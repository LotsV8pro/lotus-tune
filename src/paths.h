#pragma once

// Where the app keeps its files.
//
// On the desktop the paths are the usual XDG ones (and they do not change,
// so the existing configuration and library are kept). On Windows they are
// the ones of the system (%APPDATA% and %LOCALAPPDATA%) and on Android
// they are the private directory of the app, because there is no HOME
// there (and the home of an app is erased when it is uninstalled).

#include <QDir>
#include <QStandardPaths>
#include <QString>

namespace AppPaths
{

// The configuration (the config.ini and the cookies).
inline QString configDir()
{
#ifdef Q_OS_ANDROID
    return QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
#elif defined(Q_OS_WIN)
    return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
           + QStringLiteral("/LotusTune");
#else
    return QDir::homePath() + QStringLiteral("/.config/lotus-tune");
#endif
}

// The state (the library, the published lyrics...).
inline QString stateDir()
{
#ifdef Q_OS_ANDROID
    return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
#elif defined(Q_OS_WIN)
    return QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
           + QStringLiteral("/LotusTune");
#else
    return QDir::homePath() + QStringLiteral("/.local/state/lotus-tune");
#endif
}

// The cache (the resolved stream URLs, the Musixmatch token...).
inline QString cacheDir()
{
#ifdef Q_OS_ANDROID
    return QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
#elif defined(Q_OS_WIN)
    return QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation)
           + QStringLiteral("/LotusTune/cache");
#else
    return QDir::homePath() + QStringLiteral("/.cache/lotus-tune");
#endif
}

// The downloaded music.
inline QString downloadDir()
{
#ifdef Q_OS_ANDROID
    return QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
#elif defined(Q_OS_WIN)
    return QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation)
           + QStringLiteral("/LotusTune");
#else
    return QDir::homePath() + QStringLiteral("/.local/share/lotus-tune/descargas");
#endif
}

// The file of the YouTube Music cookies.
inline QString cookiesFile()
{
    return configDir() + QStringLiteral("/cookies.txt");
}

// The file of the configuration.
inline QString configFile()
{
    return configDir() + QStringLiteral("/config.ini");
}

// The file of the library.
inline QString libraryFile()
{
    return stateDir() + QStringLiteral("/library.json");
}

// The Python interpreter that runs the helpers (the catalogue, the login
// and "mis listas"). On Linux it is "python3"; on Windows it is usually
// "python" (or "py -3"). It can be forced with LOTUS_TUNE_PYTHON.
inline QString pythonProgram()
{
    const QString forced = qEnvironmentVariable("LOTUS_TUNE_PYTHON");
    if (!forced.isEmpty())
        return forced;
    for (const QString &name : { QStringLiteral("python3"),
                                QStringLiteral("python"),
                                QStringLiteral("python3.12"),
                                QStringLiteral("python3.11") }) {
        if (!QStandardPaths::findExecutable(name).isEmpty())
            return name;
    }
    return QStringLiteral("python3");
}

// The arguments that go with it ("py -3" needs the flag).
inline QStringList pythonArgs(const QString &program)
{
    if (program.compare(QStringLiteral("py"), Qt::CaseInsensitive) == 0)
        return { QStringLiteral("-3") };
    return {};
}

} // namespace AppPaths
