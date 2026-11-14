-- A game scene (.w2scene, cooked) as it is, to change in place: its flow (inputs, sections, conditions, randoms,
-- scripts, outputs), each section's elements (lines, pauses, comments, a cutscene) and its choice, and the director's
-- events of each element (cameras, look-ats, gestures, mimics ...). Everything the game's file has stays: an
-- unchanged scene is written back byte for byte, a change touches only what it changes (scene_check.lua: all 6225
-- scenes of the game).
--   local s = SF.open(bytes)
--   s:flow()                  -> {nodes by number, order} - what the scene does, in reading order from its inputs
--   s:elements(sec)           -> the section's elements {n, kind, id, speaker, text, duration}
--   s:events_of(sec, el)      -> the events of one element {k, cls, start, props}
--   s:set_text(el, id), s:set_duration(el, secs), s:set_speaker(el, tag), s:remove_element(sec, el),
--   s:insert_line(sec, after, speaker, id, secs, regie_from), s:move_element(sec, el, by), s:set_choice_text(cl, id),
--   s:remove_choice(cl), s:set_fact_check(cond, fact, op, value), s:set_event(sec, k, name, value),
--   s:remove_event(sec, k), s:add_input(target, name)
--   s:bytes()
local TR = require("conjunction.cr2w_tree")
local SF = {}
local S = {}
S.__index = S
SF.S = S                                  -- (scene_timeline.lua adds the timeline's methods)

SF.SECTIONS = {CStorySceneSection = true, CStorySceneCutsceneSection = true, CStorySceneVideoSection = true}
SF.DEFAULT_INPUT, SF.DEFAULT_OUTPUT = "Input", "Output"
-- what each kind of control part leads to: {property, label} (a list: one link per item)
SF.LINKS = {
  CStorySceneInput = {{"nextLinkElement"}},
  CStorySceneSection = {{"nextLinkElement"}},
  CStorySceneCutsceneSection = {{"nextLinkElement"}},
  CStorySceneVideoSection = {{"nextLinkElement"}},
  CStorySceneLinkHub = {{"nextLinkElement"}},
  CStorySceneScript = {{"nextLinkElement"}, {"links", "out", list = true}},
  CStorySceneFlowCondition = {{"trueLink", "yes"}, {"falseLink", "no"}},
  CStorySceneRandomizer = {{"outputs", "random", list = true}},
  CStorySceneFlowSwitch = {{"defaultLink", "else"}},
  CStorySceneLinkElement = {{"nextLinkElement"}},
}
SF.KINDS = {CStorySceneInput = "input", CStorySceneOutput = "output", CStorySceneSection = "section",
            CStorySceneCutsceneSection = "cutscene", CStorySceneVideoSection = "video",
            CStorySceneFlowCondition = "if", CStorySceneRandomizer = "random", CStorySceneScript = "script",
            CStorySceneLinkHub = "hub", CStorySceneFlowSwitch = "switch"}
SF.ELEMENTS = {CStorySceneLine = "line", CStoryScenePauseElement = "pause", CStorySceneComment = "comment",
               CStorySceneCutscenePlayer = "cutscene", CStorySceneVideoElement = "video",
               CStorySceneQuestChoiceLine = "quest choice"}
SF.OPS = {CF_Equal = "=", CF_NotEqual = "!=", CF_Less = "<", CF_LessEqual = "<=", CF_Greater = ">",
          CF_GreaterEqual = ">="}
SF.OP_NAMES = {}
for k, v in pairs(SF.OPS) do SF.OP_NAMES[v] = k end

local function loc(v) return TR.is(v, TR.LOC) and v.n or nil end

function SF.open(data)
  local t = TR.Tree(data, {events = true})
  local self = setmetatable({t = t, data = data}, S)
  return self
end

function S:obj(n) return self.t.objects[n] end
function S:root() return self.t.objects[1] end
function S:bytes() return self.t:to_bytes() end

-- the object a link points at, past the plain link elements in between (CStorySceneLinkElement)
function S:target(n)
  local seen = {}
  while n and n > 0 and not seen[n] do
    seen[n] = true
    local o = self:obj(n)
    if not o or o.cls ~= "CStorySceneLinkElement" then return n end
    n = o:get("nextLinkElement", 0)
  end
  return 0
end

function S:name_of(n)
  local o = self:obj(n)
  if not o then return "" end
  if o.cls == "CStorySceneInput" then return o:get("inputName", SF.DEFAULT_INPUT) end
  if o.cls == "CStorySceneOutput" then return o:get("name", SF.DEFAULT_OUTPUT) end
  if SF.SECTIONS[o.cls] then return o:get("sectionName", "") end
  return o:get("comment", "") or ""
end

function S:inputs()
  local out = {}
  for _, n in ipairs(self:root():get("controlParts") or {}) do
    local o = self:obj(n)
    if o and o.cls == "CStorySceneInput" then out[#out + 1] = {n = n, name = self:name_of(n)} end
  end
  return out
end

function S:outputs()
  local out = {}
  for _, n in ipairs(self:root():get("controlParts") or {}) do
    local o = self:obj(n)
    if o and o.cls == "CStorySceneOutput" then out[#out + 1] = {n = n, name = self:name_of(n)} end
  end
  return out
end

function S:actors()
  local out = {}
  for _, n in ipairs(self:root():get("sceneTemplates") or {}) do
    local o = self:obj(n)
    if o then out[#out + 1] = {n = n, id = o:get("id", ""), tags = o:get("actorTags")} end
  end
  return out
end

function S:cameras()
  local out = {}
  for _, st in ipairs(self:root():get("cameraDefinitions") or {}) do out[#out + 1] = TR.sget(st, "cameraName", "") end
  return out
end

-- the links of a control part: {{label, to}} (to: the part it leads to, 0 = nowhere)
function S:links(n)
  local o = self:obj(n)
  local out = {}
  if not o then return out end
  for _, spec in ipairs(SF.LINKS[o.cls] or {}) do
    local v = o:get(spec[1])
    if spec.list then
      for k, x in ipairs(v or {}) do out[#out + 1] = {label = (spec[2] or "") .. " " .. k, to = self:target(x)} end
    elseif v ~= nil then
      out[#out + 1] = {label = spec[2] or "", to = self:target(v)}
    end
  end
  if o.cls == "CStorySceneFlowSwitch" then
    for k, c in ipairs(o:get("cases") or {}) do
      local co = self:obj(c)
      if co then out[#out + 1] = {label = "case " .. k, to = self:target(co:get("thenLink", 0))} end
    end
  end
  if SF.SECTIONS[o.cls] then
    local ch = self:obj(o:get("choice", 0))
    if ch then
      for _, cl in ipairs(ch:get("choiceLines") or {}) do
        local c = self:obj(cl)
        if c then out[#out + 1] = {label = "answer", choice = cl, to = self:target(c:get("nextLinkElement", 0))} end
      end
    end
  end
  return out
end

-- the scene in reading order: from each input on, depth first along the links; parts no input reaches at the end
function S:flow()
  local order, seen = {}, {}
  local function visit(n)
    if not n or n <= 0 or seen[n] then return end
    seen[n] = true
    order[#order + 1] = n
    for _, l in ipairs(self:links(n)) do visit(l.to) end
  end
  for _, i in ipairs(self:inputs()) do visit(i.n) end
  for _, n in ipairs(self:root():get("controlParts") or {}) do
    local o = self:obj(n)
    if o and o.cls ~= "CStorySceneLinkElement" then visit(n) end
  end
  local nodes = {}
  for _, n in ipairs(order) do
    local o = self:obj(n)
    nodes[n] = {n = n, kind = SF.KINDS[o.cls] or o.cls, name = self:name_of(n), links = self:links(n)}
  end
  return {nodes = nodes, order = order}
end

-- --- a section's elements and their events
function S:elements(sec)
  local o = self:obj(sec)
  local out = {}
  for _, n in ipairs(o and o:get("sceneElements") or {}) do
    local e = self:obj(n)
    if e then
      out[#out + 1] = {n = n, cls = e.cls, kind = SF.ELEMENTS[e.cls] or e.cls, id = e:get("elementID", ""),
                       speaker = e:get("voicetag", ""), text = loc(e:get("dialogLine")) or loc(e:get("commentText")),
                       duration = e:get("approvedDuration", e:get("duration", 0))}
    end
  end
  return out
end

function S:choice(sec)
  local o = self:obj(sec)
  local ch = o and self:obj(o:get("choice", 0))
  if not ch then return nil end
  local out = {n = o:get("choice"), lines = {}}
  for _, cl in ipairs(ch:get("choiceLines") or {}) do
    local c = self:obj(cl)
    if c then
      out.lines[#out.lines + 1] = {n = cl, text = loc(c:get("choiceLine")), to = self:target(c:get("nextLinkElement", 0)),
                                   once = c:get("singleUseChoice", false), emphasis = c:get("emphasisLine", false),
                                   condition = c:get("questCondition", 0)}
    end
  end
  return out
end

-- the events of a section {k, cls, element (its number), start, props}, those of one element with el
function S:events_of(sec, el)
  local o = self:obj(sec)
  local out = {}
  for k, ev in ipairs(o and o.events or {}) do
    local e = TR.sget(ev.props, "sceneElement", 0)
    if not el or e == el then
      out[#out + 1] = {k = k, cls = ev.cls, element = e, start = TR.sget(ev.props, "startPosition", 0), props = ev.props}
    end
  end
  return out
end

-- a fact check (CQuestFactsDBCondition) -> fact, op, value; nil for any other condition
function S:fact_check(n)
  local o = self:obj(n)
  if not o or (o.cls ~= "CQuestFactsDBCondition" and o.cls ~= "CQuestFactsDBForbiddenCondition") then return nil end
  return o:get("factId", ""), SF.OPS[o:get("compareFunc", "CF_Equal")] or "=", o:get("value", 0),
         o:get("queryFact", "QF_Sum"), o.cls == "CQuestFactsDBForbiddenCondition"
end

-- every fact the scene asks (its ifs, its answers' conditions) and sets (scripts' and events' AddFact): {name = {reads
-- = {where ...}, sets = {...}}}
function S:facts()
  local out = {}
  local function note(name, how, where)
    if not name or name == "" then return end
    out[name] = out[name] or {reads = {}, sets = {}}
    table.insert(out[name][how], where)
  end
  for n, o in ipairs(self.t.objects) do
    if o.cls == "CQuestFactsDBCondition" or o.cls == "CQuestFactsDBForbiddenCondition" then
      note(o:get("factId"), "reads", n)
    elseif o.cls == "CStorySceneScript" then
      for _, a in ipairs(o.args or {}) do
        if (a.name == "factName" or a.name == "factId" or a.name == "fact") and type(a.value) == "string" then
          note(a.value, "sets", n)
        end
      end
    end
    for _, ev in ipairs(o.events or {}) do
      if ev.cls == "CStorySceneAddFactEvent" then note(TR.sget(ev.props, "factId"), "sets", n) end
    end
  end
  return out
end

-- --- changing it
local function index_of(list, v)
  for k, x in ipairs(list or {}) do if x == v then return k end end
  return nil
end

-- the section's variants (one per locale; usually one) and the element's entry in each
function S:_variants(sec)
  local out = {}
  for _, v in ipairs(self:obj(sec):get("variants") or {}) do
    local vo = self:obj(v)
    if vo then out[#out + 1] = vo end
  end
  return out
end

local function info_of(vo, id)
  for k, st in ipairs(vo:get("elementInfo") or {}) do
    if TR.sget(st, "elementId") == id then return st, k end
  end
  return nil
end

local function sset(st, name, typ, value)
  for _, p in ipairs(st) do
    if p.name == name then
      p.value = value
      return
    end
  end
  st[#st + 1] = TR.Prop(name, typ, value)
end

function S:section_of(el)
  for n, o in ipairs(self.t.objects) do
    if SF.SECTIONS[o.cls] and index_of(o:get("sceneElements"), el) then return n end
  end
  return nil
end

function S:set_text(el, id)
  local e = self:obj(el)
  if e.cls == "CStorySceneComment" then e:set("commentText", TR.Loc(id)) return end
  e:set("dialogLine", TR.Loc(id), "LocalizedString")
end

function S:set_duration(el, secs)
  local e = self:obj(el)
  e:set("approvedDuration", secs, "Float")
  if e.cls == "CStoryScenePauseElement" then e:set("duration", secs, "Float") end
  local sec = self:section_of(el)
  for _, vo in ipairs(sec and self:_variants(sec) or {}) do
    local st = info_of(vo, e:get("elementID", ""))
    if st then sset(st, "approvedDuration", "Float", secs) end
  end
end

function S:set_speaker(el, tag) self:obj(el):set("voicetag", tag, "CName") end

-- events by GUID bytes, for the section's lists of them
local function ev_guid(ev) local g = TR.sget(ev.props, "GUID") return g and g.b or nil end

-- the section's events k (a set), gone: from its list, its variants' lists and its event infos
function S:_drop_events(sec, gone)
  local o = self:obj(sec)
  local guids, keep = {}, {}
  for k, ev in ipairs(o.events or {}) do
    if gone[k] then
      local g = ev_guid(ev)
      if g then guids[g] = true end
    else
      keep[#keep + 1] = ev
    end
  end
  o.events = keep
  for _, ev in ipairs(keep) do                     -- a parent gone: the event stands on its own
    local lp = TR.sget(ev.props, "linkParentGUID")
    if lp and guids[lp.b] then
      for k, p in ipairs(ev.props) do
        if p.name == "linkParentGUID" then table.remove(ev.props, k) break end
      end
    end
  end
  for _, vo in ipairs(self:_variants(sec)) do
    local list, out = vo:get("events"), {}
    if list then
      for _, g in ipairs(list) do if not guids[g.b] then out[#out + 1] = g end end
      vo:set("events", TR.Array(out))
    end
  end
  local infos, drop = o:get("eventsInfo"), {}
  if infos then
    local out = {}
    for _, n in ipairs(infos) do
      local io = self:obj(n)
      local g = io and io:get("eventGuid")
      if g and guids[g.b] then drop[#drop + 1] = n else out[#out + 1] = n end
    end
    o:set("eventsInfo", TR.Array(out))
  end
  table.sort(drop, function(a, b) return a > b end)
  for _, n in ipairs(drop) do self.t:remove(n) end
end

function S:remove_event(sec, k) self:_drop_events(sec, {[k] = true}) end

function S:set_event(sec, k, name, value, typ)
  local ev = self:obj(sec).events[k]
  sset(ev.props, name, typ or "CName", value)
end

-- another animation for gesture k, len seconds long (nil: not known): it plays whole, to the pose it ends in
function S:set_gesture(sec, k, anim, len)
  local ev = self:obj(sec).events[k]
  sset(ev.props, "animationName", "CName", anim)
  if not (len and len > 0.05) then return end
  sset(ev.props, "clipFront", "Float", 0.0)
  sset(ev.props, "clipEnd", "Float", len)
  sset(ev.props, "stretch", "Float", 1.0)
  sset(ev.props, "duration", "Float", len)
end

-- an object's number now (removing objects renumbers those after them)
function S:num(o)
  for n, x in ipairs(self.t.objects) do if x == o then return n end end
  return nil
end

-- object n out of every list of handles (back links, element lists) before it goes
function S:_strip(n)
  for _, o in ipairs(self.t.objects) do
    for _, p in ipairs(o.props or {}) do
      if p.type:sub(1, 6) == "array:" and p.type:find("ptr:", 1, true) and TR.is(p.value, TR.ARRAY) then
        for k = #p.value, 1, -1 do if p.value[k] == n then table.remove(p.value, k) end end
      end
    end
  end
end

function S:remove_element(sec, el)
  local so, eo = self:obj(sec), self:obj(el)
  local gone = {}
  for _, e in ipairs(self:events_of(sec, el)) do gone[e.k] = true end
  self:_drop_events(sec, gone)
  sec, el = self:num(so), self:num(eo)
  local id = eo:get("elementID", "")
  for _, vo in ipairs(self:_variants(sec)) do
    local _, k = info_of(vo, id)
    if k then table.remove(vo:get("elementInfo"), k) end
  end
  self:_strip(el)
  self.t:remove(el)
end

function S:move_element(sec, el, by)
  local o = self:obj(sec)
  local list = o:get("sceneElements")
  local at = index_of(list, el)
  local to = at and at + by
  if not at or to < 1 or to > #list then return false end
  list[at], list[to] = list[to], list[at]
  local id_a, id_b = self:obj(list[to]):get("elementID", ""), self:obj(list[at]):get("elementID", "")
  for _, vo in ipairs(self:_variants(sec)) do
    local infos = vo:get("elementInfo")
    local _, ka = info_of(vo, id_a)
    local _, kb = info_of(vo, id_b)
    if ka and kb then infos[ka], infos[kb] = infos[kb], infos[ka] end
  end
  return true
end

-- a new line after element `after` (nil: first), said by speaker, text id, seconds; the director's events of element
-- regie_from copied onto it (cameras, look-ats, gestures: the scene's own way of showing that speaker) -> its number
function S:insert_line(sec, after, speaker, id, secs, regie_from)
  local o = self:obj(sec)
  local root = self:root()
  local count = root:get("elementIDCounter", 0) + 1
  root:set("elementIDCounter", count, "Uint32")
  local eid = "Line_" .. count
  local line = TR.Obj("CStorySceneLine", 0, sec, 0, {
    TR.Prop("elementID", "String", eid), TR.Prop("approvedDuration", "Float", secs),
    TR.Prop("voicetag", "CName", speaker), TR.Prop("dialogLine", "LocalizedString", TR.Loc(id))})
  local n = self.t:add(line)
  local list = o:get("sceneElements")
  if not list then
    list = TR.Array({})
    o:set("sceneElements", list, "array:2,0,ptr:CStorySceneElement")
  end
  local at = after and (index_of(list, after) or #list) or 0
  table.insert(list, at + 1, n)
  local after_id = after and self:obj(after):get("elementID", "") or nil
  for _, vo in ipairs(self:_variants(sec)) do
    local infos = vo:get("elementInfo")
    if infos then
      local k = after_id and select(2, info_of(vo, after_id)) or 0
      table.insert(infos, k + 1, TR.Struct({TR.Prop("elementId", "String", eid),
                                             TR.Prop("approvedDuration", "Float", secs)}))
    end
  end
  if regie_from then self:copy_events(sec, regie_from, n) end
  return n
end

-- the events of element from, copied onto element to (new GUIDs; a copied event's parent in the copy follows)
function S:copy_events(sec, from, to)
  local o = self:obj(sec)
  local src = self:events_of(sec, from)
  if #src == 0 then return 0 end
  local map, made = {}, {}
  for _, e in ipairs(src) do
    local ev = TR.deepcopy(o.events[e.k])
    local old = ev_guid(ev)
    local g = TR.new_guid()
    sset(ev.props, "GUID", "CGUID", g)
    sset(ev.props, "sceneElement", "ptr:CStorySceneElement", to)
    if old then map[old] = g end
    made[#made + 1] = ev
  end
  for _, ev in ipairs(made) do
    local lp = TR.sget(ev.props, "linkParentGUID")
    if lp and map[lp.b] then sset(ev.props, "linkParentGUID", "CGUID", map[lp.b]) end
    o.events[#o.events + 1] = ev
  end
  local vid = 0
  local vs = self:_variants(sec)
  if vs[1] then vid = vs[1]:get("id", 0) end
  local infos = o:get("eventsInfo")
  for _, ev in ipairs(made) do
    local g = TR.sget(ev.props, "GUID")
    for _, vo in ipairs(vs) do
      local list = vo:get("events")
      if list then list[#list + 1] = g end
    end
    if infos then
      local io = TR.Obj("CStorySceneEventInfo", 0, 0, 0, {TR.Prop("eventGuid", "CGUID", g),
                                                           TR.Prop("sectionVariantId", "Uint32", vid)})
      infos[#infos + 1] = self.t:add(io)
    end
  end
  return #made
end

function S:set_choice_text(cl, id) self:obj(cl):set("choiceLine", TR.Loc(id), "LocalizedString") end

function S:set_choice_target(cl, to) self:obj(cl):set("nextLinkElement", to, "ptr:CStorySceneLinkElement") end

function S:remove_choice(cl)
  local o = self:obj(cl)
  if not o or o.cls ~= "CStorySceneChoiceLine" then return false end
  self:_strip(cl)
  self.t:remove(cl)
  return true
end

-- a copy of answer cl (its conditions too) with text id, leading to `to` -> its number
function S:add_choice(cl, id, to)
  local o = self:obj(cl)
  local n = self.t:copy(cl, o.parent)
  local c = self:obj(n)
  c:set("choiceLine", TR.Loc(id), "LocalizedString")
  if to then c:set("nextLinkElement", to, "ptr:CStorySceneLinkElement") end
  local ch = self:obj(o.parent)
  table.insert(ch:get("choiceLines"), n)
  return n
end

function S:set_fact_check(cond, fact, op, value)
  local o = self:obj(cond)
  o:set("factId", fact, "String")
  o:set("compareFunc", SF.OP_NAMES[op] or "CF_Equal", "ECompareFunc")
  o:set("value", value, "Int32")
end

-- an input of the scene's own leading to control part `target` (for playing from a section) -> its number
function S:add_input(target, name)
  local inp = TR.Obj("CStorySceneInput", 0, 1, 0, {
    TR.Prop("nextLinkElement", "ptr:CStorySceneLinkElement", target), TR.Prop("inputName", "String", name)})
  -- (actors as the scene's first input maps them: a new input without its voicetags finds nobody)
  local first = self:inputs()[1]
  if first then
    local fo = self:obj(first.n)
    for _, p in ipairs(fo.props) do
      if p.name ~= "nextLinkElement" and p.name ~= "inputName" then
        inp.props[#inp.props + 1] = TR.Prop(p.name, p.type, TR.deepcopy(p.value))
      end
    end
  end
  local n = self.t:add(inp)
  table.insert(self:root():get("controlParts"), n)
  return n
end

-- --- another scene in place of a section: a scene Motion built (its stages, animations, its scripts' calls) where the
-- game plays a cutscene. Everything between the other scene's input and its outputs comes over; it plays at a
-- dialogset of its own (OWN_SET .. k) whose spot is a tag of the world (the cutscene's point), its people are this
-- scene's, its outputs lead where the section did. The spot moves with set_place (Motion's scenes put every actor at
-- the spot with OverridePlacement: their animations hold where each one is).
SF.OWN_SET = "cj_scene_"

-- the objects of scene B that come with its control parts: the parts, what is under them, what they point at
local function closure(B, starts, stop)
  local have, out, todo = {}, {}, {}
  for _, n in ipairs(starts) do todo[#todo + 1] = n end
  while #todo > 0 do
    local n = table.remove(todo, 1)
    if n > 0 and not have[n] and not stop[n] and B.t.objects[n] then
      have[n] = true
      out[#out + 1] = n
      for _, k in ipairs(B.t:under(n)) do todo[#todo + 1] = k end
      for _, r in ipairs(B.t:refs(n)) do todo[#todo + 1] = r end
    end
  end
  table.sort(out)
  return out
end

-- every name of map in a list of values (voicetags, tags), inside structs and arrays too
local function map_names(props, map)
  for _, p in ipairs(props or {}) do
    local v = p.value
    if type(v) == "string" and (p.type == "CName" or p.type == "TagList") and map[v] then
      p.value = map[v]
    elseif TR.is(v, TR.STRUCT) then
      map_names(v, map)
    elseif type(v) == "table" and (TR.is(v, TR.ARRAY) or TR.is(v, TR.TAGS)) then
      for k, x in ipairs(v) do
        if TR.is(x, TR.STRUCT) then map_names(x, map)
        elseif type(x) == "string" and map[x] then v[k] = map[x] end
      end
    end
  end
end

-- every GUID of map (bytes -> new GUID) in a list of values
local function map_guids(props, map)
  for _, p in ipairs(props or {}) do
    local v = p.value
    if TR.is(v, TR.GUID) and map[v.b] then
      p.value = map[v.b]
    elseif TR.is(v, TR.STRUCT) then
      map_guids(v, map)
    elseif TR.is(v, TR.ARRAY) then
      for k, x in ipairs(v) do
        if TR.is(x, TR.GUID) and map[x.b] then v[k] = map[x.b]
        elseif TR.is(x, TR.STRUCT) then map_guids(x, map) end
      end
    end
  end
end

-- the dialogset section sec plays in: its own (dialogsetChangeTo), else the one the scene starts with - an input's
-- dialogsetInstanceName, else the scene's only one (a talk's first section names none) -> its name or nil
function S:set_of(sec)
  local o = self:obj(sec)
  local own = o and o:get("dialogsetChangeTo")
  if own and own ~= "" then return own end
  for _, x in ipairs(self.t.objects) do
    if x.cls == "CStorySceneInput" then
      local n = x:get("dialogsetInstanceName")
      if n and n ~= "" then return n end
    end
  end
  local all = self:root():get("dialogsetInstances") or {}
  if #all == 1 then
    local d = self:obj(all[1])
    return d and d:get("name") or nil
  end
  return nil
end

function S:_dialogset(name)
  for _, n in ipairs(self:root():get("dialogsetInstances") or {}) do
    local o = self:obj(n)
    if o and o:get("name") == name then return n end
  end
  return nil
end

-- the section n and what only it has (its variants, its event infos, what is under it) out of the scene
function S:_remove_section(sec)
  self:_strip(sec)
  local o = self:obj(sec)
  local gone = {sec}
  for _, k in ipairs(o:get("variants") or {}) do gone[#gone + 1] = k end
  for _, k in ipairs(o:get("eventsInfo") or {}) do gone[#gone + 1] = k end
  table.sort(gone, function(a, b) return a > b end)
  local done = {}
  for _, n in ipairs(gone) do
    if n > 0 and not done[n] then
      done[n] = true
      self.t:remove(n)
    end
  end
end

-- what went to section sec goes to part `entry`; then the section goes (out of the lists first)
function S:_take_place(sec, entry)
  self:_strip(sec)
  local kids = {}
  for _, x in ipairs(self.t.objects) do if x.parent == sec then kids[#kids + 1] = x end end
  self.t:renumber(function(i) return i == sec and entry or i end)
  for _, x in ipairs(kids) do x.parent = sec end
  self:_remove_section(sec)
end

-- section sec replaced by scene B (an SF) -> {set = the dialogset's name, entry = the first part of B here}.
-- o.names: B's voicetags and tags -> this scene's ({CJ_A = "SHANI", uc_woman_tag = "shani"}); o.tag: the spot's tag
function S:replace_section(sec, B, o)
  o = o or {}
  local names = o.names or {}
  local broot = B:root()
  local inp = B:inputs()[1]
  if not inp then error("the other scene has no input", 0) end
  local stop, outputs = {[1] = true}, {}
  for _, n in ipairs(broot:get("controlParts") or {}) do
    local c = B:obj(n)
    if c and c.cls == "CStorySceneInput" then stop[n] = true end
    if c and c.cls == "CStorySceneOutput" then stop[n] = true outputs[#outputs + 1] = n end
  end
  for _, list in ipairs({"sceneTemplates", "dialogsetInstances", "sceneProps", "sceneLights"}) do
    for _, n in ipairs(broot:get(list) or {}) do stop[n] = true end
  end
  local starts = {}
  for _, n in ipairs(broot:get("controlParts") or {}) do if not stop[n] then starts[#starts + 1] = n end end
  local olds = closure(B, starts, stop)
  -- where B's outputs lead here: where the section went on
  local so = self:obj(sec)
  local after = so:get("nextLinkElement", 0)
  local outside = {[1] = 1}
  for _, n in ipairs(outputs) do outside[n] = after end
  -- the section out of every list first (the scene's parts, back links); handles to it get B's entry below
  self:_strip(sec)
  local new = self.t:adopt_set(B.t, olds, outside)
  local copies = {}
  for _, old in ipairs(olds) do copies[#copies + 1] = self:obj(new[old]) end
  for _, c in ipairs(copies) do                       -- (back links to B's input: gone)
    for _, p in ipairs(c.props or {}) do
      if p.type:sub(1, 6) == "array:" and p.type:find("ptr:", 1, true) and TR.is(p.value, TR.ARRAY) then
        for k = #p.value, 1, -1 do if p.value[k] == 0 then table.remove(p.value, k) end end
      end
    end
  end
  local entry = new[B:obj(inp.n):get("nextLinkElement", 0)] or after
  -- B's people are this scene's; ids, section numbers and event GUIDs of their own
  local root = self:root()
  local count, scount = root:get("elementIDCounter", 0), root:get("sectionIDCounter", 0)
  local ids, guids = {}, {}
  for _, c in ipairs(copies) do
    map_names(c.props, names)
    map_names(c.args, names)
    for _, ev in ipairs(c.events or {}) do
      map_names(ev.props, names)
      local g = TR.sget(ev.props, "GUID")
      if g then guids[g.b] = TR.new_guid() end
    end
    local id = c:get("elementID")
    if id then
      count = count + 1
      ids[id] = (id:gsub("_%d+$", "")) .. "_" .. count
      c:set("elementID", ids[id], "String")
    end
    if SF.SECTIONS[c.cls] then
      scount = scount + 1
      c:set("sectionId", scount, "Uint32")
    end
  end
  root:set("elementIDCounter", count, "Uint32")
  root:set("sectionIDCounter", scount, "Uint32")
  for _, c in ipairs(copies) do
    map_guids(c.props, guids)
    for _, ev in ipairs(c.events or {}) do map_guids(ev.props, guids) end
    if c.cls == "CStorySceneSectionVariant" then
      for _, st in ipairs(c:get("elementInfo") or {}) do
        local id = TR.sget(st, "elementId")
        if id and ids[id] then sset(st, "elementId", "String", ids[id]) end
      end
    end
  end
  -- B's dialogset as one of this scene's, at the spot's tag
  local k = 1
  while self:_dialogset(SF.OWN_SET .. k) do k = k + 1 end
  local set = SF.OWN_SET .. k
  local bset = B:_dialogset(B:obj(inp.n):get("dialogsetInstanceName", ""))
  if bset then
    local ds = self.t:adopt(B.t, bset, 1)
    local dso = self:obj(ds)
    dso:set("name", set, "CName")
    dso:set("placementTag", TR.Tags({o.tag or "PLAYER"}), "TagList")
    -- (the spot as it is: a boat is no safe ground, and its deck is above the terrain)
    dso:set("findSafePlacement", false, "Bool")
    dso:set("snapToTerrain", false, "Bool")
    for _, sl in ipairs(dso:get("slots") or {}) do
      local slo = self:obj(sl)
      if slo then map_names(slo.props, names) end
    end
    table.insert(root:get("dialogsetInstances"), ds)
  end
  for _, c in ipairs(copies) do
    if c.cls == "CStorySceneSection" then c:set("dialogsetChangeTo", set, "CName") end
  end
  -- B's parts and sections into this scene's lists, B's cameras too
  for _, list in ipairs({"controlParts", "sections"}) do
    local mine = root:get(list)
    for _, n in ipairs(broot:get(list) or {}) do if new[n] then mine[#mine + 1] = new[n] end end
  end
  local cams = root:get("cameraDefinitions")
  for _, st in ipairs(broot:get("cameraDefinitions") or {}) do
    if cams then cams[#cams + 1] = TR.deepcopy(st) end
  end
  local first = self:obj(entry)
  self:_take_place(sec, entry)
  -- a camera of its own where B brings none (Motion's scenes have none; the scene's last one stands elsewhere)
  local has_cam = false
  for _, c in ipairs(copies) do
    for _, ev in ipairs(c.events or {}) do if ev.cls:find("Camera", 1, true) then has_cam = true end end
  end
  if not has_cam then self:set_camera(set, o.view or "side", o.pos, o.yaw) end
  if o.pos or o.yaw then self:set_place(set, o.pos, o.yaw) end
  return {set = set, entry = self:num(first)}
end

-- the replacements in the scene: {{set = name, tag = the spot's tag, sections = {n ...}, pos = {x, y, z}, yaw}}
function S:own_sets()
  local out = {}
  for _, n in ipairs(self:root():get("dialogsetInstances") or {}) do
    local o = self:obj(n)
    local name = o and o:get("name") or ""
    if type(name) == "string" and name:sub(1, #SF.OWN_SET) == SF.OWN_SET then
      local tags = o:get("placementTag") or {}
      local r = {set = name, n = n, tag = tags[1] or "", sections = {}, pos = {0, 0, 0}, yaw = 0}
      for k, x in ipairs(self.t.objects) do
        if SF.SECTIONS[x.cls] and x:get("dialogsetChangeTo") == name then r.sections[#r.sections + 1] = k end
      end
      local got = false
      for _, sec in ipairs(r.sections) do
        for _, ev in ipairs(self:obj(sec).events or {}) do
          if not got and ev.cls == "CStorySceneEventOverridePlacement" then
            local t = TR.sget(ev.props, "placement")
            if t and t.position then r.pos = {t.position[1], t.position[2], t.position[3]} end
            if t and t.rotation then r.yaw = t.rotation[3] end
            got = true
          end
        end
      end
      r.view = self:camera_of(name)
      out[#out + 1] = r
    end
  end
  return out
end

-- a replacement's spot moved: every actor's placement in its sections (pos {x, y, z} from the tag, yaw in degrees),
-- its camera with them
function S:set_place(set, pos, yaw)
  pos = pos or {0, 0, 0}
  for _, x in ipairs(self.t.objects) do
    if SF.SECTIONS[x.cls] and x:get("dialogsetChangeTo") == set then
      for _, ev in ipairs(x.events or {}) do
        if ev.cls == "CStorySceneEventOverridePlacement" then
          sset(ev.props, "placement", "EngineTransform",
               TR.Transform({pos[1], pos[2], pos[3]}, {0, 0, yaw or 0}, nil))
        end
      end
    end
  end
  local view = self:camera_of(set)
  if view then self:set_camera(set, view, pos, yaw) end
end

-- --- a camera of its own for a replacement: each of its sections starts with it (CStorySceneEventCustomCamera, as
-- CDPR's own cameras: where it stands and turns from the spot), from one of a few views; it moves with the spot
SF.OWN_CAMERA = "cj camera "
SF.VIEWS = {side = {{3.4, 0.4, 1.35}, {0, 0.4, 1.0}}, ["other side"] = {{-3.4, 0.4, 1.35}, {0, 0.4, 1.0}},
            front = {{0, 3.6, 1.4}, {0, 0.3, 1.0}}, back = {{0, -3.2, 1.4}, {0, 0.3, 1.0}},
            close = {{1.6, 1.2, 1.2}, {0, 0.3, 0.95}}, above = {{1.8, 1.8, 3.4}, {0, 0.3, 0.6}}}
SF.VIEW_ORDER = {"side", "other side", "front", "back", "close", "above"}

local function vec(x, y, z, w)
  return TR.Struct({TR.Prop("X", "Float", x), TR.Prop("Y", "Float", y), TR.Prop("Z", "Float", z),
                    TR.Prop("W", "Float", w or 1.0)})
end

-- a camera at pos looking at `at` (the spot's frame) -> pitch, yaw in degrees (yaw 0: along +Y, counter-clockwise)
local function look(pos, at)
  local dx, dy, dz = at[1] - pos[1], at[2] - pos[2], at[3] - pos[3]
  return math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), math.deg(math.atan(-dx, dy)) % 360
end

local function moved(p, off, yaw)
  local a = math.rad(yaw or 0)
  return {p[1] * math.cos(a) - p[2] * math.sin(a) + off[1], p[1] * math.sin(a) + p[2] * math.cos(a) + off[2],
          p[3] + off[3]}
end

-- an event of one's own on a section: its GUID into the variants' lists, an event info for it
function S:_add_event(sec, ev)
  local o = self:obj(sec)
  o.events[#o.events + 1] = ev
  local g = TR.sget(ev.props, "GUID")
  local vs = self:_variants(sec)
  for _, vo in ipairs(vs) do
    local list = vo:get("events")
    if list then list[#list + 1] = g end
  end
  local infos = o:get("eventsInfo")
  if infos then
    local io = TR.Obj("CStorySceneEventInfo", 0, 0, 0, {TR.Prop("eventGuid", "CGUID", g),
                                                         TR.Prop("sectionVariantId", "Uint32", vs[1] and vs[1]:get("id", 0) or 0)})
    infos[#infos + 1] = self.t:add(io)
  end
end

-- every section of replacement `set` starts with the camera `view`, moved with the spot (pos, yaw)
function S:set_camera(set, view, pos, yaw)
  local v = SF.VIEWS[view] or SF.VIEWS.side
  pos = pos or {0, 0, 0}
  local cp, at = moved(v[1], pos, yaw), moved(v[2], pos, yaw)
  local pitch, cyaw = look(cp, at)
  local secs = {}
  for _, x in ipairs(self.t.objects) do
    if SF.SECTIONS[x.cls] and x:get("dialogsetChangeTo") == set and x.events then secs[#secs + 1] = x end
  end
  for _, x in ipairs(secs) do                       -- (dropping events renumbers: each section found again)
    local n = self:num(x)
    do
      local gone = {}
      for k, ev in ipairs(x.events) do
        if tostring(TR.sget(ev.props, "eventName", "")):sub(1, #SF.OWN_CAMERA) == SF.OWN_CAMERA then gone[k] = true end
      end
      if next(gone) then self:_drop_events(n, gone) end
      local o = self:obj(n)
      local el = (o:get("sceneElements") or {})[1] or o:get("choice", 0)
      if el and el ~= 0 then
        local fov = 35.0
        self:_add_event(n, {cls = "CStorySceneEventCustomCamera", props = {
          TR.Prop("eventName", "String", SF.OWN_CAMERA .. (SF.VIEWS[view] and view or "side")),
          TR.Prop("sceneElement", "ptr:CStorySceneElement", el),
          TR.Prop("GUID", "CGUID", TR.new_guid()),
          TR.Prop("cameraTranslation", "Vector", vec(cp[1], cp[2], cp[3])),
          TR.Prop("cameraRotation", "EulerAngles", TR.Struct({TR.Prop("Pitch", "Float", pitch),
                                                              TR.Prop("Yaw", "Float", cyaw),
                                                              TR.Prop("Roll", "Float", 0.0)})),
          TR.Prop("cameraFov", "Float", fov),
          TR.Prop("cameraDefinition", "StorySceneCameraDefinition", TR.Struct({
            TR.Prop("cameraName", "CName", "CustomCamera"),
            TR.Prop("cameraTransform", "EngineTransform", TR.Transform({cp[1], cp[2], cp[3]}, {0.0, pitch, cyaw}, nil)),
            TR.Prop("cameraFov", "Float", fov)}))}})
      end
    end
  end
end

-- the view a replacement's camera has now (nil: none of its own)
function S:camera_of(set)
  for _, x in ipairs(self.t.objects) do
    if SF.SECTIONS[x.cls] and x:get("dialogsetChangeTo") == set then
      for _, ev in ipairs(x.events or {}) do
        local name = tostring(TR.sget(ev.props, "eventName", ""))
        if name:sub(1, #SF.OWN_CAMERA) == SF.OWN_CAMERA then return name:sub(#SF.OWN_CAMERA + 1) end
      end
    end
  end
  return nil
end

-- --- a cutscene of one's own: a section whose elements are its moments (a pause, or a line said), each with what
-- happens in it - an animation per person (played again until the moment ends), a camera, everyone's place. Events
-- start at a share of their element (0..1, as every event of the game's 6219 scenes), last seconds.
SF.OWN_EVENT = "cj "                      -- the events a moment of one's own carries: their names begin so
SF.SIZES = {wide = 1.6, medium = 1.0, close = 0.55}
SF.SIZE_ORDER = {"wide", "medium", "close"}

-- a view over a person's shoulder (with two people or more: "over <name>"): behind them and a little to their
-- right, looking at the face of the one nearest them
SF.OVER = "over "
function SF.views_for(places)
  local out = {}
  for _, v in ipairs(SF.VIEW_ORDER) do out[#out + 1] = v end
  local names = {}
  for who in pairs(places or {}) do names[#names + 1] = who end
  if #names >= 2 then
    table.sort(names)
    for _, who in ipairs(names) do out[#out + 1] = SF.OVER .. who end
  end
  return out
end

-- view "over <name>" at size k -> where the camera stands, where it looks (the spot's frame); nil without the
-- person or a second one
local function over_shoulder(view, k, places)
  if view:sub(1, #SF.OVER) ~= SF.OVER or not places then return nil end
  local a = places[view:sub(#SF.OVER + 1)]
  if not a then return nil end
  local b, best
  for _, p in pairs(places) do
    local d = (p[1] - a[1]) ^ 2 + (p[2] - a[2]) ^ 2
    if p ~= a and (not best or d < best) then b, best = p, d end
  end
  if not b or best < 0.0025 then return nil end
  local len = math.sqrt(best)
  local dx, dy = (b[1] - a[1]) / len, (b[2] - a[2]) / len
  local back, side = 0.9 * k, 0.45
  return {a[1] - dx * back + dy * side, a[2] - dy * back - dx * side, 1.65}, {b[1], b[2], 1.55}
end

function S:_own_events(sec, el, what)
  local out = {}
  for k, ev in ipairs(self:obj(sec).events or {}) do
    local name = tostring(TR.sget(ev.props, "eventName", ""))
    if TR.sget(ev.props, "sceneElement", 0) == el and name:sub(1, #SF.OWN_EVENT + #what) == SF.OWN_EVENT .. what then
      out[k] = ev
    end
  end
  return out
end

-- a part or element given as its object or its number -> its number now (dropping events renumbers what follows)
function S:n(x) return type(x) == "table" and self:num(x) or x end

function S:_drop_own(sec, el, what)
  sec, el = self:n(sec), self:n(el)
  local gone = {}
  for k in pairs(self:_own_events(sec, el, what)) do gone[k] = true end
  if next(gone) then self:_drop_events(sec, gone) end
end

-- every link to part `from` leads to part `to` instead (the flow's links, a switch's cases, the answers), but the
-- links of part `keep` -> how many
function S:redirect(from, to, keep)
  local k = 0
  local function one(o, prop)
    if o:get(prop, 0) == from then o:set(prop, to, "ptr:CStorySceneLinkElement") k = k + 1 end
  end
  for n, o in ipairs(self.t.objects) do
    if n ~= keep and o.props then
      for _, spec in ipairs(SF.LINKS[o.cls] or {}) do
        if spec.list then
          local v = o:get(spec[1]) or {}
          for i, x in ipairs(v) do if x == from then v[i] = to k = k + 1 end end
        else
          one(o, spec[1])
        end
      end
      if o.cls == "CStorySceneFlowSwitchCase" then one(o, "thenLink") end
      if o.cls == "CStorySceneChoiceLine" then one(o, "nextLinkElement") end
    end
  end
  return k
end

-- fact `fact` set to `value` on the way into part `target` (a section or an output): a script element as the game's
-- scenes set theirs (AddFact_S - passiflora girl 02's "_met +1"), every link to the part going through it first;
-- a quest waits for the fact -> the script's number
function S:add_fact(target, fact, value)
  local tpl
  for _, o in ipairs(self.t.objects) do
    if o.cls == "CStorySceneScript" then tpl = o break end
  end
  local n = self.t:add(TR.Obj("CStorySceneScript", tpl and tpl.flags or 0, 1, 0, {
    TR.Prop("linkedElements", "array:2,0,ptr:CStorySceneLinkElement", TR.Array({})),
    TR.Prop("nextLinkElement", "ptr:CStorySceneLinkElement", target),
    TR.Prop("comment", "String", fact .. " +" .. value),
    TR.Prop("functionName", "CName", "AddFact_S")},
    {TR.Prop("factName", "String", fact), TR.Prop("value", "Int32", value), TR.Prop("validFor", "Int32", 0)},
    tpl and tpl.rest or ""))
  table.insert(self:root():get("controlParts"), n)
  self:redirect(target, n, n)
  return n
end

-- a new section after control part `after` (what `after` led to follows it), at dialogset `set` -> its number
function S:add_section(after, name, set)
  local root = self:root()
  local tpl
  for _, n in ipairs(root:get("sections") or {}) do
    local o = self:obj(n)
    if o and o.cls == "CStorySceneSection" and o.events then tpl = o break end
  end
  local locale = 0
  if tpl then
    local v = self:obj((tpl:get("variants") or {})[1] or 0)
    locale = v and v:get("localeId", 0) or 0
  end
  local id = root:get("sectionIDCounter", 0) + 1
  root:set("sectionIDCounter", id, "Uint32")
  local ao = self:obj(after)
  local spec = ao and SF.LINKS[ao.cls] and SF.LINKS[ao.cls][1]
  local next_of = spec and not spec.list and ao:get(spec[1], 0) or 0
  local var = self.t:add(TR.Obj("CStorySceneSectionVariant", tpl and self:obj(tpl:get("variants")[1]).flags or 0, 0, 0, {
    TR.Prop("id", "Uint32", 0), TR.Prop("localeId", "Uint32", locale),
    TR.Prop("events", "array:2,0,CGUID", TR.Array({})),
    TR.Prop("elementInfo", "array:2,0,CStorySceneSectionVariantElementInfo", TR.Array({}))}))
  local o = TR.Obj("CStorySceneSection", tpl and tpl.flags or 0, 1, 0, {
    TR.Prop("linkedElements", "array:2,0,ptr:CStorySceneLinkElement", TR.Array(ao and {after} or {})),
    TR.Prop("nextLinkElement", "ptr:CStorySceneLinkElement", next_of),
    TR.Prop("nextVariantId", "Uint32", 1), TR.Prop("defaultVariantId", "Uint32", 0),
    TR.Prop("variants", "array:2,0,ptr:CStorySceneSectionVariant", TR.Array({var})),
    TR.Prop("sceneElements", "array:2,0,ptr:CStorySceneElement", TR.Array({})),
    TR.Prop("eventsInfo", "array:2,0,ptr:CStorySceneEventInfo", TR.Array({})),
    TR.Prop("sectionId", "Uint32", id), TR.Prop("sectionName", "String", name)}, nil, tpl and tpl.rest or "")
  if set then o.props[#o.props + 1] = TR.Prop("dialogsetChangeTo", "CName", set) end
  o.events = {}
  local n = self.t:add(o)
  table.insert(root:get("controlParts"), n)
  table.insert(root:get("sections"), n)
  if spec and not spec.list then ao:set(spec[1], n, "ptr:CStorySceneLinkElement") end
  return n
end

-- a dialogset of one's own at a spot (a tag of the world; "PLAYER": where the player stands) with a slot per person
-- (their places: the moments' placement events) -> its name
function S:add_set(tag, people)
  local k = 1
  while self:_dialogset(SF.OWN_SET .. k) do k = k + 1 end
  local set = SF.OWN_SET .. k
  local ds = self.t:add(TR.Obj("CStorySceneDialogsetInstance", 0, 1, 0, {
    TR.Prop("name", "CName", set), TR.Prop("slots", "array:2,0,ptr:CStorySceneDialogsetSlot", TR.Array({})),
    TR.Prop("placementTag", "TagList", TR.Tags({tag or "PLAYER"})), TR.Prop("findSafePlacement", "Bool", false),
    TR.Prop("snapToTerrain", "Bool", false)}))
  local slots = self:obj(ds):get("slots")
  for i, who in ipairs(people or {}) do
    slots[#slots + 1] = self.t:add(TR.Obj("CStorySceneDialogsetSlot", 0, ds, 0, {
      TR.Prop("slotNumber", "Uint32", i), TR.Prop("slotName", "CName", "slot" .. i),
      TR.Prop("slotPlacement", "EngineTransform", TR.Transform({0, (i - 1) * 1.2, 0}, {0, 0, i == 1 and 0 or 180}, nil)),
      TR.Prop("actorName", "CName", who), TR.Prop("ID", "CGUID", TR.new_guid())}))
  end
  table.insert(self:root():get("dialogsetInstances"), ds)
  return set
end

-- a moment after element `after` (nil: first): a pause of secs -> its element
function S:add_moment(sec, after, secs)
  local o = self:obj(sec)
  local root = self:root()
  local count = root:get("elementIDCounter", 0) + 1
  root:set("elementIDCounter", count, "Uint32")
  local eid = "Pause_" .. count
  local n = self.t:add(TR.Obj("CStoryScenePauseElement", 0, sec, 0, {
    TR.Prop("elementID", "String", eid), TR.Prop("approvedDuration", "Float", secs), TR.Prop("duration", "Float", secs)}))
  local list = o:get("sceneElements")
  local at = after and (index_of(list, after) or #list) or #list
  table.insert(list, at + 1, n)
  local after_id = after and self:obj(after):get("elementID", "") or nil
  for _, vo in ipairs(self:_variants(sec)) do
    local infos = vo:get("elementInfo")
    local k = after_id and select(2, info_of(vo, after_id)) or #infos
    table.insert(infos, k + 1, TR.Struct({TR.Prop("elementId", "String", eid), TR.Prop("approvedDuration", "Float", secs)}))
  end
  return n
end

local function ev_base(cls, name, el, start)
  return {cls = cls, props = {TR.Prop("eventName", "String", SF.OWN_EVENT .. name),
                               TR.Prop("startPosition", "Float", start or 0.0),
                               TR.Prop("sceneElement", "ptr:CStorySceneElement", el),
                               TR.Prop("GUID", "CGUID", TR.new_guid())}}
end

-- the length of an element (a pause's, a line's)
function S:length_of(el)
  local e = self:obj(self:n(el))
  return e and (e:get("approvedDuration") or e:get("duration") or 0) or 0
end

-- person `actor` plays animation `anim` (len seconds long) through the moment, again and again; nil: nothing of one's own
function S:set_moment_anim(sec, el, actor, anim, len)
  local so, eo = self:obj(self:n(sec)), self:obj(self:n(el))
  self:_drop_own(so, eo, "anim " .. actor)
  sec, el = self:num(so), self:num(eo)
  if not anim or anim == "" then return end
  local secs = math.max(self:length_of(el), 0.1)
  len = (len and len > 0.05) and len or secs
  local t = 0.0
  while t < secs - 0.05 do
    local d = math.min(len, secs - t)
    local ev = ev_base("CStorySceneEventAnimation", "anim " .. actor, el, t / secs)
    for _, p in ipairs({TR.Prop("duration", "Float", d), TR.Prop("actor", "CName", actor),
                        TR.Prop("clipEnd", "Float", d), TR.Prop("stretch", "Float", 1.0), TR.Prop("weight", "Float", 1.0),
                        TR.Prop("animationName", "CName", anim)}) do ev.props[#ev.props + 1] = p end
    self:_add_event(sec, ev)
    t = t + len
  end
end

-- everyone's place for the moment: {actor = {x, y, turn}} from the spot
function S:set_moment_places(sec, el, places)
  local so, eo = self:obj(self:n(sec)), self:obj(self:n(el))
  for actor, pl in pairs(places) do
    self:_drop_own(so, eo, "place " .. actor)
    sec, el = self:num(so), self:num(eo)
    local ev = ev_base("CStorySceneEventOverridePlacement", "place " .. actor, el, 0.0)
    ev.props[#ev.props + 1] = TR.Prop("actorName", "CName", actor)
    ev.props[#ev.props + 1] = TR.Prop("placement", "EngineTransform",
                                      TR.Transform({pl[1] or 0, pl[2] or 0, pl[4] or 0}, {0, 0, pl[3] or 0}, nil))
    self:_add_event(sec, ev)
  end
end

-- the moment's camera: a view (SF.VIEWS) at a size (SF.SIZES: how far), looking at `at` {x, y, z} of the spot's frame;
-- a view over a person's shoulder (SF.views_for) needs the moment's places
function S:set_moment_camera(sec, el, view, size, at, places)
  local so, eo = self:obj(self:n(sec)), self:obj(self:n(el))
  self:_drop_own(so, eo, "camera")
  sec, el = self:num(so), self:num(eo)
  local k = SF.SIZES[size] or 1.0
  local cp, oat = over_shoulder(tostring(view or ""), k, places)
  if cp then
    at = oat
  else
    view = SF.VIEWS[view] and view or "side"
    local v = SF.VIEWS[view]
    at = at or {0, 0, 1.4}
    cp = {at[1] + (v[1][1] - v[2][1]) * k, at[2] + (v[1][2] - v[2][2]) * k, at[3] + (v[1][3] - v[2][3]) * k}
  end
  local pitch, cyaw = look(cp, at)
  local ev = ev_base("CStorySceneEventCustomCamera", "camera " .. view .. "|" ..
                     (SF.SIZES[size] and size or "medium"), el, 0.0)
  for _, p in ipairs({TR.Prop("cameraTranslation", "Vector", vec(cp[1], cp[2], cp[3])),
                      TR.Prop("cameraRotation", "EulerAngles", TR.Struct({TR.Prop("Pitch", "Float", pitch),
                                                                          TR.Prop("Yaw", "Float", cyaw),
                                                                          TR.Prop("Roll", "Float", 0.0)})),
                      TR.Prop("cameraFov", "Float", 35.0),
                      TR.Prop("cameraDefinition", "StorySceneCameraDefinition", TR.Struct({
                        TR.Prop("cameraName", "CName", "CustomCamera"),
                        TR.Prop("cameraTransform", "EngineTransform", TR.Transform(cp, {0.0, pitch, cyaw}, nil)),
                        TR.Prop("cameraFov", "Float", 35.0)}))}) do ev.props[#ev.props + 1] = p end
  self:_add_event(sec, ev)
  return cp, at
end

-- the moment's camera at pos {x, y, z} of the spot's frame, turned pitch / yaw (degrees, as the game's camera), fov
SF.OWN_VIEW = "own"
function S:set_moment_view(sec, el, pos, pitch, yaw, fov)
  local so, eo = self:obj(self:n(sec)), self:obj(self:n(el))
  self:_drop_own(so, eo, "camera")
  sec, el = self:num(so), self:num(eo)
  fov = fov or 35.0
  local ev = ev_base("CStorySceneEventCustomCamera", "camera " .. SF.OWN_VIEW .. "|view", el, 0.0)
  for _, p in ipairs({TR.Prop("cameraTranslation", "Vector", vec(pos[1], pos[2], pos[3])),
                      TR.Prop("cameraRotation", "EulerAngles", TR.Struct({TR.Prop("Pitch", "Float", pitch),
                                                                          TR.Prop("Yaw", "Float", yaw),
                                                                          TR.Prop("Roll", "Float", 0.0)})),
                      TR.Prop("cameraFov", "Float", fov),
                      TR.Prop("cameraDefinition", "StorySceneCameraDefinition", TR.Struct({
                        TR.Prop("cameraName", "CName", "CustomCamera"),
                        TR.Prop("cameraTransform", "EngineTransform", TR.Transform(pos, {0.0, pitch, yaw}, nil)),
                        TR.Prop("cameraFov", "Float", fov)}))}) do ev.props[#ev.props + 1] = p end
  self:_add_event(sec, ev)
end

-- the properties of a camera of one's own: where it stands (scene space), pitch and yaw, its field of view, where
-- it focuses (focus: metres; nil: the game's default)
function SF.camera_props(pos, pitch, yaw, fov, focus)
  fov = fov or 35.0
  local out = {TR.Prop("cameraTranslation", "Vector", vec(pos[1], pos[2], pos[3])),
               TR.Prop("cameraRotation", "EulerAngles", TR.Struct({TR.Prop("Pitch", "Float", pitch),
                                                                   TR.Prop("Yaw", "Float", yaw),
                                                                   TR.Prop("Roll", "Float", 0.0)})),
               TR.Prop("cameraFov", "Float", fov)}
  if focus then
    out[#out + 1] = TR.Prop("dofFocusDistNear", "Float", math.max(0.1, focus - 0.6))
    out[#out + 1] = TR.Prop("dofFocusDistFar", "Float", focus + 1.5)
    out[#out + 1] = TR.Prop("dofBlurDistNear", "Float", math.max(0.05, focus - 1.5))
    out[#out + 1] = TR.Prop("dofBlurDistFar", "Float", focus + 6.0)
    out[#out + 1] = TR.Prop("dofIntensity", "Float", 1.0)
  end
  out[#out + 1] = TR.Prop("cameraDefinition", "StorySceneCameraDefinition", TR.Struct({
    TR.Prop("cameraName", "CName", "CustomCamera"),
    TR.Prop("cameraTransform", "EngineTransform", TR.Transform(pos, {0.0, pitch, yaw}, nil)),
    TR.Prop("cameraFov", "Float", fov)}))
  return out
end

-- a moment's length: the element's and its variants', the animations played through it again
function S:set_moment_secs(sec, el, secs)
  local so, eo = self:obj(self:n(sec)), self:obj(self:n(el))
  local anims = self:moment(self:num(so), self:num(eo)).anims
  self:set_duration(self:num(eo), secs)
  for actor, a in pairs(anims) do self:set_moment_anim(so, eo, actor, a.name, a.len) end
end

-- what a moment has: {el, kind, secs, text, speaker, anims = {actor = {name, len}}, camera = {view, size},
-- places = {actor = {x, y, turn}}}
function S:moment(sec, el)
  sec, el = self:n(sec), self:n(el)
  local e = self:obj(el)
  local m = {el = el, kind = SF.ELEMENTS[e.cls] or e.cls, secs = self:length_of(el), anims = {}, places = {}}
  if e.cls == "CStorySceneLine" then
    m.speaker = e:get("voicetag", "")
    m.text = e:get("dialogLine") and e:get("dialogLine").n
  end
  for _, ev in ipairs(self:obj(sec).events or {}) do
    if TR.sget(ev.props, "sceneElement", 0) == el then
      local name = tostring(TR.sget(ev.props, "eventName", ""))
      if name:sub(1, #SF.OWN_EVENT) == SF.OWN_EVENT then
        local what = name:sub(#SF.OWN_EVENT + 1)
        if what:sub(1, 5) == "anim " and not m.anims[what:sub(6)] then
          m.anims[what:sub(6)] = {name = TR.sget(ev.props, "animationName"), len = TR.sget(ev.props, "duration", 0)}
        elseif what:sub(1, 7) == "camera " then
          local view, size = what:sub(8):match("^(.-)|(.*)$")
          m.camera = {view = view or what:sub(8), size = size or "medium"}
        elseif what:sub(1, 6) == "place " then
          local t = TR.sget(ev.props, "placement")
          m.places[what:sub(7)] = {t and t.position and t.position[1] or 0, t and t.position and t.position[2] or 0,
                                   t and t.rotation and t.rotation[3] or 0}
        end
      end
    end
  end
  return m
end

function S:moments(sec)
  local out = {}
  for _, e in ipairs(self:elements(sec)) do out[#out + 1] = self:moment(sec, e.n) end
  return out
end

function S:set_place_tag(set, tag)
  local n = self:_dialogset(set)
  if n then self:obj(n):set("placementTag", TR.Tags({tag}), "TagList") end
end

-- the cutscene a cutscene section plays (its depot path), nil for any other part
function S:cutscene_of(sec)
  local o = self:obj(sec)
  if not o or o.cls ~= "CStorySceneCutsceneSection" then return nil end
  local h = o:get("cutscene", 0)
  local im = h < 0 and self.t.f.imports[-h]
  return im and im[1] or nil
end

return SF
