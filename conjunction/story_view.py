"""The story map (Maxim 05.10.: "einen graphen der alle WIRKLICH ALLE quests zeigt ... wann welche quest passiert,
welche dadurch freigeschaltet wird ... dort kann man neue einhängen"): every quest of the game and its expansions
on one timeline - the level it is meant for, never before what unlocks it (story.placed) - in a lane per region,
the main story on top, the acts above the level ruler, the project's own quest above it all, where it is hooked in.

    the chips               which kinds (main, side, contracts, treasure hunts) and which games are shown; contracts
                            and treasure hunts are off at first - 121 quests that hang on nothing but a notice board
                            or a note found
    a click on a quest      its chain: everything it waits for (gold, from the left) and everything that waits for it
                            (blue, to the right), the rest dimmed; its details on the right, the quests named there a
                            click away - and "Start my quest after this": the project's quest begins once that quest
                            has set the chosen fact (the quest's after_game hook)
    a click on the map / Esc  nothing picked
    the search field        the quests whose title or code has the words, the first one in view
    the wheel / a drag      zoom / move; zoomed far out the cards are bars of their kind's colour
"""
import threading

from PySide6 import QtCore, QtGui, QtWidgets

from . import config, story
from .tooltips import tip

PX = 96                         # px per level on the timeline
CARD_W, CARD_H, ROW = 176, 26, 30
LABEL_W, RULER_H, TOP = 128, 46, 4
DETAIL_ZOOM = 0.5               # below: the cards without words
KIND_COLOUR = {"main": "#d9a441", "side": "#7d8fa8", "contract": "#c0504d", "treasure": "#4f9a6a"}
KIND_NAME = {"main": "Main", "side": "Side", "contract": "Contracts", "treasure": "Treasure"}
CARD_KIND = {"main": "Main quest", "side": "Side quest", "contract": "Contract", "treasure": "Treasure hunt"}
GAME_FILTER = [("base", "Base game"), ("Hearts of Stone", "Hearts of Stone"), ("Blood and Wine", "Blood and Wine")]
GAME_COLOUR = {"Hearts of Stone": "#8e5bd1", "Blood and Wine": "#a8324a"}
REGION = {4: "White Orchard", 9: "Velen", 1: "Novigrad", 2: "Skellige", 3: "Kaer Morhen", 11: "Toussaint",
          5: "Vizima", 8: "Vizima"}
SHOWN = {"main": True, "side": True, "contract": False, "treasure": False,
         "base": True, "Hearts of Stone": True, "Blood and Wine": True}
BY, UNLOCKS, OWN = "#d9a441", "#5b9bd5", "#5cb85c"
STYLE = (
    "*{border-radius:0}"
    "QGraphicsView{background:#141417;border:1px solid #333}"
    "QLabel{color:#c8c8cc;font:12px}"
    "QLabel#detail{color:#d8d8dc;font:12px;padding:6px}"
    "QPushButton#hook{background:rgba(92,184,92,40);border-color:#5cb85c;color:#fff;font:bold 12px}"
    "QToolButton{color:#9a9aa0;background:#1b1b1e;border:1px solid #3a3a40;padding:3px 8px;font:12px}"
    "QToolButton:checked{color:#f0f0f2;background:#2c2c32;border-color:#5a5a62}"
    "QToolButton:hover{border-color:#7a7a82}")


def done_facts(q):
    """The facts a quest sets, the ones that read as 'it is done' first (to hook a quest after it)."""
    facts = list(dict.fromkeys(q.get("sets") or []))

    def key(f):
        return not any(w in f.lower() for w in ("complet", "done", "finish", "_end", "success")), facts.index(f)
    return sorted(facts, key=key)


def game_key(q):
    return q.get("game") if q.get("game") in GAME_COLOUR else "base"


def chain(quests, qid, key):
    """Every quest reached from qid along `key` ("by": all it waits for, "unlocks": all that waits for it)."""
    seen, todo = set(), [qid]
    while todo:
        for other in quests.get(todo.pop(), {}).get(key, []):
            if other not in seen and other in quests:
                seen.add(other)
                todo.append(other)
    return seen - {qid}


