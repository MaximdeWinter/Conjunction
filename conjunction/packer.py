"""A remaster bundle written by Conjunction (02.10.: 'wcc_lite pack' is 21 s of starting it for a few small files) - the
layout wcc_lite writes, measured on its bundles:

    header 0x20: 'POTATO70', u32 the bundle's size rounded up to 16, u32 0, u32 the table's size, u16 5,
                 u16 where the data begins (0x20 + the table), 8 zero bytes
    table: 0x130 per file - the depot path (0x100, zero padded), a hash (16 zero bytes), u64 offset, u32 size,
           u32 stored size, u32 crc32 of the file, u32 compression (5 = lz4 hc)
    data: the files in the reverse order of the table, each at a 16-byte boundary, nothing after the last

    pack(folder, out_dir)        every file under `folder` (paths from it) -> out_dir/blob0.bundle
"""
import os
import struct
import zlib

ENTRY = 0x130
LZ4HC = 5


def _compress(raw):
    import lz4.block
    return lz4.block.compress(raw, mode="high_compression", store_size=False)


def pack(folder, out_dir, name="blob0.bundle", skip=("cook.db",)):
    """The files under `folder` (cooked: dlc\\<dlc>\\...) into one bundle -> its path."""
    files = []
    for d, _s, fs in os.walk(folder):
        for f in fs:
            if f in skip:
                continue
            full = os.path.join(d, f)
            files.append((os.path.relpath(full, folder).replace("/", "\\"), full))
    files.sort(key=lambda x: x[0].lower())
    toc = ENTRY * len(files)
    start = 0x20 + toc
    blocks, offsets, pos = [], [None] * len(files), start
    for i in reversed(range(len(files))):                 # (the data in the reverse order of the table)
        pos = (pos + 15) & ~15
        raw = open(files[i][1], "rb").read()
        stored = _compress(raw)
        comp = LZ4HC
        if len(stored) >= len(raw):                          # (nothing gained: stored as it is)
            stored, comp = raw, 0
        offsets[i] = (pos, len(raw), len(stored), zlib.crc32(raw) & 0xFFFFFFFF, comp)
        blocks.append((pos, stored))
        pos += len(stored)
    size = pos
    out = bytearray(size)
    struct.pack_into("<8sIIIHH8x", out, 0, b"POTATO70", (size + 15) & ~15, 0, toc, 5, start)
    for i, (path, _f) in enumerate(files):
        o = 0x20 + i * ENTRY
        p = path.encode("ascii")
        if len(p) >= 0x100:
            raise ValueError(f"path too long for a bundle: {path}")
        out[o:o + len(p)] = p
        off, n, z, crc, comp = offsets[i]
        struct.pack_into("<QIIII", out, o + 0x110, off, n, z, crc, comp)
    for pos, stored in blocks:
        out[pos:pos + len(stored)] = stored
    os.makedirs(out_dir, exist_ok=True)
    target = os.path.join(out_dir, name)
    open(target + ".tmp", "wb").write(out)
    os.replace(target + ".tmp", target)
    return target
