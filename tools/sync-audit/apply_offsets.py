import json, os, sys, glob, re

CONFIG = os.environ.get("LOTUS_CONFIG",
                        os.path.expanduser("~/.config/lotus-tune/lotus-tune.conf"))
CACHE = os.environ.get("LOTUS_LYRICS_CACHE",
                       os.path.expanduser("~/.cache/lotus-tune/lyrics"))
REPORT = os.environ.get("LOTUS_SYNC_REPORT", "/tmp/lotus-sync-audit/report.json")

def read_conf():
    lines = []
    if os.path.exists(CONFIG):
        lines = open(CONFIG, encoding="utf-8").read().splitlines()
    m = {}
    for line in lines:
        if "=" in line:
            k, v = line.split("=", 1)
            m[k] = v
    return lines, m

def read_map(m):
    raw = m.get("lyricsOffsetByTrack", '""')
    if raw.startswith('"') and raw.endswith('"'):
        raw = raw[1:-1].replace('\\"', '"')
    try:
        return json.loads(raw or "{}")
    except Exception:
        return {}

def save_map(m):
    lines, old = read_conf()
    value = json.dumps(m, ensure_ascii=False, separators=(",", ":"))
    encoded = '"' + value.replace('"', '\\"') + '"'
    out = []
    done = False
    for line in lines:
        if line.startswith("lyricsOffsetByTrack="):
            out.append("lyricsOffsetByTrack=" + encoded)
            done = True
        else:
            out.append(line)
    if not done:
        out.append("lyricsOffsetByTrack=" + encoded)
    tmp = CONFIG + ".tmp"
    open(tmp, "w", encoding="utf-8").write("\n".join(out) + "\n")
    os.replace(tmp, CONFIG)

def find_key(video_id):
    for f in glob.glob(os.path.join(CACHE, "*.json")):
        try:
            o = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        if o.get("videoId") == video_id:
            k = o.get("trackKey")
            if k:
                return k
            a, t = o.get("artist"), o.get("title")
            if a and t:
                return a + " - " + t
    return None

def all_keys(video_id):
    keys = []
    k = find_key(video_id)
    if k:
        keys.append(k)
    for f in glob.glob(os.path.join(CACHE, "*.json")):
        try:
            o = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        if o.get("videoId") == video_id and o.get("title") and o.get("artist"):
            keys.append(o["artist"] + " - " + o["title"])
    return list(dict.fromkeys(keys))

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else REPORT
    if os.path.exists(path):
        data = json.load(open(path, encoding="utf-8"))
    else:
        data = []
        log = os.environ.get("LOTUS_SYNC_LOG", "/tmp/lotus-sync-audit/analyze.log")
        for line in open(log, encoding="utf-8"):
            line = line.strip()
            if line.startswith("{"):
                try:
                    data.append(json.loads(line))
                except Exception:
                    pass
        print("using log rows:", len(data))
    _, conf = read_conf()
    m = read_map(conf)
    written = 0
    for d in data:
        if d.get("matched", 0) < 30:
            continue
        keys = all_keys(d["videoId"])
        if d.get("trackKey"):
            keys.insert(0, d["trackKey"])
        keys = list(dict.fromkeys(k for k in keys
                                  if k and k.strip(" -")))
        if not keys:
            continue
        delta = d["medianDelta"]
        # A chorus or a parenthetical verse makes the transcript start
        # seconds away from the stamps. That is not a drift: an offset that
        # large was observed to push the front the wrong way.
        if abs(delta) < 0.03 or abs(delta) > 1.0:
            continue
        # delta = audio time - lyrics time. A negative delta means the
        # lyrics are late. The player activates a word at pos + offset, so
        # advancing the front needs a positive compensation: invert delta.
        offset = round(-delta * 20) / 20
        for key in keys:
            # -4 s and 0 s are hand-set offsets; never overwrite them.
            if key in m and (abs(m[key]) >= 1.0 or m[key] == 0):
                print(d["videoId"], key, "kept manual", m[key])
                continue
            old = m.get(key)
            m[key] = max(-3.0, min(3.0, offset))
            written += 1
            print(d["videoId"], key, round(delta, 3), "->", m[key], "(old", old, ")")
    save_map(m)
    print("written:", written, "of", len(data))

if __name__ == "__main__":
    main()
