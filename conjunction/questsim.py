"""A quest's logic run without the game: the blocks quest.generate makes (radish's structure) played through - facts
set and waited on, ways that run side by side, random picks, outcomes - with a stand-in player who does what a step
asks (walks into the area, waits, talks and takes the first way on, has the item). For tests of the quest logic
(does a quest end once? does a lane run beside the story? does 'at random' take one way?) where the game cannot run.

    sim = QuestSim(struct)          # quest.generate(project)[0]
    sim.start()
    sim.play()                      # the player does everything, until the quest ends or nothing is left to do
    sim.outcomes                    # ["Success"] ...
    sim.set_fact("actor_x_was_killed", 1)   # the world does something; ways waiting on it go on

What the game does inside a scene (a talk's answer setting its fact) the player does when he 'talks': the answer
that goes on (or the one `answers` names for that talk block).
"""
import operator
import random

OPS = {"=": operator.eq, "!=": operator.ne, ">=": operator.ge, ">": operator.gt, "<=": operator.le, "<": operator.lt}
PASS = ("start", "objective", "journal", "mappin", "phaseobjectives", "spawn", "spawnsets", "despawn", "changelayers",
        "reward", "teleport", "changeworld", "settime", "shifttime", "pausetime", "unpausetime", "script")
FACT_PARAMS = ("fact", "factName", "factId", "factID")      # a game action's parameter that names a fact
PLAYER = ("interaction", "scene")                       # a talk: the player starts it and chooses


