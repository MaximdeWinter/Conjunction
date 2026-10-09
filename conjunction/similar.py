"""How much of a quest is the same as one of this PC's projects - by its content, not its marks (Maxim 06.10.: "so
sicher wie möglich"). Someone who knows the code can cut the history out, roll new GUIDs, round the marks away and
move every object a few millimetres; the texts, the order of the steps and where the objects stand stay. Check
origin shows: "Bandit camp: 92 % of the texts, 11 of 11 objects (within 5 cm), the steps 100 %".

    content_of_meta(meta) -> (texts, step kinds)
    compare(texts, kinds, objects, skip="") -> [Match]     this PC's projects, most alike first
"""
import difflib
import glob
import os
import re

import yaml

WORD = re.compile(r"[a-z0-9']+")
NEAR = 0.05                         # m: objects this close count as the same spot (survives a few mm of jitter)
LEAST_OBJECTS = 3


class Match:
    def __init__(self, name, path, texts, objects, steps):
        self.name, self.path = name, path
        self.texts = texts              # share of the quest's text found in the project (0..1) or None
        self.objects = objects          # (at the project's spots, looked at) or None
        self.steps = steps              # how alike the order of the steps is (0..1) or None

    def strong(self):
        return (self.texts or 0) >= 0.5 or (self.objects and self.objects[0] >= LEAST_OBJECTS and
                                             self.objects[0] >= 0.5 * self.objects[1]) or (self.steps or 0) >= 0.9

    def line(self):
        parts = []
        if self.texts is not None:
            parts.append(f"{round(self.texts * 100)} % of the texts")
        if self.objects:
            parts.append(f"{self.objects[0]} of {self.objects[1]} objects (within {round(NEAR * 100)} cm)")
        if self.steps is not None:
            parts.append(f"the steps {round(self.steps * 100)} %")
        return f"{self.name}: " + ", ".join(parts)


def _strings(x, out):
    if isinstance(x, str):
        if len(WORD.findall(x.lower())) >= 2 and "\\" not in x and "/" not in x:
            out.append(x)
    elif isinstance(x, dict):
        for k, v in x.items():
            if k not in ("template", "npc", "id", "world", "tags", "appearance"):
                _strings(v, out)
    elif isinstance(x, list):
        for v in x:
            _strings(v, out)
    return out


def content_of_meta(meta):
    """(texts, step kinds) of a project.yml: every line, title, objective; the kind of each step in order."""
    texts = _strings({k: v for k, v in (meta or {}).items() if k not in ("id", "uid", "mark", "run")}, [])
    kinds = []
    for q in ([meta.get("quest")] if isinstance((meta or {}).get("quest"), dict) else []) + \
            [q for q in ((meta or {}).get("quests") or []) if isinstance(q, dict)]:
        for s in q.get("steps") or []:
            if isinstance(s, dict) and s:
                kinds.append(next(iter(s)))
    return texts, kinds


def _shingles(texts, n=3):
    out = set()
    for t in texts:
        w = WORD.findall(str(t).lower())
        if len(w) < n:
            if w:
                out.add(tuple(w))
            continue
        out.update(tuple(w[i:i + n]) for i in range(len(w) - n + 1))
    return out


def _objects_of(root):
    out = []
    for f in glob.glob(os.path.join(root, "places", "*.yml")):
        try:
            out += [o["pos"][:3] for o in (yaml.safe_load(open(f, encoding="utf-8")) or {}).get("objects", [])
                    if len(o.get("pos") or []) >= 3]
        except Exception:                               # noqa: BLE001
            continue
    return out


def _near_count(pts, own):
    cells = {}
    for q in own:
        cells.setdefault(tuple(int(v // NEAR) for v in q), []).append(q)
    n = 0
    for p in pts:
        c = [int(v // NEAR) for v in p]
        hit = False
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for q in cells.get((c[0] + dx, c[1] + dy, c[2] + dz), ()):
                        if sum((a - b) ** 2 for a, b in zip(p, q)) <= NEAR ** 2:
                            hit = True
                            break
                    if hit:
                        break
                if hit:
                    break
        n += hit
    return n


def compare(texts, kinds, objects, skip=""):
    """This PC's projects that the quest (its texts, step kinds, placed objects [{pos}]) is alike, most alike first."""
    from . import paths
    sh = _shingles(texts)
    pts = [o["pos"][:3] for o in objects or [] if len(o.get("pos") or []) >= 3]
    out = []
    for proj in glob.glob(os.path.join(paths.PROJECTS, "*", "project.yml")):
        root = os.path.dirname(proj)
        if skip and os.path.normcase(os.path.abspath(root)) == os.path.normcase(os.path.abspath(skip)):
            continue
        try:
            meta = yaml.safe_load(open(proj, encoding="utf-8")) or {}
        except Exception:                               # noqa: BLE001
            continue
        own_texts, own_kinds = content_of_meta(meta)
        t = None
        if sh:
            own = _shingles(own_texts)
            t = len(sh & own) / len(sh) if own else 0.0
        o = None
        if len(pts) >= LEAST_OBJECTS:
            own_pts = _objects_of(root)
            o = (_near_count(pts, own_pts), len(pts)) if own_pts else (0, len(pts))
        s = difflib.SequenceMatcher(a=kinds, b=own_kinds, autojunk=False).ratio() if kinds and own_kinds else None
        m = Match(meta.get("name") or os.path.basename(root), root, t, o, s)
        if m.strong():
            out.append(m)
    return sorted(out, key=lambda m: -max(m.texts or 0, (m.objects[0] / m.objects[1]) if m.objects else 0,
                                          m.steps or 0))
