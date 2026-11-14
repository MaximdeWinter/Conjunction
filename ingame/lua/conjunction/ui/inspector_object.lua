-- The inspector's part for an object of the project selected in the world (catalog_view.Inspector.show_object): its
-- name, where it stands, its look, what a person does and the name shown above them; for containers and people what
-- is in them - the quest's items, the random loot, what the game says is in it now. Every change at once, no apply.
-- Below the template's own part (ui/inspector.lua: "Place another"). Still to come: the quest's lines about the object
-- (steps_about, puts_in: step 5), the look window, the item and loot windows (item_chooser.py), plug-in sections.
--   require("conjunction.ui.inspector_object")(INS)     adds INS:show_object(place, index) and the drawing
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local L = require("conjunction.ui.layout")
local CT = require("conjunction.ui.controls")
local PIC = require("conjunction.ui.pictures")
local QP = require("conjunction.ui.qtpaint")
local H = require("conjunction.hashlib")
local S = require("conjunction.pystr")
local J = require("conjunction.json")
local Y = require("conjunction.yaml")
local CAT = require("conjunction.catalog")
local QUEST = require("conjunction.quest")
local NA = require("conjunction.npc_actions")
local LC = require("conjunction.look_chooser")
local P = require("conjunction.project")
local D = w3.ui.draw

