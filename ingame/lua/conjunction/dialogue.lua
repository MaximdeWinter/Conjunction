-- dialogue.py, as far as the quest board needs it so far: a talk's lines and answers as a tree (from_step, walk,
-- options), how it can end (outcomes) and who talks (PLAYERS, speakers, color). Lists come back as Lua lists (walk,
-- options: Python's generators); outcomes is a set {end = true}.
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local D = {}

D.ENDS = {{"back", "Back to choice"}, {"continue", "End: continue quest"}, {"retry", "End: repeatable"},
          {"fail", "Quest fails"}}
D.END = {}
for _, e in ipairs(D.ENDS) do D.END[e[1]] = e[2] end
D.CODE = {continue = 1, retry = 2, fail = 3}

-- a way out as a quest block's socket name ([a-z_0-9])
function D.socket(e) return P.replace(e, ":", "_") end

D.PLAYER = "player"
D.PLAYERS = Y.map({
  "geralt", Y.map({"label", "Geralt", "template", "gameplay\\templates\\characters\\player\\player.w2ent",
                   "voicetag", "GERALT", "enum", "EQRE_Geralt"}),
  "ciri", Y.map({"label", "Ciri", "template", "gameplay\\templates\\characters\\player\\ciri_player.w2ent",
                 "voicetag", "CIRILLA", "enum", "EQRE_Ciri"}),
})
D.PLAYER_COLOR = "#c4c8d0"
D.COLORS = {"#e0915f", "#6fb4e0", "#8fd07a", "#e07fae", "#b99be6", "#e3c65f", "#5fcbb9", "#e57a7a", "#9fb0ff",
            "#cfa57a", "#7adf9f", "#dcb0ff"}

function D.is_player(who) return who == D.PLAYER or who == "geralt" end

local function label(ref)
  local s = P.str(P.or_(ref, ""))
  s = s:match("([^/]*)$")
  s = P.replace(s, "_", " ")
  -- str.capitalize: the first character upper, the rest lower
  local cps = PYS.cps(s)
  if #cps == 0 then return "" end
  return PYS.upper(PYS.from_cps(cps, 1, 1)) .. PYS.lower(PYS.from_cps(cps, 2))
end
D._label = label

-- {{key, object reference or nil, label}}: key is what a line's `who` says
function D.speakers(a)
  if P.has(a, "object") and not P.has(a, "npc") then return {{D.PLAYER, nil, "Player"}} end
  local out = {{D.PLAYER, nil, "Player"}, {"npc", P.get(a, "npc"), P.or_(label(P.get(a, "npc")), "NPC")}}
  for _, w in ipairs(P.list(P.get(a, "with"))) do out[#out + 1] = {w.who, w.who, label(w.who)} end
  return out
end

-- the player silver; everybody else a colour of their own (from their name)
function D.color(key, a)
  if D.is_player(key) then return D.PLAYER_COLOR end
  local ref = key
  if key == "npc" then ref = P.get(a or {}, "npc") end
  ref = P.or_(ref, key)
  return D.COLORS[P.crc32(ref) % #D.COLORS + 1]
end

local function line(x)
  if Y.is_map(x) and P.has(x, "text") then return x end
  local who, text
  if Y.is_map(x) then
    who = Y.keys(x)[1]
    text = x[who]
  else
    local s = P.str(x)
    local c = s:find(":", 1, true)
    if c then who, text = s:sub(1, c - 1), s:sub(c + 1) else who, text = "npc", s end
  end
  who = PYS.lower(PYS.strip(who))
  return Y.map({"who", D.is_player(who) and D.PLAYER or "npc", "text", PYS.strip(P.str(text))})
end

-- the dialogue of a talk step; the older form (lines "who: text", choices with then) is read too
function D.from_step(a)
  if P.get(a, "dialogue") ~= nil then return a.dialogue end
  local out = Y.list({})
  for _, x in ipairs(P.list(P.get(a, "lines"))) do out[#out + 1] = line(x) end
  if P.T(P.get(a, "choices")) then
    local ch = Y.list({})
    for _, c in ipairs(a.choices) do
      local ls = Y.list({})
      for _, x in ipairs(P.list(P.get(c, "lines"))) do ls[#ls + 1] = line(x) end
      local o = Y.map({"text", P.get(c, "text", ""), "lines", ls, "end", P.or_(P.get(c, "then"), "continue")})
      if P.get(c, "say") == false then o.say = false end
      ch[#ch + 1] = o
    end
    out[#out + 1] = Y.map({"choice", ch})
  end
  return out
end

D.SPLITS = {"choice", "if", "random"}

-- where the first choice / if / random of a list of lines is (nil: none) - 1-based
function D.split_at(ls, start)
  for k = start or 1, #ls do
    for _, s in ipairs(D.SPLITS) do
      if P.has(ls[k], s) then return k end
    end
  end
  return nil
end

-- {{lines, end}} of every way of a choice / if / random; an if's or random's way without an end goes on
function D.ways(x)
  local out = {}
  if P.has(x, "choice") then
    for _, c in ipairs(x.choice) do out[#out + 1] = {P.list(P.get(c, "lines")), P.str(P.or_(P.get(c, "end"), "continue"))} end
    return out
  end
  local brs
  if P.has(x, "random") then
    brs = P.list(P.get(x, "random"))
  else
    brs = {P.or_(P.get(x, "then"), Y.map()), P.or_(P.get(x, "else"), Y.map())}
  end
  for _, br in ipairs(brs) do out[#out + 1] = {P.list(P.get(br, "lines")), P.str(P.or_(P.get(br, "end"), "on"))} end
  return out
end

-- the gestures, moods, poses, ways to join, shots (data/dialogue_tables.lua: made from dialogue.py)
local TB = require("conjunction.data.dialogue_tables")
D.GESTURES, D.MOODS, D.POSES, D.JOINS, D.SHOTS = TB.GESTURES, TB.MOODS, TB.POSES, TB.JOINS, TB.SHOTS
D.AXII_CAST_ANIM, D.AXII_CAST_SECONDS = TB.AXII_CAST_ANIM, TB.AXII_CAST_SECONDS
D.AXII_CAST_ANIM_ALT, D.AXII_DAZED_FACE = TB.AXII_CAST_ANIM_ALT, TB.AXII_DAZED_FACE
D.POSE, D.GESTURE, D.MOOD = {}, {}, {}
for _, p in ipairs(D.POSES) do D.POSE[p[1]] = p[2] end
for _, g in ipairs(D.GESTURES) do D.GESTURE[g[1]] = {g[2], g[3][1]} end
for _, m in ipairs(D.MOODS) do D.MOOD[m[1]] = m[2] end
D.GERALT_COLOR = D.PLAYER_COLOR

local function first_had(list, key, have)
  for _, row in ipairs(list) do
    if row[1] == key then
      if have == nil then return row[3][1] end
      for _, a in ipairs(row[3]) do if have[a] then return a end end
      return nil
    end
  end
  return nil
end
-- the idle animation a pose is for a body that has `have` (a set; nil: not known - the first), or nil
function D.pose_anim(key, have) return first_had(D.POSES, key, have) end
function D.gesture_anim(key, have) return first_had(D.GESTURES, key, have) end
-- {{key, label}} of the poses / gestures a body can take (all while `have` is not known)
function D.poses_for(have)
  local out = {}
  for _, p in ipairs(D.POSES) do if have == nil or D.pose_anim(p[1], have) then out[#out + 1] = {p[1], p[2]} end end
  return out
end
function D.gestures_for(have)
  local out = {}
  for _, g in ipairs(D.GESTURES) do if have == nil or D.gesture_anim(g[1], have) then out[#out + 1] = {g[1], g[2]} end end
  return out
end

-- {{animation, seconds}} of every scene animation radish knows (repo.scenes\sbui.all_animations.repo.yml)
local ALL_ANIMS
function D.all_animations()
  if ALL_ANIMS == nil then
    -- (kept only when read whole: stopped in the middle - TW3SE's 5 s for a call - it kept a third of them)
    local list, whole = {}, false
    pcall(function()
      local radish = require("conjunction.config").load().radish
      local f = io.open(tostring(radish) .. "\\repo.scenes\\sbui.all_animations.repo.yml", "rb")
      if not f then return end
      local text = f:read("a"):gsub("\r\n", "\n")
      f:close()
      local seen = {}
      for name, frames in text:gmatch('\n        %S+:\n            animation: "([^"]+)"\n            frames: (%d+)') do
        if not seen[name] then
          seen[name] = true
          list[#list + 1] = {name, tonumber(frames) / 30.0}
        end
      end
      whole = true
    end)
    if not whole then return list end
    ALL_ANIMS = list
  end
  return ALL_ANIMS
end

-- the animations whose name has every word (in the order of the repo); only: of these (a body's own, a set)
function D.find_animations(words, limit, only)
  limit = limit or 80
  local ws = PYS.split(P.replace(PYS.lower(words or ""), "_", " "))
  local out = {}
  for _, a in ipairs(D.all_animations()) do
    if only == nil or only[a[1]] then
      local n = P.replace(a[1], "_", " ")
      local all = true
      for _, w in ipairs(ws) do if not n:find(w, 1, true) then all = false break end end
      if all then
        out[#out + 1] = a
        if #out >= limit then break end
      end
    end
  end
  return out
end

function D.anim_label(animation) return P.replace(animation, "_", " ") end

D.AFTER_ALL = "@all"
D.OPS = {["="] = true, ["!="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true}

-- an option's conditions, a list (all must hold): '@all', '@<id>', a fact name, {fact, op, value} (dialogue.conditions)
function D.conditions(c)
  local cond = P.get(c, "only_if")
  if not P.T(cond) then return {} end
  if type(cond) == "string" then return {cond} end
  local l = P.list(cond)
  if #l == 3 and type(l[1]) == "string" and type(l[2]) == "string" and D.OPS[l[2]] then return {P.copy_list(l)} end
  local out = {}
  for _, x in ipairs(l) do out[#out + 1] = type(x) == "string" and x or P.copy_list(P.list(x)) end
  return out
end

function D.set_conditions(c, conds)
  if #conds == 0 then Y.remove(c, "only_if") return end
  if #conds == 1 and type(conds[1]) == "string" then c.only_if = conds[1] return end
  local l = {}
  for _, x in ipairs(conds) do l[#l + 1] = type(x) == "table" and Y.list(x) or x end
  c.only_if = Y.list(l)
end

-- every line and answer of the tree
function D.walk(lines, out)
  out = out or {}
  for _, x in ipairs(lines or {}) do
    if P.has(x, "choice") then
      for _, c in ipairs(x.choice) do
        out[#out + 1] = c
        D.walk(P.list(P.get(c, "lines")), out)
      end
    elseif P.has(x, "if") then
      for _, side in ipairs({"then", "else"}) do D.walk(P.list(P.get(P.or_(P.get(x, side), Y.map()), "lines")), out) end
    elseif P.has(x, "random") then
      for _, way in ipairs(P.list(P.get(x, "random"))) do D.walk(P.list(P.get(way, "lines")), out) end
    elseif P.has(x, "script") then
      -- (no line: the scene runs it)
    else
      out[#out + 1] = x
    end
  end
  return out
end

-- every answer of the tree (the dicts of its choices)
function D.options(lines, out)
  out = out or {}
  for _, x in ipairs(lines or {}) do
    if P.has(x, "choice") then
      for _, c in ipairs(x.choice) do
        out[#out + 1] = c
        D.options(P.list(P.get(c, "lines")), out)
      end
    elseif P.has(x, "if") then
      for _, side in ipairs({"then", "else"}) do D.options(P.list(P.get(P.or_(P.get(x, side), Y.map()), "lines")), out) end
    elseif P.has(x, "random") then
      for _, way in ipairs(P.list(P.get(x, "random"))) do D.options(P.list(P.get(way, "lines")), out) end
    end
  end
  return out
end

function D.summary(lines)
  local n_lines, n_answers, voiced = 0, 0, 0
  for _, x in ipairs(D.walk(lines)) do
    if P.has(x, "who") then n_lines = n_lines + 1 else n_answers = n_answers + 1 end
    if P.T(P.get(x, "voice")) then voiced = voiced + 1 end
  end
  local parts = {string.format("%d line%s", n_lines, n_lines ~= 1 and "s" or "")}
  if n_answers > 0 then parts[#parts + 1] = string.format("%d option%s", n_answers, n_answers ~= 1 and "s" or "") end
  if voiced > 0 then parts[#parts + 1] = string.format("%d voiced", voiced) end
  return table.concat(parts, ", ")
end

-- how the dialogue can end: a set of continue / retry / fail / path:x / out:x (the lines over: it goes on)
function D.outcomes(lines)
  local out, done = {}, {}
  local function run(ls, start, after_all)
    done[ls] = done[ls] or {}
    if done[ls][start] then return end
    done[ls][start] = true
    local k = D.split_at(ls, start)
    if k == nil then
      after_all()
      return
    end
    local after = after_all
    if k + 1 <= #ls then after = function() run(ls, k + 1, after_all) end end
    for _, w in ipairs(D.ways(ls[k])) do
      local sub, e = w[1], w[2]
      if e ~= "back" and e ~= "up" then
        if e == "on" then run(sub, 1, after) else run(sub, 1, function() out[e] = true end) end
      end
    end
  end
  run(lines, 1, function() out.continue = true end)
  local kept = {}
  for e in pairs(out) do
    if D.CODE[e] or P.startswith(e, "path:") or P.startswith(e, "out:") then kept[e] = true end
  end
  if next(kept) == nil then kept.continue = true end
  return kept
end

-- the set's ends sorted (Python's sorted(set))
function D.sorted(set)
  local out = {}
  for e in pairs(set) do out[#out + 1] = e end
  require("conjunction.pysort").sort(out)
  return out
end

return D
