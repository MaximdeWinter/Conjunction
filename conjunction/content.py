"""Where each thing a quest uses comes from, and which content packs are in the game - Conjunction as an ecosystem
(Maxim, 02.10.): someone imports 300 items and pieces of furniture as a content pack; a quest that uses some of them
names that pack in its manifest (version, where to get it, exactly which things); a player who drops the quest in
without the pack is told what is missing and from which pack.

The origin of a reference (a template's depot path, an item's name, a loot table's name):
    "game"            the game itself (<game>\\content - the remaster carries both expansions there)
    "suite"           Conjunction's own DLC (the mesh library) - every install has it
    "own"             the quest's own DLC
    "pack:<id>"       a content pack: a DLC or mod folder with a marker file (conjunction_pack.yml), or a mod made without
                      Conjunction that someone registered as a pack (a card: pack.yml with `detect`)
    "mod:<dlc|mods>/<folder>"  a mod folder Conjunction knows no pack for
    None              found nowhere on this machine

A pack in the game (installed from a .w3p by the library, or by hand / a mod manager from Nexus):
    <game>\\dlc\\<folder>\\conjunction_pack.yml      id, name, author, version, url, description, kinds
    <game>\\dlc\\<folder>\\conjunction_index.json    the templates and items it brings (made when the pack was made)
    (or <game>\\Mods\\<folder>\\...)

    o = Origins()                      every bundle of the game read once (cached by size and time in origins.json)
    o.template("dlc\\furn\\chair.w2ent") -> "pack:medieval_furniture"
    needs(project, o)                  -> what the quest uses that is not the game's: packs with the things used, mods
"""
import glob
import json
import os
import re

import yaml

from . import config

MARKER = "conjunction_pack.yml"
INDEX = "conjunction_index.json"
QUEST_MARKER = "conjunction_quest.yml"          # a quest the library installed (its manifest)
CACHE = os.path.join(os.path.dirname(config.PATH), "origins.json")
SUITE_DLCS = {"dlcconjunctionmeshes"}
ITEM_XML = re.compile(r"(^|\\)gameplay\\items[^\\]*\\[^\\]*\.xml$")
CACHE_VERSION = 2                           # 2: xml.bundle of the remaster read right (bundles._entry_size)
KIND = {"templates": "template", "items": "item", "loot": "loot table"}
# the game's own depot paths (base game, expansions, free DLCs) - everything else under dlc\ is a mod's
VANILLA_FILE = re.compile(r"^(?!dlc\\)|^dlc\\(ep1|bob|dlc\d+)\\")       # (the remaster: ep1, bob, dlc1 .. dlc20)


def _game(game=None):
    return game or config.load().get("game", "")


def folders(game=None):
    """(kind, name, path) of every place the game loads content from: the game itself, each DLC, each mod."""
    game = _game(game)
    out = [("game", "", os.path.join(game, "content"))]
    for kind, sub in (("dlc", "dlc"), ("mods", "Mods")):
        root = os.path.join(game, sub)
        if os.path.isdir(root):
            out += [(kind, n, os.path.join(root, n)) for n in sorted(os.listdir(root))
                    if os.path.isdir(os.path.join(root, n))]
    return out


def bundles_in(path):
    return sorted(glob.glob(os.path.join(path, "**", "*.bundle"), recursive=True))


def _item_names(text):
    """Item and loot table names an item definition file declares."""
    items = re.findall(r"<item\s[^>]*?\bname\s*=\s*\"([^\"]+)\"", text)
    loot = re.findall(r"<loot\s[^>]*?\bname\s*=\s*\"([^\"]+)\"", text)
    return items, loot


def read_bundle(path):
    """{"w2ent": [...], "items": [...], "loot": [...]} of one bundle."""
    from .bundles import entries, read
    out = {"w2ent": [], "items": [], "loot": []}
    for e in entries(path):
        p = e[0].lower()
        if p.endswith(".w2ent"):
            out["w2ent"].append(p)
        elif ITEM_XML.search(p):
            try:
                raw = read(path, e)
            except Exception:                       # noqa: BLE001 - an unreadable entry is no item file
                continue
            text = raw.decode("utf-16", "replace") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else \
                raw.decode("utf-8-sig", "replace")
            items, loot = _item_names(re.sub(r"<!--.*?-->", "", text, flags=re.S))
            out["items"] += items
            out["loot"] += loot
    return out


def _stamp(path):
    st = os.stat(path)
    return [st.st_size, int(st.st_mtime)]


