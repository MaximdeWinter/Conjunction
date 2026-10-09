"""Gwent and fist fights in an own quest. radish has no block for minigames: the quest gets a stand-in - a randomize
block named gwent_s<i> / fistfight_s<i> with the outputs Success and Failure - and once radish has encoded the quest
the stand-in becomes the game's own minigame block, as the game's quests have it: CQuestGraphMinigameBlock (its links
kept) owning a CGwintMinigame (deckName, difficulty, aggression - 188 in the game) or a CFistfightMinigame
(fightAreaTag, enemies [{npcTag}] - 41). The game's quests go on from Success / Failure (mq7024: back into the talk -
gwent_win, gwent_loss).

The same way 'Stop lane': a fact block named cut_s<i> becomes the game's cut control block (CQuestCutControlBlock -
its output Thunder leads to the input Cut of the blocks it stops; 19 in q103 and mq1035).

    apply(folder, spec) - every stand-in of `spec` {block name: {"deck", "difficulty"} | {"game": "fistfight",
        "area": tag, "enemies": [tags]}} in the encoded quest files under `folder` replaced; -> the names replaced
"""
import glob
import os
import re
import struct

# the opponents' decks of the game's quests (every deckName of their gwent blocks)
DECKS = ["Baron", "BoatBuilder", "CardProdigy", "CircusGwentAddict", "Crach", "CrossroadsInnkeeper", "Dijkstra",
         "Gambler", "Gremista", "Halflings", "Hermit", "Lambert", "LugosTheMad", "MarkizaSerenity", "Mousesack",
         "NKEasy", "NKNormal", "NKHard", "NKTournament", "NMLEasy", "NMLNormal", "NMLHard", "NMLTournament",
         "NMLTournament2", "NilfEasy", "NilfNormal", "NilfHard", "NilfPrologue", "NilfTournament", "NilfTournament2",
         "Olgierd", "Olivier", "Roche", "ScoiaEasy", "ScoiaNormal", "ScoiaHard", "ScoiaTournament",
         "ScoiaTournament2", "ScoiaTrader", "Shani", "Sjusta", "SkelEasy", "SkelNormal", "SkelHard", "SkelTournament2",
         "Stjepan", "Thaler", "VimmeVivaldi", "Zoltan"]
FACTIONS = {"NK": "Northern Realms", "NML": "Monsters", "Nilf": "Nilfgaard",
            "Scoia": "Scoia'tael", "Skel": "Skellige"}
DIFFICULTY = {"medium": "EGDM_Medium", "hard": "EGDM_Hard"}       # the two the game's quests use
AGGRESSION = {"normal": "EGAM_Normal", "aggressive": "EGAM_Aggressive", "very aggressive": "EGAM_VeryAggressive",
              "all it has": "EGAM_AllIHave"}


def deck_label(deck):
    """'NilfHard' -> 'Nilfgaard, hard'; a person's deck is theirs ('LugosTheMad' -> 'Lugos The Mad')."""
    for pre, faction in FACTIONS.items():
        rest = deck[len(pre):]
        if deck.startswith(pre) and rest in ("Easy", "Normal", "Hard", "Prologue", "Tournament", "Tournament2"):
            return f"{faction}, {rest.lower().replace('2', ' 2')}"
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", deck)


def _replace(f, block, m):
    from .graph_edit import CONDITION_FLAGS, _cname, _idx, _prop
    e = f.exports[block - 1]
    chunk = bytes(e[4])
    props = f.props(chunk)
    head, tail = chunk[:props[0][2] - 8], chunk[props[-1][2] + props[-1][3]:]
    keep = b"".join(chunk[off - 8:off + size] for n, _t, off, size in props if n != "randomOutputs")
    new = len(f.exports) + 1
    cls = "CFistfightMinigame" if m.get("game") == "fistfight" else "CGwintMinigame"
    for c in ("CQuestGraphMinigameBlock", cls):
        _idx(f, c)
    e[0] = "CQuestGraphMinigameBlock"
    e[4] = bytearray(head + keep + _prop(f, "minigame", "ptr:CMinigame", struct.pack("<i", new)) + tail)
    if cls == "CFistfightMinigame":
        # the opponents: an array of structs (each: a 0 byte, its properties, name 0)
        enemies = struct.pack("<I", len(m["enemies"])) + b"".join(
            b"\0" + _prop(f, "npcTag", "CName", _cname(f, t)) + b"\0\0" for t in m["enemies"])
        game = b"\0" + _prop(f, "fightAreaTag", "CName", _cname(f, m["area"])) + \
            _prop(f, "enemies", "array:2,0,CFistfightOpponent", enemies) + b"\0\0"
    else:
        game = b"\0" + _prop(f, "deckName", "CName", _cname(f, m["deck"])) + \
            _prop(f, "difficulty", "EGwintDifficultyMode",
                  _cname(f, DIFFICULTY.get(m.get("difficulty"), "EGDM_Medium"))) + \
            _prop(f, "aggression", "EGwintAggressionMode",
                  _cname(f, AGGRESSION.get(m.get("aggression"), "EGAM_Normal"))) + b"\0\0"
    f.exports.append([cls, CONDITION_FLAGS, block, 0, bytearray(game)])


