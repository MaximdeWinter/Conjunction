"""The dialogue of a talk step: laid out to be read at a glance (dialogue_flow: what is always said down the
middle, the ways that go on under a choice, questions and ends to its right), the card of what is picked under it
(dialogue.py keeps the tree).

    the sidebar     Line, Choice, If - let go on a block: after it; on an answer's row: into its way; clicked:
                    after what is picked
    lines           a block per run of lines; its card: every line - who says it, the words (Enter: the next line,
                    the other one speaks), the game's own voice for them (searched among 64 000 voiced lines), a
                    gesture, a mood
    a choice        its answers; its card: their words, what each does after its lines (goes on in the talk, a
                    question - back to the choices, ends the talk: the quest goes on / later / it fails), and what
                    it costs, needs, does
    a right click   remove it

Every change is saved at once.
"""
import threading
import time

from PySide6 import QtCore, QtGui, QtWidgets

from . import dialogue as D
from . import dialogue_flow as F
from .dialogue_flow_view import FlowView
from . import theme
from .tooltips import tip
from .inline_menu import attach

Q = QtCore.Qt

STYLE = """
QFrame#line{background:#26262a;border:1px solid #3c3c42;border-radius:0}
QFrame#choice{background:#222226;border:1px solid #4a4a50;border-radius:0}
QFrame#branch{border:none;border-left:2px solid #3c3c42;margin-left:10px}
QToolButton#who{color:#e8e8e8;background:#34343a;border:1px solid #55555c;border-radius:0;padding:2px 8px;
  font:bold 11px;min-width:64px}
QToolButton#who[geralt="true"]{color:#d0d0d0;background:#2b2b30}
QToolButton#who:hover{border-color:#aaa}
QToolButton#opt{color:#9a9a9a;background:transparent;border:1px solid transparent;padding:1px 6px;font:11px}
QToolButton#opt:hover{color:#eee;border-color:#555}
QToolButton#opt[set="true"]{color:#e8e8e8;border-color:#55555c;background:#2e2e33}
QToolButton#opt::menu-indicator{image:none;width:0}
QLabel#head{color:#9a9a9a;font:bold 11px}
QLabel#num{color:#bbb;font:bold 12px;min-width:16px}
QLabel#note{color:#8a8a8a;font:11px}
QPushButton#small{padding:2px 8px;font:12px}
QPushButton#plus{color:#9a9a9a;background:transparent;border:1px dashed #444;padding:2px 8px;font:12px}
QPushButton#plus:hover{color:#eee;border-color:#888}
"""


def _button(text, fn, key=None, name="small"):
    b = QtWidgets.QPushButton(text)
    b.setObjectName(name)
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


_MOUTH = {}                     # text -> seconds the mouth moves to it (radish times it from the text alone)


def lip_seconds(x):
    """How long the line's voice or mouth lasts (seconds), or None while it is still being timed."""
    if x.get("voice") or x.get("voice_pack"):
        return float(x.get("dur") or 0) or None
    text = " ".join(str(x.get("text", "")).split())
    if not text or x.get("thought"):
        return None
    if text not in _MOUTH:
        _MOUTH[text] = None

        def run():
            try:
                from .speech import text_timing
                _MOUTH[text] = text_timing([{"id": 2111000001, "text": text, "source": None, "lang": "en"}]).get(2111000001)   # (an id of a scene line's size: a small one is not timed)
            except Exception:                   # noqa: BLE001 - no radish here: no length shown
                _MOUTH[text] = 0.0
        threading.Thread(target=run, daemon=True).start()
    return _MOUTH[text]


def length_field(x, on_set):
    """[Length] [ s ] (lip sync 2.6 s): empty - as long as the voice / the mouth; a number - at least that long."""
    box = QtWidgets.QWidget()
    h = QtWidgets.QHBoxLayout(box)
    h.setContentsMargins(0, 0, 0, 0)
    h.setSpacing(4)
    lab = QtWidgets.QLabel("Length")
    lab.setStyleSheet("color:#8a8a8a;font:11px")
    edit = QtWidgets.QLineEdit("" if not x.get("length") else f"{float(x['length']):g}")
    edit.setFixedWidth(52)
    edit.setPlaceholderText("auto")
    tip(edit, "dlg.length")
    unit = QtWidgets.QLabel("s")
    unit.setStyleSheet("color:#8a8a8a;font:11px")
    info = QtWidgets.QLabel("")
    info.setStyleSheet("color:#8a8a8a;font:11px")

    def shown():
        s = lip_seconds(x)
        try:
            info.setText(f"(lip sync {s:.1f} s)" if s else "")
        except RuntimeError:                    # the card was made anew meanwhile
            return
        if s is None and str(x.get("text", "")).strip() and not (x.get("voice") or x.get("voice_pack") or
                                                                 x.get("thought")):
            QtCore.QTimer.singleShot(400, shown)    # (still being timed)
    shown()
    box.refresh = shown

    def done():
        t = edit.text().strip().replace(",", ".")
        try:
            v = round(float(t), 2) if t else None
        except ValueError:
            v = x.get("length")
        on_set(v if v and v > 0 else None)
    edit.editingFinished.connect(done)
    for w in (lab, edit, unit, info):
        h.addWidget(w)
    return box


def _opt(text, on, key):
    b = QtWidgets.QToolButton()
    b.setObjectName("opt")
    b.setText(text.replace("&", "&&"))
    b.setProperty("set", bool(on))
    b.setFocusPolicy(Q.NoFocus)
    tip(b, key)
    return b


def _toggle_icon(name, on, key):
    """A small icon button that is on or off (Once): white when on, dim when off."""
    from .icons import icon
    b = _icon(name, None, key)
    b.setIcon(icon(name, "#ffffff" if on else "#6a6a70"))
    b.setCheckable(True)
    b.setChecked(on)
    return b


def _fact_typed(field):
    from .questboard import _fact_typed as typed
    return typed(field)


def _voice_icon(button, voiced):
    """A line's voice (Maxim, 01.10.): audio lines in green when it has one, red with an x when not."""
    from .icons import GREEN, RED, set_icon
    set_icon(button, "audio-lines" if voiced else "audio-lines-x", GREEN if voiced else RED)
    button.setToolButtonStyle(Q.ToolButtonTextBesideIcon if button.text() else Q.ToolButtonIconOnly)


def _menu(button, entries, current, fn):
    """A flat list to choose from: (key, label); None = none. Filled when it opens (a big talk has hundreds)."""
    m = QtWidgets.QMenu(button)             # its look: the board's STYLE
    make = entries if callable(entries) else None   # filled anew each time it opens (what can be added changes)
    entries = [] if make else list(entries)

    def fill():
        if make is not None:
            m.clear()
        elif m.actions():
            return
        for k, label in (make() if make is not None else entries):
            a = m.addAction(label)
            a.setCheckable(True)
            a.setChecked(k == current)
            a.triggered.connect(lambda _c=False, k=k: fn(k))
    m.aboutToShow.connect(fill)
    attach(button, m)


def _hbox(*widgets, stretch=None, margins=(0, 0, 0, 0)):
    w = QtWidgets.QWidget()
    h = QtWidgets.QHBoxLayout(w)
    h.setContentsMargins(*margins)
    h.setSpacing(4)
    for i, x in enumerate(widgets):
        if x is None:
            h.addStretch(1)
        else:
            h.addWidget(x, 1 if i == stretch else 0)
    return w


INDENT = 22                             # one level of a dialogue: this much to the right
ANSWER_DOES = [("emphasize", "Main option (yellow, first)"), ("pay", "Player pays crowns"),
               ("axii", "Persuade with Axii"), ("give", "Player gives an item"),
               ("receive", "Player receives something"), ("shop", "Opens the shop")]
ENTRY = ("QPushButton#entry{text-align:left;color:#ddd;background:#1d1d20;border:none;padding:3px 6px;font:12px}"
         "QPushButton#entry:hover{background:#34343a}")
END_COLOR = {"back": "#bbbbbb", "up": "#bbbbbb", "continue": "#9fd38a", "retry": "#e3c65f", "fail": "#e57a7a"}
BLOCKS = [("line", "Line"), ("choice", "Choice"), ("if", "If")]         # the dialogue's own sidebar
CHOICE, IF = "#b99be6", "#d9a45b"
BLOCK_COLOUR = {"line": "#c8c8d0", "choice": CHOICE, "if": IF}


def _short(text, n=80):
    return text if len(text) <= n else text[:n - 3].rstrip() + "..."


# the speakers' colours (dialogue.py: Geralt and twelve) - one rule each in the shared stylesheet, the widgets only
# carry their number (a stylesheet of their own each made a big talk slow: ~2 per line)
SPEAKER_COLORS = [D.GERALT_COLOR] + D.COLORS
STYLE += "".join(
    f"QFrame#line[c=\"{i}\"]{{background:#26262a;border:1px solid #3a3a40;border-left:3px solid {c};border-radius:0}}"
    f"QToolButton#speaker[c=\"{i}\"]{{color:{c};background:#1f1f23;border:1px solid {c};border-radius:0;"
    f"padding:2px 8px;font:bold 11px;min-width:56px}}"
    f"QToolButton#speaker[c=\"{i}\"]:hover{{background:#2c2c32}}"
    for i, c in enumerate(SPEAKER_COLORS))
STYLE += ("QToolButton#speaker::menu-indicator{image:none;width:0}"
          f"QFrame#answer{{background:#222226;border:1px solid #3a3a40;border-left:3px solid {D.GERALT_COLOR};"
          "border-radius:0}")


def _speaker(widget, colour):
    """A line card / speaker button in its speaker's colour (a rule of the shared stylesheet)."""
    widget.setProperty("c", str(SPEAKER_COLORS.index(colour) if colour in SPEAKER_COLORS else 0))
    return widget


class Hover(QtWidgets.QFrame):
    """A row whose tools (move, remove) show only while the mouse is on it."""

    def __init__(self):
        super().__init__()
        self._tools = []

    @property
    def tools(self):
        return self._tools

    @tools.setter
    def tools(self, widgets):
        self._tools = widgets
        for w in widgets:
            keep = w.sizePolicy()
            keep.setRetainSizeWhenHidden(True)
            w.setSizePolicy(keep)
            w.setVisible(False)

    def enterEvent(self, e):
        for w in self._tools:
            w.setVisible(True)
        super().enterEvent(e)

    def leaveEvent(self, e):
        for w in self._tools:
            w.setVisible(False)
        super().leaveEvent(e)


