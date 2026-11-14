-- vanilla_view.py's VanillaWindow: a game quest graph in the panel's window, editable - the trail, the edit buttons
-- and the search above, the first steps under them (until closed once), the sidebar of blocks at the left, the graph,
-- the picked block's card at the right. Phases open in place, a phase of another file opens that file.
--   Undo, Redo, Save, Revert: Save keeps the file in the project (game_files\<its path>), the build puts it into the
--   project's mod bundle; Revert: the game's file again. A game quest's file is read only while the experimental
--   features are off.
--   local vw = VW.new(ed, win, path, {depot = , project_dir = })   vw:frame(r)   vw:open_path(path)
local V = require("conjunction.vanilla_graph")
local VE = require("conjunction.vanilla_edit")
local BL = require("conjunction.blocks")
local GV = require("conjunction.ui.vanilla_graph_view")
local BP = require("conjunction.ui.block_palette")
local BC = require("conjunction.ui.block_card")
local PT = require("conjunction.ui.props_tree")
local L = require("conjunction.ui.layout")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local T = require("conjunction.ui.theme")
local TR = require("conjunction.cr2w_tree")
local J = require("conjunction.json")
local P = require("conjunction.py")
local D = w3.ui.draw
local VW = {}
VW.__index = VW

local function hex(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
VW.C = {bg = hex("#18181b"), label = hex("#c8c8cc"), crumb = hex("#a8a8ac"), crumb_last = hex("#f0f0f2"),
        crumb_hover = hex("#f0f0f2"), checked_bg = hex("#24402a"), checked_edge = hex("#5cb85c"),
        checked_fg = hex("#e8f4e8"), tips_bg = hex("#1f2a1f"), tips_edge = hex("#2f4a2f"), tips_fg = hex("#cfe3cf"),
        tips_button = hex("#8fbf8f"), tab_bg = hex("#1f1f23"), tab_on = hex("#2c2c34"), tab_fg = hex("#9a9aa0"),
        tab_on_fg = hex("#f0f0f2"), head = hex("#c8c8cc")}
local C = VW.C
VW.READ_ONLY = "a game file: read only (changing it: Settings > General > Experimental)"
VW.LAYOUT = "game_layout.json"      -- in the project: where blocks were dragged, by file and block GUID
VW.TIPS = "First steps:  drag a block from the left onto the graph  ·  click a block to see what it does and how " ..
          "the game uses it  ·  drag from an output's square to an input to connect  ·  Custom block: an own block " ..
          "with the game's blocks inside  ·  Handbook: every block with examples"
VW.SPLIT = {250, 1050, 400}         -- split.setSizes: the sidebar, the graph, the card (stretch 0, 3, 1)
VW.HANDLE = 5
local CLIP = nil                    -- the blocks copied: {src = file bytes, ns = {numbers}, at = {[n] = {x, y}}}

local function basename(p) return (p:gsub("^.*[\\/]", "")) end

VW.ROW_W = 1180            -- px the top row needs (crumbs, buttons, the two fields, Fit, Handbook)
function VW.new(ed, win, path, opts)
  opts = opts or {}
  local proj = ed and ed.project
  local self = setmetatable({ed = ed, win = win, _depot = opts.depot, editors = {}, trail = {}, state = "",
                             search = "", opener = "", unfolded = {}, fold_of = {}, live = false, follow = false,
                             folding = true, tab = 1, head = nil, picked = nil, want_path = path,
                             want_own = opts.own}, VW)
  self.project_dir = opts.project_dir or (proj and proj.path) or nil
  self.layout_ = self:_load_layout()
  -- (the top row needs about VW.ROW_W: in Qt its layout's minimum kept the window that wide; here a narrower window
  -- laid the fields and buttons on each other) - as wide as the picture allows, and no narrower by dragging
  if win and win.rect and win.mover then
    local W = (ed and ed.panel and ed.panel.W) or 1920
    local want = math.min(VW.ROW_W, W - 16)
    if win.rect.w < want then
      win.rect.w = want
      if win.rect.x + want > W - 8 then win.rect.x = math.max(8, W - 8 - want) end
    end
    win.min_w = math.max(win.min_w or 360, want)
    win.mover.min_w = win.min_w
  end
  local CFG = require("conjunction.config")
  local ok, cfg = pcall(CFG.load)
  self.tips = not (ok and type(cfg) == "table" and P.T(P.get(cfg, "quest_graph_tips_closed")))
  self.palette = BP.new()
  self.palette.edit_style = ed and ed.panel and ed.panel.EDIT_STYLE or nil
  self.palette.on_chosen = function(entry) self:add_entry(entry, nil) end
  self.palette.on_drop = function(entry, mx, my) self:drop(entry, mx, my) end
  self.card = BC.new(self)
  self.props = PT.new(self)
  self.view = GV.new({editable = true})
  self.view.on_pick = function(b) self:show_block(b) end
  self.view.on_open = function(n) self:open_block(n) end
  self.view.on_moved = function(n, x, y) self:block_moved(n, x, y) end
  self.view.on_connect = function(a, out, b, put) self:link(a, out, b, put) end
  self.view.on_menu = function(target, mx, my, sx, sy) self:menu(target, mx, my, sx, sy) end
  return self
end

function VW:depot()
  if self._depot == nil then
    self._depot = require("conjunction.depot").open(require("conjunction.config").load().game)
  end
  return self._depot
end

-- --- files and where we are in them
function VW:editor(path)
  if self.editors[path] == nil then
    local rel, data, base
    if self.project_dir then rel, data, base = VE.own_quest_data(self.project_dir) end
    if rel and rel:lower() == path:lower() then         -- the project's own quest
      local JI = require("conjunction.journal_index")
      if JI.own_objectives then
        for _, o in ipairs(JI.own_objectives(self.project_dir)) do BL.OWN_CAPTIONS[o.guid] = o.caption end
      end
      self.editors[path] = VE.Editor(self:depot(), path, self.project_dir, base, data ~= nil and data or base,
                                     self.project_dir .. "\\" .. VE.GAME_FILES .. "\\" .. VE.OWN_FILE)
    else
      self.editors[path] = VE.Editor(self:depot(), path, self.project_dir)
    end
  end
  return self.editors[path]
end

-- the project's own quest in the graph (as the last build encoded it, with the graph's changes) -> false before the
-- first build
function VW:open_own_quest()
  local rel = VE.own_quest(self.project_dir)
  if not rel then
    self.state = "Build the quest once, then it opens here"
    self.not_built = true
    return false
  end
  self:open_path(rel)
  return true
