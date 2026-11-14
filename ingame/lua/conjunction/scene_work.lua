-- The scene workshop's logic (ui/scene_window.lua shows it): one of the game's scenes changed in place, everything
-- the game's file has kept (scene_file.lua). Each change goes at once into the running game (in memory, read at the
-- scene's next load; Play plays it at once). The project keeps it in game_files\<its path>; the build puts it into the
-- project's mod bundle.
--   local w = SW.open(path, {project_dir = , depot = })
--   w.s (the scene_file), w:edit(fn), w:undo(), w:redo(), w:revert(), w:changed()
--   w:set_line_text(el, text), w:set_voice(el, sid, secs), w:text_of(id)
--   w:play(input name | section number)    w:facts(), w:set_fact(name, n), w:restore_facts()
--   SW.here(depot) -> the scenes the game is at now      SW.clear_live() -> the game's own scenes again
local SF = require("conjunction.scene_file")
require("conjunction.scene_timeline")      -- (S:layer, S:apply_layer, S:strip_own)
local ST = require("conjunction.scene_texts")
local J = require("conjunction.json")
local SW = {}
SW.__index = SW

SW.GAME_FILES = "game_files"
SW.WORLD = "scene_world.json"            -- in the project: {"<scene path>": {"<fact>": value}}
SW.PLAY_INPUT = "cj_play_from_here"      -- the input the live copy gets for playing from a section

-- the undo and redo of each scene for the game's session: the workshop closed and the scene opened again has them
-- (when the scene is still as it was left), for the 4 scenes changed last
local kept, kept_order = {}, {}

local function makedirs(p) require("conjunction.build").makedirs(p) end
local function dirname(p) return (p:gsub("[\\/][^\\/]*$", "")) end

-- --- the scene in the running game: new contents for its file, in memory only (w3.files.set), the resource the game
-- has loaded left alone (30.10.: TW3SE's loose-file reload forgets it, and the game crashed when it freed the old
-- scene later). The game reads the new contents the next time it loads the scene; Play loads a copy under a path of
-- its own at once (SW:play). Nothing is written into the game's folder: the project keeps the scene.
local live = {}                          -- path -> true: the scenes with new contents now

-- a scene runs, or one is still loading (a play asked for then is queued by the game and runs after it, 02.11.)
local function playing()
  if w3.scene and w3.scene.playing and w3.scene.playing() then return true end
  local ok, ps = pcall(w3.all, "CStoryScenePlayer")
  return ok and ps ~= nil and #ps > 0
end
SW.playing = playing

-- the running scene's player, and where it stands (w3.scene.time): the player kept while it lives, looked for anew
-- at most four times a second (02.11.: w3.scene.time without a player searches every object of the game - ~30 ms a call;
-- a measure calling it each frame took the game from 63 to 21 frames a second)
local scene_p, scene_p_next = nil, 0
function SW.scene_player()
  if scene_p and w3.valid and w3.valid(scene_p) then return scene_p end
  scene_p = nil
  local now = os.clock()
  if now < scene_p_next then return nil end
  scene_p_next = now + 0.25
  -- (and only while the game says a scene holds the player or plays: no search at all without one)
  local okg, busy = pcall(function()
    local g = w3.global("theGame")
    return w3.player():IsInNonGameplayCutscene() or g:IsDialogOrCutscenePlaying()
  end)
  if okg and not busy then return nil end
  local ok, ps = pcall(w3.all, "CStoryScenePlayer")
  scene_p = ok and ps and ps[1] or nil
  return scene_p
end
function SW.scene_time()
  if not (w3.scene and w3.scene.time) then return nil end
  local p = SW.scene_player()
  if not p then return nil end
  local ok, t = pcall(w3.scene.time, p)
  if not ok then scene_p = nil return nil end
  return t
end

function SW.put_live(path, data)
  if not (w3.files and w3.files.set) then return true end      -- (no game: the lab)
  local ok, err = w3.files.set(path, data, false)
  if not ok then return false, tostring(err) end
  live[path] = true
  return true
end

function SW.take_live(path)
  if live[path] and w3.files and w3.files.clear then pcall(w3.files.clear, path, false) end
  live[path] = nil
  return true
end

-- every scene the workshop changed in the game back to the game's own (the window closed)
function SW.clear_live()
  local n = 0
  for path in pairs(live) do
    SW.take_live(path)
    n = n + 1
  end
  return n
end

-- --- one scene
-- opts.layer: a scene of the project's own quest (a talk the build makes anew from its lines): only what one put on
-- its timeline is kept, as its layer (scene_layers\<scene name>.json in the project, scene_timeline.lua S:layer),
-- laid over the scene as the game has it now; the build lays it over the scene it makes (conjunction/scene_layer.py)
SW.LAYERS = "scene_layers"

