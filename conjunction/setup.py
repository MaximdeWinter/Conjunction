"""Setup: everything Conjunction needs, checked and (after asking once) fixed.

    python -m conjunction.setup          check, fix what is missing, report

1. paths: the game, REDkit (wcc_lite cooks and packs), radish modding tools (encoders) - config.json
2. Conjunction's scripts, kept up to date: the runtime every quest made with Conjunction needs in
   <game>\\Mods\\modConjunctionRuntime (for everyone, also "only play"), the editor's in <game>\\Mods\\modConjunction (plus
   scripts of plugins - only when building quests)
3. game settings: [Game] DoNotPauseWhileStopped=true (the game keeps running without focus, so the editor app can
   talk to it while you click in its panel); a backup `*.vor_conjunction.bak` is made once
4. the catalog index
5. no start videos: the logos (20 s) and the photosensitivity warning (it waits for a key) are moved to
   <game>\\Mods_deaktiviert\\intro_videos - again at every start_game() (a game update or a file check brings them
   back); `restore_intro()` puts them back
6. the script extender (TW3SE, extender.py): the editor talks to the game through its pipe - any game with it
   will do, started by `start_game()` or from Steam
"""
import filecmp
import os
import shutil
import subprocess

from . import catalog, config, extender, plugins

HERE = os.path.dirname(os.path.abspath(__file__))
MOD_SCRIPTS = os.path.join(os.path.dirname(HERE), "mod", "scripts")            # the editor's (modding only)
RUNTIME_SCRIPTS = os.path.join(os.path.dirname(HERE), "mod", "runtime", "scripts")  # the quests' (everyone)
RUNTIME_MOD, EDITOR_MOD = "modConjunctionRuntime", "modConjunction"
RUNTIME_MARK = "runtime.txt"            # in Mods\modConjunctionRuntime: its version (the Nexus runtime brings it too)


def installed_runtime(cfg=None):
    """The version of the runtime in the game (runtime.txt), 0 when none says."""
    cfg = cfg or config.load()
    try:
        return int(open(os.path.join(cfg["game"], "Mods", RUNTIME_MOD, RUNTIME_MARK)).read().strip())
    except (OSError, ValueError):
        return 0
DOCS = os.path.expanduser(r"~\Documents\The Witcher 3")
SETTINGS = ["user.settings", "dx12user.settings"]
EXE = r"bin\x64_dx12\witcher3.exe"
INTRO = r"content\content0\movies\cutscenes\gamestart"
INTRO_PARTS = [r"bumpers\bumpers.usm", "epilepsy"]     # the logos; the warning, one video a language
PARKED = r"Mods_deaktiviert\intro_videos"


class Check:
    def __init__(self, name, ok, detail="", fix=None, closed_game=False):
        self.name, self.ok, self.detail, self.fix = name, ok, detail, fix
        self.closed_game = closed_game      # the fix only works while the game is not running

    def __repr__(self):
        return f"[{'ok' if self.ok else '--'}] {self.name}{': ' + self.detail if self.detail else ''}"


def _tree_differs(src, dst):
    if not os.path.isdir(dst):
        return True
    for root, _, files in os.walk(src):
        for f in files:
            a = os.path.join(root, f)
            b = os.path.join(dst, os.path.relpath(a, src))
            if not os.path.exists(b) or not filecmp.cmp(a, b, shallow=False):
                return True
    return False


def _script_names():
    """Relative paths of every script Conjunction's mod should hold (its own + the plugins', which go to local/)."""
    names = set()
    for root, _, files in os.walk(MOD_SCRIPTS):
        names.update(os.path.relpath(os.path.join(root, f), MOD_SCRIPTS).lower() for f in files)
    for extra in plugins.get().scripts():
        for root, _, files in os.walk(extra):
            names.update(os.path.join("local", os.path.relpath(os.path.join(root, f), extra)).lower() for f in files)
    return names


