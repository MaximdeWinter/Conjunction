"""The Quest tab: the quest as a graph (docs/quest-graph.md) - the sidebar's blocks, the graph (graph_view), and
under it the card of the node picked.

Every step is one block: a goal (what the player does: talk, go to, find, kill, collect ...; its journal line and
map marker), an action (what happens: a reward, a door, a journal note ...), a choice, a lane, a chapter, an end. A
list of steps keeps them in order; the story is one list, every path another. Decisions: a step can lead into paths
(a dialogue answer, a choice's way, a lost game); at its end a path goes back to the story (after the step that
split) or ends the quest.

Every change is saved at once and the graph is built anew. The board works on the step dicts themselves (a card
changes its dict), on the lists only to put steps in, move and remove them (the _graph_* methods).
"""
import os
import zlib

from PySide6 import QtCore, QtWidgets

from . import theme
from .tooltips import tip
from .inline_menu import Combo, attach
from . import graph_layout as L
from .dialogue import walk as D_walk
from . import quest_nodes as QN

Q = QtCore.Qt
# goals: what the player does (the objective waits for it)
GOALS = [("talk", "Talk", "npc"), ("goto", "Go to", "place"), ("loot", "Loot", "object"),
         ("examine", "Examine", "object"), ("use", "Use", "object"), ("kill", "Kill", "target"),
         ("defeat", "Defeat", "target"), ("gwent", "Gwent", "deck"), ("fistfight", "Fist fight", "targets"), ("deliver", "Deliver", "npc"), ("read", "Read", "item"),
         ("notice", "Notice", "board"),
         ("collect", "Collect", "item"), ("equip", "Equip", "item"), ("clues", "Find clues", "clues"), ("follow", "Follow", "who"),
         ("wait", "Wait", "time"), ("waitfact", "Wait until", "fact"), ("waitfor", "Wait for", "what"),
         ("race", "Race", "path"),
         ("either", "Either / or", "options"),
         ("all", "All of these", "options")]
# actions: what happens (no objective of their own)
ACTIONS = [("say", "Says", "text"), ("show", "Show place", "place"), ("hide", "Hide place", "place"),
           ("reward", "Reward", "reward"), ("item", "Item", "item"), ("note", "Journal note", "text"),
           ("hostile", "Hostile", "target"), ("immortal", "Immortal", "target"), ("door", "Door", "target"), ("switch", "Switch", "target"), ("lock", "Lock", "target"),
           ("effect", "Effect", "target"), ("sound", "Sound", "event"), ("fade", "Fade", "fade"),
           ("shake", "Camera shake", "strength"), ("weather", "Weather", "weather"), ("time", "Time of day", "at"),
           ("teleport", "Teleport", "pos"), ("travel", "Travel", "pos"), ("playas", "Play as", "as"),
           ("portal", "Portal", "a"), ("lights", "Lights", "target"), ("presence", "Hide object", "target"),
           ("encounters", "Creatures nearby", "pos"),
           ("message", "Message", "text"), ("autosave", "Autosave", "none"),
           ("person", "Journal entry", "who"), ("walk", "Walk to", "who"), ("patrol", "Patrol", "who"),
           ("stands", "Stands", "who"), ("meanwhile", "Parallel track", "path"), ("stop", "Stop track", "path"),
           ("random", "At random", "ways"),
           ("tutorial", "Tutorial", "text"), ("game", "Game function", "function"),
           ("fact", "Set fact", "fact"), ("worldchange", "Change world", "change"),
           ("goaway", "Goes away", "who"), ("health", "Health", "who"), ("target", "Attacks", "who"),
           ("notalk", "No talking", "who"), ("look", "Change look", "who"), ("shop", "Merchant", "who"),
           ("bossbar", "Boss health bar", "who"), ("weapon", "Draw weapon", "weapon"),
           ("controls", "Block controls", "what"), ("timelapse", "Time passes", "text"),
           ("highlight", "Highlight", "target")]
WAIT_FOR = [("combat", "a fight starts"), ("peace", "the fight is over"), ("senses", "the witcher senses"),
            ("health", "the player's health is down to")]
WEATHERS = ["WT_Clear", "WT_Light_Clouds", "WT_Mid_Clouds", "WT_Mid_Clouds_Dark", "WT_Heavy_Clouds",
            "WT_Heavy_Clouds_Dark", "WT_Rain_Storm", "WT_Fog", "WT_Snow", "WT_Blizzard", "WT_Wild_Hunt"]
# + then: the actions by what they touch
# the goals by family - the colour each has in the graph
GOAL_GROUPS = [("People", ["talk", "deliver", "follow"]), ("Places", ["goto", "wait", "waitfact", "waitfor"]),
               ("Things", ["loot", "examine", "use", "collect", "equip", "read", "notice", "clues"]),
               ("Fights and games", ["kill", "defeat", "fistfight", "gwent", "race"]), ("Combined", ["all"])]
ACTION_GROUPS = [("Player", ["say", "reward", "item", "teleport", "travel", "playas", "portal", "weapon",
                            "controls"]),
                 ("People", ["hostile", "immortal", "walk", "stands", "patrol", "person", "presence", "goaway",
                             "health", "target", "notalk", "look", "shop", "bossbar"]),
                 ("World", ["show", "hide", "door", "lock", "switch", "lights", "effect", "sound", "encounters",
                            "worldchange", "highlight"]),
                 ("Mood", ["fade", "shake", "weather", "time"]),
                 ("Screen", ["note", "message", "tutorial", "autosave", "timelapse"]),
                 ("Advanced", ["random", "meanwhile", "stop", "fact", "game"])]
GOAL_KINDS = {k for k, _l, _f in GOALS} - {"deliver"}       # deliver makes a talk
LABEL = {k: lab for k, lab, _f in GOALS + ACTIONS}
PERSON_ACTIONS = ("goaway", "health", "target", "notalk", "look", "shop", "bossbar")
EITHER_KINDS = [("goto", "Go to"), ("loot", "Loot"), ("examine", "Examine"), ("use", "Use"), ("kill", "Kill")]
QUEST_TYPES = [("main", "Main quest"), ("secondary", "Side quest"), ("monsterhunt", "Contract"),
               ("treasurehunt", "Treasure hunt")]
TALK_STARTS = [("interact", "On interaction (E)"), ("near", "When the player is near"),
               ("overhear", "Overheard (the player listens)"),
               ("calls", "NPC calls out"), ("now", "Immediately (cutscene)")]
QUEST_STARTS = [("at_once", "Immediately"), ("after_first", "After step 1")]
IMMORTAL = [("immortal", "Immortal"), ("unconscious", "Knocked out, not killed"), ("off", "Mortal")]
DOOR = [("open", "opens"), ("close", "closes"), ("lock", "locks"), ("unlock", "unlocks")]
SWITCH = [("on", "on"), ("off", "off"), ("lock", "locked"), ("unlock", "unlocked")]
LIGHTS = [("on", "on"), ("off", "off")]
PRESENCE = [("hide", "hidden"), ("show", "shown again")]
ENCOUNTERS = [("off", "off"), ("on", "back on")]
WORLDCHANGE = [("on", "from here on"), ("off", "ends here")]
FADE_COLORS = [("black", "black"), ("white", "white")]
# actions on one placed thing or person: what the card misses while it is empty
TARGET_ACTIONS = {"hostile": "character", "immortal": "character", "presence": "object", "door": "object",
                  "switch": "object", "lights": "object", "lock": "object", "effect": "object"}
CIRI_LOOKS = [("", "Default"), ("wounded", "wounded"), ("winter", "winter clothes"), ("naked", "naked")]
USE_HOW = [("", "used"), ("on", "switched on"), ("off", "switched off"), ("item", "item used on it")]
CARD_MENU = [("test", "Play from here"), ("copy", "Duplicate"), ("remove", "Remove")]
PATH_ENDS = [("join", "Rejoin story"), ("success", "End quest: success"),
             ("fail", "End quest: failure")]
UNDONE = ("quest", "swaps", "cutscene_swaps")          # what Ctrl+Z on the board takes back
# a path's own colour (its wires, its nodes' left edge) - apart from the colours that say what a node is (the
# families of quest_graph.FAMILY: blue, green, yellow, red, purple, teal, pink)
PATH_COLORS = ["#e0915f", "#8fa3e8", "#d9a45b", "#aebd5f", "#cdb28a", "#c98f86", "#7fb3c2", "#b0a8d8"]

STYLE = """
QPlainTextEdit#autotext{color:#e6e6e6;background:#1d1d20;border:1px solid #444;font:13px}
#card{background:#26262a;border:1px solid #3c3c42;border-radius:0}
#card QLabel#num{color:#f0f0f0;font:bold 15px;min-width:22px}
#card QLabel#kind{color:#9a9a9a;font:bold 11px}
#card QToolButton#kindmenu{color:#9a9a9a;font:bold 11px;background:transparent;border:1px solid transparent;padding:1px 4px}
#card QToolButton#kindmenu:hover{color:#ddd;border-color:#666}
#card QToolButton#kindmenu::menu-indicator{image:none;width:0}
QLabel#then{color:#8a8a8a;font:11px}
QLabel#field{color:#999;font:12px}
QPushButton#small{padding:2px 8px;font:12px}
QPushButton#plus{color:#9a9a9a;background:transparent;border:1px dashed #444;padding:3px;font:12px}
QPushButton#plus:hover{color:#eee;border-color:#888}
QToolButton#plus{color:#9a9a9a;background:transparent;border:1px dashed #444;padding:3px 8px;font:12px}
QToolButton#plus:hover{color:#eee;border-color:#888}
QToolButton#plus::menu-indicator{image:none;width:0}
QToolButton#chip{color:#cfcfcf;background:#262629;border:1px solid #555;border-radius:0;padding:2px 8px;font:12px}
QToolButton#chip:checked{color:#fff;background:#4b4b50;border-color:#c8c8c8}
QPushButton#more{color:#8a8a8a;background:transparent;border:none;padding:0 2px;font:11px;text-align:left}
QPushButton#more:hover{color:#ddd}
QPushButton#target{text-align:left;color:#eee;background:#262629;border:1px solid #555;border-radius:0;
padding:3px 10px;font:bold 12px}
QPushButton#target:hover,QPushButton#target_empty:hover{border-color:#999}
QPushButton#target_empty{text-align:left;color:#aaa;background:#1f1f22;border:1px dashed #666;border-radius:0;
padding:3px 10px;font:12px}
QToolButton#menu{color:#ddd;background:#262629;border:1px solid #555;border-radius:0;padding:2px 8px;font:12px}
QToolButton#menu:hover{border-color:#aaa}
QToolButton#menu::menu-indicator{image:none;width:0}
"""


def step_kind(step):
    kind, args = next(iter(step.items()))
    if not isinstance(args, dict):
        args = {}
        step[kind] = args
    return kind, args


def forks(step):
    """The paths a step leads into, in order: its dialogue's answers, its Either options."""
    kind, a = step_kind(step)
    out = []
    if kind == "talk":
        from . import dialogue as D
        for x in D.walk(D.from_step(a)):
            e = str(x.get("end", ""))
            if "who" not in x and e.startswith("path:") and e[5:] not in out:
                out.append(e[5:])
    elif kind == "either":
        for o in a.get("options") or []:
            if o.get("path") and o["path"] not in out:
                out.append(o["path"])
    elif kind == "meanwhile" and a.get("path"):
        out.append(a["path"])
    elif kind == "random":
        for w in a.get("ways") or []:
            if w.get("path") and w["path"] not in out:
                out.append(w["path"])
    elif kind in ("gwent", "fistfight") and str(a.get("lost", "")).startswith("path:"):
        out.append(a["lost"][5:])
    return out


def missing(kind, a):
    """What a step still needs before it can be built (nouns: the card shows them after the octagon)."""
    out = []
    if kind in ("goal", "action", "choice", "parallel"):
        return ["step type"]                 # a block of the graph not told yet
    if kind == "if" and not (a.get("path") or a.get("fact") or a.get("conditions")):
        out.append("condition")
    if kind in ("talk", "defeat") and not a.get("npc" if kind == "talk" else "target"):
        out.append("character")
    if kind in ("loot", "examine", "use") and not a.get("object"):
        out.append("object")
    if kind == "kill" and not ([t for t in a.get("targets") or [] if t] or a.get("target")):
        out.append("character")
    if kind == "goto" and a.get("mode") in ("near", "look"):
        if not a.get("who"):
            out.append("character")
    elif kind == "goto" and not (a.get("place") or a.get("pos") or a.get("at")):
        out.append("location")
    if kind == "say" and "who" in a and not a.get("who"):
        out.append("character")
    if kind == "follow" and not a.get("who"):
        out.append("character")
    if kind == "portal" and not a.get("a"):
        out.append("portal object")
    if kind == "portal" and not a.get("b_exit"):
        out.append("destination")
    if kind == "portal" and a.get("two_way") and not (a.get("b") and a.get("a_exit")):
        out.append("way back")
    if kind == "travel" and not a.get("pos"):
        out.append("destination")
    if kind in TARGET_ACTIONS and not a.get("target"):
        out.append(TARGET_ACTIONS[kind])
    if kind == "encounters" and not a.get("pos"):
        out.append("location")
    if kind == "playas" and not a.get("as"):
        out.append("character")
    if kind == "gwent" and not a.get("deck"):
        out.append("deck")
    if kind == "race" and len([p for p in a.get("path") or [] if p]) < 2:
        out.append("course")
    if kind == "race" and not [r for r in a.get("racers") or [] if r]:
        out.append("racers")
    if kind == "fistfight" and not [t for t in a.get("targets") or [] if t]:
        out.append("opponent")
    if kind in ("meanwhile", "stop") and not a.get("path"):
        out.append("track")
    if kind == "stands" and not a.get("who"):
        out.append("character")
    if kind == "stands" and not a.get("pos"):
        out.append("location")
    if kind == "waitfact" and not a.get("fact") and not a.get("conditions"):
        out.append("fact")
    if kind == "game":
        from . import game_functions as G
        fn = a.get("function")
        if not fn:
            out.append("function")
        elif fn in G.functions():
            args = a.get("args") or {}
            out += [n for n, t, o in G.functions()[fn]["params"]
                    if not o and G.kind(t) in ("name", "string") and not args.get(n)]
    if kind == "follow" and not a.get("path"):
        out.append("route")
    if kind in ("collect", "read", "equip") and not a.get("item"):
        out.append("item")
    if kind == "notice" and not a.get("board"):
        out.append("notice board")
    if kind == "collect" and a.get("item") and not a.get("from"):
        out.append("item source")
    if kind == "collect" and a.get("item") and a.get("from") in ("container", "person") and not a.get("in"):
        out.append("container" if a["from"] == "container" else "carrier")
    if kind == "clues" and not [c for c in a.get("clues") or [] if c.get("object") or c.get("trail")]:
        out.append("clues")
    if kind == "talk":
        from . import dialogue as D
        for x in D.walk(D.from_step(a)):
            if (x.get("give") or {}).get("item") == "":
                out.append("item to hand over")
                break
    if kind == "talk" and a.get("start") == "overhear":
        from . import dialogue as D
        if any("choice" in x for x in D.from_step(a)):
            out.append("lines only, no choices")
    if kind in ("either", "all"):
        for o in a.get("options") or []:
            gk, ga = step_kind(o.get("goal") or {"goto": {}})
            if missing(gk, ga):
                out.append("option " + missing(gk, ga)[0])
                break
    return out


def path_color(pid):
    return PATH_COLORS[zlib.crc32(pid.encode("utf-8")) % len(PATH_COLORS)]


MISSING_RED = "#e57a7a"


def _missing_row(text):
    """Something still missing: the octagon, then what (Maxim, 01.10.)."""
    from .icons import pixmap
    w = QtWidgets.QWidget()
    h = QtWidgets.QHBoxLayout(w)
    h.setContentsMargins(0, 0, 0, 0)
    h.setSpacing(5)
    ic = QtWidgets.QLabel()
    ic.setPixmap(pixmap("octagon-alert", MISSING_RED, 14))
    note = QtWidgets.QLabel(text)
    note.setObjectName("missing")
    note.setStyleSheet(f"color:{MISSING_RED};font:12px")
    h.addWidget(ic)
    h.addWidget(note, 1)
    tip(w, "qb.missing")
    return w


def _button(text, fn, key=None, name="small"):
    b = QtWidgets.QPushButton(text)
    b.setObjectName(name)
    if name == "target_empty":                  # still to be set: the octagon before it
        from .icons import icon
        b.setIcon(icon("octagon-alert", MISSING_RED, 14))
    b.setFocusPolicy(Q.NoFocus)
    b.clicked.connect(fn)
    if key:
        tip(b, key)
    return b


def _trash():
    from .icons import icon
    return icon("trash-2")


def _icon(name, fn, key=None):
    """A small icon button (Lucide): Remove trash-2, Move up / down chevrons, Close x, Back arrow-left, Play / Stop."""
    from .icons import icon_button
    b = icon_button(name, fn, key)
    b.setAccessibleName(name)
    return b


def _chip(text, checked, fn, key=None):
    b = QtWidgets.QToolButton()
    b.setObjectName("chip")
    b.setText(text.replace("&", "&&"))
    b.setCheckable(True)
    b.setChecked(checked)
    b.clicked.connect(fn)
    if key:
        tip(b, key)
    return b


def _removable(chip):
    """A chip that removes itself on a click: the trash can after its text."""
    from .icons import icon
    chip.setIcon(icon("trash-2", size=12))
    chip.setLayoutDirection(Q.RightToLeft)          # the icon after the text
    chip.setToolButtonStyle(Q.ToolButtonTextBesideIcon)
    return chip


_SCANNING = set()                           # worlds whose notice boards are being looked for (once)


def _menu_button(text, entries, current, fn, key=None, colour=None, lazy=True):
    """A button that opens a flat list: entries (key, label) - filled when it opens (a board of a big quest has
    hundreds); `lazy=False` for one whose entries are ticked from outside."""
    b = QtWidgets.QToolButton()
    b.setObjectName("menu")
    if text == "···":                       # the card's menu: the ellipsis icon
        from .icons import icon
        b.setIcon(icon("ellipsis"))
        b.setAccessibleName("ellipsis")
    else:
        b.setText(text.replace("&", "&&"))
    b.setFocusPolicy(Q.NoFocus)
    if colour:
        b.setStyleSheet(f"QToolButton#menu{{color:{colour};border-color:{colour}}}")
    m = QtWidgets.QMenu(b)                  # its look: the board's STYLE (one sheet, not one per menu - speed)
    entries = list(entries)

    def fill():
        if m.actions():
            return
        for k, label in entries:
            act = m.addAction(label)
            if k == "remove":
                act.setIcon(_trash())
            act.setCheckable(True)
            act.setChecked(k == current)
            act.triggered.connect(lambda _c=False, k=k: fn(k))
    if lazy:
        m.aboutToShow.connect(fill)
    else:
        fill()
    attach(b, m)
    if key:
        tip(b, key)
    return b


def _field(text):
    lab = QtWidgets.QLabel(text)
    lab.setObjectName("field")
    return lab


def _row(*widgets, stretch_last=True):
    w = QtWidgets.QWidget()
    h = QtWidgets.QHBoxLayout(w)
    h.setContentsMargins(0, 0, 0, 0)
    h.setSpacing(6)
    for i, x in enumerate(widgets):
        h.addWidget(x, 1 if stretch_last and i == len(widgets) - 1 else 0)
    return w


def _fact_typed(field):
    """A fact's name as typed, made one radish takes (project.fact_id: "größe erreicht" -> groesse_erreicht) - the
    field shows what it became."""
    from .project import fact_id
    name = fact_id(field.text())
    if name != field.text():
        field.setText(name)
    return name


class Chooser(QtWidgets.QWidget):
    """Which one to create: the catalog on its kind (people, creatures, everything), a click shows it, Place it (or
    a double click) takes it. 'clue_swap:<cat>/<sub>': the clues of that kind (with the game's quest things)."""
    GROUP = {"people": ("People", None), "creatures": ("Creatures", None), "clues": ("Gameplay", "Clues"),
             "containers": ("Containers", None)}

    def __init__(self, board, what, then):
        super().__init__()
        self.board, self.then, self.entry, self.what = board, then, None, what
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 6, 0, 0)
        title = QtWidgets.QLabel({"people": "Place new NPC", "creatures": "Place new creature",
                                  "clues": "Place new clue", "containers": "Place new container"}.get(
            what, "Swap for clue" if what.startswith("clue_swap") else "Place new object"))
        title.setStyleSheet("color:#f0f0f0;font:bold 13px")
        self.name = QtWidgets.QLabel("")
        self.name.setStyleSheet("color:#bbb;font:12px")
        self.take = _button("Use it" if what.startswith("clue_swap") else "Place", self._take, "qb.chooser_take")
        self.take.setEnabled(False)
        if not what.startswith("clue_swap"):       # placing: the side card's Place button is the one (Maxim 02.10.)
            self.take.hide()
        v.addWidget(_row(tip(theme.back_button(board.close_chooser), "qb.chooser_back"), title, self.name, self.take,
                         stretch_last=False))
        v.itemAt(0).widget().layout().setStretch(2, 1)
        db = board.assets()
        if db is None:
            v.addWidget(_field("The catalog is not built yet."))
            return
        from .catalog_view import CatalogView
        self.catalog = CatalogView(board.ed, db)
        v.addWidget(self.catalog, 1)
        self.catalog.current.connect(self._current)
        self.catalog.chosen.connect(lambda e: (self._current(e), self._take()))
        if what in ("containers", "loot"):          # (Maxim 08.10.: Geralt's stash is no loot - not offered at all)
            from .quest import NOT_LOOT
            self.catalog.hide = lambda r: r.get("class") in NOT_LOOT
        if what in self.GROUP:
            self.catalog.show_only("type", self.GROUP[what])
        elif what == "loot":                        # (everything else hidden: the list as it was)
            self.catalog.refresh()
        elif what.startswith("clue_swap"):          # a clue of the same kind as the object it replaces
            cat, _, sub = what.partition(":")[2].partition("/")
            self.catalog.quest_chip.setChecked(True)
            self.catalog.show_only("trait", "clue")
            self.catalog.cat, self.catalog.sub = cat or None, sub or None
            self.catalog.refresh()
        QtCore.QTimer.singleShot(0, lambda: getattr(board.ed, "typing", None) and board.ed.typing.start(
            self.catalog.search))

    def _refused(self, e):
        """Why this one can not be the container asked for (Geralt's stash ...) or None."""
        if self.what not in ("containers", "loot") or not e or not e.get("path"):
            return None
        from .quest import not_loot
        return not_loot(e["path"])

    def _current(self, e):
        self.entry = e if e and e.get("type") == "template" else None
        why = self._refused(self.entry)
        e = self.entry
        shown = (f"{e['row'].get('name')}, {e['sub']}" if "look" in e else e["title"]) if e else ""   # (a look: whose)
        self.name.setText(why or shown)
        self.name.setStyleSheet("color:%s;font:12px" % ("#e06c5a" if why else "#bbb"))
        self.take.setEnabled(self.entry is not None and not why)
        panel = getattr(self.board.ed, "panel", None)
        if self.entry and panel is not None and getattr(panel, "inspector", None) is not None:
            # the side panel as in the catalog: the 3D view, the looks, what it is (Maxim, 01.10.)
            panel.show_inspector(True)
            panel.inspector.show_entry(self.entry, favourite=self.entry["key"] in panel.catalog.favourites)

    def _take(self):
        if not self.entry:
            return
        if self._refused(self.entry):               # (the side card's Place comes here too)
            self._current(self.entry)
            return
        self.catalog.remember(self.entry)
        path = self.entry["path"]
        self.board.chosen_variants = self.entry.get("members")     # a folder: its variants (a group: mixed)
        if self.entry.get("members"):               # a folder: one of its variants
            import random
            path = random.choice(self.entry["members"])
        # its id: 'blacksmith', not the template's file name (a look: the person's name, not the look's)
        self.board.chosen_title = self.entry["row"].get("name") if "look" in self.entry else self.entry.get("title")
        self.board.ed.place_look = self.entry.get("look")     # one look of a person: placed in exactly it
        self.board.close_chooser()
        self.then(path)


