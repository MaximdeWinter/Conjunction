"""Make a mod a content pack (Maxim, 02.10.): a creator of furniture, items or people points Conjunction at their mod
folder; Conjunction shows what it found and what keeps it from working seamlessly with quests made by others, and with
one click writes the pack card (conjunction_pack.yml) and the table of contents (conjunction_index.json) into the mod. The mod
is uploaded as always (Nexus); a quest that uses something of it names it, a player without it is told.

    r = inspect(folder)          what is in it: r.templates, r.items, r.meshes, r.checks
    write(folder, meta, r)       the card and the table of contents into the folder

    python -m conjunction.packmaker <folder>            the report
    python -m conjunction.packmaker <folder> --write id=my_pack name="My pack" version=1.0 url=...

A check: (level, key, text, things) - level "ok", "fix" (Conjunction does it: the card, the contents), "warn" (works,
but others will trip over it), "info". Things: the names concerned.
"""
import json
import os
import re
import sys

import yaml

from . import content

KINDS = ("furniture", "items", "people", "creatures", "voices", "other")


class Report:
    def __init__(self, folder):
        self.folder = folder
        self.templates = []         # catalog rows (as the asset database's)
        self.items = []             # item rows
        self.meshes = []            # meshes no template of the pack uses
        self.replaces = []          # files that also exist in the game (the mod changes the game's)
        self.voices = 0
        self.meta = {}
        self.checks = []

    def counts(self):
        out = {}
        for r in self.templates:
            out[r["cat"] or "Other"] = out.get(r["cat"] or "Other", 0) + 1
        return out


def _strings(folder):
    """id -> text and key hash -> id of the mod's own English strings."""
    from . import w3strings
    by_id, by_key = {}, {}
    for root, _d, files in os.walk(folder):
        for f in files:
            if f.lower() == "en.w3strings":
                try:
                    _v, _l, texts, keys = w3strings.read(open(os.path.join(root, f), "rb").read(), "en")
                except (OSError, ValueError, KeyError, IndexError):
                    continue
                by_id.update(texts)
                for sid, h in keys.items():
                    by_key[h] = sid
    return by_id, by_key


def _item_rows(text, path, by_id, by_key, game_text=None):
    from .assets import _attrs, java_hash
    from .taxonomy import classify_item
    out = []
    for m in re.finditer(r"<item\s([^>]*?)(/>|>(.*?)</item>)", re.sub(r"<!--.*?-->", "", text, flags=re.S), re.S):
        a = _attrs(m.group(1))
        if not a.get("name"):
            continue
        tags = []
        t = re.search(r"<tags>(.*?)</tags>", m.group(3) or "", re.S)
        if t:
            tags = [x.strip() for x in t.group(1).split(",") if x.strip()]

        def text_of(key):
            sid = by_key.get(java_hash(key.lower())) if key else None     # (keys are hashed lower case)
            if sid is not None and sid in by_id:
                return by_id[sid]
            return (game_text or {}).get(key, "") if key else ""
        label = text_of(a.get("localisation_key_name", ""))
        cat, sub = classify_item(a.get("category", ""), tags)
        out.append({"name": a["name"], "label": label, "descr": text_of(a.get("localisation_key_description", "")),
                    "category": a.get("category", ""), "tags": " ".join(tags),
                    "price": float(a.get("price") or 0), "weight": float(a.get("weight") or 0),
                    "icon": a.get("icon_path", ""), "equip_template": a.get("equip_template", ""),
                    "stackable": a.get("stackable", ""), "file": path, "cat": cat, "sub": sub})
    return out


def _template_row(path, info, by_id, source):
    from . import catalog, taxonomy
    from .assets import kind_and_tags
    info = info or {}
    kind, tags = kind_and_tags(path, info)
    real = by_id.get(info.get("name_id") or -1, "")
    cls, comps = info.get("class", ""), info.get("components", [])
    cat, sub = taxonomy.classify(path, cls, comps, kind, real, info.get("meshes", []))
    if "CDecalComponent" in comps and not info.get("meshes"):
        cat, sub = "Decoration", "Decals"            # a picture painted onto the world
    traits = taxonomy.traits(path, cls, comps, info.get("inventory"), info.get("loot"), bool(real))
    return {"path": path, "name": real or catalog.caption(path), "named": int(bool(real)), "kind": kind, "class": cls,
            "source": source, "quest": 0, "inventory": int(bool(info.get("inventory"))),
            "loot": json.dumps(info.get("loot", [])), "components": json.dumps(comps),
            "appearances": json.dumps(info.get("appearances", [])), "meshes": json.dumps(info.get("meshes", [])[:40]),
            "tags": " ".join(tags), "grp": catalog.group_of(path), "thumb": 0, "cat": cat, "sub": sub,
            "styles": " ".join(s.replace(" ", "_") for s in taxonomy.styles(path, real)), "traits": " ".join(traits),
            "loot_defs": json.dumps(info.get("loot_defs", []))}


