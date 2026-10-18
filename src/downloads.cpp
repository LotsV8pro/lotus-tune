#include "downloads.h"

#include <QDateTime>
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

// Restos parciales que yt-dlp deja al interrumpirse una descarga; se limpian
// al cancelar/fallar (y, si quedan huérfanos de otra sesión, al arrancar).
bool isPartialName(const QString &name)
{
    const QString low = name.toLower();
    return low.endsWith(QLatin1String(".part"))
        || low.endsWith(QLatin1String(".ytdl"))
        || low.endsWith(QLatin1String(".temp"))
        || low.contains(QLatin1String(".part-frag"));
}

bool isAudioFile(const QString &path)
{
    const QString ext = QFileInfo(path).suffix().toLower();
    for (const char *e : kAudioExts)
        if (ext == QLatin1String(e))
            return true;
    return false;
}

// Antigüedad mínima (segundos) para considerar huérfano un resto parcial al
// arrancar: así no se borra uno reanudable de un cierre reciente, pero sí la
// basura que dejó una sesión abortada hace horas.
constexpr qint64 kOrphanAgeSecs = 6 * 3600;

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

    // Limpia restos parciales huérfanos (de una sesión abortada) antes de la
    // primera sincronización.
    sweepOrphans(kOrphanAgeSecs);

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

int Downloads::activeProgress() const
{
    if (m_current < 0 || m_current >= m_jobs.size())
        return -1;
    return m_jobs[m_current].progress;
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
        m.insert(QStringLiteral("playlist"), j.playlist);
        // Carpeta destino de una lista ("" en pistas sueltas), para que la UI
        // pueda dar feedback dentro de la propia lista.
        m.insert(QStringLiteral("folder"), j.folder);
        m.insert(QStringLiteral("progress"), j.progress);
        m.insert(QStringLiteral("state"), j.state);
        m.insert(QStringLiteral("error"), j.error);
        out.append(m);
    }
    return out;
}

// Crea un nombre de carpeta/archivo seguro (yt-dlp también escapa, pero la
// ruta base no debe contener separadores ni caracteres prohibidos, ni exceder
// el límite del sistema de ficheros con títulos largos en UTF-8).
QString Downloads::safeSegment(const QString &text)
{
    QString s = text.trimmed();
    s.replace(QRegularExpression(QStringLiteral("[\\\\/:*?\"<>|\\p{Cc}\\p{Cf}]")),
              QStringLiteral("_"));
    // Colapsa espacios repetidos para nombres más limpios.
    s.replace(QRegularExpression(QStringLiteral("\\s+")), QStringLiteral(" "));
    while (s.endsWith(QLatin1Char('.')) || s.endsWith(QLatin1Char(' ')))
        s.chop(1);
    if (s.isEmpty())
        s = QStringLiteral("descarga");

    // Recorta por BYTES, no por caracteres: un nombre UTF-8 puede ocupar varios
    // bytes por carácter y desbordar el límite (255) del sistema de ficheros.
    // Se cortan code points enteros para no dejar un surrogate suelto.
    static constexpr int kMaxBytes = 180;
    while (s.toUtf8().size() > kMaxBytes && !s.isEmpty()) {
        const QChar last = s.at(s.size() - 1);
        s.chop(last.isLowSurrogate() && s.size() >= 2 ? 2 : 1);
    }
    // El recorte puede dejar un punto/espacio final otra vez.
    while (s.endsWith(QLatin1Char('.')) || s.endsWith(QLatin1Char(' ')))
        s.chop(1);
    if (s.isEmpty())
        s = QStringLiteral("descarga");
    return s;
}

