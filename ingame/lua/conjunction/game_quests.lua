-- game_quests.py: the game's quests as moments a Conjunction quest can hang on (hooks: nothing of the game's quest
-- changes, saves keep working) - each quest file of the game with the facts its graph sets, in the order they come,
-- read with questread.lua. Kept in data\game_quests.json (the app's own); graph_edit.phase_index: every quest graph
-- file of the game, kept in data\game_phases.json.
--   GQ.index() -> {{path, name, facts}}   GQ.facts_set(depot, path)   GQ.quest_files(depot)   GQ.phase_index()
local CE = require("conjunction.cr2w_edit")
local J = require("conjunction.json")
local PATHS = require("conjunction.paths")
local QR = require("conjunction.questread")
local GQ = {}

GQ.CACHE = PATHS.DATA .. "\\game_quests.json"
GQ.PHASES = PATHS.DATA .. "\\game_phases.json"

local function depot_open()
  return require("conjunction.depot").open(require("conjunction.config").load().game)
end

local function graph_files(depot)
  local out = {}
  for _, p in ipairs(depot:glob("", ".w2phase")) do out[#out + 1] = p end
  for _, p in ipairs(depot:glob("", ".w2quest")) do out[#out + 1] = p end
  table.sort(out)
  return out
end

-- the game's quests: the phase / quest files a quest starts from (not the sub phases in quest_files folders)
function GQ.quest_files(depot)
  local S = require("conjunction.pystr")
  local out = {}
  for _, p in ipairs(graph_files(depot)) do
    if ("\\" .. p):find("\\quests\\", 1, true) then
      local low = S.lower(p)
      local base = low:match("([^\\]*)$")
      if not (low:find("\\quest_files\\", 1, true) or low:find("\\phases\\", 1, true) or base:find("test", 1, true)) then
        out[#out + 1] = p
      end
    end
  end
  return out
end

-- 'quests\part_1\q103_daughter.w2phase' -> 'q103 daughter'
function GQ.name_of(path)
  local base = path:match("([^\\]*)$")
  base = base:gsub("%.w2phase$", ""):gsub("%.w2quest$", "")
  return (base:gsub("_", " "))
end

local function has_key(d, k)
  for _, x in ipairs(CE.all_keys(d)) do if x == k then return true end end
  return false
end

-- the facts a quest's graph sets (value above 0), in the order of its blocks, through its sub phases
function GQ.facts_set(depot, path, seen)
  seen = seen or {}
  if seen[path] or not depot:exists(path) then return {} end
  seen[path] = true
  local out, have = {}, {}
  local function add(x)
    if not have[x] then
      have[x] = true
      out[#out + 1] = x
    end
  end
  local ok, g, f = pcall(QR.open_graph, depot, path)
  if not ok then return out end                    -- (a file the reader does not know)
  local stack = {g}
  while #stack > 0 do
    local gr = table.remove(stack, 1)
    for _, i in ipairs(gr.order) do
      local b = gr.blocks[i]
      local cls, bp = b[1], b[2]
      if cls == "CQuestFactsDBChangingBlock" and type(bp.factID) == "string" and bp.factID ~= "" then
        local v = bp.value
        if not has_key(bp, "value") then v = 1 end
        if v == nil or v == false or v == CE.NONE then v = 0 elseif v == true then v = 1 end
        if type(v) == "number" and v > 0 then add(bp.factID) end
      end
      if cls == "CQuestPhaseBlock" then
        local emb, ph = bp.embeddedGraph, bp.phase
        if QR.is_ref(emb, "export") then
          stack[#stack + 1] = QR.Graph(f, emb[2])
        elseif QR.is_ref(ph, "import") then
          for _, x in ipairs(GQ.facts_set(depot, ph[2], seen)) do add(x) end
        end
      end
    end
  end
  return out
end

function GQ.build(log)
  log = log or function() end
  local d = depot_open()
  local files = GQ.quest_files(d)
  local out = {}
  for k, p in ipairs(files) do
    local facts = GQ.facts_set(d, p)
    if #facts > 0 then out[#out + 1] = {path = p, name = GQ.name_of(p), facts = facts} end
    if k % 50 == 0 then log("[game quests] " .. k .. " / " .. #files) end
  end
  w3.fs.write(GQ.CACHE, J.encode(out))
  return out
end

local INDEX
function GQ.index()
  if INDEX == nil then
    local text = w3.fs.exists(GQ.CACHE) and w3.fs.read(GQ.CACHE) or nil
    local ok, v = pcall(J.decode, text or "")
    INDEX = (text and ok and type(v) == "table") and v or GQ.build()
  end
  return INDEX
end

local PHASES
function GQ.phase_index()
  if PHASES == nil then
    local text = w3.fs.exists(GQ.PHASES) and w3.fs.read(GQ.PHASES) or nil
    local ok, v = pcall(J.decode, text or "")
    if text and ok and type(v) == "table" then
      PHASES = v
    else
      PHASES = graph_files(depot_open())
      w3.fs.write(GQ.PHASES, J.encode(PHASES))
    end
  end
  return PHASES
end

return GQ
