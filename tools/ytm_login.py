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
import json
import os
import sys
import time

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

# Google rechaza inicios de sesion desde navegadores embebidos que no reconoce.
# WebKitGTK comparte motor con Safari, asi que nos identificamos como Safari/mac.
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


def _stored_header():
    try:
        with open(SESSION_FILE, "r", encoding="utf-8") as f:
            return json.load(f).get("cookie_header", "")
    except Exception:
        return ""


def cmd_status():
    header = _stored_header()
    if not header:
        try:
            with open(COOKIE_FILE, "r", encoding="utf-8") as f:
                names = [
                    ln.split("\t")[5]
                    for ln in f
                    if ln.strip() and not ln.startswith("#") and len(ln.split("\t")) >= 7
                ]
            header = "; ".join(names)
        except Exception:
            header = ""
    if _usable(header):
        out("STATUS ok")
        return 0
    out("STATUS error sin-sesion")
    return 1


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

    # Mas especifico primero, como hace un navegador.
    rows.sort(key=lambda r: (r[0].count("."), r[0]), reverse=True)

    header = "; ".join(f"{r[5]}={r[6]}" for r in rows)

    with open(COOKIE_FILE, "w", encoding="utf-8") as f:
        f.write("# Netscape HTTP Cookie File\n")
        for r in rows:
            f.write("\t".join(r) + "\n")

    with open(SESSION_FILE, "w", encoding="utf-8") as f:
        json.dump(
            {
                "saved_at": int(time.time()),
                "cookie_header": header,
                "cookie_count": len(rows),
            },
            f,
        )
    return header, len(rows)


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
                # Muro de consentimiento ("Antes de continuar en YouTube") y
                # pantallas intermedias de Google: pulsar Aceptar solo.
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
    if args.cmd == "refresh":
        return cmd_login(url=REFRESH_URL)
    return cmd_login(url=ADD_URL if args.add_account else LOGIN_URL)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)