def _game_paths():
    """Depot paths of the game's own templates and meshes, and its item names - what a mod would replace."""
    try:
        o = content.Origins()
        game_tpl = {p for p, f in o.templates.items() if f == "game"}
        game_items = {n for n, f in o.items.items() if f == "game"}
        return game_tpl, game_items
    except OSError:
        return set(), set()


def inspect(folder, log=None):
    """What a mod folder brings and what it needs to work with everyone's quests."""
    from .assets import read_template
    from .bundles import entries, read
    r = Report(folder)
    marker = os.path.join(folder, content.MARKER)
    if os.path.isfile(marker):
        try:
            r.meta = content.read_pack_meta(marker)
        except (OSError, yaml.YAMLError):
            r.meta = {}
    by_id, by_key = _strings(folder)
    source = r.meta.get("name") or os.path.basename(folder.rstrip("\\/"))
    files = {}
    for b in content.bundles_in(folder):
        for e in entries(b):
            files.setdefault(e[0].lower(), (b, e))
    game_tpl, game_items = _game_paths()
    used_meshes = set()
    for p, (b, e) in sorted(files.items()):
        if p.endswith(".w2ent"):
            try:
                info = read_template(read(b, e))
            except Exception:                       # noqa: BLE001 - a broken template: listed without details
                info = None
            row = _template_row(p, info, by_id, source)
            r.templates.append(row)
            used_meshes.update((info or {}).get("meshes", []))
            if p in game_tpl:
                r.replaces.append(p)
        elif content.ITEM_XML.search(p):
            try:
                raw = read(b, e)
            except Exception:                       # noqa: BLE001
                continue
            text = raw.decode("utf-16", "replace") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else \
                raw.decode("utf-8-sig", "replace")
            r.items += _item_rows(text, p, by_id, by_key)
    r.meshes = sorted(p for p in files if p.endswith(".w2mesh") and p not in used_meshes)
    for root, _d, fs in os.walk(folder):
        r.voices += sum(1 for f in fs if f.lower().endswith(".w3speech"))
    _checks(r, game_items)
    if log:
        log(f"[pack] {folder}: {len(r.templates)} templates, {len(r.items)} items, {len(r.meshes)} loose meshes")
    return r


def _checks(r, game_items):
    c = r.checks
    if not r.templates and not r.items:
        c.append(("warn", "empty", "Nothing to place or give: no templates (.w2ent) and no item definitions found "
                                   "in the folder's bundles.", []))
    if r.meta.get("id"):
        c.append(("ok", "card", f"Pack card: {r.meta.get('name') or r.meta['id']} {r.meta.get('version', '')}", []))
    else:
        c.append(("fix", "card", "No pack card yet: quests cannot name this mod, players cannot be told it is "
                                 "missing.", []))
    if not r.meta.get("url"):
        c.append(("warn", "url", "No download link: players who lack the mod are not told where to get it.", []))
    index = os.path.join(r.folder, content.INDEX)
    bundles = content.bundles_in(r.folder)
    if os.path.isfile(index) and all(os.path.getmtime(b) <= os.path.getmtime(index) for b in bundles):
        c.append(("ok", "index", f"Table of contents: {len(r.templates)} templates, {len(r.items)} items.", []))
    elif os.path.isfile(index):
        c.append(("fix", "index", "The mod changed since its table of contents was written: write the card again.",
                  []))
    else:
        c.append(("fix", "index", "Table of contents: written with the card (what the catalog shows of the mod).",
                  []))
    clash = sorted(i["name"] for i in r.items if i["name"] in game_items)
    if clash:
        c.append(("warn", "item_names", "Items with a name the game already uses - they change the game's item for "
                                        "everyone. Give new items names of their own (a prefix).", clash))
    # helper items no player sees (a sword's scabbard: neither a name nor an icon, as the game's own) - no warning
    helper = {i["name"] for i in r.items if not i["label"] and not i["icon"] and (
        i["category"].endswith("scabbards") or "NoShow" in i["tags"].split())}
    unnamed = sorted(i["name"] for i in r.items if not i["label"] and i["name"] not in helper)
    if unnamed:
        c.append(("warn", "item_labels", "Items without a readable name (no en.w3strings text for their "
                                         "localisation_key_name): quests and the catalog show the raw name.", unnamed))
    noicon = sorted(i["name"] for i in r.items if not i["icon"] and i["name"] not in helper)
    if noicon:
        c.append(("info", "item_icons", "Items without an icon (icon_path).", noicon))
    if r.replaces:
        c.append(("warn", "replaces", "Files at the game's own paths: the mod replaces them. Quests that use them "
                                      "show the game's version to players without the mod - new things belong in "
                                      "folders of their own.", r.replaces))
    prefixes = {p.split("\\")[0] + ("\\" + p.split("\\")[1] if p.startswith("dlc\\") else "") for p in
                [t["path"] for t in r.templates if t["path"] not in r.replaces]}
    if len(prefixes) > 3:
        c.append(("info", "folders", "New files spread over many top folders - one folder of the mod's own "
                                     "(dlc\\<mod>\\...) keeps them apart from other mods.", sorted(prefixes)))
    if r.meshes:
        c.append(("info", "meshes", "Meshes without a template: they cannot be placed. Conjunction can place meshes of "
                                    "the game through its mesh library; templates for these come with a later "
                                    "version.", r.meshes[:50]))


