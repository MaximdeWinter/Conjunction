-- vanilla_view.py's "All values" tab: every value of the picked block in a QTreeWidget of the theme (Property, Value,
-- Type; the columns 150 and 220, the last stretched; rows of 24, indentation 30), the objects under it unfolded (a
-- condition, an AI action), opened two levels deep. A double click changes a value (a yes / no flips; a reference to a
-- quest file opens it), a right click on a list: an item more / less.
--   local pt = PT.new(window)   pt:fill(qf, b)   pt:frame(r)
local TR = require("conjunction.cr2w_tree")
local V = require("conjunction.vanilla_graph")
local VE = require("conjunction.vanilla_edit")
local P = require("conjunction.py")
local S = require("conjunction.pystr")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local T = require("conjunction.ui.theme")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local D = w3.ui.draw
local PT = {}
PT.__index = PT

PT.ROW, PT.IND, PT.HEAD = 24, 30, 33
PT.COLS = {150, 220}
PT.LAST_MIN = 100                   -- (stretchLastSection: at least the default section size)
PT.SIMPLE = {Bool = true, Int8 = true, Uint8 = true, Int16 = true, Uint16 = true, Int32 = true, Uint32 = true,
             Int64 = true, Uint64 = true, Float = true, Double = true}
PT.IMPORT_CLASS = {[".w2scene"] = "CStoryScene", [".w2phase"] = "CQuestPhase", [".journal"] = "CJournalResource",
                   [".w2comm"] = "CCommunity", [".w2behtree"] = "CBehTree", [".env"] = "CEnvironmentDefinition",
                   [".w2ent"] = "CEntityTemplate"}

function PT.new(window)
  return setmetatable({window = window, rows = {}, top = {}, bar = IV.bar(1, 0, 0), hbar = IV.bar(20, 0, 0),
                       bar_state = {}, current = nil, editing = nil}, PT)
end

local function item(text, typ, data)
  return {text = text, value = "", typ = typ or "", data = data, children = {}, expanded = false}
end

local function hex_spaced(b)
  local out = {}
  for i = 1, #b do out[i] = string.format("%02x", b:byte(i)) end
  return table.concat(out, " ")
end
local function hex(b) return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

