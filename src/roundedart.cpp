#include "roundedart.h"

#include <QCryptographicHash>
#include <QImage>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPainter>
#include <QPainterPath>
#include <QTimer>
#include <QUrl>

namespace {

// The key identifies the combination (candidates + slot + radius + dpr).
// It travels in the provider's URL, so it is summarised with a hash.
QString makeKey(const QStringList &candidates, int boxW, int boxH, int radius,
                qreal scale)
{
    QCryptographicHash h(QCryptographicHash::Sha1);
    for (const QString &c : candidates)
        h.addData(c.toUtf8());
    h.addData(QByteArray::number(boxW));
    h.addData(QByteArray::number(boxH));
    h.addData(QByteArray::number(radius));
    h.addData(QByteArray::number(qRound(scale * 100)));
    return h.result().toHex().left(16);
}

// Only the candidates that can be downloaded (http/https).
QStringList usable(const QStringList &candidates)
{
    QStringList real;
    for (const QString &c : candidates) {
        const QUrl u(c);
        if (u.isEmpty())
            continue;
        const QString scheme = u.scheme();
        if (scheme != QStringLiteral("http") && scheme != QStringLiteral("https"))
            continue;
        real << c;
    }
    return real;
}

} // namespace

RoundedArt::RoundedArt(QObject *parent)
    : QObject(parent), m_net(new QNetworkAccessManager(this))
{
}

QString RoundedArt::url(const QString &src, int boxW, int boxH, int radius,
                         qreal scale)
{
    return url(QStringList{src}, boxW, boxH, radius, scale);
}

QString RoundedArt::url(const QStringList &candidates, int boxW, int boxH,
                         int radius, qreal scale)
{
    const QStringList real = usable(candidates);
    if (real.isEmpty() || boxW <= 0 || boxH <= 0)
        return QString();

    const QString key = makeKey(real, boxW, boxH, radius, scale);
    int version = 0;
    bool needStart = false;
    {
        QMutexLocker lock(&m_mutex);
        auto it = m_jobs.find(key);
        if (it == m_jobs.end()) {
            Job job;
            job.candidates = real;
            job.boxW = boxW;
            job.boxH = boxH;
            job.radius = radius;
            job.scale = scale > 0 ? scale : 1.0;
            m_jobs.insert(key, job);
            // Every size (and every radius) is a different job with its own
            // image: without a limit the map grows with every resize of
            // the window.
            while (m_jobs.size() > 64) {
                auto oldest = m_jobs.begin();
                for (auto it = m_jobs.begin(); it != m_jobs.end(); ++it) {
                    if (it->done && !oldest->done)
                        oldest = it;
                }
                m_jobs.erase(oldest);
            }
            needStart = true;
        } else {
            version = it->version;
            if (!it->started && !it->done) {
                it->started = true;
                needStart = true;
            } else if (it->failed && !it->done && it->attempts < 3) {
                // Every candidate failed last time: try again.
                it->failed = false;
                it->started = true;
                it->attempts++;
                needStart = true;
            }
        }
    }
    if (needStart)
        start(key);

    // While the photo is not processed NO url is returned: the QML leaves
    // the slot empty (without asking for an image that does not exist yet)
    // and paints it when the "ready" signal arrives.
    {
        QMutexLocker lock(&m_mutex);
        auto it = m_jobs.constFind(key);
        if (it == m_jobs.constEnd() || !it->done)
            return QString();
        version = it->version;
    }
    return QStringLiteral("image://rart/%1?v=%2").arg(key).arg(version);
}

QString RoundedArt::key(const QStringList &candidates, int boxW, int boxH,
                         int radius, qreal scale) const
{
    const QStringList real = usable(candidates);
    if (real.isEmpty() || boxW <= 0 || boxH <= 0)
        return QString();
    return makeKey(real, boxW, boxH, radius, scale);
}

QImage RoundedArt::image(const QString &key) const
{
    QMutexLocker lock(&m_mutex);
    auto it = m_jobs.constFind(key);
    if (it == m_jobs.constEnd())
        return QImage();
    return it->image;
}

void RoundedArt::start(const QString &key)
{
    bool done = false;
    {
        QMutexLocker lock(&m_mutex);
        auto it = m_jobs.find(key);
        if (it == m_jobs.end())
            return;
        for (const QString &c : it->candidates) {
            auto orig = m_originals.constFind(c);
            if (orig == m_originals.constEnd())
                continue;
            const QImage img = process(*orig, it->boxW, it->boxH, it->radius,
                                       it->scale);
            it->image = img;
            it->done = true;
            it->version++;
            done = true;
            break;
        }
    }
    if (done)
    if (done)
        emit ready(key);
    tryNext(key, 0);
}