class AutoText(QtWidgets.QPlainTextEdit):
    """A text field as tall as its text (long lines wrap); `done` when it loses the focus, `enter` on Enter."""
    done = QtCore.Signal(str)
    enter = QtCore.Signal(str)

    def __init__(self, text, placeholder):
        super().__init__(text)
        self.setPlaceholderText(placeholder)
        self.setVerticalScrollBarPolicy(Q.ScrollBarAlwaysOff)
        self.setHorizontalScrollBarPolicy(Q.ScrollBarAlwaysOff)
        self.setTabChangesFocus(True)
        self.setObjectName("autotext")          # its look: the board's STYLE (not a sheet of its own - speed)
        self.document().documentLayout().documentSizeChanged.connect(self._fit)
        self._fit()

    def _fit(self, *_):
        # the laid-out height of the text (wrapped at the width it has now)
        doc = self.document()
        h, block = 0.0, doc.begin()
        while block.isValid():
            h += self.blockBoundingRect(block).height()
            block = block.next()
        h = max(h, self.fontMetrics().lineSpacing())
        self.setFixedHeight(int(h + 2 * doc.documentMargin() + 2 * self.frameWidth()) + 6)

    def resizeEvent(self, e):
        super().resizeEvent(e)
        QtCore.QTimer.singleShot(0, self, self._fit)     # (not after the field is gone)

    def keyPressEvent(self, e):
        if e.key() in (Q.Key_Return, Q.Key_Enter):
            self._entered = True                # one line of speech: Enter ends it (and goes on to the next)
            self.enter.emit(self.toPlainText())
            return
        super().keyPressEvent(e)

    def focusOutEvent(self, e):
        super().focusOutEvent(e)
        if not getattr(self, "_entered", False):
            self.done.emit(self.toPlainText())