-- every value of block b: its properties, then (arguments)
function PT:fill(qf, b)
  self.qf, self.b = qf, b
  self.top, self.current, self.editing = {}, nil, nil
  IV.set(self.bar, 0)
  IV.set(self.hbar, 0)
  if b == nil then return end
  local o = qf.tree:obj(b.n)
  local root = {children = self.top}
  self:fill_props(root, qf, b.n, {}, o.props or {}, {[b.n] = true})
  if o.args and #o.args > 0 then
    local args = item("(arguments)", "", nil)
    self.top[#self.top + 1] = args
    self:fill_props(args, qf, b.n, nil, o.args, {[b.n] = true})
    args.expanded = true
  end
  -- expandToDepth(1): the top two levels open
  for _, it in ipairs(self.top) do
    it.expanded = true
    for _, ch in ipairs(it.children) do ch.expanded = true end
  end
end

function PT:fill_props(parent, qf, objn, path, props, seen)
  for _, p in ipairs(props) do
    local sub = nil
    if path ~= nil then
      sub = {}
      for i, x in ipairs(path) do sub[i] = x end
      sub[#sub + 1] = p.name
    end
    self:value(parent, qf, objn, sub, p.name, p.type, p.value, seen)
  end
end

-- a value's row; its data: (object, path inside it, type) - where an edit writes (path nil: not editable here)
function PT:value(parent, qf, objn, path, name, typ, v, seen)
  local it = item(name, typ, {objn, path, typ})
  parent.children[#parent.children + 1] = it
  local handle = P.startswith(typ, "handle:") or P.startswith(typ, "ptr:") or P.startswith(typ, "#")
  if TR.is(v, TR.STRUCT) then
    self:fill_props(it, qf, objn, path, v, seen)
  elseif V.is_list(v) and not TR.is(v, TR.TAGS) then
    local inner = ""
    if P.startswith(typ, "array:") then
      local a = typ:find(",", 1, true)
      local b2 = a and typ:find(",", a + 1, true)
      inner = b2 and typ:sub(b2 + 1) or ""
    end
    it.value = #v .. " item" .. (#v ~= 1 and "s" or "")
    for k, x in ipairs(v) do
      local sub = nil
      if path ~= nil then
        sub = {}
        for i, y in ipairs(path) do sub[i] = y end
        sub[#sub + 1] = k - 1
      end
      self:value(it, qf, objn, sub, "[" .. (k - 1) .. "]", inner, x, seen)
    end
  elseif handle and math.type(v) == "integer" and v > 0 then
    local o = qf.tree:obj(v)
    it.value = o.cls
    -- (another block of the graph, a graph: named, not walked)
    local other = o.cls == "CQuestGraph" or (P.endswith(o.cls, "Block") and v ~= objn and o:get("guid") ~= nil)
    if other then
      it.value = o.cls .. " (object " .. v .. ")"
    elseif not seen[v] then
      local seen2 = {}
      for k in pairs(seen) do seen2[k] = true end
      seen2[v] = true
      self:fill_props(it, qf, v, {}, o.props or {}, seen2)
    end
  elseif TR.is(v, TR.SOFT) or (handle and math.type(v) == "integer" and v < 0) then
    local p = qf:import_path(v)
    it.value = p or "none"
    it.ref = p
  elseif TR.is(v, TR.VARIANT) then
    it.typ = typ .. " (" .. v.type .. ")"
    it.value = qf:text(v.value, v.type)
  elseif TR.is(v, TR.GUID) then
    it.value = hex(v.b)
  elseif TR.is(v, TR.LOC) then
    it.value = tostring(v.n)
  elseif TR.is(v, TR.TRANSFORM) then
    it.value = qf:text(v)
  elseif TR.is(v, TR.RAW) then
    it.value = hex_spaced(v.b)
  elseif type(v) == "string" or TR.is(v, TR.WIDE) then
    it.value = V.s(v)
  else
    it.value = qf:text(v, typ)
  end
end

-- the rows shown, in order: {it, depth}
function PT:shown()
  local out = {}
  local function walk(list, depth)
    for _, it in ipairs(list) do
      out[#out + 1] = {it = it, depth = depth}
      if it.expanded and #it.children > 0 then walk(it.children, depth + 1) end
    end
  end
  walk(self.top, 0)
  return out
end

-- --- changed
function PT.editable_value(v, typ)
  if TR.is(v, TR.GUID) or TR.is(v, TR.RAW) or TR.is(v, TR.TRANSFORM) or TR.is(v, TR.STRUCT) or
     (V.is_list(v) and not TR.is(v, TR.TAGS)) then
    return false
  end
  local handle = P.startswith(typ, "handle:") or P.startswith(typ, "ptr:") or P.startswith(typ, "#")
  if handle and math.type(v) == "integer" and v > 0 then return false end
  return true
end

-- the text typed into a value's field, as a value of its type
function PT.parse(old, typ, text)
  local NUM = require("conjunction.pynum")
  local function int(s)
    local n = math.tointeger(tonumber(S.strip(s)))
    if n == nil then error("ValueError: invalid literal for int() with base 10: '" .. s .. "'", 0) end
    return n
  end
  if TR.is(old, TR.VARIANT) then return TR.Variant(old.type, PT.parse(old.value, old.type, text)) end
  if PT.SIMPLE[typ] and typ ~= "Float" and typ ~= "Double" and typ ~= "Bool" then return int(text) end
  if typ == "Float" or typ == "Double" or math.type(old) == "float" then return NUM.float(S.strip(text)) end
  if TR.is(old, TR.TAGS) then
    local out = {}
    for x in text:gmatch("[^,]+") do if S.strip(x) ~= "" then out[#out + 1] = S.strip(x) end end
    return TR.Tags(out)
  end
  if TR.is(old, TR.LOC) then return TR.Loc(int(text)) end
  if TR.is(old, TR.WIDE) then return TR.Wide(text) end
  if math.type(old) == "integer" then return int(text) end
  return text
end

function PT:current_value(objn, path)
  local e = self.window:editor(self.window.trail[#self.window.trail][1])
  local holder, key = VE.locate(e.tree:obj(objn).props, path)
  if key ~= nil then return holder[key >= 0 and key + 1 or #holder + key + 1] end
  return holder.value
end

function PT:import_class(v, text)
  local e = self.window:editor(self.window.trail[#self.window.trail][1])
  local k = TR.is(v, TR.SOFT) and v.n or ((math.type(v) == "integer" and v < 0) and -v or 0)
  if k > 0 and k <= #e.tree.f.imports then return e.tree.f.imports[k][2] end
  local ext = S.lower(S.strip(text)):match("(%.[^.\\/]*)$") or ""
  return PT.IMPORT_CLASS[ext] or "CResource"
end

-- a double click: a reference to a quest file opens it; a value is changed (a yes / no flips)
function PT:double(it, col)
  local w = self.window
  if col == 0 and it.ref and (P.endswith(it.ref, ".w2phase") or P.endswith(it.ref, ".w2quest")) and
     w:depot():exists(it.ref) then
    w.trail[#w.trail + 1] = {it.ref, nil, (it.ref:gsub("^.*[\\/]", ""))}
    w:show_current(true)
    return
  end
  local d = it.data
  if not d or d[1] == nil or d[2] == nil then return end
  local objn, path, typ = d[1], d[2], d[3]
  local v = self:current_value(objn, path)
  if type(v) == "boolean" then
    w:edit(function(e) e:set(objn, path, not v) end)
    return
  end
  if not PT.editable_value(v, typ) then return end
  local is_ref = P.startswith(typ, "soft:") or P.startswith(typ, "handle:") or P.startswith(typ, "ptr:") or
                 P.startswith(typ, "#")
  self.editing = {it = it, text = is_ref and (it.ref or "") or it.value, old = v, objn = objn, path = path, typ = typ,
                  is_ref = is_ref, fresh = true}
end

function PT:finish_edit(text)
  local ed = self.editing
  self.editing = nil
  local w = self.window
  if ed.is_ref then
    w:edit(function(e) e:set_ref(ed.objn, ed.path, S.strip(text), self:import_class(ed.old, text)) end)
    return
  end
  local ok, new = pcall(PT.parse, ed.old, ed.typ, text)
  if not ok then
    w.state = "not changed: " .. tostring(new)
    return
  end
  local same = new == ed.old
  if TR.is(new, TR.VARIANT) and TR.is(ed.old, TR.VARIANT) then same = new.type == ed.old.type and new.value == ed.old.value end
  if not same or math.type(new) ~= math.type(ed.old) then w:edit(function(e) e:set(ed.objn, ed.path, new) end) end
end

function PT:menu(it, mx, my)
  local d = it.data
  if not d or d[2] == nil then return end
  local objn, path, typ = d[1], d[2], d[3]
  local list = {}
  if P.startswith(typ, "array:") then
    list[#list + 1] = {text = "Add item", action = function()
      self.window:edit(function(e) e:add_item(objn, path) end)
    end}
  end
  if #path > 0 and math.type(path[#path]) == "integer" then
    list[#list + 1] = {text = "Remove item", action = function()
      self.window:edit(function(e) e:remove_item(objn, path) end)
    end}
  end
  if #list > 0 then
    require("conjunction.ui.inline_menu").open("vg.props.menu", {x = mx, y = my, w = 1, h = 1}, list,
                                                self.window.win and self.window.win.rect or {x = 0, y = 0, w = 4096,
                                                                                              h = 4096})
  end
end

-- --- drawn: the frame (LINE), the header, the rows, the bars
local function elided(s, w) return Q.elide(s, "right", w, T.FONT_LIST) end

function PT:frame(r)
  D.fill(r.x, r.y, r.w, r.h, T.LINE)
  D.fill(r.x + 1, r.y + 1, r.w - 2, r.h - 2, T.SURFACE)
  local vx, vy = r.x + 1, r.y + 1 + PT.HEAD
  local vw, vh = r.w - 2, r.h - 2 - PT.HEAD
  local rows = self:shown()
  local total_w = PT.COLS[1] + PT.COLS[2] + PT.LAST_MIN
  local hbar_on = total_w > vw
  if hbar_on then vh = vh - 10 end
  local bar = self.bar
  bar.single, bar.page = 1, vh // PT.ROW
  IV.range(bar, #rows - bar.page)
  local vbar_on = #rows > bar.page
  if vbar_on then
    vw = vw - 10
    if not hbar_on and total_w > vw then
      hbar_on = true
      vh = vh - 10
      bar.page = vh // PT.ROW
      IV.range(bar, #rows - bar.page)
    end
  end
  local last = math.max(PT.LAST_MIN, vw - PT.COLS[1] - PT.COLS[2])
  local cols = {PT.COLS[1], PT.COLS[2], last}
  total_w = cols[1] + cols[2] + cols[3]
  local hb = self.hbar
  hb.page = vw
  IV.range(hb, math.max(0, total_w - vw))
  local sx = hb.value
  -- the header
  D.clip(vx, r.y + 1, vw, PT.HEAD, function()
    local x = vx - sx
    for k, name in ipairs({"Property", "Value", "Type"}) do
      Q.header_left(x, r.y + 1, cols[k], PT.HEAD, name)
      x = x + cols[k]
    end
  end)
  -- the mouse
  local mx, my, wheel = w3.ui.mouse()
  local area = {x = vx, y = vy, w = vw, h = vh}
  local _, hovered = CT.hit_box("vg.props", area)
  if hovered and wheel and wheel ~= 0 then IV.wheel(bar, wheel, 3) end
  local i = hovered and bar.value + (my - vy) // PT.ROW + 1 or nil
  local row = i and rows[i] or nil
  if row and (w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(2)) then
    local x0 = vx - sx + row.depth * PT.IND
    local it = row.it
    if #it.children > 0 and mx >= x0 and mx < x0 + PT.IND and w3.ui.mouse_clicked(1) then
      it.expanded = not it.expanded
    else
      self.current = it
      local col = (mx - vx + sx) < cols[1] and 0 or ((mx - vx + sx) < cols[1] + cols[2] and 1 or 2)
      if w3.ui.mouse_clicked(2) then
        self:menu(it, mx, my)
      elseif w3.ui.mouse_double(1) then
        if #it.children > 0 and col == 0 and not it.ref then it.expanded = not it.expanded end
        self:double(it, col)
      end
    end
  end
  D.clip(vx, vy, vw, vh, function()
    for k = bar.value + 1, math.min(#rows, bar.value + bar.page + 1) do
      local rw = rows[k]
      local it = rw.it
      local y = vy + (k - 1 - bar.value) * PT.ROW
      local chosen = it == self.current
      local hov = row ~= nil and row.it == it
      local bg = chosen and T.CHOSEN or (hov and T.HOVER or T.SURFACE)
      local x0 = vx - sx + rw.depth * PT.IND
      if bg ~= T.SURFACE then D.fill(x0 + PT.IND, y, vx - sx + total_w - x0 - PT.IND, PT.ROW, bg) end
      if #it.children > 0 then
        Q.draw_part((it.expanded and "vg_branch_open" or "vg_branch_closed") ..
                    (chosen and "_chosen" or (hov and "_hover" or "")), x0, y)
      end
      local fg = chosen and T.WHITE or T.BUTTON_TEXT     -- (the theme's lists: #dddddd)
      local ty = y + (PT.ROW - Q.line_h(T.FONT_LIST) + 1) // 2
      local c0 = x0 + PT.IND
      local cw0 = vx - sx + cols[1] - c0
      Q.text(c0 + 9, ty, fg, elided(it.text, cw0 - 18), T.FONT_LIST, false, bg)
      local c1 = vx - sx + cols[1]
      if self.editing and self.editing.it == it then
        local st = {bg = 0x1b1b1eff, edge = 0xd9a441ff, edge_focus = 0xd9a441ff, fg = 0xffffffff, px = T.FONT_LIST,
                    pad = {1, 1, 1, 1}, sel_bg = T.CHOSEN, sel_fg = T.WHITE}
        local id = "vg.props.edit"
        if self.editing.fresh then
          CT.set_focus(id)
          self.editing.fresh = false
        end
        local was = CT.focus == id
        local _, text, enter = CT.edit(id, c1, y, cols[2], self.editing.text, {style = st, h = PT.ROW})
        self.editing.text = text
        if enter or (was and CT.focus ~= id) then self.pending = function() self:finish_edit(text) end end
      else
        Q.text(c1 + 9, ty, fg, elided(it.value, cols[2] - 18), T.FONT_LIST, false, bg)
      end
      local c2 = c1 + cols[2]
      Q.text(c2 + 9, ty, fg, elided(it.typ, cols[3] - 18), T.FONT_LIST, false, bg)
    end
  end)
  local hit = function(id, rr) return CT.hit_box(id, rr) end
  if vbar_on then SBAR.draw(self.bar_state, "vg.props.vbar", bar, {x = vx + vw, y = vy, w = 10, h = vh}, "v", hit) end
  if hbar_on then SBAR.draw(self.bar_state, "vg.props.hbar", hb, {x = vx, y = vy + vh, w = vw, h = 10}, "h", hit) end
  if self.pending then
    local fn = self.pending
    self.pending = nil
    fn()
  end
end

return PT
