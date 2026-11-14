-- The windows that pick from the game's own quests and scenes (item_chooser.SceneChooser, PointChooser,
-- MomentChooser): + game scene (a scene to replace), Inside a game quest (a point of one to put the quest after), After
-- a moment of a game quest / + game moment (a fact a game quest sets). Each: a search over the game's list on the
-- left, what the one clicked is made of on the right, a button that takes it.
--   GC.scenes(panel, win, then_)   GC.points(panel, win, then_)   GC.moments(panel, win, then_)   -> a window body
local CT = require("conjunction.ui.controls")
local D = w3.ui.draw
local IV = require("conjunction.ui.itemview")
local P = require("conjunction.py")
local Q = require("conjunction.ui.qt")
local S = require("conjunction.pystr")
local SBAR = require("conjunction.ui.scrollbar")
local T = require("conjunction.ui.theme")
local TL = require("conjunction.ui.textlayout")
local GC = {}

local function hex(s) return (tonumber(s:sub(2), 16) << 8) | 255 end
local C = {title = hex("#eeeeee"), about = hex("#bbbbbb"), field = hex("#9a9a9a"), note = hex("#e3c65f"),
           list = hex("#dddddd")}

local function depot()
  return require("conjunction.depot").open(require("conjunction.config").load().game)
end

