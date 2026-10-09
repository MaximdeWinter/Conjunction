"""One look for every window of Conjunction (Maxim 05.10.: "alles was UI ist nutzt die gleichen Größen, Formen und
Farben across the board"): the values of the editor's panel, square corners, one light grey for what is chosen, no
focus frame, a check box a square with a check mark in it. The app, Settings, the library and the editor's panel take
their style from here.

    from . import theme
    theme.install(app)                  # the controls, for every window
    w.setStyleSheet(theme.sheet())      # an app window: its backgrounds and headings too
"""
import os
import tempfile

from PySide6 import QtCore, QtGui, QtSvg, QtWidgets

HERE = os.path.dirname(os.path.abspath(__file__))
LOGO = os.path.join(HERE, "data", "conjunction.ico")

# --- colours
BG = "#18181a"              # windows, the panel
SURFACE = "#1d1d20"         # lists, trees, tables, rows
FIELD = "#2a2a2d"           # text fields, choices, check boxes
BUTTON = "#303033"
HEADER = "#252528"          # tabs, table headers
LINE = "#444444"            # frames, the lines of the nav
EDGE = "#55555a"            # the edge of what can be clicked or typed into
EDGE_HOVER = "#8a8a8f"
CHOSEN = "#4b4b50"          # the one mark for chosen / selected
CHOSEN_EDGE = "#c8c8c8"
HOVER = "#29292d"
TEXT = "#cccccc"
BRIGHT = "#eeeeee"
DIM = "#8c8c90"
RED = "#e57a7a"
GOLD = "#d9a441"            # the graph's selection, the logo and the way back from a sub page (back_button)

# --- sizes (px)
FONT = 13                   # labels, buttons, fields
FONT_LIST = 12              # entries of lists, trees, tables
FONT_SMALL = 11             # dim lines, table headers
FONT_HEAD = 14              # a page's heading
PAD = "5px 10px"            # buttons
PAD_FIELD = "5px"
BOX = 14                    # a check box
LABEL_W = 190               # the label column of a settings page
FIELD_W = 560               # a field there at most


def _cache_dir():
    d = os.path.join(tempfile.gettempdir(), "conjunction_theme")
    os.makedirs(d, exist_ok=True)
    return d


def _svg_png(name, color, size, stroke=None):
    """A Lucide icon as a PNG (and @2x for high-dpi screens) for a style sheet's image:url(). -> its path, with /."""
    out = os.path.join(_cache_dir(), f"{name}_{color.lstrip('#')}_{size}{f'_w{stroke}' if stroke else ''}.png")
    for scale, path in ((1, out), (2, out[:-4] + "@2x.png")):
        if os.path.exists(path):
            continue
        with open(os.path.join(HERE, "icons", name + ".svg"), encoding="utf-8") as f:
            data = f.read().replace("currentColor", color)
        if stroke:                                  # a bolder line (the back button)
            data = data.replace('stroke-width="2"', f'stroke-width="{stroke}"')
        img = QtGui.QImage(size * scale, size * scale, QtGui.QImage.Format_ARGB32)
        img.fill(QtCore.Qt.transparent)
        p = QtGui.QPainter(img)
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        QtSvg.QSvgRenderer(QtCore.QByteArray(data.encode())).render(p)
        p.end()
        img.save(path)
    return out.replace("\\", "/")


def logo(size=28):
    """The logo (the two rings) as a pixmap."""
    return QtGui.QIcon(LOGO).pixmap(size, size)


def window_icon():
    return QtGui.QIcon(LOGO)


