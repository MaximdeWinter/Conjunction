-- quest.py, as far as the editor and the project need it so far: whether a placed object is a person or a creature.
local CAT = require("conjunction.catalog")
local PYS = require("conjunction.pystr")   -- (Python's str.lower: umlauts too)
local Q = {}
Q.ACTOR_CLASSES = {CNewNPC = true, W3MerchantNPC = true, W3MonsterHuntNPC = true, W3NPCBackground = true, CGhost = true}
Q.SPOT_MARKER = [[dlc\bob\data\environment\decorations\gameplay\flags_banners\flag_racing_b.w2ent]]

-- the entity class the catalog read from the template ("" when the catalog does not know it): assets.sqlite's
-- templates table, as the app asks it (quest.template_class)
local actor_class = {}
Q.template_class = function(template)
  local t = PYS.lower(template or "")
  if actor_class[t] == nil then
    local ok, r = pcall(function()
      local DB = require("conjunction.db")
      local db = DB.open(require("conjunction.assets").DB, false)
      local row = db:one("select class from templates where path = ?", t)
      db:close()
      return row
    end)
    local cls = ok and r and r[1] or nil
    actor_class[t] = (cls ~= nil and cls ~= require("conjunction.yaml").null) and tostring(cls) or ""
  end
  return actor_class[t]
end

-- people, monsters and animals (they come as a community): the object's own "actor", else the template's class,
-- else its path
function Q.is_actor(obj)
  local a = obj.actor
  if a ~= nil then
    local Y = require("conjunction.yaml")
    if a == Y.null then return false end
    if type(a) == "table" then return next(a) ~= nil end   -- (Python's bool(): an empty list or dict is False)
    return a ~= false and a ~= 0 and a ~= ""
  end
  local cls = Q.template_class(obj.template)
  if cls and cls ~= "" then return Q.ACTOR_CLASSES[cls] == true end
  local k = CAT.kind_of(PYS.lower(obj.template))
  return k == "NPC" or k == "Monster" or k == "Animal"
end

-- {table of a step's arguments (and of everything inside them) = who is played there} (quest.characters, a graph's):
-- the quest starts as q.player (Geralt when not set); a 'playas' step changes it along the wires; a node nothing leads
-- to: as the quest starts
function Q.characters(q)
  local Y = require("conjunction.yaml")
  local P = require("conjunction.py")
  local D = require("conjunction.dialogue")
  local start = P.str(P.or_(P.get(q, "player"), "geralt"))
  local out, who_at, queue = {}, {start = start}, {"start"}
  local function mark_all(x, who)
    if type(x) == "table" and x ~= Y.null then
      out[x] = who
      if Y.is_map(x) then for _, k in ipairs(Y.keys(x)) do mark_all(x[k], who) end
      else for _, v in ipairs(x) do mark_all(v, who) end end
    end
  end
  local nodes = P.get(q, "nodes") or Y.map()
  while #queue > 0 do
    local nid = table.remove(queue, 1)
    local node = P.get(nodes, nid)
    if node ~= nil then
      local who = who_at[nid]
      mark_all(node.step, who)
      local kind = Y.keys(node.step)[1]
      local args = kind and node.step[kind]
      local as = Y.is_map(args) and P.get(args, "as") or nil
      if kind == "playas" and as ~= nil and P.get(D.PLAYERS, as) ~= nil then who = as end
      for _, ln in ipairs(P.list(P.get(q, "links"))) do
        if ln[1] == nid and who_at[ln[3]] == nil then
          who_at[ln[3]] = who
          queue[#queue + 1] = ln[3]
        end
      end
    end
  end
  for _, nid in ipairs(Y.keys(nodes)) do
    if who_at[nid] == nil then mark_all(nodes[nid].step, start) end
  end
  return out
end

-- what can not hold a quest's items (quest.NOT_LOOT): the reason, by the template's class
Q.NOT_LOOT = {W3Stash = "Geralt's stash (it opens his own storage, quest items stay out of it). Take a chest"}
function Q.not_loot(template) return Q.NOT_LOOT[Q.template_class(template)] end
-- something to loot (a container, a body, a person)? Unknown: yes. Geralt's stash: no
function Q.lootable(template)
  local cls = Q.template_class(template) or ""
  if Q.NOT_LOOT[cls] then return false end
  local low = PYS.lower(cls)
  return cls == "" or low:find("container", 1, true) ~= nil or low:find("stash", 1, true) ~= nil or
         Q.is_actor({template = template})
end

local NUM = require("conjunction.pynum")
local function null(v) return v == nil or v == require("conjunction.yaml").null end
local function truthy(v)
  return not null(v) and v ~= false and v ~= "" and v ~= 0 and not (type(v) == "table" and next(v) == nil)
end

-- {{position, radius, map radius or nil}} of every Go to whose spot (or point) is in `place` (the editor draws them)
function Q.spot_rings(q, project, place)
  local Y = require("conjunction.yaml")
  local out = {}
  local function walk(x)
    if Y.is_map(x) then
      for k, v in pairs(x) do
        if k == "goto" and Y.is_map(v) then
          local pos
          if truthy(v.at) then
            local s = NUM.str(v.at)
            local slash = s:find("/", 1, true)
            local pl, oid = slash and s:sub(1, slash - 1) or s, slash and s:sub(slash + 1) or ""
            local p = project.places[pl]
            local objs = (Y.is_map(p) and not null(p.objects)) and p.objects or {}
            local o
            for _, ob in ipairs(objs) do if ob.id == oid then o = ob break end end
            pos = (o and pl == place) and o.pos or nil
          elseif truthy(v.pos) and (v.place == nil and place or v.place) == place then
            pos = v.pos
          end
          if truthy(pos) then
            local r = NUM.float(v.radius == nil and 10 or v.radius)
            local area
            if v.map ~= "pin" then area = truthy(v.map_radius) and NUM.float(v.map_radius) or r end
            out[#out + 1] = {pos, r, area}
          end
        end
        walk(v)
      end
    elseif type(x) == "table" and x ~= Y.null then
      for _, v in ipairs(x) do walk(v) end
    end
  end
  walk(q)
  return out
end

-- --- the words of a step (the graph's lines, journal lines made from a step)
local P = require("conjunction.py")
Q.COND_KINDS = {{"fact", "a fact"}, {"path", "a branch was taken"}, {"area", "the player is in an area"},
                {"item", "the player has an item"}, {"quest", "a quest's state"}, {"time", "the time of day"},
                {"present", "someone is there"}, {"combat", "the player is fighting"},
                {"near", "someone is near someone"}, {"health", "someone's health is down to"},
                {"alive", "someone is alive"}, {"state", "someone is fighting, knocked out or dead"},
                {"gone", "someone is gone"}, {"riding", "the player rides or sails"},
                {"doing", "the player swims, dives, climbs ..."}}
-- the game's checks of a person, by how often its quests use them - quest_encoder's "actor" / "scripted"
Q.PERSON_STATES = {{"combat", "fighting", "EQNS_Combat"}, {"unconscious", "knocked out", "EQNS_KnockedUnconscious"},
                   {"dead", "dead", "EQNS_Dead"}}
Q.RIDES = {{"horse", "on a horse", "EVT_Horse"}, {"boat", "in a boat", "EVT_Boat"}, {"any", "on a horse or in a boat", ""}}
Q.PLAYER_DOES = {{"swimming", "swims", "QCPS_Swimming"}, {"diving", "dives", "QCPS_Diving"},
                 {"climbing", "climbs", "QCPS_Climbing"}, {"running", "runs", "QCPS_Running"},
                 {"sprinting", "sprints", "QCPS_Sprinting"}, {"walking", "walks", "QCPS_Walking"},
                 {"meditating", "meditates", "QCPS_Preparation"}, {"sign", "casts a sign", "QCPS_CastingSign"}}
-- a person's state (ChangeNPCStateQuest), a map pin's (SetMapPinStatus)
Q.NPC_STATES = {{"unconscious", "knocked out", "EQNS_KnockedUnconscious"}, {"agony", "dying on the ground", "EQNS_Agony"},
                {"dead", "dead", "EQNS_Dead"}, {"normal", "back to normal", "EQNS_Default"}}
Q.PIN_STATES = {{"known", "known", "EMPS_Known"}, {"discovered", "discovered", "EMPS_Discovered"},
                {"off", "off the map", "EMPS_Disabled"}}
-- column col (2: the label, 3: the game's value) of the entry of such a table with this key (nil: none)
function Q.pick(tbl, key, col)
  for _, e in ipairs(tbl) do if e[1] == key then return e[col] end end
  return nil
end
Q.QUEST_STATES = {{"active", "is running", "JS_Active"}, {"done", "is done", "JS_Success"},
                  {"failed", "has failed", "JS_Failed"}}
Q.DEFAULT_TEXT = {talk = "Talk to {who}", ["goto"] = "Go to {where}", loot = "Search {what}",
                  examine = "Examine {what}", use = "Use {what}", kill = "Kill {what}", collect = "Collect {what}",
                  wait = "Wait", either = "Decide", all = "Do all of these",
                  clues = "Look for clues with your witcher senses", defeat = "Defeat {who}", read = "Read {what}",
                  follow = "Follow {who}", gwent = "Win a game of gwent", fistfight = "Beat {who} in a fist fight",
                  notice = "Check the notice board"}

-- a step's conditions: its list - or the older If / Wait until (a fact, a branch) as one
function Q.conditions_of(s)
  local Y = require("conjunction.yaml")
  if P.T(P.get(s, "conditions")) then return P.copy_list(s.conditions) end
  if P.T(P.get(s, "path")) then return {Y.map({"kind", "path", "path", s.path})} end
  if P.T(P.get(s, "fact")) then
    return {Y.map({"kind", "fact", "fact", s.fact, "op", P.or_(P.get(s, "op"), ">="), "value", P.get(s, "value", 1)})}
  end
  return {}
end

function Q.cond_kind(c)
  if P.T(P.get(c, "kind")) then return c.kind end
  for _, k in ipairs(Q.COND_KINDS) do if P.has(c, k[1]) then return k[1] end end
  return "fact"
end

-- a step's conditions in a few words (the node's line): 'met_baron >= 1 or 22:00-04:00'
function Q.conditions_text(s)
  local Y = require("conjunction.yaml")
  local words = {}
  for _, c in ipairs(Q.conditions_of(s)) do
    local kind = Q.cond_kind(c)
    local w
    if kind == "fact" then
      w = P.str(P.or_(P.get(c, "fact"), "?")) .. " " .. P.str(P.or_(P.get(c, "op"), ">=")) .. " " ..
          P.str(P.get(c, "value", 1))
    elseif kind == "path" then
      w = "'" .. P.str(P.or_(P.get(c, "path"), "?")) .. "' taken"
    elseif kind == "area" then
      w = "in the area" .. (P.T(P.get(c, "place")) and (" (" .. P.str(c.place) .. ")") or "")
    elseif kind == "item" then
      w = "has " .. P.str(P.get(c, "count", 1)) .. " " .. P.replace(P.str(P.or_(P.get(c, "item"), "?")), "own:", "")
    elseif kind == "quest" then
      local label = P.str(P.or_(P.get(P.or_(P.get(c, "quest"), Y.map()), "label"), "a quest"))
      local parts, i = {}, 1
      while true do
        local a, b = label:find(" / ", i, true)
        if not a then break end
        parts[#parts + 1] = label:sub(i, a - 1)
        i = b + 1
      end
      label = label:sub(i)
      local state = P.or_(P.get(c, "state"), "done")
      local said = ""
      for _, st in ipairs(Q.QUEST_STATES) do if st[1] == state then said = st[2] end end
      w = label .. " " .. said
    elseif kind == "time" then
      w = P.str(P.or_(P.get(c, "from"), "20:00")) .. "-" .. P.str(P.or_(P.get(c, "to"), "06:00"))
    elseif kind == "present" then
      w = P.str(P.or_(P.get(c, "who"), P.get(c, "tag"), "?")):match("([^/]*)$") .. " there"
    elseif kind == "near" or kind == "health" or kind == "alive" or kind == "state" or kind == "gone" then
      local who = P.str(P.or_(P.get(c, "who"), "player")):match("([^/]*)$")
      if kind == "near" then
        w = who .. " " .. (P.T(P.get(c, "farther")) and "farther than" or "within") .. " " ..
            P.str(P.get(c, "metres", 5)) .. " m of " .. P.str(P.or_(P.get(c, "to"), "player")):match("([^/]*)$")
      elseif kind == "health" then
        w = who .. "'s health <= " .. P.str(P.get(c, "percent", 20)) .. "%"
      elseif kind == "alive" then
        w = who .. " alive"
      elseif kind == "state" then
        w = who .. " " .. P.str(Q.pick(Q.PERSON_STATES, P.or_(P.get(c, "state"), "combat"), 2))
      else
        w = who .. " gone"
      end
    elseif kind == "riding" then
      w = "player " .. P.str(Q.pick(Q.RIDES, P.or_(P.get(c, "on"), "horse"), 2))
    elseif kind == "doing" then
      w = "player " .. P.str(Q.pick(Q.PLAYER_DOES, P.or_(P.get(c, "does"), "swimming"), 2))
    else
      w = "fighting"
    end
    words[#words + 1] = (P.T(P.get(c, "not")) and "not " or "") .. w
  end
  return table.concat(words, P.T(P.get(s, "any")) and " or " or " and ")
end

-- what an item is called in a line: an own item by its name, a game item by its (readable) id
function Q._item_name(ref, items)
  ref = P.str(P.or_(ref, ""))
  if P.startswith(ref, "own:") then
    local own = P.or_(P.get(P.or_(items, {}), ref:sub(5)), {})
    return P.str(P.or_(P.get(own, "name"), P.replace(ref:sub(5), "_", " ")))
  end
  return P.replace(ref, "_", " ")
end

-- a loot / collect step's items: the first ('item', 'count') and the ones added to it ('more_items')
function Q.step_items(a)
  local out = {}
  if P.T(P.get(a, "item")) then out[#out + 1] = {item = a.item, count = P.get(a, "count", 1)} end
  for _, x in ipairs(P.list(P.get(a, "more_items"))) do
    if P.T(P.get(x, "item")) then out[#out + 1] = {item = x.item, count = P.get(x, "count", 1)} end
  end
  return out
end

-- {place/id: the name shown above a person}
function Q.display_names(project)
  local out = {}
  for place, p in pairs(project.places) do
    for _, o in ipairs(P.list(P.get(p, "objects"))) do
      if P.T(P.get(o, "id")) and P.T(P.get(o, "display")) then out[place .. "/" .. P.str(o.id)] = o.display end
    end
  end
  return out
end

local function last_part(s) return s:match("([^/]*)$") end

-- the journal line of a step made from it; `items`: the quest's own items; `names`: display_names()
function Q.default_text(kind, a, items, names)
  local function call(ref)
    ref = P.str(P.or_(ref, ""))
    return P.or_((names or {})[ref], P.replace(last_part(ref), "_", " "))
  end
  local g = function(k) return P.get(a, k) end
  local function where_of() return P.replace(last_part(P.str(P.or_(g("object"), ""))), "_", " ") end
  if kind == "follow" and P.T(g("lead")) then
    return "Lead " .. P.or_(call(g("who")), "them") .. " to safety"
  end
  if kind == "use" and (P.T(g("item")) or P.T(g("state"))) then
    local where = P.or_(where_of(), "it")
    if g("state") == "on" or g("state") == "off" then return "Switch the " .. where .. " " .. a.state end
    return "Use the " .. Q._item_name(a.item, items) .. " on the " .. where
  end
  local many = (kind == "loot" or kind == "collect" or kind == "equip") and Q.step_items(a) or {}
  if (kind == "loot" or kind == "collect") and #many > 1 then
    local what
    if #many == 2 then
      what = "the " .. Q._item_name(many[1].item, items) .. " and the " .. Q._item_name(many[2].item, items)
    else
      what = "the " .. Q._item_name(many[1].item, items) .. " and " .. (#many - 1) .. " more items"
    end
    local where = kind == "loot" and where_of() or ""
    return (kind == "loot" and "Take " or "Get ") .. what .. (where ~= "" and (" from the " .. where) or "")
  end
  if kind == "equip" and #many > 0 then
    local s = "Equip the " .. Q._item_name(many[1].item, items)
    if #many == 2 then
      s = s .. " and the " .. Q._item_name(many[2].item, items)
    elseif #many > 2 then
      s = s .. " and " .. (#many - 1) .. " more items"
    end
    return s
  end
  if kind == "loot" and P.T(g("item")) then
    local where = where_of()
    return "Take the " .. Q._item_name(a.item, items) .. (where ~= "" and (" from the " .. where) or "")
  end
  if kind == "talk" then
    local D = require("conjunction.dialogue")
    local give
    for _, x in ipairs(D.walk(D.from_step(a))) do
      local gv = P.get(x, "give")
      if P.T(gv) and P.T(P.get(gv, "item")) then give = gv.item break end
    end
    if give then
      local who = call(g("npc"))
      return "Bring " .. Q._item_name(give, items) .. (who ~= "" and (" to " .. who) or "")
    end
  end
  if kind == "goto" and (P.T(g("pos")) or P.T(g("at"))) and not P.T(g("text")) then return "Go to the marked place" end
  -- (Python's `or`: the first true one, the rest not looked at - (a.get("targets") or [""])[0] only when needed)
  local what
  for _, k in ipairs({"npc", "who", "object", "target", "targets", "item", "place"}) do
    local v = g(k)
    if k == "targets" then
      v = P.or_(v, {""})
      if type(v) == "string" then v = PYS.from_cps(PYS.cps(v), 1, 1) else v = v[1] end   -- ([0] of a str)
    end
    if P.T(v) then what = v break end
  end
  what = what or ""
  local of_world = P.startswith(P.str(what), "@world/")   -- (a thing of the world: "Search the crate")
  if P.startswith(P.str(what), "own:") then what = Q._item_name(what, items) else what = call(what) end
  local text = Q.DEFAULT_TEXT[kind] or ""
  local word = P.T(what) and ((of_world and "the " or "") .. what) or nil
  local fill = {who = word or "someone", where = word or "a place", what = word or "it"}
  return (text:gsub("{(%a+)}", function(k) return fill[k] end))
end
return Q
