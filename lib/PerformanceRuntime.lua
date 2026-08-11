-- Runtime quality-of-life/performance controls for the Gen-2 Stadium voxel mod.
--
-- Owns two presentation/input policies that are deliberately outside the
-- engine save schema:
--   * FRAME RATE LIMIT: caps PRESENTATION FPS without changing Gold's fixed
--     60 Hz simulation clock.  The limiter sleeps only after the finished
--     Game2 draw, so game speed, music and movement remain real-time.
--   * SHOULDER GAME SPEED: optionally blocks Gen1Recomp's built-in
--     leftshoulder/rightshoulder (L1/R1, LB/RB) speed cycling before it reaches
--     Game2:gamepadpressed.  OFF is the safe default for this mod.

local V = ...
local mod = V and V.mod
local Quality = nil
do
  local ok, q = pcall(function() return V and V.require and V.require("Quality") end)
  if ok and type(q) == "table" then Quality = q end
end

local M = {
  installed = false,
  game = nil,
  drawWrapped = false,
  padWrapped = false,
  padReleaseWrapped = false,
  framesLimited = 0,
  shoulderBlocks = 0,
  slept = 0,
  lastLimit = nil,
  nextDeadline = nil,
  drawSamples = 0,
  drawSeconds = 0,
  lastDrawSeconds = 0,
}

local function option(key, fallback)
  local opts = mod and mod.options
  if not (opts and type(opts.get) == "function") then return fallback end
  local ok, value = pcall(opts.get, opts, key)
  if not ok or value == nil then return fallback end
  return value
end

local function fpsLimit()
  local raw = tostring(option("frameRateLimit", "60")):lower()
  if raw == "unlimited" or raw == "off" or raw == "0" then return 0 end
  local n = tonumber(raw) or 60
  if n < 20 then n = 20 end
  if n > 360 then n = 360 end
  return n
end

local function fpsCounterEnabled()
  local v = option("showFpsCounter", false)
  return v == true or v == 1 or v == "1" or v == "true" or v == "on"
end

local function shoulderSpeedEnabled()
  local v = option("shoulderSpeedControl", false)
  return v == true or v == 1 or v == "1" or v == "true" or v == "on"
end

local function voxelEnabled()
  local v = option("voxel3d", true)
  return not (v == false or v == 0 or v == "0" or v == "false" or v == "off")
end

local function now()
  local timer = love and love.timer
  if timer and type(timer.getTime) == "function" then
    local ok, t = pcall(timer.getTime)
    if ok and tonumber(t) then return tonumber(t) end
  end
  return os.clock()
end

local function sleep(seconds)
  if not (seconds and seconds > 0) then return end
  local timer = love and love.timer
  if timer and type(timer.sleep) == "function" then
    pcall(timer.sleep, seconds)
  end
end

function M.applyFrameLimit()
  local fps = fpsLimit()
  if fps <= 0 then
    M.nextDeadline = nil
    M.lastLimit = 0
    return false
  end

  local t = now()
  if M.lastLimit ~= fps or M.nextDeadline == nil then
    M.lastLimit = fps
    M.nextDeadline = t
  end

  local step = 1 / fps
  local deadline = M.nextDeadline + step
  -- If a frame took substantially longer than the target, never try to catch
  -- up by issuing a train of zero-sleep frames. Re-anchor to wall time.
  if t - deadline > step * 2 then deadline = t end

  if t < deadline then
    local wait = deadline - t
    sleep(wait)
    M.slept = M.slept + wait
    t = now()
  end
  M.nextDeadline = math.max(deadline, t - step * 0.25)
  M.framesLimited = M.framesLimited + 1
  return true
end

local function drawFpsCounter()
  if not fpsCounterEnabled() then return end
  local G, timer = love and love.graphics, love and love.timer
  if not (G and G.print) then return end
  local fps = 0
  if timer and type(timer.getFPS) == "function" then
    local ok, n = pcall(timer.getFPS)
    if ok then fps = tonumber(n) or 0 end
  end
  local label = ("FPS %d"):format(math.floor(fps + 0.5))
  G.push("all")
  G.origin()
  G.setShader()
  G.setColor(0, 0, 0, 0.58)
  G.rectangle("fill", 6, 6, 66, 24, 5, 5)
  G.setColor(1, 1, 1, 1)
  G.print(label, 12, 10)
  G.pop()
end

local function wrapDraw(game)
  if not game or game._stadium2FrameLimiter then return true end
  local native = game.draw
  if type(native) ~= "function" then return false, "game.draw unavailable" end

  game.draw = function(self, ...)
    local t0 = now()
    local a, b, c = native(self, ...)
    local drawCost = math.max(0, now() - t0)
    M.lastDrawSeconds = drawCost
    M.drawSeconds = M.drawSeconds + drawCost
    M.drawSamples = M.drawSamples + 1
    if Quality and type(Quality.requestedPreset) == "function"
        and type(Quality.noteFrameCost) == "function" then
      local okPreset, requested = pcall(Quality.requestedPreset)
      if okPreset and requested == "auto" and voxelEnabled() then
        local target = fpsLimit()
        if target <= 0 then target = 60 end
        pcall(Quality.noteFrameCost, drawCost, target)
      end
    end
    drawFpsCounter()
    M.applyFrameLimit()
    return a, b, c
  end
  game._stadium2FrameLimiter = true
  M.drawWrapped = true
  return true
