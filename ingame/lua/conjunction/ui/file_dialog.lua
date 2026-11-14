-- A file or folder chooser over the game (dialogs.pick_file / pick_folder with the editor up: Qt's own QFileDialog,
-- DontUseNativeDialog, in one of the panel's windows - "file chooser"). Its parts as qfiledialog.ui lays them out (a
-- grid, margins 9, 6 apart): Look in (the folder, its icon) and the tool buttons (back, forward, parent: the Windows 11
-- style's chevrons; new folder, list and detail view: Qt's own pictures), the side bar (My Computer, the home folder;
-- 24 px icons, rows 40 high) beside the files (a QTreeView: Name, Size, Type, Date Modified - 312, 108, 108, 192 -
-- rows 20 high, the folders first, the name filter hiding the other files), File name (Directory)
-- and Files of type, Open (Choose) and Cancel. The rows are Qt's: cj_qt_dir (QDir, QCollator, QLocale) and
-- cj_qt_mime; the icons Windows' (cj_shell_icon) as Qt takes them.
--   FD.open(ed, {title =, start =, filter = "Conjunction key (*.cjkey)", folder = true}, then_)   then_(path | nil)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local SI = require("conjunction.ui.shellicon")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local PYS = require("conjunction.pystr")
local D = w3.ui.draw
local FD = {}
FD.__index = FD

