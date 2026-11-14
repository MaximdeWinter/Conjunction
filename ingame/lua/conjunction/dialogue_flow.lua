-- dialogue_flow.py: a talk's dialogue laid out to be read at a glance (ui/dialogue_view draws it) - what is always
-- said down the middle, a choice's answers in one box (those that go on under it side by side, questions and ends to
-- its right), an if / at random's ways side by side. Pure data: F.layout(lines, names) -> Flow {boxes, wires, w, h,
-- exits} in pixels from 0, 0. A box keeps what it shows (ref) so a click finds it.
local D = require("conjunction.dialogue")
local P = require("conjunction.py")
local Y = require("conjunction.yaml")
local PS = require("conjunction.pysort")
local PYS = require("conjunction.pystr")
local F = {}

F.W, F.LANE, F.GAP, F.SIDE, F.HEAD, F.LINE, F.ROW = 380, 300, 28, 70, 26, 17, 24
F.PILL_W, F.PILL_H = 170, 26
F.CHARS = 44
F.MAIN = "#e3c65f"
F.COLOUR = {on = "#d8d8e0", back = "#9aa0b0", up = "#9aa0b0", continue = "#22c55e", retry = "#d9a45b", fail = "#ef4444"}
F.WORD = {on = "", back = "back to choice", up = "back to previous choice", continue = "end: continue",
          retry = "end: repeatable", fail = "end: fail quest"}
F.PILL = {continue = "CONTINUE QUEST", retry = "REPEATABLE", fail = "FAIL QUEST"}
local W, LANE, GAP, SIDE, HEAD, LINE, ROW = F.W, F.LANE, F.GAP, F.SIDE, F.HEAD, F.LINE, F.ROW
local PILL_W, PILL_H = F.PILL_W, F.PILL_H

-- what an answer's end is in the look's words: on, back, up, continue, retry, fail (a path or a scene's exit ends the
-- talk and goes on)
function F.kind(end_)
  local e = P.str(P.or_(end_, "continue"))
  if e:sub(1, 5) == "path:" or e:sub(1, 4) == "out:" then return "continue" end
  return F.COLOUR[e] and e or "continue"
end

