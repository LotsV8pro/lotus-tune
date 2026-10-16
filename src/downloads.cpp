#include "downloads.h"

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSettings>
#include <QStringList>
#include <QUrl>

#include <utility>

#include <QDebug>

namespace {

// Extensiones de audio que forman la biblioteca local.
const char *const kAudioExts[] = {
    "mp3", "flac", "m4a", "opus", "ogg", "wav", "webm", "mka",
};

bool isAudioFile(const QString &path)
{
    const QString ext = QFileInfo(path).suffix().toLower();
    for (const char *e : kAudioExts)
        if (ext == QLatin1String(e))
            return true;
    return false;
}

// ¿Está mutagen disponible para yt-dlp? Se comprueba una sola vez por sesión
// (python3 -c "import mutagen"). Sólo condiciona incrustar la portada en
// formatos que lo requieren (Opus/Ogg).
bool mutagenAvailable()
{
    static const bool ok = [] {
        QProcess p;
        p.start(QStringLiteral("python3"),
                {QStringLiteral("-c"), QStringLiteral("import mutagen")});
        if (!p.waitForFinished(4000))
            return false;
        return p.exitStatus() == QProcess::NormalExit && p.exitCode() == 0;
    }();
    return ok;
}

} // namespace

Downloads::Downloads(QObject *parent)
    : QObject(parent)
{
    // Carpeta persistida por el usuario; si no hay, la de por defecto.
    const QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    const QString saved = s.value(QStringLiteral("downloadFolder")).toString();
    m_folder = saved.trimmed().isEmpty() ? defaultFolder() : saved.trimmed();
    QDir().mkpath(m_folder);

    // Un único proceso yt-dlp, con salida estándar y de error mezcladas para
    // leer tanto los avisos como la barra de progreso con el mismo parser.
    m_proc.setProcessChannelMode(QProcess::MergedChannels);
    connect(&m_proc, &QProcess::readyRead, this, &Downloads::readStdout);
    connect(&m_proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this](int code, QProcess::ExitStatus) { finishJob(code); });

    // Escaneo incremental: el QDirIterator avanza por lotes en cada tick para
    // no congelar la UI con bibliotecas grandes.
    m_scanTimer.setInterval(2);
    connect(&m_scanTimer, &QTimer::timeout, this, &Downloads::scanChunk);

    // Auto-sync: cualquier cambio en disco (alta/baja de ficheros) reescanea
    // la biblioteca local tras un breve silencio, sin intervención del usuario.
    m_watchDebounce.setSingleShot(true);
    m_watchDebounce.setInterval(600);
    connect(&m_watchDebounce, &QTimer::timeout, this, [this]() {
        if (!m_busy)
            refreshLocal();
    });
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this,
            [this](const QString &) { m_watchDebounce.start(); });

    // Primera sincronización al arrancar.
    refreshLocal();
}

Downloads::~Downloads()
{
    stopScan();
    if (m_proc.state() != QProcess::NotRunning) {
        m_proc.kill();
        m_proc.waitForFinished(700);
    }
}

QString Downloads::defaultFolder() const
{
    return QDir::homePath() + QStringLiteral("/.local/share/lotus-tune/descargas");
}

void Downloads::setFolder(const QString &dir)
{
    const QString clean = QDir::cleanPath(dir.trimmed());
    if (clean.isEmpty() || clean == m_folder)
        return;
    m_folder = clean;
    QDir().mkpath(m_folder);

    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    s.setValue(QStringLiteral("downloadFolder"), m_folder);
    s.sync();

    emit changed();
    // La biblioteca local ahora vive en otra carpeta: reescanear.
    refreshLocal();
}

// ---------------------------------------------------------------- jobs ----

QVariantList Downloads::jobs() const
{
    QVariantList out;
    out.reserve(m_jobs.size());
    for (const Job &j : m_jobs) {
        QVariantMap m;
        m.insert(QStringLiteral("name"), j.name);
        m.insert(QStringLiteral("url"), j.url);
        m.insert(QStringLiteral("progress"), j.progress);
        m.insert(QStringLiteral("state"), j.state);
        m.insert(QStringLiteral("error"), j.error);
        out.append(m);
    }
    return out;
}

