"""The mesh library: every environment mesh of the game made placeable. The engine can only spawn entity templates,
and most of the world (walls, roofs, rocks, crates, clutter) exists only as meshes - so Conjunction builds, once on the
user's machine, a DLC with one tiny entity per mesh (a static mesh component that points to the game's mesh; nothing
of the game is copied).

    python -m conjunction.meshlib build [--limit N]     generate, encode, cook, pack, install (one time, takes a while)
    python -m conjunction.meshlib list                  how many meshes would go in

The catalog lists them as kind by path, source "Mesh"; the editor places them like any template.
"""
import hashlib
import json
import os
import re
import sys

import yaml

from . import catalog, config

DLC_ID = "conjunctionmeshes"
INDEX = os.path.join(os.path.dirname(config.PATH), "meshes.json")
DECAL_INDEX = os.path.join(os.path.dirname(config.PATH), "decals.json")     # texture -> library template
# a decal's picture, not one of its other maps (normal, specular, height, mask ...)
DECAL_MAPS = re.compile(r"(_n|_nm|_nrm|_normal|_s|_spec|_h|_a|_alpha|_m|_mask|_r|_rough|_e|_ao)\d*\.xbm$")
# world building meshes; not: characters (body parts), items (have templates), merged sector meshes, engine, fx
KEEP = re.compile(r"^(dlc\\[^\\]+\\(data\\)?)?environment\\|^gameplay\\")
DROP = re.compile(r"proxy|\\lod\d|_lod\d|shadow|\\collision|_col\.w2mesh$|occluder|\\terrain\\|\\foliage\\|"
                  r"\\trees?\\|\\grass\\|\\water\\")


def meshes(game=None):
    game = game or config.load()["game"]
    seen = set()
    for b in catalog.bundles(game):
        for p in catalog.bundle_files(b):
            if p.endswith(".w2mesh") and p not in seen and KEEP.search(p) and not DROP.search(p):
                seen.add(p)
    return sorted(seen)


def decals(game=None):
    """The game's decal pictures (vanilla: base game and expansions)."""
    from .bundles import Depot
    from .content import VANILLA_FILE
    d = Depot(game)
    return sorted(p for p in d.where if p.endswith(".xbm") and "decal" in p and VANILLA_FILE.match(p)
                  and not DECAL_MAPS.search(p) and not p.startswith("characters\\") and "censored" not in p)


def decal_entity_name(texture):
    base = re.sub(r"[^a-z0-9_]", "_", os.path.splitext(os.path.basename(texture))[0].lower())[:40]
    return f"d_{base}_{hashlib.md5(texture.encode()).hexdigest()[:6]}"


def decal_index():
    """decal texture -> library template; empty without a library (or one built before decals were in it)."""
    if not os.path.exists(DECAL_INDEX):
        return {}
    return json.load(open(DECAL_INDEX, encoding="utf-8"))


def decal_reverse_index():
    return {t.lower(): tex for tex, t in decal_index().items()}


def entity_name(mesh):
    base = re.sub(r"[^a-z0-9_]", "_", os.path.splitext(os.path.basename(mesh))[0].lower())[:40]
    return f"m_{base}_{hashlib.md5(mesh.encode()).hexdigest()[:6]}"


def wrapper(mesh):
    """radish entity definition: an entity with one static mesh component (collision from the mesh). Not streamed:
    wcc_lite cooks streamed components out of a template that is spawned by script (nothing was drawn)."""
    return {"entityObject": {".type": "CEntity", "components": {"mesh": {
        ".type": "CStaticMeshComponent", "isStreamed": False, "mesh": mesh}}}}


def reverse_index():
    """library template (lower case) -> mesh path; empty without a library."""
    if not os.path.exists(INDEX):
        return {}
    return {t.lower(): m for m, t in json.load(open(INDEX, encoding="utf-8")).items()}


