#include "appconfig.h"
#include "catalog.h"
#include "discordrpc.h"
#include "stubs.h"
#include "downloads.h"
#include "sfx.h"
#include "lyrics.h"
#ifndef Q_OS_ANDROID
#include "mpris.h"
#endif
#include "perf.h"
#include "player.h"
#include "roundedart.h"
#include "sources.h"
#include "theme.h"
#include "wash.h"

#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QMouseEvent>
#include <QQuickItem>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQuickWindow>
#include <QStandardPaths>
#include <QThread>

#include <csignal>
#ifndef Q_OS_ANDROID
#include <unistd.h>
#endif

static void rawMessageHandler(QtMsgType type, const QMessageLogContext &, const QString &msg)
{
    const char *tag = (type == QtFatalMsg) ? "FATAL" :
                      (type == QtCriticalMsg) ? "CRIT" :
                      (type == QtWarningMsg) ? "WARN" : "INFO";
    fprintf(stderr, "[%s] %s\n", tag, qPrintable(msg));
    fflush(stderr);
}

static void dumpErrors(const QQmlComponent &component)
{
    for (const QQmlError &e : component.errors())
        fprintf(stderr, "QML ERROR: %s\n", qPrintable(e.toString()));
    fflush(stderr);
}

// ---------------------------------------------------------------------------
// Mouse side buttons (4 = back, 5 = forward).
//
// They are filtered at the window level so they always arrive, even if the
// QML below (lists, panels) eats the event. It calls the root QML object's
// functions ("mouseNavBack" / "mouseNavForward").
// ---------------------------------------------------------------------------
class MouseNavFilter : public QObject
{
public:
    explicit MouseNavFilter(QObject *root, QObject *parent = nullptr)
        : QObject(parent), m_root(root) {}

protected:
    bool eventFilter(QObject *obj, QEvent *ev) override
    {
        if (ev->type() == QEvent::MouseButtonPress) {
            const auto *me = static_cast<QMouseEvent *>(ev);
            // Click outside the focused text field: it drops the focus, like
            // on the web. Without this the "Search" box stays focused even
            // when clicking elsewhere, the shortcuts (F, L, M, Space...) keep
            // being filtered as if "typing" and they die until restart.
            // It is done here because Qt 6.12's `Item` still has no
            // containsMousePressed signal, which would solve it in QML alone.
            auto *win = qobject_cast<QQuickWindow *>(parent());
            if (win && win->activeFocusItem()) {
                QQuickItem *focus = win->activeFocusItem();
                const QPointF p = me->position();
                const QPointF o = focus->mapToScene(QPointF(0, 0));
                const QRectF r(o, QSizeF(focus->width(), focus->height()));
                if (!r.contains(p))
                    focus->setFocus(false);
            }
            const char *fn = nullptr;
            if (me->button() == Qt::BackButton)
                fn = "mouseNavBack";
            else if (me->button() == Qt::ForwardButton)
                fn = "mouseNavForward";
            if (fn && m_root) {
                QMetaObject::invokeMethod(m_root, fn);
                return true;   // consumed: the QML must not receive it
            }
        }
        return QObject::eventFilter(obj, ev);
    }

private:
    QObject *m_root = nullptr;
};

// ---------------------------------------------------------------------------
// Single instance (QLocalServer + QLocalSocket)
//
// The second instance creates no window: it connects to the first one's
// socket, sends it "raise" and exits with 0. Safety nets:
//  - if the socket was left orphan (SIGKILL/pkill without cleanup) it is
//    removed and the app starts normally;
//  - a PID file allows detecting live instances, and if the PID is dead it
//    is cleaned so the startup is never blocked.
// ---------------------------------------------------------------------------

static QQuickWindow *g_mainWindow = nullptr;

static QString appRuntimeDir()
{
    QString dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (dir.isEmpty())
        dir = QDir::tempPath();
    return dir;
}

static QString appSocketPath()
{
    return appRuntimeDir() + QStringLiteral("/lotus-tune-app.sock");
}

static QString appPidPath()
{
    return appRuntimeDir() + QStringLiteral("/lotus-tune.pid");
}

static bool processAlive(qint64 pid)
{
#ifdef Q_OS_ANDROID
    Q_UNUSED(pid)
    return false;   // there is no single instance on a phone
#else
    if (pid <= 0)
        return false;
    return ::kill(static_cast<pid_t>(pid), 0) == 0;
#endif
}

