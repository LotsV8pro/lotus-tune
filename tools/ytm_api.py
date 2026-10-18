#!/usr/bin/env python3
"""Lotus Tune -- cliente de la API interna de YouTube Music.

Lee las cookies del login integrado (~/.config/lotus-tune/cookies.txt, formato
Netscape) y consulta la API interna de YouTube Music (InnerTube) para:

  library                     playlists guardadas/creadas del usuario
  playlist <listId>           tracks de una playlist (rápido, sin yt-dlp)
  playlistinfo <listId>       título/descripción/privacidad/propiedad de una lista
  rate  <videoId> <rating>    vota LIKE | DISLIKE | INDIFFERENT
  addpl <playlistId> <videoId>
                              añade una pista a una playlist del usuario
  rmpl  <playlistId> <videoId> <setVideoId>
                              quita una pista de una playlist del usuario
  createpl <title> [priv]     crea una lista (priv=1 -> privada; por defecto pública)
  renamepl <listId> <title> [priv]
                              renombra una lista propia (y opcionalmente su privacidad)
  setplpriv <listId> <priv>   pone la lista privada (priv=1) o pública (priv=0)
  deletepl <listId>           elimina una lista propia

Solo stdlib: urllib, hashlib, json.

Salida:
  library   -> [{"name","id","thumb","count","owned"}, ...] por stdout
  playlist  -> {"entries":[{"id","title","url","channel","duration","thumbnail","setVideoId"}, ...]}
  playlistinfo -> {"id","title","description","privacy","owned","count"} por stdout
  rate/addpl/rmpl/createpl/renamepl/setplpriv/deletepl -> {"status": ...} por stdout
  createpl -> {"status":"ok","id":"<nueva lista>"} por stdout
En caso de error escribe el motivo en stderr y sale con código 2.
"""

import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

CONFIG = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "lotus-tune"
)
COOKIE_FILE = os.path.join(CONFIG, "cookies.txt")

API_KEY = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
BASE_URL = "https://music.youtube.com/youtubei/v1/"
ORIGIN = "https://music.youtube.com"
CLIENT_VERSION = "1.20240101.01.00"

# Puntos de entrada: el primero es la página "mis listas"; los demás son
# alternativas por si la API cambia el browseId o devuelve vacío.
LIBRARY_IDS = (
    "FEmusic_liked_playlists",
    "FEmusic_library_landing",
    "FEmusic_library_privately_owned_playlists",
)

SAPISID_NAMES = ("SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID")

LIKE_STATUSES = ("LIKE", "DISLIKE", "INDIFFERENT")

_DUR_RE = re.compile(r"(?:(\d+):)?(\d+):(\d{2})")


class YtmError(Exception):
    """Error de sesión o de la API de YouTube Music."""


# --------------------------------------------------------------- cookies ----

