#include "appconfig.h"
#include "paths.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QFileInfo>
#include <QSettings>
#include <QStandardPaths>
#include <QTextStream>

#include <QDebug>

static const char *kThemeKeys[] = {
    "accent", "bg", "surface", "surfaceAlt", "border", "borderSubtle",
    "onAccent", "text", "textDim", "danger", "followSystem",
};

static const char *kAppKeys[] = {
    "cookiesFromBrowser", "spotifyClientId", "spotifyUsername",
    "spotifyPassword", "tidalUsername", "tidalPassword", "defaultSource",
    "audioQuality", "discordRpc", "discordClientId", "downloadFolder",
    "lyricsEnabled", "autoplay", "dynamicBg",
    // Lyrics settings (time compensation, word level karaoke) and the Now
     // Playing view settings (show or hide the lyrics). The compensation
     // used to live outside this list, so it was NOT restored on startup.
    "lyricsOffset", "karaokeWords", "npLyrics",
    // Extra lyric sources, translation target and the adjustment saved
    // for each track: without these here they were written to disk but
    // never read back on the next start.
    "lyricsLiriqo", "lyricsTranslate", "lyricsOffsetByTrack",
    // Chosen repeat mode (0/1/2), besides its mirror in the session.
    "repeatMode",
    // State of the last session (queue + track + volume), restored paused
     // on startup. They are loaded at the start like the rest of the app's
     // keys.
    "sessionState", "playerVolume",
    // Bookkeeping of the notices that must not come back: the version whose
    // update was already announced and the one whose notes were already read.
    // Without them in this list they are saved but never read back, and both
    // notices came back on every start.
    "updateNotified", "whatsNewSeen", "whatsNewForVersion",
};

static bool isThemeKey(const QString &key)
{
    const QString k = key.toLower();
    for (const char *t : kThemeKeys)
        if (QString::fromLatin1(t).toLower() == k)
            return true;
    return false;
}

// Returns the canonical spelling of an app key as listed in kAppKeys (matched
// case-insensitively). Unknown keys (theme keys and ad-hoc keys) are folded to
// lowercase, matching the config.ini contract.
static QString canonicalAppKey(const QString &key)
{
    for (const char *k : kAppKeys) {
        const QString canon = QString::fromLatin1(k);
        if (canon.compare(key, Qt::CaseInsensitive) == 0)
            return canon;
    }
    return key.toLower();
}

AppConfig::AppConfig(QObject *parent)
    : QObject(parent)
    , m_themeFile(AppPaths::configFile())
{
    loadThemeFile();
    loadAppSettings();
    // Persist anything pending when the app exits, even if QML never called
    // save() explicitly.
    if (QCoreApplication *app = QCoreApplication::instance()) {
        connect(app, &QCoreApplication::aboutToQuit, this, [this]() { save(); });
    }
}

QString AppConfig::get(const QString &key) const
{
    return m_values.value(canonicalAppKey(key.trimmed())).toString();
}

void AppConfig::set(const QString &key, const QString &value)
{
    const QString k = canonicalAppKey(key.trimmed());
    if (k.isEmpty())
        return;
    m_values.insert(k, value);
    if (isThemeKey(k))
        m_dirtyTheme.insert(k.toLower(), value);
    else
        m_dirtyApp.insert(k, value);
}

void AppConfig::loadThemeFile()
{
    QFile f(m_themeFile);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return;
    QTextStream in(&f);
    while (!in.atEnd()) {
        QString line = in.readLine();
        if (line.isEmpty() || line.at(0) == QLatin1Char('#')
            || line.at(0) == QLatin1Char(';'))
            continue;
        const int eq = line.indexOf(QLatin1Char('='));
        if (eq <= 0)
            continue;
        m_values.insert(line.left(eq).trimmed().toLower(),
                        line.mid(eq + 1).trimmed());
    }
}

// Rewrite config.ini in place, preserving unchanged lines. In-place (same
// inode) write is deliberate: theme.cpp hot-reloads via QFileSystemWatcher,
// which inotify does NOT re-arm across an atomic replace (remove+rename).
void AppConfig::saveThemeFile()
{
    if (m_dirtyTheme.isEmpty())
        return;
    QFile f(m_themeFile);
    QStringList lines;
    if (f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        QTextStream in(&f);
        while (!in.atEnd()) {
            QString line = in.readLine();
            const int eq = line.indexOf(QLatin1Char('='));
            if (eq > 0) {
                const QString k = line.left(eq).trimmed().toLower();
                const QString nv = m_dirtyTheme.value(k).toString();
                if (m_dirtyTheme.contains(k)) {
                    line = k + QLatin1Char('=') + nv;
                    m_dirtyTheme.remove(k);
                }
            }
            lines << line;
        }
        f.close();
    }
    for (auto it = m_dirtyTheme.constBegin(); it != m_dirtyTheme.constEnd(); ++it)
        lines << it.key() + QLatin1Char('=') + it.value().toString();
    m_dirtyTheme.clear();

    QDir().mkpath(QFileInfo(m_themeFile).absolutePath());
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text | QIODevice::Truncate))
        return;
    QTextStream out(&f);
    for (const QString &l : lines)
        out << l << QLatin1Char('\n');
    f.close();
}

