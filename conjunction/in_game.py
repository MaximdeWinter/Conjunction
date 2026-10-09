"""Only the open project in the game (Maxim 05.10.: "jede quest die ich baue lässt ihre sachen stehen wenn ich eine
neue baue ... cluttered nur extremst"): when a project is built into the game, the DLCs and mod bundles of Conjunction's
other projects are parked - moved beside the game's folders, never deleted - so their people and things
leave the world. A project with `always_in_game: true` stays, and so do Conjunction's own libraries (meshes,
foliage). Parking renames on the game's drive: it moves the whole folder or nothing (a file the running game holds
open: the folder stays, said so).

    suite_folders(game, projects) -> [{"folder", "where": dlc | Mods, "project": path | None}]
    park_others(project_dir, log) -> [names parked]
    park(entries, log) / parked() / restore(name, log)
    PARKED                          <game>\\_conjunction_parked\\{dlc, Mods}
"""
import os
import re
import shutil

from . import config

LIBRARIES = {"dlcconjunctionmeshes", "dlcconjunctionfoliage"}
# Conjunction's own tests that are no project (yet installed by its tools)
TESTS = {("dlc", "dlcw3sterraintest"), ("dlc", "dlcsuite_test_furniture"), ("Mods", "modconjunctionterraintest")}


def parked_root(game=None):
    return os.path.join(game or config.load()["game"], "_conjunction_parked")


