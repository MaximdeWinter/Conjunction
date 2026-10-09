"""Several quests in one project (Maxim 05.10.: "wir müssen Projekte haben und es können mehrere quests teil davon
sein"): the project's places - its people and things - are there once, its quests use them side by side, all of
them in the project's one DLC.

A project keeps the quest being edited in meta["quest"] and the others in meta["quests"]; each has a key of its
own (1, 2, ...) that never changes: it gives its steps their numbers (quest 2's node n3 is step 2003, its facts and
blocks s2003_...) and its journal entry (key 1: the project's id, key k: <id>q<k>) - so which one is open does not
matter, and a save keeps its place.

Built, the quests are one graph (merge): each one's start wired from the quest's start, all running at once; the
journal (objectives_by_part, retarget_objectives) and the ends (split_outcomes) are each quest's own again - ending quest 2 does not end
quest 1.

    all_quests(meta) -> [quest]         by key
    add(meta, title) -> key / switch(meta, key) / remove(meta, key)
    journal_key(qid, key) / part_of(step number) -> key
    merge(meta, q) -> (q, {key: quest})
    split_outcomes(struct, parts, qid) / retarget_objectives(struct, parts, qid) / objectives_by_part(...)
"""
import copy
import re

SPAN = 1000


def key_of(q):
    return int((q or {}).get("key") or 1)


def all_quests(meta):
    """Every quest of the project, by key (the one being edited among them)."""
    out = ([meta["quest"]] if meta.get("quest") else []) + list(meta.get("quests") or [])
    return sorted(out, key=key_of)


def journal_key(qid, key):
    return qid if key == 1 else f"{qid}q{key}"


def part_of(number):
    """Which quest a step number belongs to (1: below 2000 - the first quest's own and its test steps)."""
    return 1 if number < 2 * SPAN else number // SPAN


def step_number(block_name):
    """The step number in a block's name (waituntil.s2003_choice -> 2003), None for the quest's own blocks."""
    m = re.search(r"\.s(\d+)(?:_|$)|^[a-z]+\.[a-z]+_s(\d+)(?:_|$)", block_name)
    return int(m.group(1) or m.group(2)) if m else None


def add(meta, title):
    """A new quest of the project, edited from now on. -> its key."""
    from .quest_nodes import new_quest
    keys = [key_of(q) for q in all_quests(meta)] or [1]
    key = max(keys) + 1
    q = new_quest(title)
    q["key"] = key
    if meta.get("quest"):
        meta.setdefault("quest", {}).setdefault("key", 1)
    switch(meta, None)
    meta.setdefault("quests", []).append(q)
    switch(meta, key)
    return key


def switch(meta, key):
    """The quest with this key the one being edited (None: put the edited one back among the others)."""
    cur = meta.get("quest")
    rest = list(meta.get("quests") or [])
    if cur:
        cur.setdefault("key", 1)
        rest.append(cur)
    chosen = next((q for q in rest if key_of(q) == key), None) if key is not None else None
    if key is not None and chosen is None:
        raise ValueError(f"the project has no quest {key}")
    if chosen is not None:
        rest = [q for q in rest if q is not chosen]
        meta["quest"] = chosen
    else:
        meta.pop("quest", None)
    meta["quests"] = sorted(rest, key=key_of)
    if not meta["quests"]:
        meta.pop("quests")


def remove(meta, key):
    """A quest out of the project (not the last one)."""
    qs = all_quests(meta)
    if len(qs) < 2:
        raise ValueError("A project needs at least one quest")
    editing = key_of(meta.get("quest")) == key
    meta["quests"] = [q for q in meta.get("quests") or [] if key_of(q) != key]
    if editing:
        meta.pop("quest", None)
        switch(meta, key_of(meta["quests"][0]))


