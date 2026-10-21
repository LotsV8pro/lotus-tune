#pragma once

#include <QByteArray>
#include <QFileSystemWatcher>
#include <QObject>
#include <QProcess>
#include <QSet>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVector>

class QDirIterator;

// Downloads to disk + local library, exposed to QML as `downloads`.
//
// It is the "Sonora" layer: it runs `yt-dlp` to download playlists or
// loose tracks as audio, one process at a time (so it does not saturate the
// network/RAM), and then publishes the files found in the root folder as a
// local library.
//
// Audio only and without re-encoding: the best already compressed audio
// track is chosen (m4a/opus) and the video, the embedded thumbnail and
// `.info.json` are dropped, so each download takes the least possible
// space. It is resumable (`--continue`) and does not download again what
// is already there.
//
// Job map:   { name, url, playlist, folder, progress (0..100), state:
//              "queued|downloading|done|error", error }
// Track map: { title, artist, duration, url (file://...), thumb,
//              source: "local" }
class Downloads : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QVariantList jobs READ jobs NOTIFY jobsChanged)
    Q_PROPERTY(QString folder READ folder NOTIFY changed)
    Q_PROPERTY(QVariantList local READ local NOTIFY libraryChanged)
    // Downloaded lists: one entry per top level folder
    // ({ name, folder, count, thumb, url }).
    Q_PROPERTY(QVariantList folders READ folders NOTIFY libraryChanged)
    Q_PROPERTY(bool localBusy READ localBusy NOTIFY libraryChanged)
    // AGGREGATED 0-100 progress of the running download (the whole list,
    // not just the current track); -1 if there is none.
    Q_PROPERTY(int activeProgress READ activeProgress NOTIFY activeProgressChanged)

public:
    explicit Downloads(QObject *parent = nullptr);
    ~Downloads() override;

    bool busy() const { return m_busy; }
    QVariantList jobs() const;
    QString folder() const { return m_folder; }
    QVariantList local() const { return m_local; }
    QVariantList folders() const;
    bool localBusy() const { return m_localBusy; }
    int activeProgress() const;

    // Root downloads folder (configurable and persisted in QSettings).
    Q_INVOKABLE void setFolder(const QString &dir);
    // ~/.local/share/lotus-tune/descargas
    Q_INVOKABLE QString defaultFolder() const;

    Q_INVOKABLE void downloadPlaylist(const QString &url, const QString &name);
    Q_INVOKABLE void downloadTrack(const QString &url, const QString &title,
                                   const QString &artist);
    Q_INVOKABLE void cancelAll();
    // Scans the folder recursively looking for audio (non blocking).
    Q_INVOKABLE void refreshLocal();
    // xdg-open on the root folder.
    Q_INVOKABLE void openFolder();
    // Uninstalls a downloaded list: deletes its top level folder
    // (recursively and with safety guards) and rescans the library.
    Q_INVOKABLE void removeList(const QString &folder);
    // Folder name that would be used for a list with that name (same
     // sanitising as when downloading); to match old lists that have no
     // metadata file.
    Q_INVOKABLE QString listFolderName(const QString &name) const;

    // Public / testable utility methods:
    static QString safeSegment(const QString &text);
    static QString friendlyError(const QString &raw);
    static void removePartials(const QString &dir);
    static int countAudioFiles(const QString &dir);
    QString uniqueListFolder(const QString &seg, const QString &url) const;

signals:
    void changed();
    void jobsChanged();
    void libraryChanged();
    // The AGGREGATED 0-100 progress of the download `name` changed (the
     // whole list).
    void progressChanged(const QString &name, int percent);
    // The download `name` failed; `message` is a readable reason for the
     // UI.
    void downloadError(const QString &name, const QString &message);
    // The download `name` finished fine; `folder` is its folder ("" for
     // loose tracks).
    void downloadCompleted(const QString &name, const QString &folder);
    // The aggregated progress of the running download changed (property).
    void activeProgressChanged();

private:
    struct Job {
        QString name;
        QString url;
        bool playlist = false;
        QString folder;      // target folder (lists); "" for loose tracks
        int progress = 0;
        QString state = QStringLiteral("queued");
        QString error;
    };

    void enqueue(const Job &job);
    void startNext();
    void readStdout();
    void finishJob(int code);
    void setJob(int index, const QString &state, const QString &error = QString());
    // Marks the job as failed with a readable message, warns the UI and
    // carries on with the queue (if it was the running job).
    void failJob(int index, const QString &message);
    // Updates the aggregated progress of the running job from the fraction
     // (0..1) of the current track and publishes it (jobsChanged +
     // progressChanged).
    void updateProgress(double frac);

    void startScan();
    void scanChunk();
    void stopScan();
    // Syncs the watched directories with the root folder + the
     // subfolders discovered in the last scan (auto sync when files
     // change).
    void updateWatchDirs();
    QVariantMap makeLocalTrack(const QString &path) const;
    QString artistForPath(const QString &dir) const;

    // Sweep, on startup, of orphan leftovers older than `ageSecs`.
    void sweepOrphans(qint64 ageSecs);

    QProcess m_proc;
    QVector<Job> m_jobs;
    int m_current = -1;      // index of the running job, -1 if none
    bool m_busy = false;
    bool m_cancelling = false;
    QString m_lastError;     // last "ERROR:" seen in the output
    QByteArray m_buf;
    // Global progress of a list: yt-dlp emits "Downloading item X of Y" and
     // then the % of each track. They are combined to show ONE 0-100 %
     // of the total instead of restarting at 0 on every song.
    int m_plItem = 0;
    int m_plTotal = 0;

    QString m_folder;
    QVariantList m_local;
    bool m_localBusy = false;
    QDirIterator *m_scan = nullptr;
    QVariantList m_scanItems;
    QTimer m_scanTimer;
    QSet<QString> m_scanDirs;      // folders seen in the scan in progress

    // Auto sync: it watches the downloads folder (and its subfolders) and
     // rescans with a small debounce when something changes on disk.
    QFileSystemWatcher m_watcher;
    QTimer m_watchDebounce;
};
