"""Bug reports (Maxim, 01.10.): everything that helps find from afar what broke - without access to the PC.

    start_session_log()                  # at start: Conjunction's output into logs\\session.log (the last run kept)
    path = collect(ed, text, shots)      # -> bug-report_<time>.zip in Documents\\Conjunction\\bug-reports
    show(path)                           # the folder in Explorer, the file picked

A report is one file on the disk (Maxim 05.10.: "als eine datei auf der platte unter bug-reports, die man dann
schicken kann über discord oder sonst wo"). Nothing is sent. Secrets in the config (webhooks, tokens, passwords)
stay out of it.

What a report holds: the user's words and screenshots (drawn on), Conjunction's session log (this run and the last),
uncaught errors, the editor's state (project, place, mode, selection, what it waits for, open windows), the game's
state (where, the tracked quest, objectives - asked over the script link if it answers), the lines the game's
scripts sent lately and the end of the script extender's log, the project (quest, places - not its build), the last
build log, the config, which mods and DLCs are installed, Conjunction's files (a fingerprint). No facts
about the PC (Maxim 06.10.: "übergriffig").
"""
import datetime
import glob
import hashlib
import io
import json
import os
import subprocess
import sys
import threading
import traceback
import zipfile

from . import config, paths

HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.join(os.path.dirname(config.PATH), "logs")
REPORTS = paths.BUG_REPORTS
SECRET = ("webhook", "token", "secret", "password", "api_key", "apikey")
SCRIPT_LOG_LINES = 4000
_errors = []                                    # uncaught errors of this run (the last 50)


class _Tee(io.TextIOBase):
    def __init__(self, stream, f):
        self.stream, self.f = stream, f
        self.lock = threading.Lock()

    def write(self, s):
        with self.lock:
            try:
                self.f.write(s)
                self.f.flush()
            except (OSError, ValueError):
                pass
        if self.stream is not None:
            try:
                return self.stream.write(s)
            except (OSError, ValueError):
                return len(s)
        return len(s)

    def flush(self):
        if self.stream is not None:
            try:
                self.stream.flush()
            except (OSError, ValueError):
                pass


def start_session_log():
    """Conjunction's output (prints, errors) also into logs\\session.log; the run before stays as session.prev.log."""
    os.makedirs(LOGS, exist_ok=True)
    cur, prev = os.path.join(LOGS, "session.log"), os.path.join(LOGS, "session.prev.log")
    if os.path.exists(cur):
        try:
            os.replace(cur, prev)
        except OSError:
            pass
    f = open(cur, "w", encoding="utf-8", errors="replace")
    f.write(f"[conjunction] session {datetime.datetime.now().isoformat(timespec='seconds')}\n")
    sys.stdout = _Tee(sys.stdout, f)
    sys.stderr = _Tee(sys.stderr, f)
    old = sys.excepthook

    def hook(tp, value, tb):
        text = "".join(traceback.format_exception(tp, value, tb))
        _errors.append({"time": datetime.datetime.now().isoformat(timespec="seconds"), "error": text})
        del _errors[:-50]
        old(tp, value, tb)
    sys.excepthook = hook


def _suite_fingerprint():
    """A short hash per file of Conjunction and its game scripts: which code the user runs."""
    out = {}
    root = os.path.dirname(HERE)
    for p in sorted(glob.glob(os.path.join(HERE, "*.py")) + glob.glob(os.path.join(root, "mod", "**",
                                                                                     "*.ws"), recursive=True)):
        with open(p, "rb") as f:
            out[os.path.relpath(p, root)] = hashlib.sha1(f.read()).hexdigest()[:10]
    total = hashlib.sha1(json.dumps(out, sort_keys=True).encode()).hexdigest()[:12]
    return total, out