// Crea un nombre de carpeta/archivo seguro (yt-dlp también escapa, pero la
// ruta base no debe contener separadores ni caracteres prohibidos).
QString Downloads::safeSegment(const QString &text)
{
    QString s = text.trimmed();
    s.replace(QRegularExpression(QStringLiteral("[\\\\/:*?\"<>|\\p{Cc}]")),
              QStringLiteral("_"));
    // Puntos/espacios finales problemáticos en algunos sistemas de ficheros.
    while (s.endsWith(QLatin1Char('.')) || s.endsWith(QLatin1Char(' ')))
        s.chop(1);
    if (s.isEmpty())
        s = QStringLiteral("descarga");
    if (s.size() > 160)
        s = s.left(160);
    return s;
}

void Downloads::enqueue(const Job &job)
{
    m_jobs.append(job);
    emit jobsChanged();
    if (m_current < 0)
        startNext();
    else
        emit changed();
}

void Downloads::downloadPlaylist(const QString &url, const QString &name)
{
    const QString u = url.trimmed();
    if (u.isEmpty())
        return;
    Job j;
    j.url = u;
    j.playlist = true;
    j.name = name.trimmed().isEmpty() ? QStringLiteral("Playlist") : name.trimmed();
    enqueue(j);
}

void Downloads::downloadTrack(const QString &url, const QString &title,
                              const QString &artist)
{
    const QString u = url.trimmed();
    if (u.isEmpty())
        return;
    Job j;
    j.url = u;
    j.playlist = false;
    const QString t = title.trimmed();
    const QString a = artist.trimmed();
    j.name = a.isEmpty() ? t : a + QStringLiteral(" - ") + t;
    if (j.name.trimmed().isEmpty())
        j.name = QStringLiteral("Pista");
    enqueue(j);
}

void Downloads::setJob(int index, const QString &state, const QString &error)
{
    if (index < 0 || index >= m_jobs.size())
        return;
    m_jobs[index].state = state;
    m_jobs[index].error = error;
}

void Downloads::startNext()
{
    if (m_current >= 0)
        return;  // ya hay una descarga en curso

    int idx = -1;
    for (int i = 0; i < m_jobs.size(); ++i) {
        if (m_jobs[i].state == QLatin1String("queued")) {
            idx = i;
            break;
        }
    }
    if (idx < 0) {
        // Cola vacía: se acabó el trabajo.
        if (m_busy) {
            m_busy = false;
            emit changed();
        }
        return;
    }

    m_current = idx;
    Job &j = m_jobs[idx];
    j.progress = 0;
    j.state = QStringLiteral("downloading");
    j.error.clear();
    m_lastError.clear();
    m_buf.clear();
    m_plItem = 0;
    m_plTotal = 0;

    m_busy = true;
    emit changed();
    emit jobsChanged();

    // -o relativo a -P home (la carpeta de la app):
    //   playlist -> <name>/<índice><título>.<ext>
    //   pista    -> <artista> - <título>.<ext>
    QString outTemplate;
    if (j.playlist) {
        const QString dir = m_folder + QLatin1Char('/') + safeSegment(j.name);
        QDir().mkpath(dir);
        outTemplate = safeSegment(j.name)
            + QStringLiteral("/%(playlist_index|)s%(title)s.%(ext)s");
    } else {
        QDir().mkpath(m_folder);
        outTemplate = safeSegment(j.name) + QStringLiteral(".%(ext)s");
    }

    QStringList args{
        QStringLiteral("--no-config"),
        QStringLiteral("--newline"),
        // Todo (audio, .part, miniaturas, info.json) se escribe DIRECTAMENTE
        // en la carpeta de la app; nada pasa por ~/Downloads ni por /tmp, así
        // que no hay que "mover" ficheros al terminar.
        QStringLiteral("-P"), QStringLiteral("home:") + m_folder,
        QStringLiteral("-P"), QStringLiteral("temp:") + m_folder,
        QStringLiteral("--extract-audio"),
        QStringLiteral("--audio-format"), QStringLiteral("best"),
        QStringLiteral("--audio-quality"), QStringLiteral("0"),
        QStringLiteral("--embed-metadata"),
        QStringLiteral("--write-info-json"),
        QStringLiteral("-o"), outTemplate,
    };

    // --embed-thumbnail en Opus/Ogg usa mutagen; si no está instalado yt-dlp
    // falla en el postprocesado ("module mutagen was not found"). La portada
    // de la app sale del .info.json, así que sólo incrustamos si es posible.
    if (mutagenAvailable())
        args << QStringLiteral("--embed-thumbnail");

    // Sesión de YT Music: las listas PRIVADAS del usuario (p. ej. "Vibes")
    // sin cookies devuelven "YouTube said: The playlist does not exist", así
    // que adjuntamos el cookies.txt del login integrado igual que hace el
    // catálogo para buscar/abrir listas.
    const QString cookies = QDir::homePath()
        + QStringLiteral("/.config/lotus-tune/cookies.txt");
    if (QFile::exists(cookies)
        && (j.url.contains(QLatin1String("youtube.com"))
            || j.url.contains(QLatin1String("youtu.be"))
            || j.url.contains(QLatin1String("music.youtube.com")))) {
        args << QStringLiteral("--cookies") << cookies;
    }

    args << j.url;

    m_proc.setProgram(QStringLiteral("yt-dlp"));
    m_proc.setArguments(args);
    m_proc.start();
    if (!m_proc.waitForStarted(3000)) {
        setJob(m_current, QStringLiteral("error"),
               QStringLiteral("No se pudo ejecutar yt-dlp"));
        m_current = -1;
        m_busy = false;
        emit jobsChanged();
        emit changed();
        startNext();
    }
}

