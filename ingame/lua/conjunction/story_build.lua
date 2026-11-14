-- story.json built in the game (story.build with story_index.index): every quest graph of the game read once, the
-- journal's quests found in them, where each lies in the story's structure, what it waits for and who sets that, what
-- it sets - written as the app writes it (the story map reads it: story.lua, ui/story_window.lua).
--   SB.build(log [, depot]) -> data       in a coroutine (ed:job): a little each frame
--   SB.index(depot, log) -> {files, journals}     SB.file_info(depot, path)     SB.journal_of(depot, path, texts)
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local CFG = require("conjunction.config")
local PATHS = require("conjunction.paths")
local PYS = require("conjunction.pystr")
local PS = require("conjunction.pysort")
local R = require("conjunction.pyre")
local CR = require("conjunction.cr2w")
local CE = require("conjunction.cr2w_edit")
local QR = require("conjunction.questread")
local SB = {}

SB.ROOT = [[quests\witcher3_structure.w2phase]]
SB.ROOTS = {{"The Witcher 3", SB.ROOT}, {"Hearts of Stone", [[dlc\ep1\data\quests\cyrograf_structure.w2phase]]},
            {"Blood and Wine", [[dlc\bob\data\quests\bob_phase.w2phase]]}}
SB.LEVELS = {[[gameplay\globals\quest_levels.csv]], [[dlc\ep1\data\gameplay\globals\quest_levels.csv]],
             [[dlc\bob\data\gameplay\globals\quest_levels.csv]]}
SB.INPUTS = {CQuestPhaseInputBlock = true, CQuestStartBlock = true}
SB.QUEST_NAME = R.compile([[(^|[\\ _-])(q|sq|mq|cg|th|ard|ms|nml|lw|ff)\d{2,}]], R.I)
SB.FACT_SCRIPTS = {TryToAddUniqueFact = "uniqueFactName", ModifyFactValueQuest = "fact"}
SB.SCENE_FACT_SCRIPTS = {AddFact_S = true}
SB.GAME_DLC = R.compile([[^dlc\\(ep1|bob|dlc\d+)\\]], R.I)
SB.GAMES = {{"dlc\\ep1\\", "Hearts of Stone"}, {"dlc\\bob\\", "Blood and Wine"}, {"dlc\\", "Free DLC"}}
SB.TESTS = {"demo_files", "\\test", "testing"}

local NONE = CE.NONE
local function yield() if coroutine.isyieldable() then coroutine.yield() end end
local function basename(p) return (tostring(p or ""):gsub("^.*[\\/]", "")) end
local function is_ref(v, kind) return QR.is_ref(v, kind) end
local function is_dict(v) return type(v) == "table" and CE.is_dict(v) end
local function is_list(v) return type(v) == "table" and not CE.is_dict(v) and getmetatable(v) ~= CE.BYTES and
                                 not (v[1] == "export" or v[1] == "import" or v[1] == "string") end
local function get(d, k) if is_dict(d) then local v = d[k] if v == NONE then return nil end return v end end
local function T(v)
  if v == nil or v == false or v == "" or v == 0 or v == NONE then return false end
  if type(v) == "table" and getmetatable(v) ~= CE.BYTES and next(v) == nil then return false end
  return true
end
local function str_value(v) return type(v) == "string" end

