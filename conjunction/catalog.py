"""The catalog: everything that can be placed in the world, found by typing a few letters.

    python -m conjunction.catalog build          index the game's bundles (base game, expansions, DLCs) - once, ~10 s
    python -m conjunction.catalog search chest   try a search

The index is read from the bundles' tables of contents (no extraction, nothing copied): every entity template
(.w2ent) gets a kind (Decoration, Container, NPC, ...), a readable name, tags from its path and where it comes from
(Base game, Hearts of Stone, Blood and Wine). Stored in %APPDATA%\\conjunction\\catalog.json; plugins can add entries
(`add_source`).
"""
import glob
import json
import os
import re
import sys

from . import config

PATH = os.path.join(os.path.dirname(config.PATH), "catalog.json")
VERSION = 4

# kind by path, first match wins (paths are lower case with backslashes)
KINDS = [
    ("Character part", [r"^characters\\models\\", r"^characters\\base_entities\\", r"\\characters\\models\\"]),
    ("Item", [r"^items\\", r"\\data\\items\\"]),
    ("Container", [r"\\containers?\\", r"_chest", r"\\chest", r"\\loot", r"_crate", r"\\barrel_loot"]),
    ("Light", [r"\\lights?\\", r"\\light_sources?\\", r"torch", r"candle", r"lantern", r"brazier", r"campfire",
               r"_fire_?place", r"bonfire"]),
    ("Monster", [r"\\monsters?\\"]),
    ("Animal", [r"\\animals?\\", r"\\horses?\\", r"\\birds?\\", r"\\fish\\"]),
    ("NPC", [r"\\npc_entities\\", r"\\characters\\", r"\\community\\", r"\\npcs?\\"]),
    ("Vehicle", [r"\\boats?\\", r"\\vehicles?\\", r"\\wagons?\\", r"\\carts?\\"]),
    ("Plant", [r"\\vegetation\\", r"\\foliage\\", r"\\trees?\\", r"\\bushes\\", r"\\herbs?\\", r"\\plants?\\"]),
    ("Architecture", [r"\\architecture\\", r"\\buildings?\\", r"\\doors?\\", r"\\gates?\\", r"\\walls?\\",
                      r"\\bridges?\\", r"\\fences?\\", r"\\ruins?\\"]),
    ("Furniture", [r"\\furniture\\", r"\\beds?\\", r"\\tables?\\", r"\\chairs?\\", r"\\benches?\\"]),
    ("Decoration", [r"\\decorations?\\", r"\\props?\\", r"\\decoration_sets?\\", r"\\clutter\\"]),
    ("Item", [r"^items\\", r"\\items\\", r"\\weapons?\\", r"\\armou?rs?\\"]),
    ("Effect", [r"^fx\\", r"\\fx\\", r"\\effects?\\", r"\\particles?\\"]),
    ("Sound", [r"\\sounds?\\", r"\\sound_emitters?\\", r"\\ambient_sounds?\\"]),
    ("Gameplay", [r"^gameplay\\", r"\\gameplay\\", r"\\triggers?\\", r"\\interactive\\", r"\\signs?\\"]),
    ("Terrain", [r"\\rocks?\\", r"\\stones?\\", r"\\cliffs?\\", r"\\terrain", r"\\ground\\", r"\\water\\"]),
    ("Quest object", [r"^quests?\\", r"\\quests?\\"]),
    ("Living world", [r"living_world\\"]),
]
HIDDEN = {"Character part"}         # heads, hair, clothes of characters: found when asked for, not by default
KIND_RE = [(k, re.compile("|".join(p))) for k, p in KINDS]
# engine / tooling templates nobody wants to place: kept out of the catalog
SKIP = re.compile(r"\\(cutscenes?|cameras?|editor|engine\\|debug|test(s|_)|dummy|templates\\gameplay_abilities)"
                  r"|^engine\\|\\animations?\\|\\behaviou?rs?\\|_proxy\b|\\proxies\\")
SOURCES = [("dlc\\ep1\\", "Hearts of Stone"), ("dlc\\bob\\", "Blood and Wine")]
STOP = {"dlc", "data", "w2ent", "entities", "entity", "common", "environment", "set", "sets", "the", "and", "of",
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "ep1", "bob", "npc", "model", "models", "levels"}


def bundles(game):
    out = glob.glob(os.path.join(game, "content", "content*", "bundles", "*.bundle"))
    out += glob.glob(os.path.join(game, "dlc", "*", "content", "bundles", "*.bundle"))
    return sorted(out)


def bundle_files(path):
    """Depot paths in a bundle's table of contents (either layout: bundles.entries)."""
    from .bundles import entries
    with open(path, "rb") as f:
        if f.read(8) != b"POTATO70":
            return []
    return [e[0].lower().replace("/", "\\") for e in entries(path) if e[0]]


