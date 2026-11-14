-- The Asset Browser's logic (conjunction/catalog_view.py's CatalogView without its widgets): what the grid lists for
-- the tab, the search, the type tree's branch, the styles and traits, an open folder of variants or of looks; the
-- type tree's items, the crumb's text, the chips, the counts; the way back, favourites and recently used, the view
-- mode and the order, kept in the config as the app keeps them. ui/catalog_view.lua draws it.
-- Checked against the app's CatalogView: ingame/ref/catalog_model_check.py.
local S = require("conjunction.pystr")
local PS = require("conjunction.pysort")
local Y = require("conjunction.yaml")
local CFG = require("conjunction.config")
local CAT = require("conjunction.catalog")
local TAX = require("conjunction.taxonomy")
local TALK = require("conjunction.talking")
local LC = require("conjunction.look_chooser")
local ASSETS = require("conjunction.assets")
local M = {}
M.__index = M

M.TABS = {"Objects", "Items", "Favourites", "Recent"}
M.OWN = 4                                            -- (a tab of the item window only: Custom)
M.TAB_TIPS = {"cat.tab.objects", "cat.tab.items", "cat.tab.favourites", "cat.tab.recent"}
M.FOLDER_CATS = {People = true, Creatures = true, Animals = true}
M.VOICE_COLOUR = {all = "#5cb85c", some = "#e3c65f", none = "#d9534f"}
M.VOICE_TEXT = {all = "Can talk (every look moves the mouth)",
                some = "Some looks stay silent (a speaker needs one that talks, the quest board shows it)",
                none = "Stays silent (no look moves the mouth)"}
M.RECENT_MAX = 30
M.VIEWS = {{"xl", "Extra large icons", 192}, {"large", "Large icons", 128}, {"medium", "Medium icons", 96},
           {"small", "Small icons", 32}, {"list", "List", 20}, {"details", "Details", 20}, {"tiles", "Tiles", 64}}
M.VIEW_SIZE = {}
for _, v in ipairs(M.VIEWS) do M.VIEW_SIZE[v[1]] = v[3] end
M.SORTS = {{"found", "Best match"}, {"name", "Name"}, {"kind", "Kind"}, {"recent", "Recently used"}}
M.SHORT = {xl = "XL", large = "Large", medium = "Medium", small = "Small", list = "List", details = "Details",
           tiles = "Tiles", found = "Best", name = "Name", kind = "Kind", recent = "Recent"}
M.NARROW = 560
M.PAGE = 300
M.TRAITS = {{"clue", "Clue"}, {"interior", "Interior"}, {"inventory", "Inventory"}, {"lootable", "Lootable"},
            {"usable", "Usable"}, {"light", "Light"}, {"destructible", "Destructible"}, {"named", "Named"},
            {"pack", "Content packs"}}
M.DETAILS = {"Name", "Kind", "From", "Traits", "File"}

-- Python's bool() of a row's value
local function truthy(v)
  return not (v == nil or v == false or v == Y.null or v == 0 or v == "" or (type(v) == "table" and next(v) == nil))
end
-- Python's `x in v`: a list's element, a string's substring (a row read alone keeps its traits as one string)
local function has(list, x)
  if type(list) == "string" then return list:find(x, 1, true) ~= nil end
  for _, v in ipairs(list or {}) do if v == x then return true end end
  return false
