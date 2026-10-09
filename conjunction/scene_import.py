"""A game scene's talks as conjunction dialogues (for a swap: start from the game's own words - change a line, add an
answer - instead of from nothing). Per input of the scene: its lines with their voices (the game's own recordings
play), its choices with their answers, where each way ends (back to the choices, one of the scene's outputs).

    talks(f, main_of) -> {input name: (dialogue, then, None) or (None, None, why not)}

Taken too: conditions on facts in the flow (an 'if' with two ways), scripts among the lines (AddFact_S and the
like - the facts the game's quest waits for), answers shown only if a fact is so, the door icon, Axii, paying.
What the dialogue tree cannot hold is not loaded (that input starts empty, `why` says why): other conditions, scripts
with enum parameters, random sections, cutscenes and films, answers with shops or games, a way that jumps back to an
earlier line. Cameras, gestures and look-ats of the game's scene are not taken - the new scene has conjunction's own.
"""
from .cr2w_props import decode
from .scene_swap import _key

PLAIN = {"CStorySceneLine", "CStoryScenePauseElement", "CStorySceneChoice", "CStorySceneComment"}
# answer icons radish writes (test_dialogscript_choice_action.yml); what they open is a script after the answer
ICONS = {"CExitStorySceneChoiceAction": "exit", "CShopStorySceneChoiceAction": "shop",
         "CArmorerStorySceneChoiceAction": "blacksmith", "CGameCardsChoiceAction": "gwent",
         "CDiceStorySceneChoiceAction": "betting"}
OPS = {"CF_Equal": "=", "CF_NotEqual": "!=", "CF_Less": "<", "CF_LessEqual": "<=", "CF_Greater": ">",
       "CF_GreaterEqual": ">="}


class NotLoadable(Exception):
    pass


NOT = {">=": "<", "<": ">=", ">": "<=", "<=": ">", "=": "!=", "!=": "="}


def fact_check(cls_name, d):
    """[fact, op, value] of a game fact condition (its class defaults: compare equal, value 0, the sum of the fact)."""
    if cls_name not in ("CQuestFactsDBCondition", "CQuestFactsDBForbiddenCondition"):
        raise NotLoadable(f"a condition on {cls_name.replace('CQuest', '').replace('W3QuestCond_', '')}")
    if d.get("queryFact") == "QF_DoesExist" and "compareFunc" not in d and "value" not in d:
        raise NotLoadable("a 'does exist' fact check without a comparison")
    check = [d.get("factId") or "", OPS.get(d.get("compareFunc") or "CF_Equal", "="), int(d.get("value") or 0)]
    if d.get("queryFact") == "QF_DoesExist":
        # the game asks 0 or 1 (there or not): which of them pass is what the check means - 'there' or 'not there'
        import operator
        test = {">=": operator.ge, ">": operator.gt, "<=": operator.le, "<": operator.lt, "=": operator.eq,
                "!=": operator.ne}[check[1]]
        passes = {v for v in (0, 1) if test(v, check[2])}
        if passes not in ({1}, {0}):
            raise NotLoadable("a 'does exist' fact check that is always or never true")
        check = [check[0], ">=" if passes == {1} else "<", 1]
    if cls_name == "CQuestFactsDBForbiddenCondition":
        check[1] = NOT[check[1]]
    return check


