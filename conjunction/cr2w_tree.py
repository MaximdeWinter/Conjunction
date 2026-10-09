"""A CR2W file as a tree of typed values, lossless (docs/VANILLA_EDITING_PLAN.md, step 1): every object of a game
quest file with every property as a Python value, changed and written back - an unchanged file comes out byte for
byte as it went in.

An object's data: a 0 byte, its properties, a 0 name; a CQuestScriptBlock then a second list of the same kind (the
function's arguments), again ended by a 0 name. A property: name (u16), type (u16), size (u32, counts itself),
value. Values, by type:

    Bool, Int8 ... Double       int / float / bool
    CName, an enum              str (the name)
    String, StringAnsi          str (a packed length: negative = 8-bit letters, else UTF-16: then Wide)
    LocalizedString             Loc(id)
    handle:X, ptr:X, #X         int (+n: object n, -n: import n, 0: none)
    soft:X                      Soft(import index, 1-based; 0: none)
    CGUID                       Guid(16 bytes)
    TagList                     Tags([names])
    array:a,b,X                 list of X values
    CVariant                    Variant(type, value)
    EngineTransform             Transform(position, rotation, scale) - each 3 floats or None (a flag byte says
                                which follow: 1 position, 2 rotation, 4 scale)
    an enum without an E        str, when its value is 2 bytes and no struct (AQMTN_EntityType)
    a struct                    Struct([Prop ...]) - a 0 byte, its properties, a 0 name
    anything else               Raw(bytes), kept as it was

A value whose bytes this reading would not give back exactly stays Raw - so nothing is ever lost; how much stays
Raw over the game's quest files is checked (tests/test_cr2w_tree.py: none).

    t = Tree(data); t.objects[i].get("factID"); t.objects[i].set("value", 2); t.to_bytes()

Objects are numbered from 1 as the file's handles count them (t.obj(n) is t.objects[n - 1]); an object's parent is
such a number (0: none). Editing keeps every handle pointing where it did:

    t.add(obj)            -> its number (appended: nothing else moves)
    t.copy(n)             -> the copy's number: n and everything under it, new GUIDs, handles inside the copy
                             pointing into the copy
    t.remove(n)           n and everything under it gone; handles to them become 0, the rest renumbered
    t.adopt(other, n)     -> the number of a copy of another file's object n (and everything under it): new GUIDs,
                             the imports it uses found in this file or added
    t.under(n)            the numbers of everything under n (its children, theirs ...)
"""
import copy as _copy
import struct
import uuid

from .cr2w import CR2W

SIMPLE = {"Bool": "<?", "Int8": "<b", "Uint8": "<B", "Int16": "<h", "Uint16": "<H", "Int32": "<i",
          "Uint32": "<I", "Int64": "<q", "Uint64": "<Q", "Float": "<f", "Double": "<d"}
NOT_ENUMS = {"EngineTransform", "EulerAngles"}


class Raw(bytes):
    """Bytes kept as they were (a type not read here)."""


class Wide(str):
    """A String the file keeps as UTF-16 (an empty one too: 0x00, where an 8-bit one is 0x80)."""


class Loc(int):
    """A LocalizedString: the id of a text in the w3strings."""


class Soft(int):
    """A soft handle: an import index, 1-based (0: none)."""


class Guid(bytes):
    def __repr__(self):
        return f"Guid({self.hex()})"


class Tags(list):
    """A TagList: its tag names."""


class Transform:
    def __init__(self, position=None, rotation=None, scale=None):
        self.position, self.rotation, self.scale = position, rotation, scale

    def __eq__(self, other):
        return isinstance(other, Transform) and (self.position, self.rotation, self.scale) == (
            other.position, other.rotation, other.scale)

    def __repr__(self):
        return f"Transform({self.position}, {self.rotation}, {self.scale})"


class Variant:
    def __init__(self, type, value):
        self.type, self.value = type, value

    def __eq__(self, other):
        return isinstance(other, Variant) and (self.type, self.value) == (other.type, other.value)

    def __repr__(self):
        return f"Variant({self.type}, {self.value!r})"


