"""The same GUIDs on every build. radish gives every quest block and journal entry a new random GUID each time it
encodes (two runs of the same definition: every file differs) - and a saved game knows a running quest's blocks and
its objectives' states by those GUIDs. A quest rebuilt while a save is in it (change it, Build & Play, play on - the
everyday way to work) then never resumes: no objective active, nothing waits (night 01.10.2026, measured).

Here each GUID a file defines (an object's own `guid`) becomes one derived from the quest id, the file and what
defines it (its class and its name - a block's `name`, a journal entry's `baseName` - and how many came before with
the same), and every place that holds the old value (the journal paths of the quest, a child's `parentGuid`) gets
the new one. An unchanged quest builds byte for byte the same files; a changed one keeps the GUIDs of everything
whose name stayed.

    stabilize(dlc_dir, qid, seed=None)     # after radish, before cooking (build.build_dlc)

With the project's mark seed (marks.py) each GUID is an HMAC of that seed instead of a plain hash: the same on every
build, random to anyone without the seed, the maker's to whoever checks with it.

    expected_guids({path below the DLC folder: bytes}, qid, seed) -> {where: (expected, found)}
"""
import hmac
import hashlib
import os
import re
import struct

from .cr2w import CR2W

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
EXTS = (".journal", ".w2quest", ".w2phase", ".w2comm", ".w2l", ".reddlc")
NAME_PROPS = ("name", "baseName")


def _string(f, typ, raw):
    if typ == "CName":
        k = struct.unpack_from("<H", raw)[0] if len(raw) >= 2 else 0
        return f.names[k] if k < len(f.names) else ""
    if typ in ("String", "StringAnsi"):
        from .cr2w_props import _string as s
        try:
            return s(raw) or ""
        except Exception:                               # noqa: BLE001 - an odd string: no name
            return ""
    return ""


def _guid(key, seed=None):
    if seed:
        g = hmac.new(seed, key.encode("utf-8"), hashlib.sha256).digest()[:16]
    else:
        g = hashlib.md5(key.encode("utf-8")).digest()
    return g if any(g) else b"\x01" + g[1:]


def _files(root):
    out = []
    for r, _d, names in os.walk(root):
        for n in names:
            if n.endswith(EXTS):
                out.append(os.path.join(r, n))
    # the journal first: it defines what the quest's journal paths point at
    return sorted(out, key=lambda p: (not p.endswith(".journal"), p.lower()))


def translation(root, old_qid, qid, seed=None):
    """{GUID a build for `old_qid` gave: the one `qid`'s gives} for what the files under `root` (stabilized for
    `qid`) define - a file kept from an earlier run (the quest graph's own quest) then points at this run's journal.
    The same keys as stabilize, the quest id swapped in the path and the names."""
    out = {}
    for p in _files(root):
        try:
            f = CR2W(open(p, "rb").read())
        except ValueError:
            continue
        rel = os.path.relpath(p, root).replace("\\", "/").lower()
        old_rel = rel.replace(qid, old_qid)
        seen = {}
        for cls, _fl, _parent, _tmpl, chunk in f.exports:
            props = f.props(chunk)
            name = ""
            for n, t, off, sz in props:
                if n in NAME_PROPS and t in ("CName", "String", "StringAnsi"):
                    name = UUID_RE.sub("", _string(f, t, bytes(chunk[off:off + sz])))
                    break
            for n, t, off, sz in props:
                if n == "guid" and t == "CGUID" and sz == 16:
                    now = bytes(chunk[off:off + 16])
                    if not any(now):
                        continue
                    key = f"{rel}|{cls}|{name}"
                    seen[key] = seen.get(key, 0) + 1
                    if _guid(f"{qid}|{key}|{seen[key]}", seed) != now:
                        continue                        # (not one stabilize made)
                    was = _guid(f"{old_qid}|{old_rel}|{cls}|{name.replace(qid, old_qid)}|{seen[key]}", seed)
                    if was != now:
                        out[was] = now
    return out


