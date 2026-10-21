#include "mpris.h"

#include "player.h"

#include <QDBusConnection>
#include <QDBusError>
#include <QDBusMessage>
#include <QDateTime>

#include <QDebug>
#include <QtGlobal>

// Exact names required by MPRIS2.
static constexpr const char *kServiceName = "org.mpris.MediaPlayer2.lotustune";
static constexpr const char *kObjectPath = "/org/mpris/MediaPlayer2";
static constexpr const char *kTrackIdPrefix = "/lotustune/track/";
static constexpr const char *kPlayerInterface = "org.mpris.MediaPlayer2.Player";

// ms waited for mpv to apply a seek before announcing the REAL position on
// the bus (see Mpris::confirmSeek).
static constexpr int kSeekConfirmMs = 250;

Mpris::Mpris(Player *player, QObject *parent)
    : QObject(parent)
    , m_player(player)
{
    m_trackId = QDBusObjectPath(QString::fromLatin1(kTrackIdPrefix) + QStringLiteral("0"));
    m_canSeek = canSeekNow();

    // Asynchronous seek confirmation: it is ONLY used when there is no mpv
    // engine (without Player::seeked there is no way to know the real
    // position). With an engine, Player::seeked announces it once by
    // itself.
    m_seekConfirm.setSingleShot(true);
    m_seekConfirm.setInterval(kSeekConfirmMs);
    connect(&m_seekConfirm, &QTimer::timeout, this, [this] {
        const qint64 us = clampToTrack(positionUs());
        if (us != m_lastSeekUs)
            announceSeek(us);
    });

    // CanSeek reflects whether a track is loaded: without it there is
    // nothing to move. Player::seeked is the single point EVERY seek goes
    // through (the app's and the ones asked by MPRIS): it is translated
    // into the bus' Seeked signal.
    if (m_player) {
        connect(m_player, &Player::stateChanged, this, &Mpris::refreshCanSeek);
        connect(m_player, &Player::seeked, this, &Mpris::onPlayerSeeked);
        connect(m_player, &Player::positionChanged, this, &Mpris::onPlayerPositionChanged);
    }

    // The adaptors are created as children of this object; registerObject()
    // with ExportAdaptors publishes them automatically. One adaptor per
    // interface.
    m_rootAdaptor = new MprisRootAdaptor(this);
    m_playerAdaptor = new MprisPlayerAdaptor(this);

    // Everything happens in the main thread: no threads nor own loops.
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) {
        qWarning() << "[mpris] no hay sesión D-Bus; integración MPRIS desactivada";
        return;
    }

    // The object first and the name after, so it is ready when taken.
    if (!bus.registerObject(QString::fromLatin1(kObjectPath), this,
                            QDBusConnection::ExportAdaptors)) {
        qWarning() << "[mpris] no se pudo registrar" << kObjectPath
                   << bus.lastError().message();
        return;
    }
    if (!bus.registerService(QString::fromLatin1(kServiceName)))
        qWarning() << "[mpris] no se pudo tomar el nombre" << kServiceName
                   << bus.lastError().message();
    else
        qInfo() << "[mpris]" << kServiceName << "listo";
}

Mpris::~Mpris()
{
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected())
        return;
    // Release the name and the object (idempotent if they never got registered).
    bus.unregisterService(QString::fromLatin1(kServiceName));
    bus.unregisterObject(QString::fromLatin1(kObjectPath));
}

