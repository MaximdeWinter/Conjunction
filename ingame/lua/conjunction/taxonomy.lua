-- What a thing is, where it belongs, what it can do (conjunction/taxonomy.py, rule for rule): a two level type,
-- styles, traits for templates and library meshes; item groups. Checked against Python: ingame/ref/taxonomy_check.py.
--   T.classify(path, cls, components, kind, name, meshes) -> group, sub
--   T.styles(path [, name]) -> {style ...};  T.traits(path, cls, components, inventory, loot, name_known) -> {...}
--   T.classify_item(category, tags) -> group, sub;  T.words(text) -> {word = true}  (taxonomy._words)
local S = require("conjunction.pystr")
local R = require("conjunction.pyre")
local PATHS = require("conjunction.paths")
local T = {}

local function wordset(s)
  local out = {}
  for _, w in ipairs(S.split(s)) do out[w] = true end
  return out
end
local function meets(a, b)            -- a & b is not empty
  for w in pairs(a) do if b[w] then return true end end
  return false
end

T.RULES = {
  {"Decoration", "Armor & weapon stands", "armor_stand armour_stand sword_stand weapon_rack weapon_stand"},
  {"Containers", "Chests & strongboxes", "chest chests strongbox casket coffer lockbox strongboxes"},
  {"Containers", "Crates & boxes", "crate crates box boxes"},
  {"Containers", "Barrels", "barrel barrels cask keg"},
  {"Containers", "Sacks & baskets", "sack sacks bag bags basket baskets"},
  {"Containers", "Cupboards & drawers", "cupboard wardrobe drawer drawers dresser cabinet commode"},
  {"Containers", "Treasure & stashes", "treasure stash cache hidden"},
  {"Lights & fire", "Candles", "candle candles candleholder candlestick"},
  {"Lights & fire", "Torches", "torch torches"},
  {"Lights & fire", "Lanterns & lamps", "lantern lanterns lamp lamps chandelier chandeliers"},
  {"Lights & fire", "Fires & braziers", "brazier braziers campfire bonfire fireplace coal fire hearth"},
  {"Furniture", "Tables", "table tables desk counter"},
  {"Furniture", "Chairs & benches", "chair chairs bench benches stool stools throne armchair"},
  {"Furniture", "Beds", "bed beds bunk cradle"},
  {"Furniture", "Shelves & racks", "shelf shelves bookshelf bookcase bookstand bookstands rack racks stand"},
  {"Furniture", "Carpets & curtains", "carpet carpets rug rugs curtain curtains furs"},
  {"Vehicles & boats", "Carts & wagons", "cart carts wagon wagons carriage wheelbarrow"},
  {"Vehicles & boats", "Boats & ships", "boat boats ship ships drakkar longship raft"},
  {"Weapons & armor", "Swords", "sword swords"},
  {"Weapons & armor", "Axes & maces", "axe axes mace maces hammer club"},
  {"Weapons & armor", "Bows & crossbows", "bow bows crossbow crossbows bolt bolts arrow arrows"},
  {"Weapons & armor", "Spears & polearms", "spear spears halberd pike polearm"},
  {"Weapons & armor", "Daggers & knives", "dagger daggers knife knives"},
  {"Weapons & armor", "Shields", "shield shields"},
  {"Weapons & armor", "Scabbards", "scabbard scabbards"},
  {"Weapons & armor", "Armor & clothes", "armor armour gloves boots pants trunk helmet coif gauntlets"},
  {"Architecture", "Doors & gates", "door doors gate gates portcullis doorway"},
  {"Architecture", "Windows", "window windows shutter shutters"},
  {"Architecture", "Roofs & chimneys", "roof roofs rooftop chimney woodenroof thatched"},
  {"Architecture", "Stairs & floors",
   "stairs stair steps floor floors platform plattform pavement ladder ramp ceiling ceilings"},
  {"Architecture", "Walls & fences", "wall walls fence fences fances palisade balustrade railing"},
  {"Architecture", "Pillars & arches", "pillar pillars column columns arch arches archway beam beams support"},
  {"Architecture", "Bridges", "bridge bridges drawbridge"},
  {"Architecture", "Towers", "tower towers"},
  {"Architecture", "Tents & huts", "tent tents hut huts shack shed"},
  {"Architecture", "Houses & buildings", "house houses building buildings maison mansion inn room shell balcony"},
  {"Architecture", "Ruins", "ruin ruins"},
  {"Decoration", "Graves & tombs", "grave graves gravestone gravestones tomb tombs tombstone sarcophagus coffin"},
  {"Decoration", "Corpses & bones", "corpse corpses corps body bodies skeleton bones skull remains victim"},
  {"Decoration", "Food & drink",
   "food bread meat fish fruit fruits apple cheese vegetables cookie cookies wine beer ale ham sausage"},
  {"Decoration", "Dishes & kitchen",
   "plate plates bowl bowls jug jugs pot pots cup cups mug mugs dishes pan cauldron bottle bottles jar jars bucket buckets"},
  {"Decoration", "Books & papers",
   "book books letter letters note notes scroll scrolls paper map poster posters sketch"},
  {"Decoration", "Paintings & statues", "painting paintings statue statues bust vase trophy trophies sculpture"},
  {"Decoration", "Tools & crafting",
   "tool tools anvil saw pitchfork shovel rake crafting workbench grindstone alchemy chain chains net nets"},
  {"Decoration", "Cloth & rope",
   "cloth clothes rag rags fabric laundry rope ropes banner banners flag flags shoe shoes pillow pillows blanket blankets"},
  {"Decoration", "Blood & traces", "blood decal decals footprints traces stain"},
  {"Decoration", "Junk & debris", "junk debris rubble pile piles trash broken"},
  {"Nature", "Herbs & flowers", "herb herbs flower flowers mushroom mushrooms"},
  {"Nature", "Plants & logs", "tree trees bush bushes plant plants creeper vine vines ivy stump log logs"},
  {"Nature", "Rocks & cliffs", "rock rocks cliff cliffs boulder stone stones stalagmite stalactite"},
  {"Nature", "Ground & caves", "ground dirt cave caves ice snow mud sand"},
  {"Gameplay", "Signs & notice boards", "sign signs signboard signboards noticeboard board"},
  {"Gameplay", "Clues", "clue clues focus"},
  {"Gameplay", "Monster nests", "nest nests"},
  {"Gameplay", "Traps & mechanisms", "trap traps switch lever mechanism"},
  {"Gameplay", "Places of power", "power"},
}
T.MONSTERS = {
  {"Necrophages", "ghoul alghoul drowner rotfiend graveir grave_hag gravehag foglet water_hag waterhag mourntart scurver devourer"},
  {"Specters", "wraith noonwraith nightwraith penitent barghest plague_maiden pesta hym spectre specter ghost wight beann"},
  {"Draconids", "wyvern forktail basilisk cockatrice slyzard dragon"},
  {"Hybrids", "griffin gryphon harpy siren succubus erynia archgriffin"},
  {"Insectoids", "endrega arachas kikimore kikimora scolopendromorph archespore spider"},
  {"Ogroids", "nekker troll giant cyclops ice_giant ogre"},
  {"Relicts", "fiend chort leshen shaelmaar spriggan sylvan godling doppler dopler"},
  {"Vampires", "bruxa katakan ekimmara garkain alp fleder vampire dettlaff"},
  {"Cursed ones", "werewolf botchling lubberkin"},
  {"Elementa", "golem elemental gargoyle"},
  {"Beasts", "wolf wolves warg bear bears wild_dog panther boar"},
  {"Wild Hunt", "wild_hunt wildhunt hound"},
}
T.ANIMALS = {
  {"Horses", "horse horses"},
  {"Birds", "bird birds crow crows seagull gull pigeon boids raven chicken hen rooster goose duck"},
  {"Farm animals", "cow cows pig pigs goat goats sheep ox"},
  {"Dogs & cats", "dog dogs cat cats"},
  {"Wild animals", "deer doe hare rabbit fox rat rats fish"},
}
T.PEOPLE = {
  {"Guards & soldiers", "guard guards soldier soldiers knight knights army redanian temerian nilfgaardian nilf hunter witch_hunter witchhunter sentry"},
  {"Bandits & outlaws", "bandit bandits pirate pirates deserter deserters thug thugs brigand outlaw cutthroat smuggler robber"},
  {"Merchants & craftsmen", "merchant merchants trader traders blacksmith armorer armourer craftsman innkeeper herbalist shopkeeper shop shops_and_craftsmen barber baker butcher"},
  {"Nobles & wealthy", "noble nobles nobleman noblewoman aristocrat courtier rich"},
  {"Mages & priests", "mage mages sorceress sorcerer priest priestess druid druids witch witches"},
  {"Villagers & peasants", "villager villagers peasant peasants farmer farmers fisherman woodcutter miner shepherd poor"},
  {"Townsfolk", "citizen citizens townsman townsfolk beggar beggars prostitute whore child children drunk worker workers bard juggler fireater minstrel entertainer old_man old_woman"},
  {"Named characters", "main_npc secondary_npc main_npcs secondary_npcs"},
}
local PEOPLE_CLASSES = {CNewNPC = true, CActor = true, W3MerchantNPC = true, W3MonsterHuntNPC = true,
                        W3NPCBackground = true, CGhost = true}
