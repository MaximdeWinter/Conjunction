-- Objects the game placed, used by a quest or a scene (MaximdeWinter 10.11.: a candle lit at a moment of a scene, a door
-- opened - Pick in world takes one that stands there, Show what fits marks everything of that kind within 30 m).
-- An object of the world is kept in the project's meta (world_objects: id -> guid, template, pos, world, name, kind)
-- and named by the ref "@world/<id>". The build gives it a tag through TW3SE's world edit (`tag <guid> <tag>`,
-- worldchanges.lua), so every block of the game that names things by tag reaches it (SetLights, DoorChangeState,
-- the scene's OpenDoor, PlayEffectQuest ...): measured 10.11., a tag added at run time is found by GetEntityByTag.
--   WP.scan(pos, kind) -> {{e, guid, pos, name, kind}}     what fits within WP.RADIUS of pos (kept half a second)
--   WP.hit(ed, mx, my, w, h) -> candidate                 the one under the mouse (picture pixels)
--   WP.draw(ed, W, H)                                       the markers while the editor waits for a pick
--   WP.keep(project, cand, world) -> ref                    into the project (the same object: the same ref)
--   WP.is_ref(ref), WP.get(project, ref), WP.tag(project, ref), WP.guid_tag(guid)
local WP = {}

WP.PREFIX = "@world/"
WP.RADIUS = 30
WP.HIT_PX = 26
WP.KINDS = {door = "Door", light = "Light", effect = "Effect", container = "Container", clue = "Clue",
            usable = "Usable", moving = "Moving", switch = "Switch", any = "Object"}
-- the kind a quest action's target needs (questboard ACTIONS; nil: only objects of the project)
WP.FOR_ACTION = {door = "door", lights = "light", effect = "effect", containers = "container", presence = "any",
                 highlight = "any", mappin = "any", lock = "door", clue = "clue", part = "any", thinglook = "any",
                 thinganim = "moving", switch = "switch"}
-- the kind a goal's object needs (Loot a chest, Examine a clue, Use a lever / gate / fire of the game)
WP.FOR_GOAL = {loot = "container", examine = "clue", use = "usable"}
-- what a kind is called: one, several (the pick's title "Pick · Light source", its button "Highlight light sources")
WP.NOUN = {door = {"Door", "doors"}, light = {"Light source", "light sources"}, effect = {"Effect", "effects"},
           container = {"Container", "containers"}, clue = {"Clue", "clues"}, usable = {"Usable thing", "usable things"},
           moving = {"Moving thing", "moving things"}, switch = {"Switch", "switches"}, any = {"Thing", "things"}}
function WP.noun(kind, many)
  local n = WP.NOUN[kind] or WP.NOUN.any
  return many and n[2] or n[1]
end
WP.CHOSEN = 0x4aa3ffff                    -- (the ones taken with Shift: blue, the kinds' own colours stay for the rest)
-- c is in the request's selection (by its GUID; a thing of the project by its ref)
function WP.is_picked(r, c)
  local k = c.guid or c.ref
  for _, p in ipairs(r and r.picked or {}) do if (p.guid or p.ref) == k then return true end end
  return false
end
-- (what using means something for: the classes of the game with their own interaction)
WP.USABLE = {"Door", "Switch", "Lever", "Elevator", "Gate", "Mechanism", "Lock", "Bed", "Boat", "FireSource",
             "Fireplace", "Lamp", "Torch", "Board", "Altar", "Interactive", "Meditation", "Stash"}
local CLASS = {door = "W3NewDoor", container = "W3Container", clue = "W3MonsterClue", switch = "W3Switch"}
-- (what a pick should never offer: places, triggers, sound emitters - they have no body to click)
local NOT_ANY = {"ActionPoint", "Area", "Trigger", "Encounter", "Emitter", "Merged", "Lair", "Saveable", "Waypoint",
                 "Community", "Spawner", "Fog", "Wind", "Marker"}
local COLOUR = {door = 0xe3c65fff, light = 0xffb347ff, effect = 0x5fcbb9ff, container = 0x8fd07aff,
                clue = 0xe57a7aff, usable = 0x6fb1f0ff, moving = 0xf08fc0ff, switch = 0xc9d46aff,
                any = 0xb99be6ff}

function WP.is_ref(ref) return type(ref) == "string" and ref:sub(1, #WP.PREFIX) == WP.PREFIX end
function WP.id_of(ref) return WP.is_ref(ref) and ref:sub(#WP.PREFIX + 1) or nil end

local function now()
  if w3.time then return w3.time() end
  return os.clock()
end

-- "aaaaaaaa-bbbbbbbb-..." -> "aaaaaaaa bbbbbbbb ..." (world.txt's form); nil for an object made while playing
local function lasting_guid(e)
  local ok, g = pcall(w3.guid, e)
  if not ok or not g then return nil end
  g = tostring(g):gsub("%-", " ")
  if g:lower():match("^ffffffff ffffffff") or g:match("^0+ 0+ 0+ 0+$") then return nil end
  return g
end

-- words of a file name a person does not read as the thing's name: its set, size, mount, variant letter or number,
-- its quest (11.11.: a goal read "Search decoration set boxes crate a" in the journal)
local NOISE = {decoration = true, deco = true, set = true, sets = true, boxes = true, wall = true, metal = true,
               wire = true, large = true, small = true, big = true, medium = true, han = true, bounce = true,
               regular = true, fx = true, proxy = true, static = true, dynamic = true}
function WP.readable(s)
  local keep = {}
  for w in tostring(s or ""):gmatch("%S+") do
    local l = w:lower()
    if not (NOISE[l] or #l == 1 or l:match("^%d+%a?$") or l:match("^m?q%d+") or l:match("^%d+m$")) then
      keep[#keep + 1] = w
    end
  end
  return #keep > 0 and table.concat(keep, " ") or tostring(s or "")
end
local function short(path)
  local b = tostring(path or ""):match("([^\\/]*)$") or ""
  return WP.readable((b:gsub("%.w2ent$", ""):gsub("%.w2mesh$", ""):gsub("_", " ")))
end

-- a name a person reads: its template's, else its mesh's file (a nameless gate of the harbour: "gate", not
-- "CGameplayEntity"), else its class
function WP.name_of(e)
  local name = short(e:GetReadableName())
  if name ~= "" then return name end
  for _, cls in ipairs({"CRigidMeshComponent", "CStaticMeshComponent", "CMeshComponent"}) do
    local ok, path = pcall(function() return e:GetComponentByClassName(cls).mesh:GetDepotPath() end)
    if ok and path and tostring(path) ~= "" then return (short(path):gsub("%.w2mesh$", "")) end
  end
  return tostring(w3.classof(e))
end

function WP.effects_of(e)
  local fx = {}
  pcall(function() for _, f in ipairs(e.template.effects:to_table()) do fx[#fx + 1] = tostring(f.name) end end)
  return fx
end

-- a light with a flame (its effect "fire", all 215 lights around the bathhouse, 13.11.): it goes out at once only -
-- faded, the coal fire's flame burnt on long after its light. c: a candidate (c.e, c.ref) -> true
function WP.has_flame(project, c)
  if c.flame == nil then
    local fx = c.e and WP.effects_of(c.e) or nil
    if not fx then
      local o = c.ref and WP.get(project, c.ref)
      fx = o and o.effects or {}
    end
    c.flame = false
    for _, f in ipairs(fx) do if tostring(f) == "fire" then c.flame = true break end end
  end
  return c.flame
end

-- its moves (the property animations of the game: a gate's "raise", a shelf's "move")
function WP.anims_of(e)
  local out = {}
  pcall(function()
    local s = e.propertyAnimationSet
    if s then for _, a in ipairs(s.animations:to_table()) do out[#out + 1] = tostring(a.animationName) end end
  end)
  return out
end

local function has_light(e)
  local ok, c = pcall(function() return e:GetComponentByClassName("CGameplayLightComponent") end)
  return ok and c ~= nil
end

local function any_ok(e)
  local c = tostring(w3.classof(e) or "")
  for _, w in ipairs(NOT_ANY) do if c:find(w, 1, true) then return false end end
  return true
end

-- does entity e fit kind (the kinds with a class are asked for by class)
function WP.fits(e, kind)
  if kind == "light" then return has_light(e) end
  if kind == "effect" then return #WP.effects_of(e) > 0 end
  if kind == "moving" then return #WP.anims_of(e) > 0 end
  if kind == "any" then return any_ok(e) end
  if kind == "usable" then
    local c = tostring(w3.classof(e) or "")
    for _, w in ipairs(WP.USABLE) do if c:find(w, 1, true) then return true end end
    return false
  end
  -- (the kinds with a class: its name or a class made from it - W3AnimatedContainer, W3ClueStash; a scan asks
  -- w3.near for the class, this answers for one alone)
  local word = ({door = "Door", container = "Container", clue = "Clue", switch = "Switch"})[kind]
  return word ~= nil and tostring(w3.classof(e) or ""):find(word, 1, true) ~= nil
end

-- the entities within WP.RADIUS of pos: the game's own range query, 1 ms (w3.near asks every entity loaded - in
-- Novigrad 100 000, 1.1 s a scan, 1 fps while picking, 12.11.). It finds gameplay entities only: for the kinds a plain
-- CEntity can be (an effect, a thing that moves, any thing) the rest comes from a sweep over all of them, 1500 a frame
-- (sweep_step), and is added when it is done.
local GAMEPLAY_ONLY = {light = true, door = true, container = true, clue = true, usable = true, switch = true}
local SWEEP_SLICE = 1500
local sweeps = {}                         -- kind -> {pos, all, i, found, done}
local function in_sphere(pos, kind)
  local v = {X = pos[1], Y = pos[2], Z = pos[3], W = 1}
  local ok, a = pcall(w3.call, "FindGameplayEntitiesInSphere", nil, v, WP.RADIUS, 5000, nil, 0, nil, CLASS[kind])
  if not ok then return nil end
  return type(a) == "table" and a or (a and a.to_table and a:to_table()) or {}
end
local function sweep_step(pos, kind)
  local s = sweeps[kind]
  if not s or math.abs(s.pos[1] - pos[1]) + math.abs(s.pos[2] - pos[2]) >= 2 then
    s = {pos = {pos[1], pos[2], pos[3]}, all = nil, i = 1, found = {}, done = false}
    sweeps[kind] = s
  end
  if s.done then return s end
  if not s.all then
    local ok, all = pcall(w3.entities)
    s.all = ok and all or {}
  end
  local r2 = WP.RADIUS * WP.RADIUS
  local stop = math.min(#s.all, s.i + SWEEP_SLICE - 1)
  for k = s.i, stop do
    local e = s.all[k]
    local ok, wp = pcall(e.GetWorldPosition, e)
    if ok and wp then
      local dx, dy, dz = wp.X - s.pos[1], wp.Y - s.pos[2], wp.Z - s.pos[3]
      if dx * dx + dy * dy + dz * dz <= r2 then s.found[#s.found + 1] = e end
    end
  end
  s.i = stop + 1
  if s.i > #s.all then s.done, s.all = true, nil end
  return s
end
local function near_list(pos, kind)
  local list = in_sphere(pos, kind)
  if list == nil then                           -- (no range query: the old way, every entity asked)
    local ok, ents = pcall(w3.near, {X = pos[1], Y = pos[2], Z = pos[3]}, WP.RADIUS, CLASS[kind])
    return ok and ents or {}, true
  end
  if GAMEPLAY_ONLY[kind] then return list, true end
  local s = sweep_step(pos, kind)
  if not s.done then return list, false end
  local have = {}
  for _, e in ipairs(list) do have[w3.addr(e)] = true end
  for _, e in ipairs(s.found) do
    if not have[w3.addr(e)] then list[#list + 1] = e end
  end
  return list, true
end

-- a thing taken before as a candidate again (the pick list's rows): its entity found by its GUID near where it
-- stood (e nil: not loaded now - its row stays, a test leaves it out)
function WP.candidate(project, ref)
  local o = WP.get(project, ref)
  if not o then return nil end
  local op = o.pos or {}
  local pos = {tonumber(op[1]) or 0, tonumber(op[2]) or 0, tonumber(op[3]) or 0}
  local c = {guid = o.guid, pos = pos, name = tostring(o.display or o.name or WP.id_of(ref)), kind = o.kind, ref = ref}
  for _, e in ipairs(in_sphere(pos, nil) or {}) do
    if lasting_guid(e) == o.guid then c.e = e break end
  end
  return c
end

local cache, names = {}, {}
function WP.scan(pos, kind)
  kind = WP.KINDS[kind] and kind or "any"
  local c = cache[kind]
  local t = now()
  local moved = c and math.abs(c.pos[1] - pos[1]) + math.abs(c.pos[2] - pos[2]) >= 2
  if c and c.whole and t - c.t < 0.5 and not moved then return c.list end
  if c and not c.whole and not moved and t - c.t < 0.05 then return c.list end
  local list = {}
  local ents, whole = near_list(pos, kind)
  for _, e in ipairs(ents) do
    local g = lasting_guid(e)
    if g and WP.fits(e, kind) then
      local wp = e:GetWorldPosition()
      local name = names[g] or WP.name_of(e)        -- (kept by GUID: the mesh's path is asked once)
      names[g] = name
      list[#list + 1] = {e = e, guid = g, pos = {wp.X, wp.Y, wp.Z}, name = name ~= "" and name or tostring(w3.classof(e)),
                         kind = kind, template = tostring(e:GetReadableName())}
    end
  end
  cache[kind] = {t = t, pos = {pos[1], pos[2], pos[3]}, list = list, whole = whole}
  return list
end

-- where a marker stands: a door at the height of its handle, the rest a little over its foot
local function marker_at(c)
  local up = c.kind == "door" and 1.2 or (c.kind == "container" and 0.6 or 0.15)
  return {c.pos[1], c.pos[2], c.pos[3] + up}
end

-- the candidate under the mouse: the nearest marker within HIT_PX, the one nearer the camera when two are as near
function WP.hit(ed, mx, my, w, h)
  local r = ed.request
  if not (r and r.world and ed.cam and ed.cam.pos) then return nil end
  local best, bd
  for _, c in ipairs(WP.scan(ed.cam.pos, r.world)) do
    local s = ed.cam:project(marker_at(c), w, h)
    if s then
      local d = math.sqrt((s[1] - mx) ^ 2 + (s[2] - my) ^ 2)
      if d <= WP.HIT_PX then
        local far = math.sqrt((c.pos[1] - ed.cam.pos[1]) ^ 2 + (c.pos[2] - ed.cam.pos[2]) ^ 2 + (c.pos[3] - ed.cam.pos[3]) ^ 2)
        local score = d + far * 0.5 + (WP.seen and not WP.seen(ed, c) and 40 or 0)   -- (one seen before one behind a wall)
        if not bd or score < bd then best, bd = c, score end
      end
    end
  end
  return best
end

-- is c seen from the camera (a ray through the static world, kept half a second: a wall between them hides it)
local function seen(ed, c)
  local t = now()
  if c.vis_t and t - c.vis_t < 0.5 then return c.vis end
  local m = marker_at(c)
  local p = ed.cam.pos
  local ok, hit, at = pcall(w3.world.trace, {X = p[1], Y = p[2], Z = p[3]}, {X = m[1], Y = m[2], Z = m[3]})
  local vis = true
  if ok and hit and at then
    local dx, dy, dz = (at.X or at[1] or m[1]) - m[1], (at.Y or at[2] or m[2]) - m[2], (at.Z or at[3] or m[3]) - m[3]
    vis = dx * dx + dy * dy + dz * dz < 1.2 * 1.2          -- (it hit the thing itself or right at it)
  end
  c.vis, c.vis_t = vis, t
  return vis
end
WP.seen = seen

-- the markers: with Show what fits on, every candidate within 30 m - one behind a wall paler, without its name; a
-- name where it does not cover another; always the one under the mouse, bigger, with its name
function WP.draw(ed, W, H, mx, my)
  local r = ed.request
  if not (r and r.world and ed.cam and ed.cam.pos and ed.cam.ready) then return end
  local D = w3.ui.draw
  local Q = require("conjunction.ui.qt")
  local col = COLOUR[r.world] or COLOUR.any
  local pale = (col & 0xffffff00) | 0x98            -- (behind a wall: paler, still seen on a dark wall - 11.11.)
  local under = mx and WP.hit(ed, mx, my, W, H) or nil
  local list = ed.show_fits and WP.scan(ed.cam.pos, r.world) or {}
  local shown = {}
  -- (the selection always shown, also without the highlight)
  local listed = {}
  for _, c in ipairs(list) do listed[c.guid] = true end
  for _, c in ipairs(r.picked or {}) do
    if not listed[c.guid] then list[#list + 1] = c end
  end
  for _, c in ipairs(list) do
    local s = ed.cam:project(marker_at(c), W, H)
    if s and s[1] >= 0 and s[2] >= 0 and s[1] <= W and s[2] <= H then
      local d = (c.pos[1] - ed.cam.pos[1]) ^ 2 + (c.pos[2] - ed.cam.pos[2]) ^ 2 + (c.pos[3] - ed.cam.pos[3]) ^ 2
      shown[#shown + 1] = {c = c, s = s, d = d, vis = seen(ed, c)}
    end
  end
  table.sort(shown, function(a, b)
    if a.vis ~= b.vis then return a.vis end
    return a.d < b.d
  end)
  -- (none of them in the picture: the nearest named at the edge it lies toward - 11.11., a torch 7 m behind the
  -- camera and the picture showed nothing at all)
  if #shown == 0 and #list > 0 then
    local best, bd
    for _, c in ipairs(list) do
      local d = (c.pos[1] - ed.cam.pos[1]) ^ 2 + (c.pos[2] - ed.cam.pos[2]) ^ 2 + (c.pos[3] - ed.cam.pos[3]) ^ 2
      if not bd or d < bd then best, bd = c, d end
    end
    local f, rgt, up = ed.cam:axes()
    local p = marker_at(best)
    local v = {p[1] - ed.cam.pos[1], p[2] - ed.cam.pos[2], p[3] - ed.cam.pos[3]}
    local function dot(a) return v[1] * a[1] + v[2] * a[2] + v[3] * a[3] end
    local ang = math.deg(math.atan(dot(rgt), dot(f)))
    local what = string.format("%s, %d m", best.name, math.floor(math.sqrt(bd) + 0.5))
    local text, side
    if math.abs(ang) > 135 then text, side = "Behind you: " .. what, "bottom"
    elseif ang > 45 then text, side = what .. "  \u{2192}", "right"
    elseif ang < -45 then text, side = "\u{2190}  " .. what, "left"
    elseif dot(up) > 0 then text, side = "\u{2191}  " .. what, "top"
    else text, side = "\u{2193}  " .. what, "bottom" end
    local tw = Q.text_w(text, 13, true)
    local x, y = (W - tw) // 2, H - 130
    if side == "right" then x, y = W - tw - 30, H // 2
    elseif side == "left" then x, y = 30, H // 2
    elseif side == "top" then y = 130 end
    D.fill(x - 10, y - 4, tw + 20, 26, 0x000000c0)
    Q.text(x, y, col, text, 13, true, 0x000000c0)
  end
  local taken = {}                                -- (the labels drawn: a new one that would cover one is left out)
  local function free(x, y, w, h)
    for _, b in ipairs(taken) do
      if x < b[1] + b[3] and b[1] < x + w and y < b[2] + b[4] and b[2] < y + h then return false end
    end
    return true
  end
  if under then
    local s = ed.cam:project(marker_at(under), W, H)
    if s then
      local text = under.name
      taken[#taken + 1] = {math.floor(s[1]) + 12, math.floor(s[2]) - 10, Q.text_w(text, 12, true) + 12, 20}
    end
  end
  for _, m in ipairs(shown) do
    local x, y = math.floor(m.s[1]), math.floor(m.s[2])
    local chosen = WP.is_picked(r, m.c)
    D.fill(x - 5, y - 5, 10, 10, m.vis and 0x000000a0 or 0x00000070)
    D.fill(x - 4, y - 4, 8, 8, chosen and WP.CHOSEN or (m.vis and col or pale))
    if chosen then D.rect(x - 8, y - 8, 16, 16, WP.CHOSEN, 2) end
    if m.vis and m.c ~= under then
      local tw = Q.text_w(m.c.name, 11)
      if free(x + 8, y - 8, tw + 8, 16) then
        taken[#taken + 1] = {x + 8, y - 8, tw + 8, 16}
        D.fill(x + 8, y - 8, tw + 8, 16, 0x000000b0)
        Q.text(x + 12, y - 7, 0xddddddff, m.c.name, 11, false, 0x000000b0)
      end
    end
  end
  if under then
    local s = ed.cam:project(marker_at(under), W, H)
    if s then
      local x, y = math.floor(s[1]), math.floor(s[2])
      local uc = WP.is_picked(r, under) and WP.CHOSEN or col
      D.rect(x - 9, y - 9, 18, 18, uc, 2)
      D.fill(x - 4, y - 4, 8, 8, uc)
      local text = under.name
      local tw = Q.text_w(text, 12, true)
      D.fill(x + 12, y - 10, tw + 12, 20, 0x000000d0)
      Q.text(x + 18, y - 8, 0xffffffff, text, 12, true, 0x000000d0)
    end
  end
end

-- --- the project's objects of the world
local function meta_of(project)
  local Y = require("conjunction.yaml")
  project.meta = project.meta or Y.map()
  if not Y.is_map(project.meta.world_objects) then project.meta.world_objects = Y.map() end
  return project.meta.world_objects
end

function WP.get(project, ref)
  local id = WP.id_of(ref)
  if not id then return nil end
  local m = project and project.meta and project.meta.world_objects
  return m and m[id] or nil
end

-- candidate c into the project (an object taken before: its ref again) -> ref
function WP.keep(project, c, world)
  local Y = require("conjunction.yaml")
  local m = meta_of(project)
  local fx, parts, looks, anims = Y.list({}), Y.list({}), Y.list({}), Y.list({})
  if c.e then
    for _, f in ipairs(WP.effects_of(c.e)) do fx[#fx + 1] = f end
    -- (its parts one can switch: what the player uses or talks to - the game's EntityComponentQuest takes them)
    pcall(function()
      for _, comp in ipairs(c.e.components:to_table()) do
        local cls = tostring(w3.classof(comp))      -- (a door's: CDoorComponent0, what a quest waits on to use it)
        if cls:find("Interaction", 1, true) or cls:find("DoorComponent", 1, true) then
          parts[#parts + 1] = tostring(comp:GetName())
        end
      end
    end)
    pcall(function() for _, l in ipairs(w3.figure.appearances(c.e)) do looks[#looks + 1] = l end end)
    -- (a look with no parts of its own where the others have some: the bare base, often nothing - 11.11., a morgue
    -- body's corpse_villager_01 left the bier empty; out of the list then)
    pcall(function()
      local parts_of, with = {}, 0
      for _, a in ipairs(c.e.template.appearances:to_table()) do
        local n = #a.includedTemplates:to_table()
        parts_of[tostring(a.name)] = n
        if n > 0 then with = with + 1 end
      end
      if with > 0 then
        local kept = Y.list({})
        for _, l in ipairs(looks) do if parts_of[tostring(l)] ~= 0 then kept[#kept + 1] = l end end
        looks = kept
      end
    end)
    for _, a in ipairs(WP.anims_of(c.e)) do anims[#anims + 1] = a end
  end
  for id, o in pairs(m) do                      -- (taken before: the same ref, what it offers read anew)
    if o.guid == c.guid then
      if c.e then o.effects, o.parts, o.looks, o.anims = fx, parts, looks, anims end
      if c.name and c.name ~= "" then o.name = c.name end   -- (a name read anew: WP.readable came later, 11.11.)
      return WP.PREFIX .. id
    end
  end
  local base = (c.name:lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
  if base == "" then base = c.kind end
  base = base:sub(1, 32)
  local id, k = base, 1
  while m[id] do k = k + 1; id = base .. "_" .. k end
  m[id] = Y.map({"guid", c.guid, "name", c.name, "kind", c.kind, "template", c.template,
                 "pos", Y.list({c.pos[1], c.pos[2], c.pos[3]}), "world", world, "effects", fx,
                 "parts", parts, "looks", looks, "anims", anims})
  return WP.PREFIX .. id
end

-- the game's interaction a goal on it waits for (CQuestInteractionCondition's interactionName: the name of one of its
-- interaction components, kept as its parts) - examine: a clue's "InteractiveClue"; use: a door's "CDoorComponent0",
-- else one named for using; else the first that is not the lock's or the medallion's; nil: it has none known
function WP.interaction_for(o, kind)
  local parts = {}
  for _, p in ipairs(o and o.parts or {}) do parts[#parts + 1] = tostring(p) end
  local function find(pat) for _, p in ipairs(parts) do if p:lower():find(pat) then return p end end end
  if kind == "loot" then return find("^loot$") or "Loot" end
  if kind == "examine" then return find("interactiveclue") or find("examin") or find("inspect") or parts[1] end
  local other
  for _, p in ipairs(parts) do
    local l = p:lower()
    if not (l == "locked" or l == "unlock" or l == "medallion" or l == "loot") then other = other or p end
  end
  return find("doorcomponent") or find("^use") or other or parts[1]
end

-- the tag the build gives it (worldchanges.lua writes `tag <guid> <this>`)
-- (from its GUID: the same in every build of the quest - a Build & Play run has a number of its own, and a scene
-- written in one run kept naming the tag of that run, 10.11. - and in every project that uses the object)
function WP.guid_tag(guid) return "cjw_" .. tostring(guid or ""):gsub("[^%x]", ""):lower() end
function WP.tag(project, ref)
  local o = WP.get(project, ref)
  return o and WP.guid_tag(o.guid) or ("cjw_" .. tostring(WP.id_of(ref)))
end

-- the name shown for it
-- is it gone from the world (a mod or a patch of the game took it away)? Only known near it: the game keeps what
-- stands within WP.KNOWN m of the camera loaded, farther it says nothing -> true: gone, false: there or not known
WP.KNOWN = 50
function WP.gone(project, ref, at)
  local o = WP.get(project, ref)
  if not o then return true end
  if not (at and o.pos) then return false end
  local d = math.sqrt((tonumber(o.pos[1]) - at[1]) ^ 2 + (tonumber(o.pos[2]) - at[2]) ^ 2)
  if d > WP.KNOWN then return false end
  local ok, e = pcall(w3.by_guid, (tostring(o.guid):gsub(" ", "-")))
  return ok and e == nil
end

function WP.label(project, ref)
  local o = WP.get(project, ref)
  if not o then return nil end
  return tostring(o.display or o.name or WP.id_of(ref))
end

return WP
