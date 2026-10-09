"""conjunction - start here.

    python -m conjunction [project dir] [--place <place>]

Checks the setup (and fixes what it can), starts the game if it is not running (or attaches to one started from
Steam: the editor talks to it through the script extender), waits until a save is loaded and opens the editor over
it - in the project worked on last, or a new one (Maxim 04.10.: no choosing at the start; a project is whatever is
made in it, and the editor's project menu opens another).
In the game: F8 = editor on / off, C = catalog / places / quest / build panel.
"""
import argparse
import faulthandler
import os
import subprocess
import sys
import threading
import time

os.environ.setdefault("QT_ENABLE_HIGHDPI_SCALING", "0")
# a hard crash (02.10. 14:53: an access violation inside python, no traceback, Conjunction gone) leaves the stacks of
# all threads here - Documents\Conjunction\data\crash.log
try:
    from . import paths as _paths
    os.makedirs(_paths.DATA, exist_ok=True)
    _CRASH = open(os.path.join(_paths.DATA, "crash.log"), "a", encoding="utf-8")
    _CRASH.write(f"\n--- started {time.strftime('%Y-%m-%d %H:%M:%S')} pid {os.getpid()}\n")
    _CRASH.flush()
    faulthandler.enable(_CRASH, all_threads=True)
except OSError:
    pass

from PySide6 import QtCore, QtWidgets  # noqa: E402

from . import APP_NAME, config, setup  # noqa: E402
from .project import Project, last_or_new, own_copy, remember  # noqa: E402


def ask_paths():
    """The start on another machine: the game is looked for (Steam, GOG, usual folders) and asked for when it is not
    found; radish comes with Conjunction (unpacked and checked once); REDkit is found if it is there - without it
    everything but building works, and a build says it is missing. (Maxim 06.10.: no choice between playing and
    building any more.) -> "ok", None when closed."""
    cfg = config.load()
    changed = False
    from . import radish_tools                        # shipped with Conjunction: unpacked, checked (once per folder)
    if not os.path.isfile(os.path.join(cfg.get("radish", ""), "w2quest.exe")) or \
            cfg.get("radish_checked") != cfg.get("radish"):
        try:
            got = radish_tools.install(cfg.get("radish", ""), log=print)
            cfg["radish"], cfg["radish_checked"], changed = got, got, True
        except radish_tools.Bad as ex:
            print(f"radish: {ex}")
            from . import radish_view                 # (a requirement from its own page: its page, then the zip)
            got = radish_view.ask()
            if got:
                cfg["radish"], cfg["radish_checked"], changed = got, got, True
    wcc = lambda d: os.path.exists(os.path.join(d, "bin", "x64_RedKit", "wcc_lite.exe"))     # noqa: E731
    if not wcc(cfg.get("redkit", "")):
        found = config.find("redkit")
        if found and wcc(found):
            cfg["redkit"], changed = found, True
    game = lambda d: os.path.exists(os.path.join(d, setup.EXE))      # noqa: E731
    if not game(cfg.get("game", "")):
        found = config.find("game")
        if found and game(found):
            cfg["game"], changed = found, True
    while not game(cfg.get("game", "")):
        d = QtWidgets.QFileDialog.getExistingDirectory(None, "Where is The Witcher 3? (the folder with bin and "
                                                             "content)")
        if not d:
            return None
        cfg["game"], changed = os.path.normpath(d), True
    if changed:
        if cfg.get("redkit"):
            cfg["wcc"] = os.path.join(cfg["redkit"], "bin", "x64_RedKit", "wcc_lite.exe")
        config.save(cfg)
    return "ok"


