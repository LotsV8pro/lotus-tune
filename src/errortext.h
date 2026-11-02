#pragma once

#include <QCoreApplication>
#include <QString>

// Traduccion de los errores de red/reproduccion a algo que el usuario
// pueda entender y accionar. Los motores devuelven cosas como
// "error:http403", "Timed out" o "Failed to open ...": eso no se le puede
// enseñar a nadie tal cual.
namespace LotusText {

inline QString friendlyNetError(const QString &raw)
{
    const QString s = raw.toLower();
    if (s.isEmpty() || s.contains(QLatin1String("cancelled")))
        return QString();
    if (s.contains(QLatin1String("403")))
        return QCoreApplication::translate(
            "Player", "La red (o el operador) rechaza la descarga desde "
                      "YouTube (403). Prueba con otra wifi o con una VPN "
                      "movil.");
    if (s.contains(QLatin1String("404"))
        || s.contains(QLatin1String("unavailable"))
        || s.contains(QLatin1String("not available")))
        return QCoreApplication::translate(
            "Player", "Esa pista ya no esta disponible en YouTube.");
    if (s.contains(QLatin1String("429")) || s.contains(QLatin1String("rate")))
        return QCoreApplication::translate(
            "Player", "YouTube esta limitando las peticiones. "
                      "Espera un momento y reintenta.");
    if (s.contains(QLatin1String("timeout")) || s.contains(QLatin1String("timed out")))
        return QCoreApplication::translate(
            "Player", "La descarga ha tardado demasiado. Comprueba la conexion.");
    if (s.contains(QLatin1String("unknownhost"))
        || s.contains(QLatin1String("offline"))
        || s.contains(QLatin1String("network is unreachable"))
        || s.contains(QLatin1String("no route to host")))
        return QCoreApplication::translate(
            "Player", "Sin conexion a internet.");
    if (s.contains(QLatin1String("enospc")) || s.contains(QLatin1String("no space")))
        return QCoreApplication::translate(
            "Player", "No queda espacio en el almacenamiento.");
    if (s.contains(QLatin1String("cookiemismatch"))
        || s.contains(QLatin1String("authcheck"))
        || s.contains(QLatin1String("playlists that require authentication"))
        || s.contains(QLatin1String("cookie")))
        return QCoreApplication::translate(
            "Player", "YouTube no acepta la sesion guardada desde esta red. "
                      "Vuelve a iniciar sesion en Ajustes para recuperar tus "
                      "listas (la reproduccion funciona igual sin sesion).");
    if (s.contains(QLatin1String("sign in")) || s.contains(QLatin1String("login")))
        return QCoreApplication::translate(
            "Player", "La sesion ha caducado: vuelve a iniciar sesion en YouTube.");
    return raw;
}

} // namespace LotusText