T.STYLES = {
  {"Novigrad & Redania", "novigrad nov redania redanian oxenfurt oxen"},
  {"Velen", "nml velen nomansland no_mans_land crookback"},
  {"Skellige", "skellige skelige skg trolde kaertro ard_skellig undvik an_skellig"},
  {"Kaer Morhen", "kaer_morhen morhen"},
  {"Toussaint", "bob toussaint beauclair vineyard vineyards"},
  {"White Orchard & Vizima", "prolog prologue wyzima vizima white_orchard"},
  {"Elven", "elven elf elves aen"},
  {"Dwarven", "dwarf dwarven dwarfs dwarves"},
  {"Nilfgaard", "nilfgaard nilfgaardian nilf"},
  {"Wild Hunt", "wild_hunt wildhunt naglfar"},
  {"Rich", "rich noble palace wealthy"},
  {"Poor", "poor impoverished beggar beggars slum"},
}
T.TRAITS = {"inventory", "lootable", "usable", "light", "destructible", "door", "quest", "named"}
local LIGHTS = {CPointLightComponent = true, CSpotLightComponent = true, CLightComponent = true}
T.KIND_FALLBACK = {
  NPC = {"People", "Other people"}, Monster = {"Creatures", "Other monsters"},
  Animal = {"Animals", "Other animals"}, Container = {"Containers", "Other containers"},
  Decoration = {"Decoration", "Other decoration"}, Light = {"Lights & fire", "Other lights"},
  Architecture = {"Architecture", "Other architecture"}, Furniture = {"Furniture", "Other furniture"},
  Plant = {"Nature", "Plants & logs"}, Terrain = {"Nature", "Ground & caves"},
  Vehicle = {"Vehicles & boats", "Other vehicles"}, Effect = {"Effects & sound", "Effects"},
  Sound = {"Effects & sound", "Sounds"}, Gameplay = {"Gameplay", "Other gameplay"},
  ["Living world"] = {"Gameplay", "Other gameplay"}, Item = {"Items", "Other items"},
  ["Quest object"] = {"Quest objects", "Quest objects"}, ["Character part"] = {"Character parts", "Character parts"},
}
-- the content packs' things: a group of their own, each pack a branch of it (MaximdeWinter 13.11.: 582 crates of the game
-- around a pack's one; the group alone searches what is not the game's)
T.PACKS = "Content packs"
T.GROUP_ORDER = {"Content packs", "People", "Creatures", "Animals", "Containers", "Furniture", "Decoration", "Lights & fire",
                 "Architecture", "Nature", "Vehicles & boats", "Weapons & armor", "Items", "Gameplay",
                 "Effects & sound", "Quest objects", "Other", "Character parts", "Internal"}
