#pragma once

#include <QHash>
#include <QObject>
#include <QProcess>
#include <QSet>
#include <QTimer>
#include <QVariantList>

class SourceManager;

// Metadata layer: runs yt-dlp (flat JSON mode) for search and playlists,
// normalises entries into track maps, and persists the user's saved
// playlists + recently played tracks.
//
// Track map:    { title, artist, duration, url, source, thumb }
// Playlist map: { name, url, source, count }
class Catalog : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QVariantList results READ results NOTIFY changed)
    Q_PROPERTY(QString resultsQuery READ resultsQuery NOTIFY changed)
    // Results of the search across ALL the sources: a list of groups
    // { id, name, items, locked } - one per source, in the order of the
    // registry (YouTube Music first). The locked sources show up with
    // locked = true and no results, so it is clear what is missing.
    Q_PROPERTY(QVariantList resultsBySource READ resultsBySource NOTIFY changed)
    // Is a search across all the sources running?
    Q_PROPERTY(bool multiSearching READ multiSearching NOTIFY changed)
    Q_PROPERTY(QVariantList tracks READ tracks NOTIFY changed)
    Q_PROPERTY(QString tracksTitle READ tracksTitle NOTIFY changed)
    Q_PROPERTY(QVariantList playlists READ playlists NOTIFY libraryChanged)
    Q_PROPERTY(QVariantList recent READ recent NOTIFY libraryChanged)
    Q_PROPERTY(QVariantList ytmLibrary READ ytmLibrary NOTIFY libraryChanged)
    Q_PROPERTY(bool libraryBusy READ libraryBusy NOTIFY libraryChanged)
    // Real in-app YT Music login ("", "waiting", "ok", "error").
    Q_PROPERTY(QString loginState READ loginState NOTIFY loginChanged)
    // YouTube Music playlist opened through the fast path: it allows
    // "remove from this list" for the playing track (its setVideoId
    // travels with every track).
    Q_PROPERTY(QString openPlaylistId READ openPlaylistId NOTIFY changed)
    // Real URL of the open list (so it can be downloaded even if it is
    // not the user's or its id is unknown).
    Q_PROPERTY(QString openListUrl READ openListUrl NOTIFY changed)
    // User's "liked" state (library). likedReady turns true once the set
    // has been loaded (or the attempt with a session failed); likedRevision
    // goes up on every change so the rows repaint the heart.
    Q_PROPERTY(bool likedReady READ likedReady NOTIFY likedChanged)
    // The "liked" tracks WITH their metadata (artist, title, url): the home
    // uses their artists to seed the recommended radios.
    Q_PROPERTY(QVariantList likedTracks READ likedTracks NOTIFY likedChanged)
    Q_PROPERTY(int likedRevision READ likedRevision NOTIFY likedChanged)
    Q_PROPERTY(QString loginError READ loginError NOTIFY loginChanged)
    Q_PROPERTY(QString loginUrl READ loginUrl NOTIFY loginChanged)

