-- questboard.py's cards: what shows under the graph for the node picked - a goal's card (its number, journal line,
-- kind, the eye, ···, the trash can, what is missing, its editor), the card of an action, a choice, an end. Built as
-- the app builds them (ui/qw.lua trees of ui/qb_widgets.lua controls), anew every frame on the step's own dicts.
--   local QC = require("conjunction.ui.quest_card")
--   QC.build(board, node) -> the card (a qw tree) or nil
local Q = require("conjunction.ui.qt")
local W = require("conjunction.ui.qw")
local B = require("conjunction.ui.qb_widgets")
local QN = require("conjunction.quest_nodes")
local QG = require("conjunction.quest_graph")
local QBD = require("conjunction.questboard")
local P = require("conjunction.py")
local Y = require("conjunction.yaml")
local PYS = require("conjunction.pystr")
local D = w3.ui.draw
local QC = {}

local function idof(t) return tostring(t):gsub("^table: ", "") end
local function top(n) n.align = "top" return n end
local function stretched(n) n.stretch = 1 return n end
local function waiting_for(board, a, key)
  return board.waiting and board.waiting[1] == idof(a) and board.waiting[2] == key
end
local function NUMF(v) return tonumber(P.str(v)) or 0 end

-- a step's dict field set (questboard._set_in): None / "" takes it out
function QC.set_in(board, d, key, value, rebuild)
  if value == nil or value == "" then Y.remove(d, key) else d[key] = value end
  board:save(rebuild)
end

function QC.default_text(board, kind, a)
  local QS = require("conjunction.quest")
  return QS.default_text(kind, a, P.get(board:quest(), "items"), QS.display_names(board.ed.project))
end

-- the QFrame#card: #26262a, a 1 px #3c3c42 border (a path's colour: 3 px on the left), margins 8 6 8 8, 5 apart
-- (spacing: a card of its own spacing - the quest's items: 4)
local function card_frame(items, colour, spacing)
  local left = colour and 3 or 1
  local edge = colour and (tonumber(colour:sub(2), 16) << 8 | 255) or B.C.card_edge
  return W.widget(W.vbox({margins = {8, 6, 8, 8}, spacing = spacing or 5}, items), {
    margins = {left, 1, 1, 1},
    draw = function(_, r)
      D.fill(r.x, r.y, r.w, r.h, B.C.card)
      D.rect(r.x, r.y, r.w, r.h, B.C.card_edge, 1)
      if colour then D.fill(r.x, r.y, 3, r.h, edge) end
      B.bg = B.C.card
    end,
  })
end

QC.card_frame = card_frame

-- the step's kind: a menu of the other kinds of its block (questboard._kind_button)
local function kind_button(board, steps, i)
  if QG.is_scene(steps[i]) then
    return B.kind("qb.kind." .. idof(steps), "SCENE", {{"scene", "Scene"}}, "scene", function() end,
                  {tip = "qb.scene_kind"})
  end
  local kind = QN.step_kind(steps[i])
  local block = QG.block_of(kind)
  local kinds = {}
  for _, k in ipairs(QG.KINDS_OF[block] or {kind}) do kinds[#kinds + 1] = {k, QG.LABEL[k] or k} end
  return B.kind("qb.kind." .. idof(steps), (QG.LABEL[kind] or kind):upper(), kinds, kind,
                function(k) board:set_kind(steps, i, k) end, {tip = "qb.step_kind"})
end

-- the eye, ···, the trash can (questboard._card_tools)
local function card_tools(board, items, steps, i)
  local q = board:quest()
  if QN.is_graph(q) and steps.nid then
    local node = q.nodes[steps.nid]
    items[#items + 1] = B.icon("qb.eye." .. steps.nid, P.T(P.get(node, "hidden")) and "eye-off" or "eye", function()
      if P.T(P.get(node, "hidden")) then Y.remove(node, "hidden") else node.hidden = true end
      board:save()
    end, {tip = "qb.eye"})
  end
  items[#items + 1] = B.menu("qb.card_menu." .. idof(steps), "···", QBD.card_menu_of(steps[i]), nil,
                             function(k) board:card_menu(steps, i, k) end, {tip = "qb.card_menu"})
  items[#items + 1] = B.icon("qb.remove." .. idof(steps), "trash-2", function() board:remove_step(steps, i) end,
                             {tip = "qb.remove"})
end

local function missing_note(items, kind, a)
  local gaps = QBD.missing(kind, a)
  if #gaps > 0 then items[#items + 1] = B.missing("Missing: " .. table.concat(gaps, ", ")) end
end

-- 'every time' (questboard._repeat_row)
local function repeat_row(board, st, a)
  local r = QN.repeat_of(a)
  local sid = idof(a)
  local on = B.chip("qb.repeat." .. sid, "every time", r ~= nil, function()
    if r == nil then a["repeat"] = Y.map() else Y.remove(a, "repeat") end
    board:save()
  end, {tip = "qb.repeat"})
  local items = {}
  if r == nil then
    items[1] = B.row({on, B.gap()})
    return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 4}, items))
  end
  local how = P.or_(P.get(r, "until"), "quest")
  local hows = {{"quest", "the quest ends"}, {"fact", "a fact is set"}, {"node", "a step is reached"}}
  items[#items + 1] = B.row({on, B.field("until"), B.menu("qb.repeat_until." .. sid, QBD.label_in(hows, how, how), hows,
                                                          how, function(k)
    for _, key in ipairs(Y.keys(r)) do Y.remove(r, key) end
    if k ~= "quest" then r["until"] = k end
    board:save()
  end, {tip = "qb.repeat_until"}), B.gap()})
  if how == "fact" then
    items[#items + 1] = B.row({B.field("fact"), B.line("qb.repeat_fact." .. sid, P.str(P.or_(P.get(r, "fact"), "")),
                                                         "Fact name", function(t)
      local name = require("conjunction.project").fact_id(t)
      QC.set_in(board, r, "fact", P.T(name) and name or nil)
    end, {tip = "qb.repeat_fact"})})
  elseif how == "node" then
    local q = board:graph_quest()
    local mine = board:node_of(st)
    local entries = {}
    for _, nid in ipairs(QN.order(q)) do
      local k, x = QN.step_kind(q.nodes[nid].step)
      if nid ~= mine and k ~= "start" then
        local words = P.or_(P.get(x or Y.map(), "text"), QC.default_text(board, k, x or Y.map()))
        entries[#entries + 1] = {nid, (QG.LABEL[k] or k) .. ": " .. P.str(words)}
      end
    end
    local cur = P.get(r, "node")
    items[#items + 1] = B.row({B.field("step"), B.menu("qb.repeat_node." .. sid, QBD.label_in(entries, cur, "choose a step"),
                                                       entries, cur, function(nid) QC.set_in(board, r, "node", nid) end,
                                                       {tip = "qb.repeat_node"}), B.gap()})
  end
  return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 4}, items))
end

-- --- the editors (a goal's, an action's)
local GOAL = {}
local ACTION = {}
QC.GOAL, QC.ACTION = GOAL, ACTION

-- who / what the step is about (questboard._target_field): a button showing it, a click opens its list
function QC.target_field(board, a, key, label, what, opts)
  opts = opts or {}
  local ident = opts.ident or idof(a)
  local ref = P.get(a, key)
  local place, oid = "", ""
  if P.T(ref) then
    local s = P.str(ref)
    local cut = s:find("/", 1, true)
    if cut then place, oid = s:sub(1, cut - 1), s:sub(cut + 1) else place = s end
  end
  local waiting = board.waiting and board.waiting[1] == ident and board.waiting[2] == key
  local text
  local found = P.T(ref) and not waiting and board:find(ref) or nil
  local WP = require("conjunction.world_pick")
  local in_world = P.T(ref) and not waiting and WP.label(board.ed.project, P.str(ref)) or nil
  if waiting then
    text = board.waiting[3] == "pick" and "Click in world. Esc cancels" or "Place in world. Esc cancels"
  elseif in_world then
    local gone = WP.gone(board.ed.project, P.str(ref), board.ed.cam and board.ed.cam.pos)
    text = in_world .. (gone and "  ·  not in the world any more" or "  ·  in the world")
    if gone then in_world = nil end                  -- (shown as missing: a click chooses another)
  elseif found then
    local o = board.ed.project.places[found[1]].objects[found[2]]
    text = P.str(P.or_(P.get(o, "display"), P.replace(oid, "_", " "))) ..
           (Y.len(board.ed.project.places) > 1 and ("  ·  " .. place) or "")
  elseif P.T(ref) then
    -- deleted in the world (MaximdeWinter 24.10.: it still read "Adventurer"): missing, a click chooses another
    text = "missing (" .. P.replace(oid ~= "" and oid or place, "_", " ") .. ")"
  else
    text = ({people = "choose who", creatures = "choose who", clues = "choose a clue",
             containers = "choose a container"})[what] or "choose what"
  end
  local open = board.open_picker and board.open_picker[1] == ident and board.open_picker[2] == key
  local b = B.button("qb.target." .. ident .. "." .. key, text .. (open and "  ▴" or "  ▾"),
                     function() board:toggle_picker(a, key, ident, opts.on_set, opts.world, opts.many) end,
                     (found or in_world or (waiting and P.T(ref))) and "target" or "target_empty",
                     {tip = "qb.target", waiting = waiting, missing = P.T(ref) and not found and not in_world and not waiting})
  local locate = found and board.ed.locate and B.icon("qb.locate." .. ident .. "." .. key, "crosshair", function()
    board.ed:locate(found[1], found[2])
  end, {tip = {"", "Shows it in the world and selects it"}}) or nil
  if in_world and board.ed.locate_world then          -- (a thing the game placed: the camera to it, marked)
    locate = B.icon("qb.locate." .. ident .. "." .. key, "crosshair", function()
      board.ed:locate_world(P.str(ref))
    end, {tip = {"", "Shows it in the world"}})
  end
  local row = B.row(locate and {B.field(label), b, locate, B.gap()} or {B.field(label), b, B.gap()})
  if opts.trash then table.insert(row.layout.items, opts.trash) end     -- (added after: its gap keeps the stretch)
  local items = {row}
  if P.T(ref) and not waiting and board:find(ref) then items[#items + 1] = QC.name_field(board, a, key, ref) end
  if open and board.search_list then items[#items + 1] = board:search_list(a, key, what, ident, opts.on_set) end
  return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, items))
end

-- its name, changeable here (questboard._name_field)
function QC.name_field(board, a, key, ref)
  local QS = require("conjunction.quest")
  local found = board:find(ref)
  local o = board.ed.project.places[found[1]].objects[found[2]]
  local oid = P.str(ref):match("/(.*)$") or ""
  local cap = PYS.from_cps(PYS.cps(P.replace(oid, "_", " ")))
  local first = PYS.cps(cap)
  local now = P.str(P.or_(P.get(o, "display"), (#first > 0 and (PYS.upper(PYS.from_cps(first, 1, 1)) ..
                                                                PYS.lower(PYS.from_cps(first, 2))) or "")))
  local e = B.line("qb.name." .. idof(a) .. "." .. key, now, "Name", function(t)
    t = PYS.strip(t)
    if t == now then return end
    board.ed.project:rename_object(found[1], found[2], t)
    board:save()
  end, {tip = QS.is_actor(o) and "qb.name_person" or "qb.name_thing"})
  return B.row({B.field("name"), e, B.gap()})
end

-- an item (questboard._item_line): a button with its name (the item chooser), a trash can to take it out
function QC.item_line(board, d, key, opts)
  opts = opts or {}
  key = key or "item"
  local value = P.str(P.or_(P.get(d, key), ""))
  local function put(ref)
    if opts.on_set then opts.on_set(ref) else QC.set_in(board, d, key, ref) end
  end
  local label = value ~= "" and board:item_label(value) or ("+ " .. (opts.placeholder or "item"))
  local id = "qb.item." .. (opts.ident or idof(d)) .. "." .. key
  local name = value ~= "" and "target" or "target_empty"
  local b = B.button(id, label, function() board:choose_item(put, nil, nil, value) end, name,
                     {tip = "dlg.item", no_icon = name == "target_empty" and opts.required == false})
  b.stretch = 1
  local items = {b}
  if value ~= "" or opts.removable then
    items[#items + 1] = B.icon(id .. ".x", "trash-2", function() put(nil) end, {tip = "ins.remove_item"})
  end
  return W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 2}, items))
end

-- a number field with its unit (questboard._spin)
function QC.spin(board, d, key, lo, hi, suffix, default, scale)
  scale = scale or 1
  local v = require("conjunction.pynum").round0(tonumber(P.str(P.get(d, key, default / scale))) * scale)
  local sp = B.spin("qb.spin." .. idof(d) .. "." .. key, v, lo, hi, function(x)
    QC.set_in(board, d, key, scale ~= 1 and x / scale or x, false)
  end)
  return B.with_unit(sp, suffix)
end

