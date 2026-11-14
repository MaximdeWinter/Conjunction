-- The bodies of the item and loot windows (conjunction/item_chooser.py ItemChooser, LootChooser), in a ui/window.lua
-- window. The item window: this quest's items on top (quick), the game's items in a catalog of their own (its item
-- page, the tab bar away), a click shows one in an inspector beside it whose button (`action`) takes it - renamed, a
-- new item of this quest made from it; a double click takes it at once; `keep_open`: the window stays for more.
-- The loot window: every loot table (searched by its name and the items it gives) with a row of what it gives; a
-- click shows all of it on the right, "Use this loot" takes it.
--   IC.items(panel, win, then, keep_open, action)    IC.loot(panel, win, then, current)    -> a body: body:frame(r)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local L = require("conjunction.ui.layout")
local CT = require("conjunction.ui.controls")
local CV = require("conjunction.ui.catalog_view")
local INS = require("conjunction.ui.inspector")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local S = require("conjunction.pystr")
local Y = require("conjunction.yaml")
local P = require("conjunction.project")
local D = w3.ui.draw
local IC = {}

local function rgba(s) return (tonumber(s:sub(2), 16) << 8) | 255 end
local C = {field = rgba("#9a9a9a"), tag_text = rgba("#cfcfcf"), tag_bg = rgba("#262629"), tag_edge = rgba("#555555"),
           tag_hover = rgba("#aaaaaa"), list_bg = rgba("#1d1d20"), list_edge = rgba("#444444"), row_line = rgba("#2c2c30"),
           loot_title = rgba("#e8e8e8"), detail_title = rgba("#f0f0f0"), entry = rgba("#cccccc"), count = rgba("#888888"),
           detail_bg = rgba("#1e1e1e")}
IC.C = C

local function str(v) if v == nil or v == Y.null then return "" end return tostring(v) end
local function tag_size(text)
  return Q.hint_w(text, 11) + 2 * Q.text_w(" ", 11) + 12 + 2 + 3, Q.line_h(11) + 2 + 2 + 3
end

