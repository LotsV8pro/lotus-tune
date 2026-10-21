#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QTimer>

class QLocalSocket;

// Discord Rich Presence over the local IPC socket ("discord-ipc-N").
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

    // Borra la presencia (SET_ACTIVITY con activity = null).
    Q_INVOKABLE void clear();

signals:
    void changed();

private slots:
    void tryConnect();
    void onConnected();
    void onDisconnected();
    void onErrorOccurred();
    void onReadyRead();

private:
    void setStatus(const QString &s);
    static QStringList socketPaths();
    void sendFrame(int opcode, const QByteArray &payload);
    void sendHandshake();
    void sendActivity(bool nullActivity);
    QJsonObject buildActivity() const;

    QLocalSocket *m_socket = nullptr;
    QTimer m_reconnect;              // reintento / watchdog cada 15 s
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

    QByteArray m_buf;                // acumulador de lecturas parciales
};