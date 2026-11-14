-- translator.py: where blocks of a quest graph are wired the way a template is inside, the graph shows them as that
-- template's block - one block, its values on its card; a double click shows its own blocks again. Only the view: the
-- file is not touched.
-- A template is found when its inside is a row Input -> b1 -> ... -> bk -> Output and a graph has blocks of the same
-- kinds wired one to the next by the same sockets (a scene's: any), each holding the same conditions (spawn sets: one
-- at least). Folded, no link is hidden: the template's block has the first block's inputs, the last block's outputs,
-- and a port of its own for each other link into or out of a block between.
--   TT.shapes(depot) -> {shape}    TT.find(g, shapes) -> {match}    TT.fold(g, matches) -> graph
--   TT.resolve(tree, match, field), TT.mirror(editor, guids, shape, field), TT.links_of(folded)
--   shape = {tpl, kinds, puts, outs, sig, inside}   match = {shape, blocks = {n ...}}
local CB = require("conjunction.custom_blocks")
local TR = require("conjunction.cr2w_tree")
local V = require("conjunction.vanilla_graph")
local P = require("conjunction.py")
local PS = require("conjunction.pysort")
local TT = {}

local SHAPES = {}

-- what a block holds, in counts: {{name, n} ...} sorted (conditions 1, spawnsets 2 ...)
local function sig(tree, n)
  local out = {}
  for _, p in ipairs(tree:obj(n).props or {}) do
    if (P.startswith(p.type, "array:2,0,ptr:") or P.startswith(p.type, "array:2,0,handle:")) and V.is_list(p.value) then
      out[#out + 1] = {p.name, #p.value}
    end
  end
  return PS.sorted(out)
end
TT.sig = sig

local function norm(s) if s == nil or require("conjunction.pystr").strip(s) == "" then return "" end return s end

-- the row a template's inside is, or nil (not a row: branches, more than one way in or out)
function TT.shape_of(depot, tpl)
  local ok, data = pcall(function() return assert(w3.fs.read(tpl.file)) end)
  if not ok then return nil end
  local qf = V.QuestFile(depot, tpl.file, data)
  local n = CB.template_block(data)
  local order = CB.inside(qf.tree, n)
  local g = qf:graph(V.ival(qf.tree:obj(n):get("embeddedGraph")))
  local outs = {}
  for _, l in ipairs(g.links) do
    outs[l[1]] = outs[l[1]] or {}
    table.insert(outs[l[1]], {l[2], l[3], l[4]})
  end
  local ins = {}
  for _, k in ipairs(order) do if g.blocks[k].cls == "CQuestPhaseInputBlock" then ins[#ins + 1] = k end end
  if #ins ~= 1 or #(outs[ins[1]] or {}) ~= 1 then return nil end
  local row, puts, out_s, in_row = {}, {}, {}, {}
  local o1 = outs[ins[1]][1]
  local nxt, put = o1[2], o1[3]
  while g.blocks[nxt].cls ~= "CQuestPhaseOutputBlock" do
    if in_row[nxt] or #(outs[nxt] or {}) ~= 1 then return nil end
    row[#row + 1] = nxt
    in_row[nxt] = true
    puts[#puts + 1] = norm(put)
    local o = outs[nxt][1]
    out_s[#out_s + 1] = norm(o[1])
    nxt, put = o[2], o[3]
  end
  if #row == 0 or #g.order ~= #row + 2 then return nil end
  local kinds, sigs, inside = {}, {}, {}
  for i, k in ipairs(row) do
    kinds[i] = g.blocks[k].kind.id
    sigs[i] = sig(qf.tree, k)
    for j, x in ipairs(order) do if x == k then inside[i] = j - 1 end end
  end
  return {tpl = tpl, kinds = kinds, puts = puts, outs = out_s, sig = sigs, inside = inside}
end

-- every template that is a row of at least two blocks - the longest first (a match takes its blocks first)
function TT.shapes(depot)
  local out = {}
  for _, t in ipairs(CB.templates()) do
    local size = w3.fs.size and w3.fs.size(t.file) or nil
    if w3.fs.exists(t.file) then
      local key = t.file .. "|" .. tostring(size)
      if SHAPES[key] == nil then
        local ok, s = pcall(TT.shape_of, depot, t)
        SHAPES[key] = ok and s or false        -- (a broken template is not found, that is all)
      end
      local s = SHAPES[key]
      if s and #s.kinds >= 2 then out[#out + 1] = s end
    end
  end
  return PS.sorted(out, function(s) return -#s.kinds end)
end

TT.FREE = {scene = true, talk = true, context_talk = true}     -- (their sockets are the scene file's: any name)
TT.STRICT = {conditions = true}

-- a block's counts against the template's: conditions the same, the rest (spawn sets ...) one at least
local function fits(a_sig, want)
  local a, b = {}, {}
  for _, x in ipairs(a_sig) do a[x[1]] = x[2] end
  for _, x in ipairs(want) do b[x[1]] = x[2] end
  for k, v in pairs(b) do
    if a[k] == nil then return false end
    if TT.STRICT[k] then
      if a[k] ~= v then return false end
    elseif a[k] < math.min(v, 1) then
      return false
    end
  end
  return true
end

-- the places of graph g wired as a template is inside -> {match}
function TT.find(g, shapes)
  local tree = g.qf.tree
  local outs = {}
  for _, l in ipairs(g.links) do
    outs[l[1]] = outs[l[1]] or {}
    table.insert(outs[l[1]], {norm(l[2]), l[3], norm(l[4])})
  end
  local function kind(n)
    local k = g.blocks[n].kind
    return k and k.id or nil
  end
  local taken, found = {}, {}
  local sorted = PS.sorted(g.order)
  for _, sh in ipairs(shapes) do
    local k = #sh.kinds
    for _, n in ipairs(sorted) do
      if not taken[n] and kind(n) == sh.kinds[1] then
        local row, in_row = {n}, {[n] = true}
        for i = 2, k do
          local free_out, free_in = TT.FREE[sh.kinds[i - 1]], TT.FREE[sh.kinds[i]]
          local nxt = {}
          for _, o in ipairs(outs[row[#row]] or {}) do
            local s, b, p = o[1], o[2], o[3]
            if (free_out or s == sh.outs[i - 1]) and (free_in or p == sh.puts[i]) and kind(b) == sh.kinds[i] and
               not in_row[b] and not taken[b] then
              nxt[#nxt + 1] = b
            end
          end
          if #nxt ~= 1 then break end
          row[#row + 1] = nxt[1]
          in_row[nxt[1]] = true
        end
        local ok = #row == k
        if ok then
          for i, x in ipairs(row) do if not fits(sig(tree, x), sh.sig[i]) then ok = false break end end
        end
        if ok then                                       -- (one link between neighbours: the row's own)
          local c = 0
          for i = 1, k - 1 do
            for _, o in ipairs(outs[row[i]] or {}) do if o[2] == row[i + 1] then c = c + 1 end end
          end
          ok = c == k - 1
        end
        if ok then
          for _, x in ipairs(row) do taken[x] = true end
          found[#found + 1] = {shape = sh, blocks = row}
        end
      end
    end
  end
  return found
end

-- an exposed field of the template, in the blocks of a match: object, name - nil when it is not there
function TT.resolve(tree, match, field)
  local sh = match.shape
  for i, x in ipairs(sh.inside) do
    if x == field.block then return CB.walk(tree, match.blocks[i], field) end
  end
  return nil
end

-- custom_blocks.mirror for a match (its blocks by their GUIDs: numbers move as a journal path is put in)
function TT.mirror(editor, guids, shape, field)
  if not P.T(field.also) then return end
  local function where(f)
    for i, x in ipairs(shape.inside) do
      if x == f.block then
        local want = guids[i]
        for k, o in ipairs(editor.tree.objects) do
          local g = o.props and o:get("guid") or nil
          if TR.is(g, TR.GUID) and g.b == want then return CB.walk(editor.tree, k, f) end
        end
        return nil
      end
    end
    return nil
  end
  for _, other in ipairs(field.also) do
    local o2 = {}
    for k, v in pairs(other) do o2[k] = v end
    o2.label = field.label
    local hn, hname = where(field)
    local tn, tname = where(o2)
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

-- an exposed field's value in a few words (the line on the template's block)
function TT.value_text(g, match, field)
  local tree = g.qf.tree
  local obj, name = TT.resolve(tree, match, field)
  if obj == nil then return "" end
  local p = tree:obj(obj):prop(name)
  if p == nil then return "(default)" end
  if p.type == "handle:CJournalPath" then               -- the block's own line names it: its last part
    local idx
    for i, x in ipairs(match.shape.inside) do if x == field.block then idx = i end end
    local b = g.blocks[match.blocks[idx]]
    local line = b and (b.lines[1] or "") or ""
    return line:match("([^/]*)$"):gsub("^ ", "")
  end
  if P.startswith(p.type, "soft:") or P.startswith(p.type, "handle:") then
    local path = V.truth(p.value) and g.qf:import_path(p.value) or ""
    if path == "" then return "(none)" end
    return (V.basename(path):gsub("%.[^.]*$", ""))
  end
  local v = p.value
  if V.is_list(v) then
    local out = {}
    for i, x in ipairs(v) do out[i] = V.str(x):match("([^\\]*)$") end
    return table.concat(out, ", ")
  end
  return V.str(v)
end

local function short(g, n)
  local b = g.blocks[n]
  local label = b.kind and b.kind.label or b.title
  return (label:match("^([^:]*)"))
end

-- graph g as shown with templates: a shallow copy, each match one block (n: its first block's)
function TT.fold(g, matches)
  if #matches == 0 then return g end
  local out = setmetatable({}, getmetatable(g))
  for k, v in pairs(g) do out[k] = v end
  out.blocks, out.order = {}, {}
  for _, n in ipairs(g.order) do out.blocks[n] = g.blocks[n] end
  local where, gone = {}, {}
  local made = {}
  for _, m in ipairs(matches) do
    local first, last = m.blocks[1], m.blocks[#m.blocks]
    local tpl = m.shape.tpl
    local name = ""
    for _, x in ipairs(m.blocks) do if g.blocks[x].name ~= "" then name = g.blocks[x].name break end end
    local lines = {}
    for _, f in ipairs(tpl.exposed or {}) do
      if #lines < 3 then lines[#lines + 1] = P.str(f.label) .. ": " .. TT.value_text(g, m, f) end
    end
    local v = {n = first, cls = "template", family = "template", title = P.str(tpl.label), name = name,
               lines = lines, inputs = {}, outputs = {}, x = 0, y = 0, w = 0, h = 0, kind = nil,
               comment = g.blocks[first].comment, opens = {"fold", first}, ports = {}, folded = m.blocks, match = m,
               last = last}
    for i, s in ipairs(g.blocks[first].inputs) do
      v.inputs[i] = s
      v.ports["in\0" .. s] = {first, s}
    end
    for i, s in ipairs(g.blocks[last].outputs) do
      v.outputs[i] = s
      v.ports["out\0" .. s] = {last, s}
    end
    for i, x in ipairs(m.blocks) do
      gone[x] = true
      where[x] = {first, i}
    end
    made[#made + 1] = v
  end
  for _, n in ipairs(g.order) do if not gone[n] then out.order[#out.order + 1] = n end end
  for n in pairs(gone) do out.blocks[n] = nil end
  for _, v in ipairs(made) do                           -- (added again: after the others, in the matches' order)
    out.blocks[v.n] = v
    out.order[#out.order + 1] = v.n
  end
  local links = {}
  for _, l in ipairs(g.links) do
    local a, s, b, p = l[1], l[2], l[3], l[4]
    local wa, wb = where[a], where[b]
    if not (wa and wb and wa[1] == wb[1] and wb[2] == wa[2] + 1) then   -- (the row's own link: inside the block)
      if wa then
        local v = out.blocks[wa[1]]
        if a ~= v.last then                             -- out of a block between: a port of its own
          local port = short(g, a) .. " > " .. (s ~= "" and s or "Out")
          if not v.ports["out\0" .. port] then
            v.outputs[#v.outputs + 1] = port
            v.ports["out\0" .. port] = {a, s}
          end
          s = port
        end
        a = wa[1]
      end
      if wb then
        local v = out.blocks[wb[1]]
        if b ~= wb[1] then                              -- into a block between
          local port = "> " .. short(g, b) .. (p ~= "" and (" " .. p) or "")
          if not v.ports["in\0" .. port] then
            v.inputs[#v.inputs + 1] = port
            v.ports["in\0" .. port] = {b, p}
          end
          p = port
        end
        b = wb[1]
      end
      links[#links + 1] = {a, s, b, p}
    end
  end
  out.links = links
  out.wires = {}
  return out
end

-- the file's links from a folded graph: each drawn link through its ports, and each template's own links
function TT.links_of(gf)
  local out = {}
  for _, l in ipairs(gf.links) do
    local a, s, b, p = l[1], l[2], l[3], l[4]
    local ba, bb = gf.blocks[a], gf.blocks[b]
    if ba and ba.ports then
      local r = ba.ports["out\0" .. s]
      a, s = r[1], r[2]
    end
    if bb and bb.ports then
      local r = bb.ports["in\0" .. p]
      b, p = r[1], r[2]
    end
    out[#out + 1] = {a, s, b, p}
  end
  local g = gf.qf:graph(gf.n)
  for _, n in ipairs(gf.order) do
    local v = gf.blocks[n]
    if v.folded then
      for i = 1, #v.folded - 1 do
        for _, l in ipairs(g.links) do
          if l[1] == v.folded[i] and l[3] == v.folded[i + 1] then out[#out + 1] = l end
        end
      end
    end
  end
  return out
end

return TT
