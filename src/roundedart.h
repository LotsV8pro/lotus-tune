#pragma once

#include <QHash>
#include <QImage>
#include <QMutex>
#include <QObject>
#include <QQuickImageProvider>
#include <QStringList>
#include <QUrl>

class QNetworkAccessManager;

// Rounded artwork ("rart"): the crop and the corners are done here, in
// the CPU, and the result is served by an image provider
// ("image://rart/<key>") as a PNG with the alpha already cut.
//
// Why in C++ and not in QML? Because a Rectangle's `clip` ignores its
// `radius` (the corners came out square) and cropping with a Canvas
// depends on the image cache keyed by URL: when another part of the app
// asks for the same photo at another size, the canvas crops over a pixmap
// that is not its own and the artwork comes out off-centre or empty.
// Here there are no surprises: it is downloaded once, cropped to the
// centre at the exact size that is asked for and given the rounded mask.
class RoundedArt : public QObject
{
    Q_OBJECT

public:
    explicit RoundedArt(QObject *parent = nullptr);

    // URL of the already processed artwork. If it is not ready yet it
    // returns the same URL with version 0 (the provider has nothing to
    // give) and starts the work in the background; when it finishes
    // ready(key) is emitted and the QML asks for the URL again (now with
    // the new version).
    //
    //   candidates : candidate urls (tried in order)
    //   boxW/boxH : the slot in logical pixels
    //   radius    : corner radius in logical pixels
    //   scale     : the screen factor (dpr)
    Q_INVOKABLE QString url(const QStringList &candidates, int boxW, int boxH,
                            int radius, qreal scale);
    Q_INVOKABLE QString url(const QString &src, int boxW, int boxH,
                            int radius, qreal scale);

    // The key of a combination (so the QML can compare it with the signal).
    Q_INVOKABLE QString key(const QStringList &candidates, int boxW, int boxH,
                            int radius, qreal scale) const;

    // The already processed image (the provider asks for it).
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
    // Crops to the centre at the requested size and applies the mask.
    static QImage process(const QImage &src, int boxW, int boxH, int radius,
                           qreal scale);

    QNetworkAccessManager *m_net;
    mutable QMutex m_mutex;
    QHash<QString, Job> m_jobs;
    // The already downloaded photos, by URL: that way the same artwork is
    // not downloaded again when it is asked at a different size.
    QHash<QString, QImage> m_originals;
    QStringList m_originalOrder;
};

// Synchronous provider: returns the image already cropped and rounded. The
// URL key carries the version, so asking for it again repaints it.
class RoundedArtProvider : public QQuickImageProvider
{
public:
    explicit RoundedArtProvider(RoundedArt *art);

    QImage requestImage(const QString &id, QSize *size,
                        const QSize &requestedSize) override;

private:
    RoundedArt *m_art;
};
