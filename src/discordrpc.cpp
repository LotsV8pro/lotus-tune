#include "discordrpc.h"

// Discord Rich Presence
// ---------------------
// Desktop: native local IPC ("discord-ipc-N"), handshake + SET_ACTIVITY.
// Android: NO local IPC is used. The mobile Discord app exposes no pipe to
// other apps, so presence goes through Discord's gateway instead:
//   1. OAuth2 PKCE authorization (scope "openid sdk.social_layer_presence",
//      redirect lotustune://discord/callback); the code is exchanged for an
//      access/refresh token at /api/v10/oauth2/token.
//   2. A minimal RFC 6455 client over QSslSocket (the Android Qt kit has no
//      QtWebSockets module) connects to wss://gateway.discord.gg.
//   3. OP2 IDENTIFY with the OAuth token, HELLO/heartbeat/READY, then
//      OP3 PRESENCE_UPDATE with a LISTENING activity, at most once per 5 s.
// No bot token and no reading of Discord app data.

#include <QCoreApplication>
#include <QDataStream>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonValue>
#include <QLocalSocket>
#include <QSettings>
#include <QStandardPaths>
#include <QUuid>

#include <QDebug>

#ifdef Q_OS_ANDROID
#include "discordgateway.h"
#include <QCryptographicHash>
#include <QJsonArray>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRandomGenerator>
#include <QUrl>
#include <QUrlQuery>
#endif

#ifdef Q_OS_UNIX
#if defined(Q_OS_UNIX) && !defined(Q_OS_ANDROID)
#include <unistd.h>
#endif
#endif

namespace {

// Opcodes of the Discord IPC protocol.
enum Opcode {
    OpHandshake = 0,  // client -> Discord: {"v":1,"client_id":"..."}
    OpFrame     = 1,  // commands, e.g. SET_ACTIVITY
    OpClose     = 2,  // close
    OpPing      = 3,  // Discord -> client
    OpPong      = 4,  // client -> Discord (same payload)
};

// Public application id (the one the reference pypresence library uses).
// It makes the Rich Presence work with NO configuration: the activity is
// published with `name: "Lotus Tune"`, so Discord shows "Lotus Tune" as
// the app. The user can override it in Settings with their own
// application.
const QString kDefaultClientId = QStringLiteral("345229890980937739");

const int kReconnectMs = 15000;             // connection retry
const double kSeekToleranceSeconds = 3.0;   // it resyncs the bar after a seek

#ifdef Q_OS_ANDROID
const QString kRedirectUri = QStringLiteral("lotustune://discord/callback");
const QString kAuthScope = QStringLiteral("openid sdk.social_layer_presence");
const QString kAuthorizeUrl = QStringLiteral("https://discord.com/oauth2/authorize");
const QString kTokenUrl = QStringLiteral("https://discord.com/api/v10/oauth2/token");
const qint64 kPresenceIntervalMs = 5000;
#endif

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

#ifdef Q_OS_ANDROID
    androidLoadTokens();
    m_gateway = new DiscordGateway(this);
    connect(m_gateway, &DiscordGateway::connected,
            this, &DiscordRpc::androidOnGatewayConnected);
    connect(m_gateway, &DiscordGateway::textMessage,
            this, &DiscordRpc::androidOnGatewayText);
    connect(m_gateway, &DiscordGateway::disconnected,
            this, &DiscordRpc::androidOnGatewayDisconnected);
    connect(m_gateway, &DiscordGateway::errorOccurred,
            this, &DiscordRpc::androidOnGatewayError);
    m_net = new QNetworkAccessManager(this);
    connect(m_net, &QNetworkAccessManager::finished,
            this, &DiscordRpc::androidOnTokenReply);
    m_reconnect.setSingleShot(true);
    connect(&m_reconnect, &QTimer::timeout, this, &DiscordRpc::androidOnReconnect);
    m_heartbeat.setSingleShot(true);
    connect(&m_heartbeat, &QTimer::timeout, this, &DiscordRpc::androidHeartbeat);
    m_presenceTimer.setSingleShot(true);
    connect(&m_presenceTimer, &QTimer::timeout, this, &DiscordRpc::androidSendPresenceNow);