void Mpris::updateMetadata(const QString &title, const QString &artist,
                           const QString &album, double durationSeconds,
                           const QString &artUrl)
{
    // Transition without data (end of the queue, track load, port still
    // resolving...): publishing that would EMPTY the metadata on the bus
    // and break the desktop widgets (title -> "Unknown Title", length -> 0
    // and the widget collapses or loses the progress bar). MPRIS allows
    // keeping the last real metadata while it is "Stopped".
    if (title.isEmpty() && artist.isEmpty() && album.isEmpty()
        && artUrl.isEmpty() && durationSeconds <= 0.0) {
        if (!m_hasTrack)
            return;                    // there has not been any real track yet
        // The duration is only refreshed if the engine already knows it.
        if (m_player && m_player->duration() > 0.0 && m_lengthUs <= 0)
            m_lengthUs = qRound64(m_player->duration() * 1e6);
        if (m_playerAdaptor)
            emit m_playerAdaptor->metadataChanged();
        emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                              {{QStringLiteral("Metadata"), metadata()}});
        return;
    }

    // The trackid only changes when the IDENTITY of the track changes.
    // Before it was regenerated with any difference (including empty
    // fields), so a SetPosition from the widget was ignored (trackid !=
    // trackid) and the UI treated the same track as a new one. Rules:
    //  - different and non empty title  -> new track;
    //  - artist different from a known one -> new track;
    //  - a field that arrives empty is "still unknown", not a change.
    const bool trackChanged = !m_hasTrack
                              || (!title.isEmpty() && title != m_title)
                              || (!artist.isEmpty() && !m_artist.isEmpty()
                                  && artist != m_artist);
    if (trackChanged) {
        ++m_trackCounter;
        m_trackId = QDBusObjectPath(QString::fromLatin1(kTrackIdPrefix)
                                    + QString::number(m_trackCounter));
    }

    m_title = title;
    m_artist = artist;
    m_album = album;
    m_artUrl = artUrl;
    if (durationSeconds > 0.0)
        m_lengthUs = qRound64(durationSeconds * 1e6);
    else if (trackChanged)
        m_lengthUs = 0;                 // new track: the duration is still ignored
    // Same track with a momentarily 0 duration: the known one is kept so
     // "mpris:length = 0" is not published (the widgets penalise that
     // metadata).
    m_hasTrack = true;

    if (m_playerAdaptor)
        emit m_playerAdaptor->metadataChanged();
    emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                          {{QStringLiteral("Metadata"), metadata()}});
    if (trackChanged) {
        m_position = 0.0;
        if (m_playerAdaptor) {
            emit m_playerAdaptor->Seeked(0);
            emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                                  {{QStringLiteral("Position"), qint64(0)}});
            emit m_playerAdaptor->playbackStatusChanged();
            emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                                  {{QStringLiteral("PlaybackStatus"), m_playbackStatus}});
        }
    }
}

void Mpris::updatePlayback(bool playing, double positionSeconds, bool stopped)
{
    // The position is always stored (for Seek/SetPosition), but only a
     // state change triggers PropertiesChanged.
    m_position = qMax(0.0, positionSeconds);

    // The real rules:
    //  - with no track loaded it can only be "Stopped" (never a phantom
    //    "Playing" nor a "Paused" inherited from the transition);
    //  - an explicit "Stopped" rules;
    //  - with a track, Playing/Paused as the app asks.
    QString status;
    if (m_player && !m_player->hasFile())
        status = QStringLiteral("Stopped");
    else if (stopped)
        status = QStringLiteral("Stopped");
    else if (playing)
        status = QStringLiteral("Playing");
    else
        status = QStringLiteral("Paused");

    if (status != m_playbackStatus) {
        m_playbackStatus = status;
        if (m_playerAdaptor)
            emit m_playerAdaptor->playbackStatusChanged();
        emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                              {{QStringLiteral("PlaybackStatus"), status}});
    }
}

void Mpris::setShuffle(bool shuffle)
{
    if (m_shuffle == shuffle)
        return;
    m_shuffle = shuffle;
    if (m_playerAdaptor)
        emit m_playerAdaptor->shuffleChanged();
    emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                          {{QStringLiteral("Shuffle"), m_shuffle}});
}

void Mpris::setLoopStatus(const QString &status)
{
    if (m_loopStatus == status)
        return;
    m_loopStatus = status;
    if (m_playerAdaptor)
        emit m_playerAdaptor->loopStatusChanged();
    emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                          {{QStringLiteral("LoopStatus"), m_loopStatus}});
}

// Reflects on the bus the volume set by the app itself (e.g. when raising/
// lowering it with the arrows or muting with M), so the system widget does
// not stay with an outdated value.
void Mpris::updateVolume(int percent)
{
    const double v = qBound(0.0, percent / 100.0, 1.0);
    if (qAbs(v - m_volume) < 1e-6)
        return;
    m_volume = v;
    if (m_playerAdaptor)
        emit m_playerAdaptor->volumeChanged();
    emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                          {{QStringLiteral("Volume"), v}});
}

