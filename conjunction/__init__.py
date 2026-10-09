"""conjunction.

Every child process of Conjunction starts without a console window of its own (CREATE_NO_WINDOW). A suite that has no
console itself (started detached) would otherwise open a terminal for each console program it runs - 01.10.: the
background suite asked tasklist several times a second, each time a window came up and took Maxim's focus.
"""
__version__ = "0.1.0"
APP_NAME = "Conjunction"        # what people see (titles, pages, the exe); the package and its folders stay conjunction

import subprocess as _subprocess
import sys as _sys

if _sys.platform == "win32" and not getattr(_subprocess.Popen, "_cj_no_window", False):
    _NO_WINDOW, _OWN_CONSOLE, _DETACHED = 0x08000000, 0x00000010, 0x00000008
    _popen_init = _subprocess.Popen.__init__

    def _init(self, *args, creationflags=0, **kwargs):
        if not creationflags & (_OWN_CONSOLE | _DETACHED):      # (asked for a console or none at all: as asked)
            creationflags |= _NO_WINDOW
        _popen_init(self, *args, creationflags=creationflags, **kwargs)

    _subprocess.Popen.__init__ = _init
    _subprocess.Popen._cj_no_window = True

# YAML read by libyaml where it is there (02.10.: Maxim's 112 project files - 1.7 s in Python, 0.15 s in libyaml, the
# same data): every yaml.safe_load of Conjunction (projects, places, plugins) goes through it
try:
    import yaml as _yaml
    if getattr(_yaml, "__with_libyaml__", False) and not getattr(_yaml.safe_load, "_cj", False):
        def _safe_load(stream, _load=_yaml.load, _loader=_yaml.CSafeLoader):
            return _load(stream, Loader=_loader)
        _safe_load._cj = True
        _yaml.safe_load = _safe_load
except ImportError:                                 # (Conjunction needs yaml; a tool that does not: fine)
    pass
