"""The foliage library: the game's trees, bushes and flowers (.srt) made placeable. A tree of the world's foliage has
no entity of its own, so Conjunction builds, on the user's machine, a DLC with one small entity per tree:

    tree       CDynamicFoliageComponent, baseTree = the game's .srt     (draws it: seen in the game 04.10.)
    collision  CStaticMeshComponent, not drawn, its mesh only collision (the component above has none: Maxim walked
               through the first planted trees) - the tree's own collision objects (srt.py: capsules, read from
               its .srt) as convex prisms, cooked into the DLC's collision cache

Nothing of the game is copied; the entities point at the game's files. Trees without collision objects (flowers,
grass, most bushes) get no collision part, as in the world.

    python -m conjunction.foliage build [--limit N]      generate, encode, cook, install (one time)
    python -m conjunction.foliage list                   how many trees would go in, how many with collision
"""
import hashlib
import json
import math
import os
import re
import shutil
import struct
import sys

import yaml

from . import config

DLC_ID = "conjunctionfoliage"
INDEX = os.path.join(os.path.dirname(config.PATH), "foliage.json")       # .srt -> library template
SIDES = 8                       # a trunk's prism: eight sides (the game's own capsule mesh: fourteen)
BASE_MESH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "collision_base.w2mesh")
MATERIAL = "wood_solid"


def trees(cfg=None):
    """The game's foliage resources (radish's list of them, the ones this game has) -> sorted depot paths."""
    from .bundles import Depot
    cfg = cfg or config.load()
    repo = os.path.join(cfg["radish"], "repo.quests", "all.foliage.repo.yml")
    found = re.findall(r":\s*(\S+\.srt)", open(repo, encoding="utf-8").read())
    depot = Depot()
    return sorted({p.replace("/", "\\").lower() for p in found if depot.exists(p.replace("/", "\\"))})


def index():
    """tree (.srt) -> library template; empty without a library."""
    if not os.path.exists(INDEX):
        return {}
    return json.load(open(INDEX, encoding="utf-8"))


def reverse_index():
    """library template (lower case) -> tree."""
    return {t.lower(): tree for tree, t in index().items()}


def catalog_entries():
    """Catalog entries for the installed library (empty if it was never built)."""
    from . import catalog
    return [{"path": t, "name": catalog.caption(tree), "kind": "Plant", "source": "Foliage",
             "tags": catalog.tags_of(tree) + ["foliage", "tree"], "group": catalog.group_of(tree), "quest": False,
             "tree": tree} for tree, t in index().items()]


GROUPS = (("\\underwater\\", "Underwater plants"), ("\\vegetables\\", "Crops"), ("\\vineyard\\", "Crops"),
          ("\\grass", "Grass"), ("\\flowers\\", "Herbs & flowers"), ("herbs", "Herbs & flowers"),
          ("\\mushrooms", "Mushrooms"), ("\\creeper\\", "Creepers"), ("\\floating_plants\\", "Water plants"),
          ("\\debris\\", "Debris"), ("bush", "Bushes"), ("shrub", "Bushes"), ("\\trees\\", "Trees"))


def group(tree):
    """The catalog group of a tree (Nature / ...): from its folder and name - trees, bushes, flowers and herbs,
    crops, grass, underwater plants; anything else a plant."""
    p = tree.lower()
    return next((g for key, g in GROUPS if key in p), "Plants")


def entity_name(tree):
    base = re.sub(r"[^a-z0-9_]", "_", os.path.splitext(os.path.basename(tree))[0].lower())[:40]
    return f"f_{base}_{hashlib.md5(tree.encode()).hexdigest()[:6]}"


