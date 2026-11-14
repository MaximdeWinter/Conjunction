-- custom_blocks.py: blocks of one's own - the game's phase block with a graph inside; its inputs are the Input blocks
-- inside, its outputs the Output blocks. Saved as a template it is a block of the quest graph's sidebar.
--   CB.templates() -> {template}     the library's (Documents\Conjunction\data\blocks) and Conjunction's own
--   CB.by_id(id), CB.inside(tree, n) the blocks inside custom block n, in order
--   template = {id, label, text, group, file, exposed = {field}, builtin}
local J = require("conjunction.json")
local TR = require("conjunction.cr2w_tree")
local PS = require("conjunction.pysort")
local PATHS = require("conjunction.paths")
local V = require("conjunction.vanilla_graph")
local CB = {}

CB.LIBRARY = PATHS.DATA .. "\\blocks"
CB.BUILTIN = (debug.getinfo(1, "S").source:match("^@(.*)[\\/][^\\/]*$") or ".") .. "\\data\\blocks"
CB.PHASE = "CQuestPhaseBlock"
CB.REGISTRY = "custom_blocks.json"      -- in the project: {instance GUID: {template = id, exposed = {field}}}

-- every template: Conjunction's own first, then the library's (newest last)
function CB.templates()
  local out = {}
  for _, f in ipairs({{CB.BUILTIN, true}, {CB.LIBRARY, false}}) do
    local folder, builtin = f[1], f[2]
    if w3.fs.isdir(folder) then
      local names = {}
      for _, e in ipairs(w3.fs.list(folder) or {}) do
        if not e.dir and e.name:sub(-5) == ".json" then names[#names + 1] = e.name end
      end
      for _, name in ipairs(PS.sorted(names)) do
        local ok, t = pcall(J.read, folder .. "\\" .. name)
        if ok and type(t) == "table" then
          t.file = folder .. "\\" .. (t.file or (name:sub(1, -6) .. ".w2phase"))
          t.builtin = builtin
          out[#out + 1] = t
        end
      end
    end
  end
  return PS.sorted(out, function(t) return {not t.builtin, t.order or 999} end)
end

function CB.by_id(tid)
  for _, t in ipairs(CB.templates()) do if t.id == tid then return t end end
  return nil
end

-- the blocks inside custom block n, in order (what an exposed field's "block" counts)
function CB.inside(tree, n)
  local emb = tree:obj(n):get("embeddedGraph")
  if not V.obj_ref(emb) then return {} end
  local out = {}
  for _, b in ipairs(tree:obj(emb):get("graphBlocks") or {}) do if V.obj_ref(b) then out[#out + 1] = b end end
  return out
end

-- {field, (index)} from block `block` to object `obj` under it (a condition, what it checks ...) - nil: not under it
function CB.path_to(tree, block, obj)
  if obj == block then return {} end
  local P = require("conjunction.py")
  local todo, seen = {{block, {}}}, {[block] = true}
  while #todo > 0 do
    local cur = table.remove(todo, 1)
    local n, path = cur[1], cur[2]
    for _, p in ipairs(tree:obj(n).props or {}) do
      if P.startswith(p.type, "handle:") or P.startswith(p.type, "ptr:") or P.startswith(p.type, "array:2,0,handle:") or
         P.startswith(p.type, "array:2,0,ptr:") then
        local listy = V.is_list(p.value)
        local vals = listy and p.value or {p.value}
        for k, v in ipairs(vals) do
          if V.obj_ref(v) and not seen[V.ival(v)] then
            v = V.ival(v)
            local step = {}
            for i, x in ipairs(path) do step[i] = x end
            step[#step + 1] = p.name
            if listy then step[#step + 1] = k - 1 end
            if v == obj then return step end
            seen[v] = true
            todo[#todo + 1] = {v, step}
          end
        end
      end
    end
  end
  return nil
end

-- from block n along a field's path to its object: object number, field name - nil when it is not there
function CB.walk(tree, n, field)
  local path = {}
  for i, x in ipairs(field.path or {}) do path[i] = x end
  while #path > 0 do
    local name = table.remove(path, 1)
    local v = tree:obj(n):get(name)
    if V.is_list(v) then
      if #path == 0 or math.type(path[1]) ~= "integer" or path[1] >= #v then return nil end
      v = v[table.remove(path, 1) + 1]
    end
    if not V.obj_ref(v) then return nil end
    n = V.ival(v)
  end
  return n, field.name
end

-- an exposed field of custom block `block`: object number, field name - nil when the inside changed
function CB.resolve(tree, block, field)
  local blocks = CB.inside(tree, block)
  local k = field.block
  if math.type(k) ~= "integer" or k < 0 or k >= #blocks then return nil end
  return CB.walk(tree, blocks[k + 1], field)
end

-- an exposed field that sets more than one place ("also"): its value written into the others
function CB.mirror(editor, block, field)
  for _, other in ipairs(field.also or {}) do
    local hn, hname = CB.resolve(editor.tree, block, field)
    local o2 = {}
    for k, v in pairs(other) do o2[k] = v end
    o2.label = field.label
    local tn, tname = CB.resolve(editor.tree, block, o2)
    if hn and tn then
      local p = editor.tree:obj(hn):prop(hname)
      if p then
        if p.type == "handle:CJournalPath" then
          if V.obj_ref(p.value) then editor:set_journal(tn, tname, editor.tree:to_bytes(), V.ival(p.value)) end
        else
          editor:set_field(tn, tname, TR.deepcopy(p.value), p.type)
        end
      end
    end
  end
end

local function slug(text)
  local s = require("conjunction.pystr").lower(text):gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return s ~= "" and s or "block"
end
CB.HOST = [[living_world\treasure_hunting\th1009_wolf_set.w2phase]]   -- the game's smallest phase file: the shell

-- the shell a template is kept in: the game's smallest phase file, its graph emptied
local function host(depot)
  local t = TR.Tree(depot:read(CB.HOST))
  local function graph()
    for k, o in ipairs(t.objects) do if o.cls == "CQuestGraph" then return k end end
    error("StopIteration", 0)
  end
  local g = graph()
  local blocks = {}
  for _, b in ipairs(t:obj(g):get("graphBlocks") or {}) do if V.obj_ref(b) then blocks[#blocks + 1] = b end end
  table.sort(blocks, function(a, b) return a > b end)
  for _, b in ipairs(blocks) do
    t:remove(b)
    g = graph()
  end
  local gb = t:obj(g):get("graphBlocks")
  for i = #gb, 1, -1 do gb[i] = nil end
  return t, g
end

-- custom block n of the editor's file kept as a template (its file and its description) -> the template
function CB.save_template(editor, n, label, text, exposed, group, folder, tid, order)
  if editor.tree:obj(n).cls ~= CB.PHASE then
    error("Only a custom block (a phase with a graph inside) can be a template", 0)
  end
  folder = folder or CB.LIBRARY
  w3.fs.mkdir(folder)
  local t, g = host(editor.depot)
  local k = t:adopt(editor.tree, n, g)
  local p = t:obj(k):prop("cachedConnections")         -- (its links outside are the quest's, not the template's)
  if p then
    for _, c in ipairs(p.value) do
      for _, q in ipairs(c) do if q.name == "blocks" then for i = #q.value, 1, -1 do q.value[i] = nil end end end
    end
  end
  local gb = t:obj(g):get("graphBlocks")
  gb[#gb + 1] = k
  if tid == nil then                                    -- (a name of its own: a new one; given: kept over)
    local base = slug(label)
    tid = base
    for i = 2, 998 do
      if not w3.fs.exists(folder .. "\\" .. tid .. ".json") then break end
      tid = base .. "_" .. i
    end
  end
  assert(w3.fs.write(folder .. "\\" .. tid .. ".w2phase", t:to_bytes()))
  local Y = require("conjunction.yaml")
  local list = Y.list({})
  for i, x in ipairs(exposed or {}) do list[i] = x end
  local meta = Y.map({"id", tid, "label", label, "text", text or "", "group", group or "Your blocks",
                      "file", tid .. ".w2phase", "exposed", list})
  if order ~= nil then meta.order = order end
  J.write(folder .. "\\" .. tid .. ".json", meta, {indent = 1})
  meta.file = folder .. "\\" .. tid .. ".w2phase"
  return meta
end

-- the custom block of a template file (the one block of its graph)
function CB.template_block(data)
  local t = TR.Tree(data)
  for _, o in ipairs(t.objects) do
    if o.cls == "CQuestGraph" then
      for _, b in ipairs(o:get("graphBlocks") or {}) do
        if V.obj_ref(b) and t:obj(V.ival(b)).cls == CB.PHASE then return V.ival(b) end
      end
      error("StopIteration", 0)
    end
  end
  error("StopIteration", 0)
end

-- a template put into graph object `graph` (a copy: fresh GUIDs, what it names imported) -> its number
function CB.insert(editor, graph, template)
  local data = assert(w3.fs.read(template.file))
  return editor:paste(graph, data, {CB.template_block(data)})[1]
end

-- a project's custom blocks: their template, the fields they show outside (by the block's GUID)
local Inst = {}
Inst.__index = Inst
function CB.Instances(project_dir)
  local self = setmetatable({path = project_dir and (project_dir .. "\\" .. CB.REGISTRY) or nil, data = {}}, Inst)
  if self.path and w3.fs.exists(self.path) then
    local ok, d = pcall(J.read, self.path)
    if ok and type(d) == "table" then self.data = d end
  end
  return self
end
function Inst:get(guid) return self.data[guid] or {} end
function Inst:set(guid, kv)
  local rec = self.data[guid]
  if rec == nil then
    rec = require("conjunction.yaml").map()
    self.data[guid] = rec
  end
  for k, v in pairs(kv) do rec[k] = v end
  self:save()
end
function Inst:save()
  if self.path then J.write(self.path, self.data, {indent = 1}) end
end

-- the fields custom block n shows outside: its own (Instances) else its template's
function CB.exposed_of(instances, tree, n, guid)
  local rec = instances:get(guid)
  if rec.exposed ~= nil then return rec.exposed end
  local t = rec.template and CB.by_id(rec.template) or nil
  return (t and t.exposed) or {}
end

return CB