def slug(text):
    return re.sub(r"[^a-z0-9_]+", "_", str(text).lower()).strip("_")


def write(folder, meta, report=None):
    """The pack card and the table of contents into the mod folder. `meta`: id, name, author, version, url,
    description, kinds."""
    report = report or inspect(folder)
    # the id stays once written (quests name the pack by it - a new name or author must not break them); a new one
    # carries the author too (two "Medieval Furniture" packs of two people stay two)
    first = slug(meta.get("name") or os.path.basename(folder.rstrip("\\/")))
    if meta.get("author") and slug(meta["author"]) not in first:
        first = f"{first}_{slug(meta['author'])}"
    m = {"id": slug(meta.get("id") or (report.meta or {}).get("id") or first),
         "name": str(meta.get("name") or "").strip() or os.path.basename(folder.rstrip("\\/")),
         "author": str(meta.get("author") or "").strip(), "version": str(meta.get("version") or "1.0").strip(),
         "url": str(meta.get("url") or "").strip(), "description": str(meta.get("description") or "").strip(),
         "kinds": list(meta.get("kinds") or guess_kinds(report)), "made_with": "conjunction"}
    if not m["id"]:
        raise ValueError("The pack needs a name")
    prefix = m["id"].replace("_", " ") + " "        # (Conjunction names a pack's things <pack>_<name>)
    for t in report.templates:
        t["source"] = m["name"]
        if not t.get("named") and t["name"].startswith(prefix) and len(t["name"]) > len(prefix):
            t["name"] = t["name"][len(prefix):]
    index = {"pack": m["id"], "version": m["version"], "templates": report.templates, "items": report.items}
    for name, data, dump in ((content.INDEX, index, lambda d, f: json.dump(d, f, indent=0)),
                             (content.MARKER, m, lambda d, f: yaml.safe_dump(d, f, sort_keys=False,
                                                                             allow_unicode=True))):
        path = os.path.join(folder, name)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            dump(data, f)
        os.replace(tmp, path)
    report.meta = m
    return m


def guess_kinds(report):
    out = []
    cats = {t["cat"] for t in report.templates}
    world = [t for t in report.templates if t["kind"] != "Item"]        # (an item's entity is no furniture)
    if {t["cat"] for t in world} & {"Furniture", "Decoration", "Architecture", "Containers", "Lights", "Props"} or \
            any(t["kind"] in ("Decoration", "Container", "Light") for t in world):
        out.append("furniture")
    if report.items:
        out.append("items")
    if any(t["kind"] == "NPC" for t in report.templates):
        out.append("people")
    if any(t["kind"] in ("Monster", "Animal") for t in report.templates):
        out.append("creatures")
    if report.voices:
        out.append("voices")
    return out or ["other"]


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return
    folder = args[0]
    r = inspect(folder, log=print)
    for level, _key, text, things in r.checks:
        print(f"  {level:5} {text}" + (f" ({len(things)}: {', '.join(things[:5])})" if things else ""))
    print("  kinds:", ", ".join(guess_kinds(r)), " by category:", r.counts())
    if "--write" in args:
        meta = dict(a.split("=", 1) for a in args[args.index("--write") + 1:] if "=" in a)
        print("written:", write(folder, meta, r))


if __name__ == "__main__":
    main()
