-- The parameters of quest script blocks, as the remaster reads them (script_params.py). The game's quest files keep a
-- script block's parameters twice: as the property `parameters` (QuestScriptParam {name, value : CVariant}) and again
-- after the block's properties; radish writes only the second (the remaster then calls the function with every
-- parameter empty), and the cook drops them for the mod's own functions.
--   SP.apply(folder) -> blocks given their parameters     SP.restore(uncooked, cooked) -> blocks given them back
local CR = require("conjunction.cr2w")
local CE = require("conjunction.cr2w_edit")
local SP = {}
local pack = string.pack

-- {name index, type index, value bytes} of what follows the properties' end marker (end: 0-based)
local function tail_params(chunk, i)
  local out = {}
  while i + 8 <= #chunk do
    local nm, tp, size = string.unpack("<I2I2I4", chunk, i + 1)
    if nm == 0 then break end
    out[#out + 1] = {nm, tp, chunk:sub(i + 9, i + 4 + size)}
    i = i + 4 + size
  end
  return out
end

-- the `parameters` property: count, then per element a 0 byte, name (CName), value (CVariant), name 0
local function parameters(f, params)
  local body = {pack("<I4", #params)}
  for _, p in ipairs(params) do
    local variant = pack("<I2I4", p[2], 4 + #p[3]) .. p[3]
    body[#body + 1] = "\0" .. CE.prop(f, "name", "CName", pack("<I2", p[1])) .. CE.prop(f, "value", "CVariant", variant) ..
                      "\0\0"
  end
  local b = table.concat(body)
  CE.idx(f, "QuestScriptParam")
  return CE.prop(f, "parameters", "array:2,0,QuestScriptParam", b)
end

local function has_parameters(props)
  for _, p in ipairs(props) do if p[1] == "parameters" then return true end end
  return false
end
local function after_function_name(props, default)
  for _, p in ipairs(props) do if p[1] == "functionName" then return p[3] + p[4] end end
  return default
end

-- every CQuestScriptBlock of an open file without `parameters` gets them -> how many
function SP.fix(f)
  local n = 0
  for _, e in ipairs(f.exports) do
    if e[1] == "CQuestScriptBlock" then
      local chunk = e[5]
      local props = f:props(chunk)
      if #props > 0 and not has_parameters(props) then
        local en = props[#props][3] + props[#props][4]
        local params = tail_params(chunk, en + 2)
        if #params > 0 then
          local at = after_function_name(props, en)
          e[5] = chunk:sub(1, at) .. parameters(f, params) .. chunk:sub(at + 1)
          n = n + 1
        end
      end
    end
  end
  return n
end

local function guid_of(f, chunk)
  for _, p in ipairs(f:props(chunk)) do
    if p[1] == "guid" then return chunk:sub(p[3] + 1, p[3] + p[4]) end
  end
  return nil
end

-- a block's parameters as {name, type, value} with names as text (a CName or enum value too)
local function portable(f, chunk)
  local props = f:props(chunk)
  local out = {}
  for _, p in ipairs(tail_params(chunk, props[#props][3] + props[#props][4] + 2)) do
    local typ, value = f.names[p[2] + 1], p[3]
    if typ == "CName" or (typ:sub(1, 1) == "E" and #value == 2) then
      value = f.names[string.unpack("<I2", value) + 1]
    elseif typ:find("CName", 1, true) then
      error(require("conjunction.questgen").ValueError("a script parameter of type " .. typ ..
                                                        " cannot be carried over yet"), 0)
    else
      value = {bytes = value}
    end
    out[#out + 1] = {f.names[p[1] + 1], typ, value}
  end
  return out
end

-- the quest graph files under a folder, as sorted(glob(*.w2quest) + glob(*.w2phase))
local function quest_files(folder)
  local quests, phases = {}, {}
  local function walk(dir)
    for _, e in ipairs(w3.fs.list(dir) or {}) do
      local p = dir .. "\\" .. e.name
      if e.dir then walk(p)
      elseif e.name:sub(-8) == ".w2quest" then quests[#quests + 1] = p
      elseif e.name:sub(-8) == ".w2phase" then phases[#phases + 1] = p end
    end
  end
  walk(folder)
  for _, p in ipairs(phases) do quests[#quests + 1] = p end
  table.sort(quests)
  return quests
end
SP.quest_files = quest_files

-- once cooked, each script block without parameters gets those of its uncooked block (the same guid) -> how many
function SP.restore(uncooked, cooked)
  local done = 0
  for _, fn in ipairs(quest_files(cooked)) do
    local src = uncooked .. fn:sub(#cooked + 1)
    if w3.fs.exists(src) then
      local u = CR.parse(assert(w3.fs.read(src)))
      local wanted, any = {}, false
      for _, e in ipairs(u.exports) do
        if e[1] == "CQuestScriptBlock" then
          local params = portable(u, e[5])
          if #params > 0 then
            local g = guid_of(u, e[5])
            if g ~= nil then wanted[g] = params any = true end
          end
        end
      end
      if any then
        local f = CR.parse(assert(w3.fs.read(fn)))
        local n = 0
        for _, e in ipairs(f.exports) do
          if e[1] == "CQuestScriptBlock" then
            local chunk = e[5]
            local props = f:props(chunk)
            local g = guid_of(f, chunk)
            local params = g ~= nil and wanted[g] or nil
            if params and not has_parameters(props) then
              local here = {}
              for _, p in ipairs(params) do
                local value = p[3]
                if type(value) == "string" then value = pack("<I2", f:add_name(value)) else value = value.bytes end
                here[#here + 1] = {f:add_name(p[1]), f:add_name(p[2]), value}
              end
              local at = after_function_name(props, props[#props][3] + props[#props][4])
              e[5] = chunk:sub(1, at) .. parameters(f, here) .. chunk:sub(at + 1)
              n = n + 1
            end
          end
        end
        if n > 0 then
          local out = f:save()
          if CR.parse(out):save() ~= out then
            error("RuntimeError: " .. fn:match("[^\\]*$") .. " does not read back after its script parameters", 0)
          end
          assert(w3.fs.write(fn, out))
          done = done + n
        end
      end
    end
  end
  return done
end

function SP.apply(folder)
  local done = 0
  for _, fn in ipairs(quest_files(folder)) do
    local data = assert(w3.fs.read(fn))
    if data:find("CQuestScriptBlock", 1, true) then
      local f = CR.parse(data)
      local n = SP.fix(f)
      if n > 0 then
        assert(w3.fs.write(fn, f:save()))
        done = done + n
      end
    end
  end
  return done
end

return SP
