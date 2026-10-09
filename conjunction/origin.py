"""Check origin: who made something and whether a profile's mark is in it (provenance.py, marks.py).

    r = check(path)        a .w3q, a project folder, a built or installed quest (its DLC folder or a .bundle)
    r.steps, r.history     the signed history found with it, and its check (provenance.Check)
    r.marks                [(profile name, what, matches, looked at, verdict)] for each own profile
    r.same_as              [(own project, objects at its spots to 2 mm, objects)] - holds when marks were rounded
    r.similar              [similar.Match] own projects alike in content (texts, steps, layout to 5 cm) - holds
                           when everything else was removed
    r.maker                the project's mark: (public key, seed is that key's signature)

A history can be cut out of a copy; the marks stay in its GUIDs and placed objects. Only the owner of a key can
look for that key's marks (the seed needs the key) - so Check origin looks with the profiles on this PC.
"""
import io
import os
import zipfile

import yaml

from . import identity, marks, provenance


_DLC_SEEN = []                      # the DLC folders the bundles read last named (dlc/<dlc>/...)


class Result:
    def __init__(self, path):
        self.path = path
        self.kind = ""
        self.steps = []
        self.history = None
        self.marks = []
        self.maker = None
        self.qid = ""
        self.notes = []
        self.same_as = []               # [(own project, objects at its spots, objects looked at)]
        self.similar = []               # [similar.Match]: own projects alike in texts, steps, layout
        self.timestamp = None           # "matches" / "does not match the history" / None (none with it)


def _bundle_files(data):
    """{path below the DLC folder: bytes} of a .bundle's bytes."""
    import tempfile
    from . import bundles
    with tempfile.NamedTemporaryFile(suffix=".bundle", delete=False) as t:
        t.write(data)
        tmp = t.name
    try:
        out = {}
        for e in bundles.entries(tmp):
            rel = e[0].replace("\\", "/")
            if rel.lower().startswith("dlc/") and rel.count("/") >= 2:
                _dlc, folder, rest = rel.split("/", 2)
                _DLC_SEEN.append(folder.lower())
                rel = rest
            out[rel] = bundles.read(tmp, e)
        return out
    finally:
        os.remove(tmp)


def _from_files(r, files):
    hist = next((v for k, v in files.items() if k.lower().endswith("conjunction/" + provenance.FILE)), None)
    if hist and not r.steps:
        r.steps = provenance.from_blob(hist)
    return files


def _objects_of_layers(files):
    """Placed objects as the built layers keep them: [{pos, rot}] of every entity with a transform in the .w2l files
    (the game's float32 - the marks survive it)."""
    from .cr2w_tree import Transform, Tree
    out = []
    for rel, data in files.items():
        if not rel.lower().endswith(".w2l"):
            continue
        try:
            t = Tree(data)
        except Exception:                               # noqa: BLE001 - a layer this reading does not know
            continue
        for o in t.objects:
            tr = o.get("transform")
            if isinstance(tr, Transform) and tr.position:
                out.append({"pos": list(tr.position), "rot": list(tr.rotation or (0.0, 0.0, 0.0))})
    return out


def _objects_of_places(places):
    out = []
    for place in places:
        out += [o for o in (place or {}).get("objects", []) if isinstance(o, dict)]
    return out


