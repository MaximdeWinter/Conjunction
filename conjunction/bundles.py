"""Read files straight out of the game's bundles (base game, expansions, DLCs) - no extraction step, nothing copied.

A bundle: header 0x20 bytes (TOC size at 16), then 0x140 bytes per file: name (0x100), hash (16), 0 (u32), size,
compressed size, offset, timestamp (u64), 16 zero bytes, crc, compression (0 none, 1 zlib, 2 snappy, 3 doboz,
4 lz4, 5 lz4hc).
"""
import glob
import os
import struct
import zlib

from . import config

ENTRY = 0x140


def bundle_paths(game=None):
    game = game or config.load()["game"]
    out = glob.glob(os.path.join(game, "content", "content*", "bundles", "*.bundle"))
    out += glob.glob(os.path.join(game, "dlc", "*", "content", "bundles", "*.bundle"))
    # DLCs and mods as REDkit / wcc_lite pack them (content\blob0.bundle): content packs, Conjunction's own DLCs
    out += glob.glob(os.path.join(game, "dlc", "*", "content", "*.bundle"))
    # (not a project's own: Mods\moddlc<id> holds the game's files a project changed - the game's own stay the
    # game's here, what the quest graph's Revert goes back to)
    out += [b for b in glob.glob(os.path.join(game, "Mods", "*", "content", "*.bundle"))
            if not os.path.basename(os.path.dirname(os.path.dirname(b))).lower().startswith("moddlc")]
    return out


ENTRY_V5 = 0x130            # the remaster (5.0, 29.09.2026): name, hash, offset u64, size, zsize, crc, compression


def _entry_size(toc):
    """0x140 (up to 4.04, and bundles cooked by the REDkit of that time) or 0x130 (the remaster): the second
    entry's name starts right after the first one."""
    if len(toc) % ENTRY and len(toc) % ENTRY_V5 == 0:    # (one entry: only the remaster's size fits)
        return ENTRY_V5
    if len(toc) >= 2 * ENTRY_V5 and len(toc) % ENTRY_V5 == 0:
        def starts(at):
            """A name starts here: a letter after the previous entry's last byte (its compression's high byte, 0) -
            not a letter in the middle of a name (xml.bundle of the remaster fits both sizes: 66 880 bytes)."""
            return toc[at:at + 1].isalnum() and toc[at - 1] == 0
        if starts(ENTRY_V5) and (len(toc) % ENTRY or not starts(ENTRY)):
            return ENTRY_V5
    return ENTRY


def entries(bundle):
    """(depot path, size, compressed size, offset, compression) of every file in a bundle."""
    with open(bundle, "rb") as f:
        head = f.read(0x20)
        n = struct.unpack_from("<I", head, 16)[0]
        toc = f.read(n)
    step = _entry_size(toc)
    out = []
    for i in range(n // step):
        o = i * step
        name = toc[o:o + 0x100].split(b"\0", 1)[0].decode("utf-8", "replace")
        if step == ENTRY_V5:
            offset, size, zsize, _crc, comp = struct.unpack_from("<QIIII", toc, o + 0x110)
        else:
            size, zsize, offset = struct.unpack_from("<III", toc, o + 0x114)
            comp = struct.unpack_from("<I", toc, o + 0x13C)[0]
        out.append((name, size, zsize, offset, comp))
    return out


# doboz match codes by the low 3 bits of the next word: mask, offset shift, length mask, length shift, size in bytes
_DOBOZ = [(0xFF, 2, 0, 0, 1), (0xFFFF, 2, 0, 0, 2), (0xFFFF, 6, 15, 2, 2), (0xFFFFFF, 8, 31, 3, 3),
          (0xFF, 2, 0, 0, 1), (0xFFFF, 2, 0, 0, 2), (0xFFFF, 6, 15, 2, 2), (0xFFFFFFFF, 11, 255, 3, 4)]


def doboz_decompress(src, size):
    """Doboz (Attila T. Afra) decompressor: header (attributes byte: version, size field width, stored flag; then the
    uncompressed and compressed sizes), then 32-bit control words - bit 0 = literal byte, 1 = a match (offset back
    from the current end, length >= 3)."""
    attrs = src[0]
    size_bytes = ((attrs >> 3) & 7) + 1
    pos = 1 + 2 * size_bytes
    if attrs & 0x80:                                # stored
        return bytes(src[pos:pos + size])
    src = bytes(src) + b"\0" * 8
    out = bytearray()
    control = 1
    while len(out) < size:
        if control == 1:
            control = struct.unpack_from("<I", src, pos)[0]
            pos += 4
        if control & 1:
            w = struct.unpack_from("<I", src, pos)[0]
            mask, oshift, lmask, lshift, n = _DOBOZ[w & 7]
            offset = (w & mask) >> oshift
            length = ((w >> lshift) & lmask) + 3
            pos += n
            start = len(out) - offset
            for k in range(length):
                out.append(out[start + k])
        else:
            out.append(src[pos])
            pos += 1
        control >>= 1
    return bytes(out[:size])


def read(bundle, entry):
    name, size, zsize, offset, comp = entry
    with open(bundle, "rb") as f:
        f.seek(offset)
        data = f.read(zsize)
    if comp == 0:
        return data[:size]
    if comp == 1:
        return zlib.decompress(data)
    if comp in (4, 5):
        import lz4.block
        return lz4.block.decompress(data, uncompressed_size=size)
    if comp == 3:
        return doboz_decompress(data, size)
    raise ValueError(f"{name}: compression {comp} not supported")


class Depot:
    """Every file of the game by depot path (later bundles / DLCs override earlier ones, as in the game)."""

    _shared = {}                # (game, bundles and their times) -> where: read once while no bundle changes

    def __init__(self, game=None):
        # 1.3 s for its index, made four to seven times a build (07.10.: Build & Play measured) - kept while the
        # bundles are the same files (a new DLC or mod bundle, a changed one: read again); nobody writes to `where`
        paths = list(bundle_paths(game))
        key = (game, tuple((p, os.path.getmtime(p), os.path.getsize(p)) for p in paths if os.path.exists(p)))
        where = Depot._shared.get(key)
        if where is None:
            where = {}
            for b in paths:
                for e in entries(b):
                    where[e[0].lower()] = (b, e)
            Depot._shared.clear()
            Depot._shared[key] = where
        self.where = where

    def exists(self, path):
        return path.lower() in self.where

    def read(self, path):
        b, e = self.where[path.lower()]
        return read(b, e)

    def glob(self, prefix, suffix=""):
        prefix, suffix = prefix.lower(), suffix.lower()
        return [p for p in self.where if p.startswith(prefix) and p.endswith(suffix)]
