"""The catalog as the editor shows it: a grid of pictures (REDkit's renders, the game's item icons) with search, tabs
and filters - and the inspector next to it: everything known about the chosen thing (plan: docs/catalog-plan.md).

Data: assets.Assets (the asset database). Pictures load in the background and are cached as small PNGs.
"""
import json
import os
import threading

from PySide6 import QtCore, QtGui, QtWidgets

from . import config
from .tooltips import item_tips, tab_tips, tip
from .inline_menu import attach

TILE = 96
PIC_W = 296                     # the inspector's picture
Q = QtCore.Qt
TABS = ["Objects", "Items", "Favourites", "Recent"]
# people, creatures and animals of one name ("Bandit": 200 templates) are one folder: placed, a random one of them
# (Maxim, 01.10.: groups of people or enemies); a double click opens the folder with all of them
FOLDER_CATS = ("People", "Creatures", "Animals")
# whether a person's mouth moves (talking.voice): the badge's colour and the inspector's line
VOICE_COLOUR = {"all": "#5cb85c", "some": "#e3c65f", "none": "#d9534f"}
VOICE_TEXT = {"all": "Can talk (every look moves the mouth)",
              "some": "Some looks stay silent (a speaker needs one that talks, the quest board shows it)",
              "none": "Stays silent (no look moves the mouth)"}
VOICE_LOOK = {"all": "Can talk (this look moves the mouth)", "none": "Stays silent (this look has no moving face)"}
RECENT_MAX = 30


def looks_of(r):
    """The looks the game picks one of when it spawns this person (talking.spawn_looks) - two or more make the
    person a folder of them; [] for one look, not a person, or not read yet."""
    if not r or r.get("cat") != "People":
        return []
    from .talking import spawn_looks
    looks = spawn_looks(r["path"])
    return list(looks) if len(looks) > 1 else []


def is_folder(e):
    """Placing it gives a random one: a folder of variants (members) or of looks (looks)."""
    return bool(e.get("members") or e.get("looks"))


def folder_count(e):
    return len(e.get("members") or e.get("looks") or [])


def voice_of(e):
    """talking.voice of a catalog entry (a folder: of all its variants; a look: 'all' or 'none' for it alone);
    None: not a person, or not read yet."""
    if (e.get("row") or {}).get("cat") != "People":
        return None
    from .talking import known_talking, voices
    if "look" in e:
        talks = known_talking(e["path"])
        return None if talks is None else "all" if e["look"] in talks else "none"
    return voices(e.get("members") or [e["path"]])


