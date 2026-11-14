-- A public timestamp's proof (timestamp.py): what Check origin reads in a quest file that has one (history.ots, a
-- standard OpenTimestamps proof). Making one went online, so it is not in this release (14.11.: Nexus forbids files
-- that go online unless the mod needs it).
--   TS.digest_of(ots) -> the sha256 the proof is for, or nil
local TS = {}
TS.MAGIC = "\0OpenTimestamps\0\0Proof\0\xbf\x89\xe2\xe8\x84\xe8\x92\x94"
TS.SHA256 = "\x08"

function TS.digest_of(ots)
  local m = #TS.MAGIC
  if ots:sub(1, m) ~= TS.MAGIC or ots:sub(m + 2, m + 2) ~= TS.SHA256 then return nil end
  return ots:sub(m + 3, m + 34)
end

return TS