def stabilize(root, qid, log=print, seed=None):
    """Rewrite the GUIDs under `root` (the encoded DLC folder) -> how many were replaced."""
    files = {}
    for p in _files(root):
        data = open(p, "rb").read()
        try:
            f = CR2W(data)
        except ValueError:
            continue
        if not f.writable:
            continue
        files[p] = (f, data)
    new_of = {}                                         # old GUID bytes -> new
    for p, (f, _data) in files.items():
        rel = os.path.relpath(p, root).replace("\\", "/").lower()
        seen = {}
        for cls, _fl, _parent, _tmpl, chunk in f.exports:
            props = f.props(chunk)
            name = ""
            for n, t, off, sz in props:
                if n in NAME_PROPS and t in ("CName", "String", "StringAnsi"):
                    name = UUID_RE.sub("", _string(f, t, bytes(chunk[off:off + sz])))
                    break
            for n, t, off, sz in props:
                if n == "guid" and t == "CGUID" and sz == 16:
                    old = bytes(chunk[off:off + 16])
                    if old in new_of or not any(old):
                        continue
                    key = f"{rel}|{cls}|{name}"
                    seen[key] = seen.get(key, 0) + 1
                    new_of[old] = _guid(f"{qid}|{key}|{seen[key]}", seed)
    if not new_of:
        return 0
    count = 0
    for p, (f, data) in files.items():
        changed = False
        for e in f.exports:
            chunk = bytes(e[4])
            for old, new in new_of.items():
                if old in chunk:
                    chunk = chunk.replace(old, new)
                    changed = True
            e[4] = bytearray(chunk)
        for b in f.buffers:
            blob = bytes(b[2])
            for old, new in new_of.items():
                if old in blob:
                    blob = blob.replace(old, new)
                    changed = True
            b[2] = blob
        if changed:
            f.timestamp = 0                             # (the encode time: the same file for the same quest)
            out = f.save()
            tmp = p + ".tmp"
            with open(tmp, "wb") as fh:
                fh.write(out)
            os.replace(tmp, p)
            count += 1
    log(f"[build] {qid}: {len(new_of)} GUIDs made stable in {count} files (a save resumes the rebuilt quest)")
    return len(new_of)


def _defined(f):
    """[(class, name, GUID bytes)] the objects of a CR2W file define, in order."""
    out = []
    for cls, _fl, _parent, _tmpl, chunk in f.exports:
        props = f.props(chunk)
        name = ""
        for n, t, off, sz in props:
            if n in NAME_PROPS and t in ("CName", "String", "StringAnsi"):
                name = UUID_RE.sub("", _string(f, t, bytes(chunk[off:off + sz])))
                break
        for n, t, off, sz in props:
            if n == "guid" and t == "CGUID" and sz == 16:
                g = bytes(chunk[off:off + 16])
                if any(g):
                    out.append((cls, name, g))
    return out


def expected_guids(files, qid, seed):
    """For a built quest's files {path below the DLC folder: bytes}: {"<path>|<class>|<name>|<n>": (the GUID the
    seed gives, the one in the file)} - every GUID stabilize made with that seed matches."""
    out = {}
    seen_guid = set()
    for rel in sorted(files, key=lambda r: (not r.lower().endswith(".journal"), r.lower())):
        if not rel.lower().endswith(EXTS):
            continue
        try:
            f = CR2W(files[rel])
        except Exception:                                # noqa: BLE001 - not a file to read
            continue
        r = rel.replace("\\", "/").lower()
        seen = {}
        for cls, name, g in _defined(f):
            if g in seen_guid:
                continue
            seen_guid.add(g)
            key = f"{r}|{cls}|{name}"
            seen[key] = seen.get(key, 0) + 1
            out[f"{key}|{seen[key]}"] = (_guid(f"{qid}|{key}|{seen[key]}", seed), g)
    return out
