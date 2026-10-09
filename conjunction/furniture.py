"""New furniture from 3D files (Maxim, 02.10.: "angenommen jemand importiert 300 neue Gegenstände und Möbel"): a folder
of FBX files with their textures becomes a content pack - placeable in the editor, usable by every quest, shareable
on Nexus like any mod.

    python -m conjunction.furniture <folder> name="Medieval Furniture" version=1.0 url=...

For every <name>.fbx in the folder:
- REDkit's wcc_lite imports it as a mesh (`import -depot=local`: a cube of 1 m stays 1 m; Z is up),
- the textures beside it become the game's textures: <name>_d / _diffuse / _albedo / _basecolor (.png .tga .jpg)
  for the colour, <name>_n / _normal for the normal map (else a flat one of the engine),
- every material of the mesh gets the game's standard material (pbr_std) with those textures (wcc_lite gives an
  imported mesh the engine's grey default material),
- an entity with the mesh (static mesh component) is the thing placed: dlc\\dlc<pack>\\data\\entities\\<pack>_<name>.w2ent.
Then the DLC is cooked, installed into the game and gets its pack card (packmaker.write) - the catalog shows the
furniture under the pack's name.
"""
import os
import re
import shutil
import struct
import subprocess
import sys

import yaml

from . import config

TEX_D = ("_d", "_diffuse", "_albedo", "_basecolor", "_color", "_col", "")
TEX_N = ("_n", "_normal", "_nrm", "_norm")
IMAGE = (".png", ".tga", ".jpg", ".jpeg", ".dds", ".bmp")
FLAT_NORMAL = "engine\\textures\\editor\\normal.xbm"
PBR = "engine\\materials\\graphs\\pbr_std.w2mg"


def slug(text):
    return re.sub(r"[^a-z0-9_]+", "_", str(text).lower()).strip("_")


def wcc_import(src, out, log=print):
    """REDkit's importer: an FBX -> .w2mesh, an image -> .xbm (about 30 s each: the engine starts every time)."""
    cfg = config.load()
    wcc = cfg["wcc"]
    src, out = os.path.abspath(src), os.path.abspath(out)      # (wcc_lite runs in its own folder)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    r = subprocess.run([wcc, "import", "-depot=local", f"-file={src}", f"-out={out}"], cwd=os.path.dirname(wcc),
                       capture_output=True, text=True, errors="replace")
    if not os.path.exists(out):
        tail = [ln for ln in (r.stdout + r.stderr).splitlines() if "[Error][WCC]" in ln or "Imported" in ln][-3:]
        raise RuntimeError(f"wcc_lite could not import {os.path.basename(src)}: {' '.join(tail) or r.returncode}")
    log(f"[furniture] imported {os.path.basename(src)}")
    return out


def find_texture(folder, base, suffixes):
    files = {f.lower(): f for f in os.listdir(folder)}
    for sfx in suffixes:
        for ext in IMAGE:
            f = files.get(f"{base.lower()}{sfx}{ext}")
            if f:
                return os.path.join(folder, f)
    return None


