-- The editor's side panel over the game, as conjunction/panel.py lays it out and draws it (rules: ingame/spec/panel.md):
-- its frame, its header (the project with its menu, the gear, the X), the tabs and the Places tab. The catalog and
-- its inspector (step 2c), the quest (step 5) and the build (step 7) come later; their tabs are there and empty.
--
--   local p = PANEL.new(ed)       ed: the editor (editor.lua); ed.panel = p
--   p:frame(W, H)                 every frame inside the overlay, before the bar (the bar's window is above it)
--
-- Sizes are Qt's (ingame/ref/qt/panel_*.json): the layouts go through ui/layout.lua (QBoxLayout, QGridLayout).
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local L = require("conjunction.ui.layout")
local CT = require("conjunction.ui.controls")
local IM = require("conjunction.ui.inline_menu")
local TT = require("conjunction.ui.tooltips")
local TIPS = require("conjunction.ui.tips")
local LE = require("conjunction.ui.lineedit")
local PT = require("conjunction.ui.plaintext")
local TL = require("conjunction.ui.textlayout")
local Y = require("conjunction.yaml")
local D = w3.ui.draw
local CFG = require("conjunction.config")
local PN = {}
PN.__index = PN

local function rgba(r, g, b, a) return (r << 24) | (g << 16) | (b << 8) | (a or 255) end
local function hex(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
PN.C = {
  bg = rgba(24, 24, 26, 235), edge = hex("#444444"),             -- #panel
  title = hex("#9a9a9a"), project = hex("#cfcfcf"),              -- the header
  label = hex("#cccccc"), dim = hex("#9a9a9a"),                  -- QLabel{color:#ccc}, the small grey lines
  tree_bg = hex("#1d1d20"), tree_edge = hex("#3a3a3e"), tree_text = hex("#dddddd"), tree_dim = hex("#8a8a8a"),
  box_bg = hex("#202023"), box_edge = hex("#3a3a3e"),            -- #areabox, #selbox
  button = hex("#dddddd"), check = hex("#ffffff"),               -- QPushButton's #ddd; a check box: the palette's
  inline_bg = hex("#1e1e1e"),                                    -- an inline list's body: the palette's window
}
local C = PN.C
-- the panel's fields: theme.py's controls without an app page's QWidget{color} (their own BRIGHT text)
PN.EDIT_STYLE = setmetatable({fg = T.BRIGHT}, {__index = CT.EDIT_STYLE})
PN.INSPECTOR_W, PN.EDGE, PN.MIN_W, PN.MIN_H = 330, 7, 420, 320
PN.HEADER_H = 24
local TREE_INDENT, TREE_ROW = 14, 25
-- the gear's settings (panel.SETTINGS): config key, label, on by default
PN.SETTINGS = {{"catalog_stays", "Stays open while placing", false},
               {"catalog_back", "Back to the catalog after placing", true},
               {"see_through", "See-through while placing", true}}
local TABS = {"Assets", "Places", "Quest", "Build"}       -- (0-based in Qt: 0 the catalog, 1 Places ...)

local function call(obj, name, ...)
  local f = obj and obj[name]
  if type(f) == "function" then return f(obj, ...) end
end
local function inside(x, y, r) return r and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h end
local function objects_of(place) return (place and place.objects) or {} end
-- Python's bool() of a value from a YAML file
local function truthy(v)
  return not (v == nil or v == false or v == Y.null or v == 0 or v == "" or (type(v) == "table" and v ~= Y.null and next(v) == nil))
end

function PN.new(ed)
  local self = setmetatable({ed = ed, shown = false, bar_shown = true, tab = 1, rect = nil, renaming = false,
                             rename_text = "", new_place = "", area_at = nil, sel_id = nil, tree_scroll = 0,
                             expanded = {}, tree_sel = nil, board = false, building = false, inspector = false,
                             inspector_wanted = false, drag = nil, resize = nil}, PN)
  self.ins = require("conjunction.ui.inspector").new(self)
  self.wc = require("conjunction.ui.world_card").new(self)
  self.notice = require("conjunction.ui.notice").new(self)
  -- moved by its header, resized at its border, docked at a side of the game (dock.lua; panel._frame_mouse)
  local DK = require("conjunction.ui.dock")
  self.min_w, self.min_h = PN.MIN_W, PN.MIN_H
  self.docker = DK.new(self, "panel", ed)
  self.docker.extra = function() return self:inspector_extra() end
  self.mover = DK.mover(self, "panel", ed, {min_w = PN.MIN_W, min_h = PN.MIN_H, docker = self.docker,
                                            hit = function(id, r) return self:hit(id, r) end,
                                            keep = function(r) self:keep_rect(r) end})
  return self
end

-- --- what the editor asks (panel.py's methods, as editor.lua calls them) ---
function PN:isVisible() return self.shown end
function PN:tabs_visible() return self.shown and not self.tabs_hidden end   -- (tabs_hidden: the inspector alone)
function PN:tab_index() return self.tab end
function PN:hide()
  self.shown = false
  self:stop_typing()
  IM.close()
end
function PN:show_tab(i) self.tab = i end
-- editor.toggle_panel: the tabs shown (the catalog loaded), or away; only the inspector open (an object selected): the
-- tabs come next to it (MaximdeWinter 23.10.: the tabs stayed hidden after that - 3 brought the last object's card back)
function PN:toggle(ed)
  if self.shown and self.tabs_hidden then
    self:load_catalog()
    self.tabs_hidden = false
    self:show_inspector(self.inspector_wanted)
    self:place()
  elseif self.shown then
    self:hide()
  else
    self:load_catalog()
    self:sync_places()
    self:sync_quest()
    self:sync_selected()
    self.tabs_hidden = false
    self:show_inspector(self.inspector_wanted)
    self.shown = true
    self:place()
  end
end
-- editor.toggle_project: the project's tabs on the quest, or away
function PN:toggle_project(ed)
  if self:tabs_visible() and self.tab ~= 0 then
    self:hide()
  else
    if not self:tabs_visible() then self:toggle(ed) end
    self:set_tab(self:has_quest() and 2 or 1)
  end
  call(self.ed.hud, "sync")
end
-- panel.load_catalog: the Asset Browser once the asset database is there; without it, it is built first (in the
-- game: assets_build.lua, a little each frame) and the catalog comes when it is ready
function PN:load_catalog()
  if self.catalog ~= nil then return end
  local ASSETS = require("conjunction.assets")
  if not ASSETS.ready() then
    self.catalog_hint = "Building the catalog..."
    self:build_assets()
    return
  end
  local pre = ASSETS.take_preloaded()
  if pre then return self:catalog_made(pre) end
  -- (not read ahead yet, or taken before: read in a job, a slice each frame - the mesh library's rows made anew ran
  -- past TW3SE's 5 s in one frame, 12.11.)
  if self.catalog_reading then return end
  self.catalog_reading = true
  self.catalog_hint = "Reading the catalog..."
  local made
  self.ed:job(function()
    while ASSETS.preloading do coroutine.yield() end
    made = ASSETS.take_preloaded()
    if not made then
      ASSETS.sliced(function()
        made = ASSETS.new()
        made:_all()
      end)
    end
  end, function(ok, err)
    self.catalog_reading = false
    if not ok then
      self.catalog_hint = "The catalog could not be read: " .. tostring(err)
      return
    end
    if self.catalog == nil then self:catalog_made(made) end
  end)
end
function PN:catalog_made(assets)
  self.catalog_hint = nil
  self.assets = assets
  self.catalog = require("conjunction.ui.catalog_view").new(self.ed, self.assets, self.catalog_opts)
  self.catalog.on_current = function(e) self:catalog_current(e) end
  self.catalog.on_chosen = function(e) self:pick(e) end
  local ins = self.ins
  ins.on_place = function(e) self:pick(e) end
  ins.on_favourite = function(e) self.catalog.model:toggle_favourite(e) self.catalog:sync_rows() end
  ins.on_overview = function(what, value)       -- (panel._overview: the catalog shows everything of that kind)
    self:set_tab(0)
    self.catalog.model:show_only(what, value)
    self.catalog:sync_rows()
  end
end
-- the Quest tab (ui/quest_board.lua), made when first wanted
function PN:board_of()
  if not self.board_ui then self.board_ui = require("conjunction.ui.quest_board").new(self) end
  return self.board_ui
end
function PN:sync_quest() if self.board_ui then self.board_ui:sync() end end
-- panel.refresh: the catalog read again (a template was chosen: its recent list)
function PN:refresh()
  if self.catalog then
    self.catalog.model:refresh()
    self.catalog:sync_rows()
  end
end
-- editor.picked / the point asked for: back to the board (it stayed open; closed meanwhile, it opens again)
function PN:show_board(ed)
  if not self:tabs_visible() then self:toggle(ed or self.ed) end
  self:set_tab(2)
end
function PN:restore_quest(shot) self:board_of():restore(shot) end
function PN:world_card_visible() return self.shown and self.wc_shown == true end
function PN:refresh_world_card() self.wc:refresh(self.ed.project.path) end
-- the game's report of the selected object: "worldinfo|fx=a,b|looks=c,d"
function PN:world_info(line)
  local kv = {}
  for part in (tostring(line) .. "|"):gmatch("([^|]*)|") do
    local k, v = part:match("^([^=]*)=(.*)$")
    if k then kv[k] = v end
  end
  local function names(s)
    local out = {}
    for n in (tostring(s or "") .. ","):gmatch("([^,]*),") do if n ~= "" then out[#out + 1] = n end end
    return out
  end
  self.wc:set_info(names(kv.fx), names(kv.looks))
end
function PN:world_say(text) self.wc:say(text) end
-- panel.show_world_card: the world card in the inspector's place (sel: the object's report), or gone
function PN:show_world_card(sel)
  if sel == nil then
    if self.wc_shown then
      self.wc_shown = false
      if self.ins_hidden then self:show_inspector(false) end
    end
    return
  end
  self.ins_hidden = true
  self.wc:show_object(sel, self.ed.project.path)
  self.wc_shown = true
  self:show_inspector(true)
end
-- the game's answer: "invlist|<id>|name:n|..." or "...|none" (no answer)
function PN:live_inventory(line)
  local parts = {}
  for p in (tostring(line) .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = p end
  local items
  if not (#parts == 3 and parts[3] == "none") then
    items = {}
    for k = 3, #parts do
      local name, n = parts[k]:match("^(.*):([^:]*)$")
      if name then items[#items + 1] = {name, math.tointeger(tonumber(n)) or 0} end
    end
  end
  self.ins:live_inventory(items)
end
-- Ctrl+C / Ctrl+V with the mouse over the panel: the step picked on the Quest tab copied, the copy put in after it
-- -> true when the Quest tab took it
function PN:quest_clip(paste)
  if not (self:tabs_visible() and self.tab == 2) then return false end
  local b = self:board_of()
  if not b or b.dialogue or b.chooser then return false end
  if paste then b:paste_node() else b:copy_node() end
  return true
end
-- Delete with the mouse over the panel: what is picked on the Quest tab goes (nothing elsewhere)
function PN:delete_picked()
  if self:tabs_visible() and self.tab == 2 then
    local b = self:board_of()
    if b then b:delete_picked() end
  end
end
-- editor.open_outliner: the panel on the project's places and their objects - or away
function PN:open_outliner(ed)
  if self:tabs_visible() and self.tab == 1 then
    self:hide()
  else
    if not self:tabs_visible() then self:toggle(ed or self.ed) end
    self:set_tab(1)
  end
  call(self.ed.hud, "sync")
end
-- editor.open_panel_tab: the bar's Project menu - the panel open at that tab (0-based, as TABS)
function PN:open_tab(ed, i)
  if not self:tabs_visible() then self:toggle(ed or self.ed) end
  self:set_tab(i)
  call(self.ed.hud, "sync")
end
PN.TABS = TABS
-- View > Scene workshop: one of the game's scenes changed in place and played at once (ui/scene_window.lua)
-- then_(win): once it is open - the first time the game's scenes are read first, in a job (scene_swap.scene_info:
-- in one frame it ran past TW3SE's 5 s for a call and the frame was stopped); nil returned meanwhile
function PN:open_scenes(ed, then_)
  ed = ed or self.ed
  local SS = require("conjunction.scene_swap")
  if not SS.info_ready() and ed and ed.job then
    if not self.scenes_reading then
      self.scenes_reading = true
      self:say("Reading the game's scenes (once, about half a minute) ...", 30000)
      local depot = require("conjunction.depot").open(require("conjunction.config").load().game)
      ed:job(function() SS.scene_info(depot) end, function(ok, err)
        self.scenes_reading = false
        if not ok then self:say("The game's scenes could not be read: " .. tostring(err), 8000) return end
        local w = self:open_scenes(ed)
        if then_ and w then then_(w) end
      end)
    end
    return nil
  end
  local w = self:open_win("scenes", "Scene workshop", "scenes", function(win)
    local kept = require("conjunction.config").load().catalog_windows
    if not (type(kept) == "table" and kept.scenes) then   -- (the first time: wide, beside the panel)
      local g = self.rect or {x = 12, y = 96, w = 516, h = 790}
      -- (no wider or higher than the game's picture: a small window or 720p cut its right side and its list)
      local sw, sh = self.W or 1920, self.H or 1080
      win.rect = {x = g.x + 40, y = g.y, w = math.min(1280, sw - g.x - 48), h = math.min(math.max(640, g.h), sh - g.y - 8)}
    end
    return require("conjunction.ui.scene_window").new(ed, win)
  end)
  if then_ then then_(w) end
  return w
end
-- the bar's Story: the story map in one of the panel's windows (editor.open_story); then_: opened from the quest's
-- Starts - once a quest is taken (with / after it) the window closes and then_() runs
function PN:open_story(ed, then_)
  ed = ed or self.ed
  local w = self:open_win("story", "Story map", "story", function(win)
    return require("conjunction.ui.story_window").new(ed, win)
  end)
  local body = w.body
  if body and body.refresh then
    body:refresh()                              -- (the project's quest may have been hooked elsewhere since)
    if then_ then
      body.on_hook = function()
        body.on_hook = nil
        w:close()
        then_()
      end
    else
      body.on_hook = nil
    end
  end
  return w
end
-- editor.build_play_now: the bar's Build & Play, one click (the Build tab's button, while it is enabled)
function PN:build_play_now()
  if not self.building then self:build(true) end
end
-- editor.show_selected: the inspector beside the game for the object selected in the world (the panel's tabs stay as
-- they are - closed: only the inspector); nothing selected: an inspector-only panel goes
function PN:show_selected(ed)
  ed = ed or self.ed
  self:sync_selected()
  local i = ed.selected and self:selected_index() or nil
  if i == nil and ed.selected and ed.world_sel then
    if not self.shown then
      self.tabs_hidden = true
      self.shown = true
    end
    self:show_world_card(ed.world_sel)
    self:place()
    return
  end
  self:show_world_card(nil)
  if i == nil then
    if self.shown and self.tabs_hidden then self:hide()
    elseif self.ins.obj then self:show_inspector(false) end
    return
  end
  self:load_catalog()
  if not self.catalog then return end              -- (the database is still being built)
  if not self.shown then
    self.tabs_hidden = true
    self.shown = true
  end
  self.ins_hidden = false
  self.ins:show_object(ed.place, i)
  self:show_inspector(true)
  self:place()
end
function PN:follow() end
-- the notice over the game (panel.Notice): a failed build stays, the rest goes after ms
function PN:say(text, ms, error)
  print("[notice] " .. tostring(text))
  self.notice:say(text, error, ms)
end
-- after the bar (the notice's window is over it), also while playing
function PN:draw_notice(W, H) self.notice:frame(W, H) end
-- a text field of the panel has the keys (keyboard.py's typing: the game does not get them)
-- a field of Conjunction has the keys: the panel's, its windows', the quest board's, a dialog's (24.10.: only
-- "panel." counted - typing in the quest's name flew the camera)
function PN:typing() return CT.focus ~= nil end
function PN:stop_typing()
  if self:typing() then CT.set_focus(nil) end
  if self.renaming then self:rename_done() end
end
-- is a point of the game's picture on the panel (or its open list)?
function PN:covers(x, y)
  if require("conjunction.ui.dock").busy_any() then return true end     -- (a window dragged: the mouse stays ours)
  if self.notice:covers(x, y) then return true end
  for _, w in ipairs(self.win_order or {}) do if w:covers(x, y) then return true end end
  if IM.is_open() and IM.covers(x, y) then return true end
  if not self.shown or not self.rect or (self.full_window and self:full_window()) then return false end
  return inside(x, y, self.rect)
end

-- --- the panel's windows (item_chooser.CatalogWindow: one per purpose, over the panel, the last opened on top) ---
function PN:open_win(key, title, kind, make)
  self.windows = self.windows or {}
  self.win_order = self.win_order or {}
  local w = self.windows[key]
  if w == nil then
    w = require("conjunction.ui.window").new(self, key, title, kind)
    w.body = make(w)
    self.windows[key] = w
  end
  w.shown = true
  for i, x in ipairs(self.win_order) do if x == w then table.remove(self.win_order, i) break end end
  self.win_order[#self.win_order + 1] = w      -- (shown: raised)
  return w
end
function PN:window_closed(w)
  if self.windows and self.windows[w.key] == w then self.windows[w.key] = nil end
  for i, x in ipairs(self.win_order or {}) do if x == w then table.remove(self.win_order, i) break end end
  if CT.focus and tostring(CT.focus):sub(1, 10) == "panel.win." then CT.set_focus(nil) end   -- (typing stops)
end
-- In this quest (ui/cast_window.lua) in a window of the catalog's kind; the first time narrow, beside the panel
-- (panel.cast_window)
function PN:cast_window(board)
  local w = self.windows and self.windows.cast
  if w then return w end
  local CFG = require("conjunction.config")
  local kept = CFG.load().catalog_windows
  w = self:open_win("cast", "In this quest", "cast", function(win) return require("conjunction.ui.cast_window").new(board, win) end)
  if not (type(kept) == "table" and kept.cast) then
    local g = self.rect or {x = 12, y = 96, w = 516, h = 790}
    w.rect = {x = g.x + g.w - 1 + 8, y = g.y, w = 460, h = math.min(720, g.h)}
  end
  return w
end
-- an item window; then_(ref) when one is taken (a game item's name or "own:<id>")
function PN:choose_item(then_, title, opts)
  opts = opts or {}
  self:load_catalog()
  if not self.assets then return nil end
  title = title or "Choose an item"
  local key = opts.key or title
  local IC = require("conjunction.ui.item_chooser")
  local w = self.windows and self.windows[key]
  if w then
    w.body.then_, w.body.keep_open, w.body.ins.item_action = then_, opts.keep_open, opts.action or "Choose item"
    w.body.action = opts.action or "Choose item"
    w.body:show_current(opts.current)
  end
  return self:open_win(key, title, "items", function(win)
    return IC.items(self, win, then_, opts.keep_open, opts.action or "Choose item", opts.current)
  end)
end
-- a loot window; then_(table name) when one is taken
function PN:choose_loot(then_, title, opts)
  opts = opts or {}
  self:load_catalog()
  if not self.assets then return nil end
  title = title or "Random loot"
  local key = opts.key or title
  local IC = require("conjunction.ui.item_chooser")
  local w = self.windows and self.windows[key]
  if w then w.body.then_ = then_ end
  return self:open_win(key, title, "loot", function(win) return IC.loot(self, win, then_, opts.current) end)
end
-- the windows that pick from the game's quests and scenes (ui/game_choosers.lua): a moment of a game quest
-- (then_({quest, name, fact})), a point inside one (then_({phase, name, block, socket, label})), a scene to replace
-- (then_(swap))
local function game_chooser(self, key, title, kind, make, then_)
  local w = self.windows and self.windows[key]
  if w then w.body.then_ = then_ end
  return self:open_win(key, title, kind, function(win) return make(self, win, then_) end)
end
function PN:choose_moment(then_)
  return game_chooser(self, "game quest moment", "After a moment of a game quest", "moments",
                      require("conjunction.ui.game_choosers").moments, then_)
end
function PN:choose_point(then_)
  return game_chooser(self, "game quest point", "Inside a game quest", "points",
                      require("conjunction.ui.game_choosers").points, then_)
end
function PN:choose_scene(then_)
  return game_chooser(self, "game scene", "Replace a scene of the game", "scenes",
                      require("conjunction.ui.game_choosers").scenes, then_)
end
-- the look window (look_chooser.py: every look as a 3D tile); then_(look) when one is used. speaks: the person talks
-- in the quest (only looks whose face can move)
function PN:choose_look(template, current, then_, speaks)
  local key = "look"
  local w = self.windows and self.windows[key]
  if w then w:close() end
  local LW = require("conjunction.ui.look_window")
  return self:open_win(key, "Choose a look", "looks", function(win)
    return LW.new(self, win, template, current, then_, speaks)
  end)
end

-- the windows drawn over the panel, each blocked where one above it lies (ImGui gives the mouse to the first item)
function PN:draw_windows(base_blocker)
  local order = self.win_order or {}
  for k, w in ipairs(order) do
    CT.blocker = function(mx, my)
      if base_blocker and base_blocker(mx, my) then return true end
      for j = k + 1, #order do if order[j]:covers(mx, my) then return true end end
      return false
    end
    w:frame()
  end
  CT.blocker = base_blocker
end

-- --- the tabs (panel._tab_group: the catalog alone, or the project's tabs) ---
function PN:has_quest() return not (self.ed.project.meta and self.ed.project.meta.kind == "place") end
function PN:set_tab(i)
  if i == 2 and not self:has_quest() then i = 1 end            -- (a place mod has no Quest tab)
  self.tab = i
  if i == 3 then self:refresh_needs() end                     -- (the Build tab: what it uses, read again)
  self:show_inspector(self.inspector_wanted)                   -- (panel._tab_changed)
end
-- the tabs shown now: their 0-based indices
function PN:shown_tabs()
  if self.tab == 0 then return {} end
  local out = {}
  for i = 1, 3 do
    if i ~= 2 or self:has_quest() then out[#out + 1] = i end
  end
  return out
end

-- --- the project (the header's menu) ---
function PN:project_name()
  local p = self.ed.project
  local name = p.meta and p.meta.name
  if name == nil or name == "" or name == false then name = call(p, "id") or p.id end
  return tostring(name) .. "  \u{25be}"
end
function PN:rename_start()
  self.renaming = true
  local name = self.ed.project.meta and self.ed.project.meta.name
  self.rename_text = (name ~= nil and name ~= false) and tostring(name) or ""
  local s = CT.state("panel.rename")
  s.e = LE.new(self.rename_text)
  s.e:select_all()
  CT.set_focus("panel.rename")
end
function PN:rename_done()
  if not self.renaming then return end
  self.renaming = false
  if CT.focus == "panel.rename" then CT.set_focus(nil) end
  call(self.ed, "rename_project", self.rename_text)
  call(self.ed.hud, "sync")
end
function PN:project_menu()
  local ed = self.ed
  return {{text = "Rename", action = function() self:rename_start() end},
          {text = "New project", action = function() call(ed, "new_project") end},
          {text = "Open project...", action = function() call(ed, "open_projects") end},
          "-",
          {text = "Library...", action = function() call(ed, "open_library") end}}
end
function PN:setting(key)
  local f = self.ed.setting or (getmetatable(self.ed) and getmetatable(self.ed).setting)
  if f then return f(key) end
  for _, s in ipairs(PN.SETTINGS) do if s[1] == key then return s[3] end end
end
function PN:settings_menu()
  local items = {}
  for _, s in ipairs(PN.SETTINGS) do
    local key = s[1]
    items[#items + 1] = {text = (self:setting(key) and "\u{2713}  " or "     ") .. s[2],
                         action = function() call(self.ed, "toggle_setting", key) end}
  end
  return items
end

-- --- the places (panel.sync_places / sync_selected / show_area) ---
function PN:place_names()
  local seen, names = {}, {}
  for n in pairs(self.ed.project.places or {}) do
    if type(n) == "string" and not seen[n] then seen[n] = true names[#names + 1] = n end
  end
  if self.ed.place and not seen[self.ed.place] then names[#names + 1] = self.ed.place end
  require("conjunction.pysort").sort(names)              -- (sorted(): by code point)
  return names
end
function PN:selected_index()
  local p = self.ed.project
  if not p.find_object or self.ed.selected == nil then return nil end
  return p:find_object(self.ed.place, self.ed.selected)
end
-- the tree anew: the place being edited open, its selected object marked
function PN:sync_places()
  self.expanded = {}
  if self.ed.place then self.expanded[self.ed.place] = true end
  self.tree_sel = nil
end
function PN:sync_selected()
  self:sync_places()
  local i = self:selected_index()
  local objs = objects_of((self.ed.project.places or {})[self.ed.place])
  if i == nil or i > #objs then
    self.sel_id = nil
    return
  end
  local o = objs[i]
  self.sel_id = i
  self.sel_name = o.id and tostring(o.id) or ""
  self.sel_vals = {}
  for k = 1, 3 do self.sel_vals[k] = (o.pos or {})[k] or 0.0 end
  for k = 1, 3 do self.sel_vals[3 + k] = (o.rot or {})[k] or 0.0 end
  for k = 1, 6 do CT.state("panel.sel." .. k).sb = nil end
end
function PN:show_area(place, index)
  local objs = place and objects_of((self.ed.project.places or {})[place]) or {}
  if index == nil or index > #objs or not objs[index].envhide then
    self.area_at = nil
    return
  end
  self.area_at = {place, index}
  CT.state("panel.area.height").sb = nil
end

-- --- sizes (Qt's hints in the panel: theme.py's controls, 13 px; ingame/spec/panel.md) ---
local function button_hint(s) return Q.hint_w(s) + 22, Q.line_h() + 12 end
local function spin_hint(min_text, max_text)
  return math.max(Q.text_w(min_text .. " "), Q.text_w(max_text .. " ")) + 34, 35
end
-- a QLabel with word wrap: its lines at a width (QTextLayout: at spaces; a longer word stays whole)
local function wrap(text, width, px)
  return TT.wrap(text, math.max(0, width), px)
end
local function wrap_box(text, width, px)
  local lines = wrap(text, width, px)
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, Q.text_w(l, px)) end
  return w, math.max(1, #lines) * Q.line_h(px), lines
end
-- QLabel::sizeHint with word wrap (QLabelPrivate::sizeForWidth(-1)): 80 average letters, half, a quarter
local function wrap_hint(text, px)
  local avg = ({[11] = 5, [12] = 6, [13] = 6})[px] or 6
  local w = avg * 80
  local lh = Q.line_h(px)
  local bw, bh = wrap_box(text, w, px)
  if bh < 4 * lh and bw > w // 2 then bw, bh = wrap_box(text, w // 2, px) end
  if bh < 2 * lh and bw > w // 4 then bw, bh = wrap_box(text, w // 4, px) end
  local widest = 0
  for word in text:gmatch("%S+") do widest = math.max(widest, Q.text_w(word, px)) end
  return bw, bh, widest
end
local function wrap_label(text, px)
  local hw, hh, widest = wrap_hint(text, px)
  local it = L.widget(hw, hh, "preferred", "preferred", {min_w = widest, min_h = Q.line_h(px)})
  return it, function(w) local _, h = wrap_box(text, w, px) return h end
end
-- fields.with_unit: [before] [the number] [after], 3 px apart, as wide as they are
local function unit_widget(before, spin_w, after)
  local w = spin_w
  if before ~= "" then w = w + Q.hint_w(before, 12) + 3 end
  if after ~= "" then w = w + 3 + Q.hint_w(after, 12) end
  return L.widget(w, 35, "maximum", "fixed")
end

-- --- the layout: every rectangle of the panel for its size and state ---
function PN:layout()
  local r = self.rect
  local lay = {frame = r}
  local x, y, w, h = r.x + 1 + PN.EDGE, r.y + 1 + 2, r.w - 2 - 2 * PN.EDGE, r.h - 2 - 2 - PN.EDGE
  lay.header = {x = x, y = y, w = w, h = PN.HEADER_H}
  -- the header's row (margins 4 0 0 0, Qt's 6 between)
  local items, what = {}, {}
  local function add(it, name) items[#items + 1] = it; what[#items] = name end
  if self.tab == 0 then
    add({hint = Q.hint_w("Asset Browser", 12), min = 0, cross_max = L.BIG}, "title")
  elseif self.renaming then
    add({hint = 220, min = 220, max = 220, cross_max = CT.edit_h()}, "rename")   -- (the header's 24 px: Qt cuts it)
  else
    local pw = Q.text_w(self:project_name(), 12, true) + 17
    add({hint = pw, min = pw, max = pw, cross_max = 19}, "project")
  end
  add({hint = 0, min = 0, stretch = 1, empty = true}, "stretch")
  add({hint = 24, min = 24, max = 24, cross_max = 20}, "gear")
  add({hint = 24, min = 24, max = 24, cross_max = 20}, "max")
  add({hint = 24, min = 24, max = 24, cross_max = 20}, "close")
  local placed = L.row(items, x, y, w, PN.HEADER_H, {margins = {4, 0, 0, 0}, spacing = 6})
  for i, n in ipairs(what) do lay[n] = placed[i] end
  -- the tabs below, the inspector beside them (an HBox: 4 apart, the inspector's box 330 wide)
  local by = y + PN.HEADER_H + 4
  lay.tabs = {x = x, y = by, w = w, h = r.y + r.h - 1 - PN.EDGE - by}
  if self.inspector and self.tabs_hidden then
    -- (only the inspector: its box alone in the row, in the middle)
    lay.inspector = {x = x + (w - 330) // 2, y = by, w = 330, h = lay.tabs.h}
    lay.tabs = nil
  elseif self.inspector then
    lay.tabs.w = w - 330 - 4
    lay.inspector = {x = x + w - 330, y = by, w = 330, h = lay.tabs.h}
  end
  if not lay.tabs then lay.tab_rects, lay.page = {}, nil return lay end
  local tb = lay.tabs
  lay.tab_rects = {}
  local tx = tb.x
  for _, i in ipairs(self:shown_tabs()) do
    local tw, th = Q.tab_size(TABS[i + 1], 12)
    lay.tab_rects[#lay.tab_rects + 1] = {x = tx, y = tb.y, w = tw, h = th, tab = i}
    tx = tx + tw
  end
  local bar_h = #lay.tab_rects > 0 and lay.tab_rects[1].h or 0
  lay.page = {x = tb.x, y = tb.y + bar_h, w = tb.w, h = tb.h - bar_h}
  if self.tab == 1 then self:layout_places(lay) end
  if self.tab == 3 then self:layout_build(lay) end
  return lay
end

-- the Places tab: the tree, the new location's row, the hide area's box, the selected object's box
function PN:layout_places(lay)
  local pg = lay.page
  local ed = self.ed
  local eh = CT.edit_h()
  local col = {
    {hint = 192, min = 56, stretch = 1},
    {hint = eh, min = eh, max = eh},
  }
  local names = {"tree", "row"}
  local boxes = {}
  local objs = objects_of((ed.project.places or {})[ed.place])
  if self.area_at then
    local o = objects_of((ed.project.places or {})[self.area_at[1]])[self.area_at[2]]
    local spec = o and o.envhide or {}
    local text = string.format("Hide area %s, %d points (visible after Build & Play)", tostring(o and o.id or ""),
                               #(spec.points or {}))
    local label, hfw = wrap_label(text, 11)
    local function check_cell(row, c, s)       -- QCheckBox: its hint, 12 px (no page rule in the panel)
      local cw, ch = Q.check_size(s, 12)
      local it = L.widget(cw, ch, "preferred", "fixed")
      return {row = row, col = c, w = it.w, h = it.h}
    end
    local cells = {
      {row = 0, col = 0, cols = 3, w = label.w, h = label.h, hfw = hfw},
      check_cell(1, 0, "Foliage"), check_cell(1, 1, "Terrain"), check_cell(1, 2, "Water"),
    }
    local sw = spin_hint("1", "500")
    local u = unit_widget("height", sw, "m")
    cells[#cells + 1] = {row = 2, col = 0, cols = 2, w = u.w, h = u.h}
    local bw, bh = button_hint("Outline")
    local b = L.widget(bw, bh, "minimum", "fixed")
    cells[#cells + 1] = {row = 2, col = 2, w = b.w, h = b.h}
    local opts = {margins = {8, 6, 8, 8}, hspacing = 6, vspacing = 6}
    boxes.area = {cells = cells, opts = opts, text = text, spin_w = sw, spec = spec}
    col[#col + 1] = {hfw = function(cw2) return 2 + (L.grid_hfw(cells, cw2 - 2, opts)) end, hint = 0, min = 0}
    names[#names + 1] = "area"
  end
  if self.sel_id and objs[self.sel_id] then
    local o = objs[self.sel_id]
    local label, hfw = wrap_label(tostring(o.template or ""), 11)
    local e = L.widget(17 * Q.text_w("x") + 16, eh, "expanding", "fixed", {min_w = 42})
    local cells = {
      {row = 0, col = 0, cols = 4, w = label.w, h = label.h, hfw = hfw},
      {row = 1, col = 0, cols = 4, w = e.w, h = e.h},
    }
    local spins = {}
    for i, name in ipairs({"x", "y", "z", "roll", "pitch", "yaw"}) do
      local sw = spin_hint(i <= 3 and "-100000.00" or "-100000.0", i <= 3 and "100000.00" or "100000.0")
      local u = unit_widget(name, sw, "")
      cells[#cells + 1] = {row = 2 + (i - 1) // 3, col = (i - 1) % 3, w = u.w, h = u.h}
      spins[i] = {name = name, w = sw}
    end
    local bw, bh = button_hint("Apply")
    local b = L.widget(bw, bh, "minimum", "fixed")
    cells[#cells + 1] = {row = 2, col = 3, rows = 2, w = b.w, h = b.h}
    local opts = {margins = {8, 6, 8, 8}, hspacing = 6, vspacing = 4}
    boxes.sel = {cells = cells, opts = opts, spins = spins, template = tostring(o.template or "")}
    col[#col + 1] = {hfw = function(cw2) return 2 + (L.grid_hfw(cells, cw2 - 2, opts)) end, hint = 0, min = 0}
    names[#names + 1] = "sel"
  end
  local placed = L.column(col, pg.x, pg.y, pg.w, pg.h, {margins = {0, 6, 0, 0}, spacing = 6})
  for i, n in ipairs(names) do lay[n] = placed[i] end
  -- the row: the field (stretch 1), Add, Hide area (4 apart)
  local aw, ah = button_hint("Add")
  local hw2, hh2 = button_hint("Hide area")
  local rr = lay.row
  local row = L.row({{hint = 17 * Q.text_w("x") + 16, min = 42, stretch = 1, cross_max = eh},
                     {hint = aw, min = aw, cross_max = ah}, {hint = hw2, min = hw2, cross_max = hh2}},
                    rr.x, rr.y, rr.w, rr.h, {spacing = 4})
  lay.new_place, lay.add, lay.hide_area = row[1], row[2], row[3]
  for name, b in pairs(boxes) do
    local fr = lay[name]
    b.placed = L.grid(b.cells, fr.x + 1, fr.y + 1, fr.w - 2, fr.h - 2, b.opts)
    lay[name .. "_box"] = b
  end
end

-- --- the Build tab (panel._build_tab): the status, Build & Play, Check, the mods it uses (export_view.NeedsBox),
-- Export with Include the project, the libraries, Content pack, the build's lines ---
PN.BUILD_RED, PN.BUILD_AMBER, PN.BUILD_GREEN = "#e57a7a", "#e5b85c", "#5cb85c"
local NEED_HEAD, NEED_THINGS = hex("#bbbbbb"), hex("#8a8a8a")
-- a QLabel's lines with word wrap (QTextLayout: at spaces, the spaces kept)
local function label_lines(text, width, px, bold)
  local out = {}
  for _, l in ipairs(TL.wrap(text, px, bold, math.max(0, width), "word")) do out[#out + 1] = l.s end
  return out
end

-- what the quest takes from mods: read again (cached bundles: a fraction of a second)
function PN:refresh_needs()
  local CNT = require("conjunction.content")
  local ok, packs, missing = pcall(function()
    return CNT.manifest_packs(self.ed.project, nil, CNT.labeler(self.assets))
  end)
  if ok then self.needs = {packs = packs or {}, missing = missing or {}}
  else
    self.needs = {packs = {}, missing = {}}
    print("[export] " .. tostring(packs))
  end
end

local function need_things(p)
  local used = {}
  for _, u in ipairs(p.used or {}) do used[#used + 1] = tostring(u.name or u.ref) end
  local s = string.format("%d %s: ", #used, #used == 1 and "thing" or "things") ..
            table.concat({table.unpack(used, 1, math.min(8, #used))}, ", ") .. (#used > 8 and " ..." or "")
  if p.folder then s = s .. "  (" .. p.folder .. ")" end
  return s
end
local function need_missing(missing)
  return "Not found in the game: " .. table.concat({table.unpack(missing, 1, math.min(6, #missing))}, ", ") ..
         (#missing > 6 and string.format(" and %d more", #missing - 6) or "")
end

function PN:layout_build(lay)
  local pg = lay.page
  local w = pg.w
  local needs = self.needs or {packs = {}, missing = {}}
  local col, names = {}, {}
  local function add(it, name) col[#col + 1] = it names[#col] = name end
  local _, bh = button_hint("Check")
  if self.build_status then
    local text = self.build_status[1]
    local indent = Q.text_w("x", 13, true) // 2
    add({hfw = function(cw) return #label_lines(text, cw - 2 * indent, 13, true) * Q.line_h(13) + 8 end, hint = 0, min = 0},
        "status")
  end
  add({hint = bh, min = bh, max = bh}, "play")
  add({hint = bh, min = bh, max = bh}, "check")
  -- the needs box: margins 0 4 0 4, 3 apart; a pack's row and its things 1 apart
  local nb = {rows = {}}
  local y = 4
  nb.head = {y = y, h = Q.line_h(12)}
  y = y + nb.head.h
  for _, p in ipairs(needs.packs) do
    local rh = p.folder and CT.edit_h() or Q.line_h(13)
    local things = need_things(p)
    local th = #label_lines(things, w, 11) * Q.line_h(11)
    y = y + 3
    nb.rows[#nb.rows + 1] = {pack = p, y = y, h = rh, things = things, ty = y + rh + 1, th = th}
    y = y + rh + 1 + th
  end
  if #needs.missing > 0 then
    local text = need_missing(needs.missing)
    local mh = #label_lines(text, w, 13) * Q.line_h(13)
    y = y + 3
    nb.missing = {y = y, h = mh, text = text}
    y = y + mh
  end
  nb.h = y + 4
  add({hint = nb.h, min = nb.h, max = nb.h}, "needs")
  add({hint = bh, min = bh, max = bh}, "export")
  add({hint = bh, min = bh, max = bh}, "meshes")
  add({hint = bh, min = bh, max = bh}, "foliage")
  add({hint = bh, min = bh, max = bh}, "pack")
  add({hint = 192, min = 0, stretch = 1}, "log")
  local placed = L.column(col, pg.x, pg.y, pg.w, pg.h, {margins = {0, 6, 0, 0}, spacing = 6})
  local b = {needs_box = nb}
  for i, n in ipairs(names) do b[n] = placed[i] end
  -- Export (stretch 1) and Include the project (6 apart)
  local cw, ch = Q.check_size("Include the project", 12)
  local er = b.export
  local row = L.row({{hint = select(1, button_hint("Export quest file")), min = 0, stretch = 1, cross_max = bh},
                     {hint = cw, min = cw, max = cw, cross_max = ch}}, er.x, er.y, er.w, er.h, {spacing = 6})
  b.export_b, b.source = row[1], row[2]
  lay.build = b
end

-- export_view.NeedsBox: the head, each pack (a card's: its name, version, author; a plain mod's: name, version and
-- link fields, remembered when left), its things, what was found nowhere
function PN:draw_needs(r, nb)
  local needs = self.needs or {packs = {}, missing = {}}
  local x, w = r.x, r.w
  local head = (#needs.packs > 0 or #needs.missing > 0) and "Mods it uses" or "Uses only the game"
  Q.text(x, r.y + nb.head.y, NEED_HEAD, head, 12, true, C.bg)
  for k, row in ipairs(nb.rows) do
    local p = row.pack
    local y = r.y + row.y
    local plain = p.folder ~= nil
    local short = plain and p.folder:match("^[^/]*/(.*)$") or nil
    local ok = not plain or (p.name ~= short and p.url ~= nil and p.url ~= "")
    Q.draw_icon(plain and "package" or "package-check", hex(ok and PN.BUILD_GREEN or PN.BUILD_AMBER), 14, x,
                y + (row.h - 14) // 2)
    local fx = x + 14 + 1
    if plain then
      local fw = w - 14 - 60 - 3
      local nw = (fw * 2) // 5
      local uw = fw - nw
      local fields = {{"name", fx, nw, "", "exp.mod_name"}, {"version", fx + nw + 1, 60, "version", "exp.mod_version"},
                      {"url", fx + nw + 1 + 60 + 1, uw, "Link (Nexus)", "exp.mod_url"}}
      local st = self.need_edits or {}
      self.need_edits = st
      for _, f in ipairs(fields) do
        local id = "panel.need." .. k .. "." .. f[1]
        local key = p.folder .. "|" .. f[1]
        if st[key] == nil then st[key] = tostring(p[f[1]] or "") end
        local _, text = CT.edit(id, f[2], y, f[3], st[key], {placeholder = f[4] ~= "" and f[4] or nil,
                                                            style = PN.EDIT_STYLE, tip = f[5]})
        st[key] = text
        local was = st[key .. "|focus"]
        st[key .. "|focus"] = CT.focus == id
        if was and CT.focus ~= id then                -- (editingFinished: remembered on this machine)
          local CNT = require("conjunction.content")
          local nm, ver, url = st[p.folder .. "|name"], st[p.folder .. "|version"], st[p.folder .. "|url"]
          CNT.remember_mod(p.folder, nm, ver, url)
          local PYS = require("conjunction.pystr")
          p.name = PYS.strip(nm) ~= "" and PYS.strip(nm) or short
          p.version, p.url = PYS.strip(ver), PYS.strip(url)
        end
      end
    else
      local t = tostring(p.name) .. " " .. tostring(p.version or "") ..
                ((p.author and p.author ~= "") and (" by " .. p.author) or "")
      Q.text(fx, y, C.label, t, 13, false, C.bg)
    end
    for i, line in ipairs(label_lines(row.things, w, 11)) do
      Q.text(x, r.y + row.ty + (i - 1) * Q.line_h(11), NEED_THINGS, line, 11, false, C.bg)
    end
  end
  if nb.missing then
    for i, line in ipairs(label_lines(nb.missing.text, w, 13)) do
      Q.text(x, r.y + nb.missing.y + (i - 1) * Q.line_h(13), hex(PN.BUILD_RED), line, 13, false, C.bg)
    end
  end
end

function PN:draw_build(lay)
  local b = lay.build
  if not b then return end
  local ed = self.ed
  if self.build_status then
    local r = b.status
    local colour = hex(self.build_status[2])
    -- (a style sheet's padding gives the label a frame: QLabel's indent is then half an x, on either side)
    local indent = Q.text_w("x", 13, true) // 2
    for i, line in ipairs(label_lines(self.build_status[1], r.w - 2 * indent, 13, true)) do
      Q.text(r.x + indent, r.y + 4 + (i - 1) * Q.line_h(13), colour, line, 13, true, C.bg)
    end
  end
  local busy = self.building
  local function button(id, r, text, tip_key, on)
    return CT.button("panel." .. id, r.x, r.y, text, {w = r.w, h = r.h, fg = C.button, tip = tip_key,
                                                      disabled = on == false})
  end
  if button("play", b.play, "Build & Play", "pan.play", not busy) then self:build(true) end
  if button("check", b.check, "Check", "pan.check", not busy) then self:build(false) end
  self:draw_needs(b.needs, b.needs_box)
  -- Export and Include the project
  if button("export", b.export_b, self:has_quest() and "Export quest file" or "Export place mod", "pan.export",
            not self.exporting) then
    self:export()
  end
  local s = b.source
  local toggled, v = CT.check("panel.export_source", s.x, s.y, "Include the project", self.include_source == true,
                              {bg = C.bg, fg = C.check, h = s.h, px = 12, tip = "pan.export_source"})
  if toggled then self.include_source = v end
  local libs = self.libraries or {}
  if button("meshes", b.meshes, "Build mesh library", "pan.meshes", libs.meshes ~= false) then self:library("meshes") end
  if button("foliage", b.foliage, "Build foliage library", "pan.foliage", libs.foliage ~= false) then
    self:library("foliage")
  end
  if button("pack", b.pack, "Content pack", "lib.packs") then call(ed, "pack_maker") end
  local r = b.log
  PT.edit("panel.build_log", r.x, r.y, r.w, r.h, table.concat(self.build_log or {}, "\n"), {readonly = true})
end

-- panel._status: a line over the buttons, in a colour
function PN:build_say(text, colour) self.build_status = {text, colour} end

-- what of the build's lines the panel shows (MaximdeWinter 14.11.: "weniger ist mehr, niemand liest das aktiv mit" - a Build
-- & Play wrote 106 lines): its steps in a few words, what Check found and what went wrong. Every line stays in
-- build\last_play.log. -> the line to show or nil
PN.LOG_STEPS = {{"^%[play%] Build & Play", "Build & Play"}, {"^%[play%] check", "Check"},
                {": encode quest$", "Building the quest..."}, {": analyze, cook$", "Cooking..."},
                {": scene ", "Scenes..."}, {"^%[speech%] lip sync$", "Voice lines..."},
                {": pack, metadatastore$", "Packing..."}, {"^%[build%] installed", "Installed"},
                {"^%[play%] the game restarts", "Restarting the game..."},
                {"^%[play%] Live: starting the session", "Starting the session..."},
                {"^%[play%] Session started", "Session started. F8 to edit"},
                {"^%[done%]", "Done"}}
PN.LOG_TROUBLE = {"error", "fail", "could not", "cannot", "can't", "not found", "missing", "left out", "stuck",
                  "unreadable", "no ffmpeg", "warning", "not built", "not in this version"}
function PN.log_line(line)
  for _, s in ipairs(PN.LOG_STEPS) do if line:find(s[1]) then return s[2] end end
  local low = line:lower()
  if low:find("debug information", 1, true) then return nil end
  local text = (line:gsub("^%s+", ""):gsub("^%[[%w ]+%]%s*", ""))
  if line:sub(1, 7) == "[check]" or line:sub(1, 8) == "[failed]" then return text end
  for _, w in ipairs(PN.LOG_TROUBLE) do if low:find(w, 1, true) then return text end end
  return nil
end

-- panel._log: a line of the build - the status after it ended, the notice over the game, the log
function PN:build_line(line)
  local name = (self.ed.project.meta or {}).name or "The quest"
  if line == "\0" then
    self.building = false
    if self.ed.editing == false and self.shown then self:hide() end   -- (playing after Build & Play)
    return
  end
  -- the outcome in two words (MaximdeWinter 23.10.: what went wrong, and how far the stand-in player came, is in the log)
  local done = self.doing or "Built"
  if line:sub(1, 8) == "[failed]" then
    local reason = (line:sub(10):gsub("^%s+", ""):gsub("%s+$", ""))
    self:build_say(done .. ": Fail", PN.BUILD_RED)
    if done == "Built" then self:say(name .. " was not built: " .. reason, nil, true) end
  elseif line:sub(1, 16) == "[check] played: " or line:sub(1, 15) == "[check] stuck: " then
    self.played = {line:sub(1, 14) == "[check] played", line:match(": (.*)$")}
  elseif line:sub(1, 6) == "[done]" then
    local played = self.played
    self.played = nil
    if played and line:find("no errors", 1, true) and not played[1] then   -- radish is happy, but a way stops (in the log)
      self:build_say("Checked: Fail", PN.BUILD_RED)
      return
    end
    local meta = self.ed.project.meta or {}
    local swaps = 0
    for _ in pairs(type(meta.swaps) == "table" and meta.swaps or {}) do swaps = swaps + 1 end
    local inside = type(meta.quest) == "table" and type(meta.quest.inside_game) == "table" and meta.quest.inside_game.phase
    local changed = swaps + ((inside ~= nil and inside ~= false and inside ~= "") and 1 or 0)
    if changed > 0 then                       -- the game's own files: a mod of their own, and a word about saves
      self.build_log = self.build_log or {}
      self.build_log[#self.build_log + 1] = string.format("It changes %d of the game's files. Saves made inside those " ..
                                                          "quests may not fit", changed)
    end
    self:build_say(done .. ": Success", "#9fd38a")
    if done == "Built" then
      self:say("Built: Success")
      require("conjunction.changes").built(self.ed.project.path, false)
    end
  end
  self.build_log = self.build_log or {}
  local log = self.build_log
  local shown = PN.log_line(line)
  if shown and shown ~= log[#log] then log[#log + 1] = shown end
  CT.state("panel.build_log").top = math.huge  -- (appendPlainText: the end in view)
end

-- panel._built_already: nothing changed since the last Build & Play, and that build is in the game
function PN:built_already()
  return call(self.ed, "dlc_installed") and require("conjunction.changes").unchanged_since_build(self.ed.project.path)
end
-- the build's start (panel._build): one at a time; Build & Play or Check, its lines into the tab
function PN:build(play, again)
  if self.building then
    self:build_say("A build is running - wait for it", "#e3c65f")
    return
  end
  if play and not again and self:built_already() then
    require("conjunction.ui.dialogs").question(self.ed, "Build & Play",
                                               "Nothing changed since the last build. Build again?", function(a)
      if a == "yes" then self:build(true, true) end
    end)
    return
  end
  self.build_log = {}
  self.doing = play and "Built" or "Checked"     -- (the status after it: "Checked: Success")
  self:build_say(play and "Building ..." or "Checking ...", "#c8c8c8")
  call(self.ed, "build_and_play", play, function(line) self:build_line(line) end)
end

-- the export (panel._export): what the page and the journal will say, asked first (export_window)
function PN:export()
  self.doing = "Exported"
  self:refresh_needs()
  call(self.ed, "export", self.include_source == true, self.needs, function(line) self:build_line(line) end)
end

-- the asset database (panel._build_assets): once; its lines into the hint, the others into the build's log
function PN:build_assets()
  if self.assets_building or not self.ed then return end
  self.assets_building = true
  local function line(s)
    if s:sub(1, 8) == "[assets]" then
      self.catalog_hint = "Building the catalog... " .. (s:sub(10):gsub(" %-> .- %(", " ("))
      if require("conjunction.pystr").lower(s) == "[assets] ready" then
        self.assets_building = false
        self:load_catalog()
      end
      return
    end
    self.build_log = self.build_log or {}
    self.build_log[#self.build_log + 1] = s
  end
  self.ed:job(function()
    require("conjunction.assets_build").build(line)
    line("[assets] Ready")
  end, function(ok, err)
    if not ok then
      self.assets_building = false
      line("[assets] " .. tostring(err))
    end
  end)
end

-- the mesh or foliage library (panel._meshlib, _foliagelib)
function PN:library(kind)
  self.build_log = {}
  self.doing = kind == "meshes" and "Mesh library" or "Foliage library"
  self.libraries = self.libraries or {}
  self.libraries[kind] = false
  call(self.ed, "build_library", kind, function(line) self:build_line(line) end)
end

-- --- drawing and the mouse ---
-- a hit box for this frame (nothing under an open list or the bar's menu): -> clicked, hovered, held
function PN:hit(id, r)
  local mx, my = w3.ui.mouse()
  if self.blocked or (CT.blocker and CT.blocker(mx, my)) then return false, false, false end   -- (before the item:
  -- ImGui gives the mouse to the first item under it)
  w3.ui.set_pos(r.x, r.y)
  local clicked, hovered, held = w3.ui.hit("panel." .. id, r.w, r.h)
  if IM.covers(mx, my) then return false, false, false end
  return clicked == 1, hovered, held
end
local function tip(id, key)
  if TIPS[key] then TT.hover("panel." .. id, "", TIPS[key]) end
end

-- the frame (Qt paints a style sheet's border side by side; the edge here is opaque)
function PN:draw_frame(lay)
  local r = lay.frame
  D.fill(r.x, r.y, r.w, r.h, C.bg)
  D.rect(r.x, r.y, r.w, r.h, C.edge, 1)
end

-- the project's menu or the gear's, open under its button (inline_menu.show), or closed
function PN:toggle_menu(which)
  local id = "panel." .. which
  if IM.is_open(id) then
    IM.close()
  else
    local items = which == "project" and self:project_menu() or self:settings_menu()
    IM.open(id, self.lay[which], items, self.lay.frame, {bg = C.inline_bg})
  end
end

function PN:draw_header(lay)
  if lay.title then
    local t = lay.title
    Q.text(t.x, t.y + Q.vcenter(t.h, Q.line_h(12)), C.title, "Asset Browser", 12, false, C.bg)
  end
  if lay.project then
    local b = lay.project
    local clicked, hovered = self:hit("project", b)
    local s = self:project_name()
    local tw = Q.text_w(s, 12, true)
    Q.text(b.x + 4 + (b.w - 8 - tw) // 2, b.y + Q.vcenter(b.h, Q.line_h(12, true)), hovered and T.WHITE or C.project, s,
           12, true, C.bg)
    if hovered then tip("project", "pan.project") end
    if clicked then self:toggle_menu("project") end
  end
  if lay.rename then
    local b = lay.rename
    local _, text, enter = CT.edit("panel.rename", b.x, b.y, b.w, self.rename_text, {h = b.h, style = PN.EDIT_STYLE, tip = "pan.project_name"})
    self.rename_text = text
    local mx, my = w3.ui.mouse()
    local beside = (w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(2)) and not inside(mx, my, b)
    if enter or beside or CT.focus ~= "panel.rename" then self:rename_done() end
  end
  do  -- the gear: a tool button with no frame of its own
    local b = lay.gear
    local clicked, hovered = self:hit("gear", b)
    Q.draw_icon("settings", C.project, 16, b.x + (b.w - 16) // 2, b.y + (b.h - 16) // 2)
    if hovered then tip("gear", "pan.settings") end
    if clicked then self:toggle_menu("gear") end
  end
  if lay.max then  -- maximize / back (dock.lua): a tool button with no frame of its own, as the gear
    local b = lay.max
    local clicked, hovered = self:hit("max", b)
    local on = self.mover:maximized()
    if hovered then D.fill(b.x, b.y, b.w, b.h, 0xffffff14) end
    Q.draw_icon(on and "copy" or "square", C.project, 14, b.x + (b.w - 14) // 2, b.y + (b.h - 14) // 2)
    if hovered then CT.tip("panel.max", {"", on and "Back to its size" or "Fills the screen"}) end
    if clicked then self.mover:toggle_max() end
  end
  do  -- the X: theme.py's push button
    local b = lay.close
    local clicked, hovered, held = self:hit("close", b)
    local bg, edge = T.BUTTON, (hovered or held) and T.EDGE_HOVER or T.EDGE
    if held and hovered then bg = T.CHOSEN end
    Q.frame(b.x, b.y, b.w, b.h, bg, edge)
    Q.draw_icon("x", C.project, 14, b.x + 11 + (b.w - 22 - 16) // 2 + 1, b.y + 6 + (b.h - 12 - 16) // 2 + 1)
    if hovered then tip("close", "pan.close") end
    if clicked then self:close_by_x() end
  end
end

function PN:draw_tabs(lay)
  for _, t in ipairs(lay.tab_rects) do
    local clicked, hovered = self:hit("tab." .. t.tab, t)
    Q.tab(t.x, t.y, t.w, t.h, TABS[t.tab + 1], {chosen = t.tab == self.tab, px = 12})
    if clicked then self:set_tab(t.tab) end
  end
end

-- the tree's rows: {place, index (nil: the place), depth, texts, bold, colours}
function PN:tree_rows()
  local rows = {}
  local ed = self.ed
  local sel = self:selected_index()
  for _, n in ipairs(self:place_names()) do
    local p = (ed.project.places or {})[n] or {}
    local objs = objects_of(p)
    local world = p.world
    if world == nil or world == false or world == "" then world = "-" end
    rows[#rows + 1] = {place = n, depth = 0, text = n, text2 = tostring(world) .. "  \u{b7}  " .. #objs, bold = true,
                       fg = n == ed.place and T.WHITE or C.tree_text, parent = #objs > 0, open = self.expanded[n]}
    if self.expanded[n] then
      for k, o in ipairs(objs) do
        local label
        if o.marker then label = o.id or "spot" else label = o.display or o.id or "-" end
        local base = tostring(o.template or ""):gsub("^.*[\\/]", ""):gsub("%.[^.]*$", "")
        rows[#rows + 1] = {place = n, index = k, depth = 1, text = tostring(label), text2 = base, fg = C.tree_text,
                           chosen = n == ed.place and k == sel}
      end
    end
  end
  return rows
end

function PN:draw_tree(lay)
  local r = lay.tree
  D.fill(r.x, r.y, r.w, r.h, C.tree_bg)
  D.rect(r.x, r.y, r.w, r.h, C.tree_edge, 1)
  local vx, vy, vw, vh = r.x + 1, r.y + 1, r.w - 2, r.h - 2
  local rows = self:tree_rows()
  -- column 0 as wide as its widest row (resizeColumnToContents), column 1 the rest
  local c0 = 0
  for _, row in ipairs(rows) do
    c0 = math.max(c0, TREE_INDENT * (row.depth + 1) + Q.text_w(row.text, 13, row.bold) + 10)
  end
  local total = #rows * TREE_ROW
  local max_scroll = math.max(0, total - vh)
  self.tree_scroll = math.max(0, math.min(self.tree_scroll, max_scroll))
  local mx, my = w3.ui.mouse()
  local over = inside(mx, my, {x = vx, y = vy, w = vw, h = vh}) and not self.blocked and not IM.covers(mx, my)
  local _, _, wheel = w3.ui.mouse()
  if over and wheel ~= 0 then
    self.tree_scroll = math.max(0, math.min(max_scroll, self.tree_scroll - math.floor(wheel * 3 + 0.5) * TREE_ROW))
  end
  D.clip(vx, vy, vw, vh, function()
    for i, row in ipairs(rows) do
      local ry = vy + (i - 1) * TREE_ROW - self.tree_scroll
      if ry + TREE_ROW > vy and ry < vy + vh then
        local box = {x = vx, y = ry, w = vw, h = TREE_ROW}
        local hot = over and inside(mx, my, box)
        local chosen = row.chosen or (self.tree_sel and self.tree_sel[1] == row.place and self.tree_sel[2] == row.index)
        local bg = chosen and T.CHOSEN or (hot and T.HOVER or C.tree_bg)
        if bg ~= C.tree_bg then D.fill(vx, ry, vw, TREE_ROW, bg) end
        local ix = vx + TREE_INDENT * (row.depth + 1)
        local ty = ry + 3 + (TREE_ROW - 6 - Q.line_h(13) + 1) // 2
        Q.text(ix + 5, ty, chosen and T.WHITE or row.fg, row.text, 13, row.bold, bg)
        Q.text(vx + c0 + 5, ty, chosen and T.WHITE or C.tree_dim, row.text2, 13, false, bg)
        if row.parent then
          local name = "panel_branch_" .. (row.open and "open" or "closed")
          Q.draw_part(name .. (chosen and "_chosen" or (hot and "_hover" or "")), ix - TREE_INDENT, ry)
        end
        if hot then self:tree_mouse(row, ix) end
      end
    end
  end)
  Q.scrollbar_v(vx + vw - 10, vy, vh, self.tree_scroll, vh, total)
  if over then tip("tree", "pan.places") end
end

-- a click on a row (panel._places_clicked: on the release), a double click (_places_jump), the arrow (open / close)
function PN:tree_mouse(row, ix)
  local mx = w3.ui.mouse()
  local ed = self.ed
  if w3.ui.mouse_clicked(1) then
    if row.parent and mx < ix and mx >= ix - TREE_INDENT then
      self.expanded[row.place] = not self.expanded[row.place]
      self.press_row = nil
      return
    end
    self.press_row = {row.place, row.index}
    if w3.ui.mouse_double(1) then
      if row.index == nil then self.expanded[row.place] = not self.expanded[row.place]
      else call(ed, "jump_to", row.place, row.index) end
    end
  end
  if w3.ui.mouse_released(1) and self.press_row and self.press_row[1] == row.place and self.press_row[2] == row.index then
    self.press_row = nil
    self.tree_sel = {row.place, row.index}
    self:places_clicked(row.place, row.index)
  end
end
function PN:places_clicked(place, index)
  local ed = self.ed
  if place ~= ed.place then call(ed, "set_place", place) end
  if index ~= nil then
    local o = objects_of((ed.project.places or {})[place])[index]
    if o and o.envhide then
      self:show_area(place, index)
      call(ed, "hide_area", index)
      return
    end
    self:show_area(nil, nil)
    call(ed, "set_mode", "select")
    if o then call(ed, "select_at", o.pos) end
  end
end

function PN:draw_row(lay)
  local ed = self.ed
  local r = lay.new_place
  local _, text, enter = CT.edit("panel.new_place", r.x, r.y, r.w, self.new_place,
                                 {placeholder = "New location", style = PN.EDIT_STYLE, tip = "pan.new_place"})
  self.new_place = text
  if enter then self:add_place() end
  local b = lay.add
  if CT.button("panel.add", b.x, b.y, "Add", {w = b.w, h = b.h, fg = C.button, tip = "pan.add_place"}) then
    self:add_place()
  end
  b = lay.hide_area
  if CT.button("panel.hide_area", b.x, b.y, "Hide area", {w = b.w, h = b.h, fg = C.button, tip = "pan.hide_area"}) then
    call(ed, "hide_area", nil)
    call(ed, "focus_game")
  end
end
function PN:add_place()
  local P = require("conjunction.project")
  local name = P.ascii_id(self.new_place)
  if name and name ~= "" then
    self.new_place = ""
    CT.state("panel.new_place").e = nil
    call(self.ed, "set_place", name)
    call(self.ed, "focus_game")
  end
end

local function box_frame(fr)
  D.fill(fr.x, fr.y, fr.w, fr.h, C.box_bg)
  D.rect(fr.x, fr.y, fr.w, fr.h, C.box_edge, 1)
end
-- a with_unit row: its labels (12 px #9a9a9a) and the number field
local function unit_row(id, cell, before, spin_w, after, value, opts)
  local x = cell.x
  if before ~= "" then
    Q.text(x, cell.y + Q.vcenter(cell.h, Q.line_h(12)), C.dim, before, 12, false, C.box_bg)
    x = x + Q.hint_w(before, 12) + 3
  end
  opts.w, opts.fg = spin_w, T.BRIGHT
  local changed, v = CT.spin(id, x, cell.y, value, opts)
  x = x + spin_w + 3
  if after ~= "" then Q.text(x, cell.y + Q.vcenter(cell.h, Q.line_h(12)), C.dim, after, 12, false, C.box_bg) end
  return changed, v
end

function PN:draw_area(lay)
  local b = lay.area_box
  if not b then return end
  box_frame(lay.area)
  local p = b.placed
  local ed = self.ed
  local l = p[1]
  for i, line in ipairs(wrap(b.text, l.w, 11)) do
    Q.text(l.x, l.y + (i - 1) * Q.line_h(11), C.dim, line, 11, false, C.box_bg)
  end
  local spec = b.spec
  for k, f in ipairs({{"foliage", "Foliage"}, {"terrain", "Terrain"}, {"water", "Water"}}) do
    local key = f[1]
    local on = spec[key]
    if on == nil then on = key == "foliage" end
    local c = p[1 + k]
    local toggled, v = CT.check("panel.area." .. key, c.x, c.y, f[2], truthy(on),
                                {bg = C.box_bg, fg = C.check, h = c.h, px = 12, tip = "area." .. key})
    if toggled then call(ed, "set_area", self.area_at[1], self.area_at[2], {[key] = v}) end
  end
  local u = p[5]
  local changed, v = unit_row("panel.area.height", u, "height", b.spin_w, "m", spec.height or 20.0,
                              {min = 1, max = 500, decimals = 0, buttons = false, dec = ".", tip = "area.height"})
  if changed then call(ed, "set_area", self.area_at[1], self.area_at[2], {height = v + 0.0}) end
  local o = p[6]
  if CT.button("panel.area.outline", o.x, o.y, "Outline", {w = o.w, h = o.h, fg = C.button, tip = "area.outline"}) then
    call(ed, "hide_area", self.area_at[2])
    call(ed, "focus_game")
  end
end

function PN:draw_sel(lay)
  local b = lay.sel_box
  if not b then return end
  box_frame(lay.sel)
  local p = b.placed
  local l = p[1]
  for i, line in ipairs(wrap(b.template, l.w, 11)) do
    Q.text(l.x, l.y + (i - 1) * Q.line_h(11), C.dim, line, 11, false, C.box_bg)
  end
  local e = p[2]
  local _, text = CT.edit("panel.sel_id", e.x, e.y, e.w, self.sel_name or "", {placeholder = "name", style = PN.EDIT_STYLE, tip = "obj.name"})
  if text ~= self.sel_name then self.sel_name = text end
  local focus_left = self.sel_focus and CT.focus ~= "panel.sel_id"
  self.sel_focus = CT.focus == "panel.sel_id"
  if focus_left then self:rename_object() end
  for i, s in ipairs(b.spins) do
    local _, v = unit_row("panel.sel." .. i, p[2 + i], s.name, s.w, "", self.sel_vals[i],
                          {min = -100000, max = 100000, decimals = i <= 3 and 2 or 1, step = i <= 3 and 0.1 or 5.0,
                           buttons = false, dec = "."})
    self.sel_vals[i] = v
  end
  local a = p[9]
  if CT.button("panel.apply", a.x, a.y, "Apply", {w = a.w, h = a.h, fg = C.button, tip = "pan.apply"}) then
    local v = self.sel_vals
    call(self.ed, "set_selected_transform", {v[1], v[2], v[3]}, {v[4], v[5], v[6]})
  end
end
-- the name field left (editingFinished): the object gets the name as an id
function PN:rename_object()
  local P = require("conjunction.project")
  local i = self:selected_index()
  local name = P.ascii_id(self.sel_name or "")
  if i ~= nil and name and name ~= "" then
    self.ed.project:name_object(self.ed.place, i, name)
    self:sync_selected()
  end
end

-- the page of the tab shown
function PN:draw_page(lay)
  if self.tab == 0 then
    local pg = lay.page
    if self.catalog then
      self.catalog:frame(pg)
      return
    end
    local s = self.catalog_hint or "Building the catalog..."
    local lh = Q.line_h()
    Q.text(pg.x, pg.y + Q.vcenter(pg.h, lh), C.label, s, 13, false, C.bg)
  elseif self.tab == 1 and lay.tree then        -- (the tab changed after the layout was made: 14.11. it failed there)
    self:draw_tree(lay)
    self:draw_row(lay)
    self:draw_area(lay)
    self:draw_sel(lay)
  elseif self.tab == 2 then
    self:board_of():frame(lay.page)
  elseif self.tab == 3 then
    self:draw_build(lay)
  end
end

function PN:close_panel()
  self:hide()
  call(self.ed.hud, "sync")
end
-- the X: the panel goes; in place mode the Asset Browser was what it showed - back to the mode before it (MaximdeWinter
-- 24.10.: closed, the bar still had the Asset Browser chosen; not select always: where one was, look too). Only the X:
-- taking a template closes the panel too and stays placing
function PN:close_by_x()
  self:close_panel()
  local ed = self.ed
  if ed and ed.mode == "place" and type(ed.set_mode) == "function" then
    ed:set_mode(ed.mode_before_place or "select", false)
  end
end

-- --- where: placed over the game (panel.place_at; a kept rectangle, docking: step 2d) ---
function PN:visible() return self.shown end
-- px the inspector adds beside the list (0 while it is hidden): the window grows by it, the list stays
function PN:inspector_extra() return (self.inspector and not self.tabs_hidden) and PN.INSPECTOR_EXTRA or 0 end
function PN:rect_key() return "panel_rect_" .. tostring(self.ed.catalog_screen or "game") end
-- kept without the inspector: shown or not, the list has the width the user gave it
function PN:keep_rect(r)
  local Y = require("conjunction.yaml")
  local cfg = CFG.load()
  cfg[self:rect_key()] = Y.list({r.x, r.y, r.w - self:inspector_extra(), r.h})
  CFG.save(cfg)
end
-- panel.place_at: docked at its side; else where the user put it last (the inspector beside the list); else compact
-- at the game's left edge under the bar and its context line
function PN:place()
  local W, H = self.W or 1600, self.H or 900
  if self.docker and self.docker.side and self.ed.catalog_screen ~= "second" and self.docker:apply() then return end
  if not self.tabs_hidden then
    local kept = CFG.load()[self:rect_key()]
    if type(kept) == "table" and #kept == 4 then
      local kx, ky, kw, kh = kept[1], kept[2], kept[3], kept[4]
      if kx < W and ky < H and kx + kw > 0 and ky + kh > 0 then         -- (on the game's screen)
        self.rect = {x = kx, y = ky, w = math.max(PN.MIN_W, kw) + self:inspector_extra(), h = math.max(PN.MIN_H, kh)}
        return
      end
    end
  end
  local tabs_w = math.min(620, math.max(500, math.floor(W * 0.30)))
  local insp_w = self.inspector and PN.INSPECTOR_EXTRA or 0
  if self.tabs_hidden then tabs_w = 0 end
  self.rect = {x = 12, y = 96, w = math.max(200, tabs_w + insp_w + 16), h = math.max(300, H - 110)}
end

-- one frame: lays out, draws, takes the mouse; blocked: the bar's menu lies over the panel
function PN:frame(W, H, blocked)
  self.W, self.H = W, H
  require("conjunction.look_chooser").tick(self.shown)   -- (LookPainter: the looks' tiles drawn in the background)
  local DK = require("conjunction.ui.dock")
  DK.W, DK.H = W, H
  self.ed.insets = DK.insets()                  -- (the bar's strip and hints keep clear of docked windows)
  local outer = CT.blocker
  local notice = self.notice
  local base = function(mx, my)                 -- (the notice lies over everything)
    return (outer and outer(mx, my)) or notice:covers(mx, my)
  end
  -- (a window that takes the whole screen, the cutscene editor: only the windows, the panel would lie in its picture)
  if not self.shown or (self.full_window and self:full_window()) then
    CT.text_press = false
    self:draw_windows(base)
    IM.frame()
    CT.blocker = outer
    local mx, my = w3.ui.mouse()
    self:typing_follows(mx, my)
    return self:covers(mx, my)
  end
  -- (the panel lies under its windows: where one is, the panel takes no mouse)
  CT.blocker = function(mx, my)
    if base and base(mx, my) then return true end
    for _, w in ipairs(self.win_order or {}) do if w:covers(mx, my) then return true end end
    return false
  end
  CT.text_press = false
  if not self.rect then self:place() end
  self.mover:follow()
  self.blocked = blocked
  local was = Q.translucent
  Q.translucent = true                   -- panel.py's window is translucent (Q.text decides per pixel)
  -- (the outer blocker back even when a part fails: left in place, the panel's blocked every window from then on,
  -- 14.11.)
  local ok, err = pcall(function()
    local lay = self:layout()
    self.lay = lay
    self:draw_frame(lay)
    self:draw_header(lay)
    self:draw_tabs(lay)
    if lay.page then self:draw_page(lay) end
    if lay.inspector then
      if self.wc_shown then self.wc:frame(lay.inspector)
      elseif not self.ins_hidden then self.ins:frame(lay.inspector) end
    end
    -- (the list keeps its least width beside the inspector, as Qt's minimum size keeps the app's: 23.10. the list was
    -- kept 200 px wide - the Quest tab, which has no inspector, a narrow strip)
    self.mover.min_w = PN.MIN_W + self:inspector_extra()
    local buttons = {}
    for _, k in ipairs({"project", "rename", "gear", "max", "close"}) do if lay[k] then buttons[#buttons + 1] = lay[k] end end
    self.mover:frame(lay.header, buttons)         -- (after the header's buttons: they take the mouse first)
  end)
  -- (the windows drawn even when the panel failed: they are on their own)
  local ok2, err2 = pcall(function() self:draw_windows(base) end)
  IM.frame()
  Q.translucent = was
  CT.blocker = outer
  if not ok then error(err, 0) end
  if not ok2 then error(err2, 0) end
  local mx, my = w3.ui.mouse()
  self:typing_follows(mx, my)
  return self:covers(mx, my)
end
-- the typing as keyboard.py's KeyRouter ends it: Escape; a press in the panel on anything but a text field ends it at
-- the release (what the field does when it is left may change the panel - the button pressed must still be there)
function PN:typing_follows(mx, my)
  if self:typing() and w3.ui.pressed("Escape") then
    self.esc_ate = os.clock()                     -- (this Esc ends the typing only: editor.escape, this frame)
    self:stop_typing()
    return
  end
  local pressed = w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(2) or w3.ui.mouse_clicked(3)
  if pressed and self:covers(mx, my) and not CT.text_press then self.untype = true end
  if self.untype and (w3.ui.mouse_released(1) or w3.ui.mouse_released(2) or w3.ui.mouse_released(3)) then
    self.untype = nil
    if not CT.text_press then self:stop_typing() end
  end
end

-- a catalog entry taken (double click, Enter; panel.pick): a template follows the cursor in the world (a folder's: one
-- of its variants, another after each placed), the panel goes out of the way unless it stays open while placing
function PN:pick(e)
  if not e or e.type ~= "template" then return end
  local ed = self.ed
  local c = self.catalog and self.catalog.model
  if e.members and #e.members > 0 then
    if c then c:remember(e) end
    call(ed, "set_template", e.members[math.random(#e.members)], false, e.members, nil)
  else
    if c then c:remember(e) end
    call(ed, "set_template", e.path, false, nil, e.look)
  end
  ed.catalog_pick = true            -- placed or given up: back to the catalog (editor.back_to_catalog)
  if not self:setting("catalog_stays") then self:close_panel() end
  call(ed, "focus_game")
end
-- a catalog entry current (a click, the arrow keys): the inspector shows it (the inspector: still to come)
function PN:catalog_current(e)
  self:show_inspector(true)
  local c = self.catalog and self.catalog.model
  local fav = false
  for _, k in ipairs(c and c.favourites or {}) do if k == e.key then fav = true end end
  self.ins:show_entry(e, fav)
end
-- panel.show_inspector: the inspector belongs to the catalog - on the other tabs it waits until the catalog is shown
-- again; shown or gone, the window grows or shrinks by it (place_at: INSPECTOR_W and 8)
function PN:show_inspector(on)
  self.inspector_wanted = on
  local vis = on and (self.tabs_hidden or self.tab == 0)
  if vis ~= self.inspector then
    self.inspector = vis
    if self.rect then self:place() end
  end
end
PN.INSPECTOR_EXTRA = 330 + 8

return PN
