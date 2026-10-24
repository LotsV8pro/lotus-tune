#include "theme.h"
#include "paths.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#include <QTextStream>
#include <QTimer>

#include <QDebug>

#ifdef Q_OS_ANDROID
#include <QJniObject>
#endif

static const char *kDefaults[][2] = {
    { "bg", "#0a0a0d" },
    { "surface", "#101014" },
    { "surfaceAlt", "#17171c" },
    { "border", "#26262e" },
    { "borderSubtle", "#1e1e25" },
    { "accent", "#1ed760" },
    { "onAccent", "#0a0a0d" },
    { "text", "#f4f4f6" },
    { "textDim", "#8e8e99" },
    { "danger", "#e81123" },
};

#ifdef Q_OS_ANDROID
// Android has no quickshell or CDE palette to mirror: the system accent
// (Material You, tinted from the wallpaper) is read from Java. Returns
// "#rrggbb" or an empty string when the system does not offer one.
static QString androidSystemAccent()
{
    const QJniObject jName = QJniObject::callStaticObjectMethod(
        QStringLiteral("io/github/lotsv8pro/lotustune/MainActivity")
            .toUtf8().constData(),
        "systemAccentColor",
        "()Ljava/lang/String;");
    if (!jName.isValid())
        return {};
    const QString hex = jName.toString();
    if (hex.size() != 7 || !hex.startsWith('#') || !QColor(hex).isValid())
        return {};
    return hex;
}
#endif

AppTheme::AppTheme(QObject *parent) : QObject(parent)
{
    m_watchFiles = {
        QDir::homePath() + "/.local/state/quickshell/user/generated/app-palette.json",
        QDir::homePath() + "/.local/state/quickshell/user/generated/colors.json",
        AppPaths::configFile(),
    };

    // Coalesce the burst of file/directory events a palette regeneration
    // produces (delete + rename + create) into a single reload so we never
    // read a half-written file or reload repeatedly.
    m_debounce = new QTimer(this);
    m_debounce->setSingleShot(true);
    m_debounce->setInterval(80);
    connect(m_debounce, &QTimer::timeout, this, &AppTheme::reload);

    reload();

    // Watch palette + config. If a file does not exist yet, watch its parent
    // directory so creation is picked up too.
    rearmWatch();

    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this](const QString &path) {
        // Atomic replaces (rename, typical of quickshell/matugen) silently drop
        // the inotify watch, so re-establish it before reloading.
        rearmWatch(path);
        scheduleReload();
    });
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this](const QString &path) {
        rearmWatch(path);
        scheduleReload();
    });
}

void AppTheme::scheduleReload()
{
    // Restart the timer on every event so a burst is handled only once.
    if (m_debounce)
        m_debounce->start();
}

void AppTheme::rearmWatch(const QString &path)
{
    // No path: (re)establish every target watch.
    if (path.isEmpty()) {
        for (const QString &f : m_watchFiles)
            rearmWatch(f);
        return;
    }

    const QFileInfo info(path);

    // A watched directory changed: re-arm every target that lives inside it.
    if (info.isDir()) {
        for (const QString &f : m_watchFiles) {
            if (QFileInfo(f).absolutePath() == path)
                rearmWatch(f);
        }
        if (!m_watcher.directories().contains(path) && QFileInfo::exists(path))
            m_watcher.addPath(path);
        return;
    }

    // The target file itself: drop any stale watch and re-establish it. When
    // the file is momentarily gone during a rename, watch its directory so we
    // notice when it reappears.
    m_watcher.removePath(path);
    if (QFileInfo::exists(path)) {
        m_watcher.addPath(path);
    } else {
        const QString dir = info.absolutePath();
        if (QFileInfo::exists(dir) && !m_watcher.directories().contains(dir))
            m_watcher.addPath(dir);
    }
}

QString AppTheme::pick(const QVariantMap &map, const QStringList &keys,
                       const QString &fallback)
{
    for (const QString &k : keys) {
        const QString v = map.value(k).toString().trimmed();
        if (!v.isEmpty())
            return v;
    }
    return fallback;
}