# radish's block types and the classes it encodes them as (read from its output) - a name alone is not unique
CLASSES = {"waituntil": "CQuestPauseConditionBlock", "interaction": "CQuestInteractionDialogBlock",
           "objective": "CJournalQuestBlock", "script": "CQuestScriptBlock", "changelayers": "CQuestLayersHiderBlock",
           "reward": "CQuestRewardBlock", "addfact": "CQuestFactsDBChangingBlock", "spawn": "CQuestStoryPhaseSetterBlock",
           "journal": "CJournalBlock", "scene": "CQuestSceneBlock", "randomize": "CQuestRandomBlock"}


def _cut(f, block, m, named):
    """The stand-in (a fact block) made the game's cut control block: Out as before, Thunder to the input Cut of
    every block of the lane."""
    from .graph_edit import _connections, _idx, links
    targets = []
    for key in m["blocks"]:
        kind, _, name = key.partition(".")
        found = [i for i, cls, n in named if n == name and (cls == CLASSES.get(kind) or kind not in CLASSES)]
        if len(found) == 1:
            targets.append((found[0], "Cut"))
    if not targets:
        raise ValueError(f"stop lane: none of the lane's blocks is in the encoded quest ({m['lane']})")
    e = f.exports[block - 1]
    chunk = bytes(e[4])
    props = f.props(chunk)
    head, tail = chunk[:props[0][2] - 8], chunk[props[-1][2] + props[-1][3]:]
    out = [t for s, t in links(f, block) if s == "Out"]
    keep = b"".join(chunk[off - 8:off + size] for n, _t, off, size in props if n in ("name", "guid"))
    _idx(f, "CQuestCutControlBlock")
    e[0] = "CQuestCutControlBlock"
    conns = [("Out", out[0] if out else []), ("Thunder", targets)]
    e[4] = bytearray(head + keep + struct.pack("<HHI", _idx(f, "cachedConnections"),
                                               _idx(f, "array:2,0,SCachedConnections"), 4 + len(_connections(f, conns)))
                     + _connections(f, conns) + tail)


def apply_data(data, spec):
    """The stand-ins of `spec` in one encoded quest file (its bytes) -> (the new bytes, the names replaced)."""
    from .cr2w import CR2W
    from .cr2w_props import decode
    if not spec or not any(n.encode("utf-8") in data for n in spec):
        return data, []
    f = CR2W(data)
    named = [(i, e[0], decode(f, e[4]).get("name")) for i, e in enumerate(f.exports, 1) if "Block" in e[0]]
    mine = [(i, n) for i, cls, n in named if n in spec and cls in ("CQuestRandomBlock",
                                                                   "CQuestFactsDBChangingBlock")]
    for i, n in mine:
        if spec[n].get("game") == "cut":
            _cut(f, i, spec[n], named)
        elif spec[n].get("game") == "follow":            # (pathfollow.py: walk a path, the player his companion)
            from .pathfollow import follow_block
            follow_block(f, i, spec[n])
        elif spec[n].get("game") == "race":              # (pathfollow.py: a racer runs the course)
            from .pathfollow import race_block
            race_block(f, i, spec[n])
        else:
            _replace(f, i, spec[n])
    return (f.save() if mine else data), [n for _i, n in mine]


def apply(folder, spec):
    done = []
    if not spec:
        return done
    for fn in sorted(glob.glob(os.path.join(folder, "**", "*.w2quest"), recursive=True) +
                     glob.glob(os.path.join(folder, "**", "*.w2phase"), recursive=True)):
        data = open(fn, "rb").read()
        new, mine = apply_data(data, spec)
        if mine:
            open(fn, "wb").write(new)
            done += mine
    missing = set(spec) - set(done)
    if missing:
        raise ValueError(f"the encoded quest has no stand-in for {sorted(missing)}")
    return done
