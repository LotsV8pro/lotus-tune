#pragma once

#include <QObject>
#include <QSoundEffect>
#include <QProcess>
#include <QUrl>
#include <QSettings>
#include <QMap>
#include <QSet>

class Sfx : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(qreal volume READ volume WRITE setVolume NOTIFY volumeChanged)
public:
    explicit Sfx(QObject *parent = nullptr);

    bool enabled() const;
    void setEnabled(bool enabled);

    qreal volume() const;
    void setVolume(qreal volume);

    Q_INVOKABLE void play(const QString &name);

signals:
    void enabledChanged(bool enabled);
    void volumeChanged(qreal volume);

private:
    void loadSettings();
    void saveSettings();
    void preloadAll();
    // Devuelve (creando si hace falta) el QSoundEffect de un recurso.
    QSoundEffect *effectFor(const QString &path);
    void tryPlayWithSoundEffect(const QString &path);
    void playWithPw(const QString &path);
    // Bucle silencioso para mantener despierto el motor de audio.
    void startKeepAlive();

    QSettings *m_settings;
    bool m_enabled;
    qreal m_volume;
    QMap<QString, QSoundEffect*> m_effects;
    QMap<QString, QString> m_soundMap;
    // Effects whose play() was asked while they were still loading.
    QSet<QSoundEffect*> m_pending;
    QSoundEffect *m_keepAlive = nullptr;
};