// The PID must really belong to lotus-tune (it avoids blocking the startup
// with a PID recycled by another process).
static bool isLotusTunePid(qint64 pid)
{
    if (pid <= 0)
        return false;
    QFile f(QStringLiteral("/proc/%1/comm").arg(pid));
    if (!f.open(QIODevice::ReadOnly))
        return false;
    return QString::fromUtf8(f.readAll()).trimmed() == QLatin1String("lotus-tune");
}

static bool sendRaiseToServer(int connectMs = 200)
{
    QLocalSocket sock;
    sock.connectToServer(appSocketPath());
    if (!sock.waitForConnected(connectMs))
        return false;
    sock.write("raise\n");
    sock.flush();
    sock.waitForBytesWritten(150);
    // No answer is awaited: the first instance may still be loading QML
    // (no event loop); the data stays in its socket buffer.
    return true;
}

static void raiseMainWindow()
{
    if (!g_mainWindow)
        return;
    g_mainWindow->showNormal();
    g_mainWindow->raise();
    g_mainWindow->requestActivate();
}

enum class SingleInstance { Primary, ExistingRaised };

// It returns ExistingRaised if there was already a live instance and it was
// asked to raise its window (the caller must exit without creating a
// window).
static SingleInstance setupSingleInstance(QLocalServer **outServer)
{
    const QString sock = appSocketPath();
    const QString pidFile = appPidPath();

    qint64 pid = 0;
    {
        QFile f(pidFile);
        if (f.open(QIODevice::ReadOnly))
            pid = QString::fromUtf8(f.readAll()).trimmed().toLongLong();
    }
    const bool live = processAlive(pid) && isLotusTunePid(pid);

    // With a live instance there may be a startup window where the server
    // already listens: it retries briefly before giving up. The wait is
    // short on purpose: it blocks the window from appearing.
    const int tries = live ? 3 : 1;
    for (int i = 0; i < tries; ++i) {
        if (sendRaiseToServer(150))
            return SingleInstance::ExistingRaised;
        if (i + 1 < tries)
            QThread::msleep(80);
    }

    // Nobody listens: leftovers are cleaned (orphan socket and, if needed,
    // dead PID).
    QFile::remove(sock);
    if (!live)
        QFile::remove(pidFile);

    auto *server = new QLocalServer;
    server->setSocketOptions(QLocalServer::UserAccessOption);
    if (!server->listen(sock)) {
        // Race: another process may have listened in between. If it
        // answers, it rules; if not, the socket is garbage and it is
        // retried once.
        if (sendRaiseToServer()) {
            delete server;
            return SingleInstance::ExistingRaised;
        }
        QLocalServer::removeServer(sock);
        if (!server->listen(sock))
            qWarning() << "[single] no se pudo escuchar" << sock
                       << server->errorString();
    }

    {
        QFile f(pidFile);
        if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            f.write(QByteArray::number(QCoreApplication::applicationPid()));
            f.close();
        }
    }

    QObject::connect(server, &QLocalServer::newConnection, server, [server] {
        while (QLocalSocket *client = server->nextPendingConnection()) {
            QObject::connect(client, &QLocalSocket::readyRead, client, [client] {
                const QByteArray cmd = client->readAll().trimmed();
                if (cmd == "raise") {
                    raiseMainWindow();
                    client->write("ok\n");
                    client->flush();
                }
            });
            QObject::connect(client, &QLocalSocket::disconnected, client,
                             &QObject::deleteLater);
        }
    });

    *outServer = server;
    return SingleInstance::Primary;
}

// ---------------------------------------------------------------------------
// Settings that can ONLY be applied before the dynamic loader loads the
// graphics driver (libQt6Gui links libGLX/libEGL). A qputenv() inside
// main() comes too late: the vendor is already loaded. So, if they are
// missing, we re-exec ourselves ONCE with them set. The re-exec keeps
// the PID, so it is transparent to systemd (a single unit) and to the
// single instance.
//
//   . MANGOHUD=0 - MangoHud comes enabled in the session environment and
//     adds ~23 MB of RSS to a player that does not draw overlays.
//   . __GLX_VENDOR_LIBRARY_NAME=mesa - libGLX loads the GPU vendor at
//     startup; with software rendering GL is not used, so Mesa's (~18 MB)
//     is loaded instead of NVIDIA's (~47 MB).
//
// Escape hatch: LOTUS_TUNE_NO_TWEAKS=1 disables both.
// ---------------------------------------------------------------------------
static void ensureFrugalExecEnv(char *argv[])
{
    if (qEnvironmentVariableIsSet("_LOTUS_TUNE_ENV_READY")
        || qEnvironmentVariableIsSet("LOTUS_TUNE_NO_TWEAKS"))
        return;

    bool changed = false;
    if (qgetenv("MANGOHUD") != "0") {
        qputenv("MANGOHUD", "0");
        changed = true;
    }
    // Only when the rendering is software (the default backend): if the
    // user forces a GPU backend their choice is respected. The session
    // already brings __GLX_VENDOR_LIBRARY_NAME=nvidia, so it has to be
    // overwritten (filling it in if missing is not enough).
    if (qEnvironmentVariableIsEmpty("QT_QUICK_BACKEND")
        && qgetenv("__GLX_VENDOR_LIBRARY_NAME") != "mesa") {
        qputenv("__GLX_VENDOR_LIBRARY_NAME", "mesa");
        changed = true;
    }
    if (!changed)
        return;

#ifdef Q_OS_ANDROID
    // There is no /proc/self/exe to re-exec on a phone.
    Q_UNUSED(argv)
    return;
#else
    qputenv("_LOTUS_TUNE_ENV_READY", "1");
    char exe[4096];
    const qint64 n = ::readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0)
        return;
    exe[n] = '\0';
    ::execv(exe, argv);
    // If execv fails, we carry on with the current process (without the
    // tweaks).