def _runtime_names():
    names = {os.path.relpath(os.path.join(root, f), RUNTIME_SCRIPTS).lower()
             for root, _, files in os.walk(RUNTIME_SCRIPTS) for f in files}
    for extra in plugins.get().scripts(runtime=True):  # (the plug-ins' runtime scripts: in its local/)
        for root, _, files in os.walk(extra):
            names.update(os.path.join("local", os.path.relpath(os.path.join(root, f), extra)).lower() for f in files)
    return names


def _leftovers(dst, keep=None):
    """Scripts in an installed mod of Conjunction it no longer has there (a removed or moved script would still be
    compiled - twice: the game would not start)."""
    if not os.path.isdir(dst):
        return []
    keep = _script_names() if keep is None else keep
    return [os.path.join(root, f) for root, _, files in os.walk(dst) for f in files
            if f.endswith(".ws") and os.path.relpath(os.path.join(root, f), dst).lower() not in keep]


def building(cfg=None):
    """Every install builds (06.10.: no choice between playing and building any more); the editor's mod is in the
    game only during an editing session (editor_mod_off)."""
    return True


def install_runtime(cfg=None):
    """The scripts every quest made with Conjunction calls (Cj*), as their own mod - the plug-ins' runtime scripts
    with them (api.add_scripts(..., runtime=True)); the item name lookup made from this game's catalog when there is
    one, else the one that comes with Conjunction."""
    cfg = cfg or config.load()
    from .packaging import RUNTIME_VERSION
    dst = os.path.join(cfg["game"], "Mods", RUNTIME_MOD, "content", "scripts")
    if installed_runtime(cfg) > RUNTIME_VERSION:    # a newer one (the Nexus runtime): it serves every older quest
        print(f"a newer Conjunction Runtime ({installed_runtime(cfg)}) is in the game - kept")
        return dst
    shutil.copytree(RUNTIME_SCRIPTS, dst, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("*.bak*"))  # (not the backups of a patch)
    for root, _d, files in os.walk(dst):            # (and none left from before: scripts_pending saw them as a
        for f in files:                             # change, a restart at every Build & Play - 06.10.)
            if ".bak" in f:
                os.remove(os.path.join(root, f))
    before = installed_runtime(cfg)
    with open(os.path.join(cfg["game"], "Mods", RUNTIME_MOD, RUNTIME_MARK), "w") as f:
        f.write(f"{RUNTIME_VERSION}\n")
    if 0 < before < RUNTIME_VERSION:                # said once at the next look (Maxim 07.10.)
        from . import updates
        updates.note(f"Conjunction Runtime updated to {RUNTIME_VERSION} in the game (it was {before})")
    for extra in plugins.get().scripts(runtime=True):
        shutil.copytree(extra, os.path.join(dst, "local"), dirs_exist_ok=True)
    for old in _leftovers(dst, _runtime_names()):
        os.remove(old)
    from . import assets, content
    try:
        packs = any(content.pack_index(p).get("items") for p in content.installed_packs(cfg["game"]))
    except OSError:
        packs = False
    if assets.Assets.ready() or packs:              # (a pack's items join the table - also without a catalog)
        assets.write_item_script(os.path.join(dst, "local"))
    return dst


