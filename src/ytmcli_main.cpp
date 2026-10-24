// Lotus Tune -- native InnerTube client ("ytmcli").
//
// On Android there is no Python and no yt-dlp, so the catalogue queries that
// Catalog runs through QProcess (python3 ytm_api.py / yt-dlp -J) would fail
// there. This helper is a standalone native binary implementing the same
// protocol:
//
//   * "python mode": argv contains a known command (library, search, ...)
//     preceded by whatever path argument the app passes (the .py placeholder);
//     it prints the exact same JSON shapes as tools/ytm_api.py and exits 0
//     or 2.
//   * "yt-dlp mode": argv is the yt-dlp flag set that Catalog uses
//     (-J --no-warnings ... --flat-playlist [--cookies file] target); it
//     prints the flat-playlist JSON shape ({"entries":[...]}) for YouTube
//     lists, radios, single videos and ytsearch prefixes.
//
// Auth, endpoints, parse rules and result shapes mirror tools/ytm_api.py, so
// the app consumes both with the same code.

#include <QCryptographicHash>
#include <QDateTime>
#include <QEventLoop>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSet>
#include <QCoreApplication>
#include <QStringList>
#include <QTimer>
#include <algorithm>
#include <cstdio>
#include <functional>
#include <vector>

using Json = QJsonValue;

