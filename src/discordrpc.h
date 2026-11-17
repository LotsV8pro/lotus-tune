#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QTimer>

class QLocalSocket;
class QTimer;
class QNetworkAccessManager;
class QNetworkReply;
class DiscordGateway;

// Discord Rich Presence. Desktop uses the local IPC socket ("discord-ipc-N").
//
// It speaks Discord's native protocol without external libraries: it
// discovers the client's pipe, does the handshake (opcode 0) and sends
// SET_ACTIVITY (opcode 1). It shows the song, the artist, the artwork
// and the progress bar, in the style of players like Sonora.
//
// The parent registers it as the `discord` context property; Settings
// calls configure() and the playback UI calls setActivity()/clear().
class DiscordRpc : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled NOTIFY changed)
    Q_PROPERTY(bool connected READ connected NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(bool loggedIn READ isLoggedIn NOTIFY changed)

public:
    explicit DiscordRpc(QObject *parent = nullptr);
    ~DiscordRpc() override;

    bool enabled() const { return m_enabled; }
    bool connected() const { return m_connected; }
    QString status() const { return m_status; }

    // Called from Settings. It persists enabled/clientId in QSettings
     // ("lotus-tune"/"lotus-tune", the same keys AppConfig uses) so
     // they survive a restart. If clientId is empty the current one is
     // kept.
    Q_INVOKABLE void configure(bool enabled, const QString &clientId);

    // Publishes the current track. It ignores repeated calls so it does
     // not flood Discord's IPC: it only resends when the track/state
     // changes or when the position jumps (a seek) by more than a few
     // seconds.
    Q_INVOKABLE void setActivity(const QString &title, const QString &artist,
                                 const QString &album, const QString &thumbUrl,
                                 double positionSeconds, double durationSeconds,
                                 bool playing);

    // Clears the presence (SET_ACTIVITY with activity = null).
    Q_INVOKABLE void clear();

    // --- Android OAuth2 PKCE login. On desktop these are no-ops. ---
    // Returns the Discord authorization URL to open in a browser. Generates
    // and persists a fresh PKCE verifier and state; call this first.
    Q_INVOKABLE QString authUrl();

    // Pass a lotustune://discord/callback?code=...&state=... redirect here.
    // Exchanges the code for tokens asynchronously. Returns true when the
    // URL is a valid callback, even if the exchange is still in flight.
    Q_INVOKABLE bool handleAuthRedirect(const QString &url);

    // True when an access or refresh token is stored.
    Q_INVOKABLE bool isLoggedIn() const;

    // The Android activity writes the lotustune:// callback to a small
    // file (it cannot call a Qt slot directly). QML calls this to hand
    // it over; desktop is a no-op.
    Q_INVOKABLE bool takeAuthRedirect();

signals:
    void changed();

private slots:
    void tryConnect();
    void onConnected();
    void onDisconnected();
    void onErrorOccurred();
    void onReadyRead();
#ifdef Q_OS_ANDROID
    void androidOnGatewayConnected();
    void androidOnGatewayDisconnected();
    void androidOnGatewayText(const QString &text);
    void androidOnGatewayError(const QString &message);
    void androidOnReconnect();
    void androidHeartbeat();
    void androidSendPresenceNow();
    void androidOnTokenReply(QNetworkReply *reply);
#endif

private:
    void setStatus(const QString &s);
    static QStringList socketPaths();
    void sendFrame(int opcode, const QByteArray &payload);
    void sendHandshake();
    void sendActivity(bool nullActivity);
    QJsonObject buildActivity() const;

    QLocalSocket *m_socket = nullptr;
    QTimer m_reconnect;              // retry / watchdog every 15 s
    bool m_enabled = false;
    bool m_connected = false;
    QString m_status;
    QString m_clientId;

    // Last activity asked for by setActivity().
    QString m_title;
    QString m_artist;
    QString m_album;
    QString m_thumb;
    double m_position = 0.0;
    double m_duration = 0.0;
    bool m_playing = false;
    bool m_hasTrack = false;

    // Last activity actually sent (for deduplication).
    QString m_sentTitle;
    QString m_sentArtist;
    QString m_sentAlbum;
    QString m_sentThumb;
    bool m_sentPlaying = false;
    bool m_sentValid = false;
    double m_sentPosition = 0.0;

    QByteArray m_buf;                // accumulator of partial reads

#ifdef Q_OS_ANDROID
    // OAuth2 PKCE + gateway client. No QLocalSocket is used on Android.
    void androidLoadTokens();
    void androidSaveTokens();
    void androidApplyEnabled();
    void androidConnectGateway();
    void androidCleanup();
    void androidRefreshToken();
    void androidRequestToken(const QByteArray &body, bool refresh);
    void androidScheduleReconnect();
    void androidSendIdentify();
    void androidSendPresence();
    void androidHandlePayload(const QJsonObject &payload);
    QJsonObject androidPresence() const;
    static QByteArray makePkceVerifier();
    static QByteArray makePkceChallenge(const QByteArray &verifier);
    static QByteArray base64Url(const QByteArray &raw);

    DiscordGateway *m_gateway = nullptr;
    QNetworkAccessManager *m_net = nullptr;
    QTimer m_heartbeat;
    QTimer m_presenceTimer;
    QString m_accessToken;
    QString m_refreshToken;
    QString m_pkceVerifier;
    QString m_authState;
    qint64 m_tokenExpiry = 0;
    qint64 m_lastPresenceMs = 0;
    qint64 m_heartbeatIntervalMs = 0;
    bool m_heartbeatAcked = true;
    bool m_refreshing = false;
    int m_sequence = -1;
    int m_backoffMs = 1000;
#endif
};