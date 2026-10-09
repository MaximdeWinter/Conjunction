"""collision.cache (CC3W, version 11): the game's cooked collision by resource path - read and written by Conjunction
(a terrain tile's collision follows its changed heights without wcc_lite, which cooks only what it cooked itself).

Measured 04.10. on the game's cache and on one wcc_lite built for our foliage DLC (written back byte for byte):
  header 0x40: magic, version, 0, 0, table offset (u64), entry count, strings offset (u64), strings size,
  largest packed / unpacked entry (each rounded up to 4 KB), fnv64 of everything from the strings on, 8 zero bytes.
  Then the entries' data (zlib, one after another), the strings (paths, 0-ended), the table: 64 bytes per entry -
  path offset in the strings, 0, 0, data offset (u64), packed size, unpacked size, fnv64 of the packed data,
  8 zero bytes, 20 bytes kept as they are (bounds, flags).
A terrain tile's data: 64 PhysX heightfields (terrain.py).

    entries = read(path)            [Entry(path, packed, size, extra), ...]
    data = write(entries)
"""
import struct
import zlib
from dataclasses import dataclass

HEADER = 0x40
ENTRY = 64


def fnv64(b):
    h = 0xCBF29CE484222325
    for x in b:
        h = ((h ^ x) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


@dataclass
class Entry:
    path: str
    packed: bytes           # zlib
    size: int               # unpacked
    extra: bytes            # the entry's last 20 bytes, kept

    def data(self):
        return zlib.decompress(self.packed)

    def replace(self, raw):
        self.packed = zlib.compress(raw, 9)
        self.size = len(raw)


def read(path):
    with open(path, "rb") as f:
        m = f.read()
    return parse(m)


def parse(m):
    magic, version = struct.unpack_from("<4sI", m, 0)
    if magic != b"CC3W" or version != 11:
        raise ValueError(f"not a collision cache of version 11 ({magic!r} {version})")
    table, count, strings = struct.unpack_from("<Q I Q", m, 0x10)[0], struct.unpack_from("<I", m, 0x18)[0], \
        struct.unpack_from("<Q", m, 0x1C)[0]
    out = []
    for i in range(count):
        e = m[table + i * ENTRY:table + (i + 1) * ENTRY]
        so = struct.unpack_from("<I", e, 0)[0]
        name = m[strings + so:m.index(b"\0", strings + so)].decode("utf-8")
        off, = struct.unpack_from("<Q", e, 0x0C)
        zsize, size = struct.unpack_from("<II", e, 0x14)
        out.append(Entry(name, bytes(m[off:off + zsize]), size, bytes(e[0x2C:])))
    return out


def find(path, wanted):
    """Only the entries named in `wanted` (depot paths, any case) from a cache - the game's is 890 MB: its table and
    strings are read, and the data of those entries."""
    import mmap
    wanted = {w.lower() for w in wanted}
    out = {}
    with open(path, "rb") as f:
        m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            table, = struct.unpack_from("<Q", m, 0x10)
            count, = struct.unpack_from("<I", m, 0x18)
            strings, = struct.unpack_from("<Q", m, 0x1C)
            for i in range(count):
                e = m[table + i * ENTRY:table + (i + 1) * ENTRY]
                so = struct.unpack_from("<I", e, 0)[0]
                name = m[strings + so:m.find(b"\0", strings + so)].decode("utf-8")
                if name.lower() in wanted:
                    off, = struct.unpack_from("<Q", e, 0x0C)
                    zsize, size = struct.unpack_from("<II", e, 0x14)
                    out[name.lower()] = Entry(name, bytes(m[off:off + zsize]), size, bytes(e[0x2C:]))
        finally:
            m.close()
    return out


def _round(n):
    return (n + 0xFFF) & ~0xFFF


def write(entries):
    data, offsets = bytearray(), []
    for e in entries:
        offsets.append(HEADER + len(data))
        data += e.packed
    strings, name_off = bytearray(), []
    for e in entries:
        name_off.append(len(strings))
        strings += e.path.encode("utf-8") + b"\0"
    table = bytearray()
    for e, off, so in zip(entries, offsets, name_off):
        table += struct.pack("<IIIQIIQQ", so, 0, 0, off, len(e.packed), e.size, fnv64(e.packed), 0) + e.extra
    strings_at = HEADER + len(data)
    table_at = strings_at + len(strings)
    head = struct.pack("<4sIIIQIQI", b"CC3W", 11, 0, 0, table_at, len(entries), strings_at, len(strings))
    head += struct.pack("<II", _round(max((len(e.packed) for e in entries), default=0)),
                        _round(max((e.size for e in entries), default=0)))
    head += struct.pack("<QQ", fnv64(bytes(strings + table)), 0)
    return bytes(head + data + strings + table)
