-- story_view.py: the story map - every quest of the game on one timeline (story.lua places them), in a lane per
-- region, the main story on top, the acts and the level ruler above, the project's own quest above it all. One of the
-- panel's windows (editor:open_story).
--   the chips: which kinds and games are shown; a click on a quest: its chain (what it waits for gold, what waits
--   for it blue, the rest dimmed) and its details at the right; a click on the map or Esc: nothing picked; the search:
--   the quests with the words, the first one in view; the wheel zooms (under the mouse), a drag moves
-- The map is a QGraphicsView (StoryMap): its arithmetic as Qt's (ranges, the bars as needed, AnchorUnderMouse,
-- AlignLeft | AlignTop) and its scene painted by Qt itself (cj_qt), each item as the app paints it.
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local ST = require("conjunction.story")
local P = require("conjunction.py")
local Y = require("conjunction.yaml")
local PYS = require("conjunction.pystr")
local D = w3.ui.draw
local SW = {}
SW.__index = SW

SW.PX = 96
SW.CARD_W, SW.CARD_H, SW.ROW = 176, 26, 30
SW.LABEL_W, SW.RULER_H, SW.TOP = 128, 46, 4
SW.DETAIL_ZOOM = 0.5
SW.KIND_COLOUR = {main = "#d9a441", side = "#7d8fa8", contract = "#c0504d", treasure = "#4f9a6a"}
SW.KIND_NAME = {{"main", "Main"}, {"side", "Side"}, {"contract", "Contracts"}, {"treasure", "Treasure"}}
SW.CARD_KIND = {main = "Main quest", side = "Side quest", contract = "Contract", treasure = "Treasure hunt"}
SW.GAME_FILTER = {{"base", "Base game"}, {"Hearts of Stone", "Hearts of Stone"}, {"Blood and Wine", "Blood and Wine"}}
SW.GAME_COLOUR = {["Hearts of Stone"] = "#8e5bd1", ["Blood and Wine"] = "#a8324a"}
SW.REGION = {[4] = "White Orchard", [9] = "Velen", [1] = "Novigrad", [2] = "Skellige", [3] = "Kaer Morhen",
             [11] = "Toussaint", [5] = "Vizima", [8] = "Vizima"}
SW.SHOWN = {main = true, side = true, contract = false, treasure = false, base = true, ["Hearts of Stone"] = true,
            ["Blood and Wine"] = true}
SW.BY, SW.UNLOCKS, SW.OWN = "#d9a441", "#5b9bd5", "#5cb85c"
local KIND_KEYS = {main = true, side = true, contract = true, treasure = true}

