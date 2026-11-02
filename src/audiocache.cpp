#include "audiocache.h"

#include "paths.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSettings>

#include <algorithm>

namespace {

constexpr int kDefaultLimitMB = 1024;
const char *kKeyLimit = "cacheLimitMB";

// audio_<videoId>.bin  /  audio_<videoId>.bin.part
QString idOfName(const QString &name)
{
    if (!name.startsWith(QLatin1String("audio_")))
        return QString();
    QString id = name.mid(6);
    if (id.endsWith(QLatin1String(".part")))
        id.chop(5);
    if (id.endsWith(QLatin1String(".bin")))
        id.chop(4);
    return id;
}

QString human(qint64 bytes)
{
    const double mb = double(bytes) / (1024.0 * 1024.0);
    if (mb < 1.0)
        return QStringLiteral("%1 KB").arg(qMax<qint64>(1, bytes / 1024));
    if (mb < 1000.0)
        return QStringLiteral("%1 MB").arg(qRound(mb));
    return QStringLiteral("%1 GB").arg(mb / 1024.0, 0, 'f', 1)
            .replace(QLatin1Char('.'), QLatin1Char(','));
}

} // namespace

AudioCache::AudioCache(QObject *parent)
    : QObject(parent)
{
}

AudioCache *AudioCache::instance()
{
    static AudioCache cache;
    return &cache;
}

QString AudioCache::dir() const
{
    return m_dir.isEmpty() ? AppPaths::cacheDir() : m_dir;
}

void AudioCache::setDirectoryForTest(const QString &dir)
{
    m_dir = dir;
    emit changed();
}

int AudioCache::limitMB() const
{
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    const int v = s.value(QLatin1String(kKeyLimit), -1).toInt();
    return v < 0 ? kDefaultLimitMB : v;
}

void AudioCache::setLimitMB(int mb)
{
    if (mb < 0)
        mb = 0;
    QSettings s(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
    s.setValue(QLatin1String(kKeyLimit), mb);
    emit changed();
}

QList<AudioCache::Entry> AudioCache::scan() const
{
    QList<Entry> list;
    const QDir d(dir());
    const QFileInfoList files =
        d.entryInfoList({QStringLiteral("audio_*.bin")}, QDir::Files, QDir::NoSort);
    list.reserve(files.size());
    for (const QFileInfo &fi : files) {
        Entry e;
        e.path = fi.absoluteFilePath();
        e.id = idOfName(fi.fileName());
        e.size = fi.size();
        e.mtime = fi.lastModified().toMSecsSinceEpoch();
        if (e.size > 0)
            list.append(e);
    }
    return list;
}

qint64 AudioCache::bytes() const
{
    qint64 total = 0;
    const QList<Entry> list = scan();
    for (const Entry &e : list)
        total += e.size;
    return total;
}

int AudioCache::files() const
{
    return int(scan().size());
}

QString AudioCache::summary() const
{
    const QString used = human(bytes());
    const int limit = limitMB();
    if (limit <= 0)
        return tr("%1 en uso (sin limite)").arg(used);
    return tr("%1 de %2").arg(used, human(qint64(limit) * 1024 * 1024));
}

int AudioCache::prune(const QString &protect)
{
    const int limit = limitMB();
    if (limit <= 0)
        return 0;

    QList<Entry> list = scan();
    qint64 total = 0;
    for (const Entry &e : list)
        total += e.size;

    const qint64 maxBytes = qint64(limit) * 1024 * 1024;
    if (total <= maxBytes)
        return 0;

    // Con margen: se deja al 90% del tope para no borrar en cada descarga.
    const qint64 target = maxBytes / 10 * 9;

    std::sort(list.begin(), list.end(), [](const Entry &a, const Entry &b) {
        return a.mtime < b.mtime;
    });

    int removed = 0;
    for (const Entry &e : list) {
        if (total <= target)
            break;
        if (!protect.isEmpty() && e.id == protect)
            continue;                     // la que suena ahora, intacta
        if (QFile::remove(e.path)) {
            total -= e.size;
            ++removed;
        }
    }
    if (removed > 0) {
        qInfo("[cache] liberados %d ficheros; quedan %s",
              removed, qPrintable(human(bytes())));
        emit changed();
    }
    return removed;
}

int AudioCache::clear()
{
    int removed = 0;
    const QDir d(dir());
    const QFileInfoList files = d.entryInfoList(
        {QStringLiteral("audio_*.bin"), QStringLiteral("audio_*.bin.part")},
        QDir::Files, QDir::NoSort);
    for (const QFileInfo &fi : files) {
        if (QFile::remove(fi.absoluteFilePath()))
            ++removed;
    }
    if (removed > 0)
        emit changed();
    return removed;
}

int AudioCache::prunePartials()
{
    int removed = 0;
    const QDir d(dir());
    const QFileInfoList files = d.entryInfoList(
        {QStringLiteral("audio_*.part"), QStringLiteral("audio_*.bin.part")},
        QDir::Files, QDir::NoSort);
    const QDateTime limit = QDateTime::currentDateTime().addSecs(-3600);
    for (const QFileInfo &fi : files) {
        if (fi.lastModified() < limit && QFile::remove(fi.absoluteFilePath()))
            ++removed;
    }
    if (removed > 0)
        emit changed();
    return removed;
}