QVariantMap Mpris::metadata() const
{
    QVariantMap m;
    if (!m_hasTrack)
        return m;                 // no real track: no phantom trackid
    m.insert(QStringLiteral("mpris:trackid"), QVariant::fromValue(m_trackId));
    if (!m_title.isEmpty())
        m.insert(QStringLiteral("xesam:title"), m_title);
    if (!m_artist.isEmpty())
        m.insert(QStringLiteral("xesam:artist"), QStringList{m_artist});
    if (!m_album.isEmpty())
        m.insert(QStringLiteral("xesam:album"), m_album);
    const qint64 length = effectiveLengthUs();
    if (length > 0)
        m.insert(QStringLiteral("mpris:length"), length);
    if (!m_artUrl.isEmpty())
        m.insert(QStringLiteral("mpris:artUrl"), m_artUrl);
    if (m_player && !m_player->currentUrl().isEmpty())
        m.insert(QStringLiteral("xesam:url"), m_player->currentUrl());
    return m;
}

qint64 Mpris::effectiveLengthUs() const
{
    if (m_lengthUs > 0)
        return m_lengthUs;
    // The QML layer may not have forwarded the duration yet (or may have
    // lost it in a transition): the engine is asked, and it is the truth.
    if (m_player && m_player->duration() > 0.0)
        return qRound64(m_player->duration() * 1e6);
    return 0;
}

qint64 Mpris::clampToTrack(qint64 us) const
{
    if (us < 0)
        return 0;
    const qint64 length = effectiveLengthUs();
    if (length > 0 && us > length)
        return length;
    return us;
}

qint64 Mpris::positionUs() const
{
    // Prefer the engine: it reflects mpv's time-pos in real time (also
    // while paused), not QML's 1 s beat.
    if (m_player)
        return qMax<qint64>(0, qRound64(m_player->position() * 1000000.0));
    return qMax<qint64>(0, qRound64(m_position * 1000000.0));
}

bool Mpris::canSeekNow() const
{
    return m_player ? m_player->hasFile() : true;
}

void Mpris::refreshCanSeek()
{
    const bool can = canSeekNow();
    if (can == m_canSeek)
        return;
    m_canSeek = can;
    if (m_playerAdaptor)
        emit m_playerAdaptor->canSeekChanged();
    emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                          {{QStringLiteral("CanSeek"), can}});
}

void Mpris::requestSeek(qint64 targetUs, bool absolute)
{
    // Without a loaded track there is nothing to move: ignoring the
    // command is better than publishing a made up position.
    if (m_player && !m_player->hasFile())
        return;

    // Clamp to [0, duration]: a target over the duration makes mpv jump
    // to eof and breaks the position/length maths of the widgets.
    targetUs = clampToTrack(targetUs);
    m_position = double(targetUs) / 1000000.0;

    // QML connects these signals to the player (player.seek(seconds)).
    if (absolute)
        emit setPositionRequested(m_position);
    else
        emit seekRequested(m_position);

    // With an engine, Player::seek() -> Player::seeked() will announce
    // Seeked just once (it also covers the seeks the app itself makes).
    // Without an engine there is no confirmation possible: it is
    // announced here with the already clamped target.
    if (!m_player) {
        announceSeek(targetUs);
        m_seekConfirm.start();
    }
}

void Mpris::onPlayerSeeked(double seconds)
{
    const qint64 us = clampToTrack(qRound64(seconds * 1000000.0));
    m_position = double(us) / 1000000.0;
    // Standard MPRIS seek signal: a single emission per seek (the engine
    // sends it, whether the seek came from the app or from the bus).
    announceSeek(us);
    // The spec does not force resending Position, but the desktop widgets
    // (Quickshell and alike) resync with it after a seek. It is emitted
    // ONLY on the seek, not on every playback tick, so the bus is not
    // flooded.
    emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                          {{QStringLiteral("Position"), us}});
}

void Mpris::onPlayerPositionChanged()
{
    if (m_playbackStatus != QLatin1String("Playing"))
        return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const qint64 us = clampToTrack(positionUs());
    // The track changes (or there is a seek backwards): the engine resets
    // the position and it usually matches the start of a new track. It is
    // published WITHOUT the throttle so the clients do not extrapolate
    // the previous track's position (the widget stayed ahead while the new
    // one buffered).
    const bool positionReset = m_lastPosPublishedUs >= 0
                               && us + 200000 < m_lastPosPublishedUs;
    if (!positionReset && now - m_lastPosPublishMs < 500)
        return;
    m_lastPosPublishMs = now;
    m_lastPosPublishedUs = us;
    emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                          {{QStringLiteral("Position"), us}});
}

