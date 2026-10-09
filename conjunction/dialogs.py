"""Windows and dialogs of Conjunction that are meant to be used now, in front of the game (Maxim 05.10.: "ein paar
fenster scheinbar hinter dem spiel geöffnet ... quests to play öffnet nix"). Windows lets a program that is not in
front bring nothing to the front - the game is in front, so a window Conjunction shows stayed behind it. With the
editor up, a file chooser is one of Conjunction's own windows (like the Asset Browser: over the game, never taking
its focus); before it (the first start) a dialog kept on top.

    bring_up(window)                         shown, in front, active (the game's input left for it)
    pick_folder(parent, title, start)        a folder chooser over the game -> path or ""
    pick_file(parent, title, start, filter)  a file chooser over the game -> path or ""
    run_dialog(dlg, title, key)              any dialog over the game (one of Conjunction's windows), waited for
    ask_text(parent, title, label)           a line asked over the game -> text or ""
"""
from PySide6 import QtCore, QtWidgets

host = None                     # the editor's panel (set when it is made): file choosers open as its windows


def bring_up(w):
    from .cursor import activate
    w.show()
    if w.isMinimized():
        w.showNormal()
    w.raise_()
    w.activateWindow()
    activate(int(w.winId()))


def _over_game(dlg):
    """A dialog of Conjunction on top while it is open (it closes again before anything else is used)."""
    dlg.setWindowFlag(QtCore.Qt.WindowStaysOnTopHint, True)
    dlg.setOption(QtWidgets.QFileDialog.DontUseNativeDialog, False)
    QtCore.QTimer.singleShot(0, lambda: bring_up(dlg))
    return dlg.exec() == QtWidgets.QDialog.Accepted


def _in_window(dlg, title):
    """Qt's own file dialog inside one of Conjunction's windows, waited for (the window's x: cancelled)."""
    key = "file chooser"
    old = host.windows.get(key)
    if old is not None:
        old.close()
    dlg.setOption(QtWidgets.QFileDialog.DontUseNativeDialog, True)
    loop, result = QtCore.QEventLoop(), []
    dlg.finished.connect(lambda code: (result.append(code), loop.quit()))
    w = host.open_window(key, title, lambda: dlg, kind="file_chooser")
    w.title.setText(title)
    w.closed.connect(loop.quit)
    loop.exec()
    if w.isVisible():
        w.close()
    return bool(result) and result[0] == QtWidgets.QDialog.Accepted


def _choose(dlg, title):
    if host is not None:
        return _in_window(dlg, title)
    return _over_game(dlg)


def run_dialog(dlg, title, key="dialog"):
    """A dialog of Conjunction over the game (Maxim 06.10.: Settings > Profile's dialogs opened outside it): with the
    editor up inside one of its windows, waited for; before it on top. -> the dialog's result code."""
    if host is None:
        dlg.setWindowFlag(QtCore.Qt.WindowStaysOnTopHint, True)
        QtCore.QTimer.singleShot(0, lambda: bring_up(dlg))
        return dlg.exec()
    old = host.windows.get(key)
    if old is not None:
        old.close()
    from . import theme
    # a background of its own (the window's frame is the panel's, see-through) - 06.10.: the game shone through
    dlg.setObjectName(dlg.objectName() or "cjdialog")
    dlg.setAttribute(QtCore.Qt.WA_StyledBackground, True)
    dlg.setStyleSheet(theme.sheet() + f"#{dlg.objectName()}{{background:{theme.BG}}}")
    want = dlg.sizeHint().expandedTo(dlg.minimumSize()).expandedTo(QtCore.QSize(460, 0))
    if dlg.testAttribute(QtCore.Qt.WA_Resized):         # (a size set on purpose; a dialog never shown says 640 x 480)
        want = want.expandedTo(dlg.size())
    screen = (host.screen() if hasattr(host, "screen") else QtWidgets.QApplication.primaryScreen()).availableGeometry()
    want = want.boundedTo(QtCore.QSize(int(screen.width() * 0.8), int(screen.height() * 0.8)))
    loop, result = QtCore.QEventLoop(), []
    dlg.finished.connect(lambda code: (result.append(code), loop.quit()))
    w = host.open_window(key, title, lambda: dlg, kind=key.replace(" ", "_"))
    w.title.setText(title)
    w.resize(want.width() + 24, want.height() + 48)     # its own size (06.10.: a line asked filled the screen)
    w.move(screen.center() - w.rect().center())
    w.closed.connect(loop.quit)
    loop.exec()
    if w.isVisible():
        w.close()
    return result[0] if result else QtWidgets.QDialog.Rejected


def ask_text(parent, title, label):
    """One line asked over the game -> the text, "" when cancelled."""
    dlg = QtWidgets.QInputDialog(None if host is not None else parent)
    dlg.setWindowTitle(title)
    dlg.setLabelText(label)
    return dlg.textValue().strip() if run_dialog(dlg, title, "ask") == QtWidgets.QDialog.Accepted else ""


def pick_folder(parent, title, start=""):
    dlg = QtWidgets.QFileDialog(None if host is not None else parent, title, start)
    dlg.setFileMode(QtWidgets.QFileDialog.Directory)
    dlg.setOption(QtWidgets.QFileDialog.ShowDirsOnly, True)
    return dlg.selectedFiles()[0] if _choose(dlg, title) and dlg.selectedFiles() else ""


def pick_file(parent, title, start="", name_filter=""):
    dlg = QtWidgets.QFileDialog(None if host is not None else parent, title, start, name_filter)
    dlg.setFileMode(QtWidgets.QFileDialog.ExistingFile)
    return dlg.selectedFiles()[0] if _choose(dlg, title) and dlg.selectedFiles() else ""
