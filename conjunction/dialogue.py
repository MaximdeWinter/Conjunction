"""A dialogue: a tree of lines and choices (the talk step keeps it; dialogue_view.py edits it as cards).

    dialogue:
      - {who: npc, text: "Witcher! Thank the gods.", gesture: greet, mood: afraid}
      - {who: geralt, text: "Hm?", voice: 354067, dur: 0.726}          # the game's own voiced line
      - choice:
          - {text: "Fine, a drink.", end: on}                           # a tone: its lines, then on below
          - {text: "Not in the mood.", lines: [...], end: on}
      - {who: npc, text: "Yennefer of Vengerberg?"}                    # where the ways that go on join
      - choice:
          - {text: "What happened?", lines: [...], end: back}         # a question: asked, heard, choose again
          - {text: "Show me the way.", end: on, emphasize: true}       # the main way (yellow): on below
          - {text: "Not now.", end: retry}                              # talk again later
          - {text: "Not my problem.", end: fail}                        # the quest fails
      - {who: npc, text: "Follow me."}                                  # (after 'Show me the way.')

`who` is geralt or npc (the one the step talks to). An answer ends: on (the talk goes on after its choice; no line
after it: the talk is over, the quest goes on), back (to its choice), up (to the choice around that one), continue
(the talk ends, the quest goes on), retry, fail, path:<id>. A way of an if / random without an end goes on. An
answer's lines can hold a choice again (a tree). `to_scene()` makes the radish scene of it.
"""
import os
import re

# gestures during a line: the game's standing dialogue gestures (animations of radish's repo.scenes/sbui repository).
# A body plays only what its own animsets have (talking.dialogue_anims): a gesture is the first of its animations the
# speaker has - men (Geralt too) and women have different ones; none of them: no gesture (a T-pose otherwise).
GESTURES = [
    ("explain", "Explain", ["high_standing2_determined_gesture_explain_01"]),
    ("explain_short", "Explain briefly", ["high_standing2_determined_gesture_explain_02"]),
    ("ask", "Ask", ["high_standing2_determined_gesture_question_01"]),
    ("point", "Point", ["high_standing_aggressive_gesture_point_forward_r"]),
    ("instruct", "Instruct", ["high_standing_sad_gesture_instruct", "high_standing_aggressive_gesture_statement"]),
    ("greet", "Greet", ["high_standing_determined_gesture_greeting_01", "high_standing2_determined_gesture_greeting"]),
    ("bow", "Bow", ["high_standing_determined_gesture_bow_short", "high_standing_determined_gesture_bow_1"]),
    ("farewell", "Farewell", ["high_standing_proud_gesture_right_hand_wave",
                              "high_standing_determined_gesture_farewell_right"]),
    ("agree", "Agree", ["high_standing_determined_gesture_sure", "high_standing_happy_gesture_acknowledge"]),
    ("decline", "Decline", ["high_standing_determined_gesture_decline", "high_standing_sad_gesture_decline"]),
    ("shrug", "Shrug", ["high_standing_aggressive_gesture_shrug", "high_standing_aggressive_gesture_pfff"]),
    ("sigh", "Sigh", ["high_standing_sad_gesture_sigh", "high_standing_aggressive_gesture_sigh"]),
    ("wave_away", "Wave away", ["high_standing_aggressive_gesture_left_hand_wave_1",
                                "high_standing_aggressive_gesture_wave_away"]),
    ("stop", "Stop!", ["high_standing_determined_gesture_both_hands_stop"]),
    ("exclaim", "Exclaim", ["high_standing_determined_gesture_exclamation_01",
                            "high_standing_aggressive_gesture_statement"]),
    ("shout", "Shout", ["high_standing_determined_exclamation_gesture_02_both_hands",
                        "high_standing_aggressive_gesture_you_01"]),
    ("chuckle", "Chuckle", ["high_standing_determined_gesture_chuckle", "high_standing_happy_gesture_amazed"]),
    ("sorry", "Apologise", ["high_standing_bored_gesture_sorry", "high_standing_devastated_gesture_worried"]),
    ("facepalm", "Facepalm", ["high_standing_determined_gesture_facepalm"]),
    ("give", "Hand over", ["high_standing_determined_gesture_give"]),
    ("scratch_head", "Scratch head", ["high_standing_sad_gesture_headscratch"]),
]
# moods: the face (radish's repo.scenes/example.repo.yml, mimics)
MOODS = [("neutral", "Neutral"), ("happy", "Happy"), ("very_happy", "Very happy"), ("sad", "Sad"), ("cry", "Crying"),
         ("afraid", "Afraid"), ("very_afraid", "Terrified"), ("nervous", "Nervous"), ("angry", "Angry"),
         ("aggressive", "Aggressive"), ("contempt", "Contempt"), ("disgusted", "Disgusted"),
         ("surprised", "Surprised"), ("sceptic", "Sceptical"), ("determined", "Determined"), ("proud", "Proud"),
         ("confident", "Confident"), ("drunk", "Drunk")]
GESTURE = {k: (label, anims[0]) for k, label, anims in GESTURES}
# an Axii answer: the player casts it first, as in the game's scenes (q702_18_bootblack_saved, q704_03b_diva_and_family)
AXII_CAST_ANIM = "high_standing_determined_gesture_axii_open_right"
AXII_CAST_SECONDS = 2.4
# poses: how a person stands, sits, kneels, lies through a talk (the idle animations the game's scenes use - counted
# over all 6 222 of them, _scratch/marathon/poses_vanilla.json); a body takes the first it has (none: as it is)
POSES = [
    ("stand", "Standing", ["high_standing_determined_idle", "high_standing_neutral_idle"]),
    ("stand_proud", "Standing proud", ["high_standing_proud_idle", "high_standing_canaris_proud_idle"]),
    ("stand_sad", "Standing sad", ["high_standing_sad_idle", "low_standing_sad_beaten_idle"]),
    ("stand_angry", "Standing angry", ["high_standing_aggressive_idle", "low_standing_aggressive_idle"]),
    ("stand_happy", "Standing happy", ["high_standing_happy_idle", "low_standing_happy_idle"]),
    ("stand_bored", "Standing bored", ["high_standing_bored_idle", "low_standing_bored_idle"]),
    ("lean", "Leaning back", ["high_standing_leaning_back_determined_idle", "low_standing_leaning_aggressive_idle"]),
    ("cover", "Covering up", ["low_standing_cover_body_idle"]),
    ("book", "Holding a book", ["high_standing_hold_book_determined_idle"]),
    ("sit", "Sitting", ["high_sitting_determined_idle", "high_sitting2_determined_idle",
                        "high_sitting_chair_determined_idle", "low_sitting_determined_idle"]),
    ("sit_happy", "Sitting happy", ["high_sitting_happy_idle", "low_sitting_ground_happy_idle"]),
    ("sit_bored", "Sitting bored", ["high_sitting_bored_idle", "low_sitting_bored_idle"]),
    ("sit_sad", "Sitting sad", ["low_sitting_sad_idle", "low_sitting_ground_sad_idle", "low_sitting_devastated2_idle"]),
    ("sit_ground", "Sitting on the ground", ["low_sitting_ground_happy_idle", "low_sitting_ground_sad_idle"]),
    ("sit_lean", "Sitting, leaning back", ["low_sitting_leaning_determined_idle", "low_sitting_leaning_proud_idle",
                                           "low_sitting_ground_leaning_back_bored_idle"]),
    ("kneel", "Kneeling", ["high_kneeling_determined_idle", "low_kneeling_determined_idle"]),
    ("lie", "Lying", ["high_lying_ground_determined_idle", "low_lying_breathing_idle"]),
    ("lie_hurt", "Lying hurt", ["low_lying_exhausted_idle", "low_lying_breathing_idle"]),
    ("tied", "Tied up", ["low_sitting_ground_tiedup_idle"]),
]
POSE = {k: label for k, label, _a in POSES}


def pose_anim(key, have=None):
    """The idle animation a pose is for a body that has `have` (None: not known - the first), or None."""
    anims = next((a for k, _l, a in POSES if k == key), [])
    if have is None:
        return anims[0] if anims else None
    return next((a for a in anims if a in have), None)


