-- Conjunction in the game (TW3SE mod: tw3se\mods\conjunction). The editor (editor.lua) and its bar over the game
-- (ui/hud.lua) on the last project, as the app opened it (project.recent, its first place).
--
-- Steps 1 and 2 of docs/INGAME_PLAN.md: the bar, the keys, flying, select / place / move, and the panel (ui/panel.lua:
-- its header, the Places tab; the catalog, the quest and the build come with their steps).
local dir = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[\\/]init%.lua$", "")
local mods = dir:gsub("[\\/]conjunction$", "")
package.path = mods .. "\\?.lua;" .. mods .. "\\?\\init.lua;" .. package.path

-- Lua's collector in its generational mode (Lua 5.4): what a frame makes and drops is collected young and cheap - the
-- incremental one let it pile up and took it in bursts, frames of up to 111 ms with the story map open (14.11.,
-- measured: 41 ms at most, half as many slow frames)
collectgarbage("generational")

-- the pictures of the Conjunction before this one freed first (13.11.: TW3SE keeps a mod's pictures over a live
-- reload; after an evening of them its 1984 slots were full - "no free picture slot", every icon gone). Each picture
-- Conjunction's own code loads is kept in a global (it outlives the reload); w3.ui.image_load wrapped once, the
-- originals kept in w3.ui, so a reload wraps them and not the wrapper. Other mods' pictures are not counted.
do
  local ui = w3.ui
  local load = rawget(ui, "_cj_image_load") or ui.image_load
  local free = rawget(ui, "_cj_image_free") or ui.image_free
  ui._cj_image_load, ui._cj_image_free = load, free
  local n = 0
  for id in pairs(CJ_PICTURES or {}) do
    pcall(free, id)
    n = n + 1
  end
  if n > 0 then print(string.format("[conjunction] %d pictures of the last start freed", n)) end
  CJ_PICTURES = {}
  local own = "[\\/]conjunction[\\/]"
  ui.image_load = function(...)
    local id, w, h = load(...)
    if id then
      local src = debug.getinfo(2, "S").source
      if src:find(own) then CJ_PICTURES[id] = true end
    end
    return id, w, h
  end
  ui.image_free = function(id, ...)
    if id ~= nil then CJ_PICTURES[id] = nil end
    return free(id, ...)
  end
end

local Y = require("conjunction.yaml")
local CFG = require("conjunction.config")
local P = require("conjunction.project")
local EDITOR = require("conjunction.editor")
local HUD = require("conjunction.ui.hud")
local PANEL = require("conjunction.ui.panel")
local CT = require("conjunction.ui.controls")
local GAME = require("conjunction.game_sys")

-- project.recent: the projects opened last that still exist, then every other one in Documents\Conjunction
local function last_project()
  local cfg = CFG.load()
  for _, p in ipairs(Y.is_list(cfg.recent) and cfg.recent or {}) do
    if type(p) == "string" and w3.fs.exists(p .. "\\project.yml") then return p end
  end
  for _, e in ipairs(w3.fs.isdir(P.PROJECTS) and w3.fs.list(P.PROJECTS) or {}) do
    local p = P.PROJECTS .. "\\" .. e.name
    if e.dir and w3.fs.exists(p .. "\\project.yml") then return p end
  end
  return nil
end

