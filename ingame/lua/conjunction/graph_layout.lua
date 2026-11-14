-- graph_layout.py: the sizes of a quest graph's nodes and where its ports are, on PathView's 10 px grid; place(g)
-- puts the older form's columns (only migrate needs that).
--   size(node) -> w, h          body(node) -> {{kind, text}}       port(node, which) -> x, y
--   which: "in" (top), "left", "next" (bottom), or an exit's index (0-based, its right side)
local PYS = require("conjunction.pystr")
local P = require("conjunction.py")
local L = {}
L.GRID = 10
L.NODE_W = 230
L.COL = L.NODE_W + 90
L.GAP = 40
L.HEAD = 30
L.LINE = 16
L.EXIT = 20
L.PAD = 8
L.CHARS = 34
local GRID = L.GRID

function L.snap(v) return -((-v) // GRID) * GRID end

-- the text in lines of about `width` characters (code points), at most `most` (the last one cut with an ellipsis)
function L.wrap(text, width, most)
  width, most = width or L.CHARS, most or 2
  local words = PYS.split(P.str(P.or_(text, "")))
  local lines, cur = {}, ""
  local len = PYS.len
  for _, w in ipairs(words) do
    if cur ~= "" and len(cur) + 1 + len(w) > width then
      lines[#lines + 1] = cur
      cur = w
    else
      cur = PYS.strip(cur .. " " .. w)
    end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  local function cut(s, n) local cps = PYS.cps(s) return PYS.from_cps(cps, 1, math.min(n, #cps)) end
  if #lines > most then
    for k = #lines, most + 1, -1 do lines[k] = nil end
    lines[most] = PYS.rstrip(cut(lines[most], width - 1)) .. "…"
  end
  for k, ln in ipairs(lines) do
    if len(ln) > width then lines[k] = cut(ln, width - 1) .. "…" end
  end
  return lines
end

L.ENDS = {done = true, success = true, fail = true, runs_out = true, ["end"] = true}

-- does the subject go under the title (MaximdeWinter 12.11.: a node read "BOB RAIDER RAN")? When the title row has no room
-- for it as graph_view draws it there: the number, KIND ▾, "· subject", the red dot and the eye at the right
function L.subject_below(node)
  if not P.T(node.subject) or L.ENDS[node.kind] then return false end
  local GV = package.loaded["conjunction.ui.graph_view"]
  if not (GV and GV.advance) then return false end
  local x = 12
  if node.number ~= 0 then x = x + GV.advance(11, true, 0, tostring(node.number)) + 7 end
  x = x + GV.advance(9, true, 0.6, node.title .. " ▾") + 6
  local room = L.NODE_W - x - 18 - (#node.missing > 0 and 10 or 0) - 16
  return GV.advance(10, false, 0, "· " .. node.subject) > room
end

-- the rows of a node under its title: {kind, text} - the subject when it is too long for the title row, its text
-- (an action's in one line), what is missing
function L.body(node)
  local out = {}
  if L.subject_below(node) then out[1] = {"subject", L.wrap(node.subject, 40, 1)[1]} end
  for _, t in ipairs(L.wrap(node.text, L.CHARS, node.block == "action" and 1 or 2)) do out[#out + 1] = {"text", t} end
  if #node.missing > 0 then
    for _, t in ipairs(L.wrap("Missing: " .. table.concat(node.missing, ", "), L.CHARS, 2)) do
      out[#out + 1] = {"missing", t}
    end
  end
  return out
end

function L.size(node)
  if L.ENDS[node.kind] then return 170, 30 end
  local rows = L.body(node)
  local h = L.HEAD + #rows * L.LINE
  if #node.exits > 0 then
    h = L.snap(h) + #node.exits * L.EXIT
  elseif #rows > 0 then
    h = h + L.PAD
  end
  return L.NODE_W, math.max(40, L.snap(h + 2))
end

-- y of the first exit row, relative to the node
function L.exits_top(node) return node.h - #node.exits * L.EXIT end

function L.port(node, which)
  if which == "in" then return node.x + node.w // 2 // GRID * GRID, node.y end
  if which == "left" then return node.x, node.y + 20 end
  if which == "next" or which == "bottom" then return node.x + node.w // 2 // GRID * GRID, node.y + node.h end
  return node.x + node.w, node.y + L.exits_top(node) + which * L.EXIT + L.EXIT // 2
end

-- --- the older form's columns placed (quest_graph.build)
local function placer(g)
  local self = {g = g, rects = {}, done = {}}
  function self.free(x0, y0, x1, y1)
    for _, r in ipairs(self.rects) do
      if not (x1 <= r[1] or x0 >= r[3] or y1 <= r[2] or y0 >= r[4]) then return false end
    end
    return true
  end
  function self.extent(col, x, y)
    local out, cy = {}, y
    for _, nid in ipairs(col.nodes) do
      local n = g.nodes[nid]
      out[#out + 1] = {x, cy - L.GAP // 2, x + L.NODE_W, cy + n.h + L.GAP // 2}
      cy = cy + n.h + L.GAP
    end
    return out
  end
  local function all_free(rs)
    for _, r in ipairs(rs) do if not self.free(r[1], r[2], r[3], r[4]) then return false end end
    return true
  end
  self.all_free = all_free
  function self.column(col, x, y)
    if self.done[col] then return y end
    self.done[col] = true
    local cy = y
    for _, nid in ipairs(col.nodes) do
      local n = g.nodes[nid]
      if n.kind == "chapter" then
        for _, r in ipairs(self.rects) do cy = math.max(cy, r[4] + L.GAP // 2) end
      end
      n.x, n.y = x + (L.NODE_W - n.w) // 2 // GRID * GRID, L.snap(cy)
      self.rects[#self.rects + 1] = {x, n.y - L.GAP // 2, x + L.NODE_W, n.y + n.h + L.GAP // 2}
      cy = n.y + n.h + L.GAP
      local below = n.y
      for _, f in ipairs(col.forks[nid] or {}) do
        local k, sub = f[1], f[2]
        if not self.done[sub] then
          local _, py = L.port(n, k)
          local sy = math.max(L.snap(py - 20), below)
          local sx = x + L.COL
          while not all_free(self.extent(sub, sx, sy)) do sx = sx + L.COL end
          local bottom = self.column(sub, sx, sy)
          below = bottom + L.GAP + ((sub["then"] == "join" or sub["then"] == "back") and GRID * 2 or 0)
          if sub["then"] == "join" then cy = math.max(cy, bottom + L.GAP + GRID * 2) end
        end
      end
    end
    return cy - L.GAP
  end
  return self
end

function L.place(g)
  for _, n in pairs(g.nodes) do n.w, n.h = L.size(n) end
  local p = placer(g)
  local bottom = p.column(g.main, 0, 0)
  local x = L.COL
  for _, sub in ipairs(g.loose) do
    while not p.all_free(p.extent(sub, x, 0)) do x = x + L.COL end
    p.column(sub, x, 0)
  end
  return bottom
end

return L