-- the words of a search (str.lower().split())
-- str.title(): a letter after one starts upper, the rest of the word lower
local function title(text)
  local out, prev = {}, false
  for _, cp in utf8.codes(text) do
    local ch = utf8.char(cp)
    local cased = S.lower(ch) ~= S.upper(ch)
    out[#out + 1] = cased and (prev and S.lower(ch) or S.upper(ch)) or ch
    prev = cased
  end
  return table.concat(out)
end

local function words_of(text)
  local out = {}
  for w in S.lower(text):gmatch("%S+") do out[#out + 1] = w end
  return out
end
local function has_all(hay, words)
  for _, w in ipairs(words) do if not hay:find(w, 1, true) then return false end end
  return true
end

-- --- the pieces
-- the search field (the panel's; setClearButtonEnabled: Qt's picture of the button while there is text)
local function search(body, r, placeholder, tip)
  local PN = require("conjunction.ui.panel")
  local PARTS = require("conjunction.parts.parts")
  local id = "panel.win." .. body.win.key .. "." .. body.search_key
  local _, text = CT.edit(id, r.x, r.y, r.w, body[body.search_key], {placeholder = placeholder, style = PN.EDIT_STYLE,
                                                                     tip = tip})
  if text ~= body[body.search_key] then return text end
  if text ~= "" then
    local cb = PARTS.lineedit_clear
    local br = {x = r.x + r.w - cb[1], y = r.y + cb[2], w = cb[3], h = cb[4]}
    Q.draw_part("lineedit_clear", br.x, br.y)
    local clicked, hovered = body:hit(id .. ".clear", br)
    if hovered and w3.ui.mouse_clicked(1) then CT.text_press = true end
    if clicked then
      CT.state(id).text = ""
      return ""
    end
  end
  return nil
end

-- a QListWidget of the theme: rows {text, tip}; st {bar, hbar, cur, press}; a row is made current on the press,
-- a double click takes it -> "current", i | "double", i
local function list_view(body, id, r, rows, st)
  Q.view_frame(r.x, r.y, r.w, r.h)
  local RH = Q.line_h(12) + Q.LIST_ROW          -- (the theme's list: 12 px #dddddd - no app page's 13 px here)
  local vx, vy, vw, vh = r.x + 1, r.y + 1, r.w - 2, r.h - 2
  local n = #rows
  st.bar = st.bar or IV.bar(1, 0, 0)
  st.hbar = st.hbar or IV.bar(20, 0, 0)
  -- (the widest row: its text and 24 - the item's padding and margins, measured; wider than the view: a bar under
  -- it, per pixel)
  local wide = 0
  for _, row in ipairs(rows) do wide = math.max(wide, Q.text_w(row[1], 12) + 24) end
  local vbar, hbar = false, false
  for _ = 1, 2 do
    vbar = n * RH > vh - (hbar and 10 or 0)
    hbar = wide > vw - (vbar and 10 or 0)
  end
  local lw, lh = vw - (vbar and 10 or 0), vh - (hbar and 10 or 0)
  local page = lh // RH
  local b = st.bar
  b.single, b.page = 1, page
  IV.range(b, math.max(0, n - page))
  local hb = st.hbar
  hb.page = lw
  IV.range(hb, math.max(0, wide - lw))
  local _, over = body:hit(id, {x = vx, y = vy, w = lw, h = lh})
  local mx, my, wheel = w3.ui.mouse()
  if over and wheel ~= 0 then IV.wheel(b, wheel >= 0 and math.min(wheel, 1) or math.max(wheel, -1), 3) end
  local hover = over and (b.value + (my - vy) // RH + 1) or nil
  if hover and hover > n then hover = nil end
  local event, at
  if over and hover and w3.ui.mouse_clicked(1) then
    if w3.ui.mouse_double(1) and st.press == hover then event, at = "double", hover
    else
      st.press = hover
      if st.cur ~= hover then event, at = "current", hover end
      st.cur = hover
    end
  end
  D.clip(vx, vy, lw, lh, function()
    for i = b.value + 1, math.min(n, b.value + page + 1) do
      local y = vy + (i - 1 - b.value) * RH
      local chosen = st.cur == i
      local bg = chosen and T.CHOSEN or (hover == i and T.HOVER or T.SURFACE)
      if bg ~= T.SURFACE then D.fill(vx, y, lw, RH, bg) end
      Q.text(vx - hb.value + 9, y + (RH - Q.line_h(12)) // 2, chosen and T.WHITE or C.list, rows[i][1], 12, false, bg)
    end
  end)
  if hover and rows[hover][2] then CT.tip(id .. ".row", {"", rows[hover][2]}) end
  if vbar then
    SBAR.draw(st, id .. ".vbar", b, {x = vx + lw, y = vy, w = 10, h = lh}, "v", function(i2, rr) return body:hit(i2, rr) end)
  end
  if hbar then
    st.hstate = st.hstate or {}
    SBAR.draw(st.hstate, id .. ".hbar", hb, {x = vx, y = vy + lh, w = lw, h = 10}, "h",
              function(i2, rr) return body:hit(i2, rr) end)
  end
  return event, at
end

-- a QLabel with word wrap (its text's lines - "\n" breaks too - at the width it gets) -> its height
local function wrapped(x, y, w, text, px, bold, colour, draw)
  local lh = Q.line_h(px, bold)
  local k = 0
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local lines = TL.wrap(para, px, bold, w, "word")
    if #lines == 0 then lines = {{s = ""}} end
    for _, l in ipairs(lines) do
      if draw ~= false then Q.text(x, y + k * lh, colour, l.s, px, bold) end
      k = k + 1
    end
  end
  return k * lh
end

-- the theme's QPushButton (the take button: off until there is something to take)
local function take_button(body, id, r, text, enabled, tip)
  local clicked, hv, held = body:hit(id, r)
  Q.button(r.x, r.y, r.w, r.h, text, {hover = hv or held, pressed = held and hv, fg = T.BUTTON_TEXT,
                                      disabled = not enabled})
  if hv and tip then CT.tip("panel.win." .. id, tip) end
  return clicked and enabled
end

local function new_body(kind, panel, win, then_)
  local self = setmetatable({kind = kind, panel = panel, win = win, then_ = then_, ed = panel.ed,
                             text = "", find = "", search_key = "text", lst = {}, lines_st = {}}, kind)
  self.lay = {frame = win.rect}
  CT.set_focus("panel.win." .. win.key .. ".text")
  return self
end

-- --- + game scene: the game's scenes a quest can start (searched by quest, name, who is in it), what the one
-- clicked is made of; Replace this scene takes it (its talks as the game's own, scene_import.load_into)
local SCENES = {}
SCENES.__index = SCENES
function GC.scenes(panel, win, then_)
  local self = new_body(SCENES, panel, win, then_)
  local SS = require("conjunction.scene_swap")
  local dp = depot()
  local info = SS.scene_info(dp)
  self.index = {}
  for _, p in ipairs(SS.scene_index(dp)) do
    local i = info[p]
    if i and P.T(i[2]) then self.index[#self.index + 1] = {p, SS.label(p), i[1]} end
  end
  self:fill("")
  return self
end
function SCENES:hit(id, r) return self.win:hit(id, r) end
function SCENES:fill(text)
  local words = words_of(P.replace(text, "_", " "))
  self.rows = {}
  for _, e in ipairs(self.index) do
    local hay = S.lower(e[2] .. " " .. P.replace(e[1], "_", " ") .. " " .. e[3])
    if has_all(hay, words) then
      self.rows[#self.rows + 1] = {e[2], e[1], path = e[1]}
      if #self.rows >= 500 then break end            -- enough to choose from; more words narrow it
    end
  end
  self.lst.cur, self.lst.press = nil, nil
  if self.lst.bar then IV.set(self.lst.bar, 0) end
end
function SCENES:show(path)
  local SS = require("conjunction.scene_swap")
  self.path = path
  local ok, o = pcall(SS.outline, depot(), path)
  if not ok then                               -- (as the app's slot: an error, the right side as it was)
    print("[game scene] " .. tostring(o))
    return
  end
  self.outline = o
  local people = {}
  for _, a in ipairs(o.actors) do
    if a.voicetag ~= "GERALT" then people[#people + 1] = title(a.voicetag) end
  end
  local parts = {#people > 0 and ("with " .. table.concat(people, ", ")) or "only the player",
                 P.str(o.lines) .. " lines" .. ((#o.inputs > 1 or #o.outputs > 1) and
                   (", " .. #o.inputs .. " entries, " .. #o.outputs .. " exits") or "")}
  if P.T(o.cutscenes) or P.T(o.videos) then parts[#parts + 1] = "has a cutscene or a film, replaced as a whole" end
  if #o.inputs == 0 then parts = {"No quest starts this scene - it cannot be replaced."} end
  self.title = SS.label(path)
  self.about = table.concat(parts, "\n")
  self.can_take = #o.inputs > 0
end
function SCENES:take()
  if not self.path then return end
  local SI = require("conjunction.scene_import")
  local SS = require("conjunction.scene_swap")
  local dp = depot()
  local swap = SI.load_into(SS.new_swap(dp, self.path), dp)      -- the game's own words
  local then_ = self.then_
  self.win:close()
  then_(swap)
end
function SCENES:frame(r)
  -- the left (stretch): the search, the list - 8 apart; the right: a box 390 wide (margins 9, 6 apart): the title,
  -- what it is made of, Replace this scene
  local PN = require("conjunction.ui.panel")
  local eh = CT.edit_h(PN.EDIT_STYLE)
  local lw = r.w - 8 - 390
  local t = search(self, {x = r.x, y = r.y, w = lw, h = eh},
                   "Search the game's scenes (" .. #self.index .. "): quest, scene, who is in it", "gs.search")
  if t then
    self.text = t
    self:fill(t)
  end
  local ev, at = list_view(self, "list", {x = r.x, y = r.y + eh + 8, w = lw, h = r.h - eh - 8}, self.rows, self.lst)
  if ev == "current" then self:show(self.rows[at].path) end
  if ev == "double" then return self:take() end
  local bx, by, bw = r.x + lw + 8 + 9, r.y + 9, 390 - 18
  local bh = r.h - 18
  local y = by
  if self.title then y = y + wrapped(bx, y, bw, self.title, 14, true, C.title) end
  y = y + 6
  if self.about then wrapped(bx, y, bw, self.about, 12, false, C.about) end
  local th = Q.line_h() + 12
  if take_button(self, "take", {x = bx, y = by + bh - th, w = bw, h = th}, "Replace this scene", self.can_take, "gs.take") then
    self:take()
  end
end

-- --- After a moment of a game quest: the game's quests (by name, then those with a moment of the words), the
-- moments of the one clicked in the order its graph sets them; Choose takes one
local MOMENTS = {}
MOMENTS.__index = MOMENTS
function GC.moments(panel, win, then_)
  local self = new_body(MOMENTS, panel, win, then_)
  self.index = require("conjunction.game_quests").index()
  self.fst = {}
  self:fill("")
  return self
end
function MOMENTS:hit(id, r) return self.win:hit(id, r) end
function MOMENTS:fill(text)
  local words = words_of(text)
  local found = {}
  for k, q in ipairs(self.index) do
    local name = S.lower(q.name .. " " .. q.path)
    if has_all(name, words) then
      found[#found + 1] = {0, q.name, k}                 -- by its name first
    elseif #words > 0 and has_all(name .. " " .. S.lower(table.concat(q.facts, " ")), words) then
      found[#found + 1] = {1, q.name, k}                 -- then those with a moment of that name
    end
  end
  local PS = require("conjunction.pysort")
  found = PS.sorted(found)
  self.rows = {}
  for _, f in ipairs(found) do
    local q = self.index[f[3]]
    self.rows[#self.rows + 1] = {q.name .. "   (" .. #q.facts .. ")", q.path, k = f[3]}
  end
  self.lst.cur, self.lst.press = nil, nil
  if self.lst.bar then IV.set(self.lst.bar, 0) end
end
function MOMENTS:show(k)
  self.quest = self.index[k]
  local words = words_of(self.text)
  self.facts = {}
  self.fst = {}
  for _, fact in ipairs(self.quest.facts) do
    self.facts[#self.facts + 1] = {P.replace(fact, "_", " "), nil, fact = fact}
    if #words > 0 and has_all(S.lower(fact), words) then self.fst.cur = #self.facts end
  end
end
function MOMENTS:take()
  local cur = self.fst.cur
  if not (self.quest and cur) then return end
  local Y = require("conjunction.yaml")
  local then_ = self.then_
  self.win:close()
  then_(Y.map({"quest", self.quest.path, "name", self.quest.name, "fact", self.facts[cur].fact}))
end
function MOMENTS:frame(r)
  local PN = require("conjunction.ui.panel")
  local eh = CT.edit_h(PN.EDIT_STYLE)
  local lw = r.w - 8 - 390
  local t = search(self, {x = r.x, y = r.y, w = lw, h = eh}, "Search the game's quests (" .. #self.index .. ") or a fact",
                   "gq.search")
  if t then
    self.text = t
    self:fill(t)
  end
  local ev, at = list_view(self, "list", {x = r.x, y = r.y + eh + 8, w = lw, h = r.h - eh - 8}, self.rows, self.lst)
  if ev == "current" then self:show(self.rows[at].k) end
  -- the right: the title, "The quest starts when ...", the moments (stretch), Choose - margins 9, 6 apart
  local bx, by, bw = r.x + lw + 8 + 9, r.y + 9, 390 - 18
  local bh = r.h - 18
  local y = by + Q.line_h(14, true) + 6
  if self.quest then Q.text(bx, by, C.title, self.quest.name, 14, true) end
  Q.text(bx, y, C.field, "The quest starts when the game's quest reaches:", 11)
  y = y + Q.line_h(11) + 6
  local th = Q.line_h() + 12
  local ly = by + bh - th - 6
  local fev = list_view(self, "facts", {x = bx, y = y, w = bw, h = ly - y}, self.facts or {}, self.fst)
  if fev == "double" then return self:take() end
  if take_button(self, "take", {x = bx, y = by + bh - th, w = bw, h = th}, "Choose", true, "gq.take") then self:take() end
end

-- --- Inside a game quest: the game's quest files on the left (330 wide, margins 9), the points of the one clicked
-- on the right (each block of its graphs with a way on, searched by words); Put my quest here takes one
local POINTS = {}
POINTS.__index = POINTS
function GC.points(panel, win, then_)
  local self = new_body(POINTS, panel, win, then_)
  local SS = require("conjunction.scene_swap")
  self.index = {}
  for _, p in ipairs(require("conjunction.game_quests").phase_index()) do
    self.index[#self.index + 1] = {path = p, name = SS.label(p)}
  end
  self.points = {}
  self:fill("")
  return self
end
function POINTS:hit(id, r) return self.win:hit(id, r) end
function POINTS:fill(text)
  local words = words_of(text)
  self.rows = {}
  for k, q in ipairs(self.index) do
    if has_all(S.lower(q.name .. " " .. q.path), words) then self.rows[#self.rows + 1] = {q.name, q.path, k = k} end
  end
  self.lst.cur, self.lst.press = nil, nil
  if self.lst.bar then IV.set(self.lst.bar, 0) end
end
function POINTS:show(k)
  local CR = require("conjunction.cr2w")
  local CE = require("conjunction.cr2w_edit")
  local QR = require("conjunction.questread")
  local SS = require("conjunction.scene_swap")
  self.quest = self.index[k]
  local dp = depot()
  self.points = {}
  local ok, err = pcall(function() self:read_points(dp, CR, CE, QR, SS) end)
  if not ok then                               -- (as the app's slot: an error, the points' list as it was)
    print("[game quest point] " .. tostring(err))
    return
  end
  self:fill_points(self.find)
end
function POINTS:read_points(dp, CR, CE, QR, SS)
  local f = CR.parse(dp:read(self.quest.path))
  local people = SS.scene_people(dp)
  for gi, e in ipairs(f.exports) do
    if e[1] == "CQuestGraph" then
      local g = QR.Graph(f, gi)
      for _, i in ipairs(g.order) do
        for _, c in ipairs(CE.links(f, i)) do
          local socket, targets = c[1], c[2]
          if #targets > 0 then
            local way = (socket ~= nil and socket ~= "Out" and socket ~= " ") and ("  -> " .. P.str(socket)) or ""
            local who = ""
            local scene = g.blocks[i][2].scene
            if QR.is_ref(scene, "import") and P.T(people[S.lower(scene[2])]) then
              who = "  (with " .. people[S.lower(scene[2])] .. ")"     -- a talk: who is in it
            end
            self.points[#self.points + 1] = {i, socket, "#" .. i .. " " .. g:describe(i) .. who .. way}
          end
        end
      end
    end
  end
end
function POINTS:fill_points(text)
  local words = words_of(text)
  self.lines = {}
  for _, pt in ipairs(self.points) do
    if has_all(S.lower(pt[3]), words) then
      local cps = S.cps(pt[3])
      self.lines[#self.lines + 1] = {S.from_cps(cps, 1, math.min(160, #cps)), pt[3], point = pt}
    end
  end
  self.lines_st.cur, self.lines_st.press = nil, nil
  if self.lines_st.bar then IV.set(self.lines_st.bar, 0) end
end
function POINTS:take()
  local cur = self.lines_st.cur
  if not (self.quest and cur) then return end
  local Y = require("conjunction.yaml")
  local pt = self.lines[cur].point
  local then_ = self.then_
  self.win:close()
  then_(Y.map({"phase", self.quest.path, "name", self.quest.name, "block", pt[1], "socket", pt[2] == nil and Y.null or pt[2],
               "label", pt[3]}))
end
function POINTS:frame(r)
  local PN = require("conjunction.ui.panel")
  local eh = CT.edit_h(PN.EDIT_STYLE)
  -- the left: a box 330 wide, margins 9 - the search, the quests (6 apart); the right (stretch, 8 apart): the title,
  -- the caution, the words of a point, the points (stretch), Put my quest here
  local lx, ly, lw = r.x + 9, r.y + 9, 330 - 18
  local t = search(self, {x = lx, y = ly, w = lw, h = eh}, "Search the game's quests (" .. #self.index .. ")", "gp.search")
  if t then
    self.text = t
    self:fill(t)
  end
  local ev, at = list_view(self, "list", {x = lx, y = ly + eh + 6, w = lw, h = r.h - 18 - eh - 6}, self.rows, self.lst)
  if ev == "current" then self:show(self.rows[at].k) end
  local rx, rw = r.x + 330 + 8, r.w - 330 - 8
  local y = r.y
  if self.quest then Q.text(rx, y, C.title, self.quest.name, 14, true) end
  y = y + Q.line_h(14, true) + 8
  local note = "(Caution: saves inside this game quest may break)"
  local nh = wrapped(rx, y, rw, note, 12, false, C.note, false)
  local _, nov = self:hit("note", {x = rx, y = y, w = rw, h = nh})
  wrapped(rx, y, rw, note, 12, false, C.note)
  if nov then CT.tip("panel.win.gp.saves", "gp.saves") end
  y = y + nh + 8
  self.search_key = "find"
  local ft = search(self, {x = rx, y = y, w = rw, h = eh}, "Words of a point (scene, fact, name)", "gp.find")
  self.search_key = "text"
  if ft then
    self.find = ft
    self:fill_points(ft)
  end
  y = y + eh + 8
  local th = Q.line_h() + 12
  local bottom = r.y + r.h - th
  local pev = list_view(self, "lines", {x = rx, y = y, w = rw, h = bottom - 8 - y}, self.lines or {}, self.lines_st)
  if pev == "double" then return self:take() end
  if take_button(self, "take", {x = rx, y = bottom, w = rw, h = th}, "Put my quest here", true, "gp.take") then self:take() end
end

-- the pieces, for other windows of the kind (the scene workshop)
GC.parts = {search = search, list_view = list_view, wrapped = wrapped, take_button = take_button, title = title,
            words_of = words_of, has_all = has_all}

return GC
