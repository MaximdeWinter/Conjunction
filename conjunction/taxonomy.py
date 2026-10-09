"""What a thing is, where it belongs, what it can do - derived from what the game's files say about it.

Every template (and every library mesh) gets
- a type: a two level tree, "Containers/Chests", "Architecture/Walls & fences", "Creatures/Necrophages", ...
- styles: the culture or region it belongs to (Novigrad, Skellige, Toussaint, Elven, ...) and rich / poor
- traits: inventory, lootable, usable, light, destructible, quest, named

Sources, strongest first: hidden helpers (volumes, blockouts, proxies, collision) go to Internal; the entity class
(a W3NewDoor is a door, a container stays a container); the head noun of the file name, read from the back past
modifiers ("auction_house_win_a_double" -> window, "kingfisher_inn_poster" -> poster), then of the display name, of
the meshes it shows, of the folders from the deepest up; a folder word alone never moves a thing out of its folder's
domain (architecture, decorations, containers, ...); then components (light) and the path kind.

    python -m conjunction.taxonomy stats        how the database's templates spread over the tree
    python -m conjunction.taxonomy <path> ...   what one path is
"""
import os
import re
import sys

# --- the tree: (group, sub, words). Order matters: the first rule with a word in the tokens wins.
RULES = [
    ("Decoration", "Armor & weapon stands", "armor_stand armour_stand sword_stand weapon_rack weapon_stand"),
    # containers first: a "chest" is a container even in an architecture folder
    ("Containers", "Chests & strongboxes", "chest chests strongbox casket coffer lockbox strongboxes"),
    ("Containers", "Crates & boxes", "crate crates box boxes"),
    ("Containers", "Barrels", "barrel barrels cask keg"),
    ("Containers", "Sacks & baskets", "sack sacks bag bags basket baskets"),
    ("Containers", "Cupboards & drawers", "cupboard wardrobe drawer drawers dresser cabinet commode"),
    ("Containers", "Treasure & stashes", "treasure stash cache hidden"),
    ("Lights & fire", "Candles", "candle candles candleholder candlestick"),
    ("Lights & fire", "Torches", "torch torches"),
    ("Lights & fire", "Lanterns & lamps", "lantern lanterns lamp lamps chandelier chandeliers"),
    ("Lights & fire", "Fires & braziers", "brazier braziers campfire bonfire fireplace coal fire hearth"),
    ("Furniture", "Tables", "table tables desk counter"),
    ("Furniture", "Chairs & benches", "chair chairs bench benches stool stools throne armchair"),
    ("Furniture", "Beds", "bed beds bunk cradle"),
    ("Furniture", "Shelves & racks", "shelf shelves bookshelf bookcase bookstand bookstands rack racks stand"),
    ("Furniture", "Carpets & curtains", "carpet carpets rug rugs curtain curtains furs"),
    ("Vehicles & boats", "Carts & wagons", "cart carts wagon wagons carriage wheelbarrow"),
    ("Vehicles & boats", "Boats & ships", "boat boats ship ships drakkar longship raft"),
    ("Weapons & armor", "Swords", "sword swords"),
    ("Weapons & armor", "Axes & maces", "axe axes mace maces hammer club"),
    ("Weapons & armor", "Bows & crossbows", "bow bows crossbow crossbows bolt bolts arrow arrows"),
    ("Weapons & armor", "Spears & polearms", "spear spears halberd pike polearm"),
    ("Weapons & armor", "Daggers & knives", "dagger daggers knife knives"),
    ("Weapons & armor", "Shields", "shield shields"),
    ("Weapons & armor", "Scabbards", "scabbard scabbards"),
    ("Weapons & armor", "Armor & clothes", "armor armour gloves boots pants trunk helmet coif gauntlets"),
    ("Architecture", "Doors & gates", "door doors gate gates portcullis doorway"),
    ("Architecture", "Windows", "window windows shutter shutters"),
    ("Architecture", "Roofs & chimneys", "roof roofs rooftop chimney woodenroof thatched"),
    ("Architecture", "Stairs & floors", "stairs stair steps floor floors platform plattform pavement ladder ramp ceiling ceilings"),
    ("Architecture", "Walls & fences", "wall walls fence fences fances palisade balustrade railing"),
    ("Architecture", "Pillars & arches", "pillar pillars column columns arch arches archway beam beams support"),
    ("Architecture", "Bridges", "bridge bridges drawbridge"),
    ("Architecture", "Towers", "tower towers"),
    ("Architecture", "Tents & huts", "tent tents hut huts shack shed"),
    ("Architecture", "Houses & buildings", "house houses building buildings maison mansion inn room shell balcony"),
    ("Architecture", "Ruins", "ruin ruins"),
    ("Decoration", "Graves & tombs", "grave graves gravestone gravestones tomb tombs tombstone sarcophagus "
                                     "coffin"),
    ("Decoration", "Corpses & bones", "corpse corpses corps body bodies skeleton bones skull remains victim"),
    ("Decoration", "Food & drink", "food bread meat fish fruit fruits apple cheese vegetables cookie cookies "
                                   "wine beer ale ham sausage"),
    ("Decoration", "Dishes & kitchen", "plate plates bowl bowls jug jugs pot pots cup cups mug mugs dishes pan "
                                       "cauldron bottle bottles jar jars bucket buckets"),
    ("Decoration", "Books & papers", "book books letter letters note notes scroll scrolls paper map poster "
                                     "posters sketch"),
    ("Decoration", "Paintings & statues", "painting paintings statue statues bust vase trophy trophies sculpture"),
    ("Decoration", "Tools & crafting", "tool tools anvil saw pitchfork shovel rake crafting workbench grindstone "
                                       "alchemy chain chains net nets"),
    ("Decoration", "Cloth & rope", "cloth clothes rag rags fabric laundry rope ropes banner banners flag flags "
                                   "shoe shoes pillow pillows blanket blankets"),
    ("Decoration", "Blood & traces", "blood decal decals footprints traces stain"),
    ("Decoration", "Junk & debris", "junk debris rubble pile piles trash broken"),
    ("Nature", "Herbs & flowers", "herb herbs flower flowers mushroom mushrooms"),
    ("Nature", "Plants & logs", "tree trees bush bushes plant plants creeper vine vines ivy stump log logs"),
    ("Nature", "Rocks & cliffs", "rock rocks cliff cliffs boulder stone stones stalagmite stalactite"),
    ("Nature", "Ground & caves", "ground dirt cave caves ice snow mud sand"),
    ("Gameplay", "Signs & notice boards", "sign signs signboard signboards noticeboard board"),
    ("Gameplay", "Clues", "clue clues focus"),
    ("Gameplay", "Monster nests", "nest nests"),
    ("Gameplay", "Traps & mechanisms", "trap traps switch lever mechanism"),
    ("Gameplay", "Places of power", "power"),
]

