-- The Asset Browser as the app shows it in the panel (conjunction/catalog_view.py's CatalogView): the search, the tabs,
-- the type tree, the crumb with its buttons, the style and trait chips, the grid of tiles (or the Details table), the
-- count. The logic is catalog_model.lua's; this lays it out as Qt does and draws it. What the app paints itself with
-- QPainter (a tile's frame, its folder tab, picture, badges) Qt paints here too (cj_qt, ui/qtpaint.lua); the text is
-- w3.ui's Qt text over it.
--   local cv = CV.new(ed, assets)       cv:frame(page) every frame (page: the panel's tab page)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local L = require("conjunction.ui.layout")
local CT = require("conjunction.ui.controls")
local QP = require("conjunction.ui.qtpaint")
local PIC = require("conjunction.ui.pictures")
local H = require("conjunction.hashlib")
local S = require("conjunction.pystr")
local M = require("conjunction.catalog_model")
local LC = require("conjunction.look_chooser")
local ASSETS = require("conjunction.assets")
local PATHS = require("conjunction.paths")
local IV = require("conjunction.ui.itemview")
local PARTS = require("conjunction.parts.parts")
local SBAR = require("conjunction.ui.scrollbar")
local D = w3.ui.draw
local CV = {}
CV.__index = CV

local function rgba(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
CV.C = {
  grid_bg = rgba("#1b1b1e"), grid_edge = rgba("#333333"),
  tree_bg = rgba("#1c1c1f"), tree_edge = rgba("#333333"), tree_text = rgba("#dddddd"), tree_hover = rgba("#29292d"),
  tree_chosen = rgba("#4b4b50"), tree_count = rgba("#888888"), tree_count_sub = rgba("#777777"),
  tree_hidden = rgba("#777777"),
  mini_text = rgba("#cccccc"), mini_bg = rgba("#262629"), mini_edge = rgba("#444444"),
  mini_on_bg = rgba("#4b4b50"), mini_on_edge = rgba("#c8c8c8"), mini_on_text = rgba("#ffffff"),
  crumb = rgba("#aaaaaa"), count = rgba("#888888"),
  title = rgba("#eeeeee"), sub = rgba("#8a8a8a"), dots = rgba("#555555"), pill_text = rgba("#1d1d1f"),
  pill = rgba("#e3c65f"),
}
local C = CV.C
-- a tile's colours by its state (Tile._frame, the folder's own)
local FRAME = {normal = {"333333", "232326"}, hover = {"555555", "232326"}, chosen = {"c8c8c8", "4b4b50"},
               folder = {"a8924f", "2a261b"}, folder_chosen = {"e3c65f", "3a3322"}}
local PT = 11.33                       -- 8.5 pt: the tiles' text (Qt's pixel size of it)

local function tmp_dir(sub)
  local d = (os.getenv("TEMP") or ".") .. "\\cj_core\\" .. sub
  if not w3.fs.isdir(d) then w3.fs.mkdir(d) end
  return d
end

-- opts: width, choice (the model's); host (its hit boxes and menus: the panel, or a window's body); ids (its
-- controls' ids, "panel.cat." in the panel); no_tabs (the tab bar hidden: an item window's)
function CV.new(ed, assets, opts)
  opts = opts or {}
  local self = setmetatable({ed = ed, assets = assets}, CV)
  self.host = opts.host
  self.ids = opts.ids or "panel.cat."
  self.search_id, self.grid_id = self.ids .. "search", self.ids .. "grid"
  self.no_tabs = opts.no_tabs
  -- (inside the quest board - its 'Place new ...' chooser - the board's sheet reaches it: Filters is a QToolButton#chip
  -- and gets the board's chip, #262629 with a #555 border, padding 2px 8px, 12 px #cfcfcf; checked #4b4b50 #c8c8c8 white)
  self.board_chip = opts.board_chip
  self.model = M.new(assets, opts)
  -- the scroll bars (ui/itemview.lua's): the grid's two, the table's, the type tree's
  self.vbar, self.hbar, self.tbar, self.trbar = IV.bar(), IV.bar(), IV.bar(), IV.bar()
  self.cur, self.tcur = nil, nil       -- the grid's and the table's current row (each view has its own)
  self.hover = nil
  self.on_current, self.on_chosen = nil, nil   -- (the panel's: the inspector shows it / it is placed)
  LC.on_painted(function(t, lk) self:look_painted(t, lk) end)
  self.tiles = {}                      -- tile picture files made: key -> {id, w, h}
  self.pictures = {}                   -- entry key @ size -> picture file or false
  return self
end

-- --- the pictures (entry_picture, as far as the app has kept them) ---
local function exists(f) return f ~= nil and w3.fs.exists(f) end
local function mosaic_file(files, size)
  return PATHS.join(ASSETS.THUMBS, "folders", tostring(size), H.md5(table.concat(files, "|")):sub(1, 16) .. ".png")
end
-- a folder's mosaic not made yet (catalog_view.folder_picture / mosaic): its pictures - the first different ones
-- of up to 16 members, at most four - made into it on cj_core's thread (cj_mosaic_async, Pillow's arithmetic); the
-- pictures asked again when it is there (poll_mosaics, each frame)
function CV:make_mosaic(out, files, px)
  self.mosaics = self.mosaics or {}
  if self.mosaics[out] ~= nil then return end
  if #files == 0 then self.mosaics[out] = false return end
  self.mosaics[out] = "busy"
  w3.plugin.cj_mosaic_async(out, tostring(px), table.unpack(files, 1, math.min(4, #files)))
end
-- (-> nil while one of them is still being made: which four are the first different ones is known after)
function CV:folder_files(members, px)
  local files, seen = {}, {}
  for i = 1, math.min(16, #members) do
    local p, pending = self.assets:thumbnail(members[i], px)
    if pending then return nil end
    if p then
      local data = w3.fs.read(p)                  -- (the same picture twice: once - by its bytes)
      if data and not seen[data] then
        seen[data] = true
        files[#files + 1] = p
      end
    end
    if #files == 4 then break end
  end
  return files
end
function CV:poll_mosaics()
  for out, state in pairs(self.mosaics or {}) do
    if state == "busy" then
      local answer = w3.plugin.cj_mosaic_status(out)
      if answer ~= "busy" then
        self.mosaics[out] = answer == "ok"
        if answer:sub(1, 1) == "!" then print("[conjunction] a folder's picture: " .. answer:sub(2)) end
        self.pictures = {}                        -- (which entries it is for: any of them - asked again)
      end
    end
  end
end

-- look_painted: a look's tile was drawn - its entry's and its folder's pictures are made again
function CV:look_painted(template, look)
  for _, size in ipairs({64, 128, 320}) do
    for _, k in ipairs({template .. "#" .. look .. "@" .. size, template .. "@" .. size}) do
      self.pictures[k] = nil
    end
  end
end

function CV:picture(e, size)
  local key = e.key .. "@" .. size
  local p = self.pictures[key]
  if p ~= nil then return p or nil end
  local px = size <= 128 and 128 or 320
  local f
  if e.type == "item" then
    local pending
    f, pending = self.assets:icon(e.row)
    if pending then return nil end                -- (being made from the game's textures: asked again next frame)
  elseif e.members and #e.members > 0 then
    f = mosaic_file(e.members, px)
    if not exists(f) then
      local files = self:folder_files(e.members, px)
      if not files then return nil end            -- (its members' pictures being made: asked again next frame)
      self:make_mosaic(f, files, px)
      f = nil
    end
  elseif e.look ~= nil then
    f = LC.cache_file(e.path, e.look)
    if not exists(f) then
      LC.want(e.path, e.look)                     -- (LookPainter draws it; look_painted makes the picture again)
      f = nil
    end
  else
    if e.looks and #e.looks > 0 then
      local have = {}
      for k, lk in ipairs(e.looks) do
        local c = LC.cache_file(e.path, lk)
        if exists(c) then have[#have + 1] = c elseif k <= 4 then LC.want(e.path, lk) end
      end
      if #have >= math.min(2, #e.looks) then
        local four = {}
        for i = 1, math.min(4, #have) do four[i] = have[i] end
        f = mosaic_file(four, px)
        if not exists(f) then
          self:make_mosaic(f, have, px)
          f = nil
        end
        self.pictures[key] = f or false
        return f
      end
    end
    local pending
    f, pending = self.assets:thumbnail(e.mesh or e.path, px)
    if pending then return nil end                -- (being made from REDkit's picture: asked again next frame)
  end
  -- (a file Qt cannot read stays without a picture, "..." as the app shows it: the item icons the app kept as .dds -
  -- Pillow wrote them as DDS, which the app's Qt has no reader for)
  if f and not pcall(PIC.size, f) then f = nil end
  self.pictures[key] = f or false
  return f
end

-- --- Qt's text helpers ---
-- QFontMetrics::elidedText (QTextEngine::elidedText): letter by letter, each with its kerning, until the width less
-- the ellipsis is reached; the letter that reaches it goes too
CV.elide = Q.elide          -- (Qt's elidedText: ui/qt.lua)

-- --- the layout (QVBoxLayout 0 6 0 0: the search, the tabs, the body; the body: the tree and the right column) ---
local function mini_size(text, icon)
  if icon then return 14 + 17, 14 + 9 end
  return Q.hint_w(text, 12) + 2 * Q.text_w(" ", 12) + 17, Q.line_h(12) + 9
end
local function chip_default_size(text)     -- a QToolButton without a sheet of its own (Filters): Qt's native look
  return Q.hint_w(text, 12) + 2 * Q.text_w(" ", 12) + 3, Q.line_h(12) + 3
end

-- a chip (the CHIP sheet: 11 px, padding 2px 8px, a 1 px border): its text as Qt shows it ("&&" is one "&")
function CV.chip_label(text) return (text:gsub("&&", "&")) end
function CV.chip_size(text)
  local s = CV.chip_label(text)
  return Q.hint_w(s, 11) + 2 * Q.text_w(" ", 11) + 16 + 2 + 3, Q.line_h(11) + 4 + 2 + 3
end

function CV:layout(page)
  local m = self.model
  m:set_width(page.w)
  local lay = {page = page}
  local x, y, w = page.x, page.y + 6, page.w
  lay.search = {x = x, y = y, w = w, h = CT.edit_h()}
  y = y + lay.search.h + 6
  lay.tab_rects = {}
  if not self.no_tabs then
    local _, th = Q.tab_size("Objects", 12)
    lay.tabs = {x = x, y = y, w = w, h = th}
    local tx = x
    for i, t in ipairs(M.TABS) do
      local tw = Q.tab_size(t, 12)
      lay.tab_rects[i] = {x = tx, y = y, w = tw, h = th}
      tx = tx + tw
    end
    y = y + th + 6
  end
  local body = {x = x, y = y, w = w, h = page.y + page.h - y}
  lay.body = body
  local rx, rw = body.x, body.w
  if m.tree_shown then
    local tw = m.tree_full and body.w or 196
    lay.tree = {x = body.x, y = body.y, w = tw, h = body.h}
    rx, rw = body.x + tw + 6, body.w - tw - 6
  end
  if m.tree_full then return lay end
  -- the crumb row: nav, crumb (stretch), Filters, view, sort; Qt's 4 between (the right column's)
  local row = {}
  if m.nav_shown then
    local nw, nh = mini_size(nil, true)
    row[#row + 1] = {hint = nw, min = nw, max = nw, cross = nh, cross_max = nh, key = "nav"}
  end
  row[#row + 1] = {hint = 0, min = 40, stretch = 1, cross_max = L.BIG, key = "crumb"}
  if m.filter_shown then
    local fw, fh = chip_default_size(m.filter_text)
    if self.board_chip then fw, fh = fw + 16 + 2, fh + 4 + 2 end
    row[#row + 1] = {hint = fw, min = fw, max = fw, cross = fh, cross_max = fh, key = "filter"}
  end
  local vw, vh = mini_size(m.view_text)
  row[#row + 1] = {hint = vw, min = vw, max = vw, cross = vh, cross_max = vh, key = "view"}
  local sw, sh = mini_size(m.sort_text)
  row[#row + 1] = {hint = sw, min = sw, max = sw, cross = sh, cross_max = sh, key = "sort"}
  local rh = 0
  for _, it in ipairs(row) do rh = math.max(rh, it.cross or 0) end
  local placed = L.row(row, rx, body.y, rw, rh, {spacing = 4})
  lay.row = {}
  for i, it in ipairs(row) do lay.row[it.key] = placed[i] end
  y = body.y + rh + 4
  -- the style and the trait chips (Flow: rows that wrap, 4 apart; the hidden ones take no room)
  lay.chips = {}
  if m.boxes_shown then
    for _, group in ipairs({m.style_chips or {}, m.trait_chips or {}, "quest"}) do
      if group == "quest" then
        group = nil
      else
        local list = {}
        for _, ch in ipairs(group) do if ch.visible then list[#list + 1] = ch end end
        if group == m.trait_chips then
          list[#list + 1] = {key = "quest", text = "+ quest things", checked = m.quest, quest = true}
        end
        local which = group == m.trait_chips and "traits" or "styles"
        local cx, cy, line = rx, y, 0
        for _, ch in ipairs(list) do
          local cw, chh = CV.chip_size(ch.text)
          if cx + cw > rx + rw - 1 and line > 0 then cx, cy, line = rx, cy + line + 4, 0 end
          lay.chips[#lay.chips + 1] = {x = cx, y = cy, w = cw, h = chh, chip = ch, which = which}
          cx = cx + cw + 4
          line = math.max(line, chh)
        end
        y = cy + line + 4
      end
    end
  end
  local count_h = Q.line_h(13)
  lay.grid = {x = rx, y = y, w = rw, h = body.y + body.h - count_h - 4 - y}
  lay.count = {x = rx, y = body.y + body.h - count_h, w = rw, h = count_h}
  return lay
end

-- --- the grid (a QListView: IconMode, or ListMode for the List view; ui/itemview.lua is Qt's layout of it) ---
function CV:tile_size()
  local mode = self.model.mode
  if mode == "small" then return 236, 40 end
  if mode == "list" then return 250, 24 end
  if mode == "tiles" then return 300, 80 end
  local t = M.VIEW_SIZE[mode]
  return t + 16, t + 44
end

-- the grid's geometry for its frame g: the viewport, Qt's layout of the items shown, the scroll bars' steps (kept in
-- self.vbar / self.hbar, their values bounded as Qt's setRange bounds them)
function CV:grid_geom(g)
  local m = self.model
  local key = table.concat({m.mode, m.shown, g.x, g.y, g.w, g.h, tostring(m.rows)}, "|")
  local G = self.G
  if not (G and G.key == key) then
    local tw, th = self:tile_size()
    local W, H = g.w - 2, g.h - 2
    if m.mode == "list" then
      -- (the layout leaves room for the sideways bar; the items' height decides how many go in a column)
      G = IV.list_layout(m.shown, tw, th, 1, H - 10)
      G.vw = W
      G.vh = G.cw > W and H - 10 or H
      local sp = G.seg_pos
      local page = G.cw <= G.vw and #sp or (G.vw // sp[2])    -- (perItemScrollingPageSteps, uniform sizes)
      G.hpage, G.hmax, G.vmax = page, math.max(0, (#sp - 1) - page), 0
    else
      -- (LeftToRight: the bar's room is kept at the right whether it shows or not)
      G = IV.icon_layout(m.shown, tw, th, 2, W - 10)
      G.vh = H
      G.vw = G.ch > H and W - 10 or W
      G.vmax, G.hmax = math.max(0, G.ch - H), 0
      G.vsingle = th + 2
    end
    G.key, G.x, G.y = key, g.x + 1, g.y + 1
    self.G = G
  end
  local vb, hb = self.vbar, self.hbar
  if G.kind == "list" then vb.single, vb.page = 25, G.vh hb.single, hb.page = 1, G.hpage
  else vb.single, vb.page = G.vsingle, G.vh hb.single, hb.page = G.tw + 2, G.vw end
  if IV.range(vb, G.vmax) then self:scrolled(vb) end
  if IV.range(hb, G.hmax) then self:scrolled(hb) end
  return G
end
-- the contents' x at the viewport's left (ListMode scrolls by columns: the column's start)
function CV:hoff(G)
  if G.kind ~= "list" then return 0 end
  return G.seg_pos[math.max(0, math.min(self.hbar.value, #G.seg_pos - 2)) + 1]
end

-- one tile as the app's Tile.paint draws it (icon modes): its picture file (made once per look) and the texts on it
function CV:tile_picture(e, state, tw, th)
  local m = self.model
  local folder = M.is_folder(e)
  local frame = folder and (state == "chosen" and FRAME.folder_chosen or FRAME.folder) or FRAME[state]
  local size = M.VIEW_SIZE[m.mode]
  local pic = self:picture(e, size > 128 and 320 or 128)
  local voice = M.voice_of(e)
  local clue = false
  for _, t in ipairs((e.row or {}).traits or {}) do if t == "clue" then clue = true end end
  local key = table.concat({m.mode, state, e.key, tostring(pic), tostring(e.fav), tostring(voice), tostring(clue),
                            tostring(M.folder_count(e)), tw, th}, "|")
  local t = self.tiles[key]
  if t then return t end
  -- r = option.rect.adjusted(3, 3, -3, -3) in the tile's own pixels
  local rx, ry, rw, rh = 3, 3, tw - 6, th - 6
  local cmds = {"fill " .. QP.hex(C.grid_bg), "aa 1", "pen " .. frame[1] .. "ff 1", "brush " .. frame[2] .. "ff"}
  if folder then
    local tab_x = rx + rw * 2 // 5
    cmds[#cmds + 1] = string.format("poly %d %d %d %d %d %d %d %d", rx, ry + 7, rx + 4, ry, tab_x, ry, tab_x + 7, ry + 7)
    ry, rh = ry + 7, rh - 7
  end
  cmds[#cmds + 1] = string.format("rect %d %d %d %d", rx, ry, rw, rh)
  local box_size = size - (folder and 8 or 0)
  local bx, by = rx + (rw - box_size) // 2, ry + 4
  local texts = {}
  local fill = frame[2]
  if pic then
    local pw, ph = PIC.size(pic)
    local sw, sh = PIC.keep_aspect(pw, ph, box_size, box_size)
    cmds[#cmds + 1] = string.format("image %d %d %d %d %s", bx + (box_size - sw) // 2, by + (box_size - sh) // 2,
                                    sw, sh, pic)
  else
    texts[#texts + 1] = {"dots", bx, by, box_size}
  end
  if e.fav then
    cmds[#cmds + 1] = string.format("image %d %d 0 0 %s\\icons\\star_on_at18.png", rx + rw - 1 - 22, ry + 4, Q.root)
  end
  if clue then
    cmds[#cmds + 1] = string.format("image %d %d 0 0 %s\\icons\\scan-eye_d9534f_16.png", rx + rw - 1 - 21,
                                    ry + rh - 1 - 62, Q.root)
  end
  local pill
  if folder then
    local n = tostring(M.folder_count(e))
    local pw = Q.text_w(n, PT, true) + 12
    pill = {bx + box_size - 1 - pw - 2, by + box_size - 1 - 20, pw, 18, n}
    cmds[#cmds + 1] = "nopen"
    cmds[#cmds + 1] = "brush " .. QP.hex(C.pill)
    cmds[#cmds + 1] = string.format("rrect %d %d %d %d 9 9", pill[1], pill[2], pill[3], pill[4])
  end
  if voice then
    local bsz, x0, y0 = 18, rx + 5, ry + 5
    local pad = math.max(2, bsz // 6)
    cmds[#cmds + 1] = "nopen"
    cmds[#cmds + 1] = "brush 141416aa"
    cmds[#cmds + 1] = string.format("rrectf %d %d %d %d %d %d", x0 - pad, y0 - pad, bsz + 2 * pad, bsz + 2 * pad, pad + 1, pad + 1)
    local name = voice == "none" and "audio-lines-x" or "audio-lines"
    cmds[#cmds + 1] = string.format("image %d %d 0 0 %s\\icons\\%s_%s_18.png", x0, y0, Q.root, name,
                                    M.VOICE_COLOUR[voice]:sub(2))
  end
  local _, id, iw, ih = QP.kept(tmp_dir("tiles"), tw, th, cmds)
  t = {id = id, w = iw, h = ih, texts = texts, pill = pill, fill = rgba("#" .. fill), box = {bx, by, box_size}}
  self.tiles[key] = t
  return t
end

-- QPainter::drawText's centring: half the room as a real number, the glyphs then put on the pixel rounded up from .5
local function half(room) return (room + 1) // 2 end

function CV:draw_tile(e, x, y, tw, th, state)
  local t = self:tile_picture(e, state, tw, th)
  if t.id then D.image(t.id, x, y, t.w, t.h) end
  local bx, by, bs = t.box[1], t.box[2], t.box[3]
  for _, tx in ipairs(t.texts) do
    if tx[1] == "dots" then          -- (no picture: "..." centred in the box, the grid's 12 px)
      local s = "..."
      local lh = Q.line_h(12)
      Q.text(x + bx + (bs - Q.text_w(s, 12)) // 2, y + by + half(bs - lh), C.dots, s, 12, false, t.fill)
    end
  end
  -- the title and the line below it (8.5 pt), centred
  local folder = M.is_folder(e)
  local rx, rw = 3, tw - 6
  local w = rw - 8
  local line = Q.line_h(PT)
  local ty = by + bs - 1 + 3
  local title = CV.elide(e.title or "", "right", w, PT, false)
  Q.text(x + rx + 4 + (w - Q.text_w(title, PT)) // 2, y + ty, C.title, title, PT, false, t.fill)
  if e.sub and e.sub ~= "" then
    local sub = CV.elide(e.sub, "middle", w, PT, false)
    Q.text(x + rx + 4 + (w - Q.text_w(sub, PT)) // 2, y + ty + line, e.sub_colour or C.sub, sub, PT, false, t.fill)
  end
  if t.pill then
    local p = t.pill
    Q.text(x + p[1] + (p[3] - Q.text_w(p[5], PT, true)) // 2, y + p[2] + half(p[4] - line), C.pill_text, p[5], PT,
           true, C.pill)
  end
  local _ = folder
end

-- small / list / tiles: the picture on the left, the words beside it (Tile._row, no antialiasing)
function CV:row_picture(e, state, tw, th)
  local m = self.model
  local mode = m.mode
  local size = M.VIEW_SIZE[mode]
  local pic = self:picture(e, size > 128 and 320 or 128)
  local voice = M.voice_of(e)
  local key = table.concat({mode, state, e.key, tostring(pic), tostring(e.fav), tostring(voice), tw, th}, "|")
  local t = self.tiles[key]
  if t then return t end
  local rx, ry, rw, rh = 2, 1, tw - 4, th - 2            -- (option.rect.adjusted(2, 1, -2, -1))
  local cmds = {"fill " .. QP.hex(C.grid_bg)}
  local fill = "1b1b1e"
  if mode == "list" then                                 -- (no frame: a list reads as lines)
    if state ~= "normal" then
      local edge = state == "chosen" and "4b4b50" or "444444"
      fill = state == "chosen" and "4b4b50" or "26262a"
      cmds[#cmds + 1] = "pen " .. edge .. "ff 1"
      cmds[#cmds + 1] = "brush " .. fill .. "ff"
      cmds[#cmds + 1] = string.format("rect %d %d %d %d", rx, ry, rw, rh)
    end
  else
    local frame = FRAME[state]
    fill = frame[2]
    cmds[#cmds + 1] = "pen " .. frame[1] .. "ff 1"
    cmds[#cmds + 1] = "brush " .. frame[2] .. "ff"
    cmds[#cmds + 1] = string.format("rect %d %d %d %d", rx, ry, rw, rh)
  end
  local bx, by = rx + 3, ry + (rh - size) // 2
  local texts = {}
  if pic then
    local pw, ph = PIC.size(pic)
    local sw, sh = PIC.keep_aspect(pw, ph, size, size)
    cmds[#cmds + 1] = string.format("image %d %d %d %d %s", bx + (size - sw) // 2, by + (size - sh) // 2, sw, sh, pic)
  else
    texts[#texts + 1] = "dots"
  end
  local right = rx + rw - 1
  -- the star and the speech badge come after the words (they lie over a long name): a picture of their own
  local over = {"fill 00000000"}
  if e.fav then
    over[#over + 1] = string.format("image %d %d 0 0 %s\\icons\\star_on_at14.png", right - 18, ry + (rh - 14) // 2, Q.root)
  end
  if voice then
    local x0, y0 = right - (e.fav and 38 or 20), ry + (rh - 16) // 2
    over[#over + 1] = "nopen"
    over[#over + 1] = "brush 141416aa"
    over[#over + 1] = string.format("rrectf %d %d 20 20 3 3", x0 - 2, y0 - 2)
    local name = voice == "none" and "audio-lines-x" or "audio-lines"
    over[#over + 1] = string.format("image %d %d 0 0 %s\\icons\\%s_%s_16.png", x0, y0, Q.root, name,
                                    M.VOICE_COLOUR[voice]:sub(2))
  end
  local _, id, iw, ih = QP.kept(tmp_dir("tiles"), tw, th, cmds)
  local oid
  if #over > 1 then _, oid = QP.kept(tmp_dir("tiles"), tw, th, over) end
  t = {id = id, w = iw, h = ih, over = oid, texts = texts, fill = rgba("#" .. fill), box = {bx, by, size},
       r = {rx, ry, rw, rh}}
  self.tiles[key] = t
  return t
end

function CV:draw_row_tile(e, x, y, tw, th, state)
  local m = self.model
  local t = self:row_picture(e, state, tw, th)
  if t.id then D.image(t.id, x, y, t.w, t.h) end
  local rx, ry, rw, rh = t.r[1], t.r[2], t.r[3], t.r[4]
  local bx, by, bs = t.box[1], t.box[2], t.box[3]
  if t.texts[1] == "dots" then
    local s, lh = "...", Q.line_h(12)
    Q.text(x + bx + (bs - Q.text_w(s, 12)) // 2, y + by + half(bs - lh), C.dots, s, 12, false, t.fill)
  end
  local tx = bx + bs - 1 + 8
  local w = (rx + rw - 1) - (bx + bs - 1) - 12
  local line = Q.line_h(PT)
  if m.mode == "tiles" then
    local title = CV.elide(e.title or "", "right", w, PT, true)
    Q.text(x + tx, y + ry + 6, C.title, title, PT, true, t.fill)
    for k, part in ipairs({{M.details_text(e, 1), rgba("#a8a8ac")}, {M.details_text(e, 3), rgba("#7c7c80")}}) do
      local s = CV.elide(part[1], "right", w, PT, false)
      Q.text(x + tx, y + ry + 8 + line * k, part[2], s, PT, false, t.fill)
    end
  else
    local text = e.title or ""
    if m.mode ~= "list" and e.sub and e.sub ~= "" then text = text .. "  \u{b7}  " .. e.sub end
    text = CV.elide(text, "right", w, PT, false)
    Q.text(x + tx, y + ry + half(rh - line), C.title, text, PT, false, t.fill)
  end
  if t.over then D.image(t.over, x, y, t.w, t.h) end
end

function CV:draw_grid(g)
  local m = self.model
  local G = self.G or self:grid_geom(g)
  -- the frame (QListView{background:#1b1b1e;border:1px solid #333}) and the viewport inside it
  D.fill(g.x, g.y, g.w, g.h, C.grid_edge)
  D.fill(g.x + 1, g.y + 1, g.w - 2, g.h - 2, C.grid_bg)
  local listing = G.kind == "list"
  local rows_mode = listing or m.mode == "small" or m.mode == "tiles"
  local vx, vy, vw, vh = G.x, G.y, G.vw, G.vh
  local ox, oy = self:hoff(G), self.vbar.value
  D.clip(vx, vy, vw, vh, function()
    for i, r in ipairs(G.items) do
      -- (a ListMode item is as wide as its column; Tile paints in it as it is)
      local ix, iy = vx + r[1] - ox, vy + r[2] - oy
      local tw, th = r[3] - r[1] + 1, r[4] - r[2] + 1
      if iy + th >= vy and iy <= vy + vh and ix + tw >= vx and ix <= vx + vw then
        local e = m.rows[i]
        local state = (self.cur == i) and "chosen" or (self.hover == i and "hover" or "normal")
        local AG = package.loaded["conjunction.agent"]        -- (a tile the agent can find: agent.item)
        if AG then AG.area("cat.item." .. tostring(e.key), ix, iy, tw, th, e.title or "") end
        if rows_mode then self:draw_row_tile(e, ix, iy, tw, th, state)
        else self:draw_tile(e, ix, iy, tw, th, state) end
      end
    end
  end)
  if listing then
    if G.cw > vw then self:scrollbar_h(vx, vy + vh, vw, self.hbar) end
  elseif G.ch > vh then
    self:scrollbar_v(vx + vw, vy, vh, self.vbar, G.ch)
  end
end

-- the Details view (a QTreeView with the TREE sheet; its header: #26262a, #9a9aa0 11 px, padding 3px 6px, a line at
-- each section's right; columns 200 170 90 150, the last stretched; its rows as high as the first row asks - 22, or
-- 28 with its picture (uniformRowHeights: the first row at the layout, the app's picture there only once it has been
-- loaded); it scrolls by rows)
CV.DETAIL_W = {200, 170, 90, 150}
function CV:table_geom(g)
  local m = self.model
  local hh = PARTS.header_sort[5]
  local T_ = {x = g.x + 1, y = g.y + 1, hh = hh}
  T_.area_h = g.h - 2 - hh
  T_.row = self.trow or 22
  local page = T_.area_h // T_.row
  T_.bar = m.shown > page
  T_.w = g.w - 2 - (T_.bar and 10 or 0)
  local cols, x = {}, T_.x
  for i, w in ipairs(CV.DETAIL_W) do cols[i] = {x, w} x = x + w end
  cols[#cols + 1] = {x, T_.x + T_.w - x}
  T_.cols = cols
  self.TG = T_
  local tb = self.tbar
  tb.single, tb.page = 1, page
  IV.range(tb, m.shown - page)
  return T_
end
function CV:draw_table(g)
  local m = self.model
  local T_ = self.TG or self:table_geom(g)
  D.fill(g.x, g.y, g.w, g.h, C.grid_edge)
  D.fill(g.x + 1, g.y + 1, g.w - 2, g.h - 2, C.tree_bg)
  local vx, vy, vw = T_.x, T_.y, T_.w
  local hh = T_.hh
  local cols = T_.cols
  -- the header
  local hbg = rgba("#26262a")
  for i, c in ipairs(cols) do
    D.fill(c[1], vy, c[2], hh, hbg)
    D.fill(c[1] + c[2] - 1, vy, 1, hh, rgba("#3c3c42"))
    local lh = Q.line_h(11)
    local s = CV.elide(M.DETAILS[i], "right", c[2] - 12, 11, false)
    Q.text(c[1] + 6, vy + Q.vcenter(hh, lh), rgba("#9a9aa0"), s, 11, false, hbg)
  end
  local arrow = PARTS.header_sort
  local sc = cols[(self.sort_col or 0) + 1]
  Q.draw_part(self.sort_desc == false and "header_sort_up" or "header_sort",
              sc[1] + sc[2] // 2 + arrow[1], vy + arrow[2])
  -- the rows
  local top = vy + hh
  local rows_h = T_.area_h
  local row_h = T_.row
  local first = self.tbar.value
  D.clip(vx, top, vw, rows_h, function()
    for i = first + 1, m.shown do
      local y = top + (i - 1 - first) * row_h
      if y > top + rows_h then break end
      local e = m.rows[i]
      local chosen, hover = self.tcur == i, self.thover == i
      local AG = package.loaded["conjunction.agent"]
      if AG then AG.area("cat.row." .. tostring(e.key), vx, y, vw, row_h, e.title or "") end
      local bg = chosen and C.tree_chosen or (hover and C.tree_hover or C.tree_bg)
      if bg ~= C.tree_bg then D.fill(vx, y, vw, row_h, bg) end
      local fg = chosen and T.WHITE or C.tree_text
      local lh = Q.line_h(12)
      local ty = y + (row_h - lh + 1) // 2
      for c, col in ipairs(cols) do
        local cx, cw = col[1], col[2]
        local tx = cx + 3
        if c == 1 then
          local pic = self:picture(e, 128)
          if pic then
            local id, pw, ph = PIC.texture(pic, 20, 20, bg)
            if id then D.image(id, cx + 3 + (20 - pw) // 2, y + (row_h - ph) // 2, pw, ph) end
          end
          tx = cx + 3 + 20 + 6
        end
        local s = CV.elide(M.details_text(e, c - 1), "right", cx + cw - 3 - tx, 12, false)
        Q.text(tx, ty, fg, s, 12, false, bg)
      end
    end
  end)
  if T_.bar then self:scrollbar_v(vx + vw, vy, g.h - 2, self.tbar, m.shown, true) end
end

-- the theme's scroll bars (ui/scrollbar.lua: QScrollBar's handle, dragging, paging)
CV.slider_pos, CV.slider_value = SBAR.slider_pos, SBAR.slider_value
function CV:scrollbar_v(x, y, h, bar)
  SBAR.draw(self, "cat.vbar." .. tostring(bar), bar, {x = x, y = y, w = 10, h = h}, "v",
            function(id, r) return self:hit(id, r) end, function(b) self:scrolled(b) end)
end
function CV:scrollbar_h(x, y, w, bar)
  SBAR.draw(self, "cat.hbar." .. tostring(bar), bar, {x = x, y = y, w = w, h = 10}, "h",
            function(id, r) return self:hit(id, r) end, function(b) self:scrolled(b) end)
end

-- --- the chrome ---
function CV:draw_mini(r, text, on, icon)
  if not r then return end
  local bg, edge, fg = C.mini_bg, C.mini_edge, C.mini_text
  if on then bg, edge, fg = C.mini_on_bg, C.mini_on_edge, C.mini_on_text end
  D.fill(r.x, r.y, r.w, r.h, edge)
  D.fill(r.x + 1, r.y + 1, r.w - 2, r.h - 2, bg)
  if icon then
    Q.draw_icon_file(icon, r.x + (r.w - 14) // 2, r.y + (r.h - 14) // 2)
  else
    local lh = Q.line_h(12)
    Q.text(r.x + (r.w - Q.text_w(text, 12)) // 2, r.y + Q.vcenter(r.h, lh), fg, text, 12, false, bg)
  end
end

-- the panel's hit box (nothing over it: the bar, an open list) -> clicked (on the release over it), hovered, held
function CV:hit(id, r)
  local pn = self.host or (self.ed and self.ed.panel)
  if pn and pn.hit then return pn:hit(id, r) end
  local mx, my = w3.ui.mouse()
  if CT.blocker and CT.blocker(mx, my) then return false, false, false end
  w3.ui.set_pos(r.x, r.y)
  local clicked, hovered, held = w3.ui.hit("panel." .. id, r.w, r.h)
  if CT.IM.covers(mx, my) then return false, false, false end
  return clicked == 1, hovered, held
end
local function inside(x, y, r) return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end

function CV:frame(page)
  local m = self.model
  self:poll_mosaics()
  self:sync_rows()
  local lay = self:layout(page)
  self.lay = lay
  -- the search (the panel's field: BRIGHT text, "Search")
  local s = lay.search
  local _, text, enter = CT.edit(self.search_id, s.x, s.y, s.w, m.text,
                                 {placeholder = "Search", style = require("conjunction.ui.panel").EDIT_STYLE,
                                  tip = "cat.search"})
  if text ~= m.text then m:set_text(text) self:sync_rows() end
  if CT.focus == self.search_id then
    if enter then self:enter() end
    -- Down: into the results (QLineEdit leaves it to the catalog's keyPressEvent)
    if w3.ui.pressed("DownArrow", true) and #m.rows > 0 then self:search_down() end
  end
  -- its clear button (setClearButtonEnabled): Qt's picture of it, shown while there is text; a click clears
  if m.text ~= "" then
    local cb = PARTS.lineedit_clear
    local r = {x = s.x + s.w - cb[1], y = s.y + cb[2], w = cb[3], h = cb[4]}
    Q.draw_part("lineedit_clear", r.x, r.y)
    local clicked, hovered = self:hit("cat.search_clear", r)
    if hovered and w3.ui.mouse_clicked(1) then CT.text_press = true end   -- (the field's own button)
    if clicked then m:set_text("") self:sync_rows() end
  end
  -- the tabs (QTabBar, not expanding: from the left) on the bar's base (the Windows 11 style's, Qt's own picture:
  -- its left and right 32 px, the column between stretched); a tab is chosen on the press
  local base = Q.part_img and Q.part_img("tabbar_base")
  local tb = lay.tabs
  if tb and base and base.id then
    local bw = base.w
    D.image(base.id, tb.x, tb.y, 32, tb.h, 0, 0, 32 / bw, 1)
    D.image(base.id, tb.x + 32, tb.y, tb.w - 64, tb.h, 32.5 / bw, 0, 32.5 / bw, 1)
    D.image(base.id, tb.x + tb.w - 32, tb.y, 32, tb.h, (bw - 32) / bw, 0, 1, 1)
  end
  if lay.tree then self:draw_tree(lay.tree) end
  for i, r in ipairs(lay.tab_rects) do
    local _, hovered = self:hit("cat.tab." .. i, r)
    Q.tab(r.x, r.y, r.w, r.h, M.TABS[i], {chosen = m.tab == i - 1, px = 12})
    if hovered then
      CT.tip("panel.cat.tab." .. i, M.TAB_TIPS[i])
      if w3.ui.mouse_clicked(1) then m:set_tab(i - 1) self:sync_rows() end
    end
  end
  if lay.grid then
    local row = lay.row
    self:draw_mini(row.nav, nil, m.nav_checked, "folder_cfcfcf_16_at14")
    self:button("nav", row.nav, "cat.nav", function() m:toggle_nav(not m.nav_checked) end)
    if row.crumb and m.crumb_shown then self:draw_crumb(row.crumb) end
    if row.filter then
      local r = row.filter
      local lh = Q.line_h(12)
      -- (no sheet of its own: the Windows 11 style's tool button, its palette's white text, nothing behind it)
      -- (checked - the filters open - the style writes it black, still with nothing behind it)
      -- (held down: the style's secondary text - white at 78.6 %, checked black at 70 %)
      local clicked, hovered, held = self:hit("cat.filter", r)
      if self.board_chip then
        local on = m.filters_open
        local bg = on and 0x4b4b50ff or 0x262629ff
        Q.frame(r.x, r.y, r.w, r.h, bg, on and 0xc8c8c8ff or 0x555555ff)
        Q.text(r.x + (r.w - Q.text_w(m.filter_text, 12)) // 2, r.y + Q.vcenter(r.h, lh), on and 0xffffffff or 0xcfcfcfff,
               m.filter_text, 12, false, bg)
      else
        local down = held and hovered
        local fg = m.filters_open and 0x00000000 or 0xffffff00
        fg = fg | (down and (m.filters_open and 179 or 200) or 255)
        Q.text(r.x + (r.w - Q.text_w(m.filter_text, 12)) // 2, r.y + Q.vcenter(r.h, lh), fg, m.filter_text, 12)
      end
      if hovered then CT.tip("panel.cat.filter", "cat.filters") end
      if clicked then m:toggle_filters(not m.filters_open) self:sync_rows() end
    end
    self:draw_mini(row.view, m.view_text)
    self:button("view", row.view, "cat.view", function() self:menu("view", row.view) end)
    self:draw_mini(row.sort, m.sort_text)
    self:button("sort", row.sort, "cat.sort", function() self:menu("sort", row.sort) end)
    self.chip_hover = nil
    for _, c in ipairs(lay.chips or {}) do self:chip(c) end
    self:sync_rows()
    -- (the mouse and the keys first: what they change shows in this frame)
    if m.grid_shown then
      self:grid_geom(lay.grid)
      self:grid_mouse(lay.grid)
      if CT.focus == self.grid_id then self:grid_keys() end
      self:grid_geom(lay.grid)
      self:draw_grid(lay.grid)
    end
    if m.table_shown then
      self:table_geom(lay.grid)
      self:table_mouse(lay.grid)
      self:table_geom(lay.grid)
      self:draw_table(lay.grid)
    end
    local c = lay.count
    Q.text(c.x, c.y, C.count, m.count_text, 13)
  end
end

-- a tool button: clicked on the release over it, its tooltip under the mouse
function CV:button(id, r, tip, fn)
  if not r then return end
  local clicked, hovered = self:hit("cat." .. id, r)
  if hovered then CT.tip("panel.cat." .. id, tip) end
  if clicked then fn() self:sync_rows() end
end
-- the view's and the order's menus (attach: inline under the button, each entry checkable)
function CV:menu(which, r)
  local m = self.model
  local id = "panel.cat." .. which
  if CT.IM.is_open(id) then CT.IM.close() return end
  local items = {}
  if which == "view" then
    for _, v in ipairs(M.VIEWS) do
      local k = v[1]
      items[#items + 1] = {text = v[2], checked = k == m.mode, action = function() m:set_view(k) self:sync_rows() end}
    end
  else
    for _, v in ipairs(M.SORTS) do
      local k = v[1]
      items[#items + 1] = {text = v[2], checked = k == m.sort_by, action = function() m:set_sort(k) self:sync_rows() end}
    end
  end
  local pn = self.host or (self.ed and self.ed.panel)
  local win = pn and pn.lay and pn.lay.frame or {x = 0, y = 0, w = 4096, h = 4096}
  CT.IM.open(id, r, items, win, {bg = require("conjunction.ui.panel").C.inline_bg})
end

-- a chip: #262629, border #444 (under the mouse #777); checked #4b4b50, border #c8c8c8, white. Picked on the press:
-- the left button this one only (again: none), the right one adds it or takes it out (Chip.mousePressEvent)
function CV:chip(c)
  local ch = c.chip
  local _, hovered = self:hit("cat.chip." .. ch.key, c)
  if hovered then
    self.chip_hover = ch.key
    CT.tip("panel.cat.chip." .. ch.key, ch.quest and "cat.quest" or (c.which == "styles" and "cat.style" or "cat.trait"))
    local left, right = w3.ui.mouse_clicked(1), w3.ui.mouse_clicked(2)
    if left or right then
      if ch.quest then self.model:toggle_quest() else self.model:pick(c.which, ch.key, right) end
      self:sync_rows()
    end
  end
  self:draw_chip(c)
end
function CV:draw_chip(c)
  local ch = c.chip
  local bg, edge, fg = C.mini_bg, rgba("#444444"), C.mini_text
  if ch.checked then bg, edge, fg = C.mini_on_bg, C.mini_on_edge, T.WHITE
  elseif self.chip_hover == ch.key then edge = rgba("#777777") end
  D.fill(c.x, c.y, c.w, c.h, edge)
  D.fill(c.x + 1, c.y + 1, c.w - 2, c.h - 2, bg)
  local s = CV.chip_label(ch.text)
  local lh = Q.line_h(11)
  Q.text(c.x + (c.w - Q.text_w(s, 11)) // 2, c.y + Q.vcenter(c.h, lh), fg, s, 11, false, bg)
end

-- the type tree (QTreeWidget, its TREE sheet: #1c1c1f, border #333, 12 px #dddddd, items padding 2px 0 - rows of 22,
-- indentation 12 with the branch arrows; two columns, the counts as wide as the widest). It scrolls by rows.
local TREE_ROW, TREE_IND = 22, 12
function CV:tree_rows()
  local rows = {}
  for _, it in ipairs(self.model.tree or {}) do
    rows[#rows + 1] = {it = it, depth = 0}
    if it.expanded then
      for _, ch in ipairs(it.children or {}) do rows[#rows + 1] = {it = ch, depth = 1, parent = it} end
    end
  end
  return rows
end
function CV:draw_tree(r)
  D.fill(r.x, r.y, r.w, r.h, C.tree_edge)
  D.fill(r.x + 1, r.y + 1, r.w - 2, r.h - 2, C.tree_bg)
  local vx, vy, vw, vh = r.x + 1, r.y + 1, r.w - 2, r.h - 2
  if self.tree_of ~= self.model.tree then self.tree_of, self.tree_sel = self.model.tree, nil end
  local rows = self:tree_rows()
  self.tree_list = rows
  local bar = self.trbar
  bar.single, bar.page = 1, vh // TREE_ROW
  IV.range(bar, #rows - bar.page)
  if #rows > bar.page then vw = vw - 10 end
  local cw = 0
  for _, row in ipairs(rows) do cw = math.max(cw, Q.hint_w(row.it.count, 12)) end
  -- (ResizeToContents: the text and the item's 3 px margins, at least the hidden header's section - QTreeWidget names
  -- its second column "2": 32 px with the header's style)
  cw = math.max(cw + 6, 32)
  local c1 = vx + vw - cw
  self:tree_mouse({x = vx, y = vy, w = vw, h = vh}, rows)
  rows = self.tree_list
  D.clip(vx, vy, vw, vh, function()
    for i, row in ipairs(rows) do
      local y = vy + (i - 1 - bar.value) * TREE_ROW
      if y + TREE_ROW > vy and y < vy + vh then
        local it = row.it
        local chosen
        if self.tree_sel then chosen = self.tree_sel == it else chosen = it.chosen == true end
        local hover = self.tree_hover == it
        local bg = chosen and C.tree_chosen or (hover and C.tree_hover or C.tree_bg)
        if bg ~= C.tree_bg then D.fill(vx, y, vw, TREE_ROW, bg) end
        local x0 = vx + row.depth * TREE_IND
        if row.depth == 0 and it.children and #it.children > 0 then
          local name = (it.expanded and "cat_branch_open" or "cat_branch_closed") ..
                       (chosen and "_chosen" or (hover and "_hover" or ""))
          Q.draw_part(name, x0, y)
        end
        local tx = x0 + TREE_IND + 3
        local fg = chosen and T.WHITE or (it.hidden and C.tree_hidden or C.tree_text)
        local lh = Q.line_h(12)
        local ty = y + (TREE_ROW - lh + 1) // 2
        local text = CV.elide(it.text, "right", c1 - 3 - tx, 12, false)
        Q.text(tx, ty, fg, text, 12, false, bg)
        local cf = chosen and T.WHITE or (row.depth == 0 and (it.top and C.tree_text or C.tree_count) or C.tree_count_sub)
        Q.text(c1 + 3, ty, cf, it.count, 12, false, bg)
      end
    end
  end)
  if #rows > bar.page then self:scrollbar_v(vx + vw, vy, vh, bar, #rows, true) end
end
-- the tree's mouse (QTreeView): a press on a branch's arrow opens or closes it; on a row it marks the row, and the
-- release over the same row is the click (itemClicked: the catalog shows that branch - the tree is built anew, so a
-- double click is two clicks, the second on whatever row is then under the mouse); the wheel by rows
function CV:tree_mouse(vp, rows)
  local mx, my = w3.ui.mouse()
  local _, hovered = self:hit("cat.tree", vp)
  self.tree_hover = nil
  local bar = self.trbar
  local i = hovered and bar.value + (my - vp.y) // TREE_ROW + 1 or nil
  if i and not rows[i] then i = nil end
  local released = w3.ui.mouse_released(1) or w3.ui.mouse_released(2)
  if released and self.tree_pressed then self:tree_release(i) end
  if not hovered then return end
  CT.tip("panel.cat.tree", "cat.tree")
  local _, _, wheel = w3.ui.mouse()
  if wheel ~= 0 then self:wheel_bar(bar, wheel) end
  if i then self.tree_hover = rows[i].it end
  if w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(2) then
    self:tree_press(i, mx - vp.x, w3.ui.mouse_double(1) or w3.ui.mouse_double(2))
  end
end
-- a press on row i (nil: below the rows) at x in the viewport; double: the press is a double click's second
function CV:tree_press(i, x, double)
  self.tree_pressed = nil
  local row = i and self.tree_list[i]
  if not row then return end
  local x0 = row.depth * TREE_IND
  local deco = row.depth == 0 and row.it.children and #row.it.children > 0 and x >= x0 and x < x0 + TREE_IND
  if deco then
    if not double then                       -- (a double click on the arrow: nothing more)
      row.it.expanded = not row.it.expanded
      self.tree_list = self:tree_rows()
    end
  else
    self.tree_pressed = row.it
    self.tree_sel = row.it
  end
end
-- the release over row i (nil: elsewhere): the same row as pressed is the click
function CV:tree_release(i)
  local it = self.tree_pressed
  self.tree_pressed = nil
  local row = i and self.tree_list[i]
  if it and row and row.it == it then
    self.model:tree_clicked(it)
    self:sync_rows()
    self.tree_list = self:tree_rows()
  end
end

-- the crumb's rich text (a QLabel, 12 px #aaa, its own colours per part): bold runs, links underlined; a link under
-- the mouse shows the hand, a press and release on it follows it (linkActivated)
function CV:draw_crumb(r)
  local html = self.model.crumb or ""
  local runs = {}
  local i = 1
  local function plain(t) return (t:gsub("&nbsp;", "\u{a0}")) end
  while i <= #html do
    local a, b, tag = html:find("<(%a+)[^>]*>", i)
    if not a then runs[#runs + 1] = {plain(html:sub(i)), C.crumb, false, false} break end
    if a > i then runs[#runs + 1] = {plain(html:sub(i, a - 1)), C.crumb, false, false} end
    local close = html:find("</" .. tag .. ">", b + 1, true)
    local inner = html:sub(b + 1, close - 1)
    local open_tag = html:sub(a, b)
    local col = open_tag:match("color:#(%x+)")
    local colour = col and rgba("#" .. (#col == 3 and col:gsub(".", "%0%0") or col)) or C.crumb
    runs[#runs + 1] = {plain(inner), colour, tag == "b", tag == "a" and (open_tag:match("href='([^']*)'") or "")}
    i = close + #tag + 3
  end
  local x = r.x
  local lh = Q.line_h(12)
  local y = r.y + (r.h - lh) // 2
  local mx, my = w3.ui.mouse()
  local _, hovered = self:hit("cat.crumb", r)
  local over
  for _, run in ipairs(runs) do
    Q.text(x, y, run[2], run[1], 12, run[3])
    local w = Q.text_w(run[1], 12, run[3])
    if run[4] then
      D.fill(x, y + lh - 2, w, 1, run[2])   -- (the underline: Segoe UI's, 2 px above the line's end)
      if hovered and mx >= x and mx < x + w and my >= y and my < y + lh then over = run[4] end
    end
    x = x + w
  end
  if hovered then CT.tip("panel.cat.crumb", "cat.crumb") end
  if over then w3.ui.cursor("hand") end
  if hovered and w3.ui.mouse_clicked(1) then self.crumb_pressed = over end
  if w3.ui.mouse_released(1) then
    local link = self.crumb_pressed
    self.crumb_pressed = nil
    if link and link == over then self.model:crumb_link(link) self:sync_rows() end
  end
end

-- --- the grid's behaviour (QListView / QTreeView as the app has them; measured: ingame/ref/behave_catalog*.py) ---
CV.SEARCH, CV.GRID = "panel.cat.search", "panel.cat.grid"
CV.KEYBOARD_INTERVAL = 0.4                -- QApplication::keyboardInputInterval: letters typed within it add up
CV.now = function() return w3.ui.time() end
CV.ACTIVATE_GAP = 0.3                     -- CatalogView._activate: a second activation within it is the same one

-- the rows were set anew (a refresh: Model.set_rows resets the grid - no current item, the scroll kept; the table
-- only hears layoutChanged - its current row stays where it was, and its rows take the first row's height anew)
function CV:sync_rows()
  local m = self.model
  if self.rows_of == m.rows then return end
  local first = self.rows_of == nil
  self.rows_of = m.rows
  self.cur, self.hover, self.press = nil, nil, nil
  if self.tcur and self.tcur > m.shown then self.tcur = nil end
  local e = m.rows[1]
  local had = e and self.pictures[e.key .. "@128"]
  self.trow = (not first and had) and 28 or 22
  self.G = nil
  -- the looks of the people listed painted in the background, behind the tiles on screen (12.11.: scrolling the
  -- People waited for each look)
  for _, r in ipairs(m.rows) do
    if r.looks then
      for k = 1, math.min(4, #r.looks) do LC.want(r.path, r.looks[k], true) end
    elseif r.look ~= nil then
      LC.want(r.path, r.look, true)
    end
  end
end

-- a value of a scroll bar changed: at the end of what is shown, the next page (QAbstractItemView's valueChanged ->
-- fetchMore, the grid's model only)
function CV:scrolled(bar)
  local m = self.model
  local G = self.G
  if not G then return end
  local fetching = (G.kind == "list" and bar == self.hbar) or (G.kind == "icon" and bar == self.vbar)
  if fetching and bar.value == bar.max and m.shown < #m.rows then self:fetch() end
end
function CV:fetch()
  -- (the grid is laid out in one pass, as the app's since 22.10.: the bar keeps its value, the next page comes at its
  -- end again)
  self.model:fetch_more()
  self.G = nil
  self:grid_geom(self.lay.grid)
end

function CV:wheel_bar(bar, notches, shift)
  -- (each notch a wheel event of its own, as Windows sends them; ImGui adds up a frame's)
  local changed = false
  local n = notches
  while n ~= 0 do
    local one = n >= 1 and 1 or (n <= -1 and -1 or n)
    n = n - one
    if math.abs(n) < 1e-9 then n = 0 end
    if self:wheel_event(bar, one, shift) then changed = true end
  end
  return changed
end
-- one wheel event of notches (delta / 120): QAbstractSlider::scrollByDelta (Shift: a page a notch)
function CV:wheel_event(bar, notches, shift)
  local c
  if shift then
    local before = bar.value
    IV.set(bar, bar.value - math.max(-bar.page, math.min(bar.page, math.floor(notches * bar.page))))
    bar.acc = 0.0
    c = bar.value ~= before
  else
    c = IV.wheel(bar, notches, CV.WHEEL_LINES)
  end
  if c then self:scrolled(bar) end
  return c
end
CV.WHEEL_LINES = 3                        -- Windows' lines a notch (SPI_GETWHEELSCROLLLINES; Qt reads it)

-- the current item: set, the view scrolled to it (autoScroll), the inspector told (current)
function CV:set_current(i)
  if i == nil or i == self.cur then return end
  self.cur = i
  self:scroll_to(i)
  local e = self.model.rows[i]
  if e and self.on_current then self.on_current(e) end
end
function CV:scroll_to(i)
  if not self.G and self.model.grid_shown and self.lay and self.lay.grid then self:grid_geom(self.lay.grid) end
  local G = self.G
  if not G or not G.items[i] or not self.model.grid_shown then return end
  local v, h = IV.scroll_to(G, i, self.vbar, self.hbar, G.vw, G.vh)
  if IV.set(self.vbar, v) then self:scrolled(self.vbar) end
  if IV.set(self.hbar, h) then self:scrolled(self.hbar) end
end
function CV:set_table_current(i)
  if i == nil or i == self.tcur then return end
  self.tcur = i
  local T_ = self.TG
  if T_ then IV.set(self.tbar, IV.tree_scroll_to(i, self.tbar, T_.area_h, T_.row)) end
  local e = self.model.rows[i]
  if e and self.on_current then self.on_current(e) end
end

-- double click / Enter (CatalogView._activate): a folder opens, a person's looks open, anything else is chosen
function CV:activate(i)
  local now = CV.now()
  if now - (self.activated_at or -1e9) < CV.ACTIVATE_GAP then return end
  self.activated_at = now
  local e = self.model.rows[i]
  if not e then return end
  local chosen = self.model:activate(e)
  self:sync_rows()
  if chosen and self.on_chosen then self.on_chosen(e) end
end

-- the search's Enter: the first result current and chosen; Down: the first result current, the keys to the grid
function CV:enter()
  local m = self.model
  if #m.rows == 0 then return end
  self:set_current(1)
  if self.on_chosen then self.on_chosen(m.rows[1]) end
end
function CV:search_down()
  self:set_current(1)
  -- (the Details view hides the grid: Qt gives no focus to a hidden widget, the keys stay in the search)
  if self.model.grid_shown then CT.set_focus(self.grid_id) end
end

-- the mouse over the grid: the item under it lit, its tooltip; a press (either button) makes it current; a double
-- click on the item pressed activates it (on another: a press); the wheel scrolls, with Ctrl it changes the view
function CV:grid_mouse(g)
  local G = self.G
  local vp = {x = G.x, y = G.y, w = G.vw, h = G.vh}
  local _, hovered = self:hit("cat.grid", vp)
  self.hover = nil
  if not hovered then return end
  local m = self.model
  local mx, my, wheel = w3.ui.mouse()
  if wheel ~= 0 then
    local ctrl, shift = w3.ui.mods()
    if ctrl then self:ctrl_wheel(wheel) return end
    -- (the List view has no vertical bar: QListView::wheelEvent turns the wheel to the sideways one)
    self:wheel_bar(G.kind == "list" and self.hbar or self.vbar, wheel, shift)
    G = self.G
  end
  local i = IV.at(G, mx - G.x, my - G.y, self.vbar, self.hbar)
  self.hover = i
  if i then
    local e = m.rows[i]
    CT.tip(self.grid_id, {e.title or "", M.tooltip(e)})
  end
  for b = 1, 2 do
    if w3.ui.mouse_clicked(b) then
      if w3.ui.mouse_double(b) and i and i == self.press then
        self:activate(i)                           -- (doubleClicked, and activated for the left button: one)
      else
        self.press = i
        if i then self:set_current(i) end
      end
    end
  end
end
function CV:table_mouse(g)
  local T_ = self.TG
  local vp = {x = T_.x, y = T_.y + T_.hh, w = T_.w, h = T_.area_h}
  local m = self.model
  local mx, my, wheel = w3.ui.mouse()
  -- the heads: a click sorts by that column (again: the other way; another column: A to Z first)
  local head = {x = T_.x, y = T_.y, w = T_.w, h = T_.hh}
  local clicked = self:hit("cat.head", head)
  if clicked then
    for c, col in ipairs(T_.cols) do
      if mx >= col[1] and mx < col[1] + col[2] then self:head_click(c - 1) break end
    end
  end
  local _, hovered = self:hit("cat.table", vp)
  self.thover = nil
  if not hovered then return end
  if wheel ~= 0 then
    local ctrl, shift = w3.ui.mods()
    if ctrl then self:ctrl_wheel(wheel) return end
    self:wheel_bar(self.tbar, wheel, shift)
  end
  local i = self.tbar.value + (my - vp.y) // T_.row + 1
  if i > m.shown then i = nil end
  self.thover = i
  if i then CT.tip("panel.cat.table", {"", M.details_text(m.rows[i], 4)}) end
  for b = 1, 2 do
    if w3.ui.mouse_clicked(b) then
      if w3.ui.mouse_double(b) and i and i == self.tpress then
        self:activate(i)
      else
        self.tpress = i
        if i then self:set_table_current(i) end
      end
    end
  end
end
-- a click on column sec's head (QHeaderView::flipSortIndicator): the same column the other way, another A to Z;
-- the entries shown sorted by it (DetailsModel.sort)
function CV:head_click(sec)
  if sec == (self.sort_col or 0) then self.sort_desc = not (self.sort_desc ~= false)
  else self.sort_desc = false end
  self.sort_col = sec
  self.model:sort_column(sec, self.sort_desc)
  self:sync_rows()
end
-- Ctrl + wheel: the next view, as in Explorer (up: bigger), one a notch
function CV:ctrl_wheel(wheel)
  local m = self.model
  local order = {}
  for k, v in ipairs(M.VIEWS) do order[v[1]] = k end
  local steps = math.max(1, math.floor(math.abs(wheel) + 0.5))
  for _ = 1, steps do
    local k = order[m.mode] + (wheel > 0 and -1 or 1)
    k = math.max(1, math.min(#M.VIEWS, k))
    m:set_view(M.VIEWS[k][1])
  end
  self:sync_rows()
end

-- the keys while the grid has them (after Down in the search): QListView::moveCursor; Enter activates; letters look
-- for the next title starting so (keyboardSearch); Escape gives the keys back to the game
local KEYS = {{"UpArrow", "up"}, {"DownArrow", "down"}, {"LeftArrow", "left"}, {"RightArrow", "right"},
              {"Home", "home"}, {"End", "end"}, {"PageUp", "pageup"}, {"PageDown", "pagedown"}}
function CV:grid_keys()
  if w3.ui.pressed("Escape") then CT.set_focus(nil) return end
  w3.ui.want_text()
  for _, k in ipairs(KEYS) do
    if w3.ui.pressed(k[1], true) then self:key(k[2]) end
  end
  if (w3.ui.pressed("Enter", true) or w3.ui.pressed("KeypadEnter", true)) and self.cur then self:activate(self.cur) end
  local typed = w3.ui.chars()
  if typed ~= "" then
    local ctrl, _, alt = w3.ui.mods()
    if not ctrl and not alt then
      for _, c in utf8.codes(typed) do self:keyboard_search(utf8.char(c)) end
    end
  end
end
function CV:key(action)
  local G = self.G
  if not G then return end
  local i = IV.move(G, action, self.cur, G.vh)
  if i and i ~= self.cur then self:set_current(i) end
end
-- QTreeView::moveCursor for the Details view (the app never gives the table the keys: a click on it ends the typing;
-- kept for the check and for the other tables). Left and Right move its sideways bar, which it has none of
function CV:table_key(action)
  local T_ = self.TG
  if not T_ or action == "left" or action == "right" then return end
  local i = IV.tree_move(self.model.shown, action, self.tcur, self.tbar.value, T_.area_h, T_.row)
  if i and i ~= self.tcur then self:set_table_current(i) end
end
-- QAbstractItemView::keyboardSearch: from the item after the current one (or, typed within the interval, from it),
-- the first title that starts with what was typed, wrapping round; the same letter again steps on
function CV:keyboard_search(ch)
  local m = self.model
  local n = m.shown
  if n == 0 then return end
  local now = CV.now()
  local skip = false
  if not self.kb_time or now - self.kb_time > CV.KEYBOARD_INTERVAL then
    self.kb_text = ch
    skip = self.cur ~= nil
  else
    self.kb_text = self.kb_text .. ch
  end
  self.kb_time = now
  local cps = S.cps(self.kb_text)
  if #cps > 1 then
    local same = true
    for _, c in ipairs(cps) do if c ~= cps[#cps] then same = false end end
    if same then skip = true end
  end
  local start = self.cur or 1
  if skip then start = start < n and start + 1 or 1 end
  local want = S.lower(self.kb_text)
  for k = 0, n - 1 do
    local i = (start - 1 + k) % n + 1
    local title = S.lower(m.rows[i].title or "")
    if title:sub(1, #want) == want then self:set_current(i) return end
  end
end

return CV
