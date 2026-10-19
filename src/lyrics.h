#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QVariantList>
#include <QVector>

class QJsonArray;
class QJsonObject;
class QNetworkAccessManager;
class QNetworkReply;

// Letras de canciones (YouTube Music -> LRCLIB -> NetEase, sin API key), tal
// que así expuesta a QML como la context property `lyrics`.
//
// El flujo es:
//   1. YouTube Music (primera opción, letra *con tiempos* estilo karaoke):
//      POST /youtubei/v1/search (cliente WEB_REMIX) localiza vídeos de la
//      canción; POST /next devuelve la pestaña «Letra» con su browseId
//      MPLYt_*; POST /browse con el cliente ANDROID_MUSIC devuelve
//      timedLyricsModel.lyricsData con startTimeMilliseconds por línea. De
//      ahí se genera un LRC que se parsea con el mismo código del resto de
//      fuentes. Las canciones cuya pestaña viene `unselectable` (o sin letra)
//      prueban el siguiente vídeo candidato y, si ninguno sirve, siguen las
//      fuentes clásicas.
//   2. LRCLIB /api/get y, si no trae letra sincronizada, /api/search.
//   3. NetEase Cloud Music (búsqueda + /song/lyric).
// Solo cuando ninguna fuente da timestamps se muestra el texto plano (o error).
//
// YouTube Music se consulta SIEMPRE en anónimo: con las cookies de la cuenta
// el browse devuelve «La letra no está disponible» (o 400), y sin ellas
// funciona. No hace falta inicio de sesión para leer letras.
//
// Las respuestas se etiquetan con la trackKey vigente para descartar las de
// peticiones antiguas (el usuario pudo cambiar de pista antes de que llegara
// la red). El LRC se cachea ya parseado para que lineIndexAt(segundos) sea una
// simple búsqueda binaria sobre el vector.
class Lyrics : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    Q_PROPERTY(bool hasLyrics READ hasLyrics NOTIFY changed)
    Q_PROPERTY(bool hasSynced READ hasSynced NOTIFY changed)
    Q_PROPERTY(QString plain READ plain NOTIFY changed)
    Q_PROPERTY(QString synced READ synced NOTIFY changed)   // LRC crudo
    Q_PROPERTY(QVariantList lines READ lines NOTIFY changed) // [{time, text}]
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString trackKey READ trackKey NOTIFY changed)

public:
    explicit Lyrics(QObject *parent = nullptr);

    bool loading() const { return m_loading; }
    bool hasLyrics() const { return m_hasLyrics; }
    bool hasSynced() const { return m_hasSynced; }
    QString plain() const { return m_plain; }
    QString synced() const { return m_synced; }
    QString error() const { return m_error; }
    QString trackKey() const { return m_trackKey; }
    // Líneas ya parseadas (con sus segundos). Es la fuente única de verdad
    // para pintar y para lineIndexAt(), así el índice y la fila resaltada
    // nunca pueden desincronizarse.
    QVariantList lines() const;

    // Busca la letra de una pista. durationSeconds se redondea para /api/get.
    // Si videoId trae el vídeo exacto en reproducción, YouTube Music se pide
    // directamente para ese vídeo (los tiempos corresponden a esa grabación);
    // si no tiene letra, la búsqueda normal actúa como respaldo.
    Q_INVOKABLE void fetch(const QString &artist, const QString &title,
                           double durationSeconds, const QString &videoId = QString());
    Q_INVOKABLE void clear();
    // Índice de la línea LRC activa en `seconds`, -1 si aún no empieza o no hay.
    Q_INVOKABLE int lineIndexAt(double seconds);

signals:
    void changed();

