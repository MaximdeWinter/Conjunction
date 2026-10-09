"""The game's encounters (the creatures of an area: wolves, drowners - CEncounter in the world's layers) with their
tags and where they stand. The game finds an encounter only by its tag (EnableEncounter needs the entity: a search
around a point finds none - Keira test 01.10.: 0 of them), so a quest step "creatures around here off" is built with
the tags of those within its radius. An index per world, made once from the game's files and kept.

    from conjunction import encounters
    encounters.near("velen", (x, y, z), 80)         -> [(tag, distance), ...]
    python -m conjunction.encounters velen              (the index made anew)
"""
import json
import math
import os
import struct
import sys

from . import config


def prefix(world):
    """The depot folder of a world's layers, by the radish world id (velen: levels/novigrad/)."""
    from .project import worlds
    for path, wid in worlds().items():
        if wid == world:
            return path.rsplit("\\", 1)[0] + "\\"
    raise ValueError(f"unknown world {world}")


def cache_path(world, cls="CEncounter"):
    kind = "encounters" if cls == "CEncounter" else cls.lower()
    return os.path.join(os.path.dirname(config.PATH), f"{kind}_{world}.json")


def _taglist(f, raw):
    """TagList: a count, then that many name indices (uint16)."""
    if not raw:
        return []
    n = raw[0]
    return [f.names[struct.unpack_from("<H", raw, 1 + 2 * i)[0]] for i in range(n) if 3 + 2 * i <= len(raw)]


def scan(world, log=print, cls="CEncounter"):
    """Every CEncounter (or `cls`: W3NoticeBoard) of the world's layers -> [{"tags": [...], "pos": [x, y, z],
    "layer": path}]."""
    from .assets import _cr2w_parts
    from .bundles import Depot
    from .meshview import _transform
    folder = prefix(world)
    depot = Depot()
    layers = [p for p in depot.where if p.startswith(folder) and p.endswith(".w2l")]
    out = []
    for k, path in enumerate(layers):
        if k % 2000 == 0:
            log(f"[{cls}] {world}: {k}/{len(layers)} layers, {len(out)} found")
        try:
            data = depot.read(path)
        except Exception:                           # noqa: BLE001 - an unreadable layer: skipped
            continue
        if cls.encode() not in data:
            continue
        for f in _cr2w_parts(data):
            for c, _fl, _parent, _tmpl, chunk in f.exports:
                if c != cls:
                    continue
                try:
                    props = f.props(chunk, 1)
                except (IndexError, struct.error, KeyError):
                    continue
                tags, pos = [], None
                for name, _tp, off, sz in props:
                    raw = bytes(chunk[off:off + sz])
                    if name == "tags":
                        tags = _taglist(f, raw)
                    elif name == "transform":
                        pos = [round(v, 2) for v in _transform(raw)[0][:3]]
                if tags and pos:
                    out.append({"tags": tags, "pos": pos, "layer": path})
    return out


def index(world, log=print, cls="CEncounter"):
    path = cache_path(world, cls)
    if os.path.exists(path):
        return json.load(open(path, encoding="utf-8"))
    found = scan(world, log, cls)
    tmp = path + ".tmp"
    json.dump(found, open(tmp, "w", encoding="utf-8"))
    os.replace(tmp, path)
    return found


def near(world, pos, radius, log=print):
    """[(tag, distance)] of the encounters whose place lies within the radius (nearest first; their first tag)."""
    out = []
    for e in index(world, log):
        d = math.dist(e["pos"][:2], pos[:2])
        if d <= radius:
            out.append((e["tags"][0], round(d, 1)))
    return sorted(set(out), key=lambda t: t[1])


if __name__ == "__main__":
    w = sys.argv[1] if len(sys.argv) > 1 else "velen"
    if os.path.exists(cache_path(w)):
        os.remove(cache_path(w))
    found = index(w)
    print(f"{len(found)} encounters in {w}")
