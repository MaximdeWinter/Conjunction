-- What a placed NPC does where it stands (conjunction/npc_actions.py): the game's work and idle actions (radish's
-- repo.quests/all.actions), sorted into standing / sitting / kneeling / lying and named in plain words; quest-only and
-- adult ones left out.
--   NA.label(job)            'stand_md_chopping_wood_jt' -> 'chopping wood'
--   NA.actions(gender)       {{posture label, {{"group/job", label}, ...}}, ...} for "man" or "woman"
--   NA.gender_of(template)   "woman" or "man"
local Y = require("conjunction.yaml")
local CFG = require("conjunction.config")
local PR = require("conjunction.pyre")
local PS = require("conjunction.pysort")
local S = require("conjunction.pystr")
local NA = {}

local SKIP = PR.compile("^(q\\d|mq|sq|bob|e3|poi|ep\\d|dlg)|sex|prostitute|flirt|nude|dancing_sexy")
local GROUPS = {man = {"idle_man", "work_man", "dining_man", "resting_man", "default_man"},
                woman = {"idle_woman", "work_woman", "dining_woman", "resting_woman", "default_man"}}
local POSTURE = {{"stand", "Standing"}, {"sit", "Sitting"}, {"kneel", "Kneeling"}, {"lie", "Lying"}}
local DROP = {jt = true, ap = true, m = true, w = true, mw = true, md = true, mwd = true, mwdc = true, mwc = true,
              d = true, i = true}
local cache = {}

local function split(s, sep)
  local out, i = {}, 1
  while true do
    local a, b = s:find(sep, i, true)
    if not a then out[#out + 1] = s:sub(i) break end
    out[#out + 1] = s:sub(i, a - 1)
    i = b + 1
  end
  return out
end
local function isdigit(w) return w ~= "" and w:match("^%d+$") ~= nil end

function NA.label(job)
  local words = {}
  for _, w in ipairs(split(job, "_")) do if not DROP[w] then words[#words + 1] = w end end
  local first = words[1]
  if first == "stand" or first == "stands" or first == "sit" or first == "kneel" or first == "lie" then
    table.remove(words, 1)
  end
  local keep = {}
  for _, w in ipairs(words) do if not isdigit(w) then keep[#keep + 1] = w end end
  local text = table.concat(keep, " ")
  if text == "" then text = job end
  return (text:gsub("  ", " "))
end

local function starts(s, p) return s:sub(1, #p) == p end

function NA.actions(gender)
  gender = gender or "man"
  if cache[gender] then return cache[gender] end
  local repo = {}
  local ok = pcall(function()
    local radish = CFG.load().radish
    local f = io.open(tostring(radish) .. "\\repo.quests\\all.actions.repo.yml", "rb")
    if not f then error("none") end
    local text = f:read("a")
    f:close()
    repo = Y.load(text).repository.actions or {}
  end)
  if not ok then repo = {} end
  local seen = {}
  local by = {stand = {}, sit = {}, kneel = {}, lie = {}}
  for _, group in ipairs(GROUPS[gender]) do
    local jobs = repo[group]
    if type(jobs) == "table" then
      for _, job in ipairs(Y.keys(jobs)) do
        if not SKIP:search(job) and not seen[job] then
          seen[job] = true
          local posture = "stand"
          for _, p in ipairs(POSTURE) do if starts(job, p[1]) then posture = p[1] break end end
          local list = by[posture]
          list[#list + 1] = {group .. "/" .. job, NA.label(job)}
        end
      end
    end
  end
  local out = {}
  for _, p in ipairs(POSTURE) do
    local list = by[p[1]]
    if #list > 0 then
      PS.sort(list, function(t) return t[2] end)
      out[#out + 1] = {p[2], list}
    end
  end
  cache[gender] = out
  return out
end

-- woman or man: by the body the catalog found in the template (woman_* / man_* meshes), else by words in the path
function NA.gender_of(template, assets)
  local row
  if assets then
    local ok, r = pcall(function() return assets:template(template) end)
    if ok then row = r end
  end
  local meshes = tostring((row or {}).meshes or "")
  if meshes:find("woman_", 1, true) or meshes:find("\\\\woman", 1, true) then return "woman" end
  if meshes:find("man_", 1, true) then return "man" end
  local t = S.lower(template)
  for _, w in ipairs({"woman", "female", "girl", "_f_", "wife", "lady"}) do
    if t:find(w, 1, true) then return "woman" end
  end
  return "man"
end

return NA