private:
    // Los tests (tests/test_all.cpp) ejercen el parseo de LRC y la búsqueda de
    // línea activa —lógica pura— sin depender de la red.
    friend class TestLotusTune;

    struct LrcLine {
        double time;    // segundos desde el inicio
        QString text;
        // Tiempos POR PALABRA (solo si la fuente los trae): [{t,e,text}].
        // Vacío en las fuentes de nivel de línea (YTM/LRCLIB/NetEase).
        QVariantList words;
        bool instrumental = false;   // tramo sin voz (solo Sonora lo marca)
    };

    // Etapa de la cascada de fuentes; viaja pegada al reply para saber qué
    // handler debe procesar la respuesta.
    enum class Stage {
        YtmSearch,        // POST /youtubei/v1/search  (candidatos)
        YtmNext,          // POST /youtubei/v1/next    (pestaña «Letra»)
        YtmBrowse,        // POST /youtubei/v1/browse  (letra con tiempos)
        LrclibGet,        // GET /api/get
        LrclibSearch,     // GET /api/search
        NeteaseSearch,    // GET music.163.com/api/search/get
        NeteaseLyric      // GET music.163.com/api/song/lyric
    };

    void request(const QUrl &url, Stage stage, const QString &key);
    // Igual que request() pero enviando un cuerpo JSON (YouTube Music).
    void postJson(const QUrl &url, const QJsonObject &body, Stage stage,
                  const QString &key);
    void onGetReply(QNetworkReply *reply, const QString &key);
    void onSearchReply(QNetworkReply *reply, const QString &key);
    void onNeteaseSearchReply(QNetworkReply *reply, const QString &key);
    void onNeteaseLyricReply(QNetworkReply *reply, const QString &key);

    // ---- cascada de YouTube Music -------------------------------------
    void startYtm();
    // Plan clásico (LRCLIB -> NetEase), cuando YouTube Music no tiene letra.
    void startLrclib();
    // Pide /next para el vídeo candidato nº `index` de m_ytmIds.
    void ytmNextFor(int index);
    // Pide /browse con el browseId de la letra encontrada en /next.
    void ytmBrowseFor(const QString &browseId);
    // Ningún vídeo sirve: se continúa con LRCLIB.
    void ytmGiveUp(const QString &why);
    void onYtmSearchReply(QNetworkReply *reply, const QString &key);
    void onYtmNextReply(QNetworkReply *reply, const QString &key);
    void onYtmBrowseReply(QNetworkReply *reply, const QString &key);

    void startSearch();
    void startNetease();
    // Cierra la búsqueda y emite `changed` con el resultado acumulado.
    void finish();
    void fail(const QString &message);
    // Sin letra sincronizada en ninguna fuente: se queda el plano si lo hay.
    void settleOrFail();

    // Vuelca un objeto JSON de LRCLIB (get o search) al estado. Un resultado
    // con "syncedLyrics" gana siempre; el plano solo se guarda si aún no hay.
    void applyPayload(const QJsonObject &obj);
    void rememberPlain(const QString &plain, const char *source);
    // Adopta un LRC como letra sincronizada. `filterCredits` elimina las líneas
    // de créditos (típicas en NetEase: 作词/作曲/...). Devuelve false si el LRC
    // no es utilizable (p. ej. solo créditos), dejando el estado intacto.
    bool adoptSynced(const QString &lrc, const QString &source,
                     bool filterCredits);
    // Puntúa los resultados de la búsqueda de NetEase y elige el mejor.
    int scoreNetease(const QJsonObject &song) const;

    static QVector<LrcLine> parseLrc(const QString &text, bool filterCredits);
    static bool looksLikeCredit(const QString &line);

    // ---- caché local de Sonora (letra con tiempos POR PALABRA) ------------
    // El reproductor de escritorio Sonora cachea en
    // ~/.cache/sonora/cache.sqlite las letras que ya bajó, indexadas por vídeo
    // de YouTube, con los tiempos por palabra de Apple Music/Musixmatch. Es la
    // MISMA fuente que usa el widget de escritorio, así que leerla da karaoke
    // palabra a palabra sin pedir nada a la red. Solo se usa si la pista tiene
    // vídeo y está en la caché; si no, sigue la cascada normal.
    bool trySonoraCache();
    // Adopta líneas ya construidas (con palabras) como letra sincronizada.
    bool adoptWorded(QVector<LrcLine> lines, const QString &source);

    QNetworkAccessManager *m_net = nullptr;
    QString m_trackKey;
    QString m_artist;
    QString m_title;
    int m_duration = 0;         // segundos redondeados
    // Número de fetch() en curso. Junto con m_trackKey descarta cualquier
    // respuesta de una petición antigua aunque la clave se repita (p. ej. dos
    // fetch() seguidos de la misma pista mientras cargaba la duración).
    int m_gen = 0;
    QStringList m_ytmIds;       // vídeos candidatos de YouTube Music
    int m_ytmIdx = 0;           // candidato en curso
    QString m_ytmBrowseId;      // browseId «MPLYt_*» de la letra actual
    // Cierto cuando ya hemos probado el vídeo exacto m_videoId y no tenía
    // letra: la búsqueda por título actúa entonces como respaldo (una vez).
    bool m_exactTried = false;
    bool m_loading = false;
    bool m_hasLyrics = false;
    bool m_hasSynced = false;
    QString m_plain;
    QString m_synced;
    QString m_error;
    QString m_syncSource;       // "ytmusic" | "lrclib" | "netease"
    QString m_plainSource;      // "ytmusic" | "lrclib"
    QVector<LrcLine> m_lines;   // LRC cacheado y ordenado
    // Vídeo exacto en reproducción (si la pista vino de YouTube): se intenta
    // primero, antes de re-buscar por título.
    QString m_videoId;
};
