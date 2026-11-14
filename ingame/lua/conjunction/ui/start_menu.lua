-- Conjunction in the game's main menu (MaximdeWinter 14.11.: "die App, die pre-startup da ist, nur im Hauptmenü"): F8 there
-- shows the app's window as it was before the game started (app.AppWindow) - the side with its pages, Projects (its
-- ProjectsPage: Add folder, New project, the search, Project / Contents / Last changed, sortable; Open ingame: <name>
-- once one is clicked, History), Library and Settings (the editor's windows as pages). Open ingame starts a session of its own (sessions.start_project: a new game from the game's files in the
-- project's world, no save loaded) and the editor opens it there. F8 or Close: the game's menu as it was.
--   SM.frame(w, h)   once a frame while there is no world
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local D = w3.ui.draw
local SM = {shown = false, f8 = false, rows = nil, cur = nil, sort = {3, true}, search = "", starting = nil,
            new = nil, bar = IV.bar(1, 0, 0), state = {}, page = "Projects"}

SM.W, SM.H, SM.SIDE, SM.ROW_H, SM.HEAD_H = 1100, 720, 180, 28, 26
SM.PAGES = {"Projects", "Library", "Settings"}

-- the windows the pages open (a file to pick, History, a question): the panel's way (panel.open_win), over the page
local PN = require("conjunction.ui.panel")
local HOST = {windows = {}, win_order = {}}
HOST.open_win, HOST.window_closed = PN.open_win, PN.window_closed
SM.host = HOST
local function host_covers(x, y, from)
  for i = from or 1, #HOST.win_order do
    local w = HOST.win_order[i]
    if w.shown and w:covers(x, y) then return true end
  end
  return false
end
-- Library and Settings: the editor's windows (library_window, settings_window) as the page, their hits the page's
local PAGE = {}
function PAGE:hit(id, r)
  local mx, my = w3.ui.mouse()
  if CT.blocker and CT.blocker(mx, my) then return false, false, false end
  w3.ui.set_pos(r.x, r.y)
  local clicked, hovered, held = w3.ui.hit("start.page." .. id, r.w, r.h)
  if CT.IM.covers(mx, my) then return false, false, false end
  return clicked == 1, hovered, held
end
local function page_body(name)
  SM.bodies = SM.bodies or {}
  local b = SM.bodies[name]
  if not b then
    if name == "Library" then b = require("conjunction.ui.library_window").new(HOST)
    else b = require("conjunction.ui.settings_window").new(HOST) end
    b.win = PAGE
    SM.bodies[name] = b
  end
  return b
end
local SKIP = {build = true, parked = true, versions = true, __pycache__ = true}

-- when a project was last changed: its newest file (project.yml, places, quests), not its build (app.last_changed)
local function last_changed(path)
  local newest = 0
  local function walk(dir, depth)
    for _, e in ipairs(w3.fs.list(dir) or {}) do
      local p = dir .. "\\" .. e.name
      if e.dir then
        if depth < 4 and not SKIP[e.name] then walk(p, depth + 1) end
      else
        local t = w3.fs.mtime(p)
        if t and t > newest then newest = t end
      end
    end
  end
  walk(path, 0)
  return newest
end

-- the projects with their quests (ProjectsPage.fill): {name, contents, when, t, path}
function SM.fill()
  local PR = require("conjunction.project")
  local QS = require("conjunction.quests")
  local rows = {}
  for _, path in ipairs(PR.recent()) do
    local ok, pr = pcall(PR.open, path)
    if ok and pr then
      local meta = pr.meta or {}
      local titles = {}
      if meta.kind == "place" then
        titles = {"Place mod"}
      else
        local okq, qs = pcall(QS.all_quests, meta)
        for _, q in ipairs(okq and qs or {}) do titles[#titles + 1] = tostring(q.title or "Untitled") end
      end
      local t = last_changed(path)
      rows[#rows + 1] = {tostring(meta.name or path:match("([^\\/]*)$")), table.concat(titles, ", "),
                         t > 0 and os.date("%d.%m.%Y %H:%M", math.floor(t)) or "", t = t, path = path}
    end
  end
  SM.rows, SM.cur = rows, nil
  SM.sorted()
end
function SM.sorted()
  local col, down = SM.sort[1], SM.sort[2]
  table.sort(SM.rows, function(a, b)
    local x, y = col == 3 and a.t or a[col]:lower(), col == 3 and b.t or b[col]:lower()
    if x == y then return a[1]:lower() < b[1]:lower() end
    if down then return x > y end
    return x < y
  end)
end
-- the rows the search leaves (every word typed in the name or the quests, any case)
local function visible()
  local words = {}
  for w in SM.search:lower():gmatch("%S+") do words[#words + 1] = w end
  local out = {}
  for _, r in ipairs(SM.rows or {}) do
    local text = (r[1] .. " " .. r[2]):lower()
    local all = true
    for _, w in ipairs(words) do if not text:find(w, 1, true) then all = false break end end
    if all then out[#out + 1] = r end
  end
  return out
end

-- the sessions mod (sessions.ensure_mod) made at the first F8 when it is not there yet: the game reads it only at its
-- start (14.11.: a fresh install had none until a save had been loaded once - Open ingame did nothing)
local function check_sessions()
  if SM.sessions_checked then return end
  SM.sessions_checked = true
  local ok, made = pcall(function()
    return require("conjunction.sessions").ensure_mod(require("conjunction.config").load().game)
  end)
  if not ok then print("[sessions] " .. tostring(made)) elseif made then SM.restart = true end
end

local function open(row)
  if SM.starting then return end
  if SM.restart then SM.message = "Restart the game once, then Open ingame" return end
  SM.starting = row[1]
  local ok, err = pcall(require("conjunction.sessions").start_project, row.path)
  if not ok then
    SM.starting = nil
    SM.message = "The session did not start: " .. tostring(err)
  end
end

-- Add folder (app.ProjectsPage.add_folder): a project from elsewhere, its project.yml picked
local function add_folder()
  local DLG = require("conjunction.ui.dialogs")
  local P = require("conjunction.project")
  DLG.pick_file(HOST, "Add a project", P.PROJECTS, "Project (project.yml)", function(path)
    if not path then return end
    local folder = P.add_project(path)
    if not folder then SM.message = "Not a project (no project.yml there)" return end
    SM.fill()
    for _, r in ipairs(SM.rows) do if P.key_of(r.path) == P.key_of(folder) then SM.cur = r end end
  end)
end
-- History (app.ProjectsPage.show_history): who made and changed the chosen project, whether its signatures hold
local function history(row)
  local DW = require("conjunction.ui.dialog_window")
  local HW = require("conjunction.ui.history_window")
  local PV = require("conjunction.provenance")
  local steps = PV.read(row.path)
  local check = #steps > 0 and PV.check(steps, PV.content_hash(row.path)) or nil
  DW.open(HOST, "history", "History of " .. (row.path:match("([^\\/]+)$") or row.path), HW.new(steps, check))
end

local function button(id, x, y, text, o)
  o = o or {}
  local w, h = Q.button_size(text)
  w = o.w or w
  local clicked, hovered, held = CT.hit_box(id, {x = x, y = y, w = w, h = h})
  if o.disabled then clicked, hovered, held = false, false, false end
  Q.button(x, y, w, h, text, {hover = hovered or held, pressed = held and hovered, primary = o.primary,
                              disabled = o.disabled, fg = (not o.primary) and T.BUTTON_TEXT or nil})
  return clicked, w, h
end

-- New project (app.NewProjectDialog): its name and kind, then Create and open ingame
local function new_row(x, y, w)
  local n = SM.new
  local _, eh = Q.edit_size(118)
  local _, name = CT.edit("start.new.name", x, y, w - 470, n.name, {h = eh, placeholder = "Project name"})
  n.name = name
  local bx = x + w - 462
  for _, k in ipairs({{"quest", "Quest"}, {"place", "Place mod"}}) do
    local c, bw = button("start.new." .. k[1], bx, y + (eh - 29) // 2, (n.kind == k[1] and "● " or "○ ") .. k[2])
    if c then n.kind = k[1] end
    bx = bx + bw + 6
  end
  local ok_name = name:find("%S") ~= nil
  local c, bw = button("start.new.go", bx, y + (eh - 29) // 2, "Create and open ingame", {primary = true,
                                                                                         disabled = not ok_name})
  if c then
    local PR = require("conjunction.project")
    local okp, path = pcall(PR.new_project, name, n.kind)
    SM.new = nil
    if okp and path then
      SM.fill()
      for _, r in ipairs(SM.rows) do if r.path == path then open(r) end end
    else
      SM.message = "The project was not made: " .. tostring(path)
    end
  end
  bx = bx + bw + 6
  if button("start.new.cancel", bx, y + (eh - 29) // 2, "Cancel") then SM.new = nil end
  return eh
end

local function table_view(r, rows)
  Q.view_frame(r.x, r.y, r.w, r.h)
  local vx, vy, vw, vh = r.x + 1, r.y + 1, r.w - 2, r.h - 2
  local body_y, body_h = vy + SM.HEAD_H, vh - SM.HEAD_H
  local need = #rows * SM.ROW_H
  local b = SM.bar
  local bar = need > body_h
  if bar then vw = vw - 10 end
  b.single, b.page = SM.ROW_H, body_h
  IV.range(b, math.max(0, need - body_h))
  local c1 = math.max(160, math.min(300, vw // 4))
  local c3 = 150
  local cols = {c1, math.max(0, vw - c1 - c3), c3}
  local heads = {"Project", "Contents", "Last changed"}
  local hx = vx
  for i, cw in ipairs(cols) do
    local text = heads[i] .. (SM.sort[1] == i and (SM.sort[2] and "  ▼" or "  ▲") or "")
    Q.header_left(hx, vy, cw, SM.HEAD_H, text)
    if CT.hit_box("start.head." .. i, {x = hx, y = vy, w = cw, h = SM.HEAD_H}) then   -- (a click sorts by it)
      if SM.sort[1] == i then SM.sort[2] = not SM.sort[2] else SM.sort = {i, i == 3} end
      SM.sorted()
    end
    hx = hx + cw
  end
  local over = CT.over({x = vx, y = body_y, w = vw, h = body_h})
  local _, _, wheel = w3.ui.mouse()
  if over and wheel and wheel ~= 0 then IV.wheel(b, wheel >= 0 and math.min(wheel, 1) or math.max(wheel, -1), 3) end
  D.clip(vx, body_y, vw, body_h, function()
    for i, row in ipairs(rows) do
      local ry = body_y + (i - 1) * SM.ROW_H - b.value
      if ry + SM.ROW_H >= body_y and ry < body_y + body_h then
        local chosen = SM.cur == row
        if chosen then D.fill(vx, ry, vw, SM.ROW_H, T.CHOSEN) end
        local cx = vx
        for c, cw in ipairs(cols) do
          local fg = c == 1 and T.TEXT or T.DIM
          Q.text(cx + 9, ry + Q.vcenter(SM.ROW_H, Q.line_h()), fg, row[c], T.FONT, false, chosen and T.CHOSEN or T.SURFACE)
          cx = cx + cw
        end
        local clicked, hovered = CT.hit_box("start.row." .. i, {x = vx, y = ry, w = vw, h = SM.ROW_H})
        if hovered and w3.ui.mouse_double(1) and SM.cur == row then open(row) end
        if clicked then SM.cur, SM.message = row, nil end
      end
    end
  end)
  if #rows == 0 then
    Q.text(vx + 9, body_y + 8, T.DIM, SM.rows and #SM.rows > 0 and "No project has these words" or "No projects yet",
           T.FONT, false, T.SURFACE)
  end
  if bar then
    SBAR.draw(SM.state, "start.vbar", b, {x = vx + vw, y = vy, w = 10, h = vh}, "v",
              function(id, rr) return CT.hit_box(id, rr) end)
  end
end

local projects_page

function SM.frame(w, h)
  -- the game started again for a test run (Build & Play, a quest that changes game files): its session started by
  -- itself once the main menu is up (sessions.start_project with later)
  if not SM.auto_done then
    local SE = require("conjunction.sessions")
    local m = SE.peek_mark()
    if m and m.later then
      SM.auto_t0 = SM.auto_t0 or w3.time()
      if w3.time() - SM.auto_t0 > 4.0 then
        SM.auto_done = true
        SM.shown = false
        pcall(SE.launch, m.world)
      end
      return
    end
    SM.auto_done = true
  end
  local down = w3.input.down(0x77)                -- F8
  if down and not SM.f8 then
    SM.shown = not SM.shown
    if SM.shown then SM.fill() check_sessions() SM.starting, SM.message, SM.new = nil, nil, nil end
  end
  SM.f8 = down
  if not SM.shown then return end
  w3.ui.take_mouse(true)
  local DK = require("conjunction.ui.dock")
  if not DK.W then DK.W, DK.H = w, h end
  HOST.W, HOST.H = w, h
  w3.ui.panel("conjunction_start", 0, 0, w, h, {bg = 0x00000000}, function()
    -- (the page under the windows it opened: they take the mouse first)
    CT.blocker = function(mx, my) return host_covers(mx, my) end
    local ww, wh = math.min(SM.W, w - 40), math.min(SM.H, h - 40)
    local x, y = (w - ww) // 2, (h - wh) // 2
    D.fill(0, 0, w, h, 0x00000090)
    D.fill(x, y, ww, wh, T.BG)
    D.rect(x, y, ww, wh, T.EDGE, 1)
    -- the side (#side, 180 wide): its pages, the version at its foot
    D.fill(x + 1, y + 1, SM.SIDE, wh - 2, T.SURFACE)
    for i, name in ipairs(SM.PAGES) do
      local ry = y + 1 + 8 + (i - 1) * 30
      local r = {x = x + 1, y = ry, w = SM.SIDE, h = 30}
      local clicked, hovered = CT.hit_box("start.side." .. name, r)
      local chosen = SM.page == name
      local bg = chosen and T.CHOSEN or (hovered and T.HOVER or T.SURFACE)
      if chosen or hovered then D.fill(r.x, r.y, r.w, r.h, bg) end
      Q.text(r.x + 14, ry + Q.vcenter(30, Q.line_h()), chosen and T.BRIGHT or T.TEXT, name, T.FONT, false, bg)
      if clicked and not chosen then
        SM.page = name
        if name ~= "Projects" and SM.bodies and SM.bodies[name] and SM.bodies[name].refresh then
          SM.bodies[name]:refresh()
        end
      end
    end
    local ver = "Conjunction " .. require("conjunction.provenance").VERSION
    Q.text(x + 1 + 12, y + wh - 12 - Q.line_h(T.FONT_SMALL), T.DIM, ver, T.FONT_SMALL, false, T.SURFACE)
    if SM.page ~= "Projects" then
      local r = {x = x + 1 + SM.SIDE, y = y + 1, w = ww - 2 - SM.SIDE, h = wh - 2}
      PAGE.rect = r
      local ok, err = pcall(function() page_body(SM.page):frame(r) end)
      if not ok then Q.text(r.x + 16, r.y + 12, 0xe57a7aff, tostring(err), T.FONT, false, T.BG) end
    else
      projects_page(x, y, ww, wh)
    end
    -- the windows the pages opened, each under the ones opened after it; the lists and tips over all
    local order = {table.unpack(HOST.win_order)}
    for i, win in ipairs(order) do
      CT.blocker = function(mx, my) return host_covers(mx, my, i + 1) end
      if win.shown then
        local ok, err = pcall(function() win:frame() end)
        if not ok then win:close() SM.message = tostring(err) end
      end
    end
    CT.blocker = nil
    CT.IM.frame()
    CT.frame()
  end)
end

function projects_page(x, y, ww, wh)
  -- the page (margins 16 12 16 12, 8 apart)
  local px, py = x + 1 + SM.SIDE + 16, y + 12
  local pw = ww - 2 - SM.SIDE - 32
  Q.label(px, py, "Projects", "head", T.BG)
  local _, hh = Q.label_size("Projects", "head")
  local nw = select(1, Q.button_size("New project"))
  if button("start.new", px + pw - nw, py + (hh - 29) // 2, "New project") then SM.new = {name = "", kind = "quest"} end
  local fw = select(1, Q.button_size("Add folder"))
  if button("start.folder", px + pw - nw - 6 - fw, py + (hh - 29) // 2, "Add folder") then add_folder() end
  py = py + hh + 8
  if SM.new then
    py = py + new_row(px, py, pw) + 8
  else
    local _, eh = Q.edit_size(118)
    local _, s = CT.edit("start.search", px, py, pw, SM.search, {h = eh, placeholder = "Search"})
    if s ~= SM.search then SM.search, SM.cur = s, nil end
    py = py + eh + 8
  end
  local bottom = y + wh - 12
  local bh = 29
  local by = bottom - bh
  table_view({x = px, y = py, w = pw, h = by - 8 - py}, visible())
  -- Open ingame: <name> (once one is clicked), the line beside it, Close at the right
  local label = SM.cur and ("Open ingame: " .. SM.cur[1]) or "Open ingame"
  local c, bw = button("start.open", px, by, label, {primary = true, disabled = SM.cur == nil or SM.starting ~= nil})
  if c and SM.cur then open(SM.cur) end
  local hc, hw = button("start.history", px + bw + 6, by, "History", {disabled = SM.cur == nil})
  if hc and SM.cur then history(SM.cur) end
  local line = SM.message or (SM.starting and ("Starting " .. SM.starting .. "...")) or ""
  Q.text(px + bw + 6 + hw + 12, by + Q.vcenter(bh, Q.line_h()), SM.message and 0xe57a7aff or T.DIM, line, T.FONT,
         false, T.BG)
  local cw = select(1, Q.button_size("Close"))
  if button("start.close", px + pw - cw, by, "Close") then SM.shown = false end
end

-- the world came: the window is gone, the windows it opened with it
function SM.reset()
  SM.shown, SM.starting, SM.new = false, nil, nil
  for _, win in ipairs({table.unpack(HOST.win_order)}) do pcall(win.close, win) end
end

return SM