def talks(f, main_of, texts=None, voices=None):
    """`main_of(input name)` -> the actor key that speaks as the talk's NPC ("npc" in the dialogue)."""
    props = {}

    def p(i):
        if i not in props:
            props[i] = decode(f, f.exports[i - 1][4])
        return props[i]

    def cls(i):
        return f.exports[i - 1][0]

    def handle(v):
        return v[1] if isinstance(v, tuple) and v and v[0] == "export" else None

    def follow(i):
        """Through link elements to what they lead to."""
        seen = set()
        while i and cls(i) == "CStorySceneLinkElement":
            if i in seen:
                raise NotLoadable("a loop of links")
            seen.add(i)
            i = handle(p(i).get("nextLinkElement"))
        return i

    def text_of(v):
        sid = v[1] if isinstance(v, tuple) and v and v[0] == "string" else None
        return sid, (texts or {}).get(sid, "") if sid else ""

    out = {}
    inputs = [(i, p(i)) for i in range(1, len(f.exports) + 1) if cls(i) == "CStorySceneInput"]
    for i, d in inputs:
        name = d.get("inputName") or "Input"
        main = main_of(name)

        def who(voicetag, main=main):
            k = _key(voicetag or "")
            return "player" if k == "geralt" else "npc" if k == main else k

        def line(e):
            sid, text = text_of(p(e).get("dialogLine"))
            x = {"who": who(p(e).get("voicetag")), "text": text or "..."}
            v = voices.line(sid) if (voices and sid) else None
            if v:
                from .voices import length
                x["voice"], x["text"] = sid, v["text"] or x["text"]
                x["dur"] = length(sid, v["dur"], x["text"])
            return x

        def script(node):
            """A scene script's call: its function and its parameters (a property list after its own)."""
            import struct
            chunk = bytes(f.exports[node - 1][4])
            props = f.props(chunk)
            k = (props[-1][2] + props[-1][3] if props else 1) + 2          # after the properties' end
            params = []
            while k + 8 <= len(chunk):
                nm, tp, sz = struct.unpack_from("<HHI", chunk, k)
                if nm == 0 or nm >= len(f.names):
                    break
                name, typ, val = f.names[nm], f.names[tp], chunk[k + 8:k + 4 + sz]
                if typ == "String":
                    n = val[0] & 0x3F if val[0] & 0x80 else 0
                    value = val[1:1 + n].decode("latin-1") if not val[0] & 0x40 else \
                        val[2:2 + ((val[1] << 6) | n)].decode("latin-1")
                elif typ == "CName":
                    value = "cname_" + f.names[struct.unpack_from("<H", val, 0)[0]]
                elif typ in ("Int32", "Uint32", "Int8", "Uint8", "Int16", "Uint16"):
                    value = int.from_bytes(val, "little", signed=typ.startswith("Int"))
                elif typ == "Float":
                    value = round(struct.unpack_from("<f", val, 0)[0], 4)
                elif typ == "Bool":
                    value = bool(val[0])
                else:
                    raise NotLoadable(f"a script with a {typ} parameter")
                params.append({name: value})
                k += 4 + sz
            return {"function": p(node).get("functionName") or "", "parameter": params}

        def answer_condition(q):
            """An answer's condition -> (only_if checks [[fact, op, value]], needs {item: [...], count, none} or
            None): facts (all of them), items the player has (one of them) or has not."""
            c = cls(q)
            if c == "CQuestLogicOperationCondition":
                op = p(q).get("logicOperation") or "LO_And"
                subs = [answer_condition(h[1]) for h in p(q).get("conditions") or []
                        if isinstance(h, tuple) and h[0] == "export"]
                facts = [x for f_, _n in subs for x in f_]
                needs = [n_ for _f, n_ in subs if n_]
                if op == "LO_And" and len(needs) <= 1:
                    return facts, needs[0] if needs else None
                if op == "LO_Or" and not facts and needs and all(not n_.get("none") and
                                                                   n_["count"] == needs[0]["count"] for n_ in needs):
                    return [], dict(needs[0], item=[i for n_ in needs for i in n_["item"]])
                raise NotLoadable(f"a condition {op} of facts and items")
            if c == "W3QuestCond_IsItemQuantityMet":
                d = p(q)
                if (d.get("entityTag") or "PLAYER") != "PLAYER" or not d.get("itemName"):
                    raise NotLoadable("a condition on somebody else's items")
                cmp_, count = d.get("comparator") or "CO_Equal", int(d.get("count") or 0)
                if cmp_ in ("CO_GreaterEq", "CO_Greater"):
                    return [], {"item": [d["itemName"]], "count": max(1, count + (cmp_ == "CO_Greater"))}
                if cmp_ in ("CO_LesserEq", "CO_Equal") and count == 0 or cmp_ == "CO_Lesser" and count == 1:
                    return [], {"item": [d["itemName"]], "count": 1, "none": True}
                raise NotLoadable("an item count condition")
            if c == "CQuestActorCondition":
                # the player has (or has not) an item, asked the actor way (Border Troll: "has no paint yet")
                d = p(q)
                ct = d.get("checkType")
                k = ct[1] if isinstance(ct, tuple) and ct[0] == "export" else None
                if (d.get("actorTag") or "") != "PLAYER" or not k or cls(k) != "CQCHasItem" or not p(k).get("item"):
                    raise NotLoadable("a condition on an actor")
                h = p(k)
                cmp_, count = h.get("compareFunc") or "CF_GreaterEqual", int(h.get("count") or 1)
                if cmp_ in ("CF_GreaterEqual", "CF_Greater"):
                    return [], {"item": [h["item"]], "count": max(1, count + (cmp_ == "CF_Greater"))}
                if cmp_ == "CF_Less" and count <= 1 or cmp_ in ("CF_Equal", "CF_LessEqual") and count == 0:
                    return [], {"item": [h["item"]], "count": 1, "none": True}
                raise NotLoadable("an item count condition")
            return [fact_check(c, p(q))], None

        def nested(checks, op, yes, no):
            """AND: if a then (if b then yes else no) else no; OR: if a then yes else (if b then yes else no)."""
            import copy
            c = checks[0]
            head = {"if": {"fact": c[0], "op": c[1], "value": c[2]}}
            if len(checks) == 1:
                head["then"], head["else"] = yes, no
            elif op == "LO_And":
                head["then"] = {"lines": [nested(checks[1:], op, yes, copy.deepcopy(no))]}
                head["else"] = no
            else:
                head["then"] = yes
                head["else"] = {"lines": [nested(checks[1:], op, copy.deepcopy(yes), no)]}
            return head

        def linear(i):
            """The flow nodes from `i` on as long as the flow goes one way (sections without a choice, scripts); the
            first one that splits is the last."""
            out_, seen_ = [], set()
            i = follow(i)
            while i and i not in seen_:
                seen_.add(i)
                out_.append(i)
                c = cls(i)
                if c == "CStorySceneSection":
                    if handle(p(i).get("choice")) or any(
                            handle(h) and cls(handle(h)) == "CStorySceneChoice" for h in p(i).get("sceneElements") or []):
                        break
                elif c != "CStorySceneScript":
                    break
                i = follow(handle(p(i).get("nextLinkElement")))
            return out_

        def join_of(starts, stack, stop):
            """Where the ways from `starts` meet again: the node most of them reach (the earliest), not one they go
            back to and not the join of a split around this one (`stop`). None: they do not meet."""
            import collections
            paths = [linear(s) for s in starts if s]
            seen_in = collections.Counter(n for path in paths for n in set(path))
            best = None
            for path in paths:
                for k, n in enumerate(path):
                    if seen_in[n] < 2 or n in stack or n == stop:
                        continue
                    rank = (-seen_in[n], k)
                    if best is None or rank < best[0]:
                        best = (rank, n)
            return best[1] if best else None

        def way_end(end, stack):
            """An if's / random's way: its end ("on" / none: it goes on after the split)."""
            if end is None or end[0] == "on":
                return None
            e = "back" if end[0] == "back" and stack and end[1] == stack[-1] else \
                f"out:{end[1]}" if end[0] == "out" else None if end[0] == "end" else "?"
            if e == "?":
                raise NotLoadable("a way that leads back to an earlier choice")
            return e

        active = set()

        def chain(start, stack, stop=None):
            """Lines from `start` on: -> (lines, end) - end: ("out", name) | ("back", section) | ("on", None) (at
            `stop`: where the ways of a split around them join) | None when the lines end with a split. `stack`: the
            sections with a choice we are inside (a way back to one = back)."""
            key = (follow(start), tuple(stack), stop)
            if key in active:                   # round again without a choice between: back through a condition
                raise NotLoadable("a way that goes back round through a condition")
            active.add(key)
            try:
                return chain_(start, stack, stop)
            finally:
                active.discard(key)

        def chain_(start, stack, stop):
            ls, seen, node = [], set(), follow(start)
            while True:
                if not node:
                    return ls, ("end", None)            # a section without a next one ends the scene
                if stop is not None and node == stop:
                    return ls, ("on", None)
                c = cls(node)
                if c == "CStorySceneOutput":
                    return ls, ("out", p(node).get("name") or "Output")
                if c == "CStorySceneScript":
                    ls.append({"script": script(node)})
                    node = follow(handle(p(node).get("nextLinkElement")))
                    continue
                if c == "CStorySceneRandomizer":
                    starts = [handle(h) for h in p(node).get("outputs") or []]
                    join = join_of(starts, stack, stop)
                    ways = []
                    for h in starts:
                        sub, end = chain(h, stack, join or stop)
                        br = {"lines": sub}
                        e = way_end(end, stack)
                        if e:
                            br["end"] = e
                        ways.append(br)
                    ls.append({"random": ways})
                    if join is None:
                        return ls, None
                    node = join                         # the ways meet again: the lines go on from there
                    continue
                if c == "CStorySceneFlowCondition":
                    # lines that depend on a fact: both ways, each with its own end
                    q = handle(p(node).get("questCondition"))
                    if not q:
                        raise NotLoadable("a condition on nothing")
                    if cls(q) == "CQuestLogicOperationCondition":
                        op = p(q).get("logicOperation") or "LO_And"
                        if op not in ("LO_And", "LO_Or"):
                            raise NotLoadable(f"a condition {op}")
                        checks = [fact_check(cls(h[1]), p(h[1])) for h in p(q).get("conditions") or []
                                  if isinstance(h, tuple) and h[0] == "export"]
                    else:
                        op, checks = "LO_And", [fact_check(cls(q), p(q))]
                    element = {}
                    links = [handle(p(node).get(link)) for link in ("trueLink", "falseLink")]
                    join = join_of(links, stack, stop)
                    for side, link in zip(("then", "else"), links):
                        sub, end = chain(link, stack, join or stop)
                        br = {"lines": sub}
                        e = way_end(end, stack)
                        if e:
                            br["end"] = e
                        element[side] = br
                    ls.append(nested(checks, op, element["then"], element["else"]))
                    if join is None:
                        return ls, None
                    node = join
                    continue
                if c != "CStorySceneSection":
                    raise NotLoadable(f"a {c.replace('CStoryScene', '').lower()} in the flow")
                if node in stack:
                    return ls, ("back", node)
                if node in seen:
                    raise NotLoadable("a way that jumps back to an earlier line")
                seen.add(node)
                choice = None
                for e in [handle(h) for h in p(node).get("sceneElements") or []]:
                    if not e:
                        continue
                    if cls(e) not in PLAIN:
                        raise NotLoadable(f"a {cls(e).replace('CStoryScene', '').lower()} in a section")
                    if cls(e) == "CStorySceneLine":
                        ls.append(line(e))
                    elif cls(e) == "CStorySceneChoice":
                        choice = e
                choice = handle(p(node).get("choice")) or choice        # a section keeps its choice apart
                if choice:
                    starts = [handle(p(handle(h)).get("nextLinkElement")) for h in p(choice).get("choiceLines") or []
                              if handle(h)]
                    join = join_of(starts, stack + [node], stop)
                    ls.append({"choice": answers(choice, stack + [node], join or stop)})
                    if join is None:
                        return ls, None
                    node = join                         # the answers meet again: the talk goes on from there
                    continue
                node = follow(handle(p(node).get("nextLinkElement")))

        def answers(choice, stack, stop=None):
            out_ = []
            for h in p(choice).get("choiceLines") or []:
                cl = handle(h)
                if not cl:
                    continue
                extra = {k for k, v in p(cl).items() if v not in (None, "", [], {}, False, 0)} - \
                    {"nextLinkElement", "choiceLine", "elementID", "emphasisLine", "singleUseChoice", "memo"}
                only_if = None
                mapped = {}
                q = handle(p(cl).get("questCondition"))
                if q:
                    checks, need = answer_condition(q)                  # shown only if: facts, items
                    if checks:
                        only_if = checks[0] if len(checks) == 1 else checks
                    if need:
                        mapped["needs"] = need
                    extra.discard("questCondition")
                act = handle(p(cl).get("action"))
                if act and cls(act) in ICONS:           # an icon on the answer (what it does comes after it)
                    mapped["icon"] = ICONS[cls(act)]
                    extra.discard("action")
                elif act and cls(act) == "CMonsterContractChoiceAction":
                    extra.discard("action")             # (its haggling is the script after it)
                elif act and cls(act) == "CAxiiStorySceneChoiceAction":
                    mapped["axii"] = int(p(act).get("level") or 1) if p(act).get("level") else True
                    extra.discard("action")
                elif act and cls(act) == "CPayStorySceneChoiceAction" and p(act).get("money"):
                    mapped["pay"] = int(p(act)["money"])
                    extra.discard("action")
                if extra:
                    what = cls(act).replace("StorySceneChoiceAction", "").replace("ChoiceAction", "").lstrip("C") \
                        if act and "action" in extra else ", ".join(sorted(extra))
                    raise NotLoadable(f"an answer with a {what.lower()} (a game action or condition)")
                _sid, text = text_of(p(cl).get("choiceLine"))
                lines, end = chain(handle(p(cl).get("nextLinkElement")), stack, stop)
                a = {"text": text or "...", "lines": lines, "say": False}      # Geralt's own line follows in them
                if p(cl).get("emphasisLine"):
                    a["emphasize"] = True
                if p(cl).get("singleUseChoice"):
                    a["once"] = True
                if only_if:
                    a["only_if"] = only_if
                a.update(mapped)
                if end is not None:
                    a["end"] = "back" if end[0] == "back" and end[1] == stack[-1] else "on" if end[0] == "on" else \
                        f"out:{end[1]}" if end[0] == "out" else "continue" if end[0] == "end" else None
                    if a["end"] is None:
                        raise NotLoadable("an answer that leads back to an earlier choice")
                elif stop is not None:
                    a["end"] = "on"                     # its lines end with a split whose ways may go on
                out_.append(a)
            return out_

        try:
            lines, end = chain(handle(d.get("nextLinkElement")), [])
            out[name] = (lines, end[1] if end and end[0] == "out" else None, None)
        except NotLoadable as ex:
            out[name] = (None, None, str(ex))
    return out


_TEXTS, _VOICES = None, None


def load_into(swap, depot):
    """A swap's talks start as the game's own (where they load); swap["not_loaded"]: {input: why} for the others."""
    global _TEXTS, _VOICES
    from .assets import LANG, _cr2w_parts, read_strings
    from . import voices
    if _TEXTS is None:
        _TEXTS = read_strings(LANG, lambda s: None)[0]
    if _VOICES is None and voices.ready():
        _VOICES = voices.Voices()
    f = _cr2w_parts(depot.read(swap["scene"]))[0]
    main = {n: (st.get("talk") or {}).get("npc") for n, st in swap["inputs"].items()}
    swap["not_loaded"] = {}
    for name, (lines, then, why) in talks(f, lambda n: main.get(n), _TEXTS, _VOICES).items():
        talk = (swap["inputs"].get(name) or {}).get("talk")
        if talk is None:
            continue
        if lines is None:
            swap["not_loaded"][name] = why
            continue
        talk["dialogue"] = lines
        if then:
            talk["then"] = then
    if not swap["not_loaded"]:
        swap.pop("not_loaded")
    return swap