MOOD_WORDS = ("determined", "happy", "sad", "aggressive", "agressive", "proud", "bored", "devastated", "nervous",
              "neutral", "drunk", "exhausted")


def pose_drop(anim):
    """How much lower than standing a pose's eyes are (m) - for the cameras on that person."""
    a = anim or ""
    if "lying" in a or "laying" in a:
        return -1.3
    if a.startswith("low_sitting") or "sitting_ground" in a or "tiedup" in a:
        return -0.85
    if "sitting" in a:
        return -0.45
    if "kneeling" in a:
        return -0.55
    return 0.0


def pose_state(anim):
    """The state the game's poses name with their idle (radish's actor.poses: status, name, emotional_state - as its
    own example: Low, Kneeling, Determined): 'low_sitting_ground_happy_idle' -> Low, Sitting, Happy."""
    words = anim.split("_")
    out = {}
    if words and words[0] in ("high", "low"):
        out["status"] = words[0].capitalize()
    posture = next((w for w in words if w in ("standing", "sitting", "kneeling", "lying", "laying", "channeling")),
                   None)
    if posture:
        out["name"] = "Lying" if posture == "laying" else posture.capitalize()
    mood = next((w for w in words if w in MOOD_WORDS), None)
    if mood:
        out["emotional_state"] = "Aggressive" if mood == "agressive" else mood.capitalize()
    return out


def poses_for(have=None):
    """[(key, label)] of the poses a body can take (all while `have` is not known)."""
    return [(k, label) for k, label, _a in POSES if have is None or pose_anim(k, have)]


def gesture_anim(key, have=None):
    """The animation a gesture is for a body that has `have` (talking.dialogue_anims; None: not known - the first),
    or None: it has none of them."""
    anims = next((a for k, _l, a in GESTURES if k == key), [])
    if have is None:
        return anims[0] if anims else None
    return next((a for a in anims if a in have), None)


def gestures_for(have=None):
    """[(key, label)] of the gestures a body can play (all while `have` is not known)."""
    return [(k, label) for k, label, _a in GESTURES if have is None or gesture_anim(k, have)]


MOOD = dict(MOODS)
# how an answer ends
ENDS = [("back", "Back to choice"), ("continue", "End: continue quest"), ("retry", "End: repeatable"),
        ("fail", "Quest fails")]
# (an answer inside an answer's choice can also go "up": back to the choices before - the choice above its own)
END = dict(ENDS)
CODE = {"continue": 1, "retry": 2, "fail": 3}


def codes(ends):
    """The fact value of every way out: continue 1, retry 2, fail 3, paths 10, 11, ... (sorted by name)."""
    out = {e: CODE[e] for e in ends if e in CODE}
    for k, e in enumerate(sorted(e for e in ends if e.startswith("path:"))):
        out[e] = 10 + k
    return out


def socket(e):
    """A way out as a quest block's socket name ([a-z_0-9])."""
    return e.replace(":", "_")

_ANIM_IDS = None


_ALL_ANIMS = None


def all_animations():
    """[(animation, seconds)] of every scene animation radish knows (repo.scenes/sbui.all_animations.repo.yml)."""
    global _ALL_ANIMS
    if _ALL_ANIMS is None:
        _ALL_ANIMS = []
        try:
            from . import config
            path = os.path.join(config.load()["radish"], "repo.scenes", "sbui.all_animations.repo.yml")
            text = open(path, encoding="utf-8").read()
            seen = set()
            for m in re.finditer(r'\n        \S+:\n            animation: "([^"]+)"\n            frames: (\d+)', text):
                if m.group(1) not in seen:
                    seen.add(m.group(1))
                    _ALL_ANIMS.append((m.group(1), int(m.group(2)) / 30.0))
        except (OSError, KeyError):
            pass
    return _ALL_ANIMS


def find_animations(words, limit=80, only=None):
    """The animations whose name has every word (in the order of the repo); `only`: of these (a body's own)."""
    ws = [w for w in words.lower().replace("_", " ").split() if w]
    out = []
    for name, secs in all_animations():
        if only is not None and name not in only:
            continue
        n = name.replace("_", " ")
        if all(w in n for w in ws):
            out.append((name, secs))
            if len(out) >= limit:
                break
    return out


def anim_label(animation):
    return animation.replace("_", " ")


def anim_repo_id(animation):
    """The radish repository id of a game animation ('anim_4033_high_standing_...'), or None."""
    global _ANIM_IDS
    if _ANIM_IDS is None:
        _ANIM_IDS = {}
        try:
            from . import config
            path = os.path.join(config.load()["radish"], "repo.scenes", "sbui.all_animations.repo.yml")
            text = open(path, encoding="utf-8").read()
            for m in re.finditer(r'\n        (\S+):\n            animation: "([^"]+)"', text):
                _ANIM_IDS.setdefault(m.group(2), m.group(1))
        except (OSError, KeyError):
            pass
    return _ANIM_IDS.get(animation)


def anim_seconds(repo):
    """How long a scene animation of radish's repository runs (by its repo id), or None."""
    global _REPO_SECS
    if _REPO_SECS is None:
        _REPO_SECS = {}
        for name, secs in all_animations():
            rid = anim_repo_id(name)
            if rid:
                _REPO_SECS.setdefault(rid, secs)
    return _REPO_SECS.get(repo)


_REPO_SECS = None


def fit_gestures(scene):
    """A gesture longer than its line ends with the line: cut there and blended out (Maxim, 01.10.: when the line was
    over, the speaker snapped back to standing). Needs the lines' durations ("[<seconds>]..." - after timing)."""
    anims = ((scene.get("production") or {}).get("assets") or {}).get("animations") or {}
    board = scene.get("storyboard") or {}
    for section, body in (scene.get("dialogScript") or {}).items():
        if not isinstance(body, list):
            continue
        for k, item in enumerate(body):
            if not (isinstance(item, dict) and "CUE" in item):
                continue
            dur = None
            for nxt in body[k + 1:]:                    # the line the cue belongs to
                if isinstance(nxt, dict) and len(nxt) == 1:
                    v = next(iter(nxt.values()))
                    if isinstance(v, str) and v.startswith("[") and "]" in v:
                        try:
                            dur = float(v[1:v.index("]")])
                        except ValueError:
                            dur = None
                        break
            events = (board.get(section) or {}).get(item["CUE"])
            if dur is None or not isinstance(events, list):
                continue
            for j, ev in enumerate(events):
                pos = ev.get("actor.anim") if isinstance(ev, dict) else None
                if not isinstance(pos, list) or len(pos) != 2 or pos[1] not in anims:
                    continue
                secs = anim_seconds(anims[pos[1]].get("repo"))
                room = dur - float(pos[0])
                if secs is None or secs <= room or room <= 0.3:
                    continue
                events[j] = {"actor.anim": {".@pos": [pos[0], pos[1]], "clipend": round(room, 3),
                                            "blendout": round(min(0.6, room / 2), 3)}}
    return scene


# --- who talks: the player, the one the step talks to ("npc") and more people ("with": [{who: place/id, joins}])
# The player is whoever is played at that point of the quest - Geralt, or Ciri after a 'Play as' (the game's own
# quests switch with ChangePlayerQuest). A line's `who` says "player"; older files say "geralt" - the same.
PLAYER = "player"
PLAYERS = {   # the game's playable characters (gameplay.xml aliases the game's ChangePlayer takes)
    "geralt": {"label": "Geralt", "template": "gameplay\\templates\\characters\\player\\player.w2ent",
               "voicetag": "GERALT", "enum": "EQRE_Geralt"},
    "ciri": {"label": "Ciri", "template": "gameplay\\templates\\characters\\player\\ciri_player.w2ent",
             "voicetag": "CIRILLA", "enum": "EQRE_Ciri"},
}
PLAYER_COLOR = GERALT_COLOR = "#c4c8d0"                # silver
COLORS = ["#e0915f", "#6fb4e0", "#8fd07a", "#e07fae", "#b99be6", "#e3c65f", "#5fcbb9", "#e57a7a", "#9fb0ff",
          "#cfa57a", "#7adf9f", "#dcb0ff"]
JOINS = [("start", "There from the start"), ("line", "Comes in at their first line")]


def is_player(who):
    return who in (PLAYER, "geralt")