// Carpeta de primer nivel única para una lista. Reutiliza la existente si es
// la MISMA lista (metadatos con la misma URL) para reanudar/completar; si el
// nombre colisiona con OTRA lista, le añade un sufijo "(2)", "(3)"…
QString Downloads::uniqueListFolder(const QString &seg, const QString &url) const
{
    const QString base = m_folder + QLatin1Char('/') + seg;
    if (!QDir(base).exists())
        return seg;

    QFile mf(base + QStringLiteral("/.lotus-list.json"));
    if (mf.open(QIODevice::ReadOnly)) {
        const QJsonObject o = QJsonDocument::fromJson(mf.readAll()).object();
        const QString prev = o.value(QStringLiteral("url")).toString().trimmed();
        if (!url.isEmpty() && prev == url)
            return seg;   // misma lista: se reutiliza y se reanuda
    }

    for (int i = 2; i < 10000; ++i) {
        const QString cand = QStringLiteral("%1 (%2)").arg(seg).arg(i);
        if (!QDir(m_folder + QLatin1Char('/') + cand).exists())
            return cand;
    }
    return QStringLiteral("%1 (%2)")
        .arg(seg)
        .arg(QDateTime::currentMSecsSinceEpoch());
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

// Marca un job como fallido con un mensaje LEGIBLE, avisa a la UI y, si era la
// descarga en curso, libera el proceso y arranca la siguiente de la cola.
void Downloads::failJob(int index, const QString &message)
{
    if (index < 0 || index >= m_jobs.size())
        return;
    const bool wasCurrent = (index == m_current);
    setJob(index, QStringLiteral("error"), message);
    if (wasCurrent) {
        m_current = -1;
        m_busy = false;
    }
    const QString name = m_jobs[index].name;
    emit jobsChanged();
    emit changed();
    emit downloadError(name, message);
    emit activeProgressChanged();
    if (wasCurrent)
        startNext();
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
            emit activeProgressChanged();
        }
        return;
    }

    m_current = idx;
    Job &j = m_jobs[idx];
    j.progress = 0;
    j.state = QStringLiteral("downloading");
    j.error.clear();
    j.folder.clear();
    m_lastError.clear();
    m_buf.clear();
    m_plItem = 0;
    m_plTotal = 0;

    m_busy = true;
    emit changed();
    emit jobsChanged();
    emit activeProgressChanged();

    // -o relativo a -P home (la carpeta de la app):
    //   playlist -> <name>/<índice><título>.<ext>
    //   pista    -> <artista> - <título>.<ext>
    QString outTemplate;
    QString archivePath;
    if (j.playlist) {
        const QString seg = uniqueListFolder(safeSegment(j.name), j.url);
        j.folder = seg;
        const QString dir = m_folder + QLatin1Char('/') + seg;
        if (!QDir().mkpath(dir)) {
            failJob(idx, QStringLiteral("No se pudo crear la carpeta «%1». "
                                        "Comprueba los permisos.").arg(dir));
            return;
        }
        if (!QFileInfo(dir).isWritable()) {
            failJob(idx, QStringLiteral("La carpeta de descargas no tiene "
                                        "permiso de escritura: %1").arg(dir));
            return;
        }
        // Marca de identidad de la lista descargada: guarda el nombre original
        // y su URL para poder emparejarla después (desinstalar, abrir, etc.),
        // aunque el nombre visible cambie o el título esté sanitizado.
        QJsonObject meta;
        meta.insert(QStringLiteral("name"), j.name);
        meta.insert(QStringLiteral("url"), j.url);
        QFile mf(dir + QStringLiteral("/.lotus-list.json"));
        if (mf.open(QIODevice::WriteOnly | QIODevice::Truncate))
            mf.write(QJsonDocument(meta).toJson(QJsonDocument::Compact));
        // Archivo de descargas por lista: evita re-bajar pistas ya completadas
        // al reanudar. Vive DENTRO de la carpeta, así que desinstalar la lista
        // también lo borra (una descarga nueva vuelve a bajar todo).
        archivePath = dir + QStringLiteral("/.lotus-archive.txt");
        outTemplate = seg
            + QStringLiteral("/%(playlist_index|)s%(title)s.%(ext)s");
    } else {
        if (!QDir().mkpath(m_folder) || !QFileInfo(m_folder).isWritable()) {
            failJob(idx, QStringLiteral("No se puede escribir en la carpeta de "
                                        "descargas: %1").arg(m_folder));
            return;
        }
        outTemplate = safeSegment(j.name) + QStringLiteral(".%(ext)s");
    }

    QStringList args{
        QStringLiteral("--no-config"),
        QStringLiteral("--newline"),
        // Todo (audio, .part, restos…) se escribe DIRECTAMENTE en la carpeta
        // de la app; nada pasa por ~/Downloads ni por /tmp, así que no hay que
        // "mover" ficheros al terminar.
        QStringLiteral("-P"), QStringLiteral("home:") + m_folder,
        QStringLiteral("-P"), QStringLiteral("temp:") + m_folder,
        // SÓLO audio: elige la mejor pista de audio ya comprimida (m4a/opus)
        // para NO re-codificar y ocupar lo mínimo; si no hay, cae a `best`.
        QStringLiteral("-f"),
        QStringLiteral("bestaudio[ext=m4a]/bestaudio[ext=opus]/bestaudio/best"),
        QStringLiteral("--extract-audio"),
        QStringLiteral("--audio-format"), QStringLiteral("best"),
        QStringLiteral("--audio-quality"), QStringLiteral("0"),
        QStringLiteral("--embed-metadata"),
        // Sin miniatura embebida y sin `.info.json`: menos peso, menos
        // postprocesado y sin depender de mutagen.
        QStringLiteral("--no-embed-thumbnail"),
        QStringLiteral("--no-write-info-json"),
        // Reanudable y sin volver a bajar lo que ya está.
        QStringLiteral("--continue"),
        QStringLiteral("--no-overwrites"),
        // Progreso machine-readable: índice/total de la lista + % de la pista
        // actual, con un prefijo reconocible para calcular UN 0-100 % TOTAL.
        QStringLiteral("--progress-template"),
        QStringLiteral("download:##LT##%(info.playlist_index)s|"
                       "%(info.n_entries)s|%(progress._percent_str)s"),
        QStringLiteral("-o"), outTemplate,
    };

    // Archivo de descargas por lista (sólo listas).
    if (!archivePath.isEmpty())
        args << QStringLiteral("--download-archive") << archivePath;

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
        failJob(idx, QStringLiteral("No se pudo ejecutar yt-dlp. "
                                    "¿Está instalado?"));
    }
}