class QuestSim:
    def __init__(self, struct, seed=0, answers=None, has_items=True, cuts=None):
        self.s, self.rng = struct, random.Random(seed)
        self.cuts = dict(cuts or {})                    # {stand-in fact block: [blocks it cuts]} (project.minigames)
        # the world the game's conditions look at: areas the player is in, journal states ({file|obj: JS_...}), the
        # hour, who is there, a fight
        self.inside, self.journal, self.hour, self.present, self.combat = set(), {}, 12, set(), False
        self.answers = dict(answers or {})              # {talk block: the fact value its answer sets}
        self.has_items = has_items
        self.facts, self.waiting, self.log, self.outcomes, self.picks = {}, [], [], [], {}
        self.arrived = set()                            # CjArrive blocks passed (a patrol loops once)

    # --- the world
    def fact(self, name):
        return self.facts.get(name, 0)

    def set_fact(self, name, value):
        self.facts[name] = value
        self._settle()

    def _test(self, cond):
        fact, op, value = cond
        return OPS[op](self.fact(str(fact)), value)

    def holds(self, c):
        """A condition of the game's (quest.conditions) in this world: True / False - None: the player does it (an
        area stepped into, a time passed ...)."""
        if "factdb" in c:
            return self._test(c["factdb"])
        if "inside" in c:                               # (someone else: "<tag>@<area>")
            return (f"{c['who']}@{c['inside']}" if c.get("who") else c["inside"]) in self.inside
        if "outside" in c:                              # (an If's 'no'; 'left' - the way out of an area: the player)
            return c["outside"] not in self.inside
        if "journal" in c:
            j = c["journal"]
            got = self.journal.get(f"{j['file']}|{j['obj']}", "JS_Inactive") == c.get("status")
            return got != bool(c.get("inverted"))
        if "period" in c:
            fr, to = (int(x) // 3600 for x in c["period"])
            return fr <= self.hour < to if fr <= to else (self.hour >= fr or self.hour < to)
        if "present" in c:
            return all(t in self.present for t in c["present"])
        if "combat" in c:
            return self.combat == bool(c["combat"])
        if "all" in c:
            got = [self.holds(x) for x in c["all"]]
            return None if None in got else all(got)
        if "any" in c:
            got = [self.holds(x) for x in c["any"]]
            return True if True in got else None if None in got else False
        if "nor" in c:
            got = [self.holds(x) for x in c["nor"]]
            return None if None in got else not any(got)
        return None

    def world(self, **kv):
        """The world changes (inside={...}, journal={...}, hour=22, present={...}, combat=True): waits on it go on."""
        for k, v in kv.items():
            setattr(self, k, v)
        self._settle()

    # --- running blocks
    def start(self):
        self._go("start")
        self._settle()

    def _targets(self, b, socket=None):
        out = []
        for t in b.get(f"next.{socket}" if socket else "next") or []:
            out.append(next(iter(t.items())) if isinstance(t, dict) else (t, None))
        return out

    def _go(self, name, in_socket=None):
        b = self.s.get(name)
        if b is None:
            raise KeyError(f"A way leads to '{name}', which does not exist")
        self.log.append(name)
        kind = name.split(".")[0]
        if kind == "end":
            return
        if kind == "addfact":
            fact, value = b["value"]
            self.facts[fact] = self.fact(fact) + value
            for x in self.cuts.get(name, []):           # a cut control block: what it cuts stops waiting
                while x in self.waiting:
                    self.waiting.remove(x)
            self._on(b)
        elif kind == "questoutcome":
            self.outcomes.append(in_socket or "?")
            self._on(b)
        elif kind == "randomize":
            socks = [k[5:] for k in b if k.startswith("next.")]
            pick = self.rng.choice(socks) if socks else None
            if name.startswith(("randomize.gwent_", "randomize.fistfight_")):   # a minigame: the player wins it
                pick = self.answers.get(name, "Success")
            self.picks[name] = pick
            self._on(b, pick)
        elif kind == "waituntil" or kind in PLAYER:
            self.waiting.append(name)
        elif kind in PASS:
            fn = b.get("function", "") if kind == "script" else ""
            if fn == "CjRunRetired":                    # a newer run never comes in a stand-in play
                self.waiting.append(name)
                return
            if fn.startswith("CjHasItemsNow"):           # counted once: 1 has it, 2 not
                fact = next((p["fact"] for p in b.get("parameter") or [] if "fact" in p), "")
                self.facts[str(fact)] = 1 if self.has_items else 2
            if fn == "RemoveFactQuest":                 # (a fact the game removes: 0 again)
                fact = next((p["factId"] for p in b.get("parameter") or [] if "factId" in p), "")
                self.facts[str(fact).replace("cname_", "", 1)] = 0
            if fn == "CjArrive":
                # a walk by phases: he arrives (the point counted, as the game does); a patrol's loop goes round once
                if name in self.arrived:
                    return
                self.arrived.add(name)
                prm = {k: v for p in b.get("parameter") or [] for k, v in p.items()}
                if prm.get("progress"):
                    self.facts[str(prm["progress"])] = prm.get("point", 1)
            if fn.startswith(("CjHasItems", "CjEquipped")) and self.has_items or fn in ("CjGoAt", "CjAwayFrom", "CjNearTo", "CjLookAt"):
                for p in b.get("parameter") or []:
                    if "fact" in p:
                        self.facts[p["fact"]] = 1           # the player has what the step asks for / gets there
            elif fn.startswith("CjG_"):
                # a game action with a fact (ModifyFactValueQuest, ...): as if it set it - to its value, else 1
                fact = next((p[k] for p in b.get("parameter") or [] for k in FACT_PARAMS if k in p), None)
                value = next((p["value"] for p in b.get("parameter") or [] if "value" in p), 1)
                if fact:
                    self.facts[str(fact)] = self.fact(str(fact)) + (value if isinstance(value, (int, float)) else 1)
            self._on(b)
        else:
            raise ValueError(f"The simulation does not know blocks like '{name}'")

    def _on(self, b, socket=None):
        for target, sock in self._targets(b, socket):
            self._go(target, sock)

    def _settle(self):
        """Ways waiting on facts go on while one of them can."""
        moved = True
        while moved:
            moved = False
            for name in list(self.waiting):
                b = self.s[name]
                if not name.startswith("waituntil."):
                    continue
                if "conditions" not in b and self.holds(b):
                    self.waiting.remove(name)
                    self._on(b)
                    moved = True
                elif "conditions" in b:
                    for sock, c in b["conditions"].items():
                        if self.holds(c):
                            self.waiting.remove(name)
                            self._on(b, sock)
                            moved = True
                            break

    # --- the player
    def step_player(self):
        """The player does the first thing a way waits for (an area, a time, a talk). False: nothing to do."""
        for name in list(self.waiting):
            b = self.s[name]
            kind = name.split(".")[0]
            if kind in PLAYER:
                self.waiting.remove(name)
                self._talk(name, b)
            elif "conditions" not in b and self.holds(b) is None:
                self.waiting.remove(name)                   # an area, a time, something examined, looted, used
                self._on(b)
            elif name.startswith("waituntil.s") and "factdb" in b and str(b["factdb"][0]).endswith("_was_killed"):
                self.facts[b["factdb"][0]] = 1              # a step's enemy: the player kills it (never someone who
                self._settle()                              # must survive: those watch from the start)
            elif name.startswith("waituntil.s") and "factdb" in b and str(b["factdb"][0]).endswith("_taken"):
                self.facts[b["factdb"][0]] = 1              # a notice: the player takes it at the board
            else:
                continue
            self._settle()
            return True
        return False

    def _talk(self, name, b):
        """A talk ends: the answer that goes on (a quest's talk sets its choice fact in the scene), then on."""
        for target, _sock in self._targets(b):
            conds = (self.s.get(target) or {}).get("conditions") or {}
            # the answer named for this talk, else the one that goes on, else the first way out
            want = self.answers.get(name) or ("continue" if "continue" in conds else next(iter(conds), None))
            c = conds.get(want) or {}
            if "factdb" in c:
                fact, _op, value = c["factdb"]
                self.facts[fact] = value
        self._on(b)

    def play(self, limit=500):
        """The player does everything until the quest has an outcome or nothing is left to do."""
        for _ in range(limit):
            if self.outcomes or not self.step_player():
                break
        return self.outcomes


QUIET = ("waituntil.forever", "waituntil.setup_rest", "waituntil.alive_", "waituntil.ends_game", "waituntil.end_",
         "waituntil.retired")


def playthrough(struct, q, qid, journals=None):
    """The quest played through by the stand-in player: (True, what happened) or (False, where a way stops and why -
    named by the step's line in the journal where it has one). A hook's game fact (after / inside a game quest) comes
    as if the game had set it."""
    import re
    sim = QuestSim(struct)
    sim.start()
    if (q.get("after_game") or {}).get("fact"):
        sim.set_fact(str(q["after_game"]["fact"]), 1)
    if (q.get("inside_game") or {}).get("phase"):
        sim.set_fact(f"{qid}_inside", 1)
    if q.get("after"):
        sim.set_fact(f"{str(q['after']).lower()}_done", 1)
    gq = q.get("game_quest") or {}
    if gq.get("file") and gq.get("obj") is not None:    # with / after a game quest: as if the game had got there
        sim.world(journal=dict(sim.journal, **{f"{gq['file']}|{int(gq['obj'])}": "JS_Success"}))
    sim.play()
    if sim.outcomes:
        return True, "played through to the end: " + ("success" if sim.outcomes[0] == "Success" else "it fails")
    stuck = [w for w in sim.waiting if not w.startswith(QUIET)]
    if not stuck:
        return True, "played through (the quest has no end of its own)"
    name = stuck[0]
    captions = {}
    for ob in (((journals or {}).get("quests") or {}).get(qid) or {}).get("instructions", {}).get("main", []):
        for oid, o in ob.items():
            captions[oid] = o.get("caption")
    step = re.match(r"waituntil\.(s\d+)", name)
    where = f"'{captions[step.group(1)]}'" if step and captions.get(step.group(1)) else "a step"
    b = struct.get(name) or {}
    if "factdb" in b:
        fact = b["factdb"][0]
        set_here = any(x.get("value", [None])[0] == fact for k, x in struct.items() if k.startswith("addfact.")) or             any(p.get(n) == fact for k, x in struct.items() if k.startswith("script.")
                for p in x.get("parameter") or [] for n in FACT_PARAMS)
        return False, (f"{where} waits for the fact '{fact}'" +
                       ("" if set_here else " - nothing in this quest sets it (one of the game's?)"))
    return False, f"{where} waits - the stand-in player could not go on ({name})"