class DialogueView(QtWidgets.QWidget):
    """Opened from a talk card of the quest board; `back` returns to it."""
    back = QtCore.Signal()

    def __init__(self, board, st):
        super().__init__()
        self.board, self.st = board, st           # the talk step's dict (on the board, in a path)
        kind, args = next(iter(st.items()))
        self.monologue = kind == "examine"      # a talk with himself: examining a clue (only the player speaks)
        self.setStyleSheet(STYLE)
        self.voice_open = None                  # the line (dict) whose voice search is open
        self.anim_open = None                   # the line whose animation search is open
        self.voice_source = "game"              # game: the game's own lines / custom: the content packs' recordings
        self.custom_find, self.custom_tags = "", set()
        self.voices = None
        self.player = self.playing = self._after_play = None
        self.folded = set()                     # (kept for older callers: the graph shows every way)
        self.focus_line = None                  # the line whose text field gets the keys after the next rebuild
        self.adding = None                      # the row to add a person is open
        self.picked = None                      # the line / choice / If (its dict) whose card shows under the graph
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 6, 0, 0)
        v.setSpacing(6)
        self.head = QtWidgets.QWidget()
        v.addWidget(self.head)
        from .graph_blocks import BlockBar
        self.graph = FlowView()                 # the talk laid out (dialogue_flow)
        self.graph.picked.connect(self._pick)
        self.graph.opened.connect(self._open)
        self.graph.menu.connect(self._box_menu)
        self.graph.place.connect(self._place)
        self.blocks = BlockBar(self.graph, self._click_block,
                               [(b, label, BLOCK_COLOUR[b], f"dblk.{b}") for b, label in BLOCKS])
        self.scroll = QtWidgets.QScrollArea()   # the card of the node picked
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QtWidgets.QFrame.NoFrame)
        self.scroll.setHorizontalScrollBarPolicy(Q.ScrollBarAlwaysOff)
        self.split = QtWidgets.QSplitter(Q.Vertical)
        self.split.addWidget(self.graph)
        self.split.addWidget(self.scroll)
        self.split.setChildrenCollapsible(False)
        self.split_frac = 0.6
        self.split.splitterMoved.connect(self._split_moved)
        area = QtWidgets.QHBoxLayout()
        area.setContentsMargins(0, 0, 0, 0)
        area.setSpacing(6)
        area.addWidget(self.blocks)
        area.addWidget(self.split, 1)
        v.addLayout(area, 1)
        self._anchor = QtWidgets.QWidget(self.graph.viewport())    # where a node's list opens
        self._anchor.resize(1, 1)
        self._anchor.hide()
        self._shown = False
        self.sync()

    # --- data
    def step(self):
        kind, a = next(iter(self.st.items()))
        if a.get("dialogue") is None:           # the older form becomes the tree once
            a["dialogue"] = D.from_step(a)
            a.pop("lines", None)
            a.pop("choices", None)
        return a

    def lines(self):
        return self.step()["dialogue"]

    def player_label(self):
        """The name of whoever is played at this talk (Geralt, or Ciri after a 'Play as')."""
        from .quest import characters
        q = self.board.quest() if hasattr(self.board, "quest") else {}
        who = characters(q).get(id(self.step()), q.get("player") or "geralt")
        return D.PLAYERS.get(who, D.PLAYERS["geralt"])["label"]

    def player_voicetag(self):
        """The voicetag of whoever is played at this talk (Geralt, or Ciri after a 'Play as') - their voiced lines."""
        from .dialogue import PLAYERS
        from .quest import characters
        q = self.board.quest() if hasattr(self.board, "quest") else {}
        who = characters(q).get(id(self.step()), q.get("player") or "geralt")
        return PLAYERS.get(who, PLAYERS["geralt"])["voicetag"]

    def body_of(self, key):
        """The scene animations the speaker `key` can play (talking.dialogue_anims; None: not known)."""
        from .quest import characters
        if D.is_player(key):
            q = self.board.quest() if hasattr(self.board, "quest") else {}
            who = characters(q).get(id(self.step()), q.get("player") or "geralt")
            template = D.PLAYERS.get(who, D.PLAYERS["geralt"])["template"]
        else:
            found = self.board._find(self.step().get("npc") if key == "npc" else key)
            if not found:
                return None
            template = self.board.ed.project.places[found[0]]["objects"][found[1]]["template"]
        try:
            from .talking import dialogue_anims
            return dialogue_anims(template)
        except Exception:                               # noqa: BLE001 - no game to look in: every gesture
            return None

    def npc_name(self):
        ref = self.step().get("npc") or ""
        return (ref.split("/")[-1].replace("_", " ") or "NPC").upper()

    def save(self, rebuild=True):
        """Saved; the graph shows it (rebuild: the card is built anew too - else the field typed in stays)."""
        self.board.ed.project.save_meta()
        self.board.remember()                   # an undo step (Ctrl+Z)
        QtCore.QTimer.singleShot(0, self, lambda: self.sync(card=rebuild))

    def _head_row(self, a, title, count):
        """Back on the left, the step's name in the middle (the pencil beside it renames it - its line in the
        journal), the talk's size on the right (Maxim 06.10.)."""
        row = QtWidgets.QWidget()
        g = QtWidgets.QGridLayout(row)
        g.setContentsMargins(0, 0, 0, 0)
        g.setColumnStretch(0, 1)
        g.setColumnStretch(2, 1)
        g.addWidget(tip(theme.back_button(self.back.emit), "dlg.back"), 0, 0, Q.AlignLeft | Q.AlignVCenter)
        mid = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(mid)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(6)
        h.addWidget(title)
        if not self.monologue:
            edit = QtWidgets.QLineEdit(a.get("text") or "")
            edit.setPlaceholderText(title.text())
            edit.setMinimumWidth(320)
            edit.hide()
            pen = _icon("pencil", None, "dlg.rename")

            def start():
                title.hide()
                pen.hide()
                edit.show()
                edit.setFocus()
                edit.selectAll()

            def done():
                if edit.isHidden():
                    return
                text = " ".join(edit.text().split())
                edit.hide()
                if text != (a.get("text") or ""):
                    if text:
                        a["text"] = text
                    else:
                        a.pop("text", None)
                    self.save()
                else:
                    title.show()
                    pen.show()
            pen.clicked.connect(start)
            edit.editingFinished.connect(done)
            h.addWidget(pen)
            h.addWidget(edit)
        g.addWidget(mid, 0, 1, Q.AlignCenter)
        g.addWidget(count, 0, 2, Q.AlignRight | Q.AlignVCenter)
        return row

    # --- the view
    def sync(self, card=True):
        a = self.step()
        lay = self.head.layout() or QtWidgets.QVBoxLayout(self.head)
        while lay.count():
            w = lay.takeAt(0).widget()
            if w:
                w.hide()                # gone at once, not only once Qt deletes it
                w.deleteLater()
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(4)
        if a.get("swap"):
            sw = self._my_swap()
            where = f" - at {a['input'].replace('_', ' ')}" if len((sw or {}).get("inputs") or {}) > 1 else ""
            title = QtWidgets.QLabel(a.get("text") or f"Replacing: {(sw or {}).get('name', 'a game scene')}{where}")
        else:
            title = QtWidgets.QLabel("Monologue" if self.monologue else
                                     a.get("text") or f"Talk to {self.npc_name().lower()}")
        title.setStyleSheet("color:#f0f0f0;font:bold 13px")
        count = QtWidgets.QLabel(D.summary(self.lines()))
        count.setObjectName("note")
        lay.addWidget(self._head_row(a, title, count))
        lay.addWidget(self._people())
        if self.adding is not None:
            lay.addWidget(self._add_person_row())
        if not a.get("swap") and not self.monologue:
            lay.addWidget(self._cameras())
        self.graph.show_flow(F.layout(self.lines(), self._names(), self.player_label(),
                                     lambda who: D.color(who, a), monologue=self.monologue), keep=self._shown)
        if not self._shown:
            QtCore.QTimer.singleShot(0, self, self.graph.home)     # (once it has its size)
        self._shown = True
        ref, row = self._ref_of(self.picked)
        if ref is None:
            self.picked = None
        self.graph.select(ref, row)
        if card and not self._typing_in_card():
            self._card()

    # --- who is in the talk
    def _people(self):
        a = self.step()
        box = QtWidgets.QWidget()
        if a.get("swap"):
            # a game scene's people (a dozen at times): names only, the row wraps
            from .catalog_view import Flow
            h = Flow(box)
            for key, _ref, label in D.speakers(a):
                chip = QtWidgets.QToolButton()
                chip.setText(label.upper())
                chip.setObjectName("speaker")
                _speaker(chip, D.color(key, a))
                chip.setFocusPolicy(Q.NoFocus)
                tip(chip, "dlg.person_scene" if not D.is_player(key) else "dlg.person_player")
                h.addWidget(chip)
            return box
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(4)
        for key, ref, label in D.speakers(a):
            label = self.player_label() if D.is_player(key) else label
            chip = QtWidgets.QToolButton()
            chip.setText(label.upper())
            chip.setObjectName("speaker")
            _speaker(chip, D.color(key, a))
            chip.setFocusPolicy(Q.NoFocus)
            if ref and key != "npc":
                w = next(x for x in a.get("with") or [] if x["who"] == ref)
                chip.setText(f"{label.upper()}  -  {'joins later' if w.get('joins') == 'line' else 'present'}")
                _menu(chip, D.JOINS + [("remove", "Not in dialogue")], w.get("joins", "start"),
                      lambda k, ref=ref: self._person(ref, k))
                tip(chip, "dlg.person")
            else:
                tip(chip, "dlg.person_main" if key == "npc" else "dlg.person_player")
            h.addWidget(chip)
            h.addWidget(self._pose_button(a, key))
        if not self.monologue:                  # (a monologue: only the player)
            h.addWidget(_button("+ character", lambda _c=False: self._toggle_adding(), "dlg.add_person", "plus"))
        h.addStretch(1)
        return box

    # --- the talk's own cameras: taken from the editor camera, looked through, chosen per line (a cut or a move)
    def _cameras(self):
        from .icons import icon
        a = self.step()
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(4)
        for name in a.get("cams") or {}:
            chip = _opt(name, True, "dlg.own_cam")
            chip.setIcon(icon("video"))
            chip.setToolButtonStyle(Q.ToolButtonTextBesideIcon)
            defaults = a.get("cam_defaults") or {}
            mine = [who for who, c in defaults.items() if c == f"cam:{name}"]
            if mine:                            # whose camera it is: on the chip
                chip.setText(f"{name}  ·  {', '.join(self._names().get(w, w) for w in mine)}")
            people = [(f"default:{who}", f"{'Not the' if who in mine else 'The'} camera of {label}")
                      for who, label in self._names().items() if who in (D.PLAYER, "npc")]
            _menu(chip, [("look", "Look through"), ("set", "Set to the view")] + people + [("remove", "Remove")],
                  None, lambda k, name=name: self._own_cam(name, k))
            h.addWidget(chip)
        h.addWidget(_button("+ camera", lambda _c=False: self._add_cam(), "dlg.add_cam", "plus"))
        for name in a.get("marks") or {}:              # spots lines can put people on (Also: goes to)
            chip = _opt(name, True, "dlg.mark")
            chip.setIcon(icon("map-pin"))
            chip.setToolButtonStyle(Q.ToolButtonTextBesideIcon)
            _menu(chip, [("here", "Set to where the player is"), ("thing", "Put a thing here"), ("remove", "Remove")],
                  None, lambda k, name=name: self._mark(name, k))
            h.addWidget(chip)
        for name, p in (a.get("props") or {}).items():   # things on the spots (Also: shows / hides)
            chip = _opt(name, True, "dlg.prop")
            chip.setIcon(icon("package"))
            chip.setToolButtonStyle(Q.ToolButtonTextBesideIcon)
            _menu(chip, [(f"on:{m}", ("On " if m != p.get("mark") else "Is on ") + m) for m in a.get("marks") or {}] +
                  [("remove", "Remove")], None, lambda k, name=name: self._prop(name, k))
            h.addWidget(chip)
        h.addWidget(_button("+ spot", lambda _c=False: self._mark(None, "here"), "dlg.add_mark", "plus"))
        h.addStretch(1)
        spot = (a.get("spots") or {}).get("player")      # where the player stands in the talk
        stand = _opt(f"{self.player_label()}: {'own spot' if spot else 'in front'}", bool(spot), "dlg.player_spot")
        stand.setIcon(icon("map-pin"))
        stand.setToolButtonStyle(Q.ToolButtonTextBesideIcon)
        _menu(stand, [("here", "Stands where the player is now"), ("front", "Stands in front of them")], None,
              lambda k: self._player_spot(k))
        h.addWidget(stand)
        return box

    def _preview_move(self, x, seconds=None):
        """The line's camera move played with the editor camera: from its first camera to its second, eased in and
        out as the scene does, as long as the line lasts (about)."""
        cams = self.step().get("cams") or {}
        a, b = cams.get(str(x.get("glide"))[4:]), cams.get(str(x.get("camera"))[4:])
        if not a or not b:
            return
        seconds = seconds or max(2.0, float(x.get("dur") or 0) or len(x.get("text", "")) * 0.08)
        t0 = time.time()
        ed = self.board.ed

        def frame():
            t = min(1.0, (time.time() - t0) / seconds)
            e = t * t * (3 - 2 * t)                 # smooth: slow at both ends
            p = [a["pos"][k] + (b["pos"][k] - a["pos"][k]) * e for k in range(3)]
            dy = ((b["yaw"] - a["yaw"] + 180) % 360) - 180      # the short way round
            yaw = (a["yaw"] + dy * e) % 360
            pitch = a["pitch"] + (b["pitch"] - a["pitch"]) * e
            ed.link.exec(f"cj_cam_set({p[0]:.3f}, {p[1]:.3f}, {p[2]:.3f}, {yaw:.2f}, {pitch:.2f})")
            if t < 1.0:
                QtCore.QTimer.singleShot(33, frame)
        frame()

    def _player_spot(self, k):
        a = self.step()
        if k == "front":
            (a.get("spots") or {}).pop("player", None)
            if not a.get("spots"):
                a.pop("spots", None)
            self.save()
            return
        ed = self.board.ed
        ed.last_where = None
        ed.link.exec("cj_where()")
        t0 = time.time()

        def wait():                             # the game's answer comes on the link (a moment)
            if ed.last_where is None and time.time() - t0 < 3:
                QtCore.QTimer.singleShot(100, wait)
                return
            if ed.last_where is None:
                ed.panel.notice.say("Player position unknown (the game did not answer)", error=True)
                return
            a.setdefault("spots", {})["player"] = {"pos": [round(v, 3) for v in ed.last_where],
                                                   "yaw": round(float(ed.last_heading or 0.0) % 360, 1)}
            self.save()
        wait()

    def _mark(self, name, k):
        """A spot of the talk (a new one: None) set to where the player stands now, or removed."""
        a = self.step()
        marks = a.setdefault("marks", {})
        if k == "thing":
            self.board.choose("props", lambda path, name=name: self._prop(None, "add", path, name))
            return
        if k == "remove":
            marks.pop(name, None)
            if not marks:
                a.pop("marks", None)
            for t, p in list((a.get("props") or {}).items()):
                if p.get("mark") == name:
                    self._prop(t, "remove", save=False)
            for x in D.walk(D.from_step(a)):
                if x.get("goto") == name:
                    x.pop("goto")
            self.save()
            return
        if name is None:
            n = 1
            while f"Spot {n}" in marks:
                n += 1
            name = f"Spot {n}"
        ed = self.board.ed
        ed.last_where = None
        ed.link.exec("cj_where()")
        t0 = time.time()

        def wait():
            if ed.last_where is None and time.time() - t0 < 3:
                QtCore.QTimer.singleShot(100, wait)
                return
            if ed.last_where is None:
                ed.panel.notice.say("Player position unknown (the game did not answer)", error=True)
                return
            marks[name] = {"pos": [round(v, 3) for v in ed.last_where],
                           "yaw": round(float(ed.last_heading or 0.0) % 360, 1)}
            self.save()
        wait()

    def _prop(self, name, k, template=None, mark=None, save=True):
        """A thing of the talk: added (from the catalog) on a spot, moved to another spot, or removed (and out of
        the lines that show / hide it)."""
        a = self.step()
        props = a.setdefault("props", {})
        if k == "add":
            self.board.close_chooser()
            base = template.rsplit("\\", 1)[-1].rsplit(".", 1)[0].replace("_", " ")
            name, n = base, 1
            while name in props:
                n += 1
                name = f"{base} {n}"
            props[name] = {"template": template, "mark": mark}
        elif k.startswith("on:"):
            props[name]["mark"] = k[3:]
        elif k == "remove":
            props.pop(name, None)
            for x in D.walk(D.from_step(a)):
                for key in ("show", "hide"):
                    if name in (x.get(key) or []):
                        x[key] = [t for t in x[key] if t != name]
                        if not x[key]:
                            x.pop(key)
        if not props:
            a.pop("props", None)
        if save:
            self.save()

    def _view(self):
        """The editor camera now ({pos, yaw, pitch, fov}), or None (the editor is not flying)."""
        cam = getattr(self.board.ed, "cam", None)
        if cam is None or not cam.ready:
            panel = getattr(self.board.ed, "panel", None)
            if panel is not None and hasattr(panel, "notice"):
                panel.notice.say("No camera yet. Press F8 and fly to the camera's spot", error=True)
            return None
        return {"pos": [round(v, 3) for v in cam.pos], "yaw": round(cam.yaw % 360, 2),
                "pitch": round(cam.pitch, 2), "fov": round(cam.fov, 1)}

    def _add_cam(self):
        view = self._view()
        if view is None:
            return
        a = self.step()
        cams = a.setdefault("cams", {})
        n = len(cams) + 1
        while f"Cam {n}" in cams:
            n += 1
        cams[f"Cam {n}"] = view
        self.save()

    def _own_cam(self, name, k):
        a = self.step()
        c = (a.get("cams") or {}).get(name)
        if c is None:
            return
        if k.startswith("default:"):            # this camera for every line of theirs (the player's: choices too)
            who = k[8:]
            defaults = a.setdefault("cam_defaults", {})
            if defaults.get(who) == f"cam:{name}":
                defaults.pop(who)
            else:
                defaults[who] = f"cam:{name}"
            if not defaults:
                a.pop("cam_defaults")
            self.save()
            return
        if k == "look":
            self.board.ed.link.exec(f"cj_cam_set({c['pos'][0]}, {c['pos'][1]}, {c['pos'][2]}, {c['yaw']}, "
                                    f"{c['pitch']})")
            return
        if k == "set":
            view = self._view()
            if view is None:
                return
            a["cams"][name] = view
        elif k == "remove":
            a["cams"].pop(name)
            if not a["cams"]:
                a.pop("cams")
            for x in D.walk(self.lines()):         # the lines that used it: their default camera again
                for f in ("camera", "glide"):
                    if x.get(f) == f"cam:{name}":
                        x.pop(f)
            defaults = a.get("cam_defaults") or {}
            for who in [w for w, c in defaults.items() if c == f"cam:{name}"]:
                defaults.pop(who)
            if "cam_defaults" in a and not defaults:
                a.pop("cam_defaults")
        self.save()

    def _pose_button(self, a, key):
        """How this person stands, sits, kneels through the whole talk (the step's 'poses')."""
        p = (a.get("poses") or {}).get(key)
        b = _opt(D.POSE[p] if p in D.POSE else "Pose", p in D.POSE, "dlg.pose_start")
        have = self.body_of(key)
        if have == set():                       # an animal, a monster: no poses
            b.hide()
        _menu(b, lambda key=key, have=have: [(None, "As they are")] + D.poses_for(have), p,
              lambda k2, key=key: self._set_pose(key, k2))
        return b

    def _set_pose(self, key, pose):
        a = self.step()
        poses = dict(a.get("poses") or {})
        if pose:
            poses[key] = pose
        else:
            poses.pop(key, None)
        if poses:
            a["poses"] = poses
        else:
            a.pop("poses", None)
        self.save()

    def _add_person_row(self):
        """Pick (click them in the world) / Create (the catalog) / the people you placed."""
        from .quest import is_actor
        box = QtWidgets.QFrame()
        box.setObjectName("choice")
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(6, 4, 6, 4)
        v.setSpacing(2)
        v.addWidget(_hbox(_button("Pick", lambda _c=False: self._request_person("pick"), "qb.pick_people"),
                          _button("Create", lambda _c=False: self._request_person("create"), "qb.create_people"),
                          None, _icon("x", lambda _c=False: self._toggle_adding(), "qb.cancel")))
        taken = {ref for _k, ref, _l in D.speakers(self.step()) if ref}
        for place, p in sorted(self.board.ed.project.places.items()):
            for k, o in enumerate(p.get("objects", [])):
                if not is_actor(o):
                    continue
                ref = f"{place}/{o['id']}" if o.get("id") else None
                if ref in taken:
                    continue
                name = (o.get("id") or o["template"].rsplit("\\", 1)[-1].rsplit(".", 1)[0]).replace("_", " ")
                entry = QtWidgets.QPushButton(f"{name}    {place}")
                entry.setObjectName("entry")
                entry.setStyleSheet(ENTRY)
                entry.setFocusPolicy(Q.NoFocus)
                entry.clicked.connect(lambda _c=False, w=(place, k): self._add_person(*w))
                tip(entry, "dlg.add_this_person")
                v.addWidget(entry)
        return box

    def _toggle_adding(self):
        self.adding = None if self.adding is not None else True
        self.sync()

    def _request_person(self, how):
        if how == "create":
            self.board.choose("people", lambda path: self.board.ed.request_object(
                "create", "people", self._add_person, template=path))
        else:
            self.board.ed.request_object(how, "people", self._add_person)

    def _add_person(self, place, index):
        oid = self.board.ed.project.name_object(place, index)
        ref = f"{place}/{oid}"
        a = self.step()
        if ref != a.get("npc") and all(w["who"] != ref for w in a.get("with") or []):
            a.setdefault("with", []).append({"who": ref, "joins": "start"})
        self.adding = None
        self.save()

    def _person(self, ref, k):
        a = self.step()
        if k == "remove":
            a["with"] = [w for w in a.get("with") or [] if w["who"] != ref]
            if not a["with"]:
                a.pop("with")
            if ref in (a.get("poses") or {}):
                self._set_pose(ref, None)
            for x in D.walk(self.lines()):
                if x.get("who") == ref:
                    x["who"] = "npc"             # their lines go to the one the step talks to
                if x.get("look") == ref:
                    x.pop("look")
        else:
            for w in a.get("with") or []:
                if w["who"] == ref:
                    w["joins"] = k
        self.save()

    # --- a line
    def _line_card(self, ls, k):
        x = ls[k]
        a = self.step()
        key = x.get("who") or "npc"
        colour = D.color(key, a)
        card = Hover()
        card.setObjectName("line")
        _speaker(card, colour)
        v = QtWidgets.QVBoxLayout(card)
        v.setContentsMargins(6, 4, 6, 3)
        v.setSpacing(2)
        names = self._names()
        who = QtWidgets.QToolButton()
        who.setText(names.get(key, D._label(key)).upper())
        who.setObjectName("speaker")
        _speaker(who, colour)
        who.setFocusPolicy(Q.NoFocus)
        _menu(who, list(names.items()), D.PLAYER if D.is_player(key) else key, lambda k2, x=x: self._set(x, "who", k2))
        tip(who, "dlg.who")
        text = AutoText(x.get("text", ""), "what they say")
        text.done.connect(lambda t, x=x: self._set_text(x, t))
        text.enter.connect(lambda t, ls=ls, x=x: self._next_line(ls, x, t))
        if self.focus_line is x:
            self.focus_line = None
            # the keys into it, and the card scrolled so it is in sight (07.10.: Enter's new line below the window)
            QtCore.QTimer.singleShot(0, lambda t=text: (self._type_into(t), self._scroll_to(t)))
        tip(text, "dlg.text")
        top = _hbox(who, text, stretch=1)
        top.layout().setAlignment(who, Q.AlignTop)
        v.addWidget(top)
        # variants: one of them is said, at random
        for j, alt in enumerate(x.get("alt") or []):
            orl = QtWidgets.QLabel("or")
            orl.setStyleSheet("color:#8a8a8a;font:11px")
            orl.setFixedWidth(who.sizeHint().width())
            orl.setAlignment(Q.AlignRight | Q.AlignTop)
            at = AutoText(str(alt), "Variant")
            at.done.connect(lambda t, x=x, j=j: self._set_alt(x, j, t))
            tip(at, "dlg.variant")
            rm = _icon("trash-2", lambda _c=False, x=x, j=j: self._remove_alt(x, j), "dlg.remove")
            v.addWidget(_hbox(orl, at, rm, stretch=1))
        # voice, gesture, mood; moving and removing only while the mouse is on the line
        if x.get("voice") or x.get("voice_pack"):
            what = "game line" if x.get("voice") else x["voice_pack"].split("/")[0].replace("_", " ")
            voice = _opt(f"{what}, {float(x.get('dur') or 0):.1f} s", True, "dlg.voice_set")
            _voice_icon(voice, True)
            _menu(voice, [("play", "Play"), ("find", "Find another"), ("none", "No voice")], None,
                  lambda k2, x=x: self._voice_menu(x, k2))
        else:
            voice = _opt("", False, "dlg.voice")
            _voice_icon(voice, False)
            voice.setPopupMode(QtWidgets.QToolButton.DelayedPopup)
            voice.clicked.connect(lambda _c=False, x=x: self._open_voice(x))
        thought = None
        if D.is_player(x.get("who")):          # the player's line: said aloud, or only thought (no mouth, no voice)
            thought = _toggle_icon("message-circle-dashed" if x.get("thought") else "message-circle",
                                   bool(x.get("thought")), "dlg.thought")
            thought.clicked.connect(lambda _c=False, x=x: self._set(x, "thought", None if x.get("thought") else True))
        g = x.get("gesture")
        have = self.body_of(key)                # only what this speaker's body has (else a T-pose in the game)
        label = f"Gesture: {D.anim_label(x['anim'])}" if x.get("anim") else \
            f"Gesture: {D.GESTURE[g][0]}" if g in D.GESTURE else "Gesture"
        if have is not None and ((g in D.GESTURE and not D.gesture_anim(g, have)) or
                                 (x.get("anim") and x["anim"] not in have)):
            label += " (not for them)"
        gesture = _opt(label[:60], bool(x.get("anim")) or g in D.GESTURE, "dlg.gesture")
        _menu(gesture, [(None, "None")] + D.gestures_for(have) +
              [("__find", f"Find another ... ({len(D.all_animations()) if have is None else len(have)})")], g,
              lambda k2, x=x: self._gesture(x, k2))
        own = [(f"cam:{n}", n) for n in a.get("cams") or {}]     # the talk's own cameras
        shots = dict(D.SHOTS + own)
        cv = x.get("camera")
        cam = _opt(f"Camera: {shots[cv]}" if cv and cv in shots else "Camera", bool(cv), "dlg.camera")
        _menu(cam, D.SHOTS + own, cv or "", lambda k2, x=x: self._set(x, "camera", k2 or None))
        glide = None
        if cv:                                  # a cut to it, or a move from another camera through the line
            gv = x.get("glide")
            glide = _opt(f"Moves from {shots[gv]}" if gv and gv in shots else "Cut", bool(gv), "dlg.glide")
            _menu(glide, [(None, "Cut")] + [(k2, label) for k2, label in D.SHOTS + own if k2 and k2 != cv], gv,
                  lambda k2, x=x: self._set(x, "glide", k2))
            if str(gv).startswith("cam:") and str(cv).startswith("cam:"):     # two own cameras: seen in the world
                preview = _icon("play", lambda _c=False, x=x: self._preview_move(x), "dlg.preview_move")
                glide = _hbox(glide, preview)
        m = x.get("mood")
        mood = _opt(f"Mood: {D.MOOD[m]}" if m in D.MOOD else "Mood", m in D.MOOD, "dlg.mood")
        _menu(mood, [(None, "None")] + D.MOODS, m, lambda k2, x=x: self._set(x, "mood", k2))
        po = x.get("pose")
        pose = _opt(f"Pose: {D.POSE[po]}" if po in D.POSE else "Pose", po in D.POSE, "dlg.pose")
        _menu(pose, [(None, "Keeps their pose")] + D.poses_for(have), po,
              lambda k2, x=x: self._set(x, "pose", k2))
        lk = x.get("look")
        look = _opt(f"Looks at {names[lk]}" if lk in names else "Looks at", lk in names, "dlg.look")
        _menu(look, lambda key=key: [(None, "Nobody in particular")] +
              [(k2, label) for k2, label in self._names().items() if k2 != key], lk,
              lambda k2, x=x: self._set(x, "look", k2))
        if have == set():                       # an animal, a monster: no dialogue gestures, no face
            gesture.hide()
            mood.hide()
            pose.hide()
        tools = [_button("+ variant", lambda _c=False, x=x: self._add_alt(x), "dlg.add_variant"),
                 _icon("trash-2", lambda _c=False: self._remove(ls, k), "dlg.remove")]
        card.tools = tools
        spacer = QtWidgets.QWidget()
        spacer.setFixedWidth(who.sizeHint().width())
        v.addWidget(_hbox(spacer, voice, *([thought] if thought is not None else []), gesture, mood, cam,
                          *([glide] if glide is not None else []), None, *tools))
        spacer2 = QtWidgets.QWidget()
        spacer2.setFixedWidth(who.sizeHint().width())
        length = length_field(x, lambda v, x=x: self._set(x, "length", v))
        text.done.connect(lambda _t, f=length: f.refresh())     # the lip sync of the text as it is now (07.10.)
        text.enter.connect(lambda _t, f=length: f.refresh())
        v.addWidget(_hbox(spacer2, pose, look, self._also_button(x), length, None))
        for key2, hint in (("sound", "sound event, e.g. gui_bribe"), ("hold", "item in the hand, e.g. Meat_04"),
                           ("appearance", "appearance name")):
            if key2 in x and (key2 != "hold" or x[key2] != ""):
                f = AutoText(str(x.get(key2) or ""), hint)
                f.done.connect(lambda t, x=x, key2=key2: self._set(x, key2, t.strip()))
                tip(f, f"dlg.also_{key2}")
                lab = QtWidgets.QLabel({"sound": "sound", "hold": "holds", "appearance": "look"}[key2])
                lab.setStyleSheet("color:#8a8a8a;font:11px")
                lab.setFixedWidth(who.sizeHint().width())
                lab.setAlignment(Q.AlignRight | Q.AlignVCenter)
                v.addWidget(_hbox(lab, f, stretch=1))
        return card

    ALSO = [("sound", "A sound"), ("hold", "Holds a thing"), ("sword:steel", "Draws the steel sword"),
            ("sword:silver", "Draws the silver sword"), ("hold:", "Puts it away"), ("appearance", "Another look"),
            ("fade:out", "Screen goes black at the end"), ("fade:in", "Screen comes back at the start")]

    def _also_button(self, x):
        """What else happens with the line (sound, hand, sword, look, fade) - each picked once more takes it out."""
        on = [label for k, label in self.ALSO if self._also_on(x, k)] + \
            ([f"goes to {x['goto']}"] if x.get("goto") else []) + \
            [f"{s}s {t}" for s in ("show", "hide") for t in x.get(s) or []]
        b = _opt(("Extras: " + ", ".join(on))[:60] if on else "Extras", bool(on), "dlg.also")
        _menu(b, lambda x=x: [(k, ("Remove: " if self._also_on(x, k) else "") + label) for k, label in self.ALSO] +
              [(f"goto:{m}", ("Remove: " if x.get("goto") == m else "") + f"Goes to {m}")
               for m in self.step().get("marks") or {}] +
              [(f"{s}:{t}", ("Remove: " if t in (x.get(s) or []) else "") + f"{s.capitalize()}s {t}")
               for t in self.step().get("props") or {} for s in ("show", "hide")],
              None, lambda k, x=x: self._also(x, k))
        return b

    @staticmethod
    def _also_on(x, k):
        key, _, val = k.partition(":")
        if key == "hold" and val == "" and k.endswith(":"):
            return x.get("hold") == ""
        if val:
            return x.get(key) == val
        return key in x and (key != "hold" or x[key] != "")

    def _also(self, x, k):
        key, _, val = k.partition(":")
        if key in ("show", "hide"):                     # the talk's things: a list each, one or the other
            other = "hide" if key == "show" else "show"
            if val in (x.get(key) or []):
                x[key] = [t for t in x[key] if t != val]
            else:
                x[key] = (x.get(key) or []) + [val]
                x[other] = [t for t in x.get(other) or [] if t != val]
            for s in (key, other):
                if s in x and not x[s]:
                    x.pop(s)
            self.save()
            return
        if self._also_on(x, k):
            x.pop(key, None)
        elif k.endswith(":") or val:
            if key == "sword" or (key == "hold" and k.endswith(":")):
                x.pop("sword", None)
                x.pop("hold", None)
            x[key] = val
        else:
            if key == "hold":
                x.pop("sword", None)
            x[key] = x.get(key) or ""
            if key == "hold":
                x[key] = "Meat_04"      # (a start: the field below takes the right one)
        self.save()

    # --- the cards: the one of the node picked in the graph
    def _card(self):
        """The card of what is picked in the graph: a line's (who, words, voice, gesture, mood), a choice's (its
        answers, how each ends), an If's, a script's. Nothing picked: no card, the graph has the room."""
        pos = self.scroll.verticalScrollBar().value()
        body = QtWidgets.QWidget()
        col = QtWidgets.QVBoxLayout(body)
        col.setContentsMargins(0, 6, 6, 4)
        col.setSpacing(4)
        at = self._locate(self.picked) if self.picked is not None else None
        if at is not None and len(at) == 3:     # an answer: its choice's card
            col.addWidget(self._choice_card(at[0], at[1]))
        elif at is not None:
            ls, k = at
            x = ls[k]
            if "choice" in x:
                col.addWidget(self._choice_card(ls, k))
            elif "if" in x:
                col.addWidget(self._if_card(ls, k))
            elif "random" in x:
                col.addWidget(self._random_card(ls, k))
            elif "script" in x:
                col.addWidget(self._script_row(ls, k))
            else:                               # a line: every line of its block, one after the other
                first, last = k, k
                while first > 0 and "who" in ls[first - 1]:
                    first -= 1
                while last + 1 < len(ls) and "who" in ls[last + 1]:
                    last += 1
                for j in range(first, last + 1):
                    col.addWidget(self._line_card(ls, j))
                    if self.voice_open is ls[j]:
                        col.addWidget(self._voice_search(ls[j]))
                    if self.anim_open is ls[j]:
                        col.addWidget(self._anim_search(ls[j]))
                col.addWidget(_hbox(_button("+ line", lambda _c=False, ls=ls, i=last + 1: self._place_line(ls, i),
                                            "dlg.add_line", "plus"), None))
        col.addStretch(1)
        self.scroll.setWidget(body)
        self.scroll.setVisible(at is not None)
        QtCore.QTimer.singleShot(0, self, lambda: self._share())
        QtCore.QTimer.singleShot(0, self, lambda: self.scroll.verticalScrollBar().setValue(pos))

    def _place_line(self, ls, i):
        new = {"who": self._next_speaker(ls, i), "text": ""}
        ls.insert(i, new)
        self.picked = self.focus_line = new
        self.save()

    def _share(self):
        total = sum(self.split.sizes()) or self.split.height()
        if total > 0 and self.scroll.isVisible():
            top = int(total * self.split_frac)
            if abs(self.split.sizes()[0] - top) > 1:
                self.split.setSizes([top, total - top])

    def _split_moved(self, _pos, _index):
        sizes = self.split.sizes()
        if sum(sizes) > 0:
            self.split_frac = min(0.9, max(0.15, sizes[0] / sum(sizes)))

    def _typing_in_card(self):
        """Is a field of the card typed in? Then the card stays (the graph is built anew around it)."""
        import shiboken6
        t = getattr(getattr(self.board.ed, "typing", None), "target", None)
        return t is not None and shiboken6.isValid(t) and self.scroll.isAncestorOf(t)

    def _choice_card(self, ls, k):
        x = ls[k]
        answers = x["choice"]
        box = QtWidgets.QFrame()
        box.setObjectName("choice")
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(6, 5, 6, 6)
        v.setSpacing(3)
        label = QtWidgets.QLabel("CHOICE")
        label.setStyleSheet(f"color:{CHOICE};font:bold 11px")
        t = x.get("time")
        timed = _opt(f"{t:g} s to choose" if t else "no time limit", bool(t), "dlg.timed")
        _menu(timed, [(None, "no time limit"), (3, "3 seconds"), (5, "5 seconds"), (8, "8 seconds"),
                      (12, "12 seconds")], t, lambda v_, x=x: self._set(x, "time", v_))
        v.addWidget(_hbox(label, timed, None, _icon("trash-2", lambda _c=False: self._remove(ls, k),
                                                      "dlg.remove_choice")))
        nested = self._owner(ls) is not None
        for j, c in enumerate(answers):
            v.addWidget(self._answer_row(answers, j))
            v.addWidget(self._answer_end(c, nested))
        v.addWidget(_hbox(_button("+ option", lambda _c=False: self._add_answer(answers), "dlg.add_answer", "plus"),
                          None))
        return box

    def answer_ends(self, nested):
        """What an answer does after its lines (the menu on its card)."""
        return [("on", "Continue dialogue"), ("back", "Back to choice")] + \
            ([("up", "Back to previous choice")] if nested else []) + \
            [("continue", "End: continue quest"), ("retry", "End: repeatable"),
             ("fail", "End: fail quest")]

    def _answer_end(self, c, nested):
        """Under an answer: how it ends (and what it does and needs, when set)."""
        e = str(c.get("end") or "continue")
        if self.step().get("swap"):
            end = self._swap_end(c, e)
        else:
            entries = self.answer_ends(nested)
            now = F.kind(e)
            end = _opt(dict(entries).get(now, now), True, "dlg.end")
            end.setStyleSheet(f"QToolButton{{color:{F.COLOUR.get(now, '#bbb')};background:transparent;"
                              "border:1px solid #444;padding:1px 8px;font:11px}QToolButton:hover{border-color:#999}"
                              "QToolButton::menu-indicator{image:none;width:0}")
            # (an answer that goes on into a path keeps it: where it goes on is the quest graph's wire)
            _menu(end, entries, now, lambda k2, c=c: None if k2 == "continue" and str(
                c.get("end", "")).startswith("path:") else self._set_end(c, k2))
        pad = QtWidgets.QWidget()
        pad.setFixedWidth(26)
        extras = self._answer_extras(c)
        conds = self._condition_chips(c)
        return _hbox(pad, end, *conds, *([extras] if extras is not None else []), None)

    # --- conditions: when an option shows (all of them must hold)
    def _options_before(self):
        """[(option dict, label)] of the options of the talks the quest has before this one (its node's ancestors in
        the graph) - 'After option' can ask for any of them."""
        q = self.board.quest()
        me = self.step()
        nodes, links = q.get("nodes") or {}, q.get("links") or []

        def holds(st):
            kind, a = next(iter(st.items())) if st else (None, {})
            return a is me or any(cl is me for cl in (a.get("clues") or []) if isinstance(a, dict))
        mine = next((nid for nid, n in nodes.items() if holds(n.get("step") or {})), None)
        before, todo = set(), [mine] if mine else []
        while todo:
            nid = todo.pop()
            for src, _port, dst in links:
                if dst == nid and src not in before:
                    before.add(src)
                    todo.append(src)
        out = []
        for nid in before:
            st = (nodes.get(nid) or {}).get("step") or {}
            if not st:
                continue
            kind, a = next(iter(st.items()))
            talks = [(a.get("text") or "Talk", a)] if kind == "talk" else \
                [(f"Monologue {k + 1}", cl) for k, cl in enumerate(a.get("clues") or []) if cl.get("dialogue")] \
                if kind == "clues" else []
            for title, holder in talks:
                for o in D.walk(D.from_step(holder) if holder.get("dialogue") is None else holder["dialogue"]):
                    if "who" not in o and o.get("text"):
                        out.append((o, f"{title}: {o['text']}"))
        return out

    def _condition_entries(self, c, answers):
        """What '+' can add: after all others, after an option (this talk's, earlier talks'), after a branch, the
        player has an item."""
        from .quest_nodes import path_fact
        have = D.conditions(c)
        out = []
        if len(answers) > 1 and D.AFTER_ALL not in have:
            out.append((D.AFTER_ALL, "After all other options"))
        mine = [o for o in D.walk(self.lines()) if "who" not in o and o is not c and o.get("text")]
        self._cond_options = {}
        for k, (o, label) in enumerate([(o, f"This dialogue: {o['text']}") for o in mine] + self._options_before()):
            key = "@" + o["id"] if o.get("id") else f"@#{k}"
            self._cond_options[key] = o
            if key not in have:
                out.append((key, f"After option - {label}"[:80]))
        qid = self.board.ed.project.id
        out += [(path_fact(qid, pid), f"After branch: {p.get('label') or pid}") for pid, p in self.board.paths().items()
                if path_fact(qid, pid) not in have]
        if not isinstance(c.get("needs"), dict):
            out.append(("__needs", "Player has an item..."))
        return out

    def _add_condition(self, c, key, answers=()):
        if key == "__needs":
            c["needs"] = {"item": "", "count": 1, "money": 0}
            self.save()
            return
        if key.startswith("@#"):                # an option without an id yet: it gets one now
            import uuid
            o = self._cond_options[key]
            o["id"] = o.get("id") or uuid.uuid4().hex[:8]
            key = "@" + o["id"]
        D.set_conditions(c, D.conditions(c) + [key])
        self.save()

    def _remove_condition(self, c, k):
        conds = D.conditions(c)
        conds.pop(k)
        D.set_conditions(c, conds)
        self.save()

    def _condition_label(self, cond):
        if cond == D.AFTER_ALL:
            return "After all other options"
        if isinstance(cond, str) and cond.startswith("@"):
            o = next((o for o, _l in self._options_before() if o.get("id") == cond[1:]), None) or next(
                (o for o in D.walk(self.lines()) if "who" not in o and o.get("id") == cond[1:]), None)
            return f"After option: {o.get('text') if o else cond[1:]}"[:60]
        if isinstance(cond, str):
            p = next((p for pid, p in self.board.paths().items() if cond.endswith("_path_" + pid)), None)
            return f"After branch: {(p or {}).get('label') or cond}"[:60]
        return f"If {str(cond[0]).replace('_', ' ')} {cond[1]} {cond[2]}"[:60]

    def _condition_chips(self, c):
        """The option's conditions as chips, each with its trash can (the 'Player has' item row stays in extras)."""
        out = []
        for k, cond in enumerate(D.conditions(c)):
            chip = QtWidgets.QLabel(self._condition_label(cond))
            chip.setStyleSheet("color:#9fb0ff;font:11px;border:1px solid #444;border-radius:0;padding:1px 6px")
            tip(chip, "dlg.only_if")
            out += [chip, _icon("trash-2", lambda _c=False, c=c, k=k: self._remove_condition(c, k), "dlg.remove")]
        return out

    def _if_card(self, ls, k):
        """Lines that depend on a fact: 'if <fact> is at least <n>' - then one way, otherwise the other; each way
        ends like an answer (or goes on as the lines around it would)."""
        x = ls[k]
        c = x.setdefault("if", {"fact": "", "op": ">=", "value": 1})
        box = QtWidgets.QFrame()
        box.setObjectName("choice")
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(6, 5, 6, 6)
        v.setSpacing(4)
        label = QtWidgets.QLabel("IF")
        label.setStyleSheet(f"color:{IF};font:bold 11px")
        fact = QtWidgets.QLineEdit(str(c.get("fact", "")))
        fact.setPlaceholderText("A fact (a decision, a moment of a quest)")
        fact.editingFinished.connect(lambda c=c, w=fact: self._set(c, "fact", _fact_typed(w), rebuild=False))
        tip(fact, "dlg.if_fact")
        op = _opt(dict(self.IF_OPS).get(c.get("op", ">="), "at least"), True, "dlg.if_op")
        _menu(op, self.IF_OPS, c.get("op", ">="), lambda v_, c=c: self._set(c, "op", v_))
        value = QtWidgets.QSpinBox()
        value.setRange(0, 999)
        value.setValue(int(c.get("value", 1)))
        value.editingFinished.connect(lambda c=c, w=value: self._set(c, "value", w.value(), rebuild=False))
        tip(value, "dlg.if_value")
        v.addWidget(_hbox(label, fact, op, value, _icon("trash-2", lambda _c=False: self._remove(ls, k),
                                                           "dlg.remove_if"), stretch=1))
        for side, title in (("then", "THEN"), ("else", "OTHERWISE")):
            lab = QtWidgets.QLabel(title)
            lab.setStyleSheet("color:#bbb;font:bold 11px")
            lab.setFixedWidth(80)
            v.addWidget(_hbox(lab, self._branch_end(x.setdefault(side, {})), None))
        return box

    def _random_card(self, ls, k):
        """One of these ways, at random (loaded from a game scene): each way's end."""
        box = QtWidgets.QFrame()
        box.setObjectName("choice")
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(6, 5, 6, 6)
        v.setSpacing(4)
        label = QtWidgets.QLabel("ONE OF THESE, AT RANDOM")
        label.setStyleSheet(f"color:{IF};font:bold 11px")
        v.addWidget(_hbox(label, None, _icon("trash-2", lambda _c=False: self._remove(ls, k), "dlg.remove_random")))
        for j, br in enumerate(ls[k]["random"] or []):
            lab = QtWidgets.QLabel(f"OUTCOME {j + 1}")
            lab.setStyleSheet("color:#bbb;font:bold 11px")
            lab.setFixedWidth(80)
            v.addWidget(_hbox(lab, self._branch_end(br), None))
        return box

    def _script_row(self, ls, k):
        """A script the scene runs here (loaded from the game's scene): what it calls, with what; Remove."""
        s = ls[k]["script"] or {}
        args = ", ".join(f"{n}={str(v).replace('cname_', '')}" for d in s.get("parameter") or [] for n, v in d.items())
        lab = QtWidgets.QLabel(f"Does: {s.get('function', '?')}({args})")
        lab.setStyleSheet("color:#9fb0ff;font:12px")
        tip(lab, "dlg.script")
        return _hbox(lab, _icon("trash-2", lambda _c=False: self._remove(ls, k), "dlg.remove"), stretch=0)

    IF_OPS = [(">=", "at least"), ("=", "is"), ("<", "less than"), ("!=", "is not")]

    def _branch_end(self, br):
        """Where a way of an If goes when its lines are over: on as around it, or like an answer's end."""
        e = br.get("end")
        if self.step().get("swap"):
            sw = self._my_swap()
            entries = [(None, "Continue"), ("back", "Back to choice")] + \
                [(f"out:{o}", f"Continue at {o.replace('_', ' ')}") for o in sw["outline"]["outputs"] or []]
        else:
            entries = [(None, "Continue")] + D.ENDS
        label = dict(entries).get(e, e) if e else "Continue"
        end = _opt(label, True, "dlg.end")
        end.setStyleSheet("QToolButton{color:#bbb;background:transparent;border:1px solid #444;padding:1px 8px;"
                          "font:11px}QToolButton:hover{border-color:#999}QToolButton::menu-indicator{image:none;width:0}")
        _menu(end, entries, e, lambda k2, br=br: self._set(br, "end", k2))
        return end

    def _add_if(self, ls):
        ls.append({"if": {"fact": "", "op": ">=", "value": 1}, "then": {"lines": []}, "else": {"lines": []}})
        self.save()

    def _my_swap(self):
        """The replaced game scene this talk belongs to."""
        return next((s for s in self.board.swaps().values()
                     if any(i.get("talk") is self.step() for i in (s.get("inputs") or {}).values())), None)

    def _swap_end(self, c, e):
        """In a game scene replaced: an answer goes back to the choices or on at one of the scene's exits."""
        sw = self._my_swap()
        outs = sw["outline"]["outputs"] or ["Output"]
        if e == "back":
            label = "Back to choice"
        else:
            out = e[4:] if e.startswith("out:") else (self.step().get("then") or outs[0])
            label = f"Continue at {out.replace('_', ' ')}" if len(outs) > 1 else "Continue"
        end = _opt(label, True, "dlg.end")
        end.setStyleSheet("QToolButton{color:#9fd38a;background:transparent;border:1px solid #444;padding:1px 8px;"
                          "font:11px}QToolButton:hover{border-color:#999}QToolButton::menu-indicator{image:none;width:0}")
        _menu(end, [("back", "Back to choice")] + [(f"out:{o}", f"Continue at {o.replace('_', ' ')}")
                                                         for o in outs], e, lambda k2, c=c: self._set_end(c, k2))
        return end

    def _answer_row(self, answers, j):
        c = answers[j]
        row = Hover()
        row.setObjectName("answer")
        h = QtWidgets.QHBoxLayout(row)          # its look: STYLE's QFrame#answer
        h.setContentsMargins(4, 3, 4, 3)
        h.setSpacing(4)
        num = QtWidgets.QLabel(str(j + 1))
        num.setStyleSheet(f"color:{D.GERALT_COLOR};font:bold 12px;min-width:18px")
        num.setAlignment(Q.AlignCenter)
        text = QtWidgets.QLineEdit(c.get("text", ""))
        text.setPlaceholderText("Option text")
        text.editingFinished.connect(lambda c=c, t=text: self._set(c, "text", t.text().strip(), rebuild=False))
        tip(text, "dlg.answer")
        once = _toggle_icon("repeat-1", bool(c.get("once")), "dlg.once")
        once.clicked.connect(lambda _c=False, c=c: self._set(c, "once", None if c.get("once") else True))
        add_cond = _icon("plus", None, "dlg.add_condition")
        _menu(add_cond, lambda c=c, answers=answers: self._condition_entries(c, answers), None,
              lambda f, c=c, answers=answers: self._add_condition(c, f, answers))
        tools = [_icon("chevron-up", lambda _c=False: self._move(answers, j, -1), "pan.up"),
                 _icon("chevron-down", lambda _c=False: self._move(answers, j, 1), "pan.down"),
                 _icon("trash-2", lambda _c=False: self._remove(answers, j, keep_one=True), "dlg.remove")]
        row.tools = tools
        does = _opt("Effects", any(c.get(k) for k, _l in ANSWER_DOES), "dlg.does")
        _menu(does, ANSWER_DOES, None, lambda k, c=c: self._answer_does(c, k))
        for w in [num, text, once, add_cond, does] + tools:
            h.addWidget(w, 1 if w is text else 0)
        return row

    # --- where things are in the tree, and what the flow shows them in
    def _locate(self, item, ls=None):
        """(list, index) of a line / choice / if / random / script; (list, index of its choice, answer index) of an
        answer; None."""
        ls = self.lines() if ls is None else ls
        for k, x in enumerate(ls):
            if x is item:
                return ls, k
            if "choice" in x:
                for j, c in enumerate(x["choice"]):
                    if c is item:
                        return ls, k, j
            if any(s in x for s in D.SPLITS):
                for sub, _e in D.ways(x):
                    found = self._locate(item, sub)
                    if found:
                        return found
        return None

    def _ref_of(self, item):
        """(the flow's box ref, answer row) of what shows an item."""
        at = self._locate(item) if item is not None else None
        if at is None or self.graph.flow is None:
            return None, -1
        for b in self.graph.flow.boxes:
            r = b.ref
            if not r or len(r) < 3:
                continue
            if len(at) == 2:
                ls, k = at
                if r[0] == "lines" and r[1] is ls and r[2] <= k <= r[3]:
                    return r, -1
                if r[0] in ("choice", "split", "script") and r[1] is ls and r[2] == k:
                    return r, -1
            elif r[0] == "choice" and r[1] is at[0] and r[2] == at[1]:
                return r, at[2]
        return None, -1

    def _owner(self, ls, within=None):
        """The answer (or way of an If) whose lines `ls` are; None for the talk's own."""
        for x in self.lines() if within is None else within:
            ways = (x.get("choice") or []) + (x.get("random") or []) + \
                ([x.get(s) or {} for s in ("then", "else")] if "if" in x else [])
            for d in ways:
                if d.get("lines") is ls:
                    return d
                found = self._owner(ls, d.get("lines") or [])
                if found is not None:
                    return found
        return None

    def _item_of(self, ref, row=-1):
        """What a box of the flow shows (the dict its card is about), or None."""
        if not ref:
            return None
        if ref[0] == "lines":
            ls, a, b = ref[1], ref[2], ref[3]
            keep = self._locate(self.picked) if self.picked is not None else None
            if keep and len(keep) == 2 and keep[0] is ls and a <= keep[1] <= b:
                return self.picked                  # a line of this block is picked already: it stays
            return ls[a]
        if ref[0] == "choice":
            x = ref[1][ref[2]]
            return x["choice"][row] if 0 <= row < len(x["choice"]) else x
        if ref[0] in ("split", "script"):
            return ref[1][ref[2]]
        if ref[0] in ("answer", "end") and isinstance(ref[1], dict):
            return ref[1]
        return None

    def _pick(self, ref, row=-1):
        self.picked = self._item_of(ref, row)
        self.graph.select(ref, row)
        self._card()

    def _open(self, ref, row=-1):
        """A double click on lines: the words of the line picked, typed in at once."""
        self._pick(ref, row)
        at = self._locate(self.picked) if self.picked is not None else None
        if at and len(at) == 2 and "who" in at[0][at[1]]:
            self.focus_line = self.picked
            self._card()

    def _names(self):
        names = {k: label for k, _r, label in D.speakers(self.step())}
        names[D.PLAYER] = self.player_label()
        return names

    def _anchored(self, menu, x, y, w, h):
        from . import inline_menu
        self._anchor.setGeometry(x, y, w, h)
        inline_menu.show(self._anchor, menu)

    def _box_menu(self, ref, row, pos):
        """A right click on the flow: remove what it is (lines, a choice, an answer, an if, a script)."""
        item = self._item_of(ref, row)
        at = self._locate(item) if item is not None else None
        if not at:
            return
        m = QtWidgets.QMenu(self)
        if len(at) == 3:
            answers = at[0][at[1]]["choice"]
            m.addAction(_trash(), "Remove option").triggered.connect(
                lambda _c=False: self._remove(answers, at[2], keep_one=True))
        elif ref[0] == "lines":
            m.addAction(_trash(), "Remove lines").triggered.connect(lambda _c=False: self._remove_run(ref[1], ref[2], ref[3]))
        else:
            m.addAction(_trash(), "Remove").triggered.connect(lambda _c=False: self._remove(at[0], at[1]))
        spot = self.graph.viewport().mapFromGlobal(pos)
        self._anchored(m, spot.x(), spot.y() - 2, 160, 2)

    def delete_picked(self):
        """Delete: the line, answer, choice or If picked goes (a choice keeps one answer)."""
        at = self._locate(self.picked) if self.picked is not None else None
        if not at:
            return
        self.picked = None
        if len(at) == 3:
            self._remove(at[0][at[1]]["choice"], at[2], keep_one=True)
        else:
            self._remove(at[0], at[1])

    def _remove_run(self, ls, a, b):
        del ls[a:b + 1]
        self.picked = None
        self.save()

    def _duplicate(self, ls, k):
        import copy
        ls.insert(k + 1, copy.deepcopy(ls[k]))
        self.picked = ls[k + 1]
        self.save()

    def _next_speaker(self, ls, i):
        """Speakers take turns: after the player the one who spoke before them, after anybody else the player; the
        first line of the talk and of an answer's way is the NPC's."""
        if getattr(self, "monologue", False):
            return D.PLAYER
        said = [y for y in ls[:i] if "who" in y]
        if not said:
            return "npc"
        if D.is_player(said[-1].get("who")):
            return next((y["who"] for y in reversed(said) if not D.is_player(y.get("who"))), "npc")
        return D.PLAYER

    def _spot(self, ref, row=-1):
        """(list, index) a block put at a box goes to: after the line picked / the block, the choice, the If; into
        an answer's way (at its end); the talk's end for its last pill; the top for its start."""
        if not ref:
            ls = self.lines()
            return ls, len(ls)
        if ref[0] == "start":
            return self.lines(), 0
        if ref[0] == "lines":
            at = self._locate(self.picked) if self.picked is not None else None
            if at and len(at) == 2 and at[0] is ref[1] and ref[2] <= at[1] <= ref[3]:
                return ref[1], at[1] + 1
            return ref[1], ref[3] + 1
        if ref[0] == "choice" and row >= 0:
            c = ref[1][ref[2]]["choice"][row]
            ls = c.setdefault("lines", [])
            return ls, len(ls)
        if ref[0] in ("choice", "split", "script"):
            return ref[1], ref[2] + 1
        if ref[0] in ("answer", "end"):
            if isinstance(ref[1], dict):
                ls = ref[1].setdefault("lines", [])
                return ls, len(ls)
            return ref[1], len(ref[1])
        return None

    def _place(self, block, ref, row=-1):
        """A block of the sidebar at a box: a line (the keys go into it), a choice (two answers that go on - a
        choice of tone to start from), an If."""
        at = self._spot(ref, row)
        if at is None:
            return
        ls, i = at
        if block == "line":
            new = {"who": self._next_speaker(ls, i), "text": ""}
            self.focus_line = new
        elif block == "choice":
            new = {"choice": [{"text": "", "lines": [], "end": "on"}, {"text": "", "lines": [], "end": "on"}]}
            if getattr(self, "monologue", False):       # examining: 'the arm', 'the head' - chosen, not said
                for c in new["choice"]:
                    c["say"] = False
        else:
            new = {"if": {"fact": "", "op": ">=", "value": 1}, "then": {"lines": []}, "else": {"lines": []}}
        ls.insert(i, new)
        self.picked = new
        self.save()

    def _click_block(self, block):
        """A block clicked (not dragged): after what is picked, else at the end of the talk."""
        self._place(block, self.graph.chosen, self.graph.chosen_row[1] if self.graph.chosen_row else -1)

    def _answer_does(self, c, k):
        """Switch one of the answer's effects / needs on or off."""
        if c.get(k):
            c.pop(k)
        else:
            c[k] = {"emphasize": True, "axii": True, "shop": True, "pay": 50, "give": {"item": "", "count": 1},
                    "receive": {"item": "", "count": 1, "money": 0, "xp": 0},
                    "needs": {"item": "", "count": 1, "money": 0}}[k]
        self.save()

    def _answer_extras(self, c):
        """A row with what the answer does and needs (only those set)."""
        parts = []

        def spin(d, key, lo, hi, suffix):
            from .fields import with_unit
            w = QtWidgets.QSpinBox()
            w.setRange(lo, hi)
            w.setValue(int(d.get(key, 0)))
            w.editingFinished.connect(lambda d=d, key=key, w=w: self._set(d, key, w.value() or None, rebuild=False))
            return with_unit(w, suffix)

        def item(d):                            # the one item chooser, as everywhere (questboard._item_line)
            return self.board._item_line(d, "item", on_set=lambda ref, d=d: self._set(d, "item", ref or ""))

        def label(text, colour="#bbb"):
            lab = QtWidgets.QLabel(text)
            lab.setStyleSheet(f"color:{colour};font:11px")
            return lab
        if c.get("emphasize"):
            parts += [label("main option (yellow)", "#e3c65f")]
        if c.get("axii"):
            parts += [label("Axii", "#9fb0ff")]
        if c.get("shop"):
            parts += [label("opens the shop", "#9fb0ff")]
        if c.get("icon"):                       # from a game scene: the answer's icon (the shop, the door ...)
            parts += [label(f"icon: {c['icon']}", "#9fb0ff")]
        if c.get("pay"):
            parts += [label("pays"), spin(c, "pay", 1, 100000, " crowns")]
        if isinstance(c.get("give"), dict):
            parts += [label("gives"), item(c["give"]), spin(c["give"], "count", 1, 999, "x")]
        if isinstance(c.get("receive"), dict):
            d = c["receive"]
            parts += [label("receives"), item(d), spin(d, "count", 0, 999, "x"), spin(d, "money", 0, 100000, " crowns"),
                      spin(d, "xp", 0, 100000, " xp")]
        if isinstance(c.get("needs"), dict):
            d = c["needs"]
            parts += [label("player has", "#9fb0ff"), item(d), spin(d, "count", 1, 999, "x"),
                      spin(d, "money", 0, 100000, " crowns"),
                      _icon("trash-2", lambda _c=False, c=c: (c.pop("needs", None), self.save()), "dlg.remove")]
        if not parts:
            return None
        return _hbox(*parts, None)

    def _set_end(self, c, k):
        """Where an answer leads; a new path is named after the answer."""
        if k == "new_path":
            k = "path:" + self.board.new_path(c.get("text") or "New branch")
        self._set(c, "end", k)

    def _only_if(self, c, fact, answers=()):
        if isinstance(fact, str) and fact.startswith("@#"):    # an option without an id yet: it gets one now
            import uuid
            other = answers[int(fact[2:])]
            other["id"] = other.get("id") or uuid.uuid4().hex[:8]
            fact = "@" + other["id"]
        self._set(c, "only_if", fact)

    def _fold(self, c):
        (self.folded.discard if id(c) in self.folded else self.folded.add)(id(c))
        self.sync()

    # --- the voice of a line: the game's own lines (searched by words) or recordings of the content packs
    def _gesture(self, x, k):
        """One of the everyday gestures, none, or the search over all of the game's scene animations."""
        if k == "__find":
            self.anim_open = self.picked = x
            self.sync()
            return
        x.pop("anim", None)
        self._set(x, "gesture", k)

    def _anim_search(self, x):
        """Words -> the game's scene animations with them in their name (and how long they are); a click takes one."""
        box = QtWidgets.QFrame()
        box.setObjectName("choice")
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(6, 5, 6, 6)
        v.setSpacing(4)
        find = QtWidgets.QLineEdit(getattr(self, "anim_find", "") or "")
        find.setPlaceholderText("Search animations")
        tip(find, "dlg.anim_find")
        v.addWidget(_hbox(find, _icon("x", lambda _c=False: self._close_anim(), "qb.cancel"), stretch=0))
        lst = QtWidgets.QListWidget()
        lst.setMinimumHeight(200)
        v.addWidget(lst)

        have = self.body_of(x.get("who") or "npc")     # only the speaker's own (another body's: a T-pose)

        def fill(text):
            self.anim_find = text
            lst.clear()
            for name, secs in D.find_animations(text, only=have):
                it = QtWidgets.QListWidgetItem(f"{D.anim_label(name)}   ({secs:.1f} s)")
                it.setData(Q.UserRole, name)
                lst.addItem(it)
        find.textChanged.connect(fill)
        lst.itemClicked.connect(lambda it, x=x: self._take_anim(x, it.data(Q.UserRole)))
        fill(find.text())
        QtCore.QTimer.singleShot(0, lambda: self._type_into(find))
        return box

    def _take_anim(self, x, name):
        x.pop("gesture", None)
        x["anim"] = name
        self.anim_open = None
        self.save()

    def _close_anim(self):
        self.anim_open = None
        self.sync()

    def _voice_search(self, x):
        box = QtWidgets.QFrame()
        box.setObjectName("choice")
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(6, 5, 6, 6)
        v.setSpacing(4)
        source = self.voice_source
        chips = []
        for key, label in (("game", "Game"), ("custom", "Custom")):
            c = _opt(label, source == key, f"dlg.voice_{key}")
            c.setPopupMode(QtWidgets.QToolButton.DelayedPopup)
            c.clicked.connect(lambda _c=False, key=key: self._voice_from(key))
            chips.append(c)
        find = QtWidgets.QLineEdit(x.get("text", "") if source == "game" else self.custom_find)
        find.setPlaceholderText("Words of the line" if source == "game" else "Words, speaker, tag")
        tip(find, "dlg.voice_find" if source == "game" else "dlg.custom_find")
        v.addWidget(_hbox(*chips, find, _icon("x", lambda _c=False: self._close_voice(), "qb.cancel"),
                          stretch=2))
        if source == "custom":
            self._custom_depot(v, x, find)
        else:
            self._game_voices(v, x, find)
        QtCore.QTimer.singleShot(0, lambda: self._type_into(find))
        return box

    def _scroll_to(self, field):
        """The card's scroll area moved so `field` (and a little below it) is in sight."""
        import shiboken6
        if not (shiboken6.isValid(field) and hasattr(self, "scroll")):
            return

        def go():                               # (after the card has its size: at once it had none - 07.10.)
            if shiboken6.isValid(field):
                self.scroll.ensureWidgetVisible(field, 0, 80)
        for ms in (30, 150, 400):
            QtCore.QTimer.singleShot(ms, go)

    def _type_into(self, field):
        """Typing goes to this field (the panel never takes the focus from the game: the key router hands it the
        keys - a plain setFocus would leave them with the game)."""
        import shiboken6
        if shiboken6.isValid(field) and field.isVisible():
            typing = getattr(self.board.ed, "typing", None)
            if typing is not None:
                typing.start(field)
            else:
                field.setFocus()

    def _game_voices(self, v, x, find):
        area = QtWidgets.QScrollArea()
        area.setWidgetResizable(True)
        area.setFrameShape(QtWidgets.QFrame.NoFrame)
        area.setHorizontalScrollBarPolicy(Q.ScrollBarAlwaysOff)
        area.setMinimumHeight(220)
        v.addWidget(area)

        def search():
            body = QtWidgets.QWidget()
            col = QtWidgets.QVBoxLayout(body)
            col.setContentsMargins(0, 0, 0, 0)
            col.setSpacing(2)
            if self.voices is None:
                note = QtWidgets.QLabel("Reading the game's voices...")
                note.setObjectName("note")
                col.addWidget(note)
                area.setWidget(body)
                self._load_voices(search)
                return
            from .voices import speaker_label
            rows = self.voices.search(find.text(), speaker=self.player_voicetag() if D.is_player(x.get("who")) else None,
                                      others=not D.is_player(x.get("who")), limit=60)
            for r in rows:
                play = _icon("square" if self.playing == ("game", r["id"]) else "play",
                               lambda _c=False, sid=r["id"]: self._play_game(sid, search), "dlg.play")
                dur = f"  -  {r['dur']:.1f} s" if r["dur"] else ""
                entry = QtWidgets.QPushButton(f"{_short(r['text'])}\n{speaker_label(r['speaker'])}{dur}")
                entry.setToolTip(r["text"])
                entry.setObjectName("entry")
                entry.setStyleSheet(ENTRY)
                entry.setFocusPolicy(Q.NoFocus)
                entry.clicked.connect(lambda _c=False, r=r, x=x: self._set_voice(x, r))
                tip(entry, "dlg.game_take")
                col.addWidget(_hbox(play, entry, stretch=1))
            if not rows:
                note = QtWidgets.QLabel("No voice lines for these words")
                note.setObjectName("note")
                col.addWidget(note)
            col.addStretch(1)
            area.setWidget(body)
        timer = QtCore.QTimer(area, singleShot=True, interval=250)
        timer.timeout.connect(search)
        find.textChanged.connect(timer.start)
        QtCore.QTimer.singleShot(0, search)

    def _custom_depot(self, v, x, find):
        """The recordings of every loaded content pack: tags (left click: only this one, right click: add), words,
        Play, click the text to take it."""
        from . import contentpacks
        from .catalog_view import Chip, Flow
        tags = QtWidgets.QWidget()
        flow = Flow(tags)
        for tag, n in contentpacks.voice_tags()[:40]:
            c = Chip(f"{tag}  {n}")
            c.setChecked(tag in self.custom_tags)
            c.picked.connect(lambda add, tag=tag: self._pick_tag(tag, add))
            flow.addWidget(c)
        v.addWidget(tags)
        area = QtWidgets.QScrollArea()
        area.setWidgetResizable(True)
        area.setFrameShape(QtWidgets.QFrame.NoFrame)
        area.setHorizontalScrollBarPolicy(Q.ScrollBarAlwaysOff)
        area.setMinimumHeight(200)
        v.addWidget(area)

        def fill():
            self.custom_find = find.text()
            body = QtWidgets.QWidget()
            col = QtWidgets.QVBoxLayout(body)
            col.setContentsMargins(0, 0, 0, 0)
            col.setSpacing(2)
            rows = contentpacks.search_voices(find.text(), sorted(self.custom_tags))
            for r in rows:
                play = _icon("square" if self.playing == r["file"] else "play",
                               lambda _c=False, f=r["file"]: self._play(f, fill), "dlg.play")
                entry = QtWidgets.QPushButton(f"{_short(r['text'])}\n{r['speaker'] or '-'}  -  {r['pack_name']}  -  "
                                              f"{r['dur']:.1f} s  -  {', '.join(r['tags'])}")
                entry.setObjectName("entry")
                entry.setStyleSheet(ENTRY)
                entry.setFocusPolicy(Q.NoFocus)
                entry.clicked.connect(lambda _c=False, r=r, x=x: self._set_custom(x, r))
                tip(entry, "dlg.custom_take")
                col.addWidget(_hbox(play, entry, stretch=1))
            if not rows:
                note = QtWidgets.QLabel("No recordings for these words or tags" if contentpacks.packs()
                                        else "No content packs loaded")
                note.setObjectName("note")
                col.addWidget(note)
            col.addStretch(1)
            area.setWidget(body)
        timer = QtCore.QTimer(area, singleShot=True, interval=200)
        timer.timeout.connect(fill)
        find.textChanged.connect(timer.start)
        fill()

    def _voice_from(self, source):
        self.voice_source = source
        self.sync()

    def _pick_tag(self, tag, add):
        if add:
            (self.custom_tags.discard if tag in self.custom_tags else self.custom_tags.add)(tag)
        elif self.custom_tags == {tag}:
            self.custom_tags.clear()
        else:
            self.custom_tags = {tag}
        self.sync()

    def _play(self, path, then=None):
        """Plays a recording (again: stops it)."""
        from PySide6 import QtMultimedia
        if self.player is None:
            self.player = QtMultimedia.QMediaPlayer(self)
            self.audio = QtMultimedia.QAudioOutput(self)
            self.player.setAudioOutput(self.audio)
            self.player.mediaStatusChanged.connect(self._played)
        if self.playing == path:
            self.player.stop()
            self.playing = None
        else:
            self.player.setSource(QtCore.QUrl.fromLocalFile(path))
            self.player.play()
            self.playing = path
        self._after_play = then
        if then:
            then()

    def _play_game(self, sid, then=None):
        """A game line: its audio is cut out of the game's speech file and decoded once (voices.listen)."""
        from . import voices
        if self.playing == ("game", sid):
            self.player.stop()
            self.playing = None
            if then:
                then()
            return
        path = voices.listen(sid)
        if not path:
            QtWidgets.QToolTip.showText(QtGui.QCursor.pos(), "No audio for this line (or vgmstream is missing).")
            return
        self._play(path)
        self.playing = ("game", sid)
        self._after_play = then
        if then:
            then()

    def _played(self, status):
        from PySide6 import QtMultimedia
        if status == QtMultimedia.QMediaPlayer.EndOfMedia:
            self.playing = None
            if self._after_play:
                try:
                    self._after_play()
                except RuntimeError:            # its list was rebuilt meanwhile
                    pass

    def _voice_menu(self, x, k):
        if k == "find":
            self.voice_source = "custom" if x.get("voice_pack") else "game"
            self._open_voice(x)
        elif k == "play":
            if x.get("voice"):
                self._play_game(int(x["voice"]))
            else:
                from . import contentpacks
                r = contentpacks.voice(x["voice_pack"])
                if r:
                    self._play(r["file"])
        else:
            self._clear_voice(x)

    def _load_voices(self, then):
        from . import voices
        if getattr(self, "_loading", False):
            return
        self._loading = True

        def work():
            if not voices.ready():
                voices.build(log=lambda s: None)
            self.voices = voices.Voices()
            QtCore.QMetaObject.invokeMethod(self, "_voices_ready", Q.QueuedConnection)
        self._then = then
        threading.Thread(target=work, daemon=True).start()

    @QtCore.Slot()
    def _voices_ready(self):
        self._loading = False
        if self.voice_open is not None:
            self.sync()

    def _open_voice(self, x):
        self.voice_open = self.picked = x
        self.sync()

    def _close_voice(self):
        self.voice_open = None
        self.sync()

    def _set_voice(self, x, r):
        """The line says what the voice says."""
        x.pop("voice_pack", None)
        from .voices import length
        x["voice"], x["dur"], x["text"] = int(r["id"]), length(r["id"], r["dur"], r["text"]), r["text"]
        self.voice_open = None
        self.save()

    def _set_custom(self, x, r):
        """An own recording: the line says what was recorded."""
        x.pop("voice", None)
        x["voice_pack"], x["dur"] = r["key"], float(r["dur"])
        if r["text"]:
            x["text"] = r["text"]
        self.voice_open = None
        self.save()

    def _clear_voice(self, x):
        for key in ("voice", "voice_pack", "dur"):
            x.pop(key, None)
        self.save()

    # --- changes
    def _set(self, x, key, value, rebuild=True):
        if value is None or value == "":
            x.pop(key, None)
        else:
            x[key] = value
        self.save(rebuild)

    def _set_text(self, x, text):
        text = " ".join(text.split())
        if text == x.get("text", ""):
            return
        if (x.get("voice") or x.get("voice_pack")) and text != x.get("text"):
            for key in ("voice", "voice_pack", "dur"):
                x.pop(key, None)                # a changed text is no longer the voiced line
            x["text"] = text
            self.save()
        else:
            self._set(x, "text", text, rebuild=False)

    def _add_alt(self, x):
        x.setdefault("alt", []).append("")
        self.save()

    def _set_alt(self, x, j, text):
        text = " ".join(text.split())
        alts = x.get("alt") or []
        if j < len(alts) and alts[j] != text:
            alts[j] = text
            self.save(rebuild=False)

    def _remove_alt(self, x, j):
        alts = x.get("alt") or []
        if j < len(alts):
            alts.pop(j)
        if not alts:
            x.pop("alt", None)
        self.save()

    def _next_line(self, ls, x, text):
        """Enter: this line is done; the next one opens with the keys in it (the other one speaks). Enter on an
        empty line: it goes and typing ends."""
        text = " ".join(text.split())
        if not text:
            if x in ls and not x.get("voice") and not x.get("voice_pack"):
                ls.remove(x)
            if hasattr(self.board.ed, "typing"):
                self.board.ed.typing.stop()
            self.save()
            return
        if text != x.get("text"):
            for key in ("voice", "voice_pack", "dur"):
                x.pop(key, None)                # a changed text is no longer the voiced line
            x["text"] = text
        k = ls.index(x) + 1                     # (before a choice that follows, too)
        speakers = [key for key, _r, _l in D.speakers(self.step())]
        before = next((y.get("who") for y in reversed(ls[:k]) if "who" in y and not D.is_player(y.get("who"))), "npc")
        new = {"who": before if D.is_player(x.get("who")) else D.PLAYER, "text": ""}
        if new["who"] not in speakers:
            new["who"] = "npc"
        ls.insert(k, new)
        self.focus_line = self.picked = new
        typing = getattr(self.board.ed, "typing", None)
        if typing is not None:                  # the card is built anew with the new line in it, the keys go there
            typing.stop()                       # (07.10.: typing kept the old card - the line only in the graph)
        self.save()

    def _add_line(self, ls):
        # speakers take turns: after anybody else the player, after the player the one who spoke before
        last = next((x for x in reversed(ls) if "who" in x), None)
        before = next((x.get("who") for x in reversed(ls) if "who" in x and not D.is_player(x.get("who"))), "npc")
        who = D.PLAYER if last is not None and not D.is_player(last.get("who")) else before
        if last is None and ls is not self.lines():
            who = "npc"                         # an answer: the player has said it, the NPC replies
        ls.append({"who": who, "text": ""})
        self.focus_line = self.picked = ls[-1]  # the keys go straight into it
        self.save()

    def _add_choice(self, ls):
        ls.append({"choice": [{"text": "", "lines": [], "end": "continue"}, {"text": "", "lines": [], "end": "back"}]})
        self.save()

    def _add_answer(self, answers):
        answers.append({"text": "", "lines": [], "end": "back"})
        self.save()

    def _move(self, ls, k, d):
        j = k + d
        if not 0 <= j < len(ls) or any(key in ls[i] for i in (j, k) for key in ("choice", "if", "random")):
            return                              # a choice stays at the end of its list
        ls[k], ls[j] = ls[j], ls[k]
        self.save()

    def _remove(self, ls, k, keep_one=False):
        if keep_one and len(ls) <= 1:
            return
        if self.voice_open is ls[k]:
            self.voice_open = None
        ls.pop(k)
        self.save()