def speakers(a):
    """[(key, object reference or None, label)] - key is what a line's `who` says. A talk with himself (examining
    something: no one to talk to) has only the player."""
    if "object" in a and "npc" not in a:
        return [(PLAYER, None, "Player")]
    out = [(PLAYER, None, "Player"), ("npc", a.get("npc"), _label(a.get("npc")) or "NPC")]
    for w in a.get("with") or []:
        out.append((w["who"], w["who"], _label(w["who"])))
    return out


def _label(ref):
    return (ref or "").split("/")[-1].replace("_", " ").capitalize()


def color(key, a=None):
    """The player silver; everybody else a colour of their own (the same every time: from their name)."""
    if is_player(key):
        return PLAYER_COLOR
    ref = (a or {}).get("npc") if key == "npc" else key
    import zlib
    return COLORS[zlib.crc32((ref or key).encode("utf-8")) % len(COLORS)]


def extra_key(ref):
    """The scene's actor name of an extra person (radish: [a-z_0-9])."""
    return "p_" + "".join(c if c.isalnum() else "_" for c in ref.lower())


# --- the tree
def from_step(a):
    """The dialogue of a talk step; the older form (lines "who: text", choices with then) is read too."""
    if a.get("dialogue") is not None:
        return a["dialogue"]
    out = [_line(x) for x in a.get("lines") or []]
    if a.get("choices"):
        out.append({"choice": [dict({"text": c.get("text", ""), "lines": [_line(x) for x in c.get("lines") or []],
                                     "end": c.get("then") or "continue"},
                                    **({"say": False} if c.get("say") is False else {}))
                               for c in a["choices"]]})
    return out


def _line(x):
    if isinstance(x, dict) and "text" in x:
        return x
    if isinstance(x, dict):
        who, text = next(iter(x.items()))
    elif ":" in str(x):
        who, text = str(x).split(":", 1)
    else:
        who, text = "npc", str(x)
    who = who.strip().lower()
    return {"who": PLAYER if is_player(who) else "npc", "text": str(text).strip()}


SPLITS = ("choice", "if", "random")


def split_at(ls, start=0):
    """Where the first choice / if / random of a list of lines is (None: it has none)."""
    return next((k for k in range(start, len(ls)) if any(s in ls[k] for s in SPLITS)), None)


def ways(x):
    """(lines, end) of every way of a choice / if / random; an if's or random's way without an end goes on."""
    if "choice" in x:
        return [(c.get("lines") or [], str(c.get("end") or "continue")) for c in x["choice"]]
    brs = (x.get("random") or []) if "random" in x else [x.get(s) or {} for s in ("then", "else")]
    return [(br.get("lines") or [], str(br.get("end") or "on")) for br in brs]


def walk(lines):
    """Every line and answer of the tree."""
    for x in lines:
        if "choice" in x:
            for c in x["choice"]:
                yield c
                yield from walk(c.get("lines") or [])
        elif "if" in x:
            for side in ("then", "else"):
                yield from walk((x.get(side) or {}).get("lines") or [])
        elif "random" in x:
            for way in x["random"] or []:
                yield from walk(way.get("lines") or [])
        elif "script" in x:
            continue                                    # no line: the scene runs it
        else:
            yield x


def options(lines):
    """Every answer of the tree (the dicts of its choices)."""
    for x in lines:
        if "choice" in x:
            for c in x["choice"]:
                yield c
                yield from options(c.get("lines") or [])
        elif "if" in x:
            for side in ("then", "else"):
                yield from options((x.get(side) or {}).get("lines") or [])
        elif "random" in x:
            for way in x["random"] or []:
                yield from options(way.get("lines") or [])


def again_lines(a):
    """A talk 'every time' (Maxim 05.10.: "am ende des dialogs einfügen was man erneut fragen darf ... custom lines
    oder auf eine frage die geralt stellt verweisen"): what it is when talked to again - its greeting, then a choice of
    the questions one may ask again (a question of the talk by its id, `ask`, or one of its own: text and lines),
    each heard and back to the choice, and a goodbye that ends the talk. None: the whole dialogue again.

        again: {greet: "Back again?", bye: "Farewell.",
                questions: [{ask: "o3"}, {text: "Where is the camp?", lines: [{who: npc, text: "North."}]}]}"""
    import copy
    ag = a.get("again") or {}
    items = ag.get("questions") or []
    if not items:
        return None
    by_id = {c.get("id"): c for c in options(from_step(a)) if c.get("id")}
    opts = []
    for it in items:
        if it.get("ask"):
            c = by_id.get(it["ask"])
            if c is None:
                raise ValueError(f"Asked again: the question '{it['ask']}' is no longer in the talk")
            opts.append({"text": c.get("text") or "...", "lines": copy.deepcopy(c.get("lines") or []), "end": "back"})
        else:
            opts.append({"text": it.get("text") or "...", "lines": list(it.get("lines") or []), "end": "back"})
    opts.append({"text": ag.get("bye") or "Goodbye.", "end": "continue"})
    return ([{"who": "npc", "text": ag["greet"]}] if ag.get("greet") else []) + [{"choice": opts}]


def summary(lines):
    n_lines = sum(1 for x in walk(lines) if "who" in x)
    n_answers = sum(1 for x in walk(lines) if "who" not in x)
    voiced = sum(1 for x in walk(lines) if x.get("voice"))
    parts = [f"{n_lines} line{'s' * (n_lines != 1)}"]
    if n_answers:
        parts.append(f"{n_answers} option{'s' * (n_answers != 1)}")
    if voiced:
        parts.append(f"{voiced} voiced")
    return ", ".join(parts)


def outcomes(lines):
    """How the dialogue can end: a subset of continue / retry / fail / path:x / out:x (the talk's lines over: it goes
    on). A way that goes back to a choice ends nowhere itself - that choice's other ways do."""
    out, done = set(), set()

    def run(ls, start, then):
        """The lines of `ls` from `start` on; `then()` when they are over."""
        if (id(ls), start) in done:
            return
        done.add((id(ls), start))
        k = split_at(ls, start)
        if k is None:
            then()
            return
        after = (lambda: run(ls, k + 1, then)) if k + 1 < len(ls) else then
        for sub, e in ways(ls[k]):
            if e in ("back", "up"):
                continue
            run(sub, 0, after if e == "on" else (lambda e=e: out.add(e)))
    run(lines, 0, lambda: out.add("continue"))
    return {e for e in out if e in CODE or e.startswith(("path:", "out:"))} or {"continue"}


AFTER_ALL = "@all"


OPS = ("=", "!=", "<", "<=", ">", ">=")


def conditions(c):
    """An option's conditions, a list (all must hold): '@all' (after all other options of its choice), '@<id>'
    (after that option - of any talk of the quest), a fact name (a branch taken: it is 1), [fact, op, value]."""
    cond = c.get("only_if")
    if not cond:
        return []
    if isinstance(cond, str):
        return [cond]
    if len(cond) == 3 and isinstance(cond[0], str) and cond[1] in OPS:
        return [list(cond)]                             # one fact compared (from a game scene)
    return [x if isinstance(x, str) else list(x) for x in cond]


def set_conditions(c, conds):
    if conds:
        c["only_if"] = conds[0] if len(conds) == 1 and isinstance(conds[0], str) else list(conds)
    else:
        c.pop("only_if", None)


def after_others(choice, c):
    """'After all other options' (Maxim, 01.10.: a monologue whose exit shows only once everything was looked at):
    the options of the same choice it waits for - only those chosen and come back from: 'once' ones and those that go
    back to the choice (an option that ends the talk - 'Not now.' - is nothing to ask first: in game 01.10. the exit
    waited for it and never showed); not those that wait for all themselves."""
    if AFTER_ALL not in conditions(c):
        return []
    return [o for o in choice if o is not c and AFTER_ALL not in conditions(o)
            and (o.get("once") or str(o.get("end", "")) in ("back", "up"))]


def option_fact(qid, oid):
    """The fact that says an option (by its id) was chosen - asked by 'After option' anywhere in the quest."""
    return f"{qid}_opt_{oid}"


def chosen_fact(fact, n, k):
    """The fact that says option k of choice n of a scene was chosen."""
    return f"{fact}_o{n}_{k}"


