"""What changed in a project between two history steps (Maxim 06.10.: quests stay open to change, but it shows what
was changed). Each step keeps a small picture of the project (its project.yml, its places, a fingerprint of every
other file) in <project>/.cj_history/state.json; the next step compares against it and names the changes in plain
words - "Camp: 2 objects placed, 1 moved", "The Bandit Camp: step 3 (talk) dialogue changed".

    state(project_path) -> dict          the picture now
    describe(old_state, new_state) -> [str]
    load(project_path) / save(project_path, state)
"""
import difflib
import hashlib
import json
import os

import yaml

DIR = ".cj_history"
FILE = "state.json"
SKIP_DIRS = {"build", "parked", "versions", ".git", "__pycache__", DIR}
QUIET = {"run", "uid", "mark"}          # project.yml keys that are no change of the quest (a test run's number ...)
MAX_LINES = 40


def _files(root):
    out = {}
    for r, ds, fs in os.walk(root):
        ds[:] = [d for d in ds if d not in SKIP_DIRS]
        for f in fs:
            if f.endswith(".tmp") or f == "history.json":
                continue
            p = os.path.join(r, f)
            rel = os.path.relpath(p, root).replace("\\", "/")
            with open(p, "rb") as h:
                out[rel] = hashlib.sha256(h.read()).hexdigest()[:16]
    return out


def state(project_path):
    root = os.path.abspath(project_path)
    meta, places = {}, {}
    try:
        meta = yaml.safe_load(open(os.path.join(root, "project.yml"), encoding="utf-8")) or {}
    except (OSError, ValueError):
        pass
    pdir = os.path.join(root, "places")
    for n in sorted(os.listdir(pdir)) if os.path.isdir(pdir) else ():
        if n.endswith(".yml"):
            try:
                places[n[:-4]] = yaml.safe_load(open(os.path.join(pdir, n), encoding="utf-8")) or {}
            except (OSError, ValueError):
                places[n[:-4]] = {}
    return {"meta": {k: v for k, v in meta.items() if k not in QUIET}, "places": places, "files": _files(root)}


def load(project_path):
    try:
        return json.load(open(os.path.join(project_path, DIR, FILE), encoding="utf-8"))
    except (OSError, ValueError):
        return None


