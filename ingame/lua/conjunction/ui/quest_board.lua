-- questboard.py's QuestBoard: the Quest tab - the quest's name and its menu, In this quest and Quest graph, the
-- blocks on the left, the graph (ui/graph_view.lua) and under it the card of the node picked (a splitter between).
-- The quest's data as the board keeps it (quest_nodes: nodes and links), every edit saved and the graph built anew.
--
--   local b = QBD.new(panel)       panel: ui/panel.lua (its editor: panel.ed)
--   b:sync()                       the board anew from the project (questboard.sync)
--   b:frame(page)                  the tab's page (screen pixels): layout, drawing, the mouse
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local L = require("conjunction.ui.layout")
local CT = require("conjunction.ui.controls")
local GV = require("conjunction.ui.graph_view")
local QN = require("conjunction.quest_nodes")
local QG = require("conjunction.quest_graph")
local GL = require("conjunction.graph_layout")
local QBD_DATA = require("conjunction.questboard")
local P = require("conjunction.py")
local Y = require("conjunction.yaml")
local D = w3.ui.draw
local QBD = {}
QBD.__index = QBD

local function hex(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
-- questboard.STYLE's colours
QBD.C = {
  field = hex("#999999"),                                              -- QLabel#field
  menu_fg = hex("#dddddd"), menu_bg = hex("#262629"), menu_edge = hex("#555555"), menu_hover = hex("#aaaaaa"),
  chip_fg = hex("#cfcfcf"), chip_on_fg = hex("#ffffff"), chip_on_bg = hex("#4b4b50"), chip_on_edge = hex("#c8c8c8"),
  plus_fg = hex("#9a9a9a"), plus_edge = hex("#444444"), plus_hover_fg = hex("#eeeeee"), plus_hover_edge = hex("#888888"),
  card = hex("#1e1e1e"),                                               -- the card's scroll area: the palette's window
}
local C = QBD.C
local LIST_BG = hex("#1e1e1e")             -- an inline list's body in the panel (panel.C.inline_bg)
QBD.BLOCK_W = 96                                      -- graph_blocks.WIDTH
QBD.BLOCK_COLOUR = {goal = "#5aa9e6", action = QG.FAMILY.action, choice = QG.FAMILY.choice,
                    parallel = QG.FAMILY.lane, chapter = QG.FAMILY.story, ["end"] = QG.SUCCESS,
                    scene = QG.FAMILY.scene}
QBD.HANDLE = 5                                         -- the splitter's handle

function QBD.new(panel)
  local self = setmetatable({panel = panel, ed = panel.ed, graph_node = nil, graph_frac = 0.6, card_scroll = 0,
                             open_picker = nil, more = {}, title_text = nil, desc_text = nil, tiles = {}}, QBD)
  self.graph = GV.new({
    picked = function(nid) self:graph_picked(nid) end,
    opened = function(nid) self:graph_open(nid) end,
    kind_menu = function(nid, x, y) self:graph_kind_menu(nid, x, y) end,
    node_menu = function(nid, x, y) self:graph_node_menu(nid, x, y) end,
    wire_menu = function(link, x, y) self:graph_wire_menu(link, x, y) end,
    place = function(block, drop) self:graph_place(block, drop) end,
    moved = function(nid, x, y) self:graph_moved_node(nid, x, y) end,
    connect = function(a, port, b, beside) self:link(a, port, b, beside) self:save() end,
    relink = function(link, b) self:unlink(link) self:link(link[1], link[2], b, true) self:save() end,
    unlink = function(link) self:unlink(link) self.graph:select_wire(nil) self:save() end,
  })
  return self
end

-- --- the data
function QBD:quest()
  local meta = self.ed.project.meta
  if meta.quest == nil or meta.quest == Y.null then meta.quest = QN.new_quest(P.str(P.get(meta, "name", ""))) end
  return meta.quest
end

function QBD:graph_quest()
  local q = self:quest()
  if not QN.is_graph(q) then
    QN.migrate(q)
    self:save_meta()
  end
  return q
end

function QBD:save_meta()
  local pr = self.ed.project
  if pr.save_meta then pr:save_meta() end
end

-- the outputs a step goes on in the story by (questboard._ons)
function QBD:ons(nid)
  local q = self:graph_quest()
  local out = {}
  for _, pt in ipairs(QN.ports(q.nodes[nid].step, self:quest())) do
    local p = pt[1]
    if p == "next" or p == "continue" or p == "Success" or p == "Failure" or p == "arrived" or p == "yes" or
        p == "no" or (p:sub(1, 1) == "o" and p:sub(2):match("^%d+$")) or p:sub(1, 3) == "way" then
      out[#out + 1] = p
    end
  end
  return out
end

-- a wire from a node's output to a node: instead of where that output led (beside: as well)
function QBD:link(a, port, b, beside)
  local q = self:graph_quest()
  if not beside then
    local keep = Y.list({})
    for _, ln in ipairs(q.links) do if not (ln[1] == a and ln[2] == port) then keep[#keep + 1] = ln end end
    q.links = keep
  end
  for _, ln in ipairs(q.links) do if ln[1] == a and ln[2] == port and ln[3] == b then return end end
  q.links[#q.links + 1] = Y.list({a, port, b})
end

function QBD:unlink(link)
  local q = self:graph_quest()
  local keep = Y.list({})
  for _, ln in ipairs(q.links) do
    if not (ln[1] == link[1] and ln[2] == link[2] and ln[3] == link[3]) then keep[#keep + 1] = ln end
  end
  q.links = keep
end

-- d[key] = value (nil or "": gone), saved (questboard._set_in)
function QBD:set_in(d, key, value, rebuild)
  require("conjunction.ui.quest_card").set_in(self, d, key, value, rebuild)
end

-- a saved change: wires of outputs a step no longer has go; one undo step; the board anew
function QBD:save(rebuild)
  local q = self:quest()
  if QN.is_graph(q) then
    local outs = {}
    for nid, n in pairs(q.nodes) do
      local s = {}
      local others = false
      for _, pt in ipairs(QN.ports(n.step, q)) do
        s[pt[1]] = true
        if pt[1] ~= "next" then others = true end
      end
      outs[nid] = {set = s, others = others}
    end
    local keep = Y.list({})
    for _, ln in ipairs(P.list(P.get(q, "links"))) do
      local o = outs[ln[1]]
      -- (a talk that got a second way out - an answer's own output: its one wire goes on from "continue" now)
      if o and ln[2] == "next" and o.others and o.set.continue then ln[2] = "continue" end
      if o and ln[2] == "continue" and not o.others and o.set.next then ln[2] = "next" end   -- (and back)
      if o and q.nodes[ln[3]] ~= nil and (o.set[ln[2]] or (ln[2] == "next" and not o.others)) then
        keep[#keep + 1] = ln
      end
    end
    q.links = keep
  end
  self:save_meta()
  self:remember()
  self.data_ver = (self.data_ver or 0) + 1      -- (what is kept from it goes: after_entries)
  if rebuild ~= false then self.want_sync = true end
end

local function deepcopy(x)
  if type(x) ~= "table" or x == Y.null then return x end
  local out
  if Y.is_map(x) then
    out = Y.map()
    for k, v in pairs(x) do out[k] = deepcopy(v) end
  elseif Y.is_list(x) then
    out = Y.list({})
    for i, v in ipairs(x) do out[i] = deepcopy(v) end
  else
    out = {}
    for k, v in pairs(x) do out[k] = deepcopy(v) end
  end
  return out
end
QBD.deepcopy = deepcopy

-- --- undo (the editor's Ctrl+Z, one stack with the world's changes)
function QBD:snapshot()
  local m = self.ed.project.meta
  local out = {}
  for _, k in ipairs(QBD_DATA.UNDONE) do out[k] = deepcopy(P.get(m, k)) end
  return out
end

function QBD:remember()
  local now = self:snapshot()
  local same = require("conjunction.json").encode(now) == require("conjunction.json").encode(self.shot or {})
  if self.shot_of == self.ed.project and not same and self.ed.undo then
    self.ed.undo[#self.ed.undo + 1] = {"quest", self.shot}
    while #self.ed.undo > 200 do table.remove(self.ed.undo, 1) end
  end
  self.shot, self.shot_of = now, self.ed.project
end

function QBD:restore(shot)
  local m = self.ed.project.meta
  for _, k in ipairs(QBD_DATA.UNDONE) do
    if shot[k] == nil then Y.remove(m, k) else m[k] = deepcopy(shot[k]) end
  end
  self:save_meta()
  self.shot, self.shot_of = self:snapshot(), self.ed.project
  self:sync()
end

-- a node under `nid`, between it and where it went on (questboard.add_after); returns the new id
function QBD:add_after(nid, step)
  local q = self:graph_quest()
  local at = q.nodes[nid]
  local nxt = QN.new_id(q)
  local gap = 120
  local shown = self.graph.graph
  if shown ~= nil and shown.nodes[nid] ~= nil then
    gap = math.max(gap, -((-(math.floor(shown.nodes[nid].h) + 40)) // GL.GRID) * GL.GRID)
  end
  local ax, ay = P.get(at, "x"), P.get(at, "y", 0)
  q.nodes[nxt] = Y.map({"step", step, "x", P.get(at, "x", 0), "y", ay + gap})
  for _, other in pairs(q.nodes) do
    if other ~= q.nodes[nxt] and P.get(other, "x") == ax and P.get(other, "y", 0) > ay then
      other.y = P.get(other, "y", 0) + gap
    end
  end
  local ons = self:ons(nid)
  if #ons == 0 then return nxt end
  local wired = {}
  for _, p in ipairs(ons) do
    local ts = {}
    for _, ln in ipairs(QN.links_from(q, nid, p)) do ts[#ts + 1] = ln[3] end
    require("conjunction.pysort").sort(ts)
    wired[p] = ts
  end
  local main
  for _, p in ipairs({"next", "continue"}) do
    if P.contains(ons, p) then main = p break end
  end
  local after = {}
  local function key(t) return table.concat(t, "\0") end
  if main ~= nil then
    after = P.copy_list(wired[main])
  else
    -- a choice's: the targets two or more of its outputs share (Python's set of tuples: the first one found of
    -- those - its order is the set's, so the earliest-wired is taken here)
    local count, order = {}, {}
    for _, p in ipairs(ons) do
      local k = key(wired[p])
      if #wired[p] > 0 then
        if not count[k] then order[#order + 1] = p end
        count[k] = (count[k] or 0) + 1
      end
    end
    for _, p in ipairs(order) do
      if count[key(wired[p])] >= 2 then after = P.copy_list(wired[p]) break end
    end
  end
  local after_key = key(after)
  for _, port in ipairs(ons) do
    local same = #after > 0 and key(wired[port]) == after_key
    if port == main or #wired[port] == 0 or same then
      local keep = Y.list({})
      for _, ln in ipairs(q.links) do if not (ln[1] == nid and ln[2] == port) then keep[#keep + 1] = ln end end
      q.links = keep
      q.links[#q.links + 1] = Y.list({nid, port, nxt})
    end
  end
  for _, mine in ipairs(self:ons(nxt)) do
    for _, b in ipairs(after) do q.links[#q.links + 1] = Y.list({nxt, mine, b}) end
  end
  return nxt
end

-- --- sync: the board anew from the project
function QBD:sync()
  self.want_sync = false
  self.data_ver = (self.data_ver or 0) + 1
  if self.waiting and not self.ed.request then self.waiting = nil end   -- (the editor stopped waiting: Esc, answered)
  if self.shot_of ~= self.ed.project then self.shot, self.shot_of = self:snapshot(), self.ed.project end
  local q = self:quest()
  self.title_text = P.str(P.get(q, "title", ""))
  if not self.desc_typing then self.desc_text = P.str(P.get(q, "description", "")) end
  self:fill_cast()
  self:sync_graph()
end

-- In this quest: its window shown or closed (questboard._toggle_cast)
function QBD:toggle_cast()
  local p = self.panel
  local w = p.windows and p.windows.cast
  if w and w.shown then w:close() return end
  p:cast_window(self)
end

-- 'In this quest': the counts on its button (cast_view.counts)
function QBD:fill_cast()
  local QS = require("conjunction.quest")
  local IC = require("conjunction.ui.item_chooser")
  local people, things = 0, 0
  for _, p in pairs(self.ed.project.places or {}) do
    for _, o in ipairs(P.list(P.get(p, "objects"))) do
      if not P.T(P.get(o, "trail")) then
        if QS.is_actor(o) then people = people + 1 else things = things + 1 end
      end
    end
  end
  local wo = self.ed.project.meta and self.ed.project.meta.world_objects   -- (and the things of the world taken)
  for _ in pairs(Y.is_map(wo) and wo or {}) do things = things + 1 end
  local items = #IC.quest_item_refs(self:quest())
  self.cast_text = string.format("In this quest  ·  %d people, %d things, %d items", people, things, items)
end

function QBD:sync_graph()
  local q = self:graph_quest()
  local same = self.graph_of == self.ed.project
  self.graph_of = self.ed.project
  local names = require("conjunction.quest").display_names(self.ed.project)
  local existing = {}                           -- (the objects there are: a step naming a gone one shows it)
  for place, p in pairs(self.ed.project.places or {}) do
    for _, o in ipairs(P.list(P.get(p, "objects"))) do
      if P.T(P.get(o, "id")) then existing[place .. "/" .. P.str(o.id)] = true end
    end
  end
  self.graph:show_graph(QG.build_nodes(q, names, existing), same)
  local pick, menu = self.graph_pick, self.graph_menu
  self.graph_pick, self.graph_menu = nil, nil
  for _, n in pairs(self.graph.graph.nodes) do
    if pick ~= nil and q.nodes[n.id].step == pick then
      self.graph_node = n.id
      self.show_later = {n.id, 60}
      if menu == pick then self.menu_later = n.id end   -- (a block just dropped: what it does, chosen at once)
    end
  end
  if (self.graph_node == nil and not self.none_picked) or
     (self.graph_node ~= nil and self.graph.graph.nodes[self.graph_node] == nil) then
    self.graph_node = QN.START
  end
  self.graph:select(self.graph_node)
  self:graph_card()
end

-- Esc (editor.escape): the block picked let go - in the dialogue when it is open, else in the graph (MaximdeWinter 13.11.)
-- -> true when something was picked
function QBD:deselect()
  if self.dialogue then return self.dialogue:deselect() end
  if self.graph_node == nil then return false end
  self.graph_node, self.none_picked = nil, true
  self.graph:select(nil)
  self:graph_card()
  return true
end

-- --- the graph's events
function QBD:graph_picked(nid)
  self.none_picked = false
  self.graph_node = nid
  self.graph:select(nid)
  self:graph_card()
  self.show_later = {nid, 30}                   -- (QTimer 0: the card below took room)
end

function QBD:node_step(nid)
  local n = self.graph.graph and self.graph.graph.nodes[nid]
  if n == nil or n.card == nil or n.card.i == nil then return nil end
  return n.card
end

-- the quest in the quest graph (vanilla_window): its every block as the last build made it; changes there are kept
-- with the project and built into the quest from then on (questboard.open_quest_graph)
function QBD:open_quest_graph()
  local panel = self.ed.panel
  local project = self.ed.project
  if not panel or not project then return nil end
  local VW = require("conjunction.ui.vanilla_window")
  local name = require("conjunction.py").str(project.meta and project.meta.name or "")
  local win = panel:open_win("Own quest graph", "Quest graph - " .. name, "quest graph", function(w)
    return VW.new(self.ed, w, nil, {project_dir = project.path, own = true})
  end)
  if win.body and #win.body.trail == 0 then win.body.want_own = true end
  return win
end

function QBD:graph_open(nid)
  local at = self:node_step(nid)
  if at ~= nil and QN.step_kind(at.steps[at.i]) == "talk" then self:open_dialogue(at.steps[at.i]) end
end

function QBD:graph_moved_node(nid, x, y)
  local node = self:graph_quest().nodes[nid]
  if node ~= nil then
    node.x, node.y = x, y
    self:save()
  end
end

-- what a node's block does: its kinds, in a list over the graph at the node's title (questboard._graph_kind_menu)
function QBD:graph_kind_menu(nid)
  local IM = require("conjunction.ui.inline_menu")
  local n = self.graph.graph and self.graph.graph.nodes[nid]
  local at = self:node_step(nid)
  local kinds = n ~= nil and self.graph:kinds_of(n) or {}
  if at == nil or #kinds == 0 then return end
  local has = {}
  for _, k in ipairs(kinds) do has[k] = true end
  local groups = n.block == "action" and QBD_DATA.ACTION_GROUPS or n.block == "goal" and QBD_DATA.GOAL_GROUPS
                 or {{nil, kinds}}
  local items = {}
  for _, g in ipairs(groups) do
    local list = g[1] and {} or items
    for _, k in ipairs(g[2]) do
      if has[k] then
        list[#list + 1] = {text = QG.LABEL[k] or k, checked = k == n.kind,
                           action = function() self:set_kind(at.steps, at.i, k) end}
      end
    end
    if g[1] then items[#items + 1] = {group = g[1], items = list} end
  end
  local g = self.graph_rect
  local cx, cy = self.graph:from_scene(n.x + 8, n.y + 4)
  IM.open("qb.graph_kinds", {x = g.x + cx, y = g.y + cy, w = 120, h = GL.HEAD - 4}, items, self.panel.rect, {bg = LIST_BG})
end

-- a right click on a node: play from here, duplicate, remove (questboard._graph_node_menu)
function QBD:graph_node_menu(nid, x, y)
  local IM = require("conjunction.ui.inline_menu")
  local at = self:node_step(nid)
  if at == nil then return end
  local items = {}
  for _, e in ipairs(QBD_DATA.card_menu_of(at.steps[at.i])) do
    items[#items + 1] = {text = e[2], action = function() self:card_menu(at.steps, at.i, e[1]) end}
  end
  IM.open("qb.graph_node", {x = x, y = y - 2, w = 140, h = 2}, items, self.panel.rect, {bg = LIST_BG})
end

function QBD:graph_wire_menu(link, x, y)
  local IM = require("conjunction.ui.inline_menu")
  IM.open("qb.graph_wire", {x = x, y = y - 2, w = 140, h = 2}, {{text = "Remove connection", icon = "trash-2",
    action = function()
      self:unlink(link)
      self.graph:select_wire(nil)
      self:save()
    end}}, self.panel.rect, {bg = LIST_BG})
end

-- a node of its own at (x, y) (its top left, on the grid); returns its id (questboard._add_node)
function QBD:add_node(step, x, y)
  local q = self:graph_quest()
  local nid = QN.new_id(q)
  q.nodes[nid] = Y.map({"step", step, "x", math.floor(x / GL.GRID) * GL.GRID, "y", math.floor(y / GL.GRID) * GL.GRID})
  return nid
end

-- a block from the sidebar: where it is let go, on its own; onto a wire: into it (questboard._graph_place)
function QBD:graph_place(block, drop)
  local step = self:new_step(block)
  if drop[1] == "wire" then
    local a, port, b = drop[2][1], drop[2][2], drop[2][3]
    local nid = self:add_node(step, drop[3] - GL.NODE_W / 2, drop[4] - 20)
    self:unlink(drop[2])
    self:link(a, port, nid)
    for _, mine in ipairs(self:ons(nid)) do self:link(nid, mine, b, true) end
  else
    self:add_node(step, drop[2] - GL.NODE_W / 2, drop[3] - 20)
  end
  self.graph_pick = step
  if QG.PLACEHOLDERS[block] then self.graph_menu = step end
  self:save()
end

-- the card of the node picked (questboard._graph_card): what it holds, built when it changes
function QBD:graph_card()
  local node = self.graph.graph and self.graph.graph.nodes[self.graph_node]
  self.card_node = node
  self.card_visible = node ~= nil and (not GL.ENDS[node.kind] or node.kind == "end")
end

-- --- layout (QuestBoard's: a VBox 0 6 0 0, the rows 6 apart)
local function menu_size(text) return Q.hint_w(text, 12) + 27, 25 end      -- QToolButton#menu / #chip
local function plus_size(text) return Q.hint_w(text, 12) + 8, 24 end       -- QPushButton#plus
local function small_size(text, icon) return Q.hint_w(text, 12) + (icon and 38 or 18), 22 end   -- QPushButton#small
QBD.menu_size, QBD.plus_size, QBD.small_size = menu_size, plus_size, small_size

function QBD:layout(pg)
  local lay = {}
  local eh = CT.edit_h()
  local top_h = eh
  local col = L.column({
    {hint = top_h, min = top_h, max = top_h},
    {hint = 22, min = 22, max = 22},
    {hint = 0, min = 0, stretch = 1},
  }, pg.x, pg.y, pg.w, pg.h, {margins = {0, 6, 0, 0}, spacing = 6})
  -- the top row: the name (stretch), [Jump to], ··· (4 apart)
  local mw, mh = menu_size("···")
  local items = {{hint = 17 * Q.text_w("x") + 16, min = 42, stretch = 1, cross_max = eh}}
  local jump = #self.graph.graph.chapters >= 2
  if jump then
    local jw, jh = menu_size("Jump to")
    items[#items + 1] = {hint = jw, min = jw, max = jw, cross_max = jh}
  end
  items[#items + 1] = {hint = mw, min = mw, max = mw, cross_max = mh}
  local top = L.row(items, col[1].x, col[1].y, col[1].w, col[1].h, {spacing = 4})
  lay.title = top[1]
  if jump then lay.jump = top[2] end
  lay.projects = top[#top]
  -- In this quest (stretch) and Quest graph (6 apart)
  local gw = small_size("Quest graph", true)
  local cw = small_size(self.cast_text or "", true)
  local row = L.row({{hint = cw, min = 0, stretch = 1, cross_max = 22}, {hint = gw, min = gw, max = gw, cross_max = 22}},
                    col[2].x, col[2].y, col[2].w, col[2].h, {spacing = 6})
  lay.cast, lay.graph_open = row[1], row[2]
  -- the blocks (100 wide) and the splitter (6 apart)
  local area = col[3]
  lay.blocks = {x = area.x, y = area.y, w = QBD.BLOCK_W + 4, h = area.h}
  local sx = area.x + QBD.BLOCK_W + 4 + 6
  local split = {x = sx, y = area.y, w = area.x + area.w - sx, h = area.h}
  lay.split = split
  local total = split.h - QBD.HANDLE
  if self.card_visible then
    local top_h2 = math.floor(total * self.graph_frac)
    -- the card no higher than what is in it, the graph takes the rest (MaximdeWinter 24.10.: below a short card the board
    -- stayed empty); card_need is what the card needed when it was last drawn
    local need = self.card_need
    if need and total - top_h2 > need then top_h2 = total - need end
    lay.graph = {x = split.x, y = split.y, w = split.w, h = top_h2}
    lay.handle = {x = split.x, y = split.y + top_h2, w = split.w, h = QBD.HANDLE}
    lay.card = {x = split.x, y = split.y + top_h2 + QBD.HANDLE, w = split.w, h = total - top_h2}
  else
    lay.graph = {x = split.x, y = split.y, w = split.w, h = split.h}
  end
  return lay
end

-- --- the painted controls of the board's sheet
-- QToolButton#menu (#chip: its own colours; checked: CHOSEN): the text in the middle, 12 px
function QBD.menu_button(id, r, text, opts)
  opts = opts or {}
  local clicked, hovered = CT.hit_box(id, r)
  local bg, edge, fg = C.menu_bg, C.menu_edge, C.menu_fg
  if opts.chip then
    fg = C.chip_fg
    if opts.checked then bg, edge, fg = C.chip_on_bg, C.chip_on_edge, C.chip_on_fg end
  elseif hovered then
    edge = C.menu_hover
  end
  Q.frame(r.x, r.y, r.w, r.h, bg, edge)
  local tw = Q.text_w(text, 12)
  local lh = Q.line_h(12)
  Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, lh), fg, text, 12, false, bg)
  if hovered and opts.tip then CT.tip(id, opts.tip) end
  return clicked, hovered
end

-- QPushButton#small (padding 2px 8px, 12 px, an icon 16 px 4 before the text; text-align: left or the middle)
function QBD.small_button(id, r, text, icon, opts)
  opts = opts or {}
  local clicked, hovered, held = CT.hit_box(id, r)
  local bg, edge = T.BUTTON, T.EDGE
  if hovered then edge = T.EDGE_HOVER end
  if held and hovered then bg = T.CHOSEN end
  Q.frame(r.x, r.y, r.w, r.h, bg, edge)
  local tw = Q.text_w(text, 12)
  local lh = Q.line_h(12)
  local block = (icon and 20 or 0) + tw
  local x = opts.left and (r.x + 1 + 8) or (r.x + 1 + 8 + (r.w - 18 - block) // 2)
  local ty = r.y + Q.vcenter(r.h, lh)
  D.clip(r.x + 1 + 8, r.y + 1, math.max(0, r.w - 18), r.h - 2, function()
    if icon then
      Q.draw_icon(icon, 0xcfcfcfff, 16, x, r.y + (r.h - 16) // 2)
      x = x + (opts.left and 20 or 18)          -- (centred, Qt's label puts the text 2 px nearer: measured)
    end
    Q.text(x, ty, T.BUTTON_TEXT, text, 12, false, bg)
  end)
  if hovered and opts.tip then CT.tip(id, opts.tip) end
  return clicked, hovered
end

-- QPushButton#plus: dashed #444, #9a9a9a, padding 3px, 12 px (under the mouse #eee on #888)
function QBD.plus_button(id, r, text, opts)
  opts = opts or {}
  local clicked, hovered = CT.hit_box(id, r)
  local fg, edge = C.plus_fg, C.plus_edge
  if hovered then fg, edge = C.plus_hover_fg, C.plus_hover_edge end
  require("conjunction.ui.qb_widgets").dashed(r.x, r.y, r.w, r.h, edge)
  local tw = Q.text_w(text, 12)
  Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(12)), fg, text, 12, false, opts.bg)
  if hovered and opts.tip then CT.tip(id, opts.tip) end
  return clicked, hovered
end

-- QToolButton#plus (padding 3px 8px: 27 high; a menu, no arrow): dashed #444, #9a9a9a - #eee on #888 under the mouse
function QBD.plus_tool(id, r, text, opts)
  return QBD.plus_button(id, r, text, opts)
end

-- _removable(_chip(...)), checked: the text, the trash can (12 px) after it - a click removes it
function QBD.removable_chip(id, r, text, opts)
  opts = opts or {}
  local clicked, hovered = CT.hit_box(id, r)
  local bg, edge, fg = C.chip_on_bg, C.chip_on_edge, C.chip_on_fg
  Q.frame(r.x, r.y, r.w, r.h, bg, edge)
  -- (QCommonStyle, TextBesideIcon: the icon's room 12 + 4 at the right - RightToLeft -, the text left in the rest)
  D.clip(r.x + 1, r.y + 1, math.max(0, r.w - 2), r.h - 2, function()
    Q.text(r.x + 1 + 8, r.y + Q.vcenter(r.h, Q.line_h(12)), fg, text, 12, false, bg)
  end)
  Q.draw_icon("trash-2", 0xcfcfcfff, 12, r.x + r.w - 1 - 8 - 16 + 2, r.y + (r.h - 12) // 2)
  if hovered and opts.tip then CT.tip(id, opts.tip) end
  return clicked, hovered
end

-- a 1 px dashed frame as Qt's style sheet paints border-style: dashed (the dashes run round from each corner)
function QBD.dashed_rect(x, y, w, h, colour)
  local dash = 3
  local function hline(yy)
    local k = 0
    while k < w do
      D.fill(x + k, yy, math.min(dash, w - k), 1, colour)
      k = k + 2 * dash
    end
  end
  local function vline(xx)
    local k = 0
    while k < h do
      D.fill(xx, y + k, 1, math.min(dash, h - k), colour)
      k = k + 2 * dash
    end
  end
  hline(y)
  hline(y + h - 1)
  vline(x)
  vline(x + w - 1)
end

-- QLabel#field: 12 px #999, in the middle of its row
function QBD.field(r, text, bg)
  Q.text(r.x, r.y + Q.vcenter(r.h, Q.line_h(12)), C.field, text, 12, false, bg)
end

-- --- the block tiles (graph_blocks.BlockTile: painted by Qt - their shape and letters as in the graph)
local function tile_picture(self, block, label, colour, hot)
  local key = block .. (hot and "_hot" or "")
  local t = self.tiles[key]
  if t ~= nil then return t end
  local node = {kind = block == "end" and "end" or block, block = block}
  local r = {2.5, 4.5, QBD.BLOCK_W - 5, 40 - 9}
  local pts, rect = GV.shape(node, r)
  local c = colour
  local out = {
    "aa 1",
    "brush " .. GV.qc(block == "chapter" and "#22222e" or GV.RAISED),
    "pen " .. GV.qc(c, hot and 255 or 150) .. " 1.2" .. (block == "parallel" and " 16 64 2" or ""),
  }
  local parts = {"path"}
  for i = 1, #pts, 2 do parts[#parts + 1] = (i == 1 and "M " or "L ") .. pts[i] .. " " .. pts[i + 1] end
  if rect then parts[#parts + 1] = "L " .. pts[1] .. " " .. pts[2] end
  parts[#parts + 1] = "Z"
  out[#out + 1] = table.concat(parts, " ")
  out[#out + 1] = "pen " .. GV.qc(c) .. " 1"
  out[#out + 1] = "fontpx 10 1 0.5"
  out[#out + 1] = string.format("textrect %s %s %s %s 132 %s", r[1], r[2], r[3], r[4], label:upper())
  local dir = (os.getenv("TEMP") or ".") .. "\\cj_core\\tiles"
  if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
  local ok, _, id, w, h = pcall(require("conjunction.ui.qtpaint").kept, dir, tostring(QBD.BLOCK_W), "40", out)
  t = false
  if ok and id then t = {id, w, h} end
  self.tiles[key] = t
  return t
end

-- (graph_blocks.BlockTile: pressed and moved MOVE_PX, a drag - over the graph it shows where the block would go, let
-- go there it goes there; let go without moving, on the tile: a click. The tile stays lit while it is held - Qt sends
-- no leave while a button is down.)
QBD.tile_picture = tile_picture                -- (the dialogue's sidebar too)

function QBD:draw_blocks(r)
  local mx, my = w3.ui.mouse()
  local y = r.y + 2
  local scenes = require("conjunction.features").scenes()
  for _, b in ipairs(QG.BLOCKS) do
    if b[1] == "scene" and not scenes then goto next_block end
    local box = {x = r.x, y = y, w = QBD.BLOCK_W, h = 40}
    local clicked, hovered, held = CT.hit_box("qb.block." .. b[1], box)
    local bp = self.block_press
    if held and (bp == nil or bp.block ~= b[1]) then
      bp = {block = b[1], x = mx, y = my}
      self.block_press = bp
    end
    local mine = bp ~= nil and bp.block == b[1]
    local t = tile_picture(self, b[1], b[2], QBD.BLOCK_COLOUR[b[1]], hovered or (mine and held))
    if t then D.image(t[1], box.x, box.y, t[2], t[3]) end
    if mine then
      if held then
        if not bp.dragging and math.abs(mx - bp.x) + math.abs(my - bp.y) >= GV.MOVE_PX then bp.dragging = true end
        if bp.dragging then self:block_drag(b[1], mx, my, false) end
      else
        self.block_press = nil
        if bp.dragging then self:block_drag(b[1], mx, my, true)
        elseif clicked then self:block_clicked(b[1], box) end
      end
    end
    y = y + 40 + 4
    ::next_block::
  end
end

-- the dragged block over the graph (dropped: let go there)
function QBD:block_drag(block, mx, my, dropped)
  local g = self.graph_rect
  if g == nil then return end
  local px, py = math.floor(mx - g.x), math.floor(my - g.y)
  if dropped then self.graph:block_dropped(block, px, py) else self.graph:block_over(block, px, py) end
end

-- --- copy and paste, templates (MaximdeWinter 10.11.: a scene built once, put in elsewhere, 1-2 things changed)
-- A copy: Conjunction's data\clipboard_step.yml (opening another project restarts the game). A template:
-- <home>\templates\<name>.yml. Both {name, step, layer}: layer the timeline's staging of a talk or scene (its
-- scene_layers\s<node>.json in the project), nil for anything else.
local function clip_path() return require("conjunction.paths").DATA .. "\\clipboard_step.yml" end
function QBD.templates_dir() return require("conjunction.paths").HOME .. "\\templates" end

-- the timeline's file of node nid in the project (the build lays it over the scene it makes: build.lua)
function QBD:layer_file(nid)
  local num = tostring(nid or ""):match("^n(%d+)$")
  local dir = self.ed.project and self.ed.project.path
  return (num and dir) and (dir .. "\\scene_layers\\s" .. num .. ".json") or nil
end

-- node nid as a copy: {name, step, layer} (nil: the start, or no such node)
function QBD:node_copy(nid)
  local q = self:graph_quest()
  local node = nid and q.nodes[nid]
  if node == nil or nid == QN.START then return nil end
  local out = Y.map({"step", deepcopy(node.step)})
  local lf = self:layer_file(nid)
  local layer = lf and w3.fs.exists(lf) and w3.fs.read(lf) or nil
  if layer then out.layer = layer end
  return out
end

function QBD:copy_node(nid)
  local data = self:node_copy(nid or self.graph_node)
  if data == nil then return false end
  require("conjunction.build").makedirs(require("conjunction.paths").DATA)
  Y.write(clip_path(), data)
  self.panel:say("Copied. Ctrl+V puts it in after the step picked, here or in another quest", 3000)
  return true
end

-- a copy (or template) put in after node `after` (nil: the one picked, else the start) -> the new node's id
function QBD:insert_copy(data, after)
  if not (Y.is_map(data) and P.get(data, "step")) then return nil end
  local step = deepcopy(data.step)
  local existing = {}
  for place, p in pairs(self.ed.project.places or {}) do
    for _, o in ipairs(P.list(P.get(p, "objects"))) do
      if P.T(P.get(o, "id")) then existing[place .. "/" .. P.str(o.id)] = true end
    end
  end
  local _, a = QN.step_kind(step)
  if Y.is_map(a) then                            -- (a person the project lacks: out - the card asks who)
    for _, key in ipairs({"npc", "who", "target"}) do
      local v = P.get(a, key)
      if type(v) == "string" and v:match("^[%w_]+/[%w_]+$") and not existing[v] then Y.remove(a, key) end
    end
  end
  local q = self:graph_quest()
  local n = self.graph.graph and self.graph.graph.nodes[after or self.graph_node]
  if n == nil or q.nodes[n.id] == nil or QN.step_kind(q.nodes[n.id].step) == "end" then
    n = self.graph.graph.nodes[QN.START]
  end
  local nid = self:add_after(n.id, step)
  local layer = P.get(data, "layer")
  local lf = self:layer_file(nid)
  if type(layer) == "string" and lf then
    require("conjunction.build").makedirs((lf:gsub("[\\/][^\\/]*$", "")))
    w3.fs.write(lf, layer)
  end
  self.graph_pick = step
  self:save()
  return nid
end

function QBD:paste_node(after)
  local ok, data = pcall(Y.read, clip_path())
  if not ok or data == nil then
    self.panel:say("Nothing copied yet: Ctrl+C over a step copies it", 3000)
    return false
  end
  return self:insert_copy(data, after) ~= nil
end

-- the templates: {{name, path}} by name
function QBD.template_list()
  local out = {}
  local dir = QBD.templates_dir()
  if not w3.fs.isdir(dir) then return out end
  for _, e in ipairs(w3.fs.list(dir) or {}) do
    local name = type(e) == "table" and e.name or e
    if type(name) == "string" and name:lower():sub(-4) == ".yml" then out[#out + 1] = {name:sub(1, -5), dir .. "\\" .. name} end
  end
  table.sort(out, function(x, y) return x[1]:lower() < y[1]:lower() end)
  return out
end

-- node nid kept as a template under its title (a scene's, a talk's), a number added when the name is taken
function QBD:save_template(nid)
  local data = self:node_copy(nid)
  if data == nil then return false end
  local _, a = QN.step_kind(data.step)
  local names = require("conjunction.quest").display_names(self.ed.project)
  local who = a and P.get(a, "npc")
  local base = P.str(P.or_(P.get(a or Y.map(), "text"),
                           (P.T(P.get(a or Y.map(), "scene")) and "Scene" or "Talk") ..
                           (who and (" with " .. P.str(names[who] or (P.str(who):match("([^/]*)$"):gsub("_", " "))))
                            or "")))
  base = base:gsub('[\\/:*?"<>|]', " "):gsub("%s+", " ")
  local dir = QBD.templates_dir()
  require("conjunction.build").makedirs(dir)
  local name, k = base, 1
  while w3.fs.exists(dir .. "\\" .. name .. ".yml") do k = k + 1; name = base .. " " .. k end
  data.name = name
  Y.write(dir .. "\\" .. name .. ".yml", data)
  self.panel:say("Kept as the template \"" .. name .. "\": the Scene block offers it", 3500)
  return true
end

-- the Scene tile: an empty scene, or (with templates) a list - Empty scene, then each template
function QBD:scene_tile(box)
  local list = QBD.template_list()
  if #list == 0 then return false end
  local IM = require("conjunction.ui.inline_menu")
  local items = {{text = "Empty scene", action = function() self:block_clicked_plain("scene") end}}
  for _, t in ipairs(list) do
    items[#items + 1] = {text = t[1], action = function()
      local ok, data = pcall(Y.read, t[2])
      if ok and data then self:insert_copy(data) else self.panel:say("The template could not be read: " .. t[2], 4000, true) end
    end}
  end
  IM.open("qb.scene_templates", {x = box.x + box.w + 4, y = box.y, w = 220, h = 2}, items, self.panel.rect, {bg = LIST_BG})
  return true
end

-- a block clicked in the sidebar (not dragged): under the node picked and on from it (between it and where its
-- output led); nothing picked, or an end: under the start (questboard._graph_click_block). The Scene tile with
-- templates kept asks first (scene_tile)
function QBD:block_clicked(block, box)
  if block == "scene" and box and self:scene_tile(box) then return end
  return self:block_clicked_plain(block)
end
function QBD:block_clicked_plain(block)
  local q = self:graph_quest()
  local n = self.graph.graph and self.graph.graph.nodes[self.graph_node]
  local step = self:new_step(block)
  if n == nil or q.nodes[n.id] == nil or QN.step_kind(q.nodes[n.id].step) == "end" then
    n = self.graph.graph.nodes[QN.START]
  end
  self:add_after(n.id, step)
  self.graph_pick = step
  if QG.PLACEHOLDERS[block] then self.graph_menu = step end
  self:save()
end

-- --- one frame
function QBD:frame(pg)
  if self.dialogue then return self.dialogue:frame(pg) end
  if self.chooser_again then                    -- (placing cancelled: QBD:request)
    local c = self.chooser_again
    self.chooser_again = nil
    self:reopen_chooser(c)
  end
  if self.want_sync then self:sync() end
  if self.graph.graph == nil then self:sync() end
  local lay = self:layout(pg)
  self.lay = lay
  local bg = self.panel.C.bg
  -- the name: a field (editingFinished: kept); a new quest's or project's name typed in its place
  local r = lay.title
  if self.new_what then
    local _, t, enter = CT.edit("qb.new_name", r.x, r.y, r.w, self.new_text or "",
                                {placeholder = self.new_what == "quest" and "Quest name" or "Project name",
                                 style = self.panel.EDIT_STYLE})
    self.new_text = t
    if enter then self:create_project()
    elseif CT.focus ~= "qb.new_name" and require("conjunction.pystr").strip(t) == "" then self:new_done() end
  else
    local _, text = CT.edit("qb.title", r.x, r.y, r.w, self.title_text or "",
                            {placeholder = "Quest name", style = self.panel.EDIT_STYLE, tip = "qb.title"})
    if text ~= self.title_text then self.title_text = text end
    local typing = CT.focus == "qb.title"
    if self.title_typing and not typing then self:save_head() end
    self.title_typing = typing
  end
  local IM = require("conjunction.ui.inline_menu")
  if lay.jump and QBD.menu_button("qb.jump", lay.jump, "Jump to", {tip = "qb.jump_to"}) then
    if IM.is_open("qb.jump") then IM.close() else
      IM.open("qb.jump", lay.jump, self:jump_entries(), self.panel.rect, {bg = LIST_BG})
    end
  end
  if QBD.menu_button("qb.projects", lay.projects, "···", {tip = "qb.projects"}) then
    if IM.is_open("qb.projects") then IM.close() else
      IM.open("qb.projects", lay.projects, self:project_entries(), self.panel.rect, {bg = LIST_BG})
    end
  end
  if QBD.small_button("qb.cast", lay.cast, self.cast_text or "", "external-link", {left = true, tip = "qb.in_quest"}) then
    self:toggle_cast()
  end
  if QBD.small_button("qb.graph_open", lay.graph_open, "Quest graph", "external-link", {tip = "qb.quest_graph"}) then
    self:open_quest_graph()
  end
  self:draw_blocks(lay.blocks)
  local g = lay.graph
  self.graph_rect = g                           -- (where the graph's lists open)
  local pr = self.panel.rect
  if pr then self.graph.device = {pr.w, pr.h, g.x - pr.x, g.y - pr.y} end
  local hovered = CT.over(g)
  self.graph:frame(g, hovered)
  if self.show_later then
    self.graph:show_node(self.show_later[1], self.show_later[2])
    self.show_later = nil
  elseif self.menu_later then                   -- (QTimer 30: after the node is in sight)
    local nid = self.menu_later
    self.menu_later = nil
    self:graph_kind_menu(nid)
  end
  if lay.card then
    D.fill(lay.handle.x, lay.handle.y, lay.handle.w, lay.handle.h, C.card)
    self:draw_card(lay.card)
  end
end

-- Jump to: the chapters - a click shows it in the graph (questboard._fill_jump)
function QBD:jump_entries()
  local out = {}
  local g = self.graph.graph
  for _, nid in ipairs(g and Y.keys(g.nodes) or {}) do
    local n = g.nodes[nid]
    if n.kind == "chapter" then out[#out + 1] = {text = P.str(n.text), action = function() self:graph_picked(nid) end} end
  end
  return out
end

-- ···: the project's quests (the one edited checked), a new one, removing this one; other projects, a new one, a
-- folder (questboard._fill_projects)
function QBD:project_entries()
  local QS = require("conjunction.quests")
  local PR = require("conjunction.project")
  local meta = self.ed.project.meta
  local mine = QS.all_quests(meta)
  if #mine == 0 then mine = {self:quest()} end
  local name = P.str(P.get(meta, "name"))
  local out = {{text = "Quests of " .. (name ~= "" and name or "this project"), disabled = true}}
  for _, q in ipairs(mine) do
    local key = QS.key_of(q)
    local title = P.str(P.get(q, "title"))
    out[#out + 1] = {text = title ~= "" and title or ("Quest " .. key), checked = q == P.get(meta, "quest"),
                     action = function() self:switch_quest(key) end}
  end
  out[#out + 1] = {text = "+ New quest in this project...", action = function() self:new_project("quest") end}
  if #mine > 1 then out[#out + 1] = {text = "Remove this quest", action = function() self:remove_quest() end} end
  out[#out + 1] = "-"
  out[#out + 1] = {text = "Projects", disabled = true}
  out[#out + 1] = {text = "New project...", action = function() self:new_project("project") end}
  local others, count = {}, {}
  for _, path in ipairs(PR.recent()) do
    if PR.key_of(path) ~= PR.key_of(self.ed.project.path) then
      local ok, m = pcall(require("conjunction.yaml").read, path .. "\\project.yml")
      if ok and type(m) == "table" then
        local n = P.str(P.get(m, "name"))
        if n == "" then n = path:match("([^\\/]+)$") or path end
        others[#others + 1] = {n, path}
        count[n] = (count[n] or 0) + 1
      end
    end
  end
  for _, o in ipairs(others) do
    local label = count[o[1]] > 1 and (o[1] .. "   (" .. (o[2]:match("([^\\/]+)$") or o[2]) .. ")") or o[1]
    out[#out + 1] = {text = label, action = function() self:switch_project(o[2]) end}
  end
  out[#out + 1] = "-"
  out[#out + 1] = {text = "Open folder...", action = function() self:open_folder() end}
  return out
end

-- (in the game another project opens with the next start: editor.start_clean)
function QBD:switch_project(path)
  if self.ed.switch_project then self.ed:switch_project(path) elseif self.ed.start_clean then self.ed:start_clean(path) end
end

-- the name of a new quest of this project (what: quest) or of a new project, typed where the title is
function QBD:new_project(what)
  self.new_what, self.new_text = what, ""
  CT.set_focus("qb.new_name")
end

function QBD:new_done()
  self.new_what, self.new_text = nil, nil
  if CT.focus == "qb.new_name" then CT.set_focus(nil) end
end

function QBD:create_project()
  local name = require("conjunction.pystr").strip(self.new_text or "")
  local what = self.new_what
  self:new_done()
  if name == "" then return end
  if what == "quest" then                       -- (a quest of this project: its people, its places)
    self:quest()
    require("conjunction.quests").add(self.ed.project.meta, name)
    self:save_meta()
    self.graph_node = nil
    self:sync()
    return
  end
  self:switch_project(require("conjunction.project").new_project(name))
end

-- another quest of the project edited (questboard._switch_quest)
function QBD:switch_quest(key)
  require("conjunction.quests").switch(self.ed.project.meta, key)
  self:save_meta()
  self.graph_node = nil
  self:sync()
end

function QBD:remove_quest()
  local q = self:quest()
  local title = P.str(P.get(q, "title"))
  local text = string.format("Remove the quest '%s' from the project? Its steps go (Undo brings them back).",
                             title ~= "" and title or "without a name")
  require("conjunction.ui.dialogs").question(self.ed, "Remove quest", text, function(answer)
    if answer ~= "yes" then return end
    local QS = require("conjunction.quests")
    QS.remove(self.ed.project.meta, QS.key_of(q))
    self:save_meta()
    self.graph_node = nil
    self:sync()
  end)
end

-- a project's folder chosen (it has a project.yml): that project (questboard._open_folder)
function QBD:open_folder()
  local PR = require("conjunction.project")
  require("conjunction.ui.dialogs").pick_folder(self.ed, "Quest folder", PR.PROJECTS, function(d)
    if d and d ~= "" and w3.fs.exists(d .. "\\project.yml") then self:switch_project(d) end
  end)
end

function QBD:save_head()
  local q = self:quest()
  q.title = require("conjunction.pystr").strip(self.title_text or "")
  self:save(false)
end

-- --- the card under the graph: a scroll area (no frame, no bar across; its body at least as wide as it needs)
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")

function QBD:draw_card(r)
  D.fill(r.x, r.y, r.w, r.h, C.card)
  local node = self.card_node
  if node == nil then return end
  if node.kind ~= "start" then return self:draw_tree_card(r, node) end
  -- QUEST STARTS (its own drawing), then what belongs to the whole quest (questboard._quest_extras) - a column,
  -- margins 0 6 6 4, 6 apart, in the card's scroll area
  local W = require("conjunction.ui.qw")
  self:card_area(r, "start", function()
    local body = self:start_card()
    if body == nil then return nil end
    local B = require("conjunction.ui.qb_widgets")
    local items = {W.leaf{w = body.w, h = body.h, min_w = body.w, fixed_h = body.h, hpol = "preferred",
                          draw = function(_, rr) B.bg = C.card body.draw(rr.x, rr.y, rr.w) end}}
    for _, n in ipairs(self:start_extras()) do items[#items + 1] = n end
    items[#items + 1] = W.stretch(1)
    return W.widget(W.vbox({margins = {0, 6, 6, 4}, spacing = 6}, items))
  end)
end

-- the card's tree in its scroll area, kept (MaximdeWinter 14.11.: the panel ran slow - made, measured and placed anew each
-- frame the start card took 7 of its 9 ms, drawing it 2): made again only when what it shows may have changed - the
-- quest saved or synced (data_ver), the room, the card, a picker open, the field typed in and its text, the editor
-- waiting - and at the latest after CARD_KEEP s (what changes elsewhere: the world's objects, pictures made). It is
-- drawn each frame: under the mouse, clicks and typing stay live. make() -> the tree or nil
QBD.CARD_KEEP = 0.5
function QBD:card_area(r, id, make)
  local W = require("conjunction.ui.qw")
  local B = require("conjunction.ui.qb_widgets")
  B.EDIT_STYLE, B.window, B.bg = self.panel.EDIT_STYLE, self.panel.rect, C.card
  B.list_bg = LIST_BG
  local typed = ""
  if CT.focus then
    local ok, t = pcall(function() local e = CT.state(CT.focus).e return e and e:text() or "" end)
    typed = ok and tostring(t) or ""
  end
  local key = table.concat({id, self.data_ver or 0, r.w, r.h, tostring(self.open_picker and self.open_picker[2]),
                            tostring(self.waiting and self.waiting[1]), tostring(CT.focus), typed,
                            tostring(self.ed.project), tostring(self.ed.request)}, "|")
  local now = os.clock()
  local c = self.card_kept
  if not c or c.key ~= key or now - c.t > QBD.CARD_KEEP then
    local tree = make()
    if tree == nil then
      self.card_kept = nil
      return
    end
    local min_w, min_h = W.min(tree)
    local function need(w) return math.max(min_h, W.hfw(tree, math.max(w, min_w))) end
    c = {key = key, t = now, tree = tree, need = need(r.w)}
    c.bar = c.need > r.h
    c.vw = c.bar and r.w - 10 or r.w
    c.bw = math.max(c.vw, min_w)
    c.bh = math.max(r.h, need(c.bw))
    self.card_kept = c
  end
  self.card_need = c.need
  self.card_bar = self.card_bar or IV.bar(1, 0, 0)
  local sb = self.card_bar
  sb.page = r.h
  IV.range(sb, c.bh - r.h)
  local hovered = CT.over({x = r.x, y = r.y, w = c.vw, h = r.h})
  local _, _, wheel = w3.ui.mouse()
  if hovered and wheel ~= 0 then IV.set(sb, sb.value - math.floor(wheel * 3 * 20 + 0.5)) end     -- (3 lines of 20)
  local at = r.x .. "," .. (r.y - sb.value)
  if c.placed ~= at then
    W.place(c.tree, r.x, r.y - sb.value, c.bw, c.bh)
    c.placed = at
  end
  self.card_tree = c.tree
  D.clip(r.x, r.y, c.vw, r.h, function() W.draw(c.tree) end)
  -- (a click in it may change what it shows without a save - a section opened, a list: made anew next frame)
  if (hovered or CT.over(r)) and (w3.ui.mouse_released(1) or w3.ui.mouse_released(2)) then c.t = -math.huge end
  if c.bar then
    self.bar_state = self.bar_state or {}
    SBAR.draw(self.bar_state, "qb.card_bar", sb, {x = r.x + c.vw, y = r.y, w = 10, h = r.h}, "v",
              function(hid, rr) return CT.hit_box(hid, rr) end)
  end
end

-- under QUEST STARTS: the people's search when + NPC is open, then what belongs to the whole quest - its own items
-- (questboard._fill_alive, _quest_extras)
function QBD:start_extras()
  local out = {}
  if self.open_picker and self.open_picker[2] == "alive" then
    out[#out + 1] = self:search_list({}, "alive", "people", "alive", function(ref) self:alive_add(ref) end)
  end
  local q = self:quest()
  if P.T(P.get(q, "items")) then out[#out + 1] = self:own_items() end
  local B = require("conjunction.ui.qb_widgets")
  local swaps = self:swaps()
  for _, sid in ipairs(Y.keys(swaps)) do out[#out + 1] = self:swap_card(sid) end
  for k, cs in ipairs(self:cutscene_swaps()) do out[#out + 1] = self:cutscene_card(k, cs) end
  if require("conjunction.features").experimental() then     -- (a game scene / cutscene replaced: the game's files)
    out[#out + 1] = B.row({B.button("qb.add_swap", "+ game scene", function() self:choose_scene(function(sw)
      self:add_swap(sw)
    end) end, "plus", {tip = "qb.add_swap"}),
                           B.button("qb.add_cutscene", "+ game cutscene", function() self:add_cutscene_swap() end,
                                    "plus", {tip = "qb.add_cutscene"}), B.gap()})
  end
  return out
end

-- the game's depot (opened once: the cutscenes' and scenes' files)
function QBD:depot()
  if self.depot_ == nil then
    self.depot_ = require("conjunction.depot").open(require("conjunction.config").load().game)
  end
  return self.depot_
end

-- a QLabel#field of a fixed width (its text cut at the edge, as a QLabel's)
local function fixed_field(text, w, colour)
  local B = require("conjunction.ui.qb_widgets")
  local f = B.label(text, colour, 12)
  local draw = f.draw_fn
  f.o.w, f.o.min_w, f.o.fixed_w, f.o.max_w = w, w, w, w
  f.draw_fn = function(n, r) D.clip(r.x, r.y, r.w, r.h, function() draw(n, r) end) end
  return f
end

-- a leaf's tooltip while the mouse is over it: a TIPS key, or {title, text} (a QLabel's setToolTip)
local function with_tip(n, id, tip)
  local draw = n.draw_fn
  n.draw_fn = function(node, r)
    draw(node, r)
    local _, hovered = CT.hit_box(id, r)
    local t = type(tip) == "function" and tip() or tip
    if hovered and t then CT.tip(id, t) end
  end
  return n
end

-- --- the game's scenes replaced (questboard.swaps, _add_swap, _remove_swap, _swap_card)
function QBD:swaps()
  return P.or_(P.get(self.ed.project.meta, "swaps"), Y.map())
end

function QBD:swap_steps()
  local out = {}
  local swaps = self:swaps()
  for _, sid in ipairs(Y.keys(swaps)) do
    local ins = P.or_(P.get(swaps[sid], "inputs"), Y.map())
    for _, k in ipairs(Y.keys(ins)) do out[#out + 1] = ins[k] end
  end
  return out
end

function QBD:add_swap(swap)
  local S = require("conjunction.pystr")
  local base = swap.scene:match("([^\\]*)$")
  base = S.lower(base:match("^(.*)%.[^.]*$") or base)
  local clean = {}
  for _, cp in ipairs(S.cps(base)) do
    local c = utf8.char(cp)
    clean[#clean + 1] = S.isalnum(c) and c or "_"
  end
  local cps = clean
  local function first(n) return table.concat(cps, "", 1, math.min(n, #cps)) end
  local meta = self.ed.project.meta
  local swaps = P.get(meta, "swaps")
  if not Y.is_map(swaps) then
    swaps = Y.map()
    meta.swaps = swaps
  end
  local sid, n = first(32), 2
  if sid == "" then sid = "scene" end
  while swaps[sid] ~= nil do
    sid = first(30) .. "_" .. n
    n = n + 1
  end
  swaps[sid] = swap
  self:save()
end

function QBD:remove_swap(sid)
  local meta = self.ed.project.meta
  local swaps = P.get(meta, "swaps")
  if Y.is_map(swaps) then Y.remove(swaps, sid) end
  if not P.T(P.get(meta, "swaps")) then Y.remove(meta, "swaps") end
  self:save()
end

-- a game scene replaced: per way in a talk (Edit dialogue), where it goes on when the talk simply ends; a plain
-- warning about saves (a #card, its left edge #b99be6, margins 8 6 8 8, 5 apart)
function QBD:swap_card(sid)
  local W = require("conjunction.ui.qw")
  local B = require("conjunction.ui.qb_widgets")
  local QC = require("conjunction.ui.quest_card")
  local D2 = require("conjunction.dialogue")
  local SS = require("conjunction.scene_swap")
  local sw = self:swaps()[sid]
  local o = sw.outline
  local name = B.label(P.str(P.or_(P.get(sw, "name"), sw.scene)), 0xf0f0f0ff, 13, true)
  with_tip(name, "qb.swap_name." .. sid, {"", P.str(sw.scene)})
  name.stretch = 1
  local v = {B.row({B.label("REPLACES", 0x9a9a9aff, 11, true), name,
                    B.icon("qb.swap_remove." .. sid, "trash-2", function() self:remove_swap(sid) end,
                           {tip = "qb.swap_remove"})}, false)}
  local warn = B.label("saves inside this quest may break", 0xe3c65fff, 12)
  with_tip(warn, "qb.swap_saves." .. sid, "qb.swap_saves")
  v[#v + 1] = warn
  local outs = P.T(P.get(o, "outputs")) and o.outputs or {SS.DEFAULT_OUT}
  local ins = P.list(P.get(o, "inputs"))
  local many = #ins > 1
  if not Y.is_map(P.get(sw, "inputs")) then sw.inputs = Y.map() end
  for k, i in ipairs(ins) do
    local iname = P.str(P.get(i, "name"))
    local st = sw.inputs[iname]
    if st == nil then
      st = Y.map({"talk", Y.map({"swap", true, "input", iname, "dialogue", Y.list({})})})
      sw.inputs[iname] = st
    end
    local a = st.talk
    local lines = P.list(P.get(a, "dialogue"))
    local where = fixed_field((many or iname ~= SS.DEFAULT_IN) and ("at " .. P.replace(iname, "_", " ")) or "dialogue",
                              220)
    local why = P.get(P.or_(P.get(sw, "not_loaded"), Y.map()), iname)
    local what_text = #lines > 0 and D2.summary(lines) or P.T(why) and ("empty - the game's has " .. P.str(why)) or
                      "Empty: the game continues at once"
    local what = fixed_field(what_text, 190)
    if P.T(why) and #lines == 0 then
      with_tip(what, "qb.swap_what." .. sid .. "." .. k, {"", "Replaces the game's dialogue at this point"})
    end
    local edit = B.button("qb.swap_edit." .. sid .. "." .. k, "Edit dialogue", function() self:open_dialogue(st) end,
                          nil, {tip = "qb.swap_edit"})
    local then_ = P.get(a, "then")
    local has = false
    for _, x in ipairs(outs) do if x == then_ then has = true end end
    if not has then then_ = outs[math.min(k, #outs)] end
    local entries = {}
    for _, x in ipairs(outs) do entries[#entries + 1] = {x, P.replace(x, "_", " ")} end
    local then_b
    if #outs > 1 then
      then_b = B.menu("qb.swap_then." .. sid .. "." .. k, "At end: " .. P.replace(then_, "_", " "), entries, then_,
                      function(key) self:set_in(a, "then", key) end, {tip = "qb.swap_then"})
    else                                         -- (one way out: nothing to choose, the button greyed)
      then_b = B.tool("qb.swap_then." .. sid .. "." .. k, "At the end: continue", {colour = T.DISABLED_TEXT,
                                                                                  tip = "qb.swap_then"})
    end
    v[#v + 1] = B.row({where, what, edit, then_b, B.gap()})
  end
  return QC.card_frame(v, "#b99be6", 5)
end

-- --- the game's cutscenes replaced, in every game scene that plays them (questboard.cutscene_swaps ...)
function QBD:cutscene_swaps()
  return P.list(P.get(self.ed.project.meta, "cutscene_swaps"))
end

function QBD:add_cutscene_swap()
  local meta = self.ed.project.meta
  if not Y.is_list(P.get(meta, "cutscene_swaps")) then meta.cutscene_swaps = Y.list({}) end
  meta.cutscene_swaps[#meta.cutscene_swaps + 1] = Y.map({"old", "", "new", ""})
  self:save()
end

function QBD:remove_cutscene_swap(k)
  local meta = self.ed.project.meta
  local cs = P.get(meta, "cutscene_swaps")
  if Y.is_list(cs) and k <= #cs then table.remove(cs, k) end
  if not P.T(P.get(meta, "cutscene_swaps")) then Y.remove(meta, "cutscene_swaps") end
  self:save()
end

-- a search over the game's cutscenes ("replace" / "with" before it, 52 wide); the one chosen is cs[key] - a
-- QLineEdit with a QCompleter (the names holding the text, any case, 16 shown)
function QBD:cutscene_pick(k, cs, key, word, more)
  local W = require("conjunction.ui.qw")
  local B = require("conjunction.ui.qb_widgets")
  local CSW = require("conjunction.cutscene_swap")
  local IM = require("conjunction.ui.inline_menu")
  local S = require("conjunction.pystr")
  local depot = self:depot()
  self.cutscene_names = self.cutscene_names or {}
  local names = self.cutscene_names
  if names.list == nil then
    names.list, names.by = {}, {}
    for _, p in ipairs(CSW.all_cutscenes(depot)) do
      local lab = CSW.label(p)
      if names.by[lab] ~= nil then
        local parts = {}
        for x in p:gmatch("[^\\]+") do parts[#parts + 1] = x end
        lab = lab .. "  (" .. (parts[#parts - 1] or "") .. ")"
      end
      if names.by[lab] == nil then names.list[#names.list + 1] = lab end
      names.by[lab] = p
    end
  end
  local id = "qb.cutscene_" .. key .. "." .. k
  local now = P.str(P.get(cs, key) or "")
  local function chosen(text)
    if names.by[text] ~= nil and names.by[text] ~= P.get(cs, key) then
      cs[key] = names.by[text]
      if key == "new" then Y.remove(cs, "file") end    -- (a game cutscene again, not the own file)
      self:save()
    end
  end
  local pick = W.leaf{w = 17 * Q.text_w("x") + 16, h = CT.edit_h(B.EDIT_STYLE), min_w = 42, hpol = "expanding",
                      vpol = "fixed", draw = function(_, r)
    local st = CT.state(id)
    if st.src ~= now then                        -- (the field shows the one chosen)
      st.src = now
      st.text = now ~= "" and CSW.label(now) or ""
    end
    local changed, t = CT.edit(id, r.x, r.y, r.w, st.text or "", {
      placeholder = "Search the game's cutscenes (" .. #names.list .. ")", style = B.EDIT_STYLE, tip = "qb.cutscene_" .. key,
      h = r.h})
    st.text = t
    if changed then
      local low = S.lower(t)
      local items = {}
      if low ~= "" then
        for _, lab in ipairs(names.list) do
          if S.lower(lab):find(low, 1, true) then
            items[#items + 1] = {text = lab, action = function()
              st.text = lab
              chosen(lab)
            end}
            if #items >= 16 then break end
          end
        end
      end
      if #items > 0 then
        IM.open(id .. ".list", {x = r.x, y = r.y, w = r.w, h = r.h}, items, B.window, {bg = B.list_bg})
      elseif IM.is_open(id .. ".list") then
        IM.close()
      end
    end
  end}
  pick.stretch = 1
  return B.row({fixed_field(word, 52), pick, more}, false)
end

-- an own cutscene (a cooked .w2cutscene) plays instead: the build puts it into the mod bundle
function QBD:cutscene_file(cs, path)
  local CSW = require("conjunction.cutscene_swap")
  local function take(f)
    if f and f ~= "" then
      cs.file = f
      cs.new = CSW.depot_path(f)
      self:save()
    end
  end
  if path then return take(path) end
  require("conjunction.ui.dialogs").pick_file(self.ed, "Custom cutscene", "", "Cutscenes (*.w2cutscene)", take)
end

-- a game cutscene replaced by another: which, by which; where it plays, the lengths, what may not fit (a #card,
-- its left edge #b99be6)
function QBD:cutscene_card(k, cs)
  local W = require("conjunction.ui.qw")
  local B = require("conjunction.ui.qb_widgets")
  local QC = require("conjunction.ui.quest_card")
  local CSW = require("conjunction.cutscene_swap")
  local gap = B.gap()
  gap.stretch = 1
  local v = {B.row({B.label("CUTSCENE", 0x9a9a9aff, 11, true), gap,
                    B.icon("qb.cutscene_remove." .. k, "trash-2", function() self:remove_cutscene_swap(k) end,
                           {tip = "qb.cutscene_remove"})}, false)}
  v[#v + 1] = self:cutscene_pick(k, cs, "old", "replace")
  if not P.T(P.get(cs, "old")) then return QC.card_frame(v, "#b99be6", 5) end
  local depot = self:depot()
  local old = CSW.info(depot, cs.old)
  local scenes = {}
  for _, sc in ipairs(old.scenes) do scenes[#scenes + 1] = CSW.label(sc) end
  local where = B.field(#scenes == 1 and ("plays in " .. scenes[1]) or #scenes > 0 and
                        ("plays in " .. #scenes .. " scenes") or "no scene plays it")
  if #old.scenes > 0 then with_tip(where, "qb.cutscene_where." .. k, {"", table.concat(old.scenes, "\n")}) end
  v[#v + 1] = where
  local file_b = B.button("qb.cutscene_file." .. k, "File...", function() self:cutscene_file(cs) end, nil,
                          {tip = "qb.cutscene_file"})
  v[#v + 1] = self:cutscene_pick(k, cs, "new", "with", file_b)
  if P.T(P.get(cs, "file")) then
    local own = B.field(P.str(cs.file))
    v[#v + 1] = own
  end
  if P.T(P.get(cs, "new")) then
    local file = P.T(P.get(cs, "file")) and cs.file or nil
    local new = CSW.info(depot, cs.new, file)
    v[#v + 1] = B.field(string.format("%.0f s - now %.0f s", old.duration, new.duration))
    for _, pr in ipairs(CSW.problems(depot, cs.old, cs.new, file)) do
      v[#v + 1] = B.label(pr, 0xe3c65fff, 12)
    end
  end
  return QC.card_frame(v, "#b99be6", 5)
end

function QBD:alive_add(ref)
  local q = self:quest()
  local alive = P.get(q, "keep_alive")
  if not P.T(alive) then
    alive = Y.list({})
    q.keep_alive = alive
  end
  local have = false
  for _, x in ipairs(alive) do if x == ref then have = true end end
  if not have then alive[#alive + 1] = ref end
  self.open_picker = nil
  self:save()
end

-- an own item more: "A letter" (letter1, letter2 ...); its card is the start's (questboard._add_own_item)
function QBD:add_own_item()
  local q = self:quest()
  local items = P.get(q, "items")
  if not Y.is_map(items) then
    items = Y.map()
    q.items = items
  end
  local n = 1
  while items["letter" .. n] ~= nil do n = n + 1 end
  items["letter" .. n] = Y.map({"name", "A letter", "description", "", "text", ""})
  self:save()
end

-- the quest's own items: a name, a line for the inventory, the text Geralt reads (none: not readable)
-- (questboard._own_items: a #card, margins 8 6 8 8, 4 apart)
function QBD:own_items()
  local W = require("conjunction.ui.qw")
  local B = require("conjunction.ui.qb_widgets")
  local QC = require("conjunction.ui.quest_card")
  local IC = require("conjunction.ui.item_chooser")
  local q = self:quest()
  local v = {B.label("QUEST ITEMS", 0x9a9a9aff, 11, true)}
  for _, iid in ipairs(Y.keys(P.get(q, "items"))) do
    local it = q.items[iid]
    local name = QC.text_line(self, it, "name", "name in the inventory", {tip = "qb.own_name"})
    name.stretch = 1
    v[#v + 1] = B.row({B.field("name"), name, B.icon("qb.own_remove." .. iid, "trash-2", function()
      IC.drop_item(q, iid)
      self:save()
    end, {tip = "qb.own_remove"})}, false)
    -- (what it is made from and where it is used, kept 1 s: the item's label from the database and the walk over
    -- every step each frame were 3.6 ms of the start card's, 14.11.)
    local memo = self.item_facts
    if not memo or os.clock() - memo.t > 1 then
      memo = {t = os.clock()}
      self.item_facts = memo
    end
    local text = memo[iid]
    if not text then
      local facts = {}
      if P.T(P.get(it, "base")) then facts[#facts + 1] = "made from " .. self:item_label(it.base) end
      local uses = {}
      for _, ns in ipairs(IC.numbered_steps(q)) do
        if IC.names(ns[2], "own:" .. iid) then uses[#uses + 1] = "step " .. P.str(ns[1]) .. " (" .. Y.keys(ns[2])[1] .. ")" end
      end
      facts[#facts + 1] = #uses > 0 and ("used in " .. table.concat(uses, ", ")) or "not used yet"
      text = table.concat(facts, "  ·  ")
      memo[iid] = text
    end
    -- (a QLabel, #9a9a9a 11 px, word wrap: as high as its lines at the width it gets)
    local TL = require("conjunction.ui.textlayout")
    local lh = Q.line_h(11)
    v[#v + 1] = W.leaf{w = Q.hint_w(text, 11), h = lh, min_w = 0, hpol = "preferred",
                       hfw = function(w) return math.max(1, #TL.wrap(text, 11, false, math.max(0, w), "word")) * lh end,
                       draw = function(_, rr)
      for i, l in ipairs(TL.wrap(text, 11, false, math.max(0, rr.w), "word")) do
        Q.text(rr.x, rr.y + (i - 1) * lh, 0x9a9a9aff, l.s, 11, false, B.bg)
      end
    end}
    v[#v + 1] = QC.text_line(self, it, "description", "a line under the name")
    v[#v + 1] = B.autotext("qb.own_text." .. iid, P.str(P.get(it, "text", "")), "text to read (empty: a plain quest item)",
                           function(t)
      local PYS = require("conjunction.pystr")
      QC.set_in(self, it, "text", P.T(PYS.strip(t)) and PYS.strip(t) or nil, false)
    end, {tip = "qb.own_text"})
  end
  return QC.card_frame(v, nil, 4)
end

-- what an item reference is called: an own item's name, a game item's label (item_chooser.item_label)
function QBD:item_label(ref)
  ref = P.str(ref)
  if ref:sub(1, 4) == "own:" then
    local it = P.get(P.get(self:quest(), "items") or Y.map(), ref:sub(5))
    return P.str(P.or_(P.get(it or Y.map(), "name"), ref:sub(5)))
  end
  local db = self.ed.assets and self.ed:assets()
  local row = db and db.item and db:item(ref) or nil
  return row and P.str(P.or_(row.label, row.name, ref)) or ref
end

-- a step's card (ui/quest_card.lua) in the scroll area: the body a column (margins 0 6 6 4, 6 apart, a stretch
-- under the card), as wide as the viewport or its minimum, as high as the viewport or its minimum
function QBD:draw_tree_card(r, node)
  local W = require("conjunction.ui.qw")
  local QC = require("conjunction.ui.quest_card")
  -- (QScrollArea with a widget whose layout has a height for its width: as high as that at the width it gets)
  self:card_area(r, "node:" .. tostring(node.id) .. ":" .. tostring(node), function()
    local card = QC.build(self, node)
    if card == nil then return nil end
    return W.widget(W.vbox({margins = {0, 6, 6, 4}, spacing = 6}, {card, W.stretch(1)}))
  end)
end

-- --- what the cards ask of the board
function QBD:node_of(step)
  for nid, n in pairs(self:graph_quest().nodes) do if n.step == step then return nid end end
  return nil
end

-- (place, index) of an object reference, or nil
function QBD:find(ref)
  if not P.T(ref) then return nil end
  local s = P.str(ref)
  local cut = s:find("/", 1, true)
  local place, oid = cut and s:sub(1, cut - 1) or s, cut and s:sub(cut + 1) or ""
  local p = (self.ed.project.places or {})[place]
  for k, o in ipairs(P.list(P.get(p, "objects"))) do
    if P.get(o, "id") == oid then return {place, k} end
  end
  return nil
end

function QBD:toggle_picker(a, key, ident, on_set, world, many)
  if on_set then self.picker_on_set = on_set end
  self.picker_world = world                      -- (the kind of object of the world the action can take)
  self.picker_many = many                        -- (several at once: the action's more_targets take the rest)
  if self.open_picker and self.open_picker[1] == ident and self.open_picker[2] == key then
    self.open_picker = nil
  else
    self.open_picker = {ident, key}
  end
  self:sync()
end

-- the target's list (questboard._search_list): pick it in the world, create a new one, go to the chosen one - then
-- everything of its kind already placed (a click takes it, Show goes there), narrowed by what is typed above them
function QBD:search_list(a, key, what, ident, on_set)
  local W = require("conjunction.ui.qw")
  local B = require("conjunction.ui.qb_widgets")
  local QS = require("conjunction.quest")
  local PYS = require("conjunction.pystr")
  local sid = ident .. "." .. key
  local items = {
    B.button("qb.pick." .. sid, "Pick in world",
             function() self:request(a, key, what, "pick", ident, on_set, self.picker_world, self.picker_many) end,
             "doit", {tip = "qb.pick_" .. what}),
    B.button("qb.create." .. sid, "Create New",                      -- (MaximdeWinter 24.10.: was "Create a new thing")
             function() self:request(a, key, what, "create", ident, on_set) end, "doit", {tip = "qb.create_" .. what}),
  }
  local found = self:find(P.get(a, key))
  if found then
    items[#items + 1] = B.button("qb.goto." .. sid, "Go to", function() self.ed:jump_to(found[1], found[2]) end,
                                 "doit", {tip = "qb.jump"})
  end
  local places = self.ed.project.places or {}
  local names = {}
  for name in pairs(places) do names[#names + 1] = name end
  table.sort(names)
  local MARK = {moves = "talks", shut = "No lip sync", none = "No lip sync", maybe = "Random look", animal = "animal"}
  local rows = {}
  for _, place in ipairs(names) do
    for k, o in ipairs(P.list(P.get(places[place], "objects"))) do
      local skip = ((what == "people" or what == "creatures") ~= QS.is_actor(o)) or
                   (what == "containers" and not self:holds_items(o)) or
                   (what == "loot" and QS.not_loot(o.template) ~= nil)
      if not skip then
        local base = P.str(o.template):match("([^\\]*)$")
        local stem = base:match("^(.*)%.[^.]*$") or base
        local name = P.str(P.or_(P.get(o, "display"), P.replace(P.str(P.or_(P.get(o, "id"), stem)), "_", " ")))
        local at = sid .. "." .. place .. "." .. k
        local entry = B.button("qb.take." .. at, name, function() self:picked(a, key, {place, k}, on_set) end, "entry",
                               {tip = "qb.take"})
        entry.stretch = 1
        local jump = B.button("qb.show." .. at, "Show", function() self.ed:jump_to(place, k) end, "small",
                              {tip = "qb.jump"})
        local row
        if what == "people" then                  -- (whose mouth moves when they talk)
          local state = self:mouth(o)
          local mark = B.label(MARK[state] or "", (state == "shut" or state == "none" or state == "maybe") and 0xd6a65aff
                               or 0x8a8a8eff, 12)
          row = B.row({entry, mark, B.field(place), jump}, false)
        else
          row = B.row({entry, B.field(place), jump}, false)
        end
        rows[#rows + 1] = {PYS.lower(name), row}
      end
    end
  end
  if #rows > 0 then
    local fid = "qb.find." .. sid
    items[#items + 1] = B.find(fid, string.format("Or one already placed (%d)", #rows), {tip = "qb.search_name"})
    local typed = PYS.lower(B.found(fid))
    for _, r in ipairs(rows) do
      if r[1]:find(typed, 1, true) then items[#items + 1] = r[2] end
    end
  end
  local was
  return W.widget(W.vbox({margins = {4, 4, 4, 4}, spacing = 1}, items), {
    margins = {1, 1, 1, 1},
    draw = function(_, r)
      D.fill(r.x, r.y, r.w, r.h, B.C.list)
      D.rect(r.x, r.y, r.w, r.h, B.C.list_edge, 1)
      was, B.bg = B.bg, B.C.list
    end,
    after = function() B.bg = was end,
  })
end

-- (questboard._holds_items) a template with an inventory, something to loot
function QBD:holds_items(o)
  local db = self.ed.assets and self.ed:assets()
  local row = db and db.template and db:template(o.template) or nil
  return row ~= nil and P.T(row.inventory) and require("conjunction.quest").lootable(o.template)
end

-- whether this person's mouth moves when they talk (questboard._mouth): moves, shut, none, maybe, animal; nil: not
-- known (no game to look in)
function QBD:mouth(o)
  local TK = require("conjunction.talking")
  local ok, state = pcall(function()
    local st = TK.mouth(o.template, P.get(o, "appearance"))
    if st == "none" then
      local have = TK.known_anims(o.template)
      if have == nil or next(have) == nil then return "animal" end
    end
    return st
  end)
  if ok then return state end
  return nil
end

-- one of those placed taken (questboard._picked)
function QBD:picked(a, key, where, on_set)
  local oid = self.ed.project:name_object(where[1], where[2])
  self.open_picker = nil
  self:take_ref(a, key, where[1] .. "/" .. oid, on_set)
end

-- a chosen object: into the field, or to where the field hands it (several targets) (questboard._take_ref)
function QBD:take_ref(a, key, ref, on_set)
  if on_set then on_set(ref) else require("conjunction.ui.quest_card").set_in(self, a, key, ref) end
end

-- the pick list's Test for a Lights step: its on or off (slowly: faded, a light with a flame at once all the same)
-- on the lights picked -> a function that gives each its own state back
function QBD:light_test(a)
  local WP = require("conjunction.world_pick")
  return function(cands)
    local on = P.str(P.get(a, "state", "on")) ~= "off"
    local before = {}
    for _, c in ipairs(cands) do
      local ok, comp = pcall(function() return c.e:GetComponentByClassName("CGameplayLightComponent") end)
      if ok and comp then
        local okb, was = pcall(function() return comp:IsLightOn() end)
        before[#before + 1] = {comp, okb and was == true}
        local slow = P.T(P.get(a, "slow")) and not WP.has_flame(self.ed.project, c)
        pcall(function() if slow then comp:SetFadeLight(on) else comp:SetLight(on) end end)
        -- (at once: the flame's effect - the glowing glass with it - ends now too; CjLights does the same)
        if not slow and not on then pcall(function() c.e:DestroyAllEffects() end) end
      end
    end
    return function()
      for _, b in ipairs(before) do pcall(function() b[1]:SetLight(b[2]) end) end
    end
  end
end

-- what the step does, to choose in the pick list (ui/pick_list.lua): a Lights step on or off, at once or slowly;
-- a Door step opens, closes, locks, unlocks (nil: nothing to choose there)
function QBD:pick_settings(a, world)
  local QB = require("conjunction.questboard")
  local function choice(label, key, default, choices)
    return {label = label, choices = choices,
            get = function() return P.str(P.get(a, key, default)) end,
            set = function(v)
              a[key] = v
              self:save()
              self:sync()
            end}
  end
  local function capital(list)
    local out = {}
    for _, c in ipairs(list) do out[#out + 1] = {c[1], (c[1]:gsub("^%l", string.upper))} end
    return out
  end
  if world == "light" then
    local slow = choice("Speed", "slow", "", {{"", "Instant"}, {"true", "Slowly"}})
    slow.get = function() return P.T(P.get(a, "slow")) and "true" or "" end
    slow.set = function(v)
      if v == "true" then a.slow = true else Y.remove(a, "slow") end
      self:save()
      self:sync()
    end
    -- (a flame goes out at once only: Slowly there for lights without one)
    local WP = require("conjunction.world_pick")
    slow.shown = function(picked)
      for _, c in ipairs(picked) do if WP.has_flame(self.ed.project, c) then return false end end
      return true
    end
    return {choice("Light", "state", "on", capital(QB.LIGHTS)), slow}
  end
  if world == "door" then return {choice("Door", "state", "open", capital(QB.DOOR))} end
  return nil
end

-- the step's object and the ones beside it (target, more_targets) -> refs
function QBD.target_refs(a)
  local refs = {}
  if P.T(P.get(a, "target")) then refs[#refs + 1] = P.str(a.target) end
  for _, t in ipairs(P.list(P.get(a, "more_targets"))) do if P.T(t) then refs[#refs + 1] = P.str(t) end end
  return refs
end

-- Select on a step with things chosen: the pick with its list filled with them; Enter or Done puts the list in
-- their place (MaximdeWinter 12.11.: the card shows one line, not the whole list)
function QBD:edit_targets(a, what, ident, world)
  local WP = require("conjunction.world_pick")
  local picked = {}
  for _, ref in ipairs(QBD.target_refs(a)) do
    if WP.is_ref(ref) then
      local c = WP.candidate(self.ed.project, ref)
      if c then picked[#picked + 1] = c end
    else
      local found = self:find(ref)
      local o = found and P.list(P.get((self.ed.project.places or {})[found[1]], "objects"))[found[2]]
      local op = o and P.get(o, "pos")
      picked[#picked + 1] = {ref = ref, name = ref:match("/(.+)$") or ref,
                             pos = (type(op) == "table" and #op >= 3) and {tonumber(op[1]), tonumber(op[2]), tonumber(op[3])} or nil,
                             go = found and function() self.ed:jump_to(found[1], found[2]) end or nil}
    end
  end
  self.open_picker = nil
  self.waiting = {ident, "target", "pick"}
  local o = {world = world, picked = picked, edit = true}
  o.world_many = function(refs)
    self.waiting = nil
    if #refs == 0 then Y.remove(a, "target") else a.target = refs[1] end
    local more = Y.list({})
    for i = 2, #refs do more[#more + 1] = refs[i] end
    if #more > 0 then a.more_targets = more else Y.remove(a, "more_targets") end
    self:save()
    self:sync()
  end
  o.world_done = function(ref) o.world_many({ref}) end
  if world == "light" then o.test = self:light_test(a) end
  o.settings = self:pick_settings(a, world)
  self.ed:request_object("pick", what, function() end, nil, nil, o)
  self:sync()
end

-- Pick / Create: the editor waits for the object; the step takes it when it comes; Create first asks which one
-- (questboard._request)
function QBD:request(a, key, what, how, ident, on_set, world, many)
  local w = self.waiting
  if w and w[1] == ident and w[2] == key and w[3] == how then
    self.ed:cancel_request()
    return
  end
  self.open_picker = nil
  local function done(place, index)
    self.waiting = nil
    local title = how == "create" and self.chosen_title or nil
    self.chosen_title = nil
    local oid = self.ed.project:name_object(place, index, nil, title)
    self:take_ref(a, key, place .. "/" .. oid, on_set)
  end
  if how == "create" then
    self:choose(what, function(path)
      self.waiting = {ident, key, how}
      -- (Esc while placing: back in the chooser as it was left - its folder, the one shown; MaximdeWinter 13.11.: it led to
      -- the quest graph. Opened once the editor has shown the board again, the next frame)
      local c = self.taken_chooser
      self.ed:request_object(how, what, done, path, nil, {cancelled = function() self.chooser_again = c end,
                                                          look = self.chosen_look})
      self.chosen_look = nil
      self:sync()
    end)
    return
  end
  self.waiting = {ident, key, how}
  local o = nil
  if world and how == "pick" then              -- (an object of the world of that kind too: world_pick.lua)
    o = {world = world, world_done = function(ref)
      self.waiting = nil
      self:take_ref(a, key, ref, on_set)
      self:save()
    end}
    if world == "light" and not on_set then o.test = self:light_test(a) end   -- (the list's Test, live)
    if not on_set then o.settings = self:pick_settings(a, world) end
    if many and key == "target" and not on_set then  -- (Shift: the first its object, the others beside it)
      o.world_many = function(refs)
        self.waiting = nil
        self:take_ref(a, key, refs[1], nil)
        local more = P.list(P.get(a, "more_targets"))
        local have = {[P.str(P.get(a, "target"))] = true}
        for _, t in ipairs(more) do have[P.str(t)] = true end
        if P.get(a, "more_targets") == nil then a.more_targets = Y.list({}) end
        for i = 2, #refs do
          if not have[refs[i]] then a.more_targets[#a.more_targets + 1] = refs[i] have[refs[i]] = true end
        end
        if #a.more_targets == 0 then Y.remove(a, "more_targets") end
        self:save()
      end
    end
  end
  self.ed:request_object(how, what, done, nil, nil, o)
  self:sync()
end

-- --- the chooser (questboard.Chooser): which one to create - the catalog on its kind instead of the board; a click
-- shows it (the inspector beside it), Place (the inspector's, or a double click) takes it. 'clue_swap:<cat>/<sub>':
-- the clues of that kind
local CHOOSER_GROUP = {people = {"People", nil}, creatures = {"Creatures", nil}, clues = {"Gameplay", "Clues"},
                       containers = {"Containers", nil}}
local CHOOSER_TITLE = {people = "Place new NPC", creatures = "Place new creature", clues = "Place new clue",
                       containers = "Place new container"}

function QBD:choose(what, then_)
  self:close_chooser()
  local p = self.panel
  p:load_catalog()
  local swap = what:sub(1, 9) == "clue_swap"
  local c = {what = what, then_ = then_, entry = nil, name = "", why = nil, swap = swap,
             title = CHOOSER_TITLE[what] or (swap and "Swap for clue" or "Place new object")}
  self.chooser = c
  -- (a window over the board, as the item window: 12.11., the catalog in the board's place read as a page of its own)
  local w = p:open_win("chooser", c.title, "chooser", function(win)
    return require("conjunction.ui.object_chooser").new(self, win)
  end)
  w.title = c.title
  w.body:start(c)
end
-- the chooser's catalog on its kind (object_chooser.build, once the catalog is there)
function QBD:chooser_filter(c)
  local m = c.cv.model
  local what, swap = c.what, c.swap
  if what == "containers" or what == "loot" then     -- (Geralt's stash is no loot: not offered at all)
    local QS = require("conjunction.quest")
    m.hide = function(r) return QS.NOT_LOOT[P.str(r.class)] ~= nil end
  end
  if CHOOSER_GROUP[what] then
    m:show_only("type", CHOOSER_GROUP[what])
  elseif what == "loot" then
    m:refresh()
  elseif swap then                             -- (a clue of the same kind as the object it replaces)
    local rest = what:match("^[^:]*:(.*)$") or ""
    local cat, sub = rest:match("^([^/]*)/?(.*)$")
    m.quest = true
    m:show_only("trait", "clue")
    m.cat, m.sub = (cat ~= "" and cat or nil), (sub ~= "" and sub or nil)
    m:refresh()
  end
end

function QBD:close_chooser()
  if self.chooser == nil then return end
  self.chooser = nil
  local w = self.panel.windows and self.panel.windows.chooser
  if w and w.shown then w:close() end
end

-- why this one can not be the container asked for (Geralt's stash ...) or nil
function QBD:chooser_refused(e)
  local c = self.chooser
  if not c or (c.what ~= "containers" and c.what ~= "loot") or not e or not e.path then return nil end
  return require("conjunction.quest").not_loot(e.path)
end

function QBD:chooser_current(e)
  local c = self.chooser
  if not c then return end
  c.entry = (e and e.type == "template") and e or nil
  c.why = self:chooser_refused(c.entry)
  e = c.entry
  local shown = ""
  if e then shown = e.look ~= nil and (P.str(e.row and e.row.name) .. ", " .. P.str(e.sub)) or P.str(e.title) end
  c.name = c.why or shown
  local w = self.panel.windows and self.panel.windows.chooser
  if c.entry and w and w.body then w.body:show_entry(c.entry) end   -- (beside its catalog: the 3D view, the looks)
end

function QBD:chooser_take()
  local c = self.chooser
  if not c or not c.entry then return end
  if self:chooser_refused(c.entry) then          -- (the side card's Place comes here too)
    self:chooser_current(c.entry)
    return
  end
  local e = c.entry
  c.cv.model:remember(e)
  local path = e.path
  self.chosen_variants = e.members               -- (a folder: its variants)
  if e.members and #e.members > 0 then path = e.members[math.random(#e.members)] end
  -- (its id: 'blacksmith', not the template's file name; a look: the person's name, not the look's)
  self.chosen_title = e.look ~= nil and (e.row and e.row.name) or e.title
  -- (one look of a person: placed in exactly it - request_object's look; 13.11.: set as ed.place_look, a field
  -- nothing read, the person came in its first look)
  self.chosen_look = e.look
  local then_ = c.then_
  self:close_chooser()
  self.taken_chooser = c
  then_(path)
  self.taken_chooser = nil
end

-- the chooser c open again as it was (its catalog kept: c.cv), the one chosen shown beside it
function QBD:reopen_chooser(c)
  self:close_chooser()
  self.chooser = c
  local w = self.panel:open_win("chooser", c.title, "chooser", function(win)
    return require("conjunction.ui.object_chooser").new(self, win)
  end)
  w.title = c.title
  if c.cv then c.cv.host = w.body end           -- (its hit boxes and menus: the new window's, the old one is closed)
  w.body:start(c)
  if c.entry then self:chooser_current(c.entry) end
end

function QBD:choose_item(put, title, action, current)
  if self.panel.choose_item then self.panel:choose_item(put, title or "Item", {action = action, current = current}) end
end

function QBD:reward_item(a, k, ref)
  local items = P.copy_list(P.list(P.get(a, "items")))
  if k > #items then items[#items + 1] = ref or ""
  elseif ref then items[k] = ref
  else table.remove(items, k) end
  if #items > 0 then a.items = Y.list(items) else Y.remove(a, "items") end
  self:save()
end

-- a merchant never fights (questboard._merchant_note): said under the card
function QBD:merchant_note(v, refs)
  local QS = require("conjunction.quest")
  local B = require("conjunction.ui.qb_widgets")
  local names = {}
  for _, ref in ipairs(refs or {}) do
    local found = P.T(ref) and self:find(ref) or nil
    if found then
      local o = self.ed.project.places[found[1]].objects[found[2]]
      if QS.template_class(o.template) == "W3MerchantNPC" then
        names[#names + 1] = P.str(P.or_(P.get(o, "display"), P.get(o, "id"), ref))
      end
    end
  end
  if #names > 0 then
    v[#v + 1] = B.label(table.concat(names, ", ") .. ": a merchant (the game makes merchants invulnerable, they never "
                        .. "fight or die)", 0xe3c65fff, 11)
  end
end

-- the talk's staging on a timeline (questboard.open_timeline): its scene in the game, the cutscene editor on its
-- first section - what one puts there is kept as the talk's layer and laid over its scene at every build
function QBD:open_timeline(st)
  local node
  for _, nid in ipairs(Y.keys(P.map(P.get(self:quest(), "nodes")))) do
    if rawequal(P.get(self:quest().nodes[nid], "step"), st) then node = nid break end
  end
  if node == nil or not node:match("^n%d+$") then
    self.panel:say("The timeline needs the talk as a node of the quest graph", 4000)
    return
  end
  local key = "s" .. node:sub(2)                 -- (its scene: <quest id>_s<node number>, quest.py node_number)
  local qid = P.str(self.ed.project:id())
  local path = "dlc\\dlc" .. qid .. "\\data\\scenes\\" .. qid .. "_" .. key .. ".w2scene"
  -- (not built yet: said, the workshop stays shut - it showed the depot's error)
  local okd, there = pcall(function()
    return require("conjunction.depot").open(require("conjunction.config").load().game):exists(path)
  end)
  if okd and not there then                     -- (asked, one click builds it: 11.11., a new scene stopped here)
    require("conjunction.ui.dialogs").question(self.ed, "Build & Play",
      "The timeline plays the scene in the game, so it has to be built first. Build & Play now?", function(a) if a == "yes" then self.ed:build_play_now() end end)
    return
  end
  self.panel:open_scenes(self.ed, function(win) self:timeline_in(win, st, path, key, qid) end)
end
function QBD:timeline_in(win, st, path, key, qid)
  local body = win and win.body
  if not body then return end
  body:open(path, key)
  -- (the one the talk is with: the preview puts Geralt in front of them, as the game does after E)
  local npc = P.get(P.get(st, "talk"), "npc")
  local place, id = tostring(npc or ""):match("^([^/]+)/(.+)$")
  body.partner = place and (qid .. "_" .. place .. "_" .. id) or nil
  -- (the scene names the one the talk is with NPC: the timeline shows the name the card gives them - 11.11.)
  if npc then
    local Q = require("conjunction.quest")
    local name = Q.display_names(self.ed.project)[P.str(npc)] or require("conjunction.dialogue")._label(npc)
    body.actor_names = (name and name ~= "") and {NPC = P.str(name)} or nil
  end
  local sec
  for _, r in ipairs(body.w and body.rows or {}) do
    if r.kind == "section" and r.node then sec = r.node break end
  end
  if sec == nil then
    self.panel:say("Build & Play once: the timeline needs the talk in the game", 5000)
    return
  end
  body:open_cut(sec)
end

-- the talk's dialogue instead of the board (questboard.open_dialogue); Back: the board again
function QBD:open_dialogue(st)
  self:close_dialogue(true)
  self.dialogue = require("conjunction.ui.dialogue_view").new(self, st)
  self.dialogue.on_back = function() self:close_dialogue() end
end

function QBD:close_dialogue(quiet)
  if self.dialogue == nil then return end
  self.dialogue = nil
  if not quiet then self:sync() end
end

-- the way drawn (or changed) in the world with the path tool; every point kept the moment it is set
-- (questboard._draw_path)
function QBD:draw_path(a)
  self.path_of = a
  local function done(points)
    self.path_of = nil
    if points and #points > 0 then a.path = Y.list(points) else Y.remove(a, "path") end
    self:save()
  end
  local function cancel()
    self.path_of = nil
    self:sync()
  end
  local function kept(points)
    a.path = Y.list(points)
    self:save(false)
  end
  if self.ed.path_tool ~= nil then self.ed.path_tool:finish() end
  require("conjunction.pathtool").new(self.ed, P.list(P.get(a, "path")), done,
                                      {label = "Way", on_cancel = cancel, on_change = kept}):start()
  self:sync()
end

-- Says: who speaks (questboard._say_speaker); a typed line is no longer the voiced one (_say_text)
function QBD:say_speaker(a, who)
  if who == "someone" then
    if P.get(a, "who") == nil and not P.has(a, "who") then a.who = "" end
    for _, key in ipairs({"voice", "dur", "voice_pack"}) do Y.remove(a, key) end
  else
    Y.remove(a, "who")
  end
  self:save()
end
function QBD:say_text(d, text)
  text = table.concat(require("conjunction.pystr").split(text), " ")
  if text ~= P.str(P.get(d, "text", "")) then
    Y.remove(d, "voice")
    Y.remove(d, "dur")
    require("conjunction.ui.quest_card").set_in(self, d, "text", text ~= "" and text or nil)
  end
end
-- the game's journal portraits (journal_images.portraits: read once from the game, kept in Documents\Conjunction\data)
function QBD:portraits()
  if self.portrait_list == nil then
    local ok, names = pcall(require("conjunction.journal_images").portraits)
    local out = {}
    for _, p in ipairs(ok and type(names) == "table" and names or {}) do
      out[#out + 1] = {p, P.replace(p:sub(#"journal_" + 1, -5), "_", " ")}
    end
    self.portrait_list = out
  end
  return self.portrait_list
end

-- the game's notice boards in the quest's worlds (questboard._game_boards: the app's index of each world, nearest
-- to the camera first; a world not indexed yet is looked for now, once - a few minutes, the list says so)
QBD.SCANNING = {}
function QBD:game_boards()
  local J = require("conjunction.json")
  local PATHS = require("conjunction.paths")
  local worlds, seen = {}, {}
  for _, p in pairs(self.ed.project.places or {}) do
    local w = P.get(p, "world")
    if P.T(w) and not seen[w] then seen[w] = true worlds[#worlds + 1] = w end
  end
  require("conjunction.pysort").sort(worlds)
  local cam = (self.ed.cam and self.ed.cam.pos) or {0.0, 0.0, 0.0}
  local out = {{nil, "a board placed for the quest"}}
  local PYS = require("conjunction.pystr")
  local PYS_lower, PYS_strip = PYS.lower, PYS.strip
  local EN = require("conjunction.encounters")
  for _, w in ipairs(worlds) do
    local cache = EN.cache_path(w, "W3NoticeBoard")
    local ok, boards = false, nil
    if w3.fs.exists(cache) then ok, boards = pcall(J.read, cache) end
    if not ok or type(boards) ~= "table" then
      if not QBD.SCANNING[w] and self.ed.job then         -- (questboard._SCANNING: one search a world)
        QBD.SCANNING[w] = true
        self.ed:job(function() EN.index(w, function() end, "W3NoticeBoard") end)
      end
      out[#out + 1] = {"", "(looking for the boards of " .. w .. " - a few minutes)"}
    else
      local list = {}
      for _, b in ipairs(boards) do
        local d = math.sqrt((b.pos[1] - cam[1]) ^ 2 + (b.pos[2] - cam[2]) ^ 2)
        local tag
        for _, t in ipairs(b.tags or {}) do if PYS_lower(t):find("notice", 1, true) then tag = PYS_strip(t) break end end
        tag = tag or PYS_strip(b.tags[1])
        list[#list + 1] = {d, "tag:" .. tag, string.format("%s   %.0f m", P.replace(tag, "_", " "), d)}
      end
      list = require("conjunction.pysort").sorted(list, function(x) return x[1] end)   -- (stable, as sorted)
      for _, e in ipairs(list) do out[#out + 1] = {e[2], e[3]} end
    end
  end
  return out
end

-- under a talk's 'who': whether their mouth moves to the lines (questboard._mouth_row)
QBD.MOUTH = {moves = "mouth moves", shut = "this look: mouth stays shut", none = "no look of them moves the mouth",
             maybe = "random look: the game may give them one whose mouth stays shut",
             animal = "animal: no mouth movement"}
function QBD:mouth_row(ref)
  local found = self:find(ref)
  if not found then return nil end
  local o = self.ed.project.places[found[1]].objects[found[2]]
  local TK = require("conjunction.talking")
  local ok, state = pcall(function()
    local st = TK.mouth(o.template, P.get(o, "appearance"))
    if st == "none" then
      local have = TK.known_anims(o.template)
      if have == nil or next(have) == nil then return "animal" end
    end
    return st
  end)
  if not ok or state == nil then return nil end
  local B = require("conjunction.ui.qb_widgets")
  -- (wrapped: in one line the long notes made the card wider than the panel, its buttons beyond the edge)
  local lab = B.rich({{QBD.MOUTH[state], (state == "moves" or state == "animal") and 0x9a9a9eff or 0xd6a65aff}}, 12, true)
  lab.stretch = 1
  if state ~= "shut" and state ~= "maybe" then return B.row({B.field(""), lab}, false) end
  return B.row({B.field(""), lab, B.button("qb.talking_look." .. found[1] .. "." .. found[2], "Use talking look",
                                           function() self:talking_look(found[1], found[2]) end, "small",
                                           {tip = "qb.talking_look"})}, false)
end

-- the person gets the first look whose face can move its mouth (questboard._talking_look)
function QBD:talking_look(place, k)
  local TK = require("conjunction.talking")
  local o = self.ed.project.places[place].objects[k]
  local looks = TK.known_talking(o.template) or {}
  if #looks == 0 then return end
  if self.ed.project.set_object then self.ed.project:set_object(place, k, {"appearance", looks[1]}) end
  if self.ed.editing and place == self.ed.place and self.ed.exec then
    self.ed:exec(string.format('cj_appearance(%s, %s, %s, "%s")', P.str(o.pos[1]), P.str(o.pos[2]), P.str(o.pos[3]),
                               looks[1]))
  end
  self:sync()
end

function QBD:object_of(ref)
  local found = self:find(ref)
  return found and self.ed.project.places[found[1]].objects[found[2]] or nil
end
-- the effects the object's template defines (questboard._effect_names: fx.lua) - offered instead of a typed name
-- the names a thing of the world offers (world_pick.lua keeps them when it is picked): effects, parts, looks
function QBD:world_names(ref, what)
  local o = P.T(ref) and require("conjunction.world_pick").get(self.ed.project, P.str(ref)) or nil
  local out = {}
  for _, n in ipairs(P.list(o and P.get(o, what))) do out[#out + 1] = P.str(n) end
  return out
end

function QBD:effect_names(ref)
  if P.T(ref) and require("conjunction.world_pick").is_ref(P.str(ref)) then return self:world_names(ref, "effects") end
  local o = P.T(ref) and self:object_of(ref) or nil
  if o == nil then return {} end
  return require("conjunction.fx").effects_of(P.str(o.template))
end
function QBD:clue_after(c, key)
  if key == "talk" then
    if P.get(c, "dialogue") == nil then c.dialogue = Y.list({}) end
  else
    Y.remove(c, "dialogue")
  end
  self:save()
end
function QBD:add_trail(items, kind)
  items[#items + 1] = Y.map({"trail", Y.null, "kind", kind, "says", Y.map()})
  self:save()                                   -- (drawing it in the world: with the editor's requests)
end

function QBD:toggle_voice(d)
  self.open_voice = (self.open_voice ~= d) and d or nil
end
-- the next click into the world gives the point and its place's world (questboard._request_point)
function QBD:request_point(a, key)
  local ident = tostring(a):gsub("^table: ", "")
  local w = self.waiting
  if w and w[1] == ident and w[2] == key then
    self.ed:cancel_request()
    return
  end
  local function done(place, pos)
    self.waiting = nil
    a[key] = Y.list(pos)
    a.place = place                             -- (its world)
    if self.ed.world then a.world = self.ed.world end   -- (the place may be new and empty: the game's world)
    self:save()
  end
  self.waiting = {ident, key, "point"}
  self.ed:request_object("point", "point", done)
  self:sync()
end

-- Show / Hide place: shown by the quest, not from the start (questboard._set_place_action)
function QBD:set_place_action(a, kind, name)
  if kind == "show" then
    local p = self.ed.project.places[name]
    if p ~= nil and P.get(p, "visible") ~= "step" then
      p.visible = "step"
      if self.ed.project.save_place then self.ed.project:save_place(name) end
    end
  end
  require("conjunction.ui.quest_card").set_in(self, a, "place", name)
end                  -- (the path tool: with the editor's requests)

function QBD:wait_mode(a, untl)
  if untl then
    Y.remove(a, "time")
    a["until"] = "22:00"
  else
    Y.remove(a, "until")
    a.time = "00:00:10"
  end
  self:save()
end

-- the older If / Wait until (a fact, a branch) as the first of a list of conditions (questboard._to_conditions)
function QBD:to_conditions(a)
  if P.get(a, "conditions") == nil and not P.has(a, "conditions") then
    a.conditions = Y.list(require("conjunction.quest").conditions_of(a))
    for _, key in ipairs({"fact", "op", "value", "path", "from"}) do Y.remove(a, key) end
  end
  return a.conditions
end

function QBD:add_walk_talk(a)
  local talks = P.list(P.get(a, "talks"))
  local at = #talks + 1
  local entry = Y.map({"talk", Y.map({"npc", P.get(a, "who") or Y.null, "start", "overhear",
                                      "at", math.min(at, math.max(1, #P.list(P.get(a, "path")))),
                                      "dialogue", Y.list({Y.map({"who", "npc", "text", ""})})})})
  if P.get(a, "talks") == nil then a.talks = Y.list({}) end
  a.talks[#a.talks + 1] = entry
  self:save()
  self:open_dialogue(entry)
end
-- the spot's menu: go there, place it again, delete it from the world (questboard._spot)
function QBD:spot(a, k)
  local found = self:find(P.get(a, "at"))
  if not found then return end
  if k == "show" then
    self.ed:jump_to(found[1], found[2])
  elseif k == "again" then
    self:request_spot(a)
  elseif k == "remove" then
    self:remove_object(found[1], found[2])
    Y.remove(a, "at")
    self:save()
  end
end

-- a placed object out (in the game too: the editor deletes it where it stands) (questboard._remove_object)
function QBD:remove_object(place, index)
  local objs = self.ed.project.places[place].objects
  local o = objs[index]
  if place == self.ed.place then
    local pos = P.list(o.pos)
    self.ed:exec(string.format("cj_delete_at(%.3f, %.3f, %.3f)", pos[1], pos[2], pos[3]))
  else
    table.remove(objs, index)
    self.ed.project:save_place(place)
  end
end

-- the flag follows the cursor; the click that places it is the spot (questboard._request_spot)
function QBD:request_spot(a)
  local ident = tostring(a):gsub("^table: ", "")
  local w = self.waiting
  if w and w[1] == ident and w[2] == "at" and w[3] == "create" then
    self.ed:cancel_request()
    return
  end
  self.waiting = {ident, "at", "create"}
  local function done(place, index)
    self.waiting = nil
    local objs = self.ed.project.places[place].objects
    local taken = {}
    for _, o in ipairs(objs) do if o.id then taken[o.id] = true end end
    local n = 1
    while taken["spot" .. n] do n = n + 1 end
    self.ed.project:name_object(place, index, "spot" .. n)
    objs[index].marker = true                   -- (only in the editor: never built into the game)
    self.ed.project:save_place(place)
    local old = P.T(P.get(a, "at")) and self:find(a.at) or nil
    a.at = place .. "/spot" .. n
    Y.remove(a, "pos")
    Y.remove(a, "place")
    if old then self:remove_object(old[1], old[2]) end
    self:save()
  end
  self.ed:request_object("create", "things", done, require("conjunction.quest").SPOT_MARKER)
  self:sync()
end

-- n creatures of one kind in a ring around a point clicked in the world, all of them targets of `a`
-- (questboard._add_group; a catalog folder: each one a random variant of it)
function QBD:add_group(a, n, radius)
  radius = radius or 2.5
  self:choose("creatures", function(path)
    local variants = self.chosen_variants
    local ident = tostring(a):gsub("^table: ", "")
    local function done(place, pos)
      self.waiting = nil
      local objs = self.ed.project:place(place, self.ed.world).objects
      local NUM = require("conjunction.pynum")
      local refs = {}
      for k = 0, n - 1 do
        local ang = 2 * math.pi * k / n
        local p = {NUM.round(pos[1] + radius * math.cos(ang), 3), NUM.round(pos[2] + radius * math.sin(ang), 3),
                   NUM.round(pos[3], 3)}
        local yaw = NUM.round(((math.deg(ang) + 90) % 360) - 180, 1)     -- (facing the middle)
        local tpl = (variants and #variants > 0) and variants[math.random(#variants)] or path
        objs[#objs + 1] = Y.map({"template", tpl, "pos", Y.list(p), "rot", Y.list({0.0, 0.0, yaw})})
        refs[#refs + 1] = place .. "/" .. self.ed.project:name_object(place, #objs)
        if place == self.ed.place then
          self.ed:exec(string.format('cj_spawn("%s", %s, %s, %s, 0, 0, %s)', tpl, NUM.str(p[1]), NUM.str(p[2]),
                                     NUM.str(p[3]), NUM.str(yaw)))
        end
      end
      self.ed.project:save_place(place)
      local targets = {}
      for _, t in ipairs(P.list(P.get(a, "targets"))) do if P.T(t) then targets[#targets + 1] = t end end
      for _, r in ipairs(refs) do targets[#targets + 1] = r end
      a.targets = Y.list(targets)
      Y.remove(a, "target")
      self:save()
    end
    self.waiting = {ident, "group", "point"}
    self.ed:request_object("point", "point", done)
    self:sync()
  end)
end

-- the step becomes another kind of its block (questboard._set_kind)
function QBD:set_kind(steps, i, kind)
  local IM = require("conjunction.ui.inline_menu")
  IM.close()
  if kind == "scene" then return end              -- (a scene stays a scene: its kind button has only itself)
  local old_kind, old = QBD_DATA.step_kind(steps[i])
  if kind == old_kind then return end
  if QBD_DATA.GOAL_KINDS[old_kind] and QBD_DATA.GOAL_KINDS[kind] then
    self:change_kind(steps, i, kind)
    self.graph_pick = steps[i]
    return
  end
  local new = self:new_step(kind)
  local nk, na = QBD_DATA.step_kind(new)
  if P.T(P.get(old, "text")) and QG.block_of(nk) == QG.block_of(old_kind) then na.text = old.text end
  if nk == "stop" then
    local lanes = {}
    for _, nid in ipairs(QN.order(self:graph_quest())) do
      local k2, a2 = QN.step_kind(self:graph_quest().nodes[nid].step)
      if k2 == "meanwhile" and P.T(P.get(a2, "path")) then lanes[#lanes + 1] = a2.path end
    end
    if #lanes > 0 then na.path = lanes[#lanes] end
  end
  if nk == "meanwhile" then
    local n = 0
    for _, node in pairs(self:graph_quest().nodes) do if QN.step_kind(node.step) == "meanwhile" then n = n + 1 end end
    na.path = "lane" .. (n + 1)
  end
  steps[i] = new
  self.graph_pick = new
  self:save()
end

-- a new goal of another kind in its place, what fits carried over (questboard._change_kind)
function QBD:change_kind(steps, goal, kind)
  local old_kind, old = QBD_DATA.step_kind(steps[goal])
  if kind == old_kind then return end
  steps[goal] = self:goal_step(kind)
  local new_kind, new = QBD_DATA.step_kind(steps[goal])
  local field = {}
  for _, g in ipairs(QBD_DATA.GOALS) do field[g[1]] = g[3] end
  for _, key in ipairs({"text", "item", "count"}) do
    if P.has(old, key) and (key == "text" or P.has(new, key) or field[new_kind] == key) then new[key] = old[key] end
  end
  local ref = P.or_(P.get(old, "npc"), P.get(old, "target"), P.get(old, "object"))
  local want = field[new_kind]
  if P.T(ref) and (want == "npc" or want == "target" or want == "object") and not P.T(P.get(new, want)) then
    new[want] = ref
  end
  self:save()
end

-- a fresh step of a kind (questboard._new_step, _goal_step, _action_step)
function QBD:new_step(kind)
  if kind == "scene" then return Y.map({"talk", Y.map({"scene", true, "start", "now"})}) end
  if QG.PLACEHOLDERS[kind] then return Y.map({kind, Y.map()}) end
  if kind == "chapter" then return Y.map({"chapter", Y.map()}) end
  if kind == "end" then return Y.map({"end", Y.map({"how", "success"})}) end
  if kind == "if" then return Y.map({"if", Y.map()}) end
  local goal = false
  for _, k in ipairs(QG.GOAL_KINDS) do if k == kind then goal = true end end
  if goal or kind == "deliver" or kind == "either" then return self:goal_step(kind) end
  return self:action_step(kind)
end

function QBD:goal_step(kind)
  local args
  if kind == "goto" then args = Y.map({"place", self.ed.place, "radius", 10})
  elseif kind == "wait" then args = Y.map({"time", "00:00:10"})
  elseif kind == "collect" then args = Y.map({"count", 1})
  else args = Y.map() end
  if kind == "clues" then args.clues = Y.list({Y.map({"says", Y.map()})}) end
  if kind == "deliver" then
    kind, args = "talk", Y.map({"dialogue", Y.list({
      Y.map({"who", "npc", "text", "Did you bring it?"}),
      Y.map({"choice", Y.list({
        Y.map({"text", "Here it is.", "give", Y.map({"item", "", "count", 1}), "lines",
               Y.list({Y.map({"who", "npc", "text", "Thank you, witcher."})}), "end", "continue"}),
        Y.map({"text", "Not yet.", "end", "retry"})})})})})
  end
  return Y.map({kind, args})
end

function QBD:action_step(kind)
  local args
  if kind == "reward" then args = Y.map({"money", 100, "xp", 50})
  elseif kind == "fact" then args = Y.map({"name", "", "value", 1})
  elseif kind == "random" then args = Y.map({"ways", Y.list({Y.map(), Y.map()})})
  else args = Y.map() end
  return Y.map({kind, args})
end

-- ···: play from here, duplicate, remove (questboard._card_menu)
function QBD:card_menu(steps, i, what)
  if what == "copy" then
    local node = self:graph_quest().nodes[steps.nid]
    local new = deepcopy(steps[i])
    local nid = QN.new_id(self:graph_quest())
    local x, y = P.get(node, "x", 0) + 40, P.get(node, "y", 0) + 40
    self:graph_quest().nodes[nid] = Y.map({"step", new, "x", math.tointeger(x // GL.GRID * GL.GRID),
                                           "y", math.tointeger(y // GL.GRID * GL.GRID)})
    self.graph_pick = new
    self:save()
  elseif what == "clip" then
    self:copy_node(steps.nid)
  elseif what == "paste" then
    self:paste_node(steps.nid)
  elseif what == "template" then
    self:save_template(steps.nid)
  elseif what == "remove" then
    self:remove_step(steps, i)
  elseif what == "test" and self.panel.test_from then
    self.panel:test_from({"node", steps.nid})
  end
end

function QBD:remove_step(steps, _i)
  if steps.nid then self:remove_node(steps.nid) end
end

-- a node goes, and its wires (the start stays)
-- Delete: a dialogue's pick on its page; else a wire clicked, else the node picked (the start stays)
function QBD:delete_picked()
  if self.dialogue ~= nil then
    self.dialogue:delete_picked()
    return
  end
  local link = self.graph.chosen_wire
  if link then
    self:unlink(link)
    self.graph:select_wire(nil)
    self:save()
  elseif self.graph_node and self.graph_node ~= QN.START and self:graph_quest().nodes[self.graph_node] ~= nil then
    self:remove_node(self.graph_node)
  end
end

-- (a node of a chain - one way out: the steps before it lead on to the one after it, as a list closes up; the
-- start and the next step stayed apart, 07.11.)
function QBD:remove_node(nid)
  local q = self:graph_quest()
  if nid == QN.START then return end
  Y.remove(q.nodes, nid)
  local ins, outs, keep = {}, {}, Y.list({})
  for _, ln in ipairs(q.links) do
    if ln[3] == nid and ln[1] ~= nid then ins[#ins + 1] = ln end
    if ln[1] == nid and ln[3] ~= nid then outs[#outs + 1] = ln end
    if ln[1] ~= nid and ln[3] ~= nid then keep[#keep + 1] = ln end
  end
  if #outs == 1 then
    local to = outs[1][3]
    for _, ln in ipairs(ins) do
      local there = false
      for _, k in ipairs(keep) do if k[1] == ln[1] and k[2] == ln[2] and k[3] == to then there = true end end
      if not there then keep[#keep + 1] = Y.list({ln[1], ln[2], to}) end
    end
  end
  q.links = keep
  self:save()
end

-- QUEST STARTS: the quest's own settings (questboard: head_box - a form of one line each, the journal entry, who
-- must survive)
function QBD:start_card()
  local q = self:quest()
  local exp = require("conjunction.features").experimental()
  -- (the first release: no Journal row - when the journal shows the quest comes with the update, MaximdeWinter 07.10.)
  local labels = exp and {"Kind", "Starts", "Journal", "Plays as", "Level"} or {"Kind", "Starts", "Plays as", "Level"}
  local lw = 0
  for _, l in ipairs(labels) do lw = math.max(lw, Q.hint_w(l, 12)) end
  -- the kinds' chips (4 apart), Starts (26 letters x wide), Plays as, Level (0 to 100, "-" for none)
  local chips, cx = {}, 0
  for i, t in ipairs(QBD_DATA.QUEST_TYPES) do
    local w = menu_size(t[2])
    chips[i] = {key = t[1], label = t[2], x = cx, w = w}
    cx = cx + w + 4
  end
  local chips_w = cx - 4
  local combo_w = 26 * Q.text_w("x") + 106
  local D2 = require("conjunction.dialogue")
  local who_key = P.or_(P.get(q, "player"), "geralt")
  local who = P.get(P.or_(P.get(D2.PLAYERS, who_key), D2.PLAYERS.geralt), "label")
  local player_w = menu_size(who)
  local spin_w = math.max(Q.text_w("0 "), Q.text_w("100 "), Q.text_w("-")) + 90
  local start_text
  for _, e in ipairs(QBD_DATA.QUEST_STARTS) do
    if e[1] == P.str(P.or_(P.get(q, "start"), "at_once")) then start_text = e[2] end
  end
  start_text = start_text or QBD_DATA.QUEST_STARTS[1][2]
  local start_w = menu_size(start_text)
  local col_w = math.max(chips_w, combo_w, player_w, spin_w, exp and start_w or 0)
  local rows = {{"Kind", 25}, {"Starts", Q.line_h() + 14}, {"Plays as", 25}, {"Level", 35}}
  if exp then table.insert(rows, 3, {"Journal", 25}) end
  local grid_h = 0
  for i, rw in ipairs(rows) do grid_h = grid_h + rw[2] + (i > 1 and 5 or 0) end
  local alive = P.list(P.get(q, "keep_alive"))
  local fw = Q.hint_w("Fail if killed", 12)
  local npc_w = plus_size("+ NPC")
  local item_w = plus_size("+ quest item")
  local chip_ws = {}
  local alive_w = fw + 6 + npc_w + 6 + 6 + item_w
  for k, ref in ipairs(alive) do
    chip_ws[k] = menu_size(P.replace(P.str(ref):match("([^/]*)$"), "_", " ")) + 16
    alive_w = alive_w + chip_ws[k] + 6
  end
  -- the experimental features on: the moment of a game quest that ends it (a chip, a click removes it), or
  -- + game moment (QToolButton#plus: padding 3px 8px, 27 high)
  local eg = P.or_(P.get(q, "ends_game"), Y.map())
  local ends_text, ends_w, ends_h
  if exp and P.T(P.get(eg, "fact")) then
    local how = P.str(P.or_(P.get(eg, "how"), "fail")) == "fail" and "fails" or "succeeds"
    ends_text = how .. " at " .. P.str(P.or_(P.get(eg, "name"), "a game quest")) .. ": " ..
                P.replace(P.str(eg.fact), "_", " ")
    ends_w, ends_h = menu_size(ends_text) + 16, 25
  elseif exp then
    ends_text = "+ game moment"
    ends_w, ends_h = menu_size(ends_text), 27
  end
  if ends_text then alive_w = alive_w + ends_w + 6 end
  local alive_h = math.max(24, #alive > 0 and 25 or 0, ends_h or 0)    -- (a chip 25 high, + game moment 27)
  local desc_h = 54
  local h = grid_h + 5 + Q.line_h(12) + 5 + desc_h + 5 + alive_h
  local w = math.max(lw + 8 + col_w, alive_w)
  local this = self
  local function draw(x, y, width)
    local bg = C.card
    local wx = x + lw + 8
    local yy = y
    -- Kind
    QBD.field({x = x, y = yy, w = lw, h = rows[1][2]}, "Kind", bg)
    local cur = P.or_(P.get(q, "type"), "secondary")
    for _, c in ipairs(chips) do
      local box = {x = wx + c.x, y = yy, w = c.w, h = 25}
      if QBD.menu_button("qb.type." .. c.key, box, c.label, {chip = true, checked = c.key == cur, tip = "qb.type"}) then
        q.type = c.key
        this:save(false)
      end
    end
    yy = yy + rows[1][2] + 5
    -- Starts
    QBD.field({x = x, y = yy, w = lw, h = rows[2][2]}, "Starts", bg)
    local entries, index = this:after_entries()
    local changed, picked = CT.combo("qb.after", wx, yy, combo_w, entries.labels, index, this.panel.rect,
                                     {h = rows[2][2], fg = T.BRIGHT, tip = "qb.after"})
    if changed then this:after_chosen(entries.data[picked]) end
    yy = yy + rows[2][2] + 5
    local ri = 3
    if exp then                                -- Journal: when the journal shows the quest
      QBD.field({x = x, y = yy, w = lw, h = rows[ri][2]}, "Journal", bg)
      local jr = {x = wx, y = yy, w = start_w, h = 25}
      if QBD.menu_button("qb.quest_start", jr, start_text, {tip = "qb.quest_start"}) then this:starts_menu(jr) end
      yy = yy + rows[ri][2] + 5
      ri = ri + 1
    end
    -- Plays as
    QBD.field({x = x, y = yy, w = lw, h = rows[ri][2]}, "Plays as", bg)
    if QBD.menu_button("qb.player", {x = wx, y = yy, w = player_w, h = 25}, who, {tip = "qb.plays_as"}) then
      this:players_menu({x = wx, y = yy, w = player_w, h = 25})
    end
    yy = yy + rows[ri][2] + 5
    ri = ri + 1
    -- Level
    QBD.field({x = x, y = yy, w = lw, h = rows[ri][2]}, "Level", bg)
    local lv = math.tointeger(tonumber(P.str(P.or_(P.get(q, "level"), 0)))) or 0
    local _, v = CT.spin("qb.level", wx, yy, lv, {min = 0, max = 100, special = "-", w = spin_w, fg = T.BRIGHT,
                                                  tip = "qb.level"})
    if v ~= lv then
      if v == 0 then Y.remove(q, "level") else q.level = v end
      this:save(false)
    end
    yy = yy + rows[ri][2] + 5
    -- Description
    Q.text(x, yy, C.field, "Description", 12, false, bg)
    yy = yy + Q.line_h(12) + 5
    local PT = require("conjunction.ui.plaintext")
    local chg, t2 = PT.edit("qb.desc", x, yy, width, desc_h, this.desc_text or "",
                            {placeholder = "Journal entry", tip = "qb.description"})
    if chg then
      this.desc_text = t2
      this.desc_due = w3.time() + 0.6            -- (saved 600 ms after the last key)
      this.desc_typing = true
    end
    if this.desc_due and w3.time() >= this.desc_due then
      this.desc_due = nil
      this.desc_typing = false
      q.description = require("conjunction.pystr").strip(this.desc_text or "")
      this:save(false)
    end
    yy = yy + desc_h + 5
    -- Fail if killed: its people, + NPC, the game moment (experimental), and + quest item at the right (a row as
    -- high as its highest; the buttons in its middle)
    QBD.field({x = x, y = yy, w = fw, h = alive_h}, "Fail if killed", bg)
    local by = yy + (alive_h - 24) // 2
    local ax = x + fw + 6
    for k, ref in ipairs(alive) do
      local label = P.replace(P.str(ref):match("([^/]*)$"), "_", " ")
      local cw = chip_ws[k]
      if QBD.removable_chip("qb.alive." .. k, {x = ax, y = yy + (alive_h - 25) // 2, w = cw, h = 25}, label,
                            {tip = "qb.alive_remove"}) then
        table.remove(alive, k)
        if #alive == 0 then Y.remove(q, "keep_alive") end
        this:save()
      end
      ax = ax + cw + 6
    end
    if QBD.plus_button("qb.alive_add", {x = ax, y = by, w = npc_w, h = 24}, "+ NPC", {bg = bg, tip = "qb.alive_add"}) then
      this:toggle_picker({}, "alive", "alive", function(ref) this:alive_add(ref) end)
    end
    ax = ax + npc_w + 6
    if ends_text and ends_h == 25 then
      if QBD.removable_chip("qb.ends_game_remove", {x = ax, y = yy + (alive_h - 25) // 2, w = ends_w, h = 25}, ends_text,
                            {tip = "qb.ends_game_remove"}) then
        this:set_in(q, "ends_game", nil)
      end
    elseif ends_text then
      local er = {x = ax, y = yy + (alive_h - ends_h) // 2, w = ends_w, h = ends_h}
      if QBD.plus_tool("qb.ends_game", er, ends_text, {bg = bg, tip = "qb.ends_game"}) then this:ends_menu(er) end
    end
    if QBD.plus_button("qb.own_add", {x = x + width - item_w, y = by, w = item_w, h = 24}, "+ quest item",
                       {bg = bg, tip = "qb.own_add"}) then
      this:add_own_item()
    end
  end
  return {w = w, h = h, draw = draw}
end

-- the 'Starts' list (questboard._fill_after): no quest before, with or after a game quest; the experimental
-- features on, also the other projects' quests (a typed id stays in it), a moment of a game quest, a block inside
-- one -> {labels, data}, the current one
-- (kept while the quest is as it was, at most 2 s - the start card asks each frame, 1.4 ms of it, 14.11.; data_ver:
-- QBD.save and QBD.sync)
function QBD:after_entries()
  local kept = self.after_kept
  if kept and kept[1] == (self.data_ver or 0) and os.clock() - kept[4] < 2 then return kept[2], kept[3] end
  local entries, index = self:after_entries_made()
  self.after_kept = {self.data_ver or 0, entries, index, os.clock()}
  return entries, index
end
function QBD:after_entries_made()
  local q = self:quest()
  local gq = P.or_(P.get(q, "game_quest"), Y.map())
  local cur = P.str(P.or_(P.get(q, "after"), ""))
  local hook = P.or_(P.get(q, "after_game"), Y.map())
  local inside = P.or_(P.get(q, "inside_game"), Y.map())
  local labels, data = {"Starts automatically"}, {""}
  local function add(label, d)
    labels[#labels + 1] = label
    data[#data + 1] = d
  end
  local function index_of(d)
    for i, x in ipairs(data) do if x == d then return i end end
    return nil
  end
  if P.T(P.get(gq, "id")) then
    add((P.get(gq, "when") == "with" and "With" or "After") .. ": " .. P.str(P.or_(P.get(gq, "title"), gq.id)),
        "__gq_set")
  end
  -- after a quest of one's own (a series): one of this project's (not for its first quest - the others start from
  -- its start), one of another project's
  local QS = require("conjunction.quests")
  local mine = QS.key_of(q)
  if mine ~= 1 then
    for _, oq in ipairs(QS.all_quests(self.ed.project.meta)) do
      local k = QS.key_of(oq)
      if k ~= mine then add("After: " .. P.str(P.or_(P.get(oq, "title"), "Quest " .. k)), "__q" .. k) end
    end
  end
  for _, oq in ipairs(self:other_quests()) do add("After: " .. oq[2], oq[1]) end
  if cur ~= "" and not index_of(cur) then add("After: " .. cur, cur) end
  add("With a game quest...", "__with")
  add("After a game quest...", "__after")
  local own = P.get(q, "after_quest")
  local own_data = (P.T(own) and mine ~= 1) and ("__q" .. P.str(own)) or nil
  if not require("conjunction.features").experimental() then   -- (a moment inside a game quest: the update)
    return {labels = labels, data = data}, index_of(P.T(P.get(gq, "id")) and "__gq_set" or own_data or cur) or 1
  end
  if P.T(P.get(hook, "fact")) then
    add("after: " .. P.str(P.get(hook, "name")) .. " - " .. P.replace(P.str(hook.fact), "_", " "), "__hooked")
  end
  if P.T(P.get(inside, "phase")) then
    local S = require("conjunction.pystr")
    local what = P.str(P.or_(P.get(inside, "label"), ""))   -- (no '#<block>', no details)
    local sp = what:find(" ", 1, true)
    if sp then what = what:sub(sp + 1) end
    local cut = what:find(": ", 1, true)
    if cut then what = what:sub(1, cut - 1) end
    local name = P.str(P.get(inside, "name"))
    local dash = name:find("  -  ", 1, true)
    if dash then name = name:sub(1, dash - 1) end
    add("inside: " .. name .. ", after " .. S.from_cps(S.cps(what), 1, math.min(48, S.len(what))), "__inside_set")
  end
  add("After a moment of a game quest...", "__game")
  add("Inside a game quest...", "__inside")
  local want = P.T(P.get(inside, "phase")) and "__inside_set" or P.T(P.get(hook, "fact")) and "__hooked" or
               P.T(P.get(gq, "id")) and "__gq_set" or own_data or cur
  return {labels = labels, data = data}, index_of(want) or 1
end

-- (id, title) of the quests of the other projects (the recent ones), then of others' in the library (a series: this
-- one after theirs) - each file read again only when it changed (questboard._other_quests)
-- (the list itself kept 2 s: the start card asks each frame - the files' times, the library's folder, the config read
-- every frame were 2.8 ms of it, 14.11.: the story map over the board ran at 21 fps)
function QBD:other_quests()
  local kept = self.other_kept
  if kept and os.clock() - kept[1] < 2 then return kept[2] end
  local out = self:other_quests_read()
  self.other_kept = {os.clock(), out}
  return out
end
function QBD:other_quests_read()
  local S = require("conjunction.pystr")
  local cache = self.meta_cache or {}
  self.meta_cache = cache
  local out, seen = {}, {}
  local own = S.lower(P.str(P.or_(self.ed.project.meta and P.get(self.ed.project.meta, "id"), "")))
  local function put(qid, title)
    if qid ~= "" and qid ~= own and not seen[qid] then
      seen[qid] = true
      out[#out + 1] = {qid, title}
    end
  end
  local cfg = require("conjunction.config").load()
  for _, path in ipairs(Y.is_list(cfg.recent) and cfg.recent or {}) do
    local f = P.str(path) .. "\\project.yml"
    local stamp = w3.fs.exists(f) and w3.fs.mtime(f) or nil
    if stamp then
      if not cache[f] or cache[f][1] ~= stamp then
        local ok, meta = pcall(Y.read, f)
        cache[f] = {stamp, (ok and Y.is_map(meta)) and meta or false}
      end
      local meta = cache[f][2]
      if meta then
        local qd = P.or_(P.get(meta, "quest"), Y.map())
        local qid = S.lower(P.str(P.or_(P.get(meta, "id"), "")))
        put(qid, P.str(P.or_(P.get(qd, "title"), P.get(meta, "name"), qid)))
      end
    end
  end
  local LIB = require("conjunction.library")
  local ok = pcall(function()
    local names = {}
    for _, e in ipairs(w3.fs.isdir(LIB.QUESTS) and w3.fs.list(LIB.QUESTS) or {}) do
      if S.lower(e.name):sub(-4) == ".w3q" then names[#names + 1] = e.name end
    end
    table.sort(names)
    for _, n in ipairs(names) do
      local key = LIB.QUESTS .. "\\" .. n
      local stamp = w3.fs.mtime(key)
      if not cache[key] or cache[key][1] ~= stamp then cache[key] = {stamp, LIB.read_manifest(key)} end
      local m = cache[key][2]
      local qid = S.lower(P.str(P.or_(P.get(m, "id"), "")))
      put(qid, P.str(P.or_(P.get(m, "title"), qid)) .. " (library)")
    end
  end)
  if not ok then return out end                  -- (a broken file: not offered)
  return out
end

function QBD:after_chosen(data)
  if data == "__gq_set" or data == "__hooked" or data == "__inside_set" then return end
  if data == "__with" or data == "__after" then                  -- (the story map: a quest picked, with / after it)
    self.panel:open_story(self.ed, function() self:sync() end)
    return
  end
  local q = self:quest()
  Y.remove(q, "game_quest")
  if data == "__inside" then                     -- a block of a game quest picked: the quest starts after it
    self:choose_point(function(point)
      Y.remove(q, "after")
      Y.remove(q, "after_game")
      q.inside_game = point
      self:save()
    end)
    return
  end
  Y.remove(q, "inside_game")
  if data == "__game" then                       -- a moment of a game quest: the quest starts when it is reached
    self:choose_moment(function(moment)
      Y.remove(q, "after")
      q.after_game = moment
      self:save()
    end)
    return
  end
  Y.remove(q, "after_game")
  if data:sub(1, 3) == "__q" then                -- one of this project's quests
    Y.remove(q, "after")
    q.after_quest = math.tointeger(tonumber(data:sub(4)))
    self:save(false)
    return
  end
  Y.remove(q, "after_quest")
  if data == "" then Y.remove(q, "after") else q.after = data end
  self:save(false)
end

-- Journal: when the journal shows the quest (QUEST_STARTS), the one set ticked
function QBD:starts_menu(r)
  local IM = require("conjunction.ui.inline_menu")
  local q = self:quest()
  local cur = P.str(P.or_(P.get(q, "start"), "at_once"))
  local list = {}
  for _, e in ipairs(QBD_DATA.QUEST_STARTS) do
    list[#list + 1] = {text = e[2], checked = e[1] == cur, action = function()
      self:set_in(q, "start", e[1] ~= "at_once" and e[1] or nil)
    end}
  end
  if IM.is_open("qb.quest_start") then IM.close() else IM.open("qb.quest_start", r, list, self.panel.rect, {bg = LIST_BG}) end
end

-- + game moment: the quest fails / succeeds when a game quest reaches the moment picked
function QBD:ends_menu(r)
  local IM = require("conjunction.ui.inline_menu")
  local q = self:quest()
  local list = {}
  for _, e in ipairs({{"fail", "Fails when a game quest reaches..."}, {"success", "Succeeds when a game quest reaches..."}}) do
    list[#list + 1] = {text = e[2], checked = false, action = function()
      self:choose_moment(function(m)
        local v = Y.map()
        for _, k in ipairs(Y.keys(m)) do v[k] = m[k] end
        v.how = e[1]
        self:set_in(q, "ends_game", v)
      end)
    end}
  end
  if IM.is_open("qb.ends_game") then IM.close() else IM.open("qb.ends_game", r, list, self.panel.rect, {bg = LIST_BG}) end
end

-- the game's windows that pick a moment of a game quest, a block inside one, a game scene (the panel's choosers)
function QBD:choose_moment(fn) if self.panel.choose_moment then self.panel:choose_moment(fn) end end
function QBD:choose_point(fn) if self.panel.choose_point then self.panel:choose_point(fn) end end
function QBD:choose_scene(fn) if self.panel.choose_scene then self.panel:choose_scene(fn) end end

-- Plays as: the game's playable characters (dialogue.PLAYERS), the one played ticked
function QBD:players_menu(r)
  local IM = require("conjunction.ui.inline_menu")
  local D2 = require("conjunction.dialogue")
  local q = self:quest()
  local cur = P.or_(P.get(q, "player"), "geralt")
  local list = {}
  for k, p in pairs(D2.PLAYERS) do
    list[#list + 1] = {text = p.label, checked = k == cur, action = function()
      if k == "geralt" then Y.remove(q, "player") else q.player = k end
      self:save()
    end}
  end
  if IM.is_open("qb.player") then IM.close() else IM.open("qb.player", r, list, self.panel.rect, {bg = LIST_BG}) end
end

return QBD
