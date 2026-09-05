-- Gold/Silver official render_pipelines bridge.
--
-- Newer Gen1Recomp builds give Gold the same engine-owned drawWorld pipeline
-- seam that Gen 1 already had.  Older Gold builds (including some Android
-- packages) still rely on render.compose instead.  Registering this provider is
-- therefore deliberately additive: current builds render the voxel world from
-- World:drawPipeline, while GoldComposeBridge remains the fallback for hosts
-- where the drawWorld half is not consumed.
local first, second = ...
local mod, VoxelBridge
if second == nil and type(first) == "table" and first.mod then
  mod, VoxelBridge = first.mod, first.VoxelBridge
else
  mod, VoxelBridge = first, second
end
local Bridge = {
  id = "stadium2_gold_voxel",
  installed = false,
  runtimeActive = false,
  frames = 0,
  renderedFrames = 0,
  fallbackFrames = 0,
  lastError = nil,
  lastStatus = nil,
  renderedForCompose = false,
  selectorComposeFallback = false,
  selectorDetected = false,
}

local function pipelineModule()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if ok and type(Pipelines) == "table" then return Pipelines end
  return nil
end

local function optionOn()
  if VoxelBridge and type(VoxelBridge.voxelModeEnabled) == "function" then
    local ok, yes = pcall(VoxelBridge.voxelModeEnabled)
    if ok then return yes and true or false end
  end
  -- Check actual pipeline level instead of mod option
  local Pipelines = pipelineModule()
  if Pipelines and type(Pipelines.get) == "function" then
    local def = Pipelines.get(Bridge.id)
    if def and def.level ~= nil then
      return def.level > 0
    end
  end
  -- Fallback to mod option
  local opts = mod and mod.options
  if not (opts and type(opts.get) == "function") then return true end
  local ok, value = pcall(opts.get, opts, "voxel3d")
  if not ok or value == nil then return true end
  -- For 8-level system, OFF (0) is off, everything else is on
  local numValue = tonumber(value)
  if numValue ~= nil then
    return numValue > 0
  end
  return not (value == false or value == "0"
    or value == "false" or value == "off")
end

local function resolveGame(value)
  if type(value) == "table" then
    if value.world or value.stack then return value end
    if type(value.game) == "table" then return value.game end
  end
  return Bridge.game
end

local function resolveWorld(ctx)
  local world = ctx and ctx.state
  if type(world) == "table" and world.map then return world end

  local game = Bridge.game
  world = game and game.world
  if type(world) == "table" and world.map then return world end

  local api = mod and mod.world
  if api and type(api.overworld) == "function" then
    local ok, value = pcall(api.overworld, api)
    if ok and type(value) == "table" and value.map then return value end
  end
  return nil
end

-- GoldVoxelBridge was originally fed render.compose metrics. Translate the
-- official drawWorld context without mutating the engine's table. Gold does
-- NOT use Gen1 Renderer:endFrame for this pass: World:drawPipeline draws the
-- returned canvas directly at (0,0).  `generation = 2` is therefore part of
-- the sizing contract -- GoldVoxelBridge must return ctx.width x ctx.height
-- logical output even on HiDPI Android, while Gen1 keeps its physical
-- framebuffer worldOverride rules.  Physical metrics are retained only as
-- diagnostics/compatibility data.
local function voxelContext(ctx)
  local w = tonumber(ctx and ctx.width)
  local h = tonumber(ctx and ctx.height)
  if not (w and h and w > 0 and h > 0) then
    local G = love and love.graphics
    if G and type(G.getDimensions) == "function" then w, h = G.getDimensions() end
  end
  w, h = tonumber(w) or 1, tonumber(h) or 1
  -- Preserve physical metrics only when the engine actually supplied them.
  -- Leaving them nil lets GoldVoxelBridge fall through to GameViewport's
  -- pixelDimensions() on current hosts instead of mistaking LOVE units for
  -- framebuffer pixels on HiDPI / reserved-viewport layouts.
  local pw = tonumber(ctx and (ctx.pw or ctx.pixelWidth))
  local ph = tonumber(ctx and (ctx.ph or ctx.pixelHeight))
  return {
    generation = 2,
    ww = w, wh = h,
    pw = pw, ph = ph,
    vw = tonumber(ctx and ctx.vw),
    vh = tonumber(ctx and ctx.vh),
    scale = tonumber(ctx and ctx.scale),
    cam = ctx and ctx.cam,
    state = ctx and ctx.state,
    level = ctx and ctx.level,
    drawFx = ctx and ctx.drawFx,
    fx = ctx and ctx.fx,
  }
