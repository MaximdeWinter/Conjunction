"""The journal entries a quest block can name (an objective to show or tick off, a quest to track, a map pin): every
journal path the game's quest files hold, each with a readable name - the quest, its phase, the objective - read
from the journal files it leads into. What the card's journal picker lists and copies from (a path is a chain of
objects: the journal file of the act, the quest's file, the quest's entries down to the one meant; copied as the
game wrote it, its GUIDs the entries').

    build(depot) -> index           about a minute; kept in %APPDATA%\\conjunction\\journal_index.json
    load() -> index | None
    index = {"entries": [{"key": chain key, "label", "kind", "count", "file", "obj"}]}
    chain(tree, n) -> key           a path object's chain as a key: "resource|guid>resource|guid>..."
    of_tree(tree, path) -> entries  the paths of one file (an own quest's: offered beside the game's)
"""
import collections
import json
import os

from . import config
from .cr2w_tree import Guid, Soft, Tree

CACHE = os.path.join(os.path.dirname(config.PATH), "journal_index.json")
KINDS = {"CJournalQuest": "quest", "CJournalQuestPhase": "phase", "CJournalQuestObjective": "objective",
         "CJournalQuestMapPin": "map pin", "CJournalQuestDescriptionGroup": "description",
         "CJournalCharacter": "person", "CJournalCreature": "monster", "CJournalQuestGroup": "act",
         "CJournalStoryBookPage": "story book", "CJournalTutorial": "tutorial", "CJournalGlossary": "glossary",
         "CJournalQuestDescriptionEntry": "quest text", "CJournalCharacterDescription": "person's text",
         "CJournalCreatureDescriptionEntry": "monster's text", "CJournalStoryBookPageDescription": "story book text",
         "CJournalCreatureGroup": "monster group"}


def chain(tree, n):
    """[(journal file or "", guid hex)] along a path object's children."""
    out = []
    o = tree.obj(n) if isinstance(n, int) and n > 0 else None
    while o is not None and o.cls == "CJournalPath":
        res = o.get("resource")
        k = int(res) if isinstance(res, Soft) else 0
        path = tree.f.imports[k - 1][0] if 0 < k <= len(tree.f.imports) else ""
        g = o.get("guid")
        out.append((path, bytes(g).hex() if isinstance(g, Guid) else ""))
        ch = o.get("child")
        o = tree.obj(ch) if isinstance(ch, int) and ch > 0 else None
    return out


def key_of(ch):
    return ">".join(f"{p}|{g}" for p, g in ch)


def roots(tree):
    """The path objects a block points at (not a child of another path)."""
    kids = {o.get("child") for o in tree.objects if o.cls == "CJournalPath"}
    for k, o in enumerate(tree.objects, 1):
        if o.cls == "CJournalPath" and k not in kids:
            yield k


def of_tree(tree, path):
    out = {}
    for k in roots(tree):
        ch = chain(tree, k)
        if ch:
            key = key_of(ch)
            e = out.setdefault(key, {"key": key, "chain": ch, "count": 0, "file": path, "obj": k})
            e["count"] += 1
    return list(out.values())


class Names:
    """Journal entries' names by GUID, read from the journal files a path leads into."""

    def __init__(self, depot, own=None):
        self.depot, self.own, self.files = depot, own or {}, {}

    def of(self, path):
        if path not in self.files:
            names = {}
            try:
                data = self.own.get(path) or self.depot.read(path)
                t = Tree(data)
                for o in t.objects:
                    g = o.get("guid") if o.props else None
                    if isinstance(g, Guid):
                        names[bytes(g).hex()] = (o.cls, str(o.get("baseName") or o.get("name") or ""))
            except Exception:                           # noqa: BLE001 - a file not found: no names from it
                pass
            self.files[path] = names
        return self.files[path]

    def label(self, ch):
        """'quest / phase / objective' and the kind of the last."""
        parts, kind, res = [], "", ""
        for path, g in ch:
            res = path or res
            if not res:
                continue
            cls, name = self.of(res).get(g, ("", ""))
            if cls in ("CJournalQuestGroup", "CJournalResource", ""):
                continue
            if name:
                parts.append(name)
            kind = KINDS.get(cls, cls.replace("CJournal", "").lower())
        return " / ".join(parts) or (os.path.basename(res).replace(".journal", "") if res else "?"), kind