-- where: the spot (questboard._place_field)
function QC.place_field(board, a)
  local items = {B.field("where")}
  local found = P.T(P.get(a, "at")) and board:find(a.at) or nil
  local waiting = board.waiting and board.waiting[1] == idof(a) and board.waiting[2] == "at"
  if found then
    local label = "the spot" .. (Y.len(board.ed.project.places) > 1 and ("  ·  " .. found[1]) or "")
    items[#items + 1] = B.menu("qb.spot." .. idof(a), label .. "  ▾", {{"show", "Go to"}, {"again", "Re-place"},
                                                                       {"remove", "Delete from world"}}, nil,
                               function(k) board:spot(a, k) end, {tip = "qb.spot", colour = 0xeeeeeeff, bold = true})
  else
    items[#items + 1] = B.button("qb.spot." .. idof(a), waiting and "Click in the world. Esc cancels" or "+ Set the spot",
                                 function() board:request_spot(a) end, "target_empty", {tip = "qb.spot", waiting = waiting})
  end
  if not found and not waiting and P.T(P.get(a, "pos")) then
    items[#items + 1] = B.field(string.format("now: a point %.0f, %.0f", a.pos[1], a.pos[2]))
  elseif not found and not waiting and P.T(P.get(a, "place")) then
    items[#items + 1] = B.field("now: the middle of " .. P.str(a.place))
  end
  items[#items + 1] = W.stretch(1)
  return W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 4}, items))
end

-- the map's mark: a pin or a search area (questboard._map_mark)
function QC.map_mark(board, a)
  local sid = idof(a)
  local kinds = {"area", "pin"}
  local cur = P.get(a, "map", "area") == "pin" and 2 or 1
  local combo = B.combo("qb.map." .. sid, kinds, cur, function(i)
    if kinds[i] == "pin" then a.map = "pin" else Y.remove(a, "map") end
  end, {tip = "qb.map_mark"})
  local size = B.spin("qb.map_r." .. sid, math.tointeger(tonumber(P.str(P.or_(P.get(a, "map_radius"), P.get(a, "radius", 10)))))
                      or 10, 2, 500, function(v)
    if v == math.tointeger(tonumber(P.str(P.get(a, "radius", 10)))) then Y.remove(a, "map_radius") else a.map_radius = v end
  end, {tip = "qb.map_radius"})
  return B.row({B.field("map"), combo, B.with_unit(size, "m"), B.gap()})
end

