-- A dialog of Conjunction over the game (dialogs.run_dialog): in one of the panel's windows (the Asset Browser's
-- kind, ui/window.lua), its own background (theme BG), as big as it wants - its size hint, at least 460 wide - plus
-- the window's frame (24 x 48), in the middle of the game's screen. Not waited for: the body says when it is done.
--   DW.open(panel, key, title, body, W, H) -> window      body: {size_hint() -> w, h, frame(r), done = fn,
--                                                           min_h, max_h (a body of a fixed height)}
--   DW.label_hint(text, px, bold, extra_w) -> w, h       a word-wrapped QLabel's size hint (sizeForWidth(-1))
--   DW.label_lines(text, px, bold, w) -> {{s, w}}, h
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local TL = require("conjunction.ui.textlayout")
local D = w3.ui.draw
local DW = {}

-- a word-wrapped label's lines at a width (fm.boundingRect with word wrap)
function DW.label_lines(text, px, bold, w)
  local ls = TL.wrap(text, px, bold, math.max(0, w), "word")
  local bw = 0
  for _, l in ipairs(ls) do bw = math.max(bw, math.ceil(l.w - 1e-9)) end
  return ls, math.max(1, #ls) * Q.line_h(px, bold), bw
end
-- QLabelPrivate::sizeForWidth(-1) with word wrap: 80 average letters (less what the label takes beside the text:
-- extra_w), half of it while it gives fewer than 4 lines, a quarter while fewer than 2
function DW.label_hint(text, px, bold, extra_w)
  extra_w = extra_w or 0
  local w = Q.avg_w(px, bold) * 80 - extra_w
  local lh = Q.line_h(px, bold)
  local _, bh, bw = DW.label_lines(text, px, bold, w)
  if bh < 4 * lh and bw > w // 2 then _, bh, bw = DW.label_lines(text, px, bold, w // 2) end
  if bh < 2 * lh and bw > w // 4 then _, bh, bw = DW.label_lines(text, px, bold, w // 4) end
  return bw + extra_w, bh
end

function DW.open(panel, key, title, body, W, H)
  local old = panel.windows and panel.windows[key]
  if old then old:close() end
  local w = panel:open_win(key, title, key:gsub(" ", "_"), function() return body end)
  w.body = body
  w.title = title
  local hw, hh = body:size_hint()
  local ww, wh = math.max(hw, 460) + 24, hh + 48
  if body.min_h then wh = math.max(wh, body.min_h + 40) end   -- (the window's own minimum: header, margins, frame)
  W, H = W or panel.W or 1600, H or panel.H or 900
  w.rect = {x = (W - ww) // 2, y = (H - wh) // 2, w = ww, h = wh}
  body.win = w
  return w
end

-- the dialog's own background under the body (#cjdialog{background:BG})
function DW.background(r) D.fill(r.x, r.y, r.w, r.h, T.BG) end

return DW
