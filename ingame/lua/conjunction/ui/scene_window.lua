-- The scene workshop (View > Scene workshop): one of the game's scenes changed in place and played at once in the
-- running game (scene_work.lua). Left: the scenes, those the game is at now (Here now) or all of them (All scenes);
-- the middle: the scene picked, as it plays (inputs, sections with their lines, answers, ifs, outputs); the right:
-- the card of the row picked. Above them the world state: the facts the scene asks, set for it in the running game.
--   local sw = SCW.new(ed, win)   sw:frame(r)   sw:open(path)
local CT = require("conjunction.ui.controls")
local GC = require("conjunction.ui.game_choosers")
local Q = require("conjunction.ui.qt")
local T = require("conjunction.ui.theme")
local SF = require("conjunction.scene_file")
local ST = require("conjunction.scene_texts")
local SW = require("conjunction.scene_work")
local TLV = require("conjunction.ui.timeline_view")
local CUT = require("conjunction.ui.cut_view")
require("conjunction.scene_timeline")
local D = w3.ui.draw
local G = GC.parts
local SCW = {}
SCW.__index = SCW

SCW.LEFT, SCW.CARD = 330, 380
SCW.TIP_EMPTY = "Pick a scene on the left. Here now lists the scenes of the quests the game is at and those of " ..
                "the people near you; All scenes searches every scene of the game."
SCW.TIP_POOL = "Texts of your own need Conjunction's text file in the game (dlc\\dlcconjunctiontexts). It was " ..
               "written now: restart the game once, then texts of your own show in scenes."

local function depot() return require("conjunction.depot").open(require("conjunction.config").load().game) end
-- the director's events by what they do (the rest by their class, short)
SCW.EVENT_NAMES = {CStorySceneEventCustomCameraInstance = "Camera", CStorySceneEventCustomCamera = "Camera (own)",
                   CStorySceneEventCameraAnim = "Camera move", CStorySceneEventLookAt = "Look at",
                   CStorySceneEventMimicsAnim = "Face", CStorySceneEventMimics = "Mood",
                   CStorySceneEventAnimation = "Gesture", CStorySceneEventAdditiveAnimation = "Gesture (added)",
                   CStorySceneEventOverridePlacement = "Placement", CStorySceneEventChangePose = "Pose",
                   CStorySceneEventCameraLight = "Light", CStorySceneEventSound = "Sound", CStorySceneEventFade = "Fade",
                   CStorySceneAddFactEvent = "Fact", CStorySceneEventEquipItem = "Item"}
local function short_cls(c)
  return SCW.EVENT_NAMES[c] or (c:gsub("^CStoryScene", ""):gsub("^Event", ""))
end

