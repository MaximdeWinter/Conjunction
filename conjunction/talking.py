"""Which looks of a person can move their mouth. The game gives a face rig (CMimicComponent, with its .w3fac) only to
some looks - the head of a talking look; background looks are one baked mesh without it (a novigrad citizen: 5 of
15). A person who speaks in the quest needs one of those, else the line plays and the mouth stays shut (seen in the
remaster, 30.09.2026). Cached in %APPDATA%\\conjunction\\talking_looks.json."""
import json
import os

from . import config

CACHE = os.path.join(os.path.dirname(config.PATH), "talking_looks.json")
_cache = None
_save = True                                    # (off in fill()'s processes: one writes the file)
SPAWN = "spawn:"                                # cache key of the looks the game spawns a template with


def _load():
    global _cache
    if _cache is None:
        try:
            _cache = json.load(open(CACHE, encoding="utf-8"))
        except (OSError, ValueError):
            _cache = {}
    return _cache


def talking_looks(template, depot=None):
    """[look] of a template whose face can talk - those the game spawns first, then the others. [] if none can.
    Reads the looks the game spawns it with too (spawn_looks)."""
    cache = _load()
    key = template.lower()
    if key in cache and SPAWN + key in cache:
        return cache[key]
    from .assets import _cr2w_parts
    from .bundles import Depot
    from .meshview import looks
    depot = depot or Depot()
    apps, used = looks(template, depot)
    faces = {}

    def face(sub):
        if sub not in faces:
            faces[sub] = depot.exists(sub) and any(e[0] == "CMimicComponent" for p in _cr2w_parts(depot.read(sub))[:3]
                                                   for e in p.exports)
        return faces[sub]
    talking = [a for a, subs in apps.items() if any(face(s) for s in subs)]
    out = [u for u in used if u in talking] + [a for a in talking if a not in used]
    cache[key] = out
    cache[SPAWN + key] = [u for u in used if u in apps] or list(apps)
    if _save:
        try:
            json.dump(cache, open(CACHE, "w", encoding="utf-8"))
        except OSError:
            pass
    return out


def _talking_many(paths):
    """[(template, its talking looks or None, the looks it spawns with)] - a process of fill()."""
    from .bundles import Depot
    global _cache, _save
    _cache, _save = {}, False                           # (each answer goes back to fill(), not into the file)
    depot = Depot()
    out = []
    for p in paths:
        try:
            out.append((p, talking_looks(p, depot), _cache.get(SPAWN + p.lower())))
        except Exception:                               # noqa: BLE001 - one broken template does not stop it
            out.append((p, None, None))
    return out


def fill(paths, workers=6, log=print):
    """Reads which of these templates can talk, those not known yet, in `workers` processes, and keeps it (the
    catalog's speech badge reads only what is known: 4000 people take about 3 minutes in one process)."""
    from concurrent.futures import ProcessPoolExecutor
    cache = _load()
    todo = sorted({p for p in paths if p.lower() not in cache or SPAWN + p.lower() not in cache})
    if not todo:
        return 0
    log(f"[talking] {len(todo)} templates: which can talk ...")
    chunks = [todo[i::workers * 4] for i in range(workers * 4)]
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for batch in pool.map(_talking_many, chunks):
            for p, looks, spawn in batch:
                if looks is not None:
                    cache[p.lower()] = looks
                    cache[SPAWN + p.lower()] = spawn or []
    tmp = CACHE + ".tmp"
    try:
        json.dump(cache, open(tmp, "w", encoding="utf-8"))
        os.replace(tmp, CACHE)
    except OSError:
        pass
    return len(todo)


def can_talk(template):
    """True (a look of it can move its mouth), False (none can), None (not read yet)."""
    talking = known_talking(template)
    return None if talking is None else bool(talking)


def known_talking(template):
    """talking_looks if already read (the cache), else None - for a card that must not wait for the game's files."""
    return _load().get(template.lower())


def spawn_looks(template):
    """The looks the game picks one of when it spawns the template (its used appearances, else all), [] if not
    read yet."""
    return _load().get(SPAWN + template.lower()) or []


