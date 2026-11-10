#include "sfx.h"
#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QStandardPaths>
#include <QUrl>

Sfx::Sfx(QObject *parent)
    : QObject(parent)
    , m_settings(new QSettings("lotus-tune", "lotus-tune", this))
    , m_enabled(true)
    , m_volume(0.5)
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
#ifdef Q_OS_LINUX
    // On Linux the sounds are played by pw-play, NOT by QSoundEffect. Qt
    // 6.12 crashed inside libQt6Multimedia (data-loop thread and main
    // thread, same spot) after a few minutes of playback: the QAudioSink
    // of every QSoundEffect got reconfigured when mpv opened or closed its
    // own PipeWire stream, and the audio engine died with it, taking the
    // whole app down. pw-play hands each sound to PipeWire and returns, so
    // there is no sink of ours to reconfigure.
    m_wavDir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
               + QStringLiteral("/sounds");
    QDir().mkpath(m_wavDir);
#else
    preloadAll();
    startKeepAlive();
#endif
}

#ifndef Q_OS_LINUX
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
    // A digital silence loop (it samples 0, hence it is inaudible at any
    // volume) keeps the audio engine alive. Without this, the
    // first sound after a while of silence could be lost because the sink
    // suspends and the engine takes a while to wake up.
    m_keepAlive = new QSoundEffect(this);
    m_keepAlive->setSource(QUrl(QStringLiteral("qrc:/sounds/silence.wav")));
    m_keepAlive->setLoopCount(QSoundEffect::Infinite);
    m_keepAlive->setVolume(1.0);
    m_keepAlive->play();
}
#endif

void Sfx::setWarm(bool on)
{
    Q_UNUSED(on)
    // No silent loop is kept on Linux: pw-play starts on demand and the
    // sounds are already on disk (extracted once), so there is nothing to
    // wake up and nothing to keep burning CPU in the background.
}

#ifndef Q_OS_LINUX
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
#endif

void Sfx::loadSettings()
{
    m_enabled = m_settings->value("uiSounds", true).toBool();
    m_volume = m_settings->value("uiSoundsVolume", 0.5).toReal();
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
#ifdef Q_OS_LINUX
    if (qEnvironmentVariableIsSet("LOTUS_TUNE_SFX_DEBUG"))
        qInfo() << "[sfx]" << name << path;
    playWithPw(path);
#else
    tryPlayWithSoundEffect(path);
#endif
}

#ifndef Q_OS_LINUX
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
#endif

void Sfx::playWithPw(const QString &path)
{
    if (path.isEmpty()) return;
    QString file = path;
    // The resources (qrc:/…) are not files: they are written once to the
    // cache and played from there (pw-play only reads files).
    if (file.startsWith(QLatin1String("qrc:/"))) {
        const QString base = QFileInfo(file).fileName();
        if (!m_wavDir.isEmpty()) {
            const QString disk = m_wavDir + QLatin1Char('/') + base;
            if (!QFile::exists(disk) || QFileInfo(disk).size() == 0) {
                // QFile::copy() with a :/ resource as the source is not
                // reliable: the bytes are read and written by hand. QFile
                // wants the ":/sounds/x.wav" form, not the "qrc:/..." URL.
                QString res = file;
                if (res.startsWith(QLatin1String("qrc:")))
                    res.replace(0, 4, QStringLiteral(":"));
                QFile in(res);
                const bool inOk = in.open(QIODevice::ReadOnly);
                if (inOk) {
                    const QByteArray bytes = in.readAll();
                    QFile out(disk);
                    const bool outOk =
                        out.open(QIODevice::WriteOnly | QIODevice::Truncate);
                    if (outOk) {
                        out.write(bytes);
                        out.close();
                    }
                    if (qEnvironmentVariableIsSet("LOTUS_TUNE_SFX_DEBUG"))
                        qInfo() << "[sfx] res" << res << "bytes" << bytes.size()
                                << "outOpen" << outOk << "err" << out.errorString();
                } else if (qEnvironmentVariableIsSet("LOTUS_TUNE_SFX_DEBUG")) {
                    qInfo() << "[sfx] cannot read" << res << in.errorString();
                }
                if (qEnvironmentVariableIsSet("LOTUS_TUNE_SFX_DEBUG"))
                    qInfo() << "[sfx] extract" << file << "->" << disk
                            << QFileInfo(disk).size();
            }
            if (QFile::exists(disk))
                file = disk;
        }
    }
    if (!QFile::exists(file))
        return;
#ifdef Q_OS_LINUX
    // The volume is the one of the interface; the role tells PipeWire it is
    // a notification and not music (it does not duck the player).
    QProcess::startDetached(QStringLiteral("pw-play"),
                            {QStringLiteral("--volume"),
                             QString::number(m_volume, 'f', 2),
                             QStringLiteral("--media-role"),
                             QStringLiteral("Notification"), file});
#else
    // There is no PipeWire player on Windows or Android: the sound of
    // the interface is played by Qt itself.
    Q_UNUSED(file)
#endif
}