def wait_for_game(app, label):
    """Until a save is loaded (the game shows its menu first); a script compile error is shown, not waited out.
    The asking runs in a thread: a question to a game still loading waits seconds for its answer, and the window
    froze ('not responding', the seconds jumping - 06.10.); the window counts the seconds itself."""
    import threading
    state = {"what": "starting", "result": None}

    def work():
        state["result"] = setup.wait_loaded_settled(              # (a crash right after the load: again)
            tick=lambda what, _s: state.__setitem__("what", what), log=lambda s: print(s, flush=True))
    t0 = time.time()
    worker = threading.Thread(target=work, daemon=True)
    worker.start()
    loop = QtCore.QEventLoop()
    timer = QtCore.QTimer()

    def tick():
        text = {"starting": "Starting game...", "menu / loading a save": "Loading save..."}.get(state["what"],
                                                                                              state["what"])
        label.setText(f"{text} {int(time.time() - t0)} s")
        if not worker.is_alive():
            loop.quit()
    timer.timeout.connect(tick)
    timer.start(200)
    tick()
    loop.exec()
    timer.stop()
    result, detail = state["result"] or ("gone", "")
    if result == "compile_error":
        QtWidgets.QMessageBox.critical(None, APP_NAME, "The game could not compile the scripts. No mods "
                                                            "work until this is fixed:\n\n" + detail)
    elif result != "loaded":
        QtWidgets.QMessageBox.warning(None, APP_NAME, f"Game didn't launch ({result})")
    return result == "loaded"


_LIBRARY = None


def wait_for_exit(pid, timeout_ms=20000):
    """Until a process has ended (or the timeout)."""
    import ctypes
    k32 = ctypes.windll.kernel32
    h = k32.OpenProcess(0x00100000, False, pid)         # SYNCHRONIZE
    if h:
        k32.WaitForSingleObject(h, timeout_ms)
        k32.CloseHandle(h)


def selftest(report):
    """Does this installation hold together (the release build too)? Every module loads, the files Conjunction brings
    are there, the windows build - nothing shown, nothing changed. -> report file: "ok" or what failed."""
    import importlib
    import pkgutil
    import traceback
    lines, bad = [], []
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pkg = os.path.dirname(os.path.abspath(__file__))
    import conjunction
    names = sorted(m.name for m in pkgutil.iter_modules(conjunction.__path__)
                   if m.name not in ("__main__", "uilab", "bg", "agent"))
    for name in names:
        try:
            importlib.import_module(f"conjunction.{name}")
        except Exception as e:                      # noqa: BLE001 - reported
            bad.append(f"module {name}: {e!r}")
    lines.append(f"modules: {len(names) - len([b for b in bad if b.startswith('module')])} / {len(names)}")
    root = os.path.dirname(pkg)
    for rel in ("conjunction/icons/package.svg", "conjunction/data/how_signing.html",
                "mod/runtime/scripts/local/conjunction_quest.ws",
                "mod/scripts/local/conjunction_editor.ws", "packs", "examples/bandit_camp/project.yml"):
        if not os.path.exists(os.path.join(root, rel)):
            bad.append(f"missing: {rel}")
    try:
        app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(sys.argv)
        from .icons import icon
        icon("package")
        from .tooltips import install as install_tips
        install_tips(app)
        from . import theme
        theme.install(app)
        lines.append("qt: " + QtCore.qVersion())
    except Exception:                               # noqa: BLE001
        bad.append("qt: " + traceback.format_exc(limit=3))
    import yaml
    import lz4.block                                # noqa: F401 - the bundles of the remaster
    from PIL import Image                           # noqa: F401 - pictures and icons
    lines.append(f"yaml {yaml.__version__}")
    checks = [("radish", _selftest_radish), ("extender", _selftest_extender), ("app", _selftest_app),
              ("bug report", _selftest_bugreport), ("signing", _selftest_signing)]
    for name, fn in checks:
        try:
            lines.append(f"{name}: {fn()}")
        except Exception:                           # noqa: BLE001 - reported
            bad.append(f"{name}: " + traceback.format_exc(limit=4))
    out = "\n".join(["ok" if not bad else "FAILED"] + lines + bad) + "\n"
    with open(report, "w", encoding="utf-8") as f:
        f.write(out)
    return 0 if not bad else 1


def _selftest_radish():
    """radish's Nexus zip is found - in the GitHub release beside the app (_internal\\third_party\\radish), else where a
    download lands (the Nexus release brings none: make_release puts it into the sandbox's Downloads) -, is the one
    from Nexus, unpacks (into Documents\\Conjunction\\tools) and checks against radish's list."""
    from . import radish_tools as R
    z = R.find_zip()
    if not z:
        raise RuntimeError("the radish zip is not found (beside the app or in Downloads)")
    dest = R.install("", log=lambda s: None)
    where = "brought by the release" if z == R.bundled_zip() else "from Downloads"
    return f"{os.path.basename(z)} {where}, unpacked, {len(R.expected(dest))} files as radish shipped them"