namespace {

// ---------------------------------------------------------------- constants

const QString kApiKey = QStringLiteral("AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8");
const QString kBaseUrl = QStringLiteral("https://music.youtube.com/youtubei/v1/");
const QString kOrigin = QStringLiteral("https://music.youtube.com");
const QString kClientVersion = QStringLiteral("1.20240101.01.00");
const QString kAnonUa = QStringLiteral(
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36");

const QStringList kLibraryIds{
    QStringLiteral("FEmusic_liked_playlists"),
    QStringLiteral("FEmusic_library_landing"),
    QStringLiteral("FEmusic_library_privately_owned_playlists"),
};

const QStringList kSapisidNames{
    QStringLiteral("SAPISID"),
    QStringLiteral("__Secure-3PAPISID"),
    QStringLiteral("__Secure-1PAPISID"),
};

// browseId prefixes that on an artist page are NOT a disc of their own.
const QStringList kNotAnAlbum{
    QStringLiteral("VL"), QStringLiteral("UC"), QStringLiteral("MPC"),
    QStringLiteral("RD"), QStringLiteral("LA"), QStringLiteral("FE"),
    QStringLiteral("SP"), QStringLiteral("MPU"), QStringLiteral("LP"),
    QStringLiteral("VP"), QStringLiteral("SE"),
};

const QRegularExpression kDurRe(
    QStringLiteral("^(?:(\\d+):)?(\\d+):(\\d{2})"));
const QRegularExpression kYearRe(
    QStringLiteral("\\b(1[89]\\d{2}|20\\d{2})\\b"));
const QRegularExpression kCountRe(
    QStringLiteral("(\\d[\\d.,]*)\\s+(?:pistas|songs|tracks|videos|canci)"));
const QRegularExpression kParensRe(
    QStringLiteral("[\\(\\[].*?[\\)\\]]"));
const QRegularExpression kJunkRe(
    QStringLiteral("\\b(official|lyrics?|lyric|video|audio|hd|hq|"
                   "remaster(ed)?|4k|1080p|720p)\\b"));
const QRegularExpression kSpacesRe(QStringLiteral("\\s+"));
const QRegularExpression kSepArtistRe(QStringLiteral("\\s*[·,]\\s*"));
const QRegularExpression kTrimStartRe(
    QStringLiteral("^[ -\u2013\u2014:.]+"));
const QRegularExpression kTrimEndRe(
    QStringLiteral("[ -\u2013\u2014:.]+$"));
const QRegularExpression kListIdRe(
    QStringLiteral("list=([A-Za-z0-9_-]+)"));
const QRegularExpression kWatchIdRe(
    QStringLiteral("[?&]v=([A-Za-z0-9_-]+)"));
const QRegularExpression kSearchPrefixRe(
    QStringLiteral("^(?:ytsearch|ytmsearch)(\\d+)?:"));

// QJsonArray has no mid(): slice helper.
QJsonArray jsonMid(const QJsonArray &src, int start, int count)
{
    QJsonArray out;
    const int size = src.size();
    for (int i = start; i < size && (count < 0 || i - start < count); ++i)
        out.append(src.at(i));
    return out;
}

// python-like error: message to stderr + exit code 2.
void die(const QString &msg)
{
    // No <iostream> on Android: libc++'s locale facet machinery throws
    // std::bad_cast inside the spawned child; writing to stdout via
    // fwrite avoids the locale machinery completely.
    std::fprintf(stderr, "ytm_api: %s\n", qPrintable(msg));
    std::fflush(stderr);
    std::exit(2);
}

QString qopt(const QJsonObject &o, const QString &key)
{
    const Json v = o.value(key);
    if (v.isObject()) {
        const QJsonArray runs = v.toObject().value(QLatin1String("runs"))
                                    .toArray();
        if (!runs.isEmpty())
            return runs.first().toObject()
                .value(QLatin1String("text")).toString().trimmed();
        return v.toObject().value(QLatin1String("simpleText")).toString()
            .trimmed();
    }
    return QString();
}

// QJsonArray entries are not swappable (QJsonValueRef): sort through a
// vector of plain objects.
QJsonArray sortJsonObjects(const QJsonArray &src,
                           const std::function<bool(const QJsonObject &,
                                                    const QJsonObject &)>
                               &cmp)
{
    std::vector<QJsonObject> rows;
    rows.reserve(src.size());
    for (const auto &v : src)
        rows.push_back(v.toObject());
    std::stable_sort(rows.begin(), rows.end(), cmp);
    QJsonArray out;
    for (const auto &row : rows)
        out.append(row);
    return out;
}

// ------------------------------------------------------------------ cookies

QList<QPair<QString, QString>> g_pairs;
QString g_sapisid;
QString g_cookiePath;   // --cookies / env fallback / default

// Loads cookies.txt (Netscape). Returns false (with the python message) when
// unusable; never exits itself.
bool loadCookies(QString *errOut = nullptr)
{
    if (!g_pairs.isEmpty())
        return true;

    QString file;
    if (!g_cookiePath.isEmpty())
        file = g_cookiePath;
    else {
        // ytm_api.py reads ~/.config/lotus-tune/cookies.txt; on Android the
        // app exports the real path through the environment.
        const QString env = qEnvironmentVariable("LOTUS_COOKIES");
        if (!env.isEmpty())
            file = env;
        else if (qEnvironmentVariableIsSet("HOME"))
            file = qEnvironmentVariable("HOME")
                   + QStringLiteral("/.config/lotus-tune/cookies.txt");
    }
    if (file.isEmpty()) {
        if (errOut)
            *errOut = QStringLiteral("no se pudo leer cookies.txt: sin ruta");
        return false;
    }

    QFile f(file);
    if (!f.open(QIODevice::ReadOnly)) {
        if (errOut)
            *errOut = QStringLiteral("no se pudo leer cookies.txt: %1")
                          .arg(f.errorString());
        return false;
    }

    const QStringList lines =
        QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'));
    for (const QString &line : lines) {
        QString l = line;
        l.remove(QLatin1Char('\r'));
        if (l.trimmed().isEmpty() || l.startsWith(QLatin1Char('#')))
            continue;
        const QStringList cols =
            l.split(QLatin1Char('\t'), Qt::KeepEmptyParts);
        if (cols.size() < 7)
            continue;
        QString domain = cols.at(0);
        while (domain.startsWith(QLatin1Char('.')))
            domain.remove(0, 1);
        domain = domain.toLower();
        // the google.com cookies break the SAPISID signature (logged_in=0):
        // only youtube.com (+ subdomains) like python.
        if (!(domain == QLatin1String("youtube.com")
              || domain.endsWith(QLatin1String(".youtube.com"))))
            continue;
        g_pairs.append({cols.at(5), cols.at(6)});
    }
    if (g_pairs.isEmpty()) {
        if (errOut)
            *errOut =
                QStringLiteral("cookies.txt no contiene cookies de YouTube");
        return false;
    }

    for (const QString &want : kSapisidNames) {
        if (!g_sapisid.isEmpty())
            break;
        for (const auto &p : g_pairs) {
            if (p.first == want && !p.second.isEmpty()) {
                g_sapisid = p.second;
                break;
            }
        }
    }
    if (g_sapisid.isEmpty()) {
        if (errOut)
            *errOut = QStringLiteral("cookies.txt no contiene SAPISID");
        return false;
    }
    return true;
}

// Cookie auth header (SAPISIDHASH sha1(ts + sap + origin)).
QString authorization()
{
    const QString stamp = QString::number(QDateTime::currentSecsSinceEpoch());
    const QByteArray digest = QCryptographicHash::hash(
        (stamp + QLatin1Char(' ') + g_sapisid + QLatin1Char(' ') + kOrigin)
            .toUtf8(),
        QCryptographicHash::Sha1).toHex();
    return QStringLiteral("SAPISIDHASH %1_%2").arg(
        stamp, QString::fromLatin1(digest));
}

// ---------------------------------------------------------------------- net

QNetworkAccessManager *nam()
{
    // Heap-allocated: a static QObject VALUE in an executable needs a copy
    // relocation against the protected typeinfo of Qt → link error.
    static QNetworkAccessManager *instance = nullptr;
    if (!instance)
        instance = new QNetworkAccessManager;
    return instance;
}

struct NetResult {
    bool ok = false;
    QJsonObject obj;
    QString err;
};

#ifdef Q_OS_ANDROID
// Synchronous HTTPS POST straight on OpenSSL (the libssl.so and
// libcrypto.so that travel packaged next to the Qt libs from the APK) :
// the Android QCoreApplication requires a live JVM (QJniEnvironment
// dereferences null inside its constructor when the helper runs spawned)
// so in the helper there is NO Qt event loop and QtNetwork is out of
// reach. The root certificates come from the system store (conscrypt
// apex on newer Android; /system on older ones).
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>
#include <netdb.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <dirent.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <cstring>
#endif

#ifdef Q_OS_ANDROID
static bool g_sslDbg = false;
static int ltm_verify_cb(int ok, X509_STORE_CTX *ctx)
{
    if (!ok && g_sslDbg) {
        X509 *err_cert = X509_STORE_CTX_get_current_cert(ctx);
        char name[256] = {0};
        X509_NAME_oneline(X509_get_subject_name(err_cert), name, 255);
        std::fprintf(stderr,
                     "[ltm] verify depth %d err %d %s : %s\n",
                     X509_STORE_CTX_get_error_depth(ctx),
                     X509_STORE_CTX_get_error(ctx),
                     X509_verify_cert_error_string(
                         X509_STORE_CTX_get_error(ctx)),
                     name);
        std::fflush(stderr);
    }
    return ok;
}

static QByteArray dechunk(const QByteArray &in)
{
    QByteArray out;
    int i = 0;
    while (i < in.size()) {
        const int nl = in.indexOf("\r\n", i);
        if (nl < 0)
            break;
        const int len = in.mid(i, nl - i).trimmed().toInt(nullptr, 16);
        if (len <= 0)
            break;
        out += in.mid(nl + 2, len);
        i = nl + 2 + len + 2;
    }
    return out;
}

// Synchronous HTTPS POST straight on OpenSSL (the libssl.so and
// libcrypto.so that travel packaged next to the Qt libs from the APK) :
// the Android QCoreApplication requires a live JVM (QJniEnvironment
// disintegrate a null pointer inside of its constructor in a child spawned
// process) so in the helper there is NO Qt event loop and QtNetwork is
// unreachable. The certificated roots are loaded from the system
// store (conscrypt apex on Android >= 14; /system path on the older).
static QByteArray httpsPost(const QUrl &url,
                            const QList<QPair<QByteArray, QByteArray>>
                                &headers,
                            const QByteArray &payload, int *statusOut)
{
    // Optional trace (standalone diagnosis): LTM_DEBUG=1 prints every
    // transport step and the OpenSSL error to stderr.
    const bool dbg = qEnvironmentVariableIsSet("LTM_DEBUG");
    const auto log = [dbg](const char *msg) -> void {
        if (dbg) {
            std::fprintf(stderr, "[ltm] %s\n", msg);
            if (unsigned long e = ERR_get_error())
                std::fprintf(stderr, "[ltm] sslerr: %s\n",
                             ERR_error_string(e, nullptr));
        }
    };
    const QByteArray rawHost = url.host().toLocal8Bit();
    const int port = url.port(443);
    const QByteArray portB = QByteArray::number(port);

    // The Android helper does NOT resolve names: the app child is not
    // bound to a network, so netd answers NODATA for it (the parent
    // injects the numeric addresses through LTM_DNS_IPS, resolved from
    // Java). Numeric candidates first, plain getaddrinfo as a last
    // resort (desktop).
    struct Candid { sockaddr_storage ss; socklen_t len; int fam; };
    std::vector<Candid> addrs;
    const auto collect = [&](addrinfo *chain) {
        for (addrinfo *ai = chain; ai; ai = ai->ai_next) {
            if (!ai->ai_addr)
                continue;
            Candid c;
            memcpy(&c.ss, ai->ai_addr, qMin(sizeof c.ss,
                                            sizeof(sockaddr_storage)));
            c.len = socklen_t(ai->ai_addrlen);
            c.fam = ai->ai_family;
            if (c.len <= sizeof c.ss)
                addrs.push_back(c);
        }
        freeaddrinfo(chain);
    };
    const QString rawIps = qEnvironmentVariable("LTM_DNS_IPS");
    if (!rawIps.isEmpty()) {
        for (const QString &ip : rawIps.split(QLatin1Char(','),
                                              Qt::SkipEmptyParts)) {
            addrinfo hintsN;
            memset(&hintsN, 0, sizeof hintsN);
            hintsN.ai_family = AF_UNSPEC;
            hintsN.ai_socktype = SOCK_STREAM;
            hintsN.ai_flags = AI_NUMERICHOST;
            addrinfo *r = nullptr;
            const QByteArray ipB = ip.trimmed().toLocal8Bit();
            if (!ipB.isEmpty()
                && getaddrinfo(ipB.constData(), portB.constData(),
                               &hintsN, &r) == 0)
                collect(r);
        }
        if (dbg)
            log(QByteArrayLiteral("dns from LTM_DNS_IPS"));
    } else {
        addrinfo hints;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        // IPv4 first: some networks answer NODATA for the combined
        // A+AAAA query netd launches for AF_UNSPEC.
        int gai = EAI_NONAME;
        for (const int family : {AF_INET, AF_UNSPEC}) {
            hints.ai_family = family;
            addrinfo *chain = nullptr;
            gai = getaddrinfo(rawHost.constData(), portB.constData(),
                              &hints, &chain);
            if (gai == 0) {
                collect(chain);
                break;
            }
        }
        if (gai != 0 && dbg) {
            std::fprintf(stderr, "[ltm] dns fail: %s\n",
                         gai_strerror(gai));
            std::fflush(stderr);
        }
    }
    if (addrs.empty())
        return QByteArray();
    int fd = -1;
    if (dbg)
        log(QByteArrayLiteral("candidates ")
            + QByteArray::number(int(addrs.size())));
    for (const Candid &c : addrs) {
        fd = ::socket(c.fam, SOCK_STREAM, 0);
        if (fd < 0)
            continue;
        {
            const int nb = fcntl(fd, F_GETFL, 0);
            if (dbg)
                std::fprintf(stderr,
                             "[ltm] try fam=%d len=%d flags=0x%x\n",
                             c.fam, int(c.len), nb);
        }
        const timeval tv{40, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        const int rc = ::connect(fd,
                                 reinterpret_cast<const sockaddr *>(&c.ss),
                                 c.len);
        if (rc == 0)
            break;
        if (dbg)
            std::fprintf(stderr, "[ltm] connect rc=%d errno=%d\n", rc,
                         errno);
        ::close(fd);
        fd = -1;
    }
    if (fd < 0) {
        if (dbg) {
            std::fprintf(stderr, "[ltm] tcp fail errno=%d\n", errno);
            std::fflush(stderr);
        }
        return QByteArray();
    }
    log("tcp connected");

    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
        ::close(fd);
        return QByteArray();
    }
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    g_sslDbg = dbg;
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, ltm_verify_cb);
    X509_VERIFY_PARAM *param = SSL_CTX_get0_param(ctx);
    X509_VERIFY_PARAM_set1_host(param, rawHost.constData(), 0);
    // System CA store (peer verification like the parent app does).
    // Route order matters: the explicit load paths first (the conscrypt
    // apex on Android >= 14, then the legacy /system path), and the
    // classic SSL_CERT_DIR / set_default_verify_paths route as a fallback.
    X509_STORE *store = SSL_CTX_get_cert_store(ctx);
    int caRoute = 0;
    // The hashed-dir lookup loads nothing in the spawned app child (the
    // fopen of the certs works, so this helper reads and loads each file
    // of the system store explicitly). Conscrypt apex first (Android
    // >= 14), the legacy /system path on older ones, and the
    // "default-verify-paths" route as the last resort.
    const auto loadDir = [&store](const char *dir) -> int {
        DIR *d = ::opendir(dir);
        if (!d)
            return 0;
        int loaded = 0;
        for (dirent *e = ::readdir(d); e; e = ::readdir(d)) {
            if (e->d_type == DT_DIR)
                continue;
            const std::string name = std::string(dir) + "/" + e->d_name;
            if (X509_STORE_load_file(store, name.c_str()) == 1)
                loaded++;
        }
        ::closedir(d);
        return loaded;
    };
    int loadedRoots = loadDir("/apex/com.android.conscrypt/cacerts");
    if (loadedRoots > 0)
        caRoute = 2;
    else if ((loadedRoots = loadDir("/system/etc/security/cacerts")) > 0)
        caRoute = 3;
    else {
        static const bool sslDirSet = []() -> bool {
            return ::setenv("SSL_CERT_DIR",
                            "/apex/com.android.conscrypt/cacerts", 1) == 0;
        }();
        if (sslDirSet && SSL_CTX_set_default_verify_paths(ctx))
            caRoute = 1;
    }
    if (dbg) {
        std::fprintf(stderr, "[ltm] ca route %d loaded %d\n", caRoute,
                     loadedRoots);
        std::fflush(stderr);
    }

    SSL *ssl = SSL_new(ctx);
    SSL_set_tlsext_host_name(ssl, rawHost.constData());
    SSL_set_fd(ssl, fd);
    SSL_set_mode(ssl, SSL_MODE_AUTO_RETRY);

    QByteArray out;
    int status = 0;
    if (SSL_connect(ssl) == 1) {
        log("tls handshake ok");
        QByteArray req;
        req += "POST " + url.path(QUrl::FullyEncoded).toLocal8Bit()
               + "?" + url.query(QUrl::FullyEncoded).toLocal8Bit()
               + " HTTP/1.1\r\n"
               "Host: " + rawHost + "\r\n"
               "Connection: close\r\n"
               "Accept-Encoding: identity\r\n";
        for (const auto &h : headers) {
            req += h.first + ": " + h.second + "\r\n";
        }
        req += "Content-Length: "
               + QByteArray::number(payload.size()) + "\r\n\r\n";
        req += payload;
        int sent = 0;
        while (sent < req.size()) {
            const int w = SSL_write(ssl, req.constData() + sent,
                                    req.size() - sent);
            if (w <= 0)
                break;
            sent += w;
        }
        if (sent == req.size()) {
            log("request sent");
            QByteArray raw;
            char buf[8192];
            while (raw.size() < (1 << 21)) {
                const int r = SSL_read(ssl, buf, sizeof buf);
                if (r <= 0)
                    break;
                raw.append(buf, r);
            }
            log("response read");
            const int headEnd = raw.indexOf("\r\n\r\n");
            if (headEnd >= 0) {
                const QByteArray head = raw.left(headEnd);
                const int sp1 = head.indexOf(' ');
                const int sp2 = head.indexOf(' ', sp1 + 1);
                if (sp1 >= 0 && sp2 >= 0)
                    status = head.mid(sp1 + 1, sp2 - sp1 - 1).toInt();
                QByteArray body = raw.mid(headEnd + 4);
                if (head.toLower().contains(
                        "transfer-encoding: chunked"))
                    body = dechunk(body);
                out = body;
            }
        } else {
            log("write incomplete");
        }
    } else {
        log("tls handshake failed");
        const long verr = SSL_get_verify_result(ssl);
        if (dbg) {
            std::fprintf(stderr, "[ltm] verify result: %ld %s\n", verr,
                         X509_verify_cert_error_string(verr));
            STACK_OF(X509) *chain = SSL_get_peer_cert_chain(ssl);
            std::fprintf(stderr, "[ltm] peer chain depth %d\n",
                         chain ? sk_X509_num(chain) : -1);
            std::fprintf(stderr, "[ltm] store objs after verify %d\n",
                         sk_X509_OBJECT_num(
                             X509_STORE_get0_objects(store)));
            {
                    }
            std::fflush(stderr);
        }
    }
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    ::close(fd);
    *statusOut = status;
    return out;
}
#endif

NetResult postJson(const QString &endpoint, const QJsonObject &bodyIn)
{
    // WEB_REMIX answers the same anonymously (browser UA); with cookies it
    // signs with them (SAPISIDHASH) like python's post_json does when they
    // are readable.
    const bool auth = !g_pairs.isEmpty() && !g_sapisid.isEmpty();

    QJsonObject client{
        {QStringLiteral("clientName"), QStringLiteral("WEB_REMIX")},
        {QStringLiteral("clientVersion"), kClientVersion},
        {QStringLiteral("hl"), QStringLiteral("es")},
        {QStringLiteral("gl"), QStringLiteral("ES")},
    };
    QJsonObject body = bodyIn;
    body.insert(QStringLiteral("context"),
                QJsonObject{{QStringLiteral("client"), client}});

    QNetworkRequest req(
        QUrl(kBaseUrl + endpoint
             + QStringLiteral("?key=%1&prettyPrint=false").arg(kApiKey)));
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::NoLessSafeRedirectPolicy);
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    req.setRawHeader("X-Goog-Api-Format-Version", "1");
    req.setRawHeader("Origin", kOrigin.toUtf8());
    req.setRawHeader("Referer", (kOrigin + QStringLiteral("/")).toUtf8());
    if (auth) {
        req.setRawHeader("Authorization", authorization().toUtf8());
        QStringList cookie;
        for (const auto &p : g_pairs)
            cookie << p.first + QLatin1Char('=') + p.second;
        req.setRawHeader("Cookie",
                         cookie.join(QLatin1String("; ")).toUtf8());
    } else {
        req.setRawHeader("User-Agent", kAnonUa.toUtf8());
    }

