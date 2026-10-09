"""The quest library (Maxim, 01.10.): quests to play are .w3q files in one folder Conjunction opens; at every start
(and on Refresh) Conjunction installs what is new, updates what changed and takes out what was removed.

    QUESTS = Documents\\Conjunction\\quests          drop .w3q files here
    state = sync(log)                            -> [entry] (each: file, manifest, status, problems)

Status: "installed" (in the game), "missing" (something it needs is not there: the runtime is too old, an
expansion the game lacks, a content pack - each said in `problems`, with the octagon in the library window),
"clash" (another quest uses its id or its range of text ids), "broken" (not a quest file). Installed quests are
remembered in library.json (which DLC / mod folder came from which file) so a removed file takes them out again -
only folders the library itself put there.
"""
import json
import os
import shutil
import zipfile

import yaml

from . import config
from . import paths
from .packaging import RUNTIME_VERSION, read_manifest

QUESTS = paths.QUESTS
STATE = os.path.join(os.path.dirname(config.PATH), "library.json")
EXPANSION_DIRS = {"Hearts of Stone": "ep1", "Blood and Wine": "bob"}


def _state():
    try:
        return json.load(open(STATE, encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _save(st):
    json.dump(st, open(STATE, "w", encoding="utf-8"), indent=1)


def _ver(v):
    """'1.10' -> (1, 10): versions compared as numbers."""
    return tuple(int(x) if x.isdigit() else 0 for x in str(v).split("."))


def problems(m, game, others, known_ids=None):
    """What keeps a quest from playing (empty: nothing). `known_ids`: the quests this game has (for one that starts
    after another)."""
    out = []
    if int(m.get("runtime", 1)) > RUNTIME_VERSION:
        out.append(f"needs Conjunction Runtime {m['runtime']} or newer")
    # (no check of the expansions: the remaster brings both to every player - Maxim 08.10.)
    from . import content
    for need in content.missing_packs(m, game):
        out.append(pack_problem(need))
    for other in others:
        if other.get("id") == m.get("id"):
            out.append(f"the same id as {other.get('title')} - only one of them can be installed")
        elif _overlap(_strings(other), _strings(m)):
            out.append(f"clashes with {other.get('title')} (the same text ids)")
        else:
            both = sorted(set(other.get("replaces") or []) & set(m.get("replaces") or []))
            if both:
                out.append(f"clashes with {other.get('title')} (both change the game's {both[0]})")
    if known_ids is not None and m.get("after") and str(m["after"]).lower() not in known_ids:
        out.append(f"starts after the quest {m['after']}, which is not installed")
    return out


def _strings(m):
    """[first, last] text id of a manifest (older ones: radish's space)."""
    if m.get("strings"):
        return [int(x) for x in m["strings"]]
    if m.get("strings_idspace") is not None:
        lo = 2110000000 + int(m["strings_idspace"]) * 1000
        return [lo, lo + 999]
    return None


def _overlap(a, b):
    return bool(a and b) and a[0] <= b[1] and b[0] <= a[1]


def pack_problem(need):
    """'needs Medieval Furniture 1.2 (14 things: oak chair, ...)' - one line of what a missing mod is and gives."""
    name = need.get("name") or need.get("id")
    ver = f" {need['version']}" if need.get("version") else ""
    used = [u.get("name") or u.get("ref") for u in need.get("used") or []]
    things = f" ({len(used)} {'thing' if len(used) == 1 else 'things'}: {', '.join(used[:3])}" + \
        (", ..." if len(used) > 3 else "") + ")" if used else ""
    if str(need.get("why", "")).startswith("old"):
        return f"needs {name}{ver} or newer (installed: {need['why'][5:]}){things}"
    return f"needs the mod {name}{ver}{things}"


def _install(path, m, game):
    dlc = os.path.join(game, "dlc", f"dlc{m['id']}")
    mod = os.path.join(game, "Mods", f"moddlc{m['id']}")
    for d in (dlc, mod):
        if os.path.isdir(d):
            shutil.rmtree(d)
    own_dlc, own_mod = f"dlc{m['id']}".lower(), f"moddlc{m['id']}".lower()
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            if name.endswith("/"):
                continue
            top, _, rest = name.partition("/")
            first, _, inner = rest.partition("/")
            if top == "dlc" and first.lower() == own_dlc:       # the game's layout (1.0)
                if inner.startswith("conjunction_source/"):
                    continue                        # (the project: for its readers, not for the game)
                target, rest = os.path.join(dlc, inner), inner
            elif top == "Mods" and first.lower() == own_mod:
                target, rest = os.path.join(mod, inner), inner
            elif top == "dlc":                      # older files: dlc/<content>, mod/<content>
                target = os.path.join(dlc, rest)
            elif top == "mod":
                target = os.path.join(mod, rest)
            else:
                continue
            if ".." in rest.replace("\\", "/").split("/"):
                continue                            # nothing outside its own folders
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(name) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
    return [dlc] + ([mod] if os.path.isdir(mod) else [])


def _uninstall(folders):
    game = config.load().get("game", "")
    for d in folders:
        # only the library's own folders inside the game
        if d and os.path.normcase(d).startswith(os.path.normcase(game)) and os.path.isdir(d):
            shutil.rmtree(d, ignore_errors=True)


def sync(log=print):
    """Bring the game in line with the quests folder -> [entry]."""
    os.makedirs(QUESTS, exist_ok=True)
    game = config.load().get("game", "")
    files = sorted(f for f in os.listdir(QUESTS) if f.lower().endswith(".w3q"))
    if not game or not os.path.isdir(os.path.join(game, "content")):
        # no game folder (yet): nothing is installed anywhere - each quest says why
        log("[library] The game's folder is not set")
        return [{"file": f, "manifest": {}, "status": "missing", "missing_packs": [],
                 "problems": ["the game's folder is not set (Conjunction's setup asks for it)"]} for f in files]
    st = _state()
    entries, seen = [], set()
    manifests = {}
    for f in files:
        try:
            manifests[f] = read_manifest(os.path.join(QUESTS, f))
        except (zipfile.BadZipFile, KeyError, yaml.YAMLError, OSError) as e:
            entries.append({"file": f, "manifest": {}, "status": "broken", "problems": [f"not a quest file: {e}"]})
    hand = by_hand(game, st, log)                   # (quests a mod manager put into the game)
    if manifests or hand:
        from .setup import install_runtime
        try:
            install_runtime()                       # the scripts every quest calls
        except OSError as e:
            log(f"[library] runtime not installed: {e}")
    known_ids = {str(m.get("id", "")).lower() for m in manifests.values()}
    known_ids |= {str(e["manifest"].get("id", "")).lower() for e in hand}
    for f, m in manifests.items():
        path = os.path.join(QUESTS, f)
        others = [o for g, o in manifests.items() if g != f and g < f]     # (the first one keeps its id)
        probs = problems(m, game, others, known_ids)
        from . import content
        entry = {"file": f, "manifest": m, "status": "installed", "problems": probs,
                 "missing_packs": content.missing_packs(m, game)}
        stamp = [os.path.getsize(path), os.path.getmtime(path)]
        known = st.get(f)
        if probs:
            entry["status"] = "clash" if any("same" in p or "clashes" in p for p in probs) else "missing"
            if known:
                _uninstall(known.get("folders", []))
                st.pop(f, None)
        elif not known or known.get("stamp") != stamp:
            folders = _install(path, m, game)
            st[f] = {"stamp": stamp, "folders": folders, "id": m.get("id")}
            log(f"[library] Installed {m.get('title')} ({f})")
        seen.add(f)
        entries.append(entry)
    for f in [f for f in st if f not in seen]:      # removed from the folder: out of the game too
        _uninstall(st[f].get("folders", []))
        log(f"[library] removed {f}")
        st.pop(f)
    _save(st)
    return entries + by_hand(game, st, log)


def by_hand(game, st=None, log=print):
    """Quests made with Conjunction that came into the game another way (by hand, a mod manager): their DLC carries
    the manifest (conjunction_quest.yml) - checked the same way, but left where they are."""
    from . import content
    st = _state() if st is None else st
    ours = {os.path.normcase(d) for e in st.values() for d in e.get("folders", [])}
    out = []
    root = os.path.join(game, "dlc")
    if not os.path.isdir(root):
        return out
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        marker = os.path.join(path, content.QUEST_MARKER)
        if os.path.normcase(path) in ours or not os.path.isfile(marker):
            continue
        try:
            m = yaml.safe_load(open(marker, encoding="utf-8")) or {}
        except (OSError, yaml.YAMLError) as e:
            log(f"[library] {marker}: {e}")
            continue
        probs = problems(m, game, [])
        out.append({"file": f"dlc\\{name}", "manifest": m, "status": "missing" if probs else "installed",
                    "problems": probs, "missing_packs": content.missing_packs(m, game), "by_hand": True})
    return out
