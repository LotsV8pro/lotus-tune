#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

// Control of the weight the app leaves on disk.
//
// On Android every track that plays is downloaded to
// cache/audio_<videoId>.bin (4-8 MB). With no cap, a library of 200 tracks
// leaves ~1 GB and Android ends up clearing the cache on its own (and then
// tracks that played yesterday "disappear"). This keeps a configurable
// limit and deletes first what has not been used for the longest (LRU by
// modification date).
//
// On the desktop the audio is not cached (mpv streams), so the sweep of
// audio_*.bin is a no-op; it still clears leftovers.
class AudioCache : public QObject
{
    Q_OBJECT
    // Current size of the audio cache, in bytes / in files.
    Q_PROPERTY(qint64 bytes READ bytes NOTIFY changed)
    Q_PROPERTY(int files READ files NOTIFY changed)
    // Cap in MB (0 = no limit). It is saved in the settings.
    Q_PROPERTY(int limitMB READ limitMB WRITE setLimitMB NOTIFY changed)
    // "320 MB of 1 GB" for the settings screen.
    Q_PROPERTY(QString summary READ summary NOTIFY changed)

public:
    explicit AudioCache(QObject *parent = nullptr);

    static AudioCache *instance();

    qint64 bytes() const;
    int files() const;
    int limitMB() const;
    void setLimitMB(int mb);
    QString summary() const;

    // Deletes the oldest tracks until it is under the limit (with margin:
    // it leaves the cache at 90% of the cap, so it is not deleting on every
    // download). `protect` is the videoId playing right now: that file is
    // never touched.
    Q_INVOKABLE int prune(const QString &protect = QString());
    // Deletes the whole audio cache.
    Q_INVOKABLE int clear();
    // Leftovers of interrupted downloads (.part) older than an hour.
    Q_INVOKABLE int prunePartials();

    // Solo para los tests: cambia el directorio que se barre.
    void setDirectoryForTest(const QString &dir);

signals:
    void changed();

private:
    struct Entry {
        QString path;
        QString id;
        qint64 size = 0;
        qint64 mtime = 0;
    };
    QString dir() const;
    QList<Entry> scan() const;

    QString m_dir;          // vacio = AppPaths::cacheDir()
};
