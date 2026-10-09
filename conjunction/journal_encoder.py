"""Our own journal encoder (docs/VANILLA_EDITING_PLAN.md, R2 of replacing radish): journals.yml (radish's format,
our generator writes it) into the journal files the game reads - the quest group, the quest with its phases,
objectives, map pins and descriptions - and the texts with their string ids. As radish wrote them (measured over
every project's build: _scratch/journal_dump.py, tests/radish_compare.py).

    encode(journals, ctx) -> ({journal depot path: bytes}, [(string id, key, text)])
        journals    journals.yml read ({"journals": {"quests": {key: {...}}}})
        ctx         Ctx(quest id, dlc, id space, first id, template bytes)

The layout radish writes:
  questgroup_<quest>.journal    CJournalResource -> CJournalQuestGroup (baseName questgroup_<quest>, script id
                                questgroup_<quest>_<its GUID as a UUID>, title "MOD questgroup_<quest> Quests")
  <key>.journal                 CJournalResource -> CJournalQuest (baseName <quest>_<key>, script id
                                quest_<GUID as UUID>, type, world, title)
                                  -> a CJournalQuestPhase per instruction group -> its objectives in name order
                                     (order / index: their place in the list), each objective's map pins
                                     (<quest>_<world>_<pin>_mp, radius)
                                  -> a CJournalQuestDescriptionGroup (<key>_description_<UUID>) -> its entries
String ids: the id space's range from the first id on, in the order: the group's title, the objectives (file
order), the descriptions (name order), the quest's title.
"""
import uuid

from .cr2w_tree import Guid, Loc, Obj, Prop, Tree

FLAGS = 8192
TYPES = {"SideQuest": "Side", "MainQuest": "Chapter", "MonsterHunt": "MonsterHunt", "TreasureHunt": "TreasureHunt",
         "Side": "Side", "Chapter": "Chapter"}
# a journal quest's world (the objectives': one more) - the game's numbers (story.py measured them: 1 Novigrad,
# 9 Velen ...); radish's names
WORLD = {"novigrad": 1, "skellige": 2, "kaer_morhen": 3, "kaermorhen": 3, "prologue": 4, "vizima": 5,
         "isle_of_mists": 6, "spiral": 7, "prologue_winter": 8, "velen": 9, "toussaint": 11, "bob": 11}


class Ctx:
    def __init__(self, quest, dlc, idspace, first=0, template=None):
        self.quest, self.dlc, self.idspace, self.first = quest, dlc, int(idspace), int(first)
        self.template = template                    # bytes of any CR2W file (its header)


def _uuid(g):
    return str(uuid.UUID(bytes_le=bytes(g)))


