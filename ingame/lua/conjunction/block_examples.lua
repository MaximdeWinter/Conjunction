-- block_examples.py: real examples of every kind of block - for each kind the places the game's own quests use it
-- (which quest, which phase, the designer's name for the block, what it does there). The card shows them ("How the
-- game uses it"), a click opens the place in the graph. The app builds them (block_examples.json); here they are read.
--   BX.load() -> {kind id: {count, files, examples = {{file, trail, guid, quest, where, name, lines}}}} | nil
--   BX.trail(tree, graph) -> {phase GUIDs}   the phase blocks one steps into from the main graph to reach `graph`
local J = require("conjunction.json")
local TR = require("conjunction.cr2w_tree")
local V = require("conjunction.vanilla_graph")
local PATHS = require("conjunction.paths")
local BX = {}

BX.CACHE = PATHS.DATA .. "\\block_examples.json"

local function hex(b) return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function guid(tree, n)
  local g = tree:obj(n):get("guid")
  return TR.is(g, TR.GUID) and hex(g.b) or nil
end
BX.guid = guid

function BX.trail(tree, graph)
  local holder = {}
  for k, o in ipairs(tree.objects) do
    local emb = o.props and o:get("embeddedGraph") or nil
    if V.obj_ref(emb) then holder[V.ival(emb)] = k end
  end
  local out, g, seen = {}, graph, {}
  while holder[g] and not seen[g] do
    seen[g] = true
    local b = holder[g]
    out[#out + 1] = guid(tree, b) or require("conjunction.yaml").null
    g = tree:obj(b).parent
  end
  local rev = {}
  for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
  return rev
end

local cached
function BX.load()
  if cached ~= nil then return cached or nil end
  local ok, v = pcall(J.read, BX.CACHE)
  cached = ok and v or false
  return cached or nil
end

return BX