def install_scripts(cfg=None):
    """The runtime always; the editor's scripts when building quests (else they go: a player needs none)."""
    cfg = cfg or config.load()
    install_runtime(cfg)
    dst = os.path.join(cfg["game"], "Mods", EDITOR_MOD, "content", "scripts")
    if not building(cfg):
        if os.path.isdir(os.path.dirname(dst)):
            shutil.rmtree(os.path.dirname(os.path.dirname(dst)), ignore_errors=True)
        return None
    shutil.copytree(MOD_SCRIPTS, dst, dirs_exist_ok=True, ignore=shutil.ignore_patterns("*.bak*"))
    for root, _d, files in os.walk(dst):            # (as the runtime: no backup of a patch in the game)
        for f in files:
            if ".bak" in f:
                os.remove(os.path.join(root, f))
    for extra in plugins.get().scripts():
        shutil.copytree(extra, os.path.join(dst, "local"), dirs_exist_ok=True)
    for old in _leftovers(dst):             # only inside Conjunction's own mod folder (the runtime's moved out)
        os.remove(old)
    # the editor's sessions (sessions.py): a game definition per world and the main quest that jumps into the story
    try:
        from . import sessions
        from .bundles import Depot
        if not os.path.exists(os.path.join(cfg["game"], "Mods", sessions.MOD, "content", "metadata.store")):
            sessions.build_mod(Depot(), cfg["game"], log=lambda *_a: None)
    except Exception as ex:                 # noqa: BLE001 - no game files to make them from: no sessions
        print("[setup] no editor sessions:", ex)
    return dst


def editor_mod_off(cfg=None):
    """The editor's script mod out of the game while no editing session runs (05.10.: it imports TW3SE's natives -
    a game started without TW3SE, in DirectX 11, or after a patch TW3SE does not know yet then fails to compile its
    scripts and quits by itself). The runtime stays: it needs no TW3SE. -> True when it was taken out."""
    cfg = cfg or config.load()
    mod = os.path.join(cfg.get("game", ""), "Mods", EDITOR_MOD)
    if not cfg.get("game") or not os.path.isdir(mod) or game_running():
        return False
    shutil.rmtree(mod, ignore_errors=True)
    return not os.path.isdir(mod)


def scripts_pending(cfg=None):
    """Would install_scripts change the game's scripts? (A running game compiled them at its start: new ones need a
    restart - Build & Play's live loading checks this.) Made into a folder of its own and compared."""
    import tempfile
    cfg = cfg or config.load()
    tmp = tempfile.mkdtemp(prefix="cj_scripts_")
    try:
        install_scripts(dict(cfg, game=tmp))
        for mod in (RUNTIME_MOD, EDITOR_MOD):
            made = os.path.join(tmp, "Mods", mod, "content", "scripts")
            there = os.path.join(cfg["game"], "Mods", mod, "content", "scripts")
            if os.path.isdir(made) != os.path.isdir(there):
                return True
            if os.path.isdir(made) and (_tree_differs(made, there) or _tree_differs(there, made)):
                return True
        return False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def settings_ok(path):
    if not os.path.exists(path):
        return False
    in_game = False
    for line in open(path, encoding="utf-8", errors="replace"):
        s = line.strip()
        if s.startswith("["):
            in_game = s == "[Game]"
        elif in_game and s.replace(" ", "").lower() == "donotpausewhilestopped=true":
            return True
    return False


def fix_settings(path):
    """Add DoNotPauseWhileStopped=true to [Game] (backup first). The game must not run: it writes the file on exit."""
    if not os.path.exists(path + ".vor_conjunction.bak"):
        shutil.copy(path, path + ".vor_conjunction.bak")
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    out, done, in_game = [], False, False
    for line in lines:
        s = line.strip()
        if s.startswith("[") and in_game and not done:
            out.append("DoNotPauseWhileStopped=true")
            done = True
        if s.startswith("["):
            in_game = s == "[Game]"
        if in_game and s.lower().startswith("donotpausewhilestopped"):
            continue
        out.append(line)
    if not done:
        if not in_game:
            out.append("[Game]")
        out.append("DoNotPauseWhileStopped=true")
    open(path, "w", encoding="utf-8", newline="\r\n").write("\n".join(out) + "\n")


def intro_files(game, parked=False):
    """The start videos (paths below the gamestart folder) in the game, or in the parking folder."""
    base = os.path.join(game, PARKED if parked else "", INTRO)
    out = []
    for part in INTRO_PARTS:
        p = os.path.join(base, part)
        if os.path.isfile(p):
            out.append(part)
        elif os.path.isdir(p):
            out += [os.path.join(part, f) for f in sorted(os.listdir(p)) if f.lower().endswith(".usm")]
    return out


