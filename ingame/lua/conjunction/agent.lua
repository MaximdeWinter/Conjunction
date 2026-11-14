-- Conjunction for an agent (or any script) in the game - agent.py's commands, served through TW3SE's pipe:
--   lua return CJ_AGENT("widgets", '{"text": "Build & Play"}')   ->  {"ok": true, "result": [...]}
-- The client is ingame/tools/cj_agent.py (the same command line as `python -m conjunction.agent`). A command answers at
-- once: the game's main thread runs it, a wait would stop the game. What waits (a build to its end, a widget that
-- comes in a moment, a walk) the client does, asking again. An answer longer than the pipe takes (4 KB) goes into a
-- file; the pipe gets "@<path>".
--
-- Widgets: Qt has a tree of them, the UI here is drawn anew each frame. Each frame the agent keeps what was drawn:
-- the windows (w3.ui.panel), the boxes that take the mouse (w3.ui.hit: the buttons, tabs, fields, tiles, a menu's
-- entries) and the texts drawn (w3.ui.draw.text) - a box's text is the text drawn inside it. A click is fed to the UI
-- (w3.ui.feed): the mouse to the box's middle, pressed, let go, a step a frame.
local J = require("conjunction.json")
local A = {}

A.MAX_REPLY = 3800                      -- bytes the pipe takes back (TW3SE: 4096)
A.app = nil                             -- init.lua: {ed, hud, sys, panel}

-- --- what the frame drew ---
local cur = {windows = {}, hits = {}, texts = {}, labels = {}}
local last = cur
local stack = {}                        -- the windows being drawn (w3.ui.panel inside w3.ui.panel)