static void loadJsonFile(const QString &path, QVariantMap &out)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QJsonObject obj = QJsonDocument::fromJson(f.readAll()).object();
    for (auto it = obj.begin(); it != obj.end(); ++it)
        out.insert(it.key().toLower(), it.value().toVariant());
}

void AppTheme::loadSystemPalette()
{
    m_sys.clear();
    const QString base = QDir::homePath()
        + "/.local/state/quickshell/user/generated";
    const QString appPal = base + "/app-palette.json";
    const QString matPal = base + "/colors.json";

    if (QFileInfo::exists(appPal)) {
        loadJsonFile(appPal, m_sys);
        m_source = appPal;
    }
    if (m_sys.isEmpty() && QFileInfo::exists(matPal)) {
        loadJsonFile(matPal, m_sys);
        m_source = matPal;
    }
#ifdef Q_OS_ANDROID
    if (m_sys.isEmpty()) {
        // No generated palette on the phone: take the system accent
        // (wallpaper / theme color) from Java so "follow system" is real.
        const QString hex = androidSystemAccent();
        if (!hex.isEmpty()) {
            m_sys.insert(QStringLiteral("app_accent"), hex);
            m_source = QStringLiteral("android system");
        }
    }
#endif
    if (m_sys.isEmpty())
        m_source = QStringLiteral("built-in defaults");
}

void AppTheme::loadOverrides()
{
    m_over.clear();
    m_followSystem = true;

    QFile f(AppPaths::configFile());
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return;

    QTextStream in(&f);
    while (!in.atEnd()) {
        QString line = in.readLine().trimmed();
        if (line.isEmpty() || line.startsWith('#') || line.startsWith(';'))
            continue;
        const int eq = line.indexOf('=');
        if (eq <= 0)
            continue;
        const QString key = line.left(eq).trimmed().toLower();
        const QString val = line.mid(eq + 1).trimmed();
        m_over.insert(key, val);
    }
    m_followSystem = m_over.value("followsystem", "true").toString()
                         .compare(QLatin1String("false"), Qt::CaseInsensitive) != 0;
}

void AppTheme::reload()
{
    loadSystemPalette();
    loadOverrides();

    auto def = [](const char *key) -> QString {
        for (const auto &kv : kDefaults)
            if (QLatin1String(kv[0]) == QLatin1String(key))
                return QString::fromLatin1(kv[1]);
        return {};
    };
    auto resolve = [&](const char *key, const QStringList &sysKeys) -> QColor {
        const QString over = m_over.value(QString::fromLatin1(key)).toString();
        if (!over.isEmpty())
            return QColor(over);
        if (m_followSystem) {
            const QString v = pick(m_sys, sysKeys, QString());
            if (!v.isEmpty())
                return QColor(v);
        }
        return QColor(def(key));
    };

    m_bg           = resolve("bg",           { "app_window_bg", "app_background", "background" });
    m_surface      = resolve("surface",      { "app_card_bg", "surface_container_low", "surface" });
    m_surfaceAlt   = resolve("surfacealt",   { "app_surface_elevated", "surface_container", "surface_bright" });
    m_border       = resolve("border",       { "app_border", "outline", "outline_variant" });
    m_borderSubtle = resolve("bordersubtle", { "app_border_subtle", "outline_variant" });
    m_accent       = resolve("accent",       { "app_accent", "primary", "surface_tint" });
    m_onAccent     = resolve("onaccent",     { "app_on_accent", "on_primary" });
    m_text         = resolve("text",         { "app_foreground", "on_background", "on_surface" });
    m_textDim      = resolve("textdim",      { "app_subtext", "on_surface_variant" });
    m_danger       = resolve("danger",       { "error", "error_container" });

    m_accentDim = m_accent;
    m_accentDim.setAlpha(0x55);

    qInfo("[theme] palette loaded: source=%s accent=%s bg=%s followingSystem=%d",
          qPrintable(m_source), qPrintable(m_accent.name(QColor::HexRgb)),
          qPrintable(m_bg.name(QColor::HexRgb)), m_followSystem ? 1 : 0);

    emit paletteChanged();
}
