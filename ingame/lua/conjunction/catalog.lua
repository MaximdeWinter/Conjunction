-- What a template path says (conjunction/catalog.py): its kind, its source, a readable name, the folder it belongs to,
-- its tags; the paths kept out of the catalog. Paths are lower case with backslashes. catalog.py's patterns as they
-- are, through pyre.lua (Python's re). Checked: ingame/ref/catalog_check.py.
local R = require("conjunction.pyre")
local S = require("conjunction.pystr")
local PATHS = require("conjunction.paths")
local CAT = {}

CAT.KINDS = {
  {"Character part", {[[^characters\\models\\]], [[^characters\\base_entities\\]], [[\\characters\\models\\]]}},
  {"Item", {[[^items\\]], [[\\data\\items\\]]}},
  {"Container", {[[\\containers?\\]], [[_chest]], [[\\chest]], [[\\loot]], [[_crate]], [[\\barrel_loot]]}},
  {"Light", {[[\\lights?\\]], [[\\light_sources?\\]], [[torch]], [[candle]], [[lantern]], [[brazier]], [[campfire]],
             [[_fire_?place]], [[bonfire]]}},
  {"Monster", {[[\\monsters?\\]]}},
  {"Animal", {[[\\animals?\\]], [[\\horses?\\]], [[\\birds?\\]], [[\\fish\\]]}},
  {"NPC", {[[\\npc_entities\\]], [[\\characters\\]], [[\\community\\]], [[\\npcs?\\]], [[_npcs?\\]]}},
  {"Vehicle", {[[\\boats?\\]], [[\\vehicles?\\]], [[\\wagons?\\]], [[\\carts?\\]]}},
  {"Plant", {[[\\vegetation\\]], [[\\foliage\\]], [[\\trees?\\]], [[\\bushes\\]], [[\\herbs?\\]], [[\\plants?\\]]}},
  {"Architecture", {[[\\architecture\\]], [[\\buildings?\\]], [[\\doors?\\]], [[\\gates?\\]], [[\\walls?\\]],
                    [[\\bridges?\\]], [[\\fences?\\]], [[\\ruins?\\]]}},
  {"Furniture", {[[\\furniture\\]], [[\\beds?\\]], [[\\tables?\\]], [[\\chairs?\\]], [[\\benches?\\]]}},
  {"Decoration", {[[\\decorations?\\]], [[\\props?\\]], [[\\decoration_sets?\\]], [[\\clutter\\]]}},
  {"Item", {[[^items\\]], [[\\items\\]], [[\\weapons?\\]], [[\\armou?rs?\\]]}},
  {"Effect", {[[^fx\\]], [[\\fx\\]], [[\\effects?\\]], [[\\particles?\\]]}},
  {"Sound", {[[\\sounds?\\]], [[\\sound_emitters?\\]], [[\\ambient_sounds?\\]]}},
  {"Gameplay", {[[^gameplay\\]], [[\\gameplay\\]], [[\\triggers?\\]], [[\\interactive\\]], [[\\signs?\\]]}},
  {"Terrain", {[[\\rocks?\\]], [[\\stones?\\]], [[\\cliffs?\\]], [[\\terrain]], [[\\ground\\]], [[\\water\\]]}},
  {"Quest object", {[[^quests?\\]], [[\\quests?\\]]}},
  {"Living world", {[[living_world\\]]}},
}
CAT.HIDDEN = {["Character part"] = true}
local KIND_RE = {}
for k, e in ipairs(CAT.KINDS) do KIND_RE[k] = {e[1], R.compile(table.concat(e[2], "|"))} end
CAT.SKIP = R.compile([[\\(cutscenes?|cameras?|editor|engine\\|debug|test(s|_)|dummy|templates\\gameplay_abilities)]] ..
                     [[|^engine\\|\\animations?\\|\\behaviou?rs?\\|_proxy\b|\\proxies\\]])
-- kept out of the catalog (catalog.SKIP.search)
function CAT.skip(path) return CAT.SKIP:search(path) ~= nil end
CAT.SOURCES = {{"dlc\\ep1\\", "Hearts of Stone"}, {"dlc\\bob\\", "Blood and Wine"}}
local STOP = {}
for _, w in ipairs(S.split("dlc data w2ent entities entity common environment set sets the and of a b c d e f g h i j " ..
                           "ep1 bob npc model models levels")) do STOP[w] = true end

function CAT.kind_of(path)
  for _, k in ipairs(KIND_RE) do
    if k[2]:search(path) then return k[1] end
  end
  return "Other"
end

function CAT.source_of(path)
  for _, s in ipairs(CAT.SOURCES) do
    if path:sub(1, #s[1]) == s[1] then return s[2] end
  end
  if path:sub(1, 4) == "dlc\\" then return "DLC" end
  return "Base game"
end

local PREFIX = R.compile([[^(decoration_set_|dec_|env_|q\d+_|mq\d+_|sq\d+_)]])
local UNDERS = R.compile([[_+]])
-- decoration_set_boxes_chest_a.w2ent -> 'boxes chest a'
function CAT.caption(path)
  local base = PATHS.splitext(PATHS.basename(path))
  base = PREFIX:sub("", base)
  return S.strip(UNDERS:sub(" ", base))
end

local GENERIC = {entities = true, entity = true, templates = true, data = true, quest_files = true, clues = true,
                 common = true, items = true}
-- the folder that tells what it belongs to (the deepest that is not generic), '_' as spaces
function CAT.group_of(path)
  local parts = {}
  for part in (path .. "\\"):gmatch("(.-)\\") do parts[#parts + 1] = part end
  parts[#parts] = nil
  for k = #parts, 1, -1 do
    if not GENERIC[parts[k]] then return (parts[k]:gsub("_", " ")) end
  end
  return ""
end

local TAG_SPLIT = R.compile([[[\\_\-. ]+]])
-- the words of the path that say something, sorted
function CAT.tags_of(path)
  local seen, out = {}, {}
  for _, w in ipairs(TAG_SPLIT:split(path)) do
    if S.len(w) > 1 and not STOP[w] and not S.isdigit(w) and not seen[w] then
      seen[w] = true
      out[#out + 1] = w
    end
  end
  require("conjunction.pysort").sort(out)
  return out
end

return CAT
