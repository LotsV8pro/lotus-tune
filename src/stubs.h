#pragma once

// Stubs of the desktop-only services, used on Android.
//
// On a phone there is no D-Bus (so no MPRIS) and no Discord rich presence
// (it needs a local socket). The QML calls those objects unconditionally,
// so instead of changing the QML the objects are replaced by these
// do-nothing ones with the same API.

#include <QObject>
#include <QString>
#include <QUrl>

// ---- MPRIS (system media controls) ---------------------------------------
class MprisStub : public QObject
{
    Q_OBJECT
    // The properties the QML reads.
    Q_PROPERTY(bool connected READ connected NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)

public:
    explicit MprisStub(QObject *parent = nullptr) : QObject(parent) {}

    bool connected() const { return false; }
    QString error() const { return QString(); }

    Q_INVOKABLE void setShuffle(bool) {}
    Q_INVOKABLE void setLoopStatus(const QString &) {}
    Q_INVOKABLE void updateMetadata(const QString &, const QString &,
                                    const QString &, double, const QString &) {}
    Q_INVOKABLE void updatePlayback(bool, double, bool) {}
    Q_INVOKABLE void updateVolume(int) {}

signals:
    void changed();
    // Kept so the connections in main.cpp do not need to be guarded.
    void raiseRequested();
    void quitRequested();
};

// ---- Discord rich presence ----------------------------------------------
class DiscordStub : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool connected READ connected NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)

public:
    explicit DiscordStub(QObject *parent = nullptr) : QObject(parent) {}

    bool connected() const { return false; }
    QString error() const { return QString(); }

    Q_INVOKABLE void configure(const QString &, const QString &) {}
    Q_INVOKABLE void clear() {}
    Q_INVOKABLE void setActivity(const QString &, const QString &,
                                 const QString &, const QString &,
                                 double, double, bool) {}

signals:
    void changed();
};
