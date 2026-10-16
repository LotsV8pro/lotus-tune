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

// Descargas a disco + biblioteca local, expuesta a QML como `downloads`.
//
// Es la capa "Sonora": lanza `yt-dlp` para bajar playlists o pistas sueltas
// como audio, un proceso a la vez (para no saturar red/RAM), y luego publica
// los archivos encontrados en la carpeta raíz como una biblioteca local.
//
// Job map:   { name, progress (0..100), state: "queued|downloading|done|error",
//              error }
// Track map: { title, artist, duration, url (file://...), thumb,
//              source: "local" }
class Downloads : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QVariantList jobs READ jobs NOTIFY jobsChanged)
    Q_PROPERTY(QString folder READ folder NOTIFY changed)
    Q_PROPERTY(QVariantList local READ local NOTIFY libraryChanged)
    // Listas descargadas: una entrada por carpeta de primer nivel
    // ({ name, folder, count, thumb, url }).
    Q_PROPERTY(QVariantList folders READ folders NOTIFY libraryChanged)
    Q_PROPERTY(bool localBusy READ localBusy NOTIFY libraryChanged)

public:
    explicit Downloads(QObject *parent = nullptr);
    ~Downloads() override;

    bool busy() const { return m_busy; }
    QVariantList jobs() const;
    QString folder() const { return m_folder; }
    QVariantList local() const { return m_local; }
    QVariantList folders() const;
    bool localBusy() const { return m_localBusy; }

    // Carpeta raíz de descargas (configurable y persistida en QSettings).
    Q_INVOKABLE void setFolder(const QString &dir);
    // ~/.local/share/lotus-tune/descargas
    Q_INVOKABLE QString defaultFolder() const;

    Q_INVOKABLE void downloadPlaylist(const QString &url, const QString &name);
    Q_INVOKABLE void downloadTrack(const QString &url, const QString &title,
                                   const QString &artist);
    Q_INVOKABLE void cancelAll();
    // Escanea recursivamente la carpeta buscando audio (no bloqueante).
    Q_INVOKABLE void refreshLocal();
    // xdg-open sobre la carpeta raíz.
    Q_INVOKABLE void openFolder();
    // Desinstala una lista descargada: borra su carpeta de primer nivel
    // (recursivo y con guardas de seguridad) y reescanea la biblioteca.
    Q_INVOKABLE void removeList(const QString &folder);
    // Nombre de carpeta que se usaría para una lista con ese nombre
    // (misma sanitización que al descargar); para emparejar listas antiguas
    // que no tienen fichero de metadatos.
    Q_INVOKABLE QString listFolderName(const QString &name) const;

signals:
    void changed();
    void jobsChanged();
    void libraryChanged();

private:
    struct Job {
        QString name;
        QString url;
        bool playlist = false;
        int progress = 0;
        QString state = QStringLiteral("queued");
        QString error;
    };

    void enqueue(const Job &job);
    void startNext();
    void readStdout();
    void finishJob(int code);
    void setJob(int index, const QString &state, const QString &error = QString());

    void startScan();
    void scanChunk();
    void stopScan();
    // Sincroniza los directorios vigilados con la carpeta raíz + subcarpetas
    // descubiertas en el último escaneo (auto-sync al cambiar ficheros).
    void updateWatchDirs();
    QVariantMap makeLocalTrack(const QString &path) const;
    QString artistForPath(const QString &dir) const;

    // Convierte un texto arbitrario en un segmento de ruta seguro
    // (sin separadores ni caracteres prohibidos).
    static QString safeSegment(const QString &text);

    QProcess m_proc;
    QVector<Job> m_jobs;
    int m_current = -1;      // índice del job en curso, -1 si ninguno
    bool m_busy = false;
    bool m_cancelling = false;
    QString m_lastError;     // último "ERROR:" visto en la salida
    QByteArray m_buf;
    // Progreso global de una lista: yt-dlp emite "Downloading item X of Y" y
    // luego el % de cada pista. Se combinan para mostrar UN 0-100 % del total
    // en vez de reiniciar a 0 en cada canción.
    int m_plItem = 0;
    int m_plTotal = 0;

    QString m_folder;
    QVariantList m_local;
    bool m_localBusy = false;
    QDirIterator *m_scan = nullptr;
    QVariantList m_scanItems;
    QTimer m_scanTimer;
    QSet<QString> m_scanDirs;      // carpetas vistas en el escaneo en curso

    // Auto-sync: vigila la carpeta de descargas (y subcarpetas) y reescanea
    // con un pequeño debounce cuando algo cambia en disco.
    QFileSystemWatcher m_watcher;
    QTimer m_watchDebounce;
};