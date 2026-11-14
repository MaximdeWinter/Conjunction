-- block_card.py's BlockCard: the picked block's card in the quest graph - what the block is and does in plain words,
-- where else the file uses its facts, how the game uses its kind (a click opens the place), then its settings as
-- fields one fills in (a yes/no a tick, a choice a list, a fact or a tag typed) for the block and for what sits under
-- it (a wait's conditions, what a person's condition checks, a game function's values). Fields the game's file leaves
-- out are shown with the default and written when changed; the rarely set ones behind "More settings".
--   local card = BC.new(window)   card:show_block(qf, b)   card:frame(r)
-- A QScrollArea (resizable, no frame) round a column (margins 10 8 10 10, 4 apart); each item a node of qw.lua.
local BL = require("conjunction.blocks")
local GC = require("conjunction.game_catalog")
local TR = require("conjunction.cr2w_tree")
local V = require("conjunction.vanilla_graph")
local P = require("conjunction.py")
local PS = require("conjunction.pysort")
local R = require("conjunction.pyre")
local S = require("conjunction.pystr")
local Y = require("conjunction.yaml")
local W = require("conjunction.ui.qw")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local T = require("conjunction.ui.theme")
local TL = require("conjunction.ui.textlayout")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local D = w3.ui.draw
local BC = {}
BC.__index = BC

local function hex(s) return (tonumber(s:sub(2), 16) << 8) | 255 end
BC.C = {bg = hex("#18181b"), label = hex("#c8c8cc"), kind = hex("#f2f2f4"), what = hex("#a8a8b0"),
        section = hex("#8c8c94"), hint = hex("#7c7c84"), example_bg = hex("#1f1f23"), example_edge = hex("#2c2c32"),
        example_fg = hex("#b8b8c0"), example_hover = hex("#d9a441"), fact_hover = hex("#5cb85c"),
        more = hex("#8c8c94"), more_hover = hex("#f0f0f2"), more_on = hex("#c8c8cc"), journal = hex("#4fb3bf")}
local C = BC.C
-- (label style: colour, px, bold, padding above)
BC.LABELS = {[""] = {C.label, 12, false, 0}, kind = {C.kind, 15, true, 0}, what = {C.what, 12, false, 0},
             section = {C.section, 11, true, 8}, hint = {C.hint, 11, false, 0}}
BC.QUIET = {guid = true, cachedConnections = true, name = true, comment = true, embeddedGraph = true,
            conditions = true, questCondition = true, ai = true, checkType = true, parameters = true,
            functionName = true, graphBlocks = true, spawnsets = true}
BC.INTS = {Int8 = true, Uint8 = true, Int16 = true, Uint16 = true, Int32 = true, Uint32 = true, Int64 = true,
           Uint64 = true}
local SIMPLE = {Bool = true, Int8 = true, Uint8 = true, Int16 = true, Uint16 = true, Int32 = true, Uint32 = true,
                Int64 = true, Uint64 = true, Float = true, Double = true}
BC.LIST_ITEMS = {String = true, CName = true, Bool = true, Int32 = true, Uint32 = true, Float = true, Uint8 = true,
                 Int8 = true, Uint16 = true, Int16 = true, CGUID = true}
BC.VECTOR = {Vector = {"X", "Y", "Z", "W"}, EulerAngles = {"Pitch", "Yaw", "Roll"}}
BC.OBJECT_HEADS = {conditions = "Waits for", questCondition = "Checks", ai = "Does", checkType = "What it checks",
                   spawnsets = "Spawn sets", ["function"] = "Time", minigame = "Minigame"}
BC.FILE_CLASSES = {CStoryScene = true, CQuestPhase = true, CCommunity = true, CEntityTemplate = true, CBehTree = true,
                   CEnvironmentDefinition = true, CResource = true, CWorld = true, CMesh = true,
                   CSkeletalAnimationSet = true}
BC.FILE_EXT = {CStoryScene = ".w2scene", CCommunity = ".w2comm", CQuestPhase = ".w2phase", CEntityTemplate = ".w2ent",
               CBehTree = ".w2behtree", CEnvironmentDefinition = ".env"}
local EDITABLE_FILES = {CStoryScene = true, CQuestPhase = true, CCommunity = true, CEntityTemplate = true,
                        CBehTree = true, CEnvironmentDefinition = true}
BC.ROW_LABEL = 132

-- --- the app's helpers
local HUMAN = R.compile([[[A-Z]+(?=[A-Z][a-z]|\d|\b)|[A-Z]?[a-z]+|\d+|[A-Z]+]])
-- factId -> "Fact ID", isInside -> "Is inside", npcTag -> "Npc tag"
function BC.human(name)
  local words = HUMAN:findall(P.replace(name, "_", " "))
  local text
  if #words > 0 then
    local out = {}
    for k, w in ipairs(words) do
      out[k] = k > 1 and S.lower(w) or (S.upper(w:sub(1, 1)) .. S.lower(w:sub(2)))
    end
    text = table.concat(out, " ")
  else
    text = name
  end
  if P.endswith(text, " id") then text = text:sub(1, -3) .. "ID" end
  return text
end
local human = BC.human

function BC.editable_type(typ)
  if SIMPLE[typ] or typ == "CName" or typ == "String" or typ == "StringAnsi" or typ == "TagList" or typ == "name" or
     typ == "string" or typ == "bool" or typ == "int" or typ == "float" then
    return true
  end
  if (P.startswith(typ, "soft:") or P.startswith(typ, "handle:C")) and not P.startswith(typ, "handle:CJournalPath") then
    return EDITABLE_FILES[typ:match("^[^:]*:(.*)$")] == true
  end
  if P.startswith(typ, "array:2,0,") then
    local inner = typ:sub(11)
    if BC.LIST_ITEMS[inner] or TR.is_enum(inner) then return true end
  end
  if typ == "Vector" or typ == "EulerAngles" or typ == "GameTime" or typ == "EngineTransform" then return true end
  return TR.is_enum(typ)
end

-- does a field of this type hold objects of the file (not a file, not the journal - those have fields)?
function BC.object_type(typ)
  local inner = P.startswith(typ, "array:2,0,") and typ:sub(11) or typ
  if not (P.startswith(inner, "ptr:") or P.startswith(inner, "handle:")) then return false end
  local cls = inner:match("^[^:]*:(.*)$")
  return cls ~= "CJournalPath" and cls ~= "CQuestGraph" and cls ~= "CQuestGraphBlock" and not BC.FILE_CLASSES[cls]
end

-- is a struct made only of plain parts (yes/no, numbers, words, choices, tags, files - or structs of them)?
function BC.struct_simple(v, depth)
  depth = depth or 0
  if depth > 4 then return false end
  for _, q in ipairs(v) do
    if TR.is(q.value, TR.STRUCT) then
      if not BC.struct_simple(q.value, depth + 1) then return false end
    elseif V.is_list(q.value) and not TR.is(q.value, TR.TAGS) then
      for _, x in ipairs(q.value) do
        local plain = type(x) == "number" or type(x) == "string" or type(x) == "boolean" or TR.is(x, TR.WIDE) or
                      TR.is(x, TR.SOFT) or TR.is(x, TR.LOC)
        if not ((TR.is(x, TR.STRUCT) and BC.struct_simple(x, depth + 1)) or plain) then return false end
      end
    elseif (P.startswith(q.type, "handle:") or P.startswith(q.type, "ptr:")) and V.obj_ref(q.value) then
      return false
    elseif TR.is(q.value, TR.GUID) then
      return false
    end
  end
  return true
end

local function item_text(v)
  if TR.is(v, TR.GUID) or TR.is(v, TR.RAW) then
    return (v.b:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end
  if type(v) == "boolean" then return v and "yes" or "no" end
  if math.type(v) == "float" then return V.g(v) end
  return V.str(v)
end

-- one item of a list typed as text: yes/no, a number, a word
local function item(typ, text)
  text = S.strip(text)
  local NUM = require("conjunction.pynum")
  if typ == "Bool" then
    local l = S.lower(text)
    return l == "yes" or l == "true" or l == "1" or l == "on"
  end
  if typ == "Float" then return NUM.float(P.replace(text, ",", ".")) end
  if typ == "Int32" or typ == "Uint32" or typ == "Uint8" or typ == "Int8" or typ == "Uint16" or typ == "Int16" then
    local f = NUM.float(text)
    return math.tointeger(f >= 0 and math.floor(f) or math.ceil(f))
  end
  if typ == "CGUID" then
    local h = text:gsub("%-", "")
    return TR.Guid((h:gsub("..", function(x) return string.char(tonumber(x, 16)) end)))
  end
  return text
end

local function game_time_text(secs)
  secs = math.tointeger(secs) or math.floor(secs)
  local d, rest = secs // 86400, secs % 86400
  local h, rest2 = rest // 3600, rest % 3600
  local m, s = rest2 // 60, rest2 % 60
  return (d ~= 0 and (d .. "d ") or "") .. string.format("%02d:%02d", h, m) .. (s ~= 0 and string.format(":%02d", s) or "")
end

local function transform_text(t)
  local parts = {}
  for i, part in ipairs({t.position, t.rotation, t.scale}) do
    local xs = {}
    for k, x in ipairs(part or {}) do xs[k] = V.g(x) end
    parts[i] = V.truth(part) and table.concat(xs, ", ") or ""
  end
  return table.concat(parts, "; ")
end

-- --- the card
function BC.new(window)
  local self = setmetatable({window = window, items = {}, more_open = {}, bar = IV.bar(20, 0, 0), bar_state = {},
                             qf = nil, b = nil, finished = {}, journal = {}}, BC)
  return self
end

function BC:catalog()
  if self._catalog == nil then
    self._catalog = GC.load() or {classes = {}, functions = {}, enums = {}}
  end
  return self._catalog
end
local function classes(cat) return P.get(cat, "classes") or {} end
local function fields_of(cat, cls) return P.get(P.get(classes(cat), cls) or {}, "fields") or {} end

-- --- building the card: a list of items, laid out each frame
function BC:show_block(qf, b)
  self.qf, self.b = qf, b
  self.items = {}
  self.journal = {}
  self.seq = 0
  if b ~= nil and b.folded then self:folded() elseif b ~= nil then self:build() end
  IV.set(self.bar, 0)
end

function BC:add(it)
  self.seq = self.seq + 1
  it.id = it.id or ("vg.card." .. self.seq)
  self.items[#self.items + 1] = it
  return it
end
function BC:label(text, style) return self:add({t = "label", text = text, style = style or ""}) end
function BC:row(text, field, hint)
  return self:add({t = "row", text = text, field = field, hint = hint})
end

function BC:build()
  local qf, b = self.qf, self.b
  local o = qf.tree:obj(b.n)
  local kind = b.kind or BL.kind_of(qf.tree, b.n)
  self:add({t = "bar", colour = hex(BL.GROUP_COLOUR[kind.group] or "#6a6a74")})
  self:label(b.title, "kind")
  local what = kind.text
  if not kind.simple then
    local doc = self:game_doc(o)
    if doc ~= "" then what = doc end
  end
  self:label(what, "what")
  local group = ""
  for _, g in ipairs(BL.GROUPS) do if g[1] == kind.group then group = g[2] end end
  self:label(group .. " · " .. o.cls .. (kind.simple and "" or " · a game block"), "hint")
  self:fact_refs(b.n)
  self:examples(kind)
  self:name_field(o, b.n)
  for _, key in ipairs(self:journal_fields(o)) do self:journal_row(b.n, key, o) end
  if o.cls == "CQuestPhaseBlock" then self:custom(b.n, o) end
  if o.cls == "CQuestPhaseBlock" then               -- a phase: a graph of its own, or a phase file
    local inside = V.obj_ref(o:get("embeddedGraph"))
    local n = b.n
    self:row("Plays", {k = "combo", items = {"Its own graph (double click to open)", "A phase file"},
                       index = inside and 1 or 2, pick = function(i)
      self.window:edit(function(e)
        if i == 1 then e:phase_inside(n) else e:phase_from_file(n, nil) end
      end)
    end})
    if b.opens then
      self:row("", {k = "button", text = "Open the phase", click = function() self.window:open_block(n) end})
    end
  end
  self:fields(b.n, o, "Settings")
  if o.cls == "CQuestSceneBlock" or o.cls == "CQuestInteractionDialogBlock" or o.cls == "CQuestContextDialogBlock" then
    self:scene(o)
  end
  self:structs(b.n, o)
  if o.cls == "CQuestScriptBlock" then self:params(b.n, o) end
  self:objects(b.n, o)
  if o.cls ~= "CCommentGraphBlock" and o.cls ~= "CDescriptionGraphBlock" then
    local p = o:prop("comment")
    local typ = p and p.type or "String"
    self:label("Note", "section")
    local n = b.n
    self:row("Comment", self:line(b.comment, "a note for yourself (not in the game)", function(text)
      self.window:edit(function(e) e:set_field(n, "comment", text, typ) end)
    end))
  end
end

-- a template's block the translator shows: what it does, its values (set here, in those blocks), its blocks; "Show
-- its blocks" opens it up
function BC:folded()
  local TT = require("conjunction.translator")
  local b, tree = self.b, self.qf.tree
  local m = b.match
  local tpl = m.shape.tpl
  self:add({t = "bar", colour = hex(V.FAMILY.template)})
  self:label(P.str(tpl.label), "kind")
  self:label(P.str(tpl.text or ""), "what")
  self:label("Template: " .. #m.blocks .. " game blocks shown as one (the file stays unchanged)", "hint")
  if b.name ~= "" then self:label("Named: " .. b.name, "hint") end
  local guids = {}
  for i, x in ipairs(m.blocks) do
    local g = tree:obj(x):get("guid")
    guids[i] = TR.is(g, TR.GUID) and g.b or ""
  end
  self:set_here(b.n, tpl.exposed or {}, function(f) return TT.resolve(tree, m, f) end,
                function(e, f) TT.mirror(e, guids, m.shape, f) end)
  local n = b.n
  self:row("", {k = "button", text = "Show its blocks", tip = "The game's blocks it is made of, each on its own " ..
                                                              "(double click does the same)",
                click = function() self.window:unfold(n) end})
  for _, x in ipairs(m.blocks) do self:fact_refs(x) end  -- (the facts its blocks set or wait for: where else)
  self:label("Its blocks", "section")
  local _, qf, gn = self.window:here()
  local g = qf:graph(gn)
  for _, x in ipairs(m.blocks) do
    local bx = g.blocks[x]
    if bx then self:label(bx.title .. (#bx.lines > 0 and (" - " .. bx.lines[1]) or ""), "hint") end
  end
end

function BC:game_doc(o)
  local cat = self:catalog()
  if o.cls == "CQuestScriptBlock" then
    local fn = V.str(o:get("functionName"))
    local f = P.get(P.get(cat, "functions") or {}, fn) or {}
    local script = P.get(f, "script")
    return "Calls the game's quest function " .. fn .. (P.T(script) and (" (" .. script .. ")") or "") .. "."
  end
  local c = P.get(classes(cat), o.cls) or {}
  return P.str(P.or_(P.get(c, "doc"), ""))
end

-- a scene: who is in it, its ways in and out, how much is said
function BC:scene(o)
  local s = o:get("scene")
  local path = V.truth(s) and self.qf:import_path(s) or nil
  if not path then return end
  local ok, info = pcall(require("conjunction.scene_swap").outline, self.window:depot(), path)
  if not ok then return end
  self:label("The scene", "section")
  local who = {}
  for _, a in ipairs(info.actors or {}) do
    if a.voicetag and a.voicetag ~= "" then who[#who + 1] = S.title and S.title(a.voicetag) or BC.title(a.voicetag) end
  end
  local ins = {}
  for _, i in ipairs(info.inputs or {}) do ins[#ins + 1] = i.name end
  local rows = {{"Who", #who > 0 and table.concat(who, ", ") or "-"},
                {"Ways in", #ins > 0 and table.concat(ins, ", ") or "-"},
                {"Ways out", #(info.outputs or {}) > 0 and table.concat(info.outputs, ", ") or "-"},
                {"Lines", tostring(info.lines or 0)}}
  for _, r in ipairs(rows) do self:row(r[1], {k = "text", text = r[2]}) end
end

-- str.title(): a letter after a letter small, the others capital
function BC.title(s)
  local out, prev = {}, false
  for _, c in utf8.codes(s) do
    local ch = utf8.char(c)
    local letter = S.isalpha(ch)
    if letter then
      out[#out + 1] = prev and S.lower(ch) or S.upper(ch)
    else
      out[#out + 1] = ch
    end
    prev = letter
  end
  return table.concat(out)
end

-- a fact: every block of the file that sets or reads it
function BC:fact_refs(n)
  local FR = require("conjunction.fact_refs")
  local names = FR.facts_of(self.qf.tree, n)
  local list = {}
  for k in pairs(names) do list[#list + 1] = k end
  if #list == 0 then return end
  list = PS.sorted(list)
  local found = FR.uses(self.qf, names)
  local others = {}
  for _, u in ipairs(found) do if u.block ~= n then others[#others + 1] = u end end
  self:label("This fact in this file: " .. table.concat(list, ", ") .. " (" .. #others .. " other blocks)", "section")
  for k = 1, math.min(12, #others) do
    local u = others[k]
    local text = u.what .. ": " .. u.title .. (u.name ~= "" and (' "' .. u.name .. '"') or "") ..
                 (u.where ~= "" and ("  - in " .. u.where) or "")
    self:add({t = "example", lines = {text}, pad = 3, hover = C.fact_hover, click = function()
      self.window:open_place(u.trail, u.guid)
    end})
  end
  if #others > 12 then self:label("... and " .. (#others - 12) .. " more", "hint") end
end

local function elide(text, mode, width)
  local ok, s = pcall(w3.plugin.cj_qt_elide, "8", tostring(mode), tostring(width), text)
  return ok and s or text
end

-- how the game uses a kind: real places, a click opens them
function BC:examples(kind)
  local ex = P.get(require("conjunction.block_examples").load() or {}, kind.id) or {}
  local here = #self.window.trail > 0 and self.window:here().path or nil
  local items = {}
  for _, x in ipairs(P.get(ex, "examples") or {}) do
    if x.file ~= here and #items < 3 then items[#items + 1] = x end
  end
  if #items == 0 then return end
  self:label(string.format("How the game uses it (%s times in %s quest files)", P.str(ex.count), P.str(ex.files)),
             "section")
  local width = math.max(160, (self.vw or 442) - 60)
  for _, x in ipairs(items) do
    local where = P.str(x.quest) .. (P.T(P.get(x, "where")) and (" > " .. x.where) or "")
    local lines = {}
    for i, l in ipairs(P.get(x, "lines") or {}) do lines[i] = P.str(l) end
    local text = (P.T(P.get(x, "name")) and ('"' .. P.str(x.name) .. '" - ') or "") .. table.concat(lines, "; ")
    self:add({t = "example", raw = {where, text}, width = width, pad = 4, hover = C.example_hover,
              tip = "Opens this place in the quest graph", click = function() self.window:open_example(x) end})
  end
end

function BC:name_field(o, n)
  if o.cls == "CQuestPhaseInputBlock" or o.cls == "CQuestPhaseOutputBlock" then return end
  local p = o:prop("name")
  local typ = p and p.type or "String"
  self:row("Name", self:line(V.str(V.or_(o:get("name"), "")), "what you call this block in the graph", function(text)
    self.window:edit(function(e) e:set_field(n, "name", text, typ) end)
  end))
end

-- --- the journal entry a block names
function BC:journal_fields(o)
  local names, seen = {}, {}
  for _, p in ipairs(o.props or {}) do
    if p.type == "handle:CJournalPath" then
      names[#names + 1] = p.name
      seen[p.name] = true
    end
  end
  local cf = fields_of(self:catalog(), o.cls)
  for _, k in ipairs(Y.keys(cf)) do
    if P.get(cf[k], "type") == "handle:CJournalPath" and not seen[k] then names[#names + 1] = k end
  end
  return names
end

-- the entries one can pick: the own quest's objectives, this file's own, then the game's
function BC:journal_entries()
  local JI = require("conjunction.journal_index")
  local e = self.window:here()
  local names = JI.Names(self.window:depot())
  local own = JI.of_tree(e.tree, e.path)
  for _, x in ipairs(own) do
    x.label, x.kind = names:label(x.chain)
    x.here = true
  end
  if BC.journal_index == nil then BC.journal_index = JI.load() or false end
  local game = BC.journal_index and BC.journal_index.entries or {}
  local keys = {}
  for _, x in ipairs(own) do keys[x.key] = true end
  local out = {}
  if e._own and self.window.project_dir then              -- the own quest: all its objectives
    for _, ob in ipairs(JI.own_objectives(self.window.project_dir)) do
      out[#out + 1] = {key = "own:" .. ob.guid, label = ob.caption ~= "" and ob.caption or ob.id, kind = "objective",
                       here = true, own_guid = ob.guid, count = 0}
    end
  end
  for _, x in ipairs(own) do out[#out + 1] = x end
  for _, x in ipairs(game) do if not keys[x.key] then out[#out + 1] = x end end
  return out
end

-- the journal entry field `key` of object n: what it names, Choose (a search over the journal under it)
function BC:journal_row(n, key, o, label)
  local JI = require("conjunction.journal_index")
  local cur = o:get(key)
  local text = "(none)"
  if V.obj_ref(cur) then
    local ch = JI.chain(self.qf.tree, V.ival(cur))
    local l, kind = JI.Names(self.window:depot()):label(ch)
    local here = self.window:here()
    if here._own and self.window.project_dir then        -- the own quest's: its text
      for _, ob in ipairs(JI.own_objectives(self.window.project_dir)) do
        if #ch > 0 and ch[#ch][2] == ob.guid then l, kind = ob.caption, "objective of this quest" end
      end
    end
    text = kind ~= "" and (l .. "  (" .. kind .. ")") or l
  end
  local jkey = n .. ":" .. key
  local row = self:row(label or human(key), {k = "journal", text = text, n = n, key = key, jkey = jkey})
  if label == nil then self:outside_tick(row, n, key) end
  self:add({t = "journal", n = n, key = key, jkey = jkey})
end

-- a journal entry picked: the path copied as the game wrote it (an own objective: shaped like one the quest has)
function BC:journal_pick(n, key, e)
  local w = self.window
  local here = w:here()
  if e.own_guid then
    local JI = require("conjunction.journal_index")
    local guids = {}
    for _, ob in ipairs(JI.own_objectives(w.project_dir)) do guids[ob.guid] = true end
    local model
    for _, x in ipairs(JI.of_tree(here.tree, here.path)) do
      if guids[x.chain[#x.chain][2]] then model = x break end
    end
    if model == nil then
      w.state = "The quest has no objective in the graph yet to copy the shape from"
      return
    end
    local guid = e.own_guid:gsub("..", function(h) return string.char(tonumber(h, 16)) end)
    w:edit(function(ed) return ed:set_journal_entry(n, key, ed.data, model.obj, guid) end)
    return
  end
  local src = e.here and here.data or w:depot():read(e.file)
  w:edit(function(ed) return ed:set_journal(n, key, src, e.obj) end)
end

-- --- the objects a block is built of
function BC:object_fields(o)
  local cf = fields_of(self:catalog(), o.cls)
  local out, seen = {}, {}
  for _, p in ipairs(o.props or {}) do
    if BC.object_type(p.type) then
      out[#out + 1] = {p.name, p.type, p.value}
      seen[p.name] = true
    end
  end
  for _, name in ipairs(Y.keys(cf)) do
    if not seen[name] and BC.object_type(P.get(cf[name], "type") or "") then out[#out + 1] = {name, cf[name].type, nil} end
  end
  return out
end

-- the classes an object field can hold: those the game puts there, the most used first
function BC:candidates(cls, field, typ)
  local cat = classes(self:catalog())
  local f = P.get(fields_of(self:catalog(), cls), field) or {}
  local out, have = {}, {}
  for _, vc in ipairs(P.get(f, "values") or {}) do
    local v = P.str(vc[1])
    if P.startswith(v, "→ ") then
      local c = v:sub(#"→ " + 1)
      out[#out + 1] = c
      have[c] = true
    end
  end
  local role = typ:find("IQuestCondition", 1, true) and "condition" or (typ:find("IAIAction", 1, true) and "ai" or
                                                                         ("part of " .. cls))
  local more = {}
  for _, k in ipairs(Y.keys(cat)) do
    local c = cat[k]
    if P.get(c, "role") == role or P.has(P.get(c, "roles") or {}, role) then more[#more + 1] = k end
  end
  more = PS.sorted(more, function(k) return -(P.get(cat[k], "count") or 0) end)
  for _, k in ipairs(more) do if not have[k] then out[#out + 1] = k end end
  return out
end

function BC:sub(head, n)
  local so = self.qf.tree:obj(n)
  self:label(head .. ": " .. GC.label(so.cls), "section")
  local text = ""
  if so.cls:find("Condition", 1, true) or P.startswith(so.cls, "W3QuestCond") or P.startswith(so.cls, "CQC") then
    text = BL.condition_text(self.qf, n)
  end
  if text ~= "" then self:label(text, "hint") end
  self:fields(n, so, nil)
  self:structs(n, so)
  self:objects(n, so)
end

function BC:objects(n, o)
  for _, of in ipairs(self:object_fields(o)) do
    local field, typ, value = of[1], of[2], of[3]
    local head = BC.OBJECT_HEADS[field] or human(field)
    local opts = self:candidates(o.cls, field, typ)
    if P.startswith(typ, "array:") then
      local items = {}
      for k, v in ipairs(V.truth(value) and value or {}) do
        if math.type(v) == "integer" then items[#items + 1] = {k - 1, v} end
      end
      self:label(head .. " (" .. #items .. ")", "section")
      for _, kv in ipairs(items) do
        local k, c = kv[1], kv[2]
        if c > 0 then self:sub(tostring(k + 1), c) else self:label((k + 1) .. ": (empty)", "hint") end
        self:add({t = "more", text = "Remove", click = function()
          self.window:edit(function(e) e:remove_object_item(n, field, k) end)
        end})
      end
      local texts, datas = {"Add ..."}, {false}
      for _, c in ipairs(opts) do
        texts[#texts + 1] = GC.label(c)
        datas[#datas + 1] = c
      end
      self:row("", {k = "combo", items = texts, index = 1, pick = function(i)
        if i > 1 then self.window:edit(function(e) return e:add_object_item(n, field, datas[i], typ) end) end
      end})
    else
      local cur = V.obj_ref(value) and self.qf.tree:obj(V.ival(value)).cls or nil
      local texts, datas = {"(none)"}, {false}
      local list = {}
      local known = false
      for _, c in ipairs(opts) do if c == cur then known = true end end
      if cur and not known then list[1] = cur end
      for _, c in ipairs(opts) do list[#list + 1] = c end
      local index = 1
      for _, c in ipairs(list) do
        texts[#texts + 1] = GC.label(c)
        datas[#datas + 1] = c
        if c == cur and index == 1 then index = #texts end
      end
      self:label(head, "section")
      self:row("Kind", {k = "combo", items = texts, index = index, pick = function(i)
        self.window:edit(function(e) return e:set_object(n, field, datas[i] or nil, typ) end)
      end})
      if cur then
        local vn = V.ival(value)
        self:fields(vn, self.qf.tree:obj(vn), nil)
        self:objects(vn, self.qf.tree:obj(vn))
      end
    end
  end
end

-- --- fields
function BC:known_fields(o)
  local cat = self:catalog()
  local cls = P.get(classes(cat), o.cls) or {}
  local cf = P.get(cls, "fields") or {}
  local out, seen = {}, {}
  for _, p in ipairs(o.props or {}) do
    local a_file = (P.startswith(p.type, "soft:") or P.startswith(p.type, "handle:")) and
                   (TR.is(p.value, TR.SOFT) or (math.type(p.value) == "integer" and p.value < 0))
    if not (BC.QUIET[p.name] or not (BC.editable_type(p.type) or a_file)) then
      seen[p.name] = true
      local f = P.get(cf, p.name) or {}
      out[#out + 1] = {p.name, p.type, p.value, P.get(f, "hint"), GC.default_of(cat, o.cls, p.name),
                       P.get(f, "values") or {}, true}
    end
  end
  local total = math.max(P.get(cls, "count") or 1, 1)
  for _, name in ipairs(Y.keys(cf)) do
    local f = cf[name]
    if not (seen[name] or BC.QUIET[name] or not BC.editable_type(P.get(f, "type") or "")) then
      local common = (P.get(f, "count") or 0) / total >= 0.2
      out[#out + 1] = {name, f.type, nil, P.get(f, "hint"), GC.default_of(cat, o.cls, name), P.get(f, "values") or {},
                       common}
    end
  end
  return out
end

function BC:fields(n, o, title)
  local rows = self:known_fields(o)
  if title and #rows > 0 then self:label(title, "section") end
  local more = {}
  local first_at
  for _, r in ipairs(rows) do
    local name, typ, value, hint, default, values, common = table.unpack(r, 1, 7)
    local w = self:field(n, name, typ, value, default, values)
    local row = self:row(human(name), w, hint)
    self:outside_tick(row, n, name)
    if not common then
      more[#more + 1] = row
      first_at = first_at or #self.items
    end
  end
  if #more > 0 then
    local key = n .. ":" .. tostring(title)
    local toggle = {t = "more", text = "More settings (" .. #more .. ")", checkable = true, key = key}
    self.seq = self.seq + 1
    toggle.id = "vg.card." .. self.seq
    table.insert(self.items, first_at, toggle)
    for _, row in ipairs(more) do row.more_key = key end
  end
end

function BC:line(text, placeholder, done, values)
  local seen = {}
  for _, v in ipairs(values or {}) do seen[#seen + 1] = v end
  return {k = "edit", text = text or "", placeholder = placeholder or "", done = done, values = seen}
end

local function number(write, typ, text)
  text = P.replace(S.strip(text), ",", ".")
  if text == "" then return end
  local NUM = require("conjunction.pynum")
  local ok, f = pcall(NUM.float, text)
  if not ok then return end
  if typ == "Float" or typ == "Double" then write(f) else
    write(math.tointeger(f >= 0 and math.floor(f) or math.ceil(f)))
  end
end

-- a field for one value; a change written through the window's editor
function BC:field(n, name, typ, value, default, values, edit)
  local seen = {}
  for _, vc in ipairs(values or {}) do
    local v = vc[1]
    if v ~= nil and v ~= Y.null and v ~= "" then seen[#seen + 1] = v end
  end
  edit = edit or function(fn) return self.window:edit(fn) end
  local function write(v) edit(function(e) e:set_field(n, name, v, typ) end) end
  if typ == "Bool" or typ == "bool" then
    local cur = value
    if cur == nil then cur = default and true or false end
    return {k = "check", checked = V.truth(cur), text = value == nil and "(default)" or "",
            toggle = function(on) write(on) end}
  end
  if TR.is_enum(typ) then
    local opts = GC.enum_values(self:catalog(), typ, seen)
    local cur = value
    if cur == nil then cur = P.T(default) and default or (opts[1] or "") end
    cur = V.str(cur)
    local known = false
    for _, x in ipairs(opts) do if V.str(x) == cur then known = true end end
    if cur ~= "" and not known then table.insert(opts, 1, cur) end
    local texts, index = {}, 1
    for i, x in ipairs(opts) do
      texts[i] = V.str(x)
      if texts[i] == cur then index = i end
    end
    return {k = "combo", items = texts, index = index, pick = function(i) write(texts[i]) end}
  end
  if BC.INTS[typ] or typ == "Float" or typ == "Double" then
    local shown = value == nil and "" or (math.type(value) == "float" and V.g(value) or V.str(value))
    local ph = (type(default) == "number") and ("default " .. V.g(default)) or "the game's default"
    return self:line(shown, ph, function(text) number(write, typ, text) end, seen)
  end
  if typ == "TagList" then
    local parts = {}
    for i, x in ipairs(value or {}) do parts[i] = V.str(x) end
    return self:line(table.concat(parts, ", "), "tags, comma separated", function(text)
      local tags = {}
      for x in text:gmatch("[^,]+") do
        x = S.strip(x)
        if x ~= "" then tags[#tags + 1] = x end
      end
      write(TR.Tags(tags))
    end, seen)
  end
  if P.startswith(typ, "array:2,0,") then
    local inner = typ:sub(11)
    local parts = {}
    for i, x in ipairs(value or {}) do parts[i] = item_text(x) end
    return self:line(table.concat(parts, ", "), "comma separated" .. (inner == "Bool" and " (yes / no)" or ""),
                     function(text)
      local out = {}
      for x in text:gmatch("[^,]+") do if S.strip(x) ~= "" then out[#out + 1] = item(inner, x) end end
      write(TR.Array(out))
    end, seen)
  end
  if typ == "EngineTransform" then
    return self:line(value == nil and "" or transform_text(value), "x, y, z; pitch, yaw, roll; scale x, y, z",
                     function(text)
      local parts = {}
      for x in (text .. ";;;"):gmatch("([^;]*);") do parts[#parts + 1] = S.strip(x) end
      local function nums(s)
        local out = {}
        for x in s:gmatch("[^,%s]+") do out[#out + 1] = require("conjunction.pynum").float(x) end
        return #out > 0 and out or nil
      end
      write(TR.Transform(nums(parts[1]), nums(parts[2]), nums(parts[3])))
    end)
  end
  if typ == "GameTime" then
    local secs = nil
    if value ~= nil then secs = TR.sget(value, "m_seconds", 0) end
    return self:line(secs == nil and "" or game_time_text(secs), "hh:mm (a day more: 1d 08:00)", function(text)
      text = S.lower(S.strip(text))
      local days = 0
      local dpart, rest = text:match("^(.-)d(.*)$")
      if dpart then days = tonumber(S.strip(dpart)) or 0 text = rest end
      local ps = {}
      for x in S.strip(text):gmatch("[^:]+") do if S.strip(x) ~= "" then ps[#ps + 1] = math.tointeger(tonumber(x)) end end
      ps[#ps + 1], ps[#ps + 2], ps[#ps + 3] = 0, 0, 0
      write(TR.Struct({TR.Prop("m_seconds", "Int32", days * 86400 + ps[1] * 3600 + ps[2] * 60 + ps[3])}))
    end)
  end
  if BC.VECTOR[typ] then
    local keys = BC.VECTOR[typ]
    local shown = ""
    if value ~= nil then
      local parts = {}
      for i, k in ipairs(keys) do parts[i] = V.g(TR.sget(value, k, 0.0)) end
      shown = table.concat(parts, ", ")
    end
    local low = {}
    for i, k in ipairs(keys) do low[i] = S.lower(k) end
    return self:line(shown, table.concat(low, ", "), function(text)
      local nums = {}
      for x in S.strip(text):gmatch("[^,;%s]+") do nums[#nums + 1] = require("conjunction.pynum").float(x) end
      local props = {}
      for i, k in ipairs(keys) do props[i] = TR.Prop(k, "Float", nums[i] or 0.0) end
      write(TR.Struct(props))
    end)
  end
  if P.startswith(typ, "soft:") or P.startswith(typ, "handle:") then
    local path = V.truth(value) and self.qf:import_path(value) or ""
    local cls = typ:match("^[^:]*:(.*)$")
    return self:line(path or "", "a file of the game", function(text)
      edit(function(e)
        local oo = e.tree:obj(n)
        if oo:prop(name) == nil then e:set_field(n, name, P.startswith(typ, "soft:") and TR.Soft(0) or 0, typ) end
        e:set_ref(n, {name}, S.strip(text), cls)
      end)
    end, seen)
  end
  return self:line(value == nil and "" or V.str(value), "", function(text) write(text) end, seen)
end

-- --- values made of parts (a book's item name, a scene's definition, a fist fight's opponents)
function BC:structs(n, o)
  for _, p in ipairs(o.props or {}) do
    if not BC.QUIET[p.name] then
      if TR.is(p.value, TR.STRUCT) and not BC.VECTOR[p.type] and p.type ~= "GameTime" and BC.struct_simple(p.value) then
        self:label(human(p.name), "section")
        self:struct_rows(n, {p.name}, p.value, "")
      elseif P.startswith(p.type, "array:2,0,") and not BC.editable_type(p.type) and not BC.object_type(p.type) then
        local all = true
        for _, x in ipairs(p.value or {}) do
          if not (TR.is(x, TR.STRUCT) and BC.struct_simple(x)) then all = false break end
        end
        if all then
          local list = p.value or {}
          self:label(human(p.name) .. " (" .. #list .. ")", "section")
          for k, x in ipairs(list) do
            self:struct_rows(n, {p.name, k - 1}, x, k .. ". ")
            local name = p.name
            self:add({t = "more", text = "Remove", click = function()
              self.window:edit(function(e) e:remove_item(n, {name, k - 1}) end)
            end})
          end
          local name = p.name
          self:add({t = "more", text = "Add", click = function()
            self.window:edit(function(e) e:add_item(n, {name}) end)
          end})
        end
      end
    end
  end
end

function BC:struct_rows(n, path, value, prefix)
  for _, q in ipairs(value) do
    local at = {}
    for i, x in ipairs(path) do at[i] = x end
    at[#at + 1] = q.name
    if V.is_list(q.value) and not TR.is(q.value, TR.TAGS) and not TR.is(q.value, TR.STRUCT) then
      self:row(prefix .. human(q.name), {k = "text", text = #q.value .. " items (see All values)"})
    elseif TR.is(q.value, TR.STRUCT) and not BC.VECTOR[q.type] and q.type ~= "GameTime" then
      self:struct_rows(n, at, q.value, prefix .. human(q.name) .. " > ")
    else
      local function write(v) self.window:edit(function(e) e:set(n, at, v) end) end
      self:row(prefix .. human(q.name), self:leaf(q.type, q.value, write))
    end
  end
end

-- a field for one part of a value (written by its path)
function BC:leaf(typ, value, write)
  if typ == "Bool" then
    return {k = "check", checked = V.truth(value), text = "", toggle = function(on) write(on) end}
  end
  if TR.is_enum(typ) then
    local opts = GC.enum_values(self:catalog(), typ, {value})
    local texts, index = {}, 1
    for _, x in ipairs(opts) do
      if x ~= nil then
        texts[#texts + 1] = V.str(x)
        if V.str(x) == V.str(value) then index = #texts end
      end
    end
    return {k = "combo", items = texts, index = index, pick = function(i) write(texts[i]) end}
  end
  if BC.INTS[typ] or typ == "Float" or typ == "Double" then
    return self:line(item_text(value), "", function(text) number(write, typ, text) end)
  end
  if typ == "TagList" then
    local parts = {}
    for i, x in ipairs(value or {}) do parts[i] = V.str(x) end
    return self:line(table.concat(parts, ", "), "tags, comma separated", function(text)
      local tags = {}
      for x in text:gmatch("[^,]+") do if S.strip(x) ~= "" then tags[#tags + 1] = S.strip(x) end end
      write(TR.Tags(tags))
    end)
  end
  if TR.is(value, TR.SOFT) or P.startswith(typ, "soft:") or P.startswith(typ, "handle:") then
    return {k = "text", text = self.qf:import_path(value) or "(none)"}
  end
  return self:line(value ~= nil and V.str(value) or "", "", function(text) write(text) end)
end

-- a game function's values: each parameter, typed as the scripts declare it
function BC:params(n, o)
  local cat = self:catalog()
  local f = P.get(P.get(cat, "functions") or {}, V.str(o:get("functionName"))) or {}
  local sig = {}
  for _, p in ipairs(P.get(f, "params") or {}) do sig[p.name] = p end
  local params = V.or_(o:get("parameters"), {})
  if #params == 0 then return end
  self:label("Values", "section")
  for _, p in ipairs(params) do
    local pname, v = V.str(V.sget(p, "name")), V.sget(p, "value")
    local typ = TR.is(v, TR.VARIANT) and v.type or "CName"
    local val = v
    if TR.is(v, TR.VARIANT) then val = v.value end      -- (a false one too)
    local s = sig[pname] or {}
    local seen = {}
    for _, vc in ipairs(P.get(s, "values") or {}) do
      if vc[1] ~= nil and vc[1] ~= Y.null and vc[1] ~= "" then seen[#seen + 1] = vc[1] end
    end
    local function write(value) self.window:edit(function(e) e:set_param(n, pname, value) end) end
    local w
    if typ == "Bool" then
      w = {k = "check", checked = V.truth(val), text = "", toggle = function(on) write(on) end}
    elseif TR.is_enum(typ) then
      local opts = {}
      for _, x in ipairs(P.get(P.get(cat, "enums") or {}, typ) or {}) do opts[#opts + 1] = x end
      if #opts == 0 then for _, x in ipairs(seen) do opts[#opts + 1] = x end end
      local cur = V.str(val)
      local known = false
      for _, x in ipairs(opts) do if V.str(x) == cur then known = true end end
      if not known then table.insert(opts, 1, cur) end
      local texts, index = {}, 1
      for i, x in ipairs(opts) do
        texts[i] = V.str(x)
        if texts[i] == cur then index = i end
      end
      w = {k = "combo", items = texts, index = index, pick = function(i) write(texts[i]) end}
    elseif BC.INTS[typ] or typ == "Float" or typ == "Double" then
      w = self:line(math.type(val) == "float" and V.g(val) or V.str(val), "", function(text) number(write, typ, text) end,
                    seen)
    else
      w = self:line(val ~= nil and V.str(val) or "", "", function(text) write(text) end, seen)
    end
    local stype = P.get(s, "type")
    self:row(human(pname), w, (stype and P.str(stype) or typ) .. (P.T(P.get(s, "optional")) and " (optional)" or ""))
  end
end

-- --- custom blocks: their fields outside, the ticks inside that choose them
function BC:custom(n, o)
  local CB = require("conjunction.custom_blocks")
  local tree = self.qf.tree
  local g = o:get("guid")
  local guid = TR.is(g, TR.GUID) and (g.b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) or ""
  local inst = self.window:instances()
  local fields = CB.exposed_of(inst, tree, n, guid)
  local rec = inst:get(guid)
  local tpl = rec.template and CB.by_id(rec.template) or nil
  if tpl then
    self:label("Template: " .. P.str(tpl.label) .. (P.T(tpl.text) and (" - " .. P.str(tpl.text)) or ""), "hint")
  end
  self:set_here(n, fields, function(f) return CB.resolve(tree, n, f) end, function(e, f) CB.mirror(e, n, f) end)
  self:row("", {k = "button", text = "Save as template", tip = "Keeps this block as a block of the sidebar " ..
                                                                 "(everything inside, the fields shown outside)",
                click = function() self:save_template(n, o, fields) end})
end

-- a template's fields, as rows: "Set it here"; where_of(field) -> object, name | nil; mirror(editor, field) writes a
-- field's value into the other places it sets (in the same undo)
function BC:set_here(n, fields, where_of, mirror)
  local tree = self.qf.tree
  if #fields > 0 then self:label("Set it here", "section") end
  for _, f in ipairs(fields) do
    local obj, name = where_of(f)
    if obj == nil then
      self:label(P.str(f.label) .. ": (no longer inside)", "hint")
    else
      local so = tree:obj(obj)
      local p = so:prop(name)
      local cf = P.get(fields_of(self:catalog(), so.cls), name) or {}
      local typ = p and p.type or (P.get(cf, "type") or "String")
      local function edit(fn)                          -- (and the places it sets as well: one undo)
        return self.window:edit(function(e) return e:batch(function(e2)
          local r = fn(e2)
          mirror(e2, f)
          return r
        end) end)
      end
      if typ == "handle:CJournalPath" then             -- an objective: chosen from the journal
        self:journal_row(obj, name, so, P.str(f.label))
      else
        local w = self:field(obj, name, typ, p and p.value or nil, GC.default_of(self:catalog(), so.cls, name),
                             P.get(cf, "values") or {}, edit)
        self:row(P.str(f.label), w, "in: " .. so.cls .. "." .. name)
      end
    end
  end
end

function BC:save_template(n, o, fields)
  local DLG = require("conjunction.ui.dialogs")
  DLG.ask_text(self.window.ed, "Save as template", "Its name in the sidebar:", function(label)
    label = S.strip(label or "")
    if label == "" then return end
    local CB = require("conjunction.custom_blocks")
    local ok, tpl = pcall(CB.save_template, self.window:here(), n, label, V.str(V.or_(o:get("comment"), "")), fields)
    if not ok then
      self.window.state = "not saved: " .. tostring(tpl)
      return
    end
    local g = o:get("guid")
    local guid = TR.is(g, TR.GUID) and (g.b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) or ""
    self.window:instances():set(guid, {template = tpl.id})
    self.window.palette:fill()
    self.window.state = "'" .. tpl.label .. "' is now a block of the sidebar (Blocks)"
  end, V.str(V.or_(o:get("name"), "My block")))
end

-- inside a custom block: a tick that shows this field on the custom block's card outside
function BC:outside_tick(row, obj, name)
  local CB = require("conjunction.custom_blocks")
  local outer = self.window:inside_custom()
  if outer == nil or self.b == nil then return end
  local tree = self.qf.tree
  local blocks_in = CB.inside(tree, outer)
  local at
  for i, x in ipairs(blocks_in) do if x == self.b.n then at = i - 1 end end
  if at == nil then return end
  local path = CB.path_to(tree, self.b.n, obj)
  if path == nil then return end
  local field = {label = human(name), block = at, path = path, name = name}
  local og = tree:obj(outer):get("guid")
  local guid = TR.is(og, TR.GUID) and (og.b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) or ""
  local inst = self.window:instances()
  local function same(f)
    if f.block ~= field.block or f.name ~= name then return false end
    local fp = f.path or {}
    if #fp ~= #path then return false end
    for i = 1, #fp do if fp[i] ~= path[i] then return false end end
    return true
  end
  local on = false
  for _, f in ipairs(CB.exposed_of(inst, tree, outer, guid)) do if same(f) then on = true end end
  row.tick = {checked = on, toggle = function(now)
    local list = require("conjunction.yaml").list({})
    for _, f in ipairs(CB.exposed_of(inst, tree, outer, guid)) do if not same(f) then list[#list + 1] = f end end
    if now then list[#list + 1] = field end
    inst:set(guid, {exposed = list})
  end}
end

-- ===================================================================================================================
-- laid out and drawn
local function label_lines(text, px, bold, w) return TL.wrap(text, px, bold, math.max(0, w), "word") end

function BC:node(it)
  local st = BC.LABELS[it.style or ""]
  if it.t == "bar" then
    return W.leaf{w = 0, h = 3, fixed_h = 3, hpol = "preferred", draw = function(_, r)
      D.fill(r.x, r.y, r.w, r.h, it.colour)
    end}
  elseif it.t == "label" then
    local colour, px, bold, pad = st[1], st[2], st[3], st[4]
    local indent = pad > 0 and Q.label_indent(px, bold) // 2 or 0    -- (a padding gives it a frame: the indent)
    local lh = Q.line_h(px, bold)
    return W.leaf{w = Q.hint_w(it.text, px, bold) + indent, h = lh + pad, min_w = 0, hpol = "preferred",
                  hfw = function(w) return math.max(1, #label_lines(it.text, px, bold, w - indent)) * lh + pad end,
                  draw = function(_, r)
      local ls = label_lines(it.text, px, bold, r.w - indent)
      for i, l in ipairs(ls) do Q.text(r.x + indent, r.y + pad + (i - 1) * lh, colour, l.s, px, bold, C.bg) end
    end}
  elseif it.t == "example" then
    local lh = Q.line_h(11)
    local n = it.raw and 2 or #it.lines
    local h = n * lh + 2 * it.pad + 2
    return W.leaf{w = 0, h = h, fixed_h = h, hpol = "preferred", draw = function(_, r)
      local lines = it.lines
      if it.raw then
        local width = math.max(160, (self.vw or r.w + 20) - 60)
        it.cache = it.cache or {}
        if it.cache.w ~= width then
          it.cache = {w = width, l = {elide(it.raw[1], 2, width), elide(it.raw[2], 1, width)}}
        end
        lines = it.cache.l
      end
      local clicked, hovered = CT.hit_box(it.id, r)
      Q.frame(r.x, r.y, r.w, r.h, C.example_bg, hovered and it.hover or C.example_edge)
      D.clip(r.x + 1, r.y + 1, r.w - 2, r.h - 2, function()
        for i, l in ipairs(lines) do
          Q.text(r.x + 1 + 6, r.y + 1 + it.pad + (i - 1) * lh, C.example_fg, l, 11, false, C.example_bg)
        end
      end)
      if hovered and it.tip then CT.tip(it.id, {"", it.tip}) end
      if clicked and it.click then self.pending = it.click end
    end}
  elseif it.t == "more" then
    local px = T.FONT
    local lh = Q.line_h(px)
    return W.leaf{w = Q.hint_w(it.text, px), h = lh + 4, fixed_h = lh + 4, hpol = "preferred", draw = function(_, r)
      local clicked, hovered = CT.hit_box(it.id, r)
      local on = it.checkable and self.more_open[it.key]
      local fg = hovered and C.more_hover or (on and C.more_on or C.more)
      Q.text(r.x, r.y + 2, fg, it.text, px, false, C.bg)
      if clicked then
        if it.checkable then self.more_open[it.key] = not self.more_open[it.key]
        elseif it.click then self.pending = it.click end
      end
    end}
  elseif it.t == "journal" then
    return self:journal_node(it)
  elseif it.t == "row" then
    local lab = W.leaf{w = BC.ROW_LABEL, h = Q.line_h(12), fixed_w = BC.ROW_LABEL, vpol = "preferred",
                       draw = function(_, r)
      local text = Q.elide(it.text, "right", BC.ROW_LABEL - 4, 12)
      Q.text(r.x, r.y + Q.vcenter(r.h, Q.line_h(12)), C.label, text, 12, false, C.bg)
      if it.text ~= "" and CT.over(r) then CT.tip(it.id .. ".label", {"", it.text .. (it.hint and (": " .. it.hint) or "")}) end
    end}
    local parts = {lab, self:field_node(it, it.field)}
    if it.tick then                                    -- (inside a custom block: "outside")
      local tw, th = Q.check_size("outside", 12)
      parts[#parts + 1] = W.leaf{w = tw, h = th, draw = function(_, r)
        local toggled, on = CT.check(it.id .. ".outside", r.x, r.y, "outside", it.tick.checked,
                                     {h = r.h, bg = C.bg, px = 12, fg = C.section,
                                      tip = {"", "Shows this field on the custom block's card (whoever uses the block " ..
                                                 "sets it there)"}})
        if toggled then
          it.tick.checked = on
          local tg = it.tick.toggle
          self.pending = function() tg(on) end
        end
      end}
    end
    return W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, parts),
                    {hidden = it.more_key ~= nil and not self.more_open[it.more_key]})
  end
end

-- the search under a journal row: a field, the entries that hold its words (300 at most, 220 px at most), and for
-- the own quest a new objective
local LIST_ROW = 22
function BC:journal_node(it)
  local j = self.journal[it.jkey]
  local open = j ~= nil and j.open
  local eh = CT.edit_h(self.window:edit_style())
  local items = {}
  if open then
    local words = {}
    for wd in S.lower(j.search):gmatch("%S+") do words[#words + 1] = wd end
    local shown = {}
    for _, e in ipairs(j.entries) do
      local hay = S.lower(P.str(e.label) .. " " .. P.str(e.kind or ""))
      local all = true
      for _, wd in ipairs(words) do if not hay:find(wd, 1, true) then all = false break end end
      if all then
        shown[#shown + 1] = e
        if #shown >= 300 then break end
      end
    end
    j.shown = shown
    items[#items + 1] = W.leaf{w = 180, h = eh, fixed_h = eh, hpol = "expanding", draw = function(_, r)
      local _, text = CT.edit("vg.card.journal." .. it.jkey .. ".search", r.x, r.y, r.w, j.search,
                              {placeholder = "Search the journal (quest, objective)", style = self.window:edit_style()})
      j.search = text
    end}
    local lh = math.min(220, #shown * LIST_ROW + 2)
    items[#items + 1] = W.leaf{w = 180, h = lh, fixed_h = lh, hpol = "expanding", draw = function(_, r)
      Q.frame(r.x, r.y, r.w, r.h, T.SURFACE, T.LINE)
      local bar = j.bar
      bar.single, bar.page = 1, (r.h - 2) // LIST_ROW
      IV.range(bar, #shown - bar.page)
      local _, hovered = CT.hit_box("vg.card.journal." .. it.jkey .. ".list", r)
      local mx, my, wheel = w3.ui.mouse()
      if hovered and wheel and wheel ~= 0 then IV.wheel(bar, wheel, 3) end
      local vw = r.w - 2 - (#shown > bar.page and 10 or 0)
      local hot = hovered and bar.value + (my - r.y - 1) // LIST_ROW + 1 or nil
      if hot and shown[hot] and w3.ui.mouse_clicked(1) then
        j.current = shown[hot]
        if w3.ui.mouse_double(1) then
          local e, n, key = shown[hot], it.n, it.key
          self.pending = function() self:journal_pick(n, key, e) end
        end
      end
      D.clip(r.x + 1, r.y + 1, vw, r.h - 2, function()
        for k = bar.value + 1, math.min(#shown, bar.value + bar.page + 1) do
          local e = shown[k]
          local y = r.y + 1 + (k - 1 - bar.value) * LIST_ROW
          local chosen, hov = j.current == e, k == hot
          local bg = chosen and T.CHOSEN or (hov and T.HOVER or T.SURFACE)
          if bg ~= T.SURFACE then D.fill(r.x + 1, y, vw, LIST_ROW, bg) end
          local text = P.str(e.label) .. "  (" .. P.str(P.T(e.kind) and e.kind or "?") .. ")" ..
                       (e.here and "  (this quest)" or "")
          Q.text(r.x + 1 + 6, y + (LIST_ROW - Q.line_h(T.FONT_LIST)) // 2, chosen and T.WHITE or T.BUTTON_TEXT,
                 Q.elide(text, "right", vw - 12, T.FONT_LIST), T.FONT_LIST, false, bg)
        end
      end)
      if #shown > bar.page then
        SBAR.draw(j.state, "vg.card.journal." .. it.jkey .. ".bar", bar, {x = r.x + 1 + vw, y = r.y + 1, w = 10,
                                                                           h = r.h - 2}, "v",
                  function(id, rr) return CT.hit_box(id, rr) end)
      end
    end}
    local here = self.window:here()
    if here._own and self.window.project_dir then      -- a new objective for the own quest
      local bw, bh = Q.button_size("Add")
      j.new = j.new or ""
      local function made()
        local text = S.strip(j.new)
        if text == "" then return end
        require("conjunction.project_gen").new_graph_objective(self.window.project_dir, text)
        j.new = ""
        self.window.state = "Objective '" .. text .. "' added. It is in the journal after the next build " ..
                            "(Build now: Build tab)"
      end
      items[#items + 1] = W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, {
        W.leaf{w = 180, h = eh, fixed_h = eh, hpol = "expanding", stretch = 1, draw = function(_, r)
          local _, text, enter = CT.edit("vg.card.journal." .. it.jkey .. ".new", r.x, r.y, r.w, j.new,
                                         {placeholder = "New objective", style = self.window:edit_style()})
          j.new = text
          if enter then self.pending = made end
        end},
        W.leaf{w = bw, h = bh, draw = function(_, r)
          if CT.button("vg.card.journal." .. it.jkey .. ".add", r.x, r.y, "Add", {w = r.w, h = r.h,
                                                                                    fg = T.BUTTON_TEXT}) then
            self.pending = made
          end
        end}}))
    end
  end
  return W.widget(W.vbox({margins = {0, 0, 0, 4}, spacing = 6}, items), {hidden = not open})
end

function BC:field_node(row, f)
  local id = row.id .. ".f"
  local node
  if f.k == "edit" then
    local eh = CT.edit_h(self.window:edit_style())
    node = W.leaf{w = 180, h = eh, min_w = 40, hpol = "expanding", fixed_h = eh, draw = function(_, r)
      local was = CT.focus == id
      local _, text, enter = CT.edit(id, r.x, r.y, r.w, f.text, {placeholder = f.placeholder ~= "" and f.placeholder
                                                                  or nil, style = self.window:edit_style(),
                                                                  tip = row.hint and {"", row.hint} or nil})
      f.now = text
      local left = was and CT.focus ~= id
      if (enter or left) and text ~= f.text and f.done then
        local done = f.done
        self.pending = function() done(text) end
      end
    end}
  elseif f.k == "check" then
    local w, h = Q.check_size(f.text, 12)       -- (the card's QCheckBox: 12 px, as the app's own)
    node = W.leaf{w = w, h = h, hpol = "preferred", draw = function(_, r)
      local toggled, on = CT.check(id, r.x, r.y, f.text, f.checked, {h = r.h, bg = C.bg, px = 12, fg = C.section})
      if toggled and f.toggle then
        local tg = f.toggle
        self.pending = function() tg(on) end
      end
    end}
  elseif f.k == "combo" then
    local ch = CT.edit_h()                      -- (QComboBox: as high as a line edit, the theme's padding)
    node = W.leaf{w = 180, h = ch, hpol = "expanding", fixed_h = ch, draw = function(_, r)
      local changed, i = CT.combo(id, r.x, r.y, r.w, f.items, f.index, self.window.win and self.window.win.rect or r,
                                  {h = r.h, fg = T.BRIGHT})
      if changed and f.pick then
        local pick = f.pick
        self.pending = function() pick(i) end
      end
    end}
  elseif f.k == "button" then
    local bw, bh = Q.button_size(f.text)
    node = W.leaf{w = bw, h = bh, hpol = "expanding", draw = function(_, r)
      if CT.button(id, r.x, r.y, f.text, {w = r.w, h = r.h, fg = T.BUTTON_TEXT, tip = f.tip and {"", f.tip} or nil})
         and f.click then
        self.pending = f.click
      end
    end}
  elseif f.k == "journal" then
    local bw, bh = Q.button_size("Choose")
    node = W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, {
      W.leaf{w = Q.hint_w(f.text, 12), h = Q.line_h(12), min_w = 0, hpol = "preferred", stretch = 1,
             draw = function(_, r)
        Q.text(r.x, r.y + Q.vcenter(r.h, Q.line_h(12)), C.journal, Q.elide(f.text, "right", r.w, 12), 12, false, C.bg)
      end},
      W.leaf{w = bw, h = bh, draw = function(_, r)
        if CT.button(id .. ".choose", r.x, r.y, "Choose", {w = r.w, h = r.h, fg = T.BUTTON_TEXT}) then
          local j = self.journal[f.jkey]
          if j == nil then
            j = {entries = self:journal_entries(), search = "", open = false, bar = IV.bar(1, 0, 0), state = {}}
            self.journal[f.jkey] = j
          end
          j.open = not j.open
          if j.open then CT.set_focus("vg.card.journal." .. f.jkey .. ".search") end
        end
      end}}))
    node.stretch = 1
    return node
  else
    local lh = Q.line_h(12)
    node = W.leaf{w = Q.hint_w(f.text, 12), h = lh, min_w = 0, hpol = "preferred",
                  hfw = function(w) return math.max(1, #label_lines(f.text, 12, false, w)) * lh end,
                  draw = function(_, r)
      for i, l in ipairs(label_lines(f.text, 12, false, r.w)) do
        Q.text(r.x, r.y + (i - 1) * lh, C.label, l.s, 12, false, C.bg)
      end
    end}
  end
  node.stretch = 1
  return node
end

function BC:frame(r)
  D.fill(r.x, r.y, r.w, r.h, C.bg)
  if self.b == nil then return end
  local nodes = {}
  for _, it in ipairs(self.items) do nodes[#nodes + 1] = self:node(it) end
  nodes[#nodes + 1] = W.stretch(1)
  local body = W.widget(W.vbox({margins = {10, 8, 10, 10}, spacing = 4}, nodes))
  -- (QScrollArea, resizable: the body as wide as the viewport, as high as it needs - a bar when it needs more)
  local vw, vh = r.w, r.h
  local bh = W.hfw(body, vw)
  if bh > vh then
    vw = vw - 10
    bh = W.hfw(body, vw)
  end
  self.vw = vw
  local bar = self.bar
  bar.page = vh
  IV.range(bar, math.max(0, bh - vh))
  local mx, my, wheel = w3.ui.mouse()
  if CT.over(r) and wheel and wheel ~= 0 then IV.wheel(bar, wheel, 3) end
  self.pending = nil
  W.place(body, r.x, r.y - bar.value, vw, math.max(bh, vh))
  D.clip(r.x, r.y, vw, vh, function() W.draw(body) end)
  if bh > vh then
    SBAR.draw(self.bar_state, "vg.card.bar", bar, {x = r.x + vw, y = r.y, w = 10, h = vh}, "v",
              function(id, rr) return CT.hit_box(id, rr) end)
  end
  if self.pending then
    local fn = self.pending
    self.pending = nil
    fn()
  end
end

return BC
