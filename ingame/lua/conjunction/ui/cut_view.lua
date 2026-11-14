-- The scene workshop's cutscene editor, laid out like a video editor (Clipchamp): the game itself in the middle as
-- the preview (nothing drawn there: the game shows through, and the mouse goes to it), the library on the left
-- (animations, cameras, people), the clip's or the cutscene's properties on the right, the transport under the
-- picture, the timeline across the bottom. Full picture hides everything but a small bar.
--   CUT.frame(sw, r, sec)    sw: the scene window (scene_window.lua), r: the whole screen, sec: the section
--   CUT.covers(sw, x, y)     the mouse is over one of its parts (the rest is the game's)
local CT = require("conjunction.ui.controls")
local Q = require("conjunction.ui.qt")
local T = require("conjunction.ui.theme")
local SF = require("conjunction.scene_file")
local SW = require("conjunction.scene_work")
local TLV = require("conjunction.ui.timeline_view")
local D = w3.ui.draw
local CUT = {}

CUT.TOP, CUT.LEFT, CUT.RIGHT, CUT.TRANSPORT = 40, 320, 320, 44
CUT.ROW_H = 30
-- the library's kinds: a name's words (a pair: a scene pack's stage, with its other half)
CUT.KINDS = {{"All"}, {"Gestures", {"gesture"}}, {"Standing", {"standing", "stand"}}, {"Sitting", {"sitting", "sit"}},
             {"Kneeling", {"kneel", "kneeling", "knien"}}, {"Lying", {"lying", "laying", "lie"}}, {"Pairs"}}

local function label(x, y, text, colour, px, bold)
  Q.text(x, y, colour or T.TEXT, text, px or T.FONT, bold)
  return Q.line_h(px or T.FONT, bold)
end

local function short(name)
  return (tostring(name):gsub("^cj_b_b_", ""):gsub("^cj_", ""):gsub("_edited", ""):gsub("_", " "))
end

-- the parts' rectangles for a screen r
function CUT.layout(r)
  local tl_h = math.max(230, math.min(360, math.floor(r.h * 0.34)))
  local tl_y = r.y + r.h - tl_h
  return {top = {x = r.x, y = r.y, w = r.w, h = CUT.TOP},
          left = {x = r.x, y = r.y + CUT.TOP, w = CUT.LEFT, h = tl_y - r.y - CUT.TOP},
          right = {x = r.x + r.w - CUT.RIGHT, y = r.y + CUT.TOP, w = CUT.RIGHT, h = tl_y - r.y - CUT.TOP},
          picture = {x = r.x + CUT.LEFT, y = r.y + CUT.TOP, w = r.w - CUT.LEFT - CUT.RIGHT,
                     h = tl_y - r.y - CUT.TOP - CUT.TRANSPORT},
          transport = {x = r.x + CUT.LEFT, y = tl_y - CUT.TRANSPORT, w = r.w - CUT.LEFT - CUT.RIGHT, h = CUT.TRANSPORT},
          timeline = {x = r.x, y = tl_y, w = r.w, h = tl_h}}
end

local function inside(p, x, y) return x >= p.x and x < p.x + p.w and y >= p.y and y < p.y + p.h end

function CUT.covers(sw, x, y)
  local L = sw.cut_layout
  if not L then return false end
  if sw.bare then return sw.bare_bar and inside(sw.bare_bar, x, y) or false end
  for _, k in ipairs({"top", "left", "right", "transport", "timeline"}) do
    if inside(L[k], x, y) then return true end
  end
  return false
end

-- the people of the cutscene (its dialogset's slots; the player first)
function CUT.people(sw, sec)
  local s = sw.w.s
  local out = {}
  local set = s:set_of(sec)
  local ds = set and s:obj(s:_dialogset(set) or 0)
  for _, sl in ipairs(ds and ds:get("slots") or {}) do
    local so = s:obj(sl)
    local a = so and so:get("actorName")
    if a and a ~= "" then out[#out + 1] = a end
  end
  for _, tr in ipairs(s:timeline(sec).tracks) do if tr.actor then out[#out + 1] = tr.actor end end
  for _, m in ipairs(s:moments(sec)) do
    for a in pairs(m.places) do out[#out + 1] = a end
  end
  table.sort(out, function(a, b)
    if (a == "GERALT") ~= (b == "GERALT") then return a == "GERALT" end
    return a < b
  end)
  local seen, uniq = {}, {}
  for _, a in ipairs(out) do if not seen[a] then seen[a] = true uniq[#uniq + 1] = a end end
  return uniq
end

local function fill_box(p) D.fill(p.x, p.y, p.w, p.h, T.SURFACE) end

-- what `actor` of the open scene can play: their template's dialogue animations (talking.dialogue_anims), nil when
-- not known (no figure, its sets not read) - kept per actor and scene
function CUT.body_of(sw, actor)
  sw.bodies = sw.bodies or {}
  local key = tostring(sw.w and sw.w.path) .. "|" .. tostring(actor)
  if sw.bodies[key] == nil then
    local have = false
    pcall(function()
      local tpl
      if actor == "GERALT" then tpl = require("conjunction.dialogue").PLAYERS.geralt.template
      else
        local e = sw.w:figure_of(actor)
        local t = e and e.template                -- (TW3SE: the entity's template, a CEntityTemplate)
        local path = t and t:GetPath()
        tpl = type(path) == "string" and path ~= "" and path or nil
      end
      if tpl then have = require("conjunction.talking").dialogue_anims(tpl, sw.w.depot) or false end
    end)
    if have and next(have) == nil then have = false end
    sw.bodies[key] = have
  end
  return sw.bodies[key] or nil
end

function CUT.frame(sw, r, sec)
  local L = CUT.layout(r)
  sw.cut_layout = L
  local people = CUT.people(sw, sec)
  local has = false
  for _, a in ipairs(people) do if a == sw.lib_for then has = true end end
  if not has then sw.lib_for = people[#people] or people[1] end
  CUT.view(sw, (not sw.bare and not sw.view_paused) and L.picture or nil)
  if sw.bare then CUT.bare(sw, r, sec) return end
  CUT.top(sw, L.top, sec)
  CUT.library(sw, L.left, sec, people)
  CUT.transport(sw, L.transport, sec)
  CUT.properties(sw, L.right, sec, people)
  D.rect(L.picture.x, L.picture.y, L.picture.w, L.picture.h, T.LINE, 1)
  local tlr = L.timeline
  D.fill(tlr.x, tlr.y, tlr.w, tlr.h, T.BG)
  D.fill(tlr.x, tlr.y, tlr.w, 1, T.LINE)
  sw:timeline({x = tlr.x + 8, y = tlr.y + 8, w = tlr.w - 16, h = tlr.h - 12}, sec,
              {cut = true, people = people, drag = sw.lib_drag})
  CUT.dragging(sw)
end

-- the game's picture: the whole camera frame scaled into rectangle p (TW3SE's w3.view.rect), nil: full screen; the
-- game's HUD hidden while the editor is open
function CUT.view(sw, p)
  local key = p and string.format("%d,%d,%d,%d", p.x, p.y, p.w, p.h) or "full"
  if sw.view_key == key then return end
  sw.view_key = key
  if w3.view and w3.view.rect then
    if p then pcall(w3.view.rect, p.x + 1, p.y + 1, p.w - 2, p.h - 2) else pcall(w3.view.rect, false) end
  end
  if not sw.hud_hidden and w3.hud and w3.hud.visible then
    sw.hud_hidden = true
    pcall(w3.hud.visible, false)
  end
end

-- the editor closed: the game's picture full screen again, its HUD back
function CUT.leave(sw)
  -- (its preview ends with it - a paused one held the picture - and the world is the editor's again once it is over:
  -- scene_stage.lua, scene_work.after_play_tick)
  local STG = require("conjunction.scene_stage")
  if STG.staged then
    if STG.scene_on() then SW.stop() end
    if sw.ed then pcall(STG.unstage, sw.ed) end
  end
  if sw.view_key and sw.view_key ~= "full" and w3.view and w3.view.rect then pcall(w3.view.rect, false) end
  sw.view_key = nil
  if sw.hud_hidden and w3.hud and w3.hud.visible then pcall(w3.hud.visible, true) end
  sw.hud_hidden = nil
end

-- the top bar: what is edited, undo, the scene list
function CUT.top(sw, p, sec)
  D.fill(p.x, p.y, p.w, p.h, T.BG)
  D.fill(p.x, p.y + p.h - 1, p.w, 1, T.LINE)
  local w = sw.w
  label(p.x + 12, p.y + 11, "Cutscene editor", T.BRIGHT, 14, true)
  label(p.x + 150, p.y + 12, sw.label(w.path) .. "  -  " .. w.s:name_of(sec), T.DIM, 13)
  local bx = p.x + p.w - 12
  local function btn(id, text, enabled, run)
    local bw = Q.button_size(text)
    bx = bx - bw
    local clicked = sw:button("cut." .. id, bx, p.y + 7, text, enabled)
    if clicked then run() end
    bx = bx - 6
  end
  btn("list", "Scene list", true, function() sw.cut = false sw.bare = false end)
  btn("game", "The game's scene", w:changed(), function() sw:after(w:revert()) sw.cut = false end)
  btn("redo", "Redo", #w.future > 0, function() sw:after(w:redo()) end)
  btn("undo", "Undo", #w.history > 0, function() sw:after(w:undo()) end)
  if sw.err then label(p.x + 150, p.y + 26, tostring(sw.err), T.RED, 11)
  elseif sw.note then label(p.x + 150, p.y + 26, tostring(sw.note), T.DIM, 11) end
end

-- the transport under the picture: the time, to the start, play / pause, to the end, take this view, full picture
function CUT.transport(sw, p, sec)
  D.fill(p.x, p.y, p.w, p.h, T.BG)
  local tl = sw.w.s:timeline(sec)
  local t = sw.playhead or 0
  label(p.x + 14, p.y + 14, string.format("%d:%04.1f  /  %d:%04.1f", t // 60, t % 60, tl.length // 60, tl.length % 60),
        T.TEXT, 13)
  local pv = sw:preview_of(sec)
  local playing = pv and not pv.paused
  local labels = {"|<", playing and "Pause" or "Play", ">|"}
  local total = 0
  for _, l in ipairs(labels) do total = total + Q.button_size(l) + 6 end
  local x = p.x + (p.w - total) // 2
  local bh = select(2, Q.button_size("Play"))
  local y = p.y + (p.h - bh) // 2
  local function btn(id, text, run)
    local clicked, bw = sw:button("cut.tp." .. id, x, y, text, true)
    if clicked then run() end
    x = x + bw + 6
  end
  btn("start", "|<", function() sw:seek(sec, 0.0) end)
  btn("play", labels[2], function() sw:play_pause(sec) end)
  btn("end", ">|", function() sw:seek(sec, math.max(0, tl.length - 0.05)) end)
  local fw = Q.button_size("Full picture")
  local vw = Q.button_size("Take this view")
  local clicked = sw:button("cut.tp.view", p.x + p.w - fw - vw - 18, y, "Take this view", w3.camera ~= nil)
  if clicked then sw:take_view(sec) end
  local full = sw:button("cut.tp.full", p.x + p.w - fw - 10, y, "Full picture", true)
  if full then sw.bare = true end
end

-- full picture: only a small bar at the bottom (back, play / pause, the time)
function CUT.bare(sw, r, sec)
  local tl = sw.w.s:timeline(sec)
  local bw, bh = 330, 40
  local p = {x = r.x + (r.w - bw) // 2, y = r.y + r.h - bh - 16, w = bw, h = bh}
  sw.bare_bar = p
  D.fill(p.x, p.y, p.w, p.h, T.BG)
  D.rect(p.x, p.y, p.w, p.h, T.LINE, 1)
  local x = p.x + 8
  local y = p.y + (bh - select(2, Q.button_size("Play"))) // 2
  local c1, w1 = sw:button("cut.bare.back", x, y, "Show panels", true)
  if c1 then sw.bare = false end
  x = x + w1 + 6
  local pv = sw:preview_of(sec)
  local c2, w2 = sw:button("cut.bare.play", x, y, (pv and not pv.paused) and "Pause" or "Play", true)
  if c2 then sw:play_pause(sec) end
  x = x + w2 + 10
  local t = sw.playhead or 0
  label(x, p.y + 13, string.format("%.1f / %.1f s", t, tl.length), T.TEXT, 13)
end

-- --- the library (left): animations, cameras, people
function CUT.library(sw, p, sec, people)
  fill_box(p)
  D.fill(p.x + p.w - 1, p.y, 1, p.h, T.LINE)
  local x, y = p.x + 10, p.y + 10
  sw.lib_tab = sw.lib_tab or "anims"
  for _, t in ipairs({{"anims", "Animations"}, {"cams", "Cameras"}, {"people", "People"}, {"world", "World"}}) do
    local bw = Q.button_size(t[2])
    local clicked = sw:button("cut.tab." .. t[1], x, y, t[2], true)
    if sw.lib_tab == t[1] then D.rect(x, y, bw, select(2, Q.button_size(t[2])), T.CHOSEN_EDGE, 1) end
    if clicked then sw.lib_tab = t[1] end
    x = x + bw + 6
  end
  y = y + select(2, Q.button_size("A")) + 10
  local body = {x = p.x + 10, y = y, w = p.w - 20, h = p.y + p.h - y - 8}
  if sw.lib_tab == "anims" then CUT.anims(sw, body, sec, people)
  elseif sw.lib_tab == "cams" then CUT.cams(sw, body, sec)
  elseif sw.lib_tab == "world" then CUT.world(sw, body, sec)
  else CUT.people_tab(sw, body, sec, people) end
end

-- the animations: for whom, the words, the kind, the list (a click shows it on the person, a double click or a drag
-- onto a track puts it on the timeline)
function CUT.anims(sw, p, sec, people)
  local x, y = p.x, p.y
  label(x, y + 6, "For", T.DIM, 12)
  local fi = 1
  for i, a in ipairs(people) do if a == sw.lib_for then fi = i end end
  local shown = {}                                -- (a talk's NPC by the name its card gives them)
  for i, a in ipairs(people) do shown[i] = (sw.actor_names and sw.actor_names[a]) or a end
  local ch, ni = CT.combo("cut.for", x + 34, y, p.w - 34, shown, fi, {x = 0, y = 0, w = 4000, h = 4000})
  if ch and people[ni] then sw.lib_for = people[ni] sw.lib_list = nil sw.lib_scroll = 0 sw:peek_stop() end
  y = y + 34
  local changed, text = CT.edit("cut.lib.words", x, y, p.w, sw.lib_text or "", {placeholder = "Search animations"})
  if changed then sw.lib_text = text sw.lib_list = nil sw.lib_scroll = 0 end
  y = y + CT.edit_h() + 6
  local kx = x
  sw.lib_kind = sw.lib_kind or "All"
  for _, k in ipairs(CUT.KINDS) do
    local tw = math.floor(Q.text_w(k[1], 12)) + 14
    if kx + tw > p.x + p.w then kx = x y = y + 26 end
    local box = {x = kx, y = y, w = tw, h = 22}
    local clicked, hv = sw:hit("cut.kind." .. k[1], box)
    D.fill(box.x, box.y, box.w, box.h, sw.lib_kind == k[1] and T.CHOSEN or (hv and T.HOVER or T.BUTTON))
    D.rect(box.x, box.y, box.w, box.h, sw.lib_kind == k[1] and T.CHOSEN_EDGE or T.EDGE, 1)
    label(box.x + 7, box.y + 4, k[1], T.TEXT, 12)
    if clicked then sw.lib_kind = k[1] sw.lib_list = nil sw.lib_scroll = 0 end
    kx = kx + tw + 4
  end
  -- only what the one picked can play (their body's sets): on unless turned off
  if CUT.body_of(sw, sw.lib_for) then
    local text = "Fits " .. tostring(sw.lib_for)
    local tw = math.floor(Q.text_w(text, 12)) + 14
    if kx + tw > p.x + p.w then kx = x y = y + 26 end
    local box = {x = kx, y = y, w = tw, h = 22}
    local on = sw.lib_fits ~= false
    local clicked, hv = sw:hit("cut.fits", box)
    D.fill(box.x, box.y, box.w, box.h, on and T.CHOSEN or (hv and T.HOVER or T.BUTTON))
    D.rect(box.x, box.y, box.w, box.h, on and T.CHOSEN_EDGE or T.EDGE, 1)
    label(box.x + 7, box.y + 4, text, T.TEXT, 12)
    if hv then CT.tip("cut.fits", "cut.fits") end
    if clicked then sw.lib_fits = not on sw.lib_list = nil sw.lib_scroll = 0 end
  end
  y = y + 30
  local list = CUT.found(sw)
  local box = {x = x, y = y, w = p.w, h = p.y + p.h - y - 34}
  CUT.list(sw, box, list, sec)
  label(x, p.y + p.h - 28, "Click: shown on the person", T.DIM, 11)
  label(x, p.y + p.h - 14, "Double click or drag onto a track: on the timeline", T.DIM, 11)
end

-- the animations found for the words and the kind -> {{name, len, from, pair}}
function CUT.found(sw)
  if sw.lib_list then return sw.lib_list end
  local depot = sw.w.depot
  local words = sw.lib_text or ""
  local all = SW.find_animations(depot, words, 4000)
  local kind
  for _, k in ipairs(CUT.KINDS) do if k[1] == sw.lib_kind then kind = k end end
  local body = sw.lib_fits ~= false and CUT.body_of(sw, sw.lib_for) or nil
  local out = {}
  for _, a in ipairs(all) do
    local name = a[1]
    local base, half = name:match("^(.*)_([ab])$")
    local pair = base and SW.animation_length(depot, base .. "_" .. (half == "a" and "b" or "a")) ~= nil
    local ok = true
    if kind and kind[2] then
      ok = false
      local low = name:lower()
      for _, wd in ipairs(kind[2]) do if low:find(wd, 1, true) then ok = true break end end
    elseif kind and kind[1] == "Pairs" then
      ok = pair
    end
    if ok and body and a[3] == "game" and not body[name] then ok = false end   -- (scene packs' stay: their sets come along)
    if ok then out[#out + 1] = {name = name, len = a[2], from = a[3], pair = pair} end
    if #out >= 300 then break end
  end
  sw.lib_list = out
  return out
end

-- a list of its own (a click, a double click, a drag out of it)
function CUT.list(sw, box, list, sec)
  D.fill(box.x, box.y, box.w, box.h, T.BG)
  local mx, my, wheel = w3.ui.mouse()
  sw.lib_scroll = sw.lib_scroll or 0
  if CT.over(box) and wheel and wheel ~= 0 then
    sw.lib_scroll = math.max(0, math.min(math.max(0, #list - math.floor(box.h / CUT.ROW_H)), sw.lib_scroll - wheel * 3))
  end
  local first = math.floor(sw.lib_scroll) + 1
  D.clip(box.x, box.y, box.w, box.h, function()
    for i = first, #list do
      local y = box.y + (i - first) * CUT.ROW_H
      if y > box.y + box.h then break end
      local a = list[i]
      local row = {x = box.x, y = y, w = box.w, h = CUT.ROW_H - 2}
      local clicked, hv, held = sw:hit("cut.lib." .. i, row)
      local picked = sw.lib_pick == a.name
      D.fill(row.x, row.y, row.w, row.h, picked and T.CHOSEN or (hv and T.HOVER or T.SURFACE))
      -- (the name cut before the length and the pair mark: a long name ran under them)
      local room = row.w - 8 - (a.pair and 100 or 54)
      label(row.x + 8, row.y + 7, Q.elide(short(a.name), "right", room, 12), T.TEXT, 12)
      if a.pair then label(row.x + row.w - 92, row.y + 8, "pair", T.DIM, 11) end
      label(row.x + row.w - 46, row.y + 7, string.format("%.1f s", a.len or 0), T.DIM, 12)
      if held and not sw.lib_press then sw.lib_press = {name = a.name, len = a.len, x = mx, y = my} end
      if clicked then
        if w3.ui.mouse_double and w3.ui.mouse_double(1) or (sw.lib_click and sw.lib_click.name == a.name and
            w3.time and w3.time() - sw.lib_click.t < 0.35) then
          sw:add_anim(sec, sw.lib_for, a.name, a.len, sw.playhead or 0)
          sw.lib_click = nil
        else
          sw.lib_pick = a.name
          sw:peek(sw.lib_for, a.name)
          sw.lib_click = {name = a.name, t = w3.time and w3.time() or 0}
        end
      end
    end
  end)
  D.rect(box.x, box.y, box.w, box.h, T.LINE, 1)
  if #list == 0 then label(box.x + 10, box.y + 10, "Nothing found", T.DIM, 12) end
end

-- a drag out of the library: past a few pixels it is a drag; let go over a person's track it lands there
function CUT.dragging(sw)
  local pr = sw.lib_press
  if not pr then return end
  local mx, my = w3.ui.mouse()
  if w3.ui.mouse_down(1) then
    if not sw.lib_drag and math.abs(mx - pr.x) + math.abs(my - pr.y) > 6 then
      sw.lib_drag = {name = pr.name, len = pr.len}
      sw:peek_stop()
    end
    if sw.lib_drag then
      local tw = 220
      D.fill(mx + 12, my + 8, tw, 24, T.CHOSEN)
      D.rect(mx + 12, my + 8, tw, 24, T.CHOSEN_EDGE, 1)
      label(mx + 20, my + 12, short(sw.lib_drag.name), T.BRIGHT, 12)
    end
  else
    sw.lib_press, sw.lib_drag = nil, nil
  end
end

-- things of the world at the playhead (MaximdeWinter 10.11.): a light on or off, a door, an effect, an object hidden or
-- shown again - each picked in the world (SCW:world_action); the ones of the section below
CUT.ACTS = {{"light_on", "Light on", "light"}, {"light_off", "Light off", "light"},
            {"door_open", "Open door", "door"}, {"door_close", "Close door", "door"},
            {"effect", "Play effect", "effect"}, {"move", "Move a thing", "moving"},
            {"hide", "Hide object", "any"}, {"show", "Show object", "any"}}
function CUT.world(sw, p, sec)
  local x, y = p.x, p.y
  label(x, y, string.format("At %.1f s, with a thing of the world", sw.playhead or 0), T.DIM, 12)
  y = y + 24
  local half = (p.w - 6) // 2
  for i, a in ipairs(CUT.ACTS) do
    local col = (i - 1) % 2
    local bx = x + col * (half + 6)
    if sw:button("cut.act." .. a[1], bx, y, a[2], sw.ed ~= nil, half) then sw:world_action(sec, a[1], a[3]) end
    if col == 1 or i == #CUT.ACTS then y = y + select(2, Q.button_size("A")) + 4 end
  end
  y = y + 8
  -- (two lines: in one, "30 m" ran under the picture - 11.11.)
  label(x, y, "Click it in the world.", T.DIM, 11)
  y = y + Q.line_h(11)
  label(x, y, "Show what fits marks everything within 30 m", T.DIM, 11)
  y = y + Q.line_h(11) + 10
  -- (the sky from the playhead on: blended in 5 s, as the game's scenes bring a storm)
  local TLm = require("conjunction.scene_timeline")
  local items = {}
  for _, wt in ipairs(require("conjunction.questboard").WEATHERS) do
    items[#items + 1] = {text = TLm.weather_name(wt), action = function()
      sw:after(sw.w:add_world_action(sec, sw.playhead or 0, {what = "weather", wid = "sky", weather = wt}))
    end}
  end
  if sw:button("cut.act.weather", x, y, "Weather  \u{25be}", true, half) then
    require("conjunction.ui.inline_menu").open("cut.act.weather", {x = x, y = y + 30, w = math.max(half, 180), h = 2},
                                               items, sw.win and sw.win.rect or p)
  end
  -- (a look laid over the world's light from the playhead on: the game's scenes' sunsets, blizzards, nightmares)
  local looks = {}
  for _, l in ipairs(TLm.LOOKS) do
    looks[#looks + 1] = {text = l[2], action = function()
      sw:after(sw.w:add_world_action(sec, sw.playhead or 0, {what = "env", wid = "look", key = l[1]}))
    end}
  end
  table.insert(looks, 1, {text = "Back to normal", action = function()   -- (first: the list is long)
    local on = {}                                 -- (every look of the scene before the playhead: off)
    for _, c in pairs(sw.w.s:timeline(sec).clips or {}) do
      local st = tostring(c.name or ""):match("^" .. TLm.WORLD_ACT:gsub("%p", "%%%0") .. "env look (%S+)")
      if st and (c.start or 0) <= (sw.playhead or 0) + 1e-3 then
        local off, key = st:match("^(off:)(.*)$")
        on[key or st] = not off
      end
    end
    local ok, err = true, nil
    for key, lit in pairs(on) do
      if lit then ok, err = sw.w:add_world_action(sec, sw.playhead or 0, {what = "env", wid = "look", key = key, on = false}) end
    end
    sw:after(ok, err)
  end})
  if sw:button("cut.act.look", x + half + 6, y, "Look  \u{25be}", true, half) then
    require("conjunction.ui.inline_menu").open("cut.act.look", {x = x + half + 6, y = y + 30, w = math.max(half, 200),
                                               h = 2}, looks, sw.win and sw.win.rect or p)
  end
end

-- the cameras: a view for the moment at the playhead, the game's view taken
function CUT.cams(sw, p, sec)
  local x, y = p.x, p.y
  local w = sw.w
  local el = w.s:element_at(sec, sw.playhead or 0)
  -- (the moment's own view, if it has one: its size and view marked, a size applies to it at once)
  local m = el and w.s:moment(sec, el)
  local own = m and m.camera and m.camera.view ~= SF.OWN_VIEW and m.camera or nil
  -- (a talk's or scene's cameras: Automatic - a cut on each line's speaker - or Custom, the cuts as clips of one's
  -- own; Start empty: none but one at the start)
  if w.layer_name then
    local mode = w:camera_mode()
    local mx = x
    for _, md in ipairs({{"auto", "Automatic"}, {"custom", "Custom"}}) do
      local clicked, bw, bh = sw:button("cut.cammode." .. md[1], mx, y, md[2], true)
      if mode == md[1] then D.rect(mx, y, bw, bh, T.CHOSEN_EDGE, 1) end
      if clicked and mode ~= md[1] then sw:after(w:set_camera_mode(md[1])) end
      mx = mx + bw + 4
    end
    if mode == "custom" then
      if sw:button("cut.cammode.empty", mx + 6, y, "Start empty", true) then sw:after(w:set_camera_mode("custom", true)) end
    end
    y = y + select(2, Q.button_size("A")) + 10
  end
  label(x, y, "The camera of the moment at the playhead", T.DIM, 12)
  y = y + 22
  sw.cam_size = (own and own.size) or sw.cam_size or "medium"
  local sx = x
  for _, sz in ipairs(SF.SIZE_ORDER) do
    local bw = Q.button_size(sz)
    local clicked = sw:button("cut.size." .. sz, sx, y, sz, true)
    if sw.cam_size == sz then D.rect(sx, y, bw, select(2, Q.button_size(sz)), T.CHOSEN_EDGE, 1) end
    if clicked then
      sw.cam_size = sz
      if own and el and sz ~= own.size then sw:after(w:set_moment_camera(sec, el, own.view, sz)) end
    end
    sx = sx + bw + 4
  end
  y = y + select(2, Q.button_size("A")) + 8
  for _, v in ipairs(SF.views_for(el and w:moment_places(sec, el))) do
    local row = {x = x, y = y, w = p.w, h = CUT.ROW_H - 2}
    local clicked, hv = sw:hit("cut.view." .. v, row)
    local is = own and own.view == v
    D.fill(row.x, row.y, row.w, row.h, is and T.CHOSEN or (hv and T.HOVER or T.BG))
    label(row.x + 8, row.y + 7, v, T.TEXT, 12)
    if clicked and el then sw:after(w:set_moment_camera(sec, el, v, sw.cam_size)) end
    y = y + CUT.ROW_H
  end
  y = y + 10
  local c1, w1 = sw:button("cut.cam.take", x, y, "Take this view", w3.camera ~= nil)
  if c1 then sw:take_view(sec) end
  local c2 = sw:button("cut.cam.free", x + w1 + 6, y, "Free camera", w3.world ~= nil and w3.world.trace ~= nil)
  if c2 and el then
    local v = w:free_camera(sec, el)
    sw:after(v ~= nil, v == nil and "No view is free of walls here" or nil)
  end
  y = y + select(2, Q.button_size("A")) + 10
  require("conjunction.ui.game_choosers").parts.wrapped(x, y, p.w,
    "Take this view: fly Conjunction's free camera in the picture (the right mouse button), then take it.", 11, false, T.DIM)
end

-- the people: where each stands in the moment at the playhead
function CUT.people_tab(sw, p, sec, people)
  local x, y = p.x, p.y
  local w = sw.w
  local el = w.s:element_at(sec, sw.playhead or 0)
  local m = el and w.s:moment(sec, el)
  label(x, y, "Their places in the moment at the playhead", T.DIM, 12)
  y = y + 24
  local sw3 = (p.w - 12) // 3
  for _, actor in ipairs(people) do
    if y + 80 > p.y + p.h then break end
    local shown = (sw.actor_names and sw.actor_names[actor]) or actor   -- (a talk's NPC by its card's name)
    label(x, y + 6, shown, T.BRIGHT, 12, true)
    -- (no place of its own in this moment: the numbers below are not where they stand - 07.11.: both read 0, 0, 0)
    if not (m and m.places[actor]) then
      label(x + Q.text_w(shown, 12) + 14, y + 7, "(set's place)", T.DIM, 11)
    end
    local pw = Q.button_size("Put here")
    local ph = sw:button("cut.put." .. actor, x + p.w - pw, y, "Put here", sw.ed ~= nil and sw.ed.request_object ~= nil)
    if ph and m then sw:put_here(sec, m.el, actor) end
    -- (a walk from where they stand at the playhead to a point clicked in the world)
    local ww = Q.button_size("Walk to")
    local wk, _, _ = sw:button("cut.walk." .. actor, x + p.w - pw - 6 - ww, y, "Walk to",
                               sw.ed ~= nil and sw.ed.request_object ~= nil)
    if wk then sw:walk_here(sec, actor) end
    y = y + select(2, Q.button_size("A")) + 4
    -- (no place of its own in this moment: where they stand then - their slot, or a walk's way)
    local pl = m and m.places[actor]
    if not pl then
      local q = w:place_at(sec, actor, sw.playhead or 0)
      pl = {q[1], q[2], q[4]}
    end
    for i = 1, 3 do
      local changed, v = CT.spin("cut.place." .. actor .. "." .. tostring(el) .. "." .. i, x + (i - 1) * (sw3 + 6), y, pl[i] or 0,
                                 i == 3 and {w = sw3, min = -360, max = 360, step = 15, decimals = 0} or
                                 {w = sw3, min = -20, max = 20, step = 0.1, decimals = 2})
      if changed and m then
        local np = {pl[1] or 0, pl[2] or 0, pl[3] or 0}
        np[i] = v
        sw:after(w:set_moment_place(sec, m.el, actor, np))
      end
    end
    y = y + CT.edit_h() + 1
    label(x, y, "x", T.DIM, 11)
    label(x + sw3 + 6, y, "y", T.DIM, 11)
    label(x + 2 * (sw3 + 6), y, "turn", T.DIM, 11)
    y = y + Q.line_h(11) + 6
    -- (their acting at the playhead: whom they look at, their face, what is in their hand - the game's scene events)
    if y + 34 <= p.y + p.h then
      local at = sw.playhead or 0
      local function act(what, o)
        o.actor = actor
        sw:after(w:edit(function(s) s:add_acting(sec, what, at, o) end))
      end
      local others = {}
      for _, b in ipairs(people) do
        if b ~= actor then others[#others + 1] = {text = b, action = function() act("look", {target = b}) end} end
      end
      local moods = {}
      for _, md in ipairs(CUT.MOODS) do moods[#moods + 1] = {text = md, action = function() act("mood", {mood = md}) end} end
      local hands = {{text = "Steel sword", action = function() act("equip", {right = "steelsword"}) end},
                     {text = "Silver sword", action = function() act("equip", {right = "silversword"}) end},
                     {text = "Empty hands", action = function() act("equip", {right = "", left = ""}) end}}
      local bw = (p.w - 12) // 3
      for i, m3 in ipairs({{"look", "Looks at", others}, {"mood", "Mood", moods}, {"hand", "In hand", hands}}) do
        local bx = x + (i - 1) * (bw + 6)
        if sw:button("cut.acting." .. m3[1] .. "." .. actor, bx, y, m3[2] .. "  \u{25be}", #m3[3] > 0, bw) then
          local IM = require("conjunction.ui.inline_menu")
          IM.open("cut.acting." .. m3[1] .. "." .. actor, {x = bx, y = y + 30, w = math.max(bw, 160), h = 2}, m3[3],
                  sw.win and sw.win.rect or p)
        end
      end
      y = y + select(2, Q.button_size("A")) + 12
    end
  end
end
-- (the faces the game's scenes use most, part 1 counted 10.11.)
CUT.MOODS = {"Neutral", "Determined", "Focused", "Confident", "Happy", "Very happy", "Sad", "Cry", "Afraid", "Nervous",
             "Surprised", "Sceptic", "Proud", "Contempt", "Disgusted", "Aggressive", "Bursting_anger", "Seducing"}

-- --- the right: the clip picked, or the cutscene
function CUT.properties(sw, p, sec, people)
  fill_box(p)
  D.fill(p.x, p.y, 1, p.h, T.LINE)
  local x, y, cw = p.x + 14, p.y + 12, p.w - 28
  local clip = sw.tl_pick and sw.w.s:timeline(sec).clips[sw.tl_pick]
  if clip then
    sw:clip_card(clip, sec, x, y, cw)
    return
  end
  local w = sw.w
  local s = w.s
  label(x, y, "Your cutscene", T.BRIGHT, 14, true)
  y = y + 28
  local set = s:set_of(sec)
  local ds = set and s:obj(s:_dialogset(set) or 0)
  local tag = ds and (ds:get("placementTag") or {})[1] or "PLAYER"
  sw.spots = sw.spots or {}
  label(x, y + 6, "Spot", T.DIM, 12)
  local _, nt, enter = CT.edit("cut.spot." .. tostring(set), x + 50, y, cw - 50, tag, {})
  if enter and nt ~= "" and nt ~= tag then sw:after(w:set_place_tag(set, nt)) end
  y = y + CT.edit_h() + 6
  if tag ~= "PLAYER" then
    if sw:button("cut.try", x, y, "Try at the player", true) then
      sw.spots[set] = tag
      sw:after(w:set_place_tag(set, "PLAYER"))
    end
    y = y + select(2, Q.button_size("A")) + 8
  elseif sw.spots[set] then
    if sw:button("cut.back", x, y, "Back to " .. sw.spots[set], true) then
      local back = sw.spots[set]
      sw.spots[set] = nil
      sw:after(w:set_place_tag(set, back))
    end
    y = y + select(2, Q.button_size("A")) + 8
  end
  local tl = s:timeline(sec)
  label(x, y, string.format("%.1f s long, %d moment(s), %d people", tl.length, #tl.elements, #people), T.DIM, 12)
  y = y + 24
  require("conjunction.ui.game_choosers").parts.wrapped(x, y, cw,
    "Pick an animation on the left, a click shows it on the person. Drag it onto the person's track below. Click a " ..
    "clip to change it here.", 11, false, T.DIM)
end

return CUT
