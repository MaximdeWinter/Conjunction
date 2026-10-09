"""radish missing at the start (09.10.: a requirement from its own Nexus page - Nexus quarantines a zip inside a zip):
its page to download it, then Conjunction finds the zip in Downloads (Check again) or the user picks it.

    ask(parent=None) -> the radish folder, or "" (later)
"""
import webbrowser

from PySide6 import QtWidgets

from . import radish_tools as R, theme


def ask(parent=None):
    d = QtWidgets.QDialog(parent)
    d.setWindowTitle("Conjunction")
    d.setWindowIcon(theme.window_icon())
    v = QtWidgets.QVBoxLayout(d)
    v.setContentsMargins(20, 16, 20, 16)
    head = QtWidgets.QLabel("radish modding tools are missing")
    head.setObjectName("head")
    v.addWidget(head)
    info = QtWidgets.QLabel("Conjunction builds quests with the radish modding tools by rmemr. Download the zip from "
                            "its Nexus page (Manual download). Conjunction finds it in your Downloads folder, or pick "
                            "it here. Until then everything works except building")
    info.setWordWrap(True)
    v.addWidget(info)
    link = QtWidgets.QLabel(f'<a href="{R.NEXUS}" style="color:{theme.GOLD}">{R.NEXUS}</a>')
    link.setOpenExternalLinks(True)
    v.addWidget(link)
    status = QtWidgets.QLabel("")
    status.setWordWrap(True)
    v.addWidget(status)
    got = {"folder": ""}

    def take(zip_path):
        status.setText("Unpacking and checking radish...")
        QtWidgets.QApplication.processEvents()
        try:
            got["folder"] = R.install_from(zip_path, log=lambda s: None)
            d.accept()
        except R.Bad as ex:
            status.setText(str(ex))

    def again():
        z = R.find_zip()
        if z:
            take(z)
        else:
            status.setText("Not in Downloads yet")

    def pick():
        path, _ = QtWidgets.QFileDialog.getOpenFileName(d, "The radish zip from Nexus", "", "Zip (*.zip)")
        if path:
            take(path)
    row = QtWidgets.QHBoxLayout()
    row.addStretch(1)
    later = QtWidgets.QPushButton("Later")
    later.clicked.connect(d.reject)
    b_again = QtWidgets.QPushButton("Check again")
    b_again.clicked.connect(again)
    b_pick = QtWidgets.QPushButton("Pick the zip ...")
    b_pick.clicked.connect(pick)
    get = QtWidgets.QPushButton("Download on Nexus")
    get.setDefault(True)
    get.clicked.connect(lambda: webbrowser.open(R.NEXUS))
    for b in (later, b_again, b_pick, get):
        row.addWidget(b)
    v.addLayout(row)
    d.setMinimumWidth(560)
    from . import dialogs
    dialogs.run_dialog(d, "radish", "radish")
    return got["folder"]
