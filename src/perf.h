#pragma once

#include <QtGlobal>

// Environment tweaks to lighten the Qt Quick engine. It must be called BEFORE
// building QGuiApplication; the parent calls it from main.cpp.
//
// The software render backend is set by main.cpp (QT_QUICK_BACKEND=software
// + QSG_RENDER_LOOP=basic), which is what really trims the RAM of the Qt Quick
// heap. Here the noisy QML warning about bindings is only silenced
// removals, which in this app is emitted often and dirties the log without
// adding anything.
inline void applyPerfEnv()
{
    qputenv("QT_LOGGING_RULES", "qt.qml.binding.removal.info=false");
}