    NetResult out;
#ifndef Q_OS_ANDROID
    QNetworkReply *reply =
        nam()->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    QEventLoop loop;
    QObject::connect(reply, &QNetworkReply::finished, &loop,
                     &QEventLoop::quit);
    QTimer::singleShot(30000, &loop, &QEventLoop::quit);
    loop.exec();

    const int status = reply->attribute(
        QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status >= 300)
        out.err = QStringLiteral("HTTP %1 en %2").arg(status).arg(endpoint);
    else if (reply->error() != QNetworkReply::NoError)
        out.err = QStringLiteral("sin conexión: %1").arg(reply->errorString());
    else {
        const QByteArray raw = reply->readAll();
        const QJsonDocument doc = QJsonDocument::fromJson(raw);
        if (!doc.isObject())
            out.err = QStringLiteral("respuesta ilegible de %1").arg(endpoint);
        else {
            out.ok = true;
            out.obj = doc.object();
        }
    }
    reply->deleteLater();
#else
    // No event loop here: transport synchronously via OpenSSL.
    QList<QPair<QByteArray, QByteArray>> headers;
    headers << qMakePair(QByteArrayLiteral("Content-Type"),
                         QByteArrayLiteral("application/json"));
    headers << qMakePair(QByteArrayLiteral("X-Goog-Api-Format-Version"),
                         QByteArrayLiteral("1"));
    headers << qMakePair(QByteArrayLiteral("Origin"),
                         kOrigin.toUtf8());
    headers << qMakePair(QByteArrayLiteral("Referer"),
                         (kOrigin + QStringLiteral("/")).toUtf8());
    if (auth) {
        headers << qMakePair(QByteArrayLiteral("Authorization"),
                             authorization().toUtf8());
        QStringList cookie;
        for (const auto &p : g_pairs)
            cookie << p.first + QLatin1Char('=') + p.second;
        headers << qMakePair(QByteArrayLiteral("Cookie"),
                             cookie.join(QLatin1String("; ")).toUtf8());
    } else {
        headers << qMakePair(QByteArrayLiteral("User-Agent"),
                             kAnonUa.toUtf8());
    }
    const QByteArray payload =
        QJsonDocument(body).toJson(QJsonDocument::Compact);
    // The netd resolver occasionally answers NODATA on the first try;
    // repeat the whole request up to 3 times before giving up.
    int status = 0;
    QByteArray raw;
    for (int attempt = 0; attempt < 3; ++attempt) {
        raw = httpsPost(req.url(), headers, payload, &status);
        if (!raw.isEmpty() && status > 0)
            break;
        ::usleep(400000);
    }
    const QJsonDocument doc = QJsonDocument::fromJson(raw);
    if (status >= 300)
        out.err = QStringLiteral("HTTP %1 en %2").arg(status).arg(endpoint);
    else if (raw.isEmpty() || !doc.isObject())
        out.err = QStringLiteral("sin conexión: %1").arg(endpoint);
    else {
        out.ok = true;
        out.obj = doc.object();
    }
#endif
    return out;
}

NetResult browseJson(const QString &browseId)
{
    return postJson(QStringLiteral("browse"),
                    QJsonObject{{QStringLiteral("browseId"), browseId}});
}

void dieOnNet(const NetResult &r)
{
    if (!r.ok)
        die(r.err);
}

// ------------------------------------------------------------- scan helpers

// python _find_key: first value of a key inside a subtree.
Json vfind(const Json &node, const QString &wanted)
{
    if (node.isObject()) {
        const QJsonObject o = node.toObject();
        if (o.contains(wanted))
            return o.value(wanted);
        for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
            const Json r = vfind(it.value(), wanted);
            if (!r.isUndefined())
                return r;
        }
    } else if (node.isArray()) {
        const QJsonArray a = node.toArray();
        for (const auto &item : a) {
            const Json r = vfind(item, wanted);
            if (!r.isUndefined())
                return r;
        }
    }
    return Json();
}

QString joinRuns(const QJsonObject &textDict)
{
    if (!textDict.value(QLatin1String("runs")).isArray())
        return textDict.value(QLatin1String("simpleText")).toString();
    QStringList parts;
    for (const auto &r : textDict.value(QLatin1String("runs")).toArray())
        parts << r.toObject().value(QLatin1String("text")).toString();
    return parts.join(QString());
}

// python _title_of.
QString titleOf(const Json &renderer)
{
    const Json title = renderer.toObject().value(QLatin1String("title"));
    if (title.isObject()) {
        const QJsonObject t = title.toObject();
        if (t.value(QLatin1String("runs")).isArray()) {
            const QJsonArray runs =
                t.value(QLatin1String("runs")).toArray();
            if (!runs.isEmpty())
                return runs.first().toObject()
                    .value(QLatin1String("text")).toString().trimmed();
        }
        const QString simple =
            t.value(QLatin1String("simpleText")).toString();
        if (!simple.isEmpty())
            return simple.trimmed();
    }
    return QString();
}

// python _flex_text: plain text of flexColumns[index].
QString flexText(const Json &renderer, int index)
{
    const QJsonArray cols =
        renderer.toObject().value(QLatin1String("flexColumns")).toArray();
    if (index >= cols.size())
        return QString();
    const QJsonObject col =
        cols.at(index).toObject()
            .value(QLatin1String("musicResponsiveListItemFlexColumnRenderer"))
            .toObject();
    return joinRuns(col.value(QLatin1String("text")).toObject()).trimmed();
}

// python _subtitle_of.
QString subtitleOf(const Json &renderer)
{
    const QJsonObject o = renderer.toObject();
    const Json sub = o.value(QLatin1String("subtitle"));
    if (sub.isObject()) {
        const QString s = joinRuns(sub.toObject()).trimmed();
        if (!s.isEmpty())
            return s;
    }
    return flexText(renderer, 1);
}

// python _best_thumb.
QString bestThumb(const Json &node)
{
    const QJsonObject o = node.toObject();
    Json renderer = o.value(QLatin1String("musicThumbnailRenderer"));
    if (!renderer.isObject())
        renderer = o.value(QLatin1String("thumbnailRenderer"))
                       .toObject()
                       .value(QLatin1String("musicThumbnailRenderer"));
    if (!renderer.isObject()) {
        const Json thumbRoot = o.value(QLatin1String("thumbnail"));
        if (thumbRoot.isObject()) {
            const Json inner = thumbRoot.toObject().value(
                QLatin1String("musicThumbnailRenderer"));
            renderer = inner.isObject() ? inner : Json(thumbRoot);
        }
    }
    if (renderer.isObject()) {
        const QJsonArray thumbs =
            renderer.toObject()
                .value(QLatin1String("thumbnail"))
                .toObject()
                .value(QLatin1String("thumbnails"))
                .toArray();
        // The API sorts low to high: the last one is the best.
        if (!thumbs.isEmpty())
            return thumbs.at(thumbs.size() - 1).toObject()
                .value(QLatin1String("url")).toString();
    }
    return QString();
}

// python _browse_id_of.
QString browseIdOf(const Json &renderer)
{
    return renderer.toObject()
        .value(QLatin1String("navigationEndpoint"))
        .toObject()
        .value(QLatin1String("browseEndpoint"))
        .toObject()
        .value(QLatin1String("browseId"))
        .toString();
}

// python _parse_duration.
double parseDur(const QString &text)
{
    const auto m = kDurRe.match(text.trimmed());
    if (!m.hasMatch())
        return 0.0;
    const int h = m.captured(1).isEmpty() ? 0 : m.captured(1).toInt();
    return h * 3600.0 + m.captured(2).toInt() * 60.0
           + m.captured(3).toInt();
}

// python _walk inside _length_text: every plain "text" string of a subtree.
void walkTexts(const Json &node, QStringList *out)
{
    if (node.isObject()) {
        const QJsonObject o = node.toObject();
        for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
            if (it.key() == QLatin1String("text") && it.value().isString())
                out->append(it.value().toString());
            else
                walkTexts(it.value(), out);
        }
    } else if (node.isArray()) {
        const QJsonArray a = node.toArray();
        for (const auto &item : a)
            walkTexts(item, out);
    }
}

// python _length_text → duration of a playlist track row.
double lengthOf(const Json &renderer)
{
    const QJsonObject o = renderer.toObject();
    QStringList candidates;
    const QJsonArray fixed =
        o.value(QLatin1String("fixedColumns")).toArray();
    for (const auto &col : fixed) {
        const QJsonObject text =
            col.toObject()
                .value(QLatin1String(
                    "musicResponsiveListItemFixedColumnRenderer"))
                .toObject()
                .value(QLatin1String("text"))
                .toObject();
        if (text.value(QLatin1String("runs")).isArray()) {
            for (const auto &r : text.value(QLatin1String("runs")).toArray())
                candidates << r.toObject()
                                  .value(QLatin1String("text")).toString();
        } else if (!text.value(QLatin1String("simpleText")).toString()
                        .isEmpty()) {
            candidates << text.value(QLatin1String("simpleText")).toString();
        }
    }
    walkTexts(o.value(QLatin1String("overlay")), &candidates);
    walkTexts(o.value(QLatin1String("lengthText")), &candidates);
    for (const QString &val : candidates) {
        if (kDurRe.match(val.trimmed()).hasMatch())
            return parseDur(val);
    }
    return 0.0;
}

