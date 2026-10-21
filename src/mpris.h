#pragma once

#include <QDBusAbstractAdaptor>
#include <QDBusObjectPath>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariantMap>

// MPRIS2 integration (org.mpris.MediaPlayer2) over the D-Bus session.
//
// It publishes the service "org.mpris.MediaPlayer2.lotustune" and the
// object "/org/mpris/MediaPlayer2", so Lotus Tune shows up in the
// desktop's media centre (bar, panel, GNOME/KDE...) and answers to the
// media keys and to the headphone/Bluetooth buttons.
//
// The bus is always used in the main thread (the UI's), with no event
// loop of its own and no blocking calls: the bus never freezes.
//
// Note about the adaptors: Qt demands a QObject with Q_OBJECT for each
// D-Bus interface, but moc does not accept Q_OBJECT in nested classes
// ("Meta object features not supported for nested classes"). That is
// why MprisRootAdaptor and MprisPlayerAdaptor are declared here at the
// same level as Mpris (they are the "inner classes" in practice). Mpris
// befriends them so their internal getters are not exposed.
class Player;
class Mpris;
class MprisRootAdaptor;
class MprisPlayerAdaptor;

class Mpris : public QObject
{
    Q_OBJECT
    friend class MprisRootAdaptor;
    friend class MprisPlayerAdaptor;

public:
    // `player` (optional) is the app's mpv engine: with it MPRIS asks for
    // the REAL position and duration instead of reflecting what the QML
    // layer thinks is happening. main.cpp injects it.
    explicit Mpris(Player *player = nullptr, QObject *parent = nullptr);
    ~Mpris() override;

    // --- API towards the app (context property "mpris" in QML) -------------

    // New track playing. durationSeconds <= 0 becomes 0. A call with no
    // data at all (empty title/artist/album/cover and duration <= 0) is
    // dropped: "phantom" metadata is never published (it empties the
    // track and breaks the desktop widgets).
    Q_INVOKABLE void updateMetadata(const QString &title, const QString &artist,
                                    const QString &album, double durationSeconds,
                                    const QString &artUrl);
    // Playback state and current position. stopped=true forces
    // PlaybackStatus="Stopped" even if playing arrives as true.
    Q_INVOKABLE void updatePlayback(bool playing, double positionSeconds,
                                    bool stopped = false);
    Q_INVOKABLE void setShuffle(bool shuffle);
    // Repeat state of the app's button ("None" | "Playlist" |
    // "Track"), so the system controls paint it the same way.
    Q_INVOKABLE void setLoopStatus(const QString &status);
    // Reflects on the bus the volume set by the app (0..150 %).
    Q_INVOKABLE void updateVolume(int percent);

    // Is there (or is there loading) a file in the engine? It is used to
    // avoid lying with PlaybackStatus/CanSeek when mpv is idle.
    bool canSeekNow() const;

signals:
    // Commands coming from the bus / media keys. Main.qml connects them
    // to the player (player.playPause(), player.seek(...), etc.).
    void playRequested();
    void pauseRequested();
    void playPauseRequested();
    void nextRequested();
    void previousRequested();
    void stopRequested();
    // Target position in absolute seconds.
    void seekRequested(double seconds);
    void setPositionRequested(double seconds);