// Actualiza el progreso AGREGADO (0-100 de TODA la lista) a partir de la
// fracción (0..1) de la pista actual y lo publica sólo cuando cambia.
void Downloads::updateProgress(double frac)
{
    if (m_current < 0 || m_current >= m_jobs.size())
        return;
    frac = qBound(0.0, frac, 1.0);

    int p;
    if (m_plTotal > 1 && m_plItem > 0)
        p = qBound(0, qRound(((m_plItem - 1) + frac) / m_plTotal * 100.0), 100);
    else
        p = qBound(0, qRound(frac * 100.0), 100);

    if (p == m_jobs[m_current].progress)
        return;
    m_jobs[m_current].progress = p;
    emit jobsChanged();
    emit progressChanged(m_jobs[m_current].name, p);
    emit activeProgressChanged();
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

        // Formato preferente, el que pedimos con --progress-template:
        //   ##LT##<índice>|<total>|<pct>%
        static const QRegularExpression reTpl(
            QStringLiteral("##LT##\\s*([^|]*)\\|\\s*([^|]*)\\|\\s*"
                           "([0-9]+(?:\\.[0-9]+)?)%"));
        const QRegularExpressionMatch mt = reTpl.match(line);
        if (mt.hasMatch()) {
            const int item = mt.captured(1).toInt();
            const int total = mt.captured(2).toInt();
            if (item > 0)
                m_plItem = item;
            if (total > 0)
                m_plTotal = total;
            updateProgress(mt.captured(3).toDouble() / 100.0);
            continue;   // es una línea de progreso: nada más que mirar
        }

        // Compatibilidad con yt-dlp antiguos: "Downloading item 3 of 20".
        static const QRegularExpression reItem(
            QStringLiteral("Downloading item ([0-9]+) of ([0-9]+)"));
        const QRegularExpressionMatch mi = reItem.match(line);
        if (mi.hasMatch()) {
            m_plItem = mi.captured(1).toInt();
            m_plTotal = mi.captured(2).toInt();
        }

        // Barra clásica "[download]  12.3%": respaldo por si no hay template.
        static const QRegularExpression reProgress(
            QStringLiteral("\\[download\\]\\s+([0-9]+(?:\\.[0-9]+)?)%"));
        const QRegularExpressionMatch m = reProgress.match(line);
        if (m.hasMatch())
            updateProgress(m.captured(1).toDouble() / 100.0);

        // Guarda el último error real para mostrarlo si el proceso falla.
        const int err = line.indexOf(QLatin1String("ERROR:"));
        if (err >= 0)
            m_lastError = line.mid(err + 6).trimmed();
    }
}