class Card(QtWidgets.QGraphicsRectItem):
    def __init__(self, view, q, own=False):
        super().__init__(0, 0, CARD_W, CARD_H)
        self.view, self.q, self.own = view, q, own
        self.setAcceptHoverEvents(True)
        self.setCursor(QtCore.Qt.PointingHandCursor)
        self.picked = self.hit = False
        kind = "Your quest" if own else CARD_KIND.get(q.get("kind"), "Quest")
        level = f", level {q['level']}" if q.get("level") else ""
        self.setToolTip(f"{q.get('title') or q.get('id')}\n{kind}{level}")

    def colour(self):
        return QtGui.QColor(OWN if self.own else KIND_COLOUR.get(self.q.get("kind"), "#6a6a70"))

    def paint(self, p, opt, _w=None):
        r = self.rect()
        q = self.q
        lod = opt.levelOfDetailFromTransform(p.worldTransform())
        if lod < DETAIL_ZOOM:                           # far out: a bar of its kind's colour
            c = self.colour()
            if not (self.picked or self.hit):
                c.setAlpha(170)
            p.fillRect(r.adjusted(0, 3, 0, -3), c)
            if self.picked or self.hit:
                p.setPen(QtGui.QPen(QtGui.QColor("#ffffff"), 3 / max(lod, 0.05)))
                p.drawRect(r.adjusted(0, 3, 0, -3))
            return
        p.setPen(QtGui.QPen(QtGui.QColor(BY if self.picked else "#e8e8e8" if self.hit else "#3c3c42"),
                            2 if self.picked else 1))
        p.setBrush(QtGui.QColor("#30303a" if self.isUnderMouse() else "#24242a"))
        p.drawRect(r)
        p.fillRect(QtCore.QRectF(r.x(), r.y(), 4, r.height()), self.colour())
        if q.get("game") in GAME_COLOUR:
            p.fillRect(QtCore.QRectF(r.right() - 7, r.y() + 3, 4, 4), QtGui.QColor(GAME_COLOUR[q["game"]]))
        f = QtGui.QFont("Segoe UI")
        f.setPixelSize(11)
        f.setBold(q.get("kind") == "main" or self.own)
        p.setFont(f)
        fm = QtGui.QFontMetrics(f)
        level = str(q.get("level") or "")
        room = r.width() - 14 - (22 if level else 6)
        p.setPen(QtGui.QColor("#f0f0f2"))
        title = q.get("title") or q.get("name") or q.get("id")
        p.drawText(QtCore.QRectF(r.x() + 10, r.y(), room, r.height()), QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter,
                   fm.elidedText(title, QtCore.Qt.ElideRight, int(room)))
        if level:
            f.setBold(False)
            f.setPixelSize(10)
            p.setFont(f)
            p.setPen(QtGui.QColor("#7c7c82"))
            p.drawText(QtCore.QRectF(r.right() - 30, r.y(), 22, r.height()),
                       QtCore.Qt.AlignRight | QtCore.Qt.AlignVCenter, level)

    def hoverEnterEvent(self, ev):
        self.update()

    def hoverLeaveEvent(self, ev):
        self.update()

    def mousePressEvent(self, ev):
        if ev.button() == QtCore.Qt.LeftButton:
            self.view.pick(self)
            ev.accept()
            return
        super().mousePressEvent(ev)


