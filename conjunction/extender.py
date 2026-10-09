"""The script extender (TW3SE) in the game: Conjunction talks to the game through it (gamelink.py). Players get it from
its own Nexus page (Maxim 08.10.: a requirement, not part of Conjunction) - Conjunction checks at its start that it
is there and new enough, and shows the page when it is not.

    <game>\\bin\\x64_dx12\\dinput8.dll           the loader
    <game>\\bin\\x64_dx12\\tw3se\\tw3se.dll       the extender (its CHANGELOG.md beside it says the version)

On the developer's machine config `extender_build` (the extender's build folder) puts that build into the game - kept
up to date as before; without it Conjunction installs nothing."""
import filecmp
import os
import re
import shutil
import struct

from . import config

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = (("dinput8.dll", ("bin", "x64_dx12", "dinput8.dll")),
         (os.path.join("tw3se", "tw3se.dll"), ("bin", "x64_dx12", "tw3se", "tw3se.dll")))
DEV_BUILD = r"C:\Desktop\tw3se\build"
NEEDS = "0.1.1"             # the oldest TW3SE this Conjunction works with (0.1.1: game patch 5.01)


def page():
    from .packaging import TW3SE_PAGE
    return TW3SE_PAGE or "https://www.nexusmods.com/witcher3"


def _ver(v):
    return tuple(int(x) for x in re.findall(r"\d+", str(v))[:3]) or (0,)


def installed_version(cfg=None):
    """The version of the TW3SE in the game: its CHANGELOG.md (the first '## x.y.z'), else the first line of its log;
    "" when neither says."""
    cfg = cfg or config.load()
    folder = _game_file(cfg, ("bin", "x64_dx12", "tw3se"))
    for name, pattern in (("CHANGELOG.md", r"^##\s+(\d+\.\d+\.\d+)"), ("tw3se.log", r"TW3SE (\d+\.\d+\.\d+) in pid")):
        try:
            m = re.search(pattern, open(os.path.join(folder, name), encoding="utf-8", errors="replace").read(4000),
                          re.M)
        except OSError:
            continue
        if m:
            return m.group(1)
    return ""


def version(cfg=None):
    """The TW3SE in the game (updates.py compares it with the newest)."""
    try:
        return installed_version(cfg)
    except Exception:                               # noqa: BLE001 - no game folder yet
        return ""


def source(cfg=None):
    """The developer's build to install (config extender_build), or None - players install TW3SE themselves."""
    cfg = cfg or config.load()
    folder = cfg.get("extender_build")
    if folder and all(os.path.exists(os.path.join(folder, rel)) for rel, _ in FILES):
        return folder
    return None


def _game_file(cfg, parts):
    return os.path.join(cfg["game"], *parts)


def state(cfg=None):
    """("ok" | "missing" | "old" | "unsupported", detail): is TW3SE in the game, new enough (the developer's build: the
    same one), and did it run on this build of the game (unsupported: its log says it stayed off)?"""
    cfg = cfg or config.load()
    present = all(os.path.exists(_game_file(cfg, parts)) for _, parts in FILES)
    if not present:
        return "missing", f"TW3SE is missing - download it from {page()}"
    src = source(cfg)
    if src is not None:                             # the developer's build: the game has exactly it
        same = all(filecmp.cmp(os.path.join(src, rel), _game_file(cfg, parts), shallow=False) for rel, parts in FILES)
        return ("ok", "the build from extender_build") if same else ("old", "another build than extender_build")
    v = installed_version(cfg)
    if v and _ver(v) < _ver(NEEDS):
        return "old", f"TW3SE {v} is too old (Conjunction needs {NEEDS} or newer) - update it from {page()}"
    if passive(cfg):
        return "unsupported", (f"TW3SE {v} stays off on this version of the game (its log says so) - update it from "
                               f"{page()}")
    return "ok", f"TW3SE {v}" if v else "TW3SE installed"


def game_build(cfg=None):
    """The build of the game's witcher3.exe (its PE time stamp, the number TW3SE logs), or None."""
    cfg = cfg or config.load()
    try:
        with open(_game_file(cfg, ("bin", "x64_dx12", "witcher3.exe")), "rb") as f:
            head = f.read(4096)
        pe = struct.unpack_from("<I", head, 0x3C)[0]
        return struct.unpack_from("<I", head, pe + 8)[0]
    except (OSError, struct.error):
        return None


def passive(cfg=None):
    """True when TW3SE's log (written anew at each game start) is of this build of the game and says TW3SE stayed off:
    it found not every place in the game (08.10., patch 5.01: 0.1.0 stayed off, and the editor's scripts that
    import its functions closed the game)."""
    cfg = cfg or config.load()
    try:
        log = open(log_path(cfg), encoding="utf-8", errors="replace").read(400000)
    except OSError:
        return False
    m = re.search(r"witcher3\.exe build ([0-9a-f]{8})", log)
    build = game_build(cfg)
    return bool(m and build is not None and int(m.group(1), 16) == build and "stays passive" in log)


def _contains(path, *texts):
    try:
        data = open(path, "rb").read()
    except OSError:
        return False
    return any(t in data for t in texts)


def keep_other_dinput8(cfg=None):
    """Another mod's dinput8.dll where TW3SE's loader goes: moved where it keeps working, never overwritten (06.10.).
    The Ultimate ASI Loader -> winmm.dll (a name it knows, the game loads it); any other -> dinput8_chain.dll (TW3SE's
    loader loads it first). A name already taken: kept beside as a backup. -> what was done, or ""."""
    cfg = cfg or config.load()
    binx = _game_file(cfg, ("bin", "x64_dx12"))
    d8 = os.path.join(binx, "dinput8.dll")
    if not os.path.exists(d8) or _contains(d8, "\\tw3se\\tw3se.dll".encode("utf-16-le")):
        return ""                               # none, or TW3SE's own loader
    ual = _contains(d8, b"Ultimate-ASI-Loader", b"Ultimate ASI Loader")
    for name in (("winmm.dll",) if ual else ("dinput8_chain.dll",)) + ("dinput8_before_tw3se.dll",):
        if not os.path.exists(os.path.join(binx, name)):
            os.replace(d8, os.path.join(binx, name))
            what = "the Ultimate ASI Loader" if ual else "another mod's dinput8.dll"
            return f"{what} moved to {name}" + ("" if name != "dinput8_before_tw3se.dll" else " (kept, not loaded)")
    raise FileExistsError("another dinput8.dll is in the game and every name to keep it under is taken")


def install(cfg=None):
    """The developer's build (config extender_build) into the game (it must be closed: it holds the DLLs). Another
    mod's dinput8.dll is moved first (keep_other_dinput8) -> what was moved, or ""."""
    cfg = cfg or config.load()
    src = source(cfg)
    if src is None:
        st, detail = state(cfg)
        if st == "ok":
            return ""                               # (the player's own TW3SE: nothing to put in)
        raise FileNotFoundError(detail)
    moved = keep_other_dinput8(cfg)
    if moved:
        print("TW3SE:", moved)
    for rel, parts in FILES:
        dst = _game_file(cfg, parts)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(src, rel), dst)
    return moved


def log_path(cfg=None):
    cfg = cfg or config.load()
    return _game_file(cfg, ("bin", "x64_dx12", "tw3se", "tw3se.log"))
