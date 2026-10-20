#include "appconfig.h"
#include "catalog.h"
#include "discordrpc.h"
#include "downloads.h"
#include "sfx.h"
#include "lyrics.h"
#include "mpris.h"
#include "perf.h"
#include "player.h"
#include "sources.h"
#include "theme.h"

#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QMouseEvent>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQuickWindow>
#include <QStandardPaths>
#include <QThread>

#include <csignal>
#include <unistd.h>

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
// Botones laterales del ratón (4 = atrás, 5 = adelante).
//
// Se filtran a nivel de ventana para que lleguen siempre, aunque el QML que
// haya debajo (listas, paneles) consuma el evento. Llama a funciones QML del
// objeto raíz ("mouseNavBack" / "mouseNavForward").
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
            const char *fn = nullptr;
            if (me->button() == Qt::BackButton)
                fn = "mouseNavBack";
            else if (me->button() == Qt::ForwardButton)
                fn = "mouseNavForward";
            if (fn && m_root) {
                QMetaObject::invokeMethod(m_root, fn);
                return true;   // consumido: que no lo reciba el QML
            }
        }
        return QObject::eventFilter(obj, ev);
    }

private:
    QObject *m_root = nullptr;
};

// ---------------------------------------------------------------------------
// Instancia única (QLocalServer + QLocalSocket)
//
// La segunda instancia no crea ventana: conecta al socket de la primera, le
// manda "raise" y sale con 0. Redes de seguridad:
//  - si el socket quedó huérfano (SIGKILL/pkill sin limpieza) se borra y se
//    sigue arrancando con normalidad;
//  - un fichero PID permite detectar instancias vivas, y si el PID está muerto
//    se limpia para no bloquear nunca el arranque.
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
    if (pid <= 0)
        return false;
    return ::kill(static_cast<pid_t>(pid), 0) == 0;
}

// El PID debe pertenecer de verdad a lotus-tune (evita bloquear el arranque
// por un PID reciclado por otro proceso).
static bool isLotusTunePid(qint64 pid)
{
    if (pid <= 0)
        return false;
    QFile f(QStringLiteral("/proc/%1/comm").arg(pid));
    if (!f.open(QIODevice::ReadOnly))
        return false;
    return QString::fromUtf8(f.readAll()).trimmed() == QLatin1String("lotus-tune");
}

static bool sendRaiseToServer()
{
    QLocalSocket sock;
    sock.connectToServer(appSocketPath());
    if (!sock.waitForConnected(250))
        return false;
    sock.write("raise\n");
    sock.flush();
    sock.waitForBytesWritten(250);
    // No se espera respuesta: la primera instancia puede estar aún cargando
    // QML (sin bucle de eventos); el dato queda en el buffer de su socket.
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

// Devuelve ExistingRaised si ya había una instancia viva y se le pidió que
// suba la ventana (el llamante debe salir sin crear ventana).
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

    // Con una instancia viva puede existir una ventana de arranque en la que
    // el servidor ya escucha: se reintenta brevemente antes de rendirse.
    const int tries = live ? 6 : 1;
    for (int i = 0; i < tries; ++i) {
        if (sendRaiseToServer())
            return SingleInstance::ExistingRaised;
        if (i + 1 < tries)
            QThread::msleep(150);
    }

    // Nadie escucha: limpiar restos (socket huérfano y, si procede, PID muerto).
    QFile::remove(sock);
    if (!live)
        QFile::remove(pidFile);

    auto *server = new QLocalServer;
    server->setSocketOptions(QLocalServer::UserAccessOption);
    if (!server->listen(sock)) {
        // Carrera: otro proceso pudo escuchar entre medias. Si responde, él
        // manda; si no, el socket es basura y se reintenta una vez.
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
// Ajustes que SOLO pueden aplicarse antes de que el cargador dinámico cargue el
// driver gráfico (libQt6Gui enlaza libGLX/libEGL). qputenv() dentro de main()
// llega tarde: el vendor ya se ha cargado. Así que, si faltan, nos
// re-ejecutamos UNA vez con ellos puestos. El re-exec conserva el PID, de modo
// que es transparente para systemd (una sola unidad) y para la instancia única.
//
//   · MANGOHUD=0 — MangoHud viene activado en el entorno de sesión y añade
//     ~23 MB de RSS a un reproductor que no dibuja overlays.
//   · __GLX_VENDOR_LIBRARY_NAME=mesa — libGLX carga el vendor de la GPU al
//     arrancar; con render por software no se usa GL, así que cargamos el de
//     Mesa (~18 MB) en lugar del de NVIDIA (~47 MB).
//
// Escape hatch: LOTUS_TUNE_NO_TWEAKS=1 desactiva ambos.
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
    // Sólo cuando el render es por software (el backend por defecto): si el
    // usuario fuerza un backend de GPU, se respeta su elección. La sesión ya
    // trae __GLX_VENDOR_LIBRARY_NAME=nvidia, así que hay que sobrescribirlo
    // (no basta con rellenarlo si falta).
    if (qEnvironmentVariableIsEmpty("QT_QUICK_BACKEND")
        && qgetenv("__GLX_VENDOR_LIBRARY_NAME") != "mesa") {
        qputenv("__GLX_VENDOR_LIBRARY_NAME", "mesa");
        changed = true;
    }
    if (!changed)
        return;

    qputenv("_LOTUS_TUNE_ENV_READY", "1");
    char exe[4096];
    const qint64 n = ::readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0)
        return;
    exe[n] = '\0';
    ::execv(exe, argv);
    // Si execv falla, seguimos con el proceso actual (sin los retoques).
}

