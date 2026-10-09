"""The game's foliage trees (.srt: SpeedTree 7 data inside a CR2W file) - what Conjunction needs of them: their
extents and their collision objects (measured 04.10. across radish's foliage list).

After the header 'SRT 07.0.0' (16 bytes): the extents (min x y z, max x y z, metres), then LOD and wind data, then a
string table - a count n (4 bytes), n entries of 8 bytes (4 zero bytes, then the string's size: its length with the
terminator, padded to 4), the strings one after the other - and right after it the collision objects: a count
(4 bytes), then per object 36 bytes: a user string reference (8 bytes), centre 1 (3 floats), centre 2 (3 floats),
radius. A trunk is a capsule from its foot up the stem; a broken tree has a second one lying on the ground; a few
huge oaks have a sphere (both centres the same). Flowers and most bushes have none.
"""
import struct

HEAD = b"SRT 07.0.0"


def _string_table(data, k):
    """(start, end) of the string table after the header at k: a count n, n sizes, strings that fit them, one of them
    a texture's file name."""
    for off in range(k + 16, len(data) - 16, 4):
        n = struct.unpack_from("<i", data, off)[0]
        if not 3 <= n <= 256:                           # (a tree names its shaders and textures: several)
            continue
        sizes_end = off + 4 + 8 * n
        if sizes_end > len(data):
            continue
        pairs = struct.unpack_from(f"<{2 * n}i", data, off + 4)
        zeros, lens = pairs[0::2], pairs[1::2]
        if any(zeros) or any(x <= 0 or x % 4 or x > 1024 for x in lens):
            continue
        pos, ok, names = sizes_end, True, []
        for x in lens:
            s = data[pos:pos + x]
            if len(s) < x or s[-1:] != b"\x00" or not all(32 <= c < 127 for c in s.split(b"\x00", 1)[0]):
                ok = False
                break
            names.append(s.split(b"\x00", 1)[0])
            pos += x
        if ok and any(nm.lower().endswith((b".dds", b".tga", b".png")) for nm in names):
            return off, pos
    return None


def read(data):
    """{"extents": (min, max), "collision": [(centre1, centre2, radius), ...]} of a tree resource, or None when it is
    not one this reader knows. Objects without a radius are left out."""
    k = data.find(HEAD)
    if k < 0:
        return None
    ext = struct.unpack_from("<6f", data, k + 20)
    table = _string_table(data, k)
    if table is None:
        return None
    end = table[1]
    n = struct.unpack_from("<i", data, end)[0]
    if not 0 <= n <= 64:
        return None
    out = []
    for i in range(n):
        o = end + 4 + 36 * i                            # (its first 8 bytes: the user string reference)
        v = struct.unpack_from("<7f", data, o + 8)
        if v[6] > 0:
            out.append((v[0:3], v[3:6], v[6]))
    return {"extents": (ext[0:3], ext[3:6]), "collision": out}
