"""The asset database: every placeable template and every item of the user's game, with what they are.

    python -m conjunction.assets build            once, a few minutes (setup offers it)
    python -m conjunction.assets show <path>      what the database knows about a template or item
    python -m conjunction.assets probe <path>     read one template straight from the bundles (development)

Everything is read from the user's own game and REDkit - nothing of theirs is copied into the repo:
- templates: every .w2ent in the bundles. A cooked template is a CR2W with the template's objects (the entity
  class, parameter objects like the loot table) and, embedded in it, the compiled entity with its components
  (inventory, meshes, lights, ...). Class, components, inventory yes/no, loot table, meshes, appearances and the
  display name (the entity's `displayName`, a string id) come from there.
- items: the item definitions (gameplay\\items*\\*.xml): name, category, tags, price, weight, icon, templates;
  display names and descriptions from the game's strings - an item gives the key, the strings store it as a
  Java-style string hash (h = 31 h + c).
- strings: the game's English .w3strings, read by w3strings.py (the remaster's v164 too).
- pictures: REDkit's asset thumbnails (r4data\\thumbnails\\<path>.thmb = a CR2W around a 500 x 500 PNG).
Stored in %APPDATA%\\conjunction\\assets.sqlite (with full text search).
"""
import os
import re
import struct
import sys

from . import config
from .cr2w import CR2W

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(os.path.dirname(config.PATH), "assets.sqlite")
CLUE_CLASSES = ("W3MonsterClue", "W3ClueCorpse")
THUMBS = os.path.join(os.path.dirname(config.PATH), "thumbs")


# --- one template
def _cr2w_parts(data):
    """The CR2W files in a cooked template: the template itself and the embedded ones (compiled entity, streamed
    component buffers). Unreadable pieces are skipped."""
    out, i = [], 0
    while True:
        i = data.find(b"CR2W", i)
        if i < 0:
            return out
        try:
            out.append(CR2W(data[i:]))
        except Exception:                       # noqa: BLE001 - "CR2W" inside other data
            pass
        i += 4


def _prop_value(f, chunk, name):
    """(type, raw value bytes) of a top-level property of an object's data, or (None, None)."""
    for n, t, off, size in f.props(chunk):
        if n == name:
            return t, bytes(chunk[off:off + size])
    return None, None


def _struct_props(f, raw, start=1):
    """name -> (type, raw) of the fields of a struct value (starts with a 0 byte, ends with name 0)."""
    out, i = {}, start
    while i + 2 <= len(raw):
        nm = struct.unpack_from("<H", raw, i)[0]
        if nm == 0:
            break
        tp, sz = struct.unpack_from("<HI", raw, i + 2)
        out[f.names[nm]] = (f.names[tp], raw[i + 8:i + 4 + sz])
        i += 4 + sz
    return out, i + 2


def appearances(f, chunk):
    t, raw = _prop_value(f, chunk, "appearances")
    if not raw:
        return []
    count = struct.unpack_from("<I", raw, 0)[0]
    names, i = [], 4
    for _ in range(count):
        # an element: a 0 byte, its fields, name 0 (_struct_props returns the index after that end marker)
        fields, i = _struct_props(f, raw, i + 1)
        if "name" in fields and fields["name"][0] == "CName":
            names.append(f.names[struct.unpack_from("<H", fields["name"][1], 0)[0]])
    return names


def loot_defs(f, chunk):
    """The loot definition names of a CR4LootParam (containers: array of CR4LootContainerParam {name: CName, ...})."""
    t, raw = _prop_value(f, chunk, "containers")
    if not raw or len(raw) < 4:
        return []
    out, i = [], 4
    for _ in range(struct.unpack_from("<I", raw, 0)[0]):
        fields, i = _struct_props(f, raw, i + 1)
        if "name" in fields and fields["name"][0] == "CName":
            out.append(f.names[struct.unpack_from("<H", fields["name"][1], 0)[0]])
    return out


