-- The scene workshop and its cutscene editor for an agent (agent.lua's commands "scene_*"): every step a person
-- does with the mouse, by name - a scene opened, a cutscene of one's own made, animations found and put on the
-- timeline, clips moved and changed, cameras, places, the live preview. Each command goes through the window's own
-- functions (ui/scene_window.lua), so what an agent does shows in the window and in the game as a click would.
-- Times are seconds of the section; a section is named by its name (scene_flow lists them).
local AS = {}

-- the scene workshop's body (opened when it is not); AS.get_body can stand in for it (a test's own window)
AS.get_body = nil
local function body()
  if AS.get_body then return AS.get_body() end
  local A = require("conjunction.agent")
  local app = A.app
  if not (app and app.panel) then error("Conjunction is not running in the game", 0) end
  local win = app.panel.windows and app.panel.windows.scenes
  if not win then win = app.panel:open_scenes(app.ed) end
  return win.body
end

local function opened()
  local b = body()
  if not b.w then error("no scene is open (scene_open first)", 0) end
  return b, b.w
end

local function section(b, name)
  local sec = name and b.w:section_named(name) or (b.cut and b:cut_section()) or b:timeline_section()
  if not sec then error("no section " .. tostring(name) .. " (scene_flow lists them)", 0) end
  return sec
end

local function done(b, ok, err)
  if ok == false then error(tostring(err), 0) end
  b:after(true)
end

local function clip_out(c)
  return {id = c.id, kind = c.kind, actor = c.actor, label = c.label, anim = c.anim, start = c.start, length = c.dur,
          speed = c.speed, blend_in = c.blend_in, blend_out = c.blend_out, pieces = #c.ks, own = c.own,
          fade_in = c.fade_in, event = c.event, who = c.who, volume = c.volume, effect = c.effect, stop = c.stops}
end

