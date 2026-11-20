#!/usr/bin/env python3
"""Lotus Tune -- login real de YouTube Music dentro de la app (WebKitGTK).

Abre una ventana de Google (ServiceLogin) embebida, espera el redirect a
music.youtube.com, captura las cookies de YouTube y las deja en:

  ~/.config/lotus-tune/cookies.txt         (formato Netscape, para yt-dlp)
  ~/.config/lotus-tune/ytm_session.json    (cabecera Cookie + metadatos)

No depende de ningun navegador del sistema (ni Zen). La sesion web vive en un
perfil WebKit propio de Lotus Tune.

Subcomandos:
  login [--add-account]   abre la ventana de inicio de sesion
  refresh                 re-captura cookies usando la sesion persistente
  status                  salida 0 si hay una sesion usable guardada
"""

import argparse
import webbrowser
import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

# Windows has no WebKitGTK (see cmd_login_win). It also keeps the app data in
# %APPDATA%/<org>/<app>/LotusTune (src/paths.h), not in ~/.config/lotus-tune:
# writing the cookies to the Linux path made the login succeed on paper while
# the app kept showing "no session".
WIN = sys.platform == "win32"
if WIN:
    CONFIG = os.path.join(
        os.environ.get("APPDATA", os.path.join(os.path.expanduser("~"), "AppData", "Roaming")),
        "lotus-tune", "lotus-tune", "LotusTune")
    STATE = os.path.join(
        os.environ.get("LOCALAPPDATA", os.path.join(os.path.expanduser("~"), "AppData", "Local")),
        "lotus-tune", "lotus-tune", "LotusTune")
else:
    CONFIG = os.path.join(
        os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "lotus-tune"
    )
    STATE = os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "lotus-tune"
    )
WEBKIT_DIR = os.path.join(STATE, "webkit")
COOKIE_FILE = os.path.join(CONFIG, "cookies.txt")
SESSION_FILE = os.path.join(CONFIG, "ytm_session.json")

LOGIN_URL = (
    "https://accounts.google.com/ServiceLogin"
    "?service=youtube&continue=https://music.youtube.com/"
)
ADD_URL = (
    "https://accounts.google.com/AddSession"
    "?service=youtube&continue=https://music.youtube.com/"
)
REFRESH_URL = "https://music.youtube.com/"

# Google refuses logins from embedded browsers it does not know.
# WebKitGTK shares the engine with Safari, so we identify as Safari/mac.
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)

SAPISID_NAMES = ("SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID")
AUTH_DOMAINS = ("youtube.com", "google.com")


def out(line):
    print(line, flush=True)


def _usable(header):
    return any(
        part.split("=", 1)[0].strip() in SAPISID_NAMES
        for part in header.split(";")
        if "=" in part
    )


def _dedupe_header(header):
    """Quita nombres repetidos de una cabecera Cookie (gana el primero).

    cookies.txt puede traer la misma cookie para google.com y para
    youtube.com con valores distintos. Mandar las dos en el mismo header
    hace que YouTube responda CookieMismatch, asi que solo puede quedar una.
    """
    seen = set()
    parts = []
    for part in header.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        name = part.split("=", 1)[0].strip()
        if name in seen:
            continue
        seen.add(name)
        parts.append(part)
    return "; ".join(parts)