# people and creatures: (group, sub, words) checked against the whole path
MONSTERS = [
    ("Necrophages", "ghoul alghoul drowner rotfiend graveir grave_hag gravehag foglet water_hag waterhag "
                    "mourntart scurver devourer"),
    ("Specters", "wraith noonwraith nightwraith penitent barghest plague_maiden pesta hym spectre specter ghost "
                 "wight beann"),
    ("Draconids", "wyvern forktail basilisk cockatrice slyzard dragon"),
    ("Hybrids", "griffin gryphon harpy siren succubus erynia archgriffin"),
    ("Insectoids", "endrega arachas kikimore kikimora scolopendromorph archespore spider"),
    ("Ogroids", "nekker troll giant cyclops ice_giant ogre"),
    ("Relicts", "fiend chort leshen shaelmaar spriggan sylvan godling doppler dopler"),
    ("Vampires", "bruxa katakan ekimmara garkain alp fleder vampire dettlaff"),
    ("Cursed ones", "werewolf botchling lubberkin"),
    ("Elementa", "golem elemental gargoyle"),
    ("Beasts", "wolf wolves warg bear bears wild_dog panther boar"),
    ("Wild Hunt", "wild_hunt wildhunt hound"),
]
ANIMALS = [
    ("Horses", "horse horses"),
    ("Birds", "bird birds crow crows seagull gull pigeon boids raven chicken hen rooster goose duck"),
    ("Farm animals", "cow cows pig pigs goat goats sheep ox"),
    ("Dogs & cats", "dog dogs cat cats"),
    ("Wild animals", "deer doe hare rabbit fox rat rats fish"),
]
PEOPLE = [
    ("Guards & soldiers", "guard guards soldier soldiers knight knights army redanian temerian nilfgaardian nilf "
                          "hunter witch_hunter witchhunter sentry"),
    ("Bandits & outlaws", "bandit bandits pirate pirates deserter deserters thug thugs brigand outlaw cutthroat "
                          "smuggler robber"),
    ("Merchants & craftsmen", "merchant merchants trader traders blacksmith armorer armourer craftsman innkeeper "
                              "herbalist shopkeeper shop shops_and_craftsmen barber baker butcher"),
    ("Nobles & wealthy", "noble nobles nobleman noblewoman aristocrat courtier rich"),
    ("Mages & priests", "mage mages sorceress sorcerer priest priestess druid druids witch witches"),
    ("Villagers & peasants", "villager villagers peasant peasants farmer farmers fisherman woodcutter miner "
                             "shepherd poor"),
    ("Townsfolk", "citizen citizens townsman townsfolk beggar beggars prostitute whore child children drunk "
                  "worker workers bard juggler fireater minstrel entertainer old_man old_woman"),
    ("Named characters", "main_npc secondary_npc main_npcs secondary_npcs"),
]
PEOPLE_CLASSES = {"CNewNPC", "CActor", "W3MerchantNPC", "W3MonsterHuntNPC", "W3NPCBackground", "CGhost"}

