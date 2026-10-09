"""Follow as the game's own quests do it (Maxim 02.10.: "how do the vanilla quests do it?" - q704 "Regis follows us"):
the person is sent along a path with the player as companion - one smooth walk that waits when the player falls
behind, instead of a community phase per point (each phase change stood him still 2-3 s).

- the path: an entity of the quest's DLC with a CPathComponent whose curve runs through the drawn points (relative
  to the entity, placed at the first point and tagged): radish writes the entity with an empty path component, the
  curve is put in after encoding (patch_paths) - the same properties as the game's paths (q701_gardens_paths.w2l):
  an SMultiCurve of three SCurveData (X, Y, Z), each point a time (0..1 by distance), its value and a tangent
- the block: a stand-in fact block made the game's CQuestScriptedActionsBlock (follow_block) owning a
  CAIMoveAlongPathWithCompanionAction and its params - npcTag, the priority, the path's tag, the distances

    curve(f, points)                    -> the SMultiCurve's bytes (points relative to the entity)
    patch_paths(uncooked, spec)         {entity name: {"points": [[x, y, z], ...]}} into the encoded .w2ent files
    follow_block(f, block, m)           the stand-in -> the scripted actions block (minigames.apply calls it)
"""
import math
import os
import struct

TREE = "gameplay\\trees\\scripted_actions\\move_along_path_companion.w2behtree"
STEER = "gameplay\\behaviors\\npc\\steering\\action\\manual_pathfollow\\manual_pathfollow.w2steer"
TANGENT = (-0.1, 0.0, 0.1, 0.0)             # every point of the game's paths has this one


def _helpers():
    from .graph_edit import _cname, _idx, _prop
    return _cname, _idx, _prop


def _struct(props):
    return b"\0" + props + b"\0\0"


def curve(f, points):
    """The path's SMultiCurve (its value bytes) through `points` (relative to the entity)."""
    _cname, _idx, _prop = _helpers()
    fl = lambda name, v: _prop(f, name, "Float", struct.pack("<f", float(v)))       # noqa: E731
    lengths = [0.0]
    for a, b in zip(points, points[1:]):
        lengths.append(lengths[-1] + math.dist(a[:3], b[:3]))
    total = lengths[-1] or 1.0
    times = [d / total for d in lengths]
    vec = _struct(fl("X", TANGENT[0]) + fl("Y", TANGENT[1]) + fl("Z", TANGENT[2]) + fl("W", TANGENT[3]))
    datas = []
    for axis in range(3):
        entries = b""
        for t, p in zip(times, points):
            props = (fl("me", t) if t > 0 else b"") + _prop(f, "ntrolPoint", "Vector", vec) + \
                fl("lue", p[axis]) + _prop(f, "rveTypeL", "Uint16", struct.pack("<H", 1)) + \
                _prop(f, "rveTypeR", "Uint16", struct.pack("<H", 1))
            entries += _struct(props)
        values = _prop(f, "Curve Values", "array:147,0,SCurveDataEntry", struct.pack("<I", len(points)) + entries)
        datas.append(_struct(values + _prop(f, "value type", "ECurveValueType", _cname(f, "CVT_Float")) +
                             _prop(f, "type", "ECurveBaseType", _cname(f, "CT_Smooth"))))
    return _struct(_prop(f, "type", "ECurveType", _cname(f, "ECurveType_Vector")) +
                   _prop(f, "enableAutomaticTimeByDistanceRecalculation", "Bool", b"\1") +
                   _prop(f, "curves", "array:2,0,SCurveData", struct.pack("<I", 3) + b"".join(datas)))


def _add_props(f, export, extra):
    """`extra` (tagged properties) appended to an export's own (before its end)."""
    e = f.exports[export - 1]
    chunk = bytes(e[4])
    props = f.props(chunk)
    if props:
        end = props[-1][2] + props[-1][3]
        e[4] = bytearray(chunk[:end] + extra + chunk[end:])
    else:
        e[4] = bytearray(b"\0" + extra + chunk[1:])


