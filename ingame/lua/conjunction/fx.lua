-- The effects a template can play (fx.py): its CFXDefinition names ('teleport', 'fire', 'activate' ...), its includes'
-- too. The Effect step and the portal offer them instead of a typed name.
--   FX.effects_of(template) -> {"teleport", ...}   {} when it has none / is unknown / no game files
local CR = require("conjunction.cr2w")
local FX = {}

local cache = {}
local depot = nil

local function lower(s) return (s:gsub("%u", string.lower)) end

function FX.effects_of(template)
  local key = lower(template or "")
  if key == "" then return {} end
  if cache[key] == nil then
    local names, have = {}, {}
    local ok = pcall(function()
      depot = depot or require("conjunction.depot").open(require("conjunction.config").load().game)
      local seen, todo = {}, {key}
      while #todo > 0 do
        local t = table.remove(todo)
        if not seen[t] and depot:exists(t) then
          seen[t] = true
          for _, f in ipairs(CR.parts(depot:read(t))) do
            for _, e in ipairs(f.exports) do
              if e[1] == "CFXDefinition" then
                local chunk = e[5]
                for _, pr in ipairs(f:props(chunk)) do
                  if pr[1] == "name" and pr[2] == "CName" and pr[4] >= 2 then
                    local n = f.names[string.unpack("<H", chunk, pr[3] + 1) + 1]
                    if n and n ~= "" and not have[n] then
                      have[n] = true
                      names[#names + 1] = n
                    end
                  end
                end
              end
            end
            for _, im in ipairs(f.imports) do
              local p = lower(im[1])
              if p:sub(-6) == ".w2ent" then todo[#todo + 1] = p end
            end
          end
        end
      end
    end)
    cache[key] = ok and names or {}
  end
  return cache[key]
end

return FX