#endif
}

int main(int argc, char *argv[])
{
    ensureFrugalExecEnv(argv);

    qInstallMessageHandler(rawMessageHandler);

    // Qt Quick software rendering: it avoids the OpenGL context entirely,
    // the GPU driver (Mesa/llvmpipe/NVIDIA) and its texture/vertex
    // buffers. It is the lever that trims the RAM the most (Qt Quick heap
    // ~85 MB -> ~28 MB in the measured profile). It is only set if the user
    // has not forced it already, so GL can be brought back with
    // QT_QUICK_BACKEND=rhi|software|... if it were ever needed. It must
    // run before QGuiApplication.
    // The software backend does not exist on a phone (the scenegraph uses
    // RHI/OpenGL ES there), so the values are only forced on the desktop.
    const bool softwareBackend = qEnvironmentVariableIsEmpty("QT_QUICK_BACKEND");
#ifndef Q_OS_ANDROID
    if (softwareBackend)
        qputenv("QT_QUICK_BACKEND", "software");
    if (qEnvironmentVariableIsEmpty("QSG_RENDER_LOOP"))
        qputenv("QSG_RENDER_LOOP", "basic");
#endif

    // This player never decodes video: the interface sounds use
    // QSoundEffect (audio only). Turning off Qt Multimedia's hardware
    // probing keeps its ffmpeg backend from loading VA-API, VDPAU, CUDA
    // and NVIDIA's video driver, and from making the first GL call that
    // drags in the whole driver vendor (~40-65 MB of RSS). It must run
    // before building QGuiApplication.
    if (qEnvironmentVariableIsEmpty("QT_FFMPEG_DECODING_HW_DEVICE_TYPES"))
        qputenv("QT_FFMPEG_DECODING_HW_DEVICE_TYPES", "");
    if (qEnvironmentVariableIsEmpty("QT_FFMPEG_ENCODING_HW_DEVICE_TYPES"))
        qputenv("QT_FFMPEG_ENCODING_HW_DEVICE_TYPES", "");

    // With software rendering GL is never used. If GLVND ends up loading a
    // vendor (libGLX/libEGL are DT_NEEDED of libQt6Gui), let it be Mesa's
    // (small) and not NVIDIA's (libnvidia-glcore + libnvidia-gpucomp,
    // ~47 MB). Only when we choose software, so nobody who forces
    // QT_QUICK_BACKEND=rhi on purpose is degraded.
    if (softwareBackend) {
        if (qEnvironmentVariableIsEmpty("__GLX_VENDOR_LIBRARY_NAME"))
            qputenv("__GLX_VENDOR_LIBRARY_NAME", "mesa");
        if (qEnvironmentVariableIsEmpty("LIBGL_ALWAYS_SOFTWARE"))
            qputenv("LIBGL_ALWAYS_SOFTWARE", "1");
    }

    // Frugal Qt Quick environment (must run before QGuiApplication).
    applyPerfEnv();

    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("lotus-tune"));
    app.setOrganizationName(QStringLiteral("lotus-tune"));
    app.setDesktopFileName(QStringLiteral("lotustune"));

    // Single instance: the second one just asks the first to raise the
    // window and exits with 0 without creating anything.
    QLocalServer *instanceServer = nullptr;
    if (setupSingleInstance(&instanceServer) == SingleInstance::ExistingRaised) {
        qInfo() << "[single] ya hay una instancia en marcha; ventana solicitada";
        return 0;
    }
    QObject::connect(&app, &QCoreApplication::aboutToQuit, [&instanceServer] {
        if (instanceServer)
            instanceServer->close();
        QFile::remove(appSocketPath());
        QFile::remove(appPidPath());
    });

    QQmlApplicationEngine engine;

    // Live theme (iNiR/matugen palette + config.ini overrides).
    AppTheme theme;
    engine.rootContext()->setContextProperty(QStringLiteral("Sys"), &theme);

    // Platforms (YouTube Music / SoundCloud ready, Spotify / Tidal registered).
    SourceManager sources;
    engine.rootContext()->setContextProperty(QStringLiteral("sources"), &sources);

    // yt-dlp metadata + saved library.
    Catalog catalog(&sources);
    engine.rootContext()->setContextProperty(QStringLiteral("catalog"), &catalog);

    // Persistent settings (theme ini + QSettings conf), see src/appconfig.cpp.
    AppConfig appcfg;
    engine.rootContext()->setContextProperty(QStringLiteral("appcfg"), &appcfg);

    // mpv playback engine (headless, JSON IPC).
    Player player;
    engine.rootContext()->setContextProperty(QStringLiteral("player"), &player);

    // Synced lyrics (LRCLIB) for the "Now Playing" view.
    Lyrics lyrics;
    engine.rootContext()->setContextProperty(QStringLiteral("lyrics"), &lyrics);
    // The engine feeds the lyrics state published for the inir widgets
    // (clock position and play/pause). See Lyrics::setEngine.
    lyrics.setEngine(&player);

    // Discord Rich Presence. On a phone there is no local socket for it:
    // a do-nothing object with the same API is exposed instead.
    DiscordRpc discord;
    engine.rootContext()->setContextProperty(QStringLiteral("discord"), &discord);

    // System media controls (MPRIS2 over D-Bus). The mpv engine is injected
    // into it to publish the real position/duration. On a phone there is no
    // D-Bus: the stub keeps the QML unchanged.