def prism(c1, c2, r, sides=SIDES):
    """A capsule as a convex prism: `sides` around the axis c1 -> c2, reaching r past both ends (the round caps).
    -> (vertices, polygons) as the game writes a convex shape: polygons [count, index, ...], faces wound
    counter-clockwise seen from outside (measured on the game's boat capsule)."""
    ax = [c2[k] - c1[k] for k in range(3)]
    length = math.sqrt(sum(a * a for a in ax))
    if length < 1e-4:                                   # a sphere: an upright prism as tall as it is wide
        ax, length = [0.0, 0.0, 1.0], 0.0
    d = [a / length for a in ax] if length else ax
    lo = [c1[k] - d[k] * r for k in range(3)]
    hi = [c1[k] + d[k] * (length + r) for k in range(3)]
    helper = [1.0, 0.0, 0.0] if abs(d[0]) < 0.9 else [0.0, 1.0, 0.0]
    u = [d[1] * helper[2] - d[2] * helper[1], d[2] * helper[0] - d[0] * helper[2], d[0] * helper[1] - d[1] * helper[0]]
    nu = math.sqrt(sum(a * a for a in u))
    u = [a / nu for a in u]
    w = [d[1] * u[2] - d[2] * u[1], d[2] * u[0] - d[0] * u[2], d[0] * u[1] - d[1] * u[0]]
    ring = [[math.cos(2 * math.pi * i / sides) * r, math.sin(2 * math.pi * i / sides) * r] for i in range(sides)]
    verts = [[lo[k] + a * u[k] + b * w[k] for k in range(3)] for a, b in ring] + \
            [[hi[k] + a * u[k] + b * w[k] for k in range(3)] for a, b in ring]
    polys = [sides] + list(range(sides - 1, -1, -1))         # the bottom cap, seen from below
    polys += [sides] + list(range(sides, 2 * sides))         # the top cap
    for i in range(sides):                                   # the sides
        j = (i + 1) % sides
        polys += [4, i, j, sides + j, sides + i]
    return verts, polys


def _wound_out(verts, polys):
    """Every face's normal points away from the body's centre (the check the game's own shape passes)."""
    c = [sum(v[k] for v in verts) / len(verts) for k in range(3)]
    i = 0
    while i < len(polys):
        n = polys[i]
        idx = polys[i + 1:i + 1 + n]
        a, b, d = verts[idx[0]], verts[idx[1]], verts[idx[2]]
        u = [b[k] - a[k] for k in range(3)]
        w = [d[k] - a[k] for k in range(3)]
        nrm = (u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0])
        face = [sum(verts[j][k] for j in idx) / n for k in range(3)]
        if sum(nrm[k] * (face[k] - c[k]) for k in range(3)) <= 0:
            return False
        i += 1 + n
    return True


def collision_mesh(path, capsules, material=MATERIAL):
    """A mesh that draws nothing of its own use (its component is not drawn) and collides like the tree: the base
    mesh with a CCollisionMesh of one convex prism per capsule (as the game's own collision meshes hold them)."""
    from .cr2w import CR2W
    from .furniture import _floats, _prop
    f = CR2W(open(BASE_MESH, "rb").read())
    mesh = f.exports[0]
    props = f.props(mesh[4])
    for n in ("collisionMesh", "handle:CCollisionMesh", "CCollisionMesh", "shapes", "array:2,0,ptr:ICollisionShape",
              "CCollisionShapeConvex", "vertices", "array:99,0,Vector", "polygons", "array:99,0,Uint16", "Vector",
              "X", "Y", "Z", "W", "Float", "physicalMaterialName", "CName", material):
        f.add_name(n)
    k_mesh = len(f.exports)                         # the collision mesh's export index (1-based: k_mesh + 1)
    shapes = []
    for c1, c2, r in capsules:
        verts, polys = prism(c1, c2, r)
        arr_v = struct.pack("<I", len(verts)) + b"".join(_floats(f, ("X", "Y", "Z", "W"), (*v, 1.0)) for v in verts)
        arr_p = struct.pack("<I", len(polys)) + struct.pack(f"<{len(polys)}H", *polys)
        shapes.append(b"\0" + _prop(f, "physicalMaterialName", "CName", struct.pack("<H", f.add_name(material))) +
                      _prop(f, "vertices", "array:99,0,Vector", arr_v) +
                      _prop(f, "polygons", "array:99,0,Uint16", arr_p) + b"\0\0")
    refs = struct.pack("<I", len(shapes)) + b"".join(struct.pack("<i", k_mesh + 2 + i) for i in range(len(shapes)))
    f.exports.append(["CCollisionMesh", 0, 1, 0, bytearray(b"\0" + _prop(f, "shapes", "array:2,0,ptr:ICollisionShape",
                                                                        refs) + b"\0\0")])
    for s in shapes:
        f.exports.append(["CCollisionShapeConvex", 0, k_mesh + 1, 0, bytearray(s)])
    after = next((p for p in props if p[0] == "autoHideDistance"), props[-1])
    at = after[2] + after[3]
    mesh[4] = bytearray(bytes(mesh[4][:at]) + _prop(f, "collisionMesh", "handle:CCollisionMesh",
                                                     struct.pack("<i", k_mesh + 1)) + bytes(mesh[4][at:]))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    open(tmp, "wb").write(f.save())
    os.replace(tmp, path)