// Traduce los errores más comunes de yt-dlp a mensajes legibles en español.
QString Downloads::friendlyError(const QString &raw)
{
    const QString r = raw.trimmed();
    if (r.isEmpty())
        return QStringLiteral("La descarga falló.");

    const QString low = r.toLower();
    auto has = [&low](const char *needle) {
        return low.contains(QLatin1String(needle));
    };

    if (has("does not exist") || has("not found") || has("unavailable")
        || has("404") || has("removed"))
        return QStringLiteral("La lista no existe, es privada o ya no está "
                              "disponible.");
    if (has("private") || has("members-only") || has("sign in")
        || has("login") || has("logged") || has("cookies")
        || has("account"))
        return QStringLiteral("Contenido privado: inicia sesión en Ajustes y "
                              "vuelve a intentarlo.");
    if (has("unsupported url") || has("is not a valid url")
        || has("invalid url"))
        return QStringLiteral("La dirección no es compatible.");
    if (has("ffmpeg") || has("ffprobe") || has("postprocessing")
        || has("post-process"))
        return QStringLiteral("Falta ffmpeg para procesar el audio.");
    if (has("timed out") || has("timeout") || has("temporary failure")
        || has("getaddrinfo") || has("unable to download") || has("network")
        || has("connection") || has("resolve") || has("http error")
        || has("ssl"))
        return QStringLiteral("Fallo de red. Comprueba tu conexión e "
                              "inténtalo de nuevo.");
    if (has("no space") || has("disk") || has("read-only")
        || has("permission denied"))
        return QStringLiteral("No hay espacio o la carpeta de descargas no "
                              "tiene permiso de escritura.");
    if (has("requested format is not available")
        || has("no video formats") || has("no formats"))
        return QStringLiteral("No hay ningún formato de audio disponible.");

    // Sin coincidencia: usa el mensaje original (ya recortado por yt-dlp).
    return r;
}

int Downloads::countAudioFiles(const QString &dir)
{
    QDir d(dir);
    if (!d.exists())
        return 0;
    const QStringList names = d.entryList(QDir::Files | QDir::NoDotAndDotDot);
    int n = 0;
    for (const QString &f : names)
        if (isAudioFile(f))
            ++n;
    return n;
}

void Downloads::removePartials(const QString &dir)
{
    QDir d(dir);
    if (!d.exists())
        return;
    const QStringList names = d.entryList(QDir::Files | QDir::NoDotAndDotDot);
    for (const QString &n : names)
        if (isPartialName(n))
            d.remove(n);
}

void Downloads::sweepOrphans(qint64 ageSecs)
{
    if (m_folder.isEmpty() || !QDir(m_folder).exists())
        return;
    const QDateTime now = QDateTime::currentDateTimeUtc();
    QDirIterator it(m_folder,
                    {QStringLiteral("*.part"), QStringLiteral("*.part-Frag*"),
                     QStringLiteral("*.part-frag*"), QStringLiteral("*.ytdl"),
                     QStringLiteral("*.temp")},
                    QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QString path = it.next();
        const QFileInfo fi(path);
        // Sólo huérfanos "viejos": lo reciente puede ser una sesión reanudable.
        if (fi.lastModified().toUTC().secsTo(now) >= ageSecs)
            QFile::remove(path);
    }
}

