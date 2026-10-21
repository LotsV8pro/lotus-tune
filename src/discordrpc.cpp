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

// Public application id (the one the reference pypresence library uses).
// It makes the Rich Presence work with NO configuration: the activity is
// published with `name: "Lotus Tune"`, so Discord shows "Lotus Tune" as
// the app. The user can override it in Settings with their own
// application.
const QString kDefaultClientId = QStringLiteral("345229890980937739");

const int kReconnectMs = 15000;             // reintento de conexión
const double kSeekToleranceSeconds = 3.0;   // resincroniza la barra tras un seek

} // namespace

DiscordRpc::DiscordRpc(QObject *parent)
    : QObject(parent)
    , m_status(QStringLiteral("Desactivado"))
{
    // It reuses the same store as AppConfig. These keys are not in its
    // whitelist, so they do not clash with yours.
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    m_enabled = s.value(QStringLiteral("discordEnabled"), false).toBool();
    // An empty stored value (e.g. from older versions) falls back to the
    // default id: the presence works without the user configuring
    // anything.
    const QString stored = s.value(QStringLiteral("discordClientId")).toString().trimmed();
    m_clientId = stored.isEmpty() ? kDefaultClientId : stored;

    connect(&m_reconnect, &QTimer::timeout, this, &DiscordRpc::tryConnect);
    m_reconnect.setInterval(kReconnectMs);

    // The timer only ticks while the presence is active: that way it does
    // not wake the CPU every 15 s when it is disabled.
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
    // With no id, the default one is used -> it works out of the box.
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

    // Without a Discord client: it does not retry (no spamming), but the
    // QTimer checks again every 15 s in case they open it later.
    setStatus(QStringLiteral("Discord no detectado"));
}

void DiscordRpc::onConnected()
{
    m_connected = true;
    m_buf.clear();
    sendHandshake();
    // Carries on with the running playback, if there is one.
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
    // Name shown in Discord. With the default public id, this field is
    // what makes "Lotus Tune" show up instead of the registered app's
    // name; that way the Rich Presence works without configuring
    // anything.
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
        // Limitation: Discord only guarantees https URLs in large_image on
         // modern clients; older ones ignore the URL and the art has to
         // be uploaded as an app "asset" and its key passed.
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

    // Without a connection it is enough to store it: onConnected() will
    // send the current state.
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