local function hex(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
SW.C = {chip_fg = hex("#9a9aa0"), chip_bg = hex("#1b1b1e"), chip_edge = hex("#3a3a40"), chip_on_fg = hex("#f0f0f2"),
        chip_on_bg = hex("#2c2c32"), chip_on_edge = hex("#5a5a62"), chip_hover = hex("#7a7a82"),
        view_bg = hex("#141417"), view_edge = hex("#333333"), side_bg = hex("#18181b"), detail = hex("#d8d8dc"),
        hook_bg = (92 << 24) | (184 << 16) | (92 << 8) | 40, hook_edge = hex("#5cb85c")}
local C = SW.C

-- a Qt colour for a paint command: rrggbbaa
local function qc(s, a)
  if type(s) == "number" then return string.format("%08x", s) end
  return string.format("%s%02x", s:sub(2):lower(), a or 255)
end
local function num(x)
  if math.type(x) == "integer" then return tostring(x) end
  return string.format("%.17g", x)
end
local function qround(x) return x >= 0 and math.floor(x + 0.5) or -math.floor(-x + 0.5) end
local function trunc(x) return x >= 0 and math.floor(x) or -math.floor(-x) end

-- ===================================================================================================================
-- the map (story_view.StoryMap)
local SM = {}
SM.__index = SM
SW.Map = SM

function SM.new()
  local self = setmetatable({items = {}, cards = {}, card_list = {}, lines = {}, spine = {}, current = nil,
                             quests = {}, bands = {}, acts = {}, m11 = 1.0, hval = 0, vval = 0, hmin = 0, hmax = 0,
                             vmin = 0, vmax = 0, w = 100, h = 100, vw = 98, vh = 98, hbar_on = false,
                             vbar_on = false, scene = {0, 0, 0, 0}, seq = 0, hot = nil, img = nil, img_key = nil,
                             hbar = IV.bar(1, 0, 0), vbar = IV.bar(1, 0, 0), bar_state = {}}, SM)
  self.file = (os.getenv("TEMP") or ".") .. "\\cj_story_" .. tostring(self):gsub("[^%w]", "") .. ".png"
  return self
end

-- --- QGraphicsView's arithmetic (recalculateContentSize: the frame 1 px, the bars as needed, 10 wide - but the ranges
-- reckon a bar as 12, its extent and the frame twice: SH_ScrollView_FrameOnlyAroundContents; the pages 2 less than
-- the viewport, as Qt has them: ref/probe_story_bars.py)
function SM:recalc()
  local s = self.m11
  local sr = self.scene
  local vx, vy, vw, vh = sr[1] * s, sr[2] * s, sr[3] * s, sr[4] * s
  local maxw, maxh = self.w - 2, self.h - 2
  local use_h, use_v = vw > maxw, vh > maxh
  if use_h and vh > maxh - 12 then use_v = true end
  if use_v and vw > maxw - 12 then use_h = true end
  local width, height = maxw - (use_v and 12 or 0), maxh - (use_h and 12 or 0)
  self.hbar_on, self.vbar_on = use_h, use_v
  self.vw, self.vh = maxw - (use_v and 10 or 0), maxh - (use_h and 10 or 0)
  self.hpage, self.vpage = width, height
  local left, right = qround(vx), qround(vx + vw - width)
  if left >= right then
    self.hmin, self.hmax, self.hval = 0, 0, 0             -- (AlignLeft: the scene's left at the left)
  else
    self.hmin, self.hmax = left, right
    self.hval = math.max(left, math.min(right, self.hval))
  end
  local top, bottom = qround(vy), qround(vy + vh - height)
  if top >= bottom then
    self.vmin, self.vmax, self.vval = 0, 0, 0
  else
    self.vmin, self.vmax = top, bottom
    self.vval = math.max(top, math.min(bottom, self.vval))
  end
end
function SM:set_h(v) self.hval = math.max(self.hmin, math.min(self.hmax, math.tointeger(v) or qround(v))) end
function SM:set_v(v) self.vval = math.max(self.vmin, math.min(self.vmax, math.tointeger(v) or qround(v))) end
function SM:to_scene(px, py) return (px + self.hval) / self.m11, (py + self.vval) / self.m11 end
function SM:from_scene(x, y) return qround(x * self.m11 - self.hval), qround(y * self.m11 - self.vval) end
function SM:from_scene_f(x, y) return x * self.m11 - self.hval, y * self.m11 - self.vval end
function SM:center_on(x, y)
  self:set_h(qround(x * self.m11 - self.vw / 2.0))
  self:set_v(qround(y * self.m11 - self.vh / 2.0))
  self.last_center = {x, y}
end
function SM:update_center()
  self.last_center = {self:to_scene((self.vw - 1) // 2, (self.vh - 1) // 2)}
end
function SM:resize(w, h)
  if w == self.w and h == self.h then return end
  self.w, self.h = w, h
  self:recalc()
  self:update_center()
end
-- QGraphicsView.scale with AnchorUnderMouse: the ranges anew, then the point under the mouse kept there (mouse:
-- the viewport's point, nil when the mouse is not over it - then the last centre)
function SM:scale(k, mouse)
  local before = mouse and {self:to_scene(mouse[1], mouse[2])} or nil
  self.m11 = self.m11 * k
  self:recalc()
  if mouse then
    local cx, cy = self:to_scene((self.vw - 1) // 2, (self.vh - 1) // 2)
    local mx, my = self:to_scene(mouse[1], mouse[2])
    self:center_on(before[1] + (cx - mx), before[2] + (cy - my))
  elseif self.last_center then
    self:center_on(self.last_center[1], self.last_center[2])
  end
end
-- QGraphicsView.ensureVisible(rect, xmargin, ymargin)
function SM:ensure_visible(rx, ry, rw, rh, xm, ym)
  local s = self.m11
  local l, t = rx * s, ry * s
  local r, b = l + rw * s, t + rh * s
  local left, right, top, bottom = self.hval, self.hval + self.vw, self.vval, self.vval + self.vh
  if l <= left + xm then self:set_h(trunc(l - xm - 0.5)) end
  if r >= right - xm then self:set_h(trunc(r - self.vw + xm + 0.5)) end
  if t <= top + ym then self:set_v(trunc(t - ym - 0.5)) end
  if b >= bottom - ym then self:set_v(trunc(b - self.vh + ym + 0.5)) end
  self:update_center()
end

-- --- the scene: items in the order Qt paints them (z, then the order added)
function SM:add(item)
  self.ver = (self.ver or 0) + 1                -- (what the picture shows changed: SM.picture)
  self.seq = self.seq + 1
  item.seq = self.seq
  self.items[#self.items + 1] = item
  return item
end

-- the map: lanes, the acts and the level ruler, a card per quest, the main story's links always (faint); own: the
-- project's quest(s) {{quest, x}} (StoryMap.show_quests)
function SM:show_quests(quests, own, acts)
  local LW, PX, CW, CH, ROW = SW.LABEL_W, SW.PX, SW.CARD_W, SW.CARD_H, SW.ROW
  self.items, self.cards, self.card_list, self.lines, self.current, self.acts = {}, {}, {}, {}, nil, acts or {}
  self.seq = 0
  self.quests = {}
  for _, q in ipairs(quests) do self.quests[q.id] = q end
  local lanes = {{"own", "Your project"}}
  for _, l in ipairs(ST.LANES) do lanes[#lanes + 1] = l end
  local by_lane = {}
  for _, l in ipairs(lanes) do by_lane[l[1]] = {} end
  for _, q in ipairs(quests) do
    local list = by_lane[q.lane] or by_lane.other
    list[#list + 1] = q
  end
  by_lane.own = {}
  for _, o in ipairs(own or {}) do
    local q = {}
    for k, v in pairs(o[1]) do q[k] = v end
    q.x, q.lane = o[2], "own"
    by_lane.own[#by_lane.own + 1] = q
  end
  local x_max = 50
  for _, q in ipairs(quests) do x_max = math.max(x_max, q.x) end
  x_max = x_max + 3
  local width = LW + x_max * PX + CW
  local y = SW.TOP + SW.RULER_H
  local bands = {}
  local PS = require("conjunction.pysort")
  for _, lane in ipairs(lanes) do
    local key = lane[1]
    if #by_lane[key] > 0 then
      local rows, spots = {}, {}
      for _, q in ipairs(PS.sorted(by_lane[key], function(q) return q.x end)) do
        local cx = LW + q.x * PX
        local row
        for k, e in ipairs(rows) do if e < cx - 4 then row = k break end end
        if row == nil then
          rows[#rows + 1] = 0
          row = #rows
        end
        rows[row] = cx + CW
        spots[#spots + 1] = {q, cx, row - 1}
      end
      local h = #rows * ROW + 10
      bands[#bands + 1] = {lane[2], y, h, #spots}
      for _, s in ipairs(spots) do
        local c = self:add({kind = "card", z = 0, q = s[1], own = key == "own", x = s[2], y = y + 5 + s[3] * ROW,
                            picked = false, hit = false, opacity = 1.0})
        local id = s[1].id .. (key == "own" and "#own" or "")
        self.cards[id] = c
        self.card_list[#self.card_list + 1] = c
      end
      y = y + h
    end
  end
  self.bands = bands
  for k, b in ipairs(bands) do
    self:add({kind = "rect", z = -3, x = 0, y = b[2], w = width, h = b[3],
              fill = k % 2 == 0 and string.format("ffffff%02x", 6) or "ffffff00"})
    self:add({kind = "line", z = -2, x0 = 0, y0 = b[2] + b[3], x1 = width, y1 = b[2] + b[3], pen = "2a2a30ff",
              width = 1})
  end
  for lvl = 0, math.floor(x_max) do
    local x = LW + lvl * PX
    self:add({kind = "line", z = -2, x0 = x, y0 = SW.TOP + SW.RULER_H, x1 = x, y1 = y, pen = "ffffff0a", width = 1})
  end
  for _, a in ipairs(self.acts) do
    local x = LW + a[2] * PX - 6
    self:add({kind = "line", z = -1.5, x0 = x, y0 = SW.TOP + SW.RULER_H, x1 = x, y1 = y,
              pen = string.format("d9a441%02x", 70), width = 1, dash = true})
  end
  self.spine = {}
  for _, q in ipairs(quests) do
    if q.lane == "story" then
      for _, b in ipairs(q.by or {}) do
        local other = self.quests[b]
        if other and other.lane == "story" then
          local it = self:link(self.cards[b], self.cards[q.id], string.format("d9a441%02x", 45), 1.0, false)
          if it then self.spine[#self.spine + 1] = it end
        end
      end
    end
  end
  self.scene = {0, 0, width, y + 10}
  self:recalc()
end

-- a square line from a's right to b's left (sharp bends) (StoryMap._link; sceneBoundingRect: the card's rect and
-- half its pen, 0.5 around)
function SM:link(a, b, colour, width, keep)
  if a == nil or b == nil then return nil end
  local x0, y0 = a.x + SW.CARD_W + 0.5, a.y + SW.CARD_H / 2
  local x1, y1 = b.x - 0.5, b.y + SW.CARD_H / 2
  local mid = x1 > x0 + 16 and (x0 + math.max(8.0, (x1 - x0) / 2)) or (x0 + 8)
  local it = self:add({kind = "path", z = keep and -0.5 or -1, pts = {x0, y0, mid, y0, mid, y1, x1, y1}, pen = colour,
                       width = width})
  if keep then self.lines[#self.lines + 1] = it end
  return it
end

local function remove_items(items, gone)
  local drop = {}
  for _, g in ipairs(gone) do drop[g] = true end
  local keep = {}
  for _, it in ipairs(items) do if not drop[it] then keep[#keep + 1] = it end end
  return keep
end

-- a quest picked: its chain lit, the rest dimmed (StoryMap.pick); nil: nothing picked
function SM:pick(card)
  self.ver = (self.ver or 0) + 1
  self.items = remove_items(self.items, self.lines)
  self.lines = {}
  self.current = card
  for _, c in ipairs(self.card_list) do
    c.picked = c == card
    c.opacity = 1.0
  end
  for _, it in ipairs(self.spine) do it.hidden = card ~= nil end
  if card == nil then
    if self.on_pick then self.on_pick(nil) end
    return
  end
  local q = card.q
  local before = (not card.own) and ST.chain(self.quests, q.id, "by") or {}
  local after = (not card.own) and ST.chain(self.quests, q.id, "unlocks") or {}
  local hooks = {}
  for _, h in ipairs(q.hooks or {}) do hooks[h] = true end
  local lit = {[q.id] = true}
  for k in pairs(before) do lit[k] = true end
  for k in pairs(after) do lit[k] = true end
  for k in pairs(hooks) do lit[k] = true end
  for _, c in ipairs(self.card_list) do
    if c ~= card and not lit[c.q.id] then c.opacity = 0.16 end
  end
  -- (Python's set order: the lines are drawn in the order of these loops - the same pixels whichever comes first,
  -- each line is drawn alone in its colour)
  local function each(set, f)
    local ks = {}
    for k in pairs(set) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do f(k) end
  end
  local with_q = {[q.id] = true}
  for k in pairs(before) do with_q[k] = true end
  each(with_q, function(qid)
    for _, b in ipairs((self.quests[qid] or {}).by or {}) do
      if before[b] then
        local strong = qid == q.id
        self:link(self.cards[b], self.cards[qid], qc(SW.BY, strong and 255 or 120), strong and 2.0 or 1.0, true)
      end
    end
  end)
  local with_a = {[q.id] = true}
  for k in pairs(after) do with_a[k] = true end
  each(with_a, function(qid)
    for _, u in ipairs((self.quests[qid] or {}).unlocks or {}) do
      if after[u] then
        local strong = qid == q.id
        self:link(self.cards[qid], self.cards[u], qc(SW.UNLOCKS, strong and 255 or 120), strong and 2.0 or 1.0, true)
      end
    end
  end)
  each(hooks, function(h) self:link(self.cards[h], card, qc(SW.OWN), 2.0, true) end)
  if self.on_pick then self.on_pick(q) end
end

function SM:pick_id(qid)
  local c = self.cards[qid]
  if c then
    self:pick(c)
    self:ensure_visible(c.x - 0.5, c.y - 0.5, SW.CARD_W + 1, SW.CARD_H + 1, 120, 80)
  end
  return c
end

-- the quests whose title or code has the words: lit, the first one in the middle (StoryMap.find)
function SM:find(words)
  words = PYS.lower(PYS.strip(words or ""))
  local first
  for _, c in ipairs(self.card_list) do
    local q = c.q
    local text = PYS.lower(P.str(q.title or "") .. " " .. P.str(q.code or ""))
    c.hit = words ~= "" and text:find(words, 1, true) ~= nil
    if c.hit and first == nil then first = c end
  end
  self.any_hit = first ~= nil                  -- (SM.frame: their edges blink)
  self.ver = (self.ver or 0) + 1
  if first then self:center_on(first.x + SW.CARD_W / 2, first.y + SW.CARD_H / 2) end
  return first
end

-- the whole map in view, at least 0.12 (StoryMap.fit: fitInView, KeepAspectRatio, its 2 px margin)
function SM:fit()
  local sr = self.scene
  self:scale(1 / self.m11, nil)
  local vw, vh = self.vw - 4, self.vh - 4
  if vw <= 0 or vh <= 0 or sr[3] <= 0 or sr[4] <= 0 then return end
  local k = math.min(vw / (sr[3] * self.m11), vh / (sr[4] * self.m11))
  self:scale(k, nil)
  self:center_on(sr[1] + sr[3] / 2, sr[2] + sr[4] / 2)
  if self.m11 < 0.12 then
    self:scale(1 / self.m11, nil)
    self:scale(0.12, nil)
  end
end

-- --- painted by Qt: the scene's items in the view, then what stays in view (the lane names, the acts, the ruler)
local ALIGN_LEFT_V, ALIGN_RIGHT_V, ALIGN_CENTER = 0x81, 0x82, 0x84
local function txt(s) return (tostring(s):gsub("[%c]", " ")) end

function SM:card_cmds(out, c)
  local q = c.q
  local CW, CH = SW.CARD_W, SW.CARD_H
  local colour = c.own and SW.OWN or (SW.KIND_COLOUR[q.kind] or "#6a6a70")
  out[#out + 1] = string.format("item %s %s", num(c.x), num(c.y))
  if c.opacity ~= 1.0 then out[#out + 1] = "opacity " .. num(c.opacity) end
  if self.m11 < SW.DETAIL_ZOOM then
    -- (lit: brighter; its white edge - 3 px at any zoom - drawn over the picture, SM.overlay)
    local lit = c.picked or c.hit
    out[#out + 1] = string.format("fillrectf 0 3 %d %d %s", CW, CH - 6, qc(colour, lit and 255 or 170))
  else
    local edge = c.picked and SW.BY or (c.hit and "#e8e8e8" or "#3c3c42")
    out[#out + 1] = string.format("pen %s %d", qc(edge), c.picked and 2 or 1)
    out[#out + 1] = "brush " .. qc("#24242a")             -- (the one under the mouse: SM.overlay)
    out[#out + 1] = string.format("rectf 0 0 %d %d", CW, CH)
    out[#out + 1] = string.format("fillrectf 0 0 4 %d %s", CH, qc(colour))
    if SW.GAME_COLOUR[q.game] then
      out[#out + 1] = string.format("fillrectf %d 3 4 4 %s", CW - 7, qc(SW.GAME_COLOUR[q.game]))
    end
    local bold = q.kind == "main" or c.own
    out[#out + 1] = string.format("fontpx 11 %d 0", bold and 1 or 0)
    local level = P.T(q.level) and tostring(q.level) or ""
    local room = CW - 14 - (level ~= "" and 22 or 6)
    out[#out + 1] = "pen f0f0f2ff 1"
    local title = P.str(P.or_(q.title, q.name, q.id))
    out[#out + 1] = string.format("textelide 10 0 %d %d %d %d %s", room, CH, ALIGN_LEFT_V, room, txt(title))
    if level ~= "" then
      out[#out + 1] = "fontpx 10 0 0"
      out[#out + 1] = "pen 7c7c82ff 1"
      out[#out + 1] = string.format("textrect %d 0 22 %d %d %s", CW - 30, CH, ALIGN_RIGHT_V, level)
    end
  end
  if c.opacity ~= 1.0 then out[#out + 1] = "opacity 1" end
end

-- scene: the items alone, all of them, in the scene (the painter zooms and scrolls them when it draws: SM.picture)
function SM:commands(scene)
  local out = {}
  local x0, y0, x1, y1
  if scene then
    out[#out + 1] = "aa 1"
    out[#out + 1] = "view 1 0 0"
    x0, y0, x1, y1 = -math.huge, -math.huge, math.huge, math.huge
  else
    if self.device then out[#out + 1] = string.format("device %d %d %d %d", table.unpack(self.device)) end
    out[#out + 1] = "fill " .. qc(C.view_bg)
    out[#out + 1] = "aa 1"
    out[#out + 1] = string.format("view %s %s %s", num(self.m11), num(self.hval), num(self.vval))
    -- (what the view shows, in the scene: only the items there are painted - Qt asks the scene for those)
    x0, y0 = self:to_scene(0, 0)
    x1, y1 = self:to_scene(self.vw, self.vh)
  end
  local order = {}
  for _, it in ipairs(self.items) do if not it.hidden then order[#order + 1] = it end end
  table.sort(order, function(a, b) if a.z ~= b.z then return a.z < b.z end return a.seq < b.seq end)
  for _, it in ipairs(order) do
    if it.kind == "card" then
      if it.x <= x1 + 2 and it.x + SW.CARD_W >= x0 - 2 and it.y <= y1 + 2 and it.y + SW.CARD_H >= y0 - 2 then
        out[#out + 1] = "world"
        self:card_cmds(out, it)
      end
    elseif it.kind == "rect" then
      out[#out + 1] = "world"
      out[#out + 1] = "nopen"
      out[#out + 1] = "brush " .. it.fill
      out[#out + 1] = string.format("rectf %s %s %s %s", num(it.x), num(it.y), num(it.w), num(it.h))
    elseif it.kind == "line" then
      out[#out + 1] = "world"
      out[#out + 1] = string.format("pen %s %s%s", it.pen, num(it.width), it.dash and " 16 64 2" or "")
      out[#out + 1] = string.format("linef %s %s %s %s", num(it.x0), num(it.y0), num(it.x1), num(it.y1))
    elseif it.kind == "path" then
      out[#out + 1] = "world"
      out[#out + 1] = string.format("pen %s %s", it.pen, num(it.width))
      out[#out + 1] = "nobrush"
      local p = it.pts
      out[#out + 1] = string.format("path M %s %s L %s %s L %s %s L %s %s", num(p[1]), num(p[2]), num(p[3]), num(p[4]),
                                    num(p[5]), num(p[6]), num(p[7]), num(p[8]))
    end
  end
  if not scene then self:foreground(out) end
  return out
end

-- drawForeground: the lane names at the left, the acts and the level ruler at the top (viewport coordinates)
function SM:foreground(out)
  if #self.bands == 0 then return end
  local LW, RH, PX = SW.LABEL_W, SW.RULER_H, SW.PX
  local vw, vh = self.vw, self.vh
  out[#out + 1] = "view 1 0 0"
  out[#out + 1] = "fontpx 12 1 0"
  for _, b in ipairs(self.bands) do
    local name, by, h, n = b[1], b[2], b[3], b[4]
    local _, top = self:from_scene(0, by)
    local _, bottom = self:from_scene(0, by + h)
    if not (bottom < RH or top > vh) then
      local y = math.max(top, RH)
      local tall = bottom - y >= 34
      out[#out + 1] = string.format("fillrectf 0 %d %d %d %s", y, LW - 10,
                                    tall and 34 or math.min(18, math.max(bottom - y, 0)), "141417e6")
      out[#out + 1] = "fontpx 12 1 0"
      out[#out + 1] = "pen b8b8bcff 1"
      out[#out + 1] = string.format("textrect 8 %d %d 16 %d %s", y + 2, LW - 18, ALIGN_LEFT_V, txt(name))
      if tall then
        out[#out + 1] = "fontpx 10 0 0"
        out[#out + 1] = "pen 76767cff 1"
        out[#out + 1] = string.format("textrect 8 %d %d 14 %d %d quest%s", y + 17, LW - 18, ALIGN_LEFT_V, n,
                                      n ~= 1 and "s" or "")
      end
    end
  end
  out[#out + 1] = string.format("fillrectf 0 0 %d %d %s", vw, RH - 2, "141417f0")
  out[#out + 1] = "fontpx 11 1 0"
  local xs = {}
  for _, a in ipairs(self.acts) do
    local x = self:from_scene(LW + a[2] * PX - 6, 0)
    xs[#xs + 1] = {a[1], x}
  end
  for k, a in ipairs(xs) do
    local name, x = a[1], a[2]
    local r = ST.is_expansion(name) and 1 or 0
    local later
    for j = k + 1, #xs do
      if (ST.is_expansion(xs[j][1]) and 1 or 0) == r and xs[j][2] > x then later = xs[j][2] break end
    end
    local e = later or vw
    if e > 0 then
      local y = 3 + r * 13
      local bx = math.max(x, 0)
      local bw = math.max(2, e - bx - 2)
      local fill = r == 0 and "d9a44128" or (name == "Hearts of Stone" and "8e5bd12d" or "a8324a32")
      out[#out + 1] = string.format("fillrectf %d %d %d 12 %s", bx, y, bw, fill)
      out[#out + 1] = "save"
      out[#out + 1] = string.format("cliprect %d %d %d 12", bx, y, bw)
      out[#out + 1] = "pen " .. (r == 0 and "e0c890ff" or "d8c8e8ff") .. " 1"
      out[#out + 1] = string.format("textrect %d %d 200 14 %d %s", bx + 4, y - 1, ALIGN_LEFT_V, txt(name))
      out[#out + 1] = "restore"
    end
  end
  out[#out + 1] = "fontpx 10 0 0"
  out[#out + 1] = "pen 8c8c90ff 1"
  local sx0 = self:to_scene(0, 0)
  local sx1 = self:to_scene(vw, 0)
  local lvl0 = math.floor(math.max(0, (sx0 - LW) // PX))
  local lvl1 = math.floor((sx1 - LW) // PX) + 1
  local m = self.m11
  local step = m >= 0.6 and 1 or (m >= 0.3 and 2 or 5)
  local lvl = lvl0 - lvl0 % step
  while lvl <= lvl1 do
    local x = self:from_scene(LW + lvl * PX, 0)
    out[#out + 1] = string.format("textrect %d 30 40 14 %d %d", x - 20, ALIGN_CENTER, lvl)
    lvl = lvl + step
  end
  out[#out + 1] = string.format("fillrectf 0 30 46 14 %s", "141417f0")
  out[#out + 1] = string.format("textrect 8 30 40 14 %d level", ALIGN_LEFT_V)
end

function SM:picture()
  if not require("conjunction.ui.graph_view").QT_PAINT then
    -- (the game draws them, ui/painter.lua: the scene compiled once - every card, in the scene - and zoomed and
    -- scrolled as it is drawn, as the quest graph's; made again only when its cards change: one hovered, a pick, a
    -- search, the quests shown (SM.ver), the detail the zoom shows. 14.11.: compiled for each move of the view, the
    -- 394 cards took 33 ms a frame. What stays in view - the lanes' names, the acts, the ruler - in its own steps)
    local PA = require("conjunction.ui.painter")
    -- (14.11.: with the card under the mouse and the zoom's edge width in it, each card the mouse crossed and each
    -- turn of the wheel compiled the scene anew - 250 ms each, the last stutters; those are drawn over it now)
    local detail = self.m11 >= SW.DETAIL_ZOOM
    local skey = table.concat({self.ver or 0, tostring(self.current), detail and "d" or "z"}, "|")
    if not self.scene_steps or skey ~= self.scene_key then
      self.scene_steps, self.scene_key = PA.compile(self:commands(true)), skey
    end
    local fkey = table.concat({num(self.m11), num(self.hval), num(self.vval), self.vw, self.vh}, "|")
    if not self.fg_steps or fkey ~= self.fg_key then
      local out = {}
      self:foreground(out)
      self.fg_steps, self.fg_key = PA.compile(out), fkey
    end
    self.img = {scene = self.scene_steps, fg = self.fg_steps}
    return self.img
  end
  local list = self:commands()
  local cmds = table.concat(list, "\n")
  if self.img and cmds == self.img_key then return self.img end
  local ok = pcall(w3.plugin.cj_qt_paint, self.file, tostring(self.vw), tostring(self.vh), cmds, "fast")
  if ok then
    local id, iw, ih = w3.ui.image_load(self.file)
    if id then
      if self.img and self.img[1] then w3.ui.image_free(self.img[1]) end
      self.img = {id, iw, ih}
    end
  end
  self.img_key = cmds
  return self.img
end

-- what changes with the mouse and the zoom, drawn over the compiled scene each frame (SM.picture): the card under the
-- mouse a little lighter; zoomed out, the lit ones' white edge (3 px whatever the zoom)
function SM:overlay(vx, vy)
  local function rect_of(c, top, bottom)
    local x1, y1 = self:from_scene_f(c.x, c.y + top)
    local x2, y2 = self:from_scene_f(c.x + SW.CARD_W, c.y + SW.CARD_H - bottom)
    if x2 < 0 or y2 < 0 or x1 > self.vw or y1 > self.vh then return nil end
    return vx + x1, vy + y1, x2 - x1, y2 - y1
  end
  D.clip(vx, vy, self.vw, self.vh, function()
    if self.m11 >= SW.DETAIL_ZOOM then
      if self.hot then
        local x, y, w, h = rect_of(self.hot, 0, 0)
        if x then D.fill(x + 4 * self.m11, y + self.m11, w - 5 * self.m11, h - 2 * self.m11, 0xffffff10) end
      end
    else
      for _, c in ipairs(self.card_list or {}) do
        if c.picked or c.hit then
          local x, y, w, h = rect_of(c, 3, 3)
          if x then D.rect(x, y, w, h, 0xffffffff, 3) end
        end
      end
    end
  end)
end

-- the card under a point of the scene (the topmost)
function SM:card_at(x, y)
  for k = #self.card_list, 1, -1 do
    local c = self.card_list[k]
    if x >= c.x and x < c.x + SW.CARD_W and y >= c.y and y < c.y + SW.CARD_H then return c end
  end
  return nil
end

-- one frame in r (the view with its frame): the size, the mouse, the picture, the bars
function SM:frame(r, hovered)
  self:resize(math.floor(r.w), math.floor(r.h))
  local vx, vy = r.x + 1, r.y + 1
  local mx, my, wheel = w3.ui.mouse()
  local ax, ay = mx - vx, my - vy
  local inside = hovered and ax >= 0 and ay >= 0 and ax < self.vw and ay < self.vh
  local sx, sy = self:to_scene(ax, ay)
  self.hot = inside and self:card_at(sx, sy) or nil
  if inside and wheel and wheel ~= 0 and not self.press then
    local k = wheel > 0 and 1.15 or 1 / 1.15
    local s = self.m11 * k
    if s >= 0.08 and s <= 2.5 then self:scale(k, {math.floor(ax), math.floor(ay)}) end
  end
  if inside and w3.ui.mouse_clicked(1) then
    local c = self:card_at(sx, sy)
    if c then
      self:pick(c)
    else
      self.press = {ax, ay, last = {ax, ay}}       -- (ScrollHandDrag: the map follows the mouse)
    end
  end
  if self.press then
    if w3.ui.mouse_down(1) then
      local dx, dy = ax - self.press.last[1], ay - self.press.last[2]
      self.press.last = {ax, ay}
      if dx ~= 0 then self:set_h(self.hval - dx) end
      if dy ~= 0 then self:set_v(self.vval - dy) end
      self:update_center()
    else
      local p = self.press
      self.press = nil
      if math.abs(ax - p[1]) + math.abs(ay - p[2]) < 4 and self.current then self:pick(nil) end
    end
  end
  if self.current and hovered and w3.ui.pressed("Escape") then self:pick(nil) end
  if self.hot then
    local q = self.hot.q
    local kind = self.hot.own and "Your quest" or (SW.CARD_KIND[q.kind] or "Quest")
    local level = P.T(q.level) and (", level " .. tostring(q.level)) or ""
    CT.tip("story.card." .. q.id, {"", P.str(P.or_(q.title, q.id)) .. "\n" .. kind .. level})
  end
  Q.frame(r.x, r.y, r.w, r.h, C.view_bg, C.view_edge)   -- (the view's background under its bars too)
  local img = self:picture()
  if img and img.scene then
    local PA = require("conjunction.ui.painter")
    PA.draw(img.scene, vx, vy, self.vw, self.vh, {self.m11, self.hval, self.vval})
    self:overlay(vx, vy)
    PA.draw(img.fg, vx, vy, self.vw, self.vh)
  elseif img and img.steps then
    require("conjunction.ui.painter").draw(img.steps, vx, vy, self.vw, self.vh)
  elseif img then
    D.image(img[1], vx, vy, img[2], img[3])
  end
  -- the search's quests: their edges blink (MaximdeWinter 14.11.: lit, they did not stand out enough) - drawn over the
  -- picture each frame, the picture itself stays as it was
  if self.any_hit then
    local t = w3.time and w3.time() or os.clock()
    local a = math.floor(90 + 165 * (0.5 + 0.5 * math.sin(t * 7)))
    local edge = 0xffffff00 | a
    local glow = 0xffffff00 | (a // 4)
    D.clip(vx, vy, self.vw, self.vh, function()
      for _, c in ipairs(self.card_list or {}) do
        if c.hit then
          local x1, y1 = self:from_scene_f(c.x, c.y)
          local x2, y2 = self:from_scene_f(c.x + SW.CARD_W, c.y + SW.CARD_H)
          if x2 > 0 and y2 > 0 and x1 < self.vw and y1 < self.vh then
            D.rect(vx + x1 - 3, vy + y1 - 3, x2 - x1 + 6, y2 - y1 + 6, glow, 3)
            D.rect(vx + x1 - 1, vy + y1 - 1, x2 - x1 + 2, y2 - y1 + 2, edge, 2)
          end
        end
      end
    end)
  end
  local AG = package.loaded["conjunction.agent"]        -- (the quests in view, for the agent: by their names)
  if AG then
    for _, c in ipairs(self.card_list or {}) do
      local x1, y1 = self:from_scene(c.x, c.y)
      local x2, y2 = self:from_scene(c.x + SW.CARD_W, c.y + SW.CARD_H)
      if x2 > 0 and y2 > 0 and x1 < self.vw and y1 < self.vh then
        local q = c.q or {}
        AG.area("story." .. tostring(q.id) .. (c.own and "#own" or ""), vx + x1, vy + y1, x2 - x1, y2 - y1,
                q.title or q.name or q.id)
      end
    end
  end
  -- the bars (the theme's), the corner between them
  local hit = function(id, rr) return CT.hit_box(id, rr) end
  if self.vbar_on then
    local b = self.vbar
    b.page = self.vpage
    IV.range(b, self.vmax - self.vmin)
    IV.set(b, self.vval - self.vmin)
    SBAR.draw(self.bar_state, "story.vbar", b, {x = vx + self.vw, y = vy, w = 10, h = self.vh}, "v", hit,
              function(bb) self:set_v(self.vmin + bb.value) self:update_center() end)
  end
  if self.hbar_on then
    local b = self.hbar
    b.page = self.hpage
    IV.range(b, self.hmax - self.hmin)
    IV.set(b, self.hval - self.hmin)
    SBAR.draw(self.bar_state, "story.hbar", b, {x = vx, y = vy + self.vh, w = self.vw, h = 10}, "h", hit,
              function(bb) self:set_h(self.hmin + bb.value) self:update_center() end)
  end
end

function SM:free()
  if self.img and self.img[1] then w3.ui.image_free(self.img[1]) end
  self.img, self.img_key = nil, nil
end

-- ===================================================================================================================
-- the window's body (story_view.StoryWindow)
SW.ROW_W = 1100            -- px the top row needs (the search, the kinds, the games, Fit, World only)
function SW.new(ed, win)
  local self = setmetatable({ed = ed, win = win, quests = {}, visible = {}, search = "", picked = nil}, SW)
  -- (in Qt the row's layout kept the window that wide; narrower, its chips ran out of the window at the left)
  if win and win.rect and win.mover then
    local W = (ed and ed.panel and ed.panel.W) or 1920
    local want = math.min(SW.ROW_W, W - 16)
    if win.rect.w < want then
      win.rect.w = want
      if win.rect.x + want > W - 8 then win.rect.x = math.max(8, W - 8 - want) end
    end
    win.min_w = math.max(win.min_w or 360, want)
    win.mover.min_w = win.min_w
  end
  local CFG = require("conjunction.config")
  local kept = CFG.load().story_shown
  self.shown = {}
  for k, v in pairs(SW.SHOWN) do self.shown[k] = v end
  if type(kept) == "table" then for k, v in pairs(kept) do self.shown[k] = v end end
  self.map = SM.new()
  self.map.on_pick = function(q) self:show_quest(q) end
  self.data = ST.load()
  -- not built yet: the game's quests read once (story.build - story_build.lua, a little each frame), then shown
  if self.data == nil and ed and ed.job then
    ed:job(function()
      require("conjunction.story_build").build(function() end)
    end, function(ok, err)
      if not ok then print("[story] " .. tostring(err)) return end
      self.data = ST.load()
      self:refresh()
      self:show_quest(nil)
    end)
  end
  self:refresh()
  self:show_quest(nil)
  return self
end

-- the picked quest's graph: the game's own quest file, every block (vanilla_window.lua)
function SW:open_graph()
  local card = self.map.current
  local path = card and card.q.file or nil
  local panel = self.ed.panel
  if not path or not panel then return nil end
  local VW = require("conjunction.ui.vanilla_window")
  local w = panel:open_win("Quest graph", "Quest graph", "quest graph", function(win) return VW.new(self.ed, win, path) end)
  if w.body and #w.body.trail > 0 and w.body.trail[1][1] ~= path then w.body:open_path(path) end
  return w
end

-- the project's own quest, where it hangs (StoryWindow.own_quests)
function SW:own_quests(quests)
  local project = self.ed.project
  local meta = project and project.meta
  local q = meta and P.get(meta, "quest")
  if not P.T(q) then return {} end
  local hook = P.or_(P.get(q, "after_game"), {})
  local gq = P.or_(P.get(q, "game_quest"), {})
  local by_id = {}
  for _, x in ipairs(quests) do by_id[x.id] = x end
  local after = by_id[P.get(gq, "id")] or by_id[P.get(hook, "quest")]
  if not after and P.get(hook, "fact") ~= nil then
    for _, x in ipairs(quests) do
      for _, f in ipairs(x.sets or {}) do if f == hook.fact then after = x break end end
      if after then break end
    end
  end
  local x = after and (after.x + (P.get(gq, "when") == "with" and 0.0 or 0.6)) or 0.5
  local pid = project:id()                        -- (a method of the editor's project, Python's attribute)
  local title = P.str(P.or_(P.get(q, "title"), P.get(meta, "name"), pid))
  local mine = {id = pid, title = title, kind = "own", level = P.get(q, "level"),
                hooks = after and {after.id} or {}, game = "", by = {}, unlocks = {}, hook_fact = P.get(hook, "fact"),
                hook_when = P.get(gq, "when"), own = true}
  return {{mine, x}}
end

function SW:refresh(save)
  if save then
    local CFG = require("conjunction.config")
    local cfg = CFG.load()
    cfg.story_shown = self.shown
    CFG.save(cfg)
  end
  if self.data == nil then return end
  self.quests = ST.placed(self.data)
  self.counts = {}
  for _, q in ipairs(self.quests) do
    self.counts[q.kind] = (self.counts[q.kind] or 0) + 1
    local g = ST.game_key(q)
    self.counts[g] = (self.counts[g] or 0) + 1
  end
  self.visible = {}
  for _, q in ipairs(self.quests) do
    local k_on, g_on = self.shown[q.kind], self.shown[ST.game_key(q)]
    if k_on ~= false and g_on ~= false then self.visible[#self.visible + 1] = q end
  end
  local m = self.map
  local picked = m.current and m.current.q.id or nil
  m:show_quests(self.visible, self:own_quests(self.quests), ST.acts(self.quests))
  if self.search ~= "" then m:find(self.search) end
  if picked and m.cards[picked] then m:pick(m.cards[picked]) end
end

-- the details at the right (StoryWindow.show_quest): rich text as the app's QLabel has it
function SW:show_quest(q)
  self.picked = q
  self:fill_starts(q)
  local html
  if q == nil then
    html = string.format(
      "<b style='color:#f0f0f2;font-size:14px'>The story</b><br>%d quests shown of %d.<br><br>Click a quest: everything "
      .. "it waits for lights up in <span style='color:%s'>gold</span>, everything that waits for it in <span "
      .. "style='color:%s'>blue</span>.<br><br>Then pick the fact below and <b>Start my quest after this</b> - your "
      .. "quest begins once that quest has set it.", #self.visible, #self.quests, SW.BY, SW.UNLOCKS)
    self.hook_ok = false
  else
    html = self:detail_html(q)
    self.hook_ok = self.ed.project ~= nil and not q.own
  end
  self:set_detail(html)
end

-- the starts for the quest: the game's own of it, a jump of ours (its world, its act, the facts), the game's story
-- starts (StoryWindow.show_quest); Play from here only with the game there
function SW:fill_starts(q)
  local SE = require("conjunction.sessions")
  local ok, defs = pcall(SE.definitions)
  if not ok then defs = {} end
  local own = q ~= nil and not q.own
  local out = {}
  if own then
    for _, d in ipairs(SE.for_quest(q, defs)) do
      out[#out + 1] = {d.name .. " · " .. SE.world_name(d.world), {"def", d.path}}
    end
    local by_id = {}
    for _, x in ipairs(self.quests) do by_id[x.id] = x end
    local world, entry, facts = SE.plan(q, by_id)
    out[#out + 1] = {"Jump here · " .. SE.world_name(world) .. (entry and (" · " .. entry) or ""),
                     {"jump", {world, entry, facts}}}
    for _, d in ipairs(SE.story_starts(defs)) do
      out[#out + 1] = {d.name .. " · " .. SE.world_name(d.world), {"def", d.path}}
    end
  end
  self.starts, self.start_i = out, 1
  self.play_ok = #out > 0 and self.ed.exec ~= nil
end

-- a fresh session from the start picked: no save loaded; a quick save first while the game is not one of the
-- editor's sessions already (StoryWindow.play_from_here)
function SW:play_from_here()
  local pick = self.starts and self.starts[self.start_i]
  local ed = self.ed
  if not pick or not ed.exec then return nil end
  local SE = require("conjunction.sessions")
  if not ed.in_session then ed:exec("cj_quicksave()") end
  local kind, what = pick[2][1], pick[2][2]
  if kind == "def" then SE.start(ed, what) else SE.jump(ed, what[1], what[2], what[3]) end
  ed.in_session = pick[2]
  return pick[2]
end

local function esc(s) return P.str(s) end
function SW:detail_html(q)
  local quests = {}
  for _, x in ipairs(self.quests) do quests[x.id] = x end
  local function name(qid)
    local x = quests[qid]
    if x then return P.str(x.title) end
    return qid:match("([^\\]*)$") or qid
  end
  local function link(qid, colour, why)
    local hidden = self.map.cards[qid] and "" or " <span style='color:#6c6c70'>(hidden)</span>"
    local reason = (why and why ~= "") and ("<br>&nbsp; &nbsp; <span style='color:#7c7c80'>" .. why .. "</span>") or ""
    return string.format("<br>&nbsp; <span style='color:%s'>■</span> <a href='%s' style='color:#e8e8ea;"
                         .. "text-decoration:none'>%s</a>%s%s", colour, qid, name(qid), hidden, reason)
  end
  if q.own then
    local after = (q.hooks and #q.hooks > 0) and name(q.hooks[1]) or "the start of the game"
    local how = (q.hook_when == "with" and q.hooks and #q.hooks > 0) and "with" or "after"
    return string.format("<b style='color:%s;font-size:14px'>%s</b><br>Your quest.<br><br>Starts %s: <b>%s</b>", SW.OWN,
                         esc(q.title), how, after) .. (P.T(q.hook_fact) and ("<br>(fact " .. q.hook_fact .. ")") or "")
  end
  local facts = table.concat(P.list(q.gates), ", ")
  local starts = {}
  if P.T(q.areas) then
    local a = {}
    for _, x in ipairs(q.areas) do a[#a + 1] = (x:gsub("AN_", ""):gsub("_", " ")) end
    starts[#starts + 1] = "in " .. table.concat(a, ", ")
  end
  if P.T(q.items) then
    local a = {}
    for k = 1, math.min(4, #q.items) do a[#a + 1] = q.items[k] end
    starts[#starts + 1] = "with " .. table.concat(a, ", ")
  end
  if P.T(q.boards) then starts[#starts + 1] = "after a notice board" end
  if P.T(q.min_level) then starts[#starts + 1] = "from level " .. tostring(q.min_level) end
  local by = {}
  for _, b in ipairs(q.by or {}) do by[#by + 1] = link(b, SW.BY, P.str((q.why or {})[b] or "")) end
  local by_s = #by > 0 and table.concat(by) or "<br>&nbsp; no other quest - open once its region is"
  local un = {}
  for _, u in ipairs(q.unlocks or {}) do un[#un + 1] = link(u, SW.UNLOCKS) end
  local un_s = #un > 0 and table.concat(un) or "<br>&nbsp; no quest known"
  local region = SW.REGION[q.world] or ""
  local parts = {}
  for _, x in ipairs({SW.CARD_KIND[q.kind] or "Quest", P.T(q.level) and ("level " .. tostring(q.level)) or "",
                      P.str(q.act or ""), region, q.game ~= "The Witcher 3" and P.str(q.game or "") or ""}) do
    if x ~= "" then parts[#parts + 1] = x end
  end
  return string.format("<b style='color:#f0f0f2;font-size:14px'>%s</b><br>%s<br><span style='color:#6c6c70'>%s · %s"
                       .. "</span><br><br><b>Waits for</b>%s", P.str(q.title), table.concat(parts, " · "),
                       P.str(q.code or ""), P.str(q.file), by_s)
         .. (#starts > 0 and ("<br>&nbsp; <span style='color:#9a9aa0'>starts " .. table.concat(starts, "; ") .. "</span>") or "")
         .. (facts ~= "" and ("<br><span style='color:#6c6c70'>facts: " .. facts .. "</span>") or "")
         .. "<br><br><b>Unlocks</b>" .. un_s
end

local seq = 0
function SW:set_detail(html)
  if html == self.detail_html_now then return end
  self.detail_html_now = html
  seq = seq + 1
  self.detail_src = string.format("%s\\cj_story_detail_%d.html", os.getenv("TEMP") or ".", seq)
  local f = io.open(self.detail_src, "wb")
  if f then
    f:write(html)
    f:close()
  end
  for _, pic in pairs(self.detail_pics or {}) do if pic then w3.ui.image_free(pic.id) end end
  self.detail_pics = {}
  if self.dbar_h then IV.set(self.dbar_h, 0) IV.set(self.dbar_v, 0) end
end

-- the QLabel's text: a document with no margin, 2 px in (its indent: half an 'x', the frame its padding gives it)
local DETAIL_PAD, DETAIL_INDENT = 6, 2
-- (kept per width: detail_area asks for two each frame - the room's, then the room beside its bar - and with one kept
-- both were made anew every frame, 11 ms of a 37 ms frame, MaximdeWinter 14.11.: 21 fps; set_detail frees them)
function SW:detail_picture(width)
  self.detail_pics = self.detail_pics or {}
  local got = self.detail_pics[width]
  if got ~= nil then return got or nil end
  local n = 0
  for _ in pairs(self.detail_pics) do n = n + 1 end
  if n >= 4 then                                -- (the window resized: the widths it had go)
    for _, pic in pairs(self.detail_pics) do if pic then w3.ui.image_free(pic.id) end end
    self.detail_pics = {}
  end
  local out = string.format("%s\\cj_story_detail_%d_%d.png", os.getenv("TEMP") or ".", seq, width)
  local ok, res = pcall(w3.plugin.cj_qt_rich, out, tostring(width), "html", self.detail_src, "12", qc(C.detail),
                        qc(C.side_bg), string.format("%08x", require("conjunction.ui.richtext").LINK), "0")
  local pic = false
  if ok then
    local id, w, h = w3.ui.image_load(out)
    if id then pic = {id = id, w = w, h = h, ideal = tonumber(tostring(res):match("\t(%d+)$")) or w} end
  end
  self.detail_pics[width] = pic
  return pic or nil
end

-- a click in the details: the quest whose link is there (linkActivated -> pick_id)
function SW:detail_link(x, y, width)
  local ok, href = pcall(w3.plugin.cj_qt_rich, "-", tostring(width), "html", self.detail_src, "12", qc(C.detail),
                         qc(C.side_bg), "000000ff", "0", "anchor", tostring(x), tostring(y))
  if ok and href and href ~= "" then return href end
  return nil
end

-- the details in their QScrollArea (resizable, the bars as needed): the label as wide as the room or its longest word
-- (a QLabel wraps at words only), as high as its text at that width; its text 2 px in from the padding
local EXTRA = 2 * DETAIL_PAD + DETAIL_INDENT
local MIN_EXTRA = EXTRA + 3        -- (its minimumSizeHint: the text's ideal width and 17 - measured, 411 -> 428)
function SW:detail_area(sr)
  self.dbar_h = self.dbar_h or IV.bar(1, 0, 0)
  self.dbar_v = self.dbar_v or IV.bar(1, 0, 0)
  self.dbar_state = self.dbar_state or {}
  local vw, vh = sr.w, sr.h
  local pic = self:detail_picture(vw - EXTRA)
  if not pic then return end
  local lw = math.max(vw, pic.ideal + MIN_EXTRA)
  local hbar = lw > vw
  if hbar then vh = vh - 10 end
  local lh = pic.h + EXTRA
  local vbar = lh > vh
  if vbar then
    vw = vw - 10
    if not hbar and pic.ideal + MIN_EXTRA > vw then
      hbar = true
      vh = vh - 10
    end
    lw = math.max(vw, pic.ideal + MIN_EXTRA)
    pic = self:detail_picture(lw - EXTRA)
    lh = pic.h + EXTRA
  elseif hbar then
    pic = self:detail_picture(lw - EXTRA)
  end
  local bh, bv = self.dbar_h, self.dbar_v
  bh.page, bv.page = vw, vh
  IV.range(bh, math.max(0, lw - vw))
  IV.range(bv, math.max(0, lh - vh))
  local area = {x = sr.x, y = sr.y, w = vw, h = vh}
  local mx, my, wheel = w3.ui.mouse()
  if CT.over(area) and wheel and wheel ~= 0 then IV.set(bv, bv.value - math.floor(wheel * 3 * 20 + 0.5)) end
  local px, py = sr.x + DETAIL_PAD + DETAIL_INDENT - bh.value, sr.y + DETAIL_PAD + DETAIL_INDENT - bv.value
  D.clip(area.x, area.y, area.w, area.h, function() D.image(pic.id, px, py, pic.w, pic.h) end)
  if CT.over(area) and w3.ui.mouse_clicked(1) then      -- (linkActivated: that quest picked)
    local href = self:detail_link(mx - px, my - py, lw - EXTRA)
    if href then self.map:pick_id(href) end
  end
  local hit = function(id, rr) return CT.hit_box(id, rr) end
  if vbar then SBAR.draw(self.dbar_state, "story.dvbar", bv, {x = sr.x + vw, y = sr.y, w = 10, h = vh}, "v", hit) end
  if hbar then SBAR.draw(self.dbar_state, "story.dhbar", bh, {x = sr.x, y = sr.y + vh, w = vw, h = 10}, "h", hit) end
end

-- --- the controls
local function chip_size(text)
  return Q.hint_w(text, 12) + 2 * Q.text_w(" ", 12) + 16 + 2 + 3, Q.line_h(12) + 6 + 2 + 3
end

function SW:chips()
  local out = {}
  for _, k in ipairs(SW.KIND_NAME) do out[#out + 1] = {k[1], k[2]} end
  out[#out + 1] = false
  for _, k in ipairs(SW.GAME_FILTER) do out[#out + 1] = {k[1], k[2]} end
  return out
end

function SW:frame(r)
  local x, y = r.x, r.y
  local eh = CT.edit_h()
  -- the top row: the search (the rest of the room), 8, the kinds, 10, the games, 10, Fit, World only (4 apart)
  local items = {}
  local fixed = 0
  local function add(kind, w, h, data)
    items[#items + 1] = {kind = kind, w = w, h = h, data = data}
    fixed = fixed + w
  end
  add("space", 8)
  local first = true
  for _, c in ipairs(self:chips()) do
    if c == false then add("space", 10)
    else
      local text = c[2] .. "  " .. tostring((self.counts or {})[c[1]] or 0)
      local w, h = chip_size(text)
      add("chip", w, h, {key = c[1], text = text})
    end
    first = false
  end
  add("space", 10)
  local fw, fh = Q.button_size("Fit")
  add("fit", fw, fh)
  local ww, wh = Q.menu_button_size("World only ▾")
  add("worlds", ww, wh)
  local nonempty = 1
  for _, it in ipairs(items) do if it.kind ~= "space" then nonempty = nonempty + 1 end end
  local sw = r.w - fixed - (nonempty - 1) * 4
  local style = self.ed.panel and self.ed.panel.EDIT_STYLE or nil
  local _, s = CT.edit("story.search", x, y, sw, self.search, {placeholder = "Find a quest", tip = "story.search",
                                                               style = style})
  if s ~= self.search then
    self.search = s
    self.map:find(s)
  end
  local cx = x + sw
  for _, it in ipairs(items) do
    if it.kind == "space" then cx = cx + it.w
    else
      cx = cx + 4
      local ry = y + (eh - it.h) // 2
      local box = {x = cx, y = ry, w = it.w, h = it.h}
      if it.kind == "chip" then
        local key = it.data.key
        local on = self.shown[key] ~= false
        local clicked, hovered = CT.hit_box("story.chip." .. key, box)
        local bg, edge, fg = C.chip_bg, C.chip_edge, C.chip_fg
        if on then bg, edge, fg = C.chip_on_bg, C.chip_on_edge, C.chip_on_fg end
        if hovered then edge = C.chip_hover end
        Q.frame(box.x, box.y, box.w, box.h, bg, edge)
        local tw = Q.text_w(it.data.text, 12)
        Q.text(box.x + (box.w - tw) // 2, box.y + Q.vcenter(box.h, Q.line_h(12)), fg, it.data.text, 12, false, bg)
        if hovered then CT.tip("story.chip." .. key, KIND_KEYS[key] and "story.chip_kind" or "story.chip_game") end
        if clicked then
          self.shown[key] = not on
          self:refresh(true)
        end
      elseif it.kind == "fit" then
        if CT.button("story.fit", box.x, box.y, "Fit", {w = box.w, h = box.h, tip = "story.fit",
                                                       fg = T.BUTTON_TEXT}) then self.map:fit() end
      else
        self:worlds_button(box)
      end
      cx = cx + it.w
    end
  end
  -- the body: the map (the rest), 6, the side (its widest row: the starts and Play)
  local by = y + eh + 6
  local bh = r.y + r.h - by
  local side_w = math.max(310, 200 + 6 + 106)
  local map_w = r.w - 6 - side_w
  self.map:frame({x = x, y = by, w = map_w, h = bh}, CT.over({x = x, y = by, w = map_w, h = bh}))
  self:side({x = x + map_w + 6, y = by, w = side_w, h = bh})
end

function SW:worlds_button(box)
  local clicked, hovered, held = CT.hit_box("story.worlds", box)
  Q.menu_button(box.x, box.y, box.w, box.h, "World only ▾", {hover = hovered, pressed = held and hovered,
                                                             fg = T.BUTTON_TEXT})
  if hovered then CT.tip("story.worlds", "story.world_only") end
  if clicked then
    local IM = require("conjunction.ui.inline_menu")
    if IM.is_open("story.worlds") then IM.close() else
      local list = {}
      for _, w in ipairs(SW.WORLDS) do
        list[#list + 1] = {text = w[2], action = function() self:world_only(w[1]) end}
      end
      IM.open("story.worlds", box, list, self.win and self.win.rect or box)
    end
  end
end

-- sessions.WORLD_DEFS in their order and sessions.world_name
SW.WORLDS = {}
for _, w in ipairs(require("conjunction.sessions").WORLDS) do
  SW.WORLDS[#SW.WORLDS + 1] = {w, require("conjunction.sessions").world_name("levels\\" .. w .. "\\x")}
end

-- a fresh session in a world, no story at all (StoryWindow.world_only: the game's world jump of sessions.py)
function SW:world_only(world)
  local ed = self.ed
  if not ed.exec then return nil end
  if not ed.in_session then ed:exec("cj_quicksave()") end
  require("conjunction.sessions").jump(ed, world)
  ed.in_session = {"jump", {world, nil, {}}}
  return world
end

function SW:side(r)
  local eh = CT.edit_h()
  local _, bh = Q.button_size("Play from here")
  local hook_h = Q.line_h(12, true) + 12
  -- (Open graph: the game's quests, shown with the experimental features only - the update for vanilla editing)
  local graph = require("conjunction.features").experimental()
  local gw, gh = Q.button_size("Open graph")
  local scroll_h = r.h - 6 - eh - 6 - hook_h - 6 - hook_h - (graph and (gh + 6) or 0)
  local sr = {x = r.x, y = r.y, w = 310, h = scroll_h}
  D.fill(sr.x, sr.y, sr.w, sr.h, C.side_bg)
  if self.detail_src then self:detail_area(sr) end
  local ry = sr.y + sr.h + 6
  if graph then
    if CT.button("story.graph", r.x, ry, "Open graph", {w = 310, h = gh, tip = "story.graph", fg = T.BUTTON_TEXT}) then
      self:open_graph()
    end
    ry = ry + gh + 6
  end
  local texts = {}
  for k, st in ipairs(self.starts or {}) do texts[k] = st[1] end
  local changed, i = CT.combo("story.starts", r.x, ry, 200, texts, #texts > 0 and self.start_i or 0,
                              self.win and self.win.rect or r, {h = eh, disabled = #texts == 0, tip = "story.starts",
                                                                fg = T.BRIGHT})
  if changed then self.start_i = i end
  if CT.button("story.play", r.x + 200 + 6, ry + (eh - bh) // 2, "Play from here",
               {w = 106, h = bh, disabled = not self.play_ok, tip = "story.play", fg = T.BUTTON_TEXT}) then
    self:play_from_here()
  end
  local hy = ry + eh + 6
  self:hook_button("story.hook_with", {x = r.x, y = hy, w = 310, h = hook_h}, "Start my quest with this", "with")
  self:hook_button("story.hook", {x = r.x, y = hy + hook_h + 6, w = 310, h = hook_h}, "Start my quest after this",
                   "after")
end

-- QPushButton#hook: rgba(92,184,92,40), a #5cb85c border, bold 12 px white
function SW:hook_button(id, box, text, when)
  local clicked, hovered = CT.hit_box(id, box)
  Q.frame(box.x, box.y, box.w, box.h, C.hook_bg, C.hook_edge)
  local tw = Q.text_w(text, 12, true)
  Q.text(box.x + (box.w - tw) // 2, box.y + Q.vcenter(box.h, Q.line_h(12, true)), T.WHITE, text, 12, true, C.hook_bg)
  if hovered then CT.tip(id, when == "with" and "story.hook_with" or "story.hook") end
  if clicked and self.hook_ok then self:hook_game(when) end
end

-- the project's quest starts with the picked quest of the game or after it (StoryWindow.hook_game); the game's
-- journal is read once, as a job (story.journal_entry)
function SW:hook_game(when)
  local card = self.map.current
  local project = self.ed.project
  if card == nil or project == nil or card.own then return end
  local entry = ST.journal_entry(card.q.id, self.ed)
  if entry == nil then
    self:set_detail(self.detail_html_now .. "<br><br><span style='color:#e57a7a'>The game's journal is being read (once, "
                    .. "about a minute). Try again in a moment.</span>")
    return
  end
  local q = project.meta.quest
  if q == nil or q == Y.null then
    q = Y.map()
    project.meta.quest = q
  end
  for _, k in ipairs({"after", "after_quest", "after_game", "inside_game"}) do Y.remove(q, k) end
  local gq = Y.map()
  for k, v in pairs(entry) do gq[k] = v end
  gq.when, gq.id, gq.title = when, card.q.id, P.str(card.q.title or "")
  q.game_quest = gq
  if project.save_meta then project:save_meta() end
  self:refresh()
  local own = self.map.cards[project:id() .. "#own"]
  if own then
    self.map:pick(own)
    self.map:center_on(own.x + SW.CARD_W / 2, own.y + SW.CARD_H / 2)
  end
  if self.on_hook then self.on_hook() end
end

return SW