end

local function available()
  -- Keep this gate intentionally cheap.  GoldVoxelBridge performs the actual
  -- depth/shader capability check and returns nil on unsupported hardware, at
  -- which point Pipelines falls back to native 2D for that frame.
  local result = optionOn()
  if Bridge.frames == 0 and mod and mod.log then
    mod.log:info("GoldPipelineBridge: available() called, returning %s", tostring(result))
  end
  return result
end

local function drawWorld(ctx)
  Bridge.frames = Bridge.frames + 1
  Bridge.renderedForCompose = false
  
  -- Log pipeline level check
  local Pipelines = pipelineModule()
  local currentLevel = 0
  if Pipelines and Pipelines.get then
    local def = Pipelines.get(Bridge.id)
    if def then currentLevel = def.level or 0 end
  end
  
  if Bridge.frames == 1 then
    local mod = VoxelBridge and VoxelBridge.lib and VoxelBridge.lib.mod
    if mod and mod.log then
      mod.log:info("GoldPipelineBridge: drawWorld called, pipeline level=%d, optionOn=%s", currentLevel, tostring(optionOn()))
    end
  end
  
  if not optionOn() then
    Bridge.lastStatus = "disabled"
    Bridge.fallbackFrames = Bridge.fallbackFrames + 1
    -- Log first disabled frame
    if Bridge.fallbackFrames == 1 then
      local mod = VoxelBridge and VoxelBridge.lib and VoxelBridge.lib.mod
      if mod and mod.log then
        mod.log:info("GoldPipelineBridge: Voxel disabled (optionOn=false, level=%d)", currentLevel)
      end
    end
    return nil
  end
  if not (VoxelBridge and type(VoxelBridge.renderFrame) == "function") then
    Bridge.lastError = "Gold voxel provider is unavailable"
    Bridge.lastStatus = "failed"
    Bridge.fallbackFrames = Bridge.fallbackFrames + 1
    return nil
  end

  local world = resolveWorld(ctx)
  if not world then
    Bridge.lastError = "Gold world is unavailable"
    Bridge.lastStatus = "pending"
    Bridge.fallbackFrames = Bridge.fallbackFrames + 1
    return nil
  end

  if type(VoxelBridge.setGame) == "function" then
    pcall(VoxelBridge.setGame, (world and world.game) or Bridge.game)
  end

  local ok, canvas, err, status = pcall(
    VoxelBridge.renderFrame, world, voxelContext(ctx))
  if not ok then
    Bridge.lastError = tostring(canvas)
    Bridge.lastStatus = "failed"
    Bridge.fallbackFrames = Bridge.fallbackFrames + 1
    return nil
  end
  Bridge.lastStatus = status or (canvas and "rendered" or "pending")
  if not canvas then
    Bridge.lastError = err and tostring(err) or nil
    Bridge.fallbackFrames = Bridge.fallbackFrames + 1
    return nil
  end

  Bridge.renderedFrames = Bridge.renderedFrames + 1
  Bridge.lastError = nil
  -- render.compose runs after World:drawPipeline on current Gold.  Let the
  -- compose bridge consume this bit so it does not render the same voxel scene
  -- a second time; on older Gold the callback never runs and the compose bridge
  -- remains fully active.
  Bridge.renderedForCompose = true
  -- Log first successful render
  if Bridge.renderedFrames == 1 then
    local mod = VoxelBridge and VoxelBridge.lib and VoxelBridge.lib.mod
    if mod and mod.log then
      mod.log:info("GoldPipelineBridge: First successful voxel render")
    end
  end
  return canvas
end

local function selectorNeedsCompose(Pipelines)
  -- Gen1Recomp permits only one active drawWorld pipeline. red_3d_player uses
  -- its public `voxel` pipeline levels for ZOOM/1ST/3RD and skin selection
  -- integration. Activating our own drawWorld record would therefore switch
  -- that pipeline OFF. When the selector is installed, deliberately keep our
  -- drawWorld record OFF and let GoldComposeBridge own the final world instead;
  -- OverworldStadium still calls the selector's red3dPlayerRenderer:drawVoxel,
  -- so selected player skins render inside the Stadium voxel scene.
  local found = false
  if mod and type(mod.find) == "function" then
    local okFind, selector = pcall(mod.find, "red_3d_player")
    found = okFind and selector ~= nil
  end
  if not found and Pipelines and type(Pipelines.get) == "function" then
    local okGet, def = pcall(Pipelines.get, "voxel")
    found = okGet and type(def) == "table"
  end
  Bridge.selectorDetected = found
  return found
