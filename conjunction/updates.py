"""Is there a newer Conjunction, TW3SE, Conjunction Runtime or content pack on Nexus Mods? (Maxim 08.10.: Nexus says it
itself) - only when Settings > General > Check for updates at start is on. One question to Nexus Mods' public API
(GraphQL v2, no key: the name, version and date of a mod) for everything with a Nexus page; what is newer is shown
with its page. Nothing is downloaded or installed by itself.

And what Conjunction changed in the game by itself (the runtime): said once at the next start (notices).

    check() -> {"what": [(name, mine, newest, page)]} or None
    note(text) / take_notes() -> [text]
"""
import json
import re
import urllib.request

API = "https://api.nexusmods.com/v2/graphql"
GAME_ID = 952                   # The Witcher 3 on Nexus Mods (domain witcher3)
_NOTES = []


def _version(v):
    return tuple(int(n) for n in re.findall(r"\d+", str(v))) or (0,)


def mod_id(url):
    """The mod's number of a Nexus Mods page of The Witcher 3, or None."""
    m = re.search(r"nexusmods\.com/witcher3/mods/(\d+)", str(url or ""))
    return int(m.group(1)) if m else None


def mine():
    """[(name, installed version, page)] of what has a Nexus page: Conjunction, TW3SE and the runtime in the game,
    the content packs in the game."""
    from . import __version__
    from .packaging import RUNTIME_PAGE, SUITE_PAGE, TW3SE_PAGE
    out = [("Conjunction", __version__, SUITE_PAGE)]
    try:
        from . import extender
        out.append(("TW3SE", extender.version() or "", TW3SE_PAGE))
    except Exception:                               # noqa: BLE001 - no game folder yet
        pass
    try:
        from .setup import installed_runtime
        rt = installed_runtime()
        if rt:
            out.append(("Conjunction Runtime", str(rt), RUNTIME_PAGE))
    except Exception:                               # noqa: BLE001
        pass
    try:
        from . import content
        out += [(p.get("name") or p.get("id"), str(p.get("version") or ""), p.get("url") or "")
                for p in content.installed_packs()]
    except Exception:                               # noqa: BLE001 - no packs, no game
        pass
    return [(n, v, url) for n, v, url in out if v and mod_id(url)]


def nexus_versions(ids, timeout=4.0):
    """{mod id: (name, version)} from Nexus Mods (one question for all) - {} when it does not answer."""
    if not ids:
        return {}
    from . import __version__
    query = "{ legacyMods(ids: [%s]) { nodes { modId name version } } }" % ", ".join(
        f"{{gameId: {GAME_ID}, modId: {i}}}" for i in sorted(set(ids)))
    req = urllib.request.Request(API, data=json.dumps({"query": query}).encode("utf-8"), method="POST",
                                 headers={"Content-Type": "application/json", "Application-Name": "Conjunction",
                                          "Application-Version": str(__version__),
                                          # (Python's own user agent is refused by Nexus' Cloudflare: 1010)
                                          "User-Agent": f"Conjunction/{__version__}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode("utf-8"))
    except (OSError, ValueError):
        return {}
    nodes = ((data.get("data") or {}).get("legacyMods") or {}).get("nodes") or []
    return {int(n["modId"]): (n.get("name") or "", str(n.get("version") or "")) for n in nodes if n.get("modId")}


def check(timeout=4.0, have=None):
    """What has a newer version on Nexus Mods than this PC has -> {"what": [(name, mine, newest, page)]} or None."""
    have = have if have is not None else mine()
    latest = nexus_versions([mod_id(url) for _n, _v, url in have], timeout)
    what = []
    for name, v, url in have:
        got = latest.get(mod_id(url))
        if got and got[1] and _version(got[1]) > _version(v):
            what.append((name, v, got[1], url))
    return {"what": what} if what else None


def note(text):
    """Something Conjunction changed in the game by itself, to say once."""
    if text not in _NOTES:
        _NOTES.append(text)


def take_notes():
    out = list(_NOTES)
    _NOTES.clear()
    return out


def show(parent, found=None, notes=()):
    """The window that says it: what is newer, each with its Nexus page, and what was updated in the game."""
    from PySide6 import QtCore, QtGui, QtWidgets
    from . import theme
    dlg = QtWidgets.QDialog(parent)
    dlg.setWindowTitle("Updates")
    dlg.setWindowIcon(theme.window_icon())
    dlg.setStyleSheet(theme.sheet() + f"QDialog{{background:{theme.BG}}}")
    v = QtWidgets.QVBoxLayout(dlg)
    for text in notes:
        v.addWidget(QtWidgets.QLabel(text))
    for name, old, new, url in (found or {}).get("what", []):
        row = QtWidgets.QHBoxLayout()
        label = QtWidgets.QLabel(f"{name} {new} is out (you have {old})")
        label.setStyleSheet(f"color:{theme.BRIGHT};font-weight:bold")
        row.addWidget(label, 1)
        go = QtWidgets.QPushButton("Open on Nexus")
        go.clicked.connect(lambda _c=False, u=url: QtGui.QDesktopServices.openUrl(QtCore.QUrl(u)))
        row.addWidget(go)
        v.addLayout(row)
    row = QtWidgets.QHBoxLayout()
    row.addStretch(1)
    close = QtWidgets.QPushButton("OK")
    close.clicked.connect(dlg.accept)
    row.addWidget(close)
    v.addLayout(row)
    dlg.setMinimumWidth(460)
    dlg.show()
    dlg.raise_()
    return dlg