// python _video_id_of.
QString videoIdOf(const Json &renderer)
{
    const QJsonObject o = renderer.toObject();
    QString id = o.value(QLatin1String("playlistItemData"))
                     .toObject()
                     .value(QLatin1String("videoId")).toString();
    if (!id.isEmpty())
        return id;
    id = o.value(QLatin1String("navigationEndpoint"))
             .toObject()
             .value(QLatin1String("watchEndpoint"))
             .toObject()
             .value(QLatin1String("videoId")).toString();
    if (!id.isEmpty())
        return id;
    id = o.value(QLatin1String("overlay"))
             .toObject()
             .value(QLatin1String("content"))
             .toObject()
             .value(QLatin1String("musicPlayButtonRenderer"))
             .toObject()
             .value(QLatin1String("playNavigationEndpoint"))
             .toObject()
             .value(QLatin1String("watchEndpoint"))
             .toObject()
             .value(QLatin1String("videoId")).toString();
    if (!id.isEmpty())
        return id;
    return o.value(QLatin1String("videoId")).toString();
}

// python _set_video_id_of.
QString setVideoIdOf(const Json &renderer)
{
    const QJsonObject o = renderer.toObject();
    QString sid = o.value(QLatin1String("playlistItemData"))
                      .toObject()
                      .value(QLatin1String("playlistSetVideoId"))
                      .toString();
    if (!sid.isEmpty())
        return sid;
    const Json raw = vfind(renderer, QStringLiteral("playlistSetVideoId"));
    if (raw.isString() && !raw.toString().isEmpty())
        return raw.toString();
    return o.value(QLatin1String("setVideoId")).toString();
}

// python _like_status_of.
QString likeStatusOf(const Json &renderer)
{
    const QJsonArray top =
        renderer.toObject()
            .value(QLatin1String("menu"))
            .toObject()
            .value(QLatin1String("menuRenderer"))
            .toObject()
            .value(QLatin1String("topLevelButtons"))
            .toArray();
    for (const auto &button : top) {
        const Json like =
            button.toObject().value(QLatin1String("likeButtonRenderer"));
        if (like.isObject())
            return like.toObject().value(QLatin1String("likeStatus"))
                .toString();
    }
    return QString();
}

// python _menu_icon_types.
QSet<QString> menuIconTypes(const Json &renderer)
{
    QSet<QString> icons;
    const QJsonArray items =
        renderer.toObject()
            .value(QLatin1String("menu"))
            .toObject()
            .value(QLatin1String("menuRenderer"))
            .toObject()
            .value(QLatin1String("items"))
            .toArray();
    for (const auto &item : items) {
        const QJsonObject it = item.toObject();
        for (const QString &key :
             {QStringLiteral("menuNavigationItemRenderer"),
              QStringLiteral("menuServiceItemRenderer")}) {
            const Json ri = it.value(key);
            if (ri.isObject()) {
                const QString type =
                    ri.toObject()
                        .value(QLatin1String("icon"))
                        .toObject()
                        .value(QLatin1String("iconType")).toString();
                if (!type.isEmpty())
                    icons.insert(type);
            }
        }
    }
    return icons;
}

// python _nav_artist / _nav_artist_of_sb: artist parts LINKED (UC/MPC) in a
// list of runs.
QString linkedArtists(const QJsonArray &runs)
{
    QStringList parts;
    for (const auto &r : runs) {
        const QJsonObject ro = r.toObject();
        const QString bid =
            ro.value(QLatin1String("navigationEndpoint"))
                .toObject()
                .value(QLatin1String("browseEndpoint"))
                .toObject()
                .value(QLatin1String("browseId")).toString();
        if (!(bid.startsWith(QLatin1String("UC"))
              || bid.startsWith(QLatin1String("MPC"))))
            continue;
        const QString txt = ro.value(QLatin1String("text")).toString();
        if (!txt.isEmpty())
            parts << txt.trimmed();
    }
    return parts.isEmpty() ? QString()
                           : parts.join(QLatin1String(", "));
}

// python _track_of: music shelf row / playlistVideo row to a plain map.
QJsonObject trackOf(const Json &renderer)
{
    const QString videoId = videoIdOf(renderer);
    if (videoId.isEmpty())
        return {};
    QString title = titleOf(renderer);
    if (title.isEmpty())
        title = flexText(renderer, 0);
    if (title.isEmpty())
        return {};

    QString artist;
    const QString byline = flexText(renderer, 1);
    if (!byline.isEmpty()) {
        // separators "·"/"," between artists in YT Music become ", ".
        artist = byline;
        artist.replace(kSepArtistRe, QStringLiteral(", "));
        artist.remove(QRegularExpression(QStringLiteral("[-,\\s]+$")));
    }
    if (artist.isEmpty()) {
        const QJsonArray runs =
            renderer.toObject()
                .value(QLatin1String("shortBylineText"))
                .toObject()
                .value(QLatin1String("runs"))
                .toArray();
        for (const auto &r : runs)
            artist += r.toObject().value(QLatin1String("text")).toString();
        artist = artist.trimmed();
    }
    if (artist.isEmpty())
        artist = flexText(renderer, 2);

    QJsonObject t;
    t.insert(QLatin1String("id"), videoId);
    t.insert(QLatin1String("title"), title);
    t.insert(QLatin1String("url"),
             QStringLiteral("https://www.youtube.com/watch?v=") + videoId);
    t.insert(QLatin1String("webpage_url"),
             QStringLiteral("https://music.youtube.com/watch?v=") + videoId);
    t.insert(QLatin1String("channel"), artist);
    t.insert(QLatin1String("duration"), lengthOf(renderer));
    t.insert(QLatin1String("thumbnail"), bestThumb(renderer));
    t.insert(QLatin1String("setVideoId"), setVideoIdOf(renderer));
    t.insert(QLatin1String("likeStatus"), likeStatusOf(renderer));
    return t;
}

// Radio queue entry (playlistPanelVideoRenderer) to a plain map. Signal:
// likes (longBylineText carries artist • views • likes) so it falls back to
// the first run.
QJsonObject panelTrackOf(const Json &renderer)
{
    const QJsonObject o = renderer.toObject();
    const QString videoId = o.value(QLatin1String("videoId")).toString();
    if (videoId.isEmpty())
        return {};
    const QString title = titleOf(renderer);
    if (title.isEmpty())
        return {};

    QString artist = linkedArtists(
        o.value(QLatin1String("longBylineText"))
            .toObject()
            .value(QLatin1String("runs"))
            .toArray());
    if (artist.isEmpty()) {
        const QJsonArray runs =
            o.value(QLatin1String("shortBylineText"))
                .toObject()
                .value(QLatin1String("runs"))
                .toArray();
        if (!runs.isEmpty())
            artist = runs.first().toObject()
                         .value(QLatin1String("text")).toString().trimmed();
    }
    QString durText;
    const QJsonArray lengthRuns =
        o.value(QLatin1String("lengthText"))
            .toObject()
            .value(QLatin1String("runs"))
            .toArray();
    if (!lengthRuns.isEmpty())
        durText = lengthRuns.first().toObject()
                      .value(QLatin1String("text")).toString();

    QJsonObject t;
    t.insert(QLatin1String("id"), videoId);
    t.insert(QLatin1String("title"), title);
    t.insert(QLatin1String("url"),
             QStringLiteral("https://www.youtube.com/watch?v=") + videoId);
    t.insert(QLatin1String("webpage_url"),
             QStringLiteral("https://music.youtube.com/watch?v=") + videoId);
    t.insert(QLatin1String("channel"), artist);
    t.insert(QLatin1String("duration"), parseDur(durText));
    t.insert(QLatin1String("thumbnail"), bestThumb(renderer));
    t.insert(QLatin1String("setVideoId"), setVideoIdOf(renderer));
    return t;
}

// python _norm: lowercase without accents (combining marks dropped).
QString norm(const QString &s)
{
    const QString nfd =
        s.toLower().trimmed().normalized(QString::NormalizationForm_D);
    QString out;
    out.reserve(nfd.size());
    for (const QChar &c : nfd) {
        if (c.category() == QChar::Mark_NonSpacing)
            continue;
        out.append(c);
    }
    return out.trimmed();
}

// python _strip_parens.
QString cleanTitle(const QString &tIn)
{
    QString t = tIn;
    t.replace(kParensRe, QStringLiteral(" "));
    t = t.toLower();
    t.replace(kJunkRe, QStringLiteral(" "));
    t.replace(kSpacesRe, QStringLiteral(" "));
    t.replace(kTrimStartRe, QString());
    t.remove(kTrimEndRe);
    return t.trimmed();
}

int yearOf(const QString &text)
{
    const auto m = kYearRe.match(text);
    return m.hasMatch() ? m.captured(1).toInt() : 0;
}

// ---------------------------------------------------------- row collectors

// python _collect_tracks.
void collectTracks(const Json &node, QJsonArray *found, QSet<QString> *seen)
{
    if (node.isObject()) {
        const QJsonObject o = node.toObject();
        for (const QString &key :
             {QStringLiteral("musicResponsiveListItemRenderer"),
              QStringLiteral("playlistVideoRenderer")}) {
            const Json renderer = o.value(key);
            if (renderer.isObject()) {
                const QJsonObject t = trackOf(renderer);
                if (!t.isEmpty()) {
                    const QString id =
                        t.value(QLatin1String("id")).toString();
                    if (!seen->contains(id)) {
                        seen->insert(id);
                        found->append(t);
                    }
                }
            }
        }
        for (auto it = o.constBegin(); it != o.constEnd(); ++it)
            collectTracks(it.value(), found, seen);
    } else if (node.isArray()) {
        const QJsonArray a = node.toArray();
        for (const auto &item : a)
            collectTracks(item, found, seen);
    }
}

// python _nav_artist (flexColumns column 1 with channel links) already part
// of linkedArtists; + _header_artist fallback like _collect_album_tracks.
QString headerArtistOf(const Json &resp)
{
    const Json strap =
        vfind(resp, QStringLiteral("straplineTextOne"));
    if (strap.isObject()) {
        const QJsonArray runs =
            strap.toObject().value(QLatin1String("runs")).toArray();
        if (!runs.isEmpty()) {
            const QString t = runs.first().toObject()
                                  .value(QLatin1String("text")).toString();
            if (!t.isEmpty())
                return t.trimmed();
        }
    }
    return QString();
}