def texture_mesh(path, diffuse, normal=None):
    """Every material of an imported mesh -> the game's standard material with these textures (depot paths)."""
    from .cr2w import CR2W
    f = CR2W(open(path, "rb").read())
    mesh = f.exports[0]
    if mesh[0] != "CMesh":
        raise ValueError(f"{path}: not a mesh")
    # names first (save() wants every name known before it writes)
    n = {k: f.add_name(k) for k in ("baseMaterial", "handle:IMaterial", "CMaterialInstance", "CMaterialGraph",
                                    "Diffuse", "Normal", "handle:ITexture", "CBitmapTexture")}

    def imp(p, cls):
        for k, (ip, _c, _fl) in enumerate(f.imports):
            if ip.lower() == p.lower():
                return k
        f.imports.append([p, cls, 0])
        return len(f.imports) - 1
    base = imp(PBR, "CMaterialGraph")
    params = [("Diffuse", imp(diffuse, "CBitmapTexture")), ("Normal", imp(normal or FLAT_NORMAL, "CBitmapTexture"))]
    chunk = bytearray(b"\0")
    chunk += struct.pack("<HHIi", n["baseMaterial"], n["handle:IMaterial"], 8, -(base + 1))
    chunk += b"\0\0" + struct.pack("<I", len(params))
    for name, k in params:
        chunk += struct.pack("<IHHi", 12, n[name], n["handle:ITexture"], -(k + 1))
    # the mesh's materials: one instance for all of them (the FBX's material names stay for the chunks)
    props = f.props(mesh[4])
    mats = next((p for p in props if p[0] == "materials"), None)
    if mats is None:
        raise ValueError(f"{path}: the mesh has no materials")
    _name, _t, off, size = mats
    count = struct.unpack_from("<I", mesh[4], off)[0]
    f.exports.append(["CMaterialInstance", 8192, 1, 0, chunk])
    handle = len(f.exports)                         # +n = export n-1
    for k in range(count):
        struct.pack_into("<i", mesh[4], off + 4 + 4 * k, handle)
    tmp = path + ".tmp"
    open(tmp, "wb").write(f.save())
    os.replace(tmp, path)
    return count


def _prop(f, name, typ, value):
    """A property: name, type, size (counting itself), value."""
    return struct.pack("<HHI", f.add_name(name), f.add_name(typ), len(value) + 4) + value


def _floats(f, fields, values):
    """A struct value of Float fields (a Vector)."""
    return b"\0" + b"".join(_prop(f, n, "Float", struct.pack("<f", v)) for n, v in zip(fields, values)) + b"\0\0"


def add_box_collision(path, material="wood_solid"):
    """A box around the mesh as its collision (the game's own furniture has such shapes): CCollisionMesh with a
    CCollisionShapeBox, the mesh's collisionMesh pointing at it - cooked into the DLC's collision cache."""
    from . import cr2w_props
    from .cr2w import CR2W
    f = CR2W(open(path, "rb").read())
    mesh = f.exports[0]
    props = f.props(mesh[4])
    if any(p[0] == "collisionMesh" for p in props):
        return False
    box = cr2w_props.decode(f, mesh[4]).get("boundingBox") or {}
    lo, hi = box.get("Min") or {}, box.get("Max") or {}
    c = [(lo.get(a, 0.0) + hi.get(a, 0.0)) / 2 for a in "XYZ"]
    half = [max(0.01, (hi.get(a, 0.0) - lo.get(a, 0.0)) / 2) for a in "XYZ"]
    for n in ("collisionMesh", "handle:CCollisionMesh", "CCollisionMesh", "shapes", "array:2,0,ptr:ICollisionShape",
              "CCollisionShapeBox", "pose", "Matrix", "Vector", "X", "Y", "Z", "W", "Float", "physicalMaterialName",
              "CName", material, "halfExtendsX", "halfExtendsY", "halfExtendsZ"):
        f.add_name(n)
    xyzw = ("X", "Y", "Z", "W")
    rows = [(1.0, 0.0, 0.0, 0.0), (0.0, 1.0, 0.0, 0.0), (0.0, 0.0, 1.0, 0.0), (c[0], c[1], c[2], 1.0)]
    matrix = b"\0" + b"".join(_prop(f, a, "Vector", _floats(f, xyzw, r)) for a, r in zip(xyzw, rows)) + b"\0\0"
    k_mesh = len(f.exports)                         # the collision mesh's export index, the box after it
    shape = (b"\0" + _prop(f, "pose", "Matrix", matrix) +
             _prop(f, "physicalMaterialName", "CName", struct.pack("<H", f.add_name(material))) +
             b"".join(_prop(f, f"halfExtends{a}", "Float", struct.pack("<f", v)) for a, v in zip("XYZ", half)) +
             b"\0\0")
    cmesh = b"\0" + _prop(f, "shapes", "array:2,0,ptr:ICollisionShape", struct.pack("<Ii", 1, k_mesh + 2)) + b"\0\0"
    f.exports.append(["CCollisionMesh", 0, 1, 0, bytearray(cmesh)])
    f.exports.append(["CCollisionShapeBox", 0, k_mesh + 1, 0, bytearray(shape)])
    # the mesh points at it: a property after autoHideDistance (where the game's meshes have it)
    after = next((p for p in props if p[0] == "autoHideDistance"), props[-1])
    at = after[2] + after[3]
    mesh[4] = bytearray(bytes(mesh[4][:at]) + _prop(f, "collisionMesh", "handle:CCollisionMesh",
                                                     struct.pack("<i", k_mesh + 1)) + bytes(mesh[4][at:]))
    tmp = path + ".tmp"
    open(tmp, "wb").write(f.save())
    os.replace(tmp, path)
    return True