-- an answer's kind; one whose lines end with an if / at random whose ways all go back is a question
function F.answer_kind(c)
  local sub = P.list(P.get(c, "lines"))
  if #sub > 0 and (P.has(sub[#sub], "if") or P.has(sub[#sub], "random")) then
    local all = true
    for _, w in ipairs(D.ways(sub[#sub])) do if w[2] ~= "back" and w[2] ~= "up" then all = false end end
    if all then return "back" end
  end
  return F.kind(P.get(c, "end"))
end

local function box(kind, x, y, w, h, title, o)
  o = o or {}
  return {kind = kind, x = x, y = y, w = w, h = h, title = title or "", rows = o.rows or {}, colour = o.colour or "",
          ref = o.ref, ports = o.ports or {}}
end
local function wire(points, colour, dashed, arrow)
  return {points = points, colour = colour or "#808090", dashed = dashed == true, arrow = arrow ~= false}
end
F.box, F.wire = box, wire

local Flow = {}
Flow.__index = Flow
function F.Flow(w) return setmetatable({boxes = {}, wires = {}, w = w or 0, h = 0, exits = {}}, Flow) end
function Flow:move(dx, dy)
  for _, b in ipairs(self.boxes) do b.x, b.y = b.x + dx, b.y + dy end
  for _, wi in ipairs(self.wires) do
    local pts = {}
    for _, p in ipairs(wi.points) do pts[#pts + 1] = {p[1] + dx, p[2] + dy} end
    wi.points = pts
  end
  local ex = {}
  for _, e in ipairs(self.exits) do ex[#ex + 1] = {e[1] + dx, e[2] + dy} end
  self.exits = ex
  return self
end
function Flow:take(other)
  for _, b in ipairs(other.boxes) do self.boxes[#self.boxes + 1] = b end
  for _, wi in ipairs(other.wires) do self.wires[#self.wires + 1] = wi end
end

-- words to lines of at most `width` characters (Python's str.split: runs of white space)
function F.wrap(text, width)
  local words = {}
  for wd in P.str(P.or_(text, "")):gmatch("%S+") do words[#words + 1] = wd end
  local lines, cur = {}, ""
  for _, wd in ipairs(words) do
    if cur ~= "" and #PYS.cps(cur) + 1 + #PYS.cps(wd) > width then
      lines[#lines + 1] = cur
      cur = wd
    else
      cur = cur == "" and wd or (cur .. " " .. wd)
    end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  if #lines == 0 then lines = {""} end
  return lines
end

-- the small tags of an answer: what it costs, needs, does
function F.chips(c)
  local out = {}
  if P.T(P.get(c, "emphasize")) then out[#out + 1] = "main" end
  if P.T(P.get(c, "once")) then out[#out + 1] = "once" end
  if P.T(P.get(c, "pay")) then out[#out + 1] = P.str(c.pay) .. " crowns" end
  if P.T(P.get(c, "axii")) then
    local a = c.axii
    out[#out + 1] = "Axii" .. ((a ~= true and a ~= 1) and (" " .. P.str(a)) or "")
  end
  local conds = D.conditions(c)
  local all, after, cond = false, false, false
  for _, x in ipairs(conds) do
    if x == D.AFTER_ALL then all = true end
    if type(x) == "string" and x:sub(1, 1) == "@" and x ~= D.AFTER_ALL then after = true end
    if not (type(x) == "string" and x:sub(1, 1) == "@") then cond = true end
  end
  if all then out[#out + 1] = "after all others" end
  if after then out[#out + 1] = "after option" end
  if cond then out[#out + 1] = "condition" end
  if Y.is_map(P.get(c, "needs")) then out[#out + 1] = P.T(P.get(c.needs, "none")) and "has none" or "player has item" end
  if Y.is_map(P.get(c, "give")) then out[#out + 1] = "gives item" end
  if Y.is_map(P.get(c, "receive")) then out[#out + 1] = "receives" end
  if P.T(P.get(c, "icon")) and c.icon ~= "exit" then out[#out + 1] = P.str(c.icon) end
  return out
end

local function bottom_of(boxes, floor)
  local m = floor
  for _, b in ipairs(boxes) do if m == nil or b.y + b.h > m then m = b.y + b.h end end
  return m
end

-- wires from the open ends down into (cx, y): straight when one is right above, else across just above
local function join(f, exits, cx, y, colour)
  colour = colour or "#808090"
  for _, e in ipairs(exits) do
    local x, y0 = e[1], e[2]
    if math.abs(x - cx) < 1 then
      f.wires[#f.wires + 1] = wire({{x, y0}, {cx, y}}, colour)
    else
      local mid = y - 12
      f.wires[#f.wires + 1] = wire({{x, y0}, {x, mid}, {cx, mid}, {cx, y}}, colour, false, true)
    end
  end
end

local function pill_text(c, e)
  local end_ = P.str(P.or_(P.get(c, "end"), ""))
  if end_:sub(1, 4) == "out:" then
    local s = PYS.cps("CONTINUE AT: " .. P.replace(end_:sub(5), "_", " "))
    return PYS.upper(PYS.from_cps(s, 1, math.min(26, #s)))
  end
  if end_:sub(1, 5) == "path:" then               -- (an answer's own output of the talk's node)
    local s = PYS.cps("OUTPUT: " .. P.replace(end_:sub(6), "_", " "))
    return PYS.upper(PYS.from_cps(s, 1, math.min(26, #s)))
  end
  return F.PILL[e] or PYS.upper(e)
end

local split
-- a list of lines in a column `w` wide from (0, 0): its boxes, and where it goes on at its bottom (dialogue_flow.flow)
function F.flow(ls, w, t, entry)
  if entry == nil then entry = true end
  local f = F.Flow(w)
  local cx = w / 2
  local y = 0.0
  local exits = entry and {{cx, 0.0}} or {}
  local chars = w >= W and F.CHARS or F.CHARS - 10
  local k = 1
  local first = true
  while k <= #ls do
    local x = ls[k]
    local is_split = false
    for _, s in ipairs(D.SPLITS) do if P.has(x, s) then is_split = true end end
    if is_split then
      local sub = split(ls, k, w, t)
      local top = y + (first and 0 or GAP)
      sub:move(0, top)
      if #exits > 0 and not first then join(f, exits, cx, top) end
      f:take(sub)
      f.w = math.max(f.w, sub.w)
      exits = sub.exits
      y = top + sub.h
      k = k + 1
      first = false
    else
      local b, j
      if P.has(x, "script") then
        b = box("script", 0, 0, w, 24, "SCRIPT", {rows = {P.str(P.or_(P.get(P.or_(x.script, Y.map()), "function"), ""))},
                                                 colour = "#9fb0ff", ref = {"script", ls, k}})
        j = k + 1
      else
        j = k
        local rows = {}
        while j <= #ls and P.has(ls[j], "who") do
          local who = P.str(P.or_(P.get(ls[j], "who"), "npc"))
          local name = D.is_player(who) and t.player or P.str(P.or_(t.names[who], D._label(who), "NPC"))
          rows[#rows + 1] = {who, PYS.upper(name), F.wrap(P.or_(P.get(ls[j], "text"), "..."), chars),
                             P.T(P.get(ls[j], "voice")), t.colour(who)}
          j = j + 1
        end
        if j > k then
          local h = 8
          for _, r in ipairs(rows) do h = h + LINE * #r[3] + 5 end
          h = h + 4
          b = box("lines", 0, 0, w, h, "", {rows = rows, ref = {"lines", ls, k, j - 1}})
        end
      end
      if b == nil then                       -- (something else: shown as nothing, skipped)
        k = k + 1
      else
        local top = y + (first and 0 or GAP)
        b.x, b.y = 0, top
        if #exits > 0 and not first then join(f, exits, cx, top) end
        f.boxes[#f.boxes + 1] = b
        exits = {{cx, top + b.h}}
        y = top + b.h
        k = j
        first = false
      end
    end
  end
  f.h = y
  f.exits = exits
  return f
end

-- a choice / if / random at the top of a column `w` wide (dialogue_flow.split)
split = function(ls, k, w, t)
  local x = ls[k]
  local f = F.Flow(w)
  local cx = w / 2
  local b, ways
  local is_choice = P.has(x, "choice")
  if is_choice then
    local answers = P.list(x.choice)
    local rows, ports = {}, {}
    for j, c in ipairs(answers) do
      rows[#rows + 1] = {text = P.str(P.or_(P.get(c, "text"), "...")), kind = F.answer_kind(c), chips = F.chips(c),
                         ref = c, main = P.T(P.get(c, "emphasize"))}
      ports[#ports + 1] = HEAD + (j - 1) * ROW + ROW / 2
    end
    b = box("choice", 0, 0, w, HEAD + #answers * ROW + 6, "CHOICE", {rows = rows, colour = "#b99be6",
                                                                     ref = {"choice", ls, k}, ports = ports})
    ways = {}
    for _, c in ipairs(answers) do ways[#ways + 1] = {c, F.answer_kind(c), P.list(P.get(c, "lines"))} end
  else
    local brs = {}
    if P.has(x, "if") then
      brs = {P.or_(P.get(x, "then"), Y.map()), P.or_(P.get(x, "else"), Y.map())}
    else
      for _, br in ipairs(P.list(P.get(x, "random"))) do brs[#brs + 1] = br end
    end
    local title
    if P.has(x, "if") then
      local c_ = P.or_(P.get(x, "if"), Y.map())
      title = string.format("IF  %s %s %s", P.str(P.or_(P.get(c_, "fact"), "...")), P.str(P.get(c_, "op", ">=")),
                            P.str(P.get(c_, "value", 1)))
    else
      title = "AT RANDOM"
    end
    b = box(P.has(x, "if") and "if" or "random", 0, 0, w, 30, title, {colour = "#d9a45b", ref = {"split", ls, k}})
    ways = {}
    for _, br in ipairs(brs) do ways[#ways + 1] = {br, F.kind(P.or_(P.get(br, "end"), "on")), P.list(P.get(br, "lines"))} end
  end
  f.boxes[#f.boxes + 1] = b
  local below = b.h
  -- the ways that go on: side by side under it, together again at the bottom; none of them: the main answer that
  -- ends the talk goes down the middle
  local ons = {}
  for _, wy in ipairs(ways) do if wy[2] == "on" then ons[#ons + 1] = {wy[1], wy[3]} end end
  local middle
  if #ons == 0 and is_choice then
    for j, wy in ipairs(ways) do
      if P.T(P.get(wy[1], "emphasize")) and #wy[3] > 0 and wy[2] ~= "back" and wy[2] ~= "up" then middle = j break end
    end
  end
  local lanes = {}
  for _, o in ipairs(ons) do lanes[#lanes + 1] = {o[1], #o[2] > 0 and F.flow(o[2], LANE, t) or false} end
  local widths, nonzero = {}, 0
  for i, l in ipairs(lanes) do
    widths[i] = l[2] and l[2].w or 0
    if widths[i] ~= 0 then nonzero = nonzero + 1 end
  end
  local total = 0
  for _, wd in ipairs(widths) do total = total + wd end
  total = total + GAP * math.max(0, nonzero - 1)
  local x0 = cx - total / 2
  local top = below + GAP
  local exits, bottom = {}, below
  local named = is_choice and #lanes > 1
  if named then top = top + 18 end
  local any_none = false
  for i, l in ipairs(lanes) do
    local c, lane, lw = l[1], l[2], widths[i]
    if not lane then
      any_none = true
      exits[#exits + 1] = {cx, below}       -- (no lines of its own: straight on)
    else
      lane:move(x0, top)
      local lcx = lw <= LANE and (x0 + lw / 2) or (x0 + LANE / 2)
      f.wires[#f.wires + 1] = wire({{cx, below}, {cx, below + 12}, {lcx, below + 12}, {lcx, top}}, "#b99be6")
      if named or not is_choice then
        local label = is_choice and P.get(c, "text") or nil
        f.boxes[#f.boxes + 1] = box("label", x0, top - 18, math.min(lw, LANE), 16, P.str(P.or_(label, "")),
                                    {colour = "#b99be6", ref = {"answer", c}})
      end
      f:take(lane)
      for _, e in ipairs(lane.exits) do exits[#exits + 1] = e end
      bottom = math.max(bottom, bottom_of(lane.boxes, top))
      x0 = x0 + lw + GAP
    end
  end
  if any_none and #lanes > 1 then
    local keep = {{cx, below}}
    for _, e in ipairs(exits) do if not (e[1] == cx and e[2] == below) then keep[#keep + 1] = e end end
    exits = keep
  end
  if middle then                             -- (the main way down the middle, its end below it)
    local c, e, sub = ways[middle][1], ways[middle][2], ways[middle][3]
    local lane = F.flow(sub, w, t):move(0, below + GAP)
    f.wires[#f.wires + 1] = wire({{cx, below}, {cx, below + GAP}}, F.MAIN)
    f:take(lane)
    local ly = bottom_of(lane.boxes)
    bottom = ly
    if #lane.exits > 0 then
      local pill = box("pill", cx - PILL_W / 2, ly + GAP, PILL_W, PILL_H, pill_text(c, e), {colour = F.COLOUR[e],
                                                                                           ref = {"end", c, e}})
      join(f, lane.exits, cx, pill.y, F.COLOUR[e])
      f.boxes[#f.boxes + 1] = pill
      bottom = pill.y + pill.h
    end
  end
  -- the others, to the right: questions first, then those that end the talk
  local right = w
  for _, bx in ipairs(f.boxes) do right = math.max(right, bx.x + bx.w) end
  right = right + SIDE
  local ry = 0.0
  local bus = right - 14
  local order = {}
  for j, wy in ipairs(ways) do
    if wy[2] ~= "on" and j ~= middle then order[#order + 1] = {j, wy[1], wy[2], wy[3]} end
  end
  order = PS.sorted(order, function(o) return not (o[3] == "back" or o[3] == "up") end)
  local backs = {}
  for _, o in ipairs(order) do
    local j, c, e, sub = o[1], o[2], o[3], o[4]
    local py = #b.ports > 0 and b.ports[j] or b.h / 2
    local colour = F.COLOUR[e]
    local turn = right - SIDE + 18 + 6 * ((j - 1) % 5)
    if #sub > 0 then
      local lane = F.flow(sub, LANE, t):move(right, ry)
      f.wires[#f.wires + 1] = wire({{w, py}, {turn, py}, {turn, ry + 14}, {right, ry + 14}}, colour, false, true)
      f:take(lane)
      local ly = bottom_of(lane.boxes)
      if e == "back" or e == "up" then
        if e == "back" and is_choice then
          backs[#backs + 1] = ly - 10
          f.wires[#f.wires + 1] = wire({{right, ly - 10}, {bus, ly - 10}}, colour, true, false)
        else
          local pill = box("pill", right + LANE / 2 - PILL_W / 2, ly + GAP / 2, PILL_W, PILL_H,
                           (e == "up" or is_choice) and "BACK TO THE CHOICE ABOVE" or "BACK TO THE CHOICES",
                           {colour = colour, ref = {"end", sub, e}})
          f.wires[#f.wires + 1] = wire({{right + LANE / 2, ly}, {right + LANE / 2, pill.y}}, colour, true)
          f.boxes[#f.boxes + 1] = pill
          ly = pill.y + pill.h
        end
      elseif #lane.exits > 0 then
        local pill = box("pill", right + LANE / 2 - PILL_W / 2, ly + GAP / 2, PILL_W, PILL_H, pill_text(c, e),
                         {colour = colour, ref = {"end", c, e}})
        join(f, lane.exits, right + LANE / 2, pill.y, colour)
        f.boxes[#f.boxes + 1] = pill
        ly = pill.y + pill.h
      end
      ry = ly + GAP
    elseif e ~= "back" then                  -- (a question with no answer: nothing beside it)
      local pill = box("pill", right, math.max(ry, py - PILL_H / 2), PILL_W, PILL_H,
                       e ~= "up" and pill_text(c, e) or "BACK TO THE CHOICE ABOVE", {colour = colour, ref = {"end", c, e}})
      f.wires[#f.wires + 1] = wire({{w, py}, {turn, py}, {turn, pill.y + PILL_H / 2}, {right, pill.y + PILL_H / 2}},
                                   colour, e == "up")
      f.boxes[#f.boxes + 1] = pill
      ry = pill.y + PILL_H + GAP
    end
  end
  if #backs > 0 then                          -- (the questions' way back: one dashed line into the choice)
    local into = b.h - 8
    local mb = backs[1]
    for _, v in ipairs(backs) do mb = math.max(mb, v) end
    f.wires[#f.wires + 1] = wire({{bus, mb}, {bus, into}, {w, into}}, F.COLOUR.back, true)
  end
  local fw = w
  for _, bx in ipairs(f.boxes) do fw = math.max(fw, bx.x + bx.w) end
  f.w = fw
  f.h = math.max(bottom, bottom_of(f.boxes, bottom))
  f.exits = exits
  return f
end

-- the whole talk: DIALOGUE START, its flow, and CONTINUE QUEST where its lines run out (dialogue_flow.layout)
function F.layout(lines, names, player, colour, monologue)
  local t = {names = names or {}, player = player or "Geralt", colour = colour or function(who) return D.color(who) end}
  local root = F.Flow()
  local start = box("start", 0, 0, W, 30, monologue and "MONOLOGUE START" or "DIALOGUE START",
                    {colour = "#808090", rows = monologue and {} or {P.str(P.or_(t.names.npc, "NPC"))},
                     ref = {"start", lines}})
  root.boxes[#root.boxes + 1] = start
  local body = F.flow(lines, W, t):move(0, 30 + GAP)
  root.wires[#root.wires + 1] = wire({{W / 2, 30}, {W / 2, 30 + GAP}})
  root:take(body)
  local y = 30 + GAP + body.h
  for _, b in ipairs(root.boxes) do if b.x < W then y = math.max(y, b.y + b.h) end end
  if #body.exits > 0 then
    local pill = box("pill", W / 2 - PILL_W / 2, y + GAP, PILL_W, PILL_H, F.PILL.continue,
                     {colour = F.COLOUR.continue, ref = {"end", lines, "continue"}})
    join(root, body.exits, W / 2, y + GAP, F.COLOUR.continue)
    root.boxes[#root.boxes + 1] = pill
  end
  local left = root.boxes[1].x
  for _, b in ipairs(root.boxes) do left = math.min(left, b.x) end
  if left < 0 then root:move(-left, 0) end
  root.w, root.h = 0, 0
  for i, b in ipairs(root.boxes) do
    root.w = i == 1 and b.x + b.w or math.max(root.w, b.x + b.w)
    root.h = i == 1 and b.y + b.h or math.max(root.h, b.y + b.h)
  end
  return root
end

-- --- boxes moved by hand (MaximdeWinter 13.11.: a dialogue has to be arranged as neatly as the quest graph)
-- where each list and answer of the dialogue is in it ("/2c1/1": line 2's choice, answer 1, its lines): a box's key
-- that stays over a save and a load, as its tables do not
function F.paths(lines)
  local at = {}
  local function walk(ls, path)
    if type(ls) ~= "table" then return end
    at[ls] = path
    for k, x in ipairs(ls) do
      if P.has(x, "choice") then
        for j, c in ipairs(P.list(x.choice)) do
          at[c] = path .. k .. "c" .. j
          walk(P.get(c, "lines"), path .. k .. "c" .. j .. "/")
        end
      elseif P.has(x, "if") then
        for _, side in ipairs({{"then", "t"}, {"else", "e"}}) do
          local br = P.get(x, side[1])
          if type(br) == "table" then
            at[br] = path .. k .. side[2]
            walk(P.get(br, "lines"), path .. k .. side[2] .. "/")
          end
        end
      elseif P.has(x, "random") then
        for j, br in ipairs(P.list(x.random)) do
          at[br] = path .. k .. "r" .. j
          walk(P.get(br, "lines"), path .. k .. "r" .. j .. "/")
        end
      end
    end
  end
  walk(lines, "/")
  return at
end

-- a box's key by what it shows (nil: one that does not move)
local KEY_OF = {lines = "L", script = "S", choice = "C", split = "X"}
function F.box_key(b, at)
  local r = b.ref
  if type(r) ~= "table" then return nil end
  if r[1] == "start" then return "start" end
  if KEY_OF[r[1]] and at[r[2]] then return KEY_OF[r[1]] .. at[r[2]] .. r[3] end
  if r[1] == "answer" and at[r[2]] then return "A" .. at[r[2]] end
  if r[1] == "end" and at[r[2]] then return "E" .. at[r[2]] .. "_" .. (P.str(r[3]):gsub("[^%w]", "_")) end
  return nil
end

-- the flow with its boxes moved by offsets {key = {dx, dy}}. Each wire's ends belong to the box they lie on the edge
-- of (w.src, w.dst); a wire between two boxes moved apart is drawn square between them anew, leaving and arriving as
-- it did (down, or across)
function F.arrange(flow, lines, offsets)
  local at = F.paths(lines)
  for _, b in ipairs(flow.boxes) do b.key = F.box_key(b, at) end
  local function owner(p)
    for _, b in ipairs(flow.boxes) do
      if b.kind ~= "label" and p[1] >= b.x - 1 and p[1] <= b.x + b.w + 1 and p[2] >= b.y - 1 and p[2] <= b.y + b.h + 1 then
        return b
      end
    end
    return nil
  end
  for _, w in ipairs(flow.wires) do
    if #w.points >= 2 then w.src, w.dst = owner(w.points[1]), owner(w.points[#w.points]) end
  end
  offsets = offsets or {}
  local function off(b)
    local o = b and b.key and offsets[b.key]
    if type(o) == "table" then return tonumber(o[1]) or 0, tonumber(o[2]) or 0 end
    return 0, 0
  end
  for _, b in ipairs(flow.boxes) do
    local dx, dy = off(b)
    b.x, b.y = b.x + dx, b.y + dy
  end
  for _, w in ipairs(flow.wires) do
    local pts = w.points
    if #pts >= 2 then
      local sx, sy = off(w.src)
      local ex, ey = off(w.dst)
      if sx == ex and sy == ey then
        if sx ~= 0 or sy ~= 0 then for i, p in ipairs(pts) do pts[i] = {p[1] + sx, p[2] + sy} end end
      else
        local a, z = pts[1], pts[#pts]
        local s, e = {a[1] + sx, a[2] + sy}, {z[1] + ex, z[2] + ey}
        local d = w.dst
        if d ~= nil then
          -- (into a box at the middle of its top, from above, as the quest graph's inputs - MaximdeWinter 13.11.: a lane's
          -- wire came in at the side, behind the box once it was moved)
          e = {d.x + d.w / 2, d.y}
          local over = e[2] - 12
          if pts[2][1] ~= a[1] then              -- (leaving across: a choice's answer on its right)
            local m = s[1] + 18
            w.points = {s, {m, s[2]}, {m, over}, {e[1], over}, e}
          elseif over > s[2] then                -- (leaving down, the box below it)
            w.points = s[1] == e[1] and {s, e} or {s, {s[1], over}, {e[1], over}, e}
          else                                   -- (the box above it: round the side)
            local side = math.max(w.src and (w.src.x + w.src.w) or s[1], d.x + d.w) + 20
            w.points = {s, {s[1], s[2] + 12}, {side, s[2] + 12}, {side, over}, {e[1], over}, e}
          end
        else
          local down0, down1 = pts[2][1] == a[1], pts[#pts - 1][1] == z[1]
          if down0 and down1 then
            local m = e[2] - 12
            if m <= s[2] then m = (s[2] + e[2]) / 2 end
            w.points = {s, {s[1], m}, {e[1], m}, e}
          elseif not down0 and not down1 then
            local m = s[1] + 18
            w.points = {s, {m, s[2]}, {m, e[2]}, e}
          elseif down1 then
            w.points = {s, {e[1], s[2]}, e}
          else
            w.points = {s, {s[1], e[2]}, e}
          end
        end
      end
    end
  end
  for i, b in ipairs(flow.boxes) do
    flow.w = i == 1 and b.x + b.w or math.max(flow.w, b.x + b.w)
    flow.h = i == 1 and b.y + b.h or math.max(flow.h, b.y + b.h)
  end
  return flow
end

return F
