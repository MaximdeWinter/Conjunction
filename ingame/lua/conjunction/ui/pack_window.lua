-- Build > Content pack over the game (pack_view.PackMakerWindow in one of the panel's windows): a creator picks their
-- mod folder; the window shows what is in it, what keeps it from working with everyone's quests, and writes the pack
-- card (packmaker.lua). A QVBoxLayout (margins 16 12 16 12, 8 apart): Content pack (#head), the mod's choice with
-- Other folder and From 3D files, the summary (dim), a scroll area (its list: margins 9, 6 apart) of check rows
-- (QFrame#row: the level's mark, the text, the things it names, dim) and For quests, Pack card: the card's form (8
-- apart; an empty name or link warned of only at a press), the status (dim) - once done a check, what next and Open
-- folder - and Write pack card (Build pack for 3D files).
--   local b = PW.new(ed, folder)   b:open(folder)   b:frame(r)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local DW = require("conjunction.ui.dialog_window")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local TL = require("conjunction.ui.textlayout")
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local D = w3.ui.draw
local PW = {}
PW.__index = PW

local function hex(s) return (tonumber(s:sub(2), 16) << 8) | 255 end
PW.LEVEL = {ok = {"circle-check", hex("#5cb85c")}, fix = {"wrench", hex("#8ab4e5")},
            warn = {"triangle-alert", hex("#e5b85c")}, info = {"info", hex("#9a9a9a")}}
PW.FIELDS = {{"name", "Name"}, {"version", "Version"}, {"author", "Author"}, {"url", "Link"},
             {"description", "Description"}}
-- the checks of the card's own fields: shown only once Write pack card / Build pack is pressed with them empty (MaximdeWinter
-- 13.11.: "No download link" before anything was entered came too early)
PW.FIELD_CHECKS = {card = true, url = true}
local GREY = hex("#cfcfcf")
local SPACING, LIST_M, ROW_M = 8, 9, 9

-- the game's DLC and mod folders that could be packs: not Conjunction's own, not quests made with it
function PW.mod_folders(game)
  local C = require("conjunction.content")
  local PM = require("conjunction.packmaker")
  local own = {}
  pcall(function()
    local PR = require("conjunction.project")
    for _, p in ipairs(PR.recent()) do
      local id = PYS.lower(PR.open(p):id())
      own["dlc" .. id], own["moddlc" .. id] = true, true
    end
  end)
  local out = {}
  for _, f in ipairs(C.folders(game)) do
    local kind, name, path = f[1], f[2], f[3]
    local low = PYS.lower(name)
    -- (Conjunction's own: its libraries, texts, runtime, sessions)
    if kind ~= "game" and not low:find("^dlcconjunction") and not low:find("^modconjunction") and
       not own[low] and not w3.fs.exists(path .. "\\" .. "conjunction_quest.yml") and #PM.bundles_in(path) > 0 then
      out[#out + 1] = path
    end
  end
  return out
end

function PW.new(ed, folder)
  local self = setmetatable({ed = ed, bar = IV.bar(20, 0, 0), mode = "mod", fields = {}, status = ""}, PW)
  self:fill_pick()
  if folder then self:open(folder)
  elseif self.paths[1] then self:open(self.paths[1]) end
  return self
end

function PW:fill_pick()
  local game = require("conjunction.config").load().game or ""
  local ok, folders = pcall(PW.mod_folders, game)
  folders = ok and folders or {}
  self.paths, self.labels = {}, {}
  for _, f in ipairs(folders) do
    self.paths[#self.paths + 1] = f
    local rel = f:sub(1, #game + 1) == game .. "\\" and f:sub(#game + 2) or f
    self.labels[#self.labels + 1] = rel
  end
  if #folders == 0 then self.labels[1] = "No mods in the game" end
  self.index = 1
end

function PW:open(folder)
  if not folder then return end
  local PM = require("conjunction.packmaker")
  self.mode = "mod"
  self.folder = folder
  local i
  for k, p in ipairs(self.paths) do if p == folder then i = k end end
  if not i then
    self.paths[#self.paths + 1] = folder
    if #self.paths == 1 then self.labels = {} end
    self.labels[#self.labels + 1] = folder
    i = #self.paths
  end
  self.index = i
  self.report = PM.inspect(folder)
  local m = self.report.meta
  for _, f in ipairs(PW.FIELDS) do
    self.fields[f[1]] = P.str(P.get(m, f[1], ""))
    CT.state("panel.win.packs." .. f[1]).e = nil
  end
  if not P.T(P.get(m, "name")) then self.fields.name = (folder:gsub("[\\/]+$", "")):match("([^\\/]*)$") end
  if not P.T(P.get(m, "version")) then self.fields.version = "1.0" end
  self.status, self.done, self.asked, self.anyway = "", nil, nil, false
  self.items = nil
end

-- the summary: the templates by category (most first), the items, the voice files
function PW:summary()
  local r = self.report
  if not r then
    return "A pack card names a mod for the quests that use its things. Players who lack the mod are told where " ..
           "to get it. Pick the mod's folder with Other folder. If you have models and no mod yet: From 3D files " ..
           "(a folder of .fbx files)"
  end
  if r.fbx_summary then return r.fbx_summary end
  local counts = r.counts(r)
  local cats = {}
  for i, cat in ipairs(Y.keys(counts)) do cats[i] = {cat, counts[cat], i} end
  table.sort(cats, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[3] < b[3] end)
  local parts = {}
  for _, c in ipairs(cats) do parts[#parts + 1] = string.format("%d %s", c[2], PYS.lower(c[1])) end
  if #r.items > 0 then parts[#parts + 1] = string.format("%d items", #r.items) end
  if r.voices > 0 then parts[#parts + 1] = string.format("%d voice files", r.voices) end
  return #parts > 0 and table.concat(parts, ", ") or "Nothing found"
end

local function lines_of(text, px, bold, w) return TL.wrap(text, px, bold, math.max(0, w), "word") end

-- a rich label's runs ({text, bold}) set into lines at a width (the words as they fit, spaces collapsed as HTML does)
local function rich_lines(runs, px, w)
  local words = {}
  for _, r in ipairs(runs) do
    for word in r[1]:gmatch("%S+") do words[#words + 1] = {word, r[2]} end
  end
  local out, line, lw = {}, {}, 0
  local sp = Q.text_w(" ", px)
  for _, wd in ipairs(words) do
    local ww = Q.text_w(wd[1], px, wd[2])
    local add = (#line > 0 and sp or 0) + ww
    if #line > 0 and lw + add > w then
      out[#out + 1] = line
      line, lw = {}, 0
      add = ww
    end
    line[#line + 1] = wd
    lw = lw + add
  end
  if #line > 0 then out[#out + 1] = line end
  return out
end

-- a 3D folder's section as one box (MaximdeWinter 13.11.: what is what, how it was found): its title and count, how its
-- files are found (dim), then a row per thing - its mark, name, file at the right; its values (label dim, value
-- bright, a missing one amber) flowing in lines; a note under them
local function section_item(sec, w)
  local iw = w - 2 - 2 * ROW_M
  local small, lh_s = T.FONT_SMALL, Q.line_h(T.FONT_SMALL)
  local hint = lines_of(sec.hint, small, false, iw)
  local rows = {}
  local h = 2 + 2 * ROW_M + Q.line_h(T.FONT, true) + 2 + #hint * lh_s
  for _, r in ipairs(sec.rows) do
    local vx = 16 + 6
    local flow, line, lx = {}, {}, 0
    for _, f in ipairs(r.fields or {}) do
      local pw = Q.text_w(f[1], small) + 6 + Q.text_w(f[2], small)
      local at = #line > 0 and lx + 18 or 0
      if #line > 0 and at + pw > iw - vx then flow[#flow + 1], line, at = line, {}, 0 end
      line[#line + 1] = {f, at}
      lx = at + pw
    end
    if #line > 0 then flow[#flow + 1] = line end
    local note = r.note and lines_of(r.note, small, false, iw - vx) or {}
    local rh = 8 + Q.line_h() + #flow * (lh_s + 2) + #note * lh_s + 8
    rows[#rows + 1] = {r = r, flow = flow, note = note, h = rh}
    h = h + rh
  end
  if #rows > 0 then h = h + 6 end
  return {h = h, draw = function(x, y, ww)
    Q.frame(x, y, ww, h, T.SURFACE, T.LINE)
    local cx, cy = x + 1 + ROW_M, y + 1 + ROW_M
    Q.text(cx, cy, T.BRIGHT, sec.title, T.FONT, true, T.SURFACE)
    local count = #sec.rows > 0 and ("  " .. #sec.rows) or "  none"
    Q.text(cx + Q.text_w(sec.title, T.FONT, true), cy, T.DIM, count, T.FONT, false, T.SURFACE)
    cy = cy + Q.line_h(T.FONT, true) + 2
    for k, l in ipairs(hint) do Q.text(cx, cy + (k - 1) * lh_s, T.DIM, l.s, small, false, T.SURFACE) end
    cy = cy + #hint * lh_s
    if #rows > 0 then cy = cy + 6 end
    for _, row in ipairs(rows) do
      local r = row.r
      D.fill(cx, cy, iw, 1, T.LINE)
      local ry = cy + 8
      local mark = PW.LEVEL[r.level]
      Q.draw_icon(mark[1], mark[2], 16, cx, ry + Q.vcenter(Q.line_h(), 16))
      Q.text(cx + 16 + 6, ry, T.BRIGHT, r.name, T.FONT, true, T.SURFACE)
      if r.side then
        local sw = Q.text_w(r.side, small)
        Q.text(cx + iw - sw, ry + (Q.line_h() - lh_s) // 2, T.DIM, r.side, small, false, T.SURFACE)
      end
      ry = ry + Q.line_h() + 2
      for _, line in ipairs(row.flow) do
        for _, p in ipairs(line) do
          local f, px = p[1], cx + 16 + 6 + p[2]
          Q.text(px, ry, T.DIM, f[1], small, false, T.SURFACE)
          Q.text(px + Q.text_w(f[1], small) + 6, ry, f[3] and PW.LEVEL.warn[2] or T.TEXT, f[2], small, false, T.SURFACE)
        end
        ry = ry + lh_s + 2
      end
      for k, l in ipairs(row.note) do Q.text(cx + 16 + 6, ry + (k - 1) * lh_s, T.DIM, l.s, small, false, T.SURFACE) end
      cy = cy + row.h
    end
  end}
end

-- the scroll area's items: the checks' rows, For quests; each {h, draw(x, y, w)}
function PW:build(w)
  local items = {}
  local r = self.report
  if not r then return items end
  local tw = w - 2 - 2 * ROW_M - 16 - 6
  local checks = {}
  for _, c in ipairs(self.asked or {}) do               -- (gone once the field has something in it)
    if not (self.fields[c[2]] or ""):find("%S") then checks[#checks + 1] = c end
  end
  for _, c in ipairs(r.checks) do
    if not (PW.FIELD_CHECKS[c[2]] and c[1] ~= "ok") then checks[#checks + 1] = c end
  end
  for _, c in ipairs(checks) do
    local level, text, things = c[1], c[3], c[4] or {}
    local tl = lines_of(text, T.FONT, false, tw)
    local th = math.max(1, #tl) * Q.line_h()
    local xs, xl = nil, nil
    if #things > 0 then
      xs = table.concat({table.unpack(things, 1, math.min(8, #things))}, ", ") ..
           (#things > 8 and string.format(" and %d more", #things - 8) or "")
      xl = lines_of(xs, T.FONT_SMALL, false, tw)
    end
    local h = 2 + 2 * ROW_M + th + (xl and (6 + math.max(1, #xl) * Q.line_h(T.FONT_SMALL)) or 0)
    items[#items + 1] = {h = h, draw = function(x, y, ww)
      Q.frame(x, y, ww, h, T.SURFACE, T.LINE)
      local mark = PW.LEVEL[level]
      Q.draw_icon(mark[1], mark[2], 16, x + 1 + ROW_M, y + 1 + ROW_M)
      local cx = x + 1 + ROW_M + 16 + 6
      for k, l in ipairs(tl) do Q.text(cx, y + 1 + ROW_M + (k - 1) * Q.line_h(), T.TEXT, l.s, T.FONT, false, T.SURFACE) end
      if xl then
        local yy = y + 1 + ROW_M + th + 6
        for k, l in ipairs(xl) do
          Q.text(cx, yy + (k - 1) * Q.line_h(T.FONT_SMALL), T.DIM, l.s, T.FONT_SMALL, false, T.SURFACE)
        end
      end
    end}
  end
  if self.mode == "fbx" then                    -- (the 3D files' plan: its sections)
    for _, sec in ipairs(self.fbx_sections or {}) do items[#items + 1] = section_item(sec, w) end
    return items
  end
  -- For quests: the mod's things by name, grouped as the catalog sorts them
  local groups = Y.map()
  for _, t in ipairs(r.templates) do
    if t.cat ~= "Internal" then
      local cat = P.T(t.cat) and t.cat or "Other"
      if groups[cat] == nil then groups[cat] = {} end
      local g = groups[cat]
      g[#g + 1] = t.name
    end
  end
  if #r.items > 0 then
    local g = {}
    for _, it in ipairs(r.items) do g[#g + 1] = P.T(it.label) and it.label or it.name end
    groups.Items = g
  end
  local cats = Y.keys(groups)
  table.sort(cats)
  local iw = w - 2 - 2 * ROW_M
  local blocks = {}
  for _, cat in ipairs(cats) do
    local set, names = {}, {}
    for _, n in ipairs(groups[cat]) do if not set[n] then set[n] = true names[#names + 1] = n end end
    table.sort(names)
    local shown = table.concat({table.unpack(names, 1, math.min(12, #names))}, ", ") ..
                  (#names > 12 and string.format(" and %d more", #names - 12) or "")
    local ls = rich_lines({{cat, true}, {"  " .. shown, false}}, T.FONT_SMALL, iw)
    blocks[#blocks + 1] = {lines = ls, h = math.max(1, #ls) * Q.line_h(T.FONT_SMALL)}
  end
  local h = 2 + 2 * ROW_M + Q.line_h(T.FONT, true)
  if #blocks == 0 then h = h + 6 + Q.line_h() end
  for _, b in ipairs(blocks) do h = h + 6 + b.h end
  items[#items + 1] = {h = h, draw = function(x, y, ww)
    Q.frame(x, y, ww, h, T.SURFACE, T.LINE)
    local cx, cy = x + 1 + ROW_M, y + 1 + ROW_M
    Q.text(cx, cy, T.BRIGHT, "For quests", T.FONT, true, T.SURFACE)
    cy = cy + Q.line_h(T.FONT, true)
    if #blocks == 0 then Q.text(cx, cy + 6, T.TEXT, "Nothing", T.FONT, false, T.SURFACE) end
    local sp = Q.text_w(" ", T.FONT_SMALL)
    for _, b in ipairs(blocks) do
      cy = cy + 6
      for k, line in ipairs(b.lines) do
        local lx = cx
        for n, wd in ipairs(line) do
          if n > 1 then lx = lx + sp end
          Q.text(lx, cy + (k - 1) * Q.line_h(T.FONT_SMALL), T.DIM, wd[1], T.FONT_SMALL, wd[2], T.SURFACE)
          lx = lx + Q.text_w(wd[1], T.FONT_SMALL, wd[2])
        end
      end
      cy = cy + b.h
    end
  end}
  return items
end

-- a QPushButton with an icon (16) before its text, as settings_window draws them
local function icon_button(self, id, x, y, text, icon, opts)
  opts = opts or {}
  local tw = text ~= "" and Q.hint_w(text) or 0
  local w = opts.w or (16 + 4 + tw + 22)
  local h = opts.h or ((text ~= "" and Q.line_h() or 16) + 12)
  local b = {x = x, y = y, w = w, h = h}
  local clicked, hovered, held = self.win:hit(id, b)
  if opts.disabled then clicked, hovered, held = false, false, false end
  Q.frame(b.x, b.y, b.w, b.h, (held and hovered) and T.CHOSEN or T.BUTTON, (hovered or held) and T.EDGE_HOVER or T.EDGE)
  local cw = w - 22
  local label = 16 + (text ~= "" and (4 + Q.text_w(text)) or 0)
  local ix = x + 11 + (cw - label) // 2
  local iy = y + 6 + (h - 12 - 16) // 2
  Q.draw_icon(icon, GREY, 16, ix, iy)
  if text ~= "" then
    local bg = (held and hovered) and T.CHOSEN or T.BUTTON
    Q.text(ix + 18, y + 6 + (h - 12 - Q.line_h()) // 2, opts.disabled and T.DISABLED_TEXT or T.TEXT, text, T.FONT, false, bg)
  end
  if hovered and opts.tip then CT.tip("panel.win.packs." .. id, opts.tip) end
  return clicked, w, h
end
local function button_w(text) return 16 + 4 + Q.hint_w(text) + 22 end

function PW:frame(r)
  DW.background(r)
  local hit = function(id, b) return self.win:hit(id, b) end
  local x, y, w = r.x + 16, r.y + 12, r.w - 32
  local bottom = r.y + r.h - 12
  Q.label(x, y, "Content pack", "head", T.BG)
  local _, hh = Q.label_size("Content pack", "head")
  -- the mod's row: the choice (stretch 1, at least 320), Other folder, From 3D files (8 apart)
  local ry = y + hh + SPACING
  local ew = 31
  local bw1, bw2 = button_w("Other folder"), button_w("From 3D files")
  local cw = w - bw1 - bw2 - 2 * SPACING
  local changed, index = CT.combo("panel.win.packs.pick", x, ry, cw, self.labels, self.index, self.win.rect,
                                  {h = ew, tip = "pack.pick"})
  if changed and self.paths[index] then self:open(self.paths[index]) end
  local _, bh = Q.button_size("Other folder")
  local by0 = ry + (ew - bh) // 2
  if icon_button(self, "folder", x + cw + SPACING, by0, "Other folder", "folder-search", {tip = "pack.folder"}) then
    self:choose()
  end
  if icon_button(self, "fbx", x + cw + SPACING + bw1 + SPACING, by0, "From 3D files", "package-plus", {tip = "pack.fbx"}) then
    self:choose_fbx()
  end
  -- the summary
  local sy = ry + ew + SPACING
  local summary = self:summary()
  local sl = lines_of(summary, T.FONT_SMALL, false, w)
  local shh = math.max(1, #sl) * Q.line_h(T.FONT_SMALL)
  for k, l in ipairs(sl) do Q.text(x, sy + (k - 1) * Q.line_h(T.FONT_SMALL), T.DIM, l.s, T.FONT_SMALL, false, T.BG) end
  -- the bottom: the status and Write pack card; the form above it (Pack card)
  local _, eh = Q.edit_size(118)
  local lh_s = Q.line_h(T.FONT_SMALL)
  local row_h = eh
  local by = bottom - bh
  local fy = by - 2 * SPACING - (#PW.FIELDS * row_h + (#PW.FIELDS - 1) * SPACING)
  local fhy = fy - 6 - Q.line_h(T.FONT, true)
  local ay = sy + shh + SPACING
  local ah = fhy - 2 * SPACING - ay
  -- the scroll area: the list's margins 9, its rows 6 apart, the bar when they are higher than it
  local items = self:build(w - 2 * LIST_M)
  local total = 2 * LIST_M
  for i, it in ipairs(items) do total = total + it.h + (i > 1 and 6 or 0) end
  local bar = total > ah
  local vw = bar and (w - 10) or w
  if bar then
    items = self:build(vw - 2 * LIST_M)
    total = 2 * LIST_M
    for i, it in ipairs(items) do total = total + it.h + (i > 1 and 6 or 0) end
  end
  local b = self.bar
  b.single, b.page = 20, ah
  IV.range(b, math.max(0, total - ah))
  local over = CT.over({x = x, y = ay, w = vw, h = ah})
  local _, _, wheel = w3.ui.mouse()
  if over and wheel and wheel ~= 0 then IV.wheel(b, wheel >= 0 and math.min(wheel, 1) or math.max(wheel, -1), 3) end
  D.clip(x, ay, vw, ah, function()
    local iy = ay + LIST_M - b.value
    for i, it in ipairs(items) do
      if i > 1 then iy = iy + 6 end
      if iy + it.h > ay and iy < ay + ah then it.draw(x + LIST_M, iy, vw - 2 * LIST_M) end
      iy = iy + it.h
    end
  end)
  if bar then SBAR.draw(self, "packs.vbar", b, {x = x + vw, y = ay, w = 10, h = ah}, "v", hit) end
  -- the card's form: its heading, the labels' column as wide as its widest, 8 to the fields, 8 between the rows; a
  -- field the last press found empty with an amber edge until something is in it
  Q.text(x, fhy, T.BRIGHT, "Pack card", T.FONT, true, T.BG)
  local missing = {}
  for _, c in ipairs(self.asked or {}) do missing[c[2]] = true end
  local lw = 0
  for _, f in ipairs(PW.FIELDS) do lw = math.max(lw, Q.hint_w(f[2])) end
  local fx, fw = x + lw + SPACING, w - lw - SPACING
  for k, f in ipairs(PW.FIELDS) do
    local yy = fy + (k - 1) * (row_h + SPACING)
    Q.text(x, yy + Q.vcenter(eh - 2, Q.line_h()), T.TEXT, f[2], T.FONT, false, T.BG)
    local amber = missing[f[1]] and not (self.fields[f[1]] or ""):find("%S")
    local style = amber and setmetatable({edge = PW.LEVEL.warn[2], edge_focus = PW.LEVEL.warn[2]},
                                         {__index = CT.EDIT_STYLE}) or nil
    local _, text = CT.edit("panel.win.packs." .. f[1], fx, yy, fw, self.fields[f[1]] or "",
                            {h = eh, tip = "pack." .. f[1], style = style,
                             placeholder = f[1] == "url" and "https://www.nexusmods.com/witcher3/mods/..." or nil})
    self.fields[f[1]] = text
  end
  -- the status (dim, wrapped, in the middle of its row); once done: a check, what to do next and Open folder; the
  -- window's button at the right
  local label = self.mode == "fbx" and (self.anyway and "Build anyway" or "Build pack") or
                (self.anyway and "Write anyway" or "Write pack card")
  local bwr = button_w(label)
  local done = not self.progress and self.done
  local ow = done and button_w("Open folder") or 0
  local stw = w - bwr - SPACING - (done and (ow + SPACING) or 0)
  local pg = self.progress
  if pg then                                    -- (a build going on: its step, the time so far, a bar of the steps)
    local secs = os.time() - pg.t0
    local line = string.format("Step %d of %d: %s...  %d:%02d", math.max(1, pg.i), pg.n, pg.text, secs // 60, secs % 60)
    local top = by + Q.vcenter(bh, lh_s + 4 + 6)
    Q.text(x, top, T.TEXT, line, T.FONT_SMALL, false, T.BG)
    local bar_y = top + lh_s + 4
    D.fill(x, bar_y, stw, 6, T.SURFACE)
    D.rect(x, bar_y, stw, 6, T.LINE, 1)
    local part = math.max(0, pg.i - 1) / math.max(1, pg.n)
    D.fill(x + 1, bar_y + 1, math.floor((stw - 2) * part), 4, PW.LEVEL.fix[2])
  elseif done then
    local mark = PW.LEVEL.ok
    local ls = lines_of(done.text, T.FONT, false, stw - 16 - 6)
    local th = math.max(1, #ls) * Q.line_h()
    local ty = by + Q.vcenter(bh, th)
    Q.draw_icon(mark[1], mark[2], 16, x, ty + Q.vcenter(Q.line_h(), 16))
    for k, l in ipairs(ls) do Q.text(x + 16 + 6, ty + (k - 1) * Q.line_h(), T.TEXT, l.s, T.FONT, false, T.BG) end
    if icon_button(self, "show", x + w - bwr - SPACING - ow, by, "Open folder", "folder-open", {tip = "pack.show"}) then
      require("conjunction.fsutil").show(done.path, true)
    end
  elseif self.status ~= "" then
    local ls = lines_of(self.status, T.FONT_SMALL, false, stw)
    local th = math.max(1, #ls) * lh_s
    local ty = by + Q.vcenter(bh, th)
    for k, l in ipairs(ls) do Q.text(x, ty + (k - 1) * lh_s, T.DIM, l.s, T.FONT_SMALL, false, T.BG) end
  end
  if icon_button(self, "write", x + w - bwr, by, label, "package-check",
                 {tip = "pack.write", disabled = self.building}) then
    self:write()
  end
end

-- another folder (dialogs.pick_folder: the folder dialog over the game)
function PW:choose()
  require("conjunction.ui.file_dialog").open(self.ed, {title = "Mod folder", folder = true},
                                              function(d) if d then self:open(d) end end)
end

-- --- furniture from 3D files (pack_view.plan_fbx): what the folder brings, then Build pack
function PW:choose_fbx()
  require("conjunction.ui.file_dialog").open(self.ed, {title = "Folder with FBX files and their textures", folder = true},
                                              function(d) if d then self:plan_fbx(d) end end)
end

function PW:plan_fbx(folder)
  local FU = require("conjunction.furniture")
  self.mode, self.fbx_folder, self.done, self.asked, self.anyway = "fbx", folder, nil, nil, false
  self.things, self.pictures, self.pack_items = FU.plan(folder), FU.decals(folder), FU.pack_items(folder)
  local base = (folder:gsub("[\\/]+$", "")):match("([^\\/]*)$")
  local name, prev = {}, false                  -- (str.title)
  for _, c in utf8.codes((base:gsub("_", " "))) do
    local ch = utf8.char(c)
    local cased = PYS.isalpha(ch)
    name[#name + 1] = cased and (prev and PYS.lower(ch) or PYS.upper(ch)) or ch
    prev = cased
  end
  name = table.concat(name)
  self.fields.name, self.fields.version, self.fields.url, self.fields.description = name, "1.0", "", ""
  for _, k in ipairs({"name", "version", "url", "description"}) do CT.state("panel.win.packs." .. k).e = nil end
  -- what the folder brings, by kind (MaximdeWinter 13.11.: what is what, how it was found)
  local function file(p) return p and p:match("([^\\/]*)$") or nil end
  local models = {title = "3D models", rows = {},
                  hint = "Each .fbx file becomes a piece of furniture. Its textures lie beside it: <name>_d.png colour, " ..
                         "<name>_n.png normal"}
  for _, t in ipairs(self.things) do
    local fields = {}
    if t[3] then fields[#fields + 1] = {"Colour", file(t[3])}
    else fields[#fields + 1] = {"Colour", "missing, it will be grey (" .. t[1] .. "_d.png)", true} end
    fields[#fields + 1] = {"Normal", t[4] and file(t[4]) or "flat"}
    fields[#fields + 1] = {"Collision", "box"}
    models.rows[#models.rows + 1] = {level = t[3] and "ok" or "warn", name = t[1], side = file(t[2]), fields = fields}
  end
  local decals = {title = "Decals", rows = {},
                  hint = "Pictures named <name>.decal.png (the longer side 1 m; <name>.decal.2x1.png sets the size)"}
  for _, pc in ipairs(self.pictures) do
    decals.rows[#decals.rows + 1] = {level = "ok", name = pc[1], side = file(pc[2]),
                                     fields = {{"Size", string.format("%g x %g m", pc[3][1], pc[3][2])}}}
  end
  local items = {title = "Items", rows = {}, hint = "From items.yml in this folder"}
  for _, iid in ipairs(Y.keys(self.pack_items)) do
    local d = self.pack_items[iid]
    local fields = {}
    if P.T(P.get(d, "base")) then fields[#fields + 1] = {"Based on", P.str(d.base)} end
    if P.T(P.get(d, "price")) then fields[#fields + 1] = {"Price", P.str(d.price)} end
    if P.T(P.get(d, "weight")) then fields[#fields + 1] = {"Weight", P.str(d.weight)} end
    if P.T(P.get(d, "text")) then fields[#fields + 1] = {"Readable", "yes"} end
    local desc = P.T(P.get(d, "description")) and P.str(d.description) or nil
    items.rows[#items.rows + 1] = {level = "ok", name = P.str(P.or_(P.get(d, "name"), iid)), side = iid,
                                   fields = fields, note = desc}
  end
  self.fbx_sections = {models, decals, items}
  local checks = {}
  if #models.rows == 0 and #decals.rows == 0 and #items.rows == 0 then
    checks[1] = {"warn", "", "This folder has no 3D models, decals or items", {}}
  end
  self.report = {checks = checks, templates = {}, items = {}, voices = 0, counts = function() return Y.map() end,
                 fbx_summary = "A new pack from " .. folder}
  local steps = FU.step_count(self.things, self.pictures, true)
  self.status = string.format("Build pack has %d steps, about %d min (REDkit starts once for each)", steps,
                              math.max(1, math.ceil(steps * FU.STEP_SECONDS / 60)))
end

function PW:build_fbx()
  local FU = require("conjunction.furniture")
  local meta = Y.map()
  for _, f in ipairs(PW.FIELDS) do meta[f[1]] = self.fields[f[1]] or "" end
  self.building = true
  self.progress = {i = 0, n = 1, text = "Starting REDkit", t0 = os.time()}
  self.status, self.done = "", nil
  self.ed:job(function()
    local dir, later = FU.build_pack(self.fbx_folder, meta, true, function() end, nil, function(i, n, text)
      self.progress.i, self.progress.n, self.progress.text = i, n, text
    end)
    self.later = later
    return dir
  end, function(ok, res)
    local later = self.later
    self.building, self.later = false, nil
    self.progress = nil
    if not ok then
      self.status = "Not built: " .. require("conjunction.build").message(res)
      return
    end
    self:fill_pick()
    self:open(res)
    -- (later: it waits beside the game and goes in at the start, FU.install - either way the game loads it only then)
    self.done = {text = "Build done. Restart the game for the content pack to show up.", path = res, later = later}
  end)
end

-- the card's fields at a press: an empty name stops it, an empty link asks once (the button then: Build / Write
-- anyway) - the warnings come up only now, at the top of the list, the fields with an amber edge
function PW:fields_ok()
  local word = self.mode == "fbx" and "pack" or "mod"
  local function empty(k) return not (self.fields[k] or ""):find("%S") end
  local asked, stop = {}, false
  if empty("name") then
    asked[#asked + 1] = {"warn", "name", "The " .. word .. " needs a name", {}}
    stop = true
  end
  if empty("url") then
    asked[#asked + 1] = {"warn", "url", "No download link: players who lack the " .. word ..
                                        " are not told where to get it", {}}
  end
  if stop or (#asked > 0 and not self.anyway) then
    self.asked, self.anyway, self.bar.value = asked, not stop, 0
    return false
  end
  self.asked, self.anyway = nil, false
  return true
end

function PW:write()
  if not self:fields_ok() then return end
  if self.mode == "fbx" then return self:build_fbx() end
  if self.report == nil then return end
  local PM = require("conjunction.packmaker")
  local C = require("conjunction.content")
  local meta = Y.map()
  for _, f in ipairs(PW.FIELDS) do meta[f[1]] = self.fields[f[1]] or "" end
  local ok, m = pcall(PM.write, self.folder, meta, self.report)
  if not ok then
    self.done = nil
    self.status = "Not written: " .. require("conjunction.build").message(m)
    return
  end
  self.report = PM.inspect(self.folder)
  self.done = {text = string.format("Pack card written (%s and %s). Upload the mod as usual.", C.MARKER, C.INDEX),
               path = self.folder}
end

return PW
