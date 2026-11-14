-- The editor's logic (editor.py: Editor) in the game. Rules: ingame/spec/editor.md. Everything editor.py does through
-- Windows, Qt or the pipe goes through `sys` (the game's adapter, or the recorder's stand-ins in the lab):
--
--   sys.exec(cmd)            a console command (w3.exec)
--   sys.lines()              the game's lines since the last call (w3.link.since)
--   sys.pressed(vk)          a key or mouse button down now ("W", "LBUTTON", "F8", "K1" ... as editor.VK)
--   sys.cursor()             the mouse on the screen: x, y
--   sys.client()             the game's picture on the screen: x, y, w, h
--   sys.set_cursor(x, y)     the mouse put back (looking around)
--   sys.wheel()              wheel notches since the last call
--   sys.time(), sys.perf()   time.time() and time.perf_counter()
--   sys.after(ms, fn)        QTimer.singleShot
--
--   local ed = EDITOR.new(project, place, template, sys, {hud = hud, panel = panel})
--   ed:tick()                 once a frame (editor.py's 60 Hz timer)
local Y = require("conjunction.yaml")
local PYS = require("conjunction.pystr")   -- (Python's str.lower: umlauts too)
local NUM = require("conjunction.pynum")
local CAM = require("conjunction.camera")
local CFG = require("conjunction.config")
local PK = require("conjunction.picking")
local QUEST = require("conjunction.quest")
local PATHS = require("conjunction.paths")
local E = {}
E.__index = E

E.VK = {"LBUTTON", "RBUTTON", "TAB", "SHIFT", "CTRL", "ALT", "SPACE", "DELETE", "K1", "K2", "C", "Z", "F8", "END",
        "V", "W", "A", "S", "D", "H", "R", "X", "ESC", "RETURN", "BACK", "F11"}
-- keys an action can have (hud.py): letters, digits, F1..F12 (the names hud.keys holds)
E.KEY_NAMES = {}
for c = 65, 90 do E.KEY_NAMES[#E.KEY_NAMES + 1] = string.char(c) end
for c = 48, 57 do E.KEY_NAMES[#E.KEY_NAMES + 1] = string.char(c) end
for i = 1, 12 do E.KEY_NAMES[#E.KEY_NAMES + 1] = "F" .. i end
E.RESERVED = {W = true, A = true, S = true, D = true, SPACE = true, CTRL = true, SHIFT = true, ALT = true, TAB = true,
              DELETE = true, END = true, F8 = true, ESC = true}
E.SEE_THROUGH = 0.1
E.LOOK_DEG_PER_PX = 0.15
E.WHEEL_DEG = 10.0
E.CLICK_S = 0.3
E.GIZMO_M = 0.8
E.GIZMO_PICK_PX = 14
E.GIZMO_FREE_PX = 11
E.UNDO_MAX = 200
E.GRID_STEPS = {0.0, 0.1, 0.25, 0.5, 1.0, 2.0}
E.TURN_STEPS = {1.0, 5.0, 10.0, 15.0, 45.0, 90.0}
E.LIGHTS = {"game", "morning", "midday", "evening", "night"}

-- a key's virtual-key name (editor.py's VK and KEY_VK share codes: "C" and "K1"/"1" are the same key)
local VK_CODE = {LBUTTON = 0x01, RBUTTON = 0x02, TAB = 0x09, SHIFT = 0x10, CTRL = 0x11, ALT = 0x12, SPACE = 0x20,
                 DELETE = 0x2E, K1 = 0x31, K2 = 0x32, C = 0x43, Z = 0x5A, F8 = 0x77, END = 0x23, V = 0x56, W = 0x57,
                 A = 0x41, S = 0x53, D = 0x44, H = 0x48, R = 0x52, X = 0x58, ESC = 0x1B, RETURN = 0x0D, BACK = 0x08,
                 F11 = 0x7A}
local KEY_VK = {}
for c = 65, 90 do KEY_VK[string.char(c)] = c end
for c = 48, 57 do KEY_VK[string.char(c)] = c end
for i = 1, 12 do KEY_VK["F" .. i] = 0x6F + i end
E.VK_CODE, E.KEY_VK = VK_CODE, KEY_VK
-- the code -> one name the sys reads it by ("C" both a VK and a key name: one code)
local CODE_NAME = {}
for name, code in pairs(KEY_VK) do CODE_NAME[code] = name end
for name, code in pairs(VK_CODE) do CODE_NAME[code] = name end
local ALL_CODES = {}
for code in pairs(CODE_NAME) do ALL_CODES[#ALL_CODES + 1] = code end
table.sort(ALL_CODES)

-- panel.setting: the panel's settings, read once
local SETTINGS = {catalog_stays = false, catalog_back = true, see_through = true}
local settings = {}
function E.setting(key)
  if settings[key] == nil then
    local v = CFG.load()[key]
    if v == nil then v = SETTINGS[key] end
    settings[key] = (v ~= false and v ~= Y.null and v ~= 0 and v ~= "")
  end
  return settings[key]
end

-- the gear's entry clicked: the setting the other way, kept (panel._toggle_setting)
function E:toggle_setting(key)
  settings[key] = not E.setting(key)
  CFG.set(key, settings[key])
end

local function fmt(f, ...) return string.format(f, ...) end
local function b(v) return v and "true" or "false" end
local function f1(v) return fmt("%.1f", v) end
local function f3(v) return fmt("%.3f", v) end
local function list_copy(l) local o = {} for i, v in ipairs(l) do o[i] = v end return o end
local function contains(l, v) for i, x in ipairs(l) do if x == v then return i end end return nil end

-- a stand-in for what is not there yet (the panel: step 2): every call does nothing and answers nothing
local function nothing()
  return setmetatable({}, {__index = function(t, k)
    local f = function() return nil end
    rawset(t, k, f)
    return f
  end})
end
E.nothing = nothing

function E.new(project, place, template, sys, parts)
  parts = parts or {}
  local self = setmetatable({}, E)
  self.project, self.place, self.sys = project, place, sys
  self.template = template or ""
  self.cam = CAM.new()
  self.mode = "look"
  self.collide, self.music_off, self.editing = true, false, false
  self.edit_existing = false
  local cfg = CFG.load()
  self.sound_off = cfg.sound_off ~= nil and cfg.sound_off ~= false and cfg.sound_off ~= Y.null
  self.sound_paused = nil
  self.catalog_screen = cfg.catalog_screen or "game"
  self.selected, self.drag = nil, nil
  self.opts = Y.map({"grid", 0.0, "turn", E.WHEEL_DEG, "align", false, "random", false, "light", 0})
  local po = cfg.place_opts
  if Y.is_map(po) then for k, v in pairs(po) do self.opts[k] = v end end
  self.group = {}
  self.lamp, self.snap, self.lamp_level, self.lamp_scrolled = false, false, 0, false
  self.paused = false                             -- P: the world stands, the camera flies (cj_pause)
  self.fly_speed = NUM.float(cfg.fly_speed or 8.0)
  self.clipboard, self.paste_pending = {}, false
  self.look_from, self.look_t, self.looked, self.flying = nil, 0.0, false, false
  self.restarting, self.saved_locked = false, false
  self.next_pause_off = 0.0
  self.last_where, self.last_heading = nil, nil
  self.path_tool, self.terrain_tool, self.path_pending = nil, nil, false
  self.undo, self.undoing = {}, 0
  self.last_pick = nil
  self.request = nil
  self.seeing_through = false
  self.live, self.live_next, self.live_seen = {}, 0.0, {}
  local rk = Y.is_map(cfg.rotate_keys) and cfg.rotate_keys or Y.map({"pitch", "R", "roll", "TAB"})
  self.rotate_keys = {}
  for a, k in pairs(rk) do self.rotate_keys[a] = VK_CODE[k] end
  self.cleared_old = false
  self.prev = {}
  for _, c in ipairs(ALL_CODES) do self.prev[c] = false end
  self.panel = parts.panel or nothing()
  self.hud = parts.hud
  self.markers = "off"
  self.senses = false
  -- what the HUD reads (hud.lua): the player's keys, Play's kind, experimental features, the world's name
  -- (hud.Hud.__init__) once: the modes on 1-4 in the bar's order, the old mode keys of a player out (MaximdeWinter 18.10.:
  -- his 1, 2, C stayed); the other keys stay
  if cfg.mode_keys_v2 == nil or cfg.mode_keys_v2 == false or cfg.mode_keys_v2 == Y.null then
    local hk = cfg.hotkeys
    if hk ~= nil and hk ~= Y.null and next(hk) ~= nil then
      local keep = Y.map()
      for _, a in ipairs(Y.keys(hk)) do
        if a:sub(1, 5) ~= "mode." then keep[a] = hk[a] end
      end
      cfg.hotkeys = keep
    end
    cfg.mode_keys_v2 = true
    CFG.save(cfg)
  end
  self.hotkeys = cfg.hotkeys
  self.play_kind = cfg.play_button or "play"
  self.experimental = E.experimental()
  self.world_name = nil
  -- a suite that ended without closing left the game in edit mode: off first
  self:exec("cj_edit(false)")
  self:exec(fmt('cj_set_place("%s")', place))
  self:exec(self.template ~= "" and fmt('cj_set_template("%s")', self.template) or "cj_clear_template()")
  self._place_look = nil
  self:exec("cj_clear_look()")
  self:exec("cj_mode(false)")
  self.world = nil
  self.jobs = {}
  -- the runs a start parked (cj_core, before the engine looked at the dlc folder) into the project's versions
  if project and project.path then pcall(require("conjunction.play").finish_parked, project.path, print) end
  return self
end

function E:exec(cmd) return self.sys.exec(cmd) end
function E:placing() return self.mode == "place" end

-- --- modes ---
function E:set_mode(mode, catalog)
  if catalog == nil then catalog = true end
  if mode == true then mode = "place" elseif mode == false then mode = "select" end
  if mode == "terrain" and not E.experimental() then return end
  local was = self.mode
  self.mode = mode
  if mode == "place" and was ~= "place" then self.mode_before_place = was end   -- (the X goes back there)
  if mode ~= "select" then
    self.selected, self.drag = nil, nil
    self.hud.gizmo = nil
  end
  if mode == "terrain" and self.terrain_tool == nil then
    self.terrain_tool = self.make_terrain_tool and self:make_terrain_tool() or nil
  elseif mode ~= "terrain" and self.terrain_tool ~= nil then
    self.terrain_tool.drag = nil
  end
  self:exec(fmt("cj_mode(%s)", b(mode == "place")))
  if mode == "place" and catalog then
    self:open_catalog()
  elseif mode ~= "place" and was == "place" and self.panel:isVisible() and self.panel:tabs_visible() then
    self.panel:hide()
  end
  self.hud:sync()
end
-- features.experimental (CJ_EXPERIMENTAL=1 for tests; else the setting)
function E.experimental() return require("conjunction.features").experimental() end

function E:open_catalog()
  self.panel:load_catalog()
  self.panel:show_tab(0)
  if not self.panel:isVisible() or not self.panel:tabs_visible() then self:toggle_panel() end
end
function E:toggle_panel() self.panel:toggle(self) self.hud:sync() end
function E:panel_open() return self.panel:isVisible() and self.panel:tabs_visible() and self.panel:tab_index() ~= 0 end

function E:set_editing(on)
  -- (a preview's world first back as editing had it: Geralt home from the camera, not from where the preview put him)
  if not on then
    local STG = require("conjunction.scene_stage")
    if STG.staged and STG.scene_on() then require("conjunction.scene_work").stop() end
    pcall(STG.unstage, self)
    -- (the cutscene editor's picture back to the whole screen and the game's HUD: playing, its window is not drawn -
    -- the game stayed in the preview's small rectangle; editing again it sets them anew)
    local sw = self.panel and self.panel.windows and self.panel.windows.scenes
    if sw and sw.body and (sw.body.view_key or sw.body.hud_hidden) then
      pcall(require("conjunction.ui.cut_view").leave, sw.body)
    end
  end
  self.editing = on
  if on then self.test_play = nil end           -- (back in the editor: Esc is the game's menu again when playing)
  self:exec(fmt("cj_edit(%s)", b(on)))
  -- editing: the Windows cursor over the whole game, the game's own never (MaximdeWinter 23.10.: it came back again and again)
  if w3.ui and w3.ui.cursor_own then w3.ui.cursor_own(on) end
  if on then
    self:send_place_opts()
    self:exec(fmt("cj_edit_existing(%s)", b(self.edit_existing)))
  end
  self.sys.wheel()
  self.selected, self.drag, self.cam.ready = nil, nil, false
  if on then
    -- (the camera reported again: editing switched on while it was on already, the flying camera said nothing until
    -- it moved - no markers and no hint while picking, 11.11.)
    self:exec("cj_cam_sync()")
    self.hud:show()
    -- (the Asset Browser lit on the bar is open again - MaximdeWinter 23.10.)
    if self.mode == "place" then self:open_catalog() end
  else
    self:show_built()
    self.music_off = false
    self.paused = false                           -- (playing: the world runs - cj_edit ends the pause)
    self.hud:close_menu()
    self.hud:hide()
    self.panel:hide()
    if not self.said_play then
      self.said_play = true
      self.panel:say("Playing. Press F8 to return to the editor")
    end
  end
  self.hud:sync()
end
function E:play() self:set_editing(false) end
function E:open_game_menu() self:set_editing(false) self:exec("cj_game_menu()") end

-- another mod's free camera off while editing: it flies the game's camera with W A S D as the editor's does, the two
-- pulled it apart (13.11.). A mod with one lists its module's name (a module of TW3SE's shared Lua, with is_on() and
-- off()) in package.loaded.cj_free_cams; gone or renamed: nothing
function E.other_free_cams_off()                  -- -> true when one was on
  local any = false
  local names = type(package.loaded.cj_free_cams) == "table" and package.loaded.cj_free_cams or {}
  for _, name in ipairs(names) do
    local fc = package.loaded[name]
    if type(fc) == "table" and type(fc.is_on) == "function" and type(fc.off) == "function" then
      local ok, on = pcall(fc.is_on)
      if ok and on then
        pcall(fc.off)
        any = true
        print("[editor] " .. name .. " off while editing")
      end
    end
  end
  return any
end

-- what is going on now: text, keys for the bar's hint
function E:doing()
  if self.path_tool ~= nil then return self.path_tool:doing() end
  local board = self.panel.board
  if board and board.drawing then return "Laying the trail", {} end
  local r = self.request
  local name = (PATHS.splitext(PATHS.basename(self.template or ""))):gsub("_", " ")
  if r then
    local what = r.what or (r.world and require("conjunction.world_pick").noun(r.world))
    if r.how == "point" then return (what and ("Pick a point \u{b7} " .. what) or "Pick a point"), {"Esc"} end
    if r.how == "pick" then return (what and ("Pick \u{b7} " .. what) or "Pick an object"), {"Esc"} end
    return "Place \u{b7} " .. ((board and board.chosen_title) or name), {"Esc"}
  end
  if self.mode == "terrain" and self.terrain_tool ~= nil then return self.terrain_tool:doing() end
  if self.mode == "place" and self.template ~= "" then
    -- (big, in the middle as a step's pick, without a key cap - MaximdeWinter 13.11.: the framed Enter looked like a button
    -- that did nothing; without it the hint sat small in the corner)
    return "Placing \u{b7} " .. name .. " (Enter: done)", {}, true
  end
  if self.mode == "select" and self.selected then
    local oid = self:selected_object_id()
    return (oid and ("Selected \u{b7} " .. oid) or "Selected"), {}
  end
  return nil, {}
end

function E:toggle_collision() self.collide = not self.collide self.hud:sync() end
function E:toggle_snap() self.snap = not self.snap self.hud:sync() end
function E:toggle_edit_existing()
  if not E.experimental() then self.edit_existing = false return end
  self.edit_existing = not self.edit_existing
  self:exec(fmt("cj_edit_existing(%s)", b(self.edit_existing)))
  self.hud:sync()
end
function E:cycle_catalog_screen()
  self.catalog_screen = self.catalog_screen == "game" and "second" or "game"
  CFG.set("catalog_screen", self.catalog_screen)
  self.hud:sync()
end

function E:copy_selection()
  local objs = ((self.project.places[self.place] or {}).objects) or {}
  local out = {}
  local all = {self.selected}
  for _, g in ipairs(self.group) do all[#all + 1] = g end
  for _, pos in ipairs(all) do
    local i = self.project:find_object(self.place, pos)
    if i then
      local o = objs[i]
      out[#out + 1] = {o.template, list_copy(o.pos), list_copy(o.rot)}
    end
  end
  if #out > 0 then
    self.clipboard = out
    self:log(fmt("[editor] copied %d object(s) - Ctrl+V puts them under the cursor", #out))
  end
end
function E:paste_at(hit)
  local anchor = self.clipboard[1][2]
  for _, c in ipairs(self.clipboard) do
    local tpl, pos, rot = c[1], c[2], c[3]
    local p = {hit[1] + pos[1] - anchor[1], hit[2] + pos[2] - anchor[2], hit[3] + pos[3] - anchor[3]}
    self:exec(fmt('cj_place_at("%s", %.3f, %.3f, %.3f, %s, %s, %s)', tpl, p[1], p[2], p[3], NUM.str(rot[1]),
                  NUM.str(rot[2]), NUM.str(rot[3])))
  end
end

function E:save_opts()
  local cfg = CFG.load()
  cfg.place_opts = self.opts
  CFG.save(cfg)
end
function E:cycle_option(key)
  local o = self.opts
  if key == "grid" then
    local i = contains(E.GRID_STEPS, o.grid)
    o.grid = i and E.GRID_STEPS[i % #E.GRID_STEPS + 1] or E.GRID_STEPS[1]
  elseif key == "turn" then
    local i = contains(E.TURN_STEPS, o.turn)
    o.turn = i and E.TURN_STEPS[i % #E.TURN_STEPS + 1] or E.WHEEL_DEG
  else
    o[key] = not o[key]
  end
  self:save_opts()
  self:send_place_opts()
  self.hud:sync()
end
function E:set_option(key, value)
  self.opts[key] = value
  self:save_opts()
  self:send_place_opts()
  self.hud:sync()
end
function E:toggle_senses()
  self.senses = not self.senses
  self:exec(fmt("cj_senses(%s)", b(self.senses)))
  self.hud:sync()
end
-- P: the world stands still (people, animals, leaves, the clock) while the camera flies on - to look at a moment
-- closely (MaximdeWinter 27.10.). Playing ends it
function E:toggle_pause()
  self.paused = not self.paused
  self:exec(fmt("cj_pause(%s)", b(self.paused)))
  self.hud:sync()
end
function E:toggle_lamp()
  self.lamp = not self.lamp
  self:exec(fmt("cj_lamp(%s)", b(self.lamp)))
end
function E:lamp_step(n)
  self.lamp_level = math.max(-4, math.min(10, self.lamp_level + n))
  self:exec(fmt("cj_lamp_power(%.3f)", 1.5 ^ self.lamp_level))
  if not self.lamp then self:toggle_lamp() end
end
function E:lamp_keys(now, up)
  local vk = KEY_VK[self.hud.keys["opt.lamp"] or ""]
  if not vk then return end
  if now[vk] then
    local n = self.sys.wheel()
    if n ~= 0 then
      self:lamp_step(n)
      self.lamp_scrolled = true
    end
  elseif up[vk] then
    if not self.lamp_scrolled then self:toggle_lamp() end
    self.lamp_scrolled = false
  end
end
function E:speed_keys(now)
  local vk = KEY_VK[self.hud.keys["opt.speed"] or ""]
  if not vk or not now[vk] then return false end
  local n = self.sys.wheel()
  if n ~= 0 then
    local v = math.min(100.0, math.max(0.1, self.fly_speed * 1.25 ^ n))
    -- (under 1 m/s two places: with one, 0.1 a notch up came back to 0.1; round(v): an int)
    if v < 1 then self.fly_speed = NUM.round(v, 2)
    elseif v < 10 then self.fly_speed = NUM.round(v, 1) else self.fly_speed = NUM.round(v) end
    CFG.set("fly_speed", self.fly_speed)
    self.hud:sync()
  end
  return true
end
function E:send_place_opts()
  local o = self.opts
  self:exec(fmt("cj_place_opts(%s, %s, %s)", NUM.str(o.grid), b(o.align), b(o.random)))
  self:exec(fmt("cj_light(%s)", NUM.str(o.light or 0)))
end
function E:focus_game() end

-- something taken from the catalog was placed, or given up: the catalog again (unless 'back to the catalog' is off)
function E:back_to_catalog(given_up)
  if not self.catalog_pick or not (given_up or E.setting("catalog_back")) then return false end
  self.catalog_pick = false
  self.template = ""
  self:exec("cj_clear_template()")
  self:open_catalog()
  self.hud:sync()
  return true
end

-- --- the quest board asks for objects ---
-- (o.back: called in place of the quest board coming back when the answer is there; o.cancelled: when it is given up -
-- another window that asked, the scene workshop)
function E:request_object(how, kind, done, template, what, o)
  o = o or {}
  self.request = {how = how, kind = kind, done = done, what = what, back = o.back, cancelled = o.cancelled,
                  world = o.world, world_done = o.world_done,  -- (world: an object of the world of that kind too)
                  world_many = o.world_many,                    -- (several of them with Shift: world_many(refs))
                  test = o.test,                                -- (the list's Test: test(picked) -> a function back)
                  picked = o.picked, edit = o.edit,             -- (Select on a step: the list filled, Enter replaces it)
                  settings = o.settings}                        -- (what the step does, chosen in the list)
  -- (the panel lies over the world in the game: it goes while the world is clicked, the answer brings the quest
  -- back - MaximdeWinter 24.10.: placing for a quest step, the quest window hid what was placed. The app's stays: its own
  -- window beside the game)
  if self.panel:isVisible() then
    self.request.reshow = true
    self.panel:hide()
  end
  if how == "point" then self:set_mode("look")
  elseif how == "pick" then self:set_mode("select")
  else
    self.template = template
    self:exec(fmt('cj_set_template("%s")', template))
    self._place_look = nil                        -- (a look chosen with it: placed in exactly that one)
    if o.look then self:set_place_look(o.look) else self:exec("cj_clear_look()") end
    self:set_mode("place", false)
  end
  self.hud:sync()
end
function E:cancel_request()
  if self.request then
    local r = self.request
    self.request = nil
    if r.test_restore then r.test_restore() r.test_restore = nil end
    if r.cancelled then r.cancelled() end
    if r.reshow and not r.back then self.panel:show_board(self) end
    if self.panel.board then self.panel.board.waiting = nil end
    self.panel:sync_quest()
    self.hud:sync()
  end
end

-- Enter while placing: what was placed stays, nothing follows the cursor any more (the catalog again when it came
-- from there)
function E:finish_placing()
  if self.catalog_pick and self:back_to_catalog(true) then return end
  self.mode = "select"
  self:exec("cj_mode(false)")
  self.hud:sync()
end

-- Esc: what the board waits for, the selection; placing ends as with Enter - what was placed stays (MaximdeWinter 23.10.:
-- five objects placed just as wanted were gone after an Esc by mistake, so Esc did nothing there; 13.11.: Esc has to
-- end it again)
function E:escape()
  if self.mode == "place" and not self.request then return self:finish_placing() end
  local board = self.panel.board
  if board and board.drawing then
    board.drawing = nil
    if self.editing then self:load_place() end
  end
  if self.request or self.mode == "place" then
    self:cancel_request()
    if self.mode == "place" then
      self.mode = "select"
      self:exec("cj_mode(false)")
      self.hud:sync()
    end
    return
  end
  -- (a block picked in the dialogue or the quest graph let go - MaximdeWinter 13.11.; the Esc that ends typing in the panel
  -- does only that: panel.typing_follows)
  local ate = self.panel.esc_ate
  local typed = self.panel:typing() or (ate ~= nil and os.clock() - ate < 0.1)
  self.panel.esc_ate = nil
  local qb = self.panel.board_ui
  if not typed and qb and self.panel:isVisible() and self.panel.tab == 2 and qb:deselect() then return end   -- (2: Quest)
  if self.selected or #self.group > 0 then
    self:exec("cj_mode(false)")
    self.selected, self.group, self.drag = nil, {}, nil
    self.hud.gizmo = nil
    self:show_selected()
    self.hud:sync()
  end
end

-- an object of the world taken for the request (world_pick.lua): kept in the project, its ref to the one waiting
function E:_world_answer(c)
  local r = self.request
  if r.test_restore then r.test_restore() r.test_restore = nil end   -- (a test is a test: the world as it was)
  local WP = require("conjunction.world_pick")
  local ref = WP.keep(self.project, c, require("conjunction.py").str((self.project.places[self.place] or {}).world or self.world or ""))
  if self.project.save_meta then self.project:save_meta() end
  self.request = nil
  self:log(fmt("[editor] taken from the world: %s (%s)", c.name, ref))
  if r.world_done then r.world_done(ref) end
  if not r.back then self.panel:show_board(self) end      -- (a window that asked: it comes back itself)
  self.panel:sync_quest()
  self.hud:sync()
end

-- Enter or the list's Done: what was picked in the world taken
function E:take_picked()
  local r = self.request
  if not (r and r.world and r.picked and (#r.picked > 0 or r.edit)) then return end
  self:_world_answer_many(r.picked)
end
-- several things of the world taken at once (Shift): the first as the step's object, the rest beside it
function E:_world_answer_many(list)
  local r = self.request
  if (#list == 1 and not r.edit) or not r.world_many then return self:_world_answer(list[1]) end
  if r.test_restore then r.test_restore() r.test_restore = nil end   -- (a test is a test: the world as it was)
  local WP = require("conjunction.world_pick")
  local world = require("conjunction.py").str((self.project.places[self.place] or {}).world or self.world or "")
  local refs = {}
  for _, c in ipairs(list) do refs[#refs + 1] = c.ref or WP.keep(self.project, c, world) end   -- (the project's: its ref)
  if self.project.save_meta then self.project:save_meta() end
  self.request = nil
  self:log(fmt("[editor] taken from the world: %d things", #refs))
  r.world_many(refs)
  if not r.back then self.panel:show_board(self) end
  self.panel:sync_quest()
  self.hud:sync()
end

function E:_request_answer(index)
  local r = self.request
  local o = self.project.places[self.place].objects[index]
  local actor = QUEST.is_actor(o)
  if (r.kind == "people" or r.kind == "creatures") ~= actor then
    self:log(fmt("[editor] not a %s - pick another one", r.kind ~= "people" and r.kind:sub(1, -2) or "person"))
    return
  end
  if r.kind == "containers" or r.kind == "loot" then
    local why = QUEST.not_loot(o.template)
    if why then                                 -- (Geralt's stash: the quest's items would never be seen)
      self:log("[editor] not a container for the quest: " .. tostring(why) .. " - pick another one")
      self.panel:say(why, 4000)                 -- (the app: a tooltip at the mouse)
      return
    end
  end
  self.request = nil
  r.done(self.place, index)
  if r.how == "create" then self:set_mode("select") end
  self.panel:show_board(self)
  self.panel:sync_quest()
  self.hud:sync()
end

-- 'place/id' of every object the quest names (its steps, talks, clues): the strings of the quest that are one
function E:quest_refs()
  local out = {}
  local function walk(x)
    if type(x) == "string" then
      if x:match("^[a-z0-9_]+/[a-z0-9_]+$") and not x:find("'", 1, true) then out[x] = true end
    elseif Y.is_map(x) then
      for k, v in pairs(x) do if k ~= "voice_pack" then walk(k) walk(v) end end   -- (a recording: pack/line)
    elseif type(x) == "table" and x ~= Y.null then
      for _, v in ipairs(x) do walk(v) end
    end
  end
  walk(self.project.meta.quest)
  return out
end

-- the steps of the quest that use the object (place, index): {{number, step}}, its ref, its name
function E:object_uses(place, index)
  local o = ((self.project.places or {})[place] or {}).objects
  o = o and o[index]
  if not o or not o.id or o.id == Y.null or o.id == "" then return {}, nil, nil end
  local ref = place .. "/" .. NUM.str(o.id)
  local IC = require("conjunction.ui.item_chooser")
  local q = (self.project.meta or {}).quest
  if not Y.is_map(q) then return {}, ref, nil end
  local uses = {}
  for _, ns in ipairs(IC.numbered_steps(q)) do
    if IC.names(ns[2], ref) then uses[#uses + 1] = ns end
  end
  local name = NUM.str((o.display and o.display ~= Y.null and o.display ~= "") and o.display or o.id):gsub("_", " ")
  return uses, ref, name
end
-- the step's node shown in the quest tab, picked (the delete question's Show step)
function E:show_step(step)
  self.panel:show_board(self)
  local b = self.panel:board_of()
  local nid = b and b.node_of and b:node_of(step) or nil
  if nid ~= nil then b:graph_picked(nid) end
end
-- Delete with what the quest uses (MaximdeWinter 24.10.: a container of the quest deleted, the step still named it): the
-- objects about to go (the selection and its group, or the one at index) asked first when a step names one -
-- Delete, Show step (the first such step in the quest tab), Cancel; then do() deletes
E.ASK_DELETE = true                             -- (false: deleted at once, as the app does - ref/editor_rec)
function E:delete_checked(indices, go)
  if not E.ASK_DELETE then return go() end
  local all, names = {}, {}
  for _, i in ipairs(indices) do
    local uses, _, name = self:object_uses(self.place, i)
    if #uses > 0 then
      names[#names + 1] = name
      for _, ns in ipairs(uses) do all[#all + 1] = ns end
    end
  end
  if #all == 0 then return go() end
  local seen, steps = {}, {}
  for _, ns in ipairs(all) do
    local t = math.type(ns[1]) and ("step " .. ns[1]) or NUM.str(ns[1])
    if not seen[t] then seen[t] = true steps[#steps + 1] = t end
  end
  local which = table.concat(steps, ", "):gsub("^step", "Step")
  local text = string.format("%s %s %s. Delete %s anyway?", which, #steps == 1 and "needs" or "need",
                             table.concat(names, ", "), #names == 1 and "it" or "them")
  local DLG = require("conjunction.ui.dialogs")
  DLG.choose(self, "Delete", text, {{"delete", "Delete"}, {"step", "Show step"}, {"cancel", "Cancel"}}, function(a)
    if a == "delete" then go()
    elseif a == "step" then self:show_step(all[1][2]) end
  end)
end
function E:delete_selected()
  local idx = {}
  local i = self:_selected_index()
  if i then idx[#idx + 1] = i end
  for _, gp in ipairs(self.group or {}) do
    local j = self.project:find_object(self.place, gp)
    if j then idx[#idx + 1] = j end
  end
  self:delete_checked(idx, function() self:exec("cj_delete_selected()") end)
end

function E:jump_to(place, index)
  if place ~= self.place then self:set_place(place) end
  local o = self.project.places[place].objects[index]
  local x, y, z = o.pos[1], o.pos[2], o.pos[3]
  self.beacon = {pos = {x, y, z}, label = o.display or o.id or "", ["until"] = self.sys.time() + 6.0}
  self.hud:update()
  self:exec(fmt("cj_cam_to(%.3f, %.3f, %.3f, %.1f)", x, y, z, NUM.float(o.rot[3])))
end

function E:selected_object_id()
  local i = self.project:find_object(self.place, self.selected)
  if i == nil then return nil end
  return self.project:name_object(self.place, i)
end

function E:set_template(path, preview, variants, look)
  self.variants = variants
  self:set_place_look(look)
  if path == self.template and preview then return end
  self.template = path
  local tree = self.plant_of and self:plant_of(path) or nil
  self:exec(tree and fmt('cj_set_plant("%s")', tree) or "cj_clear_plant()")
  self:exec(fmt('cj_set_template("%s")', path))
  if not self:placing() then self:set_mode("place") end
  self.hud:sync()
  if not preview then self.panel:refresh() end
end
function E:set_place_look(look)
  if look == self._place_look then return end
  self._place_look = look
  self:exec(look and fmt('cj_set_look("%s")', look) or "cj_clear_look()")
end

function E:set_place(name)
  if name == self.place then return end
  self.place = name
  self.project:place(name, self.world)
  self:exec(fmt('cj_set_place("%s")', name))
  if self.editing then self:load_place() end
  self.panel:sync_places()
  self.hud:sync()
end

function E:player_here() self:exec("cj_player_here()") end
function E:layer_group(name)
  return table.concat({"DLC", "dlc" .. self.project:id(), self.project:id(), name}, "\\")
end
function E:dlc_installed()
  return w3.fs.isdir(CFG.load().game .. "\\dlc\\dlc" .. self.project:id())
end

local function places_in_order(self)
  local out = {}
  for name, p in pairs(self.project.places) do out[#out + 1] = {name, p} end
  return out
end
local function objects(p)
  local o = Y.is_map(p) and p.objects or nil
  if o == nil or o == Y.null then return {} end
  return o
end
local function has_objects(p) return #objects(p) > 0 end
-- Python's == of the world ids: None is None (a place without a world is in the game's)
local function nn(v) if v == Y.null then return nil end return v end
local function same_world(a, b) return nn(a) == nn(b) end
-- int() of a count: toward zero
local function pyint(v)
  local f = NUM.float(v)
  return math.tointeger(f >= 0 and math.floor(f) or math.ceil(f))
end

-- the place being edited as copies (its built layer goes meanwhile); the other places show their built layers
function E:load_place()
  self:exec("cj_clear()")
  self.selected, self.drag = nil, nil
  if self:dlc_installed() then
    for _, np in ipairs(places_in_order(self)) do
      local name, p = np[1], np[2]
      if same_world(p.world, self.world) and has_objects(p) then
        self:exec(fmt('cj_layer("%s", %s)', self:layer_group(name), name == self.place and "false" or "true"))
        for _, o in ipairs(objects(p)) do
          if o.id and o.id ~= Y.null and o.id ~= "" and QUEST.is_actor(o) then
            self:exec(fmt("cj_hide_tag(%s_%s_%s, %s)", self.project:id(), name, NUM.str(o.id),
                          name == self.place and "true" or "false"))
          end
        end
      end
    end
  end
  local p = self.project.places[self.place] or Y.map()
  local pw = p.world
  if pw ~= nil and pw ~= Y.null and pw ~= "" and pw ~= false and not same_world(pw, self.world) then
    self:log(fmt("[editor] place %s is in world %s, the game is in %s", self.place, NUM.str(pw), NUM.str(self.world)))
    return
  end
  for _, o in ipairs(objects(p)) do
    if o.envhide and o.envhide ~= Y.null then
      -- a hide area: nothing to stand there
    elseif o.trail and o.trail ~= Y.null and o.trail ~= false then
      for _, pc in ipairs(o.pieces or {}) do
        self:exec(fmt('cj_spawn("%s", %s, %s, %s, 0, 0, %s)', NUM.str(pc[5]), NUM.str(pc[1]), NUM.str(pc[2]),
                      NUM.str(pc[3]), NUM.str(pc[4])))
      end
    else
      local x, y, z = NUM.str(o.pos[1]), NUM.str(o.pos[2]), NUM.str(o.pos[3])
      local r, pi, ya = NUM.str(o.rot[1]), NUM.str(o.rot[2]), NUM.str(o.rot[3])
      self:exec(fmt('cj_spawn("%s", %s, %s, %s, %s, %s, %s)', o.template, x, y, z, r, pi, ya))
      if o.appearance and o.appearance ~= Y.null and o.appearance ~= "" then
        self:exec(fmt('cj_appearance(%s, %s, %s, "%s")', x, y, z, o.appearance))
      end
      if o.loot ~= nil then
        local clear = QUEST.is_actor(o) and "false" or "true"
        local loot = (o.loot ~= Y.null and o.loot ~= "" and o.loot) or "cj_none"
        self:exec(fmt('cj_loot_set(%s, %s, %s, "%s", %s)', x, y, z, NUM.str(loot), clear))
      end
      for _, entry in ipairs((o.inventory ~= Y.null and o.inventory) or {}) do
        self:exec(fmt('cj_inv_set(%s, %s, %s, "%s", %d)', x, y, z, entry.item,
                      pyint(entry.count == nil and 1 or entry.count)))
      end
    end
  end
  self:log(fmt("[editor] place %s: %d objects loaded for editing", self.place, #objects(p)))
end

function E:_hide_built_people()
  if not self:dlc_installed() then return end
  local p = self.project.places[self.place] or Y.map()
  local pw = p.world
  if not (pw == nil or pw == Y.null or same_world(pw, self.world)) then return end
  for _, o in ipairs(objects(p)) do
    if o.id and o.id ~= Y.null and o.id ~= "" and QUEST.is_actor(o) then
      self:exec(fmt("cj_hide_tag(%s_%s_%s, true)", self.project:id(), self.place, NUM.str(o.id)))
    end
  end
end

-- editing ends: the copies go and the built quest is back
function E:show_built()
  self:exec("cj_clear()")
  self.selected, self.drag = nil, nil
  if self.senses then
    self.senses = false
    self:exec("cj_senses(false)")
  end
  if not self:dlc_installed() then return end
  for _, np in ipairs(places_in_order(self)) do
    local name, p = np[1], np[2]
    if same_world(p.world, self.world) and has_objects(p) then
      -- (as the build has it: a place for a step that no step shows comes from the start)
      local vis = require("conjunction.questgen").place_visible(self.project, name)
      if vis == "start" then
        self:exec(fmt('cj_layer("%s", true)', self:layer_group(name)))
        for _, o in ipairs(objects(p)) do
          if o.id and o.id ~= Y.null and o.id ~= "" and QUEST.is_actor(o) then
            self:exec(fmt("cj_hide_tag(%s_%s_%s, false)", self.project:id(), name, NUM.str(o.id)))
          end
        end
      end
    end
  end
end

function E:_selected_index() return self.project:find_object(self.place, self.selected) end
function E:_selected_is_marker()
  local d = self.drag or {}
  if d.marker == nil then
    local i = self.project:find_object(self.place, d.start or self.selected)
    local objs = objects(self.project.places[self.place] or Y.map())
    d.marker = (i ~= nil and objs[i] ~= nil and objs[i].marker ~= nil and objs[i].marker ~= false and objs[i].marker ~= Y.null)
  end
  return d.marker
end
function E:show_selected() self.panel:show_selected(self) end

function E:toggle_sound()
  self.sound_off = not self.sound_off
  CFG.set("sound_off", self.sound_off)
  self:keep_sound(true)
  self.hud:sync()
end
function E:keep_sound(front)
  local paused = self.sound_off or not front
  local back = front and self._sound_front == false
  self._sound_front = front
  if paused ~= self.sound_paused then
    self.sound_paused = paused
    self:exec(paused and "cj_sound_pause()" or "cj_sound_resume()")
  elseif back and self.sound_off then
    self:exec("cj_sound_pause()")
    for _, ms in ipairs({600, 1600}) do
      self.sys.after(ms, function() if self.sound_off and self.sound_paused then self:exec("cj_sound_pause()") end end)
    end
  end
end
function E:toggle_music()
  self.music_off = not self.music_off
  self:exec(fmt("cj_music(%s)", b(self.music_off)))
  self.hud:sync()
end

-- --- undo: every change the game reports, with what takes it back ---
function E:undo_entry(what, kv, pos)
  local tpl = kv.template or ""
  local rot = {}
  for i, v in ipairs(PROJECT_split(kv.rot or "0,0,0")) do rot[i] = NUM.float(v) end
  if what == "placed" then return {"placed", tpl, pos, rot} end
  if what == "deleted" then return {"deleted", tpl, pos, rot} end
  if what == "moved" or what == "rotated" then
    local key = pos
    if what == "moved" then
      key = {}
      for i, v in ipairs(PROJECT_split(kv.from, ",")) do key[i] = NUM.float(v) end
    end
    local i = self.project:find_object(self.place, key)
    if i then
      local o = self.project.places[self.place].objects[i]
      return {"moved", tpl, list_copy(o.pos), list_copy(o.rot), pos}
    end
  end
  return nil
end
function E:undo_last()
  if #self.undo == 0 then self:log("[editor] nothing to undo") return end
  local e = table.remove(self.undo)
  if e[1] == "terrain" then
    if self.terrain_tool then self.terrain_tool:undo() end
    self:log("[editor] undo terrain")
    return
  end
  if e[1] == "quest" then
    self.panel:restore_quest(e[2])
    self:log("[editor] undo quest")
    return
  end
  self.undoing = self.undoing + 1
  if e[1] == "placed" then
    self:exec(fmt("cj_delete_at(%.3f, %.3f, %.3f)", e[3][1], e[3][2], e[3][3]))
  elseif e[1] == "deleted" then
    self:exec(fmt('cj_place_at("%s", %.3f, %.3f, %.3f, %.2f, %.2f, %.2f)', e[2], e[3][1], e[3][2], e[3][3], e[4][1],
                  e[4][2], e[4][3]))
  else
    self:exec(fmt("cj_set_at(%.3f, %.3f, %.3f, %.3f, %.3f, %.3f, %.2f, %.2f, %.2f)", e[5][1], e[5][2], e[5][3],
                  e[3][1], e[3][2], e[3][3], e[4][1], e[4][2], e[4][3]))
  end
  self:log("[editor] undo " .. e[1])
end
function E:set_selected_transform(pos, rot)
  if self.selected then
    self:exec(fmt("cj_set_at(%.3f, %.3f, %.3f, %.3f, %.3f, %.3f, %.2f, %.2f, %.2f)", self.selected[1], self.selected[2],
                  self.selected[3], pos[1], pos[2], pos[3], rot[1], rot[2], rot[3]))
  end
end
-- --- the selected object's contents and look (editor.py ask_inventory, set_object_item, set_object_loot,
-- set_object_look) ---
local function at3(sel) return NUM.str(sel[1]), NUM.str(sel[2]), NUM.str(sel[3]) end
function E:ask_inventory()
  if self.selected then self:exec(fmt("cj_inv_list(%s, %s, %s)", at3(self.selected))) end
end
-- count of item put in by this quest (0: none, nil: one more)
function E:set_object_item(item, count)
  local i = self:_selected_index()
  if i == nil then return end
  local o = self.project.places[self.place].objects[i]
  local inv = Y.list({})
  local have
  for _, e in ipairs(o.inventory or {}) do
    local c = Y.map({})
    for _, k in ipairs(Y.keys(e)) do c[k] = e[k] end
    inv[#inv + 1] = c
    if c.item == item then have = c end
  end
  if count == nil then count = (have and (math.tointeger(tonumber(have.count)) or 0) or 0) + 1 end
  if have then have.count = count else inv[#inv + 1] = Y.map({"item", item, "count", count}) end
  local kept = Y.list({})
  for _, e in ipairs(inv) do if (math.tointeger(tonumber(e.count)) or 0) > 0 then kept[#kept + 1] = e end end
  self.project:set_object(self.place, i, {"inventory", kept})
  local x, y, z = at3(self.selected)
  if tostring(item):sub(1, 4) ~= "own:" then           -- (an own item exists in the game only after the build)
    self:exec(fmt('cj_inv_set(%s, %s, %s, "%s", %d)', x, y, z, item, math.tointeger(tonumber(count)) or 0))
  end
end
-- the selected container's loot table: a name, "" none, nil the template's again (in the game: emptied, filled from
-- the table, the items always inside put back)
function E:set_object_loot(loot)
  local i = self:_selected_index()
  if i == nil then return end
  local o = self.project.places[self.place].objects[i]
  if loot == nil then
    self.project:set_object(self.place, i, {"loot", Y.null})
    Y.remove(o, "loot")
  else
    o.loot = loot                                  -- ("" is kept: set_object drops empty values)
    self.project:save_place(self.place)
  end
  local x, y, z = at3(self.selected)
  local QU = require("conjunction.quest")
  local clear = o.loot ~= nil and not QU.is_actor(o)
  local name = (o.loot ~= nil and o.loot ~= "") and o.loot or "cj_none"
  self:exec(fmt('cj_loot_set(%s, %s, %s, "%s", %s)', x, y, z, name, clear and "true" or "false"))
  for _, e in ipairs(o.inventory or {}) do
    self:exec(fmt('cj_inv_set(%s, %s, %s, "%s", %d)', x, y, z, e.item, math.tointeger(tonumber(e.count or 1)) or 1))
  end
end
function E:set_object_look(appearance)
  local i = self:_selected_index()
  if i == nil then return end
  self.project:set_object(self.place, i, {"appearance", (appearance ~= nil and appearance ~= "") and appearance or Y.null})
  if appearance and appearance ~= "" then
    local x, y, z = at3(self.selected)
    self:exec(fmt('cj_appearance(%s, %s, %s, "%s")', x, y, z, appearance))
  end
end

-- --- objects the game placed (edit existing): world changes, kept by the script extender (worldchanges.lua) ---
function E:world_remove() self:exec("cj_delete_selected()") end
function E:world_effect(name, on) self:exec(fmt("cj_world_effect('%s', %s)", name, on and "true" or "false")) end
function E:world_look(name) self:exec(fmt('cj_world_look("%s")', name)) end
function E:world_drop(cid)
  local W = require("conjunction.worldchanges")
  local change
  for _, c in ipairs(W.load(self.project.path) or {}) do if c.id == cid then change = c end end
  W.drop(self.project.path, cid)
  if change and change["do"] == "effect" and self.selected then
    self:exec(fmt("cj_world_effect('%s', false)", tostring(change.value)))
  end
  if change and change["do"] == "remove" then self:exec(fmt('cj_world_show("%s")', change.guid)) end
  if change and change["do"] == "move" then
    local parts = {}
    for p in tostring(change.otherwise or ""):gmatch("%S+") do parts[#parts + 1] = p end
    if #parts == 6 then self:exec(fmt('cj_world_put("%s", %s)', change.guid, table.concat(parts, ", "))) end
  end
  self:log(fmt("[editor] world change %s forgotten", tostring(cid)))
  self.panel:refresh_world_card()
end

-- a quest card's object in the world (MaximdeWinter 24.10.: a long quest, which chest is meant at step 3?): its place
-- edited, the camera flies to it, it is selected
function E:locate(place, index)
  if place ~= self.place then self:set_place(place) end
  local o = ((self.project.places or {})[place] or {}).objects
  o = o and o[index]
  if not o then return end
  if self.mode ~= "select" then self:set_mode("select", false) end
  self:jump_to(place, index)
  self:select_at(o.pos)
end

-- a thing the game placed (world_pick.lua): the camera to it, a beacon on it for some seconds
function E:locate_world(ref)
  local o = require("conjunction.world_pick").get(self.project, ref)
  if not (o and o.pos) then return end
  local x, y, z = NUM.float(o.pos[1]), NUM.float(o.pos[2]), NUM.float(o.pos[3])
  self.beacon = {pos = {x, y, z}, label = tostring(o.name or ""), ["until"] = self.sys.time() + 6.0}
  self.hud:update()
  self:exec(fmt("cj_cam_to(%.3f, %.3f, %.3f, %.1f)", x, y, z, 0.0))
end

function E:select_at(pos)
  if self.mode == "select" then self:exec(fmt("cj_select_at(%.3f, %.3f, %.3f)", pos[1], pos[2], pos[3])) end
end

function E:log(s) if self.sys.log then self.sys.log(s) end end

-- --- the game's lines ---
local function split(s, sep)
  local out, i = {}, 1
  while true do
    local j = s:find(sep, i, true)
    if not j then out[#out + 1] = s:sub(i); break end
    out[#out + 1] = s:sub(i, j - 1)
    i = j + #sep
  end
  return out
end
PROJECT_split = function(s, sep) return split(s, sep or ",") end
local function after(s, key)        -- line.split(key, 1)[1]
  local i = s:find(key, 1, true)
  return i and s:sub(i + #key) or nil
end
local function kv_of(parts, from)
  local kv = {}
  for i = from, #parts do
    local eq = parts[i]:find("=", 1, true)
    if eq then kv[parts[i]:sub(1, eq - 1)] = parts[i]:sub(eq + 1) end
  end
  return kv
end
local function floats(s)
  local out = {}
  for i, v in ipairs(split(s, ",")) do out[i] = NUM.float(v) end
  return out
end

function E:handle(line)
  require("conjunction.play").heard(line)      -- (a Build & Play step waiting for the game's answer)
  if line:sub(1, 6) == "where " and line:find(" player=", 1, true) then
    local ok = pcall(function()
      local rest = after(line, " player=")
      local w = {}
      for v in rest:gmatch("%S+") do w[#w + 1] = v; if #w == 3 then break end end
      self.last_where = {NUM.float(w[1]), NUM.float(w[2]), NUM.float(w[3])}
      if line:find("world=", 1, true) then
        self.last_world = PYS.lower(P_strip(split(after(line, "world="), " player=")[1]))
      else
        self.last_world = nil
      end
      if line:find(" heading=", 1, true) then
        self.last_heading = NUM.float(after(line, " heading="):match("^(%S+)"))
      else
        self.last_heading = nil
      end
    end)
  end
  if line == "save|locked" then self.saved_locked = true return end
  if line == "esc|edit" then
    if not self.editing then self:set_editing(true) end
    return
  end
  if line:sub(1, 14) == "edit on world=" then
    local path = P_strip(split(after(line, "world="), " template=")[1])
    self.world = require("conjunction.project").worlds()[PYS.lower(path)]
    self.world_name = self.world and (E.WORLD_NAMES[self.world] or self.world) or nil
    self:exec(fmt('cj_set_place("%s")', self.place))
    self:load_place()
  elseif line:sub(1, 14) == "spawn|missing|" then
    self:log("[editor] not in the game: " .. line:sub(15))
  elseif line:sub(1, 4) == "cam|" then
    local parts = split(line, "|")
    self.cam:from_game({table.unpack(parts, 2, 10)})
  elseif line:sub(1, 7) == "moving|" and self.drag and self.drag.sent then
    pcall(function()
      local got = floats(line:sub(8))
      self.drag.off = {got[1] - self.drag.sent[1], got[2] - self.drag.sent[2], got[3] - self.drag.sent[3]}
    end)
  elseif line:sub(1, 7) == "change|" then
    if line:find("|place=|", 1, true) and self.place and self.place ~= "" then
      local i = line:find("|place=|", 1, true)
      line = line:sub(1, i - 1) .. "|place=" .. self.place .. "|" .. line:sub(i + 8)
    end
    local parts = split(line, "|")
    local kv = kv_of(parts, 3)
    local pos = floats(kv.pos or "0,0,0")
    local what = parts[2]
    if what == "selected" or what == "moved" or what == "rotated" then self.selected = pos end
    if what == "selected" then
      self.world_sel = (self:_selected_index() == nil and kv.guid and kv.guid ~= "") and kv or nil
    end
    if what == "deleted" or what == "removed" then
      self.selected = nil
      self.world_sel = nil
    end
    local ws = self.world_sel
    if (what == "moved" or what == "rotated") and kv.game == "1" and ws and ws.guid == kv.guid then
      line = line .. "|home=" .. (ws.pos or "") .. "|homerot=" .. (ws.rot or "")
    end
    local before = self:undo_entry(what, kv, pos)
    local msg = self.project:apply_change(line)
    if msg then
      self:log("[editor] " .. msg)
      if before then
        if self.undoing > 0 then
          self.undoing = self.undoing - 1
        else
          self.undo[#self.undo + 1] = before
          while #self.undo > E.UNDO_MAX do table.remove(self.undo, 1) end
        end
      end
      if self.panel:isVisible() then self.panel:sync_places() end
    end
    if self.panel:isVisible() then self.panel:sync_selected() end
    local look = self._place_look
    if what == "placed" and msg and look then
      local name = (kv.place and kv.place ~= "") and kv.place or self.place
      local objs = objects(self.project.places[name] or Y.map())
      if #objs > 0 then
        self.project:set_object(name, #objs, {"appearance", look})
        self:exec(fmt('cj_appearance(%s, %s, %s, "%s")', NUM.str(pos[1]), NUM.str(pos[2]), NUM.str(pos[3]), look))
      end
    end
    if what == "placed" and self.variants and self:placing() then
      local vs = self.variants
      self:set_template(vs[self.sys.random(#vs)], true, vs)
    end
    if what == "placed" and not self.request and self:back_to_catalog() then return end
    if self.request and (what == "selected" or what == "placed") then
      local i
      if what == "selected" then i = self:_selected_index()
      else i = #objects(self.project.places[self.place] or Y.map()) end
      if i ~= nil and i >= 1 and (what == "selected") == (self.request.how == "pick") then
        self:_request_answer(i)
        return
      end
    end
    if what == "selected" then self:show_selected()
    elseif what == "deleted" or what == "removed" then self:show_selected()
    elseif (what == "effect" or what == "effect_off" or what == "look") and self.panel:world_card_visible() then
      self.panel:refresh_world_card()
    end
  elseif line:sub(1, 10) == "worldinfo|" then
    self.panel:world_info(line)
  elseif line:sub(1, 16) == "worldfx|missing|" then
    self.panel:world_say("It has no effect '" .. line:sub(17) .. "'")
  elseif line == "worldlook|nocomponent" then
    self.panel:world_say("It has no other appearances")
  elseif line:sub(1, 9) == "drop|none" then
    self.panel:say("Nothing below it to drop onto", 4000)
  elseif line:sub(1, 11) == "select|none" then
    local click = self.click_px
    self.click_px = nil
    local near = click and self:screen_pick(click[1], click[2], click[3], click[4]) or nil
    if near then
      self:exec(fmt("cj_select_at(%.3f, %.3f, %.3f)", near[1], near[2], near[3]))
      return
    end
    self.selected = nil
    if self.panel:isVisible() then self.panel:sync_selected() end
    self:show_selected()
  elseif line:sub(1, 6) == "group|" then
    self.group = {}
    for _, g in ipairs(split(line:sub(7), ";")) do
      local _, n = g:gsub(",", "")
      if n == 2 then self.group[#self.group + 1] = floats(g) end
    end
  elseif line:sub(1, 7) == "cursor|" and self.path_pending then
    self.path_pending = false
    if self.path_tool then self.path_tool:ground(line == "cursor|none" and nil or floats(line:sub(8))) end
  elseif line:sub(1, 7) == "cursor|" and self.point_pending then
    self.point_pending = false
    local r = self.request
    if r and r.how == "point" and line ~= "cursor|none" then
      self.request = nil
      local p = floats(line:sub(8))
      for i, v in ipairs(p) do p[i] = NUM.round(v, 3) end
      r.done(self.place, p)
      if r.back then r.back() else self.panel:show_board(self) end
      self.panel:sync_quest()
      self.hud:sync()
    end
  elseif line:sub(1, 8) == "groundz|" and self.groundz_pending then
    local done = self.groundz_pending
    self.groundz_pending = nil
    local out = {}
    for i, v in ipairs(split(line:sub(9), ";")) do out[i] = (v == "n" or v == "") and Y.null or NUM.float(v) end
    done(out)
  elseif line:sub(1, 8) == "grounds|" and self.grounds_pending then
    local done = self.grounds_pending
    self.grounds_pending = nil
    local out = {}
    for _, v in ipairs(split(line:sub(9), ";")) do if v ~= "" then out[#out + 1] = NUM.float(v) end end
    done(out)
  elseif line:sub(1, 7) == "cursor|" and self.paste_pending then
    self.paste_pending = false
    if line ~= "cursor|none" then self:paste_at(floats(line:sub(8))) end
  elseif line:sub(1, 10) == "objective|" and line:find("|status=", 1, true) then
    local body = line:sub(11)
    local cut = body:match("^.*()|status=")
    local caption, status = body:sub(1, cut - 1), body:sub(cut + 8)
    self.live_seen[P_strip(caption)] = math.tointeger(tonumber(P_strip(status) ~= "" and P_strip(status) or "0")) or 0
    self.sys.after(400, function() self:_live_done() end)
  elseif line:sub(1, 8) == "invlist|" then
    self.panel:live_inventory(line)
  end
end
P_strip = function(s) return require("conjunction.project").strip(s) end
local function P_str(v) return require("conjunction.py").str(v) end

-- --- long work in coroutines (a build, an export): one step a frame, the game goes on meanwhile
function E:job(fn, done)
  self.jobs[#self.jobs + 1] = {co = coroutine.create(fn), done = done}
end
E.GC_ROOM = 256 * 1024     -- KB a job may leave as garbage before it is collected at once
function E:run_jobs()
  if #self.jobs == 0 then return end
  for i = #self.jobs, 1, -1 do
    local j = self.jobs[i]
    local ok, err = coroutine.resume(j.co)
    if not ok or coroutine.status(j.co) == "dead" then
      table.remove(self.jobs, i)
      if j.done then j.done(ok, err) end
    end
  end
  -- what a job reads it mostly throws away (the catalog's first build reads 20 000 templates as strings: 6 GB before
  -- Lua's collector caught up; TW3SE caps all Lua mods together at 1 GB): collected once there is GC_ROOM more than
  -- after the last collection
  local live = collectgarbage("count")
  if self.gc_floor == nil or live < self.gc_floor then
    self.gc_floor = live
  elseif live > self.gc_floor + E.GC_ROOM then
    collectgarbage("collect")
    self.gc_floor = collectgarbage("count")
  end
end

-- Build & Play (play.lua: into the running game) or Check (build.check: seconds, no cooking); its lines to log, then
-- [done] or [failed], and "\0" at the end (panel._build's thread)
function E:build_and_play(play, log, test_from)
  local B = require("conjunction.build")
  -- what happened, to read afterwards (the card closes): build\last_play.log, each line with its time
  w3.fs.mkdir(self.project.path .. "\\build")
  local kept = io.open(self.project.path .. "\\build\\last_play.log", "wb")
  local to_ui = log
  log = function(line)
    if kept then
      if line == "\0" then
        pcall(function() kept:close() end)
        kept = nil
      else
        pcall(function() kept:write(os.date("%H:%M:%S ") .. ((tostring(line) .. "\n"):gsub("\r?\n", "\r\n"))) kept:flush() end)
      end
    end
    to_ui(line)
  end
  if play then                                  -- (Build & Play: its card over the game, build_view.BuildWindow)
    local BWm = require("conjunction.ui.build_window")
    local card = BWm.new(P_str(self.project.meta and self.project.meta.name or self.project:id()))
    self.build_card = card
    local to_panel = log
    log = function(line)
      to_panel(line)
      card:line(line)
    end
  end
  local function ended(ok, err)
    if ok then log("[done]" .. (play and "" or " (no errors)"))
    else
      -- (a build's own message - REDkit missing, a step without its person - says what to do; only an error of
      -- Conjunction itself gets the stack, for a bug report)
      local own = B.is_runtime_error(err) or require("conjunction.questgen").is_value_error(err)
      if not own then log(debug.traceback(tostring(B.message(err)))) end
      log("[failed] " .. B.message(err))
    end
    log("\0")
  end
  self.panel.building = true
  self:job(function()
    log("[play] " .. (play and "Build & Play" or "check") .. (test_from and (" from " .. tostring(test_from)) or ""))
    if play then require("conjunction.play").build_and_play(self, log, test_from)
    else B.check(self.project.path, log) end
  end, ended)
end

-- Export (panel._export): the export window first, then packaging.export in a job
function E:export(include_source, needs, log)
  local EW = require("conjunction.ui.export_window")
  local DW = require("conjunction.ui.dialog_window")
  local panel = self.panel
  DW.open(panel, "export", "Export", EW.new(self.project, include_source, function(values)
    panel.include_source = values.include_source
    local mine = values.project.path == self.project.path
    local packs = mine and needs and needs.packs or nil
    panel.exporting = true
    panel:build_say("Exporting...", "#cccccc")
    self:job(function()
      local path = require("conjunction.packaging").export(values.project.path, values.include_source, nil, log, packs,
                                                            values.rebuild)
      log("[done] exported")
      panel:build_say("Exported: " .. path:gsub("[\\/][^\\/]*$", ""), "#9fd38a")
      EW.show(path:gsub("[\\/][^\\/]*$", ""))
    end, function(ok, err)
      panel.exporting = false
      if not ok then
        local msg = require("conjunction.build").message(err)
        log("[failed] " .. msg)
        panel:build_say("Not exported: " .. msg, "#e57a7a")
      end
    end)
  end), panel.W, panel.H)
end

-- the mesh and foliage libraries (panel._meshlib, _foliagelib: meshlib.build, foliage.build - libraries.lua), one
-- step a frame; the game takes a library at its next start
function E:build_library(kind, log)
  local LIB = require("conjunction.libraries")
  local panel = self.panel
  self:job(function()
    if kind == "meshes" then
      LIB.build_meshes(log)
      log("[done] mesh library - active after the next game start")
    else
      LIB.build_foliage(log)
      log("[done] Foliage library (active after the next game start)")
    end
    panel.catalog = nil                         -- (reloaded with the meshes or trees the next time it opens)
  end, function(ok, err)
    panel.libraries[kind] = true
    if not ok then log("[failed] " .. require("conjunction.build").message(err)) end
  end)
end

function E:_live_done()
  -- (the board shows them: step 5)
end

-- a world came (init.lua): when it is a session started for a project from the main menu (sessions.start_project's
-- mark) - that project opened, saving locked for the session (the player's saves are never touched, MaximdeWinter 14.11.),
-- Geralt and the camera at the first thing of its places, the editor on. Any other world (a save loaded): nothing.
-- new_world false: the same world after the mod loaded again - a session stays one (CJ_SESSION outlives the reload)
function E:session_arrived(new_world)
  local m = require("conjunction.sessions").take_mark()
  if not m then
    if new_world ~= false then CJ_SESSION = false end
    self.session = CJ_SESSION == true
    return
  end
  CJ_SESSION = true
  self.session = true
  if not (self.project and PYS.lower(tostring(self.project.path)) == PYS.lower(m.project)) then
    self:switch_project(m.project)
  end
  self:exec("cj_session_nosave()")
  self:log("[editor] session in " .. tostring(m.world) .. ": " .. tostring(self.project.meta and self.project.meta.name))
  -- (Build & Play's: a test run - playing where the player stood)
  if m.play then self.test_play = true end
  self.sys.after(1500, function()
    local where = type(m.where) == "table" and m.where[3] and m.where or nil
    local place, index
    for _, name in ipairs(Y.keys(self.project.places or {})) do
      if #objects(self.project.places[name]) > 0 then place, index = name, 1 break end
    end
    if where then
      self:exec(fmt("cj_teleport(%.3f, %.3f, %.3f, 0)", NUM.float(where[1]), NUM.float(where[2]), NUM.float(where[3])))
    elseif place then
      local o = self.project.places[place].objects[index]
      self:exec(fmt("cj_teleport(%.3f, %.3f, %.3f, %.1f)", o.pos[1], o.pos[2], o.pos[3], NUM.float(o.rot and o.rot[3] or 0)))
    end
    if m.play then
      self:exec(fmt('cj_track("%s")', self.project:id()))
      return
    end
    self:set_editing(true)
    if place then self.sys.after(1200, function() self:jump_to(place, index) end) end
  end)
end

-- --- the frame ---
function E:tick()
  for _, line in ipairs(self.sys.lines()) do self:handle(line) end
  self:run_jobs()
  if self.restarting then return end
  if not self.cleared_old and not self.editing then
    self.cleared_old = true
    self:exec("cj_clear()")
    -- (a save loaded: playing - the editor comes with F8 only, MaximdeWinter 14.11.: with Conjunction installed one plays the
    -- game as usual. Started again by Build & Play: a test run)
    local play = require("conjunction.play").play_after_start()
    if play then self.test_play = true end
    self.sys.after(500, function()
      if self.editing then self:set_editing(false) end
    end)
  end
  local front = self.sys.front()
  -- back in the game after Alt+Tab: the game hides its cursor again - the editor shows it again (MaximdeWinter 06.10.:
  -- "keine maus sichtbar wenn ich im spiel getabbt bin", F8 off and on was needed)
  if front and self._was_front == false and self.editing then
    self:exec("cj_edit(true)")             -- (already on: only the cursor - conjunction_editor.ws)
    self.sys.after(600, function() if self.editing then self:exec("cj_edit(true)") end end)   -- (the game may hide
    -- it a few frames after it has the focus again)
  end
  self._was_front = front
  local STG = require("conjunction.scene_stage")
  -- (a preview that never started: its world back after a while - scene_work.after_play_tick does it for the others)
  if STG.staged and require("conjunction.scene_work").after_play == nil and os.clock() - STG.staged.at > 40
      and not STG.scene_on() then
    STG.unstage(self)
  end
  if self.editing and self.sys.time() >= (self._hide_next or 0.0) and not STG.staged then
    self._hide_next = self.sys.time() + 2.0
    self:_hide_built_people()
  end
  if self.editing and E.other_free_cams_off() then
    -- (a free camera's off sets the game's input to Exploration: Geralt would walk with W A S D - the editor's again)
    pcall(function() w3.global("theInput"):SetContext("EMPTY_CONTEXT") end)
    -- (its camera ran over the editor's and went: the game falls back to its own, not to the editor's - which runs
    -- again, conjunction_cam.ws w3sFlyCam)
    pcall(function()
      local cam = w3.global("thePlayer").w3sFlyCam
      if cam then cam:Run() end
    end)
    self:exec("cj_cam_sync()")
  end
  self:keep_sound(front)
  self.panel:follow(front)
  self:see_through()
  local mouse_only = self.panel:typing()
  local now, edge, up = {}, {}, {}
  for _, c in ipairs(ALL_CODES) do
    local name = CODE_NAME[c]
    now[c] = self.sys.pressed(name) and front and
             (not mouse_only or c == VK_CODE.LBUTTON or c == VK_CODE.RBUTTON or c == VK_CODE.ESC) or false
  end
  for _, c in ipairs(ALL_CODES) do
    edge[c] = now[c] and not self.prev[c]
    up[c] = self.prev[c] and not now[c]
  end
  self.prev = now
  local V = VK_CODE
  local x, y, w, h = self.sys.client()
  if edge[V.F11] then self:screenshot() end
  local game_front = front
  -- the editor on in the game too: a save loaded while editing turned the game's side off, the cursor stayed hidden
  -- until Alt+Tab (MaximdeWinter 23.10.) - asked again every 1.5 s; already on, it only shows the cursor
  if game_front and self.editing and self.sys.time() >= (self._edit_next or 0.0) then
    self._edit_next = self.sys.time() + 1.5
    self:exec("cj_edit(true)")
  end
  -- (the game's pause menu kept off - Esc is the editor's - only while editing; playing, a test run as well, it is the
  -- game's again, its fact runs out within 10 s: MaximdeWinter 14.11., F8 back to the editor)
  if game_front and self.editing and
     (self.sys.time() >= self.next_pause_off or self._menu_kept == false) then
    self._menu_kept = true
    self.next_pause_off = self.sys.time() + 3.0
    self:exec("cj_pause_menu_off()")
  end
  local building = self.panel.building
  if edge[V.F8] and not building then
    self:set_editing(not self.editing)
  end
  if not (self.editing and front) then
    self.sys.wheel()
    return
  end
  -- paused, the game's time stands and the camera's timer with it: every frame the camera steps in real time
  local t = self.sys.perf()
  if self.paused then self:exec(fmt("cj_cam_step(%.4f)", t - (self._step_t or t))) end
  self._step_t = t
  local cx, cy = self.sys.cursor()
  local c = {x = cx, y = cy}
  local seeing = self.seeing_through
  local on_bar = self.hud:over_bar(c.x, c.y) and not seeing
  if self.hud.menu_open and (edge[V.LBUTTON] or edge[V.RBUTTON]) and not on_bar then
    self.hud:close_menu()
    return
  end
  -- (the panel and its windows lie in the game picture: the cursor from its corner - a window with a frame, or on
  -- another screen, is not at 0, 0)
  local on_panel = not seeing and self.panel:covers(c.x - x, c.y - y)
  on_bar = on_bar or on_panel
  if on_panel then self.sys.wheel()
  elseif edge[V.LBUTTON] and self.panel:typing() then self.panel:stop_typing() end
  if on_panel and now[V.CTRL] and (edge[V.C] or edge[V.V]) and not self.panel:typing()
     and self.panel:quest_clip(edge[V.V]) then return end
  if edge[V.C] and now[V.CTRL] and self.selected then self:copy_selection() return end
  if edge[V.V] and now[V.CTRL] and #self.clipboard > 0 then
    local cx2, cy2 = self.sys.cursor()
    self.paste_pending = true
    self:exec(fmt("cj_cursor_hit(%.4f, %.4f, %.4f)", (cx2 - x) / w, (cy2 - y) / h, w / h))
    return
  end
  if edge[V.D] and now[V.CTRL] and not self:placing() and self.selected then self:exec("cj_duplicate()") return end
  if edge[V.Z] and now[V.CTRL] then self:undo_last() return end
  if self.hud.capturing then
    for _, name in ipairs(E.KEY_NAMES_SORTED) do
      local vk = KEY_VK[name]
      if edge[vk] and not E.RESERVED[name] then self.hud:set_key(name) return end
    end
    if edge[V.ESC] then self.hud:set_key(nil) end
    return
  end
  local tool = self.path_tool
  if tool ~= nil then
    if edge[V.ESC] then tool:cancel() return end
    if edge[V.RETURN] then tool:finish() return end
    if edge[V.BACK] then tool:back() return end
  end
  if edge[V.ESC] then self:escape() return end
  if edge[V.RETURN] and self.mode == "place" and not self.request then self:finish_placing() return end
  local board = self.panel.board
  if edge[V.RETURN] and board and board.drawing then board:finish_trail() return end
  if not now[V.CTRL] then
    self:lamp_keys(now, up)
    self:speed_keys(now)
    for _, a in ipairs(self.hud:key_order()) do
      local name = self.hud.keys[a]
      if name and name ~= "" and a ~= "opt.lamp" and a ~= "opt.speed" and edge[KEY_VK[name]] then
        self:trigger(a)
        return
      end
    end
  end
  local moved_cam = self:fly(now, edge, c, on_bar)
  local sx, sy = (c.x - x) / w, (c.y - y) / h
  local inside = sx >= 0 and sx <= 1 and sy >= 0 and sy <= 1 and not on_bar
  local a = fmt("%.4f, %.4f, %.4f", sx, sy, w / h)
  if self.path_tool ~= nil and inside then
    if edge[V.LBUTTON] then
      self.path_tool:click(c.x - x, c.y - y, function() self:_ask_path_ground(a) end)
      return
    end
    if up[V.RBUTTON] and self.look_from and not self.looked and self.sys.perf() - self.look_t < E.CLICK_S then
      self.path_tool:right_click(c.x - x, c.y - y)
    end
  end
  if inside and self.request and self.request.how == "point" and edge[V.LBUTTON] then
    self.point_pending = true
    self:exec(fmt("cj_cursor_hit(%s)", a))
    return
  end
  local tt = self.terrain_tool
  if self.mode == "terrain" and tt ~= nil then
    if inside then
      tt:handle(edge, up, now, V, c.x - x, c.y - y, w, h, moved_cam)
    elseif tt.drag and up[V.LBUTTON] then
      tt:_finish(tt.cursor)
    end
  elseif inside and self.mode ~= "look" then
    if self:placing() and self.template ~= "" then
      if a ~= self.last_pick or moved_cam then
        self:exec(fmt("cj_pick(%s)", a))
        self.last_pick = a
      end
      if edge[V.LBUTTON] then self:exec("cj_place()") end
    elseif not self:placing() then
      self:select_mode(edge, up, now, c.x - x, c.y - y, w, h, a)
    end
    if up[V.RBUTTON] and self.look_from and not self.looked and self.sys.perf() - self.look_t < E.CLICK_S then
      -- (the object under the mouse - the hover's, else found as the hover finds it: the game's trace hits only
      -- what has static collision, a person it went through - MaximdeWinter 13.11.); asked first when the quest uses it
      local o = self.hud and self.hud.hover
      if not o then
        local mx, my = c.x - x, c.y - y
        local p = self:box_pick(mx, my, w, h) or self:screen_pick(mx, my, w, h, 30)
        local k = p and self.project:find_object(self.place, p)
        o = k and self.project.places[self.place].objects[k] or nil
      end
      local pos = o and o.pos
      local i = pos and self.project:find_object(self.place, pos) or nil
      if i and E.ASK_DELETE and #self:object_uses(self.place, i) > 0 then
        self:delete_checked({i}, function()
          self:exec(fmt("cj_delete_at(%.3f, %.3f, %.3f)", pos[1], pos[2], pos[3]))
        end)
      elseif i then
        self:exec(fmt("cj_delete_at(%.3f, %.3f, %.3f)", pos[1], pos[2], pos[3]))
      else
        self:exec(fmt("cj_delete(%s)", a))
      end
    end
  end
  if up[V.RBUTTON] then self.look_from = nil end
  if edge[V.END] and self.mode == "select" and self.selected then self:exec("cj_drop_selected()") end
  if edge[V.DELETE] and self:_over_panel() then
    self.panel:delete_picked()
  elseif edge[V.DELETE] and self.mode == "select" and self.selected then
    self:delete_selected()
  end
  local n = self.sys.wheel()
  if n ~= 0 and self.mode == "terrain" and tt ~= nil then
    if now[V.SHIFT] then tt:strengthen(n) else tt:resize(n) end
  elseif n ~= 0 then
    local axis = now[self.rotate_keys.pitch] and 1 or (now[self.rotate_keys.roll] and 2 or 0)
    local step = now[V.SHIFT] and 1.0 or NUM.float(self.opts.turn)
    self:exec(fmt("cj_rotate(%.1f, %d)", n * step, axis))
  end
  local hover
  if self.drag then hover = self.drag.axis
  elseif inside and self.mode == "select" then hover = self:gizmo_axis_at(c.x - x, c.y - y, w, h) end
  self:hover_object(inside and self.mode == "select" and not self.drag and hover == nil and not on_bar,
                    c.x - x, c.y - y, w, h, moved_cam)
  local free = self.drag ~= nil and self.drag.axis == "free"
  self.hud.gizmo = (self.selected and self.mode == "select" and not free) and {pos = self.selected, hover = hover} or nil
  self.hud:update()
end
-- hud.keys in the order Python's dict has them (the HUD gives it)
E.KEY_NAMES_SORTED = {}
do
  -- KEY_VK.items() order in editor.py: letters A..Z, digits 0..9, F1..F12
  for c = 65, 90 do E.KEY_NAMES_SORTED[#E.KEY_NAMES_SORTED + 1] = string.char(c) end
  for c = 48, 57 do E.KEY_NAMES_SORTED[#E.KEY_NAMES_SORTED + 1] = string.char(c) end
  for i = 1, 12 do E.KEY_NAMES_SORTED[#E.KEY_NAMES_SORTED + 1] = "F" .. i end
end

function E:_ask_path_ground(a)
  self.path_pending = true
  self:exec(fmt("cj_cursor_hit(%s)", a))
end

-- a hide area of the place being edited (envhide.py): its outline drawn in the world with the path tool - a new one
-- (index nil) or one already there (1-based). Every point is kept as it is set; the area needs three.
function E:hide_area(index)
  local EH = require("conjunction.envhide")
  local PT = require("conjunction.pathtool")
  local objs = self.project:place(self.place, self.world).objects
  local o = index ~= nil and objs[index] or nil
  local spec = (o and o.envhide ~= nil and o.envhide ~= Y.null) and o.envhide or {}
  local pts = {}
  if o then
    for _, d in ipairs(spec.points or {}) do pts[#pts + 1] = {o.pos[1] + d[1], o.pos[2] + d[2], o.pos[3] + 1.0} end
  end
  -- the area itself, not its index: an object deleted meanwhile moves the indices (the area kept another one)
  local state = {obj = o}
  local function keep(points)
    if #points < 3 then return end
    local i = nil
    if state.obj ~= nil then
      for k, x in ipairs(objs) do if x == state.obj then i = k break end end
      if i == nil then return end               -- (the area itself was deleted meanwhile)
    end
    local old = i ~= nil and objs[i] or Y.map()
    local flags = (old.envhide ~= nil and old.envhide ~= Y.null) and old.envhide or {}
    local function fl(k, default)
      local v = flags[k]
      if v == nil or v == Y.null then return default end
      return v
    end
    local new = EH.area_object(points, fl("height", 20.0), fl("foliage", true), fl("terrain", false), fl("water", false),
                               old.id)
    if i == nil then
      objs[#objs + 1] = new
      i = #objs
      state.obj = new
      self.project:name_object(self.place, i, nil, "hide_area")
    else
      local id = old.id
      new.id = (id == nil) and Y.null or id
      local merged = Y.map()                    -- ({**old, **new}: old's keys in their order, new's after them)
      for _, k in ipairs(Y.keys(old)) do merged[k] = old[k] end
      for _, k in ipairs(Y.keys(new)) do merged[k] = new[k] end
      objs[i] = merged
      state.obj = merged
      self.project:save_place(self.place)
    end
    if self.panel:isVisible() then
      self.panel:sync_places()
      self.panel:show_area(self.place, i)
    end
  end
  local function done(points)
    keep(points)
    -- (MaximdeWinter 06.10.: Enter, "es ist nix passiert" - the area only shows after a build)
    self.panel:say("Hide area saved", 6000)
  end
  if self.path_tool ~= nil then self.path_tool:finish() end
  PT.new(self, pts, done, {label = "Hide area", closed = true, min_points = 3, on_change = keep}):start()
end

-- File > Open project: the project browser over the game (one; among the panel's windows: its clicks are not clicks
-- into the world, it lies above the game)
function E:open_projects()
  local PB = require("conjunction.ui.project_browser")
  local p = self.panel
  p.windows = p.windows or {}
  p.win_order = p.win_order or {}
  local b = p.windows.projects
  if b == nil then
    b = PB.new(self)
    b.key = "projects"
    p.windows.projects = b
  end
  for i, x in ipairs(p.win_order) do if x == b then table.remove(p.win_order, i) break end end
  p.win_order[#p.win_order + 1] = b
  local _, _, w, h = self.sys.client()
  b:show_over(w or 1600, h or 900)
end
-- File > New project: its name and kind asked over the game, made, then the editor in it (switch_project)
function E:new_project()
  local NP = require("conjunction.ui.new_project")
  local DW = require("conjunction.ui.dialog_window")
  local P = require("conjunction.project")
  DW.open(self.panel, "new project", "New project", NP.new(function(name, kind)
    self:switch_project(P.new_project(name, kind))
  end))
end

-- Another project, the game goes on (MaximdeWinter 24.10.: a new project restarted the game - since Build & Play runs in
-- the game that is not needed): every other project's DLC is switched off for the next load and its places leave the
-- world now (their layer groups, every run of it in the game); this one's first place in this world is edited. Only
-- another project's mod bundle (game files: read at a start) still needs the restart (start_clean).
function E:switch_project(path)
  local P = require("conjunction.project")
  local IG = require("conjunction.in_game")
  local PL = require("conjunction.play")
  local game = CFG.load().game
  local others = IG.others_in(path, game)
  for _, e in ipairs(others) do
    if e.where == "Mods" then return self:start_clean(path) end
  end
  self:exec("cj_clear()")
  self.selected, self.drag, self.group, self.request, self.world_sel = nil, nil, {}, nil, nil
  local hidden, off = 0, {}
  for _, e in ipairs(others) do
    local low = PYS.lower(e.folder)
    if e.where == "dlc" and low:sub(1, 3) == "dlc" then
      local run = low:sub(4)
      off[#off + 1] = run
      self:exec(fmt("cj_dlc_enable('dlc_%s', false)", run))
      local ok, op = pcall(P.open, e.project)
      if ok and op then
        for _, g in ipairs(PL.run_groups(op, run)) do
          self:exec(fmt('cj_layer("%s", false)', g))
          hidden = hidden + 1
        end
      end
    end
  end
  if #off > 0 then
    self:log(fmt("[editor] out of the world: %s (%d layer groups)",
                 table.concat(off, ", "), hidden))
  end
  self.project = P.open(path)
  P.remember(self.project.path)
  self.undo, self.live, self.live_seen = {}, {}, {}
  local here, all = {}, Y.keys(self.project.places)
  for _, name in ipairs(all) do
    local w = self.project.places[name].world
    if w == nil or w == Y.null or w == "" or same_world(w, self.world) then here[#here + 1] = name end
  end
  self.place = here[1] or all[1] or "main"
  self:exec(fmt('cj_set_place("%s")', self.place))
  if self.editing then self:load_place() end
  self.panel:sync_places()
  self.panel:sync_quest()
  self.hud:sync()
  self:log(fmt("[editor] project %s: %s", self.project:id(), self.project.path))
end

-- File > Settings over the game (hud._open_settings): one of the panel's windows, at least 1000 x 640 (06.10.: the
-- key file's path and the buttons cut off)
function E:open_settings()
  local SW = require("conjunction.ui.settings_window")
  local w = self.panel:open_win("settings", "Settings", "settings", function() return SW.new(self) end)
  w.body.win = w
  w.rect.w, w.rect.h = math.max(w.rect.w, SW.W), math.max(w.rect.h, SW.H)
end

-- Report a bug ... (hud.open_bug_report): the bug window, one; shown again if it was closed
function E:open_bug_report()
  local BW = require("conjunction.ui.bug_window")
  local w = self.panel:open_win("bug", "Report a bug", "bug", function() return BW.new(self) end)
  w.body.win = w
  self.bug_window = w.body
end

-- File > Library over the game (hud._quests_to_play): the quests to play, synced with the game as it opens
function E:open_library()
  local LW = require("conjunction.ui.library_window")
  local w = self.panel:open_win("library", "Library", "library", function() return LW.new(self) end)
  w.body.win = w
end

-- Build > Content pack (panel._pack_maker): a mod made a content pack
function E:pack_maker()
  local PW = require("conjunction.ui.pack_window")
  local w = self.panel:open_win("packs", "Content pack", "packs", function() return PW.new(self) end)
  w.body.win = w
end

-- the bar's Build menu (hud.py: panel._build, _meshlib, _foliagelib, _show_build_tab) and Build & Play
function E:build_play_now() self.panel:build_play_now() end
function E:check()                             -- (its result is said in the Build tab: shown first - 22.10.,
  self:show_build_tab()                         -- a Check from the menu said nothing)
  self.panel:build(false)
end
function E:build_meshlib() if (self.panel.libraries or {}).meshes ~= false then self.panel:library("meshes") end end
function E:build_foliagelib() if (self.panel.libraries or {}).foliage ~= false then self.panel:library("foliage") end end
function E:show_build_tab() self:open_panel_tab(3) end
-- the bar's Outliner and Project menu: the panel open at that tab (0-based: Assets, Places, Quest, Build)
function E:open_outliner() self.panel:open_outliner(self) end
function E:open_panel_tab(i) self.panel:open_tab(self, i) end

-- File > Open screenshots folder: the project's screenshots in Explorer (the screenshots folder while it has none)
function E:screenshot_folder()
  local P = require("conjunction.project")
  local name = self.project.meta and self.project.meta.name
  if type(name) ~= "string" or name == "" then name = self.project.path:match("[^\\/]+$") end
  return PATHS.SCREENSHOTS .. "\\" .. P.slug_of(name)
end
function E:open_screenshots()
  local folder = self:screenshot_folder()
  if not w3.fs.isdir(folder) then
    folder = PATHS.SCREENSHOTS
    w3.fs.mkdir(folder)
  end
  if w3.proc and w3.proc.run then require("conjunction.fsutil").show(folder) end
end

-- File > Quit Conjunction: the app closes and the game goes on without it; here the editor goes (F8 brings it back)
function E:quit() self:set_editing(false) end

-- the quests to play at the start (__main__.in_game: the library synced; it comes up when a quest lacks something)
-- and while the editor runs (LibraryWindow.watch_quests: a file landed or left - looked at every 2 s, synced 1.5 s
-- later, a copy takes a moment; up again when one more lacks something)
function E:watch_quests()
  local LIB = require("conjunction.library")
  local function lacking_now()
    local ok, entries = pcall(LIB.sync, function() end)
    local out = {}
    for _, e in ipairs(ok and entries or {}) do if e.status ~= "installed" then out[e.file] = true end end
    if not ok then print("[library] " .. tostring(entries)) end
    return out
  end
  local function listing()
    local parts = {}
    for _, e in ipairs(w3.fs.list(LIB.QUESTS) or {}) do
      parts[#parts + 1] = e.name .. "|" .. e.size .. "|" .. e.mtime
    end
    return table.concat(parts, "\n")
  end
  local lacking = lacking_now()
  if next(lacking) then self:open_library() end
  local seen = listing()
  local function look()
    local now = listing()
    if now ~= seen then
      seen = now
      self.sys.after(1500, function()
        local w = self.panel.windows and self.panel.windows.library
        local before = lacking
        if w and w.shown and w.body.refresh then
          w.body:refresh()
          lacking = {}
          for _, f in ipairs(w.body.lacking) do lacking[f] = true end
        else
          lacking = lacking_now()
        end
        for f in pairs(lacking) do if not before[f] then self:open_library() break end end
      end)
    end
    self.sys.after(2000, look)
  end
  self.sys.after(2000, look)
end

-- File > History: the open project's history over the game (hud._open_history) - who made and changed it, with which
-- tools, whether the signatures hold
function E:open_history()
  local DW = require("conjunction.ui.dialog_window")
  local HW = require("conjunction.ui.history_window")
  local PV = require("conjunction.provenance")
  local path = self.project.path
  local steps = PV.read(path)
  local check = #steps > 0 and PV.check(steps, PV.content_hash(path)) or nil
  local title = "History of " .. (path:match("([^\\/]+)$") or path)
  DW.open(self.panel, "history", title, HW.new(steps, check))
end

-- the game again with only that project in it (editor.start_clean: quick save, the game closed, the other projects
-- out of the game folder, Conjunction again in that project): the project becomes the one the editor opens at the
-- next start, the other projects' DLCs and mod bundles leave at that start (pending.txt), the game starts again
-- (play.restart)
function E:start_clean(path)
  local P = require("conjunction.project")
  local PL = require("conjunction.play")
  local IG = require("conjunction.in_game")
  P.remember(path)
  self.panel:say("Restarting the game ...", 15000)
  self:job(function()
    local function log(s) self:log(s) end
    if self.editing then self:set_editing(false) end
    self:show_built()
    local game = CFG.load().game
    local moves = {}
    for _, e in ipairs(IG.others_in(path, game)) do
      moves[#moves + 1] = {e.where .. "\\" .. e.folder, "_conjunction_parked\\" .. e.where .. "\\" .. e.folder}
    end
    PL.park_later(game, moves)
    -- (no quick save of the player's: the game's main menu starts the project's session by itself - MaximdeWinter 14.11.)
    require("conjunction.sessions").start_project(path, nil, {later = true})
    log("[editor] starting again in " .. path .. ", the other projects out of the game")
    PL.restart(log)
  end)
end

-- foliage / terrain / water / height of a hide area - takes effect with the next build
function E:set_area(place, index, flags)
  local o = self.project.places[place].objects[index]
  for _, k in ipairs(Y.keys(flags)) do o.envhide[k] = flags[k] end
  self.project:save_place(place)
end

-- the path tool on these points; on_done(points) with Enter
function E:draw_path(points, on_done, label, closed, min_points)
  local PT = require("conjunction.pathtool")
  if self.path_tool ~= nil then self.path_tool:cancel() end
  PT.new(self, points, on_done, {label = label or "Path", closed = closed or false, min_points = min_points or 1}):start()
end
-- F11: the game as it is on the screen, Conjunction over it -> screenshots\<project>\<project>_<date>_<time>.png
-- (TW3SE's w3.ui.screenshot: saved when the frame is shown - the shutter and the notice once it is there)
function E:screenshot()
  local folder = self:screenshot_folder()       -- (made with the project's first screenshot)
  w3.fs.mkdir(folder)
  local path = folder .. "\\" .. folder:match("([^\\/]+)$") .. os.date("_%Y-%m-%d_%H-%M-%S.png")
  local before, err = w3.ui.screenshot(path)
  if before == nil then
    self.panel:say("No screenshot: " .. tostring(err), nil, true)
    return
  end
  local until_t = self.sys.time() + 5.0
  local function taken()
    if w3.ui.screenshots_done() <= before then
      if self.sys.time() < until_t then self.sys.after(50, taken)
      else self.panel:say("No screenshot: it was not saved", nil, true) end
      return
    end
    print("[editor] screenshot " .. path)
    local shutter = PATHS.SOUNDS .. "\\shutter.wav"
    if w3.sound and w3.fs.exists(shutter) then pcall(w3.sound.play, shutter) end   -- (a soft click, as a camera does)
    self.panel:say("Screenshot saved", 4000)
  end
  self.sys.after(50, taken)
end
function E:_over_panel()
  if self.seeing_through then return false end
  local cx, cy = self.sys.cursor()
  local x, y = self.sys.client()
  return self.panel:covers(cx - (x or 0), cy - (y or 0))
end

-- placing or picking in the world: the panel and the bar let the world through (their look: the panel's)
function E:see_through()
  local busy = (self.request ~= nil or (self.mode == "place" and self.template ~= "")) and E.setting("see_through")
  if busy then
    local x, y, w, h = self.sys.client()
    local px, py = self.sys.cursor()
    busy = px >= x and px < x + w and py >= y and py < y + h
  end
  self.seeing_through = busy and true or false
end

-- the actions of the bar, its strip, its menus and keys (hud.trigger)
function E:trigger(a)
  if a:sub(1, 5) == "mode." then
    self:set_mode((self.mode == a:sub(6) and a ~= "mode.select") and "select" or a:sub(6))
  elseif a == "opt.edit_existing" then self:toggle_edit_existing()
  elseif a == "opt.collision" then self:toggle_collision()
  elseif a == "opt.snap" then self:toggle_snap()
  elseif a == "opt.grid" or a == "opt.turn" or a == "opt.align" or a == "opt.random" then self:cycle_option(a:sub(5))
  elseif a == "opt.light" then self:set_option("light", ((self.opts.light or 0) + 1) % #E.LIGHTS)
  elseif a == "opt.lamp" then self:toggle_lamp()
  elseif a == "opt.fits" then self.show_fits = not self.show_fits
  elseif a == "opt.pause" then self:toggle_pause()
  elseif a == "opt.senses" then self:toggle_senses()
  elseif a == "opt.markers" then self.markers = ({off = "quest", quest = "all"})[self.markers or "off"] or "off"
  elseif a == "opt.music" then self:toggle_music()
  elseif a == "opt.sound" then self:toggle_sound()
  elseif a == "opt.catalog_screen" then self:cycle_catalog_screen()
  elseif a == "act.panel" then self.panel:toggle_project(self)
  elseif a == "act.outliner" then self.panel:open_outliner(self)
  elseif a == "act.story" then self.panel:open_story(self)
  elseif a == "act.build_play" then self.panel:build_play_now(self)
  elseif a == "act.play" then self:play()
  elseif a == "act.player_here" then self:player_here()
  elseif a == "act.drop" then self:exec("cj_drop_selected()")
  elseif a == "act.duplicate" then self:exec("cj_duplicate()")
  elseif a == "act.delete" then self:delete_selected()
  end
  self.hud:sync()
end

-- camera input to the game, which flies it every frame; right mouse held = look (the cursor goes back each frame)
function E:fly(now, edge, c, on_bar)
  local V = VK_CODE
  local dyaw, dpitch = 0.0, 0.0
  if edge[V.RBUTTON] and not on_bar then
    self.look_from, self.look_t, self.looked = {c.x, c.y}, self.sys.perf(), false
  elseif now[V.RBUTTON] and self.look_from then
    local dx, dy = c.x - self.look_from[1], c.y - self.look_from[2]
    if dx ~= 0 or dy ~= 0 then
      self.looked = true
      dyaw, dpitch = dx * E.LOOK_DEG_PER_PX, dy * E.LOOK_DEG_PER_PX
      self.sys.set_cursor(self.look_from[1], self.look_from[2])
      c.x, c.y = self.look_from[1], self.look_from[2]
    end
  end
  local function n(v) return v and 1 or 0 end
  local mv = {n(now[V.W]) - n(now[V.S]), n(now[V.D]) - n(now[V.A]), n(now[V.SPACE]) - n(now[V.X])}
  local fast = self.fly_speed / 4.0
  local active = mv[1] ~= 0 or mv[2] ~= 0 or mv[3] ~= 0 or dyaw ~= 0 or dpitch ~= 0
  if active then
    self:exec(fmt("cj_cam(%d, %d, %d, %.4f, %.3f, %.3f)", mv[1], mv[2], mv[3], fast, dyaw, dpitch))
  elseif self.flying then
    self:exec("cj_cam(0, 0, 0, 1, 0, 0)")
    self:exec("cj_cam_sync()")
  end
  self.flying = active
  return self.flying
end

function E:select_mode(edge, up, now, mx, my, w, h, a)
  local V = VK_CODE
  -- (a pick that takes objects of the world too: the one under the mouse, before the project's own)
  if self.request and self.request.world then
    local r = self.request
    self.pick_mouse = {mx, my, w, h}
    if edge[V.RETURN] then self:take_picked() return end
    if require("conjunction.ui.pick_list").covers(mx, my) then return end   -- (its own buttons)
    if edge[V.LBUTTON] and not self.drag then
      -- (a click picks - blue, in the list at the right - and the step waits for Enter or Done: MaximdeWinter 12.11.)
      local WP = require("conjunction.world_pick")
      local c = WP.hit(self, mx, my, w, h)
      if c then
        r.picked = r.picked or {}
        local at
        for i, p in ipairs(r.picked) do if p.guid == c.guid then at = i end end
        if r.world_many and now[V.SHIFT] then              -- (Shift: one more, or out again)
          if at then table.remove(r.picked, at) else r.picked[#r.picked + 1] = c end
        elseif #r.picked >= 2 then                         -- (a selection of several: asked before it goes)
          require("conjunction.ui.dialogs").question(self, "Pick",
            string.format("Discard the %d selected %s and pick only this one?", #r.picked, WP.noun(r.world, true)),
            function(a)
              if a == "yes" and self.request == r then
                if r.test_restore then r.test_restore() r.test_restore = nil end
                r.picked = {c}
              end
            end)
        else
          if r.test_restore and not at then r.test_restore() r.test_restore = nil end
          r.picked = {c}
        end
        self.hud:sync()
        return
      end
    end
    if r.edit then return end                        -- (Select on a step: only the world's things, the list keeps the rest)
  end
  if self.drag and self.drag.axis == "free" then
    if now[V.LBUTTON] then
      local last = self.drag.last
      if not last or last[1] ~= mx or last[2] ~= my then
        self.drag.last = {mx, my}
        self:exec(fmt("cj_move_free(%s)", a))
        local guess = self:slide_guess(mx, my, w, h)
        if guess then self.selected = guess end
      end
    else
      local s = self.drag.start
      self:exec(fmt("cj_move_done(%.3f, %.3f, %.3f)", s[1], s[2], s[3]))
      self.drag = nil
    end
    return
  end
  if self.drag then
    if now[V.LBUTTON] then
      local d = self.drag
      local ax = d.axis_px
      local n2 = ax[1] * ax[1] + ax[2] * ax[2]
      if n2 > 1e-6 then
        local t = ((mx - d.mouse[1]) * ax[1] + (my - d.mouse[2]) * ax[2]) / n2
        local target = list_copy(d.start)
        target[d.axis + 1] = target[d.axis + 1] + t
        local g = NUM.float(self.opts.grid or 0)
        if g ~= 0 then target[d.axis + 1] = NUM.round(target[d.axis + 1] / g) * g end
        self.drag.sent = list_copy(target)
        local off = self.drag.off or {0.0, 0.0, 0.0}
        self.selected = {target[1] + off[1], target[2] + off[2], target[3] + off[3]}
        local flag = self:_selected_is_marker()
        self:exec(fmt("cj_move_to(%.3f, %.3f, %.3f, %s, %s)", target[1], target[2], target[3],
                      b(self.collide and not flag), b(flag or self.snap)))
      end
    else
      local s = self.drag.start
      self:exec(fmt("cj_move_done(%.3f, %.3f, %.3f)", s[1], s[2], s[3]))
      self.drag = nil
    end
    return
  end
  if edge[V.LBUTTON] then
    local axis = self:gizmo_axis_at(mx, my, w, h)
    if axis == "free" then
      self.drag = {axis = "free", start = list_copy(self.selected), last = nil}
      return
    end
    if axis ~= nil then
      local o = self.cam:project(self.selected, w, h)
      local endp = list_copy(self.selected)
      endp[axis + 1] = endp[axis + 1] + 1.0
      local e = self.cam:project(endp, w, h)
      if o and e then
        self.drag = {axis = axis, start = list_copy(self.selected), mouse = {mx, my}, axis_px = {e[1] - o[1], e[2] - o[2]}}
        return
      end
    end
    local hit = self:box_pick(mx, my, w, h)
    if hit then
      self:exec(now[V.SHIFT] and fmt("cj_group_add_at(%.3f, %.3f, %.3f)", hit[1], hit[2], hit[3]) or
                fmt("cj_select_at(%.3f, %.3f, %.3f)", hit[1], hit[2], hit[3]))
      return
    end
    self.click_px = (not now[V.SHIFT]) and {mx, my, w, h} or nil
    self:exec(now[V.SHIFT] and fmt("cj_select_add(%s)", a) or fmt("cj_select(%s)", a))
  end
end

function E:cursor_ray(mx, my, w, h) return self.cam:cursor_ray(mx, my, w, h) end
-- the terrain brush (terraintool.lua), made when Terrain is first on
function E:make_terrain_tool() return require("conjunction.terraintool").new(self) end

function E:slide_guess(mx, my, w, h)
  local start = self.drag and self.drag.start or nil
  if not start or not self.cam.ready then return nil end
  local origin, d = self:cursor_ray(mx, my, w, h)
  if d[3] > -1e-4 then return nil end
  local t = (start[3] - origin[3]) / d[3]
  if t <= 0 or t > 400 then return nil end
  local px, py = origin[1] + d[1] * t, origin[2] + d[2] * t
  local g = NUM.float(self.opts.grid or 0)
  if g ~= 0 then px, py = NUM.round(px / g) * g, NUM.round(py / g) * g end
  return {px, py, start[3]}
end

function E:hover_object(on, mx, my, w, h, moved_cam)
  if not on then
    self.hud.hover, self._hover_at = nil, nil
    return
  end
  local at = {NUM.round(mx), NUM.round(my), w, h}
  local prev = self._hover_at
  if prev and prev[1] == at[1] and prev[2] == at[2] and prev[3] == at[3] and prev[4] == at[4] and not moved_cam then return end
  self._hover_at = at
  local pos = self:box_pick(mx, my, w, h) or self:screen_pick(mx, my, w, h, 30)
  local i = pos and self.project:find_object(self.place, pos) or nil
  self.hud.hover = i and self.project.places[self.place].objects[i] or nil
end

function E:box_pick(mx, my, w, h)
  if not self.cam.ready then return nil end
  local objs = objects(self.project.places[self.place] or Y.map())
  local ts = {}
  for _, o in ipairs(objs) do ts[#ts + 1] = o.template end
  PK.prepare(ts)
  local origin, dir = self:cursor_ray(mx, my, w, h)
  return PK.pick(origin, dir, objs, QUEST.is_actor)
end

function E:screen_pick(mx, my, w, h, reach)
  reach = reach or 40
  if not self.cam.ready then return nil end
  local best
  for _, o in ipairs(objects(self.project.places[self.place] or Y.map())) do
    local x, y, z = o.pos[1], o.pos[2], o.pos[3]
    local pts = {}
    for _, dz in ipairs({0.0, 0.3, 0.6, 1.0}) do
      local p = self.cam:project({x, y, z + dz}, w, h)
      if p then pts[#pts + 1] = p end
    end
    if #pts > 0 then
      local px
      for _, p in ipairs(pts) do
        local d = ((p[1] - mx) ^ 2 + (p[2] - my) ^ 2) ^ 0.5
        if px == nil or d < px then px = d end
      end
      local sq = {}
      for i = 1, 3 do sq[i] = (o.pos[i] - self.cam.pos[i]) ^ 2 end
      local depth = NUM.sum(sq) ^ 0.5
      if px <= reach and (best == nil or px < best[1] or (px == best[1] and depth < best[2])) then
        best = {px, depth, o.pos}
      end
    end
  end
  return best and best[3] or nil
end

-- 0 / 1 / 2: an arrow of the gizmo under the cursor; "free": its middle
function E:gizmo_axis_at(mx, my, w, h)
  if not self.selected or not self.cam.ready then return nil end
  local o = self.cam:project(self.selected, w, h)
  if not o then return nil end
  if NUM.hypot(mx - o[1], my - o[2]) <= E.GIZMO_FREE_PX then return "free" end
  local best, best_d = nil, E.GIZMO_PICK_PX
  for axis = 0, 2 do
    local endp = list_copy(self.selected)
    endp[axis + 1] = endp[axis + 1] + E.GIZMO_M
    local e = self.cam:project(endp, w, h)
    if e then
      local vx, vy = e[1] - o[1], e[2] - o[2]
      local L2 = vx * vx + vy * vy
      if L2 == 0 then L2 = 1.0 end
      local t = math.max(0.0, math.min(1.0, ((mx - o[1]) * vx + (my - o[2]) * vy) / L2))
      local d = NUM.hypot(mx - (o[1] + t * vx), my - (o[2] + t * vy))
      if d < best_d then best, best_d = axis, d end
    end
  end
  return best
end

-- --- what the HUD asks (hud.py reads these of the editor) ---
E.WORLD_NAMES = {novigrad = "Velen and Novigrad", velen = "Velen and Novigrad", skellige = "Skellige",
                 kaer_morhen = "Kaer Morhen", prologue = "White Orchard", prologue_winter = "White Orchard",
                 bob = "Toussaint", toussaint = "Toussaint"}
function E:box_of(o) return PK.box_of(o, QUEST.is_actor(o)) end
-- the quest's steps whose things the overlay draws: every step with its eye open (the card being worked on: step 5)
function E:shown_steps()
  local q = self.project.meta.quest
  local out = Y.map()             -- (in the quest's order, as the dict editor.py builds)
  if not Y.is_map(q) or not Y.is_map(q.nodes) then return out end
  for nid, n in pairs(q.nodes) do
    if not (Y.is_map(n) and n.hidden and n.hidden ~= Y.null and n.hidden ~= false) then out[nid] = n end
  end
  return out
end
-- the Go to spots of the place being edited, for the overlay's rings; a spot being dragged: where it is now
function E:spot_rings()
  local q = self.project.meta.quest
  if not Y.is_map(q) then q = Y.map() end
  if Y.is_map(q.nodes) and next(q.nodes) ~= nil then q = Y.map({"nodes", self:shown_steps()}) end
  local rings = QUEST.spot_rings(q, self.project, self.place)
  local start = type(self.drag) == "table" and self.drag.start or nil
  if start and self.selected then
    for i, ring in ipairs(rings) do
      local sq = {}
      for k = 1, math.min(#ring[1], #start) do sq[k] = (ring[1][k] - start[k]) ^ 2 end
      if NUM.sum(sq) < 0.05 ^ 2 then rings[i] = {list_copy(self.selected), ring[2], ring[3]} end
    end
  end
  return rings
end
function E:save_config(key, value) CFG.set(key, value) end
-- the bar's or the panel's name field done (hud._rename_done, panel._rename_done: project.rename)
function E:rename_project(name)
  local ok, err = pcall(require("conjunction.project").rename, self.project, name)
  if not ok then print("[hud] rename: " .. tostring(err)) end   -- (the folder in use: the name changes, the folder stays)
  self.hud:sync()
end

function E:close()
  if self.editing then
    self:exec("cj_edit(false)")
    self:show_built()
  end
  self:exec("cj_sound_resume()")
end
return E
