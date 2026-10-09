"""Swapping a scene of the game (a talk, a cutscene - one day its love scenes): the new scene has to fit where the old
one was called - the same inputs (the quest graph starts it at one of them, with the actors it names), the same
outputs (the graph goes on from them), the same actors (found in the world by their voicetag).

    outline(depot, path) -> {"inputs": [{"name", "voicetags"}], "outputs": [names], "actors": [{"voicetag",
                              "template", ...}], "sections": {kind: n}, "lines": n, "cutscenes": [...], "videos": [...]}
    skeleton(outline, player="geralt") -> a radish scene definition with those inputs, outputs and actors: a line
                              per input to write over, each output an exit section

    python -m conjunction.scene_swap <depot path of a .w2scene> [--skeleton out.yml]

Built as a mod under the game's path, the swapped scene replaces the game's one - old saves that are inside that
quest may not fit it any more (a disclaimer for whoever publishes such a mod).
"""
import argparse
import collections
import re
import sys

import yaml

from .cr2w_props import decode

DEFAULT_IN, DEFAULT_OUT = "Input", "Output"


def outline(depot, path):
    from .assets import _cr2w_parts
    f = _cr2w_parts(depot.read(path))[0]
    ins, outs, actors, kinds, lines, cuts, videos = [], [], [], collections.Counter(), 0, [], []
    for cls, _fl, _p, _t, chunk in f.exports:
        if cls == "CStorySceneInput":
            d = decode(f, chunk)
            ins.append({"name": d.get("inputName") or DEFAULT_IN,
                        "voicetags": [m.get("voicetag") for m in d.get("voicetagMappings") or [] if m.get("voicetag")]})
        elif cls == "CStorySceneOutput":
            outs.append(decode(f, chunk).get("name") or DEFAULT_OUT)
        elif cls == "CStorySceneActor":
            d = decode(f, chunk)
            t = d.get("entityTemplate")
            actors.append({"voicetag": d.get("id"), "template": t[1] if isinstance(t, tuple) else None,
                           "search_by_voicetag": not d.get("dontSearchByVoicetag"), "spawn": bool(d.get("forceSpawn"))})
        elif cls.endswith("Section"):
            kinds[cls.replace("CStoryScene", "")] += 1
        elif cls == "CStorySceneLine":
            lines += 1
        elif cls == "CStorySceneCutscenePlayer":
            c = decode(f, chunk).get("cutscene")
            if isinstance(c, tuple):
                cuts.append(c[1])
        elif cls == "CStorySceneVideoElement":
            v = decode(f, chunk).get("videoFileName")
            if v:
                videos.append(v)
    return {"path": path, "inputs": ins, "outputs": list(dict.fromkeys(outs)), "actors": actors,
            "sections": dict(kinds), "lines": lines, "cutscenes": cuts, "videos": videos}


def _key(voicetag):
    """The actor's name in the radish scene: its voicetag in small letters - radish makes the id from it in capitals,
    and the game finds the actor by that id (spaces kept: 'ETERNAL FIRE PRIEST NICE')."""
    return " ".join(str(voicetag).lower().split()) or "actor"


def _section(name):
    return re.sub(r"[^a-z0-9]+", "_", str(name).lower()).strip("_")


def skeleton(o, player="geralt"):
    """A radish scene with the game scene's sockets and actors: write the lines over, wire the sections up."""
    actors = {}
    repo = {}
    for a in o["actors"]:
        k = _key(a["voicetag"])
        if a["voicetag"] == "GERALT":           # the player (the actor's name is its voicetag: GERALT)
            from .dialogue import PLAYERS
            repo[k] = {"template": PLAYERS["geralt"]["template"]}
            actors[k] = {"repo": k}
            continue
        repo[k] = {"template": a["template"] or STAND_IN}
        actors[k] = {"repo": k, "by_voicetag": bool(a["search_by_voicetag"])}
    speakers = [k for k in actors if k != "geralt"] or ["geralt"]
    script = {"player": player, "actors": list(actors)}
    for n, i in enumerate(o["inputs"]):
        name = "section_start" if i["name"] == DEFAULT_IN else f"section_start_{i['name']}"
        who = next((_key(v) for v in i["voicetags"] if _key(v) in actors and _key(v) not in ("geralt", "player")),
                   speakers[0])
        first_out = o["outputs"][min(n, len(o["outputs"]) - 1)] if o["outputs"] else None
        script[name] = [{who: f"(new line - started at {i['name']})"},
                        {"NEXT": f"section_exit_{_section(first_out)}" if first_out else "section_exit"}]
    for out in o["outputs"]:
        script[f"section_exit_{_section(out)}"] = ([] if out == DEFAULT_OUT else [{"OUTPUT": out}]) + ["EXIT"]
    if not o["outputs"]:
        script["section_exit"] = ["EXIT"]
    cameras = {f"{_section(k)}_cam": {"repo": "1_2_medium" if k == "geralt" else "2_1_medium"} for k in actors}
    return {"repository": {"actors": repo} if repo else {},
            "production": {"settings": {"sceneid": 1, "strings-idspace": 9999, "strings-idstart": 0},
                           "placement": "PLAYER", "assets": {"actors": actors, "cameras": cameras}},
            "storyboard": {"defaults": {"camera": {k: f"{_section(k)}_cam" for k in actors}}},
            "dialogscript": script}


