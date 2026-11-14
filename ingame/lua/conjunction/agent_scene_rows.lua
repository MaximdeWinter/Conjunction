-- The scene workshop's rows for an agent and for the app (agent.lua's commands "scene_row*", "scene_line_*" ...):
-- what the card of a row shows and every change it makes, by name. A row is its number in scene_flow (`row`); after
-- a change the numbers can move: the answer says which row is picked now. Each change goes through the workshop's
-- own functions (scene_work.lua, the window's body), as a click in the card does.
local AR = {}

local TR = require("conjunction.cr2w_tree")
local ST = require("conjunction.scene_texts")

local function names_of(s)
  local out = {}
  for i, a in ipairs(s:actors()) do out[i] = a.id end
  return out
end

function AR.register(C, DOC, body)
  local function opened()
    local b = body()
    if not b.w then error("no scene is open (scene_open first)", 0) end
    return b, b.w, b.w.s
  end
  local function row_of(b, i, kinds)
    local r = b.rows[tonumber(i) or -1]
    if not r then error("no row " .. tostring(i) .. " (scene_flow lists them)", 0) end
    if kinds and not kinds[r.kind] then
      error("row " .. tostring(i) .. " is a " .. r.kind .. ", not a " .. table.concat((function()
        local k = {} for n in pairs(kinds) do k[#k + 1] = n end table.sort(k) return k end)(), " or "), 0)
    end
    b.pick = tonumber(i)
    return r
  end
  local function done(b, ok, err)
    if ok == false or ok == nil and err then error(tostring(err), 0) end
    b:after(true)
    return {pick = b.pick, rows = #b.rows}
  end

  DOC.scene_here = "The scenes the game is at now (the quests' and those of the people near) -> {path, label, why}"
  function C.scene_here()
    local b = body()
    b:refresh_here()
    local out = {}
    for _, h in ipairs(b.here) do out[#out + 1] = {path = h.path, label = h[1], why = h[2]:match("%((.*)%)$")} end
    return out
  end

  DOC.scene_row = "What the card of a row shows: row -> kind and its fields (a line: speaker, people, text, own, " ..
                  "seconds, events; an answer: text, to, targets; an if: fact, op, value, now; a pause: seconds ...)"
  function C.scene_row(a)
    local b, w, s = opened()
    local r = row_of(b, a.row)
    local out = {row = b.pick, kind = r.kind, section = r.node and s:name_of(r.node) or nil}
    if r.kind == "line" then
      local e = s:obj(r.el)
      local id = e:get("dialogLine") and e:get("dialogLine").n
      out.speaker, out.people = e:get("voicetag", ""), names_of(s)
      out.text, out.text_id, out.own = w:text_of(id), id, ST.is_pool(id)
      out.seconds = e:get("approvedDuration", 0)
      out.events = {}
      for _, ev in ipairs(s:events_of(r.node, r.el)) do
        out.events[#out.events + 1] = {event = ev.k, start = ev.start, kind = (require("conjunction.ui.scene_window")
          .EVENT_NAMES[ev.cls] or ev.cls), camera = TR.sget(ev.props, "customCameraName"),
          anim = TR.sget(ev.props, "animationName"), target = TR.sget(ev.props, "target"),
          actor = TR.sget(ev.props, "actor")}
      end
      out.cameras = s:cameras()
    elseif r.kind == "pause" then
      local e = s:obj(r.el)
      out.seconds = e and e:get("duration", e:get("approvedDuration", 0)) or 0
    elseif r.kind == "answer" then
      local c = s:obj(r.cl)
      local cur = c and c:get("choiceLine")
      out.text = w:text_of(cur and cur.n)
      local to = s:target(c:get("nextLinkElement", 0))
      out.targets = {}
      for _, n in ipairs(b.flow.order) do
        local node = b.flow.nodes[n]
        if node.kind ~= "input" then
          local name = node.kind .. " " .. (node.name ~= "" and node.name or ("#" .. n))
          out.targets[#out.targets + 1] = name
          if n == to then out.to = name end
        end
      end
    elseif r.kind == "if" then
      local fact, op, value = s:fact_check(r.cond)
      out.fact, out.op, out.value = fact, op, value
      if fact and w3.fact and w3.fact.get then
        local ok, now = pcall(w3.fact.get, fact)
        out.now = ok and now or nil
      end
    elseif r.kind == "cutscene" then
      local path = s:cutscene_of(r.node)
      local tag, people = require("conjunction.scene_work").cutscene_spot(w.depot, path)
      out.plays, out.spot, out.people = path, tag, people
    elseif r.kind == "section" and r.set then
      for _, it in ipairs(s:own_sets()) do
        if it.set == r.set then
          out.own = {tag = it.tag, x = it.pos[1], y = it.pos[2], z = it.pos[3], turn = it.yaw, view = it.view}
        end
      end
    end
    out.cutscene_of_own = r.kind == "section" and require("conjunction.scene_work").is_own_cutscene(s, r.node) or nil
    return out
  end

  DOC.scene_line_set = "Change a line: row, and any of speaker, text (a text of one's own; no voice), voice (the id " ..
                       "of a game's line from scene_voices: its words and voice)"
  function C.scene_line_set(a)
    local b, w, s = opened()
    local r = row_of(b, a.row, {line = true})
    if a.speaker then
      local ok, err = w:edit(function(sc) sc:set_speaker(r.el, a.speaker) end)
      if ok == false then error(tostring(err), 0) end
    end
    if a.text then
      local ok, err = w:set_line_text(r.el, a.text)
      if ok == false then error(tostring(err), 0) end
    end
    if a.voice then
      local VO = require("conjunction.voices")
      local sid = math.tointeger(tonumber(a.voice))
      local okv, v = pcall(VO.open)
      local l = okv and v.line and v:line(sid) or nil
      local ok, err = w:set_voice(r.el, sid, VO.length(sid, l and l.dur, l and l.text))
      if ok == false then error(tostring(err), 0) end
    end
    return done(b, true)
  end

  DOC.scene_line_add = "A new line: after the line in `row`, or at the end of the section in `row`: text, speaker " ..
                       "(default: the line's, or the section's last speaker)"
  function C.scene_line_add(a)
    local b, w, s = opened()
    local r = row_of(b, a.row, {line = true, section = true})
    local n, err
    if r.kind == "line" then
      local e = s:obj(r.el)
      n, err = w:add_line(r.node, r.el, a.speaker or e:get("voicetag", ""), a.text or "...", r.el)
    else
      local els = s:elements(r.node)
      local last
      for _, e in ipairs(els) do if e.kind == "line" then last = e end end
      local speaker = a.speaker or (last and last.speaker) or (s:actors()[1] and s:actors()[1].id) or "GERALT"
      n, err = w:add_line(r.node, els[#els] and els[#els].n or nil, speaker, a.text or "...", last and last.n or nil)
    end
    if not n then error(tostring(err or "no line added"), 0) end
    return done(b, true)
  end

  DOC.scene_row_move = "Move a line or pause up or down in its section: row, by (-1 up, 1 down)"
  function C.scene_row_move(a)
    local b, w = opened()
    local r = row_of(b, a.row, {line = true, pause = true, comment = true})
    return done(b, w:edit(function(sc) sc:move_element(r.node, r.el, (a.by or 1) < 0 and -1 or 1) end))
  end

  DOC.scene_row_remove = "Take a row out: a line, a pause, an answer, or another part of a section"
  function C.scene_row_remove(a)
    local b, w = opened()
    local r = row_of(b, a.row)
    local ok, err
    if r.kind == "answer" then
      ok, err = w:edit(function(sc) sc:remove_choice(r.cl) end)
    elseif r.el then
      ok, err = w:edit(function(sc) sc:remove_element(r.node, r.el) end)
    else
      error("a " .. r.kind .. " cannot be taken out here", 0)
    end
    b.pick = nil
    return done(b, ok, err)
  end

  DOC.scene_pause_set = "A pause this long: row, seconds"
  function C.scene_pause_set(a)
    local b, w = opened()
    local r = row_of(b, a.row, {pause = true})
    return done(b, w:edit(function(sc) sc:set_duration(r.el, tonumber(a.seconds) or 0) end))
  end

  DOC.scene_answer_set = "Change an answer: row, and any of text, to (a target as scene_row lists them)"
  function C.scene_answer_set(a)
    local b, w, s = opened()
    local r = row_of(b, a.row, {answer = true})
    if a.text then
      local ok, err = w:set_choice_text(r.cl, a.text)
      if ok == false then error(tostring(err), 0) end
    end
    if a.to then
      local target
      for _, n in ipairs(b.flow.order) do
        local node = b.flow.nodes[n]
        if node.kind .. " " .. (node.name ~= "" and node.name or ("#" .. n)) == a.to then target = n end
      end
      if not target then error("no target " .. tostring(a.to) .. " (scene_row lists them)", 0) end
      local ok, err = w:edit(function(sc) sc:set_choice_target(r.cl, target) end)
      if ok == false then error(tostring(err), 0) end
    end
    return done(b, true)
  end

  DOC.scene_answer_add = "A new answer like the one in `row` (same target): text"
  function C.scene_answer_add(a)
    local b, w, s = opened()
    local r = row_of(b, a.row, {answer = true})
    local to = s:target(s:obj(r.cl):get("nextLinkElement", 0))
    return done(b, w:edit(function(sc) sc:add_choice(r.cl, w:own_text_id(nil, a.text or "..."), to) end))
  end

  DOC.scene_if_set = "Change an if that asks a fact: row, and any of fact, op (= != < <= > >=), value"
  function C.scene_if_set(a)
    local b, w, s = opened()
    local r = row_of(b, a.row, {["if"] = true})
    local fact, op, value = s:fact_check(r.cond)
    if not fact then error("this if asks something other than a fact", 0) end
    return done(b, w:edit(function(sc)
      sc:set_fact_check(r.cond, a.fact or fact, a.op or op, math.tointeger(tonumber(a.value)) or value)
    end))
  end

  DOC.scene_event_set = "Change a director's event on a line: row, event (its number from scene_row), and camera, " ..
                        "anim (a gesture) or target (who is looked at)"
  function C.scene_event_set(a)
    local b, w, s = opened()
    local r = row_of(b, a.row, {line = true})
    local k = math.tointeger(tonumber(a.event))
    if a.camera then return done(b, w:edit(function(sc) sc:set_event(r.node, k, "customCameraName", a.camera) end)) end
    if a.target then return done(b, w:edit(function(sc) sc:set_event(r.node, k, "target", a.target) end)) end
    if a.anim then
      local len = require("conjunction.scene_work").animation_length(w.depot, a.anim)
      return done(b, w:edit(function(sc) sc:set_gesture(r.node, k, a.anim, len) end))
    end
    error("camera, anim or target is needed", 0)
  end

  DOC.scene_event_remove = "Take a director's event off a line: row, event"
  function C.scene_event_remove(a)
    local b, w = opened()
    local r = row_of(b, a.row, {line = true})
    return done(b, w:edit(function(sc) sc:remove_event(r.node, math.tointeger(tonumber(a.event))) end))
  end

  DOC.scene_voices = "The game's spoken lines by words (speaker: a voice tag first) -> {voice (id), speaker, text, " ..
                     "scene, seconds}"
  function C.scene_voices(a)
    local VO = require("conjunction.voices")
    if not VO.ready() then error("the list of the game's voices is not built yet (Conjunction builds it once)", 0) end
    local v = VO.open()
    local list = v:search(a.words or "", a.speaker, nil, a.limit or 30) or {}
    if #list == 0 and a.speaker then list = v:search(a.words or "", nil, nil, a.limit or 30) or {} end
    local out = {}
    for _, l in ipairs(list) do
      out[#out + 1] = {voice = l.id, speaker = l.speaker, text = l.text, scene = l.scene, seconds = l.dur}
    end
    return out
  end

  DOC.scene_facts = "The world for the scene: the facts it asks and sets -> {name, now, want (the value set for it), reads, sets}"
  function C.scene_facts()
    local _, w = opened()
    local out = {}
    for _, f in ipairs(w:facts()) do
      out[#out + 1] = {name = f.name, now = f.now, want = f.want, reads = f.reads, sets = f.sets}
    end
    return out
  end

  DOC.scene_fact_set = "A fact's value while the scene is open (set at once, back to the game's when it closes): " ..
                       "name, value (nil: the game's again)"
  function C.scene_fact_set(a)
    local _, w = opened()
    w:set_fact(a.name, a.value ~= nil and (math.tointeger(tonumber(a.value)) or 0) or nil)
    return {name = a.name, want = a.value}
  end

  DOC.scene_built = "The scenes Motion built that can take a cutscene's place -> {name, path}"
  function C.scene_built()
    local _, w = opened()
    local out = {}
    for _, x in ipairs(require("conjunction.scene_work").built_scenes(w.depot)) do
      out[#out + 1] = {name = x.name, path = x.path}
    end
    return out
  end

  DOC.scene_replace_built = "A built scene in a cutscene's place: row (the cutscene), path (from scene_built)"
  function C.scene_replace_built(a)
    local b, w = opened()
    local r = row_of(b, a.row, {cutscene = true})
    local set, err = w:replace_cutscene(r.node, a.path)
    if not set then error(tostring(err), 0) end
    b:after(true)
    for i, rw in ipairs(b.rows) do if rw.set == set then b.pick = i break end end
    return {pick = b.pick, rows = #b.rows}
  end

  DOC.scene_own_set = "A section put in a cutscene's place: row, and any of tag (the spot), x, y, z, turn (from the " ..
                      "spot), view (its camera)"
  function C.scene_own_set(a)
    local b, w, s = opened()
    local r = row_of(b, a.row, {section = true})
    if not r.set then error("this section is no scene put in a cutscene's place", 0) end
    local o
    for _, it in ipairs(s:own_sets()) do if it.set == r.set then o = it end end
    if a.tag then
      local ok, err = w:set_place_tag(r.set, a.tag)
      if ok == false then error(tostring(err), 0) end
    end
    if a.x or a.y or a.z or a.turn then
      local ok, err = w:set_place(r.set, {a.x or o.pos[1], a.y or o.pos[2], a.z or o.pos[3]}, a.turn or o.yaw)
      if ok == false then error(tostring(err), 0) end
    end
    if a.view then
      local ok, err = w:set_camera(r.set, a.view)
      if ok == false then error(tostring(err), 0) end
    end
    return done(b, true)
  end

  DOC.scene_play_from = "Play the scene from a row (an input, a section, a line's section)"
  function C.scene_play_from(a)
    local b, _, s = opened()
    local r = row_of(b, a.row)
    if r.kind == "input" then b:play(s:name_of(r.node)) elseif r.node then b:play(r.node) end
    return {playing = true, err = b.err}
  end
end

return AR
