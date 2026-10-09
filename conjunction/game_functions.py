"""The game's quest functions (404 in the remaster's scripts): what a quest's script block can call. Each with its
parameters (name, type, optional) and the values of its enum parameters - so any of them can be an action of a quest
("Game action"), each parameter a field of its kind. Read from the game's scripts once, kept in
%APPDATA%\\conjunction\\game_functions.json.

    functions() -> {name: {"params": [(name, type, optional)], "latent": bool, "file": path}}
    enums() -> {enum name: [values]}
    usable(fn) -> the parameters can all be written by radish (names, strings, numbers, bools, enums)
"""
import glob
import json
import os
import re

from . import config

CACHE = os.path.join(os.path.dirname(config.PATH), "game_functions.json")
FUNC = re.compile(r"^\s*(latent\s+)?quest\s+function\s+(\w+)\s*\(([^)]*)\)", re.M | re.S)
ENUM = re.compile(r"\benum\s+(\w+)\s*\{([^}]*)\}", re.S)
SIMPLE = {"name": "name", "cname": "name", "string": "string", "int": "int", "float": "float", "bool": "bool",
          "Uint32": "int", "Int32": "int", "Uint8": "int", "Int8": "int", "Uint16": "int"}
_data = None


def _scripts():
    return os.path.join(config.load()["game"], "content", "content0", "scripts")


def _parse():
    funcs, enums = {}, {}
    for f in glob.glob(os.path.join(_scripts(), "**", "*.ws"), recursive=True):
        try:
            text = open(f, encoding="utf-16" if open(f, "rb").read(2) in (b"\xff\xfe", b"\xfe\xff") else "utf-8",
                        errors="replace").read()
        except OSError:
            continue
        text = re.sub(r"//[^\n]*", "", text)
        for m in ENUM.finditer(text):
            values = [v.split("=")[0].strip() for v in m.group(2).split(",")]
            enums[m.group(1)] = [v for v in values if v]
        for m in FUNC.finditer(text):
            params, pending = [], []
            for p in m.group(3).split(","):
                p = " ".join(p.split())
                if not p:
                    continue
                if ":" not in p:                        # 'a, b, c : bool' - the type comes with the last name
                    pending.append(p)
                    continue
                left, typ = p.split(":", 1)
                for name in pending + [left]:
                    opt = name.strip().startswith("optional")
                    params.append((name.replace("optional", "").strip(), typ.strip(), opt))
                pending = []
            funcs[m.group(2)] = {"params": params, "latent": bool(m.group(1)),
                                 "file": os.path.relpath(f, _scripts())}
    return funcs, enums


def _load():
    global _data
    if _data is None:
        try:
            _data = json.load(open(CACHE, encoding="utf-8"))
        except (OSError, ValueError):
            funcs, enums = _parse()
            _data = {"functions": funcs, "enums": enums}
            try:
                json.dump(_data, open(CACHE, "w", encoding="utf-8"))
            except OSError:
                pass
    return _data


def functions():
    return _load()["functions"]


def enums():
    return _load()["enums"]


def kind(typ):
    """name / string / int / float / bool / enum / None (radish cannot write it)."""
    if typ in SIMPLE:
        return SIMPLE[typ]
    if typ in enums():
        return "enum"
    return None


def usable(fn):
    """Radish can write every parameter (and a latent one needs no wrapper: only a quest block may call those)."""
    info = functions()[fn]
    if not all(kind(t) for _n, t, _o in info["params"]):
        return False
    return not (info["latent"] and any(kind(t) == "enum" for _n, t, _o in info["params"]))


def label(fn):
    """'DoorChangeState' -> 'Door change state' ('Quest' at the end dropped)."""
    name = re.sub(r"Quest$", "", fn) or fn
    words = re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ", name).split()
    return " ".join([words[0]] + [w.lower() if not w.isupper() else w for w in words[1:]]) if words else fn


def words(name):
    """'dontBlockInCombat' -> 'dont block in combat' (a parameter's name as words)."""
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name).lower()


def radish_value(typ, value):
    """A parameter's value as radish writes it (names as CNAME_, enums by their value's index)."""
    k = kind(typ)
    if k == "name":
        return f"cname_{value}"
    if k == "int":
        return int(value)
    if k == "float":
        return float(value)
    if k == "bool":
        return bool(value)
    if k == "enum":
        values = enums()[typ]
        return values.index(value) if value in values else int(value or 0)
    return str(value)


WRAP = "CjG_"


def is_tag(name, typ):
    """A parameter that names an entity by its tag (the card lets you pick a placed object for it)."""
    return kind(typ) == "name" and "tag" in name.lower()


def is_person(name):
    return any(k in name.lower() for k in ("npc", "actor", "target"))


def default(typ):
    """The value a required parameter has before one is chosen."""
    k = kind(typ)
    return {"int": 0, "float": 0.0, "bool": False, "enum": (enums().get(typ) or [""])[0]}.get(k, "")


def needs_wrapper(fn):
    """A function with enum parameters is called through a wrapper that takes their values as names (radish writes
    names, not enums)."""
    return usable(fn) and any(kind(t) == "enum" for _n, t, _o in functions()[fn]["params"])


def called(fn):
    """The function a quest block calls for `fn`."""
    return WRAP + fn if needs_wrapper(fn) else fn


def wrappers_ws():
    """WitcherScript: a wrapper per function with enum parameters - enum values given as names, switched into the
    enum, the game's function called."""
    out = ["// generated by conjunction (game_functions.py): the game's quest functions with enum parameters, callable",
           "// from a quest block with the enum value as a name (radish cannot write enums)", ""]
    for fn in sorted(f for f in functions() if needs_wrapper(f)):
        info = functions()[fn]
        params = info["params"]
        sig = ", ".join(("optional " if o else "") + f"{n} : {'name' if kind(t) == 'enum' else t}" for n, t, o in params)
        out.append(f"{'latent ' if info['latent'] else ''}quest function {WRAP}{fn}({sig}) {{")
        for n, t, _o in params:
            if kind(t) == "enum":
                out.append(f"    var e_{n} : {t};")
        for n, t, _o in params:
            if kind(t) == "enum":
                out.append(f"    switch ({n}) {{")
                for v in enums()[t]:
                    out.append(f"        case '{v}': e_{n} = {v}; break;")
                out.append("    }")
        args = ", ".join(f"e_{n}" if kind(t) == "enum" else n for n, t, _o in params)
        out.append(f"    {fn}({args});")
        out.append("}")
        out.append("")
    return "\n".join(out)


if __name__ == "__main__":
    import sys
    if "--write" in sys.argv:
        target = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mod", "runtime", "scripts", "local",
                              "conjunction_gamefuncs.ws")
        open(target, "w", encoding="utf-8", newline="\n").write(wrappers_ws())
        print(target, sum(1 for f in functions() if needs_wrapper(f)), "wrappers")