def read_cookies():
    """Devuelve [(name, value)] de cookies.txt válidas de YouTube.

    Se excluyen las de google.com: al enviarlas junto a las de youtube.com el
    servidor recibe dos cookies SAPISID y rechaza la firma (logged_in=0).
    """
    cookies = []
    try:
        with open(COOKIE_FILE, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError as exc:
        raise YtmError("no se pudo leer cookies.txt: %s" % exc)

    for line in lines:
        line = line.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 7:
            continue
        domain = cols[0].lstrip(".").lower()
        if not (domain == "youtube.com" or domain.endswith(".youtube.com")):
            continue
        cookies.append((cols[5], cols[6]))
    if not cookies:
        raise YtmError("cookies.txt no contiene cookies de YouTube")
    return cookies


def sapisid_from(cookies):
    for want in SAPISID_NAMES:
        for name, value in cookies:
            if name == want and value:
                return value
    raise YtmError("cookies.txt no contiene SAPISID")


def authorization(sapisid):
    ts = str(int(time.time()))
    digest = hashlib.sha1(
        ("%s %s %s" % (ts, sapisid, ORIGIN)).encode("utf-8")
    ).hexdigest()
    return "SAPISIDHASH %s_%s" % (ts, digest)


# ------------------------------------------------------------------ api ----

def post_json(endpoint, body):
    """POST autenticado a un endpoint de youtubei/v1 y devuelve el JSON."""
    cookies = read_cookies()
    cookie_header = "; ".join("%s=%s" % (n, v) for n, v in cookies)
    auth = authorization(sapisid_from(cookies))

    body["context"] = {
        "client": {
            "clientName": "WEB_REMIX",
            "clientVersion": CLIENT_VERSION,
            "hl": "es",
            "gl": "ES",
        }
    }
    req = urllib.request.Request(
        "%s%s?key=%s&prettyPrint=false" % (BASE_URL, endpoint, API_KEY),
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": auth,
            "Cookie": cookie_header,
            "X-Goog-Api-Format-Version": "1",
            "Origin": ORIGIN,
            "Referer": ORIGIN + "/",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        raise YtmError("HTTP %s en %s" % (exc.code, endpoint))
    except urllib.error.URLError as exc:
        raise YtmError("sin conexión: %s" % exc.reason)
    try:
        return json.loads(raw)
    except ValueError:
        raise YtmError("respuesta ilegible de %s" % endpoint)


def browse(browse_id):
    """browse() público (mantiene nombre/compatibilidad internos)."""
    return post_json("browse", {"browseId": browse_id})


# -------------------------------------------------------------- parsing ----

def _best_thumb(node):
    """URL de mayor resolución disponible en un thumbnailRenderer/thumbnail."""
    thumbs = []
    if isinstance(node, dict):
        # musicTwoRowItemRenderer usa thumbnailRenderer.musicThumbnailRenderer;
        # musicResponsiveListItemRenderer usa thumbnail.musicThumbnailRenderer.
        renderer = node.get("musicThumbnailRenderer")
        if not renderer:
            renderer = node.get("thumbnailRenderer", {}).get("musicThumbnailRenderer")
        # playlistVideoRenderer guarda las miniaturas en thumbnail.thumbnails.
        if not renderer:
            thumb_root = node.get("thumbnail")
            if isinstance(thumb_root, dict):
                renderer = thumb_root.get("musicThumbnailRenderer") or thumb_root
        if renderer:
            thumbs = (
                renderer.get("thumbnail", {}).get("thumbnails", []) or []
            )
    if thumbs:
        # La API ordena de menor a mayor resolución: la última es la mejor.
        return thumbs[-1].get("url", "")
    return ""


def _title_of(renderer):
    title = renderer.get("title")
    if isinstance(title, dict):
        runs = title.get("runs") or []
        if runs:
            return (runs[0].get("text") or "").strip()
        if title.get("simpleText"):
            return title["simpleText"].strip()
    return ""


def _browse_id_of(renderer):
    nav = renderer.get("navigationEndpoint") or {}
    browse = nav.get("browseEndpoint") or {}
    return browse.get("browseId") or ""


def _menu_icon_types(renderer):
    """Tipos de icono del menú contextual de un renderer (EDITED/DELETE...).

    En "mis listas" una lista PROPIA trae las acciones EDIT y DELETE; una lista
    de otro (guardada de alguien) no. Sirve para saber a qué listas se les puede
    renombrar/eliminar."""
    icons = set()
    menu = renderer.get("menu") or {}
    mr = menu.get("menuRenderer") or {}
    for item in mr.get("items") or []:
        for key in ("menuNavigationItemRenderer", "menuServiceItemRenderer"):
            ri = item.get(key)
            if isinstance(ri, dict):
                it = (ri.get("icon") or {}).get("iconType")
                if it:
                    icons.add(it)
    return icons


def _collect(node, found, seen):
    """Recorre recursivamente el JSON y recoge playlists."""
    if isinstance(node, dict):
        for key in ("musicTwoRowItemRenderer", "musicResponsiveListItemRenderer"):
            renderer = node.get(key)
            if isinstance(renderer, dict):
                bid = _browse_id_of(renderer)
                name = _title_of(renderer)
                # Solo listas: su browseId empieza por "VL" (VL + id de lista).
                if bid.startswith("VL") and name:
                    pid = bid[2:]
                    if pid not in seen:
                        seen.add(pid)
                        icons = _menu_icon_types(renderer)
                        found.append(
                            {
                                "name": name,
                                "id": pid,
                                "thumb": _best_thumb(renderer),
                                "owned": "EDIT" in icons or "DELETE" in icons,
                            }
                        )
        for value in node.values():
            _collect(value, found, seen)
    elif isinstance(node, list):
        for item in node:
            _collect(item, found, seen)


# --------------------------------------------------- tracks de playlist ----

def _flex_text(renderer, index):
    """Texto plano de la columna flexColumns[n] (título=0, artista=1...)."""
    cols = renderer.get("flexColumns") or []
    if index >= len(cols):
        return ""
    col = cols[index].get("musicResponsiveListItemFlexColumnRenderer") or {}
    text = col.get("text") or {}
    runs = text.get("runs") or []
    if runs:
        return "".join(r.get("text", "") for r in runs).strip()
    return (text.get("simpleText") or "").strip()


def _length_text(renderer):
    """Texto de duración ("3:45", "1:02:15"...) de un track de playlist."""
    candidates = []
    fixed = renderer.get("fixedColumns") or []
    for col in fixed:
        coll = col.get("musicResponsiveListItemFixedColumnRenderer") or {}
        text = coll.get("text") or {}
        runs = text.get("runs") or []
        if runs:
            candidates.extend(r.get("text", "") for r in runs)
        elif text.get("simpleText"):
            candidates.append(text["simpleText"])
    # playlistVideoRenderer usa lengthText o overlay.
    overlay = renderer.get("overlay") or {}

    def _walk(obj):
        if isinstance(obj, dict):
            for k, v in obj.items():
                if k == "text" and isinstance(v, str):
                    candidates.append(v)
                else:
                    _walk(v)
        elif isinstance(obj, list):
            for it in obj:
                _walk(it)

    _walk(overlay)
    lt = renderer.get("lengthText")
    if isinstance(lt, dict):
        _walk(lt)
    for val in candidates:
        if _DUR_RE.match(val.strip()):
            return val.strip()
    return ""


def _parse_duration(text):
    m = _DUR_RE.match(text.strip())
    if not m:
        return 0.0
    h, mte, ss = (int(m.group(1) or 0), int(m.group(2)), int(m.group(3)))
    return float(h * 3600 + mte * 60 + ss)


def _find_key(node, wanted):
    """Devuelve el primer valor de la clave `wanted` en un subárbol."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == wanted:
                return v
            r = _find_key(v, wanted)
            if r is not None:
                return r
    elif isinstance(node, list):
        for item in node:
            r = _find_key(item, wanted)
            if r is not None:
                return r
    return None


def _video_id_of(renderer):
    """videoId de un track de playlist (music o playlistVideo renderer)."""
    # playlistItemData.videoId es el campo canónico del shelf de música.
    pid = renderer.get("playlistItemData") or {}
    if pid.get("videoId"):
        return pid["videoId"]
    # navigationEndpoint.watchEndpoint (top-level, musicResponsiveListItem)
    nav = renderer.get("navigationEndpoint") or {}
    if (nav.get("watchEndpoint") or {}).get("videoId"):
        return nav["watchEndpoint"]["videoId"]
    # overlay.playNavigationEndpoint.watchEndpoint (mismo renderer).
    overlay = renderer.get("overlay") or {}
    play_nav = overlay.get("content", {}) \
                     .get("musicPlayButtonRenderer", {}) \
                     .get("playNavigationEndpoint") or {}
    if (play_nav.get("watchEndpoint") or {}).get("videoId"):
        return play_nav["watchEndpoint"]["videoId"]
    # renderer plano (playlistVideoRenderer).
    return renderer.get("videoId") or ""


def _set_video_id_of(renderer):
    """setVideoId (id de la fila dentro de la lista) o vacío."""
    pid = renderer.get("playlistItemData") or {}
    if pid.get("playlistSetVideoId"):
        return pid["playlistSetVideoId"]
    raw = _find_key(renderer, "playlistSetVideoId")
    if isinstance(raw, str) and raw:
        return raw
    raw2 = renderer.get("setVideoId")
    return raw2 if isinstance(raw2, str) else ""


def _like_status_of(renderer):
    """likeStatus de la pista ('LIKE'/'DISLIKE'/'INDIFFERENT'), o vacío.

    Vive en menu.menuRenderer.topLevelButtons[].likeButtonRenderer.likeStatus,
    el mismo sitio que usa ytmusicapi. Sólo aparece con sesión iniciada.
    """
    menu = renderer.get("menu") or {}
    top = (menu.get("menuRenderer") or {}).get("topLevelButtons") or []
    for button in top:
        like = button.get("likeButtonRenderer")
        if like:
            status = like.get("likeStatus")
            return status if isinstance(status, str) else ""
    return ""


def _track_of(renderer):
    """Convierte un renderer de track (music/playlist o playlistVideo) a mapa."""
    video_id = _video_id_of(renderer)
    if not video_id:
        return None

    title = _title_of(renderer)
    if not title:
        title = _flex_text(renderer, 0)
    if not title:
        return None

    artist = ""
    # musicResponsiveListItemRenderer: columna 1 = artista(es).
    byline = _flex_text(renderer, 1)
    if byline:  # separadores "·" entre artistas en YT Music
        artist = re.sub(r"\s*[·,]\s*", ", ", byline).strip(" -,")
    if not artist:
        # playlistVideoRenderer usa shortBylineText.runs[].text
        sb = renderer.get("shortBylineText") or {}
        runs = sb.get("runs") or []
        if runs:
            artist = "".join(r.get("text", "") for r in runs).strip()
    if not artist:
        artist = _flex_text(renderer, 2)

    duration = _parse_duration(_length_text(renderer))
    set_video_id = _set_video_id_of(renderer)

    return {
        "id": video_id,
        "title": title,
        "url": "https://www.youtube.com/watch?v=" + video_id,
        "webpage_url": "https://music.youtube.com/watch?v=" + video_id,
        "channel": artist,
        "duration": duration,
        "thumbnail": _best_thumb(renderer),
        "setVideoId": set_video_id,
        "likeStatus": _like_status_of(renderer),
    }


def _collect_tracks(node, found, seen):
    """Recoge tracks de musicResponsiveListItemRenderer/playlistVideoRenderer."""
    if isinstance(node, dict):
        for key in ("musicResponsiveListItemRenderer", "playlistVideoRenderer"):
            renderer = node.get(key)
            if isinstance(renderer, dict):
                t = _track_of(renderer)
                if t and t["id"] not in seen:
                    seen.add(t["id"])
                    found.append(t)
        for value in node.values():
            _collect_tracks(value, found, seen)
    elif isinstance(node, list):
        for item in node:
            _collect_tracks(item, found, seen)


def _token_from_items(items):
    """Token de continuación del último continuationItemRenderer de una lista.

    Es el token REAL de la lista de pistas (a diferencia del token de sección,
    que en las playlists lleva a «Sugerencias»)."""
    if not items:
        return None
    last = items[-1]
    cir = last.get("continuationItemRenderer") or {}
    ep = cir.get("continuationEndpoint") or {}
    cmd = ep.get("continuationCommand") or {}
    token = cmd.get("token")
    if isinstance(token, str) and token:
        return token
    commands = ((ep.get("commandExecutorCommand") or {}).get("commands")) or []
    for c in commands:
        cc = c.get("continuationCommand") or {}
        if cc.get("request") == "CONTINUATION_REQUEST_TYPE_BROWSE":
            t = cc.get("token")
            if isinstance(t, str) and t:
                return t
    return None


def _continuation_items(resp):
    """Items de una respuesta de continuación de playlist."""
    for action in resp.get("onResponseReceivedActions") or []:
        items = (action.get("appendContinuationItemsAction") or {}).get(
            "continuationItems"
        )
        if items:
            return items
    shelf = _find_key(resp, "musicPlaylistShelfContinuation")
    if isinstance(shelf, dict):
        return shelf.get("contents") or []
    return []


def playlist(list_id):
    """Tracks de una playlist (browse VL<id> + continuaciones). Rápido.

    Se ciñe al musicPlaylistShelfRenderer (la lista de pistas real) y a su
    token de continuación, para NO colar las «Sugerencias» ni los «relacionados»
    que la página trae aparte."""
    tracks, seen = [], set()
    resp = browse("VL" + list_id)
    shelf = _find_key(resp, "musicPlaylistShelfRenderer")
    if not isinstance(shelf, dict):
        # Listas sin shelf (p. ej. algunas automáticas): se recoge del árbol.
        found = []
        _collect_tracks(resp, found, seen)
        return found

    items = shelf.get("contents") or []
    found = []
    _collect_tracks(items, found, seen)
    tracks.extend(found)

    token = _token_from_items(items)
    for _ in range(50):
        if not token:
            break
        r = post_json("browse", {"continuation": token})
        items = _continuation_items(r)
        found = []
        _collect_tracks(items, found, seen)
        if not found:
            break
        tracks.extend(found)
        token = _token_from_items(items)
    return tracks


def search(query, limit=40):
    """Búsqueda de canciones en YT Music (endpoint search). Rápido (~0.5 s).

    Devuelve las pistas (canciones + vídeos) en orden de relevancia. Se usa la
    vía interna en vez de arrancar yt-dlp (que tarda ~2.4 s en extraer lo mismo):
    es lo que hace que «buscar» sea casi instantáneo. Los álbumes, listas y
    artistas del resultado se ignoran a propósito: la app busca canciones."""
    resp = post_json("search", {"query": query})
    tracks, seen = [], set()
    _collect_tracks(resp, tracks, seen)
    return tracks[:limit]


def library():
    """Playlists guardadas/creadas del usuario."""
    for browse_id in LIBRARY_IDS:
        data = browse(browse_id)
        found, seen = [], set()
        _collect(data, found, seen)
        if found:
            return found
    return []


def _description_of(header):
    """Texto de la descripción de una lista (musicDescriptionShelfRenderer)."""
    if not isinstance(header, dict):
        return ""
    node = header.get("description") or {}
    shelf = node.get("musicDescriptionShelfRenderer") or {}
    desc = shelf.get("description") or {}
    runs = desc.get("runs") or []
    if runs:
        return "".join(r.get("text", "") for r in runs).strip()
    return (desc.get("simpleText") or "").strip()


def playlist_info(list_id):
    """Metadatos de una lista: título, descripción, privacidad y propiedad.

    La privacidad ("PUBLIC"/"PRIVATE"/"UNLISTED") y la propiedad sólo se pueden
    leer de una lista PROPIA: la página trae entonces
    musicEditablePlaylistDetailHeaderRenderer con un campo `privacy`."""
    data = browse("VL" + list_id)
    editable = _find_key(data, "musicEditablePlaylistDetailHeaderRenderer")
    owned = editable is not None
    header = None
    if owned:
        header = _find_key(editable, "musicResponsiveHeaderRenderer")
    if header is None:
        header = _find_key(data, "musicDetailHeaderRenderer")
    if header is None:
        header = _find_key(data, "musicResponsiveHeaderRenderer")

    count = 0
    if isinstance(header, dict):
        st2 = header.get("secondSubtitle") or {}
        text = "".join(r.get("text", "") for r in (st2.get("runs") or []))
        m = re.search(r"(\d[\d.,]*)\s+(?:pistas|songs|tracks|videos|canci)", text)
        if m:
            count = int(re.sub(r"[^\d]", "", m.group(1)) or 0)

    return {
        "id": list_id,
        "title": _title_of(header) if isinstance(header, dict) else "",
        "description": _description_of(header),
        "privacy": (_find_key(editable, "privacy") or "") if owned else "",
        "owned": owned,
        "count": count,
    }


# ------------------------------------------------------------- gestión -----

PRIVACY_STATUSES = ("PUBLIC", "PRIVATE", "UNLISTED")


def create_playlist(title, private):
    """Crea una lista (pública por defecto) y devuelve su id."""
    title = (title or "").strip()
    if not title:
        raise YtmError("la lista necesita un nombre")
    body = {
        "title": title,
        "description": "",
        "privacyStatus": "PRIVATE" if private else "PUBLIC",
    }
    resp = post_json("playlist/create", body)
    playlist_id = resp.get("playlistId")
    if not playlist_id:
        raise YtmError("no se pudo crear la lista")
    return playlist_id


def edit_playlist(playlist_id, title=None, privacy=None):
    """Renombra y/o cambia la privacidad de una lista propia."""
    actions = []
    if title:
        actions.append(
            {"action": "ACTION_SET_PLAYLIST_NAME", "playlistName": title}
        )
    if privacy:
        privacy = privacy.upper()
        if privacy not in PRIVACY_STATUSES:
            raise YtmError("privacidad inválida: %s" % privacy)
        actions.append(
            {"action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": privacy}
        )
    if not actions:
        return {"status": "ok"}
    return post_json(
        "browse/edit_playlist", {"playlistId": playlist_id, "actions": actions}
    )


def delete_playlist(playlist_id):
    """Elimina una lista propia."""
    return post_json("playlist/delete", {"playlistId": playlist_id})


# ----------------------------------------------------------- interacción ----

def rate(video_id, rating):
    """Vota una canción (LIKE/DISLIKE/INDIFFERENT)."""
    rating = (rating or "").upper()
    if rating not in LIKE_STATUSES:
        raise YtmError("rating debe ser LIKE, DISLIKE o INDIFFERENT")
    if rating == "LIKE":
        endpoint = "like/like"
    elif rating == "DISLIKE":
        endpoint = "like/dislike"
    else:
        endpoint = "like/removelike"
    return post_json(endpoint, {"target": {"videoId": video_id}})


def add_playlist_item(playlist_id, video_id):
    """Añade una pista a una playlist del usuario (debe ser VL... propietaria)."""
    return post_json(
        "browse/edit_playlist",
        {
            "playlistId": playlist_id,
            "actions": [
                {"action": "ACTION_ADD_VIDEO", "addedVideoId": video_id}
            ],
        },
    )


def remove_playlist_item(playlist_id, video_id, set_video_id):
    """Quita una pista de una playlist del usuario (requiere setVideoId)."""
    if not set_video_id:
        raise YtmError("falta setVideoId (consulta primero playlist)")
    return post_json(
        "browse/edit_playlist",
        {
            "playlistId": playlist_id,
            "actions": [
                {
                    "action": "ACTION_REMOVE_VIDEO",
                    "removedVideoId": video_id,
                    "setVideoId": set_video_id,
                }
            ],
        },
    )


def move_playlist_item(playlist_id, set_video_id, neighbor_set_video_id, before):
    """Reordena una pista dentro de una playlist propia.

    `before` = True  -> mueve la pista JUSTO ANTES del vecino.
    `before` = False -> la mueve JUSTO DESPUÉS del vecino (ACTION_MOVE_VIDEO_AFTER).
    """
    if not set_video_id or not neighbor_set_video_id:
        raise YtmError("faltan setVideoId para reordenar")
    if before:
        action = {
            "action": "ACTION_MOVE_VIDEO_BEFORE",
            "setVideoId": set_video_id,
            "movedSetVideoIdSuccessor": neighbor_set_video_id,
        }
    else:
        action = {
            "action": "ACTION_MOVE_VIDEO_AFTER",
            "setVideoId": set_video_id,
            "movedSetVideoIdPredecessor": neighbor_set_video_id,
        }
    return post_json(
        "browse/edit_playlist",
        {"playlistId": playlist_id, "actions": [action]},
    )


# ------------------------------------------------------------------- cli ----

def cmd_library():
    items = library()
    json.dump(items, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_playlist(list_id):
    tracks = playlist(list_id)
    json.dump({"entries": tracks}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_search(query):
    tracks = search(query)
    json.dump({"entries": tracks}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_rate(video_id, rating):
    resp = rate(video_id, rating)
    json.dump({"status": resp.get("status", "ok")}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_addpl(playlist_id, video_id):
    resp = add_playlist_item(playlist_id, video_id)
    json.dump({"status": resp.get("status", "ok")}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_rmpl(playlist_id, video_id, set_video_id):
    resp = remove_playlist_item(playlist_id, video_id, set_video_id)
    json.dump({"status": resp.get("status", "ok")}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_movepl(playlist_id, set_video_id, neighbor_set_video_id, before):
    resp = move_playlist_item(playlist_id, set_video_id, neighbor_set_video_id,
                              before)
    json.dump({"status": resp.get("status", "ok")}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_playlistinfo(list_id):
    info = playlist_info(list_id)
    json.dump(info, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_createpl(title, private):
    playlist_id = create_playlist(title, private)
    json.dump({"status": "ok", "id": playlist_id}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_renamepl(list_id, title, privacy=None):
    resp = edit_playlist(list_id, title=title, privacy=privacy)
    json.dump({"status": resp.get("status", "ok")}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_setplpriv(list_id, private):
    resp = edit_playlist(list_id, privacy="PRIVATE" if private else "PUBLIC")
    json.dump({"status": resp.get("status", "ok")}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_deletepl(list_id):
    resp = delete_playlist(list_id)
    json.dump({"status": resp.get("status", "ok")}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def _truthy(value):
    return str(value).strip().lower() in ("1", "true", "priv", "private", "privada")


def main():
    args = sys.argv[1:]
    if not args:
        print(
            "uso: ytm_api.py library | search <q> | playlist <id> | "
            "playlistinfo <id> | "
            "rate <v> <r> | addpl <p> <v> | rmpl <p> <v> <s> | "
            "createpl <title> [priv] | renamepl <id> <title> | "
            "setplpriv <id> <priv> | deletepl <id>",
            file=sys.stderr,
        )
        return 2
    cmd = args[0]
    try:
        if cmd == "library":
            return cmd_library()
        if cmd == "search":
            if len(args) < 2:
                raise YtmError("falta la consulta de búsqueda")
            return cmd_search(" ".join(args[1:]))
        if cmd == "playlist":
            if len(args) < 2:
                raise YtmError("falta el id de la playlist")
            return cmd_playlist(args[1])
        if cmd == "playlistinfo":
            if len(args) < 2:
                raise YtmError("falta el id de la playlist")
            return cmd_playlistinfo(args[1])
        if cmd == "rate":
            if len(args) < 3:
                raise YtmError("uso: rate <videoId> <LIKE|DISLIKE|INDIFFERENT>")
            return cmd_rate(args[1], args[2])
        if cmd == "addpl":
            if len(args) < 3:
                raise YtmError("uso: addpl <playlistId> <videoId>")
            return cmd_addpl(args[1], args[2])
        if cmd == "rmpl":
            if len(args) < 4:
                raise YtmError("uso: rmpl <playlistId> <videoId> <setVideoId>")
            return cmd_rmpl(args[1], args[2], args[3])
        if cmd == "movepl":
            if len(args) < 5:
                raise YtmError("uso: movepl <playlistId> <setVideoId> "
                               "<vecinoSetVideoId> <before|after>")
            return cmd_movepl(args[1], args[2], args[3],
                              args[4].lower() == "before")
        if cmd == "createpl":
            if len(args) < 2:
                raise YtmError("uso: createpl <title> [priv]")
            return cmd_createpl(args[1], _truthy(args[2]) if len(args) > 2 else False)
        if cmd == "renamepl":
            if len(args) < 3:
                raise YtmError("uso: renamepl <listId> <title> [priv]")
            priv = None
            if len(args) > 3:
                priv = "PRIVATE" if _truthy(args[3]) else "PUBLIC"
            return cmd_renamepl(args[1], args[2], priv)
        if cmd == "setplpriv":
            if len(args) < 3:
                raise YtmError("uso: setplpriv <listId> <priv>")
            return cmd_setplpriv(args[1], _truthy(args[2]))
        if cmd == "deletepl":
            if len(args) < 2:
                raise YtmError("uso: deletepl <listId>")
            return cmd_deletepl(args[1])
        raise YtmError("comando desconocido: %s" % cmd)
    except YtmError as exc:
        print("ytm_api: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)