    if (m_enabled)
        androidApplyEnabled();
    else
        setStatus(QStringLiteral("Desactivado"));
#else
    connect(&m_reconnect, &QTimer::timeout, this, &DiscordRpc::tryConnect);
    m_reconnect.setInterval(kReconnectMs);

    // The timer only ticks while the presence is active: that way it does
    // not wake the CPU every 15 s when it is disabled.
    if (m_enabled) {
        m_reconnect.start();
        tryConnect();
    }
#endif
}

DiscordRpc::~DiscordRpc()
{
#ifdef Q_OS_ANDROID
    androidCleanup();
#else
    // Leaves the profile clean when the app is closed.
    if (m_socket && m_socket->state() == QLocalSocket::ConnectedState) {
        if (m_connected)
            sendActivity(true);
        m_socket->disconnectFromServer();
    }
#endif
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

#ifdef Q_OS_ANDROID
    androidApplyEnabled();
#else
    if (!m_enabled) {
        // Turns the presence off and closes the pipe, but does not touch the settings.
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
            sendActivity(false);   // it re-applies the active track with the new id
        else
            tryConnect();
    }
#endif
    emit changed();
}

// Candidate paths of the Discord client socket, in priority order.
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
    // Snap/Flatpak installations use their own private runtime.
    dirs << QDir::homePath() + QStringLiteral("/.var/app/com.discordapp.Discord/tmp");
    dirs.removeDuplicates();

    QStringList paths;
    for (const QString &dir : dirs)
        for (int i = 0; i < 10; ++i)
            paths << dir + QStringLiteral("/discord-ipc-%1").arg(i);
#ifdef Q_OS_ANDROID
    // On Android the Discord app publishes the socket in the ABSTRACT
    // namespace (there is no /tmp for the apps), so the name is the
    // socket name with a leading NUL.
    for (int i = 0; i < 10; ++i) {
        QString abstract = QString(QChar(0));
        abstract += QStringLiteral("discord-ipc-%1").arg(i);
        paths << abstract;
    }
#endif
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

    // Connects to the first socket that exists.
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
    // Discord may not be installed or the pipe may close: the 15 s QTimer
    // takes care of retrying without flooding with messages.
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

    // Header: int32 LE opcode + int32 LE payload length.
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
        a[QStringLiteral("details")] = m_title;    // song
    if (!m_artist.isEmpty())
        a[QStringLiteral("state")] = m_artist;     // artist

    // Progress: Discord computes the bar from the timestamps.
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

#ifdef Q_OS_ANDROID
    androidSendPresence();
    return;
#endif

    // Without a connection it is enough to store it: onConnected() will
    // send the current state.
    if (!m_connected)
        return;

    const bool significant = !m_sentValid || title != m_sentTitle
        || artist != m_sentArtist || album != m_sentAlbum || thumbUrl != m_sentThumb
        || playing != m_sentPlaying;
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const double expected = m_sentValid
        ? m_sentPosition + double(nowMs - m_sentAt) / 1000.0 : m_position;
    const bool seeked = m_sentValid
        && qAbs(m_position - expected) > kSeekToleranceSeconds;
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
    m_sentAt = nowMs;
}

void DiscordRpc::clear()
{
    m_hasTrack = false;
    m_sentValid = false;
#ifdef Q_OS_ANDROID
    androidSendPresence();
    return;
#endif
    if (m_connected)
        sendActivity(true);
}

