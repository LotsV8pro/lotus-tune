#include "appconfig.h"
#include "audiocache.h"
#include "catalog.h"
#include "paths.h"
#include "discordrpc.h"
#include "updates.h"
#include "translator.h"
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
#include <QIcon>
#include <QLocalServer>
#include <QLocalSocket>
#include <QMouseEvent>
#include <QQuickItem>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQuickWindow>
#include <QResource>
#include <QStandardPaths>
#include <QThread>
#include <QElapsedTimer>
#include <QEvent>
#include <QtQuick/QSGRendererInterface>

// Counters of the frame meter (LOTUS_FRAME_LOG).
struct FrameStats
{
    qint64 last = 0;
    int frames = 0;
    int over16 = 0;
    int over33 = 0;
    double sum = 0;
    double mx = 0;
};

#include <csignal>
#include <cstdio>
#if defined(Q_OS_UNIX) && !defined(Q_OS_ANDROID)
#include <unistd.h>
#endif
#ifdef Q_OS_ANDROID
#include <android/log.h>
#define ANDROID_LOG(prio, msg) \
    __android_log_print(prio, "LotusTune", "%s", qPrintable(msg))
#else
#define ANDROID_LOG(prio, msg) ((void) 0)
#endif

// The desktop prints to stderr (good for journalctl); on Android stderr is
// a black hole, so every level also goes to logcat: without it a failure
// of the QML loader is a silent instant crash, invisible.
static void rawMessageHandler(QtMsgType type, const QMessageLogContext &, const QString &msg)
{
    const char *tag = (type == QtFatalMsg) ? "FATAL" :
                      (type == QtCriticalMsg) ? "CRIT" :
                      (type == QtWarningMsg) ? "WARN" : "INFO";
    fprintf(stderr, "[%s] %s\n", tag, qPrintable(msg));
    fflush(stderr);
#ifdef Q_OS_ANDROID
    ANDROID_LOG((type == QtFatalMsg) ? ANDROID_LOG_FATAL :
                (type == QtCriticalMsg) ? ANDROID_LOG_ERROR :
                (type == QtWarningMsg) ? ANDROID_LOG_WARN : ANDROID_LOG_INFO, msg);
#endif
}

