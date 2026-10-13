#pragma once

#include <QtGlobal>

// Ajustes de entorno para aligerar el motor Qt Quick. Debe invocarse ANTES de
// construir QGuiApplication; el padre lo llamará desde main.cpp.
//
// Deliberadamente NO se fija QT_QUICK_BACKEND=software: evita la GPU, pero
// dispara el uso de CPU al rasterizar todo por software, justo lo contrario
// de lo que buscamos al reducir RAM/consumo. Aquí solo silenciamos el aviso
// ruidoso de QML sobre bindings eliminados, que en esta app se emite a
// menudo y ensucia el log sin aportar nada.
inline void applyPerfEnv()
{
    qputenv("QT_LOGGING_RULES", "qt.qml.binding.removal.info=false");
}