void collectAlbumTracks(const Json &node, QJsonArray *found,
                        QSet<QString> *seen, const QString &headerArtist)
{
    if (node.isObject()) {
        const QJsonObject o = node.toObject();
        for (const QString &key :
             {QStringLiteral("musicResponsiveListItemRenderer"),
              QStringLiteral("playlistVideoRenderer")}) {
            const Json renderer = o.value(key);
            if (!renderer.isObject())
                continue;
            const QJsonObject base = trackOf(renderer);
            if (base.isEmpty())
                continue;
            const QString id =
                base.value(QLatin1String("id")).toString();
            if (seen->contains(id))
                continue;
            seen->insert(id);
            const QJsonArray cols =
                renderer.toObject()
                    .value(QLatin1String("flexColumns"))
                    .toArray();
            QString artist;
            if (cols.size() >= 2) {
                artist = linkedArtists(
                    cols.at(1)
                        .toObject()
                        .value(QLatin1String(
                            "musicResponsiveListItemFlexColumnRenderer"))
                        .toObject()
                        .value(QLatin1String("text"))
                        .toObject()
                        .value(QLatin1String("runs"))
                        .toArray());
            }
            if (artist.isEmpty())
                artist = linkedArtists(
                    renderer.toObject()
                        .value(QLatin1String("shortBylineText"))
                        .toObject()
                        .value(QLatin1String("runs"))
                        .toArray());
            QJsonObject t = base;
            if (!artist.isEmpty()) {
                t.insert(QLatin1String("channel"), artist);
            } else if (!headerArtist.isEmpty()) {
                const QString ch =
                    t.value(QLatin1String("channel")).toString().trimmed();
                const QString low = ch.toLower();
                if (ch.isEmpty() || low.contains(QLatin1String("reproducc"))
                    || low.contains(QLatin1String("view"))) {
                    t.insert(QLatin1String("channel"), headerArtist);
                }
            }
            found->append(t);
        }
        for (auto it = o.constBegin(); it != o.constEnd(); ++it)
            collectAlbumTracks(it.value(), found, seen, headerArtist);
    } else if (node.isArray()) {
        const QJsonArray a = node.toArray();
        for (const auto &item : a)
            collectAlbumTracks(item, found, seen, headerArtist);
    }
}

// -------------------------------------------------------------- continuation

// python _token_from_items: real track continuation of the list (the last
// continuationItemRenderer).
QString tokenFromItems(const Json &items)
{
    if (!items.isArray())
        return QString();
    const QJsonArray a = items.toArray();
    if (a.isEmpty())
        return QString();
    const QJsonObject last = a.at(a.size() - 1).toObject();
    const QJsonObject cir =
        last.value(QLatin1String("continuationItemRenderer")).toObject();
    const QJsonObject ep =
        cir.value(QLatin1String("continuationEndpoint")).toObject();
    const QString token =
        ep.value(QLatin1String("continuationCommand"))
            .toObject()
            .value(QLatin1String("token")).toString();
    if (!token.isEmpty())
        return token;
    const QJsonArray commands =
        ep.value(QLatin1String("commandExecutorCommand"))
            .toObject()
            .value(QLatin1String("commands"))
            .toArray();
    for (const auto &c : commands) {
        const QJsonObject cc =
            c.toObject()
                .value(QLatin1String("continuationCommand")).toObject();
        if (cc.value(QLatin1String("request")).toString()
                == QLatin1String("CONTINUATION_REQUEST_TYPE_BROWSE")) {
            const QString t =
                cc.value(QLatin1String("token")).toString();
            if (!t.isEmpty())
                return t;
        }
    }
    return QString();
}

// python _continuation_items.
Json continuationItems(const Json &resp)
{
    if (resp.isObject()) {
        const QJsonArray actions =
            resp.toObject()
                .value(QLatin1String("onResponseReceivedActions"))
                .toArray();
        for (const auto &action : actions) {
            const Json items =
                action.toObject()
                    .value(QLatin1String("appendContinuationItemsAction"))
                    .toObject()
                    .value(QLatin1String("continuationItems"));
            if (items.isArray())
                return items;
        }
    }
    const Json shelf = vfind(resp, QStringLiteral("musicPlaylistShelfContinuation"));
    if (shelf.isObject())
        return shelf.toObject().value(QLatin1String("contents"));
    return Json();
}

// ----------------------------------------------------------------- entities

QJsonArray playlistTracks(const QString &listId)
{
    QJsonArray found;
    QSet<QString> seen;

    // Radios (RDAMVM<videoId> and friends): not "browse"; the queue arrives
    // in next.playlistPanelRenderer like yt-dlp resolves them.
    if (listId.startsWith(QLatin1String("RD"))) {
        const NetResult r =
            postJson(QStringLiteral("next"),
                     QJsonObject{{QLatin1String("playlistId"), listId}});
        dieOnNet(r);
        const Json panel =
            vfind(r.obj, QStringLiteral("playlistPanelRenderer"));
        const QJsonArray contents =
            panel.toObject().value(QLatin1String("contents")).toArray();
        for (const auto &item : contents) {
            const Json renderer =
                item.toObject()
                    .value(QLatin1String("playlistPanelVideoRenderer"));
            if (!renderer.isObject())
                continue;
            const QJsonObject t = panelTrackOf(renderer);
            if (!t.isEmpty()) {
                const QString id =
                    t.value(QLatin1String("id")).toString();
                if (!seen.contains(id)) {
                    seen.insert(id);
                    found.append(t);
                }
            }
        }
        return found;
    }

    const NetResult r = browseJson(QStringLiteral("VL") + listId);
    dieOnNet(r);
    const Json shelf =
        vfind(r.obj, QStringLiteral("musicPlaylistShelfRenderer"));
    if (!shelf.isObject()) {
        // Lists without a shelf (some automatic ones): from the whole tree.
        collectTracks(r.obj, &found, &seen);
        return found;
    }
    const QJsonArray items =
        shelf.toObject().value(QLatin1String("contents")).toArray();
    collectTracks(items, &found, &seen);
    QString token = tokenFromItems(items);
    for (int round = 0; round < 50 && !token.isEmpty(); ++round) {
        const NetResult cr =
            postJson(QStringLiteral("browse"),
                     QJsonObject{{QLatin1String("continuation"), token}});
        dieOnNet(cr);
        const Json items2 = continuationItems(cr.obj);
        if (!items2.isArray())
            break;
        const int before = found.size();
        collectTracks(items2, &found, &seen);
        if (found.size() == before)
            break;
        token = tokenFromItems(items2);
    }
    return found;
}

// Single video (watch URL through the yt-dlp fallback): the queue with just
// the video arrives in next.playlistPanelRenderer.
QJsonArray singleVideoEntry(const QString &videoId)
{
    const NetResult r =
        postJson(QStringLiteral("next"),
                 QJsonObject{{QLatin1String("videoId"), videoId}});
    dieOnNet(r);
    const Json panel =
        vfind(r.obj, QStringLiteral("playlistPanelRenderer"));
    QJsonArray found;
    QSet<QString> seen;
    const QJsonArray contents =
        panel.toObject().value(QLatin1String("contents")).toArray();
    for (const auto &item : contents) {
        const Json renderer =
            item.toObject().value(QLatin1String("playlistPanelVideoRenderer"));
        if (!renderer.isObject())
            continue;
        const QJsonObject t = panelTrackOf(renderer);
        if (!t.isEmpty()) {
            const QString id = t.value(QLatin1String("id")).toString();
            if (!seen.contains(id)) {
                seen.insert(id);
                found.append(t);
            }
        }
    }
    return found;
}

// python search(): rows of songs/videos of a YTM search (API order).
QJsonArray searchResults(const QString &query)
{
    // The anonymous reading works without any session: like python
    // post_json(anon) when there are no cookies.
    const NetResult r =
        postJson(QStringLiteral("search"),
                 QJsonObject{{QLatin1String("query"), query}});
    dieOnNet(r);
    QJsonArray found;
    QSet<QString> seen;
    collectTracks(r.obj, &found, &seen);
    return found;
}

// python _artist_from_card: the highlighted card of the artist search.
void artistFromCard(const Json &card, QJsonArray *found, QSet<QString> *seen)
{
    const QJsonObject c = card.toObject();
    const QJsonArray titleRuns =
        c.value(QLatin1String("title"))
            .toObject()
            .value(QLatin1String("runs"))
            .toArray();
    QString name;
    QString bid;
    if (!titleRuns.isEmpty()) {
        name = titleRuns.first().toObject()
                   .value(QLatin1String("text")).toString().trimmed();
        bid = titleRuns.first().toObject()
                  .value(QLatin1String("navigationEndpoint"))
                  .toObject()
                  .value(QLatin1String("browseEndpoint"))
                  .toObject()
                  .value(QLatin1String("browseId")).toString();
    }
    if (bid.isEmpty())
        bid = c.value(QLatin1String("onTap"))
                  .toObject()
                  .value(QLatin1String("browseEndpoint"))
                  .toObject()
                  .value(QLatin1String("browseId")).toString();
    if (name.isEmpty() || bid.isEmpty())
        return;
    if (!(bid.startsWith(QLatin1String("UC"))
          || bid.startsWith(QLatin1String("MPC")))
        || seen->contains(bid))
        return;
    seen->insert(bid);
    const QJsonObject sub =
        c.value(QLatin1String("subtitle")).toObject();
    QJsonObject entry;
    entry.insert(QLatin1String("name"), name);
    entry.insert(QLatin1String("browseId"), bid);
    entry.insert(QLatin1String("thumb"), bestThumb(card));
    entry.insert(QLatin1String("subtitle"), joinRuns(sub));
    found->insert(0, entry);   // first: the best match of the search
}

// python _collect_artists.
void collectArtists(const Json &node, QJsonArray *found, QSet<QString> *seen)
{
    if (node.isObject()) {
        const QJsonObject o = node.toObject();
        const Json card = o.value(QLatin1String("musicCardShelfRenderer"));
        if (card.isObject())
            artistFromCard(card, found, seen);
        for (const QString &key :
             {QStringLiteral("musicTwoRowItemRenderer"),
              QStringLiteral("musicResponsiveListItemRenderer")}) {
            const Json renderer = o.value(key);
            if (!renderer.isObject())
                continue;
            const QString bid = browseIdOf(renderer);
            if (!(bid.startsWith(QLatin1String("UC"))
                  || bid.startsWith(QLatin1String("MPC")))
                || seen->contains(bid))
                continue;
            QString name = titleOf(renderer);
            if (name.isEmpty())
                name = flexText(renderer, 0);
            const QString subtitle = subtitleOf(renderer);
            // Only the rows declared "Artist"; "Perfil • @usuario" rows are
            // foreign YouTube channels.
            if (!norm(subtitle).contains(QStringLiteral("artista")))
                continue;
            if (name.isEmpty())
                continue;
            seen->insert(bid);
            found->append(QJsonObject{
                {QLatin1String("name"), name},
                {QLatin1String("browseId"), bid},
                {QLatin1String("thumb"), bestThumb(renderer)},
                {QLatin1String("subtitle"), subtitle},
            });
        }
        for (auto it = o.constBegin(); it != o.constEnd(); ++it)
            collectArtists(it.value(), found, seen);
    } else if (node.isArray()) {
        const QJsonArray a = node.toArray();
        for (const auto &item : a)
            collectArtists(item, found, seen);
    }
}