end

function Bridge.sync(gameOrEvent)
  Bridge.game = resolveGame(gameOrEvent) or Bridge.game
  local Pipelines = pipelineModule()
  if not (Pipelines and type(Pipelines.get) == "function"
      and type(Pipelines.setLevel) == "function") then
    Bridge.runtimeInstalled = false
    Bridge.runtimeActive = false
    return false, "engine drawWorld pipelines unavailable"
  end
  local def = Pipelines.get(Bridge.id)
  if type(def) ~= "table" or type(def.drawWorld) ~= "function" then
    Bridge.runtimeInstalled = false
    Bridge.runtimeActive = false
    return false, "Gold voxel drawWorld pipeline not present in merged registry"
  end

  Bridge.runtimeInstalled = true

  -- Preserve Character Selector's own world-pipeline state. The compose path
  -- is not a competing drawWorld pipeline, so both its selector/camera ladder
  -- and our voxel/Stadium presentation can coexist there.
  if selectorNeedsCompose(Pipelines) then
    pcall(Pipelines.setLevel, Bridge.id, 0)
    Bridge.runtimeActive = false
    Bridge.selectorComposeFallback = true
    Bridge.lastError = nil
    return true, false
  end
  Bridge.selectorComposeFallback = false

  -- Get current pipeline level first to preserve user's choice
  local currentLevel = 0
  local okRead, current = pcall(Pipelines.level, Bridge.id)
  if okRead and current ~= nil then
    currentLevel = tonumber(current) or 0
  end

  -- For Gen 2, if the level is already set (non-zero), never reset it
  -- The manual pipeline rows control the level directly, so we preserve it
  -- This prevents sync() from resetting the level when options are opened
  if currentLevel > 0 then
    if mod and mod.log then
      mod.log:info("GoldPipelineBridge.sync: preserving current level %d (Gen 2)", currentLevel)
    end
    Bridge.runtimeActive = true
    Bridge.lastError = nil
    return true, true
  end

  -- Only read from mod options if current level is 0 (for Gen 1 compatibility)
  local wanted = currentLevel
  if wanted == 0 then
    local opts = mod and mod.options
    if opts and type(opts.get) == "function" then
      local ok, value = pcall(opts.get, opts, "voxel3d")
      if ok and value ~= nil then
        local numValue = tonumber(value)
        if numValue ~= nil then
          wanted = numValue
        elseif value == false or value == "0" or value == "false" or value == "off" then
          wanted = 0
        else
          wanted = 1
        end
      else
        wanted = optionOn() and 1 or 0
      end
    else
      wanted = optionOn() and 1 or 0
    end
  end

  local ok, level = pcall(Pipelines.setLevel, Bridge.id, wanted)
  if not ok then
    Bridge.runtimeActive = false
    Bridge.lastError = tostring(level)
    return false, Bridge.lastError
  end
  Bridge.runtimeActive = tonumber(level) and tonumber(level) > 0 or false
  return true, Bridge.runtimeActive
end

function Bridge.consumeRenderedFrame()
  local rendered = Bridge.renderedForCompose == true
  Bridge.renderedForCompose = false
  return rendered
end

-- love.timer.getFrameCount is not part of every LOVE build this mod runs
-- under (some hosts omit it entirely, which crashed every throttled log
-- line below with "attempt to call field 'getFrameCount' (a nil value)"
-- and took the whole pipeline down for the session). Fall back to a
-- private counter incremented once per Bridge.update call when the real
-- API is unavailable.
local _frameCounter = 0
local function frameTick()
  if love and love.timer and type(love.timer.getFrameCount) == "function" then
    local ok, n = pcall(love.timer.getFrameCount)
    if ok and type(n) == "number" then return n end
  end
  _frameCounter = _frameCounter + 1
  return _frameCounter
end

