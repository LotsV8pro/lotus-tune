#include "appconfig.h"
#include "catalog.h"
#include "discordrpc.h"
#include "downloads.h"
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

int main(int argc, char *argv[])
{
    qInstallMessageHandler(rawMessageHandler);

    // Render por software de Qt Quick: evita por completo el contexto OpenGL,
    // el driver de GPU (Mesa/llvmpipe/NVIDIA) y sus buffers de texturas/vertex.
    // Es la palanca que más recorta la RAM (heap de Qt Quick ~85 MB -> ~28 MB
    // en el perfil medido). Solo se fija si el usuario no lo ha forzado ya,
    // para poder volver a GL con QT_QUICK_BACKEND=rhi|software|... si hiciera
    // falta. Debe correr antes de QGuiApplication.
    if (qEnvironmentVariableIsEmpty("QT_QUICK_BACKEND"))
        qputenv("QT_QUICK_BACKEND", "software");
    if (qEnvironmentVariableIsEmpty("QSG_RENDER_LOOP"))
        qputenv("QSG_RENDER_LOOP", "basic");

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

    qInfo() << "[main] Lotus Tune running";
    return app.exec();
}