local function rgba(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
local C = {
  head = rgba("#f0f0f0"), label = rgba("#999999"), item = rgba("#dddddd"), count = rgba("#eeeeee"),
  none = rgba("#777777"), off = rgba("#888888"), tag_text = rgba("#cfcfcf"), tag_bg = rgba("#262629"),
  tag_edge = rgba("#555555"), tag_hover = rgba("#aaaaaa"), on_bg = rgba("#4b4b50"), on_edge = rgba("#c8c8c8"),
  dot = rgba("#666666"), dot_bg = rgba("#232326"), dot_edge = rgba("#333333"), add_text = rgba("#bbbbbb"),
  add_bg = rgba("#1f1f22"), add_edge = "666666", add_hover = "999999", icon_hover = rgba("#ffffff", 20),
}
local function truthy(v)
  return not (v == nil or v == false or v == Y.null or v == 0 or v == "" or (type(v) == "table" and next(v) == nil))
end
local function str(v) if v == nil or v == Y.null then return "" end return tostring(v) end
local function list_of(v)
  if type(v) == "table" then return v end
  if v == nil or v == Y.null or v == "" then return {} end
  local ok, t = pcall(J.decode, v)
  return (ok and type(t) == "table") and t or {}
end
local function has(o, k) return o[k] ~= nil end
local function call_ed(ed, name, ...)
  local f = ed[name]
  if type(f) == "function" then return f(ed, ...) end
end
local function split_on(s, sep)
  local out, i = {}, 1
  while true do
    local a = s:find(sep, i, true)
    if not a then out[#out + 1] = s:sub(i) break end
    out[#out + 1] = s:sub(i, a - 1)
    i = a + #sep
  end
  return out
end

-- item_chooser.loot_title: '_interrior inn_everywhere but not nml' -> 'Interrior inn - everywhere but not nml'
local function loot_title(name)
  local t = S.strip(str(name), "_ ")
  local parts = {}
  for _, p in ipairs(split_on(t, "_")) do
    local q = S.strip(p)
    if q ~= "" then parts[#parts + 1] = q end
  end
  if #parts > 0 then t = table.concat(parts, " - ") end
  return S.upper(S.from_cps(S.cps(t), 1, 1)) .. S.from_cps(S.cps(t), 2, #S.cps(t))
end
-- item_chooser.item_label: an own item's name, a game item's label
local function item_label(ref, quest, assets)
  ref = str(ref)
  if ref:sub(1, 4) == "own:" then
    local it = ((quest or {}).items or {})[ref:sub(5)]
    return (it and str(it.name) ~= "") and str(it.name) or ref:sub(5)
  end
  local it = assets and assets:item(ref) or nil
  if it then
    local l = str(it.label) ~= "" and str(it.label) or str(it.name)
    if l ~= "" then return l end
  end
  return ref
end

-- the TAG chip's size (11 px, padding 1px 6px, a border)
local function tag_size(text)
  return Q.hint_w(text, 11) + 2 * Q.text_w(" ", 11) + 12 + 2 + 3, Q.line_h(11) + 2 + 2 + 3
end

return function(INS)
  INS.OBJ_C = C

  function INS:show_object(place, index)
    local ed = self.panel.ed
    local o = ((ed.project.places or {})[place] or {}).objects[index]
    self.obj = {place, index}
    local assets = self.panel.assets
    local row = assets and assets:template(o.template) or nil
    if not row then row = {path = S.lower(o.template), name = o.template, kind = "", tags = ""} end
    self:show_entry({type = "template", key = row.path, path = row.path, title = row.name, sub = CAT.caption(row.path),
                     row = row}, false, true)
    self.place_text, self.place_icon = "Place another", nil
    local ob = {o = o, row = row}
    self.ob = ob
    ob.id = str(o.id)
    ob.placeholder = (CAT.caption(o.template):gsub(" ", "_"))
    ob.vals = {}
    for k = 1, 3 do ob.vals[k] = (o.pos or {})[k] or 0.0 end
    for k = 1, 3 do ob.vals[3 + k] = (o.rot or {})[k] or 0.0 end
    ob.apps = list_of(row.appearances)
    ob.actor = QUEST.is_actor(o)
    ob.look = LC.label(str(o.appearance)) .. "  ..."
    ob.does = truthy(o.action) and NA.label(str(o.action):gsub("^.*/", "")) or "stands"
    ob.display = str(o.display)
    ob.contents = truthy(row.inventory)
    ob.template_loot = list_of(row.loot_defs)
    ob.asking = true
    ob.live = nil
    for k = 1, 6 do CT.state("panel.ins.num." .. k).sb = nil end
    if ob.contents then call_ed(ed, "ask_inventory") end
  end

  -- what the game says is in it now (items: {{name, n}} or nil - no answer)
  function INS:live_inventory(items, asking)
    if not self.ob then return end
    self.ob.asking = asking or false
    self.ob.live = items
  end

  function INS:loot_now(o)
    local ob = self.ob
    if has(o, "loot") then return str(o.loot) end
    if ob.actor then return "" end
    return ob.template_loot[1] and str(ob.template_loot[1]) or ""
  end

  -- --- the object box's layout (QVBoxLayout margins 0 4 0 4, spacing 6) for the content width cw ---
  local HEAD_H = 24                                 -- (_head: bold 12 px, margin-top 8)
  function INS:obj_parts(cw)
    local ob = self.ob
    local o = ob.o
    local parts = {}
    local function add(key, h, extra)
      local p = {key = key, h = h}
      for k, v in pairs(extra or {}) do p[k] = v end
      parts[#parts + 1] = p
    end
    add("head", HEAD_H, {text = "OBJECT"})
    -- the form (QGridLayout: margins 0, 6 across, 4 down; the three number columns stretch alike)
    local labels = {{0, "name"}, {1, "position"}, {2, "turn"}}
    local cells = {}
    local function lab(r, text)
      local w = L.widget(Q.hint_w(text, 12), Q.line_h(12), "preferred", "preferred")
      cells[#cells + 1] = {row = r, col = 0, w = w.w, h = w.h, what = "label", text = text}
    end
    local function field(r, key, h, cols)
      local w = L.widget(118, h, "expanding", "fixed")
      cells[#cells + 1] = {row = r, col = 1, cols = cols or 3, w = w.w, h = w.h, what = key}
    end
    lab(0, "name")
    field(0, "o_id", 31)
    for i, name in ipairs({"x", "y", "z", "roll", "pitch", "yaw"}) do
      local w = L.widget(Q.hint_w(name, 12) + 3 + 102, 35, "ignored", "fixed")
      cells[#cells + 1] = {row = 1 + (i - 1) // 3, col = 1 + (i - 1) % 3, w = w.w, h = w.h, what = "num", k = i,
                           name = name}
    end
    lab(1, "position")
    lab(2, "turn")
    if #ob.apps > 0 then
      lab(3, "look")
      local bw = Q.hint_w(ob.look) + 22
      local w = L.widget(bw, 29, "minimum", "fixed")
      cells[#cells + 1] = {row = 3, col = 1, cols = 3, w = w.w, h = w.h, what = "look"}
    end
    if ob.actor then
      lab(4, "does")
      local tw, th = tag_size(ob.does)
      local w = L.widget(tw, th, "fixed", "fixed")
      cells[#cells + 1] = {row = 4, col = 1, cols = 3, w = w.w, h = w.h, what = "does"}
      lab(5, "Shown as")
      field(5, "display", 31)
    end
    local opts = {hspacing = 6, vspacing = 4, col_stretch = {[1] = 1, [2] = 1, [3] = 1}}
    local _, gh = L.grid_size(cells, opts)
    add("form", gh, {cells = cells, opts = opts})
    if ob.contents then
      add("head", HEAD_H, {text = ob.actor and "CARRIES" or "CONTENTS"})
      add("label", Q.line_h(12), {text = ob.actor and "Drops when killed" or "Quest items"})
      local inv = o.inventory or {}
      if #inv == 0 then add("none", Q.line_h(12), {text = "None yet"})
      else add("items", #inv * 30 + (#inv - 1) * 2, {inv = inv}) end
      add("add", 27)
      local own = ob.actor and "" or (ob.template_loot[1] and str(ob.template_loot[1]) or "")
      local table_name = has(o, "loot") and str(o.loot) or own
      local on = table_name ~= ""
      local lh = 22 + 2 + (on and 22 or Q.line_h(12))
      local name = self:loot_now(o)
      local lt = name ~= "" and self.panel.assets and self.panel.assets:loot(name) or nil
      local strip
      if lt then
        local items = {}
        for _, e in ipairs(lt.entries or {}) do items[#items + 1] = {e[1], e[3]} end
        strip = items
      end
      local h = 8 + lh
      if strip then h = h + 3 + Q.line_h(11) + 3 + self:strip_h(strip, cw, 16) end
      add("loot", h, {own = own, table = table_name, on = on, strip = strip})
      add("now_head", HEAD_H, {text = "In the game now"})
      if ob.live == nil then add("now_text", Q.line_h(12), {text = ob.asking and "Asking the game..." or "No answer from the game"})
      else add("now", self:strip_h(ob.live, cw, 24, "empty"), {items = ob.live}) end
    end
    local h = 4
    for i, p in ipairs(parts) do h = h + p.h + (i > 1 and 6 or 0) end
    return parts, h + 4
  end

  -- IconStrip: 30 x 30 icons in rows that wrap (3 apart), more than limit: "+ n"
  function INS:strip_places(items, w, limit, empty)
    local out = {}
    if #items == 0 then
      out[1] = {kind = "empty", text = empty or "-", w = Q.hint_w(empty or "-", 12), h = Q.line_h(12)}
    end
    for i = 1, math.min(limit, #items) do out[#out + 1] = {kind = "icon", item = items[i], w = 30, h = 30} end
    if #items > limit then
      local t = string.format("+ %d", #items - limit)
      out[#out + 1] = {kind = "more", text = t, w = Q.hint_w(t, 12), h = Q.line_h(12)}
    end
    local x, y, line = 0, 0, 0
    for _, it in ipairs(out) do
      if x + it.w > w - 1 and line > 0 then x, y, line = 0, y + line + 3, 0 end
      it.x, it.y = x, y
      x = x + it.w + 3
      line = math.max(line, it.h)
    end
    return out, y + line
  end
  function INS:strip_h(items, w, limit, empty)
    local _, h = self:strip_places(items, w, limit, empty)
    return h
  end

  -- an item's icon as the strip shows it (_count_icon: the picture made to fill 30 x 30, the count in its corner);
  -- no picture: "·" on #232326 in a #333 frame. opaque: drawn into an opaque widget (a list: ClearType text)
  function INS:draw_icon_label(x, y, name, n, opaque)
    local assets = self.panel.assets
    local it = assets and assets:item(name) or nil
    local file = it and assets:icon(it) or nil
    if file and not pcall(PIC.size, file) then file = nil end
    local tip = (it and str(it.label) ~= "" and str(it.label) or str(name))
    if n ~= nil and n ~= "" and n ~= 1 and n ~= "1" then tip = tip .. "  x" .. tostring(n) end
    local _, hv = self:hit("ins.icon." .. tostring(name) .. "." .. x .. "." .. y, {x = x, y = y, w = 30, h = 30})
    if hv then CT.tip("panel.ins.icon", {"", tip}) end
    if not file then
      D.fill(x, y, 30, 30, C.dot_edge)
      D.fill(x + 1, y + 1, 28, 28, C.dot_bg)
      local s = "\u{b7}"
      Q.text(x + (30 - Q.text_w(s, 13)) // 2, y + Q.vcenter(30, Q.line_h(13)), C.dot, s, 13, false, C.dot_bg)
      return
    end
    local count = math.type(n) == "integer" and n > 1 and n or nil
    local id, tw, th = PIC.texture(file, 30, 30)
    if id then D.image(id, x, y, 30, 30) end                   -- (drawn into the 30 x 30 square: stretched)
    if count then
      -- (its count: bold 10 px at the bottom right, a shadow 1 px below and right)
      local s = tostring(count)
      local lh = Q.line_h(10, true)
      local tx = x + 29 - Q.text_w(s, 10, true)
      local ty = y + 18 + 12 - lh
      local was = Q.translucent
      Q.translucent = not opaque
      Q.text(tx + 1, ty + 1, 0x000000c8, s, 10, true)
      Q.text(tx, ty, rgba("#f0f0f0"), s, 10, true)
      Q.translucent = was
    end
    local _ = {tw, th}
  end

  -- bg: an opaque widget's background under it (the loot list's rows)
  function INS:draw_strip(r, items, limit, empty, bg)
    local places = self:strip_places(items, r.w, limit, empty)
    for _, it in ipairs(places) do
      if it.kind == "icon" then self:draw_icon_label(r.x + it.x, r.y + it.y, it.item[1], it.item[2], bg ~= nil)
      elseif it.kind == "empty" then Q.text(r.x + it.x, r.y + it.y, C.none, it.text, 12, false, bg)
      else Q.text(r.x + it.x, r.y + it.y, C.off, it.text, 12, false, bg) end
    end
  end

  -- a TAG tool button (checked: the loot row's segments) -> clicked
  function INS:tag(id, b, text, checked, tip)
    local clicked, hv = self:hit(id, b)
    local bg, edge, fg = C.tag_bg, C.tag_edge, C.tag_text
    if checked then bg, edge, fg = C.on_bg, C.on_edge, T.WHITE
    elseif hv then edge, fg = C.tag_hover, T.WHITE end
    D.fill(b.x, b.y, b.w, b.h, edge)
    D.fill(b.x + 1, b.y + 1, b.w - 2, b.h - 2, bg)
    Q.text(b.x + (b.w - Q.text_w(text, 11)) // 2, b.y + Q.vcenter(b.h, Q.line_h(11)), fg, text, 11, false, bg)
    if hv and tip then CT.tip("panel." .. id, tip) end
    return clicked
  end

  function INS:draw_obj(r)
    local ob = self.ob
    local o = ob.o
    local ed = self.panel.ed
    local parts = self:obj_parts(r.w)
    local y = r.y + 4
    for i, p in ipairs(parts) do
      if i > 1 then y = y + 6 end
      local b = {x = r.x, y = y, w = r.w, h = p.h}
      if p.key == "head" or p.key == "now_head" then
        -- (a label with a box - its margin-top - gets QLabel's indent: half the advance of 'x' in)
        local bold = p.key == "head"
        Q.text(b.x + Q.text_w("x", 12, bold) // 2, b.y + 8, bold and C.head or C.label, p.text, 12, bold)
      elseif p.key == "label" then
        Q.text(b.x, b.y, C.label, p.text, 12)
      elseif p.key == "none" or p.key == "now_text" then
        Q.text(b.x, b.y, C.none, p.text, 12)
      elseif p.key == "form" then
        self:draw_form(b, p)
      elseif p.key == "items" then
        self:draw_items(b, p.inv)
      elseif p.key == "add" then
        self:draw_add(b)
      elseif p.key == "loot" then
        self:draw_loot(b, p)
      elseif p.key == "now" then
        self:draw_strip(b, p.items, 24, "empty")
      end
      y = y + p.h
    end
    local _ = ed
  end

  -- a field left (editingFinished: Enter, or the focus gone)
  local function finished(self, id, enter)
    self.focus_was = self.focus_was or {}
    local was = self.focus_was[id]
    local now = CT.focus == "panel." .. id
    self.focus_was[id] = now
    return enter or (was and not now)
  end

  function INS:draw_form(b, p)
    local ob = self.ob
    local o = ob.o
    local ed = self.panel.ed
    local placed = L.grid(p.cells, b.x, b.y, b.w, b.h, p.opts)
    local PN = require("conjunction.ui.panel")
    for i, c in ipairs(p.cells) do
      local pr = placed[i]
      if c.what == "label" then
        Q.text(pr.x, pr.y + Q.vcenter(pr.h, Q.line_h(12)), C.label, c.text, 12)
      elseif c.what == "o_id" then
        local _, text, enter = CT.edit("panel.ins.o_id", pr.x, pr.y, pr.w, ob.id,
                                       {placeholder = ob.placeholder, style = PN.EDIT_STYLE, h = 31, tip = "obj.name"})
        ob.id = text
        if finished(self, "ins.o_id", enter) then
          local name = P.ascii_id(ob.id)
          if name ~= "" then
            ed.project:name_object(self.obj[1], self.obj[2], name)
            ob.id = name
          end
        end
      elseif c.what == "num" then
        local k = c.k
        local x = pr.x
        Q.text(x, pr.y + Q.vcenter(pr.h, Q.line_h(12)), rgba("#9a9a9a"), c.name, 12)
        x = x + Q.hint_w(c.name, 12) + 3
        local id = "panel.ins.num." .. k
        local _, v = CT.spin(id, x, pr.y, ob.vals[k], {min = -100000, max = 100000, decimals = k <= 3 and 2 or 1,
                                                    step = k <= 3 and 0.1 or 5.0, buttons = false,
                                                    w = pr.x + pr.w - x, fg = T.BRIGHT})
        ob.vals[k] = v
        local enter = CT.focus == id and (w3.ui.pressed("Enter") or w3.ui.pressed("KeypadEnter"))
        if finished(self, "ins.num." .. k, enter) then
          local vv = ob.vals
          if ed.set_selected_transform then ed:set_selected_transform({vv[1], vv[2], vv[3]}, {vv[4], vv[5], vv[6]}) end
        end
      elseif c.what == "look" then
        local clicked, hv, held = self:hit("ins.o_look", pr)
        Q.button(pr.x, pr.y, pr.w, pr.h, ob.look, {hover = hv or held, pressed = held and hv, fg = T.BUTTON_TEXT})
        if hv then CT.tip("panel.ins.o_look", "obj.look") end
        if clicked and self.panel.choose_look then
          self.panel:choose_look(o.template, str(o.appearance), function(app) self:set_look(app) end, ob.speaks)
        end
      elseif c.what == "does" then
        if self:tag("ins.does", pr, ob.does, false, "obj.does") then self:does_menu(pr) end
      elseif c.what == "display" then
        local _, text, enter = CT.edit("panel.ins.display", pr.x, pr.y, pr.w, ob.display,
                                       {placeholder = "The game's name", style = PN.EDIT_STYLE, h = 31, tip = "obj.display"})
        ob.display = text
        if finished(self, "ins.display", enter) then
          local t = S.strip(ob.display)
          if t ~= str(o.display) then
            ed.project:set_object(self.obj[1], self.obj[2], {"display", t ~= "" and t or Y.null})
          end
        end
      end
    end
  end

  function INS:set_look(appearance)
    local ob = self.ob
    ob.look = LC.label(str(appearance)) .. "  ..."
    local ed = self.panel.ed
    if ed.set_object_look then ed:set_object_look(appearance) end
  end

  -- the person's action: "stands", or one of the game's by posture (a menu of groups)
  function INS:does_menu(anchor)
    local ob = self.ob
    local items = {{text = "stands", action = function() self:set_does(nil) end}}
    for _, group in ipairs(NA.actions(NA.gender_of(ob.o.template, self.panel.assets))) do
      local sub = {}
      local seen = {}
      for _, entry in ipairs(group[2]) do
        if not seen[entry[2]] then
          seen[entry[2]] = true
          sub[#sub + 1] = {text = entry[2], action = function() self:set_does(entry[1]) end}
        end
      end
      items[#items + 1] = {group = group[1], items = sub}
    end
    local pn = self.panel
    CT.IM.open("panel.ins.does", anchor, items, pn.lay and pn.lay.frame or anchor,
               {bg = require("conjunction.ui.panel").C.inline_bg})
  end
  function INS:set_does(action)
    local ed = self.panel.ed
    ed.project:set_object(self.obj[1], self.obj[2], {"action", action or Y.null})
    self:show_object(self.obj[1], self.obj[2])
  end

  -- the quest's items in it: [icon] name [-] n [+] [trash], 3 apart, rows of 30, 2 between
  function INS:draw_items(b, inv)
    local ed = self.panel.ed
    local quest = (ed.project.meta or {}).quest or {}
    local y = b.y
    for k, entry in ipairs(inv) do
      local name, n = str(entry.item), math.tointeger(tonumber(entry.count or 1)) or 1
      local row = L.row({{hint = 30, min = 30, max = 30, cross = 30, cross_max = 30},
                         {hint = 0, min = 0, stretch = 1, cross = 30, cross_max = 30},
                         {hint = 22, min = 22, max = 22, cross = 22, cross_max = 22},
                         {hint = 22, min = 22, max = 22, cross = 30, cross_max = 30},
                         {hint = 22, min = 22, max = 22, cross = 22, cross_max = 22},
                         {hint = 23, min = 23, max = 23, cross = 23, cross_max = 23}}, b.x, y, b.w, 30, {spacing = 3})
      self:draw_icon_label(row[1].x, row[1].y, name, nil)
      local lab = row[2]
      local text = item_label(name, quest, self.panel.assets)
      D.clip(lab.x, lab.y, lab.w, lab.h, function()
        Q.text(lab.x, lab.y + Q.vcenter(lab.h, Q.line_h(12)), C.item, text, 12)
      end)
      if self:tag("ins.minus." .. k, row[3], "-", false, "ins.count") then
        if ed.set_object_item then ed:set_object_item(name, math.max(0, n - 1)) end
      end
      local c = row[4]
      local s = tostring(n)
      Q.text(c.x + (c.w - Q.text_w(s, 12, true)) // 2, c.y + Q.vcenter(c.h, Q.line_h(12, true)), C.count, s, 12, true)
      if self:tag("ins.plus." .. k, row[5], "+", false, "ins.count") then
        if ed.set_object_item then ed:set_object_item(name, n + 1) end
      end
      local t = row[6]
      local clicked, hv = self:hit("ins.trash." .. k, t)
      if hv then D.fill(t.x, t.y, t.w, t.h, C.icon_hover) w3.ui.cursor("hand") CT.tip("panel.ins.trash", "ins.remove_item") end
      Q.draw_icon_file(hv and "trash-2_ffffff_16" or "trash-2_cfcfcf_16", t.x + (t.w - 16) // 2, t.y + (t.h - 16) // 2)
      if clicked and ed.set_object_item then ed:set_object_item(name, 0) end
      y = y + 30 + 2
    end
  end

  -- "+ Add item": a dashed frame (QStyleSheetStyle: 1 px dashed is Qt's dotted line, edge by edge)
  function INS:draw_add(b)
    local clicked, hv = self:hit("ins.add", b)
    local edge = hv and C.add_hover or C.add_edge
    local key = table.concat({b.w, b.h, edge}, "|")
    self.add_pics = self.add_pics or {}
    local t = self.add_pics[key]
    if not t then
      local w, h = b.w, b.h
      -- (antialiased, as QStyleSheetStyle draws borders: each dot half on two rows where it is not clipped)
      local cmds = {"fill " .. QP.hex(C.add_bg), "aa 1", string.format("pen %sff 1 0 0 3", edge),
                    string.format("linef 0 %d %d %d", h - 1, w - 1, h - 1),
                    string.format("linef %d 0 %d %d", w - 1, w - 1, h - 1),
                    string.format("linef 0 0 0 %d", h - 1),
                    string.format("linef 0 0 %d 0", w - 1)}
      local dir = (os.getenv("TEMP") or ".") .. "\\cj_core"
      if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
      local out = dir .. "\\add_" .. H.md5(key) .. ".png"
      QP.paint(out, w, h, cmds)
      t = {id = w3.ui.image_load(out)}
      self.add_pics[key] = t
    end
    if t.id then D.image(t.id, b.x, b.y, b.w, b.h) end
    local s = "+ Add item"
    local fg = hv and rgba("#eeeeee") or C.add_text
    Q.text(b.x + (b.w - Q.text_w(s)) // 2, b.y + 5 + (b.h - 10 - Q.line_h()) // 2, fg, s, T.FONT, false, C.add_bg)
    if hv then CT.tip("panel.ins.add", "obj.add_item") end
    if clicked and self.panel.choose_item then
      local o = self.ob.o
      local name = str(o.id) ~= "" and str(o.id) or (str(o.template):gsub("^.*[\\/]", ""):gsub("%.[^.]*$", ""))
      local label = name:gsub("_", " ")
      self.panel:choose_item(function(ref) self.panel.ed:set_object_item(ref, nil) end,
                             self.ob.actor and ("Give " .. label .. " an item") or ("Put into " .. label),
                             {key = "inventory:" .. self.obj[1] .. "/" .. name, keep_open = true, action = "Add item"})
    end
  end

  -- the random loot (item_chooser.loot_row): [label] [On] [Off]; on: its table and Change (Its own when another
  -- was chosen), "May contain" and its items; off: what is left
  function INS:draw_loot(b, p)
    local ob = self.ob
    local o = ob.o
    local y = b.y + 8
    local label = ob.actor and "Loot when killed" or "Random loot"
    local lw = Q.hint_w(label, 12)
    Q.text(b.x, y + Q.vcenter(22, Q.line_h(12)), C.label, label, 12)
    local x = b.x + lw + 3
    local on_w = tag_size("On")
    local off_w = tag_size("Off")
    if self:tag("ins.loot_on", {x = x, y = y, w = on_w, h = 22}, "On", p.on,
                ob.actor and "loot.actor_on" or "loot.on") then
      if p.own ~= "" then self:set_loot(nil) else self:loot_window() end
    end
    x = x + on_w + 3
    if self:tag("ins.loot_off", {x = x, y = y, w = off_w, h = 22}, "Off", not p.on,
                ob.actor and "loot.actor_off" or "loot.off") then
      self:set_loot("")
    end
    y = y + 22 + 2
    if p.on then
      local items = {{hint = 0, min = 0, stretch = 1, cross = 22, cross_max = 22}}
      local own_btn = has(o, "loot") and p.own ~= ""
      if own_btn then
        local w = tag_size("Its own")
        items[#items + 1] = {hint = w, min = w, max = w, cross = 22, cross_max = 22}
      end
      local cw = tag_size("Change")
      items[#items + 1] = {hint = cw, min = cw, max = cw, cross = 22, cross_max = 22}
      local row = L.row(items, b.x, y, b.w, 22, {spacing = 4})
      local n = row[1]
      local title = loot_title(p.table)
      D.clip(n.x, n.y, n.w, n.h, function()
        Q.text(n.x, n.y + Q.vcenter(n.h, Q.line_h(12)), C.item, title, 12)
      end)
      local _, hv = self:hit("ins.loot_name", n)
      if hv then CT.tip("panel.ins.loot_name", {"", p.table}) end
      local k = 2
      if own_btn then
        if self:tag("ins.loot_own", row[k], "Its own", false, "loot.own") then self:set_loot(nil) end
        k = k + 1
      end
      if self:tag("ins.loot_change", row[k], "Change", false, "loot.change") then self:loot_window() end
      y = y + 22
    else
      Q.text(b.x, y, C.off, ob.actor and "Only what they carry" or "Only the quest items", 12)
      y = y + Q.line_h(12)
    end
    if p.strip then
      y = y + 3
      Q.text(b.x, y, C.none, "May contain", 11)
      y = y + Q.line_h(11) + 3
      self:draw_strip({x = b.x, y = y, w = b.w}, p.strip, 16)
    end
  end
  function INS:set_loot(name)
    local ed = self.panel.ed
    if ed.set_object_loot then ed:set_object_loot(name) end
  end
  function INS:loot_window()
    local o = self.ob.o
    local name = str(o.id) ~= "" and str(o.id) or (str(o.template):gsub("^.*[\\/]", ""):gsub("%.[^.]*$", ""))
    if self.panel.choose_loot then
      self.panel:choose_loot(function(n) self:set_loot(n) end, "Random loot for " .. name:gsub("_", " "),
                             {key = "loot:" .. self.obj[1] .. "/" .. name, current = self:loot_now(o) ~= "" and self:loot_now(o) or nil})
    end
  end
end