def read_template(data):
    """What a cooked template is: class, components, inventory, loot, meshes, appearances, display name id."""
    parts = _cr2w_parts(data)
    if not parts:
        return None
    top = parts[0]
    info = {"class": "", "components": [], "inventory": False, "loot": [], "meshes": [], "includes": [],
            "appearances": [], "name_id": 0, "loot_defs": []}
    for cls, _fl, _p, _t, chunk in top.exports:
        if cls == "CEntityTemplate":
            # the entity object the template points at (a handle: +n = export n-1), else its entityClass
            t, raw = _prop_value(top, chunk, "entityObject")
            if raw and len(raw) >= 4:
                k = struct.unpack_from("<i", raw, 0)[0]
                if 0 < k <= len(top.exports):
                    info["class"] = top.exports[k - 1][0]
            if not info["class"]:
                t, raw = _prop_value(top, chunk, "entityClass")
                if raw:
                    info["class"] = top.names[struct.unpack_from("<H", raw, 0)[0]]
            break
    if (not info["class"] or info["class"].endswith("Component")) and len(parts) > 1 and parts[1].exports:
        info["class"] = parts[1].exports[0][0]  # the compiled entity's first object is the entity
    comps = set()
    for f in parts[:2]:
        for cls, _fl, _p, _t, chunk in f.exports:
            if cls.endswith("Component") and cls != "CFXSpawnerComponent":
                comps.add(cls)
    for f in parts:
        for path, cls, _fl in f.imports:
            p = path.lower()
            if p.endswith(".w2mesh") and p not in info["meshes"]:
                info["meshes"].append(p)
            elif p.endswith(".w2ent") and f is top:
                info["includes"].append(p)
            if ("_container_definitions" in p and "_mesh_entities" not in p) or "\\loot" in p:
                info["loot"].append(p)
    for f in parts[:2]:
        for cls, _fl, _p, _t, chunk in f.exports:
            if cls == "CR4LootParam":
                for n in loot_defs(f, chunk):
                    if n not in info["loot_defs"]:
                        info["loot_defs"].append(n)
    info["components"] = sorted(comps)
    info["inventory"] = "CInventoryComponent" in comps
    for cls, _fl, _p, _t, chunk in top.exports:
        if cls == "CEntityTemplate":
            info["appearances"] = appearances(top, chunk)
    for f in parts[:2]:
        for cls, _fl, _p, _t, chunk in f.exports:
            if cls == info["class"]:
                t, raw = _prop_value(f, chunk, "displayName")
                if t == "LocalizedString" and raw and len(raw) >= 4:
                    info["name_id"] = info["name_id"] or struct.unpack_from("<I", raw, 0)[0]
    return info


def java_hash(s):
    h = 0
    for c in s.encode("ascii", "replace"):
        h = (31 * h + c) & 0xFFFFFFFF
    return h


# --- strings
LANG = "en"


def string_files(lang, game=None):
    import glob
    game = game or config.load()["game"]
    return sorted(glob.glob(os.path.join(game, "content", "content*", f"{lang}.w3strings"))) + \
        sorted(glob.glob(os.path.join(game, "dlc", "*", "content", f"{lang}.w3strings")))


def read_strings(lang, log=print, game=None):
    """id -> text and key hash -> id of every string of a language - Conjunction's own reader (w3strings.py) reads the
    remaster's v164 as well as the older versions (radish's decoder stops at v164)."""
    from . import w3strings
    by_id, by_key = {}, {}
    for src in string_files(lang, game):
        try:
            _version, _lang, texts, keys = w3strings.read(open(src, "rb").read(), lang.lower())
        except (OSError, ValueError, KeyError, IndexError) as ex:
            log(f"[assets] strings: {src} unreadable ({ex})")
            continue
        by_id.update(texts)
        for sid, h in keys.items():
            by_key[h] = sid
    log(f"[assets] strings {lang}: {len(by_id)}")
    return by_id, by_key


# --- items
def _attrs(tag):
    return {k: v for k, v in re.findall(r'(\w+)\s*=\s*"([^"]*)"', tag)}


def read_items(depot):
    """Every item definition (later files override earlier ones with the same name, as the game's _plus files)."""
    items = {}
    # the base game's and the expansions' (dlc\ep1, dlc\bob ...: 02.10. - they were missing, ~1600 items); a content
    # pack's join from its own table of contents
    from .content import ITEM_XML, VANILLA_FILE
    files = [p for p in depot.where if ITEM_XML.search(p) and VANILLA_FILE.match(p)]
    for p in sorted(files, key=lambda x: (x.startswith("dlc\\"), "items_plus" in x, x)):
        try:
            raw = depot.read(p)
            # UTF-16 up to 4.04, UTF-8 with BOM since the remaster (5.0)
            text = raw.decode("utf-16", "replace") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else \
                raw.decode("utf-8-sig", "replace")
        except Exception:                           # noqa: BLE001
            continue
        for m in re.finditer(r"<item\s([^>]*?)(/>|>(.*?)</item>)", text, re.S):
            a = _attrs(m.group(1))
            if not a.get("name"):
                continue
            body = m.group(3) or ""
            tags = []
            t = re.search(r"<tags>(.*?)</tags>", body, re.S)
            if t:
                tags = [x.strip() for x in t.group(1).split(",") if x.strip()]
            items[a["name"]] = {"name": a["name"], "category": a.get("category", ""), "tags": tags,
                                "price": float(a.get("price") or 0), "weight": float(a.get("weight") or 0),
                                "icon": a.get("icon_path", ""), "key_name": a.get("localisation_key_name", ""),
                                "key_desc": a.get("localisation_key_description", ""),
                                "equip_template": a.get("equip_template", ""), "stackable": a.get("stackable", ""),
                                "file": p}
    return items


def _xml_text(raw):
    return raw.decode("utf-16", "replace") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8-sig", "replace")