local BR = require("conjunction.bugreport")
-- the agent (agent.lua, the app's agent.py): commands through TW3SE's pipe - `lua return CJ_AGENT(cmd, json)`
local AGENT = require("conjunction.agent")
AGENT.install()
function CJ_AGENT(cmd, args_json) return AGENT.call(cmd, args_json) end
-- the engine for the app (engine.lua, docs/APP_ENGINE_PLAN.md): the app installs the mod with a file engine_only
-- beside this one; the app draws the windows, nothing of the editor starts here
if w3.fs.exists(dir .. "\\engine_only") then
  require("conjunction.engine").start(AGENT)
  return
end
-- an error of a frame: printed and kept for the bug report (bugreport._errors)
local function failed_at(what, err)
  print("[conjunction] " .. what .. ": " .. tostring(err))
  BR.error(what .. ": " .. tostring(err))
end

local function start()
  pcall(BR.start_session_log)                     -- (the mod's output also into data\logs\session.log)
  -- Qt's application (cj_qt: what Qt draws itself - text, its own icons, the 3D view) comes up on its thread now,
  -- so a window that needs it later does not wait for it
  if w3.plugin and w3.plugin.cj_qt_gl_start then pcall(w3.plugin.cj_qt_gl_start) end
  -- the index of the game's files made on cj_core's thread now (25.10.: the first window that read a game file built
  -- it in its frame - the lag of the first window after the game's start)
  pcall(function() require("conjunction.depot").open_async(require("conjunction.config").load().game) end)
  -- the one worked on last, or a new one when there is none (project.last_or_new)
  local path = last_project() or P.new_project("Untitled")
  local pr = P.open(path)
  local place = Y.keys(pr.places)[1] or "main"
  local sys = GAME.new()
  local panel = PANEL.new(nil)
  local ed = EDITOR.new(pr, place, "", sys, {panel = panel})
  panel.ed = ed
  local hud = HUD.new(ed)
  ed.hud = hud
  -- hud.py's window calls: the HUD is drawn anew every frame, they have nothing to do
  for _, m in ipairs({"sync", "show", "hide", "update", "close_menu", "click_through"}) do
    if hud[m] == nil then hud[m] = function() end end
  end
  -- a window that takes the whole screen (the cutscene editor, with a top bar of its own): the bar is not drawn then
  -- and takes no clicks (in Qt that window lay over the bar)
  function panel:full_window()
    for _, w in pairs(self.windows or {}) do
      if w.shown and w.body and w.body.full_screen and w.body:full_screen() then return true end
    end
    return false
  end
  -- editor.py asks with screen positions (hud.over_bar(gx, gy)); hud.lua works in the game picture's
  local over = hud.over_bar
  function hud:over_bar(gx, gy)
    if panel:full_window() then return false end
    local cx, cy = sys.client()
    return over(self, gx - (cx or 0), gy - (cy or 0))
  end
  -- the bar and its menus are windows over the panel in Qt: where they are, the panel's controls get no mouse; with a
  -- menu of the bar open, none at all (panel.frame's blocked)
  CT.blocker = function(mx, my)
    if panel:full_window() then return false end
    return hud.menu_open ~= nil or over(hud, mx, my)
  end
  CJ_BASE_BLOCKER = CT.blocker                     -- (each frame starts with it again: frame below)
  -- the quests to play: synced now, watched while the editor runs (library.lua)
  local okl, errl = pcall(function() ed:watch_quests() end)
  if not okl then print("[library] " .. tostring(errl)) end
  -- the first start: what a profile is, said once (a profile is opt-in - profile_view.first_hint)
  local okp, errp = pcall(require("conjunction.ui.profile_first").first_hint, ed)
  if not okp then print("[profile] " .. tostring(errp)) end
  -- radish for building: checked once per folder, unpacked from its Nexus zip, or its window (__main__: radish_view)
  local okr, errr = pcall(require("conjunction.radish_tools").at_start, ed)
  if not okr then print("[radish] " .. tostring(errr)) end
  -- our session starts in the game when they are not there yet (setup.install_scripts: the game reads them at its start)
  local oks, errs = pcall(function() require("conjunction.sessions").ensure_mod(require("conjunction.config").load().game) end)
  if not oks then print("[sessions] " .. tostring(errs)) end
  -- a newer Conjunction, TW3SE or pack (only when Settings asks for it) and what Conjunction updated in the game by
  -- itself, a little after the start (__main__: after the logo)
  sys.after(2600, function()
    local oku, erru = pcall(require("conjunction.updates").at_start, ed)
    if not oku then print("[updates] " .. tostring(erru)) end
  end)
  print(string.format("[conjunction] %s, place %s: F8 = edit or play",
                       pr:id(), place))
  return {ed = ed, hud = hud, sys = sys, panel = panel}
end

-- the editor starts once the player is in the world (the app started it after the save had loaded: at the main menu
-- the editor's scripts have no world to edit)
local function in_world()
  local ok, p = pcall(function() return w3.player and w3.player() end)
  return ok and p ~= nil
end
local app, failed = nil, false

-- what the panel's first opening needs, read while the game starts (assets.preload; 25.10.: the first window after
-- the game's start lagged), a slice each frame (12.11.: in one go it ran past TW3SE's 5 s after an update)
local preload = coroutine.create(function()
  local ASSETS = require("conjunction.assets")
  ASSETS.sliced(ASSETS.preload)
end)
local function preload_step()
  if not preload then return end
  local ok, err = coroutine.resume(preload)
  if not ok then print("[conjunction] the catalog read ahead: " .. tostring(err)) end
  if coroutine.status(preload) == "dead" then preload = nil end
end

w3.ui.overlay(true)
local HITCLIP = require("conjunction.ui.hitclip")
local START_MENU = require("conjunction.ui.start_menu")
local had_world = nil
local function frame()
  -- the game's main menu: F8 shows the projects (ui/start_menu.lua; never while a job of the editor waits on a load)
  local world = in_world()
  if not world and not (app and #app.ed.jobs > 0) then
    local cw, ch = select(3, w3.input.client())
    if cw then
      local okm, errm = pcall(START_MENU.frame, cw, ch)
      if not okm then print("[conjunction] start menu: " .. tostring(errm)) end
    end
  end
  -- a world came after none: a session started for a project takes the editor there (editor.session_arrived)
  local arrived = world and had_world == false
  had_world = world
  if world and START_MENU.shown then START_MENU.reset() end
  if not app then
    if failed or not world then return end
    local ok, a = pcall(start)
    if not ok then
      failed = true
      print("[conjunction] could not start: " .. tostring(a))
      return
    end
    if not a then failed = true return end
    app = a
    AGENT.app = a
  end
  local ed, hud = app.ed, app.hud
  -- (the bar's blocker as each frame's start: a frame that failed half way left the panel's own in its place - it
  -- blocks wherever a window is - and every frame after took that as its start: no window took a click any more,
  -- 14.11.)
  if CJ_BASE_BLOCKER then CT.blocker = CJ_BASE_BLOCKER end
  if arrived or (world and not ed.session_checked) then
    ed.session_checked = true
    local oks, errs = pcall(function() ed:session_arrived(arrived) end)
    if not oks then failed_at("session", errs) end
  end
  local ok2, err = pcall(function()
    app.sys.run_timers()
    ed:tick()
  end)
  if not ok2 then failed_at("tick", err) end
  local x, y, w, h = app.sys.client()
  if not w then return end
  local panel = app.panel
  local card = ed.build_card                    -- (Build & Play's card over the game: build_window.lua)
  if card and card.closed then ed.build_card, card = nil, nil end
  local function draw_card()
    if not card then return false end
    local ok6, over = pcall(function() return card:frame(w, h) end)
    if not ok6 then failed_at("build card", over) return false end
    return over and card.state == "failed"      -- (failed: its Close takes the mouse)
  end
  if not ed.editing then
    -- (playing: only the notice, "Playing. Press F8 ...", and the build's card over the game; the game keeps the
    -- mouse)
    if panel.notice:visible() or card then
      local mx0, my0 = app.sys.cursor()
      w3.ui.take_mouse(card ~= nil and card.state == "failed" and
                       mx0 - x >= (w - math.min(860, w)) // 2 and mx0 - x < (w + math.min(860, w)) // 2 and
                       my0 - y >= (h - math.min(560, h)) // 2 and my0 - y < (h + math.min(560, h)) // 2)
      w3.ui.panel("conjunction_hud", 0, 0, w, h, {bg = 0x00000000}, function()
        draw_card()
        local ok5, err5 = pcall(function() panel:draw_notice(w, h) end)
        if not ok5 then failed_at("notice", err5) end
        local ok8, err8 = pcall(CT.frame)
        if not ok8 then failed_at("tooltip", err8) end
      end)
    end
    return
  end
  local mx, my = app.sys.cursor()
  -- the overlay takes the mouse over the bar and its parts, the panel and its open list (hud.click_through,
  -- panel.covers); the game has it elsewhere
  w3.ui.take_mouse(hud:over_bar(mx, my) or hud.renaming == true or panel:covers(mx - x, my - y))
  -- (the panel at the picture's corner: the UI works in the game picture's positions, x and y are where that picture is
  -- on the screen - a window off the screen's corner or on a second monitor put the panel off the picture)
  w3.ui.panel("conjunction_hud", 0, 0, w, h, {bg = 0x00000000}, function()
    -- the world's rings and frames first (the hud window's own painting, under the panel and its windows), then the
    -- panel, the bar over it (its window is above the panel's)
    local ok7, err7 = pcall(function() hud:frame_world(w, h) end)
    if not ok7 then failed_at("world", err7) end
    -- (the bar and its strip under the panel and its windows: MaximdeWinter 14.11. - the rest of the bar's over them, below)
    if not panel:full_window() then
      local ok9, err9 = pcall(function() hud:frame_under(w, h, function(cx, cy) return panel:covers(cx, cy) end) end)
      if not ok9 then failed_at("hud", err9) end
    end
    local ok4, err4 = pcall(function() panel:frame(w, h, hud.menu_open ~= nil) end)
    if not ok4 then failed_at("panel", err4) end
    if not panel:full_window() then
      local ok3, err3 = pcall(function() hud:frame(w, h, true) end)
      if not ok3 then failed_at("hud", err3) end
    end
    draw_card()
    local ok5, err5 = pcall(function() panel:draw_notice(w, h) end)
    if not ok5 then failed_at("notice", err5) end
    -- the tooltip of the control the mouse rests on, over everything (MaximdeWinter 23.10.: never called here, none showed)
    local ok8, err8 = pcall(CT.frame)
    if not ok8 then failed_at("tooltip", err8) end
  end)
end
w3.on_ui(function()
  preload_step()
  AGENT.frame_start()                          -- (the agent's clicks and keys, given to the UI now)
  pcall(require("conjunction.scene_work").sub_tick)   -- (the subtitles of one's own lines in the preview)
  pcall(require("conjunction.scene_work").after_play_tick)   -- (the screen back after a preview)
  -- (each box cut to the clip it is drawn in: one scrolled out of a list took clicks there, ui/hitclip.lua)
  local ok, err = pcall(HITCLIP.run, frame)
  if not ok then print("[conjunction] frame: " .. tostring(err)) end
  -- (a field typed in whose card went this frame: what was typed kept - ui/qb_widgets.lua)
  local okf, errf = pcall(require("conjunction.ui.qb_widgets").flush_stale)
  if not okf then print("[conjunction] fields: " .. tostring(errf)) end
  AGENT.frame_done()                            -- (what this frame drew: the agent's widgets)
end)
