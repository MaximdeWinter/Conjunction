"""The picked block's card in the quest graph (docs/SESSION_PLAN_0510.md, step 4): what the block is and does in
plain words, then its settings as fields one fills in - a yes/no a tick, a choice a list, a fact or a tag typed
with the values the game uses offered - for the block and for what sits under it (a wait's conditions, what a
person's condition checks, a person's action, a game function's values). Fields the game's file leaves out (they
are at their default) are shown with the default and written when changed. Everything else: the "All values" tab.

    card = BlockCard(window)        window: the VanillaWindow (its edit(fn) makes a change)
    card.show_block(qf, b)          b: a vanilla_graph Block (None: empty)
"""
import re

from PySide6 import QtCore, QtGui, QtWidgets

from . import blocks
from .cr2w_tree import SIMPLE, Guid, Soft, Struct, Tags, Variant, is_enum

QUIET = {"guid", "cachedConnections", "name", "comment", "embeddedGraph", "conditions",
         "questCondition", "ai", "checkType", "parameters", "functionName", "graphBlocks", "spawnsets"}
INTS = {"Int8", "Uint8", "Int16", "Uint16", "Int32", "Uint32", "Int64", "Uint64"}
STYLE = (
    "QWidget#card{background:#18181b}"
    "QLabel{color:#c8c8cc;font:12px}"
    "QLabel#kind{color:#f2f2f4;font:bold 15px}"
    "QLabel#what{color:#a8a8b0;font:12px}"
    "QLabel#section{color:#8c8c94;font:bold 11px;padding-top:8px}"
    "QLabel#hint{color:#7c7c84;font:11px}"
    "QCheckBox{color:#8c8c94}"
    "QPushButton#more{background:transparent;border:none;color:#8c8c94;text-align:left;padding:2px 0}"
    "QPushButton#more:hover{color:#f0f0f2}"
    "QPushButton#more:checked{color:#c8c8cc}")


def human(name):
    """factId -> 'Fact id', isInside -> 'Is inside', npcTag -> 'Npc tag'."""
    words = re.findall(r"[A-Z]+(?=[A-Z][a-z]|\d|\b)|[A-Z]?[a-z]+|\d+|[A-Z]+", name.replace("_", " "))
    text = " ".join(w.lower() if k else w.capitalize() for k, w in enumerate(words)) if words else name
    return text.replace(" id", " ID") if text.endswith(" id") else text


def editable_type(typ):
    """Can this type be a plain field? (bool, number, text, a choice, tags, a list of names, a file)"""
    if typ in SIMPLE or typ in ("CName", "String", "StringAnsi", "TagList", "name", "string", "bool", "int",
                                "float"):
        return True
    if typ.startswith(("soft:", "handle:C")) and not typ.startswith(("handle:CJournalPath",)):
        return typ.split(":", 1)[1] in ("CStoryScene", "CQuestPhase", "CCommunity", "CEntityTemplate",
                                       "CBehTree", "CEnvironmentDefinition")
    if typ.startswith("array:2,0,") and (typ[10:] in LIST_ITEMS or is_enum(typ[10:])):
        return True
    if typ in ("Vector", "EulerAngles", "GameTime", "EngineTransform"):
        return True
    return is_enum(typ)


LIST_ITEMS = {"String", "CName", "Bool", "Int32", "Uint32", "Float", "Uint8", "Int8", "Uint16", "Int16", "CGUID"}
VECTOR = {"Vector": ("X", "Y", "Z", "W"), "EulerAngles": ("Pitch", "Yaw", "Roll")}


OBJECT_HEADS = {"conditions": "Waits for", "questCondition": "Checks", "ai": "Does", "checkType": "What it checks",
                "spawnsets": "Spawn sets", "function": "Time", "minigame": "Minigame"}


def object_type(typ):
    """Does a field of this type hold objects of the file (not a file, not the journal - those have fields)?"""
    inner = typ[10:] if typ.startswith("array:2,0,") else typ
    if not inner.startswith(("ptr:", "handle:")):
        return False
    cls = inner.split(":", 1)[1]
    return cls not in ("CJournalPath", "CQuestGraph", "CQuestGraphBlock") and cls not in FILE_CLASSES


FILE_CLASSES = {"CStoryScene", "CQuestPhase", "CCommunity", "CEntityTemplate", "CBehTree", "CEnvironmentDefinition",
                "CResource", "CWorld", "CMesh", "CSkeletalAnimationSet"}


FILE_EXT = {"CStoryScene": ".w2scene", "CCommunity": ".w2comm", "CQuestPhase": ".w2phase",
            "CEntityTemplate": ".w2ent", "CBehTree": ".w2behtree", "CEnvironmentDefinition": ".env"}
_FILES = {}     # (the game's files by kind, listed once)


def struct_simple(v, depth=0):
    """Is a struct made only of plain parts (yes/no, numbers, words, choices, tags, files - or structs of them)?"""
    if depth > 4:
        return False
    for q in v:
        if isinstance(q.value, Struct):
            if not struct_simple(q.value, depth + 1):
                return False
        elif isinstance(q.value, list) and not isinstance(q.value, Tags):
            if not all(isinstance(x, Struct) and struct_simple(x, depth + 1) or
                       isinstance(x, (int, float, str)) for x in q.value):
                return False                            # (a list of plain parts: a curve's points)
        elif q.type.startswith(("handle:", "ptr:")) and isinstance(q.value, int) and q.value > 0:
            return False                                # (an object of the file)
        elif isinstance(q.value, Guid):
            return False
    return True


