"""The parameters of quest script blocks, as the remaster reads them.

The game's quest files keep a script block's parameters twice: as the property `parameters` (an array of
QuestScriptParam {name : CName, value : CVariant}) and again after the block's properties (name, type, value each).
radish (2020) writes only the second - the remaster calls the function with every parameter empty (a tag None, a
count 0): a chest never got its item, a check never saw it. Once radish has encoded the quest, every script block
without `parameters` gets it, made from what radish wrote after the properties.

    apply(folder) -> the number of blocks given their parameters
"""
import glob
import os
import struct


def _tail_params(f, chunk, end):
    """(name index, type index, value bytes) of what follows the properties' end marker."""
    out, i = [], end
    while i + 8 <= len(chunk):
        nm, tp, size = struct.unpack_from("<HHI", chunk, i)
        if nm == 0:
            break
        out.append((nm, tp, chunk[i + 8:i + 4 + size]))
        i += 4 + size
    return out


def _parameters(f, params):
    """The `parameters` property: count, then per element a 0 byte, name (CName), value (CVariant: type, size,
    value), name 0 - as in the game's own quest files."""
    from .graph_edit import _idx, _prop
    body = struct.pack("<I", len(params))
    for nm, tp, value in params:
        variant = struct.pack("<HI", tp, 4 + len(value)) + value
        body += b"\0" + _prop(f, "name", "CName", struct.pack("<H", nm)) + \
            _prop(f, "value", "CVariant", variant) + b"\0\0"
    _idx(f, "QuestScriptParam")
    return _prop(f, "parameters", "array:2,0,QuestScriptParam", body)


def fix(f):
    """Every CQuestScriptBlock of an open file without `parameters` gets them -> how many."""
    n = 0
    for e in f.exports:
        if e[0] != "CQuestScriptBlock":
            continue
        chunk = bytes(e[4])
        props = f.props(chunk)
        if not props or any(name == "parameters" for name, *_ in props):
            continue
        end = props[-1][2] + props[-1][3]           # the end marker (name 0) after the last property
        params = _tail_params(f, chunk, end + 2)
        if not params:
            continue
        # after functionName, as the game has it (functionName, parameters, ...)
        at = next((off + size for name, _t, off, size in props if name == "functionName"), end)
        e[4] = bytearray(chunk[:at] + _parameters(f, params) + chunk[at:])
        n += 1
    return n


def _guid(f, chunk):
    for name, _t, off, size in f.props(chunk):
        if name == "guid":
            return chunk[off:off + size]
    return None


def _portable(f, chunk):
    """A block's parameters as (name, type, value) with names as text (a CName or enum value too) - from what radish
    wrote after the properties."""
    props = f.props(chunk)
    out = []
    for nm, tp, value in _tail_params(f, chunk, props[-1][2] + props[-1][3] + 2):
        typ = f.names[tp]
        if typ == "CName" or (typ.startswith("E") and len(value) == 2):
            value = f.names[struct.unpack("<H", value)[0]]
        elif "CName" in typ:
            raise ValueError(f"a script parameter of type {typ} cannot be carried over yet")
        out.append((f.names[nm], typ, value))
    return out


def restore(uncooked, cooked):
    """REDkit's cook keeps a script block's parameters only for functions it knows - the game's, not a mod's (every
    W3S... function lost them: the game called it with a tag None). Once cooked, each script block without them gets
    those of its uncooked block (the same guid) -> how many."""
    from .cr2w import CR2W
    done = 0
    for fn in sorted(glob.glob(os.path.join(cooked, "**", "*.w2quest"), recursive=True) +
                     glob.glob(os.path.join(cooked, "**", "*.w2phase"), recursive=True)):
        src = os.path.join(uncooked, os.path.relpath(fn, cooked))
        if not os.path.exists(src):
            continue
        u = CR2W(open(src, "rb").read())
        wanted = {}
        for e in u.exports:
            if e[0] == "CQuestScriptBlock":
                chunk = bytes(e[4])
                params = _portable(u, chunk)
                if params:
                    wanted[_guid(u, chunk)] = params
        if not wanted:
            continue
        data = open(fn, "rb").read()
        f = CR2W(data)
        n = 0
        for e in f.exports:
            if e[0] != "CQuestScriptBlock":
                continue
            chunk = bytes(e[4])
            props = f.props(chunk)
            params = wanted.get(_guid(f, chunk))
            if not params or any(name == "parameters" for name, *_ in props):
                continue
            here = []
            for name, typ, value in params:
                if isinstance(value, str):
                    value = struct.pack("<H", f.add_name(value))
                here.append((f.add_name(name), f.add_name(typ), value))
            at = next((off + size for name, _t, off, size in props if name == "functionName"),
                      props[-1][2] + props[-1][3])
            e[4] = bytearray(chunk[:at] + _parameters(f, here) + chunk[at:])
            n += 1
        if n:
            out = f.save()
            if CR2W(out).save() != out:
                raise RuntimeError(f"{os.path.basename(fn)} does not read back after its script parameters")
            open(fn, "wb").write(out)
            done += n
    return done


def apply(folder):
    from .cr2w import CR2W
    done = 0
    for fn in sorted(glob.glob(os.path.join(folder, "**", "*.w2quest"), recursive=True) +
                     glob.glob(os.path.join(folder, "**", "*.w2phase"), recursive=True)):
        data = open(fn, "rb").read()
        if b"CQuestScriptBlock" not in data:
            continue
        f = CR2W(data)
        n = fix(f)
        if n:
            open(fn, "wb").write(f.save())
            done += n
    return done