def kind_of(path):
    for k, rx in KIND_RE:
        if rx.search(path):
            return k
    return "Other"


def source_of(path):
    for prefix, name in SOURCES:
        if path.startswith(prefix):
            return name
    if path.startswith("dlc\\"):
        return "DLC"
    return "Base game"


def caption(path):
    """decoration_set_boxes_chest_a.w2ent -> 'boxes chest a' (words of the file name without the set prefix)."""
    base = os.path.splitext(os.path.basename(path))[0]
    base = re.sub(r"^(decoration_set_|dec_|env_|q\d+_|mq\d+_|sq\d+_)", "", base)
    return re.sub(r"_+", " ", base).strip()


def group_of(path):
    """The folder that tells what it belongs to (skipping generic ones): '...\\mq3002_hidden_messages\\entities\\x'
    -> 'mq3002 hidden messages'."""
    generic = {"entities", "entity", "templates", "data", "quest_files", "clues", "common", "items"}
    parts = path.split("\\")[:-1]
    for d in reversed(parts):
        if d not in generic:
            return d.replace("_", " ")
    return ""


def tags_of(path):
    words = re.split(r"[\\_\-. ]+", path)
    return sorted({w for w in words if len(w) > 1 and w not in STOP and not w.isdigit()})


def build(game=None):
    game = game or config.load()["game"]
    seen = {}
    for b in bundles(game):
        for p in bundle_files(b):
            # (Conjunction's own mesh library comes with readable names from its index, see meshlib)
            if p.endswith(".w2ent") and p not in seen and not SKIP.search(p) and "\\dlcconjunctionmeshes\\" not in p:
                seen[p] = {"path": p, "name": caption(p), "kind": kind_of(p), "source": source_of(p),
                           "tags": tags_of(p), "group": group_of(p), "quest": "\\quest" in "\\" + p}
    entries = sorted(seen.values(), key=lambda e: (e["kind"], e["name"]))
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    json.dump({"version": VERSION, "entries": entries}, open(PATH, "w", encoding="utf-8"))
    return entries


class Catalog:
    """Loaded index + search. `sources` from plugins add entries (dicts like the index's)."""

    def __init__(self, entries=None):
        if entries is None:
            if not os.path.exists(PATH) or json.load(open(PATH, encoding="utf-8")).get("version") != VERSION:
                build()
            entries = json.load(open(PATH, encoding="utf-8"))["entries"]
        from . import foliage, meshlib
        entries = entries + meshlib.catalog_entries() + foliage.catalog_entries()
        self.entries = entries
        self._hay = [self._haystack(e) for e in entries]

    @staticmethod
    def _haystack(e):
        return " ".join([e["name"], e["kind"].lower(), e["source"].lower(), " ".join(e.get("tags", [])),
                         e["path"]]).lower()

    def add_source(self, entries):
        for e in entries:
            e.setdefault("tags", tags_of(e["path"]))
            e.setdefault("name", caption(e["path"]))
            e.setdefault("kind", kind_of(e["path"]))
            e.setdefault("source", "Plugin")
            self.entries.append(e)
            self._hay.append(self._haystack(e))

    def kinds(self):
        out = {}
        for e in self.entries:
            out[e["kind"]] = out.get(e["kind"], 0) + 1
        return sorted(out.items(), key=lambda kv: -kv[1])

    def search(self, text="", kind=None, source=None, limit=500, everything=False):
        """All words must appear (name, tags, kind, path); name hits first, shorter names first. Hidden kinds only
        when asked for by kind or `everything`."""
        words = text.lower().split()
        hits = []
        for e, hay in zip(self.entries, self._hay):
            if kind and e["kind"] != kind:
                continue
            if not kind and not everything and e["kind"] in HIDDEN:
                continue
            if source and e["source"] != source:
                continue
            if all(w in hay for w in words):
                # the generic things first; one-off quest props after
                in_name = sum(w in e["name"] for w in words)
                hits.append((-in_name, bool(e.get("quest")), len(e["name"]), e["name"], e))
        hits.sort(key=lambda h: h[:4])
        return [h[4] for h in hits[:limit]]


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "build"
    if cmd == "build":
        entries = build()
        cat = Catalog(entries)
        print(f"{len(entries)} templates -> {PATH}")
        for k, n in cat.kinds():
            print(f"  {k:13s} {n}")
    elif cmd == "search":
        for e in Catalog().search(" ".join(sys.argv[2:]), limit=30):
            print(f"{e['kind']:12s} {e['name']:40s} {e['path']}")


if __name__ == "__main__":
    main()
