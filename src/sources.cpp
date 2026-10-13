#include "sources.h"

#include <QVariantMap>

SourceManager::SourceManager(QObject *parent)
    : QObject(parent)
{
    // Ready sources: stream via yt-dlp extraction (ad-free, no browser).
    m_list = {
        QVariantMap{
            {QStringLiteral("id"), QStringLiteral("ytm")},
            {QStringLiteral("name"), QStringLiteral("YouTube Music")},
            {QStringLiteral("status"), QStringLiteral("ready")},
            {QStringLiteral("note"), QStringLiteral("Extracción directa con yt-dlp: sin anuncios, sin navegador.")},
            {QStringLiteral("searchPrefix"), QStringLiteral("ytsearch15:")},
        },
        QVariantMap{
            {QStringLiteral("id"), QStringLiteral("soundcloud")},
            {QStringLiteral("name"), QStringLiteral("SoundCloud")},
            {QStringLiteral("status"), QStringLiteral("ready")},
            {QStringLiteral("note"), QStringLiteral("Búsqueda y playlists públicas de SoundCloud.")},
            {QStringLiteral("searchPrefix"), QStringLiteral("scsearch15:")},
        },
        // Locked sources: activated once the matching account/backend exists.
        QVariantMap{
            {QStringLiteral("id"), QStringLiteral("spotify")},
            {QStringLiteral("name"), QStringLiteral("Spotify")},
            {QStringLiteral("status"), QStringLiteral("locked")},
            {QStringLiteral("note"),
             QStringLiteral("Requiere cuenta Premium y un Client ID de "
                            "developer.spotify.com (backend librespot, pendiente).")},
            {QStringLiteral("searchPrefix"), QString()},
        },
        QVariantMap{
            {QStringLiteral("id"), QStringLiteral("tidal")},
            {QStringLiteral("name"), QStringLiteral("Tidal")},
            {QStringLiteral("status"), QStringLiteral("locked")},
            {QStringLiteral("note"),
             QStringLiteral("Requiere una cuenta Tidal y credenciales de la API "
                            "(pendiente).")},
            {QStringLiteral("searchPrefix"), QString()},
        },
    };
}

QVariantMap SourceManager::entry(const QString &id) const
{
    for (const QVariant &v : m_list) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("id")).toString() == id)
            return m;
    }
    return {};
}

bool SourceManager::isReady(const QString &id) const
{
    return entry(id).value(QStringLiteral("status")).toString() == QLatin1String("ready");
}

QString SourceManager::searchPrefix(const QString &id) const
{
    return entry(id).value(QStringLiteral("searchPrefix")).toString();
}

void SourceManager::setActiveId(const QString &id)
{
    if (m_active == id || entry(id).isEmpty())
        return;
    m_active = id;
    emit activeChanged();
}

void SourceManager::select(const QString &id)
{
    setActiveId(id);
}
