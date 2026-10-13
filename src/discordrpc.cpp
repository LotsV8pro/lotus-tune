#include "discordrpc.h"

#include <QCoreApplication>
#include <QDataStream>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonValue>
#include <QLocalSocket>
#include <QSettings>
#include <QUuid>

#include <QDebug>

#ifdef Q_OS_UNIX
#include <unistd.h>
#endif

namespace {

// Opcodes del protocolo Discord IPC.
enum Opcode {
    OpHandshake = 0,  // cliente -> Discord: {"v":1,"client_id":"..."}
    OpFrame     = 1,  // comandos, p.ej. SET_ACTIVITY
    OpClose     = 2,  // cierre
    OpPing      = 3,  // Discord -> cliente
    OpPong      = 4,  // cliente -> Discord (mismo payload)
};

// Id de aplicación público (el que usa la librería de referencia pypresence).
// Sirve para que el Rich Presence funcione SIN configuración: la actividad se
// publica con `name: "Lotus Tune"`, así que Discord muestra "Lotus Tune" como
// app. El usuario puede sobrescribirlo en Ajustes con su propia aplicación.
const QString kDefaultClientId = QStringLiteral("345229890980937739");

const int kReconnectMs = 15000;             // reintento de conexión
const double kSeekToleranceSeconds = 3.0;   // resincroniza la barra tras un seek

} // namespace

DiscordRpc::DiscordRpc(QObject *parent)
    : QObject(parent)
    , m_status(QStringLiteral("Desactivado"))
{
    // Reutiliza el mismo almacén que AppConfig. Estas claves no están en su
    // whitelist, así que no chocan con las suyas.
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    m_enabled = s.value(QStringLiteral("discordEnabled"), false).toBool();
    // Un valor vacío guardado (p. ej. de versiones anteriores) cae al id por
    // defecto: la presencia funciona sin que el usuario configure nada.
    const QString stored = s.value(QStringLiteral("discordClientId")).toString().trimmed();
    m_clientId = stored.isEmpty() ? kDefaultClientId : stored;

    connect(&m_reconnect, &QTimer::timeout, this, &DiscordRpc::tryConnect);
    m_reconnect.setInterval(kReconnectMs);

    // El temporizador sólo late mientras la presencia está activa: así no
    // despierta la CPU cada 15 s cuando está desactivada.
    if (m_enabled) {
        m_reconnect.start();
        tryConnect();
    }
}

DiscordRpc::~DiscordRpc()
{
    // Deja el perfil limpio al cerrar la app.
    if (m_socket && m_socket->state() == QLocalSocket::ConnectedState) {
        if (m_connected)
            sendActivity(true);
        m_socket->disconnectFromServer();
    }
}

void DiscordRpc::setStatus(const QString &s)
{
    if (m_status == s)
        return;
    m_status = s;
    qInfo() << "[discord]" << s;
    emit changed();
}

void DiscordRpc::configure(bool enabled, const QString &clientId)
{
    // Si no se indica id, se usa el de por defecto → funciona en automático.
    const QString id = clientId.trimmed();
    m_enabled = enabled;
    m_clientId = id.isEmpty() ? kDefaultClientId : id;

    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    s.setValue(QStringLiteral("discordEnabled"), m_enabled);
    s.setValue(QStringLiteral("discordClientId"), m_clientId);

    if (!m_enabled) {
        // Apaga la presencia y cierra el pipe, pero no toca los ajustes.
        m_reconnect.stop();
        if (m_connected)
            sendActivity(true);
        if (m_socket)
            m_socket->abort();
        m_connected = false;
        setStatus(QStringLiteral("Desactivado"));
    } else {
        m_reconnect.start();
        if (m_connected || (m_socket && m_socket->state() == QLocalSocket::ConnectedState))
            sendActivity(false);   // re-aplica la pista activa con el nuevo id
        else
            tryConnect();
    }
    emit changed();
}

// Rutas candidatas del socket del cliente de Discord, en orden de prioridad.
QStringList DiscordRpc::socketPaths()
{
    QStringList dirs;
    const QByteArray xdg = qgetenv("XDG_RUNTIME_DIR");
    if (!xdg.isEmpty())
        dirs << QString::fromLocal8Bit(xdg);
#ifdef Q_OS_UNIX
    dirs << QStringLiteral("/run/user/%1").arg(::getuid());
#endif
    dirs << QStringLiteral("/tmp");
    // Instalaciones Snap/Flatpak usan su propio runtime privado.
    dirs << QDir::homePath() + QStringLiteral("/.var/app/com.discordapp.Discord/tmp");
    dirs.removeDuplicates();

    QStringList paths;
    for (const QString &dir : dirs)
        for (int i = 0; i < 10; ++i)
            paths << dir + QStringLiteral("/discord-ipc-%1").arg(i);
    return paths;
}

