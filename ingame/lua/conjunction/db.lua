-- SQLite through cj_core (ingame/plugin/cj_core.cpp): Python's sqlite3 as the app uses it, the same version and options.
--
--   local db = DB.open(path, true)          true: read into memory, the file let go (assets.Assets)
--   local db = DB.open(path, "write")       read and written, made when it is not there
--   local rows = db:rows(sql, a, b ...)      each row a map by column name and a list (row[1] ...), NULL as Y.null
--   local n = db:exec(sql, a, b ...)         the rows changed
--   db:close()
-- A parameter goes as its Lua type: an integer (math.type), a float, a string, nil or Y.null for NULL; true and
-- false as 1 and 0 (sqlite3 binds Python's bools so).
local Y = require("conjunction.yaml")
local DB = {}
DB.__index = DB

local function plugin(name)
  local p = w3.plugin and w3.plugin[name]
  if not p then error("cj_core is not loaded (tw3se\\plugins\\cj_core.dll): no w3.plugin." .. name, 3) end
  return p
end

local function param(v)
  if v == nil or v == Y.null then return "n" end
  local t = type(v)
  if t == "boolean" then return v and "i:1" or "i:0" end
  if t == "number" then
    if math.type(v) == "integer" then return "i:" .. string.format("%d", v) end
    return "r:" .. string.format("%.17g", v)
  end
  if t == "string" then return "s:" .. v end
  error("db: a parameter of type " .. t, 3)
end

local function params(...)
  local out = {}
  for i = 1, select("#", ...) do out[i] = param((select(i, ...))) end
  return table.unpack(out)
end

function DB.open(path, memory)
  local id = plugin("cj_db_open")(path, memory == "write" and "write" or memory and "memory" or "file")
  return setmetatable({id = id}, DB)
end

function DB:exec(sql, ...)
  return tonumber(plugin("cj_db_exec")(self.id, sql, params(...)))
end

-- the rows: the chunk cj_core wrote, loaded with Y.null for NULL
function DB:rows(sql, ...)
  local reply = plugin("cj_db_query")(self.id, sql, params(...))
  local src = reply
  if reply:sub(1, 7) ~= "local N" then src = w3.fs.read(reply:match("^(.-)\t")) end   -- (an older TW3SE: a file)
  local chunk, err = load(src, "=cj_db_query", "t", {})
  if not chunk then error("db: " .. tostring(err), 2) end
  local cols, rows = chunk(Y.null)
  for _, r in ipairs(rows) do
    for c, name in ipairs(cols) do r[name] = r[c] end
  end
  return rows, cols
end

-- the first row or nil (sqlite3's fetchone)
function DB:one(sql, ...)
  return (self:rows(sql, ...))[1]
end

function DB:close()
  if self.id then plugin("cj_db_close")(self.id) end
  self.id = nil
end

return DB
