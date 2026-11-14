-- Build & Play's card over the game (build_view.BuildWindow with its curtain): the logo's rings turning over the
-- build's lines as they come in, the stage in words, a bar of how far it is. Done, it closes 1.8 s later; failed, it
-- stays with its reason and Close. The card (860 x 560 at most) in the middle of the game's picture, its box (820 x 520
-- at most, a LINE frame) in the middle of the card; the box a QVBoxLayout (margins 22 14 22 16, 8 apart): the rings
-- (150 high), the title (17 px bold), the stage (13 px), the bar (5 high), the log (Consolas 11 px, DIM on SURFACE, a
-- LINE border, padding 6: the rest of the height), Close at the right.
--   local w = BW.new(title, {stages, done_text, on_close})   w:line(text)   w:frame(W, H) -> covers   w.closed
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local TL = require("conjunction.ui.textlayout")
local D = w3.ui.draw
local BW = {}
BW.__index = BW

BW.STAGES = {{"keeps running (script", 2, "building while the game runs"}, {"[play] quick save", 3, "saving the game"},
             {"encode quest", 8, "writing the quest"}, {"analyze, cook", 18, "cooking"}, {": scene ", 40, "cooking the scenes"},
             {"pack, metadatastore", 62, "packing"}, {": strings", 72, "texts and voices"}, {"installed ->", 82, "installing"},
             {"[play] game starting", 86, "starting the game"}, {"step aside", 84, "the runs before step aside"},
             {"[play] live: ok", 88, "loading it into the game"}, {"reloading the save", 92, "loading the save"},
             {"save loaded", 97, "loading the save"}, {"[done]", 100, "done"}}
BW.EXPORT_STAGES = {{"[export] checking", 2, "checking the quest"}, {"[export] Built again", 4, "building the quest under its own id"},
                    {"encode quest", 8, "writing the quest"}, {"analyze, cook", 20, "cooking"},
                    {": scene ", 40, "cooking the scenes"}, {"pack, metadatastore", 58, "packing"},
                    {": strings", 66, "texts and voices"}, {"[export] the quest file", 76, "the quest file"},
                    {"[export] the zip", 88, "the zip for mod managers"}, {"[export] the page text", 96, "the text for its page"},
                    {"[done]", 100, "done"}}