void DiscordRpc::tryConnect()
{
    if (!m_enabled)
        return;

    if (m_clientId.isEmpty()) {
        setStatus(QStringLiteral("Client ID de Discord no configurado"));
        return;
    }

    if (m_socket && (m_socket->state() == QLocalSocket::ConnectedState
                     || m_socket->state() == QLocalSocket::ConnectingState))
        return;

    if (!m_socket) {
        m_socket = new QLocalSocket(this);
        connect(m_socket, &QLocalSocket::connected, this, &DiscordRpc::onConnected);
        connect(m_socket, &QLocalSocket::disconnected, this, &DiscordRpc::onDisconnected);
        connect(m_socket, &QLocalSocket::readyRead, this, &DiscordRpc::onReadyRead);
        connect(m_socket, &QLocalSocket::errorOccurred, this, &DiscordRpc::onErrorOccurred);
    }

    // Conecta al primer socket que exista.
    for (const QString &path : socketPaths()) {
        if (!QFile::exists(path))
            continue;
        m_socket->abort();
        m_socket->connectToServer(path);
        return;
    }

    // Sin cliente de Discord: no reintentamos conectar (no spamear), pero el
    // QTimer vuelve a comprobar cada 15 s por si lo abren después.
    setStatus(QStringLiteral("Discord no detectado"));
}

void DiscordRpc::onConnected()
{
    m_connected = true;
    m_buf.clear();
    sendHandshake();
    // Continúa la reproducción en curso, si la hay.
    if (m_hasTrack)
        sendActivity(false);
    setStatus(QStringLiteral("Conectado"));
    emit changed();
}

void DiscordRpc::onDisconnected()
{
    const bool was = m_connected;
    m_connected = false;
    m_buf.clear();
    if (m_enabled)
        setStatus(QStringLiteral("Discord no detectado"));
    else
        setStatus(QStringLiteral("Desactivado"));
    if (was)
        emit changed();
}

void DiscordRpc::onErrorOccurred()
{
    // Discord puede no estar instalado o el pipe cerrarse: el QTimer de 15 s
    // se encarga de reintentar sin inundar de mensajes.
    const bool was = m_connected;
    m_connected = false;
    m_buf.clear();
    if (m_enabled)
        setStatus(QStringLiteral("Discord no detectado"));
    else
        setStatus(QStringLiteral("Desactivado"));
    if (was)
        emit changed();
}

void DiscordRpc::sendFrame(int opcode, const QByteArray &payload)
{
    if (!m_socket || m_socket->state() != QLocalSocket::ConnectedState)
        return;

    // Cabecera: int32 LE opcode + int32 LE longitud del payload.
    QByteArray frame;
    frame.reserve(8 + payload.size());
    QDataStream ds(&frame, QIODevice::WriteOnly);
    ds.setByteOrder(QDataStream::LittleEndian);
    ds << qint32(opcode) << qint32(payload.size());
    frame.append(payload);

    m_socket->write(frame);
    m_socket->flush();
}

void DiscordRpc::sendHandshake()
{
    QJsonObject o;
    o[QStringLiteral("v")] = 1;
    o[QStringLiteral("client_id")] = m_clientId;
    sendFrame(OpHandshake, QJsonDocument(o).toJson(QJsonDocument::Compact));
}

void DiscordRpc::sendActivity(bool nullActivity)
{
    if (!m_connected)
        return;

    QJsonObject args;
    args[QStringLiteral("pid")] = static_cast<qint64>(QCoreApplication::applicationPid());
    if (nullActivity)
        args[QStringLiteral("activity")] = QJsonValue(QJsonValue::Null);
    else
        args[QStringLiteral("activity")] = buildActivity();

    QJsonObject root;
    root[QStringLiteral("cmd")] = QStringLiteral("SET_ACTIVITY");
    root[QStringLiteral("nonce")] = QUuid::createUuid().toString(QUuid::WithoutBraces);
    root[QStringLiteral("args")] = args;

    sendFrame(OpFrame, QJsonDocument(root).toJson(QJsonDocument::Compact));
}

