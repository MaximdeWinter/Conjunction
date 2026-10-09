"""What the game's quests are made of, as a catalog for the editor's general blocks (Maxim 05.10.: "allgemeine
blöcke zum editieren und einstellungen ... eine vanilla quest voll nachbaubar mit unserem questsystem"): every
block class, condition, script function and AI action the game's quest graphs use - their fields with types, the
values the game gives them (for pickers), CDPR's own descriptions (the scripts' hint lines) and defaults.

Two sources:
  the game's scripts (content0\\scripts): `quest function` signatures (405 of them: the functions a script block
      calls), script classes (`editable var` fields, `default`, `hint`) - most conditions (W3QuestCond_...) and
      AI actions (CAI...) are script classes; enums
  every object of the 1041 quest graph files: the native classes (most blocks, CQuestFactsDBCondition ...) known by
      what they hold; each object's role by where it sits (in a graph: a block; under a wait or an if: a
      condition; under an AI actions block: an AI action; else a part of its parent)

    build(depot) -> catalog          about a minute; kept in %APPDATA%\\conjunction\\game_catalog.json
    load() -> catalog
    catalog = {"classes": {name: {"role", "count", "label", "doc", "extends", "fields": {name: {"type", "count",
               "values": [[value, n] ...], "hint", "default"}}}},
               "functions": {name: {"count", "latent", "params": [{"name", "type", "optional", "values"}], "label"}},
               "enums": {name: [values]}}
"""
import collections
import glob
import json
import os
import re

from . import config

CACHE = os.path.join(os.path.dirname(config.PATH), "game_catalog.json")
VALUES = 24                     # values kept per field (the most used)
PREFIXES = ("W3QuestCond_", "CQuestCondition", "CQuest", "CJournalQuest", "CJournal", "CQC", "CAI", "CBehTree",
            "W3", "C")
SUFFIXES = ("Block", "Condition", "Action", "Params", "Quest")


def label(name):
    """CQuestInsideTriggerCondition -> 'Inside trigger', W3QuestCond_IsItemEquipped -> 'Is item equipped'."""
    n = name
    for p in PREFIXES:
        if n.startswith(p) and len(n) > len(p):
            n = n[len(p):]
            break
    for s in SUFFIXES:
        if n.endswith(s) and len(n) > len(s):
            n = n[:-len(s)]
    n = n.replace("_", " ")
    words = re.findall(r"[A-Z]+(?=[A-Z][a-z]|\d|\b)|[A-Z]?[a-z]+|\d+|[A-Z]+", n)
    text = " ".join(words) if words else n
    return text[:1].upper() + text[1:].lower() if text else name


# --- the scripts
FUNC = re.compile(r"^\s*(latent\s+)?quest\s+function\s+(\w+)\s*\(([^)]*)\)\s*(?::\s*([\w<>]+))?", re.M)
CLASS = re.compile(r"^\s*(?:import\s+|abstract\s+|statemachine\s+)*class\s+(\w+)(?:\s+extends\s+(\w+))?", re.M)
FIELD = re.compile(r"^\s*(?:editable\s+|saved\s+|inlined\s+|const\s+|private\s+|protected\s+|public\s+|import\s+)*"
                   r"(editable)?[\w\s]*?\bvar\s+([\w,\s]+?)\s*:\s*([\w<>:, ]+?)\s*;", re.M)
HINT = re.compile(r'^\s*hint\s+(\w+)\s*=\s*"([^"]*)"', re.M)
DEFAULT = re.compile(r"^\s*default\s+(\w+)\s*=\s*([^;]+);", re.M)
ENUM = re.compile(r"^\s*enum\s+(\w+)\s*\{([^}]*)\}", re.M)


def _params(text):
    out = []
    for part in [p.strip() for p in text.split(",") if p.strip()]:
        m = re.match(r"((?:optional|out|inout)\s+)*(\w+)\s*:\s*(.+)$", part)
        if m:
            mods = m.group(1) or ""
            out.append({"name": m.group(2), "type": m.group(3).strip(), "optional": "optional" in mods,
                        "out": "out" in mods})
    return out