class Prop:
    __slots__ = ("name", "type", "value")

    def __init__(self, name, type, value):
        self.name, self.type, self.value = name, type, value

    def __eq__(self, other):
        return isinstance(other, Prop) and (self.name, self.type, self.value) == (other.name, other.type, other.value)

    def __repr__(self):
        return f"{self.name}:{self.type}={self.value!r}"


class Struct(list):
    """A struct value: its properties in order."""

    def get(self, name, default=None):
        return next((p.value for p in self if p.name == name), default)


def is_enum(typ):
    return typ[:1] in "Ee" and typ[1:2].isupper() and typ not in NOT_ENUMS


# --- packed ints (string lengths, tag counts): the first byte sign (0x80), more (0x40), 6 bits; then 7 bits each
def read_packed(b, i):
    c = b[i]
    neg, v, more, i, shift = c & 0x80, c & 0x3F, c & 0x40, i + 1, 6
    while more:
        c = b[i]
        v |= (c & 0x7F) << shift
        more, shift, i = c & 0x80, shift + 7, i + 1
    return (-v if neg else v), i


def packed(n):
    neg, v = n < 0, abs(n)
    first = (0x80 if neg else 0) | (v & 0x3F)
    v >>= 6
    if not v:
        return bytes([first])
    out = [first | 0x40]
    while v:
        out.append((v & 0x7F) | (0x80 if v >> 7 else 0))
        v >>= 7
    return bytes(out)