QJsonObject DiscordRpc::buildActivity() const
{
    QJsonObject a;
    // Nombre mostrado en Discord. Con el id público por defecto, este campo es
    // lo que hace que aparezca "Lotus Tune" en lugar del nombre de la app
    // registrada; así el Rich Presence funciona sin configurar nada.
    a[QStringLiteral("name")] = QStringLiteral("Lotus Tune");
    a[QStringLiteral("type")] = 2;   // 2 = Listening
    if (!m_title.isEmpty())
        a[QStringLiteral("details")] = m_title;    // canción
    if (!m_artist.isEmpty())
        a[QStringLiteral("state")] = m_artist;     // artista

    // Progreso: Discord calcula la barra a partir de los timestamps.
    if (m_playing) {
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        QJsonObject ts;
        ts[QStringLiteral("start")] = now - static_cast<qint64>(m_position * 1000.0);
        if (m_duration > 0.0 && m_duration > m_position)
            ts[QStringLiteral("end")] =
                now + static_cast<qint64>((m_duration - m_position) * 1000.0);
        a[QStringLiteral("timestamps")] = ts;
    }

    QJsonObject assets;
    if (!m_thumb.isEmpty()) {
        // Limitación: Discord sólo garantiza URLs https en large_image en los
        // clientes modernos; clientes antiguos ignoran la URL y hay que subir
        // el arte como "asset" de la app y pasar su clave.
        assets[QStringLiteral("large_image")] = m_thumb;
    }
    assets[QStringLiteral("large_text")] =
        m_album.isEmpty() ? QStringLiteral("Lotus Tune") : m_album;
    assets[QStringLiteral("small_image")] = m_playing ? QStringLiteral("play")
                                                      : QStringLiteral("pause");
    assets[QStringLiteral("small_text")] = m_playing ? QStringLiteral("Reproduciendo")
                                                     : QStringLiteral("En pausa");
    a[QStringLiteral("assets")] = assets;

    return a;
}

void DiscordRpc::setActivity(const QString &title, const QString &artist,
                             const QString &album, const QString &thumbUrl,
                             double positionSeconds, double durationSeconds,
                             bool playing)
{
    m_title = title;
    m_artist = artist;
    m_album = album;
    m_thumb = thumbUrl;
    m_position = qMax(0.0, positionSeconds);
    m_duration = qMax(0.0, durationSeconds);
    m_playing = playing;
    m_hasTrack = !title.isEmpty();

    // Sin conexión, basta con guardar: onConnected() enviará el estado actual.
    if (!m_connected)
        return;

    const bool significant = !m_sentValid || title != m_sentTitle
        || artist != m_sentArtist || album != m_sentAlbum || thumbUrl != m_sentThumb
        || playing != m_sentPlaying;
    const bool seeked = qAbs(m_position - m_sentPosition) > kSeekToleranceSeconds;
    if (!significant && !seeked)
        return;

    sendActivity(false);
    m_sentTitle = title;
    m_sentArtist = artist;
    m_sentAlbum = album;
    m_sentThumb = thumbUrl;
    m_sentPlaying = playing;
    m_sentValid = true;
    m_sentPosition = m_position;
}

void DiscordRpc::clear()
{
    m_hasTrack = false;
    m_sentValid = false;
    if (m_connected)
        sendActivity(true);
}

void DiscordRpc::onReadyRead()
{
    if (!m_socket)
        return;
    m_buf.append(m_socket->readAll());

    // Cada frame: int32 LE opcode + int32 LE longitud + payload.
    while (m_buf.size() >= 8) {
        QDataStream ds(m_buf);
        ds.setByteOrder(QDataStream::LittleEndian);
        qint32 opcode = 0;
        qint32 len = 0;
        ds >> opcode >> len;

        if (len < 0 || len > 8 * 1024 * 1024) {   // frame corrupto
            m_buf.clear();
            break;
        }
        if (m_buf.size() < 8 + len)
            break;                                // frame incompleto

        const QByteArray payload = m_buf.mid(8, len);
        m_buf.remove(0, 8 + len);

        if (opcode == OpPing) {
            sendFrame(OpPong, payload);           // responde PONG con lo mismo
        } else if (opcode == OpClose) {
            m_socket->abort();
            break;
        }
        // Opcode 1 (respuesta a SET_ACTIVITY) se descarta.
    }
}