class Origins:
    """Which folder of the game brings each template, item and loot table (the game's own first: a quest needs
    nothing else for what the game has, even when a mod changes it)."""

    def __init__(self, game=None, log=None):
        self.game = _game(game)
        try:
            cache = json.load(open(CACHE, encoding="utf-8"))
            if cache.get("version") != CACHE_VERSION:
                cache = {}
        except (OSError, ValueError):
            cache = {}
        old = cache.get("bundles", {})
        new = {}
        self.templates, self.items, self.loot = {}, {}, {}
        self.folder_paths = {}
        for kind, name, path in folders(self.game):
            key = "game" if kind == "game" else f"{kind}/{name}"
            self.folder_paths[key] = path
            for b in bundles_in(path):
                stamp = _stamp(b)
                known = old.get(b)
                if known and known.get("stamp") == stamp:
                    data = known
                else:
                    if log:
                        log(f"[content] reading {os.path.relpath(b, self.game)}")
                    try:
                        data = dict(read_bundle(b), stamp=stamp)
                    except (OSError, ValueError) as ex:
                        if log:
                            log(f"[content] {b}: {ex}")
                        continue
                new[b] = data
                for p in data["w2ent"]:
                    self.templates.setdefault(p, key)
                for n in data["items"]:
                    self.items.setdefault(n, key)
                for n in data["loot"]:
                    self.loot.setdefault(n, key)
        self._game_items_from_assets()
        if new != old:
            try:
                os.makedirs(os.path.dirname(CACHE), exist_ok=True)
                tmp = CACHE + ".tmp"
                json.dump({"version": CACHE_VERSION, "bundles": new}, open(tmp, "w", encoding="utf-8"))
                os.replace(tmp, CACHE)
            except OSError:
                pass
        self.packs = installed_packs(self.game)
        self.pack_of_folder = {}
        for p in self.packs:
            for f in p.get("folders", []):
                self.pack_of_folder[f] = p["id"]

    def _game_items_from_assets(self):
        """The remaster keeps most of its item definitions outside the bundles - the asset database (read from the
        game) knows them: those defined by the game's own files count as the game's."""
        import sqlite3

        from .assets import DB
        if not os.path.exists(DB):
            return
        try:
            db = sqlite3.connect(DB)
            rows = db.execute("select name, file from items").fetchall()
            loot = db.execute("select name, file from loot").fetchall()
            db.close()
        except sqlite3.Error:
            return
        for table, rs in ((self.items, rows), (self.loot, loot)):
            for name, f in rs:
                if VANILLA_FILE.match(str(f).lower()):
                    table.setdefault(name, "game")

    def _origin(self, folder):
        if folder is None:
            return None
        if folder == "game":
            return "game"
        if folder.split("/", 1)[1].lower() in SUITE_DLCS:
            return "suite"
        if folder in self.pack_of_folder:
            return "pack:" + self.pack_of_folder[folder]
        return "mod:" + folder

    def template(self, path):
        return self._origin(self.templates.get(str(path).lower()))

    def item(self, name):
        return self._origin(self.items.get(str(name)))

    def loot_table(self, name):
        return self._origin(self.loot.get(str(name)))

    def pack(self, pid):
        return next((p for p in self.packs if p["id"] == pid), None)


# --- packs in the game
def read_pack_meta(path):
    meta = yaml.safe_load(open(path, encoding="utf-8")) or {}
    meta["id"] = str(meta.get("id") or "").strip().lower()
    return meta


def installed_packs(game=None):
    """Every content pack this game has: marker files in its DLC and mod folders, and registered mods (cards in the
    pack folders) whose files are there. Each: {id, name, author, version, url, kinds, folders: ["dlc/x"], index}."""
    game = _game(game)
    out, seen = [], set()
    for kind, name, path in folders(game):
        if kind == "game":
            continue
        marker = os.path.join(path, MARKER)
        if not os.path.isfile(marker):
            continue
        try:
            meta = read_pack_meta(marker)
        except (OSError, yaml.YAMLError):
            continue
        if not meta["id"]:
            continue
        key = f"{kind}/{name}"
        if meta["id"] in seen:                      # one pack over several folders (a DLC and a mod part)
            p = next(p for p in out if p["id"] == meta["id"])
            p["folders"].append(key)
            continue
        seen.add(meta["id"])
        out.append(dict(meta, folders=[key], index=os.path.join(path, INDEX)))
    for card in pack_cards():
        if card["id"] in seen or not detected(card, game):
            continue
        seen.add(card["id"])
        out.append(dict(card, folders=[_folder_key(d) for d in card.get("detect", []) if _folder_key(d)]))
    return out


