-- Qt's own painter for what the app draws with QPainter (cj_qt, ingame/plugin/cj_qt.cpp): a list of commands made
-- into a picture file, drawn 1:1 afterwards (text goes over it with w3.ui's Qt text).
--   local f = QP.paint(out, w, h, {"fill 1b1b1eff", "aa 1", "pen 333333ff 1", "brush 232326ff", "rect 3 3 106 134"})
-- Checked against PySide: ingame/ref/qt_paint_check.py.
local QP = {}

function QP.paint(out, w, h, cmds)
  local f = w3.plugin and w3.plugin.cj_qt_paint
  if not f then error("cj_qt is not loaded (tw3se\\plugins\\cj_qt.dll)", 2) end
  f(out, w, h, type(cmds) == "table" and table.concat(cmds, "\n") or cmds)
  return out
end

-- the picture of these commands in folder dir, named by their hash: painted only when that one is not there yet
-- (25.10.: after each game start every tile was painted again - 6 ms each, the first frame of a view 250 ms; Qt's
-- first picture of a session 500 ms more) -> its file, and an image id loaded from it (painted anew once if the kept
-- file does not load)
function QP.kept(dir, w, h, cmds)
  local text = type(cmds) == "table" and table.concat(cmds, "\n") or cmds
  local out = dir .. "\\" .. require("conjunction.hashlib").md5(w .. "x" .. h .. "\n" .. text) .. ".png"
  if not w3.fs.exists(out) then QP.paint(out, w, h, text) end
  local id, iw, ih = w3.ui.image_load(out)
  if not id then
    QP.paint(out, w, h, text)
    id, iw, ih = w3.ui.image_load(out)
  end
  return out, id, iw, ih
end

-- a colour 0xRRGGBBAA as the commands write it
function QP.hex(c) return string.format("%08x", c) end

return QP
