"""Blocks of one's own (Maxim 05.10.: "eine neue node ... custom programmierbar ... man platziert sie, öffnet sie, sie
hat einen oder mehrere inputs und outputs, darin baut man mit den nodes die das spiel liefert ... als vorlage
speichern"). A custom block is the game's own phase block with a graph inside (CDPR uses it 11 209 times): its
inputs are the Input blocks inside (CQuestPhaseInputBlock), its outputs the Output blocks. Saved as a template, it is a block of
the sidebar: put in, it copies itself with all it needs (journal paths, files) and fresh GUIDs.

Exposed fields make a template simple: a value inside (block k of the inside, an object under it, a field) shown on
the custom block's own card - who uses the template sets it there and never has to go in.

    templates()                          [template] of the library (%APPDATA%\\conjunction\\blocks) and Conjunction's own
    save_template(editor, n, label, text, exposed) -> template      block n (a custom block) kept
    insert(editor, graph, template) -> n    a template put into graph object `graph`
    Instances(project_dir)               which custom block of a project comes from which template, its exposed
    resolve(tree, block, field) -> (object, name) | None   an exposed field's object in a custom block

    template = {"id", "label", "text", "group", "file", "exposed": [field], "builtin"}
    field = {"label", "block": k (inside, in order), "path": [field, index, ...] to the object, "name",
             "also": [{"block", "path", "name"}] (optional: set to the same value, mirror())}
"""
import json
import os
import re

from . import config
from .cr2w_tree import Tree

LIBRARY = os.path.join(os.path.dirname(config.PATH), "blocks")
BUILTIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "blocks")
HOST = r"living_world\treasure_hunting\th1009_wolf_set.w2phase"     # the game's smallest phase file: the shell
PHASE = "CQuestPhaseBlock"
REGISTRY = "custom_blocks.json"         # in the project: {instance GUID: {"template": id, "exposed": [field]}}


def _slug(text):
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_") or "block"


def templates():
    """Every template: Conjunction's own first, then the library's (newest last)."""
    out = []
    for folder, builtin in ((BUILTIN, True), (LIBRARY, False)):
        if not os.path.isdir(folder):
            continue
        for f in sorted(os.listdir(folder)):
            if f.endswith(".json"):
                try:
                    t = json.load(open(os.path.join(folder, f), encoding="utf-8"))
                except (OSError, ValueError):
                    continue
                t["file"] = os.path.join(folder, t.get("file") or f[:-5] + ".w2phase")
                t["builtin"] = builtin
                out.append(t)
    return sorted(out, key=lambda t: (not t["builtin"], t.get("order", 999)))      # (stable: the rest by name)


def by_id(tid):
    return next((t for t in templates() if t["id"] == tid), None)


def inside(tree, n):
    """The blocks inside custom block n, in order (what an exposed field's 'block' counts)."""
    emb = tree.obj(n).get("embeddedGraph")
    if not (isinstance(emb, int) and emb > 0):
        return []
    return [b for b in tree.obj(emb).get("graphBlocks") or [] if isinstance(b, int) and b > 0]


def path_to(tree, block, obj):
    """[field, (index)] from block `block` to object `obj` under it (a condition, what it checks ...)."""
    if obj == block:
        return []
    todo = [(block, [])]
    seen = {block}
    while todo:
        n, path = todo.pop(0)
        for p in tree.obj(n).props or []:
            if not p.type.startswith(("handle:", "ptr:", "array:2,0,handle:", "array:2,0,ptr:")):
                continue
            vals = p.value if isinstance(p.value, list) else [p.value]
            for k, v in enumerate(vals):
                if not (isinstance(v, int) and v > 0) or v in seen:
                    continue
                step = path + ([p.name, k] if isinstance(p.value, list) else [p.name])
                if v == obj:
                    return step
                seen.add(v)
                todo.append((v, step))
    return None


def resolve(tree, block, field):
    """An exposed field of custom block `block`: (object number, field name) - None when the inside changed."""
    blocks = inside(tree, block)
    k = field.get("block")
    if not isinstance(k, int) or not 0 <= k < len(blocks):
        return None
    return walk(tree, blocks[k], field)


def walk(tree, n, field):
    """From block n along a field's path to its object: (object number, field name) - None when it is not there."""
    path = list(field.get("path") or [])
    while path:
        name = path.pop(0)
        v = tree.obj(n).get(name)
        if isinstance(v, list):
            if not path or not isinstance(path[0], int) or path[0] >= len(v):
                return None
            v = v[path.pop(0)]
        if not (isinstance(v, int) and v > 0):
            return None
        n = v
    return n, field["name"]