void Downloads::readStdout()
{
    m_buf += m_proc.readAllStandardOutput();
    int nl;
    while ((nl = m_buf.indexOf('\n')) >= 0) {
        const QString line = QString::fromUtf8(m_buf.left(nl)).trimmed();
        m_buf.remove(0, nl + 1);
        if (line.isEmpty() || m_current < 0)
            continue;

        // Cabecera de cada pista de una lista: "Downloading item 3 of 20".
        // Permite traducir el % por-pista a un % global de la lista.
        static const QRegularExpression reItem(
            QStringLiteral("Downloading item ([0-9]+) of ([0-9]+)"));
        const QRegularExpressionMatch mi = reItem.match(line);
        if (mi.hasMatch()) {
            m_plItem = mi.captured(1).toInt();
            m_plTotal = mi.captured(2).toInt();
        }

        // Ignora el progreso del postprocesado ("[ExtractAudio]"), solo nos
        // interesa la barra de descarga.
        static const QRegularExpression reProgress(
            QStringLiteral("\\[download\\]\\s+([0-9]+(?:\\.[0-9]+)?)%"));
        const QRegularExpressionMatch m = reProgress.match(line);
        if (m.hasMatch()) {
            const double frac = qBound(0.0, m.captured(1).toDouble() / 100.0, 1.0);
            // Con varias pistas: un solo 0-100 % de TODA la lista
            // ((completadas + fracción actual) / total). En pistas sueltas,
            // el % de siempre.
            int p;
            if (m_plTotal > 1 && m_plItem > 0)
                p = qBound(0, qRound(((m_plItem - 1) + frac) / m_plTotal * 100.0), 100);
            else
                p = qBound(0, qRound(frac * 100.0), 100);
            if (p != m_jobs[m_current].progress) {
                m_jobs[m_current].progress = p;
                emit jobsChanged();
            }
        }

        if (line.contains(QLatin1String("has been downloaded"))
            && (m_plTotal <= 1 || m_plItem >= m_plTotal))
            m_jobs[m_current].progress = 100;

        // Guarda el último error real para mostrarlo si el proceso falla.
        const int err = line.indexOf(QLatin1String("ERROR:"));
        if (err >= 0)
            m_lastError = line.mid(err + 6).trimmed();
    }
}

