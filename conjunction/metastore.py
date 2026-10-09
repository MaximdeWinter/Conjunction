"""metadata.store, the index beside a DLC's bundles (02.10.: 'wcc_lite metadatastore' is 26 s of starting it) - read
and written by Conjunction. The format after w3edit (Systemcluster, BSD-2: src/metadata.rs), version 7 of the remaster:

    header: '\\x03VTM', u32 version 7, u32 the largest stored size, u32 the largest size
    the string table (vlq length + bytes; offset 0 = the empty string), then seven arrays (vlq count + records):
    file_infos (32 bytes: name, path hash, stored size, size, first entry, compression, buffer id, has buffer),
    entry_infos (24: u64 offset in the bundle, stored size, next entry, file, bundle),
    bundle_infos (24: u64 data block size, data block offset, name, first entry, number of entries),
    buffers (u32 each), dir_init_infos (8: name, parent), file_init_infos (12: file, directory, leaf name),
    hashes (16: i64 hash, i64 file)

    read(data) -> dict            write(store) -> bytes            build(bundles) -> bytes   (the order wcc_lite uses)
"""
import struct


def vlq_read(buf, i):
    """CR2W's variable length int: first byte 6 bits (0x40 more, 0x80 negative), then 7 bits each (0x80 more)."""
    b = buf[i]
    neg, more, val = b & 0x80, b & 0x40, b & 0x3F
    i += 1
    shift = 6
    while more:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        shift += 7
        more = b & 0x80
    return (-val if neg else val), i


def vlq_write(value):
    neg = value < 0
    v = abs(value)
    first = v & 0x3F
    v >>= 6
    out = bytearray([first | (0x80 if neg else 0) | (0x40 if v else 0)])
    while v:
        b = v & 0x7F
        v >>= 7
        out.append(b | (0x80 if v else 0))
    return bytes(out)


def read(data):
    assert data[:4] == b"\x03VTM", data[:4]
    version, max_z, max_size = struct.unpack_from("<III", data, 4)
    n, i = vlq_read(data, 16)
    strings = data[i:i + n]
    i += n

    def array(i, width):
        count, i = vlq_read(data, i)
        return [data[i + k * width:i + (k + 1) * width] for k in range(count)], i + count * width
    recs, i = array(i, 32)
    files = [struct.unpack("<8I", r) for r in recs]
    recs, i = array(i, 24)
    entries = [struct.unpack("<QIIII", r) for r in recs]          # offset, size, next, file, bundle
    recs, i = array(i, 24)
    bundles = [struct.unpack("<QIIII", r) for r in recs]          # block size, block offset, name, first, count
    recs, i = array(i, 4)
    buffers = [struct.unpack("<I", r)[0] for r in recs]
    recs, i = array(i, 8)
    dirs = [struct.unpack("<ii", r) for r in recs]
    recs, i = array(i, 12)
    inits = [struct.unpack("<iii", r) for r in recs]
    recs, i = array(i, 16)
    hashes = [struct.unpack("<qq", r) for r in recs]
    return {"version": version, "max_z": max_z, "max_size": max_size, "strings": strings, "files": files,
            "entries": entries, "bundles": bundles, "buffers": buffers, "dirs": dirs, "inits": inits,
            "hashes": hashes, "end": i}


def write(s):
    out = bytearray(b"\x03VTM")
    out += struct.pack("<III", s["version"], s["max_z"], s["max_size"])
    out += vlq_write(len(s["strings"])) + s["strings"]
    for key, fmt in (("files", "<8I"), ("entries", "<QIIII"), ("bundles", "<QIIII"), ("buffers", "<I"),
                     ("dirs", "<ii"), ("inits", "<iii"), ("hashes", "<qq")):
        # (wcc_lite writes an empty buffer list's count as a negative zero, 0x80)
        out += b"\x80" if key == "buffers" and not s[key] else vlq_write(len(s[key]))
        for r in s[key]:
            out += struct.pack(fmt, *(r if isinstance(r, tuple) else (r,)))
    return bytes(out)


def string_at(strings, off):
    return strings[off:strings.index(b"\0", off)].decode("ascii", "replace")


def fnv64(data):
    h = 0xcbf29ce484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def build(bundles):
    """The store wcc_lite writes for `bundles` [(file name, path)] - in its order (measured on its stores: the files in
    the order of their data, the bundle's name first in the string table, an empty name for the root directory, the
    directories as the paths bring them, a file's own name pointing into its path, the hashes (fnv64 of the path)
    sorted, the first file's hash record with 0 where the others have -1) -> bytes."""
    from .bundles import entries as bundle_entries
    strings = bytearray(b"\0")

    def intern(text):
        off = len(strings)
        strings.extend(text.encode("ascii") + b"\0")
        return off
    files, binfo = [], []
    for k, (name, path) in enumerate(bundles, 1):
        name_off = intern(name)
        data = open(path, "rb").read(32)
        size, toc = struct.unpack_from("<I", data, 8)[0], struct.unpack_from("<I", data, 16)[0]
        start = 0x20 + toc
        rows = sorted(bundle_entries(path), key=lambda e: e[3])        # (path, size, zsize, offset, compression)
        binfo.append((name_off, start, size - start, rows, k))
        files += [(r, k) for r in rows]
    path_off = [intern(r[0]) for r, _k in files]
    root = intern("")
    dirs, children, inits = [(root, 0)], {}, []
    for i, (r, _k) in enumerate(files):
        parts = r[0].split("\\")
        cur = 0
        for comp in parts[:-1]:
            key = (cur, comp)
            if key not in children:
                children[key] = len(dirs)
                dirs.append((intern(comp), cur))
            cur = children[key]
        inits.append((i + 1, cur, path_off[i] + len(r[0]) - len(parts[-1])))
    recs = [(0,) * 8] + [(path_off[i], 0, r[2], r[1], i + 1, 0, 0, r[4]) for i, (r, _k) in enumerate(files)]
    ents = [(0, 0, 0, 0, 0)] + [(r[3], r[2], 0, i + 1, k) for i, (r, k) in enumerate(files)]
    first = 1
    bund = [(0, 0, 0, 0, 0)]
    for name_off, start, block, rows, _k in binfo:
        bund.append((block, start, name_off, first if rows else 0, len(rows)))
        first += len(rows)
    hashes = []
    for i, (r, _k) in enumerate(files):
        h = fnv64(r[0].encode("ascii"))
        hi = 0 if i == 0 else 0xFFFFFFFF
        hashes.append((h - (1 << 64) if h >= 1 << 63 else h, struct.unpack("<q", struct.pack("<II", i + 1, hi))[0]))
    hashes.sort(key=lambda x: x[0] & 0xFFFFFFFFFFFFFFFF)
    return write({"version": 7, "max_z": max((r[2] for r, _k in files), default=0),
                  "max_size": max((r[1] for r, _k in files), default=0), "strings": bytes(strings),
                  "files": recs, "entries": ents, "bundles": bund, "buffers": [], "dirs": dirs, "inits": inits,
                  "hashes": hashes})