def only_if_checks(cond):
    """An answer's 'only if' as [[fact, op, value]]: a decision (a fact name: it is 1), one check, or several (all
    of them)."""
    if not cond:
        return []
    if isinstance(cond, str):
        return [[cond, "=", 1]]
    if cond and isinstance(cond[0], (list, tuple)):
        return [list(x) for x in cond]
    return [list(cond)]


def says_choice(c):
    """Does the player say an answer's text when it is chosen? Set on it (say: true / false) - or: not when its first
    line is the player's own (the option is a heading then, 'Give him the boots' -> 'Here you go.'; Maxim 02.10.:
    Geralt read the option, then his line), else yes (a whole sentence, as the game's)."""
    if c.get("say") is not None:
        return bool(c["say"])
    first = next(iter(c.get("lines") or []), None)
    return not (isinstance(first, dict) and "who" in first and is_player(first.get("who")))


def custom_voiced(lines, mouth=True):
    """The lines that get their audio from the quest's DLC: own recordings (a content pack's voice line) and, with
    `mouth`, every line without a voice (silence, the mouth moves to the text)."""
    out = [x for x in walk(lines) if ("who" in x or says_choice(x))
           and (x.get("voice_pack") or mouth and not x.get("voice") and not x.get("thought"))]
    if mouth:                                           # the variants of a line are lines of their own
        out += [{"text": t} for x in walk(lines) for t in x.get("alt") or [] if str(t).strip()]
    return out


def string_count(lines):
    """How many strings the scene needs (a line, an answer and Geralt saying it)."""
    return sum((2 if "who" not in x else 1) + len(x.get("alt") or []) for x in walk(lines)) + 2


# --- the radish scene
# wide shots from the side for the people after the two main ones (radish's example for many actors: side_1 ..)
_SIDE = [(40.0, -15.0), (45.0, -15.0), (45.0, -10.0), (45.0, -18.0), (50.0, -15.0), (60.0, -15.0), (70.0, -15.0),
         (80.0, -15.0)]
SIDE_CAMERAS = {f"cj_side_{k + 1}": {
    "fov": fov, "transform": {"pos": [-3.5 if k != 1 else -4.5, 1.2, 1.9], "rot": [0.0, tilt, 260.0 if k != 1 else 240.0]},
    "zoom": 0.0, "dof": {"aperture": [42.14, 2.7], "blur": [4.0, 5.0], "focus": [1.45, 3.0], "intensity": 1.0},
    "event_generator": {"plane": "medium", "tags": ["ext"]}} for k, (fov, tilt) in enumerate(_SIDE)}


# a line's camera (Maxim, 01.10.): the shots of the game's own dialogues - their names and places (relative to the
# scene's two slots) taken from ~700 vanilla scenes (camera_shots.json). '1_2_*' frames slot 1 (the player), '2_1_*'
# the other one, each over the listener's shoulder.
SHOTS = [("", "Default"), ("wide", "Wide"), ("medium", "Medium"), ("semicloseup", "Semi close-up"),
         ("closeup", "Close-up"), ("supercloseup", "Extreme close-up")]
_SHOT_DEFS = None


def shot_camera(player_speaks, plane, drop=0.0, player_at=None):
    """(repo name, its definition) of a shot on the one who speaks, or None. `drop`: how much lower the person is than
    standing (a pose) - the camera goes down with them. `player_at`: where the player stands in the scene's space
    ([x, y, z]; the game's shots expect them 1.6 m in front of the person) - the shot turned around the person to
    them, a shot on the player moved along with them."""
    global _SHOT_DEFS
    if _SHOT_DEFS is None:
        import json
        try:
            _SHOT_DEFS = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                     "camera_shots.json"), encoding="utf-8"))
        except (OSError, ValueError):
            _SHOT_DEFS = {}
    side = "1_2" if player_speaks else "2_1"
    for suffix in ("ext", "int"):
        name = f"{side}_{plane}_{suffix}"
        d = _SHOT_DEFS.get(name)
        if d:
            pos = [d["pos"][0], d["pos"][1], round(d["pos"][2] + drop, 3)]
            rot = list(d["rot"])
            low = f"_low{int(round(-drop * 100))}" if drop else ""
            if player_at:
                import math
                px, py = float(player_at[0]), float(player_at[1])
                t = math.atan2(-px, py)                     # the player's direction from the person (a heading)
                x, y = pos[0], pos[1] - (1.6 if player_speaks else 0.0)
                x, y = x * math.cos(t) - y * math.sin(t), x * math.sin(t) + y * math.cos(t)
                if player_speaks:
                    x, y = x + px, y + py
                    pos[2] = round(pos[2] + float(player_at[2] if len(player_at) > 2 else 0.0), 3)
                pos[0], pos[1] = round(x, 3), round(y, 3)
                rot[2] = round((rot[2] + math.degrees(t)) % 360, 2)
                low += f"_at{int(round(px * 100))}_{int(round(py * 100))}".replace("-", "m")
            return f"cj_{name}{low}", {"fov": d["fov"], "transform": {"pos": pos, "rot": rot},
                                   "zoom": d.get("zoom", 0.0),
                                   "dof": {"aperture": [28.25, 1.27], "blur": [3.0, 10.0], "focus": [2.0, 4.0],
                                           "intensity": 1.0},
                                   "event_generator": {"plane": plane, "tags": [suffix]}}
    return None


def own_camera(c):
    """The radish camera of one of a talk's own cameras, `c` in the scene's space ({pos, yaw, pitch, fov}): rot is
    [roll, pitch, yaw] (the repo's 'side_tilt_right_slight_from_above': [0, -15, 260])."""
    return {"fov": float(c.get("fov", 35.0)),
            "transform": {"pos": [round(float(v), 3) for v in c["pos"]],
                          "rot": [0.0, round(float(c.get("pitch", 0.0)), 2), round(float(c.get("yaw", 0.0)) % 360, 2)]},
            "zoom": 0.0,
            "dof": {"aperture": [28.25, 1.27], "blur": [3.0, 10.0], "focus": [2.0, 4.0], "intensity": 0.0},
            "event_generator": {"plane": "medium", "tags": ["ext"]}}


def scene_space(c, origin, origin_yaw):
    """A camera ({pos, yaw, pitch, fov}) or where someone stands ({pos, yaw}), set in the world, in the space of a
    scene placed at `origin` (x, y, z) turned by `origin_yaw` (the scene point: the person's spot and heading)."""
    import math
    a = math.radians(-float(origin_yaw))
    dx, dy = c["pos"][0] - origin[0], c["pos"][1] - origin[1]
    return dict(c, pos=[dx * math.cos(a) - dy * math.sin(a), dx * math.sin(a) + dy * math.cos(a),
                        c["pos"][2] - origin[2]],
                yaw=(float(c.get("yaw", 0.0)) - float(origin_yaw)) % 360)


def side_cameras(keys):
    """{camera asset: {repo}}, {actor: camera asset}, {repo cameras} for these actors (in order), side_1 on."""
    assets, defaults, repo = {}, {}, {}
    for k, key in enumerate(keys[:len(SIDE_CAMERAS)]):
        name, cam = f"{key.replace(' ', '_')}_cam", f"cj_side_{k + 1}"
        assets[name], defaults[key], repo[cam] = {"repo": cam}, name, SIDE_CAMERAS[cam]
    return assets, defaults, repo


HOLD_SWORD = {"steel": "steelsword", "silver": "silversword"}
_BANKS = {}


def sound_bank(event):
    """The game's sound bank that holds a sound event (radish's repo.scenes/soundevents.with-exp.repo.yml), or None."""
    if not _BANKS:
        import yaml

        from . import config
        f = os.path.join(config.load().get("radish", ""), "repo.scenes", "soundevents.with-exp.repo.yml")
        try:
            banks = ((yaml.safe_load(open(f, encoding="utf-8")) or {}).get("repository") or {}).get("soundbanks") or {}
        except (OSError, yaml.YAMLError):
            banks = {}
        for bank, events in banks.items():
            for e in events or []:
                _BANKS.setdefault(str(e), str(bank))
        _BANKS.setdefault("", "")
    return _BANKS.get(str(event))


