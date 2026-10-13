#include "mpris.h"

#include "player.h"

#include <QDBusConnection>
#include <QDBusError>
#include <QDBusMessage>
#include <QDateTime>

#include <QDebug>
#include <QtGlobal>

// Nombres exactos que exige MPRIS2.
static constexpr const char *kServiceName = "org.mpris.MediaPlayer2.lotustune";
static constexpr const char *kObjectPath = "/org/mpris/MediaPlayer2";
static constexpr const char *kTrackIdPrefix = "/lotustune/track/";
static constexpr const char *kPlayerInterface = "org.mpris.MediaPlayer2.Player";

// ms que se esperan a que mpv aplique un seek antes de anunciar la posición
// REAL en el bus (ver Mpris::confirmSeek).
static constexpr int kSeekConfirmMs = 250;

Mpris::Mpris(Player *player, QObject *parent)
    : QObject(parent)
    , m_player(player)
{
    m_trackId = QDBusObjectPath(QString::fromLatin1(kTrackIdPrefix) + QStringLiteral("0"));
    m_canSeek = canSeekNow();

    // Confirmación asíncrona del seek: SOLO se usa cuando no hay motor mpv
    // (sin Player::seeked no hay forma de saber la posición real). Con motor,
    // Player::seeked anuncia él mismo una única vez.
    m_seekConfirm.setSingleShot(true);
    m_seekConfirm.setInterval(kSeekConfirmMs);
    connect(&m_seekConfirm, &QTimer::timeout, this, [this] {
        const qint64 us = clampToTrack(positionUs());
        if (us != m_lastSeekUs)
            announceSeek(us);
    });

    // CanSeek refleja si hay pista cargada: sin ella no hay nada que mover.
    // Player::seeked es el punto único por el que pasan TODOS los seeks (los
    // de la app y los pedidos por MPRIS): se traduce a la señal Seeked del bus.
    if (m_player) {
        connect(m_player, &Player::stateChanged, this, &Mpris::refreshCanSeek);
        connect(m_player, &Player::seeked, this, &Mpris::onPlayerSeeked);
        connect(m_player, &Player::positionChanged, this, &Mpris::onPlayerPositionChanged);
    }

    // Los adaptadores se crean como hijos de este objeto; registerObject() con
    // ExportAdaptors los publica automáticamente. Un adaptador por interfaz.
    m_rootAdaptor = new MprisRootAdaptor(this);
    m_playerAdaptor = new MprisPlayerAdaptor(this);

    // Todo ocurre en el hilo principal: sin hilos ni bucles propios.
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) {
        qWarning() << "[mpris] no hay sesión D-Bus; integración MPRIS desactivada";
        return;
    }

    // Primero el objeto y luego el nombre, para que al tomarlo ya esté listo.
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
    // Liberar el nombre y el objeto (idempotente si no llegaron a registrarse).
    bus.unregisterService(QString::fromLatin1(kServiceName));
    bus.unregisterObject(QString::fromLatin1(kObjectPath));
}

void Mpris::updateMetadata(const QString &title, const QString &artist,
                           const QString &album, double durationSeconds,
                           const QString &artUrl)
{
    // Transición sin datos (fin de cola, carga de pista, puerto todavía
    // resolviendo...): publicar esto VACIARÍA el metadato en el bus y rompe
    // los widgets del escritorio (título -> "Unknown Title", longitud -> 0 y
    // el widget se colapsa o pierde la barra de progreso). MPRIS permite
    // mantener el último metadato real mientras se está "Stopped".
    if (title.isEmpty() && artist.isEmpty() && album.isEmpty()
        && artUrl.isEmpty() && durationSeconds <= 0.0) {
        if (!m_hasTrack)
            return;                    // aún no ha habido ninguna pista real
        // Sólo se refresca la duración si el motor ya la conoce.
        if (m_player && m_player->duration() > 0.0 && m_lengthUs <= 0)
            m_lengthUs = qRound64(m_player->duration() * 1e6);
        if (m_playerAdaptor)
            emit m_playerAdaptor->metadataChanged();
        emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                              {{QStringLiteral("Metadata"), metadata()}});
        return;
    }

    // El trackid sólo cambia cuando cambia la IDENTIDAD de la pista. Antes se
    // regeneraba con cualquier diferencia (incluidos campos vacíos), con lo
    // que un SetPosition del widget se ignoraba (trackid != trackid) y la UI
    // trataba la misma pista como una nueva. Reglas:
    //  - título distinto y no vacío  -> pista nueva;
    //  - artista distinto de un artista ya conocido -> pista nueva;
    //  - un campo que llega vacío es "todavía desconocido", no un cambio.
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
        m_lengthUs = 0;                 // pista nueva: la duración aún se ignora
    // Misma pista con duración momentáneamente 0: se conserva la conocida para
    // no publicar "mpris:length = 0" (los widgets penalizan esa metadata).
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
    // La posición se guarda siempre (para Seek/SetPosition), pero sólo el
    // cambio de estado dispara PropertiesChanged.
    m_position = qMax(0.0, positionSeconds);

    // Reglas de verdad:
    //  - sin pista cargada sólo puede ser "Stopped" (nunca un "Playing"
    //    fantasma ni un "Paused" heredado de la transición);
    //  - "Stopped" explícito manda;
    //  - con pista, Playing/Paused según lo que pida la app.
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