QJsonArray searchArtists(const QString &query, int limit)
{
    const NetResult r =
        postJson(QStringLiteral("search"),
                 QJsonObject{{QLatin1String("query"), query}});
    dieOnNet(r);
    QJsonArray found;
    QSet<QString> seen;
    collectArtists(r.obj, &found, &seen);
    if (limit >= 0 && found.size() > limit)
        return jsonMid(found, 0, limit);
    return found;
}

// python _collect_albums.
void collectAlbums(const Json &node, QJsonArray *found, QSet<QString> *seen)
{
    if (node.isObject()) {
        const QJsonObject o = node.toObject();
        for (const QString &key :
             {QStringLiteral("musicTwoRowItemRenderer"),
              QStringLiteral("musicResponsiveListItemRenderer")}) {
            const Json renderer = o.value(key);
            if (!renderer.isObject())
                continue;
            const QString bid = browseIdOf(renderer);
            if (bid.isEmpty())
                continue;
            bool skip = false;
            for (const QString &p : kNotAnAlbum) {
                if (bid.startsWith(p)) {
                    skip = true;
                    break;
                }
            }
            if (skip)
                continue;
            QString title = titleOf(renderer);
            if (title.isEmpty())
                title = flexText(renderer, 0);
            if (title.isEmpty() || seen->contains(bid))
                continue;
            const QString subtitle = subtitleOf(renderer);
            seen->insert(bid);
            found->append(QJsonObject{
                {QLatin1String("title"), title},
                {QLatin1String("browseId"), bid},
                {QLatin1String("thumb"), bestThumb(renderer)},
                {QLatin1String("subtitle"), subtitle},
                {QLatin1String("year"), yearOf(subtitle)},
            });
        }
        for (auto it = o.constBegin(); it != o.constEnd(); ++it)
            collectAlbums(it.value(), found, seen);
    } else if (node.isArray()) {
        const QJsonArray a = node.toArray();
        for (const auto &item : a)
            collectAlbums(item, found, seen);
    }
}

// python artist_discography: the page MPAD lists ALL the recordings in a
// single reply (the UC…/MPC… one truncates to carousels of 10).
QJsonArray artistDiscography(const QString &bidIn)
{
    QString bid = bidIn.trimmed();
    if (bid.isEmpty())
        return {};
    if (!bid.startsWith(QLatin1String("MPAD")))
        bid = QStringLiteral("MPAD") + bid;
    const NetResult r = browseJson(bid);
    dieOnNet(r);
    QJsonArray found;
    QSet<QString> seen;
    collectAlbums(r.obj, &found, &seen);
    // newest first (year 0 last), alphabetical within the same year like
    // python's sort((-year, title.lower())).
    found = sortJsonObjects(found,
                            [](const QJsonObject &a, const QJsonObject &b) {
                                const int ya = a.value(QLatin1String("year"))
                                                   .toInt();
                                const int yb = b.value(QLatin1String("year"))
                                                   .toInt();
                                if (ya != yb)
                                    return ya > yb;
                                const QString ta =
                                    a.value(QLatin1String("title"))
                                        .toString().toLower();
                                const QString tb =
                                    b.value(QLatin1String("title"))
                                        .toString().toLower();
                                return ta < tb;
                            });
    if (found.size() > 80)
        return jsonMid(found, 0, 80);
    return found;
}

// python album_tracks.
QJsonArray albumTracks(const QString &bid)
{
    if (bid.isEmpty())
        return {};
    const NetResult r = browseJson(bid);
    dieOnNet(r);
    QJsonArray tracks;
    QSet<QString> seen;
    const Json shelf = vfind(r.obj, QStringLiteral("musicShelfRenderer"));
    const QJsonArray items =
        shelf.isObject()
            ? shelf.toObject().value(QLatin1String("contents")).toArray()
            : QJsonArray();
    collectAlbumTracks(items, &tracks, &seen, QString());
    QString token = tokenFromItems(items);
    for (int round = 0; round < 12 && !token.isEmpty(); ++round) {
        const NetResult cr =
            postJson(QStringLiteral("browse"),
                     QJsonObject{{QLatin1String("continuation"), token}});
        dieOnNet(cr);
        const Json items2 = continuationItems(cr.obj);
        if (!items2.isArray())
            break;
        const int before = tracks.size();
        collectAlbumTracks(items2, &tracks, &seen, QString());
        if (tracks.size() == before)
            break;
        token = tokenFromItems(items2);
    }
    if (tracks.isEmpty())
        collectAlbumTracks(r.obj, &tracks, &seen, QString());

    // Without a per-row link (albums with no artist column): the header.
    const QString hdr = headerArtistOf(r.obj);
    if (!hdr.isEmpty()) {
        for (int k = 0; k < tracks.size(); ++k) {
            QJsonObject t = tracks.at(k).toObject();
            const QString ch =
                t.value(QLatin1String("channel")).toString().trimmed();
            const QString low = ch.toLower();
            if (ch.isEmpty()
                || low.contains(QLatin1String("reproducc"))
                || low.contains(QLatin1String("view"))) {
                t.insert(QLatin1String("channel"), hdr);
                tracks.replace(k, t);
            }
        }
    }
    return tracks;
}

// python _collect (playlists of the library page).
void collectPlaylists(const Json &node, QJsonArray *found, QSet<QString> *seen)
{
    if (node.isObject()) {
        const QJsonObject o = node.toObject();
        for (const QString &key :
             {QStringLiteral("musicTwoRowItemRenderer"),
              QStringLiteral("musicResponsiveListItemRenderer")}) {
            const Json renderer = o.value(key);
            if (!renderer.isObject())
                continue;
            const QString bid = browseIdOf(renderer);
            if (!bid.startsWith(QLatin1String("VL")))
                continue;
            const QString name = titleOf(renderer);
            if (name.isEmpty())
                continue;
            const QString pid = bid.mid(2);
            if (seen->contains(pid))
                continue;
            seen->insert(pid);
            const QSet<QString> icons = menuIconTypes(renderer);
            // An OWN list shows the EDIT/DELETE actions; a saved one from
            // someone else does not.
            found->append(QJsonObject{
                {QLatin1String("name"), name},
                {QLatin1String("id"), pid},
                {QLatin1String("thumb"), bestThumb(renderer)},
                {QLatin1String("owned"),
                 icons.contains("EDIT") || icons.contains("DELETE")},
            });
        }
        for (auto it = o.constBegin(); it != o.constEnd(); ++it)
            collectPlaylists(it.value(), found, seen);
    } else if (node.isArray()) {
        const QJsonArray a = node.toArray();
        for (const auto &item : a)
            collectPlaylists(item, found, seen);
    }
}

// python library(): the user's saved/own lists.
QJsonArray libraryItems()
{
    for (const QString &bid : kLibraryIds) {
        const NetResult r = browseJson(bid);
        if (!r.ok)
            continue;
        QJsonArray found;
        QSet<QString> seen;
        collectPlaylists(r.obj, &found, &seen);
        if (!found.isEmpty())
            return found;
    }
    return {};
}

// python _playable_row checks + _first_top_row walk.
Json firstTopRow(const Json &node)
{
    if (node.isObject()) {
        const QJsonObject o = node.toObject();
        const Json item =
            o.value(QLatin1String("musicResponsiveListItemRenderer"));
        if (item.isObject()) {
            const Json overlay =
                item.toObject()
                    .value(QLatin1String("overlay"))
                    .toObject()
                    .value(QLatin1String("musicItemThumbnailOverlayRenderer"));
            if (overlay.isObject()) {
                const QString vid =
                    overlay.toObject()
                        .value(QLatin1String("content"))
                        .toObject()
                        .value(QLatin1String("musicPlayButtonRenderer"))
                        .toObject()
                        .value(QLatin1String("playNavigationEndpoint"))
                        .toObject()
                        .value(QLatin1String("watchEndpoint"))
                        .toObject()
                        .value(QLatin1String("videoId")).toString();
                if (!vid.isEmpty())
                    return item;
            }
        }
        for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
            const Json found = firstTopRow(it.value());
            if (!found.isUndefined())
                return found;
        }
    } else if (node.isArray()) {
        const QJsonArray a = node.toArray();
        for (const auto &item : a) {
            const Json found = firstTopRow(item);
            if (!found.isUndefined())
                return found;
        }
    }
    return Json();
}

// python top_track: the artist's top track (radio seed RDAMVM).
QJsonObject topTrack(const QString &query)
{
    const QJsonArray artists = searchArtists(query, 5);
    if (artists.isEmpty())
        return {};
    const QJsonObject first = artists.first().toObject();
    const NetResult r =
        browseJson(first.value(QLatin1String("browseId")).toString());
    dieOnNet(r);
    const Json row = firstTopRow(r.obj);
    if (row.isUndefined())
        return {};
    QJsonObject track = trackOf(row);
    if (track.isEmpty())
        return {};
    track.insert(QLatin1String("artist"),
                 first.value(QLatin1String("name")).toString());
    return track;
}

// python playlist_info.
QJsonObject playlistInfoObj(const QString &listId)
{
    const NetResult r = browseJson(QStringLiteral("VL") + listId);
    dieOnNet(r);
    const Json editable = vfind(
        r.obj, QStringLiteral("musicEditablePlaylistDetailHeaderRenderer"));
    const bool owned = editable.isObject();

    Json header;
    if (owned)
        header = vfind(editable, QStringLiteral("musicResponsiveHeaderRenderer"));
    if (!header.isObject())
        header = vfind(r.obj, QStringLiteral("musicDetailHeaderRenderer"));
    if (!header.isObject())
        header = vfind(r.obj, QStringLiteral("musicResponsiveHeaderRenderer"));

    int count = 0;
    if (header.isObject()) {
        const QString text =
            joinRuns(header.toObject()
                         .value(QLatin1String("secondSubtitle"))
                         .toObject());
        const auto m = kCountRe.match(text);
        if (m.hasMatch()) {
            const QString digits =
                m.captured(1).remove(QRegularExpression("[^\\d]"));
            count = digits.toInt();
        }
    }

    QString description;
    if (header.isObject()) {
        // python _description_of (musicDescriptionShelfRenderer).
        const Json shelf = vfind(
            header, QStringLiteral("musicDescriptionShelfRenderer"));
        if (shelf.isObject()) {
            const QJsonArray runs =
                shelf.toObject()
                    .value(QLatin1String("description"))
                    .toObject()
                    .value(QLatin1String("runs"))
                    .toArray();
            if (!runs.isEmpty()) {
                QStringList texts;
                for (const auto &r2 : runs)
                    texts << r2.toObject()
                                 .value(QLatin1String("text")).toString();
                description = texts.join(QString()).trimmed();
            } else {
                description = shelf.toObject()
                                  .value(QLatin1String("description"))
                                  .toObject()
                                  .value(QLatin1String("simpleText"))
                                  .toString()
                                  .trimmed();
            }
        }
    }

    return QJsonObject{
        {QLatin1String("id"), listId},
        {QLatin1String("title"), header.isObject() ? titleOf(header) : QString()},
        {QLatin1String("description"), description},
        {QLatin1String("privacy"),
         owned ? vfind(editable, QStringLiteral("privacy")).toString()
               : QString()},
        {QLatin1String("owned"), owned},
        {QLatin1String("count"), count},
    };
}