def _stored_header():
    try:
        with open(SESSION_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        # New sessions already save the filtered header; old ones carry
        # google.com and youtube.com mixed and have to be deduplicated.
        return _dedupe_header(
            data.get("youtube_cookie_header") or data.get("cookie_header", "")
        )
    except Exception:
        return ""


def _youtube_header():
    """Cabecera Cookie con SOLO las cookies de YouTube.

    Es lo que manda un navegador a youtube.com. Mezclar las de google.com
    (SID/HSID/SSID llegan duplicadas) provoca CookieMismatch y el chequeo
    daba la sesion por caducada en cada arranque aunque siguiera valiendo.
    Si un nombre aparece en varios dominios gana el mas especifico.
    """
    best = {}
    order = []
    try:
        with open(COOKIE_FILE, "r", encoding="utf-8") as f:
            for ln in f:
                if not ln.strip() or ln.startswith("#"):
                    continue
                cols = ln.rstrip("\n").split("\t")
                if len(cols) < 7:
                    continue
                domain = cols[0].lstrip(".").lower()
                if not (domain == "youtube.com" or domain.endswith(".youtube.com")):
                    continue
                name, value = cols[5], cols[6]
                rank = domain.count(".")
                if name not in best:
                    order.append(name)
                    best[name] = (rank, value)
                elif rank > best[name][0]:
                    best[name] = (rank, value)
    except OSError:
        return ""
    return "; ".join(f"{name}={best[name][1]}" for name in order)


def _cookies_txt_header():
    """Cabecera Cookie a partir de cookies.txt: es lo que manda yt-dlp."""
    return _youtube_header()


def _session_state(header):
    """Comprueba de verdad si la sesion guardada sigue valiendo.

    Tener SAPISID no basta: YouTube contesta a una peticion de pagina hecha
    con cookies caducadas (o con la misma sesion usada desde otra red/IP)
    con un redirect a accounts.google.com/CookieMismatch. En ese caso yt-dlp
    no puede bajar la pagina y las listas fallan aunque la extraccion
    anonima funcione, asi que la app debe dejar de mandar esas cookies.

    Devuelve "ok", "expired" o "unknown" (sin red, 429, 5xx...: la sesion no
    se toca, porque el fallo puede ser de la red y no de las cookies).
    """

    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    req = urllib.request.Request(
        "https://www.youtube.com/", headers={"Cookie": header, "User-Agent": UA}
    )
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=15) as resp:
            return "ok" if resp.status < 400 else "unknown"
    except urllib.error.HTTPError as exc:
        loc = (exc.headers.get("Location") or "").lower()
        if "cookiemismatch" in loc or "servicelogin" in loc or "accounts.google.com" in loc:
            return "expired"
        return "unknown"
    except Exception:
        return "unknown"


def cmd_status():
    # cookies.txt is the source of truth (what yt-dlp reads); the header of
    # ytm_session.json is used when the Netscape file is not there. In both
    # cases only the YouTube cookies travel: mixing them with the google.com
    # ones made the server answer CookieMismatch and the session was taken
    # as expired on every restart.
    header = _cookies_txt_header() or _stored_header()
    if not _usable(header):
        out("STATUS error sin-sesion")
        return 1
    if _session_state(header) == "expired":
        out("STATUS error sesion-caducada")
        return 1
    out("STATUS ok")
    return 0


def _domain_ok(domain):
    d = (domain or "").lstrip(".").lower()
    return any(d == a or d.endswith("." + a) for a in AUTH_DOMAINS)


def _write_cookies(cookies):
    """cookies: list of WebKit2 cookie objects."""
    os.makedirs(CONFIG, exist_ok=True)
    rows = []
    for c in cookies:
        domain = c.get_domain() or ""
        if not _domain_ok(domain):
            continue
        name = c.get_name()
        value = c.get_value() or ""
        path = c.get_path() or "/"
        secure = "TRUE" if c.get_secure() else "FALSE"
        expires = c.get_expires()
        try:
            expires = int(expires.get_value() if expires is not None else 0)
        except Exception:
            expires = 0
        if expires < 0:
            expires = 0
        subdom = "TRUE" if domain.startswith(".") else "FALSE"
        rows.append((domain, subdom, path, secure, str(expires), name, value))

    # Most specific first, the way a browser does it.
    rows.sort(key=lambda r: (r[0].count("."), r[0]), reverse=True)

    header = "; ".join(f"{r[5]}={r[6]}" for r in rows)

    yt = {}
    yt_order = []
    for r in rows:
        domain = r[0].lstrip(".").lower()
        if not (domain == "youtube.com" or domain.endswith(".youtube.com")):
            continue
        name, value = r[5], r[6]
        rank = domain.count(".")
        if name not in yt:
            yt_order.append(name)
            yt[name] = (rank, value)
        elif rank > yt[name][0]:
            yt[name] = (rank, value)
    youtube_header = "; ".join(f"{name}={yt[name][1]}" for name in yt_order)

    # These files hold the user's YouTube session: never leave them at the
    # process umask, which is 0644 when the helper runs on its own.
    with open(COOKIE_FILE, "w", encoding="utf-8") as f:
        os.chmod(COOKIE_FILE, 0o600)
        f.write("# Netscape HTTP Cookie File\n")
        for r in rows:
            f.write("\t".join(r) + "\n")

    with open(SESSION_FILE, "w", encoding="utf-8") as f:
        os.chmod(SESSION_FILE, 0o600)
        json.dump(
            {
                "saved_at": int(time.time()),
                "cookie_header": header,
                "youtube_cookie_header": youtube_header,
                "cookie_count": len(rows),
            },
            f,
        )
    return header, len(rows)