STYLES = [   # (style, words checked against the path)
    ("Novigrad & Redania", "novigrad nov redania redanian oxenfurt oxen"),
    ("Velen", "nml velen nomansland no_mans_land crookback"),
    ("Skellige", "skellige skelige skg trolde kaertro ard_skellig undvik an_skellig"),
    ("Kaer Morhen", "kaer_morhen morhen"),
    ("Toussaint", "bob toussaint beauclair vineyard vineyards"),
    ("White Orchard & Vizima", "prolog prologue wyzima vizima white_orchard"),
    ("Elven", "elven elf elves aen"),
    ("Dwarven", "dwarf dwarven dwarfs dwarves"),
    ("Nilfgaard", "nilfgaard nilfgaardian nilf"),
    ("Wild Hunt", "wild_hunt wildhunt naglfar"),
    ("Rich", "rich noble palace wealthy"),
    ("Poor", "poor impoverished beggar beggars slum"),
]

TRAITS = ["inventory", "lootable", "usable", "light", "destructible", "door", "quest", "named"]
LIGHTS = {"CPointLightComponent", "CSpotLightComponent", "CLightComponent"}
KIND_FALLBACK = {   # catalog.kind_of -> (group, sub) when nothing else says what it is
    "NPC": ("People", "Other people"), "Monster": ("Creatures", "Other monsters"),
    "Animal": ("Animals", "Other animals"), "Container": ("Containers", "Other containers"),
    "Decoration": ("Decoration", "Other decoration"), "Light": ("Lights & fire", "Other lights"),
    "Architecture": ("Architecture", "Other architecture"), "Furniture": ("Furniture", "Other furniture"),
    "Plant": ("Nature", "Plants & logs"), "Terrain": ("Nature", "Ground & caves"),
    "Vehicle": ("Vehicles & boats", "Other vehicles"), "Effect": ("Effects & sound", "Effects"),
    "Sound": ("Effects & sound", "Sounds"), "Gameplay": ("Gameplay", "Other gameplay"),
    "Living world": ("Gameplay", "Other gameplay"), "Item": ("Items", "Other items"),
    "Quest object": ("Quest objects", "Quest objects"), "Character part": ("Character parts", "Character parts"),
}
GROUP_ORDER = ["People", "Creatures", "Animals", "Containers", "Furniture", "Decoration", "Lights & fire",
               "Architecture", "Nature", "Vehicles & boats", "Weapons & armor", "Items", "Gameplay",
               "Effects & sound", "Quest objects", "Other", "Character parts", "Internal"]