function SCW.new(ed, win)
  local self = setmetatable({ed = ed, win = win, tab = "here", text = "", search_key = "text", lst = {}, flow_st = {},
                             here_st = {}, voice_st = {}, rows = {}, flow = {}, voice = "", voices = nil,
                             note = nil, facts_open = false, tlv = TLV.new(), playhead = 0.0}, SCW)
  local proj = ed and ed.project
  self.project_dir = proj and proj.path or nil
  -- a preview while editing: the world set as the game has it, and back after it (scene_stage.lua; self.partner: the
  -- built person a talk is with, quest_board.open_timeline)
  local STG = require("conjunction.scene_stage")
  SW.on_play = function() if self.ed then STG.stage(self.ed, self.partner) end end
  SW.on_over = function() if self.ed then STG.unstage(self.ed) end end
  -- (and the spot PLAYER, editing, where the preview will have Geralt: the ghost under the camera is not there)
  SW.player_spot = function()
    if not (self.ed and self.ed.editing) or STG.staged then return nil end
    local pos, yaw = STG.front_of(self.partner, self.ed)
    if not pos then return nil end
    return {pos.X, pos.Y, pos.Z}, yaw
  end
  local SS = require("conjunction.scene_swap")
  self.dp = depot()
  self.info = SS.scene_info(self.dp)
  self.index = SS.scene_index(self.dp)
  self.all = {}
  for _, p in ipairs(self.index) do
    local i = self.info[p]
    self.all[#self.all + 1] = {p, SS.label(p), i and i[1] or ""}
  end
  self.label = SS.label
  self:fill("")
  if require("conjunction.config").load().game then
    local okp, wrote = pcall(ST.ensure_pool, require("conjunction.config").load().game)
    if okp and wrote > 0 and not ST.pool_loaded() then self.note = SCW.TIP_POOL end
  end
  self:refresh_here()
  return self
end

function SCW:hit(id, r) return self.win:hit(id, r) end

-- --- the scenes on the left
function SCW:fill(text)
  local words = G.words_of((text:gsub("_", " ")))
  self.found = {}
  for _, e in ipairs(self.all) do
    local hay = (e[2] .. " " .. e[1]:gsub("_", " ") .. " " .. e[3]):lower()
    if G.has_all(hay, words) then
      self.found[#self.found + 1] = {e[2], e[1], path = e[1]}
      if #self.found >= 500 then break end
    end
  end
  self.lst.cur = nil
end

function SCW:refresh_here()
  local ok, list = pcall(SW.here, self.index, self.info)
  self.here = {}
  for _, h in ipairs(ok and list or {}) do
    self.here[#self.here + 1] = {self.label(h.path), h.path .. "  (" .. h.why .. ")", path = h.path}
  end
  self.here_st.cur = nil
end

-- --- the scene in the middle
function SCW:open(path, layer)
  if self.w then self.w:restore_facts() end
  self.actor_names = nil                        -- (a talk's names: set again by its timeline, quest_board)
  local ok, w = pcall(SW.open, path, {project_dir = self.project_dir, depot = self.dp, layer = layer})
  if not ok then
    self.err = tostring(w)
    self.w = nil
    return
  end
  self.err, self.w, self.pick = nil, w, nil
  w:apply_world()
  if w:changed() then w:keep() end              -- (the project's version into the game)
  self:build_rows()
end

-- the rows of the flow: {text, tip, kind, node, el, cl}
function SCW:build_rows()
  local w = self.w
  local s = w.s
  local fl = s:flow()
  self.flow = fl
  local rows = {}
  local function name_of(n)
    local node = fl.nodes[n]
    if not node then return n == 0 and "nowhere" or "?" end
    local nm = node.name ~= "" and node.name or ("#" .. n)
    return node.kind .. " " .. nm
  end
  local function add(text, kind, extra)
    local r = {text, nil, kind = kind}
    for k, v in pairs(extra or {}) do r[k] = v end
    rows[#rows + 1] = r
  end
  for _, n in ipairs(fl.order) do
    local node = fl.nodes[n]
    local k = node.kind
    if k == "input" then
      add("Input  " .. node.name, "input", {node = n})
    elseif k == "output" then
      add("Output  " .. node.name, "output", {node = n})
    elseif k == "if" then
      local o = s:obj(n)
      local fact, op, value = s:fact_check(o:get("questCondition", 0))
      local yes, no = node.links[1], node.links[2]
      add("If " .. (fact and (fact .. " " .. op .. " " .. value) or (node.name ~= "" and node.name or "(a condition)")) ..
          "   yes: " .. name_of(yes and yes.to or 0) .. ",  no: " .. name_of(no and no.to or 0), "if",
          {node = n, cond = o:get("questCondition", 0)})
    elseif k == "random" or k == "script" or k == "hub" or k == "switch" then
      local outs = {}
      for _, l in ipairs(node.links) do outs[#outs + 1] = name_of(l.to) end
      add(k:sub(1, 1):upper() .. k:sub(2) .. "  " .. node.name .. "   -> " .. table.concat(outs, ", "), k, {node = n})
    else                                            -- a section, a cutscene, a film
      local set = s:obj(n):get("dialogsetChangeTo")
      set = type(set) == "string" and set:sub(1, #SF.OWN_SET) == SF.OWN_SET and set or nil
      add((k == "section" and (set and "Section (your scene)  " or "Section  ") or (k:sub(1, 1):upper() .. k:sub(2) .. "  ")) ..
          node.name, k, {node = n, set = set})
      for _, e in ipairs(s:elements(n)) do
        if e.kind == "line" then
          local voiced = not ST.is_pool(e.text)
          add("      " .. (e.speaker ~= "" and e.speaker or "?") .. ":  " .. w:text_of(e.text) ..
              (voiced and "" or "   (own text)"), "line", {node = n, el = e.n})
        elseif e.kind == "pause" then
          add(string.format("      (pause %.1f s)", tonumber(e.duration) or 0), "pause", {node = n, el = e.n})
        elseif e.kind == "comment" then
          add("      // " .. w:text_of(e.text), "comment", {node = n, el = e.n})
        else
          add("      (" .. e.kind .. ")", e.kind, {node = n, el = e.n})
        end
      end
      local ch = s:choice(n)
      for _, c in ipairs(ch and ch.lines or {}) do
        add("      > " .. w:text_of(c.text) .. "   -> " .. name_of(c.to), "answer", {node = n, cl = c.n})
      end
      for _, l in ipairs(node.links) do
        if not l.choice and l.label == "" then add("      -> " .. name_of(l.to), "next", {node = n}) end
      end
    end
  end
  self.rows = rows
  if self.pick and self.pick > #rows then self.pick = nil end
end

-- after a change: the rows again, the same row picked where it can be
function SCW:after(ok, err)
  if ok == false then self.err = err end
  if ok ~= false and self.preview and self:live() and self.w then      -- (the preview shows the change: after a
    self.restart_at = (w3.time and w3.time() or 0) + 0.4                -- row of changes once - 02.11.: each of 35
  end                                                                    -- started the scene, the game queued them
  local keep = self.pick and self.rows[self.pick]
  self:build_rows()
  if keep then
    for i, r in ipairs(self.rows) do
      if r[1] == keep[1] then self.pick = i break end
    end
  end
end

function SCW:closed()
  self:peek_stop()
  for _, h in pairs(self.wpv or {}) do self:world_apply(h, nil, true) end
  self.wpv = nil
  CUT.leave(self)
  if self.w then self.w:restore_facts() end
  SW.clear_live()
end

-- --- drawing
local function label(x, y, text, colour, px, bold)
  Q.text(x, y, colour or T.TEXT, text, px or T.FONT, bold)
  return Q.line_h(px or T.FONT, bold)
end

function SCW:button(id, x, y, text, enabled, w)
  local bw, bh = Q.button_size(text)
  bw = w or bw
  local clicked, hv, held = self:hit(id, {x = x, y = y, w = bw, h = bh})
  Q.button(x, y, bw, bh, text, {hover = hv or held, pressed = held and hv, fg = T.BUTTON_TEXT,
                                disabled = enabled == false})
  return clicked and enabled ~= false, bw, bh
end

function SCW:frame(r)
  self:peek_tick()
  if self.view_key or self.hud_hidden then CUT.leave(self) end   -- (the cutscene editor was left)
  local lw = SCW.LEFT
  self:left({x = r.x, y = r.y, w = lw, h = r.h})
  local mx = r.x + lw + 8
  local m = {x = mx, y = r.y, w = r.w - lw - 8, h = r.h}
  if not self.w then
    D.fill(m.x, m.y, m.w, m.h, T.SURFACE)
    G.wrapped(m.x + 12, m.y + 12, m.w - 24, self.err or self.note or SCW.TIP_EMPTY, 13, false, T.DIM)
    return
  end
  local y = self:head(m)
  local fh = 0
  if self.facts_open then
    local n = #self.w:facts()
    local want = Q.line_h(11) + 12 + n * (CT.edit_h() + 4) + 6
    fh = self:facts_box({x = m.x, y = y, w = m.w, h = math.min(want, math.max(120, m.h // 3))}) + 8
  end
  y = y + fh
  local cw = SCW.CARD
  local tsec = self:timeline_section()
  local th = 0
  if tsec then
    local shown = TLV.shown(self.w.s:timeline(tsec), self.tl_all)
    local tracks = 0                            -- (their heights: the world track grows with its rows)
    for _, tr in ipairs(shown) do tracks = tracks + TLV.track_h(tr) + TLV.GAP end
    tracks = tracks + math.max(0, 2 - #shown) * (TLV.TRACK_H + TLV.GAP)
    th = math.min(math.floor((m.y + m.h - y) * 0.45),
                  select(2, Q.button_size("Play")) + 10 + TLV.RULER_H + TLV.GAP + tracks + 8)
  end
  local flow = {x = m.x, y = y, w = m.w - cw - 8, h = m.y + m.h - y - (th > 0 and th + 8 or 0)}
  local ev, at = G.list_view(self, "flow", flow, self.rows, self.flow_st)
  if ev == "current" or ev == "double" then self.pick = at end
  if ev == "double" and self.rows[at] then
    local row = self.rows[at]
    if row.kind == "input" then self:play(self.w.s:name_of(row.node)) elseif row.node then self:play(row.node) end
  end
  self.flow_st.cur = self.pick
  self:card({x = flow.x + flow.w + 8, y = y, w = cw, h = flow.h})
  if tsec then self:timeline({x = m.x, y = flow.y + flow.h + 8, w = m.w, h = th}, tsec) end
end

-- the section the timeline shows: the picked row's (a section, or a line, pause ... of it), nil for anything else
function SCW:timeline_section()
  if self.cut and self.w then return self:cut_section() end
  local row = self.w and self.pick and self.rows[self.pick]
  local o = row and row.node and self.w.s:obj(row.node)
  if not (o and o.cls == "CStorySceneSection" and o.events) then return nil end
  local name = self.w.s:name_of(row.node)
  if self.tl_sec ~= name then
    self.tl_sec, self.tl_pick, self.playhead = name, nil, 0.0
  end
  return row.node
end

-- the timeline of section sec: its buttons, the tracks (timeline_view.lua), what is done on them
function SCW:timeline(r, sec, o)
  o = o or {}
  local w = self.w
  local tl = w.s:timeline(sec)
  -- the lines on a track of their own, first: who says what when (07.11.: the timeline showed none of them)
  local lines = {id = "lines", kind = "lines", clips = {}}
  for k, e in ipairs(tl.elements or {}) do
    local ob = w.s:obj(e.n)
    if ob and ob.cls == "CStorySceneLine" then
      local dl = ob:get("dialogLine")
      local okt, txt = pcall(function() return w:text_of(dl and dl.n) end)
      lines.clips[#lines.clips + 1] = {id = "line:" .. k, kind = "lines", fixed = true, start = e.start,
                                       stop = e.start + e.len, dur = e.len, seams = {},
                                       label = tostring(ob:get("voicetag", "") or "") .. ": " .. tostring(okt and txt or "")}
    end
  end
  if #lines.clips > 0 then table.insert(tl.tracks, 1, lines) end
  local bh = select(2, Q.button_size("Play"))
  local x = r.x
  local function btn(id, text, enabled, run)
    local clicked, bw = self:button("tl." .. id, x, r.y, text, enabled)
    if clicked then run() end
    x = x + bw + 6
  end
  local pv = self:preview_of(sec)
  if not o.cut then
    btn("play", (pv and not pv.paused) and "Pause" or "Play", true, function() self:play_pause(sec) end)
  end
  if SW.is_own_cutscene(w.s, sec) and not o.cut then
    btn("edit", "Cutscene editor", true, function() self:open_cut(sec) end)
  end
  if SW.is_own_cutscene(w.s, sec) then
    if not o.cut then btn("view", "Take this view", w3.camera ~= nil, function() self:take_view(sec) end) end
    btn("split", "Split at playhead", true, function()
      local n, e
      local ok, err = w:edit(function(sc) n, e = sc:split_at(sec, self.playhead or 0) if not n then error(e, 0) end end)
      self:after(ok, err)
    end)
  end
  btn("all", self.tl_all and "Main tracks" or "All tracks", true, function() self.tl_all = not self.tl_all end)
  local c = self.tl_pick and tl.clips[self.tl_pick]
  btn("remove", "Remove", c ~= nil, function()
    self:after(w:edit(function(sc) sc:remove_clip(sec, c.id) end))
    self.tl_pick = nil
  end)
  label(x + 6, r.y + 6, string.format("%.1f s  -  playhead %.2f s  (drag the end to change the length)", tl.length,
                                      self.playhead or 0), T.DIM, 12)
  -- (playing: the playhead runs along until the scene ends)
  if pv and not pv.paused then
    local okt, tm = pcall(SW.scene_time)
    if okt and tm and tm.section == w.s:name_of(sec) then
      self.playhead = math.min(tm.t, tl.length)
    elseif w3.time and w3.time() - pv.t0 > 2 and not (okt and tm) then
      self.preview = nil
    end
  elseif self.playing and w3.time then
    local t = w3.time() - self.playing.t0
    if t > tl.length + 0.5 or (t > 2 and w3.scene and w3.scene.playing and not w3.scene.playing()) then
      self.playing = nil
    else
      self.playhead = math.min(t, tl.length)
    end
  end
  pcall(self.world_preview, self, tl, pv)
  local tr = {x = r.x, y = r.y + bh + 8, w = r.w, h = r.h - bh - 8}
  local act = self.tlv:frame(tr, tl, function(id, rr) return self:hit("tl." .. id, rr) end,
                             {pick = self.tl_pick, playhead = self.playhead, all = self.tl_all, people = o.people,
                              drag = o.drag, names = self.actor_names})
  if not act then return end
  local kind = act[1]
  if kind == "pick" then
    self.tl_pick = act[2]
  elseif kind == "seek" then
    self:seek(sec, act[2])
  elseif kind == "drop" then
    local d = o.drag
    self.lib_press, self.lib_drag = nil, nil
    if d then self:add_anim(sec, act[2], d.name, d.len, act[3]) end
  else
    local new
    local ok, err = w:edit(function(sc)
      if kind == "move" then new = sc:move_clip(sec, act[2], act[3])
      elseif kind == "resize" then
        local cl = tl.clips[act[2]]
        new = sc:resize_clip(sec, act[2], act[3], act[4], cl and cl.anim and SW.animation_length(w.depot, cl.anim))
      elseif kind == "length" then
        if not sc:set_length(sec, act[2]) then error("Only a section that ends in a pause can be made longer", 0) end
      end
    end)
    self:after(ok, err)
    if new then self.tl_pick = new end
  end
end

-- the clip picked on the timeline: its animation, start, length, speed, blends
function SCW:clip_card(c, sec, x, y, cw)
  local w = self.w
  local key = "panel.win." .. self.win.key .. ".clip." .. c.id
  local bh = select(2, Q.button_size("Play"))
  if c.actor then y = y + label(x, y, (self.actor_names and self.actor_names[c.actor]) or c.actor, T.DIM, 12) + 2 end
  y = y + label(x, y, c.label or "", T.BRIGHT, 14, true) + 8
  local function apply(fn)
    local new
    local ok, err = w:edit(function(sc) new = fn(sc) end)
    self:after(ok, err)
    if new then self.tl_pick = new end
  end
  local len = c.anim and SW.animation_length(w.depot, c.anim)
  local anim = c.cls == "CStorySceneEventAnimation" or c.cls == "CStorySceneEventAdditiveAnimation"
  if c.kind == "camera" and c.own and c.name:sub(1, #SF.OWN_EVENT + 7) == SF.OWN_EVENT .. "camera " then
    local el = require("conjunction.cr2w_tree").sget(w.s:obj(sec).events[c.ks[1]].props, "sceneElement", 0)
    local view, size = c.name:sub(#SF.OWN_EVENT + 8):match("^(.-)|(.*)$")
    local views, sizes = SF.views_for(w:moment_places(sec, el)), SF.SIZE_ORDER
    local vi, si = 1, 2
    for i, v in ipairs(views) do if v == view then vi = i end end
    for i, v in ipairs(sizes) do if v == size then si = i end end
    local half = (cw - 6) // 2
    if view == SF.OWN_VIEW then
      G.wrapped(x, y, cw, "Your view, taken from the game's camera. A view below puts one of Conjunction's in its place.",
                11, false, T.DIM)
      y = y + 2 * Q.line_h(11) + 6
      vi = 0
    end
    local vc, nv = CT.combo(key .. ".view", x, y, half, views, math.max(vi, 1), self.win.rect)
    if vc then self:after(w:set_moment_camera(sec, el, views[nv], sizes[si])) end
    local sc2, ns = CT.combo(key .. ".size", x + half + 6, y, half, sizes, si, self.win.rect)
    if sc2 then self:after(w:set_moment_camera(sec, el, views[math.max(vi, 1)], sizes[ns])) end
    y = y + 38
    local tv = self:button(key .. ".take", x, y, "Take this view", w3.camera ~= nil)
    if tv then self:take_view(sec, el) end
    y = y + bh + 6
    local fc = self:button(key .. ".free", x, y, "Free camera", w3.world ~= nil and w3.world.trace ~= nil)
    if fc then
      local v = w:free_camera(sec, el)
      self:after(v ~= nil, v == nil and "No view is free of walls here" or nil)
    end
    y = y + bh + 8
    G.wrapped(x, y, cw, "The camera holds until the next one. Split at playhead starts a moment that can have its own.",
              11, false, T.DIM)
    y = y + 2 * Q.line_h(11) + 8
    local clicked = self:button(key .. ".back", x, y, "Back to the section", true)
    if clicked then self.tl_pick = nil end
    return y + bh
  end
  if anim then
    local _, at, enter = CT.edit(key .. ".anim", x, y, cw, c.anim or "", {placeholder = "Animation (words, Enter searches)"})
    if enter then
      self.clip_hits = {}
      for _, a in ipairs(SW.find_animations(w.depot, at, 40)) do
        self.clip_hits[#self.clip_hits + 1] = {a[1], string.format("%.1f s  %s", a[2], a[3]), name = a[1], len = a[2]}
      end
      self.clip_st = {}
    end
    y = y + CT.edit_h() + 4
    if self.clip_hits and #self.clip_hits > 0 then
      local hh = math.min(130, #self.clip_hits * (Q.line_h(12) + Q.LIST_ROW) + 2)
      local ev, at2 = G.list_view(self, "cliphits", {x = x, y = y, w = cw, h = hh}, self.clip_hits, self.clip_st)
      if ev == "current" and self.clip_hits[at2] and c.actor then self:peek(c.actor, self.clip_hits[at2].name) end
      if ev == "double" and self.clip_hits[at2] then
        self:peek_stop()
        local a = self.clip_hits[at2]
        self.clip_hits = nil
        apply(function(sc) return sc:set_clip_anim(sec, c.id, a.name, a.len) end)
      end
      y = y + hh + 6
    end
  end
  local half = (cw - 8) // 2
  local function spin(id, lx, text, value, opts, run)
    label(lx, y + 8, text, T.DIM, 12)
    local changed, v = CT.spin(key .. "." .. id, lx + 70, y, value, opts)
    if changed then run(v) end
  end
  spin("start", x, "Start", c.start, {w = half - 70, min = 0, max = 600, step = 0.1, decimals = 2},
       function(v) apply(function(sc) return sc:move_clip(sec, c.id, v) end) end)
  if anim then
    spin("len", x + half + 8, "Length", c.dur, {w = half - 70, min = 0.1, max = 600, step = 0.1, decimals = 2},
         function(v) apply(function(sc) return sc:resize_clip(sec, c.id, c.start, c.start + v, len) end) end)
    y = y + CT.edit_h() + 6
    spin("speed", x, "Speed", c.speed or 1.0, {w = half - 70, min = 0.1, max = 5, step = 0.1, decimals = 2},
         function(v) apply(function(sc) return sc:set_clip_speed(sec, c.id, v, len) end) end)
    y = y + CT.edit_h() + 6
    spin("bin", x, "Blend in", c.blend_in or 0.0, {w = half - 70, min = 0, max = 5, step = 0.1, decimals = 2},
         function(v) apply(function(sc) return sc:set_clip_blend(sec, c.id, v, c.blend_out) end) end)
    spin("bout", x + half + 8, "Blend out", c.blend_out or 0.0, {w = half - 70, min = 0, max = 5, step = 0.1, decimals = 2},
         function(v) apply(function(sc) return sc:set_clip_blend(sec, c.id, c.blend_in, v) end) end)
    y = y + CT.edit_h() + 6
    if len then label(x, y, string.format("The animation is %.1f s long, a longer clip plays it again", len), T.DIM, 11) end
  else
    y = y + CT.edit_h() + 6
  end
  y = y + Q.line_h(11) + 10
  local clicked = self:button(key .. ".back", x, y, "Back to the section", true)
  if clicked then self.tl_pick = nil end
  return y + bh
end

function SCW:left(r)
  local bh = select(2, Q.button_size("Here now"))
  local x = r.x
  for _, t in ipairs({{"here", "Here now"}, {"all", "All scenes"}}) do
    local clicked, bw = self:button("tab." .. t[1], x, r.y, t[2], true)
    if self.tab == t[1] then D.rect(x, r.y + bh - 2, bw, 2, T.CHOSEN_EDGE, 1) end
    if clicked then self.tab = t[1] end
    x = x + bw + 4
  end
  local y = r.y + bh + 8
  local rows, st
  if self.tab == "all" then
    local eh = CT.edit_h()
    local t = G.search(self, {x = r.x, y = y, w = r.w, h = eh}, "Search " .. #self.all .. " scenes: quest, name, who",
                       nil)
    if t then
      self.text = t
      self:fill(t)
    end
    y = y + eh + 8
    rows, st = self.found, self.lst
  else
    local clicked = self:button("here.refresh", r.x, y, "Look again", true)
    if clicked then self:refresh_here() end
    y = y + bh + 8
    rows, st = self.here, self.here_st
    if #rows == 0 then
      G.wrapped(r.x + 4, y + 4, r.w - 8, "No quest is at a scene here and nobody near you is in one. All scenes " ..
                "has every scene of the game.", 12, false, T.DIM)
      return
    end
  end
  local ev, at = G.list_view(self, "scenes." .. self.tab, {x = r.x, y = y, w = r.w, h = r.y + r.h - y}, rows, st)
  if (ev == "current" or ev == "double") and rows[at] then self:open(rows[at].path) end
end

-- the scene's name, its buttons, the world state's line -> the y below
function SCW:head(m)
  local w = self.w
  local y = m.y
  y = y + label(m.x, y, self.label(w.path), T.BRIGHT, 14, true) + 2
  label(m.x, y, w.path, T.DIM, 11)
  y = y + Q.line_h(11) + 6
  local x = m.x
  local first = w.s:inputs()[1]
  local function btn(id, text, enabled, run)
    local clicked, bw = self:button(id, x, y, text, enabled)
    if clicked then run() end
    x = x + bw + 4
  end
  btn("play", "Play", first ~= nil, function() self:play(first and first.name) end)
  btn("undo", "Undo", #w.history > 0, function() self:after(w:undo()) end)
  btn("redo", "Redo", #w.future > 0, function() self:after(w:redo()) end)
  btn("revert", "The game's scene", w:changed(), function() self:after(w:revert()) end)
  local facts = w:facts()
  btn("facts", (self.facts_open and "Hide " or "") .. "World state (" .. #facts .. (#facts == 1 and " fact)" or " facts)"),
      #facts > 0,
      function() self.facts_open = not self.facts_open end)
  local bh = select(2, Q.button_size("Play"))
  y = y + bh + 4
  local state = w:changed() and "Changed: saved in the project. Play plays it now, the game's quests from the " ..
                "scene's next load" or "The game's own scene"
  if w:changed() and not require("conjunction.features").experimental() then
    state = state .. ". Building it needs Settings > General > Experimental"
  end
  if self.err then state = self.err end
  label(m.x, y, state, self.err and T.RED or T.DIM, 12)
  return y + Q.line_h(12) + 8
end

-- the facts the scene asks and sets: now in the game, and the value set for this scene -> its height
function SCW:facts_box(r)
  local w = self.w
  Q.view_frame(r.x, r.y, r.w, r.h)
  local y = r.y + 6
  label(r.x + 8, y, "The world for this scene: what the game has now, and the value set for the scene (set at once; " ..
        "back to the game's when you leave)", T.DIM, 11)
  y = y + Q.line_h(11) + 6
  local eh = CT.edit_h()
  for _, f in ipairs(w:facts()) do
    if y + eh > r.y + r.h - 4 then break end
    local x = r.x + 8
    label(x, y + 6, f.name, T.TEXT, 12)
    x = r.x + math.min(360, r.w // 2)
    label(x, y + 6, "now " .. f.now .. (f.reads > 0 and "  (asked)" or "") .. (f.sets > 0 and "  (set by it)" or ""),
          T.DIM, 12)
    x = x + 170
    local changed, v = CT.spin("panel.win." .. self.win.key .. ".fact." .. f.name, x, y, f.want or f.now,
                               {w = 90, min = -1000000, max = 1000000})
    if changed then w:set_fact(f.name, math.tointeger(v) or 0) end
    local clicked, bw = self:button("fact.game." .. f.name, x + 98, y, "The game's", f.want ~= nil)
    if clicked then w:set_fact(f.name, nil) end
    y = y + eh + 4
  end
  return r.h
end

-- --- the card of the row picked
function SCW:card(r)
  D.fill(r.x, r.y, r.w, r.h, T.SURFACE)
  local row = self.pick and self.rows[self.pick]
  local x, y, cw = r.x + 10, r.y + 10, r.w - 20
  if not row then
    G.wrapped(x, y, cw, "Click a row of the scene. A double click plays the scene from there.", 12, false, T.DIM)
    return
  end
  local w = self.w
  local s = w.s
  local kind = row.kind
  local tsec = self:timeline_section()
  local clip = tsec and self.tl_pick and s:timeline(tsec).clips[self.tl_pick]
  if clip then
    self:clip_card(clip, tsec, x, y, cw)
    return
  end
  local key = "panel.win." .. self.win.key
  local bh = select(2, Q.button_size("Play"))
  local function heading(t) y = y + label(x, y, t, T.BRIGHT, 14, true) + 8 end
  local function play_btn(target, text)
    local clicked = self:button("card.play", x, y, text or "Play from here", true)
    if clicked then self:play(target) end
    y = y + bh + 10
  end
  if kind == "input" then
    heading("Input " .. s:name_of(row.node))
    play_btn(s:name_of(row.node), "Play from this input")
    G.wrapped(x, y, cw, "A quest starts the scene here. The people of the scene are found by their voice tags " ..
              "near the player.", 12, false, T.DIM)
  elseif kind == "output" then
    heading("Output " .. s:name_of(row.node))
    G.wrapped(x, y, cw, "The scene ends here, and the quest goes on from this output.", 12, false, T.DIM)
  elseif kind == "if" then
    heading("If")
    local fact, op, value = s:fact_check(row.cond)
    if not fact then
      G.wrapped(x, y, cw, "A condition of another kind (" .. (s:obj(row.cond) and s:obj(row.cond).cls or "?") .. ")",
                12, false, T.DIM)
      return
    end
    label(x, y, "Fact", T.DIM, 12)
    y = y + Q.line_h(12) + 2
    local _, ft, enter = CT.edit(key .. ".if.fact", x, y, cw, fact, {})
    if enter and ft ~= fact then self:after(w:edit(function(sc) sc:set_fact_check(row.cond, ft, op, value) end)) end
    y = y + CT.edit_h() + 6
    local ops = {"=", "!=", "<", "<=", ">", ">="}
    local oi = 1
    for i, o in ipairs(ops) do if o == op then oi = i end end
    local changed, ni = CT.combo(key .. ".if.op", x, y, 70, ops, oi, self.win.rect)
    if changed then self:after(w:edit(function(sc) sc:set_fact_check(row.cond, fact, ops[ni], value) end)) end
    local vchanged, nv = CT.spin(key .. ".if.value", x + 78, y, value, {w = 100, min = -1000000, max = 1000000})
    if vchanged then self:after(w:edit(function(sc) sc:set_fact_check(row.cond, fact, op, math.tointeger(nv) or 0) end)) end
    y = y + 34
    local ok, now = pcall(function() return w3.fact.get(fact) end)
    label(x, y, "Now in the game: " .. tostring(ok and now or "?"), T.DIM, 12)
  elseif kind == "cutscene" then
    heading(s:name_of(row.node))
    play_btn(row.node)
    self:cutscene_card(row, x, y, cw, r)
  elseif kind == "section" and SW.is_own_cutscene(s, row.node) then
    heading("Cutscene of your own")
    play_btn(row.node)
    self:own_cutscene_card(row, x, y, cw, r)
  elseif row.set and kind == "section" then
    heading("Section " .. s:name_of(row.node))
    play_btn(row.node)
    self:own_scene_card(row, x, y, cw)
  elseif kind == "section" or kind == "video" or kind == "next" then
    heading((kind == "section" and "Section " or "") .. s:name_of(row.node))
    play_btn(row.node)
    if kind == "section" then
      local els = s:elements(row.node)
      local last
      for _, e in ipairs(els) do if e.kind == "line" then last = e end end
      local clicked, bw = self:button("card.add", x, y, "+ line at the end", true)
      if clicked then
        local speaker = last and last.speaker or (s:actors()[1] and s:actors()[1].id) or "GERALT"
        local n, err = w:add_line(row.node, els[#els] and els[#els].n or nil, speaker, "...", last and last.n or nil)
        self:after(n ~= nil, err)
      end
      local cclicked = self:button("card.cutscene", x + bw + 6, y, "+ cutscene after this", true)
      if cclicked then self:new_cutscene(row.node, false) end
    end
  elseif kind == "line" then
    self:line_card(row, x, y, cw, r)
  elseif kind == "pause" then
    heading("Pause")
    local e = s:obj(row.el)
    local secs = e and e:get("duration", e:get("approvedDuration", 0)) or 0
    label(x, y, "Seconds (Enter keeps them)", T.DIM, 12)
    y = y + Q.line_h(12) + 2
    local _, nt, enter = CT.edit(key .. ".pause.secs", x, y, 120, string.format("%.2f", secs), {})
    local v = tonumber((nt:gsub(",", ".")))
    if enter and v and v >= 0 then self:after(w:edit(function(sc) sc:set_duration(row.el, v) end)) end
    y = y + CT.edit_h() + 10
    local clicked = self:button("card.remove", x, y, "Remove", true)
    if clicked then self:after(w:edit(function(sc) sc:remove_element(row.node, row.el) end)) self.pick = nil end
  elseif kind == "answer" then
    heading("Answer")
    local c = s:obj(row.cl)
    local cur = c and c:get("choiceLine")
    local text = w:text_of(cur and cur.n)
    label(x, y, "Text", T.DIM, 12)
    y = y + Q.line_h(12) + 2
    local _, nt, enter = CT.edit(key .. ".answer.text", x, y, cw, text, {})
    if enter and nt ~= text then self:after(w:set_choice_text(row.cl, nt)) end
    y = y + CT.edit_h() + 8
    label(x, y, "Leads to", T.DIM, 12)
    y = y + Q.line_h(12) + 2
    local targets, names, at = {}, {}, 1
    local to = s:target(c:get("nextLinkElement", 0))
    for _, n in ipairs(self.flow.order) do
      local node = self.flow.nodes[n]
      if node.kind ~= "input" then
        targets[#targets + 1] = n
        names[#names + 1] = node.kind .. " " .. (node.name ~= "" and node.name or ("#" .. n))
        if n == to then at = #targets end
      end
    end
    local changed, ni = CT.combo(key .. ".answer.to", x, y, cw, names, at, self.win.rect)
    if changed then self:after(w:edit(function(sc) sc:set_choice_target(row.cl, targets[ni]) end)) end
    y = y + 38
    local clicked, bw = self:button("card.answer.copy", x, y, "+ answer like this", true)
    if clicked then
      self:after(w:edit(function(sc) sc:add_choice(row.cl, w:own_text_id(nil, "..."), to) end))
    end
    local rclicked = self:button("card.answer.remove", x + bw + 6, y, "Remove", true)
    if rclicked then self:after(w:edit(function(sc) sc:remove_choice(row.cl) end)) self.pick = nil end
  else
    heading(kind:sub(1, 1):upper() .. kind:sub(2))
    if row.el then
      local clicked = self:button("card.remove", x, y, "Remove", true)
      if clicked then self:after(w:edit(function(sc) sc:remove_element(row.node, row.el) end)) self.pick = nil end
    end
  end
end

-- a line: who says it, what (one's own text or one of the game's lines with its voice), how long, its camera and
-- the director's other events
function SCW:line_card(row, x, y, cw, r)
  local w = self.w
  local s = w.s
  local key = "panel.win." .. self.win.key
  local e = s:obj(row.el)
  if not e then return end
  local bh = select(2, Q.button_size("Play"))
  y = y + label(x, y, "Line", T.BRIGHT, 14, true) + 8
  -- who
  local actors, at = {}, 1
  for i, a in ipairs(s:actors()) do
    actors[i] = a.id
    if a.id == e:get("voicetag", "") then at = i end
  end
  label(x, y + 8, "Said by", T.DIM, 12)
  local changed, ni = CT.combo(key .. ".line.who", x + 70, y, cw - 70, actors, at, self.win.rect)
  if changed then self:after(w:edit(function(sc) sc:set_speaker(row.el, actors[ni]) end)) end
  y = y + 38
  -- what
  local id = e:get("dialogLine") and e:get("dialogLine").n
  local text = w:text_of(id)
  label(x, y, ST.is_pool(id) and "Text of your own (no voice)" or ("The game's line " .. tostring(id) .. " (its voice)"),
        T.DIM, 12)
  y = y + Q.line_h(12) + 2
  local _, nt, enter = CT.edit(key .. ".line.text", x, y, cw, text, {})
  if enter and nt ~= text then self:after(w:set_line_text(row.el, nt)) end
  y = y + CT.edit_h() + 4
  label(x, y, string.format("%.2f s  ·  Enter keeps a text of your own", e:get("approvedDuration", 0)), T.DIM, 11)
  y = y + Q.line_h(11) + 8
  -- a voice of the game's
  label(x, y, "A voice of the game's (words, Enter searches)", T.DIM, 12)
  y = y + Q.line_h(12) + 2
  local _, vt, venter = CT.edit(key .. ".line.voice", x, y, cw, self.voice, {placeholder = "words of the line"})
  if venter then
    self.voice = vt
    self.voices = {}
    local VO = require("conjunction.voices")
    if VO.ready() then
      local okv, v = pcall(VO.open)
      if okv then
        for _, l in ipairs(v:search(vt, e:get("voicetag", ""), nil, 30) or {}) do
          self.voices[#self.voices + 1] = {l.speaker .. ": " .. l.text, l.scene, sid = l.id, dur = l.dur}
        end
        if #self.voices == 0 then
          for _, l in ipairs(v:search(vt, nil, nil, 30) or {}) do
            self.voices[#self.voices + 1] = {l.speaker .. ": " .. l.text, l.scene, sid = l.id, dur = l.dur}
          end
        end
      end
    else
      self.voices = {{"The list of the game's voices is not built yet (Conjunction builds it once)"}}
    end
    self.voice_st.cur = nil
  end
  y = y + CT.edit_h() + 4
  if self.voices and #self.voices > 0 then
    local lh = math.min(150, #self.voices * (Q.line_h(12) + Q.LIST_ROW) + 2)
    local ev, at2 = G.list_view(self, "voices", {x = x, y = y, w = cw, h = lh}, self.voices, self.voice_st)
    if ev == "double" and self.voices[at2].sid then
      local VO = require("conjunction.voices")
      local l = self.voices[at2]
      self:after(w:set_voice(row.el, math.tointeger(tonumber(l.sid)), VO.length(l.sid, l.dur, l[1])))
    end
    y = y + lh + 2
    label(x, y, "A double click takes the line's words and voice", T.DIM, 11)
    y = y + Q.line_h(11) + 8
  end
  -- what the line does
  local bx = x
  local function btn(id2, text2, run)
    local clicked, bw = self:button(id2, bx, y, text2, true)
    if clicked then run() end
    bx = bx + bw + 4
  end
  btn("line.play", "Play", function() self:play(row.node) end)
  btn("line.add", "+ line after", function()
    local n, err = w:add_line(row.node, row.el, e:get("voicetag", ""), "...", row.el)
    self:after(n ~= nil, err)
  end)
  btn("line.up", "Up", function() self:after(w:edit(function(sc) sc:move_element(row.node, row.el, -1) end)) end)
  btn("line.down", "Down", function() self:after(w:edit(function(sc) sc:move_element(row.node, row.el, 1) end)) end)
  btn("line.remove", "Remove", function()
    self:after(w:edit(function(sc) sc:remove_element(row.node, row.el) end))
    self.pick = nil
  end)
  y = y + bh + 10
  -- the director's events on it
  local evs = s:events_of(row.node, row.el)
  label(x, y, "The director's events on this line (" .. #evs .. ")", T.DIM, 12)
  y = y + Q.line_h(12) + 4
  local cams = s:cameras()
  local eh = 30
  for _, ev in ipairs(evs) do
    if y + eh > r.y + r.h - 6 then break end
    local TR = require("conjunction.cr2w_tree")
    local name = short_cls(ev.cls)
    label(x, y + 8, string.format("%.2f  %s", ev.start or 0, name), T.TEXT, 12)
    local fx = x + 150
    local fw = cw - 150 - 30
    local cam = TR.sget(ev.props, "customCameraName")
    local anim = TR.sget(ev.props, "animationName")
    local target = TR.sget(ev.props, "target")
    if cam and #cams > 0 then
      local ci = 1
      for i, c in ipairs(cams) do if c == cam then ci = i end end
      local ch, nc = CT.combo(key .. ".ev.cam." .. ev.k, fx, y, fw, cams, ci, self.win.rect)
      if ch then self:after(w:edit(function(sc) sc:set_event(row.node, ev.k, "customCameraName", cams[nc]) end)) end
    elseif anim then
      local _, at3, aenter = CT.edit(key .. ".ev.anim." .. ev.k, fx, y, fw, anim, {})
      if aenter and at3 ~= anim then
        local len = SW.animation_length(w.depot, at3)
        self:after(w:edit(function(sc) sc:set_gesture(row.node, ev.k, at3, len) end))
      end
    elseif target then
      local names, ti = {}, 1
      for i, a in ipairs(s:actors()) do
        names[i] = a.id
        if a.id == target then ti = i end
      end
      local ch, nn = CT.combo(key .. ".ev.target." .. ev.k, fx, y, fw, names, ti, self.win.rect)
      if ch then self:after(w:edit(function(sc) sc:set_event(row.node, ev.k, "target", names[nn]) end)) end
    else
      local actor = TR.sget(ev.props, "actor")
      if actor then label(fx, y + 8, tostring(actor), T.DIM, 12) end
    end
    local xr = {x = x + cw - 24, y = y + 5, w = 20, h = 20}
    local clicked, hv = self:hit("ev.remove." .. ev.k, xr)
    if hv then D.fill(xr.x, xr.y, xr.w, xr.h, T.HOVER) end
    Q.draw_icon("x", T.DIM, 12, xr.x + 4, xr.y + 4)
    if clicked then self:after(w:edit(function(sc) sc:remove_event(row.node, ev.k) end)) end
    y = y + eh + 2
  end
end

-- a cutscene: what it plays and where, and the scenes Motion built that can take its place
function SCW:cutscene_card(row, x, y, cw, r)
  local w = self.w
  local path = w.s:cutscene_of(row.node)
  if not path then return end
  local tag, people = SW.cutscene_spot(w.depot, path)
  y = y + label(x, y, "Plays " .. (path:match("[^\\]+$") or path), T.DIM, 11) + 4
  label(x, y, "Spot " .. (tag ~= "" and tag or "(none)") .. "  ·  " .. table.concat(people, ", "), T.DIM, 12)
  y = y + Q.line_h(12) + 8
  local clicked = self:button("card.own_cutscene", x, y, "Build one of your own in its place", true)
  if clicked then
    self:new_cutscene(row.node, true)
    return
  end
  y = y + select(2, Q.button_size("Play")) + 12
  label(x, y, "A built scene in its place", T.BRIGHT, 13, true)
  y = y + Q.line_h(13, true) + 4
  if not self.built then
    self.built = {}
    for _, b in ipairs(SW.built_scenes(w.depot)) do self.built[#self.built + 1] = {b.name, b.path, path = b.path} end
    self.built_st = {}
  end
  if #self.built == 0 then
    G.wrapped(x, y, cw, "The game has no scene Motion built (a scene pack's DLC brings them).", 12, false, T.DIM)
    return
  end
  local lh = math.min(220, math.max(60, r.y + r.h - y - 60))
  local ev, at = G.list_view(self, "built", {x = x, y = y, w = cw, h = lh}, self.built, self.built_st)
  y = y + lh + 4
  G.wrapped(x, y, cw, "A double click puts it in: the player plays the player, the cutscene's people the others, " ..
            "at the cutscene's spot.", 11, false, T.DIM)
  if ev == "double" and self.built[at] then
    local set, err = w:replace_cutscene(row.node, self.built[at].path)
    self:after(set ~= nil, err)
    if set then
      for i, rw in ipairs(self.rows) do if rw.set == set then self.pick = i break end end
    end
  end
end

-- a section of a scene put in a cutscene's place: its spot (a tag of the world) and where the people stand from it
function SCW:own_scene_card(row, x, y, cw)
  local w = self.w
  local key = "panel.win." .. self.win.key .. ".own." .. row.set
  local o
  for _, it in ipairs(w.s:own_sets()) do if it.set == row.set then o = it end end
  if not o then return end
  self.spots = self.spots or {}
  label(x, y, "Spot (a tag in the world; Enter keeps it)", T.DIM, 12)
  y = y + Q.line_h(12) + 2
  local _, nt, enter = CT.edit(key .. ".tag", x, y, cw, o.tag, {})
  if enter and nt ~= "" and nt ~= o.tag then self:after(w:set_place_tag(row.set, nt)) end
  y = y + CT.edit_h() + 6
  local bx = x
  if o.tag ~= "PLAYER" then
    local clicked, bw = self:button(key .. ".try", bx, y, "Try at the player", true)
    if clicked then
      self.spots[row.set] = o.tag
      self:after(w:set_place_tag(row.set, "PLAYER"))
    end
    bx = bx + bw + 4
    local here, err = SW.player_from(o.tag)
    local hclicked = self:button(key .. ".here", bx, y, "Where I stand", here ~= nil)
    if hclicked and here then self:after(w:set_place(row.set, here, select(2, SW.player_from(o.tag)))) end
    if not here and err then
      y = y + select(2, Q.button_size("Play")) + 4
      label(x, y, err, T.DIM, 11)
    end
  elseif self.spots[row.set] then
    local back = self.spots[row.set]
    local clicked = self:button(key .. ".back", bx, y, "Back to " .. back, true)
    if clicked then
      self.spots[row.set] = nil
      self:after(w:set_place_tag(row.set, back))
    end
  end
  y = y + select(2, Q.button_size("Play")) + 10
  label(x, y, "From the spot (metres, degrees)", T.DIM, 12)
  y = y + Q.line_h(12) + 2
  local vals = {o.pos[1], o.pos[2], o.pos[3], o.yaw}
  local names = {"x", "y", "z", "turn"}
  local sw = (cw - 3 * 6) // 4
  for i = 1, 4 do
    local changed, v = CT.spin(key .. ".v" .. i, x + (i - 1) * (sw + 6), y, vals[i],
                               i == 4 and {w = sw, min = -360, max = 360, step = 5, decimals = 0} or
                               {w = sw, min = -50, max = 50, step = 0.1, decimals = 2})
    if changed then
      vals[i] = v
      self:after(w:set_place(row.set, {vals[1], vals[2], vals[3]}, vals[4]))
    end
  end
  y = y + CT.edit_h() + 2
  for i = 1, 4 do label(x + (i - 1) * (sw + 6), y, names[i], T.DIM, 11) end
  y = y + Q.line_h(11) + 10
  if o.view then
    label(x, y + 8, "Camera", T.DIM, 12)
    local vi = 1
    for i, v in ipairs(SF.VIEW_ORDER) do if v == o.view then vi = i end end
    local changed, ni = CT.combo(key .. ".view", x + 70, y, cw - 70, SF.VIEW_ORDER, vi, self.win.rect)
    if changed then self:after(w:set_camera(row.set, SF.VIEW_ORDER[ni])) end
    y = y + 38
  end
  G.wrapped(x, y, cw, "Everyone of the scene stands at the spot; the animations hold where each one is. Undo or The " ..
            "game's scene bring the cutscene back.", 11, false, T.DIM)
end

-- a cutscene of one's own after part n (replace: in its place), its row picked
function SCW:new_cutscene(n, replace, opts)
  local sec, err = self.w:add_cutscene(n, replace, opts)
  self:after(sec ~= nil, err)
  if sec then
    for i, rw in ipairs(self.rows) do if rw.node == sec and rw.kind == "section" then self.pick = i break end end
    self:open_cut(sec)
    self.moment_at = 1
    if w3.world and w3.world.trace then
      local m = self.w.s:moments(sec)[1]
      if m and self.w:free_camera(sec, m.el) then self:after(true) end
    end
  end
end

-- a cutscene of one's own: its spot, its moments, and the moment picked - its length, its camera, and for each
-- person an animation (search the game's and the scene packs') and a place
function SCW:own_cutscene_card(row, x, y, cw, r)
  local w = self.w
  local s = w.s
  local sec = row.node
  local key = "panel.win." .. self.win.key .. ".cut." .. s:name_of(sec)
  local bh = select(2, Q.button_size("Play"))
  local set = s:set_of(sec)
  local ds = set and s:obj(s:_dialogset(set) or 0)
  local tag = ds and (ds:get("placementTag") or {})[1] or "PLAYER"
  self.spots = self.spots or {}
  label(x, y + 8, "Spot", T.DIM, 12)
  local _, nt, enter = CT.edit(key .. ".tag", x + 50, y, cw - 50, tag, {})
  if enter and nt ~= "" and nt ~= tag then self:after(w:set_place_tag(set, nt)) end
  y = y + CT.edit_h() + 4
  if tag ~= "PLAYER" then
    local clicked = self:button(key .. ".try", x, y, "Try at the player", true)
    if clicked then
      self.spots[set] = tag
      self:after(w:set_place_tag(set, "PLAYER"))
    end
    y = y + bh + 8
  elseif self.spots[set] then
    local clicked = self:button(key .. ".back", x, y, "Back to " .. self.spots[set], true)
    if clicked then
      local back = self.spots[set]
      self.spots[set] = nil
      self:after(w:set_place_tag(set, back))
    end
    y = y + bh + 8
  end
  -- the moment at the playhead (the timeline shows them all): each person's animation and place
  local el = s:element_at(sec, self.playhead or 0)
  local m = el and s:moment(sec, el)
  if not m then return end
  G.wrapped(x, y, cw, "An animation found here goes onto the timeline at the playhead. The place is the person's in " ..
            "the moment at the playhead.", 11, false, T.DIM)
  y = y + 2 * Q.line_h(11) + 8
  -- each person: an animation and a place
  local people = {}
  for actor in pairs(m.places) do people[#people + 1] = actor end
  table.sort(people, function(a, b)
    if (a == "GERALT") ~= (b == "GERALT") then return a == "GERALT" end
    return a < b
  end)
  local sw = (cw - 2 * 6) // 3
  for _, actor in ipairs(people) do
    if y + 90 > r.y + r.h then break end
    label(x, y + 6, actor, T.BRIGHT, 12, true)
    local ph = self:button(key .. ".put." .. actor, x + cw - Q.button_size("Put here"), y, "Put here",
                           self.ed ~= nil and self.ed.request_object ~= nil)
    if ph then self:put_here(sec, m.el, actor) end
    y = y + bh + 4
    local cur = m.anims[actor] and m.anims[actor].name or ""
    local _, at2, aenter = CT.edit(key .. ".anim." .. actor .. "." .. m.el, x, y, cw, cur,
                                   {placeholder = "Animation (words, Enter searches)"})
    if aenter then
      self.anim_for = actor
      self.anim_hits = {}
      for _, a in ipairs(SW.find_animations(w.depot, at2, 40)) do
        self.anim_hits[#self.anim_hits + 1] = {a[1], string.format("%.1f s  %s", a[2], a[3]), name = a[1], len = a[2]}
      end
      self.anim_st = {}
    end
    y = y + CT.edit_h() + 2
    if self.anim_for == actor and self.anim_hits and #self.anim_hits > 0 then
      self.anim_st = self.anim_st or {}
      local hh = math.min(130, #self.anim_hits * (Q.line_h(12) + Q.LIST_ROW) + 2)
      local ev2, at3 = G.list_view(self, "anims", {x = x, y = y, w = cw, h = hh}, self.anim_hits, self.anim_st)
      if ev2 == "current" and self.anim_hits[at3] then self:peek(actor, self.anim_hits[at3].name) end
      if ev2 == "double" and self.anim_hits[at3] then     -- (on the timeline: at the playhead, once)
        local a = self.anim_hits[at3]
        self.anim_hits = nil
        self:peek_stop()
        self:add_anim(sec, actor, a.name, a.len, self.playhead or 0.0)
      end
      y = y + hh + 4
    end
    local pl = m.places[actor] or {0, 0, 0}
    for i = 1, 3 do
      local changed, nv2 = CT.spin(key .. ".place." .. actor .. "." .. m.el .. "." .. i, x + (i - 1) * (sw + 6), y, pl[i],
                                   i == 3 and {w = sw, min = -360, max = 360, step = 15, decimals = 0} or
                                   {w = sw, min = -20, max = 20, step = 0.1, decimals = 2})
      if changed then
        local np = {pl[1], pl[2], pl[3]}
        np[i] = nv2
        self:after(w:set_moment_place(sec, m.el, actor, np))
      end
    end
    y = y + CT.edit_h() + 1
    label(x, y, "x", T.DIM, 11)
    label(x + sw + 6, y, "y", T.DIM, 11)
    label(x + 2 * (sw + 6), y, "turn", T.DIM, 11)
    y = y + Q.line_h(11) + 8
  end
end

-- the playhead to second t: the scene shown there (the running section seeks, else it starts paused there)
function SCW:seek(sec, t)
  self.playhead, self.playing = t, nil
  if not self:live() then return end
  if self.restart_at then return end            -- (the changed scene starts soon, at the playhead)
  local pv = self:preview_of(sec)
  if pv and pv.o and not pv.o.started then      -- (the changed scene not started yet: it starts there; the old one
    pv.o.at = t                                 -- still plays and is no seek's)
    return
  end
  local okt, tm = pcall(SW.scene_time)
  if pv and okt and tm and tm.section == self.w.s:name_of(sec) then
    pcall(w3.scene.seek, t)
  elseif not (pv and pv.starting and w3.time and w3.time() - (pv.o and pv.o.started or pv.t0) < 1.5) then
    self:preview_at(sec, t, true)
  end
end

-- play from the playhead, pause, go on (an older TW3SE: the section plays from its start)
function SCW:play_pause(sec)
  if self.restart_at and self:live() then       -- (changed just now: the new scene plays from the playhead)
    self.restart_at = nil
    self:preview_at(sec, self.playhead or 0, false)
    return
  end
  local pv = self:preview_of(sec)
  if not self:live() then
    self:play(sec)
    self.playing = {t0 = w3.time and w3.time() or 0}
  elseif pv and not pv.paused then
    pcall(w3.scene.pause, true)
    pv.paused = true
  elseif pv then
    pcall(w3.scene.pause, false)
    pv.paused = false
  else
    self:preview_at(sec, self.playhead or 0, false)
  end
end

-- person `actor` plays animation `name` (len s) from second t; a scene pack's half brings its other half to the
-- other person
function SCW:add_anim(sec, actor, name, len, t)
  local w = self.w
  if not actor then return end
  local other, partner = SW.partner_of(w.depot, name, CUT.people(self, sec), actor)
  -- on top of what the person plays (the game's layer): an add_ animation - 15 619 of the 20 187 the game's scenes
  -- lay on top (_scratch/additive_audit.py) - or a gesture while they already play something, a walk (11.11.: a
  -- gesture dropped on a walking woman took the walk's place)
  local low = tostring(name):lower()
  local layer = low:sub(1, 4) == "add_"
  if not layer and low:find("gesture", 1, true) and not other then
    for _, tr in ipairs(w.s:timeline(sec).tracks) do
      if tr.kind == "anim" and tr.actor == actor then
        for _, c in ipairs(tr.clips) do
          if c.start <= (t or 0) + 0.01 and (t or 0) < c.start + c.dur - 0.05 then layer = true end
        end
      end
    end
  end
  local new
  local ok, err = w:edit(function(sc)
    new = sc:add_clip(sec, actor, name, len, t, nil, {layer = layer or nil})
    if other then sc:add_clip(sec, other, partner, SW.animation_length(w.depot, partner) or len, t, len) end
  end)
  self:after(ok, err)
  if new then self.tl_pick = new end
end

-- --- the cutscene editor (cut_view.lua): the window takes the whole screen, the game shows through its middle
function SCW:open_cut(sec)
  self.cut, self.bare = true, false
  self.cut_name = self.w.s:name_of(sec)
  self.tl_sec, self.tl_pick, self.playhead = self.cut_name, nil, 0.0
end
function SCW:cut_section()
  local sec = self.cut_name and self.w:section_named(self.cut_name)
  if not sec then self.cut = false end
  return sec
end
function SCW:full_screen() return self.cut == true and self.w ~= nil and self:cut_section() ~= nil end
function SCW:frame_full(r)
  self:peek_tick()
  local sec = self:cut_section()
  if sec then CUT.frame(self, r, sec) end
end
function SCW:covers_full(x, y) return CUT.covers(self, x, y) end

-- TW3SE's scene preview is there (a scene stands at a second, back and forth)
function SCW:live() return w3.scene ~= nil and w3.scene.seek ~= nil and w3.scene.pause ~= nil end

-- the preview of section sec when it is the one shown, else nil
function SCW:preview_of(sec)
  local pv = self.preview
  if pv and pv.name == self.w.s:name_of(sec) then
    if pv.starting and w3.time and (not pv.o or pv.o.started) and
       w3.time() - (pv.o and pv.o.started or pv.t0) > 1.0 then pv.starting = nil end
    return pv
  end
  return nil
end

-- animation `name` shown on the figure of person `actor`, again and again, until another is picked (a click in an
-- animation list; the scene playing ends it)
function SCW:peek(actor, name)
  if not (w3.anim and w3.anim.pose) then return end
  self:peek_stop()
  local e = self.w:figure_of(actor)
  if not e then self.err = actor .. " is not in the world near you" return end
  self.peek_at = {e = e, actor = actor, name = name, t0 = w3.time and w3.time() or 0, tries = 0}
end

function SCW:peek_stop()
  local pk = self.peek_at
  self.peek_at = nil
  if pk and pk.on and w3.anim and w3.anim.pose_clear then pcall(w3.anim.pose_clear, pk.e) end
end

function SCW:peek_tick()
  if self.restart_at and (not w3.time or w3.time() >= self.restart_at) then
    self.restart_at = nil
    local sec = self.preview and self.w and self.w:section_named(self.preview.name)
    if sec then self:preview_at(sec, self.playhead or 0, true) end
  end
  local pk = self.peek_at
  if not pk then return end
  if not pk.len then                             -- (its data may still stream in: asked again each frame, 3 s long)
    local len, why = SW.peek_ready(pk.e, pk.name)
    if not len then
      pk.tries = pk.tries + 1
      if (why and why ~= "") or pk.tries > 180 then
        self.err = pk.actor .. ": " .. ((why and why ~= "") and why or "the animation did not load")
        self.peek_at = nil
      end
      return
    end
    pk.len, pk.t0 = math.max(len, 0.1), w3.time and w3.time() or 0
  end
  local t = ((w3.time and w3.time() or 0) - pk.t0) % pk.len
  local ok = pcall(w3.anim.pose, pk.e, {{pk.name, t, 1.0}})
  pk.on = true
  if not ok then self:peek_stop() end
end

-- section sec plays from second t (paused: it stands there)
function SCW:preview_at(sec, t, paused)
  self.restart_at = nil                          -- (a play asked for now: no restart for the changes before it)
  self:peek_stop()
  local o = {at = t, paused = paused}            -- (SW:play reads o.at when the scene starts; it marks o.started)
  local ok, err = self.w:play(sec, o)
  if ok == false then self.err = err return end
  self.preview = {name = self.w.s:name_of(sec), paused = paused, t0 = w3.time and w3.time() or 0, starting = true,
                  o = o}
end

-- the game's camera now (Conjunction's free camera, flown where it should look from) is the camera of the moment at
-- element el (nil: the one at the playhead)
function SCW:take_view(sec, el)
  el = el or self.w.s:element_at(sec, self.playhead or 0)
  if not el then return end
  self:after(self.w:take_view(sec, el))
end

-- a click in the world puts the person there, in the moment at element el: the window goes while the world is
-- clicked (Conjunction's way of asking for a point, the quest board's), and comes back with the answer or Esc
-- a thing of the world at the playhead (the tab World of the cutscene editor): the window goes, the world is
-- clicked where the game draws it (Show what fits marks what fits), the scene switches it at that second.
-- act: light_on, light_off, door_open, door_close, effect, hide, show; kind: what fits (world_pick.lua)
function SCW:world_action(sec, act, kind)
  local ed = self.ed
  if not (ed and ed.request_object) then return end
  if ed.set_editing and not ed.editing then ed:set_editing(true) end
  local at = self.playhead or 0
  self.win.shown = false
  self.view_paused = true
  CUT.view(self, nil)
  -- (the preview gives the picture to the editor's camera while one picks, from where it looked last; it starts
  -- again at the playhead afterwards - 11.11.: the picture stayed the scene camera's, the markers were drawn for the
  -- flying camera somewhere else and one could not fly to a candle out of the shot)
  local c = ed.cam
  if require("conjunction.scene_stage").scene_on() then pcall(require("conjunction.scene_work").stop) end
  if c and c.pos and ed.exec then
    ed:exec(string.format("cj_cam_set(%.3f, %.3f, %.3f, %.1f, %.1f)", c.pos[1], c.pos[2], c.pos[3], c.yaw or 0.0,
                          c.pitch or 0.0))
  end
  local back = function()
    self.win.shown = true
    self.view_paused = nil
    pcall(self.preview_at, self, sec, at, true)
  end
  local function take(ref)
    back()
    local WP = require("conjunction.world_pick")
    local P = require("conjunction.py")
    local qid = P.str(ed.project:id())
    local wo = WP.get(ed.project, ref)
    local wid, tag = WP.id_of(ref), WP.tag(ed.project, ref)
    -- (the tag at once, for the preview: the build gives it through TW3SE after every load)
    pcall(function() local e = w3.by_guid((tostring(wo.guid):gsub(" ", "-"))) if e then e:AddTag(tag) end end)
    local o = {wid = wid, tag = tag}
    if act == "light_on" or act == "light_off" then o.what, o.on = "light", act == "light_on"
    elseif act == "door_open" or act == "door_close" then o.what, o.open = "door", act == "door_open"
    elseif act == "hide" or act == "show" then o.what = act
    elseif act == "move" then o.what = "anim"
    else o.what = "effect" end
    if o.what == "light" or o.what == "hide" or o.what == "show" or o.what == "anim" then
      o.fact = "@wa_" .. wid .. "_" .. (self.w.s:world_act_count() + 1)   -- (the build puts its run's id in)
    end
    if o.what == "effect" then
      local fx = P.list(P.get(wo, "effects"))
      if #fx == 0 then self:after(false, "It has no effect to play") return end
      if #fx > 1 then                              -- (which one: a list where the mouse is)
        local IM = require("conjunction.ui.inline_menu")
        local mx, my = w3.ui.mouse()
        local items = {}
        for _, f in ipairs(fx) do
          items[#items + 1] = {text = P.str(f), action = function()
            o.effect = P.str(f)
            self:after(self.w:add_world_action(sec, at, o))
          end}
        end
        IM.open("cut.act.effects", {x = mx, y = my, w = 200, h = 2}, items, self.win.rect)
        return
      end
      o.effect = P.str(fx[1])
    end
    if o.what == "anim" then                     -- (which of its moves: a list where the mouse is)
      local moves = P.list(P.get(wo, "anims"))
      if #moves == 0 then self:after(false, "It has no move of its own") return end
      if #moves > 1 then
        local IM = require("conjunction.ui.inline_menu")
        local mx, my = w3.ui.mouse()
        local items = {}
        for _, m in ipairs(moves) do
          items[#items + 1] = {text = P.str(m), action = function()
            o.anim = P.str(m)
            self:after(self.w:add_world_action(sec, at, o))
          end}
        end
        IM.open("cut.act.moves", {x = mx, y = my, w = 200, h = 2}, items, self.win.rect)
        return
      end
      o.anim = P.str(moves[1])
    end
    self:after(self.w:add_world_action(sec, at, o))
  end
  ed:request_object("pick", "things", function() back() self:after(false, "Pick a thing of the world (its marker)") end,
                    nil, nil, {back = back, cancelled = back, world = kind, world_done = take})
end

-- the things of the world as the scene leaves them at the playhead (MaximdeWinter 10.11.: the candle goes out while one
-- scrubs): per thing and kind the last clip before the playhead; none: as it was before the preview touched it
function SCW:world_preview(tl, pv)
  local ed = self.ed
  if not (ed and ed.project) then return end
  local TLm = require("conjunction.scene_timeline")
  local at = self.playhead or 0
  local want = {}                               -- "wid|kind" -> the clip's {what, state}
  for _, c in pairs(tl.clips or {}) do
    local nm = tostring(c.name or "")
    if nm:sub(1, #TLm.WORLD_ACT) == TLm.WORLD_ACT and (c.start or 0) <= at + 1e-3 then
      local what, wid, state = nm:sub(#TLm.WORLD_ACT + 1):match("^(%S+) (%S+) (%S+)")
      local group = (what == "light" or what == "anim") and what or
                    ((what == "hide" or what == "show") and "presence" or nil)
      if group then
        local k = wid .. "|" .. group
        if not want[k] or (c.start or 0) >= want[k].t then
          want[k] = {what = what, state = state, wid = wid, group = group, t = c.start or 0}
        end
      end
    end
  end
  self.wpv = self.wpv or {}
  local quick = not ((pv and not pv.paused) or self.playing)   -- (a seek: there at once; playing: as fast as the game)
  for k, h in pairs(self.wpv) do
    if not want[k] then self:world_apply(h, nil, quick) self.wpv[k] = nil end
  end
  for k, a in pairs(want) do
    local h = self.wpv[k]
    if not h or h.key ~= a.what .. " " .. a.state then
      h = h or {wid = a.wid, group = a.group}
      h.key = a.what .. " " .. a.state
      self:world_apply(h, a, quick)
      self.wpv[k] = h
    end
  end
end

-- one thing of the world as clip a wants it (nil: as it was)
function SCW:world_apply(h, a, quick)
  local WP = require("conjunction.world_pick")
  local o = WP.get(self.ed.project, WP.PREFIX .. h.wid)
  local e = o and w3.by_guid((tostring(o.guid):gsub(" ", "-")))
  if not e then return end
  pcall(function()
    if h.group == "light" then
      local lc = e:GetComponentByClassName("CGameplayLightComponent")
      if h.was == nil then h.was = lc:IsLightOn() and true or false end
      lc:SetLight(a and a.state == "on" or (not a and h.was))
    elseif h.group == "presence" then
      e:SetHideInGame(a ~= nil and a.what == "hide")
    elseif h.group == "anim" then
      local scale = quick and 0.01 or 1.0
      if h.played and (not a or a.state ~= h.played) then e:PlayPropertyAnimation(h.played, 1, 0.01, 1) end
      if a then e:PlayPropertyAnimation(a.state, 1, scale, 0) end
      h.played = a and a.state or nil
    end
  end)
end

function SCW:put_here(sec, el, actor)
  local ed = self.ed
  if not (ed and ed.request_object) then return end
  if ed.set_editing and not ed.editing then ed:set_editing(true) end
  self.win.shown = false
  self.view_paused = true                       -- (the world is clicked where the game draws it: full screen)
  CUT.view(self, nil)
  local back = function() self.win.shown = true self.view_paused = nil end
  ed:request_object("point", "point", function(_, p)
    self.win.shown = true
    self.view_paused = nil
    self:after(self.w:put_at(sec, el, actor, p))
  end, nil, nil, {back = back, cancelled = back})
end

-- a click in the world: the person walks there from where they stand at the playhead (SW:walk); the window goes
-- while the world is clicked, as for Put here
function SCW:walk_here(sec, actor)
  local ed = self.ed
  if not (ed and ed.request_object) then return end
  if ed.set_editing and not ed.editing then ed:set_editing(true) end
  local at = self.playhead or 0
  self.win.shown = false
  self.view_paused = true
  CUT.view(self, nil)
  local back = function() self.win.shown = true self.view_paused = nil end
  ed:request_object("point", "point", function(_, p)
    back()
    local to, err = self.w:to_spot(sec, p)
    if not to then self:after(false, err) return end
    local from = self.w:place_at(sec, actor, at)
    local tries = 0
    local function try()
      tries = tries + 1
      local r, why = self.w:walk(sec, actor, at, from, to, {fit = true})
      if r then
        self.note = nil
        self:after(true)
        self.tl_pick = r.id
      elseif why and why:find("still loading", 1, true) and tries < 12 and w3.after then
        self.note = "Measuring how fast " .. actor .. " walks ..."
        w3.after(0.5, try)
      else
        self.note = nil
        self:after(false, why)
      end
    end
    try()
  end, nil, nil, {back = back, cancelled = back})
end

function SCW:play(target)
  self.preview = nil
  self:peek_stop()
  local ok, err = self.w:play(target)
  if not ok then self.err = err end
end

return SCW