end

-- (editor, QuestFile, graph object number) of the graph shown
function VW:here()
  local t = self.trail[#self.trail]
  local e = self:editor(t[1])
  local qf = e.qf
  local gn = qf.root
  if t[2] ~= nil then
    local n = VW.by_guid(qf, t[2])
    local emb = n and qf.tree:obj(n):get("embeddedGraph") or nil
    if V.obj_ref(emb) then gn = emb end
  end
  return e, qf, gn
end

local function ghex(b) return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
function VW.by_guid(qf, guid)
  for k, o in ipairs(qf.tree.objects) do
    local g = o.props and o:get("guid") or nil
    if TR.is(g, TR.GUID) and ghex(g.b) == guid then return k end
  end
  return nil
end
function VW.guid(qf, n)
  local g = n and qf.tree:obj(n):get("guid") or nil
  return TR.is(g, TR.GUID) and ghex(g.b) or nil
end

-- a quest file from its start (the trail begins anew)
function VW:open_path(path)
  self.trail = {{path, nil, basename(path)}}
  self.not_built = false
  self:show_current(true)
end

function VW:open_block(n)
  local shown = self:shown(n)
  if shown and shown.opens and shown.opens[1] == "fold" then return self:unfold(n) end
  local _, qf, gn = self:here()
  local b = qf:graph(gn).blocks[n]
  if not b or not b.opens then return end
  if b.opens[1] == "graph" then
    self.trail[#self.trail + 1] = {self.trail[#self.trail][1], VW.guid(qf, n), b.name ~= "" and b.name or "phase"}
  elseif b.opens[2] and self:depot():exists(b.opens[2]) then
    self.trail[#self.trail + 1] = {b.opens[2], nil, basename(b.opens[2])}
  else
    return
  end
  self:show_current(true)
end

-- a block of the file shown, wherever it is: the phases in (their GUIDs), then it picked and in sight
function VW:open_place(trail_guids, guid)
  local path = self.trail[1][1]
  local e = self:editor(path)
  local trail = {{path, nil, basename(path)}}
  for _, g in ipairs(trail_guids or {}) do
    local n = VW.by_guid(e.qf, g)
    local name = n and V.str(V.or_(e.tree:obj(n):get("name"), "phase")) or "phase"
    trail[#trail + 1] = {path, g, name}
  end
  self.trail = trail
  self.reveal = guid
  self:show_current(true, guid)
  if self.view.current then self.view:center_on_item(self.view.current) end
end

-- a place of the game's quests (block_examples): its file, the phases in, the block picked and in sight
function VW:open_example(ex)
  local trail = {{ex.file, nil, basename(ex.file)}}
  local names = {}
  for part in ((P.get(ex, "where") or "") .. " > "):gmatch("(.-) > ") do names[#names + 1] = part end
  for k, g in ipairs(P.get(ex, "trail") or {}) do
    trail[#trail + 1] = {ex.file, g, (names[k] and names[k] ~= "") and names[k] or "phase"}
  end
  self.trail = trail
  self.reveal = P.get(ex, "guid")
  self:show_current(true, P.get(ex, "guid"))
  if self.view.current then self.view:center_on_item(self.view.current) end
end

function VW:back_to(k)
  for i = #self.trail, k + 1, -1 do self.trail[i] = nil end
  self:show_current(true)
end

-- --- drawn
function VW:placed(qf, gn)
  local g = self:folded(qf, gn)
  V.place(g)
  local mine = self.layout_[qf.path] or {}
  for _, n in ipairs(g.order) do
    local at = mine[VW.guid(qf, n) or ""]
    if at then g.blocks[n].x, g.blocks[n].y = at[1], at[2] end
  end
  V.route(g)
  return g
end

-- graph gn as shown: with Templates on, the blocks wired as a template is inside as that template's block
-- (translator.lua) - those double clicked open as their blocks
function VW:folded(qf, gn)
  local g = qf:graph(gn)
  self.fold_of = {}
  self.view.fold_of = self.fold_of
  if not self.folding then return g end
  local TT = require("conjunction.translator")
  local ok, ms = pcall(function() return TT.find(g, TT.shapes(self:depot())) end)
  if not ok then
    self.state = "templates not read: " .. tostring(ms)
    return g
  end
  local reveal = self.reveal
  self.reveal = nil
  for _, m in ipairs(ms) do                             -- (a block gone to: Follow, a fact's use ... - its own)
    for _, x in ipairs(m.blocks) do
      if reveal and VW.guid(qf, x) == reveal then self.unfolded[VW.guid(qf, m.blocks[1]) or ""] = true end
    end
  end
  local kept = {}
  for _, m in ipairs(ms) do
    if not self.unfolded[VW.guid(qf, m.blocks[1]) or ""] then kept[#kept + 1] = m end
  end
  for _, m in ipairs(kept) do
    for _, x in ipairs(m.blocks) do self.fold_of[x] = m.blocks[1] end
  end
  return TT.fold(g, kept)
end

-- the block as the graph shows it (a template's block for its first block), or nil
function VW:shown(n)
  local it = self.view.blocks[n]
  return it and it.b or nil
end

-- a link as drawn -> the link in the file (a template's block: the block and socket its port stands for)
function VW:real(a, out, b, put)
  local ba, bb = self:shown(a), self:shown(b)
  if ba and ba.ports then
    local r = ba.ports["out\0" .. out]
    if r then a, out = r[1], r[2] else a = ba.last end
  end
  if bb and bb.ports then
    local r = bb.ports["in\0" .. put]
    if r then b, put = r[1], r[2] end
  end
  return a, out, b, put
end

-- block numbers as drawn -> the file's (a template's block: all its blocks)
function VW:real_blocks(ns)
  local out = {}
  for _, n in ipairs(ns) do
    local b = self:shown(n)
    if b and b.folded then
      for _, x in ipairs(b.folded) do out[#out + 1] = x end
    else
      out[#out + 1] = n
    end
  end
  return out
end

-- a template's block shown as its blocks again
function VW:unfold(n)
  local _, qf = self:here()
  local guid = VW.guid(qf, n)
  if guid then self.unfolded[guid] = true end
  self:show_current(false, guid)
end

function VW:show_current(home, pick)
  local e, qf, gn = self:here()
  local g = self:placed(qf, gn)
  local gv = self.view
  local keep = {gv.m11, gv.hval, gv.vval}
  gv:show_graph(g)
  if home then                                          -- all of it when it fits readably, else its start
    gv:reset_transform()
    local x, y, w, h = gv:items_rect()
    x, y, w, h = x - 30, y - 30, w + 60, h + 60
    local pw, ph = gv.vpw, gv.vph                       -- (viewport().rect(): as laid out)
    local fits = w > 0 and math.min(pw / w, ph / h) >= 0.6
    local first
    for _, n in ipairs(gv.order) do
      local c = gv.blocks[n].b.cls
      if c == "CQuestPhaseInputBlock" or c == "CQuestStartBlock" then first = gv.blocks[n] break end
    end
    if fits then
      gv:fit_in_view(x, y, w, h)
      if gv.m11 > 1.0 then
        gv:reset_transform()
        gv:center_on(x + w / 2, y + h / 2)
      end
    elseif first then
      gv:center_on(first.b.x + pw / 2 - 60, first.b.y)
    end
  else
    gv:set_scale(keep[1], nil)
    gv:set_h(keep[2])
    gv:set_v(keep[3])
  end
  if self.search ~= "" then gv:find(self.search) end
  self.guid_n = {}
  for _, n in ipairs(g.order) do
    local guid = VW.guid(qf, n)
    if guid then self.guid_n[guid] = n end
  end
  for guid, at in pairs(self.live_seen or {}) do
    local n = self.guid_n[guid]
    if n and gv.blocks[n] then gv.blocks[n].live_at = at end
  end
  self:sync_buttons()
  local n = pick and VW.by_guid(qf, pick) or nil
  n = n and (self.fold_of[n] or n) or nil
  if n and gv.blocks[n] then gv:pick_n(n) else self:show_block(nil) end
end

function VW:sync_buttons()
  local e = #self.trail > 0 and self:editor(self.trail[#self.trail][1]) or nil
  local on = e ~= nil
  self.can = {undo = on and #e.history > 0, redo = on and #e.future > 0,
              save = on and e:dirty() and self.project_dir ~= nil, revert = on and e:changed()}
  if not e then
    self.state = ""
  elseif self:read_only(e) and not e:changed() then
    self.state = VW.READ_ONLY
  elseif e:changed() and e._own then                    -- the project's own quest
    self.state = (e:dirty() and "unsaved · " or "") .. "Changed in the graph. Build uses this version (changes on " ..
                 "the quest board reach it after Revert)"
  elseif e:changed() then
    local gu = e:changed_guids()
    self.state = (e:dirty() and "unsaved · " or "") .. "Changed from the game" ..
                 (gu.gone > 0 and (" · " .. gu.gone .. " game blocks gone (Caution: saves inside this quest may not " ..
                                   "fit)") or "")
  else
    self.state = ""
  end
end

-- a game quest's file while the experimental features are off: shown, not changed
function VW:read_only(e)
  if e == nil and #self.trail > 0 then e = self:editor(self.trail[#self.trail][1]) end
  return e ~= nil and not e._own and not require("conjunction.features").experimental()
end

-- one change on the file shown, then everything drawn again (the picked block stays picked); a game quest's file
-- read only takes none - but going back to the game's (allow)
function VW:edit(fn, pick_guid, allow)
  local e, qf = self:here()
  if not allow and self:read_only(e) then
    self.state = VW.READ_ONLY
    return nil
  end
  local cur = self.view.current
  local keep = pick_guid or (cur and VW.guid(qf, cur.b.n) or nil)
  local ok, result = pcall(fn, e)
  if not ok then
    self.state = "not changed: " .. tostring(result)
    return nil
  end
  self:show_current(false, math.type(result) == "integer" and (VW.guid(e.qf, result) or keep) or keep)
  return result
end

function VW:undo() self:edit(function(e) e:undo() end) end
function VW:redo() self:edit(function(e) e:redo() end) end
function VW:revert() self:edit(function(e) e:revert() end, nil, true) end
function VW:save()
  local e = self:editor(self.trail[#self.trail][1])
  if self.project_dir then
    local ok, err = pcall(function() e:save() end)
    if not ok then
      self.state = tostring(err)
      return
    end
    self:_save_layout()
  end
  local cur = self.view.current
  self:show_current(false, cur and VW.guid(e.qf, cur.b.n) or nil)
end

function VW:link(a, out, b, put)
  a, out, b, put = self:real(a, out, b, put)
  self:edit(function(e) e:connect(a, out, b, put) end)
end

function VW:block_moved(n, x, y)
  local _, qf = self:here()
  local guid = VW.guid(qf, n)
  if guid then
    self.layout_[qf.path] = self.layout_[qf.path] or {}
    self.layout_[qf.path][guid] = {x, y}
    self:_save_layout()
  end
  self.view:grow()
end

local function put_at(self, qf, ed, n, at)
  local guid = VW.guid(ed.qf, n)
  if guid then
    self.layout_[qf.path] = self.layout_[qf.path] or {}
    self.layout_[qf.path][guid] = {math.tointeger(at[1]) or math.floor(at[1]), math.tointeger(at[2]) or math.floor(at[2])}
  end
end

function VW:add_block(cls, at)
  local _, qf, gn = self:here()
  local n = self:edit(function(ed)
    local k = ed:add_block(gn, cls)
    put_at(self, qf, ed, k, at)
    return k
  end)
  self:_save_layout()
  return n
end

-- a block from the sidebar put into the graph shown, at `at` (nil: the middle of what is in sight); one undo takes
-- it back -> its number
function VW:add_entry(entry, at)
  if #self.trail == 0 then return nil end
  local _, qf, gn = self:here()
  if at == nil then
    local cx, cy = self.view:to_scene((self.view.vw - 1) // 2, (self.view.vh - 1) // 2)
    at = {cx - V.NODE_W / 2, cy - 30}
  end
  local what, name = entry[1], entry[2]
  if what == "template" then return self:add_template(name, at) end
  local function make(ed)
    if what == "kind" then return BL.create(ed, gn, BL.BY_ID[name]) end
    if what == "block" then return ed:add_block(gn, name) end
    if what == "wait" then return ed:add_wait(gn, name) end
    if what == "if" then
      local n = ed:add_block(gn, BL.I)
      ed:add_condition(n, name)
      return n
    end
    if what == "fn" then return ed:add_function(gn, name, BL.function_params(name, self.palette:catalog())) end
    if what == "ai" then return ed:add_ai(gn, name) end
    error("unknown block " .. tostring(what), 0)
  end
  local n = self:edit(function(ed)
    local k = ed:batch(make)
    put_at(self, qf, ed, k, at)
    return k
  end)
  self:_save_layout()
  return n
end

-- a template (custom_blocks) put in: a custom block with all inside, named as the template; the project remembers
-- which template it is (its exposed fields on the card) -> its number
function VW:add_template(tid, at)
  local CB = require("conjunction.custom_blocks")
  local tpl = CB.by_id(tid)
  if tpl == nil then return nil end
  local _, qf, gn = self:here()
  local n = self:edit(function(ed)
    local k = ed:batch(function(ed2)
      local m = CB.insert(ed2, gn, tpl)
      ed2:set_field(m, "name", tpl.label, "String")
      return m
    end)
    put_at(self, qf, ed, k, at)
    local guid = VW.guid(ed.qf, k)
    if guid then self:instances():set(guid, {template = tid}) end
    return k
  end)
  self:_save_layout()
  return n
end

-- the project's custom blocks (custom_blocks.Instances): which template, which fields shown outside
function VW:instances()
  if self._instances == nil then self._instances = require("conjunction.custom_blocks").Instances(self.project_dir) end
  return self._instances
end

-- the custom block the graph shown is the inside of: its number in the file, else nil
function VW:inside_custom()
  if #self.trail < 2 or self.trail[#self.trail][2] == nil then return nil end
  local e = self:editor(self.trail[#self.trail][1])
  return VW.by_guid(e.qf, self.trail[#self.trail][2])
end

-- a block dragged from the sidebar and let go: over the graph, put there
function VW:drop(entry, mx, my)
  local r = self.view_rect
  if not r or mx < r.x + 1 or my < r.y + 1 or mx >= r.x + 1 + self.view.vw or my >= r.y + 1 + self.view.vh then
    return
  end
  local sx, sy = self.view:to_scene(mx - r.x - 1, my - r.y - 1)
  self:add_entry(entry, {sx, sy})
end

-- --- copy and paste: blocks between graphs and quest files
function VW:copy()
  if #self.trail == 0 then return 0 end
  local e, qf = self:here()
  local drawn = self.view:chosen()
  if #drawn == 0 then return 0 end
  local ns = self:real_blocks(drawn)
  local at = {}
  for _, n in ipairs(drawn) do                          -- (a template's blocks: in a row from where it stands)
    local it = self.view.blocks[n]
    for k, x in ipairs(self:real_blocks({n})) do
      if it then at[x] = {it.b.x + (k - 1) * (V.NODE_W + V.GAP_X), it.b.y} end
    end
  end
  CLIP = {src = e.data, ns = ns, at = at, from = qf.path}
  self.state = #ns .. " block" .. (#ns ~= 1 and "s" or "") .. " copied"
  return #ns
end

function VW:paste(at)
  if not CLIP or #self.trail == 0 then return {} end
  local _, qf, gn = self:here()
  if at == nil then
    local mx, my = w3.ui.mouse()
    local r = self.view_rect
    local ax, ay = mx - (r and r.x + 1 or 0), my - (r and r.y + 1 or 0)
    if not (r and ax >= 0 and ay >= 0 and ax < self.view.vw and ay < self.view.vh) then
      ax, ay = (self.view.vw - 1) // 2, (self.view.vh - 1) // 2
    end
    at = {self.view:to_scene(ax, ay)}
  end
  local x0, y0
  for _, p in pairs(CLIP.at) do
    x0 = x0 and math.min(x0, p[1]) or p[1]
    y0 = y0 and math.min(y0, p[2]) or p[2]
  end
  x0, y0 = x0 or 0, y0 or 0
  local new = self:edit(function(ed)
    local made = ed:paste(gn, CLIP.src, CLIP.ns)
    for i, n in ipairs(made) do
      local p = CLIP.at[CLIP.ns[i]] or {x0, y0}
      put_at(self, qf, ed, n, {at[1] + p[1] - x0, at[2] + p[2] - y0})
    end
    return made
  end) or {}
  self:_save_layout()
  for _, n in ipairs(new) do if self.view.blocks[n] then self.view.selected[n] = true end end
  return new
end

function VW:duplicate_chosen()
  if self:copy() > 0 then
    local x0, y0
    for _, p in pairs(CLIP.at) do
      x0 = x0 and math.min(x0, p[1]) or p[1]
      y0 = y0 and math.min(y0, p[2]) or p[2]
    end
    return self:paste({x0 + 40, y0 + 40})
  end
  return {}
end

function VW:remove_chosen()
  if #self.trail == 0 then return end
  local _, _, gn = self:here()
  local ns = self:real_blocks(self.view:chosen())
  if #ns > 0 then self:edit(function(ed) return ed:remove_blocks(gn, ns) end) end
end

function VW:choose_all()
  for _, n in ipairs(self.view.order) do self.view.selected[n] = true end
end

-- --- the picked block
function VW:show_block(b)
  self.picked = b
  if #self.trail == 0 then return end
  local _, qf, gn = self:here()
  self.card:show_block(qf, b)
  self.props_of = b
  if self.tab == 2 then self.props:fill(qf, b) else self.props:fill(qf, nil) end   -- (filled when its tab opens)
  if b == nil then
    local g = qf:graph(gn)
    self:set_head(string.format("<b style='color:#f0f0f2'>%s</b><br><span style='color:#8c8c90'>%d blocks, %d links" ..
                                "<br>%s</span>", self.trail[#self.trail][3], #g.order, #g.links, qf.path))
    return
  end
  self:set_head(nil)
end

function VW:set_head(html)
  if html == self.head then return end
  self.head = html
  if self.head_pic and self.head_pic.id then w3.ui.image_free(self.head_pic.id) end
  self.head_pic, self.head_w = nil, nil
end

-- the head's picture (a QLabel, rich text, word wrap: 12 px #c8c8cc)
function VW:head_picture(width)
  if self.head == nil then return nil end
  if self.head_pic ~= nil and self.head_w == width then return self.head_pic end
  if self.head_pic and self.head_pic.id then w3.ui.image_free(self.head_pic.id) end
  self.head_w = width
  local tmp = os.getenv("TEMP") or "."
  local src = tmp .. "\\cj_vg_head.html"
  local f = io.open(src, "wb")
  if f then f:write(self.head) f:close() end
  local out = string.format("%s\\cj_vg_head_%d.png", tmp, width)
  local ok = pcall(w3.plugin.cj_qt_rich, out, tostring(width), "html", src, "12", "c8c8ccff", "18181bff",
                   string.format("%08x", require("conjunction.ui.richtext").LINK), "0")
  self.head_pic = false
  if ok then
    local id, w, h = w3.ui.image_load(out)
    if id then self.head_pic = {id = id, w = w, h = h} end
  end
  return self.head_pic
end

-- --- where blocks were dragged (game_layout.json in the project)
function VW:_layout_file()
  return self.project_dir and (self.project_dir .. "\\" .. VW.LAYOUT) or nil
end
function VW:_load_layout()
  local f = self:_layout_file()
  if f and w3.fs.exists(f) then
    local ok, data = pcall(J.read, f)
    if ok and type(data) == "table" then return data end
  end
  return {}
end
function VW:_save_layout()
  local f = self:_layout_file()
  if f then pcall(J.write, f, self.layout_) end
end

-- the right click's menu: a link's, a block's, or the graph's (add a block there)
function VW:menu(target, mx, my, sx, sy)
  local IM = require("conjunction.ui.inline_menu")
  local list = {}
  if target and target[1] == "wire" then
    local ra, rout, rb, rput = self:real(target[2][1], target[2][2], target[2][3], target[2][4])
    list[#list + 1] = {text = "Remove link", action = function()
      self:edit(function(ed) ed:disconnect(ra, rout, rb, rput) end)
    end}
  elseif target and target[1] == "block" then
    local b = target[2]
    if b.opens and b.opens[1] == "fold" then
      list[#list + 1] = {text = "Show its blocks", action = function() self:unfold(b.n) end}
    elseif b.opens then
      list[#list + 1] = {text = "Open", action = function() self:open_block(b.n) end}
    end
    list[#list + 1] = {text = "Copy  (Ctrl+C)", action = function() self:copy() end}
    list[#list + 1] = {text = "Duplicate  (Ctrl+D)", action = function() self:duplicate_chosen() end}
    list[#list + 1] = {text = "Remove  (Del)", action = function() self:remove_chosen() end}
  else
    if CLIP then
      local n = #CLIP.ns
      list[#list + 1] = {text = "Paste " .. n .. " block" .. (n ~= 1 and "s" or "") .. "  (Ctrl+V)",
                         action = function() self:paste({sx, sy}) end}
    end
    -- Add block: the simple ones by what they are for, then the game's blocks (the app's submenus as groups)
    for _, g in ipairs(BL.GROUPS) do
      local items = {}
      for _, k in ipairs(BL.KINDS) do
        if k.group == g[1] then
          items[#items + 1] = {text = k.label, action = function() self:add_entry({"kind", k.id}, {sx, sy}) end}
        end
      end
      if #items > 0 then list[#list + 1] = {group = g[2], items = items} end
    end
    local simple = {}
    for _, k in ipairs(BL.KINDS) do simple[k.cls] = true end
    local game = {}
    for _, c in ipairs(VE.block_classes(self:depot())) do
      if not simple[c] then
        game[#game + 1] = {text = (V.NAMES[c] or V.short(c)) .. "   (" .. c .. ")", action = function()
          self:add_block(c, {sx, sy})
        end}
      end
    end
    list[#list + 1] = {group = "Game blocks", items = game}
  end
  if #list > 0 then
    IM.open("vg.menu", {x = mx, y = my, w = 1, h = 1}, list, self.win and self.win.rect or {x = 0, y = 0, w = 4096,
                                                                                             h = 4096})
  end
end

-- --- one frame
local function button(id, x, y, w, h, text, st)
  local clicked, hovered, held = CT.hit_box(id, {x = x, y = y, w = w, h = h})
  st = st or {}
  if st.checked then
    local edge = C.checked_edge
    Q.frame(x, y, w, h, C.checked_bg, edge)
    local tw = Q.text_w(text)
    local dy = h - 12 - Q.line_h()
    Q.text(x + 11 + (w - 22 - tw) // 2, y + 6 + dy // 2, C.checked_fg, text, T.FONT, false, C.checked_bg)
  else
    Q.button(x, y, w, h, text, {hover = hovered, pressed = held and hovered, disabled = st.disabled,
                                fg = T.BUTTON_TEXT})
  end
  if hovered and st.tip then CT.tip(id, st.tip) end
  return clicked and not st.disabled
end

-- the crumbs: buttons (#crumb: transparent, padding 3px 4px; the last bold #f0f0f2), "›" between
function VW:crumb_items()
  local out = {}
  for k, t in ipairs(self.trail) do
    if k > 1 then out[#out + 1] = {kind = "sep", text = "›", w = Q.hint_w("›", 12), h = Q.line_h(12)} end
    local e = self.editors[t[1]]
    local label = t[3] .. ((e and e:changed()) and " *" or "")
    local last = k == #self.trail
    out[#out + 1] = {kind = "crumb", text = label, k = k, last = last, w = Q.hint_w(label, T.FONT, last) + 8,
                     h = Q.line_h(T.FONT) + 6}
  end
  return out
end

function VW:top_row(r)
  local eh = CT.edit_h()
  local crumbs = self:crumb_items()
  local cw = 0
  for _, c in ipairs(crumbs) do cw = cw + c.w end
  local items, what = {}, {}
  local function add(it, w) items[#items + 1] = it what[#what + 1] = w end
  add({hint = cw, min = cw}, {"crumbs"})
  add({spacer = true, stretch = 1, expanding = true, empty = true, hint = 0, min = 0}, {"stretch"})
  local sw = self.state ~= "" and Q.hint_w(self.state, 12) or 0
  add({hint = sw, min = sw}, {"state"})
  local buttons = {{"live", "Live"}, {"templates", "Templates"}, {"follow", "Follow"}, {"undo", "Undo"},
                   {"redo", "Redo"}, {"save", "Save"}, {"revert", "Revert"}}
  for _, b in ipairs(buttons) do
    local w = Q.button_size(b[2])
    add({hint = w, min = w}, {"button", b[1], b[2]})
  end
  add({spacer = true, fixed = true, empty = true, hint = 8, min = 8}, {"space"})
  add({hint = 220, min = 220, max = 220}, {"opener"})
  add({hint = 220, min = 220, max = 220}, {"search"})
  for _, b in ipairs({{"fit", "Fit"}, {"handbook", "Handbook"}}) do
    local w = Q.button_size(b[2])
    add({hint = w, min = w}, {"button", b[1], b[2]})
  end
  local placed = L.row(items, r.x, r.y, r.w, eh, {spacing = 6})
  local _, bh = Q.button_size("Live")
  for i, w in ipairs(what) do
    local p = placed[i]
    if w[1] == "crumbs" then
      local x = p.x
      for _, c in ipairs(crumbs) do
        local cy = r.y + (eh - c.h) // 2
        if c.kind == "sep" then
          Q.text(x, r.y + Q.vcenter(eh, Q.line_h(12)), C.label, c.text, 12, false, C.bg)
        else
          local clicked, hovered = CT.hit_box("vg.crumb." .. c.k, {x = x, y = cy, w = c.w, h = c.h})
          local fg = c.last and C.crumb_last or (hovered and C.crumb_hover or C.crumb)
          Q.text(x + 4 + (c.w - 8 - Q.text_w(c.text, T.FONT, c.last)) // 2, cy + 3, fg, c.text, T.FONT, c.last, C.bg)
          if clicked then self:back_to(c.k) end
        end
        x = x + c.w
      end
    elseif w[1] == "state" then
      if self.state ~= "" then Q.text(p.x, r.y + Q.vcenter(eh, Q.line_h(12)), C.label, self.state, 12, false, C.bg) end
    elseif w[1] == "button" then
      local key = w[2]
      local by = r.y + (eh - bh) // 2
      local st = {tip = "vg." .. key}
      if key == "live" then st.checked = self.live end
      if key == "templates" then st.checked = self.folding end
      if key == "follow" then st.checked = self.follow end
      if self.can and self.can[key] ~= nil then st.disabled = not self.can[key] end
      if button("vg." .. key, p.x, by, p.w, bh, w[3], st) then self:press(key) end
    elseif w[1] == "opener" then
      local _, s, enter = CT.edit("vg.opener", p.x, r.y, 220, self.opener, {placeholder = "Open a game quest...",
                                                                             tip = "vg.open",
                                                                             style = self:edit_style()})
      if s ~= self.opener then
        self.opener = s
        self:opener_list({x = p.x, y = r.y, w = 220, h = eh})
      end
      if enter then self:open_typed() end
    elseif w[1] == "search" then
      local _, s = CT.edit("vg.search", p.x, r.y, 220, self.search, {placeholder = "Find a block", tip = "vg.search",
                                                                   style = self:edit_style()})
      if s ~= self.search then
        self.search = s
        self.view:find(s)
      end
    end
  end
end

function VW:edit_style() return self.ed and self.ed.panel and self.ed.panel.EDIT_STYLE or nil end

function VW:press(key)
  if key == "undo" then self:undo()
  elseif key == "redo" then self:redo()
  elseif key == "save" then self:save()
  elseif key == "revert" then self:revert()
  elseif key == "fit" then self.view:fit()
  elseif key == "templates" then
    self.folding = not self.folding
    self.unfolded = {}
    if #self.trail > 0 then self:show_current() end
  elseif key == "live" then self:set_live(not self.live)
  elseif key == "follow" then self.follow = not self.follow
  elseif key == "handbook" then self:handbook()
  end
end

-- --- live: the blocks the game activates (TW3SE's questlive: a qb|on|<guid> line for each)
function VW:set_live(on)
  local ok, reply = pcall(function() return w3.command("questlive " .. (on and "on" or "off")) end)
  if not ok then reply = "no game: " .. tostring(reply) end
  if on and not tostring(reply):find("hooked=yes", 1, true) then
    self.state = "Live: TW3SE has no questlive - " .. tostring(reply):sub(1, 80)
    self.live = false
    return
  end
  self.live = on
  if on then
    self.live_pos = w3.link.mark()
    self.live_next = 0
  end
end

function VW:live_tick()
  local now = w3.time()
  if now < (self.live_next or 0) then return end
  self.live_next = now + 0.25                           -- (the app's timer: every 250 ms)
  local ok, pos, lines = pcall(w3.link.since, self.live_pos)
  if not ok then return end                             -- (the game went away)
  self.live_pos = pos
  self:live_activations(lines, now)
end

-- qb|on|<guid> lines: each GUID's time kept; a block of the graph shown lit -> how many of them here
function VW:live_activations(lines, now)
  self.live_seen = self.live_seen or {}
  local here, last = 0, nil
  for _, ln in ipairs(lines) do
    if ln:sub(1, 6) == "qb|on|" then
      local guid = ln:sub(7, 38)
      self.live_seen[guid] = now
      local n = (self.guid_n or {})[guid]
      if n and self.view.blocks[n] then
        self.view.blocks[n].live_at = now
        here = here + 1
      end
      last = guid
    end
  end
  if self.follow and last and here == 0 then self:follow_to(last) end
  return here
end

-- Follow: a block the game ran elsewhere in the file shown - its phase opened, it picked -> true when in this file
function VW:follow_to(guid)
  if #self.trail == 0 then return false end
  local e = self:editor(self.trail[1][1])
  local n = VW.by_guid(e.qf, guid)
  if not n or e.tree:obj(n).cls == "CJournalPath" then return false end
  local graph = e.tree:obj(n).parent
  if not graph or graph == 0 or e.tree:obj(graph).cls ~= "CQuestGraph" then return false end
  self:open_place(require("conjunction.block_examples").trail(e.tree, graph), guid)
  return true
end

-- docs\QUEST_BLOCKS.md: every kind of block with real places of the game that use it
function VW:handbook()
  local root = debug.getinfo(1, "S").source:match("^@(.*)[\\/]ingame[\\/]") or ""
  local path = root ~= "" and (root .. "\\docs\\QUEST_BLOCKS.md") or nil
  if path and w3.fs.exists(path) and w3.proc and w3.proc.run then
    require("conjunction.fsutil").show(path)
  else
    self.state = "The handbook comes with the app (docs\\QUEST_BLOCKS.md)"
  end
  return path
end

-- --- "Open a game quest...": any quest file of the game by a part of its name
function VW:quest_files()
  if self.files == nil then
    local story = require("conjunction.story")
    local list = {}
    for _, ext in ipairs({".w2phase", ".w2quest"}) do
      for _, p in ipairs(self:depot():glob("", ext)) do if story.game_file(p) then list[#list + 1] = p end end
    end
    list = require("conjunction.pysort").sorted(list)
    self.files, self.file_keys = {}, {}
    for _, p in ipairs(list) do
      local name = basename(p):gsub("%.[^.]*$", "")
      local key = name .. "   (" .. (p:match("^(.*)[\\/]") or "") .. ")"
      self.files[key] = p
      self.file_keys[#self.file_keys + 1] = key
    end
  end
  return self.files
end

-- the quest file chosen (or the first whose name holds what is typed) opened
function VW:open_typed(text)
  local S = require("conjunction.pystr")
  local files = self:quest_files()
  text = S.strip(text or self.opener)
  local path = files[text]
  if not path then
    local low = S.lower(text)
    for _, k in ipairs(self.file_keys) do
      if S.lower(k):find(low, 1, true) then path = files[k] break end
    end
  end
  if path then
    self:open_path(path)
    self.opener = ""
  end
  return path
end

-- the completer's list under the field: the files whose names hold the text (16 at most)
function VW:opener_list(r)
  local IM = require("conjunction.ui.inline_menu")
  local S = require("conjunction.pystr")
  if self.opener == "" then
    if IM.is_open("vg.opener.list") then IM.close() end
    return
  end
  self:quest_files()
  local low = S.lower(self.opener)
  local items = {}
  for _, k in ipairs(self.file_keys) do
    if S.lower(k):find(low, 1, true) then
      items[#items + 1] = {text = k, action = function() self:open_typed(k) end}
      if #items >= 16 then break end
    end
  end
  if #items > 0 then
    IM.open("vg.opener.list", r, items, self.win and self.win.rect or r)
  elseif IM.is_open("vg.opener.list") then
    IM.close()
  end
end

-- the window's keys (the app's shortcuts, WidgetWithChildrenShortcut: the mouse over the window, no field typing)
function VW:keys()
  if CT.focus ~= nil then return end
  local ctrl = w3.ui.mods()
  local function p(k) return w3.ui.pressed(k) end
  if ctrl and p("C") then self:copy()
  elseif ctrl and p("V") then self:paste(nil)
  elseif ctrl and p("D") then self:duplicate_chosen()
  elseif ctrl and p("A") then self:choose_all()
  elseif ctrl and p("Z") then self:undo()
  elseif ctrl and p("Y") then self:redo()
  elseif ctrl and p("S") then self:save()
  elseif not ctrl and p("Delete") then self:remove_chosen()
  end
end

-- the first steps (a QFrame: #1f2a1f, a #2f4a2f border; margins 8 4 4 4; the label 12 px #cfe3cf, word wrap; "Got
-- it" transparent, #8fbf8f, padding 0 6px) -> its height
function VW:tips_bar(r)
  -- (the label is a QFrame too: the bar's rule gives it its own border, and with it the indent of half an 'x')
  local lh = Q.line_h(12)
  local gw, gh = Q.hint_w("Got it", T.FONT) + 12, lh + 1         -- (a QPushButton: the buttons' font)
  local lw = r.w - 2 - 8 - 4 - 6 - gw
  -- (the label's word wrap: its lines, each as wide as the label - one line ran on past the window's edge)
  local lines = {}
  for _, l in ipairs(require("conjunction.ui.textlayout").wrap(VW.TIPS, 12, false,
                                                               math.max(40, lw - 2 - Q.label_indent(12)), "word")) do
    lines[#lines + 1] = l.s
  end
  if #lines == 0 then lines = {VW.TIPS} end
  local label_h = #lines * lh + 2
  local h = 1 + 4 + label_h + 4 + 1
  Q.frame(r.x, r.y, r.w, h, C.tips_bg, C.tips_edge)
  local lx, ly = r.x + 1 + 8, r.y + 1 + 4
  Q.frame(lx, ly, lw, label_h, C.tips_bg, C.tips_edge)
  for i, l in ipairs(lines) do
    Q.text(lx + 1 + Q.label_indent(12) // 2, ly + 1 + (i - 1) * lh, C.tips_fg, l, 12, false, C.tips_bg)
  end
  local bx, by = r.x + 1 + 8 + lw + 6, r.y + 1 + 4 + (label_h - gh) // 2
  local clicked = CT.hit_box("vg.tips_close", {x = bx, y = by, w = gw, h = gh})
  Q.text(bx + 6, by + Q.vcenter(gh, Q.line_h(T.FONT)), C.tips_button, "Got it", T.FONT, false, C.tips_bg)
  if clicked then
    self.tips = false
    pcall(function()
      local CFG = require("conjunction.config")
      local cfg = CFG.load()
      cfg.quest_graph_tips_closed = true
      CFG.save(cfg)
    end)
  end
  return h
end

-- the tabs over the card (padding 4px 12px, #1f1f23 / chosen #2c2c34, no border)
function VW:tabs(x, y)
  local names = {"Block", "All values"}
  local lh = Q.line_h(12)
  local th = lh + 8
  for k, name in ipairs(names) do
    local w = Q.hint_w(name, 12) + 24
    local on = self.tab == k
    local clicked = CT.hit_box("vg.tab." .. k, {x = x, y = y, w = w, h = th})
    D.fill(x, y, w, th, on and C.tab_on or C.tab_bg)
    Q.text(x + 12, y + 4, on and C.tab_on_fg or C.tab_fg, name, 12, false, on and C.tab_on or C.tab_bg)
    if clicked and self.tab ~= k then
      self.tab = k
      if k == 2 and self.props_of and #self.trail > 0 then self.props:fill(select(2, self:here()), self.props_of) end
    end
    x = x + w
  end
  return th
end

function VW:side(r)
  local y = r.y
  if self.picked == nil and self.head then
    local pic = self:head_picture(r.w)
    if pic then
      D.image(pic.id, r.x, y, pic.w, pic.h)
      y = y + pic.h + 6
    end
  end
  local th = self:tabs(r.x, y)
  local cr = {x = r.x, y = y + th, w = r.w, h = r.y + r.h - y - th}
  if self.tab == 1 then self.card:frame(cr) else self.props:frame(cr) end
end

function VW:frame(r)
  D.fill(r.x, r.y, r.w, r.h, C.bg)
  if self.win and CT.over(self.win.rect) and #self.trail > 0 then self:keys() end
  local eh = CT.edit_h()
  local y = r.y
  self:top_row({x = r.x, y = y, w = r.w, h = eh})
  y = y + eh + 6
  if self.tips then y = y + self:tips_bar({x = r.x, y = y, w = r.w}) + 6 end
  local h = r.y + r.h - y
  -- the splitter: the sidebar keeps its size, the graph and the card share the rest as their sizes stand
  local placed = L.row({{hint = VW.SPLIT[1], min = VW.SPLIT[1]}, {hint = VW.HANDLE, min = VW.HANDLE, max = VW.HANDLE},
                        {hint = 0, min = 0, stretch = VW.SPLIT[2], expanding = true},
                        {hint = VW.HANDLE, min = VW.HANDLE, max = VW.HANDLE},
                        {hint = 0, min = 0, stretch = VW.SPLIT[3], expanding = true}}, r.x, y, r.w, h)
  local pr, vr, sr = placed[1], placed[3], placed[5]
  local hit = function(id, rr) return CT.hit_box(id, rr) end
  self.palette:frame({x = pr.x, y = y, w = pr.w, h = h}, hit)
  self.view_rect = {x = vr.x, y = y, w = vr.w, h = h}
  self.view:resize(vr.w, h)
  if self.want_path then                                -- (opened once the view has its size)
    local p = self.want_path
    self.want_path = nil
    self:open_path(p)
  elseif self.want_own then
    self.want_own = nil
    self:open_own_quest()
  end
  if self.live then self:live_tick() end
  self.view:frame(self.view_rect, CT.over(self.view_rect))
  self:side({x = sr.x, y = y, w = sr.w, h = h})
end

return VW