// python alternate_track: a reproducible alternative for a dead track.
QJsonObject alternateTrack(const QString &artist, const QString &title,
                           const QString &exclude, double duration)
{
    const QString q = (artist + " " + title).trimmed();
    if (q.isEmpty())
        return {};
    const QString wantT = norm(cleanTitle(title));
    const QString wantA = norm(artist);
    const QJsonArray cands = searchResults(q);   // API order (python limit 15)
    QJsonObject best;
    double bestScore = -1e9;
    for (int idx = 0; idx < cands.size() && idx < 15; ++idx) {
        const QJsonObject c = cands.at(idx).toObject();
        if (!exclude.isEmpty()
            && c.value(QLatin1String("id")).toString() == exclude)
            continue;
        const QString ct =
            norm(cleanTitle(c.value(QLatin1String("title")).toString()));
        const QString ca =
            norm(c.value(QLatin1String("channel")).toString());
        if (ct.isEmpty() || wantT.isEmpty())
            continue;
        bool titleOk = ct == wantT || ct.startsWith(wantT)
                       || wantT.startsWith(ct);
        if (!titleOk) {
            // very long title: chance through words.
            const QStringList wtList = wantT.split(QLatin1Char(' '));
            const QStringList wcList = ct.split(QLatin1Char(' '));
            const QSet<QString> wt(wtList.cbegin(), wtList.cend());
            const QSet<QString> wc(wcList.cbegin(), wcList.cend());
            int inter = 0;
            for (const QString &w : wt)
                if (wc.contains(w))
                    inter++;
            if (inter == 0
                || double(inter) / std::max(1, int(wt.size())) < 0.6)
                continue;
        }
        double score = 40;
        if (ct == wantT)
            score += 40;
        if (!wantA.isEmpty() && !ca.isEmpty()
            && (wantA.contains(ca) || ca.contains(wantA)))
            score += 30;
        const double dur = c.value(QLatin1String("duration")).toDouble();
        if (duration > 0 && dur > 0) {
            const double d = qAbs(dur - duration);
            if (d <= 5)
                score += 20;
            else if (d <= 20)
                score += 10;
            else if (d > 45)
                score -= 10;
        }
        score -= idx;
        if (score > bestScore) {
            best = c;
            bestScore = score;
        }
    }
    return best;
}

// python _search_rank as an ordered int for the stable sort.
int searchRank(const QJsonObject &e, const QString &query)
{
    const QString ch = e.value(QLatin1String("channel")).toString();
    const QString title = e.value(QLatin1String("title")).toString();
    int typ;
    // python splits by U+2022 (bullet): "Canción • Artista".
    const QStringList parts = ch.toLower().split(QChar(0x2022));
    const QString kind = parts.isEmpty() ? QString()
                                         : parts.first().trimmed();
    if (kind == QStringLiteral("canción") || kind == QStringLiteral("cancion")
        || kind == QStringLiteral("song"))
        typ = 0;
    else if (kind == QStringLiteral("vídeo") || kind == QStringLiteral("video"))
        typ = 1;
    else
        typ = 2;
    const QString nq = norm(query);
    const QString nt = norm(title);
    const QString ntc = norm(cleanTitle(title));
    int exact;
    if (nt == nq)
        exact = 0;
    else if (ntc == nq)
        exact = 1;
    else if (!nq.isEmpty() && nt.contains(nq))
        exact = 2;
    else
        exact = 3;
    const int inCh =
        (!nq.isEmpty() && norm(ch).contains(nq)) ? 0 : 1;
    return typ * 10000 + exact * 100 + inCh;
}

// cmd_search sorting: song first, video, rest; within each type the closest
// title to the query; equal rank: the API's order.
QJsonArray rankedSearch(const QString &query)
{
    QJsonArray tracks = searchResults(query);
    return sortJsonObjects(tracks,
                           [&query](const QJsonObject &a,
                                    const QJsonObject &b) {
                               return searchRank(a, query)
                                      < searchRank(b, query);
                           });
}

// ------------------------------------------------------------ management net

NetResult postAuth(const QString &endpoint, const QJsonObject &body)
{
    QString err;
    if (!loadCookies(&err))
        die(err);
    return postJson(endpoint, body);
}

// ---------------------------------------------------------------- printing

void printJson(const QJsonDocument &doc)
{
    const QByteArray bytes = doc.toJson(QJsonDocument::Compact);
    // fwrite on stdout (see the note in die): std::cout breaks on Android.
    const QByteArray line = bytes + QByteArrayLiteral("\n");
    std::fwrite(line.constData(), 1, line.size(), stdout);
    std::fflush(stdout);
}

void printArray(const QJsonArray &a) { printJson(QJsonDocument(a)); }

void printObj(const QJsonObject &o) { printJson(QJsonDocument(o)); }

QJsonObject statusObj(const QJsonObject &resp)
{
    return QJsonObject{{QLatin1String("status"),
                        resp.value(QLatin1String("status")).toString(
                            QStringLiteral("ok"))}};
}

} // namespace

// ------------------------------------------------------------------- main

