-- The look window (look_chooser.LookChooser in a CatalogWindow, "Choose a look"): every look of a person as a tile
-- (a QListWidget in icon mode: 96 x 136 icons on a 112 x 166 grid, the label under it), the one clicked large and
-- turnable beside them (its title, "(current)" for the look it has now, Use this look). Tiles not yet drawn are blank
-- (48, 50, 55) until LookPainter has them; a click shows the look from the front; a double click or the button uses it.
--   local body = LW.new(panel, win, template, current, then_)   body:frame(r)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local PIC = require("conjunction.ui.pictures")
local LC = require("conjunction.look_chooser")
local MV = require("conjunction.meshview")
local V3 = require("conjunction.ui.view3d")
local D = w3.ui.draw
local LW = {}
LW.__index = LW

local function rgba(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
LW.C = {blank = (48 << 24) | (50 << 16) | (55 << 8) | 255, text = rgba("#dddddd"), chosen_text = rgba("#ffffff"),
        title = rgba("#eeeeee"), clear = (48 << 24) | (51 << 16) | (56 << 8) | 255,
        dim = (125 << 24) | (125 << 16) | (128 << 8) | 255}
local C = LW.C
LW.GRID_W, LW.GRID_H = LC.TILE[1] + 16, LC.TILE[2] + 30

function LW.new(panel, win, template, current, then_, speaks)
  local self = setmetatable({panel = panel, win = win, template = template, current = current or "", then_ = then_,
                             speaks = speaks, bar = IV.bar(), v3 = V3.new()}, LW)
  -- which looks have a face that moves its mouth (talking.lua, read in the background: a coroutine)
  self.talk_job = coroutine.create(function()
    local ok, talks = pcall(require("conjunction.talking").talking_looks, template, V3.depot())
    return ok and talks or nil
  end)
  local apps, used = MV.looks(template, V3.depot())
  local names = {}
  for _, k in ipairs(apps.keys) do names[#names + 1] = k end
  self.looks = {""}
  for _, lk in ipairs(LC.ordered(names, used)) do self.looks[#self.looks + 1] = lk end
  self.cur = 1
  for i, lk in ipairs(self.looks) do if lk == self.current then self.cur = i end end
  for _, lk in ipairs(self.looks) do
    if not w3.fs.exists(LC.cache_file(template, lk)) then LC.want(template, lk) end
  end
  self:show(self.looks[self.cur])
  return self
end

function LW:hit(id, r) return self.win:hit(id, r) end

-- clicked: large, to turn (from the front, as the tiles)
function LW:show(look)
  self.shown = look
  self.name = LC.label(look) .. (look == self.current and "   (current)" or "")
  local v = self.v3
  self.v3_key = look
  v:load(look, function()
    local ok, parts = pcall(function()
      local _, parts = MV.entity_parts(self.template, V3.depot(), {}, look ~= "" and look or nil)
      return parts
    end)
    return ok and parts or {}
  end, function(k, ok, parts)
    if k ~= self.shown or not ok then return end
    if v:show_parts(parts) then v.yaw, v.pitch = 180.0, 0.0 end
  end)
end

function LW:use(look)
  if look == nil then return end
  self.current = look
  if self.then_ then self.then_(look) end
  self.win:close()
end

-- the grid (QListView IconMode, Adjust, Static): as many columns as the viewport takes, rows of GRID_H
function LW:draw_grid(r)
  Q.view_frame(r.x, r.y, r.w, r.h)
  local vx, vy, vw, vh = r.x + 1, r.y + 1, r.w - 2, r.h - 2
  local shown = {}
  for i, lk in ipairs(self.looks) do
    if not (self.mark and self.mark[lk] == "hidden") then shown[#shown + 1] = i end
  end
  local n = #shown
  local cols = math.max(1, vw // LW.GRID_W)
  local rows = (n + cols - 1) // cols
  local need = rows * LW.GRID_H
  local b = self.bar
  if need > vh then vw = vw - 10 cols = math.max(1, vw // LW.GRID_W) rows = (n + cols - 1) // cols need = rows * LW.GRID_H end
  b.single, b.page = 20, vh
  IV.range(b, math.max(0, need - vh))
  local _, over = self:hit("look.grid", {x = vx, y = vy, w = vw, h = vh})
  local on_item = false
  local mx, my, wheel = w3.ui.mouse()
  if over and wheel and wheel ~= 0 then IV.wheel(b, wheel >= 0 and math.min(wheel, 1) or math.max(wheel, -1), 3) end
  local lh = Q.line_h()
  D.clip(vx, vy, vw, vh, function()
    for at, i in ipairs(shown) do
      local lk = self.looks[i]
      local col, row = (at - 1) % cols, (at - 1) // cols
      local ix, iy = vx + col * LW.GRID_W, vy + row * LW.GRID_H - b.value
      local ih = 4 + LC.TILE[2] + 4 + lh + 0     -- (the item: its decoration, the label under it - measured: 157)
      ih = 157
      local item = {x = ix, y = iy, w = LW.GRID_W, h = ih}
      local chosen = i == self.cur
      if chosen then D.fill(ix, iy, item.w, item.h, T.CHOSEN) end
      local bg = chosen and T.CHOSEN or T.SURFACE
      local file = LC.cache_file(self.template, lk)
      if w3.fs.exists(file) then
        -- (the icon's size is worked out twice - QIcon.actualSize for the item, then again where it is painted -
        -- each time kept to its aspect: a 200 x 272 tile becomes 96 x 130, then 95 x 130)
        local fw, fh = PIC.size(file)
        local aw, ah = PIC.keep_aspect(fw, fh, LC.TILE[1], LC.TILE[2])
        local pw, ph = PIC.keep_aspect(fw, fh, aw, ah)
        local id = PIC.texture(file, pw, ph, bg)
        if id then D.image(id, ix + (LW.GRID_W - pw + 1) // 2, iy + 4, pw, ph) end
      else
        D.fill(ix + (LW.GRID_W - LC.TILE[1] + 1) // 2, iy + 4, LC.TILE[1], LC.TILE[2], C.blank)
      end
      local label = LC.label(lk)
      local fl = T.FONT_LIST
      local mark = self.mark and self.mark[lk]
      local fg = chosen and C.chosen_text or (mark == "dim" and C.dim or C.text)
      Q.text(ix + (LW.GRID_W - Q.text_w(label, fl)) // 2, iy + 137, fg, label, fl, false, bg)
      local clicked, hovered = self:hit("look.tile." .. i, item)
      if hovered then
        -- (an item's own tooltip: its look; for the talking marks what they mean)
        on_item = true
        local t = lk ~= "" and lk or "default"
        if mark == "speaks" then t = lk .. " (can speak)"
        elseif mark == "dim" then t = lk .. " (background look without a moving face, a speaker needs one that can)" end
        CT.tip("panel.look.tile", {"", t})
      end
      -- (itemDoubleClicked comes with the second press; the click, with the release)
      if hovered and w3.ui.mouse_double(1) and self.press == i then self:use(lk) return end
      if clicked then
        self.press = i
        if self.cur ~= i then
          self.cur = i
          self:show(lk)
        end
      end
    end
  end)
  if over and not on_item then CT.tip("panel.look.tiles", "look.tiles") end
  if need > vh then
    SBAR.draw(self, "look.vbar", b, {x = vx + vw, y = vy, w = 10, h = vh}, "v", function(id, rr) return self:hit(id, rr) end)
  end
end

-- the talking looks read on (a frame's share), then marked: a look without a face that moves is hidden for a person
-- who speaks in the quest (unless it is theirs now), dimmed for everyone else
function LW:read_talks()
  local co = self.talk_job
  if not co then return end
  MV.deadline = os.clock() + V3.BUDGET
  local ok, talks = coroutine.resume(co)
  MV.deadline = nil
  if coroutine.status(co) ~= "dead" then return end
  self.talk_job = nil
  if ok and talks and #talks > 0 then
    local set = {}
    for _, t in ipairs(talks) do set[t] = true end
    self.mark = {}
    for _, lk in ipairs(self.looks) do
      if lk ~= "" then
        if set[lk] then self.mark[lk] = "speaks"
        elseif self.speaks and lk ~= self.current then self.mark[lk] = "hidden"
        else self.mark[lk] = "dim" end
      end
    end
  end
end

function LW:frame(r)
  self.v3:tick()
  self:read_talks()
  -- QHBoxLayout 8 apart: the grid (stretch 3), the right column (stretch 2)
  local avail = r.w - 8
  local gw = (avail * 3 + 2) // 5
  local grid = {x = r.x, y = r.y, w = gw, h = r.h}
  self:draw_grid(grid)
  local rx, rw = r.x + gw + 8, r.w - gw - 8
  local th = Q.line_h(14, true)
  Q.text(rx, r.y, C.title, self.name or "", 14, true)
  local bh = 29
  local view = {x = rx, y = r.y + th + 8, w = rw, h = r.h - th - 8 - 8 - bh}
  if self.v3.mesh then
    self.v3:draw(view, function(id, rr) return self:hit(id, rr) end)
  else
    D.fill(view.x, view.y, view.w, view.h, LW.C.clear)    -- (MeshView before its parts: only its clear colour)
  end
  local b = {x = rx, y = r.y + r.h - bh, w = rw, h = bh}
  local clicked, hv, held = self:hit("look.use", b)
  Q.button(b.x, b.y, b.w, b.h, "Use this look", {hover = hv or held, pressed = held and hv, fg = T.BUTTON_TEXT})
  if hv then CT.tip("panel.look.use", "look.use") end
  if clicked then self:use(self.shown) end
end

return LW