#ifdef Q_OS_ANDROID
    MprisStub mpris;
#else
    Mpris mpris(&player);
#endif
    engine.rootContext()->setContextProperty(QStringLiteral("mpris"), &mpris);
#ifdef Q_OS_ANDROID
    // There is no MPRIS on a phone (no D-Bus): the stub is inert.
#else
    // org.mpris.MediaPlayer2.Raise -> bring the window to the front.
    QObject::connect(&mpris, &Mpris::raiseRequested, [] { raiseMainWindow(); });
    // org.mpris.MediaPlayer2.Quit -> quit. Main.qml also handles it with
    // Qt.quit(), but the close must not depend on the QML layer being at
    // the exact point of its cycle: it is guaranteed here (idempotent).
    QObject::connect(&mpris, &Mpris::quitRequested, &app, &QCoreApplication::quit);
#endif

    // YouTube downloads (yt-dlp) + local library.
    Downloads downloads;
    engine.rootContext()->setContextProperty(QStringLiteral("downloads"), &downloads);

    Sfx sfx;
    engine.rootContext()->setContextProperty(QStringLiteral("sfx"), &sfx);

    // Background wash: a real CPU blur of the track's thumbnail, served by
    // an image provider ("image://wash/<serial>"). That way the
    // background and the cinema mode come out as a soft veil, with no
    // blocks and no pixelation.
    Wash wash(&engine);
    engine.addImageProvider(QStringLiteral("wash"), new WashProvider(&wash));
    engine.rootContext()->setContextProperty(QStringLiteral("wash"), &wash);

    // Colour picker of the artworks for the cards (dominant colour -> face).
    ColorPick colorpick(&engine);
    engine.rootContext()->setContextProperty(QStringLiteral("colorpick"), &colorpick);

    // Rounded artwork: the centre crop and the corners are done in the
    // CPU and served by an image provider ("image://rart/<key>").
    // That way the corners are really rounded (a Rectangle's `clip` ignores
    // the radius) and the crop never comes out off-centre.
    RoundedArt roundedart(&engine);
    engine.addImageProvider(QStringLiteral("rart"), new RoundedArtProvider(&roundedart));
    engine.rootContext()->setContextProperty(QStringLiteral("rart"), &roundedart);

    QQmlComponent component(&engine);
    component.loadFromModule("LotusTune", "Main");
    if (component.isError()) {
        dumpErrors(component);
        return 1;
    }
    QObject *root = component.create();
    if (!root) {
        dumpErrors(component);
        return 1;
    }
    g_mainWindow = qobject_cast<QQuickWindow *>(root);
    if (g_mainWindow)
        g_mainWindow->installEventFilter(new MouseNavFilter(root, g_mainWindow));

    qInfo() << "[main] Lotus Tune running";
    return app.exec();
}
