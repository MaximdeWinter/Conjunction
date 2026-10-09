"""Make a content pack (Maxim, 02.10.): a creator picks their mod folder; the window shows what is in it (by kind),
what keeps it from working seamlessly with everyone's quests, and writes the pack card with one click
(packmaker.py). The mod is then uploaded as always. Or new furniture from 3D files: a folder of FBX files with their
textures becomes a pack of its own (furniture.py)."""
import os

from PySide6 import QtCore, QtGui, QtWidgets

from . import APP_NAME, content, packmaker, theme
from .icons import GREEN, icon, pixmap
from .tooltips import tip

LEVEL = {"ok": ("circle-check", GREEN), "fix": ("wrench", "#8ab4e5"), "warn": ("triangle-alert", "#e5b85c"),
         "info": ("info", "#9a9a9a")}
FIELDS = (("name", "Name"), ("version", "Version"), ("author", "Author"), ("url", "Link"),
          ("description", "Description"))


def mod_folders(game=None):
    """The game's DLC and mod folders that could be packs: not Conjunction's own, not quests made with it."""
    out = []
    try:                                        # the DLCs of this PC's own quests (Build & Play) are no packs
        from .project import Project, recent
        own = {f"dlc{Project(p).id}".lower() for p in recent()} | {f"moddlc{Project(p).id}".lower() for p in recent()}
    except Exception:                           # noqa: BLE001 - a broken project: listed then
        own = set()
    for kind, name, path in content.folders(game):
        if kind == "game" or name.lower() in content.SUITE_DLCS or name in ("modConjunction", "modConjunctionRuntime"):
            continue
        if name.lower() in own:
            continue
        if os.path.exists(os.path.join(path, content.QUEST_MARKER)) or not content.bundles_in(path):
            continue
        out.append(path)
    return out


class _Progress(QtCore.QObject):
    line = QtCore.Signal(str)
    done = QtCore.Signal(str, str)              # the installed pack folder, an error


