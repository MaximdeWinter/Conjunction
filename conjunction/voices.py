"""The game's voiced lines: every line of every scene (.w2scene) with who speaks it, how long and its text - so a
dialogue line of a quest can reuse one (radish: a line "0001011351|text" plays the game's own voice and lip sync).

    voices.sqlite  lines(id, speaker, dur, scene, text)   built once from the game (a minute), then searched
"""
import os
import sqlite3
import struct

from . import config

DB = os.path.join(os.path.dirname(config.PATH), "voices.sqlite")
VERSION = 1
GERALT = "GERALT"
# words that say nothing about a line (a search by a whole sentence ranks by the others)
COMMON = set("the and you your for are was were that this with have has had not but they them their there what "
             "who how why when where will would could should can just all out from into about his her him she he "
             "its it's i'm i'll don't won't can't our ours we us me my mine yes".split())


def build(log=print):
    """Read every scene of the game: its lines (voice tag, approved duration, string id) joined with the texts."""
    from .assets import LANG, _cr2w_parts, read_strings
    from .bundles import Depot
    depot = Depot()
    texts, _keys = read_strings(LANG, log)
    files = [p for p in depot.where if p.endswith(".w2scene")]
    rows = {}
    for n, p in enumerate(files):
        if n % 1000 == 0:
            log(f"[voices] scenes {n} / {len(files)}")
        try:
            f = _cr2w_parts(depot.read(p))[0]
        except Exception:                               # noqa: BLE001
            continue
        for cls, _fl, _parent, _tmpl, chunk in f.exports:
            if cls != "CStorySceneLine":
                continue
            line = {}
            for name, tp, off, _sz in f.props(chunk):
                if name == "voicetag" and tp == "CName":
                    line["speaker"] = f.names[struct.unpack_from("<H", chunk, off)[0]]
                elif name == "dialogLine" and tp == "LocalizedString":
                    line["id"] = struct.unpack_from("<I", chunk, off)[0]
                elif name == "approvedDuration" and tp == "Float":
                    line["dur"] = struct.unpack_from("<f", chunk, off)[0]
            sid = line.get("id")
            text = texts.get(sid, "").strip()
            if not sid or not text or not line.get("speaker") or sid in rows:
                continue
            rows[sid] = (sid, line["speaker"].upper(), round(line.get("dur", 0.0), 3), p, text)
    tmp = DB + ".new"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.execute("create table lines (id integer primary key, speaker text, dur real, scene text, text text)")
    db.execute("create table meta (key text primary key, value text)")
    db.executemany("insert into lines values (?, ?, ?, ?, ?)", rows.values())
    db.execute("create index lines_speaker on lines (speaker)")
    db.execute("insert into meta values ('version', ?)", (str(VERSION),))
    db.commit()
    db.close()
    os.replace(tmp, DB)
    log(f"[voices] {len(rows)} voiced lines")
    return len(rows)


def ready():
    if not os.path.exists(DB):
        return False
    try:
        v = sqlite3.connect(DB).execute("select value from meta where key='version'").fetchone()
        return bool(v) and int(v[0]) == VERSION
    except sqlite3.Error:
        return False


class Voices:
    """Searching the voiced lines (read into memory: a rebuild can replace the file meanwhile)."""

    def __init__(self):
        src = sqlite3.connect(DB)
        self.db = sqlite3.connect(":memory:", check_same_thread=False)
        src.backup(self.db)
        src.close()
        self.db.row_factory = sqlite3.Row

    def search(self, text, speaker=None, others=False, limit=40, geralt=None):
        """Lines with all the words first (short lines first: "hm" finds "Hm." before a speech that contains it),
        then lines with most of them (a whole sentence of one's own still finds lines close to it).
        speaker: only that voicetag's lines (the player: GERALT, CIRILLA); others: everybody but the playable
        characters; neither: all. (geralt True / False: the older call.)"""
        if geralt is True:
            speaker = GERALT
        elif geralt is False:
            others = True
        words = [w for w in "".join(c if c.isalnum() or c == "'" else " " for c in text.lower()).split() if w]
        who, who_args = "", []
        if speaker:
            who, who_args = " and speaker = ?", [speaker]
        elif others:
            from .dialogue import PLAYERS
            tags = [p["voicetag"] for p in PLAYERS.values()]
            who, who_args = " and speaker not in (" + ",".join("?" * len(tags)) + ")", tags
        sql = "select * from lines where " + " and ".join(["lower(text) like ?"] * len(words) or ["1"]) + who + \
            " order by length(text), id limit ?"
        out = [dict(r) for r in self.db.execute(sql, [f"%{w}%" for w in words] + who_args + [limit])]
        keys = sorted({w for w in words if len(w) > 2 and w not in COMMON}, key=len, reverse=True)[:8]
        if len(out) < limit and len(keys) > 1:
            seen = {r["id"] for r in out}
            sql = "select * from lines where (" + " or ".join(["lower(text) like ?"] * len(keys)) + ")" + who
            scored = []
            for r in self.db.execute(sql, [f"%{w}%" for w in keys] + who_args):
                if r["id"] in seen:
                    continue
                low = r["text"].lower()
                hits = sum(1 for w in keys if w in low)
                if hits > 1 or len(keys) <= 2:
                    scored.append((-hits, len(low), dict(r)))
            scored.sort(key=lambda t: t[:2])
            out += [r for _h, _n, r in scored[:limit - len(out)]]
        return out

    def line(self, sid):
        r = self.db.execute("select * from lines where id = ?", (int(sid),)).fetchone()
        return dict(r) if r else None