int main(int argc, char *argv[])
{
#ifndef Q_OS_ANDROID
    // On Android the helper runs as a spawned child WITHOUT a JVM:
    // QCoreApplication would touch the Java side and abort (the app
    // version field uses JNI there), so the app object stays behind and
    // the process runs single-threaded with blocking IO only.
    QCoreApplication app(argc, argv);
    app.setApplicationVersion(QStringLiteral("1.0"));

    QStringList args = app.arguments();
    args.removeFirst();
#else
    QStringList args;
    for (int i = 1; i < argc; ++i)
        args << QString::fromLocal8Bit(argv[i]);
#endif

    // python-mode: the app passes {pythonProgram, ytmApiPath, cmd, ...};
    // this binary finds the first known command in argv.
    static const QSet<QString> kCommands{
        "library",    "search",   "artists",  "artist",
        "album",      "alternate", "toptrack", "playlist",
        "playlistinfo", "rate",   "addpl",    "rmpl",
        "movepl",     "createpl", "renamepl", "setplpriv",
        "deletepl",
    };
    static const QSet<QString> kAuthCommands{
        "rate", "addpl", "rmpl", "movepl",
        "createpl", "renamepl", "setplpriv", "deletepl",
    };

    int cmdIdx = -1;
    for (int i = 0; i < args.size(); ++i) {
        if (kCommands.contains(args.at(i))) {
            cmdIdx = i;
            break;
        }
    }
    if (cmdIdx >= 0) {
        const QString cmd = args.at(cmdIdx);
        const QStringList rest =
            args.mid(cmdIdx + 1);
        QString ckErr;
        if (!loadCookies(&ckErr)) {
            // python errors out only when the command needs the session.
            if (kAuthCommands.contains(cmd))
                die(ckErr);
        }

        if (cmd == QLatin1String("library")) {
            printArray(libraryItems());
            return 0;
        }
        if (cmd == QLatin1String("search")) {
            if (rest.isEmpty())
                die(QStringLiteral("falta la consulta de búsqueda"));
            printObj(QJsonObject{{QLatin1String("entries"),
                                  rankedSearch(rest.join(
                                      QLatin1Char(' ')))}});
            return 0;
        }
        if (cmd == QLatin1String("artists")) {
            if (rest.isEmpty())
                die(QStringLiteral("falta la consulta de búsqueda"));
            printObj(QJsonObject{{QLatin1String("artists"),
                                  searchArtists(rest.join(QLatin1Char(' ')),
                                                12)}});
            return 0;
        }
        if (cmd == QLatin1String("artist")) {
            if (rest.isEmpty())
                die(QStringLiteral("falta el browseId del artista"));
            printObj(QJsonObject{
                {QLatin1String("albums"), artistDiscography(rest.first())}});
            return 0;
        }
        if (cmd == QLatin1String("album")) {
            if (rest.isEmpty())
                die(QStringLiteral("falta el browseId del álbum"));
            printObj(QJsonObject{{QLatin1String("entries"),
                                  albumTracks(rest.first())}});
            return 0;
        }
        if (cmd == QLatin1String("toptrack")) {
            if (rest.isEmpty())
                die(QStringLiteral("falta el nombre del artista"));
            QJsonObject top = topTrack(rest.join(QLatin1Char(' ')));
            if (top.isEmpty())
                die(QStringLiteral(
                        "no se encontró una pista principal"));
            // Catalog consumes it (resolveArtistRadio).
            top.insert(QLatin1String("videoId"),
                       top.value(QLatin1String("id")).toString());
            printObj(top);
            return 0;
        }
        if (cmd == QLatin1String("alternate")) {
            if (rest.isEmpty())
                die(QStringLiteral(
                        "falta la pista (artista\\ttítulo\\texcluir)"));
            const QStringList specParts =
                rest.first().split(QLatin1Char('\t'));
            double dur = 0.0;
            if (rest.size() > 1)
                dur = rest.at(1).toDouble();
            QJsonObject t = alternateTrack(specParts.value(0),
                                           specParts.value(1),
                                           specParts.value(2), dur);
            if (t.isEmpty())
                die(QStringLiteral("no hay vídeo alternativo"));
            t.insert(QLatin1String("videoId"),
                     t.value(QLatin1String("id")).toString());
            printObj(t);
            return 0;
        }
        if (cmd == QLatin1String("playlist")) {
            if (rest.isEmpty())
                die(QStringLiteral("falta el id de la playlist"));
            printObj(QJsonObject{{QLatin1String("entries"),
                                  playlistTracks(rest.first())}});
            return 0;
        }
        if (cmd == QLatin1String("playlistinfo")) {
            if (rest.isEmpty())
                die(QStringLiteral("falta el id de la playlist"));
            printObj(playlistInfoObj(rest.first()));
            return 0;
        }
        if (cmd == QLatin1String("rate")) {
            if (rest.size() < 2)
                die(QStringLiteral("uso: rate <videoId> <LIKE|DISLIKE|"
                                   "INDIFFERENT>"));
            const QString rating = rest.at(1).toUpper();
            QString ep;
            if (rating == QLatin1String("LIKE"))
                ep = QStringLiteral("like/like");
            else if (rating == QLatin1String("DISLIKE"))
                ep = QStringLiteral("like/dislike");
            else if (rating == QLatin1String("INDIFFERENT"))
                ep = QStringLiteral("like/removelike");
            else
                die(QStringLiteral(
                        "rating debe ser LIKE, DISLIKE o INDIFFERENT"));
            const NetResult resp = postAuth(ep, QJsonObject{
                {QLatin1String("target"),
                 QJsonObject{{QLatin1String("videoId"), rest.first()}}}});
            dieOnNet(resp);
            printObj(statusObj(resp.obj));
            return 0;
        }
        if (cmd == QLatin1String("addpl") || cmd == QLatin1String("rmpl")
            || cmd == QLatin1String("movepl")) {
            QJsonArray actions;
            if (cmd == QLatin1String("addpl")) {
                if (rest.size() < 2)
                    die(QStringLiteral(
                            "uso: addpl <playlistId> <videoId>"));
                actions.append(QJsonObject{
                    {QLatin1String("action"), QStringLiteral("ACTION_ADD_VIDEO")},
                    {QLatin1String("addedVideoId"), rest.at(1)},
                });
            } else if (cmd == QLatin1String("rmpl")) {
                if (rest.size() < 3)
                    die(QStringLiteral(
                            "uso: rmpl <playlistId> <videoId> <setVideoId>"));
                if (rest.at(2).isEmpty())
                    die(QStringLiteral(
                            "falta setVideoId (consulta primero playlist)"));
                actions.append(QJsonObject{
                    {QLatin1String("action"),
                     QStringLiteral("ACTION_REMOVE_VIDEO")},
                    {QLatin1String("removedVideoId"), rest.at(1)},
                    {QLatin1String("setVideoId"), rest.at(2)},
                });
            } else {   // movepl: <pid> <setVideoId> <vecinoSetVideoId> <dir>
                if (rest.size() < 4)
                    die(QStringLiteral(
                            "uso: movepl <playlistId> <setVideoId> "
                            "<vecinoSetVideoId> <before|after>"));
                if (rest.at(1).isEmpty() || rest.at(2).isEmpty())
                    die(QStringLiteral(
                            "faltan setVideoId para reordenar"));
                const bool before =
                    rest.at(3).compare(QLatin1String("before"),
                                       Qt::CaseInsensitive) == 0;
                if (before) {
                    actions.append(QJsonObject{
                        {QLatin1String("action"),
                         QStringLiteral("ACTION_MOVE_VIDEO_BEFORE")},
                        {QLatin1String("setVideoId"), rest.at(1)},
                        {QLatin1String("movedSetVideoIdSuccessor"),
                         rest.at(2)},
                    });
                } else {
                    actions.append(QJsonObject{
                        {QLatin1String("action"),
                         QStringLiteral("ACTION_MOVE_VIDEO_AFTER")},
                        {QLatin1String("setVideoId"), rest.at(1)},
                        {QLatin1String("movedSetVideoIdPredecessor"),
                         rest.at(2)},
                    });
                }
            }
            const NetResult resp = postAuth(
                QStringLiteral("browse/edit_playlist"),
                QJsonObject{{QLatin1String("playlistId"), rest.first()},
                            {QLatin1String("actions"), actions}});
            dieOnNet(resp);
            printObj(statusObj(resp.obj));
            return 0;
        }
        if (cmd == QLatin1String("createpl")) {
            if (rest.isEmpty())
                die(QStringLiteral("la lista necesita un nombre"));
            const bool priv =
                rest.size() > 1 && rest.at(1).compare(QLatin1String("priv"),
                                                      Qt::CaseInsensitive)
                                     == 0;
            const NetResult resp = postAuth(
                QStringLiteral("playlist/create"),
                QJsonObject{{QLatin1String("title"), rest.first()},
                            {QLatin1String("description"), QString()},
                            {QLatin1String("privacyStatus"),
                             priv ? QStringLiteral("PRIVATE")
                                  : QStringLiteral("PUBLIC")}});
            dieOnNet(resp);
            const QString id =
                resp.obj.value(QLatin1String("playlistId")).toString();
            if (id.isEmpty())
                die(QStringLiteral("no se pudo crear la lista"));
            printObj(QJsonObject{{QLatin1String("status"),
                                  QStringLiteral("ok")},
                                 {QLatin1String("id"), id}});
            return 0;
        }
        if (cmd == QLatin1String("renamepl")) {
            if (rest.size() < 2)
                die(QStringLiteral("uso: renamepl <listId> <title> [priv]"));
            QJsonArray actions;
            actions.append(QJsonObject{
                {QLatin1String("action"),
                 QStringLiteral("ACTION_SET_PLAYLIST_NAME")},
                {QLatin1String("playlistName"), rest.at(1)},
            });
            if (rest.size() > 2) {
                const QString priv = rest.at(2);
                const QString p =
                    priv.compare(QLatin1String("priv"),
                                 Qt::CaseInsensitive) == 0
                        ? QStringLiteral("PRIVATE")
                        : QStringLiteral("PUBLIC");
                actions.append(QJsonObject{
                    {QLatin1String("action"),
                     QStringLiteral("ACTION_SET_PLAYLIST_PRIVACY")},
                    {QLatin1String("playlistPrivacy"), p},
                });
            }
            const NetResult resp = postAuth(
                QStringLiteral("browse/edit_playlist"),
                QJsonObject{{QLatin1String("playlistId"), rest.first()},
                            {QLatin1String("actions"), actions}});
            dieOnNet(resp);
            printObj(statusObj(resp.obj));
            return 0;
        }
        if (cmd == QLatin1String("setplpriv")) {
            if (rest.size() < 2)
                die(QStringLiteral("uso: setplpriv <listId> <priv>"));
            const QString p =
                rest.at(1).compare(QLatin1String("priv"),
                                   Qt::CaseInsensitive) == 0
                    ? QStringLiteral("PRIVATE")
                    : QStringLiteral("PUBLIC");
            QJsonArray actions;
            actions.append(QJsonObject{
                {QLatin1String("action"),
                 QStringLiteral("ACTION_SET_PLAYLIST_PRIVACY")},
                {QLatin1String("playlistPrivacy"), p},
            });
            const NetResult resp = postAuth(
                QStringLiteral("browse/edit_playlist"),
                QJsonObject{{QLatin1String("playlistId"), rest.first()},
                            {QLatin1String("actions"), actions}});
            dieOnNet(resp);
            printObj(statusObj(resp.obj));
            return 0;
        }
        if (cmd == QLatin1String("deletepl")) {
            const NetResult resp = postAuth(
                QStringLiteral("playlist/delete"),
                QJsonObject{{QLatin1String("playlistId"), rest.first()}});
            dieOnNet(resp);
            printObj(statusObj(resp.obj));
            return 0;
        }
        die(QStringLiteral("comando desconocido: %1").arg(cmd));
    }

    // --------------------------- yt-dlp emulation -----------------------
    // Catalog::runYtdlp calls: yt-dlp -J --no-warnings --ignore-errors
    // --no-plugin-dirs --playlist-end=N --flat-playlist [--cookies FILE]
    // TARGET
    int cap = -1;
    QString cookies;
    QString target;
    for (int i = 0; i < args.size(); ++i) {
        const QString a = args.at(i);
        if (a == QLatin1String("--cookies")) {
            if (i + 1 < args.size())
                cookies = args.at(i + 1);
            i++;
        } else if (a.startsWith(QLatin1String("--playlist-end="))) {
            cap = a.mid(a.lastIndexOf(QLatin1Char('=')) + 1).toInt();
        } else if (!a.startsWith(QLatin1Char('-'))) {
            target = a;
        }
    }
    if (!cookies.isEmpty()) {
        g_cookiePath = cookies;
        QString err;
        loadCookies(&err);   // like python: without readable cookies it
                             // goes anonymous, without failing
    }
    if (target.isEmpty())
        die(QStringLiteral("uso: yt-dlp <target>"));

    // SoundCloud has no native path on the phone: same error as the missing
    // binary on the desktop would give.
    if (target.contains(QLatin1String("soundcloud.com")))
        die(QStringLiteral("soundcloud sin soporte en esta plataforma"));

    // A) ytsearch15:<query> / ytsearch:<query> (yt-dlp syntax).
    const auto searchMatch = kSearchPrefixRe.match(target);
    if (searchMatch.hasMatch()) {
        const QString query =
            target.mid(searchMatch.capturedEnd(0)).trimmed();
        if (query.isEmpty())
            die(QStringLiteral("target no soportado: %1").arg(target));
        int limit = searchMatch.captured(1).isEmpty()
                        ? 15 : searchMatch.captured(1).toInt();
        // ranked like the YTM fast path: better order than yt-dlp's.
        QJsonArray found = rankedSearch(query);
        if (found.size() > limit)
            found = jsonMid(found, 0, limit);
        printObj(QJsonObject{
            {QLatin1String("_type"), QStringLiteral("playlist")},
            {QLatin1String("entries"), found},
        });
        return 0;
    }

    if (target.contains(QLatin1String("youtube.com"))
        || target.contains(QLatin1String("youtu.be"))) {
        // playlist/radio: list=<id>; single video: v=<id>.
        const QString listId = [&]() {
            const auto ml = kListIdRe.match(target);
            return ml.hasMatch() ? ml.captured(1) : QString();
        }();
        QString videoId;
        if (listId.isEmpty()) {
            const auto mv = kWatchIdRe.match(target);
            if (mv.hasMatch())
                videoId = mv.captured(1);
        }
        if (listId.isEmpty() && videoId.isEmpty())
            die(QStringLiteral("target no soportado: %1").arg(target));
        QJsonArray entries;
        int limit = 1;
        if (!listId.isEmpty()) {
            entries = playlistTracks(listId);
            const bool radio = listId.startsWith(QLatin1String("RD"));
            limit = radio ? (cap > 0 ? cap : 25) : (cap > 0 ? cap : 500);
        } else {
            entries = singleVideoEntry(videoId);
        }
        if (entries.size() > limit)
            entries = jsonMid(entries, 0, limit);
        QJsonObject out{
            {QLatin1String("_type"), QStringLiteral("playlist")},
            {QLatin1String("id"),
             listId.isEmpty() ? videoId : listId},
            {QLatin1String("entries"), entries},
        };
        printObj(out);
        return 0;
    }

    // Bare radio id (RDAMVM...).
    if (target.startsWith(QLatin1String("RD"))) {
        QJsonArray entries = playlistTracks(target);
        const int limit = cap > 0 ? cap : 25;
        if (entries.size() > limit)
            entries = jsonMid(entries, 0, limit);
        QJsonObject out{
            {QLatin1String("_type"), QStringLiteral("playlist")},
            {QLatin1String("id"), target},
            {QLatin1String("entries"), entries},
        };
        printObj(out);
        return 0;
    }

    die(QStringLiteral("target no soportado: %1").arg(target));
}
