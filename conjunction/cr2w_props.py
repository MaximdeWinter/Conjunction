"""Properties of a CR2W object, decoded generically: numbers, names, strings, handles (to exports and imports),
arrays and structs - enough to read the game's quest graphs and scenes (questread.py).

    decode(f, chunk) -> {name: value}
    values: int / float / bool / str (CName, String, enum), ("export", i) / ("import", path), [..], {..} (a struct),
    bytes (a type not known here)
"""
import struct

SIMPLE = {"Bool": ("<?", 1), "Int8": ("<b", 1), "Uint8": ("<B", 1), "Int16": ("<h", 2), "Uint16": ("<H", 2),
          "Int32": ("<i", 4), "Uint32": ("<I", 4), "Int64": ("<q", 8), "Uint64": ("<Q", 8), "Float": ("<f", 4),
          "Double": ("<d", 8)}


def _string(v):
    """A String: a length byte (0x80: 8-bit letters, 0x40: one more length byte), then the letters."""
    if not v:
        return ""
    b = v[0]
    n, i = b & 0x3F, 1
    if b & 0x40:
        n += v[1] << 6
        i = 2
    if b & 0x80:
        return bytes(v[i:i + n]).decode("latin-1", "replace")
    return bytes(v[i:i + 2 * n]).decode("utf-16-le", "replace")


def _ref(f, h):
    if h > 0:
        return ("export", h)
    if h < 0 and -h - 1 < len(f.imports):
        return ("import", f.imports[-h - 1][0])
    return None


def value(f, typ, v):
    """One property value of type `typ` from the bytes `v`."""
    if typ in SIMPLE:
        fmt, n = SIMPLE[typ]
        return struct.unpack_from(fmt, v)[0] if len(v) >= n else None
    if typ == "CName":
        k = struct.unpack_from("<H", v)[0] if len(v) >= 2 else 0
        return f.names[k] if k < len(f.names) else None
    if typ in ("String", "StringAnsi"):
        return _string(v)
    if typ == "CVariant":                           # a value with its own type: type name, size, the value
        if len(v) < 6:
            return None
        t, sz = struct.unpack_from("<HI", v)
        return value(f, f.names[t], v[6:2 + sz]) if t < len(f.names) else None
    if typ == "LocalizedString":
        return ("string", struct.unpack_from("<I", v)[0]) if len(v) >= 4 else None
    if typ.startswith(("ptr:", "handle:")):
        return _ref(f, struct.unpack_from("<i", v)[0]) if len(v) >= 4 else None
    if typ.startswith("soft:"):
        k = struct.unpack_from("<H", v)[0] if len(v) >= 2 else 0
        return ("import", f.imports[k - 1][0]) if 0 < k <= len(f.imports) else None
    if typ.startswith("array:"):
        inner = typ.split(",", 2)[2]
        n, i, out = struct.unpack_from("<I", v)[0], 4, []
        if inner in SIMPLE:
            fmt, size = SIMPLE[inner]
            return [struct.unpack_from(fmt, v, 4 + k * size)[0] for k in range(n)]
        if inner == "CName" or inner.startswith("soft:"):
            return [value(f, inner, v[4 + 2 * k:6 + 2 * k]) for k in range(n)]
        if inner.startswith(("ptr:", "handle:")):
            return [value(f, inner, v[4 + 4 * k:8 + 4 * k]) for k in range(n)]
        if inner == "String":
            for _k in range(n):
                s = _string(v[i:])
                b = v[i]
                ln = (b & 0x3F) + ((v[i + 1] << 6) if b & 0x40 else 0)
                i += (2 if b & 0x40 else 1) + (ln if b & 0x80 else 2 * ln)
                out.append(s)
            return out
        for _k in range(n):                         # structs one after the other
            if i >= len(v):
                break
            item, i = struct_at(f, v, i)
            out.append(item)
        return out
    if len(v) == 2 and not v[:1] == b"\0":
        k = struct.unpack_from("<H", v)[0]         # an enum: its value's name
        return f.names[k] if k < len(f.names) else k
    if v[:1] == b"\0":
        try:
            return struct_at(f, v, 0)[0]
        except (struct.error, IndexError):
            return bytes(v)
    return bytes(v)


def struct_at(f, v, i):
    """A serialized struct at v[i] (a 0 byte, properties, a 0 name) -> ({name: value}, the offset after it)."""
    out, i = {}, i + 1
    while i + 2 <= len(v):
        nm = struct.unpack_from("<H", v, i)[0]
        if nm == 0:
            return out, i + 2
        tp, sz = struct.unpack_from("<HI", v, i + 2)
        out[f.names[nm]] = value(f, f.names[tp], v[i + 8:i + 4 + sz])
        i += 4 + sz
    return out, i


def decode(f, chunk):
    """{name: value} of an object's properties (its data starts with a 0 byte)."""
    out = {}
    for name, typ, off, sz in f.props(chunk):
        try:
            out[name] = value(f, typ, chunk[off:off + sz])
        except (struct.error, IndexError, UnicodeDecodeError):
            out[name] = bytes(chunk[off:off + sz])
    return out
