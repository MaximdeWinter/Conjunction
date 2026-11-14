-- dialogue_view.py's DialogueView: the dialogue of a talk step on the Quest tab (instead of the board) - Back, its
-- name (the pencil renames it), its size; who is in it (each with a pose, + character); its cameras, spots and things,
-- where the player stands; the sidebar's blocks (Line, Choice, If) beside the flow (ui/flow_view.lua: dialogue_flow's
-- layout); the card of what is picked under the flow (a splitter between). Every change is saved at once.
--   local v = DV.new(board, st)     v:frame(page)     v.on_back = fn
-- Measured on Qt (ref/qt/dialogue_*.png): the view's margins 0 6 0 0, 6 apart; the head's rows 4 apart.
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local FV = require("conjunction.ui.flow_view")
local F = require("conjunction.dialogue_flow")
local D = require("conjunction.dialogue")
local P = require("conjunction.py")
local Y = require("conjunction.yaml")
local PYS = require("conjunction.pystr")
local Dr = w3.ui.draw
local DV = {}
DV.__index = DV

local function hex(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
DV.C = {title = hex("#f0f0f0"), note = hex("#8a8a8a"), speaker_bg = hex("#1f1f23"), speaker_hover = hex("#2c2c32"),
        opt = hex("#9a9a9a"), opt_set = hex("#e8e8e8"), opt_set_bg = hex("#2e2e33"), opt_set_edge = hex("#55555c"),
        opt_hover = hex("#eeeeee"), opt_hover_edge = hex("#555555"), plus = hex("#9a9a9a"), plus_edge = hex("#444444"),
        plus_hover = hex("#eeeeee"), plus_hover_edge = hex("#888888")}
local C = DV.C
DV.BLOCKS = {{"line", "Line"}, {"choice", "Choice"}, {"if", "If"}}
DV.BLOCK_COLOUR = {line = "#c8c8d0", choice = "#b99be6", ["if"] = "#d9a45b"}
DV.SPEAKER_COLORS = {D.GERALT_COLOR}
for _, c in ipairs(D.COLORS) do DV.SPEAKER_COLORS[#DV.SPEAKER_COLORS + 1] = c end

local function idof(t) return (tostring(t):gsub("^table: ", "")) end
local function NUM_F(v) return tonumber(v) or 0.0 end
-- Python's f"{v:g}"
local function NUMSTR(v)
  local n = tonumber(v)
  if n == nil then return P.str(v) end
  if n == math.floor(n) then return string.format("%d", n) end
  return (string.format("%.6g", n))
end

function DV.new(board, st)
  local self = setmetatable({board = board, st = st, picked = nil, adding = nil, shown = false, tiles = {},
                             split_frac = 0.6}, DV)
  local kind = Y.keys(st)[1]
  self.monologue = kind == "examine"
  self.flow = FV.new({
    picked = function(ref, row) self:pick(ref, row) end,
    opened = function(ref, row) self:open(ref, row) end,
    menu = function(ref, row, x, y) self:box_menu(ref, row, x, y) end,
    place = function(block, ref, row) self:place(block, ref, row) end,
    moved_box = function(key, dx, dy) self:moved_box(key, dx, dy) end,
  })
  self:sync()
  return self
end

-- the quest's node of this talk (its boxes' places are kept on it), or nil (a dialogue of no node: a swap's)
function DV:node()
  local q = self.board:quest()
  for _, n in pairs(P.or_(P.get(q, "nodes"), Y.map())) do
    if type(n) == "table" and n.step == self.st then return n end
  end
  return nil
end

-- the boxes moved by hand: {key = {dx, dy}} on the node (node.flow; the step stays as it was, so Build & Play sees no
-- change of the dialogue - changes.quest compares the steps)
function DV:offsets()
  local n = self:node()
  local f = n and P.get(n, "flow")
  return Y.is_map(f) and f or nil
end
function DV:moved_box(key, dx, dy)
  local n = self:node()
  if not n then return end
  if not Y.is_map(P.get(n, "flow")) then n.flow = Y.map() end
  local o = P.get(n.flow, key)
  local ox, oy = 0, 0
  if type(o) == "table" then ox, oy = tonumber(o[1]) or 0, tonumber(o[2]) or 0 end
  n.flow[key] = Y.list({math.tointeger(ox + dx) or (ox + dx), math.tointeger(oy + dy) or (oy + dy)})
  self:save(false)
end

-- --- data
function DV:step()
  local kind = Y.keys(self.st)[1]
  local a = self.st[kind]
  if P.get(a, "dialogue") == nil then           -- (the older form becomes the tree once)
    a.dialogue = Y.list(D.from_step(a))
    Y.remove(a, "lines")
    Y.remove(a, "choices")
  end
  return a
end
function DV:lines() return self:step().dialogue end

function DV:who_plays()
  local q = self.board:quest()
  local who = require("conjunction.quest").characters(q)[self:step()]
  return who or P.str(P.or_(P.get(q, "player"), "geralt"))
end
function DV:player_label()
  local p = P.get(D.PLAYERS, self:who_plays()) or D.PLAYERS.geralt
  return P.str(p.label)
end

function DV:npc_name()
  local ref = P.str(P.or_(P.get(self:step(), "npc"), ""))
  local name = P.replace(ref:match("([^/]*)$") or "", "_", " ")
  return PYS.upper(name ~= "" and name or "NPC")
end

function DV:names()
  local names = {}
  for _, s in ipairs(D.speakers(self:step())) do names[s[1]] = P.str(s[3]) end
  names[D.PLAYER] = self:player_label()
  return names
end

-- a speaker's template (nil: not found)
function DV:template_of(key)
  if D.is_player(key) then
    local p = P.get(D.PLAYERS, self:who_plays()) or D.PLAYERS.geralt
    return p.template
  end
  local found = self.board:find(key == "npc" and P.get(self:step(), "npc") or key)
  if not found then return nil end
  return self.board.ed.project.places[found[1]].objects[found[2]].template
end

-- the scene animations a speaker can play (talking: a set; nil - not known)
function DV:body_of(key)
  local template = self:template_of(key)
  if not template then return nil end
  local ok, have = pcall(require("conjunction.talking").dialogue_anims, template)
  if ok then return have end
  return nil
end

function DV:save(rebuild)
  self.board:save_meta()
  self.board:remember()
  self.want_sync = rebuild ~= false and "card" or "flow"
end

-- the flow anew (keep: the view stays where it was), what is picked kept; card: the card's fields made anew too (not
-- while one of them is typed in - DialogueView._typing_in_card)
function DV:sync(card)
  local f = CT.focus
  local typing = f ~= nil and (f:find("^dlg%.voice_find%.") or f:find("^dlg%.anim_find%."))
  if card ~= false and not typing then self.card_gen = (self.card_gen or 0) + 1 end
  local a = self:step()
  local names = self:names()
  local flow = F.layout(self:lines(), names, self:player_label(), function(who) return D.color(who, a) end,
                        self.monologue)
  self.flow:show_flow(F.arrange(flow, self:lines(), self:offsets()), self.shown)
  if not self.shown then self.flow.want_home = true end   -- (once it has its size)
  self.shown = true
  local ref, row = self:ref_of(self.picked)
  if ref == nil then self.picked = nil end
  self.flow:select(ref, row)
end

-- --- where things are in the tree, and what the flow shows them in (DialogueView._locate, _ref_of, _item_of)
function DV:locate(item, ls)
  ls = ls or self:lines()
  for k, x in ipairs(ls) do
    if x == item then return {ls, k} end
    if P.has(x, "choice") then
      for j, c in ipairs(P.list(x.choice)) do if c == item then return {ls, k, j} end end
    end
    local split = false
    for _, sname in ipairs(D.SPLITS) do if P.has(x, sname) then split = true end end
    if split then
      for _, wy in ipairs(D.ways(x)) do
        local found = self:locate(item, wy[1])
        if found then return found end
      end
    end
  end
  return nil
end

function DV:ref_of(item)
  local at = item ~= nil and self:locate(item) or nil
  if at == nil or self.flow.flow == nil then return nil, -1 end
  for _, b in ipairs(self.flow.flow.boxes) do
    local r = b.ref
    if r and #r >= 3 then
      if #at == 2 then
        local ls, k = at[1], at[2]
        if r[1] == "lines" and r[2] == ls and r[3] <= k and k <= r[4] then return r, -1 end
        if (r[1] == "choice" or r[1] == "split" or r[1] == "script") and r[2] == ls and r[3] == k then return r, -1 end
      elseif r[1] == "choice" and r[2] == at[1] and r[3] == at[2] then
        return r, at[3] - 1
      end
    end
  end
  return nil, -1
end

function DV:item_of(ref, row)
  if not ref then return nil end
  if ref[1] == "lines" then
    local ls, a, b = ref[2], ref[3], ref[4]
    local keep = self.picked ~= nil and self:locate(self.picked) or nil
    if keep and #keep == 2 and keep[1] == ls and a <= keep[2] and keep[2] <= b then return self.picked end
    return ls[a]
  end
  if ref[1] == "choice" then
    local x = ref[2][ref[3]]
    local answers = P.list(x.choice)
    if row and row >= 0 and row < #answers then return answers[row + 1] end
    return x
  end
  if ref[1] == "split" or ref[1] == "script" then return ref[2][ref[3]] end
  if (ref[1] == "answer" or ref[1] == "end") and Y.is_map(ref[2]) then return ref[2] end
  return nil
end

-- --- what the flow's boxes show
function DV:pick(ref, row)
  self.picked = self:item_of(ref, row)
  self.flow:select(ref, row)
end
function DV:open(ref, row)
  self:pick(ref, row)
  local at = self.picked ~= nil and self:locate(self.picked) or nil
  if at and #at == 2 and P.has(at[1][at[2]], "who") then self.focus_line = self.picked end
end
-- a right click on the flow: remove what it is (DialogueView._box_menu)
function DV:box_menu(ref, row, x, y)
  local item = self:item_of(ref, row)
  local at = item ~= nil and self:locate(item) or nil
  if not at then return end
  local entry
  if #at == 3 then
    local answers = P.list(at[1][at[2]].choice)
    entry = {text = "Remove option", icon = "trash-2", action = function() self:remove(answers, at[3], true) end}
  elseif ref[1] == "lines" then
    entry = {text = "Remove lines", icon = "trash-2", action = function() self:remove_run(ref[2], ref[3], ref[4]) end}
  else
    entry = {text = "Remove", icon = "trash-2", action = function() self:remove(at[1], at[2]) end}
  end
  require("conjunction.ui.inline_menu").open("dlg.box_menu", {x = x, y = y - 2, w = 160, h = 2}, {entry},
                                             self.board.panel.rect, {bg = hex("#1e1e1e")})
end

-- (list, index) a block put at a box goes to (DialogueView._spot)
function DV:spot(ref, row)
  if not ref then
    local ls = self:lines()
    return ls, #ls + 1
  end
  if ref[1] == "start" then return self:lines(), 1 end
  if ref[1] == "lines" then
    local at = self.picked ~= nil and self:locate(self.picked) or nil
    if at and #at == 2 and at[1] == ref[2] and ref[3] <= at[2] and at[2] <= ref[4] then return ref[2], at[2] + 1 end
    return ref[2], ref[4] + 1
  end
  if ref[1] == "choice" and row and row >= 0 then
    local c = P.list(ref[2][ref[3]].choice)[row + 1]
    if P.get(c, "lines") == nil then c.lines = Y.list({}) end
    return c.lines, #c.lines + 1
  end
  if ref[1] == "choice" or ref[1] == "split" or ref[1] == "script" then return ref[2], ref[3] + 1 end
  if ref[1] == "answer" or ref[1] == "end" then
    if Y.is_map(ref[2]) then
      if P.get(ref[2], "lines") == nil then ref[2].lines = Y.list({}) end
      return ref[2].lines, #ref[2].lines + 1
    end
    return ref[2], #ref[2] + 1
  end
  return nil
end

-- a block of the sidebar at a box: a line (the keys go into it), a choice (two answers that go on), an If
function DV:place(block, ref, row)
  local ls, i = self:spot(ref, row)
  if ls == nil then return end
  local new
  if block == "line" then
    new = Y.map({"who", self:next_speaker(ls, i), "text", ""})
    self.focus_line = new
  elseif block == "choice" then
    new = Y.map({"choice", Y.list({Y.map({"text", "", "lines", Y.list({}), "end", "on"}),
                                   Y.map({"text", "", "lines", Y.list({}), "end", "on"})})})
    if self.monologue then for _, c in ipairs(new.choice) do c.say = false end end
  else
    new = Y.map({"if", Y.map({"fact", "", "op", ">=", "value", 1}), "then", Y.map({"lines", Y.list({})}),
                 "else", Y.map({"lines", Y.list({})})})
  end
  table.insert(ls, i, new)
  self.picked = new
  self:save()
end

-- --- the controls of the head (each its Qt size: the text, its padding, its border, QToolButton's 3 more)
local function tool_size(text, px, bold, padx, pady, icon)
  local tw = Q.hint_w(text, px, bold) + 2 * Q.text_w(" ", px, bold)
  local w = tw + (icon and (16 + 4) or 0)
  local h = math.max(icon and 16 or 0, Q.line_h(px, bold))
  return w + 2 * padx + 2 + 3, h + 2 * pady + 2 + 3
end

-- QToolButton#speaker: its speaker's colour, #1f1f23 (#2c2c32 under the mouse), bold 11 px, padding 2px 8px, at
-- least 56 wide inside
local function speaker_size(text)
  local tw = math.max(56, Q.hint_w(text, 11, true) + 2 * Q.text_w(" ", 11, true))
  return tw + 16 + 2 + 3, Q.line_h(11, true) + 4 + 2 + 3
end

function DV:hit(id, r) return CT.hit_box(id, r) end

function DV:speaker(id, r, text, colour, tipkey)
  local clicked, hovered = self:hit(id, r)
  local c = hex(colour)
  local bg = hovered and C.speaker_hover or C.speaker_bg
  Q.frame(r.x, r.y, r.w, r.h, bg, c)
  local tw = Q.text_w(text, 11, true)
  Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(11, true)), c, text, 11, true, bg)
  if hovered and tipkey then CT.tip(id, tipkey) end
  return clicked
end

-- QToolButton#opt: #9a9a9a, no border (set: #e8e8e8 on #2e2e33, a #55555c border), 11 px, padding 1px 6px
function DV:opt(id, r, text, on, tipkey, icon, icon_colour)
  local clicked, hovered = self:hit(id, r)
  local fg, bg, edge = C.opt, nil, nil
  if on then fg, bg, edge = C.opt_set, C.opt_set_bg, C.opt_set_edge end
  if hovered then fg, edge = C.opt_hover, C.opt_hover_edge end
  if bg then Dr.fill(r.x, r.y, r.w, r.h, bg) end
  if edge then Dr.rect(r.x, r.y, r.w, r.h, edge, 1) end
  local under = bg or self.bg
  if icon then
    local cx = r.x + 1 + 6
    -- (its own colour: 11.11., the voice's red and green icons have no grey file - the icon was missing)
    Q.draw_icon(icon, icon_colour or 0xcfcfcfff, 16, cx + 2, r.y + (r.h - 16) // 2)
    Q.text(cx + 20, r.y + Q.vcenter(r.h, Q.line_h(11)), fg, text, 11, false, under)
  else
    local tw = Q.text_w(text, 11)
    Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(11)), fg, text, 11, false, under)
  end
  if hovered and tipkey then CT.tip(id, tipkey) end
  return clicked
