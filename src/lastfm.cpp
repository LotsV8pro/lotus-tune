#include "lastfm.h"

#include <algorithm>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDebug>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSettings>
#include <QUrl>
#include <QUrlQuery>

static const char *kEndpoint = "https://ws.audioscrobbler.com/2.0/";
static const char *kSessionKey = "lastfmSessionKey";

LastFm::LastFm(QObject *parent)
    : QObject(parent)
    , m_net(new QNetworkAccessManager(this))
{
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    m_sessionKey = s.value(QLatin1String(kSessionKey)).toString();
    m_apiKey = s.value(QStringLiteral("lastfmApiKey")).toString();
    m_secret = s.value(QStringLiteral("lastfmSecret")).toString();
    m_username = s.value(QStringLiteral("lastfmUsername")).toString();
    m_enabled = s.value(QStringLiteral("lastfmEnabled"), false).toBool();
}

LastFm::~LastFm() = default;

void LastFm::setEnabled(bool v)
{
    if (m_enabled == v)
        return;
    m_enabled = v;
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    s.setValue(QStringLiteral("lastfmEnabled"), v);
    s.sync();
    emit enabledChanged();
}

QString LastFm::md5(const QString &input)
{
    return QString::fromLatin1(QCryptographicHash::hash(
        input.toUtf8(), QCryptographicHash::Md5).toHex());
}

// Last.fm 2.0 signature: params sorted by name, each name+value concatenated,
// then the shared secret appended.
QByteArray LastFm::sign(const QList<QPair<QString, QString>> &params,
                        const QString &secret)
{
    QList<QPair<QString, QString>> sorted = params;
    std::sort(sorted.begin(), sorted.end(),
              [](const QPair<QString, QString> &a, const QPair<QString, QString> &b) {
                  return a.first < b.first;
              });
    QString payload;
    for (const auto &p : sorted)
        payload += p.first + p.second;
    payload += secret;
    return md5(payload).toLatin1();
}

bool LastFm::authenticate(const QString &username, const QString &password,
                          const QString &apiKey, const QString &secret)
{
    if (username.trimmed().isEmpty() || password.isEmpty()
        || apiKey.trimmed().isEmpty() || secret.trimmed().isEmpty()) {
        emit status(tr("Faltan credenciales de Last.fm"));
        return false;
    }
    QList<QPair<QString, QString>> params = {
        {QStringLiteral("api_key"), apiKey.trimmed()},
        {QStringLiteral("method"), QStringLiteral("auth.getMobileSession")},
        {QStringLiteral("password"), password},
        {QStringLiteral("username"), username.trimmed()},
    };
    params.append({QStringLiteral("api_sig"), QString::fromLatin1(sign(params, secret))});

    QUrlQuery query;
    for (const auto &p : params)
        query.addQueryItem(p.first, p.second);
    QNetworkRequest req = QNetworkRequest(QUrl(QLatin1String(kEndpoint)));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/x-www-form-urlencoded"));
    QNetworkReply *reply = m_net->post(req, query.toString(QUrl::FullyEncoded).toUtf8());
    // stash the secret until the reply arrives (needed for scrobble signature)
    m_secret = secret;
    m_apiKey = apiKey.trimmed();
    m_username = username.trimmed();
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleReply(reply, QStringLiteral("auth"));
    });
    emit status(tr("Conectando con Last.fm…"));
    return true;
}

bool LastFm::scrobble(const QString &artist, const QString &title,
                      double duration, double playTime)
{
    if (!m_enabled || m_sessionKey.isEmpty() || artist.trimmed().isEmpty()
        || title.trimmed().isEmpty())
        return false;
    // Last.fm rule: longer than 30 s and at least half played, or 4 min.
    if (duration <= 30.0 || playTime < 4.0 * 60.0
        && playTime < duration / 2.0)
        return false;

    const qlonglong timestamp =
        QDateTime::currentSecsSinceEpoch() - static_cast<qlonglong>(playTime);
    QList<QPair<QString, QString>> params = {
        {QStringLiteral("api_key"), m_apiKey},
        {QStringLiteral("artist"), artist.trimmed()},
        {QStringLiteral("method"), QStringLiteral("track.scrobble")},
        {QStringLiteral("sk"), m_sessionKey},
        {QStringLiteral("timestamp"), QString::number(timestamp)},
        {QStringLiteral("track"), title.trimmed()},
    };
    params.append({QStringLiteral("api_sig"), QString::fromLatin1(sign(params, m_secret))});

    QUrlQuery query;
    for (const auto &p : params)
        query.addQueryItem(p.first, p.second);
    QNetworkRequest req = QNetworkRequest(QUrl(QLatin1String(kEndpoint)));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/x-www-form-urlencoded"));
    QNetworkReply *reply = m_net->post(req, query.toString(QUrl::FullyEncoded).toUtf8());
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleReply(reply, QStringLiteral("scrobble"));
    });
    return true;
}