def build(depot=None, log=print):
    from . import story
    from .bundles import Depot
    depot = depot or Depot()
    files = sorted(p for p in depot.where if p.endswith((".w2phase", ".w2quest")) and story.game_file(p))
    entries = {}
    for path in files:
        try:
            t = Tree(depot.read(path))
        except Exception:                               # noqa: BLE001
            continue
        for e in of_tree(t, path):
            have = entries.get(e["key"])
            if have:
                have["count"] += e["count"]
            else:
                entries[e["key"]] = e
    names = Names(depot)
    out = []
    for e in entries.values():
        e["label"], e["kind"] = names.label(e["chain"])
        out.append(e)
    out.sort(key=lambda e: (e["label"].lower(), -e["count"]))
    index = {"entries": out}
    tmp = CACHE + ".tmp"
    json.dump(index, open(tmp, "w", encoding="utf-8"))
    os.replace(tmp, CACHE)
    log(f"[journal] {len(out)} journal entries the game's quests name")
    return index


def own_journal_names(project_dir):
    """{guid hex: "file|class|name|n"} of every entry of the own quest's journal as its last build wrote it - the
    file with the quest id as {QID} (the same entry in every run of Build & Play and after the journal encoder
    changed: its GUIDs may differ, its names do not)."""
    import glob
    from .vanilla_edit import own_quest
    rel, _built = own_quest(project_dir)
    if not rel:
        return {}
    qid = os.path.splitext(os.path.basename(rel))[0]
    root = os.path.join(project_dir, "build", "uncooked")
    out = {}
    for f in sorted(glob.glob(os.path.join(root, os.path.dirname(os.path.dirname(rel)), "**", "*.journal"),
                           recursive=True)):
        try:
            t = Tree(open(f, "rb").read())
        except Exception:                               # noqa: BLE001
            continue
        name_of_file = os.path.relpath(f, root).replace("\\", "/").lower().replace(qid, "{QID}")
        seen = collections.Counter()
        for o in t.objects:
            g = o.get("guid") if o.props else None
            if isinstance(g, Guid):
                key = f"{name_of_file}|{o.cls}|{str(o.get('baseName') or '').replace(qid, '{QID}')}"
                seen[key] += 1
                out[bytes(g).hex()] = f"{key}|{seen[key]}"
    return out


def own_objectives(project_dir):
    """The objectives of a project's own quest as its last build wrote them: [{"id", "guid", "caption", "file"}] -
    the quest board's and those made in the quest graph (graph_journal.yml)."""
    import glob
    import yaml
    from .vanilla_edit import own_quest
    rel, _built = own_quest(project_dir)
    if not rel:
        return []
    dlc_dir = os.path.join(project_dir, "build", "uncooked", os.path.dirname(os.path.dirname(rel)))
    captions = {}
    try:
        jy = yaml.safe_load(open(os.path.join(project_dir, "build", "definition.quest", "journals.yml"),
                                 encoding="utf-8")) or {}
        for q in ((jy.get("journals") or {}).get("quests") or {}).values():
            for items in (q.get("instructions") or {}).values():
                for item in items or []:
                    for k, body in (item.items() if isinstance(item, dict) else []):
                        captions[str(k)] = (body or {}).get("caption", "")
    except OSError:
        pass
    out = []
    for f in sorted(glob.glob(os.path.join(dlc_dir, "**", "*.journal"), recursive=True)):
        try:
            t = Tree(open(f, "rb").read())
        except Exception:                               # noqa: BLE001
            continue
        for o in t.objects:
            if o.cls == "CJournalQuestObjective" and isinstance(o.get("guid"), Guid):
                oid = str(o.get("baseName") or "")
                out.append({"id": oid, "guid": bytes(o.get("guid")).hex(), "caption": captions.get(oid, oid),
                            "file": os.path.relpath(f, os.path.join(project_dir, "build", "uncooked"))})
    return out


def load():
    if not os.path.exists(CACHE):
        return None
    return json.load(open(CACHE, encoding="utf-8"))


def get(depot=None):
    return load() or build(depot)


def by_key(index):
    return {e["key"]: e for e in (index or {}).get("entries") or []}


__all__ = ["build", "load", "get", "chain", "key_of", "of_tree", "Names", "by_key", "collections"]
