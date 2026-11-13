#include "updates.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>
#include <QVector>

#if defined(Q_OS_ANDROID)
#include <QJniObject>
#endif

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

#if defined(Q_OS_ANDROID)
// The phone's notification shade. The app is closed most of the time, and a
// notice that only exists inside it is a notice nobody sees. The Java side
// keeps the version that was already told and opens the .apk of the release
// when the notification is tapped.
void notifyAndroid(const QString &version, const QString &url)
{
    const QJniObject context = QJniObject::callStaticObjectMethod(
        "com/lotustuneremote/app/MainActivity", "appContext",
        "()Landroid/content/Context;");
    if (!context.isValid())
        return;
    const QJniObject jVersion = QJniObject::fromString(version);
    const QJniObject jUrl = QJniObject::fromString(url);
    QJniObject::callStaticMethod<void>(
        "com/lotustuneremote/app/UpdateNotifier", "notifyUpdate",
        "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;)V",
        context.object(), jVersion.object(), jUrl.object());
}
#endif

#if defined(Q_OS_LINUX) && !defined(Q_OS_ANDROID)
// On Linux the update is not a file to download but the command that builds
// the new version and installs it over the one that is running: the same
// installer the README gives. It runs in a terminal because the build prints
// its progress and takes a few minutes; the window stays open at the end so
// the result can be read.
bool runUpdateInTerminal()
{
    // The two messages go inside single quotes of a bash command: they must
    // not carry one ("don't" would close the string and break the line).
    const QString done = QCoreApplication::translate(
        "Updates", "Listo. Abre Lotus Tune otra vez.");
    const QString wait = QCoreApplication::translate(
        "Updates", "Pulsa una tecla para cerrar.");
    const QString command =
        QStringLiteral("curl -fsSL %1 | bash; printf '\\n%2\\n'; "
                       "read -r -n 1 -p '%3' _")
            .arg(QStringLiteral(
                     "https://raw.githubusercontent.com/LotsV8pro/lotus-tune/master/tools/install.sh"),
                 done, wait);

    // The terminal of the session, in the order in which a desktop usually
    // has them. Each one takes the command after its own flag.
    const QVector<QPair<QString, QStringList>> terminals = {
        { QStringLiteral("foot"),           {} },
        { QStringLiteral("kitty"),          {} },
        { QStringLiteral("alacritty"),      { QStringLiteral("-e") } },
        { QStringLiteral("wezterm"),        { QStringLiteral("start"), QStringLiteral("--") } },
        { QStringLiteral("konsole"),        { QStringLiteral("-e") } },
        { QStringLiteral("gnome-terminal"), { QStringLiteral("--") } },
        { QStringLiteral("xfce4-terminal"), { QStringLiteral("-x") } },
        { QStringLiteral("xterm"),          { QStringLiteral("-e") } },
    };
    for (const auto &t : terminals) {
        if (QStandardPaths::findExecutable(t.first).isEmpty())
            continue;
        QStringList args = t.second;
        args << QStringLiteral("bash") << QStringLiteral("-c") << command;
        if (QProcess::startDetached(t.first, args, QDir::homePath()))
            return true;
    }
    return false;
}
#endif

#if defined(Q_OS_WIN)
// Windows: there is no installer, the release is a zip with the .exe and the
// Qt libraries next to it. The update is run by a PowerShell window that
// downloads the zip, waits for this copy of the app to close (an .exe cannot
// be replaced while it is running), unpacks it over the folder of the app and
// opens it again. The window is left visible so the progress (and any error)
// can be read.
bool runWindowsUpdate(const QString &zipUrl)
{
    if (zipUrl.isEmpty())
        return false;
    const QString dir = QDir::toNativeSeparators(
        QCoreApplication::applicationDirPath());
    // Same as above: these texts sit inside single quotes of PowerShell, so
    // they must not contain one.
    const QString downloading = QCoreApplication::translate(
        "Updates", "Descargando la versión nueva…");
    const QString done = QCoreApplication::translate(
        "Updates", "Listo: la versión nueva está abierta.");
    const QString failed = QCoreApplication::translate(
        "Updates", "No se pudo actualizar: ");
    const QString wait = QCoreApplication::translate(
        "Updates", "Pulsa Intro para cerrar");
    const QString script = QStringLiteral(
        "$ErrorActionPreference='Stop'; "
        "$zip=Join-Path $env:TEMP 'lotus-tune-windows.zip'; "
        "Write-Host '%3'; "
        "try { "
        "Invoke-WebRequest -Uri '%1' -OutFile $zip -UseBasicParsing; "
        "Get-Process lotus-tune -ErrorAction SilentlyContinue | Wait-Process; "
        "Expand-Archive -Force -Path $zip -DestinationPath '%2'; "
        "Start-Process (Join-Path '%2' 'lotus-tune.exe'); "
        "Write-Host '%4' "
        "} catch { Write-Host ('%5' + $_); "
        "Read-Host '%6' }")
        .arg(zipUrl, dir, downloading, done, failed, wait);
    const bool started = QProcess::startDetached(
        QStringLiteral("cmd.exe"),
        { QStringLiteral("/c"), QStringLiteral("start"), QString(),
          QStringLiteral("powershell"), QStringLiteral("-NoExit"),
          QStringLiteral("-Command"), script });
    if (started) {
        // This copy has to go away: the files are replaced once it closes.
        QTimer::singleShot(1200, qApp, &QCoreApplication::quit);
    }
    return started;
}
#endif

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
            m_error = tr("No hay ninguna versión publicada");
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
            m_error = tr("Todavía no hay ninguna versión publicada para %1")
                          .arg(platformName());
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
#if defined(Q_OS_ANDROID)
        if (m_available)
            notifyAndroid(m_latest, m_url);
#endif
        emit changed();
    });
}

void Updates::openDownload()
{
#if defined(Q_OS_LINUX) && !defined(Q_OS_ANDROID)
    // Linux: the update is the installer (it builds the new version and
    // installs it over the running one). Only when the session has no
    // terminal the download page is opened, so the user is never stuck.
    if (runUpdateInTerminal())
        return;
#endif
#if defined(Q_OS_WIN)
    // Windows: the zip is downloaded and unpacked over this folder, and the
    // app opens again on its own (there is no installer).
    if (runWindowsUpdate(m_url))
        return;
#endif
    // Android (and the fallbacks): the file of the platform, not the page of
    // the release, so the download starts with one click.
    const QString target = m_url.isEmpty() ? m_page : m_url;
    if (target.isEmpty())
        return;
    QDesktopServices::openUrl(QUrl(target));
}