def patch_paths(uncooked, spec):
    """The curves into the path entities radish encoded -> the names done."""
    from .cr2w import CR2W
    _cname, _idx, _prop = _helpers()
    done = []
    for root, _d, files in os.walk(uncooked):
        for n in files:
            name = n[:-6] if n.endswith(".w2ent") else None
            if name not in spec:
                continue
            path = os.path.join(root, n)
            f = CR2W(open(path, "rb").read())
            comp = next((i for i, e in enumerate(f.exports, 1) if e[0] == "CPathComponent"), None)
            if comp is None:
                raise ValueError(f"{n}: no path component to put the way into")
            _add_props(f, comp, _prop(f, "curve", "SMultiCurve", curve(f, spec[name]["points"])))
            data = f.save()
            if CR2W(data).save() != data:
                raise RuntimeError(f"{n} does not read back after its way was written")
            open(path, "wb").write(data)
            done.append(name)
    missing = set(spec) - set(done)
    if missing:
        raise ValueError(f"the encoded DLC has no path entity for {sorted(missing)}")
    return done


RACE_TREE = "gameplay\\trees\\scripted_actions\\move_along_path.w2behtree"
RACE_STEER = "gameplay\\behaviors\\npc\\steering\\action\\manual_pathfollow\\manual_pathfollow_racing.w2steer"


def race_block(f, block, m):
    """The stand-in (a fact block) made the game's scripted actions block: the racer (m["npc"]) runs the path
    (m["path"]) with the game's race AI - CAIMoveAlongPathAction with CAIRaceAlongPathParams, as the game's own races
    on foot (q205's Ciri, sq107's pigs): manual_pathfollow_racing steering, explorations used, the pace m["pace"]."""
    from .graph_edit import CONDITION_FLAGS
    _cname, _idx, _prop = _helpers()
    e = f.exports[block - 1]
    chunk = bytes(e[4])
    props = f.props(chunk)
    head, tail = chunk[:props[0][2] - 8], chunk[props[-1][2] + props[-1][3]:]
    keep = b"".join(chunk[off - 8:off + size] for n, _t, off, size in props
                    if n in ("name", "guid", "cachedConnections"))
    for c in ("CQuestScriptedActionsBlock", "CAIMoveAlongPathAction", "CAIRaceAlongPathParams"):
        _idx(f, c)

    def imported(path, cls):
        for k, (p, c, _fl) in enumerate(f.imports):
            if p.lower() == path.lower():
                return -(k + 1)
        _idx(f, cls)
        f.imports.append([path, cls, 0])
        return -len(f.imports)
    tree, steer = imported(RACE_TREE, "CBehTree"), imported(RACE_STEER, "CMoveSteeringBehavior")
    action = len(f.exports) + 1
    params = action + 1
    e[0] = "CQuestScriptedActionsBlock"
    e[4] = bytearray(head + keep + _prop(f, "npcTag", "CName", _cname(f, m["npc"])) +
                     _prop(f, "actionsPriority", "ETopLevelAIPriorities", _cname(f, "AIP_AboveEmergency")) +
                     _prop(f, "ai", "handle:IAIActionTree", struct.pack("<i", action)) + tail)
    pace = m.get("pace") or "MT_FastRun"
    p = (_prop(f, "pathTag", "CName", _cname(f, m["path"])) +
         _prop(f, "moveTypeBeforePath", "EMoveType", _cname(f, pace)) +
         _prop(f, "moveType", "EMoveType", _cname(f, pace)) +
         _prop(f, "steeringGraph", "handle:CMoveSteeringBehavior", struct.pack("<i", steer)) +
         _prop(f, "fromBeginning", "Bool", b"\1") +
         _prop(f, "useExplorations", "Bool", b"\1") +
         _prop(f, "dontCareAboutNavigable", "Bool", b"\1") +
         _prop(f, "pathMargin", "Float", struct.pack("<f", 0.5)))
    f.exports.append(["CAIMoveAlongPathAction", CONDITION_FLAGS, block, 0, bytearray(
        b"\0" + _prop(f, "tree", "handle:CBehTree", struct.pack("<i", tree)) +
        _prop(f, "params", "handle:CAIMoveAlongPathParams", struct.pack("<i", params)) + b"\0\0")])
    f.exports.append(["CAIRaceAlongPathParams", CONDITION_FLAGS, action, 0, bytearray(b"\0" + p + b"\0\0")])


