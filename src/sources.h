#pragma once

#include <QObject>
#include <QVariantList>

// Platform registry ("sources").
//
// Every platform is described by { id, name, status, note, searchPrefix }:
//   status "ready"   – streams today through the shared mpv + yt-dlp engine
//                      (searchPrefix is passed to yt-dlp, e.g. "ytsearch15:").
//   status "locked"  – registered with its requirements (Premium account,
//                      Client ID, credentials...) so the UI can explain what
//                      is needed; a real backend plugs in later behind the
//                      same list without UI changes.
class SourceManager : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QVariantList list READ list NOTIFY listChanged)
    Q_PROPERTY(QString activeId READ activeId WRITE setActiveId NOTIFY activeChanged)

public:
    explicit SourceManager(QObject *parent = nullptr);

    QVariantList list() const { return m_list; }
    QString activeId() const { return m_active; }
    void setActiveId(const QString &id);
    Q_INVOKABLE void select(const QString &id);

    QString searchPrefix(const QString &id) const;
    QVariantMap entry(const QString &id) const;
    bool isReady(const QString &id) const;

signals:
    void listChanged();
    void activeChanged();

private:
    QVariantList m_list;
    QString m_active = QStringLiteral("ytm");
};