class Codec:
    """Reads and writes values of one file (its names and imports)."""

    def __init__(self, f):
        self.f = f

    def name(self, k):
        if k >= len(self.f.names):
            raise ValueError("name index out of range")
        return self.f.names[k]

    # --- reading: (value, offset after it)
    def read(self, typ, b, i, end):
        if typ in SIMPLE:
            fmt = SIMPLE[typ]
            return struct.unpack_from(fmt, b, i)[0], i + struct.calcsize(fmt)
        if typ == "CName":
            return self.name(struct.unpack_from("<H", b, i)[0]), i + 2
        if typ in ("String", "StringAnsi"):
            n, i = read_packed(b, i)
            if n < 0 or b[i - 1] == 0x80:               # (0x80: an empty 8-bit one)
                return bytes(b[i:i - n]).decode("latin-1"), i - n
            return Wide(bytes(b[i:i + 2 * n]).decode("utf-16-le")), i + 2 * n
        if typ == "LocalizedString":
            return Loc(struct.unpack_from("<I", b, i)[0]), i + 4
        if typ.startswith(("handle:", "ptr:", "#")):
            return struct.unpack_from("<i", b, i)[0], i + 4
        if typ.startswith("soft:"):
            return Soft(struct.unpack_from("<H", b, i)[0]), i + 2
        if typ == "EngineTransform":
            flags, i, parts = b[i], i + 1, []
            for bit in (1, 2, 4):
                if flags & bit:
                    parts.append(tuple(struct.unpack_from("<3f", b, i)))
                    i += 12
                else:
                    parts.append(None)
            if flags & ~7:
                raise ValueError("transform flags")
            return Transform(*parts), i
        if typ == "CGUID":
            return Guid(b[i:i + 16]), i + 16
        if typ == "TagList":
            n, i = read_packed(b, i)
            return Tags(self.name(struct.unpack_from("<H", b, i + 2 * k)[0]) for k in range(n)), i + 2 * n
        if typ.startswith("array:"):
            inner = typ.split(",", 2)[2]
            n, i = struct.unpack_from("<I", b, i)[0], i + 4
            out = []
            for _k in range(n):
                v, i = self.read(inner, b, i, end)
                out.append(v)
            return out, i
        if typ == "CVariant":
            t, size = struct.unpack_from("<HI", b, i)
            vt = self.name(t)
            v, j = self.read(vt, b, i + 6, i + 2 + size)
            if j != i + 2 + size:
                raise ValueError("variant size")
            return Variant(vt, v), j
        if is_enum(typ):
            return self.name(struct.unpack_from("<H", b, i)[0]), i + 2
        if b[i] == 0 and end - i > 2:                   # a struct
            props, i = self.read_props(b, i + 1, end)
            return Struct(props), i
        if end - i == 2:                                # an enum not named E... (its value: a name)
            return self.name(struct.unpack_from("<H", b, i)[0]), i + 2
        raise ValueError(f"unknown type {typ}")

    def read_props(self, b, i, end):
        """Properties up to a 0 name -> ([Prop], offset after the 0 name). A value read back differently stays Raw."""
        out = []
        while True:
            nm = struct.unpack_from("<H", b, i)[0]
            if nm == 0:
                return out, i + 2
            tp, size = struct.unpack_from("<HI", b, i + 2)
            name, typ = self.name(nm), self.name(tp)
            vs, ve = i + 8, i + 4 + size
            if ve > end or size < 4:
                raise ValueError("property size")
            raw = bytes(b[vs:ve])
            try:
                v, j = self.read(typ, b, vs, ve)
                if j != ve or self.write(typ, v) != raw:
                    v = Raw(raw)
            except (ValueError, struct.error, IndexError, UnicodeDecodeError):
                v = Raw(raw)
            out.append(Prop(name, typ, v))
            i = ve

    # --- writing
    def write(self, typ, v):
        if isinstance(v, Raw):
            return bytes(v)
        f = self.f
        if typ in SIMPLE:
            return struct.pack(SIMPLE[typ], v)
        if typ in ("String", "StringAnsi"):
            if not isinstance(v, Wide) and all(ord(c) < 256 for c in v):
                data = v.encode("latin-1")
                return (packed(-len(data)) if data else b"\x80") + data
            data = v.encode("utf-16-le")
            return packed(len(data) // 2) + data
        if typ == "CName" or (isinstance(v, str) and not isinstance(v, Struct)):     # (an enum: its name)
            return struct.pack("<H", f.add_name(v))
        if typ == "LocalizedString":
            return struct.pack("<I", v)
        if typ.startswith(("handle:", "ptr:", "#")):
            return struct.pack("<i", v)
        if typ == "EngineTransform":
            parts = (v.position, v.rotation, v.scale)
            return bytes([sum(bit for bit, x in zip((1, 2, 4), parts) if x is not None)]) + b"".join(
                struct.pack("<3f", *x) for x in parts if x is not None)
        if typ.startswith("soft:"):
            return struct.pack("<H", v)
        if typ == "CGUID":
            return bytes(v)
        if typ == "TagList":
            return packed(len(v)) + b"".join(struct.pack("<H", f.add_name(n)) for n in v)
        if typ.startswith("array:"):
            inner = typ.split(",", 2)[2]
            return struct.pack("<I", len(v)) + b"".join(self.write(inner, x) for x in v)
        if typ == "CVariant":
            data = self.write(v.type, v.value)
            return struct.pack("<HI", f.add_name(v.type), len(data) + 4) + data
        if isinstance(v, Struct):
            return b"\0" + self.write_props(v)
        raise ValueError(f"cannot write {typ}: {v!r}")

    def write_props(self, props):
        out = bytearray()
        for p in props:
            data = self.write(p.type, p.value)
            out += struct.pack("<HHI", self.f.add_name(p.name), self.f.add_name(p.type), len(data) + 4) + data
        return bytes(out + b"\0\0")


class Obj:
    """One object of the file: its class, its export fields, its properties (and a script block's arguments)."""

    def __init__(self, cls, flags, parent, template, props, args=None, rest=b""):
        self.cls, self.flags, self.parent, self.template = cls, flags, parent, template
        self.props, self.args, self.rest = props, args, rest

    def prop(self, name):
        return next((p for p in self.props if p.name == name), None)

    def get(self, name, default=None):
        p = self.prop(name)
        return p.value if p is not None else default

    def set(self, name, value, typ=None):
        """A property's value; a property the object lacks is added (its type then needed)."""
        p = self.prop(name)
        if p is None:
            if typ is None:
                raise KeyError(f"{self.cls} has no {name}: give its type")
            self.props.append(Prop(name, typ, value))
        else:
            p.value = value

    def __repr__(self):
        return f"<{self.cls} {self.props!r}>"


class Tree:
    def __init__(self, data):
        self.f = CR2W(data)
        self.codec = Codec(self.f)
        self.objects = [self._read(e) for e in self.f.exports]

    def _read(self, export):
        cls, flags, parent, template, chunk = export
        b = bytes(chunk)
        if not b or b[0] != 0:
            return Obj(cls, flags, parent, template, None, rest=b)
        try:
            props, i = self.codec.read_props(b, 1, len(b))
        except (ValueError, struct.error, IndexError):
            return Obj(cls, flags, parent, template, None, rest=b)
        args = None
        if i < len(b):
            try:
                args, j = self.codec.read_props(b, i, len(b))
                if j == len(b):
                    i = j
                else:
                    args = None
            except (ValueError, struct.error, IndexError):
                args = None
        return Obj(cls, flags, parent, template, props, args, b[i:])

    def chunk(self, o):
        if o.props is None:
            return bytes(o.rest)
        out = b"\0" + self.codec.write_props(o.props)
        if o.args is not None:
            out += self.codec.write_props(o.args)
        return out + bytes(o.rest)

    def to_bytes(self):
        chunks = [self.chunk(o) for o in self.objects]   # (names added first: the writer wants them all)
        for o in self.objects:
            self.f.add_name(o.cls)
        for _path, cls, _fl in self.f.imports:          # (an import's class too: added before the writer runs)
            self.f.add_name(cls)
        self.f.exports = [[o.cls, o.flags, o.parent, o.template, bytearray(c)] for o, c in zip(self.objects, chunks)]
        return self.f.save()

    def raw_values(self):
        """Every value kept as Raw: [(object index, class, property path, type)]."""
        out = []

        def walk(i, cls, props, path):
            for p in props or []:
                here = f"{path}{p.name}"
                if isinstance(p.value, Raw):
                    out.append((i, cls, here, p.type))
                elif isinstance(p.value, Struct):
                    walk(i, cls, p.value, here + ".")
                elif isinstance(p.value, list):
                    for k, x in enumerate(p.value):
                        if isinstance(x, Struct):
                            walk(i, cls, x, f"{here}[{k}].")
        for i, o in enumerate(self.objects):
            if o.props is None:
                out.append((i, o.cls, "(whole object)", ""))
            walk(i, o.cls, o.props, "")
            walk(i, o.cls, o.args, "(args).")
            if o.rest:
                out.append((i, o.cls, "(rest)", ""))
        return out

    # --- editing
    def obj(self, n):
        return self.objects[n - 1]

    def under(self, n):
        """Everything under object n (its children, theirs ...), by number, in file order."""
        kids = {}
        for k, o in enumerate(self.objects, 1):
            kids.setdefault(o.parent, []).append(k)
        out, todo = [], list(kids.get(n, []))
        while todo:
            k = todo.pop(0)
            if k not in out and k != n:
                out.append(k)
                todo += kids.get(k, [])
        return sorted(out)

    def renumber(self, fn, imp=None):
        """Every handle to an object (+n) and every parent passed through fn(n) -> its new number (0: gone); with
        `imp`, every import a handle or soft handle names through imp(k) -> its new index (1-based)."""
        def conv(typ, v):
            if isinstance(v, Raw):
                return v
            if typ.startswith("soft:"):
                return Soft(imp(v)) if imp and isinstance(v, int) and v > 0 else v
            if typ.startswith(("handle:", "ptr:", "#")):
                if isinstance(v, int) and v > 0:
                    return fn(v)
                return -imp(-v) if imp and isinstance(v, int) and v < 0 else v
            if typ.startswith("array:") and isinstance(v, list):
                inner = typ.split(",", 2)[2]
                v[:] = [conv(inner, x) for x in v]
                return v
            if isinstance(v, Variant):
                v.value = conv(v.type, v.value)
                return v
            if isinstance(v, Struct):
                for p in v:
                    p.value = conv(p.type, p.value)
            return v
        for o in self.objects:
            for props in (o.props, o.args):
                for p in props or []:
                    p.value = conv(p.type, p.value)
            if o.parent:
                o.parent = fn(o.parent)

    def add(self, o):
        self.objects.append(o)
        return len(self.objects)

    def remove(self, n):
        gone = {n, *self.under(n)}
        new, k = {}, 0
        for i in range(1, len(self.objects) + 1):
            if i not in gone:
                k += 1
                new[i] = k
        self.objects = [o for i, o in enumerate(self.objects, 1) if i not in gone]
        self.renumber(lambda i: new.get(i, 0))

    def copy(self, n, parent=None):
        """A copy of object n and everything under it, appended: new GUIDs, its parent `parent` (default: n's)."""
        olds = self.with_parts([n])
        base = len(self.objects)
        new = {old: base + k for k, old in enumerate(olds, 1)}
        copies = [_copy.deepcopy(self.obj(old)) for old in olds]
        keep = self.objects
        self.objects = copies                           # (renumber only the copies: inside ones to the copies)
        self.renumber(lambda i: new.get(i, i))
        self.objects = keep + copies
        copies[0].parent = self.obj(n).parent if parent is None else parent
        _fresh_guids(copies)
        return new[n]

    def adopt(self, other, n, parent=0):
        """A copy of `other`'s object n and everything under it, appended to this file: handles inside the copy
        point into it (outside it: 0), the imports it names found here or added; new GUIDs."""
        return self.adopt_many(other, [n], parent)[0]

    def refs(self, n):
        """The objects object n's values point at (+n handles)."""
        out = []

        def walk(typ, v):
            if typ.startswith(("handle:", "ptr:", "#")) and isinstance(v, int) and not isinstance(v, bool) and v > 0:
                out.append(v)
            elif typ.startswith("array:") and isinstance(v, list):
                inner = typ.split(",", 2)[2]
                for x in v:
                    walk(inner, x)
            elif isinstance(v, Variant):
                walk(v.type, v.value)
            elif isinstance(v, Struct):
                for q in v:
                    walk(q.type, q.value)
        o = self.obj(n)
        for props in (o.props, o.args):
            for q in props or []:
                walk(q.type, q.value)
        return out

    def with_parts(self, ns):
        """Objects ns, everything under them, and the journal paths they name (a path's parts are not children of
        what names it: they come along through `child`)."""
        olds = []
        todo = list(ns)
        while todo:
            n = todo.pop(0)
            for k in [n] + self.under(n):
                if k not in olds:
                    olds.append(k)
                    todo += [r for r in self.refs(k) if r not in olds and self.obj(r).cls in KEEP_GUID]
        return olds

    def adopt_many(self, other, ns, parent=0):
        """adopt for several objects at once: handles between them (one block's link to another) kept. -> their new
        numbers, in order."""
        olds = other.with_parts(ns)
        base = len(self.objects)
        new = {old: base + k for k, old in enumerate(olds, 1)}
        copies = [_copy.deepcopy(other.obj(old)) for old in olds]
        tops = {new[n] for n in ns}

        def imp(k):
            if not 0 < k <= len(other.f.imports):
                return 0
            path, cls, fl = other.f.imports[k - 1]
            for i, (p2, c2, _f) in enumerate(self.f.imports, 1):
                if p2 == path and c2 == cls:
                    return i
            self.f.imports.append([path, cls, fl])
            return len(self.f.imports)
        keep = self.objects
        self.objects = copies
        self.renumber(lambda i: new.get(i, 0), imp)
        self.objects = keep + copies
        for k in tops:
            self.objects[k - 1].parent = parent
        _fresh_guids(copies)
        return [new[n] for n in ns]


KEEP_GUID = {"CJournalPath"}     # its GUID points at a journal entry (the same in every quest that names it)


def _fresh_guids(objs):
    """New GUIDs for copied objects (a block's GUID is what saves remember: two blocks never share one)."""
    def fresh(props):
        for p in props or []:
            if p.type == "CGUID" and p.name in ("guid", "GUID"):
                p.value = Guid(uuid.uuid4().bytes)
            elif isinstance(p.value, Struct):
                fresh(p.value)
    for o in objs:
        if o.cls in KEEP_GUID:
            continue
        fresh(o.props)