T.HIDDEN_GROUPS = {["Character parts"] = true, Internal = true}

local function index(rules, with_sub)
  local out = {}
  for k, r in ipairs(rules) do
    if with_sub then out[k] = {r[1], r[2], wordset(r[3])} else out[k] = {r[1], wordset(r[2])} end
  end
  return out
end
local _RULES, _MONSTERS, _ANIMALS = index(T.RULES, true), index(T.MONSTERS), index(T.ANIMALS)
local _PEOPLE, _STYLES = index(T.PEOPLE), index(T.STYLES)
local SPLIT = R.compile([[[\\/_\-\s.]+|\d+]])

-- 'bob_elven_ruins_pillar_a' -> its words longer than one letter and their neighbour pairs (a set: {w = true})
function T.words(text)
  local parts = {}
  for _, w in ipairs(SPLIT:split(S.lower(text))) do
    if S.len(w) > 1 then parts[#parts + 1] = w end
  end
  local out = {}
  for i, w in ipairs(parts) do
    out[w] = true
    if parts[i + 1] then out[w .. "_" .. parts[i + 1]] = true end
  end
  return out
end
local function union(a, b)
  local out = {}
  for w in pairs(a) do out[w] = true end
  for w in pairs(b) do out[w] = true end
  return out
end

-- the folder names of a path, deepest first, without the dlc prefix
local function folders(path)
  local s = {}
  for part in (S.lower(path) .. "\\"):gmatch("(.-)\\") do s[#s + 1] = part end
  s[#s] = nil                                         -- (the file)
  if s[1] == "dlc" then
    local from = (#s > 3 and s[3] == "data") and 4 or 3
    local cut = {}
    for k = from, #s do cut[#cut + 1] = s[k] end
    s = cut
  end
  local out = {}
  for k = #s, 1, -1 do out[#out + 1] = s[k] end
  return out
end

local function creature(words, kind)
  for _, r in ipairs(_MONSTERS) do if meets(r[2], words) then return "Creatures", r[1] end end
  for _, r in ipairs(_ANIMALS) do if meets(r[2], words) then return "Animals", r[1] end end
  if kind == "Monster" or words.monsters or words.monster then return "Creatures", "Other monsters" end
  if kind == "Animal" or words.animals then return "Animals", "Other animals" end
  for _, r in ipairs(_PEOPLE) do if meets(r[2], words) then return "People", r[1] end end
  return "People", "Other people"
end

local INTERNAL = R.compile([[^(characters\\player_entities|animations\\)|_debug\b|\\debug\\|\\test\\|_test\b|]] ..
                           [[volume|blockout|blocker|grey_box|proxy|occluder|_col\b|collision|art_development|tech_d[e]?velopment|]] ..
                           [[\\helpers?\\|\\test_|dummy|placeholder|_shadow\b|shadow_mesh|\\shaders?\\|\\skybox]])

T.MODIFIERS = wordset([[
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
]])
T.ALIASES = {win = "window", wnd = "window", cont = "container", brl = "barrel", chr = "chair", tbl = "table",
             shlf = "shelf", cndl = "candle", stair = "stairs", plattform = "platform", fances = "fence"}

-- every word of every rule -> the first rule's (group, sub)
T.NOUNS = {}
for _, r in ipairs(_RULES) do
  for w in pairs(r[3]) do if T.NOUNS[w] == nil then T.NOUNS[w] = {r[1], r[2]} end end
end
T.NOUNS.container = {"Containers", "Other containers"}
local CONTAINER_BODIES = wordset("corpse corpses corps body bodies skeleton remains victim bones")
local DOMAINS = {{"architecture", {"Architecture", "Other architecture"}},
                 {"containers", {"Containers", "Other containers"}},
                 {"light_sources", {"Lights & fire", "Other lights"}}, {"lightsources", {"Lights & fire", "Other lights"}},
                 {"furniture", {"Furniture", "Other furniture"}},
                 {"corpses", {"Decoration", "Corpses & bones"}},
                 {"vegetation", {"Nature", "Plants & logs"}}, {"terrain_surroundings", {"Nature", "Rocks & cliffs"}},
                 {"decorations", {"Decoration", "Other decoration"}}, {"decoration", {"Decoration", "Other decoration"}},
                 {"ships", {"Vehicles & boats", "Boats & ships"}}, {"vehicles", {"Vehicles & boats", "Other vehicles"}}}

local function tokens(text)
  local out = {}
  for _, w in ipairs(SPLIT:split(S.lower(text))) do
    if w ~= "" then out[#out + 1] = T.ALIASES[w] or w end
  end
  return out
end

-- what a name is: read from the back, the first word (or word pair) that names a thing
function T.head_noun(text)
  local ws = tokens(text)
  for i = #ws, 1, -1 do
    if i > 1 and T.NOUNS[ws[i - 1] .. "_" .. ws[i]] then return ws[i - 1] .. "_" .. ws[i] end
    local w = ws[i]
    if not (T.MODIFIERS[w] or S.len(w) < 3 or S.isdigit(w)) and T.NOUNS[w] then return w end
  end
  return nil
end

local function is_container(cls)
  return cls:find("Container", 1, true) ~= nil or cls == "W3ClueStash" or cls == "W3treasureHuntContainer" or
         cls == "W3ActorRemains"
end
local function has(s, part) return s:find(part, 1, true) ~= nil end

function T.classify(path, cls, components, kind, name, meshes)
  cls, kind, name = cls or "", kind or "", name or ""
  path = S.lower(path)
  local base = PATHS.splitext(PATHS.basename(path))
  local allw = union(T.words(path), T.words(name))
  local comps = {}
  for _, c in ipairs(components or {}) do comps[c] = true end
  if INTERNAL:search(path) then return "Internal", "Internal" end
  if kind == "Character part" or (has(path, "\\bodyparts\\") and not has(path, "armor_stand")) then
    return "Character parts", "Character parts"
  end
  if cls == "CActionPoint" then return "Gameplay", "Work & idle spots" end
  if PEOPLE_CLASSES[cls] or kind == "NPC" or kind == "Monster" or kind == "Animal" then return creature(allw, kind) end
  if has(cls, "Door") then return "Architecture", "Doors & gates" end
  if cls == "W3Herb" then return "Nature", "Herbs & flowers" end
  if cls == "CMonsterNestEntity" then return "Gameplay", "Monster nests" end
  if cls == "CTeleportEntity" or has(path, "fast_travel") then return "Gameplay", "Fast travel & teleports" end
  if cls == "W3Poster" or cls == "W3Signboard" or cls == "W3NoticeBoard" then return "Gameplay", "Signs & notice boards" end
  if cls == "CStaticCamera" then return "Gameplay", "Cameras" end
  if cls == "CWitcherSword" or cls == "W3ImprovedSword" then return "Weapons & armor", "Swords" end
  if kind == "Effect" or kind == "Sound" then return T.KIND_FALLBACK[kind][1], T.KIND_FALLBACK[kind][2] end
  for part in (path .. "\\"):gmatch("(.-)\\") do
    if part == "abilities" then return "Gameplay", "Abilities & spells" end
  end
  local noun = T.head_noun(base) or (name ~= "" and T.head_noun(name) or nil)
  for _, m in ipairs(meshes or {}) do
    if noun then break end
    noun = T.head_noun((PATHS.splitext(PATHS.basename(m))))
  end
  local folder_noun
  if not noun then
    for _, folder in ipairs(folders(path)) do
      folder_noun = T.head_noun(folder)
      if folder_noun then break end
    end
  end
  local hit = (noun or folder_noun) and T.NOUNS[noun or folder_noun] or nil
  if is_container(cls) then
    if hit and hit[1] == "Containers" then return hit[1], hit[2] end
    if (noun and CONTAINER_BODIES[noun]) or meets(allw, CONTAINER_BODIES) then return "Containers", "Bodies & remains" end
    return "Containers", "Other containers"
  end
  if cls == "W3MonsterClue" or cls == "W3DestroyableClue" or cls == "W3MonsterClueScent" or cls == "W3ClueCorpse" then
    if noun and CONTAINER_BODIES[noun] then return "Decoration", "Corpses & bones" end
    return "Gameplay", "Clues"
  end
  if hit then
    local g, s = hit[1], hit[2]
    if g == "Weapons & armor" and cls ~= "CItemEntity" and cls ~= "CWitcherSword" and cls ~= "Crossbow" and
       path:sub(1, 6) ~= "items\\" then
      if allw.stand or allw.rack or allw.racks then g, s = "Furniture", "Shelves & racks"
      else g, s = "Decoration", "Weapons on display" end
    end
    if not noun then
      for _, d in ipairs(DOMAINS) do
        if has("\\" .. path, "\\" .. d[1] .. "\\") and d[2][1] ~= g then return d[2][1], d[2][2] end
      end
    end
    return g, s
  end
  for _, d in ipairs(DOMAINS) do
    if has("\\" .. path, "\\" .. d[1] .. "\\") then return d[2][1], d[2][2] end
  end
  if meets(comps, LIGHTS) then return "Lights & fire", "Other lights" end
  if has(path, "horse_items") then return "Items", "Horse gear" end
  if path:sub(1, 6) == "items\\" or has(path, "\\items\\") then
    if has(path, "quest_items") then return "Items", "Quest items" end
    if has(path, "readable_books") then return "Items", "Books & notes" end
    return "Items", "Other items"
  end
  local fb = T.KIND_FALLBACK[kind]
  if fb then return fb[1], fb[2] end
  return "Other", "Other"
end

function T.styles(path, name)
  local words = T.words(path .. " " .. (name or ""))
  local out = {}
  for _, r in ipairs(_STYLES) do if meets(r[2], words) then out[#out + 1] = r[1] end end
  return out
end

function T.traits(path, cls, components, inventory, loot, name_known)
  cls = cls or ""
  local comps = {}
  for _, c in ipairs(components or {}) do comps[c] = true end
  local out = {}
  if inventory then out[#out + 1] = "inventory" end
  if (loot and next(loot) ~= nil) or has(cls, "Container") then out[#out + 1] = "lootable" end
  if comps.CInteractionComponent or has(cls, "Container") or has(cls, "Door") or cls == "W3Herb" or
     cls == "W3Poster" or cls == "W3Signboard" or cls == "W3QuestUsableItem" or cls == "W3FireSource" or
     cls == "W3Campfire" then
    out[#out + 1] = "usable"
  end
  if meets(comps, LIGHTS) or cls == "W3FireSource" or cls == "W3Campfire" then out[#out + 1] = "light" end
  if has(cls, "Destroyable") or has(cls, "Destructible") or comps.CDestructionSystemComponent or
     comps.CDestructionComponent then
    out[#out + 1] = "destructible"
  end
  if has(cls, "Door") then out[#out + 1] = "door" end
  if has("\\" .. S.lower(path), "\\quest") then out[#out + 1] = "quest" end
  if name_known then out[#out + 1] = "named" end
  return out
end

T.ITEM_CATEGORIES = {
  {"Weapons", "Steel swords", "steelsword"},
  {"Weapons", "Silver swords", "silversword"},
  {"Weapons", "Crossbows & bolts", "crossbow bolt bow"},
  {"Weapons", "Other weapons", "secondary axe1h axe2h blunt1h hammer2h halberd2h spear2h staff2h cleaver1h polearm shield"},
  {"Weapons", "Monster weapons", "monster_weapon"},
  {"Armor", "Chest armor", "armor"},
  {"Armor", "Gloves", "gloves"},
  {"Armor", "Trousers", "pants"},
  {"Armor", "Boots", "boots"},
  {"Armor", "Masks", "mask"},
  {"Armor", "Scabbards", "steel_scabbards silver_scabbards"},
  {"Armor", "Upgrades & runes", "upgrade"},
  {"Alchemy", "Potions", "potion"},
  {"Alchemy", "Oils", "oil"},
  {"Alchemy", "Bombs", "petard"},
  {"Alchemy", "Ingredients", "alchemy_ingredient"},
  {"Alchemy", "Formulae", "alchemy_recipe"},
  {"Crafting", "Diagrams", "crafting_schematic"},
  {"Crafting", "Materials", "crafting_ingredient"},
  {"Food & drink", "Food & drink", "edibles"},
  {"Books & notes", "Books", "book cooking_recipe"},
  {"Gwent", "Gwent cards", "gwint"},
  {"Keys", "Keys", "key"},
  {"Trophies", "Trophies", "trophy"},
  {"Horse gear", "Horse gear", "horse_saddle horse_blinder horse_bag horse_tail horse_reins horse_harness horse_hair"},
  {"Junk & valuables", "Junk & valuables", "junk"},
  {"Internal", "Internal", "head hair fist"},
}
local ITEM_CAT = {}
for _, r in ipairs(T.ITEM_CATEGORIES) do
  for _, c in ipairs(S.split(r[3])) do ITEM_CAT[c] = {r[1], r[2]} end
end
T.ITEM_GROUP_ORDER = {"Weapons", "Armor", "Alchemy", "Crafting", "Food & drink", "Books & notes", "Quest items",
                      "Junk & valuables", "Keys", "Trophies", "Gwent", "Horse gear", "Tools & everyday things",
                      "Other", "Internal"}

function T.classify_item(category, tags)
  local ts = {}
  if type(tags) == "string" then for _, t in ipairs(S.split(tags)) do ts[t] = true end
  else for _, t in ipairs(tags or {}) do ts[t] = true end end
  local hit = ITEM_CAT[category]
  if hit and not ((hit[1] == "Books & notes" or hit[1] == "Junk & valuables" or hit[1] == "Food & drink") and ts.Quest) then
    return hit[1], hit[2]
  end
  if ts.Quest then return "Quest items", "Quest items" end
  if ts.ReadableItem or ts.mod_book or ts.NoticeBoardNote or ts.ThMap then
    return "Books & notes", (ts.NoticeBoardNote or ts.ThMap) and "Notes & maps" or "Books"
  end
  if ts.mod_junk or ts.Junk then return "Junk & valuables", "Junk & valuables" end
  if ts.mod_food or ts.Edibles then return "Food & drink", "Food & drink" end
  if category == "work" or category == "work_secondary" or category == "tool" or category == "usable" or
     category == "decorations" or category == "lute" then
    return "Tools & everyday things", "Tools & everyday things"
  end
  return "Other", "Other"
end

-- sorted(names, key=(the group's place in the order, else after them all; then the name))
function T.sort_groups(names, order)
  order = order or T.GROUP_ORDER
  local at = {}
  for k, g in ipairs(order) do at[g] = k - 1 end
  local list = {}
  for _, g in ipairs(names) do list[#list + 1] = g end
  table.sort(list, function(a, b)
    local ka, kb = at[a] or #order, at[b] or #order
    if ka ~= kb then return ka < kb end
    return require("conjunction.pysort").strlt(a, b)
  end)
  return list
end

return T