    // Extras useful to complete the MPRIS interface.
    void volumeRequested(double volume);          // Volume (0..1) set by the client
    void openUriRequested(const QString &uri);    // OpenUri()
    void quitRequested();                         // Quit()
    void raiseRequested();                        // Raise() -> bring the window to the front

private:
    QVariantMap metadata() const;
    qint64 positionUs() const;
    // Real duration of the current track in µs (0 if not known yet).
    qint64 effectiveLengthUs() const;
    // Clamps a position to [0, duration] so impossible positions are
     // not published (they break the position/length maths of the
     // widgets).
    qint64 clampToTrack(qint64 us) const;
    // Seek order shared by Seek()/SetPosition(): it applies, delegates in
     // Player::seek() and lets Player::seeked() announce Seeked just once
     // with the position the engine really applied.
    void requestSeek(qint64 targetUs, bool absolute);
    void announceSeek(qint64 us);
    // Player::seeked -> announces Seeked + PropertiesChanged(Position) on the bus.
    void onPlayerSeeked(double seconds);
    // Player::positionChanged (the engine's ~240 ms timer) -> publishes
     // Position on the bus with a throttle (~500 ms). MPRIS allows reading
     // Position, but clients like Quickshell do NOT do a GET: they
     // extrapolate from the last sample received. Without these periodic
     // pushes the widget keeps moving from the previous track's position
     // after a Next (running ahead while the new track buffers).
    void onPlayerPositionChanged();
    // Recalculates CanSeek when the engine state changes.
    void refreshCanSeek();

    // Sends org.freedesktop.DBus.Properties.PropertiesChanged in an
     // asynchronous way (it does not block the bus). See the note in
     // mpris.cpp: Qt does not emit it automatically when a Q_PROPERTY
     // changes.
    void emitPropertiesChanged(const QString &interface, const QVariantMap &changed,
                               const QStringList &invalidated = QStringList());

    MprisRootAdaptor *m_rootAdaptor = nullptr;
    MprisPlayerAdaptor *m_playerAdaptor = nullptr;

    Player *m_player = nullptr;       // mpv engine (it can be nullptr)
    QTimer m_seekConfirm;             // Seeked confirmation with the real position
    qint64 m_lastSeekUs = -1;         // last position announced with Seeked
    qint64 m_lastPosPublishMs = -1;   // throttle of the periodic Position publication
    qint64 m_lastPosPublishedUs = -1; // last published position (reset detection)
    bool m_canSeek = true;            // CanSeek cache (it is announced on change)

    QDBusObjectPath m_trackId;      // /lotustune/track/<n>
    int m_trackCounter = 0;
    bool m_hasTrack = false;

    QString m_title;
    QString m_artist;
    QString m_album;
    QString m_artUrl;
    qint64 m_lengthUs = 0;          // duration in microseconds

    QString m_playbackStatus = QStringLiteral("Stopped");
    QString m_loopStatus = QStringLiteral("None");
    double m_rate = 1.0;
    bool m_shuffle = false;
    double m_volume = 1.0;
    double m_position = 0.0;        // seconds
};

// Adaptor of org.mpris.MediaPlayer2 (identity and life cycle).
// constant getters -> they do not need PropertiesChanged.
class MprisRootAdaptor : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2")
    Q_PROPERTY(QString Identity READ identity CONSTANT)
    Q_PROPERTY(QString DesktopEntry READ desktopEntry CONSTANT)
    Q_PROPERTY(bool CanQuit READ canQuit CONSTANT)
    Q_PROPERTY(bool CanRaise READ canRaise CONSTANT)
    Q_PROPERTY(bool HasTrackList READ hasTrackList CONSTANT)
    Q_PROPERTY(QStringList SupportedUriSchemes READ supportedUriSchemes CONSTANT)
    Q_PROPERTY(QStringList SupportedMimeTypes READ supportedMimeTypes CONSTANT)

public:
    explicit MprisRootAdaptor(Mpris *parent);

    QString identity() const { return QStringLiteral("LotusTune"); }
    QString desktopEntry() const { return QStringLiteral("lotustune"); }
    bool canQuit() const { return true; }
    bool canRaise() const { return true; }
    bool hasTrackList() const { return false; }
    QStringList supportedUriSchemes() const
    {
        return {QStringLiteral("http"), QStringLiteral("https"), QStringLiteral("file")};
    }
    QStringList supportedMimeTypes() const
    {
        return {QStringLiteral("audio/mpeg"), QStringLiteral("audio/ogg"),
                QStringLiteral("audio/flac"), QStringLiteral("audio/mp4"),
                QStringLiteral("audio/webm")};
    }

