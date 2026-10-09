"""conjunction: links (Maxim 05.10.: Motion's review page opens a .blend with one click). A link names an action and
its values - conjunction:blend?path=C:\\Users\\...\\Documents\\Conjunction\\stage\\x.blend - Windows hands it to
conjunction_link.pyw, which hands it here; the action is a plug-in's (api.add_link_handler). Every value named
path (or ending in _path) must be a file below Documents\\Conjunction that is there: a web page cannot make
Conjunction open anything else.

    register(log) -> True when it wrote the scheme (HKCU\\Software\\Classes\\conjunction; once, the same after)
    parse(url) -> (action, params)
    route(url, plugins=None) -> what the handler returned
"""
import os
import sys
import urllib.parse

from . import paths

ROOT = paths.HOME
LAUNCHER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "conjunction_link.pyw")


class Refused(Exception):
    pass


def command():
    exe = sys.executable
    if exe.lower().endswith("python.exe"):
        exe = exe[:-len("python.exe")] + "pythonw.exe"         # (no console window for a click)
    return f'"{exe}" "{LAUNCHER}" "%1"'


def register(log=print):
    """The scheme in the user's own part of the registry (no admin): written when missing or pointing elsewhere."""
    import winreg
    want = command()
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Classes\conjunction\shell\open\command") as k:
            if winreg.QueryValue(k, None) == want:
                return False
    except OSError:
        pass
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r"Software\Classes\conjunction") as k:
        winreg.SetValue(k, None, winreg.REG_SZ, "URL:Conjunction")
        winreg.SetValueEx(k, "URL Protocol", 0, winreg.REG_SZ, "")
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r"Software\Classes\conjunction\shell\open\command") as k:
        winreg.SetValue(k, None, winreg.REG_SZ, want)
    log("[links] conjunction: links open with Conjunction")
    return True


def parse(url):
    """conjunction:<action>?<query> (also conjunction://<action>/?...) -> (action, {key: value})."""
    if not url.lower().startswith("conjunction:"):
        raise Refused(f"not a conjunction: link: {url[:60]}")
    rest = url[len("conjunction:"):].lstrip("/")
    action, _, query = rest.partition("?")
    action = action.strip("/").lower()
    if not action.replace("_", "").replace("-", "").isalnum():
        raise Refused(f"no such action: {action[:30]}")
    return action, {k: v for k, v in urllib.parse.parse_qsl(query, keep_blank_values=True)}


def checked(params, root=None):
    """The values naming files: below Documents\\Conjunction, there, no way out of it (.., another drive)."""
    root = os.path.normcase(os.path.realpath(root or ROOT))
    for key, v in params.items():
        if key == "path" or key.endswith("_path"):
            real = os.path.normcase(os.path.realpath(v))
            try:
                inside = os.path.commonpath([real, root]) == root
            except ValueError:                          # (another drive)
                inside = False
            if not inside:
                raise Refused(f"{key}: only files below {ROOT}")
            if not os.path.isfile(real):
                raise Refused(f"{key}: no such file")
    return params


def route(url, plugins=None, root=None):
    action, params = parse(url)
    params = checked(params, root)
    if plugins is None:
        from . import plugins as P
        plugins = P.get()
    fn = plugins.link_handler(action)
    if fn is None:
        raise Refused(f"no plug-in opens '{action}' links")
    return fn(params)


def main(url):
    try:
        route(url)
    except Refused as ex:
        from PySide6 import QtWidgets
        app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])     # noqa: F841
        QtWidgets.QMessageBox.warning(None, "Conjunction", f"This link is not opened: {ex}")
