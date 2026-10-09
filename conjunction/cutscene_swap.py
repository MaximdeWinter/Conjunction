"""A game cutscene replaced by another in every game scene that plays it - the scenes stay the game's own, only the
cutscene they point at changes (the love scenes are cutscenes: cs201_sex_with_yennefer, sex_do_component ...).

A scene plays a cutscene from a CStorySceneCutsceneSection: its property `cutscene` is a handle to an import - the
cutscene's path. A cutscene (CCutsceneTemplate) names its actors (`actorsDef`: name, voiceTag, type) and the scenes
that play it (`usedInFiles` - not kept up to date, checked against the scenes' imports); its length is the length of
its animations. Replaced: where the section's handle points (an import of the new cutscene - the scene's own if it
has one), and the length the scene gives the cutscene player (`approvedDuration`), so a longer one is not cut and a
shorter one does not leave the screen standing. Written with the CR2W writer; the build puts the scenes into the
quest's mod bundle.

An own cutscene (a cooked .w2cutscene - the animation workshop makes them) plays the same way: the build puts the
file into the mod bundle under its depot path (`depot_path`) and the scenes point there.

    all_cutscenes() -> every cutscene of the game (paths, sorted)
    info(path, file=None) -> {"actors": [names of its people], "duration": seconds, "scenes": [scene paths]} (an own
        one read from its file)
    problems(old, new, file=None) -> plain words on what may not fit (people the scenes do not have)
    swapped(scene_path, changes, files=None) -> the scene's bytes with {old cutscene: new cutscene} replaced
    depot_path(file) -> where an own cutscene file goes in the depot
"""
import functools
import os
import struct

from .bundles import Depot
from .cr2w import CR2W
from .cr2w_props import decode

_depot = None
_ALL = None


def _d():
    global _depot
    if _depot is None:
        _depot = Depot()
    return _depot


def all_cutscenes():
    global _ALL
    if _ALL is None:
        _ALL = sorted(p for p in _d().where if p.endswith(".w2cutscene"))
    return _ALL


def label(path):
    """'animations\\...\\cs201_sex_with_yennefer.w2cutscene' -> 'cs201 sex with yennefer'."""
    return path.rsplit("\\", 1)[-1].rsplit(".", 1)[0].replace("_", " ")


def depot_path(file):
    """An own cutscene's depot path: from its folder 'animations' on (the workshop builds to the game's layout), else
    animations\\cutscenes\\conjunction\\<its name>."""
    parts = os.path.normpath(file).split(os.sep)
    low = [x.lower() for x in parts]
    if "animations" in low:
        return "\\".join(parts[len(low) - 1 - low[::-1].index("animations"):])
    return "animations\\cutscenes\\conjunction\\" + os.path.basename(file)


@functools.lru_cache(maxsize=64)
def info(path, file=None):
    f = CR2W(open(file, "rb").read() if file else _d().read(path))
    top = decode(f, f.exports[0][4])
    actors = [a.get("name") for a in top.get("actorsDef") or [] if a.get("type", "CAT_Actor") == "CAT_Actor"]
    duration = 0.0
    for e in f.exports:
        if e[0] == "CSkeletalAnimation":
            duration = max(duration, float(decode(f, e[4]).get("duration") or 0.0))
    # the list is not kept up to date: it names a scene the game no longer has and one that does not play it (both
    # Blood and Wine's) - the scenes that really import it
    scenes = [] if file else [p for p in top.get("usedInFiles") or [] if _d().exists(p) and
                              path.lower() in [i[0].lower() for i in CR2W(_d().read(p)).imports]]
    return {"actors": [a for a in actors if a], "duration": duration, "scenes": scenes}


def problems(old, new, file=None):
    """What may not fit when `new` plays where `old` did: people it has that `old` does not (the scene binds its
    people by name)."""
    a, b = info(old), info(new, file)
    extra = [x for x in b["actors"] if x not in a["actors"]]
    return [f"it has {', '.join(extra)} - the scene has {', '.join(a['actors']) or 'nobody'}"] if extra else []


def swapped(scene_path, changes, files=None):
    """The scene with its cutscenes replaced ({old path: new path}; `files` {new path: file} for own ones); -> (bytes,
    [the old paths it had])."""
    from .graph_edit import _idx
    f = CR2W(_d().read(scene_path))
    low = {k.lower(): v for k, v in changes.items()}
    paths = [imp[0].lower() for imp in f.imports]
    hit = []
    for e in f.exports:
        if e[0] != "CStorySceneCutsceneSection":
            continue
        # the section's handle (-n: import n-1) points at the new cutscene - an import the scene has already (the
        # brothels' scenes import all their cutscenes), or one added; the old import stays, unused
        chunk = bytes(e[4])
        at = next((off for n, _t, off, size in f.props(chunk) if n == "cutscene" and size == 4), None)
        h = struct.unpack_from("<i", chunk, at)[0] if at is not None else 0
        if h >= 0 or -h - 1 >= len(f.imports):
            continue
        old = f.imports[-h - 1][0]
        new = low.get(old.lower())
        if not new:
            continue
        if new.lower() not in paths:
            f.imports.append([new, "CCutsceneTemplate", f.imports[-h - 1][2]])
            paths.append(new.lower())
        e[4] = bytearray(chunk[:at] + struct.pack("<i", -(paths.index(new.lower()) + 1)) + chunk[at + 4:])
        if old not in hit:
            hit.append(old)
        # its cutscene player gets the new one's length
        sec = decode(f, e[4])
        length = info(new, (files or {}).get(new))["duration"]
        for kind, el in sec.get("sceneElements") or []:
            if kind == "export" and f.exports[el - 1][0] == "CStorySceneCutscenePlayer" and length:
                chunk = bytes(f.exports[el - 1][4])
                for n, _t, off, size in f.props(chunk):
                    if n == "approvedDuration" and size == 4:
                        f.exports[el - 1][4] = bytearray(chunk[:off] + struct.pack("<f", length) + chunk[off + 4:])
                        break
                else:
                    props = f.props(chunk)
                    end = props[-1][2] + props[-1][3] if props else 1
                    add = struct.pack("<HHI", _idx(f, "approvedDuration"), _idx(f, "Float"), 8) + \
                        struct.pack("<f", length)
                    f.exports[el - 1][4] = bytearray(chunk[:end] + add + chunk[end:])
    return f.save(), hit
