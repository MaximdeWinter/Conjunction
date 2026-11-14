-- Conjunction's engine for the app (docs/APP_ENGINE_PLAN.md): the mod without a bar, a panel or an editor of its
-- own. The app (conjunction/engine.py) calls the agent's commands through TW3SE's pipe - the scene workshop's scene_*
-- above all - and draws the windows itself. init.lua starts this when a file `engine_only` lies beside it (the app
-- installs the mod that way).
--   ENGINE.start(AGENT)
local E = {}

E.project = nil                 -- the app's open project (engine_project)
E.body = nil                    -- the scene workshop without a window (ui/scene_window.lua's body: the model)

-- the window the body would draw in: nothing is drawn, nothing is hit
local WIN = {hit = function() return false, false, false end}

function E.get_body()
  if not E.body then
    local SCW = require("conjunction.ui.scene_window")
    E.body = SCW.new({project = E.project and {path = E.project} or nil}, WIN)
  end
  return E.body
end

function E.close()
  if E.body then
    pcall(E.body.closed, E.body)
    E.body = nil
  end
end

function E.register(C, DOC)
  DOC.engine_ping = "The engine answers: {engine = true, project, scene (the open scene's path), live (preview possible)}"
  function C.engine_ping()
    local b = E.body
    return {engine = true, project = E.project, scene = b and b.w and b.w.path or nil,
            live = w3.scene ~= nil and w3.scene.seek ~= nil}
  end

  DOC.engine_project = "The app's open project: path (its folder)"
  function C.engine_project(a)
    E.project = a.path
    if E.body then E.body.project_dir = a.path end
    return {project = E.project}
  end

  DOC.engine_close = "The scene workshop closed: the scene's facts back, the preview stopped, the picture full screen"
  function C.engine_close()
    E.close()
    if w3.view and w3.view.rect then pcall(w3.view.rect, false) end
    if w3.hud and w3.hud.visible then pcall(w3.hud.visible, true) end
    return {closed = true}
  end

  DOC.camera_now = "The game's camera now: x, y, z, pitch, yaw, fov (a camera to give scene_camera_move later)"
  function C.camera_now()
    local p, r = w3.camera.pos(), w3.camera.rot()
    return {x = p.X, y = p.Y, z = p.Z, pitch = r.Pitch or 0, yaw = r.Yaw or 0,
            fov = w3.camera.fov and tonumber(w3.camera.fov()) or 35}
  end

  DOC.camera_free ="The free camera on (on = true: the editor flies) or off (the game shows its own camera - in a " ..
                    "playing scene, the scene's)"
  function C.camera_free(a)
    if not (w3.camera and w3.camera.free) then error("this TW3SE has no w3.camera.free", 0) end
    return {free = w3.camera.free(a.on ~= false)}
  end

  DOC.view_rect ="The game's picture in a rectangle of the screen's client area: x, y, w, h; full = true: the whole " ..
                  "picture again. hud = false hides the game's HUD, true shows it"
  function C.view_rect(a)
    if not (w3.view and w3.view.rect) then error("this TW3SE has no w3.view.rect", 0) end
    if a.full then
      w3.view.rect(false)
    elseif a.x then
      w3.view.rect(a.x, a.y, a.w, a.h)
    end
    if a.hud ~= nil and w3.hud and w3.hud.visible then w3.hud.visible(a.hud == true) end
    local x, y, w, h = w3.view.rect()
    return {x = x, y = y, w = w, h = h}
  end
end

function E.start(AGENT)
  require("conjunction.agent_scene").get_body = E.get_body
  E.register(AGENT.COMMANDS, AGENT.DOC)
  AGENT.app = {engine = true}
  -- read ahead over the first frames: the index of the game's files (cj_core's thread) and the list of the game's
  -- scenes with their people (in slices of 4 ms: scene_swap.scene_info) - the first scene command took 4 s without
  local game = require("conjunction.config").load().game
  local warm = game and coroutine.create(function()
    local DP = require("conjunction.depot")
    local d = DP.open_async(game)
    while not d do
      coroutine.yield()
      d = DP.open_async(game)
    end
    require("conjunction.scene_swap").scene_info(d)
  end)
  -- the body's timers: a library peek ends by itself, a pose shows once its animation has streamed in
  w3.on_ui(function()
    if warm and coroutine.status(warm) == "suspended" then
      local ok, err = coroutine.resume(warm)
      if not ok then
        print("[conjunction engine] reading ahead: " .. tostring(err))
        warm = nil
      end
    end
    pcall(require("conjunction.scene_work").sub_tick)     -- (the subtitles of one's own lines in the preview)
    pcall(require("conjunction.scene_work").after_play_tick)   -- (the screen back after a preview)
    local b = E.body
    if b then
      local ok, err = pcall(b.peek_tick, b)
      if not ok and not E.tick_err then
        E.tick_err = tostring(err)
        print("[conjunction engine] " .. E.tick_err)
      end
    end
  end)
  print("[conjunction] the engine for the app is ready (commands through the pipe: CJ_AGENT)")
end

return E