def read_loot(depot):
    """Every loot definition (gameplay\\items*\\def_loot*.xml; later files override, as the game's _plus files):
    name -> {"entries": [[item, min, max, chance]], "file"}."""
    out = {}
    files = [p for p in depot.where if p.endswith(".xml") and "\\def_loot" in p and "\\items" in p]
    for p in sorted(files, key=lambda x: ("_plus" in x, x)):
        try:
            text = _xml_text(depot.read(p))
        except Exception:                           # noqa: BLE001
            continue
        text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
        for m in re.finditer(r"<loot\s([^>]*?)(/>|>(.*?)</loot>)", text, re.S):
            a = _attrs(m.group(1))
            if not a.get("name"):
                continue
            entries = []
            for e in re.finditer(r"<loot_entry\s([^>]*?)/?>", m.group(3) or ""):
                b = _attrs(e.group(1))
                if b.get("name"):
                    entries.append([b["name"], int(float(b.get("quantity_min") or 1)),
                                    int(float(b.get("quantity_max") or 1)), float(b.get("chance") or 0)])
            out[a["name"]] = {"entries": entries, "file": p}
    return out


# --- kinds and tags
LIGHTS = {"CPointLightComponent", "CSpotLightComponent", "CLightComponent"}


def _camel_words(cls):
    base = re.sub(r"^(CR4|C|W3)(?=[A-Z])", "", cls)
    return [w.lower() for w in re.findall(r"[A-Z][a-z]+|[A-Z]+(?![a-z])|\d+", base) if len(w) > 2]


def kind_and_tags(path, info):
    from . import catalog
    kind = catalog.kind_of(path)
    tags = set(catalog.tags_of(path))
    cls = info.get("class", "")
    comps = set(info.get("components", []))
    tags.update(_camel_words(cls))
    if "Container" in cls:
        kind = "Container" if kind not in ("Character part",) else kind
        tags.add("container")
    if info.get("inventory"):
        tags.add("inventory")
    if info.get("loot") or "Container" in cls:
        tags.add("lootable")
    if cls == "CNewNPC" and kind not in ("Monster", "Animal"):
        kind = "NPC"
    if comps & LIGHTS:
        tags.add("light")
        if kind in ("Decoration", "Other", "Gameplay"):
            kind = "Light"
    if "Door" in cls:
        tags.add("door")
    if "CInteractionComponent" in comps:
        tags.add("interactive")
    return kind, sorted(tags)


# --- building
def _probe_many(paths):
    from .bundles import Depot
    depot = Depot()
    out = []
    for p in paths:
        try:
            out.append((p, read_template(depot.read(p))))
        except Exception as ex:                     # noqa: BLE001 - one broken template does not stop the build
            out.append((p, {"error": str(ex)}))
    return out


TEXTURE_EXT = (".xbm", ".w2mi", ".texarray")


def mesh_textured(data):
    """Does a cooked mesh use any texture? The engine's bare material alone = a technical helper (a blocker box, a
    proxy) that nobody sees in the game."""
    parts = _cr2w_parts(data)
    return bool(parts) and any(path.lower().endswith(TEXTURE_EXT) for f in parts for path, _c, _f in f.imports)


def _textures_many(paths):
    from .bundles import Depot
    depot = Depot()
    out = []
    for p in paths:
        try:
            out.append((p, int(mesh_textured(depot.read(p)))))
        except Exception:                           # noqa: BLE001 - unreadable: counted as textured (shown)
            out.append((p, 1))
    return out


SCHEMA = """
create table meta(key text primary key, value text);
create table templates(path text primary key, name text, named int, kind text, class text, source text,
    quest int, inventory int, loot text, components text, appearances text, meshes text, tags text, grp text,
    thumb int, cat text, sub text, styles text, traits text, loot_defs text);
create table loot(name text primary key, entries text, file text);
create table items(name text primary key, label text, descr text, category text, tags text, price real,
    weight real, icon text, equip_template text, stackable text, file text, cat text, sub text);
create table mesh_info(path text primary key, textured int);
create virtual table template_search using fts5(path unindexed, name, words,
    tokenize='unicode61 remove_diacritics 2');
create virtual table item_search using fts5(name unindexed, label, words, tokenize='unicode61 remove_diacritics 2');
"""
VERSION = 5