def skip_intro(cfg=None):
    """Move the start videos out of the game (a newer copy replaces the parked one). -> how many moved."""
    game = (cfg or config.load())["game"]
    moved = 0
    for rel in intro_files(game):
        dst = os.path.join(game, PARKED, INTRO, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.exists(dst):
            os.remove(dst)
        shutil.move(os.path.join(game, INTRO, rel), dst)
        moved += 1
    return moved


def restore_intro(cfg=None):
    """Put the start videos back."""
    game = (cfg or config.load())["game"]
    for rel in intro_files(game, parked=True):
        dst = os.path.join(game, INTRO, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if not os.path.exists(dst):
            shutil.move(os.path.join(game, PARKED, INTRO, rel), dst)


def game_running():
    """Is this process's game running? (two may: the background game for tests and Maxim's - bg.our_pids)"""
    from . import bg
    return bool(bg.our_pids())


def game_link_up():
    """True if this Conjunction's game answers through the script extender - an editable game the editor can attach to
    instead of starting another one, however it was started."""
    from . import bg, tw3se
    return tw3se.ready(bg.our_pids())


def start_game(cfg=None):
    cfg = cfg or config.load()
    from . import bg
    if cfg.get("game_in_background") or bg.BACKGROUND:  # tests beside Maxim's work: bg.py (the 4060 Ti, no focus)
        bg.start(cfg=cfg)
        return
    # Don't start a second game. One that answers through the script extender is attached to; one without it
    # (started before the extender was put in) has to go first.
    if game_link_up():
        print("the game is running already - attaching to it instead of starting a new one")
        return
    if bg.game_pids():
        print("Witcher 3 is running without the script extender (it was started before Conjunction put it in); "
              "close it and try again")
        return
    st, detail = extender.state(cfg)
    if st != "ok":
        if extender.source(cfg) is not None:        # the developer's build
            extender.install(cfg)
        elif os.path.isdir(os.path.join(cfg["game"], "Mods", EDITOR_MOD)):
            # (players install TW3SE themselves - Maxim 08.10.; the editor's scripts need it, a game to play does not)
            raise RuntimeError(detail)
    exe = os.path.join(cfg["game"], EXE)
    # the remaster (5.0) crashes in its Steam module when started without Steam's app id (GOG does not need it)
    env = dict(os.environ, SteamAppId="292030", SteamGameId="292030")
    if cfg.get("skip_intro", True):
        try:
            skip_intro(cfg)
        except OSError:                                 # a video in use: it plays this once
            pass
    subprocess.Popen([exe, "--launcher-skip"], cwd=os.path.dirname(exe), env=env)


def _idle(seconds):
    """Wait without freezing the app (Windows calls a window that handles nothing for a while 'not responding')."""
    import time
    end = time.time() + seconds
    try:
        from PySide6 import QtCore, QtWidgets
        app = QtWidgets.QApplication.instance()
        if app is not None and QtCore.QThread.currentThread() is not app.thread():
            app = None                          # (asked from a thread: only the window's own thread may do this)
    except ImportError:
        app = None
    while True:
        if app is not None:
            app.processEvents()
        left = end - time.time()
        if left <= 0:
            return
        time.sleep(min(0.05, left))


def wait_loaded(timeout=900, tick=None):
    """Until the game has a save loaded. -> ("loaded", where-line) | ("compile_error", text) | ("gone", "") |
    ("timeout", ""). `tick(state, seconds)` is called about once a second (for a progress label)."""
    import time
    from .compile_errors import read as compile_errors
    from .gamelink import run
    t0, seen = time.time(), False
    while time.time() - t0 < timeout:
        if not game_running():              # (every game but the background one: started here or attached to)
            # just started: not in the process list for a moment (night 01.10.: 'did not come up (gone)' at once)
            if seen or time.time() - t0 > 90:
                return "gone", ""
            if tick:
                tick("starting", int(time.time() - t0))
            _idle(1.0)
            continue
        seen = True
        err = compile_errors()
        if err:
            return "compile_error", err
        try:
            lines = run(["cj_where()"], 0.5)
            where = next((ln for ln in lines if "world=levels" in ln or "world=dlc" in ln), None)
            if where:
                return "loaded", where
            state = "menu / loading a save" if lines else "starting"
        except OSError:
            state = "starting"
        if tick:
            tick(state, int(time.time() - t0))
        _idle(1.0)
    return "timeout", ""


def close_crash_reports(cfg=None):
    """The game's own crash report windows (bin\\x64_dx12\\crashreporter) closed without sending - one stays open for
    every crash (night test 07.10.: seven on the desktop). Only those of the game's folder. -> how many."""
    import ctypes
    from ctypes import wintypes
    from .bg import _ProcessEntry
    game = os.path.normcase(os.path.abspath((cfg or config.load()).get("game") or ""))
    if not game:
        return 0
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    k32.OpenProcess.restype = wintypes.HANDLE
    snap = k32.CreateToolhelp32Snapshot(0x00000002, 0)          # TH32CS_SNAPPROCESS
    if not snap or snap == wintypes.HANDLE(-1).value:
        return 0
    found = []
    try:
        e = _ProcessEntry()
        e.dwSize = ctypes.sizeof(e)
        ok = k32.Process32FirstW(snap, ctypes.byref(e))
        while ok:
            if e.szExeFile.lower() == "crashreporter.exe":
                found.append(int(e.th32ProcessID))
            ok = k32.Process32NextW(snap, ctypes.byref(e))
    finally:
        k32.CloseHandle(snap)
    closed = 0
    for pid in found:
        h = k32.OpenProcess(0x1000 | 0x0001, False, pid)       # QUERY_LIMITED_INFORMATION | TERMINATE
        if not h:
            continue
        try:
            buf = ctypes.create_unicode_buffer(1024)
            size = wintypes.DWORD(1024)
            if k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)) and \
                    os.path.normcase(buf.value).startswith(game + os.sep):
                closed += bool(k32.TerminateProcess(h, 1))
        finally:
            k32.CloseHandle(h)
    return closed