# ---- Windows: use the browser session the user already has --------------
# WebKitGTK is Linux-only and the embedded Python of the Windows build has
# only the stdlib, so `import gi` made the helper exit before any STATUS line
# (the app showed "Sign in did not complete"). On Windows the real session
# already lives in the user's default browser: the bundled yt-dlp can export
# those cookies from the existing profile, with no new window and no fresh
# login. Only when there is no usable session do we open the sign-in URL with
# webbrowser.open(), which uses the browser the user chose as default.
# None of this runs on Linux: cmd_login() below keeps using WebKitGTK.
def _yt_dlp_program():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "yt-dlp.exe")


def _default_browser():
    """(executable, family) of the browser Windows uses for https links."""
    try:
        import winreg
        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice"
        ) as key:
            prog = winreg.QueryValueEx(key, "ProgId")[0]
        with winreg.OpenKey(
            winreg.HKEY_CLASSES_ROOT, prog + r"\shell\open\command"
        ) as key:
            cmd = winreg.QueryValueEx(key, "")[0]
        exe = cmd.lstrip()
        exe = exe[1:].split('"', 1)[0] if exe.startswith('"') else exe.split(" ", 1)[0]
        if os.path.isfile(exe):
            return exe, _browser_family(exe)
    except Exception:
        pass
    exe = _known_browser()
    return (exe, _browser_family(exe)) if exe else (None, None)


def _browser_family(exe):
    name = os.path.basename(exe).lower()
    if any(k in name for k in ("firefox", "zen", "waterfox", "librewolf")):
        return "gecko"
    return "chromium"


