-- block_palette.py's BlockPalette: the quest graph's sidebar - every block one can add, the simple ones first by what
-- they are for (Story flow, Wait until, Check ...), then the game's own (every block class, every condition to wait for
-- or check, every quest function, every action a person can be given), with a search over names and explanations. A
-- block is dragged onto the graph or double clicked; the line under the list says what the hovered one does.
--   local bp = BP.new()   bp:frame(r)   bp.on_chosen(entry)   bp.dragging: {entry} while one is dragged (dropped:
--   bp.on_drop(entry, mx, my))
--   entry: {"kind", id} | {"block", class} | {"wait", class} | {"if", class} | {"fn", name} | {"ai", class} |
--          {"template", id}
local BL = require("conjunction.blocks")
local GC = require("conjunction.game_catalog")
local P = require("conjunction.py")
local PS = require("conjunction.pysort")
local S = require("conjunction.pystr")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local D = w3.ui.draw
local BP = {}
BP.__index = BP

local function hex(s) return (tonumber(s:sub(2), 16) << 8) | 255 end
BP.C = {bg = hex("#18181b"), text = hex("#d8d8dc"), help = hex("#a8a8b0"), help_bg = hex("#1f1f23"),
        help_edge = hex("#333333"), hover = hex("#29292d"), chosen = hex("#4b4b50"), white = hex("#ffffff")}
local C = BP.C
BP.ROW, BP.IND = 22, 12          -- QTreeWidget::item{padding:2px 0} at 12 px: rows of 22; setIndentation(12)
BP.HELP = "Drag a block onto the graph or double click it"
BP.HELP_H = 64