-- Update function called by the engine every frame
-- This is where FirstPerson.update and FreeMove should be called for Gen 2
function Bridge.update(dt, level)
  -- Only update if voxel mode is active (level > 0)
  if not level or level == 0 then return end

  local mod = VoxelBridge and VoxelBridge.lib and VoxelBridge.lib.mod
  local tick = frameTick()
  if mod and mod.log and tick % 30 == 0 then
    mod.log:info("GoldPipelineBridge.update: called, level=%d, dt=%.3f", level, dt)
  end

  if VoxelBridge and VoxelBridge.lib then
    local FirstPerson = VoxelBridge.lib.require and VoxelBridge.lib.require("FirstPerson")
    if FirstPerson and type(FirstPerson.update) == "function" then
      local ok, err = pcall(FirstPerson.update, dt)
      if mod and mod.log and tick % 30 == 0 then
        mod.log:info("GoldPipelineBridge.update: FirstPerson.update called, ok=%s", tostring(ok))
        if not ok then mod.log:warn("FirstPerson.update error: %s", tostring(err)) end
      end
    end

    -- Call FreeMove.tick for free movement (Gen 2 doesn't use handleInput wrap)
    local FreeMove = VoxelBridge.lib.require and VoxelBridge.lib.require("FreeMove")
    if FreeMove and type(FreeMove.tick) == "function" then
      -- Get the overworld state for FreeMove.tick
      local okState, state = pcall(function()
        local okG2, Game2 = pcall(require, "src.core.Game2")
        if okG2 and Game2 then return Game2.overworld end
        local Game = require("src.core.Game")
        return Game.overworld
      end)
      if okState and state then
        local okTick, errTick = pcall(FreeMove.tick, state)
        if mod and mod.log and tick % 30 == 0 then
          mod.log:info("GoldPipelineBridge.update: FreeMove.tick called, okState=%s, okTick=%s", tostring(okState), tostring(okTick))
          if not okTick then mod.log:warn("FreeMove.tick error: %s", tostring(errTick)) end
        end
      else
        if mod and mod.log and tick % 30 == 0 then
          mod.log:warn("GoldPipelineBridge.update: Failed to get overworld state: %s", tostring(state))
        end
      end
    else
      if mod and mod.log and tick % 30 == 0 then
        mod.log:warn("GoldPipelineBridge.update: FreeMove not available or tick not a function")
      end
    end

    -- Step Stadium 2 ROM build (for Gen 2 Pokemon models)
    local Stadium2Install = VoxelBridge.lib.require and VoxelBridge.lib.require("Stadium2Install")
    if Stadium2Install and type(Stadium2Install.step) == "function" then
      pcall(Stadium2Install.step)
    end
  end
end

function Bridge.install()
  if Bridge.registered then return true end
  local content = mod and mod.content
  local registry = content and content.render_pipelines
  if not (registry and type(registry.register) == "function") then
    -- Older engines can still use GoldComposeBridge.  This is deliberately a
    -- non-fatal "not installed" result, not a reason to take the mod down.
    return false, "render_pipelines registry is unavailable"
  end

  local ok, err = pcall(registry.register, registry, Bridge.id, {
    label = "STADIUM 2 VOXEL WORLD",
    levels = { "OFF", "FULL", "15", "35", "50", "75", "1ST", "3RD" },
    priority = 1100,
    available = available,
    drawWorld = drawWorld,
    update = Bridge.update,
  })
  if not ok then return false, tostring(err) end
  Bridge.registered = true
  if mod and mod.log then
    mod.log:info("GoldPipelineBridge: Pipeline %s registered with 8 levels", Bridge.id)
    -- Verify it's actually in the registry
    local verifyOk, verifyDef = pcall(registry.get, registry, Bridge.id)
    if verifyOk and verifyDef then
      mod.log:info("GoldPipelineBridge: Verified pipeline in registry, levels=%d", #verifyDef.levels)
    else
      mod.log:warn("GoldPipelineBridge: Pipeline not found in registry after registration")
    end
  end

  if mod.events and type(mod.events.on) == "function" then
    pcall(mod.events.on, mod.events, "game.ready", function(ev)
      Bridge.sync(ev)
    end)
    pcall(mod.events.on, mod.events, "map.entered", function(ev)
      Bridge.sync(ev)
    end)
    pcall(mod.events.on, mod.events, "mod.options_changed", function(ev)
      if type(ev) ~= "table" then return end
      if ev.mod ~= nil and ev.mod ~= mod.id then return end
      if ev.key == "voxel3d" or ev.key == "openWorld" then Bridge.sync() end
    end)
  end

  return true
end

function Bridge.status()
  return {
    id = Bridge.id,
    registered = Bridge.registered,
    runtimeInstalled = Bridge.runtimeInstalled,
    runtimeActive = Bridge.runtimeActive,
    frames = Bridge.frames,
    renderedFrames = Bridge.renderedFrames,
    fallbackFrames = Bridge.fallbackFrames,
    lastError = Bridge.lastError,
    lastStatus = Bridge.lastStatus,
    selectorDetected = Bridge.selectorDetected,
    selectorComposeFallback = Bridge.selectorComposeFallback,
  }
end

Bridge._drawWorld = drawWorld
Bridge._available = available
Bridge._voxelContext = voxelContext
return Bridge