INDEX = None


def scene_index():
    """Every scene of the game (depot paths), sorted - kept in %APPDATA%\\conjunction\\game_scenes.json."""
    global INDEX
    if INDEX is None:
        import json
        import os
        from . import config
        cache = os.path.join(os.path.dirname(config.PATH), "game_scenes.json")
        try:
            INDEX = json.load(open(cache, encoding="utf-8"))
        except (OSError, ValueError):
            from .bundles import Depot
            INDEX = sorted(p for p in Depot().where if p.endswith(".w2scene"))
            json.dump(INDEX, open(cache, "w", encoding="utf-8"))
    return INDEX


INFO = None


def scene_info():
    """{scene path: [voicetags of its actors (Geralt apart), ways in]} - to find a scene by who is in it (baron,
    yennefer ...) and to leave out those no quest starts; read once (a second), kept in
    %APPDATA%\\conjunction\\game_scene_info.json."""
    global INFO
    if INFO is None:
        import json
        import os
        import struct
        from . import config
        cache = os.path.join(os.path.dirname(config.PATH), "game_scene_info.json")
        try:
            INFO = json.load(open(cache, encoding="utf-8"))
        except (OSError, ValueError):
            from .assets import _cr2w_parts
            from .bundles import Depot
            d, INFO = Depot(), {}
            for p in scene_index():
                try:
                    f = _cr2w_parts(d.read(p))[0]
                except Exception:                           # noqa: BLE001 - a scene that does not read: left out
                    continue
                tags, ins = [], 0
                for cls, _fl, _pa, _t, chunk in f.exports:
                    if cls == "CStorySceneActor":
                        tags += [f.names[struct.unpack_from("<H", chunk, off)[0]]
                                 for name, tp, off, _sz in f.props(chunk) if name == "id" and tp == "CName"]
                    elif cls == "CStorySceneInput":
                        ins += 1
                INFO[p] = [" ".join(t.lower() for t in tags if t != "GERALT"), ins]
            json.dump(INFO, open(cache, "w", encoding="utf-8"))
    return INFO


def scene_people():
    """{scene path: "voicetags of its actors"}."""
    return {p: v[0] for p, v in scene_info().items()}


def label(path):
    """'mq1060 01 hook  -  mq1060 devils pit': the scene's name and the quest folder it is in."""
    parts = path.replace("/", "\\").split("\\")
    name = parts[-1].rsplit(".", 1)[0].replace("_", " ")
    folder = next((parts[k + 1] for k in range(len(parts) - 1) if parts[k] == "quest_files"),
                  parts[-3] if len(parts) > 2 else "")
    return f"{name}  -  {folder.replace('_', ' ')}" if folder else name


def new_swap(depot, path):
    """A swap of the game scene at `path`: its outline and a talk per input (who speaks first: its actor)."""
    o = outline(depot, path)
    if not o["inputs"]:
        raise ValueError("No quest starts this scene, so it cannot be replaced")
    inputs = {}
    for i in o["inputs"]:
        people = [_key(v) for v in i["voicetags"] if v != "GERALT"]
        main = people[0] if people else next((_key(a["voicetag"]) for a in o["actors"] if a["voicetag"] != "GERALT"),
                                             None)
        talk = {"swap": True, "input": i["name"], "dialogue": []}
        if main:
            talk["npc"] = main
            talk["with"] = [{"who": p} for p in people[1:]]
        inputs[i["name"]] = {"talk": talk}
    return {"scene": path, "name": label(path), "outline": o, "inputs": inputs}