void DiscordRpc::onReadyRead()
{
    if (!m_socket)
        return;
    m_buf.append(m_socket->readAll());

    // Each frame: int32 LE opcode + int32 LE length + payload.
    while (m_buf.size() >= 8) {
        QDataStream ds(m_buf);
        ds.setByteOrder(QDataStream::LittleEndian);
        qint32 opcode = 0;
        qint32 len = 0;
        ds >> opcode >> len;

        if (len < 0 || len > 8 * 1024 * 1024) {   // corrupt frame
            m_buf.clear();
            break;
        }
        if (m_buf.size() < 8 + len)
            break;                                // incomplete frame

        const QByteArray payload = m_buf.mid(8, len);
        m_buf.remove(0, 8 + len);

        if (opcode == OpPing) {
            sendFrame(OpPong, payload);           // it answers PONG with the same
        } else if (opcode == OpClose) {
            m_socket->abort();
            break;
        }
        // Opcode 1 (SET_ACTIVITY answer) is discarded.
    }
}

#ifdef Q_OS_ANDROID

QByteArray DiscordRpc::base64Url(const QByteArray &raw)
{
    QByteArray b = raw.toBase64();
    b.replace('+', '-');
    b.replace('/', '_');
    while (b.endsWith('='))
        b.chop(1);
    return b;
}

QByteArray DiscordRpc::makePkceVerifier()
{
    QByteArray raw(32, '\0');
    QRandomGenerator *g = QRandomGenerator::global();
    for (int i = 0; i < raw.size(); ++i)
        raw[i] = char(g->bounded(256));
    return base64Url(raw);  // 43 unreserved characters, as PKCE requires
}

QByteArray DiscordRpc::makePkceChallenge(const QByteArray &verifier)
{
    return base64Url(QCryptographicHash::hash(verifier, QCryptographicHash::Sha256));
}

void DiscordRpc::androidLoadTokens()
{
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    m_accessToken = s.value(QStringLiteral("discordAccessToken")).toString();
    m_refreshToken = s.value(QStringLiteral("discordRefreshToken")).toString();
    m_tokenExpiry = s.value(QStringLiteral("discordTokenExpiry")).toLongLong();
    m_pkceVerifier = s.value(QStringLiteral("discordPkceVerifier")).toString();
    m_authState = s.value(QStringLiteral("discordAuthState")).toString();
}

void DiscordRpc::androidSaveTokens()
{
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    s.setValue(QStringLiteral("discordAccessToken"), m_accessToken);
    s.setValue(QStringLiteral("discordRefreshToken"), m_refreshToken);
    s.setValue(QStringLiteral("discordTokenExpiry"), m_tokenExpiry);
}

#endif // Q_OS_ANDROID (helpers above); login API below has desktop fallbacks

QString DiscordRpc::authUrl()
{
#ifdef Q_OS_ANDROID
    m_pkceVerifier = QString::fromLatin1(makePkceVerifier());
    m_authState = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    s.setValue(QStringLiteral("discordPkceVerifier"), m_pkceVerifier);
    s.setValue(QStringLiteral("discordAuthState"), m_authState);

    QUrlQuery q;
    q.addQueryItem(QStringLiteral("response_type"), QStringLiteral("code"));
    q.addQueryItem(QStringLiteral("client_id"), m_clientId);
    q.addQueryItem(QStringLiteral("redirect_uri"), kRedirectUri);
    q.addQueryItem(QStringLiteral("scope"), kAuthScope);
    q.addQueryItem(QStringLiteral("code_challenge"),
                   QString::fromLatin1(makePkceChallenge(m_pkceVerifier.toLatin1())));
    q.addQueryItem(QStringLiteral("code_challenge_method"), QStringLiteral("S256"));
    q.addQueryItem(QStringLiteral("state"), m_authState);
    QUrl u(kAuthorizeUrl);
    u.setQuery(q);
    return u.toString(QUrl::FullyEncoded);
#else
    return QString();
#endif
}