def _folder_key(rel):
    """'dlc/dlcfurniture/content/blob0.bundle' -> 'dlc/dlcfurniture'."""
    parts = re.split(r"[\\/]+", str(rel).strip("\\/"))
    if len(parts) >= 2 and parts[0].lower() in ("dlc", "mods"):
        return f"{parts[0].lower()}/{parts[1]}"
    return None


def detected(card, game=None):
    """A registered mod is there when all its detect paths (relative to the game folder) exist."""
    game = _game(game)
    paths = card.get("detect") or []
    return bool(paths) and all(os.path.exists(os.path.join(game, *re.split(r"[\\/]+", p))) for p in paths)


def card_dirs():
    from .contentpacks import pack_dirs
    return pack_dirs()


def pack_cards():
    """Registered mods: <pack folder>\\<id>.pack.yml with `detect` (and the index beside it: <id>.index.json)."""
    out = []
    for d in card_dirs():
        for f in sorted(os.listdir(d)):
            if not f.endswith(".pack.yml"):
                continue
            try:
                meta = read_pack_meta(os.path.join(d, f))
            except (OSError, yaml.YAMLError):
                continue
            if meta["id"]:
                out.append(dict(meta, index=os.path.join(d, f[:-len(".pack.yml")] + ".index.json")))
    return out


def pack_index(pack):
    """{"templates": [row], "items": [row]} of an installed pack (empty when it has none)."""
    try:
        return json.load(open(pack.get("index") or "", encoding="utf-8"))
    except (OSError, ValueError):
        return {"templates": [], "items": []}


# --- what a quest uses
def refs(project):
    """{"templates": {path: [where]}, "items": {name: [where]}, "loot": {name: [where]}} - every thing of the game
    (or of a pack) the project names: its places' objects (template, inventory, loot table) and its quest (any
    template, item and loot table in its steps, talks and rewards). `where`: "place/id" or "quest"."""
    out = {"templates": {}, "items": {}, "loot": {}}

    def add(kind, value, where):
        if isinstance(value, str) and value and not value.startswith("own:"):
            out[kind].setdefault(value if kind != "templates" else value.lower(), []).append(where)

    def walk(x, where):
        if isinstance(x, dict):
            for k, v in x.items():
                if isinstance(v, str) and v.lower().endswith(".w2ent"):
                    add("templates", v, where)
                elif k in ("item", "hold"):             # (hold: a thing in a speaker's hand)
                    add("items", v, where)
                elif k == "items" and isinstance(v, list):
                    for i in v:
                        if isinstance(i, dict):
                            walk(i, where)
                        else:
                            add("items", i, where)
                elif k in ("loot", "loot_table") and isinstance(v, str):
                    add("loot", v, where)
                else:
                    walk(v, where)
        elif isinstance(x, list):
            for v in x:
                walk(v, where)
    for pname, place in project.places.items():
        for o in place.get("objects", []):
            where = f"{pname}/{o.get('id', '?')}"
            walk(o, where)
    q = dict(project.meta.get("quest") or {})
    q.pop("items", None)                        # the quest's own items (in its DLC)
    walk(q, "quest")
    return out


def needs(project, origins=None, labels=None):
    """What the quest uses that the game does not have -> {"packs": {id: {id, name, author, version, url, detect,
    used: [{ref, kind, name}]}}, "mods": {folder: [ref]}, "missing": [ref]} - `missing`: found nowhere here.
    `labels(kind, ref)` gives a thing's readable name (the catalog's)."""
    o = origins or Origins(project_game(project))
    r = refs(project)
    out = {"packs": {}, "mods": {}, "missing": []}
    get = {"templates": o.template, "items": o.item, "loot": o.loot_table}
    for kind, things in r.items():
        for ref in sorted(things):
            origin = get[kind](ref)
            if origin in ("game", "suite", "own"):
                continue
            if origin is None:
                if kind == "templates" and _own_template(project, ref):
                    continue
                out["missing"].append(ref)
            elif origin.startswith("pack:"):
                pid = origin[5:]
                p = o.pack(pid) or {"id": pid}
                entry = out["packs"].setdefault(pid, {
                    "id": pid, "name": p.get("name", pid), "author": p.get("author", ""),
                    "version": str(p.get("version", "1")), "url": p.get("url", ""),
                    "detect": list(p.get("detect") or []) or [f"{f}/{MARKER}" for f in p.get("folders", [])],
                    "used": []})
                entry["used"].append({"ref": ref, "kind": KIND[kind],
                                      "name": (labels(kind, ref) if labels else None) or _short(ref)})
            else:
                out["mods"].setdefault(origin[4:], []).append((kind, ref))
    return out


