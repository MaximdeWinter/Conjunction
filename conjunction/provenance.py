"""The history of what is made with Conjunction (Maxim 06.10.): every step - made, edited, built, exported - with
who did it (the profile's display name), the tools and when, signed by that profile's key and chained to the step
before. Quests stay open to change (Maxim 06.10.): each step names what changed since the one before (changes.py).
What cannot be done unseen is rewriting the history: a step changed, put in or cut out is found; the content of the
last step tells whether the thing changed after it.

Kept in the project (history.json) and carried along: in the built mod's bundle (conjunction\\history.json beside
the quest's files), in the .w3q and in its manifest.

    note(project_path, "edit")                 a step when the project changed since the last one
    note(project_path, "build", force=True)    always a step
    read(project_path) -> [step]
    check(steps, content=None) -> Check         .ok, .problem, .steps (each with .name, .label, .tools, .at)
    content_hash(project_path)
"""
import datetime
import hashlib
import json
import os

FILE = "history.json"
SKIP_DIRS = {"build", "parked", "versions", ".git", "__pycache__", ".cj_history"}
LABELS = {"create": "Made", "edit": "Edited", "build": "Built", "export": "Exported", "import": "Taken in",
          "finish": "Finished"}


def content_hash(project_path):
    """sha256 over the project's own files (paths and bytes, sorted) - not its build, not the history itself."""
    h = hashlib.sha256()
    root = os.path.abspath(project_path)
    files = []
    for r, ds, fs in os.walk(root):
        ds[:] = [d for d in ds if d not in SKIP_DIRS]
        for f in fs:
            if f == FILE or f.endswith(".tmp"):
                continue
            files.append(os.path.relpath(os.path.join(r, f), root).replace("\\", "/"))
    for rel in sorted(files, key=str.lower):
        h.update(rel.lower().encode("utf-8") + b"\0")
        if rel.lower() == "project.yml":                # without what is no change of the quest (a test run's number)
            import yaml
            from .changes import QUIET
            try:
                meta = yaml.safe_load(open(os.path.join(root, rel), encoding="utf-8")) or {}
                h.update(hashlib.sha256(json.dumps({k: v for k, v in meta.items() if k not in QUIET},
                                                   sort_keys=True, default=str).encode("utf-8")).digest())
                continue
            except (OSError, ValueError):
                pass
        with open(os.path.join(root, rel), "rb") as f:
            h.update(hashlib.sha256(f.read()).digest())
    return h.hexdigest()


def _canonical(body):
    return json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def tools():
    """What made it: Conjunction and its version, the plug-ins switched on (name and version)."""
    from . import __version__
    out = [f"Conjunction {__version__}"]
    try:
        from . import plugins
        for m, st in plugins.get().listing():
            if st == "loaded":
                out.append(f"{m.get('name') or m.get('id')} {m.get('version') or ''}".strip())
    except Exception:                                   # noqa: BLE001 - the history does not need the plug-ins
        pass
    return out


def make_step(profile, step, content, prev, tools_used=None, extra=None):
    body = {"v": 1, "step": step, "label": LABELS.get(step, step), "name": profile.name, "key": profile.public,
            "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "tools": list(tools_used if tools_used is not None else tools()), "content": content, "prev": prev}
    body.update(extra or {})
    return dict(body, sig=profile.sign(_canonical(body)).hex())


def read(project_path):
    p = os.path.join(project_path, FILE)
    if not os.path.isfile(p):
        return []
    try:
        return json.load(open(p, encoding="utf-8")).get("steps") or []
    except (ValueError, OSError):
        return []


def write(project_path, steps):
    p = os.path.join(project_path, FILE)
    with open(p + ".tmp", "w", encoding="utf-8") as f:
        json.dump({"history": "conjunction/1", "steps": steps}, f, ensure_ascii=False, indent=1)
    os.replace(p + ".tmp", p)


def note(project_path, step, force=False, tools_used=None, extra=None, profile=None):
    """Add a step by the active profile; an 'edit' only when the project changed since the last step. -> the step
    or None. Without a profile (none made yet) nothing is noted."""
    from . import identity
    profile = profile or identity.active()
    if profile is None or not os.path.isdir(project_path):
        return None
    steps = read(project_path)
    content = content_hash(project_path)
    if not force and steps and steps[-1].get("content") == content:
        return None
    if not steps and step == "edit":
        step = "create"
    if not steps:                                       # the first step names the project (its uid, marks.py)
        try:
            import yaml
            uid = (yaml.safe_load(open(os.path.join(project_path, "project.yml"), encoding="utf-8")) or {}).get("uid")
            if uid:
                extra = dict(extra or {}, uid=uid)
        except (OSError, ValueError):
            pass
    from . import changes
    now = changes.state(project_path)
    said = changes.describe(changes.load(project_path) if steps else None, now)
    if said:                                            # what changed since the step before, in plain words
        extra = dict(extra or {}, changes=said)
    s = make_step(profile, step, content, steps[-1]["sig"] if steps else "", tools_used, extra)
    steps.append(s)
    write(project_path, steps)
    changes.save(project_path, now)
    return s


def note_safely(project_path, step, **kw):
    """note(), never in the way of the work it notes (a failure is printed)."""
    try:
        return note(project_path, step, **kw)
    except Exception as ex:                             # noqa: BLE001
        print(f"[history] {step}: {ex}")
        return None


class Check:
    def __init__(self, ok, problem, steps, changed_after=False):
        self.ok, self.problem, self.steps, self.changed_after = ok, problem, steps, changed_after

    def __repr__(self):
        return f"Check(ok={self.ok}, problem={self.problem!r}, steps={len(self.steps)})"


def check(steps, content=None):
    """Every signature and the chain; with `content`, whether the thing still is what the last step signed."""
    from . import identity
    prev = ""
    for i, st in enumerate(steps):
        body = {k: v for k, v in st.items() if k != "sig"}
        if body.get("prev", "") != prev:
            return Check(False, f"step {i + 1} ({st.get('label', '?')}) does not follow the one before: a step was "
                                "cut out, put in or moved", steps)
        try:
            ok = identity.verify(st["key"], _canonical(body), bytes.fromhex(st["sig"]))
        except (KeyError, ValueError):
            ok = False
        if not ok:
            return Check(False, f"step {i + 1} ({st.get('label', '?')}) was changed after it was signed", steps)
        prev = st["sig"]
    changed = bool(content and steps and steps[-1].get("content") != content)
    return Check(True, None, steps, changed)


def blob(project_path):
    """The history as the bytes that travel with the built mod and the .w3q."""
    return json.dumps({"history": "conjunction/1", "steps": read(project_path)}, ensure_ascii=False,
                      indent=1).encode("utf-8")


def from_blob(data):
    try:
        return json.loads(data.decode("utf-8")).get("steps") or []
    except (ValueError, UnicodeDecodeError, AttributeError):
        return []