def item(typ, text):
    """One item of a list typed as text: yes/no, a number, a word."""
    text = text.strip()
    if typ == "Bool":
        return text.lower() in ("yes", "true", "1", "on")
    if typ == "Float":
        return float(text.replace(",", "."))
    if typ in ("Int32", "Uint32", "Uint8", "Int8", "Uint16", "Int16"):
        return int(float(text))
    if typ == "CGUID":
        from .cr2w_tree import Guid
        return Guid(bytes.fromhex(text.replace("-", "")))
    return text


def game_time_text(secs):
    d, rest = divmod(int(secs), 86400)
    h, rest = divmod(rest, 3600)
    m, s = divmod(rest, 60)
    return (f"{d}d " if d else "") + f"{h:02d}:{m:02d}" + (f":{s:02d}" if s else "")


def game_time(text):
    """'08:30', '1d 08:30', '8:30:15' -> seconds."""
    text = text.strip().lower()
    days = 0
    if "d" in text:
        dpart, text = text.split("d", 1)
        days = int(dpart.strip() or 0)
    parts = [int(x) for x in text.strip().split(":") if x.strip()] + [0, 0, 0]
    return days * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]


def transform_text(t):
    """A place, its turn and size as text: 'x, y, z; pitch, yaw, roll; sx, sy, sz' (a part left out: empty)."""
    return "; ".join(", ".join(f"{x:g}" for x in part) if part else "" for part in (t.position, t.rotation, t.scale))


def transform(text):
    from .cr2w_tree import Transform
    parts = [x.strip() for x in text.split(";")] + ["", "", ""]

    def nums(s):
        return tuple(float(x) for x in re.split(r"[,\s]+", s) if x) or None
    return Transform(nums(parts[0]), nums(parts[1]), nums(parts[2]))


def item_text(v):
    if isinstance(v, bytes):
        return v.hex()
    return ("yes" if v else "no") if isinstance(v, bool) else f"{v:g}" if isinstance(v, float) else str(v)