-- item_chooser.quest_item_refs: the quest's own items ("own:<id>") first, then the game's it uses, each once
function IC.quest_item_refs(q)
  q = q or {}
  local refs, seen = {}, {}
  local function add(r) if not seen[r] then seen[r] = true refs[#refs + 1] = r end end
  for _, iid in ipairs(Y.is_map(q.items) and Y.keys(q.items) or {}) do add("own:" .. iid) end
  local function walk(x)
    if type(x) ~= "table" then return end
    if Y.is_list(x) then
      for _, v in ipairs(x) do walk(v) end
      return
    end
    for _, k in ipairs(Y.is_map(x) and Y.keys(x) or {}) do
      local v = x[k]
      if k == "item" and type(v) == "string" and v ~= "" then add(v)
      elseif k == "items" and Y.is_list(v) then
        for _, i in ipairs(v) do if type(i) == "string" and i ~= "" then add(i) end end
      elseif k ~= "items" then walk(v) end
    end
  end
  for _, k in ipairs(Y.is_map(q) and Y.keys(q) or {}) do
    if k ~= "items" then walk(q[k]) end
  end
  return refs
end
-- item_chooser.numbered_steps: {{number, step}} - a graph's steps by the number the graph shows (an action has none:
-- its kind instead), the older form's steps in order and its paths'
function IC.numbered_steps(quest)
  local P = require("conjunction.py")
  if P.T(P.get(quest, "nodes")) then
    local QN = require("conjunction.quest_nodes")
    local shown = {}
    local ok, g = pcall(require("conjunction.quest_graph").build_nodes, quest)
    if ok and g then for nid, n in pairs(g.nodes) do shown[nid] = n.number end end
    local out = {}
    for _, nid in ipairs(QN.order(quest)) do
      local node = P.get(quest.nodes, nid)
      local st = P.get(node or Y.map(), "step")
      local kind = Y.is_map(st) and Y.keys(st)[1] or nil
      if kind and kind ~= "start" and kind ~= "end" and kind ~= "remember" then
        local n = shown[nid]
        out[#out + 1] = {P.T(n) and n or kind, st}
      end
    end
    return out
  end
  local out = {}
  for k, st in ipairs(P.list(P.get(quest, "steps"))) do out[#out + 1] = {k, st} end
  local paths = P.get(quest, "paths")
  for _, name in ipairs(Y.is_map(paths) and Y.keys(paths) or {}) do
    for k, st in ipairs(P.list(P.get(paths[name], "steps"))) do out[#out + 1] = {name .. " " .. k, st} end
  end
  return out
end

-- item_chooser._names: the value anywhere in x
function IC.names(x, value)
  if type(x) == "table" and x ~= Y.null then
    for _, k in ipairs(Y.is_map(x) and Y.keys(x) or {}) do if IC.names(x[k], value) then return true end end
    if not Y.is_map(x) then for _, v in ipairs(x) do if IC.names(v, value) then return true end end end
    return false
  end
  return x == value
end

-- item_chooser.puts_in: {{number, item ref}} what the quest puts into the container ref (place/id) - a Loot step's
-- items to take
function IC.puts_in(quest, ref)
  local P = require("conjunction.py")
  local out = {}
  for _, ns in ipairs(IC.numbered_steps(quest)) do
    local st = ns[2]
    local kind = Y.keys(st)[1]
    local a = st[kind]
    if kind == "loot" and Y.is_map(a) and P.get(a, "object") == ref then
      local its = {P.get(a, "item")}
      for _, x in ipairs(P.list(P.get(a, "more_items"))) do its[#its + 1] = x end
      for i = 1, #its + 1 do
        local it = its[i]
        if Y.is_map(it) then it = P.get(it, "item") end
        if P.T(it) then out[#out + 1] = {ns[1], it} end
      end
    end
  end
  return out
end

-- item_chooser.drop_item: the own item out of the quest - its entry and every place a step names it (an item field
-- empties, a list loses it) -> how many places were cleared
function IC.drop_item(quest, iid)
  local P = require("conjunction.py")
  local ref, count = "own:" .. iid, 0
  local function clear(x)
    if Y.is_map(x) then
      for _, k in ipairs(Y.keys(x)) do
        local v = x[k]
        if v == ref then
          x[k] = ""
          count = count + 1
        elseif Y.is_list(v) and IC.names_in(v, ref) then
          local keep = Y.list({})
          for _, i in ipairs(v) do if i ~= ref then keep[#keep + 1] = i end end
          x[k] = keep
          count = count + 1
        else
          clear(v)
        end
      end
    elseif Y.is_list(x) then
      for _, v in ipairs(x) do clear(v) end
    end
  end
  local items = P.get(quest, "items")
  if Y.is_map(items) then Y.remove(items, iid) end
  if not P.T(P.get(quest, "items")) then Y.remove(quest, "items") end
  for _, k in ipairs(Y.keys(quest)) do if k ~= "items" then clear(quest[k]) end end
  return count
end
-- (Python's `ref in v` for a list: one of its own entries)
function IC.names_in(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

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
IC.item_label = item_label

-- a TAG chip (a quest item) -> clicked
local function tag(host, id, b, text, tip)
  local clicked, hv = host:hit(id, b)
  local edge, fg = C.tag_edge, C.tag_text
  if hv then edge, fg = C.tag_hover, T.WHITE if tip then CT.tip("panel." .. id, tip) end end
  D.fill(b.x, b.y, b.w, b.h, edge)
  D.fill(b.x + 1, b.y + 1, b.w - 2, b.h - 2, C.tag_bg)
  Q.text(b.x + (b.w - Q.text_w(text, 11)) // 2, b.y + Q.vcenter(b.h, Q.line_h(11)), fg, text, 11, false, C.tag_bg)
  return clicked
end

-- --- the item window ---
local ITEMS = {}
ITEMS.__index = ITEMS
-- current: the item the asking field has now ("own:<id>": the window opens on Custom, that one chosen)
function IC.items(panel, win, then_, keep_open, action, current)
  local self = setmetatable({panel = panel, win = win, then_ = then_, keep_open = keep_open,
                             action = action or "Choose item", tab = 1}, ITEMS)
  self.ed, self.assets = panel.ed, panel.assets
  self.lay = {frame = win.rect}
  local ids = "panel.win." .. win.key .. ".cat."
  self.catalog = CV.new(panel.ed, panel.assets, {host = self, ids = ids, no_tabs = true, width = win.rect.w,
                                                  choice = panel.catalog_opts and panel.catalog_opts.choice,
                                                  own = function() return self:own_entries() end})
  self.catalog.model:set_tab(1)
  self.ins = INS.new(self)
  self.ins.item_action = self.action
  self:show_ins(false)
  local cv, ins = self.catalog, self.ins
  cv.on_current = function(e)
    if e and e.type == "item" then
      local fav = false
      for _, k in ipairs(cv.model.favourites or {}) do if k == e.key then fav = true end end
      ins:show_entry(e, fav)
      self:show_ins(true)
    end
  end
  cv.on_chosen = function(e) if e and e.type == "item" then self:take(e.name) end end
  ins.on_place = function(e) self:take_shown(e) end
  ins.on_favourite = function(e) cv.model:toggle_favourite(e) cv:sync_rows() end
  ins.on_overview = function(what, value)
    self:set_tab(1)
    cv.model:show_only(what, value)
    cv.model:set_tab(1)
    cv:sync_rows()
  end
  ins.on_own_text = function(e) self:edit_text(e.own) end
  ins.on_own_drop = function(e) self:ask_drop(e.own) end
  self:show_current(current)
  return self
end
function ITEMS:hit(id, r) return self.win:hit(id, r) end
-- the inspector out at the window's side or away (the window grows by it as the panel by its own)
function ITEMS:show_ins(on)
  self.ins_shown = on
  self.win:set_extra(on and 330 + 8 or 0)
end
function ITEMS:closed() if self.own_dirty then self:save_own() end end
-- what the asking field has now: an own item opens Custom with it chosen, else the game's items (the typing in
-- their search)
function ITEMS:show_current(ref)
  ref = str(ref)
  self.current = ref
  if ref:sub(1, 4) == "own:" then
    self:set_tab(2, ref:sub(5))
  else
    self:set_tab(1)
    CT.set_focus(self.catalog.search_id)
  end
end
-- the tab shown: the catalog on the game's items or on the quest's own (choose: that one current, in the inspector)
function ITEMS:set_tab(i, choose)
  local M = require("conjunction.catalog_model")
  self.tab = i
  local cv = self.catalog
  cv.model:set_tab(i == 2 and M.OWN or 1)
  if i == 2 then cv.model:refresh() end           -- (the own items as they are now)
  cv:sync_rows()
  self:show_ins(false)
  if i == 2 then
    for k, e in ipairs(cv.model.rows) do
      if e.own == choose or (not choose and k == 1) then
        cv:set_current(k)
        cv.on_current(e)
        break
      end
    end
  end
end
function ITEMS:take_shown(e)
  if not e or e.type ~= "item" then return end
  if e.own then self:take(e.key) return end
  local name = self.ins:renamed_to()
  self:take(name and self:make_own(name, e.row, self.ins:described()) or e.name)
end
-- a new item of this quest named name, made from a game item -> own:<id> (the same name from the same item: that one)
function ITEMS:make_own(name, row, description)
  local project = self.ed.project
  local meta = project.meta
  if not Y.is_map(meta.quest) then meta.quest = Y.map({}) end
  local quest = meta.quest
  if not Y.is_map(quest.items) then quest.items = Y.map({}) end
  local items = quest.items
  for _, iid in ipairs(Y.keys(items)) do
    local it = items[iid]
    if S.lower(S.strip(str(it.name))) == S.lower(S.strip(name)) and it.base == row.name then return "own:" .. iid end
  end
  local slug = P.ascii_id(name, "")
  slug = S.from_cps(S.cps(slug), 1, 20)
  if slug == "" then slug = "item" end
  local iid, n = slug, 2
  while items[iid] ~= nil do iid, n = slug .. n, n + 1 end
  items[iid] = Y.map({"name", name, "description", (description and description ~= "") and description or str(row.descr),
                      "text", "", "base", row.name})
  if project.save_meta then project:save_meta() end
  return "own:" .. iid
end
function ITEMS:take(ref)
  if not ref or ref == "" then return end
  if self.own_dirty then self:save_own() end
  local then_ = self.then_
  if not self.keep_open then self.win:close() end
  then_(ref)
end
-- a chip of this quest: a game item shows in the inspector (its button takes it), an own one is taken
function ITEMS:quest_item(ref)
  if ref:sub(1, 4) == "own:" then self:take(ref) return end
  local row = self.assets:item(ref)
  if row then self.catalog.on_current(self.catalog.model:entry_item(row)) else self:take(ref) end
end

-- the tabs over the window (MaximdeWinter 24.10.: a book made, then no way to see it or change it again): the game's items,
-- and Custom - the quest's own items in the same grid, the one the step has now marked; the inspector changes the
-- chosen one (its name, its line, its text in a window of its own)
IC.TABS = {"Items", "Custom"}
function ITEMS:frame(r)
  local quest = (self.ed.project.meta or {}).quest
  local own = quest and Y.is_map(quest.items) and Y.len(quest.items) or 0
  local x, th = r.x, 0
  for i, name in ipairs(IC.TABS) do
    local text = (i == 2 and own > 0) and (name .. " (" .. own .. ")") or name
    local tw, h = Q.tab_size(text, 12)
    th = h
    local clicked = self:hit("tab." .. i, {x = x, y = r.y, w = tw, h = h})
    Q.tab(x, r.y, tw, h, text, {chosen = self.tab == i, px = 12})
    if clicked and self.tab ~= i then
      self:set_tab(i)
      if i == 1 then CT.set_focus(self.catalog.search_id) end
    end
    x = x + tw
  end
  D.fill(r.x, r.y + th - 1, r.w, 1, T.LINE)
  local body = {x = r.x, y = r.y + th + 6, w = r.w, h = r.h - th - 6}
  if self.tab == 2 then self:frame_custom(body) else self:frame_game(body) end
end

function ITEMS:frame_game(r)
  local quest = (self.ed.project.meta or {}).quest or {}
  -- this quest: "This quest" and a chip per item (Flow, 4 apart)
  local parts = {{kind = "label", text = "This quest", w = Q.hint_w("This quest", 11), h = Q.line_h(11)}}
  for _, ref in ipairs(IC.quest_item_refs(quest)) do
    local text = item_label(ref, quest, self.assets)
    local w, h = tag_size(text)
    parts[#parts + 1] = {kind = "tag", ref = ref, text = text, w = w, h = h}
  end
  local x, y, line = 0, 0, 0
  for _, p in ipairs(parts) do
    if x + p.w > r.w - 1 and line > 0 then x, y, line = 0, y + line + 4, 0 end
    p.x, p.y = x, y
    x = x + p.w + 4
    line = math.max(line, p.h)
  end
  local qh = y + line
  for k, p in ipairs(parts) do
    local b = {x = r.x + p.x, y = r.y + p.y, w = p.w, h = p.h}
    if p.kind == "label" then Q.text(b.x, b.y, C.field, p.text, 11)
    elseif tag(self, "quest." .. k, b, p.text, p.ref:sub(1, 4) == "own:" and "ic.own_item" or "ic.quest_item") then
      self:quest_item(p.ref)
    end
  end
  self:frame_catalog({x = r.x, y = r.y + qh + 6, w = r.w, h = r.h - qh - 6})
end
-- the catalog and, when one is shown, its inspector (330 wide, 8 apart)
function ITEMS:frame_catalog(r)
  local cw = self.ins_shown and r.w - 330 - 8 or r.w
  self.lay.frame = self.win.rect
  self.catalog:frame({x = r.x, y = r.y, w = cw, h = r.h})
  if self.ins_shown then self.ins:frame({x = r.x + cw + 8 - 8, y = r.y, w = 330 + 8, h = r.h}) end
end

-- --- Custom: this quest's own items ---
IC.LETTER = "q603_roberts_letter"                  -- (the picture of an own item made from none: a letter)
-- the quest's own items {iid}, the map, the quest
function ITEMS:own_items()
  local quest = (self.ed.project.meta or {}).quest
  local items = quest and Y.is_map(quest.items) and quest.items or nil
  return items and Y.keys(items) or {}, items, quest
end
-- the steps naming own item iid ("step 3", ...)
function ITEMS:own_uses(quest, iid)
  local uses = {}
  for _, ns in ipairs(IC.numbered_steps(quest)) do
    if IC.names(ns[2], "own:" .. iid) then uses[#uses + 1] = "step " .. str(ns[1]) end
  end
  return uses
end
-- the own items as the catalog's entries: the picture of the item each is made from, the line under it what uses it
-- (the asking step's own: "this step", gold)
function ITEMS:own_entries()
  local list, items, quest = self:own_items()
  local out = {}
  for _, iid in ipairs(list) do
    local it = items[iid]
    local base = str(it.base) ~= "" and self.assets:item(str(it.base)) or nil
    local row = base or self.assets:item(IC.LETTER) or {name = IC.LETTER}
    local uses = self:own_uses(quest, iid)
    local here = self.current == "own:" .. iid
    out[#out + 1] = {type = "item", own = iid, key = "own:" .. iid, name = "own:" .. iid,
                     title = str(it.name) ~= "" and str(it.name) or iid,
                     sub = here and "this step" or (#uses > 0 and ("used in " .. table.concat(uses, ", ")) or "not used yet"),
                     sub_colour = here and T.GOLD or nil, kind = row.category, fav = false, row = row,
                     own_name = str(it.name), own_descr = str(it.description), own_text = str(it.text),
                     made_from = base and item_label(base.name, quest, self.assets) or nil, uses = uses}
  end
  return out
end
-- a change kept: through the quest board (an undo step, the board anew) when it is there
function ITEMS:save_own()
  self.own_dirty = false
  local b = self.panel.board_ui
  if b and b.save then b:save() elseif self.ed.project.save_meta then self.ed.project:save_meta() end
end
function ITEMS:ask_drop(iid)
  local list, items, quest = self:own_items()
  local it = items and items[iid]
  if not it then return end
  local function drop()
    IC.drop_item(quest, iid)
    if self.current == "own:" .. iid then self.current = nil end
    self:save_own()
    self:set_tab(2)
  end
  local uses = self:own_uses(quest, iid)
  if #uses == 0 then drop() return end
  require("conjunction.ui.dialogs").choose(self.ed, "Delete item",
    "\"" .. (str(it.name) ~= "" and str(it.name) or iid) .. "\" is used in " .. table.concat(uses, ", ") ..
    ". Deleting it empties those fields", {{"delete", "Delete"}, {"cancel", "Cancel"}}, function(a)
      if a == "delete" then drop() end
    end)
  local _ = list
end
-- the text Geralt reads (a letter, a book) in a window of its own, big enough to write in
function ITEMS:edit_text(iid)
  local _, items = self:own_items()
  local it = items and items[iid]
  if not it then return end
  local host = self
  local PT = require("conjunction.ui.plaintext")
  local body = {}
  function body:frame(r)
    local w = self.win
    local id = "panel.win." .. w.key .. ".text"
    local bw, bh = Q.button_size("Done")
    local _, text = PT.edit(id, r.x, r.y, r.w, r.h - bh - 6, str(it.text),
                            {placeholder = "What Geralt reads when he opens it (empty: not readable)",
                             hit = function(hid, b) return w:hit(hid, b) end})
    if text ~= str(it.text) then it.text = text self.dirty = true end
    local hint = "Empty: a plain quest item, nothing to read"
    Q.text(r.x, r.y + r.h - bh + Q.vcenter(bh, Q.line_h(11)), C.count, hint, 11)
    local b = {x = r.x + r.w - bw, y = r.y + r.h - bh, w = bw, h = bh}
    local clicked, hv, held = w:hit("done", b)
    Q.button(b.x, b.y, b.w, b.h, "Done", {hover = hv or held, pressed = held and hv, primary = true})
    if self.dirty and CT.focus ~= id then self:closed() end
    if clicked then w:close() end
  end
  function body:closed()
    if self.dirty then
      self.dirty = false
      host:save_own()
      host.catalog.model:refresh()
      host.catalog:sync_rows()
    end
  end
  local name = str(it.name) ~= "" and str(it.name) or iid
  local w = self.panel:open_win("own_text." .. iid, "Text of " .. name, "own_text", function(win)
    body.win = win
    return body
  end)
  CT.set_focus("panel.win." .. w.key .. ".text")
end

function ITEMS:frame_custom(r)
  local cv = self.catalog
  if #cv.model.rows == 0 and cv.model.text == "" then
    local TL = require("conjunction.ui.textlayout")
    local s = "No custom items yet. In Items choose one and give it a name of its own"
    D.fill(r.x, r.y, r.w, r.h, CV.C.grid_bg)
    D.rect(r.x, r.y, r.w, r.h, CV.C.grid_edge, 1)
    for k, l in ipairs(TL.wrap(s, 12, false, r.w - 24, "word")) do
      Q.text(r.x + 12, r.y + 12 + (k - 1) * Q.line_h(12), C.count, l.s, 12, false, CV.C.grid_bg)
    end
    return
  end
  self:frame_catalog(r)
  -- the inspector's fields into the chosen own item; kept once the typing leaves them (not at every key)
  local e = self.ins.entry
  local _, items = self:own_items()
  local it = self.ins_shown and e and e.own and items and items[e.own]
  if it then
    local name, descr = self.ins.rename or "", self.ins.redescribe or ""
    if name ~= str(it.name) then it.name, e.title, self.own_dirty = name, name, true end
    if descr ~= str(it.description) then it.description, self.own_dirty = descr, true end
  end
  if self.own_dirty and CT.focus ~= "panel.ins.rename" and CT.focus ~= "panel.ins.redescribe" then
    self:save_own()
    cv.model:refresh()
    cv:sync_rows()
  end
end

-- --- the loot window ---
local LOOT = {}
LOOT.__index = LOOT
local ROW_H = 58                                    -- (a title and one row of icons: setSizeHint(0, 58))
function IC.loot(panel, win, then_, current)
  local self = setmetatable({panel = panel, win = win, then_ = then_, name = current}, LOOT)
  self.ed, self.assets = panel.ed, panel.assets
  self.lay = {frame = win.rect}
  self.text = ""
  self.bar = IV.bar(1, 0, 0)
  self.dbar = IV.bar(20, 0, 0)
  self.ins = INS.new(self)                        -- (its icon strips)
  self:fill("")
  CT.set_focus("panel.win." .. win.key .. ".search")
  return self
end
function LOOT:hit(id, r) return self.win:hit(id, r) end
function LOOT:fill(text)
  local tables = self.assets:loot_tables(text, 150)
  if self.name and text == "" then
    local found = false
    for _, t in ipairs(tables) do if t.name == self.name then found = true end end
    if not found then
      local cur = self.assets:loot(self.name)       -- (the one it has now: always in the list, first)
      if cur then table.insert(tables, 1, cur) end
    end
  end
  self.tables = tables
  self.cur = nil
  for i, t in ipairs(tables) do if t.name == self.name then self.cur = i end end
end
function LOOT:use(name)
  local then_ = self.then_
  self.win:close()
  then_(name)
end
local function loot_title(name)
  local t = S.strip(str(name), "_ ")
  local parts = {}
  local i = 1
  while true do
    local a = t:find("_", i, true)
    local piece = a and t:sub(i, a - 1) or t:sub(i)
    local q = S.strip(piece)
    if q ~= "" then parts[#parts + 1] = q end
    if not a then break end
    i = a + 1
  end
  if #parts > 0 then t = table.concat(parts, " - ") end
  local cps = S.cps(t)
  return S.upper(S.from_cps(cps, 1, 1)) .. S.from_cps(cps, 2, #cps)
end
IC.loot_title = loot_title

function LOOT:frame(r)
  local PN = require("conjunction.ui.panel")
  -- the left: the search, the list (stretch); the right: the detail, 330 wide; 8 apart
  local lw = r.w - 330 - 8
  local sid = "panel.win." .. self.win.key .. ".search"
  local eh = CT.edit_h(PN.EDIT_STYLE)
  local _, text = CT.edit(sid, r.x, r.y, lw, self.text, {placeholder = "Search a loot table or an item it gives",
                                                         style = PN.EDIT_STYLE})
  if text ~= self.text then self.text = text self:fill(text) end
  -- (the left column is a layout inside the row: it takes the row's 8 between its parts)
  local lr = {x = r.x, y = r.y + eh + 8, w = lw, h = r.h - eh - 8}
  self:draw_list(lr)
  self:draw_detail({x = r.x + lw + 8, y = r.y, w = 330, h = r.h})
end
function LOOT:draw_list(lr)
  D.fill(lr.x, lr.y, lr.w, lr.h, C.list_edge)
  D.fill(lr.x + 1, lr.y + 1, lr.w - 2, lr.h - 2, C.list_bg)
  local vx, vy, vw, vh = lr.x + 1, lr.y + 1, lr.w - 2, lr.h - 2
  local n = #self.tables
  local page = vh // ROW_H
  local b = self.bar
  b.single, b.page = 1, page
  IV.range(b, n - page)
  if n > page then vw = vw - 10 end
  local _, over = self:hit("list", {x = vx, y = vy, w = vw, h = vh})
  local mx, my, wheel = w3.ui.mouse()
  if over and wheel ~= 0 then
    local k = wheel
    while k ~= 0 do
      local one = k >= 1 and 1 or (k <= -1 and -1 or k)
      k = k - one
      if math.abs(k) < 1e-9 then k = 0 end
      IV.wheel(b, one, 3)
    end
  end
  local hover = over and (b.value + (my - vy) // ROW_H + 1) or nil
  if hover and hover > n then hover = nil end
  if over and hover and (w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(2)) then
    if w3.ui.mouse_double(1) and self.press == hover then self:use(self.tables[hover].name) return end
    self.press = hover
    self.cur = hover
    self.name = self.tables[hover].name
  end
  D.clip(vx, vy, vw, vh, function()
    for i = b.value + 1, math.min(n, b.value + page + 1) do
      local t = self.tables[i]
      local y = vy + (i - 1 - b.value) * ROW_H
      local bg = (self.cur == i) and T.CHOSEN or ((hover == i) and T.HOVER or C.list_bg)
      if bg ~= C.list_bg then D.fill(vx, y, vw, ROW_H, bg) end
      D.fill(vx, y + ROW_H - 1, vw, 1, C.row_line)
      -- (the row's widget in the item, less its padding 3px 6px and border; inside it margins 4 3 4 3: the title,
      -- 1 below it the icons - their strip 28 high, the icons cut)
      local wx, wy, ww = vx + 6, y + 3, vw - 12
      local tx, ty = wx + 4, wy + 3
      Q.text(tx, ty, C.loot_title, loot_title(t.name), 12, false, bg)
      local items = {}
      for _, e in ipairs(t.entries or {}) do items[#items + 1] = {e[1], nil} end
      local sy = ty + Q.line_h(12) + 1
      local sh = (ROW_H - 6 - 1) - 3 - Q.line_h(12) - 1 - 3
      D.clip(tx, sy, ww - 8, sh, function()
        self.ins:draw_strip({x = tx, y = sy, w = ww - 8}, items, 10, nil, bg)
      end)
    end
  end)
  if n > page then
    SBAR.draw(self, "lbar", b, {x = vx + vw, y = vy, w = 10, h = vh}, "v", function(id, rr) return self:hit(id, rr) end)
  end
end
function LOOT:draw_detail(r)
  if not self.name then return end
  local t = self.assets:loot(self.name)
  local y = r.y
  local title = loot_title(self.name)
  local TL = require("conjunction.ui.textlayout")
  local lines = TL.wrap(title, 13, true, r.w, "word")
  for k, l in ipairs(lines) do Q.text(r.x, y + (k - 1) * Q.line_h(13, true), C.detail_title, l.s, 13, true) end
  y = y + math.max(1, #lines) * Q.line_h(13, true) + 6
  local b = {x = r.x, y = y, w = r.w, h = 29}
  local clicked, hv, held = self:hit("use", b)
  Q.button(b.x, b.y, b.w, b.h, "Use this loot", {hover = hv or held, pressed = held and hv, fg = T.BUTTON_TEXT})
  if hv then CT.tip("panel.win.use", "loot.use") end
  if clicked then self:use(self.name) return end
  y = y + 29 + 6
  -- what it gives: [icon] name  n (or lo-hi), rows 2 apart, in a scroll area (opaque #1e1e1e: the style's window
  -- colour shows through its viewport, measured)
  local area = {x = r.x, y = y, w = r.w, h = r.y + r.h - y}
  D.fill(area.x, area.y, area.w, area.h, C.detail_bg)
  local entries = (t and t.entries) or {}
  local need = 4 + #entries * 30 + math.max(0, #entries - 1) * 2
  local db = self.dbar
  db.single, db.page = 20, area.h
  IV.range(db, need - area.h)
  local iw = need > area.h and area.w - 10 or area.w
  local _, over = self:hit("detail", {x = area.x, y = area.y, w = iw, h = area.h})
  local _, _, wheel = w3.ui.mouse()
  if over and wheel ~= 0 then IV.wheel(db, wheel >= 0 and math.min(wheel, 1) or math.max(wheel, -1), 3) end
  D.clip(area.x, area.y, iw, area.h, function()
    local yy = area.y + 4 - db.value
    for _, e in ipairs(entries) do
      local item, lo, hi = e[1], e[2], e[3]
      self.ins:draw_icon_label(area.x, yy, item, nil, true)
      local it = self.assets:item(item) or {}
      local name = str(it.label) ~= "" and str(it.label) or str(item)
      local cnt = (lo == hi) and tostring(lo) or (tostring(lo) .. "-" .. tostring(hi))
      local cw = Q.hint_w(cnt, 12)
      Q.text(area.x + 30 + 6, yy + Q.vcenter(30, Q.line_h(12)), C.entry, name, 12, false, C.detail_bg)
      Q.text(area.x + iw - cw, yy + Q.vcenter(30, Q.line_h(12)), C.count, cnt, 12, false, C.detail_bg)
      yy = yy + 30 + 2
    end
  end)
  if need > area.h then
    SBAR.draw(self, "dbar", db, {x = area.x + iw, y = area.y, w = 10, h = area.h}, "v",
              function(id, rr) return self:hit(id, rr) end)
  end
end

return IC
