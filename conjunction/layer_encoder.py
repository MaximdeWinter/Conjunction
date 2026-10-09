"""Our own layer encoder (docs/VANILLA_EDITING_PLAN.md, R3 of replacing radish): layers.yml (radish's format, our
generator writes it) into the layer files the game reads - a place's objects (static.w2l) and per world the
quest's meta layer: action points, trigger areas, scene points and map pins. As radish wrote them (measured over
every project's build: _scratch/r3_schema.py, _scratch/r3_full.py, tests/radish_layers.py); radish's own debug
layer (radish_dbginfo.w2l) is left out - the game does not read it.

    encode(layers, ctx) -> {layer depot path: bytes}
        layers  layers.yml read ({"layers": {name: {"world", "statics" | "actionpoints" | "areas" | ...}}})
        ctx     Ctx(quest id, dlc, template bytes, repo dir) - radish's repository data (worlds.repo.yml: a world's
                level folder; all.actions.repo.yml: an action's job tree and place) stays ours to use

Where: dlc\\<dlc>\\<world's level folder>\\<quest>\\<layer>\\static.w2l; the meta layer <quest>_meta_<world>:
actionpoints.w2l, areas.w2l, mappins.w2l, scenepoints.w2l. Tags: every entity carries radish_layer_<quest>_<layer>;
a meta entity <quest>_<world>_<id>_<ap | ar | sp | mp>. An area: its border points' middle the entity's place,
the points relative to it (float32, as radish computes) and as they are, a box up to its height.
"""
import os
import struct
import uuid

import yaml

from .cr2w_tree import Guid, Obj, Prop, Raw, Struct, Tags, Transform, Tree

LAYER, STATIC = 8192, 0
META_FILES = (("actionpoints", "actionpoints.w2l"), ("areas", "areas.w2l"), ("mappins", "mappins.w2l"),
              ("scenepoints", "scenepoints.w2l"))
SUFFIX = {"actionpoints": "ap", "areas": "ar", "mappins": "mp", "scenepoints": "sp"}
KIND = {"actionpoints": "layer_actionpoint", "areas": "layer_area", "mappins": "layer_mappin",
        "scenepoints": "layer_scenepoint"}


def f32(x):
    return struct.unpack("<f", struct.pack("<f", float(x)))[0]


def _mean32(values):
    """A mean as radish computes it: summed up in float32, divided in float32."""
    total = 0.0
    for v in values:
        total = f32(total + f32(v))
    return f32(total / f32(len(values)))


def _vec(x, y, z, w=1.0):
    return Struct([Prop("X", "Float", f32(x)), Prop("Y", "Float", f32(y)), Prop("Z", "Float", f32(z)),
                   Prop("W", "Float", f32(w))])


def _dbg(pairs):
    return [Struct([Prop("type", "String", k), Prop("s", "String", str(v))]) for k, v in pairs]


def _rot(rot):
    r = tuple(float(x) for x in (rot or (0, 0, 0)))
    return r if any(r) else None


class Ctx:
    def __init__(self, quest, dlc, template, repo):
        self.quest, self.dlc, self.template = quest, dlc, template
        self.worlds = yaml.safe_load(open(os.path.join(repo, "worlds.repo.yml"), encoding="utf-8"))["repository"]["worlds"]
        acts = yaml.safe_load(open(os.path.join(repo, "all.actions.repo.yml"), encoding="utf-8"))["repository"]["actions"]
        self.actions = acts