class BlockCard(QtWidgets.QScrollArea):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.setWidgetResizable(True)
        self.setFrameShape(QtWidgets.QFrame.NoFrame)
        self._catalog = None
        self.body = None
        self.show_block(None, None)

    @property
    def catalog(self):
        if self._catalog is None:
            from . import game_catalog
            self._catalog = game_catalog.load() or {"classes": {}, "functions": {}, "enums": {}}
        return self._catalog

    # --- building the card
    def show_block(self, qf, b):
        self.qf, self.b = qf, b
        body = QtWidgets.QWidget()
        body.setObjectName("card")
        body.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        body.setStyleSheet(STYLE)
        self.form = QtWidgets.QVBoxLayout(body)
        self.form.setContentsMargins(10, 8, 10, 10)
        self.form.setSpacing(4)
        self.fields = {}                                # (object, field) -> widget (tests)
        if b is not None and getattr(b, "folded", None):
            self._folded()
        elif b is not None:
            self._build()
        self.form.addStretch(1)
        self.setWidget(body)
        self.body = body

    def _label(self, text, name=None, wrap=True):
        lab = QtWidgets.QLabel(text)
        if name:
            lab.setObjectName(name)
        lab.setWordWrap(wrap)
        lab.setTextInteractionFlags(QtCore.Qt.TextSelectableByMouse)
        self.form.addWidget(lab)
        return lab

    def _build(self):
        qf, b = self.qf, self.b
        o = qf.tree.obj(b.n)
        kind = getattr(b, "kind", None) or blocks.kind_of(qf.tree, b.n)
        colour = blocks.GROUP_COLOUR.get(kind.group, "#6a6a74")
        bar = QtWidgets.QFrame()
        bar.setFixedHeight(3)
        bar.setStyleSheet(f"background:{colour}")
        self.form.addWidget(bar)
        self._label(b.title, "kind")
        what = kind.text
        if not kind.simple:
            what = self._game_doc(o) or what
        self._label(what, "what")
        group = dict(blocks.GROUPS).get(kind.group, "")
        self._label(f"{group} · {o.cls}" + ("" if kind.simple else " · a game block"), "hint")
        self._fact_refs(b.n)
        self._examples(kind)
        self._name_field(o, b.n)
        for key in self._journal_fields(o):
            self._journal_row(b.n, key, o)
        if o.cls == blocks.P:                           # a custom block: the fields it shows outside
            self._custom(b.n, o)
        if o.cls == blocks.P:                           # a phase: a graph of its own, or a phase file
            inside = isinstance(o.get("embeddedGraph"), int) and o.get("embeddedGraph") > 0
            pick = QtWidgets.QComboBox()
            pick.addItems(["Its own graph (double click to open)", "A phase file"])
            pick.setCurrentIndex(0 if inside else 1)
            pick.activated.connect(lambda i, n=b.n: self.window.edit(
                (lambda e: e.phase_inside(n)) if i == 0 else (lambda e: e.phase_from_file(n, None))))
            self.fields[(b.n, "phase:kind")] = pick
            self._row("Plays", pick)
            if getattr(b, "opens", None):               # (a double click on the block does the same)
                go = QtWidgets.QPushButton("Open the phase")
                go.clicked.connect(lambda _c=False, n=b.n: self.window.open_block(n))
                self.fields[(b.n, "phase:open")] = go
                self._row("", go)
        self._fields(b.n, o, "Settings")
        if o.cls in ("CQuestSceneBlock", "CQuestInteractionDialogBlock", "CQuestContextDialogBlock"):
            self._scene(o)
        self._structs(b.n, o)
        if o.cls == blocks.S:
            self._params(b.n, o)
        self._objects(b.n, o)
        if o.cls not in ("CCommentGraphBlock", "CDescriptionGraphBlock"):
            p = o.prop("comment")
            typ = p.type if p is not None else "String"
            self._label("Note", "section")
            row = self._row("Comment", self._line(b.comment, "a note for yourself (not in the game)",
                                                  lambda text: self.window.edit(
                                                      lambda e: e.set_field(b.n, "comment", text, typ))))
            self.fields[(b.n, "comment")] = row.field

    # --- how the game uses a kind: real places, a click opens them
    # --- a scene: who is in it, its ways in and out, how much is said
    def _scene(self, o):
        s = o.get("scene")
        path = self.qf.import_path(s) if s else None
        if not path:
            return
        try:
            from .scene_swap import outline
            info = outline(self.window.depot, path)
        except Exception:                               # noqa: BLE001 - not a scene the game has (an own one)
            return
        self._label("The scene", "section")
        who = [a.get("voicetag") for a in info.get("actors") or [] if a.get("voicetag")]
        for label, text in (("Who", ", ".join(x.title() for x in who) or "-"),
                            ("Ways in", ", ".join(i["name"] for i in info.get("inputs") or []) or "-"),
                            ("Ways out", ", ".join(info.get("outputs") or []) or "-"),
                            ("Lines", str(info.get("lines", 0)))):
            lab = QtWidgets.QLabel(text)
            lab.setWordWrap(True)
            self._row(label, lab)

    # --- a fact: every block of the file that sets or reads it (the quest's memory, followed)
    def _fact_refs(self, n):
        from .fact_refs import facts_of, uses
        names = facts_of(self.qf.tree, n)
        if not names:
            return
        found = uses(self.qf, names)
        others = [u for u in found if u["block"] != n]
        self._label(f"This fact in this file: {', '.join(sorted(names))} ({len(others)} other blocks)", "section")
        for u in others[:12]:
            b = QtWidgets.QPushButton(f"{u['what']}: {u['title']}" + (f" \"{u['name']}\"" if u["name"] else "") +
                                      (f"  - in {u['where']}" if u["where"] else ""))
            b.setObjectName("example")
            b.setStyleSheet("QPushButton#example{text-align:left;background:#1f1f23;border:1px solid #2c2c32;"
                            "color:#b8b8c0;padding:3px 6px;font:11px}QPushButton#example:hover{border-color:#5cb85c}")
            b.clicked.connect(lambda _c=False, u=u: self.window.open_place(u["trail"], u["guid"]))
            self.form.addWidget(b)
        if len(others) > 12:
            self._label(f"... and {len(others) - 12} more", "hint")

    def _examples(self, kind):
        from . import block_examples
        ex = (block_examples.load() or {}).get(kind.id) or {}
        here = self.window.here()[0].path if self.window.trail else None
        items = [x for x in ex.get("examples") or [] if x["file"] != here][:3]
        if not items:
            return
        self._label(f"How the game uses it ({ex['count']} times in {ex['files']} quest files)", "section")
        for x in items:
            where = x["quest"] + (f" > {x['where']}" if x.get("where") else "")
            text = (f'"{x["name"]}" - ' if x.get("name") else "") + "; ".join(x.get("lines") or [])
            fm = QtGui.QFontMetrics(QtGui.QFont("Segoe UI", 8))
            width = max(160, self.viewport().width() - 60)
            b = QtWidgets.QPushButton(fm.elidedText(where, QtCore.Qt.ElideMiddle, width) + "\n" +
                                      fm.elidedText(text, QtCore.Qt.ElideRight, width))
            b.setObjectName("example")
            b.setStyleSheet("QPushButton#example{text-align:left;background:#1f1f23;border:1px solid #2c2c32;"
                            "color:#b8b8c0;padding:4px 6px;font:11px}QPushButton#example:hover{border-color:#d9a441}")
            b.setToolTip("Opens this place in the quest graph")
            b.clicked.connect(lambda _c=False, x=x: self.window.open_example(x))
            self.form.addWidget(b)

    # --- the journal entry a block names: picked from those the game's quests (and this file) name
    def _journal_fields(self, o):
        cf = ((self.catalog["classes"].get(o.cls) or {}).get("fields")) or {}
        names = [p.name for p in o.props or [] if p.type == "handle:CJournalPath"]
        return names + [k for k, f in cf.items() if f.get("type") == "handle:CJournalPath" and k not in names]

    def journal_entries(self):
        """The entries one can pick: this file's own (an own quest's journal), then the game's."""
        from . import journal_index as J
        e = self.window.here()[0]
        own = J.of_tree(e.tree, e.path)
        names = J.Names(self.window.depot)
        for x in own:
            x["label"], x["kind"] = names.label(x["chain"])
            x["here"] = True
        game = J.get(self.window.depot)["entries"]
        keys = {x["key"] for x in own}
        mine = []
        if getattr(e, "_own", None) and self.window.project_dir:     # the own quest: all its objectives
            for o in J.own_objectives(self.window.project_dir):
                mine.append({"key": "own:" + o["guid"], "label": o["caption"] or o["id"], "kind": "objective",
                             "here": True, "own_guid": o["guid"], "count": 0})
        return mine + own + [x for x in game if x["key"] not in keys]

    def _journal_row(self, n, key, o, label=None, fkey=None, edit=None):
        """The journal entry field `key` of object n: what it names, Choose (a search over the journal). label/fkey:
        its name on the card and in self.fields; edit: how a choice is written (the window's edit)."""
        from . import journal_index as J
        edit = edit or self.window.edit
        cur = o.get(key)
        text = "(none)"
        if isinstance(cur, int) and cur > 0:
            ch = J.chain(self.qf.tree, cur)
            label, kind = J.Names(self.window.depot).label(ch)
            here = self.window.here()[0]
            if getattr(here, "_own", None) and self.window.project_dir:      # the own quest's: its text
                mine = {o["guid"]: o for o in J.own_objectives(self.window.project_dir)}
                if ch and ch[-1][1] in mine:
                    label, kind = mine[ch[-1][1]]["caption"], "objective of this quest"
            text = f"{label}  ({kind})" if kind else label
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        lab = QtWidgets.QLabel(text)
        lab.setStyleSheet("color:#4fb3bf")
        lab.setWordWrap(True)
        h.addWidget(lab, 1)
        choose = QtWidgets.QPushButton("Choose")
        h.addWidget(choose)
        row = self._row(label or human(key), box)
        if fkey is None:
            self._outside_tick(row, n, key)
        holder = QtWidgets.QWidget()
        hv = QtWidgets.QVBoxLayout(holder)
        hv.setContentsMargins(0, 0, 0, 4)
        search = QtWidgets.QLineEdit()
        search.setPlaceholderText("Search the journal (quest, objective)")
        found = QtWidgets.QListWidget()
        found.setMaximumHeight(220)
        hv.addWidget(search)
        hv.addWidget(found)
        holder.hide()
        self.form.addWidget(holder)
        self.fields[fkey or (n, "journal:" + key)] = (choose, search, found)
        entries = []

        def fill(words):
            found.clear()
            ws = words.lower().split()
            shown = 0
            for e in entries:
                hay = (e["label"] + " " + e.get("kind", "")).lower()
                if all(w in hay for w in ws):
                    it = QtWidgets.QListWidgetItem(f"{e['label']}  ({e.get('kind') or '?'})" +
                                                   ("  (this quest)" if e.get("here") else ""))
                    it.setData(QtCore.Qt.UserRole, e)
                    found.addItem(it)
                    shown += 1
                    if shown >= 300:
                        break

        def open_():
            if not entries:
                entries.extend(self.journal_entries())
            holder.setVisible(not holder.isVisible())
            fill(search.text())
            search.setFocus()

        def pick(item):
            e = item.data(QtCore.Qt.UserRole)
            here = self.window.here()[0]
            if e.get("own_guid"):                       # an objective of the own quest: shaped like one it has
                from . import journal_index as J
                guids = {o["guid"] for o in J.own_objectives(self.window.project_dir)}
                model = next((x for x in J.of_tree(here.tree, here.path) if x["chain"][-1][1] in guids), None)
                if model is None:
                    self.window.state.setText("The quest has no objective in the graph yet to copy the shape from")
                    return
                edit(lambda ed: ed.set_journal_entry(n, key, ed.data, model["obj"], bytes.fromhex(e["own_guid"])))
                return
            src = here.data if e.get("here") else self.window.depot.read(e["file"])
            edit(lambda ed: ed.set_journal(n, key, src, e["obj"]))
        choose.clicked.connect(open_)
        search.textChanged.connect(fill)
        found.itemActivated.connect(pick)
        here = self.window.here()[0]
        if getattr(here, "_own", None) and self.window.project_dir:  # a new objective for the own quest
            row = QtWidgets.QWidget()
            h2 = QtWidgets.QHBoxLayout(row)
            h2.setContentsMargins(0, 0, 0, 0)
            new = QtWidgets.QLineEdit()
            new.setPlaceholderText("New objective")
            add = QtWidgets.QPushButton("Add")
            h2.addWidget(new, 1)
            h2.addWidget(add)
            hv.addWidget(row)
            self.fields[(n, "journal-new:" + key)] = (new, add)

            def made():
                text = new.text().strip()
                if not text:
                    return
                from .project import new_graph_objective
                new_graph_objective(self.window.project_dir, text)
                new.clear()
                self.window.state.setText(f"Objective '{text}' added. It is in the journal after the next build "
                                          f"(Build now: Build tab)")
            add.clicked.connect(made)
            new.returnPressed.connect(made)

    def _game_doc(self, o):
        cat = self.catalog
        if o.cls == blocks.S:
            f = cat["functions"].get(str(o.get("functionName"))) or {}
            return f"Calls the game's quest function {o.get('functionName')}" + \
                (f" ({f.get('script')})" if f.get("script") else "") + "."
        c = cat["classes"].get(o.cls) or {}
        return c.get("doc") or ""

    def _sub(self, head, n):
        """An object under the block: a condition, what it checks, an action - its own fields."""
        so = self.qf.tree.obj(n)
        from .game_catalog import label
        self._label(f"{head}: {label(so.cls)}", "section")
        text = blocks.condition_text(self.qf, n) if "Condition" in so.cls or so.cls.startswith(("W3QuestCond",
                                                                                                 "CQC")) else ""
        if text:
            self._label(text, "hint")
        self._fields(n, so, None)
        self._structs(n, so)
        self._objects(n, so)

    # --- the objects a block is built of: each one's kind chosen, its fields, a list's items added and removed
    def _object_fields(self, o):
        """[(field, type, value)] of an object's fields that hold objects (a time function, conditions ...)."""
        cf = ((self.catalog["classes"].get(o.cls) or {}).get("fields")) or {}
        out, seen = [], set()
        for p in o.props or []:
            if object_type(p.type):
                out.append((p.name, p.type, p.value))
                seen.add(p.name)
        for name, f in cf.items():
            if name not in seen and object_type(f.get("type") or ""):
                out.append((name, f["type"], None))
        return out

    def candidates(self, cls, field, typ):
        """The classes an object field can hold: those the game puts there, the most used first."""
        cat = self.catalog["classes"]
        f = ((cat.get(cls) or {}).get("fields") or {}).get(field) or {}
        out = [v[2:] for v, _c in f.get("values") or [] if str(v).startswith("→ ")]
        role = "condition" if "IQuestCondition" in typ else "ai" if "IAIAction" in typ else f"part of {cls}"
        more = sorted((k for k, c in cat.items() if c.get("role") == role or role in (c.get("roles") or {})),
                      key=lambda k: -(cat[k].get("count") or 0))
        return out + [k for k in more if k not in out]

    def _objects(self, n, o):
        from .game_catalog import label
        for field, typ, value in self._object_fields(o):
            head = OBJECT_HEADS.get(field, human(field))
            opts = self.candidates(o.cls, field, typ)
            if typ.startswith("array:"):
                items = [(k, v) for k, v in enumerate(value or []) if isinstance(v, int)]
                self._label(f"{head} ({len(items)})", "section")
                for k, c in items:                      # (k: its place in the list - an empty one counts)
                    if c > 0:
                        self._sub(f"{k + 1}", c)
                    else:
                        self._label(f"{k + 1}: (empty)", "hint")
                    rm = QtWidgets.QPushButton("Remove")
                    rm.setObjectName("more")
                    rm.clicked.connect(lambda _c=False, k=k, field=field: self.window.edit(
                        lambda e: e.remove_object_item(n, field, k)))
                    self.form.addWidget(rm)
                add = QtWidgets.QComboBox()
                add.addItem("Add ...")
                for c in opts:
                    add.addItem(label(c), c)
                add.activated.connect(lambda i, add=add, field=field, typ=typ: i and self.window.edit(
                    lambda e: e.add_object_item(n, field, add.itemData(i), typ)))
                self.fields[(n, "add:" + field)] = add
                self._row("", add)
            else:
                cur = self.qf.tree.obj(value).cls if isinstance(value, int) and value > 0 else None
                pick = QtWidgets.QComboBox()
                pick.addItem("(none)", None)
                for c in ([cur] if cur and cur not in opts else []) + opts:
                    pick.addItem(label(c), c)
                pick.setCurrentIndex(max(0, pick.findData(cur)))
                pick.activated.connect(lambda i, pick=pick, field=field, typ=typ: self.window.edit(
                    lambda e: e.set_object(n, field, pick.itemData(i), typ)))
                self.fields[(n, "object:" + field)] = pick
                self._label(head, "section")
                self._row("Kind", pick)
                if cur:
                    self._fields(value, self.qf.tree.obj(value), None)
                    self._objects(value, self.qf.tree.obj(value))

    # --- fields
    def _known_fields(self, o):
        """[(name, type, value or None, hint, default, values the game uses)] of an object: what it has, then what
        its class can have (the catalog) at the default."""
        from .game_catalog import default_of
        cls = self.catalog["classes"].get(o.cls) or {}
        cf = cls.get("fields") or {}
        out, seen = [], set()
        for p in o.props or []:
            a_file = p.type.startswith(("soft:", "handle:")) and (isinstance(p.value, Soft) or (
                isinstance(p.value, int) and not isinstance(p.value, bool) and p.value < 0))
            if p.name in QUIET or not (editable_type(p.type) or a_file):
                continue
            seen.add(p.name)
            f = cf.get(p.name) or {}
            out.append((p.name, p.type, p.value, f.get("hint"), default_of(self.catalog, o.cls, p.name),
                        f.get("values") or [], True))
        total = max(cls.get("count") or 1, 1)
        for name, f in cf.items():
            if name in seen or name in QUIET or not editable_type(f.get("type") or ""):
                continue
            common = (f.get("count") or 0) / total >= 0.2     # most blocks of the kind set it: in front
            out.append((name, f["type"], None, f.get("hint"), default_of(self.catalog, o.cls, name),
                        f.get("values") or [], common))
        return out

    def _name_field(self, o, n):
        if o.cls in ("CQuestPhaseInputBlock", "CQuestPhaseOutputBlock"):
            return
        p = o.prop("name")
        typ = p.type if p is not None else "String"
        row = self._row("Name", self._line(str(o.get("name") or ""), "what you call this block in the graph",
                                           lambda text: self.window.edit(lambda e: e.set_field(n, "name", text,
                                                                                                typ))))
        self.fields[(n, "name")] = row.field

    # --- values made of parts (a book's item name, a scene's definition, a fist fight's opponents)
    def _structs(self, n, o):
        for p in o.props or []:
            if p.name in QUIET:
                continue
            if isinstance(p.value, Struct) and p.type not in VECTOR and p.type != "GameTime" and                     struct_simple(p.value):
                self._label(human(p.name), "section")
                self._struct_rows(n, [p.name], p.value)
            elif p.type.startswith("array:2,0,") and not editable_type(p.type) and not object_type(p.type) and                     all(isinstance(x, Struct) and struct_simple(x) for x in p.value or []):
                self._label(f"{human(p.name)} ({len(p.value or [])})", "section")
                for k, x in enumerate(p.value or []):
                    self._struct_rows(n, [p.name, k], x, prefix=f"{k + 1}. ")
                    rm = QtWidgets.QPushButton("Remove")
                    rm.setObjectName("more")
                    rm.clicked.connect(lambda _c=False, k=k, name=p.name: self.window.edit(
                        lambda e: e.remove_item(n, [name, k])))
                    self.form.addWidget(rm)
                add = QtWidgets.QPushButton("Add")
                add.setObjectName("more")
                add.clicked.connect(lambda _c=False, name=p.name: self.window.edit(lambda e: e.add_item(n, [name])))
                self.form.addWidget(add)

    def _struct_rows(self, n, path, value, prefix=""):
        for q in value:
            if isinstance(q.value, list) and not isinstance(q.value, Tags):      # (a curve's points ...)
                lab = QtWidgets.QLabel(f"{len(q.value)} items (see All values)")
                self._row(prefix + human(q.name), lab)
                continue
            if isinstance(q.value, Struct) and q.type not in VECTOR and q.type != "GameTime":
                self._struct_rows(n, path + [q.name], q.value, prefix + human(q.name) + " > ")
                continue

            def write(v, at=path + [q.name]):
                self.window.edit(lambda e: e.set(n, at, v))
            w = self._leaf(q.type, q.value, write)
            self.fields[(n, "/".join(str(x) for x in path + [q.name]))] = w
            self._row(prefix + human(q.name), w)

    def _leaf(self, typ, value, write):
        """A field for one part of a value (written by its path)."""
        if typ == "Bool":
            w = QtWidgets.QCheckBox()
            w.setChecked(bool(value))
            w.toggled.connect(lambda on: write(bool(on)))
            return w
        if is_enum(typ):
            from .game_catalog import enum_values
            w = QtWidgets.QComboBox()
            opts = enum_values(self.catalog, typ, [value])
            w.addItems([str(x) for x in opts if x is not None])
            w.setCurrentText(str(value))
            w.currentTextChanged.connect(lambda text: write(text))
            return w
        if typ in INTS or typ in ("Float", "Double"):
            return self._line(item_text(value), "", lambda text: self._number(write, typ, text))
        if typ == "TagList":
            return self._line(", ".join(value or []), "tags, comma separated",
                              lambda text: write(Tags(x.strip() for x in text.split(",") if x.strip())))
        if isinstance(value, Soft) or typ.startswith(("soft:", "handle:")):
            return QtWidgets.QLabel(self.qf.import_path(value) or "(none)")
        return self._line(str(value if value is not None else ""), "", lambda text: write(text))

    def _fields(self, n, o, title):
        """The object's fields: those its file has, then the rest of its class (at the default) behind
        'More settings'."""
        rows = self._known_fields(o)
        if title and rows:
            self._label(title, "section")
        more = []
        for name, typ, value, hint, default, values, common in rows:
            w = self._field(n, name, typ, value, default, values)
            self.fields[(n, name)] = w
            row = self._row(human(name), w, hint)
            self._outside_tick(row, n, name)
            if not common:
                more.append(row)
        if more:
            toggle = QtWidgets.QPushButton(f"More settings ({len(more)})")
            toggle.setObjectName("more")
            toggle.setCheckable(True)
            at = self.form.indexOf(more[0])
            self.form.insertWidget(at, toggle)
            for row in more:
                row.setVisible(False)
            toggle.toggled.connect(lambda on, more=more: [r.setVisible(on) for r in more])

    # --- custom blocks: their fields outside, the ticks inside that choose them
    def _custom(self, n, o):
        from . import custom_blocks as CB
        tree = self.qf.tree
        guid = bytes(o.get("guid")).hex() if o.get("guid") is not None else ""
        inst = self.window.instances()
        fields = CB.exposed_of(inst, tree, n, guid)
        tpl = CB.by_id(inst.get(guid).get("template")) if inst.get(guid).get("template") else None
        if tpl:
            self._label(f"Template: {tpl['label']}" + (f" - {tpl['text']}" if tpl.get("text") else ""), "hint")
        self._set_here(n, fields, lambda f: CB.resolve(tree, n, f), lambda e, f: CB.mirror(e, n, f))
        save = QtWidgets.QPushButton("Save as template")
        save.setToolTip("Keeps this block as a block of the sidebar (everything inside, the fields shown outside)")
        save.clicked.connect(lambda _c=False: self._save_template(n, o, fields))
        self.fields[(n, "save template")] = save
        self._row("", save)

    def _set_here(self, n, fields, where_of, mirror):
        """A template's fields, as rows: "Set it here". where_of(field) -> (object, name) | None; mirror(editor,
        field) writes a field's value into the other places it sets (in the same undo)."""
        tree = self.qf.tree
        if fields:
            self._label("Set it here", "section")
        for f in fields:
            where = where_of(f)
            if where is None:
                self._label(f"{f['label']}: (no longer inside)", "hint")
                continue
            obj, name = where
            so = tree.obj(obj)
            p = so.prop(name)
            cf = ((self.catalog["classes"].get(so.cls) or {}).get("fields") or {}).get(name) or {}
            typ = p.type if p is not None else cf.get("type") or "String"

            def edit(fn, f=f):                          # (and the places it sets as well: one undo)
                return self.window.edit(lambda e: e.batch(lambda e2: (fn(e2), mirror(e2, f))[0]))
            if typ == "handle:CJournalPath":            # an objective: chosen from the journal
                self._journal_row(obj, name, so, f["label"], (n, "outside:" + f["label"]), edit)
                continue
            from .game_catalog import default_of
            w = self._field(obj, name, typ, p.value if p is not None else None, default_of(self.catalog, so.cls, name),
                            cf.get("values") or [], edit)
            self.fields[(n, "outside:" + f["label"])] = w
            self._row(f["label"], w, f"in: {so.cls}.{name}")

    def _folded(self):
        """A template's block the translator shows (blocks of the game wired as the template is inside): what it
        does, its values - set here, in those blocks -, its blocks; "Show its blocks" opens it up."""
        from . import translator as T
        from . import vanilla_graph as V
        b, tree = self.b, self.qf.tree
        m = b.match
        tpl = m["shape"]["tpl"]
        bar = QtWidgets.QFrame()
        bar.setFixedHeight(3)
        bar.setStyleSheet(f"background:{V.FAMILY['template']}")
        self.form.addWidget(bar)
        self._label(tpl["label"], "kind")
        self._label(tpl.get("text") or "", "what")
        self._label(f"Template: {len(m['blocks'])} game blocks shown as one (the file stays unchanged)", "hint")
        if b.name:
            self._label(f"Named: {b.name}", "hint")
        guids = [bytes(tree.obj(x).get("guid")) for x in m["blocks"]]
        self._set_here(b.n, tpl.get("exposed") or [], lambda f: T.resolve(tree, m, f),
                       lambda e, f: T.mirror(e, guids, m["shape"], f))
        unfold = QtWidgets.QPushButton("Show its blocks")
        unfold.setToolTip("The game's blocks it is made of, each on its own (double click does the same)")
        unfold.clicked.connect(lambda _c=False: self.window.unfold(b.n))
        self.fields[(b.n, "unfold")] = unfold
        self._row("", unfold)
        for x in m["blocks"]:                           # the facts its blocks set or wait for: where else
            self._fact_refs(x)
        self._label("Its blocks", "section")
        e, qf, gn = self.window.here()
        g = qf.graph(gn)
        for x in m["blocks"]:
            bx = g.blocks.get(x)
            if bx is not None:
                self._label(f"{bx.title}" + (f" - {bx.lines[0]}" if bx.lines else ""), "hint")

    def _save_template(self, n, o, fields, label=None):
        from . import custom_blocks as CB
        if label is None:
            label, ok = QtWidgets.QInputDialog.getText(self, "Save as template", "Its name in the sidebar:",
                                                       text=str(o.get("name") or "My block"))
            if not ok or not label.strip():
                return None
        tpl = CB.save_template(self.window.here()[0], n, label.strip(), str(o.get("comment") or ""), fields)
        guid = bytes(o.get("guid")).hex() if o.get("guid") is not None else ""
        self.window.instances().set(guid, template=tpl["id"])
        self.window.palette.fill()
        self.window.state.setText(f"'{tpl['label']}' is now a block of the sidebar (Blocks)")
        return tpl

    def _outside_tick(self, row, obj, name):
        """Inside a custom block: a tick that shows this field on the custom block's card outside."""
        from . import custom_blocks as CB
        outer = self.window.inside_custom()
        if outer is None or self.b is None:
            return
        tree = self.qf.tree
        blocks_in = CB.inside(tree, outer)
        if self.b.n not in blocks_in:
            return
        path = CB.path_to(tree, self.b.n, obj)
        if path is None:
            return
        field = {"label": human(name), "block": blocks_in.index(self.b.n), "path": path, "name": name}
        og = tree.obj(outer).get("guid")
        guid = bytes(og).hex() if og is not None else ""
        inst = self.window.instances()

        def same(f):
            return (f["block"], list(f.get("path") or []), f["name"]) == (field["block"], path, name)
        tick = QtWidgets.QCheckBox("outside")
        tick.setToolTip("Shows this field on the custom block's card (whoever uses the block sets it there)")
        tick.setChecked(any(same(f) for f in CB.exposed_of(inst, tree, outer, guid)))

        def toggled(on):
            now = [f for f in CB.exposed_of(inst, tree, outer, guid) if not same(f)]
            inst.set(guid, exposed=now + ([field] if on else []))
        tick.toggled.connect(toggled)
        row.layout().addWidget(tick)
        self.fields[(obj, "outside:" + name)] = tick

    def _row(self, text, widget, hint=None):
        """A label and its field in a row. -> the row."""
        row = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(row)
        h.setContentsMargins(0, 0, 0, 0)
        lab = QtWidgets.QLabel()
        lab.setFixedWidth(132)
        lab.setText(lab.fontMetrics().elidedText(text, QtCore.Qt.ElideRight, 128))
        lab.setToolTip(text + (f": {hint}" if hint else ""))
        h.addWidget(lab)
        h.addWidget(widget, 1)
        self.form.addWidget(row)
        if hint:
            widget.setToolTip(hint)
        row.field = widget
        return row

    def _line(self, text, placeholder, done, values=()):
        w = QtWidgets.QLineEdit(text)
        w.setPlaceholderText(placeholder)
        if values:
            comp = QtWidgets.QCompleter([str(v) for v in values], w)
            comp.setCaseSensitivity(QtCore.Qt.CaseInsensitive)
            comp.setFilterMode(QtCore.Qt.MatchContains)
            w.setCompleter(comp)
        start = text

        def finished():
            if w.text() != start:
                done(w.text())
        w.editingFinished.connect(finished)
        return w

    def _field(self, n, name, typ, value, default, values, edit=None):
        """A field for one value; a change written through the window's editor (or `edit`)."""
        seen = [v for v, _c in values if v not in ("", None)]
        edit = edit or self.window.edit

        def write(v):
            edit(lambda e: e.set_field(n, name, v, typ))
        if typ in ("Bool", "bool"):
            w = QtWidgets.QCheckBox()
            cur = value if value is not None else bool(default)
            w.setChecked(bool(cur))
            if value is None:
                w.setText("(default)")
            w.toggled.connect(lambda on: write(bool(on)))
            return w
        if is_enum(typ):
            from .game_catalog import enum_values
            opts = enum_values(self.catalog, typ, seen)
            w = QtWidgets.QComboBox()
            cur = value if value is not None else (default or (opts[0] if opts else ""))
            if cur and cur not in opts:
                opts = [cur] + opts
            w.addItems(opts)
            w.setCurrentText(str(cur))
            if value is None:
                w.setToolTip("At the game's default")
            w.currentTextChanged.connect(lambda text: write(text))
            return w
        if typ in INTS or typ in ("Float", "Double"):
            shown = "" if value is None else (f"{value:g}" if isinstance(value, float) else str(value))
            w = self._line(shown, f"default {default:g}" if isinstance(default, (int, float)) and
                           not isinstance(default, bool) else "the game's default",
                           lambda text: self._number(write, typ, text), seen)
            w.setValidator(QtGui.QDoubleValidator() if typ in ("Float", "Double") else QtGui.QIntValidator())
            return w
        if typ == "TagList":
            return self._line(", ".join(value or []), "tags, comma separated",
                              lambda text: write(Tags(x.strip() for x in text.split(",") if x.strip())), seen)
        if typ.startswith("array:2,0,"):
            inner = typ[10:]
            return self._line(", ".join(item_text(x) for x in value or []),
                              "comma separated" + (" (yes / no)" if inner == "Bool" else ""),
                              lambda text: write([item(inner, x) for x in text.split(",") if x.strip()]), seen)
        if typ == "EngineTransform":
            from .cr2w_tree import Transform
            shown = "" if value is None else transform_text(value)

            def tf(text):
                write(transform(text))
            return self._line(shown, "x, y, z; pitch, yaw, roll; scale x, y, z", tf)
        if typ == "GameTime":
            from .cr2w_tree import Prop, Struct
            secs = next((p.value for p in value or [] if p.name == "m_seconds"), 0) if value is not None else None
            shown = "" if secs is None else game_time_text(secs)

            def gt(text):
                write(Struct([Prop("m_seconds", "Int32", game_time(text))]))
            return self._line(shown, "hh:mm (a day more: 1d 08:00)", gt)
        if typ in VECTOR:
            from .cr2w_tree import Prop, Struct
            keys = VECTOR[typ]
            have = {p.name: p.value for p in value} if value is not None else {}
            shown = ", ".join(f"{have.get(k, 0.0):g}" for k in keys) if value is not None else ""

            def vec(text):
                nums = [float(x) for x in re.split(r"[,;\s]+", text.strip()) if x]
                write(Struct([Prop(k, "Float", nums[i] if i < len(nums) else 0.0) for i, k in enumerate(keys)]))
            return self._line(shown, ", ".join(k.lower() for k in keys), vec)
        if typ.startswith(("soft:", "handle:")):
            path = self.qf.import_path(value) if value else ""
            cls = typ.split(":", 1)[1]
            return self._line(path or "", "a file of the game",
                              lambda text: self._ref(n, name, typ, cls, value, text.strip(), edit),
                              self.game_files(cls) or seen)
        return self._line("" if value is None else str(value), "", lambda text: write(text), seen)

    def game_files(self, cls):
        """Every file of the game of a kind (a scene, a community, a phase ...) - offered when one is typed."""
        ext = FILE_EXT.get(cls)
        if not ext:
            return []
        if ext not in _FILES:
            _FILES[ext] = sorted(p for p in self.window.depot.where if p.endswith(ext))
        return _FILES[ext]

    @staticmethod
    def _number(write, typ, text):
        text = text.strip().replace(",", ".")
        if not text:
            return
        write(float(text) if typ in ("Float", "Double") else int(float(text)))

    def _ref(self, n, name, typ, cls, old, path, edit=None):
        def fn(e):
            o = e.tree.obj(n)
            if o.prop(name) is None:
                e.set_field(n, name, Soft(0) if typ.startswith("soft:") else 0, typ)
            e.set_ref(n, [name], path, cls)
        (edit or self.window.edit)(fn)

    def _params(self, n, o):
        """A game function's values: each parameter, typed as the scripts declare it."""
        f = self.catalog["functions"].get(str(o.get("functionName"))) or {}
        sig = {p["name"]: p for p in f.get("params") or []}
        params = o.get("parameters") or []
        if not params:
            return
        self._label("Values", "section")
        for p in params:
            pname, v = p.get("name"), p.get("value")
            typ = v.type if isinstance(v, Variant) else "CName"
            val = v.value if isinstance(v, Variant) else v
            s = sig.get(pname) or {}
            seen = [x for x, _c in s.get("values") or [] if x not in ("", None)]

            def write(value, pname=pname):
                self.window.edit(lambda e: e.set_param(n, pname, value))
            if typ == "Bool":
                w = QtWidgets.QCheckBox()
                w.setChecked(bool(val))
                w.toggled.connect(lambda on, write=write: write(bool(on)))
            elif is_enum(typ):
                w = QtWidgets.QComboBox()
                opts = list(self.catalog["enums"].get(typ) or []) or seen
                if val not in opts:
                    opts = [str(val)] + opts
                w.addItems(opts)
                w.setCurrentText(str(val))
                w.currentTextChanged.connect(lambda text, write=write: write(text))
            elif typ in INTS or typ in ("Float", "Double"):
                w = self._line(f"{val:g}" if isinstance(val, float) else str(val), "",
                               lambda text, write=write, typ=typ: self._number(write, typ, text), seen)
            else:
                w = self._line(str(val if val is not None else ""), "",
                               lambda text, write=write: write(text), seen)
            self.fields[(n, "param:" + pname)] = w
            self._row(human(pname), w, f"{s.get('type', typ)}" + (" (optional)" if s.get("optional") else ""))
