#pragma once

#include <QColor>
#include <QFileSystemWatcher>
#include <QObject>
#include <QStringList>
#include <QVariantMap>

class QTimer;

// Live theme that mirrors the desktop palette.
//
// Colour source order:
//   1. ~/.config/spotify-qml/config.ini   (explicit overrides, wins)
//   2. ~/.local/state/quickshell/user/generated/app-palette.json   (iNiR/matugen)
//   3. .../generated/colors.json           (Material tokens fallback)
//   4. built-in Spotify-ish defaults
//
// Both files are watched: changing the theme from the shell's settings panel
// (Super) regenerates the palette and the app recolours instantly.
class AppTheme : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QColor bg READ bg NOTIFY paletteChanged)
    Q_PROPERTY(QColor surface READ surface NOTIFY paletteChanged)
    Q_PROPERTY(QColor surfaceAlt READ surfaceAlt NOTIFY paletteChanged)
    Q_PROPERTY(QColor border READ border NOTIFY paletteChanged)
    Q_PROPERTY(QColor borderSubtle READ borderSubtle NOTIFY paletteChanged)
    Q_PROPERTY(QColor accent READ accent NOTIFY paletteChanged)
    Q_PROPERTY(QColor onAccent READ onAccent NOTIFY paletteChanged)
    Q_PROPERTY(QColor accentDim READ accentDim NOTIFY paletteChanged)
    Q_PROPERTY(QColor text READ text NOTIFY paletteChanged)
    Q_PROPERTY(QColor textDim READ textDim NOTIFY paletteChanged)
    Q_PROPERTY(QColor danger READ danger NOTIFY paletteChanged)
    Q_PROPERTY(bool followingSystem READ followingSystem NOTIFY paletteChanged)
    Q_PROPERTY(QString source READ source NOTIFY paletteChanged)
    // "Fondo dinámico" (estilo Liner): la portada de la pista actual tiñe el
    // escritorio y las islas se vuelven translúcidas. Lo decide la UI (se
    // recuerda en appcfg); aquí sólo vive para que todos los QML reaccionen.
    Q_PROPERTY(bool dynamicBg READ dynamicBg WRITE setDynamicBg NOTIFY washChanged)

public:
    explicit AppTheme(QObject *parent = nullptr);

    QColor bg() const { return m_bg; }
    QColor surface() const { return m_surface; }
    QColor surfaceAlt() const { return m_surfaceAlt; }
    QColor border() const { return m_border; }
    QColor borderSubtle() const { return m_borderSubtle; }
    QColor accent() const { return m_accent; }
    QColor onAccent() const { return m_onAccent; }
    QColor accentDim() const { return m_accentDim; }
    QColor text() const { return m_text; }
    QColor textDim() const { return m_textDim; }
    QColor danger() const { return m_danger; }
    bool followingSystem() const { return m_followSystem; }
    QString source() const { return m_source; }
    bool dynamicBg() const { return m_dynamicBg; }
    void setDynamicBg(bool on) {
        if (m_dynamicBg == on)
            return;
        m_dynamicBg = on;
        emit washChanged();
    }

signals:
    void paletteChanged();
    void washChanged();

private:
    void reload();
    void scheduleReload();
    void rearmWatch(const QString &path = QString());
    void loadSystemPalette();
    void loadOverrides();
    static QString pick(const QVariantMap &map,
                        const QStringList &keys,
                        const QString &fallback);

    QFileSystemWatcher m_watcher;
    QTimer *m_debounce = nullptr;
    QStringList m_watchFiles;  // files we want to stay in sync with

    QVariantMap m_sys;   // parsed system palette (app-palette/colors json)
    QVariantMap m_over;  // parsed config.ini overrides
    bool m_followSystem = true;
    bool m_dynamicBg = false;   // "Fondo dinámico" pedido por la UI (Main.qml)

    // resolved values
    QColor m_bg, m_surface, m_surfaceAlt, m_border, m_borderSubtle;
    QColor m_accent, m_onAccent, m_accentDim, m_text, m_textDim, m_danger;
    QString m_source;
};
