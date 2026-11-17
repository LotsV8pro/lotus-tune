#pragma once

#include <QByteArray>
#include <QObject>
#include <QString>

class QSslSocket;
class QTimer;

// Minimal RFC 6455 client for Discord's gateway. The Android Qt kit has no
// QtWebSockets module, so this uses QSslSocket directly: TLS, the HTTP
// Upgrade handshake, masked client text frames, and unmasked server frames
// (text, ping, close). No local IPC and no Discord app data are involved.
class DiscordGateway : public QObject
{
    Q_OBJECT
public:
    explicit DiscordGateway(QObject *parent = nullptr);
    ~DiscordGateway() override;

    // TLS connect to wss://gateway.discord.gg/?v=10&encoding=json.
    void open();
    // Silent close: does not emit disconnected().
    void close();
    // Send one masked text frame.
    void sendText(const QString &text);
    // True while connecting or open.
    bool isActive() const;

signals:
    void connected();                       // HTTP 101 upgrade done
    void textMessage(const QString &message);
    void disconnected();
    void errorOccurred(const QString &message);

private slots:
    void onEncrypted();
    void onReadyRead();
    void onSocketDisconnected();
    void onSocketError();
    void onTimeout();

private:
    void parseFrames();
    void sendFrame(int opcode, const QByteArray &payload);
    void fail(const QString &message);
    void resetSession();

    QSslSocket *m_socket = nullptr;
    QTimer *m_timeout = nullptr;
    QByteArray m_buf;
    QByteArray m_key;
    bool m_handshakeDone = false;
    bool m_suppressDisconnect = false;
};