# an actor the game scene names without a template (voicesets: whoever has the voicetag says it) still needs one for
# radish; it is only used if the game had to spawn the actor - it finds them by voicetag
STAND_IN = r"gameplay\community\community_npcs\novigrad\regular\novigrad_citizen_man.w2ent"


def cast_of(o):
    """{who: (actor key, radish asset, template)} of a game scene's actors (Geralt apart): who is the key the
    dialogue's lines use - the actor key itself."""
    out = {}
    for a in o["actors"]:
        if a["voicetag"] == "GERALT":
            continue
        k = _key(a["voicetag"])
        out[k] = (k, {"repo": k, "by_voicetag": bool(a["search_by_voicetag"]) if a["template"] else True},
                  a["template"] or STAND_IN)
    return out


def exit_section(output):
    return f"section_exit_{_section(output)}" if output != DEFAULT_OUT else "section_exit"


def _rename(x, names):
    """Section names in a dialogscript's bodies (NEXT, CHOICE, RANDOM) renamed by `names`."""
    if isinstance(x, str):
        return names.get(x, x)
    if isinstance(x, list):
        return [_rename(v, names) for v in x]
    if isinstance(x, dict):
        return {k: (_rename(v, names) if k in ("NEXT", "CHOICE", "RANDOM", "CUE", "choice", "on_true", "on_false")
                    else v)
                for k, v in x.items()}
    return x


MAX_ACTORS = 10                                     # radish: "expected 2-10 actor definitions in dialogscript"


def _only_speakers(scene):
    """A scene with more people than radish takes (the dwarves of q505: 13): only those who speak in it (and Geralt)
    - the others are in the world anyway, found by their voicetag."""
    script = scene["dialogScript"]
    actors = list(script["actors"])
    if len(actors) <= MAX_ACTORS:
        return
    spoken = set()
    for key, body in script.items():
        if isinstance(body, list):
            for x in body:
                if isinstance(x, dict):
                    spoken |= {k for k in x if k in actors}
    keep = [a for a in actors if a == "geralt" or a in spoken][:MAX_ACTORS]
    script["actors"] = keep
    assets = scene["production"]["assets"]
    assets["actors"] = {k: v for k, v in assets.get("actors", {}).items() if k in keep}
    cams = {f"{_section(k)}_cam" for k in keep}
    assets["cameras"] = {k: v for k, v in assets.get("cameras", {}).items() if k in cams}
    for kind in ("animations", "mimics"):
        if assets.get(kind):
            assets[kind] = {k: v for k, v in assets[kind].items() if v.get("actor") in keep}
    defaults = (scene.get("storyboard") or {}).get("defaults") or {}
    if defaults.get("camera"):
        defaults["camera"] = {k: v for k, v in defaults["camera"].items() if k in keep}
    repo = (scene.get("repository") or {}).get("actors")
    if repo:
        scene["repository"]["actors"] = {k: v for k, v in repo.items() if k in keep}