-- --- sets (Python's set / frozenset of strings and tuples)
local function set_new() return {} end
local function key_of(x) if type(x) == "table" then return x[1] .. "\0" .. x[2] end return x end
local function set_add(s, x) s[key_of(x)] = x end
local function set_union(a, b)
  local out = {}
  for k, v in pairs(a) do out[k] = v end
  for k, v in pairs(b) do out[k] = v end
  return out
end
local function set_list(s) local out = {} for _, v in pairs(s) do out[#out + 1] = v end return out end
local function set_sorted(s) return PS.sorted(set_list(s)) end
local function set_has(s, x) return s[key_of(x)] ~= nil end
local function set_n(s) local n = 0 for _ in pairs(s) do n = n + 1 end return n end

function SB.game_file(path)
  local low = PYS.lower(path)
  if low:sub(1, 12) == "conjunction\\" then return false end
  return low:sub(1, 4) ~= "dlc\\" or SB.GAME_DLC:match(path) ~= nil
end
function SB.game_of(path)
  local low = PYS.lower(path)
  for _, g in ipairs(SB.GAMES) do if low:sub(1, #g[1]) == g[1] then return g[2] end end
  return "The Witcher 3"
end
function SB.quest_like(name, path)
  return SB.QUEST_NAME:search(basename(path or "")) ~= nil or SB.QUEST_NAME:search(name or "") ~= nil or
         PYS.upper(name or ""):sub(1, 5) == "QUEST"
end
local function strip_chars(s, chars)
  local set = {}
  for c in chars:gmatch(".") do set[c] = true end
  local a, b = 1, #s
  while a <= b and set[s:sub(a, a)] do a = a + 1 end
  while b >= a and set[s:sub(b, b)] do b = b - 1 end
  return s:sub(a, b)
end
function SB.code_of(qid)
  local m = SB.QUEST_NAME:search(basename((qid:gsub("#.*$", ""))))
  if not m then return nil end
  return PYS.lower(strip_chars(m:group(0), "\\ _-"))
end

-- every factId named in a decoded value - conditions nested in other conditions too (story._facts_in)
function SB.facts_in(f, value, seen, out)
  seen, out = seen or {}, out or {}
  if is_ref(value, "export") then
    local i = value[2]
    if seen[i] or not (i > 0 and i <= #f.exports) then return out end
    seen[i] = true
    return SB.facts_in(f, CE.decode_ordered(f, f.exports[i][5]), seen, out)
  end
  if is_dict(value) then
    for _, k in ipairs(CE.keys(value)) do
      local v = value[k]
      if (k == "factId" or k == "factId1" or k == "factId2") and str_value(v) and v ~= "" then
        out[#out + 1] = v
      else
        SB.facts_in(f, v, seen, out)
      end
    end
  elseif type(value) == "table" and getmetatable(value) ~= CE.BYTES and not is_ref(value, "import") and
         not is_ref(value, "string") then
    for _, v in ipairs(value) do SB.facts_in(f, v, seen, out) end
  end
  return out
end

-- every imported file named in a decoded value (story._imports_in)
function SB.imports_in(f, value, seen, out)
  seen, out = seen or {}, out or {}
  if is_ref(value, "import") then
    out[#out + 1] = value[2]
  elseif is_ref(value, "export") then
    local i = value[2]
    if not seen[i] and i > 0 and i <= #f.exports then
      seen[i] = true
      SB.imports_in(f, CE.decode_ordered(f, f.exports[i][5]), seen, out)
    end
  elseif is_dict(value) then
    for _, k in ipairs(CE.keys(value)) do SB.imports_in(f, value[k], seen, out) end
  elseif type(value) == "table" and getmetatable(value) ~= CE.BYTES and not is_ref(value, "string") then
    for _, v in ipairs(value) do SB.imports_in(f, v, seen, out) end
  end
  return out
end

local function journal_file(f, value)
  local found = {}
  for _, x in ipairs(SB.imports_in(f, value)) do if PYS.lower(x):sub(-8) == ".journal" or x:sub(-8) == ".journal" then
    if x:sub(-8) == ".journal" then found[#found + 1] = x end
  end end
  return found[#found]
end

-- a CR2W string value at i (0-based): its first byte - ascii flag 0x80, more-bytes flag 0x40, 6 bits of the length
local function cr2w_str(data, i)
  local b = data:byte(i + 1)
  local n, shift, more = b & 0x3F, 6, b & 0x40
  i = i + 1
  while more ~= 0 do
    b = data:byte(i + 1)
    n = n | ((b & 0x7F) << shift)
    shift, more, i = shift + 7, b & 0x80, i + 1
  end
  local raw = data:sub(i + 1, i + n)
  if utf8.len(raw) then return raw end
  local out = {}                                        -- (latin-1)
  for k = 1, #raw do out[k] = utf8.char(raw:byte(k)) end
  return table.concat(out)
end

-- the facts a scene's AddFact_S scripts set (story_index._scene_facts)
function SB.scene_facts(f)
  local out = {}
  for _, e in ipairs(f.exports) do
    if e[1] == "CStorySceneScript" then
      local chunk = e[5]
      local props = f:props(chunk)
      local fn
      for _, p in ipairs(props) do
        if p[1] == "functionName" then fn = string.unpack("<I2", chunk, p[3] + 1) break end
      end
      if fn ~= nil and SB.SCENE_FACT_SCRIPTS[f.names[fn + 1]] then
        local last = props[#props]
        local i = (last and (last[3] + last[4]) or 1) + 2
        while i + 8 <= #chunk do
          local nm, tp = string.unpack("<I2I2", chunk, i + 1)
          if nm == 0 or nm >= #f.names or tp >= #f.names then break end
          local size = string.unpack("<I4", chunk, i + 5)
          local vstart = i + 8
          local name = f.names[nm + 1]
          if (name == "factName" or name == "factId") and size > 4 then
            if f.names[tp + 1] == "String" then
              out[#out + 1] = cr2w_str(chunk, vstart)
            elseif f.names[tp + 1] == "CName" then
              out[#out + 1] = f.names[string.unpack("<I2", chunk, vstart + 1) + 1]
            end
          end
          if size < 4 then break end
          i = vstart + size - 4
        end
      end
    end
  end
  local kept = {}
  for _, x in ipairs(out) do if x and x ~= "" then kept[#kept + 1] = x end end
  return kept
end

-- the start conditions in a condition tree that say when a quest can begin (story_index._gate)
function SB.gate(f, value, gates)
  if is_ref(value, "export") and value[2] > 0 and value[2] <= #f.exports then
    local e = f.exports[value[2]]
    local cls = e[1]
    local v = CE.decode_ordered(f, e[5])
    if cls == "CQuestFactsDBCondition" or cls == "CQuestFactsDBExCondition" then
      for _, k in ipairs({"factId", "factId1"}) do
        if T(get(v, k)) then set_add(gates.facts, v[k]) end
      end
    elseif cls == "CQuestJournalStatusCondition" then
      local j = journal_file(f, get(v, "entry"))
      if j then
        local st = get(v, "status")
        set_add(gates.quests, {j, T(st) and st or "JS_Active"})
      end
    elseif cls == "W3QuestCond_World" then
      if T(get(v, "currentArea")) then set_add(gates.areas, v.currentArea) end
    elseif cls == "W3QuestCond_PlayerLevel" then
      if T(get(v, "level")) then
        local l = math.tointeger(v.level) or math.tointeger(math.floor(tonumber(v.level)))
        if gates.level == nil or l > gates.level then gates.level = l end
      end
    elseif cls == "W3QuestCond_WasNoticeboardVisited" then
      if T(get(v, "entityName")) then set_add(gates.boards, v.entityName) end
    elseif cls == "CQCHasItem" or cls == "W3QuestCond_IsItemQuantityMet" or cls == "CQCHasItemGE" then
      local item = get(v, "item")
      if not T(item) then item = get(v, "itemName") end
      if str_value(item) then set_add(gates.items, item) end
    elseif cls == "W3QuestCond_BookHasBeenRead" or cls == "W3QuestCond_BookHasBeenReadExt" then
      local book = get(v, "bookName")
      if is_dict(book) then book = get(book, "itemName") end
      if str_value(book) then set_add(gates.items, book) end
    end
    for _, k in ipairs(CE.keys(v)) do
      if k == "conditions" or k == "condition" or k == "checkType" then SB.gate(f, v[k], gates) end
    end
  elseif type(value) == "table" and getmetatable(value) ~= CE.BYTES and not is_dict(value) and
         not is_ref(value, "import") and not is_ref(value, "string") and not is_ref(value, "export") then
    for _, x in ipairs(value) do SB.gate(f, x, gates) end
  end
end

local function new_gates()
  return {facts = set_new(), quests = set_new(), areas = set_new(), boards = set_new(), items = set_new(), level = nil}
end

-- what a quest file does (story_index.file_info): its journal quests, the facts it sets, the scenes it plays, the
-- phase files it plays, the gates on its way in
function SB.file_info(depot, path)
  local g, f = QR.open_graph(depot, path)
  local info = {journals = {}, sets = set_new(), scenes = set_new(), children = set_new(), gates = new_gates()}
  local stack = {g}
  while #stack > 0 do
    local gr = table.remove(stack)
    for _, i in ipairs(gr.ins) do
      local b = gr.blocks[i]
      local cls, bp = b[1], b[2]
      if cls == "CQuestFactsDBChangingBlock" then
        if T(get(bp, "factID")) then set_add(info.sets, bp.factID) end
      elseif cls == "CQuestScriptBlock" and SB.FACT_SCRIPTS[get(bp, "functionName") or ""] then
        local key = SB.FACT_SCRIPTS[bp.functionName]
        local params = get(bp, "parameters")
        for _, p in ipairs(T(params) and params or {}) do
          if is_dict(p) and get(p, "name") == key and str_value(get(p, "value")) then set_add(info.sets, p.value) end
        end
      elseif cls == "CQuestSceneBlock" or cls == "CQuestInteractionDialogBlock" or cls == "CQuestContextDialogBlock" then
        for _, k in ipairs({"scene", "targetScene"}) do
          local s = get(bp, k)
          if is_ref(s, "import") then set_add(info.scenes, s[2]) end
        end
      elseif cls == "CJournalQuestBlock" then
        local j = journal_file(f, get(bp, "questEntry"))
        if j then
          local had = false
          for _, x in ipairs(info.journals) do if x == j then had = true end end
          if not had then info.journals[#info.journals + 1] = j end
        end
      elseif cls == "CQuestPhaseBlock" then
        local ph = get(bp, "phase")
        if is_ref(ph, "import") then set_add(info.children, ph[2]) end
      end
      local emb = get(bp, "embeddedGraph")
      if is_ref(emb, "export") then stack[#stack + 1] = QR.Graph(f, emb[2]) end
    end
  end
  -- the way in: from the inputs to the first journal quest block, the gates on the way (embedded graphs followed)
  local todo, gating = {g}, true
  while #todo > 0 and gating do
    local gr = table.remove(todo, 1)
    local start = {}
    for _, i in ipairs(gr.ins) do if SB.INPUTS[gr.blocks[i][1]] then start[#start + 1] = i end end
    if #start == 0 and #gr.order > 0 then start = {gr.order[1]} end
    local seen, queue = {}, {}
    for _, i in ipairs(start) do seen[i] = true queue[#queue + 1] = i end
    while #queue > 0 do
      local i = table.remove(queue, 1)
      local b = gr.blocks[i]
      local cls, bp, outs = b[1], b[2], b[3]
      if cls == "CJournalQuestBlock" then
        gating = false
        break
      end
      if cls == "CQuestPauseConditionBlock" then
        SB.gate(f, get(bp, "conditions"), info.gates)
      elseif cls == "CQuestPhaseBlock" then
        local emb = get(bp, "embeddedGraph")
        if is_ref(emb, "export") then todo[#todo + 1] = QR.Graph(f, emb[2]) end
      end
      local branch = false
      if cls == "CQuestConditionBlock" then
        for _, o in ipairs(outs) do if o[1] == "False" and gr.blocks[o[2]] then branch = true end end
        if not branch then SB.gate(f, get(bp, "questCondition"), info.gates) end
      end
      for _, o in ipairs(outs) do
        local target = o[2]
        if gr.blocks[target] and not seen[target] then
          seen[target] = true
          queue[#queue + 1] = target
        end
      end
    end
  end
  return info, f
end

-- a quest's journal entry: {title, type, world, base} (nil: no such file)
function SB.journal_of(depot, path, texts)
  if not path or path == "" or not depot:exists(path) then return nil end
  local f = CR.parts(depot:read(path))[1]
  for _, e in ipairs(f.exports) do
    if e[1] == "CJournalQuest" then
      local v = CE.decode_ordered(f, e[5])
      local title = get(v, "title")
      local sid = is_ref(title, "string") and title[2] or nil
      local t = sid and texts[sid] or nil
      if not T(t) then t = T(get(v, "baseName")) and v.baseName or "" end
      local world = get(v, "world")
      return Y.map({"title", t, "type", T(get(v, "type")) and v.type or "Side", "world", world == nil and Y.null or world,
                    "base", T(get(v, "baseName")) and v.baseName or ""})
    end
  end
  return nil
end

function SB.texts()
  local path = CFG.load().game .. "\\content\\content0\\en.w3strings"
  local data = w3.fs.read(path)
  if not data then return {} end
  local _, _, texts = require("conjunction.w3strings").read(data, "en")
  return texts or {}
end

-- every quest file read (story_index.index) -> {files = {path: info}, journals = {journal file: entry}}
function SB.index(depot, log)
  local files = {}
  for _, p in ipairs(depot:glob("", "")) do
    if (p:sub(-8) == ".w2phase" or p:sub(-8) == ".w2quest") and SB.game_file(p) then files[#files + 1] = p end
  end
  files = PS.sorted(files)
  local out, order, scene_cache, nscenes = {}, {}, {}, 0
  for k, path in ipairs(files) do
    local ok, info = pcall(SB.file_info, depot, path)
    if not ok then
      log(string.format("[story] %s: %s", path, tostring(info)))
    else
      for _, s in ipairs(set_sorted(info.scenes)) do
        if scene_cache[s] == nil then
          nscenes = nscenes + 1
          local ok2, facts = pcall(function()
            if not depot:exists(s) then return {} end
            return SB.scene_facts(CR.parts(depot:read(s))[1])
          end)
          scene_cache[s] = ok2 and facts or {}
        end
        for _, x in ipairs(scene_cache[s]) do set_add(info.sets, x) end
      end
      local g = info.gates
      local quests = {}
      for _, q in ipairs(set_list(g.quests)) do quests[#quests + 1] = {q[1], q[2]} end
      out[path] = {journals = info.journals, sets = set_sorted(info.sets), scenes = set_sorted(info.scenes),
                   children = set_sorted(info.children),
                   gates = {facts = set_sorted(g.facts), quests = PS.sorted(quests), areas = set_sorted(g.areas),
                            boards = set_sorted(g.boards), items = set_sorted(g.items), level = g.level}}
      order[#order + 1] = path
    end
    if (k - 1) % 100 == 0 then
      log(string.format("[story] %d/%d quest files read, %d scenes", k - 1, #files, nscenes))
      yield()
    end
  end
  local texts = SB.texts()
  local journals, jorder = {}, {}
  local function want(j)
    if journals[j] == nil then
      journals[j] = SB.journal_of(depot, j, texts) or false
      jorder[#jorder + 1] = j
    end
  end
  for _, p in ipairs(order) do
    local info = out[p]
    for _, j in ipairs(info.journals) do want(j) end
    for _, q in ipairs(info.gates.quests) do want(q[1]) end
  end
  local jkept, jkorder = {}, {}
  for _, j in ipairs(jorder) do if journals[j] then jkept[j] = journals[j] jkorder[#jkorder + 1] = j end end
  return {files = out, order = order, journals = jkept, jorder = jkorder}
end

-- --- the story's structure (story.Walker): through the roots' graphs, where each file sits, the facts waited for on
-- the way to it, the quests passed before it
local Walker = {}
Walker.__index = Walker
local function walker(depot) return setmetatable({depot = depot, quests = {}, parts = {}, seen_files = {}}, Walker) end

function Walker:walk_file(path, where, gates, after)
  if self.seen_files[path] or not self.depot:exists(path) then return end
  self.seen_files[path] = true
  local g, f = QR.open_graph(self.depot, path)
  self:walk_graph(g, f, path, where, gates, after)
end

local function copy(t) local o = {} for i, v in ipairs(t) do o[i] = v end return o end
local function plus(t, x) local o = copy(t) o[#o + 1] = x return o end

function Walker:walk_graph(g, f, origin, where, gates, after)
  local start = {}
  for _, i in ipairs(g.ins) do if SB.INPUTS[g.blocks[i][1]] then start[#start + 1] = i end end
  if #start == 0 and #g.order > 0 then start = {g.order[1]} end
  local state, queue = {}, {}
  for _, i in ipairs(start) do state[i] = {gates, after} queue[#queue + 1] = i end
  while #queue > 0 do
    local i = table.remove(queue, 1)
    local b = g.blocks[i]
    local cls, bp, outs = b[1], b[2], b[3]
    local gs, af = state[i][1], state[i][2]
    local mine
    if cls == "CQuestPauseConditionBlock" then
      gs = set_union(gs, {})
      for _, x in ipairs(SB.facts_in(f, get(bp, "conditions"))) do set_add(gs, x) end
    elseif cls == "CQuestPhaseBlock" then
      local name = T(get(bp, "name")) and bp.name or ""
      local ph, emb = get(bp, "phase"), get(bp, "embeddedGraph")
      local file = is_ref(ph, "import") and ph[2] or nil
      if SB.quest_like(name, file) then
        mine = file or (origin .. "#" .. i)
        if not self.quests[mine] then
          self.quests[mine] = {id = mine, name = name ~= "" and name or basename(file or ""), path = copy(where),
                               gates = set_sorted(gs), after = set_sorted(af)}
        end
      elseif file then
        self.parts[#self.parts + 1] = {name = name, path = copy(where), file = file}
        self:walk_file(file, plus(where, name ~= "" and name or basename(file)), gs, af)
      elseif is_ref(emb, "export") then
        self.parts[#self.parts + 1] = {name = name, path = copy(where), file = origin .. "#" .. i}
        self:walk_graph(QR.Graph(f, emb[2]), f, origin, plus(where, name ~= "" and name or "phase"), gs, af)
      end
    end
    local has_false = false
    if cls == "CQuestConditionBlock" then
      for _, o in ipairs(outs) do if o[1] == "False" and g.blocks[o[2]] then has_false = true end end
    end
    for _, o in ipairs(outs) do
      local target = o[2]
      if g.blocks[target] and state[target] == nil then
        local g2 = gs
        if cls == "CQuestConditionBlock" and not has_false then
          g2 = set_union(gs, {})
          for _, x in ipairs(SB.facts_in(f, get(bp, "questCondition"))) do set_add(g2, x) end
        end
        local af2 = af
        if mine then af2 = set_union(af, {}) set_add(af2, mine) end
        state[target] = {g2, af2}
        queue[#queue + 1] = target
      end
    end
  end
end

local function levels(depot)
  local out = {}
  for _, path in ipairs(SB.LEVELS) do
    if depot:exists(path) then
      local text = depot:read(path)
      local lines = {}
      for line in (text:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
      for k = 2, #lines do
        local name, level = lines[k]:match("^(.*);([^;]*)$")
        if name and name ~= "" and PYS.strip(level):match("^%d+$") then
          out[PYS.lower(PYS.strip(name))] = math.tointeger(tonumber(PYS.strip(level)))
        end
      end
    end
  end
  return out
end

-- story.build: every journal quest of the game -> {version = 2, quests = {...}}, written to story.json
function SB.build(log, depot)
  log = log or print
  depot = depot or require("conjunction.depot").open(CFG.load().game)
  local idx = SB.index(depot, log)
  local files, forder = {}, {}
  for _, p in ipairs(idx.order) do if SB.game_file(p) then files[p] = idx.files[p] forder[#forder + 1] = p end end
  local journals, jorder = {}, {}
  for _, j in ipairs(idx.jorder) do if SB.game_file(j) then journals[j] = idx.journals[j] jorder[#jorder + 1] = j end end
  local w = walker(depot)
  for _, r in ipairs(SB.ROOTS) do
    if depot:exists(r[2]) then w:walk_file(r[2], {r[1]}, {}, {}) end
  end
  yield()
  local where = {}
  for _, p in ipairs(w.parts) do where[p.file] = plus(p.path, p.name) end
  for _, q in pairs(w.quests) do where[q.id] = q.path end
  local containers = {}
  for _, p in ipairs(w.parts) do if not p.file:find("#", 1, true) then containers[p.file] = true end end
  for _, r in ipairs(SB.ROOTS) do containers[r[2]] = true end
  containers[ [[quests\witcher3_quest.w2quest]] ] = true
  local parents = {}
  for _, p in ipairs(forder) do
    for _, c in ipairs(files[p].children) do
      parents[c] = parents[c] or {}
      parents[c][p] = true
    end
  end
  local owners = {}
  for _, p in ipairs(forder) do
    for k, j in ipairs(files[p].journals) do
      owners[j] = owners[j] or {}
      owners[j][#owners[j] + 1] = {k - 1, p}
    end
  end
  local function firsts(j)
    local mine, out = owners[j] or {}, {}
    for _, x in ipairs(mine) do if x[1] == 0 then out[#out + 1] = x[2] end end
    if #out == 0 then for _, x in ipairs(mine) do out[#out + 1] = x[2] end end
    return out
  end
  local function rep_key(p)
    local _, n = p:gsub("\\", "")
    return {containers[p] == true, PYS.lower(p):find("bugfix", 1, true) ~= nil,
            p:find("\\quest_files\\", 1, true) ~= nil or p:find("\\phases\\", 1, true) ~= nil, n, p}
  end
  local reps = {}
  for _, j in ipairs(jorder) do
    if owners[j] then
      reps[j] = PS.sorted(firsts(j), rep_key)[1]          -- (min: the first of the smallest, as sorted is stable)
    end
  end
  local memo = {}
  local function plain(js)
    local out = {}
    for _, x in ipairs(js) do
      local jj = journals[x]
      local title = jj and jj.title or ""
      if not PYS.lower(x):find("replacer", 1, true) and title:sub(1, 12) ~= "Ciri's Story" then out[#out + 1] = x end
    end
    if #out == 0 then return copy(js) end
    return out
  end
  local function primary(p)
    local js = plain(files[p].journals)
    for _, j in ipairs(js) do if reps[j] == p then return j end end
    return js[1]
  end
  local quest_of
  quest_of = function(p, depth)
    depth = depth or 0
    if memo[p] ~= nil then return memo[p] or nil end
    memo[p] = false                                       -- (a loop, a container: none)
    local info = files[p]
    if containers[p] then
      -- nothing
    elseif info and #info.journals > 0 then
      memo[p] = primary(p)
    elseif depth < 8 then
      local ks, above = {}, {}
      for k in pairs(parents[p] or {}) do ks[#ks + 1] = k end
      for _, x in ipairs(PS.sorted(ks)) do                -- (Python walks a set here: its order is the hash's)
        local q = quest_of(x, depth + 1)
        if q then above[#above + 1] = q end
      end
      above = PS.sorted(above)
      memo[p] = above[1] or false
    end
    return memo[p] or nil
  end
  local function where_of(p, depth)
    depth = depth or 0
    if where[p] ~= nil or depth > 8 then return where[p] end
    local ks = {}
    for k in pairs(parents[p] or {}) do ks[#ks + 1] = k end
    for _, x in ipairs(PS.sorted(ks)) do
      local r = where_of(x, depth + 1)
      if r then return r end
    end
    return nil
  end
  local setters = {}
  for _, p in ipairs(forder) do
    local low, test = PYS.lower(p), false
    for _, t in ipairs(SB.TESTS) do if low:find(t, 1, true) then test = true end end
    if not test then
      for _, fact in ipairs(files[p].sets) do
        local q = quest_of(p)
        if q then
          setters[fact] = setters[fact] or {}
          setters[fact][q] = true
        end
      end
    end
  end
  yield()
  local lv = levels(depot)
  local codes = {}
  for _, j in ipairs(jorder) do
    if reps[j] then codes[j] = SB.code_of(reps[j]) or SB.code_of(j) end
  end
  local function setters_of(fact, j)
    local who = {}
    for s in pairs(setters[fact] or {}) do if s ~= j then who[s] = true end end
    local m = SB.QUEST_NAME:match(fact)
    if m then
      local named = {}
      local want = PYS.lower(strip_chars(m:group(0), "\\ _-"))
      for s in pairs(who) do if (codes[s] or "") == want then named[s] = true end end
      if next(named) then who = named end
    end
    local list = {}
    for s in pairs(who) do list[#list + 1] = s end
    if #list > 3 then return {} end
    return PS.sorted(list)
  end
  local quests = {}
  for _, j in ipairs(jorder) do
    local jj = journals[j]
    if reps[j] then
      local mine, first, rep = owners[j], firsts(j), reps[j]
      local gates = new_gates()
      for _, p in ipairs(first) do
        local g = files[p].gates
        for _, key in ipairs({"facts", "areas", "boards", "items"}) do
          for _, x in ipairs(g[key]) do set_add(gates[key], x) end
        end
        for _, x in ipairs(g.quests) do set_add(gates.quests, {x[1], x[2]}) end
        if g.level then gates.level = math.max(gates.level or 0, g.level) end
        local wq = w.quests[p]
        for _, x in ipairs(wq and wq.gates or {}) do set_add(gates.facts, x) end
      end
      local why = Y.map()
      for _, fact in ipairs(set_sorted(gates.facts)) do
        if not (setters[fact] and setters[fact][j]) then        -- (its own fact: no other quest's)
          for _, s in ipairs(setters_of(fact, j)) do
            if why[s] == nil then why[s] = "sets " .. fact end
          end
        end
      end
      local gq = PS.sorted(set_list(gates.quests))
      for _, x in ipairs(gq) do
        local other, status = x[1], x[2]
        if other ~= j and journals[other] then why[other] = "its journal entry " .. PYS.lower(status:sub(4)) end
      end
      if #Y.keys(why) == 0 then
        for _, p in ipairs(first) do                       -- (the story's order: the quests passed on the way to it)
          local wq = w.quests[p]
          for _, a in ipairs(wq and wq.after or {}) do
            local s = quest_of(a)
            if s and s ~= j and why[s] == nil then why[s] = "comes before it in the story" end
          end
        end
      end
      if #Y.keys(why) == 0 then                            -- (shown inside another quest's graph: after that quest)
        for _, x in ipairs(mine) do
          local k, p = x[1], x[2]
          if k > 0 and not containers[p] and files[p].journals[1] ~= j then
            local o = files[p].journals[1]
            if why[o] == nil then why[o] = "shown within it" end
            break
          end
        end
      end
      local sets = {}
      for _, p in ipairs(forder) do
        if quest_of(p) == j then for _, x in ipairs(files[p].sets) do set_add(sets, x) end end
      end
      local fl = {}
      for _, x in ipairs(mine) do set_add(fl, x[2]) end
      local by = PS.sorted(Y.keys(why))
      local lvl = lv[PYS.lower(jj.base or "")]
      quests[#quests + 1] = Y.map({
        "id", j, "file", rep, "files", Y.list(set_sorted(fl)), "title", jj.title, "type", jj.type,
        "world", jj.world, "base", jj.base, "level", lvl == nil and Y.null or lvl,
        "code", codes[j] == nil and Y.null or codes[j], "game", SB.game_of(rep),
        "path", Y.list(where_of(rep) or {SB.game_of(rep)}),
        "gates", Y.list(set_sorted(gates.facts)), "areas", Y.list(set_sorted(gates.areas)),
        "boards", Y.list(set_sorted(gates.boards)), "items", Y.list(set_sorted(gates.items)),
        "min_level", gates.level == nil and Y.null or gates.level, "by", Y.list(by), "why", why,
        "sets", Y.list(set_sorted(sets))})
    end
  end
  quests = PS.sorted(quests, function(q) return q.id end)
  local data = Y.map({"version", 2, "quests", Y.list(quests)})
  J.write(require("conjunction.story").file(), data, {indent = 1})
  local linked = 0
  for _, q in ipairs(quests) do if #q.by > 0 then linked = linked + 1 end end
  log(string.format("[story] %d quests, %d after another one, from %d quest files", #quests, linked, #forder))
  return data
end

return SB
