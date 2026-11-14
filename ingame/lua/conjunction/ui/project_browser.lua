-- The project browser (project_browser.ProjectBrowser, File > Open project): every project in Documents\Conjunction,
-- the ones added from elsewhere, and Conjunction's examples - a window over the game, 760 x 460, moved, resized and
-- docked at a side like the panel (dock.lua, key "projects"). Its own sheet: #browser rgba(22,22,25,240) with a 1 px
-- #55555c border, margins 12 8 12 12, 8 apart; the title bold 13 px #f0f0f2, the close button a flat "✕" #9a9aa0;
-- the list a QTreeWidget (Name 230, Changed 120, Where the rest; the project open now on green, the examples grey,
-- the clicked row framed in #c8c8c8 - no selection fill); Open (once a row is clicked), Open folder, Add..., the hint
-- (11 px #8c8c90: how many projects, or the clicked one's folder).
--   local b = PB.new(ed)   b:show_over(W, H)   b:frame()   b:covers(x, y)   b.shown
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local DK = require("conjunction.ui.dock")
local P = require("conjunction.project")
local Y = require("conjunction.yaml")
local D = w3.ui.draw
local PB = {}
PB.__index = PB

local function rgba(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
PB.C = {bg = (22 << 24) | (22 << 16) | (25 << 8) | 240, edge = rgba("#55555c"), title = rgba("#f0f0f2"),
        close = rgba("#9a9aa0"), hint = rgba("#8c8c90"), open_bg = (47 << 24) | (90 << 16) | (50 << 8) | 200,
        open_inner = (46 << 24) | (88 << 16) | (49 << 8) | 255, picked = rgba("#c8c8c8"), example = (160 << 24) | (160 << 16) | (164 << 8) | 255, text = rgba("#dddddd")}
local C = PB.C
PB.W, PB.H = 760, 460
PB.COLS = {230, 120}
PB.ROW_H = 24
PB.HEAD_H = 33

function PB.new(ed)
  local self = setmetatable({ed = ed, shown = false, rows = {}, cur = nil, bar = IV.bar(),
                             rect = {x = 0, y = 0, w = PB.W, h = PB.H}}, PB)
  self.min_w, self.min_h = 360, 240
  self.mover = DK.mover(self, "projects", ed, {min_w = 360, min_h = 240,
                                               hit = function(id, r) return self:hit(id, r) end})
  return self
end
function PB:visible() return self.shown end
function PB:covers(x, y)
  local r = self.rect
  return self.shown and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end
function PB:hit(id, r)
  local mx, my = w3.ui.mouse()
  if CT.blocker and CT.blocker(mx, my) then return false, false, false end
  w3.ui.set_pos(r.x, r.y)
  local clicked, hovered, held = w3.ui.hit("browser." .. id, r.w, r.h)
  return clicked == 1, hovered, held
end

-- every project (the one open marked), then the examples
function PB:fill()
  self.rows = {}
  local here = P.key_of(self.ed.project and self.ed.project.path or "")
  for _, path in ipairs(P.recent()) do
    local ok, meta = pcall(Y.read, path .. "\\project.yml")
    local name = ok and type(meta) == "table" and type(meta.name) == "string" and meta.name ~= "" and meta.name
                 or require("conjunction.paths").basename(path)
    self.rows[#self.rows + 1] = {name, P.when(path), path, path = path, open = P.key_of(path) == here}
  end
  for _, ex in ipairs(P.examples()) do
    self.rows[#self.rows + 1] = {ex[1] .. "   (example)", "", "Comes with Conjunction", path = ex[2], example = true}
  end
  self.cur = nil
end

-- shown in the middle of the game's window, the list fresh (docked: at its side; else where it was left)
function PB:show_over(W, H)
  self:fill()
  self.shown = true
  if not self.mover.docker:apply() then
    local kept = self.mover:kept_rect()
    if kept then self.rect = kept
    else self.rect = {x = (W - PB.W) // 2, y = (H - PB.H) // 2, w = PB.W, h = PB.H} end
  end
end

-- the buttons
function PB:open_chosen()
  local row = self.cur and self.rows[self.cur]
  if not row then return end
  self.shown = false
  if P.key_of(row.path) == P.key_of(self.ed.project.path) then return end
  -- (the editor in that project, the game goes on: editor.switch_project)
  if self.ed.switch_project then self.ed:switch_project(row.path) elseif self.ed.start_clean then self.ed:start_clean(row.path) end
end
function PB:open_folder()
  if not w3.fs.isdir(P.PROJECTS) then w3.fs.mkdir(P.PROJECTS) end
  if w3.proc and w3.proc.run then require("conjunction.fsutil").show(P.PROJECTS) end
end
function PB:add()
  local DLG = require("conjunction.ui.dialogs")
  if not DLG or not DLG.pick_file then return end
  DLG.pick_file(self.ed, "Add a project", P.PROJECTS, "Project (project.yml)", function(path)
    if not path then return end
    local folder = P.add_project(path)
    if not folder then self.message = "Not a project (no project.yml there)" return end
    self:fill()
    for i, row in ipairs(self.rows) do if P.key_of(row.path) == P.key_of(folder) then self.cur = i end end
  end)
end

local function button(self, id, x, y, text, primary, tip)
  local w, h = Q.button_size(text)
  local b = {x = x, y = y, w = w, h = h}
  local clicked, hv, held = self:hit(id, b)
  Q.button(b.x, b.y, b.w, b.h, text, {hover = hv or held, pressed = held and hv, primary = primary,
                                      fg = (not primary) and T.BUTTON_TEXT or nil})
  if hv then CT.tip("browser." .. id, tip) end
  return clicked, w
end

function PB:frame()
  if not self.shown then return end
  self.mover:follow()
  local r = self.rect
  local was = Q.translucent
  Q.translucent = true
  D.fill(r.x, r.y, r.w, r.h, C.bg)
  D.rect(r.x, r.y, r.w, r.h, C.edge, 1)
  local x, y, w = r.x + 1 + 12, r.y + 1 + 8, r.w - 2 - 24
  local bottom = r.y + r.h - 1 - 12
  -- the header: the title, the close button at the right
  local hh = 21
  Q.text(x, y + Q.vcenter(hh, Q.line_h(13, true)), C.title, "Projects", 13, true)
  local xb = {x = x + w - 25, y = y, w = 25, h = hh}
  local closed, chv = self:hit("close", xb)
  local glyph = "\u{2715}"
  Q.text(xb.x + (xb.w - Q.text_w(glyph)) // 2, xb.y + Q.vcenter(xb.h, Q.line_h()), C.close, glyph)
  if chv then CT.tip("browser.close", "pan.close") end
  -- the bottom row: Open (once a row is clicked), Open folder, Add..., the hint at the right
  local bh = 29
  local by = bottom - bh
  local bx = x
  if self.cur then
    local c, bw = button(self, "open", bx, by, "Open", true, "browse.open")
    if c then self:open_chosen() end
    bx = bx + bw + 8
  end
  local c2, w2 = button(self, "folder", bx, by, "Open folder", false, "browse.folder")
  if c2 then self:open_folder() end
  bx = bx + w2 + 8
  local c3 = button(self, "add", bx, by, "Add...", false, "browse.add")
  if c3 then self:add() end
  local hint = self.message or (self.cur and self.rows[self.cur][3]) or (#self.rows .. " projects")
  Q.text(x + w - Q.text_w(hint, 11), by + Q.vcenter(bh, Q.line_h(11)), C.hint, hint, 11)
  -- the list between them
  local tree = {x = x, y = y + hh + 8, w = w, h = by - 8 - (y + hh + 8)}
  self:draw_tree(tree)
  self.mover:frame({x = x, y = y, w = w - 25, h = hh})
  Q.translucent = was
  if closed then self.shown = false end
end

function PB:draw_tree(r)
  Q.view_frame(r.x, r.y, r.w, r.h)
  local vx, vy, vw = r.x + 1, r.y + 1, r.w - 2
  local vh = r.h - 2
  local body_y, body_h = vy + PB.HEAD_H, vh - PB.HEAD_H
  local n = #self.rows
  local need = n * PB.ROW_H
  local b = self.bar
  local bar = need > body_h
  if bar then vw = vw - 10 end
  b.single, b.page = PB.ROW_H, body_h
  IV.range(b, math.max(0, need - body_h))
  -- the columns: 230, 120, the rest (the last section stretches)
  local cols = {PB.COLS[1], PB.COLS[2], math.max(0, vw - PB.COLS[1] - PB.COLS[2])}
  local heads = {"Name", "Changed", "Where"}
  local hx = vx
  for i, cw in ipairs(cols) do
    Q.header_left(hx, vy, cw, PB.HEAD_H, heads[i])
    hx = hx + cw
  end
  local over = CT.over({x = vx, y = body_y, w = vw, h = body_h})
  local mx, my, wheel = w3.ui.mouse()
  if over and wheel and wheel ~= 0 then IV.wheel(b, wheel >= 0 and math.min(wheel, 1) or math.max(wheel, -1), 3) end
  local fl = T.FONT_LIST
  local CV = require("conjunction.ui.catalog_view")
  local tip_row
  D.clip(vx, body_y, vw, body_h, function()
    for i, row in ipairs(self.rows) do
      local ry = body_y + (i - 1) * PB.ROW_H - b.value
      if ry + PB.ROW_H >= body_y and ry < body_y + body_h then
        if row.open then                  -- (the item's background, and again over the row 2 px in: as Qt shows it)
          D.fill(vx, ry, cols[1] + cols[2] + cols[3], PB.ROW_H, C.open_bg)
          D.fill(vx + 2, ry + 2, cols[1] + cols[2] + cols[3] - 4, PB.ROW_H - 4, C.open_bg)
        end
        local cx = vx
        for c, cw in ipairs(cols) do
          local bg = row.open and C.open_inner or T.SURFACE   -- (the text on it: opaque, ClearType)
          local s = CV.elide(row[c], "right", cw - 18, fl, false)
          local fg = (row.example and c == 1) and C.example or C.text
          Q.text(cx + 9, ry + (PB.ROW_H - Q.line_h(fl) + 1) // 2, fg, s, fl, false, bg)
          cx = cx + cw
        end
        if i == self.cur then             -- (RowFrame: a light frame round the whole row)
          D.rect(vx, ry, cx - vx, PB.ROW_H, C.picked, 1)
        end
        local clicked, hovered = self:hit("row." .. i, {x = vx, y = ry, w = vw, h = PB.ROW_H})
        if hovered and row.open then tip_row = true end
        -- (itemDoubleClicked comes with the second press; the click, with the release)
        if hovered and w3.ui.mouse_double(1) and self.press == i then self.cur = i self:open_chosen() return end
        if clicked then self.press, self.cur, self.message = i, i, nil end
      end
    end
  end)
  if tip_row then CT.tip("browser.row", {"", "Open now"}) elseif over then CT.tip("browser.list", "browse.list") end
  if bar then
    SBAR.draw(self, "tree.vbar", b, {x = vx + vw, y = vy, w = 10, h = vh}, "v", function(id, rr) return self:hit(id, rr) end)
  end
end

return PB