def mosaic(files, size, out):
    """Up to four pictures in a 2 x 2 mosaic of `size` px -> out (a png), or None without pictures."""
    from PIL import Image
    pics = [Image.open(f).convert("RGBA") for f in files[:4]]
    if not pics:
        return None
    gap = max(2, size // 48)
    cell = (size - gap) // 2
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    n = len(pics)
    for k, im in enumerate(pics):
        im.thumbnail((cell, cell))
        cx, cy = (k % 2) * (cell + gap), (k // 2) * (cell + gap)
        if n == 1:                                      # one: in the middle
            cx, cy = (size - cell) // 2, (size - cell) // 2
        elif n == 2:                                    # two: side by side, in the middle (Maxim 08.10.)
            cy = (size - cell) // 2
        elif n == 3 and k == 2:                         # three: two above, the third in the middle below
            cx = (size - cell) // 2
        canvas.paste(im, (cx + (cell - im.width) // 2, cy + (cell - im.height) // 2), im)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    canvas.save(out)
    return out


def _mosaic_file(files, size):
    import hashlib
    from .assets import THUMBS
    return os.path.join(THUMBS, "folders", str(size),
                        hashlib.md5("|".join(files).encode("utf-8")).hexdigest()[:16] + ".png")


def folder_picture(assets, members, size):
    """A folder of variants: up to four of them side by side (different pictures, the first ones that have one) -
    a file in the thumbnail cache, or None."""
    import hashlib
    out = _mosaic_file(members, size)
    if os.path.exists(out):
        return out
    files, seen = [], set()
    for m in members[:16]:
        p = assets.thumbnail(m, 128 if size <= 128 else 320)
        if not p:
            continue
        h = hashlib.md5(open(p, "rb").read()).hexdigest()
        if h not in seen:
            seen.add(h)
            files.append(p)
        if len(files) == 4:
            break
    return mosaic(files, size, out)


def entry_picture(pictures, assets, e, size, paint=False):
    """The picture of a catalog entry (a QPixmap, or None while it is made). A look: its tile (look_chooser draws
    it); a folder of looks: up to four of them once drawn (`paint`: have them drawn now), else the person's picture."""
    from .look_chooser import cache_file, painter
    key = f"{e['key']}@{size}"
    px = 128 if size <= 128 else 320
    if e["type"] == "item":
        return pictures.get(key, lambda: assets.icon(e["row"]))
    if e.get("members"):
        return pictures.get(key, lambda: folder_picture(assets, e["members"], px))
    if "look" in e:
        f = cache_file(e["path"], e["look"])
        if os.path.exists(f):
            return pictures.get(key, lambda: f)
        painter().want(e["path"], e["look"])
        return None
    if e.get("looks"):
        files = [cache_file(e["path"], lk) for lk in e["looks"]]
        have = [f for f in files if os.path.exists(f)]
        if paint:
            for lk, f in list(zip(e["looks"], files))[:4]:
                if not os.path.exists(f):
                    painter().want(e["path"], lk)
        if len(have) >= min(2, len(files)):
            return pictures.get(key, lambda: mosaic(have, px, _mosaic_file(have[:4], px)))
    return pictures.get(key, lambda: assets.thumbnail(e.get("mesh") or e["path"], px))


def look_painted(pictures, template, look):
    """A look's tile was drawn: its entry and its folder's picture are made again."""
    for size in (64, 128, 320):
        for k in (f"{template}#{look}@{size}", f"{template}@{size}"):
            if pictures.cache.pop(k, None) is not None:
                pictures.ready.emit(k)


def folder_text(e):
    """What placing a folder does (Maxim 08.10.: it must be clear that a random one is placed)."""
    if e.get("members"):
        return (f"Places a random variant ({len(e['members'])} in this folder), each with a random look. Double click "
                "to open the folder for a specific variant")
    return (f"Places this person with a random look ({len(e['looks'])} looks). Double click to open the folder for "
            "a specific look")
# how the assets are shown (Maxim 05.10.: the Asset Browser with the useful view modes of Windows Explorer - docked
# at a side there is not much room): id, label, picture size
VIEWS = [("xl", "Extra large icons", 192), ("large", "Large icons", 128), ("medium", "Medium icons", 96),
         ("small", "Small icons", 32), ("list", "List", 20), ("details", "Details", 20), ("tiles", "Tiles", 64)]
VIEW_SIZE = {k: s for k, _l, s in VIEWS}
SORTS = [("found", "Best match"), ("name", "Name"), ("kind", "Kind"), ("recent", "Recently used")]
SHORT = {"xl": "XL", "large": "Large", "medium": "Medium", "small": "Small", "list": "List", "details": "Details",
         "tiles": "Tiles", "found": "Best", "name": "Name", "kind": "Kind", "recent": "Recent"}
NARROW = 560                    # px: narrower than this, the category tree folds away by itself (with it
                                # shown the browser needs ~490: below the threshold, or it would never fold)


# --- pictures in the background
class _Job(QtCore.QRunnable):
    def __init__(self, loader, key, fn):
        super().__init__()
        self.loader, self.key, self.fn = loader, key, fn

    def run(self):
        try:
            path = self.fn()
        except Exception:                           # noqa: BLE001 - no picture then
            path = None
        self.loader.done.emit(self.key, path or "")


class PictureLoader(QtCore.QObject):
    """key -> QPixmap, loaded once in a thread pool; `ready(key)` when one arrived."""
    done = QtCore.Signal(str, str)
    ready = QtCore.Signal(str)

    def __init__(self):
        super().__init__()
        self.pool = QtCore.QThreadPool()
        self.pool.setMaxThreadCount(4)
        self.cache, self.pending = {}, set()
        self.done.connect(self._done)

    def get(self, key, fn):
        if key in self.cache:
            return self.cache[key]
        if key not in self.pending:
            self.pending.add(key)
            self.pool.start(_Job(self, key, fn))
        return None

    def _done(self, key, path):
        self.pending.discard(key)
        self.cache[key] = QtGui.QPixmap(path) if path else QtGui.QPixmap()
        self.ready.emit(key)


# --- the grid
PAGE = 300                      # entries shown at first; scrolled to the end, the next ones (Maxim 06.10.: only a
                                # page at a time - it showed at most 400, the rest never)


class Model(QtCore.QAbstractListModel):
    """The grid's entries, a page at a time: `rows` what is shown, `all` everything found; the view asks for more
    (fetchMore) when it is scrolled to the end."""

    def __init__(self, view):
        super().__init__()
        self.view, self.rows, self.all, self.at = view, [], [], {}
        view.pictures.ready.connect(self._picture)

    def set_rows(self, rows):
        self.beginResetModel()
        self.all = rows
        self.rows = rows[:PAGE]
        self.at = {e["key"]: i for i, e in enumerate(self.rows)}
        self.endResetModel()

    def canFetchMore(self, parent=QtCore.QModelIndex()):
        return not parent.isValid() and len(self.rows) < len(self.all)

    def fetchMore(self, parent=QtCore.QModelIndex()):
        if parent.isValid():
            return
        n = len(self.rows)
        more = self.all[n:n + PAGE]
        if not more:
            return
        self.beginInsertRows(QtCore.QModelIndex(), n, n + len(more) - 1)
        self.rows = self.rows + more
        for i, e in enumerate(more, n):
            self.at[e["key"]] = i
        self.endInsertRows()

    def rowCount(self, parent=QtCore.QModelIndex()):
        return 0 if parent.isValid() else len(self.rows)

    def data(self, index, role=Q.DisplayRole):
        e = self.rows[index.row()]
        if role == Q.DisplayRole:
            return e["title"]
        if role == Q.ToolTipRole:
            r = e.get("row") or {}
            what = " / ".join(x for x in (r.get("cat"), r.get("sub")) if x)
            lines = [what or e.get("sub") or e.get("path") or e.get("name")]
            if is_folder(e):
                lines.append(folder_text(e))
            v = voice_of(e)
            if v and v != "some":                   # (some talk, some not: the folder's yellow mark, the guide)
                lines.append(VOICE_TEXT[v])
            return "\n".join(lines)
        if role == Q.UserRole:
            return e
        if role == Q.DecorationRole:
            return self.view.picture(e, 320 if VIEW_SIZE[self.view.mode] > 128 else 128)
        return None

    def _picture(self, key):
        base = key.rsplit("@", 1)[0]                # picture keys are "<entry key>@<size>"
        i = self.at.get(base)
        if i is not None and i < len(self.rows):
            ix = self.index(i)
            self.dataChanged.emit(ix, ix, [Q.DecorationRole])


class DetailsModel(QtCore.QAbstractTableModel):
    """The Details view: the same entries as a table - name, kind, from where, traits, file."""
    COLUMNS = ["Name", "Kind", "From", "Traits", "File"]

    def __init__(self, view):
        super().__init__()
        self.view = view

    def rowCount(self, parent=QtCore.QModelIndex()):
        return 0 if parent.isValid() else len(self.view.model.rows)

    def columnCount(self, parent=QtCore.QModelIndex()):
        return len(self.COLUMNS)

    def headerData(self, section, orientation, role=Q.DisplayRole):
        if role == Q.DisplayRole and orientation == Q.Horizontal:
            return self.COLUMNS[section]
        return None

    @staticmethod
    def text(e, col):
        row = e.get("row") or {}
        if col == 0:
            return e["title"]
        if col == 1:
            return " / ".join(v for v in (row.get("cat"), row.get("sub")) if v) or e.get("sub") or ""
        if col == 2:
            return row.get("source") or os.path.basename(row.get("file") or "")
        if col == 3:
            return ", ".join(row.get("traits") or [])
        return e.get("path") or e.get("name") or ""

    def data(self, index, role=Q.DisplayRole):
        e = self.view.model.rows[index.row()]
        if role == Q.DisplayRole:
            return self.text(e, index.column())
        if role == Q.UserRole:
            return e
        if role == Q.DecorationRole and index.column() == 0:
            pix = self.view.picture(e, 128)
            if isinstance(pix, QtGui.QPixmap) and not pix.isNull():
                return pix.scaled(20, 20, Q.KeepAspectRatio, Q.SmoothTransformation)
            return None
        if role == Q.ToolTipRole:
            return self.text(e, 4)
        return None

    def sort(self, column, order=Q.AscendingOrder):
        """A click on a column's head: the entries by it (the grid and the table show the same order)."""
        rows = list(self.view.model.rows)
        rows.sort(key=lambda e: self.text(e, column).lower(), reverse=order == Q.DescendingOrder)
        self.view.model.set_rows(rows)
        self.layoutChanged.emit()


class Tile(QtWidgets.QStyledItemDelegate):
    """Picture, name (two lines) and small badges: inventory, lootable, favourite - laid out for the view mode
    (icons of three sizes, small icons, list, tiles)."""

    def __init__(self, view, parent=None):
        super().__init__(parent)
        self.view = view

    def sizeHint(self, option, index):
        mode = self.view.mode
        if mode == "small":
            return QtCore.QSize(236, 40)
        if mode == "list":
            return QtCore.QSize(250, 24)
        if mode == "tiles":
            return QtCore.QSize(300, 80)
        t = VIEW_SIZE[mode]
        return QtCore.QSize(t + 16, t + 44)

    @staticmethod
    def _frame(p, option, r):
        sel = option.state & QtWidgets.QStyle.State_Selected
        hover = option.state & QtWidgets.QStyle.State_MouseOver
        p.setPen(QtGui.QPen(QtGui.QColor("#c8c8c8" if sel else "#555" if hover else "#333"), 1))
        p.setBrush(QtGui.QColor("#4b4b50" if sel else "#232326"))
        p.drawRect(r)

    @staticmethod
    def _talks(e):
        """A person: talking.voice - 'all' (every look the game may give them can talk), 'some', 'none'; None (not
        a person, or not read yet). A folder: of all its variants together."""
        return voice_of(e)

    @classmethod
    def _talk_badge(cls, p, e, x, y, size):
        """The speech badge (as a voiced line's): green, every look can talk; yellow, some looks cannot; red, none
        can (Maxim 08.10.: a folder showed green though looks in it could not talk)."""
        talks = cls._talks(e)
        if talks is not None:
            from .icons import pixmap
            # a dark box behind it: it stays readable on a light picture (Maxim 08.10.: white backgrounds hid it)
            pad = max(2, size // 6)
            p.save()
            p.setPen(Q.NoPen)
            p.setBrush(QtGui.QColor(20, 20, 22, 170))
            p.drawRoundedRect(QtCore.QRectF(x - pad, y - pad, size + 2 * pad, size + 2 * pad), pad + 1, pad + 1)
            p.restore()
            p.drawPixmap(x, y, pixmap("audio-lines-x" if talks == "none" else "audio-lines", VOICE_COLOUR[talks], size))

    @staticmethod
    def _pic(p, pix, box):
        if isinstance(pix, QtGui.QPixmap) and not pix.isNull():
            s = pix.scaled(box.size(), Q.KeepAspectRatio, Q.SmoothTransformation)
            p.drawPixmap(box.x() + (box.width() - s.width()) // 2, box.y() + (box.height() - s.height()) // 2, s)
        else:
            p.setPen(QtGui.QColor("#555"))
            p.drawText(box, Q.AlignCenter, "...")

    def _row(self, p, option, index):
        """small / list / tiles: the picture on the left, the words beside it."""
        e, mode = index.data(Q.UserRole), self.view.mode
        r = option.rect.adjusted(2, 1, -2, -1)
        p.save()
        if mode == "list":                          # no frame: a list reads as lines
            sel = option.state & QtWidgets.QStyle.State_Selected
            if sel or option.state & QtWidgets.QStyle.State_MouseOver:
                p.setPen(QtGui.QPen(QtGui.QColor("#4b4b50" if sel else "#444"), 1))
                p.setBrush(QtGui.QColor("#4b4b50" if sel else "#26262a"))
                p.drawRect(r)
        else:
            self._frame(p, option, r)
        size = VIEW_SIZE[mode]
        box = QtCore.QRect(r.x() + 3, r.y() + (r.height() - size) // 2, size, size)
        self._pic(p, index.data(Q.DecorationRole), box)
        f = p.font()
        f.setPointSizeF(8.5)
        x, w = box.right() + 8, r.right() - box.right() - 12
        fm = QtGui.QFontMetrics(f)
        if mode == "tiles":
            f.setBold(True)
            p.setFont(f)
            p.setPen(QtGui.QColor("#eee"))
            p.drawText(QtCore.QRect(x, r.y() + 6, w, fm.height()), Q.AlignLeft,
                       QtGui.QFontMetrics(f).elidedText(e["title"], Q.ElideRight, w))
            f.setBold(False)
            p.setFont(f)
            row = e.get("row") or {}
            kind = " / ".join(v for v in (row.get("cat"), row.get("sub")) if v) or e.get("sub") or ""
            traits = ", ".join(row.get("traits") or [])
            for k, (text, colour) in enumerate(((kind, "#a8a8ac"), (traits, "#7c7c80"))):
                p.setPen(QtGui.QColor(colour))
                p.drawText(QtCore.QRect(x, r.y() + 8 + fm.height() * (k + 1), w, fm.height()), Q.AlignLeft,
                           fm.elidedText(text, Q.ElideRight, w))
        else:
            p.setFont(f)
            p.setPen(QtGui.QColor("#eee"))
            text = e["title"] if mode == "list" or not e.get("sub") else f"{e['title']}  ·  {e['sub']}"
            p.drawText(QtCore.QRect(x, r.y(), w, r.height()), Q.AlignLeft | Q.AlignVCenter,
                       fm.elidedText(text, Q.ElideRight, w))
        if e.get("fav"):
            star_icon(True).paint(p, QtCore.QRect(r.right() - 18, r.y() + (r.height() - 14) // 2, 14, 14))
        self._talk_badge(p, e, r.right() - (38 if e.get("fav") else 20), r.y() + (r.height() - 16) // 2, 16)
        p.restore()

    def paint(self, p, option, index):
        if self.view.mode in ("small", "list", "tiles"):
            self._row(p, option, index)
            return
        e = index.data(Q.UserRole)
        TILE = VIEW_SIZE[self.view.mode]
        r = option.rect.adjusted(3, 3, -3, -3)
        p.save()
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        folder = is_folder(e)
        if folder:                                  # a folder: a tab on top, a warm frame (Maxim 08.10.)
            sel = option.state & QtWidgets.QStyle.State_Selected
            edge = QtGui.QColor("#e3c65f" if sel else "#a8924f")
            p.setPen(QtGui.QPen(edge, 1))
            p.setBrush(QtGui.QColor("#3a3322" if sel else "#2a261b"))
            tab = QtGui.QPolygon([QtCore.QPoint(r.x(), r.y() + 7), QtCore.QPoint(r.x() + 4, r.y()),
                                  QtCore.QPoint(r.x() + r.width() * 2 // 5, r.y()),
                                  QtCore.QPoint(r.x() + r.width() * 2 // 5 + 7, r.y() + 7)])
            p.drawPolygon(tab)
            r = r.adjusted(0, 7, 0, 0)
            p.drawRect(r)
        else:
            self._frame(p, option, r)
        pix = index.data(Q.DecorationRole)
        size = TILE - (8 if folder else 0)
        box = QtCore.QRect(r.x() + (r.width() - size) // 2, r.y() + 4, size, size)
        if isinstance(pix, QtGui.QPixmap) and not pix.isNull():
            s = pix.scaled(box.size(), Q.KeepAspectRatio, Q.SmoothTransformation)
            p.drawPixmap(box.x() + (size - s.width()) // 2, box.y() + (size - s.height()) // 2, s)
        else:
            p.setPen(QtGui.QColor("#555"))
            p.drawText(box, Q.AlignCenter, "...")
        p.setPen(QtGui.QColor("#eee"))
        f = p.font()
        f.setPointSizeF(8.5)
        p.setFont(f)
        fm = p.fontMetrics()
        line = fm.height()
        w = r.width() - 8
        p.drawText(QtCore.QRect(r.x() + 4, box.bottom() + 3, w, line), Q.AlignHCenter,
                   fm.elidedText(e["title"], Q.ElideRight, w))
        if e.get("sub"):
            p.setPen(QtGui.QColor("#8a8a8a"))
            p.drawText(QtCore.QRect(r.x() + 4, box.bottom() + 3 + line, w, line), Q.AlignHCenter,
                       fm.elidedText(e["sub"], Q.ElideMiddle, w))
        if e.get("fav"):
            star_icon(True).paint(p, QtCore.QRect(r.right() - 22, r.y() + 4, 18, 18))
        if "clue" in ((e.get("row") or {}).get("traits") or []):    # glows in the witcher senses
            from .icons import pixmap
            p.drawPixmap(r.right() - 21, r.bottom() - 62, pixmap("scan-eye", "#d9534f", 16))
        if folder:                                  # how many are in it (the dice is on Place random)
            n = f"{folder_count(e)}"
            bf = p.font()
            bf.setBold(True)
            p.setFont(bf)
            w = p.fontMetrics().horizontalAdvance(n) + 12
            pill = QtCore.QRect(box.right() - w - 2, box.bottom() - 20, w, 18)
            p.setPen(Q.NoPen)
            p.setBrush(QtGui.QColor("#e3c65f"))
            p.drawRoundedRect(pill, 9, 9)
            p.setPen(QtGui.QColor("#1d1d1f"))
            p.drawText(pill, Q.AlignCenter, n)
            bf.setBold(False)
            p.setFont(bf)
        self._talk_badge(p, e, r.x() + 5, r.y() + 5, 18)
        p.restore()


class Flow(QtWidgets.QLayout):
    """Widgets in rows that wrap (the chips)."""

    def __init__(self, parent=None, spacing=4):
        super().__init__(parent)
        self.items, self.gap = [], spacing
        self.setContentsMargins(0, 0, 0, 0)

    def addItem(self, item):
        self.items.append(item)

    def count(self):
        return len(self.items)

    def itemAt(self, i):
        return self.items[i] if 0 <= i < len(self.items) else None

    def takeAt(self, i):
        return self.items.pop(i) if 0 <= i < len(self.items) else None

    def hasHeightForWidth(self):
        return True

    def heightForWidth(self, w):
        return self._do(QtCore.QRect(0, 0, w, 0), True)

    def setGeometry(self, rect):
        super().setGeometry(rect)
        self._do(rect, False)

    def sizeHint(self):
        return self.minimumSize()

    def minimumSize(self):
        s = QtCore.QSize()
        for it in self.items:
            s = s.expandedTo(it.minimumSize())
        return s

    def _do(self, rect, test):
        x, y, line = rect.x(), rect.y(), 0
        for it in self.items:
            if it.widget() and it.widget().isHidden():
                continue
            hint = it.sizeHint()
            if x + hint.width() > rect.right() and line:
                x, y, line = rect.x(), y + line + self.gap, 0
            if not test:
                it.setGeometry(QtCore.QRect(QtCore.QPoint(x, y), hint))
            x += hint.width() + self.gap
            line = max(line, hint.height())
        return y + line - rect.y()


CHIP = ("QToolButton{color:#ccc;background:#262629;border:1px solid #444;border-radius:0;padding:2px 8px;"
        "font:11px}QToolButton:hover{border-color:#777}"
        "QToolButton:checked{color:#fff;background:#4b4b50;border-color:#c8c8c8}")
TREE = ("QTreeWidget{background:#1c1c1f;border:1px solid #333;border-radius:0;color:#ddd;font:12px}"
        "QTreeWidget::item{padding:2px 0}QTreeWidget::item:selected{background:#4b4b50;color:#fff}"
        "QTreeWidget::item:hover{background:#29292d}")
TRAITS = [("clue", "Clue", ""), ("interior", "Interior", ""), ("inventory", "Inventory", ""), ("lootable", "Lootable", ""), ("usable", "Usable", ""),
          ("light", "Light", ""),
          ("destructible", "Destructible", ""), ("named", "Named", ""),
          ("pack", "Content packs", "")]          # things of the content packs in the game (assets._merge_packs)


class Chip(QtWidgets.QToolButton):
    """A filter chip: left click picks only this one (again: none), right click adds it or takes it out."""
    picked = QtCore.Signal(bool)                # add (right click) or only (left click)

    def __init__(self, text=""):
        super().__init__()
        self.setText(text)
        self.setCheckable(True)
        self.setStyleSheet(CHIP)

    def mousePressEvent(self, ev):
        if ev.button() in (Q.LeftButton, Q.RightButton):
            self.picked.emit(ev.button() == Q.RightButton)
            ev.accept()
            return
        super().mousePressEvent(ev)

    def mouseReleaseEvent(self, ev):
        ev.accept()                             # the choice happened on press; no toggling by Qt


TAG = ("QToolButton{color:#cfcfcf;background:#262629;border:1px solid #555;border-radius:0;padding:1px 6px;"
       "font:11px}QToolButton:hover{border-color:#aaa;color:#fff}")


class CatalogView(QtWidgets.QWidget):
    """Search, tabs, the type tree, style and trait chips, the grid. `current(entry)` on selection, `chosen(entry)`
    on double click / Enter. Every count shows what a choice would give with the other choices kept."""
    current = QtCore.Signal(dict)
    chosen = QtCore.Signal(dict)

    def __init__(self, editor, assets):
        super().__init__()
        self.ed, self.assets = editor, assets
        self.pictures = PictureLoader()
        from .look_chooser import painter
        painter().painted.connect(lambda t, lk, _p: look_painted(self.pictures, t, lk))
        cfg = config.load()
        self.favourites = list(cfg.get("favourites", []))
        self.recent = list(cfg.get("recent_templates", []))
        self.cat = self.sub = None                  # the chosen branch of the tree
        self.folder = None                          # an open folder: (cat, name) - its variants one by one
        self.look_folder = None                     # an open person: (template) - its looks one by one
        self.hide = None                            # (row) -> True: not offered here (a chooser's: Geralt's stash)
        self._picked_member = {}                    # a folder's picture: one of its members, the same while open
        self.history = []                           # overviews opened from the inspector: the way back
        self.styles, self.traits = set(), set()
        self.mode = cfg.get("asset_view") if cfg.get("asset_view") in VIEW_SIZE else "medium"
        self.sort_by = cfg.get("asset_sort", "found")
        self.nav_wanted = bool(cfg.get("asset_nav", True))     # the category tree, when there is room
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 6, 0, 0)
        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText("Search")
        self.search.setClearButtonEnabled(True)
        tip(self.search, "cat.search")
        self.search.textChanged.connect(self.refresh)   # (a refresh takes ~20 ms: at every letter)
        self.search.returnPressed.connect(self._enter)
        v.addWidget(self.search)
        self.tabs = QtWidgets.QTabBar()
        for t in TABS:
            self.tabs.addTab(t)
        self.tabs.setExpanding(False)
        self.tabs.setUsesScrollButtons(True)            # (narrow, docked at a side: the tabs scroll)
        self.tabs.setSizePolicy(QtWidgets.QSizePolicy.Ignored, QtWidgets.QSizePolicy.Fixed)
        tab_tips(self.tabs, ["cat.tab.objects", "cat.tab.items", "cat.tab.favourites", "cat.tab.recent"])
        self.tabs.currentChanged.connect(self._tab)
        v.addWidget(self.tabs)
        body = QtWidgets.QHBoxLayout()
        body.setSpacing(6)
        v.addLayout(body, 1)
        # left: what it is
        self.tree = QtWidgets.QTreeWidget()
        self.tree.setHeaderHidden(True)
        self.tree.setColumnCount(2)
        self.tree.setIndentation(12)
        self.tree.setRootIsDecorated(True)
        self.tree.setFixedWidth(196)
        self.tree.setStyleSheet(TREE)
        tip(self.tree, "cat.tree")
        self.tree.header().setStretchLastSection(False)
        self.tree.header().setSectionResizeMode(0, QtWidgets.QHeaderView.Stretch)
        self.tree.header().setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeToContents)
        self.tree.itemClicked.connect(self._tree_clicked)
        body.addWidget(self.tree)
        self.body = body
        right = QtWidgets.QVBoxLayout()
        right.setSpacing(4)
        body.addLayout(right, 1)
        self.crumb = QtWidgets.QLabel()
        self.crumb.setTextFormat(Q.RichText)
        self.crumb.linkActivated.connect(self._crumb)
        self.crumb.setStyleSheet("color:#aaa;font:12px")
        self.crumb.setSizePolicy(QtWidgets.QSizePolicy.Ignored, QtWidgets.QSizePolicy.Preferred)
        self.crumb.setMinimumWidth(40)
        tip(self.crumb, "cat.crumb")
        # the style and trait chips folded away behind "Filters" (02.10.: four rows of chips before the first thing)
        self.filters_open = bool(config.load().get("catalog_filters_open", False))
        self.filter_b = QtWidgets.QToolButton()
        self.filter_b.setObjectName("chip")
        self.filter_b.setCheckable(True)
        self.filter_b.setChecked(self.filters_open)
        self.filter_b.setText("Filters")
        self.filter_b.clicked.connect(self._toggle_filters)
        tip(self.filter_b, "cat.filters")
        crumb_row = QtWidgets.QHBoxLayout()
        # the Explorer's ribbon, small: the category tree on / off, the view, the order
        self.nav_b = QtWidgets.QToolButton()
        self.nav_b.setObjectName("chip")
        self.nav_b.setCheckable(True)
        from .icons import icon
        self.nav_b.setIcon(icon("folder"))
        self.nav_b.setIconSize(QtCore.QSize(14, 14))
        self.nav_b.clicked.connect(self._toggle_nav)
        tip(self.nav_b, "cat.nav")
        crumb_row.addWidget(self.nav_b)
        crumb_row.addWidget(self.crumb, 1)
        crumb_row.addWidget(self.filter_b)
        self.view_b = QtWidgets.QToolButton()
        self.view_b.setObjectName("chip")
        vm = QtWidgets.QMenu(self.view_b)
        vm.aboutToShow.connect(lambda: self._fill_view_menu(vm))
        attach(self.view_b, vm)
        tip(self.view_b, "cat.view")
        crumb_row.addWidget(self.view_b)
        self.sort_b = QtWidgets.QToolButton()
        self.sort_b.setObjectName("chip")
        sm = QtWidgets.QMenu(self.sort_b)
        sm.aboutToShow.connect(lambda: self._fill_sort_menu(sm))
        attach(self.sort_b, sm)
        tip(self.sort_b, "cat.sort")
        crumb_row.addWidget(self.sort_b)
        for b in (self.nav_b, self.view_b, self.sort_b):    # (little padding: room when docked narrow)
            b.setObjectName("mini")
            b.setStyleSheet("QToolButton#mini{color:#ccc;background:#262629;border:1px solid #444;padding:2px 6px;"
                            "font:12px}QToolButton#mini:checked{background:#4b4b50;border-color:#c8c8c8;color:#fff}"
                            "QToolButton#mini::menu-indicator{width:0;image:none}")
        right.addLayout(crumb_row)
        # styles and traits: chips that wrap, with counts
        self.style_box = QtWidgets.QWidget()
        self.style_flow = Flow(self.style_box)
        right.addWidget(self.style_box)
        self.trait_box = QtWidgets.QWidget()
        self.trait_flow = Flow(self.trait_box)
        self.trait_chips = {}
        for key, label, _text in TRAITS:
            b = self._chip(label, "cat.trait")
            b.picked.connect(lambda add, k=key: self._pick(self.traits, k, add))
            self.trait_flow.addWidget(b)
            self.trait_chips[key] = (b, label)
        self.quest_chip = self._chip("+ quest things", "cat.quest")
        self.quest_chip.picked.connect(lambda _add: (self.quest_chip.setChecked(not self.quest_chip.isChecked()),
                                                     self.refresh()))
        self.trait_flow.addWidget(self.quest_chip)
        right.addWidget(self.trait_box)
        self.style_box.setVisible(self.filters_open)
        self.trait_box.setVisible(self.filters_open)
        self.style_chips = {}
        self.grid = QtWidgets.QListView()
        self.grid.setViewMode(QtWidgets.QListView.IconMode)
        self.grid.setResizeMode(QtWidgets.QListView.Adjust)
        self.grid.setMovement(QtWidgets.QListView.Static)
        self.grid.setUniformItemSizes(True)
        self.grid.setLayoutMode(QtWidgets.QListView.Batched)    # the first tiles at once, the rest after (06.10.)
        self.grid.setBatchSize(300)
        self.grid.setSpacing(2)
        self.grid.setMouseTracking(True)
        self.grid.setItemDelegate(Tile(self, self.grid))
        # dark on its own (no dark palette in Conjunction: on a light Windows the list's white showed through)
        self.grid.setStyleSheet("QListView{background:#1b1b1e;border:1px solid #333}")
        self.grid.viewport().installEventFilter(self)       # Ctrl + wheel: the next view, as in Explorer
        item_tips(self.grid)
        self.grid.setVerticalScrollMode(QtWidgets.QAbstractItemView.ScrollPerPixel)
        self.model = Model(self)
        self.grid.setModel(self.model)
        self.grid.selectionModel().currentChanged.connect(self._current)
        self.grid.doubleClicked.connect(self._activate)
        self.grid.activated.connect(self._activate)
        right.addWidget(self.grid, 1)
        self.table = QtWidgets.QTreeView()                  # the Details view
        self.table.setRootIsDecorated(False)
        self.table.setUniformRowHeights(True)
        self.table.setSortingEnabled(True)
        self.table.setAllColumnsShowFocus(True)
        self.table.setIconSize(QtCore.QSize(20, 20))
        self.table.setStyleSheet(TREE.replace("QTreeWidget", "QTreeView") +
                                 "QHeaderView::section{background:#26262a;color:#9a9aa0;border:none;"
                                 "border-right:1px solid #3c3c42;padding:3px 6px;font:11px}")
        self.details = DetailsModel(self)
        self.table.setModel(self.details)
        self.table.header().setSortIndicatorShown(True)
        self.table.header().setStretchLastSection(True)
        for col, width in enumerate((200, 170, 90, 150)):
            self.table.setColumnWidth(col, width)
        self.table.selectionModel().currentChanged.connect(self._current)
        self.table.doubleClicked.connect(self._activate)
        self.table.viewport().installEventFilter(self)
        right.addWidget(self.table, 1)
        self.count = QtWidgets.QLabel("")
        self.count.setStyleSheet("color:#888")
        right.addWidget(self.count)
        self.set_view(self.mode, keep=False)
        self.refresh()

    # --- the view (Explorer's view modes), the order, the category tree
    def set_view(self, mode, keep=True):
        self.mode = mode
        details = mode == "details"
        if not details:
            listing = mode == "list"
            self.grid.setViewMode(QtWidgets.QListView.ListMode if listing else QtWidgets.QListView.IconMode)
            self.grid.setFlow(QtWidgets.QListView.TopToBottom if listing else QtWidgets.QListView.LeftToRight)
            self.grid.setWrapping(True)
            self.grid.setResizeMode(QtWidgets.QListView.Adjust)
            self.grid.setMovement(QtWidgets.QListView.Static)
            self.grid.setSpacing(1 if listing else 2)
            self.grid.doItemsLayout()
        self.grid.setVisible(not details)
        self.table.setVisible(details)
        self.view_b.setText(SHORT[mode] + "  ▾")
        if keep:
            cfg = config.load()
            cfg["asset_view"] = mode
            config.save(cfg)
        self.grid.viewport().update()

    def _fill_view_menu(self, menu):
        menu.clear()
        for k, label, _s in VIEWS:
            a = menu.addAction(label, lambda m=k: self.set_view(m))
            a.setCheckable(True)
            a.setChecked(k == self.mode)

    def _fill_sort_menu(self, menu):
        menu.clear()
        for k, label in SORTS:
            a = menu.addAction(label, lambda m=k: self._set_sort(m))
            a.setCheckable(True)
            a.setChecked(k == self.sort_by)

    def _set_sort(self, key):
        self.sort_by = key
        cfg = config.load()
        cfg["asset_sort"] = key
        config.save(cfg)
        self.refresh()

    def _sorted(self, rows):
        if self.sort_by == "name":
            return sorted(rows, key=lambda e: e["title"].lower())
        if self.sort_by == "kind":
            return sorted(rows, key=lambda e: (DetailsModel.text(e, 1).lower(), e["title"].lower()))
        if self.sort_by == "recent":
            order = {k: i for i, k in enumerate(self.recent)}
            return sorted(rows, key=lambda e: order.get(e["key"], len(order)))
        return rows

    def _toggle_nav(self):
        if self.width() < NARROW:               # narrow: the tree instead of the grid until a branch is chosen
            self.narrow_nav = self.nav_b.isChecked()
            self._sync_nav()
            return
        self.nav_wanted = self.nav_b.isChecked()
        cfg = config.load()
        cfg["asset_nav"] = self.nav_wanted
        config.save(cfg)
        self._sync_nav()

    def _sync_nav(self):
        """The category tree: when wanted and there is room. Docked narrow at a side it folds away by itself; the
        folder button then shows it in the grid's place until a branch is chosen (06.10.: narrow, the tree could
        not be reached - no Chests, no other branch)."""
        has_tree = getattr(self, "_has_tree", True)
        room = self.width() >= NARROW
        narrow_nav = not room and has_tree and getattr(self, "narrow_nav", False)
        self.tree.setVisible(has_tree and (self.nav_wanted and room or narrow_nav))
        if narrow_nav:                          # the whole width (the grid is away)
            self.tree.setMinimumWidth(0)
            self.tree.setMaximumWidth(16777215)
        else:
            self.tree.setFixedWidth(196)
        if hasattr(self, "body"):
            self.body.setStretch(0, 1 if narrow_nav else 0)         # the tree, and the grid's side
            self.body.setStretch(1, 0 if narrow_nav else 1)
        details = self.mode == "details"
        self.grid.setVisible(not narrow_nav and not details)
        self.table.setVisible(not narrow_nav and details)
        self.nav_b.setChecked(self.nav_wanted and room or narrow_nav)
        self.nav_b.setVisible(has_tree)

    def resizeEvent(self, ev):
        super().resizeEvent(ev)
        self._sync_nav()

    def eventFilter(self, obj, ev):
        if ev.type() == QtCore.QEvent.Wheel and ev.modifiers() & Q.ControlModifier:
            order = [k for k, _l, _s in VIEWS]
            step = -1 if ev.angleDelta().y() > 0 else 1     # wheel up: bigger, as in Explorer
            self.set_view(order[max(0, min(len(order) - 1, order.index(self.mode) + step))])
            return True
        return super().eventFilter(obj, ev)

    def _chip(self, text, key=""):
        b = Chip(text)
        if key:
            tip(b, key)
        return b

    # --- pictures
    def picture(self, e, size):
        return entry_picture(self.pictures, self.assets, e, size, paint=True)

    # --- choosing a branch, a style, a trait
    def _tab(self, _i):
        self.cat = self.sub = None
        self.refresh()

    def _tree_clicked(self, item, _col=0):
        cat, sub = item.data(0, Q.UserRole)
        if (cat, sub) == (self.cat, self.sub) and sub is None and cat is not None:
            item.setExpanded(not item.isExpanded())
        self.cat, self.sub = cat, sub
        # narrow: a branch with nothing below it brings the grid back (one with branches opens; the folder button
        # shows the grid for the whole branch)
        if getattr(self, "narrow_nav", False) and item.childCount() == 0:
            self.narrow_nav = False
        self.refresh()

    def _crumb(self, link):
        if link == "back":
            self.back()
            return
        if link == "all":
            self.cat = self.sub = None
        elif link == "cat":
            self.sub = None
        self.refresh()

    def _pick(self, target, key, add):
        """Left click: only this one (the only one again: none). Right click: add it or take it out."""
        if add:
            (target.discard if key in target else target.add)(key)
        elif target == {key}:
            target.clear()
        else:
            target.clear()
            target.add(key)
        self.refresh()

    # --- an overview of one kind (a chip of the inspector): everything of it, the way back kept
    def _state(self):
        return (self.tabs.currentIndex(), self.search.text(), self.cat, self.sub, set(self.styles), set(self.traits),
                self.folder, self.look_folder)

    def _activate(self, ix):
        """Double click / Enter: a folder opens; anything else is chosen (both signals come for one double click)."""
        import time
        now = time.monotonic()
        if now - getattr(self, "_activated", 0.0) < 0.3:
            return
        self._activated = now
        e = ix.data(Q.UserRole)
        if e and e.get("members"):
            self.open_folder(e)
        elif e and e.get("looks"):
            self.open_looks(e)
        elif e:
            self.chosen.emit(e)

    def open_folder(self, e):
        """All variants of a folder (a person / creature of one name), the way back kept."""
        self.history.append(self._state())
        del self.history[:-20]
        self.folder, self.look_folder = e["folder"], None
        self.refresh()

    def open_looks(self, e):
        """All looks of a person the game spawns with a random one, the way back kept."""
        self.history.append(self._state())
        del self.history[:-20]
        self.look_folder = e["path"]
        self.refresh()

    def show_only(self, what, value):
        """what: type (value = (cat, sub)), style, trait or words (a search)."""
        self.history.append(self._state())
        self.folder = self.look_folder = None
        del self.history[:-20]
        self.tabs.blockSignals(True)
        self.tabs.setCurrentIndex(0)
        self.tabs.blockSignals(False)
        self.cat = self.sub = None
        self.styles.clear()
        self.traits.clear()
        text = ""
        if what == "type":
            self.cat, self.sub = value
        elif what == "style":
            self.styles.add(value)
        elif what == "trait":
            self.traits.add(value)
        else:
            text = value
        self.search.blockSignals(True)
        self.search.setText(text)
        self.search.blockSignals(False)
        self.refresh()

    def back(self):
        if not self.history:
            return
        tab, text, self.cat, self.sub, self.styles, self.traits, self.folder, self.look_folder = self.history.pop()
        self.tabs.blockSignals(True)
        self.tabs.setCurrentIndex(tab)
        self.tabs.blockSignals(False)
        self.search.blockSignals(True)
        self.search.setText(text)
        self.search.blockSignals(False)
        self.refresh()

    # --- entries
    def _entry_template(self, r):
        """The grid's entry for a template - made once and kept (a refresh made 22 000 of them anew: most of its
        0.7 s, 06.10.); a copy, so a folder's entry made from it does not change it."""
        cache = self.__dict__.setdefault("_entries", {})
        e = cache.get(r["path"])
        if e is None or e["row"] is not r:
            from .catalog import caption
            # many share a display name ("Treasure Chest"): the file name tells them apart
            sub = caption(r["path"]) if r.get("named") else r.get("sub") or r.get("kind")
            looks = looks_of(r)                         # several: a folder of its looks
            if looks:
                sub = f"{len(looks)} looks"
            e = cache[r["path"]] = {"type": "template", "key": r["path"], "path": r["path"], "title": r["name"],
                                    "looks": looks,
                                    "sub": sub, "mesh": r.get("mesh"), "kind": r.get("kind"),
                                    "inv": bool(r.get("inventory")), "loot": "lootable" in (r.get("traits") or []),
                                    "row": r}
        out = dict(e)
        out["fav"] = r["path"] in self._fav_set()
        return out

    def _fav_set(self):
        """The favourites as a set (asked 22 000 times a refresh: a list was slow), made anew when they change."""
        if getattr(self, "_fav_src", None) != self.favourites or not hasattr(self, "_favs"):
            self._fav_src, self._favs = list(self.favourites), set(self.favourites)
        return self._favs

    def _folders(self, found):
        """Templates of FOLDER_CATS sharing a name -> one folder entry each (at the first one's place)."""
        from collections import defaultdict
        members = defaultdict(list)
        for r in found:
            if r.get("cat") in FOLDER_CATS and r.get("named"):
                members[(r["cat"], r["name"])].append(r)
        out, done = [], set()
        for r in found:
            k = (r.get("cat"), r.get("name"))
            if len(members.get(k, ())) < 2:
                out.append(self._entry_template(r))
            elif k not in done:
                done.add(k)
                out.append(self._entry_folder(k, members[k]))
        return out

    def _entry_folder(self, k, rows):
        import random
        key = f"folder:{k[0]}:{k[1]}"
        if key not in self._picked_member or self._picked_member[key] not in [r["path"] for r in rows]:
            self._picked_member[key] = random.choice(rows)["path"]
        rep = next(r for r in rows if r["path"] == self._picked_member[key])
        e = self._entry_template(rep)
        e.update(key=key, title=k[1], sub=f"{len(rows)} variants", folder=k,
                 members=[r["path"] for r in rows], looks=[], fav=False)
        return e

    def _entry_look(self, r, look):
        """One look of a person: placed with exactly it. Named by what sets it apart from the others ('Look 07';
        outside its folder - recent, favourites - with the person's name)."""
        from .look_chooser import label
        key = f"{r['path']}#{look}"
        looks = looks_of(r)
        short = label(look)
        if len(looks) > 1:
            cut = os.path.commonprefix(looks)
            cut = cut[:cut.rfind("_") + 1]                  # (at a word's end: rich_1 / rich_10 keep their digits)
            short = label(look[len(cut):]) or short
        inside = self.look_folder == r["path"]
        return {"type": "template", "key": key, "path": r["path"], "look": look,
                "title": f"Look {short}" if inside else f"{r['name']}, look {short}", "sub": label(look),
                "mesh": None, "kind": r.get("kind"), "inv": bool(r.get("inventory")), "loot": False, "row": r,
                "fav": key in self._fav_set()}

    def _entry_item(self, r):
        return {"type": "item", "key": "item:" + r["name"], "name": r["name"], "title": r["label"] or r["name"],
                "sub": r.get("sub") or r["category"].replace("_", " "), "kind": r["category"],
                "fav": ("item:" + r["name"]) in self.favourites, "row": r}

    def refresh(self):
        text, tab = self.search.text(), self.tabs.currentIndex()
        facets = None
        if tab == 0 and self.look_folder:
            r = self.assets.template(self.look_folder)
            rows = [self._entry_look(r, lk) for lk in looks_of(r)]
            facets = {"tree": {}, "styles": {}, "traits": {}, "total": len(rows)}
        elif tab == 0 and self.folder:
            cat, name = self.folder
            found = [r for r in self.assets.browse("", cat, None, (), (), quest=self.quest_chip.isChecked(),
                                                   limit=100000)[0]
                     if r.get("name") == name]
            rows = [self._entry_template(r) for r in found]
            facets = {"tree": {}, "styles": {}, "traits": {}, "total": len(rows)}
        elif tab == 0:
            found, facets = self.assets.browse(text, self.cat, self.sub, self.styles, self.traits,
                                               quest=self.quest_chip.isChecked(), limit=100000)
            if self.hide:
                found = [r for r in found if not self.hide(r)]
            rows = self._folders(found)                 # all of them, shown a page at a time (Model)
            facets = dict(facets, total=facets["total"])
        elif tab == 1:
            found, facets = self.assets.browse_items(text, self.cat, self.sub)
            rows = [self._entry_item(r) for r in found]
        else:
            keys = self.favourites if tab == 2 else self.recent
            rows = []
            for k in keys:
                if "#" in k and not k.startswith("item:"):          # a look of a person
                    path, look = k.split("#", 1)
                    r = self.assets.template(path)
                    if r:
                        rows.append(self._entry_look(r, look))
                    continue
                r = self.assets.item(k[5:]) if k.startswith("item:") else self.assets.template(k)
                if r:
                    rows.append(self._entry_item(r) if k.startswith("item:") else self._entry_template(r))
        self.model.set_rows(self._sorted(rows))
        self.details.layoutChanged.emit()
        self.sort_b.setText(SHORT.get(self.sort_by, "Best") + "  ▾")
        self._has_tree = facets is not None
        self._sync_nav()
        self.style_box.setVisible(tab == 0 and self.filters_open)
        self.trait_box.setVisible(tab == 0 and self.filters_open)
        self.filter_b.setVisible(tab == 0)
        self.crumb.setVisible(facets is not None)
        if facets is not None:
            self._fill_tree(facets["tree"], tab)
            self._fill_crumb(facets["total"], tab)
        if tab == 0:
            self._fill_chips(facets)
        total = facets["total"] if facets else len(rows)
        self.count.setText(f"{total}")                  # (all of them: the grid shows a page at a time)

    def _fill_tree(self, counts, tab):
        from .taxonomy import GROUP_ORDER, HIDDEN_GROUPS, ITEM_GROUP_ORDER, sort_groups
        groups = {}
        for (c, s), n in counts.items():
            groups.setdefault(c, {})[s] = n
        if self.cat and self.cat not in groups:
            groups[self.cat] = {self.sub: 0} if self.sub else {}
        self.tree.blockSignals(True)
        self.tree.clear()
        visible = sum(n for c, subs in groups.items() for n in subs.values() if c not in HIDDEN_GROUPS)
        top = QtWidgets.QTreeWidgetItem(["Everything", str(visible)])
        top.setData(0, Q.UserRole, (None, None))
        self.tree.addTopLevelItem(top)
        chosen = top
        order = ITEM_GROUP_ORDER if tab == 1 else GROUP_ORDER
        for c in sort_groups(groups, order):
            subs = groups[c]
            n = sum(subs.values())
            if c in HIDDEN_GROUPS and c != self.cat and not n:
                continue
            it = QtWidgets.QTreeWidgetItem([c, str(n)])
            it.setData(0, Q.UserRole, (c, None))
            if c in HIDDEN_GROUPS:
                it.setForeground(0, QtGui.QColor("#777"))
            self.tree.addTopLevelItem(it)
            if c == self.cat and not self.sub:
                chosen = it
            if len(subs) > 1 or (c == self.cat and self.sub):
                for s, k in sorted(subs.items(), key=lambda x: (x[0].startswith("Other"), -x[1])):
                    ch = QtWidgets.QTreeWidgetItem([s, str(k)])
                    ch.setData(0, Q.UserRole, (c, s))
                    it.addChild(ch)
                    if (c, s) == (self.cat, self.sub):
                        chosen = ch
            it.setExpanded(c == self.cat)
            for col in (1,):
                it.setForeground(col, QtGui.QColor("#888"))
        for i in range(self.tree.topLevelItemCount()):
            t = self.tree.topLevelItem(i)
            for k in range(t.childCount()):
                t.child(k).setForeground(1, QtGui.QColor("#777"))
        self.tree.setCurrentItem(chosen)
        self.tree.blockSignals(False)

    def _fill_crumb(self, total, tab):
        link = "<a style='color:#dddddd;text-decoration:underline' href='{}'>{}</a>"
        parts = [link.format("all", "Everything") if self.cat else "<b style='color:#eee'>Everything</b>"]
        if self.history:
            parts.insert(0, link.format("back", "Back"))
        if self.look_folder:
            r = self.assets.template(self.look_folder) or {}
            path = ([self.folder[1]] if self.folder else []) + [f"<b style='color:#eee'>{r.get('name', '')}</b>"]
            self.crumb.setText(" / ".join(parts[:1] + path) + f"<span style='color:#777'> &nbsp;{total} looks</span>")
            return
        if self.folder:
            self.crumb.setText(" / ".join(parts[:1] + [f"<b style='color:#eee'>{self.folder[1]}</b>"]) +
                               f"<span style='color:#777'> &nbsp;{total} variants</span>")
            return
        if self.cat:
            parts.append(link.format("cat", self.cat) if self.sub else f"<b style='color:#eee'>{self.cat}</b>")
        if self.sub:
            parts.append(f"<b style='color:#eee'>{self.sub}</b>")
        self.crumb.setText(" / ".join(parts) + f"<span style='color:#777'> &nbsp;{total}</span>")

    def _fill_chips(self, facets):
        from .taxonomy import STYLES
        counts = facets["styles"]
        # the style chips: made once, shown with their count when something would come of them
        for s, _w in STYLES:
            if s not in self.style_chips:
                b = self._chip(s, "cat.style")
                b.picked.connect(lambda add, k=s: self._pick(self.styles, k, add))
                self.style_flow.addWidget(b)
                self.style_chips[s] = b
            b = self.style_chips[s]
            n = counts.get(s, 0)
            b.setText(f"{s}  {n}".replace("&", "&&"))       # & would be a shortcut mark
            b.setChecked(s in self.styles)
            b.setVisible(n > 0 or s in self.styles)
        for key, (b, label) in self.trait_chips.items():
            n = facets["traits"].get(key, 0)
            b.setText(f"{label}  {n}".replace("&", "&&"))
            b.setChecked(key in self.traits)
            b.setVisible(n > 0 or key in self.traits)
        self.style_box.updateGeometry()
        self.trait_box.updateGeometry()
        on = len(self.styles) + len(self.traits) + int(self.quest_chip.isChecked())
        self.filter_b.setText(f"Filters  {on}" if on else "Filters")

    def _toggle_filters(self):
        self.filters_open = self.filter_b.isChecked()
        self.style_box.setVisible(self.filters_open)
        self.trait_box.setVisible(self.filters_open)
        cfg = config.load()
        cfg["catalog_filters_open"] = self.filters_open
        config.save(cfg)

    # --- choosing
    def _current(self, ix, _prev=None):
        if ix.isValid():
            self.current.emit(ix.data(Q.UserRole))

    def _enter(self):
        if self.model.rows:
            self.grid.setCurrentIndex(self.model.index(0))
            self.chosen.emit(self.model.rows[0])

    def keyPressEvent(self, ev):
        # Down in the search field goes into the grid (the world preview follows)
        if ev.key() == Q.Key_Down and self.focusWidget() is self.search and self.model.rows:
            self.grid.setFocus()
            self.grid.setCurrentIndex(self.model.index(0))
            return
        super().keyPressEvent(ev)

    def remember(self, e):
        self.recent = [e["key"]] + [k for k in self.recent if k != e["key"]][:RECENT_MAX - 1]
        self._save()

    def toggle_favourite(self, e):
        k = e["key"]
        self.favourites = [x for x in self.favourites if x != k] if k in self.favourites else [k] + self.favourites
        self._save()
        self.refresh()

    def _save(self):
        cfg = config.load()
        cfg["favourites"], cfg["recent_templates"] = self.favourites, self.recent
        config.save(cfg)


def star_icon(on):
    """A star, drawn: grey outline, gold when it is a favourite."""
    import math
    pm = QtGui.QPixmap(20, 20)
    pm.fill(Q.transparent)
    p = QtGui.QPainter(pm)
    p.setRenderHint(QtGui.QPainter.Antialiasing)
    pts = [QtCore.QPointF(10 + (8.5 if i % 2 == 0 else 3.6) * math.sin(math.pi * i / 5),
                          10.5 - (8.5 if i % 2 == 0 else 3.6) * math.cos(math.pi * i / 5)) for i in range(10)]
    p.setPen(QtGui.QPen(QtGui.QColor("#d9a441" if on else "#8a8a8a"), 1.4))
    p.setBrush(QtGui.QColor("#d9a441") if on else Q.NoBrush)
    p.drawPolygon(QtGui.QPolygonF(pts))
    p.end()
    return QtGui.QIcon(pm)


# --- the inspector
_DEPOT = None


def _depot():
    """One depot for the 3D loader (its index is read once)."""
    global _DEPOT
    if _DEPOT is None:
        from .bundles import Depot
        _DEPOT = Depot()
    return _DEPOT


class Inspector(QtWidgets.QScrollArea):
    """Everything about the chosen thing: picture, names, what it is; for an object selected in the world also
    what it is in this quest (C of the plan)."""
    place = QtCore.Signal(dict)
    favourite = QtCore.Signal(dict)
    overview = QtCore.Signal(str, object)       # a chip: show all of this kind (catalog.show_only)
    mesh_ready = QtCore.Signal(str, object, object)     # (entry key, parts, images) from the 3D loader

    def __init__(self, editor, assets, pictures):
        super().__init__()
        self.ed, self.assets, self.pictures = editor, assets, pictures
        self.entry = None
        self.item_action = None                 # an item window's inspector: its button for items ("Add item")
        self.setWidgetResizable(True)
        self.setFrameShape(QtWidgets.QFrame.NoFrame)
        self.setHorizontalScrollBarPolicy(Q.ScrollBarAlwaysOff)   # long paths wrap instead
        self.setStyleSheet("QScrollArea{background:transparent} #inspector{background:transparent}")
        body = QtWidgets.QWidget()
        body.setObjectName("inspector")
        self.setWidget(body)
        self.v = QtWidgets.QVBoxLayout(body)
        self.v.setContentsMargins(6, 6, 6, 6)
        # the picture - pressed: the thing itself, turnable (3D preview: meshview.py)
        self.pic_stack = QtWidgets.QStackedWidget()
        self.pic_stack.setFixedHeight(PIC_W + 4)
        self.pic = QtWidgets.QLabel()
        self.pic.setAlignment(Q.AlignCenter)
        self.pic.setStyleSheet("background:#1d1d20;border:1px solid #333")
        self.pic.installEventFilter(self)
        tip(self.pic, "ins.picture3d")
        self.pic_stack.addWidget(self.pic)
        self.view3d = None                      # made when first needed (an OpenGL widget)
        self.mesh_key = None
        self.auto3d = QtCore.QTimer(self)       # quick clicks through the list: only the last one is read
        self.auto3d.setSingleShot(True)
        self.auto3d.setInterval(120)
        self.auto3d.timeout.connect(lambda: self.entry and self.entry.get("type") == "template"
                                    and not is_folder(self.entry) and self._load_3d())
        self.mesh_ready.connect(self._mesh_ready)
        self.v.addWidget(self.pic_stack)
        # the looks the game spawns it in (it picks one): step through them in 3D
        self.look_row = QtWidgets.QWidget()
        lr = QtWidgets.QHBoxLayout(self.look_row)
        lr.setContentsMargins(0, 0, 0, 0)
        self.look_prev = tip(QtWidgets.QToolButton(), "ins.look_step")
        self.look_prev.setText("<")
        self.look_next = tip(QtWidgets.QToolButton(), "ins.look_step")
        self.look_next.setText(">")
        self.look_label = QtWidgets.QLabel()
        self.look_label.setAlignment(Q.AlignCenter)
        self.look_label.setStyleSheet("color:#bbb")
        self.look_prev.clicked.connect(lambda: self._step_look(-1))
        self.look_next.clicked.connect(lambda: self._step_look(1))
        lr.addWidget(self.look_prev)
        lr.addWidget(self.look_label, 1)
        lr.addWidget(self.look_next)
        self.look_row.hide()
        self.v.addWidget(self.look_row)
        self.look_pick = None                   # a catalog entry's look chosen here (None: the usual one)
        self.look_info = {}                     # 3D key -> (look shown, looks to step through)
        self.title = QtWidgets.QLabel()
        self.title.setObjectName("title")
        self.title.setWordWrap(True)
        self.v.addWidget(self.title)
        # an item window's item: its name can be changed - then taking it makes a new item of this quest
        self.rename = QtWidgets.QLineEdit()
        self.rename.setStyleSheet("font:bold 13px")
        tip(self.rename, "ic.rename")
        self.rename.textChanged.connect(self._renamed)
        self.rename.hide()
        self.v.addWidget(self.rename)
        self.rename_note = QtWidgets.QLabel("A new item of this quest")
        self.rename_note.setStyleSheet("color:#e3c65f;font:11px")
        self.rename_note.hide()
        self.v.addWidget(self.rename_note)
        self.redescribe = QtWidgets.QPlainTextEdit()
        self.redescribe.setPlaceholderText("Description")
        self.redescribe.setFixedHeight(64)
        tip(self.redescribe, "ic.redescribe")
        self.redescribe.hide()
        self.v.addWidget(self.redescribe)
        self.subtitle = QtWidgets.QLabel()
        self.subtitle.setWordWrap(True)
        self.v.addWidget(self.subtitle)
        # a folder: that a random variant is placed; a person: whether their mouth moves (Maxim 08.10.)
        self.random_note = QtWidgets.QLabel()
        self.random_note.setWordWrap(True)
        self.random_note.setStyleSheet("color:#e3c65f;font:11px;border:1px solid #5a5032;padding:4px")
        self.random_note.hide()
        self.v.addWidget(self.random_note)
        self.voice = QtWidgets.QLabel()
        self.voice.setWordWrap(True)
        self.voice.hide()
        self.v.addWidget(self.voice)
        prow = QtWidgets.QHBoxLayout()
        self.path = QtWidgets.QLineEdit()
        self.path.setReadOnly(True)
        self.path.setSizePolicy(QtWidgets.QSizePolicy.Ignored, QtWidgets.QSizePolicy.Fixed)
        from .icons import icon_button
        copy = icon_button("copy", lambda: QtWidgets.QApplication.clipboard().setText(self.path.text()), "ins.copy")
        prow.addWidget(self.path, 1)
        prow.addWidget(copy)
        self.copy_b = copy
        self.v.addLayout(prow)
        brow = QtWidgets.QHBoxLayout()
        self.b_place = tip(QtWidgets.QPushButton("Place"), "ins.place")
        self.b_place.clicked.connect(lambda: self.entry and self.place.emit(self.entry))
        self.b_fav = tip(QtWidgets.QPushButton(), "ins.fav")
        self.b_fav.setCheckable(True)
        self.b_fav.setIconSize(QtCore.QSize(20, 20))
        self.b_fav.setFixedWidth(40)
        self.b_fav.setIcon(star_icon(False))
        self.b_fav.toggled.connect(lambda on: self.b_fav.setIcon(star_icon(on)))
        self.b_fav.clicked.connect(lambda: self.entry and self.favourite.emit(self.entry))
        brow.addWidget(self.b_place, 1)
        brow.addWidget(self.b_fav)
        self.v.addLayout(brow)
        # an object selected in the world: what it is in this quest (built by show_object)
        self.obj_box = QtWidgets.QWidget()
        self.obj_lay = QtWidgets.QVBoxLayout(self.obj_box)
        self.obj_lay.setContentsMargins(0, 4, 0, 4)
        self.obj_box.hide()
        self.v.addWidget(self.obj_box)
        # what it is, as chips: a click shows all of that kind
        self.chips_box = QtWidgets.QWidget()
        self.chips_grid = QtWidgets.QGridLayout(self.chips_box)
        self.chips_grid.setContentsMargins(0, 4, 0, 4)
        self.chips_grid.setHorizontalSpacing(8)
        self.chips_grid.setVerticalSpacing(4)
        self.chips_grid.setColumnStretch(1, 1)
        self.v.addWidget(self.chips_box)
        self.facts = QtWidgets.QLabel()
        self.facts.setWordWrap(True)
        self.facts.setTextFormat(Q.RichText)
        self.facts.setTextInteractionFlags(Q.TextSelectableByMouse)
        self.v.addWidget(self.facts)
        self.v.addStretch(1)
        self.obj = None                     # (place, index) of the selected object
        pictures.ready.connect(self._picture_ready)
        from .look_chooser import painter
        painter().painted.connect(lambda t, lk, _p: look_painted(self.pictures, t, lk))

    # --- 3D
    def eventFilter(self, obj, ev):
        if obj is getattr(self, "pic", None) and ev.type() == QtCore.QEvent.MouseButtonPress \
                and self.entry and self.entry.get("type") == "template" and not is_folder(self.entry):
            self._load_3d()
            return True
        return super().eventFilter(obj, ev)

    def _meshes_of(self, e):
        """The meshes to show for an entry (a library mesh, or a template's own - not shadows, wounds, helpers)."""
        if not e or e.get("type") != "template":
            return []
        if e.get("mesh"):
            return [e["mesh"]]
        row = e.get("row") or {}
        try:
            meshes = json.loads(row.get("meshes") or "[]")
        except (TypeError, ValueError):
            meshes = []
        return meshes

    def _key3d(self):
        if not self.entry:
            return None
        return self.entry["key"] + (f"#{self.obj}" if self.obj else "") + (f"@{self.look_pick}" if self.look_pick
                                                                            else "")

    def _load_3d(self):
        e = self.entry
        meshes = self._meshes_of(e)
        key = self._key3d()
        if self.mesh_key == key and self.view3d is not None:
            self.pic_stack.setCurrentWidget(self.view3d)
            return
        self.mesh_key = key

        def work():
            from . import meshview
            if e.get("mesh"):                           # a library mesh
                parts = meshview.read_mesh(e["mesh"], _depot())
            else:                                       # a template: its meshes, or a person's look in its colours
                try:
                    look = (self.obj and self.ed.project.places[self.obj[0]]["objects"][self.obj[1]].get(
                        "appearance")) or self.look_pick
                    how, parts = meshview.entity_parts(e["path"], _depot(), meshes, look)
                    if how.startswith("look "):         # the looks to step through: those the game uses
                        apps, used = meshview.looks(e["path"], _depot())
                        self.look_info[key] = (how[5:], [u for u in used if u in apps] or list(apps))
                except Exception:                       # noqa: BLE001
                    parts = []
            images = meshview.load_images(parts) if parts else {}
            self.mesh_ready.emit(key, parts, images)
        threading.Thread(target=work, daemon=True).start()

    def _mesh_ready(self, key, parts, images):
        if not self.entry or key != self.mesh_key or key != self._key3d():
            return                                      # clicked on to something else meanwhile
        cur, options = self.look_info.get(key, ("", []))
        self.look_row.setVisible(not self.obj and len(options) > 1 and "look" not in self.entry)
        if options:
            at = options.index(cur) + 1 if cur in options else 0
            text = f"{cur.replace('_', ' ')}  {at}/{len(options)}" if at else cur.replace("_", " ")
            from .talking import known_talking
            talking = known_talking(self.entry.get("path") or "") if voice_of(self.entry) == "some" else None
            if talking is not None and cur not in talking:
                text += "  (cannot talk)"
            self.look_label.setText(text)
        if not parts:
            self._picture()                             # nothing to turn: the picture stays
            return
        from . import meshview
        if self.view3d is None:
            self.view3d = meshview.MeshView()
            tip(self.view3d, "ins.view3d")
            self.pic_stack.addWidget(self.view3d)
        self.view3d.show_parts(parts, images)
        self.pic_stack.setCurrentWidget(self.view3d)

    def _step_look(self, d):
        cur, options = self.look_info.get(self._key3d(), ("", []))
        if not options:
            return
        at = options.index(cur) if cur in options else -1
        self.look_pick = options[(at + d) % len(options)]
        self._load_3d()

    def show_entry(self, e, favourite=False):
        """A catalog entry (what it is)."""
        self.obj = None
        self.obj_box.hide()
        self.b_place.setText("Place")
        self._show(e, favourite)

    def _show(self, e, favourite=False):
        if not self.entry or self.entry.get("key") != e.get("key"):
            self.look_pick = None                       # another thing: its usual look
            self.look_row.hide()
        if "look" in e:                                 # a look of a person: shown in it
            self.look_pick = e["look"]
        self.entry = e
        if self.pic_stack.currentWidget() is not self.pic:
            self.pic_stack.setCurrentWidget(self.pic)   # a new thing: its picture first, then itself in 3D
        r = e["row"]
        self._picture()
        if e["type"] == "template":
            self.auto3d.start()
        self.b_fav.setChecked(favourite)
        self.random_note.setVisible(is_folder(e))
        if is_folder(e):
            self.random_note.setText(folder_text(e))
        v = voice_of(e) if e["type"] == "template" else None
        self.voice.setVisible(bool(v) and v != "some")     # (Maxim 08.10.: the guide says how talking works)
        if v:
            self.voice.setText(VOICE_LOOK[v] if "look" in e else VOICE_TEXT[v])
            self.voice.setStyleSheet(f"color:{VOICE_COLOUR[v]};font:11px")
        self.b_place.setIcon(QtGui.QIcon())
        if self.item_action is None and not self.obj:
            self.b_place.setText("Place random" if is_folder(e) else "Place")
            if is_folder(e):                        # the dice: one of the folder at random
                from .icons import icon
                self.b_place.setIcon(icon("dices", "#e3c65f", 16))
        if e["type"] == "item":
            self.title.setText(r["label"] or r["name"])
            self.subtitle.setText(" / ".join(x for x in (r.get("cat"), r.get("sub"), r["category"].replace("_", " "))
                                             if x))
            self.path.setText(r["name"])
            self.b_place.setVisible(bool(self.item_action))
            if self.item_action:
                self.b_place.setText(self.item_action)
                self.title.hide()                       # its name is the field: renamed, a new item
                self.rename.blockSignals(True)
                self.rename.setText(r["label"] or r["name"])
                self.rename.blockSignals(False)
                self.rename.show()
                self.rename_note.hide()
                self.redescribe.setPlainText(r.get("descr") or "")
                self.redescribe.hide()
            facts = [("price", f"{r['price']:g} crowns"), ("weight", f"{r['weight']:g}"),
                     ("defined in", r["file"])]
            self._chips([("type", [(r.get("sub") or "", ("words", r.get("sub") or ""))] if r.get("sub") else []),
                         ("tags", [(t, ("words", t)) for t in (r["tags"] or "").split()][:24])])
            descr = r.get("descr") or ""
            self.facts.setText(_facts(facts) + (f"<p style='color:#bbb'>{descr}</p>" if descr else ""))
            return
        self.b_place.setVisible(True)
        if e.get("members"):
            self.title.setText(f"{e['title']}  (folder, {len(e['members'])} variants)")
        elif e.get("looks"):
            self.title.setText(f"{e['title']}  (folder, {len(e['looks'])} looks)")
        elif "look" in e:
            self.title.setText(f"{r.get('name')}: {e['sub']}")
        else:
            self.title.setText(r.get("name") or e["title"])
        styles = r.get("styles") or []
        styles = styles if isinstance(styles, list) else [x.replace("_", " ") for x in styles.split()]
        sub = [x for x in (" / ".join(y for y in (r.get("cat"), r.get("sub")) if y), ", ".join(styles),
                           r.get("source")) if x]
        self.subtitle.setText(" / ".join(sub))
        self.path.setText("" if e.get("members") else e["path"])
        self.path.setVisible(not e.get("members"))
        self.copy_b.setVisible(not e.get("members"))
        facts = [("class", r.get("class", "")), ("inventory", "yes" if r.get("inventory") else "no")]
        loot = json.loads(r.get("loot_defs") or "[]")     # its loot parameter's tables (not what it includes)
        if loot:
            facts.append(("loot table", ", ".join(x.strip("_") for x in loot)))
        apps = json.loads(r.get("appearances") or "[]")
        if apps:
            facts.append(("appearances", ", ".join(apps[:12]) + (f" (+{len(apps) - 12})" if len(apps) > 12 else "")))
        comps = json.loads(r.get("components") or "[]")
        if comps:
            facts.append(("components", ", ".join(c[1:] if c.startswith("C") else c for c in comps)))
        meshes = json.loads(r.get("meshes") or "[]")
        if meshes:
            facts.append(("meshes", ", ".join(os.path.splitext(os.path.basename(m))[0] for m in meshes[:6]) +
                          (f" (+{len(meshes) - 6})" if len(meshes) > 6 else "")))
        if r.get("mesh"):
            facts.append(("mesh", r["mesh"]))
        traits = r.get("traits") or []
        traits = traits if isinstance(traits, list) else traits.split()
        self._chips([("type", [(r.get("sub") or r.get("cat") or "", ("type", (r.get("cat"), r.get("sub"))))]
                      if r.get("cat") else []),
                     ("style", [(s, ("style", s)) for s in styles]),
                     ("can", [(t, ("trait", t)) for t in traits if t not in ("quest", "named")]),
                     ("class", [(r.get("class", ""), ("words", r.get("class", "")))]
                      if r.get("class") and r.get("class") != "mesh" else []),
                     ("tags", [(t, ("words", t)) for t in (r.get("tags") or "").split()][:24])])
        facts = [f for f in facts if f[0] != "class"]
        self.facts.setText("" if e.get("members") else _facts(facts))     # (a folder: one variant's would mislead)

    def renamed_to(self):
        """The new name typed for an item window's item, or None (not renamed)."""
        e = self.entry
        if not (self.item_action and e and e.get("type") == "item"):
            return None
        text = self.rename.text().strip()
        return text if text and text != (e["row"]["label"] or e["row"]["name"]) else None

    def _renamed(self, _text):
        new = self.renamed_to() is not None
        self.rename_note.setVisible(new)
        self.redescribe.setVisible(new)             # a new item: its description can be its own too

    def described(self):
        """The description written for a renamed item."""
        return self.redescribe.toPlainText().strip()

    def _chips(self, rows):
        """rows: [(label, [(text, (what, value)), ...])] - one line of outlined chips per label."""
        grid = self.chips_grid
        while grid.count():
            w = grid.takeAt(0).widget()
            if w:
                w.hide()
                w.deleteLater()
        r = 0
        for name, chips in rows:
            if not chips:
                continue
            lab = QtWidgets.QLabel(name)
            lab.setStyleSheet("color:#999;font:12px")
            grid.addWidget(lab, r, 0, Q.AlignTop)
            box = QtWidgets.QWidget()
            flow = Flow(box, 4)
            for text, target in chips:
                b = QtWidgets.QToolButton()
                b.setText(text.replace("&", "&&"))
                b.setStyleSheet(TAG)
                b.setCursor(Q.PointingHandCursor)
                tip(b, title=text, text="Shows everything of this kind")
                b.clicked.connect(lambda _c=False, t=target: self.overview.emit(*t))
                flow.addWidget(b)
            grid.addWidget(box, r, 1)
            r += 1
        self.chips_box.setVisible(r > 0)

    # --- an object selected in the world
    def show_object(self, place, index):
        """The selected object, everything that can be changed about it: name, where it stands, its look, and for
        containers what is in it (loot table, what is always inside, what is in it now)."""
        ed = self.ed
        o = ed.project.places[place]["objects"][index]
        self.obj = (place, index)
        row = self.assets.template(o["template"]) or {"path": o["template"].lower(), "name": o["template"],
                                                       "kind": "", "tags": ""}
        from .catalog import caption
        self._show({"type": "template", "key": row["path"], "path": row["path"], "title": row["name"],
                    "sub": caption(row["path"]), "row": row})
        self.b_place.setText("Place another")
        lay = self.obj_lay
        while lay.count():
            it = lay.takeAt(0)
            w = it.widget()
            if w:
                w.hide()
                w.deleteLater()
        lay.addWidget(_head("OBJECT"))
        form = QtWidgets.QGridLayout()
        form.setContentsMargins(0, 0, 0, 0)
        form.setHorizontalSpacing(6)
        form.setVerticalSpacing(4)
        fbox = QtWidgets.QWidget()
        fbox.setLayout(form)
        self.o_id = QtWidgets.QLineEdit(o.get("id", ""))
        self.o_id.setPlaceholderText(caption(o["template"]).replace(" ", "_"))
        self.o_id.editingFinished.connect(self._rename)
        tip(self.o_id, "obj.name")
        form.addWidget(_label("name"), 0, 0)
        form.addWidget(self.o_id, 0, 1, 1, 3)
        self.o_num = []
        values = list(o["pos"]) + list(o["rot"])
        for i, name in enumerate(["x", "y", "z", "roll", "pitch", "yaw"]):
            b = QtWidgets.QDoubleSpinBox()
            b.setRange(-100000, 100000)
            b.setDecimals(2 if i < 3 else 1)
            b.setSingleStep(0.1 if i < 3 else 5.0)
            b.setButtonSymbols(QtWidgets.QAbstractSpinBox.NoButtons)
            b.setSizePolicy(QtWidgets.QSizePolicy.Ignored, QtWidgets.QSizePolicy.Fixed)
            b.setValue(values[i])
            b.editingFinished.connect(self._move)                  # every change at once, no apply button
            self.o_num.append(b)
            from .fields import with_unit
            form.addWidget(with_unit(b, before=name), 1 + i // 3, 1 + i % 3)
        form.addWidget(_label("position"), 1, 0)
        form.addWidget(_label("turn"), 2, 0)
        apps = json.loads(row.get("appearances") or "[]")
        if apps:
            # one button with the look it has; the window with a picture of every look chooses another
            from .look_chooser import label as look_label
            form.addWidget(_label("look"), 3, 0)
            self.o_look = QtWidgets.QPushButton(look_label(o.get("appearance") or "") + "  ...")
            self.o_look.clicked.connect(lambda _c=False, t=o["template"]: self.panel_choose_look(t))
            tip(self.o_look, "obj.look")
            form.addWidget(self.o_look, 3, 1, 1, 3)
        from .quest import is_actor
        self.o_speaks = False
        if apps and is_actor(o):
            from .quest import speaking_people
            # who speaks in the quest needs a look with a face that moves (the look window hides the others)
            self.o_speaks = f"{place}/{o.get('id')}" in speaking_people(self.ed.project.meta.get("quest") or {})
        from .item_chooser import steps_about
        about = steps_about(self.ed.project.meta.get("quest") or {}, f"{place}/{o.get('id')}") if o.get("id") else []
        if about:
            q = QtWidgets.QLabel("quest: " + ";  ".join(f"step {n} - {t}" for n, t in about[:3]))
            q.setWordWrap(True)
            q.setStyleSheet("color:#c8c8c8;font:11px")
            form.addWidget(q, 6, 0, 1, 4)
        from .item_chooser import item_label, puts_in
        quest = self.ed.project.meta.get("quest") or {}
        put = puts_in(quest, f"{place}/{o.get('id')}") if o.get("id") else []
        if put:                                     # (a Loot step's items: in it once the quest starts)
            q = QtWidgets.QLabel("Quest puts in: " + ",  ".join(
                f"{item_label(ref, quest, self.assets)} (step {n})" for n, ref in put))
            q.setWordWrap(True)
            q.setStyleSheet("color:#e3c65f;font:11px")
            tip(q, "obj.quest_puts_in")
            form.addWidget(q, 7, 0, 1, 4)
        if is_actor(o):                             # the name the game shows above them (empty: the game's own)
            self.o_display = QtWidgets.QLineEdit(o.get("display", ""))
            self.o_display.setPlaceholderText("The game's name")
            self.o_display.editingFinished.connect(self._display)
            tip(self.o_display, "obj.display")
            form.addWidget(_label("Shown as"), 5, 0)
            form.addWidget(self.o_display, 5, 1, 1, 3)
        if is_actor(o):                             # what the person does where they stand (the game's actions)
            from . import npc_actions
            form.addWidget(_label("does"), 4, 0)
            does = QtWidgets.QToolButton()
            cur = o.get("action")
            does.setText(npc_actions.label(cur.split("/")[-1]) if cur else "stands")
            does.setStyleSheet(TAG + "QToolButton::menu-indicator{image:none;width:0}")
            menu = QtWidgets.QMenu(does)
            menu.addAction("stands").triggered.connect(lambda _c=False: self._does(None))
            for posture, entries in npc_actions.actions(npc_actions.gender_of(o["template"])):
                sub = menu.addMenu(posture)
                seen = set()
                for key, lab in entries:
                    if lab in seen:
                        continue
                    seen.add(lab)
                    sub.addAction(lab).triggered.connect(lambda _c=False, key=key: self._does(key))
            attach(does, menu)
            tip(does, "obj.does")
            form.addWidget(does, 4, 1, 1, 3)
        form.setColumnStretch(1, 1)
        form.setColumnStretch(2, 1)
        form.setColumnStretch(3, 1)
        lay.addWidget(fbox)
        if row.get("inventory"):
            self._contents_section(lay, o, row)
        self._plugin_sections(lay, o, place, index, "npc" if is_actor(o) else
                              "container" if row.get("inventory") else "object")
        self.obj_box.show()

    def _plugin_sections(self, lay, o, place, index, kind):
        """The plug-ins' sections for this kind of thing (api.add_inspector_section): a heading and their widget;
        one that fails says so in its place."""
        from . import plugins
        for title, factory in plugins.get().inspector_sections(kind, o):
            lay.addWidget(_head(str(title).upper()))
            try:
                lay.addWidget(factory(self.ed, o, place, index))
            except Exception as ex:                 # noqa: BLE001 - a plug-in's section is not the inspector's
                lab = QtWidgets.QLabel(f"{title}: {ex}")
                lab.setWordWrap(True)
                lay.addWidget(lab)

    def _move(self):
        v = [b.value() for b in self.o_num]
        self.ed.set_selected_transform(v[:3], v[3:])

    def _display(self):
        """The name the game shows above the selected person (after the build)."""
        if not self.obj:
            return
        text = self.o_display.text().strip()
        o = self.ed.project.places[self.obj[0]]["objects"][self.obj[1]]
        if text != o.get("display", ""):
            self.ed.project.set_object(self.obj[0], self.obj[1], display=text or None)

    def _does(self, action):
        """What the selected person does where they stand (their action point's job)."""
        if not self.obj:
            return
        self.ed.project.set_object(self.obj[0], self.obj[1], action=action)
        self.show_object(*self.obj)

    def panel_choose_look(self, template):
        o = self.ed.project.places[self.obj[0]]["objects"][self.obj[1]] if self.obj else {}
        self.ed.panel.choose_look(template, o.get("appearance") or "", self._look,
                                  speaks=getattr(self, "o_speaks", False))

    def _look(self, appearance):
        from .look_chooser import label as look_label
        if getattr(self, "o_look", None) is not None:
            self.o_look.setText(look_label(appearance) + "  ...")
        self.ed.set_object_look(appearance)
        self.mesh_key = None                        # the new look in 3D
        self.auto3d.start()

    def _rename(self):
        if not self.obj:
            return
        from .project import ascii_id
        name = ascii_id(self.o_id.text())
        if name:
            self.ed.project.name_object(self.obj[0], self.obj[1], name)
            self.o_id.setText(name)

    # --- what is in a container
    def _contents_section(self, lay, o, row):
        """What Geralt finds in it: the quest's items (the builder's choice) first, then the random loot, then what
        is in it in the game right now."""
        from .quest import is_actor
        actor = is_actor(o)
        self.o_template_loot = json.loads(row.get("loot_defs") or "[]")
        lay.addWidget(_head("CARRIES" if actor else "CONTENTS"))
        lay.addWidget(_label("Drops when killed" if actor else "Quest items"))
        self.o_items = QtWidgets.QVBoxLayout()
        ibox = QtWidgets.QWidget()
        ibox.setLayout(self.o_items)
        self.o_items.setContentsMargins(0, 0, 0, 0)
        self.o_items.setSpacing(2)
        lay.addWidget(ibox)
        self._fill_items(o.get("inventory", []))
        add = tip(QtWidgets.QPushButton("+ Add item"), "obj.add_item")
        add.setStyleSheet("QPushButton{color:#bbb;background:#1f1f22;border:1px dashed #666;border-radius:0;"
                          "padding:4px}QPushButton:hover{border-color:#999;color:#eee}")
        name = o.get("id") or os.path.splitext(os.path.basename(o["template"]))[0]
        add.clicked.connect(lambda: self.ed.panel.choose_item(
            lambda ref: self.ed.set_object_item(ref, None),
            f"Give {name.replace('_', ' ')} an item" if actor else f"Put into {name.replace('_', ' ')}",
            key=f"inventory:{self.obj[0]}/{name}", keep_open=True, action="Add item"))
        lay.addWidget(add)
        self.o_loot_box = QtWidgets.QWidget()
        self.o_loot_lay = QtWidgets.QVBoxLayout(self.o_loot_box)
        self.o_loot_lay.setContentsMargins(0, 8, 0, 0)
        self.o_loot_lay.setSpacing(3)
        lay.addWidget(self.o_loot_box)
        self._fill_loot(o)                      # people and creatures too: a table added to what they carry
        now = _label("In the game now")
        now.setStyleSheet("color:#999;font:12px;margin-top:8px")
        lay.addWidget(now)
        self.o_now_box = QtWidgets.QVBoxLayout()
        nb = QtWidgets.QWidget()
        nb.setLayout(self.o_now_box)
        self.o_now_box.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(nb)
        self.o_now = True
        self.live_inventory(None, asking=True)
        self.ed.ask_inventory()

    def _loot_now(self, o):
        """The loot table this object uses: its own choice, else the template's (a container's; a person's extra loot
        starts at none); "" = none."""
        from .quest import is_actor
        if "loot" in o:
            return o["loot"] or ""
        if is_actor(o):
            return ""
        return self.o_template_loot[0] if self.o_template_loot else ""

    def _fill_loot(self, o):
        from .item_chooser import IconStrip, loot_row
        lay = self.o_loot_lay
        while lay.count():
            w = lay.takeAt(0).widget()
            if w:
                w.hide()
                w.deleteLater()
        from .quest import is_actor
        actor = is_actor(o)
        # a person's template table is what they carry anyway: their extra loot starts at none
        own = "" if actor else (self.o_template_loot[0] if self.o_template_loot else "")
        lay.addWidget(loot_row(o, own, self._set_loot, self._loot_window, actor=actor))
        name = self._loot_now(o)
        table = self.assets.loot(name) if name else None
        if table:
            may = _label("May contain")
            may.setStyleSheet("color:#777;font:11px")
            lay.addWidget(may)
            lay.addWidget(IconStrip(self.assets, self.pictures, [(e[0], e[2]) for e in table["entries"]], limit=16))

    def _loot_window(self):
        o = self._obj_data()
        name = o.get("id") or os.path.splitext(os.path.basename(o["template"]))[0]
        self.ed.panel.choose_loot(self._set_loot, f"Random loot for {name.replace('_', ' ')}",
                                  key=f"loot:{self.obj[0]}/{name}", current=self._loot_now(o) or None)

    def _set_loot(self, name):
        """name: a loot table; "" = none; None = the template's again."""
        self.ed.set_object_loot(name)
        self._fill_loot(self._obj_data())

    def _obj_data(self):
        place, index = self.obj
        return self.ed.project.places[place]["objects"][index]

    def _fill_items(self, inventory):
        from .item_chooser import IconStrip, item_label
        lay = self.o_items
        while lay.count():
            w = lay.takeAt(0).widget()
            if w:
                w.hide()                # gone at once, not only once Qt deletes it
                w.deleteLater()
        if not inventory:
            none = QtWidgets.QLabel("None yet")
            none.setStyleSheet("color:#777;font:12px")
            lay.addWidget(none)
        quest = self.ed.project.meta.get("quest") or {}
        for entry in inventory:
            name, n = entry["item"], int(entry.get("count", 1))
            row = QtWidgets.QWidget()
            h = QtWidgets.QHBoxLayout(row)
            h.setContentsMargins(0, 0, 0, 0)
            h.setSpacing(3)
            h.addWidget(IconStrip(self.assets, self.pictures, [(name, None)], limit=1))
            label = QtWidgets.QLabel(item_label(name, quest, self.assets))
            label.setStyleSheet("color:#ddd;font:12px")
            label.setSizePolicy(QtWidgets.QSizePolicy.Ignored, QtWidgets.QSizePolicy.Preferred)
            h.addWidget(label, 1)
            for text, d in (("-", -1), (None, 0), ("+", 1)):
                if text is None:
                    c = QtWidgets.QLabel(str(n))
                    c.setFixedWidth(22)
                    c.setAlignment(Q.AlignCenter)
                    c.setStyleSheet("color:#eee;font:bold 12px")
                    h.addWidget(c)
                    continue
                b = QtWidgets.QToolButton()
                b.setText(text)
                b.setStyleSheet(TAG)
                b.setFixedWidth(22)
                b.clicked.connect(lambda _c=False, name=name, v=max(0, n + d): self.ed.set_object_item(name, v))
                tip(b, "ins.count")
                h.addWidget(b)
            from .icons import icon_button
            rm = icon_button("trash-2", lambda _c=False, name=name: self.ed.set_object_item(name, 0), "ins.remove_item")
            h.addWidget(rm)
            lay.addWidget(row)

    def refresh_object(self):
        """After a change: the quest's list again (the object's place file is the truth)."""
        if self.obj and hasattr(self, "o_items"):
            place, index = self.obj
            objs = self.ed.project.places.get(place, {}).get("objects", [])
            if index < len(objs):
                self._fill_items(objs[index].get("inventory", []))
                if hasattr(self, "o_loot_lay") and not self.o_loot_box.isHidden():
                    self._fill_loot(objs[index])

    def live_inventory(self, items, asking=False):
        """What the game says is in the object now (its loot table's items included), as icons."""
        if not getattr(self, "o_now", None):
            return
        from .item_chooser import IconStrip
        lay = self.o_now_box
        while lay.count():
            w = lay.takeAt(0).widget()
            if w:
                w.hide()                # gone at once, not only once Qt deletes it
                w.deleteLater()
        if items is None:
            lab = QtWidgets.QLabel("Asking the game..." if asking else "No answer from the game")
            lab.setStyleSheet("color:#777;font:12px")
            lay.addWidget(lab)
            return
        lay.addWidget(IconStrip(self.assets, self.pictures, [(name, int(n)) for name, n in items], limit=24,
                                empty="empty"))

    def _picture(self):
        e = self.entry
        if not e:
            return
        size = 64 if e["type"] == "item" else 320
        pix = entry_picture(self.pictures, self.assets, e, size, paint=True)
        if pix is None:
            self.pic.setText("...")
        elif pix.isNull():
            self.pic.setText("-")
        else:
            # renders fill the box; item icons (64 px) at most doubled - bigger only blurs them
            w = min(PIC_W, pix.width() * 2) if e["type"] == "item" else PIC_W
            self.pic.setPixmap(pix.scaled(w, w, Q.KeepAspectRatio, Q.SmoothTransformation))

    def _picture_ready(self, key):
        if self.entry and key.startswith(self.entry["key"] + "@"):
            self._picture()
        elif key.startswith("item:") and self.obj and hasattr(self, "o_items"):
            # an item icon of the inventory list arrived: draw the list again (a moment later, once for many)
            if not getattr(self, "_redraw_pending", False):
                self._redraw_pending = True
                QtCore.QTimer.singleShot(150, self._redraw_items)

    def _redraw_items(self):
        self._redraw_pending = False
        self.refresh_object()


def _breakable(text):
    """Paths and long names may wrap after \\ / _ , (a zero width space)."""
    import html
    t = html.escape(str(text))
    for ch in ("\\", "/", "_", ","):
        t = t.replace(ch, ch + "​")
    return t


def _head(text):
    lab = QtWidgets.QLabel(text)
    lab.setStyleSheet("color:#f0f0f0;font:bold 12px;margin-top:8px")
    return lab


def _label(text):
    lab = QtWidgets.QLabel(text)
    lab.setStyleSheet("color:#999;font:12px")
    return lab


def _facts(pairs):
    rows = "".join(f"<tr><td style='color:#999;padding-right:8px;vertical-align:top'>{k}</td>"
                   f"<td style='color:#ddd'>{_breakable(v)}</td></tr>" for k, v in pairs if v != "")
    return f"<table cellspacing='2'>{rows}</table>"
