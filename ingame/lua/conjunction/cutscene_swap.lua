-- cutscene_swap.py: a game cutscene replaced by another in every game scene that plays it - the scenes stay the
-- game's own, only the cutscene they point at changes. A scene plays a cutscene from a CStorySceneCutsceneSection
-- (its `cutscene`: a handle to an import); the cutscene names its actors and the scenes that play it (`usedInFiles`,
-- checked against the scenes' imports); its length is its animations'. Replaced: where the section's handle points
-- (an import of the new cutscene - the scene's own if it has one) and the length the scene gives its player
-- (`approvedDuration`). An own cutscene (a cooked .w2cutscene) plays the same way from its depot path.
--   CS.all_cutscenes(depot), CS.label(path), CS.depot_path(file), CS.info(depot, path, file),
--   CS.problems(depot, old, new, file), CS.swapped(depot, scene, changes, files) -> bytes, {old paths it had}
local CR = require("conjunction.cr2w")
local CE = require("conjunction.cr2w_edit")
local PS = require("conjunction.pysort")
local S = require("conjunction.pystr")
local CS = {}

local ALL
function CS.all_cutscenes(depot)
  if ALL == nil then ALL = PS.sorted(depot:glob("", ".w2cutscene")) end
  return ALL
end

-- 'animations\...\cs201_sex_with_yennefer.w2cutscene' -> 'cs201 sex with yennefer'
function CS.label(path)
  local base = path:match("([^\\]*)$")
  return (base:match("^(.*)%.[^.]*$") or base):gsub("_", " ")
end

-- an own cutscene's depot path: from its folder 'animations' on, else animations\cutscenes\conjunction\<its name>
function CS.depot_path(file)
  local parts = {}
  for x in file:gsub("/", "\\"):gmatch("[^\\]+") do parts[#parts + 1] = x end
  local last
  for i, x in ipairs(parts) do if S.lower(x) == "animations" then last = i end end
  if last then return table.concat(parts, "\\", last) end
  return "animations\\cutscenes\\conjunction\\" .. parts[#parts]
end

local INFO = {}
function CS.info(depot, path, file)
  local key = path .. "|" .. tostring(file)
  if INFO[key] then return INFO[key] end
  local f = CR.parse(file and assert(w3.fs.read(file)) or depot:read(path))
  local top = CE.decode(f, f.exports[1][5])
  local actors = {}
  for _, a in ipairs(type(top.actorsDef) == "table" and top.actorsDef or {}) do
    if (a.type or "CAT_Actor") == "CAT_Actor" and a.name and a.name ~= "" then actors[#actors + 1] = a.name end
  end
  local duration = 0.0
  for _, e in ipairs(f.exports) do
    if e[1] == "CSkeletalAnimation" then
      duration = math.max(duration, (tonumber(CE.decode(f, e[5]).duration) or 0.0) + 0.0)
    end
  end
  -- (the list is not kept up to date: the scenes that really import it)
  local scenes = {}
  if not file then
    for _, p in ipairs(type(top.usedInFiles) == "table" and top.usedInFiles or {}) do
      if depot:exists(p) then
        for _, im in ipairs(CR.parse(depot:read(p)).imports) do
          if S.lower(im[1]) == S.lower(path) then scenes[#scenes + 1] = p break end
        end
      end
    end
  end
  INFO[key] = {actors = actors, duration = duration, scenes = scenes}
  return INFO[key]
end

-- what may not fit when `new` plays where `old` did: people it has that `old` does not
function CS.problems(depot, old, new, file)
  local a, b = CS.info(depot, old), CS.info(depot, new, file)
  local have, extra = {}, {}
  for _, x in ipairs(a.actors) do have[x] = true end
  for _, x in ipairs(b.actors) do if not have[x] then extra[#extra + 1] = x end end
  if #extra == 0 then return {} end
  return {"it has " .. table.concat(extra, ", ") .. " - the scene has " ..
          (#a.actors > 0 and table.concat(a.actors, ", ") or "nobody")}
end

-- the scene with its cutscenes replaced ({old path: new path}; files {new path: file} for own ones) -> bytes, {the
-- old paths it had}
function CS.swapped(depot, scene_path, changes, files)
  local f = CR.parse(depot:read(scene_path))
  local low = {}
  for k, v in pairs(changes) do low[S.lower(k)] = v end
  local paths = {}
  for i, im in ipairs(f.imports) do paths[i] = S.lower(im[1]) end
  local hit, had = {}, {}
  for _, e in ipairs(f.exports) do
    if e[1] == "CStorySceneCutsceneSection" then
      local chunk = e[5]
      local at
      for _, p in ipairs(f:props(chunk)) do
        if p[1] == "cutscene" and p[4] == 4 then at = p[3] break end
      end
      local h = at and string.unpack("<i4", chunk, at + 1) or 0
      if h < 0 and -h - 1 < #f.imports then
        local old = f.imports[-h][1]
        local new = low[S.lower(old)]
        if new then
          local where
          for i, x in ipairs(paths) do if x == S.lower(new) then where = i break end end
          if not where then
            f.imports[#f.imports + 1] = {new, "CCutsceneTemplate", f.imports[-h][3]}
            paths[#paths + 1] = S.lower(new)
            where = #paths
          end
          e[5] = chunk:sub(1, at) .. string.pack("<i4", -where) .. chunk:sub(at + 5)
          if not had[old] then
            had[old] = true
            hit[#hit + 1] = old
          end
          -- its cutscene player gets the new one's length
          local sec = CE.decode(f, e[5])
          local length = CS.info(depot, new, (files or {})[new]).duration
          for _, el in ipairs(type(sec.sceneElements) == "table" and sec.sceneElements or {}) do
            local ex = type(el) == "table" and el[1] == "export" and f.exports[el[2]] or nil
            if ex and ex[1] == "CStorySceneCutscenePlayer" and length ~= 0 then
              local c = ex[5]
              local done = false
              for _, p in ipairs(f:props(c)) do
                if p[1] == "approvedDuration" and p[4] == 4 then
                  ex[5] = c:sub(1, p[3]) .. string.pack("<f", length) .. c:sub(p[3] + 5)
                  done = true
                  break
                end
              end
              if not done then
                local props = f:props(c)
                local e2 = #props > 0 and (props[#props][3] + props[#props][4]) or 1
                local add = string.pack("<I2I2I4", f:add_name("approvedDuration"), f:add_name("Float"), 8) ..
                            string.pack("<f", length)
                ex[5] = c:sub(1, e2) .. add .. c:sub(e2 + 1)
              end
            end
          end
        end
      end
    end
  end
  return f:save(), hit
end

return CS
