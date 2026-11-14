-- graph_route.py: the wires of a quest graph, orthogonal, around the nodes - A* on the 10 px grid (PathView's router):
-- a step costs 1, a turn 2 more, a step through a node's margin 6 more; no turning back; a node's inside cannot be
-- crossed (only its own ports); a wire laid makes the cells along it dearer for wires to other targets.
--   route(g)        sets wire.points ({{x, y}} pixel corners, source port first) of every wire
-- The app keeps the ways found (a wire whose ends did not move takes its old way again) and the last graph: so does
-- this module, the same way, so the same edits give the same wires.
local L = require("conjunction.graph_layout")
local QG = require("conjunction.quest_graph")
local R = {}
local GRID = L.GRID
R.TURN_COST, R.SOFT_COST, R.CROWD_COST, R.STRAIGHT = 2, 6, 3, 3
R.WINDOWS = {{16, 20000}, {64, 60000}}
R.MAX_EXPANSIONS = 200000
R.WIDE_WEIGHT, R.WIDE_EXPANSIONS = 2.0, 400000
R.FAR = 120
local DX, DY = {1, -1, 0, 0}, {0, 0, 1, -1}       -- (0-based directions as the app's: right, left, down, up)
local OPPOSITE = {[0] = 1, 0, 3, 2}
local RIGHT, DOWN, UP = 0, 2, 3
local TURN_COST, SOFT_COST, CROWD_COST = R.TURN_COST, R.SOFT_COST, R.CROWD_COST

local OFF, SPAN = 1048576, 2097152
local function ckey(x, y) return (math.tointeger(x) + OFF) * SPAN + (math.tointeger(y) + OFF) end

local function Obstacles()
  local o = {hard = {}, soft = {}, box = {0, 0, 0, 0}}
  function o.add(x0, y0, x1, y1)
    local a, b, c, d = x0 // GRID, y0 // GRID, -((-x1) // GRID), -((-y1) // GRID)
    a, b, c, d = math.tointeger(a) or math.floor(a), math.tointeger(b) or math.floor(b),
                 math.tointeger(c) or math.floor(c), math.tointeger(d) or math.floor(d)
    for gy = b - 1, d + 1 do
      for gx = a - 1, c + 1 do
        if a <= gx and gx <= c and b <= gy and gy <= d then o.hard[ckey(gx, gy)] = true else o.soft[ckey(gx, gy)] = true end
      end
    end
    o.box = {math.min(o.box[1], a), math.min(o.box[2], b), math.max(o.box[3], c), math.max(o.box[4], d)}
  end
  return o
end

-- heapq's order: entries {f, cost, x, y, d} compared as Python's tuples
local function less(a, b)
  for i = 1, 5 do
    if a[i] ~= b[i] then return a[i] < b[i] end
  end
  return false
end
local function push(h, e)
  local n = #h + 1
  h[n] = e
  while n > 1 do
    local p = n // 2
    if less(h[n], h[p]) then h[n], h[p] = h[p], h[n] n = p else break end
  end
end
local function pop(h)
  local top = h[1]
  local last = h[#h]
  h[#h] = nil
  local n = #h
  if n > 0 then
    h[1] = last
    local i = 1
    while true do
      local l, r, m = 2 * i, 2 * i + 1, i
      if l <= n and less(h[l], h[m]) then m = l end
      if r <= n and less(h[r], h[m]) then m = r end
      if m == i then break end
      h[i], h[m] = h[m], h[i]
      i = m
    end
  end
  return top
end

local function corners_of(parent, s)
  local cells = {}
  while s ~= nil do
    table.insert(cells, 1, s)
    s = parent[s[4]] or nil
  end
  local out = {{cells[1][1], cells[1][2]}}
  for i = 2, #cells - 1 do
    if cells[i][3] ~= cells[i + 1][3] then out[#out + 1] = {cells[i][1], cells[i][2]} end
  end
  out[#out + 1] = {cells[#cells][1], cells[#cells][2]}
  return out
end

local function search_in(obs, start, sd, goal, ed, forced, win, crowd, dst, weight, most)
  local ex, ey = goal[1], goal[2]
  local hard, soft = obs.hard, obs.soft
  local wx0, wy0, wx1, wy1 = win[1], win[2], win[3], win[4]
  local INF = 1 << 30
  local function h(x, y, d)
    local dx, dy = ex - x, ey - y
    local ahead, side
    if d == 0 then ahead, side = dx, dy
    elseif d == 1 then ahead, side = -dx, dy
    elseif d == 2 then ahead, side = dy, dx
    else ahead, side = -dy, dx end
    local t
    if side == 0 then t = ahead >= 0 and 0 or 2 else t = ahead >= 0 and 1 or 2 end
    return (dx >= 0 and dx or -dx) + (dy >= 0 and dy or -dy) + TURN_COST * t
  end
  local function skey(x, y, d) return ckey(x, y) * 4 + d end
  -- a state: {x, y, d, key}
  local s0 = {start[1], start[2], sd, skey(start[1], start[2], sd)}
  local g = {[s0[4]] = 0}
  local parent = {[s0[4]] = false}
  local states = {[s0[4]] = s0}
  local heap = {}
  push(heap, {weight * h(start[1], start[2], sd), 0, start[1], start[2], sd})
  local closed = {}
  local expanded = 0
  while #heap > 0 do
    local e = pop(heap)
    local cost, x, y, d = e[2], e[3], e[4], e[5]
    local k = skey(x, y, d)
    if not closed[k] then
      closed[k] = true
      expanded = expanded + 1
      if expanded > most then return nil end
      if x == ex and y == ey then
        return corners_of(parent, states[k])
      end
      local first = parent[k] == false
      local back = OPPOSITE[d]
      for nd = 0, 3 do
        if not (nd == back or (first and nd ~= d)) then
          local nx, ny = x + DX[nd + 1], y + DY[nd + 1]
          if not (nx < wx0 or nx > wx1 or ny < wy0 or ny > wy1) then
            local cell = ckey(nx, ny)
            local free = forced[cell] == true
            if free or not hard[cell] then
              local c = cost + 1 + (nd == d and 0 or TURN_COST)
              if not free and soft[cell] then c = c + SOFT_COST end
              if crowd ~= nil then
                local others = crowd[cell * 2 + (nd < 2 and 1 or 0)]
                if others and (others.n > 1 or not others.set[dst]) then c = c + CROWD_COST end
              end
              if nx == ex and ny == ey and nd ~= ed then c = c + TURN_COST * 4 end
              local nk = skey(nx, ny, nd)
              if not closed[nk] and not ((g[nk] or INF) <= c) then
                g[nk] = c
                parent[nk] = states[k]
                states[nk] = states[nk] or {nx, ny, nd, nk}
                push(heap, {c + weight * h(nx, ny, nd), c, nx, ny, nd})
              end
            end
          end
        end
      end
    end
  end
  return nil
end

-- the cheapest path of grid corners from start (leaving in start_dir) to goal (arriving in end_dir), or nil
function R.search(obs, start, start_dir, goal, end_dir, forced, crowd, dst)
  local far = math.abs(start[1] - goal[1]) + math.abs(start[2] - goal[2]) > R.FAR
  local tries = far and {{nil, R.WIDE_EXPANSIONS}} or {R.WINDOWS[1], R.WINDOWS[2], {nil, R.WIDE_EXPANSIONS}}
  for _, t in ipairs(tries) do
    local pad, most = t[1], t[2]
    local win
    if pad == nil then
      local b = obs.box
      win = {math.min(b[1], start[1], goal[1]) - 16, math.min(b[2], start[2], goal[2]) - 16,
             math.max(b[3], start[1], goal[1]) + 16, math.max(b[4], start[2], goal[2]) + 16}
    else
      win = {math.min(start[1], goal[1]) - pad, math.min(start[2], goal[2]) - pad,
             math.max(start[1], goal[1]) + pad, math.max(start[2], goal[2]) + pad}
    end
    local found = search_in(obs, start, start_dir, goal, end_dir, forced, win, crowd, dst,
                            pad == nil and R.WIDE_WEIGHT or 1.0, most)
    if found then return found end
  end
  return nil
end

-- every cell along the corners: {x, y, horizontal}
local function cells_of(corners)
  local out = {}
  for i = 1, #corners - 1 do
    local x0, y0, x1, y1 = corners[i][1], corners[i][2], corners[i + 1][1], corners[i + 1][2]
    local horizontal = y0 == y1
    local n = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
    local sx = (x1 > x0 and 1 or 0) - (x1 < x0 and 1 or 0)
    local sy = (y1 > y0 and 1 or 0) - (y1 < y0 and 1 or 0)
    for k = 0, n do out[#out + 1] = {x0 + k * sx, y0 + k * sy, horizontal} end
  end
  return out
end

R._last = {key = nil, points = nil}
R._ways = {}
R._no_way = {}

local function num(v) return string.format("%.17g", v) end
local function graph_key(g)
  local ids = {}
  for id in pairs(g.nodes) do ids[#ids + 1] = id end
  require("conjunction.pysort").sort(ids)
  local parts = {}
  for _, id in ipairs(ids) do
    local n = g.nodes[id]
    local f = {}
    for _, e in ipairs(n.exits) do f[#f + 1] = QG.fails_here(e) and "1" or "0" end
    parts[#parts + 1] = table.concat({id, num(n.x), num(n.y), num(n.w), num(n.h), table.concat(f)}, "\1")
  end
  parts[#parts + 1] = "\2"
  for _, w in ipairs(g.wires) do parts[#parts + 1] = table.concat({w.src, tostring(w.port), w.dst, w.enter}, "\1") end
  return table.concat(parts, "\3")
end

local function wire_length(g, w)
  local ax, ay = L.port(g.nodes[w.src], w.port)
  local bx, by = L.port(g.nodes[w.dst], w.enter == "top" and "in" or w.enter)
  return math.abs(ax - bx) + math.abs(ay - by)
end

local function route_all(g)
  local obs = Obstacles()
  for _, n in pairs(g.nodes) do
    obs.add(n.x, n.y, n.x + n.w, n.y + n.h)
    for k, e in ipairs(n.exits) do
      if QG.fails_here(e) then
        local x, y = L.port(n, k - 1)
        obs.add(x + 8, y - 7, x + 8 + QG.FAIL_MARK, y + 7)
      end
    end
  end
  local hk = {}
  for c in pairs(obs.hard) do hk[#hk + 1] = c end
  table.sort(hk)
  local sig = table.concat(hk, ",")
  local crowd = {}
  local order = {}
  for i, w in ipairs(g.wires) do order[i] = {w, wire_length(g, w), i} end
  table.sort(order, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[3] < b[3] end)
  for _, ow in ipairs(order) do
    local w = ow[1]
    local src, dst = g.nodes[w.src], g.nodes[w.dst]
    local ax, ay = L.port(src, w.port)
    local bx, by = L.port(dst, w.enter == "top" and "in" or w.enter)
    local sd = w.port == "next" and DOWN or RIGHT
    local ed = (w.enter == "top" and DOWN) or (w.enter == "bottom" and UP) or RIGHT
    local function cell(v) return math.tointeger(v // GRID) or math.floor(v // GRID) end
    local port0, goal = {cell(ax), cell(ay)}, {cell(bx), cell(by)}
    local lead = (sd == DOWN and goal[2] - port0[2] > R.STRAIGHT) and R.STRAIGHT or 0
    while lead > 0 do
      local blocked = false
      for k = 2, lead + 1 do
        local c = ckey(port0[1], port0[2] + k)
        if obs.hard[c] or obs.soft[c] then blocked = true break end
      end
      if not blocked then break end
      lead = lead - 1
    end
    local start = {port0[1], port0[2] + lead}
    local forced = {}
    forced[ckey(port0[1], port0[2])] = true
    forced[ckey(start[1], start[2])] = true
    forced[ckey(goal[1], goal[2])] = true
    forced[ckey(start[1] + DX[sd + 1], start[2] + DY[sd + 1])] = true
    forced[ckey(goal[1] - DX[ed + 1], goal[2] - DY[ed + 1])] = true
    for k = 0, lead - 1 do forced[ckey(port0[1], port0[2] + k)] = true end
    local wkey = table.concat({start[1], start[2], sd, goal[1], goal[2], ed, port0[1], port0[2]}, ",")
    local old = R._ways[wkey]
    local corners
    local clear = false
    if old ~= nil then
      clear = true
      for _, c in ipairs(cells_of(old)) do
        local ck = ckey(c[1], c[2])
        if obs.hard[ck] and not forced[ck] then clear = false break end
      end
    end
    if clear then
      corners = {}
      for i, c in ipairs(old) do corners[i] = {c[1], c[2]} end
    elseif R._no_way[wkey .. "|" .. sig] then
      corners = nil
    else
      corners = R.search(obs, start, sd, goal, ed, forced, crowd, w.dst)
      if corners ~= nil then
        local copy = {}
        for i, c in ipairs(corners) do copy[i] = {c[1], c[2]} end
        R._ways[wkey] = copy
      else
        R._no_way[wkey .. "|" .. sig] = true
      end
    end
    if corners == nil then
      if start[1] ~= goal[1] then
        corners = {{start[1], start[2]}, {start[1], goal[2]}, {goal[1], goal[2]}}
      else
        corners = {{start[1], start[2]}, {goal[1], goal[2]}}
      end
    end
    corners[1] = {port0[1], port0[2]}
    local pts = {}
    for i, c in ipairs(corners) do pts[i] = {c[1] * GRID, c[2] * GRID} end
    w.points = pts
    for _, c in ipairs(cells_of(corners)) do
      local key = ckey(c[1], c[2]) * 2 + (c[3] and 1 or 0)
      local e = crowd[key]
      if not e then e = {n = 0, set = {}} crowd[key] = e end
      if not e.set[w.dst] then e.set[w.dst] = true e.n = e.n + 1 end
    end
  end
end

function R.route(g)
  local key = graph_key(g)
  if key == R._last.key then
    for i, w in ipairs(g.wires) do
      local pts = {}
      for j, p in ipairs(R._last.points[i]) do pts[j] = {p[1], p[2]} end
      w.points = pts
    end
    return
  end
  route_all(g)
  local saved = {}
  for i, w in ipairs(g.wires) do
    local pts = {}
    for j, p in ipairs(w.points) do pts[j] = {p[1], p[2]} end
    saved[i] = pts
  end
  R._last.key, R._last.points = key, saved
end

-- (for checks: the ways remembered forgotten, as a fresh app has none)
function R.forget()
  R._last = {key = nil, points = nil}
  R._ways, R._no_way = {}, {}
end

return R
