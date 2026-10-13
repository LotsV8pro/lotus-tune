#pragma once

#include <QDBusAbstractAdaptor>
#include <QDBusObjectPath>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariantMap>

// Integración con MPRIS2 (org.mpris.MediaPlayer2) sobre la sesión de D-Bus.
//
// Publica el servicio "org.mpris.MediaPlayer2.lotustune" y el objeto
// "/org/mpris/MediaPlayer2", de modo que Lotus Tune aparece en el centro
// multimedia del escritorio (barra, panel, GNOME/KDE, etc.) y responde a las
// teclas multimedia y a los botones de auriculares/Bluetooth.
//
// El bus se usa siempre en el hilo principal (el de la UI), sin bucle de
// eventos propio y sin llamadas bloqueantes: nunca se congela el bus.
//
// Nota sobre los adaptadores: Qt exige un QObject con Q_OBJECT por cada
// interfaz D-Bus, pero moc no admite Q_OBJECT en clases anidadas ("Meta object
// features not supported for nested classes"). Por eso MprisRootAdaptor y
// MprisPlayerAdaptor se declaran aquí al mismo nivel que Mpris (son las
// "inner classes" a efectos prácticos). Mpris les concede amistad para no
// exponer getters internos.
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
    // `player` (opcional) es el motor mpv de la app: con él MPRIS consulta la
    // posición y la duración REALES en lugar de reflejar lo que la capa QML
    // cree que pasa. main.cpp lo inyecta.
    explicit Mpris(Player *player = nullptr, QObject *parent = nullptr);
    ~Mpris() override;

    // --- API hacia la app (context property "mpris" en QML) -------------

    // Nuevo track en reproducción. durationSeconds <= 0 se traduce a 0.
    // Una llamada sin ningún dato (título/artista/álbum/portada vacíos y
    // duración <= 0) se descarta: nunca se publican metadatos "fantasma"
    // (eso vacía el track y rompe los widgets del escritorio).
    Q_INVOKABLE void updateMetadata(const QString &title, const QString &artist,
                                    const QString &album, double durationSeconds,
                                    const QString &artUrl);
    // Estado de reproducción y posición actual. stopped=true fuerza
    // PlaybackStatus="Stopped" aunque playing llegue a true.
    Q_INVOKABLE void updatePlayback(bool playing, double positionSeconds,
                                    bool stopped = false);
    Q_INVOKABLE void setShuffle(bool shuffle);
    // Refleja en el bus el volumen fijado por la app (0..150 %).
    Q_INVOKABLE void updateVolume(int percent);

    // ¿Hay (o se está cargando) un fichero en el motor? Se usa para no
    // mentir con PlaybackStatus/CanSeek cuando mpv está en idle.
    bool canSeekNow() const;

signals:
    // Órdenes que llegan desde el bus / teclado multimedia. Main.qml las
    // conecta al reproductor (player.playPause(), player.seek(...), etc.).
    void playRequested();
    void pauseRequested();
    void playPauseRequested();
    void nextRequested();
    void previousRequested();
    void stopRequested();
    // Posición destino en segundos absolutos.
    void seekRequested(double seconds);
    void setPositionRequested(double seconds);

    // Extras útiles para completar la interfaz MPRIS.
    void volumeRequested(double volume);          // Volume (0..1) fijado por el cliente
    void openUriRequested(const QString &uri);    // OpenUri()
    void quitRequested();                         // Quit()
    void raiseRequested();                        // Raise() -> traer la ventana al frente