def voice(template):
    """'all' (every look the game may spawn it with can move the mouth), 'some' (the game may give it one that
    cannot: placed for a speaker, the look has to be checked), 'none' (no look can), None (not read yet).
    Maxim 08.10.: a folder showed 'can talk' though some of its looks could not."""
    talking = known_talking(template)
    if talking is None:
        return None
    if not talking:
        return "none"
    spawn = spawn_looks(template)
    return "all" if all(s in talking for s in spawn) else "some"


def voices(templates):
    """voice() of several (a folder of the catalog): the same for all, else 'some'; None if one is not read yet."""
    found = {voice(t) for t in templates}
    if None in found:
        return None
    return found.pop() if len(found) == 1 else "some"


def mouth(template, look):
    """'moves' (this look's face can talk), 'shut' (another look of it could), 'none' (no look of it can: an animal,
    a monster, a background person), 'maybe' (no look set and the game may spawn one that cannot) - None while not
    read yet (known_talking)."""
    talking = known_talking(template)
    if talking is None:
        return None
    if not talking:
        return "none"
    if not look:
        return "maybe" if voice(template) == "some" else "moves"
    return "moves" if look in talking else "shut"


# --- what a body can play in a scene: the game names a gesture the same for men and women, but each skeleton has its
# own animsets and not every gesture is in each (Maxim's test3, 01.10.: a man given a woman's 'sigh' stood in a T-pose)
ANIMS = os.path.join(os.path.dirname(config.PATH), "dialogue_anims.json")
_anims = None


def _anim_cache():
    global _anims
    if _anims is None:
        try:
            _anims = json.load(open(ANIMS, encoding="utf-8"))
        except (OSError, ValueError):
            _anims = {}
        _anims.setdefault("sets", {})
        _anims.setdefault("templates", {})
    return _anims


def _animsets(template, depot, depth=0):
    """The dialogue animsets a template lists (and those of the base entities it includes)."""
    import re
    try:
        data = depot.read(template)
    except KeyError:
        return set()
    out = {p.decode() for p in re.findall(rb"[a-z0-9_\\]+\.w2anims", data) if b"dialog" in p}
    if depth < 2:
        for base in set(re.findall(rb"characters\\base_entities\\[a-z0-9_\\]+\.w2ent", data)):
            out |= _animsets(base.decode(), depot, depth + 1)
    return out


def known_anims(template):
    """dialogue_anims if already read, else None."""
    c = _anim_cache()
    sets = c["templates"].get(template.lower())
    if sets is None or any(s not in c["sets"] for s in sets):
        return None
    return {n for s in sets for n in c["sets"][s]}


def dialogue_anims(template, depot=None):
    """The scene animations a template's body can play: the names radish knows (dialogue.all_animations) found in the
    dialogue animsets the template lists - a set (empty: none, an animal or a monster). None: nothing to tell by (no
    game or no radish to look in)."""
    have = known_anims(template)
    if have is not None:
        return have
    from . import dialogue as D
    known = {n for n, _s in D.all_animations()}
    if not known:
        return None
    try:
        from .bundles import Depot
        depot = depot or Depot()
    except Exception:                                   # noqa: BLE001 - no game to look in
        return None
    import re
    c = _anim_cache()
    sets = sorted(_animsets(template.lower(), depot))
    for s in sets:
        if s not in c["sets"]:
            words = set(re.findall(rb"[a-z0-9_]{4,}", depot.read(s)))
            c["sets"][s] = sorted(n for n in known if n.encode() in words)
    c["templates"][template.lower()] = sets
    try:
        tmp = ANIMS + ".tmp"
        json.dump(c, open(tmp, "w", encoding="utf-8"))
        os.replace(tmp, ANIMS)
    except OSError:
        pass
    return {n for s in sets for n in c["sets"][s]}


def look_for_speaker(template, chosen=None, depot=None):
    """(the look a speaking person gets, a note or None): the chosen one if it can talk, else the first that can."""
    try:
        talking = talking_looks(template, depot)
    except Exception:                                   # noqa: BLE001 - no game to look in: leave it
        return chosen, None
    if not talking:
        return chosen, "no look of it can move its mouth"
    if chosen in talking:
        return chosen, None
    return talking[0], (f"look {chosen} cannot move its mouth - {talking[0]} instead" if chosen else None)
