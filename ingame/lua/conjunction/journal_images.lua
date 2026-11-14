-- The game's journal portraits (journal_images.py): the image names of its character pages, read once from the game's
-- journal files and kept in Conjunction's folder (data\journal_portraits.json, as the app keeps it).
--   JI.portraits() -> {"journal_anabelle.png", ...}
local J = require("conjunction.json")
local PATHS = require("conjunction.paths")
local PS = require("conjunction.pysort")
local JI = {}

function JI.cache() return PATHS.DATA .. "\\journal_portraits.json" end

function JI.portraits()
  if w3.fs.exists(JI.cache()) then
    local ok, got = pcall(J.read, JI.cache())
    if ok and type(got) == "table" then return got end
  end
  local names = {}
  pcall(function()
    local CR = require("conjunction.cr2w")
    local d = require("conjunction.depot").open(require("conjunction.config").load().game)
    for _, p in ipairs(d:glob("gameplay\\journal\\characters\\", ".journal")) do
      local ok, f = pcall(function() return CR.parts(d:read(p))[1] end)
      if ok and f then
        for _, e in ipairs(f.exports) do
          if e[1] == "CJournalCharacter" then
            local chunk = e[5]
            for _, pr in ipairs(f:props(chunk)) do
              if pr[1] == "image" and pr[2] == "String" then
                local text = chunk:sub(pr[3] + 2, pr[3] + pr[4])      -- (Python: chunk[off + 1:off + sz])
                if not utf8.len(text) then text = text:gsub("[\128-\255]", "\239\191\189") end
                if text:sub(-4) == ".png" then names[text] = true end
              end
            end
          end
        end
      end
    end
  end)
  local out = {}
  for n in pairs(names) do out[#out + 1] = n end
  out = PS.sorted(out)
  if #out == 0 then out = {"journal_grandma.png"} end
  pcall(J.write, JI.cache(), out, {})
  return out
end

return JI
