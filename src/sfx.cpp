#include "sfx.h"
#include <QDebug>
#include <QUrl>
#include <QProcess>
#include <QFileInfo>

Sfx::Sfx(QObject *parent)
    : QObject(parent)
    , m_settings(new QSettings("lotus-tune", "lotus-tune", this))
    , m_enabled(true)
    , m_volume(0.35)
{
    loadSettings();
    const QString click = QStringLiteral("qrc:/sounds/click.wav");
    const QString clickToggle = QStringLiteral("qrc:/sounds/click_toggle.wav");
    const QString clickPlay = QStringLiteral("qrc:/sounds/click_play.wav");
    const QString clickLike = QStringLiteral("qrc:/sounds/click_like.wav");
    m_soundMap.insert("tap", click);
    m_soundMap.insert("click", click);
    m_soundMap.insert("open", click);
    m_soundMap.insert("play", clickPlay);
    m_soundMap.insert("pause", clickPlay);
    m_soundMap.insert("like", clickLike);
    m_soundMap.insert("unlike", click);
    m_soundMap.insert("add", click);
    m_soundMap.insert("remove", click);
    m_soundMap.insert("toggle", clickToggle);
    m_soundMap.insert("success", click);
    m_soundMap.insert("error", click);
}

void Sfx::loadSettings()
{
    m_enabled = m_settings->value("uiSounds", true).toBool();
    m_volume = m_settings->value("uiSoundsVolume", 0.35).toReal();
    if (m_volume < 0.0) m_volume = 0.0;
    if (m_volume > 1.0) m_volume = 1.0;
}

void Sfx::saveSettings()
{
    m_settings->setValue("uiSounds", m_enabled);
    m_settings->setValue("uiSoundsVolume", m_volume);
    m_settings->sync();
}

bool Sfx::enabled() const { return m_enabled; }
void Sfx::setEnabled(bool enabled)
{
    if (m_enabled == enabled) return;
    m_enabled = enabled;
    saveSettings();
    emit enabledChanged(m_enabled);
}

qreal Sfx::volume() const { return m_volume; }
void Sfx::setVolume(qreal volume)
{
    if (volume < 0.0) volume = 0.0;
    if (volume > 1.0) volume = 1.0;
    if (m_volume == volume) return;
    m_volume = volume;
    saveSettings();
    emit volumeChanged(m_volume);
}

void Sfx::play(const QString &name)
{
    if (!m_enabled) return;
    QString path = m_soundMap.value(name);
    if (path.isEmpty()) path = QStringLiteral("qrc:/sounds/click.wav");
    tryPlayWithSoundEffect(path);
}

void Sfx::tryPlayWithSoundEffect(const QString &path)
{
    QUrl url(path.startsWith("qrc:/") ? QUrl(path) : QUrl::fromLocalFile(path));
    if (!m_effects.contains(path)) {
        QSoundEffect *e = new QSoundEffect(this);
        e->setSource(url);
        e->setVolume(m_volume);
        m_effects.insert(path, e);
    }
    QSoundEffect *e = m_effects.value(path);
    if (e->status() == QSoundEffect::Ready) {
        e->setVolume(m_volume);
        e->play();
        return;
    }
    if (e->status() == QSoundEffect::Error) {
        playWithPw(path);
        return;
    }
}

void Sfx::playWithPw(const QString &path)
{
    if (path.isEmpty()) return;
    QStringList args;
    if (path.startsWith("qrc:/")) {
        // fallback to file on disk if available? the file is in build dir? no
        args << "/home/lots/lotus-tune/sounds/click.wav";
    } else {
        args << path;
    }
    QProcess::startDetached("pw-play", args);
}