def parse_scripts(root):
    funcs, classes, enums = {}, {}, {}
    for path in glob.glob(os.path.join(root, "**", "*.ws"), recursive=True):
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        rel = os.path.relpath(path, root)
        for m in FUNC.finditer(text):
            funcs[m.group(2)] = {"latent": bool(m.group(1)), "params": _params(m.group(3)),
                                 "returns": m.group(4), "file": rel}
        for m in ENUM.finditer(text):
            body = re.sub(r"//[^\n]*", "", m.group(2))
            enums[m.group(1)] = [v.split("=")[0].strip() for v in body.split(",") if v.split("=")[0].strip()]
        # classes: each one's text up to the next class
        starts = list(CLASS.finditer(text))
        for k, m in enumerate(starts):
            body = text[m.end(): starts[k + 1].start() if k + 1 < len(starts) else len(text)]
            depth, end = 0, len(body)
            for i, ch in enumerate(body):          # only the class's own top level (not its functions' vars)
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
            top, depth = [], 0
            for ch in body[:end]:
                if ch == "{":
                    depth += 1
                    continue
                if ch == "}":
                    depth -= 1
                    continue
                if depth <= 1:
                    top.append(ch)
            top = "".join(top)
            fields = {}
            for f in FIELD.finditer(top):
                for name in [x.strip() for x in f.group(2).split(",") if x.strip()]:
                    fields[name] = {"type": f.group(3).strip(), "editable": bool(f.group(1)) or "editable" in
                                    f.group(0)}
            c = classes.setdefault(m.group(1), {"extends": m.group(2), "fields": {}, "hints": {}, "defaults": {},
                                                "file": rel})
            c["fields"].update(fields)
            c["hints"].update({h.group(1): h.group(2) for h in HINT.finditer(top)})
            c["defaults"].update({d.group(1): d.group(2).strip() for d in DEFAULT.finditer(top)})
    return funcs, classes, enums


# --- the quest files
def _value_text(qf_imports, v):
    from .cr2w_tree import Guid, Loc, Raw, Soft, Struct, Tags, Transform, Variant
    if isinstance(v, (Guid, Raw, Transform, Struct)) or isinstance(v, list) and not isinstance(v, Tags):
        return None
    if isinstance(v, Variant):
        return _value_text(qf_imports, v.value)
    if isinstance(v, Tags):
        return ", ".join(v)
    if isinstance(v, Soft):
        return qf_imports[v - 1][0] if 0 < v <= len(qf_imports) else None
    if isinstance(v, Loc):
        return None
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, float):
        return f"{v:g}"
    return str(v)


