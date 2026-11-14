-- fact_refs.py: facts followed through a quest file - which blocks set a fact, wait for it, check it, remove it, in
-- every graph of the file, with the phases one steps into to get there (the card of a fact block lists them).
--   FR.facts_of(tree, n) -> {name = true}   the facts block n sets or reads (its conditions too)
--   FR.uses(qf, names) -> {{block, guid, trail, where, what, title, name}}
local V = require("conjunction.vanilla_graph")
local TR = require("conjunction.cr2w_tree")
local FR = {}

FR.FACT_CONDS = {CQuestFactsDBCondition = true, CQuestFactsDBExCondition = true}
FR.SETTERS = {CQuestFactsDBChangingBlock = "factID"}
FR.FUNCTIONS = {AddFact = "factName", RemoveFactQuest = "factId", AddFactQuest = "factName"}

-- condition objects under block / condition n (and / or followed)
local function conds(tree, n, seen)
  seen = seen or {}
  local o = tree:obj(n)
  local out = {}
  for _, key in ipairs({"conditions", "questCondition"}) do
    local v = o:get(key)
    local list = V.is_list(v) and v or {v}
    for _, c in ipairs(list) do
      if V.obj_ref(c) and not seen[V.ival(c)] then
        c = V.ival(c)
        seen[c] = true
        out[#out + 1] = c
        for _, x in ipairs(conds(tree, c, seen)) do out[#out + 1] = x end
      end
    end
  end
  return out
end

function FR.facts_of(tree, n)
  local o = tree:obj(n)
  local names = {}
  local key = FR.SETTERS[o.cls]
  if key and V.truth(o:get(key)) then names[V.str(o:get(key))] = true end
  if o.cls == "CQuestScriptBlock" then
    local fn = V.str(V.or_(o:get("functionName"), ""))
    for _, p in ipairs(V.or_(o:get("parameters"), {})) do
      if FR.FUNCTIONS[fn] and V.sget(p, "name") == FR.FUNCTIONS[fn] then
        local v = V.sget(p, "value")
        if TR.is(v, TR.VARIANT) then v = v.value end   -- (getattr(v, "value", v): a false one too)
        names[V.str(v)] = true
      end
    end
  end
  for _, c in ipairs(conds(tree, n)) do
    local co = tree:obj(c)
    if FR.FACT_CONDS[co.cls] then
      for _, k in ipairs({"factId", "factId1", "factId2"}) do
        if V.truth(co:get(k)) then names[V.str(co:get(k))] = true end
      end
    end
  end
  names[""] = nil
  return names
end

function FR.uses(qf, names)
  local BX = require("conjunction.block_examples")
  local BL = require("conjunction.blocks")
  local t = qf.tree
  local out = {}
  for gn, go in ipairs(t.objects) do
    if go.cls == "CQuestGraph" then
      local tr
      for _, b in ipairs(go:get("graphBlocks") or {}) do
        if V.obj_ref(b) then
          b = V.ival(b)
          local hit = false
          for name in pairs(FR.facts_of(t, b)) do if names[name] then hit = true break end end
          if hit then
            local o = t:obj(b)
            tr = tr or BX.trail(t, gn)
            local fn = V.str(o:get("functionName"))
            local what = (FR.SETTERS[o.cls] or (o.cls == "CQuestScriptBlock" and (fn == "AddFact" or
                          fn == "AddFactQuest"))) and "sets" or (o.cls == "CQuestScriptBlock" and "removes" or
                          (o.cls == "CQuestPauseConditionBlock" and "waits for" or "checks"))
            local names_in = {}
            for _, g in ipairs(tr) do
              local k
              for i, x in ipairs(t.objects) do
                if x.props and BX.guid(t, i) == g then k = i break end
              end
              names_in[#names_in + 1] = k and V.str(V.or_(t:obj(k):get("name"), "phase")) or "phase"
            end
            out[#out + 1] = {block = b, guid = BX.guid(t, b), trail = tr, where = table.concat(names_in, " > "),
                             what = what, title = BL.kind_of(t, b).label, name = V.str(V.or_(o:get("name"), ""))}
          end
        end
      end
    end
  end
  return out
end

return FR