public:
    explicit Catalog(SourceManager *sources, QObject *parent = nullptr);
    ~Catalog() override;

    bool busy() const { return m_busy; }
    QString error() const { return m_error; }
    QVariantList results() const { return m_results; }
    QString resultsQuery() const { return m_resultsQuery; }
    QVariantList resultsBySource() const { return m_resultsBySource; }
    bool multiSearching() const { return m_multiActive; }
    QVariantList tracks() const { return m_tracks; }
    QString tracksTitle() const { return m_tracksTitle; }
    QVariantList playlists() const { return m_playlists; }
    QVariantList recent() const { return m_recent; }
    QVariantList ytmLibrary() const { return m_ytmLibrary; }
    bool libraryBusy() const { return m_libraryBusy; }
    QString loginState() const { return m_loginState; }
    QString openPlaylistId() const { return m_openPlaylistId; }
    QString openListUrl() const { return m_openListUrl; }
    bool likedReady() const { return m_likedReady; }
    QVariantList likedTracks() const { return m_likedTracks; }
    int likedRevision() const { return m_likedRevision; }
    QString loginError() const { return m_loginError; }
    QString loginUrl() const { return m_loginUrl; }

    Q_INVOKABLE void search(const QString &query);
    // Search in ALL the available sources at once: they are queried one
    // after the other (each source's search is a separate process) and the
    // results arrive group by group, in the order of the registry. It is
    // what the launcher (Ctrl+Space) and the Search page use: there is
    // no need to pick a source before searching.
    Q_INVOKABLE void searchAll(const QString &query);
    Q_INVOKABLE void openPlaylist(int savedIndex);
    Q_INVOKABLE void openUrl(const QString &url, const QString &name);
    // YouTube Music self radio for a videoId (what the app itself puts
    // "up next"): it resolves the RDAMVM<videoId> mix with yt-dlp and
    // emits radioReady() with the list, without touching the queue. It is
    // also stored in the list cache, so it can be pre-fetched (on mouse
    // over its card) and opened instantly. fetchRadio() asks for 80 tracks
    // (autoplay); prefetchRadio() only 25, so the home prefetch finishes
    // in ~1.4 s.
    Q_INVOKABLE void fetchRadio(const QString &videoId,
                                const QString &title = QString());
    Q_INVOKABLE void prefetchRadio(const QString &videoId,
                                   const QString &title = QString());
    // ---- Artists -----------------------------------------------------------
    // Artist search (not songs): artistsReady() with a list of
    // { name, browseId, thumb, subtitle }; the best match first.
    Q_INVOKABLE void searchArtists(const QString &query);
    // Full discography of an artist (albums, singles, EPs...), newest
    // first: artistReady(browseId, albums).
    Q_INVOKABLE void fetchArtist(const QString &browseId);
    // Tracks of an album or single: albumTracksReady(browseId, tracks).
    Q_INVOKABLE void fetchAlbumTracks(const QString &browseId);
    // Resolves the main track of an artist to seed their radio
    // ("Radio of the artist" in the context menu): it emits
    // artistTopTrackResolved.
    Q_INVOKABLE void resolveArtistRadio(const QString &artistName);
    // Alternative video for a track whose original video is gone (see
    // alternateResolved()). It is looked up in YouTube Music dropping the
    // failed id. `duration` (seconds, 0 if unknown) helps fine tune the
    // match.
    Q_INVOKABLE void resolveAlternate(const QString &artist, const QString &title,
                                      const QString &failedVideoId,
                                      double duration);
    Q_INVOKABLE void syncLiked();
    // Empties the in-memory cache of already loaded lists: the next open
    // of each one queries the network again (useful to "refresh").
    Q_INVOKABLE void invalidatePlaylistCache();
    // ---- YouTube Music interaction (needs a signed in session) ---------
    // rating: "LIKE" | "DISLIKE" | "INDIFFERENT".
    Q_INVOKABLE void rateTrack(const QString &videoId, const QString &rating);
    Q_INVOKABLE void addToPlaylist(const QString &playlistId, const QString &videoId);
    Q_INVOKABLE void removeFromPlaylist(const QString &playlistId,
                                        const QString &videoId,
                                        const QString &setVideoId);
    // Reorders (`delta` ±1) or removes a track from the OPEN list
    // (m_openPlaylistId): it is painted at once and synced with YouTube
    // Music.
    Q_INVOKABLE void moveOpenPlaylistTrack(const QString &setVideoId, int delta);
    Q_INVOKABLE void removeOpenPlaylistTrack(const QString &videoId,
                                             const QString &setVideoId);
    // Is the track in "liked" (library) according to the loaded set?
    // The session of YouTube Music (the cookies) is what lets the app
    // read the private lists and, on a phone, play the audio. It can be
    // exported to a file and imported in another device.
    Q_INVOKABLE bool exportSession(const QString &path);
    Q_INVOKABLE bool importSession(const QString &path);
    Q_INVOKABLE bool isLiked(const QString &videoId) const;
    // Updates the local set after a vote (without waiting for the server).
    Q_INVOKABLE void setLiked(const QString &videoId, bool liked);
    // videoId of a YouTube URL (or the id itself if it already is one);
    // "" if it does not apply.
    Q_INVOKABLE QString videoIdOf(const QString &urlOrId) const;
    // Toggles "liked" of a track (URL or videoId): it votes and updates
    // the set.
    Q_INVOKABLE void toggleLiked(const QString &videoIdOrUrl, bool currentlyLiked);
    // YouTube Music "My playlists" (saved/created playlists), via the API.
    Q_INVOKABLE void refreshYtmLibrary();
    // ---- own list management (create/edit/delete) ----------------
    // Creates a list (private depending on `isPrivate`) and, if addVideoId
    // is not empty, adds that track to it.
    Q_INVOKABLE void createPlaylist(const QString &title, bool isPrivate,
                                    const QString &addVideoId);
    // Renames and/or changes the privacy of an own list.
    Q_INVOKABLE void updatePlaylist(const QString &id, const QString &title,
                                    bool isPrivate);
    Q_INVOKABLE void deletePlaylist(const QString &id);
    // Asks for the title/description/privacy/ownership of a list (async).
    Q_INVOKABLE void fetchPlaylistInfo(const QString &id);
    // Opens the integrated Google window (WebKit) to sign in to YouTube Music.
    Q_INVOKABLE void loginYTM();
    Q_INVOKABLE void logoutYTM();
    Q_INVOKABLE void addPlaylist(const QString &name, const QString &url);
    Q_INVOKABLE void removePlaylist(int index);
    Q_INVOKABLE void addRecent(const QVariantMap &track);
    Q_INVOKABLE void clearRecent();
    Q_INVOKABLE void dismissError();