void LastFm::nowPlaying(const QString &artist, const QString &title)
{
    if (!m_enabled || m_sessionKey.isEmpty() || artist.trimmed().isEmpty()
        || title.trimmed().isEmpty())
        return;
    QList<QPair<QString, QString>> params = {
        {QStringLiteral("api_key"), m_apiKey},
        {QStringLiteral("artist"), artist.trimmed()},
        {QStringLiteral("method"), QStringLiteral("track.updateNowPlaying")},
        {QStringLiteral("sk"), m_sessionKey},
        {QStringLiteral("track"), title.trimmed()},
    };
    params.append({QStringLiteral("api_sig"), QString::fromLatin1(sign(params, m_secret))});
    QUrlQuery query;
    for (const auto &p : params)
        query.addQueryItem(p.first, p.second);
    QNetworkRequest req = QNetworkRequest(QUrl(QLatin1String(kEndpoint)));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/x-www-form-urlencoded"));
    QNetworkReply *reply = m_net->post(req, query.toString(QUrl::FullyEncoded).toUtf8());
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        handleReply(reply, QStringLiteral("nowplaying"));
    });
}

void LastFm::handleReply(QNetworkReply *reply, const QString &kind)
{
    reply->deleteLater();
    const QByteArray body = reply->readAll();
    if (reply->error() != QNetworkReply::NoError) {
        qWarning() << "[lastfm] network error" << reply->error() << body;
        emit status(tr("Error de red al contactar con Last.fm"));
        return;
    }
    const QString xml = QString::fromUtf8(body);
    // Last.fm may reorder attributes; read the code instead of matching a
    // literal substring.
    const QRegularExpression errRe(QStringLiteral("<error[^>]*\\bcode=\"(\\d+)\""));
    const QRegularExpressionMatch errMatch = errRe.match(xml);
    const bool invalidSession = errMatch.hasMatch() && errMatch.captured(1).toInt() == 9;
    if (invalidSession) {
        // Invalid session key: revoke it and make the user reconnect.
        m_sessionKey.clear();
        QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
        s.remove(QLatin1String(kSessionKey));
        s.sync();
        emit authenticatedChanged();
        emit status(tr("Sesión de Last.fm caducada; vuelve a conectar"));
        return;
    }
    if (xml.contains(QLatin1String("<error"))) {
        const int at = xml.indexOf(QLatin1String("<error"));
        const int end = xml.indexOf(QLatin1Char('>'), at);
        qWarning() << "[lastfm] api error" << xml.mid(at, end - at + 1);
        emit status(tr("Last.fm rechazó la petición"));
        return;
    }
    if (kind == QLatin1String("auth")) {
        const int a = xml.indexOf(QLatin1String("<key>"));
        const int b = xml.indexOf(QLatin1String("</key>"));
        if (a < 0 || b < 0) {
            emit status(tr("Last.fm no devolvió una clave de sesión"));
            return;
        }
        m_sessionKey = xml.mid(a + 5, b - a - 5);
        QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
        s.setValue(QLatin1String(kSessionKey), m_sessionKey);
        s.setValue(QStringLiteral("lastfmApiKey"), m_apiKey);
        s.setValue(QStringLiteral("lastfmSecret"), m_secret);
        s.setValue(QStringLiteral("lastfmUsername"), m_username);
        s.sync();
        emit authenticatedChanged();
        emit status(tr("Conectado con Last.fm"));
    }
}