def survey(depot, files):
    from .cr2w_tree import Tree, Variant
    classes = {}
    funcs = {}

    def note(cls, role, o, t):
        c = classes.setdefault(cls, {"roles": collections.Counter(), "count": 0, "fields": {}})
        c["roles"][role] += 1
        c["count"] += 1
        for p in o.props or []:
            if p.name in ("guid", "cachedConnections", "graphBlocks"):
                continue
            f = c["fields"].setdefault(p.name, {"type": p.type, "count": 0, "values": collections.Counter()})
            f["count"] += 1
            if p.type.startswith(("handle:", "ptr:", "#")) and isinstance(p.value, int):
                if p.value < 0:
                    imp = t.f.imports[-p.value - 1][0] if -p.value <= len(t.f.imports) else None
                    if imp:
                        f["values"][imp] += 1
                elif p.value > 0:
                    f["values"]["→ " + t.obj(p.value).cls] += 1
                continue
            text = _value_text(t.f.imports, p.value)
            if text is not None and len(text) < 120:
                f["values"][text] += 1

    for path in files:
        try:
            t = Tree(depot.read(path))
        except Exception:                               # noqa: BLE001
            continue
        role = {}
        for o in t.objects:
            if o.cls == "CQuestGraph":
                for b in o.get("graphBlocks") or []:
                    if isinstance(b, int) and b > 0:
                        role[b] = "block"

        def mark(h, r):
            todo = [h]
            while todo:
                x = todo.pop()
                if isinstance(x, list):
                    todo += x
                    continue
                if not (isinstance(x, int) and 0 < x <= len(t.objects)) or x in role:
                    continue
                role[x] = r
                for p in t.obj(x).props or []:
                    if p.type.startswith(("handle:", "ptr:")) or p.type.startswith("array:") and \
                            ("handle:" in p.type or "ptr:" in p.type):
                        todo.append(p.value)
        for k, o in enumerate(t.objects, 1):
            if role.get(k) != "block":
                continue
            if o.cls == "CQuestPauseConditionBlock":
                mark(o.get("conditions"), "condition")
            elif o.cls == "CQuestConditionBlock":
                mark(o.get("questCondition"), "condition")
            elif o.cls in ("CQuestScriptedActionsBlock", "CQuestRiderScriptedActionsBlock"):
                mark(o.get("ai"), "ai")
            if o.cls == "CQuestScriptBlock":
                fn = funcs.setdefault(str(o.get("functionName")), {"count": 0, "params": {}})
                fn["count"] += 1
                for prm in o.get("parameters") or []:
                    pn = str(prm.get("name"))
                    v = prm.get("value")
                    slot = fn["params"].setdefault(pn, {"types": collections.Counter(),
                                                        "values": collections.Counter()})
                    if isinstance(v, Variant):
                        slot["types"][v.type] += 1
                        text = _value_text(t.f.imports, v.value)
                        if text is not None and len(text) < 120:
                            slot["values"][text] += 1
        for k, o in enumerate(t.objects, 1):
            r = role.get(k)
            if r is None:
                parent = t.obj(o.parent).cls if o.parent else ""
                r = "part of " + parent if parent else "file"
            note(o.cls, r, o, t)
    return classes, funcs


def build(depot=None, log=print):
    from . import story
    from .bundles import Depot
    depot = depot or Depot()
    root = os.path.join(config.load()["game"], "content", "content0", "scripts")
    sfuncs, sclasses, enums = parse_scripts(root)
    log(f"[catalog] scripts: {len(sfuncs)} quest functions, {len(sclasses)} classes, {len(enums)} enums")
    files = sorted(p for p in depot.where if p.endswith((".w2phase", ".w2quest")) and story.game_file(p))
    seen, used = survey(depot, files)
    log(f"[catalog] quest files: {len(seen)} classes, {len(used)} functions")
    out = {"classes": {}, "functions": {}, "enums": enums}
    for name, c in seen.items():
        role = c["roles"].most_common(1)[0][0]
        sc = sclasses.get(name, {})
        fields = {}
        for fname, f in c["fields"].items():
            fields[fname] = {"type": f["type"], "count": f["count"], "values": f["values"].most_common(VALUES),
                             "hint": sc.get("hints", {}).get(fname), "default": sc.get("defaults", {}).get(fname)}
        for fname, f in sc.get("fields", {}).items():  # script fields the game's files never set
            if f.get("editable") and fname not in fields:
                fields[fname] = {"type": f["type"], "count": 0, "values": [], "hint": sc["hints"].get(fname),
                                 "default": sc["defaults"].get(fname)}
        out["classes"][name] = {"role": role, "roles": dict(c["roles"]), "count": c["count"], "label": label(name),
                                "doc": None, "extends": sc.get("extends"), "script": sc.get("file"),
                                "fields": fields}
    for name, f in used.items():
        sig = sfuncs.get(name)
        params = []
        for p in (sig or {}).get("params") or [{"name": n, "type": s["types"].most_common(1)[0][0] if s["types"]
                                                else "?", "optional": False, "out": False}
                                               for n, s in f["params"].items()]:
            s = f["params"].get(p["name"], {"values": collections.Counter()})
            ft = s.get("types")                         # (the type the quest files write it as)
            params.append(dict(p, values=s["values"].most_common(VALUES),
                               file_type=ft.most_common(1)[0][0] if ft else None))
        out["functions"][name] = {"count": f["count"], "latent": (sig or {}).get("latent"), "params": params,
                                  "returns": (sig or {}).get("returns"), "script": (sig or {}).get("file"),
                                  "label": label(name)}
    for name, sig in sfuncs.items():                    # quest functions no game quest calls: offered too
        if name not in out["functions"]:
            out["functions"][name] = {"count": 0, "latent": sig["latent"], "returns": sig["returns"],
                                      "params": [dict(p, values=[]) for p in sig["params"]],
                                      "script": sig["file"], "label": label(name)}
    tmp = CACHE + ".tmp"
    json.dump(out, open(tmp, "w", encoding="utf-8"), indent=1)
    os.replace(tmp, CACHE)
    roles = collections.Counter(c["role"] for c in out["classes"].values())
    log(f"[catalog] {len(out['classes'])} classes ({dict(roles)}), {len(out['functions'])} functions")
    return out