// Refleja en el bus el volumen que fija la propia app (p. ej. al subir/bajar
// con las flechas o silenciar con M), para que el widget del sistema no se
// quede con un valor obsoleto.
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
        return m;                 // sin pista real: nada de trackid fantasma
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
    // La capa QML puede no haber reenviado la duración todavía (o haberla
    // perdido en una transición): se pregunta al motor, que es la verdad.
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
    // Preferir el motor: refleja time-pos de mpv en tiempo real (también con
    // la reproducción en pausa), no el latido de 1 s de QML.
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
    // Sin pista cargada no hay nada que mover: ignorar la orden es mejor que
    // publicar una posición inventada.
    if (m_player && !m_player->hasFile())
        return;

    // Clampear a [0, duración]: un destino superior a la duración hace que
    // mpv salte a eof y rompe el cálculo position/length de los widgets.
    targetUs = clampToTrack(targetUs);
    m_position = double(targetUs) / 1000000.0;

    // QML conecta estas señales al reproductor (player.seek(seconds)).
    if (absolute)
        emit setPositionRequested(m_position);
    else
        emit seekRequested(m_position);

    // Con motor, Player::seek() -> Player::seeked() anunciará Seeked una sola
    // vez (cubre también los seeks que hace la propia app). Sin motor no habrá
    // confirmación posible: se anuncia aquí con el objetivo ya clampeado.
    if (!m_player) {
        announceSeek(targetUs);
        m_seekConfirm.start();
    }
}

void Mpris::onPlayerSeeked(double seconds)
{
    const qint64 us = clampToTrack(qRound64(seconds * 1000000.0));
    m_position = double(us) / 1000000.0;
    // Señal MPRIS estándar de seek: una única emisión por seek (la manda el
    // motor, tanto si el seek nació en la app como si llegó por el bus).
    announceSeek(us);
    // La spec no obliga a reenviar Position, pero los widgets de escritorio
    // (Quickshell y similares) se resincronizan con él tras un seek. Se emite
    // SOLO en el seek, no en cada tick de reproducción, para no inundar el bus.
    emitPropertiesChanged(QString::fromLatin1(kPlayerInterface),
                          {{QStringLiteral("Position"), us}});
}

void Mpris::onPlayerPositionChanged()
{
    if (m_playbackStatus != QLatin1String("Playing"))
        return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const qint64 us = clampToTrack(positionUs());
    // La pista cambia (o hay un seek hacia atrás): el motor resetea la posición
    // y suele coincidir con el arranque de una pista nueva. Se publica SIN
    // throttle para que los clientes no extrapolen la posición de la pista
    // anterior (el widget se quedaba adelantado mientras la nueva bufferiza).
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
    // Qt's QDBusAbstractAdaptor relays declared signals, pero NO emite
    // org.freedesktop.DBus.Properties.PropertiesChanged por sí mismo (ni
    // siquiera con Q_PROPERTY + NOTIFY). Lo mandamos nosotros: send() es
    // asíncrono y no bloquea el bus. Los clientes MPRIS (barras, teclas
    // multimedia) sí dependen de esta señal para refrescar sus controles.
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
    // La app decide si cierra; aquí solo se reenvía la intención.
    emit m_mpris->quitRequested();
}

void MprisRootAdaptor::Raise()
{
    // CanRaise = true: main.cpp conecta esta señal a raise()/showNormal()/
    // requestActivate() de la ventana principal.
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
    // Seek() es relativo (puede ser negativo); la app espera segundos
    // absolutos.
    m_mpris->requestSeek(m_mpris->positionUs() + offsetUs, false);
}

void MprisPlayerAdaptor::SetPosition(const QDBusObjectPath &trackId, qint64 positionUs)
{
    // Ignorar peticiones para un track que ya no suena (según la especificación).
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
    // Solo se soporta "None"; se ignoran Track/Playlist para no mentir.
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
    // La app aplica el volumen real en el motor (mpv).
    emit m_mpris->volumeRequested(volume);
}
