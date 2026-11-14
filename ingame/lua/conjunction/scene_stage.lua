-- The world set for a preview while editing. Editing, Geralt rides along under the free camera as an unseen ghost
-- (conjunction_cam.ws CjFlyFollow) and the quest's built people are hidden behind the editor's copies - a scene played
-- so had nobody in it: a talk's spot is the player, its people stood under the camera or not at all (07.11.: the
-- preview of a new talk showed the market behind where its two should stand). While a preview plays Geralt is off the
-- camera and seen, where the game has him - in front of the one he talks to - and the built people are seen, their
-- copies not; after it everything is as it was.
--   ST.stage(ed, partner)   partner: the built person's tag the talk is with (nil: Geralt onto the ground below)
--   ST.unstage(ed)          as it was (the preview over, the cutscene editor left, editing ends)
local Y = require("conjunction.yaml")
local ST = {}

ST.FRONT = 1.6             -- metres between the two, as the game has them after E (measured 07.11., Novigrad)
ST.staged = nil            -- {geralt = bool, tags = {...}} while set

-- the built people of the place being edited: tags, and tag -> {pos, yaw} where the project has them
local function built_tags(ed)
  local out, homes = {}, {}
  local QUEST = require("conjunction.quest")
  local p = ed.project and ed.project.places and ed.project.places[ed.place]
  local objs = p and p.objects
  if not objs or objs == Y.null then return out, homes end
  for _, o in ipairs(objs) do
    if o.id and o.id ~= Y.null and o.id ~= "" and QUEST.is_actor(o) then
      local tag = ed.project:id() .. "_" .. ed.place .. "_" .. tostring(o.id)
      out[#out + 1] = tag
      if type(o.pos) == "table" and o.pos[1] then
        homes[tag] = {pos = {X = o.pos[1], Y = o.pos[2], Z = o.pos[3], W = 1},
                      yaw = type(o.rot) == "table" and tonumber(o.rot[3]) or 0}
      end
    end
  end
  return out, homes
end

-- the built one with the tag (not the editor's copy: those carry cj_placed)
local function built(tag)
  for _, e in ipairs(w3.by_tag and w3.by_tag(tag) or {}) do
    local ok, copy = pcall(function() return e:HasTag("cj_placed") end)
    if ok and not copy then return e end
  end
  return nil
end

-- the built people seen (on) or hidden again; the editor's copies of people (cj_placed, without the built one's tag)
-- hidden meanwhile, without collision (a built one seen on the same spot pushed its copy metres away, 07.11.) - kept
-- in copies with where they stood, put back there and seen again
local function show_built(tags, on, copies, homes)
  if on then
    for _, e in ipairs(w3.by_tag and w3.by_tag("cj_placed") or {}) do
      local ok, cls = pcall(w3.classof, e)
      if ok and cls == "CNewNPC" then
        pcall(function()
          local c = {e = e, pos = e:GetWorldPosition(), rot = e:GetWorldRotation()}
          e:SetHideInGame(true)
          e:EnableCollisions(false)
          copies[#copies + 1] = c
        end)
      end
    end
  end
  for _, tag in ipairs(tags) do
    for _, e in ipairs(w3.by_tag and w3.by_tag(tag) or {}) do
      pcall(function()
        if not e:HasTag("cj_placed") then
          -- (home first: where the project has them, not where the last preview's scene left them)
          local h = on and homes and homes[tag]
          if h then e:TeleportWithRotation(h.pos, {Pitch = 0, Yaw = h.yaw, Roll = 0}) end
          e:SetHideInGame(not on)
          e:EnableCollisions(on)
        end
      end)
    end
  end
  if not on then
    for _, c in ipairs(copies) do
      pcall(function()
        c.e:TeleportWithRotation(c.pos, c.rot)
        c.e:EnableCollisions(true)
        c.e:SetHideInGame(false)
      end)
    end
  end
end

-- where the preview puts Geralt with `partner`: pos {X, Y, Z}, yaw - from the partner's place in the project (ed),
-- else where the partner is; nil when neither is known
function ST.front_of(partner, ed)
  local at, ryaw
  if ed then
    local _, homes = built_tags(ed)
    local h = partner and homes[partner]
    if h then at, ryaw = h.pos, h.yaw end
  end
  if not at then
    local e = partner and built(partner)
    if not e then return nil end
    local ok = pcall(function() at, ryaw = e:GetWorldPosition(), e:GetWorldRotation().Yaw or 0 end)
    if not ok then return nil end
  end
  local a = math.rad(ryaw or 0)                  -- (the game's heading: yaw 0 looks along +Y)
  return {X = at.X - math.sin(a) * ST.FRONT, Y = at.Y + math.cos(a) * ST.FRONT, Z = at.Z, W = 1}, (ryaw or 0) + 180
end

function ST.stage(ed, partner)
  if not (ed and ed.editing) or ST.staged then return end
  local p = w3.player and w3.player()
  if not p then return end
  local tags, homes = built_tags(ed)
  local st = {geralt = false, tags = tags, copies = {}, at = os.clock()}
  ST.staged = st
  show_built(st.tags, true, st.copies, homes)
  local okf, riding = pcall(function() return p.w3sFlyOn and p.w3sFlyAway end)
  if not (okf and riding) then return end
  local ok = pcall(function()
    p:BreakAttachment()
    p.w3sFlyAway = false
    p:CjFlyGhost(false)
  end)
  if not ok then return end
  st.geralt = true
  local pos, yaw = ST.front_of(partner, ed)
  if not pos then
    pcall(function()
      local at, rot = p:GetWorldPosition(), p:GetWorldRotation()
      local z = w3.world and w3.world.ground and w3.world.ground({X = at.X, Y = at.Y, Z = at.Z + 5}) or at.Z
      pos, yaw = {X = at.X, Y = at.Y, Z = z or at.Z, W = 1}, rot.Yaw or 0
    end)
  end
  if pos then pcall(function() p:TeleportWithRotation(pos, {Pitch = 0, Yaw = yaw or 0, Roll = 0}) end) end
end

-- a scene holds the people (playing or paused)
function ST.scene_on()
  local ok, busy = pcall(function()
    return w3.player():IsInNonGameplayCutscene() or w3.global("theGame"):IsDialogOrCutscenePlaying()
  end)
  return ok and busy
end

-- (not while a scene still holds Geralt: put on the camera then, the scene's end put him at the world's origin -
-- the caller stops it first, scene_work.after_play_tick calls again once it is over)
function ST.unstage(ed)
  local st = ST.staged
  if not st or ST.scene_on() then return end
  ST.staged = nil
  if not ed.editing then return end             -- (playing: the built people are the game's, the copies are gone)
  show_built(st.tags, false, st.copies)
  local p = w3.player and w3.player()
  if not p then return end
  pcall(function()
    if not p.w3sFlyOn then return end
    -- (riding along again, unseen: the editor's own way, from where the camera is; the free camera the picture's
    -- again - after a scene the game kept its last camera)
    if st.geralt then p:CjFlyFollow() end
    if p.w3sFlyCam then p.w3sFlyCam:Run() end
  end)
end

return ST