class Encoder:
    def __init__(self, ctx):
        self.ctx = ctx
        self.next_id = ctx.first
        self.strings = []

    def text(self, s, key=""):
        sid = 2110000000 + self.ctx.idspace * 1000 + self.next_id
        self.next_id += 1
        self.strings.append((sid, key, str(s)))
        return Loc(sid)

    def tree(self):
        t = Tree(self.ctx.template)
        t.objects, t.f.imports, t.f.buffers = [], [], []
        return t

    @staticmethod
    def add(t, cls, parent, props):
        t.objects.append(Obj(cls, FLAGS, parent, 0, [Prop(n, ty, v) for n, ty, v in props]))
        return len(t.objects)

    def group(self):
        t = self.tree()
        g = Guid(uuid.uuid4().bytes)
        res = self.add(t, "CJournalResource", 0, [("entry", "ptr:CJournalBase", 2)])
        name = f"questgroup_{self.ctx.quest}"
        self.add(t, "CJournalQuestGroup", res, [
            ("guid", "CGUID", g), ("baseName", "String", name),
            ("uniqueScriptIdentifier", "CName", f"{name}_{_uuid(g)}"),
            ("title", "LocalizedString", self.text(f"MOD {name} Quests"))])
        return t, g

    def quest(self, key, q, group_guid):
        t = self.tree()
        qg = Guid(uuid.uuid4().bytes)
        res = self.add(t, "CJournalResource", 0, [("entry", "ptr:CJournalBase", 2)])
        quest = self.add(t, "CJournalQuest", res, [])
        world = WORLD.get(str(q.get("world", "")).lower())
        children = []
        for phase_name, objectives in (q.get("instructions") or {}).items():
            pg = Guid(uuid.uuid4().bytes)
            phase = self.add(t, "CJournalQuestPhase", quest, [
                ("guid", "CGUID", pg), ("baseName", "String", str(phase_name)), ("parentGuid", "CGUID", qg),
                ("children", "array:2,0,ptr:CJournalContainerEntry", [])])
            children.append(phase)
            listed = []
            for k, item in enumerate(objectives or []):
                for oname, body in (item.items() if isinstance(item, dict) else []):
                    listed.append((str(oname), k, body or {}))
            kids = []
            for oname, k, body in sorted(listed, key=lambda x: x[0]):
                og = Guid(uuid.uuid4().bytes)
                props = [("guid", "CGUID", og), ("baseName", "String", oname), ("order", "Uint32", k),
                         ("parentGuid", "CGUID", pg), ("index", "Uint8", k)]
                obj = self.add(t, "CJournalQuestObjective", phase, props)
                pins = []
                for n, pin in enumerate(body.get("mappins") or []):
                    pname, radius = (pin[0], pin[1]) if isinstance(pin, (list, tuple)) else (pin, 1.0)
                    mp = f"{self.ctx.quest}_{q.get('world')}_{pname}_mp"
                    pins.append(self.add(t, "CJournalQuestMapPin", obj, [
                        ("guid", "CGUID", Guid(uuid.uuid4().bytes)), ("baseName", "String", mp),
                        ("order", "Uint32", n), ("parentGuid", "CGUID", og), ("radius", "Float", float(radius)),
                        ("mapPinID", "CName", mp)]))
                o = t.obj(obj)
                if pins:
                    o.props.append(Prop("children", "array:2,0,ptr:CJournalContainerEntry", pins))
                o.props.append(Prop("title", "LocalizedString", self.text(body.get("caption", ""))))
                if world is not None:
                    o.props.append(Prop("world", "Uint32", world + 1))
                kids.append(obj)
            t.obj(phase).set("children", kids)
        descriptions = q.get("description") or []
        if descriptions:
            dg = Guid(uuid.uuid4().bytes)
            group = self.add(t, "CJournalQuestDescriptionGroup", quest, [
                ("guid", "CGUID", dg), ("baseName", "String", f"{key}_description_{_uuid(dg)}"),
                ("parentGuid", "CGUID", qg), ("children", "array:2,0,ptr:CJournalContainerEntry", [])])
            listed = [(str(ename), k, text) for k, item in enumerate(descriptions)
                      for ename, text in (item.items() if isinstance(item, dict) else [])]
            entries = []
            for ename, k, text in sorted(listed, key=lambda x: x[0]):      # (in name order, as the objectives)
                props = [("guid", "CGUID", Guid(uuid.uuid4().bytes)), ("baseName", "String", ename),
                         ("order", "Uint32", k), ("parentGuid", "CGUID", dg)]
                if k:                                   # (radish writes the index from the second entry on)
                    props.append(("index", "Uint8", k))
                props.append(("description", "LocalizedString", self.text(text)))
                entries.append(self.add(t, "CJournalQuestDescriptionEntry", group, props))
            t.obj(group).set("children", entries)
            children.append(group)
        props = [("guid", "CGUID", qg), ("baseName", "String", f"{self.ctx.quest}_{key}"),
                 ("uniqueScriptIdentifier", "CName", f"quest_{_uuid(qg)}"), ("parentGuid", "CGUID", group_guid),
                 ("children", "array:2,0,ptr:CJournalContainerEntry", children),
                 ("type", "eQuestType", TYPES.get(str(q.get("type")), "Side"))]
        if world is not None:
            props.append(("world", "Uint32", world))
        props.append(("title", "LocalizedString", self.text(q.get("title", key))))
        t.obj(quest).props = [Prop(n, ty, v) for n, ty, v in props]
        return t


def encode(journals, ctx):
    e = Encoder(ctx)
    files = {}
    base = f"dlc/{ctx.dlc}/journal/quests"
    gt, gg = e.group()
    files[f"{base}/questgroup_{ctx.quest}.journal"] = gt.to_bytes()
    for key, q in ((journals.get("journals") or {}).get("quests") or {}).items():
        files[f"{base}/{key}.journal"] = e.quest(key, q, gg).to_bytes()
    return files, e.strings