def with_soundbanks(scene):
    """The sound banks the scene's sounds come from, in its production assets (radish wants them imported)."""
    banks = set()

    def walk(x):
        if isinstance(x, dict):
            for k, v in x.items():
                if k == "actor.sound" and isinstance(v, list) and len(v) >= 3:
                    b = sound_bank(v[2])
                    if not b:
                        raise ValueError(f"The sound {v[2]} is in none of the game's sound banks")
                    banks.add(b)
                else:
                    walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(scene.get("storyboard") or {})
    if banks:
        scene["production"]["assets"]["soundbanks"] = sorted(banks)
    return scene


def line_events(x, who, marks=None, props=None):
    """What happens with a line besides the words (PLAN 2.4): `sound` (a sound event of the game), `hold` (an item in
    the speaker's right hand - "" puts it away; `sword`: steel / silver draws one), `appearance` (the speaker's look
    from now on), `fade` (out: the screen goes black at the line's end, in: it comes back at its start), `goto` (a
    mark of the talk: the speaker stands there from this line on - `marks` {name: {pos, yaw}} in the scene's space),
    `show` / `hide` (things of the talk - `props` {name: the scene's prop key})."""
    out = []
    for k in ("show", "hide"):
        out += [{f"prop.{k}": [0.0, (props or {})[n]]} for n in x.get(k) or [] if n in (props or {})]
    m = (marks or {}).get(x.get("goto")) if x.get("goto") else None
    if m:
        out.append({"actor.placement": [0.0, who, [round(float(v), 3) for v in m["pos"]],
                                        [0.0, 0.0, round(float(m.get("yaw", 0.0)) % 360, 2)]]})
    if x.get("sound"):
        out.append({"actor.sound": [0.0, who, str(x["sound"])]})
    if x.get("sword") in HOLD_SWORD:
        out.append({"actor.equip.right": [0.2, who, HOLD_SWORD[x["sword"]]]})
    elif "hold" in x:
        out.append({"actor.equip.right": [0.2, who, str(x["hold"])]} if x["hold"] else
                   {"actor.unequip.right": [0.2, who]})
    if x.get("appearance"):
        out.append({"actor.appearance": [0.0, who, str(x["appearance"])]})
    if x.get("fade") == "out":
        out.append({"fade.out": [0.8, 1.0]})
    elif x.get("fade") == "in":
        out.append({"fade.in": [0.0, 1.0]})
    return out