class PackMakerWindow(QtWidgets.QWidget):
    def __init__(self, folder=None):
        super().__init__()
        self.mode = "mod"                       # "mod": a mod folder and its card; "fbx": furniture from 3D files
        self.fbx_folder = None
        self.progress = _Progress()
        self.progress.line.connect(lambda t: self.status.setText(t))
        self.progress.done.connect(self._built)
        self.setObjectName("lib")
        self.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        theme.install(QtWidgets.QApplication.instance())
        self.setStyleSheet(theme.sheet())
        self.setWindowTitle(f"{APP_NAME} - Content pack")
        self.setWindowIcon(theme.window_icon())
        self.resize(680, 720)
        self.report = None
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(16, 12, 16, 12)
        v.setSpacing(8)
        head = QtWidgets.QLabel("Content pack")
        head.setObjectName("head")
        v.addWidget(head)
        row = QtWidgets.QHBoxLayout()
        self.pick = QtWidgets.QComboBox()
        self.pick.setMinimumWidth(320)
        tip(self.pick, "pack.pick")
        self.pick.activated.connect(lambda _i: self.open(self.pick.currentData()))
        b_folder = QtWidgets.QPushButton("Other folder")
        b_folder.setIcon(icon("folder-search"))
        tip(b_folder, "pack.folder")
        b_folder.clicked.connect(self._choose)
        b_fbx = QtWidgets.QPushButton("From 3D files")
        b_fbx.setIcon(icon("package-plus"))
        tip(b_fbx, "pack.fbx")
        b_fbx.clicked.connect(self._choose_fbx)
        row.addWidget(self.pick, 1)
        row.addWidget(b_folder)
        row.addWidget(b_fbx)
        v.addLayout(row)
        self.summary = QtWidgets.QLabel("")
        self.summary.setObjectName("dim")
        self.summary.setWordWrap(True)
        v.addWidget(self.summary)
        self.area = QtWidgets.QScrollArea()
        self.area.setWidgetResizable(True)
        self.area.setFrameShape(QtWidgets.QFrame.NoFrame)
        self.list = QtWidgets.QWidget()
        self.list.setObjectName("list")
        self.rows = QtWidgets.QVBoxLayout(self.list)
        self.rows.setSpacing(6)
        self.area.setWidget(self.list)
        v.addWidget(self.area, 1)
        form = QtWidgets.QFormLayout()
        self.fields = {}
        for key, label in FIELDS:
            f = QtWidgets.QLineEdit()
            tip(f, f"pack.{key}")
            self.fields[key] = f
            form.addRow(label, f)
        self.fields["url"].setPlaceholderText("https://www.nexusmods.com/witcher3/mods/...")
        v.addLayout(form)
        h = QtWidgets.QHBoxLayout()
        self.status = QtWidgets.QLabel("")
        self.status.setObjectName("dim")
        self.status.setWordWrap(True)
        self.b_write = QtWidgets.QPushButton("Write pack card")
        self.b_write.setIcon(icon("package-check"))
        tip(self.b_write, "pack.write")
        self.b_write.clicked.connect(self._write)
        h.addWidget(self.status, 1)
        h.addWidget(self.b_write)
        v.addLayout(h)
        self._fill_pick()
        if folder:
            self.open(folder)
        elif self.pick.count():
            self.open(self.pick.itemData(0))
        else:
            self._show()

    def _fill_pick(self):
        self.pick.clear()
        try:
            folders = mod_folders()
        except OSError:
            folders = []
        game = content._game()
        for f in folders:
            self.pick.addItem(os.path.relpath(f, game), f)
        if not folders:
            self.pick.addItem("No mods in the game", None)

    def _choose(self):
        from .dialogs import pick_folder
        d = pick_folder(self, "Mod folder")
        if d:
            self.open(os.path.normpath(d))

    def open(self, folder):
        if not folder:
            return
        self.mode = "mod"
        self.b_write.setText("Write pack card")
        self.folder = folder
        i = self.pick.findData(folder)
        if i < 0:
            self.pick.addItem(folder, folder)
            i = self.pick.count() - 1
        self.pick.setCurrentIndex(i)
        QtWidgets.QApplication.setOverrideCursor(QtCore.Qt.WaitCursor)
        try:
            self.report = packmaker.inspect(folder)
        finally:
            QtWidgets.QApplication.restoreOverrideCursor()
        m = self.report.meta
        for key, _l in FIELDS:
            self.fields[key].setText(str(m.get(key, "")))
        if not m.get("name"):
            self.fields["name"].setText(os.path.basename(folder.rstrip("\\/")))
        if not m.get("version"):
            self.fields["version"].setText("1.0")
        self.status.setText("")
        self._show()

    def _show(self):
        while self.rows.count():
            w = self.rows.takeAt(0).widget()
            if w:
                w.hide()
                w.deleteLater()
        r = self.report
        if r is None:
            self.summary.setText("")
            self.rows.addStretch(1)
            return
        parts = [f"{n} {cat.lower()}" for cat, n in sorted(r.counts().items(), key=lambda kv: -kv[1])]
        if r.items:
            parts.append(f"{len(r.items)} items")
        if r.voices:
            parts.append(f"{r.voices} voice files")
        self.summary.setText(", ".join(parts) or "Nothing found")
        for level, _key, text, things in r.checks:
            self.rows.addWidget(self._check_row(level, text, things))
        self.rows.addWidget(self._contents())
        self.rows.addStretch(1)

    def _check_row(self, level, text, things):
        row = QtWidgets.QFrame()
        row.setObjectName("row")
        h = QtWidgets.QHBoxLayout(row)
        name, color = LEVEL[level]
        mark = QtWidgets.QLabel()
        mark.setPixmap(pixmap(name, color, 16))
        h.addWidget(mark, 0, QtCore.Qt.AlignTop)
        col = QtWidgets.QVBoxLayout()
        t = QtWidgets.QLabel(text)
        t.setWordWrap(True)
        col.addWidget(t)
        if things:
            more = f" and {len(things) - 8} more" if len(things) > 8 else ""
            x = QtWidgets.QLabel(", ".join(things[:8]) + more)
            x.setObjectName("dim")
            x.setWordWrap(True)
            col.addWidget(x)
        h.addLayout(col, 1)
        return row

    def _contents(self):
        """What quests can take from the mod: its things by name, grouped as the catalog sorts them."""
        box = QtWidgets.QFrame()
        box.setObjectName("row")
        v = QtWidgets.QVBoxLayout(box)
        t = QtWidgets.QLabel("For quests")
        t.setObjectName("title")
        v.addWidget(t)
        groups = {}
        for row in self.report.templates:
            if row["cat"] != "Internal":
                groups.setdefault(row["cat"] or "Other", []).append(row["name"])
        if self.report.items:
            groups["Items"] = [i["label"] or i["name"] for i in self.report.items]
        if not groups:
            v.addWidget(QtWidgets.QLabel("Nothing"))
        for cat, names in sorted(groups.items()):
            names = sorted(set(names))
            more = f" and {len(names) - 12} more" if len(names) > 12 else ""
            x = QtWidgets.QLabel(f"<b>{cat}</b>  " + ", ".join(names[:12]) + more)
            x.setObjectName("dim")
            x.setWordWrap(True)
            v.addWidget(x)
        return box

    # --- furniture from 3D files
    def _choose_fbx(self):
        from .dialogs import pick_folder
        d = pick_folder(self, "Folder with FBX files and their textures")
        if d:
            self.plan_fbx(os.path.normpath(d))

    def plan_fbx(self, folder):
        from . import furniture
        self.mode, self.fbx_folder = "fbx", folder
        self.things = furniture.plan(folder)
        self.pictures = furniture.decals(folder)
        self.pack_items = furniture.pack_items(folder)
        self.b_write.setText("Build pack")
        self.fields["name"].setText(os.path.basename(folder.rstrip("\\/")).replace("_", " ").title())
        self.fields["version"].setText("1.0")
        for k in ("url", "description"):            # a new pack (the author stays)
            self.fields[k].setText("")
        while self.rows.count():
            w = self.rows.takeAt(0).widget()
            if w:
                w.hide()
                w.deleteLater()
        self.summary.setText(f"{len(self.things)} pieces from 3D files, {len(self.pictures)} decals, "
                             f"{len(self.pack_items)} items in {folder}")
        for iid, d in self.pack_items.items():
            self.rows.addWidget(self._check_row("ok", f"{iid}: item {d.get('name') or iid}" +
                                                (f", like {d['base']}" if d.get("base") else ""), []))
        if not self.things and not self.pictures and not self.pack_items:
            self.rows.addWidget(self._check_row("warn", "Nothing to build here: no .fbx files, no pictures named "
                                                        "<name>.decal.png, no items.yml.", []))
        for name, img, size in self.pictures:
            self.rows.addWidget(self._check_row("ok", f"{name}: decal {os.path.basename(img)}, "
                                                      f"{size[0]:g} x {size[1]:g} m", []))
        for name, fbx, diff, norm in self.things:
            if diff:
                text = f"{name}: colour {os.path.basename(diff)}" + (f", normal {os.path.basename(norm)}" if norm
                                                                     else "")
                self.rows.addWidget(self._check_row("ok", text, []))
            else:
                self.rows.addWidget(self._check_row("warn", f"{name}: no colour texture beside it ({name}_d.png) - "
                                                            f"it will be grey", []))
        self.rows.addStretch(1)
        self.status.setText("REDkit imports each file, this may take some time...")

    def _build_fbx(self):
        import threading
        from . import furniture
        meta = {k: f.text() for k, f in self.fields.items()}
        self.b_write.setEnabled(False)

        def work():
            try:
                target = furniture.build_pack(self.fbx_folder, meta, log=self.progress.line.emit)
                self.progress.done.emit(target, "")
            except Exception as ex:                 # noqa: BLE001 - shown in the window
                self.progress.done.emit("", str(ex))
        threading.Thread(target=work, daemon=True).start()

    def _built(self, target, error):
        self.b_write.setEnabled(True)
        if error:
            self.status.setText(f"Not built: {error}")
            return
        self._fill_pick()
        self.open(target)
        self.status.setText("Built and installed. The furniture shows in the catalog after the next start of "
                            "Conjunction. To share it, upload this folder (it has its card)")

    def _write(self):
        if self.mode == "fbx":
            return self._build_fbx()
        if self.report is None:
            return
        meta = {k: f.text() for k, f in self.fields.items()}
        try:
            m = packmaker.write(self.folder, meta, self.report)
        except (OSError, ValueError) as ex:
            self.status.setText(f"Not written: {ex}")
            return
        self.report = packmaker.inspect(self.folder)
        self._show()
        self.status.setText(f"Written: {content.MARKER} and {content.INDEX}. Upload the mod as usual, quests made "
                            f"with it name {m['name']} {m['version']}")


def open_url(url):
    if url:
        QtGui.QDesktopServices.openUrl(QtCore.QUrl(url))
