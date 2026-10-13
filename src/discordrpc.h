#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QTimer>

class QLocalSocket;

// Discord Rich Presence sobre el socket IPC local ("discord-ipc-N").
//
// Habla el protocolo nativo de Discord sin librerías externas: descubre el
// pipe del cliente, hace el handshake (opcode 0) y envía SET_ACTIVITY
// (opcode 1). Muestra canción, artista, portada y barra de progreso, al
// estilo de reproductores como Sonora.
//
// El padre lo registra como context property `discord`; Ajustes llama a
// configure() y la UI de reproducción a setActivity()/clear().
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

    // Llamado desde Ajustes. Persiste enabled/clientId en QSettings
    // ("lotus-tune"/"lotus-tune", mismas claves que usa AppConfig) para que
    // sobrevivan al reinicio. Si clientId está vacío se conserva el actual.
    Q_INVOKABLE void configure(bool enabled, const QString &clientId);

    // Publica la pista actual. Ignora llamadas repetidas para no saturar el
    // IPC de Discord: sólo reenvía cuando cambia la pista/estado o cuando la
    // posición salta (seek) más de unos segundos.
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

    // Última actividad pedida por setActivity().
    QString m_title;
    QString m_artist;
    QString m_album;
    QString m_thumb;
    double m_position = 0.0;
    double m_duration = 0.0;
    bool m_playing = false;
    bool m_hasTrack = false;

    // Última actividad realmente enviada (para deduplicar).
    QString m_sentTitle;
    QString m_sentArtist;
    QString m_sentAlbum;
    QString m_sentThumb;
    bool m_sentPlaying = false;
    bool m_sentValid = false;
    double m_sentPosition = 0.0;

    QByteArray m_buf;                // acumulador de lecturas parciales
};