-- [(section, [(label, entry, explanation)])] of the game's own blocks, conditions, functions, actions - the most used
-- first (block_palette.game_entries)
function BP.game_entries(catalog)
  local cls = P.get(catalog, "classes") or {}
  local simple_blocks, simple_fns = {}, {}
  for _, k in ipairs(BL.KINDS) do
    if #k.cond == 0 and #k.fn == 0 then simple_blocks[k.cls] = true end
    for _, f in ipairs(k.fn) do simple_fns[f] = true end
  end
  local function count(n) return P.get(P.get(cls, n) or {}, "count") or 0 end
  local function by_count(names) return PS.sorted(names, function(n) return -count(n) end) end
  local function named(role, skip)
    local out = {}
    for _, n in ipairs(require("conjunction.yaml").keys(cls)) do
      if P.get(cls[n], "role") == role and not (skip and skip[n]) then out[#out + 1] = n end
    end
    return out
  end
  local skip = {[BL.W] = true, [BL.I] = true, [BL.S] = true, CQuestScriptedActionsBlock = true}
  for n in pairs(simple_blocks) do skip[n] = true end
  local out = {}
  local list = {}
  for _, n in ipairs(by_count(named("block", skip))) do
    list[#list + 1] = {GC.label(n), {"block", n}, P.str(P.or_(P.get(cls[n], "doc"), n))}
  end
  out[#out + 1] = {"Other blocks", list}
  local conds = by_count(named("condition"))
  local waits, ifs = {}, {}
  for _, n in ipairs(conds) do
    waits[#waits + 1] = {GC.label(n), {"wait", n}, n}
    ifs[#ifs + 1] = {GC.label(n), {"if", n}, n}
  end
  out[#out + 1] = {"Wait for any condition", waits}
  out[#out + 1] = {"Check any condition", ifs}
  local fns = P.get(catalog, "functions") or {}
  local names = {}
  for _, n in ipairs(require("conjunction.yaml").keys(fns)) do if not simple_fns[n] then names[#names + 1] = n end end
  names = PS.sorted(names, function(n) return {-(P.get(fns[n], "count") or 0), n} end)
  list = {}
  for _, n in ipairs(names) do
    local f = fns[n]
    local ps = {}
    for _, p in ipairs(P.get(f, "params") or {}) do ps[#ps + 1] = P.str(p.name) end
    local c = P.get(f, "count")
    list[#list + 1] = {P.str(P.or_(P.get(f, "label"), n)), {"fn", n},
                       n .. "(" .. table.concat(ps, ", ") .. ")" .. (P.T(c) and (" - used " .. c .. " times in the game")
                                                                       or "")}
  end
  out[#out + 1] = {"Game functions", list}
  list = {}
  for _, n in ipairs(by_count(named("ai"))) do list[#list + 1] = {GC.label(n), {"ai", n}, n} end
  out[#out + 1] = {"Actions for a person", list}
  return out
end

function BP.new(catalog)
  local self = setmetatable({search = "", items = {}, bar = IV.bar(1, 0, 0), bar_state = {}, help = BP.HELP,
                             hover = nil, current = nil, _catalog = catalog}, BP)
  self:fill()
  return self
end

function BP:catalog()
  if self._catalog == nil then self._catalog = GC.load() or {} end
  return self._catalog
end

-- an item: text_label (its name), text (what it does, for the help and the search), entry, children
local function item(label, opts)
  local it = {text_label = label, children = {}, expanded = false, hidden = false}
  for k, v in pairs(opts or {}) do it[k] = v end
  return it
end

function BP:fill()
  local top = {}
  local blocks = item("Blocks", {bold = true, colour = hex("#f0f0f2"), expanded = true})
  blocks.children[1] = item("Custom block (empty)", {entry = {"kind", "phase"},
    text = "A block of your own: double click it to open it and build inside with the game's blocks; its Input and " ..
           "Output blocks are its ways in and out. Its card: 'Save as template' makes it a block here."})
  for _, tpl in ipairs(require("conjunction.custom_blocks").templates()) do
    blocks.children[#blocks.children + 1] = item(tpl.label, {entry = {"template", tpl.id},
                                                              text = P.or_(tpl.text, "A block of your own.")})
  end
  top[#top + 1] = blocks
  for _, g in ipairs(BL.GROUPS) do
    local gid, gname = g[1], g[2]
    if gid ~= "game" then
      local kinds = {}
      for _, k in ipairs(BL.KINDS) do if k.group == gid then kinds[#kinds + 1] = k end end
      if #kinds > 0 then
        local it = item(gname, {bold = true, colour = hex(BL.GROUP_COLOUR[gid]),
                                expanded = gid == "flow" or gid == "wait" or gid == "check"})
        for _, k in ipairs(kinds) do
          it.children[#it.children + 1] = item(k.label, {entry = {"kind", k.id}, text = k.text})
        end
        top[#top + 1] = it
      end
    end
  end
  local game = item("Game blocks (all of them)", {bold = true, colour = hex("#9a9aa4")})
  for _, sec in ipairs(BP.game_entries(self:catalog())) do
    local s = item(sec[1] .. " (" .. #sec[2] .. ")", {colour = hex("#b4b4bc")})
    for _, e in ipairs(sec[2]) do s.children[#s.children + 1] = item(e[1], {entry = e[2], text = e[3]}) end
    game.children[#game.children + 1] = s
  end
  top[#top + 1] = game
  self.items = top
end

function BP:filter(text)
  local words = {}
  for w in S.lower(text):gmatch("%S+") do words[#words + 1] = w end
  local function visit(it)
    if it.entry then
      local hay = S.lower(it.text_label .. " " .. P.str(it.text or "") .. " " .. it.entry[2])
      local show = true
      for _, w in ipairs(words) do if not hay:find(w, 1, true) then show = false break end end
      it.hidden = not show
      return show
    end
    local any = false
    for _, ch in ipairs(it.children) do any = visit(ch) or any end
    it.hidden = #words > 0 and not any
    if #words > 0 and any then it.expanded = true end
    return any
  end
  for _, it in ipairs(self.items) do visit(it) end
  if #words == 0 then self:fill() end
end

-- the rows shown, in order: {it, depth}
function BP:rows()
  local out = {}
  local function walk(list, depth)
    for _, it in ipairs(list) do
      if not it.hidden then
        out[#out + 1] = {it = it, depth = depth}
        if it.expanded and #it.children > 0 then walk(it.children, depth + 1) end
      end
    end
  end
  walk(self.items, 0)
  return out
end

-- what the hovered (or current) item does, under the list
function BP:show_help(it)
  if it == nil or not it.text then return end
  local used = ""
  if it.entry and it.entry[1] == "kind" then
    if self.examples == nil then
      local ok, ex = pcall(require("conjunction.json").read, require("conjunction.paths").DATA .. "\\block_examples.json")
      self.examples = ok and ex or {}
    end
    local ex = P.get(self.examples, it.entry[2]) or {}
    if P.T(P.get(ex, "count")) then
      used = string.format("<br><span style='color:#7c7c84'>The game uses it %s times in %s quest files.</span>",
                           P.str(ex.count), P.str(ex.files))
    end
  end
  self.help = "<b>" .. it.text_label .. "</b><br>" .. it.text .. used
end

-- the help label's picture (a QLabel, rich text, word wrap: 11 px #a8a8b0 on #1f1f23, padding 6)
function BP:help_picture(width)
  local key = self.help .. "|" .. width
  if self.help_pic and self.help_key == key then return self.help_pic end
  if self.help_pic and self.help_pic.id then w3.ui.image_free(self.help_pic.id) end
  self.help_key = key
  local tmp = os.getenv("TEMP") or "."
  local src = tmp .. "\\cj_palette_help.html"
  local f = io.open(src, "wb")
  if f then f:write(self.help) f:close() end
  local out = tmp .. "\\cj_palette_help.png"
  local ok = pcall(w3.plugin.cj_qt_rich, out, tostring(width), "auto", src, "11", "a8a8b0ff", "1f1f23ff",
                   string.format("%08x", require("conjunction.ui.richtext").LINK), "0")
  self.help_pic = false
  if ok then
    local id, w, h = w3.ui.image_load(out)
    if id then self.help_pic = {id = id, w = w, h = h} end
  end
  return self.help_pic
end

function BP:frame(r, hit)
  D.fill(r.x, r.y, r.w, r.h, C.bg)
  local eh = CT.edit_h()
  local _, s = CT.edit("vg.palette.search", r.x, r.y, r.w, self.search,
                       {placeholder = "Search blocks (wait, fact, door, spawn)", style = self.edit_style})
  if s ~= self.search then
    self.search = s
    self:filter(s)
  end
  local ty = r.y + eh + 4
  local th = r.h - eh - 4 - 4 - BP.HELP_H
  self:tree({x = r.x, y = ty, w = r.w, h = th}, hit)
  -- the help: border-top 1 px #333, padding 6, the text at the top left (its indent: half an 'x')
  local hy = ty + th + 4
  D.fill(r.x, hy, r.w, BP.HELP_H, C.help_bg)
  D.fill(r.x, hy, r.w, 1, C.help_edge)
  local indent = Q.text_w("x", 11) // 2
  local pic = self:help_picture(r.w - 12 - indent)      -- (QLabel's indent: at the side it is aligned to only)
  if pic then
    D.clip(r.x, hy + 1, r.w, BP.HELP_H - 1, function() D.image(pic.id, r.x + 6 + indent, hy + 1 + 6 + 2, pic.w, pic.h) end)
  end
end

function BP:tree(r, hit)
  local rows = self:rows()
  local bar = self.bar
  bar.single, bar.page = 1, r.h // BP.ROW
  IV.range(bar, #rows - bar.page)
  local vw = r.w
  local scrolls = #rows > bar.page
  if scrolls then vw = vw - 10 end
  local mx, my, wheel = w3.ui.mouse()
  local _, hovered = hit("vg.palette.tree", {x = r.x, y = r.y, w = vw, h = r.h})
  if hovered and wheel and wheel ~= 0 then IV.wheel(bar, wheel, 3) end
  local i = hovered and bar.value + (my - r.y) // BP.ROW + 1 or nil
  local row = i and rows[i] or nil
  self.hover = row and row.it or nil
  if self.hover and self.hover ~= self.hover_was then self:show_help(self.hover) end
  self.hover_was = self.hover
  if row and w3.ui.mouse_clicked(1) then
    local x0 = r.x + row.depth * BP.IND
    local it = row.it
    if #it.children > 0 and mx >= x0 and mx < x0 + BP.IND then
      it.expanded = not it.expanded
    elseif w3.ui.mouse_double(1) and #it.children > 0 then
      it.expanded = not it.expanded                    -- (a double click on a group opens or closes it)
    elseif it.entry then
      self.current = it
      self:show_help(it)
      if w3.ui.mouse_double(1) then
        if self.on_chosen then self.on_chosen(it.entry) end
      else
        self.press = {mx, my, it = it}
      end
    end
  end
  if self.press then
    if w3.ui.mouse_down(1) then
      local p = self.press
      if not self.dragging and math.abs(mx - p[1]) + math.abs(my - p[2]) >= 10 then
        self.dragging = {entry = p.it.entry, text = p.it.text_label}
      end
    else
      if self.dragging and self.on_drop then self.on_drop(self.dragging.entry, mx, my) end
      self.press, self.dragging = nil, nil
    end
  end
  if self.hover and self.hover.text and not self.dragging then CT.tip("vg.palette." .. self.hover.text_label,
                                                                       {"", self.hover.text}) end
  D.clip(r.x, r.y, vw, r.h, function()
    for k = bar.value + 1, math.min(#rows, bar.value + bar.page + 1) do
      local rw = rows[k]
      local it = rw.it
      local y = r.y + (k - 1 - bar.value) * BP.ROW
      local chosen = it == self.current
      local hov = it == self.hover
      local bg = chosen and C.chosen or (hov and C.hover or C.bg)
      local x0 = r.x + rw.depth * BP.IND
      if bg ~= C.bg then D.fill(x0 + BP.IND, y, r.x + vw - x0 - BP.IND, BP.ROW, bg) end
      if #it.children > 0 then
        Q.draw_part((it.expanded and "pal_branch_open" or "pal_branch_closed") ..
                    (chosen and "_chosen" or (hov and "_hover" or "")), x0, y)
      end
      local tx = x0 + BP.IND + 3
      local lh = Q.line_h(12, it.bold)
      local fg = chosen and C.white or (it.colour or C.text)
      Q.text(tx, y + (BP.ROW - lh + 1) // 2, fg, it.text_label, 12, it.bold, bg)
      local AG = package.loaded["conjunction.agent"]    -- (a block the agent can click: by its name)
      if AG then AG.area("vg.palette." .. tostring(it.text_label) .. "." .. k, x0 + BP.IND, y, r.x + vw - x0 - BP.IND,
                         BP.ROW, it.text_label) end
    end
  end)
  if scrolls then
    SBAR.draw(self.bar_state, "vg.palette.bar", bar, {x = r.x + vw, y = r.y, w = 10, h = r.h}, "v", hit)
  end
end

return BP