def build(workers=6, log=print):
    import json
    import sqlite3
    import time
    from concurrent.futures import ProcessPoolExecutor

    from . import catalog, taxonomy
    from .bundles import Depot
    t0 = time.time()
    cfg = config.load()
    depot = Depot()
    text_by_id, id_by_key = read_strings(LANG, log)
    # the game's own: the DLCs and mods packed as content\*.bundle (content packs, quests, the mesh library) join the
    # catalog from their own table of contents (content.py)
    own = os.path.normcase(os.path.join(cfg["game"], "content")) + os.sep
    paths = sorted(p for p in depot.where if p.endswith(".w2ent") and not catalog.SKIP.search(p)
                   and "\\dlcconjunctionmeshes\\" not in p and
                   (os.path.normcase(depot.where[p][0]).startswith(own) or "\\bundles\\" in depot.where[p][0]))
    log(f"[assets] {len(paths)} templates, reading with {workers} processes ...")
    chunks = [paths[i::workers * 8] for i in range(workers * 8)]
    infos = {}
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for n, batch in enumerate(pool.map(_probe_many, chunks)):
            for p, info in batch:
                infos[p] = info
            if n % 8 == 7:
                log(f"[assets]   {len(infos)} / {len(paths)}")
    # which meshes have textures at all (the library's and the templates')
    from . import meshlib
    mesh_paths = set(meshlib.meshes())
    for info in infos.values():
        if info and "error" not in info:
            mesh_paths.update(info.get("meshes", []))
    mesh_paths = sorted(m for m in mesh_paths if m in depot.where)
    log(f"[assets] {len(mesh_paths)} meshes: textures ...")
    textured = {}
    chunks = [mesh_paths[i::workers * 8] for i in range(workers * 8)]
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for batch in pool.map(_textures_many, chunks):
            textured.update(batch)
    log(f"[assets]   {sum(1 for v in textured.values() if not v)} without any texture (hidden)")
    thumbs = os.path.join(cfg["redkit"], "r4data", "thumbnails")
    tmp = DB + ".new"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.executescript(SCHEMA)
    rows, search = [], []
    for p, info in infos.items():
        if not info or "error" in info:
            info = {"class": "", "components": [], "inventory": False, "loot": [], "meshes": [], "appearances": [],
                    "name_id": 0}
        kind, tags = kind_and_tags(p, info)
        real = text_by_id.get(info.get("name_id") or -1) or ""
        name = real or catalog.caption(p)
        cls, comps = info.get("class", ""), info.get("components", [])
        cat, sub = taxonomy.classify(p, cls, comps, kind, real, info.get("meshes", []))
        ms = info.get("meshes", [])
        if cls in ("CEntity", "CGameplayEntity", "") and ms and not any(textured.get(m, 1) for m in ms):
            cat, sub = "Internal", "Internal"          # shows only untextured helper geometry
        styles = taxonomy.styles(p, real)
        traits = taxonomy.traits(p, cls, comps, info.get("inventory"), info.get("loot"), bool(real))
        has_thumb = os.path.exists(os.path.join(thumbs, os.path.splitext(p)[0] + ".thmb"))
        rows.append((p, name, int(bool(real)), kind, cls, catalog.source_of(p), int("quest" in traits),
                     int(bool(info.get("inventory"))), json.dumps(info.get("loot", [])), json.dumps(comps),
                     json.dumps(info.get("appearances", [])), json.dumps(info.get("meshes", [])[:40]), " ".join(tags),
                     catalog.group_of(p), int(has_thumb), cat, sub, " ".join(s.replace(" ", "_") for s in styles),
                     " ".join(traits), json.dumps(info.get("loot_defs", []))))
        search.append((p, name, " ".join([cat, sub, " ".join(styles), kind, cls, " ".join(tags), catalog.group_of(p),
                                          p.replace("\\", " ").replace("_", " ")])))
    db.executemany("insert into templates values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    loot = read_loot(depot)
    db.executemany("insert into loot values (?,?,?)", [(n, json.dumps(v["entries"]), v["file"])
                                                      for n, v in sorted(loot.items())])
    log(f"[assets] {len(loot)} loot tables")
    db.executemany("insert into mesh_info values (?,?)", sorted(textured.items()))
    db.executemany("insert into template_search values (?,?,?)", search)
    items = read_items(depot)
    irows, isearch = [], []
    for it in items.values():
        kn, kd = java_hash(it["key_name"].lower()), java_hash(it["key_desc"].lower())   # (hashed lower case)
        label = text_by_id.get(id_by_key.get(kn, -1), "") or it["name"]
        descr = text_by_id.get(id_by_key.get(kd, -1), "")
        cat, sub = taxonomy.classify_item(it["category"], it["tags"])
        irows.append((it["name"], label, descr, it["category"], " ".join(it["tags"]), it["price"], it["weight"],
                      it["icon"], it["equip_template"], it["stackable"], it["file"], cat, sub))
        isearch.append((it["name"], label, " ".join([it["name"], cat, sub, it["category"].replace("_", " "),
                                                     " ".join(it["tags"])])))
    db.executemany("insert into items values (?,?,?,?,?,?,?,?,?,?,?,?,?)", irows)
    db.executemany("insert into item_search values (?,?,?)", isearch)
    db.execute("insert into meta values ('version', ?)", (str(VERSION),))
    db.commit()
    db.close()
    os.replace(tmp, DB)
    log(f"[assets] {len(rows)} templates, {len(irows)} items -> {DB} ({time.time() - t0:.0f} s)")
    try:                                    # which people can talk: the catalog's speech badge (talking.py)
        from . import talking
        talking.fill([r[0] for r in rows if r[15] == "People"], workers, log)
    except Exception as ex:                 # noqa: BLE001 - the catalog stands without it
        log(f"[assets] which people can talk: {ex}")


ITEM_SCRIPT = "conjunction_items.ws"


def shipped_names(function):
    """The names Conjunction's own item table holds for one of its lookups (CjItemName / CjLootName)."""
    path = os.path.join(HERE, "..", "mod", "runtime", "scripts", "local", ITEM_SCRIPT)
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return []
    out = []
    for block in re.findall(rf"function {function}\d+\(s : string\) : name {{(.*?)\n}}", text, re.S):
        out += re.findall(r'if \(s == "([^"]+)"\)', block)
    return sorted(set(out))


def write_item_script(folder):
    """conjunction_items.ws into the installed script mod (made from the user's game, not part of the repo):
    CjItemName("Ruby dust") -> 'Ruby dust'. WitcherScript cannot turn text into a name, and radish passes names to
    quest functions only as [a-z_0-9] - so quests pass items as text and Conjunction's functions look them up here."""
    import sqlite3
    # always written - Conjunction's scripts call CjItemName; without the database it knows no item yet
    names = sorted(r[0] for r in sqlite3.connect(DB).execute("select name from items")) if Assets.ready() else \
        shipped_names("CjItemName")                # (no catalog here: the table Conjunction brings)
    # the items of the content packs in this game (a quest gives them by text like the game's)
    from . import content
    try:
        packs = content.installed_packs()
    except OSError:
        packs = []
    names = sorted(set(names) | {i["name"] for p in packs for i in content.pack_index(p).get("items") or []
                                 if i.get("name")})
    # a name literal takes letters, digits, spaces and _ only (a hyphen stops the script compiler)
    ok = [n for n in names if re.fullmatch(r"[A-Za-z0-9 _]+", n)]
    # small functions: one with all 3 500 items is too big for the script compiler ("memory exhausted")
    chunks = [ok[i:i + 120] for i in range(0, len(ok), 120)]
    out = ["// generated by conjunction from this game's item definitions - an item's name as text -> the item's name"]
    for k, group in enumerate(chunks):
        out.append(f"function CjItemName{k}(s : string) : name {{")
        out += [f'    if (s == "{n}") {{ return \'{n}\'; }}' for n in group]
        out += ["    return '';", "}"]
    out += ["function CjItemName(s : string) : name {", "    var n : name;"]
    for k in range(len(chunks)):
        out.append(f"    n = CjItemName{k}(s); if (n != '') {{ return n; }}")
    out += ["    return '';", "}", ""]
    # loot table names the same way (they have spaces and capitals: no radish name)
    loot = sorted(r[0] for r in sqlite3.connect(DB).execute("select name from loot")) if Assets.ready() else \
        shipped_names("CjLootName")
    loot = [n for n in loot if re.fullmatch(r"[A-Za-z0-9 _]+", n)]
    lchunks = [loot[i:i + 120] for i in range(0, len(loot), 120)]
    for k, group in enumerate(lchunks):
        out.append(f"function CjLootName{k}(s : string) : name {{")
        out += [f'    if (s == "{n}") {{ return \'{n}\'; }}' for n in group]
        out += ["    return '';", "}"]
    out += ["function CjLootName(s : string) : name {", "    var n : name;"]
    for k in range(len(lchunks)):
        out.append(f"    n = CjLootName{k}(s); if (n != '') {{ return n; }}")
    out += ["    return '';", "}", ""]
    path = os.path.join(folder, ITEM_SCRIPT)
    open(path, "w", encoding="utf-8").write("\n".join(out))
    return path


def _fts(text):
    """User words -> an FTS5 query: every word, as a prefix ('gua' finds 'guard')."""
    words = re.findall(r"\w+", text.lower())
    return " AND ".join(f'"{w}"*' for w in words)


class Assets:
    """The database for the editor: searching templates and items, details, pictures."""

    def __init__(self):
        import sqlite3
        # read into memory and let the file go: a rebuild can replace it while the editor runs (Windows locks open files)
        src = sqlite3.connect(DB)
        self.db = sqlite3.connect(":memory:", check_same_thread=False)
        src.backup(self.db)
        src.close()
        self.packs = self._merge_packs()
        self.db.row_factory = sqlite3.Row
        self.thumb_root = os.path.join(config.load()["redkit"], "r4data", "thumbnails")
        self._textures = None
        self._rows = self._items = self._loot = None

    def _merge_packs(self):
        """The content packs in the game (content.py: a mod with Conjunction's card) join the catalog from their table
        of contents - placed, searched and given like the game's things, their source the pack's name. -> the packs."""
        from . import content
        try:
            packs = content.installed_packs()
        except OSError:
            return []
        cols = ("path", "name", "named", "kind", "class", "source", "quest", "inventory", "loot", "components",
                "appearances", "meshes", "tags", "grp", "thumb", "cat", "sub", "styles", "traits", "loot_defs")
        icols = ("name", "label", "descr", "category", "tags", "price", "weight", "icon", "equip_template",
                 "stackable", "file", "cat", "sub")
        for p in packs:
            idx = content.pack_index(p)
            for r in idx.get("templates") or []:
                r = dict(r, source=p.get("name") or p["id"], traits=" ".join(
                    sorted(set(str(r.get("traits") or "").split()) | {"pack"})))
                self.db.execute(f"insert or replace into templates values ({','.join('?' * len(cols))})",
                                [r.get(c, "") for c in cols])
                self.db.execute("delete from template_search where path = ?", (r["path"],))
                self.db.execute("insert into template_search values (?,?,?)", (
                    r["path"], r.get("name", ""), " ".join([r.get("cat", ""), r.get("sub", ""), r.get("kind", ""),
                                                           r.get("class", ""), r.get("tags", ""), r["source"],
                                                           r["path"].replace("\\", " ").replace("_", " ")])))
            for r in idx.get("items") or []:
                r = dict(r, label=r.get("label") or r.get("name"))
                self.db.execute(f"insert or replace into items values ({','.join('?' * len(icols))})",
                                [r.get(c, "") for c in icols])
                self.db.execute("delete from item_search where name = ?", (r["name"],))
                self.db.execute("insert into item_search values (?,?,?)", (
                    r["name"], r["label"], " ".join([r["name"], r.get("cat", ""), r.get("sub", ""),
                                                    str(r.get("category", "")).replace("_", " "),
                                                    str(r.get("tags", "")), p.get("name") or p["id"]])))
        return packs

    @staticmethod
    def ready():
        import sqlite3
        if not os.path.exists(DB):
            return False
        try:
            v = sqlite3.connect(DB).execute("select value from meta where key='version'").fetchone()
            return bool(v) and int(v[0]) == VERSION
        except sqlite3.Error:
            return False

    # --- browsing: the rows in memory (20 000, a few MB), filtered and counted per keystroke in a few ms
    def _all(self):
        if self._rows is None:
            self._rows = []
            for r in self.db.execute("select * from templates"):
                r = dict(r)
                r["styles"] = [x.replace("_", " ") for x in (r["styles"] or "").split()]
                r["traits"] = (r["traits"] or "").split()
                if r.get("sub") == "Trees & plants":    # (a database built before 04.10.: the trees have a group of
                    r["sub"] = "Plants & logs"          # their own now - the foliage library's)
                if r.get("class") in CLUE_CLASSES:      # glows red in the witcher senses (examined by itself)
                    r["traits"].append("clue")
                if "CR4InteriorAreaComponent" in (r.get("components") or ""):
                    r["traits"].append("interior")      # a room with its own inside: no rain, the map knows it
                self._rows.append(r)
            self._rows += self._mesh_rows()
        return self._rows

    def _mesh_rows(self):
        """The mesh library's rows - kept in a file beside the database (02.10.: sorting 12 000 meshes into the tree
        took 3 of the catalog's 4 seconds, at every start); made anew when the library, the database or the sorting
        rules changed."""
        import pickle

        from . import catalog, foliage, meshlib, taxonomy
        here = os.path.dirname(os.path.abspath(__file__))

        def stamp(f):
            try:
                return os.path.getmtime(f)
            except OSError:
                return 0
        key = [stamp(f) for f in (meshlib.INDEX, meshlib.DECAL_INDEX, foliage.INDEX, DB,
                                  os.path.join(here, "taxonomy.py"),
                                  os.path.join(here, "catalog.py"), os.path.join(here, "foliage.py"),
                                  os.path.abspath(__file__))]
        cache = os.path.join(os.path.dirname(DB), "mesh_rows.pickle")
        try:
            with open(cache, "rb") as f:
                kept = pickle.load(f)
            if kept.get("key") == key:
                return kept["rows"]
        except (OSError, pickle.PickleError, EOFError, AttributeError, KeyError):
            pass
        rows = self._mesh_rows_made(catalog, meshlib, taxonomy)
        try:
            with open(cache + ".tmp", "wb") as f:
                pickle.dump({"key": key, "rows": rows}, f, protocol=pickle.HIGHEST_PROTOCOL)
            os.replace(cache + ".tmp", cache)
        except OSError:
            pass
        return rows

    def _mesh_rows_made(self, catalog, meshlib, taxonomy):
        """The mesh library (walls, roofs, ruins - most of the world exists only as meshes) as rows like templates:
        sorted into the same tree, found by the same search (its words are matched here, not by the index)."""
        import json
        textured = dict(self.db.execute("select path, textured from mesh_info"))
        out = []
        for mesh, tpl in meshlib.index().items():
            kind = catalog.kind_of(mesh)
            cat, sub = taxonomy.classify(mesh, "", (), kind, "", [mesh])
            if not textured.get(mesh, 1):
                cat, sub = "Internal", "Internal"      # no texture at all: a technical helper
            styles = taxonomy.styles(mesh)
            name = catalog.caption(mesh)
            traits = ["quest"] if "\\quest" in "\\" + mesh else []
            out.append({"path": tpl.lower(), "mesh": mesh, "name": name, "named": 0, "kind": kind,
                        "class": "mesh", "source": "Mesh library", "quest": int(bool(traits)), "inventory": 0,
                        "loot": "[]", "components": "[]", "appearances": "[]", "meshes": json.dumps([mesh]),
                        "tags": "", "grp": catalog.group_of(mesh), "thumb": 1, "cat": cat, "sub": sub,
                        "styles": styles, "traits": traits,
                        "words": " " + " ".join(sorted(taxonomy._words(" ".join([mesh, cat, sub] + styles)))) +
                                 " " + " ".join(w.lower() for w in (cat + " " + sub).split())})
        for tex, tpl in meshlib.decal_index().items():      # the game's decal pictures (blood, posters, signs)
            name = catalog.caption(tex) + " (decal)"
            out.append({"path": tpl.lower(), "decal": tex, "name": name, "named": 0, "kind": "Decoration",
                        "class": "decal", "source": "Mesh library", "quest": int("\\quest" in "\\" + tex),
                        "inventory": 0, "loot": "[]", "components": json.dumps(["CDecalComponent"]),
                        "appearances": "[]", "meshes": "[]", "tags": "decal", "grp": catalog.group_of(tex), "thumb": 1,
                        "cat": "Decoration", "sub": "Decals", "styles": [], "traits": [],
                        "words": " " + " ".join(sorted(taxonomy._words(" ".join([tex, "decal decoration decals"]))))})
        from . import foliage
        for tree, tpl in foliage.index().items():           # the game's trees, bushes, flowers (foliage.py)
            cat, sub = "Nature", foliage.group(tree)      # (own groups: not mixed with logs and fences)
            name = catalog.caption(tree)
            out.append({"path": tpl.lower(), "tree": tree, "name": name, "named": 0, "kind": "Plant",
                        "class": "foliage", "source": "Foliage library", "quest": 0, "inventory": 0, "loot": "[]",
                        "components": json.dumps(["CDynamicFoliageComponent"]), "appearances": "[]",
                        "meshes": "[]", "tags": "foliage", "grp": catalog.group_of(tree), "thumb": 1,
                        "cat": cat, "sub": sub, "styles": [], "traits": [],
                        "words": " " + " ".join(sorted(taxonomy._words(" ".join([tree, cat, sub, "foliage tree"]))))
                                 + " " + " ".join(w.lower() for w in (cat + " " + sub).split())})
        return out

    def _scores(self, table, key, text):
        q = _fts(text)
        if not q:
            return None
        sql = f"select {key}, bm25({table}, 0, 8, 1) from {table} where {table} match ?"
        return {k: sc for k, sc in self.db.execute(sql, (q,))}

    def browse(self, text="", cat=None, sub=None, styles=(), traits=(), quest=False, limit=400):
        """Templates for the catalog: (rows, facets). Filters: the type tree (cat / sub), styles (any of them),
        traits (all of them), quest things only with `quest`. Facets count what each choice would give with the
        other filters kept: {"tree": {(cat, sub): n}, "styles": {s: n}, "traits": {t: n}, "total": n}."""
        from collections import Counter

        from .taxonomy import HIDDEN_GROUPS
        scores = self._scores("template_search", "path", text)
        styles, traits = set(styles), set(traits)
        tree, sty, tra = Counter(), Counter(), Counter()
        out = []
        words = [w for w in re.findall(r"\w+", text.lower())]
        for r in self._all():
            if scores is not None:
                if "words" in r:            # a library mesh: every word must start one of its words
                    if not all(" " + w in r["words"] for w in words):
                        continue
                    scores[r["path"]] = -2.0 * sum(" " + w in " " + r["name"].lower() for w in words)
                elif r["path"] not in scores:
                    continue
            if r["quest"] and not quest:
                continue
            in_tree = (not cat or r["cat"] == cat) and (not sub or r["sub"] == sub) and \
                (cat or r["cat"] not in HIDDEN_GROUPS)
            in_styles = not styles or bool(styles.intersection(r["styles"]))
            in_traits = traits.issubset(r["traits"])
            if in_styles and in_traits:
                tree[(r["cat"], r["sub"])] += 1
            if in_tree and in_traits:
                sty.update(r["styles"])
            if in_tree and in_styles:
                tra.update(r["traits"])
            if in_tree and in_styles and in_traits:
                out.append(r)
        if scores is not None:
            # real names first, then relevance
            out.sort(key=lambda r: scores[r["path"]] + (0 if r["named"] else 2))
        else:
            out.sort(key=lambda r: (not r["named"], not r["thumb"], r["name"].lower()))
        return out[:limit], {"tree": tree, "styles": sty, "traits": tra, "total": len(out)}

    def browse_items(self, text="", cat=None, sub=None, limit=400):
        """Items for the catalog: (rows, facets) like browse; internal ones (heads, hair) only when asked for."""
        from collections import Counter
        if self._items is None:
            self._items = [dict(r) for r in self.db.execute("select * from items order by label")]
        scores = self._scores("item_search", "name", text)
        tree, out = Counter(), []
        for r in self._items:
            if scores is not None and r["name"] not in scores:
                continue
            if r["cat"] == "Internal" and cat != "Internal":
                continue
            tree[(r["cat"], r["sub"])] += 1
            if (not cat or r["cat"] == cat) and (not sub or r["sub"] == sub):
                out.append(r)
        if scores is not None:
            out.sort(key=lambda r: scores[r["name"]])
        return out[:limit], {"tree": tree, "styles": Counter(), "traits": Counter(), "total": len(out)}

    def loot_tables(self, text="", limit=200):
        """Loot definitions whose name or items match every word (their items' names count too)."""
        import json
        words = [w for w in re.findall(r"\w+", text.lower())]
        if self._loot is None:
            labels = {r[0]: (r[1] or "").lower() for r in self.db.execute("select name, label from items")}
            self._loot = []
            for n, e, f in self.db.execute("select name, entries, file from loot order by name"):
                entries = json.loads(e)
                hay = " ".join([n.lower().replace("_", " ")] + [x[0].lower() + " " + labels.get(x[0], "")
                                                                for x in entries])
                self._loot.append({"name": n, "entries": entries, "file": f, "hay": hay})
        return [r for r in self._loot if all(w in r["hay"] for w in words)][:limit]

    def loot(self, name):
        import json
        r = self.db.execute("select entries, file from loot where name = ?", (name,)).fetchone()
        return {"name": name, "entries": json.loads(r[0]), "file": r[1]} if r else None

    def items(self, text="", limit=400):
        q = _fts(text)
        if q:
            sql = ("select i.* from item_search s join items i on i.name = s.name where item_search match ? and "
                   "i.cat != 'Internal' order by bm25(item_search, 0, 8, 1) limit ?")
            rows = self.db.execute(sql, [q, limit]).fetchall()
        else:
            rows = self.db.execute("select * from items where cat != 'Internal' order by label limit ?",
                                   (limit,)).fetchall()
        return [dict(r) for r in rows]

    def template(self, path):
        r = self.db.execute("select * from templates where path = ?", (path.lower(),)).fetchone()
        return dict(r) if r else None

    def item(self, name):
        r = self.db.execute("select * from items where name = ?", (name,)).fetchone()
        return dict(r) if r else None

    # --- pictures (cut out on first use, cached as PNG)
    def _redkit_picture(self, path, size):
        """REDkit's picture of a template or mesh as a PIL image at `size` px, or None."""
        src = os.path.join(self.thumb_root, os.path.splitext(path)[0] + ".thmb")
        if not os.path.exists(src):
            return None
        data = open(src, "rb").read()
        i = data.find(b"\x89PNG")
        if i < 0:
            return None
        from io import BytesIO

        from PIL import Image
        im = Image.open(BytesIO(data[i:])).convert("RGBA")
        return im.resize((size, size), Image.LANCZOS) if size < im.width else im

    @staticmethod
    def _blank(im):
        """REDkit rendered nothing (a template whose meshes stream in later): almost all of it is the sky colour."""
        px = im.convert("RGB").resize((32, 32)).getdata()
        sky = px[2 * 32 + 2]
        return sum(1 for p in px if abs(p[0] - sky[0]) + abs(p[1] - sky[1]) + abs(p[2] - sky[2]) < 30) > 0.9 * 1024

    def thumbnail(self, path, size=128, meshes=None):
        """PNG file of a template's picture at `size` px, or None. REDkit's picture of a template is often empty -
        then the first of its meshes with a real picture stands in (cached as the template's)."""
        out = os.path.join(THUMBS, str(size), os.path.splitext(path.lower())[0] + ".png")
        if os.path.exists(out):
            return out
        from . import meshlib
        tex = meshlib.decal_reverse_index().get(path.lower())
        if tex:                                         # a decal of the library: its picture
            return self._texture_picture(tex, size, out)
        if getattr(self, "_trees", None) is None:
            from . import foliage
            self._trees = foliage.reverse_index()
        tree = self._trees.get(path.lower())
        # a tree of the foliage library: REDkit's picture of the tree (its wrapper entity has none)
        im = self._redkit_picture(tree or path, size)
        if (im is None or self._blank(im)) and path.lower().endswith(".w2ent"):
            if meshes is None:
                import json
                r = self.template(path)
                meshes = json.loads(r["meshes"] or "[]") if r else []
            for m in meshes[:6]:
                alt = self._redkit_picture(m, size)
                if alt is not None and not self._blank(alt):
                    im = alt
                    break
        if im is None:
            return None
        os.makedirs(os.path.dirname(out), exist_ok=True)
        im.save(out)
        return out

    def _texture_picture(self, texture, size, out):
        """A texture of the game (its texture cache) as a picture file of `size` px, or None."""
        if self._textures is None:
            from .textures import TextureCache
            self._textures = TextureCache()
        try:
            im = self._textures.image(texture, max_side=size * 2)
        except Exception:                               # noqa: BLE001 - an odd format: no picture
            im = None
        if im is None:
            return None
        im = im.convert("RGBA")
        im.thumbnail((size, size))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        im.save(out)
        return out

    def icon(self, item):
        """PNG file of an item's inventory icon (game texture cache), or None."""
        it = self.item(item) if isinstance(item, str) else item
        if not it or not it.get("icon"):
            return None
        out = os.path.join(THUMBS, "icons", it["icon"].replace("/", os.sep))
        if os.path.exists(out):
            return out
        if self._textures is None:
            from .textures import TextureCache
            self._textures = TextureCache()
        im = self._textures.icon(it["icon"])
        if im is None:
            return None
        os.makedirs(os.path.dirname(out), exist_ok=True)
        im.save(out)
        return out


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "build"
    if cmd == "build":
        build()
    elif cmd == "show":
        a = Assets()
        for p in sys.argv[2:]:
            print(a.template(p) or a.item(p))
    elif cmd == "probe":
        from .bundles import Depot
        d = Depot()
        for p in sys.argv[2:]:
            info = read_template(d.read(p))
            print(p)
            for k in ("class", "name_id", "appearances", "inventory", "loot", "components"):
                print(f"   {k}: {info[k]}")
            print(f"   meshes: {len(info['meshes'])}, includes: {len(info['includes'])}")


if __name__ == "__main__":
    main()
