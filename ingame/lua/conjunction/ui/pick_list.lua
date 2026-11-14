-- The things of the world picked for a step, at the right edge while picking (MaximdeWinter 12.11.): each one with its
-- distance from the camera now, Go to and Remove; what the step does to them (a light on or off, instant or slowly;
-- a door opens, closes ...) set here; Test plays it on them in the game and Reset gives them back; Done takes them
-- (Enter too). A click in the world picks one, Shift+click one more (world_pick.lua, editor.select_mode).
--   PL.frame(ed, W, H)     PL.covers(x, y)
-- r.settings (quest_board.pick_settings): {{label, choices = {{value, text}}, get(), set(value)}}
local Q = require("conjunction.ui.qt")
local D = w3.ui.draw
local PL = {}

PL.W = 320
local ROW_H, HEAD_H, SET_H, PAD = 26, 30, 30, 8
local rect = nil

local function inside(x, y, r) return r and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h end
function PL.covers(x, y) return inside(x, y, rect) end

-- (its own hits: the controls' blocker keeps the mouse from what lies under the bar, and the list counts as the
-- bar's - through CT.hit_box nothing in it took a click, 12.11.)
local function hit(id, r)
  w3.ui.set_pos(r.x, r.y)
  local clicked, hovered, held = w3.ui.hit("pick." .. id, r.w, r.h)
  return clicked == 1, hovered, held
end
local function button(id, r, text, primary)
  local clicked, hovered, held = hit(id, r)
  Q.button(r.x, r.y, r.w, r.h, text, {hover = hovered, pressed = held and hovered, primary = primary})
  return clicked
end

-- the step's choices: a row of buttons each, the one it has now highlighted
local function settings(r, sets, picked, x, y)
  for si, s in ipairs(sets) do
    Q.text(x + PAD, y + 6, 0x9a9a9aff, s.label, 12)
    local bx = x + PAD + 70
    local now = s.get()
    for ci, ch in ipairs(s.choices) do
      local bw = Q.button_size(ch[2])
      if button("set." .. si .. "." .. ci, {x = bx, y = y + 2, w = bw, h = SET_H - 4}, ch[2], now == ch[1]) and now ~= ch[1] then
        s.set(ch[1])
        if r.test_restore then                    -- (a test going on: shown again as the step says now)
          r.test_restore()
          r.test_restore = r.test(picked)
        end
      end
      bx = bx + bw + 4
    end
    y = y + SET_H
  end
  return y
end

function PL.frame(ed, W, H)
  rect = nil
  local r = ed.request
  if not (r and r.world and ed.cam and ed.cam.pos) then return end
  local WP = require("conjunction.world_pick")
  local picked = r.picked or {}
  local rows = math.max(1, #picked)
  local sets = {}                                 -- (s.shown: a choice only for some of them, Slowly without a flame)
  for _, s in ipairs(r.settings or {}) do
    if not s.shown or s.shown(picked) then sets[#sets + 1] = s end
  end
  local nset = #sets
  local h = HEAD_H + rows * ROW_H + PAD + nset * SET_H + (nset > 0 and PAD or 0) + 30 + PAD
  local x, y = W - PL.W - 12, 110
  h = math.min(h, H - y - 20)
  rect = {x = x, y = y, w = PL.W, h = h}
  D.fill(x, y, PL.W, h, 0x18181aeb)
  D.rect(x, y, PL.W, h, 0x444444ff, 1)
  local title = string.format("%s · %d", (WP.noun(r.world, true):gsub("^%l", string.upper)), #picked)
  Q.text(x + PAD, y + 7, 0xeeeeeeff, title, 13, true)
  local cy = y + HEAD_H
  if #picked == 0 then
    Q.text(x + PAD, cy + 4, 0x888888ff, "None yet", 12)
  end
  local gone = nil
  local p = ed.cam.pos
  local foot = y + h - PAD - 30 - nset * SET_H - (nset > 0 and PAD or 0)
  for i, c in ipairs(picked) do
    if cy + ROW_H > foot then break end
    local d = c.pos and math.sqrt((c.pos[1] - p[1]) ^ 2 + (c.pos[2] - p[2]) ^ 2 + (c.pos[3] - p[3]) ^ 2) or nil
    local bw = 26
    local xr = {x = x + PL.W - PAD - bw, y = cy + 2, w = bw, h = ROW_H - 4}
    local gw = Q.button_size("Go to")
    local gr = {x = xr.x - 4 - gw, y = cy + 2, w = gw, h = ROW_H - 4}
    local dist = d and string.format("%d m", math.floor(d + 0.5)) or ""
    local dw = Q.text_w(dist, 12)
    Q.text(gr.x - 8 - dw, cy + 5, 0x9a9a9aff, dist, 12)
    D.clip(x + PAD, cy, math.max(0, gr.x - 16 - dw - x - PAD), ROW_H, function()
      Q.text(x + PAD, cy + 5, WP.CHOSEN, c.name, 12)
    end)
    local go = button("goto." .. i, gr, "Go to")
    if go and c.go then
      c.go()                                      -- (a thing of the project: the editor goes to it)
    elseif go and c.pos then
      ed.beacon = {pos = {c.pos[1], c.pos[2], c.pos[3]}, label = c.name, ["until"] = ed.sys.time() + 4.0}
      ed:exec(string.format("cj_cam_to(%.3f, %.3f, %.3f, %.1f)", c.pos[1], c.pos[2], c.pos[3], 0.0))
    end
    local hx, hover = hit("remove." .. i, xr)
    Q.button(xr.x, xr.y, xr.w, xr.h, "", {hover = hover})
    -- (a red cross, drawn: the icon font left the box empty here, 12.11.)
    local cx, cy2, k = xr.x + xr.w / 2, xr.y + xr.h / 2, 5
    local red = hover and 0xff6a5aff or 0xe0503fff
    D.line(cx - k, cy2 - k, cx + k, cy2 + k, red, 2)
    D.line(cx - k, cy2 + k, cx + k, cy2 - k, red, 2)
    if hx then gone = i end
    cy = cy + ROW_H
  end
  if gone then
    if r.test_restore then r.test_restore() r.test_restore = nil end   -- (tested on it too: back first)
    table.remove(picked, gone)
  end
  -- what the step does, then the foot: Test / Reset (when the step can be tried here), Done
  if nset > 0 then
    D.fill(x + PAD, foot + PAD // 2, PL.W - 2 * PAD, 1, 0x3a3a3aff)
    settings(r, sets, picked, x, foot + PAD)
  end
  local fy = y + h - PAD - 30
  local dw2 = Q.button_size("Done")
  local done_r = {x = x + PL.W - PAD - dw2, y = fy, w = dw2, h = 30}
  if button("done", done_r, "Done", #picked > 0) and (#picked > 0 or r.edit) then ed:take_picked() return end
  if r.test then
    local label = r.test_restore and "Reset" or "Test"
    local tw = Q.button_size(label)
    local tr = {x = done_r.x - 6 - tw, y = fy, w = tw, h = 30}
    if button("test", tr, label) and #picked > 0 then
      if r.test_restore then
        r.test_restore()
        r.test_restore = nil
      else
        r.test_restore = r.test(picked)
      end
    end
  end
end

return PL
