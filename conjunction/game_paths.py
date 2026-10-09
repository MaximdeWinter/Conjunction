"""The game's own paths (CPathComponent in a layer: an NPC's way to a village, a patrol) as points in the world - for a
Follow, a Walk or a Patrol that goes the way the game's quest goes.

    points(depot, layer_path)            -> {tag: [[x, y, z], ...]}

A path's curve keeps one list of keys per axis (X, Y, Z: a value per key, 0 left out); the points are the entity's
position + the component's + the values.
"""
import struct


def _value(key):
    """A key's value (the reader cuts the first letters of some field names: 'lue')."""
    return next((v for k, v in key.items() if k.endswith("lue") and isinstance(v, (int, float))), 0.0)


def points(depot, layer):
    from .assets import _cr2w_parts
    from .cr2w_props import decode
    from .meshview import _transform
    out = {}
    for f in _cr2w_parts(depot.read(layer)):
        pos, tags = [0.0, 0.0, 0.0], []
        for cls, _fl, _parent, _t, chunk in f.exports:
            try:
                x = decode(f, chunk)
            except Exception:                       # noqa: BLE001 - an object the reader does not know
                continue
            if cls == "CEntity":
                tr = x.get("transform")
                pos = list(_transform(tr)[0]) if tr else [0.0, 0.0, 0.0]
                raw = x.get("tags")
                tags = [f.names[struct.unpack_from("<H", raw, 1 + 2 * k)[0]] for k in range(raw[0])] \
                    if isinstance(raw, (bytes, bytearray)) and raw else []
            elif cls == "CPathComponent":
                comp = list(_transform(x["transform"])[0]) if x.get("transform") else [0.0, 0.0, 0.0]
                curves = ((x.get("curve") or {}).get("curves") or [])[:3]
                if len(curves) < 3:
                    continue
                vals = [[_value(k) for k in c.get("Curve Values") or []] for c in curves]
                n = min(len(v) for v in vals)
                pts = [[round(pos[i] + comp[i] + vals[i][j], 3) for i in range(3)] for j in range(n)]
                out[tags[0] if tags else f"path{len(out)}"] = pts
    return out
