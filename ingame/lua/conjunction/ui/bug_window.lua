-- Report a bug over the game (bugreport_view.BugWindow in one of the panel's windows): what happened (a
-- QPlainTextEdit, its placeholder), the screenshots taken (120 x 68 each, a trash button under it), Add screenshot,
-- Cancel, Show file and Copy for Nexus (once saved), Save report; what the report holds (#note: 11 px #999,
-- wrapped) and what happened last. Its own sheet: #bug #232326, the heading bold 14 px #eee. A QVBoxLayout, margins
-- 9, 6 apart; the text takes the room left. Add screenshot hides the window, takes the game's picture with the
-- overlay (w3.ui.screenshot), then the picture is marked (ui/annotate.lua) and kept.
--   local b = BW.new(ed)   b:frame(r)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local DW = require("conjunction.ui.dialog_window")
local PT = require("conjunction.ui.plaintext")
local BR = require("conjunction.bugreport")
local D = w3.ui.draw
local BW = {}
BW.__index = BW

local function rgb(s) return (tonumber(s:sub(2), 16) << 8) | 255 end
BW.C = {bg = rgb("#232326"), head = rgb("#eeeeee"), note = rgb("#999999"), text = rgb("#dddddd")}
local C = BW.C
BW.INCLUDED = "Saved as one file in Documents\\Conjunction\\bug-reports. Nothing is sent. Inside: what you write, " ..
              "the screenshots, Conjunction's and the game's logs, the open project (quest and places), the " ..
              "editor's and the game's state, installed mods and DLCs. Anonymous (your names, the PC's name and your " ..
              "profile are taken out)"
BW.PLACEHOLDER = "Please write what happened and what you expected to happen"
local GREY = (0xcf << 24) | (0xcf << 16) | (0xcf << 8) | 255     -- (icons.GREY)

function BW.new(ed)
  local self = setmetatable({ed = ed, text = "", shots = {}, status = "", saved = nil}, BW)
  CT.state("panel.win.bug.text").e = nil
  return self
end