def plan(folder):
    """[(name, fbx, diffuse image, normal image)] of the folder's FBX files."""
    out = []
    for f in sorted(os.listdir(folder)):
        if f.lower().endswith(".fbx"):
            base = os.path.splitext(f)[0]
            out.append((slug(base), os.path.join(folder, f), find_texture(folder, base, TEX_D),
                        find_texture(folder, base, TEX_N)))
    return out


DECAL = re.compile(r"^(?P<base>.+?)\.decal(?:\.(?P<w>\d+(?:\.\d+)?)x(?P<h>\d+(?:\.\d+)?))?\.(png|tga|jpg|jpeg)$",
                   re.I)


def decals(folder):
    """[(name, image, (width, height) in metres)] - pictures to paint onto the world: <name>.decal.png (the longer
    side 1 m) or <name>.decal.2x1.png (2 m wide, 1 m high). A decal projects straight down onto what is below it;
    turned upright (pitch 90) it goes onto a wall."""
    out = []
    for f in sorted(os.listdir(folder)):
        m = DECAL.match(f)
        if not m:
            continue
        if m.group("w"):
            size = (float(m.group("w")), float(m.group("h")))
        else:
            size = (1.0, 1.0)
            try:
                from PIL import Image
                w, h = Image.open(os.path.join(folder, f)).size
                size = (1.0, round(h / w, 3)) if w >= h else (round(w / h, 3), 1.0)
            except (OSError, ImportError, ZeroDivisionError):
                pass
        out.append((slug(m.group("base")), os.path.join(folder, f), size))
    return out


def decal_name(texture, size):
    """The entity name of a decal object of a quest: its texture's name and size."""
    base = slug(os.path.splitext(os.path.basename(str(texture).replace("\\", "/")))[0])[:40]
    return f"decal_{base}_" + "x".join(f"{float(v):g}" for v in size[:2]).replace(".", "_")


def decal_entity(texture, size, depth=0.6):
    return {"entityObject": {".type": "CEntity", "components": {"decal": {
        ".type": "CDecalComponent", "diffuseTexture": texture, "specularity": 0.2,
        "transform": {"pos": [0, 0, 0], "scale": [float(size[0]), float(size[1]), depth]}}}}}


def pack_items(folder):
    """The pack's own items: items.yml beside the 3D files -

        oak_goblet:                       its id (the game's name: <pack>_own_oak_goblet)
          name: Oak goblet
          description: A goblet carved from oak.
          base: Silver goblet             a game item it is like: its icon, category, tags, price, weight
          price: 12                       (each optional: the base item's)
          text: ...                       a letter or a book: its text (readable)
    """
    f = os.path.join(folder, "items.yml")
    if not os.path.exists(f):
        return {}
    data = yaml.safe_load(open(f, encoding="utf-8")) or {}
    return {slug(k): dict(v or {}) for k, v in (data.get("items") or data).items() if slug(k)}


