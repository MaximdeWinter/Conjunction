-- editor.lua's `sys` in the game (TW3SE): the commands go through w3.exec, the scripts' lines come from w3.link,
-- the keys and the mouse from w3.input (Windows' own state, as editor.py read it next to the game), the clock is
-- w3.time, Qt's single-shot timers a list run once a frame.
local E = require("conjunction.editor")
local S = {}

function S.new()
  local seq = w3.link.mark()          -- (lines from before this session are not this session's)
  local timers, tseq = {}, 0
  local sys = {}
  function sys.exec(cmd)
    local ok, err = w3.exec(cmd)
    if not ok then print("[game] " .. tostring(err)) end
    return ok
  end
  function sys.lines()
    local s, lines = w3.link.since(seq)
    seq = s
    return lines
  end
  function sys.pressed(name)
    local c = E.VK_CODE[name] or E.KEY_VK[name]
    return c ~= nil and w3.input.down(c)
  end
  sys.front = w3.input.front          -- the game's window in front (editor.py's game_in_front)
  sys.cursor = w3.input.cursor
  sys.client = w3.input.client
  sys.set_cursor = w3.input.set_cursor
  sys.wheel = w3.input.wheel
  sys.time = w3.time
  sys.perf = w3.time
  function sys.after(ms, fn)
    tseq = tseq + 1
    timers[#timers + 1] = {w3.time() + ms / 1000.0, tseq, fn}
  end
  -- the timers that are due, in order (before each tick, as Qt's event loop runs them between the ticks)
  function sys.run_timers()
    while true do
      local now, best = w3.time(), nil
      for k, t in ipairs(timers) do
        if t[1] <= now and (best == nil or t[1] < timers[best][1] or (t[1] == timers[best][1] and t[2] < timers[best][2])) then
          best = k
        end
      end
      if not best then return end
      local t = table.remove(timers, best)
      local ok, err = pcall(t[3])
      if not ok then print("[conjunction] timer: " .. tostring(err)) end
    end
  end
  function sys.random(n) return math.random(n) end
  sys.log = print
  return sys
end
return S