HIDDEN_GROUPS = ("Character parts", "Internal")


def _index(rules):
    return [(g, s, set(w.split())) for g, s, w in rules]


_RULES = _index(RULES)
_MONSTERS = [(s, set(w.split())) for s, w in MONSTERS]
_ANIMALS = [(s, set(w.split())) for s, w in ANIMALS]
_PEOPLE = [(s, set(w.split())) for s, w in PEOPLE]
_STYLES = [(s, set(w.split())) for s, w in STYLES]
_SPLIT = re.compile(r"[\\/_\-\s.]+|\d+")


def _words(text):
    """'bob_elven_ruins_pillar_a' -> {bob, elven, ruins, pillar, bob_elven, elven_ruins, ...}: single words and
    neighbour pairs (for 'wild_hunt', 'kaer_morhen', 'main_npc')."""
    parts = [w for w in _SPLIT.split(text.lower()) if len(w) > 1]
    return set(parts) | {a + "_" + b for a, b in zip(parts, parts[1:])}


def _folders(path):
    """The folder names of a path, deepest first, without the dlc prefix and the generic top folders."""
    s = path.lower().split("\\")[:-1]
    if s and s[0] == "dlc":
        s = s[3:] if len(s) > 3 and s[2] == "data" else s[2:]
    return list(reversed(s))


def _first(rules, words):
    for g, s, ws in rules:
        if ws & words:
            return g, s
    return None


def _creature(words, cls, kind):
    for s, ws in _MONSTERS:
        if ws & words:
            return "Creatures", s
    for s, ws in _ANIMALS:
        if ws & words:
            return "Animals", s
    if kind == "Monster" or "monsters" in words or "monster" in words:
        return "Creatures", "Other monsters"
    if kind == "Animal" or "animals" in words:
        return "Animals", "Other animals"
    for s, ws in _PEOPLE:
        if ws & words:
            return "People", s
    return "People", "Other people"


INTERNAL = re.compile(r"^(characters\\player_entities|animations\\)|_debug\b|\\debug\\|\\test\\|_test\b|"
                      r"volume|blockout|blocker|grey_box|proxy|occluder|_col\b|collision|art_development|tech_d[e]?velopment|"
                      r"\\helpers?\\|\\test_|dummy|placeholder|_shadow\b|shadow_mesh|\\shaders?\\|\\skybox")

# words that describe, not name: skipped when the name is read from the back ("bob_house_rich_01_d_front" -> house)
MODIFIERS = set("""
a b c d e f g h i j k l m n o p q r s t u v w x y z px static dynamic lod big small medium med large huge tall short
long wide narrow thin thick old new ancient rich poor average generic gen common deco decoration decorative set sets
merged merge mesh meshes main int ext interior exterior inner outer part parts piece pieces top bottom up down left
right front back side sides middle center centre corner end half full empty open closed opened dark bright colour
color colours colors red blue green white black yellow brown grey gray gold golden silver wooden wood stone stones
metal iron steel brick bricks straight bend round square flat double single triple simple complex basic unique var
variant version copy noshadow emisiv emissive hd lowpoly low high lvl level snow snowy wet dirty clean mossy moss
burned burnt burning ruined destroyed broken damaged cracked crack fallen rotten muddy frozen bloody covered with and
of the on in for no mh dao ekimma pc ps ns tm us ca ep ep1 ep2 bob nov nml skg km prolog novigrad skellige skelige
velen toussaint beauclair redania kaer morhen trolde kaertro wyzima vizima nilfgaard nilfgaardian elven dwarven
dwarf oxenfurt temeria temerian aen
""".split())
# short forms seen in file names
ALIASES = {"win": "window", "wnd": "window", "cont": "container", "brl": "barrel", "chr": "chair", "tbl": "table",
           "shlf": "shelf", "cndl": "candle", "stair": "stairs", "plattform": "platform", "fances": "fence"}