void Downloads::finishJob(int code)
{
    readStdout();  // drena lo que quede pendiente antes de cerrar el job
    if (m_current < 0)
        return;

    const int idx = m_current;
    m_current = -1;

    const Job job = m_jobs[idx];   // copia: nombre, playlist y carpeta
    const QString dir = job.folder.isEmpty()
        ? m_folder
        : m_folder + QLatin1Char('/') + job.folder;

    if (m_cancelling) {
        // Cancelado a mitad: borra los restos parciales para no dejar basura.
        removePartials(dir);
        setJob(idx, QStringLiteral("error"), QStringLiteral("Cancelado"));
        m_cancelling = false;
        m_busy = false;
        emit jobsChanged();
        emit changed();
        emit activeProgressChanged();
        return;  // cancelAll() ya marcó el resto de la cola
    }

    if (code == 0) {
        // Éxito, pero una lista VACÍA (o sin pistas bajables) también es un
        // fallo: yt-dlp puede salir con 0 y no haber escrito nada.
        if (job.playlist && countAudioFiles(dir) == 0) {
            const QString msg = QStringLiteral("La lista está vacía o no se "
                                               "pudo descargar ninguna pista.");
            setJob(idx, QStringLiteral("error"), msg);
            emit jobsChanged();
            emit changed();
            emit downloadError(job.name, msg);
            startNext();
            refreshLocal();
            return;
        }
        removePartials(dir);
        setJob(idx, QStringLiteral("done"));
        m_jobs[idx].progress = 100;
        emit jobsChanged();
        emit changed();
        emit progressChanged(job.name, 100);
        emit downloadCompleted(job.name, job.folder);
        emit activeProgressChanged();
    } else {
        // Fallo: limpia parciales y publica un motivo legible.
        const QString raw = m_lastError.isEmpty()
            ? QStringLiteral("yt-dlp terminó con código %1").arg(code)
            : m_lastError;
        const QString msg = friendlyError(raw);
        removePartials(dir);
        setJob(idx, QStringLiteral("error"), msg);
        emit jobsChanged();
        emit changed();
        emit downloadError(job.name, msg);
        emit activeProgressChanged();
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
        // finishJob() limpiará los restos parciales del job en curso.
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
        // Metadatos de la lista (si existen): nombre original y URL de origen.
        QFile mf(m_folder + QLatin1Char('/') + f
                 + QStringLiteral("/.lotus-list.json"));
        if (mf.open(QIODevice::ReadOnly)) {
            const QJsonObject o = QJsonDocument::fromJson(mf.readAll()).object();
            const QString nm = o.value(QStringLiteral("name")).toString().trimmed();
            const QString u = o.value(QStringLiteral("url")).toString().trimmed();
            if (!nm.isEmpty())
                m.insert(QStringLiteral("name"), nm);
            if (!u.isEmpty())
                m.insert(QStringLiteral("url"), u);
        }
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

    // Compatibilidad con bibliotecas antiguas: si existe un `.info.json`
    // hermano (de versiones que sí lo escribían), enriquece la pista con su
    // título, artista duración y portada. Las descargas nuevas ya no lo crean.
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

QString Downloads::listFolderName(const QString &name) const
{
    return safeSegment(name);
}

void Downloads::removeList(const QString &folder)
{
    // Sólo se permite borrar una carpeta de PRIMER nivel dentro de la carpeta
    // de descargas (nunca la raíz ni rutas con separadores o "..").
    const QString f = folder.trimmed();
    if (f.isEmpty() || f.contains(QLatin1Char('/'))
        || f.contains(QLatin1Char('\\')) || f == QLatin1String(".")
        || f == QLatin1String(".."))
        return;
    const QDir root(m_folder);
    const QString canon = QDir::cleanPath(root.absoluteFilePath(f));
    const QString rootCanon = QDir::cleanPath(root.absolutePath());
    if (canon == rootCanon
        || !canon.startsWith(rootCanon + QLatin1Char('/')))
        return;   // fuera de la carpeta de descargas

    // Si esa lista se está descargando (o está en cola), se cancela antes de
    // borrar para que yt-dlp no vuelva a crear la carpeta.
    bool killCurrent = false;
    for (int i = 0; i < m_jobs.size(); ++i) {
        if (!m_jobs[i].playlist)
            continue;
        // La carpeta resuelta manda; si aún no se resolvió (job en cola) se
        // compara por el nombre saneado.
        if (m_jobs[i].folder.isEmpty() ? safeSegment(m_jobs[i].name) != f
                                       : m_jobs[i].folder != f)
            continue;
        if (m_jobs[i].state == QLatin1String("queued"))
            setJob(i, QStringLiteral("error"), QStringLiteral("Cancelado"));
        else if (i == m_current)
            killCurrent = true;
    }
    if (killCurrent && m_proc.state() != QProcess::NotRunning) {
        m_cancelling = true;
        m_proc.kill();
    }

    QDir(canon).removeRecursively();
    // Reescanea para que la lista desaparezca al instante de la UI.
    refreshLocal();
    emit jobsChanged();
    emit changed();
}
