#include "updates.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrl>

namespace {

// Where the releases are published.
const char *kRepo = "LotsV8pro/lotus-tune";
// The list of releases (not "latest"): the pre-releases do not come in
// "latest" and they are published too.
const char *kApi = "https://api.github.com/repos/LotsV8pro/lotus-tune/releases";

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

// The artifact of THIS platform: Android looks for the .apk, Windows for
// its .exe/.zip and Linux for its AppImage/tarball. A release without that
// artifact is not an update for this app (it is for another platform).
bool assetMatches(const QString &nameIn)
{
    const QString name = nameIn.trimmed().toLower();
    if (name.isEmpty())
        return false;
#if defined(Q_OS_ANDROID)
    return name.endsWith(QLatin1String(".apk"));
#elif defined(Q_OS_WIN)
    if (!name.contains(QLatin1String("win")))
        return false;
    return name.endsWith(QLatin1String(".exe"))
           || name.endsWith(QLatin1String(".zip"))
           || name.endsWith(QLatin1String(".msi"));
#else
    // Linux (and the other unices): never pick a Windows or an Android
    // build by mistake.
    if (name.contains(QLatin1String("win")) || name.endsWith(QLatin1String(".apk")))
        return false;
    return name.contains(QLatin1String("linux"))
           || name.contains(QLatin1String("appimage"))
           || name.endsWith(QLatin1String(".appimage"))
           || name.endsWith(QLatin1String(".deb"))
           || name.endsWith(QLatin1String(".rpm"))
           || name.endsWith(QLatin1String(".tar.gz"))
           || name.endsWith(QLatin1String(".tar.xz"))
           || name.endsWith(QLatin1String(".zip"));
#endif
}

// The name of this platform, for the messages.
QString platformName()
{
#if defined(Q_OS_ANDROID)
    return QStringLiteral("Android");
#elif defined(Q_OS_WIN)
    return QStringLiteral("Windows");
#elif defined(Q_OS_MACOS)
    return QStringLiteral("macOS");
#else
    return QStringLiteral("Linux");
#endif
}

// Compares two versions ("1.10.0" is newer than "1.9.0"). A version
// without a suffix is newer than the same one with one (1.0.0 > 1.0.0-rc1).
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
    const bool candRc = candidate.contains(QLatin1Char('-'));
    const bool currRc = current.contains(QLatin1Char('-'));
    if (candRc != currRc)
        return !candRc;
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
    // A private repository needs a token; a public one does not.
    const QString token = qEnvironmentVariable("LOTUS_TUNE_GITHUB_TOKEN");
    if (!token.isEmpty())
        req.setRawHeader("Authorization", QByteArray("Bearer ") + token.toUtf8());
    QNetworkReply *reply = net->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, net]() {
        reply->deleteLater();
        net->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            m_error = reply->errorString();
            qInfo().noquote() << QString("[updates] no se pudo consultar: %1")
                                    .arg(m_error);
            emit changed();
            return;
        }
        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        QJsonArray list;
        if (doc.isArray())
            list = doc.array();
        else if (doc.isObject())
            list.append(doc.object());
        if (list.isEmpty()) {
            m_error = QStringLiteral("No hay ninguna versión publicada");
            emit changed();
            return;
        }

        // Only the releases that carry THIS platform's file count: the
        // newest one may be an APK (it says nothing to the desktop) or a
        // Windows build. Among the ones that do, the highest version wins
        // (the list is ordered by publication date, not by version).
        QString tag, url, page, notes, asset;
        QString best;
        for (const QJsonValue &v : list) {
            const QJsonObject rel = v.toObject();
            const QString t = rel.value(QStringLiteral("tag_name")).toString();
            if (t.isEmpty())
                continue;
            QString artifact, link;
            for (const QJsonValue &av :
                 rel.value(QStringLiteral("assets")).toArray()) {
                const QJsonObject a = av.toObject();
                const QString n = a.value(QStringLiteral("name")).toString();
                if (!assetMatches(n))
                    continue;
                artifact = n;
                link = a.value(QStringLiteral("browser_download_url")).toString();
                break;
            }
            if (link.isEmpty())
                continue;   // this release is for another platform
            if (!best.isEmpty() && !isNewer(t, best))
                continue;
            best = t;
            tag = t;
            url = link;
            page = rel.value(QStringLiteral("html_url")).toString();
            notes = rel.value(QStringLiteral("body")).toString().simplified();
            asset = artifact;
        }
        if (tag.isEmpty()) {
            m_latest.clear();
            m_url.clear();
            m_notes.clear();
            m_available = false;
            m_error = QStringLiteral("Todavía no hay ninguna versión publicada para ")
                      + platformName();
            qInfo().noquote() << QStringLiteral("[updates] sin versión para %1, en uso %2")
                                     .arg(platformName(), currentVersion());
            emit changed();
            return;
        }
        m_latest = tag;
        m_url = url;
        m_page = page;
        m_notes = notes;
        m_asset = asset;
        m_error.clear();
        m_available = isNewer(m_latest, currentVersion());
        qInfo().noquote() << QString("[updates] %1: publicada %2 (%3), en uso %4%5")
                                .arg(platformName(), m_latest, m_asset,
                                     currentVersion(),
                                     m_available ? QStringLiteral(" (hay una nueva)")
                                                 : QString());
        emit changed();
    });
}

void Updates::openDownload()
{
    // The file of this platform (the .apk on Android, the tarball/AppImage
    // on Linux, the .exe/.zip on Windows): the asset itself, not the page
    // of the release, so the download starts with one click.
    const QString target = m_url.isEmpty() ? m_page : m_url;
    if (target.isEmpty())
        return;
    QDesktopServices::openUrl(QUrl(target));
}
