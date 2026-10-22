#include "wash.h"

#include <QImage>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>

// ---------------------------------------------------------------------------
// Separable box over ARGB32. It is applied on a tiny canvas (<=128 px), so
// the cost is a few hundred thousand additions: nothing.
// ---------------------------------------------------------------------------
static QImage boxBlur(const QImage &in, int r)
{
    const int w = in.width(), h = in.height();
    const int win = 2 * r + 1;
    QImage tmp(w, h, QImage::Format_ARGB32);
    QImage out(w, h, QImage::Format_ARGB32);

    // Horizontal pass.
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

    // Vertical pass over the horizontal result.
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

    // 1) Halving down to ~240 px: a real average, not sampling. This is
    //    where the JPEG blocks of the original melt (at this size they
    //    are 2 px long and they fade away).
    QImage img = src;
    int w = img.width(), h = img.height();
    while (w > 240 || h > 240) {
        w = qMax(120, w / 2);
        h = qMax(120, h / 2);
        img = img.scaled(w, h, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    }

    // 2) Bilinear upscale to the working canvas (480 px): the detail lost
    //    in the halving comes back without bringing the blocks back.
    img = img.scaled(480, 480, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);

    // 3) Separable box over the big canvas: three passes of medium radius.
    //    The radius is deliberately WIDE: the veil is stretched over the
    //    whole window, and with a short blur the dark edges of the artwork
    //    itself showed up as a hard rectangle in the middle of the
    //    background (it read as "the background does not reach 100 %"). With
    //    the wide radius those edges melt and the background becomes a
    //    continuous gradient.
    img = boxBlur(img, 10);
    img = boxBlur(img, 10);
    img = boxBlur(img, 6);
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
    // "this" as context: if the app dies before answering, nothing is
    // fired. The copy destroys itself when it finishes.
    QObject::connect(reply, &QNetworkReply::finished, this,
                     [this, reply, url]() {
        reply->deleteLater();
        // The track changed while this one was downloading: its picture is
        // not wanted any more (it would paint the wrong artwork).
        if (url != m_wanted)
            return;
        if (reply->error() != QNetworkReply::NoError) {
            return;
        }
        const QByteArray body = reply->readAll();
        const QImage src = QImage::fromData(body);
        if (src.isNull()) {
            return;
        }
        const QImage blurred = blurPipeline(src);
        if (blurred.isNull())
            return;
        m_image = blurred;
        ++m_serial;
        emit changed();
    });
}

// ---------------------------------------------------------------------------
// Image provider for QML: image://wash/<serial>
// The key only breaks the Image's cache; the image is served already
// blurred.
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
    if (img.isNull()) {
        // Nothing computed yet: a solid colour is returned so the QML Image
        // does not fail (an empty image leaves it in error and the veil
        // never appears).
        if (size)
            *size = QSize(64, 64);
        QImage solid(64, 64, QImage::Format_ARGB32_Premultiplied);
        solid.fill(QColor(0x12, 0x15, 0x1a));
        return solid;
    }
    if (size)
        *size = img.size();
    return img;
}

// ---------------------------------------------------------------------------
// Colour picker
// ---------------------------------------------------------------------------
ColorPick::ColorPick(QObject *parent)
    : QObject(parent), m_net(new QNetworkAccessManager(this))
{
}

