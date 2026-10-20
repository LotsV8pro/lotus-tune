#pragma once

#include <QImage>
#include <QObject>
#include <QQuickImageProvider>
#include <QUrl>

class QNetworkAccessManager;

// Lavado de fondo («wash»): descarga la miniatura de la pista y le aplica un
// desenfoque REAL en la CPU — bajado por mitades (promedio: borra los bloques
// JPEG), caja separable, y subida final bilineal. El resultado se sirve por
// un proveedor de imágenes ("image://wash/<serial>") para que el fondo de la
// app y el modo cine se vean como una vela suave, sin bloques ni pixelado,
// sin usar shaders (la app corre con backend de software).
class Wash : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int serial READ serial NOTIFY changed)
    Q_PROPERTY(bool valid READ valid NOTIFY changed)

public:
    explicit Wash(QObject *parent = nullptr);

    int serial() const { return m_serial; }
    bool valid() const { return !m_image.isNull(); }

    // Cambia la imagen fuente (la miniatura de la pista). Vacío = sin cambio
    // de imagen guardada; el QML decide ocultar el lavado.
    Q_INVOKABLE void setSource(const QUrl &url);

    // La imagen desenfocada actual (la pide el proveedor).
    QImage blurred() const { return m_image; }

signals:
    void changed();

private:
    // Pipeline de desenfoque: mitades + caja separable ×2 + subida bilineal.
    static QImage blurPipeline(const QImage &src);

    QNetworkAccessManager *m_net;
    QImage m_image;
    QUrl m_wanted;
    int m_serial = 0;
};

// Proveedor síncrono: devuelve el desenfoque ya calculado. La clave es el
// número de pista (serial), que rompe la caché del Image en QML al cambiar.
class WashProvider : public QQuickImageProvider
{
public:
    explicit WashProvider(Wash *wash);

    QImage requestImage(const QString &id, QSize *size,
                        const QSize &requestedSize) override;

private:
    Wash *m_wash;
};
