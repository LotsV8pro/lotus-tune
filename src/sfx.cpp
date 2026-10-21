#include "sfx.h"
#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QUrl>

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
    preloadAll();
    startKeepAlive();
}

void Sfx::preloadAll()
{
    // Loads the sounds ahead of time (QSoundEffect loads lazily; without
    // this the first play() did not sound while it was still Loading).
    effectFor(QStringLiteral("qrc:/sounds/click.wav"));
    effectFor(QStringLiteral("qrc:/sounds/click_toggle.wav"));
    effectFor(QStringLiteral("qrc:/sounds/click_play.wav"));
    effectFor(QStringLiteral("qrc:/sounds/click_like.wav"));
}

void Sfx::startKeepAlive()
{
    // Un bucle de silencio digital (samples a 0, por eso es inaudible a
    // cualquier volumen) mantiene activo el motor de audio. Sin esto, el
    // first sound after a while of silence could be lost because the sink
    // suspende y el motor tarda en despertar.
    m_keepAlive = new QSoundEffect(this);
    m_keepAlive->setSource(QUrl(QStringLiteral("qrc:/sounds/silence.wav")));
    m_keepAlive->setLoopCount(QSoundEffect::Infinite);
    m_keepAlive->setVolume(1.0);
    m_keepAlive->play();
}

QSoundEffect *Sfx::effectFor(const QString &path)
{
    if (!m_effects.contains(path)) {
        QSoundEffect *e = new QSoundEffect(this);
        e->setSource(QUrl(path));
        e->setVolume(m_volume);
        m_effects.insert(path, e);
        // If it was asked to play while it was still loading, it is played
        // once ready: that way the FIRST click is never mute.
        connect(e, &QSoundEffect::statusChanged, this, [this, e]() {
            if (e->status() == QSoundEffect::Ready && m_pending.remove(e)) {
                e->setVolume(m_volume);
                e->play();
            }
        });
    }
    return m_effects.value(path);
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
    QSoundEffect *e = effectFor(path);
    e->setVolume(m_volume);
    switch (e->status()) {
    case QSoundEffect::Ready:
        e->play();
        break;
    case QSoundEffect::Loading:
        // Still loading: play it as soon as it is ready (see effectFor).
        m_pending.insert(e);
        break;
    default: // QSoundEffect::Error
        playWithPw(path);
        break;
    }
}

void Sfx::playWithPw(const QString &path)
{
    if (path.isEmpty()) return;
    QString file = path;
    // Los recursos (qrc:/…) no son ficheros: buscar la copia en disco junto al
    // binary or in the source tree for the pw-play fallback.
    if (file.startsWith(QLatin1String("qrc:/"))) {
        const QString base = QFileInfo(file).fileName();
        const QStringList cands{
            QCoreApplication::applicationDirPath() + QStringLiteral("/sounds/") + base,
            QCoreApplication::applicationDirPath() + QStringLiteral("/../sounds/") + base,
            QCoreApplication::applicationDirPath() + QStringLiteral("/../../sounds/") + base,
        };
        for (const QString &c : cands) {
            if (QFile::exists(c)) { file = c; break; }
        }
    }
    if (!QFile::exists(file))
        return;
    QProcess::startDetached(QStringLiteral("pw-play"), {file});
}