def entity(tree, coll_rel=None):
    """radish entity definition: the tree, and its collision when it has one (a mesh component that is not drawn:
    drawableFlags without DF_IsVisible). Not streamed: wcc_lite cooks streamed parts out of a spawned template."""
    comps = {"tree": {".type": "CDynamicFoliageComponent", "baseTree": tree.replace("\\", "/"), "isStreamed": False}}
    if coll_rel:
        comps["collision"] = {".type": "CStaticMeshComponent", "isStreamed": False, "mesh": coll_rel,
                              "drawableFlags": []}
    return {"entityObject": {".type": "CEntity", "components": comps}}


def quest_collision(project, tree, defdir):
    """A planted tree in a quest: its collision mesh, made beside the quest's definition and handed to the build
    (project.extra_resources) -> its depot path in the quest's DLC, or None when the tree has no collision."""
    from . import srt
    from .bundles import Depot
    info = srt.read(Depot().read(tree)) or {}
    if not info.get("collision"):
        return None
    name = entity_name(tree)
    rel = "\\".join(["dlc", f"dlc{project.id}", "data", "collision", name + ".w2mesh"])
    path = os.path.join(os.path.dirname(defdir), "collision", name + ".w2mesh")
    collision_mesh(path, info["collision"])
    project.extra_resources[rel] = path
    return rel


def generate(work, tree_list, log=print):
    """radish definition + the collision meshes -> (index {tree: template}, extra {depot path: file})."""
    from . import srt
    from .bundles import Depot
    defdir = os.path.join(work, "definition.quest")
    if os.path.isdir(defdir):
        shutil.rmtree(defdir)
    os.makedirs(defdir)
    yaml.safe_dump({"production": {"settings": {
        "id": DLC_ID, "caption": "conjunction foliage library", "description": "the game's trees as placeable entities",
        "menuvisibile": False, "enabled": True, "storesdata": False, "strings-idspace": 9996, "strings-idstart": 0,
        "version": 12}}}, open(os.path.join(defdir, f"prod.quest-{DLC_ID}.yml"), "w", encoding="utf-8"),
        sort_keys=False)
    yaml.safe_dump({"structure": {"quest": {"blocks": {"start": {"next": ["end"]}, "end": {"next": ".done"}}}}},
                   open(os.path.join(defdir, "structure.root.yml"), "w", encoding="utf-8"), sort_keys=False)
    depot = Depot()
    index, extra, ents, with_coll = {}, {}, {}, 0
    for t in tree_list:
        name = entity_name(t)
        info = srt.read(depot.read(t)) or {}
        coll_rel = None
        if info.get("collision"):
            coll_rel = "\\".join(["dlc", f"dlc{DLC_ID}", "data", "collision", name + ".w2mesh"])
            dst = os.path.join(work, "collision", name + ".w2mesh")
            collision_mesh(dst, info["collision"])
            extra[coll_rel] = dst
            with_coll += 1
        ents[name] = entity(t, coll_rel)
        index[t] = "\\".join(["dlc", f"dlc{DLC_ID}", "data", "entities", name + ".w2ent"])
    yaml.safe_dump({"entities": ents}, open(os.path.join(defdir, "entities.yml"), "w", encoding="utf-8"),
                   sort_keys=False)
    log(f"[foliage] {len(tree_list)} trees, {with_coll} with collision")
    return index, extra


def build(limit=None, install=True, log=print, only=None):
    """Generate, encode, cook (with the collision cache), install -> the packed DLC folder."""
    from . import build as builder
    cfg = config.load()
    work = os.path.join(os.path.dirname(config.PATH), "foliagelib")
    tree_list = only or trees(cfg)
    if limit:
        tree_list = tree_list[:limit]
    index, extra = generate(work, tree_list, log)
    # (the collision meshes carry buffers: build_dlc lets wcc_lite pack them, and cooks their collision cache)
    packed = builder.build_dlc(os.path.join(work, "definition.quest"), work, install=False, log=log, extra=extra,
                               collision_cache=True)
    if install:
        target = os.path.join(cfg["game"], "dlc", f"dlc{DLC_ID}")
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.copytree(packed, target)
        log(f"[foliage] installed -> {target}")
        json.dump(index, open(INDEX, "w", encoding="utf-8"))
    return packed


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        from . import srt
        from .bundles import Depot
        depot = Depot()
        ts = trees()
        n = sum(1 for t in ts if (srt.read(depot.read(t)) or {}).get("collision"))
        print(f"{len(ts)} trees, {n} with collision")
    elif cmd == "build":
        limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
        build(limit)


if __name__ == "__main__":
    main()
