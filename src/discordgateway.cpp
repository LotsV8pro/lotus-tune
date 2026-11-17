#include "discordgateway.h"

#include <QAbstractSocket>
#include <QCryptographicHash>
#include <QRandomGenerator>
#include <QSslSocket>
#include <QTimer>

namespace {

const QString kHost = QStringLiteral("gateway.discord.gg");
const quint16 kPort = 443;
const QByteArray kGuid = QByteArrayLiteral("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
const int kMaxFrame = 16 * 1024 * 1024;
const int kHandshakeTimeoutMs = 10000;

} // namespace

DiscordGateway::DiscordGateway(QObject *parent)
    : QObject(parent)
{
}

DiscordGateway::~DiscordGateway()
{
    if (m_socket)
        disconnect(m_socket, nullptr, this, nullptr);
    disconnect(this, nullptr, nullptr, nullptr);
    close();
}

bool DiscordGateway::isActive() const
{
    if (!m_socket)
        return false;
    const QAbstractSocket::SocketState st = m_socket->state();
    return st == QAbstractSocket::HostLookupState
        || st == QAbstractSocket::ConnectingState
        || st == QAbstractSocket::ConnectedState;
}

void DiscordGateway::open()
{
    if (isActive())
        return;

    if (!m_socket) {
        m_socket = new QSslSocket(this);
        m_socket->setPeerVerifyMode(QSslSocket::VerifyPeer);
        connect(m_socket, &QSslSocket::encrypted, this, &DiscordGateway::onEncrypted);
        connect(m_socket, &QAbstractSocket::readyRead, this, &DiscordGateway::onReadyRead);
        connect(m_socket, &QAbstractSocket::disconnected, this, &DiscordGateway::onSocketDisconnected);
        connect(m_socket, &QAbstractSocket::errorOccurred, this, &DiscordGateway::onSocketError);
        m_timeout = new QTimer(this);
        m_timeout->setSingleShot(true);
        connect(m_timeout, &QTimer::timeout, this, &DiscordGateway::onTimeout);
    }

    m_buf.clear();
    m_handshakeDone = false;

    QRandomGenerator *g = QRandomGenerator::global();
    QByteArray key(16, '\0');
    for (int i = 0; i < 16; ++i)
        key[i] = char(g->bounded(256));
    m_key = key.toBase64();

    m_timeout->start(kHandshakeTimeoutMs);
    m_socket->connectToHostEncrypted(kHost, kPort);
}

void DiscordGateway::close()
{
    if (!m_socket)
        return;
    m_suppressDisconnect = true;
    m_timeout->stop();
    m_socket->abort();
    m_suppressDisconnect = false;
    resetSession();
}

void DiscordGateway::sendText(const QString &text)
{
    sendFrame(0x1, text.toUtf8());
}

void DiscordGateway::onEncrypted()
{
    QByteArray req;
    req += "GET /?v=10&encoding=json HTTP/1.1\r\n";
    req += "Host: gateway.discord.gg\r\n";
    req += "Upgrade: websocket\r\n";
    req += "Connection: Upgrade\r\n";
    req += "Sec-WebSocket-Key: " + m_key + "\r\n";
    req += "Sec-WebSocket-Version: 13\r\n";
    req += "\r\n";
    m_socket->write(req);
}

void DiscordGateway::onReadyRead()
{
    m_buf.append(m_socket->readAll());

    if (!m_handshakeDone) {
        const int end = m_buf.indexOf("\r\n\r\n");
        if (end < 0) {
            if (m_buf.size() > 8192)
                fail(QStringLiteral("respuesta HTTP de Discord invalida"));
            return;
        }
        const QByteArray header = m_buf.left(end + 4);
        const QList<QByteArray> lines = header.split('\n');
        if (lines.isEmpty() || !lines.first().contains(" 101 ")) {
            fail(QStringLiteral("Discord no acepto la conexion WebSocket"));
            return;
        }
        QByteArray accept;
        for (const QByteArray &line : lines) {
            if (line.toLower().startsWith("sec-websocket-accept:")) {
                accept = line.mid(21).trimmed();
                break;
            }
        }
        const QByteArray expected =
            QCryptographicHash::hash(m_key + kGuid, QCryptographicHash::Sha1).toBase64();
        if (accept != expected) {
            fail(QStringLiteral("Sec-WebSocket-Accept incorrecto"));
            return;
        }
        m_buf.remove(0, end + 4);
        m_handshakeDone = true;
        m_timeout->stop();
        emit connected();
    }

    parseFrames();
}

void DiscordGateway::parseFrames()
{
    while (m_buf.size() >= 2) {
        const quint8 b0 = quint8(m_buf.at(0));
        const quint8 b1 = quint8(m_buf.at(1));
        const int opcode = b0 & 0x0f;
        const bool masked = (b1 & 0x80) != 0;
        quint64 len = b1 & 0x7f;
        int header = 2;

        if (len == 126) {
            if (m_buf.size() < 4)
                return;
            len = (quint64(quint8(m_buf.at(2))) << 8) | quint8(m_buf.at(3));
            header = 4;
        } else if (len == 127) {
            if (m_buf.size() < 10)
                return;
            len = 0;
            for (int i = 0; i < 8; ++i)
                len = (len << 8) | quint64(quint8(m_buf.at(2 + i)));
            header = 10;
        }
        if (len > kMaxFrame) {
            fail(QStringLiteral("trama WebSocket demasiado grande"));
            return;
        }
        if (masked)
            header += 4;
        if (quint64(m_buf.size()) < quint64(header) + len)
            return;

        const QByteArray mask = masked ? m_buf.mid(header - 4, 4) : QByteArray();
        QByteArray payload = m_buf.mid(header, int(len));
        m_buf.remove(0, header + int(len));
        for (int i = 0; masked && i < payload.size(); ++i)
            payload[i] = char(quint8(payload.at(i)) ^ quint8(mask.at(i % 4)));

        switch (opcode) {
        case 0x1: // text
            emit textMessage(QString::fromUtf8(payload));
            break;
        case 0x8: // close: the socket disconnect drives the reconnect
            m_socket->abort();
            return;
        case 0x9: // ping -> pong
            sendFrame(0xA, payload);
            break;
        default: // binary, pong, continuation: not used by the gateway
            break;
        }
    }
}

void DiscordGateway::sendFrame(int opcode, const QByteArray &payload)
{
    if (!m_socket || !m_handshakeDone
        || m_socket->state() != QAbstractSocket::ConnectedState)
        return;

    QByteArray frame;
    frame.append(char(0x80 | (opcode & 0x0f)));
    const quint64 len = quint64(payload.size());
    if (len < 126) {
        frame.append(char(0x80 | len));
    } else if (len <= 0xffff) {
        frame.append(char(0x80 | 126));
        frame.append(char((len >> 8) & 0xff));
        frame.append(char(len & 0xff));
    } else {
        frame.append(char(0x80 | 127));
        for (int i = 7; i >= 0; --i)
            frame.append(char((len >> (8 * i)) & 0xff));
    }

    QRandomGenerator *g = QRandomGenerator::global();
    QByteArray mask(4, '\0');
    for (int i = 0; i < 4; ++i)
        mask[i] = char(g->bounded(256));
    frame.append(mask);
    for (int i = 0; i < payload.size(); ++i)
        frame.append(char(quint8(payload.at(i)) ^ quint8(mask.at(i % 4))));

    m_socket->write(frame);
    m_socket->flush();
}

void DiscordGateway::fail(const QString &message)
{
    emit errorOccurred(message);
    close();
}

void DiscordGateway::resetSession()
{
    m_handshakeDone = false;
    m_buf.clear();
    if (m_timeout)
        m_timeout->stop();
}

void DiscordGateway::onSocketDisconnected()
{
    if (m_suppressDisconnect)
        return;
    resetSession();
    emit disconnected();
}

void DiscordGateway::onSocketError()
{
    if (m_suppressDisconnect || !m_socket)
        return;
    emit errorOccurred(m_socket->errorString());
}

void DiscordGateway::onTimeout()
{
    if (!m_handshakeDone)
        fail(QStringLiteral("tiempo de espera agotado al conectar con Discord"));
}
