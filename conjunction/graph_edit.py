"""Changing a game quest's graph (level 3 of docs/editing-game-quests.md - breaks saves of that quest): a block put
between two blocks of a phase, written back with the CR2W writer (which writes the game's quest files byte for byte).

    insert_fact_after(f, block, socket, fact, value) - a 'set fact' block after `block` (export index, 1-based): what
        `block` led to on `socket` now follows the new one. Returns the new block's export index.
    insert_wait_after(f, block, socket, fact) - a 'wait until the fact is there' block, the same way
    insert_hook(f, block, socket, start_fact, resume_fact) - both: own content put into a game quest at that point

The layout, read from the game's files: a graph's blocks are the array `graphBlocks` of handles; a block's links are
`cachedConnections` - per output socket (CName `socketId`) the blocks it leads to (`ock` a handle, `putName` the
input's CName; a pause block's output has none). A property is name (u16), type (u16), size (u32, counts itself),
value; a struct starts with a 0 byte and ends with name 0 - in arrays too. A name the file lacks is added with its
hash (FNV-1a of the name and its 0 byte - cr2w.known_hash).
"""
import json
import os
import struct

from .cr2w_props import decode

_PHASES = None


def phase_index():
    """Every quest graph file of the game (.w2quest, .w2phase), sorted - kept in %APPDATA%\\conjunction\\game_phases.json."""
    global _PHASES
    if _PHASES is None:
        from . import config
        cache = os.path.join(os.path.dirname(config.PATH), "game_phases.json")
        try:
            _PHASES = json.load(open(cache, encoding="utf-8"))
        except (OSError, ValueError):
            from .bundles import Depot
            _PHASES = sorted(p for p in Depot().where if p.endswith((".w2phase", ".w2quest")))
            json.dump(_PHASES, open(cache, "w", encoding="utf-8"))
    return _PHASES


def _idx(f, n):
    """The name's index in the file - added (its hash: cr2w.known_hash) if it is not there."""
    return f.add_name(n)


def _prop(f, name, typ, value):
    return struct.pack("<HHI", _idx(f, name), _idx(f, typ), 4 + len(value)) + value


def _cname(f, n):
    return struct.pack("<H", _idx(f, n))


def _string(s):
    b = s.encode("latin-1")
    n = len(b)
    if n < 64:
        return bytes([0x80 | n]) + b
    return bytes([0x80 | 0x40 | (n & 0x3F), n >> 6]) + b


def _connections(f, conns):
    """cachedConnections: [(socket, [(target export, input name)])]."""
    out = struct.pack("<I", len(conns))
    for socket, targets in conns:
        blocks = struct.pack("<I", len(targets))
        for target, put in targets:
            blocks += b"\0" + _prop(f, "ock", "ptr:CQuestGraphBlock", struct.pack("<i", target)) + \
                _prop(f, "putName", "CName", _cname(f, put)) + b"\0\0"
        sid = _prop(f, "socketId", "CName", _cname(f, socket)) if socket is not None else b""
        out += b"\0" + sid + _prop(f, "blocks", "array:2,0,SBlockDesc", blocks) + b"\0\0"
    return out


def _replace_prop(f, chunk, name, typ, value):
    """The chunk with the property `name` set to `value` (added before the end marker if it was not there)."""
    for n, _t, off, size in f.props(chunk):
        if n == name:
            head = off - 8
            return chunk[:head] + _prop(f, name, typ, value) + chunk[off + size:]
    props = f.props(chunk)
    end = props[-1][2] + props[-1][3] if props else 1
    return chunk[:end] + _prop(f, name, typ, value) + chunk[end:]


def links(f, block):
    """[(socket, [(target, input name)])] of a block (export index)."""
    d = decode(f, f.exports[block - 1][4])
    out = []
    for c in d.get("cachedConnections") or []:
        out.append((c.get("socketId"), [(b["ock"][1], b.get("putName") or "In")
                                                   for b in c.get("blocks") or [] if isinstance(b.get("ock"), tuple)]))
    return out