bool DiscordRpc::handleAuthRedirect(const QString &url)
{
#ifdef Q_OS_ANDROID
    const QUrl u(url);
    if (u.scheme() != QLatin1String("lotustune"))
        return false;
    if (!((u.host() == QLatin1String("discord") && u.path() == QLatin1String("/callback"))
          || u.path() == QLatin1String("//discord/callback")))
        return false;

    const QUrlQuery q(u);
    if (q.hasQueryItem(QStringLiteral("error"))) {
        m_pkceVerifier.clear();
        m_authState.clear();
        QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
        s.remove(QStringLiteral("discordPkceVerifier"));
        s.remove(QStringLiteral("discordAuthState"));
        return true;
    }
    const QString code = q.queryItemValue(QStringLiteral("code"));
    if (code.isEmpty() || m_pkceVerifier.isEmpty())
        return false;
    if (!m_authState.isEmpty()
        && q.queryItemValue(QStringLiteral("state")) != m_authState)
        return false;

    QUrlQuery body;
    body.addQueryItem(QStringLiteral("client_id"), m_clientId);
    body.addQueryItem(QStringLiteral("grant_type"), QStringLiteral("authorization_code"));
    body.addQueryItem(QStringLiteral("code"), code);
    body.addQueryItem(QStringLiteral("redirect_uri"), kRedirectUri);
    body.addQueryItem(QStringLiteral("code_verifier"), m_pkceVerifier);
    androidRequestToken(body.toString(QUrl::FullyEncoded).toUtf8(), false);
    return true;
#else
    Q_UNUSED(url);
    return false;
#endif
}

bool DiscordRpc::takeAuthRedirect()
{
#ifdef Q_OS_ANDROID
    const QString path = QStandardPaths::writableLocation(
        QStandardPaths::AppLocalDataLocation)
        + QStringLiteral("/discord-redirect.txt");
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return false;
    const QString url = QString::fromUtf8(f.readAll()).trimmed();
    f.close();
    QFile::remove(path);
    if (!url.isEmpty())
        handleAuthRedirect(url);
    return !url.isEmpty();
#else
    return false;
#endif
}

bool DiscordRpc::isLoggedIn() const
{
#ifdef Q_OS_ANDROID
    return !m_accessToken.isEmpty() || !m_refreshToken.isEmpty();
#else
    return false;
#endif
}

#ifdef Q_OS_ANDROID

void DiscordRpc::androidRequestToken(const QByteArray &body, bool refresh)
{
    QNetworkRequest req{QUrl(kTokenUrl)};
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/x-www-form-urlencoded"));
    QNetworkReply *reply = m_net->post(req, body);
    reply->setProperty("discordRefresh", refresh);
    m_refreshing = refresh;
    setStatus(QStringLiteral("Conectando con Discord..."));
}

void DiscordRpc::androidOnTokenReply(QNetworkReply *reply)
{
    const bool refresh = reply->property("discordRefresh").toBool();
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QByteArray body = reply->readAll();
    reply->deleteLater();

    QJsonParseError pe;
    const QJsonDocument doc = QJsonDocument::fromJson(body, &pe);
    const QString access = doc.isObject()
        ? doc.object().value(QStringLiteral("access_token")).toString() : QString();
    if (status != 200 || pe.error != QJsonParseError::NoError || access.isEmpty()) {
        m_refreshing = false;
        if (m_enabled && m_accessToken.isEmpty())
            androidScheduleReconnect();
        return;
    }

    m_accessToken = access;
    const QString refreshTok =
        doc.object().value(QStringLiteral("refresh_token")).toString();
    if (!refreshTok.isEmpty())
        m_refreshToken = refreshTok;
    const int expires = doc.object().value(QStringLiteral("expires_in")).toInt();
    m_tokenExpiry = expires > 0
        ? QDateTime::currentMSecsSinceEpoch() + qint64(expires) * 1000 : 0;
    androidSaveTokens();
    m_refreshing = false;

    if (!refresh) {
        QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
        s.remove(QStringLiteral("discordPkceVerifier"));
        s.remove(QStringLiteral("discordAuthState"));
        m_pkceVerifier.clear();
        m_authState.clear();
    }
    if (m_enabled)
        androidConnectGateway();
}