-- at a time of day; leaving again fails the quest (questboard._when_stay)
function QC.when_stay(board, a)
  local sid = idof(a)
  local items = {"Any time", "morning", "day", "evening", "night"}
  local when = P.get(a, "when")
  local cur = 1
  for i, t in ipairs(items) do if t == when then cur = i end end
  if P.T(when) and cur == 1 then
    items[#items + 1] = P.str(when)
    cur = #items
  end
  local combo = B.combo("qb.when." .. sid, items, cur, function(i)
    local text = items[i]
    if PYS.lower(text) == "any time" then Y.remove(a, "when") else a.when = text end
  end, {tip = "qb.when"})
  local stay = B.check("qb.stay." .. sid, "Fail on leaving", P.T(P.get(a, "stay")), function(on)
    if on then a.stay = true else Y.remove(a, "stay") end
  end, {tip = "qb.stay"})
  return B.row({B.field("when"), combo, stay, B.gap()})
end

GOAL["goto"] = function(board, st, a, v)
  local modes = {{"arrive", "Arrive"}, {"leave", "Leave the area"}, {"near", "Near someone or something"},
                 {"look", "Look at"}}
  local mode = P.or_(P.get(a, "mode"), "arrive")
  local sid = idof(a)
  v[#v + 1] = B.row({B.menu("qb.goto_mode." .. sid, QBD.label_in(modes, mode, mode), modes, mode, function(k)
    QC.set_in(board, a, "mode", k ~= "arrive" and k or nil)
  end, {tip = "qb.goto_mode"}), B.gap()})
  -- (a person of the project, or a thing the game placed: a statue, the city gate - Pick in world takes it)
  if mode == "near" then
    v[#v + 1] = QC.target_field(board, a, "who", "who", "people", {world = "any"})
    local r = B.spin("qb.radius." .. sid, math.tointeger(tonumber(P.str(P.get(a, "radius", 5)))) or 5, 1, 200,
                     function(x) QC.set_in(board, a, "radius", x, false) end, {tip = "qb.radius"})
    v[#v + 1] = B.row({B.field("within"), B.with_unit(r, "m"), B.gap()})
    return
  end
  if mode == "look" then
    v[#v + 1] = QC.target_field(board, a, "who", "who", "people", {world = "any"})
    v[#v + 1] = B.row({B.field("for"), QC.spin(board, a, "seconds", 1, 60, " s", 3), B.field("within"),
                       QC.spin(board, a, "radius", 1, 200, " m", 20), B.gap()})
    return
  end
  v[#v + 1] = QC.place_field(board, a)
  local r = B.spin("qb.radius." .. sid, math.tointeger(tonumber(P.str(P.get(a, "radius", 10)))) or 10, 1, 200,
                   function(x) QC.set_in(board, a, "radius", x, false) end, {tip = "qb.radius"})
  v[#v + 1] = B.row({B.field("radius"), B.with_unit(r, "m"), B.gap()})
  v[#v + 1] = QC.map_mark(board, a)
  v[#v + 1] = QC.when_stay(board, a)
end

-- how the talk starts (questboard._talk_start)
function QC.talk_start(board, a)
  local start = P.or_(P.get(a, "start"), "interact")
  local sid = idof(a)
  local how = B.menu("qb.talk_start." .. sid, QBD.label_in(QBD.TALK_STARTS, start, start), QBD.TALK_STARTS, start,
                     function(k) QC.set_in(board, a, "start", k ~= "interact" and k or nil) end, {tip = "qb.talk_start"})
  local row = {B.field("starts"), how}
  if start ~= "interact" and start ~= "now" then
    local r = B.spin("qb.talk_radius." .. sid, math.tointeger(tonumber(P.str(P.get(a, "radius", start == "near" and 6 or 10))))
                     or 6, 2, 60, function(x) QC.set_in(board, a, "radius", x, false) end, {tip = "qb.talk_radius"})
    row[#row + 1] = B.with_unit(r, "m")
  end
  if start == "calls" then
    local call = P.or_(P.get(a, "call"), {Y.map()})[1]
    row[#row + 1] = B.line("qb.talk_call." .. sid, P.str(P.get(call, "text", "")), "Call-out line", function(t)
      t = PYS.strip(t)
      QC.set_in(board, a, "call", t ~= "" and Y.list({Y.map({"who", "npc", "text", t})}) or nil, false)
    end, {tip = "qb.talk_call"})
  else
    row[#row + 1] = B.gap()
  end
  return B.row(row)
end

-- how much the dialogue has and the way into it (MaximdeWinter 13.11.: its lines and answers listed here took room
-- nobody needed - the dialogue's own view shows them)
function QC.dialogue_preview(board, st, a)
  local DL = require("conjunction.dialogue")
  local lines = DL.from_step(a)
  local v = {}
  local info = B.field(#lines > 0 and DL.summary(lines) or "no lines yet")
  local gap = B.gap()
  gap.stretch = 1
  local edit = B.button("qb.edit_dialogue." .. idof(a), P.T(P.get(a, "scene")) and "Open scene" or "Edit dialogue",
                        function() board:open_dialogue(st) end, "small",
                        {tip = "qb.edit_dialogue"})
  local timeline = B.button("qb.timeline." .. idof(a), "Timeline", function() board:open_timeline(st) end, "small",
                            {tip = "qb.timeline"})
  -- (above its lines: 11.11., with a few lines Timeline and Open scene slid under the card's edge)
  local row = require("conjunction.features").scenes() and {info, gap, timeline, edit} or {info, gap, edit}
  table.insert(v, 1, W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, row)))
  return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 2}, v))
end

GOAL.talk = function(board, st, a, v)
  v[#v + 1] = QC.target_field(board, a, "npc", "who", "people")
  local mouth = board.mouth_row and board:mouth_row(P.get(a, "npc"))
  if mouth then v[#v + 1] = mouth end
  v[#v + 1] = QC.talk_start(board, a)
  v[#v + 1] = QC.dialogue_preview(board, st, a)
end

GOAL.kill = function(board, st, a, v)
  if P.T(P.get(a, "target")) and not P.T(P.get(a, "targets")) then
    a.targets = Y.list({a.target})
    Y.remove(a, "target")
  end
  if P.get(a, "targets") == nil then a.targets = Y.list({}) end
  local targets = a.targets
  local holders = {}
  for _, t in ipairs(targets) do holders[#holders + 1] = Y.map({"target", t}) end
  if #targets == 0 then holders[1] = Y.map() end
  for k, hd in ipairs(holders) do
    local trash
    if k > 1 and #targets > 0 then
      trash = B.icon("qb.kill_x." .. idof(a) .. "." .. k, "trash-2", function()
        table.remove(a.targets, k)
        board:save()
      end, {tip = "qb.remove_action"})
    end
    v[#v + 1] = QC.target_field(board, hd, "target", k == 1 and "who" or "and", "creatures", {
      ident = idof(a) .. ".targets." .. k, trash = trash,
      on_set = function(ref)
        if k <= #a.targets then a.targets[k] = ref else a.targets[#a.targets + 1] = ref end
        board:save()
      end})
  end
  board:merchant_note(v, targets)
  local row = {}
  if #targets > 0 then
    row[#row + 1] = B.button("qb.kill_add." .. idof(a), "+ who", function()
      board.open_picker = nil
      a.targets[#a.targets + 1] = ""
      board:save()
    end, "plus", {tip = "qb.kill_add"})
  end
  if board.waiting and board.waiting[1] == idof(a) and board.waiting[2] == "group" then
    row[#row + 1] = B.button("qb.kill_group." .. idof(a), "Click in the world. Esc cancels",
                             function() board.ed:cancel_request() end, "small", {tip = "qb.kill_group"})
  else
    local groups = {}
    for _, n in ipairs({2, 3, 4, 5, 6, 8}) do groups[#groups + 1] = {n, "a group of " .. n} end
    row[#row + 1] = B.menu("qb.kill_group." .. idof(a), "+ group", groups, nil, function(n) board:add_group(a, n) end,
                           {tip = "qb.kill_group", plus = true})
  end
  row[#row + 1] = B.gap()
  v[#v + 1] = B.row(row)
end

-- more items for a loot / collect / equip (questboard._more_items): a row each, + item
function QC.more_items(board, v, a)
  if not P.T(P.get(a, "item")) then return end
  if P.get(a, "more_items") == nil then a.more_items = Y.list({}) end
  local more = a.more_items
  for k, x in ipairs(more) do
    local count = B.spin("qb.more_count." .. idof(x), math.tointeger(tonumber(P.str(P.get(x, "count", 1)))) or 1, 1, 999,
                         function(n) QC.set_in(board, x, "count", n, false) end, {tip = "qb.count"})
    local line = QC.item_line(board, x, "item", {required = false, removable = true, on_set = function(ref)
      if ref == nil then table.remove(more, k) else x.item = ref end
      board:save()
    end})
    line.stretch = 1
    v[#v + 1] = B.row({B.field("and"), line, count}, false)
  end
  v[#v + 1] = B.row({B.button("qb.more_items." .. idof(a), "+ item", function()
    more[#more + 1] = Y.map()
    board:save()
  end, "plus", {tip = "qb.more_items"}), B.gap()})
end

-- the item and how many (questboard._item_field)
function QC.item_field(board, a)
  local count = B.spin("qb.count." .. idof(a), math.tointeger(tonumber(P.str(P.get(a, "count", 1)))) or 1, 1, 999,
                       function(n) QC.set_in(board, a, "count", n, false) end, {tip = "qb.count"})
  local line = QC.item_line(board, a)
  line.stretch = 1
  return B.row({B.field("what"), line, B.field("how many"), count}, false)
end

QC.SOURCES = {{"container", "in a container"}, {"person", "a person carries it"},
              {"none", "not placed - the player finds or buys it"}}
-- where a collect's item is (questboard._source_field)
function QC.source_field(board, a)
  local v = {}
  local src = P.get(a, "from")
  local how = B.menu("qb.item_from." .. idof(a), QBD.label_in(QC.SOURCES, src, "Location not set"), QC.SOURCES, src,
                     function(k)
    if k ~= P.get(a, "from") then Y.remove(a, "in") end
    QC.set_in(board, a, "from", k)
  end, {tip = "qb.item_from", dashed = not P.T(src)})
  v[#v + 1] = B.row({B.field("where"), how, B.gap()})
  if src == "container" or src == "person" then
    v[#v + 1] = QC.target_field(board, a, "in", src == "container" and "in" or "who",
                                src == "container" and "containers" or "people")
  end
  -- (a container's random loot: with the item chooser's loot row)
  return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, v))
end

-- the way: points clicked in the world (questboard._path_field)
function QC.path_field(board, a)
  local pts = P.list(P.get(a, "path"))
  local drawing = board.ed.path_tool ~= nil and board.path_of == a
  local items = {B.field("way"), B.field(#pts > 0 and (#pts .. " point" .. (#pts ~= 1 and "s" or "")) or "not drawn yet")}
  items[#items + 1] = B.button("qb.path_add." .. idof(a), drawing and "Done" or (#pts > 0 and "Edit in the world" or
                               "Draw in the world"), function()
    if drawing then board.ed.path_tool:finish() else board:draw_path(a) end
  end, #pts > 0 and "target" or "target_empty", {tip = "qb.path_add", icon = "spline"})
  if #pts > 0 then
    items[#items + 1] = B.icon("qb.path_clear." .. idof(a), "trash-2", function()
      Y.remove(a, "path")
      board:save()
    end, {tip = "qb.path_clear"})
  end
  items[#items + 1] = W.stretch(1)
  return W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 4}, items))
end

-- a line of text kept in d[key] (questboard._text_line)
function QC.text_line(board, d, key, placeholder, opts)
  opts = opts or {}
  local e = B.line("qb.text." .. idof(d) .. "." .. key, P.str(P.get(d, key, "")), placeholder, function(t)
    QC.set_in(board, d, key, P.T(PYS.strip(t)) and PYS.strip(t) or nil, false)
  end, {tip = opts.tip, names = opts.names})
  return e
end

-- Wait until: a fact (questboard._fact_field; a game quest's moment: experimental)
function QC.fact_field(board, a)
  local fact = QC.text_line(board, a, "fact", "a fact - or pick a moment of a game quest", {tip = "qb.wait_fact"})
  fact.stretch = 1
  local items = {B.field("until"), fact}
  if require("conjunction.features").experimental() then
    items[#items + 1] = B.button("qb.wait_moment." .. idof(a), "A moment of a game quest...", function()
      if board.panel.choose_moment then
        board.panel:choose_moment(function(m) a.fact, a.from = m.fact, m.name board:save() end)
      end
    end, "small", {tip = "qb.wait_moment"})
  end
  local row = B.row(items, false)
  if P.T(P.get(a, "from")) then
    return W.widget(W.vbox({margins = {0, 0, 0, 0}}, {row, B.field("a moment of the game's quest " .. P.str(a.from))}))
  end
  return row
end

-- the targets of a list (kill's, fist fight's): a field each, a trash can from the second on
local function target_list(board, a, label1, what, add_tip, merchant)
  if P.get(a, "targets") == nil then a.targets = Y.list({}) end
  local targets = a.targets
  local v = {}
  local holders = {}
  for _, t in ipairs(targets) do holders[#holders + 1] = Y.map({"target", t}) end
  if #targets == 0 then holders[1] = Y.map() end
  for k, hd in ipairs(holders) do
    local trash
    if k > 1 and #targets > 0 then
      trash = B.icon("qb.target_x." .. idof(a) .. "." .. k, "trash-2", function()
        table.remove(a.targets, k)
        board:save()
      end, {tip = "qb.remove_action"})
    end
    v[#v + 1] = QC.target_field(board, hd, "target", k == 1 and label1 or "and", what, {
      ident = idof(a) .. ".targets." .. k, trash = trash,
      on_set = function(ref)
        if k <= #a.targets then a.targets[k] = ref else a.targets[#a.targets + 1] = ref end
        board:save()
      end})
  end
  return v, targets
end

GOAL.fistfight = function(board, st, a, v)
  local rows, targets = target_list(board, a, "with", "people")
  for _, r in ipairs(rows) do v[#v + 1] = r end
  if #targets > 0 then
    v[#v + 1] = B.row({B.button("qb.fist_add." .. idof(a), "+ who", function()
      board.open_picker = nil
      a.targets[#a.targets + 1] = ""
      board:save()
    end, "plus", {tip = "qb.fistfight_add"}), B.gap()})
  end
  board:merchant_note(v, targets)
end

-- a deck's words (minigames.deck_label)
QC.DECKS = {"Baron", "BoatBuilder", "CardProdigy", "CircusGwentAddict", "Crach", "CrossroadsInnkeeper", "Dijkstra",
            "Gambler", "Gremista", "Halflings", "Hermit", "Lambert", "LugosTheMad", "MarkizaSerenity", "Mousesack",
            "NKEasy", "NKNormal", "NKHard", "NKTournament", "NMLEasy", "NMLNormal", "NMLHard", "NMLTournament",
            "NMLTournament2", "NilfEasy", "NilfNormal", "NilfHard", "NilfPrologue", "NilfTournament", "NilfTournament2",
            "Olgierd", "Olivier", "Roche", "ScoiaEasy", "ScoiaNormal", "ScoiaHard", "ScoiaTournament",
            "ScoiaTournament2", "ScoiaTrader", "Shani", "Sjusta", "SkelEasy", "SkelNormal", "SkelHard", "SkelTournament2",
            "Stjepan", "Thaler", "VimmeVivaldi", "Zoltan"}
local FACTIONS = {{"NK", "Northern Realms"}, {"NML", "Monsters"}, {"Nilf", "Nilfgaard"}, {"Scoia", "Scoia'tael"},
                  {"Skel", "Skellige"}}
local RESTS = {Easy = true, Normal = true, Hard = true, Prologue = true, Tournament = true, Tournament2 = true}
function QC.deck_label(deck)
  for _, f in ipairs(FACTIONS) do
    local rest = deck:sub(#f[1] + 1)
    if P.startswith(deck, f[1]) and RESTS[rest] then return f[2] .. ", " .. P.replace(rest:lower(), "2", " 2") end
  end
  return (deck:gsub("(%l)(%u)", "%1 %2"))
end

GOAL.gwent = function(board, st, a, v)
  local deck = P.get(a, "deck")
  local decks = P.copy_list(QC.DECKS)
  require("conjunction.pysort").sort(decks, function(k)
    return {QC.deck_label(k):find(",", 1, true) and 0 or 1, QC.deck_label(k)}
  end)
  local entries = {}
  for _, k in ipairs(decks) do entries[#entries + 1] = {k, QC.deck_label(k)} end
  local d = B.menu("qb.gwent_deck." .. idof(a), P.T(deck) and QC.deck_label(deck) or "Which deck", entries, deck,
                   function(k) QC.set_in(board, a, "deck", k) end, {tip = "qb.gwent_deck", dashed = not P.T(deck)})
  local hard = P.get(a, "difficulty", "medium")
  local how = B.menu("qb.gwent_hard." .. idof(a), P.str(hard), {{"medium", "medium"}, {"hard", "hard"}}, hard,
                     function(k) QC.set_in(board, a, "difficulty", k ~= "medium" and k or nil) end, {tip = "qb.gwent_hard"})
  v[#v + 1] = B.row({B.field("against"), d, how, B.gap()})
end

GOAL.loot = function(board, st, a, v, kind)
  kind = kind or "loot"
  v[#v + 1] = QC.target_field(board, a, "object", "what", kind == "loot" and "loot" or "things",
                              {world = require("conjunction.world_pick").FOR_GOAL[kind]})
  if kind == "use" then v[#v + 1] = QC.use_how(board, a) end
  if kind ~= "loot" then v[#v + 1] = QC.interaction_row(board, a, kind) end
  if kind == "loot" then
    local take = QC.item_line(board, a, "item", {required = false})
    take.tip = "qb.loot_take"
    v[#v + 1] = B.row({B.field("take"), take})
    QC.more_items(board, v, a)
  end
end
GOAL.examine = function(board, st, a, v) GOAL.loot(board, st, a, v, "examine") end
GOAL.use = function(board, st, a, v) GOAL.loot(board, st, a, v, "use") end

-- Use / Examine on a thing of the world with more than one interaction of its own: which one the goal waits for
-- (the game's interaction by its component's name; 8c, 11.11.) - nil when there is nothing to choose
QC.INTERACTION_WORDS = {cdoorcomponent0 = "open or close it", loot = "loot it", interactiveclue = "examine it",
                        locked = "try the lock", unlock = "unlock it"}
function QC.interaction_row(board, a, kind)
  local WP = require("conjunction.world_pick")
  local ref = P.str(P.get(a, "object") or "")
  if not WP.is_ref(ref) or P.has(a, "item") or P.T(P.get(a, "state")) then return nil end
  local o = WP.get(board.ed.project, ref)
  local parts = {}
  for _, p in ipairs(o and o.parts or {}) do                -- (the medallion's: not something the player does)
    if P.str(p):lower() ~= "medallion" then parts[#parts + 1] = P.str(p) end
  end
  if #parts < 2 then return nil end
  local function word(p)
    return QC.INTERACTION_WORDS[p:lower()] or (p:gsub("(%l)(%u)", "%1 %2"):gsub("_", " "):lower())
  end
  local auto = WP.interaction_for(o, kind)
  local cur = P.str(P.get(a, "action") or auto or "")
  local entries = {}
  for _, p in ipairs(parts) do entries[#entries + 1] = {p, word(p)} end
  return B.row({B.field("by"), B.menu("qb.interaction." .. idof(a), word(cur), entries, cur, function(k)
    if k == auto then Y.remove(a, "action") else a.action = k end
    board:save()
  end, {tip = "qb.interaction"}), B.gap()})
end

-- Use: when it counts (questboard._use_how)
function QC.use_how(board, a)
  local how = P.has(a, "item") and "item" or P.str(P.get(a, "state", ""))
  local row = {B.field("done when"), B.menu("qb.use_how." .. idof(a), QBD.label_in(QBD.USE_HOW, how, how), QBD.USE_HOW,
                                            how, function(k)
    Y.remove(a, "state")
    if k ~= "item" then Y.remove(a, "item") end
    if k == "on" or k == "off" then a.state = k
    elseif k == "item" and not P.T(P.get(a, "item")) then a.item = "" end
    board:save()
  end, {tip = "qb.use_how"})}
  if how == "item" then
    row[#row + 1] = QC.item_line(board, a)
    return B.row(row)
  end
  row[#row + 1] = B.gap()
  return B.row(row)
end

GOAL.race = function(board, st, a, v)
  v[#v + 1] = QC.path_field(board, a)
  if P.get(a, "racers") == nil then a.racers = Y.list({}) end
  local racers = a.racers
  local holders = {}
  for _, r in ipairs(racers) do holders[#holders + 1] = Y.map({"who", r}) end
  if #racers == 0 then holders[1] = Y.map() end
  for k, hd in ipairs(holders) do
    local trash
    if k > 1 and #racers > 0 then
      trash = B.icon("qb.race_x." .. idof(a) .. "." .. k, "trash-2", function()
        table.remove(a.racers, k)
        board:save()
      end, {tip = "qb.race_remove"})
    end
    v[#v + 1] = QC.target_field(board, hd, "who", k == 1 and "against" or "and", "people", {
      ident = idof(a) .. ".racers." .. k, trash = trash,
      on_set = function(ref)
        if k <= #a.racers then a.racers[k] = ref else a.racers[#a.racers + 1] = ref end
        board:save()
      end})
  end
  local paces = {{"easy", "easy (they run)"}, {"normal", "normal (fast)"}, {"hard", "hard (they sprint)"}}
  local pace = P.or_(P.get(a, "pace"), "normal")
  local add = B.button("qb.race_add." .. idof(a), "+ who", function()
    a.racers[#a.racers + 1] = ""
    board:save()
  end, "plus", {tip = "qb.race_add"})
  v[#v + 1] = B.row({add, B.field("pace"), B.menu("qb.race_pace." .. idof(a), QBD.label_in(paces, pace, pace), paces, pace,
                                                  function(k) QC.set_in(board, a, "pace", k) end, {tip = "qb.race_pace"}),
                     B.field("checkpoints"), QC.spin(board, a, "radius", 2, 30, " m", 6), B.gap()})
  v[#v + 1] = B.row({B.check("qb.race_checkpoints." .. idof(a), "Checkpoints must be passed",
                             P.T(P.get(a, "checkpoints")), function(on)
    QC.set_in(board, a, "checkpoints", on and true or nil, false)
  end, {tip = "qb.race_checkpoints"}), B.gap()})
end

GOAL.follow = function(board, st, a, v)
  v[#v + 1] = QC.target_field(board, a, "who", "who", "people")
  v[#v + 1] = QC.path_field(board, a)
  local lead = P.T(P.get(a, "lead"))
  local how = B.menu("qb.follow_lead." .. idof(a), lead and "The player leads" or "The player follows",
                     {{false, "The player follows"}, {true, "The player leads"}}, lead,
                     function(k) QC.set_in(board, a, "lead", k or nil) end, {tip = "qb.follow_lead"})
  local run = P.T(P.get(a, "run"))
  local pace = B.menu("qb.follow_run." .. idof(a), run and "runs" or "walks", {{false, "walks"}, {true, "runs"}}, run,
                      function(k) QC.set_in(board, a, "run", k or nil) end, {tip = "qb.follow_run"})
  local row = {B.field("how"), how, pace}
  if not lead then
    row[#row + 1] = B.field("waits beyond")
    row[#row + 1] = QC.spin(board, a, "wait", 3, 60, " m", 10)
  end
  row[#row + 1] = B.gap()
  v[#v + 1] = B.row(row)
  if not lead then QC.walk_talks(board, v, a) end
end

-- talks on the way of a follow step (questboard._walk_talks)
function QC.walk_talks(board, v, a)
  local points = math.max(1, #P.list(P.get(a, "path")))
  for _, entry in ipairs(P.list(P.get(a, "talks"))) do
    if P.get(entry, "talk") == nil then entry.talk = Y.map() end
    local t = entry.talk
    t.npc, t.start = P.get(a, "who") or Y.null, "overhear"
    local n = 0
    for _, x in ipairs(P.list(P.get(t, "dialogue"))) do if P.T(P.get(x, "text")) then n = n + 1 end end
    local lines = B.button("qb.walk_lines." .. idof(entry), n > 0 and (n .. " line" .. (n ~= 1 and "s" or "")) or
                           "Write the lines", function() board:open_dialogue(entry) end, "target",
                           {tip = "qb.walk_talk_lines"})
    local spin = QC.spin(board, t, "at", 1, points, "", 1)
    local rm = B.icon("qb.walk_x." .. idof(entry), "trash-2", function()
      local keep = Y.list({})
      for _, e in ipairs(a.talks) do if e ~= entry then keep[#keep + 1] = e end end
      if #keep > 0 then a.talks = keep else Y.remove(a, "talks") end
      board:save()
    end, {tip = "qb.remove_action"})
    v[#v + 1] = B.row({B.field("talk at point"), spin, lines, rm, B.gap()})
  end
  v[#v + 1] = B.row({B.button("qb.walk_add." .. idof(a), "+ talk on the way", function() board:add_walk_talk(a) end,
                              "plus", {tip = "qb.walk_talk_add"}), B.gap()})
end

-- Notice: the board (one placed for the quest, or one of the game's), the title, what it says, a note it gives
GOAL.notice = function(board, st, a, v)
  local game = P.str(P.or_(P.get(a, "board"), ""))
  if not P.startswith(game, "tag:") then v[#v + 1] = QC.target_field(board, a, "board", "board", "things") end
  v[#v + 1] = B.row({B.field(P.startswith(game, "tag:") and "board" or "or the game's"),
                     B.menu("qb.notice_board." .. idof(a), P.startswith(game, "tag:") and P.replace(game:sub(5), "_", " ")
                            or "A notice board of the game", board:game_boards(), game, function(k)
                       QC.set_in(board, a, "board", k)
                     end, {tip = "qb.notice_game_board"}), B.gap()})
  v[#v + 1] = B.row({B.field("title"), QC.text_line(board, a, "title", "the notice's title on the board")})
  v[#v + 1] = B.autotext("qb.notice_text." .. idof(a), P.str(P.get(a, "body", "")), "what the notice says", function(t)
    t = PYS.strip(t)
    QC.set_in(board, a, "body", t ~= "" and t or nil, false)
  end, {tip = "qb.notice_text"})
  v[#v + 1] = B.row({B.field("gives"), QC.item_line(board, a, "item", {placeholder = "A note to read again (optional)",
                                                                       required = false, removable = true})})
end

GOAL.read = function(board, st, a, v) v[#v + 1] = B.row({B.field("what"), QC.item_line(board, a)}) end
GOAL.equip = function(board, st, a, v)
  v[#v + 1] = B.row({B.field("what"), QC.item_line(board, a)})
  QC.more_items(board, v, a)
end
GOAL.collect = function(board, st, a, v)
  v[#v + 1] = QC.item_field(board, a)
  QC.more_items(board, v, a)
  if P.T(P.get(a, "item")) then v[#v + 1] = QC.source_field(board, a) end
end
GOAL.defeat = function(board, st, a, v)
  v[#v + 1] = QC.target_field(board, a, "target", "who", "people")
  v[#v + 1] = B.row({B.field("until health below"), QC.spin(board, a, "below", 5, 90, " %", 20), B.gap()})
end
GOAL.wait = function(board, st, a, v)
  local untl = P.T(P.get(a, "until"))
  local how = B.menu("qb.wait_mode." .. idof(a), untl and "Until the hour" or "Game time",
                     {{false, "Game time"}, {true, "Until the hour"}}, untl, function(k) board:wait_mode(a, k) end,
                     {tip = "qb.wait_mode"})
  local key = untl and "until" or "time"
  local t = B.line("qb.wait_time." .. idof(a), P.str(untl and P.get(a, "until", "22:00") or P.get(a, "time", "00:00:10")),
                   "", function(x) QC.set_in(board, a, key, x, false) end,
                   {tip = untl and "qb.time_at" or "qb.time", mask = untl and "99:99" or "99:99:99"})
  v[#v + 1] = B.row({B.field("wait"), how, t, B.gap()})
end
GOAL.waitfor = function(board, st, a, v)
  local what = P.or_(P.get(a, "what"), "senses")
  local parts = {B.field("for"), B.menu("qb.waitfor." .. idof(a), QBD.label_in(QBD.WAIT_FOR, what, what), QBD.WAIT_FOR,
                                        what, function(k) QC.set_in(board, a, "what", k) end, {tip = "qb.waitfor"})}
  if what == "health" then
    parts[#parts + 1] = B.spin("qb.waitfor_pc." .. idof(a), math.tointeger(tonumber(P.str(P.get(a, "percent", 30)))) or 30,
                               1, 99, function(x) QC.set_in(board, a, "percent", x, false) end,
                               {tip = "qb.waitfor_percent", suffix = " %"})
  end
  parts[#parts + 1] = B.gap()
  v[#v + 1] = B.row(parts)
end
GOAL.waitfact = function(board, st, a, v)
  if P.T(P.get(a, "conditions")) and QC.conditions_editor then
    v[#v + 1] = QC.conditions_editor(board, a, true)
  else
    v[#v + 1] = QC.fact_field(board, a)
    v[#v + 1] = B.row({B.button("qb.cond_add." .. idof(a), "+ condition", function()
      board:to_conditions(a)[#board:to_conditions(a) + 1] = Y.map({"kind", "area"})
      board:save()
    end, "small", {tip = "qb.cond_add"}), B.gap()})
  end
end

-- Find clues: in sequence, each something to examine or a track (questboard._clues_editor)
QC.HOW = {{"", "Default"}, {"ground", "Ground"}, {"eye", "Eye level"}, {"body", "Body"}, {"high", "up high"}}
local function framed(items, spacing)
  return W.widget(W.vbox({margins = {6, 4, 6, 4}, spacing = spacing or 3}, items), {
    margins = {1, 1, 1, 1},
    draw = function(_, r)
      D.fill(r.x, r.y, r.w, r.h, 0x222226ff)
      D.rect(r.x, r.y, r.w, r.h, 0x3a3a40ff, 1)
      B.bg = 0x222226ff
    end})
end
QC.framed = framed

GOAL.clues = function(board, st, a, v)
  if P.get(a, "clues") == nil then a.clues = Y.list({}) end
  local items = a.clues
  v[#v + 1] = B.row({B.check("qb.clues_order." .. idof(a), "In sequence", P.T(P.get(a, "in_order")), function(on)
    QC.set_in(board, a, "in_order", on and true or nil, false)
  end, {tip = "qb.clues_order"}), B.gap()})
  for k, c in ipairs(items) do
    local rv = {}
    if P.has(c, "trail") and not P.T(P.get(c, "object")) then
      local o = P.T(P.get(c, "trail")) and board:object_of(c.trail) or nil
      local kind = P.or_(P.get(o or Y.map(), "trail"), P.get(c, "kind"))
      local label = QC.trail_label(kind)
      local n = #P.list(P.get(o or Y.map(), "pieces"))
      local gap = B.gap()
      gap.stretch = 1
      rv[#rv + 1] = W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, {
        B.field("track " .. k), B.field(n > 0 and (label .. " · " .. n .. " pieces") or (label .. " · not drawn yet")), gap,
        B.button("qb.trail_draw." .. idof(c), n > 0 and "Redraw track" or "Draw track", function() end,
                 n > 0 and "target" or "target_empty", {tip = "qb.trail_draw"})}))
      if P.get(c, "says") == nil then c.says = Y.map() end
      rv[#rv + 1] = QC.say_field(board, c.says)
    else
      rv[#rv + 1] = QC.target_field(board, c, "object", "examine " .. k, "things")
      local talk = P.get(c, "dialogue")
      local how = B.menu("qb.clue_how." .. idof(c), "Animation: " .. QBD.label_in(QC.HOW, P.or_(P.get(c, "how"), ""),
                         "Default"), QC.HOW, P.or_(P.get(c, "how"), ""), function(key)
        QC.set_in(board, c, "how", P.T(key) and key or nil)
      end, {tip = "qb.clue_how"})
      local after = B.menu("qb.clue_after." .. idof(c), talk ~= nil and "Then: monologue" or "Then: comment",
                           {{"line", "Then: comment"}, {"talk", "Then: monologue"}}, talk ~= nil and "talk" or "line",
                           function(key) board:clue_after(c, key) end, {tip = "qb.clue_after"})
      rv[#rv + 1] = B.row({how, after, B.gap()})
      if talk ~= nil then
        local n = #require("conjunction.dialogue").walk(talk)
        local gap = B.gap()
        gap.stretch = 1
        rv[#rv + 1] = W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, {
          B.field(n > 0 and (n .. " lines and choices") or "nothing yet"), gap,
          B.button("qb.clue_talk." .. idof(c), "Edit monologue", function() board:open_dialogue(c) end, "small",
                   {tip = "qb.clue_talk"})}))
      else
        if P.get(c, "says") == nil then c.says = Y.map() end
        rv[#rv + 1] = QC.say_field(board, c.says)
      end
    end
    local gap = B.gap()
    gap.stretch = 1
    rv[#rv + 1] = W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, {gap,
      B.icon("qb.clue_x." .. idof(c), "trash-2", function()
        table.remove(items, k)
        board:save()
      end, {tip = "qb.remove_action"})}))
    v[#v + 1] = framed(rv)
  end
  v[#v + 1] = B.row({B.button("qb.clue_add." .. idof(a), "+ examine", function()
    items[#items + 1] = Y.map({"says", Y.map()})
    board:save()
  end, "plus", {tip = "qb.clue_add"}), B.menu("qb.trail_add." .. idof(a), "+ track", QC.trail_kinds(), nil,
                                               function(key) board:add_trail(items, key) end, {tip = "qb.trail_add"}),
                     B.gap()})
end

-- the trails' library (trails.LIBRARY: data/trails.lua)
function QC.trails() return require("conjunction.data.trails") end
function QC.trail_kinds()
  local out = {}
  for _, t in ipairs(QC.trails()) do out[#out + 1] = {t[1], t[3] .. ": " .. t[2]} end
  return out
end
function QC.trail_label(kind)
  for _, t in ipairs(QC.trails()) do if t[1] == kind then return t[2] end end
  return "trail"
end

-- Either / or, All of these: the options, each a goal (questboard._either_editor; a graph: no Then menu)
local function either_editor(board, v, a, every)
  if not every and P.has(a, "ways") and not P.T(P.get(a, "options")) then
    local h = {}
    ACTION.random(board, a, h, "way", "qb.either_way_add")
    v[#v + 1] = h[1]
    return
  end
  if P.get(a, "options") == nil then a.options = Y.list({}) end
  local opts = a.options
  for k, o in ipairs(opts) do
    if P.get(o, "goal") == nil then o.goal = Y.map({"goto", Y.map()}) end
    local gkind, ga = QBD.step_kind(o.goal)
    local num = B.label(k > 1 and ((every and "AND " or "OR ") .. k) or "1", 0xbbbbbbff, 11, true)
    local kind_b = B.menu("qb.either_kind." .. idof(o), QBD.label_in(QBD.EITHER_KINDS, gkind, gkind), QBD.EITHER_KINDS,
                          gkind, function(nk)
      o.goal = Y.map({nk, nk == "goto" and Y.map({"place", board.ed.place, "radius", 10}) or Y.map()})
      board:save()
    end, {tip = "qb.either_kind"})
    local gap = B.gap()
    gap.stretch = 1
    local head = W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, {num, kind_b, gap,
      B.icon("qb.either_x." .. idof(o), "trash-2", function()
        table.remove(opts, k)
        board:save()
      end, {tip = "qb.remove_action"})}))
    local field
    if gkind == "goto" then field = QC.place_field(board, ga)
    elseif gkind == "kill" then field = QC.target_field(board, ga, "target", "who", "creatures")
    else field = QC.target_field(board, ga, "object", "what", "things",
                                 {world = require("conjunction.world_pick").FOR_GOAL[gkind]}) end
    -- (its frame: #222226, 1 px #3a3a40, margins 6 4 6 4, 3 apart)
    v[#v + 1] = W.widget(W.vbox({margins = {6, 4, 6, 4}, spacing = 3}, {head, field}), {
      margins = {1, 1, 1, 1},
      draw = function(_, r)
        D.fill(r.x, r.y, r.w, r.h, 0x222226ff)
        D.rect(r.x, r.y, r.w, r.h, 0x3a3a40ff, 1)
        B.bg = 0x222226ff
      end})
  end
  v[#v + 1] = B.row({B.button("qb.either_add." .. idof(a), every and "+ and" or "+ or", function()
    opts[#opts + 1] = Y.map({"goal", Y.map({"kill", Y.map()})})
    board:save()
  end, "plus", {tip = every and "qb.all_add" or "qb.either_add"}), B.gap()})
end
GOAL.either = function(board, st, a, v) either_editor(board, v, a, false) end
GOAL.all = function(board, st, a, v) either_editor(board, v, a, true) end

-- what the player says (questboard._say_field): typed, or one of his voiced lines
function QC.say_field(board, d)
  local t = stretched(B.line("qb.says." .. idof(d), P.str(P.get(d, "text", "")), "What the player says", function(x)
    board:say_text(d, x)
  end, {tip = "qb.says"}))
  local voiced = P.T(P.get(d, "voice"))
  local voice = B.button("qb.says_voice." .. idof(d), voiced and string.format("Game line, %.1f s",
                         tonumber(P.str(P.or_(P.get(d, "dur"), 0))) or 0) or "", function() board:toggle_voice(d) end,
                         "small", {tip = "qb.says_voice", icon = voiced and "audio-lines" or "audio-lines-x",
                                   icon_colour = voiced and 0x5cb85cff or 0xd9534fff})
  local row = {B.field("Player"), t, voice}
  if voiced then row[#row + 1] = B.icon("qb.says_play." .. idof(d), "play", function() end, {tip = "dlg.play"}) end
  return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 2}, {B.row(row, false)}))
end

ACTION.say = function(board, a, h)
  local DL = require("conjunction.dialogue")
  local speaker = P.has(a, "who") and "someone" or "player"
  local who = B.menu("qb.say_who." .. idof(a), speaker == "player" and "Player" or "Someone else",
                     {{"player", "Player"}, {"someone", "Someone else"}}, speaker, function(k) board:say_speaker(a, k) end,
                     {tip = "qb.say_who"})
  local g = P.get(a, "gesture")
  local gestures = {{"", "No gesture"}}
  for _, x in ipairs(DL.gestures_for and DL.gestures_for() or {}) do gestures[#gestures + 1] = x end
  local gesture = B.menu("qb.say_gesture." .. idof(a), (DL.GESTURE and g and DL.GESTURE[g]) and DL.GESTURE[g][1] or
                         "No gesture", gestures, P.get(a, "gesture", ""), function(k)
    QC.set_in(board, a, "gesture", P.T(k) and k or nil)
  end, {tip = "qb.say_gesture"})
  local moods = {{"", "No mood"}}
  for _, x in ipairs(DL.MOODS or {}) do moods[#moods + 1] = x end
  local m = P.get(a, "mood")
  local mood = B.menu("qb.say_mood." .. idof(a), (DL.MOOD and m and DL.MOOD[m]) or "No mood", moods,
                      P.get(a, "mood", ""), function(k) QC.set_in(board, a, "mood", P.T(k) and k or nil) end,
                      {tip = "qb.say_mood"})
  local v = {B.row({who, gesture, mood, B.gap()})}
  if speaker == "someone" then
    v[#v + 1] = QC.target_field(board, a, "who", "who", "people")
    v[#v + 1] = B.line("qb.says_text." .. idof(a), P.str(P.get(a, "text", "")),
                       "What they say (if left empty, only the gesture)", function(x)
      local words = PYS.split(x)
      QC.set_in(board, a, "text", #words > 0 and table.concat(words, " ") or nil)
    end, {tip = "qb.says_text"})
  else
    v[#v + 1] = QC.say_field(board, a)
  end
  h[#h + 1] = stretched(W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, v)))
end

-- Portal: from an object to a point, back again (questboard._portal_card)
ACTION.portal = function(board, a, h)
  local v = {QC.target_field(board, a, "a", "from", "things")}
  v[#v + 1] = B.row({B.field("to"), QC.point_button(board, a, "b_exit", "arrive"), B.gap()})
  local two = B.chip("qb.portal_two." .. idof(a), "two-way", P.T(P.get(a, "two_way")), function()
    QC.set_in(board, a, "two_way", (not P.T(P.get(a, "two_way"))) and true or nil)
  end, {tip = "qb.portal_two_way"})
  local white_on = P.get(a, "white", true) ~= false
  local white = B.chip("qb.portal_white." .. idof(a), "white fade", white_on, function()
    QC.set_in(board, a, "white", white_on and false or nil)
  end, {tip = "qb.portal_white"})
  v[#v + 1] = B.row({two, white, B.gap()})
  if P.T(P.get(a, "two_way")) then
    v[#v + 1] = QC.target_field(board, a, "b", "back from", "things")
    v[#v + 1] = B.row({B.field("back to"), QC.point_button(board, a, "a_exit", "arrive"), B.gap()})
  end
  local names = board:effect_names(P.get(a, "a"))
  if #names > 0 then
    local opts = {{"", "none"}}
    for _, n in ipairs(names) do opts[#opts + 1] = {n, n} end
    local cur = P.T(P.get(a, "effect")) and P.str(a.effect) or ""
    v[#v + 1] = B.row({B.menu("qb.portal_effect." .. idof(a), "effect: " .. (cur ~= "" and cur or "none"), opts, cur,
                              function(k) QC.set_in(board, a, "effect", P.T(k) and k or nil) end,
                              {tip = "qb.portal_effect"}), B.gap()})
  end
  h[#h + 1] = stretched(W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, v)))
end

-- Stands: who, where, what they do there (questboard._stands)
ACTION.stands = function(board, a, h)
  local NA = require("conjunction.npc_actions")
  local v = {QC.target_field(board, a, "who", "who", "people")}
  local pos = P.get(a, "pos")
  local waiting = waiting_for(board, a, "pos")
  local where = B.button("qb.stands_where." .. idof(a), waiting and "Click in the world. Esc cancels" or
                         (P.T(pos) and string.format("at %.0f, %.0f", NUMF(pos[1]), NUMF(pos[2])) or "+ where"),
                         function() board:request_point(a, "pos") end, P.T(pos) and "target" or "target_empty",
                         {tip = "qb.stands_where"})
  local cur = P.get(a, "action")
  local label = P.T(cur) and (NA.label and NA.label(P.str(cur):match("([^/]*)$")) or P.str(cur)) or "stands"
  local does = B.menu("qb.stands_does." .. idof(a), label, {{"", "stands"}}, cur or "", function(k)
    QC.set_in(board, a, "action", P.T(k) and k or nil)
  end, {tip = "qb.stands_does"})
  v[#v + 1] = B.row({B.field("from now on"), where, B.field("and"), does, B.gap()})
  h[#h + 1] = stretched(W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, v)))
end

-- Game function: the function searched by name (questboard._game_action; its fields once chosen)
ACTION.game = function(board, a, h)
  local GF = require("conjunction.game_functions")
  local n = 0
  for f, info in pairs(GF.functions()) do
    local ok = true
    for _, prm in ipairs(info.params or {}) do if not GF.kind(prm[2]) then ok = false end end
    if ok and info.latent then
      for _, prm in ipairs(info.params or {}) do if GF.kind(prm[2]) == "enum" then ok = false end end
    end
    if ok then n = n + 1 end
  end
  local fn = P.get(a, "function")
  local pick = stretched(B.line("qb.game_fn." .. idof(a), P.T(fn) and P.str(fn) or "",
                                "Search the game's actions (" .. n .. ")", function(_t) end, {tip = "qb.game_fn"}))
  local v = {B.row({B.field("does"), pick}, false)}
  h[#h + 1] = stretched(W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, v)))
end

-- Journal entry: who, the name the journal calls them, their portrait, main character, the paragraph
ACTION.person = function(board, a, h)
  local img = P.str(P.or_(P.get(a, "image"), "journal_grandma.png"))
  local function words(p) return P.replace(p:sub(#"journal_" + 1, -5), "_", " ") end
  local v = {QC.target_field(board, a, "who", "who", "people")}
  local name = stretched(QC.text_line(board, a, "name", "as the journal calls them"))
  local portrait = B.menu("qb.portrait." .. idof(a), "portrait: " .. words(img), board:portraits(), img,
                          function(k) QC.set_in(board, a, "image", k) end, {tip = "qb.portrait"})
  local main = B.chip("qb.person_main." .. idof(a), "main character", P.T(P.get(a, "main")), function()
    QC.set_in(board, a, "main", (not P.T(P.get(a, "main"))) and true or nil)
  end, {tip = "qb.person_main"})
  v[#v + 1] = B.row({B.field("name"), name, portrait, main}, false)
  v[#v + 1] = QC.text_line(board, a, "text", "what the journal says about them (this paragraph)")
  h[#h + 1] = stretched(W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, v)))
end

-- --- actions (questboard._action_row): one row
ACTION.reward = function(board, a, h)
  for _, spec in ipairs({{"money", " crowns"}, {"xp", " xp"}}) do
    local key = spec[1]
    local sp = B.spin("qb.reward." .. idof(a) .. "." .. key, math.tointeger(tonumber(P.str(P.get(a, key, 0)))) or 0, 0,
                      100000, function(x) QC.set_in(board, a, key, x, false) end)
    h[#h + 1] = B.with_unit(sp, spec[2])
  end
  local listed = P.copy_list(P.list(P.get(a, "items")))
  for k, it in ipairs(listed) do
    local line = QC.item_line(board, Y.map({"item", it}), "item", {ident = idof(a) .. ".items." .. k,
                                                                   on_set = function(ref) board:reward_item(a, k, ref) end})
    line.stretch = 1
    h[#h + 1] = line
  end
  h[#h + 1] = B.button("qb.reward_add." .. idof(a), "+ item", function()
    board:choose_item(function(ref) board:reward_item(a, #listed + 1, ref) end, "Reward item", "Add item")
  end, "plus", {tip = "qb.reward_items"})
  if #listed == 0 then h[#h + 1] = W.stretch(1) end
end

ACTION.note = function(board, a, h)
  local t = B.line("qb.note." .. idof(a), P.str(P.get(a, "text", "")), "New paragraph in the journal", function(t)
    QC.set_in(board, a, "text", PYS.strip(t), false)
  end)
  t.stretch = 1
  h[#h + 1] = t
end

ACTION.hostile = function(board, a, h)
  local tf = QC.target_field(board, a, "target", "who", "people")
  tf.stretch = 1
  h[#h + 1] = tf
  local f = B.chip("qb.friendly." .. idof(a), "Friendly again", P.T(P.get(a, "friendly")), function()
    QC.set_in(board, a, "friendly", (not P.T(P.get(a, "friendly"))) and true or nil)
  end, {tip = "qb.friendly"})
  f.align = "top"
  h[#h + 1] = f
end

local function pick_list(pairs_, key3)
  local out = {}
  for _, p in ipairs(pairs_) do out[#out + 1] = {p[1], p[2]} end
  return out
end

ACTION.show = function(board, a, h, kind)
  local names = Y.keys(board.ed.project.places)
  require("conjunction.pysort").sort(names)
  for _, name in ipairs(names) do
    h[#h + 1] = B.chip("qb.place." .. idof(a) .. "." .. name, name, P.get(a, "place") == name,
                       function() board:set_place_action(a, kind or "show", name) end, {tip = "qb.place"})
  end
  h[#h + 1] = W.stretch(1)
end
ACTION.hide = function(board, a, h) ACTION.show(board, a, h, "hide") end

ACTION.item = function(board, a, h)
  h[#h + 1] = B.menu("qb.item_way." .. idof(a), P.T(P.get(a, "take")) and "The player loses" or "The player gets",
                     {{false, "The player gets"}, {true, "The player loses"}}, P.T(P.get(a, "take")),
                     function(k) QC.set_in(board, a, "take", k or nil) end, {tip = "qb.item_way"})
  h[#h + 1] = stretched(QC.item_line(board, a))
  h[#h + 1] = QC.spin(board, a, "count", 1, 999, "x", 1)
end

ACTION.lock = function(board, a, h)
  local v = {QC.target_field(board, a, "target", "what", "things")}
  local locked = P.get(a, "state", "lock") == "lock"
  local how = B.menu("qb.lock_state." .. idof(a), locked and "Locks it" or "Unlocks it",
                     {{"lock", "Locks it"}, {"unlock", "Unlocks it"}}, P.get(a, "state", "lock"),
                     function(k) QC.set_in(board, a, "state", k) end, {tip = "qb.lock_state"})
  if locked then
    local key = stretched(QC.item_line(board, a, "key", {placeholder = "Key item (none: nothing opens it)"}))
    local goes = B.check("qb.lock_goes." .. idof(a), "The key is used up", P.T(P.get(a, "key_goes")), function(on)
      QC.set_in(board, a, "key_goes", on and true or nil, false)
    end, {tip = "qb.lock_key_goes"})
    v[#v + 1] = B.row({how, B.field("key"), key, goes}, false)
  else
    v[#v + 1] = B.row({how, B.gap()})
  end
  h[#h + 1] = stretched(W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, v)))
end

-- the lights of the world near the step's light (a room's candles at once): within QC.NEAR_LIGHTS m of it, the
-- ones not taken yet -> how many came
QC.NEAR_LIGHTS = 4
function QC.lights_near(board, a)
  local WP = require("conjunction.world_pick")
  local o = WP.get(board.ed.project, P.str(a.target))
  if not (o and o.pos) then return 0 end
  local at = {tonumber(o.pos[1]), tonumber(o.pos[2]), tonumber(o.pos[3])}
  local have = {[P.str(a.target)] = true}
  for _, t in ipairs(P.list(P.get(a, "more_targets"))) do have[P.str(t)] = true end
  local n = 0
  for _, c in ipairs(WP.scan(at, "light")) do
    local d = math.sqrt((c.pos[1] - at[1]) ^ 2 + (c.pos[2] - at[2]) ^ 2 + (c.pos[3] - at[3]) ^ 2)
    if d <= QC.NEAR_LIGHTS then
      local ref = WP.keep(board.ed.project, c, P.get(o, "world"))
      if not have[ref] then
        have[ref] = true
        if P.get(a, "more_targets") == nil then a.more_targets = Y.list({}) end
        a.more_targets[#a.more_targets + 1] = ref
        n = n + 1
      end
    end
  end
  if n > 0 then
    board.ed.project:save_meta()
    board:save()
  end
  return n
end

-- the same action on more things (questboard._more_targets)
function QC.more_targets(board, v, a, what, world)
  if not P.T(P.get(a, "target")) then return end
  local more = P.list(P.get(a, "more_targets"))
  for k, t in ipairs(more) do
    local trash = B.icon("qb.more_x." .. idof(a) .. "." .. k, "trash-2", function()
      table.remove(a.more_targets, k)
      if #a.more_targets == 0 then Y.remove(a, "more_targets") end
      board:save()
    end, {tip = "qb.remove_action"})
    v[#v + 1] = QC.target_field(board, Y.map({"target", t}), "target", "and", what, {
      ident = idof(a) .. ".more_targets." .. k, trash = trash, world = world,   -- (things of the world too, 12.11.)
      on_set = function(ref)
        if P.get(a, "more_targets") == nil then a.more_targets = Y.list({}) end
        if k <= #a.more_targets then a.more_targets[k] = ref else a.more_targets[#a.more_targets + 1] = ref end
        board:save()
      end})
  end
  v[#v + 1] = B.row({B.button("qb.more_targets." .. idof(a), "+ another", function()
    board.open_picker = nil
    if P.get(a, "more_targets") == nil then a.more_targets = Y.list({}) end
    a.more_targets[#a.more_targets + 1] = ""
    board:save()
  end, "plus", {tip = "qb.more_targets"}), B.gap()})
end

local function state_menu(board, a, key, pairs_, default, tipk)
  local cur = P.get(a, key, default)
  return top(B.menu("qb." .. key .. "." .. idof(a), QBD.label_in(pairs_, cur, P.str(cur)), pairs_, cur,
                    function(k) QC.set_in(board, a, key, k) end, {tip = tipk}))
end
for _, kind in ipairs({"immortal", "door", "switch", "effect", "lights", "presence", "clue", "part", "thinglook",
                         "thinganim"}) do
  ACTION[kind] = function(board, a, h)
    local what = kind == "immortal" and "people" or "things"
    local WP = require("conjunction.world_pick")
    local world = WP.FOR_ACTION[kind]
    local tv
    local refs = board.target_refs(a)
    if world and #refs > 0 then
      -- (chosen already: one line and Select - the list, the picking, the test in the selection at the right;
      -- MaximdeWinter 12.11.)
      local text = WP.label(board.ed.project, refs[1]) or (refs[1]:match("/(.+)$") or refs[1])
      if #refs > 1 then text = string.format("%d %s", #refs, WP.noun(world, true)) end
      tv = {B.row({B.field(text), B.gap(), B.button("qb.select_targets." .. idof(a), "Select", function()
        board:edit_targets(a, what, idof(a), world)
      end, "small", {tip = "qb.select_targets"})})}
    else
      tv = {QC.target_field(board, a, "target", kind == "immortal" and "who" or "what", what,
                            {world = world, many = true})}
      QC.more_targets(board, tv, a, what, world)
    end
    if kind == "lights" and require("conjunction.world_pick").is_ref(P.str(P.get(a, "target") or "")) then
      tv[#tv + 1] = B.row({B.button("qb.lights_near." .. idof(a), "+ the lights near it", function()
        QC.lights_near(board, a)
      end, "plus", {tip = "qb.lights_near"}), B.gap()})
    end
    h[#h + 1] = stretched(W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, tv)))
    if kind == "lights" then
      h[#h + 1] = state_menu(board, a, "state", QBD.LIGHTS, "on", "qb.lights_state")
      local flame = false                         -- (a flame goes out at once only: no "slowly" then)
      for _, ref in ipairs(board.target_refs(a)) do
        if require("conjunction.world_pick").has_flame(board.ed.project, {ref = ref}) then flame = true end
      end
      if not flame then
        h[#h + 1] = top(B.chip("qb.lights_slow." .. idof(a), "slowly", P.T(P.get(a, "slow")), function()
          QC.set_in(board, a, "slow", (not P.T(P.get(a, "slow"))) and true or nil)
        end, {tip = "qb.lights_slow"}))
      end
    elseif kind == "presence" then
      h[#h + 1] = state_menu(board, a, "state", QBD.PRESENCE, "hide", "qb.presence_state")
    elseif kind == "immortal" then
      h[#h + 1] = state_menu(board, a, "mode", QBD.IMMORTAL, "immortal", "qb.immortal_mode")
    elseif kind == "switch" then
      h[#h + 1] = state_menu(board, a, "state", QBD.SWITCH, "on", "qb.switch_state")
    elseif kind == "clue" or kind == "part" then
      if kind == "part" then
        h[#h + 1] = top(QC.text_line(board, a, "part", "which part",
                                     {names = board:world_names(P.get(a, "target"), "parts")}))
      end
      h[#h + 1] = state_menu(board, a, "state", QBD.LIGHTS, "on", "qb.lights_state")
    elseif kind == "thinganim" then
      h[#h + 1] = top(QC.text_line(board, a, "anim", "which move",
                                   {names = board:world_names(P.get(a, "target"), "anims")}))
      h[#h + 1] = state_menu(board, a, "how", QBD.THING_ANIM, "once", "qb.thinganim_how")
    elseif kind == "thinglook" then
      h[#h + 1] = top(QC.text_line(board, a, "look", "which look",
                                   {names = board:world_names(P.get(a, "target"), "looks")}))
    elseif kind == "door" then
      h[#h + 1] = state_menu(board, a, "state", QBD.DOOR, "open", "qb.door_state")
      if P.get(a, "state") == "lock" then
        local key = QC.item_line(board, a, "key", {placeholder = "Key item"})
        h[#h + 1] = top(key)
      end
    else
      h[#h + 1] = top(QC.text_line(board, a, "effect", "effect name",
                                   {names = board:effect_names(P.get(a, "target"))}))
    end
  end
end

ACTION.worldchange = function(board, a, h)
  local WC = require("conjunction.worldchanges")
  local opts = {}
  local ok, changes = pcall(WC.load, board.ed.project.path)
  for _, c in ipairs(ok and changes or {}) do
    opts[#opts + 1] = {P.str(c.id), P.str(P.or_(P.get(c, "label"), "object")) .. ": " .. P.str(c["do"]) ..
                       (P.T(P.get(c, "value")) and (" " .. P.str(c.value)) or "")}
  end
  if #opts > 0 then
    local cur = P.str(P.or_(P.get(a, "change"), ""))
    h[#h + 1] = stretched(B.menu("qb.worldchange." .. idof(a), QBD.label_in(opts, cur, "which change?"), opts, cur,
                                 function(k) QC.set_in(board, a, "change", math.tointeger(tonumber(k))) end,
                                 {tip = "qb.worldchange"}))
    h[#h + 1] = state_menu(board, a, "state", QBD.WORLDCHANGE, "on", "qb.worldchange_state")
  else
    h[#h + 1] = stretched(B.field("No world changes yet"))
  end
end

ACTION.sound = function(board, a, h) h[#h + 1] = stretched(QC.text_line(board, a, "event", "sound event")) end

-- a point picked in the world (questboard._point_button)
function QC.point_button(board, a, key, label, tipk)
  local pos = P.get(a, key)
  local waiting = waiting_for(board, a, key)
  local text = waiting and "Click in the world. Esc cancels" or
               (P.T(pos) and string.format("%s: %.0f, %.0f, %.0f", label, NUMF(pos[1]), NUMF(pos[2]), NUMF(pos[3])) or
                (label .. ": pick a point"))
  return B.button("qb.point." .. idof(a) .. "." .. key, text, function() board:request_point(a, key) end,
                  P.T(pos) and "target" or "target_empty", {tip = tipk or "qb.portal_point"})
end

ACTION.encounters = function(board, a, h)
  h[#h + 1] = state_menu(board, a, "state", QBD.ENCOUNTERS, "off", "qb.encounters_state")
  h[#h + 1] = top(QC.point_button(board, a, "pos", "around", "qb.encounters_point"))
  h[#h + 1] = top(QC.spin(board, a, "radius", 10, 500, " m", 60))
  h[#h + 1] = W.stretch(1)
end

ACTION.fade = function(board, a, h)
  local to = P.get(a, "to", "black")
  h[#h + 1] = B.menu("qb.fade." .. idof(a), to == "black" and "To black" or "Back in",
                     {{"black", "To black"}, {"in", "Back in"}}, to, function(k) QC.set_in(board, a, "to", k) end,
                     {tip = "qb.fade"})
  if to == "black" then
    local c = P.get(a, "color", "black")
    h[#h + 1] = B.menu("qb.fade_color." .. idof(a), QBD.label_in(QBD.FADE_COLORS, c, P.str(c)), QBD.FADE_COLORS, c,
                       function(k) QC.set_in(board, a, "color", k) end, {tip = "qb.fade_color"})
  end
  h[#h + 1] = QC.spin(board, a, "seconds", 0, 30, " s", 1)
  h[#h + 1] = W.stretch(1)
end

ACTION.shake = function(board, a, h)
  h[#h + 1] = QC.spin(board, a, "strength", 1, 100, " %", 50, 100)
  h[#h + 1] = W.stretch(1)
end

QC.WEAPONS = {{"steel", "steel sword"}, {"silver", "silver sword"}, {"fists", "fists"}, {"none", "sheathed"}}
ACTION.weapon = function(board, a, h)
  local cur = P.or_(P.get(a, "weapon"), "steel")
  h[#h + 1] = B.menu("qb.weapon." .. idof(a), QBD.label_in(QC.WEAPONS, cur, P.str(cur)), QC.WEAPONS, cur,
                     function(k) QC.set_in(board, a, "weapon", k) end, {tip = "qb.weapon"})
  h[#h + 1] = W.stretch(1)
end

QC.CONTROLS = {{"all", "everything"}, {"fastTravel", "fast travel"}, {"meditation", "meditation"},
               {"callHorse", "calling the horse"}, {"mount", "riding"}, {"runAndSprint", "running"},
               {"drawWeapon", "drawing weapons"}, {"signs", "signs"}, {"openMap", "the map"},
               {"openInventory", "the inventory"}, {"interactions", "interacting"}}
ACTION.controls = function(board, a, h)
  h[#h + 1] = B.chip("qb.controls_how." .. idof(a), P.T(P.get(a, "unlock")) and "unblock" or "block", true, function()
    QC.set_in(board, a, "unlock", (not P.T(P.get(a, "unlock"))) and true or nil)
  end, {tip = "qb.controls_how"})
  local what = P.copy_list(P.or_(P.get(a, "what"), {"all"}))
  for _, c in ipairs(QC.CONTROLS) do
    local k = c[1]
    h[#h + 1] = B.chip("qb.controls." .. idof(a) .. "." .. k, c[2], P.contains(what, k), function()
      local cur = P.copy_list(P.or_(P.get(a, "what"), {"all"}))
      local now = {}
      if P.contains(cur, k) then
        for _, x in ipairs(cur) do if x ~= k then now[#now + 1] = x end end
      else
        for _, x in ipairs(P.copy_list(P.list(P.get(a, "what")))) do if x ~= "all" then now[#now + 1] = x end end
        now[#now + 1] = k
      end
      QC.set_in(board, a, "what", #now > 0 and Y.list(now) or Y.list({"all"}))
    end, {tip = "qb.controls_what"})
  end
  h[#h + 1] = W.stretch(1)
end

QC.LAPSES = {{"cinematic_text_some_time_later", "Some time later"}, {"cinematic_text_few_hours_later", "A few hours later"},
             {"cinematic_text_while_later", "A while later"}, {"cinematic_text_day_later", "A day later"}}
ACTION.timelapse = function(board, a, h)
  local cur = P.or_(P.get(a, "text"), QC.LAPSES[1][1])
  h[#h + 1] = B.menu("qb.timelapse." .. idof(a), QBD.label_in(QC.LAPSES, cur, P.str(cur)), QC.LAPSES, cur,
                     function(k) QC.set_in(board, a, "text", k) end, {tip = "qb.timelapse"})
  h[#h + 1] = QC.spin(board, a, "seconds", 1, 30, " s", 5)
  h[#h + 1] = W.stretch(1)
end

QC.HIGHLIGHTS = {{"clue", "as a clue (red)"}, {"interactive", "as something to use (yellow)"}, {"none", "not"}}
ACTION.highlight = function(board, a, h)
  h[#h + 1] = stretched(QC.target_field(board, a, "target", "what", "things"))
  local cur = P.or_(P.get(a, "how"), "clue")
  h[#h + 1] = B.menu("qb.highlight." .. idof(a), QBD.label_in(QC.HIGHLIGHTS, cur, P.str(cur)), QC.HIGHLIGHTS, cur,
                     function(k) QC.set_in(board, a, "how", k) end, {tip = "qb.highlight"})
end

ACTION.weather = function(board, a, h)
  local w = P.str(P.get(a, "weather", "WT_Clear"))
  local entries = {}
  for _, x in ipairs(QBD.WEATHERS) do entries[#entries + 1] = {x, P.replace(x:sub(4), "_", " ")} end
  h[#h + 1] = B.menu("qb.weather." .. idof(a), P.replace(w:sub(4), "_", " "), entries, w,
                     function(k) QC.set_in(board, a, "weather", k) end, {tip = "qb.weather"})
  h[#h + 1] = QC.spin(board, a, "seconds", 0, 120, " s blend", 10)
  h[#h + 1] = W.stretch(1)
end

ACTION.time = function(board, a, h)
  h[#h + 1] = B.line("qb.time_at." .. idof(a), P.str(P.get(a, "at", "12:00")), "", function(t)
    QC.set_in(board, a, "at", t, false)
  end, {tip = "qb.time_at", mask = "99:99"})
  h[#h + 1] = W.stretch(1)
end

local function pick_point_button(board, a, tipk, text)
  local waiting = waiting_for(board, a, "pos")
  return B.button("qb.pick_pos." .. idof(a), waiting and "Click in the world. Esc cancels" or (text or "Pick a point"),
                  function() board:request_point(a, "pos") end, "small", {tip = tipk})
end

ACTION.travel = function(board, a, h)
  local pos = P.get(a, "pos")
  h[#h + 1] = B.field(P.T(pos) and string.format("%s: %.0f, %.0f", P.str(P.get(a, "world", "?")), NUMF(pos[1]),
                                                   NUMF(pos[2])) or "Location not set")
  h[#h + 1] = pick_point_button(board, a, "qb.travel_here")
  h[#h + 1] = W.stretch(1)
end

ACTION.teleport = function(board, a, h)
  local pos = P.get(a, "pos")
  h[#h + 1] = B.field(P.T(pos) and string.format("%.0f, %.0f, %.0f", NUMF(pos[1]), NUMF(pos[2]), NUMF(pos[3])) or
                      "Location not set")
  h[#h + 1] = pick_point_button(board, a, "qb.teleport_here")
  h[#h + 1] = W.stretch(1)
end

ACTION.playas = function(board, a, h)
  local DL = require("conjunction.dialogue")
  local who = P.get(a, "as")
  local entries = {}
  for k, p in pairs(DL.PLAYERS) do entries[#entries + 1] = {k, p.label} end
  local pl = who and P.get(DL.PLAYERS, who)
  h[#h + 1] = top(B.menu("qb.playas." .. idof(a), pl and pl.label or "who", entries, who,
                         function(k) QC.set_in(board, a, "as", k) end, {tip = "qb.playas_who"}))
  if who == "ciri" then
    local look = P.or_(P.get(a, "look"), "")
    h[#h + 1] = top(B.menu("qb.playas_look." .. idof(a), QBD.label_in(QBD.CIRI_LOOKS, look, look), QBD.CIRI_LOOKS, look,
                           function(k) QC.set_in(board, a, "look", P.T(k) and k or nil) end, {tip = "qb.playas_look"}))
  end
  local pos = P.get(a, "pos")
  h[#h + 1] = B.field(P.T(pos) and string.format("at %.0f, %.0f", NUMF(pos[1]), NUMF(pos[2])) or "where they are")
  h[#h + 1] = pick_point_button(board, a, "qb.playas_at")
  if P.T(pos) then
    h[#h + 1] = B.icon("qb.playas_x." .. idof(a), "x", function() QC.set_in(board, a, "pos", nil) end,
                       {tip = "qb.playas_here"})
  end
  h[#h + 1] = W.stretch(1)
end

ACTION.walk = function(board, a, h, kind)
  kind = kind or "walk"
  local v = {QC.target_field(board, a, "who", "who", "people")}
  local run = P.T(P.get(a, "run"))
  local pace = B.menu("qb.walk_run." .. idof(a), run and "runs" or "walks", {{false, "walks"}, {true, "runs"}}, run,
                      function(k) QC.set_in(board, a, "run", k or nil) end, {tip = "qb.follow_run"})
  if kind == "walk" then
    local pos = P.get(a, "pos")
    local waiting = waiting_for(board, a, "pos")
    local where = B.button("qb.walk_to." .. idof(a), waiting and "Click in the world. Esc cancels" or
                           (P.T(pos) and string.format("to %.0f, %.0f", NUMF(pos[1]), NUMF(pos[2])) or "Pick a point"),
                           function() board:request_point(a, "pos") end, "small", {tip = "qb.walk_to"})
    local wait = B.menu("qb.walk_wait." .. idof(a), P.T(P.get(a, "wait")) and "Quest waits" or "Quest continues",
                        {{false, "Quest continues"}, {true, "Quest waits"}}, P.T(P.get(a, "wait")),
                        function(k) QC.set_in(board, a, "wait", k or nil) end, {tip = "qb.walk_wait"})
    v[#v + 1] = B.row({where, pace, wait, B.gap()})
  else
    v[#v + 1] = QC.path_field(board, a)
    v[#v + 1] = B.row({pace, B.gap()})
  end
  h[#h + 1] = stretched(W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, v)))
end
ACTION.patrol = function(board, a, h) ACTION.walk(board, a, h, "patrol") end

ACTION.tutorial = function(board, a, h)
  local title = stretched(QC.text_line(board, a, "title", "title", {tip = "qb.tut_title"}))
  local text = QC.text_line(board, a, "text", "text - <<Focus>>, <<Jump>> ... show the key", {tip = "qb.tut_text"})
  local v = {B.row({title, QC.spin(board, a, "seconds", 2, 60, " s", 8)}, false), text}
  h[#h + 1] = stretched(W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, v)))
end

ACTION.meanwhile = function(board, a, h)
  local t = B.line("qb.meanwhile." .. idof(a), P.str(P.or_(P.get(a, "path"), "")), "Track name", function(x)
    local name = QN.safe(PYS.strip(x))
    QC.set_in(board, a, "path", name ~= "" and name or nil)
  end, {tip = "qb.meanwhile"})
  h[#h + 1] = stretched(B.row({B.field("lane"), t, B.gap()}))
end

ACTION.stop = function(board, a, h)
  local q = board:graph_quest()
  local lanes, seen = {}, {}
  for _, nid in ipairs(QN.order(q)) do
    local k, x = QN.step_kind(q.nodes[nid].step)
    if k == "meanwhile" and P.T(P.get(x, "path")) and not seen[x.path] then
      seen[x.path] = true
      lanes[#lanes + 1] = {x.path, P.str(QN.label_of(q, x.path))}
    end
  end
  local cur = P.get(a, "path")
  local b = B.menu("qb.stop_lane." .. idof(a), QBD.label_in(lanes, cur, "Track not set"), lanes, cur,
                   function(k) QC.set_in(board, a, "path", k) end, {tip = "qb.stop_lane", dashed = not P.T(cur)})
  h[#h + 1] = stretched(B.row({B.field("stops"), b, B.gap()}))
end

ACTION.random = function(board, a, h, word, add_tip)
  word = word or "outcome"
  if P.get(a, "ways") == nil then a.ways = Y.list({Y.map(), Y.map()}) end
  local ways = a.ways
  local v = {}
  for k = 1, #ways do
    local row = {B.field(word .. " " .. k .. (word == "outcome" and (": 1 in " .. #ways) or ""))}
    if #ways > 2 then
      row[#row + 1] = B.icon("qb.random_x." .. idof(a) .. "." .. k, "trash-2", function()
        table.remove(ways, k)
        board:save()
      end, {tip = "qb.random_remove"})
    end
    row[#row + 1] = B.gap()
    v[#v + 1] = B.row(row)
  end
  v[#v + 1] = B.row({B.button("qb.random_add." .. idof(a), "+ " .. word, function()
    ways[#ways + 1] = Y.map()
    board:save()
  end, "plus", {tip = add_tip or "qb.random_add"}), B.gap()})
  h[#h + 1] = stretched(W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, v)))
end

ACTION.message = function(board, a, h) h[#h + 1] = stretched(QC.text_line(board, a, "text", "shown on the screen")) end
ACTION.autosave = function(board, a, h) h[#h + 1] = W.stretch(1) end

ACTION.forget = function(board, a, h)
  h[#h + 1] = stretched(B.line("qb.forget." .. idof(a), P.str(P.get(a, "name", "")), "Fact name", function(t)
    QC.set_in(board, a, "name", require("conjunction.project").fact_id(t), false)
  end, {tip = "qb.forget"}))
end

local function chip_of(board, a, key, text, tipk)
  return B.chip("qb." .. key .. "." .. idof(a), text, P.T(P.get(a, key)), function()
    QC.set_in(board, a, key, (not P.T(P.get(a, key))) and true or nil)
  end, {tip = tipk})
end

ACTION.containers = function(board, a, h)
  h[#h + 1] = stretched(QC.target_field(board, a, "target", "what", "things"))
  h[#h + 1] = chip_of(board, a, "off", "closed", "qb.containers_off")
end

ACTION.questitem = function(board, a, h)
  h[#h + 1] = stretched(QC.item_line(board, a))
  h[#h + 1] = chip_of(board, a, "again", "a quest item again", "qb.questitem_again")
end

ACTION.mappin = function(board, a, h)
  local QS = require("conjunction.quest")
  h[#h + 1] = stretched(QC.target_field(board, a, "target", "what", "things"))
  local states = {}
  for _, s in ipairs(QS.PIN_STATES) do states[#states + 1] = {s[1], s[2]} end
  local cur = P.or_(P.get(a, "state"), "discovered")
  h[#h + 1] = B.menu("qb.mappin." .. idof(a), QBD.label_in(states, cur, P.str(cur)), states, cur,
                     function(k) QC.set_in(board, a, "state", k) end, {tip = "qb.mappin"})
end

ACTION.fact = function(board, a, h)
  local n = stretched(B.line("qb.fact_name." .. idof(a), P.str(P.get(a, "name", "")), "Fact name", function(t)
    QC.set_in(board, a, "name", require("conjunction.project").fact_id(t), false)
  end))
  h[#h + 1] = n
  h[#h + 1] = B.spin("qb.fact_value." .. idof(a), math.tointeger(tonumber(P.str(P.get(a, "value", 1)))) or 1, -1000, 1000,
                     function(x) QC.set_in(board, a, "value", x, false) end)
end

-- the actions about one person (questboard._person_action)
local function person_action(board, a, h, kind)
  local player_too = kind == "health" or kind == "look"
  h[#h + 1] = stretched(QC.target_field(board, a, "who", "who" .. (player_too and " (empty: Geralt)" or ""), "people"))
  local function toggle_chip(key, text, tipk)
    return B.chip("qb." .. key .. "." .. idof(a), text, P.T(P.get(a, key)), function()
      QC.set_in(board, a, key, (not P.T(P.get(a, key))) and true or nil)
    end, {tip = tipk})
  end
  if kind == "health" then
    h[#h + 1] = QC.spin(board, a, "percent", 1, 100, " %", 100)
  elseif kind == "target" then
    h[#h + 1] = stretched(QC.target_field(board, a, "at", "attacks (empty: Geralt)", "people"))
    h[#h + 1] = toggle_chip("stop", "stops", "qb.target_stop")
  elseif kind == "notalk" then
    h[#h + 1] = toggle_chip("again", "talks again", "qb.notalk_again")
  elseif kind == "look" then
    h[#h + 1] = stretched(B.line("qb.look." .. idof(a), P.str(P.or_(P.get(a, "appearance"), "")), "Appearance name",
                                 function(t) QC.set_in(board, a, "appearance", P.T(PYS.strip(t)) and PYS.strip(t) or nil) end,
                                 {tip = "qb.look_name"}))
  elseif kind == "state" then
    local QS = require("conjunction.quest")
    local states = {}
    for _, s in ipairs(QS.NPC_STATES) do states[#states + 1] = {s[1], s[2]} end
    local cur = P.or_(P.get(a, "state"), "unconscious")
    h[#h + 1] = B.menu("qb.state." .. idof(a), QBD.label_in(states, cur, P.str(cur)), states, cur,
                       function(k) QC.set_in(board, a, "state", k) end, {tip = "qb.state"})
  elseif kind == "shop" or kind == "bossbar" then
    h[#h + 1] = toggle_chip("off", "off", kind == "shop" and "qb.shop_off" or "qb.bossbar_off")
  end
end
for _, k in ipairs(QBD.PERSON_ACTIONS) do ACTION[k] = function(board, a, h) person_action(board, a, h, k) end end

function QC.action_row(board, steps, i, alone)
  local kind, a = QBD.step_kind(steps[i])
  local h = {}
  if not alone then
    local kl = B.field(QBD.LABEL[kind] or kind)
    kl.o.fixed_w = 84
    kl.align = "top"
    h[#h + 1] = kl
  end
  local f = ACTION[kind]
  if f then f(board, a, h) end
  return W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, h))
end

-- --- If and Wait until's conditions
local OPS = {{"=", "="}, {"!=", "!="}, {">=", ">="}, {">", ">"}, {"<=", "<="}, {"<", "<"}}

local function fact_value_row(board, c, store)
  local name = stretched(B.line("qb.if_fact." .. idof(c), P.str(P.or_(P.get(c, "fact"), "")), "Fact name", function(t)
    store(require("conjunction.project").fact_id(t))
  end, {tip = "qb.if_fact"}))
  local op = B.menu("qb.if_op." .. idof(c), P.str(P.or_(P.get(c, "op"), ">=")), OPS, P.or_(P.get(c, "op"), ">="),
                    function(o) QC.set_in(board, c, "op", o) end, {tip = "qb.if_op"})
  local val = B.spin("qb.if_value." .. idof(c), math.tointeger(tonumber(P.str(P.get(c, "value", 1)))) or 1, -1000, 1000,
                     function(x) QC.set_in(board, c, "value", x) end, {tip = "qb.if_value"})
  return name, op, val
end

-- the fields of one condition (questboard._condition_fields)
function QC.condition_fields(board, c, kind)
  if kind == "fact" then
    local name, op, val = fact_value_row(board, c, function(f) QC.set_in(board, c, "fact", P.T(f) and f or nil) end)
    return B.row({name, op, val}, false)
  end
  if kind == "path" then
    local cur = P.get(c, "path")
    return B.row({B.menu("qb.cond_path." .. idof(c), P.T(cur) and ("'" .. P.str(cur) .. "' was taken") or "Which branch",
                         {}, cur, function(pid) QC.set_in(board, c, "path", pid) end, {tip = "qb.if_path"}), B.gap()})
  end
  if kind == "area" then
    return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, {
      QC.place_field(board, c),
      B.row({B.field("within"), QC.spin(board, c, "radius", 1, 200, " m", 10), B.gap()})}))
  end
  if kind == "item" then
    return B.row({B.field("has"), QC.spin(board, c, "count", 1, 999, "", 1), QC.item_line(board, c)})
  end
  if kind == "quest" then
    local q = P.or_(P.get(c, "quest"), Y.map())
    local line = stretched(B.line("qb.cond_quest." .. idof(c), P.str(P.or_(P.get(q, "label"), "")),
                                  "A quest or objective of the game...", function(_t) end, {tip = "qb.cond_quest"}))
    local QS = require("conjunction.quest")
    local states = {}
    for _, s in ipairs(QS.QUEST_STATES) do states[#states + 1] = {s[1], s[2]} end
    local cur = P.or_(P.get(c, "state"), "done")
    local state = B.menu("qb.cond_state." .. idof(c), QBD.label_in(states, cur, cur), states, cur,
                         function(k) QC.set_in(board, c, "state", k) end, {tip = "qb.cond_state"})
    return B.row({line, state}, false)
  end
  if kind == "time" then
    local function t(key, default)
      return B.line("qb.cond_time." .. idof(c) .. "." .. key, P.str(P.or_(P.get(c, key), default)), "", function(x)
        QC.set_in(board, c, key, x, false)
      end, {tip = "qb.cond_time", fixed_w = 60, mask = "99:99"})
    end
    return B.row({B.field("from"), t("from", "20:00"), B.field("to"), t("to", "06:00"), B.gap()})
  end
  if kind == "present" then return QC.target_field(board, c, "who", "who", "people") end
  local QS = require("conjunction.quest")
  local function pairs_of(tbl)
    local out = {}
    for _, s in ipairs(tbl) do out[#out + 1] = {s[1], s[2]} end
    return out
  end
  if kind == "near" or kind == "health" or kind == "alive" or kind == "state" or kind == "gone" then
    local player_too = kind == "near" or kind == "health" or kind == "state"
    local who = QC.target_field(board, c, "who", "who" .. (player_too and " (empty: player)" or ""), "people")
    if kind == "near" then
      local far = P.T(P.get(c, "farther"))
      local how = B.menu("qb.cond_near_far." .. idof(c), far and "farther than" or "within",
                         {{false, "within"}, {true, "farther than"}}, far,
                         function(k) QC.set_in(board, c, "farther", k or nil) end, {tip = "qb.cond_near_far"})
      return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 3}, {
        who, B.row({how, QC.spin(board, c, "metres", 1, 500, " m", 5), B.field("of")}, false),
        QC.target_field(board, c, "to", "of whom (empty: player)", "people")}))
    end
    if kind == "health" then return B.row({who, QC.spin(board, c, "percent", 1, 99, " %", 20)}, false) end
    if kind == "state" then
      local cur = P.or_(P.get(c, "state"), "combat")
      local states = pairs_of(QS.PERSON_STATES)
      return B.row({who, B.menu("qb.cond_pstate." .. idof(c), QBD.label_in(states, cur, P.str(cur)), states, cur,
                                function(k) QC.set_in(board, c, "state", k) end, {tip = "qb.cond_state"})}, false)
    end
    return who
  end
  if kind == "riding" then
    local cur = P.or_(P.get(c, "on"), "horse")
    local rides = pairs_of(QS.RIDES)
    return B.row({B.menu("qb.cond_riding." .. idof(c), QBD.label_in(rides, cur, P.str(cur)), rides, cur,
                         function(k) QC.set_in(board, c, "on", k) end, {tip = "qb.cond_riding"}), B.gap()})
  end
  if kind == "doing" then
    local cur = P.or_(P.get(c, "does"), "swimming")
    local does = pairs_of(QS.PLAYER_DOES)
    return B.row({B.menu("qb.cond_doing." .. idof(c), QBD.label_in(does, cur, P.str(cur)), does, cur,
                         function(k) QC.set_in(board, c, "does", k) end, {tip = "qb.cond_doing"}), B.gap()})
  end
  return B.field(kind == "combat" and "the player is in a fight" or "")
end

-- the list of conditions (questboard._conditions_editor)
function QC.conditions_editor(board, a, waiting)
  local QS = require("conjunction.quest")
  local v = {}
  local conds = P.list(P.get(a, "conditions"))
  local kinds = {}
  for _, k in ipairs(QS.COND_KINDS) do
    if not waiting or k[1] ~= "item" then kinds[#kinds + 1] = {k[1], k[2]} end
  end
  if #conds > 1 then
    v[#v + 1] = B.row({B.chip("qb.cond_all." .. idof(a), "all of these", not P.T(P.get(a, "any")),
                              function() QC.set_in(board, a, "any", nil) end, {tip = "qb.cond_all"}),
                       B.chip("qb.cond_any." .. idof(a), "one of them", P.T(P.get(a, "any")),
                              function() QC.set_in(board, a, "any", true) end, {tip = "qb.cond_any"}), B.gap()})
  end
  for k, c in ipairs(conds) do
    local kind = QS.cond_kind(c)
    local gap = B.gap()
    gap.stretch = 1
    local head = W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, {
      B.menu("qb.cond_kind." .. idof(c), QBD.label_in(kinds, kind, kind), kinds, kind, function(new)
        local keep = P.T(P.get(c, "not"))
        for _, key in ipairs(Y.keys(c)) do Y.remove(c, key) end
        if keep then c["not"] = true end
        c.kind = new
        board:save()
      end, {tip = "qb.cond_kind"}),
      B.chip("qb.cond_not." .. idof(c), "not", P.T(P.get(c, "not")), function()
        QC.set_in(board, c, "not", (not P.T(P.get(c, "not"))) and true or nil)
      end, {tip = "qb.cond_not"}),
      gap,
      B.icon("qb.cond_x." .. idof(c), "trash-2", function()
        table.remove(conds, k)
        board:save()
      end, {tip = "qb.cond_remove"})}))
    v[#v + 1] = head
    v[#v + 1] = QC.condition_fields(board, c, kind)
  end
  v[#v + 1] = B.row({B.button("qb.cond_add." .. idof(a), "+ condition", function()
    conds[#conds + 1] = Y.map({"kind", "fact"})
    if P.get(a, "conditions") == nil then a.conditions = conds end
    board:save()
  end, "small", {tip = "qb.cond_add"}), B.gap()})
  return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 4}, v))
end

-- If: a branch taken or a fact - or the list (questboard._if_editor)
function QC.if_editor(board, a)
  if P.T(P.get(a, "conditions")) then return QC.conditions_editor(board, a) end
  local v = {}
  local how = (P.get(a, "fact") ~= nil and not P.T(P.get(a, "path"))) and "fact" or "path"
  local function by(h)
    if h == "fact" then
      Y.remove(a, "path")
      if P.get(a, "fact") == nil then a.fact = "" end
    else
      for _, key in ipairs({"fact", "op", "value"}) do Y.remove(a, key) end
    end
    board:save()
  end
  v[#v + 1] = B.row({B.chip("qb.if_by_path." .. idof(a), "a branch was taken", how == "path", function() by("path") end,
                            {tip = "qb.if_by_path"}),
                     B.chip("qb.if_by_fact." .. idof(a), "a fact", how == "fact", function() by("fact") end,
                            {tip = "qb.if_by_fact"}), B.gap()})
  if how == "path" then
    local cur = P.get(a, "path")
    v[#v + 1] = B.row({B.field("if"), B.menu("qb.if_path." .. idof(a), P.T(cur) and ("'" .. P.str(cur) .. "' was taken") or
                                             "Branch not set", {}, cur, function(pid)
      Y.remove(a, "fact")
      QC.set_in(board, a, "path", pid)
    end, {tip = "qb.if_path"}), B.gap()})
  else
    local name, op, val = fact_value_row(board, a, function(f)
      a.fact = f
      board:save()
    end)
    v[#v + 1] = B.row({B.field("if"), name, op, val}, false)
  end
  v[#v + 1] = B.row({B.button("qb.cond_add." .. idof(a), "+ condition", function()
    local conds = board:to_conditions(a)
    conds[#conds + 1] = Y.map({"kind", "area"})
    board:save()
  end, "small", {tip = "qb.cond_add"}), B.gap()})
  return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 4}, v))
end

-- a chapter's card: its title, its journal text (questboard._chapter)
function QC.chapter_card(board, steps, i, a)
  local kind = B.label("CHAPTER", 0x9a9aa3ff, 11, true)
  local title = stretched(B.line("qb.chapter_title." .. idof(a), P.str(P.get(a, "title", "")), "Chapter name", function(t)
    QC.set_in(board, a, "title", P.T(PYS.strip(t)) and PYS.strip(t) or nil)
  end, {tip = "qb.chapter_title", style = "chapter"}))
  local menu = B.menu("qb.chapter_menu." .. idof(a), "···", {{"test", "Play from here"}, {"remove", "Remove chapter"}},
                      nil, function(k)
    if k == "remove" then board:remove_step(steps, i) end
  end, {tip = "qb.chapter_menu"})
  local head = W.widget(W.hbox({margins = {4, 8, 4, 4}, spacing = 6}, {kind, title, menu}), {
    draw = function(_, r)
      D.fill(r.x, r.y, r.w, r.h, 0x1b1b1fff)
      D.fill(r.x, r.y + r.h - 2, r.w, 2, 0x6b6b74ff)
      B.bg = 0x1b1b1fff
    end, margins = {0, 0, 0, 2}})
  local j = Y.is_map(P.get(a, "journal")) and a.journal or Y.map()
  local text = B.plain("qb.chapter_journal." .. idof(a), P.str(P.or_(P.get(j, "text"), "")), "Journal text (optional)",
                       54, function(t)
    local jj = Y.map()
    for k2, v2 in pairs(P.or_(P.get(a, "journal"), Y.map())) do jj[k2] = v2 end
    jj.text = PYS.strip(t)
    if P.T(jj.text) then
      if jj.mode == nil then jj.mode = "add" end
      a.journal = jj
    else
      Y.remove(a, "journal")
    end
    board:save(false)
  end, {tip = "qb.chapter_journal"})
  local v = {head, text}
  local modes = {{"add", "Add to journal"}, {"replace", "Replace journal text"}}
  local mode = P.or_(P.get(j, "mode"), "add")
  v[#v + 1] = B.row({B.menu("qb.chapter_mode." .. idof(a), QBD.label_in(modes, mode, mode), modes, mode, function(k)
    if P.get(a, "journal") == nil then a.journal = Y.map() end
    a.journal.mode = k
    board:save()
  end, {tip = "qb.chapter_journal_mode"}), B.gap()})
  return W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 4}, v))
end

-- --- the cards
-- a goal's card (questboard._card)
function QC.goal_card(board, steps, number, i, colour)
  local st = steps[i]
  local kind, a = QBD.step_kind(st)
  local v = {}
  local placeholder = QC.default_text(board, kind, a)
  local text = P.str(P.get(a, "text", ""))
  local disabled = false
  if kind == "talk" and P.get(a, "start") == "now" then
    text, placeholder, disabled = "", "A cutscene (no line in the journal)", true
  end
  local line = B.line("qb.objective." .. idof(a), text, placeholder, function(t)
    QC.set_in(board, a, "text", P.T(PYS.strip(t)) and PYS.strip(t) or nil)
  end, {tip = "qb.objective", disabled = disabled})
  line.stretch = 1
  local head_items = {B.num(number), line, kind_button(board, steps, i)}
  card_tools(board, head_items, steps, i)
  v[#v + 1] = W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, head_items))
  missing_note(v, kind, a)
  local ed = {}
  if GOAL[kind] then GOAL[kind](board, st, a, ed) end
  v[#v + 1] = W.widget(W.vbox({margins = {0, 0, 0, 0}, spacing = 4}, ed))
  if QN.REPEATABLE[kind] and QN.is_graph(board:quest()) then v[#v + 1] = repeat_row(board, st, a) end
  return card_frame(v, colour)
end

-- an action's, a choice's, a lane's, an end's card (questboard._step_card)
function QC.step_card(board, steps, i, colour)
  local kind, a = QBD.step_kind(steps[i])
  local v = {}
  local head_items = {kind_button(board, steps, i), B.gap()}
  head_items[2].stretch = 1
  card_tools(board, head_items, steps, i)
  v[#v + 1] = W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, head_items))
  missing_note(v, kind, a)
  if QG.PLACEHOLDERS[kind] then
    local buttons = {}
    for _, k in ipairs(QG.KINDS_OF[kind]) do
      buttons[#buttons + 1] = B.button("qb.pick_kind." .. idof(steps) .. "." .. k, QG.LABEL[k] or k,
                                       function() board:set_kind(steps, i, k) end, "small", {tip = "step." .. k})
    end
    v[#v + 1] = W.widget(W.flow({spacing = 4}, buttons))
  elseif kind == "end" then
    v[#v + 1] = B.row({B.field("the quest"),
                       B.chip("qb.end_success." .. idof(a), "succeeds", P.get(a, "how") ~= "fail",
                              function() QC.set_in(board, a, "how", nil) end, {tip = "qb.end_success"}),
                       B.chip("qb.end_fail." .. idof(a), "fails", P.get(a, "how") == "fail",
                              function() QC.set_in(board, a, "how", "fail") end, {tip = "qb.end_fail"}),
                       B.gap()})
  elseif kind == "if" then
    v[#v + 1] = QC.if_editor(board, a)
  else
    v[#v + 1] = QC.action_row(board, steps, i, true)
  end
  return card_frame(v, colour)
end

-- the card of the node picked (questboard._graph_card's own part; the start's card is the board's)
function QC.build(board, node)
  if node == nil or node.card == nil or node.card.i == nil then return nil end
  local steps, i = node.card.steps, node.card.i
  local kind = QN.step_kind(steps[i])
  local colour = P.T(node.lane) and node.lane or nil
  if node.kind == "remember" then                 -- (a branch's own node: what it remembers, the trash can)
    local gap = B.gap()
    gap.stretch = 1
    return W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, {
      B.field("Remembers branch: " .. P.str(node.text)), gap,
      B.icon("qb.remember_x." .. node.id, "trash-2", function() board:remove_node(node.id) end, {tip = "qb.remove"})}))
  end
  if kind == "chapter" then return QC.chapter_card(board, steps, i, QBD.step_kind(steps[i]) and select(2, QBD.step_kind(steps[i]))) end
  if not QG.PLACEHOLDERS[kind] and (QG.block_of(kind) == "goal" or kind == "either") then
    return QC.goal_card(board, steps, node.number, i, colour)
  end
  return QC.step_card(board, steps, i, colour)
end

return QC
