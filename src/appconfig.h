#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>

// Persistent settings for Lotus Tune, exposed to QML as the `appcfg` context
// property. Values live in two files that must stay consistent with their
// existing readers:
//  - App keys  -> QSettings("lotus-tune","lotus-tune")
//                 (~/.config/lotus-tune/lotus-tune.conf), same store Catalog
//                 uses for `cookiesFromBrowser`.
//  - Theme keys -> ~/.config/lotus-tune/config.ini, parsed manually by
//                 theme.cpp (key=value lines, lowercase keys, '#'/';' comments)
//                 and hot-reloaded by its QFileSystemWatcher.
class AppConfig : public QObject
{
    Q_OBJECT
public:
    explicit AppConfig(QObject *parent = nullptr);

    Q_INVOKABLE QString get(const QString &key) const;
    Q_INVOKABLE void set(const QString &key, const QString &value);
    Q_INVOKABLE void save();
    Q_INVOKABLE QString dump() const;
    // Publish the current track as JSON so bars, OBS and other widgets can
    // read it without a socket.
    Q_INVOKABLE bool writeNowPlaying(const QString &json) const;
    // Export/import every setting as one JSON document.
    Q_INVOKABLE QString exportAll() const;
    Q_INVOKABLE bool importAll(const QString &json);
    Q_INVOKABLE bool exportSettingsFile(const QString &path) const;
    Q_INVOKABLE bool importSettingsFile(const QString &path);
    // Export the playback queue as JSON written to an arbitrary path.
    Q_INVOKABLE bool exportQueueFile(const QString &path, const QString &json) const;
    // Read a queue JSON document back as text (max 1 MB).
    Q_INVOKABLE QString readQueueFile(const QString &path) const;
    Q_INVOKABLE void saveLogin(const QString &sourceId, const QString &v1,
                               const QString &v2, const QString &v3);

private:
    void loadThemeFile();
    void saveThemeFile();
    void loadAppSettings();
    QString m_themeFile;
    QVariantMap m_values;      // merged view of every key (get()/set())
    QVariantMap m_dirtyTheme;  // keys changed since last save -> config.ini
    QVariantMap m_dirtyApp;    // keys changed since last save -> QSettings
};