def _selftest_signing():
    """A profile made, a project signed and marked, its history checked, a changed step found (all in a scratch
    folder: nothing of this PC's profiles is touched)."""
    import shutil
    import tempfile
    from . import identity, marks, paths, provenance
    from .project import Project
    tmp = tempfile.mkdtemp()
    old = paths.IDENTITY
    try:
        paths.IDENTITY = os.path.join(tmp, "identity")
        cfg = config.load()
        keep = cfg.get("profile")
        p = identity.create("Self test")
        proj = Project.create(os.path.join(tmp, "p"), "selftest", "Self test")
        pos, rot = marks.stamp(proj, [10.0, 20.0, 1.5], [0.0, 0.0, 90.0])
        steps = provenance.read(proj.path)
        ok = provenance.check(steps, provenance.content_hash(proj.path)).ok
        steps[0]["name"] = "Someone else"
        bad = provenance.check(steps).ok
        score = marks.object_score([{"pos": pos, "rot": rot}], p.project_seed(proj.meta["uid"]))
        cfg = config.load()
        if keep is None:
            cfg.pop("profile", None)
        else:
            cfg["profile"] = keep
        config.save(cfg)
        if not ok or bad or score != (6, 6) or not marks.seed_is_theirs(proj.meta):
            raise RuntimeError(f"history ok {ok}, changed step found {not bad}, mark {score}")
        return "profile, signed history, a changed step found, the mark in a placed object 6 / 6"
    finally:
        paths.IDENTITY = old
        shutil.rmtree(tmp, ignore_errors=True)


def _selftest_extender():
    """TW3SE is a requirement (its own Nexus page): the check finds it missing in an empty game folder and names the
    page; Conjunction brings no copy."""
    import shutil
    import tempfile
    from . import extender
    game = tempfile.mkdtemp()
    try:
        st, detail = extender.state({"game": game})
        if st != "missing" or extender.page() not in detail:
            raise RuntimeError(f"the TW3SE check: {st} {detail}")
        if os.path.isdir(os.path.join(extender.ROOT, "extender")):
            raise RuntimeError("the release brings a copy of TW3SE")
    finally:
        shutil.rmtree(game, ignore_errors=True)
    return f"TW3SE a requirement ({extender.page()})"


def _selftest_app():
    """The app's window builds; in the release no experimental switch, no adult plug-in on."""
    from . import features, plugins
    from .app import AppWindow
    w = AppWindow(on_open=lambda p: None)
    names = [w.nav.item(k).text() for k in range(w.nav.count())]
    if names[:2] != ["Projects", "Library"] or names[-1] != "Settings":
        raise RuntimeError(f"pages: {names}")
    s = w.pages["Settings"]
    if features.released() and (("General", features.KEY) in s.fields or features.experimental()):
        raise RuntimeError("the experimental switch is in the release")
    adult = [m["id"] for m, st in plugins.get().listing() if m.get("adult") and st != "off"]
    if adult:
        raise RuntimeError(f"adult plug-ins on: {adult}")
    w.deleteLater()
    return f"pages {names}, experimental {'on' if features.experimental() else 'off'}"