class QuestBoard(QtWidgets.QWidget):
    """The Quest tab. `ed`: the editor (project, place, selection); `assets`: () -> the asset database or None."""

    def __init__(self, ed, assets=lambda: None):
        super().__init__()
        self.ed, self.assets = ed, assets
        self.setStyleSheet(STYLE)
        self.open_picker = None                 # (id of a step's args, field) of the object list shown
        self.more = set()                       # cards whose extra options are open (id of the step's dict)
        self.waiting = None                     # (id of a step's args, field, how) while the editor waits
        self.dialogue = None                    # the dialogue view shown instead of the board
        self.chooser = None                     # the catalog shown to create an object for a step
        self.stack = QtWidgets.QStackedLayout(self)
        self.page = QtWidgets.QWidget()
        self.stack.addWidget(self.page)
        v = QtWidgets.QVBoxLayout(self.page)
        v.setContentsMargins(0, 6, 0, 0)
        top = QtWidgets.QHBoxLayout()
        top.setSpacing(4)
        self.title = QtWidgets.QLineEdit()
        self.title.setPlaceholderText("Quest name")
        self.title.editingFinished.connect(self._save_head)
        tip(self.title, "qb.title")
        top.addWidget(self.title, 1)
        self.new_name = QtWidgets.QLineEdit()           # "New quest": its name typed here, Enter makes it
        self.new_name.setPlaceholderText("Quest name")
        self.new_name.returnPressed.connect(self._create_project)
        self.new_name.editingFinished.connect(lambda: self.new_name.text().strip() or self._new_done())
        self.new_name.hide()
        top.addWidget(self.new_name, 1)
        # a long quest: its chapters and paths, one click away (filled when it opens)
        self.jump = QtWidgets.QToolButton()
        self.jump.setObjectName("menu")
        self.jump.setText("Jump to")
        self.jump.setFocusPolicy(Q.NoFocus)
        jm = QtWidgets.QMenu(self.jump)
        jm.aboutToShow.connect(lambda: self._fill_jump(jm))
        attach(self.jump, jm)
        tip(self.jump, "qb.jump_to")
        self.jump.hide()
        top.addWidget(self.jump)
        self.projects = QtWidgets.QToolButton()
        self.projects.setObjectName("menu")
        self.projects.setText("···")
        self.projects.setFocusPolicy(Q.NoFocus)
        pm = QtWidgets.QMenu(self.projects)
        pm.aboutToShow.connect(lambda: self._fill_projects(pm))
        attach(self.projects, pm)
        tip(self.projects, "qb.projects")
        top.addWidget(self.projects)
        v.addLayout(top)
        # 'In this quest': its people, things and items - a window of its own (Maxim 02.10.: folded out on the tab
        # it was cramped; cast_view.py)
        self.cast_toggle = QtWidgets.QPushButton("In this quest")
        self.cast_toggle.setObjectName("small")
        from .icons import icon
        self.cast_toggle.setIcon(icon("external-link"))
        self.cast_toggle.setFocusPolicy(Q.NoFocus)
        self.cast_toggle.setStyleSheet("QPushButton{text-align:left}")
        self.cast_toggle.clicked.connect(self._toggle_cast)
        tip(self.cast_toggle, "qb.in_quest")
        # every block of the quest as the game has it, in the quest graph (the same editor as the game's quests):
        # deeper than the board, each value at hand
        self.graph_open = QtWidgets.QPushButton("Quest graph")
        self.graph_open.setObjectName("small")
        self.graph_open.setIcon(icon("external-link"))
        self.graph_open.setFocusPolicy(Q.NoFocus)
        self.graph_open.clicked.connect(self.open_quest_graph)
        tip(self.graph_open, "qb.quest_graph")
        row = QtWidgets.QHBoxLayout()
        row.setSpacing(6)
        row.addWidget(self.cast_toggle, 1)
        row.addWidget(self.graph_open)
        v.addLayout(row)
        # the quest's own settings: the card of the graph's start node (a form, one line each - Maxim 01.10.:
        # finding one's way must be easy; the rows over the graph were crowded), the graph keeps the height
        self.head_box = QtWidgets.QWidget()
        hv = QtWidgets.QVBoxLayout(self.head_box)
        hv.setContentsMargins(0, 0, 0, 0)
        hv.setSpacing(5)
        self.types = QtWidgets.QWidget()
        form = QtWidgets.QGridLayout(self.types)
        form.setContentsMargins(0, 0, 0, 0)
        form.setHorizontalSpacing(8)
        form.setVerticalSpacing(5)
        kinds = QtWidgets.QWidget()
        th = QtWidgets.QHBoxLayout(kinds)
        th.setContentsMargins(0, 0, 0, 0)
        th.setSpacing(4)
        self.type_chips = {}
        for key, label in QUEST_TYPES:
            c = _chip(label, False, lambda _c=False, k=key: self._set_type(k), "qb.type")
            self.type_chips[key] = c
            th.addWidget(c)
        th.addStretch(1)
        self.start_chip = _menu_button("", QUEST_STARTS, None, self._set_start, "qb.quest_start", lazy=False)
        from .dialogue import PLAYERS
        self.player_chip = _menu_button("", [(k, p["label"]) for k, p in PLAYERS.items()], None,
                                        lambda k: self._set_in(self.quest(), "player", None if k == "geralt" else k),
                                        "qb.plays_as", lazy=False)
        self.level = QtWidgets.QSpinBox()
        self.level.setRange(0, 100)
        self.level.setSpecialValueText("-")
        self.level.editingFinished.connect(lambda: self._set_in(self.quest(), "level", self.level.value() or None,
                                                                rebuild=False))
        tip(self.level, "qb.level")
        self.after = Combo()
        # a long entry (a game quest's point) must not widen the panel: the list shows it whole, the box cuts it
        self.after.setSizeAdjustPolicy(QtWidgets.QComboBox.AdjustToMinimumContentsLengthWithIcon)
        self.after.setMinimumContentsLength(26)
        self.after.view().setMinimumWidth(420)
        self.after.currentIndexChanged.connect(self._after_chosen)
        tip(self.after, "qb.after")
        from . import features
        rows = [("Kind", kinds), ("Starts", self.after), ("Journal", self.start_chip),
                ("Plays as", self.player_chip), ("Level", self.level)]
        if not features.experimental():
            # the first release: starts at once, with a quest of the game or after one (Maxim 07.10.); when the
            # journal shows it and a moment inside a quest come with the update
            rows = [(n, w) for n, w in rows if w is not self.start_chip]
            self.start_chip.hide()
        for r, (name, w) in enumerate(rows):
            form.addWidget(_field(name), r, 0)
            form.addWidget(w, r, 1, Q.AlignLeft if w is not kinds else Q.AlignVCenter)
        form.setColumnStretch(1, 1)
        hv.addWidget(self.types)
        self.desc = QtWidgets.QPlainTextEdit()
        self.desc.setPlaceholderText("Journal entry")
        self.desc.setFixedHeight(54)
        self.desc.textChanged.connect(self._desc_changed)
        tip(self.desc, "qb.description")
        hv.addWidget(_field("Description"))
        hv.addWidget(self.desc)
        self.alive_box = QtWidgets.QWidget()
        QtWidgets.QVBoxLayout(self.alive_box).setContentsMargins(0, 0, 0, 0)
        hv.addWidget(self.alive_box)
        self.head_box.setParent(self.page)              # (in the start node's card when that is picked)
        self.head_box.hide()
        # the quest as a graph: blocks from the sidebar into it, a click on a node shows its card under it
        from .graph_view import GraphView
        from .graph_blocks import BlockBar
        self.graph = GraphView()
        self.graph.picked.connect(self._graph_picked)
        self.graph.opened.connect(self._graph_open)
        self.graph.kind_menu.connect(self._graph_kind_menu)
        self.graph.node_menu.connect(self._graph_node_menu)
        self.graph.place.connect(self._graph_place)
        self.graph.moved.connect(self._graph_moved_node)
        self.graph.connect.connect(self._graph_connect)
        self.graph.relink.connect(self._graph_relink)
        self.graph.unlink.connect(self._graph_unlink)
        self.graph.wire_menu.connect(self._graph_wire_menu)
        self.blocks = BlockBar(self.graph, self._graph_click_block)
        self.graph_card = QtWidgets.QScrollArea()
        self.graph_card.setWidgetResizable(True)
        self.graph_card.setFrameShape(QtWidgets.QFrame.NoFrame)
        self.graph_card.setHorizontalScrollBarPolicy(Q.ScrollBarAlwaysOff)
        self.graph_split = QtWidgets.QSplitter(Q.Vertical)
        self.graph_split.addWidget(self.graph)
        self.graph_split.addWidget(self.graph_card)
        self.graph_split.setStretchFactor(0, 3)
        self.graph_split.setStretchFactor(1, 2)
        self.graph_split.setChildrenCollapsible(False)
        self.graph_frac = 0.6                           # the graph's part of the height (the handle moves it)
        self.graph_split.splitterMoved.connect(self._graph_moved)
        self.graph_split.installEventFilter(self)
        area = QtWidgets.QHBoxLayout()
        area.setContentsMargins(0, 0, 0, 0)
        area.setSpacing(6)
        area.addWidget(self.blocks)
        area.addWidget(self.graph_split, 1)
        v.addLayout(area, 1)
        self.graph_node = None                          # the node whose card shows under the graph
        self.graph_pick = None                          # a step dict: its node is picked after the next build
        self.graph_menu = None                          # a step dict: its kinds open after the next build
        self._anchor = QtWidgets.QWidget(self.graph.viewport())     # where a node's kind menu opens
        self._anchor.resize(1, 1)
        self._anchor.hide()
        self._desc_timer = QtCore.QTimer(singleShot=True, interval=600)
        self._desc_timer.timeout.connect(self._save_head)
        self.sync()

    # --- data
    def quest(self):
        return self.ed.project.meta.setdefault("quest", QN.new_quest(self.ed.project.meta.get("name", "")))

    def graph_quest(self):
        """The quest as its graph: a quest of the older form (step lists) becomes it once - where it was drawn."""
        q = self.quest()
        if not QN.is_graph(q):
            QN.migrate(q)
            self.ed.project.save_meta()
        return q

    def steps(self):
        """The quest's steps from its start along the wires, then those nothing leads to - a list whose changes wire
        the graph (StoryList)."""
        return StoryList(self)

    def _story(self):
        q = self.graph_quest()
        return [n for n in QN.order(q) if QN.step_kind(q["nodes"][n]["step"])[0] not in ("start", "end", "remember")]

    def node_of(self, step):
        """The id of the node whose step this is (or None)."""
        return next((nid for nid, n in self.graph_quest()["nodes"].items() if n["step"] is step), None)

    def _ons(self, nid):
        """The outputs a step goes on in the story by (the older form's 'continue'): "next"; a talk's "continue";
        won and - unless it leads elsewhere - lost; arrived; every option / way of a choice; yes and no."""
        ports = [p for p, _l in QN.ports(self.graph_quest()["nodes"][nid]["step"], self.quest())]
        return [p for p in ports if p in ("next", "continue", "Success", "Failure", "arrived", "yes", "no") or
                p[:1] == "o" and p[1:].isdigit() or p.startswith("way")]

    def _out(self, nid):
        """The output a step goes on by (the first of _ons), or None."""
        ons = self._ons(nid)
        return ons[0] if ons else None

    def add_after(self, nid, step):
        """A node under `nid`, between it and where it went on (its output: to the new one, the new one's on to
        where that led). Returns the new id."""
        q = self.graph_quest()
        at = q["nodes"][nid]
        nxt = QN.new_id(q)
        gap = 120                                       # under it with room: a talk with its exits is taller
        shown = getattr(getattr(self, "graph", None), "graph", None)
        if shown is not None and nid in shown.nodes:
            gap = max(gap, -(-(int(shown.nodes[nid].h) + 40) // L.GRID) * L.GRID)
        q["nodes"][nxt] = {"step": step, "x": at.get("x", 0), "y": at.get("y", 0) + gap}
        for other in q["nodes"].values():               # what stood below moves down to make room
            if other is not q["nodes"][nxt] and other.get("x") == at.get("x") and other.get("y", 0) > at.get("y", 0):
                other["y"] = other.get("y", 0) + gap
        ons = self._ons(nid)
        if not ons:
            return nxt
        # where it went on: its "next" / "continue"'s targets; a choice's - those two or more of its outputs share
        # (one output wired alone elsewhere is a way off it: it stays)
        wired = {p: tuple(sorted(ln[2] for ln in QN.links_from(q, nid, p))) for p in ons}
        main = next((p for p in ("next", "continue") if p in ons), None)
        if main is not None:
            after = list(wired[main])
        else:
            shared = [t for t in set(wired.values()) if t and list(wired.values()).count(t) >= 2]
            after = list(shared[0]) if shared else []
        for port in ons:
            if port == main or not wired[port] or (after and set(wired[port]) == set(after)):
                q["links"] = [ln for ln in q["links"] if not (ln[0] == nid and ln[1] == port)]
                q["links"].append([nid, port, nxt])
        q["links"] += [[nxt, mine, b] for mine in self._ons(nxt) for b in after]
        return nxt

    def _remove_joined(self, nid):
        """A node goes; what led to it leads on to where it went on."""
        q = self.graph_quest()
        out = self._out(nid)
        after = [ln[2] for ln in QN.links_from(q, nid, out)] if out else []
        into = [ln for ln in q["links"] if ln[2] == nid]
        q["nodes"].pop(nid, None)
        q["links"] = [ln for ln in q["links"] if nid not in (ln[0], ln[2])]
        for a, port, _b in into:
            for b in after:
                if b != nid and [a, port, b] not in q["links"]:
                    q["links"].append([a, port, b])

    def paths(self):
        return self.quest().get("paths") or {}           # (the older form's; a graph's ways are wires)

    def all_steps(self):
        """Every step of the quest."""
        return self.steps()

    def save(self, rebuild=True):
        q = self.quest()
        if QN.is_graph(q):                              # wires of outputs a step no longer has go
            outs = {nid: {p for p, _l in QN.ports(n["step"], q)} for nid, n in q["nodes"].items()}
            q["links"] = [ln for ln in q.get("links") or [] if ln[0] in outs and ln[2] in q["nodes"] and
                          (ln[1] in outs[ln[0]] or ln[1] == "next" and not outs[ln[0]] - {"next"})]
        self.ed.project.save_meta()
        self.remember()
        if rebuild:
            QtCore.QTimer.singleShot(0, self.sync)

    # --- undo (the editor's Ctrl+Z, one stack with the world's changes)
    def _snapshot(self):
        import copy
        m = self.ed.project.meta
        return copy.deepcopy({k: m.get(k) for k in UNDONE})

    def remember(self):
        """A saved change: the state before it is one undo step."""
        now = self._snapshot()
        if getattr(self, "_shot_of", None) is self.ed.project and self._shot != now and hasattr(self.ed, "undo"):
            self.ed.undo.append(("quest", self._shot))
            del self.ed.undo[:-200]
        self._shot, self._shot_of = now, self.ed.project

    def restore(self, shot):
        """Undo: the quest (and its replaced scenes and cutscenes) as they were."""
        import copy
        m = self.ed.project.meta
        for k in UNDONE:
            if shot.get(k) is None:
                m.pop(k, None)
            else:
                m[k] = copy.deepcopy(shot[k])
        self.ed.project.save_meta()
        self._shot, self._shot_of = self._snapshot(), self.ed.project
        self.close_dialogue()                   # (it showed the dicts that are gone now)
        self.sync()

    def _save_head(self):
        q = self.quest()
        q["title"] = self.title.text().strip()
        q["description"] = self.desc.toPlainText().strip()
        self.save(rebuild=False)

    def _desc_changed(self):
        self._desc_timer.start()

    def _set_start(self, key):
        self._set_in(self.quest(), "start", None if key == "at_once" else key)

    def _set_type(self, key):
        self.quest()["type"] = key
        for k, c in self.type_chips.items():
            c.setChecked(k == key)
        self.save(rebuild=False)

    # --- paths
    def new_path(self, label):
        """A new path (its id from the label, unique); returns the id. Named after an answer: without its full stop."""
        label = (label or "").strip().rstrip(".!?…").strip() or None
        base = "".join(c if c.isascii() and c.isalnum() else "_"
                       for c in (label or "path").lower()).strip("_")[:24] or "path"
        pid, n = base, 2
        q = self.quest()
        while pid in self.paths() or pid in (q.get("outcomes") or {}):
            pid, n = f"{base}_{n}", n + 1
        if QN.is_graph(q):                              # a graph: the name of an output of its own
            q.setdefault("outcomes", {})[pid] = label or pid.replace("_", " ").capitalize()
            return pid
        self.paths()[pid] = {"label": label or pid.replace("_", " ").capitalize(), "then": "join", "steps": []}
        return pid

    def path_entries(self):
        """(way out, label) of every path, for the menus that lead somewhere (a graph: none - its wires do)."""
        return [(f"path:{pid}", f"Branch: {p.get('label') or pid}") for pid, p in self.paths().items()]

    # --- one dialogue instead of the board
    def open_dialogue(self, st):
        from .dialogue_view import DialogueView
        self.close_dialogue()
        self.dialogue = DialogueView(self, st)
        self.dialogue.back.connect(self.close_dialogue)
        self.stack.addWidget(self.dialogue)
        self.stack.setCurrentWidget(self.dialogue)

    def close_dialogue(self):
        if self.dialogue is not None:
            self.stack.removeWidget(self.dialogue)
            self.dialogue.deleteLater()
            self.dialogue = None
            self.stack.setCurrentWidget(self.page)
            self.sync()

    # --- the board
    def _toggle_cast(self):
        w = self._cast()
        if w is None:
            return
        if w.isVisible():
            w.close()
            return
        w.body.fill()
        w.show()
        w.raise_()
        ed = self.ed
        if hasattr(ed, "stack") and hasattr(ed, "game_in_front"):     # over the game at once, not at the next round
            ed.z_top = None
            ed.stack(True)

    def _cast(self):
        panel = getattr(self, "panel", None)
        return panel.cast_window(self) if panel is not None else None

    def _fill_cast(self):
        """The button's count; the window, if open, anew."""
        w = self._cast()
        if w is None:
            return
        people, things, items = w.body.counts()
        self.cast_toggle.setText(f"In this quest  ·  {people} people, {things} things, {items} items")
        if w.isVisible():
            w.body.fill()

    def sync(self):
        if getattr(self, "cast_toggle", None) is not None:
            self._fill_cast()
        if getattr(self, "graph_open", None) is not None:    # the quest changed in the quest graph: Build uses that
            from .vanilla_edit import GAME_FILES, OWN_FILE
            graphed = os.path.exists(os.path.join(self.ed.project.path, GAME_FILES, OWN_FILE))
            self.graph_open.setText("Quest graph (changed there)" if graphed else "Quest graph")
        if getattr(self, "_shot_of", None) is not self.ed.project:
            self._shot, self._shot_of = self._snapshot(), self.ed.project      # a project opened: undo starts here
        if self.waiting and not self.ed.request:
            self.waiting = None                 # the editor stopped waiting (Esc, answered)
        if self.dialogue is not None:
            if getattr(self.dialogue, "monologue", False) or \
                    any(st is self.dialogue.st for st in self.all_steps() + self.swap_steps() + self.walk_talks()):
                self.dialogue.sync()
                return
            self.close_dialogue()
        q = self.quest()
        if self._desc_timer.isActive():         # typed and not saved yet (a click within 0.6 s): kept, not overwritten
            self._desc_timer.stop()
            q["description"] = self.desc.toPlainText().strip()
            self.ed.project.save_meta()
        self.title.setText(q.get("title", ""))
        if self.desc.toPlainText() != q.get("description", ""):
            self.desc.blockSignals(True)
            self.desc.setPlainText(q.get("description", ""))
            self.desc.blockSignals(False)
        for k, c in self.type_chips.items():
            c.setChecked(k == q.get("type", "secondary"))
        start = q.get("start", "at_once")
        self.level.setValue(int(q.get("level") or 0))
        self._fill_after()
        self.start_chip.setText(dict(QUEST_STARTS)[start])
        for act in self.start_chip.menu().actions():
            act.setChecked(act.text() == dict(QUEST_STARTS)[start])
        from .dialogue import PLAYERS
        who = PLAYERS.get(q.get("player") or "geralt", PLAYERS["geralt"])["label"]
        self.player_chip.setText(who)
        for act in self.player_chip.menu().actions():
            act.setChecked(act.text() == who)
        self._fill_alive()
        self._sync_graph()

    # --- the graph
    def _graph_picked(self, nid):
        self.graph_node = nid
        self.graph.select(nid)
        self._graph_card()
        QtCore.QTimer.singleShot(0, lambda: self.graph.show_node(nid, 30))   # the card below took room

    def _graph_share(self):
        total = sum(self.graph_split.sizes()) or self.graph_split.height()
        if total > 0 and self.graph_card.isVisible():
            top = int(total * self.graph_frac)
            if abs(self.graph_split.sizes()[0] - top) > 1:
                self.graph_split.setSizes([top, total - top])

    def _graph_moved(self, _pos, _index):
        sizes = self.graph_split.sizes()
        if sum(sizes) > 0:
            self.graph_frac = min(0.9, max(0.15, sizes[0] / sum(sizes)))

    def eventFilter(self, obj, ev):
        if obj is getattr(self, "graph_split", None) and ev.type() in (QtCore.QEvent.Resize, QtCore.QEvent.Show):
            QtCore.QTimer.singleShot(0, self._graph_share)
        return super().eventFilter(obj, ev)

    def _node_step(self, nid):
        """(steps, index) of a node's step, or None (the start, a path's head, an end)."""
        n = self.graph.graph.nodes.get(nid) if self.graph.graph else None
        if n is None or n.card is None or n.card[1] is None:
            return None
        return n.card

    def _graph_open(self, nid):
        """A double click: a talk's dialogue opens (the rest have all they need on the card)."""
        at = self._node_step(nid)
        if at is not None and step_kind(at[0][at[1]])[0] == "talk":
            self.open_dialogue(at[0][at[1]])

    def _sync_graph(self):
        def live(n):
            if n.card is None or n.card[1] is None or n.kind in ("chapter", "remember"):
                return None
            return self._live_state(*step_kind(n.card[0][n.card[1]]))
        self.graph.live = live
        q = self.graph_quest()
        same = getattr(self, "_graph_of", None) is self.ed.project
        self._graph_of = self.ed.project
        from .quest import display_names
        # another quest opened: from its start
        self.graph.show_graph(QG.build_nodes(q, display_names(self.ed.project)), keep=same)
        pick, self.graph_pick = self.graph_pick, None
        menu, self.graph_menu = self.graph_menu, None
        for n in self.graph.graph.nodes.values():
            if pick is not None and q["nodes"][n.id]["step"] is pick:
                self.graph_node = n.id
                QtCore.QTimer.singleShot(0, lambda nid=n.id: self.graph.show_node(nid, 60))
                if menu is pick:                # a block just dropped: what it does, chosen at once
                    QtCore.QTimer.singleShot(30, lambda nid=n.id: self._graph_kind_menu(nid))
        if self.graph_node not in self.graph.graph.nodes:
            self.graph_node = QN.START
        self.graph.select(self.graph_node)
        if self._typing_in_card():
            return                              # the graph anew; the card (and the field typed in) stays
        t = getattr(getattr(self.ed, "typing", None), "target", None)
        if t is not None:
            from .keyboard import name, trace
            trace(f"the card is built anew while typing in {name(t)}")
        self._graph_card()

    def _typing_in_card(self):
        """Is a field of the card being typed in? Then the card is not built anew under it: the field left before
        finished (saved), the one clicked would be gone with its caret (Maxim: 'the caret goes when I go into
        another field'). The card shows the step's dicts themselves - it stays right."""
        import shiboken6
        t = getattr(getattr(self.ed, "typing", None), "target", None)
        return t is not None and shiboken6.isValid(t) and self.graph_card.isAncestorOf(t)

    # the graph's edits: every one changes the quest's nodes and links, saves, and the graph is built anew
    def _new_step(self, kind):
        """A fresh step of a kind (or a block not told yet what it does), with what it needs to start."""
        if kind in ("goal", "action", "choice", "parallel"):
            return {kind: {}}
        if kind == "chapter":
            return {"chapter": {}}
        if kind == "end":
            return {"end": {"how": "success"}}
        if kind == "if":
            return {"if": {}}
        if kind in GOAL_KINDS or kind in ("deliver", "either"):
            return self._goal_step(kind)
        return self._action_step(kind)

    def _add_node(self, step, x, y):
        """A node of its own at (x, y) (its top left, on the grid); returns its id."""
        q = self.graph_quest()
        nid = QN.new_id(q)
        q["nodes"][nid] = {"step": step, "x": int(x // L.GRID * L.GRID), "y": int(y // L.GRID * L.GRID)}
        return nid

    def _link(self, a, port, b, beside=False):
        """A wire from a node's output to a node: instead of where that output led (beside: as well)."""
        q = self.graph_quest()
        if not beside:
            q["links"] = [ln for ln in q["links"] if not (ln[0] == a and ln[1] == port)]
        if [a, port, b] not in q["links"]:
            q["links"].append([a, port, b])

    def _unlink(self, link):
        q = self.graph_quest()
        q["links"] = [ln for ln in q["links"] if ln != list(link)]

    def _graph_place(self, block, drop):
        """A block from the sidebar: where it is let go, on its own; onto a wire: into it."""
        step = self._new_step(block)
        if drop[0] == "wire":
            a, port, b = drop[1]
            nid = self._add_node(step, drop[2] - L.NODE_W / 2, drop[3] - 20)
            self._unlink(drop[1])
            self._link(a, port, nid)
            for mine in self._ons(nid):
                self._link(nid, mine, b, beside=True)
        elif drop[0] == "insert":                   # (by its place in the story: StoryList - the rebuild tests)
            drop[1].insert(drop[2], step)
        else:
            self._add_node(step, drop[1] - L.NODE_W / 2, drop[2] - 20)
        self.graph_pick = step
        if block in QG.PLACEHOLDERS:
            self.graph_menu = step
        self.save()

    def _graph_click_block(self, block):
        """A block clicked in the sidebar (not dragged): under the node picked and on from it (between it and where
        its output led); nothing picked: under the start, on its own."""
        q = self.graph_quest()
        n = self.graph.graph.nodes.get(self.graph_node) if self.graph.graph else None
        step = self._new_step(block)
        if n is None or n.id not in q["nodes"] or step_kind(q["nodes"][n.id]["step"])[0] == "end":
            n = self.graph.graph.nodes.get(QN.START)
        self.add_after(n.id, step)              # (its output on to the new one, the new one's on to where it led)
        self.graph_pick = step
        if block in QG.PLACEHOLDERS:
            self.graph_menu = step
        self.save()

    def _graph_moved_node(self, nid, x, y):
        node = self.graph_quest()["nodes"].get(nid)
        if node is not None:
            node["x"], node["y"] = x, y
            self.save()

    def _graph_connect(self, a, port, b, beside):
        self._link(a, port, b, beside)
        self.save()

    def _graph_relink(self, link, b):
        self._unlink(link)
        self._link(link[0], link[1], b, beside=True)
        self.save()

    def _graph_unlink(self, link):
        self._unlink(link)
        self.graph.select_wire(None)
        self.save()

    def _graph_wire_menu(self, link, pos):
        from . import inline_menu
        m = QtWidgets.QMenu(self)
        m.addAction(_trash(), "Remove connection").triggered.connect(lambda _c=False: self._graph_unlink(link))
        spot = self.graph.viewport().mapFromGlobal(pos)
        self._anchor.setGeometry(spot.x(), spot.y() - 2, 140, 2)
        inline_menu.show(self._anchor, m)

    def _graph_kind_menu(self, nid, pos=None):
        """What a node's block does: its kinds, in a list over the graph at the node's title."""
        from . import inline_menu
        n = self.graph.graph.nodes.get(nid)
        at = self._node_step(nid)
        kinds = self.graph.kinds_of(n) if n is not None else []
        if at is None or not kinds:
            return
        m = QtWidgets.QMenu(self)
        groups_ = ACTION_GROUPS if n.block == "action" else GOAL_GROUPS if n.block == "goal" else [(None, kinds)]
        for group, ks in groups_:
            target = m.addMenu(group) if group else m
            for k in ks:
                if k not in kinds:
                    continue
                act = target.addAction(QG.LABEL.get(k, k))
                act.setCheckable(True)
                act.setChecked(k == n.kind)
                act.triggered.connect(lambda _c=False, k=k: self._set_kind(at[0], at[1], k))
        corner = self.graph.mapFromScene(QtCore.QPointF(n.x + 8, n.y + 4))
        self._anchor.setGeometry(corner.x(), corner.y(), 120, L.HEAD - 4)
        inline_menu.show(self._anchor, m)

    def _graph_node_menu(self, nid, pos):
        """A right click on a node: play from here, duplicate, remove."""
        from . import inline_menu
        n = self.graph.graph.nodes.get(nid)
        if n is None:
            return
        m = QtWidgets.QMenu(self)
        at = self._node_step(nid)
        if at is None:
            return
        for key, label in CARD_MENU:
            m.addAction(label).triggered.connect(lambda _c=False, k=key: self._card_menu(at[0], at[1], k))
        spot = self.graph.viewport().mapFromGlobal(pos)
        self._anchor.setGeometry(spot.x(), spot.y() - 2, 140, 2)
        inline_menu.show(self._anchor, m)

    def _set_kind(self, steps, i, kind):
        """The step becomes another kind of its block (a block just dropped: what it does)."""
        from . import inline_menu
        inline_menu.close_open()                # its list, if the kind was chosen on the card instead
        old_kind, old = step_kind(steps[i])
        if kind == old_kind:
            return
        if old_kind in GOAL_KINDS and kind in GOAL_KINDS:
            self._change_kind(steps, i, kind)
            self.graph_pick = steps[i]
            return
        new = self._new_step(kind)
        nk, na = step_kind(new)
        if old.get("text") and QG.block_of(nk) == QG.block_of(old_kind):
            na["text"] = old["text"]
        if nk == "stop":                        # the lane started last (it is nearly always that one)
            lanes = [step_kind(st)[1].get("path") for st in self.all_steps() if step_kind(st)[0] == "meanwhile"]
            lanes = [x for x in lanes if x]
            if lanes:
                na["path"] = lanes[-1]
        if nk == "meanwhile":                   # a lane of its own at once (its name: what Stop lane stops)
            n = sum(1 for st in self.all_steps() if step_kind(st)[0] == "meanwhile")
            na["path"] = f"lane{n + 1}"
        if kind == "deliver":
            self._deliver_defaults(steps, i, na)
        steps[i] = new
        self.graph_pick = new
        self.save()

    def _deliver_defaults(self, steps, i, a):
        """A Deliver fills itself in from what came before (a fetch quest nearly always brings the thing back to who
        asked for it): to the person of the last talk, the item of the last step that got one."""
        from . import dialogue as D
        before = list(reversed(steps[:i])) + ([] if steps is self.steps() else list(reversed(self.steps())))
        item = next((step_kind(st)[1].get("item") for st in before
                     if step_kind(st)[0] in ("collect", "loot", "read") and step_kind(st)[1].get("item")), None)
        who = next((step_kind(st)[1].get("npc") for st in before
                    if step_kind(st)[0] == "talk" and step_kind(st)[1].get("npc")), None)
        if who:
            a["npc"] = who
        if item:
            for x in D.walk(a.get("dialogue") or []):
                if "give" in x and not x["give"].get("item"):
                    x["give"]["item"] = item

    def _graph_card(self):
        """The card of the node picked in the graph: a step's own, a path's (its name, where it goes), the
        start's (the quest's own items, the game's scenes it replaces, a template while it is empty)."""
        pos = self.graph_card.verticalScrollBar().value()
        self.head_box.setParent(self.page)              # (kept: the old card body goes, the settings stay)
        self.head_box.hide()
        body = QtWidgets.QWidget()
        col = QtWidgets.QVBoxLayout(body)
        col.setContentsMargins(0, 6, 6, 4)
        col.setSpacing(6)
        node = self.graph.graph.nodes.get(self.graph_node) if self.graph_node else None
        if node is not None and node.kind == "start":
            col.addWidget(self.head_box)
            self.head_box.show()
            self._quest_extras(col)
        elif node is not None and node.kind == "remember":
            note = _field(f"Remembers branch: {node.text}")
            col.addWidget(_row(note, QtWidgets.QWidget(), _icon(
                "trash-2", lambda _c=False, nid=node.id: self._remove_node(nid), "qb.remove"), stretch_last=False))
        elif node is not None and node.card is not None and node.card[1] is not None:
            steps, i = node.card
            kind = step_kind(steps[i])[0]
            colour = node.lane or None
            if kind == "chapter":
                col.addWidget(self._chapter(steps, i, step_kind(steps[i])[1]))
            elif kind not in QG.PLACEHOLDERS and (QG.block_of(kind) == "goal" or kind == "either"):
                col.addWidget(self._card(steps, node.number, i, colour))
            else:
                col.addWidget(self._step_card(steps, i, colour))
        col.addStretch(1)
        self.graph_card.setWidget(body)
        self.graph_card.setVisible(node is not None and node.kind not in L.ENDS or
                                   node is not None and node.kind == "end")
        self._graph_share()
        self.jump.setVisible(len(self.graph.graph.chapters) >= 2)
        QtCore.QTimer.singleShot(0, lambda: self.graph_card.verticalScrollBar().setValue(pos))

    def _quest_extras(self, col):
        """What belongs to the whole quest: its own items, the game's scenes and cutscenes it replaces. (No templates
        to start from since 06.10. - Maxim: Conjunction brings example projects instead.)"""
        if self.quest().get("items"):
            col.addWidget(self._own_items())
        for sid in list(self.swaps()):
            col.addWidget(self._swap_card(sid))
        for k, cs in enumerate(self.cutscene_swaps()):
            col.addWidget(self._cutscene_card(k, cs))
        from . import features
        if features.experimental():                 # a game scene / cutscene replaced: the game's files change
            col.addWidget(_row(_button("+ game scene", lambda _c=False: self.ed.panel.choose_scene(self._add_swap),
                                       "qb.add_swap", "plus"),
                               _button("+ game cutscene", lambda _c=False: self._add_cutscene_swap(),
                                       "qb.add_cutscene", "plus"), QtWidgets.QWidget()))

    # --- the game's scenes replaced
    def swaps(self):
        """The game scenes this quest replaces (read only - _add_swap makes the entry)."""
        return self.ed.project.meta.get("swaps") or {}

    def swap_steps(self):
        return [i for sw in self.swaps().values() for i in (sw.get("inputs") or {}).values()]

    def _add_swap(self, swap):
        base = "".join(c if c.isalnum() else "_" for c in swap["scene"].rsplit("\\", 1)[-1].rsplit(".", 1)[0].lower())
        sid, n = base[:32] or "scene", 2
        while sid in self.swaps():
            sid, n = f"{base[:30]}_{n}", n + 1
        self.ed.project.meta.setdefault("swaps", {})[sid] = swap
        self.save()

    def _remove_swap(self, sid):
        self.swaps().pop(sid, None)
        if not self.swaps():
            self.ed.project.meta.pop("swaps", None)
        self.save()

    def _swap_card(self, sid):
        """A game scene replaced: per way in a talk (Edit talk), where it goes on when the talk simply ends; a plain
        warning about saves."""
        from . import dialogue as D
        from .scene_swap import DEFAULT_IN, DEFAULT_OUT
        sw = self.swaps()[sid]
        o = sw["outline"]
        card = QtWidgets.QFrame()
        card.setObjectName("card")
        card.setStyleSheet("#card{border-left:3px solid #b99be6}")
        v = QtWidgets.QVBoxLayout(card)
        v.setContentsMargins(8, 6, 8, 8)
        v.setSpacing(5)
        kind = QtWidgets.QLabel("REPLACES")
        kind.setObjectName("kind")
        name = QtWidgets.QLabel(sw.get("name") or sw["scene"])
        name.setStyleSheet("color:#f0f0f0;font:bold 13px")
        name.setToolTip(sw["scene"])
        remove = _icon("trash-2", lambda _c=False, sid=sid: self._remove_swap(sid), "qb.swap_remove")
        head = _row(kind, name, remove, stretch_last=False)
        head.layout().setStretch(1, 1)
        v.addWidget(head)
        warn = _field("saves inside this quest may break")
        warn.setStyleSheet("color:#e3c65f;font:12px")
        tip(warn, "qb.swap_saves")
        v.addWidget(warn)
        outs = o["outputs"] or [DEFAULT_OUT]
        many = len(o["inputs"]) > 1
        for i in o["inputs"]:
            st = sw["inputs"].setdefault(i["name"], {"talk": {"swap": True, "input": i["name"], "dialogue": []}})
            a = st["talk"]
            lines = a.get("dialogue") or []
            where = _field(("at " + i["name"].replace("_", " ")) if many or i["name"] != DEFAULT_IN else "dialogue")
            where.setFixedWidth(220)
            why = (sw.get("not_loaded") or {}).get(i["name"])
            what = _field(D.summary(lines) if lines else f"empty - the game's has {why}" if why else
                          "Empty: the game continues at once")
            if why and not lines:
                what.setToolTip("Replaces the game's dialogue at this point")
            what.setFixedWidth(190)
            edit = _button("Edit dialogue", lambda _c=False, st=st: self.open_dialogue(st), "qb.swap_edit")
            then = a.get("then") if a.get("then") in outs else outs[min(o["inputs"].index(i), len(outs) - 1)]
            then_b = _menu_button(f"At end: {then.replace('_', ' ')}" if len(outs) > 1 else "At the end: continue",
                                  [(x, x.replace("_", " ")) for x in outs], then,
                                  lambda k, a=a: self._set_in(a, "then", k), "qb.swap_then")
            if len(outs) == 1:
                then_b.setEnabled(False)
            v.addWidget(_row(where, what, edit, then_b, QtWidgets.QWidget()))
        return card

    # --- the game's cutscenes replaced (in every game scene that plays them)
    def cutscene_swaps(self):
        return self.ed.project.meta.get("cutscene_swaps") or []

    def _add_cutscene_swap(self):
        self.ed.project.meta.setdefault("cutscene_swaps", []).append({"old": "", "new": ""})
        self.save()

    def _remove_cutscene_swap(self, k):
        cs = self.cutscene_swaps()
        if k < len(cs):
            cs.pop(k)
        if not cs:
            self.ed.project.meta.pop("cutscene_swaps", None)
        self.save()

    def _cutscene_pick(self, cs, key, word):
        """A search over the game's cutscenes; the one chosen is `cs[key]`."""
        from . import cutscene_swap as C
        names = {}
        for p in C.all_cutscenes():
            lab = C.label(p)
            names[lab if lab not in names else f"{lab}  ({p.rsplit(chr(92), 2)[-2]})"] = p
        pick = QtWidgets.QLineEdit(C.label(cs[key]) if cs.get(key) else "")
        pick.setPlaceholderText(f"Search the game's cutscenes ({len(names)})")
        comp = QtWidgets.QCompleter(list(names), pick)
        comp.setCaseSensitivity(Q.CaseInsensitive)
        comp.setFilterMode(Q.MatchContains)
        comp.setMaxVisibleItems(16)
        pick.setCompleter(comp)
        tip(pick, f"qb.cutscene_{key}")

        def chosen(text):
            if text in names and names[text] != cs.get(key):
                cs[key] = names[text]
                if key == "new":
                    cs.pop("file", None)         # a game cutscene again, not the own file
                self.save()
        comp.activated.connect(chosen)
        lab = _field(word)
        lab.setFixedWidth(52)                   # both searches start in one line
        row = _row(lab, pick, stretch_last=False)
        row.layout().setStretch(1, 1)
        return row

    def _cutscene_file(self, cs, path=None):
        """An own cutscene (a cooked .w2cutscene) plays instead: the build puts it into the mod bundle."""
        from . import cutscene_swap as C
        if path is None:
            from .dialogs import pick_file
            path = pick_file(self, "Custom cutscene", "", "Cutscenes (*.w2cutscene)")
        if path:
            cs["file"], cs["new"] = os.path.abspath(path), C.depot_path(path)
            self.save()

    def _cutscene_card(self, k, cs):
        """A game cutscene replaced by another: which, by which; where it plays, the lengths, what may not fit."""
        from . import cutscene_swap as C
        card = QtWidgets.QFrame()
        card.setObjectName("card")
        card.setStyleSheet("#card{border-left:3px solid #b99be6}")
        v = QtWidgets.QVBoxLayout(card)
        v.setContentsMargins(8, 6, 8, 8)
        v.setSpacing(5)
        kind = QtWidgets.QLabel("CUTSCENE")
        kind.setObjectName("kind")
        head = _row(kind, QtWidgets.QWidget(),
                    _icon("trash-2", lambda _c=False, k=k: self._remove_cutscene_swap(k), "qb.cutscene_remove"),
                    stretch_last=False)
        head.layout().setStretch(1, 1)
        v.addWidget(head)
        v.addWidget(self._cutscene_pick(cs, "old", "replace"))
        if not cs.get("old"):
            return card
        old = C.info(cs["old"])
        scenes = [C.label(s) for s in old["scenes"]]
        where = _field(f"plays in {scenes[0]}" if len(scenes) == 1 else f"plays in {len(scenes)} scenes"
                       if scenes else "no scene plays it")
        where.setToolTip("\n".join(old["scenes"]))
        v.addWidget(where)
        row = self._cutscene_pick(cs, "new", "with")
        row.layout().addWidget(_button("File...", lambda _c=False, cs=cs: self._cutscene_file(cs), "qb.cutscene_file"))
        v.addWidget(row)
        if cs.get("file"):
            own = _field(cs["file"])
            own.setToolTip(cs["new"])
            v.addWidget(own)
        if cs.get("new"):
            new = C.info(cs["new"], cs.get("file"))
            v.addWidget(_field(f"{old['duration']:.0f} s - now {new['duration']:.0f} s"))
            for p in C.problems(cs["old"], cs["new"], cs.get("file")):
                w = _field(p)
                w.setStyleSheet("color:#e3c65f;font:12px")
                tip(w, "qb.cutscene_people")
                v.addWidget(w)
        return card

    def open_quest_graph(self):
        """The quest in the quest graph (vanilla_view): its every block as the last build made it; changes there
        are kept with the project and built into the quest from then on."""
        from .vanilla_view import VanillaWindow
        panel = self.ed.panel

        def make():
            w = VanillaWindow(self.ed, None, project_dir=self.ed.project.path)
            w.open_own_quest()
            return w
        win = panel.open_window("Own quest graph", "Quest graph - " + (self.ed.project.meta.get("name") or ""),
                                make, kind="quest graph")
        body = getattr(win, "body", None)
        if body is not None and hasattr(body, "open_own_quest") and not body.trail:
            body.open_own_quest()
        return win

    # --- quests: this project's (several, one DLC - quests.py), a new one in it; projects: make one, switch to another
    def _fill_projects(self, menu):
        from . import quests as QS
        from .project import Project, recent
        menu.clear()
        meta = self.ed.project.meta
        mine = QS.all_quests(meta) or [self.quest()]
        head = menu.addAction(f"Quests of {meta.get('name') or 'this project'}")
        head.setEnabled(False)
        for q in mine:
            act = menu.addAction(q.get("title") or f"Quest {QS.key_of(q)}")
            act.setCheckable(True)
            act.setChecked(q is meta.get("quest"))
            act.triggered.connect(lambda _c=False, k=QS.key_of(q): self._switch_quest(k))
        menu.addAction("+ New quest in this project...").triggered.connect(lambda: self._new_project("quest"))
        if len(mine) > 1:
            menu.addAction("Remove this quest").triggered.connect(self._remove_quest)
        menu.addSeparator()
        head = menu.addAction("Projects")
        head.setEnabled(False)
        menu.addAction("New project...").triggered.connect(lambda: self._new_project("project"))
        others = []
        for p in recent():
            if os.path.normcase(p) == os.path.normcase(self.ed.project.path):
                continue
            try:
                others.append((Project(p).meta.get("name") or os.path.basename(p), p))
            except Exception:                           # noqa: BLE001 - a broken project file: not offered
                continue
        names = [n for n, _p in others]
        for name, p in others:
            label = f"{name}   ({os.path.basename(p)})" if names.count(name) > 1 else name
            menu.addAction(label).triggered.connect(lambda _c=False, p=p: self.ed.switch_project(p))
        menu.addSeparator()
        menu.addAction("Open folder...").triggered.connect(self._open_folder)

    def _new_project(self, what="project"):
        """The name of a new quest of this project (what: quest) or of a new project, typed where the title is."""
        self._new_what = what
        self.title.hide()
        self.new_name.clear()
        self.new_name.setPlaceholderText("Quest name" if what == "quest" else
                                         "Project name")
        self.new_name.show()
        self.new_name.setFocus()

    def _switch_quest(self, key):
        """Another quest of the project edited (the board and the graph show it)."""
        from . import quests as QS
        QS.switch(self.ed.project.meta, key)
        self.ed.project.save_meta()
        self.graph_node = None
        self.sync()

    def _remove_quest(self):
        from . import quests as QS
        q = self.quest()
        answer = QtWidgets.QMessageBox.question(self, "Remove quest",
                                                f"Remove the quest '{q.get('title') or 'without a name'}' from the "
                                                f"project? Its steps go (Undo brings them back).")
        if answer != QtWidgets.QMessageBox.Yes:
            return
        QS.remove(self.ed.project.meta, QS.key_of(q))
        self.ed.project.save_meta()
        self.graph_node = None
        self.sync()

    def _new_done(self):
        self.new_name.hide()
        self.title.show()

    def _create_project(self):
        from .project import new_project
        name = self.new_name.text().strip()
        self._new_done()
        if not name:
            return
        if getattr(self, "_new_what", "project") == "quest":   # a quest of this project: its people, its places
            from . import quests as QS
            self.quest()                                         # (the one there is: key 1)
            QS.add(self.ed.project.meta, name)
            self.ed.project.save_meta()
            self.graph_node = None
            self.sync()
            return
        self.ed.switch_project(new_project(name))

    def _open_folder(self):
        from .project import PROJECTS
        from .dialogs import pick_folder
        d = pick_folder(self, "Quest folder", PROJECTS)
        if d and os.path.exists(os.path.join(d, "project.yml")):
            self.ed.switch_project(d)

    def show_live(self, live):
        """The game's objectives (caption -> 1 active, 2 done, 3 failed): the cards show where the player is."""
        self.live = live
        if self.dialogue is None and self.chooser is None:
            self.sync()

    def _live_state(self, kind, a):
        caption = (a.get("text") or self._default_text(kind, a)).strip()
        live = getattr(self, "live", None) or {}
        states = [v for k, v in live.items() if k == caption or k.startswith(caption + " (")]    # counted: (1/3)
        if not states:
            return None
        return 1 if 1 in states else 3 if 3 in states else 2

    def _own_items(self):
        """The quest's own items: a name, a line for the inventory, the text Geralt reads (none: not readable)."""
        from .dialogue_view import AutoText
        box = QtWidgets.QFrame()
        box.setObjectName("card")
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(8, 6, 8, 8)
        v.setSpacing(4)
        head = QtWidgets.QLabel("QUEST ITEMS")
        head.setObjectName("kind")
        v.addWidget(head)
        from .item_chooser import item_label, item_uses
        for iid, it in self.quest().get("items", {}).items():
            name = self._text_line(it, "name", "name in the inventory")
            tip(name, "qb.own_name")
            v.addWidget(_row(_field("name"), name, _icon("trash-2", lambda _c=False, iid=iid: self._remove_own(iid),
                                                               "qb.own_remove"), stretch_last=False))
            v.itemAt(v.count() - 1).widget().layout().setStretch(1, 1)
            uses = item_uses(self.quest(), iid)
            facts = ([f"made from {item_label(it['base'], {}, self.assets())}"] if it.get("base") else []) + \
                [("used in " + ", ".join(f"step {n} ({k})" for n, k in uses)) if uses else "not used yet"]
            lab = QtWidgets.QLabel("  ·  ".join(facts))
            lab.setStyleSheet("color:#9a9a9a;font:11px")
            lab.setWordWrap(True)
            v.addWidget(lab)
            desc = self._text_line(it, "description", "a line under the name")
            v.addWidget(desc)
            text = AutoText(it.get("text", ""), "text to read (empty: a plain quest item)")
            text.done.connect(lambda t, it=it: self._set_in(it, "text", t.strip() or None, rebuild=False))
            tip(text, "qb.own_text")
            v.addWidget(text)
        return box

    def _add_own_item(self):
        items = self.quest().setdefault("items", {})
        n = 1
        while f"letter{n}" in items:
            n += 1
        items[f"letter{n}"] = {"name": "A letter", "description": "", "text": ""}
        self.save()
        if QN.is_graph(self.quest()):                 # its card is the start's: shown, not added out of sight
            QtCore.QTimer.singleShot(0, lambda: self._graph_picked(QN.START))

    def _remove_own(self, iid):
        """The item goes, and out of the steps that use it (their item fields empty: shown missing)."""
        from .item_chooser import drop_item
        drop_item(self.quest(), iid)
        self.save()

    def _other_quests(self):
        """(id, title) of the quests of your other projects (the recent ones) - one of them can come before this."""
        import os
        import yaml
        from . import config
        out, own = [], str(getattr(self.ed.project, "id", "")).lower()
        cache = self.__dict__.setdefault("_meta_cache", {})    # (each sync read every recent project's file)
        for path in config.load().get("recent", []):
            f = os.path.join(path, "project.yml")
            try:
                stamp = os.path.getmtime(f)
                if cache.get(f, (None,))[0] != stamp:
                    cache[f] = (stamp, yaml.safe_load(open(f, encoding="utf-8")) or {})
                meta = cache[f][1]
            except (OSError, yaml.YAMLError):
                continue
            qid = str(meta.get("id", "")).lower()
            if qid and qid != own and qid not in [q for q, _t in out]:
                out.append((qid, (meta.get("quest") or {}).get("title") or meta.get("name") or qid))
        # and the quests of others in the library (a series: this one after theirs - the manifest names it, the
        # library tells a player who lacks it)
        try:
            from . import library
            from .packaging import read_manifest
            for f in sorted(os.listdir(library.QUESTS)) if os.path.isdir(library.QUESTS) else []:
                if not f.lower().endswith(".w3q"):
                    continue
                key = os.path.join(library.QUESTS, f)
                stamp = os.path.getmtime(key)
                if cache.get(key, (None,))[0] != stamp:
                    cache[key] = (stamp, read_manifest(key))
                m = cache[key][1]
                qid = str(m.get("id", "")).lower()
                if qid and qid != own and qid not in [q for q, _t in out]:
                    out.append((qid, f"{m.get('title') or qid} (library)"))
        except Exception:                               # noqa: BLE001 - a broken file: not offered
            pass
        return out

    def _fill_after(self):
        """The 'after' list: no quest before, or one of the other projects' quests (a typed id stays in it)."""
        cur = str(self.quest().get("after") or "")
        hook = self.quest().get("after_game") or {}
        inside = self.quest().get("inside_game") or {}
        gq = self.quest().get("game_quest") or {}
        from . import features
        self.after.blockSignals(True)
        self.after.clear()
        self.after.addItem("Starts automatically", "")
        if gq.get("id"):
            self.after.addItem(f"{'With' if gq.get('when') == 'with' else 'After'}: {gq.get('title') or gq['id']}",
                               "__gq_set")
        self.after.addItem("With a game quest...", "__with")
        self.after.addItem("After a game quest...", "__after")
        if not features.experimental():             # (another project's quest, a moment inside one: the update)
            self.after.setCurrentIndex(1 if gq.get("id") else 0)
            self.after.blockSignals(False)
            return
        for qid, title in self._other_quests():
            self.after.addItem(f"after: {title}", qid)
        if cur and self.after.findData(cur) < 0:
            self.after.addItem(f"after: {cur}", cur)
        if hook.get("fact"):
            self.after.addItem(f"after: {hook.get('name')} - {hook['fact'].replace('_', ' ')}", "__hooked")
        if inside.get("phase"):
            what = str(inside.get("label") or "").split(" ", 1)[-1].split(": ", 1)[0]      # no '#<block>', no details
            self.after.addItem(f"inside: {str(inside.get('name')).split('  -  ')[0]}, after {what[:48]}",
                               "__inside_set")
            self.after.setItemData(self.after.count() - 1, inside.get("label") or "", QtCore.Qt.ToolTipRole)
        self.after.addItem("After a moment of a game quest...", "__game")
        if features.experimental():                 # (changes the game quest's file)
            self.after.addItem("Inside a game quest...", "__inside")
        self.after.setCurrentIndex(max(0, self.after.findData(
            "__inside_set" if inside.get("phase") else "__hooked" if hook.get("fact") else
            "__gq_set" if gq.get("id") else cur)))
        self.after.blockSignals(False)

    def _after_chosen(self, _index):
        data = self.after.currentData()
        if data in ("__hooked", "__inside_set", "__gq_set"):
            return
        if data in ("__with", "__after"):           # the story map: a quest picked, Start my quest with / after this
            self._fill_after()                      # (the combo shows the current choice until one is taken)
            self.ed.open_story(then=lambda: (self._fill_after(), self.sync()))
            return
        self.quest().pop("game_quest", None)
        if data == "__inside":
            def put(point):
                q = self.quest()
                q.pop("after", None)
                q.pop("after_game", None)
                q["inside_game"] = point
                self.save()
            self._fill_after()
            self.ed.panel.choose_point(put)
            return
        self.quest().pop("inside_game", None)
        if data == "__game":
            def hooked(moment):
                q = self.quest()
                q.pop("after", None)
                q["after_game"] = moment
                self.save()
            self._fill_after()                          # the combo shows the current choice until one is taken
            self.ed.panel.choose_moment(hooked)
            return
        self.quest().pop("after_game", None)
        self._set_in(self.quest(), "after", data or None, rebuild=False)

    def _fill_alive(self):
        """Must survive: people whose death fails the quest."""
        lay = self.alive_box.layout()
        while lay.count():
            w = lay.takeAt(0).widget()
            if w:
                w.hide()                # gone at once, not only once Qt deletes it
                w.deleteLater()
        q = self.quest()
        alive = q.get("keep_alive") or []
        row = [_field("Fail if killed")]
        for k, ref in enumerate(alive):
            row.append(_removable(_chip(ref.split("/")[-1].replace("_", " "), True,
                                        lambda _c=False, k=k: self._alive_remove(k), "qb.alive_remove")))
        holder = {}
        row.append(_button("+ NPC", lambda _c=False: self._toggle_picker(holder, "alive"), "qb.alive_add", "plus"))
        eg = q.get("ends_game") or {}
        from . import features
        if not features.experimental():             # game quests: the update for vanilla editing (Maxim 07.10.)
            pass
        elif eg.get("fact"):
            how = "fails" if eg.get("how", "fail") == "fail" else "succeeds"
            row.append(_removable(_chip(f"{how} at {eg.get('name', 'a game quest')}: {eg['fact'].replace('_', ' ')}",
                                        True, lambda _c=False: self._set_in(q, "ends_game", None),
                                        "qb.ends_game_remove")))
        else:
            ends = _menu_button("+ game moment", [("fail", "Fails when a game quest reaches..."),
                                                  ("success", "Succeeds when a game quest reaches...")], None,
                                lambda k: self.ed.panel.choose_moment(
                                    lambda m, k=k: self._set_in(q, "ends_game", dict(m, how=k))), "qb.ends_game")
            ends.setObjectName("plus")
            row.append(ends)
        row.append(QtWidgets.QWidget())
        row.append(_button("+ quest item", lambda _c=False: self._add_own_item(), "qb.own_add", "plus"))
        line = _row(*row, stretch_last=False)
        line.layout().setStretch(len(row) - 2, 1)      # the gap grows: '+ own item' stays small on the right
        lay.addWidget(line)
        if self.open_picker and self.open_picker[1] == "alive":
            holder["_on_set"] = self._alive_add
            lay.addWidget(self._search_list(holder, "alive", "people"))
            self._alive_holder = holder

    def _toggle_alive(self):
        self._toggle_picker({}, "alive")

    def _alive_add(self, ref):
        alive = self.quest().setdefault("keep_alive", [])
        if ref not in alive:
            alive.append(ref)
        self.open_picker = None
        self.save()

    def _alive_remove(self, k):
        alive = self.quest().get("keep_alive") or []
        alive.pop(k)
        if not alive:
            self.quest().pop("keep_alive", None)
        self.save()

    def _path_head(self, pid):
        """A path's card: its name, remove it (whatever led to it goes on in the story)."""
        p = self.paths()[pid]
        colour = QG.FAMILY["lane"] if self._is_lane(pid) else path_color(pid)
        head = QtWidgets.QFrame()
        head.setStyleSheet(f"QFrame{{background:#202024;border:1px solid #3a3a40;border-left:4px solid {colour};"
                           "border-radius:0}")
        h = QtWidgets.QHBoxLayout(head)
        h.setContentsMargins(6, 3, 4, 3)
        h.setSpacing(6)
        kind = QtWidgets.QLabel("LANE" if self._is_lane(pid) else "PATH")
        kind.setStyleSheet(f"color:{colour};font:bold 11px;border:none")
        name = QtWidgets.QLineEdit(p.get("label", ""))
        name.setPlaceholderText("Branch name")
        name.setStyleSheet(f"QLineEdit{{color:{colour};font:bold 13px;background:transparent;border:none}}")
        name.editingFinished.connect(lambda p=p, e=name: self._set_in(p, "label", e.text().strip() or None))
        tip(name, "qb.path_name")
        remove = _icon("trash-2", lambda _c=False, pid=pid: self._remove_path(pid), "qb.path_remove")
        for w in (kind, name, remove):
            h.addWidget(w, 1 if w is name else 0)
        return head

    def _path_end(self, pid):
        """Where a path goes at its end (a lane runs out)."""
        p = self.paths()[pid]
        if self._is_lane(pid):
            end = _field("At end: stop")
            tip(end, "qb.lane_end")
            return _row(end, QtWidgets.QWidget())
        e = p.get("then", "join")
        end = _menu_button(f"At end: {dict(PATH_ENDS)[e].lower()}", PATH_ENDS, e,
                           lambda k, p=p: self._set_in(p, "then", k), "qb.path_then",
                           {"join": "#bbbbbb", "success": "#9fd38a", "fail": "#e57a7a"}[e])
        return _row(end, QtWidgets.QWidget())

    def _is_lane(self, pid):
        """A path some Meanwhile step starts."""
        return any(step_kind(st)[0] == "meanwhile" and (step_kind(st)[1] or {}).get("path") == pid
                   for st in self.all_steps())

    def _chapter(self, steps, index, a):
        """A chapter's card: its title; remove the heading (its steps stay)."""
        head = QtWidgets.QFrame()
        head.setObjectName("chapter")
        head.setStyleSheet("QFrame#chapter{background:#1b1b1f;border:none;border-bottom:2px solid #6b6b74}")
        h = QtWidgets.QHBoxLayout(head)
        h.setContentsMargins(4, 8, 4, 4)
        h.setSpacing(6)
        kind = QtWidgets.QLabel("CHAPTER")
        kind.setStyleSheet("color:#9a9aa3;font:bold 11px;border:none")
        title = QtWidgets.QLineEdit(a.get("title", ""))
        title.setPlaceholderText("Chapter name")
        title.setStyleSheet("QLineEdit{color:#f0f0f0;font:bold 15px;background:transparent;border:none}")
        title.editingFinished.connect(lambda a=a, t=title: self._set_in(a, "title", t.text().strip() or None))
        tip(title, "qb.chapter_title")
        remove = _menu_button("···", [("test", "Play from here"), ("remove", "Remove chapter")], None,
                              lambda k: self._test_from(steps, index) if k == "test" else
                              (steps.pop(index), self.save()), "qb.chapter_menu")
        h.addWidget(kind)
        h.addWidget(title, 1)
        h.addWidget(remove)
        # its journal text from here on (Maxim 07.10.): a paragraph added below the others, or in their place
        box = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(4)
        v.addWidget(head)
        j = a.get("journal") if isinstance(a.get("journal"), dict) else {}
        text = QtWidgets.QPlainTextEdit(j.get("text") or "")
        text.setPlaceholderText("Journal text (optional)")
        text.setFixedHeight(54)

        def keep_text(a=a, t=text):
            jj = dict(a.get("journal") or {})
            jj["text"] = t.toPlainText().strip()
            if jj["text"]:
                jj.setdefault("mode", "add")
                a["journal"] = jj
            else:
                a.pop("journal", None)
            self.save(rebuild=False)
        timer = QtCore.QTimer(text)                     # (kept a moment after the last key, the card stays)
        timer.setSingleShot(True)
        timer.setInterval(600)
        timer.timeout.connect(keep_text)
        text.textChanged.connect(timer.start)
        tip(text, "qb.chapter_journal")
        v.addWidget(text)
        from . import features
        if features.experimental():             # in place of the others: the game turns them on again (07.10.)
            modes = [("add", "Add to journal"), ("replace", "Replace journal text")]
            mode = _menu_button(dict(modes)[j.get("mode") or "add"], modes, j.get("mode") or "add",
                                lambda k, a=a: (a.setdefault("journal", {}).update(mode=k), self.save()),
                                "qb.chapter_journal_mode")
            v.addWidget(_row(mode, QtWidgets.QWidget()))
        return box

    def _fill_jump(self, menu):
        """The chapters: a click shows it in the graph."""
        menu.clear()
        for n in self.graph.graph.nodes.values():
            if n.kind == "chapter":
                menu.addAction(n.text).triggered.connect(lambda _c=False, nid=n.id: self._graph_picked(nid))

    def _remove_path(self, pid):
        """The path goes; whatever led to it goes on in the story instead."""
        self.paths().pop(pid, None)
        from . import dialogue as D
        for st in self.all_steps():
            kind, a = step_kind(st)
            if kind == "talk":
                for x in D.walk(D.from_step(a)):
                    if x.get("end") == f"path:{pid}":
                        x["end"] = "continue"
            elif kind == "either":
                for o in a.get("options") or []:
                    if o.get("path") == pid:
                        o.pop("path")
            elif kind in ("meanwhile", "stop") and a.get("path") == pid:
                a.pop("path")
            elif kind == "random":
                for w in a.get("ways") or []:
                    if w.get("path") == pid:
                        w.pop("path")
            elif kind in ("gwent", "fistfight") and a.get("lost") == f"path:{pid}":
                a.pop("lost")
        self.save()

    def _card_menu(self, steps, i, what):
        if what == "test":
            self._test_from(steps, i)
        elif what == "copy":
            import copy
            if isinstance(steps, QG.Slot):          # a node: its copy beside it, not wired
                node = self.graph_quest()["nodes"][steps.nid]
                new = copy.deepcopy(steps[i])
                self._add_node(new, node.get("x", 0) + 40, node.get("y", 0) + 40)
                self.graph_pick = new
            else:
                steps.insert(i + 1, copy.deepcopy(steps[i]))
                self.graph_pick = steps[i + 1]
            self.save()
        elif what == "remove":
            self._remove_step(steps, i)

    def _card(self, steps, number, goal, colour=None):
        """A goal's card: its journal line, its kind, what it still needs, its editor."""
        card = QtWidgets.QFrame()
        card.setObjectName("card")
        if colour:
            card.setStyleSheet(f"#card{{border-left:3px solid {colour}}}")
        v = QtWidgets.QVBoxLayout(card)
        v.setContentsMargins(8, 6, 8, 8)
        v.setSpacing(5)
        st = steps[goal]
        kind, a = step_kind(st)
        num = QtWidgets.QLabel(str(number))
        num.setObjectName("num")
        text = QtWidgets.QLineEdit(a.get("text", ""))
        text.setPlaceholderText(self._default_text(kind, a))
        text.editingFinished.connect(lambda a=a, t=text: self._set_in(a, "text", t.text().strip() or None))
        tip(text, "qb.objective")
        if kind == "talk" and a.get("start") == "now":
            text.setText("")
            text.setPlaceholderText("A cutscene (no line in the journal)")
            text.setEnabled(False)
        head = _row(num, text, self._kind_button(steps, goal), stretch_last=False)
        head.layout().setStretch(1, 1)
        self._card_tools(head, steps, goal)
        v.addWidget(head)
        state = self._live_state(kind, a)
        if state:
            label = {1: "IN THE GAME: NOW", 2: "IN THE GAME: DONE", 3: "IN THE GAME: FAILED"}.get(state, "")
            colour = {1: "#e3c65f", 2: "#9fd38a", 3: "#e57a7a"}.get(state, "#bbb")
            live = QtWidgets.QLabel(label)
            live.setStyleSheet(f"color:{colour};font:bold 11px")
            tip(live, "qb.live")
            v.addWidget(live)
            if state == 1:
                card.setStyleSheet(card.styleSheet() + f"#card{{border:1px solid {colour}}}")
        self._missing_note(v, kind, a)
        v.addWidget(self._goal_editor(st, kind, a))
        if kind in QN.REPEATABLE and QN.is_graph(self.quest()):
            v.addWidget(self._repeat_row(st, a))
        return card

    def _again_box(self, a):
        """A talk 'every time': what one may ask when talking to them again (dialogue.again_lines) - questions of the
        talk (by their id) or of its own; none: the whole talk again."""
        from .dialogue import from_step, options
        box = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(box)
        lay.setContentsMargins(0, 4, 0, 0)
        lay.setSpacing(4)
        ag = a.get("again") or {}
        qs = ag.get("questions") or []

        def stored():                                   # (written into the step only when something is set)
            g = a.setdefault("again", {})
            return g, g.setdefault("questions", [])
        lay.addWidget(_field("when talked to again" + ("" if qs else ": the whole talk again")))
        greet = QtWidgets.QLineEdit(str(ag.get("greet") or ""))
        greet.setPlaceholderText("Greeting (optional)")
        greet.editingFinished.connect(lambda: greet.text().strip() != str(ag.get("greet") or "") and
                                      self._set_in(stored()[0], "greet", greet.text().strip() or None, rebuild=False))
        tip(greet, "qb.again_greet")
        lay.addWidget(greet)
        talk = {id(c): c for c in options(from_step(a))}
        by_id = {c.get("id"): c for c in talk.values() if c.get("id")}
        for k, it in enumerate(qs):
            if it.get("ask"):
                c = by_id.get(it["ask"])
                text = f"{c.get('text')}  (from the talk)" if c else f"{it['ask']} - no longer in the talk"
            else:
                answer = " / ".join(str(x.get("text") or "") for x in it.get("lines") or [] if "who" in x)
                text = f"{it.get('text')}" + (f"  - {answer}" if answer else "")
            lab = QtWidgets.QLabel(text)
            lab.setWordWrap(True)

            def drop(_c=False, k=k):
                del stored()[1][k]
                self.save()
            lay.addWidget(_row(lab, _icon("trash-2", drop, "qb.again_remove"), stretch_last=False))
        mine = [(oid, c) for oid, c in talk.items() if str(c.get("text") or "").strip()]

        def ask(oid):
            c = talk[oid]
            if not c.get("id"):                         # (an id of its own, to be asked again by it)
                used = set(by_id)
                n = 1
                while f"q{n}" in used:
                    n += 1
                c["id"] = f"q{n}"
            if not any(x.get("ask") == c["id"] for x in qs):
                stored()[1].append({"ask": c["id"]})
            self.save()
        lay.addWidget(_row(_menu_button("+ a question of the talk", [(oid, c["text"]) for oid, c in mine], None, ask,
                                        "qb.again_ask"), QtWidgets.QWidget()))
        q_text, a_text = QtWidgets.QLineEdit(), QtWidgets.QLineEdit()
        q_text.setPlaceholderText("The player asks...")
        a_text.setPlaceholderText("They answer...")
        tip(q_text, "qb.again_own")

        def own(_c=False):
            if not q_text.text().strip():
                return
            stored()[1].append({"text": q_text.text().strip(),
                                "lines": [{"who": "npc", "text": a_text.text().strip()}] if a_text.text().strip()
                                else []})
            self.save()
        lay.addWidget(_row(q_text, a_text, _button("+ own question", own, "qb.again_add"), stretch_last=False))
        return box

    def _repeat_row(self, st, a):
        """'Every time' (quest.py: again): the goal repeats; what its output 'every time' leads to runs each time it
        is done - until the quest ends, a fact is set, or a step is reached."""
        box = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(4)
        r = QN.repeat_of(a)

        def toggle(_c=False):
            if r is None:
                a["repeat"] = {}
            else:
                a.pop("repeat", None)
            self.save()
        on = _chip("every time", r is not None, toggle, "qb.repeat")
        if r is None:
            lay.addWidget(_row(on, QtWidgets.QWidget()))
            return box
        how = r.get("until") or "quest"

        def until(k):
            r.clear()
            if k != "quest":
                r["until"] = k
            self.save()
        hows = [("quest", "the quest ends"), ("fact", "a fact is set"), ("node", "a step is reached")]
        lay.addWidget(_row(on, _field("until"), _menu_button(dict(hows)[how], hows, how, until, "qb.repeat_until"),
                           QtWidgets.QWidget()))
        if QN.step_kind(st)[0] == "talk":
            lay.addWidget(self._again_box(a))
        if how == "fact":
            name = QtWidgets.QLineEdit(str(r.get("fact") or ""))
            name.setPlaceholderText("Fact name")
            name.editingFinished.connect(lambda: self._set_in(r, "fact", _fact_typed(name) or None))
            tip(name, "qb.repeat_fact")
            lay.addWidget(_row(_field("fact"), name))
        elif how == "node":
            q = self.graph_quest()
            mine = self.node_of(st)
            entries = []
            for nid in QN.order(q):
                k, x = QN.step_kind(q["nodes"][nid]["step"])
                if nid == mine or k in ("start",):
                    continue
                words = (x or {}).get("text") or self._default_text(k, x or {})
                entries.append((nid, f"{QG.LABEL.get(k, k)}: {words}"))
            cur = r.get("node")
            lay.addWidget(_row(_field("step"), _menu_button(dict(entries).get(cur, "choose a step"), entries, cur,
                                                            lambda nid: self._set_in(r, "node", nid),
                                                            "qb.repeat_node"), QtWidgets.QWidget()))
        return box

    def _kind_button(self, steps, i):
        """The step's kind: a menu of the other kinds of its block (a wrong pick is one click away)."""
        kind = step_kind(steps[i])[0]
        block = QG.block_of(kind)
        kinds = [(k, QG.LABEL.get(k, k)) for k in QG.KINDS_OF.get(block, [kind])]
        kl = _menu_button(QG.LABEL.get(kind, kind).upper(), kinds, kind,
                          lambda k, steps=steps, i=i: self._set_kind(steps, i, k), "qb.step_kind")
        kl.setObjectName("kindmenu")
        return kl

    def _card_tools(self, row, steps, i):
        nid = self.node_of(steps[i]) if QN.is_graph(self.quest()) else None
        if nid is not None:
            # its ways and circles in the world: always (eye open) or only while its card is open (shut)
            node = self.graph_quest()["nodes"][nid]
            row.layout().addWidget(_icon("eye-off" if node.get("hidden") else "eye",
                                         lambda _c=False, node=node: self._toggle_eye(node), "qb.eye"))
        row.layout().addWidget(_menu_button("···", CARD_MENU, None,
                                            lambda k, steps=steps, i=i: self._card_menu(steps, i, k),
                                            "qb.card_menu"))
        row.layout().addWidget(_icon("trash-2", lambda _c=False, steps=steps, i=i: self._remove_step(steps, i),
                                       "qb.remove"))

    def _toggle_eye(self, node):
        if node.get("hidden"):
            node.pop("hidden")
        else:
            node["hidden"] = True
        self.save()
        if getattr(self.ed, "hud", None) is not None:
            self.ed.hud.update()

    def _missing_note(self, v, kind, a):
        gaps = missing(kind, a)
        if gaps:
            v.addWidget(_missing_row("Missing: " + ", ".join(gaps)))

    def _step_card(self, steps, i, colour=None):
        """The card of an action, a choice, a lane, an end: its kind, what it still needs, what it does."""
        kind, a = step_kind(steps[i])
        card = QtWidgets.QFrame()
        card.setObjectName("card")
        if colour:
            card.setStyleSheet(f"#card{{border-left:3px solid {colour}}}")
        v = QtWidgets.QVBoxLayout(card)
        v.setContentsMargins(8, 6, 8, 8)
        v.setSpacing(5)
        head = _row(self._kind_button(steps, i), QtWidgets.QWidget(), stretch_last=False)
        head.layout().setStretch(1, 1)
        self._card_tools(head, steps, i)
        v.addWidget(head)
        self._missing_note(v, kind, a)
        if kind in QG.PLACEHOLDERS:
            from .catalog_view import Flow
            flow = QtWidgets.QWidget()
            h = Flow(flow)
            for k in QG.KINDS_OF[kind]:
                h.addWidget(_button(QG.LABEL.get(k, k), lambda _c=False, k=k: self._set_kind(steps, i, k),
                                    f"step.{k}"))
            v.addWidget(flow)
        elif kind == "end":
            v.addWidget(_row(_field("the quest"),
                             _chip("succeeds", a.get("how") != "fail", lambda _c=False: self._set_in(a, "how", None),
                                   "qb.end_success"),
                             _chip("fails", a.get("how") == "fail", lambda _c=False: self._set_in(a, "how", "fail"),
                                   "qb.end_fail"), QtWidgets.QWidget()))
        elif kind == "if":
            v.addWidget(self._if_editor(a))
        else:
            v.addWidget(self._action_row(steps, i, alone=True))
        return card

    def _if_by(self, a, how):
        """If by a path taken or by a fact - the other one's fields go (an empty fact name still says 'by a fact')."""
        if how == "fact":
            a.pop("path", None)
            a.setdefault("fact", "")
        else:
            for key in ("fact", "op", "value"):
                a.pop(key, None)
        self.save()

    def _if_fact(self, a, name):
        a["fact"] = name                        # (empty: still an If by a fact, its name not typed yet)
        self.save()

    def _if_editor(self, a):
        """If: a path taken before (the quest remembers every path it went), or a fact - or several conditions of
        the game's (the list: _conditions_editor)."""
        if a.get("conditions"):
            return self._conditions_editor(a)
        box = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(4)
        how = "fact" if a.get("fact") is not None and not a.get("path") else "path"
        entries = [(pid, p.get("label") or pid) for pid, p in self.paths().items()]
        cur = a.get("path")
        choose = _menu_button(f"'{dict(entries).get(cur, cur)}' was taken" if cur else "Branch not set",
                              entries, cur, lambda pid: (a.pop("fact", None), self._set_in(a, "path", pid)),
                              "qb.if_path")
        lay.addWidget(_row(_chip("a branch was taken", how == "path", lambda _c=False: self._if_by(a, "path"),
                                 "qb.if_by_path"),
                           _chip("a fact", how == "fact", lambda _c=False: self._if_by(a, "fact"), "qb.if_by_fact"),
                           QtWidgets.QWidget()))
        if how == "path":
            lay.addWidget(_row(_field("if"), choose, QtWidgets.QWidget()))
        else:
            name = QtWidgets.QLineEdit(str(a.get("fact") or ""))
            name.setPlaceholderText("Fact name")
            name.editingFinished.connect(lambda: self._if_fact(a, _fact_typed(name)))
            tip(name, "qb.if_fact")
            op = _menu_button(a.get("op") or ">=", [(o, o) for o in ("=", "!=", ">=", ">", "<=", "<")],
                              a.get("op") or ">=", lambda o: self._set_in(a, "op", o), "qb.if_op")
            val = QtWidgets.QSpinBox()
            val.setRange(-1000, 1000)
            val.setValue(int(a.get("value", 1)))
            val.editingFinished.connect(lambda: self._set_in(a, "value", val.value()))
            tip(val, "qb.if_value")
            lay.addWidget(_row(_field("if"), name, op, val, stretch_last=False))
        lay.addWidget(_row(_button("+ condition", lambda _c=False: (self._to_conditions(a).append({"kind": "area"}),
                                                                    self.save()), "qb.cond_add"),
                           QtWidgets.QWidget()))
        return box

    def _to_conditions(self, a):
        """The older If / Wait until (a fact, a branch) as the first of a list of conditions."""
        from .quest import conditions_of
        if "conditions" not in a:
            a["conditions"] = conditions_of(a)
            for key in ("fact", "op", "value", "path", "from"):
                a.pop(key, None)
        return a["conditions"]

    def _conditions_editor(self, a, waiting=False):
        """If / Wait until: its conditions (quest.condition) - each a kind, its fields and 'not'; '+ condition'; with
        more than one: all of them or one of them."""
        from .quest import COND_KINDS, QUEST_STATES, WAIT_KINDS, cond_kind
        box = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(box)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(4)
        conds = a.get("conditions") or []
        kinds = [(k, label) for k, label in COND_KINDS if not waiting or k in WAIT_KINDS]
        if len(conds) > 1:
            lay.addWidget(_row(_chip("all of these", not a.get("any"), lambda _c=False: self._set_in(a, "any", None),
                                     "qb.cond_all"),
                               _chip("one of them", bool(a.get("any")), lambda _c=False: self._set_in(a, "any", True),
                                     "qb.cond_any"), QtWidgets.QWidget()))
        for k, c in enumerate(conds):
            kind = cond_kind(c)

            def set_kind(new, c=c):
                keep = {"not": c["not"]} if c.get("not") else {}
                c.clear()
                c.update(dict(keep, kind=new))
                self.save()

            def drop(_c=False, k=k):
                del conds[k]
                self.save()
            head = _row(_menu_button(dict(kinds).get(kind, kind), kinds, kind, set_kind, "qb.cond_kind"),
                        _chip("not", bool(c.get("not")),
                              lambda _c=False, c=c: self._set_in(c, "not", None if c.get("not") else True),
                              "qb.cond_not"),
                        QtWidgets.QWidget(), _icon("trash-2", drop, "qb.cond_remove"), stretch_last=False)
            head.layout().setStretch(2, 1)
            lay.addWidget(head)
            lay.addWidget(self._condition_fields(c, kind, QUEST_STATES))
        lay.addWidget(_row(_button("+ condition", lambda _c=False: (conds.append({"kind": "fact"}), self.save()),
                                   "qb.cond_add"), QtWidgets.QWidget()))
        return box

    def _condition_fields(self, c, kind, states):
        """The fields of one condition."""
        if kind == "fact":
            name = QtWidgets.QLineEdit(str(c.get("fact") or ""))
            name.setPlaceholderText("Fact name")
            name.editingFinished.connect(lambda: self._set_in(c, "fact", _fact_typed(name) or None))
            tip(name, "qb.if_fact")
            op = _menu_button(c.get("op") or ">=", [(o, o) for o in ("=", "!=", ">=", ">", "<=", "<")],
                              c.get("op") or ">=", lambda o: self._set_in(c, "op", o), "qb.if_op")
            val = QtWidgets.QSpinBox()
            val.setRange(-1000, 1000)
            val.setValue(int(c.get("value", 1)))
            val.editingFinished.connect(lambda: self._set_in(c, "value", val.value()))
            tip(val, "qb.if_value")
            return _row(name, op, val, stretch_last=False)
        if kind == "path":
            entries = [(pid, p.get("label") or pid) for pid, p in self.paths().items()]
            cur = c.get("path")
            return _row(_menu_button(f"'{dict(entries).get(cur, cur)}' was taken" if cur else "Which branch",
                                     entries, cur, lambda pid: self._set_in(c, "path", pid), "qb.if_path"),
                        QtWidgets.QWidget())
        if kind == "area":
            box = QtWidgets.QWidget()
            v = QtWidgets.QVBoxLayout(box)
            v.setContentsMargins(0, 0, 0, 0)
            v.setSpacing(3)
            v.addWidget(self._place_field(c))
            v.addWidget(_row(_field("within"), self._spin(c, "radius", 1, 200, " m", 10), QtWidgets.QWidget()))
            return box
        if kind == "item":
            return _row(_field("has"), self._spin(c, "count", 1, 999, "", 1), self._item_line(c), stretch_last=True)
        if kind == "quest":
            return self._quest_state_field(c, states)
        if kind == "time":
            fr, to = QtWidgets.QLineEdit(c.get("from") or "20:00"), QtWidgets.QLineEdit(c.get("to") or "06:00")
            for key, w in (("from", fr), ("to", to)):
                w.setInputMask("99:99")
                w.setFixedWidth(60)
                w.editingFinished.connect(lambda key=key, w=w: self._set_in(c, key, w.text(), rebuild=False))
                tip(w, "qb.cond_time")
            return _row(_field("from"), fr, _field("to"), to, QtWidgets.QWidget())
        if kind == "present":
            return self._target_field(c, "who", "who", "people")
        return _field("the player is in a fight" if kind == "combat" else "")

    def _quest_state_field(self, c, states):
        """A quest's (an objective's) state: the entry typed - the game's quests and objectives offered - and its
        state (running, done, failed)."""
        from . import journal_index as J
        q = c.get("quest") or {}
        line = QtWidgets.QLineEdit(q.get("label") or "")
        line.setPlaceholderText("A quest or objective of the game...")
        tip(line, "qb.cond_quest")
        index = J.load() or {}                          # (made by the quest graph's journal picker; none: typed only)
        entries = [e for e in index.get("entries") or [] if e.get("kind") in ("quest", "objective")]
        by_label = {e["label"]: e for e in entries}
        comp = QtWidgets.QCompleter(sorted(by_label))
        comp.setCaseSensitivity(Q.CaseInsensitive)
        comp.setFilterMode(Q.MatchContains)
        line.setCompleter(comp)

        def chosen(text=None):
            e = by_label.get((text or line.text()).strip())
            if e and e["label"] != q.get("label"):
                self._set_in(c, "quest", {"label": e["label"], "file": e["file"], "obj": e["obj"], "key": e["key"]})
        comp.activated.connect(chosen)
        line.editingFinished.connect(chosen)
        cur = c.get("state") or "done"
        state = _menu_button(dict((k, label) for k, label, _s in states)[cur], [(k, label) for k, label, _s in states],
                             cur, lambda k: self._set_in(c, "state", k), "qb.cond_state")
        row = _row(line, state, stretch_last=False)
        row.layout().setStretch(0, 1)
        return row

    def _default_text(self, kind, a):
        from .quest import default_text
        from .quest import display_names
        return default_text(kind, a, self.quest().get("items"), display_names(self.ed.project))

    def _more_open(self, a, set_):
        """A card's extra options show when asked for (or when one of them is set - nothing that works is hidden)."""
        return set_ or id(a) in self.more

    def _more_link(self, a, text):
        b = _button(text, lambda _c=False: self._toggle_more(a), "qb.more", "more")
        return _row(b, QtWidgets.QWidget())

    def _toggle_more(self, a):
        self.more.symmetric_difference_update({id(a)})
        self.sync()

    def _map_mark(self, a):
        """How the map shows where to go: an exact pin, or a search area (a circle, as big as asked)."""
        kind = Combo()
        kind.addItems(["area", "pin"])
        kind.setCurrentText(a.get("map", "area"))
        tip(kind, "qb.map_mark")
        size = QtWidgets.QSpinBox()
        size.setRange(2, 500)
        size.setValue(int(a.get("map_radius") or a.get("radius", 10)))
        size.setEnabled(kind.currentText() == "area")
        tip(size, "qb.map_radius")

        def set_kind(text):
            if text == "pin":
                a["map"] = "pin"
            else:
                a.pop("map", None)
            size.setEnabled(text == "area")
        kind.currentTextChanged.connect(set_kind)

        def set_size():
            if size.value() == int(a.get("radius", 10)):
                a.pop("map_radius", None)               # the same as the arrival circle: nothing to keep
            else:
                a["map_radius"] = size.value()
        size.editingFinished.connect(set_size)
        from .fields import with_unit
        return _row(_field("map"), kind, with_unit(size, "m"), QtWidgets.QWidget())

    def _use_how(self, a):
        """Use: when it counts - used at all, a lever switched on / off, or an item used on it (the item goes)."""
        how = "item" if "item" in a else a.get("state", "")
        row = [_field("done when"), _menu_button(dict(USE_HOW)[how], USE_HOW, how,
                                                 lambda k: self._use_mode(a, k), "qb.use_how")]
        if how == "item":
            row.append(self._item_line(a))
        return _row(*row, QtWidgets.QWidget()) if how != "item" else _row(*row)

    def _use_mode(self, a, how):
        a.pop("state", None)
        if how != "item":
            a.pop("item", None)
        if how in ("on", "off"):
            a["state"] = how
        elif how == "item" and not a.get("item"):
            a["item"] = ""                          # the field shows; empty until typed
        self.save()

    def _when_stay(self, a):
        """Go to only at a time of day; leaving again before that fails the quest."""
        when = Combo()
        when.addItems(["Any time", "morning", "day", "evening", "night"])
        if a.get("when") in ("morning", "day", "evening", "night"):
            when.setCurrentText(a["when"])
        elif a.get("when"):
            when.addItem(str(a["when"]))                # own hours ("21-3") stay as they are
            when.setCurrentText(str(a["when"]))
        tip(when, "qb.when")

        def set_when(text):
            if text == "any time":
                a.pop("when", None)
            else:
                a["when"] = text
        when.currentTextChanged.connect(set_when)
        stay = QtWidgets.QCheckBox("Fail on leaving")
        stay.setChecked(bool(a.get("stay")))
        tip(stay, "qb.stay")

        def set_stay(on):
            if on:
                a["stay"] = True
            else:
                a.pop("stay", None)
        stay.toggled.connect(set_stay)
        return _row(_field("when"), when, stay, QtWidgets.QWidget())

    # --- goal editors (on the step's own dict)
    def _goal_editor(self, st, kind, a):
        box = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(4)
        if kind == "talk":
            v.addWidget(self._target_field(a, "npc", "who", "people"))
            mouth = self._mouth_row(a.get("npc"))
            if mouth is not None:
                v.addWidget(mouth)
            v.addWidget(self._talk_start(a))
            v.addWidget(self._dialogue_preview(st, a))
        elif kind == "goto":
            modes = [("arrive", "Arrive"), ("leave", "Leave the area"), ("near", "Near a character"),
                     ("look", "Look at")]
            mode = a.get("mode") or "arrive"
            v.addWidget(_row(_menu_button(dict(modes)[mode], modes, mode,
                                          lambda k: self._set_in(a, "mode", None if k == "arrive" else k),
                                          "qb.goto_mode"), QtWidgets.QWidget()))
            if mode == "near":
                v.addWidget(self._target_field(a, "who", "who", "people"))
                r = QtWidgets.QSpinBox()
                r.setRange(1, 200)
                r.setValue(int(a.get("radius", 5)))
                self._live(r, lambda v, a=a: self._set_in(a, "radius", v, rebuild=False))
                tip(r, "qb.radius")
                from .fields import with_unit
                v.addWidget(_row(_field("within"), with_unit(r, "m"), QtWidgets.QWidget()))
                return box
            if mode == "look":
                v.addWidget(self._target_field(a, "who", "who", "people"))
                v.addWidget(_row(_field("for"), self._spin(a, "seconds", 1, 60, " s", 3), _field("within"),
                                 self._spin(a, "radius", 1, 200, " m", 20), QtWidgets.QWidget()))
                return box
            v.addWidget(self._place_field(a))
            # radius, map and time always open (Maxim 08.10.: a Go to nearly always needs them)
            r = QtWidgets.QSpinBox()
            r.setRange(1, 200)
            r.setValue(int(a.get("radius", 10)))
            self._live(r, lambda v, a=a: self._set_in(a, "radius", v, rebuild=False))
            tip(r, "qb.radius")
            from .fields import with_unit
            v.addWidget(_row(_field("radius"), with_unit(r, "m"), QtWidgets.QWidget()))
            v.addWidget(self._map_mark(a))
            v.addWidget(self._when_stay(a))
        elif kind in ("loot", "examine", "use"):
            # what to loot: anything but Geralt's stash (Maxim 08.10.: it was offered, its items never show)
            v.addWidget(self._target_field(a, "object", "what", "loot" if kind == "loot" else "things"))
            if kind == "use":                       # used / a lever switched on or off / an item used on it
                v.addWidget(self._use_how(a))
            if kind == "loot":                      # empty: opening it is enough; items: taking them out
                take = self._item_line(a, required=False)
                tip(take, "qb.loot_take")
                v.addWidget(_row(_field("take"), take))
                self._more_items(v, a)
        elif kind == "kill":
            # one or several: all of them
            if a.get("target") and not a.get("targets"):
                a["targets"] = [a.pop("target")]
            targets = a.setdefault("targets", [])
            holders = [{"target": t} for t in targets] + ([{}] if not targets else [])
            for k, hd in enumerate(holders):
                tf = self._target_field(hd, "target", "who" if k == 0 else "and", "creatures",
                                        on_set=lambda ref, k=k: self._set_target(a, k, ref),
                                        ident=(id(a), "targets", k))
                if k and targets:
                    tf.layout().itemAt(0).widget().layout().addWidget(
                        _icon("trash-2", lambda _c=False, k=k: self._remove_target(a, k), "qb.remove_action"))
                v.addWidget(tf)
            self._merchant_note(v, targets)
            row = [_button("+ who", lambda _c=False: self._add_target(a), "qb.kill_add", "plus")] if targets else []
            if self.waiting and self.waiting[:2] == (id(a), "group"):
                row.append(_button("Click in the world. Esc cancels", lambda _c=False: self.ed.cancel_request(),
                                   "qb.kill_group"))
            else:
                group = _menu_button("+ group", [(n, f"a group of {n}") for n in (2, 3, 4, 5, 6, 8)], None,
                                     lambda n, a=a: self._add_group(a, n), "qb.kill_group")
                group.setObjectName("plus")
                row.append(group)
            v.addWidget(_row(*row, QtWidgets.QWidget()))
        elif kind == "race":
            v.addWidget(self._path_field(a))
            racers = a.setdefault("racers", [])
            holders = [{"who": r} for r in racers] + ([{}] if not racers else [])
            for k, hd in enumerate(holders):
                def put(ref, k=k):
                    rs = a.setdefault("racers", [])
                    if k < len(rs):
                        rs[k] = ref
                    else:
                        rs.append(ref)
                    self.save()
                tf = self._target_field(hd, "who", "against" if k == 0 else "and", "people", on_set=put,
                                        ident=(id(a), "racers", k))
                if k and racers:
                    tf.layout().itemAt(0).widget().layout().addWidget(
                        _icon("trash-2", lambda _c=False, k=k: (a["racers"].pop(k), self.save()), "qb.race_remove"))
                v.addWidget(tf)
            paces = [("easy", "easy (they run)"), ("normal", "normal (fast)"), ("hard", "hard (they sprint)")]
            pace = a.get("pace") or "normal"
            add = _button("+ who", lambda _c=False: (a.setdefault("racers", []).append(""), self.save()),
                          "qb.race_add", "plus")
            v.addWidget(_row(add, _field("pace"), _menu_button(dict(paces)[pace], paces, pace,
                                                               lambda k: self._set_in(a, "pace", k), "qb.race_pace"),
                             _field("checkpoints"), self._spin(a, "radius", 2, 30, " m", 6), QtWidgets.QWidget()))
        elif kind == "follow":
            v.addWidget(self._target_field(a, "who", "who", "people"))
            v.addWidget(self._path_field(a))
            how = _menu_button("The player leads" if a.get("lead") else "The player follows",
                               [(False, "The player follows"), (True, "The player leads")], bool(a.get("lead")),
                               lambda k: self._set_in(a, "lead", k or None), "qb.follow_lead")
            pace = _menu_button("runs" if a.get("run") else "walks", [(False, "walks"), (True, "runs")],
                                bool(a.get("run")), lambda k: self._set_in(a, "run", k or None), "qb.follow_run")
            row = [_field("how"), how, pace]
            if not a.get("lead"):
                row += [_field("waits beyond"), self._spin(a, "wait", 3, 60, " m", 10)]
            v.addWidget(_row(*row, QtWidgets.QWidget()))
            if not a.get("lead"):
                self._walk_talks(v, a)
        elif kind == "read":
            v.addWidget(_row(_field("what"), self._item_line(a)))
        elif kind == "notice":
            from .dialogue_view import AutoText
            if not str(a.get("board") or "").startswith("tag:"):
                v.addWidget(self._target_field(a, "board", "board", "things"))
            game = str(a.get("board") or "")
            v.addWidget(_row(_field("board" if game.startswith("tag:") else "or the game's"), _menu_button(
                game[4:].replace("_", " ") if game.startswith("tag:") else "A notice board of the game",
                self._game_boards(), game, lambda k, a=a: self._set_in(a, "board", k), "qb.notice_game_board"),
                QtWidgets.QWidget()))
            v.addWidget(_row(_field("title"), self._text_line(a, "title", "the notice's title on the board")))
            text = AutoText(a.get("body", ""), "what the notice says")
            text.done.connect(lambda t, a=a: self._set_in(a, "body", t.strip() or None, rebuild=False))
            tip(text, "qb.notice_text")
            v.addWidget(text)
            v.addWidget(_row(_field("gives"), self._item_line(a, placeholder="A note to read again (optional)",
                                                              required=False, removable=True)))
        elif kind == "defeat":
            v.addWidget(self._target_field(a, "target", "who", "people"))
            v.addWidget(_row(_field("until health below"), self._spin(a, "below", 5, 90, " %", 20),
                             QtWidgets.QWidget()))
        elif kind == "waitfact":
            if a.get("conditions"):
                v.addWidget(self._conditions_editor(a, waiting=True))
            else:
                v.addWidget(self._fact_field(a))
                v.addWidget(_row(_button("+ condition", lambda _c=False, a=a: (
                    self._to_conditions(a).append({"kind": "area"}), self.save()), "qb.cond_add"),
                    QtWidgets.QWidget()))
        elif kind == "gwent":
            self._gwent(v, a)
        elif kind == "fistfight":
            self._fistfight(v, a)
        elif kind == "equip":
            v.addWidget(_row(_field("what"), self._item_line(a)))
            self._more_items(v, a)
        elif kind == "collect":
            v.addWidget(self._item_field(a))
            self._more_items(v, a)
            if a.get("item"):                       # the next thing: where it is
                v.addWidget(self._source_field(a))
        elif kind == "wait":
            until = bool(a.get("until"))
            how = _menu_button("Until the hour" if until else "Game time", [(False, "Game time"),
                                                                          (True, "Until the hour")], until,
                               lambda k: self._wait_mode(a, k), "qb.wait_mode")
            t = QtWidgets.QLineEdit(a.get("until", "22:00") if until else a.get("time", "00:00:10"))
            t.setInputMask("99:99" if until else "99:99:99")
            t.editingFinished.connect(lambda a=a, t=t, until=until: self._set_in(
                a, "until" if until else "time", t.text(), rebuild=False))
            tip(t, "qb.time_at" if until else "qb.time")
            v.addWidget(_row(_field("wait"), how, t, QtWidgets.QWidget()))
        elif kind == "waitfor":
            what = a.get("what") or "senses"
            how = _menu_button(dict(WAIT_FOR)[what], WAIT_FOR, what,
                               lambda k: self._set_in(a, "what", k), "qb.waitfor")
            parts = [_field("for"), how]
            if what == "health":
                pc = QtWidgets.QSpinBox()
                pc.setRange(1, 99)
                pc.setValue(int(a.get("percent", 30)))
                pc.setSuffix(" %")
                self._live(pc, lambda v, a=a: self._set_in(a, "percent", v, rebuild=False))
                tip(pc, "qb.waitfor_percent")
                parts.append(pc)
            v.addWidget(_row(*parts, QtWidgets.QWidget()))
        elif kind == "either":
            self._either_editor(v, a)
        elif kind == "all":
            self._either_editor(v, a, every=True)
        elif kind == "clues":
            self._clues_editor(v, a)
        return box

    HOW = [("", "Default"), ("ground", "Ground"), ("eye", "Eye level"), ("body", "Body"),
           ("high", "up high")]

    def _clues_editor(self, v, a):
        """The clues: each something to examine (any object - how Geralt bends to it; a line after, or a talk with
        himself) or a trail from the library (drawn in the world; a line when he sees it); in order: each opens the
        next."""
        items = a.setdefault("clues", [])
        order = QtWidgets.QCheckBox("In sequence")
        order.setChecked(bool(a.get("in_order")))
        order.toggled.connect(lambda on: self._set_in(a, "in_order", True if on else None, rebuild=False))
        tip(order, "qb.clues_order")
        v.addWidget(_row(order, QtWidgets.QWidget()))
        for k, c in enumerate(items):
            row = QtWidgets.QFrame()
            row.setStyleSheet("QFrame{background:#222226;border:1px solid #3a3a40;border-radius:0}"
                              "QLabel{border:none}")
            rv = QtWidgets.QVBoxLayout(row)
            rv.setContentsMargins(6, 4, 6, 4)
            rv.setSpacing(3)
            if "trail" in c and not c.get("object"):
                self._trail_rows(rv, c, k)
            else:
                self._examine_rows(rv, c, k)
            rv.addWidget(_row(QtWidgets.QWidget(), _icon(
                "trash-2", lambda _c=False, k=k: self._remove_clue(items, k), "qb.remove_action"), stretch_last=False))
            rv.itemAt(rv.count() - 1).widget().layout().setStretch(0, 1)
            v.addWidget(row)
        from . import trails
        kinds = [(key, f"{group}: {label}") for key, label, group, _t, _s in trails.LIBRARY]
        add_trail = _menu_button("+ track", kinds, None, lambda key: self._add_trail(items, key), "qb.trail_add")
        v.addWidget(_row(_button("+ examine", lambda _c=False: self._add_clue(items), "qb.clue_add", "plus"),
                         add_trail, QtWidgets.QWidget(), stretch_last=True))

    def _examine_rows(self, rv, c, k):
        rv.addWidget(self._target_field(c, "object", f"examine {k + 1}", "things"))
        o = self._object(c.get("object")) if c.get("object") else None
        from .quest import is_clue_template
        if o is not None and not is_clue_template(o["template"]):
            # not one of the game's clues: examinable, but it does not glow in the witcher senses (01.10.: the
            # corpse was hard to find) - one of the same kind that does, where it lies
            warn = _missing_row("Not highlighted in witcher senses")
            warn.layout().addWidget(_button("Swap for clue", lambda _c=False, c=c: self._swap_for_clue(c),
                                            "qb.clue_swap"), 0)
            rv.addWidget(warn)
        how = _menu_button("Animation: " + dict(self.HOW).get(c.get("how") or "", "Default"), self.HOW,
                           c.get("how") or "", lambda key: self._set_in(c, "how", key or None), "qb.clue_how")
        talk = c.get("dialogue")
        after = _menu_button("Then: monologue" if talk is not None else "Then: comment",
                             [("line", "Then: comment"), ("talk", "Then: monologue")],
                             "talk" if talk is not None else "line", lambda key: self._clue_after(c, key),
                             "qb.clue_after")
        rv.addWidget(_row(how, after, QtWidgets.QWidget()))
        if talk is not None:
            n = sum(1 for _x in D_walk(talk))
            rv.addWidget(_row(_field(f"{n} lines and choices" if n else "nothing yet"), QtWidgets.QWidget(),
                              _button("Edit monologue", lambda _c=False: self._open_monologue(c), "qb.clue_talk"),
                              stretch_last=False))
            rv.itemAt(rv.count() - 1).widget().layout().setStretch(1, 1)
        else:
            rv.addWidget(self._say_field(c.setdefault("says", {})))
        trail = c.get("trail") or []                    # (the older form: pieces leading to it, placed one by one)
        for j, piece in enumerate(trail):
            tf = self._target_field({"object": piece}, "object", "trail", "clues",
                                    on_set=lambda ref, c=c, j=j: self._set_listed(c, "trail", j, ref),
                                    ident=(id(c), "trail", j))
            tf.layout().itemAt(0).widget().layout().addWidget(
                _icon("trash-2", lambda _c=False, c=c, j=j: self._remove_listed(c, "trail", j), "qb.remove_action"))
            rv.addWidget(tf)

    def _effect_names(self, ref):
        """The effects the object's template defines (fx.py) - offered instead of a typed name."""
        o = self._object(ref) if ref else None
        if o is None:
            return []
        from .fx import effects_of
        return effects_of(o["template"])

    def _point_button(self, a, key, label, tip_key="qb.portal_point"):
        pos = a.get(key)
        waiting = self.waiting and self.waiting[:2] == (id(a), key)
        b = _button("Click in the world. Esc cancels" if waiting else
                    (f"{label}: {pos[0]:.0f}, {pos[1]:.0f}, {pos[2]:.0f}" if pos else f"{label}: pick a point"),
                    lambda _c=False: self._request_point(a, key), tip_key,
                    "target" if pos else "target_empty")
        return b

    def _portal_card(self, a):
        """From an object (the portal), to a point; back again (two-way) from a second object to a second point;
        the fade's colour and the effect that shows them open."""
        box = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(3)
        v.addWidget(self._target_field(a, "a", "from", "things"))
        v.addWidget(_row(_field("to"), self._point_button(a, "b_exit", "arrive"), QtWidgets.QWidget()))
        two = _chip("two-way", bool(a.get("two_way")), lambda _c=False: self._set_in(a, "two_way", None if a.get(
            "two_way") else True), "qb.portal_two_way")
        white = _chip("white fade", a.get("white", True) is not False, lambda _c=False: self._set_in(
            a, "white", False if a.get("white", True) is not False else None), "qb.portal_white")
        v.addWidget(_row(two, white, QtWidgets.QWidget()))
        if a.get("two_way"):
            v.addWidget(self._target_field(a, "b", "back from", "things"))
            v.addWidget(_row(_field("back to"), self._point_button(a, "a_exit", "arrive"), QtWidgets.QWidget()))
        names = self._effect_names(a.get("a"))
        if names:
            eff = _menu_button(f"effect: {a.get('effect') or 'none'}", [("", "none")] + [(n, n) for n in names],
                               a.get("effect") or "", lambda k: self._set_in(a, "effect", k or None), "qb.portal_effect")
            v.addWidget(_row(eff, QtWidgets.QWidget()))
        return box

    def _swap_for_clue(self, c):
        """The examined object becomes a clue of its kind (same place, turn, id): chosen in the catalog."""
        db = self.assets()
        o = self._object(c.get("object"))
        row = db.template(o["template"]) if db is not None and o else None
        kind = f"{row['cat']}/{row['sub']}" if row and row.get("cat") == "Decoration" else ""

        def chosen(path, o=o):
            o["template"] = path
            place = c["object"].partition("/")[0]
            self.ed.project.save_place(place)
            if getattr(self.ed, "editing", False) and place == self.ed.place:
                self.ed.load_place()                    # the new one stands there now
            self.save()
        self.choose("clue_swap:" + kind, chosen)

    def _trail_rows(self, rv, c, k):
        from . import trails
        o = self._object(c.get("trail"))
        kind = (o or {}).get("trail") or c.get("kind")
        label = trails.BY_KEY.get(kind, ("trail",))[0]
        drawing = getattr(self, "drawing", None)
        if drawing and drawing["c"] is c:
            text = f"{label}: {len(drawing['points'])} points. Enter: done, Esc: cancel"
            rv.addWidget(_row(_field(f"track {k + 1}"), _field(text), stretch_last=True))
        else:
            n = len((o or {}).get("pieces") or [])
            text = f"{label} · {n} pieces" if n else f"{label} · not drawn yet"
            rv.addWidget(_row(_field(f"track {k + 1}"), _field(text), QtWidgets.QWidget(), _button(
                "Redraw track" if n else "Draw track", lambda _c=False: self._draw_trail(c, kind), "qb.trail_draw",
                "target" if n else "target_empty"), stretch_last=False))
            rv.itemAt(rv.count() - 1).widget().layout().setStretch(2, 1)
        rv.addWidget(self._say_field(c.setdefault("says", {})))

    def _object(self, ref):
        found = self._find(ref) if ref else None
        return self.ed.project.places[found[0]]["objects"][found[1]] if found else None

    def _add_clue(self, items):
        items.append({"says": {}})
        self.save()

    def _add_trail(self, items, kind):
        c = {"trail": None, "kind": kind, "says": {}}
        items.append(c)
        self.save()
        self._draw_trail(c, kind)

    def _remove_clue(self, items, k):
        c = items[k]
        if c.get("trail") and not c.get("object"):     # its trail goes with it (drawn for this entry)
            found = self._find(c["trail"])
            if found:
                self._remove_object(*found)
        if getattr(self, "drawing", None) and self.drawing["c"] is c:
            self.drawing = None
            self.ed.cancel_request()
        self._remove_option(items, k)

    def _clue_after(self, c, key):
        if key == "talk":
            c.setdefault("dialogue", [])
        else:
            c.pop("dialogue", None)
        self.save()

    def _open_monologue(self, c):
        """The talk with himself in the dialogue editor: only the player speaks, an answer is chosen, not said."""
        c.setdefault("dialogue", [])
        self.open_dialogue({"examine": c})

    # --- drawing a trail: points clicked in the world (Enter: done, Esc: stop), the pieces laid on the ground
    def _draw_trail(self, c, kind):
        """The trail's way drawn with the path tool (pathtool.py); Enter lays its pieces along it."""
        self.drawing = {"c": c, "kind": kind, "points": [], "place": self.ed.place}
        d = self.drawing

        def done(points, d=d):
            d["points"] = points
            self.finish_trail()

        def cancel(_points, d=d):
            if getattr(self, "drawing", None) is d:
                self.drawing = None
            self.sync()
        from .pathtool import PathTool
        if getattr(self.ed, "path_tool", None) is not None:
            self.ed.path_tool.cancel()
        PathTool(self.ed, [], done, label=kind.replace("_", " ") + " trail", on_cancel=cancel, min_points=2).start()
        self.sync()

    def finish_trail(self):
        """Enter: the trail along the points drawn - its pieces asked for the ground under them."""
        from . import trails
        d = getattr(self, "drawing", None)
        if d is None or getattr(self.ed, "path_tool", None) is not None:
            return                                  # (still drawing: the path tool's Enter comes first)
        self.ed.cancel_request()
        if len(d["points"]) < 2:
            self.drawing = None
            self.sync()
            return
        d["pieces"] = trails.pieces(d["points"], d["kind"])
        pts = ";".join(f"{p[0]:.3f},{p[1]:.3f},{p[2]:.3f}" for p in d["pieces"])
        self.ed.grounds_pending = self._trail_grounds
        self.ed.link.exec(f'cj_grounds("{pts}")')

    def _trail_grounds(self, zs):
        """The ground under each piece came: the trail is made (or drawn anew) in the place, its copies shown."""
        d, self.drawing = getattr(self, "drawing", None), None
        if d is None:
            return
        zs = list(zs)
        for k, z in enumerate(zs):
            # a ray that starts inside a trunk or a rock answers its own start: the piece would float - the
            # ground of its neighbours instead (01.10.: the first drop of a forest trail stood 3 m up)
            near = sorted(zs[max(0, k - 2):k] + zs[k + 1:k + 3])
            if near and z - near[len(near) // 2] > 1.0:
                zs[k] = near[len(near) // 2]
        for p, z in zip(d["pieces"], zs):
            p[2] = round(z, 3)
        c, place = d["c"], d.get("place") or self.ed.place
        objs = self.ed.project.place(place, getattr(self.ed, "world", None))["objects"]
        o = self._object(c.get("trail"))
        if o is None:
            first = d["pieces"][0]
            o = {"template": first[4], "pos": first[:3], "rot": [0.0, 0.0, first[3]]}
            objs.append(o)
            base = d["kind"].replace("_", " ")
            oid = self.ed.project.name_object(place, len(objs) - 1,
                                              base=base if base.endswith(("trail", "tracks", "prints")) else
                                              base + " trail")
            c["trail"] = f"{place}/{oid}"
        o.update(trail=d["kind"], points=d["points"], pieces=d["pieces"], pos=d["pieces"][0][:3])
        c.pop("kind", None)
        self.ed.project.save_place(place)
        if getattr(self.ed, "editing", False):
            self.ed.load_place()                        # the flags go, the pieces show
        self.save()

    def _say_field(self, d):
        """What Geralt says: typed, or one of his voiced game lines (Voice: search, Play, take)."""
        box = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(2)
        t = QtWidgets.QLineEdit(d.get("text", ""))
        t.setPlaceholderText("What the player says")
        t.editingFinished.connect(lambda t=t: self._say_text(d, t.text()))
        tip(t, "qb.says")
        voiced = bool(d.get("voice"))
        voice = _button(f"Game line, {float(d.get('dur') or 0):.1f} s" if voiced else "",
                        lambda _c=False: self._toggle_voice(d), "qb.says_voice")
        from .icons import GREEN, RED, icon
        voice.setIcon(icon("audio-lines" if voiced else "audio-lines-x", GREEN if voiced else RED))
        row = [_field("Player"), t, voice]
        if voiced:
            row.append(_icon("play", lambda _c=False: self._play_game(int(d["voice"])), "dlg.play"))
        v.addWidget(_row(*row, stretch_last=False))
        v.itemAt(0).widget().layout().setStretch(1, 1)
        if getattr(self, "open_voice", None) == id(d):
            v.addWidget(self._geralt_lines(d, t.text()))
        return box

    def _say_text(self, d, text):
        text = " ".join(text.split())
        if text != d.get("text", ""):
            for key in ("voice", "dur"):
                d.pop(key, None)                # a changed text is no longer the voiced line
            self._set_in(d, "text", text or None)

    def _toggle_voice(self, d):
        self.open_voice = None if getattr(self, "open_voice", None) == id(d) else id(d)
        self.sync()

    def _geralt_lines(self, d, words):
        """The player's voiced lines with these words (whoever is played at that step): Play, a click takes it."""
        from . import voices
        box = QtWidgets.QFrame()
        box.setObjectName("list")
        box.setStyleSheet("QFrame#list{background:#1d1d20;border:1px solid #444}"
                          "QPushButton#entry{text-align:left;color:#ddd;background:transparent;border:none;"
                          "padding:3px 6px;font:12px}QPushButton#entry:hover{background:#34343a}")
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(4, 4, 4, 4)
        v.setSpacing(1)
        if not voices.ready():
            v.addWidget(_field("The game's voices are read once - open a dialogue's Voice search first."))
            return box
        if getattr(self, "_voices", None) is None:
            self._voices = voices.Voices()
        from .dialogue import PLAYERS
        from .quest import characters
        who = characters(self.quest()).get(id(d), self.quest().get("player") or "geralt")
        for r in self._voices.search(words or "hm", speaker=PLAYERS.get(who, PLAYERS["geralt"])["voicetag"], limit=12):
            entry = _button(r["text"], lambda _c=False, r=r: self._take_voice(d, r), "qb.take", "entry")
            play = _icon("play", lambda _c=False, sid=r["id"]: self._play_game(sid), "dlg.play")
            row = _row(play, entry, stretch_last=True)
            v.addWidget(row)
        return box

    def _take_voice(self, d, r):
        from .voices import length
        d["voice"], d["dur"], d["text"] = int(r["id"]), length(r["id"], r["dur"], r["text"]), r["text"]
        self.open_voice = None
        self.save()

    def _play_game(self, sid):
        from PySide6 import QtMultimedia
        from . import voices
        path = voices.listen(sid)
        if not path:
            return
        if getattr(self, "_player", None) is None:
            self._player = QtMultimedia.QMediaPlayer(self)
            self._audio = QtMultimedia.QAudioOutput(self)
            self._player.setAudioOutput(self._audio)
        self._player.setSource(QtCore.QUrl.fromLocalFile(path))
        self._player.play()

    def _either_editor(self, v, a, every=False):
        """Either / or: options, each a goal and where it leads; the first one done decides. every (All of these):
        the goals in any order, all of them - no ways to choose."""
        if not every and "ways" in a and not a.get("options"):
            v.addWidget(self._random(a, "way", "qb.either_way_add"))     # (ways wired to goals: the first done wins)
            return
        opts = a.setdefault("options", [])
        for k, o in enumerate(opts):
            gkind, ga = step_kind(o.setdefault("goal", {"goto": {}}))
            row = QtWidgets.QFrame()
            row.setStyleSheet("QFrame{background:#222226;border:1px solid #3a3a40;border-radius:0}"
                              "QLabel{border:none}")
            rv = QtWidgets.QVBoxLayout(row)
            rv.setContentsMargins(6, 4, 6, 4)
            rv.setSpacing(3)
            num = QtWidgets.QLabel((f"AND {k + 1}" if every else f"OR {k + 1}") if k else "1")
            num.setStyleSheet("color:#bbb;font:bold 11px;border:none")
            kind_b = _menu_button(dict(EITHER_KINDS)[gkind], EITHER_KINDS, gkind,
                                  lambda nk, o=o: self._either_kind(o, nk), "qb.either_kind")
            lead = o.get("path")
            ways = [("", "Continue story")] + [(e[5:], label) for e, label in self.path_entries()] + \
                [("new", "New branch")]
            leads = _menu_button(f"Then: {self.paths()[lead]['label']}" if lead in self.paths() else "Then: continue",
                                 ways, lead or "", lambda pid, o=o: self._either_path(o, pid), "qb.either_path",
                                 path_color(lead) if lead in self.paths() else None)
            rv.addWidget(_row(num, kind_b, QtWidgets.QWidget(), *([] if every or QN.is_graph(self.quest()) else [leads]),
                              _icon("trash-2", lambda _c=False, k=k: self._remove_option(opts, k), "qb.remove_action"),
                              stretch_last=False))
            rv.itemAt(0).widget().layout().setStretch(2, 1)
            if gkind == "goto":
                rv.addWidget(self._place_field(ga))
            elif gkind == "kill":
                rv.addWidget(self._target_field(ga, "target", "who", "creatures"))
            else:
                rv.addWidget(self._target_field(ga, "object", "what", "things"))
            v.addWidget(row)
        v.addWidget(_row(_button("+ and" if every else "+ or", lambda _c=False: self._add_option(opts),
                                 "qb.all_add" if every else "qb.either_add", "plus"), QtWidgets.QWidget()))

    def _either_kind(self, o, kind):
        o["goal"] = {kind: {"place": self.ed.place, "radius": 10} if kind == "goto" else {}}
        self.save()

    def _either_path(self, o, pid):
        if pid == "new":
            pid = self.new_path(f"Branch {len(self.paths()) + 1}")
        if pid:
            o["path"] = pid
        else:
            o.pop("path", None)
        self.save()

    def _add_option(self, opts):
        opts.append({"goal": {"kill": {}}})
        self.save()

    def _remove_option(self, opts, k):
        opts.pop(k)
        self.save()

    def _talk_start(self, a):
        """How the talk starts: press E, by itself when Geralt comes near, or the NPC calls out first."""
        start = a.get("start", "interact")
        how = _menu_button(dict(TALK_STARTS)[start], TALK_STARTS, start,
                           lambda k: self._set_in(a, "start", None if k == "interact" else k), "qb.talk_start")
        row = [_field("starts"), how]
        if start not in ("interact", "now"):
            r = QtWidgets.QSpinBox()
            r.setRange(2, 60)
            r.setValue(int(a.get("radius", 6 if start == "near" else 10)))
            self._live(r, lambda v: self._set_in(a, "radius", v, rebuild=False))
            tip(r, "qb.talk_radius")
            from .fields import with_unit
            row.append(with_unit(r, "m"))
        if start == "calls":
            call = (a.get("call") or [{}])[0]
            t = QtWidgets.QLineEdit(call.get("text", ""))
            t.setPlaceholderText("Call-out line")
            t.editingFinished.connect(lambda t=t: self._set_in(
                a, "call", [{"who": "npc", "text": t.text().strip()}] if t.text().strip() else None, rebuild=False))
            tip(t, "qb.talk_call")
            row.append(t)
        else:
            row.append(QtWidgets.QWidget())
        return _row(*row)

    def _dialogue_preview(self, st, a):
        """The first lines of the dialogue and the way into it: the dialogue is a graph of its own (a double click
        on the talk opens it too)."""
        from . import dialogue as D
        lines = D.from_step(a)
        player = D.PLAYERS.get(self.quest().get("player") or "geralt", D.PLAYERS["geralt"])["label"]
        box = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(2)
        names = {k: label for k, _r, label in D.speakers(a)}
        names[D.PLAYER] = player
        shown = 0
        for x in lines:
            if "script" in x:
                continue
            if "random" in x:
                v.addWidget(_field(f"random: one of {len(x['random'] or [])} outcomes"))
                break
            if "if" in x:
                c = x["if"] or {}
                v.addWidget(_field(f"if {c.get('fact') or '...'} {c.get('op', '>=')} {c.get('value', 1)}: "
                                   f"two branches"))
                break
            if "choice" in x:
                v.addWidget(_field("Choice:"))
                for c in x["choice"]:
                    e = str(c.get("end", "continue"))
                    sub = c.get("lines") or []
                    if sub and "choice" in sub[-1]:
                        where, colour = "more choices", "#999"
                    elif e in ("back", "up"):
                        where, colour = "follow-up", "#bbb"
                    elif e.startswith("path:") and e[5:] in self.paths():
                        where, colour = f"branch {self.paths()[e[5:]].get('label') or e[5:]}", path_color(e[5:])
                    else:
                        where = D.END.get(e, e).lower()
                        colour = {"continue": "#9fd38a", "retry": "#e3c65f", "fail": "#e57a7a"}.get(e, "#999")
                    lab = QtWidgets.QLabel(f"&nbsp;&nbsp;{c.get('text') or '...'} &nbsp;"
                                           f"<span style='color:{colour}'>- {where}</span>")
                    lab.setStyleSheet("color:#cfcfcf;font:12px")
                    v.addWidget(lab)
                break
            if shown == 3:
                v.addWidget(_field("..."))
                break
            who = names.get(x.get("who") or "npc", "NPC")
            lab = QtWidgets.QLabel(f"<span style='color:{D.color(x.get('who') or 'npc', a)}'>{who}:</span> "
                                   f"{x.get('text') or '...'}")
            lab.setStyleSheet("color:#cfcfcf;font:12px")
            lab.setWordWrap(True)
            v.addWidget(lab)
            shown += 1
        info = _field(D.summary(lines) if lines else "no lines yet")
        v.addWidget(_row(info, QtWidgets.QWidget(), _button("Edit dialogue", lambda _c=False: self.open_dialogue(st),
                                                           "qb.edit_dialogue"), stretch_last=False))
        v.itemAt(v.count() - 1).widget().layout().setStretch(1, 1)
        return box

    def _walk_talks(self, v, a):
        """Talks on the way of a follow step: each at a point of the path (the NPC reaches it: its lines play while
        both walk on), its lines in the dialogue editor."""
        points = max(1, len(a.get("path") or []))
        for entry in a.get("talks") or []:
            t = entry.setdefault("talk", {})
            t["npc"], t["start"] = a.get("who"), "overhear"     # (the editor: who speaks, no choices)
            n = len([x for x in t.get("dialogue") or [] if x.get("text")])
            lines = _button(f"{n} line{'s' if n != 1 else ''}" if n else "Write the lines",
                            lambda _c=False, e=entry: self.open_dialogue(e), "qb.walk_talk_lines", "target")
            spin = self._spin(t, "at", 1, points, "", 1)
            rm = _icon("trash-2", lambda _c=False, e=entry: self._remove_walk_talk(a, e), "qb.remove_action")
            v.addWidget(_row(_field("talk at point"), spin, lines, rm, QtWidgets.QWidget()))
        v.addWidget(_row(_button("+ talk on the way", lambda _c=False: self._add_walk_talk(a), "qb.walk_talk_add",
                                 "plus"), QtWidgets.QWidget()))

    def _add_walk_talk(self, a):
        at = len(a.get("talks") or []) + 1
        entry = {"talk": {"npc": a.get("who"), "start": "overhear", "at": min(at, max(1, len(a.get("path") or []))),
                          "dialogue": [{"who": "npc", "text": ""}]}}
        a.setdefault("talks", []).append(entry)
        self.save()
        self.open_dialogue(entry)

    def _remove_walk_talk(self, a, entry):
        a["talks"] = [e for e in a.get("talks") or [] if e is not entry]
        if not a["talks"]:
            a.pop("talks")
        self.save()

    def walk_talks(self):
        """The talks on the way of every follow step (each opens in the dialogue editor like a step)."""
        out = []
        for st in self.all_steps():
            kind, a = step_kind(st)
            if kind == "follow":
                out += a.get("talks") or []
        return out

    def _game_boards(self):
        """[(tag:<tag>, label)] of the game's notice boards in the quest's worlds, nearest to the editor camera first
        (the index of a world is made once - its first time takes a few minutes, meanwhile the list says so)."""
        import math
        import threading
        from . import encounters
        worlds = sorted({p.get("world") for p in self.ed.project.places.values() if p.get("world")})
        cam = getattr(getattr(self.ed, "cam", None), "pos", None) or [0.0, 0.0, 0.0]
        out = [(None, "a board placed for the quest")]
        for w in worlds:
            if not os.path.exists(encounters.cache_path(w, "W3NoticeBoard")):
                if w not in _SCANNING:
                    _SCANNING.add(w)
                    threading.Thread(target=encounters.index, args=(w, lambda s: None, "W3NoticeBoard"),
                                     daemon=True).start()
                out.append(("", f"(looking for the boards of {w} - a few minutes)"))
                continue
            boards = encounters.index(w, cls="W3NoticeBoard")
            for b in sorted(boards, key=lambda b: math.dist(b["pos"][:2], cam[:2])):
                tag = next((t.strip() for t in b["tags"] if "notice" in t.lower()), b["tags"][0].strip())
                out.append((f"tag:{tag}", f"{tag.replace('_', ' ')}   {math.dist(b['pos'][:2], cam[:2]):.0f} m"))
        return out

    def _target_field(self, a, key, label, what, on_set=None, ident=None):
        """Who / what the step is about: one button showing it (or 'choose ...'); a click opens one list - pick it
        in the world, create a new one, show it, or take one of those placed. `on_set(reference)`: where the choice
        goes instead of a[key] (a list of several); `ident`: a stable name for the button when `a` is made anew on
        every build (list entries)."""
        if on_set is not None:
            a["_on_set"] = on_set
        ident = ident or id(a)
        box = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(3)
        ref = a.get(key)
        place, _, oid = (ref or "").partition("/")
        waiting = self.waiting and self.waiting[:2] == (ident, key)
        if waiting:
            text = "Click in world. Esc cancels" if self.waiting[2] == "pick" else \
                "Place in world. Esc cancels"
        elif ref:
            found = self._find(ref)
            o = self.ed.project.places[found[0]]["objects"][found[1]] if found else {}
            text = (o.get("display") or oid.replace("_", " ")) +                 (f"  ·  {place}" if len(self.ed.project.places) > 1 else "")
        else:
            text = {"people": "choose who", "creatures": "choose who", "clues": "choose a clue",
                    "containers": "choose a container"}.get(what, "choose what")
        open_ = self.open_picker == (ident, key)
        b = _button(text + ("  ▴" if open_ else "  ▾"), lambda _c=False: self._toggle_picker(a, key, ident),
                    "qb.target", "target" if ref else "target_empty")
        if waiting:
            b.setStyleSheet("color:#fff;background:#4b4b50;border:1px solid #c8c8c8")
        v.addWidget(_row(_field(label), b, QtWidgets.QWidget()))
        if ref and not waiting and self._find(ref):
            v.addWidget(self._name_field(a, key, ref))
        if open_:
            v.addWidget(self._search_list(a, key, what, ident))
        return box

    def _name_field(self, a, key, ref):
        """Its name, changeable here (Maxim 08.10.: full control on the quest tab): a person's name above them in the
        game; the id follows it, and with it every step, dialogue and journal line."""
        from .quest import is_actor
        place, k = self._find(ref)
        o = self.ed.project.places[place]["objects"][k]
        e = QtWidgets.QLineEdit(o.get("display") or ref.partition("/")[2].replace("_", " ").capitalize())
        e.setPlaceholderText("Name")
        tip(e, "qb.name_person" if is_actor(o) else "qb.name_thing")

        def done():
            text = e.text().strip()
            now = o.get("display") or ref.partition("/")[2].replace("_", " ").capitalize()
            if text == now:
                return
            self.ed.project.rename_object(place, k, text)
            self.save()
        e.editingFinished.connect(done)
        return _row(_field("name"), e, QtWidgets.QWidget())

    def _find(self, ref):
        """(place, index) of an object reference, or None."""
        if not ref:
            return None
        place, _, oid = ref.partition("/")
        for k, o in enumerate(self.ed.project.places.get(place, {}).get("objects", [])):
            if o.get("id") == oid:
                return place, k
        return None

    def _search_list(self, a, key, what, ident=None):
        """The target's list: pick it in the world, create a new one, show the chosen one - then everything of
        this kind already placed (click takes it, Show goes there)."""
        from .quest import is_actor
        ident = ident or id(a)
        box = QtWidgets.QFrame()
        box.setStyleSheet("QFrame#list{background:#1d1d20;border:1px solid #444}"
                          "QPushButton#entry{text-align:left;color:#ddd;background:transparent;border:none;"
                          "padding:3px 6px;font:12px}QPushButton#entry:hover{background:#34343a}"
                          "QPushButton#doit{text-align:left;color:#fff;background:transparent;border:none;"
                          "padding:3px 6px;font:bold 12px}QPushButton#doit:hover{background:#34343a}")
        box.setObjectName("list")
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(4, 4, 4, 4)
        v.setSpacing(1)
        kind = {"people": "person", "creatures": "person", "clues": "clue", "containers": "container"}.get(
            what, "thing")
        v.addWidget(_button("Pick in world", lambda _c=False: self._request(a, key, what, "pick", ident),
                            f"qb.pick_{what}", "doit"))
        v.addWidget(_button(f"Create a new {kind}", lambda _c=False: self._request(a, key, what, "create", ident),
                            f"qb.create_{what}", "doit"))
        found = self._find(a.get(key))
        if found:
            v.addWidget(_button("Go to", lambda _c=False, f=found: self.ed.jump_to(*f), "qb.jump",
                                "doit"))
        rows = []
        for place, p in sorted(self.ed.project.places.items()):
            for k, o in enumerate(p.get("objects", [])):
                if (what in ("people", "creatures")) != is_actor(o):
                    continue
                if what == "containers" and not self._holds_items(o):
                    continue
                if what == "loot":
                    from .quest import not_loot
                    if not_loot(o["template"]):
                        continue
                name = o.get("display") or                     (o.get("id") or o["template"].rsplit("\\", 1)[-1].rsplit(".", 1)[0]).replace("_", " ")
                entry = _button(name, lambda _c=False, w=(place, k): self._picked(a, key, w), "qb.take", "entry")
                jump = _button("Show", lambda _c=False, w=(place, k): self.ed.jump_to(*w), "qb.jump")
                if what == "people":            # whose mouth moves when they talk (Maxim 01.10.)
                    state = self._mouth(o)
                    mark = _field({"moves": "talks", "shut": "No lip sync", "none": "No lip sync",
                                   "maybe": "Random look", "animal": "animal"}.get(state, ""))
                    mark.setStyleSheet("color:%s" % ("#d6a65a" if state in ("shut", "none", "maybe") else "#8a8a8e"))
                    tip(mark, "qb.mouth")
                    r = _row(entry, mark, _field(place), jump, stretch_last=False)
                else:
                    r = _row(entry, _field(place), jump, stretch_last=False)
                r.layout().setStretch(0, 1)
                rows.append((name.lower(), r))
        if rows:
            find = QtWidgets.QLineEdit()
            find.setPlaceholderText(f"Or one already placed ({len(rows)})")
            tip(find, "qb.search_name")
            v.addWidget(find)
            for _n, r in rows:
                v.addWidget(r)
            find.textChanged.connect(lambda t: [r.setVisible(t.lower() in n) for n, r in rows])
        return box

    def _request(self, a, key, what, how, ident=None):
        """Pick / Create: the editor waits for the object; the step takes it when it comes. Create first asks which
        one (the chooser in this window)."""
        ident = ident or id(a)
        if self.waiting and self.waiting[:3] == (ident, key, how):
            self.ed.cancel_request()
            return
        self.open_picker = None

        def done(place, index, a=a, key=key):
            self.waiting = None
            title = getattr(self, "chosen_title", None) if how == "create" else None
            self.chosen_title = None
            oid = self.ed.project.name_object(place, index, base=title)
            self._take_ref(a, key, f"{place}/{oid}")
        if how == "create":
            def chosen(path):
                self.waiting = (ident, key, how)
                self.ed.request_object(how, what, done, template=path)
                self.sync()
            self.choose(what, chosen)
            return
        self.waiting = (ident, key, how)
        self.ed.request_object(how, what, done)
        self.sync()

    # --- the chooser: the catalog on one kind, inside this window
    def choose(self, what, then):
        """Shows the catalog (people / creatures / things) instead of the board; `then(template path)` when one is
        taken, the board comes back."""
        self.close_chooser()
        self.chooser = Chooser(self, what, then)
        self.stack.addWidget(self.chooser)
        self.stack.setCurrentWidget(self.chooser)

    def close_chooser(self):
        c = getattr(self, "chooser", None)
        panel = getattr(self.ed, "panel", None)
        if c is not None and panel is not None and getattr(panel, "inspector", None) is not None:
            panel.show_inspector(False)
        if c is not None:
            self.stack.removeWidget(c)
            c.deleteLater()
            self.chooser = None
            self.stack.setCurrentWidget(self.dialogue if self.dialogue is not None else self.page)

    def _place_field(self, a, point=True):
        """Where: the spot - a marker placed in the world (a flag: selected and moved like anything placed, only
        in the editor; the quest takes its position). Older steps: a place's middle or a bare point."""
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(4)
        h.addWidget(_field("where"))
        found = self._find(a.get("at")) if a.get("at") else None
        waiting = self.waiting and self.waiting[:2] == (id(a), "at")
        if found:
            place, _i = found
            label = "the spot" + (f"  ·  {place}" if len(self.ed.project.places) > 1 else "")
            b = _menu_button(label + "  ▾", [("show", "Go to"), ("again", "Re-place"), ("remove", "Delete from world")],
                             None, lambda k, a=a: self._spot(a, k), "qb.spot")
            b.setStyleSheet("QToolButton#menu{color:#eee;font:bold 12px}")
        else:
            b = _button("Click in the world. Esc cancels" if waiting else "+ Set the spot",
                        lambda _c=False, a=a: self._request_spot(a), "qb.spot", "target_empty")
            if waiting:
                b.setStyleSheet("color:#fff;background:#4b4b50;border:1px solid #c8c8c8")
        h.addWidget(b)
        if not found and not waiting and a.get("pos"):
            h.addWidget(_field(f"now: a point {a['pos'][0]:.0f}, {a['pos'][1]:.0f}"))
        elif not found and not waiting and a.get("place"):
            h.addWidget(_field(f"now: the middle of {a['place']}"))
        h.addStretch(1)
        return box

    def _request_spot(self, a):
        """The flag follows the cursor; the click that places it is the spot."""
        if self.waiting and self.waiting[:3] == (id(a), "at", "create"):
            self.ed.cancel_request()
            return
        self.waiting = (id(a), "at", "create")

        def done(place, index, a=a):
            self.waiting = None
            objs = self.ed.project.places[place]["objects"]
            taken = {o.get("id") for o in objs}
            n = 1
            while f"spot{n}" in taken:
                n += 1
            self.ed.project.name_object(place, index, f"spot{n}")
            objs[index]["marker"] = True                # only in the editor: never built into the game
            self.ed.project.save_place(place)
            old = self._find(a.get("at")) if a.get("at") else None
            a["at"] = f"{place}/spot{n}"
            a.pop("pos", None)
            a.pop("place", None)
            if old:
                self._remove_object(*old)
            self.save()
        from .quest import SPOT_MARKER
        self.ed.request_object("create", "things", done, template=SPOT_MARKER)
        self.sync()

    def _spot(self, a, k):
        found = self._find(a.get("at"))
        if not found:
            return
        if k == "show":
            self.ed.jump_to(*found)
        elif k == "again":
            self._request_spot(a)
        elif k == "remove":
            self._remove_object(*found)
            a.pop("at", None)
            self.save()

    def _remove_object(self, place, index):
        """Takes a placed object out (in the game too: the editor deletes it where it stands)."""
        o = self.ed.project.places[place]["objects"][index]
        if place == self.ed.place:
            x, y, z = o["pos"]
            self.ed.link.exec(f"cj_delete_at({x:.3f}, {y:.3f}, {z:.3f})")
        else:
            self.ed.project.places[place]["objects"].pop(index)
            self.ed.project.save_place(place)

    def _wait_mode(self, a, until):
        if until:
            a.pop("time", None)
            a["until"] = "22:00"
        else:
            a.pop("until", None)
            a["time"] = "00:00:10"
        self.save()

    def _set_place(self, a, name):
        a.pop("pos", None)
        self._set_in(a, "place", name)

    def _path_field(self, a):
        """The way: points clicked in the world, in order (a click on one takes it out); the last is where it ends."""
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(4)
        h.addWidget(_field("way"))
        pts = a.get("path") or []
        drawing = getattr(self.ed, "path_tool", None) is not None and getattr(self, "_path_of", None) is a
        h.addWidget(_field(f"{len(pts)} point{'s' * (len(pts) != 1)}" if pts else "not drawn yet"))
        b = _button("Done" if drawing else ("Edit in the world" if pts else "Draw in the world"),
                    (lambda _c=False: self.ed.path_tool.finish()) if drawing else
                    (lambda _c=False: self._draw_path(a)), "qb.path_add", "target" if pts else "target_empty")
        from .icons import icon
        b.setIcon(icon("spline", "#dddddd", 14))
        h.addWidget(b)
        if pts:
            h.addWidget(_icon("trash-2", lambda _c=False: self._clear_path(a), "qb.path_clear"))
        h.addStretch(1)
        return box

    def _draw_path(self, a):
        """The way drawn (or changed) in the world with the path tool: Enter keeps it."""
        self._path_of = a

        def done(points, a=a):
            self._path_of = None
            if points:
                a["path"] = points
            else:
                a.pop("path", None)
            self.save()

        def cancel(_points, a=a):
            self._path_of = None
            self.sync()

        def kept(points, a=a):                  # every point the moment it is set (no Enter needed to keep it)
            a["path"] = points
            self.save(rebuild=False)
        from .pathtool import PathTool
        if getattr(self.ed, "path_tool", None) is not None:
            self.ed.path_tool.finish()
        PathTool(self.ed, a.get("path") or [], done, label="Way", on_cancel=cancel, on_change=kept).start()
        self.sync()

    def _clear_path(self, a):
        a.pop("path", None)
        self.save()

    def _request_path_point(self, a):
        """The next click into the world adds a point to the way."""
        if self.waiting and self.waiting[:2] == (id(a), "path"):
            self.ed.cancel_request()
            return

        def done(place, pos, a=a):
            self.waiting = None
            a.setdefault("path", []).append([round(float(v), 2) for v in pos[:3]])
            self.save()
        self.waiting = (id(a), "path", "point")
        self.ed.request_object("point", "point", done)
        self.sync()

    def _drop_point(self, a, k):
        a["path"].pop(k)
        if not a["path"]:
            a.pop("path")
        self.save()

    def _request_point(self, a, key):
        """The next click into the world gives the point (and its place's world)."""
        if self.waiting and self.waiting[:2] == (id(a), key):
            self.ed.cancel_request()
            return

        def done(place, pos, a=a, key=key):
            self.waiting = None
            a[key] = pos
            a["place"] = place                  # its world
            if getattr(self.ed, "world", None):
                a["world"] = self.ed.world      # (the place may be new and empty: the game's world itself)
            self.save()
        self.waiting = (id(a), key, "point")
        self.ed.request_object("point", "point", done)
        self.sync()

    def _item_field(self, a):
        count = QtWidgets.QSpinBox()
        count.setRange(1, 999)
        count.setValue(int(a.get("count", 1)))
        self._live(count, lambda v, a=a: self._set_in(a, "count", v, rebuild=False))
        tip(count, "qb.count")
        row = _row(_field("what"), self._item_line(a), _field("how many"), count, stretch_last=False)
        row.layout().setStretch(1, 1)
        return row

    SOURCES = [("container", "in a container"), ("person", "a person carries it"),
               ("none", "not placed - the player finds or buys it")]

    def _holds_items(self, o):
        db = self.assets()
        row = db.template(o["template"]) if db is not None else None
        from .quest import lootable
        return bool(row and row.get("inventory")) and lootable(o["template"])

    def _source_field(self, a):
        """Where the item of a collect step is: the kind, then which one, then (a container) its loot."""
        box = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(3)
        src = a.get("from")
        how = _menu_button(dict(self.SOURCES).get(src, "Location not set"), self.SOURCES, src,
                           lambda k: self._set_source(a, k), "qb.item_from")
        if not src:
            how.setStyleSheet("QToolButton#menu{border-style:dashed;color:#aaa}")
        v.addWidget(_row(_field("where"), how, QtWidgets.QWidget()))
        if src in ("container", "person"):
            v.addWidget(self._target_field(a, "in", "in" if src == "container" else "who",
                                           "containers" if src == "container" else "people"))
        found = self._find(a.get("in")) if src == "container" else None
        if found:
            place, index = found
            import json
            from .item_chooser import loot_row
            o = self.ed.project.places[place]["objects"][index]
            db = self.assets()
            row = db.template(o["template"]) if db is not None else None
            own = (json.loads((row or {}).get("loot_defs") or "[]") or [""])[0]
            v.addWidget(loot_row(o, own, lambda value, f=found: self._set_loot(f, value),
                                 lambda f=found, o=o: self.ed.panel.choose_loot(
                                     lambda name, f=f: self._set_loot(f, name),
                                     f"Random loot for {(o.get('id') or 'it').replace('_', ' ')}",
                                     key=f"loot:{f[0]}/{o.get('id')}", current=o.get("loot") or own or None)))
        return box

    def _set_source(self, a, k):
        if k != a.get("from"):
            a.pop("in", None)
        self._set_in(a, "from", k)

    def _set_loot(self, found, value):
        """The container's random loot: None = its own table again, "" = none, a name = that table."""
        place, index = found
        o = self.ed.project.places[place]["objects"][index]
        if value is None:
            o.pop("loot", None)
        else:
            o["loot"] = value
        self.ed.project.save_place(place)
        self.sync()

    # --- action rows
    def _person_action(self, h, kind, a):
        """The actions about one person: who, and what (health in %, whom they attack, talking off or on again, a
        look, a merchant on or off, a boss's bar on or off); 'goes away': who only."""
        player_too = kind in ("health", "look")
        h.addWidget(self._target_field(a, "who", "who" + (" (empty: Geralt)" if player_too else ""), "people"), 1)
        if kind == "health":
            h.addWidget(self._spin(a, "percent", 1, 100, " %", 100))
        elif kind == "target":
            h.addWidget(self._target_field(a, "at", "attacks (empty: Geralt)", "people"), 1)
            h.addWidget(_chip("stops", bool(a.get("stop")),
                              lambda _c=False: self._set_in(a, "stop", None if a.get("stop") else True),
                              "qb.target_stop"))
        elif kind == "notalk":
            h.addWidget(_chip("talks again", bool(a.get("again")),
                              lambda _c=False: self._set_in(a, "again", None if a.get("again") else True),
                              "qb.notalk_again"))
        elif kind == "look":
            look = QtWidgets.QLineEdit(str(a.get("appearance") or ""))
            look.setPlaceholderText("Appearance name")
            look.editingFinished.connect(lambda: self._set_in(a, "appearance", look.text().strip() or None))
            tip(look, "qb.look_name")
            h.addWidget(look, 1)
        elif kind in ("shop", "bossbar"):
            h.addWidget(_chip("off", bool(a.get("off")),
                              lambda _c=False: self._set_in(a, "off", None if a.get("off") else True),
                              "qb.shop_off" if kind == "shop" else "qb.bossbar_off"))

    def _action_row(self, steps, i, alone=False):
        """What an action does, edited in one row (alone: on a card of its own - no label, no Remove)."""
        kind, a = step_kind(steps[i])
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(6)
        if not alone:
            kl = QtWidgets.QLabel(LABEL.get(kind, kind))
            kl.setObjectName("field")
            kl.setFixedWidth(84)
            h.addWidget(kl, 0, Q.AlignTop)
        if kind in ("show", "hide"):
            for name in sorted(self.ed.project.places):
                h.addWidget(_chip(name, a.get("place") == name, lambda _c=False, n=name: self._set_place_action(
                    a, kind, n), "qb.place"))
            h.addStretch(1)
        elif kind == "reward":
            money, xp = QtWidgets.QSpinBox(), QtWidgets.QSpinBox()
            for w, key, suffix in ((money, "money", " crowns"), (xp, "xp", " xp")):
                from .fields import with_unit
                w.setRange(0, 100000)
                w.setValue(int(a.get(key, 0)))
                self._live(w, lambda v, key=key: self._set_in(a, key, v, rebuild=False))
                h.addWidget(with_unit(w, suffix))
            listed = list(a.get("items") or [])
            for k, it in enumerate(listed):
                h.addWidget(self._item_line({"item": it}, on_set=lambda ref, k=k: self._reward_item(a, k, ref)), 1)
            h.addWidget(_button("+ item", lambda _c=False: self.ed.panel.choose_item(
                lambda ref: self._reward_item(a, len(listed), ref), "Reward item", action="Add item"),
                "qb.reward_items", "plus"))
            if not listed:
                h.addStretch(1)                         # (else the buttons took the room)
        elif kind == "note":
            t = QtWidgets.QLineEdit(a.get("text", ""))
            t.setPlaceholderText("New paragraph in the journal")
            t.editingFinished.connect(lambda t=t: self._set_in(a, "text", t.text().strip(), rebuild=False))
            h.addWidget(t, 1)
        elif kind == "hostile":
            h.addWidget(self._target_field(a, "target", "who", "people"), 1)
            friendly = _chip("Friendly again", bool(a.get("friendly")),
                             lambda _c=False: self._set_in(a, "friendly", None if a.get("friendly") else True),
                             "qb.friendly")
            h.addWidget(friendly, 0, Q.AlignTop)
        elif kind == "say":
            from . import dialogue as D
            inner = QtWidgets.QWidget()
            bv = QtWidgets.QVBoxLayout(inner)
            bv.setContentsMargins(0, 0, 0, 0)
            bv.setSpacing(3)
            speaker = "someone" if "who" in a else "player"
            who = _menu_button("Player" if speaker == "player" else "Someone else",
                               [("player", "Player"), ("someone", "Someone else")], speaker,
                               lambda k: self._say_speaker(a, k), "qb.say_who")
            have = self._body(a.get("who") if speaker == "someone" else None)     # only what that body has
            gesture = _menu_button(D.GESTURE[a["gesture"]][0] if a.get("gesture") in D.GESTURE else "No gesture",
                                   [("", "No gesture")] + D.gestures_for(have), a.get("gesture", ""),
                                   lambda k: self._set_in(a, "gesture", k or None), "qb.say_gesture")
            mood = _menu_button(D.MOOD[a["mood"]] if a.get("mood") in D.MOOD else "No mood",
                                [("", "No mood")] + list(D.MOODS), a.get("mood", ""),
                                lambda k: self._set_in(a, "mood", k or None), "qb.say_mood")
            bv.addWidget(_row(who, gesture, mood, QtWidgets.QWidget()))
            if speaker == "someone":
                bv.addWidget(self._target_field(a, "who", "who", "people"))
                t = QtWidgets.QLineEdit(a.get("text", ""))
                t.setPlaceholderText("What they say (if left empty, only the gesture)")
                t.editingFinished.connect(lambda t=t: self._set_in(a, "text", " ".join(t.text().split()) or None))
                tip(t, "qb.says_text")
                bv.addWidget(t)
            else:
                bv.addWidget(self._say_field(a))
            h.addWidget(inner, 1)
        elif kind == "item":
            h.addWidget(_menu_button("The player loses" if a.get("take") else "The player gets",
                                     [(False, "The player gets"), (True, "The player loses")], bool(a.get("take")),
                                     lambda k: self._set_in(a, "take", k or None), "qb.item_way"))
            h.addWidget(self._item_line(a), 1)
            h.addWidget(self._spin(a, "count", 1, 999, "x", 1))
        elif kind == "lock":
            inner = QtWidgets.QWidget()
            bv = QtWidgets.QVBoxLayout(inner)
            bv.setContentsMargins(0, 0, 0, 0)
            bv.setSpacing(3)
            bv.addWidget(self._target_field(a, "target", "what", "things"))
            locked = a.get("state", "lock") == "lock"
            how = _menu_button("Locks it" if locked else "Unlocks it", [("lock", "Locks it"), ("unlock", "Unlocks it")],
                               a.get("state", "lock"), lambda k: self._set_in(a, "state", k), "qb.lock_state")
            row = [how]
            if locked:
                row += [_field("key"), self._item_line(a, "key", placeholder="Key item (none: nothing opens it)")]
                goes = QtWidgets.QCheckBox("The key is used up")
                goes.setChecked(bool(a.get("key_goes")))
                goes.toggled.connect(lambda on: self._set_in(a, "key_goes", True if on else None, rebuild=False))
                tip(goes, "qb.lock_key_goes")
                row.append(goes)
                bv.addWidget(_row(*row, stretch_last=False))
                bv.itemAt(1).widget().layout().setStretch(2, 1)
            else:
                bv.addWidget(_row(*row, QtWidgets.QWidget()))
            h.addWidget(inner, 1)
        elif kind in ("immortal", "door", "switch", "effect", "lights", "presence"):
            what = "people" if kind == "immortal" else "things"
            tbox = QtWidgets.QWidget()
            tv = QtWidgets.QVBoxLayout(tbox)
            tv.setContentsMargins(0, 0, 0, 0)
            tv.setSpacing(3)
            tv.addWidget(self._target_field(a, "target", "who" if kind == "immortal" else "what", what))
            self._more_targets(tv, a, what)
            h.addWidget(tbox, 1)
            if kind == "lights":
                h.addWidget(_menu_button(dict(LIGHTS)[a.get("state", "on")], LIGHTS, a.get("state", "on"),
                                         lambda k: self._set_in(a, "state", k), "qb.lights_state"), 0, Q.AlignTop)
                h.addWidget(_chip("slowly", bool(a.get("slow")), lambda _c=False: self._set_in(
                    a, "slow", None if a.get("slow") else True), "qb.lights_slow"), 0, Q.AlignTop)
            elif kind == "presence":
                h.addWidget(_menu_button(dict(PRESENCE)[a.get("state", "hide")], PRESENCE, a.get("state", "hide"),
                                         lambda k: self._set_in(a, "state", k), "qb.presence_state"), 0, Q.AlignTop)
            elif kind == "immortal":
                h.addWidget(_menu_button(dict(IMMORTAL)[a.get("mode", "immortal")], IMMORTAL, a.get("mode", "immortal"),
                                         lambda k: self._set_in(a, "mode", k), "qb.immortal_mode"), 0, Q.AlignTop)
            elif kind == "switch":
                h.addWidget(_menu_button(dict(SWITCH)[a.get("state", "on")], SWITCH, a.get("state", "on"),
                                         lambda k: self._set_in(a, "state", k), "qb.switch_state"), 0, Q.AlignTop)
            elif kind == "door":
                h.addWidget(_menu_button(dict(DOOR)[a.get("state", "open")], DOOR, a.get("state", "open"),
                                         lambda k: self._set_in(a, "state", k), "qb.door_state"), 0, Q.AlignTop)
                if a.get("state") == "lock":
                    key = self._item_line(a, "key", placeholder="Key item")
                    tip(key, "qb.door_key")
                    h.addWidget(key, 0, Q.AlignTop)
            else:
                h.addWidget(self._text_line(a, "effect", "effect name", self._effect_names(a.get("target"))), 0,
                            Q.AlignTop)
        elif kind == "worldchange":                 # a change to an object the game placed (worldchanges.py)
            from . import worldchanges
            opts = [(str(c["id"]), f"{c.get('label') or 'object'}: {c['do']}"
                     + (f" {c['value']}" if c.get("value") else "")) for c in worldchanges.load(self.ed.project.path)]
            if opts:
                cur = str(a.get("change") or "")
                h.addWidget(_menu_button(dict(opts).get(cur, "which change?"), opts, cur,
                                         lambda k: self._set_in(a, "change", int(k)), "qb.worldchange"), 1)
                h.addWidget(_menu_button(dict(WORLDCHANGE)[a.get("state", "on")], WORLDCHANGE, a.get("state", "on"),
                                         lambda k: self._set_in(a, "state", k), "qb.worldchange_state"), 0, Q.AlignTop)
            else:
                h.addWidget(_field("No world changes yet"), 1)
        elif kind == "sound":
            h.addWidget(self._text_line(a, "event", "sound event", self._sound_names()), 1)
        elif kind == "encounters":
            h.addWidget(_menu_button(dict(ENCOUNTERS)[a.get("state", "off")], ENCOUNTERS, a.get("state", "off"),
                                     lambda k: self._set_in(a, "state", k), "qb.encounters_state"), 0, Q.AlignTop)
            h.addWidget(self._point_button(a, "pos", "around", "qb.encounters_point"), 0, Q.AlignTop)
            h.addWidget(self._spin(a, "radius", 10, 500, " m", 60), 0, Q.AlignTop)
            if a.get("pos"):                        # how many of the game's creature groups that reaches
                try:
                    from . import encounters
                    n = len(encounters.near(a.get("world") or "velen", a["pos"], float(a.get("radius", 60))))
                    h.addWidget(_field(f"{n} group{'s' * (n != 1)}" if n else "none there"), 0, Q.AlignTop)
                except Exception:                   # noqa: BLE001 - no game files: no count
                    pass
            h.addStretch(1)
        elif kind == "fade":
            h.addWidget(_menu_button("To black" if a.get("to", "black") == "black" else "Back in",
                                     [("black", "To black"), ("in", "Back in")], a.get("to", "black"),
                                     lambda k: self._set_in(a, "to", k), "qb.fade"))
            if a.get("to", "black") == "black":
                h.addWidget(_menu_button(dict(FADE_COLORS)[a.get("color", "black")], FADE_COLORS,
                                         a.get("color", "black"), lambda k: self._set_in(a, "color", k),
                                         "qb.fade_color"))
            h.addWidget(self._spin(a, "seconds", 0, 30, " s", 1))
            h.addStretch(1)
        elif kind == "shake":
            h.addWidget(self._spin(a, "strength", 1, 100, " %", 50, scale=100))
            h.addStretch(1)
        elif kind in PERSON_ACTIONS:
            self._person_action(h, kind, a)
        elif kind == "weapon":
            from .quest import WEAPONS
            cur = a.get("weapon") or "steel"
            h.addWidget(_menu_button(dict((k, x) for k, x, _e in WEAPONS)[cur], [(k, x) for k, x, _e in WEAPONS],
                                     cur, lambda k: self._set_in(a, "weapon", k), "qb.weapon"))
            h.addStretch(1)
        elif kind == "controls":
            from .quest import CONTROLS
            h.addWidget(_chip("unblock" if a.get("unlock") else "block", True,
                              lambda _c=False: self._set_in(a, "unlock", None if a.get("unlock") else True),
                              "qb.controls_how"))
            what = list(a.get("what") or ["all"])
            for k, label in CONTROLS:
                def toggle(_c=False, k=k):
                    now = [x for x in (a.get("what") or ["all"]) if x != k] if k in (a.get("what") or ["all"]) \
                        else [x for x in (a.get("what") or []) if x != "all"] + [k]
                    self._set_in(a, "what", now or ["all"])
                h.addWidget(_chip(label, k in what, toggle, "qb.controls_what"))
            h.addStretch(1)
        elif kind == "timelapse":
            from .quest import LAPSES
            cur = a.get("text") or LAPSES[0][0]
            h.addWidget(_menu_button(dict(LAPSES).get(cur, cur), LAPSES, cur, lambda k: self._set_in(a, "text", k),
                                     "qb.timelapse"))
            h.addWidget(self._spin(a, "seconds", 1, 30, " s", 5))
            h.addStretch(1)
        elif kind == "highlight":
            from .quest import HIGHLIGHTS
            h.addWidget(self._target_field(a, "target", "what", "things"), 1)
            cur = a.get("how") or "clue"
            h.addWidget(_menu_button(dict((k, x) for k, x, _e in HIGHLIGHTS)[cur],
                                     [(k, x) for k, x, _e in HIGHLIGHTS], cur, lambda k: self._set_in(a, "how", k),
                                     "qb.highlight"))
        elif kind == "weather":
            w = a.get("weather", "WT_Clear")
            h.addWidget(_menu_button(w[3:].replace("_", " "), [(x, x[3:].replace("_", " ")) for x in WEATHERS], w,
                                     lambda k: self._set_in(a, "weather", k), "qb.weather"))
            h.addWidget(self._spin(a, "seconds", 0, 120, " s blend", 10))
            h.addStretch(1)
        elif kind == "time":
            t = QtWidgets.QLineEdit(a.get("at", "12:00"))
            t.setInputMask("99:99")
            t.editingFinished.connect(lambda t=t: self._set_in(a, "at", t.text(), rebuild=False))
            tip(t, "qb.time_at")
            h.addWidget(t)
            h.addStretch(1)
        elif kind == "travel":
            pos = a.get("pos")
            where = f"{a.get('world', '?')}: {pos[0]:.0f}, {pos[1]:.0f}" if pos else "Location not set"
            h.addWidget(_field(where))
            h.addWidget(_button("Click in the world. Esc cancels" if self.waiting and self.waiting[:2] == (id(a), "pos")
                                else "Pick a point", lambda _c=False: self._request_point(a, "pos"), "qb.travel_here"))
            h.addStretch(1)
        elif kind == "playas":
            from .dialogue import PLAYERS
            who = a.get("as")
            h.addWidget(_menu_button(PLAYERS[who]["label"] if who in PLAYERS else "who", [(k, p["label"]) for k, p in
                                     PLAYERS.items()], who, lambda k: self._set_in(a, "as", k), "qb.playas_who"),
                        0, Q.AlignTop)
            if who == "ciri":
                look = a.get("look") or ""
                h.addWidget(_menu_button(dict(CIRI_LOOKS)[look], CIRI_LOOKS, look,
                                         lambda k: self._set_in(a, "look", k or None), "qb.playas_look"), 0, Q.AlignTop)
            pos = a.get("pos")
            h.addWidget(_field(f"at {pos[0]:.0f}, {pos[1]:.0f}" if pos else "where they are"))
            h.addWidget(_button("Click in the world. Esc cancels" if self.waiting and self.waiting[:2] == (id(a), "pos")
                                else "Pick a point", lambda _c=False: self._request_point(a, "pos"), "qb.playas_at"))
            if pos:
                h.addWidget(_icon("x", lambda _c=False: self._set_in(a, "pos", None), "qb.playas_here"))
            h.addStretch(1)
        elif kind == "portal":
            h.addWidget(self._portal_card(a), 1)
        elif kind == "teleport":
            pos = a.get("pos")
            h.addWidget(_field(f"{pos[0]:.0f}, {pos[1]:.0f}, {pos[2]:.0f}" if pos else "Location not set"))
            h.addWidget(_button("Click in the world. Esc cancels" if self.waiting and self.waiting[:2] == (id(a), "pos")
                                else "Pick a point", lambda _c=False: self._request_point(a, "pos"), "qb.teleport_here"))
            h.addStretch(1)
        elif kind in ("walk", "patrol"):
            inner = QtWidgets.QWidget()
            bv = QtWidgets.QVBoxLayout(inner)
            bv.setContentsMargins(0, 0, 0, 0)
            bv.setSpacing(3)
            bv.addWidget(self._target_field(a, "who", "who", "people"))
            pace = _menu_button("runs" if a.get("run") else "walks", [(False, "walks"), (True, "runs")],
                                bool(a.get("run")), lambda k: self._set_in(a, "run", k or None), "qb.follow_run")
            if kind == "walk":
                pos = a.get("pos")
                waiting = self.waiting and self.waiting[:2] == (id(a), "pos")
                where = _button("Click in the world. Esc cancels" if waiting else
                                (f"to {pos[0]:.0f}, {pos[1]:.0f}" if pos else "Pick a point"),
                                lambda _c=False: self._request_point(a, "pos"), "qb.walk_to")
                wait = _menu_button("Quest waits" if a.get("wait") else "Quest continues",
                                    [(False, "Quest continues"), (True, "Quest waits")],
                                    bool(a.get("wait")), lambda k: self._set_in(a, "wait", k or None), "qb.walk_wait")
                bv.addWidget(_row(where, pace, wait, QtWidgets.QWidget()))
            else:
                bv.addWidget(self._path_field(a))
                bv.addWidget(_row(pace, QtWidgets.QWidget()))
            h.addWidget(inner, 1)
        elif kind == "tutorial":
            inner = QtWidgets.QWidget()
            bv = QtWidgets.QVBoxLayout(inner)
            bv.setContentsMargins(0, 0, 0, 0)
            bv.setSpacing(3)
            title = self._text_line(a, "title", "title")
            tip(title, "qb.tut_title")
            text = self._text_line(a, "text", "text - <<Focus>>, <<Jump>> ... show the key")
            tip(text, "qb.tut_text")
            bv.addWidget(_row(title, self._spin(a, "seconds", 2, 60, " s", 8), stretch_last=False))
            bv.itemAt(0).widget().layout().setStretch(0, 1)
            bv.addWidget(text)
            h.addWidget(inner, 1)
        elif kind == "game":
            h.addWidget(self._game_action(a), 1)
        elif kind == "stands":
            h.addWidget(self._stands(a), 1)
        elif kind == "meanwhile":
            h.addWidget(self._meanwhile(a), 1)
        elif kind == "stop":
            h.addWidget(self._stop_lane(a), 1)
        elif kind == "random":
            h.addWidget(self._random(a), 1)
        elif kind == "message":
            h.addWidget(self._text_line(a, "text", "shown on the screen"), 1)
        elif kind == "autosave":
            h.addStretch(1)
        elif kind == "person":
            pbox = QtWidgets.QWidget()          # (not 'box': that is the row itself - rebound, Qt deleted the row)
            bv = QtWidgets.QVBoxLayout(pbox)
            bv.setContentsMargins(0, 0, 0, 0)
            bv.setSpacing(3)
            bv.addWidget(self._target_field(a, "who", "who", "people"))
            img = a.get("image") or "journal_grandma.png"
            portraits = [(p, p[len("journal_"):-4].replace("_", " ")) for p in self._portraits()]
            bv.addWidget(_row(_field("name"), self._text_line(a, "name", "as the journal calls them"),
                              _menu_button("portrait: " + img[len("journal_"):-4].replace("_", " "), portraits, img,
                                           lambda k: self._set_in(a, "image", k), "qb.portrait"),
                              _chip("main character", bool(a.get("main")),
                                    lambda _c=False: self._set_in(a, "main", None if a.get("main") else True),
                                    "qb.person_main"), stretch_last=False))
            bv.itemAt(1).widget().layout().setStretch(1, 1)
            bv.addWidget(self._text_line(a, "text", "what the journal says about them (this paragraph)"))
            h.addWidget(pbox, 1)
        elif kind == "fact":
            n = QtWidgets.QLineEdit(a.get("name", ""))
            n.setPlaceholderText("Fact name")
            n.editingFinished.connect(lambda n=n: self._set_in(a, "name", _fact_typed(n), rebuild=False))
            val = QtWidgets.QSpinBox()
            val.setRange(-1000, 1000)
            val.setValue(int(a.get("value", 1)))
            self._live(val, lambda v: self._set_in(a, "value", v, rebuild=False))
            h.addWidget(n, 1)
            h.addWidget(val)
        if not alone:
            h.addWidget(_icon("trash-2", lambda _c=False: self._remove_step(steps, i), "qb.remove_action"), 0,
                        Q.AlignTop)
        return box

    def _fact_field(self, a):
        """Wait until: a fact typed, or a moment of one of the game's quests picked in its window."""
        fact = self._text_line(a, "fact", "a fact - or pick a moment of a game quest")
        tip(fact, "qb.wait_fact")
        pick = _button("A moment of a game quest...", lambda _c=False, a=a: self.ed.panel.choose_moment(
            lambda m, a=a: (a.update({"fact": m["fact"], "from": m["name"]}), self.save())), "qb.wait_moment")
        from . import features
        if not features.experimental():             # game quests: the update for vanilla editing (Maxim 07.10.)
            pick.hide()
        row = _row(_field("until"), fact, pick, stretch_last=False)
        row.layout().setStretch(1, 1)
        if a.get("from"):
            box = QtWidgets.QWidget()
            v = QtWidgets.QVBoxLayout(box)
            v.setContentsMargins(0, 0, 0, 0)
            v.addWidget(row)
            v.addWidget(_field(f"a moment of the game's quest {a['from']}"))
            return box
        return row

    def _random(self, a, word="outcome", add_tip="qb.random_add"):
        """At random: its ways, each a path or 'goes on'; + way, x on each past the second. (Either's ways too: word
        'way', no odds.)"""
        ways = a.setdefault("ways", [{}, {}])
        box = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(3)
        entries = [("", "continue")] + [(pid, p.get("label") or pid) for pid, p in self.paths().items()] + \
            [("new", "+ new branch")]
        for k, w in enumerate(ways):
            cur = w.get("path") or ""
            b = _menu_button(dict(entries).get(cur, cur), entries, cur,
                             lambda pid, w=w: self._either_path(w, pid), "qb.random_way")
            row = [_field(f"{word} {k + 1}" + (f": 1 in {len(ways)}" if word == "outcome" else ""))] +                 ([] if QN.is_graph(self.quest()) else [b])
            if len(ways) > 2:
                row.append(_icon("trash-2", lambda _c=False, k=k: self._remove_option(ways, k), "qb.random_remove"))
            row.append(QtWidgets.QWidget())
            v.addWidget(_row(*row))
        v.addWidget(_row(_button(f"+ {word}", lambda _c=False: (ways.append({}), self.save()), add_tip, "plus"),
                         QtWidgets.QWidget()))
        return box

    def _gwent(self, v, a):
        """Gwent: against which deck (the factions' first, then the game's people), how hard, where a lost game
        leads."""
        from .minigames import DECKS, deck_label
        deck = a.get("deck")
        decks = sorted(DECKS, key=lambda k: ("," not in deck_label(k), deck_label(k)))
        d = _menu_button(deck_label(deck) if deck else "Which deck", [(k, deck_label(k)) for k in decks], deck,
                         lambda k: self._set_in(a, "deck", k), "qb.gwent_deck")
        if not deck:
            d.setStyleSheet("QToolButton#menu{border-style:dashed;color:#aaa}")
        hard = a.get("difficulty", "medium")
        how = _menu_button(hard, [("medium", "medium"), ("hard", "hard")], hard,
                           lambda k: self._set_in(a, "difficulty", None if k == "medium" else k), "qb.gwent_hard")
        v.addWidget(_row(_field("against"), d, how, QtWidgets.QWidget()))
        self._lost_field(v, a)

    def _fistfight(self, v, a):
        """Fist fight: with whom (people of the places; + who for more), where lost leads."""
        targets = a.setdefault("targets", [])
        for k, hd in enumerate([{"target": t} for t in targets] + ([{}] if not targets else [])):
            tf = self._target_field(hd, "target", "with" if k == 0 else "and", "people",
                                    on_set=lambda ref, k=k: self._set_target(a, k, ref),
                                    ident=(id(a), "targets", k))
            if k and targets:
                tf.layout().itemAt(0).widget().layout().addWidget(
                    _icon("trash-2", lambda _c=False, k=k: self._remove_target(a, k), "qb.remove_action"))
            v.addWidget(tf)
        if targets:
            v.addWidget(_row(_button("+ who", lambda _c=False: self._add_target(a), "qb.fistfight_add", "plus"),
                             QtWidgets.QWidget()))
        self._merchant_note(v, targets)
        self._lost_field(v, a)

    def _merchant_note(self, v, refs):
        """A merchant or smith never fights - the game makes them invulnerable (03.10.: the blacksmith stood still in
        his fist fight): said under the card."""
        from .quest import template_class
        names = []
        for ref in refs or []:
            found = self._find(ref) if ref else None
            if found:
                o = self.ed.project.places[found[0]]["objects"][found[1]]
                if template_class(o["template"]) == "W3MerchantNPC":
                    names.append(str(o.get("display") or o.get("id") or ref))
        if names:
            note = QtWidgets.QLabel(f"{', '.join(names)}: a merchant (the game makes merchants invulnerable, they "
                                    f"never fight or die)")
            note.setStyleSheet("color:#e3c65f;font:11px")
            note.setWordWrap(True)
            v.addWidget(note)

    def _lost_field(self, v, a):
        """A minigame's 'if lost': goes on, plays again, the quest fails, or a path (a new one too). A graph: its
        'lost' output is wired instead."""
        if QN.is_graph(self.quest()):
            return
        entries = [("continue", "continue"), ("retry", "repeatable"), ("fail", "fail quest")] + \
            self.path_entries() + [("new", "+ new branch")]
        lost = a.get("lost") or "continue"

        def chosen(k, a=a):
            if k == "new":
                k = "path:" + self.new_path("Lost at gwent" if "deck" in a else "Lost the fight")
            self._set_in(a, "lost", None if k == "continue" else k)
        v.addWidget(_row(_field("if lost"), _menu_button(dict(entries).get(lost, lost), entries, lost, chosen,
                                                          "qb.gwent_lost"), QtWidgets.QWidget()))

    def _meanwhile(self, a):
        """Meanwhile: which lane (a path of this quest) runs beside the story from here - or a new one. A graph:
        what its 'meanwhile' output is wired to; its name (what Stop lane stops)."""
        if QN.is_graph(self.quest()):
            t = QtWidgets.QLineEdit(str(a.get("path") or ""))
            t.setPlaceholderText("Track name")
            t.editingFinished.connect(lambda t=t, a=a: self._set_in(a, "path", QN.safe(t.text().strip()) or None))
            tip(t, "qb.meanwhile")
            return _row(_field("lane"), t, QtWidgets.QWidget())
        entries = [(pid, p.get("label") or pid) for pid, p in self.paths().items()] + [("__new", "+ new track")]
        cur = a.get("path")
        label = dict(entries).get(cur, "Track not set")

        def chosen(k, a=a):
            if k == "__new":
                k = self.new_path("Meanwhile")
            self._set_in(a, "path", k)
        b = _menu_button(label, entries, cur, chosen, "qb.meanwhile")
        if not cur:
            b.setStyleSheet("QToolButton#menu{border-style:dashed;color:#aaa}")
        return _row(_field("Parallel track"), b, QtWidgets.QWidget())

    def _stop_lane(self, a):
        """Stop lane: which lane (one a Meanwhile starts) stops here."""
        lanes = [st["meanwhile"]["path"] for st in self.all_steps() if "meanwhile" in st and
                 ((st["meanwhile"] or {}).get("path") in self.paths() or QN.is_graph(self.quest()) and
                  (st["meanwhile"] or {}).get("path"))]
        entries = [(pid, QN.label_of(self.quest(), pid)) for pid in dict.fromkeys(lanes)]
        cur = a.get("path")
        b = _menu_button(dict(entries).get(cur, "Track not set"), entries, cur,
                         lambda k, a=a: self._set_in(a, "path", k), "qb.stop_lane")
        if not cur:
            b.setStyleSheet("QToolButton#menu{border-style:dashed;color:#aaa}")
        parts = [_field("stops"), b]
        story = self.steps()
        at = next((k for k, st in enumerate(story) if st.get("stop") is a), None)
        start = next((k for k, st in enumerate(story) if "meanwhile" in st and
                      (st["meanwhile"] or {}).get("path") == cur), None)
        if cur and at is not None and start is not None and start > at:
            early = _field("before its Meanwhile - nothing runs yet")
            early.setStyleSheet("color:#e3c65f;font:12px")
            tip(early, "qb.stop_early")
            parts.append(early)
        return _row(*parts, QtWidgets.QWidget())

    def _stands(self, a):
        """From now on: who, where (a point clicked in the world), what they do there (the game's actions)."""
        from . import npc_actions
        box = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(3)
        v.addWidget(self._target_field(a, "who", "who", "people"))
        pos = a.get("pos")
        waiting = self.waiting and self.waiting[:2] == (id(a), "pos")
        where = _button("Click in the world. Esc cancels" if waiting else
                        (f"at {pos[0]:.0f}, {pos[1]:.0f}" if pos else "+ where"),
                        lambda _c=False: self._request_point(a, "pos"), "qb.stands_where",
                        "target" if pos else "target_empty")
        does = QtWidgets.QToolButton()
        cur = a.get("action")
        does.setText(npc_actions.label(cur.split("/")[-1]) if cur else "stands")
        does.setObjectName("menu")
        menu = QtWidgets.QMenu(does)
        menu.addAction("stands").triggered.connect(lambda _c=False: self._set_in(a, "action", None))
        found = self._find(a.get("who"))
        template = self.ed.project.places[found[0]]["objects"][found[1]]["template"] if found else ""
        for posture, entries in npc_actions.actions(npc_actions.gender_of(template)):
            sub = menu.addMenu(posture)
            seen = set()
            for key, lab in entries:
                if lab not in seen:
                    seen.add(lab)
                    sub.addAction(lab).triggered.connect(lambda _c=False, key=key: self._set_in(a, "action", key))
        attach(does, menu)
        tip(does, "qb.stands_does")
        v.addWidget(_row(_field("from now on"), where, _field("and"), does, QtWidgets.QWidget()))
        return box

    def _game_action(self, a):
        """Game action: the function (searched by name), then a field per parameter of its kind."""
        from . import game_functions as G
        box = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(3)
        names = sorted((G.label(f), f) for f in G.functions() if G.usable(f))
        fn = a.get("function")
        pick = QtWidgets.QLineEdit(G.label(fn) if fn else "")
        pick.setPlaceholderText(f"Search the game's actions ({len(names)})")
        comp = QtWidgets.QCompleter([f"{lab}   ({f})" for lab, f in names], pick)
        comp.setCaseSensitivity(Q.CaseInsensitive)
        comp.setFilterMode(Q.MatchContains)
        comp.setMaxVisibleItems(16)
        pick.setCompleter(comp)
        tip(pick, "qb.game_fn")

        def chosen(text):
            f = text.rsplit("(", 1)[-1].rstrip(")") if "(" in text else None
            if f and f in G.functions() and f != a.get("function"):
                a["function"], a["args"] = f, {}
                self.save()
        comp.activated.connect(chosen)
        v.addWidget(_row(_field("does"), pick, stretch_last=False))
        v.itemAt(0).widget().layout().setStretch(1, 1)
        if not fn or fn not in G.functions():
            return box
        args = a.setdefault("args", {})
        grid = QtWidgets.QGridLayout()
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(6)
        from .fields import with_unit
        for r, (n, t, optional) in enumerate(G.functions()[fn]["params"]):
            k = G.kind(t)
            grid.addWidget(_field(G.words(n) + (" (optional)" if optional else "")), r, 0)
            if G.is_tag(n, t):
                w = self._target_field(args, n, "", "people" if G.is_person(n) else "things", ident=f"{id(a)}:{n}")
            elif k == "bool":
                w = QtWidgets.QCheckBox()
                w.setChecked(bool(args.get(n, False)))
                w.toggled.connect(lambda on, n=n: self._set_in(args, n, bool(on), rebuild=False))
            elif k in ("int", "float"):
                w = QtWidgets.QDoubleSpinBox() if k == "float" else QtWidgets.QSpinBox()
                w.setRange(-1000000, 1000000)
                w.setValue(args.get(n, 0) or 0)
                w.editingFinished.connect(lambda w=w, n=n, k=k: self._set_in(
                    args, n, float(w.value()) if k == "float" else int(w.value()), rebuild=False))
                w = with_unit(w)
            elif k == "enum":
                values = G.enums().get(t, [])
                w = _menu_button(args.get(n) or (values[0] if values and not optional else "-"),
                                 [(x, x) for x in values], args.get(n), lambda x, n=n: self._set_in(args, n, x),
                                 "qb.game_enum")
            else:
                w = QtWidgets.QLineEdit(str(args.get(n, "")))
                w.editingFinished.connect(lambda w=w, n=n: self._set_in(args, n, w.text().strip() or None,
                                                                         rebuild=False))
            grid.addWidget(w, r, 1)
        grid.setColumnStretch(1, 1)
        v.addLayout(grid)
        return box

    # --- small fields of the action rows
    @staticmethod
    def _live(w, commit):
        """A number field that takes effect while typing, a moment after the last key (Maxim 08.10.: the radius
        changed only after Enter) - Enter or leaving the field at once."""
        t = QtCore.QTimer(w)
        t.setSingleShot(True)
        t.setInterval(400)
        t.timeout.connect(lambda: commit(w.value()))
        w.valueChanged.connect(lambda _v: t.start())
        w.editingFinished.connect(lambda: (t.stop(), commit(w.value())))
        return w

    def _spin(self, d, key, lo, hi, suffix, default, scale=1):
        from .fields import with_unit
        w = QtWidgets.QSpinBox()
        w.setRange(lo, hi)
        w.setValue(int(round(float(d.get(key, default / scale)) * scale)))
        self._live(w, lambda v: self._set_in(d, key, v / scale if scale != 1 else v, rebuild=False))
        return with_unit(w, suffix)

    def _text_line(self, d, key, placeholder, names=None):
        e = QtWidgets.QLineEdit(str(d.get(key, "")))
        e.setPlaceholderText(placeholder)
        if names:
            comp = QtWidgets.QCompleter(names, e)
            comp.setCaseSensitivity(Q.CaseInsensitive)
            comp.setFilterMode(Q.MatchContains)
            e.setCompleter(comp)
        e.editingFinished.connect(lambda: self._set_in(d, key, e.text().strip() or None, rebuild=False))
        return e

    def _more_items(self, v, a):
        """More items for a loot / collect (Maxim, 01.10.: a whole armour set): a row each (how many, remove), and
        '+ item' once the first is chosen."""
        if not a.get("item"):
            return
        more = a.setdefault("more_items", [])
        for k, x in enumerate(more):
            count = QtWidgets.QSpinBox()
            count.setRange(1, 999)
            count.setValue(int(x.get("count", 1)))
            self._live(count, lambda v, x=x: self._set_in(x, "count", v, rebuild=False))
            tip(count, "qb.count")
            # its trash can takes the row out (an item chosen or not)
            row = _row(_field("and"), self._item_line(
                x, on_set=lambda ref, k=k, x=x: (more.pop(k) if ref is None else x.update(item=ref), self.save()),
                required=False, removable=True), count, stretch_last=False)
            row.layout().setStretch(1, 1)
            v.addWidget(row)
        v.addWidget(_row(_button("+ item", lambda _c=False: (more.append({}), self.save()), "qb.more_items", "plus"),
                         QtWidgets.QWidget()))

    def _item_line(self, d, key="item", on_set=None, placeholder="item", required=True, removable=False):
        """An item: a button with its name that opens the item chooser (item_chooser.py - the same everywhere); a
        small x takes it out again. Kept as the game item's name or own:<id>."""
        from .item_chooser import item_label
        value = str(d.get(key, "") or "")

        def put(ref):
            if on_set is not None:
                on_set(ref)
            else:
                self._set_in(d, key, ref)
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(2)
        b = QtWidgets.QPushButton(item_label(value, self.quest(), self.assets()) if value else f"+ {placeholder}")
        b.setObjectName("target" if value else "target_empty")      # dashed while missing: the next thing to do
        if not value and required:
            from .icons import icon
            b.setIcon(icon("octagon-alert", MISSING_RED, 14))
        b.setFocusPolicy(Q.NoFocus)
        b.clicked.connect(lambda: self.ed.panel.choose_item(put))
        tip(b, "dlg.item")
        h.addWidget(b, 1)
        if value or removable:
            h.addWidget(_icon("trash-2", lambda _c=False: put(None), "ins.remove_item"))
        return box

    def _item_names_list(self):
        db = self.assets()
        if db is not None and getattr(self, "_item_names", None) is None:
            self._item_names = sorted({r["name"] for r in db.items("", limit=100000)})
        own = [it.get("name") or iid for iid, it in (self.quest().get("items") or {}).items()]  # own items first
        return own + (getattr(self, "_item_names", None) or [])

    def _portraits(self):
        """The game's journal portraits (the character pages' images) to choose from."""
        if getattr(self, "_portrait_list", None) is None:
            from . import journal_images
            self._portrait_list = journal_images.portraits()
        return self._portrait_list

    def _sound_names(self):
        """The game's sound events (radish's repository of them), for the completer."""
        if getattr(self, "_sounds", None) is None:
            import os
            import re
            from . import config
            self._sounds = []
            try:
                path = os.path.join(config.load()["radish"], "repo.scenes", "soundevents.with-exp.repo.yml")
                text = open(path, encoding="utf-8", errors="replace").read()
                self._sounds = sorted(set(re.findall(r'\n\s+- "([^"]+)"', text)))
            except (OSError, KeyError):
                pass
        return self._sounds

    def _test_from(self, steps, index):
        """Build & Play a test that starts at this step."""
        if isinstance(steps, QG.Slot):
            spec = ("node", steps.nid)
        elif isinstance(steps, StoryList):
            spec = ("node", self.node_of(steps[index]))
        elif steps is self.steps():
            spec = ("main", index)
        else:
            pid = next(p for p, d in self.paths().items() if d.get("steps") is steps)
            spec = ("path", pid, index)
        panel = self.window()
        if hasattr(panel, "test_from"):
            panel.test_from(spec)

    def _take_ref(self, a, key, ref):
        """A chosen object: into the field, or to where the field hands it (several targets)."""
        on_set = a.pop("_on_set", None)
        if on_set is not None:
            on_set(ref)
        else:
            self._set_in(a, key, ref)

    def _set_target(self, a, k, ref):
        targets = a.setdefault("targets", [])
        if k < len(targets):
            targets[k] = ref
        else:
            targets.append(ref)
        self.save()

    def _add_group(self, a, n, radius=2.5):
        """n creatures of one kind in a ring around a point clicked in the world; all of them targets of `a`."""
        def chosen(path):
            variants = getattr(self, "chosen_variants", None)     # a catalog folder: each one a random variant

            def done(place, pos, a=a):
                import math
                import random
                self.waiting = None
                objs = self.ed.project.place(place, getattr(self.ed, "world", None))["objects"]
                refs = []
                for k in range(n):
                    ang = 2 * math.pi * k / n
                    p = [round(pos[0] + radius * math.cos(ang), 3), round(pos[1] + radius * math.sin(ang), 3),
                         round(pos[2], 3)]
                    yaw = round((math.degrees(ang) + 90) % 360 - 180, 1)       # facing the middle
                    tpl = random.choice(variants) if variants else path
                    objs.append({"template": tpl, "pos": p, "rot": [0.0, 0.0, yaw]})
                    refs.append(f"{place}/{self.ed.project.name_object(place, len(objs) - 1)}")
                    if place == self.ed.place and hasattr(self.ed, "link"):
                        self.ed.link.exec(f'cj_spawn("{tpl}", {p[0]}, {p[1]}, {p[2]}, 0, 0, {yaw})')
                self.ed.project.save_place(place)
                a["targets"] = [t for t in a.get("targets") or [] if t] + refs
                a.pop("target", None)
                self.save()
            self.waiting = (id(a), "group", "point")
            self.ed.request_object("point", "point", done)
            self.sync()
        self.choose("creatures", chosen)

    def _more_targets(self, v, a, what):
        """The same action on more things (Keira's four candles): a row each with its trash can, '+ another' once
        the first is chosen."""
        if not a.get("target"):
            return
        more = a.get("more_targets") or []
        for k, t in enumerate(more):
            tf = self._target_field({"target": t}, "target", "and", what,
                                    on_set=lambda ref, k=k: self._set_more_target(a, k, ref),
                                    ident=(id(a), "more_targets", k))
            tf.layout().itemAt(0).widget().layout().addWidget(
                _icon("trash-2", lambda _c=False, k=k: self._remove_more_target(a, k), "qb.remove_action"))
            v.addWidget(tf)
        v.addWidget(_row(_button("+ another", lambda _c=False: self._add_more_target(a), "qb.more_targets", "plus"),
                         QtWidgets.QWidget()))

    def _set_more_target(self, a, k, ref):
        more = a.setdefault("more_targets", [])
        if k < len(more):
            more[k] = ref
        else:
            more.append(ref)
        self.save()

    def _add_more_target(self, a):
        self.open_picker = None
        a.setdefault("more_targets", []).append("")
        self.save()

    def _remove_more_target(self, a, k):
        a["more_targets"].pop(k)
        if not a["more_targets"]:
            a.pop("more_targets")
        self.save()

    def _add_target(self, a):
        self.open_picker = None
        a.setdefault("targets", []).append("")
        self.save()

    def _remove_target(self, a, k):
        a["targets"].pop(k)
        self.save()

    # a list of object refs in a dict (a clue's trail)
    def _set_listed(self, d, key, k, ref):
        items = d.setdefault(key, [])
        if k < len(items):
            items[k] = ref
        else:
            items.append(ref)
        self.save()

    def _add_listed(self, d, key):
        self.open_picker = None
        d.setdefault(key, []).append("")
        self.save()

    def _remove_listed(self, d, key, k):
        d[key].pop(k)
        if not d[key]:
            d.pop(key)
        self.save()

    # --- changes
    def _set_in(self, d, key, value, rebuild=True):
        """A field of a step's dict (or of a path)."""
        if value is None or value == "":
            d.pop(key, None)
        else:
            d[key] = value
        self.save(rebuild)

    def _set_place_action(self, a, kind, name):
        if kind == "show":                          # shown by the quest, not from the start
            p = self.ed.project.places.get(name)
            if p is not None and p.get("visible") != "step":
                p["visible"] = "step"
                self.ed.project.save_place(name)
        self._set_in(a, "place", name)

    def _toggle_picker(self, a, key, ident=None):
        ident = ident or id(a)
        if key == "alive":                          # the must-survive list has one picker, whatever holds it
            self.open_picker = None if self.open_picker and self.open_picker[1] == "alive" else (0, "alive")
        else:
            self.open_picker = None if self.open_picker == (ident, key) else (ident, key)
        self.sync()

    def _picked(self, a, key, where):
        if not where:
            return
        place, index = where
        oid = self.ed.project.name_object(place, index)
        self.open_picker = None
        self._take_ref(a, key, f"{place}/{oid}")

    def _change_kind(self, steps, goal, kind):
        """The step becomes another kind: a new one of that kind in its place, its journal line and what fits
        (who, what, which item, how many) carried over."""
        old_kind, old = step_kind(steps[goal])
        if kind == old_kind:
            return
        steps[goal] = self._goal_step(kind)
        new_kind, new = step_kind(steps[goal])
        field = {k: f for k, _l, f in GOALS}
        for key in ("text", "item", "count"):
            if key in old and (key == "text" or key in new or field.get(new_kind) == key):
                new[key] = old[key]
        ref = old.get("npc") or old.get("target") or old.get("object")
        want = field.get(new_kind)
        if ref and want in ("npc", "target", "object") and not new.get(want):
            new[want] = ref
        self.save()

    def _add_goal(self, steps, index, kind):
        steps.insert(index, self._goal_step(kind))
        self.graph_pick = steps[index]          # a new step is the one worked on
        self.save()

    def _goal_step(self, kind):
        """A new goal step: what it needs to start with (the object picked in the world, if it fits)."""
        args = {"place": self.ed.place, "radius": 10} if kind == "goto" else \
            {"time": "00:00:10"} if kind == "wait" else {"count": 1} if kind == "collect" else {}
        if kind == "clues":
            args["clues"] = [{"says": {}}]
        if kind == "deliver":
            # a talk whose answer hands the item over - it shows only when Geralt has it
            kind, args = "talk", {"dialogue": [
                {"who": "npc", "text": "Did you bring it?"},
                {"choice": [{"text": "Here it is.", "give": {"item": "", "count": 1}, "lines": [
                    {"who": "npc", "text": "Thank you, witcher."}], "end": "continue"},
                    {"text": "Not yet.", "lines": [], "end": "retry"}]}]}
        if kind in ("talk", "loot", "examine", "use", "kill"):
            oid = self.ed.selected_object_id()
            key = {"talk": "npc", "kill": "target"}.get(kind, "object")
            found = self._find(f"{self.ed.place}/{oid}") if oid else None
            if found:
                # the object selected in the world - if it fits: someone to talk to / kill, a thing to loot / use
                from .quest import is_actor
                o = self.ed.project.places[found[0]]["objects"][found[1]]
                if is_actor(o) == (kind in ("talk", "kill")):
                    args[key] = f"{self.ed.place}/{oid}"
        if kind == "either" and QN.is_graph(self.quest()):
            args["ways"] = [{}, {}]                     # wired to goals of their own, the first done wins (02.10.)
        elif kind == "either":
            args["options"] = [{"goal": {"kill": {}}}, {"goal": {"goto": {"place": self.ed.place, "radius": 10}}}]
        if kind == "all":
            args["options"] = [{"goal": {"loot": {}}}, {"goal": {"examine": {}}}]
        return {kind: args}

    def _mouth(self, o):
        """Does this person's mouth move when they talk: 'moves', 'shut' (this look not, another would), 'none' (no
        look of them), 'animal' (no dialogue body at all) - None: not known (no game to look in)."""
        from . import talking
        try:
            talking.talking_looks(o["template"])
            state = talking.mouth(o["template"], o.get("appearance"))
            if state == "none" and not talking.dialogue_anims(o["template"]):
                return "animal"
            return state
        except Exception:                               # noqa: BLE001 - no game to look in
            return None

    MOUTH = {"moves": "mouth moves", "shut": "this look: mouth stays shut", "none": "no look of them moves the mouth",
             "maybe": "random look: the game may give them one whose mouth stays shut",
             "animal": "animal: no mouth movement"}

    def _mouth_row(self, ref):
        """Under a talk's 'who': whether their mouth moves to the lines (Maxim 01.10.: 'tell lip-synced from not at
        a glance') - a look that cannot: one click takes one that can."""
        found = self._find(ref)
        if not found:
            return None
        place, k = found
        o = self.ed.project.places[place]["objects"][k]
        state = self._mouth(o)
        if state is None:
            return None
        lab = _field(self.MOUTH[state])
        lab.setStyleSheet("color:%s" % ("#9a9a9e" if state in ("moves", "animal") else "#d6a65a"))
        tip(lab, "qb.mouth")
        if state not in ("shut", "maybe"):
            return _row(_field(""), lab)
        return _row(_field(""), lab, _button("Use talking look", lambda _c=False: self._talking_look(place, k),
                                             "qb.talking_look"), QtWidgets.QWidget())

    def _talking_look(self, place, k):
        """The person gets the first look whose face can move its mouth - in the place file and in the world."""
        from . import talking
        o = self.ed.project.places[place]["objects"][k]
        looks = talking.known_talking(o["template"]) or []
        if not looks:
            return
        self.ed.project.set_object(place, k, appearance=looks[0])
        if getattr(self.ed, "editing", False) and place == getattr(self.ed, "place", None):
            x, y, z = o["pos"]
            self.ed.link.exec(f'cj_appearance({x}, {y}, {z}, "{looks[0]}")')
        self.sync()

    def _body(self, ref):
        """The scene animations of a placed person (`ref`) or of the player (None) - talking.dialogue_anims; None:
        not known (every gesture is offered)."""
        from . import dialogue as D
        if ref is None:
            template = D.PLAYERS.get(self.quest().get("player") or "geralt", D.PLAYERS["geralt"])["template"]
        else:
            found = self._find(ref)
            if not found:
                return None
            template = self.ed.project.places[found[0]]["objects"][found[1]]["template"]
        try:
            from .talking import dialogue_anims
            return dialogue_anims(template)
        except Exception:                               # noqa: BLE001 - no game to look in
            return None

    def _say_speaker(self, a, who):
        if who == "someone":
            a.setdefault("who", "")
            for key in ("voice", "dur", "voice_pack"):
                a.pop(key, None)                        # Geralt's voiced line is not theirs
        else:
            a.pop("who", None)
        self.save()

    def _reward_item(self, a, k, ref):
        """A reward's item k set (None: taken out; k past the end: a new, empty one)."""
        items = list(a.get("items") or [])
        if k >= len(items):
            items.append(ref or "")
        elif ref:
            items[k] = ref
        else:
            items.pop(k)
        if items:
            a["items"] = items
        else:
            a.pop("items", None)
        self.save()

    def _add_action(self, steps, at, kind):
        steps.insert(at, self._action_step(kind))
        self.graph_pick = steps[at]
        self.save()

    def _action_step(self, kind):
        args = {"money": 100, "xp": 50} if kind == "reward" else {"name": "", "value": 1} if kind == "fact" else \
            {"ways": [{}, {}]} if kind == "random" else {}
        return {kind: args}

    def _remove_step(self, steps, i):
        if isinstance(steps, StoryList):
            self._remove_joined(self.node_of(steps[i]))
            self.save()
            return
        if isinstance(steps, QG.Slot):
            self._remove_node(steps.nid)
            return
        steps.pop(i)
        self.save()

    def delete_picked(self):
        """Delete: a dialogue's pick on its page; else a wire clicked, else the node picked (the start stays)."""
        if self.dialogue is not None:
            self.dialogue.delete_picked()
            return
        link = self.graph.chosen_wire
        if link:
            self._graph_unlink(link)
        elif self.graph_node and self.graph_node != QN.START and self.graph_node in self.graph_quest()["nodes"]:
            self._remove_node(self.graph_node)

    def _remove_node(self, nid):
        """A node goes, and its wires (the start stays)."""
        q = self.graph_quest()
        if nid == QN.START:
            return
        q["nodes"].pop(nid, None)
        q["links"] = [ln for ln in q["links"] if nid not in (ln[0], ln[2])]
        self.save()

# the graph's model reads this module's names: imported once they all exist
from . import quest_graph as QG  # noqa: E402


class StoryList(list):
    """The quest's steps in story order (from its start along the wires, then those nothing leads to), as a list whose
    changes wire the graph: insert - after the step before it (and on to where that went); pop / remove - its
    neighbours joined; a step put in place of another - into that node."""

    def __init__(self, board):
        self.board = board
        q = board.graph_quest()
        super().__init__(q["nodes"][n]["step"] for n in board._story())

    def insert(self, i, step):
        ids = self.board._story()
        i = len(ids) + i if i < 0 else min(i, len(ids))
        self.board.add_after(ids[i - 1] if i > 0 else QN.START, step)
        super().insert(i, step)

    def append(self, step):
        self.insert(len(self), step)

    def pop(self, i=-1):
        step = self[i]
        self.board._remove_joined(self.board.node_of(step))
        return super().pop(i)

    def remove(self, step):
        self.pop(self.index(step))

    def __setitem__(self, i, step):
        nid = self.board.node_of(self[i])
        self.board.graph_quest()["nodes"][nid]["step"] = step
        super().__setitem__(i, step)