BW.MAX_LINES = 400
BW.CARD = {860, 560}
BW.PERIOD, BW.SPEED = 2.4, math.rad(40)
BW.RING = (214 << 24) | (170 << 16) | (92 << 8) | 255
BW.RING_FAILED = (229 << 24) | (122 << 16) | (122 << 8) | 255
local MONO, LOG_PX = "mono", 11
local MARGIN = 4                                 -- (a QPlainTextEdit's document margin)

function BW.new(title, opts)
  opts = opts or {}
  local self = setmetatable({title = title, stages = opts.stages or BW.STAGES, done_text = opts.done_text or
                            "The quest is in the game", on_close = opts.on_close, stage = "Starting...", stage_red = false,
                            state = "busy", since = 0.0, t0 = w3.time(), lines = {""}, queue = {}, progress = 0.0,
                            target = 0, done = false, frames = {}, now = opts.clock}, BW)
  return self
end

function BW:time() return self.now and self.now() or (w3.time() - self.t0) end

-- a line of the build (the stage it reaches, typed out, failed or done)
function BW:line(text)
  if text == "\0" then return end
  for _, st in ipairs(self.stages) do
    if text:find(st[1], 1, true) and st[2] > self.target then
      self.target = st[2]
      self.stage = st[3]:sub(1, 1):upper() .. st[3]:sub(2) .. (st[2] < 100 and "..." or "")
    end
  end
  if text:sub(1, 8) == "[failed]" then self:failed((text:sub(10):gsub("^%s+", ""):gsub("%s+$", ""))) end
  local short = #text < 160 and text or (text:sub(1, 157) .. "...")
  self.queue[#self.queue + 1] = short .. "\n"
  if text:sub(1, 6) == "[done]" and not self.done then
    self.done = true
    self.stage = self.done_text
    self:finish(true)
    self.close_at = w3.time() + 1.8
  end
end

function BW:finish(ok)
  self.state = ok and "done" or "failed"
  self.since = self:time()
end

function BW:failed(reason)
  self.done = true
  self.stage = "Failed: " .. reason
  self.stage_red = true
  self:finish(false)
end

-- the newest line types itself (a long backlog flushes faster: the cook can log hundreds of lines at once)
function BW:type_step()
  if #self.queue == 0 then return end
  local n = #self.queue < 3 and 4 or (#self.queue < 30 and 40 or 10000)
  local cur = self.queue[1]
  local chunk, rest = cur:sub(1, n), cur:sub(n + 1)
  if rest ~= "" then self.queue[1] = rest else table.remove(self.queue, 1) end
  for c in chunk:gmatch("[^\n]*\n?") do
    if c ~= "" then
      if c:sub(-1) == "\n" then
        self.lines[#self.lines] = self.lines[#self.lines] .. c:sub(1, -2)
        self.lines[#self.lines + 1] = ""
        while #self.lines > BW.MAX_LINES do table.remove(self.lines, 1) end
      else
        self.lines[#self.lines] = self.lines[#self.lines] .. c
      end
    end
  end
end

function BW:ease_step()
  if self.progress < self.target then
    self.progress = math.min(self.target, self.progress + math.max(0.15, (self.target - self.progress) * 0.06))
  end
end
-- the steps since the last frame: the bar every 30 ms (its timer), the typing every 16 ms
function BW:steps()
  local t = w3.time()
  self.last = self.last or t
  local dt = math.min(1.0, t - self.last)
  self.last = t
  self.ease_acc = (self.ease_acc or 0) + dt
  while self.ease_acc >= 0.03 do self.ease_acc = self.ease_acc - 0.03 self:ease_step() end
  self.type_acc = (self.type_acc or 0) + dt
  local n = 0
  while self.type_acc >= 0.016 and n < 8 do self.type_acc = self.type_acc - 0.016 self:type_step() n = n + 1 end
  if n == 0 then self:type_step() end            -- (at least one a frame: frames are about 16 ms)
end

-- the rings' turn (rad) now: turning; done, slowing to standing in a second; failed, stopped
function BW:turn()
  local t = self:time()
  if self.state == "busy" then return t * BW.SPEED end
  if self.state == "done" then
    local s = math.min(1.0, t - self.since)
    return self.since * BW.SPEED + BW.SPEED * (s - s * s / 2)
  end
  return self.since * BW.SPEED
end

-- the rings' picture (cj_qt: Qt's painter), kept per turn: the picture repeats every 30 degrees (12 teeth)
function BW:rings(w, h)
  local step = 2 * math.pi / 12
  local turn = self:turn()
  local key
  if self.exact then key = string.format("%.6f", turn)
  else
    turn = (math.floor((turn % step) / math.rad(1) + 0.5) * math.rad(1)) % step     -- (a degree a picture)
    key = string.format("%d", math.floor(turn / math.rad(1) + 0.5))
  end
  local colour = self.state == "failed" and BW.RING_FAILED or BW.RING
  key = string.format("%dx%d_%08x_%s", w, h, colour, key)
  local img = self.frames[key]
  if img == nil then
    local dir = (os.getenv("TEMP") or "C:\\tmp") .. "\\conjunction_rings"
    if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
    local out = dir .. "\\" .. key .. ".png"
    require("conjunction.ui.qtpaint").paint(out, w, h, {"aa 1", string.format("gears 0 0 %d %d %.9f %08x", w, h, turn, colour)})
    local id, iw, ih = w3.ui.image_load(out)
    img = id and {id, iw, ih} or false
    self.frames[key] = img
  end
  return img
end

function BW:close()
  if self.closed then return end
  self.closed = true
  if self.on_close then self.on_close() end
end

-- the log's visual lines at a width (QPlainTextEdit: each paragraph wrapped at words)
local function visual(lines, w)
  local out = {}
  for _, l in ipairs(lines) do
    if l == "" then out[#out + 1] = ""
    else
      for _, v in ipairs(TL.wrap(l, LOG_PX, MONO, math.max(0, w), "word_any")) do out[#out + 1] = v.s end
    end
  end
  return out
end

-- one frame over the game's picture (W x H) -> whether the mouse is over the card
function BW:frame(W, H)
  if self.closed then return false end
  if self.timed ~= false then self:steps() end
  if self.close_at and w3.time() >= self.close_at then self:close() return false end
  local cw, ch = math.min(BW.CARD[1], W), math.min(BW.CARD[2], H)
  local card = {x = (W - cw) // 2, y = (H - ch) // 2, w = cw, h = ch}
  D.fill(card.x, card.y, card.w, card.h, T.BG)
  local bw, bh = math.min(820, cw - 40), math.min(520, ch - 40)
  local box = {x = card.x + (cw - bw) // 2, y = card.y + (ch - bh) // 2, w = bw, h = bh}
  D.fill(box.x - 1, box.y - 1, box.w + 2, box.h + 2, T.LINE)
  D.fill(box.x, box.y, box.w, box.h, T.BG)
  local x, y, w = box.x + 22, box.y + 14, box.w - 44
  local bottom = box.y + box.h - 16
  -- the rings
  local img = self:rings(w, 150)
  if img then D.image(img[1], x, y, img[2], img[3]) end
  y = y + 150 + 8
  -- the title and the stage, in the middle
  local th = Q.line_h(17, true)
  Q.text(x + (w - Q.text_w(self.title, 17, true)) // 2, y, T.BRIGHT, self.title, 17, true, T.BG)
  y = y + th + 8
  local sh = Q.line_h(13)
  local stage = self.stage
  Q.text(x + (w - Q.text_w(stage, 13)) // 2, y, self.stage_red and T.RED or T.DIM, stage, 13, false, T.BG)
  y = y + sh + 8
  -- the bar
  D.fill(x, y, w, 5, T.FIELD)
  local fill = (w * math.floor(self.progress)) // 100
  if fill > 0 then D.fill(x, y, fill, 5, self.stage_red and T.RED or T.GOLD) end
  y = y + 5 + 8
  -- Close (failed): at the right of the last row
  local close_h = 0
  if self.state == "failed" then
    local cbw, cbh = Q.button_size("Close")
    close_h = cbh + 8
    if CT.button("build.close", x + w - cbw, bottom - cbh, "Close", {w = cbw, h = cbh, fg = 0xddddddff}) then
      self:close()                               -- (the app sheet's QPushButton: #ddd)
    end
  end
  -- the log: the end in view
  local lh = Q.line_h(LOG_PX, MONO)
  local lr = {x = x, y = y, w = w, h = bottom - close_h - y}
  Q.frame(lr.x, lr.y, lr.w, lr.h, T.SURFACE, T.LINE)
  local vx, vy, vw, vh = lr.x + 1 + 6, lr.y + 1 + 6, lr.w - 14, lr.h - 14
  local tw = vw - 2 * MARGIN
  local shown = self.lines
  if shown[#shown] == "" and #shown > 1 then shown = {table.unpack(shown, 1, #shown - 1)} end
  local vis = visual(shown, tw)
  local fit = math.max(1, (vh - MARGIN) // lh)
  local bar = #vis > fit
  if bar then
    tw = vw - 10 - 2 * MARGIN
    vis = visual(shown, tw)
  end
  local first = math.max(1, #vis - fit + 1)
  D.clip(vx, vy, vw - (bar and 10 or 0), vh, function()
    for k = first, #vis do
      Q.text(vx + MARGIN, vy + MARGIN + (k - first) * lh, T.DIM, vis[k], LOG_PX, MONO, T.SURFACE)
    end
  end)
  if bar then
    local SBAR = require("conjunction.ui.scrollbar")
    local IV = require("conjunction.ui.itemview")
    self.vbar = self.vbar or IV.bar(1, 0, 0)
    self.vbar.page = fit
    IV.range(self.vbar, #vis - fit)
    self.vbar.value = #vis - fit
    SBAR.draw(self, "build.vbar", self.vbar, {x = vx + vw - 10, y = vy, w = 10, h = vh}, "v",
              function(id, b) return CT.hit_box(id, b) end)
  end
  return CT.over(card)
end

return BW
