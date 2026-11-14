-- Pictures as the app's Qt shows them: QPixmap(file).scaled(box, KeepAspectRatio, SmoothTransformation) drawn onto
-- a known colour - made by cj_core (Qt's own smooth scaling and blending, cj_img_qt) into a file kept in the temp
-- folder, then drawn 1:1. Checked against PySide: ingame/ref/qt_scale_check.py.
--   local f, w, h = PIC.scaled(file, box_w, box_h, bg)    bg: 0xRRGGBBAA of what it lies on (nil: its transparency)
--   local id, w, h = PIC.texture(file, box_w, box_h, bg)  the same, loaded for w3.ui.draw.image
local H = require("conjunction.hashlib")
local PIC = {}
local made, textures = {}, {}

local function dir()
  local d = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\cj_core\\pictures"
  if not w3.fs.isdir(d) then w3.fs.mkdir(d) end
  return d
end

-- QSize::scaled(box, Qt::KeepAspectRatio), then QPixmap::scaled's at least 1 x 1
function PIC.keep_aspect(w, h, bw, bh)
  if w == 0 or h == 0 then return math.max(bw, 1), math.max(bh, 1) end
  local rw = bh * w // h
  local nw, nh
  if rw <= bw then nw, nh = rw, bh else nw, nh = bw, bw * h // w end
  return math.max(nw, 1), math.max(nh, 1)
end

-- (kept per file: the inspector's icons asked every frame, 23.10.)
local sizes = {}
function PIC.size(file)
  local s = sizes[file]
  if s then return s[1], s[2] end
  local r = w3.plugin.cj_img_size(file)
  local w, h = r:match("^(%d+)\t(%d+)$")
  w, h = tonumber(w), tonumber(h)
  if w and h then sizes[file] = {w, h} end
  return w, h
end

function PIC.scaled(file, bw, bh, bg)
  local key = table.concat({file, bw, bh, bg and string.format("%08x", bg) or "-"}, "|")
  local m = made[key]
  if m then return m[1], m[2], m[3] end
  local w, h = PIC.size(file)
  local nw, nh = PIC.keep_aspect(w, h, bw, bh)
  local out = dir() .. "\\" .. H.md5(key) .. ".png"
  w3.plugin.cj_img_qt(file, out, nw, nh, bg and string.format("%06x", bg >> 8) or "")
  made[key] = {out, nw, nh}
  return out, nw, nh
end

function PIC.texture(file, bw, bh, bg)
  local out, w, h = PIC.scaled(file, bw, bh, bg)
  local t = textures[out]
  if not t then
    t = {w3.ui.image_load(out)}
    textures[out] = t
  end
  return t[1], w, h
end

return PIC