def _index_nouns():
    out = {}
    for g, s, ws in _RULES:
        for w in ws:
            out.setdefault(w, (g, s))
    out["container"] = ("Containers", "Other containers")
    return out


NOUNS = _index_nouns()
CONTAINER_BODIES = {"corpse", "corpses", "corps", "body", "bodies", "skeleton", "remains", "victim", "bones"}
# a folder names the domain when the name itself does not say what it is
DOMAINS = [("architecture", ("Architecture", "Other architecture")),
           ("containers", ("Containers", "Other containers")),
           ("light_sources", ("Lights & fire", "Other lights")), ("lightsources", ("Lights & fire", "Other lights")),
           ("furniture", ("Furniture", "Other furniture")),
           ("corpses", ("Decoration", "Corpses & bones")),
           ("vegetation", ("Nature", "Plants & logs")), ("terrain_surroundings", ("Nature", "Rocks & cliffs")),
           ("decorations", ("Decoration", "Other decoration")), ("decoration", ("Decoration", "Other decoration")),
           ("ships", ("Vehicles & boats", "Boats & ships")), ("vehicles", ("Vehicles & boats", "Other vehicles"))]


def _tokens(text):
    return [ALIASES.get(w, w) for w in _SPLIT.split(text.lower()) if w]


def head_noun(text):
    """What a name is: read from the back, the first word (or word pair) that names a thing - modifiers, letters
    and numbers are skipped. 'auction_house_win_a_double' -> window, 'kingfisher_inn_poster' -> poster."""
    ws = _tokens(text)
    for i in range(len(ws) - 1, -1, -1):
        if i > 0 and f"{ws[i - 1]}_{ws[i]}" in NOUNS:
            return f"{ws[i - 1]}_{ws[i]}"
        w = ws[i]
        if w in MODIFIERS or len(w) < 3 or w.isdigit():
            continue
        if w in NOUNS:
            return w
    return None


def _is_container(cls):
    return "Container" in cls or cls in ("W3ClueStash", "W3treasureHuntContainer", "W3ActorRemains")