class Encoder:
    def __init__(self, ctx):
        self.ctx = ctx

    def tree(self):
        t = Tree(self.ctx.template)
        t.objects, t.f.imports, t.f.buffers = [], [], []
        return t

    @staticmethod
    def add(t, cls, flags, parent, props, template=0, rest=b""):
        t.objects.append(Obj(cls, flags, parent, template, [Prop(n, ty, v) for n, ty, v in props], rest=rest))
        return len(t.objects)

    @staticmethod
    def imp(t, path, cls):
        for k, (p, c, _f) in enumerate(t.f.imports, 1):
            if p == path and c == cls:
                return k
        t.f.imports.append([path, cls, 0])
        return len(t.f.imports)

    def folder(self, world, layer):
        level = self.ctx.worlds.get(world, {}).get("level", f"levels/{world}/").replace("/", "\\").strip("\\")
        return f"dlc\\{self.ctx.dlc}\\{level}\\{self.ctx.quest}\\{layer}"

    def layer_tag(self, layer):
        return f"radish_layer_{self.ctx.quest}_{layer}"

    # --- a place's objects
    def statics(self, name, layer):
        t = self.tree()
        root = self.add(t, "CLayer", LAYER, 0, [("entities", "array:32,0,ptr:CEntity", [])])
        made = []
        for oid, o in (layer.get("statics") or {}).items():
            template = str(o["template"])
            k = self.imp(t, template, "CEntityTemplate")
            tags = [str(x) for x in o.get("tags") or []] + [self.layer_tag(name)]
            made.append(self.add(t, "CEntity", STATIC, root, [
                ("template", "handle:CEntityTemplate", -k),
                ("transform", "EngineTransform", Transform(tuple(float(v) for v in o["pos"]), _rot(o.get("rot")),
                                                             None)),
                ("tags", "TagList", Tags(tags)),
                ("dbgInfo", "array:2,0,SDbgInfo", _dbg([("preset", ".entity"), ("type", "layer_static"), ("id", oid),
                                                       ("questid", self.ctx.quest), ("layername", name),
                                                       ("class", "CEntity"), ("template", template)]))],
                template=(-k) & 0xFFFFFFFF, rest=bytes(14)))
        t.obj(root).set("entities", made)
        return t.to_bytes()

    # --- the quest's meta layer of a world: one file per kind
    def meta(self, name, layer, kind):
        world = layer["world"]
        t = self.tree()
        root = self.add(t, "CLayer", LAYER, 0, [("entities", "array:32,0,ptr:CEntity", [])])
        made = []
        for oid, spec in (layer.get(kind) or {}).items():
            tag = f"{self.ctx.quest}_{world}_{oid}_{SUFFIX[kind]}"
            dbg = [("type", KIND[kind]), ("id", oid), ("questid", self.ctx.quest), ("layername", name)]
            cls, comp = "CEntity", None
            if kind == "areas":
                pts = [[f32(v) for v in p] for p in spec["borderpoints"]]
                cx, cy, cz = (_mean32([p[i] for p in pts]) for i in range(3))
                pos, rot = (cx, cy, cz), None
            elif kind == "actionpoints":
                pos, rot = tuple(float(v) for v in spec["pos"]), _rot(spec.get("rot"))
                cat, _, act = str(spec["action"]).partition("/")
                a = (self.ctx.actions.get(cat) or {}).get(act) or {}
                dbg += [("action", act), ("category", cat)]
                cls = "CActionPoint"
            elif kind == "scenepoints":
                pos, rot = tuple(float(v) for v in spec[:3]), _rot((0, 0, spec[3]) if len(spec) > 3 else None)
            else:                                       # mappins
                pos, rot = tuple(float(v) for v in spec[:3]), None
                cls = "CGameplayEntity"
            props = [("tags", "TagList", Tags([tag, self.layer_tag(name)])),
                     ("transform", "EngineTransform", Transform(pos, rot, None)),
                     ("guid", "CGUID", Guid(uuid.uuid4().bytes)), ("streamingDistance", "Uint8", 0),
                     ("dbgInfo", "array:2,0,SDbgInfo", _dbg(dbg))]
            if kind in ("actionpoints", "mappins"):
                props.append(("idTag", "IdTag", Raw(b"\x00" + uuid.uuid4().bytes)))
            n = self.add(t, cls, LAYER, root, props)
            c = n + 1                                   # its one component, right after it
            self.t_rest(t, n, c)
            if kind == "areas":
                xs, ys, zs = ([p[i] for p in pts] for i in range(3))
                height = float(spec.get("height", 2.0))
                comp = self.add(t, "CTriggerAreaComponent", LAYER, n, [
                    ("transform", "EngineTransform", Transform(None, None, (1.0, 1.0, 1.0))),
                    ("guid", "CGUID", Guid(uuid.uuid4().bytes)), ("name", "String", str(oid)),
                    ("boundingBox", "Box", Struct([Prop("Min", "Vector", _vec(min(xs), min(ys), min(zs))),
                                                   Prop("Max", "Vector", _vec(max(xs), max(ys), max(zs) + height))])),
                    ("height", "Float", height),
                    ("localPoints", "array:2,0,Vector", [_vec(f32(p[0] - cx), f32(p[1] - cy), f32(p[2] - cz))
                                                         for p in pts]),
                    ("worldPoints", "array:2,0,Vector", [_vec(*p) for p in pts])], rest=bytes(12))
            elif kind == "actionpoints":
                job = str(a.get("file", "")).replace("/", "\\")
                comp = self.add(t, "CActionPointComponent", LAYER, n, [
                    ("guid", "CGUID", Guid(uuid.uuid4().bytes)), ("name", "String", str(a.get("place", ""))),
                    ("jobTreeRes", "handle:CJobTree", -self.imp(t, job, "CJobTree"))], rest=bytes(8))
            elif kind == "scenepoints":
                comp = self.add(t, "CStorySceneWaypointComponent", LAYER, n, [
                    ("guid", "CGUID", Guid(uuid.uuid4().bytes)), ("name", "String", str(oid))], rest=bytes(8))
            else:
                comp = self.add(t, "CWayPointComponent", LAYER, n, [
                    ("guid", "CGUID", Guid(uuid.uuid4().bytes)), ("name", "String", str(oid))], rest=bytes(8))
            assert comp == c
            made.append(n)
        t.obj(root).set("entities", made)
        return t.to_bytes()

    @staticmethod
    def t_rest(t, n, component):
        """An entity's data after its properties: 8 zero bytes, its components (a count, a handle each), 2 zero
        bytes - as radish writes it."""
        t.obj(n).rest = bytes(8) + bytes([1]) + struct.pack("<i", component) + bytes(2)


def encode(layers, ctx):
    e = Encoder(ctx)
    out = {}
    for name, layer in ((layers or {}).get("layers") or {}).items():
        world = layer.get("world")
        if layer.get("statics"):
            out[e.folder(world, name) + "\\static.w2l"] = e.statics(name, layer)
        for kind, fname in META_FILES:
            if layer.get(kind):
                out[e.folder(world, name) + "\\" + fname] = e.meta(name, layer, kind)
    return out