def _known_browser():
    roots = [
        os.environ.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)"),
        os.environ.get("PROGRAMFILES", r"C:\Program Files"),
        os.environ.get("LOCALAPPDATA", ""),
    ]
    rels = [
        ("Microsoft", "Edge", "Application", "msedge.exe"),
        ("Google", "Chrome", "Application", "chrome.exe"),
        ("Zen Browser", "zen.exe"),
        ("Mozilla Firefox", "firefox.exe"),
        ("BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
        ("Vivaldi", "Application", "vivaldi.exe"),
    ]
    for root in roots:
        for rel in rels:
            path = os.path.join(root, *rel)
            if os.path.isfile(path):
                return path
    for name in ("msedge", "chrome", "zen", "firefox", "brave", "vivaldi"):
        found = shutil.which(name)
        if found:
            return found
    return None


def _firefox_profile(root_name):
    root = os.path.join(
        os.environ.get("APPDATA", os.path.join(os.path.expanduser("~"), "AppData", "Roaming")),
        root_name, "Profiles")
    if not os.path.isdir(root):
        return None
    profiles = [
        os.path.join(root, d) for d in os.listdir(root)
        if os.path.isfile(os.path.join(root, d, "cookies.sqlite"))
    ]
    if not profiles:
        return None
    return max(profiles, key=lambda p: os.path.getmtime(os.path.join(p, "cookies.sqlite")))


def _browser_spec():
    """The --cookies-from-browser value for the default browser."""
    exe, family = _default_browser()
    if not exe:
        return None
    name = os.path.basename(exe).lower()
    if family == "gecko":
        root = "zen" if "zen" in name else "Mozilla"
        profile = _firefox_profile(root)
        return "firefox:" + profile if profile else "firefox"
    for key, spec in (("msedge", "edge"), ("chrome", "chrome"),
                      ("brave", "brave"), ("vivaldi", "vivaldi")):
        if key in name:
            return spec
    return "chrome"


class _RowCookie:
    """Adapt a Netscape cookies.txt row to the WebKit2 cookie interface."""

    def __init__(self, cols):
        self.cols = cols

    def get_domain(self):
        return self.cols[0]

    def get_name(self):
        return self.cols[5]

    def get_value(self):
        return self.cols[6]

    def get_path(self):
        return self.cols[2]

    def get_secure(self):
        return self.cols[3].upper() == "TRUE"

    def get_expires(self):
        try:
            value = int(self.cols[4])
        except ValueError:
            value = -1

        class _Expires:
            def get_value(self_inner):
                return value

        return _Expires()


def _export_browser_cookies(spec):
    """Ask the bundled yt-dlp to dump the live browser cookies to a temp file.

    http://127.0.0.1:1/ fails instantly offline: we only want the cookie
    export, not a download or a two-minute crawl of a YouTube feed.
    """
    ytdlp = _yt_dlp_program()
    if not os.path.isfile(ytdlp):
        return None
    tmp = os.path.join(STATE, "browser-cookies.txt")
    os.makedirs(STATE, exist_ok=True)
    try:
        os.remove(tmp)
    except OSError:
        pass
    try:
        subprocess.run(
            [ytdlp, "--cookies-from-browser", spec, "--cookies", tmp,
             "--simulate", "--skip-download", "--no-warnings", "http://127.0.0.1:1/"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    except Exception:
        pass
    return tmp if os.path.isfile(tmp) else None


def _cookies_from_file(path):
    rows = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if not line.strip() or line.startswith("#"):
                    continue
                cols = line.rstrip("\n").split("\t")
                if len(cols) >= 7 and _domain_ok(cols[0]):
                    rows.append(_RowCookie(cols))
    except OSError:
        pass
    return rows


def cmd_login_win(url=LOGIN_URL, timeout_min=12):
    spec = _browser_spec()
    if not spec:
        out("STATUS error sin-navegador")
        return 1

    out("LOGIN_URL accounts.google.com")
    deadline = time.time() + timeout_min * 60
    opened = False
    while time.time() < deadline:
        cookies = []
        path = _export_browser_cookies(spec)
        if path:
            cookies = _cookies_from_file(path)
            # The exported file holds the user's live cookies: never leave it
            # lying around in the app's state directory.
            try:
                os.remove(path)
            except OSError:
                pass
        if cookies:
            header, count = _write_cookies(cookies)
            if _usable(header):
                out(f"STATUS ok cookies={count}")
                return 0
        if not opened:
            # No session in the browser: open the sign-in page using the
            # browser the user already has (a tab in their window), not a
            # private profile launched from scratch.
            try:
                webbrowser.open(url)
            except Exception:
                pass
            opened = True
            out("STATUS esperando-login")
        time.sleep(3)
    out("STATUS error tiempo-agotado")
    return 1


def cmd_login(url=LOGIN_URL, timeout_min=12):
    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("WebKit2", "4.1")
    from gi.repository import Gtk, WebKit2, GLib

    os.makedirs(WEBKIT_DIR, exist_ok=True)
    os.makedirs(CONFIG, exist_ok=True)

    wdm = WebKit2.WebsiteDataManager(
        base_data_directory=WEBKIT_DIR,
        base_cache_directory=os.path.join(WEBKIT_DIR, "cache"),
    )
    ctx = WebKit2.WebContext(website_data_manager=wdm)
    ctx.get_cookie_manager().set_persistent_storage(
        os.path.join(WEBKIT_DIR, "cookies.sqlite"),
        WebKit2.CookiePersistentStorage.SQLITE,
    )
    view = WebKit2.WebView.new_with_context(ctx)
    view.get_settings().set_user_agent(UA)

    win = Gtk.Window(title="Lotus Tune - Iniciar sesion en YouTube Music")
    win.set_default_size(560, 760)
    win.add(view)

    state = {"done": False, "waiting": False, "deadline": None, "gone": False}

    def finish(ok, message):
        if state["done"]:
            return False
        state["done"] = True
        state["ok"] = ok
        if ok:
            out(f"STATUS ok cookies={message}")
        else:
            out(f"STATUS error {message}")
        GLib.idle_add(Gtk.main_quit)
        return False

    def receive(cm, res):
        try:
            cookies = cm.get_all_cookies_finish(res)
        except Exception as e:  # noqa: BLE001
            finish(False, f"cookies-fallo:{e}")
            return
        header, count = _write_cookies(cookies)
        if _usable(header):
            finish(True, count)
        elif time.time() > state["deadline"]:
            finish(False, "sin-sesion (no se obtuvo SAPISID)")
        else:
            GLib.timeout_add(600, poll)

    def poll():
        if state["done"] or state["gone"]:
            return False
        ctx.get_cookie_manager().get_all_cookies(None, receive)
        return False

    def on_decide(view_, decision, decision_type):
        return False

    def on_load(view_, event):
        if event != WebKit2.LoadEvent.FINISHED:
            return
        uri = view_.get_uri() or ""
        host = uri.split("/")[2] if "://" in uri else ""
        if host == "music.youtube.com":
            if not state["waiting"]:
                state["waiting"] = True
                state["deadline"] = time.time() + 20
                GLib.timeout_add(700, poll)
        else:
            out(f"NAV {uri}")
            if host.startswith("consent.") or host.startswith("accounts.google.com"):
                # Consent wall ("Before you continue to YouTube") and the intermediate
                # Google screens: press Accept only.
                js = (
                    "(function(){try{"
                    "var re=/acept|accept|agree|akkoord|akzept|acuerdo|aceitar/i;"
                    "var els=document.querySelectorAll('button,input[type=submit],[role=button]');"
                    "for(var i=0;i<els.length;i++){var e=els[i];"
                    "var t=(e.innerText||e.value||e.getAttribute('aria-label')||'');"
                    "if(re.test(e.textContent||'')||re.test(e.getAttribute('aria-label')||'')){e.click();return 'click';}}"
                    "return 'none';}catch(e){return 'err';}})()"
                )
                view_.run_javascript(js, None, None)

    view.connect("load-changed", on_load)
    view.connect("decide-policy", on_decide)

    def on_destroy(*_a):
        state["gone"] = True
        if not state["done"]:
            finish(False, "ventana-cerrada")
        return False

    win.connect("destroy", on_destroy)
    win.show_all()
    view.load_uri(url)
    out("LOGIN_URL accounts.google.com")

    GLib.timeout_add(timeout_min * 60 * 1000, lambda: finish(False, "tiempo-agotado"))
    Gtk.main()
    return 0 if state.get("ok") else 1


def main():
    ap = argparse.ArgumentParser(description="Lotus Tune - login de YouTube Music")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_login = sub.add_parser("login")
    p_login.add_argument("--add-account", action="store_true")
    sub.add_parser("refresh")
    sub.add_parser("status")
    args = ap.parse_args()

    if args.cmd == "status":
        return cmd_status()
    url = REFRESH_URL if args.cmd == "refresh" else (
        ADD_URL if args.add_account else LOGIN_URL)
    if WIN:
        return cmd_login_win(url=url)
    return cmd_login(url=url)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)