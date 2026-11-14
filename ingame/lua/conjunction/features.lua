-- Experimental features (features.py): what changes the game's own files - the terrain brush, editing the game's
-- quests - and Edit Vanilla Objects. Off until switched on in Settings > General > Experimental; the release leaves
-- the switch out (IN_RELEASE).
--   if F.experimental() then ... end
local F = {}
F.KEY = "general.experimental"
F.IN_RELEASE = false        -- the first release: the switch is not offered, everything of it off
F.WARNING = "Unstable and hardly tested. Turns on:\n" ..
            "- Terrain editing\n" ..
            "- Editing the game's quests in the quest graph\n" ..
            "- Starting a quest inside a game quest\n" ..
            "- Replacing a game scene or cutscene\n" ..
            "- Edit Vanilla Objects: moving, turning and removing the game's own objects"

-- the release build (the app: conjunction.exe; the mod: CJ_RELEASE=1 until its release marks itself)
function F.released() return os.getenv("CJ_RELEASE") == "1" end
-- the switch shows in Settings
function F.offered() return F.IN_RELEASE or not F.released() end

-- experimental features on (CJ_EXPERIMENTAL=1 for tests)
function F.experimental()
  local e = os.getenv("CJ_EXPERIMENTAL")
  if e == "1" or e == "0" then return e == "1" end
  if not F.offered() then return false end
  return not not require("conjunction.settings").value(F.KEY, false)
end

-- the scenes: the SCENE block, a talk's Timeline, the scene workshop. Not in the first release (12.11.: a scene
-- has to be built before its timeline opens; it comes later, everything of it live); CJ_SCENES=1 to work on them
F.SCENES = false
function F.scenes() return F.SCENES or os.getenv("CJ_SCENES") == "1" end

-- an experimental feature asked for: an error unless they are on (features.Off)
function F.require(what)
  if not F.experimental() then
    error(what .. " is an experimental feature (Settings > General > Experimental)", 0)
  end
end

return F
