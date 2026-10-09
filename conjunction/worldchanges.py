"""Changes to objects the game itself placed - remove a house, set it alight, swap its look - made in the editor and
kept by the script extender (TW3SE world edits, docs/manual/world-edit.md in the extender). No bake, nothing of the
game's files is touched: the extender changes the object every time it comes into the world.

    <project>/world.yml           changes: [{id, guid, do, value, otherwise, label, world, pos}]
    <dlc>\\tw3se\\world.txt        what the build writes for the extender (one line per change)

`do`: remove | effect (value: the effect's name) | look (value: the appearance; otherwise: the one it goes back to) |
move (value: "x y z roll pitch yaw" where it goes; otherwise: the same, where it stood - for taking it back).
Without a quest step a change holds while the quest is installed. A `worldchange` step switches one on or off from
that point of the quest: it sets the fact <quest id>_wc<id>_on / _off, which the extender asks twice a second.
"""
import os

import yaml

FILE = "world.yml"
DOES = ("remove", "effect", "look", "move")


def load(project_path):
    p = os.path.join(project_path, FILE)
    if not os.path.exists(p):
        return []
    return (yaml.safe_load(open(p, encoding="utf-8")) or {}).get("changes") or []


def save(project_path, changes):
    yaml.safe_dump({"changes": changes}, open(os.path.join(project_path, FILE), "w", encoding="utf-8"),
                   sort_keys=False, allow_unicode=True, default_flow_style=None)


def short_name(name):
    """What an object is called on the card: a template path becomes its file name (lamp_standing_complex)."""
    base = str(name or "").replace("/", "\\").rsplit("\\", 1)[-1]
    return base[:-6] if base.lower().endswith(".w2ent") else base


def guid_ok(guid):
    """A key that comes back: four hex dwords, not all zero, not a counter of an object made at run time
    (ffffffff ffffffff n 0 - a crowd's NPC, an item)."""
    parts = str(guid or "").split()
    if len(parts) != 4:
        return False
    try:
        vals = [int(x, 16) for x in parts]
    except ValueError:
        return False
    return any(vals) and not (vals[0] == vals[1] == 0xFFFFFFFF)


def add(project_path, guid, do, value="", label="", world=None, pos=None, otherwise=""):
    """Record a change -> its id. The same object with the same kind of change is updated, not doubled."""
    if do not in DOES:
        raise ValueError(f"a world change is one of {DOES}, not {do!r}")
    if not guid_ok(guid):
        raise ValueError("This object was made by the game at run time and cannot be changed permanently (only "
                         "objects the game placed can)")
    changes = load(project_path)
    for c in changes:
        if c["guid"] == guid and c["do"] == do:
            # (a move keeps where the object first stood: moved twice, it still goes back to the game's place)
            back = c.get("otherwise", "") if do == "move" else otherwise or c.get("otherwise", "")
            c.update(value=value, otherwise=back or otherwise, label=label or c.get("label", ""))
            if do == "move" and pos:
                c["pos"] = [round(float(v), 3) for v in pos]
            save(project_path, changes)
            return c["id"]
    cid = max([c["id"] for c in changes] + [0]) + 1
    changes.append({"id": cid, "guid": guid, "do": do, "value": value, "otherwise": otherwise, "label": label,
                    "world": world, "pos": [round(float(v), 3) for v in pos] if pos else None})
    save(project_path, changes)
    return cid


def drop(project_path, cid):
    """Forget a change (the object is as the game made it again from the next load)."""
    save(project_path, [c for c in load(project_path) if c["id"] != cid])


def transform(pos, rot):
    """A move's value from a position and the game's rotation (roll, pitch, yaw): "x y z roll pitch yaw"."""
    return " ".join(f"{float(v):.3f}" for v in pos) + " " + " ".join(f"{float(v):.2f}" for v in rot)


def facts(qid, cid):
    """The facts a worldchange step sets: (on, off)."""
    return f"{qid}_wc{cid}_on", f"{qid}_wc{cid}_off"


def switched(quest):
    """{change id: {"on", "off"}} - which changes the quest's steps switch on or off."""
    from .quest import all_steps, step_type
    out = {}
    for step in all_steps(quest or {}):
        kind, a = step_type(step)
        if kind == "worldchange" and (a or {}).get("change"):
            out.setdefault(int(a["change"]), set()).add((a or {}).get("state", "on"))
    return out


def lines(project_path, qid, quest):
    """The world.txt lines for the extender."""
    sw = switched(quest)
    out = []
    for c in load(project_path):
        if not guid_ok(c.get("guid")):
            continue
        on, off = facts(qid, c["id"])
        cond = (f" if {on}" if "on" in sw.get(c["id"], ()) else "") + \
               (f" unless {off}" if "off" in sw.get(c["id"], ()) else "")
        label = f"# {c.get('label') or c['do']} (change {c['id']})"
        if c["do"] == "remove":
            out += [label, f"remove {c['guid']}{cond}"]
        elif c["do"] == "effect" and c.get("value"):
            out += [label, f"effect {c['guid']} {c['value']}{cond}"]
        elif c["do"] == "look" and c.get("value"):
            back = f" else {c['otherwise']}" if c.get("otherwise") else ""
            out += [label, f"appearance {c['guid']} {c['value']}{back}{cond}"]
        elif c["do"] == "move" and len(str(c.get("value", "")).split()) == 6:
            x, y, z, roll, pitch, yaw = c["value"].split()     # the extender takes pitch yaw roll
            out += [label, f"move {c['guid']} {x} {y} {z} {pitch} {yaw} {roll}{cond}"]
    return out


def write(project_path, qid, quest, dlc_folder, log=print):
    """<dlc>\\tw3se\\world.txt from the project's changes (none: no file) -> how many changes."""
    text = lines(project_path, qid, quest)
    target = os.path.join(dlc_folder, "tw3se", "world.txt")
    if not text:
        if os.path.exists(target):
            os.remove(target)
        return 0
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"# {qid}: changes to the game's own objects (Conjunction, kept by the script extender TW3SE)\n")
        f.write("\n".join(text) + "\n")
    n = sum(1 for ln in text if not ln.startswith("#"))
    log(f"[build] {qid}: {n} change(s) to the game's objects -> tw3se\\world.txt")
    return n