def back_button(on_click, text="Back"):
    """The way out of a sub page (the dialogue editor, a chooser): the arrow and the word in gold and bold, the most
    visible button there (Maxim 06.10.: "der zurück knopf prominenter ... gold und fett", the arrow, not the logo)."""
    b = QtWidgets.QToolButton()
    b.setObjectName("back")
    b.setText(text)
    b.setIcon(QtGui.QIcon(_svg_png("arrow-left", GOLD, 18, stroke=3)))
    b.setIconSize(QtCore.QSize(18, 18))
    b.setToolButtonStyle(QtCore.Qt.ToolButtonTextBesideIcon)
    b.setCursor(QtCore.Qt.PointingHandCursor)
    b.setFocusPolicy(QtCore.Qt.NoFocus)
    b.setStyleSheet(f"QToolButton#back{{color:{GOLD};font:bold 13px;background:transparent;border:1px solid {GOLD};"
                    f"padding:3px 10px 3px 6px}}"
                    f"QToolButton#back:hover{{background:rgba(217,164,65,40)}}")
    b.clicked.connect(lambda _c=False: on_click())
    return b


def base():
    """The controls, the same in every window (the app sets it once for all, install()): buttons, fields, check
    boxes, lists, trees, tables, tabs, menus, scroll bars. A window's own sheet adds its backgrounds and labels."""
    check = _svg_png("check", BRIGHT, BOX - 2)
    down = _svg_png("chevron-down", TEXT, 12)
    up = _svg_png("chevron-up", TEXT, 10)
    down_small = _svg_png("chevron-down", TEXT, 10)
    return f"""
*{{border-radius:0;outline:0}}
QPushButton{{color:#dddddd;background:{BUTTON};border:1px solid {EDGE};padding:{PAD};font-size:{FONT}px}}
QPushButton:hover{{border-color:{EDGE_HOVER}}}
QPushButton:pressed{{background:{CHOSEN}}}
QPushButton:disabled{{color:#6a6a6e;border-color:{LINE}}}
QPushButton#primary{{color:{BRIGHT};background:{CHOSEN};border-color:{CHOSEN_EDGE}}}
QPushButton#primary:disabled{{color:#6a6a6e;background:{BUTTON};border-color:{LINE}}}
QLineEdit,QComboBox,QSpinBox,QDoubleSpinBox,QPlainTextEdit,QTextEdit{{color:{BRIGHT};background:{FIELD};
    border:1px solid {EDGE};padding:{PAD_FIELD};font-size:{FONT}px;selection-background-color:{CHOSEN}}}
QLineEdit:focus,QComboBox:focus,QSpinBox:focus,QDoubleSpinBox:focus,QPlainTextEdit:focus,QTextEdit:focus{{
    border-color:{EDGE_HOVER}}}
QComboBox::drop-down{{border:none;width:20px}}
QComboBox::down-arrow{{image:url({down});width:12px;height:12px}}
QComboBox QAbstractItemView{{background:{SURFACE};color:{TEXT};border:1px solid {LINE};
    selection-background-color:{CHOSEN};selection-color:#ffffff}}
QSpinBox::up-button,QDoubleSpinBox::up-button,QSpinBox::down-button,QDoubleSpinBox::down-button{{border:none;
    width:16px;background:transparent}}
QSpinBox::up-arrow,QDoubleSpinBox::up-arrow{{image:url({up});width:10px;height:10px}}
QSpinBox::down-arrow,QDoubleSpinBox::down-arrow{{image:url({down_small});width:10px;height:10px}}
QCheckBox{{spacing:8px;background:transparent}}
QCheckBox::indicator{{width:{BOX}px;height:{BOX}px;border:1px solid {EDGE};background:{FIELD}}}
QCheckBox::indicator:hover{{border-color:{EDGE_HOVER}}}
QCheckBox::indicator:checked{{image:url({check})}}
QCheckBox::indicator:disabled{{border-color:{LINE};background:{BG}}}
QRadioButton{{spacing:8px;background:transparent;color:{TEXT};font-size:{FONT}px}}
QRadioButton::indicator{{width:{BOX - 2}px;height:{BOX - 2}px;border:1px solid {EDGE};border-radius:{BOX // 2}px;
    background:{FIELD}}}
QRadioButton::indicator:hover{{border-color:{EDGE_HOVER}}}
QRadioButton::indicator:checked{{background:{CHOSEN_EDGE};border:3px solid {FIELD};outline:1px solid {EDGE}}}
QListWidget,QTreeWidget,QTableWidget,QListView,QTreeView{{color:#dddddd;background:{SURFACE};
    border:1px solid {LINE};font-size:{FONT_LIST}px;gridline-color:{LINE}}}
QListWidget::item,QTreeWidget::item{{padding:3px 6px}}
QTableWidget::item{{padding:0 8px}}
QListWidget::item:hover,QTreeWidget::item:hover{{background:{HOVER}}}
QListWidget::item:selected,QTreeWidget::item:selected,QTableWidget::item:selected{{background:{CHOSEN};
    color:#ffffff}}
QHeaderView{{background:{HEADER};border:none}}
QHeaderView::section{{color:#bbbbbb;background:{HEADER};border:none;border-bottom:1px solid {LINE};
    border-right:1px solid {LINE};padding:4px 8px;font-size:{FONT_SMALL}px}}
QTabWidget::pane{{border:0}}
QTabBar::tab{{color:#bbbbbb;background:{HEADER};padding:6px 14px;border:1px solid {LINE};border-bottom:0}}
QTabBar::tab:selected{{color:#ffffff;background:{CHOSEN};border-color:{CHOSEN_EDGE}}}
QMenu{{background:{SURFACE};color:#dddddd;border:1px solid {EDGE};font-size:{FONT_LIST}px}}
QMenu::item{{padding:4px 14px}}
QMenu::item:selected{{background:{CHOSEN};color:#ffffff}}
QMenu::item:disabled{{color:#6a6a6e}}
QMenu::separator{{height:1px;background:{LINE};margin:3px 0}}
QScrollBar:vertical{{background:transparent;width:10px;margin:0;border:none}}
QScrollBar:horizontal{{background:transparent;height:10px;margin:0;border:none}}
QScrollBar::handle{{background:#3a3a3e;min-height:24px;min-width:24px}}
QScrollBar::handle:hover{{background:{EDGE}}}
QScrollBar::add-line,QScrollBar::sub-line{{width:0;height:0;border:none}}
QScrollBar::add-page,QScrollBar::sub-page{{background:transparent}}
QProgressBar{{background:{FIELD};border:1px solid {LINE};color:#dddddd;text-align:center;font-size:{FONT_SMALL}px;
    height:16px}}
QProgressBar::chunk{{background:{CHOSEN}}}
"""


