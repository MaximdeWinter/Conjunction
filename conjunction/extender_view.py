"""TW3SE missing or too old (Maxim 08.10.: TW3SE is a requirement from its own Nexus page): said at Conjunction's start
and again before the game is opened for editing, with the page to get it.

    ask(parent=None, opening=False) -> True when TW3SE is in the game and new enough
"""
import webbrowser

from PySide6 import QtWidgets

from . import extender, theme


def ask(parent=None, opening=False):
    """The check, and when it fails the hint with the page; opening: before the game opens for editing (it can not
    without TW3SE). -> True when TW3SE is ready."""
    st, _detail = extender.state()
    if st == "ok" or extender.source() is not None:
        return True
    d = QtWidgets.QDialog(parent)
    d.setWindowTitle("Conjunction")
    d.setWindowIcon(theme.window_icon())
    v = QtWidgets.QVBoxLayout(d)
    v.setContentsMargins(20, 16, 20, 16)
    head = QtWidgets.QLabel({"missing": "TW3SE is missing", "unsupported": "TW3SE needs an update"}.get(st, "TW3SE is too old"))
    head.setObjectName("head")
    v.addWidget(head)
    found = extender.installed_version()
    text = ("Conjunction needs TW3SE (The Witcher 3 Script Extender) to work in the game. Download it from its Nexus "
            "page and install it" if st == "missing" else
            f"TW3SE {found} stays off on this version of The Witcher 3 (a game patch). Download the new version from its "
            "Nexus page and install it" if st == "unsupported" else
            f"Conjunction needs TW3SE {extender.NEEDS} or newer" + (f" (the game has {found})" if found else "") +
            ". Download the new version from its Nexus page and install it")
    if opening:
        text += ". The game opens for editing once TW3SE is there"
    else:
        text += ". Until then everything outside the game works (projects, the quest graph, dialogues)"
    info = QtWidgets.QLabel(text)
    info.setWordWrap(True)
    v.addWidget(info)
    link = QtWidgets.QLabel(f'<a href="{extender.page()}" style="color:{theme.GOLD}">{extender.page()}</a>')
    link.setOpenExternalLinks(True)
    v.addWidget(link)
    row = QtWidgets.QHBoxLayout()
    row.addStretch(1)
    later = QtWidgets.QPushButton("Later")
    later.clicked.connect(d.reject)
    again = QtWidgets.QPushButton("Check again")
    get = QtWidgets.QPushButton("Download on Nexus")
    get.setDefault(True)
    get.clicked.connect(lambda: webbrowser.open(extender.page()))

    def check():
        if extender.state()[0] == "ok":
            d.accept()
        else:
            again.setText("Not there yet - check again")
    again.clicked.connect(check)
    for b in (later, again, get):
        row.addWidget(b)
    v.addLayout(row)
    d.setMinimumWidth(500)
    from . import dialogs
    dialogs.run_dialog(d, "TW3SE", "tw3se")
    return extender.state()[0] == "ok"