def merge(meta, q):
    """The project's quests as one graph to build: the first quest's (key 1) with the others' nodes renamed into
    their own numbers, their starts wired from the quest's start, their items. `q`: the quest being edited as the
    caller has it (an older form already made a graph). -> (graph, {key: quest})."""
    from .quest_nodes import START, is_graph, migrate, new_quest
    qs = all_quests(meta)
    if len(qs) < 2:
        return q, {key_of(q): q} if q else {1: q}

    def ready(x):                                       # (the one being edited: as the caller has it)
        x = q if x is meta.get("quest") else x
        return x if is_graph(x) else migrate(copy.deepcopy(x), layout=False)
    first = next((x for x in qs if key_of(x) == 1), None)
    if first is not None and (first.get("nodes") or first.get("steps")):
        base = copy.deepcopy(ready(first))
    else:
        base = new_quest((first or {}).get("title", ""))
    base.setdefault("nodes", {})
    base.setdefault("links", [])
    parts = {1: first if first is not None else base}
    items = dict(base.get("items") or {})
    for other in (ready(x) for x in qs if key_of(x) != 1):
        k = key_of(other)
        parts[k] = other
        names = {}
        loose = sorted(n for n in other.get("nodes") or {} if n != START and not re.fullmatch(r"n\d+", n))
        for nid in other.get("nodes") or {}:
            if nid == START:
                continue
            m = re.fullmatch(r"n(\d+)", nid)
            if m and int(m.group(1)) < 900:
                names[nid] = f"n{k * SPAN + int(m.group(1))}"
            elif nid in loose:                          # (done, failed ...: from 900 on, in their order)
                names[nid] = f"n{k * SPAN + 900 + loose.index(nid)}"
            else:
                raise ValueError(f"quest {k}: a step numbered {nid} - more than 899 steps in one quest")
        for nid, node in (other.get("nodes") or {}).items():
            if nid != START:
                base["nodes"][names[nid]] = copy.deepcopy(node)
        for a, port, b in other.get("links") or []:
            if b in names:
                base["links"].append([START if a == START else names.get(a, a), port, names[b]])
        items.update(other.get("items") or {})
    if items:
        base["items"] = items
    return base, parts


def split_outcomes(struct, parts, qid):
    """Each quest's ends its own: the blocks of quest k (k > 1) that lead to the quest's outcome lead to quest k's
    (questoutcome.done_q<k> / failed_q<k>, their facts <journal key>_done / _failed). -> the guards to add
    {outcome: (guard block, the other outcome's fact, socket)}."""
    guards = {}
    for k in sorted(parts):
        if k == 1:
            continue
        jk = journal_key(qid, k)
        mine = {}
        for name, b in struct.items():
            n = step_number(name)
            if n is None or part_of(n) != k or not isinstance(b, dict):
                continue
            for key, targets in b.items():
                if not (key.startswith("next") and isinstance(targets, list)):
                    continue
                for i, t in enumerate(targets):
                    if isinstance(t, dict) and len(t) == 1:
                        (target, sock), = t.items()
                        if target in ("questoutcome.done", "questoutcome.failed"):
                            new = f"{target}_q{k}"
                            targets[i] = {new: sock}
                            mine[new] = target.split(".")[1]
        for outcome, how in mine.items():
            fact = f"{jk}_{how}"
            struct[outcome] = {"quest": jk, "next": [f"addfact.{how}_q{k}"]}
            struct[f"addfact.{how}_q{k}"] = {"value": [fact, 1], "next": ["waituntil.forever"]}
        for how, other, sock in (("done", "failed", "Success"), ("failed", "done", "Failure")):
            outcome = f"questoutcome.{how}_q{k}"
            if outcome in struct:
                guards[outcome] = (f"waituntil.end_{how}_q{k}", f"{jk}_{other}", sock)
    return guards


def objectives_by_part(objectives, parts):
    """The journal's objectives ({id: ...}, ids s<step>...) by the quest they belong to -> {key: [objective]}."""
    mine = {k: [] for k in parts}
    for ob in objectives:
        m = re.match(r"s(\d+)", next(iter(ob)))
        k = part_of(int(m.group(1))) if m else 1
        mine.setdefault(k if k in parts else 1, []).append(ob)
    return mine


def retarget_objectives(struct, parts, qid):
    """Objective blocks of quest k name its own journal entry (<id>q<k>/main/s...)."""
    for b in struct.values():
        if not isinstance(b, dict):
            continue
        ref = b.get("objective")
        if isinstance(ref, str) and ref.startswith(f"{qid}/main/"):
            m = re.match(r"s(\d+)", ref.split("/")[-1])
            k = part_of(int(m.group(1))) if m else 1
            if k != 1 and k in parts:
                b["objective"] = f"{journal_key(qid, k)}/main/{ref.split('/')[-1]}"
