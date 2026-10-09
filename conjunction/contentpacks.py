"""Content packs: add-ons anyone can make and load - for now voice recordings (later more kinds of content).

A pack is a folder (later also one packed file) in one of the pack folders (PACK_DIRS, config "pack_dirs"):

    <pack>/pack.yml            id, name, author, version, description
    <pack>/voices/voices.yml   lines: [{id, file, text, speaker, tags: [...], lang}]
    <pack>/voices/*.wav        the recordings (uncompressed wav; ogg / mp3 / flac too when ffmpeg is installed)

A voice line is known as "<pack id>/<line id>". The dialogue editor lists them (search, tags, play); a quest that
uses one carries the recording in its DLC (speech.py makes the game's format and the lip sync).
"""
import os
import struct

import yaml

from . import config

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIO = (".wav", ".ogg", ".mp3", ".flac")


def pack_dirs():
    cfg = config.load()
    dirs = [os.path.join(HERE, "..", "packs"), os.path.join(os.path.expanduser("~"), "Documents", "conjunction", "packs")]
    return [os.path.normpath(d) for d in dirs + list(cfg.get("pack_dirs", [])) if os.path.isdir(d)]


class Pack:
    def __init__(self, path):
        self.path = path
        meta = yaml.safe_load(open(os.path.join(path, "pack.yml"), encoding="utf-8")) or {}
        self.id = str(meta.get("id") or os.path.basename(path)).lower()
        self.name = meta.get("name") or self.id
        self.author = meta.get("author", "")
        self.version = meta.get("version", 1)
        self.description = meta.get("description", "")
        self.problems = []
        self.voices = self._voices()

    def _voices(self):
        f = os.path.join(self.path, "voices", "voices.yml")
        if not os.path.exists(f):
            return []
        out = []
        for e in (yaml.safe_load(open(f, encoding="utf-8")) or {}).get("lines") or []:
            src = os.path.join(self.path, "voices", str(e.get("file", "")))
            if not e.get("id") or not os.path.isfile(src) or not src.lower().endswith(AUDIO):
                self.problems.append(f"{self.id}: voice line {e.get('id') or e.get('file')} - no such recording")
                continue
            out.append({"key": f"{self.id}/{e['id']}", "pack": self.id, "pack_name": self.name, "id": str(e["id"]),
                        "file": src, "text": str(e.get("text", "")).strip(), "speaker": str(e.get("speaker", "")),
                        "tags": [str(t).lower() for t in e.get("tags") or []], "lang": e.get("lang", "en"),
                        "dur": audio_seconds(src)})
        return out


_CACHE = {}


def packs():
    """Every pack found (re-read when a pack file changed)."""
    out = []
    for d in pack_dirs():
        for name in sorted(os.listdir(d)):
            path = os.path.join(d, name)
            meta = os.path.join(path, "pack.yml")
            if not os.path.isfile(meta):
                continue
            stamp = tuple(os.path.getmtime(f) for f in (meta, os.path.join(path, "voices", "voices.yml"))
                          if os.path.exists(f))
            if _CACHE.get(path, (None,))[0] != stamp:
                try:
                    _CACHE[path] = (stamp, Pack(path))
                except (OSError, yaml.YAMLError) as ex:
                    print(f"[packs] {path}: {ex}", flush=True)
                    continue
            out.append(_CACHE[path][1])
    return out


def voice_lines():
    return [v for p in packs() for v in p.voices]


def voice(key):
    return next((v for v in voice_lines() if v["key"] == key), None)


def voice_tags():
    """Every tag with how many lines have it, most used first."""
    count = {}
    for v in voice_lines():
        for t in v["tags"]:
            count[t] = count.get(t, 0) + 1
    return sorted(count.items(), key=lambda kv: (-kv[1], kv[0]))


def search_voices(text="", tags=(), limit=200):
    words = text.lower().split()
    out = []
    for v in voice_lines():
        hay = " ".join([v["text"], v["speaker"], v["id"], v["pack_name"]] + v["tags"]).lower()
        if all(w in hay for w in words) and all(t in v["tags"] for t in tags):
            out.append(v)
    return out[:limit]


def audio_seconds(path):
    """Length of a recording (wav header; other formats: 0 until converted)."""
    try:
        with open(path, "rb") as f:
            data = f.read(1 << 16)
        if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
            return 0.0
        i, rate, block, size = 12, 0, 0, 0
        while i + 8 <= len(data):
            cid, n = data[i:i + 4], struct.unpack_from("<I", data, i + 4)[0]
            if cid == b"fmt ":
                rate, block = struct.unpack_from("<I", data, i + 12)[0], struct.unpack_from("<H", data, i + 20)[0]
            elif cid == b"data":
                size = n
                break
            i += 8 + n + (n & 1)
        if not size:                                    # the data chunk lies beyond the part read
            size = os.path.getsize(path) - i - 8
        return round(size / (rate * block), 3) if rate and block else 0.0
    except (OSError, struct.error):
        return 0.0
