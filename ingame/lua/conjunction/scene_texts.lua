-- Texts of one's own in the game's scenes (the scene workshop, scene_work.lua). A scene line or an answer shows the
-- text of a string id, and the game skips a line whose id has no text in its tables (measured 30.10.). So Conjunction
-- brings a pool of ids that have one: dlc\dlcconjunctiontexts\content\<language>.w3strings, POOL_SIZE ids from
-- POOL_BASE, each with a marker text ("cj 17"; a line whose text starts with "{" the game skips, 30.10.). The game
-- reads it at its start. A new text takes a free id of the pool; while you work, the subtitle and the answer show the
-- project's text in place of the marker (w3.scene.on_line, w3.scene.on_choice). The build moves the pool ids into the
-- project's own range and puts the texts into its DLC's strings (ST.remap, ST.add_strings).
--   <project>\scene_texts.json   {"texts": {"<pool id>": "text"}}
--   ST.load(dir) -> t   ST.save(dir, t)   ST.new_id(t) -> id   ST.ensure_pool(game) -> written (a restart then)
--   ST.pool_loaded() -> the game has the pool   ST.show(t) -> the subtitles and answers show t's texts
local J = require("conjunction.json")
local WS = require("conjunction.w3strings")
local ST = {}

ST.POOL_BASE, ST.POOL_SIZE = 2099000000, 4000     -- (no id of the game's or its DLCs' strings is there, 30.10.)
ST.FILE = "scene_texts.json"
ST.DLC = "dlcconjunctiontexts"                   -- (strings of a dlc folder: scene lines show them, 30.10.)
ST.SILENT_PER_CHAR, ST.SILENT_MIN = 0.07, 1.5     -- a line without a voice lasts as long as its text (voices.lua)

function ST.marker(id) return "cj " .. (id - ST.POOL_BASE) end
function ST.is_pool(id) return id and id >= ST.POOL_BASE and id < ST.POOL_BASE + ST.POOL_SIZE end
function ST.length_of(text)
  text = text or ""
  return math.max(ST.SILENT_MIN, ST.SILENT_PER_CHAR * (utf8.len(text) or #text))
end

-- --- the project's texts
function ST.load(dir)
  local t = {texts = {}}
  local data = dir and w3.fs.read(dir .. "\\" .. ST.FILE)
  if data then
    local ok, j = pcall(J.decode, data)
    if ok and type(j) == "table" and type(j.texts) == "table" then
      for k, v in pairs(j.texts) do
        local id = math.tointeger(tonumber(k))
        if ST.is_pool(id) and type(v) == "string" then t.texts[id] = v end
      end
    end
  end
  return t
end

function ST.save(dir, t)
  local out = {}
  for id, text in pairs(t.texts) do out[tostring(id)] = text end
  assert(w3.fs.write(dir .. "\\" .. ST.FILE, J.encode({texts = out})))
end

-- the first id of the pool no text of the project has; used: the ids its scenes still show (kept as well)
function ST.new_id(t, used)
  for k = 0, ST.POOL_SIZE - 1 do
    local id = ST.POOL_BASE + k
    if t.texts[id] == nil and not (used and used[id]) then return id end
  end
  error("the project has " .. ST.POOL_SIZE .. " texts of its own in scenes already (the most there can be)", 0)
end

-- --- the pool in the game
function ST.languages(game)
  local out = {}
  for _, e in ipairs(w3.fs.list(game .. "\\content\\content0") or {}) do
    local lang = e.name:match("^(%a+)%.w3strings$")
    if lang and WS.LANGS[lang:lower()] then out[#out + 1] = lang:lower() end
  end
  if #out == 0 then out = {"en"} end
  table.sort(out)
  return out
end

function ST.pool_bytes(lang)
  local texts = {}
  for k = 0, ST.POOL_SIZE - 1 do texts[ST.POOL_BASE + k] = ST.marker(ST.POOL_BASE + k) end
  return WS.write_v164(lang, texts)
end

-- the pool's files in the game's dlc folder, where one is missing -> how many were written (the game reads them at
-- its next start)
function ST.ensure_pool(game)
  local dir = game .. "\\dlc\\" .. ST.DLC .. "\\content"
  local n = 0
  for _, lang in ipairs(ST.languages(game)) do
    local f = dir .. "\\" .. lang .. ".w3strings"
    if not w3.fs.exists(f) then
      require("conjunction.build").makedirs(dir)
      assert(w3.fs.write(f, ST.pool_bytes(lang)))
      n = n + 1
    end
  end
  return n
end

function ST.pool_loaded()
  local ok, t = pcall(function() return w3.text.get(ST.POOL_BASE) end)
  return ok and t == ST.marker(ST.POOL_BASE)
end

-- --- the texts shown while you work: marker -> the project's text
local shown, hooked = {}, false
local function replace(text)
  if type(text) ~= "string" then return nil end
  local k = text:match("^cj (%d+)$")
  if k then return shown[ST.POOL_BASE + tonumber(k)] end
  return nil
end
function ST.show(t)
  shown = {}
  for id, text in pairs(t and t.texts or {}) do shown[id] = text end
  if not hooked and w3.scene then
    hooked = true
    w3.scene.on_line(replace)
    if w3.scene.on_choice then w3.scene.on_choice(replace) end
  end
end
ST.replace = replace

-- --- the build: the scenes' pool ids moved to the project's own (base .. base + POOL_SIZE - 1) -> how many moved
function ST.remap(dir, base)
  return require("conjunction.idremap").remap_tree(dir, ST.POOL_BASE, ST.POOL_BASE + ST.POOL_SIZE - 1, base)
end

-- the project's texts under those ids into the strings of a content folder (the DLC's): each language's file read and
-- written with them, or made -> how many
function ST.add_strings(project_dir, content, base, langs)
  local mine, n = {}, 0
  for id, text in pairs(ST.load(project_dir).texts) do
    mine[base + (id - ST.POOL_BASE)] = text
    n = n + 1
  end
  if n == 0 then return 0 end
  require("conjunction.build").makedirs(content)
  for _, lang in ipairs(langs) do
    local f = content .. "\\" .. lang .. ".w3strings"
    local texts, hashes, order = {}, nil, nil
    if w3.fs.exists(f) then
      local _v, _h
      _v, _h, texts, hashes, order = WS.read(assert(w3.fs.read(f)))
    end
    for id, text in pairs(mine) do texts[id] = text end
    assert(w3.fs.write(f, WS.write_v164(lang, texts, nil, hashes, order)))
  end
  return n
end

return ST