def check(path):
    r = Result(path)
    _DLC_SEEN.clear()
    files, objects, meta, strings = {}, [], None, []
    low = path.lower()
    if low.endswith(".w3q"):
        r.kind = "quest file (.w3q)"
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            top = next((n.split("/")[0] + "/" + n.split("/")[1] for n in names if n.startswith("dlc/")
                        and n.count("/") >= 2), "")
            r.qid = top.split("/")[-1][3:] if top else ""
            for n in names:
                if n.endswith("/" + provenance.FILE) and "conjunction_source/" not in n:
                    r.steps = provenance.from_blob(z.read(n))
                    ots = n[:-len(provenance.FILE)] + "history.ots"
                    if ots in names:                    # a public timestamp of exactly this history (timestamp.py)
                        import hashlib
                        from . import timestamp
                        r.timestamp = "matches" if timestamp.digest_of(z.read(ots)) == \
                            hashlib.sha256(z.read(n)).digest() else "does not match the history"
                if n.lower().endswith(".bundle"):
                    files.update(_bundle_files(z.read(n)))
                if n.lower().endswith(".w3strings") and "conjunction_source/" not in n:
                    strings.append(z.read(n))
                if "conjunction_source/" in n:
                    rel = n.split("conjunction_source/", 1)[1]
                    if rel == "project.yml":
                        meta = yaml.safe_load(z.read(n))
                    elif rel.startswith("places/") and rel.endswith(".yml"):
                        objects += _objects_of_places([yaml.safe_load(io.BytesIO(z.read(n)))])
    elif os.path.isfile(os.path.join(path, "project.yml")):
        r.kind = "project"
        meta = yaml.safe_load(open(os.path.join(path, "project.yml"), encoding="utf-8"))
        r.steps = provenance.read(path)
        r.history = provenance.check(r.steps, provenance.content_hash(path))
        import glob
        objects = _objects_of_places([yaml.safe_load(open(f, encoding="utf-8"))
                                      for f in glob.glob(os.path.join(path, "places", "*.yml"))])
        built = os.path.join(path, "build", "packed")
        for root, _d, fs in os.walk(built):
            for f in fs:
                if f.endswith(".bundle"):
                    files.update(_bundle_files(open(os.path.join(root, f), "rb").read()))
    else:
        r.kind = "built quest"
        bundles_found = []
        if os.path.isfile(path) and low.endswith(".bundle"):
            bundles_found = [path]
        elif os.path.isdir(path):
            for root, _d, fs in os.walk(path):
                bundles_found += [os.path.join(root, f) for f in fs if f.endswith(".bundle")]
                strings += [open(os.path.join(root, f), "rb").read() for f in fs if f.endswith(".w3strings")][:1]
        for b in bundles_found:
            files.update(_bundle_files(open(b, "rb").read()))
            if not r.qid:
                parts = os.path.normpath(b).split(os.sep)
                d = next((x for x in reversed(parts) if x.lower().startswith("dlc") and len(x) > 3), "")
                r.qid = d[3:]
    _from_files(r, files)
    if not objects and files:                           # no project with it: the objects of its built layers
        objects = _objects_of_layers(files)
    if not r.qid and _DLC_SEEN:                         # the quest's id from its bundle's paths (dlc/dlc<id>/...)
        d = _DLC_SEEN[-1]
        r.qid = d[3:] if d.startswith("dlc") else d
    if r.history is None:
        r.history = provenance.check(r.steps) if r.steps else None
    if meta and meta.get("mark"):
        r.maker = (meta["mark"].get("key", ""), marks.seed_is_theirs(meta))
    for p in identity.profiles():
        seeds = []
        if meta and meta.get("uid"):
            seeds.append(p.project_seed(meta["uid"]))
        uid = _uid_from_steps(r.steps)
        if uid and (not meta or uid != meta.get("uid")):
            seeds.append(p.project_seed(uid))
        seeds += [p.project_seed(u) for u in _own_uids()]
        best = None
        for sd in dict.fromkeys(seeds):
            gm, gt = marks.guid_score(files, r.qid, sd) if files and r.qid else (0, 0)
            om, ot = marks.objects_marked(objects, sd) if objects else (0, 0)
            score = (gm, om)
            if best is None or score > best[0]:
                best = (score, gm, gt, om, ot)
        if best is None:
            continue
        _s, gm, gt, om, ot = best
        if gt:
            r.marks.append((p.name, "GUIDs", gm, gt, "yes" if gm >= 3 else ("likely" if gm else "no")))
        if ot:
            r.marks.append((p.name, "placed objects", om, ot, marks.objects_verdict(om, ot)))
    r.same_as = same_spots(objects, skip=os.path.abspath(path))
    try:                                                # the content itself: texts, steps, layout
        from . import similar
        texts, kinds = similar.content_of_meta(meta) if meta else ([], [])
        if not texts and strings:
            from . import w3strings
            texts = list(w3strings.read(strings[0])[2].values())
        r.similar = similar.compare(texts, kinds, objects, skip=os.path.abspath(path))
    except Exception as ex:                             # noqa: BLE001 - the rest of the check stands
        r.notes.append(f"Content not compared ({ex})")
    if not files and not objects:
        r.notes.append("Nothing built found to look for marks in")
    return r


def same_spots(objects, skip="", tol=0.002, least=3):
    """This PC's projects with objects at the same spots (to 2 mm): placed by hand, no two makers hit the same
    millimetres - it holds when the marks were rounded away. -> [(project name, matches, objects looked at)]"""
    import glob
    from . import paths
    pts = [o["pos"][:3] for o in objects if len(o.get("pos") or []) >= 3]
    if len(pts) < least:
        return []
    out = []
    for proj in glob.glob(os.path.join(paths.PROJECTS, "*", "project.yml")):
        root = os.path.dirname(proj)
        if os.path.normcase(os.path.abspath(root)) == os.path.normcase(skip):
            continue
        own = []
        for f in glob.glob(os.path.join(root, "places", "*.yml")):
            try:
                own += [o["pos"][:3] for o in (yaml.safe_load(open(f, encoding="utf-8")) or {}).get("objects", [])
                        if len(o.get("pos") or []) >= 3]
            except Exception:                           # noqa: BLE001
                continue
        if not own:
            continue
        cells = {}
        for q in own:
            cells.setdefault(tuple(round(v, 1) for v in q), []).append(q)

        def near(p):
            k = [round(v, 1) for v in p]
            for dx in (-0.1, 0, 0.1):
                for dy in (-0.1, 0, 0.1):
                    for dz in (-0.1, 0, 0.1):
                        for q in cells.get((round(k[0] + dx, 1), round(k[1] + dy, 1), round(k[2] + dz, 1)), ()):
                            if all(abs(a - b) <= tol for a, b in zip(p, q)):
                                return True
            return False
        m = sum(near(p) for p in pts)
        if m >= least:
            try:
                name = (yaml.safe_load(open(proj, encoding="utf-8")) or {}).get("name") or os.path.basename(root)
            except Exception:                           # noqa: BLE001
                name = os.path.basename(root)
            out.append((name, m, len(pts)))
    return sorted(out, key=lambda x: -x[1])


def _uid_from_steps(steps):
    for s in steps or []:
        if s.get("uid"):
            return s["uid"]
    return None


def _own_uids():
    """The uids of this PC's projects (a stolen copy of one of them carries their GUIDs)."""
    from . import paths
    out = []
    root = paths.PROJECTS
    for n in os.listdir(root) if os.path.isdir(root) else ():
        p = os.path.join(root, n, "project.yml")
        if os.path.isfile(p):
            try:
                u = (yaml.safe_load(open(p, encoding="utf-8")) or {}).get("uid")
            except Exception:                           # noqa: BLE001
                u = None
            if u:
                out.append(u)
    return out
