-- File > Library over the game (library_view.LibraryWindow in one of the panel's windows): the quests to play from
-- the quests folder (library.lua installs them), each a QFrame#row (SURFACE, a LINE border, margins 9, 6 apart): its
-- title bold, Ready (green) or Missing (red) at the right, who made it and its version (dim), where it starts (dim),
-- what keeps it from playing (red), the mods it lacks (Get); then the content packs in the game (Page). A scroll area
-- (per pixel, 20 a step) between the heading and the buttons (Open quest folder, Refresh); the last log lines below.
--   local b = LW.new(ed)   b:refresh()   b:frame(r)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local DW = require("conjunction.ui.dialog_window")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local Y = require("conjunction.yaml")
local NUM = require("conjunction.pynum")
local D = w3.ui.draw
local LW = {}
LW.__index = LW

local GREEN = (0x5c << 24) | (0xb8 << 16) | (0x5c << 8) | 255     -- (icons.GREEN)

local function truthy(v) return not (v == nil or v == false or v == Y.null or v == 0 or v == "" or
                                     (type(v) == "table" and next(v) == nil)) end
local function pystr(v)
  if v == nil or v == Y.null then return "None" end
  if v == true then return "True" elseif v == false then return "False" end
  return NUM.str(v)
end
local function join(list, sep)
  local out = {}
  for _, x in ipairs(list) do if truthy(x) then out[#out + 1] = pystr(x) end end
  return table.concat(out, sep)
end

function LW.new(ed)
  local self = setmetatable({ed = ed, bar = IV.bar(20, 0, 0), entries = {}, lacking = {}, logs = {}}, LW)
  self:refresh()
  return self
end

-- library.sync and what the window shows of it
function LW:refresh()
  local LIB = require("conjunction.library")
  local logs = {}
  local ok, entries = pcall(LIB.sync, function(m) logs[#logs + 1] = m end)
  if not ok then
    logs = {"The library could not be read: " .. tostring(entries)}
    entries = {}
  end
  self.entries = entries
  self.lacking = {}
  for _, e in ipairs(entries) do if e.status ~= "installed" then self.lacking[#self.lacking + 1] = e.file end end
  local ok2, packs = pcall(require("conjunction.content").installed_packs)
  self.packs = ok2 and packs or {}
  local last = {}
  for i = math.max(1, #logs - 2), #logs do last[#last + 1] = logs[i] end
  self.status = table.concat(last, "  ")
  self.items = nil
end

-- the scroll area's items down (heads, rows, the empty line), each {kind, h(w), draw(x, y, w)}
local function wrapped_h(text, px, w)
  local _, h = DW.label_lines(text, px or T.FONT, false, w)
  return h
end
local function draw_wrapped(x, y, w, text, fg, px, bg, bold)
  local lines = DW.label_lines(text, px or T.FONT, bold, w)
  for k, l in ipairs(lines) do Q.text(x, y + (k - 1) * Q.line_h(px, bold), fg, l.s, px or T.FONT, bold, bg) end
end

function LW:row_parts(e)
  local m = e.manifest or {}
  local LIB = require("conjunction.library")
  local parts = {}
  local ok = e.status == "installed"
  parts[#parts + 1] = {kind = "top", title = truthy(m.title) and pystr(m.title) or e.file, ok = ok}
  local ver = truthy(m.version) and ("version " .. pystr(m.version)) or ""
  local exp = join(type(m.expansions) == "table" and m.expansions or {}, ", ")
  parts[#parts + 1] = {kind = "dim", text = join({m.author, ver, exp}, ", ")}
  local st = type(m.starts) == "table" and m.starts or {}
  if truthy(st.text) then
    parts[#parts + 1] = {kind = "dim_wrap", text = "Starts: " .. pystr(st.text) ..
                                                  (truthy(st.world) and (" (" .. pystr(st.world) .. ")") or "")}
  end
  local packs = e.missing_packs or {}
  local said = {}
  for _, n in ipairs(packs) do said[LIB.pack_problem(n)] = true end
  for _, p in ipairs(e.problems or {}) do
    if not said[p] then parts[#parts + 1] = {kind = "problem", text = p} end
  end
  for _, need in ipairs(packs) do parts[#parts + 1] = {kind = "pack", need = need} end
  return parts
end

local function pack_texts(need)
  local name = truthy(need.name) and need.name or need.id
  local ver = truthy(need.version) and (" " .. pystr(need.version)) or ""
  local why = pystr(need.why ~= nil and need.why or "")
  local old = why:sub(1, 3) == "old"
  local t = "Needs " .. pystr(name) .. ver .. (old and (" or newer (installed: " .. why:sub(6) .. ")") or "") ..
            (truthy(need.author) and (" by " .. pystr(need.author)) or "")
  local used = {}
  for _, u in ipairs(type(need.used) == "table" and need.used or {}) do
    used[#used + 1] = truthy(u.name) and u.name or u.ref
  end
  local x
  if #used > 0 then
    local first = {}
    for i = 1, math.min(10, #used) do first[i] = pystr(used[i]) end
    x = "For: " .. table.concat(first, ", ") .. (#used > 10 and string.format(" and %d more", #used - 10) or "")
  end
  return t, x
end

-- a part's height at the column's width
function LW:part_h(p, w)
  if p.kind == "top" then return Q.line_h(T.FONT, true) end
  if p.kind == "dim" then return Q.line_h(T.FONT_SMALL) end
  if p.kind == "dim_wrap" then return wrapped_h(p.text, T.FONT_SMALL, w) end
  if p.kind == "problem" then return wrapped_h(p.text, T.FONT, w) end
  if p.kind == "pack" then
    local t, x = pack_texts(p.need)
    local bw = truthy(p.need.url) and (Q.button_size("Get") + 6) or 0
    local _, bh = Q.button_size("Get")
    local h = math.max(wrapped_h(t, T.FONT, w - bw), truthy(p.need.url) and bh or 0)
    if x then h = h + 1 + wrapped_h(x, T.FONT_SMALL, w) end
    return 2 + h + 2
  end
  return 0
end

function LW:build(w)
  local items = {}
  local inner = w - 2 - 18
  local head_h = Q.line_h(T.FONT_HEAD, true) + 4
  if #self.entries > 0 then items[#items + 1] = {kind = "head", text = "Quests", h = head_h} end
  for _, e in ipairs(self.entries) do
    local parts = self:row_parts(e)
    local h = 0
    for i, p in ipairs(parts) do
      p.h = self:part_h(p, inner)
      h = h + p.h + (i > 1 and 6 or 0)
    end
    items[#items + 1] = {kind = "row", parts = parts, h = 1 + 9 + h + 9 + 1, entry = e}
  end
  if #self.entries == 0 then
    items[#items + 1] = {kind = "empty", text = "No quests yet", h = Q.line_h(T.FONT_SMALL)}
  end
  if #self.packs > 0 then
    items[#items + 1] = {kind = "head", text = "Content packs", h = head_h}
    for _, pk in ipairs(self.packs) do
      local name = pystr(truthy(pk.name) and pk.name or pk.id)
      local title = (name .. " " .. pystr(pk.version ~= nil and pk.version or "")):match("^%s*(.-)%s*$")
      local sub = join({pk.author, join(type(pk.kinds) == "table" and pk.kinds or {}, ", "),
                        join(type(pk.folders) == "table" and pk.folders or {}, ", ")}, ", ")
      local _, bh = Q.button_size("Page")
      local col = Q.line_h(T.FONT, true) + 6 + Q.line_h(T.FONT_SMALL)
      local h = truthy(pk.url) and math.max(col, bh) or col
      items[#items + 1] = {kind = "pack_row", title = title, sub = sub, url = truthy(pk.url) and pk.url or nil,
                           h = 1 + 9 + h + 9 + 1, col = col}
    end
  end
  return items
end

local function open_url(u)
  if w3.proc and w3.proc.run then require("conjunction.fsutil").show(tostring(u)) end
end

function LW:draw_item(it, x, y, w, hit)
  if it.kind == "head" then
    Q.label(x, y, it.text, "head", T.BG)
  elseif it.kind == "empty" then
    Q.label(x, y, it.text, "dim", T.BG)
  elseif it.kind == "row" then
    Q.frame(x, y, w, it.h, T.SURFACE, T.LINE)
    local cx, cy, cw = x + 10, y + 10, w - 20
    for i, p in ipairs(it.parts) do
      if i > 1 then cy = cy + 6 end
      if p.kind == "top" then
        local word = p.ok and "Ready" or "Missing"
        local ww = Q.hint_w(word, T.FONT, true)
        Q.text(cx, cy, T.BRIGHT, p.title, T.FONT, true, T.SURFACE)
        Q.text(cx + cw - ww, cy, p.ok and GREEN or T.RED, word, T.FONT, true, T.SURFACE)
      elseif p.kind == "dim" then
        Q.text(cx, cy, T.DIM, p.text, T.FONT_SMALL, false, T.SURFACE)
      elseif p.kind == "dim_wrap" then
        draw_wrapped(cx, cy, cw, p.text, T.DIM, T.FONT_SMALL, T.SURFACE)
      elseif p.kind == "problem" then
        draw_wrapped(cx, cy, cw, p.text, T.RED, T.FONT, T.SURFACE)
      elseif p.kind == "pack" then
        local t, xtext = pack_texts(p.need)
        local url = truthy(p.need.url) and p.need.url or nil
        local bw, bh = Q.button_size("Get")
        local tw = cw - (url and (bw + 6) or 0)
        local th = wrapped_h(t, T.FONT, tw)
        local top = math.max(th, url and bh or 0)
        draw_wrapped(cx, cy + 2 + Q.vcenter(top, th), tw, t, T.RED, T.FONT, T.SURFACE)
        if url and CT.button("panel.win.library.get." .. tostring(p.need.id), cx + cw - bw, cy + 2 + (top - bh) // 2,
                             "Get", {w = bw, h = bh, tip = "lib.get"}) then
          open_url(url)
        end
        if xtext then draw_wrapped(cx, cy + 2 + top + 1, cw, xtext, T.DIM, T.FONT_SMALL, T.SURFACE) end
      end
      cy = cy + p.h
    end
  elseif it.kind == "pack_row" then
    Q.frame(x, y, w, it.h, T.SURFACE, T.LINE)
    local cx, cy, cw = x + 10, y + 10, w - 20
    local bw, bh = Q.button_size("Page")
    local inner = it.h - 20
    local ty = cy + (inner - it.col) // 2
    Q.text(cx, ty, T.BRIGHT, it.title, T.FONT, true, T.SURFACE)
    Q.text(cx, ty + Q.line_h(T.FONT, true) + 6, T.DIM, it.sub, T.FONT_SMALL, false, T.SURFACE)
    if it.url and CT.button("panel.win.library.page." .. it.title, cx + cw - bw, cy + (inner - bh) // 2, "Page",
                            {w = bw, h = bh, tip = "lib.page"}) then
      open_url(it.url)
    end
  end
end

function LW:open_folder()
  local LIB = require("conjunction.library")
  w3.fs.mkdir(LIB.QUESTS)
  if w3.proc and w3.proc.run then require("conjunction.fsutil").show(LIB.QUESTS) end
end

function LW:frame(r)
  DW.background(r)
  local hit = function(id, b) return self.win:hit(id, b) end
  local x, y, w = r.x + 16, r.y + 12, r.w - 32
  local bottom = r.y + r.h - 12
  Q.label(x, y, "Library", "head", T.BG)
  local _, hh = Q.label_size("Library", "head")
  -- the bottom: the last log lines (dim, wrapped), the buttons above them
  local sh = self.status ~= "" and wrapped_h(self.status, T.FONT_SMALL, w) or Q.line_h(T.FONT_SMALL)
  local _, bh = Q.button_size("Refresh")
  local sy = bottom - sh
  local by = sy - 8 - bh
  local ay = y + hh + 8
  local ah = by - 8 - ay
  -- the scroll area: the items 6 apart, the bar when they are higher than it
  local items = self:build(w)
  local total = 0
  for i, it in ipairs(items) do total = total + it.h + (i > 1 and 6 or 0) end
  local bar = total > ah
  local vw = bar and (w - 10) or w
  if bar then
    items = self:build(vw)
    total = 0
    for i, it in ipairs(items) do total = total + it.h + (i > 1 and 6 or 0) end
  end
  local b = self.bar
  b.single, b.page = 20, ah
  IV.range(b, math.max(0, total - ah))
  local over = CT.over({x = x, y = ay, w = vw, h = ah})
  local _, _, wheel = w3.ui.mouse()
  if over and wheel and wheel ~= 0 then IV.wheel(b, wheel >= 0 and math.min(wheel, 1) or math.max(wheel, -1), 3) end
  D.clip(x, ay, vw, ah, function()
    local iy = ay - b.value
    for i, it in ipairs(items) do
      if i > 1 then iy = iy + 6 end
      if iy + it.h > ay and iy < ay + ah then self:draw_item(it, x, iy, vw, hit) end
      iy = iy + it.h
    end
  end)
  if bar then SBAR.draw(self, "library.vbar", b, {x = x + vw, y = ay, w = 10, h = ah}, "v", hit) end
  local fw = Q.button_size("Open quest folder")
  if CT.button("panel.win.library.folder", x, by, "Open quest folder", {w = fw, h = bh, tip = "lib.folder"}) then
    self:open_folder()
  end
  local rw = Q.button_size("Refresh")
  if CT.button("panel.win.library.refresh", x + fw + 6, by, "Refresh", {w = rw, h = bh, tip = "lib.refresh"}) then
    self:refresh()
  end
  if self.status ~= "" then draw_wrapped(x, sy, w, self.status, T.DIM, T.FONT_SMALL, T.BG) end
end

return LW