def classify(path, cls="", components=(), kind="", name="", meshes=()):
    """(group, sub) of a template or mesh. Strongest first: hidden helpers, the class, the head noun of the file
    name (then of the display name, of the meshes it shows, of the folders from the deepest up), the folder's
    domain, components, the path kind. `name`: display name, `meshes`: the template's mesh paths."""
    path = path.lower()
    base = os.path.splitext(os.path.basename(path))[0]
    allw = _words(path) | _words(name)
    comps = set(components or ())
    if INTERNAL.search(path):
        return "Internal", "Internal"
    if kind == "Character part" or ("\\bodyparts\\" in path and "armor_stand" not in path):
        return "Character parts", "Character parts"
    # the class says it for sure
    if cls == "CActionPoint":
        return "Gameplay", "Work & idle spots"
    if cls in PEOPLE_CLASSES or kind in ("NPC", "Monster", "Animal"):
        return _creature(allw, cls, kind)
    if "Door" in cls:
        return "Architecture", "Doors & gates"
    if cls == "W3Herb":
        return "Nature", "Herbs & flowers"
    if cls == "CMonsterNestEntity":
        return "Gameplay", "Monster nests"
    if cls == "CTeleportEntity" or "fast_travel" in path:
        return "Gameplay", "Fast travel & teleports"
    if cls in ("W3Poster", "W3Signboard", "W3NoticeBoard"):
        return "Gameplay", "Signs & notice boards"
    if cls == "CStaticCamera":
        return "Gameplay", "Cameras"
    if cls in ("CWitcherSword", "W3ImprovedSword"):         # a sword, whatever its name (a 'cleaver' is no kitchen)
        return "Weapons & armor", "Swords"
    if kind in ("Effect", "Sound"):
        return KIND_FALLBACK[kind]
    if "abilities" in path.split("\\"):
        return "Gameplay", "Abilities & spells"
    # the head noun: file name, display name, the meshes it shows, the folders from the deepest up
    noun = head_noun(base) or (head_noun(name) if name else None)
    for m in meshes or ():
        if noun:
            break
        noun = head_noun(os.path.splitext(os.path.basename(m))[0])
    folder_noun = None
    if not noun:
        for folder in _folders(path):
            folder_noun = head_noun(folder)
            if folder_noun:
                break
    hit = NOUNS.get(noun or folder_noun) if (noun or folder_noun) else None
    # a container (the class): sorted among the containers by what it looks like
    if _is_container(cls):
        if hit and hit[0] == "Containers":
            return hit
        if noun in CONTAINER_BODIES or allw & CONTAINER_BODIES:
            return "Containers", "Bodies & remains"
        return "Containers", "Other containers"
    if cls in ("W3MonsterClue", "W3DestroyableClue", "W3MonsterClueScent", "W3ClueCorpse"):
        return ("Decoration", "Corpses & bones") if noun in CONTAINER_BODIES else ("Gameplay", "Clues")
    if hit:
        g, s = hit
        # a weapon word in a decoration's name ("sword_rack") is not a weapon to pick up
        if g == "Weapons & armor" and cls not in ("CItemEntity", "CWitcherSword", "Crossbow") and \
                not path.startswith("items\\"):
            g, s = ("Furniture", "Shelves & racks") if allw & {"stand", "rack", "racks"} else \
                ("Decoration", "Weapons on display")
        # a folder word alone does not move a thing out of its folder's domain ("grey_box_blockout\\quarry")
        if not noun:
            for key, dom in DOMAINS:
                if f"\\{key}\\" in f"\\{path}" and dom[0] != g:
                    return dom
        return g, s
    for key, dom in DOMAINS:
        if f"\\{key}\\" in f"\\{path}":
            return dom
    if comps & LIGHTS:
        return "Lights & fire", "Other lights"
    if "horse_items" in path:
        return "Items", "Horse gear"
    if path.startswith("items\\") or "\\items\\" in path:
        if "quest_items" in path:
            return "Items", "Quest items"
        if "readable_books" in path:
            return "Items", "Books & notes"
        return "Items", "Other items"
    return KIND_FALLBACK.get(kind, ("Other", "Other"))


def styles(path, name=""):
    words = _words(path + " " + name)
    return [s for s, ws in _STYLES if ws & words]


def traits(path, cls="", components=(), inventory=False, loot=(), name_known=False):
    comps = set(components or ())
    out = []
    if inventory:
        out.append("inventory")
    if loot or "Container" in cls:
        out.append("lootable")
    if "CInteractionComponent" in comps or "Container" in cls or "Door" in cls or cls in (
            "W3Herb", "W3Poster", "W3Signboard", "W3QuestUsableItem", "W3FireSource", "W3Campfire"):
        out.append("usable")
    if comps & LIGHTS or cls in ("W3FireSource", "W3Campfire"):
        out.append("light")
    if "Destroyable" in cls or "Destructible" in cls or "CDestructionSystemComponent" in comps or \
            "CDestructionComponent" in comps:
        out.append("destructible")
    if "Door" in cls:
        out.append("door")
    if "\\quest" in "\\" + path.lower():
        out.append("quest")
    if name_known:
        out.append("named")
    return out


