"""Lip sync in the game's own form. radish makes a CR2W (CSkeletalAnimation + CAnimationBufferBitwiseCompressed); the
game's .w3speech files (4.04 and the remaster) hold the same animation raw, and the game moves no mouth with the CR2W
(seen in 5.0, 30.09.2026). The raw form:

    f32 frames per second, f32 duration
    bit6 bone count, per bone: position, orientation              (the scale is not stored)
    bit6 track count, per track: one record
    bit6 data size, the data (the bytes of the CR2W's data array)
    u32 frame count, f32 dt

a record (16 bytes): f32 dt, i8 compression, u8 0, u16 frames, u32 data address, u32 fallback address.
"""
import struct

from .cr2w import CR2W
from .w3strings import _bit6_read, _bit6_write

RECORD = ("dt", "compression", "numFrames", "dataAddr", "dataAddrFallback")


def _value(c, typ, v):
    if typ == "Float":
        return struct.unpack_from("<f", v)[0]
    if typ == "Int8":
        return struct.unpack_from("<b", v)[0]
    if typ == "Uint16":
        return struct.unpack_from("<H", v)[0]
    if typ == "Uint32":
        return struct.unpack_from("<I", v)[0]
    if typ.startswith("array:") and typ.endswith(",Int8"):
        return bytes(v[4:4 + struct.unpack_from("<I", v)[0]])
    if typ.startswith("array:"):
        n, i, out = struct.unpack_from("<I", v)[0], 4, []
        for _ in range(n):
            item, i = _struct(c, v, i)
            out.append(item)
        return out
    if typ.startswith("SAnimationBufferBitwiseCompressed"):          # the records; enums and settings stay bytes
        return _struct(c, v, 0)[0]
    return bytes(v)


def _struct(c, data, i):
    """A serialized struct at i (a 0 byte, properties, a 0 name) -> ({name: value}, the offset after it)."""
    out, i = {}, i + 1
    while True:
        nm = struct.unpack_from("<H", data, i)[0]
        if nm == 0:
            return out, i + 2
        tp, sz = struct.unpack_from("<HI", data, i + 2)
        out[c.names[nm]] = _value(c, c.names[tp], data[i + 8:i + 4 + sz])
        i += 4 + sz


def read_cr2w(data):
    """radish's lip sync CR2W -> {fps, duration, bones, tracks, data, frames, dt}."""
    c = CR2W(data)
    anim = buf = None
    for cls, _fl, _parent, _tmpl, chunk in c.exports:
        props, _end = _struct(c, chunk, 0)
        if cls == "CSkeletalAnimation":
            anim = props
        elif cls == "CAnimationBufferBitwiseCompressed":
            buf = props
    if buf is None:
        raise ValueError("no CAnimationBufferBitwiseCompressed in the lip sync")
    dt = buf.get("dt", 1 / 30)
    return {"fps": (anim or {}).get("framesPerSecond", 1 / dt), "duration": buf.get("duration", 0.0),
            "bones": buf.get("bones", []), "tracks": buf.get("tracks", []), "data": buf.get("data", b""),
            "frames": buf.get("numFrames", 0), "dt": dt}


def _record(r):
    return struct.pack("<fbBHII", r.get("dt", 0.0), r.get("compression", 0), 0, r.get("numFrames", 0),
                       r.get("dataAddr", 0), r.get("dataAddrFallback", 0))


def write_raw(a):
    out = bytearray(struct.pack("<ff", a["fps"], a["duration"]))
    out += _bit6_write(len(a["bones"]))
    for b in a["bones"]:
        out += _record(b.get("position", {})) + _record(b.get("orientation", {}))
    out += _bit6_write(len(a["tracks"]))
    for t in a["tracks"]:
        out += _record(t)
    out += _bit6_write(len(a["data"])) + a["data"]
    out += struct.pack("<If", a["frames"], a["dt"])
    return bytes(out)


def read_raw(data):
    """The game's raw lip sync -> the same dict as read_cr2w."""
    fps, duration = struct.unpack_from("<ff", data)

    def rec(i):
        return dict(zip(RECORD, (v for k, v in enumerate(struct.unpack_from("<fbBHII", data, i)) if k != 2)))
    nb, i = _bit6_read(data, 8)
    bones = [{"position": rec(i + 32 * k), "orientation": rec(i + 32 * k + 16)} for k in range(nb)]
    nt, i = _bit6_read(data, i + 32 * nb)
    tracks = [rec(i + 16 * k) for k in range(nt)]
    size, i = _bit6_read(data, i + 16 * nt)
    frames, dt = struct.unpack_from("<If", data, i + size)
    return {"fps": fps, "duration": duration, "bones": bones, "tracks": tracks, "data": bytes(data[i:i + size]),
            "frames": frames, "dt": dt}


def to_game(lipsync):
    """Any lip sync -> the game's raw form (a CR2W is converted, raw bytes and empty stay)."""
    return write_raw(read_cr2w(lipsync)) if lipsync[:4] == b"CR2W" else lipsync