void Downloads::finishJob(int code)
{
    readStdout();  // drena lo que quede pendiente antes de cerrar el job
    if (m_current < 0)
        return;

    const int idx = m_current;
    m_current = -1;

    if (m_cancelling) {
        setJob(idx, QStringLiteral("error"), QStringLiteral("Cancelado"));
    } else if (code == 0) {
        setJob(idx, QStringLiteral("done"));
        m_jobs[idx].progress = 100;
    } else {
        setJob(idx, QStringLiteral("error"),
               m_lastError.isEmpty()
                   ? QStringLiteral("yt-dlp terminó con código %1").arg(code)
                   : m_lastError);
    }

    emit jobsChanged();
    emit changed();

    if (m_cancelling) {
        m_cancelling = false;
        m_busy = false;
        emit changed();
        return;  // cancelAll() ya marcó el resto de la cola
    }

    // Siguiente de la cola y refresco automático de la biblioteca local.
    startNext();
    refreshLocal();
}

void Downloads::cancelAll()
{
    // Los jobs aún en cola nunca llegarán a ejecutarse.
    for (int i = 0; i < m_jobs.size(); ++i) {
        if (m_jobs[i].state == QLatin1String("queued"))
            setJob(i, QStringLiteral("error"), QStringLiteral("Cancelado"));
    }

    if (m_proc.state() != QProcess::NotRunning) {
        m_cancelling = true;
        m_proc.kill();
    }
    emit jobsChanged();
    emit changed();
}

// ------------------------------------------------------------- local ----

QString Downloads::artistForPath(const QString &dir) const
{
    const QDir root(m_folder);
    const QString rel = root.relativeFilePath(dir);
    if (rel.isEmpty() || rel == QLatin1String("."))
        return QStringLiteral("Local");
    return rel.section(QLatin1Char('/'), 0, 0);
}

QVariantList Downloads::folders() const
{
    // Agrupa la biblioteca local por carpeta de primer nivel: cada carpeta es
    // una lista descargada (con nombre, nº de pistas y una miniatura).
    QStringList order;
    QHash<QString, QVariantList> groups;
    for (const QVariant &v : m_local) {
        const QString f = v.toMap().value(QStringLiteral("folder")).toString();
        if (f.isEmpty())
            continue;   // pistas sueltas en la raíz: no forman lista
        if (!groups.contains(f))
            order.append(f);
        groups[f].append(v);
    }

    QVariantList out;
    out.reserve(order.size());
    for (const QString &f : std::as_const(order)) {
        const QVariantList &tr = groups.value(f);
        QString thumb;
        for (const QVariant &v : tr) {
            const QString th = v.toMap().value(QStringLiteral("thumb")).toString();
            if (!th.isEmpty()) {
                thumb = th;
                break;
            }
        }
        QVariantMap m;
        m.insert(QStringLiteral("name"), f);
        m.insert(QStringLiteral("folder"), f);
        m.insert(QStringLiteral("count"), tr.size());
        m.insert(QStringLiteral("thumb"), thumb);
        out.append(m);
    }
    return out;
}

