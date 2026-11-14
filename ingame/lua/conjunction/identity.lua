-- Profiles (identity.py): who made something with Conjunction - a display name and an ed25519 key pair of its own,
-- one file in Documents\Conjunction\identity (<slug>.cjkey) its owner keeps and never posts. Several profiles may be
-- there (each its own key); the config's "profile" says which signs ("none": signing is off). The key lives in
-- cj_core (crypto.cpp), the private seed never leaves this module but to sign.
--   ID.profiles() -> {profile}   ID.active() -> profile|nil   ID.create(name) -> profile (made active)
--   p.name, p.public (hex), p.path, p.id   p:sign(text) -> hex   p:project_seed(uid) -> hex   p:rename(name)
--   ID.set_active(p|nil)   ID.add_file(path) -> profile   ID.verify(public_hex, text, signature_hex) -> bool
local Y = require("conjunction.yaml")
local PATHS = require("conjunction.paths")
local PYS = require("conjunction.pystr")
local ID = {}

ID.EXT = ".cjkey"
ID.HEAD = "# Conjunction profile key. This file is you: what you make with Conjunction is signed with it.\n" ..
          "# Keep it safe. On a new PC copy it into Documents\\Conjunction\\identity.\n" ..
          "# Never post it or send it to anyone: whoever has this file can sign as you.\n"
ID.NONE = "none"

function ID.folder() return PATHS.IDENTITY end

-- --- base64 (the key file's "private")
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(raw)
  local out = {}
  for i = 1, #raw, 3 do
    local a, b, c = raw:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    out[#out + 1] = B64:sub((n >> 18) + 1, (n >> 18) + 1) .. B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1) ..
                    (b and B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "=") ..
                    (c and B64:sub((n & 63) + 1, (n & 63) + 1) or "=")
  end
  return table.concat(out)
end
local function b64decode(s)
  s = s:gsub("[^%w%+/=]", "")
  local out = {}
  for i = 1, #s, 4 do
    local q = s:sub(i, i + 3)
    local n, pad = 0, 0
    for k = 1, 4 do
      local ch = q:sub(k, k)
      local v = 0
      if ch == "=" or ch == "" then pad = pad + 1 else v = B64:find(ch, 1, true) - 1 end
      n = (n << 6) | v
    end
    out[#out + 1] = string.char((n >> 16) & 255)
    if pad < 2 then out[#out + 1] = string.char((n >> 8) & 255) end
    if pad < 1 then out[#out + 1] = string.char(n & 255) end
  end
  return table.concat(out)
end
ID.b64encode, ID.b64decode = b64encode, b64decode
local function hex(raw) return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function unhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end

-- --- a profile
local Profile = {}
Profile.__index = Profile
function ID.read(path)
  local d = Y.read(path)
  if type(d) ~= "table" then error("identity: " .. path .. " is no key file") end
  local priv = b64decode(tostring(d.private or ""))
  if #priv ~= 32 then error("identity: " .. path .. ": the key is not 32 bytes") end
  local self = setmetatable({path = path, name = tostring(d.name or ""), created = tostring(d.created or "")}, Profile)
  self._seed = hex(priv)
  self.public = w3.plugin.cj_ed25519_public(self._seed)
  self.id = PATHS.splitext(PATHS.basename(path))
  return self
end
function Profile:sign(text) return w3.plugin.cj_ed25519_sign(self._seed, text) end
-- this profile's seed for one project: its signature of the project's uid (hex)
function Profile:project_seed(uid) return self:sign("cj-mark/1|" .. tostring(uid)) end
local function write(path, name, created, seed_hex)
  local body = ID.HEAD .. Y.dump(Y.map({"name", name, "created", created, "private", b64encode(unhex(seed_hex))}),
                                 {sort_keys = false, allow_unicode = true})
  local dir = PATHS.dirname(path)
  if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
  assert(w3.fs.write(path .. ".tmp", (body:gsub("\n", "\r\n"))))   -- (Python's text mode: CRLF)
  w3.fs.remove(path)
  assert(w3.fs.rename(path .. ".tmp", path))
end
function Profile:rename(name)
  local n = (name or ""):match("^%s*(.-)%s*$")
  write(self.path, n ~= "" and n or self.name, self.created, self._seed)
  if n ~= "" then self.name = n end
end

function ID.profiles()
  local d = ID.folder()
  local names = {}
  for _, e in ipairs(w3.fs.isdir(d) and w3.fs.list(d) or {}) do
    if not e.dir and PYS.lower(e.name):sub(-#ID.EXT) == ID.EXT then names[#names + 1] = e.name end
  end
  table.sort(names)
  local out = {}
  for _, n in ipairs(names) do
    local ok, p = pcall(ID.read, d .. "\\" .. n)
    if ok then out[#out + 1] = p else print("[identity] " .. n .. ": " .. tostring(p)) end
  end
  return out
end

function ID.active()
  local ps = ID.profiles()
  local want = require("conjunction.config").load().profile
  want = type(want) == "string" and want or ""
  if #ps == 0 or want == ID.NONE then return nil end
  for _, p in ipairs(ps) do if p.id == want then return p end end
  return ps[1]
end
function ID.set_active(p)
  local CFG = require("conjunction.config")
  local cfg = CFG.load()
  cfg.profile = p and p.id or ID.NONE
  CFG.save(cfg)
end

local function slug(name)
  local s = PYS.lower(name):gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  s = s:sub(1, 24)
  return s ~= "" and s or "profile"
end
function ID.create(name)
  local seed = w3.plugin.cj_random("32")
  local base = ID.folder() .. "\\" .. slug(name)
  local path, n = base .. ID.EXT, 2
  while w3.fs.exists(path) do path, n = base .. "_" .. n .. ID.EXT, n + 1 end
  write(path, (name:match("^%s*(.-)%s*$")), os.date("%Y-%m-%dT%H:%M:%S"), seed)
  local p = ID.read(path)
  ID.set_active(p)
  return p
end

-- a key file from another PC into the identity folder (the same key twice is kept once)
function ID.add_file(src)
  local p = ID.read(src)
  for _, q in ipairs(ID.profiles()) do if q.public == p.public then return q end end
  local dst = ID.folder() .. "\\" .. PATHS.basename(src)
  local base, n = (PATHS.splitext(dst)), 2
  while w3.fs.exists(dst) do dst, n = base .. "_" .. n .. ID.EXT, n + 1 end
  if not w3.fs.isdir(ID.folder()) then w3.fs.mkdir(ID.folder()) end
  assert(w3.fs.write(dst, assert(w3.fs.read(src))))
  return ID.read(dst)
end

function ID.verify(public_hex, text, signature_hex)
  local ok, r = pcall(w3.plugin.cj_ed25519_verify, public_hex, text, signature_hex)
  return ok and r == "1"
end

return ID