void Mpris::announceSeek(qint64 us)
{
    m_lastSeekUs = us;
    if (m_playerAdaptor)
        emit m_playerAdaptor->Seeked(us);
}

void Mpris::emitPropertiesChanged(const QString &interface, const QVariantMap &changed,
                                  const QStringList &invalidated)
{
    // Qt's QDBusAbstractAdaptor relays declared signals, but it does NOT emit
    // org.freedesktop.DBus.Properties.PropertiesChanged by itself (not even
    // with Q_PROPERTY + NOTIFY). We send it ourselves: send() is
    // asynchronous and does not block the bus. The MPRIS clients (bars,
    // media keys) do depend on this signal to refresh their controls.
    QDBusMessage sig = QDBusMessage::createSignal(
        QString::fromLatin1(kObjectPath),
        QStringLiteral("org.freedesktop.DBus.Properties"),
        QStringLiteral("PropertiesChanged"));
    sig << interface << changed << invalidated;
    QDBusConnection::sessionBus().send(sig);
}

// ---------------------------------------------------------------------------
// MprisRootAdaptor
// ---------------------------------------------------------------------------

MprisRootAdaptor::MprisRootAdaptor(Mpris *parent)
    : QDBusAbstractAdaptor(parent)
    , m_mpris(parent)
{
}

void MprisRootAdaptor::Quit()
{
    // The app decides whether to close; here the intent is only
    // forwarded.
    emit m_mpris->quitRequested();
}

void MprisRootAdaptor::Raise()
{
    // CanRaise = true: main.cpp connects this signal to raise()/
    // showNormal()/requestActivate() of the main window.
    emit m_mpris->raiseRequested();
}

// ---------------------------------------------------------------------------
// MprisPlayerAdaptor
// ---------------------------------------------------------------------------

MprisPlayerAdaptor::MprisPlayerAdaptor(Mpris *parent)
    : QDBusAbstractAdaptor(parent)
    , m_mpris(parent)
{
}

void MprisPlayerAdaptor::Play()
{
    emit m_mpris->playRequested();
}

void MprisPlayerAdaptor::Pause()
{
    emit m_mpris->pauseRequested();
}

void MprisPlayerAdaptor::PlayPause()
{
    emit m_mpris->playPauseRequested();
}

void MprisPlayerAdaptor::Next()
{
    emit m_mpris->nextRequested();
}

void MprisPlayerAdaptor::Previous()
{
    emit m_mpris->previousRequested();
}

void MprisPlayerAdaptor::Stop()
{
    emit m_mpris->stopRequested();
}

void MprisPlayerAdaptor::Seek(qint64 offsetUs)
{
    // Seek() is relative (it can be negative); the app expects absolute
    // seconds.
    m_mpris->requestSeek(m_mpris->positionUs() + offsetUs, false);
}

void MprisPlayerAdaptor::SetPosition(const QDBusObjectPath &trackId, qint64 positionUs)
{
    // Ignore requests for a track that is not playing any more (as the
    // specification says).
    if (trackId.path() != m_mpris->m_trackId.path())
        return;

    m_mpris->requestSeek(positionUs, true);
}

void MprisPlayerAdaptor::OpenUri(const QString &uri)
{
    emit m_mpris->openUriRequested(uri);
}

void MprisPlayerAdaptor::setLoopStatus(const QString &status)
{
    // Only "None" is supported; Track/Playlist are ignored so it does not lie.
    if (status != QStringLiteral("None"))
        return;
    if (m_mpris->m_loopStatus == status)
        return;
    m_mpris->m_loopStatus = status;
    emit loopStatusChanged();
    m_mpris->emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                                   {{QStringLiteral("LoopStatus"), status}});
}

void MprisPlayerAdaptor::setShuffle(bool shuffle)
{
    m_mpris->setShuffle(shuffle);
}

void MprisPlayerAdaptor::setVolume(double volume)
{
    volume = qBound(0.0, volume, 1.0);
    if (qAbs(volume - m_mpris->m_volume) < 1e-6)
        return;
    m_mpris->m_volume = volume;
    emit volumeChanged();
    m_mpris->emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                                   {{QStringLiteral("Volume"), volume}});
    // The app applies the real volume in the engine (mpv).
    emit m_mpris->volumeRequested(volume);
}
