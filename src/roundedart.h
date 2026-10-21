#pragma once

#include <QHash>
#include <QImage>
#include <QMutex>
#include <QObject>
#include <QQuickImageProvider>
#include <QStringList>
#include <QUrl>

class QNetworkAccessManager;

// Portadas redondeadas («rart»): el recorte y las esquinas se hacen aquí,
// en la CPU, y el resultado se sirve por un proveedor de imágenes
// ("image://rart/<clave>") como un PNG con el alfa recortado.
//
// ¿Por qué en C++ y no en QML? Porque el `clip` de un Rectangle ignora el
// `radius` (las esquinas salían cuadradas) y el recorte con Canvas
// depende de la caché de imágenes por URL: si otra parte de la app pide
// la misma foto en otro tamaño, el lienzo recorta sobre un pixmap que no
// es el suyo y la portada sale descentrada o directamente vacía. Aquí no
// hay sorpresas: se descarga una vez, se recorta al centro al tamaño
// exacto que se pide y se le aplica la máscara redondeada.
class RoundedArt : public QObject
{
    Q_OBJECT

public:
    explicit RoundedArt(QObject *parent = nullptr);

    // URL de la portada ya procesada. Si todavía no está, devuelve la
    // misma URL con la versión 0 (el proveedor no tiene nada que dar) y
    // lanza el trabajo en segundo plano; cuando termina se emite
    // ready(clave) y el QML vuelve a pedir la URL (ya con versión nueva).
    //
    //   candidates : urls candidatas (se prueban en orden)
    //   boxW/boxH : el hueco en píxeles lógicos
    //   radius    : radio de las esquinas en píxeles lógicos
    //   scale     : el factor de pantalla (dpr)
    Q_INVOKABLE QString url(const QStringList &candidates, int boxW, int boxH,
                            int radius, qreal scale);
    Q_INVOKABLE QString url(const QString &src, int boxW, int boxH,
                            int radius, qreal scale);

    // La clave de una combinación (para que el QML compare con la señal).
    Q_INVOKABLE QString key(const QStringList &candidates, int boxW, int boxH,
                            int radius, qreal scale) const;

    // La imagen ya procesada (la pide el proveedor).
    QImage image(const QString &key) const;

signals:
    void ready(const QString &key);

private:
    struct Job
    {
        QStringList candidates;
        int boxW = 0;
        int boxH = 0;
        int radius = 0;
        qreal scale = 1.0;
        int version = 0;
        bool started = false;
        bool done = false;
        QImage image;
    };

    void start(const QString &key);
    void tryNext(const QString &key, int index);
    // Recorta al centro al tamaño pedido y le aplica la máscara.
    static QImage process(const QImage &src, int boxW, int boxH, int radius,
                           qreal scale);

    QNetworkAccessManager *m_net;
    mutable QMutex m_mutex;
    QHash<QString, Job> m_jobs;
    // Las fotos ya bajadas, por URL: así la misma portada no se descarga
    // otra vez cuando se pide en un tamaño distinto.
    QHash<QString, QImage> m_originals;
    QStringList m_originalOrder;
};

// Proveedor síncrono: devuelve la imagen ya recortada y redondeada. La
// clave de la URL lleva la versión, para que al repedirla se repinte.
class RoundedArtProvider : public QQuickImageProvider
{
public:
    explicit RoundedArtProvider(RoundedArt *art);

    QImage requestImage(const QString &id, QSize *size,
                        const QSize &requestedSize) override;

private:
    RoundedArt *m_art;
};
