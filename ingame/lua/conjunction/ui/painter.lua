-- The quest graph's, the dialogue flow's and the game quest graph's picture drawn by the game itself (MaximdeWinter 24.10.:
-- "warum wird der quest graph nicht gleich gebaut wie der asset manager"). The views write the commands cj_qt_paint
-- reads (cj_qt.cpp: pen, brush, path, rectf, textrect ... in the view's scene); Qt painted them into a picture file
-- that was loaded as a texture each time something changed - 20 ms a change, hovering, zooming and dragging were
-- slow. Here the same commands are read once when they change, into steps in the view's pixels, and the steps are
-- drawn each frame with w3.ui.draw - only antialiasing and dashes differ a little from Qt's.
--   local steps = PA.compile(commands)      the commands (a list of lines) -> steps
--   PA.draw(steps, x, y, w, h)              drawn with the view's top left at x, y, inside w x h
local Q = require("conjunction.ui.qt")
local D = w3.ui.draw
local PA = {}

local function col(s)                                 -- "rrggbbaa" -> w3.ui's 0xRRGGBBAA
  return tonumber(s, 16) or 0
end
local function nums(parts, from, to)
  local out = {}
  for i = from, to or #parts do out[#out + 1] = tonumber(parts[i]) end
  return out
end
-- the rest of a line after n words (a text: it may have spaces)
local function rest(line, n)
  local i = 1
  for _ = 1, n do
    local a, b = line:find("%S+", i)
    if not a then return "" end
    i = b + 2
  end
  return line:sub(i)
end

-- a polyline cut into dashes (pattern in units of the pen's width, Qt's way) -> list of polylines
local function dashed(pts, pattern, unit)
  local out, cur = {}, {}
  local k, left, on = 1, pattern[1] * unit, true
  if on then cur = {pts[1], pts[2]} end
  for i = 1, #pts - 2, 2 do
    local ax, ay, bx, by = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    local at = 0
    while len - at > left do
      at = at + left
      local px, py = ax + dx * at / len, ay + dy * at / len
      if on then
        cur[#cur + 1], cur[#cur + 2] = px, py
        out[#out + 1] = cur
        cur = {}
      else
        cur = {px, py}
      end
      on = not on
      k = k % #pattern + 1
      left = pattern[k] * unit
    end
    left = left - (len - at)
    if on then cur[#cur + 1], cur[#cur + 2] = bx, by end
  end
  if on and #cur >= 4 then out[#out + 1] = cur end
  return out
end

-- the commands -> steps: {"fill", x, y, w, h, c} {"poly", pts, c} (convex, filled) {"line", pts, c, w, closed}
-- {"text", x, y, c, s, px, bold, spacing} {"image", id, x, y, w, h} {"clip", x, y, w, h} {"unclip"}
local images = {}
-- Qt's measures in the scene (the view's own size: the same for every zoom, asked once per text)
local function adv(px, bold, spacing, t) return require("conjunction.ui.graph_view").advance(px, bold, spacing, t) end
local heights = {}
local function height(px, bold)
  local key = px .. (bold and "b" or "")
  local v = heights[key]
  if v == nil then
    local ok, r = pcall(w3.plugin.cj_qt_font_height, tostring(px), bold and "1" or "0")
    v = ok and tonumber(r) or math.floor(px * 1.33 + 0.5)
    heights[key] = v
  end
  return v
end
-- QFontMetrics::elidedText at the right, in the scene: letters off until the rest and the ellipsis fit
local function elide(t, width, px, bold)
  if adv(px, bold, 0, t) <= width then return t end
  local cps = {}
  for _, c in utf8.codes(t) do cps[#cps + 1] = utf8.char(c) end
  for n = #cps - 1, 0, -1 do
    local head = table.concat(cps, "", 1, n) .. "\u{2026}"
    if adv(px, bold, 0, head) <= width then return head end
  end
  return ""
end
function PA.compile(commands)
  local steps = {}
  local s, sx, sy = 1, 0, 0                             -- the view's transform
  local ix, iy = 0, 0                                   -- an item's place in the scene
  local pen, pw, dash = nil, 1, nil                     -- colour (nil: none), width (scene), dash pattern
  local brush = nil
  local font = {px = 12, bold = false, spacing = 0}
  local stack = {}
  local clips = 0
  local opacity = 1                                     -- (opacity a: the story map's faded cards)
  local function fade(c)
    if not c or opacity >= 1 then return c end
    return (c & 0xffffff00) | math.floor((c & 0xff) * opacity + 0.5)
  end
  local function X(x) return (x + ix) * s - sx end
  local function Y(y) return (y + iy) * s - sy end
  local function width() return pw > 0 and pw * s or 1 end
  local function stroke(pts, closed)
    if not pen then return end
    if dash then
      local p = pts
      if closed then p = {table.unpack(pts)} p[#p + 1], p[#p + 2] = pts[1], pts[2] end
      for _, piece in ipairs(dashed(p, dash, width())) do steps[#steps + 1] = {"line", piece, fade(pen), width(), false} end
    else
      steps[#steps + 1] = {"line", pts, fade(pen), width(), closed}
    end
  end
  local function shape(pts, closed)
    if closed and brush and #pts >= 6 then steps[#steps + 1] = {"poly", pts, fade(brush)} end
    stroke(pts, closed)
  end
  local function rect_pts(x, y, w, h)
    return {X(x), Y(y), X(x + w), Y(y), X(x + w), Y(y + h), X(x), Y(y + h)}
  end
  local function text(x, y, w, h, flags, t, elide_w)
    if not pen or t == "" then return end
    local px = font.px * s
    if px < 3 then return end                           -- (too small to read: Qt draws a smudge)
    local lines = {}
    for l in (t .. "\30"):gmatch("([^\30]*)\30") do lines[#lines + 1] = l end
    if elide_w then
      local a, b = lines[1]:match("^([^\31]*)\31?(.*)$")
      lines[1] = elide(a, elide_w, font.px, font.bold) .. (b or "")
    end
    local lh = height(font.px, font.bold)               -- (scene units)
    local total = lh * #lines
    local top = y
    if flags & 0x80 ~= 0 then top = top + (h - total) / 2
    elseif flags & 0x40 ~= 0 then top = top + h - total end
    for k, l in ipairs(lines) do
      local tw = adv(font.px, font.bold, font.spacing, l)
      local left = x
      if flags & 0x4 ~= 0 then left = left + (w - tw) / 2
      elseif flags & 0x2 ~= 0 then left = left + w - tw end
      local adv1
      if font.spacing ~= 0 then                         -- (spaced letters: each at its place)
        adv1 = {}
        for _, c in utf8.codes(l) do adv1[#adv1 + 1] = adv(font.px, font.bold, 0, utf8.char(c)) * s end
      end
      steps[#steps + 1] = {"text", X(left), Y(top + (k - 1) * lh), fade(pen), l, px, font.bold, font.spacing * s, adv1}
    end
  end
  local function path(line, from)
    local pts, closed = {}, false
    local cx, cy
    local parts = {}
    for w in line:sub(from):gmatch("%S+") do parts[#parts + 1] = w end
    local i = 1
    while i <= #parts do
      local p = parts[i]
      if p == "M" or p == "L" then
        cx, cy = tonumber(parts[i + 1]), tonumber(parts[i + 2])
        pts[#pts + 1], pts[#pts + 2] = X(cx), Y(cy)
        i = i + 3
      elseif p == "Z" then
        closed = true
        i = i + 1
      else
        i = i + 1
      end
    end
    if closed and #pts >= 4 and pts[1] == pts[#pts - 1] and pts[2] == pts[#pts] then
      pts[#pts], pts[#pts - 1] = nil, nil
    end
    return pts, closed
  end
  for _, line in ipairs(commands) do
    local op = line:match("^(%S+)")
    local parts = {}
    for w in line:gmatch("%S+") do parts[#parts + 1] = w end
    if op == "view" then
      s, sx, sy = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4])
      ix, iy = 0, 0
    elseif op == "item" then
      ix, iy = tonumber(parts[2]), tonumber(parts[3])
    elseif op == "world" then
      ix, iy = 0, 0
    elseif op == "save" then
      stack[#stack + 1] = {ix, iy, pen, pw, dash, brush, {px = font.px, bold = font.bold, spacing = font.spacing}, clips,
                           opacity}
    elseif op == "restore" then
      local t = table.remove(stack)
      if t then
        ix, iy, pen, pw, dash, brush, font, opacity = t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[9] or 1
        while clips > t[8] do steps[#steps + 1] = {"unclip"} clips = clips - 1 end
      end
    elseif op == "pen" then
      pen, pw = col(parts[2]), tonumber(parts[3]) or 1
      dash = (tonumber(parts[6]) == 2) and {4, 2} or nil       -- (Qt::DashLine)
    elseif op == "opacity" then
      opacity = tonumber(parts[2]) or 1
    elseif op == "nopen" then
      pen = nil
    elseif op == "dash" then
      dash = nums(parts, 2)
    elseif op == "brush" then
      brush = col(parts[2])
    elseif op == "nobrush" then
      brush = nil
    elseif op == "fillrectf" then
      local x, y, w, h = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5])
      steps[#steps + 1] = {"fill", X(x), Y(y), w * s, h * s, fade(col(parts[6]))}
    elseif op == "rectf" or op == "rect" then
      local x, y, w, h = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5])
      shape(rect_pts(x, y, w, h), true)
    elseif op == "linef" or op == "line" then
      stroke({X(tonumber(parts[2])), Y(tonumber(parts[3])), X(tonumber(parts[4])), Y(tonumber(parts[5]))}, false)
    elseif op == "polylinef" then
      local v = nums(parts, 2)
      local pts = {}
      for i = 1, #v, 2 do pts[#pts + 1], pts[#pts + 2] = X(v[i]), Y(v[i + 1]) end
      stroke(pts, false)
    elseif op == "ellipsec" then
      local cx, cy, rx, ry = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5])
      steps[#steps + 1] = {"ellipse", X(cx), Y(cy), rx * s, ry * s, fade(brush), fade(pen), width()}
    elseif op == "path" then
      local pts, closed = path(line, 5)
      shape(pts, closed)
    elseif op == "clippath" then
      local pts = path(line, 9)
      local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
      for i = 1, #pts, 2 do
        x0, y0, x1, y1 = math.min(x0, pts[i]), math.min(y0, pts[i + 1]), math.max(x1, pts[i]), math.max(y1, pts[i + 1])
      end
      if x0 < x1 then steps[#steps + 1] = {"clip", x0, y0, x1 - x0, y1 - y0} clips = clips + 1 end
    elseif op == "fontpx" then
      font = {px = tonumber(parts[2]) or 12, bold = parts[3] == "1", spacing = tonumber(parts[4]) or 0}
    elseif op == "textrect" then
      text(tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5]), tonumber(parts[6]) or 0,
           rest(line, 6))
    elseif op == "textelide" then
      text(tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5]), tonumber(parts[6]) or 0,
           rest(line, 7), tonumber(parts[7]))
    elseif op == "imagefast" or op == "imagesmooth" or op == "image" then
      local file = rest(line, 5)
      local im = images[file]
      if im == nil then
        local id = w3.ui.image_load(file)
        im = id or false
        images[file] = im
      end
      if im then
        local x, y, w, h = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5])
        steps[#steps + 1] = {"image", im, X(x), Y(y), w * s, h * s, fade(0xffffffff)}
      end
    end
    -- (fill, aa, device: nothing to do - the background is the view's fillrectf, the game smooths always)
  end
  while clips > 0 do steps[#steps + 1] = {"unclip"} clips = clips - 1 end
  return steps
end

-- the steps drawn with the view's top left at ox, oy (clipped to its w x h); text at any size (TW3SE's text_scaled -
-- an older TW3SE: its nearest size)
local function one_text(x, y, c, s, px, bold)
  if D.text_scaled then D.text_scaled(x, y, c, s, px, bold) else Q.text(x, y, c, s, px, bold) end
end
local function text_spaced(x, y, c, s, px, bold, spacing, advs)
  if spacing == 0 or not advs then one_text(x, y, c, s, px, bold) return end
  local k = 1
  for _, cp in utf8.codes(s) do
    one_text(x, y, c, utf8.char(cp), px, bold)
    x = x + (advs[k] or 0) + spacing
    k = k + 1
  end
end
-- one step, the view's transform applied: x on the screen = ox + x * sc - sx (sc 1, sx sy 0: as compiled)
local function bbox(st)                                 -- (the step's box in its own units, kept with it)
  local b = st.bb
  if b then return b end
  local k = st[1]
  local x0, y0, x1, y1
  if k == "fill" or k == "clip" then
    x0, y0, x1, y1 = st[2], st[3], st[2] + st[4], st[3] + st[5]
  elseif k == "poly" or k == "line" then
    local p = st[2]
    x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #p, 2 do
      if p[i] < x0 then x0 = p[i] end
      if p[i] > x1 then x1 = p[i] end
      if p[i + 1] < y0 then y0 = p[i + 1] end
      if p[i + 1] > y1 then y1 = p[i + 1] end
    end
    local m = (st[4] or 0) / 2 + 1
    x0, y0, x1, y1 = x0 - m, y0 - m, x1 + m, y1 + m
  elseif k == "ellipse" then
    x0, y0, x1, y1 = st[2] - st[4] - 2, st[3] - st[5] - 2, st[2] + st[4] + 2, st[3] + st[5] + 2
  elseif k == "text" then
    x0, y0, x1, y1 = st[2], st[3], st[2] + #st[5] * st[6], st[3] + st[6] * 2
  elseif k == "image" then
    x0, y0, x1, y1 = st[3], st[4], st[3] + st[5], st[4] + st[6]
  else
    x0, y0, x1, y1 = -math.huge, -math.huge, math.huge, math.huge
  end
  b = {x0, y0, x1, y1}
  st.bb = b
  return b
end

-- (one table for the points of every shape drawn and one for a text's advances, filled anew each time - the draw
-- functions read them at once: a new table per shape per frame made 4 MB of garbage a second with the story map
-- open, its collection the micro stutters, 14.11.)
local qbuf, qlen, abuf, alen = {}, 0, {}, 0
local function on_screen(p, bx, by, sc)
  local n = #p
  for i = 1, n, 2 do qbuf[i], qbuf[i + 1] = bx + p[i] * sc, by + p[i + 1] * sc end
  for i = n + 1, qlen do qbuf[i] = nil end
  qlen = n
  return qbuf
end
local function scaled_advs(advs, sc)
  local n = #advs
  for i = 1, n do abuf[i] = advs[i] * sc end
  for i = n + 1, alen do abuf[i] = nil end
  alen = n
  return abuf
end

-- the steps drawn with the view's top left at ox, oy, clipped to its w x h; xf {scale, sx, sy}: the view's zoom and
-- scroll applied now (steps compiled in the scene: zooming and scrolling need no new steps), nil: as compiled
function PA.draw(steps, ox, oy, w, h, xf)
  local sc, sx, sy = 1, 0, 0
  if xf then sc, sx, sy = xf[1], xf[2], xf[3] end
  local bx = ox - sx                                    -- (screen x = bx + x * sc)
  local by = oy - sy
  -- what is in view, in the steps' units
  local vx0, vy0 = (ox - bx) / sc, (oy - by) / sc
  local vx1, vy1 = (ox + w - bx) / sc, (oy + h - by) / sc
  local function one(st)
    local k = st[1]
    local b = bbox(st)
    if b[3] < vx0 or b[1] > vx1 or b[4] < vy0 or b[2] > vy1 then return end
    if k == "fill" then
      D.fill(bx + st[2] * sc, by + st[3] * sc, st[4] * sc, st[5] * sc, st[6])
    elseif k == "poly" then
      D.fill_poly(on_screen(st[2], bx, by, sc), st[3])
    elseif k == "line" then
      D.poly(on_screen(st[2], bx, by, sc), st[3], st[4] * sc, st[5])
    elseif k == "ellipse" then
      local cx, cy, rx, ry = bx + st[2] * sc, by + st[3] * sc, st[4] * sc, st[5] * sc
      if st[6] then
        if rx < 1.6 and ry < 1.6 then D.fill(cx - rx, cy - ry, 2 * rx, 2 * ry, st[6])    -- (a dot: a square)
        else D.ellipse(cx, cy, rx, ry, st[6], 0) end
      end
      if st[7] then D.ellipse(cx, cy, rx, ry, st[7], st[8] * sc) end
    elseif k == "text" then
      local px = st[6] * sc
      if px >= 3 then
        local advs = st[9]
        if advs and sc ~= 1 then advs = scaled_advs(advs, sc) end
        text_spaced(bx + st[2] * sc, by + st[3] * sc, st[4], st[5], px, st[7], st[8] * sc, advs)
      end
    elseif k == "image" then
      D.image(st[2], bx + st[3] * sc, by + st[4] * sc, st[5] * sc, st[6] * sc, 0, 0, 1, 1, st[7])
    end
  end
  D.clip(ox, oy, w, h, function()
    local i = 1
    local function run(inner)
      while i <= #steps do
        local st = steps[i]
        i = i + 1
        if st[1] == "clip" then
          D.clip(bx + st[2] * sc, by + st[3] * sc, st[4] * sc, st[5] * sc, function() run(true) end)
        elseif st[1] == "unclip" then
          if inner then return end
        else
          one(st)
        end
      end
    end
    run(false)
  end)
end

return PA