signals:
    void changed();
    void libraryChanged();
    // A track list finished loading and should replace the queue.
    void tracksReady(const QVariantList &tracks, const QString &title);
    // YouTube Music's radio (autoplay) arrived: `tracks` is what follows the
    // seed videoId, so the UI can extend "up next".
    void radioReady(const QString &seedVideoId, const QVariantList &tracks);
    // Artist search results (see searchArtists()).
    void artistsReady(const QVariantList &artists);
    // Discography received (see fetchArtist()).
    void artistReady(const QString &browseId, const QVariantList &albums);
    // Album/single tracks received (see fetchAlbumTracks()).
    void albumTracksReady(const QString &browseId, const QVariantList &tracks);
    // An artist's main track resolved (see resolveArtistRadio()); `track` is
    // empty if it could not be resolved (the UI falls back to the track's
    // radio).
    void artistTopTrackResolved(const QString &artistName, const QVariantMap &track);
    // The alternative video for the failed track `key` resolved (see
    // resolveAlternate()); `track` is empty if there was none.
    void alternateResolved(const QString &key, const QVariantMap &track);
    // loginState / loginError / loginUrl changed.
    void loginChanged();
    // Result of a YouTube Music interaction (vote / add / remove from list).
    void interactionDone(bool ok, const QString &message);
    // The "liked" set changed (loaded or after a vote).
    void likedChanged();
    // A list's metadata arrived (answer to fetchPlaylistInfo).
    void playlistInfoReady(const QVariantMap &info);