def _restored(path):
    """Has the game finished loading a save since it started? (TW3SE's log - begun anew at each start - says
    'game loaded (RestoreSession)'.) None when there is no log to ask."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return "(RestoreSession)" in f.read()
    except OSError:
        return None


def wait_loaded_settled(timeout=900, tick=None, log=print, settle=15.0, tries=3):
    """wait_loaded - and the game watched for `settle` seconds after the save has really loaded: in an editing
    session it crashes now and then a few seconds after a load (night test 07.10.: about one load in five with the
    editor's mod, one in 27 without it; an access violation in the game's renderer, TW3SE not on the stack). Gone in
    that time: its crash report closed, the game started again with the same save - up to `tries` starts in all.
    The game answers before its loading screen is over: the end of the load is read from TW3SE's log."""
    import time
    from .extender import log_path
    result = ("timeout", "")
    for n in range(1, tries + 1):
        result = wait_loaded(timeout, tick)
        if result[0] != "loaded":
            return result
        t = time.time()
        while time.time() - t < 90 and game_running() and _restored(log_path()) is False:
            _idle(0.5)                                  # (the loading screen: until the save is restored)
        t = time.time()
        while time.time() - t < settle and game_running():
            _idle(0.5)
        if game_running():
            return result
        _idle(2.0)                                      # (its crash report opens a moment after)
        close_crash_reports()
        if n == tries:
            return "gone", ""
        log(f"[play] the game crashed right after loading the save - starting it again ({n + 1} of {tries})")
        start_game()
    return result


EULA_KEY = r"Software\CD Projekt RED\Mod Tools\1.0"