private:
    QVariantMap metadata() const;
    qint64 positionUs() const;
    // Duración real del track en curso en µs (0 si aún no se conoce).
    qint64 effectiveLengthUs() const;
    // Limita una posición a [0, duración] para no publicar posiciones
    // imposibles (rompen el cálculo position/length de los widgets).
    qint64 clampToTrack(qint64 us) const;
    // Orden de seek compartida por Seek()/SetPosition(): aplica, delega en
    // Player::seek() y deja que Player::seeked() anuncie Seeked una sola vez
    // con la posición realmente aplicada por el motor.
    void requestSeek(qint64 targetUs, bool absolute);
    void announceSeek(qint64 us);
    // Player::seeked -> anuncia Seeked + PropertiesChanged(Position) en el bus.
    void onPlayerSeeked(double seconds);
    // Player::positionChanged (timer ~240ms del motor) -> publica Position en el
    // bus con throttle (~500ms). MPRIS permite leer Position, pero clientes como
    // Quickshell NO hacen GET: extrapolan la última muestra recibida. Sin estos
    // push periódicos el widget sigue avanzando desde la posición de la pista
    // anterior tras un Next (adelantado mientras la nueva pista bufferiza).
    void onPlayerPositionChanged();
    // Recalcula CanSeek cuando cambia el estado del motor.
    void refreshCanSeek();

    // Envía org.freedesktop.DBus.Properties.PropertiesChanged de forma
    // asíncrona (no bloquea el bus). Ver nota en mpris.cpp: Qt no lo emite
    // automáticamente al cambiar una Q_PROPERTY.
    void emitPropertiesChanged(const QString &interface, const QVariantMap &changed,
                               const QStringList &invalidated = QStringList());

    MprisRootAdaptor *m_rootAdaptor = nullptr;
    MprisPlayerAdaptor *m_playerAdaptor = nullptr;

    Player *m_player = nullptr;       // motor mpv (puede ser nullptr)
    QTimer m_seekConfirm;             // confirmación de Seeked con la posición real
    qint64 m_lastSeekUs = -1;         // última posición anunciada con Seeked
    qint64 m_lastPosPublishMs = -1;   // throttle de la publicación periódica de Position
    qint64 m_lastPosPublishedUs = -1; // última posición publicada (detección de reset)
    bool m_canSeek = true;            // cache de CanSeek (se anuncia al cambiar)

    QDBusObjectPath m_trackId;      // /lotustune/track/<n>
    int m_trackCounter = 0;
    bool m_hasTrack = false;

    QString m_title;
    QString m_artist;
    QString m_album;
    QString m_artUrl;
    qint64 m_lengthUs = 0;          // duración en microsegundos

    QString m_playbackStatus = QStringLiteral("Stopped");
    QString m_loopStatus = QStringLiteral("None");
    double m_rate = 1.0;
    bool m_shuffle = false;
    double m_volume = 1.0;
    double m_position = 0.0;        // segundos
};

// Adaptador de org.mpris.MediaPlayer2 (identidad y ciclo de vida).
// getters constantes -> no necesitan PropertiesChanged.
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

// Adaptador de org.mpris.MediaPlayer2.Player (transporte, estado y metadatos).
// Las propiedades mutables usan Q_PROPERTY + NOTIFY, pero el
// PropertiesChanged real lo manda Mpris (ver emitPropertiesChanged): Qt no lo
// genera automáticamente.
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
    // WRITE de Q_PROPERTY. No se declaran como slots para no exportarlos como
    // métodos D-Bus adicionales; Qt llama al setter vía QMetaProperty.
    void setLoopStatus(const QString &status);
    void setShuffle(bool shuffle);
    void setVolume(double volume);

signals:
    // Señales NOTIFY de las propiedades. Ojo: QDBusAbstractAdaptor sólo
    // reenvía las señales declaradas al bus; NO emite
    // org.freedesktop.DBus.Properties.PropertiesChanged por sí mismo. Por eso
    // Mpris envía ese PropertiesChanged manualmente (emitPropertiesChanged).
    void playbackStatusChanged();
    void loopStatusChanged();
    void rateChanged();
    void shuffleChanged();
    void metadataChanged();
    void volumeChanged();
    void canSeekChanged();
    // Señal MPRIS estándar: cambio de posición tras un seek.
    void Seeked(qint64 position);

private:
    Mpris *m_mpris;
};
