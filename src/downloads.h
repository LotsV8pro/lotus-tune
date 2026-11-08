#pragma once

#include <QByteArray>
#include <QFileSystemWatcher>
#include <QHash>
#include <QObject>
#include <QPair>
#include <QProcess>
#include <QSet>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVector>

class QDirIterator;
class QNetworkAccessManager;
class Player;

// Downloads to disk + local library, exposed to QML as `downloads`.
//
// It is the "Sonora" layer: it runs `yt-dlp` to download playlists or
// loose tracks as audio, one process at a time (so it does not saturate the
// network/RAM), and then publishes the files found in the root folder as a
// local library.
//
// Audio only and without re-encoding: the best already compressed audio
// track is chosen (m4a/opus, preferring the compact Opus variant) and the
// video, the embedded thumbnail and `.info.json` are dropped, so each
// download takes the least possible space. It is resumable (`--continue`)
// and does not download again what is already there.
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
    // Space taken by the downloads folder (audio + metadata of the lists):
    // Settings shows it broken down with the audio cache.
    Q_PROPERTY(qint64 bytes READ bytes NOTIFY libraryChanged)
    // Quality of new downloads: "max" | "alta" | "media" | "baja"
    // (persisted in QSettings; the smallest one is the default).
    Q_PROPERTY(QString quality READ quality WRITE setQuality NOTIFY changed)
    Q_PROPERTY(QString storageSummary READ storageSummary NOTIFY libraryChanged)
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
    qint64 bytes() const { return m_bytes; }
    QString quality() const { return m_quality; }
    void setQuality(const QString &q);
    // "1,2 GB · 64 pistas en 14 listas" (or "Sin descargas").
    QString storageSummary() const;
    int activeProgress() const;

    // Root downloads folder (configurable and persisted in QSettings).
    Q_INVOKABLE void setFolder(const QString &dir);
    // Reproductor: en Android las descargas resuelven la URL directa del
    // audio con la misma cadena que la reproduccion (no hay yt-dlp).
    void setPlayer(Player *player);
    // ~/.local/share/lotus-tune/descargas
    Q_INVOKABLE QString defaultFolder() const;

    Q_INVOKABLE void downloadPlaylist(const QString &url, const QString &name,
                                      const QString &kind = QStringLiteral("list"));
    Q_INVOKABLE void downloadTrack(const QString &url, const QString &title,
                                   const QString &artist);
    Q_INVOKABLE void cancelAll();
    // Deletes EVERYTHING inside the downloads folder (lists and loose
    // tracks), keeping the folder itself. Runs are cancelled first.
    Q_INVOKABLE void removeAll();
    // Pause / resume a job by its position in `jobs`. Pausing STOPS yt-dlp
    // but keeps the .part, so resuming continues from the same byte
    // (--continue) and skips the tracks already in the list's archive.
    // A job that failed can also be resumed this way (retry from where it
    // stopped) instead of downloading the whole list again.
    Q_INVOKABLE void pauseDownload(int index);
    Q_INVOKABLE void resumeDownload(int index);
    // Same, for every job (the header buttons of the download panel).
    Q_INVOKABLE void pauseAll();
    Q_INVOKABLE void resumeAll();
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
    static void removePartials(const QString &dir, bool keepResumable = false);
    // Replaces the audio files of a freshly downloaded list that are
    // byte-identical to one in another folder with a hard link to that
    // one: a song released both as a single and inside an album takes the
    // space of ONE file, not two.
    void dedupeFolder(const QString &dir);
    // Size of a downloaded list folder in bytes (confirmation dialogs).
    Q_INVOKABLE qint64 listSize(const QString &folder) const;
    // Approximate size of `minutes` of audio at the chosen quality, for
    // the "you are going to download X" dialog.
    Q_INVOKABLE QString estimateSize(double minutes) const;
    static int countAudioFiles(const QString &dir);
    QString uniqueListFolder(const QString &seg, const QString &url) const;
    // Caches the cover of a downloaded list in `<folder>/cover.jpg` (the
    // signed YouTube URL expires, the file does not).
    void cacheCover(const QString &dir, const QString &url);
    void queueFolderCovers();
    // yt-dlp `-f` selector + quality for the level chosen in Settings.
    QPair<QString, QString> downloadFormat() const;

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
        // What the list is: "album", "single" or "list" (saved
        // playlists/radios). Downloads groups the folders by it.
        QString kind = QStringLiteral("list");
        QString folder;      // target folder (lists); "" for loose tracks
        int progress = 0;
        QString state = QStringLiteral("queued");
        QString error;
    };

    void enqueue(const Job &job);
    // Position of the job of that URL that is still alive (queued,
    // downloading, paused or failed); -1 if there is none. Clicking
    // download again on the same list resumes it instead of stacking a
    // second copy of the same download.
    int liveJobForUrl(const QString &url) const;
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
    QVariantMap makeLocalTrack(const QString &path,
                               const QVariantMap &meta) const;
    QString artistForPath(const QString &dir) const;

    // ---- metadata of the downloaded lists -------------------------------
    // The files only carry the audio: the title/artist/duration/cover of
    // every track is taken from the list itself (one yt-dlp call for the
    // whole list) and cached in `<list>/.lotus-meta.json`. That way the
    // library shows the real data - and the same as on Android - without
    // extra files per track and without touching the audio.
    static QVariantMap readFolderMeta(const QString &dir);
    static void writeFolderMeta(const QString &dir, const QVariantMap &map);
    void queueFolderMeta();
    void startNextFolderMeta();
    void finishFolderMeta(int code);

    // Sweep, on startup, of orphan leftovers older than `ageSecs`.
    void sweepOrphans(qint64 ageSecs);