void DiscordRpc::androidRefreshToken()
{
    if (m_refreshToken.isEmpty()) {
        m_accessToken.clear();
        m_refreshToken.clear();
        m_tokenExpiry = 0;
        androidSaveTokens();
        setStatus(QStringLiteral("Inicia sesión en Discord"));
        return;
    }
    QUrlQuery body;
    body.addQueryItem(QStringLiteral("client_id"), m_clientId);
    body.addQueryItem(QStringLiteral("grant_type"), QStringLiteral("refresh_token"));
    body.addQueryItem(QStringLiteral("refresh_token"), m_refreshToken);
    androidRequestToken(body.toString(QUrl::FullyEncoded).toUtf8(), true);
}

void DiscordRpc::androidApplyEnabled()
{
    m_reconnect.stop();
    m_heartbeat.stop();
    m_presenceTimer.stop();
    if (!m_enabled) {
        if (m_gateway)
            m_gateway->close();
        m_connected = false;
        setStatus(QStringLiteral("Desactivado"));
        return;
    }
    if (!isLoggedIn()) {
        if (m_gateway)
            m_gateway->close();
        m_connected = false;
        setStatus(QStringLiteral("Inicia sesión en Discord"));
        return;
    }
    m_backoffMs = 1000;
    androidConnectGateway();
}

void DiscordRpc::androidConnectGateway()
{
    if (!m_enabled || !m_gateway || !isLoggedIn() || m_refreshing)
        return;
    if (m_gateway->isActive())
        return;
    if (m_accessToken.isEmpty()
        || (m_tokenExpiry > 0
            && QDateTime::currentMSecsSinceEpoch() >= m_tokenExpiry - 60000)) {
        androidRefreshToken();
        return;
    }
    setStatus(QStringLiteral("Conectando con Discord..."));
    m_gateway->open();
}

void DiscordRpc::androidOnGatewayConnected()
{
    m_heartbeatAcked = true;
    androidSendIdentify();
    setStatus(QStringLiteral("Identificando con Discord..."));
}

void DiscordRpc::androidSendIdentify()
{
    QJsonObject props;
    props[QStringLiteral("$os")] = QStringLiteral("Android");
    props[QStringLiteral("$browser")] = QStringLiteral("lotus-tune");
    props[QStringLiteral("$device")] = QStringLiteral("lotus-tune");
    QJsonObject d;
    d[QStringLiteral("token")] = m_accessToken;
    d[QStringLiteral("properties")] = props;
    d[QStringLiteral("intents")] = 0;
    QJsonObject root;
    root[QStringLiteral("op")] = 2;
    root[QStringLiteral("d")] = d;
    m_gateway->sendText(QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact)));
}

void DiscordRpc::androidOnGatewayText(const QString &text)
{
    const QJsonDocument doc = QJsonDocument::fromJson(text.toUtf8());
    if (doc.isObject())
        androidHandlePayload(doc.object());
}

void DiscordRpc::androidHandlePayload(const QJsonObject &o)
{
    const int op = o.value(QStringLiteral("op")).toInt(-1);
    const QJsonValue dv = o.value(QStringLiteral("d"));
    if (o.contains(QStringLiteral("s")) && o.value(QStringLiteral("s")).isDouble())
        m_sequence = o.value(QStringLiteral("s")).toInt();

    if (op == 10 && dv.isObject()) {
        m_heartbeatIntervalMs = qMax<qint64>(1000,
            dv.toObject().value(QStringLiteral("heartbeat_interval")).toDouble());
        m_heartbeat.start(int(m_heartbeatIntervalMs));
        return;
    }
    if (op == 11) {
        m_heartbeatAcked = true;
        return;
    }
    if (op == 7 || op == 9) {
        androidScheduleReconnect();
        return;
    }
    if (op == 0 && dv.isObject()) {
        if (dv.toObject().value(QStringLiteral("t")).toString() == QLatin1String("READY")) {
            m_connected = true;
            m_backoffMs = 1000;
            setStatus(QStringLiteral("Conectado"));
            emit changed();
            androidSendPresence();
        }
    }
}

