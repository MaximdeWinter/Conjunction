-- cast_view.py's CastWindow: In this quest - the quest's people, things and items in three lists, each with where it
-- is and the steps that use it; a filter over all three. One of the panel's windows (panel:cast_window(board)).
--   a person / a thing: its crosshair (or a double click) flies there; a step's button opens that step's card
--   an own item: its name edited in place; its bin asks once more, then it goes (out of the steps too)
-- Measured on Qt (ref/qt/cast_window*.png): the body #232326, margins 4 2 4 4, 6 apart; the count bold 14 px #eee;
-- the filter the theme's field; the lists in a scroll area (margins 0 0 4 0, 4 apart): a heading bold 11 px #8a8a8a
-- (padding 8 0 2 0), a row a #1c1c1f frame with a #303034 border (margins 8 5 6 5; its rows 3 apart, inherited):
-- the name bold 12 px #f0f0f0, where in 11 px #9a9a9a, the crosshair 23 x 23; under it the steps (4 apart) - a
-- button #2e2e33, 11 px #ddd, a #4a4a50 border (#999 under the mouse), or "Not in a step"
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local W = require("conjunction.ui.qw")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local IC = require("conjunction.ui.item_chooser")
local P = require("conjunction.py")
local Y = require("conjunction.yaml")
local PYS = require("conjunction.pystr")
local D = w3.ui.draw
local CW = {}
CW.__index = CW

local function hex(s) return (tonumber(s:sub(2), 16) << 8) | 255 end
CW.C = {bg = hex("#232326"), text = hex("#dddddd"), kind = hex("#8a8a8a"), grey = hex("#9a9a9a"),
        row = hex("#1c1c1f"), row_edge = hex("#303034"), name = hex("#f0f0f0"), head = hex("#eeeeee"),
        step = hex("#2e2e33"), step_edge = hex("#4a4a50"), step_hover = hex("#999999"), icon_hover = hex("#3a3a3e"),
        danger = hex("#5a2626"), danger_edge = hex("#8a3a3a"), white = hex("#ffffff")}
local C = CW.C

function CW.new(board, win)
  local self = setmetatable({board = board, win = win, filter = "", asking = nil, bar = IV.bar(1, 0, 0),
                             bar_state = {}}, CW)
  return self
end