-- a QPushButton with an icon (16 px, grey) before its text
local function icon_button(id, x, y, text, icon, opts)
  local tw = Q.hint_w(text)
  local w, h = 16 + 4 + tw + 22, Q.line_h() + 12
  local mx, my = w3.ui.mouse()
  local blocked = CT.blocker and CT.blocker(mx, my)
  w3.ui.set_pos(x, y)
  local clicked, hovered, held = w3.ui.hit(id, w, h)
  if blocked then clicked, hovered, held = 0, false, false end
  local bg = (held and hovered) and T.CHOSEN or T.BUTTON
  Q.frame(x, y, w, h, bg, (hovered or held) and T.EDGE_HOVER or T.EDGE)
  local ix = x + 11 + (w - 22 - (16 + 4 + Q.text_w(text))) // 2
  Q.draw_icon(icon, GREY, 16, ix, y + 6 + (h - 12 - 16) // 2)
  Q.text(ix + 18, y + 6 + (h - 12 - Q.line_h()) // 2, opts.fg or C.text, text, T.FONT, false, bg)
  if hovered and opts.tip then CT.tip(id, opts.tip) end
  return clicked == 1, w, h
end

local function wrapped(text, px, w)
  local lines, h = DW.label_lines(text, px, false, w)
  return lines, math.max(h, Q.line_h(px))
end

-- --- the screenshots: the window out of the picture, the shot, marked, kept
function BW:add_screenshot()
  if self.taking then return end
  local w = self.win
  local dir = (os.getenv("TEMP") or ".") .. "\\cj_bug_shots"
  w3.fs.mkdir(dir)
  local path = string.format("%s\\shot_%d_%d.png", dir, os.time(), #self.shots + 1)
  self.taking = true
  w.shown = false                                 -- (its window: hidden while the shot is taken)
  local sys = self.ed and self.ed.sys
  local after = sys and sys.after or function(_, fn) fn() end
  after(350, function()
    local before = w3.ui.screenshot and w3.ui.screenshot(path)
    local function back(ok)
      w.shown = true
      self.taking = false
      if not ok then self.status = "No screenshot: the game's picture could not be taken" return end
      local AN = require("conjunction.ui.annotate")
      AN.open(self.ed, path, function(marked)
        if marked then
          self.shots[#self.shots + 1] = {path, marked}
          self:thumbs()
        end
      end)
    end
    if not before then back(false) return end
    local tries = 0
    local function wait()
      tries = tries + 1
      if w3.ui.screenshots_done() > before and w3.fs.exists(path) then back(true)
      elseif tries > 100 then back(false)
      else after(20, wait) end
    end
    after(20, wait)
  end)
end
-- each marked shot as the strip shows it: QPixmap.scaled(120, 68, KeepAspectRatio, Smooth) - Qt's own (cj_qt_paint)
function BW:thumbs()
  for _, s in ipairs(self.shots) do
    if not s.pic then
      local id0, w, h = w3.ui.image_load(s[2])
      if id0 then
        w3.ui.image_free(id0)
        local out = s[2]:gsub("%.png$", "") .. "_thumb.png"
        local ok = pcall(w3.plugin.cj_qt_paint, out, tostring(w), tostring(h), "image 0 0 0 0 " .. s[2], "120 68")
        local id, tw, th = w3.ui.image_load(ok and out or s[2])
        if id then s.pic = {id = id, w = tw, h = th} end
      end
    end
  end
end

function BW:send()
  self.status = "Collecting..."
  self.busy = true
  local shots = {}
  for k, s in ipairs(self.shots) do
    shots[#shots + 1] = {"marked_" .. k, s[2]}
    shots[#shots + 1] = {"original_" .. k, s[1]}
  end
  local p = self.ed and self.ed.panel
  local log = p and p.log_text and p:log_text() or ""
  local text = self.text:match("^%s*(.-)%s*$")
  local sys = self.ed and self.ed.sys
  BR.collect(self.ed, text, shots, log, function(path, err)
    self.busy = false
    if not path then
      self.status = "Could not collect the report: " .. tostring(err)
      return
    end
    self.saved = path
    self.status = "Saved. Copy for Nexus puts a short report into the clipboard: paste it into the Bugs tab " ..
                  "of the mod's Nexus page. The author may ask you for the file. Thank you"
    self.text = ""
    CT.state("panel.win.bug.text").e = nil
    self.shots = {}
  end, sys and sys.after)
end
function BW:copy()
  if not self.saved then return end
  local ok, t = pcall(BR.nexus_text, self.saved)
  if ok then
    w3.ui.clipboard(t)
    self.status = "Copied. Paste it into the Bugs tab of the mod's Nexus page (Add a new report)"
  end
end

function BW:frame(r)
  D.fill(r.x, r.y, r.w, r.h, C.bg)
  local hit = function(id, b) return self.win:hit(id, b) end
  local x, y, w = r.x + 9, r.y + 9, r.w - 18
  local bottom = r.y + r.h - 9
  -- from the bottom: the status, the note, the buttons, the screenshots' strip
  local sl, sh = wrapped(self.status, 11, w)
  local nl, nh = wrapped(BW.INCLUDED, 11, w)
  local _, bh = Q.button_size("Cancel")
  local sy = bottom - sh
  local ny = sy - 6 - nh
  local by = ny - 6 - bh
  local strip_h = 18                                -- (the strip's layout: its margins 9 and 9)
  if #self.shots > 0 then strip_h = 9 + 68 + 6 + 23 + 9 end
  local tsy = by - 6 - strip_h
  local hy = y
  local hh = Q.line_h(14, true)
  Q.text(x, hy, C.head, "Report a bug", 14, true, C.bg)
  local ey = hy + hh + 6
  local eh = tsy - 6 - ey
  local _, text = PT.edit("panel.win.bug.text", x, ey, w, eh, self.text,
                          {placeholder = BW.PLACEHOLDER, hit = hit, tip = "bug.text_field", focus_edge = false})
  self.text = text
  -- the strip: each shot over its trash button
  if #self.shots > 0 then
    local sx = x + 9
    for k, s in ipairs(self.shots) do
      if s.pic then D.image(s.pic.id, sx, tsy + 9, s.pic.w, s.pic.h) end
      local bx = sx + ((s.pic and s.pic.w or 120) - 23) // 2
      local clicked, hv = hit("shot.trash." .. k, {x = bx, y = tsy + 9 + 68 + 6, w = 23, h = 23})
      if hv then
        D.fill(bx, tsy + 9 + 68 + 6, 23, 23, (255 << 24) | (255 << 16) | (255 << 8) | 20)
        CT.tip("bug.remove", "bug.remove")
      end
      Q.draw_icon("trash-2", hv and T.WHITE or GREY, 16, bx + 3, tsy + 9 + 68 + 6 + 3)
      if clicked then table.remove(self.shots, k) break end
      sx = sx + (s.pic and s.pic.w or 120) + 6
    end
  end
  -- the buttons
  if icon_button("panel.win.bug.shot", x, by, "Add screenshot", "camera", {tip = "bug.screenshot"}) then
    self:add_screenshot()
  end
  local right = {}
  right[#right + 1] = {"cancel", "Cancel", nil}
  if self.saved then
    right[#right + 1] = {"folder", "Show file", "folder-open", "bug.folder"}
    right[#right + 1] = {"copy", "Copy for Nexus", "copy", "bug.copy"}
  end
  right[#right + 1] = {"send", "Save report", nil, "bug.send"}
  local widths, total = {}, 0
  for i, b in ipairs(right) do
    local bw = b[3] and (16 + 4 + Q.hint_w(b[2]) + 22) or Q.button_size(b[2])
    widths[i] = bw
    total = total + bw + (i > 1 and 6 or 0)
  end
  local bx = x + w - total
  for i, b in ipairs(right) do
    local id = "panel.win.bug." .. b[1]
    local clicked
    if b[3] then clicked = icon_button(id, bx, by, b[2], b[3], {tip = b[4]})
    else clicked = CT.button(id, bx, by, b[2], {w = widths[i], h = bh, tip = b[4], fg = C.text,
                                                disabled = b[1] == "send" and self.busy}) end
    if clicked then
      if b[1] == "cancel" then self.win:close()
      elseif b[1] == "send" then self:send()
      elseif b[1] == "folder" then BR.show(self.saved)
      elseif b[1] == "copy" then self:copy() end
    end
    bx = bx + widths[i] + 6
  end
  for k, l in ipairs(nl) do Q.text(x, ny + (k - 1) * Q.line_h(11), C.note, l.s, 11, false, C.bg) end
  if self.status ~= "" then
    for k, l in ipairs(sl) do Q.text(x, sy + (k - 1) * Q.line_h(11), C.note, l.s, 11, false, C.bg) end
  end
end

return BW
