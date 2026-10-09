"""Paths of the local installation. First run writes a config with guesses; the setup wizard will fill it later.

    Documents\\Conjunction\\data\\config.json : {"game": ..., "redkit": ..., "wcc": ..., "radish": ...}
                                          (paths.py: the one folder; an older one in AppData moves in once)
"""
import json
import os

from . import paths

PATH = os.path.join(paths.DATA, "config.json")
DEFAULT_PATH = PATH

GUESSES = {
    "game": [r"C:\Program Files (x86)\Steam\steamapps\common\The Witcher 3",
             r"C:\Program Files (x86)\GOG Galaxy\Games\The Witcher 3 Wild Hunt GOTY",
             r"C:\GOG Games\The Witcher 3 Wild Hunt GOTY"],
    "redkit": [r"C:\Program Files (x86)\Steam\steamapps\common\The Witcher 3 REDkit"],
    "radish": [r"C:\Apps\radish-tools", r"C:\radish-tools", r"C:\Modding\radish-tools"],
}
STEAM_NAMES = {"game": "The Witcher 3", "redkit": "The Witcher 3 REDkit"}


def steam_libraries():
    """Every Steam library folder of this PC (read from Steam's own list - Steam itself is not touched)."""
    out = []
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as k:
            steam = winreg.QueryValueEx(k, "SteamPath")[0]
    except OSError:
        return out
    out.append(os.path.normpath(steam))
    vdf = os.path.join(steam, "steamapps", "libraryfolders.vdf")
    try:
        import re
        text = open(vdf, encoding="utf-8", errors="replace").read()
        out += [os.path.normpath(m.replace("\\\\", "\\")) for m in re.findall(r'"path"\s+"([^"]+)"', text)]
    except OSError:
        pass
    return list(dict.fromkeys(out))


def gog_game():
    """The Witcher 3 installed by GOG (its registry entry), or None."""
    try:
        import winreg
        root = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\GOG.com\Games")
    except OSError:
        return None
    k = 0
    while True:
        try:
            sub = winreg.EnumKey(root, k)
        except OSError:
            return None
        k += 1
        try:
            with winreg.OpenKey(root, sub) as g:
                name = str(winreg.QueryValueEx(g, "gameName")[0])
                path = str(winreg.QueryValueEx(g, "path")[0])
        except OSError:
            continue
        if "witcher 3" in name.lower() and os.path.isdir(path):
            return path


def find(key):
    """Where `key` (game, redkit, radish) is on this PC: Steam's libraries, GOG, the usual folders - or None."""
    found = []
    if key in STEAM_NAMES:
        found += [os.path.join(lib, "steamapps", "common", STEAM_NAMES[key]) for lib in steam_libraries()]
    if key == "game":
        g = gog_game()
        if g:
            found.append(g)
    found += GUESSES.get(key, [])
    return next((p for p in found if os.path.isdir(p)), None)


def load():
    if not os.path.exists(PATH) and PATH == DEFAULT_PATH:
        paths.migrate()                         # an older Conjunction's settings and caches move in (once)
    if os.path.exists(PATH):
        with open(PATH, encoding="utf-8") as f:
            cfg = json.load(f)
    else:
        cfg = {k: find(k) or v[0] for k, v in GUESSES.items()}
        cfg["wcc"] = os.path.join(cfg["redkit"], "bin", "x64_RedKit", "wcc_lite.exe")
        os.makedirs(os.path.dirname(PATH), exist_ok=True)
        json.dump(cfg, open(PATH, "w", encoding="utf-8"), indent=1)
    layer = os.environ.get("CJ_CONFIG_LAYER")  # the background Conjunction's own settings over Maxim's (bg.py)
    if layer and os.path.exists(layer):
        with open(layer, encoding="utf-8") as f:
            cfg.update(json.load(f))
    if os.environ.get("CJ_GAME_DIR"):          # the background game's own game folder (bg.py): only in this process
        cfg["game"] = os.environ["CJ_GAME_DIR"]
    return cfg


def save(cfg):
    """Written whole to a file beside it, then put in its place: a reader at the same moment (another suite window,
    tests running side by side) never sees half a file."""
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    layer = os.environ.get("CJ_CONFIG_LAYER")
    if layer:                                   # the background suite: only what differs from Maxim's, in its layer
        base = json.load(open(PATH, encoding="utf-8")) if os.path.exists(PATH) else {}
        diff = {k: v for k, v in cfg.items() if k != "game" and base.get(k) != v}
        os.makedirs(os.path.dirname(layer), exist_ok=True)
        tmp = f"{layer}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(diff, f, indent=1)
        os.replace(tmp, layer)
        return
    if os.environ.get("CJ_GAME_DIR") and cfg.get("game") == os.environ["CJ_GAME_DIR"] and os.path.exists(PATH):
        cfg = dict(cfg, game=json.load(open(PATH, encoding="utf-8")).get("game"))     # never kept: Maxim's game stays
    tmp = f"{PATH}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=1)
    for _ in range(20):
        try:
            os.replace(tmp, PATH)
            return
        except PermissionError:                     # Windows: the file is open for reading just now
            import time
            time.sleep(0.05)
    os.replace(tmp, PATH)


# --- which game this process talks to (Maxim, 01.10.: a background game for tests beside his own - bg.py sets these
# for the background one: its own debug port, its own Documents folder, its own agent port)
def game_docs():
    """The game's Documents folder 'The Witcher 3' (settings, saves, scriptslog.txt)."""
    return os.environ.get("CJ_GAME_DOCS") or os.path.join(os.path.expanduser("~"), "Documents", "The Witcher 3")


def game_log():
    return os.path.join(game_docs(), "scriptslog.txt")


def game_port():
    """The game's script debugger port (37001; the background game's: bg.PORT)."""
    return int(os.environ.get("CJ_GAME_PORT") or 37001)


def agent_port(default=37110):
    return int(os.environ.get("CJ_AGENT_PORT") or default)
