#pragma once

#include <QObject>
#include <QSoundEffect>
#include <QProcess>
#include <QUrl>
#include <QSettings>
#include <QMap>

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
    void tryPlayWithSoundEffect(const QString &path);
    void playWithPw(const QString &path);

    QSettings *m_settings;
    bool m_enabled;
    qreal m_volume;
    QMap<QString, QSoundEffect*> m_effects;
    QMap<QString, QString> m_soundMap;
};