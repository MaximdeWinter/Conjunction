"""The trail library: tracks a quest lays out for the witcher senses - footprints, blood, drag marks - as the game's
own contracts do (20-37 pieces along the way to the beast, each a clue of its own, lit when the trail opens).

A trail is drawn in the editor: a few points clicked, the pieces laid every `spacing` metres along them, turned along
the way (footprints left and right in turn), each on the ground the game reports there.

    LIBRARY             [(key, label, group, templates, spacing)]
    pieces(points, kind) -> [[x, y, z, yaw, template], ...] (z from the points; the editor asks the game for the ground)
"""
import math

# templates: one is used for every piece; two or more take turns (left foot, right foot)
LIBRARY = [
    # people
    ("boots", "Boot prints", "People", [r"quests\minor_quests\prologue_village\quest_files\mq0005_dwarfsmith\clues\mq0005_bootprints.w2ent"], 1.4),
    ("footprints", "Footprints", "People", [r"quests\part_1\quest_files\q202_giant\entities\q202_focus_footprints_left.w2ent",
                                             r"quests\part_1\quest_files\q202_giant\entities\q202_focus_footprints_right.w2ent"], 0.75),
    ("bare_feet", "Bare feet", "People", [r"dlc\ep1\data\quests\quest_files\mq6004_broken_rose\entities\clues\mq6004_bare_footprints.w2ent"], 1.4),
    ("armored", "Soldiers' boots", "People", [r"dlc\ep1\data\quests\quest_files\mq6004_broken_rose\entities\clues\mq6004_armored_footprints.w2ent"], 1.4),
    ("children", "Child's footprints", "People", [r"quests\part_1\quest_files\q105_witches\entities\q105_children_footprints.w2ent"], 1.0),
    # animals
    ("horse", "Hoofprints", "Animals", [r"dlc\ep1\data\quests\quest_files\mq6004_broken_rose\entities\clues\mq6004_horseprints.w2ent"], 2.0),
    ("wolf", "Wolf tracks", "Animals", [r"quests\part_1\quest_files\q205_frozen_coast\entities\q205_focus_wolfprints.w2ent"], 1.2),
    ("dog", "Dog tracks", "Animals", [r"quests\minor_quests\prologue_village\quest_files\mq0001_missing_brother\clues\mq0001_dog_track.w2ent"], 1.0),
    ("goat", "Goat tracks", "Animals", [r"quests\part_1\quest_files\q103_daughter\entities\q103_goat_track.w2ent"], 1.0),
    ("boar", "Boar tracks", "Animals", [r"dlc\ep1\data\quests\quest_files\q603_bank\entities\q603_clue_boar_tracks.w2ent"], 1.2),
    # monsters
    ("nekker", "Nekker tracks", "Monsters", [r"quests\generic_quests\skellige\quest_files\mh202_nekker_warrior\entities\mh202_nekker_tracks.w2ent"], 1.2),
    ("troll", "Troll tracks", "Monsters", [r"dlc\dlc3\data\entities\mh201_troll_tracks.w2ent"], 2.2),
    ("giant", "Giant's footprints", "Monsters", [r"quests\part_1\quest_files\q202_giant\entities\q202_focus_footprints_giant_left.w2ent"], 3.0),
    ("cockatrice", "Cockatrice tracks", "Monsters", [r"quests\generic_quests\no_mans_land\quest_files\mh101_cockatrice\entities\mh101_cockatrice_tracks.w2ent"], 1.5),
    ("arachas", "Arachas tracks", "Monsters", [r"quests\generic_quests\no_mans_land\quest_files\mh102_arachas\entities\mh102_arachas_tracks.w2ent"], 2.0),
    ("leshen", "Leshen footprints", "Monsters", [r"quests\sidequests\skellige\quest_files\sq204_forest_spirit\entities\sq204_leshy_footprints.w2ent",
                                                  r"quests\sidequests\skellige\quest_files\sq204_forest_spirit\entities\sq204_leshy_footprints_r.w2ent"], 1.8),
    ("fiend", "Fiend tracks", "Monsters", [r"quests\generic_quests\skellige\quest_files\mh206_fiend_ruins\entities\mh206_fiend_tracks_single_back.w2ent"], 2.5),
    ("forktail", "Forktail tracks", "Monsters", [r"quests\part_1\quest_files\q401_konsylium\clues\q401_forktail_track.w2ent"], 2.0),
    # blood and marks
    ("blood_drops", "Blood drops", "Blood and marks", [r"quests\generic_quests\no_mans_land\quest_files\mh101_cockatrice\entities\mh101_blood_trace.w2ent"], 1.6),
    ("blood_trail", "Blood trail", "Blood and marks", [r"quests\minor_quests\prologue_village\quest_files\mq0005_dwarfsmith\clues\mq0005_blood_trail.w2ent"], 1.8),
    ("blood_splat", "Blood splats", "Blood and marks", [r"gameplay\focus_mode_clues\generic_clues_traces\generic_clue_blood_splat.w2ent"], 2.5),
    ("drag", "Drag marks", "Blood and marks", [r"quests\part_1\quest_files\q202_giant\entities\q202_focus_dragmarks.w2ent"], 2.0),
    ("blood_drag", "Bloody drag marks", "Blood and marks", [r"quests\part_1\quest_files\q202_giant\entities\q202_focus_blood_drag_big.w2ent"], 2.5),
    ("cart", "Cart tracks", "Blood and marks", [r"dlc\bob\data\quests\main_quests\quest_files\q701_wine_festival\entities\q701_victim_cart_tracks.w2ent"], 3.0),
]
BY_KEY = {k: (label, group, templates, spacing) for k, label, group, templates, spacing in LIBRARY}
GROUPS = list(dict.fromkeys(g for _k, _l, g, _t, _s in LIBRARY))


def pieces(points, kind, spacing=None):
    """[[x, y, z, yaw, template]] of a trail along `points` ([x, y, z] each): a piece every `spacing` m, turned along
    the way (yaw in degrees, the game's: 0 looks along +y), the templates in turn."""
    _label, _group, templates, default = BY_KEY[kind]
    step = float(spacing or default)
    pts = [[float(v) for v in p[:3]] for p in points if p]
    if len(pts) < 2:
        return [[*pts[0], 0.0, templates[0]]] if pts else []
    out, carry, n = [], 0.0, 0
    for a, b in zip(pts, pts[1:]):
        dx, dy, dz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
        seg = math.hypot(dx, dy)
        if seg < 1e-6:
            continue
        yaw = math.degrees(math.atan2(-dx, dy)) % 360.0
        # two templates (left foot, right foot): each a hand's breadth beside the line, as a walker's steps
        side = (0.12 / seg) if len(templates) == 2 else 0.0
        d = carry
        while d <= seg + 1e-6:
            t = d / seg
            off = side * (-1 if n % 2 == 0 else 1)
            out.append([round(a[0] + dx * t + dy * off, 3), round(a[1] + dy * t - dx * off, 3),
                        round(a[2] + dz * t, 3), round(yaw, 1), templates[n % len(templates)]])
            n += 1
            d += step
        carry = d - seg
    return out