def scene(swap, scene_id, idspace, idstart, speech=None, own_ids=None, own_item=lambda item: None):
    """The radish scene of a swap: {scene: <game path>, outline: {...}, inputs: {name: {dialogue: [...], then:
    <output>}}} - a dialogue per input of the game scene (an input without one: its first output at once), merged
    into one scene with exactly the game scene's inputs, outputs and actors. -> (scene, strings used)"""
    from . import dialogue as D
    o = swap["outline"]
    cast = cast_of(o)
    outputs = o["outputs"] or [DEFAULT_OUT]
    exits = {f"out:{out}": exit_section(out) for out in outputs}
    merged, n_strings = None, 0
    for k, i in enumerate(o["inputs"]):
        name = i["name"]
        mine = (swap.get("inputs") or {}).get(name) or {}
        mine = mine.get("talk", mine)
        lines = mine.get("dialogue") or []
        # by default an input goes on at the output in its place (the game's scenes pair them mostly)
        then = mine.get("then") if mine.get("then") in outputs else outputs[min(k, len(outputs) - 1)]
        ex = dict(exits, **{"continue": exit_section(then), "retry": exit_section(then), "fail": exit_section(then)})
        start = "section_start" if name == DEFAULT_IN else f"section_start_{_section(name)}"
        if not lines:
            part = {"dialogScript": {start: [{"NEXT": exit_section(then)}]}, "storyboard": {}}
        else:
            main = mine.get("npc") if mine.get("npc") in cast else next(iter(cast), None)
            mcast = dict({"npc": cast[main]} if main else {}, **cast)
            part, _ends = D.to_scene(lines, None, None, scene_id, idspace, idstart + n_strings,
                                     f"cj_swap{scene_id}_{_section(name)}", own_ids, speech, cast=mcast, exits=ex,
                                     own_item=own_item)
            n_strings += D.string_count(lines)
            # its sections get the input's name (one scene holds every input's talk)
            script = part["dialogScript"]
            names = {s: (start if s == "section_start" else f"{s}_{_section(name)}") for s in script
                     if s not in ("player", "actors") and s not in exits.values()}
            for sec, cues in part["storyboard"].items():        # cues too: one scene, every input's
                if sec != "defaults":
                    names.update({c: f"{c}_{_section(name)}" for c in cues})
            part["dialogScript"] = {names.get(s, s): _rename(v, names) for s, v in script.items()}
            part["storyboard"] = {names.get(s, s): ({names.get(c, c): e for c, e in v.items()} if s != "defaults"
                                                    else v) for s, v in part["storyboard"].items()}
        if merged is None:
            merged = part if lines else skeleton(o)
            if not lines:
                merged["dialogScript"] = {"player": "geralt", "actors": merged["dialogscript"]["actors"]}
                merged.pop("dialogscript")
                merged["production"]["settings"] = {"sceneid": scene_id, "strings-idspace": idspace,
                                                    "strings-idstart": idstart}
                merged["dialogScript"].update(part["dialogScript"])
            continue
        merged["dialogScript"].update({s: v for s, v in part["dialogScript"].items() if s not in ("player", "actors")})
        for s, v in part["storyboard"].items():
            if s != "defaults":
                merged["storyboard"][s] = v
        for kind in ("animations", "mimics"):
            if part.get("production", {}).get("assets", {}).get(kind):
                merged["production"]["assets"].setdefault(kind, {}).update(part["production"]["assets"][kind])
    # every output must stay (the quest graph goes on from it); radish wants each pointed at - one nobody's talk
    # leads to gets an input of its own that the game never starts
    used = set()

    def refs(x):
        if isinstance(x, str):
            used.add(x)
        elif isinstance(x, list):
            for v in x:
                refs(v)
        elif isinstance(x, dict):
            for key, v in x.items():
                if key in ("NEXT", "CHOICE", "RANDOM", "choice", "on_true", "on_false"):
                    refs(v)
    refs([v for key, v in merged["dialogScript"].items() if key not in ("player", "actors")])
    # the player is always in it (the scene's look-ats go to them even where they say nothing)
    from .dialogue import PLAYERS
    if "geralt" not in merged["dialogScript"]["actors"]:
        merged["dialogScript"]["actors"] = ["geralt"] + list(merged["dialogScript"]["actors"])
    merged["production"]["assets"].setdefault("actors", {}).setdefault("geralt", {"repo": "geralt"})
    merged.setdefault("repository", {}).setdefault("actors", {}).setdefault(
        "geralt", {"template": PLAYERS["geralt"]["template"]})
    _only_speakers(merged)
    for k, out in enumerate(outputs):
        merged["dialogScript"][exit_section(out)] = ([] if out == DEFAULT_OUT else [{"OUTPUT": out}]) + ["EXIT"]
        if exit_section(out) not in used:
            merged["dialogScript"][f"section_start_cj_unused_{k + 1}"] = [{"NEXT": exit_section(out)}]
    return merged, n_strings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--skeleton")
    args = ap.parse_args()
    from .bundles import Depot
    o = outline(Depot(), args.path)
    print(yaml.safe_dump({k: v for k, v in o.items() if v}, sort_keys=False, allow_unicode=True))
    if args.skeleton:
        yaml.safe_dump(skeleton(o), open(args.skeleton, "w", encoding="utf-8"), sort_keys=False, allow_unicode=True)
        print("skeleton:", args.skeleton)


if __name__ == "__main__":
    sys.exit(main())