def _project_id(folder):
    """A project folder's id (its base id: the id of project.yml) - None when it is no project."""
    import yaml
    meta = os.path.join(folder, "project.yml")
    if not os.path.exists(meta):
        return None
    try:
        m = yaml.safe_load(open(meta, encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError):
        return None
    return str(m.get("id") or "").lower() or None


def _projects(root, more=()):
    """{base id: project folder} of every project in the projects folder, and of the folders in `more`."""
    out = {}
    for path in [os.path.join(root, n) for n in (os.listdir(root) if os.path.isdir(root) else [])] + list(more):
        pid = _project_id(path)
        if pid:
            out.setdefault(pid, path)
    return out


def _known_elsewhere():
    """The projects Conjunction knows outside its projects folder: opened, added, its examples."""
    try:
        cfg = config.load()
        dirs = list(cfg.get("recent", [])) + list(cfg.get("projects_added", []))
    except Exception:                                   # noqa: BLE001 - no settings yet
        dirs = []
    try:
        from .project import examples
        dirs += [p for _n, p in examples()]
    except Exception:                                   # noqa: BLE001
        pass
    return dirs


def suite_folders(game=None, projects=None, also=None):
    """The folders of the game's dlc and Mods that Conjunction's projects (and its tests) put there: by their mark
    (conjunction.json), else by the id of a project Conjunction knows (`also`: one more project folder)."""
    from .project import PROJECTS
    game = game or config.load()["game"]
    ids = _projects(projects or PROJECTS, ([] if projects else _known_elsewhere()) + ([also] if also else []))
    out = []
    for where, prefix in (("dlc", "dlc"), ("Mods", "moddlc")):
        root = os.path.join(game, where)
        for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            low = d.lower()
            if low in LIBRARIES:
                continue
            if (where, low) in TESTS:
                out.append({"folder": d, "where": where, "project": None})
                continue
            marked = _marked(os.path.join(root, d))
            if marked:
                out.append({"folder": d, "where": where, "project": marked.get("project") or None})
                continue
            m = re.fullmatch(rf"{prefix}(.+?)(r\d+)?", low)
            if m and (m.group(1) in ids or low[len(prefix):] in ids):
                out.append({"folder": d, "where": where,
                            "project": ids.get(m.group(1)) or ids.get(low[len(prefix):])})
    return out


def _kept(project_dir):
    import yaml
    try:
        m = yaml.safe_load(open(os.path.join(project_dir, "project.yml"), encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError):
        return False
    return bool(m.get("always_in_game"))


def park(entries, log=print, game=None):
    """Move these folders beside the game's (<game>\\_conjunction_parked\\<dlc | Mods>) -> the names moved."""
    game = game or config.load()["game"]
    done = []
    for e in entries:
        src = os.path.join(game, e["where"], e["folder"])
        dst_root = os.path.join(parked_root(game), e["where"])
        os.makedirs(dst_root, exist_ok=True)
        dst = os.path.join(dst_root, e["folder"])
        k = 2
        while os.path.exists(dst):                      # (parked before: the older one keeps its name)
            dst = os.path.join(dst_root, f"{e['folder']}.{k}")
            k += 1
        try:
            os.rename(src, dst)
            done.append(e["folder"])
        except OSError as ex:
            log(f"[in game] {e['folder']} stays (the game holds it - close the game): {ex.strerror}")
    if done:
        log(f"[in game] parked (out of the world, in {parked_root(game)}): {', '.join(done)}")
    return done


def others_in(project_dir, game=None, projects=None):
    """Every other project's DLC and mod bundle in the game (what park_others would move) -> entries."""
    me = os.path.normcase(os.path.abspath(project_dir))
    mine = _ids_of(project_dir)

    def own(e):
        if e["project"] and os.path.normcase(os.path.abspath(e["project"])) == me:
            return True
        low = e["folder"].lower()
        prefix = "dlc" if e["where"] == "dlc" else "moddlc"
        return any(re.fullmatch(rf"{prefix}{re.escape(i)}(r\d+)?", low) for i in mine)
    return [e for e in suite_folders(game, projects) if not own(e) and not (e["project"] and _kept(e["project"]))]


def park_others(project_dir, log=print, game=None, projects=None):
    """Every other project's DLC and mod bundle out of the game (not this project's, not those always in it)."""
    me = os.path.normcase(os.path.abspath(project_dir))
    mine = _ids_of(project_dir)                         # (a copy elsewhere is this project too: by its id)

    def own(e):
        if e["project"] and os.path.normcase(os.path.abspath(e["project"])) == me:
            return True
        low = e["folder"].lower()
        prefix = "dlc" if e["where"] == "dlc" else "moddlc"
        return any(re.fullmatch(rf"{prefix}{re.escape(i)}(r\d+)?", low) for i in mine)
    others = [e for e in suite_folders(game, projects)
              if not own(e) and not (e["project"] and _kept(e["project"]))]
    return park(others, log, game)


MARK = "conjunction.json"       # in each DLC and mod bundle Build & Play installs: {"project", "base", "id"}


def mark(folder, project_dir, qid, base):
    """Conjunction's mark in an installed DLC or mod bundle: the game folder knows whose it is (any project folder)."""
    import json
    with open(os.path.join(folder, MARK), "w", encoding="utf-8") as f:
        json.dump({"project": os.path.abspath(project_dir), "base": base, "id": qid}, f)


def _marked(path):
    import json
    try:
        with open(os.path.join(path, MARK), encoding="utf-8") as f:     # (closed at once: an open file holds
            m = json.load(f)                                            # the folder in place)
    except (OSError, ValueError):
        return None
    return m if isinstance(m, dict) else None


def clear_for(project_dir, log=print, game=None, projects=None, dry=False, wait=10.0):
    """Before the game starts: in its dlc and Mods only this project's current run (and what is always in the game,
    Conjunction's libraries, quests installed by players). Its older runs go into its versions, every other
    project's DLC and mod bundle is parked. A folder the system still holds (the game just closed) is tried again
    for `wait` seconds. -> the folders that should go and are still there (dry: those that would go)"""
    import time
    from .project import Project, park_run, prune_versions
    game = game or config.load()["game"]
    project = Project(project_dir)
    base, current = project.base_id, project.id
    left = []
    t = time.time()
    while True:
        own, others = [], []
        for e in suite_folders(game, projects, project_dir):
            low = e["folder"].lower()
            prefix = "dlc" if e["where"] == "dlc" else "moddlc"
            if re.fullmatch(rf"{prefix}{re.escape(base)}(r\d+)?", low):
                if low != prefix + current:
                    own.append(e)
            elif not (e["project"] and _kept(e["project"])):
                others.append(e)
        left = [e["folder"] for e in own + others]
        if dry or not left:
            return left
        for e in own:
            # out of the game folder in one step on its own drive (whole or not at all - the versions may be on
            # another drive: a copy there that fails halfway leaves nothing half in the game)
            stage = os.path.join(parked_root(game), "runs", e["folder"])
            try:
                if os.path.exists(stage):
                    shutil.rmtree(stage)
                os.makedirs(os.path.dirname(stage), exist_ok=True)
                os.rename(os.path.join(game, e["where"], e["folder"]), stage)
            except OSError as ex:
                log(f"[in game] {e['folder']} is held: {ex.strerror or ex}")
                continue
            try:
                park_run(project.path, os.path.dirname(stage), e["folder"], "dlc" if e["where"] == "dlc" else "mod")
                log(f"[in game] older run out of the game (in the project's versions): {e['folder']}")
            except OSError as ex:
                log(f"[in game] older run out of the game ({stage}; not in the versions: {ex.strerror or ex})")
        park(others, log, game)
        if own:
            prune_versions(project.path)
        if time.time() - t > wait:
            break
        time.sleep(1.0)
    left = clear_for(project_dir, log, game, projects, dry=True)
    if left:
        log(f"[in game] still in the game folder (a program holds them): {', '.join(left)}")
    return left


def _ids_of(project_dir):
    """The ids a project's DLC is named by (its id, and without the run's r<n>)."""
    import yaml
    try:
        m = yaml.safe_load(open(os.path.join(project_dir, "project.yml"), encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError):
        return []
    pid = str(m.get("id") or "").lower()
    return [i for i in {pid, re.sub(r"r\d+$", "", pid) if m.get("run") else pid} if i]


def parked(game=None):
    """[(where, folder)] parked now."""
    root = parked_root(game)
    out = []
    for w in ("dlc", "Mods"):
        if os.path.isdir(os.path.join(root, w)):
            out += [(w, d) for d in sorted(os.listdir(os.path.join(root, w)))]
    return out


def restore(name, log=print, game=None):
    """A parked folder back into the game (its name without the '.2' of a second parking)."""
    game = game or config.load()["game"]
    for where, d in parked(game):
        if d == name:
            target = os.path.join(game, where, re.sub(r"\.\d+$", "", d))
            if os.path.exists(target):
                raise ValueError(f"{target} is there already")
            os.rename(os.path.join(parked_root(game), where, d), target)
            log(f"[in game] back: {d}")
            return target
    raise ValueError(f"nothing parked as {name}")