QColor ColorPick::dominant(const QImage &src0)
{
    QImage img = src0.convertToFormat(QImage::Format_ARGB32);
    if (img.isNull())
        return {};
    img = img.scaled(48, 48, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);

    // 5x5x5 histogram with the average of each cube. Every pixel is
    // weighted by its saturation: an artwork full of blacks and grey
    // haze must not come out "dull grey" but with its true colour.
    double cnt[5][5][5] = {};
    double sr[5][5][5] = {}, sg[5][5][5] = {}, sb[5][5][5] = {};
    double totW = 0.0, totR = 0.0, totG = 0.0, totB = 0.0;

    for (int y = 0; y < img.height(); ++y) {
        const QRgb *row = reinterpret_cast<const QRgb *>(img.constScanLine(y));
        for (int x = 0; x < img.width(); ++x) {
            const QRgb p = row[x];
            if (qAlpha(p) < 128)
                continue;
            const int r = qRed(p), g = qGreen(p), b = qBlue(p);
            const int mx = qMax(r, qMax(g, b)), mn = qMin(r, qMin(g, b));
            const int sat = mx - mn;                    // 0..255
            // The blacks do not score, not even for the global average.
            if (mx < 24)
                continue;
            const double w = 0.10 + sat / 255.0;
            const int ri = r / 51, gi = g / 51, bi = b / 51;   // 0..4 (255/51=5)
            const int ci = qMin(ri, 4), cj = qMin(gi, 4), ck = qMin(bi, 4);
            cnt[ci][cj][ck] += w;
            sr[ci][cj][ck] += r * w;
            sg[ci][cj][ck] += g * w;
            sb[ci][cj][ck] += b * w;
            totW += w; totR += r * w; totG += g * w; totB += b * w;
        }
    }

    double best = 0.0;
    int bx = -1, by = -1, bz = -1;
    for (int i = 0; i < 5; ++i)
        for (int j = 0; j < 5; ++j)
            for (int k = 0; k < 5; ++k) {
                // The cube is also weighted by its size relative to the
                // average of its neighbours: it avoids ties decided by
                // 1 px of noise.
                if (cnt[i][j][k] > best) {
                    best = cnt[i][j][k];
                    bx = i; by = j; bz = k;
                }
            }

    if (bx < 0 || totW <= 0.0)
        return {};
    QColor c;
    if (best <= 0.0)
        c = QColor::fromRgb(int(totR / totW), int(totG / totW), int(totB / totW));
    else
        c = QColor::fromRgb(qBound(0, int(sr[bx][by][bz] / best), 255),
                            qBound(0, int(sg[bx][by][bz] / best), 255),
                            qBound(0, int(sb[bx][by][bz] / best), 255));
    // A bit of life: the colour as it comes is almost always dull (the
    // artworks are dark photos) and it does not read as "the colour of
    // the artwork". The saturation goes up and the brightness is lifted
    // without going over the top.
    const QColor hsv = c.toHsv();
    const int s = qMin(255, int(hsv.saturation() * 1.35) + 20);
    const int v = qBound(60, hsv.value(), 235);
    return QColor::fromHsv(hsv.hue(), s, v);
}

void ColorPick::pick(const QUrl &url)
{
    const QString scheme = url.scheme();
    if (url.isEmpty() || (scheme != QStringLiteral("http") && scheme != QStringLiteral("https")))
        return;
    const QString key = url.toString();
    auto it = m_cache.constFind(key);
    if (it != m_cache.constEnd()) {
        emit found(url, it.value());
        return;
    }
    if (m_pending.contains(key))
        return;
    m_pending.insert(key);

    // To get the dominant colour the big image is not needed: YouTube's
    // thumbnails are asked for in their 320 px variant (the 16:9 one
    // with black bars, which the histogram drops for being black).
    static const QRegularExpression re(
        QStringLiteral("^https?://i\\.ytimg\\.com/vi/([\\w-]{11,13})/"));
    const QRegularExpressionMatch m = re.match(key);
    QUrl small = url;
    if (m.hasMatch())
        small = QUrl(QStringLiteral("https://i.ytimg.com/vi/%1/mqdefault.jpg")
                         .arg(m.captured(1)));

    fetch(url, small, key);
}

void ColorPick::fetch(const QUrl &orig, const QUrl &download, const QString &key)
{
    QNetworkRequest req(download);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    QNetworkReply *reply = m_net->get(req);
    QObject::connect(reply, &QNetworkReply::finished, this,
                     [this, reply, orig, download, key]() {
        reply->deleteLater();
        m_pending.remove(key);
        if (reply->error() != QNetworkReply::NoError) {
            // If the small variant does not exist, the original is tried.
            if (download != orig) {
                m_pending.insert(key);
                fetch(orig, orig, key);
            }
            return;
        }
        const QImage src = QImage::fromData(reply->readAll());
        if (src.isNull())
            return;
        const QColor c = dominant(src);
        if (!c.isValid())
            return;
        m_cache.insert(key, c);
        emit found(orig, c);
    });
}