def to_scene(lines, npc_template, npc_tag, scene_id, idspace, idstart, fact, own_ids=None, speech=None, mouth=True,
             extras=(), own_item=lambda item: None, cast=None, exits=None, character="geralt", qid="cj",
             poses=None, gameplay=False, cams=None, stands=None, placement="PLAYER", cam_defaults=None,
             marks=None, props=None):
    """-> (radish scene definition, outcomes). When the dialogue can end in more than one way, the answer that ends
    it sets `fact` (1 continue, 2 retry, 3 fail) and the quest branches on it.
    Lines with an own recording take their string ids from `own_ids` (an iterator); what the build needs for them
    (id, text, recording) goes into `speech`. `extras`: more people [(reference, template, tag, joins)] - joins
    "line": hidden until they speak.
    A game scene swapped (scene_swap.py): `cast` {who: (actor key, asset, template or None)} - its actors, found by
    voicetag - in place of the NPC and the extras; `exits` {end: section} - where each end goes (the game scene's
    outputs); no facts then. `character`: who the player is here (PLAYERS) - the scene's player actor is them.
    `poses`: {who: pose} each person's pose from the start ("player", "npc", an extra's reference); a line's `pose`
    changes its speaker's, its `look` turns the speaker's eyes to someone ("player", "npc", a reference).
    `cams`: the talk's own cameras {name: {pos, yaw, pitch, fov}} in the scene's space (scene_space); a line's
    `camera` 'cam:<name>' is one of them, its `glide` the camera it moves from through the line.
    `stands`: {who: {pos, yaw}} where people stand in the scene's space ("player", an extra's reference) - the
    scene's person stands at its origin; without it the game puts the player 1.6 m in front of them and moves the
    whole scene elsewhere when that spot is taken (Keira in her bath, 02.10.).
    `cam_defaults`: {"player" / "npc": "cam:<name>"} - one of the own cameras as that person's camera for every line
    of theirs without one of its own (the player's: at the choices too).
    `placement`: the tag of the entity the scene is placed at (its origin and heading) - the person's scene point;
    PLAYER (radish's default) puts the origin where the player stands and the person is moved there (02.10.).
    `marks`: the talk's spots {name: {pos, yaw}} in the scene's space; `props`: its things {name: {template, mark}} -
    each stands on its mark, a line's `show` / `hide` (names) shows or hides it; one a line shows is hidden before."""
    prop_key = {} if exits is not None else {
        n: f"prop_{k + 1}_{re.sub('[^a-z0-9]+', '_', n.lower()).strip('_')}"[:40]
        for k, n in enumerate(n for n, p in (props or {}).items() if p.get("template") and (marks or {}).get(p.get("mark")))}
    # the scene's player actor: named after the character's voicetag (radish makes the actor's id from the name in
    # capitals and the game finds it by that: GERALT, CIRILLA)
    who_plays = PLAYERS.get(character, PLAYERS["geralt"])
    pk = who_plays["voicetag"].lower()
    player_actor = {pk: {"template": who_plays["template"]}}
    actor_of = {ref: extra_key(ref) for ref, _t, _g, _j in extras}
    if cast:
        actor_of = {who: key for who, (key, _a, _t) in cast.items()}
    late = [actor_of[ref] for ref, _t, _g, joins in extras if joins == "line"]
    # each actor's body: the gestures it can play (talking.dialogue_anims)
    template_of = {pk: who_plays["template"], "npc": npc_template,
                   **{actor_of[ref]: t for ref, t, _g, _j in extras if ref in actor_of}}
    if cast:
        template_of.update({key: t for _w, (key, _a, t) in cast.items()})
    bodies = {}
    shot_repo, shot_assets = {}, {}                     # the cameras lines chose (SHOTS)

    def anims_of(actor):
        if actor not in bodies:
            t = template_of.get(actor)
            try:
                from .talking import dialogue_anims
                bodies[actor] = dialogue_anims(t) if t else None
            except Exception:                           # noqa: BLE001 - nothing to tell by: as chosen
                bodies[actor] = None
        return bodies[actor]
    ends = outcomes(lines)
    code = codes(ends)
    monologue = npc_template is None and not cast and not extras
    sections = {}
    storyboard = {"defaults": {"camera": {pk: "player_cam", "npc": "npc_cam"}}}
    anims, mimics = {}, {}
    pose_repo, pose_assets = {}, {}                     # the poses taken (actor.poses)
    # where the player stands, when not where the game's shots expect them (stands): the shots follow
    player_at = next((c["pos"] for r, c in (stands or {}).items() if is_player(r)), None)
    drops = {}                                          # actor -> how much lower its pose is (cameras follow)
    count = {"cue": 0, "choice": 0}

    def actor_key(ref):
        """'player' / 'npc' / an extra's reference -> the scene's actor."""
        if ref is None:
            return None
        return pk if is_player(ref) else "npc" if ref == "npc" else actor_of.get(ref)

    def camera_of(key, who):
        """The camera asset of a line's camera `key` - one of SHOTS (on the speaker) or 'cam:<name>' (one of the
        talk's own `cams`) - or None."""
        if not key:
            return None
        if key.startswith("cam:"):
            name = key[4:]
            c = (cams or {}).get(name)
            if not c:
                return None
            asset = f"own_{re.sub(r'[^a-z0-9_]', '_', name.lower())}"
            shot_repo[f"cj_{asset}"] = own_camera(c)
            shot_assets[asset] = {"repo": f"cj_{asset}"}
            return asset
        if who not in (pk, "npc"):
            return None
        shot = shot_camera(who == pk, key, drops.get(who, 0.0), player_at)
        if not shot:
            return None
        name, definition = shot
        shot_repo[name] = definition
        shot_assets[name] = {"repo": name}
        return name

    def pose_event(who, key):
        """actor.pose for `who` taking pose `key` (None: the body has no such idle, or the player in a gameplay
        scene - it takes no events)."""
        if gameplay and who == pk:
            return None
        anim = pose_anim(key, anims_of(who))
        if not anim:
            return None
        repo = f"pose_{anim}"
        pose_repo[repo] = dict(pose_state(anim), idle_anim=anim)
        asset = f"{who.replace(' ', '_')}_{key}"
        pose_assets[asset] = {"actor": who, "repo": repo}
        return {"actor.pose": [0.0, asset]}

    def say(x, section, body):
        who = pk if is_player(x.get("who")) else actor_of.get(
            x.get("who"), next(iter(actor_of.values())) if cast else "npc")
        text = str(x.get("text", "")).strip() or "..."
        hold = float(x.get("length") or 0)           # the line's own length: at least this long (seconds)
        if x.get("voice"):
            # the game's own line: its voice and lip sync play; the duration keeps gestures in time
            text = f"[{float(x.get('dur') or 2.0):.3f}]{int(x['voice']):010d}|{text}"
        elif own_ids is not None and mouth and not x.get("voice_pack") and not x.get("thought"):
            # no voice: silence as long as the line and a mouth that moves to the text (the build times it)
            sid = next(own_ids)
            speech.append({"id": sid, "text": text, "source": None, "lang": "en"})
            text = f"[@{sid}]{sid:010d}|{text}"
        elif x.get("voice_pack") and own_ids is not None:
            from . import contentpacks
            v = contentpacks.voice(x["voice_pack"])
            if v is None:
                raise ValueError(f"Voice line {x['voice_pack']} is in no loaded content pack")
            sid = next(own_ids)
            from .speech import seconds
            dur = seconds(v["file"]) or float(x.get("dur") or 2.0)
            speech.append({"id": sid, "text": text, "source": v["file"], "lang": v.get("lang", "en")})
            text = f"[{dur:.3f}]{sid:010d}|{text}"
        events = []
        have = anims_of(who)
        anim = gesture_anim(x["gesture"], have) if x.get("gesture") in GESTURE else None
        if x.get("anim") and (have is None or x["anim"] in have):     # any of the game's scene animations
            anim = x["anim"]
        repo = anim and anim_repo_id(anim)
        if repo:
            asset = f"{who.replace(' ', '_')}_{x['gesture']}" if not x.get("anim") else \
                f"{who.replace(' ', '_')}_{repo}"
            anims[asset] = {"actor": who, "repo": repo, "blendin": 0.4, "blendout": 0.6}
            events.append({"actor.anim": [0.1, asset]})
        if x.get("mood") in MOOD and have != set():     # (no dialogue animations: an animal - no face either)
            asset = f"{who}_{x['mood']}"
            mimics[asset] = {"actor": who, "repo": x["mood"]}
            events.append({"actor.mimic": [0.0, asset]})
        if x.get("pose") in POSE:                       # the speaker changes into another pose
            ev = pose_event(who, x["pose"])
            if ev:
                events.append(ev)
        target = actor_key(x.get("look"))
        if target and target != who and not (gameplay and who == pk):     # the speaker looks at someone
            events.append({"actor.lookat": [0.0, who, target]})
        if who in late:
            events.append({"actor.show": [0.0, who]})         # comes in (every line of theirs: any branch)
        events += line_events(x, who, marks, prop_key)
        to = camera_of(x.get("camera"), who)
        start = camera_of(x.get("glide"), who) if to else None
        if to and start and start != to:                # the camera moves from one to the other through the line
            events += [{"cam.blend.start": [0.0, start, "smooth"]}, {"cam.blend.end": [1.0, to, "smooth"]}]
        elif to:                                        # this line's own camera
            events.append({"cam": [0.0, to]})
        if events:
            count["cue"] += 1
            cue = f"cue_{count['cue']}"
            body.append({"CUE": cue})
            storyboard.setdefault(section, {})[cue] = events
        body.append({who: text})
        if hold > 0:
            # the line's own length: the scene holds after it for the rest (the game goes on when the voice ends)
            if text.startswith("[@"):                # a mouth to the text: its length known at the build
                body.append({"PAUSE": f"@rest {text[2:text.index(']')]} {hold:.3f}"})
            elif text.startswith("["):                  # a voice: its length known now
                said = float(text[1:text.index("]")])
                if hold - said > 0.05:
                    body.append({"PAUSE": round(hold - said, 3)})

    def end_of(e):
        if exits is not None:
            return exits[e]
        return f"script_end_{socket(e)}" if len(ends) > 1 and e in code else "section_exit"

    def scripts(calls, then):
        """Script calls as a chain of script sections leading to `then`; returns the first (or `then`)."""
        for k in range(len(calls) - 1, -1, -1):
            count["script"] = count.get("script", 0) + 1
            name = f"script_do_{count['script']}"
            sections[name] = [{"SCRIPT": calls[k]}, {"NEXT": then}]
            then = name
        return then

    def effects(c):
        """What an answer does after its lines (the pay / axii icons do theirs themselves)."""
        calls = []
        for key, sign in (("give", -1), ("receive", 1)):
            d = c.get(key) or {}
            if d.get("item"):
                own = own_item(d["item"])               # the quest's own item: by name
                calls.append({"function": "CjSceneItemN", "parameter": [
                    {"itemName": f"cname_{own}"}, {"count": sign * int(d.get("count", 1))}]} if own else
                    {"function": "CjSceneItem", "parameter": [
                        {"item": str(d["item"])}, {"count": sign * int(d.get("count", 1))}]})
            if key == "receive" and (d.get("money") or d.get("xp")):
                calls.append({"function": "CjSceneGive", "parameter": [
                    {"money": int(d.get("money", 0))}, {"xp": int(d.get("xp", 0))}]})
        if c.get("shop") and npc_tag:
            # trade: the game's shop window with the NPC's goods (the game's own scene function, as its merchants)
            calls.append({"function": "ShowMeGoods", "parameter": [{"merchantTag": f"cname_{npc_tag}"}]})
        return calls

    def axii_cast(section, lines):
        """An Axii answer casts it before its lines, as the game's scenes do (q702_18, q704_03b; Maxim 06.10.: "da
        fehlt das wirken"): the player's sign gesture, the glow of the cast, the dazed look on the one talked to."""
        events = []
        repo = anim_repo_id(AXII_CAST_ANIM)
        if repo and anims_of(pk) != set():
            asset = f"{pk}_axii_cast"
            anims[asset] = {"actor": pk, "repo": repo, "blendin": 0.3, "blendout": 0.5}
            events.append({"actor.anim": [0.05, asset]})
        events.append({"actor.effect.start": [0.35, pk, "axii_cast_dialog"]})
        # the one it is cast on: who answers it (else the one talked to) - an actor of this scene
        ref = next((ln.get("who") for ln in lines if isinstance(ln, dict) and ln.get("who") and
                    not is_player(ln.get("who"))), "npc")
        target = actor_of.get(ref) or (actor_key(ref) if not cast and npc_template is not None else None)
        if target and target != pk:
            events.append({"actor.effect.start": [0.6, target, "axii_confusion"]})
        count["cue"] += 1
        cue = f"cue_{count['cue']}"
        sections.setdefault(section, []).extend([{"CUE": cue}, {"PAUSE": AXII_CAST_SECONDS}])
        storyboard.setdefault(section, {})[cue] = events

    def fill(section, ls, end, pre=(), back=None):
        """The lines into `section`; it goes on to a choice (their own sections) or, when the lines are over, to
        `end` (a section name). `pre`: script calls to run before either (an answer's effects). `back`: the choice
        a 'back to the choices' goes to (inside an answer)."""
        body = sections.setdefault(section, [])
        for k0, x in enumerate(ls):
            if any(s in x for s in SPLITS):
                # what follows a choice / if / random: where its ways that go on join (none: the list's end)
                join = end
                if k0 + 1 < len(ls):
                    count["join"] = count.get("join", 0) + 1
                    join = f"section_join_{count['join']}"
                    fill(join, ls[k0 + 1:], end, back=back)
            if "script" in x:
                # a script among the lines (the game's AddFact_S ...): its own section, then on with the lines
                count["after_script"] = count.get("after_script", 0) + 1
                after = f"section_after_script_{count['after_script']}"
                body.append({"NEXT": scripts([x["script"]], after)})
                section, body = after, sections.setdefault(after, [])
                continue
            if "random" in x:
                # one of the ways, by chance: each its own section and its own way on
                count["rand"] = count.get("rand", 0) + 1
                n = count["rand"]
                names = []
                for k, br in enumerate(x["random"] or [], 1):
                    sec = f"section_random_{n}_{k}"
                    be = br.get("end")
                    target = back if be in ("back", "up") and back else \
                        end_of(be) if be not in (None, "back", "up", "on") else join
                    fill(sec, br.get("lines") or [], target, back=back)
                    names.append(sec)
                pick = f"section_random_{n}"
                sections[pick] = [{"RANDOM": names}]
                body.append({"NEXT": scripts(list(pre), pick)})
                return                                  # (what follows it: in its join section)
            if "if" in x:
                # lines that depend on a fact: a conditional link to one of two sections, each with its own way on
                count["if"] = count.get("if", 0) + 1
                n = count["if"]
                c = x["if"] or {}
                names = []
                for side, tag in (("then", "yes"), ("else", "no")):
                    br = x.get(side) or {}
                    sec = f"section_if_{n}_{tag}"
                    be = br.get("end")
                    target = back if be in ("back", "up") and back else \
                        end_of(be) if be not in (None, "back", "up", "on") else join
                    fill(sec, br.get("lines") or [], target, back=back)
                    names.append(sec)
                cond = {"condition": [str(c.get("fact", "")), str(c.get("op", ">=")), int(c.get("value", 1))],
                        "on_true": names[0], "on_false": names[1]}
                body.append({"NEXT": scripts(list(pre), cond)})
                return                                  # (what follows it: in its join section)
            alts = [t for t in x.get("alt") or [] if str(t).strip()] if "choice" not in x else []
            if alts:
                # one of them, at random; the lines after it go on in a section of their own
                count["var"] = count.get("var", 0) + 1
                n = count["var"]
                after = f"section_after_{n}"
                names = []
                for k, text in enumerate([x.get("text", "")] + alts):
                    vs = f"section_variant_{n}_{k + 1}"
                    variant = dict(x, text=text) if k else x
                    if k:
                        for key in ("voice", "voice_pack", "dur", "alt"):
                            variant.pop(key, None)
                    vb = sections.setdefault(vs, [])
                    say(variant, vs, vb)
                    vb.append({"NEXT": after})
                    names.append(vs)
                body.append({"RANDOM": names})
                section, body = after, sections.setdefault(after, [])
                continue
            if "choice" not in x:
                say(x, section, body)
                continue
            count["choice"] += 1
            n = count["choice"]
            # (a scene with poses: not a pure 'section_choice' - it carries the poses before the choice)
            cs = f"section_ask_{n}" if base_poses else f"section_choice_{n}"
            options, checks, answers = [], [], []
            # options another one waits for ('after all'): choosing them sets a fact; an option with an id (some
            # 'After option' in the quest asks for it) sets its own
            waited = {id(o) for c in x["choice"] for o in after_others(x["choice"], c)}
            for k, c in enumerate(x["choice"]):
                a = f"section_answer_{n}_{k + 1}"
                text = str(c.get("text", "")).strip() or "..."
                act = "pay" if c.get("pay") else "axii" if c.get("axii") else "shop" if c.get("shop") else \
                    c.get("icon")                   # shop, exit ...
                opt = {"choice": [text, a] + ([act] + ([int(c["pay"])] if act == "pay" else []) if act else [])}
                if c.get("once"):
                    opt["single_use"] = True
                if c.get("emphasize"):
                    opt["emphasize"] = True
                conds = []
                for cond in conditions(c):                  # all of them
                    if cond == AFTER_ALL:
                        conds += [[chosen_fact(fact, n, j + 1), "=", 1] for j, o in enumerate(x["choice"])
                                  if o in after_others(x["choice"], c)]
                    elif isinstance(cond, str) and cond.startswith("@"):
                        conds.append([option_fact(qid, cond[1:]), "=", 1])
                    else:
                        conds += only_if_checks(cond)       # a branch taken before / a fact
                need = dict(c.get("needs") or {})
                if (c.get("give") or {}).get("item"):   # handing over needs having it
                    need.setdefault("item", c["give"]["item"])
                    need.setdefault("count", c["give"].get("count", 1))
                if isinstance(need.get("item"), list) or need.get("none"):
                    # one of these items (a pass, a safe conduct, fake papers) - or none of them
                    check = f"{fact}_n{n}_{k + 1}"
                    items = need["item"] if isinstance(need.get("item"), list) else [need.get("item") or ""]
                    checks.append({"function": "CjSceneHas", "parameter": [
                        {"fact": check}, {"items": ";".join(str(i) for i in items if i)},
                        {"count": int(need.get("count", 1))}, {"none": bool(need.get("none"))}]})
                    conds.append([check, "=", 1])
                elif need.get("item") or need.get("money"):
                    check = f"{fact}_n{n}_{k + 1}"
                    own = own_item(need.get("item"))
                    checks.append({"function": "CjSceneCheckN", "parameter": [
                        {"fact": check}, {"itemName": f"cname_{own}"}, {"count": int(need.get("count", 1))}]} if own
                        else {"function": "CjSceneCheck", "parameter": [
                            {"fact": check}, {"item": str(need.get("item", ""))}, {"count": int(need.get("count", 1))},
                            {"money": int(need.get("money", 0))}]})
                    conds.append([check, "=", 1])
                if len(conds) > 1:                      # all of them: one fact says so (a choice has one condition)
                    check = f"{fact}_a{n}_{k + 1}"
                    checks.append({"function": "CjSceneAll", "parameter": [
                        {"fact": check}, {"checks": ";".join(f"{f},{op},{v}" for f, op, v in conds)}]})
                    conds = [[check, "=", 1]]
                if conds:
                    opt["condition"] = conds[0]
                options.append(opt if len(opt) > 1 else opt["choice"])
                # (a monologue - examining something, no one to answer: its options are chosen, not said)
                if says_choice(c) and not monologue:
                    say(dict(c, who=PLAYER, text=text, gesture=None, mood=None), a, sections.setdefault(a, []))
                e = c.get("end", "continue")
                answers.append((a, c, e))
            # back to the choices: through its checks again (an option waiting for others may show now)
            entry = scripts(checks, cs)
            for k, (a, c, e) in enumerate(answers):
                target = entry if e == "back" else (back or end) if e == "up" else join if e == "on" else end_of(e)
                mark = [{"function": "CjSetFact", "parameter": [{"fact": chosen_fact(fact, n, k + 1)}, {"value": 1}]}
                        ] if id(c) in waited else []
                if c.get("id"):
                    mark.append({"function": "CjSetFact", "parameter": [{"fact": option_fact(qid, c["id"])},
                                                                         {"value": 1}]})
                if c.get("axii") and not gameplay:
                    axii_cast(a, c.get("lines") or [])
                fill(a, c.get("lines") or [], target, mark + effects(c), back=entry)
            if x.get("time"):                           # a timed choice (the game's countdown)
                options.append({"time_limit": float(x["time"])})
            sections[cs] = [{"CHOICE": options}]
            body.append({"NEXT": scripts(list(pre), entry)})
            return                                      # (what follows it: in its join section)
        body.append({"NEXT": scripts(list(pre), end)})

    first = []                                          # at the start: who is hidden, who looks at whom
    if late:                                            # who comes in later is not there at first
        first += [{"actor.hide": [0.0, who]} for who in late]
    shown_later = {n for y in walk(lines) for n in y.get("show") or []}
    for n, key in prop_key.items():                     # the talk's things on their spots
        m = marks[props[n]["mark"]]
        first += [{"prop.placement": [0.0, key, [round(float(v), 3) for v in m["pos"]],
                                      [0.0, 0.0, round(float(m.get("yaw", 0.0)) % 360, 2)]]},
                  {"prop.hide" if n in shown_later else "prop.show": [0.0, key]}]
    base_poses = []                                     # each section starts with these (a pose holds per section)
    for ref, key in (poses or {}).items():
        who = actor_key(ref)
        ev = pose_event(who, key) if who else None
        if ev:
            base_poses.append(ev)
    if not monologue and not cast:                      # the player and the person look at each other
        first += ([] if gameplay else [{"actor.lookat": [0.0, pk, "npc"]}]) + [{"actor.lookat": [0.0, "npc", pk]}]
    for ev in base_poses:                               # how low each posed person is (their cameras follow)
        asset = ev["actor.pose"][1]
        drops[pose_assets[asset]["actor"]] = pose_drop(pose_repo[pose_assets[asset]["repo"]]["idle_anim"])
    own_default = {}                                    # actor -> the asset of their own default camera
    for ref, key in (cam_defaults or {}).items():
        who, asset = actor_key(ref), camera_of(key, None)
        if who and asset:
            own_default[who] = asset
    fill("section_start", lines, end_of("continue"))
    for name, sec in list(sections.items()):            # every section with lines or a choice: the poses again
        if name == "section_start" or not base_poses or not sec or not isinstance(sec[0], dict):
            continue
        k0 = 1 if "CUE" in sec[0] else 0
        head = sec[k0] if k0 < len(sec) else None
        if name.startswith("section_ask_") and isinstance(head, dict) and "CHOICE" in head:
            cue = f"cue_pose_{len(storyboard.get(name, {})) + 1}"
            sec[0:0] = [{"CUE": cue}, {"PAUSE": 0.3}]       # (a pose at 0.0 did nothing in the game: a moment in)
            later = [{"actor.pose": [0.1, ev["actor.pose"][1]]} for ev in base_poses]
            # the game stands the posed people up while a choice is open (01.10., Keira knelt again after it): the
            # player close up meanwhile - the others out of the picture
            close = None if own_default.get(pk) else shot_camera(True, "closeup", 0.0, player_at)
            if close:
                shot_repo[close[0]] = close[1]
                shot_assets[close[0]] = {"repo": close[0]}
            storyboard.setdefault(name, {})[cue] = later + [{"cam": [0.0, close[0] if close else "player_cam"]}]
            continue
        if not isinstance(head, dict) or next(iter(head)) in ("NEXT", "SCRIPT", "OUTPUT", "PAUSE", "CHOICE"):
            continue
        if k0:
            cue = sec[0]["CUE"]
            storyboard.setdefault(name, {})[cue] = list(base_poses) + storyboard.get(name, {}).get(cue, [])
        else:
            cue = f"cue_pose_{len(storyboard.get(name, {})) + 1}"
            sec.insert(0, {"CUE": cue})
            storyboard.setdefault(name, {})[cue] = list(base_poses)
    start_poses = [{"actor.pose": [0.1, ev["actor.pose"][1]]} for ev in base_poses]
    if first or start_poses:
        # the scene opens with a short pause of its own carrying the start events (a cue needs an element after
        # it; a pose at 0.0 with the first line did nothing in the game)
        sections["section_start"][0:0] = [{"CUE": "cue_start"}, {"PAUSE": 0.4}]   # (the first line's mouth: 07.10.)
        storyboard.setdefault("section_start", {})["cue_start"] = first + start_poses
    if exits is not None:
        # a swap: its own actors, the exits are the caller's (the game scene's outputs)
        actors = dict({pk: {"repo": pk}}, **{key: asset for key, asset, _t in cast.values()})
        main = cast["npc"][0] if "npc" in cast else next((k for k in actors if k != pk), None)
        others = [k for k in actors if k not in (pk, main)]
        side_assets, side_defaults, side_repo = side_cameras(others)
        assets = {"actors": actors, "cameras": dict({f"{k.replace(' ', '_')}_cam": {
            "repo": "1_2_medium" if k == pk else "2_1_medium"} for k in actors if k not in others},
            **side_assets)}
        storyboard["defaults"] = {"camera": dict({k: f"{k.replace(' ', '_')}_cam" for k in actors
                                                  if k not in others}, **side_defaults)}
        if anims:
            assets["animations"] = anims
        if mimics:
            assets["mimics"] = mimics
        scene = {"repository": dict({"actors": dict(player_actor, **{key: {"template": t} for key, _a, t in
                                                                     cast.values() if t})},
                                    **({"cameras": side_repo} if side_repo else {})),
                 "production": {"settings": {"sceneid": scene_id, "strings-idspace": idspace, "strings-idstart": idstart},
                                "placement": "PLAYER", "assets": assets},
                 "storyboard": storyboard,
                 "dialogScript": dict({"player": pk, "actors": list(actors)}, **sections)}
        return with_soundbanks(scene), ends
    if len(ends) > 1:
        for e in sorted(ends):
            sections[f"script_end_{socket(e)}"] = [
                {"SCRIPT": {"function": "CjSetFact", "parameter": [{"fact": fact}, {"value": code[e]}]}},
                {"NEXT": "section_exit"}]
    # the scene's output must be named as the quest block's out-socket (radish does not check it): radish's quest
    # blocks go on on "Out"; a scene output without a name is "Output" to the game (vanilla, measured 30.09.) - the
    # quest then never went on after the talk
    sections["section_exit"] = [{"OUTPUT": "Out"}, "EXIT"]
    alone = npc_template is None                        # the player alone (their comments on clues)
    assets = {"actors": dict({pk: {"repo": pk}},
                             **({} if alone else {"npc": {"repo": "npc", "tags": [npc_tag], "by_voicetag": False}}),
                             **{actor_of[ref]: {"repo": actor_of[ref], "tags": [tag], "by_voicetag": False}
                                for ref, _t, tag, _j in extras}),
              "cameras": {"player_cam": {"repo": "1_2_medium"}, "npc_cam": {"repo": "2_1_medium"}}}
    side_assets, side_defaults, side_repo = side_cameras([actor_of[ref] for ref, _t, _g, _j in extras])
    assets["cameras"].update(side_assets)
    for who, cam, side in ((pk, "player_cam", True), ("npc", "npc_cam", False)):
        if own_default.get(who):                        # one of the talk's own cameras is theirs
            assets["cameras"][cam] = {"repo": f"cj_{own_default[who]}"}
        elif drops.get(who) or player_at:               # a posed person: their default shot lower; the player
            low = shot_camera(side, "medium", drops.get(who, 0.0), player_at)      # elsewhere: turned to them
            if low:
                shot_repo[low[0]] = low[1]
                assets["cameras"][cam] = {"repo": low[0]}
    assets["cameras"].update(shot_assets)
    side_repo = dict(side_repo, **shot_repo)
    storyboard["defaults"]["camera"].update(side_defaults)
    if stands and not alone:                            # where they stand (radish rot: [0, 0, yaw])
        # the person turned to the player where they stand (as the game's dialogsets do: 02.10. Keira kept looking
        # her own way and the shots saw her from behind)
        turn = 0.0
        if player_at:
            import math
            turn = round(math.degrees(math.atan2(-float(player_at[0]), float(player_at[1]))) % 360, 2)
        spots = {"npc": [[0.0, 0.0, 0.0], [0.0, 0.0, turn]]}
        for ref, c in stands.items():
            who = actor_key(ref)
            if who and who != "npc":
                spots[who] = [[round(float(v), 3) for v in c["pos"]], [0.0, 0.0, round(float(c.get("yaw", 0)) % 360, 2)]]
        storyboard["defaults"]["placement"] = spots
    if anims:
        assets["animations"] = anims
    if mimics:
        assets["mimics"] = mimics
    if pose_assets:
        assets["actor.poses"] = pose_assets
    if prop_key:
        assets["props"] = {key: {"repo": key} for key in prop_key.values()}
    scene = {
        "repository": dict({"actors": dict(player_actor, **({} if alone else {"npc": {"template": npc_template}}),
                                           **{actor_of[ref]: {"template": t} for ref, t, _g, _j in extras})},
                           **({"cameras": side_repo} if side_repo else {}),
                           **({"actor.poses": pose_repo} if pose_repo else {}),
                           **({"props": {key: {"template": props[n]["template"]} for n, key in prop_key.items()}}
                              if prop_key else {})),
        "production": {"settings": {"sceneid": scene_id, "strings-idspace": idspace, "strings-idstart": idstart},
                       "placement": placement, "assets": assets},
        "storyboard": storyboard,
        "dialogScript": dict({"player": pk, "actors": [pk] + ([] if alone else ["npc"]) +
                              [actor_of[r] for r, *_ in extras]},
                             **({"props": list(prop_key.values())} if prop_key else {}), **sections)}
    return with_soundbanks(scene), ends