BLOCK_FLAGS, CONDITION_FLAGS = 8192, 8200            # as the game's quest blocks and their conditions have them


def _insert(f, block, socket, cls, props, out_socket, children=()):
    """A new block of class `cls` after `block` on `socket`: it leads where `block` led. `props(new)` -> its own
    properties (after guid and links); `children` [(class, data)]: exports owned by it (conditions)."""
    _cls, _flags, graph, _tmpl, chunk = f.exports[block - 1]
    conns = links(f, block)
    after = next((t for s, t in conns if s == socket), None)
    if after is None:
        raise ValueError(f"block {block} has no output {socket!r} (it has {[s for s, _t in conns]})")
    new = len(f.exports) + 1
    for c in [cls] + [c for c, _d in children]:
        _idx(f, c)                              # class names too (the writer's own hash source lacks quest classes)
    data = b"\0" + _prop(f, "guid", "CGUID", os.urandom(16)) + \
        _prop(f, "cachedConnections", "array:2,0,SCachedConnections", _connections(f, [(out_socket, after)])) + \
        props(new) + b"\0\0"
    f.exports.append([cls, BLOCK_FLAGS, graph, 0, bytearray(data)])
    for ccls, cdata in children:
        f.exports.append([ccls, CONDITION_FLAGS, new, 0, bytearray(cdata)])
    # the block before leads to the new one now
    conns = [(s, [(new, "In")] if s == socket else t) for s, t in conns]
    f.exports[block - 1][4] = bytearray(_replace_prop(f, bytes(chunk), "cachedConnections",
                                                      "array:2,0,SCachedConnections", _connections(f, conns)))
    # and the graph holds it
    g = f.exports[graph - 1]
    blocks = [h[1] for h in decode(f, g[4]).get("graphBlocks") or [] if isinstance(h, tuple)] + [new]
    g[4] = bytearray(_replace_prop(f, bytes(g[4]), "graphBlocks", "array:2,0,ptr:CGraphBlock",
                                   struct.pack("<I", len(blocks)) + b"".join(struct.pack("<i", b) for b in blocks)))
    return new


def insert_fact_after(f, block, socket, fact, value=1):
    """A 'set fact' block after `block` on `socket`. Returns its export index."""
    return _insert(f, block, socket, "CQuestFactsDBChangingBlock",
                   lambda new: _prop(f, "factID", "String", _string(fact)) +
                   _prop(f, "value", "Int32", struct.pack("<i", value)), "Out")


def insert_wait_after(f, block, socket, fact):
    """A 'wait until the fact is there' block after `block` on `socket` (as the game's own: QF_DoesExist >= 1; its
    output has no name, like every pause block of the game's). Returns its export index."""
    cond = b"\0" + _prop(f, "factId", "String", _string(fact)) + \
        _prop(f, "queryFact", "EQueryFact", _cname(f, "QF_DoesExist")) + \
        _prop(f, "value", "Int32", struct.pack("<i", 1)) + \
        _prop(f, "compareFunc", "ECompareFunc", _cname(f, "CF_GreaterEqual")) + b"\0\0"
    return _insert(f, block, socket, "CQuestPauseConditionBlock",
                   lambda new: _prop(f, "conditions", "array:2,0,ptr:IQuestCondition",
                                     struct.pack("<Ii", 1, new + 1)), None,
                   children=[("CQuestFactsDBCondition", cond)])


def insert_hook(f, block, socket, start_fact, resume_fact):
    """Own content put into a game quest after `block`: it sets `start_fact` (a conjunction quest starts on it) and waits
    until `resume_fact` (the conjunction quest sets it at its end), then goes on as before. -> (fact block, wait block)"""
    wait = insert_wait_after(f, block, socket, resume_fact)
    fact = insert_fact_after(f, block, socket, start_fact)
    return fact, wait
