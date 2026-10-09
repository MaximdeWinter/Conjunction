"""Facts followed through a quest file: which blocks set a fact, wait for it, check it, remove it - in every graph of
the file, with the phases one steps into to get there (the card of a fact block lists them; a click opens them).

    facts_of(tree, n) -> {fact names}       the facts block n sets or reads (its conditions too)
    uses(qf, names) -> [{"block", "guid", "trail", "where", "what", "title", "name"}]
"""
from .block_examples import trail as trail_of

FACT_CONDS = ("CQuestFactsDBCondition", "CQuestFactsDBExCondition")
SETTERS = {"CQuestFactsDBChangingBlock": "factID"}
FUNCTIONS = {"AddFact": "factName", "RemoveFactQuest": "factId", "AddFactQuest": "factName"}


def _conds(tree, n, seen=None):
    """Condition objects under block / condition n (and / or followed)."""
    seen = seen or set()
    o = tree.obj(n)
    out = []
    for key in ("conditions", "questCondition"):
        v = o.get(key)
        for c in (v if isinstance(v, list) else [v]):
            if isinstance(c, int) and c > 0 and c not in seen:
                seen.add(c)
                out.append(c)
                out += _conds(tree, c, seen)
    return out


def facts_of(tree, n):
    o = tree.obj(n)
    names = set()
    if o.cls in SETTERS and o.get(SETTERS[o.cls]):
        names.add(str(o.get(SETTERS[o.cls])))
    if o.cls == "CQuestScriptBlock":
        fn = str(o.get("functionName") or "")
        for p in o.get("parameters") or []:
            if fn in FUNCTIONS and p.get("name") == FUNCTIONS[fn]:
                v = p.get("value")
                names.add(str(getattr(v, "value", v)))
    for c in _conds(tree, n):
        co = tree.obj(c)
        if co.cls in FACT_CONDS:
            for key in ("factId", "factId1", "factId2"):
                if co.get(key):
                    names.add(str(co.get(key)))
    return {x for x in names if x}


def uses(qf, names):
    t = qf.tree
    out = []
    for gn, go in enumerate(t.objects, 1):
        if go.cls != "CQuestGraph":
            continue
        tr = None
        for b in go.get("graphBlocks") or []:
            if not (isinstance(b, int) and b > 0):
                continue
            hit = facts_of(t, b) & names
            if not hit:
                continue
            o = t.obj(b)
            if tr is None:
                tr = trail_of(t, gn)
            what = "sets" if o.cls in SETTERS or o.cls == "CQuestScriptBlock" and \
                str(o.get("functionName")) in ("AddFact", "AddFactQuest") else \
                "removes" if o.cls == "CQuestScriptBlock" else \
                "waits for" if o.cls == "CQuestPauseConditionBlock" else "checks"
            names_in = []
            for g in tr:
                k = next((i for i, x in enumerate(t.objects, 1) if x.props and
                          getattr(x.get("guid"), "hex", lambda: None)() == g), None)
                names_in.append((t.obj(k).get("name") or "phase") if k else "phase")
            from . import blocks
            out.append({"block": b, "guid": bytes(o.get("guid")).hex() if o.get("guid") is not None else None,
                        "trail": tr, "where": " > ".join(names_in), "what": what,
                        "title": blocks.kind_of(t, b).label, "name": str(o.get("name") or "")})
    return out