def speaker_label(speaker):
    """'REDANIAN TOWNSMAN 02' -> 'Redanian townsman 02'."""
    return speaker.capitalize() if speaker else ""


# --- listening: the game's speech file (<lang>pc.w3speech) holds every line's audio (Wwise; remaster 5.0: Opus)
# Layout (radish writes 162, 4.04 had 163, the remaster 164 - the same): "CPSW", version u32, key u16, count (bit6
# varint), then per line 40 bytes: id ^ ID_KEY u32, 0 u32, audio offset u64, audio size u64, lip sync offset u64,
# lip sync size u64. An audio blob is its wem's length (u32) and the wem.
ID_KEY = 0x79321793             # language "en" (radish's own files and the game's decode with it)
_INDEX = {}


def _bit6(f):
    b = f.read(1)[0]
    r = b & 0x3F
    if b & 0x40:
        s = 6
        while True:
            b = f.read(1)[0]
            r |= (b & 0x7F) << s
            s += 7
            if not b & 0x80:
                break
    return r


def speech_file(lang="en"):
    return os.path.join(config.load()["game"], "content", "content0", f"{lang}pc.w3speech")


def speech_index(path=None):
    """{string id: (audio offset, audio size)} of a speech file (read once)."""
    path = path or speech_file()
    if path not in _INDEX:
        out = {}
        with open(path, "rb") as f:
            if f.read(4) != b"CPSW":
                raise RuntimeError(f"{path}: not a speech file")
            f.read(6)
            n = _bit6(f)
            raw = f.read(40 * n)
        for k in range(n):
            sid, _z, off, size, _lo, _ls = struct.unpack_from("<IIQQQQ", raw, 40 * k)
            out[sid ^ ID_KEY] = (off, size)
        _INDEX[path] = out
    return _INDEX[path]


def duration(sid, path=None):
    """The length of a game line's recording in seconds, from its Wwise Opus header (fmt: samples at +24, 48 kHz) -
    the scenes' approved length is 0 for a third of the lines. None if it is not there or not Opus."""
    try:
        off, size = speech_index(path).get(int(sid), (None, None))
    except (OSError, RuntimeError):
        return None
    if off is None:
        return None
    with open(path or speech_file(), "rb") as f:
        f.seek(off)
        head = f.read(min(size, 256))
    k = head.find(b"fmt ")
    if k < 0 or len(head) < k + 8 + 32:
        return None
    body = head[k + 8:]
    codec, _ch, rate = struct.unpack_from("<HHI", body, 0)
    if codec != 0x3041 or not rate:
        return None
    return struct.unpack_from("<I", body, 24)[0] / rate


def length(sid, approved=0.0, text=""):
    """How long a game line lasts: its scene's approved length, else its recording's, else from its text."""
    if approved and float(approved) > 0:
        return float(approved)
    return duration(sid) or max(1.5, 0.07 * len(text or ""))


def vgmstream():
    exe = config.load().get("vgmstream") or r"C:\Apps\vgmstream\vgmstream-cli.exe"
    if os.path.exists(exe):
        return exe
    import shutil
    return shutil.which("vgmstream-cli")


def cache_dir():
    d = os.path.join(os.path.dirname(config.PATH), "voice_cache")
    os.makedirs(d, exist_ok=True)
    return d


def listen(sid, path=None):
    """A wav of the game's line `sid` to play (made once, kept in the cache), or None if the game has no audio for
    it. Needs vgmstream (it decodes Wwise audio)."""
    import subprocess
    out = os.path.join(cache_dir(), f"{int(sid)}.wav")
    if os.path.exists(out):
        return out
    entry = speech_index(path).get(int(sid))
    exe = vgmstream()
    if not entry or not exe:
        return None
    off, size = entry
    with open(path or speech_file(), "rb") as f:
        f.seek(off)
        blob = f.read(size)
    n = struct.unpack_from("<I", blob)[0]
    wem = out[:-4] + ".wem"
    open(wem, "wb").write(blob[4:4 + n])
    subprocess.run([exe, "-o", out, wem], capture_output=True)
    os.remove(wem)
    return out if os.path.exists(out) else None
