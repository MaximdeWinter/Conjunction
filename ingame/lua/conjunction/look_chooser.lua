-- A person's looks (conjunction/look_chooser.py): their order, their labels, the file a look's tile is kept in, and
-- LookPainter - the tiles drawn one at a time in the background, the last one asked for first (what the grid shows
-- now): the look in 3D from the front (ui/view3d.lua, its textures at 256 px), 200 x 272, kept in cache_file.
--   LC.want(template, look [, low [, square]])   LC.tick(behind) (each frame)   LC.on_painted(fn(template, look, path))   LC.PAINT (false: none)
local S = require("conjunction.pystr")
local H = require("conjunction.hashlib")
local PATHS = require("conjunction.paths")
local LC = {}
LC.CACHE = PATHS.join(PATHS.DATA, "looks")
LC.TILE = {96, 136}

-- the game's own looks first (the ones its spawns use, in their order), the quests' (__name) last
function LC.ordered(apps, used)
  local is_app, first, in_first = {}, {}, {}
  for _, a in ipairs(apps) do is_app[a] = true end
  for _, u in ipairs(used) do
    if is_app[u] then first[#first + 1] = u in_first[u] = true end
  end
  local own, quest = {}, {}
  for _, a in ipairs(apps) do
    if not in_first[a] then
      if a:sub(1, 2) == "__" then quest[#quest + 1] = a else own[#own + 1] = a end
    end
  end
  for _, a in ipairs(own) do first[#first + 1] = a end
  for _, a in ipairs(quest) do first[#first + 1] = a end
  return first
end

function LC.label(look)
  if look == nil or look == "" then return "default" end
  return (S.lstrip(look, "_"):gsub("_", " "))
end

LC.PAINT = true
LC.BUDGET = 0.006       -- seconds of a frame for the painting (the 3D views' 4 ms: a person's look took 2 s, 12.11.)
-- queue: what the grid shows, the last asked first; later: the looks of every person listed, in their order, painted
-- when nothing on screen waits (catalog_view.sync_rows). asked[key]: the job while it waits, true once begun.
local queue, later, later_at, asked, busy = {}, {}, 1, {}, false
local listeners = {}
local V3, MV
local own_cache = false         -- (meshview's part cache on for the painting: the looks of one person share files)
function LC.on_painted(fn) listeners[#listeners + 1] = fn end
-- (square: a thing's catalog picture, 200 x 200 - a content pack's, which REDkit drew none of)
function LC.want(template, look, low, square)
  if not LC.PAINT then return end
  look = look or ""
  local k = template .. "\1" .. look .. (square and "\1sq" or "")
  local was = asked[k]
  if was == true or (was and (low or not was.low)) then return end
  if was then was.gone = true end                -- (it waited behind; now on screen: to the front)
  local job = {template, look, low = low, square = square, key = k}
  asked[k] = job
  if low then later[#later + 1] = job else queue[#queue + 1] = job end
end
-- the next job: the grid's first, then the ones behind; a look painted before (its file there) is skipped
local function next_job(behind)
  for _ = 1, 64 do
    local job = table.remove(queue)
    if not job then
      if not behind then return nil end
      job = later[later_at]
      if not job then
        later, later_at = {}, 1
        return nil
      end
      later[later_at] = nil
      later_at = later_at + 1
    end
    if not job.gone then
      asked[job.key] = true
      if not w3.fs.exists(LC.cache_file(job[1], job[2], job.square)) then return job end
    end
  end
  return nil
end
local painter
-- each frame: the job going on goes on; when it is done the next (the last asked) begins - behind: the looks
-- waiting behind too (the panel shown; while playing only what a window shows)
function LC.tick(behind)
  if painter then painter:tick() end
  if busy then return end
  MV = MV or require("conjunction.meshview")
  local job = next_job(behind)
  if not job then
    if own_cache then MV.part_cache, own_cache = nil, false end
    return
  end
  if MV.part_cache == nil then MV.part_cache, own_cache = {files = {}, n = 0}, true end
  V3 = V3 or require("conjunction.ui.view3d")
  painter = painter or V3.new()
  painter.budget = LC.BUDGET
  local template, look, square = job[1], job[2], job.square
  busy = true
  painter:load(template .. "#" .. look, function()
    local ok, parts = pcall(function()
      local _, parts = MV.entity_parts(template, V3.depot(), {}, look ~= "" and look or nil)
      return parts
    end)
    return ok and parts or {}
  end, function(_, ok, parts)
    busy = false
    local path = ""
    if ok and type(parts) == "table" and #parts > 0 and painter:show_parts(parts) then
      painter.yaw, painter.pitch = 180.0, 0.0                  -- (from the front)
      if square then painter.yaw, painter.pitch = 215.0, 20.0 end   -- (a thing: from above at an angle)
      local file = LC.cache_file(template, look, square)
      local dir = file:match("^(.*)\\[^\\]+$")
      if dir and not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
      local g = function(v) return string.format("%.17g", v) end
      -- (TILE x 2, but MeshView's least size, 200 x 200, wins: 200 x 272)
      local tw, th = math.max(200, LC.TILE[1] * 2), math.max(200, LC.TILE[2] * 2)
      if square then tw, th = 200, 200 end
      local okr = pcall(w3.plugin.cj_qt_mesh_render, tostring(painter.mesh), tostring(tw), tostring(th),
                        g(painter.yaw), g(painter.pitch), g(painter.dist),
                        g(painter.center[1]), g(painter.center[2]), g(painter.center[3]), g(painter.radius), file)
      if okr then path = file end
      painter:free()
    end
    for _, fn in ipairs(listeners) do fn(template, look, path) end
  end, 256)
end

function LC.cache_file(template, look, square)
  local key = H.sha1(S.lower(template)):sub(1, 10)
  local base = PATHS.splitext(PATHS.basename((template:gsub("\\", "/"))))
  return PATHS.join(LC.CACHE, base .. "_" .. key, ((look ~= nil and look ~= "") and look or "_default") ..
                    (square and "_angled" or "") .. ".png")
end

return LC