def follow_block(f, block, m):
    """The stand-in (a fact block) made the game's scripted actions block: the person (m["npc"]) walks the path
    (m["path"], a tag) with the player as companion - waits beyond m["max"] metres, goes on within m["min"]."""
    from .graph_edit import CONDITION_FLAGS
    _cname, _idx, _prop = _helpers()
    e = f.exports[block - 1]
    chunk = bytes(e[4])
    props = f.props(chunk)
    head, tail = chunk[:props[0][2] - 8], chunk[props[-1][2] + props[-1][3]:]
    keep = b"".join(chunk[off - 8:off + size] for n, _t, off, size in props
                    if n in ("name", "guid", "cachedConnections"))
    for c in ("CQuestScriptedActionsBlock", "CAIMoveAlongPathWithCompanionAction",
              "CAIMoveAlongPathWithCompanionParams"):
        _idx(f, c)

    def imported(path, cls):
        for k, (p, c, _fl) in enumerate(f.imports):
            if p.lower() == path.lower():
                return -(k + 1)
        _idx(f, cls)                                    # (its class among the names before saving)
        f.imports.append([path, cls, 0])
        return -len(f.imports)
    tree, steer = imported(TREE, "CBehTree"), imported(STEER, "CMoveSteeringBehavior")
    action = len(f.exports) + 1
    params = action + 1
    e[0] = "CQuestScriptedActionsBlock"
    e[4] = bytearray(head + keep + _prop(f, "npcTag", "CName", _cname(f, m["npc"])) +
                     _prop(f, "actionsPriority", "ETopLevelAIPriorities",
                           _cname(f, m.get("priority", "AIP_AboveEmergency"))) +
                     _prop(f, "ai", "handle:IAIActionTree", struct.pack("<i", action)) + tail)
    move = "MT_Run" if m.get("run") else "MT_Walk"
    p = (_prop(f, "pathTag", "CName", _cname(f, m["path"])) +
         _prop(f, "moveTypeBeforePath", "EMoveType", _cname(f, move)) +
         _prop(f, "moveType", "EMoveType", _cname(f, move)) +
         _prop(f, "steeringGraph", "handle:CMoveSteeringBehavior", struct.pack("<i", steer)) +
         _prop(f, "rotateAfterReachStart", "Bool", b"\0") +
         _prop(f, "useExplorations", "Bool", b"\1") +
         _prop(f, "dontCareAboutNavigable", "Bool", b"\1") +
         _prop(f, "tolerance", "Float", struct.pack("<f", 1.0)) +
         _prop(f, "maxDistance", "Float", struct.pack("<f", float(m.get("max", 10.0)))) +
         _prop(f, "minDistance", "Float", struct.pack("<f", float(m.get("min", 4.0)))) +
         _prop(f, "progressWhenCompanionIsAhead", "Bool", b"\1"))
    f.exports.append(["CAIMoveAlongPathWithCompanionAction", CONDITION_FLAGS, block, 0, bytearray(
        b"\0" + _prop(f, "tree", "handle:CBehTree", struct.pack("<i", tree)) +
        _prop(f, "params", "handle:CAIMoveAlongPathParams", struct.pack("<i", params)) + b"\0\0")])
    f.exports.append(["CAIMoveAlongPathWithCompanionParams", CONDITION_FLAGS, action, 0, bytearray(b"\0" + p + b"\0\0")])
