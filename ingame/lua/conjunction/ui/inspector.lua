-- The inspector beside the Asset Browser (conjunction/catalog_view.py Inspector, the part for a catalog entry): the
-- picture, the name, what it is, the path to copy, Place and the star, chips of what it is (a click shows all of that
-- kind), the facts. A QScrollArea (widgetResizable, its bar's single step 20) around a column (margins 6, spacing 6);
-- the panel's sheet: QLabel 13 px #ccc, #title bold 14 px #eee. Plain labels wrap as QLabel does (ui/textlayout.lua),
-- the facts are a rich text table as QTextDocumentLayout sets it (cellspacing 2, variable columns).
-- The 3D view comes in the picture's place 120 ms after a template is shown, or when the picture is pressed
-- (ui/view3d.lua); a person's looks are stepped through under it. The part for an object selected in the world:
-- inspector_object.lua.
--   local ins = INS.new(panel)      ins:show_entry(e, favourite)      ins:frame(rect) (the inspector box: 330 wide)
--   ins.on_place(e), ins.on_favourite(e), ins.on_overview(what, value): the panel's
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local L = require("conjunction.ui.layout")
local CT = require("conjunction.ui.controls")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local TL = require("conjunction.ui.textlayout")
local PIC = require("conjunction.ui.pictures")
local S = require("conjunction.pystr")
local J = require("conjunction.json")
local Y = require("conjunction.yaml")
local M = require("conjunction.catalog_model")
local V3 = require("conjunction.ui.view3d")
local MV = require("conjunction.meshview")
local D = w3.ui.draw
local INS = {}
INS.__index = INS

INS.W = 330                    -- panel.INSPECTOR_W
INS.PIC_W = 296                -- catalog_view.PIC_W
local function rgba(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
local C = {
  label = rgba("#cccccc"), title = rgba("#eeeeee"), pic_bg = rgba("#1d1d20"), pic_edge = rgba("#333333"),
  note = rgba("#e3c65f"), note_edge = rgba("#5a5032"), key = rgba("#999999"), value = rgba("#dddddd"),
  descr = rgba("#bbbbbb"), tag_text = rgba("#cfcfcf"), tag_bg = rgba("#262629"), tag_edge = rgba("#555555"),
  tag_hover = rgba("#aaaaaa"), icon_hover = rgba("#ffffff", 20),
}
INS.C = C
INS.VOICE_LOOK = {all = "Can talk (this look moves the mouth)", none = "Stays silent (this look has no moving face)"}

local function truthy(v)
  return not (v == nil or v == false or v == Y.null or v == 0 or v == "" or (type(v) == "table" and next(v) == nil))
end
local function str(v) if v == nil or v == Y.null then return "" end return tostring(v) end
local function list_of(v)
  if type(v) == "table" then return v end
  if v == nil or v == Y.null or v == "" then return {} end
  local ok, t = pcall(J.decode, v)
  if ok and type(t) == "table" then return t end
  return {}
end
-- Python's f"{x:g}"
local function g(x) return (string.format("%g", tonumber(x) or 0)) end
-- catalog_view._breakable: a zero width space after \ / _ , (paths and long names may wrap there)
local function breakable(t)
  return (str(t):gsub("([\\/_,])", "%1\u{200b}"))
end
local function words(s)
  local out = {}
  for w in str(s):gmatch("%S+") do out[#out + 1] = w end
  return out
end

function INS.new(panel)
  local self = setmetatable({panel = panel}, INS)
  self.entry = nil
  self.bar = IV.bar(20, 0, 0)
  -- what stays from the entry shown before (the app sets these only for templates)
  self.path_shown, self.copy_shown = true, true
  self.v3 = V3.new()
  self.look_info = {}                       -- 3D key -> {look shown, looks to step through}
  self.look_pick = nil                      -- a catalog entry's look chosen here (nil: the usual one)
  return self
end
INS.AUTO3D = true                           -- (the lab's pictures of the inspector: off, the picture stays)
-- the look row: [<] the look (#bbb, centred) [>] - QToolButtons without a sheet (Qt's native look: the text only)
local function step_size(text) return Q.hint_w(text) + 2 * Q.text_w(" ") + 3, Q.line_h() + 3 end
function INS.look_h() return math.max(select(2, step_size("<")), Q.line_h()) end
function INS:draw_look(r)
  local lw = step_size("<")
  local rw = step_size(">")
  local function step(id, b, text, d)
    local clicked, hovered, held = self:hit(id, b)
    local fg = (held and hovered) and 0xffffffc8 or 0xffffffff
    Q.text(b.x + (b.w - Q.text_w(text)) // 2, b.y + Q.vcenter(b.h, Q.line_h()), fg, text)
    if hovered then CT.tip("panel." .. id, "ins.look_step") end
    if clicked then self:step_look(d) end
  end
  step("ins.look_prev", {x = r.x, y = r.y, w = lw, h = r.h}, "<", -1)
  local lx, lr = r.x + lw + 6, r.x + r.w - rw - 6           -- (the row's 6 between)
  local t = self.look_text or ""
  Q.text(lx + (lr - lx - Q.text_w(t)) // 2, r.y + Q.vcenter(r.h, Q.line_h()), rgba("#bbbbbb"), t)
  step("ins.look_next", {x = r.x + r.w - rw, y = r.y, w = rw, h = r.h}, ">", 1)
end

-- --- the 3D view (Inspector._load_3d / _mesh_ready / _step_look) ---
function INS:meshes_of(e)
  if not e or e.type ~= "template" then return {} end
  if e.mesh then return {e.mesh} end
  local ok, meshes = pcall(J.decode, str((e.row or {}).meshes) ~= "" and str(e.row.meshes) or "[]")
  return ok and type(meshes) == "table" and meshes or {}
end
function INS:key3d()
  if not self.entry then return nil end
  return tostring(self.entry.key) .. (self.obj and ("#" .. tostring(self.obj[1]) .. "," .. tostring(self.obj[2])) or "")
         .. (self.look_pick and ("@" .. self.look_pick) or "")
end
function INS:load_3d()
  local e = self.entry
  local meshes = self:meshes_of(e)
  local key = self:key3d()
  if self.mesh_key == key and self.v3.mesh then
    self.showing3d = true
    return
  end
  self.mesh_key = key
  local look = self.look_pick
  if self.obj then
    local pr = self.panel and self.panel.ed and self.panel.ed.project
    local o = pr and pr.places[self.obj[1]] and pr.places[self.obj[1]].objects[self.obj[2]]
    local a = o and o.appearance
    if a and a ~= Y.null and a ~= "" then look = a end
  end
  local info = self.look_info
  self.v3:load(key, function()
    local d = V3.depot()
    if e.mesh then return MV.read_mesh(e.mesh, d) end      -- (a library mesh)
    local ok, parts = pcall(function()
      local how, parts = MV.entity_parts(e.path, d, meshes, look)
      if how:sub(1, 5) == "look " then                     -- (the looks to step through: those the game uses)
        local apps, used = MV.looks(e.path, d)
        local opts = {}
        for _, u in ipairs(used) do if apps.v[u] ~= nil then opts[#opts + 1] = u end end
        if #opts == 0 then for _, k in ipairs(apps.keys) do opts[#opts + 1] = k end end
        info[key] = {how:sub(6), opts}
      end
      return parts
    end)
    return ok and parts or {}
  end, function(k, ok, parts) if ok then self:mesh_ready(k, parts) end end)
end
function INS:mesh_ready(key, parts)
  if not self.entry or key ~= self.mesh_key or key ~= self:key3d() then return end   -- (clicked on meanwhile)
  local info = self.look_info[key] or {"", {}}
  local cur, options = info[1], info[2]
  if not self.obj and #options > 1 and self.entry.look == nil then self.look_row = true else self.look_row = nil end
  if #options > 0 then
    local at = 0
    for i, o in ipairs(options) do if o == cur and at == 0 then at = i end end
    local text = at > 0 and string.format("%s  %d/%d", (cur:gsub("_", " ")), at, #options) or (cur:gsub("_", " "))
    local talking = M.voice_of(self.entry) == "some" and require("conjunction.talking").known_talking(
      str(self.entry.path)) or nil
    if talking ~= nil then
      local can = false
      for _, t in ipairs(talking) do if t == cur then can = true end end
      if not can then text = text .. "  (cannot talk)" end
    end
    self.look_text = text
  end
  if #parts == 0 then
    self.showing3d = false                       -- (nothing to turn: the picture stays)
    return
  end
  if self.v3:show_parts(parts) then self.showing3d = true end
end
function INS:step_look(d)
  local info = self.look_info[self:key3d()] or {"", {}}
  local cur, options = info[1], info[2]
  if #options == 0 then return end
  local at = 0
  for i, o in ipairs(options) do if o == cur and at == 0 then at = i end end
  self.look_pick = options[((at - 1 + d) % #options) + 1]
  self:load_3d()
end

-- --- what is shown (Inspector._show for a catalog entry) ---
-- keep_obj: shown for the object selected (show_object), else the object's part goes
function INS:show_entry(e, favourite, keep_obj)
  if not keep_obj then self.obj, self.ob = nil, nil end
  if not self.entry or self.entry.key ~= e.key then
    IV.set(self.bar, 0)
    self.look_pick, self.look_row = nil, nil       -- (another thing: its usual look)
  end
  if e.look ~= nil then self.look_pick = e.look end -- (a look of a person: shown in it)
  self.showing3d = false                           -- (a new thing: its picture first, then itself in 3D)
  if e.type == "template" and INS.AUTO3D then self.auto3d_at = os.clock() + 0.12 end
  self.entry = e
  self.own = nil
  self.fav = favourite and true or false
  local r = e.row or {}
  local folder = M.is_folder(e)
  self.note = folder and M.folder_text(e) or nil
  local v = e.type == "template" and M.voice_of(e) or nil
  self.voice = nil
  if v and v ~= "some" then
    self.voice = {text = (e.look ~= nil) and INS.VOICE_LOOK[v] or M.VOICE_TEXT[v], colour = rgba(M.VOICE_COLOUR[v])}
  end
  if not self.obj then
    self.place_text, self.place_icon = "Place", nil
    if folder then self.place_text, self.place_icon = "Place random", "dices" end
  end
  if e.type == "item" then
    self.title = str(r.label) ~= "" and str(r.label) or str(r.name)
    local parts = {}
    for _, x in ipairs({str(r.cat), str(r.sub), (str(r.category):gsub("_", " "))}) do
      if x ~= "" then parts[#parts + 1] = x end
    end
    self.subtitle = table.concat(parts, " / ")
    self.path = str(r.name)
    -- (an item window's inspector: its button takes the item, the name is a field - renamed, a new item of this
    -- quest is made from it)
    self.place_shown = self.item_action ~= nil
    if self.item_action then
      self.place_text, self.place_icon = self.item_action, nil
      self.rename = self.title
      CT.state("panel.ins.rename").e = nil
      self.redescribe = str(r.descr)              -- (redescribe.setPlainText: shown once the item is renamed)
      CT.state("panel.ins.redescribe").e = nil
    end
    local tags = {}
    for i, t in ipairs(words(r.tags)) do if i <= 24 then tags[#tags + 1] = {t, {"words", t}} end end
    self.chips = {{"type", str(r.sub) ~= "" and {{str(r.sub), {"words", str(r.sub)}}} or {}}, {"tags", tags}}
    self.facts = {{"price", g(r.price) .. " crowns"}, {"weight", g(r.weight)}, {"defined in", str(r.file)}}
    self.descr = str(r.descr)
    self.own = e.own
    if e.own then                                  -- (an own item of this quest - the item window's Custom: its
      -- fields change it; the picture is the one it is made from)
      self.title = e.title
      self.rename, self.redescribe = e.own_name, e.own_descr
      self.subtitle = e.made_from and ("Custom item, made from " .. e.made_from) or "Custom item"
      self.path_shown, self.copy_shown = false, false
      self.chips = {}
      self.facts = {{"used in", #e.uses > 0 and table.concat(e.uses, ", ") or "not used yet"},
                    {"readable", e.own_text ~= "" and "yes" or "no"}}
      self.descr = ""
    end
    return
  end
  self.place_shown = true
  if truthy(e.members) then
    self.title = string.format("%s  (folder, %d variants)", str(e.title), #e.members)
  elseif truthy(e.looks) then
    self.title = string.format("%s  (folder, %d looks)", str(e.title), #e.looks)
  elseif e.look ~= nil then
    self.title = str(r.name) .. ": " .. str(e.sub)
  else
    self.title = str(r.name) ~= "" and str(r.name) or str(e.title)
  end
  local styles = r.styles
  if type(styles) ~= "table" then
    local t = {}
    for _, x in ipairs(words(styles)) do t[#t + 1] = (x:gsub("_", " ")) end
    styles = t
  end
  local catsub = {}
  for _, x in ipairs({str(r.cat), str(r.sub)}) do if x ~= "" then catsub[#catsub + 1] = x end end
  local sub = {}
  for _, x in ipairs({table.concat(catsub, " / "), table.concat(styles, ", "), str(r.source)}) do
    if x ~= "" then sub[#sub + 1] = x end
  end
  self.subtitle = table.concat(sub, " / ")
  self.path = truthy(e.members) and "" or str(e.path)
  self.path_shown = not truthy(e.members)
  self.copy_shown = self.path_shown
  local facts = {{"inventory", truthy(r.inventory) and "yes" or "no"}}
  local loot = list_of(r.loot_defs)
  if #loot > 0 then
    local t = {}
    for i, x in ipairs(loot) do t[i] = (tostring(x):gsub("^_+", ""):gsub("_+$", "")) end
    facts[#facts + 1] = {"loot table", table.concat(t, ", ")}
  end
  local apps = list_of(r.appearances)
  if #apps > 0 then
    local t = {}
    for i = 1, math.min(12, #apps) do t[i] = tostring(apps[i]) end
    facts[#facts + 1] = {"appearances", table.concat(t, ", ") .. (#apps > 12 and string.format(" (+%d)", #apps - 12) or "")}
  end
  local comps = list_of(r.components)
  if #comps > 0 then
    local t = {}
    for i, c in ipairs(comps) do c = tostring(c) t[i] = c:sub(1, 1) == "C" and c:sub(2) or c end
    facts[#facts + 1] = {"components", table.concat(t, ", ")}
  end
  local meshes = list_of(r.meshes)
  if #meshes > 0 then
    local t = {}
    for i = 1, math.min(6, #meshes) do t[i] = (tostring(meshes[i]):gsub("^.*[\\/]", ""):gsub("%.[^.]*$", "")) end
    facts[#facts + 1] = {"meshes", table.concat(t, ", ") .. (#meshes > 6 and string.format(" (+%d)", #meshes - 6) or "")}
  end
  if truthy(r.mesh) then facts[#facts + 1] = {"mesh", str(r.mesh)} end
  local traits = r.traits
  if type(traits) ~= "table" then traits = words(traits) end
  local chips = {}
  local cls = str(r.class)
  chips[1] = {"type", str(r.cat) ~= "" and {{str(r.sub) ~= "" and str(r.sub) or str(r.cat), {"type", {r.cat, r.sub}}}} or {}}
  local st = {}
  for _, s in ipairs(styles) do st[#st + 1] = {s, {"style", s}} end
  chips[2] = {"style", st}
  local can = {}
  for _, t in ipairs(traits) do if t ~= "quest" and t ~= "named" then can[#can + 1] = {t, {"trait", t}} end end
  chips[3] = {"can", can}
  chips[4] = {"class", (cls ~= "" and cls ~= "mesh") and {{cls, {"words", cls}}} or {}}
  local tags = {}
  for i, t in ipairs(words(r.tags)) do if i <= 24 then tags[#tags + 1] = {t, {"words", t}} end end
  chips[5] = {"tags", tags}
  self.chips = chips
  self.facts = not truthy(e.members) and facts or nil  -- (a folder: one variant's would mislead)
  self.descr = ""
end

-- an item window's item: the new name typed for it, or nil (not renamed)
function INS:renamed_to()
  local e = self.entry
  if not (self.item_action and e and e.type == "item") or e.own then return nil end
  local text = S.strip(self.rename or "")
  local r = e.row or {}
  local was = str(r.label) ~= "" and str(r.label) or str(r.name)
  if text ~= "" and text ~= was then return text end
  return nil
end
-- the description written for a renamed item
function INS:described() return S.strip(self.redescribe or "") end

-- --- sizes ---
local function label_lines(text, px, bold, w) return TL.wrap(text, px, bold, math.max(0, w), "word") end
-- the sizes asked three times a frame for the same texts: kept (27.10.: laid out anew each time they made 13 MB of
-- garbage a second while an object was selected, the garbage collector's pauses 100 ms every few seconds)
local MEMO, memo_n = {}, 0
local function memo(key, make)
  local v = MEMO[key]
  if v == nil then
    if memo_n >= 512 then MEMO, memo_n = {}, 0 end
    v = make()
    MEMO[key] = v
    memo_n = memo_n + 1
  end
  return v
end
local function label_h(text, px, bold, w)
  return memo(table.concat({"h", text, px, tostring(bold), w}, "\0"), function()
    return math.max(1, #label_lines(text, px, bold, w)) * Q.line_h(px, bold)
  end)
end
-- catalog_view.path_tail: the end of a path that fits in width (MaximdeWinter 23.10.: one line, the end of it) - from a
-- backslash on, after an ellipsis
INS.PATH_PX = T.FONT
INS.ELLIPSIS = "\u{2026}"
function INS.path_tail(path, width)
  local function adv(s) return Q.text_w(s, INS.PATH_PX) end
  if adv(path) <= width then return path end
  local parts, cur = {}, ""
  for ch in path:gmatch(".") do
    cur = cur .. ch
    if ch == "\\" or ch == "/" then
      parts[#parts + 1] = cur
      cur = ""
    end
  end
  if cur ~= "" then parts[#parts + 1] = cur end
  local tail = ""
  for k = #parts, 1, -1 do
    if adv(INS.ELLIPSIS .. "\\" .. parts[k] .. tail) > width then break end
    tail = parts[k] .. tail
  end
  if tail ~= "" then return INS.ELLIPSIS .. "\\" .. tail end
  local last = parts[#parts]
  local k = 1
  while k < #last and adv(INS.ELLIPSIS .. last:sub(k)) > width do k = k + 1 end
  return INS.ELLIPSIS .. last:sub(k)
end
-- catalog_view.disk_folder: the folder on disk that holds a game file (REDkit's r4data, else the game's own folder) -
-- a path to paste into Explorer; nil when neither has it
function INS.disk_folder(depot_path)
  local cfg = require("conjunction.config").load()
  local rel = (tostring(depot_path or ""):gsub("/", "\\"):gsub("^\\+", ""))
  for _, root in ipairs({(cfg.redkit or "") .. "\\r4data", cfg.game or ""}) do
    if rel ~= "" and root ~= "" and root ~= "\\r4data" then
      local full = root .. "\\" .. rel
      if w3.fs.exists(full) and not w3.fs.isdir(full) then return (full:gsub("\\[^\\]*$", "")) end
    end
  end
  return nil
end
-- the path's box (PathBox: a field's look, padding 5, a 1 px border) at the row's width cw: its line and height
local function path_box(path, cw)
  local w = math.max(1, cw - 23 - 6 - 12)
  return memo(table.concat({"p", path or "", w}, "\0"), function() return INS.path_tail(path or "", w) end),
         Q.line_h(INS.PATH_PX) + 12
end
-- a TAG chip (QToolButton: 11 px, padding 1px 6px, a 1 px border)
local function tag_size(text)
  local s = text
  return Q.hint_w(s, 11) + 2 * Q.text_w(" ", 11) + 12 + 2 + 3, Q.line_h(11) + 2 + 2 + 3
end
-- Flow: rows that wrap, 4 apart; -> the chips' places (from 0, 0) and the height
local function flow(chips, w)
  local x, y, line = 0, 0, 0
  local out = {}
  for i, ch in ipairs(chips) do
    local cw, chh = tag_size(ch[1])
    if x + cw > w - 1 and line > 0 then x, y, line = 0, y + line + 4, 0 end
    out[i] = {x = x, y = y, w = cw, h = chh}
    x = x + cw + 4
    line = math.max(line, chh)
  end
  return out, y + line
end

-- the facts' table (QTextDocumentLayout::layoutTable: cellspacing 2, no border, no cell padding; the key's cell
-- padding-right 8; variable columns: their minimum, then up to their maximum, rounded with the error carried on)
-- and the description below it (<p>: 12 px above). -> {height, cells = {{x, y, lines, colour}}}
local FPX = 13
function INS.facts_layout(facts, descr, width)
  local out = {cells = {}}
  local lh = Q.line_h(FPX)
  local rows = {}
  for _, f in ipairs(facts or {}) do
    if f[2] ~= "" then rows[#rows + 1] = {f[1], breakable(f[2])} end
  end
  local y = 0
  if #rows > 0 then
    local sp = 2
    local pad = {8, 0}                            -- right padding per column
    local minw, maxw = {1, 1}, {nil, nil}
    for _, r in ipairs(rows) do
      for c = 1, 2 do
        local mn, mx = TL.min_max(r[c], FPX, false)
        minw[c] = math.max(minw[c], math.ceil(mn + pad[c]))
        local m = math.ceil(mx + pad[c])
        maxw[c] = maxw[c] and math.max(maxw[c], m) or m
        maxw[c] = math.max(maxw[c], minw[c])
      end
    end
    -- (in 1/64 px, as QFixed)
    local remaining = (width - (2 - 1) * sp - 2 * sp) * 64
    local widths = {}
    for c = 1, 2 do widths[c] = minw[c] * 64 remaining = remaining - minw[c] * 64 end
    if remaining > 0 then
      local last = remaining
      while remaining > 0 do
        for k = 1, 2 do
          local left = 2 - k + 1
          local share = remaining // left
          if remaining < 0 then share = -((-remaining) // left) end
          local wv = math.min(maxw[k] * 64 - widths[k], share)
          widths[k] = widths[k] + wv
          remaining = remaining - wv
        end
        if remaining == last then break end
        last = remaining
      end
    end
    local err = 0
    for c = 1, 2 do
      local orig = widths[c]
      local v = widths[c] - err
      widths[c] = ((v + 32) // 64) * 64              -- (QFixed::round)
      err = widths[c] - orig
    end
    local w0, w1 = widths[1] // 64, widths[2] // 64
    local colx = {sp, sp + w0 + sp}
    y = sp
    for _, r in ipairs(rows) do
      local k_lines = TL.wrap(r[1], FPX, false, w0 - pad[1], "word")
      local v_lines = TL.wrap(r[2], FPX, false, w1 - pad[2], "word")
      local h = math.max(#k_lines, #v_lines, 1) * lh
      out.cells[#out.cells + 1] = {x = colx[1], y = y, lines = k_lines, colour = C.key}
      out.cells[#out.cells + 1] = {x = colx[2], y = y, lines = v_lines, colour = C.value}
      y = y + h + sp
    end
  end
  if descr and descr ~= "" then
    y = y + 12
    local lines = TL.wrap(descr, FPX, false, width, "word")
    out.cells[#out.cells + 1] = {x = 0, y = y, lines = lines, colour = C.descr}
    y = y + #lines * lh
  end
  out.height = math.max(y, lh)                   -- (nothing: an empty line)
  return out
end

-- the column's items for the content width cw: {key, h | hfw}
function INS:items(cw)
  local it = {}
  local function add(key, h) it[#it + 1] = {key = key, h = h} end
  add("pic", 300)
  if self.look_row then add("look", INS.look_h()) end
  local renaming = self.item_action and self.entry and self.entry.type == "item"
  if renaming then
    add("rename", 31)
    if self.own then                            -- (an own item: its line, its text, out of the quest)
      add("redescribe", 64)
      add("own_tools", 29)
    elseif self:renamed_to() then                   -- (a new item: its description can be its own too)
      add("rename_note", Q.line_h(11))
      add("redescribe", 64)
    end
  else
    add("title", label_h(self.title or "", 14, true, cw))
  end
  add("subtitle", label_h(self.subtitle or "", 13, false, cw))
  -- (a label with a frame - the note's border - gets QLabel's indent: its size counts the advance of 'x', its
  -- paint only half of it, and wraps at that width)
  if self.note then add("note", label_h(self.note, 11, false, cw - 10 - Q.text_w("x", 11)) + 10) end
  if self.voice then add("voice", label_h(self.voice.text, 11, false, cw)) end
  if self.path_shown or self.copy_shown then add("path", select(2, path_box(self.path, cw))) end
  add("buttons", 32)
  if self.obj and self.ob then
    local _, h = self:obj_parts(cw)
    add("obj", h)
  end
  local chip_rows = {}
  for _, row in ipairs(self.chips or {}) do if #row[2] > 0 then chip_rows[#chip_rows + 1] = row end end
  self.chip_rows = chip_rows
  if #chip_rows > 0 then
    local lw = 0
    for _, row in ipairs(chip_rows) do lw = math.max(lw, Q.hint_w(row[1], 12)) end
    self.chip_lw = lw
    local fw = cw - lw - 8
    local h = 4
    for i, row in ipairs(chip_rows) do
      local _, fh = flow(row[2], fw)
      h = h + math.max(fh, Q.line_h(12)) + (i > 1 and 4 or 0)
    end
    add("chips", h + 4)
  end
  -- (kept while the facts and the description stay, one per width: laid out three times a frame it took 2 ms, 23.10.;
  -- with the scroll bar a frame asks two widths - kept for one, both were laid out anew every frame, 7 ms and the
  -- garbage collector's pauses with it, 27.10.)
  local fk = self._facts_for
  if not (fk and fk[1] == self.facts and fk[2] == self.descr) then
    fk = {self.facts, self.descr, {}}
    self._facts_for = fk
  end
  local lay = fk[3][cw]
  if not lay then
    lay = INS.facts_layout(self.facts, self.descr, cw)
    fk[3][cw] = lay
  end
  self.facts_lay = lay
  add("facts", lay.height)
  return it
end
function INS:content_h(cw)
  local h = 6
  for i, it in ipairs(self:items(cw)) do h = h + it.h + (i > 1 and 6 or 0) end
  return h + 6
end

-- --- drawing and the mouse ---
function INS:hit(id, r)
  local pn = self.panel
  if pn and pn.hit then return pn:hit(id, r) end
  w3.ui.set_pos(r.x, r.y)
  local c, hv, held = w3.ui.hit("panel." .. id, r.w, r.h)
  return c == 1, hv, held
end

local function draw_lines(lines, x, y, colour, px, bold, lh)
  for k, l in ipairs(lines) do Q.text(x, y + (k - 1) * lh, colour, l.s, px, bold) end
end

-- a push button of the theme with an icon (QCommonStyle's label: icon and text centred together, 4 px apart; the
-- contents: the border and the theme's padding 5px 10px; QPushButton's own #ddd - no page rule in the panel)
local function push(x, y, w, h, text, icon, icon_size, st)
  local bg, edge = T.BUTTON, T.EDGE
  if st.hover then edge = T.EDGE_HOVER end
  if st.pressed then bg = T.CHOSEN end
  Q.frame(x, y, w, h, bg, edge)
  local cx, cy, cw, ch = x + 11, y + 6, w - 22, h - 12
  local lh = Q.line_h()
  local ty = cy + (ch - lh) // 2
  if not icon then
    Q.text(cx + (cw - Q.text_w(text)) // 2, ty, T.BUTTON_TEXT, text, T.FONT, false, bg)
    return
  end
  -- (the label counts 4 px between icon and text, the text then stands half of that from the icon)
  local label = icon_size + (text ~= "" and Q.hint_w(text) + 4 or 0)
  local ix = cx + (cw - label) // 2
  Q.draw_icon_file(icon, ix, cy + (ch - icon_size) // 2)
  if text ~= "" then Q.text(ix + icon_size + 2, ty, T.BUTTON_TEXT, text, T.FONT, false, bg) end
end

function INS:frame(box)
  local e = self.entry
  if not e then return end
  self._fc = {}                                   -- (this frame's layouts, see INS:items below)
  -- (the 3D view: 120 ms after the template came - quick clicks through the list read only the last one)
  if self.auto3d_at and os.clock() >= self.auto3d_at then
    self.auto3d_at = nil
    if e.type == "template" and not M.is_folder(e) then self:load_3d() end
  end
  self.v3:tick()
  -- the scroll area: the box less its 8 px at the left; its bar when the column is higher than it
  local sx, sy, sw, sh = box.x + 8, box.y, box.w - 8, box.h
  local cw = sw - 12
  local need = self:content_h(cw)
  local bar = need > sh
  local vw = bar and sw - 10 or sw
  if bar then cw = vw - 12 need = self:content_h(cw) end
  local body_h = math.max(sh, need)
  local b = self.bar
  b.single, b.page = 20, sh
  IV.range(b, body_h - sh)
  -- the wheel (a notch: 3 lines of 20 px)
  -- (where the mouse is, no item: an item over the whole area took the presses of the buttons in it - 23.10. Place,
  -- the path's copy and the tags did nothing)
  local vp = {x = sx, y = sy, w = vw, h = sh}
  local mx0, my0 = w3.ui.mouse()
  local pn = self.panel
  local over = not (pn and pn.blocked) and not (CT.blocker and CT.blocker(mx0, my0)) and
               not require("conjunction.ui.inline_menu").covers(mx0, my0) and
               mx0 >= vp.x and my0 >= vp.y and mx0 < vp.x + vp.w and my0 < vp.y + vp.h
  local pr = self.pic_rect                       -- (over the 3D view the wheel is its own)
  if over and self.showing3d and pr and mx0 >= pr.x and mx0 < pr.x + pr.w and my0 >= pr.y and my0 < pr.y + pr.h then
    over = false
  end
  if over then
    local _, _, wheel = w3.ui.mouse()
    if wheel ~= 0 then
      local n = wheel
      while n ~= 0 do
        local one = n >= 1 and 1 or (n <= -1 and -1 or n)
        n = n - one
        if math.abs(n) < 1e-9 then n = 0 end
        IV.wheel(b, one, 3)
      end
    end
  end
  local items = self:items(cw)
  local col = {}
  for i, it in ipairs(items) do col[i] = {hint = it.h, min = it.h, max = it.h} end
  col[#col + 1] = {hint = 0, min = 0, stretch = 1, empty = true}   -- (addStretch: a spacer takes no spacing)
  local placed = L.column(col, sx, sy - b.value, vw, body_h, {margins = {6, 6, 6, 6}, spacing = 6})
  D.clip(sx, sy, vw, sh, function()
    for i, it in ipairs(items) do self:draw_item(it.key, placed[i], e) end
  end)
  if bar then
    SBAR.draw(self, "ins.vbar", b, {x = sx + vw, y = sy, w = 10, h = sh}, "v",
              function(id, r) return self:hit(id, r) end)
  end
  self._fc = nil
end

function INS:draw_item(key, r, e)
  if key == "pic" and self.showing3d and self.v3.mesh then
    self.pic_rect = r
    self.v3:draw(r, function(id, rr) return self:hit(id, rr) end)
  elseif key == "pic" then
    self.pic_rect = r
    Q.frame(r.x, r.y, r.w, r.h, C.pic_bg, C.pic_edge)
    local size = e.type == "item" and 64 or 320
    local cv = self.panel and self.panel.catalog
    local pic = cv and cv:picture(e, size)
    local ix, iy, iw, ih = r.x + 1, r.y + 1, r.w - 2, r.h - 2
    if pic then
      local pw, ph = PIC.size(pic)
      local w = INS.PIC_W
      if e.type == "item" then w = math.min(INS.PIC_W, pw * 2) end
      local id, tw, th = PIC.texture(pic, w, w, C.pic_bg)
      if id then D.image(id, ix + (iw - tw) // 2, iy + (ih - th) // 2, tw, th) end
    else
      local s = "-"
      Q.text(ix + (iw - Q.text_w(s, 13)) // 2, iy + Q.vcenter(ih, Q.line_h(13)), C.label, s, 13, false, C.pic_bg)
    end
    if self.panel and self.panel.tip then
      local _, hv = self:hit("ins.pic", r)
      if hv then CT.tip("panel.ins.pic", "ins.picture3d") end
      -- (pressed: the thing itself in 3D)
      if hv and (w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(2) or w3.ui.mouse_clicked(3))
         and e.type == "template" and not M.is_folder(e) then
        self:load_3d()
      end
    end
  elseif key == "look" then
    self:draw_look(r)
  elseif key == "rename" then
    local PN = require("conjunction.ui.panel")
    local st = setmetatable({px = 13, bold = true}, {__index = PN.EDIT_STYLE})   -- (font:bold 13px on the field)
    local _, text, enter = CT.edit("panel.ins.rename", r.x, r.y, r.w, self.rename or "", {style = st, h = 31,
                                   tip = self.own and "ic.own_name" or "ic.rename"})
    self.rename = text
    if enter and self.on_place then self.on_place(e) end        -- (rename.returnPressed: taken as it is shown)
  elseif key == "own_tools" then
    local text = e.own_text ~= "" and "Edit text" or "+ Text to read"
    local row = L.row({{hint = 52, min = 52, stretch = 1, cross = 29, cross_max = 29},
                       {hint = 90, min = 90, max = 90, cross = 29, cross_max = 29}}, r.x, r.y, r.w, r.h, {spacing = 6})
    local b, d = row[1], row[2]
    local clicked, hv, held = self:hit("ins.own_text", b)
    push(b.x, b.y, b.w, b.h, text, nil, 16, {hover = hv or held, pressed = held and hv})
    if hv then CT.tip("panel.ins.own_text", {"", "What Geralt reads when he opens it (empty: a plain quest item)"}) end
    if clicked and self.on_own_text then self.on_own_text(e) end
    local dc, dhv, dheld = self:hit("ins.own_drop", d)
    push(d.x, d.y, d.w, d.h, "Delete", nil, 16, {hover = dhv or dheld, pressed = dheld and dhv})
    if dhv then CT.tip("panel.ins.own_drop", {"", "Takes it out of the quest (asks first when a step uses it)"}) end
    if dc and self.on_own_drop then self.on_own_drop(e) end
  elseif key == "rename_note" then
    Q.text(r.x, r.y, C.note, "A new item of this quest", 11)
  elseif key == "redescribe" then
    local _, text = require("conjunction.ui.plaintext").edit("panel.ins.redescribe", r.x, r.y, r.w, r.h,
                                                              self.redescribe or "",
                                                              {placeholder = "Description", tip = "ic.redescribe"})
    self.redescribe = text
  elseif key == "title" then
    draw_lines(label_lines(self.title, 14, true, r.w), r.x, r.y, C.title, 14, true, Q.line_h(14, true))
  elseif key == "subtitle" then
    draw_lines(label_lines(self.subtitle, 13, false, r.w), r.x, r.y, C.label, 13, false, Q.line_h(13))
  elseif key == "note" then
    D.rect(r.x, r.y, r.w, r.h, C.note_edge, 1)
    local m = Q.text_w("x", 11) // 2
    local lines = label_lines(self.note, 11, false, r.w - 10 - m)
    local lh = Q.line_h(11)
    draw_lines(lines, r.x + 5 + m, r.y + 5 + Q.vcenter(r.h - 10, #lines * lh), C.note, 11, false, lh)
  elseif key == "voice" then
    draw_lines(label_lines(self.voice.text, 11, false, r.w), r.x, r.y, self.voice.colour, 11, false, Q.line_h(11))
  elseif key == "path" then
    local line, bh = path_box(self.path, r.w)
    local row = L.row({{hint = 0, min = 0, stretch = 1, cross = bh, cross_max = bh, key = "edit"},
                       {hint = 23, min = 23, max = 23, cross = 23, cross_max = 23, key = "copy"}},
                      r.x, r.y, r.w, r.h, {spacing = 6})
    local pe, pc = row[1], row[2]
    if self.path_shown then
      D.fill(pe.x, pe.y, pe.w, pe.h, T.FIELD)
      D.rect(pe.x, pe.y, pe.w, pe.h, T.EDGE, 1)
      Q.text(pe.x + 6, pe.y + 6, T.BRIGHT, line, INS.PATH_PX, false, T.FIELD)
    end
    if self.copy_shown then
      local clicked, hv = self:hit("ins.copy", pc)
      if hv then
        D.fill(pc.x, pc.y, pc.w, pc.h, C.icon_hover)
        w3.ui.cursor("hand")
        CT.tip("panel.ins.copy", "ins.copy")
      end
      Q.draw_icon_file(hv and "copy_ffffff_16" or "copy_cfcfcf_16", pc.x + (pc.w - 16) // 2, pc.y + (pc.h - 16) // 2)
      if clicked then w3.ui.clipboard(INS.disk_folder(self.path) or self.path) end
    end
  elseif key == "buttons" then
    local items = {}
    if self.place_shown then
      items[#items + 1] = {hint = 52, min = 52, stretch = 1, cross = 29, cross_max = 29, key = "place"}
    end
    if not self.own then           -- (an own item is no favourite: it is this quest's)
      items[#items + 1] = {hint = 40, min = 40, max = 40, cross = 32, cross_max = 32, key = "fav"}
    end
    local row = L.row(items, r.x, r.y, r.w, r.h, {spacing = 6})
    for i, it in ipairs(items) do
      local b = row[i]
      local clicked, hv, held = self:hit("ins." .. it.key, b)
      if it.key == "place" then
        push(b.x, b.y, b.w, b.h, self.place_text, self.place_icon and "dices_e3c65f_16", 16,
             {hover = hv or held, pressed = held and hv})
        if hv then CT.tip("panel.ins.place", "ins.place") end
        if clicked and self.on_place then self.on_place(e) end
      else
        push(b.x, b.y, b.w, b.h, "", self.fav and "star_on_20" or "star_off_20", 20, {hover = hv or held, pressed = held and hv})
        if hv then CT.tip("panel.ins.fav", "ins.fav") end
        if clicked then
          self.fav = not self.fav
          if self.on_favourite then self.on_favourite(e) end
        end
      end
    end
  elseif key == "chips" then
    local lw = self.chip_lw
    local fx, fw = r.x + lw + 8, r.w - lw - 8
    local y = r.y + 4
    for _, row in ipairs(self.chip_rows) do
      Q.text(r.x, y, C.key, row[1], 12)
      local places, fh = flow(row[2], fw)
      for i, ch in ipairs(row[2]) do
        local p = places[i]
        local b = {x = fx + p.x, y = y + p.y, w = p.w, h = p.h}
        local clicked, hv = self:hit("ins.tag." .. row[1] .. "." .. i, b)
        local edge, fg = C.tag_edge, C.tag_text
        if hv then edge, fg = C.tag_hover, T.WHITE w3.ui.cursor("hand") CT.tip("panel.ins.tag", {ch[1], "Shows everything of this kind"}) end
        D.fill(b.x, b.y, b.w, b.h, edge)
        D.fill(b.x + 1, b.y + 1, b.w - 2, b.h - 2, C.tag_bg)
        local lh = Q.line_h(11)
        Q.text(b.x + (b.w - Q.text_w(ch[1], 11)) // 2, b.y + Q.vcenter(b.h, lh), fg, ch[1], 11, false, C.tag_bg)
        if clicked and self.on_overview then self.on_overview(ch[2][1], ch[2][2]) end
      end
      y = y + math.max(fh, Q.line_h(12)) + 4
    end
  elseif key == "obj" then
    self:draw_obj(r)
  elseif key == "facts" then
    local lay = self.facts_lay
    local lh = Q.line_h(FPX)
    for _, c in ipairs(lay.cells) do draw_lines(c.lines, r.x + c.x, r.y + c.y, c.colour, FPX, false, lh) end
  end
end

require("conjunction.ui.inspector_object")(INS)

-- one layout per frame and width: frame() asks content_h twice and items once, draw_obj the object's parts again -
-- built anew each time, they made most of the editor's garbage while an object was selected (27.10.: the garbage
-- collector then stood 70-100 ms every second). Only inside frame() (self._fc); outside it, built as asked
do
  local items, parts = INS.items, INS.obj_parts
  function INS:items(cw)
    local fc = self._fc
    if not fc then return items(self, cw) end
    local hit = fc["i" .. cw]
    if not hit then
      local it = items(self, cw)
      hit = {it, self.facts_lay}                  -- (items lays the facts out for this width: drawn with it)
      fc["i" .. cw] = hit
    end
    self.facts_lay = hit[2]
    return hit[1]
  end
  function INS:obj_parts(cw)
    local fc = self._fc
    if not fc then return parts(self, cw) end
    local hit = fc["o" .. cw]
    if not hit then
      hit = table.pack(parts(self, cw))
      fc["o" .. cw] = hit
    end
    return table.unpack(hit, 1, hit.n)
  end
end

return INS
