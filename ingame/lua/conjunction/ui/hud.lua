-- The editor's bar over the game, as conjunction/hud.py lays it out and draws it (rules: ingame/spec/hud.md).
--
--   local bar = HUD.new(ed)        ed: the editor (mode, opts, project, keys ...: see FakeEditor in the lab test)
--   bar:frame(w, h)                every frame inside the overlay window: lays out, draws, takes clicks
--
-- Everything here comes from hud.py's BAR_STYLE and its layouts (sizes measured on Qt's, ingame/ref/qt/bar_*.json).
local Q = require("conjunction.ui.qt")
local L = require("conjunction.ui.layout")
local TT = require("conjunction.ui.tooltips")
local TIPS = require("conjunction.ui.tips")
local CT = require("conjunction.ui.controls")
local LE = require("conjunction.ui.lineedit")
local D = w3.ui.draw
local H = {}
H.__index = H

H.BAR_H = 32
H.LIGHTS = {"game", "morning", "midday", "evening", "night"}

local function rgba(r, g, b, a) return (r << 24) | (g << 16) | (b << 8) | (a or 255) end
local C = {
  bar = rgba(20, 20, 22, 228), bar_line = rgba(255, 255, 255, 20),
  menu = rgba(22, 22, 25),   -- the menu is an opaque window: Qt fills its background without alpha
  panel = rgba(22, 22, 25, 232), panel_edge = rgba(0x45, 0x45, 0x4c),
  btn = rgba(0xd4, 0xd4, 0xd6), btn_hover_edge = rgba(0x6a, 0x6a, 0x70), btn_checked = rgba(255, 255, 255, 24),
  disabled = rgba(0x6a, 0x6a, 0x70), white = rgba(255, 255, 255),
  menubtn = rgba(0xc8, 0xc8, 0xcc), menubtn_open = rgba(0x3a, 0x3a, 0x40),
  mode_bg = rgba(255, 255, 255, 8), mode_edge = rgba(255, 255, 255, 22), mode_on = rgba(0x4b, 0x4b, 0x50),
  mode_on_edge = rgba(0xc8, 0xc8, 0xc8), label = rgba(0xbb, 0xbb, 0xbb), key = rgba(0x8a, 0x8a, 0x90),
  play = rgba(0x3c, 0x6e, 0x3f), play_edge = rgba(0x58, 0xa3, 0x5c), play_hover = rgba(0x46, 0x7f, 0x49),
  play_split = rgba(0x2c, 0x52, 0x2e), play_open = rgba(0x2f, 0x58, 0x32),
  project = rgba(0xec, 0xec, 0xee), world = rgba(0x8c, 0x8c, 0x90), sep = rgba(0x4a, 0x4a, 0x50),
  entry = rgba(0xdc, 0xdc, 0xde), entry_hover = rgba(0x3a, 0x3a, 0x40), shortcut = rgba(0x8a, 0x8a, 0x90),
  group = rgba(0x8c, 0x8c, 0x90), line = rgba(0x45, 0x45, 0x4c),
  doing = rgba(0xf0, 0xe2, 0xbd), keycap = rgba(0xdd, 0xdd, 0xdd), keycap_bg = rgba(40, 40, 44, 225),
  keycap_edge = rgba(0x5a, 0x5a, 0x60), busy = rgba(24, 24, 27, 215), busykey_bg = rgba(60, 60, 66, 235),
  busykey_edge = rgba(0x7a, 0x7a, 0x80), busykey = rgba(0xee, 0xee, 0xee), head = rgba(0xee, 0xee, 0xee),
}
H.C = C
-- the bar's QLineEdit (BAR_STYLE: #1b1b1e, edge #5a5a60 focused too, #eee, padding 2 4, 12 px; the selection the
-- palette's, theme.py's #4b4b50 with white)
local BAR_EDIT = {bg = rgba(0x1b, 0x1b, 0x1e), edge = rgba(0x5a, 0x5a, 0x60), edge_focus = rgba(0x5a, 0x5a, 0x60),
                  fg = rgba(0xee, 0xee, 0xee), px = 12, pad = {4, 2, 4, 2}, sel_bg = rgba(0x4b, 0x4b, 0x50),
                  sel_fg = rgba(255, 255, 255)}
local MODE_ICONS = {["mode.look"] = "eye", ["mode.select"] = "mouse-pointer-2", ["mode.place"] = "package-plus",
                    ["mode.terrain"] = "mountain"}
local MODES = {"mode.look", "mode.select", "mode.place", "mode.terrain"}
local BASE = {"opt.lamp", "opt.light", "opt.speed", "opt.pause", false}
local STRIP = {
  select = {"opt.lamp", "opt.light", "opt.speed", "opt.pause", false, "opt.grid", "opt.collision", "opt.snap", "opt.edit_existing",
            false, "act.drop", "act.duplicate", "act.delete"},
  place = {"opt.lamp", "opt.light", "opt.speed", "opt.pause", false, "opt.grid", "opt.turn", "opt.align", "opt.random", "opt.collision"},
  look = {"opt.lamp", "opt.light", "opt.speed", "opt.pause", false, "act.player_here"},
  -- (a pick that takes objects of the world: what fits, marked)
  world = {"opt.lamp", "opt.light", "opt.speed", "opt.pause", false, "opt.fits"},
}
local KIND = {["opt.edit_existing"] = "toggle", ["opt.collision"] = "toggle", ["opt.snap"] = "toggle",
              ["opt.grid"] = "cycle", ["opt.turn"] = "cycle", ["opt.align"] = "toggle", ["opt.random"] = "toggle",
              ["opt.light"] = "choice", ["opt.lamp"] = "toggle", ["opt.pause"] = "toggle", ["opt.senses"] = "toggle", ["opt.markers"] = "cycle",
              ["opt.speed"] = "hold", ["opt.music"] = "toggle", ["opt.sound"] = "toggle", ["opt.catalog_screen"] = "cycle",
              ["act.outliner"] = "button", ["act.story"] = "button", ["act.panel"] = "button", ["act.play"] = "button",
              ["act.build_play"] = "button", ["act.player_here"] = "button", ["act.drop"] = "button",
              ["act.duplicate"] = "button", ["act.delete"] = "button", ["opt.fits"] = "toggle"}
H.KIND = KIND
-- hud.ACTIONS' order (the shortcuts panel lists them so)
H.ACTIONS = {"mode.look", "mode.select", "mode.place", "mode.terrain", "opt.edit_existing", "opt.collision", "opt.snap",
             "opt.grid", "opt.turn", "opt.align", "opt.random", "opt.light", "opt.lamp", "opt.senses", "opt.markers",
             "opt.speed", "opt.pause", "opt.music", "opt.sound", "opt.catalog_screen", "act.outliner", "act.story", "act.panel",
             "act.play", "act.build_play", "act.player_here", "act.drop", "act.duplicate", "act.delete"}
-- keys the editor uses itself (flying, looking, editing): not for actions (hud.RESERVED)
H.RESERVED = {W = true, A = true, S = true, D = true, SPACE = true, CTRL = true, SHIFT = true, ALT = true, TAB = true,
              DELETE = true, END = true, F8 = true, ESC = true}