def page():
    """An app window's own part: its backgrounds, headings, dim lines, the nav."""
    return f"""
QWidget#app,QWidget#page,QWidget#lib,QScrollArea,QScrollArea>QWidget>QWidget,QStackedWidget{{background:{BG}}}
QWidget{{color:{TEXT};font-size:{FONT}px}}
QLabel{{color:{TEXT};font-size:{FONT}px;background:transparent}}
QLabel#head{{color:{BRIGHT};font-size:{FONT_HEAD}px;font-weight:bold;padding:0 0 4px 0}}
QLabel#title{{color:{BRIGHT};font-weight:bold}}
QLabel#name{{color:{BRIGHT};font-size:{FONT_HEAD}px;font-weight:bold}}
QLabel#dim{{color:{DIM};font-size:{FONT_SMALL}px}}
QLabel#problem{{color:{RED}}}
QFrame#top{{background:{BG};border:none;border-bottom:1px solid {LINE}}}
QFrame#side{{background:{BG};border:none;border-right:1px solid {LINE}}}
QFrame#side QListWidget#nav{{border:none}}
QFrame#row{{background:{SURFACE};border:1px solid {LINE}}}
QListWidget#nav,QTreeWidget#nav{{background:{BG};border:none;border-right:1px solid {LINE};font-size:{FONT}px}}
QListWidget#nav::item,QTreeWidget#nav::item{{padding:6px 10px}}
QTreeWidget#nav::branch{{background:transparent}}
"""


def install(app):
    """Once per app: the controls' look for every window (the editor's too)."""
    if not getattr(app, "_cj_theme", False):
        app.setStyleSheet(base())
        app._cj_theme = True


_style = None


def sheet():
    """An app window's sheet: the controls and its own part (made once: its images need the app to exist)."""
    global _style
    if _style is None:
        _style = base() + page()
    return _style