static void dumpErrors(const QQmlComponent &component)
{
    for (const QQmlError &e : component.errors()) {
        fprintf(stderr, "QML ERROR: %s\n", qPrintable(e.toString()));
#ifdef Q_OS_ANDROID
        __android_log_print(ANDROID_LOG_ERROR, "LotusTune", "QML ERROR: %s",
                            qPrintable(e.toString()));
#endif
    }
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
#if defined(Q_OS_ANDROID) || defined(Q_OS_WIN)
    Q_UNUSED(pid)
    return false;   // there is no single instance on a phone or on Windows
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
//
// Android-specific: QT_ANDROID_HWUI_MODE=0 disables MIUI HWUI rendering
// which causes pthread_mutex crashes on exit. Set QT_LOGGING_RULES for
// debugging Qt Android issues.
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

#ifdef Q_OS_ANDROID
    // MIUI HWUI workaround: disable HWUI to prevent pthread_mutex crashes
    // MIUI's custom HWUI renderer conflicts with Qt's OpenGL rendering
    if (qEnvironmentVariableIsEmpty("QT_ANDROID_HWUI_MODE")) {
        qputenv("QT_ANDROID_HWUI_MODE", "0");
        changed = true;
    }
    // Force Qt to use OpenGL ES backend (not MIUI's Vulkan/software)
    if (qEnvironmentVariableIsEmpty("QT_ANDROID_GRAPHICS_RENDERER")) {
        qputenv("QT_ANDROID_GRAPHICS_RENDERER", "opengl");
        changed = true;
    }
    // Disable MIUI auto theme dark mode which triggers HWUI theme overlays
    if (qEnvironmentVariableIsEmpty("QT_ANDROID_FORCE_DARK")) {
        qputenv("QT_ANDROID_FORCE_DARK", "0");
        changed = true;
    }
    // Additional HWUI mode variables to completely suppress MIUI rendering threads
    if (qEnvironmentVariableIsEmpty("HWUI_RENDER_MODE")) {
        qputenv("HWUI_RENDER_MODE", "software");
        changed = true;
    }
    if (qEnvironmentVariableIsEmpty("SKIA_RENDER_MODE")) {
        qputenv("SKIA_RENDER_MODE", "software");
        changed = true;
    }
#endif

    if (!changed)
        return;

#if defined(Q_OS_ANDROID) || defined(Q_OS_WIN)
    // There is no /proc/self/exe to re-exec on a phone or on Windows.
    // Environment changes are applied directly (no re-exec possible).
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
    // The MIUI HWUI crash is triggered when any graphics stack is initialized.
    // To allow the C++ backend to run on MIUI devices, we MUST avoid creating
    // a QGuiApplication if we are being used as a JNI bridge.
    if (qEnvironmentVariableIsSet("LOTUS_NATIVE_UI")) {
        QCoreApplication app(argc, argv);
        app.setApplicationName(QStringLiteral("lotus-tune"));
        // Backend only mode
        return app.exec();
    }

    ensureFrugalExecEnv(argv);

    // The version of the app: the settings compare it with the one
    // published in the repository.
    QCoreApplication::setApplicationVersion(QStringLiteral(LOTUS_TUNE_VERSION));

    // `--version` (or `-v`): prints the version and leaves. It is how the
    // installer and the launcher check which binary is the installed one
    // without opening a window, and the answer is the version the binary
    // was built with (not a file date).
    for (int i = 1; i < argc; ++i) {
        const QByteArray a(argv[i]);
        if (a == "--version" || a == "-v") {
            std::fprintf(stdout, "lotus-tune %s\n", LOTUS_TUNE_VERSION);
            std::fflush(stdout);
            return 0;
        }
    }

    qInstallMessageHandler(rawMessageHandler);

    // Qt Quick software rendering: it avoids the OpenGL context entirely,
    // the GPU driver (Mesa/llvmpipe/NVIDIA) and its texture/vertex
    // buffers. It is the lever that trims the RAM the most (Qt Quick heap
    // ~85 MB -> ~28 MB in the measured profile). It is only set if the user
    // has not forced it already, so GL can be brought back with
    // QT_QUICK_BACKEND=rhi|software|... if it were ever needed. It must
    // run before QGuiApplication.
    // ONLY on the desktop: on a phone the software rasterizer paints the
    // whole 1080x2400 window on the CPU (measured ~8 ms per frame here,
    // i.e. the entire 120 Hz budget before anything moves) and that is
    // what made the menus feel heavy. The phone renders with the hardware
    // (RHI -> OpenGL ES) and the default threaded render loop, which is
    // what every Qt app uses there.
#ifndef Q_OS_ANDROID
    if (qEnvironmentVariableIsEmpty("QT_QUICK_BACKEND"))
        qputenv("QT_QUICK_BACKEND", "software");
    if (qEnvironmentVariableIsEmpty("QSG_RHI_BACKEND"))
        qputenv("QSG_RHI_BACKEND", "software");
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

#ifdef Q_OS_ANDROID
    // The native helper (libytmcli.so) finds the cookies through this
    // variable: the process hangs on to the environment of this one at
    // the moment of igniting.
    qputenv("LOTUS_COOKIES",
            QStandardPaths::writableLocation(
                QStandardPaths::AppConfigLocation).toUtf8()
            + QByteArrayLiteral("/cookies.txt"));
    // Its own process: the child linker does not search the packaged
    // native lib dir by itself (its dependent Qt libs travel there).
    {
        const QString libDir = AppPaths::cliLibDir();
        if (!libDir.isEmpty()) {
            const QString old = qEnvironmentVariable("LD_LIBRARY_PATH");
            qputenv("LD_LIBRARY_PATH",
                    (libDir + (old.isEmpty() ? QString()
                                             : ":" + old)).toUtf8());
        }
    }
#endif

    // With software rendering GL is never used. If GLVND ends up loading a
    // vendor (libGLX/libEGL are DT_NEEDED of libQt6Gui), let it be Mesa's
    // (small) and not NVIDIA's (libnvidia-glcore + libnvidia-gpucomp,
    // ~47 MB). Only when we choose software, so nobody who forces
    // QT_QUICK_BACKEND=rhi on purpose is degraded.
    if (true) {
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
    // Window/taskbar icon: the installed hicolor icon; fall back to the
    // source tree icon so local runs show it too.
    QIcon appIcon = QIcon::fromTheme(QStringLiteral("lotus-tune"));
    if (appIcon.isNull()) {
#ifdef Q_OS_ANDROID
        // On Android, the icon is in the APK assets
        appIcon = QIcon(QStringLiteral(":/android_rcc_bundle/lotus-tune.svg"));
#else
        appIcon = QIcon(QStringLiteral(":/LotusTune/packaging/icons/lotus-tune.svg"));
#endif
    }
    if (!appIcon.isNull())
        app.setWindowIcon(appIcon);

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

#ifdef Q_OS_ANDROID
    // The APK ships the QML bundle as assets/android_rcc_bundle.rcc, but
    // this build does not register it automatically (the Qt module in the
    // binary points at qrc:/LotusTune/... while the bundle lives under
    // /android_rcc_bundle). Read it through the Android assets engine and
    // register it once. The buffer must outlive the resource, hence the
    // static QByteArray.
    {
        static QByteArray appRccData;
        QFile rcc(QStringLiteral("assets:/android_rcc_bundle.rcc"));
        if (rcc.open(QIODevice::ReadOnly)) {
            appRccData = rcc.readAll();
            const bool ok = QResource::registerResource(
                reinterpret_cast<const uchar *>(appRccData.constData()));
            qInfo() << "[android] app rcc bundle" << appRccData.size()
                    << "bytes, registered:" << ok;
        } else {
            qWarning() << "[android] cannot open assets:/android_rcc_bundle.rcc:"
                       << rcc.errorString();
        }
    }
    // Where the bundle really landed inside the resource tree. androiddeployqt
    // roots the rcc at /android_rcc_bundle, but it also appends the qrc's own
    // directory in some versions (Qt 6.6.3), leaving the files one level
    // deeper: /android_rcc_bundle/android_rcc_bundle. The prefix written in
    // the qrc does not change that. Look for the qmldir instead of trusting
    // either layout: with the wrong root the module import fails and the
    // fallback below has nowhere to load Main.qml from.
    const QString appRccRoot = QFile::exists(QStringLiteral(":/android_rcc_bundle/qmldir"))
        ? QStringLiteral(":/android_rcc_bundle")
        : QStringLiteral(":/android_rcc_bundle/android_rcc_bundle");
    qInfo() << "[android] app rcc root:" << appRccRoot;
    {
        // The Qt QML modules (QtQuick, QtQuick.Window, QtQuick.Controls...)
        // are not in the APK assets in this build either. A second RCC
        // carries them under /qt/qml so the engine can resolve the imports.
        static QByteArray qtRccData;
        QFile rcc(QStringLiteral("assets:/qt_qml.rcc"));
        if (rcc.open(QIODevice::ReadOnly)) {
            qtRccData = rcc.readAll();
            const bool ok = QResource::registerResource(
                reinterpret_cast<const uchar *>(qtRccData.constData()));
            qInfo() << "[android] Qt QML rcc bundle" << qtRccData.size()
                    << "bytes, registered:" << ok;
        } else {
            qWarning() << "[android] cannot open assets:/qt_qml.rcc:"
                       << rcc.errorString();
        }
    }
#endif

    QQmlApplicationEngine engine;

    // The QML of the app is compiled into the binary under /LotusTune (see
    // the generated qrc: prefix "/LotusTune/"), so `import LotusTune` only
    // resolves when the resource root is in the import path. Qt does not add
    // it by itself when the module is linked statically, and without it
    // loadFromModule fails and the app depends on a qt.conf pointing at the
    // source tree (which is what made the .deb unusable on other machines).
    engine.addImportPath(QStringLiteral(":/"));

#ifdef Q_OS_ANDROID
    // The QML modules live in the two RCC bundles registered above:
    // /qt/qml/* for Qt and /android_rcc_bundle/* for the app.
    engine.addImportPath(QStringLiteral(":/qt/qml"));
    engine.addImportPath(appRccRoot);
    // The module's qmldir sits at the root of the bundle while the types are
    // under qml/, so `import LotusTune` also resolves as a plain directory
    // import from here (what the fallback relies on).
    engine.addImportPath(appRccRoot + QStringLiteral("/qml"));
#endif

    // Language of the interface. It has to be installed before the QML is
    // loaded: the first frame is already painted in the chosen language.
    // "system" follows the locale; the rest of the codes come from the .qm
    // files in the build.
    Translator lang(&engine);
    // QA: `--lang=en` forces a language for one run (the screenshots of the
    // translated interface). It does not touch the saved choice.
    for (int i = 1; i < argc; ++i) {
        const QByteArray a(argv[i]);
        if (a.startsWith("--lang="))
            lang.setLanguage(QString::fromUtf8(a.mid(7)));
    }
    // QA: `--i18n-selftest` prints a few strings in the chosen language and
    // exits, to check the .qm files without opening a window.
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--i18n-selftest") == 0) {
            const auto say = [](const char *ctx, const char *src, int n) {
                printf("%s\n", qPrintable(QCoreApplication::translate(ctx, src, "", n)));
            };
            printf("language: %s (choice %s)\n", qPrintable(lang.current()),
                   qPrintable(lang.language()));
            printf("available: %s\n", qPrintable(lang.available().join(", ")));
            say("LibraryPage", "%n canción", 1);
            say("LibraryPage", "%n canción", 3);
            say("Main", "%n pista añadida a la cola", 2);
            say("Main", "Ajustes", -1);
            say("HomePage", "Buenos días", -1);
            say("SearchPage", "%1 resultados para «%2»", -1);
            return 0;
        }
    }
    engine.rootContext()->setContextProperty(QStringLiteral("lang"), &lang);

    // Live theme (iNiR/matugen palette + config.ini overrides).
    AppTheme theme;
    engine.rootContext()->setContextProperty(QStringLiteral("Sys"), &theme);

    // Platforms (YouTube Music / SoundCloud ready, Spotify / Tidal registered).
    // Their descriptions are shown to the user, so they are rebuilt when the
    // language changes.
    SourceManager sources;
    QObject::connect(&lang, &Translator::languageChanged,
                     &sources, &SourceManager::retranslate);
    engine.rootContext()->setContextProperty(QStringLiteral("sources"), &sources);

    // yt-dlp metadata + saved library.
    Catalog catalog(&sources);
    engine.rootContext()->setContextProperty(QStringLiteral("catalog"), &catalog);

    // QA/support: `--diagnostics` prints what the "Copiar diagnóstico" button
    // copies (version, phone, session, helper, lists) and exits. It is the
    // same text, so a report from a phone and one from the desktop compare.
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--diagnostics") == 0) {
            printf("%s\n", qPrintable(catalog.diagnostics()));
            return 0;
        }
    }

    // Persistent settings (theme ini + QSettings conf), see src/appconfig.cpp.
    AppConfig appcfg;
    engine.rootContext()->setContextProperty(QStringLiteral("appcfg"), &appcfg);

    // Audio cache cleanup: on Android every downloaded track leaves 4-8 MB
    // in cache/audio_<id>.bin and with no cap it eats the storage.
    AudioCache &audiocache = *AudioCache::instance();
    audiocache.prunePartials();
    audiocache.prune();
    engine.rootContext()->setContextProperty(QStringLiteral("audiocache"), &audiocache);

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
    // On a phone there is no yt-dlp: the downloader asks the player for the
    // direct audio URL (same resolution chain as playback).
    downloads.setPlayer(&player);
    engine.rootContext()->setContextProperty(QStringLiteral("downloads"), &downloads);

    // The new versions of the app are published in the repository: the
    // settings ask it for the last release.
    Updates updates;
    engine.rootContext()->setContextProperty(QStringLiteral("updates"), &updates);

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
    QObject *root = nullptr;
    if (component.isError()) {
        // Android: the in-binary QML plugin registration can stay
        // dormant on this Qt 6.6 runtime, so the module lookup fails
        // even with the module baked into the shared library. Fall
        // back to loading Main.qml straight by its resource URL; the
        // sibling components resolve through the implicit directory
        // import, exactly as they do on the file system.
        dumpErrors(component);
        qWarning() << "[fallback] module load failed, trying resource/asset paths";

#ifdef Q_OS_ANDROID
        // On Android, try loading from assets directly. The RCC bundle is
        // corrupt (header "qres" vs expected "QRsc"), so we load QML files
        // from the APK assets. The key paths are:
        // - ":/qt/qml/LotusTune/qml/Main.qml" - if Qt installation has it
        // - ":/android_rcc_bundle/qml/LotusTune/Main.qml" - from APK assets
        const QStringList mainQmlPaths = {
            QStringLiteral(":/qt/qml/LotusTune/qml/Main.qml"),
            appRccRoot + QStringLiteral("/qml/LotusTune/Main.qml"),
            QStringLiteral(":/assets/android_rcc_bundle/qml/LotusTune/Main.qml"),
        };
        bool loaded = false;
        for (const QString &path : mainQmlPaths) {
            if (QFile::exists(path)) {
                qInfo() << "[fallback] loading Main.qml from:" << path;
                // QFile treats ":/..." as a resource path, but QUrl does
                // not: without the qrc scheme it resolves relative to the
                // process CWD (/data/data/<pkg>/files on Android) and the
                // engine fails with "file to open is a directory".
                const QUrl url = path.startsWith(QStringLiteral(":/"))
                    ? QUrl(QStringLiteral("qrc") + path)
                    : QUrl(path);
                QQmlComponent direct(&engine,
                                     url,
                                     QQmlComponent::PreferSynchronous);
                if (!direct.isError()) {
                    root = direct.create();
                    loaded = true;
                    break;
                }
                dumpErrors(direct);
            }
        }
        if (!loaded) {
            // Final fallback: try file URL (assets may be extracted to app's storage)
            QString extractedPath = QStandardPaths::writableLocation(
                QStandardPaths::AppDataLocation) + QStringLiteral("/qml/Main.qml");
            if (QFile::exists(extractedPath)) {
                qInfo() << "[fallback] loading from extracted path:" << extractedPath;
                QQmlComponent direct(&engine,
                                     QUrl::fromLocalFile(extractedPath),
                                     QQmlComponent::PreferSynchronous);
                if (!direct.isError()) {
                    root = direct.create();
                    loaded = true;
                }
                dumpErrors(direct);
            }
        }
        if (!loaded) {
            return 1;
        }
#else
        QQmlComponent direct(&engine,
                             QUrl(QStringLiteral("qrc:/LotusTune/qml/Main.qml")),
                             QQmlComponent::PreferSynchronous);
        if (direct.isError()) {
            dumpErrors(direct);
            return 1;
        }
        root = direct.create();
#endif
    } else {
        // The module loaded: create the root object from it. Without this
        // branch the desktop build exited right away with a null root
        // (the fallback only ran when the module itself failed).
        root = component.create();
    }
    if (!root) {
        dumpErrors(component);
        return 1;
    }
    g_mainWindow = qobject_cast<QQuickWindow *>(root);
    if (g_mainWindow)
        g_mainWindow->installEventFilter(new MouseNavFilter(root, g_mainWindow));

    // Frame meter (only with LOTUS_FRAME_LOG=1): every block of 120 frames
    // prints the mean and the worst frame. It is there to compare before and
    // after a change without guessing. It never turns itself on (it does not
    // even leave the connect made).
    if (g_mainWindow && qEnvironmentVariableIntValue("LOTUS_FRAME_LOG") > 0) {
        auto *clock = new QElapsedTimer;
        clock->start();
        auto *st = new FrameStats;
        QObject::connect(g_mainWindow, &QQuickWindow::frameSwapped,
                         g_mainWindow, [clock, st]() {
            const qint64 now = clock->nsecsElapsed() / 1000;
            if (st->last > 0) {
                const double ms = double(now - st->last) / 1000.0;
                // A big gap is the app idle (it draws nothing): it does not count as a
                // slow frame.
                if (ms > 250.0) {
                    st->last = now;
                    return;
                }
                st->sum += ms;
                st->mx = qMax(st->mx, ms);
                ++st->frames;
                if (ms > 16.7) ++st->over16;
                if (ms > 33.0) ++st->over33;
                if (st->frames >= 120) {
                    qInfo("[frame] n=%d avg=%.1f max=%.1f >16.7=%d >33=%d",
                          st->frames, st->sum / st->frames, st->mx,
                          st->over16, st->over33);
                    st->sum = st->mx = 0;
                    st->frames = st->over16 = st->over33 = 0;
                }
            }
            st->last = now;
        });
        // Latencia dedo -> frame presentado: marca el instante del ultimo
        // evento de entrada y lo compara con el primer frame que se pinta
        // despues. Es lo que se nota al deslizar.
        auto *inClock = new QElapsedTimer;
        inClock->start();
        auto *lastInput = new qint64(0);
        auto *inSum = new double(0);
        auto *inMax = new double(0);
        auto *inN = new int(0);
        class InputWatch : public QObject
        {
        public:
            InputWatch(QElapsedTimer *c, qint64 *l) : m_c(c), m_last(l) {}
            bool eventFilter(QObject *, QEvent *e) override
            {
                switch (e->type()) {
                case QEvent::MouseButtonPress:
                case QEvent::MouseMove:
                case QEvent::TouchBegin:
                case QEvent::TouchUpdate:
                    *m_last = m_c->nsecsElapsed() / 1000;
                    break;
                default:
                    break;
                }
                return false;
            }
        private:
            QElapsedTimer *m_c;
            qint64 *m_last;
        };
        g_mainWindow->installEventFilter(new InputWatch(inClock, lastInput));
        QObject::connect(g_mainWindow, &QQuickWindow::frameSwapped,
                         g_mainWindow, [inClock, lastInput, inSum, inMax, inN]() {
            if (*lastInput <= 0)
                return;
            const double ms = double(inClock->nsecsElapsed() / 1000 - *lastInput) / 1000.0;
            *lastInput = 0;
            if (ms < 0 || ms > 400)
                return;
            *inSum += ms;
            *inMax = qMax(*inMax, ms);
            if (++(*inN) >= 60) {
                qInfo("[input] n=%d avg=%.1f max=%.1f ms", *inN, *inSum / *inN, *inMax);
                *inSum = *inMax = 0;
                *inN = 0;
            }
        });

        qInfo() << "[frame] graphics api ="
                << int(g_mainWindow->rendererInterface()->graphicsApi())
                << "loop =" << qgetenv("QSG_RENDER_LOOP");
    }

    qInfo() << "[main] Lotus Tune running";
    return app.exec();
}
