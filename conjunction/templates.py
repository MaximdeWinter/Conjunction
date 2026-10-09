"""Quest templates: a new quest starts from one of these skeletons - the steps, talks and decisions are there, the
author puts in who and where (Pick / Create on the cards) and changes the words.

    TEMPLATES: [(key, label, what it shows, quest dict)]
"""
import copy

ERRAND = {
    "title": "A Small Favour",
    "type": "secondary",
    "description": "Someone in town needs a witcher's help.",
    "steps": [
        {"talk": {"text": "Talk to the villager", "start": "calls",
                  "call": [{"who": "npc", "text": "Witcher! A moment, please!"}],
                  "dialogue": [
                      {"who": "npc", "text": "Bandits took my things and hid them. Could you get them back?",
                       "gesture": "explain", "mood": "nervous"},
                      {"choice": [
                          {"text": "Where?", "lines": [
                              {"who": "npc", "text": "Near the old mill. Please hurry.", "gesture": "point"}],
                           "end": "continue"},
                          {"text": "Not now.", "lines": [], "end": "retry"}]}]}},
        {"goto": {"text": "Find the hiding place", "radius": 10}},
        {"loot": {"text": "Search the chest"}},
        {"deliver_marker": {}},
    ],
}
# (deliver is a talk that takes the item; made below so every template gets fresh dicts)

DECISION = {
    "title": "A Price for Mercy",
    "type": "secondary",
    "description": "A captive, a captor and a choice.",
    "steps": [
        {"talk": {"text": "Talk to the worried father", "dialogue": [
            {"who": "npc", "text": "They took my daughter! Please, witcher!", "mood": "afraid"},
            {"choice": [{"text": "I'll find her.", "lines": [], "end": "continue"},
                        {"text": "Not now.", "lines": [], "end": "retry"}]}]}},
        {"goto": {"text": "Find the kidnappers", "radius": 12}},
        {"talk": {"text": "Talk to the kidnapper", "start": "near", "radius": 7, "dialogue": [
            {"who": "npc", "text": "Walk away, witcher. Or take a share of the ransom.", "mood": "contempt"},
            {"choice": [
                {"text": "Let her go.", "lines": [{"who": "npc", "text": "Make me.", "gesture": "stop"}],
                 "end": "path:rescue"},
                {"text": "How much?", "lines": [{"who": "npc", "text": "Half. If you leave now."}],
                 "end": "path:ransom"}]}]}},
    ],
    "paths": {
        "rescue": {"label": "Rescue her", "then": "join", "steps": [
            {"hostile": {}}, {"kill": {"text": "Kill the kidnapper"}}, {"reward": {"money": 100, "xp": 100}}]},
        "ransom": {"label": "Take the money", "then": "success", "steps": [
            {"note": {"text": "The money was taken and the matter left behind."}}, {"reward": {"money": 250, "xp": 25}}]},
    },
}

CONTRACT = {
    "title": "Contract: The Beast in the Woods",
    "type": "monsterhunt",
    "description": "A notice asks for a witcher. Something kills livestock at night.",
    "start": "after_first",
    "steps": [
        {"read": {"text": "Read the notice"}},
        {"talk": {"text": "Talk to the one who posted the contract", "dialogue": [
            {"who": "npc", "text": "You read the notice? Something tears our sheep apart. Every night.",
             "gesture": "explain", "mood": "afraid"},
            {"choice": [
                {"text": "What did you see?", "lines": [
                    {"who": "npc", "text": "Only the tracks. Big ones. Leading to the woods."}], "end": "back"},
                {"text": "I'll take the contract.", "emphasize": True, "lines": [
                    {"who": "npc", "text": "Bring me proof and the coin is yours."}], "end": "continue"}]}]}},
        {"clues": {"text": "Examine the scene with your witcher senses", "clues": [
            {"says": {"text": "Tracks... something big."}}, {"says": {"text": "Blood. Fresh."}}]}},
        {"goto": {"text": "Follow the tracks", "radius": 15}},
        {"kill": {"text": "Kill the beast"}},
        {"say": {"text": "That's that. Time to collect."}},
        {"deliver_marker": {}},
        {"reward": {"money": 300, "xp": 200}},
    ],
}

CHAPTERS = {
    "title": "Blood on the Road",
    "type": "secondary",
    "description": "A merchant's son went missing on the old trade road.",
    "steps": [
        {"chapter": {"title": "The merchant"}},
        {"talk": {"text": "Talk to the merchant", "start": "calls",
                  "call": [{"who": "npc", "text": "Witcher! Over here!"}],
                  "dialogue": [
                      {"if": {"fact": "blood_road_met", "op": ">=", "value": 1},
                       "then": {"lines": [{"who": "npc", "text": "Back again? Any news of my boy?",
                                           "mood": "nervous"}]},
                       "else": {"lines": [{"who": "npc", "text": "My son took the old road three days ago. "
                                                                   "He never came back.", "mood": "afraid"}]}}]}},
        {"fact": {"name": "blood_road_met", "value": 1}},
        {"meanwhile": {"path": "remarks"}},
        {"chapter": {"title": "The road"}},
        {"goto": {"text": "Follow the old trade road", "radius": 15}},
        {"random": {"ways": [{"path": "ambush"}, {}]}},
        {"examine": {"text": "Examine the wrecked cart"}},
        {"chapter": {"title": "The son"}},
        {"kill": {"text": "Kill the beast that took him"}},
        {"reward": {"money": 250, "xp": 150}},
    ],
    "paths": {
        "remarks": {"label": "Remarks on the way", "then": "join", "steps": [
            {"wait": {"time": "00:02:00"}}, {"say": {"text": "Tracks. A cart... and something heavy."}}]},
        "ambush": {"label": "An ambush", "then": "join", "steps": [
            {"kill": {"text": "Fight off the bandits"}}]},
    },
}

