"""Text ids of their own for every quest (Maxim, 02.10.: quests made with Conjunction must work side by side).

radish gives a quest one of 10 000 "id spaces" of 1000 text ids (2110000000 + space * 1000 + n); Conjunction took the
space from the quest's id - 8000 of them, so among 100 quests two share one with a fair chance (about half), and the
second one's lines, journal and names would show the other's texts. After radish has encoded everything, the ids
are moved to a range of their own in a far wider field: 100 000 000 to 2 000 000 000 (below the signed limit the
game's scripts read; the game's own texts end near 1 500 000, mods made with radish live at 2 110 000 000 and up) -
a block as long as the quest needs, at a place derived from its id (and a salt the author can change when the
library ever reports a clash).

Where the ids are: the strings file (radish's, rewritten as v164 by the build), the speech file (one entry per
spoken line), and inside the encoded files every LocalizedString property and a scene's `sceneId` (a Uint32 radish
takes from the same space). Those are patched in place in the raw bytes - a property is name (u16), type (u16),
size (u32 = 8), value (u32) - in every CR2W of a file (templates in layers carry CR2Ws of their own); nothing changes
length, so nothing else in the file needs to move.

    base = wide_base(qid, count, salt)
    remap_file(path, lo, hi, base)          -> how many values moved
    remap_tree(root, lo, hi, base)
"""
import os
import struct
import zlib

LOW, HIGH = 100_000_000, 2_000_000_000
STEP = 100
EXTS = (".w2scene", ".journal", ".w2quest", ".w2phase", ".w2l", ".w2ent", ".w2comm", ".reddlc", ".w2behtree")


def wide_base(qid, count=1000, salt=""):
    """The first id of the quest's block: a multiple of 100 from a hash of its id (+ salt), room for `count`."""
    slots = (HIGH - LOW - count) // STEP
    h = zlib.crc32(f"{qid}|{salt}".encode("utf-8"))
    h = (h * 2654435761 + zlib.crc32(f"{salt}|{qid}|w3s".encode("utf-8"))) & 0xFFFFFFFFFFFF
    return LOW + (h % slots) * STEP


def _cr2w_starts(data):
    out, i = [], 0
    while True:
        i = data.find(b"CR2W", i)
        if i < 0:
            return out
        out.append(i)
        i += 4


def _names(data, start):
    """The name table of the CR2W at `start` (None when it is not one)."""
    from .cr2w import CR2W
    try:
        return CR2W(bytes(data[start:])).names
    except Exception:                                   # noqa: BLE001 - "CR2W" inside other data
        return None


def remap_bytes(data, lo, hi, base):
    """-> (new bytes, how many values moved). Values lo..hi become base + (value - lo)."""
    buf = bytearray(data)
    starts = _cr2w_starts(buf)
    moved = 0
    for k, s in enumerate(starts):
        names = _names(buf, s)
        if not names:
            continue
        end = len(buf)
        types = {i for i, n in enumerate(names) if n == "LocalizedString"}
        u32 = {i for i, n in enumerate(names) if n == "Uint32"}
        scene_id = {i for i, n in enumerate(names) if n == "sceneId"}
        if not types and not (u32 and scene_id):
            continue
        for t in sorted(types | (u32 if scene_id else set())):
            pat = struct.pack("<HI", t, 8)          # type, size 8 - the name before it, the value after
            j = buf.find(pat, s + 6)
            while 0 <= j and j + 10 <= end:
                i = j - 2
                if t in types or struct.unpack_from("<H", buf, i)[0] in scene_id:
                    v = struct.unpack_from("<I", buf, i + 8)[0]
                    if lo <= v <= hi:
                        struct.pack_into("<I", buf, i + 8, base + (v - lo))
                        moved += 1
                j = buf.find(pat, j + 1)
    return bytes(buf), moved


def remap_file(path, lo, hi, base):
    data = open(path, "rb").read()
    new, moved = remap_bytes(data, lo, hi, base)
    if moved:
        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(new)
        os.replace(tmp, path)
    return moved


def remap_tree(root, lo, hi, base):
    """Every encoded file under `root` -> how many values moved."""
    moved = 0
    for r, _d, files in os.walk(root):
        for n in files:
            if n.lower().endswith(EXTS):
                moved += remap_file(os.path.join(r, n), lo, hi, base)
    return moved


def remap_ids(ids, lo, hi, base):
    """{id: x} with the quest's ids moved (others kept)."""
    return {(base + (i - lo) if lo <= i <= hi else i): v for i, v in ids.items()}