public slots:
    void Quit();
    void Raise();

private:
    Mpris *m_mpris;
};

// Adaptor of org.mpris.MediaPlayer2.Player (transport, state and metadata).
// The mutable properties use Q_PROPERTY + NOTIFY, but the real
// PropertiesChanged is sent by Mpris (see emitPropertiesChanged): Qt does
// not generate it automatically.
class MprisPlayerAdaptor : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
    Q_PROPERTY(QString PlaybackStatus READ playbackStatus NOTIFY playbackStatusChanged)
    Q_PROPERTY(QString LoopStatus READ loopStatus WRITE setLoopStatus NOTIFY loopStatusChanged)
    Q_PROPERTY(double Rate READ rate NOTIFY rateChanged)
    Q_PROPERTY(bool Shuffle READ shuffle WRITE setShuffle NOTIFY shuffleChanged)
    Q_PROPERTY(QVariantMap Metadata READ metadata NOTIFY metadataChanged)
    Q_PROPERTY(double Volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(qlonglong Position READ position)
    Q_PROPERTY(double MinimumRate READ minimumRate CONSTANT)
    Q_PROPERTY(double MaximumRate READ maximumRate CONSTANT)
    Q_PROPERTY(bool CanGoNext READ canGoNext CONSTANT)
    Q_PROPERTY(bool CanGoPrevious READ canGoPrevious CONSTANT)
    Q_PROPERTY(bool CanPlay READ canPlay CONSTANT)
    Q_PROPERTY(bool CanPause READ canPause CONSTANT)
    Q_PROPERTY(bool CanSeek READ canSeek NOTIFY canSeekChanged)
    Q_PROPERTY(bool CanControl READ canControl CONSTANT)

public:
    explicit MprisPlayerAdaptor(Mpris *parent);

    QString playbackStatus() const { return m_mpris->m_playbackStatus; }
    QString loopStatus() const { return m_mpris->m_loopStatus; }
    double rate() const { return m_mpris->m_rate; }
    bool shuffle() const { return m_mpris->m_shuffle; }
    QVariantMap metadata() const { return m_mpris->metadata(); }
    double volume() const { return m_mpris->m_volume; }
    qlonglong position() const { return m_mpris->positionUs(); }
    double minimumRate() const { return 1.0; }
    double maximumRate() const { return 1.0; }
    bool canGoNext() const { return true; }
    bool canGoPrevious() const { return true; }
    bool canPlay() const { return true; }
    bool canPause() const { return true; }
    bool canSeek() const { return m_mpris->m_canSeek; }
    bool canControl() const { return true; }

public slots:
    void Play();
    void Pause();
    void PlayPause();
    void Next();
    void Previous();
    void Stop();
    void Seek(qint64 offsetUs);
    void SetPosition(const QDBusObjectPath &trackId, qint64 positionUs);
    void OpenUri(const QString &uri);

public:
    // WRITE of the Q_PROPERTY. They are not declared as slots so they are
     // not exported as extra D-Bus methods; Qt calls the setter through
     // QMetaProperty.
    void setLoopStatus(const QString &status);
    void setShuffle(bool shuffle);
    void setVolume(double volume);

signals:
    // NOTIFY signals of the properties. Careful: QDBusAbstractAdaptor only
     // forwards the declared signals to the bus; it does NOT emit
     // org.freedesktop.DBus.Properties.PropertiesChanged by itself. That
     // is why Mpris sends that PropertiesChanged by hand
     // (emitPropertiesChanged).
    void playbackStatusChanged();
    void loopStatusChanged();
    void rateChanged();
    void shuffleChanged();
    void metadataChanged();
    void volumeChanged();
    void canSeekChanged();
    // Standard MPRIS signal: position change after a seek.
    void Seeked(qint64 position);

private:
    Mpris *m_mpris;
};
