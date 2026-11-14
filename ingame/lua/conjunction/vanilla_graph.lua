-- vanilla_graph.py: a game quest graph as the quest graph window shows it - read from the lossless tree (cr2w_tree),
-- each block with what it does in a line or three, its named inputs and outputs, its links, and where it stands, laid
-- out left to right (the game's cooked files keep no positions).
--   local qf = V.QuestFile(depot, path [, data])    a .w2phase / .w2quest: its tree, its main graph (qf.root)
--   local g = qf:graph(n)                           the graph object n: g.order (block numbers), g.blocks {n: Block},
--                                                   g.links {{from, output, to, input}}
--   V.place(g)                                      x, y, w, h of every block; g.wires: {{link, points}}
-- A Block: n, cls, name, family, title, lines, inputs, outputs (socket names in order), opens ({"graph", n} inside
-- this file or {"file", path}), kind (blocks.lua). Socket names are the file's; a single unnamed socket is "".
-- The V.py_* helpers are Python's ways with the tree's values (an int, str(), truth, `not in ("", None, [], 0)`).
local TR = require("conjunction.cr2w_tree")
local P = require("conjunction.py")
local PS = require("conjunction.pysort")
local S = require("conjunction.pystr")
local V = {}

-- --- Python's ways with the tree's values
local is = TR.is
-- isinstance(v, int): an integer, a yes/no, a soft handle, a text id
function V.isint(v)
  return math.type(v) == "integer" or type(v) == "boolean" or is(v, TR.SOFT) or is(v, TR.LOC)
end
function V.ival(v)
  if type(v) == "boolean" then return v and 1 or 0 end
  if is(v, TR.SOFT) or is(v, TR.LOC) then return v.n end
  return v
end
-- isinstance(v, int) and v > 0: an object of the file (a soft handle counts as Python's int does)
function V.obj_ref(v) return V.isint(v) and V.ival(v) > 0 end
local function is_list(v)
  if type(v) ~= "table" then return false end
  local mt = getmetatable(v)
  return mt == nil or mt == TR.ARRAY or mt == TR.TAGS or mt == TR.STRUCT
end
V.is_list = is_list
-- bool(v)
function V.truth(v)
  if v == nil or v == false or v == 0 or v == "" then return false end
  if is(v, TR.WIDE) then return v.s ~= "" end
  if is(v, TR.SOFT) or is(v, TR.LOC) then return v.n ~= 0 end
  if is(v, TR.RAW) or is(v, TR.GUID) then return v.b ~= "" end
  if is_list(v) then return #v > 0 end
  return true
end
-- v in ("", None, [], 0)
function V.empty(v)
  if v == nil or v == false or v == 0 or v == "" then return true end
  if is(v, TR.WIDE) then return v.s == "" end
  if is(v, TR.SOFT) or is(v, TR.LOC) then return v.n == 0 end
  if is_list(v) then return #v == 0 end
  return false
end
-- a or b: the first true one, else the last
function V.or_(...)
  local n = select("#", ...)
  for i = 1, n - 1 do
    local v = select(i, ...)
    if V.truth(v) then return v end
  end
  return (select(n, ...))
end
-- str(v) of a tree value
function V.str(v)
  if is(v, TR.WIDE) then return v.s end
  if is(v, TR.SOFT) or is(v, TR.LOC) then return tostring(v.n) end
  if type(v) == "table" and getmetatable(v) ~= nil and not is_list(v) then return tostring(v) end
  return P.str(v)
end
-- a string value as it is (a wide one's text)
function V.s(v)
  if is(v, TR.WIDE) then return v.s end
  return v
end
-- f"{x:g}"
function V.g(x)
  if type(x) == "boolean" then x = x and 1 or 0 end
  return string.format("%g", x)
end
local function strip(v) return S.strip(V.str(v)) end
local function basename(p) return (p:gsub("^.*[\\/]", "")) end
V.basename = basename
-- a struct's value by name (Struct.get)
function V.sget(st, name, default)
  if type(st) ~= "table" then return default end
  return TR.sget(st, name, default)
end

V.FAMILY = {
  flow = "#7d8fa8", wait = "#d9a441", ["if"] = "#e0b85a", facts = "#5cb85c", scene = "#a779d9",
  journal = "#4fb3bf", script = "#e08a4f", world = "#6f9bd1", note = "#8c8c70",
  check = "#e0b85a", talk = "#a779d9", people = "#e08a4f", fx = "#c97fb0", items = "#c9b458",
  notes = "#8c8c70", game = "#6a6a74",
  template = "#9b8cff",
}
V.CLASS_FAMILY = {
  CQuestPhaseInputBlock = "flow", CQuestPhaseOutputBlock = "flow", CQuestStartBlock = "flow",
  CQuestEndBlock = "flow", CQuestAndBlock = "flow", CQuestXorBlock = "flow", CQuestRandomBlock = "flow",
  CQuestCheckpointBlock = "flow", CQuestPhaseBlock = "flow", CQuestCutControlBlock = "flow",
  CQuestPauseConditionBlock = "wait", CQuestConditionBlock = "if", CQuestFactsDBChangingBlock = "facts",
  CQuestSceneBlock = "scene", CQuestInteractionDialogBlock = "scene", CQuestContextDialogBlock = "scene",
  CQuestScenePrepareBlock = "scene", CQuestScriptBlock = "script", CQuestScriptedActionsBlock = "script",
  CQuestPokeScriptedActionsBlock = "script", CQuestResetScriptedActionsBlock = "script",
  CQuestRiderScriptedActionsBlock = "script", CQuestPlayAnimationBlock = "script",
  CQuestLookAtBlock = "script", CCommentGraphBlock = "note", CDescriptionGraphBlock = "note",
}
V.NAMES = {CQuestPhaseInputBlock = "Input", CQuestPhaseOutputBlock = "Output", CQuestStartBlock = "Start",
           CQuestEndBlock = "End", CQuestAndBlock = "All of", CQuestXorBlock = "First of",
           CQuestRandomBlock = "Random", CQuestCheckpointBlock = "Checkpoint", CQuestPhaseBlock = "Phase",
           CQuestPauseConditionBlock = "Wait", CQuestConditionBlock = "If", CQuestFactsDBChangingBlock = "Fact",
           CQuestSceneBlock = "Scene", CQuestInteractionDialogBlock = "Talk", CQuestScriptBlock = "Script",
           CJournalQuestBlock = "Journal", CJournalQuestMappinStateBlock = "Map pin",
           CQuestCutControlBlock = "Cut control", CCommentGraphBlock = "Comment",
           CDescriptionGraphBlock = "Description", CQuestStoryPhaseSetterBlock = "Spawn sets",
           CQuestLayersHiderBlock = "Layers", CQuestTeleportBlock = "Teleport", CQuestRewardBlock = "Reward",
           CQuestTimeManagementBlock = "Time", CQuestScriptedActionsBlock = "AI actions",
           CQuestDeletionMarkerBlock = "Deleted", CQuestEncounterManagerBlock = "Encounters"}
V.QUIET = {guid = true, cachedConnections = true, name = true, comment = true, caption = true, embeddedGraph = true,
           phase = true, size = true}
local SHORT = {"CQuest", "CJournal", "CStoryScene", "W3QuestCond_", "CQC", "C"}

function V.short(cls)
  for _, p in ipairs(SHORT) do
    if P.startswith(cls, p) and #cls > #p then
      cls = cls:sub(#p + 1)
      break
    end
  end
  return P.replace(P.replace(cls, "Block", ""), "Condition", "")
end

function V.family_of(cls)
  if V.CLASS_FAMILY[cls] then return V.CLASS_FAMILY[cls] end
  if P.startswith(cls, "CJournal") then return "journal" end
  return "world"
end

-- --- the file
local QF = {}
QF.__index = QF
function V.QuestFile(depot, path, data)
  local self = setmetatable({depot = depot, path = path, _graphs = {}}, QF)
  self.tree = TR.Tree(data ~= nil and data or depot:read(path))
  local top = self.tree:obj(1)
  local g = top and top:get("graph")
  if V.obj_ref(g) then
    self.root = V.ival(g)
  else
    for k, o in ipairs(self.tree.objects) do
      if o.cls == "CQuestGraph" then self.root = k break end
    end
    if self.root == nil then error("StopIteration: no CQuestGraph in " .. tostring(path), 0) end
  end
  return self
end

-- a handle's import (-n) or a soft handle's (Soft(n)) -> its path
function QF:import_path(h)
  local k = is(h, TR.SOFT) and h.n or -V.ival(h)
  local imps = self.tree.f.imports
  if k > 0 and k <= #imps then return imps[k][1] end
  return nil
end

local function fmt_list(xs, sep)
  return table.concat(xs, sep)
end

-- a value, short: objects under a handle followed (conditions), imports by file name
function QF:text(v, typ, depth)
  typ, depth = typ or "", depth or 0
  if is(v, TR.RAW) then return "<" .. #v.b .. " bytes>" end
  if is(v, TR.SOFT) then
    local p = self:import_path(v)
    return p and basename(p) or "none"
  end
  if (P.startswith(typ, "handle:") or P.startswith(typ, "ptr:") or P.startswith(typ, "#")) and
     (math.type(v) == "integer" or type(v) == "boolean" or is(v, TR.LOC)) then
    local n = V.ival(v)
    if n < 0 then
      local p = self:import_path(n)
      return p and basename(p) or "?"
    end
    if n == 0 then return "none" end
    if depth > 2 then return V.short(self.tree:obj(n).cls) end
    return self:object_text(n, depth + 1)
  end
  if is(v, TR.GUID) then return (require("conjunction.journal_index").hex(v.b)):sub(1, 8) end
  if is(v, TR.LOC) then return "text " .. v.n end
  if is(v, TR.TAGS) then
    local parts = {}
    for i, x in ipairs(v) do parts[i] = V.str(x) end
    local s = fmt_list(parts, ", ")
    return s ~= "" and s or "no tags"
  end
  if is(v, TR.VARIANT) then return self:text(v.value, v.type, depth) end
  if is(v, TR.TRANSFORM) then
    local out = {}
    for _, kp in ipairs({{"at", v.position}, {"rot", v.rotation}, {"scale", v.scale}}) do
      local part = kp[2]
      if V.truth(part) then
        local xs = {}
        for i, x in ipairs(part) do xs[i] = V.g(x) end
        out[#out + 1] = kp[1] .. "=(" .. fmt_list(xs, ", ") .. ")"
      end
    end
    return fmt_list(out, " ")
  end
  if is(v, TR.STRUCT) then
    local out = {}
    for _, p in ipairs(v) do
      local x = p.value
      if not (x == nil or x == "" or (is(x, TR.WIDE) and x.s == "") or (is_list(x) and #x == 0)) then
        out[#out + 1] = p.name .. "=" .. self:text(x, p.type, depth)
      end
    end
    return "{" .. fmt_list(out, ", ") .. "}"
  end
  if is_list(v) then
    local inner = ""
    if P.startswith(typ, "array:") then
      local a = typ:find(",", 1, true)
      local b = a and typ:find(",", a + 1, true)
      if not b then error("IndexError: list index out of range", 0) end
      inner = typ:sub(b + 1)
    end
    local items = {}
    for i = 1, math.min(6, #v) do items[i] = self:text(v[i], inner, depth) end
    return "[" .. fmt_list(items, ", ") .. (#v > 6 and " ..." or "") .. "]"
  end
  if math.type(v) == "float" then return V.g(v) end
  if type(v) == "boolean" then return v and "yes" or "no" end
  return V.str(v)
end

-- an object under a handle (a condition, an AI action ...): Class(prop=value, ...)
function QF:object_text(n, depth)
  depth = depth or 0
  local o = self.tree:obj(n)
  if o.cls == "CQuestFactsDBCondition" then return V.fact_test(o) end
  if o.cls == "CQuestLogicOperationCondition" then
    local op = o:get("logicOperation", "LO_And") == "LO_And" and " and " or " or "
    local parts = {}
    for _, c in ipairs(V.truth(o:get("conditions")) and o:get("conditions") or {}) do
      if V.truth(c) then parts[#parts + 1] = self:text(c, "handle:x", depth) end
    end
    return "(" .. fmt_list(parts, op) .. ")"
  end
  local parts = {}
  for _, p in ipairs(o.props or {}) do
    if not V.QUIET[p.name] and not V.empty(p.value) then
      parts[#parts + 1] = p.name .. "=" .. self:text(p.value, p.type, depth)
    end
  end
  if #parts > 0 then return V.short(o.cls) .. "(" .. fmt_list(parts, ", ") .. ")" end
  return V.short(o.cls)
end

function QF:graph(n)
  n = (n ~= nil and n ~= 0) and n or self.root
  if self._graphs[n] == nil then self._graphs[n] = V.Graph(self, n) end
  return self._graphs[n]
end

local CMP_T = {CF_Equal = "=", CF_NotEqual = "!=", CF_Less = "<", CF_LessEqual = "<=", CF_Greater = ">",
               CF_GreaterEqual = ">="}
function V.fact_test(o)
  local fact = V.str(V.or_(o:get("factId"), "?"))
  local cmp = CMP_T[o:get("compareFunc")] or "?"
  local value = o:get("value", 0)
  local q = o:get("queryFact")
  if (q == "QF_DoesExist" or q == nil) and cmp == ">=" and V.ival(value) == 1 then return fact end
  return fact .. " " .. cmp .. " " .. V.str(value)
end

-- --- the graph
local function new_block(n, cls)
  return {n = n, cls = cls, name = "", title = "", lines = {}, inputs = {}, outputs = {}, opens = nil,
          family = V.family_of(cls), x = 0, y = 0, w = 0, h = 0, comment = ""}
end
local function has(list, x)
  for _, y in ipairs(list) do if y == x then return true end end
  return false
end
local function index_of(list, x)
  for i, y in ipairs(list) do if y == x then return i end end
  return nil
end

local G = {}
G.__index = G
function V.Graph(qf, n)
  local self = setmetatable({qf = qf, n = n, blocks = {}, order = {}, links = {}, wires = {}}, G)
  local t = qf.tree
  for _, b in ipairs(t:obj(n):get("graphBlocks") or {}) do
    if V.obj_ref(b) then
      b = V.ival(b)
      if self.blocks[b] == nil then self.order[#self.order + 1] = b end
      self.blocks[b] = self:_block(b)
    end
  end
  for _, bn in ipairs(self.order) do                    -- the sockets its class has, then any others it uses
    local b = self.blocks[bn]
    local s = V.sockets(b.cls)
    b.inputs, b.outputs = {}, {}
    for i, x in ipairs(s[1]) do b.inputs[i] = S.strip(x) end
    for i, x in ipairs(s[2]) do b.outputs[i] = S.strip(x) end
  end
  for _, bn in ipairs(self.order) do
    local b = self.blocks[bn]
    local o = t:obj(b.n)
    for _, c in ipairs(V.or_(o:get("cachedConnections"), {})) do
      local sock = V.s(V.or_(V.sget(c, "socketId"), ""))
      if S.strip(sock) == "" then sock = "" end
      if not has(b.outputs, sock) then b.outputs[#b.outputs + 1] = sock end
      for _, d in ipairs(V.or_(V.sget(c, "blocks"), {})) do
        local to, put = V.sget(d, "ock"), V.s(V.or_(V.sget(d, "putName"), ""))
        if V.isint(to) and self.blocks[V.ival(to)] ~= nil then
          to = V.ival(to)
          if S.strip(put) == "" then put = "" end
          self.links[#self.links + 1] = {b.n, sock, to, put}
          if not has(self.blocks[to].inputs, put) then
            local ins = self.blocks[to].inputs
            ins[#ins + 1] = put
          end
        end
      end
    end
  end
  for _, bn in ipairs(self.order) do                    -- the sockets a block has by its kind
    local b = self.blocks[bn]
    local sin = self:_sockets_in(b)
    for _, s in ipairs(sin) do if not has(b.inputs, s) then b.inputs[#b.inputs + 1] = s end end
    for _, s in ipairs(self:_sockets_out(b)) do if not has(b.outputs, s) then b.outputs[#b.outputs + 1] = s end end
    -- "Cut" only where something is wired into it (a wire from a Thunder output dropped onto the block goes there)
    local kept = {}
    for _, s in ipairs(b.inputs) do
      local keep = s ~= "Cut" or has(sin, "Cut")
      if not keep then
        for _, l in ipairs(self.links) do
          if l[3] == b.n and l[4] == "Cut" then keep = true break end
        end
      end
      if keep then kept[#kept + 1] = s end
    end
    b.inputs = kept
  end
  local BL = require("conjunction.blocks")
  local ins = {}
  for _, l in ipairs(self.links) do
    ins[l[3]] = ins[l[3]] or {}
    ins[l[3]][l[4]] = true
  end
  for _, bn in ipairs(self.order) do                    -- an objective says what it does: show, done, failed
    local b = self.blocks[bn]
    if b.kind ~= nil and b.kind.id == "objective" then b.title = BL.objective_label(ins[b.n]) end
  end
  return self
end

function G:_sockets_in(b)
  if b.cls == "CQuestPhaseBlock" and b.opens and b.opens[1] == "graph" then
    local sub = self.qf:graph(b.opens[2])               -- (its unnamed input is the phase's "In")
    local out = {}
    for _, xn in ipairs(sub.order) do
      local x = sub.blocks[xn]
      if x.cls == "CQuestPhaseInputBlock" then out[#out + 1] = x.name ~= "" and x.name or "In" end
    end
    return out
  end
  return {}
end

function G:_sockets_out(b)
  if b.cls == "CQuestConditionBlock" then return {"True", "False"} end
  if b.cls == "CQuestPhaseBlock" and b.opens and b.opens[1] == "graph" then
    local sub = self.qf:graph(b.opens[2])
    local out = {}
    for _, xn in ipairs(sub.order) do
      local x = sub.blocks[xn]
      if x.cls == "CQuestPhaseOutputBlock" then out[#out + 1] = x.name ~= "" and x.name or "Out" end
    end
    return out
  end
  return {}
end

function G:_block(n)
  local qf = self.qf
  local o = qf.tree:obj(n)
  local b = new_block(n, o.cls)
  b.name = strip(V.or_(o:get("name"), ""))
  b.comment = strip(V.or_(o:get("comment"), ""))
  if o.cls == "CQuestPhaseInputBlock" or o.cls == "CQuestPhaseOutputBlock" then
    b.name = strip(V.or_(o:get("socketID"), b.name, ""))
  end
  local BL = require("conjunction.blocks")
  local kind = BL.kind_of(qf.tree, n)
  b.kind = kind
  b.family = kind.group
  local label = kind.label
  if kind == BL.GAME_SCRIPT then
    local l = require("conjunction.game_catalog").label(V.str(V.or_(o:get("functionName"), "")))
    if l ~= "" then label = l end
  end
  b.title = label
  local lines = BL.summary(qf, n, kind)
  if lines ~= nil then b.lines = lines else b.lines = self:_lines(o) end
  if o.cls == "CQuestPhaseBlock" then
    local emb, ph = o:get("embeddedGraph"), o:get("phase")
    if V.obj_ref(emb) then
      b.opens = {"graph", V.ival(emb)}
    elseif (V.isint(ph) and not is(ph, TR.SOFT) and V.ival(ph) < 0) or (is(ph, TR.SOFT) and ph.n ~= 0) then
      b.opens = {"file", qf:import_path(ph)}
    end
  end
  return b
end

function G:_lines(o)
  local qf, c = self.qf, o.cls
  if c == "CQuestPhaseInputBlock" or c == "CQuestPhaseOutputBlock" then
    return {V.str(V.or_(o:get("socketID"), "(the phase's own)"))}
  end
  if c == "CQuestFactsDBChangingBlock" then
    local value = o:get("value", 1)
    local plus = V.ival(V.or_(value, 0)) >= 0 and "+" or ""
    return {V.str(o:get("factID")) .. " " .. plus .. V.str(value)}
  end
  if c == "CQuestPauseConditionBlock" then
    local out = {}
    for _, x in ipairs(V.or_(o:get("conditions"), {})) do
      if V.truth(x) and #out < 3 then out[#out + 1] = qf:text(x, "handle:x") end
    end
    return #out > 0 and out or {"(nothing)"}
  end
  if c == "CQuestConditionBlock" then return {qf:text(o:get("questCondition"), "handle:x")} end
  if c == "CQuestSceneBlock" or c == "CQuestInteractionDialogBlock" or c == "CQuestContextDialogBlock" then
    local s = V.or_(o:get("scene"), o:get("targetScene"))
    return {is(s, TR.SOFT) and qf:text(s) or V.str(s)}
  end
  if c == "CQuestScriptBlock" then
    local args = {}
    for _, p in ipairs(V.or_(o:get("parameters"), {})) do
      args[#args + 1] = V.str(V.sget(p, "name")) .. "=" .. qf:text(V.sget(p, "value"))
    end
    return {V.str(o:get("functionName")) .. "(" .. fmt_list(args, ", ") .. ")"}
  end
  if c == "CQuestPhaseBlock" then
    local ph = o:get("phase")
    if (V.isint(ph) and not is(ph, TR.SOFT) and V.ival(ph) < 0) or (is(ph, TR.SOFT) and ph.n ~= 0) then
      return {basename(qf:import_path(ph) or "")}
    end
    local emb = o:get("embeddedGraph")
    if V.truth(emb) then
      return {"inside, " .. #(V.or_(qf.tree:obj(V.ival(emb)):get("graphBlocks"), {})) .. " blocks"}
    end
    return {}
  end
  if c == "CJournalQuestBlock" or c == "CJournalQuestMappinStateBlock" or c == "CJournalBlock" then
    local entry = V.or_(o:get("questEntry"), o:get("mappinEntry"), o:get("entry"))
    return {self:journal_text(entry)}
  end
  if c == "CCommentGraphBlock" or c == "CDescriptionGraphBlock" then
    local text = strip(V.or_(o:get("descriptionText"), o:get("comment"), ""))
    local cap = strip(V.or_(o:get("caption"), ""))
    local out = {}
    for _, x in ipairs({cap, text}) do if x ~= "" then out[#out + 1] = x end end
    return out
  end
  local parts = {}
  for _, p in ipairs(o.props or {}) do
    if not V.QUIET[p.name] and not V.empty(p.value) and #parts < 3 then
      parts[#parts + 1] = p.name .. "=" .. qf:text(p.value, p.type)
    end
  end
  return parts
end

-- a journal path (an object chain resource -> child ...) -> its deepest file and entry
function G:journal_text(h)
  local t = self.qf.tree
  if not V.obj_ref(h) then return "none" end
  local o = t:obj(V.ival(h))
  local names = {}
  while o ~= nil and o.cls == "CJournalPath" do
    local res = o:get("resource")
    if is(res, TR.SOFT) and res.n ~= 0 then
      names[#names + 1] = (basename(self.qf:import_path(res) or ""):gsub("%.journal", ""))
    end
    local child = o:get("child")
    o = V.obj_ref(child) and t:obj(V.ival(child)) or nil
  end
  local s = table.concat(names, " / ", math.max(1, #names - 1), #names)
  return s ~= "" and s or "journal"
end

-- each class's sockets, as the game's graphs use them (measured over all 1041 files)
V.SOCKETS = {
  CQuestPhaseInputBlock = {{}, {" "}}, CQuestStartBlock = {{}, {" "}},
  CQuestPhaseOutputBlock = {{" "}, {}}, CQuestEndBlock = {{" "}, {}},
  CQuestPauseConditionBlock = {{"In", "Cut"}, {""}}, CQuestConditionBlock = {{"In"}, {"True", "False"}},
  CQuestAndBlock = {{"In 0", "In 1"}, {"Out"}}, CQuestXorBlock = {{"In 0", "In 1"}, {"Out"}},
  CQuestRandomBlock = {{"In"}, {"Random 1", "Random 2"}}, CQuestCutControlBlock = {{"In"}, {"Out", "Thunder"}},
  CQuestSceneBlock = {{"Input", "Cut"}, {"Output"}}, CQuestInteractionDialogBlock = {{"Input", "Cut"}, {"Output"}},
  CJournalQuestBlock = {{"Activate", "Success", "Failure", "Deactivate"}, {"Out"}},
  CQuestPhaseBlock = {{"In", "Cut"}, {"Out"}}, CQuestScriptBlock = {{"In", "Cut"}, {"Out"}},
  CCommentGraphBlock = {{}, {}}, CDescriptionGraphBlock = {{}, {}},
}
V.DEFAULT_SOCKETS = {{"In"}, {"Out"}}
function V.sockets(cls) return V.SOCKETS[cls] or V.DEFAULT_SOCKETS end

-- --- where the blocks stand: layers left to right along the links
V.NODE_W, V.HEAD, V.LINE, V.ROW, V.PAD = 240, 22, 15, 17, 6
V.GAP_X, V.GAP_Y = 90, 18
V.CHARS = 38
V.ROW_GAP = 160         -- between the rows of a long graph wrapped like text

-- has the block a name line? (a phase's input / output: its name is its socket, its line already)
function V.shows_name(b)
  return b.name ~= "" and b.cls ~= "CQuestPhaseInputBlock" and b.cls ~= "CQuestPhaseOutputBlock"
end
function V.text_rows(b)
  local notes = b.family == "note" or b.family == "notes"
  return (V.shows_name(b) and 1 or 0) + math.min(#b.lines, notes and 8 or 3)
end
function V.size(b)
  local rows = math.max(#b.inputs, #b.outputs, 0)
  return V.NODE_W, V.HEAD + V.text_rows(b) * V.LINE + rows * V.ROW + V.PAD
end

local function mean(xs)
  local s = 0
  for _, x in ipairs(xs) do s = s + x end
  return s / #xs
end

function V.place(g)
  local blocks = g.blocks
  local succ, pred = {}, {}
  for _, n in ipairs(g.order) do succ[n], pred[n] = {}, {} end
  for _, l in ipairs(g.links) do
    if l[1] ~= l[3] then table.insert(succ[l[1]], l[3]) end
  end
  -- back links (a loop) left out of the layering: depth-first from the inputs, then from the rest
  local order = PS.sorted(g.order, function(n)
    local c = blocks[n].cls
    return {not (c == "CQuestPhaseInputBlock" or c == "CQuestStartBlock"), n}
  end)
  local state, back = {}, {}
  local function bkey(a, b) return a .. ">" .. b end
  local function dfs(start)
    local stack = {{start, 0}}
    state[start] = 1
    while #stack > 0 do
      local top = stack[#stack]
      local n = top[1]
      top[2] = top[2] + 1
      local nxt = succ[n][top[2]]
      if nxt == nil then
        state[n] = 2
        stack[#stack] = nil
      elseif state[nxt] == 1 then
        back[bkey(n, nxt)] = true
      elseif state[nxt] == nil then
        state[nxt] = 1
        stack[#stack + 1] = {nxt, 0}
      end
    end
  end
  for _, n in ipairs(order) do
    if state[n] == nil then dfs(n) end
  end
  for _, a in ipairs(g.order) do
    for _, b in ipairs(succ[a]) do
      if not back[bkey(a, b)] then table.insert(pred[b], a) end
    end
  end
  local layer, layer_order = {}, {}
  local function depth(n)
    if layer[n] ~= nil then return layer[n] end
    layer[n] = 0                                        -- (guards a loop the back links missed)
    layer_order[#layer_order + 1] = n
    local m = 0
    for _, p in ipairs(pred[n]) do m = math.max(m, depth(p) + 1) end
    layer[n] = m
    return m
  end
  local notes, is_note = {}, {}
  for _, n in ipairs(g.order) do
    local f = blocks[n].family
    if (f == "note" or f == "notes") and #pred[n] == 0 and #succ[n] == 0 then
      notes[#notes + 1] = n
      is_note[n] = true
    end
  end
  for _, n in ipairs(g.order) do
    if not is_note[n] then depth(n) end
  end
  local cols, col_keys = {}, {}
  for _, n in ipairs(layer_order) do
    local k = layer[n]
    if cols[k] == nil then
      cols[k] = {}
      col_keys[#col_keys + 1] = k
    end
    table.insert(cols[k], n)
  end
  table.sort(col_keys)
  for _, k in ipairs(col_keys) do table.sort(cols[k]) end
  for _, n in ipairs(g.order) do
    local b = blocks[n]
    b.w, b.h = V.size(b)
  end
  -- order inside a column: by the mean place of what leads to it (a few sweeps), then stacked near that place
  local pos = {}
  for _, k in ipairs(col_keys) do
    for i, n in ipairs(cols[k]) do pos[n] = i - 1 end
  end
  for _ = 1, 4 do
    for ci = 2, #col_keys do
      local k = col_keys[ci]
      PS.sort(cols[k], function(n)
        local ps = {}
        for _, p in ipairs(pred[n]) do if pos[p] ~= nil then ps[#ps + 1] = pos[p] end end
        return #ps > 0 and mean(ps) or pos[n]
      end)
      for i, n in ipairs(cols[k]) do pos[n] = i - 1 end
    end
  end
  local y_of = {}
  local top = 0
  if #notes > 0 then                                    -- the notes above the graph, in a row
    local x = 0
    local sorted_notes = PS.sorted(notes)
    for _, n in ipairs(sorted_notes) do
      local b = blocks[n]
      b.x, b.y = x, 0
      x = x + b.w + V.GAP_Y
      top = math.max(top, b.h + V.GAP_Y * 2)
    end
  end
  for _, k in ipairs(col_keys) do
    local y = top
    for _, n in ipairs(cols[k]) do
      local b = blocks[n]
      local ps = {}
      for _, p in ipairs(pred[n]) do if y_of[p] ~= nil then ps[#ps + 1] = y_of[p] end end
      local want = #ps > 0 and mean(ps) or y
      local w = math.tointeger(want >= 0 and math.floor(want) or math.ceil(want))
      b.y = math.max(y, w)
      b.x = k * (V.NODE_W + V.GAP_X)
      y_of[n] = b.y
      y = b.y + b.h + V.GAP_Y
    end
  end
  V.wrap(g, cols, col_keys, top)
  g.back = back
  V.route(g)
end

-- a long chain in rows like lines of text, so the whole graph fits a screen about 16:9
function V.wrap(g, cols, col_keys, top)
  if #col_keys == 0 then return end
  local layers = col_keys[#col_keys] + 1
  local band = 0
  for _, n in ipairs(g.order) do
    local b = g.blocks[n]
    band = math.max(band, b.y + b.h)
  end
  band = band - top
  local col_w = V.NODE_W + V.GAP_X
  local per_row = math.max(4, math.tointeger(math.ceil(math.sqrt(layers * (band + V.ROW_GAP) * 16 / 9 / col_w))))
  if per_row >= layers then return end
  for _, k in ipairs(col_keys) do
    local row, col = k // per_row, k % per_row
    for _, n in ipairs(cols[k]) do
      local b = g.blocks[n]
      b.x = col * col_w
      b.y = b.y + row * (band + V.ROW_GAP)
    end
  end
end

function V.in_port(b, name)
  local k = (index_of(b.inputs, name) or 1) - 1
  return b.x, b.y + V.HEAD + V.text_rows(b) * V.LINE + k * V.ROW + V.ROW // 2
end
function V.out_port(b, name)
  local k = (index_of(b.outputs, name) or 1) - 1
  return b.x + b.w, b.y + V.HEAD + V.text_rows(b) * V.LINE + k * V.ROW + V.ROW // 2
end

-- the ways the links run, square: out to the right, along the gap before the target, into it from the left; a link
-- back (a loop) under both blocks. Links sharing a gap get lanes of their own.
function V.route(g)
  local lanes = {}
  g.wires = {}
  for _, l in ipairs(g.links) do
    local ba, bb = g.blocks[l[1]], g.blocks[l[3]]
    local x0, y0 = V.out_port(ba, l[2])
    local x1, y1 = V.in_port(bb, l[4])
    local pts
    if x1 > x0 + 20 then
      local gap = x1 - V.GAP_X
      local k = lanes[gap] or 0
      lanes[gap] = k + 1
      local mx = x1 - V.GAP_X // 2 - 24 + (k % 8) * 6
      pts = {{x0, y0}, {mx, y0}, {mx, y1}, {x1, y1}}
    else                                                -- back: right of a, under both, left of b
      local below = math.max(ba.y + ba.h, bb.y + bb.h) + 14 + (#g.wires % 6) * 5
      pts = {{x0, y0}, {x0 + 16, y0}, {x0 + 16, below}, {x1 - 16, below}, {x1 - 16, y1}, {x1, y1}}
    end
    g.wires[#g.wires + 1] = {l, pts}
  end
end

return V