void AppConfig::loadAppSettings()
{
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    for (const char *k : kAppKeys) {
        const QString canon = QString::fromLatin1(k);
        QVariant v = s.value(canon);
        if (!v.isValid() || v.toString().isEmpty()) {
            // Migrate keys written in lowercase by older builds: if the
            // canonical key has no value, adopt the legacy lowercase one and
            // rewrite it under its canonical spelling for good.
            const QString lower = canon.toLower();
            if (s.contains(lower)) {
                const QString lv = s.value(lower).toString();
                if (!lv.isEmpty()) {
                    m_values.insert(canon, lv);
                    s.setValue(canon, lv);
                    s.remove(lower);
                    continue;
                }
            }
        }
        if (v.isValid() && !v.isNull())
            m_values.insert(canon, v.toString());
    }
    // The whitelist above only covers the older, fixed keys. Newer settings
    // (shortcuts, page order, compact mode, sleep timer, ...) are written by
    // cfgSet() with an ad-hoc lower-case key and were therefore silently
    // ignored on the next start. Load everything else too.
    for (const QString &k : s.allKeys()) {
        if (isThemeKey(k))
            continue;
        const QString canon = canonicalAppKey(k);
        if (m_values.contains(canon))
            continue;
        const QVariant v = s.value(k);
        if (v.isValid() && !v.isNull())
            m_values.insert(canon, v.toString());
    }
    s.sync();
}

void AppConfig::save()
{
    // Theme and app stores are always both flushed, even when one is empty.
    if (!m_dirtyApp.isEmpty()) {
        // A fresh instance each time merges with whatever the running app or
        // Catalog may have written concurrently.
        QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
        for (auto it = m_dirtyApp.constBegin(); it != m_dirtyApp.constEnd(); ++it)
            s.setValue(it.key(), it.value().toString());
        s.sync();
        m_dirtyApp.clear();
    }
    saveThemeFile();
    qInfo() << "[appconfig] settings saved";
}

QString AppConfig::dump() const
{
    QStringList lines;
    for (auto it = m_values.constBegin(); it != m_values.constEnd(); ++it)
        lines << it.key() + QLatin1Char('=') + it.value().toString();
    lines.sort();
    return lines.join(QLatin1Char('\n'));
}

void AppConfig::saveLogin(const QString &sourceId, const QString &v1,
                          const QString &v2, const QString &v3)
{
    const QString src = sourceId.trimmed().toLower();
    if (src == QLatin1String("spotify")) {
        set(QStringLiteral("spotifyClientId"), v1);
        set(QStringLiteral("spotifyUsername"), v2);
        set(QStringLiteral("spotifyPassword"), v3);
    } else if (src == QLatin1String("tidal")) {
        set(QStringLiteral("tidalUsername"), v1);
        set(QStringLiteral("tidalPassword"), v2);
    } else if (src == QLatin1String("ytm")) {
        set(QStringLiteral("cookiesFromBrowser"), v1);
    }
    save();
}

QString AppConfig::exportAll() const
{
    QJsonObject o;
    for (auto it = m_values.constBegin(); it != m_values.constEnd(); ++it)
        o.insert(it.key(), QJsonValue::fromVariant(it.value()));
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Indented));
}

bool AppConfig::importAll(const QString &json)
{
    const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    if (!doc.isObject())
        return false;
    const QJsonObject o = doc.object();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
        // Canonicalise the same way set() does: an exported file may use the
        // old lowercase spelling, which was imported as a different key and
        // then never read back by the theme/player settings.
        const QString key = canonicalAppKey(it.key());
        if (key.isEmpty())
            continue;
        const QVariant value = it.value().toVariant();
        if (isThemeKey(key)) {
            m_dirtyTheme.insert(key.toLower(), value);
        } else {
            m_dirtyApp.insert(key, value);
        }
        m_values.insert(key, value);
    }
    save();
    return true;
}

bool AppConfig::exportSettingsFile(const QString &path) const
{
    if (path.isEmpty())
        return false;
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;
    return f.write(exportAll().toUtf8()) > 0;
}

bool AppConfig::importSettingsFile(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return false;
    if (f.size() > 1024 * 1024)   // settings are a few KB at most
        return false;
    const QByteArray data = f.readAll();
    f.close();
    return importAll(QString::fromUtf8(data));
}

bool AppConfig::exportQueueFile(const QString &path, const QString &json) const
{
    const QByteArray data = json.toUtf8();
    if (path.isEmpty() || data.isEmpty() || data.size() > 1024 * 1024)
        return false;
    if (!QDir().mkpath(QFileInfo(path).absolutePath()))
        return false;
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;
    return f.write(data) > 0;
}

QString AppConfig::readQueueFile(const QString &path) const
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return QString();
    if (f.size() > 1024 * 1024)   // a queue is a few KB at most
        return QString();
    return QString::fromUtf8(f.readAll());
}

bool AppConfig::writeNowPlaying(const QString &json) const
{
    const QString dir = AppPaths::stateDir();
    if (!QDir().mkpath(dir))
        return false;
    QFile f(dir + QStringLiteral("/now-playing.json"));
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;
    return f.write(json.toUtf8()) > 0;
}