def save(project_path, st):
    d = os.path.join(project_path, DIR)
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, FILE)
    with open(p + ".tmp", "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, default=str)
    os.replace(p + ".tmp", p)


def _plural(n, word):
    return f"{n} {word}" + ("" if n == 1 else "s")


def _short(text, n=40):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[:n - 3] + "..."


# --- places
def _obj_key(o):
    return (str(o.get("template", "")).lower(), tuple(round(float(v), 3) for v in (o.get("pos") or [])[:3]))


def _place(name, old, new):
    oo, no = list((old or {}).get("objects") or []), list((new or {}).get("objects") or [])
    keys_o = [_obj_key(o) for o in oo]
    keys_n = [_obj_key(o) for o in no]
    left_o, left_n = list(range(len(oo))), list(range(len(no)))
    changed = 0
    for i in list(left_o):                              # the same object at the same spot
        for j in left_n:
            if keys_o[i] == keys_n[j]:
                if oo[i] != no[j]:
                    changed += 1
                left_o.remove(i)
                left_n.remove(j)
                break
    moved = 0
    for i in list(left_o):                              # the same object somewhere else
        for j in left_n:
            if keys_o[i][0] == keys_n[j][0]:
                moved += 1
                left_o.remove(i)
                left_n.remove(j)
                break
    parts = []
    if left_n:
        parts.append(f"{_plural(len(left_n), 'object')} placed")
    if moved:
        parts.append(f"{moved} moved")
    if changed:
        parts.append(f"{changed} changed")
    if left_o:
        parts.append(f"{len(left_o)} removed")
    for k in sorted(set(old or {}) | set(new or {})):
        if k != "objects" and (old or {}).get(k) != (new or {}).get(k):
            parts.append(f"{k} changed")
    return f"{name}: " + ", ".join(parts) if parts else None


# --- quests
def _quests(meta):
    out = ([meta["quest"]] if isinstance(meta.get("quest"), dict) else []) + \
        [q for q in (meta.get("quests") or []) if isinstance(q, dict)]
    return {str(q.get("title") or f"quest {k + 1}"): q for k, q in enumerate(out)}


def _step_sig(s):
    if not isinstance(s, dict) or not s:
        return ("?", "")
    kind = next(iter(s))
    body = s[kind] if isinstance(s[kind], dict) else {}
    return (kind, str(body.get("text") or body.get("title") or ""))


def _step_label(n, s):
    kind, text = _step_sig(s)
    return f"step {n} ({kind}{': ' + _short(text) if text else ''})"


def _step_change(a, b):
    """What differs in one step: its dialogue, its text, its settings."""
    ka, kb = _step_sig(a), _step_sig(b)
    if ka[0] != kb[0]:
        return f"now {kb[0]}"
    ba = a.get(ka[0]) if isinstance(a.get(ka[0]), dict) else {}
    bb = b.get(kb[0]) if isinstance(b.get(kb[0]), dict) else {}
    what = []
    if ba.get("dialogue") != bb.get("dialogue"):
        what.append("dialogue")
    if ka[1] != kb[1]:
        what.append("text")
    rest = {k for k in set(ba) | set(bb) if k not in ("dialogue", "text") and ba.get(k) != bb.get(k)}
    if rest:
        what.append(", ".join(sorted(rest)))
    return " and ".join(what) + " changed" if what else "changed"


def _quest(title, old, new):
    out = []
    for k in ("title", "type", "description", "items"):
        if (old or {}).get(k) != (new or {}).get(k):
            out.append(f"{title}: {k} changed")
    so, sn = list((old or {}).get("steps") or []), list((new or {}).get("steps") or [])
    m = difflib.SequenceMatcher(a=[_step_sig(s) for s in so], b=[_step_sig(s) for s in sn], autojunk=False)
    for op, i1, i2, j1, j2 in m.get_opcodes():
        if op == "equal":
            for i, j in zip(range(i1, i2), range(j1, j2)):
                if so[i] != sn[j]:
                    out.append(f"{title}: {_step_label(j + 1, sn[j])} {_step_change(so[i], sn[j])}")
        elif op == "replace" and i2 - i1 == j2 - j1:
            for i, j in zip(range(i1, i2), range(j1, j2)):
                out.append(f"{title}: {_step_label(j + 1, sn[j])} {_step_change(so[i], sn[j])}")
        else:
            for i in range(i1, i2):
                out.append(f"{title}: {_step_label(i + 1, so[i])} removed")
            for j in range(j1, j2):
                out.append(f"{title}: {_step_label(j + 1, sn[j])} added")
    return out


def describe(old, new):
    """The changes from `old` to `new` (two state() pictures) in plain words; old None: nothing (the first step)."""
    if not old:
        return []
    out = []
    om, nm = old.get("meta") or {}, new.get("meta") or {}
    oq, nq = _quests(om), _quests(nm)
    for t in nq:
        if t not in oq:
            out.append(f"quest {t} added")
    for t in oq:
        if t not in nq:
            out.append(f"quest {t} removed")
        else:
            out += _quest(t, oq[t], nq[t])
    for k in sorted(set(om) | set(nm)):
        if k not in ("quest", "quests") and om.get(k) != nm.get(k):
            out.append(f"project {k} changed")
    op, np_ = old.get("places") or {}, new.get("places") or {}
    for name in sorted(set(op) | set(np_)):
        if name not in op:
            n = len((np_[name] or {}).get("objects") or [])
            out.append(f"place {name} added" + (f" ({_plural(n, 'object')})" if n else ""))
        elif name not in np_:
            out.append(f"place {name} removed")
        elif op[name] != np_[name]:
            line = _place(name, op[name], np_[name])
            if line:
                out.append(line)
    of, nf = old.get("files") or {}, new.get("files") or {}
    for rel in sorted(set(of) | set(nf)):
        if rel == "project.yml" or rel.startswith("places/"):
            continue
        if rel not in of:
            out.append(f"file {rel} added")
        elif rel not in nf:
            out.append(f"file {rel} removed")
        elif of[rel] != nf[rel]:
            out.append(f"file {rel} changed")
    if len(out) > MAX_LINES:
        out = out[:MAX_LINES] + [f"and {len(out) - MAX_LINES} more"]
    return out