# --- items: the item definitions' category and tags -> (group, sub)
ITEM_CATEGORIES = [
    ("Weapons", "Steel swords", "steelsword"),
    ("Weapons", "Silver swords", "silversword"),
    ("Weapons", "Crossbows & bolts", "crossbow bolt bow"),
    ("Weapons", "Other weapons", "secondary axe1h axe2h blunt1h hammer2h halberd2h spear2h staff2h cleaver1h "
                                 "polearm shield"),
    ("Weapons", "Monster weapons", "monster_weapon"),
    ("Armor", "Chest armor", "armor"),
    ("Armor", "Gloves", "gloves"),
    ("Armor", "Trousers", "pants"),
    ("Armor", "Boots", "boots"),
    ("Armor", "Masks", "mask"),
    ("Armor", "Scabbards", "steel_scabbards silver_scabbards"),
    ("Armor", "Upgrades & runes", "upgrade"),
    ("Alchemy", "Potions", "potion"),
    ("Alchemy", "Oils", "oil"),
    ("Alchemy", "Bombs", "petard"),
    ("Alchemy", "Ingredients", "alchemy_ingredient"),
    ("Alchemy", "Formulae", "alchemy_recipe"),
    ("Crafting", "Diagrams", "crafting_schematic"),
    ("Crafting", "Materials", "crafting_ingredient"),
    ("Food & drink", "Food & drink", "edibles"),
    ("Books & notes", "Books", "book cooking_recipe"),
    ("Gwent", "Gwent cards", "gwint"),
    ("Keys", "Keys", "key"),
    ("Trophies", "Trophies", "trophy"),
    ("Horse gear", "Horse gear", "horse_saddle horse_blinder horse_bag horse_tail horse_reins horse_harness "
                                 "horse_hair"),
    ("Junk & valuables", "Junk & valuables", "junk"),
    ("Internal", "Internal", "head hair fist"),
]
_ITEM_CAT = {c: (g, s) for g, s, cs in ITEM_CATEGORIES for c in cs.split()}
ITEM_GROUP_ORDER = ["Weapons", "Armor", "Alchemy", "Crafting", "Food & drink", "Books & notes", "Quest items",
                    "Junk & valuables", "Keys", "Trophies", "Gwent", "Horse gear", "Tools & everyday things",
                    "Other", "Internal"]


def classify_item(category, tags):
    tags = set(tags.split() if isinstance(tags, str) else tags)
    hit = _ITEM_CAT.get(category)
    if hit and not (hit[0] in ("Books & notes", "Junk & valuables", "Food & drink") and "Quest" in tags):
        return hit
    if "Quest" in tags:
        return "Quest items", "Quest items"
    if tags & {"ReadableItem", "mod_book", "NoticeBoardNote", "ThMap"}:
        return "Books & notes", "Notes & maps" if tags & {"NoticeBoardNote", "ThMap"} else "Books"
    if tags & {"mod_junk", "Junk"}:
        return "Junk & valuables", "Junk & valuables"
    if tags & {"mod_food", "Edibles"}:
        return "Food & drink", "Food & drink"
    if category in ("work", "work_secondary", "tool", "usable", "decorations", "lute"):
        return "Tools & everyday things", "Tools & everyday things"
    return "Other", "Other"


def sort_groups(names, order=None):
    order = order or GROUP_ORDER
    return sorted(names, key=lambda g: (order.index(g) if g in order else len(order), g))


def main():
    args = sys.argv[1:]
    if args and args[0] == "stats":
        import collections
        import json
        import sqlite3

        from .assets import DB
        db = sqlite3.connect(DB)
        cnt = collections.Counter()
        sty = collections.Counter()
        for path, cls, comps, kind, name, meshes in db.execute(
                "select path, class, components, kind, name, meshes from templates"):
            g, s = classify(path, cls, json.loads(comps or "[]"), kind, name, json.loads(meshes or "[]"))
            cnt[(g, s)] += 1
            for st in styles(path):
                sty[st] += 1
        for g in sort_groups({g for g, _ in cnt}):
            subs = sorted(((s, n) for (gg, s), n in cnt.items() if gg == g), key=lambda x: -x[1])
            print(f"{g:22} {sum(n for _, n in subs):6}   " + ", ".join(f"{s} {n}" for s, n in subs))
        print()
        print(", ".join(f"{s} {n}" for s, n in sty.most_common()))
        return
    for p in args:
        print(p, classify(p), styles(p))


if __name__ == "__main__":
    main()