# the engine's own choices the scripts do not list (their values as the quest files name them)
NATIVE_ENUMS = {
    "ECompareFunc": ["CF_Equal", "CF_NotEqual", "CF_Less", "CF_LessEqual", "CF_Greater", "CF_GreaterEqual"],
    "EQueryFact": ["QF_Sum", "QF_SumSince", "QF_LatestValue", "QF_DoesExist"],
    "ELogicOperation": ["LO_And", "LO_Or", "LO_Xor", "LO_Nand", "LO_Nor", "LO_Nxor"],
    "EJournalStatus": ["JS_Inactive", "JS_Active", "JS_Success", "JS_Failed"],
}
INT_TYPES = {"Int8", "Uint8", "Int16", "Uint16", "Int32", "Uint32", "Int64", "Uint64", "Float", "Double"}


def enum_values(catalog, typ, seen=()):
    """The values a choice can have: the scripts' list, the engine's, else those the game's files use."""
    return list((catalog or {}).get("enums", {}).get(typ) or NATIVE_ENUMS.get(typ) or seen)


def default_of(catalog, cls, field):
    """A field's value when a file leaves it out (the cooked files write only what differs from the class's own
    value): the scripts' `default`, else read off the game's files - a yes/no only ever written as yes is no by
    default; a number never written as 0 is 0 (written as 0, never as 1: 1 - a 'has item' count); a choice's
    first value never written is it. None: not known."""
    f = ((catalog or {}).get("classes", {}).get(cls) or {}).get("fields", {}).get(field) or {}
    typ = f.get("type") or ""
    seen = {str(v) for v, _c in f.get("values") or []}
    d = f.get("default")
    if d not in (None, ""):
        d = str(d).strip().strip('"')
        if typ == "Bool":
            return d.lower() in ("true", "yes", "1")
        if typ in INT_TYPES:
            try:
                return float(d) if typ in ("Float", "Double") else int(float(d))
            except ValueError:
                return None
        return d
    if typ == "Bool":
        return seen == {"no"}                           # (only ever written as no: yes by default)
    if typ in INT_TYPES:                                # never written as 0: 0; as 0 but never as 1: 1
        f = float if typ in ("Float", "Double") else int
        if not seen:
            return None
        if "0" not in seen and "0.0" not in seen:
            return f(0)
        if "1" not in seen and "1.0" not in seen:
            return f(1)
        return None
    if typ in ("String", "CName", "StringAnsi"):
        return ""
    opts = enum_values(catalog, typ)
    if opts:
        return next((o for o in opts if o not in seen), None)
    return None


def load():
    if not os.path.exists(CACHE):
        return None
    return json.load(open(CACHE, encoding="utf-8"))
