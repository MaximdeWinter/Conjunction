-- difflib.SequenceMatcher as CPython has it (no junk, autojunk off - what changes.py asks for): the same matching
-- blocks and opcodes for two sequences of elements compared by a key (a string per element).
--   local ops = DL.opcodes(a, b, key)    a, b: lists; key(e) -> string; ops: {{tag, i1, i2, j1, j2}, ...} (0-based as
--                                         Python's: a[i1:i2], b[j1:j2])
local DL = {}

local function longest(a, b, b2j, alo, ahi, blo, bhi)
  local besti, bestj, bestsize = alo, blo, 0
  local j2len = {}
  for i = alo, ahi - 1 do
    local newj2len = {}
    for _, j in ipairs(b2j[a[i + 1]] or {}) do
      if j >= blo then
        if j >= bhi then break end
        local k = (j2len[j - 1] or 0) + 1
        newj2len[j] = k
        if k > bestsize then besti, bestj, bestsize = i - k + 1, j - k + 1, k end
      end
    end
    j2len = newj2len
  end
  -- (no junk: the matches widened by equal elements on both ends)
  while besti > alo and bestj > blo and a[besti] == b[bestj] do
    besti, bestj, bestsize = besti - 1, bestj - 1, bestsize + 1
  end
  while besti + bestsize < ahi and bestj + bestsize < bhi and a[besti + bestsize + 1] == b[bestj + bestsize + 1] do
    bestsize = bestsize + 1
  end
  return besti, bestj, bestsize
end

function DL.matching_blocks(ka, kb)
  local b2j = {}
  for j, e in ipairs(kb) do
    local l = b2j[e]
    if not l then l = {} b2j[e] = l end
    l[#l + 1] = j - 1
  end
  local la, lb = #ka, #kb
  local queue = {{0, la, 0, lb}}
  local blocks = {}
  while #queue > 0 do
    local q = table.remove(queue)
    local alo, ahi, blo, bhi = q[1], q[2], q[3], q[4]
    local i, j, k = longest(ka, kb, b2j, alo, ahi, blo, bhi)
    if k > 0 then
      blocks[#blocks + 1] = {i, j, k}
      if alo < i and blo < j then queue[#queue + 1] = {alo, i, blo, j} end
      if i + k < ahi and j + k < bhi then queue[#queue + 1] = {i + k, ahi, j + k, bhi} end
    end
  end
  table.sort(blocks, function(x, y)
    if x[1] ~= y[1] then return x[1] < y[1] end
    if x[2] ~= y[2] then return x[2] < y[2] end
    return x[3] < y[3]
  end)
  local i1, j1, k1 = 0, 0, 0
  local out = {}
  for _, blk in ipairs(blocks) do
    local i2, j2, k2 = blk[1], blk[2], blk[3]
    if i1 + k1 == i2 and j1 + k1 == j2 then
      k1 = k1 + k2
    else
      if k1 > 0 then out[#out + 1] = {i1, j1, k1} end
      i1, j1, k1 = i2, j2, k2
    end
  end
  if k1 > 0 then out[#out + 1] = {i1, j1, k1} end
  out[#out + 1] = {la, lb, 0}
  return out
end

function DL.opcodes(a, b, key)
  local ka, kb = {}, {}
  for i, e in ipairs(a) do ka[i] = key and key(e) or e end
  for i, e in ipairs(b) do kb[i] = key and key(e) or e end
  local i, j = 0, 0
  local answer = {}
  for _, m in ipairs(DL.matching_blocks(ka, kb)) do
    local ai, bj, size = m[1], m[2], m[3]
    local tag = ""
    if i < ai and j < bj then tag = "replace"
    elseif i < ai then tag = "delete"
    elseif j < bj then tag = "insert" end
    if tag ~= "" then answer[#answer + 1] = {tag, i, ai, j, bj} end
    i, j = ai + size, bj + size
    if size > 0 then answer[#answer + 1] = {"equal", ai, i, bj, j} end
  end
  return answer
end

return DL