def _selftest_bugreport():
    import zipfile
    from . import bugreport
    path = bugreport.collect(None, "self test", [], "")
    if "report.json" not in zipfile.ZipFile(path).namelist():
        raise RuntimeError("a report without report.json")
    return os.path.relpath(path, os.path.expanduser("~"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("project", nargs="?")
    ap.add_argument("--place", default=None)
    ap.add_argument("--background", action="store_true",
                    help="tests beside other work: the game on the second card, Conjunction invisible (bg.py)")
    ap.add_argument("--after", type=int, default=None,
                    help="wait until this process has ended (the editor opening another project)")
    ap.add_argument("--selftest", metavar="REPORT", default=None,
                    help="load every part, open the windows unseen, write what was found to REPORT and quit")
    args = ap.parse_args()
    if args.selftest:
        return selftest(args.selftest)
    from .bugreport import start_session_log
    start_session_log()                     # the session's output for bug reports (bugreport.py)
    app = QtWidgets.QApplication(sys.argv)
    # numbers as the English interface writes them (12.5, not 12,5 on a German Windows)
    QtCore.QLocale.setDefault(QtCore.QLocale(QtCore.QLocale.English, QtCore.QLocale.UnitedStates))
    if args.background:
        from . import bg
        bg.suite_in_background(app)
    from .tooltips import install as install_tips
    install_tips(app)
    from . import theme
    theme.install(app)                              # one look for the controls of every window
    if ask_paths() is None:
        return
    from .profile_view import first_hint            # a profile is opt-in (identity.py): said once, never asked for
    first_hint()
    from .extender_view import ask as tw3se_ready   # TW3SE comes from its own page: missing or old - its page shown
    tw3se_ready()
    problems = []
    for c in setup.checks():
        if not c.ok and c.fix and not (c.closed_game and setup.game_running()):
            c.fix()
            c.ok = True
        if not c.ok and c.name.startswith("game"):  # only the game is needed to start (a build says what it lacks)
            problems.append(str(c))
    if problems:
        QtWidgets.QMessageBox.warning(None, f"{APP_NAME} setup", "Not ready yet:\n\n" + "\n".join(problems))
        return
    try:                                            # conjunction: links (Motion's "open in Blender") - links.py
        from . import links
        links.register()
    except Exception as e:                          # noqa: BLE001 - links are a convenience
        print(f"[links] {e}", flush=True)
    # one Conjunction at a time (07.10.: a second one, started with a project, attached to the game beside the first -
    # both editors answered it): started again, the open one comes to the front. Opening another project from the
    # editor (--after): the one before has ended first
    if args.after:
        wait_for_exit(args.after)
    if not args.background and already_running():
        return
    if not (args.project or args.background or args.after):
        return app_first(app, args)                 # the app (Maxim 05.10.): the game only when a project is opened
    if not args.background:
        _hold(app)                                  # (the next one started sees this one)
    return in_game(app, args, args.project)


def _hold(app):
    """This Conjunction answers the next one started (already_running): it ends instead of attaching too."""
    from PySide6 import QtNetwork
    server = QtNetwork.QLocalServer(app)
    QtNetwork.QLocalServer.removeServer(SERVER)     # (a server left by one that crashed)
    server.listen(SERVER)

    def asked():
        while server.hasPendingConnections():
            server.nextPendingConnection().close()
    server.newConnection.connect(asked)
    app._cj_server = server


SERVER = "Conjunction-app"


def already_running():
    """Another Conjunction app is open: it is asked to come to the front -> True (this one then ends)."""
    from PySide6 import QtNetwork
    sock = QtNetwork.QLocalSocket()
    sock.connectToServer(SERVER)
    if not sock.waitForConnected(300):
        return False
    sock.write(b"show\n")
    sock.waitForBytesWritten(300)
    sock.disconnectFromServer()
    return True


def app_first(app, args):
    """The app without the game: its pages; a project opened from it starts the game and the editor. One app at a
    time: started again, the open one comes to the front (06.10.: two of them both answered F8)."""
    from PySide6 import QtNetwork
    from .app import AppWindow
    if already_running():
        return
    state = {"window": None}
    server = QtNetwork.QLocalServer()
    QtNetwork.QLocalServer.removeServer(SERVER)     # (a server left by one that crashed)
    server.listen(SERVER)

    def asked():
        while server.hasPendingConnections():
            server.nextPendingConnection().close()
        w = state["window"]
        if w is not None and not state.get("in_game"):
            w.showNormal()
            w.raise_()
            w.activateWindow()
    server.newConnection.connect(asked)
    state["server"] = server

    def session_over():
        state["in_game"] = False
        setup.editor_mod_off()                      # the game is gone: the editor's mod out of it again
        if state.get("path"):                       # what the session changed: a step in the history
            from . import provenance
            provenance.note_safely(state["path"], "edit")
        app.setQuitOnLastWindowClosed(True)
        state["window"].show()
        state["window"].raise_()

    def open_project(path):
        w = state["window"]
        state["path"] = own_copy(os.path.abspath(path))
        # the app's window goes, the wait for the game comes and goes, then the overlay (no window Qt counts): with
        # quit-on-last-window Qt ended Conjunction the moment the wait closed (06.10.: in the game, no editor, F8 dead)
        app.setQuitOnLastWindowClosed(False)
        state["in_game"] = True
        w.hide()
        if not setup.game_running():
            setup.install_scripts()                 # the editor's mod only for the session (setup.editor_mod_off)
        elif setup.scripts_pending():               # a game started without the editor's scripts (from Steam)
            setup.install_scripts()
            QtWidgets.QMessageBox.information(None, APP_NAME, "The game was started without Conjunction's editor "
                                                              "scripts. They are installed now. Please close the "
                                                              "game and open the project again")
            app.setQuitOnLastWindowClosed(True)
            state["in_game"] = False
            w.show()
            return
        ed = in_game(app, args, path, keep_running=True, on_gone=session_over)
        if ed is None:                              # (the game did not come up: back to the app)
            setup.editor_mod_off()
            app.setQuitOnLastWindowClosed(True)
            state["in_game"] = False
            w.show()
    # no editing session yet: the editor's mod is not in the game (a game started from Steam needs no TW3SE)
    setup.editor_mod_off()
    app.aboutToQuit.connect(setup.editor_mod_off)
    w = AppWindow(on_open=open_project)
    state["window"] = w
    if os.environ.get("CJ_NO_SPLASH"):
        w.show()
    else:                                           # the logo builds itself in the window, then the app (2 s)
        from .splash import play
        state["splash"] = play(w)
    # after the logo: a newer Conjunction / TW3SE / runtime (only when Settings > General asks for it), and what
    # Conjunction updated in the game by itself (Maxim 07.10.) - updates.py
    from . import settings as _S
    from . import updates
    asked = bool(_S.value("general.check_updates", False))
    found = {}
    if asked:
        threading.Thread(target=lambda: found.__setitem__("it", updates.check()), daemon=True).start()

    def say_updates(tries=[0]):
        if asked and "it" not in found and tries[0] < 20:      # (the check has 4 s at most)
            tries[0] += 1
            QtCore.QTimer.singleShot(500, say_updates)
            return
        notes = updates.take_notes()
        if found.get("it") or notes:
            state["updates"] = updates.show(state["window"], found.get("it"), notes)
    QtCore.QTimer.singleShot(2600, say_updates)
    app.exec()


def _others_in_game(project):
    """Is anything of another project, or an older run of this one, in the game folder?"""
    from . import in_game as _ig
    try:                                            # (every older run too: a run loaded beside another stays in the
        return bool(_ig.clear_for(project.path, dry=True))     # world, 07.10.)
    except Exception as ex:                         # noqa: BLE001 - unsure: the clean way
        print(f"[conjunction] the game folder unknown ({ex}): a clean start", flush=True)
        return True


def _restart_clean(app, project):
    """Quick save, the game closed (it holds its DLCs) - the start that follows parks what is not this project."""
    from . import bg
    from .gamelink import GameLink
    label = QtWidgets.QLabel(f"Starting the game again with only {project.meta.get('name') or project.id} in it "
                             "(automatic quick save)...")
    label.setWindowTitle(APP_NAME)
    label.setMargin(20)
    label.show()
    app.processEvents()
    folder = os.path.join(config.game_docs(), "gamesaves")

    def newest():
        try:
            return max((os.path.getmtime(os.path.join(folder, f)) for f in os.listdir(folder) if f.endswith(".sav")),
                       default=0.0)
        except OSError:
            return 0.0
    before = newest()
    try:
        GameLink(robust=True).exec("cj_quicksave()")
        t = time.time()
        while time.time() - t < 15 and not (newest() > before and time.time() - newest() > 0.5):
            app.processEvents()
            time.sleep(0.2)
    except Exception as ex:                         # noqa: BLE001 - the last save loads instead
        print(f"[conjunction] no quick save: {ex}", flush=True)
    for pid in bg.our_pids():
        subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
    t = time.time()
    while setup.game_running() and time.time() - t < 20:
        app.processEvents()
        time.sleep(0.3)
    label.close()


def in_game(app, args, project_path, keep_running=False, on_gone=None):
    """A project in the game: the game started (or the one running), a save loaded, the editor over it.
    keep_running: the app's event loop runs already (opened from the app); on_gone: what happens when the game has
    been gone a while (the app comes back - else Conjunction ends). -> the editor, None when the game did not come."""
    global _LIBRARY
    try:                                            # the quests to play, also when building (library.py)
        from .library_view import LibraryWindow
        _LIBRARY = LibraryWindow()                  # (synced on creation) - comes up when a quest lacks something
        _LIBRARY.watch_quests()
        if _LIBRARY.lacking and not args.background:
            _LIBRARY.come_up()
    except Exception as e:                          # noqa: BLE001 - building goes on; the library window says more
        print(f"[library] {e}", flush=True)
    if args.after:
        wait_for_exit(args.after)               # the editor switching projects: the one before lets go first
    path = own_copy(os.path.abspath(project_path or last_or_new()))
    remember(path)
    project = Project(path)
    project.signed()                                # the maker's mark, the history's step (marks.py, provenance.py)
    if setup.game_running() and _others_in_game(project):
        # another project (or an older run of this one) is in the running game: it starts again with only this
        # one in it (Maxim 07.10.: Conjunction closed, opened again on another project - it only attached)
        _restart_clean(app, project)
    if not setup.game_running():
        # the gate before every start (in_game.clear_for): only this project's current run in the game - its older
        # runs into its versions, every other project parked; what cannot go stops the start
        from . import in_game as _ig
        left = _ig.clear_for(path, log=lambda s: print(s, flush=True))
        if left:
            QtWidgets.QMessageBox.warning(None, APP_NAME, f"{', '.join(left)} cannot leave the game folder (a program "
                                                          f"holds it open). The game would load it beside this "
                                                          f"project. Close that program and open the project again")
            return None
        from .extender_view import ask as tw3se_ready
        if not tw3se_ready(opening=True):           # (the editor's scripts need TW3SE: without it the game quits)
            return None
        setup.install_scripts()                     # the editor's mod for this session (out again: editor_mod_off)
        setup.start_game()
    wait = QtWidgets.QLabel("Starting game...")
    wait.setWindowTitle(APP_NAME)
    from . import theme as _theme
    wait.setWindowIcon(_theme.window_icon())
    wait.setMinimumWidth(420)
    wait.setMargin(20)
    wait.show()
    ok = wait_for_game(app, wait)
    wait.close()
    if not ok:
        return
    from .cursor import game_window
    from .editor import Editor
    place = args.place or next(iter(project.places), "main")
    ed = Editor(project, place, None, game_window())
    print(f"[conjunction] {project.id}: in the game F8 = edit or play, Esc while playing = back to editing", flush=True)
    app.aboutToQuit.connect(ed.close)
    app.aboutToQuit.connect(setup.editor_mod_off)   # (out of the game when the game is closed already)
    # the overlay is no window Qt counts: closing the bug report (or any window) as the last one ended the whole
    # suite (Maxim 02.10.). It ends when the game has been gone for a while instead (a Build & Play closes it for
    # the build - minutes)
    app.setQuitOnLastWindowClosed(False)
    gone = {"since": None}

    def watch_game():
        # the game closed by the user: the app is back within seconds; while Conjunction builds or restarts it
        # (Build & Play) it waits up to 10 minutes (06.10.: the app came back only after 10 minutes)
        busy = getattr(ed, "restarting", False) or getattr(getattr(ed, "panel", None), "building", False)
        # a crash (its crash report window opened) is no closing: the game starts again with the last save and the
        # editor finds it as after Build & Play (night test 07.10.: Conjunction ended with the crashed game)
        busy = busy or time.time() - gone.get("restarted", 0) < 300
        if setup.game_running():               # (also a game the editor attached to, not only one it started)
            gone["since"] = None
        elif not busy and setup.close_crash_reports():
            print("[conjunction] the game crashed - started again with the last save", flush=True)
            gone["restarted"], gone["since"] = time.time(), None
            setup.start_game()
        elif gone["since"] is None:
            gone["since"] = time.time()
        elif time.time() - gone["since"] > (600 if busy else 8):
            if on_gone is not None:
                game_watch.stop()
                on_gone()
            else:
                app.quit()
    game_watch = QtCore.QTimer()
    game_watch.timeout.connect(watch_game)
    game_watch.start(3000)
    if keep_running:
        app._game_watch = game_watch                # (kept alive with the app's loop)
        return ed
    app.exec()


if __name__ == "__main__":
    main()
