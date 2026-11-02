#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

// Control del peso que deja la app en el disco.
//
// En Android cada pista que suena se descarga a
// cache/audio_<videoId>.bin (4-8 MB). Sin tope, una biblioteca de 200
// pistas deja ~1 GB y Android acaba borrando el cache por su cuenta (y
// entonces "desaparecen" pistas que ayer sonaban). Esto mantiene un
// limite configurable y borra primero lo que hace mas tiempo que no se
// usa (LRU por fecha de modificacion).
//
// En escritorio el audio no se cachea (mpv hace streaming), asi que el
// barrido de audio_*.bin es un no-op; sirve igual para limpiar restos.
class AudioCache : public QObject
{
    Q_OBJECT
    // Tamano actual del cache de audio, en bytes / en ficheros.
    Q_PROPERTY(qint64 bytes READ bytes NOTIFY changed)
    Q_PROPERTY(int files READ files NOTIFY changed)
    // Tope en MB (0 = sin limite). Se guarda en la configuracion.
    Q_PROPERTY(int limitMB READ limitMB WRITE setLimitMB NOTIFY changed)
    // "320 MB de 1 GB" para la pantalla de ajustes.
    Q_PROPERTY(QString summary READ summary NOTIFY changed)

public:
    explicit AudioCache(QObject *parent = nullptr);

    static AudioCache *instance();

    qint64 bytes() const;
    int files() const;
    int limitMB() const;
    void setLimitMB(int mb);
    QString summary() const;

    // Borra las pistas mas antiguas hasta bajar del limite (con margen:
    // deja el cache al 90% del tope, para no estar borrando en cada
    // descarga). `protect` es el videoId que se esta reproduciendo ahora:
    // ese fichero no se toca nunca.
    Q_INVOKABLE int prune(const QString &protect = QString());
    // Borra todo el cache de audio.
    Q_INVOKABLE int clear();
    // Restos de descargas interrumpidas (.part) de mas de una hora.
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
