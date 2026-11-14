-- The quest board's "Place new ..." in a window of its own, as the item window (12.11.: choosing a person took the
-- board's place; a window that pops up over it reads better): the catalog on its kind, a click shows one in an
-- inspector beside it, its Place (or a double click) takes it; the one shown on top (red when it can not be taken),
-- Use it for a clue swap. The board (ui/quest_board.lua: choose, chooser_current, chooser_take) keeps what is chosen.
--   OC.new(board, win) -> a body: body:start(c), body:frame(r), body:show_entry(e)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local CV = require("conjunction.ui.catalog_view")
local INS = require("conjunction.ui.inspector")
local D = w3.ui.draw
local OC = {}
OC.__index = OC

local INS_W = 330

function OC.new(board, win)
  local self = setmetatable({board = board, win = win, panel = board.panel, ed = board.ed}, OC)
  self.lay = {frame = win.rect}
  self.ins = INS.new(self)
  self.ins.on_place = function(e)
    board:chooser_current(e)
    board:chooser_take()
  end
  self.ins.on_favourite = function(e)
    local cv = self.c and self.c.cv
    if cv then
      cv.model:toggle_favourite(e)
      cv:sync_rows()
    end
  end
  self:show_ins(false)
  return self
end
function OC:hit(id, r) return self.win:hit(id, r) end
function OC:show_ins(on)
  self.ins_shown = on
  self.win:set_extra(on and INS_W + 8 or 0)
end
-- the chooser c (quest_board.choose) in it: the catalog made once the asset database is read
function OC:start(c)
  self.c = c
  self:show_ins(false)
  self:build()
end
function OC:build()
  local c, p = self.c, self.panel
  if not c or c.cv or not p.assets then return end
  local opts = {}
  for k, v in pairs(p.catalog_opts or {}) do opts[k] = v end
  opts.ids = "panel.win.chooser.cat."             -- (its own controls, as the item window's)
  opts.host = self
  opts.board_chip = true
  local cv = CV.new(self.ed, p.assets, opts)
  c.cv = cv
  local board = self.board
  cv.on_current = function(e) board:chooser_current(e) end
  cv.on_chosen = function(e)
    board:chooser_current(e)
    board:chooser_take()
  end
  board:chooser_filter(c)
  cv:sync_rows()
  CT.set_focus(cv.search_id)                      -- (typing.start: its search has the keys)
end
-- the entry shown beside the catalog (the 3D view, the looks)
function OC:show_entry(e)
  local fav = false
  local cv = self.c and self.c.cv
  for _, k in ipairs(cv and cv.model.favourites or {}) do if k == e.key then fav = true end end
  self.ins:show_entry(e, fav)
  self:show_ins(true)
end
function OC:closed()
  if self.board.chooser == self.c then self.board.chooser = nil end
  self.c = nil
end

-- QPushButton#small (the board's): #2b2b2b, a 1 px edge, 12 px; disabled grey
local function small(self, id, r, text, disabled)
  local clicked, hovered, held = self:hit(id, r)
  if disabled then clicked, hovered, held = false, false, false end
  local bg, edge = T.BUTTON, hovered and T.EDGE_HOVER or T.EDGE
  if held and hovered then bg = T.CHOSEN end
  Q.frame(r.x, r.y, r.w, r.h, bg, edge)
  local fg = disabled and 0x777777ff or T.BUTTON_TEXT
  Q.text(r.x + (r.w - Q.text_w(text, 12)) // 2, r.y + Q.vcenter(r.h, Q.line_h(12)), fg, text, 12, false, bg)
  return clicked, hovered
end

-- the one shown and Use it (a clue swap) over the catalog and its inspector (330 wide, 8 apart)
function OC:frame(r)
  local c = self.c
  if not c then return end
  self.lay.frame = self.win.rect
  if not c.cv then self:build() end
  local bh = 22
  local right = r.x + r.w
  if c.swap then
    local sw = Q.hint_w("Use it", 12) + 18
    local sr = {x = right - sw, y = r.y, w = sw, h = bh}
    local clicked, hovered = small(self, "take", sr, "Use it", not c.entry or c.why ~= nil)
    if hovered then CT.tip("win.chooser.take", "qb.chooser_take") end
    if clicked then self.board:chooser_take() end
    right = sr.x - 6
  end
  D.clip(r.x, r.y, math.max(0, right - r.x), bh, function()
    Q.text(r.x, r.y + Q.vcenter(bh, Q.line_h(12)), c.why and 0xe06c5aff or 0xbbbbbbff, c.name or "", 12)
  end)
  local body = {x = r.x, y = r.y + bh + 6, w = r.w, h = r.h - bh - 6}
  if not c.cv then
    Q.text(body.x, body.y, 0x9a9a9aff, self.panel.catalog_hint or "The catalog is not built yet.", 12)
    return
  end
  local cw = self.ins_shown and body.w - INS_W - 8 or body.w
  c.cv:frame({x = body.x, y = body.y, w = cw, h = body.h})
  if self.ins_shown then self.ins:frame({x = body.x + cw + 8 - 8, y = body.y, w = INS_W + 8, h = body.h}) end
end

return OC
