"""The export window (Maxim 08.10.): before the export, what the quest's page will say - its name, where it starts,
its description - shown and changeable. The name and the description are the quest's own (the journal shows them);
a changed start line is kept for the page only (project.yml page.starts).

    values = ask(project, include_source, parent)   -> {"project", "include_source", "rebuild"} or None (cancelled)
    last_export(project)                            -> the folder of its newest export, or None

(export_view.py: the list of the mods a quest uses, above the button)
"""
import os

from PySide6 import QtCore, QtWidgets

from . import theme


def _start_line(project):
    from .packaging import starts_with
    st = starts_with(project) or {}
    return (st.get("text") or "") + (f" ({st['world']})" if st.get("world") else "")


def last_export(project):
    """The folder of the project's newest export (Documents\\Conjunction\\exports\\<quest name>), or None."""
    from .packaging import find_export
    return find_export(project.base_id)


def _show(folder):
    from PySide6 import QtGui
    os.makedirs(folder, exist_ok=True)
    QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(folder))


def ask(project, include_source=False, parent=None):
    """Any project can be exported here (Maxim 08.10.), the open one is first; where the exports go is shown and one
    click opens them. -> {"project", "include_source", "rebuild"} or None."""
    from .packaging import EXPORTS
    from .project import Project, recent
    d = QtWidgets.QDialog(parent)
    d.setWindowTitle("Export")
    d.setWindowIcon(theme.window_icon())
    d.setStyleSheet(theme.sheet())
    v = QtWidgets.QVBoxLayout(d)
    v.setContentsMargins(20, 16, 20, 16)
    head = QtWidgets.QLabel("Export")
    head.setObjectName("head")
    v.addWidget(head)
    which = QtWidgets.QComboBox()
    paths = [project.path] + [p for p in recent() if os.path.normcase(os.path.abspath(p)) !=
                              os.path.normcase(os.path.abspath(project.path))]
    for k, path in enumerate(paths):
        try:
            other = project if k == 0 else Project(path)
        except Exception:                               # noqa: BLE001 - a broken project is not offered
            continue
        label = other.meta.get("name") or other.id
        which.addItem(label + ("  (open)" if k == 0 else ""), path)
    v.addWidget(which)
    info = QtWidgets.QLabel("This is what the quest's Nexus page and the journal will show")
    info.setWordWrap(True)
    info.setStyleSheet(f"color:{theme.DIM}")
    v.addWidget(info)
    form = QtWidgets.QFormLayout()
    form.setLabelAlignment(QtCore.Qt.AlignLeft)
    v.addLayout(form)
    name = QtWidgets.QLineEdit()
    name.setPlaceholderText("Name")
    form.addRow("Name", name)
    starts = QtWidgets.QLineEdit()
    starts.setPlaceholderText("Where it starts")
    starts_label = QtWidgets.QLabel("Starts")
    form.addRow(starts_label, starts)
    desc = QtWidgets.QPlainTextEdit()
    desc.setPlaceholderText("Description (optional)")
    desc.setMinimumHeight(110)
    form.addRow("Description", desc)
    source = QtWidgets.QCheckBox("Include the project (others can open and change it)")
    source.setChecked(include_source)
    v.addWidget(source)
    where = QtWidgets.QLabel(f"Exports go to {EXPORTS}")
    where.setWordWrap(True)
    where.setStyleSheet(f"color:{theme.DIM}")
    where.setTextInteractionFlags(QtCore.Qt.TextSelectableByMouse)
    v.addWidget(where)
    shown = {}

    def load(_k=0):
        path = which.currentData()
        shown["p"] = project if path == project.path else Project(path)
        meta = shown["p"].meta
        q = meta.get("quest") or {}
        place = meta.get("kind") == "place"
        name.setText((meta.get("name") if place else q.get("title")) or "")
        starts.setText(((meta.get("page") or {}).get("starts") or {}).get("text") or _start_line(shown["p"]))
        starts.setVisible(not place)
        starts_label.setVisible(not place)
        desc.setPlainText(q.get("description") or meta.get("description") or "")
        last = last_export(shown["p"])
        b_last.setEnabled(last is not None)
        b_last.setToolTip(last or "Not exported yet")
    row = QtWidgets.QHBoxLayout()
    b_last = QtWidgets.QPushButton("Open last export")
    b_last.clicked.connect(lambda: last_export(shown["p"]) and _show(last_export(shown["p"])))
    b_all = QtWidgets.QPushButton("Show exported quests")
    b_all.setToolTip(EXPORTS)
    b_all.clicked.connect(lambda: _show(EXPORTS))
    row.addWidget(b_last)
    row.addWidget(b_all)
    row.addStretch(1)
    cancel = QtWidgets.QPushButton("Cancel")
    cancel.clicked.connect(d.reject)
    go = QtWidgets.QPushButton("Export")
    go.setObjectName("primary")
    go.setDefault(True)
    go.clicked.connect(d.accept)
    name.textChanged.connect(lambda t: go.setEnabled(bool(t.strip())))
    row.addWidget(cancel)
    row.addWidget(go)
    v.addLayout(row)
    which.currentIndexChanged.connect(load)
    load()
    d.setMinimumWidth(600)
    from . import dialogs
    if dialogs.run_dialog(d, "Export", "export") != QtWidgets.QDialog.Accepted:
        return None
    chosen = shown["p"]
    return dict(apply(chosen, name.text(), starts.text(), desc.toPlainText(), source.isChecked()), project=chosen)


def apply(project, name, start, description, include_source):
    """The window's values into the project -> {"include_source", "rebuild"} (rebuild: the name changed)."""
    meta = project.meta
    place = meta.get("kind") == "place"
    name, start, description = name.strip(), start.strip(), description.strip()
    rebuild = False
    if place:
        if name and name != meta.get("name"):
            meta["name"] = name
            rebuild = True
        meta["description"] = description
    else:
        q = meta.setdefault("quest", {})
        if name and name != q.get("title"):
            q["title"] = name
            rebuild = True
        q["description"] = description
        page = meta.setdefault("page", {})
        if start and start != _start_line(project):
            page["starts"] = {"text": start, "world": ""}
        else:
            page.pop("starts", None)
        if not page:
            meta.pop("page", None)
    project.save_meta()
    return {"include_source": include_source, "rebuild": rebuild}
