-- Conjunction's folders (paths.py): Documents\Conjunction.
local P = {}
local function env(k) return os.getenv(k) end
-- Windows' own Documents, also when it was moved (OneDrive): TW3SE asks Windows for it (14.11.: the user profile's
-- Documents missed the game's saves on a PC whose Documents is in OneDrive)
P.DOCUMENTS = (rawget(_G, "w3") and w3.fs and w3.fs.folder and w3.fs.folder("documents")) or
              ((env("USERPROFILE") or ((env("HOMEDRIVE") or "") .. (env("HOMEPATH") or ""))) .. "\\Documents")
P.HOME = env("CJ_HOME") or (P.DOCUMENTS .. "\\Conjunction")
P.PROJECTS = P.HOME .. "\\projects"
P.QUESTS = P.HOME .. "\\quests"
P.EXPORTS = P.HOME .. "\\exports"
P.BUG_REPORTS = P.HOME .. "\\bug-reports"
P.PLUGINS = P.HOME .. "\\plugins"
P.TOOLS = P.HOME .. "\\tools"
P.SCREENSHOTS = P.HOME .. "\\screenshots"
P.IDENTITY = P.HOME .. "\\identity"
P.DATA = P.HOME .. "\\data"

-- the mod's own folder (this file's: <game>\bin\x64_dx12\tw3se\mods\conjunction, or ingame\lua\conjunction in the
-- repository - then REPO is the repository, where the app keeps what the mod's copy brings: mod\runtime, packs)
P.MOD_ROOT = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("/", "\\"):gsub("\\paths%.lua$", ""))
do
  local repo = P.MOD_ROOT .. "\\..\\..\\.."
  if rawget(_G, "w3") and w3.fs and w3.fs.exists(repo .. "\\conjunction\\__init__.py") then P.REPO = repo end
end
-- the scripts every quest calls (setup.RUNTIME_SCRIPTS: the repository's mod\runtime\scripts; deploy_mod.py puts a
-- copy in the mod's runtime\scripts)
P.RUNTIME_SCRIPTS = P.REPO and (P.REPO .. "\\mod\\runtime\\scripts") or (P.MOD_ROOT .. "\\runtime\\scripts")
-- the app's sounds (conjunction\sounds: the screenshot's shutter); deploy_mod.py puts a copy in the mod's sounds
P.SOUNDS = P.REPO and (P.REPO .. "\\conjunction\\sounds") or (P.MOD_ROOT .. "\\sounds")

-- os.path.join for Windows paths (an absolute part starts again)
function P.join(...)
  local out = ""
  for _, part in ipairs({...}) do
    if part:match("^%a:") or part:match("^[\\/]") then out = part
    elseif out == "" or out:match("[\\/]$") then out = out .. part
    else out = out .. "\\" .. part end
  end
  return out
end
function P.basename(p) return p:match("([^\\/]*)$") end
function P.dirname(p) return p:match("^(.*)[\\/][^\\/]*$") or "" end
-- os.path.splitext
function P.splitext(p)
  local base = P.basename(p)
  local dot = base:match("^.*()%.")
  if not dot or base:sub(1, dot - 1):match("^%.*$") then return p, "" end
  local cut = #p - #base + dot - 1
  return p:sub(1, cut), p:sub(cut + 1)
end
return P
