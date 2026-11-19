#pragma once

#include <QObject>
#include <QString>

class QNetworkAccessManager;
class QNetworkReply;

// Last.fm scrobbling (API 2.0). Session key lives in QSettings under the
// `lastfmSessionKey` app key; credentials are never stored here.
class LastFm : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(bool authenticated READ authenticated NOTIFY authenticatedChanged)
    Q_PROPERTY(QString username READ username CONSTANT)
    Q_PROPERTY(QString apiKey READ apiKey CONSTANT)
    Q_PROPERTY(QString secret READ secret CONSTANT)

public:
    explicit LastFm(QObject *parent = nullptr);
    ~LastFm() override;

    bool enabled() const { return m_enabled; }
    void setEnabled(bool v);
    bool authenticated() const { return !m_sessionKey.isEmpty(); }
    QString username() const { return m_username; }
    QString apiKey() const { return m_apiKey; }
    QString secret() const { return m_secret; }

    Q_INVOKABLE bool authenticate(const QString &username, const QString &password,
                                  const QString &apiKey, const QString &secret);
    Q_INVOKABLE bool scrobble(const QString &artist, const QString &title,
                              double duration, double playTime);
    Q_INVOKABLE void nowPlaying(const QString &artist, const QString &title);

signals:
    void enabledChanged();
    void authenticatedChanged();
    void status(const QString &message);

private:
    static QString md5(const QString &input);
    static QByteArray sign(const QList<QPair<QString, QString>> &params,
                           const QString &secret);
    void handleReply(QNetworkReply *reply, const QString &kind);

    QNetworkAccessManager *m_net = nullptr;
    QString m_sessionKey;
    QString m_apiKey;
    QString m_secret;
    QString m_username;
    bool m_enabled = false;
};
