-- vanilla_edit.py: editing a game quest file - every change on the lossless tree, undone and redone, kept in the
-- project under the game's own path (the build puts it into the project's mod bundle, where it replaces the game's
-- file).
--   local e = VE.Editor(depot, path, project_dir)   the project's copy when it has one, else the game's file
--   e:set(n, {"parameters", 0, "value"}, 12)        a value anywhere in an object (property, struct field, array
--                                                   item: a path of names and 0-based indices, as the app's)
--   e:connect(a, "Out", b, "In"), e:disconnect(...)
--   e:add_block(graph, cls) / e:duplicate(graph, n) / e:remove_block(graph, n)
--   e:add_item(n, path) / e:remove_item(n, path)    an array's item (a copy of its last, or of the game's)
--   e:set_ref(n, path, file, cls)                   a reference to another file (its import found or added)
--   e:undo(), e:redo(), e:save(), e:revert()        save: into <project>\game_files\<path>
--   e.qf                                            the QuestFile now (read again after each change)
-- Socket names as the game writes them: "In", "Cut", "Input", "Activate" ...; a block's single unnamed output is " "
-- (Start, phase inputs) or has no name at all (a pause) - written the way the class has it (vanilla_graph.SOCKETS).
local TR = require("conjunction.cr2w_tree")
local V = require("conjunction.vanilla_graph")
local J = require("conjunction.json")
local P = require("conjunction.py")
local S = require("conjunction.pystr")
local PS = require("conjunction.pysort")
local PATHS = require("conjunction.paths")
local VE = {}

VE.GAME_FILES = "game_files"
VE.TEMPLATES = PATHS.DATA .. "\\block_templates.json"
VE.OBJECT_SAMPLES = PATHS.DATA .. "\\object_samples.json"
VE.ENCODED = "own_quest.encoded.w2quest"   -- in build: the quest as the board made it, when the graph's replaced it
VE.OWN_FILE, VE.OWN_META = "own_quest.w2quest", "own_quest.json"   -- in game_files: the own quest as the graph left it

local is, Prop, Struct, Array = TR.is, TR.Prop, TR.Struct, TR.Array
local obj_ref, ival = V.obj_ref, V.ival
local function fs() return w3.fs end
local function exists(p) return fs().exists(p) end
local function dirname(p) return (p:match("^(.*)[\\/][^\\/]*$")) or "" end
local function read(p) return assert(fs().read(p)) end
local function strip(v) return S.strip(V.str(V.or_(v, ""))) end

