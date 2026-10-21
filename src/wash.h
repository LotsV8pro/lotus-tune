#pragma once

#include <QColor>
#include <QHash>
#include <QImage>
#include <QObject>
#include <QQuickImageProvider>
#include <QSet>
#include <QUrl>

class QNetworkAccessManager;

// Background wash ("wash"): it downloads the track's thumbnail and applies a
// REAL blur in the CPU - halving (averaging: it melts the JPEG blocks),
// a separable box and a final bilinear upscale. The result is served by an
// image provider ("image://wash/<serial>") so the app background and the
// cinema mode look like a soft veil, without blocks or pixelation and
// without shaders (the app runs on the software backend).
class Wash : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int serial READ serial NOTIFY changed)
    Q_PROPERTY(bool valid READ valid NOTIFY changed)

public:
    explicit Wash(QObject *parent = nullptr);

    int serial() const { return m_serial; }
    bool valid() const { return !m_image.isNull(); }

    // Changes the source image (the track's thumbnail). Empty = no change
    // of the stored image; the QML decides to hide the wash.
    Q_INVOKABLE void setSource(const QUrl &url);

    // The current blurred image (the provider asks for it).
    QImage blurred() const { return m_image; }

signals:
    void changed();

private:
    // Blur pipeline: halving + separable box ×2 + bilinear upscale.
    static QImage blurPipeline(const QImage &src);

    QNetworkAccessManager *m_net;
    QImage m_image;
    QUrl m_wanted;
    int m_serial = 0;
};

// Synchronous provider: returns the blur already computed. The key is the
// track serial, which breaks the Image's cache in QML when it changes.
class WashProvider : public QQuickImageProvider
{
public:
    explicit WashProvider(Wash *wash);

    QImage requestImage(const QString &id, QSize *size,
                        const QSize &requestedSize) override;

private:
    Wash *m_wash;
};

// Colour picker ("colorpick"): it downloads a thumbnail and extracts its
// DOMINANT colour cheaply - the image is downloaded at 48 px and counted
// in a 5x5x5 RGB histogram, weighting every pixel by its saturation
// (the vivid colours win; the greys and the near blacks barely score).
// The most populated cube gives the card's colour. Cached by URL: every
// artwork is downloaded once even if the cards are recycled on scroll.
class ColorPick : public QObject
{
    Q_OBJECT
public:
    explicit ColorPick(QObject *parent = nullptr);

    // Starts the extraction; when it finishes it emits found(url, color).
    // If it is already cached the emit is immediate (same loop, no network).
    Q_INVOKABLE void pick(const QUrl &url);

signals:
    void found(const QUrl &url, const QColor &color);

private:
    static QColor dominant(const QImage &img);
    // Downloads (the small variant if there is one) and extracts the colour.
    void fetch(const QUrl &orig, const QUrl &download, const QString &key);

    QNetworkAccessManager *m_net;
    QHash<QString, QColor> m_cache;
    QSet<QString> m_pending;
};