-- what the quest has (CastWindow._gather)
function CW:gather()
  local QS = require("conjunction.quest")
  local b = self.board
  local q = b:quest()
  local steps = IC.numbered_steps(q)
  local people, things = {}, {}
  local places = b.ed.project.places or {}
  for _, place in ipairs(Y.is_map(places) and Y.keys(places) or (function()
    local ks = {}
    for k in pairs(places) do ks[#ks + 1] = k end
    return ks
  end)()) do
    for k, o in ipairs(P.list(P.get(places[place], "objects"))) do
      if not P.T(P.get(o, "trail")) then
        local ref = P.T(P.get(o, "id")) and (place .. "/" .. P.str(o.id)) or nil
        local base = P.str(o.template):match("([^\\]*)$")
        local stem = base:match("^(.*)%.[^.]*$") or base
        local name = P.str(P.or_(P.get(o, "display"), P.get(o, "id"), stem))
        local uses = {}
        for _, ns in ipairs(steps) do if ref and IC.names(ns[2], ref) then uses[#uses + 1] = ns end end
        local list = QS.is_actor(o) and people or things
        list[#list + 1] = {name = P.replace(name, "_", " "), place = place, index = k, ref = ref, uses = uses}
      end
    end
  end
  -- the things of the world the project took (a chest of the game, a candle of an inn - 11.11.: "0 things" while
  -- the quest used four of them)
  local WP = require("conjunction.world_pick")
  local wo = b.ed.project.meta and b.ed.project.meta.world_objects
  local ids = {}
  for id in pairs(Y.is_map(wo) and wo or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local ref = WP.PREFIX .. id
    local uses = {}
    for _, ns in ipairs(steps) do if IC.names(ns[2], ref) then uses[#uses + 1] = ns end end
    local name = WP.readable(P.str(P.or_(P.get(wo[id], "name"), id)))
    things[#things + 1] = {name = name, place = "in the world", index = id, ref = ref, uses = uses, world = true}
  end
  local items = {}
  for _, r in ipairs(IC.quest_item_refs(q)) do
    local uses = {}
    for _, ns in ipairs(steps) do if IC.names(ns[2], r) then uses[#uses + 1] = ns end end
    items[#items + 1] = {ref = r, uses = uses}
  end
  return people, things, items
end

function CW:counts()
  local people, things, items = self:gather()
  return #people, #things, #items
end

-- --- the pieces (leaves of ui/qw.lua with the sizes Qt gives them)
local function label(text, colour, px, bold, opts)
  opts = opts or {}
  local indent = opts.indent and Q.label_indent(px, bold) or 0
  local pad = opts.pad or {0, 0, 0, 0}             -- {top, bottom}
  return W.leaf{w = Q.hint_w(text, px, bold) + indent, h = Q.line_h(px, bold) + pad[1] + pad[2], min_w = opts.min_w,
                draw = function(_, r)
    local ch = r.h - pad[1] - pad[2]
    D.clip(r.x, r.y, r.w, r.h, function()
      Q.text(r.x + indent // 2, r.y + pad[1] + Q.vcenter(ch, Q.line_h(px, bold)), colour, text, px, bold, opts.bg)
    end)
  end}
end

-- QToolButton#step / #danger (padding 1px 6px / 8px, a 1 px border; its size hint: the text and two spaces, the
-- padding, the border, 3 more)
local function tool(id, text, fn, danger)
  local padx = danger and 8 or 6
  local px = danger and 12 or 11                   -- (#danger has no font of its own: #cast's 12 px, inherited)
  local w = Q.hint_w(text, px) + 2 * Q.text_w(" ", px) + 2 * padx + 2 + 3
  local h = Q.line_h(px) + 2 + 2 + 3
  return W.leaf{w = w, h = h, hpol = "minimum", vpol = "fixed", draw = function(_, r)
    local clicked, hovered = CT.hit_box(id, r)
    if hovered then CW.on_button = true end
    local bg, edge, fg = C.step, hovered and C.step_hover or C.step_edge, C.text
    if danger then bg, edge, fg = C.danger, C.danger_edge, C.white end
    Q.frame(r.x, r.y, r.w, r.h, bg, edge)
    local tw = Q.text_w(text, px)
    Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(px)), fg, text, px, false, bg)
    if hovered then CT.tip(id, danger and "qb.own_remove" or "cast.step") end
    if clicked and fn then fn() end
  end}
end

-- QToolButton#icon: 16 px, padding 2, #3a3a3e under the mouse
local function icon(id, name, fn, tipkey)
  return W.leaf{w = 23, h = 23, vpol = "fixed", draw = function(_, r)
    local clicked, hovered = CT.hit_box(id, r)
    if hovered then
      CW.on_button = true
      D.fill(r.x, r.y, r.w, r.h, C.icon_hover)
    end
    Q.draw_icon(name, 0xcfcfcfff, 16, r.x + (r.w - 16) // 2, r.y + (r.h - 16) // 2)
    if hovered and tipkey then CT.tip(id, tipkey) end
    if clicked and fn then fn() end
  end}
end

-- the step numbers, each a button that opens its card (an action has no number: its kind)
function CW:steps(uses, id)
  local items = {}
  if #uses == 0 then items[1] = label("Not in a step", C.grey, 11, false, {bg = C.row}) end
  for k, ns in ipairs(uses) do
    local n = ns[1]
    local text = math.type(n) and ("step " .. n) or P.str(n)
    items[#items + 1] = tool(id .. ".step" .. k, text, function() self:open_step(ns[2]) end)
  end
  items[#items + 1] = W.stretch(1)
  return W.hbox({margins = {0, 0, 0, 0}, spacing = 4}, items)
end

local function row_frame(_id, top, steps, go)
  return W.widget(W.vbox({margins = {8, 5, 6, 5}, spacing = 3}, {W.hbox({margins = {0, 0, 0, 0}, spacing = 3}, top),
                                                                    steps}), {
    margins = {1, 1, 1, 1},
    draw = function(_, r)
      Q.frame(r.x, r.y, r.w, r.h, C.row, C.row_edge)
      CW.on_button = false
    end,
    -- (a double click on the row, not on one of its buttons: there - QFrame.mouseDoubleClickEvent)
    after = function(_, r)
      if go and not CW.on_button and CT.over(r) and w3.ui.mouse_double and w3.ui.mouse_double(1) then go() end
    end,
  })
end

function CW:row(id, name, where, uses, go)
  local grey = label(where, C.grey, 11, false, {bg = C.row})
  grey.stretch = 1
  local top = {label(name, C.name, 12, true, {bg = C.row}), grey}
  if go then top[#top + 1] = icon(id .. ".go", "crosshair", go, "cast.go") end
  return row_frame(id, top, self:steps(uses, id), go)
end

function CW:own_row(id, iid, uses)
  local b = self.board
  local q = b:quest()
  local it = P.get(P.or_(P.get(q, "items"), Y.map()), iid) or Y.map()
  local fid = "cast.own." .. iid
  local now = P.str(P.or_(P.get(it, "name"), iid))
  local field = W.leaf{w = 17 * Q.text_w("x") + 16, h = CT.edit_h(), min_w = 42, hpol = "expanding", vpol = "fixed",
                       draw = function(_, r)
    local st = CT.state(fid)
    local _, t, enter = CT.edit(fid, r.x, r.y, r.w, st.typed or now, {tip = "qb.own_name", h = r.h,
                                                                       style = b.panel.EDIT_STYLE})
    st.typed = t
    local focused = CT.focus == fid
    if (st.had and not focused) or enter then
      local v = PYS.strip(t)
      st.typed = nil
      if v ~= "" and v ~= P.str(P.get(it, "name")) then require("conjunction.ui.quest_card").set_in(b, it, "name", v, false) end
    end
    if not focused and not enter then st.typed = nil end
    st.had = focused
  end}
  field.stretch = 1
  local rm
  if self.asking == iid then
    local text = #uses > 0 and string.format("Remove from %d step%s?", #uses, #uses ~= 1 and "s" or "") or "Remove?"
    rm = tool(id .. ".remove", text, function() self:remove(iid) end, true)
  else
    rm = icon(id .. ".bin", "trash-2", function() self.asking = iid end, "qb.own_remove")
  end
  return row_frame(id, {field, label("Made for this quest", C.grey, 11, false, {bg = C.row}), rm}, self:steps(uses, id))
end

function CW:remove(iid)
  self.asking = nil
  IC.drop_item(self.board:quest(), iid)
  self.board:save()
end

-- the step's card on the Quest tab (the panel comes up there)
function CW:open_step(st)
  local b = self.board
  local nid = P.T(P.get(b:quest(), "nodes")) and b:node_of(st) or nil
  local panel = b.panel
  if panel then
    panel.tab = 2
    panel.shown = true
  end
  if nid ~= nil then b:graph_picked(nid) end
end

-- the lists, as fill() builds them
function CW:tree()
  local b = self.board
  local q = b:quest()
  local people, things, items = self:gather()
  local want = PYS.lower(PYS.strip(self.filter))
  local assets = b.ed.assets and b.ed:assets() or nil
  local out = {}
  local function head(title, n)
    out[#out + 1] = label(title .. "  " .. n, C.kind, 11, true, {indent = true, pad = {8, 2}, bg = C.bg})
  end
  for _, part in ipairs({{"PEOPLE", people}, {"THINGS", things}}) do
    local shown = {}
    for _, r in ipairs(part[2]) do
      if want == "" or PYS.lower(r.name):find(want, 1, true) or PYS.lower(r.place):find(want, 1, true) then
        shown[#shown + 1] = r
      end
    end
    head(part[1], #shown)
    for _, r in ipairs(shown) do
      local extra = ""
      if part[1] == "THINGS" and r.ref then
        local put = IC.puts_in(q, r.ref)
        if #put > 0 then
          local names = {}
          for _, x in ipairs(put) do names[#names + 1] = IC.item_label(x[2], q, assets) end
          extra = "holds " .. table.concat(names, ", ")
        end
      end
      out[#out + 1] = self:row("cast." .. r.place .. "." .. r.index, r.name,
                               r.place .. (extra ~= "" and ("  ·  " .. extra) or ""), r.uses,
                               function()
                                 if r.world then b.ed:locate_world(r.ref) else b.ed:jump_to(r.place, r.index) end
                               end)
    end
  end
  local shown = {}
  for _, r in ipairs(items) do
    if want == "" or PYS.lower(IC.item_label(r.ref, q, assets)):find(want, 1, true) then shown[#shown + 1] = r end
  end
  head("ITEMS", #shown)
  for k, r in ipairs(shown) do
    if r.ref:sub(1, 4) == "own:" then
      out[#out + 1] = self:own_row("cast.item" .. k, r.ref:sub(5), r.uses)
    else
      out[#out + 1] = self:row("cast.item" .. k, IC.item_label(r.ref, q, assets), "the game's", r.uses)
    end
  end
  out[#out + 1] = W.stretch(1)
  return W.widget(W.vbox({margins = {0, 0, 4, 0}, spacing = 4}, out)), #people, #things, #items
end

function CW:frame(r)
  local b = self.board
  D.fill(r.x, r.y, r.w, r.h, C.bg)
  local x, y, w = r.x + 4, r.y + 2, r.w - 8
  local body, np, nt, ni = self:tree()
  local text = string.format("%d people, %d things, %d items", np, nt, ni)
  Q.text(x, y, C.head, text, 14, true, C.bg)
  y = y + Q.line_h(14, true) + 6
  local eh = CT.edit_h()
  local _, f = CT.edit("cast.filter", x, y, w, self.filter, {placeholder = "filter", style = b.panel.EDIT_STYLE})
  self.filter = f
  y = y + eh + 6
  local area = {x = x, y = y, w = w, h = r.y + r.h - 4 - y}
  -- (QScrollArea, resizable, no horizontal bar: the body as wide as the room, a bar when it is higher)
  local min_w, min_h = W.min(body)
  local need = math.max(min_h, W.hfw(body, math.max(area.w, min_w)))
  local bar = need > area.h
  local vw = bar and area.w - 10 or area.w
  local bh = math.max(area.h, math.max(min_h, W.hfw(body, math.max(vw, min_w))))
  local sb = self.bar
  sb.page = area.h
  IV.range(sb, bh - area.h)
  local hovered = CT.over({x = area.x, y = area.y, w = vw, h = area.h})
  local _, _, wheel = w3.ui.mouse()
  if hovered and wheel ~= 0 then IV.set(sb, sb.value - math.floor(wheel * 3 * 20 + 0.5)) end
  W.place(body, area.x, area.y - sb.value, math.max(vw, min_w), bh)
  D.clip(area.x, area.y, vw, area.h, function() W.draw(body) end)
  if bar then
    SBAR.draw(self.bar_state, "cast.bar", sb, {x = area.x + vw, y = area.y, w = 10, h = area.h}, "v",
              function(id, rr) return CT.hit_box(id, rr) end)
  end
end

return CW