int main(int argc, char *argv[])
{
    ensureFrugalExecEnv(argv);

    qInstallMessageHandler(rawMessageHandler);

    // Render por software de Qt Quick: evita por completo el contexto OpenGL,
    // el driver de GPU (Mesa/llvmpipe/NVIDIA) y sus buffers de texturas/vertex.
    // Es la palanca que más recorta la RAM (heap de Qt Quick ~85 MB -> ~28 MB
    // en el perfil medido). Solo se fija si el usuario no lo ha forzado ya,
    // para poder volver a GL con QT_QUICK_BACKEND=rhi|software|... si hiciera
    // falta. Debe correr antes de QGuiApplication.
    const bool softwareBackend = qEnvironmentVariableIsEmpty("QT_QUICK_BACKEND");
    if (softwareBackend)
        qputenv("QT_QUICK_BACKEND", "software");
    if (qEnvironmentVariableIsEmpty("QSG_RENDER_LOOP"))
        qputenv("QSG_RENDER_LOOP", "basic");

    // Este reproductor nunca decodifica vídeo: los sonidos de interfaz usan
    // QSoundEffect (solo audio). Desactivar el sondeo de aceleración por
    // hardware de Qt Multimedia evita que su backend ffmpeg cargue VA-API,
    // VDPAU, CUDA y el driver de vídeo de NVIDIA, y de paso que haga la
    // primera llamada a GL que arrastra el vendor completo del driver
    // (~40-65 MB de RSS). Debe correr antes de construir QGuiApplication.
    if (qEnvironmentVariableIsEmpty("QT_FFMPEG_DECODING_HW_DEVICE_TYPES"))
        qputenv("QT_FFMPEG_DECODING_HW_DEVICE_TYPES", "");
    if (qEnvironmentVariableIsEmpty("QT_FFMPEG_ENCODING_HW_DEVICE_TYPES"))
        qputenv("QT_FFMPEG_ENCODING_HW_DEVICE_TYPES", "");

    // Con render por software no se usa GL nunca. Si GLVND acaba cargando un
    // vendor (libGLX/libEGL son DT_NEEDED de libQt6Gui), que sea el de Mesa
    // (pequeño) y no el de NVIDIA (libnvidia-glcore + libnvidia-gpucomp,
    // ~47 MB). Sólo cuando elegimos software, para no degradar a quien fuerce
    // QT_QUICK_BACKEND=rhi a propósito.
    if (softwareBackend) {
        if (qEnvironmentVariableIsEmpty("__GLX_VENDOR_LIBRARY_NAME"))
            qputenv("__GLX_VENDOR_LIBRARY_NAME", "mesa");
        if (qEnvironmentVariableIsEmpty("LIBGL_ALWAYS_SOFTWARE"))
            qputenv("LIBGL_ALWAYS_SOFTWARE", "1");
    }

    // Entorno frugal de Qt Quick (debe correr antes de QGuiApplication).
    applyPerfEnv();

    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("lotus-tune"));
    app.setOrganizationName(QStringLiteral("lotus-tune"));
    app.setDesktopFileName(QStringLiteral("lotustune"));

    // Instancia única: la segunda se limita a pedir a la primera que suba la
    // ventana y sale con 0 sin crear nada.
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

    // Letras sincronizadas (LRCLIB) para la vista "Now Playing".
    Lyrics lyrics;
    engine.rootContext()->setContextProperty(QStringLiteral("lyrics"), &lyrics);
    // El motor alimenta el estado de letras publicado para los widgets de
    // inir (posición y play/pausa del reloj). Ver Lyrics::setEngine.
    lyrics.setEngine(&player);

    // Discord Rich Presence.
    DiscordRpc discord;
    engine.rootContext()->setContextProperty(QStringLiteral("discord"), &discord);

    // Controles multimedia del sistema (MPRIS2 sobre D-Bus). Se le inyecta el
    // motor mpv para publicar posición/duración reales.
    Mpris mpris(&player);
    engine.rootContext()->setContextProperty(QStringLiteral("mpris"), &mpris);
    // org.mpris.MediaPlayer2.Raise -> traer la ventana al frente.
    QObject::connect(&mpris, &Mpris::raiseRequested, [] { raiseMainWindow(); });
    // org.mpris.MediaPlayer2.Quit -> salir. Main.qml también lo maneja con
    // Qt.quit(), pero el cierre no debe depender de que la capa QML esté en
    // el punto exacto de su ciclo: aquí se garantiza (idempotente).
    QObject::connect(&mpris, &Mpris::quitRequested, &app, &QCoreApplication::quit);

    // Descargas de YouTube (yt-dlp) + biblioteca local.
    Downloads downloads;
    engine.rootContext()->setContextProperty(QStringLiteral("downloads"), &downloads);

    Sfx sfx;
    engine.rootContext()->setContextProperty(QStringLiteral("sfx"), &sfx);

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
