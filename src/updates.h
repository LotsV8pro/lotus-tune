#pragma once

#include <QObject>
#include <QString>

// Looks for a new version of the app in the repository.
//
// The releases are published by the CI, so the app asks GitHub for the
// last one and compares its version with the one that is running. The
// user is told when there is something new and can open the download
// page from there.
class Updates : public QObject
{
    Q_OBJECT
    // Is there a version newer than the one that is running?
    Q_PROPERTY(bool available READ available NOTIFY changed)
    // The version that is published (empty when there is none).
    Q_PROPERTY(QString latestVersion READ latestVersion NOTIFY changed)
    // Where the new version is downloaded.
    Q_PROPERTY(QString url READ url NOTIFY changed)
    // What the release says.
    Q_PROPERTY(QString notes READ notes NOTIFY changed)
    // The last error (empty when everything went well).
    Q_PROPERTY(QString error READ error NOTIFY changed)
    // The version that is running.
    Q_PROPERTY(QString currentVersion READ currentVersion CONSTANT)

public:
    explicit Updates(QObject *parent = nullptr);

    bool available() const { return m_available; }
    QString latestVersion() const { return m_latest; }
    QString url() const { return m_url; }
    QString notes() const { return m_notes; }
    QString error() const { return m_error; }
    QString currentVersion() const;

    // Asks the repository for the last release.
    Q_INVOKABLE void check();
    // Opens the page of the new version.
    Q_INVOKABLE void openDownload();

signals:
    void changed();

private:
    bool m_available = false;
    QString m_latest;
    QString m_url;
    QString m_notes;
    QString m_error;
};