NOTICE = {                               # after Highwayman's Cache (mq1043)
    "title": "A Notice on the Board",
    "type": "secondary",
    "description": "A notice in the village asks for help - bandits on the road.",
    "steps": [
        {"notice": {"text": "Read the notice on the board", "title": "Bandits on the road!",
                    "body": "Bandits rob travellers on the river road. A reward for whoever drives them off."}},
        {"clues": {"text": "Follow the tracks with your witcher senses", "in_order": True, "clues": [
            {"says": {"text": "Boot prints. Three men, heavy loads."}}]}},
        {"talk": {"text": "Deal with the bandits", "start": "near", "radius": 10, "dialogue": [
            {"who": "npc", "text": "Lost, are we? This road has a toll."},
            {"choice": [
                {"text": "Pay with my blade.", "lines": [{"who": "npc", "text": "Get him!"}], "end": "path:fight"},
                {"text": "Leave. Now.", "axii": True, "lines": [{"who": "npc", "text": "Fine, fine. We're going."}],
                 "end": "path:peace"}]}]}},
        {"loot": {"text": "Search their cache"}},
    ],
    "paths": {
        "fight": {"label": "Fight", "then": "join", "steps": [{"kill": {"text": "Kill the bandits"}}]},
        "peace": {"label": "They leave", "then": "join", "steps": []},
    },
}

TREASURE = {                             # after Campfire Treasure (lw_de32)
    "title": "A Note and a Chest",
    "type": "treasurehunt",
    "description": "A note on a dead bandit spoke of something buried nearby.",
    "start": "after_first",
    "steps": [
        {"collect": {"text": "Take the note", "count": 1}},
        {"read": {"text": "Read the note"}},
        {"loot": {"text": "Find the treasure the note speaks of"}},
    ],
}

FISTFIGHT = {                            # after Drunken Rabble (mq1007)
    "title": "Drunks in the Way",
    "type": "secondary",
    "description": "Two drunks by the harbour want coin for another round.",
    "steps": [
        {"talk": {"text": "Deal with the drunks", "start": "near", "radius": 6, "dialogue": [
            {"who": "npc", "text": "Spare a coin for a thirsty man, master?"},
            {"choice": [
                {"text": "Here.", "pay": 25, "lines": [{"who": "npc", "text": "A true friend!"}], "end": "continue"},
                {"text": "Go home.", "axii": True, "lines": [{"who": "npc", "text": "Aye... home."}],
                 "end": "continue"},
                {"text": "Out of my way.", "lines": [{"who": "npc", "text": "Want a hiding, do you?"}],
                 "end": "path:fight"}]}]}},
    ],
    "paths": {
        "fight": {"label": "Fist fight", "then": "join", "steps": [
            {"fistfight": {"text": "Win the fist fight", "lost": "path:lost"}},
            {"reward": {"xp": 25}}]},
        "lost": {"label": "Lost", "then": "join", "steps": [{"reward": {"money": -50, "text": "Robbed"}}]},
    },
}

DELIVER = {"talk": {"text": "Bring it back", "dialogue": [
    {"who": "npc", "text": "Did you bring it?"},
    {"choice": [{"text": "Here it is.", "give": {"item": "", "count": 1}, "lines": [
        {"who": "npc", "text": "Thank you, witcher. Take this."}], "end": "continue"},
        {"text": "Not yet.", "lines": [], "end": "retry"}]}]}}

TEMPLATES = [
    ("errand", "Simple errand", "talk - go - search - bring it back", ERRAND),
    ("decision", "A decision", "a choice in a talk splits the quest in two", DECISION),
    ("contract", "Witcher contract", "notice - clues - the beast - the reward", CONTRACT),
    ("chapters", "A quest in chapters", "chapters, a lane beside the story, a random ambush, an if in a talk",
     CHAPTERS),
    ("notice", "Notice board job", "a notice - tracks - a talk with two ways - the cache", NOTICE),
    ("treasure", "Treasure hunt", "a note - read it - the chest", TREASURE),
    ("fistfight", "Fist fight", "a talk that ends in a fist fight - won or lost", FISTFIGHT),
]


def make(key):
    """A fresh copy of a template's quest (its own dicts)."""
    q = copy.deepcopy(next(t for k, _l, _w, t in TEMPLATES if k == key))
    q["steps"] = [copy.deepcopy(DELIVER) if "deliver_marker" in st else st for st in q["steps"]]
    return q
