#include "wash.h"

#include <QImage>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>

// ---------------------------------------------------------------------------
// Caja separable sobre ARGB32. Se aplica sobre un lienzo diminuto (≤128 px),
// así que el coste es de unos pocos cientos de miles de sumas: nada.
// ---------------------------------------------------------------------------
static QImage boxBlur(const QImage &in, int r)
{
    const int w = in.width(), h = in.height();
    const int win = 2 * r + 1;
    QImage tmp(w, h, QImage::Format_ARGB32);
    QImage out(w, h, QImage::Format_ARGB32);

    // Barrido horizontal.
    for (int y = 0; y < h; ++y) {
        const QRgb *row = reinterpret_cast<const QRgb *>(in.constScanLine(y));
        QRgb *dst = reinterpret_cast<QRgb *>(tmp.scanLine(y));
        long sa = 0, sr = 0, sg = 0, sb = 0;
        for (int k = -r; k <= r; ++k) {
            const QRgb p = row[qBound(0, w - 1, k)];
            sa += qAlpha(p); sr += qRed(p); sg += qGreen(p); sb += qBlue(p);
        }
        for (int x = 0; x < w; ++x) {
            dst[x] = qRgba(int(sr / win), int(sg / win), int(sb / win), int(sa / win));
            const QRgb pa = row[qBound(0, w - 1, x + r + 1)];
            const QRgb pb = row[qBound(0, w - 1, x - r)];
            sa += qAlpha(pa) - qAlpha(pb);
            sr += qRed(pa) - qRed(pb);
            sg += qGreen(pa) - qGreen(pb);
            sb += qBlue(pa) - qBlue(pb);
        }
    }

    // Barrido vertical sobre el resultado horizontal.
    for (int x = 0; x < w; ++x) {
        long sa = 0, sr = 0, sg = 0, sb = 0;
        for (int k = -r; k <= r; ++k) {
            const QRgb p = reinterpret_cast<const QRgb *>(tmp.constScanLine(qBound(0, h - 1, k)))[x];
            sa += qAlpha(p); sr += qRed(p); sg += qGreen(p); sb += qBlue(p);
        }
        for (int y = 0; y < h; ++y) {
            reinterpret_cast<QRgb *>(out.scanLine(y))[x] =
                qRgba(int(sr / win), int(sg / win), int(sb / win), int(sa / win));
            const QRgb pa = reinterpret_cast<const QRgb *>(tmp.constScanLine(qBound(0, h - 1, y + r + 1)))[x];
            const QRgb pb = reinterpret_cast<const QRgb *>(tmp.constScanLine(qBound(0, h - 1, y - r)))[x];
            sa += qAlpha(pa) - qAlpha(pb);
            sr += qRed(pa) - qRed(pb);
            sg += qGreen(pa) - qGreen(pb);
            sb += qBlue(pa) - qBlue(pb);
        }
    }
    return out;
}

QImage Wash::blurPipeline(const QImage &src0)
{
    QImage src = src0.convertToFormat(QImage::Format_ARGB32);
    if (src.isNull())
        return {};

    // 1) Bajada por mitades hasta ~240 px: promedio de verdad, no muestreo.
    //    Aquí es donde los bloques JPEG del original se funden (a este
    //    tamaño ya miden 2 px y se diluyen).
    QImage img = src;
    int w = img.width(), h = img.height();
    while (w > 240 || h > 240) {
        w = qMax(120, w / 2);
        h = qMax(120, h / 2);
        img = img.scaled(w, h, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    }

    // 2) Subida bilineal al lienzo de trabajo (480 px): se recupera el
    //    detalle perdido en la bajada sin re-introducir bloques.
    img = img.scaled(480, 480, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);

    // 3) Caja separable sobre el lienzo grande: dos pasadas de radio medio.
    //    Corto para que la portada se RECONOZCA, lo justo para fundir también
    //    los bordes duros del propio arte (collages, esquinas) que con radios
    //    menores salían como costuras rectangulares.
    img = boxBlur(img, 5);
    img = boxBlur(img, 5);
    return img;
}

Wash::Wash(QObject *parent)
    : QObject(parent), m_net(new QNetworkAccessManager(this))
{
}

void Wash::setSource(const QUrl &url)
{
    if (url.isEmpty() || url == m_wanted)
        return;
    m_wanted = url;

    QNetworkRequest req(url);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    QNetworkReply *reply = m_net->get(req);
    // «this» como contexto: si la app muere antes de responder, nada se
    // dispara. La réplica se auto-destruye al terminar.
    QObject::connect(reply, &QNetworkReply::finished, this,
                     [this, reply, url]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            qInfo().noquote() << "[wash] miniatura no descargable:" << url.toString();
            return;
        }
        const QByteArray body = reply->readAll();
        const QImage src = QImage::fromData(body);
        if (src.isNull())
            return;
        const QImage blurred = blurPipeline(src);
        if (blurred.isNull())
            return;
        m_image = blurred;
        ++m_serial;
        emit changed();
    });
}

// ---------------------------------------------------------------------------
// Proveedor de imágenes para QML: image://wash/<serial>
// La clave sólo rompe la caché del Image; la imagen se sirve ya desenfocada.
// ---------------------------------------------------------------------------
WashProvider::WashProvider(Wash *wash)
    : QQuickImageProvider(QQuickImageProvider::Image), m_wash(wash)
{
}

QImage WashProvider::requestImage(const QString &id, QSize *size,
                                  const QSize &requestedSize)
{
    Q_UNUSED(id);
    Q_UNUSED(requestedSize);
    const QImage img = m_wash->blurred();
    if (size)
        *size = img.size();
    return img;
}
