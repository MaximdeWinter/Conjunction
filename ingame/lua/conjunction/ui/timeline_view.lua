-- The scene workshop's timeline, below the scene (scene_timeline.lua's model): a ruler, a track per person and one
-- for the camera (with "All tracks" also faces, look-ats, places and effects), the clips on them, the playhead and
-- the section's end. A clip is moved by its body, made longer or shorter by its edges (an animation longer than
-- itself plays again: its seams show); edges snap to the clips' edges, the playhead and whole tenths. The wheel
-- zooms around the mouse, the middle button pans. The view only shows and reports; its owner changes the scene.
--   local v = TLV.new()
--   v:frame(r, tl, hit, {pick = id, playhead = t, all = bool, people = {actor ...}, drag = what, names = {tag = shown}})
--     -> an action or nil:
--     {"pick", id} {"seek", t} {"move", id, t} {"resize", id, from, to} {"length", secs}
--     {"drop", actor, t}  (o.drag: something dragged from elsewhere, let go over a person's track)
--   (o.people: each of them has an animation track, with clips or without)
local Q = require("conjunction.ui.qt")
local T = require("conjunction.ui.theme")
local D = w3.ui.draw
local TLV = {}
TLV.__index = TLV

TLV.HEAD_W, TLV.RULER_H, TLV.TRACK_H, TLV.GAP = 190, 22, 36, 4
TLV.EDGE_PX, TLV.SNAP_PX, TLV.MOVE_PX = 6, 8, 3
TLV.SIMPLE = {camera = true, anim = true, layer = true, lines = true, world = true,   -- (world: things of the world)
              acting = true}

function TLV.new()
  return setmetatable({px = 80.0, x0 = 0.0, press = nil, drag = nil}, TLV)
end

-- names: {voicetag = the name shown} (a talk's NPC by the name its card gives them)
local function track_name(tr, names)
  local who = tr.actor and names and names[tr.actor] or tr.actor
  if tr.kind == "camera" then return "Camera" end
  if tr.kind == "lines" then return "Lines" end
  if tr.kind == "effects" then return "Effects" end
  if tr.kind == "world" then return "World" end
  if tr.kind == "acting" then return (who or "?") .. "  acting" end
  if tr.kind == "anim" then return who or "?" end
  if tr.kind == "layer" then return (who or "?") .. "  layer" end
  return (who or "?") .. "  " .. tr.kind
end

-- the tracks shown: the camera and the people's animations (each of `people` has one); all of them with `all`
function TLV.shown(tl, all, people)
  local out, have = {}, {}
  for _, tr in ipairs(tl.tracks) do
    if all or TLV.SIMPLE[tr.kind] then out[#out + 1] = tr end
    if tr.kind == "anim" and tr.actor then have[tr.actor] = true end
  end
  for _, a in ipairs(people or {}) do
    if not have[a] then
      local tr = {id = "anim:" .. a, kind = "anim", actor = a, clips = {}}
      local at = #out + 1
      for i, t in ipairs(out) do                       -- (after the camera, among the people by name)
        if t.kind ~= "camera" and t.kind ~= "lines" and t.kind ~= "world" and (t.actor or "~") > a then at = i break end
      end
      table.insert(out, at, tr)
    end
  end
  return out
end

-- the world track's moments in rows of their own where they meet (a light and a door at the same second: each one
-- seen and clicked - 11.11., the second lay under the first) -> {[clip] = row from 0}, rows
local function lanes(tr)
  if tr.kind ~= "world" or #tr.clips < 2 then return nil, 1 end
  local list = {}
  for _, c in ipairs(tr.clips) do list[#list + 1] = c end
  table.sort(list, function(a, b) return a.start < b.start end)
  local ends, row = {}, {}
  for _, c in ipairs(list) do
    local k = 1
    while ends[k] and ends[k] > c.start + 0.01 do k = k + 1 end
    ends[k], row[c] = c.start + math.max(c.dur, 0.05), k - 1
  end
  return row, #ends
end
TLV.lanes = lanes
-- a track's height: the world track grows past two rows (14 px a row), the others TRACK_H
function TLV.track_h(tr)
  local _, n = lanes(tr)
  return n > 2 and (6 + n * 14) or TLV.TRACK_H
end
-- the top of track i of `shown` under `top` (the ruler's foot)
function TLV.track_y(shown, i, top)
  local y = top + TLV.GAP
  for j = 1, i - 1 do y = y + TLV.track_h(shown[j]) + TLV.GAP end
  return y
end

function TLV:t_of(x, r) return (x - (r.x + TLV.HEAD_W)) / self.px + self.x0 end
function TLV:x_of(t, r) return r.x + TLV.HEAD_W + (t - self.x0) * self.px end

-- t snapped to an edge near it (other clips', the playhead, 0, the end, whole tenths) - within SNAP_PX
function TLV:snap(t, tl, skip, playhead)
  local best, bd = nil, TLV.SNAP_PX / self.px
  local function try(v)
    local d = math.abs(v - t)
    if d < bd then best, bd = v, d end
  end
  try(0.0)
  try(tl.length)
  if playhead then try(playhead) end
  for _, tr in ipairs(tl.tracks) do
    for _, c in ipairs(tr.clips) do
      if c.id ~= skip then try(c.start) try(c.stop) end
    end
  end
  if best then return best end
  return math.floor(t * 10 + 0.5) / 10
end

-- what is under the mouse: {"ruler"} {"end"} {"clip", c, part = "body"|"left"|"right"} {"track", tr} or nil
function TLV:under(mx, my, r, shown, tl)
  local top = r.y + TLV.RULER_H
  if my >= r.y and my < top and mx >= r.x + TLV.HEAD_W then return {"ruler"} end
  local ex = self:x_of(tl.length, r)
  if math.abs(mx - ex) <= 4 and my >= r.y then return {"end"} end
  for i, tr in ipairs(shown) do
    local y, h = TLV.track_y(shown, i, top), TLV.track_h(tr)
    if my >= y and my < y + h then
      if mx < r.x + TLV.HEAD_W then return {"head", tr} end
      local row, n = lanes(tr)
      local at_row = row and math.max(0, math.min(n - 1, math.floor((my - y - 3) / ((h - 6) / n))))
      for k = #tr.clips, 1, -1 do
        local c = tr.clips[k]
        if row and row[c] ~= at_row then goto next_clip end
        local x1, x2 = self:x_of(c.start, r), self:x_of(c.start + math.max(c.dur, 0.05), r)
        if mx >= x1 - TLV.EDGE_PX / 2 and mx <= x2 + TLV.EDGE_PX / 2 then
          local part = "body"
          if c.kind ~= "camera" and mx >= x2 - TLV.EDGE_PX then part = "right"
          elseif c.kind ~= "camera" and mx <= x1 + TLV.EDGE_PX then part = "left" end
          return {"clip", c, part = part}
        end
        ::next_clip::
      end
      return {"track", tr}
    end
  end
  return nil
end

function TLV:frame(r, tl, hit, o)
  o = o or {}
  local act
  local shown = TLV.shown(tl, o.all, o.people)
  local mx, my, wheel = w3.ui.mouse()
  local clicked, hovered, held = hit("timeline", r)
  local over = hovered or held
  -- the wheel: zoom around the mouse
  if over and wheel and wheel ~= 0 and not self.drag then
    local at = self:t_of(mx, r)
    self.px = math.max(8.0, math.min(600.0, self.px * (wheel > 0 and 1.25 or 0.8)))
    self.x0 = math.max(0.0, at - (mx - r.x - TLV.HEAD_W) / self.px)
  end
  -- press, drag, let go
  if over and w3.ui.mouse_clicked(3) then self.press = {"pan", mx, x0 = self.x0} end
  if over and w3.ui.mouse_clicked(1) then
    local u = self:under(mx, my, r, shown, tl)
    self.press = {u and u[1] or "none", mx, my, u = u}
    -- (a line, its owner's fixed clip: a click goes there - it is moved in the dialogue, not here)
    if u and u[1] == "clip" then act = u[2].fixed and {"seek", u[2].start} or {"pick", u[2].id} end
    if u and u[1] == "ruler" then
      self.drag = {"seek"}
      act = {"seek", math.max(0.0, math.min(tl.length, self:t_of(mx, r)))}
    end
    if u and u[1] == "track" then act = {"seek", math.max(0.0, math.min(tl.length, self:t_of(mx, r)))} end
    if u and u[1] == "head" then act = {"pick", nil} end
  end
  local down = w3.ui.mouse_down(1) or w3.ui.mouse_down(3)
  if self.press and down then
    local p = self.press
    if p[1] == "pan" then
      self.x0 = math.max(0.0, p.x0 - (mx - p[2]) / self.px)
    elseif not self.drag and math.abs(mx - p[2]) >= TLV.MOVE_PX then
      local u = p.u
      if u and u[1] == "clip" and not u[2].fixed then
        local c = u[2]
        self.drag = {u.part, c, grab = self:t_of(p[2], r) - c.start}
      elseif u and u[1] == "end" then
        self.drag = {"end"}
      end
    end
    local d = self.drag
    if d then
      local t = self:t_of(mx, r)
      if d[1] == "seek" then
        act = {"seek", math.max(0.0, math.min(tl.length, t))}
      elseif d[1] == "body" then
        local s0 = self:snap(t - d.grab, tl, d[2].id, o.playhead)
        local e0 = self:snap(t - d.grab + d[2].dur, tl, d[2].id, o.playhead)
        d.at = math.abs(s0 - (t - d.grab)) <= math.abs(e0 - (t - d.grab + d[2].dur)) and s0 or e0 - d[2].dur
        d.at = math.max(0.0, d.at)
      elseif d[1] == "left" then
        d.from = math.max(0.0, math.min(self:snap(t, tl, d[2].id, o.playhead), d[2].stop - 0.1))
      elseif d[1] == "right" then
        d.to = math.max(self:snap(t, tl, d[2].id, o.playhead), d[2].start + 0.1)
      elseif d[1] == "end" then
        d.len = math.max(0.5, self:snap(t, tl, nil, o.playhead))
      end
    end
  elseif self.press and not down then
    local d = self.drag
    if d and d[1] == "body" and d.at then act = {"move", d[2].id, d.at}
    elseif d and d[1] == "left" and d.from then act = {"resize", d[2].id, d.from, d[2].stop}
    elseif d and d[1] == "right" and d.to then act = {"resize", d[2].id, d[2].start, d.to}
    elseif d and d[1] == "end" and d.len then act = {"length", d.len} end
    self.press, self.drag = nil, nil
  end
  if over then
    local u = self.drag and {"clip", nil, part = self.drag[1]} or self:under(mx, my, r, shown, tl)
    if u and (u.part == "left" or u.part == "right" or u[1] == "end") then w3.ui.cursor("move")
    elseif u and u[1] == "clip" then w3.ui.cursor("hand") end
  end
  -- something dragged in from elsewhere (an animation of the library): the track under the mouse, let go there
  self.drop_at = nil
  if o.drag then
    local u = self:under(mx, my, r, shown, tl)
    local tr = u and (u[1] == "track" and u[2] or (u[1] == "clip" and nil) or (u[1] == "head" and u[2]))
    if u and u[1] == "clip" then
      for _, t in ipairs(shown) do
        for _, c in ipairs(t.clips) do if c == u[2] then tr = t end end
      end
    end
    if tr and tr.actor and (tr.kind == "anim" or tr.kind == "layer") then
      local t = math.max(0.0, math.min(tl.length, self:snap(self:t_of(math.max(mx, r.x + TLV.HEAD_W), r), tl, nil, o.playhead)))
      self.drop_at = {tr.id, t}
      if not w3.ui.mouse_down(1) then act = {"drop", tr.actor, t} end
    end
  end
  self:paint(r, tl, shown, o)
  return act
end

function TLV:paint(r, tl, shown, o)
  D.fill(r.x, r.y, r.w, r.h, T.SURFACE)
  local x0 = r.x + TLV.HEAD_W
  D.clip(r.x, r.y, r.w, r.h, function()
    -- the ruler: a mark each second (each 5 or 10 when it is small)
    D.fill(x0, r.y, r.w - TLV.HEAD_W, TLV.RULER_H, T.HEADER)
    local step = self.px >= 40 and 1 or (self.px >= 12 and 5 or 10)
    local s = math.floor(self.x0 / step) * step
    while self:x_of(s, r) < r.x + r.w do
      local x = self:x_of(s, r)
      if x >= x0 then
        D.fill(x, r.y + TLV.RULER_H - 6, 1, 6, T.EDGE)
        Q.text(x + 3, r.y + 3, T.DIM, s .. " s", T.FONT_SMALL)
      end
      s = s + step
    end
    -- the tracks
    local top = r.y + TLV.RULER_H
    for i, tr in ipairs(shown) do
      local y, h = TLV.track_y(shown, i, top), TLV.track_h(tr)
      D.fill(r.x + 4, y, TLV.HEAD_W - 10, h, T.HEADER)
      Q.text(r.x + 12, y + 10, T.TEXT, track_name(tr, o.names), T.FONT)
      D.fill(x0, y, r.w - TLV.HEAD_W, h, T.BG)
      D.clip(x0, y, r.w - TLV.HEAD_W, h, function()
        local row, n = lanes(tr)
        for k, c in ipairs(tr.clips) do
          local cy, ch = y + 3, TLV.TRACK_H - 6      -- (its row: the whole track, or its part of it)
          if row then ch = (h - 6) / n cy = y + 3 + row[c] * ch ch = ch - 1 end
          local cs, ce = c.start, c.start + math.max(c.dur, 0.05)
          local d = self.drag
          if d and d[2] and d[2].id == c.id then
            if d[1] == "body" and d.at then cs, ce = d.at, d.at + c.dur
            elseif d[1] == "left" and d.from then cs = d.from
            elseif d[1] == "right" and d.to then ce = d.to end
          end
          local xa, xb = self:x_of(cs, r), self:x_of(ce, r)
          local picked = o.pick == c.id
          local text = c.label or ""
          for tag, name in pairs(o.names or {}) do
            if text:sub(1, #tag + 1) == tag .. ":" then text = name .. text:sub(#tag + 1) end
          end
          D.fill(xa, cy, math.max(2, xb - xa - 2), ch, picked and T.CHOSEN or T.BUTTON)
          D.rect(xa, cy, math.max(2, xb - xa - 2), ch, picked and T.CHOSEN_EDGE or T.EDGE, 1)
          for _, sm in ipairs(c.seams or {}) do
            if sm > cs and sm < ce then D.fill(self:x_of(sm, r), y + 7, 1, TLV.TRACK_H - 14, T.DIM) end
          end
          local prev = tr.clips[k - 1]
          if prev and prev.start + prev.dur > c.start + 0.01 and c.kind == "anim" then   -- over the one before: a blend
            D.line(xa, y + TLV.TRACK_H - 4, self:x_of(prev.start + prev.dur, r), y + 4, T.CHOSEN_EDGE, 1)
          end
          if picked and c.kind ~= "camera" then
            local hy, hh = row and cy + 2 or y + 11, row and ch - 4 or TLV.TRACK_H - 22
            D.fill(xa - 2, hy, 4, hh, T.CHOSEN_EDGE)
            D.fill(xb - 4, hy, 4, hh, T.CHOSEN_EDGE)
          end
          if xb - xa > 24 and row then              -- (a row of its own: the name alone)
            D.clip(xa + 1, cy, xb - xa - 4, ch, function()
              Q.text(xa + 5, cy + math.max(0, (ch - 13) / 2), picked and T.BRIGHT or T.TEXT, text, T.FONT_SMALL)
            end)
          elseif xb - xa > 24 then
            D.clip(xa + 1, y + 3, xb - xa - 4, TLV.TRACK_H - 6, function()
              Q.text(xa + 7, y + 5, picked and T.BRIGHT or T.TEXT, text, T.FONT_LIST)
              Q.text(xa + 7, y + 19, T.DIM, string.format("%.1f s", ce - cs), T.FONT_SMALL)
            end)
          end
        end
      end)
    end
    if self.drop_at then
      for i, tr in ipairs(shown) do
        if tr.id == self.drop_at[1] then
          local y, h = TLV.track_y(shown, i, top), TLV.track_h(tr)
          D.rect(x0, y, r.w - TLV.HEAD_W, h, T.CHOSEN_EDGE, 1)
          D.fill(self:x_of(self.drop_at[2], r) - 1, y, 3, h, T.CHOSEN_EDGE)
        end
      end
    end
    -- the section's end, the playhead
    local len = self.drag and self.drag[1] == "end" and self.drag.len or tl.length
    local ex = self:x_of(len, r)
    D.fill(ex - 1, r.y, 3, r.h, T.EDGE)
    if o.playhead then
      local px = self:x_of(o.playhead, r)
      if px >= x0 then
        D.fill(px - 1, r.y, 2, r.h, T.BRIGHT)
        D.fill_poly({px - 6, r.y, px + 6, r.y, px, r.y + 9}, T.BRIGHT)
      end
    end
  end)
end

return TLV