local installed = false
function A.install()
  if installed then return end
  installed = true
  local ui, draw = w3.ui, w3.ui.draw
  -- (the game's own functions are wrapped, kept in w3.ui: a live reload of the mod runs this again in a new agent - it
  -- had wrapped the agent before, whose frame never ends again, and that one kept every text, box and window drawn:
  -- 13 GB of Lua after an evening, frames of 8 s for its garbage collection, 24.10.)
  local orig = rawget(ui, "_cj_agent_orig")
  if not orig then
    -- (agents of earlier reloads, from before this was kept: peeled off down to TW3SE's own function)
    local function peel(f, name)
      for _ = 1, 100 do
        local info = debug.getinfo(f, "S")
        if not info or info.what == "C" then return f end
        local inner
        for i = 1, 20 do
          local n, v = debug.getupvalue(f, i)
          if not n then break end
          if n == name and type(v) == "function" then inner = v break end
        end
        if not inner then return f end
        f = inner
      end
      return f
    end
    orig = {panel = peel(ui.panel, "panel"), hit = peel(ui.hit, "hit"), text = peel(draw.text, "text")}
    ui._cj_agent_orig = orig
  end
  local panel, hit, text = orig.panel, orig.hit, orig.text
  ui.panel = function(id, x, y, w, h, opts, fn)
    cur.windows[#cur.windows + 1] = {id = id, rect = {x, y, w, h}}
    stack[#stack + 1] = id
    local ok, err = pcall(panel, id, x, y, w, h, opts, fn)
    stack[#stack] = nil
    if not ok then error(err, 0) end
  end
  ui.hit = function(id, w, h)
    local x, y = ui.pos()
    local c, hov, held = hit(id, w, h)
    cur.hits[#cur.hits + 1] = {id = id, rect = {x, y, w, h}, window = stack[#stack]}
    return c, hov, held
  end
  draw.text = function(x, y, colour, s, ...)
    if type(s) == "string" and s ~= "" then cur.texts[#cur.texts + 1] = {x = x, y = y, s = s} end
    return text(x, y, colour, s, ...)
  end
end

-- w3.ui works only inside a frame (w3.on_ui); a command comes from the pipe between frames. What it does to the UI
-- (input fed, a screenshot) waits here for the next frame.
local feedq, todo = {}, {}
local fed_waiting = 0                   -- steps TW3SE still holds (w3.ui.feed_pending, last frame)
local function feed(step) feedq[#feedq + 1] = step end

-- the frame begins (init.lua, first thing in its w3.on_ui): the input and the jobs the commands left
function A.frame_start()
  local q, t = feedq, todo
  feedq, todo = {}, {}
  for _, step in ipairs(q) do w3.ui.feed(step) end
  for _, fn in ipairs(t) do
    local ok, err = pcall(fn)
    if not ok then print("[agent] " .. tostring(err)) end
  end
  fed_waiting = w3.ui.feed_pending()
end

-- the frame ends (init.lua, after its windows): what it drew is what the commands see
function A.frame_done()
  last = cur
  cur = {windows = {}, hits = {}, texts = {}, labels = {}}
end

-- a painted thing names itself (agent.py: accessibleName): the graph's tiles, what Qt draws into a picture
function A.label(id, text) cur.labels[id] = text end

-- a part of a view that takes clicks without a box of its own (an entry of a drop-down list, a catalog tile, a node
-- of the graph): drawn this frame at x, y, w, h with its text; a click on it goes to that spot as a real one does
function A.area(id, x, y, w, h, text, window)
  cur.hits[#cur.hits + 1] = {id = id, rect = {x, y, w, h}, window = window or stack[#stack]}
  if text then cur.labels[id] = text end
end

-- --- widgets ---
local function inside(t, r) return t.x >= r[1] - 1 and t.x < r[1] + r[3] and t.y >= r[2] - 2 and t.y < r[2] + r[4] end

local function text_of(h)
  if last.labels[h.id] then return last.labels[h.id] end
  local parts = {}
  for _, t in ipairs(last.texts) do
    if inside(t, h.rect) then parts[#parts + 1] = t end
  end
  table.sort(parts, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  local out = {}
  for _, t in ipairs(parts) do out[#out + 1] = t.s end
  return table.concat(out, " ")
end

local function norm(t)
  return (tostring(t):gsub("▾", " "):gsub("▴", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")):lower()
end

local function describe(h)
  local r = h.rect
  return {id = h.id, class = "hit", name = h.id, text = text_of(h):sub(1, 200), window = h.window,
          rect = {math.floor(r[1]), math.floor(r[2]), math.floor(r[3]), math.floor(r[4])}, enabled = true}
end

-- the widget asked for (by id, its text, or its name) - the one drawn last (in front) when several match
local function find(id, text, name)
  local found
  for _, h in ipairs(last.hits) do
    if (id == nil or h.id == id) and (name == nil or h.id == name) and (text == nil or text_of(h) == text) then
      found = h
    end
  end
  if not found and text ~= nil then
    for _, h in ipairs(last.hits) do
      if (name == nil or h.id == name) and norm(text_of(h)) == norm(text) then found = h end
    end
  end
  if not found then
    error(string.format("no visible widget with %s", id and ("id=" .. id) or text and ("text=" .. text) or
                        ("name=" .. tostring(name))), 0)
  end
  return found
end

-- a click fed to the UI: to the point, pressed, let go (twice: a double click)
local function click_at(x, y, button, double)
  local b = ({left = 0, right = 1, middle = 2})[button or "left"] or 0
  feed{x = x, y = y}
  for _ = 1, double and 2 or 1 do
    feed{button = b, down = true}
    feed{button = b, down = false}
  end
end

local C = {}                           -- the commands: C.<name>(args) -> result
local DOC = {}

DOC.ping = "Is Conjunction there: its project, the place, the world, whether the editor is on"
function C.ping()
  local ed = A.app and A.app.ed
  if not ed then return {project = nil, editing = false, game = true, started = false} end
  return {project = ed.project.path, place = ed.place, editing = ed.editing == true, game = true,
          world = ed.world or w3.world.path()}
end

DOC.world_fits = "Objects the game placed within 30 m of the camera that fit `kind` (door, light, effect, container, " ..
                 "clue, usable, moving, any; default: what the waiting pick asks for) -> {n, name, kind, guid, metres, screen = {x, y} or nil}"
function C.world_fits(a)
  local ed = A.app and A.app.ed
  if not (ed and ed.cam and ed.cam.pos) then error("the editor is not on", 0) end
  local WP = require("conjunction.world_pick")
  local kind = a.kind or (ed.request and ed.request.world) or "any"
  local W, H = (ed.hud and ed.hud.W) or 1920, (ed.hud and ed.hud.Hh) or 1080
  local out = {}
  for i, c in ipairs(WP.scan(ed.cam.pos, kind)) do
    local d = math.sqrt((c.pos[1] - ed.cam.pos[1]) ^ 2 + (c.pos[2] - ed.cam.pos[2]) ^ 2 + (c.pos[3] - ed.cam.pos[3]) ^ 2)
    local s = ed.cam:project(c.pos, W, H)
    out[#out + 1] = {n = i, name = c.name, kind = c.kind, guid = c.guid, metres = math.floor(d * 10 + 0.5) / 10,
                     screen = s and {math.floor(s[1]), math.floor(s[2])} or nil}
  end
  table.sort(out, function(x, y) return x.metres < y.metres end)
  return out
end

DOC.world_take = "Take an object of the world: `n` from world_fits (same kind) or the first whose name contains " ..
                 "`name`. With a pick waiting (Pick in world on a card) it answers it, as a click on its marker; " ..
                 "else it goes into the project -> {ref, name}"
function C.world_take(a)
  local ed = A.app and A.app.ed
  if not (ed and ed.cam and ed.cam.pos) then error("the editor is not on", 0) end
  local WP = require("conjunction.world_pick")
  local kind = a.kind or (ed.request and ed.request.world) or "any"
  local list = WP.scan(ed.cam.pos, kind)
  local c
  if a.n then c = list[a.n] end
  if not c and a.name then
    for _, x in ipairs(list) do if x.name:lower():find(tostring(a.name):lower(), 1, true) then c = x break end end
  end
  if not c then error("nothing of that kind there (world_fits lists them)", 0) end
  if ed.request and ed.request.world then
    ed:_world_answer(c)
    return {taken = c.name}
  end
  local ref = WP.keep(ed.project, c, require("conjunction.py").str((ed.project.places[ed.place] or {}).world or ed.world or ""))
  if ed.project.save_meta then ed.project:save_meta() end
  return {ref = ref, name = c.name}
end

DOC.help = "The commands and what each does"
function C.help()
  local out = {}
  for k, d in pairs(DOC) do out[k] = d end
  return out
end

DOC.windows = "Conjunction's windows drawn last frame (the bar and panel, its windows, menus) and the game's picture"
function C.windows()
  local out = {}
  for _, w in ipairs(last.windows) do
    out[#out + 1] = {id = w.id, class = "window", title = w.id, rect = w.rect, window = true}
  end
  local cx, cy, cw, ch = w3.input.client()
  if cw then out[#out + 1] = {id = "game", class = "game", rect = {cx, cy, cw, ch}} end
  return out
end

DOC.widgets = "Widgets drawn last frame - filter by text (exact), contains, name, window; each with its id and rect"
function C.widgets(a)
  local out, limit = {}, a.limit or 200
  for _, h in ipairs(last.hits) do
    local t = text_of(h)
    if (a.window == nil or h.window == a.window) and (a.text == nil or t == a.text) and (a.name == nil or h.id == a.name)
        and (a.contains == nil or (t .. " " .. h.id):lower():find(a.contains:lower(), 1, true)) then
      out[#out + 1] = describe(h)
      if #out >= limit then break end
    end
  end
  return out
end

DOC.click = "Click a widget (id, text or name) at its middle, or at x, y inside it; button, double"
function C.click(a)
  local h = find(a.id, a.text, a.name)
  local r = h.rect
  local x = a.x and (r[1] + a.x) or (r[1] + r[3] / 2)
  local y = a.y and (r[2] + a.y) or (r[2] + r[4] / 2)
  click_at(x, y, a.button, a.double)
  return describe(h)
end

DOC.hover = "The mouse to x, y of the picture without a click (the last click leaves it there: on the bar it kept the panel from taking the mouse)"
function C.hover(a)
  feed{x = a.x, y = a.y}
  return {a.x, a.y}
end

DOC.drag = "Drag with the left button: from a widget (from = id; fx, fy inside it) or a point (x1, y1) to a widget " ..
           "(to = id; tx, ty inside it) or a point (x2, y2), in `steps` moves"
function C.drag(a)
  local function at(id, dx, dy, px, py)
    if id then
      local r = find(id).rect
      return r[1] + (dx or r[3] / 2), r[2] + (dy or r[4] / 2)
    end
    return px, py
  end
  local x1, y1 = at(a.from, a.fx, a.fy, a.x1, a.y1)
  local x2, y2 = at(a.to, a.tx, a.ty, a.x2, a.y2)
  if not (x1 and y1 and x2 and y2) then error("drag: from (or x1, y1) and to (or x2, y2)", 0) end
  feed{x = x1, y = y1}
  feed{button = 0, down = true}
  local n = math.max(2, a.steps or 8)
  for i = 1, n do feed{x = x1 + (x2 - x1) * i / n, y = y1 + (y2 - y1) * i / n} end
  feed{x = x2, y = y2}
  feed{button = 0, down = false}
  return {from = {x1, y1}, to = {x2, y2}}
end

DOC.type = "Type into a text field (id, name, or the field showing `field`): clicked, cleared (clear), the text, Enter"
function C.type(a)
  local h = find(a.id, a.field, a.name)
  local r = h.rect
  click_at(r[1] + r[3] / 2, r[2] + r[4] / 2)
  if a.clear ~= false then
    feed{ctrl = true}
    feed{key = "A", down = true}
    feed{key = "A", down = false}
    feed{ctrl = false}
    feed{key = "Backspace", down = true}
    feed{key = "Backspace", down = false}
  end
  feed{chars = tostring(a.text)}
  if a.enter ~= false then
    feed{key = "Enter", down = true}
    feed{key = "Enter", down = false}
  end
  return describe(h)
end

DOC.menu = "Choose the entry `text` of the menu or list that is open"
function C.menu(a) return C.click({text = a.text}) end

DOC.tab = "Switch to the tab `text` (the panel's tabs, a catalog's tabs)"
function C.tab(a) return C.click({text = a.text}) end

DOC.item = "Click the first entry of a list or grid whose text starts with `text`; double: a double click"
function C.item(a)
  local want = norm(a.text)
  for _, h in ipairs(last.hits) do
    if norm(text_of(h)):sub(1, #want) == want then
      local r = h.rect
      click_at(r[1] + r[3] / 2, r[2] + r[4] / 2, "left", a.double)
      return {item = text_of(h), id = h.id}
    end
  end
  error("no entry starting with " .. tostring(a.text), 0)
end

DOC.feed_pending = "Steps of input still waiting to reach the UI (a click is done when this is 0)"
function C.feed_pending()
  return {waiting = #feedq + fed_waiting}
end

DOC.shot = "A screenshot of the game with Conjunction's windows -> its path; target: a window id or a widget id " ..
           "gives the rectangle to cut (the client cuts it)"
function C.shot(a)
  local path = a.path or (A.shots_dir() .. "\\" .. os.date("%H%M%S") .. "_" ..
                          tostring(a.target or "view"):gsub("[^%w_%-]", "_"):sub(1, 30) .. ".png")
  local rect
  if a.target and a.target ~= "game" and a.target ~= "view" and a.target ~= "screen" then
    for _, w in ipairs(last.windows) do if w.id == a.target then rect = w.rect end end
    if not rect then
      for _, h in ipairs(last.hits) do if h.id == a.target then rect = h.rect end end
    end
    if not rect then error("no window or widget " .. tostring(a.target), 0) end
  end
  if w3.fs.exists(path) then w3.fs.remove(path) end
  todo[#todo + 1] = function()
    if w3.ui.screenshot(path) == nil then print("[agent] the overlay could not take a screenshot") end
  end
  return {path = path, rect = rect}
end

function A.shots_dir()
  local d = require("conjunction.paths").HOME .. "\\_agent_shots"
  if not w3.fs.isdir(d) then w3.fs.mkdir(d) end
  return d
end

DOC.eval = "Lua inside Conjunction (the expert's way to everything): app, ed, panel, project, agent; returns the " ..
           "value of `return ...`"
local env = setmetatable({}, {__index = _G})
function C.eval(a)
  local ed = A.app and A.app.ed
  env.app, env.ed, env.panel, env.agent = A.app, ed, A.app and A.app.panel, A
  env.project = ed and ed.project
  local fn, err = load(a.code, "=agent", "t", env)
  if not fn then error(err, 0) end
  local v = fn()
  local ok = pcall(J.encode, v)
  return ok and v or tostring(v)
end

local function ed()
  local e = A.app and A.app.ed
  if not e then error("Conjunction has not started (no project, or not in the world yet)", 0) end
  return e
end

DOC.quest = "The project's quest (nodes, links, steps); set: replace it (saved, the Quest tab shows it)"
function C.quest(a)
  local p = ed().project
  if a.set ~= nil then
    p.meta.quest = a.set
    p:save_meta()
    local board = A.app.panel.board_ui
    if board and board.sync then pcall(board.sync, board) end
  end
  return p.meta.quest
end

DOC.places = "The places and what is placed in them; place + set: replace that place (saved)"
function C.places(a)
  local p = ed().project
  if a.place ~= nil and a.set ~= nil then
    p.places[a.place] = a.set
    p:save_place(a.place)
  end
  if a.place == nil then return p.places end
  return p.places[a.place]
end

DOC.build = "Build: play=false only checks, play=true Build & Play; ask build_log until done"
function C.build(a)
  ed()
  local panel = A.app.panel
  panel.tab = 3
  panel:build(a.play == true)
  return {started = true}
end

DOC.build_log = "The build's log (its last lines), whether it is done and whether it failed"
function C.build_log(a)
  local panel = A.app and A.app.panel
  local lines = panel and panel.build_log or {}
  local tail, out, failed = a.tail or 60, {}, false
  for i = math.max(1, #lines - tail + 1), #lines do out[#out + 1] = lines[i] end
  for _, l in ipairs(lines) do if tostring(l):sub(1, 8) == "[failed]" then failed = true end end
  return {done = not (panel and panel.building), failed = failed, log = out}
end

-- --- the game ---
DOC.game = "Exec commands in the game (cj_* of Conjunction's scripts, any exec function) -> a mark; game_since(mark) " ..
           "gives the lines they sent back"
function C.game(a)
  local cmds = type(a.cmds) == "string" and {a.cmds} or a.cmds or {}
  local mark = w3.link.mark()
  for _, c in ipairs(cmds) do
    local ok, err = w3.exec(c)
    if not ok then error("the game did not take " .. c .. ": " .. tostring(err), 0) end
  end
  return {mark = mark}
end

DOC.game_since = "The lines the game's scripts sent after `mark` (from game)"
function C.game_since(a)
  local _, lines = w3.link.since(a.mark or 0)
  return lines or {}
end

DOC.where = "The player's position and the camera (x, y, z each), where the camera looks, and the world"
function C.where()
  local p = w3.player()
  if not p then error("the game did not say where (loading? the main menu?)", 0) end
  local pos = p:GetWorldPosition()
  local cam = w3.camera.pos()
  local f = w3.camera.forward()
  return {world = w3.world.path(), player = {pos.X, pos.Y, pos.Z}, cam = {cam.X, cam.Y, cam.Z},
          dir = {f.X, f.Y, f.Z}}
end

DOC.ground = "The height of what stands at x, y (from z + 5 m down) - nil: nothing there"
function C.ground(a)
  return w3.world.ground({X = a.x, Y = a.y, Z = (a.z or 0) + 5})
end

DOC.place = "Place a template as a click does: at x, y (z: the ground there) or ahead = metres in front of the " ..
            "player (side: to the right); ask places until it is in -> the place and how many it had before"
function C.place(a)
  local e = ed()
  local x, y, z = a.x, a.y, a.z
  if a.ahead ~= nil then
    local w = C.where()
    local dx, dy = w.dir[1], w.dir[2]
    local n = math.sqrt(dx * dx + dy * dy)
    if n == 0 then n = 1 end
    dx, dy = dx / n, dy / n
    local side = a.side or 0
    x, y, z = w.player[1] + dx * a.ahead + dy * side, w.player[2] + dy * a.ahead - dx * side, w.player[3]
  end
  if z == nil then z = C.where().player[3] end
  if a.ground ~= false then z = C.ground({x = x, y = y, z = z}) or z end
  local objs = (e.project.places[e.place] or {}).objects or {}
  C.game({cmds = {string.format('cj_place_at("%s", %.3f, %.3f, %.3f, 0, 0, %s)', a.template, x, y, z,
                                tostring(a.yaw or 0))}})
  return {place = e.place, before = #objs, at = {x, y, z}}
end

DOC.point = "Answer Conjunction when it waits for a point clicked in the world: x, y (z: the ground there)"
function C.point(a)
  local e = ed()
  local z = a.z or C.ground({x = a.x, y = a.y, z = C.where().player[3]}) or 0
  local r = e.request
  if not r or r.how ~= "point" then
    error("Conjunction waits for no point (it waits for: " .. tostring(r and r.how) .. ")", 0)
  end
  e.request = nil
  r.done(e.place, {a.x, a.y, z})
  return {a.x, a.y, z}
end

DOC["goto"] = "Teleport the player: to a placed object (ref 'place/id': in front of it, facing it) or to x, y, z"
C["goto"] = function(a)
  local x, y, z, yaw = a.x, a.y, a.z, a.yaw or 0
  if a.ref then
    local place, oid = a.ref:match("^(.-)/(.*)$")
    local o
    for _, it in ipairs(((ed().project.places[place] or {}).objects) or {}) do
      if it.id == oid then o = it end
    end
    if not o then error("nothing placed as " .. a.ref, 0) end
    local face, before = math.rad(o.rot[3]), a.before or 2.0
    x, y, z = o.pos[1] - math.sin(face) * before, o.pos[2] + math.cos(face) * before, o.pos[3]
    yaw = (o.rot[3] + 180) % 360
  end
  return C.game({cmds = {string.format("cj_teleport(%s, %s, %s, %s)", x, y, z, yaw)}})
end

DOC.ground_check = "Lift the project's people that are under the ground (near the player) onto it: started; " ..
                   "ground_check_result says when it is done"
local ground = nil
function C.ground_check()
  local e = ed()
  ground = {done = false, log = {}}
  local g = ground
  e:job(function()
    g.fixed = require("conjunction.play").ground_check(e, function(l) g.log[#g.log + 1] = l end)
  end, function(ok, err)
    g.done = true
    if not ok then g.error = tostring(err) end
  end)
  return {started = true}
end
DOC.ground_check_result = "What ground_check lifted (done = false: still measuring)"
function C.ground_check_result()
  if not ground then error("no ground_check asked", 0) end
  local out = {done = ground.done, log = ground.log, error = ground.error, fixed = {}}
  for _, f in ipairs(ground.fixed or {}) do
    out.fixed[#out.fixed + 1] = {place = f[1], what = f[2], from = f[3], to = f[4]}
  end
  return out
end

require("conjunction.agent_scene").register(C, DOC)   -- (the scene workshop: scene_*)
A.COMMANDS, A.DOC = C, DOC

-- one command -> the JSON answer (or "@<file>" when it is longer than the pipe takes)
local seq = 0
function A.call(cmd, args_json)
  local ok, res = pcall(function()
    local fn = C[cmd]
    if not fn then
      local names = {}
      for k in pairs(C) do names[#names + 1] = k end
      table.sort(names)
      error("unknown command '" .. tostring(cmd) .. "' (commands: " .. table.concat(names, ", ") .. ")", 0)
    end
    local args = (args_json and args_json ~= "") and J.decode(args_json) or {}
    return fn(args)
  end)
  local out = ok and {ok = true, result = res} or {ok = false, error = tostring(res)}
  local okj, text = pcall(J.encode, out)
  if not okj then text = J.encode({ok = false, error = "the answer is no JSON: " .. tostring(text)}) end
  if #text <= A.MAX_REPLY then return text end
  seq = seq + 1
  local path = A.shots_dir() .. "\\reply_" .. seq % 8 .. ".json"
  local f = io.open(path, "wb")
  f:write(text)
  f:close()
  return "@" .. path
end

return A
