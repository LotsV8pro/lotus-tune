#include "updates.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrl>

namespace {

// Where the releases are published.
const char *kRepo = "LotsV8pro/lotus-tune";
const char *kApi = "https://api.github.com/repos/LotsV8pro/lotus-tune/releases/latest";

// The version of the release, without the "v" and the pre-release part
// ("1.2.0-beta.3" -> "1.2.0").
QString versionOf(const QString &raw)
{
    QString v = raw.trimmed();
    if (v.startsWith(QLatin1Char('v')))
        v = v.mid(1);
    const int dash = v.indexOf(QLatin1Char('-'));
    if (dash > 0)
        v = v.left(dash);
    return v;
}

// Compares two versions ("1.10.0" is newer than "1.9.0").
bool isNewer(const QString &candidate, const QString &current)
{
    const QStringList a = versionOf(candidate).split(QLatin1Char('.'));
    const QStringList b = versionOf(current).split(QLatin1Char('.'));
    for (int i = 0; i < qMax(a.size(), b.size()); ++i) {
        const int x = i < a.size() ? a.at(i).toInt() : 0;
        const int y = i < b.size() ? b.at(i).toInt() : 0;
        if (x != y)
            return x > y;
    }
    return false;
}

} // namespace

Updates::Updates(QObject *parent)
    : QObject(parent)
{
}

QString Updates::currentVersion() const
{
    const QString v = QCoreApplication::applicationVersion();
    return v.isEmpty() ? QStringLiteral("1.0.0") : v;
}

void Updates::check()
{
    m_error.clear();
    qInfo().noquote() << QString("[updates] buscando la ultima version en %1")
                            .arg(QString::fromLatin1(kRepo));
    QNetworkAccessManager *net = new QNetworkAccessManager(this);
    QNetworkRequest req(QUrl(QString::fromLatin1(kApi)));
    req.setRawHeader("Accept", "application/vnd.github+json");
    req.setRawHeader("User-Agent", "LotusTune");
    QNetworkReply *reply = net->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, net]() {
        reply->deleteLater();
        net->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            m_error = reply->errorString();
            emit changed();
            return;
        }
        const QJsonObject root =
            QJsonDocument::fromJson(reply->readAll()).object();
        const QString tag = root.value(QStringLiteral("tag_name")).toString();
        if (tag.isEmpty()) {
            m_error = QStringLiteral("No se ha podido leer la versión");
            emit changed();
            return;
        }
        m_latest = tag;
        m_url = root.value(QStringLiteral("html_url")).toString();
        m_notes = root.value(QStringLiteral("body")).toString().simplified();
        m_available = isNewer(m_latest, currentVersion());
        qInfo().noquote() << QString("[updates] publicada %1, en uso %2%3")
                                .arg(m_latest, currentVersion(),
                                     m_available ? QStringLiteral(" (hay una nueva)")
                                                 : QString());
        emit changed();
    });
}

void Updates::openDownload()
{
    if (m_url.isEmpty())
        return;
    QDesktopServices::openUrl(QUrl(m_url));
}