class StoryMap(QtWidgets.QGraphicsView):
    picked = QtCore.Signal(object)          # the quest dict (None: nothing)

    def __init__(self):
        super().__init__()
        self.setScene(QtWidgets.QGraphicsScene(self))
        self.setRenderHint(QtGui.QPainter.Antialiasing)
        self.setDragMode(QtWidgets.QGraphicsView.ScrollHandDrag)
        self.setTransformationAnchor(QtWidgets.QGraphicsView.AnchorUnderMouse)
        self.setAlignment(QtCore.Qt.AlignLeft | QtCore.Qt.AlignTop)
        self.cards, self.lines, self.current, self.quests = {}, [], None, {}
        self.bands, self.acts = [], []

    # --- drawn
    def show_quests(self, quests, own=None, acts=()):
        """The map: lanes, the acts and the level ruler, a card per quest, the main story's links always (faint);
        `own`: the project's quest(s) [(quest dict, x)]."""
        sc = self.scene()
        sc.clear()
        self.cards, self.lines, self.current, self.acts = {}, [], None, list(acts)
        self.quests = {q["id"]: q for q in quests}
        lanes = [("own", "Your project")] + story.LANES
        by_lane = {k: [] for k, _n in lanes}
        for q in quests:
            by_lane.get(q["lane"], by_lane["other"]).append(q)
        by_lane["own"] = [dict(q, x=x, lane="own") for q, x in (own or [])]
        x_max = max([q["x"] for q in quests] + [50]) + 3
        width = LABEL_W + x_max * PX + CARD_W
        y = TOP + RULER_H
        bands = []
        for key, name in lanes:
            if not by_lane[key]:
                continue
            rows, spots = [], []                        # each row: the right end of its last card
            for q in sorted(by_lane[key], key=lambda q: q["x"]):
                cx = LABEL_W + q["x"] * PX
                row = next((k for k, end in enumerate(rows) if end < cx - 4), None)
                if row is None:
                    rows.append(0)
                    row = len(rows) - 1
                rows[row] = cx + CARD_W
                spots.append((q, cx, row))
            h = len(rows) * ROW + 10
            bands.append((name, y, h, len(spots)))
            for q, cx, row in spots:
                c = Card(self, q, own=key == "own")
                c.setPos(cx, y + 5 + row * ROW)
                sc.addItem(c)
                self.cards[q["id"] + ("#own" if key == "own" else "")] = c
            y += h
        self.bands = bands
        for k, (_name, by, h, _n) in enumerate(bands):
            band = sc.addRect(0, by, width, h, QtGui.QPen(QtCore.Qt.NoPen),
                              QtGui.QColor(255, 255, 255, 6 if k % 2 else 0))
            band.setZValue(-3)
            sc.addLine(0, by + h, width, by + h, QtGui.QPen(QtGui.QColor("#2a2a30"))).setZValue(-2)
        for lvl in range(0, int(x_max) + 1):
            x = LABEL_W + lvl * PX
            sc.addLine(x, TOP + RULER_H, x, y, QtGui.QPen(QtGui.QColor(255, 255, 255, 10))).setZValue(-2)
        pen = QtGui.QPen(QtGui.QColor(217, 164, 65, 70), 1, QtCore.Qt.DashLine)
        for _name, x in self.acts:                      # where each act begins: across the whole map
            sc.addLine(LABEL_W + x * PX - 6, TOP + RULER_H, LABEL_W + x * PX - 6, y, pen).setZValue(-1.5)
        self.spine = []
        for q in quests:                                # the main story's own links, always there, faint
            if q["lane"] == "story":
                for b in q.get("by", []):
                    if self.quests.get(b, {}).get("lane") == "story":
                        item = self._link(self.cards.get(b), self.cards.get(q["id"]),
                                          QtGui.QColor(217, 164, 65, 45), 1.0, keep=False)
                        if item is not None:
                            self.spine.append(item)
        sc.setSceneRect(0, 0, width, y + 10)

    # --- picked: its chain
    def pick(self, card):
        for item in self.lines:
            self.scene().removeItem(item)
        self.lines = []
        self.current = card
        for c in self.cards.values():
            c.picked = c is card
            c.setOpacity(1.0)
            c.update()
        for item in getattr(self, "spine", []):
            item.setVisible(card is None)
        if card is None:
            self.picked.emit(None)
            return
        q = card.q
        before = chain(self.quests, q["id"], "by") if not card.own else set()
        after = chain(self.quests, q["id"], "unlocks") if not card.own else set()
        hooks = set(q.get("hooks", []))
        lit = before | after | hooks | {q["id"]}
        for key, c in self.cards.items():
            if c is not card and c.q["id"] not in lit:
                c.setOpacity(0.16)
        for qid in before | {q["id"]}:                  # what it waits for: gold, the direct ones strong
            for b in self.quests.get(qid, {}).get("by", []):
                if b in before:
                    strong = qid == q["id"]
                    self._link(self.cards.get(b), self.cards.get(qid), BY, 2.0 if strong else 1.0,
                               alpha=255 if strong else 120)
        for qid in after | {q["id"]}:                   # what waits for it: blue
            for u in self.quests.get(qid, {}).get("unlocks", []):
                if u in after:
                    strong = qid == q["id"]
                    self._link(self.cards.get(qid), self.cards.get(u), UNLOCKS, 2.0 if strong else 1.0,
                               alpha=255 if strong else 120)
        for hook in hooks:                              # the project's quest: to the quest it waits for
            self._link(self.cards.get(hook), card, OWN, 2.0)
        self.picked.emit(q)

    def pick_id(self, qid):
        card = self.cards.get(qid)
        if card is not None:
            self.pick(card)
            self.ensureVisible(card, 120, 80)
        return card

    def _link(self, a, b, colour, width=1.6, alpha=255, keep=True):
        """A square line from a's right to b's left (sharp bends)."""
        if a is None or b is None:
            return None
        ra, rb = a.sceneBoundingRect(), b.sceneBoundingRect()
        x0, y0 = ra.right(), ra.center().y()
        x1, y1 = rb.left(), rb.center().y()
        mid = x0 + max(8.0, (x1 - x0) / 2) if x1 > x0 + 16 else x0 + 8
        path = QtGui.QPainterPath(QtCore.QPointF(x0, y0))
        path.lineTo(mid, y0)
        path.lineTo(mid, y1)
        path.lineTo(x1, y1)
        c = QtGui.QColor(colour)
        if alpha != 255:
            c.setAlpha(alpha)
        item = self.scene().addPath(path, QtGui.QPen(c, width))
        item.setZValue(-1 if not keep else -0.5)
        if keep:
            self.lines.append(item)
        return item

    def find(self, words):
        words = words.lower().strip()
        first = None
        for c in self.cards.values():
            q = c.q
            text = f"{q.get('title', '')} {q.get('code') or ''}".lower()
            c.hit = bool(words) and words in text
            c.update()
            if c.hit and first is None:
                first = c
        if first is not None:
            self.centerOn(first)
        return first

    def fit(self):
        self.fitInView(self.sceneRect(), QtCore.Qt.KeepAspectRatio)
        if self.transform().m11() < 0.12:
            self.resetTransform()
            self.scale(0.12, 0.12)

    def mousePressEvent(self, ev):
        if ev.button() == QtCore.Qt.LeftButton and not isinstance(self.itemAt(ev.position().toPoint()), Card):
            self._press = ev.position().toPoint()
        super().mousePressEvent(ev)

    def mouseReleaseEvent(self, ev):
        press = getattr(self, "_press", None)
        self._press = None
        super().mouseReleaseEvent(ev)
        if press is not None and (ev.position().toPoint() - press).manhattanLength() < 4 and self.current:
            self.pick(None)                             # a click on the map, not a drag: nothing picked

    def keyPressEvent(self, ev):
        if ev.key() == QtCore.Qt.Key_Escape and self.current is not None:
            self.pick(None)
            return
        super().keyPressEvent(ev)

    def drawForeground(self, p, rect):
        """The lane names at the left, the acts and the level ruler at the top stay in view while the map moves."""
        if not self.bands:
            return
        p.save()
        p.resetTransform()
        vw, vh = self.viewport().width(), self.viewport().height()
        f = QtGui.QFont("Segoe UI")
        f.setPixelSize(12)
        f.setBold(True)
        p.setFont(f)
        for name, by, h, n in self.bands:
            top = self.mapFromScene(QtCore.QPointF(0, by)).y()
            bottom = self.mapFromScene(QtCore.QPointF(0, by + h)).y()
            if bottom < RULER_H or top > vh:
                continue
            y = max(top, RULER_H)
            tall = bottom - y >= 34                     # (room for its count too)
            p.fillRect(QtCore.QRectF(0, y, LABEL_W - 10, 34 if tall else min(18, max(bottom - y, 0))),
                       QtGui.QColor(20, 20, 23, 230))
            f.setBold(True)
            f.setPixelSize(12)
            p.setFont(f)
            p.setPen(QtGui.QColor("#b8b8bc"))
            p.drawText(QtCore.QRectF(8, y + 2, LABEL_W - 18, 16), QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter, name)
            if tall:
                f.setBold(False)
                f.setPixelSize(10)
                p.setFont(f)
                p.setPen(QtGui.QColor("#76767c"))
                p.drawText(QtCore.QRectF(8, y + 17, LABEL_W - 18, 14), QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter,
                           f"{n} quest{'s' if n != 1 else ''}")
        p.fillRect(QtCore.QRectF(0, 0, vw, RULER_H - 2), QtGui.QColor(20, 20, 23, 240))
        # the acts: a band each, from where it begins to where the next one does
        f.setPixelSize(11)
        f.setBold(True)
        p.setFont(f)
        xs = [(name, self.mapFromScene(QtCore.QPointF(LABEL_W + x * PX - 6, 0)).x()) for name, x in self.acts]
        for k, (name, x) in enumerate(xs):
            r = 1 if name in story.EXPANSIONS else 0     # (the expansions in a row of their own: they overlap)
            later = [x2 for n2, x2 in xs[k + 1:] if (n2 in story.EXPANSIONS) == bool(r) and x2 > x]
            end = later[0] if later else vw
            if end <= 0:
                continue
            y = 3 + r * 13
            band = QtCore.QRectF(max(x, 0), y, max(2, end - max(x, 0) - 2), 12)
            p.fillRect(band, QtGui.QColor(217, 164, 65, 40) if not r else QtGui.QColor(142, 91, 209, 45)
                       if name == "Hearts of Stone" else QtGui.QColor(168, 50, 74, 50))
            p.save()
            p.setClipRect(band)                         # (its name within its band: scrolled past, it gives way)
            p.setPen(QtGui.QColor("#e0c890") if not r else QtGui.QColor("#d8c8e8"))
            p.drawText(QtCore.QRectF(band.x() + 4, y - 1, 200, 14), QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter,
                       name)
            p.restore()
        f.setBold(False)
        f.setPixelSize(10)
        p.setFont(f)
        p.setPen(QtGui.QColor("#8c8c90"))
        lvl0 = int(max(0, (self.mapToScene(QtCore.QPoint(0, 0)).x() - LABEL_W) // PX))
        lvl1 = int((self.mapToScene(QtCore.QPoint(vw, 0)).x() - LABEL_W) // PX) + 1
        m = self.transform().m11()
        step = 1 if m >= 0.6 else 2 if m >= 0.3 else 5
        for lvl in range(lvl0 - lvl0 % step, lvl1 + 1, step):
            x = self.mapFromScene(QtCore.QPointF(LABEL_W + lvl * PX, 0)).x()
            p.drawText(QtCore.QRectF(x - 20, 30, 40, 14), QtCore.Qt.AlignCenter, f"{lvl}")
        p.fillRect(QtCore.QRectF(0, 30, 46, 14), QtGui.QColor(20, 20, 23, 240))
        p.drawText(QtCore.QRectF(8, 30, 40, 14), QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter, "level")
        p.restore()

    def scrollContentsBy(self, dx, dy):
        super().scrollContentsBy(dx, dy)
        self.viewport().update()                        # (the fixed names and ruler drawn again)

    def wheelEvent(self, ev):
        k = 1.15 if ev.angleDelta().y() > 0 else 1 / 1.15
        scale = self.transform().m11() * k
        if 0.08 <= scale <= 2.5:
            self.scale(k, k)
            self.viewport().update()


class StoryWindow(QtWidgets.QWidget):
    """The story map's body: the search and the chips above, the map, the picked quest's details at the right."""

    loaded = QtCore.Signal(object)

    def __init__(self, ed):
        super().__init__()
        self.ed = ed
        self.quests, self.visible = [], []
        self.setStyleSheet(STYLE)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        top = QtWidgets.QHBoxLayout()
        top.setSpacing(4)
        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText("Find a quest")
        self.search.textChanged.connect(lambda t: self.map.find(t))
        tip(self.search, "story.search")
        top.addWidget(self.search, 1)
        top.addSpacing(8)
        shown = dict(SHOWN, **(config.load().get("story_shown") or {}))
        self.chips = {}
        for key, name in list(KIND_NAME.items()) + [(None, None)] + GAME_FILTER:
            if key is None:
                top.addSpacing(10)
                continue
            b = QtWidgets.QToolButton()
            b.setCheckable(True)
            b.setChecked(bool(shown.get(key, True)))
            b.toggled.connect(lambda _on: self.refresh(save=True))
            tip(b, "story.chip_kind" if key in KIND_NAME else "story.chip_game")
            self.chips[key] = (b, name)
            top.addWidget(b)
        top.addSpacing(10)
        fit = QtWidgets.QPushButton("Fit")
        fit.clicked.connect(lambda: self.map.fit())
        tip(fit, "story.fit")
        top.addWidget(fit)
        from . import sessions
        self.worlds = QtWidgets.QPushButton("World only ▾")
        menu = QtWidgets.QMenu(self.worlds)
        menu.setStyleSheet("QMenu{background:#1f1f23;color:#ddd;border:1px solid #45454c}"
                           "QMenu::item:selected{background:#2c2c34}")
        for world in sessions.WORLD_DEFS:
            menu.addAction(sessions.world_name(f"levels\\{world}\\x"), lambda w=world: self.world_only(w))
        self.worlds.setMenu(menu)
        tip(self.worlds, "story.world_only")
        top.addWidget(self.worlds)
        v.addLayout(top)
        body = QtWidgets.QHBoxLayout()
        self.map = StoryMap()
        self.map.picked.connect(self.show_quest)
        body.addWidget(self.map, 1)
        side = QtWidgets.QVBoxLayout()
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFixedWidth(310)
        scroll.setStyleSheet("QScrollArea{border:none;background:#18181b}"
                             "QScrollArea > QWidget > QWidget{background:#18181b}")
        self.detail = QtWidgets.QLabel()
        self.detail.setObjectName("detail")
        self.detail.setWordWrap(True)
        self.detail.setTextFormat(QtCore.Qt.RichText)
        self.detail.setAlignment(QtCore.Qt.AlignTop)
        self.detail.linkActivated.connect(self.map.pick_id)
        scroll.setWidget(self.detail)
        side.addWidget(scroll, 1)
        self.graph = QtWidgets.QPushButton("Open graph")
        self.graph.setFixedWidth(310)
        self.graph.clicked.connect(self.open_graph)
        tip(self.graph, "story.graph")
        side.addWidget(self.graph)
        from . import features
        if not features.experimental():             # the game's quests: the update for vanilla editing (07.10.)
            self.graph.hide()
        row = QtWidgets.QHBoxLayout()
        self.starts = QtWidgets.QComboBox()
        self.starts.setFixedWidth(200)
        tip(self.starts, "story.starts")
        row.addWidget(self.starts)
        self.play = QtWidgets.QPushButton("Play from here")
        self.play.setFixedWidth(106)
        self.play.clicked.connect(self.play_from_here)
        tip(self.play, "story.play")
        row.addWidget(self.play)
        row.addStretch(1)
        side.addLayout(row)
        self.fact = QtWidgets.QComboBox()
        self.fact.setFixedWidth(310)
        tip(self.fact, "story.fact")
        side.addWidget(self.fact)
        if not features.experimental():             # a moment inside a quest (a fact): the update (Maxim 07.10.)
            self.fact.hide()
        # with or after a quest of the game (Maxim 07.10.: "mit einer quest ... oder nach einer quest")
        self.hook_with = QtWidgets.QPushButton("Start my quest with this")
        self.hook_with.setObjectName("hook")
        self.hook_with.setFixedWidth(310)
        self.hook_with.clicked.connect(lambda: self.hook_game("with"))
        tip(self.hook_with, "story.hook_with")
        side.addWidget(self.hook_with)
        self.hook = QtWidgets.QPushButton("Start my quest after this")
        self.hook.setObjectName("hook")
        self.hook.setFixedWidth(310)
        self.hook.clicked.connect(lambda: self.hook_game("after"))
        tip(self.hook, "story.hook")
        side.addWidget(self.hook)
        self.on_hook = None                         # (opened from the quest's Starts: closes the window then)
        body.addLayout(side)
        v.addLayout(body, 1)
        self.data = story.load()
        story.journal_entry("")                   # (the game's journal read once, for With / After)
        self.loaded.connect(self._loaded)
        if self.data is None:
            self.detail.setText("Reading the game's quests (once, about half a minute)...")
            threading.Thread(target=lambda: self.loaded.emit(story.build(log=lambda *_a: None)), daemon=True).start()
        self.refresh()
        self.show_quest(None)

    def _loaded(self, data):
        self.data = data
        self.refresh()
        self.show_quest(None)

    # --- the project's own quest, where it hangs
    def own_quests(self, quests):
        project = getattr(self.ed, "project", None)
        meta = getattr(project, "meta", None)
        q = (meta or {}).get("quest") if isinstance(meta, dict) else None
        if not q:
            return []
        hook = q.get("after_game") or {}
        gq = q.get("game_quest") or {}
        by_id = {x["id"]: x for x in quests}
        after = by_id.get(gq.get("id")) or by_id.get(hook.get("quest")) or             next((x for x in quests if hook.get("fact") in (x.get("sets") or [])), None)
        # after a quest: beside its end; with a quest: under it, at its start
        x = (after["x"] + (0.0 if gq.get("when") == "with" else 0.6)) if after else 0.5
        mine = {"id": project.id, "title": q.get("title") or meta.get("name") or project.id, "kind": "own",
                "level": q.get("level"), "hooks": [after["id"]] if after else [], "game": "", "by": [],
                "unlocks": [], "hook_fact": hook.get("fact"), "hook_when": gq.get("when")}
        return [(mine, x)]

    def shown(self):
        return {key: b.isChecked() for key, (b, _n) in self.chips.items()}

    def refresh(self, save=False):
        if save:
            cfg = config.load()
            cfg["story_shown"] = self.shown()
            config.save(cfg)
        if self.data is None:
            return
        self.quests = story.placed(self.data)
        on = self.shown()
        for key, (b, name) in self.chips.items():   # each chip with how many it stands for
            n = sum(1 for q in self.quests if (q["kind"] if key in KIND_NAME else game_key(q)) == key)
            b.setText(f"{name}  {n}")
        self.visible = [q for q in self.quests if on.get(q["kind"], True) and on.get(game_key(q), True)]
        picked = self.map.current.q["id"] if self.map.current is not None else None
        self.map.show_quests(self.visible, self.own_quests(self.quests), story.acts(self.quests))
        if self.search.text():
            self.map.find(self.search.text())
        if picked and picked in self.map.cards:
            self.map.pick(self.map.cards[picked])

    def open_graph(self):
        """The picked quest's graph: the game's own quest file, every block (vanilla_view.py)."""
        card = self.map.current
        path = card.q.get("file") if card is not None else None
        panel = getattr(self.ed, "panel", None)
        if not path or panel is None:
            return None
        from .vanilla_view import VanillaWindow
        w = panel.open_window("Quest graph", "Quest graph", lambda: VanillaWindow(self.ed, path), kind="quest graph")
        if w.body is not None and getattr(w.body, "trail", None) and w.body.trail[0][0] != path:
            w.body.open_path(path)
        return w

    def play_from_here(self):
        """A fresh session from the start picked (sessions.py): no save loaded, the running game's state gone - a
        quick save first while the game is not one of the editor's sessions already."""
        pick = self.starts.currentData()
        link = getattr(self.ed, "link", None)
        if not pick or link is None:
            return None
        from . import sessions
        if not getattr(self.ed, "in_session", False):
            link.exec("cj_quicksave()")
        kind, what = pick
        if kind == "def":
            sessions.start(link, what)
        else:
            sessions.jump(link, *what)
        self.ed.in_session = pick
        return pick

    def world_only(self, world):
        """A fresh session in a world, no story at all: the neutral place to build in."""
        link = getattr(self.ed, "link", None)
        if link is None:
            return None
        from . import sessions
        if not getattr(self.ed, "in_session", False):
            link.exec("cj_quicksave()")
        sessions.jump(link, world)
        self.ed.in_session = ("jump", (world, None, []))
        return world

    def show_quest(self, q):
        self.fact.clear()
        self.graph.setEnabled(bool(q and q.get("file")))
        self.starts.clear()
        from . import sessions
        try:
            defs = sessions.definitions()
        except Exception:                               # noqa: BLE001 - no game files
            defs = []
        own = q is not None and "hook_fact" not in q
        mine = sessions.for_quest(q, defs) if own else []
        for d in mine:                                  # CDPR's own starts of this quest first
            self.starts.addItem(f"{d['name']} · {sessions.world_name(d['world'])}", ("def", d["path"]))
        if own:                                         # then a jump of ours: its world, its act, the facts
            world, entry, facts = sessions.plan(q, {x["id"]: x for x in self.quests})
            self.starts.addItem(f"Jump here · {sessions.world_name(world)}" + (f" · {entry}" if entry else ""),
                                ("jump", (world, entry, facts)))
        for d in sessions.story_starts(defs) if own else []:
            self.starts.addItem(f"{d['name']} · {sessions.world_name(d['world'])}", ("def", d["path"]))
        live = getattr(getattr(self.ed, "link", None), "exec", None) is not None
        self.starts.setEnabled(self.starts.count() > 0)
        self.play.setEnabled(self.starts.count() > 0 and live)
        if q is None:
            n = len(self.visible)
            self.detail.setText(
                f"<b style='color:#f0f0f2;font-size:14px'>The story</b><br>{n} quests shown of {len(self.quests)}."
                "<br><br>Click a quest: everything it waits for lights up in <span style='color:%s'>gold</span>, "
                "everything that waits for it in <span style='color:%s'>blue</span>.<br><br>Then pick the fact "
                "below and <b>Start my quest after this</b> - your quest begins once that quest has set it."
                % (BY, UNLOCKS))
            self.hook.setEnabled(False)
            self.hook_with.setEnabled(False)
            self.fact.setEnabled(False)
            return
        quests = {x["id"]: x for x in self.quests}

        def name(qid):
            x = quests.get(qid)
            return x.get("title") if x else qid.rsplit("\\", 1)[-1]

        def link(qid, colour, why=""):
            hidden = "" if qid in self.map.cards else " <span style='color:#6c6c70'>(hidden)</span>"
            reason = f"<br>&nbsp; &nbsp; <span style='color:#7c7c80'>{why}</span>" if why else ""
            return (f"<br>&nbsp; <span style='color:{colour}'>■</span> <a href='{qid}' style='color:#e8e8ea;"
                    f"text-decoration:none'>{name(qid)}</a>{hidden}{reason}")
        if "hook_fact" in q:                            # the project's own quest
            after = name((q.get("hooks") or [None])[0]) if q.get("hooks") else "the start of the game"
            how = "with" if q.get("hook_when") == "with" and q.get("hooks") else "after"
            self.detail.setText(f"<b style='color:{OWN};font-size:14px'>{q['title']}</b><br>Your quest.<br><br>"
                                f"Starts {how}: <b>{after}</b>" + (f"<br>(fact {q['hook_fact']})" if q.get("hook_fact")
                                                                    else ""))
            self.hook.setEnabled(False)
            self.hook_with.setEnabled(False)
            self.fact.setEnabled(False)
            return
        facts = ", ".join(q.get("gates") or [])
        starts = []
        if q.get("areas"):
            starts.append("in " + ", ".join(a.replace("AN_", "").replace("_", " ") for a in q["areas"]))
        if q.get("items"):
            starts.append("with " + ", ".join(q["items"][:4]))
        if q.get("boards"):
            starts.append("after a notice board")
        if q.get("min_level"):
            starts.append(f"from level {q['min_level']}")
        by = "".join(link(b, BY, (q.get("why") or {}).get(b, "")) for b in q.get("by", [])) \
            or "<br>&nbsp; no other quest - open once its region is"
        unlocks = "".join(link(u, UNLOCKS) for u in q.get("unlocks", [])) or "<br>&nbsp; no quest known"
        region = REGION.get(q.get("world"), "")
        head = " · ".join(x for x in (CARD_KIND.get(q.get("kind"), "Quest"),
                                      f"level {q['level']}" if q.get("level") else "", q.get("act") or "",
                                      region, q.get("game") if q.get("game") != "The Witcher 3" else "") if x)
        self.detail.setText(
            f"<b style='color:#f0f0f2;font-size:14px'>{q.get('title')}</b><br>{head}<br>"
            f"<span style='color:#6c6c70'>{q.get('code') or ''} · {q.get('file')}</span><br><br>"
            f"<b>Waits for</b>{by}" +
            (f"<br>&nbsp; <span style='color:#9a9aa0'>starts {'; '.join(starts)}</span>" if starts else "") +
            (f"<br><span style='color:#6c6c70'>facts: {facts}</span>" if facts else "") +
            f"<br><br><b>Unlocks</b>{unlocks}")
        facts = done_facts(q)
        for f in facts:
            self.fact.addItem(f)
        ok = getattr(self.ed, "project", None) is not None
        self.fact.setEnabled(ok and bool(facts))
        self.hook.setEnabled(ok)
        self.hook_with.setEnabled(ok)

    def hook_game(self, when):
        """The project's quest starts with the picked quest of the game (once it is running) or after it (once it is
        over) - read from the game's journal (quest.game_quest). With the experimental features and a fact chosen,
        after: the older hook on that fact (a moment inside the quest)."""
        card = self.map.current
        project = getattr(self.ed, "project", None)
        if card is None or project is None or "hook_fact" in card.q:
            return
        from . import features, story
        if when == "after" and features.experimental() and self.fact.currentText() and self.fact.currentIndex() > 0:
            self.hook_here()
            return
        entry = story.journal_entry(card.q["id"])
        if entry is None:
            self.detail.setText(self.detail.text() + "<br><br><span style='color:#e57a7a'>The game's journal is "
                                "being read (once, about a minute). Try again in a moment.</span>")
            return
        q = project.meta.setdefault("quest", {})
        for k in ("after", "after_game", "inside_game"):
            q.pop(k, None)
        q["game_quest"] = dict(entry, when=when, id=card.q["id"], title=card.q.get("title") or "")
        project.save_meta()
        self.refresh()
        own = self.map.cards.get(f"{project.id}#own")
        if own is not None:
            self.map.pick(own)
            self.map.centerOn(own)
        if self.on_hook is not None:
            self.on_hook()

    def hook_here(self):
        """The project's quest starts once the picked quest has set the chosen fact (quest.after_game)."""
        card = self.map.current
        project = getattr(self.ed, "project", None)
        if card is None or project is None or not self.fact.currentText():
            return
        q = project.meta.setdefault("quest", {})
        q["after_game"] = {"fact": self.fact.currentText(), "quest": card.q["id"],
                           "title": card.q.get("title") or ""}
        project.save_meta()
        self.refresh()
        own = self.map.cards.get(f"{project.id}#own")
        if own is not None:
            self.map.pick(own)
            self.map.centerOn(own)