-- the game files the samples come from: every quest graph file of the game
local function game_quest_files(depot)
  local story = require("conjunction.story")
  local out = {}
  for _, p in ipairs(depot:glob("", ".w2phase")) do if story.game_file(p) then out[#out + 1] = p end end
  for _, p in ipairs(depot:glob("", ".w2quest")) do if story.game_file(p) then out[#out + 1] = p end end
  return PS.sorted(out)
end

-- {class: {game file, object number}}: a block of every class the game has; built here when missing (a minute)
local templates
function VE.templates(depot)
  if templates then return templates end
  if exists(VE.TEMPLATES) then
    templates = J.read(VE.TEMPLATES).samples
    return templates
  end
  local out = {}
  for _, path in ipairs(game_quest_files(depot)) do
    local t = TR.Tree(depot:read(path))
    for _, o in ipairs(t.objects) do
      if o.cls == "CQuestGraph" then
        for _, b in ipairs(o:get("graphBlocks") or {}) do
          if obj_ref(b) and out[t:obj(b).cls] == nil then out[t:obj(b).cls] = {path, b} end
        end
      end
    end
  end
  J.write(VE.TEMPLATES, {samples = out})
  templates = out
  return out
end

function VE.block_classes(depot)
  local out = {}
  for cls in pairs(VE.templates(depot)) do out[#out + 1] = cls end
  return PS.sorted(out)
end

-- {class: {game file, object number}} for every class the game's quest graphs hold - conditions, AI actions, time
-- functions too: what a new one is copied from. Built once (a minute), kept in object_samples.json.
local samples
function VE.object_samples(depot)
  if samples then return samples end
  if exists(VE.OBJECT_SAMPLES) then
    samples = J.read(VE.OBJECT_SAMPLES)
    return samples
  end
  local out = {}
  for _, path in ipairs(game_quest_files(depot)) do
    local t = TR.Tree(depot:read(path))
    for k, o in ipairs(t.objects) do
      if out[o.cls] == nil and o.props ~= nil then out[o.cls] = {path, k} end
    end
  end
  J.write(VE.OBJECT_SAMPLES, out)
  samples = out
  return out
end

local SAMPLES, nsamples = {}, 0
-- a game file new blocks are copied from, read once (copying leaves it as it is)
local function sample_tree(depot, path)
  if SAMPLES[path] == nil then
    if nsamples > 64 then SAMPLES, nsamples = {}, 0 end
    SAMPLES[path] = TR.Tree(depot:read(path))
    nsamples = nsamples + 1
  end
  return SAMPLES[path]
end

-- a script parameter's type in the scripts -> its type in the quest file, and an empty value of it
VE.SCRIPT_TYPE = {int = {"Int32", 0}, float = {"Float", 0.0}, bool = {"Bool", false}, name = {"CName", ""},
                  string = {"String", ""}, Int32 = {"Int32", 0}, Float = {"Float", 0.0}, Bool = {"Bool", false},
                  CName = {"CName", ""}, String = {"String", ""}}

-- the project's own quest as the quest graph edits it: its path in the DLC, the file the last build encoded - nil,
-- nil before the first build
function VE.own_quest(project_dir)
  if not project_dir or project_dir == "" then return nil, nil end
  local ok, qid = pcall(require("conjunction.build").production_id, project_dir .. "\\build\\definition.quest")
  if not ok or qid == nil then return nil, nil end
  local rel = "dlc\\dlc" .. qid .. "\\data\\" .. qid .. ".w2quest"
  local f = project_dir .. "\\build\\uncooked\\" .. rel
  if not exists(f) then return nil, nil end
  local enc = project_dir .. "\\build\\" .. VE.ENCODED     -- (the build put the graph's version there: the board's)
  return rel, exists(enc) and enc or f
end

local function hex(b) return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function unhex(h) return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end)) end

-- {guid hex: "file|class|name|n"} of every entry of the own quest's journal as its last build wrote it
-- (journal_index.own_journal_names)
function VE.own_journal_names(project_dir)
  local rel = VE.own_quest(project_dir)
  if not rel then return {} end
  local qid = (rel:match("([^\\]*)%.w2quest$"))
  local root = project_dir .. "\\build\\uncooked"
  local base = root .. "\\" .. dirname(dirname(rel))
  local files = {}
  if fs().isdir(base) then
    for _, e in ipairs(require("conjunction.fsutil").walk(base)) do
      if e.name:sub(-8) == ".journal" then files[#files + 1] = e.path end
    end
  end
  local out = {}
  for _, f in ipairs(PS.sorted(files)) do
    local ok, t = pcall(function() return TR.Tree(read(f)) end)
    if ok then
      local name_of_file = P.replace(S.lower((P.replace(f:sub(#root + 2), "\\", "/"))), qid, "{QID}")
      local seen = {}
      for _, o in ipairs(t.objects) do
        local g = o.props and o:get("guid") or nil
        if is(g, TR.GUID) then
          local key = name_of_file .. "|" .. o.cls .. "|" .. P.replace(V.str(V.or_(o:get("baseName"), "")), qid,
                                                                     "{QID}")
          seen[key] = (seen[key] or 0) + 1
          out[hex(g.b)] = key .. "|" .. seen[key]
        end
      end
    end
  end
  return out
end

-- the own quest's graph version for this build: path in the DLC, its data (nil when the graph never changed it),
-- what the build encoded. A file kept for an earlier run of Build & Play has its names and journal GUIDs moved to
-- this run's.
function VE.own_quest_data(project_dir)
  local rel, built = VE.own_quest(project_dir)
  if not rel then return nil, nil, nil end
  local base = read(built)
  local keep = project_dir .. "\\" .. VE.GAME_FILES .. "\\" .. VE.OWN_FILE
  if not exists(keep) then return rel, nil, base end
  local data = read(keep)
  local okm, meta = pcall(J.read, project_dir .. "\\" .. VE.GAME_FILES .. "\\" .. VE.OWN_META)
  if not okm or type(meta) ~= "table" then meta = {} end
  local old = P.get(meta, "qid")
  local qid = (rel:match("([^\\]*)%.w2quest$"))
  local guids, any = {}, false
  if P.T(P.get(meta, "journal")) then                   -- the journal entries it names, found again by their names
    local now = {}
    for g, key in pairs(VE.own_journal_names(project_dir)) do now[key] = g end
    for g, key in pairs(meta.journal) do
      if now[key] ~= nil and now[key] ~= g then
        guids[unhex(g)] = unhex(now[key])
        any = true
      end
    end
  elseif P.T(old) and old ~= qid then                   -- (kept before the names were: the runs' GUID keys)
    local dlc_dir = project_dir .. "\\build\\uncooked\\" .. dirname(dirname(rel))
    local B = require("conjunction.build")
    guids = require("conjunction.stable_ids").translation(dlc_dir, old, qid, B.mark_seed(project_dir))
    any = next(guids) ~= nil
  end
  if (P.T(old) and old ~= qid) or any then data = VE.retarget(data, P.T(old) and old or qid, qid, guids) end
  return rel, data, base
end

-- a quest file made for quest id `old` moved to `new`: every name, text and file path with the id in it, and the
-- GUIDs it points at (guids: {old bytes: new bytes})
function VE.retarget(data, old, new, guids)
  local t = TR.Tree(data)
  local function fix(v)
    if is(v, TR.TAGS) then
      local out = {}
      for i, x in ipairs(v) do out[i] = P.replace(x, old, new) end
      return TR.Tags(out)
    end
    if type(v) == "string" then return v:find(old, 1, true) and P.replace(v, old, new) or v end
    if is(v, TR.WIDE) then return v.s:find(old, 1, true) and TR.Wide(P.replace(v.s, old, new)) or v end
    if is(v, TR.GUID) then return guids[v.b] and TR.Guid(guids[v.b]) or v end
    if is(v, TR.VARIANT) then return TR.Variant(v.type, fix(v.value)) end
    if is(v, TR.STRUCT) then
      for _, p in ipairs(v) do p.value = fix(p.value) end
      return v
    end
    if is(v, TR.ARRAY) then
      for i, x in ipairs(v) do v[i] = fix(x) end
      return v
    end
    return v
  end
  for _, o in ipairs(t.objects) do
    for _, props in ipairs({o.props or {}, o.args or {}}) do
      for _, p in ipairs(props) do p.value = fix(p.value) end
    end
  end
  for _, imp in ipairs(t.f.imports) do imp[1] = P.replace(imp[1], old, new) end
  return t:to_bytes()
end

-- --- where a value is: (holder, key) of the value at `path` in a property list - holder a property (key nil) or a
-- list (key a 0-based index). path: property / struct field names and list indices.
local function is_prop(p) return type(p) == "table" and getmetatable(p) == nil and p.name ~= nil and p.type ~= nil end
local function locate(props, path)
  local holder, cur = nil, props
  for k, step in ipairs(path) do
    if math.type(step) == "integer" then
      if k == #path then return cur, step end
      local item = cur[step >= 0 and step + 1 or #cur + step + 1]
      if item == nil then error("IndexError: list index out of range", 0) end
      cur = item
      holder = nil
    else
      local found
      for _, p in ipairs(cur) do
        if is_prop(p) and p.name == step then found = p break end
      end
      if found == nil then error("KeyError: " .. tostring(step), 0) end
      holder = found
      cur = found.value
    end
  end
  return holder, nil
end
VE.locate = locate
local function at(holder, key)
  if key ~= nil then return holder[key >= 0 and key + 1 or #holder + key + 1] end
  return holder.value
end
local function put(holder, key, value)
  if key ~= nil then holder[key >= 0 and key + 1 or #holder + key + 1] = value else holder.value = value end
end

local function conns(t, n)
  local o = t:obj(n)
  local p = o:prop("cachedConnections")
  if p == nil then                                      -- (where the game has it: after the GUID)
    local pos = 0
    for k, x in ipairs(o.props) do
      if x.name == "guid" then pos = k break end
    end
    table.insert(o.props, pos + 1, Prop("cachedConnections", "array:2,0,SCachedConnections", Array({})))
    p = o:prop("cachedConnections")
  end
  return p.value
end
local function sprop(st, name)
  for _, p in ipairs(st) do if p.name == name then return p end end
  return nil
end
local function clear(list) for i = #list, 1, -1 do list[i] = nil end end
local function filter(list, keep)
  local out = {}
  for _, x in ipairs(list) do if keep(x) then out[#out + 1] = x end end
  clear(list)
  for i, x in ipairs(out) do list[i] = x end
end
local function sorted_desc(xs)
  local out = {}
  for i, x in ipairs(xs) do out[i] = x end
  table.sort(out, function(a, b) return a > b end)
  return out
end
-- how many of old and what is under it come before n (n's number once they are gone)
local function before(t, old, n)
  local c = old < n and 1 or 0
  for _, k in ipairs(t:under(old)) do if k < n then c = c + 1 end end
  return c
end

VE.KEEP = {guid = true, cachedConnections = true, graphBlocks = true, embeddedGraph = true, questCondition = true,
           ai = true, checkType = true, parameters = true, functionName = true, ["function"] = true, minigame = true}
local function handle_typed(typ) return P.startswith(typ, "handle:") or P.startswith(typ, "ptr:") end

-- a copy of the game's block or condition made new: only what makes it what it is stays (its GUID, links, the
-- objects it is built of) - every value back to the class's own default; what only a dropped value held goes too
local function blank(t, n)
  local o = t:obj(n)
  local keep, drop, any = {}, {}, false
  for _, p in ipairs(o.props or {}) do
    local single = handle_typed(p.type) and obj_ref(p.value) and t:obj(ival(p.value)).cls ~= "CJournalPath"
    if VE.KEEP[p.name] or single then
      keep[#keep + 1] = p
    elseif p.type:find("ptr:", 1, true) or p.type:find("handle:", 1, true) then
      local vals = V.is_list(p.value) and p.value or {p.value}
      for _, v in ipairs(vals) do
        if (math.type(v) == "integer" or is(v, TR.SOFT) or is(v, TR.LOC)) and ival(v) > 0 then
          drop[ival(v)] = true
          any = true
        end
      end
    end
  end
  clear(o.props)
  for i, p in ipairs(keep) do o.props[i] = p end
  if any then
    local ds = {}
    for k in pairs(drop) do ds[#ds + 1] = k end
    table.sort(ds)
    local gone = {}
    for _, c in ipairs(t:with_parts(ds)) do if c > n then gone[#gone + 1] = c end end
    local seen = {}
    for _, c in ipairs(sorted_desc(gone)) do
      if not seen[c] then
        seen[c] = true
        if t:obj(c).parent == n or t:obj(c).cls == "CJournalPath" then t:remove(c) end
      end
    end
  end
  for _, p in ipairs(keep) do                           -- the objects it is built of: new too
    local child = handle_typed(p.type) and V.isint(p.value) and ival(p.value) > n
    if not (p.name == "conditions" or p.name == "graphBlocks" or p.name == "embeddedGraph") and child and
       t:obj(ival(p.value)).parent == n then
      blank(t, ival(p.value))
    end
  end
end
VE.blank = blank

local function clear_links(o)
  local p = o:prop("cachedConnections")
  if p ~= nil then
    for _, c in ipairs(p.value) do
      local b = sprop(c, "blocks")
      if b ~= nil then clear(b.value) end
    end
  end
end

-- a copied value with new GUIDs inside (the same block twice would confuse saves)
local function fresh(v)
  if is(v, TR.STRUCT) then
    for _, p in ipairs(v) do
      if p.type == "CGUID" then p.value = TR.new_guid() else p.value = fresh(p.value) end
    end
  elseif V.is_list(v) then
    for i, x in ipairs(v) do v[i] = fresh(x) end
  end
  return v
end

-- --- the editor
local E = {}
E.__index = E

-- base: the file to start from and go back to (an own quest's: what the build encoded), else the game's. data: the
-- file now (else the project's copy or base). own: where the project keeps it (else game_files\<path>).
function VE.Editor(depot, path, project_dir, base, data, own)
  local self = setmetatable({depot = depot, path = path, project_dir = project_dir, _own = own, fast = false}, E)
  self.base = base ~= nil and base or depot:read(path)            -- what "revert" goes back to
  if data == nil then
    local mine = self:own_path()
    data = (mine and exists(mine)) and read(mine) or self.base
  end
  self.saved = data
  self.history, self.future = {}, {}
  self:_load(data)
  return self
end

function E:own_path()
  if self._own then return self._own end
  return self.project_dir and (self.project_dir .. "\\" .. VE.GAME_FILES .. "\\" .. self.path) or nil
end

function E:_load(data)
  self.data = data
  self.qf = V.QuestFile(self.depot, self.path, data)
  self.tree = self.qf.tree
end

function E:dirty() return self.data ~= self.saved end
-- changed from the game's file (saved or not)
function E:changed() return self.data ~= self.base end

-- many edits in a row (a rebuild: fast = true): on the tree itself, no undo; flush() writes the bytes
function E:flush()
  if self.fast then self:_load(self.tree:to_bytes()) end
end

-- one edit: fn(tree) changes it; undo goes back to before -> fn's result
function E:change(fn)
  if self.fast then
    local result = fn(self.tree)
    self.qf._graphs = {}
    return result
  end
  local before_data = self.data
  local tree = TR.Tree(before_data)
  local result = fn(tree)
  local after = tree:to_bytes()
  if after ~= before_data then
    self.history[#self.history + 1] = before_data
    self.future = {}
    self:_load(after)
  end
  return result
end

-- several edits as one: fn(editor) makes them; one undo takes them all back -> fn's result
function E:batch(fn)
  if self.fast then return fn(self) end
  local k, start = #self.history, self.data
  local result = fn(self)
  if #self.history > k then
    for i = #self.history, k + 1, -1 do self.history[i] = nil end
    self.history[#self.history + 1] = start
  end
  return result
end

function E:undo()
  if #self.history > 0 then
    self.future[#self.future + 1] = self.data
    self:_load(table.remove(self.history))
  end
end

function E:redo()
  if #self.future > 0 then
    self.history[#self.history + 1] = self.data
    self:_load(table.remove(self.future))
  end
end

function E:save()
  local own = self:own_path()
  if not own then error("No project to keep the change in", 0) end
  if not self._own and self.data ~= self.base then     -- a game quest's file changed: experimental (features.lua)
    require("conjunction.features").require("Changing a game quest file")
  end
  fs().mkdir(dirname(own))
  if self.data == self.base then                        -- back to the game's file: nothing of ours
    if exists(own) then fs().remove(own) end
  else
    assert(fs().write(own, self.data))                  -- (w3.fs.write: through a temp file, as os.replace)
    if self._own then                                   -- the quest id it was made for, its journal entries by name
      local names = VE.own_journal_names(self.project_dir)
      local used = {}
      for _, o in ipairs(self.tree.objects) do
        local g = o.cls == "CJournalPath" and o:get("guid") or nil
        if is(g, TR.GUID) then used[#used + 1] = hex(g.b) end
      end
      local Y = require("conjunction.yaml")
      local journal = Y.map()
      for _, g in ipairs(PS.sorted(used)) do if names[g] then journal[g] = names[g] end end
      local meta = dirname(own) .. "\\" .. VE.OWN_META
      local qid = (self.path:match("([^\\/]*)%.[^.\\/]*$")) or self.path
      assert(fs().write(meta, J.encode(Y.map({"qid", qid, "journal", journal}))))
    end
  end
  self.saved = self.data
end

-- back to the game's file (undo can bring the change back)
function E:revert()
  if self.data ~= self.base then
    self.history[#self.history + 1] = self.data
    self.future = {}
    self:_load(self.base)
  end
end

-- --- values
function E:set(n, path, value)
  self:change(function(t)
    local holder, key = locate(t:obj(n).props, path)
    put(holder, key, value)
  end)
end

-- a property of object n, added when the object lacks it (the game's files leave out what is at its default)
function E:set_field(n, name, value, typ)
  self:change(function(t) t:obj(n):set(name, value, typ) end)
end

-- a game function's parameter (a script block): its value in the parameters and in the arguments after them, the
-- same type as before
function E:set_param(n, name, value)
  self:change(function(t)
    local o = t:obj(n)
    local found = false
    for _, p in ipairs(o:get("parameters") or {}) do
      if V.sget(p, "name") == name then
        local v = V.sget(p, "value")
        local holder = sprop(p, "value")
        if holder == nil then error("StopIteration", 0) end
        holder.value = is(v, TR.VARIANT) and TR.Variant(v.type, value) or value
        found = true
        break
      end
    end
    if not found then error("KeyError: " .. tostring(name), 0) end
    for _, a in ipairs(o.args or {}) do
      if a.name == name then a.value = value end
    end
  end)
end

-- a reference to another file (a scene, a phase, a journal entry): the import found or added; an empty path: none
function E:set_ref(n, path, file, cls)
  cls = cls or "CResource"
  self:change(function(t)
    local holder, key = locate(t:obj(n).props, path)
    local old = at(holder, key)
    local k = 0
    if file and file ~= "" then
      for i, im in ipairs(t.f.imports) do
        if im[1] == file then k = i break end
      end
      if k == 0 then
        t.f.imports[#t.f.imports + 1] = {file, cls, 0}
        k = #t.f.imports
      end
    end
    put(holder, key, is(old, TR.SOFT) and TR.Soft(k) or -k)
  end)
end

-- an item more in the array at `path`: a copy of its last item (new GUIDs inside), else of the same array in the
-- class's template block -> its index (0-based)
function E:add_item(n, path)
  return self:change(function(t)
    local holder, key = locate(t:obj(n).props, path)
    local arr = at(holder, key)
    if V.truth(arr) then
      arr[#arr + 1] = fresh(TR.deepcopy(arr[#arr]))
    else
      local src = self:_template_array(t:obj(n).cls, path)
      if src == nil then error("Nothing to copy an item from", 0) end
      arr[#arr + 1] = src
    end
    return #arr - 1
  end)
end

function E:remove_item(n, path)
  self:change(function(t)
    local head = {}
    for i = 1, #path - 1 do head[i] = path[i] end
    local holder, key = locate(t:obj(n).props, head)
    local arr = at(holder, key)
    local i = path[#path]
    table.remove(arr, i >= 0 and i + 1 or #arr + i + 1)
  end)
end

function E:_template_array(cls, path)
  local tpl = VE.templates(self.depot)[cls]
  if not tpl then return nil end
  local t = TR.Tree(self.depot:read(tpl[1]))
  local ok, holder, key = pcall(locate, t:obj(tpl[2]).props, path)
  if not ok then return nil end
  local arr = at(holder, key)
  return V.truth(arr) and fresh(TR.deepcopy(arr[1])) or nil
end

-- --- links
-- a link from block a's output `out` to block b's input `put` (socket names as shown: "" for an unnamed one)
function E:connect(a, out, b, put_)
  self:change(function(t)
    local cs = conns(t, a)
    local want = S.strip(out)
    local c
    for _, x in ipairs(cs) do
      if strip(V.sget(x, "socketId")) == want then c = x break end
    end
    if c == nil then
      -- the class's own name for it (" " for a start's), else as given - an unnamed output stays unnamed
      local raw = out
      for _, s in ipairs(V.sockets(t:obj(a).cls)[2]) do
        if S.strip(s) == want then raw = s break end
      end
      local props = {}
      if raw ~= "" then props[1] = Prop("socketId", "CName", raw) end
      props[#props + 1] = Prop("blocks", "array:2,0,SBlockDesc", Array({}))
      c = Struct(props)
      cs[#cs + 1] = c
    end
    local bp = sprop(c, "blocks")
    if bp == nil then                                   -- (a connection the game left without its list)
      bp = Prop("blocks", "array:2,0,SBlockDesc", Array({}))
      c[#c + 1] = bp
    end
    local blocks = bp.value
    local want_put = S.strip(put_)
    local raw_put = put_ ~= "" and put_ or "In"
    for _, s in ipairs(V.sockets(t:obj(b).cls)[1]) do
      if S.strip(s) == want_put then raw_put = s break end
    end
    for _, d in ipairs(blocks) do
      if V.sget(d, "ock") == b and strip(V.sget(d, "putName")) == want_put then return end
    end
    blocks[#blocks + 1] = Struct({Prop("ock", "ptr:CQuestGraphBlock", b), Prop("putName", "CName", raw_put)})
  end)
end

function E:disconnect(a, out, b, put_)
  self:change(function(t)
    for _, c in ipairs(conns(t, a)) do
      if strip(V.sget(c, "socketId")) == S.strip(out) then
        local bp = sprop(c, "blocks")
        if bp == nil then error("StopIteration", 0) end
        filter(bp.value, function(d)
          return not (V.sget(d, "ock") == b and strip(V.sget(d, "putName")) == S.strip(put_))
        end)
      end
    end
  end)
end

-- --- blocks
-- a block of class `cls` in graph object `graph`: a copy of one the game has (its values a start), its links
-- cleared, a new GUID -> its number
function E:add_block(graph, cls)
  local tpl = VE.templates(self.depot)[cls]
  if not tpl then error("the game has no " .. cls, 0) end
  local src = sample_tree(self.depot, tpl[1])
  return self:change(function(t)
    local n = t:adopt(src, tpl[2], graph)
    clear_links(t:obj(n))
    blank(t, n)
    local emb = t:obj(n):get("embeddedGraph")         -- a phase: its inside empty (not the sample's blocks)
    if obj_ref(emb) then
      local inner = {}
      for _, b in ipairs(t:obj(emb):get("graphBlocks") or {}) do if obj_ref(b) then inner[#inner + 1] = b end end
      for _, b in ipairs(sorted_desc(inner)) do t:remove(b) end
      clear(t:obj(emb):get("graphBlocks"))
    end
    local gb = t:obj(graph):get("graphBlocks")
    gb[#gb + 1] = n
    return n
  end)
end

-- a phase block that plays a graph of its own (empty: a start and an end) in place of a phase file
function E:phase_inside(n)
  local tpl = VE.templates(self.depot)["CQuestPhaseBlock"]
  local src = sample_tree(self.depot, tpl[1])
  local emb_src = src:obj(tpl[2]):get("embeddedGraph")
  self:change(function(t)
    local o = t:obj(n)
    if obj_ref(o:get("embeddedGraph")) then return end
    local g = t:adopt(src, emb_src, n)
    local inner = {}
    for _, b in ipairs(t:obj(g):get("graphBlocks") or {}) do if obj_ref(b) then inner[#inner + 1] = b end end
    for _, b in ipairs(sorted_desc(inner)) do t:remove(b) end
    clear(t:obj(g):get("graphBlocks"))
    o:set("embeddedGraph", g, "ptr:CQuestGraph")
    filter(o.props, function(p) return p.name ~= "phase" end)
  end)
  local g = self.tree:obj(n):get("embeddedGraph")
  local a = self:add_block(g, "CQuestPhaseInputBlock")
  local b = self:add_block(g, "CQuestPhaseOutputBlock")
  self:connect(a, "", b, "")
end

-- a phase block that plays a phase file (path) in place of a graph of its own (the inside goes)
function E:phase_from_file(n, path)
  self:change(function(t)
    local o = t:obj(n)
    local emb = o:get("embeddedGraph")
    if obj_ref(emb) then
      filter(o.props, function(p) return p.name ~= "embeddedGraph" end)
      t:remove(emb)
    end
    if o:prop("phase") == nil then o.props[#o.props + 1] = Prop("phase", "handle:CQuestPhase", 0) end
  end)
  if path and path ~= "" then self:set_ref(n, {"phase"}, path, "CQuestPhase") end
end

function E:duplicate(graph, n)
  return self:change(function(t)
    local k = t:copy(n, graph)
    clear_links(t:obj(k))
    local gb = t:obj(graph):get("graphBlocks")
    gb[#gb + 1] = k
    return k
  end)
end

-- blocks ns of another quest file (src: its bytes - or this one's) copied into graph object `graph`, with what they
-- hold, the files they name, and the links among them; links to blocks not copied are left out. New GUIDs. -> their
-- new numbers, in order.
function E:paste(graph, src, ns)
  return self:change(function(t)
    local other = TR.Tree(src)
    local new = t:adopt_many(other, ns, graph)
    local mine = {}
    for _, k in ipairs(new) do mine[k] = true end
    for _, k in ipairs(new) do
      for _, c in ipairs(conns(t, k)) do
        local bp = sprop(c, "blocks")
        if bp ~= nil then filter(bp.value, function(d) return mine[V.sget(d, "ock")] == true end) end
      end
      local gb = t:obj(graph):get("graphBlocks")
      gb[#gb + 1] = k
    end
    return new
  end)
end

-- several blocks gone at once (one undo)
function E:remove_blocks(graph, ns)
  return self:batch(function(e)
    local out = {}
    for i, n in ipairs(sorted_desc(ns)) do out[i] = e:remove_block(graph, n) end
    return out
  end)
end

-- block n gone: the links into it too, and what it holds (its conditions ...)
function E:remove_block(graph, n)
  self:change(function(t)
    for _, b in ipairs(t:obj(graph):get("graphBlocks") or {}) do
      if obj_ref(b) and b ~= n then
        for _, c in ipairs(conns(t, b)) do
          local bp = sprop(c, "blocks")
          if bp ~= nil then filter(bp.value, function(d) return V.sget(d, "ock") ~= n end) end
        end
      end
    end
    filter(t:obj(graph):get("graphBlocks"), function(b) return b ~= n end)
    t:remove(n)
  end)
end

-- --- the general blocks: any condition, any game function, any AI action
function E:_adopt_sample(t, cls, parent)
  local sample = VE.object_samples(self.depot)[cls]
  if not sample then error("the game has no " .. cls .. " to copy", 0) end
  local n = t:adopt(sample_tree(self.depot, sample[1]), sample[2], parent)
  blank(t, n)
  return n
end

-- a condition of class `cls` under a wait block (its conditions: all must hold) or as an if block's condition (the
-- one it had goes) -> its number
function E:add_condition(block, cls)
  return self:change(function(t)
    local o = t:obj(block)
    local n = self:_adopt_sample(t, cls, block)
    if o.cls == "CQuestConditionBlock" then
      local old = o:get("questCondition")
      o:set("questCondition", n, "ptr:IQuestCondition")
      if obj_ref(old) then
        n = n - before(t, old, n)
        t:remove(old)
      end
    else
      local p = o:prop("conditions")
      if p == nil then
        o.props[#o.props + 1] = Prop("conditions", "array:2,0,ptr:IQuestCondition", Array({n}))
      else
        p.value[#p.value + 1] = n
      end
    end
    return n
  end)
end

function E:remove_condition(block, cond)
  self:change(function(t)
    local p = t:obj(block):prop("conditions")
    if p ~= nil then filter(p.value, function(c) return c ~= cond end) end
    t:remove(cond)
  end)
end

-- --- objects a block is built of: a time function, a minigame, spawn set actions, conditions under and / or
-- the object under field `field` of object n made one of class `cls` (a copy of one the game has, made new); cls
-- nil: none -> its number
function E:set_object(n, field, cls, typ)
  return self:change(function(t)
    local o = t:obj(n)
    local old = o:get(field)
    local new
    if cls == nil then                                  -- none: the field left out, as the game's files do
      filter(o.props, function(p) return p.name ~= field end)
      new = 0
    else
      new = self:_adopt_sample(t, cls, n)
      o:set(field, new, typ)
    end
    if obj_ref(old) then
      if new ~= 0 then new = new - before(t, old, new) end
      t:remove(old)
    end
    return new
  end)
end

-- an object of class `cls` more in the list field `field` of object n (created when missing) -> its number
function E:add_object_item(n, field, cls, typ)
  return self:change(function(t)
    local new = cls and self:_adopt_sample(t, cls, n) or 0     -- (nil: an empty place, as the game has some)
    local o = t:obj(n)
    local p = o:prop(field)
    if p == nil then
      o.props[#o.props + 1] = Prop(field, typ, Array({new}))
    else
      p.value[#p.value + 1] = new
    end
    return new
  end)
end

function E:remove_object_item(n, field, index)
  self:change(function(t)
    local p = t:obj(n):prop(field)
    local old = table.remove(p.value, index + 1)
    if obj_ref(old) then t:remove(old) end
  end)
end

-- the journal entry field `field` of object n names: the path copied from object src_obj of quest file bytes src
-- (journal_index: where the game names that entry), as the game wrote it -> its number
function E:set_journal(n, field, src, src_obj)
  local function links(tree, k)                         -- (a path's parts are not its children: along `child`)
    local out, seen = {}, {}
    while obj_ref(k) and tree:obj(k).cls == "CJournalPath" and not seen[k] do
      out[#out + 1] = k
      seen[k] = true
      k = tree:obj(k):get("child")
    end
    return out
  end
  return self:change(function(t)
    local o = t:obj(n)
    local old = links(t, o:get(field))
    local other = (type(src) == "table" and src.objects) and src or TR.Tree(src)
    local new = t:adopt_many(other, links(other, src_obj), n)[1]
    o:set(field, new, "handle:CJournalPath")
    for _, k in ipairs(sorted_desc(old)) do             -- the old path's parts (each block has its own)
      if k < new then new = new - 1 end
      t:remove(k)
    end
    return new
  end)
end

-- as set_journal, the path's last part pointed at the entry `guid` (bytes): an objective made in the quest graph
function E:set_journal_entry(n, field, src, src_obj, guid)
  local new = self:set_journal(n, field, src, src_obj)
  self:change(function(t)
    local k, last = new, new
    while obj_ref(k) and t:obj(k).cls == "CJournalPath" do
      last = k
      k = t:obj(k):get("child")
    end
    t:obj(last):set("guid", TR.Guid(guid), "CGUID")
  end)
  return new
end

-- what a person's condition (CQuestActorCondition) checks: an object of class `cls` (CQCDistanceTo, CQCIsAlive ...)
-- in place of the one it had -> its number
function E:set_check(cond, cls)
  return self:change(function(t)
    local o = t:obj(cond)
    local old = o:get("checkType")
    if obj_ref(old) and t:obj(old).cls == cls then return old end
    local n = self:_adopt_sample(t, cls, cond)
    o:set("checkType", n, "ptr:IActorConditionType")
    if obj_ref(old) then
      n = n - before(t, old, n)
      t:remove(old)
    end
    return n
  end)
end

-- a wait block that waits for one condition of class `cls` -> the block's number
function E:add_wait(graph, cls)
  local n = self:add_block(graph, "CQuestPauseConditionBlock")
  self:change(function(t)
    local o = t:obj(n)
    local cs = {}
    for _, c in ipairs(o:get("conditions") or {}) do cs[#cs + 1] = c end
    for _, c in ipairs(cs) do
      if obj_ref(c) then t:remove(c) end
    end
    o:set("conditions", Array({}), "array:2,0,ptr:IQuestCondition")
    filter(o.props, function(p) return p.name ~= "name" end)     -- (a new block: no name yet)
  end)
  self:add_condition(n, cls)
  return n
end

-- a script block calling the game function `fn_name` with its parameters {{name, script type, value}} (the
-- signature's; value nil: empty) - as the game writes them: the parameters, then the arguments -> the block's number
function E:add_function(graph, fn_name, params)
  local n = self:add_block(graph, "CQuestScriptBlock")
  self:change(function(t)
    local o = t:obj(n)
    local plist, args = {}, {}
    for _, prm in ipairs(params or {}) do
      local pname, ptype, value = prm[1], prm[2], prm[3]
      local st = VE.SCRIPT_TYPE[ptype]
      local typ, empty
      if st then
        typ, empty = st[1], st[2]
      else
        local c = ptype:sub(1, 1)
        typ = (c:match("^%u$") or c == "#" or ptype:find(":", 1, true)) and ptype or "CName"
        empty = ""
      end
      if P.startswith(typ, "array:") then
        empty = Array({})
      elseif handle_typed(typ) or P.startswith(typ, "#") then
        empty = 0
      elseif typ == "Vector" then
        empty = Struct({Prop("X", "Float", 0.0), Prop("Y", "Float", 0.0), Prop("Z", "Float", 0.0),
                        Prop("W", "Float", 0.0)})
      end
      local v = value
      if v == nil then v = empty end
      local item = {Prop("name", "CName", pname), Prop("value", "CVariant", TR.Variant(typ, v))}
      if P.startswith(typ, "soft:") then item[#item + 1] = Prop("softHandle", "Bool", true) end  -- (a file)
      plist[#plist + 1] = Struct(item)
      args[#args + 1] = Prop(pname, typ, v)
    end
    filter(o.props, function(p) return p.name ~= "functionName" and p.name ~= "parameters" end)
    if fn_name and fn_name ~= "" then o:set("functionName", fn_name, "CName") end  -- (the files leave out empties)
    if #plist > 0 then o:set("parameters", Array(plist), "array:2,0,QuestScriptParam") end
    o:set("caption", "Script [" .. V.str(fn_name) .. "]", "String")                -- (what the game's editor writes)
    o.args = args
  end)
  return n
end

-- an AI actions block whose action is of class `cls` (a copy of one the game has) -> the block's number
function E:add_ai(graph, cls)
  local n = self:add_block(graph, "CQuestScriptedActionsBlock")
  self:change(function(t)
    local o = t:obj(n)
    local old = o:get("ai")
    local a = self:_adopt_sample(t, cls, n)
    o:set("ai", a, "handle:IAIActionTree")
    if obj_ref(old) then t:remove(old) end
  end)
  return n
end

-- GUIDs of the game's blocks that are gone or new here: a save made inside this quest remembers blocks by GUID
function E:changed_guids()
  local function guids(data)
    local t = TR.Tree(data)
    local out = {}
    for _, o in ipairs(t.objects) do
      local g = o.props and o:get("guid") or nil
      if is(g, TR.GUID) then out[g.b] = true end
    end
    return out
  end
  local was, now = guids(self.base), guids(self.data)
  local gone, new = 0, 0
  for g in pairs(was) do if not now[g] then gone = gone + 1 end end
  for g in pairs(now) do if not was[g] then new = new + 1 end end
  return {gone = gone, new = new}
end

return VE
