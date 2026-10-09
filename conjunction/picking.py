"""Selecting in the world by the objects' real size: every placed object is a box - its meshes' bounds (the game's
own numbers), turned as it stands - and a click is a ray from the camera through the cursor. The game's physics ray
only hit collision shapes (small or none: a corpse, a cup) and needed a round trip to the game.

Of the boxes a ray goes through, the nearest wins - unless a smaller one lies in it along the ray (a cup on a
table): the smaller one. People are a person's box; a template without meshes (a light, an effect) a small cube.
Bounds are read once per template and kept in %APPDATA%\\conjunction\\bounds.json.
"""
import json
import math
import os
import struct
import threading

from . import config

CACHE = os.path.join(os.path.dirname(config.PATH), "bounds.json")
PERSON = (-0.35, -0.35, 0.0, 0.35, 0.35, 1.85)
SMALL = (-0.25, -0.25, 0.0, 0.25, 0.25, 0.5)
_cache, _lock, _pending = None, threading.Lock(), set()


def _load():
    global _cache
    if _cache is None:
        try:
            _cache = json.load(open(CACHE, encoding="utf-8"))
        except (OSError, ValueError):
            _cache = {}
    return _cache


def _save():
    try:
        json.dump(_cache, open(CACHE, "w", encoding="utf-8"))
    except OSError:
        pass


def turn(x, y, z, roll, pitch, yaw):
    """A point turned as the game turns things: roll around y, pitch around x, yaw around z (degrees)."""
    cy, sy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    cp, sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
    cr, sr = math.cos(math.radians(roll)), math.sin(math.radians(roll))
    x, z = x * cr + z * sr, -x * sr + z * cr
    y, z = y * cp - z * sp, y * sp + z * cp
    x, y = x * cy - y * sy, x * sy + y * cy
    return x, y, z


def unturn(x, y, z, roll, pitch, yaw):
    """The other way round (world -> the object's own axes)."""
    cy, sy = math.cos(math.radians(-yaw)), math.sin(math.radians(-yaw))
    cp, sp = math.cos(math.radians(-pitch)), math.sin(math.radians(-pitch))
    cr, sr = math.cos(math.radians(-roll)), math.sin(math.radians(-roll))
    x, y = x * cy - y * sy, x * sy + y * cy
    y, z = y * cp - z * sp, y * sp + z * cp
    x, z = x * cr + z * sr, -x * sr + z * cr
    return x, y, z


def mesh_bounds(path, depot):
    """(min x, y, z, max x, y, z) of a cooked mesh (its CMesh's boundingBox), or None."""
    from .assets import _cr2w_parts
    from .meshview import _props
    f = _cr2w_parts(depot.read(path))[0]
    mesh = next((e for e in f.exports if e[0] == "CMesh"), None)
    if mesh is None:
        return None
    chunk = mesh[4]
    props = _props(f, chunk)
    if "boundingBox" not in props:
        return None
    _tp, off, sz = props["boundingBox"]
    box = chunk[off:off + sz]
    bp = _props(f, box)

    def vec(name):
        if name not in bp:
            return None
        _t, o, s = bp[name]
        sub = _props(f, box[o:o + s], 1)
        return [struct.unpack_from("<f", box, o + sub[k][1])[0] if k in sub else 0.0 for k in "XYZ"]
    lo, hi = vec("Min"), vec("Max")
    return tuple(lo + hi) if lo and hi else None


def template_bounds(template, depot):
    """The box of all a template's meshes where its components put them, or None (no meshes)."""
    from .meshview import template_meshes
    lo, hi = [math.inf] * 3, [-math.inf] * 3
    for mesh, ((px, py, pz), (roll, pitch, yaw), (sx, sy, sz)) in template_meshes(template, depot):
        try:
            b = depot.exists(mesh) and mesh_bounds(mesh, depot)
        except Exception:                                   # noqa: BLE001 - an unreadable mesh: left out
            b = None
        if not b:
            continue
        for cx in (b[0], b[3]):
            for cy in (b[1], b[4]):
                for cz in (b[2], b[5]):
                    x, y, z = turn(cx * sx, cy * sy, cz * sz, roll, pitch, yaw)
                    for i, v in enumerate((x + px, y + py, z + pz)):
                        lo[i], hi[i] = min(lo[i], v), max(hi[i], v)
    if lo[0] == math.inf:
        return None
    return tuple(lo + hi)


def box_of(o, actor):
    """The box of a placed object in its own axes (known, or the stand-in while it is being read)."""
    if actor:
        return PERSON
    t = o["template"].lower()
    b = _load().get(t, "?")
    if isinstance(b, list):
        return tuple(b)
    return PERSON if b is None and ("npc_entities" in t or "\\monsters\\" in t or "\\animals\\" in t) else SMALL


def prepare(templates, depot_fn):
    """Reads the boxes of templates not known yet, in the background (`depot_fn()`: the game's depot)."""
    todo = [t for t in {t.lower() for t in templates} if t not in _load() and t not in _pending]
    if not todo:
        return
    _pending.update(todo)

    def work():
        depot = depot_fn()
        for t in todo:
            try:
                b = template_bounds(t, depot)
            except Exception:                               # noqa: BLE001 - unreadable: the small cube
                b = None
            with _lock:
                _cache[t] = list(b) if b else None
                _pending.discard(t)
        with _lock:
            _save()
    threading.Thread(target=work, daemon=True).start()


def ray_box(origin, direction, o, box):
    """(entry, exit) distances of the ray through the object's turned box, or None."""
    roll, pitch, yaw = o.get("rot") or (0, 0, 0)
    p = o["pos"]
    ox, oy, oz = unturn(origin[0] - p[0], origin[1] - p[1], origin[2] - p[2], roll, pitch, yaw)
    dx, dy, dz = unturn(*direction, roll, pitch, yaw)
    t0, t1 = -math.inf, math.inf
    for s, d, lo, hi in ((ox, dx, box[0], box[3]), (oy, dy, box[1], box[4]), (oz, dz, box[2], box[5])):
        if abs(d) < 1e-9:
            if s < lo or s > hi:
                return None
            continue
        a, b = (lo - s) / d, (hi - s) / d
        t0, t1 = max(t0, min(a, b)), min(t1, max(a, b))
        if t0 > t1:
            return None
    if t1 < 0:
        return None
    return max(t0, 0.0), t1


def pick(origin, direction, objects, is_actor):
    """The position of the object the ray selects (see the module text), or None."""
    hits = []
    for o in objects:
        box = box_of(o, is_actor(o))
        r = ray_box(origin, direction, o, box)
        if r:
            vol = (box[3] - box[0]) * (box[4] - box[1]) * (box[5] - box[2])
            hits.append((r[0], r[1], vol, o["pos"]))
    if not hits:
        return None
    hits.sort()
    near = hits[0]
    inside = [h for h in hits if h[0] <= near[1]]           # along the ray within the nearest one's box
    return min(inside, key=lambda h: (h[2], h[0]))[3]
