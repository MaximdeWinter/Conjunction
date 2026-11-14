-- Settings > Profile > Check origin (profile_view.CheckOriginDialog): a .w3q, a project or a built quest in; its
-- history (the table of history_window.lua, the chosen step's changes under it), whether it holds (red when not),
-- and the marks of this PC's profiles, the same spots and the similar projects (origin.lua) under that. A dialog of
-- at least 800 x 480 (setMinimumSize); a row of File... and Folder... and what was chosen (DIM) at the top.
--   OW.open(ed)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local DW = require("conjunction.ui.dialog_window")
local HW = require("conjunction.ui.history_window")
local OW = {}
OW.__index = OW

function OW.new(ed)
  return setmetatable({ed = ed, what = "A quest file (.w3q), a project or a built quest", state = "", bad = false,
                       marks = "", hist = nil, pending = nil}, OW)
end

function OW:size_hint() return 800, 480 end

local function base(p) return (p:gsub("[\\/]+$", "")):match("([^\\/]+)$") or p end

function OW:run(path)
  local OR = require("conjunction.origin")
  local ok, r = pcall(OR.check, path)
  if not ok then
    self.what, self.state, self.bad, self.marks, self.hist = base(path), tostring(r), true, "", nil
    return
  end
  self.what = string.format("%s (%s)", base(path), r.kind)
  self.state, self.bad = HW.state_text(r.history)
  self.hist = HW.new(r.steps, r.history)
  self.hist.win = self.win
  self.hist.table:ensure_visible()       -- (the dialog is up when the app checks: selectRow scrolls to the last step)
  self.marks = table.concat(OR.lines(r), "\n")
  self.result = r
end

function OW:choose(path)
  if path and path ~= "" then
    self.what, self.state, self.bad, self.marks, self.hist = base(path), "Checking...", false, "", nil
    self.pending = path                    -- (checked the next frame: the window shows what it does first)
  end
end

local function lines_of(text, w)
  local out = {}
  if text == "" then return out, 0 end
  for para in (text .. "\n"):gmatch("(.-)\n") do
    for _, l in ipairs(DW.label_lines(para, T.FONT, false, w)) do out[#out + 1] = l end
  end
  return out, #out * Q.line_h()
end

function OW:frame(r)
  if self.pending and self.drawn_pending then
    local p = self.pending
    self.pending, self.drawn_pending = nil, nil
    self:run(p)
  elseif self.pending then
    self.drawn_pending = true
  end
  DW.background(r)
  local x, y, w = r.x + 9, r.y + 9, r.w - 18
  local bottom = r.y + r.h - 9
  local fw, bh = Q.button_size("File...")
  local dw = Q.button_size("Folder...")
  local DLG = require("conjunction.ui.dialogs")
  if CT.button("origin.file", x, y, "File...", {w = fw, h = bh, tip = "origin.file"}) then
    DLG.pick_file(self.ed, "Check origin", os.getenv("USERPROFILE") or "", "Quest file or bundle (*.w3q *.bundle)",
                  function(p) self:choose(p) end)
  end
  if CT.button("origin.folder", x + fw + 6, y, "Folder...", {w = dw, h = bh, tip = "origin.folder"}) then
    DLG.pick_folder(self.ed, "Check origin (a project or a built quest)", nil, function(p) self:choose(p) end)
  end
  local lx = x + fw + 6 + dw + 6
  Q.text(lx, y + Q.vcenter(bh, Q.line_h()), T.DIM, self.what, T.FONT, false, T.BG)
  y = y + bh + 6
  local sl, sh = lines_of(self.state, w)
  for k, l in ipairs(sl) do
    Q.text(x, y + (k - 1) * Q.line_h(), self.bad and T.RED or T.TEXT, l.s, T.FONT, false, T.BG)
  end
  y = y + sh + (sh > 0 and 6 or 0)
  local ml, mh = lines_of(self.marks, w)
  local my = bottom - mh
  for k, l in ipairs(ml) do Q.text(x, my + (k - 1) * Q.line_h(), T.TEXT, l.s, T.FONT, false, T.BG) end
  if self.hist then
    local dl, dh = lines_of(self.hist.detail or "", w)
    local dy = my - (mh > 0 and 6 or 0) - dh
    local th = dy - 6 - y
    self.hist.win = self.win
    self.hist.table:frame({x = x, y = y, w = w, h = th}, self.hist.rows,
                          function(id, b) return self.win:hit(id, b) end, "origin")
    for k, l in ipairs(dl) do Q.text(x, dy + (k - 1) * Q.line_h(), T.TEXT, l.s, T.FONT, false, T.BG) end
  end
end

function OW.open(ed)
  return DW.open(ed.panel or ed, "check origin", "Check origin", OW.new(ed))
end

return OW
