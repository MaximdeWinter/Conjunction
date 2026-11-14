-- scene_import.py: a game scene's talks as Conjunction dialogues (for a swap: start from the game's own words -
-- change a line, add an answer - instead of from nothing). Per input of the scene: its lines with their voices (the
-- game's own recordings play), its choices with their answers, where each way ends (back to the choices, one of the
-- scene's outputs). Taken too: conditions on facts in the flow, scripts among the lines, answers shown only if a fact
-- is so, the door icon, Axii, paying. What the dialogue tree cannot hold is not loaded (that input starts empty,
-- `why` says why).
--   SI.talks(f, main_of, texts, voices) -> {order = {input name ...}, by = {name = {dialogue, then, why}}}
--   SI.load_into(swap, depot) -> swap
local CE = require("conjunction.cr2w_edit")
local CR = require("conjunction.cr2w")
local N = require("conjunction.pynum")
local P = require("conjunction.py")
local QR = require("conjunction.questread")
local Y = require("conjunction.yaml")
local SI = {}

local PLAIN = {CStorySceneLine = true, CStoryScenePauseElement = true, CStorySceneChoice = true,
               CStorySceneComment = true}
-- answer icons radish writes (test_dialogscript_choice_action.yml); what they open is a script after the answer
local ICONS = {CExitStorySceneChoiceAction = "exit", CShopStorySceneChoiceAction = "shop",
               CArmorerStorySceneChoiceAction = "blacksmith", CGameCardsChoiceAction = "gwent",
               CDiceStorySceneChoiceAction = "betting"}
local OPS = {CF_Equal = "=", CF_NotEqual = "!=", CF_Less = "<", CF_LessEqual = "<=", CF_Greater = ">",
             CF_GreaterEqual = ">="}
local NOT = {[">="] = "<", ["<"] = ">=", [">"] = "<=", ["<="] = ">", ["="] = "!=", ["!="] = "="}

-- NotLoadable: an error of its own (the rest go on up, as Python's)
local NL = {}
local function not_loadable(why) error(setmetatable({why = why}, NL), 0) end
SI.NotLoadable = NL

local function plain_replace(s, a, b) return (s:gsub(a:gsub("%p", "%%%0"), (b:gsub("%%", "%%%%")))) end

-- Python's truth of a decoded value
local function T(v)
  if v == nil or v == false or v == "" or v == 0 or v == CE.NONE then return false end
  if getmetatable(v) == CE.BYTES then return v.bytes ~= "" end
  if type(v) == "table" then
    if CE.is_dict(v) then return #CE.all_keys(v) > 0 end
    return next(v) ~= nil
  end
  return true
end
local function or_(a, b) if T(a) then return a end return b end
local function has_key(d, k)
  for _, x in ipairs(CE.all_keys(d)) do if x == k then return true end end
  return false
end
-- int(x) of a decoded number (a bool counts)
local function int(x)
  if x == true then return 1 end
  if x == false or x == nil then return 0 end
  if math.type(x) == "float" then
    local i = x >= 0 and math.floor(x) or math.ceil(x)
    return math.tointeger(i) or i
  end
  if type(x) == "string" then return math.tointeger(tonumber(x)) or error("ValueError: invalid literal for int()", 0) end
  return x
end
local function list(v) if T(v) and type(v) == "table" and not CE.is_dict(v) then return v end return {} end

local function deepcopy(v)
  if Y.is_map(v) then
    local m = Y.map()
    for _, k in ipairs(Y.keys(v)) do m[k] = deepcopy(v[k]) end
    return m
  end
  if Y.is_list(v) then
    local l = Y.list({})
    for i, x in ipairs(v) do l[i] = deepcopy(x) end
    return l
  end
  return v
end

-- [fact, op, value] of a game fact condition (its class defaults: compare equal, value 0, the sum of the fact)
function SI.fact_check(cls_name, d)
  if cls_name ~= "CQuestFactsDBCondition" and cls_name ~= "CQuestFactsDBForbiddenCondition" then
    not_loadable("a condition on " .. plain_replace(plain_replace(cls_name, "CQuest", ""), "W3QuestCond_", ""))
  end
  if d.queryFact == "QF_DoesExist" and not has_key(d, "compareFunc") and not has_key(d, "value") then
    not_loadable("a 'does exist' fact check without a comparison")
  end
  local check = {or_(d.factId, ""), OPS[or_(d.compareFunc, "CF_Equal")] or "=", int(or_(d.value, 0))}
  if d.queryFact == "QF_DoesExist" then
    -- the game asks 0 or 1 (there or not): which of them pass is what the check means - 'there' or 'not there'
    local tests = {[">="] = function(a, b) return a >= b end, [">"] = function(a, b) return a > b end,
                   ["<="] = function(a, b) return a <= b end, ["<"] = function(a, b) return a < b end,
                   ["="] = function(a, b) return a == b end, ["!="] = function(a, b) return a ~= b end}
    local test = tests[check[2]]
    local p0, p1 = test(0, check[3]), test(1, check[3])
    if p0 == p1 then not_loadable("a 'does exist' fact check that is always or never true") end
    check = {check[1], p1 and ">=" or "<", 1}
  end
  if cls_name == "CQuestFactsDBForbiddenCondition" then check[2] = NOT[check[2]] end
  return check
end

-- `main_of(input name)` -> the actor key that speaks as the talk's NPC ("npc" in the dialogue)
function SI.talks(f, main_of, texts, voices)
  local SS = require("conjunction.scene_swap")
  local props = {}
  local function p(i)
    if props[i] == nil then props[i] = CE.decode_ordered(f, f.exports[i][5]) end
    return props[i]
  end
  local function cls(i) return f.exports[i][1] end
  local function handle(v) return QR.is_ref(v, "export") and v[2] or nil end

  -- through link elements to what they lead to
  local function follow(i)
    local seen = {}
    while i and cls(i) == "CStorySceneLinkElement" do
      if seen[i] then not_loadable("a loop of links") end
      seen[i] = true
      i = handle(p(i).nextLinkElement)
    end
    return i
  end

  local function text_of(v)
    local sid = QR.is_ref(v, "string") and v[2] or nil
    if T(sid) then return sid, (texts or {})[sid] or "" end
    return sid, ""
  end

  local out = {order = {}, by = {}}
  local inputs = {}
  for i = 1, #f.exports do
    if cls(i) == "CStorySceneInput" then inputs[#inputs + 1] = {i, p(i)} end
  end
  for _, inp in ipairs(inputs) do
    local d = inp[2]
    local name = or_(d.inputName, "Input")
    local main = main_of(name)

    local function who(voicetag)
      local k = SS.key(or_(voicetag, ""))
      if k == "geralt" then return "player" end
      if k == main then return "npc" end
      return k
    end

    local function line(e)
      local sid, text = text_of(p(e).dialogLine)
      local x = Y.map({"who", who(p(e).voicetag), "text", T(text) and text or "..."})
      local v = (voices and T(sid)) and voices:line(sid) or nil
      if T(v) then
        local VO = require("conjunction.voices")
        x.voice = sid
        x.text = T(v.text) and v.text or x.text
        x.dur = VO.length(sid, v.dur, x.text)
      end
      return x
    end

    -- a scene script's call: its function and its parameters (a property list after its own)
    local function script(node)
      local chunk = f.exports[node][5]
      local ps = f:props(chunk)
      local k = (#ps > 0 and (ps[#ps][3] + ps[#ps][4]) or 1) + 2           -- after the properties' end (0-based)
      local params = Y.list({})
      while k + 8 <= #chunk do
        local nm, tp, sz = string.unpack("<I2I2I4", chunk, k + 1)
        if nm == 0 or nm >= #f.names then break end
        local pname, typ, val = f.names[nm + 1], f.names[tp + 1], chunk:sub(k + 9, k + 4 + sz)
        local value
        local function latin1(b) return (b:gsub("[\128-\255]", function(c) return utf8.char(c:byte()) end)) end
        if typ == "String" then
          local b0 = val:byte(1)
          local n = (b0 & 0x80 ~= 0) and (b0 & 0x3F) or 0
          if b0 & 0x40 == 0 then value = latin1(val:sub(2, 1 + n))
          else value = latin1(val:sub(3, 2 + ((val:byte(2) << 6) | n))) end
        elseif typ == "CName" then
          value = "cname_" .. f.names[string.unpack("<I2", val, 1) + 1]
        elseif typ == "Int32" or typ == "Uint32" or typ == "Int8" or typ == "Uint8" or typ == "Int16" or
               typ == "Uint16" then
          if #val == 0 then value = 0
          else value = string.unpack((typ:sub(1, 3) == "Int" and "<i" or "<I") .. #val, val) end
        elseif typ == "Float" then
          value = N.round(string.unpack("<f", val, 1), 4)
        elseif typ == "Bool" then
          value = val:byte(1) ~= 0
        else
          not_loadable("a script with a " .. typ .. " parameter")
        end
        params[#params + 1] = Y.map({pname, value})
        k = k + 4 + sz
      end
      return Y.map({"function", or_(p(node).functionName, ""), "parameter", params})
    end

    -- an answer's condition -> only_if checks {{fact, op, value}}, needs {item, count, none} or nil: facts (all of
    -- them), items the player has (one of them) or has not
    local answer_condition
    answer_condition = function(q)
      local c = cls(q)
      if c == "CQuestLogicOperationCondition" then
        local op = or_(p(q).logicOperation, "LO_And")
        local subs = {}
        for _, h in ipairs(list(p(q).conditions)) do
          if QR.is_ref(h, "export") then
            local fs, n = answer_condition(h[2])
            subs[#subs + 1] = {fs, n}
          end
        end
        local facts, needs = {}, {}
        for _, s in ipairs(subs) do for _, x in ipairs(s[1]) do facts[#facts + 1] = x end end
        for _, s in ipairs(subs) do if T(s[2]) then needs[#needs + 1] = s[2] end end
        if op == "LO_And" and #needs <= 1 then return facts, needs[1] end
        if op == "LO_Or" and #facts == 0 and #needs > 0 then
          local all = true
          for _, n in ipairs(needs) do
            if T(n.none) or n.count ~= needs[1].count then all = false end
          end
          if all then
            local m = deepcopy(needs[1])
            local items = Y.list({})
            for _, n in ipairs(needs) do for _, it in ipairs(n.item) do items[#items + 1] = it end end
            m.item = items
            return {}, m
          end
        end
        not_loadable("a condition " .. P.str(op) .. " of facts and items")
      end
      if c == "W3QuestCond_IsItemQuantityMet" then
        local d2 = p(q)
        if or_(d2.entityTag, "PLAYER") ~= "PLAYER" or not T(d2.itemName) then
          not_loadable("a condition on somebody else's items")
        end
        local cmp, count = or_(d2.comparator, "CO_Equal"), int(or_(d2.count, 0))
        if cmp == "CO_GreaterEq" or cmp == "CO_Greater" then
          return {}, Y.map({"item", Y.list({d2.itemName}), "count", math.max(1, count + (cmp == "CO_Greater" and 1 or 0))})
        end
        if (cmp == "CO_LesserEq" or cmp == "CO_Equal") and count == 0 or cmp == "CO_Lesser" and count == 1 then
          return {}, Y.map({"item", Y.list({d2.itemName}), "count", 1, "none", true})
        end
        not_loadable("an item count condition")
      end
      if c == "CQuestActorCondition" then
        -- the player has (or has not) an item, asked the actor way (Border Troll: "has no paint yet")
        local d2 = p(q)
        local k = handle(d2.checkType)
        if or_(d2.actorTag, "") ~= "PLAYER" or not k or cls(k) ~= "CQCHasItem" or not T(p(k).item) then
          not_loadable("a condition on an actor")
        end
        local h = p(k)
        local cmp, count = or_(h.compareFunc, "CF_GreaterEqual"), int(or_(h.count, 1))
        if cmp == "CF_GreaterEqual" or cmp == "CF_Greater" then
          return {}, Y.map({"item", Y.list({h.item}), "count", math.max(1, count + (cmp == "CF_Greater" and 1 or 0))})
        end
        if cmp == "CF_Less" and count <= 1 or (cmp == "CF_Equal" or cmp == "CF_LessEqual") and count == 0 then
          return {}, Y.map({"item", Y.list({h.item}), "count", 1, "none", true})
        end
        not_loadable("an item count condition")
      end
      return {SI.fact_check(c, p(q))}, nil
    end

    -- AND: if a then (if b then yes else no) else no; OR: if a then yes else (if b then yes else no)
    local nested
    nested = function(checks, op, yes, no, from)
      from = from or 1
      local c = checks[from]
      local head = Y.map({"if", Y.map({"fact", c[1], "op", c[2], "value", c[3]})})
      if from == #checks then
        head["then"] = yes                      -- (one after the other: the map keeps the order)
        head["else"] = no
      elseif op == "LO_And" then
        head["then"] = Y.map({"lines", Y.list({nested(checks, op, yes, deepcopy(no), from + 1)})})
        head["else"] = no
      else
        head["then"] = yes
        head["else"] = Y.map({"lines", Y.list({nested(checks, op, deepcopy(yes), no, from + 1)})})
      end
      return head
    end

    -- the flow nodes from `i` on as long as the flow goes one way (sections without a choice, scripts); the first
    -- one that splits is the last
    local function linear(i)
      local out_, seen_ = {}, {}
      i = follow(i)
      while i and not seen_[i] do
        seen_[i] = true
        out_[#out_ + 1] = i
        local c = cls(i)
        if c == "CStorySceneSection" then
          local split = handle(p(i).choice) ~= nil
          if not split then
            for _, h in ipairs(list(p(i).sceneElements)) do
              local e = handle(h)
              if e and cls(e) == "CStorySceneChoice" then split = true break end
            end
          end
          if split then break end
        elseif c ~= "CStorySceneScript" then
          break
        end
        i = follow(handle(p(i).nextLinkElement))
      end
      return out_
    end

    local function in_list(xs, x)
      for _, y in ipairs(xs) do if y == x then return true end end
      return false
    end

    -- where the ways from `starts` meet again: the node most of them reach (the earliest), not one they go back to
    -- and not the join of a split around this one (`stop`). nil: they do not meet
    local function join_of(starts, stack, stop)
      local paths = {}
      for _, s in ipairs(starts) do if s then paths[#paths + 1] = linear(s) end end
      local seen_in = {}
      for _, path in ipairs(paths) do
        local once = {}
        for _, n in ipairs(path) do
          if not once[n] then
            once[n] = true
            seen_in[n] = (seen_in[n] or 0) + 1
          end
        end
      end
      local best_rank1, best_rank2, best
      for _, path in ipairs(paths) do
        for k0, n in ipairs(path) do
          local k = k0 - 1
          if not ((seen_in[n] or 0) < 2 or in_list(stack, n) or n == stop) then
            local r1, r2 = -seen_in[n], k
            if best == nil or r1 < best_rank1 or (r1 == best_rank1 and r2 < best_rank2) then
              best_rank1, best_rank2, best = r1, r2, n
            end
          end
        end
      end
      return best
    end

    -- an if's / random's way: its end ("on" / none: it goes on after the split)
    local function way_end(e, stack)
      if e == nil or e[1] == "on" then return nil end
      local r
      if e[1] == "back" and #stack > 0 and e[2] == stack[#stack] then r = "back"
      elseif e[1] == "out" then r = "out:" .. P.str(e[2])
      elseif e[1] == "end" then r = nil
      else r = "?" end
      if r == "?" then not_loadable("a way that leads back to an earlier choice") end
      return r
    end

    local active = {}
    local chain_, answers

    -- lines from `start` on: -> lines, end - end: {"out", name} | {"back", section} | {"on"} (at `stop`: where the
    -- ways of a split around them join) | nil when the lines end with a split. `stack`: the sections with a choice
    -- we are inside (a way back to one = back)
    local function chain(start, stack, stop)
      local key = tostring(follow(start)) .. "|" .. table.concat(stack, ",") .. "|" .. tostring(stop)
      if active[key] then not_loadable("a way that goes back round through a condition") end
      active[key] = true
      local ok, ls, e = pcall(chain_, start, stack, stop)
      active[key] = nil
      if not ok then error(ls, 0) end
      return ls, e
    end

    local function plus(stack, node)
      local s = {}
      for i, x in ipairs(stack) do s[i] = x end
      s[#s + 1] = node
      return s
    end

    chain_ = function(start, stack, stop)
      local ls, seen, node = Y.list({}), {}, follow(start)
      while true do
        if not node then return ls, {"end"} end         -- a section without a next one ends the scene
        if stop ~= nil and node == stop then return ls, {"on"} end
        local c = cls(node)
        if c == "CStorySceneOutput" then return ls, {"out", or_(p(node).name, "Output")} end
        if c == "CStorySceneScript" then
          ls[#ls + 1] = Y.map({"script", script(node)})
          node = follow(handle(p(node).nextLinkElement))
        elseif c == "CStorySceneRandomizer" then
          local starts = {}
          for _, h in ipairs(list(p(node).outputs)) do starts[#starts + 1] = handle(h) or false end
          local real = {}
          for _, s in ipairs(starts) do if s then real[#real + 1] = s end end
          local join = join_of(real, stack, stop)
          local ways = Y.list({})
          for _, h in ipairs(starts) do
            local sub, e = chain(h or nil, stack, join or stop)
            local br = Y.map({"lines", sub})
            local we = way_end(e, stack)
            if we then br["end"] = we end
            ways[#ways + 1] = br
          end
          ls[#ls + 1] = Y.map({"random", ways})
          if join == nil then return ls, nil end
          node = join                                  -- the ways meet again: the lines go on from there
        elseif c == "CStorySceneFlowCondition" then
          -- lines that depend on a fact: both ways, each with its own end
          local q = handle(p(node).questCondition)
          if not q then not_loadable("a condition on nothing") end
          local op, checks
          if cls(q) == "CQuestLogicOperationCondition" then
            op = or_(p(q).logicOperation, "LO_And")
            if op ~= "LO_And" and op ~= "LO_Or" then not_loadable("a condition " .. P.str(op)) end
            checks = {}
            for _, h in ipairs(list(p(q).conditions)) do
              if QR.is_ref(h, "export") then checks[#checks + 1] = SI.fact_check(cls(h[2]), p(h[2])) end
            end
          else
            op, checks = "LO_And", {SI.fact_check(cls(q), p(q))}
          end
          local element = {}
          local links = {handle(p(node).trueLink) or false, handle(p(node).falseLink) or false}
          local real = {}
          for _, s in ipairs(links) do if s then real[#real + 1] = s end end
          local join = join_of(real, stack, stop)
          for k, side in ipairs({"then", "else"}) do
            local sub, e = chain(links[k] or nil, stack, join or stop)
            local br = Y.map({"lines", sub})
            local we = way_end(e, stack)
            if we then br["end"] = we end
            element[side] = br
          end
          if #checks == 0 then error("IndexError: list index out of range", 0) end
          ls[#ls + 1] = nested(checks, op, element["then"], element["else"])
          if join == nil then return ls, nil end
          node = join
        else
          if c ~= "CStorySceneSection" then
            not_loadable("a " .. plain_replace(c, "CStoryScene", ""):lower() .. " in the flow")
          end
          if in_list(stack, node) then return ls, {"back", node} end
          if seen[node] then not_loadable("a way that jumps back to an earlier line") end
          seen[node] = true
          local choice
          for _, h in ipairs(list(p(node).sceneElements)) do
            local e = handle(h)
            if e then
              if not PLAIN[cls(e)] then
                not_loadable("a " .. plain_replace(cls(e), "CStoryScene", ""):lower() .. " in a section")
              end
              if cls(e) == "CStorySceneLine" then ls[#ls + 1] = line(e)
              elseif cls(e) == "CStorySceneChoice" then choice = e end
            end
          end
          choice = handle(p(node).choice) or choice      -- a section keeps its choice apart
          if choice then
            local starts = {}
            for _, h in ipairs(list(p(choice).choiceLines)) do
              local cl = handle(h)
              if cl then starts[#starts + 1] = handle(p(cl).nextLinkElement) or false end
            end
            local real = {}
            for _, s in ipairs(starts) do if s then real[#real + 1] = s end end
            local join = join_of(real, plus(stack, node), stop)
            ls[#ls + 1] = Y.map({"choice", answers(choice, plus(stack, node), join or stop)})
            if join == nil then return ls, nil end
            node = join                                -- the answers meet again: the talk goes on from there
          else
            node = follow(handle(p(node).nextLinkElement))
          end
        end
      end
    end

    local SKIP_EXTRA = {nextLinkElement = true, choiceLine = true, elementID = true, emphasisLine = true,
                        singleUseChoice = true, memo = true}
    answers = function(choice, stack, stop)
      local out_ = Y.list({})
      for _, h in ipairs(list(p(choice).choiceLines)) do
        local cl = handle(h)
        if cl then
          local d2 = p(cl)
          local extra = {}
          for _, k in ipairs(CE.all_keys(d2)) do
            local v = d2[k]
            if T(v) and not SKIP_EXTRA[k] then extra[k] = true end
          end
          local only_if
          local mapped = Y.map()
          local q = handle(d2.questCondition)
          if q then
            local checks, need = answer_condition(q)          -- shown only if: facts, items
            if #checks > 0 then
              if #checks == 1 then only_if = Y.list(checks[1])
              else
                only_if = Y.list({})
                for i, c in ipairs(checks) do only_if[i] = Y.list(c) end
              end
            end
            if T(need) then mapped.needs = need end
            extra.questCondition = nil
          end
          local act = handle(d2.action)
          if act and ICONS[cls(act)] then                    -- an icon on the answer (what it does comes after it)
            mapped.icon = ICONS[cls(act)]
            extra.action = nil
          elseif act and cls(act) == "CMonsterContractChoiceAction" then
            extra.action = nil                               -- (its haggling is the script after it)
          elseif act and cls(act) == "CAxiiStorySceneChoiceAction" then
            local lv = p(act).level
            mapped.axii = T(lv) and int(or_(lv, 1)) or true
            extra.action = nil
          elseif act and cls(act) == "CPayStorySceneChoiceAction" and T(p(act).money) then
            mapped.pay = int(p(act).money)
            extra.action = nil
          end
          if next(extra) then
            local what
            if act and extra.action then
              what = plain_replace(plain_replace(cls(act), "StorySceneChoiceAction", ""), "ChoiceAction", "")
              what = what:gsub("^C+", "")
            else
              local ks = {}
              for k in pairs(extra) do ks[#ks + 1] = k end
              table.sort(ks)
              what = table.concat(ks, ", ")
            end
            not_loadable("an answer with a " .. what:lower() .. " (a game action or condition)")
          end
          local _, text = text_of(d2.choiceLine)
          local lines, e = chain(handle(d2.nextLinkElement), stack, stop)
          local a = Y.map({"text", T(text) and text or "...", "lines", lines, "say", false})   -- Geralt's line follows
          if T(d2.emphasisLine) then a.emphasize = true end
          if T(d2.singleUseChoice) then a.once = true end
          if only_if then a.only_if = only_if end
          for _, k in ipairs(Y.keys(mapped)) do a[k] = mapped[k] end
          if e ~= nil then
            local r
            if e[1] == "back" and e[2] == stack[#stack] then r = "back"
            elseif e[1] == "on" then r = "on"
            elseif e[1] == "out" then r = "out:" .. P.str(e[2])
            elseif e[1] == "end" then r = "continue" end
            if r == nil then not_loadable("an answer that leads back to an earlier choice") end
            a["end"] = r
          elseif stop ~= nil then
            a["end"] = "on"                                  -- its lines end with a split whose ways may go on
          end
          out_[#out_ + 1] = a
        end
      end
      return out_
    end

    local ok, lines, e = pcall(chain, handle(d.nextLinkElement), {})
    local res
    if ok then
      res = {lines, (e and e[1] == "out") and e[2] or nil, nil}
    elseif getmetatable(lines) == NL then
      res = {nil, nil, lines.why}
    else
      error(lines, 0)
    end
    if out.by[name] == nil then out.order[#out.order + 1] = name end
    out.by[name] = res
  end
  return out
end

local TEXTS, VOICES
-- a swap's talks start as the game's own (where they load); swap.not_loaded: {input: why} for the others
function SI.load_into(swap, depot)
  local VO = require("conjunction.voices")
  if TEXTS == nil then TEXTS = require("conjunction.w3strings").read_strings("en", function() end) end
  if VOICES == nil and VO.ready() then VOICES = VO.open() end
  local f = CR.parse(depot:read(swap.scene))
  local main = {}
  for _, n in ipairs(Y.keys(swap.inputs)) do
    local st = swap.inputs[n]
    main[n] = P.get(P.or_(P.get(st, "talk"), Y.map()), "npc")
  end
  swap.not_loaded = Y.map()
  local got = SI.talks(f, function(n) return main[n] end, TEXTS, VOICES)
  for _, name in ipairs(got.order) do
    local r = got.by[name]
    local talk = P.get(P.or_(P.get(swap.inputs, name), Y.map()), "talk")
    if talk ~= nil then
      if r[1] == nil then
        swap.not_loaded[name] = r[3]
      else
        talk.dialogue = r[1]
        if T(r[2]) then talk["then"] = r[2] end
      end
    end
  end
  if Y.len(swap.not_loaded) == 0 then Y.remove(swap, "not_loaded") end
  return swap
end

return SI