end

local function noteGamepad(game)
  local touch = game and game.touchControls
  if touch and type(touch.noteGamepad) == "function" then
    pcall(touch.noteGamepad, touch)
  end
end

local function wrapShoulders(game)
  if not game or game._stadium2ShoulderSpeedGuard then return true end
  local native = game.gamepadpressed
  if type(native) ~= "function" then return false, "game.gamepadpressed unavailable" end

  -- Install late (after FlyYourPokemon) so this wrapper is the outermost owner
  -- of shoulder presses. Face-button mount shortcuts still pass through.
  game.gamepadpressed = function(self, joystick, button, ...)
    if (button == "leftshoulder" or button == "rightshoulder")
        and not shoulderSpeedEnabled() then
      noteGamepad(self)
      M.shoulderBlocks = M.shoulderBlocks + 1
      return
    end
    -- This is the outermost controller wrapper in the mod. Never let one bad
    -- optional face-button feature take the whole game down. Log the original
    -- error and leave the frame alive; release/input reconciliation on the next
    -- tick prevents a stuck held button.
    local ok, a, b, c = pcall(native, self, joystick, button, ...)
    if ok then return a, b, c end
    if mod and mod.log and type(mod.log.error) == "function" then
      pcall(mod.log.error, mod.log,
        "Controller button %s handler failed safely: %s",
        tostring(button), tostring(a))
    end
    local input = self and self.input
    if input and type(input.reset) == "function" then pcall(input.reset, input) end
    return nil
  end
  game._stadium2ShoulderSpeedGuard = true
  M.padWrapped = true

  local nativeRelease = game.gamepadreleased
  if type(nativeRelease) == "function" and not game._stadium2ControllerReleaseGuard then
    game.gamepadreleased = function(self, joystick, button, ...)
      local ok, a, b, c = pcall(nativeRelease, self, joystick, button, ...)
      if ok then return a, b, c end
      if mod and mod.log and type(mod.log.error) == "function" then
        pcall(mod.log.error, mod.log,
          "Controller button %s release handler failed safely: %s",
          tostring(button), tostring(a))
      end
      local input = self and self.input
      if input and type(input.reset) == "function" then pcall(input.reset, input) end
      return nil
    end
    game._stadium2ControllerReleaseGuard = true
    M.padReleaseWrapped = true
  end
  return true
end

function M.attach(game)
  if not game then return false, "no game" end
  M.game = game
  local okDraw, errDraw = wrapDraw(game)
  local okPad, errPad = wrapShoulders(game)
  if not okDraw then return false, errDraw end
  if not okPad then return false, errPad end
  return true
end

function M.install()
  if M.installed then return true end
  if mod and mod.events and type(mod.events.on) == "function" then
    mod.events:on("game.ready", function(game)
      pcall(M.attach, game)
    end)
    mod.events:on("mod.options_changed", function(payload)
      if type(payload) ~= "table" then return end
      if payload.mod ~= nil and mod and payload.mod ~= mod.id then return end
      if payload.key == "frameRateLimit" then
        -- Re-anchor immediately so lowering or raising the cap never inherits
        -- the old cadence's deadline.
        M.nextDeadline = nil
        M.lastLimit = nil
      elseif (payload.key == "performancePreset" or payload.key == "voxel3d")
          and Quality and type(Quality.resetAuto) == "function" then
        pcall(Quality.resetAuto)
      end
    end)
  end
  M.installed = true

  -- Hot reload: game.ready may already have fired.
  local game = (mod and mod.world and mod.world.game) or (V and V.game) or nil
  if game then pcall(M.attach, game) end
  return true
end

function M.status()
  return {
    installed = M.installed,
    fpsLimit = fpsLimit(),
    shoulderSpeedEnabled = shoulderSpeedEnabled(),
    fpsCounterEnabled = fpsCounterEnabled(),
    drawWrapped = M.drawWrapped,
    padWrapped = M.padWrapped,
    padReleaseWrapped = M.padReleaseWrapped,
    framesLimited = M.framesLimited,
    shoulderBlocks = M.shoulderBlocks,
    slept = M.slept,
    drawSamples = M.drawSamples,
    lastDrawMs = M.lastDrawSeconds * 1000,
    averageDrawMs = M.drawSamples > 0 and (M.drawSeconds / M.drawSamples * 1000) or 0,
    adaptive = (Quality and type(Quality.status) == "function")
      and Quality.status() or nil,
  }
end

return M
