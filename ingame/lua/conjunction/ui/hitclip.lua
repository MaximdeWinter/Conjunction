-- Boxes cut to the clip they are drawn in. TW3SE's draw.clip cuts what is drawn, not where the mouse counts (a box is
-- an ImGui item, the clip only its draw list's): a button scrolled out of a list still took clicks where it would be -
-- over the dialogue's graph above its cards, over the game beside the panel (07.11.). While Conjunction draws its
-- frame (init.lua: HC.run), each box is cut to the clips around it; one wholly outside is no item at all (ImGui gives
-- the mouse to the first item under it). A layer and a window of their own start without a clip, as their draw lists
-- do. Other mods' drawing is untouched: the functions are swapped in for Conjunction's frame only.
local HC = {}

local stack = {}                     -- the clips in force, innermost last: {x0, y0, x1, y1}
local inner = {}                     -- w3.ui's functions while ours stand in for them

local function clip(x, y, w, h, fn)
  local r = {x, y, x + w, y + h}
  local top = stack[#stack]
  if top then
    r = {math.max(r[1], top[1]), math.max(r[2], top[2]), math.min(r[3], top[3]), math.min(r[4], top[4])}
  end
  stack[#stack + 1] = r
  local ok, err = pcall(inner.clip, x, y, w, h, fn)
  stack[#stack] = nil
  if not ok then error(err, 0) end
end

local function unclipped(f, ...)
  local was = stack
  stack = {}
  local ok, err = pcall(f, ...)
  stack = was
  if not ok then error(err, 0) end
end
local function layer(n, fn) unclipped(inner.layer, n, fn) end
local function panel(...) unclipped(inner.panel, ...) end

local function hit(id, w, h)
  local top = stack[#stack]
  if not top then return inner.hit(id, w, h) end
  local x, y = w3.ui.pos()
  local x0, y0 = math.max(x, top[1]), math.max(y, top[2])
  local x1, y1 = math.min(x + w, top[3]), math.min(y + h, top[4])
  if x1 - x0 < 1 or y1 - y0 < 1 then return 0, false, false end
  if x0 ~= x or y0 ~= y then w3.ui.set_pos(x0, y0) end
  return inner.hit(id, x1 - x0, y1 - y0)
end

-- fn (Conjunction's frame) with the boxes cut to their clips; w3.ui as it was afterwards, also when fn fails
function HC.run(fn)
  local ui, draw = w3.ui, w3.ui.draw
  inner.hit, inner.panel, inner.clip, inner.layer = ui.hit, ui.panel, draw.clip, draw.layer
  stack = {}
  ui.hit, ui.panel, draw.clip, draw.layer = hit, panel, clip, layer
  local ok, err = pcall(fn)
  ui.hit, ui.panel, draw.clip, draw.layer = inner.hit, inner.panel, inner.clip, inner.layer
  if not ok then error(err, 0) end
end

return HC