local function fmt_g(v)   -- Python's :g for the few values here
  if v == math.floor(v) then return string.format("%d", v) end
  return (string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", ""))
end
local function speed_text(v)
  if v < 1 then return string.format("%.2f m/s", v) end
  return v < 10 and string.format("%.1f m/s", v) or string.format("%.0f m/s", v)
end

-- what an action says (hud.label)
function H.label(ed, a)
  local o = ed.opts
  if a == "opt.fits" and ed.request and ed.request.world then   -- (named by what the pick is for, 12.11.)
    return "Highlight " .. require("conjunction.world_pick").noun(ed.request.world, true)
  end
  local texts = {["mode.look"] = "Look", ["mode.select"] = "Select", ["mode.place"] = "Asset Browser",
                 ["mode.terrain"] = "Terrain", ["opt.edit_existing"] = "Edit Vanilla Objects", ["opt.collision"] = "Collision",
                 ["opt.snap"] = "Snap to ground", ["opt.align"] = "Align", ["opt.random"] = "Random turn", ["opt.lamp"] = "Lamp", ["opt.pause"] = "Pause",
                 ["opt.senses"] = "Senses", ["opt.music"] = "Music", ["opt.sound"] = "Sound", ["act.panel"] = "Project",
                 ["act.outliner"] = "Outliner", ["act.story"] = "Story", ["act.build_play"] = "Build & Play",
                 ["act.play"] = "Play", ["act.player_here"] = "Player here", ["act.drop"] = "Drop",
                 ["opt.fits"] = "Show what fits (30 m)",
                 ["act.duplicate"] = "Duplicate", ["act.delete"] = "Delete"}
  if texts[a] then return texts[a] end
  if a == "opt.grid" then return (o.grid ~= 0) and ("Grid " .. fmt_g(o.grid) .. " m") or "Grid off" end
  if a == "opt.turn" then return "Turn " .. fmt_g(o.turn) .. "\u{b0}" end
  if a == "opt.light" then return "Light: " .. H.LIGHTS[math.min((o.light or 0) + 1, #H.LIGHTS)] end
  if a == "opt.markers" then
    return ({quest = "Markers: quest", all = "Markers: all"})[ed.markers or "off"] or "Markers: off"
  end
  if a == "opt.speed" then return "Fly " .. speed_text(ed.fly_speed) end
  if a == "opt.catalog_screen" then
    return ed.catalog_screen == "second" and "Asset Browser on the second screen" or "Asset Browser over the game"
  end
  return ""
end

function H.checked(ed, a)
  if a:sub(1, 5) == "mode." then return ed.mode == a:sub(6) end
  local v = ({["opt.edit_existing"] = ed.edit_existing, ["opt.collision"] = ed.collide, ["opt.snap"] = ed.snap,
              ["opt.align"] = ed.opts.align, ["opt.random"] = ed.opts.random, ["opt.lamp"] = ed.lamp, ["opt.pause"] = ed.paused,
              ["opt.senses"] = ed.senses == true, ["opt.music"] = not ed.music_off, ["opt.sound"] = not ed.sound_off,
              ["act.panel"] = ed.panel_open and ed:panel_open(), ["opt.catalog_screen"] = ed.catalog_screen == "second",
              ["opt.fits"] = ed.show_fits == true})[a]
  return v and true or false
end

-- the keys by default (hud.ACTIONS) and the player's own (the config's "hotkeys")
H.DEFAULT_KEYS = {["mode.look"] = "1", ["mode.select"] = "2", ["mode.place"] = "3", ["mode.terrain"] = "4",
                  ["opt.lamp"] = "H", ["opt.senses"] = "V", ["opt.markers"] = "M", ["opt.speed"] = "F", ["opt.pause"] = "P", ["act.panel"] = "Q"}
-- hud.Hud.__init__: the defaults, the player's over them; a default key another action of the player has is not the
-- default action's any more
-- (in hud.ACTIONS' order, as Python's dict(DEFAULT_KEYS, **hotkeys) has them: the defaults, then the player's others)
H.DEFAULT_ORDER = {"mode.look", "mode.select", "mode.place", "mode.terrain", "opt.lamp", "opt.senses", "opt.markers",
                   "opt.speed", "opt.pause", "act.panel"}
function H.keys_of(hotkeys)
  local Y = require("conjunction.yaml")
  hotkeys = hotkeys or {}
  local keys = Y.map()
  for _, a in ipairs(H.DEFAULT_ORDER) do keys[a] = H.DEFAULT_KEYS[a] end
  local hk = Y.is_map(hotkeys) and hotkeys or (function()
    local m, ks = Y.map(), {}
    for k in pairs(hotkeys) do ks[#ks + 1] = k end
    require("conjunction.pysort").sort(ks)
    for _, k in ipairs(ks) do m[k] = hotkeys[k] end
    return m
  end)()
  for a, k in pairs(hk) do keys[a] = k end
  for _, a in ipairs(H.DEFAULT_ORDER) do
    local k = H.DEFAULT_KEYS[a]
    if hk[a] == nil then
      local n = 0
      for _, v in pairs(keys) do if v == k then n = n + 1 end end
      if n > 1 then keys[a] = "" end
    end
  end
  return keys
end
-- the actions in the order the keys are looked at (editor.py: for a, name in self.hud.keys.items())
function H:key_order() return require("conjunction.yaml").keys(self.keys) end

function H.new(ed)
  local self = setmetatable({ed = ed, menu_open = nil, keys = H.keys_of(ed.hotkeys or ed.keys), hover = nil}, H)
  return self
end

-- --- sizes (BAR_STYLE's box model) ---
local function btn_size(text, pad, bold) return Q.hint_w(text, 12, bold) + 2 * pad + 2, 24 end
-- a mode button: its labels' row (10 in, 6 between) and 16 more (hud._mode_button)
local function mode_parts(self, a)
  local text = H.label(self.ed, a)
  local key = self.keys[a] or ""
  local items = {{hint = 14}, {hint = Q.hint_w(text, 12)}, {hint = key ~= "" and Q.hint_w(key, 11) or 0, empty = key == ""}}
  return items, text, key
end
-- hud._mode_button sets the minimum width before Qt applies the style sheet: the key label still has the default
-- font then (12 px, not its 11 px), so "C" counts one pixel more (Asset Browser 143, not 142)
local function mode_size(self, a)
  local items, text, key = mode_parts(self, a)
  if key ~= "" then items[3] = {hint = Q.hint_w(key, 12)} end
  return L.row_hint(items, {margins = {10, 2, 10, 2}, spacing = 6}) + 16, 24
end
-- QLabel{padding:0 6px} with its frame: + the advance of 'x'
local function label_size(text, pad_l, pad_r, px, bold)
  return Q.hint_w(text, px or 12, bold) + pad_l + pad_r + Q.label_indent(px or 12, bold), Q.line_h(px or 12, bold)
end

-- --- drawing ---
-- Qt paints a style sheet border side by side: a corner pixel gets two of them (seen when the edge is translucent)
local function frame(x, y, w, h, bg, edge)
  if bg then D.fill(x, y, w, h, bg) end
  if edge and (edge & 0xff) < 255 then
    D.fill(x, y, w, 1, edge)
    D.fill(x, y + h - 1, w, 1, edge)
    D.fill(x, y, 1, h, edge)
    D.fill(x + w - 1, y, 1, h, edge)
  elseif edge then
    D.rect(x, y, w, h, edge, 1)
  end
end
-- a QPushButton's text centred in its box (padding pad, 1 px border)
local function btn_text(x, y, w, h, text, pad, colour, bold, bg)
  local tw = Q.text_w(text, 12, bold)
  Q.text(x + 1 + pad + (w - 2 - 2 * pad - tw) // 2, y + 4 + (h - 8 - Q.line_h(12)) // 2, colour, text, 12, bold, bg)
end

-- a hit box for this frame: -> clicked, hovered
-- (tip: the tooltip's id in TIPS when it is not the hit's own)
function H:hit(id, r, tip)
  if self.drawing_under and self.covered then        -- (the bar under the panel's windows: none of the mouse there)
    local mx, my = w3.ui.mouse()
    if self.covered(mx, my) then return false, false, false end
  end
  w3.ui.set_pos(r.x, r.y)
  local clicked, hovered, held = w3.ui.hit("hud." .. id, r.w, r.h)
  tip = tip or id
  if hovered and TIPS[tip] then TT.hover("hud." .. id, "", TIPS[tip]) end
  return clicked == 1, hovered, held
end

-- --- the bar ---
function H:layout_bar(W)
  local ed = self.ed
  local items, what = {}, {}
  local function add(it, name) items[#items + 1] = it; what[#items] = name end
  add({hint = 30}, "logo")
  for _, n in ipairs({"File", "Edit", "View", "Build", "Help"}) do
    local w = btn_size(n, 8)
    add({hint = w, cross_max = 24}, "menu:" .. n)
  end
  add({hint = 0, stretch = 1, expanding = true, empty = true}, "stretch")
  local gw = 0
  self.modes = {}
  for _, a in ipairs(MODES) do
    if a ~= "mode.terrain" or ed.experimental then
      local w = mode_size(self, a)
      self.modes[#self.modes + 1] = {a = a, w = w}
      gw = gw + w
    end
  end
  add({hint = gw}, "modes")
  add({hint = 0, stretch = 1, expanding = true, empty = true}, "stretch")
  add({hint = (btn_size("Project", 9)), cross_max = 24}, "act.panel")
  add({hint = 8, spacer = true, fixed = true, empty = true}, "space")
  local pname = ((ed.project.meta and ed.project.meta.name) or ed.project:id() or "") .. "  \u{25be}"
  self.project_text = pname
  if self.renaming then   -- the name's button gives its place to a 200 px field (hud._rename_start)
    add({hint = 200, cross_max = CT.edit_h(BAR_EDIT)}, "project")
  else
    add({hint = (btn_size(pname, 9, true)), cross_max = 24}, "project")
  end
  local wt = table.concat((function()
    local t = {}
    if ed.place and ed.place ~= "" then t[#t + 1] = ed.place end
    if ed.world_name then t[#t + 1] = ed.world_name end
    return t
  end)(), "  \u{b7}  ")
  self.world_text = wt
  add({hint = (label_size(wt, 2, 8)), empty = wt == ""}, "world")
  local kind = ed.play_kind or "play"
  self.play_text = H.label(ed, "act." .. kind)
  local pw = 10 + 15 + 6 + Q.hint_w(self.play_text, 12, true) + 12
  add({hint = pw + 18}, "play")
  local placed = L.row(items, 0, 0, W, H.BAR_H - 1, {margins = {8, 2, 8, 2}, spacing = 2})
  local out = {}
  for i, r in ipairs(placed) do out[what[i]] = out[what[i]] or r end
  out.menus = {}
  for i, r in ipairs(placed) do if what[i]:sub(1, 5) == "menu:" then out.menus[what[i]:sub(6)] = r end end
  out.play_w = pw
  return out
end

function H:draw_bar(W)
  local ed = self.ed
  local lay = self:layout_bar(W)
  self.bar_rects = lay
  D.fill(0, 0, W, H.BAR_H, C.bar)              -- the background under the border too (Qt's box)
  D.fill(0, H.BAR_H - 1, W, 1, C.bar_line)
  -- the logo
  local lg = lay.logo
  Q.draw_icon_file("logo_18", lg.x + 6, lg.y + (lg.h - 18) // 2)
  -- the menus
  for name, r in pairs(lay.menus) do
    local open = self.menu_open == name
    local clicked, hovered = self:hit("menu." .. name:lower(), r)
    if open then frame(r.x, r.y, r.w, r.h, C.menubtn_open, C.menubtn_open)
    elseif hovered then frame(r.x, r.y, r.w, r.h, nil, C.btn_hover_edge) end
    btn_text(r.x, r.y, r.w, r.h, name, 8, C.menubtn, false, open and C.menubtn_open or C.bar)   -- #menubtn wins over :checked
    if clicked then self:toggle_menu(name) end
  end
  -- the modes
  local m = lay.modes
  local x = m.x
  for _, md in ipairs(self.modes) do
    local r = {x = x, y = m.y + (m.h - 24) // 2, w = md.w, h = 24}
    local on = H.checked(ed, md.a)
    local clicked, hovered = self:hit(md.a, r)
    if on then frame(r.x, r.y, r.w, r.h, C.mode_on, C.mode_on_edge)
    else frame(r.x, r.y, r.w, r.h, C.mode_bg, hovered and C.btn_hover_edge or C.mode_edge) end
    local items, text, key = mode_parts(self, md.a)
    local parts = L.row(items, r.x, r.y, r.w, r.h, {margins = {10, 2, 10, 2}, spacing = 6})
    local bg = on and C.mode_on or C.bar
    Q.draw_icon(MODE_ICONS[md.a] or "square", 0xddddddff, 14, parts[1].x, parts[1].y + (parts[1].h - 14) // 2)
    Q.text(parts[2].x, parts[2].y + Q.vcenter(parts[2].h, Q.line_h(12)), C.label, text, 12, false, bg)
    if key ~= "" then Q.text(parts[3].x, parts[3].y + Q.vcenter(parts[3].h, Q.line_h(11)), C.key, key, 11, false, bg) end
    if clicked then self:trigger(md.a) end
    x = x + md.w
  end
  -- Project, the project's name, the world
  local pr = lay["act.panel"]
  do
    local clicked, hovered = self:hit("act.panel", pr)
    local open = self.menu_open == "Project"
    if open then frame(pr.x, pr.y, pr.w, pr.h, C.btn_checked, nil) end
    if hovered then frame(pr.x, pr.y, pr.w, pr.h, nil, C.btn_hover_edge) end
    btn_text(pr.x, pr.y, pr.w, pr.h, "Project", 9, open and C.white or C.btn, false, C.bar)
    if clicked then self:toggle_menu("Project") end
  end
  local pn = lay.project
  if self.renaming then
    local _, text, enter = CT.edit("hud.rename", pn.x, pn.y, pn.w, self.rename_text,
                                   {style = BAR_EDIT, tip = "pan.project_name"})
    self.rename_text = text
    local mx, my = w3.ui.mouse()
    local beside = (w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(2)) and
                   not (mx >= pn.x and my >= pn.y and mx < pn.x + pn.w and my < pn.y + pn.h)
    if enter or beside or CT.focus ~= "hud.rename" then self:rename_done() end
  else
    local clicked, hovered = self:hit("bar.project", pn)
    local open = self.menu_open == "project"
    if open then frame(pn.x, pn.y, pn.w, pn.h, C.btn_checked, nil) end
    if hovered then frame(pn.x, pn.y, pn.w, pn.h, nil, C.btn_hover_edge) end
    btn_text(pn.x, pn.y, pn.w, pn.h, self.project_text, 9, open and C.white or C.project, true, C.bar)
    if clicked then self:toggle_menu("project") end
  end
  local wr = lay.world
  if self.world_text ~= "" then
    local ind = Q.label_indent(12) // 2
    Q.text(wr.x + 2 + ind, wr.y + Q.vcenter(wr.h, Q.line_h(12)), C.world, self.world_text, 12, false, C.bar)
  end
  -- Play: the green split button
  local pl = lay.play
  local py = pl.y + (pl.h - 24) // 2
  local main = {x = pl.x, y = py, w = lay.play_w, h = 24}
  local drop = {x = pl.x + lay.play_w, y = py, w = 18, h = 24}
  local kind = ed.play_kind or "play"
  do
    local clicked, hovered = self:hit("act." .. kind, main)
    D.fill(main.x, main.y, main.w, main.h, hovered and C.play_hover or C.play)
    D.fill(main.x, main.y, main.w, 1, C.play_edge)
    D.fill(main.x, main.y + main.h - 1, main.w, 1, C.play_edge)
    D.fill(main.x, main.y, 1, main.h, C.play_edge)
    local bg = hovered and C.play_hover or C.play
    -- icon and text as labels in a row (10 in, 6 between): the layout gives them the button's extra width
    local parts = L.row({{hint = 15}, {hint = Q.hint_w(self.play_text, 12, true)}}, main.x, main.y, main.w, main.h,
                        {margins = {10, 2, 10, 2}, spacing = 6})
    Q.draw_icon(kind == "build_play" and "wrench" or "play", 0xffffffff, 15, parts[1].x, parts[1].y + Q.vcenter(parts[1].h, 15))
    Q.text(parts[2].x, parts[2].y + Q.vcenter(parts[2].h, Q.line_h(12)), C.white, self.play_text, 12, true, bg)
    if clicked then self:trigger("act." .. kind) end
  end
  do
    local clicked, hovered = self:hit("bar.play_menu", drop)
    local open = self.menu_open == "play"
    local bg = open and C.play_open or C.play
    D.fill(drop.x, drop.y, drop.w, drop.h, bg)
    D.rect(drop.x, drop.y, drop.w, drop.h, C.play_edge, 1)
    D.fill(drop.x, drop.y + 1, 1, drop.h - 1, C.play_split)   -- (the top corner is the top's colour, the bottom one the left's)
    btn_text(drop.x, drop.y, drop.w, drop.h, "\u{25be}", 5, C.white, false, bg)
    if clicked then self:toggle_menu("play") end
  end
end

-- --- the strip ---
function H:draw_strip(W)
  local ed = self.ed
  local list = (ed.request and ed.request.world and ed.mode == "select") and STRIP.world or STRIP[ed.mode]
  self.strip_rect = nil
  if not list then return end
  local items, what = {}, {}
  for _, a in ipairs(list) do
    if a == false then
      items[#items + 1] = {hint = (label_size("|", 1, 1)), cross_max = 24}
      what[#items] = false
    elseif a ~= "opt.edit_existing" or ed.experimental then
      items[#items + 1] = {hint = (btn_size(H.label(ed, a), 9)), cross_max = 24}
      what[#items] = a
    end
  end
  local sw = L.row_hint(items, {margins = {4, 2, 4, 2}, spacing = 1}) + 2
  local ins = ed.insets or {left = 0, right = 0, top = 0}
  local free_l, free_r = ins.left, W - ins.right
  local sx = math.max(free_l, free_l + (free_r - free_l - sw) // 2)
  local sy = H.BAR_H + ins.top + 6
  local sh = 30
  self.strip_rect = {x = sx, y = sy, w = sw, h = sh}
  frame(sx, sy, sw, sh, C.panel, C.panel_edge)
  local placed = L.row(items, sx + 1, sy + 1, sw - 2, sh - 2, {margins = {4, 2, 4, 2}, spacing = 1})
  for i, r in ipairs(placed) do
    local a = what[i]
    if a == false then
      Q.text(r.x + 1 + Q.label_indent(12) // 2, r.y + Q.vcenter(r.h, Q.line_h(12)), C.sep, "|", 12, false, C.panel)
    else
      local on = H.checked(ed, a) or (a == "opt.light" and self.menu_open == "light")
      local disabled = (a == "act.drop" or a == "act.duplicate" or a == "act.delete") and not ed.selected
      local clicked, hovered = self:hit(a, r)
      if disabled then clicked, hovered = false, false end
      if on then D.fill(r.x, r.y, r.w, r.h, C.btn_checked) end
      if hovered then D.rect(r.x, r.y, r.w, r.h, C.btn_hover_edge, 1) end
      btn_text(r.x, r.y, r.w, r.h, H.label(ed, a), 9, disabled and C.disabled or (on and C.white or C.btn), false, C.panel)
      if clicked then if a == "opt.light" then self:toggle_menu("light", r) else self:trigger(a) end end
    end
  end
end

-- --- the menus (hud._menu_entries, toggle_menu, _show_menu) ---
-- an entry: {text, run = fn, short = "Q", on = true/false/nil, enabled = bool} | "-" | {group = "Light"}
local function call(ed, name, ...)
  local f = ed[name]
  if type(f) == "function" then return f(ed, ...) end
end
function H:menu_entries(name)
  local e, k = self.ed, function(a) return self.keys[a] or "" end
  local sel = e.selected ~= nil
  local function act(a) return function() self:trigger(a) end end
  if name == "File" then
    local export = (e.project.meta and e.project.meta.kind == "place") and "Export place mod ..." or "Export quest file ..."
    return {{text = "New project", run = function() call(e, "new_project") end},
            {text = "Open project ...", run = function() call(e, "open_projects") end},
            {text = "Rename project", run = function() self:rename_start() end}, "-",
            {text = export, run = function() e.panel:export() end},
            {text = "Open screenshots folder", run = function() call(e, "open_screenshots") end},
            {text = "Library ...", run = function() call(e, "open_library") end},
            {text = "Settings ...", run = function() call(e, "open_settings") end},
            {text = "History ...", run = function() call(e, "open_history") end}, "-",
            {text = "Game menu ...", run = function() call(e, "open_game_menu") end},
            {text = "Quit Conjunction", run = function() call(e, "quit") end}}
  elseif name == "Edit" then
    local out = {{text = "Undo", run = function() call(e, "undo_last") end, short = "Ctrl+Z"}, "-",
                 {text = "Copy", run = function() call(e, "copy_selection") end, short = "Ctrl+C", enabled = sel},
                 {text = "Duplicate", run = act("act.duplicate"), short = "Ctrl+D", enabled = sel},
                 {text = "Delete", run = act("act.delete"), short = "Del", enabled = sel},
                 {text = "Drop to ground", run = act("act.drop"), short = "End", enabled = sel}, "-"}
    if e.experimental then
      out[#out + 1] = {text = "Edit Vanilla Objects", run = act("opt.edit_existing"), short = k("opt.edit_existing"),
                       on = H.checked(e, "opt.edit_existing")}
    end
    out[#out + 1] = {text = "Player here", run = act("act.player_here"), short = k("act.player_here")}
    out[#out + 1] = "-"
    out[#out + 1] = {text = "Keyboard shortcuts ...", run = function() self:toggle_settings() end}
    return out
  elseif name == "View" then
    local out = {{text = "Outliner", run = act("act.outliner"), short = k("act.outliner")},
                 {text = "Project", run = act("act.panel"), short = k("act.panel"), on = H.checked(e, "act.panel")},
                 {text = "Story map", run = act("act.story"), short = k("act.story")}}
    if require("conjunction.features").scenes() then
      out[#out + 1] = {text = "Scene workshop", run = function() e.panel:open_scenes(e) end}
    end
    out[#out + 1] = "-"
    for _, a in ipairs({"opt.markers", "opt.senses", "opt.lamp", "opt.pause", "opt.music", "opt.sound", "opt.catalog_screen"}) do
      local c = nil
      if KIND[a] == "toggle" or a == "opt.catalog_screen" then c = H.checked(e, a) end
      out[#out + 1] = {text = H.label(e, a), run = act(a), short = k(a), on = c}
    end
    out[#out + 1] = {group = "Light"}
    local light = math.min(e.opts.light or 0, #H.LIGHTS - 1)
    for i, n in ipairs(H.LIGHTS) do
      out[#out + 1] = {text = n:sub(1, 1):upper() .. n:sub(2), run = function() call(e, "set_option", "light", i - 1) end,
                       on = (i - 1) == light}
    end
    return out
  elseif name == "Build" then
    local export = (e.project.meta and e.project.meta.kind == "place") and "Export place mod ..." or "Export quest file ..."
    return {{text = "Build & Play", run = act("act.build_play"), short = k("act.build_play")},
            {text = "Check", run = function() call(e, "check") end},
            {text = export, run = function() e.panel:export() end}, "-",
            {text = "Build mesh library", run = function() call(e, "build_meshlib") end},
            {text = "Build foliage library", run = function() call(e, "build_foliagelib") end},
            {text = "Content pack ...", run = function() call(e, "pack_maker") end}, "-",
            {text = "Build output", run = function() call(e, "show_build_tab") end}}
  elseif name == "Help" then
    return {{text = "Keyboard shortcuts ...", run = function() self:toggle_settings() end},
            {text = "Report a bug ...", run = function() call(e, "open_bug_report") end}, "-",
            {group = "Conjunction " .. require("conjunction.provenance").VERSION}}
  elseif name == "play" then
    return {{text = "Play", run = function() self:set_play_kind("play") end, short = k("act.play"), on = (e.play_kind or "play") == "play"},
            {text = "Build & Play", run = function() self:set_play_kind("build_play") end, short = k("act.build_play"),
             on = e.play_kind == "build_play"}}
  elseif name == "project" then
    return {{text = "Rename", run = function() self:rename_start() end},
            {text = "New project", run = function() call(e, "new_project") end},
            {text = "Open project ...", run = function() call(e, "open_projects") end}}
  elseif name == "Project" then
    -- (the panel's tabs; a place mod has no Quest tab)
    local p = e.panel
    local shown = p.shown and p.tab ~= 0
    local out = {}
    for i, t in ipairs(p.TABS) do
      if i ~= 3 or p:has_quest() then
        out[#out + 1] = {text = t, run = function() call(e, "open_panel_tab", i - 1) end, on = shown and p.tab == i - 1}
      end
    end
    if shown then
      out[#out + 1] = "-"
      out[#out + 1] = {text = "Close", run = function() call(e, "toggle_panel") end, short = k("act.panel")}
    end
    return out
  elseif name == "light" then
    local out = {}
    local light = math.min(e.opts.light or 0, #H.LIGHTS - 1)
    for i, n in ipairs(H.LIGHTS) do
      out[#out + 1] = {text = n:sub(1, 1):upper() .. n:sub(2), run = function() call(e, "set_option", "light", i - 1) end,
                       on = (i - 1) == light}
    end
    return out
  end
  return {}
end

-- an entry's look: "✓  " or five spaces before the text (none when it has no state: also five spaces)
local function entry_text(en)
  return (en.on and "\u{2713}  " or "     ") .. en.text
end
local ENTRY_H, LINE_H, GROUP_H = 26, 7, 23
-- the menu's rows: -> list of {kind, h, w (its width hint), entry}, the content width
function H:menu_rows(name)
  local rows, width = {}, 0
  local play = name == "play"
  for _, en in ipairs(self:menu_entries(name)) do
    if en == "-" then
      rows[#rows + 1] = {kind = "line", h = LINE_H, w = 0}
    elseif en.group then
      local gw = Q.hint_w(en.group, 11, true) + 20 + Q.label_indent(11, true)
      rows[#rows + 1] = {kind = "group", h = GROUP_H, w = gw, text = en.group}
      width = math.max(width, gw)
    else
      local t = entry_text(en)
      local w
      if play then
        w = Q.hint_w(t, 12, true) + 28                      -- #entryplay: padding 5 14, no border
      else
        w = math.max(190, Q.hint_w(t, 12)) + 28 + 2         -- #entry: padding 4 18 4 10, min-width 190, 1 px border
        if en.short and en.short ~= "" then                 -- the shortcut beside it: setMinimumWidth(hint + label + 24)
          local sw = Q.hint_w(en.short, 12) + 10 + Q.label_indent(12)
          w = math.max(w, Q.hint_w(t, 12) + 28 + 2 + sw + 24)
          en.short_w = sw
        end
      end
      rows[#rows + 1] = {kind = "entry", h = ENTRY_H, w = w, entry = en, text = t}
      width = math.max(width, w)
    end
  end
  return rows, width
end

function H:menu_rect(name, rows, width)
  local h = 1 + 3 + 3 + 1
  for _, r in ipairs(rows) do h = h + r.h end
  local w = width + 4
  local W = self.W or 1600
  local x
  if name == "light" and self.menu_anchor then
    x = self.menu_anchor.x
    return {x = math.max(0, x), y = self.strip_rect.y + self.strip_rect.h, w = w, h = h}
  end
  local src
  if name == "project" then src = self.bar_rects.project
  elseif name == "play" then
    local pl = self.bar_rects.play
    src = {x = pl.x + self.bar_rects.play_w, w = 18}
  elseif name == "Project" then src = self.bar_rects["act.panel"]
  else src = self.bar_rects.menus[name] end
  local left, right = src.x, src.x + src.w
  if name == "play" then left = self.bar_rects.play.x end
  x = (left + w <= W - 4) and left or (right - w)
  return {x = math.max(0, x), y = H.BAR_H, w = w, h = h}
end

function H:draw_menu()
  local name = self.menu_open
  if not name then return end
  local rows, width = self:menu_rows(name)
  local r = self:menu_rect(name, rows, width)
  self.menu_rect_now = r
  local play = name == "play"
  D.layer("front", function()
    D.fill(r.x, r.y, r.w, r.h, C.menu)
    D.rect(r.x, r.y, r.w, r.h, C.panel_edge, 1)
    local y = r.y + 1 + 3
    local ex, ew = r.x + 2, r.w - 4
    for i, row in ipairs(rows) do
      if row.kind == "line" then
        D.fill(ex, y + 3, ew, 1, C.line)
      elseif row.kind == "group" then
        Q.text(ex + 10 + Q.label_indent(11, true) // 2, y + 6, C.group, row.text, 11, true, C.menu)
      else
        local en = row.entry
        local box = {x = ex, y = y, w = ew, h = ENTRY_H}
        local enabled = en.enabled ~= false
        local clicked, hovered = self:hit("menu." .. name .. "." .. i, box)
        if not enabled then clicked, hovered = false, false end
        if play then
          local bg = hovered and C.play_hover or C.play
          D.fill(box.x, box.y, box.w, box.h, bg)
          Q.text(box.x + 14, box.y + (ENTRY_H - Q.line_h(12)) // 2, C.white, row.text, 12, true, bg)
        else
          local bg = C.menu
          if hovered then bg = C.entry_hover D.fill(box.x, box.y, box.w, box.h, bg) end
          local fg = not enabled and C.disabled or C.entry
          Q.text(box.x + 1 + 10, box.y + 1 + 4, fg, row.text, 12, false, bg)
          if en.short and en.short ~= "" then
            local sx = box.x + box.w - en.short_w
            Q.text(sx + Q.label_indent(12) // 2, box.y + (ENTRY_H - Q.line_h(12)) // 2, C.shortcut, en.short, 12, false, bg)
          end
        end
        if clicked then
          self.menu_open = nil                 -- the menu closes, then the entry runs
          if en.run then en.run() end
        end
      end
      y = y + row.h
    end
  end)
end

-- --- the hints (hud._sync_hints): what a click does now and its keys ---
-- normal: bottom left, 14 in and 12 up, no frame: the text (#doing bold 12, 6 px after it) and key caps (bold 11,
-- padding 0 5, a 1 px edge), 5 px between; busy (something Esc ends, a path): framed, large, the middle, 60 px up
function H:draw_hints(W, Hh)
  local ed = self.ed
  if not ed.doing then return end
  local doing, keys, big = ed:doing()              -- (big: framed in the middle without a key cap - placing)
  keys = keys or {}
  if not doing or doing == "" or not ed.editing then return end
  local busy = big == true
  for _, k in ipairs(keys) do if k == "Esc" or k == "Enter" then busy = true end end
  busy = busy or ed.path_tool ~= nil
  -- (the bar starts with nothing going on: Qt keeps each label's padding and frame from that first style - the
  -- big hint's #busydoing / #busykey / #busy borders and paddings are drawn, but sized and placed by #doing's
  -- padding 0 6 0 0, #keycap's 1 px border and 0 5px padding and #busy's frame as none)
  local items = {}
  local dpx, kpx = busy and 22 or 12, busy and 17 or 11
  items[1] = {hint = Q.hint_w(doing, dpx, true) + 6 + Q.label_indent(dpx, true)}
  for _, k in ipairs(keys) do
    items[#items + 1] = {hint = Q.hint_w(k, kpx, true) + 10 + 2 + Q.label_indent(kpx, true)}
  end
  local m = busy and {18, 10, 18, 10} or {0, 0, 0, 0}
  local lh = Q.line_h(dpx, true)
  local kh = Q.line_h(kpx, true) + 2
  local ch = #keys > 0 and math.max(lh, kh) or lh
  local w = L.row_hint(items, {margins = m, spacing = 5})
  local h = ch + m[2] + m[4]
  local ins = ed.insets or {left = 0, right = 0, bottom = 0}
  local x, y
  if busy then
    local free_l, free_r = ins.left, W - (ins.right or 0)
    x = math.max(free_l, free_l + (free_r - free_l - w) // 2)
    y = Hh - h - 60 - (ins.bottom or 0)
  else
    x, y = 14 + ins.left, Hh - h - 12 - (ins.bottom or 0)
  end
  if busy then
    D.fill(x, y, w, h, C.busy)
    D.rect(x, y, w, h, C.keycap_edge, 1)
  end
  local placed = L.row(items, x, y, w, h, {margins = m, spacing = 5})
  local bg = busy and C.busy or nil
  local r = placed[1]
  Q.text(r.x + Q.label_indent(dpx, true) // 2, r.y + Q.vcenter(r.h, lh), C.doing, doing, dpx, true, bg)
  for i, k in ipairs(keys) do
    local kr = placed[i + 1]
    local kbg, kedge, kfg = busy and C.busykey_bg or C.keycap_bg, busy and C.busykey_edge or C.keycap_edge,
                            busy and C.busykey or C.keycap
    -- the label fills the row's height; its text centred in what the edge leaves
    D.fill(kr.x, kr.y, kr.w, kr.h, kbg)
    D.rect(kr.x, kr.y, kr.w, kr.h, kedge, 1)
    local ty = kr.y + 1 + Q.vcenter(kr.h - 2, Q.line_h(kpx, true))
    Q.text(kr.x + 1 + 5 + Q.label_indent(kpx, true) // 2, ty, kfg, k, kpx, true, kbg)
  end
end

function H:set_play_kind(kind)
  self.ed.play_kind = kind
  local f = self.ed.save_config
  if type(f) == "function" then f(self.ed, "play_button", kind) end
end
-- File > Rename project: the field with the name, all of it selected, focused
function H:rename_start()
  self.menu_open = nil
  self.renaming = true
  self.rename_text = tostring((self.ed.project.meta and self.ed.project.meta.name) or "")
  local s = CT.state("hud.rename")
  s.e = LE.new(self.rename_text)
  s.e:select_all()
  CT.set_focus("hud.rename")
end
-- Enter, or the field losing the focus (a click beside it): the project gets the name (hud._rename_done; the editor
-- does the rest as project.rename: spaces, an empty name, the folder)
function H:rename_done()
  if not self.renaming then return end
  self.renaming = false
  if CT.focus == "hud.rename" then CT.set_focus(nil) end
  call(self.ed, "rename_project", self.rename_text)
end
function H:toggle_settings()
  self.menu_open = nil
  self.settings_open = not self.settings_open
  if not self.settings_open then self.capturing = nil end
end
-- a click on an action's key: the next key pressed is its key (the editor calls set_key); the same click again stops
function H:capture(a) if self.capturing == a then self.capturing = nil else self.capturing = a end end
-- the key pressed while capturing (nil: Esc, the action has no key); a key belongs to one action
function H:set_key(name)
  local a = self.capturing
  self.capturing = nil
  if not a then return end
  for other, k in pairs(self.keys) do
    if name and k == name then self.keys[other] = "" end
  end
  self.keys[a] = name or ""
  local f = self.ed.save_config
  if type(f) == "function" then f(self.ed, "hotkeys", self.keys) end
end

-- --- over the world (hud.paintEvent: QPainter with antialiasing; the camera's projection is the editor's) ---
H.GIZMO_M = 0.8
H.PERSON = {-0.35, -0.35, 0.0, 0.35, 0.35, 1.85}
H.SMALL = {-0.25, -0.25, 0.0, 0.25, 0.25, 0.5}
-- picking.turn: a point turned as the game turns things (roll around y, pitch around x, yaw around z; degrees)
function H.turn(x, y, z, roll, pitch, yaw)
  local cy, sy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
  local cp, sp = math.cos(math.rad(pitch)), math.sin(math.rad(pitch))
  local cr, sr = math.cos(math.rad(roll)), math.sin(math.rad(roll))
  x, z = x * cr + z * sr, -x * sr + z * cr
  y, z = y * cp - z * sp, y * sp + z * cp
  x, y = x * cy - y * sy, x * sy + y * cy
  return x, y, z
end
local PT_COLOUR, PT_PICKED = "#e3c65f", "#ffffff"     -- (pathtool.COLOUR, PICKED)
local function hex(s, a)
  return (tonumber(s:sub(2, 3), 16) << 24) | (tonumber(s:sub(4, 5), 16) << 16) | (tonumber(s:sub(6, 7), 16) << 8) | (a or 255)
end
-- QPainter's drawLine with a QPen(colour, width): the default square cap reaches half the width past each end
local function qline(a, b, colour, width)
  local dx, dy = b[1] - a[1], b[2] - a[2]
  local len = math.sqrt(dx * dx + dy * dy)
  local ex, ey = 0, 0
  if len > 0 then ex, ey = dx / len * width / 2, dy / len * width / 2 end
  D.line(a[1] - ex - 0.5, a[2] - ey - 0.5, b[1] + ex - 0.5, b[2] + ey - 0.5, colour, width)   -- (AddLine adds 0.5)
end
-- drawEllipse(centre, r, r) with a pen (colour, width) and a brush (nil: none): the fill, then the pen on the outline
local function qcircle(c, r, pen, width, brush)
  if brush then D.disc(c[1], c[2], r, brush) end
  if pen then D.circle(c[1], c[2], r + 0.5, pen, width) end   -- (AddCircle draws at the radius - 0.5)
end
-- drawText into a rectangle with AlignCenter (or AlignLeft | AlignVCenter): the shadow 1 px down right, the text
local function qtext_in(rx, ry, rw, rh, s, colour, centre)
  local tw, lh = Q.text_w(s, 12, true), Q.line_h(12, true)
  local x = math.floor(centre and rx + (rw - tw) / 2 or rx)   -- (Qt's raster engine floors a glyph's x)
  local y = ry + (rh - lh) / 2
  Q.text(x + 1, y + 1, rgba(0, 0, 0, 200), s, 12, true)
  Q.text(x, y, colour, s, 12, true)
end

-- hud._frame: an object's box (turned as it stands) as a glowing frame, its name above the highest corner
function H:draw_frame(o, colour_hex, label)
  local ed = self.ed
  local box = (ed.box_of and ed:box_of(o)) or (o.actor and H.PERSON or H.SMALL)
  local rot = o.rot or {0, 0, 0}
  local corners = {}
  for _, cx in ipairs({box[1], box[4]}) do
    for _, cy in ipairs({box[2], box[5]}) do
      for _, cz in ipairs({box[3], box[6]}) do
        local x, y, z = H.turn(cx, cy, cz, rot[1], rot[2], rot[3])
        corners[#corners + 1] = ed.cam:project({o.pos[1] + x, o.pos[2] + y, o.pos[3] + z}, self.W, self.Hh) or false
      end
    end
  end
  local edges = {{1, 2}, {3, 4}, {5, 6}, {7, 8}, {1, 3}, {2, 4}, {5, 7}, {6, 8}, {1, 5}, {2, 6}, {3, 7}, {4, 8}}
  local col = hex(colour_hex)
  for _, pen in ipairs({{rgba(0, 0, 0, 120), 4}, {hex(colour_hex, 70), 8}, {col, 1.8}}) do
    for _, e in ipairs(edges) do
      local a, b = corners[e[1]], corners[e[2]]
      if a and b then qline(a, b, pen[1], pen[2]) end
    end
  end
  if label then
    local top
    for _, c in ipairs(corners) do if c and (not top or c[2] < top[2]) then top = c end end
    if top then qtext_in(top[1] - 130, top[2] - 24, 260, 18, label, col, true) end
  end
end

-- how far the selection is dragged now ({0, 0, 0}: not dragged): the first one from where the drag began
function H.group_offset(ed)
  local d, sel = ed.drag, ed.selected
  if type(d) ~= "table" or not d.start or not sel then return {0, 0, 0} end
  return {sel[1] - d.start[1], sel[2] - d.start[2], sel[3] - d.start[3]}
end

-- hud._hover_and_selected: Select mode, the chosen object gold, the one under the mouse light blue with its name
function H:draw_hover_and_selected()
  local ed = self.ed
  local objs = ((ed.project.places or {})[ed.place] or {}).objects or {}
  local chosen
  if ed.selected then
    local key = (type(ed.drag) == "table" and ed.drag.start) or ed.selected
    local i = ed.project.find_object and ed.project:find_object(ed.place, key)
    chosen = i and objs[i]
    if chosen then
      local moved = {}
      for k, v in pairs(chosen) do moved[k] = v end
      moved.pos = {ed.selected[1], ed.selected[2], ed.selected[3]}
      self:draw_frame(moved, "#e3c65f")
    end
  end
  -- the rest of the selection (Shift+click) gold too, each where it is now: while dragged, as far as the first one
  -- (MaximdeWinter 24.10.: only the first had a frame, the others' rings moved only once it stood still)
  local off = H.group_offset(ed)
  for _, gp in ipairs(ed.group or {}) do
    local i = ed.project.find_object and ed.project:find_object(ed.place, gp)
    local g = i and objs[i]
    if g then
      local moved = {}
      for k, v in pairs(g) do moved[k] = v end
      moved.pos = {gp[1] + off[1], gp[2] + off[2], gp[3] + off[3]}
      self:draw_frame(moved, "#e3c65f")
    end
  end
  local o = self.hover
  if o and o ~= chosen then
    local name = o.display or o.id or o.template:match("([^\\]+)$"):gsub("%.[^.]*$", "")
    self:draw_frame(o, "#bfe3ff", (name:gsub("_", " ")))
  end
end

-- the gizmo (three axes 0.8 m, thick under the mouse; the middle a square to drag freely); the rest of the Shift
-- selection has its frames (draw_hover_and_selected)
function H:draw_gizmo()
  local g, ed = self.gizmo, self.ed
  if not g then return end
  local o = ed.cam:project(g.pos, self.W, self.Hh)
  if not o then return end
  for axis, c in ipairs({"#e5484d", "#46a758", "#3e8ed0"}) do
    local tip = {g.pos[1], g.pos[2], g.pos[3]}
    tip[axis] = tip[axis] + H.GIZMO_M
    local e = ed.cam:project(tip, self.W, self.Hh)
    if e then
      local wd = g.hover == axis - 1 and 6 or 3
      qline(o, e, hex(c), wd)
      qcircle(e, 7, hex(c), wd, hex(c))
    end
  end
  local free = g.hover == "free"
  local brush = rgba(255, 255, 255, free and 200 or 60)
  D.fill(o[1] - 7, o[2] - 7, 14, 14, brush)
  local wh = rgba(255, 255, 255)
  D.poly({o[1] - 7, o[2] - 7, o[1] + 7, o[2] - 7, o[1] + 7, o[2] + 7, o[1] - 7, o[2] + 7}, wh, 2, true)
end

-- Qt's dashes (QDashStroker): the pattern in pen widths (DashLine 4 2, DotLine 1 2), from the start of each drawn
-- path; every dash gets the square cap. pts: {{x, y}, ...} along the path (closed: back to the first).
local DASH, DOT = {4, 2}, {1, 2}
local function qdash(pts, colour, width, pattern, closed)
  local path = {}
  for _, p in ipairs(pts) do path[#path + 1] = p end
  if closed then path[#path + 1] = pts[1] end
  local u = math.max(width, 1)
  local i, left, on = 1, pattern[1] * u, true
  local piece = {path[1]}
  local function flush()
    if #piece >= 2 then
      local a, b = piece[1], piece[#piece]
      local a2, b2 = piece[2], piece[#piece - 1]
      -- the caps: half the width out past the dash's ends, along its first and last bits
      local function out(p, q)
        local dx, dy = p[1] - q[1], p[2] - q[2]
        local l = math.sqrt(dx * dx + dy * dy)
        if l == 0 then return p end
        return {p[1] + dx / l * width / 2, p[2] + dy / l * width / 2}
      end
      local flat = {}
      local s, e = out(a, a2), out(b, b2)
      flat[#flat + 1] = s[1]; flat[#flat + 1] = s[2]       -- (AddPolyline takes the points as they are)
      for k = 2, #piece - 1 do flat[#flat + 1] = piece[k][1]; flat[#flat + 1] = piece[k][2] end
      flat[#flat + 1] = e[1]; flat[#flat + 1] = e[2]
      D.poly(flat, colour, width)
    end
  end
  for k = 1, #path - 1 do
    local a, b = path[k], path[k + 1]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local len = math.sqrt(dx * dx + dy * dy)
    local at = 0
    while len - at > left do
      at = at + left
      local p = {a[1] + dx * at / len, a[2] + dy * at / len}
      if on then piece[#piece + 1] = p; flush() end
      piece = {p}
      on = not on
      i = i % #pattern + 1
      left = pattern[i] * u
    end
    left = left - (len - at)
    if on then piece[#piece + 1] = b else piece = {b} end
  end
  if on then flush() end
end
-- a QPainterPath ellipse as points (it starts at the right and goes up first, as addEllipse)
local function ellipse_pts(c, rx, ry, n)
  local pts = {}
  for k = 0, n - 1 do
    local t = k / n * 2 * math.pi
    pts[#pts + 1] = {c[1] + rx * math.cos(t), c[2] - ry * math.sin(t)}
  end
  return pts
end

-- QPainter's state for one paint (the pen and the brush stay set from one drawing to the next, as in hud.py)
local function painter() return {brush = nil} end

-- drawText(QPointF(x, baseline), s): x floored as Qt's raster engine does
local function qtext_at(x, baseline, s, colour, px, bold)
  local asc = select(1, w3.ui.font_metrics(px, bold and "bold" or nil))
  Q.text(math.floor(x), baseline - asc, colour, s, px, bold)
end

-- hud._rings: each Go to spot's radius (solid gold) and its search area on the map (dashed grey), 64 lines each
function H:draw_rings()
  local ed = self.ed
  for _, ring in ipairs(ed.spot_rings and ed:spot_rings() or {}) do
    local pos, r, area = ring[1], ring[2], ring[3]
    for _, rd in ipairs({{r, false}, {area, true}}) do
      local radius, dashed = rd[1], rd[2]
      if radius and radius ~= 0 and not (dashed and math.abs(radius - r) < 0.01) then
        local col = dashed and hex("#c8c8c8") or hex("#e3c65f")
        local pts = {}
        for t = 0, 64 do
          pts[#pts + 1] = ed.cam:project({pos[1] + radius * math.cos(t * math.pi / 32),
                                          pos[2] + radius * math.sin(t * math.pi / 32), pos[3]}, self.W, self.Hh) or false
        end
        for k = 1, 64 do
          local a, b = pts[k], pts[k + 1]
          if a and b then
            if dashed then qdash({a, b}, col, 2, DASH) else qline(a, b, col, 2) end
          end
        end
      end
    end
  end
end

-- hud._routes: the quest's ways dashed, a dot at each point, the step's kind at the start
function H:draw_routes(pt)
  local ed = self.ed
  local tool = ed.path_tool
  local nodes = ed.shown_steps and ed:shown_steps() or {}
  local gold = rgba(227, 198, 95, 170)
  for _, node in pairs(type(nodes) == "table" and nodes or {}) do
    for kind, a in pairs(node.step or {}) do
      local pts = type(a) == "table" and a.path or nil
      if pts and #pts >= 2 and not (tool and tool.points == pts) then
        local scr = {}
        for i, q in ipairs(pts) do scr[i] = ed.cam:project(q, self.W, self.Hh) or false end
        for i = 1, #scr - 1 do
          if scr[i] and scr[i + 1] then qdash({scr[i], scr[i + 1]}, gold, 2, DASH) end
        end
        pt.brush = gold
        for _, s in ipairs(scr) do   -- (the dashed pen is still set: each dot's outline dashed too)
          if s then
            D.disc(s[1], s[2], 3, gold)
            qdash(ellipse_pts(s, 3, 3, 32), gold, 2, DASH, true)
          end
        end
        if scr[1] then
          qtext_at(scr[1][1] + 8, scr[1][2] - 6, kind:sub(1, 1):upper() .. kind:sub(2):lower(), hex("#e3c65f"), 11)
        end
      end
    end
  end
end

-- hud._marker: a ring over a spot and its name, a dotted line down to it
function H:draw_marker(pt, pos, label, colour_hex, size, lift)
  size, lift = size or 9, lift or 1.8
  local ed = self.ed
  local a = ed.cam:project({pos[1], pos[2], pos[3] + lift}, self.W, self.Hh)
  if not a then return end
  local b = ed.cam:project(pos, self.W, self.Hh)
  local col = hex(colour_hex)
  if b then qdash({a, b}, col, 1.5, DOT) end
  pt.brush = nil
  qcircle(a, size, rgba(0, 0, 0, 180), 4)
  qcircle(a, size, col, 2)
  if label and label ~= "" then qtext_in(a[1] + size + 4, a[2] - 9, 260, 18, label, col, false) end
end

-- hud._talk_cams: each talk camera a small box looking its way with its name; a glide dashed; the player's spot
function H:draw_talk_cams(pt)
  local ed = self.ed
  local quest = (ed.project and ed.project.meta and ed.project.meta.quest) or {}
  local blue = hex("#6fb4e0")
  for _, node in pairs(quest.nodes or {}) do
    local a = (node.step or {}).talk
    if type(a) == "table" then
      local spots = {}
      for name, c in pairs(a.cams or {}) do
        local at = ed.cam:project(c.pos, self.W, self.Hh)
        if at then
          spots[name] = at
          local yaw, pitch = math.rad(tonumber(c.yaw or 0)), math.rad(tonumber(c.pitch or 0))
          local ahead = {c.pos[1] - math.sin(yaw) * math.cos(pitch) * 1.5, c.pos[2] + math.cos(yaw) * math.cos(pitch) * 1.5,
                         c.pos[3] + math.sin(pitch) * 1.5}
          local to = ed.cam:project(ahead, self.W, self.Hh)
          if to then qline(at, to, blue, 2) end
          pt.brush = rgba(24, 24, 26, 220)
          D.fill(at[1] - 8, at[2] - 6, 16, 12, pt.brush)
          D.poly({at[1] - 8, at[2] - 6, at[1] + 8, at[2] - 6, at[1] + 8, at[2] + 6, at[1] - 8, at[2] + 6}, blue, 2, true)
          qtext_at(at[1] + 12, at[2] + 4, name, blue, 11)
        end
      end
      local function walk(lines, out)
        for _, x in ipairs(lines or {}) do
          if x.choice then
            for _, c in ipairs(x.choice) do out[#out + 1] = c; walk(c.lines, out) end
          elseif x["if"] then
            for _, side in ipairs({"then", "else"}) do walk((x[side] or {}).lines, out) end
          elseif x.random then
            for _, way in ipairs(x.random) do walk(way.lines, out) end
          elseif not x.script then
            out[#out + 1] = x
          end
        end
        return out
      end
      for _, x in ipairs(walk(a.dialogue, {})) do
        local one, two = tostring(x.glide or ""), tostring(x.camera or "")
        if one:sub(1, 4) == "cam:" and two:sub(1, 4) == "cam:" and spots[one:sub(5)] and spots[two:sub(5)] then
          qdash({spots[one:sub(5)], spots[two:sub(5)]}, blue, 2, DASH)
        end
      end
      local spot = (a.spots or {}).player
      if spot then self:draw_marker(pt, spot.pos, "Player", "#c4c8d0", 7, 0.0) end
    end
  end
end

-- hud._markers: Markers on (M): the place's objects (the quest's gold, or all light blue), each a ring and its name
function H:draw_markers(pt)
  local ed = self.ed
  local mode = ed.markers or "off"
  if mode == "off" then return end
  self:draw_talk_cams(pt)
  local used = mode == "quest" and ed:quest_refs() or nil
  for _, o in ipairs((((ed.project.places or {})[ed.place]) or {}).objects or {}) do
    if not o.trail then
      local ref = ed.place .. "/" .. tostring(o.id)
      if not used or used[ref] then
        self:draw_marker(pt, o.pos, o.display or o.id or "", used and "#e3c65f" or "#9fb0ff")
      end
    end
  end
end

-- hud._beacon: Go to's pulsing rings and a column from the sky, for a few seconds (ed.beacon.until, the clock)
function H:draw_beacon(pt)
  local ed = self.ed
  local b = ed.beacon
  local now = ed.clock and ed:clock() or w3.time()
  if not b or now > b["until"] then return end
  local pos = b.pos
  local phase = (now * 2.0) % 1.0
  local sky = ed.cam:project({pos[1], pos[2], pos[3] + 25.0}, self.W, self.Hh)
  local foot = ed.cam:project(pos, self.W, self.Hh)
  if sky and foot then qline(sky, foot, rgba(255, 210, 90, 150), 3) end
  if foot then
    for k = 0, 1 do
      local r = 10 + 30 * ((phase + k * 0.5) % 1.0)
      local c = rgba(255, 210, 90, math.floor(230 * (1 - (r - 10) / 30)))
      if pt.brush then D.ellipse(foot[1], foot[2], r, r * 0.55, pt.brush, 0) end
      D.ellipse(foot[1], foot[2], r, r * 0.55, c, 3)
    end
  end
  self:draw_marker(pt, pos, b.label or "", "#ffd25a", 11, 0.0)
end

-- pathtool.draw: the lines (black 6 px under gold 3 px), the dots numbered from the start (#1a1a1a bold 11 px), the
-- one picked up white and larger, the end of an open path a square
function H:draw_path_tool(tool)
  local ed = self.ed
  local scr = {}
  for i, q in ipairs(tool.points) do scr[i] = ed.cam:project(q, self.W, self.Hh) or false end
  local col = hex(PT_COLOUR)
  local segs = {}
  for i = 1, #scr - 1 do segs[#segs + 1] = {scr[i], scr[i + 1]} end
  if tool.closed and #scr > 2 then segs[#segs + 1] = {scr[#scr], scr[1]} end
  for _, sg in ipairs(segs) do
    local a, b = sg[1], sg[2]
    if a and b then
      qline(a, b, rgba(0, 0, 0, 170), 6)
      qline(a, b, col, 3)
    end
  end
  local pen = rgba(0, 0, 0, 200)
  for i, s in ipairs(scr) do
    if s then
      local picked = i == tool.picked
      local r = picked and 10 or 8
      local brush = picked and hex(PT_PICKED) or col
      if i == #scr and not tool.closed and #scr > 1 then           -- the end: a square
        local x0, y0, x1, y1 = s[1] - r, s[2] - r, s[1] + r, s[2] + r
        D.fill_poly({x0, y0, x1, y0, x1, y1, x0, y1}, brush)
        D.poly({x0, y0, x1, y0, x1, y1, x0, y1}, pen, 2, true)
      else
        qcircle(s, r, pen, 2, brush)
      end
      local t = tostring(i)
      local tw, lh = Q.text_w(t, 11, true), Q.line_h(11, true)
      -- (on the opaque dot: ClearType, as Qt draws over an opaque pixel of its translucent window)
      Q.text(math.floor(s[1] - r + (2 * r - tw) / 2), s[2] - r + (2 * r - lh) / 2, hex("#1a1a1a"), t, 11, true, brush)
    end
  end
end

function H:draw_world()
  local ed = self.ed
  if not (ed.cam and ed.cam.ready) then return end
  local pt = painter()
  if ed.editing then
    self:draw_rings()
    self:draw_routes(pt)
    self:draw_markers(pt)
    self:draw_beacon(pt)
    if ed.mode == "select" then self:draw_hover_and_selected() end
    if ed.request and ed.request.world then
      local m = ed.pick_mouse
      local WP = require("conjunction.world_pick")
      WP.draw(ed, self.W, self.Hh, m and m[1], m and m[2])
      -- (what the click is for, under the bar: the scene's window is gone while one picks - 11.11.)
      local Q = require("conjunction.ui.qt")
      local r = ed.request
      local many = WP.noun(r.world, true)
      local text = string.format('Activate "Highlight %s" to see them all', many)
      if r.world_many then text = text .. "  ·  Shift+click picks several" end
      text = text .. "  ·  Enter takes them"
      local tw = Q.text_w(text, 13, true)
      local y = self.strip_rect and (self.strip_rect.y + self.strip_rect.h + 8) or 80
      local x = math.floor((self.W - tw) / 2)
      w3.ui.draw.fill(x - 12, y, tw + 24, 26, 0x000000c0)
      Q.text(x, y + 4, 0xffffffff, text, 13, true, 0x000000c0)
    end
    if ed.path_tool then self:draw_path_tool(ed.path_tool) end
    if ed.terrain_tool and ed.mode == "terrain" then self:draw_terrain(ed.terrain_tool) end
  end
  self:draw_gizmo()
end

-- terraintool.draw: the net over the changed ground (gold up, blue down: the more, the brighter), a ramp's line
-- (white dashed), the brush's edge on the ground (black under white 2 px) and its half-strength line (white dashed 1
-- px; none for a hard brush), the dot under the cursor
function H:draw_terrain(tool)
  local ed = self.ed
  if tool.terrain == nil then return end
  local W, Hh = self.W, self.Hh
  for _, run in ipairs(tool:net_lines()) do
    local scr = {}
    for i, pd in ipairs(run) do scr[i] = {ed.cam:project(pd[1], W, Hh) or false, pd[2]} end
    for i = 1, #scr - 1 do
      local a, dz, b = scr[i][1], scr[i][2], scr[i + 1][1]
      if a and b then
        local alpha = math.floor(math.min(230, 90 + 60 * math.abs(dz)))
        qline(a, b, dz > 0 and rgba(227, 198, 95, alpha) or rgba(110, 170, 230, alpha), 1.2)
      end
    end
  end
  local c = tool.cursor
  if not c then return end
  local b = tool.brush
  if tool.drag and tool.drag.op == "ramp" then
    local s, e = ed.cam:project(tool.drag.start, W, Hh), ed.cam:project(c, W, Hh)
    if s and e then qdash({s, e}, rgba(255, 255, 255, 220), 2, DASH) end
  end
  local inner = b.radius * (b.falloff ~= "hard" and 0.5 or 1.0)
  for k, ring in ipairs({{b.radius, rgba(255, 255, 255, 230), 2, false}, {inner, rgba(255, 255, 255, 120), 1, true}}) do
    if k == 1 or b.falloff ~= "hard" then
      local scr = {}
      for i, p in ipairs(tool:outline(c, ring[1])) do scr[i] = ed.cam:project(p, W, Hh) or false end
      for i = 1, #scr - 1 do
        if scr[i] and scr[i + 1] then qline(scr[i], scr[i + 1], rgba(0, 0, 0, 110), ring[3] + 2) end
      end
      for i = 1, #scr - 1 do
        if scr[i] and scr[i + 1] then
          if ring[4] then qdash({scr[i], scr[i + 1]}, ring[2], ring[3], DASH) else qline(scr[i], scr[i + 1], ring[2], ring[3]) end
        end
      end
    end
  end
  local dot = ed.cam:project(c, W, Hh)
  if dot then qcircle(dot, 3, nil, nil, rgba(255, 255, 255, 230)) end
end

-- --- the terrain brush (hud._build_brush / _sync_brush; experimental): three rows under the bar, centred ---
H.TOOLS = {{"raise", "Raise"}, {"lower", "Lower"}, {"smooth", "Smooth"}, {"flatten", "Flatten"}, {"set", "Set height"},
           {"ramp", "Ramp"}, {"noise", "Roughen"}, {"terrace", "Terrace"}}
H.STRENGTH = {raise = {0.02, 5.0}, lower = {0.02, 5.0}, noise = {0.05, 5.0}}   -- metres; the rest 0..1
local function round2(v) return tonumber(string.format("%.2f", v)) end

function H:brush_click(what, value)
  local t = self.ed.terrain_tool
  if not t then return end
  local b = t.brush
  if what == "op" then      -- (the strength into the tool's range first)
    local r = H.STRENGTH[value] or {0.05, 1.0}
    b.strength = math.max(r[1], math.min(r[2], b.strength))
    t:set("op", value)
  elseif what == "radius" then t:resize(value)
  elseif what == "strength" then t:strengthen(value)
  elseif what == "height" then     -- the height under the cursor (fixed), or back to where the stroke starts
    if b.height == nil and t.cursor then t:set("height", round2(t.cursor[3])) else t:set("height", nil) end
  elseif what == "extra" then      -- Terrace: its step; Roughen: the size of its bumps
    local key = b.op == "terrace" and "step" or "scale"
    t:set(key, round2(math.max(0.25, math.min(40.0, b[key] * (value > 0 and 1.25 or 0.8)))))
  elseif what == "undo" then t:undo_button()
  elseif what == "reset" then t:clear()
  else t:set(what, value) end
end

function H:draw_brush(W)
  self.brush_rect = nil
  local ed = self.ed
  local t = ed.terrain_tool
  if not (t and ed.mode == "terrain" and ed.editing) then return end
  local b = t.brush
  local function btn(text, id, click, on) return {hint = (btn_size(text, 9)), cross_max = 24, text = text, id = id,
                                                  click = click, on = on} end
  local function lab(text, id) return {hint = (label_size(text, 6, 6)), text = text, id = id, label = true} end
  local SPACE = {hint = 10, spacer = true, fixed = true, empty = true}
  local STRETCH = {hint = 0, stretch = 1, expanding = true, empty = true}
  local r1 = {}
  for _, tl in ipairs(H.TOOLS) do r1[#r1 + 1] = btn(tl[2], "terrain." .. tl[1], {"op", tl[1]}, b.op == tl[1]) end
  local strength = H.STRENGTH[b.op] and ("Strength " .. fmt_g(b.strength) .. " m")
                   or string.format("Strength %.0f %%", b.strength * 100)
  local r2 = {lab("Size " .. fmt_g(b.radius * 2) .. " m", "terrain.size"),
              btn("-", "terrain.smaller", {"radius", -2}), btn("+", "terrain.bigger", {"radius", 2}),
              lab(strength, "terrain.strength"),
              btn("-", "terrain.weaker", {"strength", -2}), btn("+", "terrain.stronger", {"strength", 2}), SPACE}
  for _, k in ipairs({{"smooth", "Soft"}, {"linear", "Linear"}, {"hard", "Hard"}}) do
    r2[#r2 + 1] = btn(k[2], "terrain.edge_" .. k[1], {"falloff", k[1]}, b.falloff == k[1])
  end
  r2[#r2 + 1] = SPACE
  for _, k in ipairs({{"circle", "Circle"}, {"square", "Square"}}) do
    r2[#r2 + 1] = btn(k[2], "terrain." .. k[1], {"shape", k[1]}, b.shape == k[1])
  end
  r2[#r2 + 1] = STRETCH
  local r3 = {}
  if b.op == "flatten" or b.op == "set" then
    local ht = b.height ~= nil and ("Height: " .. fmt_g(b.height) .. " m") or "Height: where the stroke starts"
    r3[#r3 + 1] = btn(ht, "terrain.height", {"height"})
  end
  local extra = ({terrace = "Step " .. fmt_g(b.step) .. " m", noise = "Bumps " .. fmt_g(b.scale) .. " m"})[b.op]
  if extra then
    r3[#r3 + 1] = lab(extra, "terrain.extra")
    r3[#r3 + 1] = btn("-", "terrain.extra_less", {"extra", -1})
    r3[#r3 + 1] = btn("+", "terrain.extra_more", {"extra", 1})
  end
  r3[#r3 + 1] = STRETCH
  local n = t:painted()
  -- (Qt shows the "&&" as it is: a QLabel without a buddy takes no mnemonic)
  r3[#r3 + 1] = lab(n > 0 and (n .. " stroke" .. (n ~= 1 and "s" or "") .. " \u{b7} applied by Build & Play") or "",
                    "terrain.painted")
  r3[#r3 + 1] = btn("Undo", "terrain.undo", {"undo"})
  r3[#r3 + 1] = btn("Reset", "terrain.reset", {"reset"})
  local rows = {r1, r2, r3}
  local iw = 0
  for _, r in ipairs(rows) do iw = math.max(iw, L.row_hint(r, {spacing = 4})) end
  local w, h = iw + 2 + 16, 1 + 6 + 3 * 24 + 2 * 4 + 8 + 1
  local x, y = math.max(0, (W - w) // 2), H.BAR_H - 1 + 6     -- (the bar's bottom + 6)
  self.brush_rect = {x = x, y = y, w = w, h = h}
  frame(x, y, w, h, C.panel, C.panel_edge)
  local click
  for i, r in ipairs(rows) do
    local placed = L.row(r, x + 9, y + 7 + (i - 1) * 28, iw, 24, {spacing = 4})
    for j, it in ipairs(r) do
      local p = placed[j]
      if it.label then
        self:hit("brush." .. it.id, p, it.id)
        Q.text(p.x + 6 + Q.label_indent(12) // 2, p.y + Q.vcenter(p.h, Q.line_h(12)), C.label, it.text, 12, false,
               C.panel)
      elseif it.text then
        local clicked, hovered = self:hit("brush." .. it.id, p, it.id)
        if it.on then D.fill(p.x, p.y, p.w, p.h, C.btn_checked) end
        if hovered then D.rect(p.x, p.y, p.w, p.h, C.btn_hover_edge, 1) end
        btn_text(p.x, p.y, p.w, p.h, it.text, 9, it.on and C.white or C.btn, false, C.panel)
        if clicked then click = it.click end
      end
    end
  end
  if click then self:brush_click(click[1], click[2]) end
end

-- --- Edit > Keyboard shortcuts (hud._build_settings: a grid, margins 8 6 8 8, 6 across, 3 down) ---
function H:draw_settings(W)
  self.settings_rect = nil
  if not self.settings_open then return end
  local ed = self.ed
  local rows = {}
  for _, a in ipairs(H.ACTIONS) do
    if (a ~= "mode.terrain" and a ~= "opt.edit_existing") or ed.experimental then rows[#rows + 1] = a end
  end
  local function key_text(a)
    if self.capturing == a then return "Press a key" end
    local k = self.keys[a] or ""
    return k ~= "" and k or "-"
  end
  -- the columns: the names (labels, padding 0 6), the keys (min-width 34, padding 3 8), the close button
  local c0, c1 = 0, 0
  for _, a in ipairs(rows) do
    c0 = math.max(c0, (label_size(H.label(ed, a), 6, 6)))
    c1 = math.max(c1, math.max(34, Q.hint_w(key_text(a), 12)) + 16 + 2)
  end
  local c2 = btn_size("\u{2715}", 9)
  local head_w = label_size("KEYBOARD SHORTCUTS", 4, 4, 12, true)
  if head_w > c0 + 6 + c1 then c0 = head_w - 6 - c1 end   -- (the heading spans the first two: never wider so far)
  local RH, n = 24, #rows + 1
  local w = 1 + 8 + c0 + 6 + c1 + 6 + c2 + 8 + 1
  local h = 1 + 6 + n * RH + (n - 1) * 3 + 8 + 1
  local x, y = math.max(8, W - w - 12), H.BAR_H + 6
  self.settings_rect = {x = x, y = y, w = w, h = h}
  frame(x, y, w, h, C.panel, C.panel_edge)
  local x0, x1, x2 = x + 9, x + 9 + c0 + 6, x + 9 + c0 + 6 + c1 + 6
  local ry = y + 7
  Q.text(x0 + 4 + Q.label_indent(12, true) // 2, ry + 4 + Q.vcenter(RH - 6, Q.line_h(12, true)), C.head,
         "KEYBOARD SHORTCUTS", 12, true, C.panel)
  do
    local r = {x = x2, y = ry, w = c2, h = RH}
    local clicked, hovered = self:hit("keys.close", r)
    if hovered then D.rect(r.x, r.y, r.w, r.h, C.btn_hover_edge, 1) end
    btn_text(r.x, r.y, r.w, r.h, "\u{2715}", 9, C.btn, false, C.panel)
    if clicked then self:toggle_settings() end
  end
  for _, a in ipairs(rows) do
    ry = ry + RH + 3
    local name = H.label(ed, a)
    self:hit("keys.name." .. a, {x = x0, y = ry, w = c0, h = RH}, a)
    Q.text(x0 + 6 + Q.label_indent(12) // 2, ry + Q.vcenter(RH, Q.line_h(12)), C.label, name, 12, false, C.panel)
    local r = {x = x1, y = ry, w = c1, h = RH}
    local clicked = self:hit("keys.key." .. a, r, "set.key")
    D.rect(r.x, r.y, r.w, r.h, C.panel_edge, 1)         -- (#key's edge: its id beats the buttons' :hover)
    btn_text(r.x, r.y, r.w, r.h, key_text(a), 8, C.label, false, C.panel)
    if clicked then self:capture(a) end
  end
end

-- is a point over the overlay's own parts (the bar, the strip, an open menu)? (hud.over_bar)
function H:over_bar(x, y)
  local function inside(r) return r and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h end
  -- (a mouse off the picture - ImGui's -FLT_MAX - is not over the bar: it blocked every box of the panel, 07.11.)
  if self.ed.editing and y >= 0 and y < H.BAR_H then return true end
  if require("conjunction.ui.pick_list").covers(x, y) then return true end
  return inside(self.strip_rect) or inside(self.settings_rect) or inside(self.brush_rect) or (self.menu_open and inside(self.menu_rect_now)) or false
end

-- --- actions (hud.trigger: the editor does the work) ---
function H:trigger(a)
  local ed = self.ed
  if ed.trigger then ed:trigger(a) end
end

function H:toggle_menu(name, anchor)
  if self.menu_open == name then self.menu_open = nil else self.menu_open, self.menu_anchor = name, anchor end
end

-- --- one frame ---
-- -> true when this frame's click was the overlay's (a click beside an open menu only closes it: editor.py)
-- the world's rings and frames alone, before the panel (init.lua: in the app they are the hud window's own painting,
-- and the panel and its windows lie above that window - Editor.stack); then frame(W, Hh, true)
function H:frame_world(W, Hh)
  self.W, self.Hh = W, Hh
  local was = Q.translucent
  Q.translucent = true
  self:draw_world()
  Q.translucent = was
end

-- the bar and its strip, drawn before the panel: under it and its windows (MaximdeWinter 14.11.: a window dragged over the
-- strip lay under it). covered(mx, my): the panel or a window there - the bar takes none of the mouse under them; with
-- one of its menus open the panel is blocked anyway. Its menus, the hints and the rest stay over all (H.frame)
function H:frame_under(W, Hh, covered)
  if not self.ed.editing then return end
  self.W, self.Hh = W, Hh
  local was = Q.translucent
  Q.translucent = true
  self.covered, self.drawing_under = (not self.menu_open) and covered or nil, true
  local ok, err = pcall(function()
    self:draw_bar(W)
    self:draw_strip(W)
  end)
  self.drawing_under = false
  Q.translucent = was
  self.under_done = true
  if not ok then error(err, 0) end
end

function H:frame(W, Hh, world_drawn)
  local ed = self.ed
  self.W, self.Hh = W, Hh
  local was = Q.translucent
  Q.translucent = true          -- hud.py's window is translucent: Qt decides its text per pixel (Q.text)
  local took = false
  -- a window dragged near an edge: the frame where it would dock (_draw_dock_preview: white at 24, a 2 px #c8c8c8
  -- line inside)
  local r = self.dock_preview
  if r then
    local D = w3.ui.draw
    D.fill(r.x, r.y, r.w, r.h, 0xffffff18)
    D.rect(r.x, r.y, r.w, r.h, 0xc8c8c8ff, 2)          -- (a 2 px pen on the rect 1 px in: its outer 2 px)
  end
  if not world_drawn then self:draw_world() end   -- (the window's own painting: under its children, the bar and the rest)
  if ed.editing then
    -- (the UI's mouse is in the game picture's positions: H.over_bar itself - the editor's over_bar takes the screen's)
    local mx, my = w3.ui.mouse()
    if self.menu_open and (w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(2)) and not H.over_bar(self, mx, my) then
      self.menu_open = nil
      took = true
    end
    if not self.under_done then                  -- (else drawn before the panel: H.frame_under)
      self:draw_bar(W)
      self:draw_strip(W)
    end
    self.under_done = false
    self:draw_menu()
    self:draw_brush(W)
    self:draw_hints(W, Hh)
    self:draw_settings(W)
    require("conjunction.ui.pick_list").frame(ed, W, Hh)   -- (what is picked in the world, at the right edge)
    took = took or H.over_bar(self, mx, my)
  end
  Q.translucent = was
  return took
end

return H