KNOWN = os.path.join(os.path.dirname(config.PATH), "known_mods.json")


def known_mods():
    """What the author told this Conjunction about mods without a marker: {"dlc/dlcfoo": {name, version, url}}."""
    try:
        return json.load(open(KNOWN, encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def remember_mod(folder, name="", version="", url=""):
    k = known_mods()
    k[folder] = {"name": name.strip(), "version": str(version).strip(), "url": url.strip()}
    os.makedirs(os.path.dirname(KNOWN), exist_ok=True)
    tmp = KNOWN + ".tmp"
    json.dump(k, open(tmp, "w", encoding="utf-8"), indent=1)
    os.replace(tmp, KNOWN)


def mod_entry(folder, things, labels=None):
    """A mod without a marker as a manifest pack: known by its folder (dlc/<x> or mods/<x>)."""
    k = known_mods().get(folder, {})
    kind, name = folder.split("/", 1)
    return {"id": "mod-" + re.sub(r"[^a-z0-9_]+", "_", name.lower()), "name": k.get("name") or name,
            "author": "", "version": k.get("version", ""), "url": k.get("url", ""),
            "detect": [("dlc/" if kind == "dlc" else "Mods/") + name], "folder": folder,
            "used": [{"ref": r, "kind": KIND[kd], "name": (labels(kd, r) if labels else None) or _short(r)}
                     for kd, r in things]}


def manifest_packs(project, origins=None, labels=None):
    """The manifest's `packs` (every mod the quest takes something from: packs and plain mods) and what was found
    nowhere on the author's machine."""
    n = needs(project, origins, labels)
    packs = list(n["packs"].values())
    packs += [mod_entry(folder, things, labels) for folder, things in sorted(n["mods"].items())]
    return packs, n["missing"]


def labeler(assets=None):
    """labels(kind, ref): the catalog's name of a template / item (None when the database is not there). `assets`:
    the editor's database (else one is opened)."""
    a = assets
    if a is None:
        try:
            from .assets import Assets
            a = Assets() if Assets.ready() else None
        except Exception:                           # noqa: BLE001
            a = None
    pack_names = {}
    for p in installed_packs():
        idx = pack_index(p)
        for r in idx.get("templates", []):
            pack_names[("templates", r.get("path", "").lower())] = r.get("name")
        for r in idx.get("items", []):
            pack_names[("items", r.get("name"))] = r.get("label")

    def labels(kind, ref):
        if (kind, ref) in pack_names:
            return pack_names[(kind, ref)]
        if a is None:
            return None
        if kind == "templates":
            t = a.template(ref)
            return t and t.get("name")
        if kind == "items":
            it = a.item(ref)
            return it and (it.get("label") or it.get("name"))
        return None
    return labels


def _own_template(project, ref):
    """A template the quest makes itself (its DLC: dlc\\<id>\\...)."""
    return ref.lower().startswith(f"dlc\\{project.id.lower()}\\") or ref.lower().startswith("dlc\\dlc" +
                                                                                            project.id.lower())


def _short(ref):
    base = os.path.splitext(re.split(r"[\\/]", ref)[-1])[0]
    return base.replace("_", " ")


def project_game(project):
    return _game()


# --- checking a quest's needs on a player's machine
def _ver(v):
    return tuple(int(x) if x.isdigit() else 0 for x in str(v).split("."))


def missing_packs(manifest, game=None):
    """The packs of a quest's manifest this game lacks -> [{id, name, version, url, used, why}] (why: "missing" or
    "old: <installed version>")."""
    game = _game(game)
    have = {p["id"]: p for p in installed_packs(game)}
    from . import contentpacks
    for p in contentpacks.packs():                  # folder packs (voices, Conjunction's samples)
        have.setdefault(p.id, {"id": p.id, "name": p.name, "version": p.version})
    out = []
    for need in manifest.get("packs") or []:
        pid = str(need.get("id", "")).lower()
        p = have.get(pid)
        if p is None and need.get("detect") and detected(need, game):
            p = {"id": pid, "version": need.get("version", "0")}        # a registered mod's files are there
        if p is None:
            out.append(dict(need, why="missing"))
        elif _ver(p.get("version", "0")) < _ver(need.get("version", "0")):
            out.append(dict(need, why=f"old: {p.get('version')}"))
    return out