function AS.register(C, DOC)
  DOC.scene_find = "Scenes of the game by words (quest, scene name, who is in it): words, limit -> {path, label}"
  function C.scene_find(a)
    local b = body()
    b:fill(a.words or "")
    local out = {}
    for i, f in ipairs(b.found or {}) do
      if i > (a.limit or 20) then break end
      out[#out + 1] = {path = f.path, label = f[1]}
    end
    return out
  end

  DOC.scene_open = "Open a scene of the game in the workshop: path -> its flow (scene_flow). layer = true: a scene of " ..
                   "the project's own quest (a talk): only its staging is kept, as its layer; a text names the " ..
                   "layer (a talk's node: \"s12\")"
  function C.scene_open(a)
    local b = body()
    b:open(a.path, a.layer)
    if b.err then error(b.err, 0) end
    return C.scene_flow({})
  end

  DOC.scene_flow = "The open scene as it plays: rows {i, kind, text, section (the section's name)}"
  function C.scene_flow()
    local b, w = opened()
    local out = {}
    for i, r in ipairs(b.rows) do
      local o = r.node and w.s:obj(r.node)
      out[#out + 1] = {i = i, kind = r.kind, text = (tostring(r[1]):gsub("^%s+", "")),
                       section = (o and o.cls and o.cls:find("Section")) and w.s:name_of(r.node) or nil}
    end
    return {path = w.path, changed = w:changed(), rows = out}
  end

  DOC.scene_cutscene = "A cutscene of one's own: in the place of the game's cutscene whose name has `cutscene` " ..
                       "(replace, the default), after the section named `after`, before the section named `before` " ..
                       "(what led to it leads to the new one), or free = true (in no flow: an answer leads to it, " ..
                       "scene_choice); people (voice tags, e.g. {\"GERALT\"}: only these; else the scene's): it opens " ..
                       "in the cutscene editor -> {section, people, length}"
  function C.scene_cutscene(a)
    local b, w = opened()
    local target
    local named = a.after or a.before
    for _, r in ipairs(b.rows) do
      if a.cutscene and r.kind == "cutscene" and tostring(r[1]):find(a.cutscene, 1, true) then target = r.node break end
      if named and r.node and w.s:name_of(r.node) == named and r.kind == "section" then target = r.node break end
    end
    if a.free and not (a.cutscene or named) then target = 0 end
    if not target then error("no cutscene or section like that (scene_flow lists them)", 0) end
    local opts = type(a.people) == "table" and #a.people > 0 and {people = a.people} or {}
    opts.before, opts.free = a.before ~= nil or nil, a.free == true or nil
    b:new_cutscene(target, a.cutscene ~= nil and a.replace ~= false and not a.free, opts)
    local sec = b:cut_section()
    if not sec then error(tostring(b.err or "no cutscene made"), 0) end
    if a.editor == false then b.cut = false end
    return {section = w.s:name_of(sec), people = require("conjunction.ui.cut_view").people(b, sec),
            length = w.s:timeline(sec).length}
  end

  DOC.scene_editor = "The cutscene editor on (section) or off (open = false)"
  function C.scene_editor(a)
    local b = opened()
    if a.open == false then b.cut = false return {editor = false} end
    b:open_cut(section(b, a.section))
    return {editor = true, section = b.cut_name}
  end

  DOC.scene_timeline = "A section's timeline: length, moments, tracks with their clips {id, label, anim, start, length, speed, ...}"
  function C.scene_timeline(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local tl = w.s:timeline(sec)
    local tracks = {}
    for _, tr in ipairs(tl.tracks) do
      local clips = {}
      for _, c in ipairs(tr.clips) do clips[#clips + 1] = clip_out(c) end
      tracks[#tracks + 1] = {id = tr.id, kind = tr.kind, actor = tr.actor, clips = clips}
    end
    local moments = {}
    for _, e in ipairs(tl.elements) do
      local o = w.s:obj(e.n)
      local m = {start = e.start, length = e.len, kind = o.cls == "CStorySceneLine" and "line" or "pause"}
      if m.kind == "line" then
        local id = o:get("dialogLine") and o:get("dialogLine").n
        m.speaker, m.text = o:get("voicetag", ""), w:text_of(id)
        m.own = require("conjunction.scene_texts").is_pool(id)
      end
      moments[#moments + 1] = m
    end
    return {section = w.s:name_of(sec), length = tl.length, moments = moments, tracks = tracks,
            people = require("conjunction.ui.cut_view").people(b, sec), playhead = b.playhead}
  end

  DOC.scene_animations = "Animations to use: words, kind (Gestures, Standing, Sitting, Kneeling, Lying, Pairs), limit " ..
                         "-> {name, length, pair}"
  function C.scene_animations(a)
    local b = opened()
    b.lib_text, b.lib_kind, b.lib_list = a.words or "", a.kind or "All", nil
    local out = {}
    for i, x in ipairs(require("conjunction.ui.cut_view").found(b)) do
      if i > (a.limit or 40) then break end
      out[#out + 1] = {name = x.name, length = x.len, pair = x.pair}
    end
    return out
  end

  DOC.scene_clip_add = "A person plays an animation: section, actor, anim, at (s; default the playhead), length " ..
                       "(default once; longer plays it again); layer = true: on top of what they play (the game's " ..
                       "additive gestures add_*), weight how strongly (the game's 0.3-0.8); from: seconds into it (the " ..
                       "game's stops start from their middle); motion = true: it carries the person (starts, stops, " ..
                       "turns); blend_in, blend_out. A scene pack's half " ..
                       "brings its other half to the other person -> {id}"
  function C.scene_clip_add(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local SW = require("conjunction.scene_work")
    -- (the figure's own length first: the depot's list keeps one length a name, and names repeat across sets)
    local fig = w:figure_of(a.actor)
    local okd, sm = pcall(function() return fig and w3.anim and w3.anim.sample(fig, a.anim, 0) end)
    local len = a.anim_length or (okd and sm and sm.duration and sm.duration > 0 and sm.duration) or
                SW.animation_length(w.depot, a.anim)
    if not len then error("no animation " .. tostring(a.anim) .. " (scene_animations finds them)", 0) end
    local at = a.at or b.playhead or 0
    -- (a scene pack's half: its other half to the other person, for as long - as the editor's add_anim does)
    local CUTV = require("conjunction.ui.cut_view")
    local other, partner = SW.partner_of(w.depot, a.anim, CUTV.people(b, sec), a.actor)
    local function with_partner(s)
      if other then
        s:add_clip(sec, other, partner, SW.animation_length(w.depot, partner) or len, at, a.length or len)
      end
    end
    if a.layer or a.weight or a.from or a.motion or a.blend_in or a.blend_out then
      local new
      local ok, err = w:edit(function(s)
        new = s:add_clip(sec, a.actor, a.anim, len, at, a.length,
          {layer = a.layer, weight = a.weight, front = a.from, motion = a.motion, blend_in = a.blend_in,
           blend_out = a.blend_out})
        if not a.layer then with_partner(s) end
      end)
      done(b, ok, err)
      return {id = new, length = len, other = other}
    end
    if a.length and a.length ~= len then
      local new
      local ok, err = w:edit(function(s)
        new = s:add_clip(sec, a.actor, a.anim, len, at, a.length)
        with_partner(s)
      end)
      done(b, ok, err)
      return {id = new, other = other}
    end
    b:add_anim(sec, a.actor, a.anim, len, at)
    return {id = b.tl_pick}
  end

  DOC.scene_clip_set = "Change a clip: section, id, and any of anim, speed, start, length, blend_in, blend_out -> {id} " ..
                       "(the id may change: use the one given back)"
  function C.scene_clip_set(a)
    local b, w = opened()
    local function sec() return section(b, a.section) end    -- (numbers move when events go: found again)
    local SW = require("conjunction.scene_work")
    local id = a.id
    local function clip() local c = w.s:timeline(sec()).clips[id] if not c then error("no clip " .. tostring(id), 0) end return c end
    local function apply(fn)
      local new
      local ok, err = w:edit(function(s) new = fn(s) end)
      if ok == false then error(tostring(err), 0) end
      id = new or id
    end
    clip()
    if a.anim then apply(function(s) return s:set_clip_anim(sec(), id, a.anim, SW.animation_length(w.depot, a.anim)) end) end
    local len = function() local c = clip() return c.anim and SW.animation_length(w.depot, c.anim) end
    if a.speed then apply(function(s) return s:set_clip_speed(sec(), id, a.speed, len()) end) end
    if a.length then local c = clip() apply(function(s) return s:resize_clip(sec(), id, c.start, c.start + a.length, len()) end) end
    if a.start then apply(function(s) return s:move_clip(sec(), id, a.start) end) end
    if a.blend_in or a.blend_out then
      local c = clip()
      apply(function(s) return s:set_clip_blend(sec(), id, a.blend_in or c.blend_in, a.blend_out or c.blend_out) end)
    end
    b.tl_pick = id
    b:after(true)
    return {id = id}
  end

  DOC.scene_effect_add = "An effect at second `at` (default the playhead): what = fade (seconds, fade_in, color = " ..
                         "{r, g, b}), sound (event: a Wwise event, actor: where it sounds, bone, volume in dB) or fx " ..
                         "(actor, effect: one of their entity's effects, stop) -> {id}"
  function C.scene_effect_add(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local id
    local ok, err = w:edit(function(s)
      id = s:add_effect(sec, a.what, a.at or b.playhead or 0, {seconds = a.seconds, fade_in = a.fade_in,
        color = a.color and {a.color.r or a.color[1], a.color.g or a.color[2], a.color.b or a.color[3]} or nil,
        event = a.event, actor = a.actor, bone = a.bone, volume = a.volume, effect = a.effect, stop = a.stop})
    end)
    done(b, ok, err)
    b.tl_pick = id
    return {id = id}
  end

  DOC.scene_effect_set = "Change an effect: section, id, and any of seconds, fade_in, event, actor, bone, volume, " ..
                         "effect, stop (its place and length: scene_clip_set start / length)"
  function C.scene_effect_set(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local ok, err = w:edit(function(s)
      if not s:set_effect(sec, a.id, a) then error("no effect " .. tostring(a.id), 0) end
    end)
    done(b, ok, err)
    return {id = a.id}
  end

  -- the line of a section at second t (an element that is a line) -> its element, or an error
  local function line_at(w, sec, t)
    for _, e in ipairs(w.s:_laid(sec)) do
      if e.start <= t + 1e-6 and t < e.start + e.len - 1e-6 and w.s:obj(e.n).cls == "CStorySceneLine" then return e.n end
    end
    error("no line at " .. tostring(t) .. " s (scene_timeline lists the moments)", 0)
  end

  DOC.scene_choice = "A choice at the end of a section, as the game's talks have one: section, answers = {{text (one's " ..
                     "own words), to: a section's name or output = a name (an output of the scene - a quest's 'play " ..
                     "scene' goes on from it by that name; blackscreen = true: it ends black), pay (money: the " ..
                     "game's coin, paid when chosen), exit = true (the way out), once, emphasis}}, seconds (to choose, " ..
                     "default 10) -> {choice, answers}"
  function C.scene_choice(a)
    local b, w = opened()
    local sec = section(b, a.section)
    if type(a.answers) ~= "table" or #a.answers == 0 then error("a choice needs answers", 0) end
    local list = {}
    for i, ans in ipairs(a.answers) do
      if not ans.text or ans.text == "" then error("answer " .. i .. " has no text", 0) end
      list[i] = {text_id = w:own_text_id(nil, ans.text), pay = ans.pay, exit = ans.exit, once = ans.once,
                 emphasis = ans.emphasis, to_section = ans.to, output = ans.output, blackscreen = ans.blackscreen}
    end
    local ch
    local ok, err = w:edit(function(s)
      for i, ans in ipairs(list) do
        if ans.output then
          ans.to = s:scene_output(ans.output, {blackscreen = ans.blackscreen, blend = not ans.blackscreen and 1.5 or nil})
        elseif ans.to_section then
          ans.to = section(b, ans.to_section)
        else error("answer " .. i .. " leads nowhere: to (a section) or output (a name)", 0) end
      end
      ch = s:set_choice(sec, list, a.seconds)
    end)
    done(b, ok, err)
    return {choice = ch, answers = #list}
  end

  DOC.scene_fact = "A fact the scene sets on the way into a section or an output, as the game's scenes do (AddFact_S): " ..
                   "fact, value (1), and section or output (a name, made when the scene has none of that name); a " ..
                   "quest's 'wait for a fact' goes on from it -> {script, fact, value}"
  function C.scene_fact(a)
    local b, w = opened()
    if not a.fact or a.fact == "" then error("which fact?", 0) end
    if not (a.section or a.output) then error("before what: section or output", 0) end
    local value = math.tointeger(a.value or 1) or 1
    local sec = a.section and section(b, a.section)
    local n
    local ok, err = w:edit(function(s)
      n = s:add_fact(sec or s:scene_output(a.output), a.fact, value)
    end)
    done(b, ok, err)
    return {script = n, fact = a.fact, value = value}
  end

  DOC.scene_hold = "Many changes at once: on = true holds them (each takes effect at once but the scene is written " ..
                   "once), on = false writes them. A play writes them as well; a change that fails undoes the held " ..
                   "ones -> {held}"
  function C.scene_hold(a)
    local b, w = opened()
    local ok, err = w:hold(a.on ~= false)
    if ok == false then error(tostring(err), 0) end
    b:after(true)
    return {held = w.held ~= nil}
  end

  DOC.scene_say_add = "A line at second `at` (default the playhead): speaker, and text (one's own words) or voice " ..
                      "(a game's line from scene_voices, with its seconds). The time after it moves back by the line's " ..
                      "length -> {at, length}"
  function C.scene_say_add(a)
    local b, w = opened()
    local at = a.at or b.playhead or 0
    local sec = section(b, a.section)
    local okp, cls = pcall(function()
      local e = w.s:element_at(sec, at)
      return e and w.s:obj(e).cls
    end)
    if okp and cls == "CStoryScenePauseElement" then          -- (a pause is split where the line goes)
      w:edit(function(s) s:split_at(sec, at) end)
      sec = section(b, a.section)
    end
    local after
    for _, e in ipairs(w.s:_laid(sec)) do
      if e.start + e.len <= at + 0.05 then after = e.n end
    end
    local speaker = a.speaker or "GERALT"
    local n, err = w:add_line(sec, after, speaker, a.text or "...", nil)
    if not n then error(tostring(err or "no line added"), 0) end
    if a.voice then
      local VO = require("conjunction.voices")
      local sid = math.tointeger(tonumber(a.voice))
      local ok2, err2 = w:set_voice(n, sid, VO.length(sid, a.seconds, nil))
      if ok2 == false then error(tostring(err2), 0) end
    end
    b:after(true)
    sec = section(b, a.section)
    for _, e in ipairs(w.s:_laid(sec)) do
      if w.s:obj(e.n).cls == "CStorySceneLine" and math.abs(e.start - at) < 0.1 then
        return {at = e.start, length = e.len}
      end
    end
    return {at = at}
  end

  DOC.scene_say_set = "Change the line at second `at`: speaker, text (one's own words) or voice (a game's line)"
  function C.scene_say_set(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local el = line_at(w, sec, a.at or b.playhead or 0)
    if a.speaker then
      local ok, err = w:edit(function(s) s:set_speaker(el, a.speaker) end)
      if ok == false then error(tostring(err), 0) end
    end
    if a.text then
      local ok, err = w:set_line_text(el, a.text)
      if ok == false then error(tostring(err), 0) end
    end
    if a.voice then
      local VO = require("conjunction.voices")
      local sid = math.tointeger(tonumber(a.voice))
      local ok, err = w:set_voice(el, sid, VO.length(sid, a.seconds, nil))
      if ok == false then error(tostring(err), 0) end
    end
    b:after(true)
    return {ok = true}
  end

  DOC.scene_say_remove = "Take out the line at second `at` (the time after it moves forward)"
  function C.scene_say_remove(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local el = line_at(w, sec, a.at or b.playhead or 0)
    done(b, w:edit(function(s) s:remove_element(sec, el) end))
    return {removed = true}
  end

  DOC.scene_clip_remove = "Take a clip out: section, id"
  function C.scene_clip_remove(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local ok, err = w:edit(function(s) if not s:remove_clip(sec, a.id) then error("no clip " .. tostring(a.id), 0) end end)
    done(b, ok, err)
    return {removed = a.id}
  end

  DOC.scene_length = "A cutscene of one's own this long: section, seconds"
  function C.scene_length(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local ok, err = w:edit(function(s) if not s:set_length(sec, a.seconds) then error("only a section that ends in a pause", 0) end end)
    done(b, ok, err)
    return {length = w.s:timeline(section(b, a.section)).length}
  end

  DOC.scene_split = "A new moment from second `at` on (each moment can have its own camera and places): section, at"
  function C.scene_split(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local ok, err = w:edit(function(s) local n, e = s:split_at(sec, a.at) if not n then error(e, 0) end end)
    done(b, ok, err)
    return {moments = #w.s:timeline(section(b, a.section)).elements}
  end

  local function moment_at(b, w, sec, at)
    local el = w.s:element_at(sec, at or b.playhead or 0)
    if not el then error("no moment there", 0) end
    return el
  end

  DOC.scene_camera = "The camera of the moment at second `at`: view (side, other side, front, back, close, above) and " ..
                     "size (wide, medium, close); or take = true: the game's camera as it is now; or free = true: " ..
                     "the first view with no wall in between"
  function C.scene_camera(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local el = moment_at(b, w, sec, a.at)
    if a.take then done(b, w:take_view(sec, el))
    elseif a.free then
      local v = w:free_camera(sec, el)
      if not v then error("no view is free of walls here", 0) end
      b:after(true)
      return {view = v}
    else done(b, w:set_moment_camera(sec, el, a.view or "side", a.size or "medium")) end
    return {ok = true}
  end

  -- a camera given by an agent -> {pos (scene space), pitch, yaw, fov, focus}: take = true (the game's camera now),
  -- or a point of the world (x, y, z) with pitch and yaw, or with look_at = {x, y, z} (it looks there)
  local function camera_spec(w, sec, c)
    local SWm = require("conjunction.scene_work")
    local px, py, pz, pitch, yaw, fov = c.x, c.y, c.z, c.pitch, c.yaw, c.fov
    if c.take then
      local cp, cr = w3.camera.pos(), w3.camera.rot()
      px, py, pz, pitch, yaw = cp.X, cp.Y, cp.Z, cr.Pitch or 0, cr.Yaw or 0
      fov = fov or (w3.camera.fov and tonumber(w3.camera.fov())) or 35
    end
    if c.look_at then
      local t = c.look_at
      local dx, dy, dz = (t.x or t[1]) - px, (t.y or t[2]) - py, (t.z or t[3]) - pz
      yaw = math.deg(math.atan(-dx, dy))
      pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))   -- (as scene_file's look: down is negative)
      c.focus = c.focus or math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    if not (px and py and pz) then error("a camera needs take = true, or x, y, z (with pitch and yaw or look_at)", 0) end
    if c.scene then                             -- (already in the scene's space: where the scene plays does not matter)
      return {pos = {px, py, pz}, pitch = pitch or 0, yaw = yaw or 0, fov = fov or 35, focus = c.focus}
    end
    local pos, ry = w:to_spot(sec, {px, py, pz}, yaw or 0)
    if not pos then error(tostring(ry), 0) end
    return {pos = pos, pitch = pitch or 0, yaw = ry, fov = fov or 35, focus = c.focus}
  end

  DOC.scene_end_blend = "The end into the game, as the game's scenes end: at second `at` (default half a second " ..
                        "before the section's end) the picture blends from the shot to the game's camera and the " ..
                        "people are the game's again. camera: the shot's (as scene_camera_cut); left out, the camera " ..
                        "of one's own that is on then. people: who goes back (default the section's) -> {id}"
  function C.scene_end_blend(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local tl = w.s:timeline(sec)
    local at = a.at or math.max(0.0, (tl.length or 0) - 0.5)
    local cam = a.camera and camera_spec(w, sec, a.camera) or nil
    local people = a.people
    if type(people) ~= "table" or #people == 0 then    -- (who acts in the section: its events name them)
      people = {}
      local seen = {}
      for _, ev in ipairs(w.s:obj(sec).events or {}) do
        for _, pr in ipairs(ev.props or {}) do
          if (pr.name == "actor" or pr.name == "actorName") and not seen[tostring(pr.value)] then
            seen[tostring(pr.value)] = true
            people[#people + 1] = tostring(pr.value)
          end
        end
      end
    end
    local id
    local ok, err = w:edit(function(s) id = s:add_end_blend(sec, at, cam, people) end)
    done(b, ok, err)
    return {id = id, at = at, people = people}
  end

  -- people walk (01.11., MaximdeWinter: "Geralt und Ciri, die eine Straße entlanglaufen"): a walk cycle on the spot and the
  -- placement carried along evenly at the cycle's own speed (measured on the feet), so no foot slides
  DOC.scene_walk = "A person walks from `from` to `to` ({x, y} in the scene's space, scene_places; world = true: " ..
                   "points of the world) from second `at`: seconds (else as long as the walk cycle's own speed " ..
                   "takes), anim (default locomotion_walk_cycle_slow_forward) -> {id, seconds, speed, turn}"
  function C.scene_walk(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local actor = a.actor or "GERALT"
    local function pt(p)
      local x, y, z = p.x or p[1], p.y or p[2], p.z or p[3]
      if a.world then
        local pos, err = w:to_spot(sec, {x, y, z or 0})
        if not pos then error(tostring(err), 0) end
        return {pos[1], pos[2], z and pos[3] or 0}
      end
      return {x, y, z or 0}
    end
    if not (a.from and a.to) then error("a walk needs from and to", 0) end
    local r, err = w:walk(sec, actor, a.at or b.playhead or 0, pt(a.from), pt(a.to),
                          {seconds = a.seconds, anim = a.anim, carried = a.carried, from_here = a.from_here})
    if not r then error(tostring(err), 0) end
    done(b, true)
    return r
  end

  DOC.scene_act = "Acting as the game's scenes have it, at second `at`: what = look (actor looks at target until the " ..
                  "next look; seconds: for that long, the body turned too - so a walking face turns), mood (actor's face: Neutral, Happy, Determined, Confident, Sad, Sceptic ...; weight), " ..
                  "face (an accent: anim such as nod_head_accent_face, head_down_head_accent_face, " ..
                  "constant_brows_up_accent_face; seconds, weight, filter), shake (the camera as held by hand from " ..
                  "here: anim, default medium_shake), pose (actor's stance from here: status High / Low, mood " ..
                  "Determined, Aggressive ..., pose Standing, Kneeling, Sitting ...; transition: the game's animation " ..
                  "into it, e.g. high_standing_determined_to_high_kneeling_determined), light (the camera's two " ..
                  "lights on the faces from here: key and fill = {x, y, z offset, brightness, radius}; the game's " ..
                  "key {0, 1-2, 0} radius 0.25, fill brightness 0.3-0.5), equip (an item of actor's own into " ..
                  "the hand: right / left = steelsword, silversword ...; \"\" puts it away), scabbard (actor's " ..
                  "scabbard hidden), prop_hand (a prop of the scene in actor's hand: prop its id, template its " ..
                  ".w2ent the first time, slot r_weapon / l_weapon, offset; attach = false: out of the hand again, show = false: hidden), prop_place (the prop put at place = " ..
                  "{x, y, z, yaw} of the scene), visible (actor seen from here or, show = false, not), lamp (a light of the scene's own " ..
                  "from here: light its id, kind point / spot, place {x, y, z}, color {r, g, b}, brightness (the " ..
                  "game's 20-100), radius m, flicker 0-1; off = true: out), posekey (actor's bones turned on " ..
                  "top for seconds, blend_in, blend_out: bones = {{bone, roll, pitch, yaw}}), door (a door of the " ..
                  "world by its tag: door, open = false closes it, instant, flip), place (actor put at x, y, z, " ..
                  "turn of the scene at that second: a walk's joint), clear (all of one's own " ..
                  "acting of the section goes) -> {id}"
  function C.scene_act(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local id
    local ok, err = w:edit(function(s)
      if a.what == "posekey" then                      -- (the bones' numbers in the person's own skeleton)
        local fig = w:figure_of(a.actor or "GERALT")
        for _, bn in ipairs(a.bones or {}) do
          local okb, k = pcall(function() return fig and fig:GetBoneIndex(bn.bone or bn[1]) end)
          bn.index = okb and k or -1
        end
      end
      if a.what == "pose" and a.transition and not a.seconds then
        a.seconds = require("conjunction.scene_work").animation_length(w.depot, a.transition) or 1.0
      end
      if a.what == "clear" then s:clear_acting(sec) else id = s:add_acting(sec, a.what, a.at or b.playhead or 0, a) end
    end)
    done(b, ok, err)
    return {id = id}
  end

  DOC.scene_camera_cut = "A cut to a camera at second `at` (it lasts until the next camera): camera = take = true, or " ..
                         "x, y, z with pitch and yaw or with look_at = {x, y, z}; fov; scene = true: x, y, z (and " ..
                         "look_at) are in the scene's space (scene_places), not the world's; clear = {from, to}: the " ..
                         "cameras of one's own between those seconds go first -> {id}"

  -- where the people stand in the scene's own space in the moment at second `at`: the moment's places, else their slot
  DOC.scene_places = "Where the people stand in the scene's own space (metres from its spot) in the moment at second " ..
                     "`at`: {actor = {x, y, z, turn}} - with scene_people (the world) it gives how the scene lies there"
  function C.scene_places(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local el = moment_at(b, w, sec, a.at or 0)
    local out = {}
    local set = w.s:set_of(sec)
    local ds = set and w.s:obj(w.s:_dialogset(set) or 0)
    for _, n in ipairs(ds and ds:get("slots") or {}) do
      local so = w.s:obj(n)
      local tf = so and so:get("slotPlacement")
      if so and tf then
        local p, r = tf.position or {}, tf.rotation or {}
        out[tostring(so:get("actorName"))] = {x = p[1] or 0, y = p[2] or 0, z = p[3] or 0, turn = r[3] or 0}
      end
    end
    -- (every placement up to that second holds until another; a walk's between its two ends)
    for actor, pl in pairs(w.s:placements_at(sec, a.at or 0)) do out[actor] = pl end
    return out
  end
  function C.scene_camera_cut(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local cam = camera_spec(w, sec, a.camera or {take = true})
    local id
    local ok, err = w:edit(function(s)
      w:_custom_first(s)
      if a.clear then s:clear_cameras(sec, a.clear.from or a.clear[1], a.clear.to or a.clear[2]) end
      id = s:add_camera_cut(sec, a.at or b.playhead or 0, cam)
    end)
    done(b, ok, err)
    b.tl_pick = id
    return {id = id}
  end

  DOC.scene_cameras_clear = "The cameras of one's own of a section between second `from` and `to` go (moments' cameras, " ..
                            "cuts, moves)"
  function C.scene_cameras_clear(a)
    local b, w = opened()
    local sec = section(b, a.section)
    done(b, w:edit(function(s) s:clear_cameras(sec, a.from, a.to) end))
    return {cleared = true}
  end

  DOC.scene_camera_move = "A camera move from second `at` to `to`: from camera `a` to camera `b` - each take = true (the " ..
                          "game's camera now), or x, y, z with pitch and yaw or with look_at = {x, y, z} (the focus on " ..
                          "it); fov; ease (smooth, the default; linear: evenly, as a camera beside walking people; a number: the game's easing " ..
                          "parameter, 0 even, larger softer) -> {id}"
  function C.scene_camera_move(a)
    local b, w = opened()
    local sec = section(b, a.section)
    if not (a.a and a.b) then error("two cameras a and b are needed", 0) end
    local ca, cb = camera_spec(w, sec, a.a), camera_spec(w, sec, a.b)
    local id
    local ease = tonumber(a.ease) or a.ease
    local ok, err = w:edit(function(s)
      w:_custom_first(s)
      id = s:add_camera_move(sec, a.at or b.playhead or 0, a.to, ca, cb, ease)
    end)
    done(b, ok, err)
    if not id then error("a camera move needs at least 0.1 s (at < to)", 0) end
    b.tl_pick = id
    return {id = id}
  end

  DOC.scene_place = "Where a person stands in the moment at second `at`: actor and x, y, turn (from the spot), or " ..
                    "world = {x, y, z} (a point of the world), or turn_by degrees; status, mood, pose, face_pose, face_weight: " ..
                    "the stance their slot gives them (as the game's dialogsets: Sitting, Sitting Ground ...); " ..
                    "keep_view: the camera as it is now stays (moved in the " ..
                    "picture)"
  function C.scene_place(a)
    local b, w = opened()
    local sec = section(b, a.section)
    if a.status or a.mood or a.pose or a.face_pose then  -- (the stance their slot gives them, as the game's dialogsets)
      local okk, errk = w:edit(function(s)
        if not s:set_slot_stance(sec, a.actor, a) then error(tostring(a.actor) .. " has no place in this section", 0) end
      end)
      if okk == false then error(tostring(errk), 0) end
      sec = section(b, a.section)
      if not (a.x or a.y or a.world or a.turn or a.turn_by) then return {stance = true} end
    end
    local el = moment_at(b, w, sec, a.at)
    if a.keep_view and (a.world or a.turn_by) then  -- (moved in the picture: the picture stays, the camera is frozen)
      local m = w.s:moment(sec, el)
      if not (m.camera and m.camera.view == require("conjunction.scene_file").OWN_VIEW) then
        local okv, errv = w:take_view(sec, el)
        if okv == false then error(tostring(errv), 0) end
        sec = section(b, a.section)
        el = moment_at(b, w, sec, a.at)
      end
    end
    if a.world and a.yaw then                       -- (a point of the world and a heading of the world: anim_fit's)
      local p = a.world
      local pos, turn = w:to_spot(sec, {p.x or p[1], p.y or p[2], p.z or p[3]}, a.yaw)
      if not pos then error(tostring(turn), 0) end
      done(b, w:set_moment_place(sec, el, a.actor, {pos[1], pos[2], turn % 360, pos[3]}))
    elseif a.world then
      local p = a.world
      done(b, w:put_at(sec, el, a.actor, {p.x or p[1], p.y or p[2], p.z or p[3]}))
    elseif a.turn_by then
      local pl = w.s:moment(sec, el).places[a.actor] or {0, 0, 0}
      done(b, w:set_moment_place(sec, el, a.actor, {pl[1] or 0, pl[2] or 0, ((pl[3] or 0) + a.turn_by) % 360, pl[4]}))
    else done(b, w:set_moment_place(sec, el, a.actor, {a.x or 0, a.y or 0, a.turn or 0})) end
    local pl = w.s:moment(sec, el).places[a.actor] or {}
    return {x = pl[1], y = pl[2], turn = pl[3]}
  end

  DOC.scene_people = "The open scene's people in the world now: {actor, world = {x, y, z}, yaw, head, pelvis, torso3 " ..
                     "(where the pose has them, once watched: ask twice)}"
  function C.scene_people()
    local _, w = opened()
    local out = {}
    for _, a in ipairs(w.s:actors()) do
      local e = w:figure_of(a.id)
      if e then
        local ok, p, r = pcall(function() return e:GetWorldPosition(), e:GetWorldRotation() end)
        if ok and p then
          local one = {actor = a.id, world = {p.X, p.Y, p.Z}, yaw = r and r.Yaw or 0}
          -- the bones where the game has them now (its own bone matrices: w3.pose gave the player's skeleton lying,
          -- the head 0.6 m high, while he stood - 02.11.)
          for _, bn in ipairs({"head", "pelvis", "torso3"}) do
            local okb, m = pcall(function()
              local i = e:GetBoneIndex(bn)
              return i and i >= 0 and e:GetBoneWorldMatrixByIndex(i)
            end)
            if okb and m and m.W then one[bn] = {m.W.X, m.W.Y, m.W.Z} end
          end
          local okp, pose = false, nil
          if not one.head then okp, pose = pcall(w3.pose, e) end   -- (nil the first time: watched from then on)
          if okp and pose and pose.bones then
            local ang = math.rad(r and r.Yaw or 0)
            local c, s = math.cos(ang), math.sin(ang)
            for _, bn in ipairs(pose.bones) do
              if bn.name == "head" or bn.name == "pelvis" or bn.name == "torso3" then
                one[bn.name] = {p.X + bn.x * c - bn.y * s, p.Y + bn.x * s + bn.y * c, p.Z + bn.z}
              end
            end
          end
          out[#out + 1] = one
        end
      end
    end
    return out
  end

  DOC.scene_people_at = "Where the people are drawn now (the preview's picture): {actor, x, y (their feet), head_x, " ..
                        "head_y - screen pixels of the game's client area; world, yaw}"
  function C.scene_people_at()
    local _, w = opened()
    return w:people_on_screen()
  end

  DOC.scene_point_at = "The point of the world under pixel x, y of the game's client area (a ray from the camera) -> " ..
                       "{x, y, z}; section: its spot's height where the ray hits nothing"
  function C.scene_point_at(a)
    local b, w = opened()
    local gz
    local sec = a.section and w:section_named(a.section) or (b.cut and b:cut_section())
    if sec then
      local set = w.s:set_of(sec)
      local ds = set and w.s:obj(w.s:_dialogset(set) or 0)
      local base = require("conjunction.scene_work").spot_world(ds and (ds:get("placementTag") or {})[1] or "PLAYER")
      gz = base and base[3]
    end
    local p, err = require("conjunction.scene_work").point_at(a.x, a.y, gz)
    if not p then error(tostring(err), 0) end
    return {x = p[1], y = p[2], z = p[3]}
  end

  DOC.scene_spot = "The tag the cutscene plays at (\"PLAYER\": where the player stands): section, tag; snap = " ..
                   "true / false: the people put onto the ground under them or not"
  function C.scene_spot(a)
    local b, w = opened()
    local sec = section(b, a.section)
    local set = w.s:set_of(sec)
    if a.tag then done(b, w:set_place_tag(set, a.tag)) end
    if a.snap ~= nil then                       -- (the people put onto the ground under them, as the game's dialogsets
      done(b, w:edit(function(s)                -- leave it on by default; off for a boat's deck)
        local n = s:_dialogset(set)
        if n then s:obj(n):set("snapToTerrain", a.snap and true or false, "Bool") end
      end))
    end
    return {tag = a.tag, snap = a.snap}
  end

  DOC.scene_seek = "The live preview at second `at` of the section (paused unless paused = false) -> {playhead, " ..
                   "ready (false: the changed scene is still starting, it starts at that second)}"
  function C.scene_seek(a)
    local b = opened()
    local sec = section(b, a.section)
    if a.paused == false then
      b.playhead = a.at or 0
      b:preview_at(sec, b.playhead, false)
    else
      b:seek(sec, a.at or 0)
    end
    local pv = b.preview
    return {playhead = b.playhead, ready = not b.restart_at and not (pv and pv.o and not pv.o.started)}
  end

  DOC.scene_play = "Play or pause the section in the preview, from the playhead"
  function C.scene_play(a)
    local b = opened()
    b:play_pause(section(b, a.section))
    local pv = b.preview
    return {playing = pv ~= nil and not pv.paused}
  end

  -- measuring what a section does (02.11., MaximdeWinter: every building block measured): it plays once from its start and
  -- each tick every person's body and face are written down - feet, pelvis and head in the world (w3.pose: its bones
  -- still carry the cycle's Trajectory, taken off: else a walk counted twice), the mouth's opening and where the face
  -- looks (the face skeleton). conjunction/agent.py's scene_measure reads it into numbers.
  local watch
  DOC.scene_watch = "The section plays once from its start; each tick every person's feet, pelvis, head, mouth " ..
                    "opening and face direction go into the file `file` (scene_watch_result: done)"
  function C.scene_watch(a)
    local b, w = opened()
    local sec = section(b, a.section)
    -- (02.11.: a watch whose module was loaded anew kept running unseen, and w3.scene.time costs ~30 ms a call
    -- while no scene plays - the game fell to 26 frames a second. The handle lives in a global, so a reload ends it,
    -- and a watch ends by itself: at its section's end, or when the section never starts)
    if rawget(_G, "CJ_SCENE_WATCH_H") then pcall(w3.off_tick, rawget(_G, "CJ_SCENE_WATCH_H")) end
    if watch and watch.h then pcall(w3.off_tick, watch.h) end
    local people = {}
    local function resolve()                    -- (once the section runs: the figures the scene holds)
      for _, act in ipairs(w.s:actors()) do
        local e = w:figure_of(act.id)
        if e then people[#people + 1] = {id = act.id, e = e} pcall(w3.pose, e) pcall(w3.pose, e, "mimic") end
      end
    end
    watch = {name = w.s:name_of(sec), file = a.file, rows = {}, seen = false, t0 = os.clock(),
             wait = tonumber(a.wait) or 60}
    local BODY = {l_foot = true, r_foot = true, pelvis = true, head = true}
    local FACE = {upper_lip = true, lowwer_lip = true, head = true, nose = true}
    local function world(m, x, y, z)
      return x * m[1] + y * m[5] + z * m[9] + m[13], x * m[2] + y * m[6] + z * m[10] + m[14],
             x * m[3] + y * m[7] + z * m[11] + m[15]
    end
    local me = watch
    local function finish(why)
      me.done, me.failed = true, why
      if me.h then pcall(w3.off_tick, me.h) end
      if rawget(_G, "CJ_SCENE_WATCH_H") == me.h then rawset(_G, "CJ_SCENE_WATCH_H", nil) end
      me.h = nil
    end
    watch.h = w3.on_tick(function()
      if me ~= watch then return finish("replaced") end
      local t = require("conjunction.scene_work").scene_time()
      if not (t and t.section == watch.name) then
        if watch.seen then return finish(nil) end
        if os.clock() - watch.t0 > watch.wait then return finish("the section did not start") end
        return
      end
      watch.seen, watch.length = true, t.length
      if not watch.resolved then
        watch.resolved = true
        resolve()
      end
      local row = {string.format("%.3f", t.t)}
      for _, pp in ipairs(people) do
        local okp, p = pcall(w3.pose, pp.e)
        -- (the bones where they are drawn: the pose as it is, its Trajectory not taken off - 02.11.: taken off, a walk
        -- whose pose kept the way measured clean while he slid ahead and jumped back each cycle; a walk that is right
        -- has it at 0, and the pose's way of its own goes into Who.traj)
        if okp and p and p.bones then
          local m = p.modelToWorld
          for _, bn in ipairs(p.bones) do
            if BODY[bn.name] then
              row[#row + 1] = string.format("%s.%s=%.3f,%.3f,%.3f", pp.id:gsub(" ", "_"), bn.name,
                                            world(m, bn.x, bn.y, bn.z))
            elseif bn.name == "Trajectory" then
              row[#row + 1] = string.format("%s.traj=%.3f", pp.id:gsub(" ", "_"), math.sqrt(bn.x ^ 2 + bn.y ^ 2))
            end
          end
        end
        -- (where the head points: the body's head bone, its X axis - the face skeleton of the player did not show
        -- his head turning, 02.11.)
        local okh, hm = pcall(function() return pp.e:GetBoneWorldMatrixByIndex(pp.e:GetBoneIndex("head")) end)
        if okh and hm and hm.X then
          row[#row + 1] = string.format("%s.headx=%.3f,%.3f", pp.id:gsub(" ", "_"), hm.X.X, hm.X.Y)
          -- (where the head is in the picture: 0..1 across and down, nothing behind the camera)
          local u, v = require("conjunction.scene_work").ratio(hm.W)
          row[#row + 1] = string.format("%s.view=%.3f,%.3f", pp.id:gsub(" ", "_"), u or -9, v or -9)
        end
        local okf, f = pcall(w3.pose, pp.e, "mimic")
        if okf and f and f.bones then
          local got = {}
          for _, bn in ipairs(f.bones) do if FACE[bn.name] then got[bn.name] = bn end end
          local ul, ll, hd, ns = got.upper_lip, got.lowwer_lip, got.head, got.nose
          if ul and ll then
            row[#row + 1] = string.format("%s.mouth=%.4f", pp.id:gsub(" ", "_"),
              math.sqrt((ul.x - ll.x) ^ 2 + (ul.y - ll.y) ^ 2 + (ul.z - ll.z) ^ 2))
          end
          if hd and ns and f.modelToWorld then
            local m = f.modelToWorld
            local hx, hy = world(m, hd.x, hd.y, hd.z)
            local nx, ny = world(m, ns.x, ns.y, ns.z)
            row[#row + 1] = string.format("%s.face=%.3f,%.3f", pp.id:gsub(" ", "_"), nx - hx, ny - hy)
          end
        end
      end
      watch.rows[#watch.rows + 1] = table.concat(row, " ")
    end)
    rawset(_G, "CJ_SCENE_WATCH_H", watch.h)
    b.playhead = 0
    b:preview_at(sec, 0, false)
    return {watching = #w.s:actors()}
  end

  DOC.scene_watch_result = "Whether scene_watch is through: done, frames, length (the section's in the game); done " ..
                           "writes the file; failed: why it ended without the section played (it did not start " ..
                           "within `wait` seconds of scene_watch, default 60)"
  function C.scene_watch_result()
    if not watch then error("no scene_watch asked", 0) end
    if not watch.done then return {done = false, frames = #watch.rows} end
    if watch.h then pcall(w3.off_tick, watch.h) watch.h = nil end
    if watch.failed then return {done = true, failed = watch.failed, frames = #watch.rows} end
    if watch.file and not watch.written then
      assert(w3.fs.write(watch.file, table.concat(watch.rows, ";")))
      watch.written = true
    end
    return {done = true, frames = #watch.rows, length = watch.length, file = watch.file}
  end

  DOC.scene_now = "Where the preview stands: playing, section, at (its second), length; ready (false: a play asked " ..
                  "for has not started yet - what plays is still the one before)"
  function C.scene_now()
    local okb, b = pcall(body)
    local pv = okb and b and b.preview
    local ready = not (okb and b and b.restart_at) and not (pv and pv.o and not pv.o.started)
    local t = require("conjunction.scene_work").scene_time()
    return t and {playing = true, section = t.section, at = t.t, length = t.length, ready = ready} or
           {playing = false, ready = ready}
  end

  DOC.scene_stop = "Every scene playing ends (and the black a scene that never started left on the screen goes)"
  function C.scene_stop()
    require("conjunction.scene_work").cancel()
    require("conjunction.scene_work").stop()
    local b = body()
    b.preview, b.restart_at = nil, nil
    -- 02.11.: a scene stopped while it still loaded left the screen black for good (the game paused without its
    -- window in front, the fade never went on); at once, since a fade does not run while the game is paused
    local SWm = require("conjunction.scene_work")
    SWm.after_play = {at = os.clock() - 60, seen = true}       -- (and once it is over: the screen back, scene_work)
    return {stopped = true, unblacked = SWm.unblack() or nil}
  end

  DOC.scene_peek = "Show an animation on the person's figure, again and again (anim = nil stops it): actor, anim"
  function C.scene_peek(a)
    local b = opened()
    if not a.anim then b:peek_stop() return {peek = false} end
    b:peek(a.actor, a.anim)
    return {peek = true}
  end

  DOC.scene_undo = "Undo the last change (redo = true: redo it; revert = true: the game's scene again)"
  function C.scene_undo(a)
    local b, w = opened()
    if a.revert then b:after(w:revert())
    elseif a.redo then b:after(w:redo())
    else b:after(w:undo()) end
    return {changed = w:changed()}
  end

  DOC.scene_state = "The workshop now: scene, changed, the editor's section, playhead, preview, the clip picked, the last error"
  function C.scene_state()
    local b = body()
    local w = b.w
    local pv = b.preview
    local tm
    if w3.scene and w3.scene.time then
      local ok, t = pcall(require("conjunction.scene_work").scene_time)
      tm = ok and t or nil
    end
    return {path = w and w.path, changed = w and w:changed(), editor = b.cut == true, section = b.cut_name,
            playhead = b.playhead, preview = pv and {section = pv.name, paused = pv.paused} or nil,
            scene_time = tm, pick = b.tl_pick, error = b.err}
  end

  require("conjunction.agent_scene_rows").register(C, DOC, body)   -- (the rows and their card: scene_row, scene_line_* ...)
  require("conjunction.world_sense").register(C, DOC, body)        -- (the world's shape: world_probe, world_person ...)

  -- a talk of the project's own quest (opened with layer = true) keeps only its staging: what changes the scene's
  -- build (lines, answers, its length, its sections) would be gone at the next build - said, not done
  local STRUCTURE = {"scene_cutscene", "scene_say_add", "scene_say_set", "scene_say_remove", "scene_length",
                     "scene_split", "scene_spot", "scene_line_set", "scene_line_add", "scene_row_move",
                     "scene_row_remove", "scene_pause_set", "scene_answer_set", "scene_answer_add", "scene_if_set",
                     "scene_event_set", "scene_event_remove", "scene_own_set", "scene_replace_built"}
  AS.STAGING_ONLY = "In a talk of your quest only its staging is kept (animations, cameras, places, effects, " ..
                    "sounds): change its lines, answers and length in the talk's dialogue"
  for _, name in ipairs(STRUCTURE) do
    local orig = C[name]
    C[name] = function(a)
      local b = body()
      if b.w and b.w.layer_name then error(AS.STAGING_ONLY, 0) end
      return orig(a)
    end
  end
end

return AS
