"""CR2W (The Witcher 3 resource files): read, change, write - enough for Conjunction's own small resources (the coloured
gizmo meshes made from meshes wcc_lite imported).

Layout (checked against REDkit's files): header 0x28 bytes (magic, version, flags, timestamp u64, build, fileSize =
end of the object data, bufferSize = whole file, crc, table count), 10 table headers (offset, count, crc32 of the
table's bytes), tables: 0 strings, 1 names (string offset, hash), 2 imports (path offset, class name, flags),
3 properties (16 bytes), 4 exports (class name, flags, parent, size, offset, template, crc32 of the data),
5 buffers (flags, index, offset, disk size, mem size, crc32). Then the object data, then the buffers (absolute
offsets). The header crc is crc32 of the first 0xA0 bytes with the crc field set to 0xDEADBEEF.
A property is written as name index (u16), type index (u16), size (u32, counts itself), value; a struct's fields
likewise, ended by name 0. A handle is an i32: -n = import n-1, +n = export n-1.

A name's hash: FNV-1a 32 of its UTF-8 bytes with the closing 0 byte (known_hash) - any new name can be added.
"""
import struct
import zlib

ITEM = [1, 8, 8, 16, 24, 24, 0, 0, 0, 0]


class CR2W:
    def __init__(self, data):
        d = bytes(data)
        if d[:4] != b"CR2W":
            raise ValueError("not a CR2W file")
        self.data = bytearray(d)
        (_, self.version, self.flags, self.timestamp, self.build, _fs, _bs, _crc,
         self.table_count) = struct.unpack_from("<4sIIQIIIII", d, 0)
        self.tables = [struct.unpack_from("<III", d, 0x28 + i * 12) for i in range(10)]
        s_off, s_len, _ = self.tables[0]
        strings = d[s_off:s_off + s_len]
        self.strings = bytes(strings)       # kept: written back in its own order (an unchanged file stays the same)
        text = lambda o: strings[o:strings.index(b"\0", o)].decode("utf-8", "replace")   # noqa: E731
        n_off, n_cnt, _ = self.tables[1]
        self.names, self.hashes = [], []
        for i in range(n_cnt):
            o, h = struct.unpack_from("<II", d, n_off + i * 8)
            self.names.append(text(o))
            self.hashes.append(h)
        i_off, i_cnt, _ = self.tables[2]
        self.imports = []                   # [path, class name, flags]
        for i in range(i_cnt):
            o, cls, fl = struct.unpack_from("<IHH", d, i_off + i * 8)
            self.imports.append([text(o), self.names[cls], fl])
        p_off, p_cnt, _ = self.tables[3]
        self.properties = [d[p_off + i * 16:p_off + (i + 1) * 16] for i in range(p_cnt)]
        e_off, e_cnt, _ = self.tables[4]
        self.exports = []                   # [class name, flags, parent, template, data]
        for i in range(e_cnt):
            cls, fl, parent, size, off, tmpl, _crc = struct.unpack_from("<HHIIIII", d, e_off + i * 24)
            self.exports.append([self.names[cls], fl, parent, tmpl, bytearray(d[off:off + size])])
        b_off, b_cnt, _ = self.tables[5]
        self.buffers = []                   # [flags, index, data, mem size]
        for i in range(b_cnt):
            fl, idx, off, disk, mem, _crc = struct.unpack_from("<IIIIII", d, b_off + i * 24)
            self.buffers.append([fl, idx, d[off:off + disk], mem])
        # tables 6.. (embedded files and more) are not read; such a file can be read but not written back
        self.writable = not any(self.tables[t][1] for t in range(6, 10))

    # --- names
    def name_index(self, name):
        return self.names.index(name)

    def add_name(self, name):
        if name in self.names:
            return self.names.index(name)
        self.names.append(name)
        self.hashes.append(known_hash(name))
        return len(self.names) - 1

    # --- reading helpers
    def props(self, chunk, start=1):
        """(name, type, value offset, value size) of the properties of an object's data (it starts with a 0 byte)."""
        out, i = [], start
        while i + 2 <= len(chunk):
            nm = struct.unpack_from("<H", chunk, i)[0]
            if nm == 0:
                break
            tp, sz = struct.unpack_from("<HI", chunk, i + 2)
            out.append((self.names[nm], self.names[tp], i + 8, sz - 4))
            i += 4 + sz
        return out

    def colors(self):
        """Offsets of every Color struct value in the file: (offset of the Red byte, (r, g, b, a))."""
        try:
            red, green, blue, alpha, u8 = (self.name_index(n) for n in ("Red", "Green", "Blue", "Alpha", "Uint8"))
        except ValueError:
            return []
        field = lambda nm: struct.pack("<HHI", nm, u8, 5)       # noqa: E731
        out, i = [], 0
        while True:
            i = self.data.find(field(red), i)
            if i < 0:
                return out
            v = i + 8
            if (self.data[v + 1:v + 9] == field(green) and self.data[v + 10:v + 18] == field(blue)
                    and self.data[v + 19:v + 27] == field(alpha)):
                out.append((v, (self.data[v], self.data[v + 9], self.data[v + 18], self.data[v + 27])))
            i += 1

    # --- writing
    def color_struct(self, rgba):
        """A Color value: the struct's fields Red / Green / Blue / Alpha (Uint8), ended by name 0."""
        u8 = self.add_name("Uint8")
        out = bytearray(b"\0")
        for nm, v in zip(("Red", "Green", "Blue", "Alpha"), rgba):
            out += struct.pack("<HHIB", self.add_name(nm), u8, 5, v)
        return bytes(out + b"\0\0")

    def save(self):
        if not self.writable:
            raise ValueError("this file uses tables the writer does not know (embedded files)")
        # strings: the file's own table as it was (its order), new names and import paths after it
        strings, offsets = bytearray(self.strings), {}
        o = 0
        while o < len(self.strings):
            end = self.strings.index(b"\0", o)
            offsets.setdefault(self.strings[o:end].decode("utf-8", "replace"), o)
            o = end + 1

        def put(s):
            if s not in offsets:
                offsets[s] = len(strings)
                strings.extend(s.encode("utf-8") + b"\0")
            return offsets[s]
        for n in self.names:
            put(n)
        for path, _cls, _fl in self.imports:
            put(path)
        names = b"".join(struct.pack("<II", offsets[n], h) for n, h in zip(self.names, self.hashes))
        imports = b"".join(struct.pack("<IHH", offsets[p], self.add_name(c), fl) for p, c, fl in self.imports)
        props = b"".join(self.properties)
        # exports and buffers need their final offsets: lay out the tables first
        pos = 0xA0
        layout = []
        for blob, count in ((strings, len(strings)), (names, len(self.names)), (imports, len(self.imports)),
                            (props, len(self.properties))):
            layout.append((pos, count, zlib.crc32(bytes(blob)), blob))
            pos += len(blob)
        exports_off = pos
        pos += 24 * len(self.exports)
        buffers_off = pos
        pos += 24 * len(self.buffers)
        data_off = pos
        exports, datas = bytearray(), bytearray()
        for cls, fl, parent, tmpl, chunk in self.exports:
            exports += struct.pack("<HHIIIII", self.add_name(cls), fl, parent, len(chunk), data_off + len(datas),
                                   tmpl, zlib.crc32(bytes(chunk)))
            datas += chunk
        file_size = data_off + len(datas)
        buffers, bufdata = bytearray(), bytearray()
        for fl, idx, blob, mem in self.buffers:
            buffers += struct.pack("<IIIIII", fl, idx, file_size + len(bufdata), len(blob), mem, zlib.crc32(blob))
            bufdata += blob
        if len(names) != 8 * len(self.names):
            raise RuntimeError("a class name was added while saving - add names before save()")
        layout.append((exports_off, len(self.exports), zlib.crc32(bytes(exports)), exports))
        layout.append((buffers_off, len(self.buffers), zlib.crc32(bytes(buffers)), buffers))
        out = bytearray(0xA0)
        struct.pack_into("<4sIIQIIIII", out, 0, b"CR2W", self.version, self.flags, self.timestamp, self.build,
                         file_size, file_size + len(bufdata), 0xDEADBEEF, self.table_count)
        for i, (off, cnt, crc, _blob) in enumerate(layout):
            # an empty table has no place (as the game writes it: offset 0)
            struct.pack_into("<III", out, 0x28 + i * 12, off if cnt else 0, cnt, crc)
        struct.pack_into("<I", out, 32, zlib.crc32(bytes(out)))
        for _off, _cnt, _crc, blob in layout:
            out += blob
        return bytes(out + datas + bufdata)


def known_hash(name):
    """A name's hash in the name table: FNV-1a (32 bit) of its UTF-8 bytes with the closing 0 byte; the empty name 0.
    (Found 30.09.: 41 400 of the 41 402 names of the game's quest files - the other two: the empty one, one whose
    bytes were not UTF-8.)"""
    if not name:
        return 0
    h = 0x811C9DC5
    for c in name.encode("utf-8") + b"\0":
        h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF
    return h


if __name__ == "__main__":
    import sys
    f = CR2W(open(sys.argv[1], "rb").read())
    print("version", f.version, "names", len(f.names))
    print(f.names[:80])
    print("imports", f.imports)
    print("exports", [(e[0], e[2], len(e[4])) for e in f.exports])
    print("colors", f.colors())
    same = f.save() == open(sys.argv[1], "rb").read()
    print("writes back identically:", same)
