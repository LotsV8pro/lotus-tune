import json, glob, os, sys, re, subprocess
from difflib import SequenceMatcher

CACHE = os.environ.get("LOTUS_LYRICS_CACHE",
                       os.path.expanduser("~/.cache/lotus-tune/lyrics"))
AUDIO = os.environ.get("LOTUS_AUDIO_DIR", "/tmp/lotus-sync-audit/audio")
OUT = os.environ.get("LOTUS_SYNC_REPORT", "/tmp/lotus-sync-audit/report.json")

def norm(s):
    s = re.sub(r"[^a-z0-9']", "", s.lower().replace("’", "'"))
    return s.strip("'")

def similar(a, b):
    if a == b:
        return True
    if len(a) < 3 or len(b) < 3:
        return False
    return SequenceMatcher(None, a, b).ratio() >= 0.72

def ref_words(o):
    out = []
    for l in (o.get("lines") or []):
        if l.get("instrumental") or not l.get("w"):
            continue
        for w in l["w"]:
            t = norm(w.get("text", ""))
            if t:
                out.append((float(w.get("t", 0)), t))
    return out

def pair(ref, asr):
    n, m = len(ref), len(asr)
    if not n or not m:
        return []
    W = 60
    NEG = -1e9
    dp = [[NEG]*(m+1) for _ in range(n+1)]
    back = [[None]*(m+1) for _ in range(n+1)]
    dp[0][0] = 0.0
    for i in range(n+1):
        for j in range(max(0, i-W), min(m, i+W)+1):
            cur = dp[i][j]
            if cur == NEG:
                continue
            if i < n and j+1 <= m and cur-0.05 > dp[i][j+1]:
                dp[i][j+1] = cur-0.05
                back[i][j+1] = (i, j, "sa")
            if i+1 <= n and j < m and cur-0.05 > dp[i+1][j]:
                dp[i+1][j] = cur-0.05
                back[i+1][j] = (i, j, "sr")
            if i < n and j < m and similar(ref[i][1], asr[j][1]):
                d = asr[j][0]-ref[i][0]
                if abs(d) <= 1.2:
                    sc = 1.0-abs(d)*0.4
                    if cur+sc > dp[i+1][j+1]:
                        dp[i+1][j+1] = cur+sc
                        back[i+1][j+1] = (i, j, "m")
    i, j = n, m
    res = []
    while i > 0 and j > 0 and back[i][j]:
        pi, pj, k = back[i][j]
        if k == "m":
            res.append((ref[pi][0], ref[pi][1], asr[pj][0],
                        asr[pj][1], asr[pj][0]-ref[pi][0]))
        i, j = pi, pj
    return sorted(res, key=lambda x: x[2])

def main():
    from faster_whisper import WhisperModel
    device = os.environ.get("LOTUS_ASR_DEVICE", "cuda")
    compute = "float16" if device == "cuda" else "int8"
    model = WhisperModel(os.environ.get("LOTUS_ASR_MODEL", "small"),
                         device=device, compute_type=compute)
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 80
    done = []
    seen = set()
    for f in sorted(glob.glob(os.path.join(CACHE, "*.json"))):
        try:
            o = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        v = o.get("videoId")
        wav = os.path.join(AUDIO, v+".wav") if v else ""
        if not v or v in seen or not os.path.exists(wav):
            continue
        ref = ref_words(o)
        if len(ref) < 30:
            continue
        seen.add(v)
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        cache = wav + ".small.json"
        if os.path.exists(cache):
            d = json.load(open(cache))
            asr = [tuple(x) for x in d["words"]]
        else:
            segs, _ = model.transcribe(wav, word_timestamps=True,
                                       vad_filter=False, beam_size=5)
            asr = []
            for s in segs:
                for w in s.words or []:
                    t = norm(w.word)
                    if t:
                        asr.append((float(w.start), t))
            json.dump({"words": asr}, open(cache, "w"))
        pairs = pair(ref, asr)
        if len(pairs) < 20:
            continue
        deltas = sorted(x[4] for x in pairs)
        def pct(t):
            return round(100*sum(1 for d in deltas if abs(d) <= t)/len(deltas), 1)
        row = {
            "videoId": v,
            "trackKey": o.get("trackKey") or ((o.get("artist") or "") + " - " + (o.get("title") or "")),
            "refWords": len(ref), "asrWords": len(asr), "matched": len(pairs),
            "medianDelta": round(deltas[len(deltas)//2], 3),
            "p200": pct(0.2), "p350": pct(0.35), "p500": pct(0.5),
        }
        done.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
        if len(done) >= limit:
            break
    json.dump(done, open(OUT, "w"), ensure_ascii=False, indent=2)

if __name__ == "__main__":
    main()