#ifdef Q_OS_ANDROID
    // ---- Descargas en Android (sin yt-dlp) ------------------------------
    // 1) el helper nativo (libytmcli.so) devuelve las pistas de la lista;
    // 2) Player resuelve la URL directa de cada pista (misma cadena que la
    //    reproduccion: WEB_REMIX + solver del WebView);
    // 3) MediaDownload (Java) baja los bytes con el stack HTTP del sistema.
    struct AndroidTrack {
        QString id;
        QString title;
        QString artist;
        QString url;
        QString thumb;
        double duration = 0.0;
    };
    void startAndroidJob(int index);
    void androidListFinished(int code);
    void androidNextTrack();
    void androidStartFetch(const QString &direct);
    void androidPollTick();
    void androidTrackFailed(const QString &message);
    // Cancela lo que haya en vuelo (helper, resolucion o descarga).
    void androidAbort();
    // Escribe la ficha de la pista para que la biblioteca local enseñe
    // titulo, artista, duracion y portada.
    void writeTrackInfo(const QString &path, const AndroidTrack &t) const;

    Player *m_player = nullptr;
    QProcess m_androidList;
    QVector<AndroidTrack> m_androidTracks;
    int m_androidIndex = 0;
    QString m_androidDir;
    QString m_androidResolving;    // pista pedida a Player (url normalizada)
    QString m_androidFetchId;      // id de la descarga Java en curso
    QString m_androidOutPath;      // fichero final de la pista en curso
    QString m_androidArchive;      // .lotus-archive.txt del trabajo
    QSet<QString> m_androidDone;   // ids ya descargados (reanudar)
    int m_androidRetries = 0;
    int m_androidResolveTicks = 0;
    QTimer m_androidPoll;
#endif

    QProcess m_proc;
    QVector<Job> m_jobs;
    int m_current = -1;      // index of the running job, -1 if none
    bool m_busy = false;
    bool m_cancelling = false;
    // The running yt-dlp is being stopped to PAUSE it: finishJob() keeps the
    // partial files and leaves the job in "paused" instead of failing it.
    bool m_pausing = false;
    QString m_lastError;     // last "ERROR:" seen in the output
    QByteArray m_buf;
    // Global progress of a list: yt-dlp emits "Downloading item X of Y" and
     // then the % of each track. They are combined to show ONE 0-100 %
     // of the total instead of restarting at 0 on every song.
    int m_plItem = 0;
    int m_plTotal = 0;

    QString m_folder;
    QString m_quality = QStringLiteral("media");
    QVariantList m_local;
    // Space taken by the folder: recounted in every scan (see scanChunk).
    qint64 m_bytes = 0;
    qint64 m_scanBytes = 0;
    bool m_localBusy = false;
    QDirIterator *m_scan = nullptr;
    QVariantList m_scanItems;
    QTimer m_scanTimer;
    QSet<QString> m_scanDirs;      // folders seen in the scan in progress

    // Per-folder metadata (index -> {title, artist, duration, thumb}),
    // loaded once per scan, and the queue of folders still to fetch.
    QHash<QString, QVariantMap> m_folderMeta;
    QSet<QString> m_metaLoaded;    // folders whose cache was read this scan
    QSet<QString> m_metaTried;     // folders already requested this session
    QStringList m_metaQueue;
    QProcess m_metaProc;
    QString m_metaFolder;          // folder being fetched right now
    bool m_metaWrote = false;      // something was cached: rescan at the end
    // Covers cached on disk (one QNetworkAccessManager for all of them).
    QNetworkAccessManager *m_coverNet = nullptr;
    QSet<QString> m_coverBusy;

    // Auto sync: it watches the downloads folder (and its subfolders) and
     // rescans with a small debounce when something changes on disk.
    QFileSystemWatcher m_watcher;
    QTimer m_watchDebounce;
};