def mirror(editor, block, field):
    """An exposed field that sets more than one place ("also": the objective shown and the one ticked off): its value
    written into the others."""
    for other in field.get("also") or []:
        here = resolve(editor.tree, block, field)
        there = resolve(editor.tree, block, dict(other, label=field.get("label")))
        if here is None or there is None:
            continue
        p = editor.tree.obj(here[0]).prop(here[1])
        if p is None:
            continue
        if p.type == "handle:CJournalPath":
            if isinstance(p.value, int) and p.value > 0:
                editor.set_journal(there[0], there[1], editor.tree.to_bytes(), p.value)
        else:
            import copy
            editor.set_field(there[0], there[1], copy.deepcopy(p.value), p.type)


def _host(depot):
    """The shell a template is kept in: the game's smallest phase file, its graph emptied."""
    t = Tree(depot.read(HOST))
    g = next(k for k, o in enumerate(t.objects, 1) if o.cls == "CQuestGraph")
    for b in sorted([b for b in t.obj(g).get("graphBlocks") or [] if isinstance(b, int) and b > 0], reverse=True):
        t.remove(b)
        g = next(k for k, o in enumerate(t.objects, 1) if o.cls == "CQuestGraph")
    t.obj(g).get("graphBlocks")[:] = []
    return t, g


def save_template(editor, n, label, text="", exposed=(), group="Your blocks", folder=None, tid=None, order=None):
    """Custom block n of the editor's file kept as a template (its file and its description). -> the template."""
    if editor.tree.obj(n).cls != PHASE:
        raise ValueError("Only a custom block (a phase with a graph inside) can be a template")
    folder = folder or LIBRARY
    os.makedirs(folder, exist_ok=True)
    t, g = _host(editor.depot)
    k = t.adopt(editor.tree, n, parent=g)
    from .vanilla_edit import _clear_links
    _clear_links(t.obj(k))                              # (its links outside are the quest's, not the template's)
    t.obj(g).get("graphBlocks").append(k)
    if tid is None:                                     # (a name of its own: a new one; given: kept over)
        tid = base = _slug(label)
        for i in range(2, 999):
            if not os.path.exists(os.path.join(folder, tid + ".json")):
                break
            tid = f"{base}_{i}"
    data = t.to_bytes()
    open(os.path.join(folder, tid + ".w2phase.tmp"), "wb").write(data)
    os.replace(os.path.join(folder, tid + ".w2phase.tmp"), os.path.join(folder, tid + ".w2phase"))
    meta = {"id": tid, "label": label, "text": text, "group": group, "file": tid + ".w2phase",
            "exposed": list(exposed)}
    if order is not None:
        meta["order"] = order
    json.dump(meta, open(os.path.join(folder, tid + ".json.tmp"), "w", encoding="utf-8"), indent=1)
    os.replace(os.path.join(folder, tid + ".json.tmp"), os.path.join(folder, tid + ".json"))
    meta["file"] = os.path.join(folder, tid + ".w2phase")
    return meta


def template_block(data):
    """The custom block of a template file (the one block of its graph)."""
    t = Tree(data)
    g = next(k for k, o in enumerate(t.objects, 1) if o.cls == "CQuestGraph")
    return next(b for b in t.obj(g).get("graphBlocks") or [] if isinstance(b, int) and b > 0 and
                t.obj(b).cls == PHASE)


def insert(editor, graph, template):
    """A template put into graph object `graph` (a copy: fresh GUIDs, what it names imported). -> its number."""
    data = open(template["file"], "rb").read()
    return editor.paste(graph, data, [template_block(data)])[0]


class Instances:
    """A project's custom blocks: their template, the fields they show outside (by the block's GUID)."""

    def __init__(self, project_dir):
        self.path = os.path.join(project_dir, REGISTRY) if project_dir else None
        try:
            self.data = json.load(open(self.path, encoding="utf-8")) if self.path and os.path.exists(self.path) \
                else {}
        except (OSError, ValueError):
            self.data = {}

    def get(self, guid):
        return self.data.get(guid) or {}

    def set(self, guid, **kv):
        self.data.setdefault(guid, {}).update(kv)
        self.save()

    def save(self):
        if not self.path:
            return
        json.dump(self.data, open(self.path + ".tmp", "w", encoding="utf-8"), indent=1)
        os.replace(self.path + ".tmp", self.path)


def exposed_of(instances, tree, n, guid):
    """The fields custom block n shows outside: its own (Instances) else its template's."""
    rec = instances.get(guid)
    if "exposed" in rec:
        return rec["exposed"]
    t = by_id(rec.get("template")) if rec.get("template") else None
    return (t or {}).get("exposed") or []
