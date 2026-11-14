-- Windows' own icons as Qt's dialogs show them (cj_core's cj_shell_icon: shellicons.cpp), each made once into
-- %TEMP%\cj_shell_icons and kept as a picture. Files share one icon per extension as Qt keeps them
-- (QWindowsFileIconEngine::cacheKey: not .exe, .lnk, .ico), a folder its own (it may have a custom icon).
--   SI.file(path, size) -> {id, w, h} | nil      SI.std("warning", 32) -> {id, w, h} | nil
--   SI.draw(ic, x, y)
local SI = {}
local D = w3.ui.draw
local cache = {}
local dir

local function folder()
  if not dir then
    dir = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\cj_shell_icons"
    if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
  end
  return dir
end
local function name_of(key)                 -- (a file name for the key: its djb2 hash and length)
  local h = 5381
  for i = 1, #key do h = (h * 33 + key:byte(i)) % 4294967296 end
  return string.format("%08x_%d", h, #key)
end

local function make(key, kind, what, size)
  local ic = cache[key]
  if ic ~= nil then return ic or nil end
  ic = false
  if w3.plugin and w3.plugin.cj_shell_icon then
    local out = folder() .. "\\" .. name_of(key) .. ".png"
    local ok, r = pcall(w3.plugin.cj_shell_icon, kind, what, tostring(size), out)
    if ok and type(r) == "string" and r:sub(1, 2) == "ok" then
      local id, w, h = w3.ui.image_load(out)
      if id then ic = {id = id, w = w, h = h, png = out} end
    end
  end
  cache[key] = ic
  return ic or nil
end

-- the file's icon as a PNG file (made if it is not there yet) -> its path, or nil
function SI.file_png(path, size)
  local ic = SI.file(path, size)
  return ic and ic.png or nil
end

function SI.file(path, size)
  size = size or 16
  local isdir = w3.fs.isdir(path)
  local key
  local ext = (not isdir) and path:match("%.([^.\\/]+)$") or nil
  local lext = ext and ext:lower()
  if isdir or path:match("^%a:[\\/]?$") or lext == "exe" or lext == "lnk" or lext == "ico" then
    key = "path:" .. path:lower()
  elseif ext then
    key = "ext:" .. ext:upper()
  else
    key = "name:" .. (path:match("([^\\/]+)$") or path)
  end
  return make(key .. ":" .. size, "file", path, size)
end
function SI.std(name, size)
  size = size or 16
  return make("std:" .. name .. ":" .. size, "std", name, size)
end
function SI.draw(ic, x, y)
  if ic then D.image(ic.id, x, y, ic.w, ic.h) end
end

return SI
