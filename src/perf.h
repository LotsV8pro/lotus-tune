#pragma once

#include <QtGlobal>

// Ajustes de entorno para aligerar el motor Qt Quick. Debe invocarse ANTES de
// construir QGuiApplication; el padre lo llamará desde main.cpp.
//
// El backend de render por software lo fija main.cpp (QT_QUICK_BACKEND=software
// + QSG_RENDER_LOOP=basic), que es lo que recorta de verdad la RAM del heap de
// Qt Quick. Aquí solo se silencia el aviso ruidoso de QML sobre bindings
// eliminados, que en esta app se emite a menudo y ensucia el log sin aportar
// nada.
inline void applyPerfEnv()
{
    qputenv("QT_LOGGING_RULES", "qt.qml.binding.removal.info=false");
}