void RoundedArt::tryNext(const QString &key, int index)
{
    QStringList candidates;
    int boxW = 0, boxH = 0, radius = 0;
    qreal scale = 1.0;
    QImage fallback;
    {
        QMutexLocker lock(&m_mutex);
        auto it = m_jobs.find(key);
        if (it == m_jobs.end())
            return;
        if (it->done)
            return;
        candidates = it->candidates;
        boxW = it->boxW;
        boxH = it->boxH;
        radius = it->radius;
        scale = it->scale;
        fallback = it->fallback;
    }
    if (index >= candidates.size()) {
        // Every candidate failed. If a small picture was downloaded it is
        // used now — never a black-and-white placeholder though (for
        // those the slot keeps its gradient). The job is marked as
        // failed so the next request tries it again.
        if (fallback.isNull() || fallback.allGray()) {
            {
                QMutexLocker lock(&m_mutex);
                auto it = m_jobs.find(key);
                if (it != m_jobs.end())
                    it->failed = true;
            }
            // The QML asks for the url again: the job starts over.
            emit ready(key);
            return;
        }
        const QImage img = process(fallback, boxW, boxH, radius, scale);
        {
            QMutexLocker lock(&m_mutex);
            auto it = m_jobs.find(key);
            if (it == m_jobs.end())
                return;
            it->image = img;
            it->done = true;
            it->version++;
        }
        emit ready(key);
        return;
    }

    const QString url = candidates.at(index);
    QNetworkRequest req{QUrl(url)};
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    QNetworkReply *reply = m_net->get(req);
    // Safety net: if this candidate does not answer in 4 s (a URL that
    // hangs, a CDN that does not respond) it is aborted and the next one is
    // tried. Without this the cover stays empty forever.
    QTimer::singleShot(4000, reply, [this, reply, key, index]() {
        if (reply->isRunning()) {
            reply->abort();
        }
    });
    QObject::connect(reply, &QNetworkReply::finished, this,
                     [this, reply, key, index, url, boxW, boxH, radius, scale]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            tryNext(key, index + 1);
            return;
        }
        QImage src = QImage::fromData(reply->readAll());
        if (src.isNull()) {
            tryNext(key, index + 1);
            return;
        }
        // The YouTube cascade sometimes answers with a 120x90 grey frame
        // or a black-and-white placeholder instead of the real cover:
        // they are kept as a fallback (better than an empty slot) and the
        // next candidate is tried first.
        if (src.allGray() || src.width() < 100 || src.height() < 100) {
            {
                QMutexLocker lock(&m_mutex);
                auto it = m_jobs.find(key);
                if (it == m_jobs.end())
                    return;
                it->fallback = src;
            }
            tryNext(key, index + 1);
            return;
        }

        {
            QMutexLocker lock(&m_mutex);
            // The original photo is saved so it is not downloaded again if
            // another part of the app asks for it at another size.
            m_originals.insert(url, src);
            m_originalOrder.removeAll(url);
            m_originalOrder << url;
            while (m_originalOrder.size() > 24) {
                m_originals.remove(m_originalOrder.takeFirst());
            }
        }

        const QImage img = process(src, boxW, boxH, radius, scale);
        {
            QMutexLocker lock(&m_mutex);
            auto it = m_jobs.find(key);
            if (it == m_jobs.end())
                return;
            it->image = img;
            it->done = true;
            it->version++;
        }
        emit ready(key);
    });
}

QImage RoundedArt::process(const QImage &src, int boxW, int boxH, int radius,
                           qreal scale)
{
    if (src.isNull() || boxW <= 0 || boxH <= 0)
        return QImage();

    const qreal s = scale > 0 ? scale : 1.0;
    const int w = qMax(1, qRound(boxW * s));
    const int h = qMax(1, qRound(boxH * s));
    const int r = qBound(0, qRound(radius * s), qMin(w, h) / 2);

    // Centre crop (KeepAspectRatioByExpanding + centre crop =
    // PreserveAspectCrop) and the corner mask.
    QImage scaled = src.scaled(w, h, Qt::KeepAspectRatioByExpanding,
                               Qt::SmoothTransformation);
    const int x = (scaled.width() - w) / 2;
    const int y = (scaled.height() - h) / 2;
    scaled = scaled.copy(x, y, w, h);

    QImage out(w, h, QImage::Format_ARGB32_Premultiplied);
    out.fill(Qt::transparent);
    {
        QPainter p(&out);
        p.setRenderHint(QPainter::Antialiasing, true);
        if (r > 0) {
            QPainterPath path;
            path.addRoundedRect(QRectF(0, 0, w, h), r, r);
            p.setClipPath(path);
        }
        p.drawImage(0, 0, scaled);
    }
    return out;
}

RoundedArtProvider::RoundedArtProvider(RoundedArt *art)
    : QQuickImageProvider(QQuickImageProvider::Image), m_art(art)
{
}

QImage RoundedArtProvider::requestImage(const QString &id, QSize *size,
                                         const QSize &requestedSize)
{
    Q_UNUSED(requestedSize);
    // The key goes before the «?v=…».
    const QString key = id.section(QLatin1Char('?'), 0, 0);
    const QImage img = m_art->image(key);
    if (size)
        *size = img.size();
    return img;
}