def generate(defdir, mesh_list, decal_list=(), decal_index_out=None):
    """radish definition: production + an empty quest (the DLC needs one) + entities in files of 2000 (and the decal
    pictures: decal_index_out gets texture -> template)."""
    os.makedirs(defdir, exist_ok=True)
    for f in os.listdir(defdir):
        if f.endswith(".yml"):
            os.remove(os.path.join(defdir, f))
    prod = {"production": {"settings": {"id": DLC_ID, "caption": "conjunction mesh library", "description":
                                        "every environment mesh as a placeable entity (generated locally)",
                                        "menuvisibile": False, "enabled": True, "storesdata": False,
                                        "strings-idspace": 9998, "strings-idstart": 0, "version": 12}}}
    yaml.safe_dump(prod, open(os.path.join(defdir, f"prod.quest-{DLC_ID}.yml"), "w", encoding="utf-8"),
                   sort_keys=False)
    yaml.safe_dump({"structure": {"quest": {"blocks": {"start": {"next": ["end"]}, "end": {"next": ".done"}}}}},
                   open(os.path.join(defdir, "structure.root.yml"), "w", encoding="utf-8"), sort_keys=False)
    # the editor's lamp (H, conjunction_editor.ws CjLamp): a flashlight - a spot light shining where the camera looks,
    # after the game's own lamp (items\usable\quest_character_lamp.w2ent: spot, radius 8, brightness 60),
    # wider and farther, without flickering and shadows
    lamp = {"entityObject": {".type": "CEntity", "components": {"lamp": {
        ".type": "CSpotLightComponent", "radius": 25.0, "brightness": 25.0, "outerAngle": 70.0, "softness": 2.0,
        "color": [255, 246, 232, 255], "shadowCastingMode": "LSCM_None", "autoHideDistance": 80.0}}}}
    yaml.safe_dump({"entities": {"cj_editor_lamp": lamp}},
                   open(os.path.join(defdir, "entities.lamp.yml"), "w", encoding="utf-8"), sort_keys=False)
    index = {}
    for k in range(0, len(mesh_list), 2000):
        ents = {}
        for m in mesh_list[k:k + 2000]:
            name = entity_name(m)
            ents[name] = wrapper(m)
            index[m] = "\\".join(["dlc", f"dlc{DLC_ID}", "data", "entities", name + ".w2ent"])
        yaml.safe_dump({"entities": ents}, open(os.path.join(defdir, f"entities.{k // 2000:03d}.yml"), "w",
                                                encoding="utf-8"), sort_keys=False)
    if decal_list:
        from .furniture import decal_entity
        ents = {}
        for tex in decal_list:
            name = decal_entity_name(tex)
            ents[name] = decal_entity(tex, (1.0, 1.0))
            if decal_index_out is not None:
                decal_index_out[tex] = "\\".join(["dlc", f"dlc{DLC_ID}", "data", "entities", name + ".w2ent"])
        yaml.safe_dump({"entities": ents}, open(os.path.join(defdir, "entities.decals.yml"), "w", encoding="utf-8"),
                       sort_keys=False)
    return index


def index():
    """mesh path -> library template path; empty without a library."""
    if not os.path.exists(INDEX):
        return {}
    return json.load(open(INDEX, encoding="utf-8"))


def catalog_entries():
    """Catalog entries for the installed library (empty if it was never built)."""
    if not os.path.exists(INDEX):
        return []
    index = json.load(open(INDEX, encoding="utf-8"))
    out = []
    for mesh, template in index.items():
        out.append({"path": template, "name": catalog.caption(mesh), "kind": catalog.kind_of(mesh),
                    "source": "Mesh", "tags": catalog.tags_of(mesh) + ["mesh"], "group": catalog.group_of(mesh),
                    "quest": "\\quest" in "\\" + mesh, "mesh": mesh})
    return out


def build(limit=None, install=True, log=print):
    from . import build as builder
    cfg = config.load()
    out = os.path.join(os.path.dirname(config.PATH), "meshlib")
    mesh_list = meshes(cfg["game"])
    if limit:
        mesh_list = mesh_list[:limit]
    log(f"[meshlib] {len(mesh_list)} meshes")
    decal_list = decals(cfg["game"])
    log(f"[meshlib] {len(decal_list)} decal pictures")
    dindex = {}
    index = generate(os.path.join(out, "definition.quest"), mesh_list, decal_list, dindex)
    builder.build_dlc(os.path.join(out, "definition.quest"), out, install=install, log=log)
    json.dump(index, open(INDEX, "w", encoding="utf-8"))
    json.dump(dindex, open(DECAL_INDEX, "w", encoding="utf-8"))
    log(f"[meshlib] catalog index -> {INDEX}")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        ms = meshes()
        print(len(ms), "meshes;", ms[:3])
    elif cmd == "build":
        limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
        build(limit)


if __name__ == "__main__":
    main()