end
-- ", ".join(v): a list's elements, a string's characters
local function join(v, sep)
  if type(v) == "string" then
    local out = {}
    for _, c in utf8.codes(v) do out[#out + 1] = utf8.char(c) end
    return table.concat(out, sep)
  end
  return table.concat(v or {}, sep)
end
local function copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

-- --- entries ---
-- the looks the game picks one of when it spawns this person: two or more make the person a folder of them
function M.looks_of(r)
  if not r or (r.own_cat or r.cat) ~= "People" then return {} end
  local looks = TALK.spawn_looks(r.path)
  if #looks > 1 then return looks end
  return {}
end
function M.is_folder(e) return truthy(e.members) or truthy(e.looks) end
function M.folder_count(e)
  if truthy(e.members) then return #e.members end
  if truthy(e.looks) then return #e.looks end
  return 0
end
-- talking.voice of an entry (a folder: of all its variants; a look: "all" or "none" for it alone); nil: not a person
-- or not read yet
function M.voice_of(e)
  local row = e.row or {}
  if (row.own_cat or row.cat) ~= "People" then return nil end
  if e.look ~= nil then
    local talks = TALK.known_talking(e.path)
    if talks == nil then return nil end
    return has(talks, e.look) and "all" or "none"
  end
  return TALK.voices(truthy(e.members) and e.members or {e.path})
end
function M.folder_text(e)
  if truthy(e.members) then
    return string.format("Places a random variant (%d in this folder), each with a random look. Double click to " ..
                         "open the folder for a specific variant", #e.members)
  end
  return string.format("Places this person with a random look (%d looks). Double click to open the folder for a " ..
                       "specific look", #e.looks)
end
-- the grid's tooltip of an entry (Model.data's ToolTipRole)
function M.tooltip(e)
  local r = e.row or {}
  local what = {}
  for _, x in ipairs({r.cat, r.sub}) do if truthy(x) then what[#what + 1] = x end end
  what = table.concat(what, " / ")
  local first = what
  if not truthy(first) then first = e.sub end
  if not truthy(first) then first = e.path end
  if not truthy(first) then first = e.name end
  local lines = {first}
  if M.is_folder(e) then lines[#lines + 1] = M.folder_text(e) end
  local v = M.voice_of(e)
  if v and v ~= "some" then lines[#lines + 1] = M.VOICE_TEXT[v] end
  return table.concat(lines, "\n")
end
-- the Details view's text of a column (DetailsModel.text)
function M.details_text(e, col)
  local row = e.row or {}
  if col == 0 then return e.title end
  if col == 1 then
    local what = {}
    for _, x in ipairs({row.cat, row.sub}) do if truthy(x) then what[#what + 1] = x end end
    local t = table.concat(what, " / ")
    if t ~= "" then return t end
    return truthy(e.sub) and e.sub or ""
  end
  if col == 2 then
    if truthy(row.source) then return row.source end
    local PATHS = require("conjunction.paths")
    return PATHS.basename(truthy(row.file) and row.file or "")
  end
  if col == 3 then return join(truthy(row.traits) and row.traits or {}, ", ") end
  if truthy(e.path) then return e.path end
  if truthy(e.name) then return e.name end
  return ""
end

-- --- the model ---
function M.new(assets, opts)
  opts = opts or {}
  local cfg = CFG.load()
  local self = setmetatable({assets = assets}, M)
  self.favourites = {}
  for _, k in ipairs(Y.is_list(cfg.favourites) and cfg.favourites or {}) do self.favourites[#self.favourites + 1] = k end
  self.recent = {}
  for _, k in ipairs(Y.is_list(cfg.recent_templates) and cfg.recent_templates or {}) do self.recent[#self.recent + 1] = k end
  self.cat, self.sub = nil, nil
  self.folder, self.look_folder = nil, nil
  self.hide = opts.hide                              -- (row) -> true: not offered here
  self.picked_member = {}
  self.history = {}
  self.styles, self.traits = {}, {}                  -- sets: {name = true}, their order of choosing kept
  self.mode = M.VIEW_SIZE[cfg.asset_view] and cfg.asset_view or "medium"
  self.sort_by = (cfg.asset_sort ~= nil and cfg.asset_sort ~= Y.null) and cfg.asset_sort or "found"
  local nav = cfg.asset_nav
  if nav == nil then nav = true end
  self.nav_wanted = truthy(nav)
  self.filters_open = truthy(cfg.catalog_filters_open)
  self.tab, self.text, self.quest = 0, "", false
  self.choice = opts.choice or function(list) return list[math.random(#list)] end   -- (random.choice)
  self.entries = {}
  self.rows = {}
  self.own = opts.own                                -- () -> the quest's own items as entries (an item window's Custom)
  self.width = opts.width or 1000
  self:refresh()
  return self
end

function M:fav_set()
  if self._fav_src ~= table.concat(self.favourites, "\0") then
    self._fav_src = table.concat(self.favourites, "\0")
    self._favs = {}
    for _, k in ipairs(self.favourites) do self._favs[k] = true end
  end
  return self._favs
end

function M:entry_template(r)
  local e = self.entries[r.path]
  if e == nil or e.row ~= r then
    local sub
    if truthy(r.named) then sub = CAT.caption(r.path)
    elseif truthy(r.sub) then sub = r.sub
    else sub = r.kind end
    local looks = M.looks_of(r)
    if #looks > 0 then sub = string.format("%d looks", #looks) end
    e = {type = "template", key = r.path, path = r.path, title = r.name, looks = looks, sub = sub, mesh = r.mesh,
         kind = r.kind, inv = truthy(r.inventory), loot = has(r.traits, "lootable"), row = r}
    self.entries[r.path] = e
  end
  local out = copy(e)
  out.fav = self:fav_set()[r.path] == true
  return out
end

function M:entry_folder(k, rows)
  local key = string.format("folder:%s:%s", k[1], k[2])
  local paths = {}
  for i, r in ipairs(rows) do paths[i] = r.path end
  if self.picked_member[key] == nil or not has(paths, self.picked_member[key]) then
    self.picked_member[key] = self.choice(rows).path
  end
  local rep
  for _, r in ipairs(rows) do if r.path == self.picked_member[key] then rep = r break end end
  local e = self:entry_template(rep)
  e.key, e.title, e.sub, e.folder = key, k[2], string.format("%d variants", #rows), k
  e.members, e.looks, e.fav = paths, {}, false
  return e
end

-- os.path.commonprefix: the longest start all share (character by character)
local function common_prefix(list)
  if #list == 0 then return "" end
  local lo, hi = list[1], list[1]
  for _, s in ipairs(list) do
    if PS.lt(s, lo) then lo = s end
    if PS.lt(hi, s) then hi = s end
  end
  local a, b = S.cps(lo), S.cps(hi)
  local n = 0
  while n < #a and n < #b and a[n + 1] == b[n + 1] do n = n + 1 end
  return S.from_cps(a, 1, n)
end

function M:entry_look(r, look)
  local key = r.path .. "#" .. look
  local looks = M.looks_of(r)
  local short = LC.label(look)
  if #looks > 1 then
    local cut = common_prefix(looks)
    local cc = S.cps(cut)
    local last = 0
    for i = #cc, 1, -1 do if cc[i] == 95 then last = i break end end   -- (cut[:cut.rfind("_") + 1])
    local n = last
    local lc = S.cps(look)
    local rest = S.from_cps(lc, n + 1, #lc)
    local lab = LC.label(rest)
    if truthy(lab) then short = lab end
  end
  local inside = self.look_folder == r.path
  return {type = "template", key = key, path = r.path, look = look,
          title = inside and ("Look " .. short) or (r.name .. ", look " .. short), sub = LC.label(look), mesh = nil,
          kind = r.kind, inv = truthy(r.inventory), loot = false, row = r, fav = self:fav_set()[key] == true}
end

function M:entry_item(r)
  local sub = truthy(r.sub) and r.sub or (r.category:gsub("_", " "))
  return {type = "item", key = "item:" .. r.name, name = r.name, title = truthy(r.label) and r.label or r.name,
          sub = sub, kind = r.category, fav = has(self.favourites, "item:" .. r.name), row = r}
end

-- templates of the folder kinds sharing a name: one folder entry each, at the first one's place
function M:folders(found)
  local members, order = {}, {}
  for _, r in ipairs(found) do
    if M.FOLDER_CATS[r.cat] and truthy(r.named) then
      local k = r.cat .. "\0" .. r.name
      if not members[k] then members[k] = {} order[#order + 1] = k end
      local l = members[k]
      l[#l + 1] = r
    end
  end
  local out, done = {}, {}
  for _, r in ipairs(found) do
    local k = tostring(r.cat) .. "\0" .. tostring(r.name)
    local m = members[k]
    if not m or #m < 2 then
      out[#out + 1] = self:entry_template(r)
    elseif not done[k] then
      done[k] = true
      out[#out + 1] = self:entry_folder({r.cat, r.name}, m)
    end
  end
  return out
end

function M:sorted(rows)
  if self.sort_by == "name" then
    return PS.sorted(rows, function(e) return S.lower(e.title) end)
  elseif self.sort_by == "kind" then
    return PS.sorted(rows, function(e) return {S.lower(M.details_text(e, 1)), S.lower(e.title)} end)
  elseif self.sort_by == "recent" then
    local order = {}
    for i, k in ipairs(self.recent) do order[k] = i - 1 end      -- (a dict: a key twice keeps its last place)
    local n = 0
    for _ in pairs(order) do n = n + 1 end
    return PS.sorted(rows, function(e) return order[e.key] or n end)
  end
  return rows
end

local function set_list(set_order)
  local out = {}
  for _, k in ipairs(set_order) do out[#out + 1] = k end
  return out
end
-- the styles / traits chosen, in the order they were chosen (a Python set; only "is it in" is asked of it)
function M:style_list() return set_list(self._style_order or {}) end
function M:trait_list() return set_list(self._trait_order or {}) end

function M:refresh()
  local text, tab = self.text, self.tab
  local facets
  local rows
  local A = ASSETS
  local function empty(total) return {tree = A.Counter(), styles = A.Counter(), traits = A.Counter(), total = total} end
  if tab == 0 and self.look_folder then
    local r = self.assets:template(self.look_folder)
    rows = {}
    for _, lk in ipairs(M.looks_of(r)) do rows[#rows + 1] = self:entry_look(r, lk) end
    facets = empty(#rows)
    facets.tree:add(r.cat .. " " .. r.sub, #rows)     -- (the type tree counts what the folder shows - 22.10.: it
    -- said "Everything 0")
  elseif tab == 0 and self.folder then
    local cat, name = self.folder[1], self.folder[2]
    local found = self.assets:browse("", cat, nil, {}, {}, self.quest, 100000)
    rows = {}
    for _, r in ipairs(found) do
      if r.name == name then rows[#rows + 1] = self:entry_template(r) end
    end
    facets = empty(#rows)
    for _, r in ipairs(found) do
      if r.name == name then facets.tree:add(r.cat .. " " .. r.sub) end
    end
  elseif tab == 0 then
    local found
    found, facets = self.assets:browse(text, self.cat, self.sub, self:style_list(), self:trait_list(), self.quest, 100000)
    if self.hide then
      local keep = {}
      for _, r in ipairs(found) do if not self.hide(r) then keep[#keep + 1] = r end end
      found = keep
    end
    rows = self:folders(found)
  elseif tab == 1 then
    local found
    found, facets = self.assets:browse_items(text, self.cat, self.sub)
    rows = {}
    for i, r in ipairs(found) do rows[i] = self:entry_item(r) end
  elseif tab == M.OWN then                           -- (the quest's own items, by their name)
    rows = {}
    local q = S.lower(S.strip(text))
    for _, e in ipairs(self.own and self.own() or {}) do
      if q == "" or S.lower(e.title):find(q, 1, true) then rows[#rows + 1] = e end
    end
  else
    local keys = tab == 2 and self.favourites or self.recent
    rows = {}
    for _, k in ipairs(keys) do
      if k:find("#", 1, true) and k:sub(1, 5) ~= "item:" then      -- a look of a person
        local path, look = k:match("^(.-)#(.*)$")
        local r = self.assets:template(path)
        if r then rows[#rows + 1] = self:entry_look(r, look) end
      else
        local r
        if k:sub(1, 5) == "item:" then r = self.assets:item(k:sub(6)) else r = self.assets:template(k) end
        if r then
          rows[#rows + 1] = k:sub(1, 5) == "item:" and self:entry_item(r) or self:entry_template(r)
        end
      end
    end
  end
  self.rows = self:sorted(rows)
  self.shown = math.min(#self.rows, M.PAGE)          -- (the grid shows a page at a time: fetch_more)
  self.sort_text = (M.SHORT[self.sort_by] or "Best") .. "  \u{25be}"
  self.view_text = M.SHORT[self.mode] .. "  \u{25be}"
  self.has_tree = facets ~= nil
  self.facets = facets
  self.boxes_shown = tab == 0 and self.filters_open
  self.filter_shown = tab == 0
  self.crumb_shown = facets ~= nil
  if facets ~= nil then
    self.tree = self:fill_tree(facets.tree, tab)
    self.crumb = self:fill_crumb(facets.total, tab)
  end
  if tab == 0 then self:fill_chips(facets) end
  self.count_text = tostring(facets and facets.total or #self.rows)
  self:sync_nav()
end

-- the next page, when the grid is scrolled to its end (Model.fetchMore)
function M:fetch_more()
  if self.shown < #self.rows then self.shown = math.min(#self.rows, self.shown + M.PAGE) return true end
  return false
end

-- the type tree: {text, count, depth, cat, sub, hidden, expanded, has_children} in order, and which is chosen
function M:fill_tree(counts, tab)
  local groups, gorder = {}, {}
  for _, k in ipairs(counts.keys) do
    local c, s = k:match("^(.-)%z(.*)$")
    if not groups[c] then groups[c] = {order = {}, n = {}} gorder[#gorder + 1] = c end
    local g = groups[c]
    if g.n[s] == nil then g.order[#g.order + 1] = s end
    g.n[s] = counts.n[k]
  end
  if self.cat and not groups[self.cat] then
    groups[self.cat] = {order = {}, n = {}}
    gorder[#gorder + 1] = self.cat
    if self.sub then groups[self.cat].order = {self.sub} groups[self.cat].n[self.sub] = 0 end
  end
  local visible = 0
  for _, c in ipairs(gorder) do
    if not TAX.HIDDEN_GROUPS[c] then
      for _, s in ipairs(groups[c].order) do visible = visible + groups[c].n[s] end
    end
  end
  local items = {{text = "Everything", count = tostring(visible), depth = 0, cat = nil, sub = nil, top = true}}
  local chosen = 1
  local order = tab == 1 and TAX.ITEM_GROUP_ORDER or TAX.GROUP_ORDER
  for _, c in ipairs(TAX.sort_groups(gorder, order)) do
    local g = groups[c]
    local n = 0
    for _, s in ipairs(g.order) do n = n + g.n[s] end
    if not (TAX.HIDDEN_GROUPS[c] and c ~= self.cat and n == 0) then
      local it = {text = c, count = tostring(n), depth = 0, cat = c, sub = nil, hidden = TAX.HIDDEN_GROUPS[c] == true,
                  expanded = c == self.cat, children = {}}
      items[#items + 1] = it
      if c == self.cat and not self.sub then chosen = #items end
      -- (Content packs: each pack its branch, one pack too)
      if #g.order > 1 or c == TAX.PACKS or (c == self.cat and self.sub) then
        local subs = {}
        for _, s in ipairs(g.order) do subs[#subs + 1] = {s, g.n[s]} end
        PS.sort(subs, function(x) return {x[1]:sub(1, 5) == "Other", -x[2]} end)
        for _, x in ipairs(subs) do
          local ch = {text = x[1], count = tostring(x[2]), depth = 1, cat = c, sub = x[1]}
          it.children[#it.children + 1] = ch
          if c == self.cat and x[1] == self.sub then ch.chosen = true end
        end
      end
    end
  end
  for _, it in ipairs(items) do
    if it.children then
      for _, ch in ipairs(it.children) do if ch.chosen then chosen = ch end end
    end
  end
  if type(chosen) == "number" then items[chosen].chosen = true end
  return items
end

-- the crumb's rich text, as the app sets it (a QLabel's HTML: links, bold, a grey count)
function M:fill_crumb(total, tab)
  local function link(href, text) return string.format("<a style='color:#dddddd;text-decoration:underline' href='%s'>%s</a>", href, text) end
  local function here(text) return string.format("<b style='color:#eee'>%s</b>", text) end
  -- an open folder of variants or of looks: the whole way to it, every level a link, the open one bold (MaximdeWinter 13.11.:
  -- "Everything / Ciri / Ciri" had only Everything to click; 12.11. "Back / background nazairi" read as a folder
  -- named Back - so no Back here)
  if self.folder or self.look_folder then
    local all = {link("all", "Everything")}
    if self.cat then all[#all + 1] = link("cat", self.cat) end
    if self.cat and self.sub then all[#all + 1] = link("sub", self.sub) end
    if self.look_folder then
      if self.folder then all[#all + 1] = link("folder", self.folder[2]) end
      local r = self.assets:template(self.look_folder) or {}
      all[#all + 1] = here(r.name or "")
      return table.concat(all, " / ") .. string.format("<span style='color:#777'> &nbsp;%d looks</span>", total)
    end
    all[#all + 1] = here(self.folder[2])
    return table.concat(all, " / ") .. string.format("<span style='color:#777'> &nbsp;%d variants</span>", total)
  end
  local parts = {self.cat and link("all", "Everything") or here("Everything")}
  if #self.history > 0 then table.insert(parts, 1, link("back", "Back")) end
  if self.cat then
    parts[#parts + 1] = self.sub and link("cat", self.cat) or string.format("<b style='color:#eee'>%s</b>", self.cat)
  end
  if self.sub then parts[#parts + 1] = string.format("<b style='color:#eee'>%s</b>", self.sub) end
  return table.concat(parts, " / ") .. string.format("<span style='color:#777'> &nbsp;%d</span>", total)
end

-- the chips: {text, checked, visible} per style (taxonomy.STYLES' order) and per trait, then "+ quest things"
function M:fill_chips(facets)
  local counts = facets.styles
  self.style_chips = {}
  for _, st in ipairs(TAX.STYLES) do
    local s = st[1]
    local n = counts:get(s)
    self.style_chips[#self.style_chips + 1] = {key = s, text = (string.format("%s  %d", s, n):gsub("&", "&&")),
                                               checked = self.styles[s] == true, visible = n > 0 or self.styles[s] == true}
  end
  self.trait_chips = {}
  for _, t in ipairs(M.TRAITS) do
    local n = facets.traits:get(t[1])
    self.trait_chips[#self.trait_chips + 1] = {key = t[1], text = (string.format("%s  %d", t[2], n):gsub("&", "&&")),
                                               checked = self.traits[t[1]] == true,
                                               visible = n > 0 or self.traits[t[1]] == true}
  end
  local on = 0
  for _ in pairs(self.styles) do on = on + 1 end
  for _ in pairs(self.traits) do on = on + 1 end
  if self.quest then on = on + 1 end
  self.filter_text = on > 0 and string.format("Filters  %d", on) or "Filters"
end

-- the category tree: when wanted and there is room; narrow, the folder button shows it in the grid's place
function M:sync_nav()
  local room = self.width >= M.NARROW
  local narrow_nav = not room and self.has_tree and self.narrow_nav == true
  self.tree_shown = self.has_tree and ((self.nav_wanted and room) or narrow_nav)
  self.tree_full = narrow_nav                         -- (the whole width: the grid is away)
  local details = self.mode == "details"
  self.grid_shown = not narrow_nav and not details
  self.table_shown = not narrow_nav and details
  self.nav_checked = (self.nav_wanted and room) or narrow_nav
  self.nav_shown = self.has_tree
end

function M:set_width(w)
  if w ~= self.width then
    self.width = w
    self:sync_nav()
  end
end

-- --- what the user does ---
local function save(key, value) CFG.set(key, value) end

function M:set_view(mode, keep)
  if keep == nil then keep = true end
  self.mode = mode
  self.view_text = M.SHORT[mode] .. "  \u{25be}"
  if keep then save("asset_view", mode) end
  self:sync_nav()
end
function M:set_sort(key)
  self.sort_by = key
  save("asset_sort", key)
  self:refresh()
end
function M:toggle_nav(checked)
  if self.width < M.NARROW then
    self.narrow_nav = checked
    self:sync_nav()
    return
  end
  self.nav_wanted = checked
  save("asset_nav", checked)
  self:sync_nav()
end
function M:toggle_filters(checked)
  self.filters_open = checked
  self.boxes_shown = self.tab == 0 and checked
  save("catalog_filters_open", checked)
end
function M:set_tab(i)
  if i == self.tab then return end
  self.tab = i
  self.cat, self.sub = nil, nil
  self:refresh()
end
function M:set_text(text)
  if text == self.text then return end
  self.text = text
  self:refresh()
end
function M:toggle_quest()
  self.quest = not self.quest
  self:refresh()
end
-- a click on the tree: its branch (the chosen branch with nothing below: open or closed)
function M:tree_clicked(item)
  -- (the app opens or closes the chosen branch here, and the refresh below builds the tree anew with it open)
  local cat, sub = item.cat, item.sub
  self.cat, self.sub = cat, sub
  if self.narrow_nav and not (item.children and #item.children > 0) then self.narrow_nav = false end
  self:refresh()
end
function M:crumb_link(link)
  if link == "back" then self:back() return end
  if self.folder or self.look_folder then                   -- (out of a folder: Back leads into it again - push)
    self.history[#self.history + 1] = self:state()
    while #self.history > 20 do table.remove(self.history, 1) end
  end
  if link == "all" then self.cat, self.sub = nil, nil
  elseif link == "cat" then self.sub = nil end
  if link == "folder" then self.look_folder = nil
  else self.folder, self.look_folder = nil, nil end
  self:refresh()
end
-- left click: only this one (the only one again: none); right click: add it or take it out
function M:pick(which, key, add)
  local set = which == "styles" and self.styles or self.traits
  local okey = which == "styles" and "_style_order" or "_trait_order"
  self[okey] = self[okey] or {}
  local order = self[okey]
  local function remove(k)
    set[k] = nil
    for i, x in ipairs(order) do if x == k then table.remove(order, i) break end end
  end
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  if add then
    if set[key] then remove(key) else set[key] = true order[#order + 1] = key end
  elseif n == 1 and set[key] then
    remove(key)
  else
    for k in pairs(set) do set[k] = nil end
    for i = #order, 1, -1 do order[i] = nil end
    set[key] = true
    order[1] = key
  end
  self:refresh()
end

function M:state()
  local function copyset(s) local o = {} for k in pairs(s) do o[k] = true end return o end
  return {tab = self.tab, text = self.text, cat = self.cat, sub = self.sub, styles = copyset(self.styles),
          traits = copyset(self.traits), style_order = self:style_list(), trait_order = self:trait_list(),
          folder = self.folder, look_folder = self.look_folder}
end
local function push(self)
  self.history[#self.history + 1] = self:state()
  while #self.history > 20 do table.remove(self.history, 1) end
end
function M:open_folder(e)
  push(self)
  self.folder, self.look_folder = e.folder, nil
  self:refresh()
end
function M:open_looks(e)
  push(self)
  self.look_folder = e.path
  self:refresh()
end
-- what: "type" (value {cat, sub}), "style", "trait" or "words" (a search)
function M:show_only(what, value)
  push(self)
  self.folder, self.look_folder = nil, nil
  self.tab = 0
  self.cat, self.sub = nil, nil
  self.styles, self.traits, self._style_order, self._trait_order = {}, {}, {}, {}
  local text = ""
  if what == "type" then self.cat, self.sub = value[1], value[2]
  elseif what == "style" then self.styles[value] = true self._style_order = {value}
  elseif what == "trait" then self.traits[value] = true self._trait_order = {value}
  else text = value end
  self.text = text
  self:refresh()
end
function M:back()
  local st = table.remove(self.history)
  if not st then return end
  self.tab, self.text, self.cat, self.sub = st.tab, st.text, st.cat, st.sub
  self.styles, self.traits = st.styles, st.traits
  self._style_order, self._trait_order = st.style_order, st.trait_order
  self.folder, self.look_folder = st.folder, st.look_folder
  self:refresh()
end
-- double click / Enter: a folder opens; anything else is chosen (-> true and the entry)
function M:activate(e)
  if e and truthy(e.members) then self:open_folder(e) return false end
  if e and truthy(e.looks) then self:open_looks(e) return false end
  return e ~= nil, e
end
function M:remember(e)
  local out = {e.key}
  for _, k in ipairs(self.recent) do
    if k ~= e.key and #out < M.RECENT_MAX then out[#out + 1] = k end
  end
  self.recent = out
  self:save_lists()
end
function M:toggle_favourite(e)
  local k = e.key
  if has(self.favourites, k) then
    local out = {}
    for _, x in ipairs(self.favourites) do if x ~= k then out[#out + 1] = x end end
    self.favourites = out
  else
    local out = {k}
    for _, x in ipairs(self.favourites) do out[#out + 1] = x end
    self.favourites = out
  end
  self:save_lists()
  self:refresh()
end
function M:save_lists()
  local cfg = CFG.load()
  cfg.favourites, cfg.recent_templates = Y.list(self.favourites), Y.list(self.recent)
  CFG.save(cfg)
end

-- the Details view's column head clicked: the entries by it (the grid shows the same order)
function M:sort_column(col, descending)
  local shown = {}
  for i = 1, self.shown do shown[i] = self.rows[i] end
  PS.sort(shown, function(e) return S.lower(M.details_text(e, col)) end, descending)
  self.rows = shown                                  -- (set_rows: what was shown is all there is now)
  self.shown = math.min(#shown, M.PAGE)
end

return M