void DiscordRpc::androidHeartbeat()
{
    if (!m_gateway || !m_gateway->isActive())
        return;
    if (!m_heartbeatAcked) {   // zombied connection: Discord stopped answering
        setStatus(QStringLiteral("Reconectando..."));
        androidScheduleReconnect();
        return;
    }
    QJsonObject root;
    root[QStringLiteral("op")] = 1;
    root[QStringLiteral("d")] = m_sequence >= 0
        ? QJsonValue(qint64(m_sequence)) : QJsonValue(QJsonValue::Null);
    m_gateway->sendText(QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact)));
    m_heartbeatAcked = false;
    if (m_heartbeatIntervalMs > 0)
        m_heartbeat.start(int(m_heartbeatIntervalMs));
}

void DiscordRpc::androidScheduleReconnect()
{
    if (!m_enabled || !isLoggedIn())
        return;
    m_reconnect.stop();
    m_backoffMs = qMin(m_backoffMs * 2, 60000);
    m_reconnect.start(m_backoffMs);
    if (m_connected) {
        m_connected = false;
        emit changed();
    }
    setStatus(QStringLiteral("Reconectando..."));
}

void DiscordRpc::androidOnReconnect()
{
    if (!m_enabled)
        return;
    if (m_gateway)
        m_gateway->close();
    m_heartbeat.stop();
    if (m_tokenExpiry > 0
        && QDateTime::currentMSecsSinceEpoch() >= m_tokenExpiry - 60000)
        androidRefreshToken();
    else
        androidConnectGateway();
}

void DiscordRpc::androidOnGatewayDisconnected()
{
    m_heartbeat.stop();
    if (m_connected) {
        m_connected = false;
        emit changed();
    }
    if (!m_enabled)
        return;
    setStatus(QStringLiteral("Reconectando..."));
    androidScheduleReconnect();
}

void DiscordRpc::androidOnGatewayError(const QString &message)
{
    qWarning() << "[discord]" << message;   // socket error text only, never tokens
    if (m_enabled && m_gateway && !m_gateway->isActive())
        androidScheduleReconnect();
}

QJsonObject DiscordRpc::androidPresence() const
{
    QJsonArray activities;
    if (m_hasTrack)
        activities.append(buildActivity());
    QJsonObject d;
    d[QStringLiteral("since")] = 0;
    d[QStringLiteral("activities")] = activities;
    d[QStringLiteral("status")] = QStringLiteral("online");
    d[QStringLiteral("afk")] = false;
    return d;
}

void DiscordRpc::androidSendPresence()
{
    if (!m_connected)
        return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const qint64 elapsed = now - m_lastPresenceMs;
    if (m_lastPresenceMs == 0 || elapsed >= kPresenceIntervalMs) {
        androidSendPresenceNow();
        return;
    }
    if (!m_presenceTimer.isActive())
        m_presenceTimer.start(int(kPresenceIntervalMs - elapsed));
}

void DiscordRpc::androidSendPresenceNow()
{
    m_presenceTimer.stop();
    if (!m_connected || !m_gateway || !m_gateway->isActive())
        return;
    m_lastPresenceMs = QDateTime::currentMSecsSinceEpoch();
    QJsonObject root;
    root[QStringLiteral("op")] = 3;
    root[QStringLiteral("d")] = androidPresence();
    m_gateway->sendText(QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact)));
}

void DiscordRpc::androidCleanup()
{
    m_reconnect.stop();
    m_heartbeat.stop();
    m_presenceTimer.stop();
    if (m_gateway) {
        disconnect(m_gateway, nullptr, this, nullptr);
        m_gateway->close();
    }
    if (m_net)
        disconnect(m_net, nullptr, this, nullptr);
    m_connected = false;
}

#endif // Q_OS_ANDROID