local function rgb(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
FD.C = {label = rgb("#cccccc"), cell = rgb("#dddddd"), glyph = rgb("#ffffff"), glyph_off = rgb("#9d9d9d"),
        handle = rgb("#1e1e1e")}
local C = FD.C
FD.FONT = 12                      -- (the files' and the side bar's: the views' 12 px)
FD.UI = 13                        -- (the dialog's own: its labels, the columns' widths measured with it)
FD.ROW = 20
FD.SIDE_ROW = 40
FD.HEAD = 33
FD.TOOL = 31                      -- (the file name field's height)
FD.SIDEBAR = 170
FD.HANDLE = 5
-- the Windows 11 style's signs (Segoe Fluent Icons): ChevronLeftMed, ChevronRightMed, ChevronUpMed; the sort mark
FD.GLYPH = {back = "E973", forward = "E974", up = "E971", sort_up = "E70E", sort_down = "E70D"}
-- (QIcon::paint: the box QFontIconEngine::actualSize gives - the sign's bounds at 16 px - in the middle of the 16 px
-- one; WinFontIconEngine then draws at the box's height)
FD.GLYPH_BOX = {back = 13, forward = 13, up = 11}

-- --- the name filters (qt_clean_filter_list): "Conjunction key (*.cjkey)" -> label, patterns
local function filters_of(f)
  if f == nil or f == "" then return {{"All Files (*)", {}}} end
  local out = {}
  for part in (f .. ";;"):gmatch("(.-);;") do
    if part ~= "" then
      local inner = part:match("%(([^)]*)%)%s*$") or part
      local pats = {}
      for p in inner:gmatch("%S+") do if p ~= "*" then pats[#pats + 1] = p end end
      out[#out + 1] = {part, pats}
    end
  end
  return out
end

-- a sign of the style's icon font, drawn once by Qt (cj_qt_paint: glyph) into a 16 x 16 picture
-- (Qt's application comes up on its thread first: until then nothing is drawn, the next frame asks again)
local glyphs = {}
local function qt_ready()
  if glyphs.ready then return true end
  local ok, r = pcall(w3.plugin.cj_qt_gl_start)
  glyphs.ready = ok and r == "ready"
  return glyphs.ready
end
local function painted(key, w, h, cmd, needs_text)
  if glyphs[key] == nil then
    if needs_text and not qt_ready() then return nil end
    glyphs[key] = false
    local dir = (os.getenv("TEMP") or ".") .. "\\cj_shell_icons"
    w3.fs.mkdir(dir)
    local out = string.format("%s\\fd_%s.png", dir, (key:gsub("[^%w]", "_")))
    local ok = pcall(w3.plugin.cj_qt_paint, out, tostring(w), tostring(h), cmd)
    if ok then
      local id, iw, ih = w3.ui.image_load(out)
      if id then glyphs[key] = {id = id, w = iw, h = ih} end
    end
  end
  return glyphs[key] or nil
end
local function glyph(name, colour)
  local h = FD.GLYPH_BOX[name] or 16
  return painted(name .. "_" .. string.format("%08x", colour), 16, 16,
                 string.format("glyph %08x 0 %d 16 %d %d %s", colour, (16 - h) // 2, h, h, FD.GLYPH[name]), true)
end
-- the header's sort mark: PE_IndicatorHeaderArrow - the sign at a point size of the box's height (6 x 6)
-- (on the header's own opaque colour: ClearType, as Qt draws it there)
local function sort_mark(name, colour)
  return painted("sort_" .. name .. "_" .. string.format("%08x", colour), 6, 6,
                 string.format("fill %08x\nglyphpt %08x 0 0 6 6 6 %s", T.HEADER, colour, FD.GLYPH[name]), true)
end
-- a 32 px Windows icon in a 24 px box as the side bar shows it (scaled smooth, QImage::scaled's way)
-- (nil: My Computer's: the style's icon has 16, 32, 48 and 256 px, no 24 either)
local function icon24(path)
  local src
  if path then src = SI.file_png(path, 32)
  else local ic = SI.std("computer", 32) src = ic and ic.png end
  if not src then return nil end
  return painted("i24_" .. (path or "computer"), 24, 24, "image 0 0 24 24 " .. src)
end
local pics = {}
local function pic(name)
  if pics[name] == nil then
    local id, w, h = w3.ui.image_load(Q.root .. "\\icons\\" .. name .. ".png")
    pics[name] = id and {id = id, w = w, h = h} or false
  end
  return pics[name] or nil
end

local function home() return os.getenv("USERPROFILE") or "C:\\" end
local function parent_of(p)
  if p == "" then return nil end
  local up = p:match("^(.*)\\[^\\]+$")
  if not up then return "" end                    -- (a drive: My Computer above it)
  if up:match("^%a:$") then return up .. "\\" end
  return up
end
local function join(dir, name)
  if dir == "" then return name end
  if dir:sub(-1) == "\\" then return dir .. name end
  return dir .. "\\" .. name
end
local function norm(p)
  p = (p or ""):gsub("/", "\\")
  if p:match("^%a:$") then p = p .. "\\" end
  if #p > 3 then p = p:gsub("\\+$", "") end
  return p
end

function FD.new(ed, opts, then_)
  opts = opts or {}
  local self = setmetatable({ed = ed, opts = opts, then_ = then_, folder_mode = opts.folder == true}, FD)
  self.filters = filters_of(opts.filter)
  self.filter = 1
  self.sort_col, self.desc = 0, false
  self.history, self.hpos = {}, 0
  self.cur = nil                                   -- (the row the selection is on, 1-based)
  self.name = ""
  self.mimes = {}
  self.bar_v, self.bar_h = IV.bar(1, 0, 0), IV.bar(1, 0, 0)
  self.side_bar = IV.bar(1, 0, 0)
  CT.state("panel.win.fd.name").e = nil
  CT.set_focus("panel.win.fd.name")                -- (the file name has the keyboard when it opens)
  local start = norm(opts.start)
  if start == "" or not w3.fs.isdir(start) then start = norm(home()) end
  self:go(start, true)
  return self
end

-- the drives there are, "C:\" (cj_qt_dir("") is the game's own folder, not My Computer: 13.11.)
local function drives()
  local out = {}
  for c = string.byte("A"), string.byte("Z") do
    local d = string.char(c) .. ":\\"
    if w3.fs.isdir(d) then out[#out + 1] = d end
  end
  return out
end

-- the rows of a folder (cj_qt_dir); "" is My Computer: the drives
function FD:load()
  local pats = self.filters[self.filter][2]
  local out = (os.getenv("TEMP") or ".") .. "\\cj_fd_rows.txt"
  self.rows = {}
  if self.dir == "" then
    for _, d in ipairs(drives()) do self.rows[#self.rows + 1] = {name = d, dir = true, size = "", date = ""} end
    return
  end
  local ok, n = pcall(w3.plugin.cj_qt_dir, self.dir, tostring(self.sort_col), self.desc and "1" or "0",
                      table.concat(pats, ";"), self.folder_mode and "1" or "0", out)
  if not ok then self.error = tostring(n) return end
  for line in (w3.fs.read(out) or ""):gmatch("([^\n]*)\n") do
    local name, dir, size, date = line:match("^(.-)\t(%d)\t(.-)\t(.*)$")
    if name then self.rows[#self.rows + 1] = {name = name, dir = dir == "1", size = size, date = date} end
  end
end

function FD:go(dir, record)
  self.dir = dir
  if record then
    for i = #self.history, self.hpos + 1, -1 do self.history[i] = nil end
    self.history[#self.history + 1] = dir
    self.hpos = #self.history
  end
  self.cur = nil
  self.bar_v.value, self.bar_h.value = 0, 0
  self:load()
end
-- Look in's list (QFileDialog's lookInCombo): My Computer, the drives, the folders down to this one under its drive
function FD:look_in()
  local list = {{"My Computer", ""}}
  local chain = {}                                 -- (the folders above this one, the drive first)
  local p = self.dir
  while p and p ~= "" do table.insert(chain, 1, p) p = parent_of(p) end
  local drive = chain[1]
  for _, d in ipairs(drives()) do
    list[#list + 1] = {d, d}
    if drive and d:upper() == drive:upper() then
      for i = 2, #chain do list[#list + 1] = {string.rep("    ", i - 1) .. (chain[i]:match("([^\\]+)$") or chain[i]), chain[i]} end
    end
  end
  return list
end

-- a path typed or pasted into Look in (Explorer's "Copy as path" puts quotes around it): a folder - there; a file -
-- its folder, its name into File name; nothing there - the field stays, red
function FD:go_typed(text)
  local t = (text or ""):match("^%s*(.-)%s*$"):gsub('^"(.*)"$', "%1")
  if t == "My Computer" or t == "" then self:go("", true) CT.set_focus(nil) return end
  local p = norm(t)
  if w3.fs.isdir(p) then
    self:go(p, true)
  elseif w3.fs.exists(p) and parent_of(p) then
    self:go(parent_of(p), true)
    if not self.folder_mode then
      self.name = p:match("([^\\]+)$") or ""
      CT.state("panel.win.fd.name").e = nil
    end
  else
    self.path_bad = true
    return
  end
  CT.set_focus(nil)
end

function FD:back() if self.hpos > 1 then self.hpos = self.hpos - 1 self:go(self.history[self.hpos]) end end
function FD:forward()
  if self.hpos < #self.history then self.hpos = self.hpos + 1 self:go(self.history[self.hpos]) end
end
function FD:up() local p = parent_of(self.dir) if p then self:go(p, true) end end

function FD:type_of(row)
  if row.dir then return "File Folder" end
  local path = join(self.dir, row.name)
  local t = self.mimes[path]
  if t == nil then
    local ok, r = pcall(w3.plugin.cj_qt_mime, path)
    t = ok and r or ""
    self.mimes[path] = t
  end
  return t
end

-- what the chosen path would be now (QFileDialog::accept): the name typed, else the folder (folder mode)
function FD:chosen()
  local t = self.name:match("^%s*(.-)%s*$")
  if self.folder_mode then
    if t == "" then return self.dir end
    local p = t:match("^%a:") and norm(t) or norm(join(self.dir, t))
    return w3.fs.isdir(p) and p or nil
  end
  if t == "" then return nil end
  local p = t:match("^%a:") and norm(t) or norm(join(self.dir, t))
  if w3.fs.exists(p) then return p end
  return nil
end
function FD:accept()
  local p = self:chosen()
  if not p then return end
  if not self.folder_mode and w3.fs.isdir(p) then          -- (a folder's name: into it)
    self.name = ""
    CT.state("panel.win.fd.name").e = nil
    self:go(p, true)
    return
  end
  if self.win then self.win:close() end
  if self.then_ then self.then_(p) end
end
function FD:reject()
  if self.win then self.win:close() end
  if self.then_ then self.then_(nil) end
end
function FD:new_folder()
  if self.dir == "" then return end
  local name, n = "New Folder", 2
  while w3.fs.exists(join(self.dir, name)) do name, n = string.format("New Folder (%d)", n), n + 1 end
  w3.fs.mkdir(join(self.dir, name))
  self:load()
  for i, r in ipairs(self.rows) do if r.name == name then self.cur = i end end
end

local function hit(self, id, r)
  if self.win then return self.win:hit(id, r) end
  w3.ui.set_pos(r.x, r.y)
  local c, hv, held = w3.ui.hit("fd." .. id, r.w, r.h)
  return c == 1, hv, held
end

-- --- drawing
-- the columns as Qt 6.11.2 sets them up here (measured: createWidgets' resizeSection calls are not what is left)
FD.COLUMNS = {312, 108, 108, 192}
function FD:columns() return FD.COLUMNS end

function FD:tool(id, x, y, kind, enabled, down)
  local b = {x = x, y = y, w = FD.TOOL, h = FD.TOOL}
  local clicked, hv = hit(self, "tool." .. id, b)
  if not enabled then clicked, hv = false, false end
  local ic
  if kind == "glyph" then ic = glyph(id, enabled and C.glyph or C.glyph_off)
  else ic = pic("qt_" .. id .. "_16" .. (enabled and "" or "_disabled")) end
  local gy = (kind == "glyph") and 1 or 0           -- (the signs: a pixel lower than the pictures, as Qt puts them)
  if ic then D.image(ic.id, x + (FD.TOOL - 16) // 2, y + (FD.TOOL - 16) // 2 + gy, 16, 16) end
  local tips = {back = "Back", forward = "Forward", up = "Parent Directory", newfolder = "Create New Folder",
                viewlist = "List View", viewdetailed = "Detail View"}
  if hv then CT.tip("fd.tool." .. id, {"", tips[id]}) end
  local _ = down
  return clicked
end

function FD:frame(r)
  local x0, y0, W, H = r.x + 9, r.y + 9, r.w - 18, r.h - 18
  local labels = {"Look in:", self.folder_mode and "Directory:" or "File name:", "Files of type:"}
  local lw = 0
  for _, l in ipairs(labels) do lw = math.max(lw, Q.hint_w(l, FD.UI)) end
  local ok_text = self.folder_mode and "Choose" or "Open"
  local bw = math.max(Q.button_size(ok_text), Q.button_size("Cancel"))
  local _, bh = Q.button_size("Cancel")
  local col1 = x0 + lw + 6
  local lh = Q.line_h(FD.UI)
  -- row 0: Look in, the tool buttons
  Q.text(x0, y0 + Q.vcenter(FD.TOOL, lh), C.label, labels[1], FD.UI, false)
  local tools_w = 6 * FD.TOOL + 5 * 6
  local cw = W - lw - 6 - tools_w - 6
  -- Look in: the folder as text to type or paste a path into, as Explorer's address bar (MaximdeWinter 13.11.); Enter goes
  -- there, the arrow beside it opens the list of folders above it
  local ARROW = 26
  local look = {x = col1, y = y0, w = cw, h = FD.TOOL}
  local shown_dir = self.dir == "" and "My Computer" or self.dir
  if CT.focus ~= "panel.win.fd.path" then self.path_text, self.path_bad = shown_dir, false end
  local edge = self.path_bad and 0xe0503fff or T.EDGE
  local pstyle = setmetatable({edge_focus = edge, edge = edge, pad = {5 + 22, 5, 5, 5}}, {__index = CT.EDIT_STYLE})
  local pchanged, ptext, penter = CT.edit("panel.win.fd.path", col1, y0, cw - ARROW - 2, self.path_text,
                                   {style = pstyle, h = FD.TOOL})
  self.path_text = ptext
  if pchanged then self.path_bad = false end
  if penter then self:go_typed(ptext) end
  local dir_icon = self.dir == "" and SI.std("computer", 16) or SI.file(self.dir, 16)
  SI.draw(dir_icon, col1 + 6, y0 + (FD.TOOL - 16) // 2)
  local arrow = {x = col1 + cw - ARROW, y = y0, w = ARROW, h = FD.TOOL}
  if hit(self, "lookin", arrow) then             -- (a click: its list, a second one closes it)
    if CT.IM.is_open("fd.lookin") then CT.IM.close() else
      local items = {}
      for i, e in ipairs(self:look_in()) do
        items[i] = {text = e[1], checked = e[2] == self.dir,
                    action = function() if e[2] ~= self.dir then self:go(e[2], true) end end}
      end
      CT.IM.open("fd.lookin", look, items, self.win and self.win.rect or look)
    end
  end
  Q.combo(arrow.x, arrow.y, arrow.w, arrow.h, "", {})
  local tx = col1 + cw + 6
  if self:tool("back", tx, y0, "glyph", self.hpos > 1) then self:back() end
  if self:tool("forward", tx + 37, y0, "glyph", self.hpos < #self.history) then self:forward() end
  if self:tool("up", tx + 74, y0, "glyph", self.dir ~= "") then self:up() end
  if self:tool("newfolder", tx + 111, y0, "pic", self.dir ~= "") then self:new_folder() end
  self:tool("viewlist", tx + 148, y0, "pic", true)
  self:tool("viewdetailed", tx + 185, y0, "pic", true, true)
  -- rows 2 and 3: File name, Files of type, the buttons
  local y3 = y0 + H - FD.TOOL
  local y2 = y3 - 6 - FD.TOOL
  local ew = W - lw - 6 - bw - 6
  Q.text(x0, y2 + Q.vcenter(FD.TOOL, lh), C.label, labels[2], FD.UI, false)
  local style = setmetatable({edge_focus = T.EDGE}, {__index = CT.EDIT_STYLE})
  local _, text, enter = CT.edit("panel.win.fd.name", col1, y2, ew, self.name, {style = style, h = FD.TOOL})
  self.name = text
  if enter then self:accept() end
  Q.text(x0, y3 + Q.vcenter(FD.TOOL, lh), C.label, labels[3], FD.UI, false)
  local names = {}
  for i, f in ipairs(self.filters) do names[i] = f[1] end
  local changed, fi = CT.combo("panel.win.fd.type", col1, y3, ew, names, self.filter, self.win and self.win.rect,
                               {h = FD.TOOL, fg = T.BRIGHT})
  if changed then self.filter = fi self:load() end
  local bx = x0 + W - bw
  if CT.button("panel.win.fd.ok", bx, y2, ok_text, {w = bw, h = bh, disabled = self:chosen() == nil, fg = C.cell}) then
    self:accept()
  end
  if CT.button("panel.win.fd.cancel", bx, y2 + bh + 6, "Cancel", {w = bw, h = bh, fg = C.cell}) then self:reject() end
  -- row 1: the side bar, the splitter's handle, the files
  local y1 = y0 + FD.TOOL + 6
  local h1 = y2 - 6 - y1
  self:sidebar({x = x0, y = y1, w = FD.SIDEBAR, h = h1})
  D.fill(x0 + FD.SIDEBAR, y1, FD.HANDLE, h1, FD.C.handle)      -- (the splitter's handle: the style's, opaque)
  self:tree({x = x0 + FD.SIDEBAR + FD.HANDLE, y = y1, w = W - FD.SIDEBAR - FD.HANDLE, h = h1})
  -- the size grip (QSizeGrip: the Windows 11 style's dots)
end

function FD:sidebar(r)
  Q.view_frame(r.x, r.y, r.w, r.h)
  local items = {{"My Computer", "", icon24(nil)}, {home():match("([^\\]+)$"), norm(home()), icon24(home())}}
  for i, it in ipairs(items) do
    local ry = r.y + 1 + (i - 1) * FD.SIDE_ROW
    local row = {x = r.x + 1, y = ry, w = r.w - 2, h = FD.SIDE_ROW}
    local clicked, hv = hit(self, "side." .. i, row)
    local on = self.dir == it[2]
    if on then D.fill(row.x, row.y, row.w, row.h, T.CHOSEN) end
    SI.draw(it[3], row.x + 9, ry + (FD.SIDE_ROW - 24) // 2)
    Q.text(row.x + 9 + 24 + 6, ry + Q.vcenter(FD.SIDE_ROW, Q.line_h(FD.FONT)), on and T.WHITE or C.cell, it[1],
           FD.FONT, false, on and T.CHOSEN or T.SURFACE)
    if clicked then self:go(it[2], true) end
    local _ = hv
  end
end

function FD:tree(r)
  Q.view_frame(r.x, r.y, r.w, r.h)
  local vx, vy, vw, vh = r.x + 1, r.y + 1, r.w - 2, r.h - 2
  local cols = self:columns()
  local total = cols[1] + cols[2] + cols[3] + cols[4]
  local need = #self.rows * FD.ROW
  local bar_h, bar_v = false, false
  for _ = 1, 2 do
    local w_ = vw - (bar_v and 10 or 0)
    bar_h = total > w_
    local h_ = vh - FD.HEAD - (bar_h and 10 or 0)
    bar_v = need > h_
  end
  local w_ = vw - (bar_v and 10 or 0)
  local body_h = vh - FD.HEAD - (bar_h and 10 or 0)
  local bv, bhb = self.bar_v, self.bar_h
  bv.single, bv.page = FD.ROW, body_h
  IV.range(bv, math.max(0, need - body_h))
  bhb.single, bhb.page = 20, w_
  IV.range(bhb, math.max(0, total - w_))
  local hx = vx - bhb.value
  local heads = {"Name", "Size", "Type", "Date Modified"}
  D.clip(vx, vy, w_, FD.HEAD, function()
    local x = hx
    for i = 1, 4 do
      local hr = {x = x, y = vy, w = cols[i], h = FD.HEAD}
      local sorted = i - 1 == self.sort_col
      Q.header_left(hr.x, hr.y, hr.w, hr.h, "")
      Q.text(hr.x + 8 + (sorted and 20 or 0), hr.y + 4, T.HEAD_TEXT, heads[i],   -- (the style: room for the mark)
             T.FONT_SMALL, false, T.HEADER)
      if sorted then                               -- (the Windows 11 style: the mark above the text, in the middle)
        local g = sort_mark(self.desc and "sort_down" or "sort_up", C.glyph)
        if g then D.image(g.id, x + (cols[i] - 1) // 2 - 3, vy, 6, 6) end
      end
      local clicked = hit(self, "head." .. i, hr)
      if clicked then
        if self.sort_col == i - 1 then self.desc = not self.desc else self.sort_col, self.desc = i - 1, false end
        self:load()
      end
      x = x + cols[i]
    end
  end)
  local top = vy + FD.HEAD
  local over = CT.over({x = vx, y = top, w = w_, h = body_h})
  local _, _, wheel = w3.ui.mouse()
  if over and wheel and wheel ~= 0 then IV.wheel(bv, wheel >= 0 and math.min(wheel, 1) or math.max(wheel, -1), 3) end
  local lh = Q.line_h(FD.FONT)
  D.clip(vx, top, w_, body_h, function()
    for i, row in ipairs(self.rows) do
      local ry = top + (i - 1) * FD.ROW - bv.value
      if ry + FD.ROW > top and ry < top + body_h then
        local on = self.cur == i
        if on then D.fill(hx, ry, total, FD.ROW, T.CHOSEN) end
        local bg = on and T.CHOSEN or T.SURFACE
        local fg = on and T.WHITE or C.cell
        local x = hx
        local path = join(self.dir, row.name)
        SI.draw(self.dir == "" and SI.std("drive_hd", 16) or SI.file(path, 16), x + 3, ry + 2)
        local CV = require("conjunction.ui.catalog_view")
        local texts = {row.name, row.size, self:type_of(row), row.date}
        for c = 1, 4 do
          local tx = (c == 1) and (x + 3 + 16 + 6) or (x + 3)
          local room = cols[c] - (tx - x) - 4
          local s = CV.elide(texts[c], "middle", room, FD.FONT, false)
          if s ~= "" then Q.text(tx, ry + Q.vcenter(FD.ROW, lh), fg, s, FD.FONT, false, bg) end
          x = x + cols[c]
        end
        local clicked, hv = hit(self, "row." .. i, {x = vx, y = ry, w = w_, h = FD.ROW})
        -- (activated: QAbstractItemView's double click comes with the second press - a click with the release)
        if hv and w3.ui.mouse_double(1) and self.press == i then
          self.swallow = true                      -- (that press's release is no click on the new rows)
          if row.dir then                          -- (enterDirectory: in folder mode the name is cleared)
            if self.folder_mode then self.name = "" CT.state("panel.win.fd.name").e = nil end
            self:go(norm(path), true)
            return
          end
          self.name = row.name
          self:accept()
          return
        end
        if clicked and self.swallow then
          self.swallow = false
        elseif clicked then
          self.press, self.cur = i, i
          CT.set_focus(nil)                        -- (the list takes the keyboard from the name)
          -- (selectionChanged: the files in file mode, the folders in folder mode go into the name)
          if (not row.dir) ~= self.folder_mode then
            self.name = row.name
            CT.state("panel.win.fd.name").e = nil
          end
        end
      end
    end
  end)
  if self.swallow and w3.ui.mouse_released(1) then self.swallow = false end   -- (released beside the rows)
  local hitf = function(id, rr) return hit(self, id, rr) end
  if bar_v then
    SBAR.draw(self, "fd.vbar", bv, {x = vx + w_, y = vy, w = 10, h = vh - (bar_h and 10 or 0)}, "v", hitf)
  end
  if bar_h then SBAR.draw(self, "fd.hbar", bhb, {x = vx, y = vy + vh - 10, w = w_, h = 10}, "h", hitf) end
end

-- a chooser in one of the panel's windows ("file chooser"), at the window's first size
function FD.open(ed, opts, then_)
  local p = ed and (ed.panel or ed)
  local body = FD.new(ed, opts, then_)
  if not p or not p.open_win then return body end
  local old = p.windows and p.windows["file chooser"]
  if old then old:close() end
  local w = p:open_win("file chooser", opts.title or "Open", "file_chooser", function() return body end)
  w.body, body.win = body, w
  w.title = opts.title or "Open"
  return body
end

return FD