function SW.open(path, opts)
  opts = opts or {}
  local depot = opts.depot or require("conjunction.depot").open(require("conjunction.config").load().game)
  local self = setmetatable({path = path, project_dir = opts.project_dir, depot = depot, history = {}, future = {},
                             facts_before = {}, names = {}}, SW)
  self.base = depot:read(path)
  if not self.base then error("the game has no scene " .. path, 0) end
  if opts.layer then
    -- (its name in the project: given - a talk's node, "s12", the same whatever run of Build & Play built it - or
    -- the scene's own)
    self.layer_name = type(opts.layer) == "string" and opts.layer or path:match("([^\\/]+)%.w2scene$")
    local bare = SF.open(self.base)
    bare:strip_own()                            -- (the scene as the build made it, without a layer laid before)
    self.base = bare:bytes()
    local lf = self:layer_file()
    local ok, layer = pcall(function() return lf and w3.fs.exists(lf) and J.decode(w3.fs.read(lf)) end)
    local s = SF.open(self.base)
    if ok and layer then s:apply_layer(layer) end
    self.bytes = s:bytes()
  else
    local own = self:own_file()
    self.bytes = (own and w3.fs.exists(own) and w3.fs.read(own)) or self.base
  end
  self.s = SF.open(self.bytes)
  self.texts = ST.load(self.project_dir)
  self.world = self:_read_world()
  self.key = (self.layer_name and ("layer " .. self.layer_name) or path) .. "|" .. tostring(opts.project_dir)
  local k = kept[self.key]
  if k and k.bytes == self.bytes then self.history, self.future = k.history, k.future end
  return self
end

function SW:own_file()
  if self.layer_name then return nil end        -- (a scene of the project's own quest: its layer, not a copy)
  return self.project_dir and (self.project_dir .. "\\" .. SW.GAME_FILES .. "\\" .. self.path) or nil
end
function SW:layer_file()
  return self.layer_name and self.project_dir and
         (self.project_dir .. "\\" .. SW.LAYERS .. "\\" .. self.layer_name .. ".json") or nil
end
function SW:changed() return self.bytes ~= self.base end

function SW:_keep_undo()
  if not self.key then return end
  if not kept[self.key] then
    kept_order[#kept_order + 1] = self.key
    if #kept_order > 4 then kept[table.remove(kept_order, 1)] = nil end
  end
  kept[self.key] = {bytes = self.bytes, history = self.history, future = self.future}
end

-- the changed scene where it belongs: the project (or out of it, when it is the game's again) and the game
function SW:keep()
  self:_keep_undo()
  local lf = self:layer_file()
  if lf then
    local layer = self.s:layer()
    if next(layer.sections) or layer.cameras == "custom" then
      makedirs(dirname(lf))
      assert(w3.fs.write(lf, J.encode(layer)))
    elseif w3.fs.exists(lf) then
      w3.fs.remove(lf)
    end
  end
  local own = self:own_file()
  if own then
    if self:changed() then
      makedirs(dirname(own))
      assert(w3.fs.write(own, self.bytes))
    elseif w3.fs.exists(own) then
      w3.fs.remove(own)
    end
    ST.save(self.project_dir, self.texts)
  end
  ST.show(self.texts)
  if self:changed() then return SW.put_live(self.path, self.bytes) end
  SW.take_live(self.path)
  return true
end

-- a change: fn(scene_file) changes it; the scene is read again from its bytes (numbers as the file has them).
-- Held (SW:hold): the change stays in the scene as it is, written and read again once when the hold ends - each
-- write and read of a large scene took 1.6 s in the game's frame (0.7 + 0.9 s), a build of 25 changes ran at 6 fps
function SW:edit(fn)
  if self.held then
    local ok, err = pcall(fn, self.s, self)
    if ok then return true end
    local before = self.held.before                     -- (a change that failed half-way: back to the hold's start)
    self.held = nil
    self.s = SF.open(before)
    return false, tostring(err) .. " (the changes since the hold began are undone)"
  end
  local before = self.bytes
  local ok, err = pcall(fn, self.s, self)
  if not ok then
    self.s = SF.open(before)
    return false, tostring(err)
  end
  local after = self.s:bytes()
  self.s = SF.open(after)
  if after == before then return true end
  self.history[#self.history + 1] = before
  self.future = {}
  self.bytes = after
  return self:keep()
end

-- hold the changes (on) or write them once (off) -> ok, err
function SW:hold(on)
  if on then
    if not self.held then self.held = {before = self.bytes} end
    return true
  end
  local h = self.held
  if not h then return true end
  self.held = nil
  local after = self.s:bytes()
  self.s = SF.open(after)
  if after == h.before then return true end
  self.history[#self.history + 1] = h.before
  self.future = {}
  self.bytes = after
  return self:keep()
end

function SW:undo()
  if self.held then self:hold(false) end
  local b = table.remove(self.history)
  if not b then return false end
  self.future[#self.future + 1] = self.bytes
  self.bytes, self.s = b, SF.open(b)
  return self:keep()
end
function SW:redo()
  if self.held then self:hold(false) end
  local b = table.remove(self.future)
  if not b then return false end
  self.history[#self.history + 1] = self.bytes
  self.bytes, self.s = b, SF.open(b)
  return self:keep()
end
function SW:revert()
  if self.held then self:hold(false) end
  if not self:changed() then return true end
  self.history[#self.history + 1] = self.bytes
  self.future = {}
  self.bytes, self.s = self.base, SF.open(self.base)
  return self:keep()
end

-- --- texts
function SW:text_of(id)
  if not id then return "" end
  if ST.is_pool(id) then return self.texts.texts[id] or ST.marker(id) end
  if self.names[id] == nil then
    local ok, t = pcall(function() return w3.text.get(id) end)
    self.names[id] = ok and t or ""
  end
  return self.names[id]
end

-- the ids of the pool the scene shows (an id it still uses is not handed out again)
function SW:used_ids()
  local used = {}
  for _, o in ipairs(self.s.t.objects) do
    for _, p in ipairs(o.props or {}) do
      if p.type == "LocalizedString" and type(p.value) == "table" and ST.is_pool(p.value.n) then used[p.value.n] = true end
    end
  end
  return used
end

-- a text of one's own for a line, a comment or an answer: its pool id (one it has already, else a free one) -> id
function SW:own_text_id(current, text)
  local id = current
  if not ST.is_pool(id) then id = ST.new_id(self.texts, self:used_ids()) end
  self.texts.texts[id] = text
  return id
end

-- a line says text of one's own: it has no voice then, and lasts as long as the text
function SW:set_line_text(el, text)
  return self:edit(function(s)
    local e = s:obj(el)
    local cur = e:get("dialogLine")
    local id = self:own_text_id(cur and cur.n, text)
    s:set_text(el, id)
    s:set_duration(el, ST.length_of(text))
  end)
end

-- a line takes one of the game's lines: its words and its voice (sid), its length
function SW:set_voice(el, sid, secs)
  return self:edit(function(s)
    s:set_text(el, sid)
    if secs and secs > 0 then s:set_duration(el, secs) end
  end)
end

function SW:set_choice_text(cl, text)
  return self:edit(function(s)
    local c = s:obj(cl)
    local cur = c:get("choiceLine")
    s:set_choice_text(cl, self:own_text_id(cur and cur.n, text))
  end)
end

-- a new line after element `after` (nil: first): the speaker, a text of one's own, the director's events of `regie`
function SW:add_line(sec, after, speaker, text, regie)
  local n
  local ok, err = self:edit(function(s)
    local id = self:own_text_id(nil, text)
    n = s:insert_line(sec, after, speaker, id, ST.length_of(text), regie)
  end)
  return ok and n or nil, err
end

-- --- playing it: from an input, or from a section (an input of its own there). The scene as it is now plays under a
-- path of its own, made for this play (w3.files.alias of the game's file, its contents set): a path the game never
-- loaded, so nothing it holds is replaced. A scene playing is stopped first. o: {at = second of the section, paused}
-- (TW3SE's scene preview: the scene stands at that second)
-- lines of one's own words in the preview: the game gives a line without a voice 1.5 to 1.8 s whatever its text
-- (01.11.), the build gives each a silent voice as long as the timeline says (build.py). So the copy that plays has a
-- pause in each one's place, as long as the line, and the subtitle is put up by SW.sub_tick: the preview runs as the
-- built quest will. -> {section name = {{t0, t1, text}}}
function SW:own_lines_as_pauses(copy)
  local TR = require("conjunction.cr2w_tree")
  local subs = {}
  for _, sn in ipairs(copy:root():get("sections") or {}) do
    local so = copy:obj(sn)
    local ok, tl = false, nil
    if so and so.cls == "CStorySceneSection" then ok, tl = pcall(copy.timeline, copy, sn) end
    for _, e in ipairs(ok and tl.elements or {}) do
      local o = copy:obj(e.n)
      local dl = o and o.cls == "CStorySceneLine" and o:get("dialogLine")
      local id = dl and dl.n
      if id and ST.is_pool(id) then
        local list = subs[copy:name_of(sn)] or {}
        subs[copy:name_of(sn)] = list
        list[#list + 1] = {t0 = e.start, t1 = e.start + e.len, text = (self.texts and self.texts.texts or {})[id] or ""}
        local eid, secs = o:get("elementID", ""), o:get("approvedDuration", e.len)
        o.cls = "CStoryScenePauseElement"
        o.props = {TR.Prop("elementID", "String", eid), TR.Prop("approvedDuration", "Float", secs),
                   TR.Prop("duration", "Float", secs)}
      end
    end
  end
  return next(subs) and subs or nil
end

-- the subtitle of a line of one's own while the preview is in it (each frame; the scene's time ten times a second)
SW.subs, SW.sub_shown, SW.sub_next = nil, nil, 0
function SW.sub_tick()
  if not SW.subs and not SW.sub_shown then return end
  local now = w3.time and w3.time() or 0
  if now < SW.sub_next then return end
  SW.sub_next = now + 0.1
  local want
  local t = SW.subs and SW.scene_time()
  for _, s in ipairs(t and SW.subs[t.section] or {}) do
    if t.t >= s.t0 and t.t < s.t1 then want = s.text break end
  end
  if want == SW.sub_shown then return end
  local ok, m = pcall(w3.hud.module, "DialogModule")
  if ok and m then
    if want then pcall(function() m:OnDialogSentenceSet(want) end) else pcall(function() m:OnDialogSentenceHide() end) end
  end
  SW.sub_shown = want
end

SW.plays = 0
SW.run = string.format("%x", os.time() % 0x100000)   -- (the paths of one load of this file: a reloaded mod plays
function SW:play(target, o)                          -- under new ones, the game holds the old ones' contents)
  if not (w3.scene and w3.scene.play) then return false, "no scene system (the lab)" end
  -- (editing: Geralt off the free camera and the built people seen, as the game has them - scene_stage.lua)
  if SW.on_play then pcall(SW.on_play) end
  if not (w3.files and w3.files.alias and w3.files.set) then return false, "TW3SE has no w3.files.alias" end
  if self.held then self:hold(false) end             -- (a play plays what is written)
  ST.show(self.texts)
  local copy = SF.open(self.bytes)
  local subs = self:own_lines_as_pauses(copy)          -- (put up when it starts: a scene playing is stopped first)
  local input = target
  if type(target) == "number" then
    -- (a section's preview ends with it: the flow after it can lead round into it again - a gameplay section of the
    -- game's waits for a fact that way - and a section leading nowhere plays again and again; both went on and on,
    -- 02.11. A section that ends in a choice keeps its way on.)
    local so, outs = copy:obj(target), copy:outputs()
    local choice = so and (so:get("choice", 0) or 0) > 0 or false   -- (the game's talks keep their choice there)
    for _, e in ipairs(so and so:get("sceneElements") or {}) do
      if copy:obj(e) and copy:obj(e).cls == "CStorySceneChoice" then choice = true end
    end
    if so and outs[1] and not choice then so:set("nextLinkElement", outs[1].n, "ptr:CStorySceneLinkElement") end
    -- (and no end of the preview leaves the screen black: a quest fades in after such an output, a preview has none -
    -- the screen stayed black and the game paused after each play, 02.11.)
    for _, out in ipairs(outs) do
      local oo = copy:obj(out.n)
      if oo and oo:get("endsWithBlackscreen") then oo:set("endsWithBlackscreen", false, "Bool") end
    end
    local n = copy:add_input(target, SW.PLAY_INPUT)
    local set = copy:obj(target) and copy:obj(target):get("dialogsetChangeTo")
    if set and set ~= "" then copy:obj(n):set("dialogsetInstanceName", set, "CName") end   -- (where that section is)
    input = SW.PLAY_INPUT
  end
  SW.plays = SW.plays + 1
  local mine = SW.plays                    -- (a play asked for later wins: this one does not start after it)
  local alias = self.path:gsub("%.w2scene$", "") .. "_cj" .. SW.run .. "_" .. SW.plays .. ".w2scene"
  local ok, err = w3.files.alias(self.path, alias)
  if not ok then return false, "a copy to play: " .. tostring(err) end
  ok, err = w3.files.set(alias, copy:bytes(), false)
  if not ok then return false, tostring(err) end
  local function start()
    if mine ~= SW.plays then return false, "a later play was asked for" end
    SW.subs = subs
    local ok2, err2
    -- (from second 0, playing: the game's own play, no seek - 02.11.: a scene started through a seek moved the
    -- walking person by the cycle's way and left the way in the pose as well, he slid ahead and jumped back each
    -- cycle; in Lua 0 counts as given, so each play from the start went through the seek)
    if o and ((o.at and o.at > 0.001) or o.paused) and w3.scene.seek then
      ok2, err2 = pcall(w3.scene.play, alias, input or SF.DEFAULT_INPUT, {at = o.at or 0.0, paused = o.paused == true})
    else
      ok2, err2 = pcall(w3.scene.play, alias, input or SF.DEFAULT_INPUT)
    end
    if not ok2 then print("[scene workshop] play: " .. tostring(err2)) end
    if o then o.started = w3.time and w3.time() or 0 end
    if ok2 then SW.after_play = {at = os.clock(), seen = false} end
    return ok2, ok2 and nil or tostring(err2)
  end
  if not playing() or not w3.after then return start() end
  SW.stop()                                -- (a scene playing: it ends first, then this one starts)
  local tries = 0
  local function wait()
    tries = tries + 1
    if playing() and tries < 40 then w3.after(0.25, wait) else w3.after(0.3, start) end
  end
  w3.after(0.25, wait)
  return true
end

-- after a preview: once its scene is over, the game as it was - the screen not black, no loading screen left (a scene
-- that ended black or was stopped while it loaded left both, and the game paused, 02.11.). Called each frame by the
-- engine; it asks the game twice a second while a preview plays and does nothing at all otherwise.
SW.after_play = nil
function SW.after_play_tick()
  local ap = SW.after_play
  if not ap then return end
  local now = os.clock()
  if ap.next and now < ap.next then return end
  ap.next = now + 0.5
  local ok, busy = pcall(function()
    return w3.player():IsInNonGameplayCutscene() or w3.global("theGame"):IsDialogOrCutscenePlaying()
  end)
  if not ok then SW.after_play = nil return end
  if busy then ap.seen, ap.quiet = true, nil return end
  if not ap.seen and now - ap.at < 30 then return end          -- (not started yet: it may still load)
  ap.quiet = ap.quiet or now
  if now - ap.quiet < 1.0 then return end                     -- (over for a second: no section change in between)
  SW.after_play = nil
  SW.unblack()
  if SW.on_over then pcall(SW.on_over) end      -- (the world as the editor had it: scene_stage.lua)
end

-- the screen back from black and no loading screen left (the game's own console commands for it) -> whether it was black
function SW.unblack()
  local g = w3.global and w3.global("theGame")
  local okb, black = pcall(function() return g:IsBlackscreen() end)
  if not (okb and black) then return false end
  if w3.exec then pcall(w3.exec, "loadingmenuclose") pcall(w3.exec, "fadein") end
  pcall(function() g:FadeInAsync(0.0) end)
  return true
end

-- no play asked for so far starts any more (a changed scene's preview still waiting for the old one to end started
-- after a stop, 02.11.: the player could not be moved, every play began where the last had left him)
function SW.cancel() SW.plays = SW.plays + 1 end

-- every scene playing ends (TW3SE's stop of every scene; an older TW3SE: the player's gameplay scenes)
function SW.stop()
  SW.subs = nil
  if not (w3.scene and w3.scene.stop) then return end
  if w3.scene.pause then pcall(w3.scene.stop) else pcall(w3.scene.stop, w3.player()) end
end

-- --- a cutscene replaced by a scene Motion built (a scene pack's stages): the other scene's flow comes in
-- the cutscene section's place, at the cutscene's spot, with this scene's people (scene_file.lua replace_section)
SW.VANILLA_DLC = {bob = true, ep1 = true}
for k = 1, 20 do SW.VANILLA_DLC["dlc" .. k] = true end

-- the built scenes the game has (DLCs of mods: dlc\<dlc>\data\scenes\*.w2scene) -> {{path, name, dlc}}
function SW.built_scenes(depot)
  local out = {}
  for _, p in ipairs(depot:glob("dlc\\", ".w2scene")) do
    local dlc, name = p:match("^dlc\\([^\\]+)\\data\\scenes\\([^\\]+)%.w2scene$")
    if dlc and not SW.VANILLA_DLC[dlc] then out[#out + 1] = {path = p, name = name, dlc = dlc} end
  end
  table.sort(out, function(a, b) return a.path < b.path end)
  return out
end

-- a cutscene's spot (the tag of its point in the world) and its people (voicetags) -> tag, {voicetag ...}
local spots = {}
function SW.cutscene_spot(depot, path)
  if not path or path == "" then return "", {} end
  if spots[path] == nil then
    local CR, TR = require("conjunction.cr2w"), require("conjunction.cr2w_tree")
    local data = depot:read(path)
    local tag, people = "", {}
    if data then
      local f = CR.parse(data)
      local b = f.exports[1][5]
      local props = TR.Codec(f):read_props(b, 1, #b)
      tag = (TR.sget(props, "point") or {})[1] or ""
      for _, a in ipairs(TR.sget(props, "actorsDef") or {}) do
        local v = TR.sget(a, "voiceTag", "")
        if TR.sget(a, "type", "CAT_Actor") == "CAT_Actor" and v ~= "" then people[#people + 1] = v end
      end
    end
    spots[path] = {tag, people}
  end
  return spots[path][1], spots[path][2]
end

-- who is who: the other scene's actors -> this scene's (the player for the player, the others in the order the
-- cutscene names its people) -> {other voicetag or tag = this scene's}, {{from, to}} to show
function SW:roles_for(sec, B)
  local mine = {}
  for _, a in ipairs(self.s:actors()) do mine[a.id] = a end
  local _, people = SW.cutscene_spot(self.depot, self.s:cutscene_of(sec) or "")
  local others = {}
  for _, v in ipairs(people) do if v ~= "GERALT" and mine[v] then others[#others + 1] = v end end
  if #others == 0 then                           -- (the brothels' cutscenes name nobody's voice: the scene's others)
    for _, a in ipairs(self.s:actors()) do if a.id ~= "GERALT" then others[#others + 1] = a.id end end
  end
  local names, shown, k = {}, {}, 0
  for _, a in ipairs(B:actors()) do
    local player = a.id == "GERALT" or (a.tags and a.tags[1] == "PLAYER")
    local to
    if player then to = "GERALT" else
      k = k + 1
      to = others[k]
    end
    if to then
      names[a.id] = to
      local t = mine[to] and mine[to].tags and mine[to].tags[1]
      if a.tags and a.tags[1] and a.tags[1] ~= "PLAYER" then names[a.tags[1]] = player and "PLAYER" or (t or to) end
    end
    shown[#shown + 1] = {from = a.id, to = to}
  end
  return names, shown
end

-- section sec (a cutscene) replaced by the built scene at path, at the cutscene's spot -> the dialogset's name
function SW:replace_cutscene(sec, path, opts)
  opts = opts or {}
  local data = self.depot:read(path)
  if not data then return nil, "the game has no scene " .. path end
  local B = SF.open(data)
  local names = opts.names or self:roles_for(sec, B)
  local tag = opts.tag or SW.cutscene_spot(self.depot, self.s:cutscene_of(sec) or "")
  if not tag or tag == "" then tag = "PLAYER" end
  local set
  local ok, err = self:edit(function(s) set = s:replace_section(sec, B, {names = names, tag = tag}).set end)
  if not ok then return nil, err end
  return set
end

function SW:set_place(set, pos, yaw) return self:edit(function(s) s:set_place(set, pos, yaw) end) end
function SW:set_place_tag(set, tag) return self:edit(function(s) s:set_place_tag(set, tag) end) end
function SW:set_camera(set, view)
  return self:edit(function(s)
    for _, o in ipairs(s:own_sets()) do if o.set == set then s:set_camera(set, view, o.pos, o.yaw) end end
  end)
end

-- --- a cutscene of one's own (scene_file.lua: moments): a section at a dialogset of its own, its moments one after
-- the other, each with an animation per person, everyone's place and a camera
SW.OWN_CUTSCENE = "cj_cutscene_"
SW.LOOK_HEIGHT = 1.3                     -- where the camera looks: this high over the people's middle

function SW.is_own_cutscene(s, sec)
  local o = s:obj(sec)
  return o and tostring(o:get("sectionName", "")):sub(1, #SW.OWN_CUTSCENE) == SW.OWN_CUTSCENE
end

-- the people of a new cutscene: the player and the others a cutscene there names (or the scene's first other one)
function SW:people_for(sec)
  local mine = {}
  for _, a in ipairs(self.s:actors()) do mine[#mine + 1] = a.id end
  local out = {"GERALT"}
  local _, people = SW.cutscene_spot(self.depot, self.s:cutscene_of(sec or 0) or "")
  for _, v in ipairs(people) do
    for _, m in ipairs(mine) do if m == v and v ~= "GERALT" then out[#out + 1] = v end end
  end
  if #out == 1 then
    for _, m in ipairs(mine) do if m ~= "GERALT" then out[#out + 1] = m break end end
  end
  return out
end

local function middle(places)
  local x, y, n = 0, 0, 0
  for _, p in pairs(places) do x, y, n = x + p[1], y + p[2], n + 1 end
  if n == 0 then return {0, 0, SW.LOOK_HEIGHT} end
  return {x / n, y / n, SW.LOOK_HEIGHT}
end
SW.middle = middle

-- a cutscene of one's own after part `after`, or (replace = true) in the place of section `after` -> its section.
-- It plays at the cutscene's spot (replacing one) or at the player; the player stands at the spot, the others
-- facing the player 1.2 m away; a first moment of 4 seconds, the camera from the side
function SW:add_cutscene(after, replace, opts)
  opts = opts or {}
  local people = opts.people or self:people_for(replace and after or nil)
  local tag = opts.tag or (replace and SW.cutscene_spot(self.depot, self.s:cutscene_of(after) or "")) or "PLAYER"
  if tag == "" then tag = "PLAYER" end
  local sec
  local ok, err = self:edit(function(s)
    local set = s:add_set(tag, people)
    local k = 1
    for _, o in ipairs(s.t.objects) do
      if SF.SECTIONS[o.cls] and tostring(o:get("sectionName", "")):sub(1, #SW.OWN_CUTSCENE) == SW.OWN_CUTSCENE then
        k = k + 1
      end
    end
    -- (opts.before: what led to section `after` leads to the new one, which goes on to it; opts.free: in no flow,
    -- reached by an answer only)
    local n = s:add_section((opts.before or opts.free) and 0 or after, SW.OWN_CUTSCENE .. k, set)
    local no = s:obj(n)
    if opts.before then
      s:redirect(after, n, n)
      no:set("nextLinkElement", after, "ptr:CStorySceneLinkElement")
    end
    if replace then s:_take_place(after, n) end
    n = s:num(no)
    local eo = s:obj(s:add_moment(n, nil, 4.0))
    local places = {}
    for i, who in ipairs(people) do places[who] = i == 1 and {0, 0, 0} or {0, 1.2 * (i - 1), 180} end
    s:set_moment_places(no, eo, places)
    s:set_moment_camera(no, eo, "side", "medium", middle(places))
    sec = no:get("sectionName")
  end)
  if not ok then return nil, err end
  return self:section_named(sec)
end

-- (a section found again after the scene was read anew: by its name)
function SW:section_named(name)
  for n, o in ipairs(self.s.t.objects) do
    if SF.SECTIONS[o.cls] and o:get("sectionName") == name then return n end
  end
  return nil
end

-- a moment after element `after` (nil: at the end): the one before it as it was (animations, places, camera)
function SW:add_moment(sec, after)
  local name = self.s:obj(sec):get("sectionName")
  local new_id
  local ok, err = self:edit(function(s)
    local els = s:elements(sec)
    after = after or (els[#els] and els[#els].n)
    local prev = after and s:moment(sec, after)
    local so = s:obj(sec)
    local eo = s:obj(s:add_moment(sec, after, prev and prev.secs or 4.0))
    if prev then
      s:set_moment_places(so, eo, prev.places)
      for actor, a in pairs(prev.anims) do s:set_moment_anim(so, eo, actor, a.name, a.len) end
      if prev.camera then
        s:set_moment_camera(so, eo, prev.camera.view, prev.camera.size, middle(prev.places), prev.places)
      end
    end
    new_id = eo:get("elementID")
  end)
  if not ok then return nil, err end
  local n = self:section_named(name)
  for _, e in ipairs(self.s:elements(n)) do if e.id == new_id then return e.n, n end end
  return nil
end

-- a change to one moment: fn(scene_file, moment) with the moment as it is now
function SW:change_moment(sec, el, fn)
  return self:edit(function(s)
    local so, eo = s:obj(sec), s:obj(el)                -- (objects: numbers move when events go)
    fn(s, s:moment(sec, el), so, eo)
  end)
end

function SW:set_moment_anim(sec, el, actor, anim, len)
  return self:change_moment(sec, el, function(s, _, so, eo) s:set_moment_anim(so, eo, actor, anim, len) end)
end
function SW:set_moment_place(sec, el, actor, place)
  local all = self:moment_places(sec, el)
  all[actor] = place
  return self:change_moment(sec, el, function(s, m, so, eo)
    m.places[actor] = place
    s:set_moment_places(so, eo, {[actor] = place})
    if m.camera and m.camera.view ~= SF.OWN_VIEW then        -- (a view taken stays where it was taken)
      s:set_moment_camera(so, eo, m.camera.view, m.camera.size, middle(m.places), all)
    end
  end)
end

-- a point of the world (and a turn) in the frame of section sec's spot -> {x, y, z}, turn; nil, why
function SW:to_spot(sec, p, yaw)
  local set = self.s:set_of(sec)
  local ds = set and self.s:obj(self.s:_dialogset(set) or 0)
  local tag = ds and (ds:get("placementTag") or {})[1] or "PLAYER"
  local base, syaw = SW.spot_world(tag)
  if not base then return nil, "The spot " .. tostring(tag) .. " is not in the world here" end
  local a = math.rad(-syaw)
  local dx, dy = p[1] - base[1], p[2] - base[2]
  return {dx * math.cos(a) - dy * math.sin(a), dx * math.sin(a) + dy * math.cos(a), p[3] - base[3]},
         yaw and (yaw - syaw) or nil
end

-- the camera as the game shows it now (Conjunction's free camera, flown where it should be) is the camera of the
-- moment at element el
function SW:take_view(sec, el)
  if not (w3.camera and w3.camera.pos and w3.camera.rot) then return false, "No camera to take here" end
  local cp, cr = w3.camera.pos(), w3.camera.rot()
  local pos, yaw = self:to_spot(sec, {cp.X, cp.Y, cp.Z}, cr.Yaw or 0)
  if not pos then return false, yaw end
  local fov = w3.camera.fov and tonumber(w3.camera.fov()) or nil
  return self:change_moment(sec, el, function(s, _, so, eo)
    self:_custom_first(s)
    s:set_moment_view(so, eo, pos, cr.Pitch or 0, yaw, fov)
  end)
end

-- person `actor` stands at point p of the world in the moment at element el (their turn stays)
function SW:put_at(sec, el, actor, p)
  local pos, err = self:to_spot(sec, p)
  if not pos then return false, err end
  local pl = self.s:moment(sec, el).places[actor]
  local turn = pl and pl[3]
  if turn == nil then                           -- (no place of their own there: the turn they have then)
    local start = 0
    for _, e in ipairs(self.s:_laid(sec)) do if e.n == el then start = e.start end end
    turn = self:place_at(sec, actor, start)[4]
  end
  return self:set_moment_place(sec, el, actor, {pos[1], pos[2], turn or 0, pos[3]})
end
-- a walk of actor from p0 to p1 ({x, y[, z]} in the scene's space) from second `at`: o.seconds (else as long as the
-- walk cycle's own speed takes, measured on the figure), o.anim (default locomotion_walk_cycle_slow_forward),
-- o.carried, o.from_here -> {id, seconds, speed, rate, turn, from, to, carried} or nil, the reason
function SW:walk(sec, actor, at, p0, p1, o)
  o = o or {}
  local anim = o.anim or "locomotion_walk_cycle_slow_forward"
  p0, p1 = {p0[1], p0[2], p0[3] or 0}, {p1[1], p1[2], p1[3] or 0}
  local dx, dy = p1[1] - p0[1], p1[2] - p0[2]
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist < 0.2 then return nil, "from and to are the same place" end
  local turn = math.deg(math.atan(-dx, dy)) % 360          -- (yaw 0 looks along +y)
  p0[4], p1[4] = turn, turn
  local e = self:figure_of(actor)
  local WSm = require("conjunction.world_sense")
  local len = SW.animation_length(self.depot, anim)
  local gait, why
  if e then gait, why = WSm.anim_gait(e, anim, len) end
  if not gait and not o.seconds then
    return nil, why == "" and "The walk is still loading. Try again in a moment" or
                ("No speed for " .. anim .. ": " .. tostring(why or (actor .. " is not in the world here")))
  end
  len = (gait and gait.length) or len or 1.0               -- (the figure's own length: the depot's list mixes sets)
  local secs = o.seconds or dist / gait.speed
  local longer
  if o.fit then
    -- (what is left of the section: longer where it ends in a pause, else the walk quicker - at most 1.6 times)
    local _, length = self.s:_laid(sec)
    local left = length - at - 0.05
    if secs > left then
      local laid = self.s:_laid(sec)
      local last = laid[#laid]
      if last and self.s:obj(last.n).cls == "CStoryScenePauseElement" then
        longer = at + secs + 0.3
      elseif left > 0.2 and secs / left <= 1.6 then
        secs = left
      else
        return nil, string.format("The walk takes %.1f s, the section ends %.1f s after the playhead. Start it " ..
                                  "earlier or pick a nearer point", secs, math.max(0, left))
      end
    end
  end
  local rate = gait and gait.speed > 0.05 and (dist / secs) / gait.speed or 1.0   -- (the feet go with the ground)
  local carried = gait and gait.carried or false
  if o.carried ~= nil then carried = o.carried and true or false end   -- (told: a cycle measured on the spot that
                                                                        -- still moves by itself, as an NPC's)
  local id
  local ok, err = self:edit(function(s)
    if longer then s:set_length(sec, longer) end
    id = s:add_walk(sec, actor, at, at + secs, p0, p1, anim, len, rate, carried, o.from_here)
  end)
  if not ok then return nil, err end
  return {id = id, seconds = secs, speed = gait and gait.speed, rate = rate, turn = turn, from = p0, to = p1,
          carried = carried}
end

-- where actor stands at second t of the section, in the scene's space: the placements up to then, else their slot
-- -> {x, y, z, turn}
function SW:place_at(sec, actor, t)
  local pl = self.s:placements_at(sec, t)[actor]
  if pl then return {pl.x, pl.y, pl.z or 0, pl.turn or 0} end
  local set = self.s:set_of(sec)
  local ds = set and self.s:obj(self.s:_dialogset(set) or 0)
  for _, n in ipairs(ds and ds:get("slots") or {}) do
    local so = self.s:obj(n)
    local tf = so and so:get("slotPlacement")
    if so and tf and tostring(so:get("actorName")) == actor then
      local p, r = tf.position or {}, tf.rotation or {}
      return {p[1] or 0, p[2] or 0, p[3] or 0, r[3] or 0}
    end
  end
  return {0, 0, 0, 0}
end

-- a thing of the world switched at second t of section sec (scene_timeline S:add_world_action) -> clip id
function SW:add_world_action(sec, t, o)
  local id
  local ok, err = self:edit(function(s) id = s:add_world_action(sec, t, o) end)
  if not ok then return nil, err end
  return id
end

-- the cameras of the scene: "auto" or "custom" (scene_timeline S:camera_mode)
function SW:camera_mode()
  if not (self._cm and self._cm[1] == self.bytes) then self._cm = {self.bytes, self.s:camera_mode()} end
  return self._cm[2]
end
function SW:set_camera_mode(mode, empty)
  if mode == "auto" and self.layer_name then
    -- (the build's cuts back at once: the scene as the build made it, the layer over it without its cameras)
    if self.held then self:hold(false) end
    local TL = require("conjunction.scene_timeline")
    local layer = self.s:layer()
    for name, list in pairs(layer.sections) do
      local keep = {}
      for _, rec in ipairs(list) do if not TL.CAM_CUTS[rec.cls] then keep[#keep + 1] = rec end end
      layer.sections[name] = keep
    end
    layer.cameras = "auto"
    local fresh = SF.open(self.base)
    fresh:apply_layer(layer)
    local after = fresh:bytes()
    if after == self.bytes then return true end
    self.history[#self.history + 1] = self.bytes
    self.future = {}
    self.bytes, self.s = after, SF.open(after)
    return self:keep()
  end
  return self:edit(function(s) s:set_camera_mode(mode, empty) end)
end
-- (a talk's or scene's camera changed while it is Automatic: Custom first, every cut kept - the next line's cut of the
-- build took the picture back)
function SW:_custom_first(s)
  if self.layer_name and s:camera_mode() == "auto" then s:set_camera_mode("custom") end
end

function SW:set_moment_camera(sec, el, view, size)
  local all = self:moment_places(sec, el)
  return self:change_moment(sec, el, function(s, m, so, eo)
    self:_custom_first(s)
    s:set_moment_camera(so, eo, view, size, middle(m.places), all)
  end)
end

-- where everyone of section sec stands at moment el: the moment's own places, else where the person is then (SW:place_at:
-- a walk, a place before, their slot) -> {name = {x, y, turn}} (kept while the scene and the moment stay the same:
-- the camera list asks each frame)
function SW:moment_places(sec, el)
  local key = tostring(sec) .. ":" .. tostring(el)
  local c = self._mp
  if c and c.key == key and c.bytes == self.bytes then return c.out end
  local out = {}
  for who, p in pairs(self.s:moment(sec, el).places) do out[who] = p end
  local set = self.s:set_of(sec)
  local ds = set and self.s:obj(self.s:_dialogset(set) or 0)
  local t
  for _, n in ipairs(ds and ds:get("slots") or {}) do
    local so = self.s:obj(n)
    local who = so and tostring(so:get("actorName") or "")
    if who and who ~= "" and not out[who] then
      if not t then
        t = 0
        for _, e in ipairs((self.s:_laid(sec))) do if e.n == el then t = e.start end end
      end
      local p = self:place_at(sec, who, t)
      out[who] = {p[1], p[2], p[4]}
    end
  end
  self._mp = {key = key, bytes = self.bytes, out = out}
  return out
end
function SW:set_moment_secs(sec, el, secs)
  return self:change_moment(sec, el, function(s, _, so, eo) s:set_moment_secs(so, eo, secs) end)
end

-- the animations a person can play in a scene: the game's (radish's list of the scene animations, with their
-- length) and those of the scene packs the game has (their DLC's list, the length as their built scenes play it)
-- -> {{name, len, from}}
local anim_list
function SW.animations(depot)
  if anim_list then return anim_list end
  -- (kept only when read whole: stopped in the middle - TW3SE's 5 s for a call - a list stayed cut short)
  local list = {}
  local seen = {}
  local lens = {}
  for _, b in ipairs(SW.built_scenes(depot)) do
    local ok, s = pcall(function() return SF.open(depot:read(b.path)) end)
    for _, o in ipairs(ok and s.t.objects or {}) do
      for _, ev in ipairs(o.events or {}) do
        if ev.cls == "CStorySceneEventAnimation" then
          local TR = require("conjunction.cr2w_tree")
          local nm = TR.sget(ev.props, "animationName")
          if nm then lens[nm] = math.max(lens[nm] or 0, TR.sget(ev.props, "duration", 0)) end
        end
      end
    end
  end
  for _, p in ipairs(depot:glob("dlc\\", "scene_body_animations.csv")) do
    local dlc = p:match("^dlc\\([^\\]+)\\")
    if dlc and not SW.VANILLA_DLC[dlc] then
      local text = depot:read(p) or ""
      for line in text:gmatch("[^\r\n]+") do
        local name = select(5, line:match("^([^;]*);([^;]*);([^;]*);([^;]*);([^;]*)"))
        if name and name ~= "" and name ~= "Animation name" and not seen[name] then
          seen[name] = true
          list[#list + 1] = {name, lens[name] or 5.0, dlc}
        end
      end
    end
  end
  local ok, all = pcall(function() return require("conjunction.dialogue").all_animations() end)
  for _, a in ipairs(ok and all or {}) do
    if not seen[a[1]] then
      seen[a[1]] = true
      list[#list + 1] = {a[1], a[2], "game"}
    end
  end
  -- (the game's list kept by dialogue.lua only when read whole: then the same table comes again)
  if ok and #all > 0 and require("conjunction.dialogue").all_animations() == all then anim_list = list end
  return list
end

-- a pair's other half: a scene pack's stage animations come as <name>_a / <name>_b, one per person. For animation
-- `name` given to `actor`, the other person of `people` (when there is exactly one) and the other half -> other, its
-- animation; nil when it has no other half
function SW.partner_of(depot, name, people, actor)
  local base, half = tostring(name):match("^(.*)_([ab])$")
  if not base then return nil end
  local partner = base .. "_" .. (half == "a" and "b" or "a")
  if not SW.animation_length(depot, partner) then return nil end
  local others = {}
  for _, p in ipairs(people or {}) do if p ~= actor then others[#others + 1] = p end end
  if #others ~= 1 then return nil end
  return others[1], partner
end

-- the length of animation `name` in seconds, nil: not known
local anim_len
function SW.animation_length(depot, name)
  if not anim_len then
    local lens = {}
    for _, a in ipairs(SW.animations(depot)) do lens[a[1]] = a[2] end
    if anim_list then anim_len = lens else return lens[name] end   -- (a list cut short: not kept)
  end
  return anim_len[name]
end

-- the animations with every word of `words` -> up to limit of them
function SW.find_animations(depot, words, limit)
  local ws = {}
  for w in tostring(words or ""):lower():gsub("_", " "):gmatch("%S+") do ws[#ws + 1] = w end
  local out = {}
  for _, a in ipairs(SW.animations(depot)) do
    local hay = (a[1] .. " " .. a[3]):lower():gsub("_", " ")
    local all = true
    for _, w in ipairs(ws) do if not hay:find(w, 1, true) then all = false break end end
    if all then
      out[#out + 1] = a
      if #out >= (limit or 60) then break end
    end
  end
  return out
end

-- where a spot is in the world: its position and turn (the entity with the tag; "PLAYER": the player) -> pos, yaw
-- SW.player_spot(): while editing, where the player will stand when the scene plays (scene_window sets it:
-- scene_stage.front_of) -> {x, y, z}, yaw, or nil (the player as he is)
SW.player_spot = nil
function SW.spot_world(tag)
  if tag == "PLAYER" and SW.player_spot then
    local ok, p, yaw = pcall(SW.player_spot)
    if ok and p then return p, yaw end
  end
  local e
  if tag == "PLAYER" then e = w3.player and w3.player() else
    local ok, x = pcall(function() return w3.global("theGame"):GetEntityByTag(tag) end)
    e = ok and x or nil
  end
  if not e then return nil end
  local p, r = e:GetWorldPosition(), e:GetWorldRotation()
  return {p.X, p.Y, p.Z}, r.Yaw or 0
end

-- where a point of the world is in the picture: u, v from 0 (left, top) to 1 - also outside the picture (below 0,
-- above 1), nil behind the camera. (w3.camera.to_screen gives nil outside the picture: in a scene's close shot the
-- feet are often below it, 01.11.)
function SW.ratio(pos)
  local okg, cam = pcall(w3.global, "theCamera")
  if okg and cam then
    local ok, good, x, y = pcall(function() return cam:WorldVectorToViewRatio(pos, 0, 0) end)
    if ok and good then return (x + 1) / 2, (y + 1) / 2 end
    return nil
  end
  return w3.camera.to_screen(pos)
end

-- u, v of the picture -> screen pixels (the picture where view_rect puts it, else the whole client area)
local function picture()
  local rx, ry, rw, rh
  if w3.view and w3.view.rect then rx, ry, rw, rh = w3.view.rect() end
  if not rx and w3.input and w3.input.client then
    local _, _, cw, ch = w3.input.client()
    rx, ry, rw, rh = 0, 0, cw, ch
  end
  return rx, ry, rw, rh
end

-- the point of the world under pixel x, y of the screen (the picture as drawn, view_rect or full): a ray from the
-- camera through the pixel, the first hit of the static world, else where it meets the height `ground_z` -> {x, y, z}
-- or nil, why. The ray's direction is found by asking the game where a point lands (w3.camera.to_screen) and
-- correcting it (Newton, numeric): the game's field of view and axes need not be known.
function SW.point_at(x, y, ground_z)
  if not (w3.camera and w3.camera.pos and w3.camera.forward and w3.camera.to_screen) then
    return nil, "No camera here"
  end
  local rx, ry, rw, rh = picture()
  if not rw then return nil, "No game picture here" end
  local tu, tv = (x - rx) / rw, (y - ry) / rh
  if tu < -1 or tu > 2 or tv < -1 or tv > 2 then return nil, "The point is far outside the picture" end
  local cp, f = w3.camera.pos(), w3.camera.forward()
  local c = {cp.X, cp.Y, cp.Z}
  local fw = {f.X, f.Y, f.Z}
  local rl = math.sqrt(fw[1] * fw[1] + fw[2] * fw[2])
  local rt = rl > 1e-6 and {fw[2] / rl, -fw[1] / rl, 0} or {1, 0, 0}
  local up = {rt[2] * fw[3] - rt[3] * fw[2], rt[3] * fw[1] - rt[1] * fw[3], rt[1] * fw[2] - rt[2] * fw[1]}
  local function screen(a, b)
    local d = {fw[1] + rt[1] * a + up[1] * b, fw[2] + rt[2] * a + up[2] * b, fw[3] + rt[3] * a + up[3] * b}
    local u, v = SW.ratio({X = c[1] + d[1] * 10, Y = c[2] + d[2] * 10, Z = c[3] + d[3] * 10, W = 1})
    return u, v, d
  end
  local a, b = 0.0, 0.0
  local d
  for _ = 1, 8 do
    local u, v
    u, v, d = screen(a, b)
    if not u then return nil, "The camera cannot see that point" end
    local eu, ev = tu - u, tv - v
    if math.abs(eu) < 1e-4 and math.abs(ev) < 1e-4 then break end
    local h = 1e-3
    local ua, va = screen(a + h, b)
    local ub, vb = screen(a, b + h)
    if not (ua and ub) then return nil, "The camera cannot see that point" end
    local j11, j21, j12, j22 = (ua - u) / h, (va - v) / h, (ub - u) / h, (vb - v) / h
    local det = j11 * j22 - j12 * j21
    if math.abs(det) < 1e-9 then break end
    a = a + (j22 * eu - j12 * ev) / det
    b = b + (-j21 * eu + j11 * ev) / det
  end
  local far = {c[1] + d[1] * 150, c[2] + d[2] * 150, c[3] + d[3] * 150}
  if w3.world and w3.world.trace then
    local ok, hit, pos = pcall(w3.world.trace, {X = c[1], Y = c[2], Z = c[3]}, {X = far[1], Y = far[2], Z = far[3]})
    if ok and hit and pos then return {pos.X, pos.Y, pos.Z} end
  end
  if ground_z and math.abs(d[3]) > 1e-6 then
    local t = (ground_z - c[3]) / d[3]
    if t > 0 then return {c[1] + d[1] * t, c[2] + d[2] * t, ground_z} end
  end
  return nil, "Nothing of the world under that point"
end

-- the people of the scene where they are drawn now: {actor, x, y (the handle: their feet, or their hips when the
-- feet are below the picture), feet_x, feet_y, head_x, head_y (screen pixels, also outside the picture), world =
-- {x, y, z}, yaw} - those of whom the picture shows something
function SW:people_on_screen()
  local out = {}
  local rx, ry, rw, rh = picture()
  if not rw then return out end                 -- (no game picture: the lab)
  local function px(p, dz)
    local u, v = SW.ratio({X = p.X, Y = p.Y, Z = p.Z + dz, W = 1})
    if not u then return nil end
    return rx + u * rw, ry + v * rh, u >= 0 and u <= 1 and v >= 0 and v <= 1
  end
  for _, a in ipairs(self.s:actors()) do
    local e = self:figure_of(a.id)
    if e then
      local ok, p, r = pcall(function() return e:GetWorldPosition(), e:GetWorldRotation() end)
      if ok and p then
        local fx, fy, fin = px(p, 0)
        local hipx, hipy, hin = px(p, 1.0)
        local hx, hy, headin = px(p, 1.8)
        if fin or hin or headin then
          local x, y = fx, fy
          if not fin and hin then x, y = hipx, hipy end
          out[#out + 1] = {actor = a.id, x = x, y = y, feet_x = fx, feet_y = fy, head_x = hx, head_y = hy,
                           world = {p.X, p.Y, p.Z}, yaw = r and r.Yaw or 0}
        end
      end
    end
  end
  return out
end

-- a camera with a free view of the moment: the views in turn at its size, the first whose line to the people no wall
-- cuts (w3.world.trace through the static world) -> the view taken, or nil (none free, or no game)
function SW:free_camera(sec, el)
  if not (w3.world and w3.world.trace) then return nil end
  local m = self.s:moment(sec, el)
  local set = self.s:set_of(sec)
  local ds = set and self.s:obj(self.s:_dialogset(set) or 0)
  local tag = ds and (ds:get("placementTag") or {})[1] or "PLAYER"
  local base, yaw = SW.spot_world(tag)
  if not base then return nil end
  local a = math.rad(yaw)
  local function world(p)
    return {X = base[1] + p[1] * math.cos(a) - p[2] * math.sin(a), Y = base[2] + p[1] * math.sin(a) + p[2] * math.cos(a),
            Z = base[3] + p[3]}
  end
  local at = middle(m.places)
  local size = m.camera and m.camera.size or "medium"
  for _, view in ipairs(SF.VIEW_ORDER) do
    local v, k = SF.VIEWS[view], SF.SIZES[size] or 1.0
    local cp = {at[1] + (v[1][1] - v[2][1]) * k, at[2] + (v[1][2] - v[2][2]) * k, at[3] + (v[1][3] - v[2][3]) * k}
    local ok, hit = pcall(w3.world.trace, world(at), world(cp))
    if ok and not hit then
      self:set_moment_camera(sec, el, view, size)
      return view
    end
  end
  return nil
end

-- where the player stands, from the spot's tag: {x, y, z} and yaw in the spot's own frame (nil: no such entity)
function SW.player_from(tag)
  if not w3.player then return nil end
  local p = w3.player()
  if not p then return nil end
  local pos, rot = p:GetWorldPosition(), p:GetWorldRotation()
  if tag == "PLAYER" then return nil, "the spot is the player" end
  local ok, e = pcall(function() return w3.global("theGame"):GetEntityByTag(tag) end)
  if not ok or not e then return nil, "nothing in the world has the tag " .. tostring(tag) end
  local ep, er = e:GetWorldPosition(), e:GetWorldRotation()
  local dx, dy, dz = pos.X - ep.X, pos.Y - ep.Y, pos.Z - ep.Z
  local a = math.rad(-(er.Yaw or 0))
  local x, y = dx * math.cos(a) - dy * math.sin(a), dx * math.sin(a) + dy * math.cos(a)
  return {x, y, dz}, (rot.Yaw or 0) - (er.Yaw or 0)
end

-- --- the world state: the facts the scene asks and sets, what they are now, and what the project wants for them
function SW:_read_world()
  if not self.project_dir then return {} end
  local ok, v = pcall(J.read, self.project_dir .. "\\" .. SW.WORLD)
  return ok and type(v) == "table" and type(v[self.path]) == "table" and v[self.path] or {}
end
function SW:_write_world()
  if not self.project_dir then return end
  local f = self.project_dir .. "\\" .. SW.WORLD
  local ok, v = pcall(J.read, f)
  if not (ok and type(v) == "table") then v = {} end
  local mine = {}
  for k, x in pairs(self.world) do mine[k] = x end
  v[self.path] = next(mine) and mine or nil
  pcall(J.write, f, v)
end

function SW:facts()
  local out = {}
  for name, use in pairs(self.s:facts()) do
    local now = w3.fact and w3.fact.get and select(2, pcall(function() return w3.fact.get(name) end)) or nil
    out[#out + 1] = {name = name, reads = #use.reads, sets = #use.sets, now = tonumber(now) or 0,
                     want = self.world[name]}
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- a fact as the project wants it for this scene (nil: as the game has it); set at once in the running game, the
-- game's value noted to come back (restore_facts)
function SW:set_fact(name, value)
  self.world[name] = value
  self:_write_world()
  if value == nil then
    if self.facts_before[name] ~= nil then
      pcall(function() w3.fact.set(name, self.facts_before[name]) end)
      self.facts_before[name] = nil
    end
    return true
  end
  if self.facts_before[name] == nil then
    local ok, now = pcall(function() return w3.fact.get(name) end)
    self.facts_before[name] = ok and tonumber(now) or 0
  end
  local ok = pcall(function() w3.fact.set(name, value) end)
  return ok
end

-- the project's facts for this scene into the game (opening it)
function SW:apply_world()
  for name, value in pairs(self.world) do
    if self.facts_before[name] == nil then
      local ok, now = pcall(function() return w3.fact.get(name) end)
      self.facts_before[name] = ok and tonumber(now) or 0
    end
    pcall(function() w3.fact.set(name, value) end)
  end
end

function SW:restore_facts()
  for name, value in pairs(self.facts_before) do pcall(function() w3.fact.set(name, value) end) end
  self.facts_before = {}
end

-- --- a person's animation shown on their figure in the world (TW3SE's w3.anim.pose), for picking one

-- the figure in the world that plays person `actor` of the scene: the player for the player, else the one with the
-- scene's tag for that person, else one near with that voice tag -> entity or nil
function SW:figure_of(actor)
  if actor == "GERALT" or actor == "PLAYER" then return w3.player and w3.player() or nil end
  local okg, game = pcall(w3.global, "theGame")
  for _, a in ipairs(self.s:actors()) do
    if a.id == actor and okg then
      for _, tag in ipairs(type(a.tags) == "table" and a.tags or {}) do
        -- (every figure with the tag: two of them - a spawned one kept in a save - and the scene took one, a check the
        -- other; 02.11. The one a scene holds now, else the nearest to the player)
        local cands = {}
        local oka, all = pcall(w3.all, "CNewNPC")
        for _, e in ipairs(oka and all or {}) do
          local okt, has = pcall(function() return e:HasTag(tag) end)
          if okt and has then cands[#cands + 1] = e end
        end
        if #cands == 1 then return cands[1] end
        if #cands > 1 then
          for _, e in ipairs(cands) do
            local okc, held = pcall(function() return e:IsInNonGameplayCutscene() end)
            if okc and held then return e end
          end
          local pp = w3.player():GetWorldPosition()
          table.sort(cands, function(x, y)
            local px, py = x:GetWorldPosition(), y:GetWorldPosition()
            return (px.X - pp.X) ^ 2 + (px.Y - pp.Y) ^ 2 < (py.X - pp.X) ^ 2 + (py.Y - pp.Y) ^ 2
          end)
          return cands[1]
        end
        local ok, e = pcall(function() return game:GetEntityByTag(tag) end)
        if ok and e then return e end
      end
    end
  end
  if w3.near then
    local ok, near = pcall(w3.near, 25)
    for _, e in ipairs(ok and near or {}) do
      local okt, t = pcall(function() return e:GetVoicetag() end)
      if okt and t and tostring(t):lower() == tostring(actor):lower() then return e end
    end
  end
  return nil
end

-- animation `name` on figure e: its length -> seconds; nil, "" while its data streams in (ask again); nil, why when
-- the figure cannot play it (not in its sets, or made for another skeleton)
function SW.peek_ready(e, name)
  if not (w3.anim and w3.anim.sample) then return nil, "This TW3SE cannot show an animation on a figure" end
  local ok, pose, why = pcall(w3.anim.sample, e, name, 0.0)
  if not ok then return nil, tostring(pose) end
  if not pose then return nil, why or "" end
  local own = w3.pose and w3.pose(e)
  if own and own.count and pose.count and own.count ~= pose.count then
    return nil, "The animation is made for another skeleton"
  end
  return pose.duration or 0.0
end

-- --- the scenes the game is at now: those of the quest blocks active this moment (a talk waiting, a scene to
-- start), then those with people near the player in them -> {{path, why}}
function SW.here(index, info)
  local out, seen = {}, {}
  local function add(p, why)
    p = p:gsub("/", "\\"):lower()
    if not seen[p] then
      seen[p] = true
      out[#out + 1] = {path = p, why = why}
    end
  end
  if w3.quest and w3.quest.blocks then
    local ok, blocks = pcall(w3.quest.blocks)
    for _, b in ipairs(ok and blocks or {}) do
      if b.class:find("Scene") or b.class:find("Dialog") or b.class:find("Interaction") then
        local okd, text = pcall(w3.dump, b.block)
        for p in tostring(okd and text or ""):gmatch("[%w_\\/%.]+%.w2scene") do add(p, "a quest is at it now") end
      end
    end
  end
  if w3.near and info then
    local ok, near = pcall(w3.near, 25)
    local tags = {}
    for _, e in ipairs(ok and near or {}) do
      local okt, t = pcall(function() return e:GetVoicetag() end)
      if okt and t and t ~= "" and t ~= "None" and t ~= "GERALT" then tags[tostring(t):lower()] = true end
    end
    if next(tags) then
      for _, p in ipairs(index or {}) do
        local i = info[p]
        if i and i[2] and i[2] > 0 then
          for w in tostring(i[1]):gmatch("%S+") do
            if tags[w] then add(p, "with " .. w .. " (near)") break end
          end
        end
        if #out >= 300 then break end
      end
    end
  end
  return out
end

return SW
