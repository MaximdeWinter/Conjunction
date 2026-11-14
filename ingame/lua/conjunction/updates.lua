-- What Conjunction changed in the game by itself (the runtime), said once at the editor's start (updates.py). The
-- question to Nexus Mods for newer versions went online, so it is not in this release (14.11.: Nexus forbids files
-- that go online unless the mod needs it - an update check does not count).
--   UP.note(text)   UP.take_notes()   UP.show(ed, notes)   UP.at_start(ed)
local UP = {}
UP.SUITE_PAGE = "https://www.nexusmods.com/witcher3/mods/15718"     -- (packaging.SUITE_PAGE)
local notes = {}

function UP.note(text)
  for _, t in ipairs(notes) do if t == text then return end end
  notes[#notes + 1] = text
end
function UP.take_notes()
  local out = notes
  notes = {}
  return out
end

-- the window that says it: what was updated in the game, OK
function UP.show(ed, said)
  local DW = require("conjunction.ui.dialog_window")
  local DLG = require("conjunction.ui.dialogs")
  return DW.open(ed.panel or ed, "updates", "Updates", DLG.Updates.new(nil, said or {}))
end

-- the editor's start (__main__: after the logo)
function UP.at_start(ed)
  local n = UP.take_notes()
  if #n > 0 then UP.show(ed, n) end
end

return UP