def _game(cfg):
    game = cfg.get("game", "")
    out = {"path": game}
    exe = os.path.join(game, "bin", "x64_dx12", "witcher3.exe")
    if not os.path.exists(exe):
        exe = os.path.join(game, "bin", "x64", "witcher3.exe")
    if os.path.exists(exe):
        st = os.stat(exe)
        out["exe"] = {"path": exe, "size": st.st_size,
                      "modified": datetime.datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds")}
    for sub in ("mods", "dlc"):
        d = os.path.join(game, sub)
        out[sub] = sorted(os.listdir(d)) if os.path.isdir(d) else []
    try:
        from .setup import game_running
        out["running"] = game_running()
    except Exception as e:                          # noqa: BLE001
        out["running"] = repr(e)
    return out


def _editor_state(ed):
    """What the editor is doing (read on the GUI thread - collect is called there)."""
    if ed is None:
        return {}
    s = {}
    for k in ("place", "world", "editing", "mode", "template", "placing", "selected", "seeing_through", "variants"):
        try:
            v = getattr(ed, k, None)
            s[k] = v if isinstance(v, (str, int, float, bool, list, type(None))) else repr(v)
        except Exception as e:                      # noqa: BLE001
            s[k] = repr(e)
    try:
        s["project"] = ed.project.path
        r = getattr(ed, "request", None)
        s["request"] = {k: v for k, v in (r or {}).items() if isinstance(v, (str, int, float, bool))}
        p = getattr(ed, "panel", None)
        if p is not None:
            s["panel"] = {"visible": p.isVisible(), "tab": p.tabs.tabText(p.tabs.currentIndex()),
                          "geometry": list(p.geometry().getRect()),
                          "windows": [w.windowTitle() or type(w).__name__ for w in p.open_windows()]}
            board = getattr(p, "board", None)
            if board is not None:
                s["board"] = {"dialogue_open": getattr(board, "dialogue", None) is not None,
                              "chooser_open": getattr(board, "chooser", None) is not None,
                              "drawing": bool(getattr(board, "drawing", None))}
            s["live"] = getattr(ed, "live", {})
    except Exception as e:                          # noqa: BLE001
        s["error"] = repr(e)
    return s


def _game_now(ed):
    """The game's own view (over the script link): where the player is, the tracked quest and its objectives."""
    try:
        from .gamelink import run
        return run(["cj_where()", "cj_quest()"], 1.5)
    except Exception as e:                          # noqa: BLE001 - the game may be closed, loading, crashed
        return [f"no answer: {e!r}"]


def _tail(path, n):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except OSError as e:
        return f"(not readable: {e})"


def collect(ed, text, shots=(), build_log=""):
    """-> the report's zip path. `shots`: [(name, png bytes)] - the drawn-on screenshots (and their originals)."""
    cfg = config.load()
    now = datetime.datetime.now()
    fp, files = _suite_fingerprint()
    from . import __version__
    report = {"text": text, "time": now.isoformat(timespec="seconds"), "suite": fp, "version": __version__,
              "game": _game(cfg), "editor": _editor_state(ed), "game_now": _game_now(ed), "errors": list(_errors)}
    os.makedirs(REPORTS, exist_ok=True)
    path = os.path.join(REPORTS, f"bug-report_{now:%Y-%m-%d_%H-%M-%S}.zip")
    words = _private_words()
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        def put(name, data):                        # every text of the report: anonymous (Maxim 08.10.)
            z.writestr(name, anonymize(data, words))

        def put_file(p, name):
            put(name, open(p, encoding="utf-8", errors="replace").read())
        put("report.json", json.dumps(report, indent=1, ensure_ascii=False, default=str))
        put("what_happened.txt", text or "")
        put("suite_files.json", json.dumps(files, indent=0))
        put("config.json", json.dumps(redacted(cfg), indent=1, ensure_ascii=False, default=str))
        for name in ("session.log", "session.prev.log"):
            p = os.path.join(LOGS, name)
            if os.path.exists(p):
                put_file(p, f"logs/{name}")
        from . import extender, gamelink
        try:                                        # the lines the game's scripts sent lately (the extender keeps them)
            lines = gamelink.since(0)[1]
        except Exception as e:                      # noqa: BLE001 - the game may be closed or crashed
            lines = [f"no answer: {e!r}"]
        put("logs/game_lines.txt", "\n".join(lines[-SCRIPT_LOG_LINES:]))
        put("logs/tw3se_tail.txt", _tail(extender.log_path(), SCRIPT_LOG_LINES))
        if build_log:
            put("logs/build.txt", build_log)
        proj = getattr(getattr(ed, "project", None), "path", None)
        if proj and os.path.isdir(proj):            # the quest and its places (not its build)
            for p in glob.glob(os.path.join(proj, "*.yml")) + glob.glob(os.path.join(proj, "places", "*.yml")):
                put_file(p, "project/" + os.path.relpath(p, proj).replace("\\", "/"))
            for p in glob.glob(os.path.join(proj, "build", "*.log")):
                put_file(p, "project/build/" + os.path.basename(p))
        for k, (name, png) in enumerate(shots):
            z.writestr(f"screenshots/{k + 1:02d}_{name}.png", png)
    return path


def _private_words():
    """[(what, its stand-in)] of what names the person or the PC (Maxim 08.10.: a report passes on nothing of the
    user): the Windows user and the home folder, the computer, Conjunction's profiles and keys. Longest first."""
    import getpass
    import re
    out = []
    home = os.path.expanduser("~")
    for form in {home, home.replace("\\", "/"), home.replace("\\", "\\\\")}:
        out.append((form, "<home>"))
    for name, stand in ((os.environ.get("USERNAME") or getpass.getuser(), "<user>"),
                        (os.environ.get("COMPUTERNAME", ""), "<pc>"), (os.environ.get("USERDOMAIN", ""), "<pc>")):
        if name and len(name) >= 3:
            out.append((name, stand))
    try:
        from . import identity
        for p in identity.profiles():
            out += [(x, "<profile>") for x in (p.name, p.id, p.public) if x and len(x) >= 3]
    except Exception:                               # noqa: BLE001 - no profiles readable: none to hide
        pass
    out = sorted(set(out), key=lambda w: -len(w[0]))
    return [(re.compile(re.escape(w), re.I), s) for w, s in out]


def anonymize(text, words=None):
    """The text without what names the person or the PC: their names (_private_words), Steam account ids in paths,
    e-mail addresses; a project's author and maker's mark."""
    import re
    text = re.sub(r"[\w.+-]+@[\w-]+\.[\w.-]+", "<e-mail>", text)       # (before the names: one may be in it)
    text = re.sub(r"(userdata[\\/]+)\d+", r"\1<id>", text, flags=re.I)
    text = re.sub(r"(?m)^(\s*author:\s*).+$", r"\1<author>", text)
    for pat, stand in words if words is not None else _private_words():
        text = pat.sub(stand, text)
    text = re.sub(r"(?m)^(\s*(?:key|seed|uid):\s*)[0-9a-fA-F]{8,}\s*$", r"\1<left out>", text)
    return text


def nexus_text(path, limit=4800):
    """A short report to paste into the Bugs tab of a Nexus page (it takes text only, 5000 letters): the version,
    what the user wrote, the errors and the last lines of the log - all from the saved (anonymous) report."""
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        rep = json.loads(z.read("report.json").decode("utf-8")) if "report.json" in names else {}
        log = z.read("logs/session.log").decode("utf-8", "replace") if "logs/session.log" in names else ""
        build = z.read("logs/build.txt").decode("utf-8", "replace") if "logs/build.txt" in names else ""
    game = rep.get("game") or {}
    lines = [f"Conjunction {rep.get('version', '?')}, {rep.get('time', '')[:16].replace('T', ' ')}",
             f"Game running: {game.get('running')}. Mods: {', '.join(game.get('mods') or []) or 'none'}", "",
             "What happened:", (rep.get("text") or "(nothing written)").strip(), ""]
    errors = [str(e).strip() for e in rep.get("errors") or []][-3:]
    if errors:
        lines += ["Errors:"] + [e[-700:] for e in errors] + [""]
    marks = ("error", "failed", "traceback", "exception", "crash")
    flagged = [ln for ln in log.splitlines() if any(m in ln.lower() for m in marks)][-15:]
    if flagged:
        lines += ["Log, the lines with errors:"] + flagged + [""]
    if build:
        lines += ["Build, the last lines:"] + build.strip().splitlines()[-10:] + [""]
    lines += ["Log, the last lines:"] + log.strip().splitlines()[-25:]
    out = "\n".join(lines)
    if len(out) > limit:
        out = out[:limit - 60].rstrip() + "\n(cut - the full report is a file on the reporter's PC)"
    return out


def redacted(v):
    """The config without its secrets: a value whose key names a webhook, token, secret or password -> "(left out)"."""
    if isinstance(v, dict):
        return {k: "(left out)" if any(s in str(k).lower() for s in SECRET) and val else redacted(val)
                for k, val in v.items()}
    if isinstance(v, list):
        return [redacted(x) for x in v]
    return v


def show(path):
    """The report's folder in Explorer with the file picked (a click of the user's: Explorer may come to the front)."""
    if os.name == "nt" and os.path.exists(path):
        subprocess.Popen(["explorer", "/select,", os.path.normpath(path)])