private:
    void run(const QString &target, const QString &purpose, const QString &title);
    // Common point of fetchRadio()/prefetchRadio(): only the purpose
    // changes, and that is what decides the track cap and the timeout.
    void runRadio(const QString &videoId, const QString &title,
                  const QString &purpose);
    // Runs `python3 ytm_api.py <args...>` in m_artistProc (artist search,
    // discography and album tracks). `mode` says how to read the output
    // ("artists" | "artist" | "album") and `arg` is the data the UI
    // recognises in the answer. Only one request is in flight: a new one
    // cancels the previous (changing artist while its discography is
    // still arriving).
    void runArtist(const QStringList &args, const QString &mode,
                   const QString &arg);
    // Search in a concrete source ("ytm", "soundcloud"...): it uses the
    // YouTube Music fast path when it applies and, if not, yt-dlp with
    // that source's prefix.
    void searchInSource(const QString &source, const QString &query);
    // Chain of the search across all the sources: the next source to query
    // and the dump of the results of the one that just finished.
    void nextMultiSource();
    void absorbMultiResults();
    // Cancels a background query in flight (radio/autoplay or prefetch).
    // It is best-effort, so it always loses to an explicit user action.
    // It returns true if there was one and it has been cancelled.
    bool cancelBackgroundFetch();
    // Classic route with yt-dlp (used directly or as the fallback of the
    // fast path for playlists through YouTube Music's internal API).
    void runYtdlp(const QString &target, const QString &purpose, const QString &title);
    // Shared launcher: arbitrary program (yt-dlp or the ytm_login.py helper)
    // whose stdout is yt-dlp -J shaped and feeds handleOutput().
    void startFetch(const QString &program, const QStringList &args,
                    const QString &purpose, const QString &title);
    // It returns true if it produced results; false if it failed (e.g. an
    // empty list).
    bool handleOutput(const QByteArray &json);
    void fail(const QString &message);
    QVariantMap normalize(const QVariantMap &entry) const;
    void loadLibrary();
    void saveLibrary() const;
    static QString stateFile();
    static QString helperPath();
    static QString ytmApiPath();
    static QString cookieFile();
    bool ytmLoggedIn() const;
    void handleLoginOutput();
    void finishLogin(int code);
    void setLoginState(const QString &state);
    // Runs `python3 ytm_api.py <args...>` in m_ytmProc (interactions).
    void runYtmAction(const QStringList &args, const QString &okMessage);
    // Runs `python3 ytm_api.py <args...>` in m_plProc (list management).
    // `mode` says how to read the output: "info" | "create" | "update" |
    // "delete" (and "createadd", internal).
    void runPlaylistAction(const QStringList &args, const QString &mode);
    // Loads the "Liked" playlist (LM) once to know the real "liked" state
    // of every track (Sonora style).
    void refreshLikedSet();
    // Starts the network fetch of the "liked" set (no TTL): it is used by
    // both the lazy refresh and the manual syncLiked() button.
    void launchLikedFetch();

    // ---- in-memory list cache --------------------------------------
    // Key of a list: it normalises YouTube's `list=<id>` so the same list
    // opened by URL, by id or from "my playlists" shares an entry.
    static QString cacheKeyFor(const QString &target);
    // Stores a freshly loaded list (FIFO, up to 24 entries).
    void cachePlaylist(const QString &key, const QVariantList &tracks,
                       const QString &title);
    void forgetCachedPlaylist(const QString &key);

    // ---- on-disk list cache ----------------------------------------
    // JSON file in QStandardPaths::CacheLocation (playlists.json) with the
    // lists already loaded and their timestamp: it allows reopening any
    // list (a radio included) instantly even if the app restarted.
    static QString playlistsFile();
    // Reads the file on startup and seeds the in-memory cache (the most
    // recent ones), without marking it dirty.
    void loadPlaylistCache();
    // Deferred dump of the cache to disk (target of the single shot QTimer).
    void savePlaylistCache();
    // Serves a list from the file (if it has not expired) when it is not in
    // memory; the fast path uses it as the last resort before the network.
    bool cachedPlaylistFromDisk(const QString &key, QVariantList *tracks,
                                QString *title) const;
    // Marks the entry as freshly loaded (timestamp) and schedules the
    // deferred dump to disk.
    void rememberPlaylistForDisk(const QString &key);

    // ---- persistence of the "liked" set ----------------------------
    // JSON file next to the library state (library.json).
    static QString likedFile();
    // Loads the set from disk; it returns false if there is no valid cache.
    bool loadLikedFromDisk();
    // Stores the current set (with the m_likedTs timestamp).
    void saveLikedToDisk() const;

    SourceManager *m_sources;
    QProcess m_proc;
    QString m_purpose;
    QString m_radioSeed;   // seed videoId of the current radio
    // The user opened by hand a list that was already being fetched in the
    // background (a radio prefetch on mouse over): the in-flight result
    // also works as the open list, without downloading it again.
    bool m_promotePending = false;
    // A best-effort process (radio) cancelled to give way to another
    // request: its later finished() is ignored instead of reporting a
    // failure.
    bool m_killed = false;
    QString m_pendingTitle;
    QString m_currentSource;
    bool m_busy = false;
    QString m_error;
    QVariantList m_results;
    QString m_resultsQuery;
    // Search across all the sources: the groups fill one by one (each
    // source is a query) and they are emitted as each one finishes.
    QVariantList m_resultsBySource;
    QStringList m_multiQueue;       // ids of the sources that are missing
    QString m_multiCurrent;         // id of the source being queried
    QString m_multiQuery;
    bool m_multiActive = false;
    QVariantList m_tracks;
    QString m_tracksTitle;
    // In-memory cache of list results (reopening is instant). The key is the
    // normalised target (e.g. "list:<id>"); it is limited to 24 entries.
    QHash<QString, QVariantList> m_playlistCache;
    QHash<QString, QString> m_playlistTitles;
    QList<QString> m_cacheOrder;   // FIFO order to evict the cache
    QString m_pendingKey;          // key of the list load in progress
    // Timestamp (epoch secs) of every cache entry, for the TTL of the on
    // disk file (playlists.json).
    QHash<QString, qint64> m_playlistCacheAt;
    // Dropped keys (edits/reorders) that have to be removed from the file
    // on the next dump: without this, reopening the list would bring the
    // old one.
    QSet<QString> m_cacheForgotten;
    QTimer m_cacheSaveTimer;       // deferred dump of the cache to disk
    bool m_cacheDirty = false;     // are there pending changes to save?
    QVariantList m_playlists;
    QVariantList m_recent;
    QVariantList m_ytmLibrary;
    bool m_libraryBusy = false;
    QProcess m_loginProc;      // dedicated: must not disturb m_proc searches
    QProcess m_statusProc;     // one-shot token check at startup
    QProcess m_libraryProc;    // one-shot "my lists" fetch (ytm_api.py)
    QProcess m_artistProc;     // one-shot artists/discography/albums (ytm_api.py)
    QString m_artistMode;      // "artists" | "artist" | "album" | "toptrack" (empty: cancelled)
    QString m_artistArg;       // data returned in the signal
    QVariantMap m_topTrack;    // resolved main track (artist radio)
    // Alternative video for a track whose video died: its own process so
    // it does not step on the artist navigation that may be in flight.
    QProcess m_altProc;
    QString m_altKey;          // failed videoId that is being retried
    QProcess m_ytmProc;        // one-shot actions (rate/addpl/rmpl)
    QString m_ytmOkMessage;    // success message tied to the action in progress
    QProcess m_plProc;         // one-shot list management (create/rename/delete/info)
    QString m_plMode;          // how to interpret the output of m_plProc
    QString m_plAddVideo;      // track to add after creating a list (or "")
    QString m_plSetId;         // pending setVideoId (remove from a list)
    QProcess m_likedProc;      // one-shot "liked" (LM) for the state of the rows
    QSet<QString> m_likedIds;  // videoIds in "liked"
    QVariantList m_likedTracks;  // "liked" with its artist and title
    // Local path (downloaded file) -> YouTube videoId, resolved once by
    // reading the sibling .info.json. It allows liking the local tracks as
    // if they were from YouTube (same videoId, same sync).
    mutable QHash<QString, QString> m_localIdCache;
    int m_likedRevision = 0;
    bool m_likedReady = false;
    qint64 m_likedTs = 0;      // timestamp of the last network fetch (epoch secs)
    // Fallback to yt-dlp if the fast path for playlists (internal API)
    // fails.
    QString m_fastFallback;      // pending yt-dlp target ("" if it does not apply)
    QString m_fastFallbackTitle; // title to keep in the fallback
    // Playlist opened through the fast path (for the "remove from the
    // list" button).
    QString m_openPlaylistId;
    QString m_openListUrl;
    QString m_loginState;
    QString m_loginError;
    QString m_loginUrl;
    QByteArray m_loginBuf;
    bool m_loginCancel = false;
};