QVariantMap Downloads::makeLocalTrack(const QString &path) const
{
    const QFileInfo fi(path);
    // Carpeta de primer nivel bajo la raíz = una lista descargada ("Neon &
    // Shadows", etc.). Vacia si el fichero está suelto en la raíz.
    const QString rel = QDir(m_folder).relativeFilePath(fi.absolutePath());
    const QString folder = (rel.isEmpty() || rel == QLatin1String("."))
        ? QString() : rel.section(QLatin1Char('/'), 0, 0);
    QVariantMap t;
    t.insert(QStringLiteral("title"), fi.completeBaseName());
    t.insert(QStringLiteral("artist"), artistForPath(fi.absolutePath()));
    t.insert(QStringLiteral("folder"), folder);
    t.insert(QStringLiteral("duration"), 0.0);
    t.insert(QStringLiteral("thumb"), QString());
    t.insert(QStringLiteral("url"),
             QUrl::fromLocalFile(fi.absoluteFilePath()).toString());
    t.insert(QStringLiteral("source"), QStringLiteral("local"));

    // yt-dlp con --write-info-json deja "<archivo>.info.json" junto al audio.
    // Se prueban ambas variantes (con y sin extensión del media) por si acaso.
    const QStringList candidates{
        fi.absolutePath() + QLatin1Char('/') + fi.fileName()
            + QStringLiteral(".info.json"),
        fi.absolutePath() + QLatin1Char('/') + fi.completeBaseName()
            + QStringLiteral(".info.json"),
    };
    for (const QString &info : candidates) {
        QFile f(info);
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        if (o.isEmpty())
            continue;

        const QString title = o.value(QStringLiteral("title")).toString().trimmed();
        if (!title.isEmpty())
            t.insert(QStringLiteral("title"), title);

        QString artist = o.value(QStringLiteral("artist")).toString().trimmed();
        if (artist.isEmpty())
            artist = o.value(QStringLiteral("uploader")).toString().trimmed();
        if (artist.isEmpty())
            artist = o.value(QStringLiteral("channel")).toString().trimmed();
        if (!artist.isEmpty())
            t.insert(QStringLiteral("artist"), artist);

        if (o.contains(QStringLiteral("duration")))
            t.insert(QStringLiteral("duration"),
                     o.value(QStringLiteral("duration")).toDouble());

        const QString thumb = o.value(QStringLiteral("thumbnail")).toString();
        if (!thumb.isEmpty())
            t.insert(QStringLiteral("thumb"), thumb);
        break;
    }
    return t;
}

void Downloads::refreshLocal()
{
    // Reinicia cualquier escaneo en curso y empieza de cero.
    stopScan();
    m_scanItems.clear();
    m_scanDirs.clear();
    m_localBusy = true;
    emit libraryChanged();
    startScan();
}

void Downloads::startScan()
{
    if (m_folder.isEmpty() || !QDir(m_folder).exists()) {
        m_local.clear();
        m_localBusy = false;
        emit libraryChanged();
        return;
    }

    // Sin filtros de nombre: probamos la extensión a mano para ser
    // insensible a mayúsculas y encontrar cualquier formato de audio.
    m_scan = new QDirIterator(m_folder, QDir::Files | QDir::NoDotAndDotDot
                                           | QDir::Readable,
                              QDirIterator::Subdirectories);
    m_scanTimer.start();
    emit libraryChanged();
}

void Downloads::stopScan()
{
    m_scanTimer.stop();
    delete m_scan;
    m_scan = nullptr;
}

void Downloads::scanChunk()
{
    if (!m_scan) {
        m_scanTimer.stop();
        return;
    }

    // Lote pequeño: mantiene el bucle de eventos vivo entre ticks.
    int processed = 0;
    while (processed < 60 && m_scan->hasNext()) {
        const QString path = m_scan->next();
        ++processed;
        m_scanDirs.insert(QFileInfo(path).absolutePath());
        if (isAudioFile(path))
            m_scanItems.append(makeLocalTrack(path));
    }

    if (!m_scan->hasNext()) {
        stopScan();
        m_local = m_scanItems;
        m_scanItems.clear();
        m_localBusy = false;
        updateWatchDirs();
        emit libraryChanged();
    }
}

void Downloads::updateWatchDirs()
{
    // Vigila la raíz + cada subcarpeta descubierta (una por lista/pista).
    QStringList want;
    if (!m_folder.isEmpty() && QDir(m_folder).exists())
        want << m_folder;
    for (const QString &d : std::as_const(m_scanDirs))
        if (QDir(d).exists())
            want << d;
    want.removeDuplicates();

    const QStringList current = m_watcher.directories();
    for (const QString &d : current)
        if (!want.contains(d))
            m_watcher.removePath(d);
    for (const QString &d : want)
        if (!current.contains(d))
            m_watcher.addPath(d);
}

void Downloads::openFolder()
{
    if (m_folder.isEmpty())
        return;
    QDir().mkpath(m_folder);
    QProcess::startDetached(QStringLiteral("xdg-open"), {m_folder});
}