def item_xml_fixer(pid, items, log=print):
    """after_encode for build_dlc: radish writes every own item as a scroll in misc - each gets its base item's icon,
    category, tags, price and weight (or its own), readable only with a text."""
    import re

    def fix(uncooked, dlc):
        path = os.path.join(uncooked, "dlc", dlc, "data", "gameplay", "items", "def_item_quest.xml")
        if not os.path.exists(path) or not items:
            return
        try:
            from .assets import Assets
            db = Assets() if Assets.ready() else None
        except Exception:                           # noqa: BLE001 - no catalog: radish's defaults stay
            db = None
        raw = open(path, "rb").read()
        bom = raw.startswith(b"\xef\xbb\xbf")
        text = raw.decode("utf-8-sig") if bom or not raw.startswith(b"\xff\xfe") else raw.decode("utf-16")

        def one(m):
            block = m.group(0)
            name = re.search(r'<item name="([^"]+)"', block).group(1).lower()
            iid = name[len(f"{pid}_own_"):] if name.startswith(f"{pid}_own_") else None
            d = items.get(iid) if iid else None
            if d is None:
                return block
            base = (db.item(d["base"]) if db and d.get("base") else None) or {}
            attrs = {"category": d.get("category") or base.get("category") or ("book" if d.get("text") else "misc"),
                     "icon_path": d.get("icon") or base.get("icon") or "",
                     "price": str(d.get("price", base.get("price", 1))),
                     "weight": str(d.get("weight", base.get("weight", 0.1)))}
            for k, v in attrs.items():
                if not v:
                    continue
                if re.search(rf'\b{k}="[^"]*"', block):
                    block = re.sub(rf'\b{k}="[^"]*"', f'{k}="{v}"', block, count=1)
                else:
                    block = block.replace('<item name="', f'<item {k}="{v}" name="', 1)
            tags = d.get("tags") or [t for t in str(base.get("tags") or "").split() if not t.startswith("Quest")]
            if d.get("text"):
                tags = list(tags) + ["ReadableItem"]
            block = re.sub(r"<!--<tags></tags>-->|<tags>.*?</tags>", f"<tags>{', '.join(tags)}</tags>", block,
                           count=1, flags=re.S)
            return block
        text = re.sub(r"<item name=.*?</item>", one, text, flags=re.S)
        open(path, "wb").write((b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8") if bom or not
                               raw.startswith(b"\xff\xfe") else text.encode("utf-16"))
        log(f"[furniture] {pid}: {len(items)} items")
    return fix


def build_pack(folder, meta, install=True, log=print, work=None):
    """The folder's FBX files and decal pictures -> an installed content pack -> its card."""
    from . import build as builder
    from . import packmaker
    pid = slug(meta.get("id") or meta.get("name") or os.path.basename(folder.rstrip("\\/")))
    if not pid:
        raise ValueError("The pack needs a name")
    dlc = f"dlc{pid}"
    work = work or os.path.join(os.path.dirname(config.PATH), "packs_work", pid)
    raw = os.path.join(work, "imported")
    extra, ents = {}, {}
    things = plan(folder)
    pictures = decals(folder)
    items = pack_items(folder)
    if not things and not pictures and not items:
        raise ValueError(f"no .fbx files, no .decal pictures and no items.yml in {folder}")
    for name, img, size in pictures:
        rel = f"dlc\\{dlc}\\data\\decals\\{name}.xbm"
        wcc_import(img, os.path.join(raw, rel), log)
        extra[rel] = os.path.join(raw, rel)
        ents[f"{pid}_{name}"] = decal_entity(rel, size)
    for name, fbx, diff, norm in things:
        mesh_rel = f"dlc\\{dlc}\\data\\furniture\\{name}.w2mesh"
        mesh = os.path.join(raw, mesh_rel)
        wcc_import(fbx, mesh, log)
        tex = {}
        for kind, img in (("d", diff), ("n", norm)):
            if img:
                rel = f"dlc\\{dlc}\\data\\furniture\\textures\\{name}_{kind}.xbm"
                wcc_import(img, os.path.join(raw, rel), log)
                extra[rel] = os.path.join(raw, rel)
                tex[kind] = rel
        if "d" in tex:
            texture_mesh(mesh, tex["d"], tex.get("n"))
        else:
            log(f"[furniture] {name}: no colour texture next to it ({name}_d.png), shown grey")
        if meta.get("collision", True):
            add_box_collision(mesh)
        extra[mesh_rel] = mesh
        ents[f"{pid}_{name}"] = {"entityObject": {".type": "CEntity", "components": {"mesh": {
            ".type": "CStaticMeshComponent", "isStreamed": False, "mesh": mesh_rel}}}}
    defdir = os.path.join(work, "definition.quest")
    if os.path.isdir(defdir):
        shutil.rmtree(defdir)
    os.makedirs(defdir)
    prod = {"production": {"settings": {"id": pid, "caption": meta.get("name") or pid,
                                        "description": meta.get("description") or "furniture",
                                        "menuvisibile": False, "enabled": True, "storesdata": False,
                                        "strings-idspace": 9997, "strings-idstart": 0, "version": 12}}}
    yaml.safe_dump(prod, open(os.path.join(defdir, f"prod.quest-{pid}.yml"), "w", encoding="utf-8"), sort_keys=False)
    yaml.safe_dump({"structure": {"quest": {"blocks": {"start": {"next": ["end"]}, "end": {"next": ".done"}}}}},
                   open(os.path.join(defdir, "structure.root.yml"), "w", encoding="utf-8"), sort_keys=False)
    if ents:
        yaml.safe_dump({"entities": ents}, open(os.path.join(defdir, "entities.furniture.yml"), "w",
                                                encoding="utf-8"), sort_keys=False)
    if items:                                       # radish: <pack>_own_<id>, name and description as strings
        own = {iid: {k: v for k, v in (("name", d.get("name") or iid), ("description", d.get("description", "")),
                                       ("text", d.get("text", ""))) if v} for iid, d in items.items()}
        yaml.safe_dump({"items": {"own": own}}, open(os.path.join(defdir, "items.yml"), "w", encoding="utf-8"),
                       sort_keys=False, allow_unicode=True)
    packed = builder.build_dlc(defdir, work, install=False, log=log, extra=extra,
                               after_encode=item_xml_fixer(pid, items, log))
    # the textures: cooked into the DLC's texture cache (REDkit 5's split depot: no -basedir, the DLC is linked in)
    cfg = config.load()
    content_dir = os.path.join(packed, "content")
    db = os.path.join(work, "cook.db")
    caches = [("textures", "texture.cache")] if any(rel.endswith(".xbm") for rel in extra) else []
    caches.append(("physics", "collision.cache"))          # the boxes the player bumps into
    for kind, name in caches:
        log(f"[furniture] {pid}: {kind} cache")
        builder.run([cfg["wcc"], "buildcache", kind, "-platform=pc", f"-db={db}",
                     f"-out={os.path.join(content_dir, name)}"], cwd=os.path.dirname(cfg["wcc"]), log=log)
    builder.run([cfg["wcc"], "metadatastore", f"-path={content_dir}"], cwd=os.path.dirname(cfg["wcc"]), log=log)
    target = os.path.join(cfg["game"], "dlc", dlc) if install else packed
    if install:
        if os.path.exists(target):
            shutil.rmtree(target)
        shutil.copytree(packed, target)
    m = packmaker.write(target, dict(meta, id=pid))           # (its kinds from what is in it)
    if install:                                     # the card goes with the pack when it is shared
        for f in (packmaker.content.MARKER, packmaker.content.INDEX):
            shutil.copy(os.path.join(target, f), os.path.join(packed, f))
    log(f"[furniture] {m['name']} {m['version']}: {len(things)} pieces, {len(pictures)} decals, {len(items)} items"
        f" -> {target}")
    return target


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    folder = sys.argv[1]
    meta = dict(a.split("=", 1) for a in sys.argv[2:] if "=" in a)
    for name, fbx, d, n in plan(folder):
        print(f"  {name}: {os.path.basename(fbx)}  colour {d and os.path.basename(d)}  normal {n and os.path.basename(n)}")
    if "--plan" in sys.argv:
        return
    build_pack(folder, meta, install="--no-install" not in sys.argv)


if __name__ == "__main__":
    main()
