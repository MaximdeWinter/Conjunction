-- Bug reports (bugreport.py): one file on the disk, Documents\Conjunction\bug-reports\bug-report_<time>.zip, to keep or
-- send - nothing is sent. Inside: what the user wrote and the screenshots (drawn on), Conjunction's session log (this
-- run and the last) and its errors, the editor's state, the game's own view (where, the tracked quest - asked over
-- the script link), the lines the game's scripts sent lately, the end of TW3SE's log, the project (quest, places),
-- the config without its secrets, the installed mods and DLCs, a fingerprint of Conjunction's files. Every text
-- anonymous (the user's and the PC's names, profiles, e-mail addresses, Steam ids, a project's author and marks).
--   BR.start_session_log()                      the mod's output into data\logs\session.log (the run before kept)
--   BR.collect(ed, text, shots, log, then_)     shots: {{name, png path}} -> then_(path) or then_(nil, error)
--   BR.nexus_text(path)   BR.anonymize(text)   BR.redacted(cfg)   BR.show(path)
local J = require("conjunction.json")
local Y = require("conjunction.yaml")
local R = require("conjunction.pyre")
local CFG = require("conjunction.config")
local PATHS = require("conjunction.paths")
local FS = require("conjunction.fsutil")
local PYS = require("conjunction.pystr")
local H = require("conjunction.hashlib")
local BR = {}

BR.LOGS = PATHS.DATA .. "\\logs"
BR.REPORTS = PATHS.BUG_REPORTS
BR.SECRET = {"webhook", "token", "secret", "password", "api_key", "apikey"}
BR.SCRIPT_LOG_LINES = 4000
BR.errors = {}                                   -- (errors of this run, the last 50)

local function iso(t) return os.date("%Y-%m-%dT%H:%M:%S", t) end

-- --- the session log: print also into logs\session.log
function BR.start_session_log()
  w3.fs.mkdir(BR.LOGS)
  local cur, prev = BR.LOGS .. "\\session.log", BR.LOGS .. "\\session.prev.log"
  if w3.fs.exists(cur) then
    if w3.fs.exists(prev) then w3.fs.remove(prev) end
    w3.fs.rename(cur, prev)
  end
  local f = io.open(cur, "wb")
  if not f then return end
  f:write(string.format("[conjunction] session %s\r\n", iso()))
  f:flush()
  local old = print
  print = function(...)                           -- luacheck: ignore (the mod's own output, as _Tee)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    pcall(function() f:write(((table.concat(parts, "\t") .. "\n"):gsub("\n", "\r\n"))) f:flush() end)   -- (gsub's
    -- count not written too)
    old(...)
  end
  BR.session_file = f
end
-- an error of this run (init.lua's guards call it)
function BR.error(text)
  BR.errors[#BR.errors + 1] = Y.map({"time", iso(), "error", tostring(text)})
  while #BR.errors > 50 do table.remove(BR.errors, 1) end
end

-- --- what names the person or the PC (bugreport._private_words): longest first
local function private_words()
  local out, seen = {}, {}
  local function add(w, stand)
    local key = w .. "\0" .. stand
    if w ~= "" and not seen[key] then seen[key] = true out[#out + 1] = {w, stand} end
  end
  local home = os.getenv("USERPROFILE") or ""
  if home ~= "" then
    add(home, "<home>")
    add((home:gsub("\\", "/")), "<home>")
    add((home:gsub("\\", "\\\\")), "<home>")
  end
  for _, ns in ipairs({{os.getenv("USERNAME") or "", "<user>"}, {os.getenv("COMPUTERNAME") or "", "<pc>"},
                       {os.getenv("USERDOMAIN") or "", "<pc>"}}) do
    if #ns[1] >= 3 then add(ns[1], ns[2]) end
  end
  local ok, ps = pcall(require("conjunction.identity").profiles)
  for _, p in ipairs(ok and ps or {}) do
    for _, x in ipairs({p.name, p.id, p.public}) do if x and #x >= 3 then add(x, "<profile>") end end
  end
  table.sort(out, function(a, b) return utf8.len(a[1]) > utf8.len(b[1]) end)
  local pats = {}
  for i, w in ipairs(out) do pats[i] = {R.compile(R.escape(w[1]), R.I), w[2]} end
  return pats
end

function BR.anonymize(text, words)
  text = R.sub([[[\w.+-]+@[\w-]+\.[\w.-]+]], "<e-mail>", text)
  text = R.sub([[(userdata[\\/]+)\d+]], [[\1<id>]], text, 0, R.I)
  text = R.sub([[(?m)^(\s*author:\s*).+$]], [[\1<author>]], text)
  for _, w in ipairs(words or private_words()) do text = w[1]:sub(w[2], text) end
  text = R.sub([[(?m)^(\s*(?:key|seed|uid):\s*)[0-9a-fA-F]{8,}\s*$]], [[\1<left out>]], text)
  return text
end

-- the config without its secrets: a value whose key names a webhook, token, secret or password
local function truthy(v) return not (v == nil or v == false or v == Y.null or v == 0 or v == "" or
                                     (type(v) == "table" and next(v) == nil)) end
function BR.redacted(v)
  if Y.is_map(v) or (type(v) == "table" and not Y.is_list(v) and next(v) ~= nil and v[1] == nil) then
    local out = Y.map({})
    for _, k in ipairs(Y.keys(v)) do
      local secret = false
      local lk = PYS.lower(tostring(k))
      for _, s in ipairs(BR.SECRET) do if lk:find(s, 1, true) then secret = true end end
      if secret and truthy(v[k]) then out[k] = "(left out)" else out[k] = BR.redacted(v[k]) end
    end
    return out
  end
  if type(v) == "table" then
    local out = Y.list({})
    for i, x in ipairs(v) do out[i] = BR.redacted(x) end
    return out
  end
  return v
end

-- --- the parts
local function fingerprint()
  local files = Y.map({})
  local root = PATHS.MOD_ROOT .. "\\.."
  local list = {}
  for _, f in ipairs(FS.walk(PATHS.MOD_ROOT)) do
    if f.name:sub(-4) == ".lua" then list[#list + 1] = {"conjunction\\" .. f.rel, f.path} end
  end
  for _, f in ipairs(FS.walk(PATHS.RUNTIME_SCRIPTS)) do
    if f.name:sub(-3) == ".ws" then list[#list + 1] = {"mod\\runtime\\scripts\\" .. f.rel, f.path} end
  end
  table.sort(list, function(a, b) return a[1] < b[1] end)
  for _, e in ipairs(list) do files[e[1]] = H.sha1(w3.fs.read(e[2]) or ""):sub(1, 10) end
  local _ = root
  local total = H.sha1(J.encode(files, {sort_keys = true})):sub(1, 12)
  return total, files
end

BR.fingerprint = fingerprint            -- (the export's manifest: suite)

local function game_info(cfg)
  local game = cfg.game or ""
  local out = Y.map({"path", game})
  local exe = PATHS.join(game, "bin", "x64_dx12", "witcher3.exe")
  if not w3.fs.exists(exe) then exe = PATHS.join(game, "bin", "x64", "witcher3.exe") end
  if w3.fs.exists(exe) then
    out.exe = Y.map({"path", exe, "size", math.tointeger(w3.fs.size(exe)),
                     "modified", iso(math.floor(w3.fs.mtime(exe)))})
  end
  for _, sub in ipairs({"mods", "dlc"}) do
    local names = Y.list({})
    for _, e in ipairs(w3.fs.list(PATHS.join(game, sub)) or {}) do names[#names + 1] = e.name end
    table.sort(names)
    out[sub] = names
  end
  out.running = true                              -- (the mod runs inside it)
  return out
end

local function plain(v) return type(v) == "string" or type(v) == "number" or type(v) == "boolean" or v == nil end
local function editor_state(ed)
  if ed == nil then return Y.map({}) end
  local s = Y.map({})
  for _, k in ipairs({"place", "world", "editing", "mode", "template", "placing", "selected", "seeing_through",
                      "variants"}) do
    local v = ed[k]
    if plain(v) or Y.is_list(v) then s[k] = v == nil and Y.null or v else s[k] = tostring(v) end
  end
  pcall(function()
    s.project = ed.project.path
    local req = Y.map({})
    for _, k in ipairs(type(ed.request) == "table" and Y.keys(ed.request) or {}) do
      local v = ed.request[k]
      if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then req[k] = v end
    end
    s.request = req
    local p = ed.panel
    if p ~= nil then
      local wins = Y.list({})
      for _, w in ipairs(p.win_order or {}) do if w.shown then wins[#wins + 1] = w.title or w.key end end
      local r = p.rect or {x = 0, y = 0, w = 0, h = 0}
      s.panel = Y.map({"visible", p.isVisible and p:isVisible() or false,
                       "tab", p.tab_name and p:tab_name() or tostring(p.tab_index and p:tab_index() or ""),
                       "geometry", Y.list({r.x, r.y, r.w, r.h}), "windows", wins})
      s.live = ed.live or Y.map({})
    end
  end)
  return s
end

local function tail(path, n)
  local s = w3.fs.read(path)
  if not s then return "(not readable: " .. path .. ")" end
  s = s:gsub("\r\n", "\n")
  local lines = {}
  for line in (s .. (s:sub(-1) == "\n" and "" or "\n")):gmatch("(.-\n)") do lines[#lines + 1] = line end
  local from = math.max(1, #lines - n + 1)
  return table.concat(lines, "", from)
end

-- the report's zip -> then_(path) (the game asked first: its answer comes within 1.5 s)
function BR.collect(ed, text, shots, build_log, then_, after)
  local sys = ed and ed.sys
  local mark = w3.link and w3.link.mark() or 0
  if sys and sys.exec then
    sys.exec("cj_where()")
    sys.exec("cj_quest()")
  end
  local function finish()
    local ok, path = pcall(BR._write, ed, text, shots or {}, build_log or "", mark)
    if ok then then_(path) else then_(nil, path) end
  end
  if after then after(1500, finish) else finish() end
end

function BR._write(ed, text, shots, build_log, mark)
  local cfg = CFG.load()
  local now = os.time()
  local fp, files = fingerprint()
  local game_now = Y.list({})
  if w3.link then
    local _, lines = w3.link.since(mark)
    for _, l in ipairs(lines or {}) do game_now[#game_now + 1] = l end
  else
    game_now[1] = "no answer: no script link"
  end
  local version = require("conjunction.provenance").VERSION
  local report = Y.map({"text", text, "time", iso(now), "suite", fp, "version", version,
                        "game", game_info(cfg), "editor", editor_state(ed), "game_now", game_now,
                        "errors", Y.list(BR.errors)})
  w3.fs.mkdir(BR.REPORTS)
  local path = BR.REPORTS .. "\\" .. os.date("bug-report_%Y-%m-%d_%H-%M-%S.zip", now)
  local words = private_words()
  local tmp = (os.getenv("TEMP") or ".") .. "\\cj_bugreport"
  FS.rmtree(tmp)
  w3.fs.mkdir(tmp)
  local plan, k = {}, 0
  local function put(name, data)
    k = k + 1
    local f = tmp .. "\\" .. k .. ".txt"
    assert(w3.fs.write(f, BR.anonymize(data, words)))
    plan[#plan + 1] = name .. "\t" .. f
  end
  local function put_file(p, name)
    local s = w3.fs.read(p)
    if s then put(name, (s:gsub("\r\n", "\n"))) end
  end
  put("report.json", J.encode(report, {indent = 1, ensure_ascii = false}))
  put("what_happened.txt", text or "")
  put("suite_files.json", J.encode(files, {indent = 0}))
  put("config.json", J.encode(BR.redacted(cfg), {indent = 1, ensure_ascii = false}))
  for _, name in ipairs({"session.log", "session.prev.log"}) do
    local p = BR.LOGS .. "\\" .. name
    if w3.fs.exists(p) then put_file(p, "logs/" .. name) end
  end
  local lines = {}
  if w3.link then
    local _, all = w3.link.since(0)
    lines = all or {}
  end
  local from = math.max(1, #lines - BR.SCRIPT_LOG_LINES + 1)
  put("logs/game_lines.txt", table.concat(lines, "\n", from))
  put("logs/tw3se_tail.txt", tail(PATHS.join(cfg.game or "", "bin", "x64_dx12", "tw3se", "tw3se.log"),
                                  BR.SCRIPT_LOG_LINES))
  if build_log ~= "" then put("logs/build.txt", build_log) end
  local proj = ed and ed.project and ed.project.path
  if proj and w3.fs.isdir(proj) then
    local function ymls(dir)
      local out = {}
      for _, e in ipairs(w3.fs.list(dir) or {}) do
        if not e.dir and e.name:sub(-4) == ".yml" then out[#out + 1] = e.name end
      end
      table.sort(out)
      return out
    end
    for _, n in ipairs(ymls(proj)) do put_file(proj .. "\\" .. n, "project/" .. n) end
    for _, n in ipairs(ymls(proj .. "\\places")) do put_file(proj .. "\\places\\" .. n, "project/places/" .. n) end
    for _, e in ipairs(w3.fs.list(proj .. "\\build") or {}) do
      if not e.dir and e.name:sub(-4) == ".log" then
        put_file(proj .. "\\build\\" .. e.name, "project/build/" .. e.name)
      end
    end
  end
  for i, s in ipairs(shots) do
    plan[#plan + 1] = string.format("screenshots/%02d_%s.png", i, s[1]) .. "\t" .. s[2]
  end
  local pf = tmp .. "\\plan.txt"
  assert(w3.fs.write(pf, table.concat(plan, "\n") .. "\n"))
  local ok, r = pcall(w3.plugin.cj_zip_write, path, pf)
  if not ok then error(r, 0) end
  return path
end

-- Python's repr of a str and of a dict of them (str(e) of an error entry)
local function py_repr(v)
  if type(v) == "string" then
    local q = (v:find("'", 1, true) and not v:find('"', 1, true)) and '"' or "'"
    local out = {q}
    for _, c in utf8.codes(v) do
      local ch = utf8.char(c)
      if ch == "\\" then out[#out + 1] = "\\\\"
      elseif ch == q then out[#out + 1] = "\\" .. q
      elseif c == 10 then out[#out + 1] = "\\n"
      elseif c == 13 then out[#out + 1] = "\\r"
      elseif c == 9 then out[#out + 1] = "\\t"
      elseif c < 32 or c == 127 then out[#out + 1] = string.format("\\x%02x", c)
      else out[#out + 1] = ch end
    end
    out[#out + 1] = q
    return table.concat(out)
  end
  if type(v) == "table" then
    local parts = {}
    for _, k in ipairs(Y.keys(v)) do parts[#parts + 1] = py_repr(k) .. ": " .. py_repr(v[k]) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  if v == true then return "True" elseif v == false then return "False" end
  if v == nil or v == Y.null then return "None" end
  return require("conjunction.pynum").str(v)
end

-- a short report to paste into a Nexus page's Bugs tab (it takes text only), from the saved anonymous one
function BR.nexus_text(path, limit)
  limit = limit or 4800
  local LIB = require("conjunction.library")
  local names = {}
  for _, n in ipairs(LIB.zip_names(path)) do names[n] = true end
  local tmp = (os.getenv("TEMP") or ".") .. "\\cj_bugreport_read"
  w3.fs.mkdir(tmp)
  local function read(name)
    if not names[name] then return nil end
    local out = tmp .. "\\" .. name:gsub("[/\\]", "_")
    LIB.zip_extract(path, {{name, out}})
    return w3.fs.read(out)
  end
  local rep = read("report.json")
  rep = rep and J.decode(rep) or {}
  local log = read("logs/session.log") or ""
  local build = read("logs/build.txt") or ""
  local game = type(rep.game) == "table" and rep.game or {}
  local mods = type(game.mods) == "table" and table.concat(game.mods, ", ") or ""
  local lines = {string.format("Conjunction %s, %s", tostring(rep.version or "?"),
                               (tostring(rep.time or "")):sub(1, 16):gsub("T", " ")),
                 string.format("Game running: %s. Mods: %s", py_repr(game.running), mods ~= "" and mods or "none"),
                 "", "What happened:", PYS.strip(truthy(rep.text) and rep.text or "(nothing written)"), ""}
  local errs = {}
  for _, e in ipairs(type(rep.errors) == "table" and rep.errors or {}) do errs[#errs + 1] = PYS.strip(py_repr(e)) end
  if #errs > 0 then
    lines[#lines + 1] = "Errors:"
    for i = math.max(1, #errs - 2), #errs do
      local cps = PYS.cps(errs[i])
      lines[#lines + 1] = PYS.from_cps(cps, math.max(1, #cps - 699), #cps)
    end
    lines[#lines + 1] = ""
  end
  local all = {}
  for l in (log:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do all[#all + 1] = l end
  if all[#all] == "" then all[#all] = nil end
  local flagged = {}
  for _, l in ipairs(all) do
    local ll = PYS.lower(l)
    for _, m in ipairs({"error", "failed", "traceback", "exception", "crash"}) do
      if ll:find(m, 1, true) then flagged[#flagged + 1] = l break end
    end
  end
  if #flagged > 0 then
    lines[#lines + 1] = "Log, the lines with errors:"
    for i = math.max(1, #flagged - 14), #flagged do lines[#lines + 1] = flagged[i] end
    lines[#lines + 1] = ""
  end
  if build ~= "" then
    lines[#lines + 1] = "Build, the last lines:"
    local bl = {}
    for l in (build:match("^%s*(.-)%s*$") .. "\n"):gmatch("(.-)\n") do bl[#bl + 1] = l end
    for i = math.max(1, #bl - 9), #bl do lines[#lines + 1] = bl[i] end
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "Log, the last lines:"
  local ll = {}
  for l in (log:gsub("\r\n", "\n"):match("^%s*(.-)%s*$") .. "\n"):gmatch("(.-)\n") do ll[#ll + 1] = l end
  for i = math.max(1, #ll - 24), #ll do lines[#lines + 1] = ll[i] end
  local out = table.concat(lines, "\n")
  local cps = PYS.cps(out)
  if #cps > limit then
    out = PYS.rstrip(PYS.from_cps(cps, 1, limit - 60)) .. "\n(cut - the full report is a file on the reporter's PC)"
  end
  return out
end

-- the report's folder in Explorer with the file picked
function BR.show(path)
  if w3.proc and w3.proc.run then require("conjunction.fsutil").show(path, true) end
end

return BR
