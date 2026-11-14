-- The timeline of a section (the scene workshop's video-editor view): its elements laid end to end and every event
-- of the director on them at its second, gathered into tracks - a person's animations, face, look-ats and places,
-- the camera, the effects. A clip is one event, or the events of one clip of one's own ("cj clip <n>": an animation
-- played again until the clip ends, each piece one event). Times here are seconds of the section; the file keeps a
-- start as a share of its element (0..1) and a length in seconds.
--   s:timeline(sec)                      -> {length, elements = {{n, start, len}}, tracks = {{id, kind, actor, clips}}}
--     a clip: {id, kind, track, cls, own, ks (its events), start, dur, anim, piece, front, stretch, speed, blend_in,
--              blend_out, seams (seconds where a piece starts again), label}
--   s:move_clip(sec, id, t)              s:resize_clip(sec, id, from, to, len)      s:set_clip_speed(sec, id, x, len)
--   (x: 2 plays it twice as fast; the file's stretch is 1 / x)
--   s:add_clip(sec, actor, anim, len, t, dur) -> id      s:remove_clip(sec, id)      s:set_length(sec, secs)
--   s:set_clip_blend(sec, id, blend_in, blend_out)      s:set_clip_anim(sec, id, anim, len)
--   s:element_at(sec, t) -> element      s:split_at(sec, t) -> the new moment (a pause split at second t)
-- `len` is the animation's own length (seconds), needed to play it again; nil: as the clip has it.
local TR = require("conjunction.cr2w_tree")
local SF = require("conjunction.scene_file")
local S = SF.S
local TL = {}

TL.CLIP = SF.OWN_EVENT .. "clip "
TL.ANIM = {CStorySceneEventAnimation = true, CStorySceneEventAdditiveAnimation = true}
TL.ORDER = {camera = 1, world = 1.5, anim = 2, layer = 3, acting = 4, face = 4, look = 5, place = 6, effects = 7,
            sound = 8}

-- what an event is on the timeline: its kind and its person (nil for the camera and the effects)
function TL.kind_of(ev)
  local c = ev.cls
  -- (a thing of the world the scene switches: its own track - S:add_world_action)
  if tostring(TR.sget(ev.props, "eventName", "")):sub(1, #SF.OWN_EVENT + 4) == SF.OWN_EVENT .. "act " then return "world", nil end
  local actor = TR.sget(ev.props, "actor") or TR.sget(ev.props, "actorName")
  if c == "CStorySceneEventAdditiveAnimation" then return "layer", actor end   -- (on top of the animation)
  if TL.ANIM[c] or c == "CStorySceneEventChangePose" then return "anim", actor end
  -- (a person's acting - face, looks, the hand - on one track of theirs)
  if c:find("Mimic", 1, true) or c:find("LookAt", 1, true) or c == "CStorySceneEventEquipItem" or
     c == "CStorySceneEventHideScabbard" then return "acting", actor end
  if c == "CStorySceneEventOverridePlacement" then return "place", actor end
  if c:find("Camera", 1, true) then return "camera", nil end
  if c == "CStorySceneEventSound" then return "sound", nil end           -- (its person: in its label)
  return "effects", nil
end

local function sset(props, name, typ, value)
  for _, p in ipairs(props) do
    if p.name == name then p.value = value return end
  end
  props[#props + 1] = TR.Prop(name, typ, value)
end

local function sdel(props, name)
  for k, p in ipairs(props) do
    if p.name == name then table.remove(props, k) return end
  end
end

-- the section's elements end to end {n, start, len}, its length
function S:_laid(sec)
  local out, at = {}, 0.0
  for _, n in ipairs(self:obj(sec):get("sceneElements") or {}) do
    local len = self:length_of(n)
    out[#out + 1] = {n = n, start = at, len = len}
    at = at + len
  end
  return out, at
end

local function own_second(ev, laid)
  local el = TR.sget(ev.props, "sceneElement", 0)
  for _, e in ipairs(laid) do
    if e.n == el then return e.start + TR.sget(ev.props, "startPosition", 0.0) * e.len end
  end
  return 0.0
end

-- every event's second (an event linked to a parent: the parent's second and its offset)
local function seconds_of(events, laid)
  local by, out = {}, {}
  for k, ev in ipairs(events) do
    local g = TR.sget(ev.props, "GUID")
    if g then by[g.b] = k end
  end
  local function at(k, depth)
    if out[k] then return out[k] end
    local ev = events[k]
    local lp = TR.sget(ev.props, "linkParentGUID")
    local pk = lp and by[lp.b]
    local t
    if pk and pk ~= k and depth < 16 then
      t = at(pk, depth + 1) + (TR.sget(ev.props, "linkParentTimeOffset", 0.0) or 0.0)
    else
      t = own_second(ev, laid)
    end
    out[k] = t
    return t
  end
  for k in ipairs(events) do at(k, 0) end
  return out
end

-- event ev starts at second t of the section: the element t falls in, the share of it (a link to a parent event
-- goes: the second is its own now)
local function put_at(ev, t, laid, length)
  t = math.max(0.0, math.min(t, length))
  local pick
  for _, e in ipairs(laid) do
    if e.len > 0 and e.start <= t + 1e-6 then pick = e end
  end
  pick = pick or laid[1]
  if not pick then return end
  sset(ev.props, "sceneElement", "ptr:CStorySceneElement", pick.n)
  sset(ev.props, "startPosition", "Float", pick.len > 0 and math.min(1.0, (t - pick.start) / pick.len) or 0.0)
  sdel(ev.props, "linkParentGUID")
  sdel(ev.props, "linkParentTimeOffset")
end

-- the clips' key: an own clip's events share a name; an own moment's animation ("cj anim X") is one clip per
-- element; any other event is a clip of its own
local function key_of(ev, k)
  local name = tostring(TR.sget(ev.props, "eventName", ""))
  if name:sub(1, #TL.CLIP) == TL.CLIP then return name end
  if name:sub(1, #SF.OWN_EVENT + 5) == SF.OWN_EVENT .. "anim " then
    return name .. "@" .. tostring(TR.sget(ev.props, "sceneElement", 0))
  end
  local g = TR.sget(ev.props, "GUID")                  -- (its GUID as hex: an id an agent can send as text)
  return "#" .. (g and (g.b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) or tostring(k))
end

local function short(anim)
  return (tostring(anim or ""):gsub("^cj_b_b_", ""):gsub("_edited", ""):gsub("_", " "))
end

-- a camera's name as one reads it: a talk's shots (dialogue_scene.shot_camera: cj_<1_2: on the player | 2_1: on the
-- other>_<size>_<ext|int>...), its defaults, one's own; else the name (07.11.: every clip read "CustomCameraInstance")
TL.SIZES = {wide = "Wide", medium = "Medium", semicloseup = "Semi close-up", semi_closeup = "Semi close-up",
            closeup = "Close-up", extremecloseup = "Extreme close-up", extreme_closeup = "Extreme close-up"}
function TL.camera_label(name)
  name = tostring(name or "")
  if name == "" then return "Camera" end
  local side, size = name:match("^cj_(%d_%d)_(.-)_[ei][xn]t")
  if side then
    return (TL.SIZES[size] or size:gsub("_", " ")) .. (side == "1_2" and ": player" or ": other")
  end
  if name == "player_cam" then return "Default: player" end
  if name == "npc_cam" then return "Default: other" end
  if name:match("^own_") then return "Camera " .. name:sub(5):gsub("_", " ") end
  return (name:gsub("^cj_", ""):gsub("_", " "))
end

function S:timeline(sec)
  local laid, length = self:_laid(sec)
  local clips, order = {}, {}
  local events = self:obj(sec).events or {}
  local secs = seconds_of(events, laid)
  for k, ev in ipairs(events) do
    local key = key_of(ev, k)
    local c = clips[key]
    local t = secs[k]
    local d = TR.sget(ev.props, "duration", 0.0) or 0.0
    if not c then
      local kind, actor = TL.kind_of(ev)
      local name = tostring(TR.sget(ev.props, "eventName", ""))
      c = {id = key, kind = kind, actor = actor, cls = ev.cls, own = name:sub(1, #SF.OWN_EVENT) == SF.OWN_EVENT, name = name,
           ks = {}, start = t, stop = t + d, anim = TR.sget(ev.props, "animationName"),
           front = TR.sget(ev.props, "clipFront", 0.0), stretch = TR.sget(ev.props, "stretch", 1.0),
           blend_in = TR.sget(ev.props, "blendIn"), blend_out = TR.sget(ev.props, "blendOut"), seams = {}}
      c.piece = (TR.sget(ev.props, "clipEnd", d) - c.front) * c.stretch      -- (stretch: seconds per second of it)
      c.speed = 1.0 / math.max(c.stretch, 0.01)
      clips[key] = c
      order[#order + 1] = c
    end
    c.ks[#c.ks + 1] = k
    if t < c.start then c.start = t end
    if t + d > c.stop then c.stop = t + d end
    if #c.ks > 1 then c.seams[#c.seams + 1] = t end
  end
  -- a camera lasts until the next camera
  local cams = {}
  for _, c in ipairs(order) do if c.kind == "camera" and c.stop - c.start < 1e-6 then cams[#cams + 1] = c end end
  table.sort(cams, function(a, b) return a.start < b.start end)
  for i, c in ipairs(cams) do c.stop = cams[i + 1] and cams[i + 1].start or length end
  -- (a look, a sword drawn, a thing of the world switched: a moment without length - shown 0.8 s wide, to be seen
  -- and picked)
  for _, c in ipairs(order) do
    if (c.kind == "acting" or c.kind == "world") and c.stop - c.start < 1e-6 then c.stop = math.min(length, c.start + 0.8) end
  end
  local tracks, by = {}, {}
  for _, c in ipairs(order) do
    c.dur = math.max(0.0, c.stop - c.start)
    local seams = {}
    for _, t in ipairs(c.seams) do if t > c.start + 1e-4 then seams[#seams + 1] = t end end
    table.sort(seams)
    c.seams = seams
    c.label = c.anim and short(c.anim) or (tostring(c.cls):gsub("^CStoryScene", ""):gsub("^Event", ""))
    -- (where a walk ends or Put here puts them: 11.11., the card read "OverridePlacement")
    if c.cls == "CStorySceneEventOverridePlacement" then c.label = "Stands here" end
    local ev1 = events[c.ks[1]]
    if c.kind == "camera" and TR.sget(ev1.props, "customCameraName") then
      c.label = TL.camera_label(TR.sget(ev1.props, "customCameraName"))
    end
    if c.kind == "camera" and #c.ks >= 3 and c.own then
      c.label, c.move = "camera move", true
    elseif c.cls == "CStorySceneEventFade" then
      c.label = TR.sget(ev1.props, "in", false) and "Fade in" or "Fade out"
      c.fade_in = TR.sget(ev1.props, "in", false) and true or false
    elseif c.cls == "CStorySceneEventSound" then
      c.event = tostring(TR.sget(ev1.props, "soundEventName", ""))
      c.who = TR.sget(ev1.props, "actor")
      c.volume = TR.sget(ev1.props, "dbVolume")
      c.label = c.event .. (c.who and ("  (" .. tostring(c.who) .. ")") or "")
    elseif c.cls == "CStorySceneActorEffectEvent" then
      c.effect = tostring(TR.sget(ev1.props, "effectName", ""))
      c.who = TR.sget(ev1.props, "actor")
      c.stops = TR.sget(ev1.props, "startOrStop", true) == false
      c.label = tostring(c.who or "?") .. ": " .. c.effect .. (c.stops and "  (stop)" or "")
    end
    if c.kind == "camera" and c.name:sub(1, #SF.OWN_EVENT + 7) == SF.OWN_EVENT .. "camera " then
      local what = c.name:sub(#SF.OWN_EVENT + 8)
      c.label = what == SF.OWN_VIEW .. "|view" and "your view" or what:gsub("|", "  ")
    end
    if c.cls == "CStorySceneEventMimics" then
      c.label = "Mood: " .. tostring(TR.sget(ev1.props, "mimicsEmotionalState", ""))
    elseif c.cls == "CStorySceneEventMimicsAnim" then
      c.label = "Face: " .. tostring(TR.sget(ev1.props, "animationName", "")):gsub("_", " ")
    elseif c.cls:find("LookAt", 1, true) then
      c.label = "Looks at: " .. tostring(TR.sget(ev1.props, "target") or TR.sget(ev1.props, "bodyTarget") or "?")
    elseif c.cls == "CStorySceneEventEquipItem" then
      local r = tostring(TR.sget(ev1.props, "rightItem", ""))
      c.label = "In hand: " .. (r ~= "" and r or "empty")
    end
    if c.name:sub(1, #TL.WORLD_ACT) == TL.WORLD_ACT then     -- (a thing of the world: what, which, how)
      local what, wid, state = c.name:sub(#TL.WORLD_ACT + 1):match("^(%S+) (%S+) (%S+)")
      if what then
        c.label = (TL.WORLD_LABEL[what] or what) .. ": " .. wid:gsub("_", " ") .. "  " .. state:gsub(":", " ")
        if what == "weather" then c.label = "Weather: " .. TL.weather_name(state) end
        if what == "env" then
          local off, key = state:match("^(off:)(.*)$")
          c.label = (off and "Look off: " or "Look: ") .. TL.look_name(key or state)
        end
      end
    end
    local id = c.kind .. (c.actor and (":" .. c.actor) or "")
    c.track = id
    local tr = by[id]
    if not tr then
      tr = {id = id, kind = c.kind, actor = c.actor, clips = {}}
      by[id] = tr
      tracks[#tracks + 1] = tr
    end
    tr.clips[#tr.clips + 1] = c
  end
  for _, tr in ipairs(tracks) do table.sort(tr.clips, function(a, b) return a.start < b.start end) end
  table.sort(tracks, function(a, b)
    -- (the camera, then the things of the world, then each person's tracks, then the rest)
    local ta, tb = a.kind == "camera" or a.kind == "world", b.kind == "camera" or b.kind == "world"
    if ta ~= tb then return ta end
    if (a.actor or "") ~= (b.actor or "") and not ta and not tb then
      if not a.actor then return false end
      if not b.actor then return true end
      return a.actor < b.actor
    end
    if TL.ORDER[a.kind] ~= TL.ORDER[b.kind] then return TL.ORDER[a.kind] < TL.ORDER[b.kind] end
    return a.id < b.id
  end)
  return {length = length, elements = laid, tracks = tracks, clips = clips}
end

function S:_clip(sec, id)
  local tl = self:timeline(sec)
  return tl.clips[id], tl
end

-- an own clip's number for a new one
function S:_next_clip(sec)
  local top = 0
  for _, ev in ipairs(self:obj(sec).events or {}) do
    local name = tostring(TR.sget(ev.props, "eventName", ""))
    local n = tonumber(name:match("^" .. TL.CLIP:gsub("%p", "%%%0") .. "(%d+)$") or "")
    if n and n > top then top = n end
  end
  return TL.CLIP .. (top + 1)
end

-- clip c written anew from `start` to `stop`: an animation in pieces of its own length (the first from `front`),
-- each piece one event like c's first (its look-ats, weights, bones stay); any other event only moved
function S:_write_clip(sec, c, start, stop, o)
  o = o or {}
  local so = self:obj(sec)
  local proto = TR.deepcopy(so.events[c.ks[1]])
  local laid, length = self:_laid(sec)
  if not TL.ANIM[c.cls] and #c.ks > 1 then
    -- (a camera move: its keys keep their share of it, its interpolation's handles the new length)
    local secs = seconds_of(so.events, laid)
    local span, new = math.max(c.stop - c.start, 1e-6), math.max(stop - start, 0.1)
    for _, k in ipairs(c.ks) do
      local ev = so.events[k]
      put_at(ev, start + (secs[k] - c.start) / span * new, laid, length)
      if ev.cls == "CStorySceneEventCameraInterpolation" then
        sset(ev.props, "keys", "array:2,0,CStorySceneEventCameraInterpolationKey",
             TR.Array({TL.move_key(true, new), TL.move_key(false, new)}))
      end
    end
    return c.id
  end
  if not TL.ANIM[c.cls] then
    local ev = so.events[c.ks[1]]
    put_at(ev, start, laid, length)
    if (TR.sget(ev.props, "duration", 0) or 0) > 0 then sset(ev.props, "duration", "Float", math.max(0.05, stop - start)) end
    return c.id
  end
  local stretch = o.stretch or c.stretch or 1.0
  local len = o.len or ((c.piece or 0) / (c.stretch or 1.0) + (c.front or 0))
  if not (len and len > 0.05) then len = (stop - start) / stretch end
  local front = math.max(0.0, math.min(o.front or c.front or 0.0, len - 0.05))
  local name = c.own and c.id:sub(1, #TL.CLIP) == TL.CLIP and c.id or self:_next_clip(sec)
  local gone, guids = {}, {}
  for _, k in ipairs(c.ks) do
    gone[k] = true
    local g = TR.sget(so.events[k].props, "GUID")
    if g then guids[g.b] = true end
  end
  local before, kept = seconds_of(so.events, laid), {}
  for k, ev in ipairs(so.events) do         -- (events linked to the clip keep their second)
    local lp = TR.sget(ev.props, "linkParentGUID")
    if not gone[k] and lp and guids[lp.b] then kept[ev] = before[k] end
  end
  self:_drop_events(self:num(so), gone)
  sec = self:num(so)
  laid, length = self:_laid(sec)
  for ev, t0 in pairs(kept) do put_at(ev, t0, laid, length) end
  local guid = TR.sget(proto.props, "GUID")
  local t, first = start, true
  while t < stop - 0.02 do
    local from = first and front or 0.0
    local d = math.min((len - from) * stretch, stop - t)
    local ev = TR.deepcopy(proto)
    sset(ev.props, "eventName", "String", name)
    sset(ev.props, "GUID", "CGUID", first and guid or TR.new_guid())
    sset(ev.props, "duration", "Float", d)
    sset(ev.props, "clipFront", "Float", from)
    sset(ev.props, "clipEnd", "Float", from + d / stretch)
    sset(ev.props, "stretch", "Float", stretch)
    -- (blended in on its first piece and out on its last only: a blend at every seam faded each loop out and in -
    -- a walk cycle lost its way, the feet slid, 02.11.)
    local last = t + d >= stop - 0.02
    if o.blend_in ~= nil or not first then sset(ev.props, "blendIn", "Float", first and o.blend_in or 0.0) end
    if o.blend_out ~= nil or not last then sset(ev.props, "blendOut", "Float", last and o.blend_out or 0.0) end
    put_at(ev, t, laid, length)
    self:_add_event(sec, ev)
    t, first = t + d, false
  end
  return name
end

function S:move_clip(sec, id, t)
  local c = self:_clip(sec, id)
  if not c then return nil end
  return self:_write_clip(sec, c, t, t + c.dur, {blend_in = c.blend_in, blend_out = c.blend_out})
end

-- the clip from second `from` to second `to`: the right edge longer plays the animation again, the left edge moved
-- cuts its start (or gives it back)
function S:resize_clip(sec, id, from, to, len)
  local c = self:_clip(sec, id)
  if not c or to - from < 0.05 then return nil end
  local front = (c.front or 0) + (from - c.start) / (c.stretch or 1.0)
  return self:_write_clip(sec, c, from, to, {len = len, front = front, blend_in = c.blend_in, blend_out = c.blend_out})
end

function S:set_clip_speed(sec, id, x, len)
  local c = self:_clip(sec, id)
  if not c or not (x and x > 0.05) then return nil end
  local dur = c.dur / (c.stretch or 1.0) / x
  return self:_write_clip(sec, c, c.start, c.start + dur, {len = len, stretch = 1.0 / x, blend_in = c.blend_in,
                                                           blend_out = c.blend_out})
end

function S:set_clip_blend(sec, id, blend_in, blend_out)
  local c = self:_clip(sec, id)
  if not c then return nil end
  return self:_write_clip(sec, c, c.start, c.stop, {blend_in = blend_in, blend_out = blend_out})
end

-- another animation for the clip, len seconds long: it starts from its beginning, the clip keeps its place and length
function S:set_clip_anim(sec, id, anim, len)
  local c = self:_clip(sec, id)
  if not c or not TL.ANIM[c.cls] then return nil end
  for _, k in ipairs(c.ks) do sset(self:obj(sec).events[k].props, "animationName", "CName", anim) end
  return self:_write_clip(sec, c, c.start, c.stop, {len = len, front = 0.0, blend_in = c.blend_in, blend_out = c.blend_out})
end

-- person `actor` plays animation `anim` (len seconds long) from second t for dur seconds (nil: once)
-- o.layer: on top of what the person plays (the game's additive gestures, add_*), o.weight how strongly
function S:add_clip(sec, actor, anim, len, t, dur, o)
  o = o or {}
  local laid, length = self:_laid(sec)
  if #laid == 0 then return nil end
  local name = self:_next_clip(sec)
  local ev = {cls = o.layer and "CStorySceneEventAdditiveAnimation" or "CStorySceneEventAnimation", props = {
    TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
    TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", TR.new_guid()),
    TR.Prop("duration", "Float", len), TR.Prop("actor", "CName", actor), TR.Prop("clipEnd", "Float", len),
    TR.Prop("stretch", "Float", 1.0), TR.Prop("weight", "Float", o.weight or 1.0),
    TR.Prop("animationName", "CName", anim)}}
  put_at(ev, t, laid, length)
  self:_add_event(sec, ev)
  local c = self:_clip(sec, name)
  -- (o.front: from that second of the animation on, as the game's scenes start a stop from its middle; o.motion: it
  -- carries the person - motion extraction on, fake motion off, as the game's walks, starts, stops and turns)
  local front = o.front or 0.0
  local id = self:_write_clip(sec, c, c.start, c.start + (dur or (len - front)), {len = len, front = front,
                                                                                  blend_in = o.blend_in, blend_out = o.blend_out})
  if o.motion then
    local cc = self:_clip(sec, id)
    for _, k in ipairs(cc and cc.ks or {}) do
      sset(self:obj(sec).events[k].props, "useMotionExtraction", "Bool", true)
      sset(self:obj(sec).events[k].props, "useFakeMotion", "Bool", false)
    end
  end
  return id
end

-- an effect at second t: what = "fade" (o.seconds, o.fade_in, o.color = {r, g, b}), "sound" (o.event: a Wwise
-- event of the game, o.actor: where it sounds, o.bone, o.volume in dB), "fx" (o.actor, o.effect: one of the
-- person's entity effects, o.stop: it ends there) -> the clip's id. The game's own events: they play in the preview
-- and in the built quest alike.
TL.EFFECTS = {fade = "CStorySceneEventFade", sound = "CStorySceneEventSound", fx = "CStorySceneActorEffectEvent"}
function S:add_effect(sec, what, t, o)
  o = o or {}
  local cls = TL.EFFECTS[what]
  if not cls then error("no effect " .. tostring(what) .. " (fade, sound, fx)", 0) end
  local laid, length = self:_laid(sec)
  if #laid == 0 then return nil end
  local name = self:_next_clip(sec)
  local props = {TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
                 TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", TR.new_guid())}
  local ev = {cls = cls, props = props}
  if what == "fade" then
    props[#props + 1] = TR.Prop("duration", "Float", math.max(0.05, o.seconds or 1.0))
    props[#props + 1] = TR.Prop("in", "Bool", o.fade_in and true or false)
    if o.color then
      props[#props + 1] = TR.Prop("color", "Color", TR.Struct({TR.Prop("Red", "Uint8", o.color[1] or 0),
        TR.Prop("Green", "Uint8", o.color[2] or 0), TR.Prop("Blue", "Uint8", o.color[3] or 0),
        TR.Prop("Alpha", "Uint8", 255)}))
    end
  elseif what == "sound" then
    if not o.event or o.event == "" then error("a sound needs its Wwise event", 0) end
    props[#props + 1] = TR.Prop("soundEventName", "String", o.event)
    props[#props + 1] = TR.Prop("actor", "CName", o.actor or "GERALT")
    if o.bone then props[#props + 1] = TR.Prop("bone", "CName", o.bone) end
    if o.volume then props[#props + 1] = TR.Prop("dbVolume", "Float", o.volume) end
  else
    if not (o.actor and o.effect) then error("an effect needs the person and the effect's name", 0) end
    props[#props + 1] = TR.Prop("actor", "CName", o.actor)
    props[#props + 1] = TR.Prop("effectName", "CName", o.effect)
    if o.stop then props[#props + 1] = TR.Prop("startOrStop", "Bool", false) end
  end
  put_at(ev, t, laid, length)
  self:_add_event(sec, ev)
  return name
end

-- an effect's values changed: seconds, fade_in, event, actor, bone, volume, effect, stop (those given)
function S:set_effect(sec, id, o)
  local c = self:_clip(sec, id)
  if not c or not TL.EFFECTS[({CStorySceneEventFade = "fade", CStorySceneEventSound = "sound",
                               CStorySceneActorEffectEvent = "fx"})[c.cls] or ""] then return nil end
  local ev = self:obj(sec).events[c.ks[1]]
  local P = ev.props
  if o.seconds and c.cls == "CStorySceneEventFade" then sset(P, "duration", "Float", math.max(0.05, o.seconds)) end
  if o.fade_in ~= nil and c.cls == "CStorySceneEventFade" then sset(P, "in", "Bool", o.fade_in and true or false) end
  if o.event then sset(P, "soundEventName", "String", o.event) end
  if o.actor then sset(P, "actor", "CName", o.actor) end
  if o.bone then sset(P, "bone", "CName", o.bone) end
  if o.volume then sset(P, "dbVolume", "Float", o.volume) end
  if o.effect then sset(P, "effectName", "CName", o.effect) end
  if o.stop ~= nil and c.cls == "CStorySceneActorEffectEvent" then
    if o.stop then sset(P, "startOrStop", "Bool", false) else sdel(P, "startOrStop") end
  end
  return id
end

-- a camera move from second t0 to t1: camera a there, camera b here (each {pos (scene space), pitch, yaw, fov, focus}),
-- the game's own interpolation between them - eased in and out as its scenes' moves are -> the clip's id
function S:add_camera_move(sec, t0, t1, a, b, ease)
  local laid, length = self:_laid(sec)
  if #laid == 0 or t1 - t0 < 0.1 then return nil end
  local name = self:_next_clip(sec)
  local gi, ga, gb = TR.new_guid(), TR.new_guid(), TR.new_guid()
  local function cam(c, guid, t)
    local props = {TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
                   TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", guid),
                   TR.Prop("interpolationEventGUID", "CGUID", gi)}
    for _, p in ipairs(SF.camera_props(c.pos, c.pitch or 0, c.yaw or 0, c.fov, c.focus)) do props[#props + 1] = p end
    local ev = {cls = "CStorySceneEventCustomCamera", props = props}
    put_at(ev, t, laid, length)
    self:_add_event(sec, ev)
  end
  cam(a, ga, t0)
  cam(b, gb, t1)
  local ev = {cls = "CStorySceneEventCameraInterpolation", props = {
    TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
    TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", gi),
    TR.Prop("keyGuids", "array:2,0,CGUID", TR.Array({ga, gb})),
    TR.Prop("easeInStyle", "EInterpolationEasingStyle", ease == "linear" and "IES_Linear" or "IES_Rapid"),
    TR.Prop("easeOutStyle", "EInterpolationEasingStyle", ease == "linear" and "IES_Linear" or "IES_Rapid"),
    TR.Prop("keys", "array:2,0,CStorySceneEventCameraInterpolationKey", TR.Array({TL.move_key(true, t1 - t0),
                                                                                    TL.move_key(false, t1 - t0)}))}}
  -- (how softly it starts and stops: 0 evenly - a camera beside walking people; without them the game eases, at a
  -- quarter of the time 16 % of the way; 0.5 was even, 1.0 3 % on a 4 s move - measured 02.11.)
  local e = TL.ease_of(ease)
  if e then
    ev.props[#ev.props + 1] = TR.Prop("easeInParameter", "Float", e)
    ev.props[#ev.props + 1] = TR.Prop("easeOutParameter", "Float", e)
  end
  put_at(ev, t0, laid, length)
  self:_add_event(sec, ev)
  return name
end

-- person `actor` goes from place p0 to place p1 ({x, y, z, turn} in the scene's space) between second t0 and t1: a
-- placement at each end and the game's interpolation between them (as the game's scenes move people), evenly - the
-- walk cycle (anim, len s) plays again and again meanwhile, at `rate` (the walk's speed by the cycle's own: the feet go
-- with the ground) -> id. carried: the cycle carries its way in its bones (the game's locomotion cycles, their
-- Trajectory bone): then it moves the figure itself (useMotionExtraction, as the game's scenes walk their steps) from a
-- placement at p0 turned to p1 - an interpolation on top carried it twice and the feet slid (measured 02.11.)
function S:add_walk(sec, actor, t0, t1, p0, p1, anim, len, rate, carried, here)
  local laid, length = self:_laid(sec)
  if #laid == 0 or t1 - t0 < 0.2 then return nil end
  local name = self:_next_clip(sec)
  local gi, ga, gb = TR.new_guid(), TR.new_guid(), TR.new_guid()
  local function place(p, guid, t)
    local ev = {cls = "CStorySceneEventOverridePlacement", props = {
      TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
      TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", guid),
      TR.Prop("interpolationEventGUID", "CGUID", gi), TR.Prop("actorName", "CName", actor),
      TR.Prop("placement", "EngineTransform", TR.Transform({p[1], p[2], p[3] or 0}, {0, 0, p[4] or 0}, nil))}}
    put_at(ev, t, laid, length)
    self:_add_event(sec, ev)
  end
  -- (one place for the person where the walk starts: a moment's own place at that second said otherwise - the slot's
  -- 1.2 m ahead, turned round - and the game took either, play after play: she walked off the other way, 02.11.)
  for _, e in ipairs(here and {} or laid) do      -- (here: the walk goes on from where the person is, no place)
    if math.abs(e.start - t0) < 0.05 then
      self:set_moment_places(sec, e.n, {[actor] = {p0[1], p0[2], p0[4] or 0, p0[3] or 0}})
      laid, length = self:_laid(sec)
      break
    end
  end
  -- (and none of its own in a moment during the walk: it would put the person back there; the walk says where)
  local during = {}
  for _, e in ipairs(laid) do
    if e.start > t0 + 0.05 and e.start < t1 - 0.05 then during[#during + 1] = self:obj(e.n) end
  end
  for _, eo in ipairs(during) do self:_drop_own(sec, eo, "place " .. actor) end
  laid, length = self:_laid(sec)
  if t0 <= 0.05 and not here then
    -- (a walk from the section's start: the person's slot stands there too, turned the way - a placement at second 0
    -- alone was not always there before the slot: she walked off the other way, measured 02.11.)
    local set = self:set_of(sec)
    local ds = set and self:obj(self:_dialogset(set) or 0)
    for _, n in ipairs(ds and ds:get("slots") or {}) do
      local so = self:obj(n)
      if so and tostring(so:get("actorName")) == actor then
        so:set("slotPlacement", TR.Transform({p0[1], p0[2], p0[3] or 0}, {0, 0, p0[4] or 0}, nil), "EngineTransform")
      end
    end
  end
  if carried then
    -- (here: no place at the start - after a start animation that carried the person, a place a few cm off made a
    -- jump, 03.11.)
    local ev0 = not here and {cls = "CStorySceneEventOverridePlacement", props = {
      TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
      TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", ga),
      TR.Prop("actorName", "CName", actor),
      TR.Prop("placement", "EngineTransform", TR.Transform({p0[1], p0[2], p0[3] or 0}, {0, 0, p0[4] or 0}, nil))}}
    if ev0 then
      put_at(ev0, t0, laid, length)
      self:_add_event(sec, ev0)
    end
    local id = anim and self:add_clip(sec, actor, anim, len, t0, t1 - t0)
    local c = id and self:_clip(sec, id)
    if c then                                   -- (no blend anywhere: as the game's scenes walk, 02.11.)
      self:_write_clip(sec, c, t0, t1, {len = len, stretch = 1.0 / math.max(rate or 1.0, 0.05), blend_in = 0.0,
                                         blend_out = 0.0})
      c = self:_clip(sec, id)
    end
    -- (useFakeMotion is on unless the file says false - the game's scenes say it on every walk; on, the scene moved
    -- the person along the way and the pose kept the way as well: he slid ahead and jumped back each cycle, 02.11.)
    for _, k in ipairs(c and c.ks or {}) do
      sset(self:obj(sec).events[k].props, "useMotionExtraction", "Bool", true)
      sset(self:obj(sec).events[k].props, "useFakeMotion", "Bool", false)
    end
    return name
  end
  place(p0, ga, t0)
  place(p1, gb, t1)
  local ev = {cls = "CStorySceneEventPlacementInterpolation", props = {
    TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
    TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", gi),
    TR.Prop("keyGuids", "array:2,0,CGUID", TR.Array({ga, gb})),
    TR.Prop("easeInParameter", "Float", 0.0), TR.Prop("easeOutParameter", "Float", 0.0),
    TR.Prop("keys", "array:2,0,CStorySceneEventPlacementInterpolationKey",
            TR.Array({TL.walk_key(true, t1 - t0), TL.walk_key(false, t1 - t0)}))}}
  put_at(ev, t0, laid, length)
  self:_add_event(sec, ev)
  if anim then
    local id = self:add_clip(sec, actor, anim, len, t0, t1 - t0)
    local c = id and rate and math.abs(rate - 1.0) > 0.02 and self:_clip(sec, id)
    if c then self:_write_clip(sec, c, t0, t1, {len = len, stretch = 1.0 / math.max(rate, 0.05)}) end
  end
  return name
end

-- the acting of the game's scenes (01.11.: theirs has a look, a mood and an accent of the face nearly everywhere, and a
-- handheld camera): what = "look" (o.actor looks at o.target until the next look; o.instant), "mood" (o.actor's face
-- in o.mood: Neutral, Happy, Determined, Sad ...; o.weight), "face" (o.actor's accent of the face: o.anim, o.seconds,
-- o.weight, o.filter), "shake" (the camera moves as held by hand from here: o.anim, default medium_shake) -> id
TL.ACTING = {look = "CStorySceneEventLookAt", mood = "CStorySceneEventMimics", face = "CStorySceneEventMimicsAnim",
             shake = "CStorySceneEventCameraAnim", pose = "CStorySceneEventChangePose",
             light = "CStorySceneEventCameraLight", equip = "CStorySceneEventEquipItem",
             scabbard = "CStorySceneEventHideScabbard", prop_hand = "CStorySceneEventAttachPropToSlot",
             prop_place = "CStorySceneEventScenePropPlacement", visible = "CStorySceneEventVisibility",
             lamp = "CStorySceneEventLightProperties", posekey = "CStorySceneEventPoseKey",
             door = "CStorySceneEventOpenDoor", place = "CStorySceneEventOverridePlacement"}

-- the scene's light `id` (kind "point" or "spot"): made once - a CStorySceneLight in the scene's sceneLights -> id
function S:scene_light(id, kind)
  local root = self:root()
  local list = root:get("sceneLights")
  for _, n in ipairs(list or {}) do
    local o = self:obj(n)
    if o and tostring(o:get("id")) == id then return id end
  end
  local n = self.t:add(TR.Obj("CStorySceneLight", 0, 1, 0, {TR.Prop("id", "CName", id),
    TR.Prop("type", "ELightType", kind == "spot" and "LT_SpotLight" or "LT_PointLight"),
    TR.Prop("shadowCastingMode", "ELightShadowCastingMode", "LSCM_Normal")}))
  if list then table.insert(list, n) else root:set("sceneLights", TR.Array({n}), "array:2,0,ptr:CStorySceneLight") end
  return id
end

-- a value that stays: the game's SSimpleCurve with one entry (its field names cut short, as the game's files have
-- them: me, ntrolPoint, lue, rveTypeL/R)
local function constant(v, scale)
  return TR.Struct({TR.Prop("ScalarEditScale", "Float", scale or 10.0), TR.Prop("ScalarEditOrigin", "Float", 0.0),
    TR.Prop("dataCurveValues", "array:147,0,SCurveDataEntry", TR.Array({TR.Struct({
      TR.Prop("me", "Float", 0.0),
      TR.Prop("ntrolPoint", "Vector", TR.Struct({TR.Prop("X", "Float", -0.1), TR.Prop("Y", "Float", 0.0),
                                                  TR.Prop("Z", "Float", 0.1), TR.Prop("W", "Float", 0.0)})),
      TR.Prop("lue", "Float", v), TR.Prop("rveTypeL", "Uint16", 1), TR.Prop("rveTypeR", "Uint16", 1)})}))})
end

-- the scene's prop `id` of the entity template `template` (a depot path, e.g. items\work\wine_cup\wine_cup_01.w2ent):
-- made once - a CStorySceneProp in the scene's sceneProps, its template one of the file's imports, as the game's
-- scenes have their props -> id
function S:scene_prop(id, template)
  local root = self:root()
  local list = root:get("sceneProps")
  for _, n in ipairs(list or {}) do
    local o = self:obj(n)
    if o and tostring(o:get("id")) == id then return id end
  end
  if not template or template == "" then error("a new prop needs its entity template (a .w2ent of the game)", 0) end
  local imps, idx = self.t.f.imports, nil
  for i, im in ipairs(imps) do if tostring(im[1]):lower() == template:lower() then idx = i end end
  if not idx then
    imps[#imps + 1] = {template, "CEntityTemplate", 4}
    idx = #imps
  end
  local n = self.t:add(TR.Obj("CStorySceneProp", 0, 1, 0, {TR.Prop("id", "CName", id),
    TR.Prop("entityTemplate", "soft:CEntityTemplate", TR.Soft(idx)), TR.Prop("resetBehaviorGraph", "Bool", false),
    TR.Prop("useMimics", "Bool", false)}))
  if list then table.insert(list, n) else root:set("sceneProps", TR.Array({n}), "array:2,0,ptr:CStorySceneProp") end
  return id
end
function S:add_acting(sec, what, t, o)
  o = o or {}
  local cls = TL.ACTING[what]
  if not cls then error("no acting " .. tostring(what) .. " (look, mood, face, shake, pose, light, equip, scabbard, " ..
                              "prop_hand, prop_place, visible, lamp, posekey, door, place)", 0) end
  if what == "look" and o.seconds then cls = "CStorySceneEventLookAtDuration" end   -- (a look for a while: body too)
  local laid, length = self:_laid(sec)
  if #laid == 0 then return nil end
  local name = self:_next_clip(sec)
  local props = {TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
                 TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", TR.new_guid())}
  local function add(n, typ, v) props[#props + 1] = TR.Prop(n, typ, v) end
  if what == "look" and o.seconds then
    -- (a look for o.seconds, head, eyes and the body turned to the target - as the game's scenes have it where people
    -- move: a plain look did not turn a walking face at all, measured 02.11.)
    add("duration", "Float", o.seconds)
    add("actor", "CName", o.actor or "GERALT")
    add("bodyTarget", "CName", o.target or "GERALT")
    add("eyesTarget", "CName", o.target or "GERALT")
    add("eyesEnabled", "Bool", true)
    add("level", "ELookAtLevel", o.level or "LL_Head")
    add("bodyWeight", "Float", o.weight or 0.7)
  elseif what == "look" then
    add("actor", "CName", o.actor or "GERALT")
    add("target", "CName", o.target or "GERALT")
    add("instant", "Bool", o.instant and true or false)
    -- (as the game's scenes look: the head turns, at their speed, in a wide range - without them a look to one beside
    -- did not turn the face at all, measured 02.11.)
    add("level", "ELookAtLevel", o.level or "LL_Head")
    add("speed", "Float", o.speed or 0.6)
    add("range", "Float", o.range or 100.0)
  elseif what == "equip" then
    -- (an item of the person's own into the hand: o.right / o.left the game's category, e.g. steelsword,
    -- silversword; "" puts it away again - as the game's scenes draw a sword)
    add("actor", "CName", o.actor or "GERALT")
    if o.right ~= nil then add("rightItem", "CName", o.right) end
    if o.left ~= nil then add("leftItem", "CName", o.left) end
  elseif what == "prop_hand" or what == "prop_place" then
    -- (a prop of the scene: o.prop its id, o.template its .w2ent the first time; in a hand - o.actor, o.slot
    -- r_weapon / l_weapon, o.offset {x, y, z, pitch, yaw, roll} - or put at o.place {x, y, z, yaw} of the scene)
    local id = self:scene_prop(o.prop or "cj_prop", o.template)
    add("propId", "CName", id)
    if what == "prop_hand" then
      add("actorName", "CName", o.actor or "GERALT")
      add("slotName", "CName", o.slot or "r_weapon")
      -- (out of the hand: activate false, as q101 puts a mug down - then prop_place stands it somewhere; show false
      -- hides it, as mq3035 ends a toast - an attach with show false alone kept it in the hand, 02.11.)
      if o.attach == false then add("activate", "Bool", false) end
      if o.show == false then add("showHide", "Bool", false) end
      local f = o.offset
      if f then add("offset", "EngineTransform", TR.Transform({f.x or 0, f.y or 0, f.z or 0},
                                                              {f.roll or 0, f.pitch or 0, f.yaw or 0}, nil)) end
    else
      local q = o.place or {}
      add("placement", "EngineTransform", TR.Transform({q.x or 0, q.y or 0, q.z or 0}, {0, 0, q.yaw or 0}, nil))
    end
  elseif what == "place" then
    -- (the person put at {x, y, z, turn} of the scene at that second, as the game's scenes set a walk's joints)
    add("actorName", "CName", o.actor or "GERALT")
    add("placement", "EngineTransform", TR.Transform({o.x or 0, o.y or 0, o.z or 0}, {0, 0, o.turn or 0}, nil))
  elseif what == "door" then
    -- (a door of the world by its tag opened - o.open false: closed -, o.instant at once, o.flip the other way:
    -- the game's OpenDoor)
    add("doorTag", "CName", o.door or "")
    add("openClose", "Bool", o.open ~= false)
    if o.instant then add("instant", "Bool", true) end
    if o.flip then add("flipDirection", "Bool", true) end
  elseif what == "posekey" then
    -- (bones of the person turned on top of what they play, blended in and out: o.bones = {{bone, roll, pitch,
    -- yaw}, ...} degrees, o.seconds, o.blend_in, o.blend_out - the game's PoseKey without the editor's caches)
    add("duration", "Float", o.seconds or 2.0)
    add("actor", "CName", o.actor or "GERALT")
    add("blendIn", "Float", o.blend_in or 0.5)
    add("blendOut", "Float", o.blend_out or 0.5)
    add("version", "Int32", 1)
    local list = {}
    for _, b in ipairs(o.bones or {}) do
      list[#list + 1] = TR.Struct({TR.Prop("bone", "CName", b.bone or b[1]),
        TR.Prop("transform", "EngineTransform", TR.Transform(nil, {b.roll or 0, b.pitch or 0, b.yaw or 0}, nil))})
    end
    add("bones", "array:2,0,SSSBoneTransform", TR.Array(list))
    -- (and what the game reads when it plays: the bones' numbers in the person's skeleton and each turn as a
    -- quaternion - a flag byte 2 (a rotation) and x, y, z, w - as the editor caches them; without them nothing
    -- turned, 02.11. Roll turns about y, pitch about x, yaw about z, as a PoseKey's thumb shows)
    local idx, raw = {}, {string.pack("<I4", #(o.bones or {}))}
    for _, b in ipairs(o.bones or {}) do
      idx[#idx + 1] = b.index or -1
      local function q(deg, ax)
        local h = math.rad(deg or 0) / 2
        local v = {0.0, 0.0, 0.0, math.cos(h)}
        v[ax] = math.sin(h)
        return v
      end
      local function mul(a, c)
        return {a[4] * c[1] + a[1] * c[4] + a[2] * c[3] - a[3] * c[2], a[4] * c[2] - a[1] * c[3] + a[2] * c[4] + a[3] * c[1],
                a[4] * c[3] + a[1] * c[2] - a[2] * c[1] + a[3] * c[4], a[4] * c[4] - a[1] * c[1] - a[2] * c[2] - a[3] * c[3]}
      end
      local r = mul(mul(q(b.yaw, 3), q(b.pitch, 1)), q(b.roll, 2))
      raw[#raw + 1] = string.pack("<Bffff", 2, r[1], r[2], r[3], r[4])
    end
    add("cachedBones", "array:2,0,Int32", TR.Array(idx))
    add("cachedTransforms", "array:138,0,EngineQsTransform", TR.Raw(table.concat(raw)))
  elseif what == "lamp" then
    -- (a light of the scene's own from here: o.light its id, o.kind point / spot the first time; o.off: out; else
    -- o.place {x, y, z} of the scene, o.color {r, g, b}, o.brightness (the game's 20-100), o.radius m, o.flicker
    -- (strength 0-1) - as the game's LightProperties)
    local id = self:scene_light(o.light or "cj_light", o.kind)
    add("lightId", "CName", id)
    if o.off then
      add("enabled", "Bool", false)
    else
      local c = o.color or {255, 200, 150}
      add("color", "Color", TR.Struct({TR.Prop("Red", "Uint8", c[1] or c.r or 255),
        TR.Prop("Green", "Uint8", c[2] or c.g or 255), TR.Prop("Blue", "Uint8", c[3] or c.b or 255),
        TR.Prop("Alpha", "Uint8", 255)}))
      add("lightColorSource", "ESceneEventLightColorSource", "ELCS_CustomLightColor")
      add("radius", "SSimpleCurve", constant(o.radius or 4.0, 10.0))
      add("brightness", "SSimpleCurve", constant(o.brightness or 40.0, 50.0))
      local q = o.place or {}
      add("placement", "EngineTransform", TR.Transform({q.x or 0, q.y or 0, q.z or 1.5}, nil, nil))
      if o.flicker then
        add("flickering", "SLightFlickering", TR.Struct({TR.Prop("positionOffset", "Float", 0.02),
          TR.Prop("flickerStrength", "Float", o.flicker), TR.Prop("flickerPeriod", "Float", 0.12)}))
      end
    end
  elseif what == "visible" then
    add("actor", "CName", o.actor or "GERALT")        -- (the person seen or not: the game's Visibility)
    add("showHideFlag", "Bool", o.show ~= false)
  elseif what == "scabbard" then
    add("actorId", "CName", o.actor or "GERALT")   -- (the scabbard hidden: the game's HideScabbard)
  elseif what == "light" then
    -- (the two lights the game hangs on a scene's camera, on the faces: o.key and o.fill = {x, y, z (the light's
    -- offset), brightness, radius} - the game's scenes: key {0, 1-2, 0} radius 0.25, fill brightness 0.3-0.5, 02.11.)
    local function mod(m)
      m = m or {}
      local f = {TR.Prop("lightOffset", "Vector", TR.Struct({TR.Prop("X", "Float", m.x or 0.0),
        TR.Prop("Y", "Float", m.y or 0.0), TR.Prop("Z", "Float", m.z or 0.0), TR.Prop("W", "Float", 1.0)}))}
      if m.brightness then f[#f + 1] = TR.Prop("brightnessScale", "Float", m.brightness) end
      if m.radius then f[#f + 1] = TR.Prop("radiusScale", "Float", m.radius) end
      return TR.Struct(f)
    end
    add("lightMod1", "SStorySceneCameraLightMod", mod(o.key))
    add("lightMod2", "SStorySceneCameraLightMod", mod(o.fill))
  elseif what == "pose" then
    -- (the person's stance from here: o.status High / Low, o.mood Determined, Aggressive ..., o.pose Standing,
    -- Kneeling, Sitting ...; o.transition the game's animation into it, o.seconds its length - as the game's scenes
    -- change a pose, 02.11.)
    local s = o.transition and (o.seconds or 1.0) or 0.0
    add("duration", "Float", s)
    add("actor", "CName", o.actor or "GERALT")
    add("clipEnd", "Float", s)
    add("stretch", "Float", 1.0)
    add("status", "CName", o.status or "High")
    add("emotionalState", "CName", o.mood or "Determined")
    add("poseName", "CName", o.pose or "Standing")
    if o.transition then add("transitionAnimation", "CName", o.transition) end
  elseif what == "mood" then
    local m = o.mood or "Neutral"
    add("duration", "Float", 1.0)
    add("actor", "CName", o.actor or "GERALT")
    add("mimicsEmotionalState", "CName", m)          -- (its layers each their own when given: eyes, face_pose, face_anim)
    add("mimicsLayer_Eyes", "CName", o.eyes or m)
    add("mimicsLayer_Pose", "CName", o.face_pose or m)
    add("mimicsLayer_Animation", "CName", o.face_anim or m)
    add("mimicsPoseWeight", "Float", o.weight or 0.6)
  elseif what == "face" then
    local s = o.seconds or 1.0
    add("duration", "Float", s)
    add("actor", "CName", o.actor or "GERALT")
    -- (the game's own values when given - a rebuild of its scenes: clip_end, stretch, blend_in, blend_out)
    add("blendIn", "Float", o.blend_in or math.min(0.2, s / 3))
    add("blendOut", "Float", o.blend_out or math.min(0.2, s / 3))
    add("clipEnd", "Float", o.clip_end or s)
    add("stretch", "Float", o.stretch or 1.0)
    add("weight", "Float", o.weight or 0.6)
    add("animationName", "CName", o.anim or "nod_head_accent_face")
    add("filterOption", "CName", o.filter or "AccentsHead")
  else
    add("duration", "Float", 0.0)
    add("blendIn", "Float", 0.0)
    add("blendOut", "Float", 0.0)
    add("animationName", "CName", o.anim or "medium_shake")
    add("isIdle", "Bool", true)
  end
  local ev = {cls = cls, props = props}
  put_at(ev, t, laid, length)
  if what == "shake" or what == "light" then
    -- (held by hand: the shake hangs on the camera that starts there, as each of the game's does - one on its own at
    -- the start did not move the picture at all, measured 02.11.)
    local evs = self:obj(sec).events or {}
    local secs, parent = seconds_of(evs, laid), nil
    for k, e in ipairs(evs) do
      if (e.cls == "CStorySceneEventCustomCamera" or e.cls == "CStorySceneEventCustomCameraInstance") and
         math.abs((secs[k] or -1) - t) < 0.02 then
        parent = TR.sget(e.props, "GUID")
      end
    end
    if parent then
      sset(ev.props, "linkParentGUID", "CGUID", parent)
      sset(ev.props, "linkParentTimeOffset", "Float", 0.0)
    end
  end
  self:_add_event(sec, ev)
  return name
end

-- the scene's end into the game at second t, as the game's scenes end (02.11.: 155 of them, ~0.5 s before the end):
-- a StartBlendToGameplayCamera with the shot's camera (c = {pos, pitch, yaw, fov, focus}; nil: the camera of one's
-- own that is on at t, copied) - from it the game blends to its own camera - and for each of `actors` a
-- ChangeActorGameState hung on it (they are the game's again; their pose snaps into the game's, as in the
-- game's own scenes - blendPoseDuration 1 s changed nothing, 02.11.) -> id
function S:add_end_blend(sec, t, c, actors)
  local laid, length = self:_laid(sec)
  if #laid == 0 then return nil end
  local name = self:_next_clip(sec)
  local gi = TR.new_guid()
  local kids = {}
  for k = 1, #(actors or {}) do kids[k] = TR.new_guid() end
  local props = {TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
                 TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", gi),
                 TR.Prop("linkChildrenGUID", "array:2,0,CGUID", TR.Array(kids))}
  if c then
    for _, p in ipairs(SF.camera_props(c.pos, c.pitch or 0, c.yaw or 0, c.fov, c.focus)) do props[#props + 1] = p end
  else                                          -- (the camera on at t: the latest of one's own that starts by then)
    local evs = self:obj(sec).events or {}
    local secs, best, bt = seconds_of(evs, laid), nil, -1
    for k, e in ipairs(evs) do
      if e.cls == "CStorySceneEventCustomCamera" and (secs[k] or 0) <= t + 1e-3 and (secs[k] or 0) >= bt then
        best, bt = e, secs[k]
      end
    end
    if not best then error("no camera of one's own before " .. tostring(t) .. " s: give the blend a camera", 0) end
    for _, p in ipairs(best.props) do
      if p.name:sub(1, 6) == "camera" or p.name:sub(1, 3) == "dof" then props[#props + 1] = TR.Prop(p.name, p.type, p.value) end
    end
  end
  local ev = {cls = "CStorySceneEventStartBlendToGameplayCamera", props = props}
  put_at(ev, t, laid, length)
  self:_add_event(sec, ev)
  for k, actor in ipairs(actors or {}) do
    local kid = {cls = "CStorySceneEventChangeActorGameState", props = {
      TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
      TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", kids[k]),
      TR.Prop("actor", "CName", actor)}}
    put_at(kid, t, laid, length)
    sset(kid.props, "linkParentGUID", "CGUID", gi)
    sset(kid.props, "linkParentTimeOffset", "Float", 0.0)
    self:_add_event(sec, kid)
  end
  return name
end

-- the stance a person has in the section's dialogset (their slot), as the game's dialogsets give one: o.status
-- High / Low, o.mood Determined, Bored ..., o.pose Standing, Sitting, Sitting Ground ...; o.face_pose and
-- o.face_weight the face's own layer (Very happy 0.3 ...) -> true, or nil when the section has no slot for them
function S:set_slot_stance(sec, actor, o)
  local set = self:set_of(sec)
  local ds = set and self:obj(self:_dialogset(set) or 0)
  for _, n in ipairs(ds and ds:get("slots") or {}) do
    local so = self:obj(n)
    if so and tostring(so:get("actorName")) == actor then
      if o.status then so:set("actorStatus", o.status, "CName") end
      if o.mood then so:set("actorEmotionalState", o.mood, "CName") end
      if o.pose then so:set("actorPoseName", o.pose, "CName") end
      if o.face_pose then so:set("actorMimicsLayer_Pose", o.face_pose, "CName") end
      if o.face_weight then so:set("actorMimicsLayer_Pose_Weight", o.face_weight, "Float") end
      return true
    end
  end
  return nil
end

-- the scene's output `name` (made once: a CStorySceneOutput among the scene's control parts - a quest's 'play scene'
-- goes on from it by its name; o.blackscreen: it ends black, o.blend: seconds into the game's camera) -> its number
function S:scene_output(name, o)
  o = o or {}
  local root = self:root()
  for _, n in ipairs(root:get("controlParts") or {}) do
    local c = self:obj(n)
    if c and c.cls == "CStorySceneOutput" and tostring(c:get("name")) == name then return n end
  end
  local props = {TR.Prop("linkedElements", "array:2,0,ptr:CStorySceneLinkElement", TR.Array({})),
                 TR.Prop("name", "CName", name)}
  if o.blackscreen then props[#props + 1] = TR.Prop("endsWithBlackscreen", "Bool", true) end
  if o.blend then props[#props + 1] = TR.Prop("gameplayCameraBlendTime", "Float", o.blend) end
  local n = self.t:add(TR.Obj("CStorySceneOutput", 0, 1, 0, props))
  table.insert(root:get("controlParts"), n)
  return n
end

-- a choice at the end of section sec, as the game's talks have one: answers = {{text_id, to (a number: a section
-- or an output), pay (money), exit, once, emphasis}}, seconds the time to choose -> the choice's number
function S:set_choice(sec, answers, seconds)
  sec = self:n(sec)
  local so = self:obj(sec)
  local old = so:get("choice", 0)
  if old and old > 0 then error("this section has a choice already", 0) end
  local k = 1
  while true do
    local used = false
    for _, o in ipairs(self.t.objects) do
      if o.cls == "CStorySceneChoice" and tostring(o:get("elementID")) == "Choice_cj" .. k then used = true end
    end
    if not used then break end
    k = k + 1
  end
  local ch = self.t:add(TR.Obj("CStorySceneChoice", 0, sec, 0, {TR.Prop("elementID", "String", "Choice_cj" .. k),
    TR.Prop("approvedDuration", "Float", seconds or 10.0),
    TR.Prop("choiceLines", "array:2,0,ptr:CStorySceneChoiceLine", TR.Array({}))}))
  local list = self:obj(ch):get("choiceLines")
  for _, a in ipairs(answers) do
    local line = self.t:add(TR.Obj("CStorySceneChoiceLine", 0, ch, 0, {
      TR.Prop("nextLinkElement", "ptr:CStorySceneLinkElement", a.to),
      TR.Prop("choiceLine", "LocalizedString", TR.Loc(a.text_id))}))
    local lo = self:obj(line)
    if a.once then lo:set("singleUseChoice", true, "Bool") end
    if a.emphasis then lo:set("emphasisLine", true, "Bool") end
    if a.pay then                                -- (the game's coin at the answer: it pays when chosen)
      local act = self.t:add(TR.Obj("CPayStorySceneChoiceAction", 0, line, 0, {TR.Prop("money", "Int32", a.pay),
        TR.Prop("dontGrantExp", "Bool", true)}))
      lo:set("action", act, "ptr:IStorySceneChoiceLineAction")
    elseif a.exit then                           -- (the game's way out of a talk)
      local act = self.t:add(TR.Obj("CExitStorySceneChoiceAction", 0, line, 0, {}))
      lo:set("action", act, "ptr:IStorySceneChoiceLineAction")
    end
    table.insert(list, line)
    local to = self:obj(a.to)                    -- (and the target knows what leads into it, as the editor keeps it)
    local back = to and to:get("linkedElements")
    if back then table.insert(back, line) elseif to then
      to:set("linkedElements", TR.Array({line}), "array:2,0,ptr:CStorySceneLinkElement") end
  end
  so:set("choice", ch, "ptr:CStorySceneChoice")
  so:set("nextLinkElement", 0, "ptr:CStorySceneLinkElement")   -- (a talk with a choice goes on by the answer only)
  return ch
end

-- every acting of one's own in a section gone (looks, moods, accents, the handheld camera)
function S:clear_acting(sec)
  local classes, gone = {}, {}
  for _, c in pairs(TL.ACTING) do classes[c] = true end
  classes.CStorySceneEventLookAtDuration = true
  for k, ev in ipairs(self:obj(sec).events or {}) do
    local name = tostring(TR.sget(ev.props, "eventName", ""))
    if classes[ev.cls] and name:sub(1, #TL.CLIP) == TL.CLIP then gone[k] = true end
  end
  if next(gone) then self:_drop_events(sec, gone) end
end

-- where the section's placements have each person at second t ({actor = {x, y, z, turn}}, the scene's space): the last
-- placement before t, between the two keys of a walk (a placement interpolation) the share of the way t is at
function S:placements_at(sec, t)
  local laid = self:_laid(sec)
  local events = self:obj(sec).events or {}
  local secs = seconds_of(events, laid)
  local keys = {}                               -- actor -> {{t, place, interpolation guid}}
  for k, ev in ipairs(events) do
    if ev.cls == "CStorySceneEventOverridePlacement" then
      local actor = tostring(TR.sget(ev.props, "actorName", ""))
      local tf = TR.sget(ev.props, "placement")
      if actor ~= "" and tf then
        local p, r = tf.position or {}, tf.rotation or {}
        local ig = TR.sget(ev.props, "interpolationEventGUID")
        keys[actor] = keys[actor] or {}
        table.insert(keys[actor], {secs[k] or 0, {p[1] or 0, p[2] or 0, p[3] or 0, r[3] or 0}, ig and ig.b})
      end
    end
  end
  local out = {}
  for actor, list in pairs(keys) do
    table.sort(list, function(a, b) return a[1] < b[1] end)
    local before, after
    for _, kk in ipairs(list) do
      if kk[1] <= t + 1e-6 then before = kk elseif not after then after = kk end
    end
    local p = before and before[2]
    if before and after and before[3] and before[3] == after[3] and after[1] > before[1] then
      local f = (t - before[1]) / (after[1] - before[1])
      p = {}
      for i = 1, 4 do p[i] = before[2][i] + (after[2][i] - before[2][i]) * f end
    end
    if p then out[actor] = {x = p[1], y = p[2], z = p[3], turn = p[4]} end
  end
  return out
end

-- a key of a placement interpolation (as the game's scenes write them): 6 channels, as move_key
function TL.walk_key(first, secs)
  local hs, ts = {}, {}
  local function v2(x, y) return TR.Struct({TR.Prop("X", "Float", x), TR.Prop("Y", "Float", y)}) end
  for k = 1, 6 do
    hs[k] = TR.Struct({TR.Prop("incomingTangent", "Vector2", v2(first and 1.0 or secs / 3, 0.0)),
                       TR.Prop("outgoingTangent", "Vector2", v2(first and secs / 3 or 1.0, 0.0))})
    ts[k] = 2
  end
  return TR.Struct({TR.Prop("bezierHandles", "[6]Bezier2dHandle", TR.Array(hs)),
                    TR.Prop("interpolationTypes", "[6]Uint32", TR.Array(ts))})
end

-- a move's easing parameters: "linear" 0 (evenly), a number as it is, "smooth" (the default) none: the game's own
function TL.ease_of(ease)
  if type(ease) == "number" then return math.max(0.0, ease) end
  return ease == "linear" and 0.0 or nil
end

-- a cut to camera c ({pos (scene space), pitch, yaw, fov, focus}) at second t: it lasts until the next camera -> id
function S:add_camera_cut(sec, t, c)
  local laid, length = self:_laid(sec)
  if #laid == 0 then return nil end
  local name = self:_next_clip(sec)
  local props = {TR.Prop("eventName", "String", name), TR.Prop("startPosition", "Float", 0.0),
                 TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n), TR.Prop("GUID", "CGUID", TR.new_guid())}
  for _, p in ipairs(SF.camera_props(c.pos, c.pitch or 0, c.yaw or 0, c.fov, c.focus)) do props[#props + 1] = p end
  local ev = {cls = "CStorySceneEventCustomCamera", props = props}
  put_at(ev, t, laid, length)
  self:_add_event(sec, ev)
  return name
end

-- every camera of one's own in a section between second t0 and t1 gone (the moments' own cameras, cuts, moves)
function S:clear_cameras(sec, t0, t1)
  local tl = self:timeline(sec)
  local gone = {}
  for _, c in pairs(tl.clips) do
    if c.kind == "camera" and c.own and c.start >= (t0 or 0) - 1e-6 and c.start <= (t1 or 1e9) + 1e-6 then
      for _, k in ipairs(c.ks) do gone[k] = true end
    end
  end
  if next(gone) then self:_drop_events(sec, gone) end
end

-- a key of a camera move (as the game's scenes write them): 15 channels, each a bezier handle - the first key's way
-- out and the last key's way in a third of the move long, flat - and the interpolation kind 2
function TL.move_key(first, secs)
  local hs, ts = {}, {}
  local function v2(x, y) return TR.Struct({TR.Prop("X", "Float", x), TR.Prop("Y", "Float", y)}) end
  for k = 1, 15 do
    hs[k] = TR.Struct({TR.Prop("incomingTangent", "Vector2", v2(first and 1.0 or secs / 3, 0.0)),
                       TR.Prop("outgoingTangent", "Vector2", v2(first and secs / 3 or 1.0, 0.0))})
    ts[k] = 2
  end
  return TR.Struct({TR.Prop("bezierHandles", "[15]Bezier2dHandle", TR.Array(hs)),
                    TR.Prop("interpolationTypes", "[15]Uint32", TR.Array(ts))})
end

function S:remove_clip(sec, id)
  local c = self:_clip(sec, id)
  if not c then return false end
  local gone = {}
  for _, k in ipairs(c.ks) do gone[k] = true end
  self:_drop_events(sec, gone)
  return true
end

-- the element second t falls in -> its number (nil: none)
function S:element_at(sec, t)
  local laid = self:_laid(sec)
  local pick
  for _, e in ipairs(laid) do
    if e.len > 0 and e.start <= t + 1e-6 then pick = e end
  end
  return pick and pick.n or nil
end

-- the pause at second t split in two: a moment of its own starts at t (every event keeps its second) -> its element
function S:split_at(sec, t)
  local laid = self:_laid(sec)
  local pick
  for _, e in ipairs(laid) do
    if e.len > 0 and e.start <= t and t < e.start + e.len then pick = e end
  end
  if not pick or self:obj(pick.n).cls ~= "CStoryScenePauseElement" then return nil, "Only a pause can be split" end
  if t - pick.start < 0.1 or pick.start + pick.len - t < 0.1 then return nil, "Too near the moment's edge" end
  local so, eo = self:obj(sec), self:obj(pick.n)
  local at, keep = seconds_of(so.events, laid), {}
  for k, ev in ipairs(so.events) do keep[ev] = at[k] end
  self:set_duration(pick.n, t - pick.start)
  local n = self:add_moment(self:num(so), self:num(eo), pick.start + pick.len - t)
  local laid2, length = self:_laid(self:num(so))
  for ev, t0 in pairs(keep) do put_at(ev, t0, laid2, length) end
  return n
end

-- the section `secs` long: its last element (a pause) longer or shorter; every event keeps its second
function S:set_length(sec, secs)
  local laid, length = self:_laid(sec)
  local last = laid[#laid]
  if not last or self:obj(last.n).cls ~= "CStoryScenePauseElement" then return false end
  local new = math.max(0.1, last.len + secs - length)
  local so = self:obj(sec)
  local at = seconds_of(so.events or {}, laid)
  self:set_duration(last.n, new)
  laid, length = self:_laid(self:num(so))
  for k, ev in ipairs(so.events or {}) do put_at(ev, at[k], laid, length) end
  return true
end

-- a section by its name (sectionName) -> its number, or nil
function S:section_named(name)
  for n, o in ipairs(self.t.objects) do
    if SF.SECTIONS[o.cls] and o:get("sectionName") == name then return n end
  end
  return nil
end

-- --- the layer (MaximdeWinter 01.11.): what one put on a scene's timeline - the events of one's own ("cj ..."), each at its
-- second of its section - kept apart from a scene that is made anew at every build (a talk of the quest: radish
-- builds it from its lines). Laid over the new scene again, it stays where it was in time; a line changed moves only
-- what comes after it. conjunction/scene_layer.py lays it the same way in the build.
--   s:layer() -> {version = 1, sections = {[name] = {{cls, at, props}}}, props = {{id, template}}}
--   s:apply_layer(layer) -> sections laid       (a handle to an import is kept as {import = {path, class}})
TL.LAYER_SKIP = {sceneElement = true, startPosition = true, linkParentGUID = true, linkParentTimeOffset = true}
-- (an event keeps its GUID in the layer: a camera move's parts name each other by theirs)

local function ser(v)
  if TR.is(v, TR.STRUCT) then
    local out = {}
    for _, p in ipairs(v) do out[#out + 1] = {p.name, p.type, ser(p.value)} end
    return {struct = out}
  elseif TR.is(v, TR.TRANSFORM) then
    return {transform = {position = v.position, rotation = v.rotation, scale = v.scale}}
  elseif TR.is(v, TR.ARRAY) then
    local out = {}
    for i, x in ipairs(v) do out[i] = ser(x) end
    return {array = out}
  elseif TR.is(v, TR.WIDE) then
    return {wide = v.s}
  elseif TR.is(v, TR.LOC) then
    return {loc = v.n}
  elseif TR.is(v, TR.TAGS) then
    local out = {}
    for i, x in ipairs(v) do out[i] = x end
    return {tags = out}
  elseif TR.is(v, TR.GUID) then
    return {guid = (v.b:gsub(".", function(c) return string.format("%02x", c:byte()) end))}
  elseif type(v) == "table" then
    error("a value of a kind the layer does not keep (" .. tostring((getmetatable(v) or {}).__name) .. ")", 0)
  end
  return v
end

local function deser(v)
  if type(v) ~= "table" then return v end
  if v.struct then
    local out = {}
    for _, p in ipairs(v.struct) do out[#out + 1] = TR.Prop(p[1], p[2], deser(p[3])) end
    return TR.Struct(out)
  elseif v.transform then
    local t = v.transform
    return TR.Transform(t.position, t.rotation, t.scale)
  elseif v.array then
    local out = {}
    for i, x in ipairs(v.array) do out[i] = deser(x) end
    return TR.Array(out)
  elseif v.wide then
    return TR.Wide(v.wide)
  elseif v.loc then
    return TR.Loc(v.loc)
  elseif v.tags then
    return TR.Tags(v.tags)
  elseif v.guid then
    return TR.Guid((v.guid:gsub("..", function(h) return string.char(tonumber(h, 16)) end)))
  end
  return v
end
TL.layer_ser, TL.layer_deser = ser, deser

local function own(ev)
  return tostring(TR.sget(ev.props, "eventName", "")):sub(1, #SF.OWN_EVENT) == SF.OWN_EVENT
end

-- --- the cameras: Automatic (the build's cut on each line's speaker) or Custom (none of the build's left: the cameras
-- are clips of one's own). The scene says which: a camera of the build in it is Automatic.
TL.CAM_CUTS = {CStorySceneEventCustomCameraInstance = true, CStorySceneEventCustomCamera = true,
               CStorySceneEventCamera = true, CStorySceneEventCameraBlend = true,
               CStorySceneEventEnhancedCameraBlend = true, CStorySceneEventCameraInterpolation = true,
               CStorySceneEventCameraInterpolationKey = true, CStorySceneEventCsCamera = true,
               CStorySceneEventGameplayCamera = true}

-- --- things of the world a scene switches at a second (MaximdeWinter 10.11.: a candle lit when she says so). o.what: door
-- (o.open), effect (o.effect, o.start), light (o.on), hide, show; o.wid the object's id in the project
-- (world_pick.lua), o.tag its tag, o.fact the fact a light, hide or show sets (the build turns the facts into TW3SE's
-- world edits: worldchanges.scene_lines). Its name says what it is: "cj act <what> <wid> <state>" -> its clip id
TL.WORLD_ACT = SF.OWN_EVENT .. "act "
TL.WORLD_LABEL = {door = "Door", effect = "Effect", light = "Light", hide = "Hide", show = "Show", anim = "Move"}
-- looks over the world a scene can lay (the game's environment definitions its scenes use: env_audit.py, 11.11.)
TL.LOOKS = {
  {"sunset", "Sunset", [[environment\definitions\env_novigrad\env_novigrad_sunset.env]]},
  {"cave", "Cave", [[environment\definitions\env_novigrad\env_novigrad_cave.env]]},
  {"cellar", "Cellar", [[environment\definitions\cutscenes_definition\envs_for_cutscenes\dandelion_cellar_cutscene.env]]},
  {"dark_mist", "Dark mist", [[environment\definitions\env_island_of_mist\env_island_of_mist_dark_cutscen.env]]},
  {"nightmare", "Nightmare", [[environment\definitions\kaer_morhen\cutscenes\kaer_morhen_nightmare.env]]},
  {"battle", "Battle", [[environment\definitions\usm\battle_02.env]]},
  {"cold_light", "Cold light", [[environment\definitions\env_skellige\q502\env_kaer_morhen_v09_tm_q502_cold_light.env]]},
  {"white_winter", "White winter", [[environment\definitions\env_winter\env_winter_epilog_white_grass.env]]},
  {"heavy_rain", "Dark clouds, heavy rain", [[dlc\ep1\environment\definitions\q601\q601_dark_clouds_heavy_rain_scene.env]]},
  {"creepy", "Creepy", [[dlc\ep1\data\environment\definitions\in_progress\q604\q604_creepy_cs.env]]},
  {"painted", "Painted world", [[dlc\ep1\data\environment\definitions\in_progress\q604\q604_painting_cs.env]]},
  {"blizzard", "Blizzard", [[dlc\ep1\data\environment\definitions\in_progress\q604\q604_blizzard_cs.env]]},
  {"wedding", "Wedding glow", [[dlc\ep1\environment\definitions\q602\q602_wedding_overlay.env]]},
  {"red_hell", "Red hell", [[dlc\ep1\data\environment\definitions\in_progress\q605\q605_hell_red_blockout.env]]},
  {"fairytale", "Fairytale land", [[dlc\bob\data\environment\definitions\quests\q704\fairytale\q704_fairyland_e_cs.env]]},
  {"snow", "Snow", [[dlc\bob\data\environment\definitions\quests\q704\q704_snow2_cs.env]]},
}
function TL.look_path(key) for _, l in ipairs(TL.LOOKS) do if l[1] == key then return l[3] end end end
function TL.look_name(key) for _, l in ipairs(TL.LOOKS) do if l[1] == key then return l[2] end end return key end
-- "WT_Rain_Storm" -> "Rain storm"
function TL.weather_name(w)
  local s = tostring(w or ""):gsub("^WT_", ""):gsub("_", " "):lower()
  return (s:gsub("^%l", string.upper))
end
-- the file's import of path (added when it has none) -> its number (a handle to it is minus that)
function S:import_of(path, cls)
  local imps = self.t.f.imports
  for i, im in ipairs(imps) do if tostring(im[1]):lower() == path:lower() then return i end end
  imps[#imps + 1] = {path, cls, 0}
  return #imps
end
function S:add_world_action(sec, t, o)
  local laid, length = self:_laid(sec)
  if #laid == 0 then return nil end
  local state = o.what
  if o.what == "door" then state = o.open == false and "close" or "open"
  elseif o.what == "effect" then state = (o.start == false and "stop" or "start") .. ":" .. tostring(o.effect or "")
  elseif o.what == "light" then state = o.on == false and "off" or "on"
  elseif o.what == "anim" then state = tostring(o.anim or "")
  elseif o.what == "weather" then state = tostring(o.weather or "WT_Clear")
  elseif o.what == "env" then state = (o.on == false and "off:" or "") .. tostring(o.key) end
  local props = {TR.Prop("eventName", "String", TL.WORLD_ACT .. o.what .. " " .. tostring(o.wid) .. " " .. state),
                 TR.Prop("startPosition", "Float", 0.0), TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1].n),
                 TR.Prop("GUID", "CGUID", TR.new_guid())}
  local cls
  if o.what == "door" then
    cls = "CStorySceneEventOpenDoor"
    props[#props + 1] = TR.Prop("doorTag", "CName", o.tag)
    props[#props + 1] = TR.Prop("openClose", "Bool", o.open ~= false)
  elseif o.what == "env" then                  -- (a look over the world's: one of the file's imports)
    local path = TL.look_path(o.key)
    if not path then error("no look " .. tostring(o.key), 0) end
    cls = "CStorySceneEventModifyEnv"
    props[#props + 1] = TR.Prop("environmentDefinition", "handle:CEnvironmentDefinition",
                                -self:import_of(path, "CEnvironmentDefinition"))
    props[#props + 1] = TR.Prop("activate", "Bool", o.on ~= false)
    props[#props + 1] = TR.Prop("priority", "Int32", 3000)
    props[#props + 1] = TR.Prop("blendFactor", "Float", 1.0)
  elseif o.what == "weather" then              -- (the sky: the game's own scene event, blended in o.blend s)
    cls = "CStorySceneEventWeatherChange"
    props[#props + 1] = TR.Prop("weatherName", "CName", state)
    props[#props + 1] = TR.Prop("blendTime", "Float", o.blend or 5.0)
  elseif o.what == "effect" then
    cls = "CStorySceneEventWorldEntityEffect"
    props[#props + 1] = TR.Prop("entityTag", "CName", o.tag)
    props[#props + 1] = TR.Prop("effectName", "CName", o.effect or "")
    props[#props + 1] = TR.Prop("startStop", "Bool", o.start ~= false)
  else
    cls = "CStorySceneAddFactEvent"               -- (as the game's: it never runs out)
    props[#props + 1] = TR.Prop("factId", "String", o.fact)
    props[#props + 1] = TR.Prop("expireTime", "Int32", -1)
  end
  local ev = {cls = cls, props = props}
  put_at(ev, t, laid, length)
  self:_add_event(sec, ev)
  return key_of(ev, 0)
end

-- how many things of the world the scene switches (a new fact's number)
function S:world_act_count()
  local n = 0
  for _, o in ipairs(self.t.objects) do
    for _, ev in ipairs(o.events or {}) do
      if tostring(TR.sget(ev.props, "eventName", "")):sub(1, #TL.WORLD_ACT) == TL.WORLD_ACT then n = n + 1 end
    end
  end
  return n
end

function S:camera_mode()
  for _, o in ipairs(self.t.objects) do
    if SF.SECTIONS[o.cls] then
      for _, ev in ipairs(o.events or {}) do
        if TL.CAM_CUTS[ev.cls] and not own(ev) then return "auto" end
      end
    end
  end
  return "custom"
end

-- the cameras (those of the build: mine = false; one's own: mine = true) out of every section
function S:_drop_cameras(mine)
  for n, o in ipairs(self.t.objects) do
    if SF.SECTIONS[o.cls] and o.events then
      local gone = {}
      for k, ev in ipairs(o.events) do
        if TL.CAM_CUTS[ev.cls] and (own(ev) and true or false) == mine then gone[k] = true end
      end
      if next(gone) then self:_drop_events(n, gone) end
    end
  end
end

-- "auto": the cameras of one's own go (the build's cuts again, at the next build or layer); "custom": the build's
-- cuts become clips of one's own; "custom" with empty: every camera goes, each section starts with one from the side
function S:set_camera_mode(mode, empty)
  if mode == "auto" then
    self:_drop_cameras(true)
    return
  end
  if empty then
    self:_drop_cameras(false)
    self:_drop_cameras(true)
    local secs = {}
    for _, o in ipairs(self.t.objects) do
      if SF.SECTIONS[o.cls] and o.events and #(o:get("sceneElements") or {}) > 0 then secs[#secs + 1] = o end
    end
    for _, so in ipairs(secs) do
      local sec = self:num(so)
      local first = self:_laid(sec)[1]
      if first then self:set_moment_camera(sec, first.n, "side", "medium") end
    end
    return
  end
  for n, o in ipairs(self.t.objects) do
    if SF.SECTIONS[o.cls] and o.events then
      for _, ev in ipairs(o.events) do
        if TL.CAM_CUTS[ev.cls] and not own(ev) then sset(ev.props, "eventName", "String", self:_next_clip(n)) end
      end
    end
  end
end

function S:layer()
  local out = {version = 1, sections = {}, cameras = self:camera_mode()}
  for n, o in ipairs(self.t.objects) do
    if SF.SECTIONS[o.cls] and o.events and #o.events > 0 then
      local laid = self:_laid(n)
      local secs = seconds_of(o.events, laid)
      local list = {}
      for k, ev in ipairs(o.events) do
        if own(ev) then
          local props = {}
          for _, p in ipairs(ev.props) do
            if not TL.LAYER_SKIP[p.name] then
              local v = ser(p.value)
              -- (a handle to one of the file's imports, a look's .env: kept as the import itself - the scene it is
              -- laid over has imports of its own; 11.11. the bare number pointed past them, the game crashed
              -- loading the scene, witcher3.exe+0x2732ed7)
              if tostring(p.type):match("^handle:") and type(p.value) == "number" and p.value < 0 then
                local im = self.t.f.imports[-p.value]
                if im then v = {import = {im[1], im[2]}} end
              end
              props[#props + 1] = {p.name, p.type, v}
            end
          end
          list[#list + 1] = {cls = ev.cls, at = secs[k], props = props}
        end
      end
      if #list > 0 then out.sections[self:name_of(n)] = list end
    end
  end
  -- (the scene's props, a cup for a hand: id and template, made again in the scene it is laid over - 11.11., the
  -- build's new scene had none and an event's prop was missing)
  for _, n in ipairs(self:root():get("sceneProps") or {}) do
    local o = self:obj(n)
    local soft = o and o:get("entityTemplate")
    local im = type(soft) == "table" and soft.n and self.t.f.imports[soft.n]
    if im then
      out.props = out.props or {}
      out.props[#out.props + 1] = {tostring(o:get("id")), im[1]}
    end
  end
  return out
end

-- every section's own events gone (the scene as it was made, without a layer)
function S:strip_own()
  for n, o in ipairs(self.t.objects) do
    if SF.SECTIONS[o.cls] and o.events then
      local gone = {}
      for k, ev in ipairs(o.events) do if own(ev) then gone[k] = true end end
      if next(gone) then self:_drop_events(n, gone) end
    end
  end
end

-- the layer over this scene: a section's own events made anew from it (those it had go first); a section the scene no
-- longer has is left out -> the names of the sections laid, the names left out
-- (qid: the build's run - a fact of a thing of the world, "@wa_...", becomes "<qid>_wa_...")
function S:apply_layer(layer, qid)
  local laid_names, missing = {}, {}
  if (layer or {}).cameras == "custom" then self:_drop_cameras(false) end   -- (Custom: the build's cuts out)
  for _, p in ipairs((layer or {}).props or {}) do pcall(self.scene_prop, self, p[1], p[2]) end
  for name, list in pairs((layer or {}).sections or {}) do
    local sec = self:section_named(name)
    if not sec then
      missing[#missing + 1] = name
    else
      local o = self:obj(sec)
      local gone = {}
      for k, ev in ipairs(o.events or {}) do if own(ev) then gone[k] = true end end
      if next(gone) then self:_drop_events(sec, gone) end
      sec = self:section_named(name)
      local laid, length = self:_laid(sec)
      table.sort(list, function(a, b) return (a.at or 0) < (b.at or 0) end)
      for _, rec in ipairs(list) do
        -- (in the order the scene's own events have: its name, start, element, GUID, the rest)
        local props, first = {}, rec.props[1]
        if first and first[1] == "eventName" then props[1] = TR.Prop(first[1], first[2], deser(first[3])) end
        props[#props + 1] = TR.Prop("startPosition", "Float", 0.0)
        props[#props + 1] = TR.Prop("sceneElement", "ptr:CStorySceneElement", laid[1] and laid[1].n or 0)
        local own_guid
        for _, p in ipairs(rec.props) do if p[1] == "GUID" then own_guid = deser(p[3]) end end
        props[#props + 1] = TR.Prop("GUID", "CGUID", own_guid or TR.new_guid())
        for i, p in ipairs(rec.props) do
          if not (i == 1 and p[1] == "eventName") and p[1] ~= "GUID" then
            local v
            if type(p[3]) == "table" and p[3].import then
              v = -self:import_of(p[3].import[1], p[3].import[2])
            else
              v = deser(p[3])
            end
            -- (a layer written before 11.11.: a look's bare import number of the old file - the look again from its
            -- event's name, "cj act env look [off:]<key>")
            if rec.cls == "CStorySceneEventModifyEnv" and p[1] == "environmentDefinition" and type(v) == "number" then
              local name = first and first[1] == "eventName" and tostring(deser(first[3])) or ""
              local path = TL.look_path((name:match("act env %S+ (.+)$") or ""):gsub("^off:", ""))
              v = path and -self:import_of(path, "CEnvironmentDefinition") or 0
            end
            if qid and p[1] == "factId" and type(v) == "string" and v:sub(1, 4) == "@wa_" then v = qid .. "_" .. v:sub(2) end
            props[#props + 1] = TR.Prop(p[1], p[2], v)
          end
        end
        local ev = {cls = rec.cls, props = props}
        put_at(ev, rec.at or 0, laid, length)
        self:_add_event(sec, ev)
      end
      laid_names[#laid_names + 1] = name
    end
  end
  table.sort(laid_names)
  table.sort(missing)
  return laid_names, missing
end

return TL
