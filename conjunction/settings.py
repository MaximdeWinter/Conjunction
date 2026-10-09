"""Settings - one menu for everything (Maxim 05.10.: "ein universelles Einstellungsmenü; Plug-ins bekommen dort ihren
eigenen Abschnitt"): General, Game, Tools, Plug-ins, then a section for each plug-in that has settings.
Kept in Conjunction's config (config.json): Conjunction's own under "settings" (the game's paths where they always
were: "game", "redkit", "radish"), the plug-ins' on / off and folders under "plugins", their values under
"plugin_settings".

    value(key, default)             "game.folder", "game.redkit", "tools.blender", "general.sound_off" ...
    set_value(key, v)
    plugin_values(id, sections)     a plug-in's values (its schema's defaults filled in), saved when set
    plugins_enabled() / set_enabled(id, on) / plugin_dirs() / add_plugin_dir(path)
    (the page: settings_view.SettingsPage)
"""
import glob
import os
import subprocess

from . import config

# Conjunction's own fields: (section, key, label, type, default, choices or None); the game's paths live at the top
# of the config as before (setup.py, build.py read them there)
TOP = {"game.folder": "game", "game.redkit": "redkit", "game.radish": "radish", "general.mode": "mode"}


def _gpus():
    """[(index, name)] of the graphics cards (nvidia-smi) - none: []."""
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=index,name", "--format=csv,noheader"], capture_output=True,
                             text=True, timeout=5, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    rows = []
    for line in out.splitlines():
        if "," in line:
            i, name = line.split(",", 1)
            rows.append((i.strip(), name.strip()))
    return rows


def _blender():
    """The newest Blender in Program Files, or ''."""
    found = sorted(glob.glob(r"C:\Program Files\Blender Foundation\Blender *\blender.exe"))
    return found[-1] if found else ""


def _default_gpu():
    gpus = _gpus()
    best = next((i for i, name in gpus if "5080" in name), None)       # (the PC's card for work: the 5080)
    return best if best is not None else (gpus[-1][0] if gpus else "auto")


FIELDS = [
    ("General", "general.sound_off", "Game sound off while editing", "bool", False, None),
    ("General", "general.experimental", "Experimental features", "bool", False, None),
    ("General", "general.check_updates", "Check for updates at start", "bool", False, None),
    ("Game", "game.folder", "The Witcher 3", "path", "", None),
    ("Game", "game.redkit", "REDkit", "path", "", None),
    ("Game", "game.radish", "radish", "path", "", None),
    ("Tools", "tools.blender", "Blender", "file", None, None),
]
SECTIONS = ["General", "Game", "Tools"]     # (Performance went to Motion's own settings, 06.10.)


def _default(key):
    if key == "tools.blender":
        return _blender()
    if key == "performance.gpu":
        return _default_gpu()
    return next((f[4] for f in FIELDS if f[1] == key), None)


def value(key, default=None, cfg=None):
    cfg = cfg if cfg is not None else config.load()
    if key in TOP:
        v = cfg.get(TOP[key])
    elif key == "general.sound_off":
        v = cfg.get("sound_off")
    else:
        sec, _, name = key.partition(".")
        v = (cfg.get("settings") or {}).get(sec, {}).get(name)
    if v in (None, ""):
        d = _default(key)
        return d if d not in (None, "") else default
    return v


def set_value(key, v):
    cfg = config.load()
    if key in TOP:
        cfg[TOP[key]] = v
        if key == "game.redkit" and v:
            cfg["wcc"] = os.path.join(v, "bin", "x64_RedKit", "wcc_lite.exe")
    elif key == "general.sound_off":
        cfg["sound_off"] = bool(v)
    else:
        sec, _, name = key.partition(".")
        cfg.setdefault("settings", {}).setdefault(sec, {})[name] = v
    config.save(cfg)


# --- plug-ins: on / off, folders, their values
def plugins_enabled(cfg=None):
    cfg = cfg if cfg is not None else config.load()
    return dict(((cfg.get("plugins") or {}).get("enabled") or {}))


def set_enabled(pid, on):
    cfg = config.load()
    cfg.setdefault("plugins", {}).setdefault("enabled", {})[pid] = bool(on)
    config.save(cfg)


def plugin_dirs(cfg=None):
    cfg = cfg if cfg is not None else config.load()
    return [d for d in ((cfg.get("plugins") or {}).get("dirs") or []) if d]


def add_plugin_dir(path):
    cfg = config.load()
    dirs = cfg.setdefault("plugins", {}).setdefault("dirs", [])
    if os.path.normcase(path) not in [os.path.normcase(d) for d in dirs]:
        dirs.append(path)
    config.save(cfg)


def remove_plugin_dir(path):
    cfg = config.load()
    dirs = (cfg.get("plugins") or {}).get("dirs") or []
    cfg.setdefault("plugins", {})["dirs"] = [d for d in dirs if os.path.normcase(d) != os.path.normcase(path)]
    config.save(cfg)


class PluginValues(dict):
    """A plug-in's settings: what was set, else its schema's default (looked up when asked: a plug-in may take its
    values before it declares its fields); setting one saves it."""

    def __init__(self, pid, sections, stored):
        super().__init__(stored)
        self.pid, self.sections = pid, sections

    def default(self, key):
        for _title, schema in self.sections:
            if isinstance(schema, list):
                for f in schema:
                    if f.get("key") == key:
                        return f.get("default")
        return None

    def __missing__(self, key):
        return self.default(key)

    def get(self, key, default=None):
        if key in self:
            return super().get(key)
        d = self.default(key)
        return d if d is not None else default

    def __setitem__(self, key, v):
        super().__setitem__(key, v)
        cfg = config.load()
        cfg.setdefault("plugin_settings", {}).setdefault(self.pid, {})[key] = v
        config.save(cfg)


def plugin_values(pid, sections):
    """A plug-in's values: `sections` its add_settings list (the same list: fields declared later count too)."""
    stored = (config.load().get("plugin_settings") or {}).get(pid) or {}
    return PluginValues(pid, sections, stored)