end

-- QPushButton#plus: #9a9a9a, a dashed #444 border (#eee, #888 under the mouse), 12 px, padding 2px 8px
function DV:plus(id, r, text, tipkey)
  local clicked, hovered = self:hit(id, r)
  local fg, edge = C.plus, C.plus_edge
  if hovered then fg, edge = C.plus_hover, C.plus_hover_edge end
  require("conjunction.ui.qb_widgets").dashed(r.x, r.y, r.w, r.h, edge)
  local tw = Q.text_w(text, 12)
  Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(12)), fg, text, 12, false, self.bg)
  if hovered and tipkey then CT.tip(id, tipkey) end
  return clicked
end
local function plus_size(text) return Q.hint_w(text, 12) + 16 + 2, Q.line_h(12) + 4 + 2 end

-- an icon button (icons.icon_button): 23 x 23, a light film under the mouse
function DV:icon(id, r, icon, tipkey)
  local clicked, hovered = self:hit(id, r)
  if hovered then Dr.fill(r.x, r.y, r.w, r.h, 0xffffff14) end
  Q.draw_icon(icon, hovered and 0xffffffff or 0xcfcfcfff, 16, r.x + (r.w - 16) // 2, r.y + (r.h - 16) // 2)
  if hovered and tipkey then CT.tip(id, tipkey) end
  return clicked
end

-- a list over the panel under a control: {{key, label}}, the current one checked
function DV:list(id, r, entries, current, fn)
  local IM = require("conjunction.ui.inline_menu")
  if IM.is_open(id) then IM.close() return end
  local items = {}
  for _, e in ipairs(entries) do
    local k = e[1]
    items[#items + 1] = {text = e[2], checked = k == current, action = function() fn(k) end}
  end
  IM.open(id, r, items, self.board.panel.rect, {bg = hex("#1e1e1e")})
end

-- --- the head: Back, the name (and the pencil), the size
function DV:head_row(x, y, w)
  local a = self:step()
  local bw, bh = Q.back_size("Back")
  local title
  if P.T(P.get(a, "swap")) then
    title = P.str(P.or_(P.get(a, "text"), "Replacing: a game scene"))
  else
    local lead = P.T(P.get(a, "scene")) and "Scene with " or "Talk to "
    title = self.monologue and "Monologue" or P.str(P.or_(P.get(a, "text"), lead .. PYS.lower(self:npc_name())))
  end
  local count = D.summary(self:lines())
  local tw = Q.hint_w(title, 13, true)
  local renaming = self.renaming and not self.monologue
  local style = self.board.panel.EDIT_STYLE
  local mid_w, mid_h = tw + (self.monologue and 0 or (6 + 23)), 23
  if renaming then mid_w, mid_h = math.max(320, 17 * Q.text_w("x") + 16), CT.edit_h(style) end  -- (the line edit alone)
  local cw = Q.hint_w(count, 11)
  -- (Timeline beside the size: the scene's cameras, animations and places, from the same place as its lines)
  local timeline = require("conjunction.features").scenes() and not self.monologue and not P.T(P.get(a, "swap")) and
                   Y.keys(self.st)[1] == "talk"
  local tlw, tlh = Q.button_size("Timeline")
  local row_h = math.max(bh, mid_h, Q.line_h(11), timeline and tlh or 0)
  -- (a QGridLayout: the name's column as wide as it is, the two beside it share the rest, 6 apart)
  local rest = w - mid_w - 12
  local c0 = (rest + 1) // 2
  local br = {x = x, y = y + (row_h - bh) // 2, w = bw, h = bh}
  local clicked, hovered = self:hit("dlg.back", br)
  Q.back(br.x, br.y, br.w, br.h, "Back", {hover = hovered, bg = self.bg})
  if hovered then CT.tip("dlg.back", "dlg.back") end
  if clicked and self.on_back then self.on_back() end
  local mx, my = x + c0 + 6, y + (row_h - mid_h) // 2
  if renaming then
    -- the step's name in a line edit, all of it selected; Enter or a click elsewhere takes it (its line in the journal)
    local id = "dlg.rename_edit"
    local st = CT.state(id)
    local now = P.str(P.or_(P.get(a, "text"), ""))
    local _, t, enter = CT.edit(id, mx, my, mid_w, st.typed or now, {placeholder = title, h = mid_h, style = style})
    st.typed = t
    if self.renaming == "start" then
      self.renaming = true
      CT.set_focus(id)
      st.e:select_all()
    elseif enter or CT.focus ~= id then
      st.typed = nil
      self.renaming = nil
      local text = table.concat(PYS.split(t), " ")
      if text ~= now then
        if text ~= "" then a.text = text else Y.remove(a, "text") end
        self:save()
      end
    end
  else
    -- (too little room beside Timeline and the size: the name further left, then cut - 11.11., "3 lines, 2 options,
    -- 1 voiced" put Timeline over it in the narrow panel)
    local right = (timeline and (x + w - cw - 8 - tlw) or (x + w - cw)) - 8
    local pen = self.monologue and 0 or 29
    if right - mx - pen < tw then mx = math.max(x + bw + 8, right - pen - tw) end
    local shown = title
    if right - mx - pen < tw then shown = Q.elide(title, "right", math.max(20, right - mx - pen), 13, true) end
    local sw = Q.text_w(shown, 13, true)
    Q.text(mx, my + Q.vcenter(23, Q.line_h(13, true)), C.title, shown, 13, true, self.bg)
    if not self.monologue then
      if self:icon("dlg.rename", {x = mx + sw + 6, y = my, w = 23, h = 23}, "pencil", "dlg.rename") then
        self.renaming = "start"
      end
    end
  end
  Q.text(x + w - cw, y + Q.vcenter(row_h, Q.line_h(11)), C.note, count, 11, false, self.bg)
  if timeline then
    local tr = {x = x + w - cw - 8 - tlw, y = y + (row_h - tlh) // 2, w = tlw, h = tlh}
    local tc, th = self:hit("dlg.timeline", tr)
    Q.button(tr.x, tr.y, tr.w, tr.h, "Timeline", {hover = th})
    if th then CT.tip("dlg.timeline", "qb.timeline") end
    if tc then self.board:open_timeline(self.st) end
  end
  return row_h
end

-- who is in the talk: each speaker (the player's name; another person's: present / joins later, a menu) and a pose
function DV:people_row(x, y, w)
  local a = self:step()
  local items = {}
  for _, s in ipairs(D.speakers(a)) do
    local key, ref, label = s[1], s[2], P.str(s[3])
    if D.is_player(key) then label = self:player_label() end
    local text = PYS.upper(label)
    local joins
    if ref and key ~= "npc" then
      for _, wx in ipairs(P.list(P.get(a, "with"))) do if wx.who == ref then joins = wx end end
      if joins then text = text .. "  -  " .. (P.get(joins, "joins") == "line" and "joins later" or "present") end
    end
    local sw, sh = speaker_size(text)
    items[#items + 1] = {kind = "speaker", key = key, ref = ref, text = text, w = sw, h = sh, joins = joins}
    local p = P.get(P.or_(P.get(a, "poses"), Y.map()), key)
    local ptext = (p and D.POSE[p]) or "Pose"
    local pw, ph = tool_size(ptext, 11, false, 6, 1)
    local have = self:body_of(key)
    local hidden = type(have) == "table" and next(have) == nil       -- (an animal, a monster: no poses)
    if not hidden then
      items[#items + 1] = {kind = "pose", key = key, text = ptext, on = D.POSE[p] ~= nil, w = pw, h = ph, have = have,
                           current = p}
    end
  end
  if not self.monologue then
    local pw, ph = plus_size("+ character")
    items[#items + 1] = {kind = "add", text = "+ character", w = pw, h = ph}
  end
  local row_h = 0
  for _, it in ipairs(items) do row_h = math.max(row_h, it.h) end
  local cx = x
  for k, it in ipairs(items) do
    local r = {x = cx, y = y + (row_h - it.h) // 2, w = it.w, h = it.h}
    if it.kind == "speaker" then
      local tipkey = (it.ref and it.key ~= "npc") and "dlg.person" or
                     (it.key == "npc" and "dlg.person_main" or "dlg.person_player")
      local id = "dlg.who." .. k
      if self:speaker(id, r, it.text, D.color(it.key, a), tipkey) and it.joins then
        local entries = {}
        for _, j in ipairs(D.JOINS) do entries[#entries + 1] = {j[1], j[2]} end
        entries[#entries + 1] = {"remove", "Not in dialogue"}
        self:list(id, r, entries, P.str(P.get(it.joins, "joins", "start")), function(kk) self:person(it.ref, kk) end)
      end
    elseif it.kind == "pose" then
      local id = "dlg.pose." .. k
      if self:opt(id, r, it.text, it.on, "dlg.pose_start") then
        local entries = {{nil, "As they are"}}
        for _, e in ipairs(D.poses_for(it.have)) do entries[#entries + 1] = e end
        self:list(id, r, entries, it.current, function(kk) self:set_pose(it.key, kk) end)
      end
    else
      if self:plus("dlg.add_person", r, it.text, "dlg.add_person") then self:toggle_adding() end
    end
    cx = cx + it.w + 4
  end
  return row_h
end

-- the talk's own cameras, spots and things; where the player stands
function DV:cameras_row(x, y, w)
  local a = self:step()
  local items = {}
  local names = self:names()
  for _, name in ipairs(Y.keys(P.or_(P.get(a, "cams"), Y.map()))) do
    local text = name
    local defaults = P.or_(P.get(a, "cam_defaults"), Y.map())
    local mine = {}
    for _, who in ipairs(Y.keys(defaults)) do if defaults[who] == "cam:" .. name then mine[#mine + 1] = names[who] or who end end
    if #mine > 0 then text = name .. "  ·  " .. table.concat(mine, ", ") end
    local cw, ch = tool_size(text, 11, false, 6, 1, true)
    items[#items + 1] = {kind = "cam", name = name, text = text, w = cw, h = ch}
  end
  local pw, ph = plus_size("+ camera")
  items[#items + 1] = {kind = "add_cam", text = "+ camera", w = pw, h = ph}
  for _, name in ipairs(Y.keys(P.or_(P.get(a, "marks"), Y.map()))) do
    local cw, ch = tool_size(name, 11, false, 6, 1, true)
    items[#items + 1] = {kind = "mark", name = name, text = name, w = cw, h = ch}
  end
  for _, name in ipairs(Y.keys(P.or_(P.get(a, "props"), Y.map()))) do
    local cw, ch = tool_size(name, 11, false, 6, 1, true)
    items[#items + 1] = {kind = "prop", name = name, text = name, w = cw, h = ch}
  end
  local sw, sh = plus_size("+ spot")
  items[#items + 1] = {kind = "add_mark", text = "+ spot", w = sw, h = sh}
  local spot = P.get(P.or_(P.get(a, "spots"), Y.map()), "player")
  local stand_text = self:player_label() .. ": " .. (P.T(spot) and "own spot" or "in front")
  local stw, sth = tool_size(stand_text, 11, false, 6, 1, true)
  local row_h = sth
  for _, it in ipairs(items) do row_h = math.max(row_h, it.h) end
  local cx = x
  for k, it in ipairs(items) do
    local r = {x = cx, y = y + (row_h - it.h) // 2, w = it.w, h = it.h}
    local id = "dlg.cam." .. k
    if it.kind == "cam" then
      if self:opt(id, r, it.text, true, "dlg.own_cam", "video") then
        local defaults = P.or_(P.get(a, "cam_defaults"), Y.map())
        local entries = {{"look", "Look through"}, {"set", "Set to the view"}}
        for _, who in ipairs(Y.keys(names)) do
          if who == D.PLAYER or who == "npc" then
            local mine = defaults[who] == "cam:" .. it.name
            entries[#entries + 1] = {"default:" .. who, (mine and "Not the" or "The") .. " camera of " .. names[who]}
          end
        end
        entries[#entries + 1] = {"remove", "Remove"}
        self:list(id, r, entries, nil, function(k2) self:own_cam(it.name, k2) end)
      end
    elseif it.kind == "mark" then
      if self:opt(id, r, it.text, true, "dlg.mark", "map-pin") then
        self:list(id, r, {{"here", "Set to where the player is"}, {"thing", "Put a thing here"}, {"remove", "Remove"}},
                  nil, function(k2) self:mark(it.name, k2) end)
      end
    elseif it.kind == "prop" then
      if self:opt(id, r, it.text, true, "dlg.prop", "package") then
        local p = a.props[it.name]
        local entries = {}
        for _, m in ipairs(Y.keys(P.or_(P.get(a, "marks"), Y.map()))) do
          entries[#entries + 1] = {"on:" .. m, (m ~= P.get(p, "mark") and "On " or "Is on ") .. m}
        end
        entries[#entries + 1] = {"remove", "Remove"}
        self:list(id, r, entries, nil, function(k2) self:prop(it.name, k2) end)
      end
    elseif it.kind == "add_cam" then
      if self:plus(id, r, it.text, "dlg.add_cam") then self:add_cam() end
    else
      if self:plus(id, r, it.text, "dlg.add_mark") then self:mark(nil, "here") end
    end
    cx = cx + it.w + 4
  end
  local r = {x = x + w - stw, y = y + (row_h - sth) // 2, w = stw, h = sth}
  if self:opt("dlg.player_spot", r, stand_text, P.T(spot), "dlg.player_spot", "map-pin") then
    self:list("dlg.player_spot", r, {{"here", "Stands where the player is now"}, {"front", "Stands in front of them"}},
              nil, function(k) self:player_spot(k) end)
  end
  return row_h
end

-- --- what the head's lists do
function DV:set_pose(key, pose)
  local a = self:step()
  local poses = Y.map()
  for _, k in ipairs(Y.keys(P.or_(P.get(a, "poses"), Y.map()))) do poses[k] = a.poses[k] end
  if pose then poses[key] = pose else Y.remove(poses, key) end
  if next(poses) ~= nil and #Y.keys(poses) > 0 then a.poses = poses else Y.remove(a, "poses") end
  self:save()
end

function DV:person(ref, k)
  local a = self:step()
  if k == "remove" then
    local keep = Y.list({})
    for _, w in ipairs(P.list(P.get(a, "with"))) do if w.who ~= ref then keep[#keep + 1] = w end end
    if #keep > 0 then a.with = keep else Y.remove(a, "with") end
    if P.get(P.or_(P.get(a, "poses"), Y.map()), ref) ~= nil then self:set_pose(ref, nil) end
    for _, x in ipairs(D.walk(self:lines())) do
      if P.get(x, "who") == ref then x.who = "npc" end
      if P.get(x, "look") == ref then Y.remove(x, "look") end
    end
  else
    for _, w in ipairs(P.list(P.get(a, "with"))) do if w.who == ref then w.joins = k end end
  end
  self:save()
end

-- where the player stands now: cj_where()'s answer comes on the link a moment later (DV:frame waits for it)
function DV:ask_where(fn)
  local ed = self.board.ed
  ed.last_where = nil
  ed:exec("cj_where()")
  self.where_wait = {t0 = w3.time(), fn = fn}
end
function DV:wait_where()
  local ww = self.where_wait
  if not ww then return end
  local ed = self.board.ed
  if ed.last_where ~= nil then
    self.where_wait = nil
    local N = require("conjunction.pynum")
    local w = ed.last_where
    ww.fn(Y.map({"pos", Y.list({N.round(w[1], 3), N.round(w[2], 3), N.round(w[3], 3)}),
                 "yaw", N.round(NUM_F(ed.last_heading) % 360, 1)}))
  elseif w3.time() - ww.t0 >= 3 then
    self.where_wait = nil
    ed.panel:say("Player position unknown (the game did not answer)", nil, true)
  end
end

function DV:player_spot(k)
  local a = self:step()
  if k == "front" then
    local spots = P.get(a, "spots")
    if Y.is_map(spots) then Y.remove(spots, "player") end
    if not P.T(P.get(a, "spots")) then Y.remove(a, "spots") end
    self:save()
    return
  end
  self:ask_where(function(spot)
    if not Y.is_map(P.get(a, "spots")) then a.spots = Y.map() end
    a.spots.player = spot
    self:save()
  end)
end

-- a spot of the talk (a new one: nil) set to where the player stands now, a thing put on it, or removed
function DV:mark(name, k)
  local a = self:step()
  if not Y.is_map(P.get(a, "marks")) then a.marks = Y.map() end
  local marks = a.marks
  if k == "thing" then
    self.board:choose("props", function(path) self:prop(nil, "add", path, name) end)
    return
  end
  if k == "remove" then
    Y.remove(marks, name)
    if #Y.keys(marks) == 0 then Y.remove(a, "marks") end
    for _, t in ipairs(Y.keys(P.or_(P.get(a, "props"), Y.map()))) do
      if P.get(a.props[t], "mark") == name then self:prop(t, "remove", nil, nil, false) end
    end
    for _, x in ipairs(D.walk(D.from_step(a))) do
      if P.get(x, "goto") == name then Y.remove(x, "goto") end
    end
    self:save()
    return
  end
  if name == nil then
    local n = 1
    while marks["Spot " .. n] ~= nil do n = n + 1 end
    name = "Spot " .. n
  end
  self:ask_where(function(spot)
    marks[name] = spot
    self:save()
  end)
end

-- a thing of the talk: added (from the catalog) on a spot, moved to another spot, or removed (and out of the lines
-- that show / hide it)
function DV:prop(name, k, template, mark, save)
  local a = self:step()
  if not Y.is_map(P.get(a, "props")) then a.props = Y.map() end
  local props = a.props
  if k == "add" then
    self.board:close_chooser()
    local base = P.replace((template:gsub("^.*\\", ""):gsub("%.[^.]*$", "")), "_", " ")
    local n = 1
    name = base
    while props[name] ~= nil do
      n = n + 1
      name = base .. " " .. n
    end
    props[name] = Y.map({"template", template, "mark", mark})
  elseif k:sub(1, 3) == "on:" then
    props[name].mark = k:sub(4)
  elseif k == "remove" then
    Y.remove(props, name)
    for _, x in ipairs(D.walk(D.from_step(a))) do
      for _, key in ipairs({"show", "hide"}) do
        local l = P.list(P.get(x, key))
        local has = false
        for _, t in ipairs(l) do if t == name then has = true end end
        if has then
          local keep = Y.list({})
          for _, t in ipairs(l) do if t ~= name then keep[#keep + 1] = t end end
          if #keep > 0 then x[key] = keep else Y.remove(x, key) end
        end
      end
    end
  end
  if #Y.keys(props) == 0 then Y.remove(a, "props") end
  if save ~= false then self:save() end
end

-- the editor camera now ({pos, yaw, pitch, fov}), or nil (the editor is not flying)
function DV:view()
  local cam = self.board.ed.cam
  if cam == nil or not cam.ready then
    self.board.ed.panel:say("No camera yet. Press F8 and fly to the camera's spot", nil, true)
    return nil
  end
  local N = require("conjunction.pynum")
  return Y.map({"pos", Y.list({N.round(cam.pos[1], 3), N.round(cam.pos[2], 3), N.round(cam.pos[3], 3)}),
                "yaw", N.round(cam.yaw % 360, 2), "pitch", N.round(cam.pitch, 2), "fov", N.round(cam.fov, 1)})
end

function DV:add_cam()
  local view = self:view()
  if view == nil then return end
  local a = self:step()
  if not Y.is_map(P.get(a, "cams")) then a.cams = Y.map() end
  local cams = a.cams
  local n = #Y.keys(cams) + 1
  while cams["Cam " .. n] ~= nil do n = n + 1 end
  cams["Cam " .. n] = view
  self:save()
end

function DV:own_cam(name, k)
  local a = self:step()
  local c = P.get(P.or_(P.get(a, "cams"), Y.map()), name)
  if c == nil then return end
  if k:sub(1, 8) == "default:" then            -- this camera for every line of theirs (the player's: choices too)
    local who = k:sub(9)
    if not Y.is_map(P.get(a, "cam_defaults")) then a.cam_defaults = Y.map() end
    local defaults = a.cam_defaults
    if defaults[who] == "cam:" .. name then Y.remove(defaults, who) else defaults[who] = "cam:" .. name end
    if #Y.keys(defaults) == 0 then Y.remove(a, "cam_defaults") end
    self:save()
    return
  end
  if k == "look" then
    self.board.ed:exec(string.format("cj_cam_set(%s, %s, %s, %s, %s)", P.str(c.pos[1]), P.str(c.pos[2]), P.str(c.pos[3]),
                                     P.str(c.yaw), P.str(c.pitch)))
    return
  end
  if k == "set" then
    local view = self:view()
    if view == nil then return end
    a.cams[name] = view
  elseif k == "remove" then
    Y.remove(a.cams, name)
    if #Y.keys(a.cams) == 0 then Y.remove(a, "cams") end
    for _, x in ipairs(D.walk(self:lines())) do      -- the lines that used it: their default camera again
      for _, f in ipairs({"camera", "glide"}) do
        if P.get(x, f) == "cam:" .. name then Y.remove(x, f) end
      end
    end
    local defaults = P.or_(P.get(a, "cam_defaults"), Y.map())
    for _, who in ipairs(Y.keys(defaults)) do
      if defaults[who] == "cam:" .. name then Y.remove(defaults, who) end
    end
    if P.has(a, "cam_defaults") and #Y.keys(defaults) == 0 then Y.remove(a, "cam_defaults") end
  end
  self:save()
end

-- --- who joins the talk: Pick (click them in the world) / Create (the catalog) / the people placed
function DV:toggle_adding()
  self.adding = (not self.adding) or nil
  self:sync()
end
function DV:request_person(how)
  local ed = self.board.ed
  if how == "create" then
    self.board:choose("people", function(path)
      ed:request_object("create", "people", function(place, index) self:add_person(place, index) end, path)
    end)
  else
    ed:request_object(how, "people", function(place, index) self:add_person(place, index) end)
  end
end
function DV:add_person(place, index)
  local oid = self.board.ed.project:name_object(place, index)
  local ref = place .. "/" .. oid
  local a = self:step()
  local known = ref == P.get(a, "npc")
  for _, w in ipairs(P.list(P.get(a, "with"))) do if w.who == ref then known = true end end
  if not known then
    if P.get(a, "with") == nil then a.with = Y.list({}) end
    a.with[#a.with + 1] = Y.map({"who", ref, "joins", "start"})
  end
  self.adding = nil
  self:save()
end


-- --- the sidebar's blocks (graph_blocks.BlockBar with the dialogue's own: Line, Choice, If)
function DV:blocks(x, y)
  local QBD = require("conjunction.ui.quest_board")
  local ty = y + 2
  local mx, my = w3.ui.mouse()
  for _, b in ipairs(DV.BLOCKS) do
    local box = {x = x, y = ty, w = 96, h = 40}
    local clicked, hovered, held = self:hit("dlg.block." .. b[1], box)
    local bp = self.block_press
    if held and (bp == nil or bp.block ~= b[1]) then
      bp = {block = b[1], x = mx, y = my}
      self.block_press = bp
    end
    local mine = bp ~= nil and bp.block == b[1]
    local t = QBD.tile_picture(self, b[1], b[2], DV.BLOCK_COLOUR[b[1]], hovered or (mine and held))
    if t then Dr.image(t[1], box.x, box.y, t[2], t[3]) end
    if hovered then CT.tip("dlg.block." .. b[1], "dblk." .. b[1]) end
    if mine then                                -- (graph_blocks.BlockTile: a drag over the flow, or a click)
      if held then
        if not bp.dragging and math.abs(mx - bp.x) + math.abs(my - bp.y) >= FV.MOVE_PX then bp.dragging = true end
        if bp.dragging and self.flow_rect then
          self.flow:block_over(b[1], math.floor(mx - self.flow_rect.x), math.floor(my - self.flow_rect.y))
        end
      else
        self.block_press = nil
        if bp.dragging and self.flow_rect then
          local inside, ref, row = self.flow:block_dropped(b[1], math.floor(mx - self.flow_rect.x),
                                                           math.floor(my - self.flow_rect.y))
          if inside then self:place(b[1], ref, row) end
        elseif clicked then
          self:click_block(b[1])
        end
      end
    end
    ty = ty + 40 + 4
  end
end
-- a block clicked (not dragged): after what is picked, else at the end of the talk
function DV:click_block(block)
  local f = self.flow
  self:place(block, f.chosen, f.chosen_row and f.chosen_row[2] or -1)
end

-- --- one frame on the tab's page
function DV:frame(pg)
  self:wait_where()
  self:voices_tick()
  if self.want_sync then
    local card = self.want_sync ~= "flow"
    self.want_sync = nil
    self:sync(card)
  end
  self.bg = self.board.panel.C.bg
  local x, y, w = pg.x, pg.y + 6, pg.w
  y = y + self:head_row(x, y, w) + 4
  y = y + self:people_row(x, y, w) + 4
  if self.adding then y = y + self:add_person_row(x, y, w) + 4 end
  if not P.T(P.get(self:step(), "swap")) and not self.monologue then y = y + self:cameras_row(x, y, w) + 4 end
  y = y - 4 + 6
  self:blocks(x, y)
  local fr = {x = x + 100 + 6, y = y, w = w - 106, h = pg.y + pg.h - y}
  local card = self.picked ~= nil and self:locate(self.picked) ~= nil
  local cr
  if card then                                  -- (the splitter: the flow a share of it, the card the rest)
    local total = fr.h - 5
    local top = math.floor(total * self.split_frac)
    -- (the card no higher than what is in it, at the bottom - the flow takes the rest; MaximdeWinter 13.11., as the quest
    -- board's since 24.10.: below a short card the page stayed empty. card_need: its height when last drawn)
    local need = self.card_need
    if need and total - top > need then top = total - need end
    cr = {x = fr.x, y = fr.y + top + 5, w = fr.w, h = total - top}
    fr.h = top
  end
  local pr = self.board.panel.rect
  if pr then self.flow.device = {pr.w, pr.h, fr.x - pr.x, fr.y - pr.y} end
  self.flow_rect = fr
  self.flow:frame(fr, CT.over(fr))
  if cr then
    Dr.fill(cr.x, cr.y - 5, cr.w, 5, self.bg)
    self:draw_card(cr)
  end
end

-- ===================================================================================================================
-- the cards (DialogueView._card): what is picked - a line's block (every line of it), a choice's, an If's, a script's
local W = require("conjunction.ui.qw")
local B = require("conjunction.ui.qb_widgets")
DV.C.line_bg, DV.C.line_edge, DV.C.choice_bg, DV.C.choice_edge = hex("#26262a"), hex("#3a3a40"), hex("#222226"),
                                                                  hex("#4a4a50")
DV.C.answer_bg, DV.C.answer_edge, DV.C.card = hex("#222226"), hex("#3a3a40"), hex("#1e1e1e")
DV.C.green, DV.C.red = hex("#5cb85c"), hex("#d9534f")

-- the leaves (their Qt sizes; drawn on the colour they lie on: self.under)
function DV:leaf_opt(id, text, on, tipkey, fn, o)
  o = o or {}
  local w, h
  if o.icon and text == "" then w, h = 16 + 12 + 2 + 3, 16 + 2 + 2 + 3
  else w, h = tool_size(text, 11, false, 6, 1, o.icon) end
  return W.leaf{w = w, h = h, hpol = "minimum", vpol = "fixed", hidden = o.hidden, draw = function(_, r)
    local was = self.bg
    self.bg = self.under or was
    local clicked
    if o.icon and text == "" then
      clicked = select(1, self:hit(id, r))
      local hovered = select(2, CT.hit_box(id .. ".h", r))
      if on then Dr.fill(r.x, r.y, r.w, r.h, C.opt_set_bg) Dr.rect(r.x, r.y, r.w, r.h, C.opt_set_edge, 1) end
      Q.draw_icon(o.icon, o.icon_colour or 0xcfcfcfff, 16, r.x + (r.w - 16) // 2, r.y + (r.h - 16) // 2)
      if hovered and tipkey then CT.tip(id, tipkey) end
    else
      clicked = self:opt(id, r, text, on, tipkey, o.icon, o.icon_colour)
    end
    self.bg = was
    if clicked and fn then fn(r) end
  end}
end

function DV:leaf_speaker(id, text, colour, tipkey, fn)
  local w, h = speaker_size(text)
  return W.leaf{w = w, h = h, hpol = "minimum", vpol = "fixed", align = "top", draw = function(_, r)
    if self:speaker(id, r, text, colour, tipkey) and fn then fn(r) end
  end}
end

function DV:leaf_icon(id, icon, tipkey, fn, colour)
  return W.leaf{w = 23, h = 23, vpol = "fixed", draw = function(_, r)
    local clicked, hovered = self:hit(id, r)
    if hovered then Dr.fill(r.x, r.y, r.w, r.h, 0xffffff14) end
    Q.draw_icon(icon, colour or (hovered and 0xffffffff or 0xcfcfcfff), 16, r.x + (r.w - 16) // 2, r.y + (r.h - 16) // 2)
    if hovered and tipkey then CT.tip(id, tipkey) end
    if clicked and fn then fn(r) end
  end}
end

function DV:leaf_plus(id, text, tipkey, fn)
  local w, h = plus_size(text)
  return W.leaf{w = w, h = h, hpol = "minimum", vpol = "fixed", draw = function(_, r)
    local was = self.bg
    self.bg = self.under or was
    local clicked = self:plus(id, r, text, tipkey)
    self.bg = was
    if clicked and fn then fn(r) end
  end}
end

local function leaf_label(text, colour, px, bold, o)
  o = o or {}
  return W.leaf{w = math.max(o.min_w or 0, Q.hint_w(text, px, bold)), h = Q.line_h(px, bold), fixed_w = o.fixed_w,
                align = o.align, draw = function(_, r)
    local tx = r.x
    if o.right then tx = r.x + r.w - Q.text_w(text, px, bold) end
    if o.center then tx = r.x + (r.w - Q.text_w(text, px, bold)) // 2 end
    local ty = o.top and r.y or (r.y + Q.vcenter(r.h, Q.line_h(px, bold)))
    Dr.clip(r.x, r.y, r.w, r.h, function() Q.text(tx, ty, colour, text, px, bold, o.bg or B.bg) end)
    if o.tip and CT.over(r) then CT.tip(o.tip_id or o.tip, o.tip) end
  end}
end
local function leaf_space(w) return W.leaf{w = w, h = 0, fixed_w = w} end
-- a row's tool (Hover: shown only while the mouse is on its row - its room kept when hidden, retainSizeWhenHidden)
local function ghost(leaf, shown)
  local draw = leaf.draw_fn
  leaf.draw_fn = function(n, r) if shown then draw(n, r) end end
  return leaf
end
local function hbox(items, spacing) return W.hbox({margins = {0, 0, 0, 0}, spacing = spacing or 4}, items) end

-- the speaker's colour index of the shared stylesheet (dialogue_view._speaker)
local function speaker_colour(colour)
  for _, c in ipairs(DV.SPEAKER_COLORS) do if c == colour then return colour end end
  return DV.SPEAKER_COLORS[1]
end

-- (a QToolButton's hint before its sheet polishes it - who.sizeHint() as the card reads it: the native look)
local function native_tool_w(text) return Q.hint_w(text, 12) + 2 * Q.text_w(" ", 12) + 3 end

function DV:set(d, key, value, rebuild)
  if value == nil then Y.remove(d, key) else d[key] = value end
  self:save(rebuild)
end

-- a line (DialogueView._line_card)
function DV:line_card(ls, k)
  local x = ls[k]
  local a = self:step()
  local key = P.str(P.or_(P.get(x, "who"), "npc"))
  local colour = speaker_colour(D.color(key, a))
  local names = self:names()
  local sid = idof(x)
  local who_text = PYS.upper(names[key] or D._label(key))
  local entries = {}
  for _, s2 in ipairs(D.speakers(a)) do entries[#entries + 1] = {s2[1], names[s2[1]] or P.str(s2[3])} end
  local who = self:leaf_speaker("dlg.line.who." .. sid, who_text, colour, "dlg.who", function(r)
    self:list("dlg.line.who." .. sid, r, entries, D.is_player(key) and D.PLAYER or key, function(k2) self:set(x, "who", k2) end)
  end)
  local fid = "dlg.line.text." .. sid
  local text = B.autotext(fid, P.str(P.get(x, "text", "")), "what they say", function(t) self:set_text(x, t) end,
                          {tip = "dlg.text", enter = function(t)
    CT.state(fid .. ".v").typed = nil
    self:next_line(ls, x, t)
  end})
  text.stretch = 1
  if self.focus_line == x then
    self.focus_line = nil
    CT.set_focus(fid)
    self.scroll_to = text                       -- (a new line below the cards' room: scrolled to - draw_card)
  end
  who.align = "top"
  local rows = {hbox({who, text})}
  local sw = native_tool_w(who_text)
  -- the voice, the thought, gesture, mood, camera (its move); the tools while the mouse is on the line
  local voiced = P.T(P.get(x, "voice")) or P.T(P.get(x, "voice_pack"))
  local voice
  if voiced then
    local what = P.T(P.get(x, "voice")) and "game line" or P.replace(P.str(x.voice_pack):match("^([^/]*)"), "_", " ")
    voice = self:leaf_opt("dlg.voice." .. sid, string.format("%s, %.1f s", what, tonumber(P.get(x, "dur") or 0) or 0), true,
                          "dlg.voice_set", function(r)
      self:list("dlg.voice." .. sid, r, {{"play", "Play"}, {"find", "Find another"}, {"none", "No voice"}}, nil,
                function(k2) self:voice_menu(x, k2) end)
    end, {icon = "audio-lines", icon_colour = C.green})
  else
    -- (named as its neighbours are: 11.11., a player looking for the voice saw only a red icon)
    voice = self:leaf_opt("dlg.voice." .. sid, "Voice", false, "dlg.voice", function() self:open_voice(x) end,
                          {icon = "audio-lines-x", icon_colour = C.red})
  end
  local row2 = {leaf_space(sw), voice}
  if D.is_player(P.get(x, "who")) then
    local th = P.T(P.get(x, "thought"))
    row2[#row2 + 1] = self:leaf_icon("dlg.thought." .. sid, th and "message-circle-dashed" or "message-circle", "dlg.thought",
                                     function() self:set(x, "thought", (not th) and true or nil) end,
                                     th and 0xffffffff or 0x6a6a70ff)
  end
  local g = P.get(x, "gesture")
  local have = self:body_of(key)
  local glabel = P.T(P.get(x, "anim")) and ("Gesture: " .. D.anim_label(P.str(x.anim))) or
                 (D.GESTURE[g] and ("Gesture: " .. D.GESTURE[g][1]))
                 or "Gesture"
  if have ~= nil and ((D.GESTURE[g] and not D.gesture_anim(g, have)) or (P.T(P.get(x, "anim")) and not have[x.anim])) then
    glabel = glabel .. " (not for them)"
  end
  local animal = type(have) == "table" and next(have) == nil
  local gcps = PYS.cps(glabel)
  glabel = PYS.from_cps(gcps, 1, math.min(60, #gcps))
  local gentries = {{nil, "None"}}
  for _, e in ipairs(D.gestures_for(have)) do gentries[#gentries + 1] = e end
  local n_have = 0
  if have ~= nil then for _ in pairs(have) do n_have = n_have + 1 end end
  gentries[#gentries + 1] = {"__find", string.format("Find another ... (%d)", have == nil and #D.all_animations() or n_have)}
  row2[#row2 + 1] = self:leaf_opt("dlg.gesture." .. sid, glabel, P.T(P.get(x, "anim")) or D.GESTURE[g] ~= nil, "dlg.gesture",
                                  function(r) self:list("dlg.gesture." .. sid, r, gentries, g, function(k2) self:gesture(x, k2) end) end,
                                  {hidden = animal})
  local m = P.get(x, "mood")
  local mentries = {{nil, "None"}}
  for _, e in ipairs(D.MOODS) do mentries[#mentries + 1] = e end
  row2[#row2 + 1] = self:leaf_opt("dlg.mood." .. sid, D.MOOD[m] and ("Mood: " .. D.MOOD[m]) or "Mood", D.MOOD[m] ~= nil,
                                  "dlg.mood", function(r) self:list("dlg.mood." .. sid, r, mentries, m, function(k2) self:set(x, "mood", k2) end) end,
                                  {hidden = animal})
  local shots, sentries = {}, {}
  for _, e in ipairs(D.SHOTS) do shots[e[1]] = e[2] sentries[#sentries + 1] = e end
  for _, n in ipairs(Y.keys(P.or_(P.get(a, "cams"), Y.map()))) do
    shots["cam:" .. n] = n
    sentries[#sentries + 1] = {"cam:" .. n, n}
  end
  local cv = P.get(x, "camera")
  row2[#row2 + 1] = self:leaf_opt("dlg.camera." .. sid, (P.T(cv) and shots[cv]) and ("Camera: " .. shots[cv]) or "Camera",
                                  P.T(cv), "dlg.camera", function(r)
    self:list("dlg.camera." .. sid, r, sentries, P.T(cv) and cv or "", function(k2) self:set(x, "camera", (k2 ~= "" and k2) or nil) end)
  end)
  if P.T(cv) then
    local gv = P.get(x, "glide")
    local gl = {{nil, "Cut"}}
    for _, e in ipairs(sentries) do if e[1] ~= "" and e[1] ~= cv then gl[#gl + 1] = e end end
    local glide = self:leaf_opt("dlg.glide." .. sid, (P.T(gv) and shots[gv]) and ("Moves from " .. shots[gv]) or "Cut",
                                P.T(gv), "dlg.glide", function(r)
      self:list("dlg.glide." .. sid, r, gl, gv, function(k2) self:set(x, "glide", k2) end)
    end)
    if P.str(gv):sub(1, 4) == "cam:" and P.str(cv):sub(1, 4) == "cam:" then    -- (two own cameras: seen in the world)
      glide = W.widget(hbox({glide, self:leaf_icon("dlg.preview." .. sid, "play", "dlg.preview_move",
                                                   function() self:preview_move(x) end)}))
    end
    row2[#row2 + 1] = glide
  end
  row2[#row2 + 1] = W.stretch(1)
  local hover = self.hover_line == sid
  row2[#row2 + 1] = ghost(B.button("dlg.add_variant." .. sid, "+ variant", function() self:add_alt(x) end, "small",
                                   {tip = "dlg.add_variant"}), hover)
  row2[#row2 + 1] = ghost(self:leaf_icon("dlg.remove." .. sid, "trash-2", "dlg.remove", function() self:remove(ls, k) end),
                          hover)
  rows[#rows + 1] = hbox(row2)
  -- pose, looks at, extras, the length
  local po = P.get(x, "pose")
  local pentries = {{nil, "Keeps their pose"}}
  for _, e in ipairs(D.poses_for(have)) do pentries[#pentries + 1] = e end
  local lk = P.get(x, "look")
  local lentries = {{nil, "Nobody in particular"}}
  for _, s2 in ipairs(D.speakers(a)) do if s2[1] ~= key then lentries[#lentries + 1] = {s2[1], names[s2[1]] or P.str(s2[3])} end end
  local row3 = {leaf_space(sw),
    self:leaf_opt("dlg.pose." .. sid, D.POSE[po] and ("Pose: " .. D.POSE[po]) or "Pose", D.POSE[po] ~= nil, "dlg.pose",
                  function(r) self:list("dlg.lpose." .. sid, r, pentries, po, function(k2) self:set(x, "pose", k2) end) end,
                  {hidden = animal}),
    self:leaf_opt("dlg.look." .. sid, names[lk] and ("Looks at " .. names[lk]) or "Looks at", names[lk] ~= nil, "dlg.look",
                  function(r) self:list("dlg.look." .. sid, r, lentries, lk, function(k2) self:set(x, "look", k2) end) end),
    self:also_leaf(x, sid), self:length_leaf(x, sid), W.stretch(1)}
  rows[#rows + 1] = hbox(row3)
  local card = W.widget(W.vbox({margins = {6, 4, 6, 3}, spacing = 2}, rows), {
    margins = {3, 1, 1, 1},
    draw = function(_, r)
      Dr.fill(r.x, r.y, r.w, r.h, C.line_bg)
      Dr.rect(r.x, r.y, r.w, r.h, C.line_edge, 1)
      Dr.fill(r.x, r.y, 3, r.h, hex(colour))
      self.was_under, self.under = self.under, C.line_bg
      B.bg = C.line_bg
      if CT.over(r) then self.hover_next = sid end
    end,
    after = function() self.under = self.was_under end,
  })
  return card
end

-- Extras: what else happens with the line (DialogueView._also_button)
DV.ALSO = {{"sound", "A sound"}, {"hold", "Holds a thing"}, {"sword:steel", "Draws the steel sword"},
           {"sword:silver", "Draws the silver sword"}, {"hold:", "Puts it away"}, {"appearance", "Another look"},
           {"fade:out", "Screen goes black at the end"}, {"fade:in", "Screen comes back at the start"}}
function DV.also_on(x, k)
  local key, val = k:match("^([^:]*):?(.*)$")
  if key == "hold" and val == "" and k:sub(-1) == ":" then return P.get(x, "hold") == "" end
  if val ~= "" then return P.get(x, key) == val end
  return P.has(x, key) and (key ~= "hold" or x[key] ~= "")
end
function DV:also_leaf(x, sid)
  local on = {}
  for _, e in ipairs(DV.ALSO) do if DV.also_on(x, e[1]) then on[#on + 1] = e[2] end end
  if P.T(P.get(x, "goto")) then on[#on + 1] = "goes to " .. P.str(x["goto"]) end
  for _, s2 in ipairs({"show", "hide"}) do
    for _, t in ipairs(P.list(P.get(x, s2))) do on[#on + 1] = s2 .. "s " .. P.str(t) end
  end
  local text = "Extras"
  if #on > 0 then
    local cps = PYS.cps("Extras: " .. table.concat(on, ", "))
    text = PYS.from_cps(cps, 1, math.min(60, #cps))
  end
  return self:leaf_opt("dlg.also." .. sid, text, #on > 0, "dlg.also")
end

-- [Length] [ s ] (lip sync): empty - as long as the voice / the mouth (dialogue_view.length_field)
function DV:length_leaf(x, sid)
  local lab = leaf_label("Length", C.note, 11, false)
  local fid = "dlg.length." .. sid
  local now = P.T(P.get(x, "length")) and NUMSTR(x.length) or ""
  local edit = W.leaf{w = 52, h = CT.edit_h(), fixed_w = 52, vpol = "fixed", draw = function(_, r)
    local st = CT.state(fid)
    local _, t, enter = CT.edit(fid, r.x, r.y, r.w, st.typed or now, {placeholder = "auto", tip = "dlg.length", h = r.h,
                                                                     style = self.board.panel.EDIT_STYLE})
    st.typed = t
    local focused = CT.focus == fid
    if (st.had and not focused) or enter then
      st.typed = nil
      local v = tonumber((PYS.strip(t):gsub(",", ".")))
      if PYS.strip(t) ~= "" and v == nil then v = P.get(x, "length") end
      if v ~= nil then v = require("conjunction.pynum").round(v, 2) end
      self:set(x, "length", (v and v > 0) and v or nil)
    end
    if not focused and not enter then st.typed = nil end
    st.had = focused
  end}
  local unit = leaf_label("s", C.note, 11, false)
  local s = DV.lip_seconds(x)
  local items = {lab, edit, unit}
  if s and s ~= 0 then items[#items + 1] = leaf_label(string.format("(lip sync %.1f s)", s), C.note, 11, false)
  else items[#items + 1] = W.leaf{w = 5, h = Q.line_h(11)} end
  return W.widget(hbox(items))
end

-- a choice (DialogueView._choice_card): CHOICE, its time to choose, its answers - each with how it ends
function DV:choice_card(ls, k)
  local x = ls[k]
  local answers = P.list(x.choice)
  local sid = idof(x)
  local t = P.get(x, "time")
  local tentries = {{nil, "no time limit"}, {3, "3 seconds"}, {5, "5 seconds"}, {8, "8 seconds"}, {12, "12 seconds"}}
  local rows = {hbox({leaf_label("CHOICE", hex("#b99be6"), 11, true),
                      self:leaf_opt("dlg.timed." .. sid, P.T(t) and (NUMSTR(t) .. " s to choose") or "no time limit",
                                    P.T(t), "dlg.timed", function(r)
                        self:list("dlg.timed." .. sid, r, tentries, t, function(v) self:set(x, "time", v) end)
                      end),
                      W.stretch(1), self:leaf_icon("dlg.remove_choice." .. sid, "trash-2", "dlg.remove_choice",
                                                   function() self:remove(ls, k) end)})}
  local nested = self:owner(ls) ~= nil
  for j, c in ipairs(answers) do
    rows[#rows + 1] = self:answer_row(answers, j)
    rows[#rows + 1] = self:answer_end(c, nested)
  end
  rows[#rows + 1] = hbox({self:leaf_plus("dlg.add_answer." .. sid, "+ option", "dlg.add_answer",
                                         function() self:add_answer(answers) end), W.stretch(1)})
  return W.widget(W.vbox({margins = {6, 5, 6, 6}, spacing = 3}, rows), {
    margins = {1, 1, 1, 1},
    draw = function(_, r)
      Dr.fill(r.x, r.y, r.w, r.h, C.choice_bg)
      Dr.rect(r.x, r.y, r.w, r.h, C.choice_edge, 1)
      self.was_under2, self.under = self.under, C.choice_bg
      B.bg = C.choice_bg
    end,
    after = function() self.under = self.was_under2 end,
  })
end

function DV:answer_row(answers, j)
  local c = answers[j]
  local sid = idof(c)
  local num = leaf_label(tostring(j), hex(D.GERALT_COLOR), 12, true, {min_w = 18, center = true})
  local tid = "dlg.answer." .. sid
  local text = W.leaf{w = 17 * Q.text_w("x") + 16, h = CT.edit_h(), min_w = 42, hpol = "expanding", vpol = "fixed",
                      draw = function(_, r)
    local st = CT.state(tid)
    local now = P.str(P.get(c, "text", ""))
    local _, t, enter = CT.edit(tid, r.x, r.y, r.w, st.typed or now, {placeholder = "Option text", tip = "dlg.answer",
                                                                     h = r.h, style = self.board.panel.EDIT_STYLE})
    st.typed = t
    local focused = CT.focus == tid
    if (st.had and not focused) or enter then
      st.typed = nil
      self:set(c, "text", PYS.strip(t), false)
    end
    if not focused and not enter then st.typed = nil end
    st.had = focused
  end}
  text.stretch = 1
  local once = P.T(P.get(c, "once"))
  local items = {num, text,
    self:leaf_icon("dlg.once." .. sid, "repeat-1", "dlg.once", function() self:set(c, "once", (not once) and true or nil) end,
                   once and 0xffffffff or 0x6a6a70ff),
    self:leaf_icon("dlg.add_condition." .. sid, "plus", "dlg.add_condition", function(r)
      self:list("dlg.add_condition." .. sid, r, self:condition_entries(c, answers), nil,
                function(f) self:add_condition(c, f) end)
    end)}
  local any = false
  for _, d in ipairs(DV.ANSWER_DOES) do if P.T(P.get(c, d[1])) then any = true end end
  items[#items + 1] = self:leaf_opt("dlg.does." .. sid, "Effects", any, "dlg.does", function(r)
    self:list("dlg.does." .. sid, r, DV.ANSWER_DOES, nil, function(k2) self:answer_does(c, k2) end)
  end)
  local hover = self.hover_line == sid
  items[#items + 1] = ghost(self:leaf_icon("dlg.up." .. sid, "chevron-up", "pan.up", function() self:move(answers, j, -1) end),
                            hover)
  items[#items + 1] = ghost(self:leaf_icon("dlg.down." .. sid, "chevron-down", "pan.down",
                                           function() self:move(answers, j, 1) end), hover)
  items[#items + 1] = ghost(self:leaf_icon("dlg.rm." .. sid, "trash-2", "dlg.remove",
                                           function() self:remove(answers, j, true) end), hover)
  return W.widget(W.hbox({margins = {4, 3, 4, 3}, spacing = 4}, items), {
    margins = {3, 1, 1, 1},
    draw = function(_, r)
      Dr.fill(r.x, r.y, r.w, r.h, C.answer_bg)
      Dr.rect(r.x, r.y, r.w, r.h, C.answer_edge, 1)
      Dr.fill(r.x, r.y, 3, r.h, hex(D.GERALT_COLOR))
      B.bg = C.answer_bg
      if CT.over(r) then self.hover_next = sid end
    end,
  })
end
DV.ANSWER_DOES = {{"emphasize", "Main option (yellow, first)"}, {"pay", "Player pays crowns"},
                  {"axii", "Persuade with Axii"}, {"give", "Player gives an item"},
                  {"receive", "Player receives something"}, {"shop", "Opens the shop"}}

function DV.answer_ends(nested)
  local out = {{"on", "Continue dialogue"}, {"back", "Back to choice"}}
  if nested then out[#out + 1] = {"up", "Back to previous choice"} end
  for _, e in ipairs({{"continue", "End: continue quest"}, {"own", "End: own output"}, {"retry", "End: repeatable"},
                      {"fail", "End: fail quest"}}) do
    out[#out + 1] = e
  end
  return out
end

-- an output of the talk's node of its own for answer c (MaximdeWinter 13.11.: a choice in the dialogue, still one output -
-- there was no way to split the quest at an answer): "path:<id>", named after the answer in quest.outcomes (the
-- graph's port path_<id>, the build's fact value 10, 11, ... - dialogue_scene.codes)
function DV:new_output(c)
  local q = self.board:quest()
  if not Y.is_map(P.get(q, "outcomes")) then q.outcomes = Y.map() end
  local text = PYS.strip(P.str(P.get(c, "text")))
  local base = PYS.lower(text):gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", ""):sub(1, 24)
  if base == "" then base = "answer" end
  local paths = P.or_(P.get(q, "paths"), Y.map())
  local id, k = base, 2
  while P.get(q.outcomes, id) ~= nil or P.get(paths, id) ~= nil do
    id, k = base .. "_" .. k, k + 1
  end
  q.outcomes[id] = text ~= "" and text or id
  return id
end

-- under an answer: how it ends (its colour, a #444 border, 11 px, padding 1px 8px)
function DV:answer_end(c, nested)
  local e = P.str(P.or_(P.get(c, "end"), "continue"))
  local entries = DV.answer_ends(nested)
  local own = e:sub(1, 5) == "path:"
  local now = own and "own" or F.kind(e)
  local label = now
  for _, en in ipairs(entries) do if en[1] == now then label = en[2] end end
  if own then
    label = "Output: " .. P.str(require("conjunction.quest_nodes").label_of(self.board:quest(), e:sub(6)))
  end
  local sid = idof(c)
  local w, h = tool_size(label, 11, false, 8, 1)
  local colour = hex(own and require("conjunction.questboard").path_color(e:sub(6)) or F.COLOUR[now] or "#bbbbbb")
  local endl = W.leaf{w = w, h = h, hpol = "minimum", vpol = "fixed", draw = function(_, r)
    local clicked, hovered = self:hit("dlg.end." .. sid, r)
    Dr.rect(r.x, r.y, r.w, r.h, hovered and hex("#999999") or hex("#444444"), 1)
    local tw = Q.text_w(label, 11)
    Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(11)), colour, label, 11, false, self.under or self.bg)
    if hovered then CT.tip("dlg.end." .. sid, "dlg.end") end
    if clicked then
      self:list("dlg.end." .. sid, r, entries, now, function(k2)
        if k2 == "own" and own then return end
        c["end"] = k2 == "own" and ("path:" .. self:new_output(c)) or k2
        -- (QBD.save: the node's wires follow its outputs - one "next", or "continue" beside an answer's own)
        self.board:save()
        self.want_sync = "card"
      end)
    end
  end}
  local items = {leaf_space(26), endl}
  for _, chip in ipairs(self:condition_chips(c)) do items[#items + 1] = chip end
  local extras = self:answer_extras(c)
  if extras then items[#items + 1] = extras end
  items[#items + 1] = W.stretch(1)
  return hbox(items)
end

-- a Python str[:n] (in code points)
local function head(t, n)
  local cps = PYS.cps(t)
  if #cps <= n then return t end
  return PYS.from_cps(cps, 1, n)
end
local function holds_value(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

-- --- conditions: when an option shows (all of them must hold)
-- {{option, label}} of the talks the quest has before this one (its node's ancestors in the graph) - 'After option'
-- can ask for any of them (DialogueView._options_before; the app walks a set of nodes, here the quest's order)
function DV:options_before()
  local q = self.board:quest()
  local me = self:step()
  local nodes, links = P.or_(P.get(q, "nodes"), Y.map()), P.list(P.get(q, "links"))
  local function first(st)
    if not P.T(st) then return nil, Y.map() end
    local kind = Y.keys(st)[1]
    return kind, st[kind]
  end
  local function holds(st)
    local _, a = first(st)
    if rawequal(a, me) then return true end
    if Y.is_map(a) then
      for _, cl in ipairs(P.list(P.get(a, "clues"))) do if rawequal(cl, me) then return true end end
    end
    return false
  end
  local mine
  for _, nid in ipairs(Y.keys(nodes)) do
    if holds(P.or_(P.get(nodes[nid], "step"), Y.map())) then mine = nid break end
  end
  local before, todo = {}, mine and {mine} or {}
  while #todo > 0 do
    local nid = table.remove(todo)
    for _, l in ipairs(links) do
      if l[3] == nid and not before[l[1]] then
        before[l[1]] = true
        todo[#todo + 1] = l[1]
      end
    end
  end
  local out = {}
  for _, nid in ipairs(Y.keys(nodes)) do
    local st = before[nid] and P.or_(P.get(nodes[nid], "step"), Y.map()) or nil
    if st and P.T(st) then
      local kind, a = first(st)
      local talks = {}
      if kind == "talk" then
        talks[1] = {P.str(P.or_(P.get(a, "text"), "Talk")), a}
      elseif kind == "clues" then
        for k, cl in ipairs(P.list(P.get(a, "clues"))) do
          if P.T(P.get(cl, "dialogue")) then talks[#talks + 1] = {"Monologue " .. k, cl} end
        end
      end
      for _, t in ipairs(talks) do
        local holder = t[2]
        local lines = P.get(holder, "dialogue") == nil and D.from_step(holder) or holder.dialogue
        for _, o in ipairs(D.walk(P.list(lines))) do
          if not P.has(o, "who") and P.T(P.get(o, "text")) then
            out[#out + 1] = {o, t[1] .. ": " .. P.str(o.text)}
          end
        end
      end
    end
  end
  return out
end

-- what '+' can add: after all others, after an option (this talk's, earlier talks'), after a branch, the player has an
-- item (DialogueView._condition_entries)
function DV:condition_entries(c, answers)
  local QN = require("conjunction.quest_nodes")
  local have = D.conditions(c)
  local out = {}
  if #answers > 1 and not holds_value(have, D.AFTER_ALL) then out[#out + 1] = {D.AFTER_ALL, "After all other options"} end
  local opts = {}
  for _, o in ipairs(D.walk(self:lines())) do
    if not P.has(o, "who") and not rawequal(o, c) and P.T(P.get(o, "text")) then
      opts[#opts + 1] = {o, "This dialogue: " .. P.str(o.text)}
    end
  end
  for _, e in ipairs(self:options_before()) do opts[#opts + 1] = e end
  self.cond_options = {}
  for k, e in ipairs(opts) do
    local o = e[1]
    local key = P.T(P.get(o, "id")) and ("@" .. P.str(o.id)) or ("@#" .. (k - 1))
    self.cond_options[key] = o
    if not holds_value(have, key) then out[#out + 1] = {key, head("After option - " .. e[2], 80)} end
  end
  local qid = self.board.ed.project.id
  local paths = P.or_(P.get(self.board:quest(), "paths"), Y.map())
  for _, pid in ipairs(Y.keys(paths)) do
    local f = QN.path_fact(qid, pid)
    if not holds_value(have, f) then
      out[#out + 1] = {f, "After branch: " .. P.str(P.or_(P.get(paths[pid], "label"), pid))}
    end
  end
  if not Y.is_map(P.get(c, "needs")) then out[#out + 1] = {"__needs", "Player has an item..."} end
  return out
end

function DV:add_condition(c, key)
  if key == "__needs" then
    c.needs = Y.map({"item", "", "count", 1, "money", 0})
    self:save()
    return
  end
  if key:sub(1, 2) == "@#" then                 -- an option without an id yet: it gets one now
    local o = self.cond_options[key]
    if not P.T(P.get(o, "id")) then o.id = require("conjunction.marks").uuid4_hex():sub(1, 8) end
    key = "@" .. P.str(o.id)
  end
  local conds = D.conditions(c)
  conds[#conds + 1] = key
  D.set_conditions(c, conds)
  self:save()
end

function DV:remove_condition(c, k)
  local conds = D.conditions(c)
  table.remove(conds, k)
  D.set_conditions(c, conds)
  self:save()
end

function DV:condition_label(cond)
  if cond == D.AFTER_ALL then return "After all other options" end
  if type(cond) == "string" and cond:sub(1, 1) == "@" then
    local id = cond:sub(2)
    local o
    for _, e in ipairs(self:options_before()) do
      if P.get(e[1], "id") == id then o = e[1] break end
    end
    if not o then
      for _, x in ipairs(D.walk(self:lines())) do
        if not P.has(x, "who") and P.get(x, "id") == id then o = x break end
      end
    end
    return head("After option: " .. (o and P.str(P.get(o, "text")) or id), 60)
  end
  if type(cond) == "string" then
    local paths = P.or_(P.get(self.board:quest(), "paths"), Y.map())
    local p
    for _, pid in ipairs(Y.keys(paths)) do
      local tail = "_path_" .. pid
      if cond:sub(-#tail) == tail then p = paths[pid] break end
    end
    return head("After branch: " .. P.str(P.or_(P.get(p or Y.map(), "label"), cond)), 60)
  end
  return head("If " .. P.replace(P.str(cond[1]), "_", " ") .. " " .. P.str(cond[2]) .. " " .. P.str(cond[3]), 60)
end

-- the option's conditions as chips (#9fb0ff, 11 px, a #444 border, padding 1px 6px - QLabel's indent with it), each
-- with its trash can (DialogueView._condition_chips)
function DV:condition_chips(c)
  local out = {}
  local sid = idof(c)
  for k, cond in ipairs(D.conditions(c)) do
    local text = self:condition_label(cond)
    local ind = Q.label_indent(11)
    local id = "dlg.chip." .. k .. "." .. sid
    out[#out + 1] = W.leaf{w = Q.hint_w(text, 11) + ind + 12 + 2, h = Q.line_h(11) + 2 + 2,
                           draw = function(_, r)
      Dr.rect(r.x, r.y, r.w, r.h, hex("#444444"), 1)
      Q.text(r.x + 1 + 6 + ind // 2, r.y + Q.vcenter(r.h, Q.line_h(11)), hex("#9fb0ff"), text, 11, false, B.bg)
      if CT.over(r) then CT.tip(id, "dlg.only_if") end
    end}
    out[#out + 1] = self:leaf_icon("dlg.rm_cond." .. k .. "." .. sid, "trash-2", "dlg.remove",
                                   function() self:remove_condition(c, k) end)
  end
  return out
end

-- a row with what the answer does and needs (only those set) (DialogueView._answer_extras)
function DV:answer_extras(c)
  local QC = require("conjunction.ui.quest_card")
  local parts = {}
  local sid = idof(c)
  local function spin(d, key, lo, hi, suffix)
    local v = math.tointeger(tonumber(P.get(d, key, 0)) or 0) or 0
    v = math.max(lo, math.min(hi, v))
    local sp = B.spin("dlg.spin." .. idof(d) .. "." .. key, v, lo, hi, function(x)
      self:set(d, key, x ~= 0 and x or nil, false)
    end)
    return B.with_unit(sp, suffix)
  end
  local function item(d)
    return QC.item_line(self.board, d, "item", {on_set = function(ref) self:set(d, "item", ref or "") end})
  end
  local function label(text, colour) return leaf_label(text, hex(colour or "#bbbbbb"), 11, false) end
  if P.T(P.get(c, "emphasize")) then parts[#parts + 1] = label("main option (yellow)", "#e3c65f") end
  if P.T(P.get(c, "axii")) then parts[#parts + 1] = label("Axii", "#9fb0ff") end
  if P.T(P.get(c, "shop")) then parts[#parts + 1] = label("opens the shop", "#9fb0ff") end
  if P.T(P.get(c, "icon")) then parts[#parts + 1] = label("icon: " .. P.str(c.icon), "#9fb0ff") end
  if P.T(P.get(c, "pay")) then
    parts[#parts + 1] = label("pays")
    parts[#parts + 1] = spin(c, "pay", 1, 100000, " crowns")
  end
  if Y.is_map(P.get(c, "give")) then
    parts[#parts + 1] = label("gives")
    parts[#parts + 1] = item(c.give)
    parts[#parts + 1] = spin(c.give, "count", 1, 999, "x")
  end
  if Y.is_map(P.get(c, "receive")) then
    local d = c.receive
    for _, x in ipairs({label("receives"), item(d), spin(d, "count", 0, 999, "x"), spin(d, "money", 0, 100000, " crowns"),
                        spin(d, "xp", 0, 100000, " xp")}) do parts[#parts + 1] = x end
  end
  if Y.is_map(P.get(c, "needs")) then
    local d = c.needs
    for _, x in ipairs({label("player has", "#9fb0ff"), item(d), spin(d, "count", 1, 999, "x"),
                        spin(d, "money", 0, 100000, " crowns"),
                        self:leaf_icon("dlg.rm_needs." .. sid, "trash-2", "dlg.remove", function()
                          Y.remove(c, "needs")
                          self:save()
                        end)}) do parts[#parts + 1] = x end
  end
  if #parts == 0 then return nil end
  parts[#parts + 1] = W.stretch(1)
  return W.widget(hbox(parts))
end

-- the end of an If's / random's way: on as around it, or like an answer's (DialogueView._branch_end)
function DV:branch_end(br, id)
  local entries = {{nil, "Continue"}}
  for _, e in ipairs(D.ENDS) do entries[#entries + 1] = e end
  local e = P.get(br, "end")
  local label = "Continue"
  if P.T(e) then
    label = P.str(e)
    for _, en in ipairs(entries) do if en[1] == e then label = en[2] end end
  end
  local w, h = tool_size(label, 11, false, 8, 1)
  return W.leaf{w = w, h = h, hpol = "minimum", vpol = "fixed", draw = function(_, r)
    local clicked, hovered = self:hit(id, r)
    Dr.rect(r.x, r.y, r.w, r.h, hovered and hex("#999999") or hex("#444444"), 1)
    local tw = Q.text_w(label, 11)
    Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(11)), hex("#bbbbbb"), label, 11, false, self.under or self.bg)
    if hovered then CT.tip(id, "dlg.end") end
    if clicked then self:list(id, r, entries, e, function(k2) self:set(br, "end", k2) end) end
  end}
end

DV.IF_OPS = {{">=", "at least"}, {"=", "is"}, {"<", "less than"}, {"!=", "is not"}}
local function frame_box(self, rows, spacing)
  return W.widget(W.vbox({margins = {6, 5, 6, 6}, spacing = spacing}, rows), {
    margins = {1, 1, 1, 1},
    draw = function(_, r)
      Dr.fill(r.x, r.y, r.w, r.h, C.choice_bg)
      Dr.rect(r.x, r.y, r.w, r.h, C.choice_edge, 1)
      self.was_under3, self.under = self.under, C.choice_bg
      B.bg = C.choice_bg
    end,
    after = function() self.under = self.was_under3 end,
  })
end

-- an If: 'if <fact> is at least <n>' - then one way, otherwise the other (DialogueView._if_card)
function DV:if_card(ls, k)
  local x = ls[k]
  if P.get(x, "if") == nil then x["if"] = Y.map({"fact", "", "op", ">=", "value", 1}) end
  local c = x["if"]
  local sid = idof(x)
  local fact = B.line("dlg.if_fact." .. sid, P.str(P.get(c, "fact", "")), "A fact (a decision, a moment of a quest)",
                      function(t)
    local name = require("conjunction.project").fact_id(t)
    self:set(c, "fact", name, false)
  end, {tip = "dlg.if_fact"})
  fact.stretch = 1
  local op = P.str(P.get(c, "op", ">="))
  local oplabel = "at least"
  for _, o in ipairs(DV.IF_OPS) do if o[1] == op then oplabel = o[2] end end
  local rows = {hbox({leaf_label("IF", hex("#d9a45b"), 11, true), fact,
                      self:leaf_opt("dlg.if_op." .. sid, oplabel, true, "dlg.if_op", function(r)
                        self:list("dlg.if_op." .. sid, r, DV.IF_OPS, op, function(v) self:set(c, "op", v) end)
                      end),
                      B.spin("dlg.if_value." .. sid, math.tointeger(tonumber(P.get(c, "value", 1)) or 1) or 1, 0, 999,
                             function(v) self:set(c, "value", v, false) end, {tip = "dlg.if_value"}),
                      self:leaf_icon("dlg.remove_if." .. sid, "trash-2", "dlg.remove_if", function() self:remove(ls, k) end)})}
  for _, side in ipairs({{"then", "THEN"}, {"else", "OTHERWISE"}}) do
    if P.get(x, side[1]) == nil then x[side[1]] = Y.map() end
    rows[#rows + 1] = hbox({leaf_label(side[2], hex("#bbbbbb"), 11, true, {fixed_w = 80}),
                            self:branch_end(x[side[1]], "dlg.if_end." .. side[1] .. "." .. sid), W.stretch(1)})
  end
  return frame_box(self, rows, 4)
end

-- one of these ways, at random (from a game scene) (DialogueView._random_card)
function DV:random_card(ls, k)
  local x = ls[k]
  local sid = idof(x)
  local rows = {hbox({leaf_label("ONE OF THESE, AT RANDOM", hex("#d9a45b"), 11, true), W.stretch(1),
                      self:leaf_icon("dlg.remove_random." .. sid, "trash-2", "dlg.remove_random",
                                     function() self:remove(ls, k) end)})}
  for j, br in ipairs(P.list(P.get(x, "random"))) do
    rows[#rows + 1] = hbox({leaf_label("OUTCOME " .. j, hex("#bbbbbb"), 11, true, {fixed_w = 80}),
                            self:branch_end(br, "dlg.random_end." .. j .. "." .. sid), W.stretch(1)})
  end
  return frame_box(self, rows, 4)
end

-- a script the scene runs here (from the game's scene) (DialogueView._script_row)
function DV:script_row(ls, k)
  local sc = P.or_(P.get(ls[k], "script"), Y.map())
  local args = {}
  for _, d in ipairs(P.list(P.get(sc, "parameter"))) do
    for _, n in ipairs(Y.keys(d)) do args[#args + 1] = n .. "=" .. P.replace(P.str(d[n]), "cname_", "") end
  end
  local text = "Does: " .. P.str(P.get(sc, "function", "?")) .. "(" .. table.concat(args, ", ") .. ")"
  local lab = leaf_label(text, hex("#9fb0ff"), 12, false, {tip = "dlg.script", tip_id = "dlg.script." .. idof(ls[k])})
  lab.stretch = 1
  return hbox({lab,
               self:leaf_icon("dlg.remove_script." .. idof(ls[k]), "trash-2", "dlg.remove", function() self:remove(ls, k) end)})
end

-- --- the card under the flow, in its scroll area (margins 0 6 6 4, 4 apart)
function DV:card_tree()
  local at = self.picked ~= nil and self:locate(self.picked) or nil
  if at == nil then return nil end
  local items = {}
  if #at == 3 then
    items[1] = self:choice_card(at[1], at[2])
  else
    local ls, k = at[1], at[2]
    local x = ls[k]
    if P.has(x, "choice") then
      items[1] = self:choice_card(ls, k)
    elseif P.has(x, "if") then
      items[1] = self:if_card(ls, k)
    elseif P.has(x, "random") then
      items[1] = self:random_card(ls, k)
    elseif P.has(x, "script") then
      items[1] = self:script_row(ls, k)
    elseif P.has(x, "who") then              -- (a line: every line of its block)
      local first, last = k, k
      while first > 1 and P.has(ls[first - 1], "who") do first = first - 1 end
      while last < #ls and P.has(ls[last + 1], "who") do last = last + 1 end
      for j = first, last do
        items[#items + 1] = self:line_card(ls, j)
        if self.voice_open ~= nil and rawequal(self.voice_open, ls[j]) then
          local vs = self:voice_search(ls[j])
          items[#items + 1] = vs
          -- (just opened: into the cards' room - 11.11., Voice on a line at the room's bottom opened it out of sight)
          if self.voice_scroll ~= ls[j] then self.voice_scroll, self.scroll_to = ls[j], vs end
        end
        if self.anim_open ~= nil and rawequal(self.anim_open, ls[j]) then items[#items + 1] = self:anim_search(ls[j]) end
      end
      items[#items + 1] = hbox({self:leaf_plus("dlg.add_line", "+ line", "dlg.add_line",
                                               function() self:place_line(ls, last + 1) end), W.stretch(1)})
    end
  end
  items[#items + 1] = W.stretch(1)
  return W.widget(W.vbox({margins = {0, 6, 6, 4}, spacing = 4}, items))
end

function DV:draw_card(r)
  local IV = require("conjunction.ui.itemview")
  local SBAR = require("conjunction.ui.scrollbar")
  Dr.fill(r.x, r.y, r.w, r.h, C.card)
  B.EDIT_STYLE, B.window, B.bg = self.board.panel.EDIT_STYLE, self.board.panel.rect, C.card
  self.hover_line, self.hover_next = self.hover_next, nil
  self.under = C.card
  local body = self:card_tree()
  if body == nil then return end
  -- (QScrollArea, resizable, no horizontal bar: a body wider than the room is cut at the right)
  local min_w, min_h = W.min(body)
  local function need(w) return math.max(min_h, W.hfw(body, math.max(w, min_w))) end
  self.card_need = need(r.w)                      -- (DV.frame: the card's height next frame)
  local bar = need(r.w) > r.h
  local vw = bar and r.w - 10 or r.w
  local bw = math.max(vw, min_w)
  local bh = math.max(r.h, need(bw))
  self.card_bar = self.card_bar or IV.bar(1, 0, 0)
  local sb = self.card_bar
  sb.page = r.h
  IV.range(sb, bh - r.h)
  W.place(body, r.x, r.y - sb.value, bw, bh)
  -- (the line just made or picked into the room: it was added below it, typing went to a field out of sight, 07.11.)
  local want = self.scroll_to
  self.scroll_to = nil
  if want and want.r then
    local t, before = want.r, sb.value
    -- (a thing taller than the room - the voice search - shows from its top: its Game / Custom row)
    if t.y + t.h > r.y + r.h and t.h + 16 >= r.h then IV.set(sb, sb.value + (t.y - r.y) - 8)
    elseif t.y + t.h > r.y + r.h then IV.set(sb, sb.value + (t.y + t.h - (r.y + r.h)) + 8)
    elseif t.y < r.y then IV.set(sb, sb.value - (r.y - t.y) - 8) end
    if sb.value ~= before then W.place(body, r.x, r.y - sb.value, bw, bh) end
  end
  self.wheel_taken = nil
  Dr.clip(r.x, r.y, vw, r.h, function() W.draw(body) end)
  local _, _, wheel = w3.ui.mouse()
  if not self.wheel_taken and CT.over({x = r.x, y = r.y, w = vw, h = r.h}) and wheel ~= 0 then
    IV.set(sb, sb.value - math.floor(wheel * 3 * 20 + 0.5))
  end
  if bar then
    self.bar_state = self.bar_state or {}
    SBAR.draw(self.bar_state, "dlg.card_bar", sb, {x = r.x + vw, y = r.y, w = 10, h = r.h}, "v",
              function(id, rr) return CT.hit_box(id, rr) end)
  end
end

-- --- what the cards change
function DV:set_text(x, t)
  local v = PYS.strip(t)
  if v ~= P.str(P.get(x, "text", "")) then self:set(x, "text", v, false) end
end
function DV:next_line(ls, x, t)
  self:set_text(x, t)
  local at = self:locate(x, ls)
  local i = at and at[2] + 1 or #ls + 1
  local new = Y.map({"who", self:next_speaker(ls, i), "text", ""})
  table.insert(ls, i, new)
  self.picked, self.focus_line = new, new
  self:save()
end
-- speakers take turns: after the player the one who spoke before them, after anybody else the player; the first line
-- of the talk and of an answer's way is the NPC's (DialogueView._next_speaker)
function DV:next_speaker(ls, i)
  if self.monologue then return D.PLAYER end
  local said = {}
  for j = 1, i - 1 do if P.has(ls[j], "who") then said[#said + 1] = ls[j] end end
  if #said == 0 then return "npc" end
  if D.is_player(P.get(said[#said], "who")) then
    for j = #said, 1, -1 do
      local w = P.get(said[j], "who")
      if not D.is_player(w) then return w end
    end
    return "npc"
  end
  return D.PLAYER
end
function DV:remove_run(ls, a, b)
  for _ = a, b do table.remove(ls, a) end
  self.picked = nil
  self:save()
end
function DV:delete_picked()
  local at = self.picked ~= nil and self:locate(self.picked) or nil
  if not at then return end
  if #at == 3 then self:remove(P.list(at[1][at[2]].choice), at[3], true) else self:remove(at[1], at[2]) end
end
-- Esc: nothing picked any more (MaximdeWinter 13.11.) -> true when something was
function DV:deselect()
  if self.picked == nil then return false end
  self.picked = nil
  self.flow:select(nil, -1)
  return true
end
function DV:place_line(ls, i)
  local new = Y.map({"who", self:next_speaker(ls, i), "text", ""})
  table.insert(ls, i, new)
  self.picked, self.focus_line = new, new
  self:save()
end
function DV:add_alt(x)
  local alt = P.list(P.get(x, "alt"))
  local out = Y.list({})
  for _, v in ipairs(alt) do out[#out + 1] = v end
  out[#out + 1] = ""
  x.alt = out
  self:save()
end
function DV:remove(ls, k, keep_one)
  if keep_one and #ls <= 1 then return end
  local gone = ls[k]
  table.remove(ls, k)
  -- (the one picked gone: its neighbour of the same kind picked, the one before first - MaximdeWinter 13.11.: a line added
  -- and deleted again left nothing picked, its block with it)
  if self.picked == gone then
    local function alike(x) return x ~= nil and P.has(x, "who") == P.has(gone, "who") end
    self.picked = (alike(ls[k - 1]) and ls[k - 1]) or (alike(ls[k]) and ls[k]) or ls[k - 1] or ls[k]
  end
  self:save()
end
function DV:move(ls, j, d)
  local t = j + d
  if t < 1 or t > #ls then return end
  ls[j], ls[t] = ls[t], ls[j]
  self:save()
end
function DV:add_answer(answers)
  answers[#answers + 1] = Y.map({"text", "", "end", "back"})
  self:save()
end
function DV:answer_does(c, k)
  if P.T(P.get(c, k)) then Y.remove(c, k)
  else
    local init = {emphasize = true, axii = true, shop = true, pay = 50,
                  give = Y.map({"item", "", "count", 1}),
                  receive = Y.map({"item", "", "count", 1, "money", 0, "xp", 0}),
                  needs = Y.map({"item", "", "count", 1, "money", 0})}
    c[k] = init[k]
  end
  self:save()
end
-- the answer (or way of an If) whose lines ls are; nil for the talk's own (DialogueView._owner)
function DV:owner(ls, within)
  for _, x in ipairs(within or self:lines()) do
    local ways = {}
    for _, c in ipairs(P.list(P.get(x, "choice"))) do ways[#ways + 1] = c end
    for _, c in ipairs(P.list(P.get(x, "random"))) do ways[#ways + 1] = c end
    if P.has(x, "if") then
      ways[#ways + 1] = P.or_(P.get(x, "then"), Y.map())
      ways[#ways + 1] = P.or_(P.get(x, "else"), Y.map())
    end
    for _, d in ipairs(ways) do
      if P.get(d, "lines") == ls then return d end
      local found = self:owner(ls, P.list(P.get(d, "lines")))
      if found ~= nil then return found end
    end
  end
  return nil
end

-- (DialogueView._add_person_row: a QFrame#choice, margins 6 4 6 4, 2 apart)
function DV:add_person_row(x, y, w)
  local QS = require("conjunction.quest")
  local taken = {}
  for _, sp in ipairs(D.speakers(self:step())) do if sp[2] then taken[sp[2]] = true end end
  local rows = {hbox({B.button("dlg.pick_people", "Pick", function() self:request_person("pick") end, "small",
                               {tip = "qb.pick_people"}),
                      B.button("dlg.create_people", "Create", function() self:request_person("create") end, "small",
                               {tip = "qb.create_people"}),
                      W.stretch(1), self:leaf_icon("dlg.adding_x", "x", "qb.cancel", function() self:toggle_adding() end)})}
  local places = self.board.ed.project.places
  local names = Y.keys(places)
  table.sort(names)
  for _, place in ipairs(names) do
    for k, o in ipairs(P.list(P.get(places[place], "objects"))) do
      local ref = P.T(P.get(o, "id")) and (place .. "/" .. P.str(o.id)) or nil
      if QS.is_actor(o) and not (ref and taken[ref]) then
        local base = P.T(P.get(o, "id")) and P.str(o.id) or P.str(o.template):gsub("^.*\\", ""):gsub("%.[^.]*$", "")
        local text = P.replace(base, "_", " ") .. "    " .. place
        local id = "dlg.add_this." .. place .. "." .. k
        local e = W.leaf{w = Q.hint_w(text, 12) + 12, h = Q.line_h(12) + 6, hpol = "minimum", vpol = "fixed",
                         draw = function(_, r)
          local clicked, hovered = self:hit(id, r)
          local bg = hovered and hex("#34343a") or hex("#1d1d20")
          Dr.fill(r.x, r.y, r.w, r.h, bg)
          Dr.clip(r.x, r.y, r.w, r.h, function()
            Q.text(r.x + 6, r.y + 3 + Q.vcenter(r.h - 6, Q.line_h(12)), hex("#dddddd"), text, 12, false, bg)
          end)
          if hovered then CT.tip(id, "dlg.add_this_person") end
          if clicked then self:add_person(place, k - 1) end
        end}
        rows[#rows + 1] = e
      end
    end
  end
  local box = W.widget(W.vbox({margins = {6, 4, 6, 4}, spacing = 2}, rows), {
    margins = {1, 1, 1, 1},
    draw = function(_, r)
      Dr.fill(r.x, r.y, r.w, r.h, C.choice_bg)
      Dr.rect(r.x, r.y, r.w, r.h, C.choice_edge, 1)
      B.bg = C.choice_bg
    end,
  })
  local _, h = W.hint(box)
  B.EDIT_STYLE, B.window = self.board.panel.EDIT_STYLE, self.board.panel.rect
  W.place(box, x, y, w, h)
  W.draw(box)
  return h
end

-- ===================================================================================================================
-- the voice of a line: the game's own lines (searched by words) or recordings of the content packs
local VO = require("conjunction.voices")
local CP = require("conjunction.contentpacks")
DV.ENTRY_BG, DV.ENTRY_HOT, DV.ENTRY_FG = hex("#1d1d20"), hex("#34343a"), hex("#dddddd")

local function short(t, n)
  n = n or 80
  local cps = PYS.cps(t)
  if #cps <= n then return t end
  return PYS.rstrip(PYS.from_cps(cps, 1, n - 3)) .. "..."
end

-- the voicetag of whoever is played at this talk (Geralt, or Ciri after a 'Play as') - their voiced lines
function DV:player_voicetag()
  local p = P.get(D.PLAYERS, self:who_plays()) or D.PLAYERS.geralt
  return p.voicetag
end

function DV:open_voice(x)
  self.voice_open, self.picked, self.voice_scroll = x, x, nil
  self.voice_source = self.voice_source or "game"
  self:sync()
end
function DV:close_voice()
  self.voice_open = nil
  self:sync()
end
function DV:voice_from(source)
  self.voice_source = source
  -- (a field of its own: Game starts from the line's words, Custom from its last search - the focused field kept
  -- the line's words, and no recording matched them all)
  self.card_gen = (self.card_gen or 0) + 1
  self:sync()
end
function DV:pick_tag(tag, add)
  local tags = self.custom_tags or {}
  local only = next(tags) ~= nil and next(tags, next(tags)) == nil and tags[tag]
  if add then
    if tags[tag] then tags[tag] = nil else tags[tag] = true end
  elseif only then
    tags = {}
  else
    tags = {[tag] = true}
  end
  self.custom_tags = tags
  self:sync()
end

function DV:voice_menu(x, k)
  if k == "find" then
    self.voice_source = P.T(P.get(x, "voice_pack")) and "custom" or "game"
    self:open_voice(x)
  elseif k == "play" then
    if P.T(P.get(x, "voice")) then
      self:play_game(math.tointeger(tonumber(x.voice)))
    else
      local r = CP.voice(x.voice_pack)
      if r then self:play(r.file) end
    end
  else
    self:clear_voice(x)
  end
end
-- the voice of a line: its text stays when there is one (the subtitle is the line's text - MaximdeWinter 13.11.: his
-- typed text gave way to the recording's); an empty line takes what the voice says
local function empty_text(x) return PYS.strip(P.str(P.get(x, "text", ""))) == "" end
function DV:set_voice(x, r)
  Y.remove(x, "voice_pack")
  x.voice, x.dur = math.tointeger(r.id), VO.length(r.id, r.dur, r.text)
  if empty_text(x) then x.text = r.text end
  self.voice_open = nil
  self:save()
end
-- an own recording
function DV:set_custom(x, r)
  Y.remove(x, "voice")
  x.voice_pack, x.dur = r.key, (tonumber(r.dur) or 0) + 0.0
  if P.T(r.text) and empty_text(x) then x.text = r.text end
  self.voice_open = nil
  self:save()
end
function DV:clear_voice(x)
  for _, key in ipairs({"voice", "voice_pack", "dur"}) do Y.remove(x, key) end
  self:save()
end

-- plays a recording (again: stops it) - w3.sound: wav and ogg
function DV:play(path, key)
  key = key or path
  if self.sound then pcall(w3.sound.stop, self.sound) self.sound = nil end
  if self.playing == key then
    self.playing = nil
    return
  end
  local ok, h = pcall(w3.sound.play, path)
  if ok then self.sound, self.playing = h, key else self.board.ed.panel:say(tostring(h), nil, true) end
end
-- a game line: its audio is cut out of the game's speech file and decoded once (voices.listen)
function DV:play_game(sid)
  local key = "game:" .. sid
  if self.playing == key then self:play(nil, key) return end
  if not VO.vgmstream() then
    self.board.ed.panel:say("Listening to the game's voices needs vgmstream (vgmstream.org): vgmstream-cli.exe in the PATH",
                            nil, true)
    return
  end
  local job = VO.listen(sid)
  if not job then
    self.board.ed.panel:say("No audio for this line", nil, true)
    return
  end
  self.listen_job = {job = job, key = key}
end

-- each frame: the voices read (or built, a little each frame), a line decoded, a sound that ended
function DV:voices_tick()
  DV.mouth_tick()
  self:move_tick()
  local lj = self.listen_job
  if lj then
    local wav = VO.listened(lj.job)
    if wav ~= nil then
      self.listen_job = nil
      if wav then self:play(wav, lj.key)
      else self.board.ed.panel:say("No audio for this line", nil, true) end
    end
  end
  if self.sound and not w3.sound.playing(self.sound) then self.sound, self.playing = nil, nil end
  local lv = self.loading_voices
  if lv then
    local t0 = os.clock()
    while lv.co and os.clock() - t0 < 0.008 do
      local ok, err = coroutine.resume(lv.co)
      if not ok then
        self.loading_voices = nil
        self.board.ed.panel:say("The game's voices could not be read: " .. tostring(err), nil, true)
        return
      end
      if coroutine.status(lv.co) == "dead" then lv.co = nil end
    end
    if not lv.co then
      self.loading_voices = nil
      self.voices = VO.open()
      if self.voice_open ~= nil then self:sync() end
    end
  end
end
function DV:load_voices()
  if self.loading_voices then return end
  local co
  if not VO.ready() then
    co = coroutine.create(function() VO.build(function() end, function() coroutine.yield() end) end)
  end
  self.loading_voices = {co = co}
end

-- the rows of the list: the game's lines for the words (and the speaker), or the packs' recordings
function DV:voice_rows(x, source, text)
  local out = {}
  if source == "game" then
    if self.voices == nil then
      self:load_voices()
      return {note = "Reading the game's voices..."}
    end
    local who = P.get(x, "who")
    local player = D.is_player(who)
    local found = self.voices:search(text, player and self:player_voicetag() or nil, not player, player and 60 or 400)
    if not player then                           -- (the voices that fit the person first: its template, its name)
      local template = self:template_of(who)
      local name = self:names()[who]
      found = VO.fit(found, (P.T(template) and P.str(template):match("([^\\/]*)$") or "") .. " " .. (name or ""))
      for k = #found, 61, -1 do found[k] = nil end
    end
    for _, r in ipairs(found) do
      local dur = (r.dur ~= nil and r.dur ~= Y.null and r.dur ~= 0) and string.format("  -  %.1f s", r.dur) or ""
      out[#out + 1] = {key = "game:" .. math.tointeger(r.id), lines = {short(r.text), VO.speaker_label(r.speaker) .. dur},
                       play = function() self:play_game(math.tointeger(r.id)) end,
                       take = function() self:set_voice(x, r) end, tip = "dlg.game_take"}
    end
    if #out == 0 then out.note = "No voice lines for these words" end
  else
    self.custom_find = text
    local tags = {}
    for t in pairs(self.custom_tags or {}) do tags[#tags + 1] = t end
    table.sort(tags)
    for _, r in ipairs(CP.search_voices(text, tags)) do
      local line2 = string.format("%s  -  %s  -  %.1f s  -  %s", P.T(r.speaker) and r.speaker or "-", r.pack_name, r.dur,
                                  table.concat(r.tags, ", "))
      out[#out + 1] = {key = r.file, lines = {short(r.text), line2}, play = function() self:play(r.file) end,
                       take = function() self:set_custom(x, r) end, tip = "dlg.custom_take"}
    end
    if #out == 0 then out.note = #CP.packs() > 0 and "No recordings for these words or tags" or "No content packs loaded" end
  end
  return out
end

-- the list under the field (a QScrollArea: no frame, no horizontal bar, its rows as wide as the widest - cut at the
-- right): a play button and the entry (two lines: QPushButton#entry, 3px 6px, 12 px #ddd on #1d1d20), 2 apart
local ROW_H = 2 * 16 + 6
function DV:voice_list(id, rows, area_h)
  local lh = Q.line_h(12)
  local function row_w(r) return 23 + 4 + math.max(Q.hint_w(r.lines[1], 12), Q.hint_w(r.lines[2], 12)) + 12 end
  local content_h, content_w = 0, 0
  for k, r in ipairs(rows) do
    content_h = content_h + 2 * lh + 6 + (k > 1 and 2 or 0)
    content_w = math.max(content_w, row_w(r))
  end
  if rows.note then
    content_h = content_h + (#rows > 0 and 2 or 0) + Q.line_h(11)
    content_w = math.max(content_w, Q.hint_w(rows.note, 11))
  end
  return W.leaf{w = math.min(content_w, 36 * lh), h = area_h, min_w = 54, hpol = "expanding", vpol = "fixed",
                draw = function(_, r)
    local IV = require("conjunction.ui.itemview")
    local SBAR = require("conjunction.ui.scrollbar")
    local st = CT.state(id)
    local bar = content_h > r.h
    local vw = bar and r.w - 10 or r.w
    st.sb = st.sb or IV.bar(1, 0, 0)
    st.sb.page = r.h
    IV.range(st.sb, math.max(0, content_h - r.h))
    local _, _, wheel = w3.ui.mouse()
    if wheel ~= 0 and CT.over({x = r.x, y = r.y, w = r.w, h = r.h}) then
      local before = st.sb.value
      IV.set(st.sb, st.sb.value - math.floor(wheel * 3 * 20 + 0.5))
      if st.sb.value ~= before then self.wheel_taken = true end
    end
    local iw = math.max(vw, content_w)
    local y = r.y - st.sb.value
    local under = B.bg
    Dr.clip(r.x, r.y, vw, r.h, function()
      for k, row in ipairs(rows) do
        if y + ROW_H > r.y and y < r.y + r.h then
          local pr = {x = r.x, y = y + (ROW_H - 23) // 2, w = 23, h = 23}
          local clicked, hovered = self:hit(id .. ".play." .. k, pr)
          if hovered then Dr.fill(pr.x, pr.y, pr.w, pr.h, 0xffffff14) end
          Q.draw_icon(self.playing == row.key and "square" or "play", hovered and 0xffffffff or 0xcfcfcfff, 16,
                      pr.x + (23 - 16) // 2, pr.y + (23 - 16) // 2)
          if hovered then CT.tip(id .. ".play." .. k, "dlg.play") end
          if clicked then row.play() end
          local er = {x = r.x + 27, y = y, w = iw - 27, h = ROW_H}
          local c2, h2 = self:hit(id .. ".take." .. k, er)
          local bg = h2 and DV.ENTRY_HOT or DV.ENTRY_BG
          Dr.fill(er.x, er.y, er.w, er.h, bg)
          Q.text(er.x + 6, er.y + 3, DV.ENTRY_FG, row.lines[1], 12, false, bg)
          Q.text(er.x + 6, er.y + 3 + lh, DV.ENTRY_FG, row.lines[2], 12, false, bg)
          if h2 then CT.tip(id .. ".take." .. k, row.tip) end
          if c2 then row.take() end
        end
        y = y + ROW_H + 2
      end
      if rows.note then Q.text(r.x, y, C.note, rows.note, 11, false, under) end
    end)
    if bar then
      st.bar_state = st.bar_state or {}
      SBAR.draw(st.bar_state, id .. ".bar", st.sb, {x = r.x + vw, y = r.y, w = 10, h = r.h}, "v",
                function(i2, rr) return CT.hit_box(i2, rr) end)
    end
  end}
end

-- the content packs' tags: left click - only this one (again: none), right click - add it or take it out
function DV:tag_chip(tag, n)
  local text = tag .. "  " .. n
  local CV = require("conjunction.ui.catalog_view")
  local w, h = CV.chip_size(text)
  local id = "dlg.tag." .. tag
  return W.leaf{w = w, h = h, hpol = "minimum", vpol = "fixed", draw = function(_, r)
    local on = (self.custom_tags or {})[tag]
    local _, hovered = self:hit(id, r)
    local bg, edge, fg = hex("#262629"), hex("#444444"), hex("#cccccc")
    if on then bg, edge, fg = hex("#4b4b50"), hex("#c8c8c8"), 0xffffffff
    elseif hovered then edge = hex("#777777") end
    Dr.fill(r.x, r.y, r.w, r.h, edge)
    Dr.fill(r.x + 1, r.y + 1, r.w - 2, r.h - 2, bg)
    Q.text(r.x + (r.w - Q.text_w(text, 11)) // 2, r.y + Q.vcenter(r.h, Q.line_h(11)), fg, text, 11, false, bg)
    if hovered and w3.ui.mouse_clicked(1) then self.tag_click = {tag, false} end
    if hovered and w3.ui.mouse_clicked(2) then self.tag_click = {tag, true} end
  end}
end

-- the search under a line: Game / Custom, the words, the list (DialogueView._voice_search)
function DV:voice_search(x)
  local source = self.voice_source or "game"
  local gen = self.card_gen or 0
  local sid = idof(x)
  local style = self.board.panel.EDIT_STYLE
  local items = {}
  for _, kv in ipairs({{"game", "Game"}, {"custom", "Custom"}}) do
    items[#items + 1] = self:leaf_opt("dlg.voice_src." .. kv[1] .. "." .. sid, kv[2], source == kv[1], "dlg.voice_" .. kv[1],
                                      function() self:voice_from(kv[1]) end)
  end
  local fid = "dlg.voice_find." .. gen .. "." .. sid
  local fst = CT.state(fid)
  if fst.typed == nil then
    fst.typed = source == "game" and P.str(P.get(x, "text", "")) or (self.custom_find or "")
    fst.query = fst.typed
    CT.set_focus(fid)                            -- (typing goes to it: _type_into)
  end
  local find = W.leaf{w = 17 * Q.text_w("x") + 16, h = CT.edit_h(style), min_w = 42, hpol = "expanding", vpol = "fixed",
                      draw = function(_, r)
    local _, t = CT.edit(fid, r.x, r.y, r.w, fst.typed, {h = r.h, style = style,
      placeholder = source == "game" and "Words of the line" or "Words, speaker, tag",
      tip = source == "game" and "dlg.voice_find" or "dlg.custom_find"})
    if t ~= fst.typed then
      fst.typed = t
      fst.due = w3.time() + (source == "game" and 0.25 or 0.2)    -- (its timer: 250 / 200 ms after the last key)
    end
    if fst.due and w3.time() >= fst.due then
      fst.due = nil
      fst.query = fst.typed
    end
  end}
  find.stretch = 1
  items[#items + 1] = find
  items[#items + 1] = self:leaf_icon("dlg.voice_x." .. sid, "x", "qb.cancel", function() self:close_voice() end)
  local rows_v = {hbox(items)}
  -- (the rows for the query; anew when it changed)
  local key = gen .. "|" .. source .. "|" .. fst.query .. "|" .. tostring(self.voices ~= nil)
  if not self.voice_cache or self.voice_cache.key ~= key then
    self.voice_cache = {key = key, rows = self:voice_rows(x, source, fst.query)}
  end
  local rows = self.voice_cache.rows
  local area_h
  if source == "custom" then
    local chips = {}
    for k, t in ipairs(CP.voice_tags()) do
      if k > 40 then break end
      chips[#chips + 1] = self:tag_chip(t[1], t[2])
    end
    rows_v[#rows_v + 1] = W.widget(W.flow({spacing = 4}, chips))
    -- (its rows were there before the layout asked: the list's own height, at least 200, at most 24 lines)
    self.voice_area_h = self.voice_area_h or {}
    if not self.voice_area_h[gen] then
      local n, ch = #rows, 0
      for k = 1, n do ch = ch + ROW_H + (k > 1 and 2 or 0) end
      if rows.note then ch = ch + (n > 0 and 2 or 0) + Q.line_h(11) end
      self.voice_area_h = {[gen] = math.max(200, math.min(ch, 24 * Q.line_h(12)))}
    end
    area_h = self.voice_area_h[gen]
  else
    area_h = 220                                  -- (the rows come after the layout asked: the minimum)
  end
  rows_v[#rows_v + 1] = self:voice_list("dlg.voice_list." .. gen .. "." .. source, rows, area_h)
  if self.tag_click then
    local tc = self.tag_click
    self.tag_click = nil
    self:pick_tag(tc[1], tc[2])
  end
  return W.widget(W.vbox({margins = {6, 5, 6, 6}, spacing = 4}, rows_v), {
    margins = {1, 1, 1, 1},
    draw = function(_, r)
      Dr.fill(r.x, r.y, r.w, r.h, C.choice_bg)
      Dr.rect(r.x, r.y, r.w, r.h, C.choice_edge, 1)
      self.was_under4, self.under = self.under, C.choice_bg
      B.bg = C.choice_bg
    end,
    after = function() self.under = self.was_under4 end,
  })
end

-- --- a line's animation: one of the everyday gestures, none, or the search over all of the game's scene animations
function DV:gesture(x, k)
  if k == "__find" then
    self.anim_open, self.picked = x, x
    self:sync()
    return
  end
  Y.remove(x, "anim")
  self:set(x, "gesture", k)
end
function DV:take_anim(x, name)
  Y.remove(x, "gesture")
  x.anim = name
  self.anim_open = nil
  self:save()
end
function DV:close_anim()
  self.anim_open = nil
  self:sync()
end

-- words -> the game's scene animations with them in their name (and how long they are); a click takes one
-- (DialogueView._anim_search: a QListWidget - the theme's: #1d1d20, a #444 border, rows padding 3px 6px)
function DV:anim_search(x)
  local gen = self.card_gen or 0
  local sid = idof(x)
  local style = self.board.panel.EDIT_STYLE
  local fid = "dlg.anim_find." .. gen .. "." .. sid
  local fst = CT.state(fid)
  if fst.typed == nil then
    fst.typed = self.anim_find or ""
    CT.set_focus(fid)
  end
  local find = W.leaf{w = 17 * Q.text_w("x") + 16, h = CT.edit_h(style), min_w = 42, hpol = "expanding", vpol = "fixed",
                      draw = function(_, r)
    local _, t = CT.edit(fid, r.x, r.y, r.w, fst.typed, {h = r.h, style = style, placeholder = "Search animations",
                                                          tip = "dlg.anim_find"})
    fst.typed = t
  end}
  find.stretch = 1
  local have = self:body_of(P.str(P.or_(P.get(x, "who"), "npc")))   -- (only the speaker's own: another body's a T-pose)
  local text = fst.typed
  if not self.anim_cache or self.anim_cache.key ~= gen .. "|" .. text then
    self.anim_find = text
    local rows = {}
    for _, a in ipairs(D.find_animations(text, nil, have)) do
      rows[#rows + 1] = {a[1], string.format("%s   (%.1f s)", D.anim_label(a[1]), a[2])}
    end
    self.anim_cache = {key = gen .. "|" .. text, rows = rows}
  end
  local rows = self.anim_cache.rows
  local lid = "dlg.anim_list." .. gen .. "." .. sid
  local RH = Q.line_h(12) + DV.ANIM_ROW
  local list = W.leaf{w = 256, h = 200, min_w = 54, hpol = "expanding", vpol = "fixed", draw = function(_, r)
    local IV = require("conjunction.ui.itemview")
    local SBAR = require("conjunction.ui.scrollbar")
    local st = CT.state(lid)
    Dr.fill(r.x, r.y, r.w, r.h, hex("#444444"))
    Dr.fill(r.x + 1, r.y + 1, r.w - 2, r.h - 2, hex("#1d1d20"))
    local vx, vy, vh = r.x + 1, r.y + 1, r.h - 2
    -- (QListView scrolls per item: the bar counts the rows above, its end leaves the last rows that fit whole)
    local fit = vh // RH
    local bar = #rows * RH > vh
    local vw = r.w - 2 - (bar and 10 or 0)
    st.sb = st.sb or IV.bar(1, 0, 0)
    st.sb.page = fit
    IV.range(st.sb, math.max(0, #rows - fit))
    local _, _, wheel = w3.ui.mouse()
    if wheel ~= 0 and CT.over(r) then
      local before = st.sb.value
      IV.set(st.sb, st.sb.value - math.floor(wheel * 3 + 0.5))
      if st.sb.value ~= before then self.wheel_taken = true end
    end
    Dr.clip(vx, vy, vw, vh, function()
      for k, row in ipairs(rows) do
        local ry = vy + (k - 1 - st.sb.value) * RH
        if ry + RH > vy and ry < vy + vh then
          local rr = {x = vx, y = ry, w = vw, h = RH}
          local clicked, hovered = self:hit(lid .. "." .. k, rr)
          local bg = hovered and hex("#29292d") or hex("#1d1d20")
          if hovered then Dr.fill(rr.x, rr.y, rr.w, rr.h, bg) end
          Q.text(rr.x + DV.ANIM_TEXT_X, ry + (RH - Q.line_h(12)) // 2, hex("#dddddd"), row[2], 12, false, bg)
          if clicked then self:take_anim(x, row[1]) end
        end
      end
    end)
    if bar then
      st.bar_state = st.bar_state or {}
      SBAR.draw(st.bar_state, lid .. ".bar", st.sb, {x = vx + vw, y = vy, w = 10, h = vh}, "v",
                function(i2, rr) return CT.hit_box(i2, rr) end)
    end
  end}
  local rows_v = {hbox({find, self:leaf_icon("dlg.anim_x." .. sid, "x", "qb.cancel", function() self:close_anim() end)}),
                  list}
  return W.widget(W.vbox({margins = {6, 5, 6, 6}, spacing = 4}, rows_v), {
    margins = {1, 1, 1, 1},
    draw = function(_, r)
      Dr.fill(r.x, r.y, r.w, r.h, C.choice_bg)
      Dr.rect(r.x, r.y, r.w, r.h, C.choice_edge, 1)
      self.was_under5, self.under = self.under, C.choice_bg
      B.bg = C.choice_bg
    end,
    after = function() self.under = self.was_under5 end,
  })
end
DV.ANIM_ROW, DV.ANIM_TEXT_X = 20, 9               -- (a row: its line and 20 px; the text 9 in - Q.LIST_ROW)

-- --- how long a line's voice or mouth lasts (dialogue_view.lip_seconds): the voice's length, or radish times the
-- mouth from the text alone (w3speech-phoneme-extractor, a moment: nil until then); a thought has none
DV.MOUTH = {}                 -- text -> seconds (0: no radish here, false: being timed)
DV.MOUTH_JOBS = {}
DV.TIME_MOUTH = true          -- (the lab's pictures: off, as qt_ref's)
local MOUTH_ID = 2111000001   -- (an id of a scene line's size: a small one is not timed)

local function wordy(text)
  for _, c in ipairs(PYS.cps(text)) do if PYS.isalnum(utf8.char(c)) then return true end end
  return false
end

function DV.start_mouth(text)
  local ok, job = pcall(function()
    local radish = require("conjunction.config").load().radish
    local tmp = (os.getenv("TEMP") or "C:\\tmp") .. "\\conjunction_mouth_" .. require("conjunction.marks").uuid4_hex():sub(1, 8)
    w3.fs.mkdir(tmp)
    w3.fs.write(tmp .. "\\lines.csv", ";meta[language=en]\n; id      |key(hex)|key(str)| text\n" .. MOUTH_ID ..
                "|00000000||" .. text .. "\n")
    local cmd = string.format('"%s\\w3speech-phoneme-extractor.exe" --strings-file "%s\\lines.csv" ' ..
                              '--generate-from-text-only --output-dir "%s"', radish, tmp, tmp)
    local proc = assert(w3.proc.run(cmd, {cwd = radish}))
    return {text = text, tmp = tmp, proc = proc, lines = {}}
  end)
  if ok then DV.MOUTH_JOBS[#DV.MOUTH_JOBS + 1] = job else DV.MOUTH[text] = 0.0 end
end

-- each frame: the timings that are done (the seconds of the last phoneme and a little more)
function DV.mouth_tick()
  for k = #DV.MOUTH_JOBS, 1, -1 do
    local job = DV.MOUTH_JOBS[k]
    for _, ln in ipairs(w3.proc.lines(job.proc) or {}) do job.lines[#job.lines + 1] = ln end
    local code = w3.proc.exit(job.proc)
    if code ~= nil then
      table.remove(DV.MOUTH_JOBS, k)
      for _, ln in ipairs(w3.proc.lines(job.proc) or {}) do job.lines[#job.lines + 1] = ln end
      w3.proc.close(job.proc)
      local failed = code ~= 0
      for _, ln in ipairs(job.lines) do
        if PYS.strip(ln) ~= "" and (ln:sub(1, 5) == "ERROR" or ln:find("Failed to add seed file", 1, true)) then
          failed = true
        end
      end
      local secs = 0.0
      if not failed then
        local f = io.open(job.tmp .. "\\" .. MOUTH_ID .. ".phonemes", "rb")
        if f then
          local stop = 0
          for line in f:lines() do
            local parts = {}
            for p in (line .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = PYS.strip(p) end
            if #parts > 2 and parts[2]:match("^%d+$") and parts[3]:match("^%d+$") then
              stop = math.max(stop, tonumber(parts[3]))
            end
          end
          f:close()
          secs = require("conjunction.pynum").round(math.max(1.2, stop / 1000.0 + 0.45), 3)
        else
          secs = 2.0
        end
      end
      DV.MOUTH[job.text] = secs
      for _, e in ipairs(w3.fs.list(job.tmp) or {}) do w3.fs.remove(job.tmp .. "\\" .. e.name) end
      w3.fs.rmdir(job.tmp)
    end
  end
end

function DV.lip_seconds(x)
  if P.T(P.get(x, "voice")) or P.T(P.get(x, "voice_pack")) then
    local d = tonumber(P.get(x, "dur") or 0) or 0
    return d ~= 0 and d + 0.0 or nil
  end
  local text = table.concat(PYS.split(P.str(P.get(x, "text", ""))), " ")
  if text == "" or P.T(P.get(x, "thought")) then return nil end
  if DV.MOUTH[text] == nil then
    DV.MOUTH[text] = false
    if not wordy(text) then return nil end         -- ("..." - a gesture alone: no phonemes to time)
    if DV.TIME_MOUTH then DV.start_mouth(text) end
  end
  return DV.MOUTH[text] or nil
end

-- the line's camera move played with the editor camera: from its first camera to its second, eased in and out as the
-- scene does, as long as the line lasts (about) - 30 steps a second, as the app sends them
function DV:preview_move(x, seconds)
  local cams = P.or_(P.get(self:step(), "cams"), Y.map())
  local a, b = P.get(cams, P.str(P.get(x, "glide")):sub(5)), P.get(cams, P.str(P.get(x, "camera")):sub(5))
  if not a or not b then return end
  seconds = seconds or math.max(2.0, (tonumber(P.get(x, "dur") or 0) or 0) ~= 0 and tonumber(x.dur) or
                                     PYS.len(P.str(P.get(x, "text", ""))) * 0.08)
  self.cam_move = {a = a, b = b, t0 = w3.time(), seconds = seconds, next = 0}
end
function DV:move_tick()
  local m = self.cam_move
  if not m then return end
  local now = w3.time()
  if now < m.next then return end
  m.next = now + 0.033
  local t = math.min(1.0, (now - m.t0) / m.seconds)
  local e = t * t * (3 - 2 * t)                 -- smooth: slow at both ends
  local a, b = m.a, m.b
  local p = {}
  for k = 1, 3 do p[k] = a.pos[k] + (b.pos[k] - a.pos[k]) * e end
  local dy = ((b.yaw - a.yaw + 180) % 360) - 180  -- the short way round
  local yaw = (a.yaw + dy * e) % 360
  local pitch = a.pitch + (b.pitch - a.pitch) * e
  self.board.ed:exec(string.format("cj_cam_set(%.3f, %.3f, %.3f, %.2f, %.2f)", p[1], p[2], p[3], yaw, pitch))
  if t >= 1.0 then self.cam_move = nil end
end

return DV