def redkit_eula_hidden():
    """HKCU\\Software\\CD Projekt RED\\Mod Tools\\1.0 DoNotShowEula (1 = accepted, wcc_lite runs without asking);
    None if the key is not there."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, EULA_KEY) as k:
            v = winreg.QueryValueEx(k, "DoNotShowEula")[0]
        return any(v) if isinstance(v, bytes) else bool(v)
    except OSError:
        return None


def keep_redkit_eula():
    """wcc_lite (REDkit, 29.09.) reads DoNotShowEula into a 1-byte buffer: the DWORD 1 it writes when the user
    accepts never fits, the read fails, it writes 0 over it and asks again at every start. The user's own 1 is kept
    as the 1-byte value it can read. Never sets anything the user has not accepted in its window."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, EULA_KEY, 0,
                            winreg.KEY_QUERY_VALUE | winreg.KEY_SET_VALUE) as k:
            v, kind = winreg.QueryValueEx(k, "DoNotShowEula")
            if kind == winreg.REG_DWORD and v == 1:
                winreg.SetValueEx(k, "DoNotShowEula", 0, winreg.REG_BINARY, b"\x01")
                return True
    except OSError:
        pass
    return False


def checks():
    cfg = config.load()
    out = [Check("game", os.path.exists(os.path.join(cfg["game"], EXE)), cfg["game"]),
           Check("REDkit (wcc_lite)", os.path.exists(cfg.get("wcc", "")), cfg.get("wcc", "")),
           Check("radish modding tools", os.path.exists(os.path.join(cfg.get("radish", ""), "w2quest.exe")),
                 cfg.get("radish", "") + "  (nexusmods.com/witcher3/mods/3620)")]
    if out[0].ok:
        runtime = os.path.join(cfg["game"], "Mods", RUNTIME_MOD, "content", "scripts")
        stale = _tree_differs(RUNTIME_SCRIPTS, runtime) or bool(_leftovers(runtime, _runtime_names()))
        # only the runtime: the editor's mod goes in when a project is opened and out after the session
        # (editor_mod_off). Put in at every start, it stayed in a game that was running - and a game started later
        # without TW3SE quit by itself (06.10.)
        out.append(Check("script mods (runtime)", not stale, "up to date" if not stale else "missing or old",
                         fix=lambda: install_runtime(cfg)))
    for name in SETTINGS:
        p = os.path.join(DOCS, name)
        if os.path.exists(p):
            ok = settings_ok(p)
            out.append(Check(f"{name}: DoNotPauseWhileStopped", ok, "" if ok else "the game pauses without focus",
                             fix=(lambda p=p: fix_settings(p)), closed_game=True))
    if out[0].ok and cfg.get("skip_intro", True):
        videos = intro_files(cfg["game"])
        out.append(Check("start videos skipped", not videos, "" if not videos else f"{len(videos)} in the game",
                         fix=lambda: skip_intro(cfg), closed_game=True))
    eula = redkit_eula_hidden()
    if eula is not None:
        out.append(Check("REDkit EULA accepted", eula, "" if eula else
                         "wcc_lite will stop at its EULA window - start the REDkit once and accept it"))
    if out[0].ok:
        st, detail = extender.state(cfg)
        out.append(Check("script extender (TW3SE)", st == "ok", detail or st,
                         fix=(lambda: extender.install(cfg)) if st in ("missing", "old", "unsupported") and extender.source(cfg)
                         else None, closed_game=True))
    has_cat = os.path.exists(catalog.PATH)
    out.append(Check("catalog index", has_cat, catalog.PATH, fix=catalog.build))
    return out


def main():
    for c in checks():
        if not c.ok and c.fix:
            if c.closed_game and game_running():
                print(f"{c}  -> close the game first")
                continue
            c.fix()
            c.ok, c.detail = True, "fixed"
        print(c)
    for folder, err in plugins.get().failed:
        print(f"[--] plugin {folder}: {err.strip().splitlines()[-1]}")
    for p in plugins.get().loaded:
        print(f"[ok] plugin {p.meta.get('name')}")


if __name__ == "__main__":
    main()
