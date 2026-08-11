-- Gold/Silver voxel renderer provider for the official render.compose hook.
--
-- Gold does not run Gen-1 drawWorld pipelines.  This module therefore owns no
-- engine method and registers no pipeline.  It only prepares the embedded
-- Dramatic Shapes renderer and exposes renderFrame(world, ctx); GoldComposeBridge
-- calls that from the engine's supported whole-window compose seam.
local mod = ...

local Bridge = {
  installed = false,
  active = false,
  lastError = nil,
  framesAttempted = 0,
  frames3d = 0,
  framesPending = 0,
  framesFailed = 0,
  mapId = nil,
  extraEntitiesProvider = nil,
  extraEntitiesMerged = 0,
  syncBuildMapId = nil,
  syncBuilds = 0,
  syncBuildFailures = 0,
  meshPendingFrames = 0,
  openWorld = false,
  openWorldMaps = 0,
  openWorldDirectMaps = 0,
  openWorldGraphBuilds = 0,
  openWorldFallbacks = 0,
  openWorldOverlapRejects = 0,
  openWorldGraphRoot = nil,
  openWorldGraphError = nil,
  cameraMode = "diorama",
  cameraLevel = 1,
  cameraHotkeyCycles = 0,
  cameraHotkeyPollCycles = 0,
  cameraStepHotkeyInstalled = false,
  cameraStepHotkeyError = nil,
  f6Down = false,
  cameraSliderInstalled = false,
  cameraSliderTouches = 0,
  cameraSliderChanges = 0,
  cameraInputInstalled = false,
  cameraInputError = nil,
  cameraModeStickHolds = 0,
  pinchZoomInstalled = false,
  pinchZoomError = nil,
  cameraMovementInstalled = false,
  cameraMovementError = nil,
  cameraOverride = nil,
  cameraProvider = "stadium",
  externalCameraLevel = nil,
  externalCameraLabel = nil,
  selectorDetected = false,
  game = nil,
  lastTickTime = nil,
}

-- Minimal Dramatic-Shape module namespace.  Deliberately does not execute the
-- Gen-1 pipeline/input installer from the original Dramaless package.
local V = { mod = mod, path = mod.path }
local modules, dataFiles = {}, {}

local function chunkFor(rel)
  local source, readErr = mod:read(rel)
  if type(source) ~= "string" then
    error(("STADIUM2_OVERWORLD_MODELS: missing %s: %s")
      :format(rel, tostring(readErr)), 0)
  end
  if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
  local loadcode = loadstring or load
  local chunk, err = loadcode(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("STADIUM2_OVERWORLD_MODELS: %s did not compile: %s")
      :format(rel, tostring(err)), 0)
  end
  return chunk
end

function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local value = chunkFor("lib/" .. name .. ".lua")(V)
  modules[name] = value
  return value
end

function V.data(name)
  local hit = dataFiles[name]
  if hit ~= nil then return hit end
  local value = chunkFor("data/" .. name .. ".lua")(V)
  dataFiles[name] = value
  return value
end

Bridge.lib = V

local Voxel, Voxel3D, VoxelScene, ChunkMesher, FirstPerson, CamControl, GoldCameraControls
local EngineViewportCompat, PixelCanvas
local OverworldBattle, OverworldCapture, GoldColorAtlas, TwinRegionWorld
local Quality
local GoldMap = nil
local neighborMapCache = {}
local openWorldGraphCache = { rootId = nil, maps = nil, specs = nil }
local logOnce

local function optionEnabled()
  local ok, value = pcall(mod.options.get, mod.options, "voxel3d")
  if not ok or value == nil then return true end
  return not (value == false or value == 0 or value == "0"
    or value == "false" or value == "off")
end

-- v0.4.16: one authoritative answer for the OVERWORLD renderer master switch.
-- Other subsystems (camera input, weather presentation, zoom and 2D fallbacks)
-- use this instead of guessing from a stale VoxelState rung or from OPEN WORLD.
-- Kanto is deliberately NOT an exception here: a player who selects native 2D
-- must remain in native 2D everywhere the Gold world is visible.
V.world3DEnabled = optionEnabled
Bridge.world3DEnabled = optionEnabled

-- Independent model switches. Neither disables the voxel world, 3D terrain,
-- buildings, trees, grass, props, weather, cameras or OPEN WORLD residency.
-- Pokemon geometry and the human-player Character Selector skin are separate
-- layers so either can fall back to Gold's 2D card while the other stays 3D.
local function modelOptionEnabled(key, default)
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return default ~= false end
  local ok, value = pcall(options.get, options, key)
  if not ok or value == nil then return default ~= false end
  return not (value == false or value == 0 or value == "0"
    or value == "false" or value == "off")
end

local function modelsEnabled()
  return modelOptionEnabled("stadium3dSprites", true)
end

local function playerModelsEnabled()
  -- A selected AND enabled custom 2D trainer is an explicit visual override.
  -- Ask the picker dynamically through exports so merely turning the setting
  -- on before a valid sheet exists does not hide Character Selector's model.
  local custom = mod and mod.exports and mod.exports.customPlayerSprite
  if custom and type(custom.active) == "function" then
    local ok, active = pcall(custom.active)
    if ok and active then return false end
  end
  return modelOptionEnabled("player3dModel", true)
end

V.modelsEnabled = modelsEnabled
V.playerModelsEnabled = playerModelsEnabled

local function graphicsQuality()
  if type(Quality) == "table" then return Quality end
  local ok, q = pcall(V.require, "Quality")
  if ok and type(q) == "table" then Quality = q return q end
  return nil
end

local function renderResolutionFactor()
  local q = graphicsQuality()
  if q and type(q.renderFactor) == "function" then
    local ok, f = pcall(q.renderFactor)
    if ok and tonumber(f) then return math.max(0.30, math.min(1.0, tonumber(f))) end
  end
  return 1.0
end
Bridge.modelsEnabled = modelsEnabled
Bridge.playerModelsEnabled = playerModelsEnabled

local function toggleValue(value, default)
  if value == nil then return default and true or false end
  if value == true or value == 1 or value == "1" then return true end
  if value == false or value == 0 or value == "0" then return false end
  if type(value) == "string" then
    value = value:lower()
    if value == "true" or value == "on" or value == "yes" then return true end
    if value == "false" or value == "off" or value == "no" then return false end
  end
  return default and true or false
end

local function optionOpenWorld()
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return false end
  local ok, value = pcall(options.get, options, "openWorld")
  if not ok then return false end
  return toggleValue(value, false)
end

local function optionGen1Region()
  -- Read the public option directly so this works during Bridge.install before
  -- TwinRegionWorld has finished loading.  Once loaded, its helper remains the
  -- authoritative normalization path.
  if TwinRegionWorld and type(TwinRegionWorld.gen1Enabled) == "function" then
    local ok, value = pcall(TwinRegionWorld.gen1Enabled)
    if ok then return value == true end
  end
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return false end
  local ok, value = pcall(options.get, options, "gen1Region")
  if not ok then return false end
  return toggleValue(value, false)
end

local function kantoExcursionActive()
  if not (optionGen1Region() and TwinRegionWorld
      and type(TwinRegionWorld.excursionIsActive) == "function") then
    return false
  end
  local ok, active = pcall(TwinRegionWorld.excursionIsActive)
  return ok and active == true
end

local function effectiveOpenWorld()
  -- v0.4.32: OPEN WORLD is the user's residency choice in BOTH Johto and the
  -- detached Yellow/Kanto excursion. Kanto still owns its voxel renderer while
  -- active, but simply entering Kanto no longer silently forces full-world
  -- residency; OFF uses the normal sector streamer and ON expands to the whole
  -- connected Kanto graph.
  return optionOpenWorld()
end

local function voxelModeEnabled()
  -- 3D VOXEL WORLD is the renderer master switch. OPEN WORLD, camera mode,
  -- Weather FX and the optional Kanto region are consumers of that renderer;
  -- none of them may resurrect it after the player explicitly selects 2D.
  return optionEnabled()
end

Bridge.voxelModeEnabled = voxelModeEnabled

local function applyOpenWorldMode(enabled)
  enabled = toggleValue(enabled, false)
  if Bridge.openWorld == enabled then return false end
  -- The mode switch only changes residency. Never replace the current voxel
  -- scene: clear the lightweight graph/adapted-map caches and let the next
  -- normal VoxelScene frame rebuild the neighbour set around the SAME current
  -- map/entities/terrain renderer. This is the key v0.2.46 rule that keeps all
  -- Stadium models, trees, grass, props and voxel geometry alive in both modes.
  neighborMapCache = {}
  openWorldGraphCache = { rootId = nil, maps = nil, specs = nil }
  Bridge.openWorld = enabled
  Bridge.openWorldGraphError = nil
  if TwinRegionWorld and type(TwinRegionWorld.invalidateOcean) == "function" then
    -- The combined world bounds change when the residency mode changes. The
    -- ocean is a four-vertex mesh, so dropping it here is cheap and prevents
    -- one stale outer rectangle from surviving the first frame of the switch.
    pcall(TwinRegionWorld.invalidateOcean)
  end
  if not enabled then
    Bridge.openWorldMaps = 0
    if V then V.goldOpenWorldMaps = {} end
  end
  return true
end

Bridge.optionOpenWorld = optionOpenWorld
Bridge.optionGen1Region = optionGen1Region
Bridge.effectiveOpenWorld = effectiveOpenWorld
Bridge._applyOpenWorldMode = applyOpenWorldMode

local CAMERA_ORDER = { "diorama", "third", "first" }
local CAMERA_NEXT = { diorama = "third", third = "first", first = "diorama" }

local function platformName()
  -- Current Gen1Recomp sandboxes throw when mod code dereferences
  -- love.system at all. Prefer the engine-owned Platform seam and keep the
  -- old direct LÖVE fallback entirely inside pcall for older hosts.
  local okPlatform, Platform = pcall(require, "src.core.Platform")
  if okPlatform and type(Platform) == "table" and type(Platform.detect) == "function" then
    local okDetect, info = pcall(Platform.detect)
    if okDetect and type(info) == "table" and type(info.os) == "string" then
      return info.os
    end
  end
  local ok, osName = pcall(function()
    local system = love and love.system
    return system and system.getOS and system.getOS()
  end)
  if ok and type(osName) == "string" then return osName end
  return "Unknown"
end

local function isAndroid()
  return platformName():lower() == "android"
end

Bridge.isAndroid = isAndroid

local function normalizeCameraMode(value)
  value = type(value) == "string" and value:lower() or value
  if value == "third" or value == "third_person" or value == "3rd" then
    return "third"
  elseif value == "first" or value == "first_person" or value == "1st" then
    return "first"
  end
  return "diorama"
end

local function optionCameraControl()
  local ok, value = pcall(mod.options.get, mod.options, "cameraControl")
  value = ok and type(value) == "string" and value:lower() or "auto"
  if value == "stadium" or value == "selector" then return value end
  return "auto"
end

local function selectorDetected()
  if not (mod and type(mod.find) == "function") then return false end
  local ok, selector = pcall(mod.find, "red_3d_player")
  return ok and selector ~= nil
end

local function externalCameraEnabled()
  local control = optionCameraControl()
  if control == "stadium" then return false end
  local detected = selectorDetected()
  Bridge.selectorDetected = detected
  if control == "selector" then return detected end
  return detected
end

-- 3D Character Selector v3.x changes the engine's public `voxel` pipeline
-- level to select its ZOOM / 1ST / 3RD modes.  This standalone Gold renderer
-- has its own private VoxelState, so without this bridge it would overwrite
-- that choice every frame.  Read the public pipeline label instead of hard-
-- coding rung numbers: upstream voxel mods are free to move the 1ST/3RD rungs.
local function selectorCameraMode()
  if not externalCameraEnabled() then return nil end
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or type(Pipelines) ~= "table" then return nil end
  if type(Pipelines.get) == "function" and not Pipelines.get("voxel") then
    return nil
  end
  if type(Pipelines.level) ~= "function" then return nil end
  local level = Pipelines.level("voxel")
  local label = type(Pipelines.levelLabel) == "function"
    and Pipelines.levelLabel("voxel", level) or tostring(level)
  local upper = tostring(label or ""):upper()
  local mode
  if upper:find("3RD", 1, true) or upper:find("THIRD", 1, true) then
    mode = "third"
  elseif upper:find("1ST", 1, true) or upper:find("FIRST", 1, true) then
    mode = "first"
  else
    -- Character Selector's ordinary ZOOM/orbit state maps to this mod's
    -- diorama camera.  The voxel world remains enabled even if the external
    -- pipeline reports OFF for a transient frame during a mode change.
    mode = "diorama"
  end
  Bridge.externalCameraLevel = level
  Bridge.externalCameraLabel = label
  Bridge.cameraProvider = "red_3d_player"
  return mode
end

-- Shared with FirstPerson/GoldCameraControls.  They still mirror camera input
-- for this renderer, but must pass it through and must not rewrite movement
-- while the Character Selector owns the public camera state.
V.externalCameraOwner = externalCameraEnabled
V.externalCameraPassthrough = externalCameraEnabled

local function optionDioramaTilt()
  -- v0.2.54: Gold's own OPTIONS -> TILT row is the authoritative diorama
  -- camera pitch. The engine stores it as levels OFF/15/35/50 in
  -- game.options.tilt. Previously this mod had a separate DIORAMA TILT option,
  -- which meant changing the real OPTIONS row only warped/zoomed the native
  -- presentation while our voxel camera kept its old pitch. Mirror the native
  -- row directly into the real 3D camera instead.
  local game = Bridge.game
  local native = game and (game.options or (game.save and game.save.options))
  if type(native) == "table" and native.tilt ~= nil then
    local level = math.floor(tonumber(native.tilt) or 0)
    if level < 0 then level = 0 elseif level > 3 then level = 3 end
    -- Gold's native TILT defaults to OFF (level 0) on a fresh install.
    -- While the voxel renderer is explicitly enabled, treating that as a
    -- literal 0-degree voxel camera makes the real 3D terrain appear flat/2D.
    -- OFF therefore means "use the voxel diorama default"; the three explicit
    -- Gold tilt rungs still map 1:1 to 15/35/50 degrees. Turning 3D VOXEL
    -- WORLD off remains the actual way to return to Gold's native 2D world.
    local angles = { 35, 15, 35, 50 }
    return angles[level + 1]
  end

  -- Backward-compatible fallback for a frame before Game2 is bound, or for an
  -- older experimental host. Existing saves that still contain dioramaTilt
  -- continue to get a sensible camera until the native options table arrives.
  local options = mod and mod.options
  if options and type(options.get) == "function" then
    local ok, value = pcall(options.get, options, "dioramaTilt")
    value = ok and tonumber(value) or nil
    if value == 0 or value == 15 or value == 35 or value == 50 or value == 75 then
      return value
    end
  end
  return 35
end

local function optionCameraMode()
  local control = optionCameraControl()
  -- An explicit in-world slider/F6 choice must not be undone one frame later
  -- by AUTO observing red_3d_player's previous public pipeline rung.  Keep the
  -- user's live choice authoritative in AUTO/STADIUM mode.  Choosing CAMERA
  -- CONTROL = CHARACTER SELECTOR explicitly hands ownership back and ignores
  -- this latch, so the compatibility path remains available on demand.
  if control ~= "selector" and Bridge.cameraOverride then
    Bridge.cameraProvider = "stadium-user"
    return normalizeCameraMode(Bridge.cameraOverride)
  end
  local external = selectorCameraMode()

  -- Right-stick LOOK is not a camera-mode selector. Some controller/mod stacks
  -- briefly expose an external voxel pipeline's ordinary/OFF rung while its
  -- right-stick handler is active; accepting that transient read here makes
  -- Gold render native 2D/diorama for exactly as long as the stick is held.
  -- While the free-roam camera is actively consuming analog look, retain the
  -- already-selected 1ST/3RD mode. Explicit slider/F6 changes update
  -- Bridge.cameraMode first, so they are not blocked by this latch.
  local function stickStable(candidate)
    local active = FirstPerson and type(FirstPerson.analogLookActive) == "function"
      and FirstPerson.analogLookActive()
    local current = normalizeCameraMode(Bridge.cameraMode)
    if active and (current == "first" or current == "third")
        and candidate ~= current then
      Bridge.cameraModeStickHolds = (Bridge.cameraModeStickHolds or 0) + 1
      return current
    end
    return candidate
  end

  if external then return stickStable(external) end
  Bridge.cameraProvider = "stadium"
  Bridge.externalCameraLevel = nil
  Bridge.externalCameraLabel = nil
  local ok, value = pcall(mod.options.get, mod.options, "cameraMode")
  if not ok then return stickStable("diorama") end
  return stickStable(normalizeCameraMode(value))
end

local function cameraLevelForMode(mode)
  mode = normalizeCameraMode(mode)
  if mode == "third" then return (Voxel and Voxel.TP_LEVEL) or 7 end
  if mode == "first" then return (Voxel and Voxel.FP_LEVEL) or 6 end
  return (Voxel and Voxel.FULL_LEVEL) or 1
end

Bridge.cameraLevelForMode = cameraLevelForMode
Bridge.normalizeCameraMode = normalizeCameraMode

local function selectorLevelForMode(mode)
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or type(Pipelines) ~= "table"
     or type(Pipelines.levelLabels) ~= "function" then return nil end
  local labels = Pipelines.levelLabels("voxel")
  if type(labels) ~= "table" then return nil end
  mode = normalizeCameraMode(mode)
  local fallback = nil
  for i, label in ipairs(labels) do
    local upper = tostring(label or ""):upper()
    local level = i - 1
    local first = upper:find("1ST", 1, true) or upper:find("FIRST", 1, true)
    local third = upper:find("3RD", 1, true) or upper:find("THIRD", 1, true)
    if mode == "first" and first then return level end
    if mode == "third" and third then return level end
    if mode == "diorama" and level > 0 and not first and not third then
      if upper:find("ZOOM", 1, true) or upper:find("ORBIT", 1, true)
         or upper:find("FULL", 1, true) then
        return level
      end
      fallback = fallback or level
    end
  end
  return fallback
end

local function setSelectorCameraMode(mode)
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not ok or type(Pipelines) ~= "table"
     or type(Pipelines.setLevel) ~= "function" then return false end
  local level = selectorLevelForMode(mode)
  if level == nil then return false end
  local okSet = pcall(Pipelines.setLevel, "voxel", level)
  if not okSet then return false end
  local game = Bridge.game
  if game and game.options and type(Pipelines.syncOptions) == "function" then
    pcall(Pipelines.syncOptions, game.options)
  end
  Bridge.externalCameraLevel = level
  Bridge.cameraProvider = "red_3d_player"
  return true
end

local function setCameraMode(mode, persist)
  mode = normalizeCameraMode(mode)
  Bridge.cameraOverride = mode
  if persist and mod.options and type(mod.options.set) == "function" then
    local ok, result = pcall(mod.options.set, mod.options, "cameraMode", mode)
    if ok and result ~= false then
      -- The public option bucket now owns the value; clear the temporary
      -- override so later Mod Manager changes can be observed normally.
      Bridge.cameraOverride = nil
    end
  end
  Bridge.cameraMode = mode
  Bridge.cameraLevel = cameraLevelForMode(mode)
  return mode
end

function Bridge.selectCameraMode(mode, persist, explicitControl)
  mode = normalizeCameraMode(mode)
  local control = optionCameraControl()

  -- CAMERA CONTROL = CHARACTER SELECTOR is the one mode where the external
  -- public voxel rung is deliberately authoritative.  Everywhere else an
  -- explicit slider/F6 action is a direct command to this renderer.  We still
  -- mirror the requested rung to red_3d_player when possible, but keep a local
  -- latch so AUTO cannot bounce DIORAMA straight back to the old 1ST/3RD rung.
  if control == "selector" and externalCameraEnabled() then
    if setSelectorCameraMode(mode) then
      Bridge.cameraOverride = nil
      Bridge.cameraMode = mode
      Bridge.cameraLevel = cameraLevelForMode(mode)
      return mode
    end
  end

  local result = setCameraMode(mode, persist ~= false)
  if explicitControl then
    Bridge.cameraOverride = mode
    if selectorDetected() then pcall(setSelectorCameraMode, mode) end
    Bridge.cameraProvider = "stadium-user"
  end
  return result
end

function Bridge.cycleCameraMode(persist)
  local current = optionCameraMode()
  return Bridge.selectCameraMode(CAMERA_NEXT[current] or CAMERA_ORDER[1],
    persist ~= false, true)
end

local function frameDt()
  local fallback = 1 / 60
  if not (love and love.timer and type(love.timer.getTime) == "function") then
    return fallback
  end
  local ok, now = pcall(love.timer.getTime)
  now = ok and tonumber(now) or nil
  if not now then return fallback end
  local prev = Bridge.lastTickTime
  Bridge.lastTickTime = now
  if not prev then return fallback end
  return math.max(1 / 240, math.min(1 / 15, now - prev))
end

local function stackTop(game)
  local stack = game and game.stack
  if not (stack and type(stack.top) == "function") then return nil end
  local ok, top = pcall(stack.top, stack)
  if ok then return top end
  return nil
end

local function goldFreeRoam(game)
  local world = game and game.world
  if not (type(world) == "table" and world.map ~= nil) then return false end
  local top = stackTop(game)
  return top == nil or (type(top) == "table" and top._stadiumCaptureOverlay == true)
end

local function fireCameraHotkey(game, fromPoll)
  -- Keep the capture rig stable for the duration of a throw. F6 resumes as
  -- soon as the transparent capture state leaves the stack.
  local top = stackTop(game)
  if top and top._stadiumCaptureOverlay == true then return false end
  if isAndroid() or not voxelModeEnabled() or not goldFreeRoam(game) then
    return false
  end
  local mode = Bridge.cycleCameraMode(true)
  Bridge.cameraHotkeyCycles = Bridge.cameraHotkeyCycles + 1
  if fromPoll then
    Bridge.cameraHotkeyPollCycles = Bridge.cameraHotkeyPollCycles + 1
  end
  local log = mod.log
  if log and type(log.info) == "function" then
    pcall(log.info, log, "Gold voxel camera: %s", tostring(mode))
  end
  return true
end

-- F6 has two independent paths on desktop.  The normal Game2 key callback is
-- lowest latency, while the frame poll below survives another mod replacing or
-- swallowing that callback later in the load order.  Both share one latch so a
-- single physical press can never advance two camera modes.
local function pollCameraHotkey(game)
  if isAndroid() or not (love and love.keyboard
      and type(love.keyboard.isDown) == "function") then
    Bridge.f6Down = false
    return false
  end
  local ok, down = pcall(love.keyboard.isDown, "f6")
  down = ok and down and true or false
  local was = Bridge.f6Down
  Bridge.f6Down = down
  if down and not was then
    return fireCameraHotkey(game, true)
  end
  return false
end

local function installCameraHotkey(game)
  if type(game) ~= "table" then return false end
  if Bridge._hotkeyGame == game then return true end
  if Bridge._hotkeyGame ~= nil then return false end

  local inner = game.keypressed
  game.keypressed = function(self, key, ...)
    if key == "f6" then
      -- Mark the poll latch even if the key was pressed over a menu/battle.
      -- Re-entering free roam while the key is still held must not create a
      -- delayed camera switch.
      Bridge.f6Down = true
      if fireCameraHotkey(self, false) then return end
    end
    if inner then return inner(self, key, ...) end
  end
  Bridge._hotkeyGame = game
  return true
end

Bridge.pollCameraHotkey = pollCameraHotkey

-- v0.3.03: also poll F6 from the engine-owned input.step hook. Newer Gold
-- builds run host hotkeys before Input and other mods can replace Game2's
-- instance key callback after game.ready. The old keypressed wrapper + render
-- poll remain as latency/fallback paths; all three share Bridge.f6Down, so one
-- physical press still advances exactly one camera mode.
local function installCameraStepHotkey()
  if Bridge.cameraStepHotkeyInstalled then return true end
  if not (mod and mod.hooks and type(mod.hooks.wrap) == "function") then
    Bridge.cameraStepHotkeyError = "mod input.step hook unavailable"
    return false
  end
  local ok, err = pcall(mod.hooks.wrap, mod.hooks, "input.step",
    function(nextFn, game, dt)
      pcall(pollCameraHotkey, game)
      return nextFn(game, dt)
    end)
  if not ok then
    Bridge.cameraStepHotkeyError = tostring(err)
    return false
  end
  Bridge.cameraStepHotkeyInstalled = true
  Bridge.cameraStepHotkeyError = nil
  return true
end

local function cameraSliderRect()
  local ox, oy, ww, wh = 0, 0, nil, nil
  if EngineViewportCompat and type(EngineViewportCompat.drawableLogicalRect) == "function" then
    ox, oy, ww, wh = EngineViewportCompat.drawableLogicalRect()
  elseif EngineViewportCompat and type(EngineViewportCompat.logicalDimensions) == "function" then
    ww, wh = EngineViewportCompat.logicalDimensions()
  else
    local G = love and love.graphics
    if not (G and type(G.getDimensions) == "function") then return nil end
    ww, wh = G.getDimensions()
  end
  if not (ww and wh and ww > 0 and wh > 0) then return nil end
  -- Keep the Android camera selector inside the SAME gameplay rectangle the
  -- engine reserved from TouchSkin. On portrait/handheld skins the old full-
  -- window centering could put this control partly over the phone controls.
  local w = math.min(380, math.max(180, ww * 0.42))
  w = math.min(w, math.max(120, ww - 16))
  local h = math.min(70, math.max(56, wh * 0.12))
  return ox + (ww - w) * 0.5, oy + 12, w, h
end

local function optionCameraSlider()
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return true end
  local ok, value = pcall(options.get, options, "cameraSlider")
  if not ok or value == nil then return true end
  return value ~= false
end

local function cameraSliderVisible(game)
  return isAndroid() and voxelModeEnabled() and optionCameraSlider()
     and goldFreeRoam(game or Bridge.game)
end

local function sliderModeAt(x)
  local sx, sy, sw = cameraSliderRect()
  if not sx then return nil end
  local pad = 28
  local left, right = sx + pad, sx + sw - pad
  local t = math.max(0, math.min(1, (x - left) / math.max(1, right - left)))
  local index = math.floor(t * 2 + 0.5) + 1
  return CAMERA_ORDER[math.max(1, math.min(3, index))]
end

local function touchInsideSlider(x, y)
  local sx, sy, sw, sh = cameraSliderRect()
  if not sx then return false end
  return x >= sx - 10 and x <= sx + sw + 10
     and y >= sy - 10 and y <= sy + sh + 12
end

local function installCameraSlider(game)
  if not isAndroid() then return true end
  if type(game) ~= "table" then return false end
  if Bridge._sliderGame == game then return true end
  if Bridge._sliderGame ~= nil then return false end

  local held = {}
  local function apply(x)
    local mode = sliderModeAt(x)
    if not mode then return end
    if optionCameraMode() ~= mode then
      Bridge.selectCameraMode(mode, true, true)
      Bridge.cameraSliderChanges = Bridge.cameraSliderChanges + 1
    end
  end

  do
    local inner = game.touchpressed
    game.touchpressed = function(self, id, x, y, ...)
      if cameraSliderVisible(self) and touchInsideSlider(x, y) then
        held[id] = true
        Bridge.cameraSliderTouches = Bridge.cameraSliderTouches + 1
        apply(x)
        return
      end
      if inner then return inner(self, id, x, y, ...) end
    end
  end

  do
    local inner = game.touchmoved
    game.touchmoved = function(self, id, x, y, ...)
      if held[id] then
        apply(x)
        return
      end
      if inner then return inner(self, id, x, y, ...) end
    end
  end

  do
    local inner = game.touchreleased
    game.touchreleased = function(self, id, x, y, ...)
      if held[id] then
        held[id] = nil
        apply(x)
        return
      end
      if inner then return inner(self, id, x, y, ...) end
    end
  end

  local innerFocus = game.focus
  game.focus = function(self, focused, ...)
    if not focused then held = {} end
    if innerFocus then return innerFocus(self, focused, ...) end
  end

  Bridge._sliderGame = game
  Bridge.cameraSliderInstalled = true
  return true
end


-- Android fallback: poll the live LOVE touch table every render frame.
-- Some Android builds route touches through the engine's overlay/pointer chain
-- in a way that can bypass a late instance-method wrapper. Polling is the
-- authoritative fallback because it observes the physical contacts directly.
local function updateCameraSliderTouches(game)
  if not cameraSliderVisible(game) then
    Bridge._sliderPollId = nil
    return false
  end
  local T = love and love.touch
  if not (T and type(T.getTouches) == "function" and type(T.getPosition) == "function") then
    return false
  end

  local okIds, ids = pcall(T.getTouches)
  if not okIds or type(ids) ~= "table" then return false end

  local active = Bridge._sliderPollId
  if active ~= nil then
    local found = false
    for _, id in ipairs(ids) do
      if id == active then
        found = true
        local okPos, x, y = pcall(T.getPosition, id)
        if okPos and type(x) == "number" and type(y) == "number" then
          if EngineViewportCompat and type(EngineViewportCompat.toLocal) == "function" then
            local lx, ly, inside = EngineViewportCompat.toLocal(x, y)
            if not inside then Bridge._sliderPollId = nil return false end
            x, y = lx, ly
          end
          local mode = sliderModeAt(x)
          if mode and optionCameraMode() ~= mode then
            Bridge.selectCameraMode(mode, true, true)
            Bridge.cameraSliderChanges = Bridge.cameraSliderChanges + 1
          end
        end
        break
      end
    end
    if not found then Bridge._sliderPollId = nil end
    return found
  end

  -- Capture only a touch that is currently inside the visible slider.  The
  -- virtual GB controls live at the bottom of the screen, so this never steals
  -- their contacts; touches elsewhere remain normal game/look/pinch input.
  for _, id in ipairs(ids) do
    local okPos, x, y = pcall(T.getPosition, id)
    if okPos and type(x) == "number" and type(y) == "number" then
      if EngineViewportCompat and type(EngineViewportCompat.toLocal) == "function" then
        local lx, ly, inside = EngineViewportCompat.toLocal(x, y)
        if inside then x, y = lx, ly else x, y = nil, nil end
      end
    end
    if type(x) == "number" and type(y) == "number"
       and touchInsideSlider(x, y) then
      Bridge._sliderPollId = id
      Bridge.cameraSliderTouches = Bridge.cameraSliderTouches + 1
      local mode = sliderModeAt(x)
      if mode and optionCameraMode() ~= mode then
        Bridge.selectCameraMode(mode, true, true)
        Bridge.cameraSliderChanges = Bridge.cameraSliderChanges + 1
      end
      return true
    end
  end
  return false
end

Bridge.updateCameraSliderTouches = updateCameraSliderTouches

-- v0.2.00 Android right-thumb look fallback. The camera-mode slider proved
-- that some Android builds do not reliably deliver late Game2 touch wrappers,
-- so camera look observes LOVE's physical touch table directly as well. Only a
-- free touch on the right side is claimed; overlay controls and the camera
-- slider are ignored. Two simultaneous FREE right-side touches are left alone
-- for pinch zoom. This feeds FirstPerson.lookBy, the same yaw/pitch used by
-- both the 1ST/3RD free-roam camera and Gold's live-overworld battle shot.
local function updateRightLookTouches(game, battleActive)
  if not isAndroid() or not voxelModeEnabled() then
    Bridge._rightLookPollId = nil
    Bridge._rightLookPollX, Bridge._rightLookPollY = nil, nil
    return false
  end

  local mode = optionCameraMode()
  if mode ~= "first" and mode ~= "third" then
    Bridge._rightLookPollId = nil
    Bridge._rightLookPollX, Bridge._rightLookPollY = nil, nil
    return false
  end

  -- In free roam require the world to be the active view. During a live-world
  -- battle the battle state is intentionally on the stack, so battleActive is
  -- the explicit permission for the same camera to keep steering.
  if not battleActive and not goldFreeRoam(game or Bridge.game) then
    Bridge._rightLookPollId = nil
    Bridge._rightLookPollX, Bridge._rightLookPollY = nil, nil
    return false
  end

  local T = love and love.touch
  if not (T and type(T.getTouches) == "function" and type(T.getPosition) == "function") then
    return false
  end
  local okIds, ids = pcall(T.getTouches)
  if not okIds or type(ids) ~= "table" then return false end
  local drawX, drawY, ww, wh = 0, 0, nil, nil
  if EngineViewportCompat and type(EngineViewportCompat.drawableLogicalRect) == "function" then
    drawX, drawY, ww, wh = EngineViewportCompat.drawableLogicalRect()
  elseif EngineViewportCompat and type(EngineViewportCompat.logicalDimensions) == "function" then
    ww, wh = EngineViewportCompat.logicalDimensions()
  else
    ww, wh = love.graphics.getDimensions()
  end

  local TouchControls = nil
  pcall(function() TouchControls = require("src.core.TouchControls") end)
  local function controlAt(x, y)
    if not (TouchControls and type(TouchControls.hitTest) == "function") then return nil end
    local ok, hit = pcall(TouchControls.hitTest, TouchControls, x, y)
    return ok and hit or nil
  end
  local function freeRight(id)
    local ok, rawX, rawY = pcall(T.getPosition, id)
    if not ok or type(rawX) ~= "number" or type(rawY) ~= "number" then return nil end
    -- TouchControls is OS-window chrome in current Gen1Recomp, so hit-test it
    -- in raw window coordinates before converting the game touch to viewport
    -- local space for camera steering.
    if controlAt(rawX, rawY) then return nil end
    local x, y = rawX, rawY
    if EngineViewportCompat and type(EngineViewportCompat.toLocal) == "function" then
      local lx, ly, inside = EngineViewportCompat.toLocal(rawX, rawY)
      if not inside then return nil end
      x, y = lx, ly
    end
    -- GameViewport.toLocal only removes the outer layout offset. TouchSkin may
    -- reserve a second rectangle for the actual game picture; right-look must
    -- ignore the phone-control surround and measure sensitivity against that
    -- drawable, not against the full Android window.
    if x < drawX or y < drawY or x >= drawX + ww or y >= drawY + wh then return nil end
    if (x - drawX) < ww * 0.45 then return nil end
    if cameraSliderVisible(game or Bridge.game) and touchInsideSlider(x, y) then return nil end
    return x, y
  end

  local candidates = {}
  for _, id in ipairs(ids) do
    local x, y = freeRight(id)
    if x then candidates[#candidates + 1] = { id = id, x = x, y = y } end
  end

  -- Two free fingers on the look side are a pinch gesture, not a camera turn.
  if #candidates > 1 then
    Bridge._rightLookPollId = nil
    Bridge._rightLookPollX, Bridge._rightLookPollY = nil, nil
    return false
  end
  if #candidates == 0 then
    Bridge._rightLookPollId = nil
    Bridge._rightLookPollX, Bridge._rightLookPollY = nil, nil
    return false
  end

  local c = candidates[1]
  if Bridge._rightLookPollId ~= c.id then
    Bridge._rightLookPollId = c.id
    Bridge._rightLookPollX, Bridge._rightLookPollY = c.x, c.y
    return true
  end

  local px, py = Bridge._rightLookPollX or c.x, Bridge._rightLookPollY or c.y
  local dx, dy = c.x - px, c.y - py
  Bridge._rightLookPollX, Bridge._rightLookPollY = c.x, c.y
  if dx ~= 0 or dy ~= 0 then
    -- Match FirstPerson's mobile-shooter convention: drag right looks right,
    -- drag up looks up. Scale by actual screen dimensions so sensitivity is
    -- stable from phones to tablets.
    local yaw = -(dx / math.max(320, ww)) * (2.2 * math.pi)
    local pitch = (dy / math.max(240, wh)) * (2.2 * math.pi)
    if battleActive then
      local okCam, BattleCinematic = pcall(V.require, "BattleCinematic")
      if okCam and BattleCinematic and type(BattleCinematic.manualLook) == "function" then
        BattleCinematic.manualLook(yaw, pitch)
      else
        FirstPerson.lookBy(yaw, pitch)
      end
    else
      FirstPerson.lookBy(yaw, pitch)
    end
    Bridge.rightLookFrames = (Bridge.rightLookFrames or 0) + 1
  end
  return true
end

Bridge.updateRightLookTouches = updateRightLookTouches

-- Direct Android pinch poll for DIORAMA. The callback-based pinch recognizer
-- is kept for desktop/debug hosts, but real Android builds have already shown
-- that late Game2 touch wrappers are not reliable enough. This watches LOVE's
-- physical contacts directly and changes the continuous diorama camera distance.
local function updateDioramaPinchTouches(game)
  if not isAndroid() or not voxelModeEnabled() or optionCameraMode() ~= "diorama"
     or not goldFreeRoam(game or Bridge.game) then
    Bridge._dioramaPinchA, Bridge._dioramaPinchB = nil, nil
    Bridge._dioramaPinchGap = nil
    return false
  end
  local T = love and love.touch
  if not (T and type(T.getTouches) == "function" and type(T.getPosition) == "function") then
    return false
  end
  local okIds, ids = pcall(T.getTouches)
  if not okIds or type(ids) ~= "table" then return false end
  local TouchControls = nil
  pcall(function() TouchControls = require("src.core.TouchControls") end)
  local drawX, drawY, drawW, drawH = 0, 0, nil, nil
  if EngineViewportCompat and type(EngineViewportCompat.drawableLogicalRect) == "function" then
    drawX, drawY, drawW, drawH = EngineViewportCompat.drawableLogicalRect()
  elseif EngineViewportCompat and type(EngineViewportCompat.logicalDimensions) == "function" then
    drawW, drawH = EngineViewportCompat.logicalDimensions()
  else
    drawW, drawH = love.graphics.getDimensions()
  end
  local function free(id)
    local ok, rawX, rawY = pcall(T.getPosition, id)
    if not ok or type(rawX) ~= "number" or type(rawY) ~= "number" then return nil end
    if TouchControls and type(TouchControls.hitTest) == "function" then
      local okHit, hit = pcall(TouchControls.hitTest, TouchControls, rawX, rawY)
      if okHit and hit then return nil end
    end
    local x, y = rawX, rawY
    if EngineViewportCompat and type(EngineViewportCompat.toLocal) == "function" then
      local lx, ly, inside = EngineViewportCompat.toLocal(rawX, rawY)
      if not inside then return nil end
      x, y = lx, ly
    end
    if drawW and drawH
       and (x < drawX or y < drawY or x >= drawX + drawW or y >= drawY + drawH) then
      return nil
    end
    if cameraSliderVisible(game or Bridge.game) and touchInsideSlider(x, y) then return nil end
    return { id=id, x=x, y=y }
  end
  local freeTouches = {}
  for _, id in ipairs(ids) do
    local c = free(id)
    if c then freeTouches[#freeTouches+1] = c end
  end
  if #freeTouches < 2 then
    Bridge._dioramaPinchA, Bridge._dioramaPinchB = nil, nil
    Bridge._dioramaPinchGap = nil
    return false
  end
  local a, b = freeTouches[1], freeTouches[2]
  local dx, dy = a.x-b.x, a.y-b.y
  local gap = math.sqrt(dx*dx + dy*dy)
  if gap < 16 then return false end
  if Bridge._dioramaPinchA ~= a.id or Bridge._dioramaPinchB ~= b.id
     or not Bridge._dioramaPinchGap then
    Bridge._dioramaPinchA, Bridge._dioramaPinchB = a.id, b.id
    Bridge._dioramaPinchGap = gap
    return true
  end
  local factor = gap / math.max(1, Bridge._dioramaPinchGap)
  Bridge._dioramaPinchGap = gap
  if math.abs(factor - 1) > 0.008 then
    local okZoom, DioramaZoom = pcall(V.require, "DioramaZoom")
    if okZoom and DioramaZoom and type(DioramaZoom.scaleBy) == "function" then
      DioramaZoom.scaleBy(1 / factor)
      Bridge.dioramaPinchFrames = (Bridge.dioramaPinchFrames or 0) + 1
      return true
    end
  end
  return false
end

Bridge.updateDioramaPinchTouches = updateDioramaPinchTouches

function Bridge.drawCameraSlider(ctx)
  local game = Bridge.game
  if not cameraSliderVisible(game) then return false end
  local G = love and love.graphics
  if not G then return false end
  local sx, sy, sw, sh = cameraSliderRect()
  if not sx then return false end
  local pad = 28
  local left, right = sx + pad, sx + sw - pad
  local trackY = sy + 38
  local mode = optionCameraMode()
  local idx = (mode == "third" and 2) or (mode == "first" and 3) or 1
  local thumbX = left + (idx - 1) * (right - left) / 2
  local labels = { "DIORAMA", "3RD", "1ST" }

  local ok = pcall(function()
    G.push("all")
    G.origin()
    G.setBlendMode("alpha")
    G.setColor(0, 0, 0, 0.58)
    G.rectangle("fill", sx, sy, sw, sh, 12, 12)
    G.setColor(1, 1, 1, 0.20)
    G.rectangle("line", sx, sy, sw, sh, 12, 12)
    G.setColor(1, 1, 1, 0.45)
    G.setLineWidth(4)
    G.line(left, trackY, right, trackY)
    for i = 1, 3 do
      local px = left + (i - 1) * (right - left) / 2
      G.setColor(1, 1, 1, 0.72)
      G.circle("fill", px, trackY, 5)
    end
    G.setColor(1, 1, 1, 1)
    G.circle("fill", thumbX, trackY, 11)
    G.setColor(0, 0, 0, 0.82)
    G.circle("fill", thumbX, trackY, 5)

    local font = type(G.getFont) == "function" and G.getFont() or nil
    for i, label in ipairs(labels) do
      local px = left + (i - 1) * (right - left) / 2
      local tw = font and font:getWidth(label) or (#label * 6)
      G.setColor(1, 1, 1, i == idx and 1 or 0.68)
      G.print(label, math.floor(px - tw / 2), sy + 7)
    end
    G.pop()
  end)
  if not ok then pcall(G.pop) return false end
  return true
end

Bridge.cameraSliderVisible = cameraSliderVisible
Bridge.cameraSliderRect = cameraSliderRect

local function bindGame(game)
  if type(game) ~= "table" then return false end
  Bridge.game = game
  V.game = game
  installCameraHotkey(game)
  if FirstPerson and type(FirstPerson.install) == "function"
     and not Bridge.cameraInputInstalled then
    local ok, result, err = pcall(FirstPerson.install, game)
    if ok and result ~= false then
      Bridge.cameraInputInstalled = true
      Bridge.cameraInputError = nil
    else
      Bridge.cameraInputError = tostring(ok and err or result)
      logOnce("camera-input:" .. Bridge.cameraInputError, "warn",
        "Gold first/third-person camera input hooks unavailable: %s",
        Bridge.cameraInputError)
    end
  end
  -- Install the shared camera input owner AFTER FirstPerson, as CamControl's
  -- wraps are intentionally the outer layer. This activates two-finger pinch
  -- zoom on the voxel world without letting the same gesture also become a
  -- first/third-person look drag. It also keeps wheel/pad zoom routing in one
  -- place instead of adding a Gold-only touch implementation.
  if CamControl and type(CamControl.install) == "function"
     and not Bridge.pinchZoomInstalled then
    local ok, result, err = pcall(CamControl.install, game)
    if ok and result ~= false then
      Bridge.pinchZoomInstalled = true
      Bridge.pinchZoomError = nil
    else
      Bridge.pinchZoomError = tostring(ok and err or result)
      logOnce("pinch-zoom:" .. Bridge.pinchZoomError, "warn",
        "Gold voxel pinch-zoom hooks unavailable: %s",
        Bridge.pinchZoomError)
    end
  end

  if not Bridge.cameraSliderInstalled then
    local okSlider, sliderResult = pcall(installCameraSlider, game)
    if not okSlider or sliderResult == false then
      logOnce("camera-slider-install", "warn",
        "Gold Android camera-mode slider unavailable")
    end
  end

  if GoldCameraControls and type(GoldCameraControls.install) == "function"
     and not Bridge.cameraMovementInstalled then
    local ok, result, err = pcall(GoldCameraControls.install)
    if ok and result ~= false then
      Bridge.cameraMovementInstalled = true
      Bridge.cameraMovementError = nil
    else
      Bridge.cameraMovementError = tostring(ok and err or result)
      logOnce("camera-movement:" .. Bridge.cameraMovementError, "warn",
        "Gold camera-relative movement hook unavailable: %s",
        Bridge.cameraMovementError)
    end
  end
  return true
end

function Bridge.setGame(game)
  return bindGame(game)
end

logOnce = function(key, level, fmt, ...)
  Bridge._logged = Bridge._logged or {}
  if Bridge._logged[key] then return end
  Bridge._logged[key] = true
  local log = mod.log
  local fn = log and log[level]
  if type(fn) == "function" then pcall(fn, log, fmt, ...) end
end

local function ensurePlayerPose()
  -- Requiring the explicit Gen-2 class is intentional here: this is a Gen-2
  -- only package and VoxelScene consumes the entity pose contract directly.
  local okPlayer, Player = pcall(require, "src.world.gen2.Player")
  if not okPlayer or type(Player) ~= "table" then
    return false, tostring(Player or "Gen-2 Player unavailable")
  end
  if not Player._stadium2VoxelPosePatched then
    local nativePose = type(Player.pose) == "function" and Player.pose or nil
    Player.pose = function(self)
      local sprite, vx, vy, facing, phase, flip, extra
      if nativePose then
        sprite, vx, vy, facing, phase, flip, extra = nativePose(self)
      else
        sprite = self.sprite
        vx = self.px
        vy = self.py + (self.spriteYOffset or 0)
        facing = self.facing
        flip = self.stepFlip == true
      end

      -- The voxel card must use the same live leg frame as Gold/Silver's 2D
      -- Player:draw path.  Older bridges accepted a stale/standing phase from
      -- pose(), which made the 2D trainer slide through DIORAMA/3RD PERSON.
      if type(self.walkPhase) == "function" then
        local okPhase, livePhase = pcall(self.walkPhase, self)
        if okPhase and livePhase ~= nil then phase = livePhase end
      end
      phase = tonumber(phase) or 0
      flip = flip == true or self.stepFlip == true

      -- Silver and Gold both use the six-frame trainer sheet.  If an older
      -- generated sprite definition omitted the `walker` hint, SpriteRenderer
      -- quite correctly stayed on STAND even though phase was changing.  Mark
      -- only the Gen-2 PLAYER renderer as a walker; NPC/icon definitions are
      -- untouched.
      local def = sprite and sprite.def
      if type(def) == "table" and (tonumber(def.frames) or 1) > 1 then
        def.walker = true
      end

      return sprite, vx or self.px, vy or (self.py + (self.spriteYOffset or 0)),
        facing or self.facing, phase, flip, extra
    end
    Player._stadium2VoxelPosePatched = true
  end
  return true
end

-- Gold keys generated tilesets with engine constants such as
-- `TILESET_JOHTO`, while Dramatic Shapes' authored voxel profile predates
-- that cache vocabulary and is keyed as `TilesetJohto`.  The tileset object
-- itself is returned by World:atlasFor and can therefore carry the engine
-- key in `id`; passing that straight through makes every authored Gen-2
-- shape silently miss and fall back to generic solid boxes.
--
-- Translate only the engine's TILESET_* spelling.  Gen-1 ids (OVERWORLD,
-- FOREST, etc.) and already-canonical Gen-2 ids are returned unchanged.
local function profileTilesetId(raw)
  if type(raw) ~= "string" or raw:sub(1, 8) ~= "TILESET_" then
    return raw
  end
  local out = { "Tileset" }
  for word in raw:sub(9):gmatch("[^_]+") do
    local lower = word:lower()
    out[#out + 1] = lower:sub(1, 1):upper() .. lower:sub(2)
  end
  return table.concat(out)
end

-- Exposed for the headless compatibility probe; harmless to runtime callers.
Bridge.profileTilesetId = profileTilesetId

local function attachRenderer(world, map)
  if not (world and map and map.def) then
    return false, "Gold map/definition not ready"
  end
  if type(world.atlasFor) ~= "function" then
    return false, "Gold World:atlasFor is unavailable"
  end

  -- Voxel terrain UVs sample a TILESET ATLAS, not Gold's already-baked whole
  -- map canvas. Reuse World:atlasFor so roofs/asset overrides resolve through
  -- the exact same live Gen-2 path as vanilla Gold.
  local ok, atlas, tileset = pcall(world.atlasFor, world, map.def)
  if not ok then return false, "Gold atlasFor failed: " .. tostring(atlas) end
  if not atlas then return false, "Gold atlasFor returned no tileset atlas" end

  map.tileset = tileset or map.tileset

  -- IMPORTANT: map.def.tileset remains the engine key (for example
  -- TILESET_JOHTO); only the tileset record's presentation id is normalised
  -- for the voxel modules.  Gen1Recomp itself indexes world.tilesets by
  -- map.def.tileset, so changing this field does not disturb the engine's
  -- lookup, while TileShape/Structures/Buildings can finally find their
  -- authored Gen-2 profile rows.
  if map.tileset then
    local engineId = map.def.tileset or map.tileset.id
    local profileId = profileTilesetId(engineId)
    if profileId then
      map.tileset._stadiumEngineTilesetId =
        map.tileset._stadiumEngineTilesetId or map.tileset.id or engineId
      map.tileset.id = profileId
    end
  end

  map.renderer = map.renderer or {}
  map.renderer.data = (world.game and world.game.data) or map.renderer.data

  -- Gold's generated tileset sheet is intentionally four-shade source art.
  -- The native 2D renderer assigns one of eight GBC palettes PER 8x8 tile at
  -- draw/bake time. Voxel geometry samples the atlas directly, so feeding it
  -- World:atlasFor's raw sheet produces a correct-but-monochrome world. Bake
  -- that same Gen-2 PalMap into a private atlas before the voxel mesh sees it.
  if not GoldColorAtlas then
    local okColor, moduleOrErr = pcall(V.require, "GoldColorAtlas")
    if okColor and type(moduleOrErr) == "table" then
      GoldColorAtlas = moduleOrErr
    else
      logOnce("gold-color-module:" .. tostring(moduleOrErr), "warn",
        "Gold voxel GBC-color adapter unavailable; raw atlas fallback: %s",
        tostring(moduleOrErr))
    end
  end

  local image, pixels, colored, colorErr, colorKey = atlas, nil, false, nil, nil
  if GoldColorAtlas and type(GoldColorAtlas.forMap) == "function" then
    local okColor, a, b, c, d, e = pcall(GoldColorAtlas.forMap, world, map, atlas)
    if okColor then
      image, pixels, colored, colorErr, colorKey = a or atlas, b, c == true, d, e
    else
      colorErr = tostring(a)
    end
  end

  map.renderer.image = image or atlas
  map.renderer.gbcAtlas = colored == true
  map.renderer._stadiumAtlasData = colored and pixels or nil
  map.renderer._stadiumColorKey = colored and colorKey or nil
  map.renderer._stadiumGen2Color = colored == true
  if not colored and colorErr then
    logOnce("gold-color-fallback:" .. tostring(colorErr), "warn",
      "Gold voxel color atlas fell back to raw source art: %s", tostring(colorErr))
  end
  return true
end

-- Gold's native 2D renderer keeps connected areas as lightweight image records
-- (`{ id, ox, oy, image }`).  VoxelScene needs actual Map objects so it can
-- mesh the next area before the player crosses the seam.  v0.2.04 adapts the
-- DIRECT connection in each cardinal direction -- one whole map ahead -- and
-- keeps those maps warm as body-only neighbour meshes.  This is intentionally
-- a renderer-side adapter: Gold's own map transition/collision code remains the
-- authority and is never replaced.
local CARDINAL_CONNECTIONS = { "north", "south", "west", "east" }
local EDGE_URGENT_CELLS = 8

local function goldMapModule()
  if GoldMap then return GoldMap end
  local ok, Map = pcall(require, "src.world.gen2.Map")
  if ok and type(Map) == "table" and type(Map.new) == "function" then
    GoldMap = Map
    return GoldMap
  end
  return nil
end

local function nativeNeighborIndex(world)
  local native = {}
  for _, nb in ipairs(world and world.neighbors or {}) do
    if nb and nb.id then native[nb.id] = nb end
  end
  return native
end

local function connectionPlacement(sourceDef, targetDef, conn, dir, sourceOx, sourceOy)
  local offset = tonumber(conn and conn.offset) or 0
  sourceOx, sourceOy = tonumber(sourceOx) or 0, tonumber(sourceOy) or 0
  if dir == "north" then
    return sourceOx + offset * 32, sourceOy - targetDef.height * 32
  elseif dir == "south" then
    return sourceOx + offset * 32, sourceOy + sourceDef.height * 32
  elseif dir == "west" then
    return sourceOx - targetDef.width * 32, sourceOy + offset * 32
  else -- east
    return sourceOx + sourceDef.width * 32, sourceOy + offset * 32
  end
end

local function directNeighborSpecs(world)
  local root = world and world.map and world.map.def
  local maps = world and world.maps
  if not (root and maps) then return {} end

  local native = nativeNeighborIndex(world)
  local out, seen = {}, {}
  for _, dir in ipairs(CARDINAL_CONNECTIONS) do
    local conn = root.connections and root.connections[dir]
    local id = conn and (conn.mapId or conn.map)
    local def = id and maps[id] or nil
    if def and not seen[id] then
      seen[id] = true
      local n = native[id]
      local ox, oy = n and tonumber(n.ox), n and tonumber(n.oy)
      if not (ox and oy) then
        ox, oy = connectionPlacement(root, def, conn, dir, 0, 0)
      end
      out[#out + 1] = {
        id = id, dir = dir, ox = ox, oy = oy, native = n, depth = 1,
        parentId = world.map.id or root.id,
      }
    end
  end
  return out
end

local function neighborUrgent(world, dir)
  local p = world and world.player
  local def = world and world.map and world.map.def
  if not (p and def) then return false end
  local x, y = tonumber(p.cellX), tonumber(p.cellY)
  if not (x and y) then return false end
  local w, h = (tonumber(def.width) or 0) * 2, (tonumber(def.height) or 0) * 2
  if dir == "north" then return y <= EDGE_URGENT_CELLS end
  if dir == "south" then return y >= h - 1 - EDGE_URGENT_CELLS end
  if dir == "west" then return x <= EDGE_URGENT_CELLS end
  if dir == "east" then return x >= w - 1 - EDGE_URGENT_CELLS end
  return false
end

local function placementRect(def, ox, oy)
  if not def then return nil end
  ox, oy = tonumber(ox) or 0, tonumber(oy) or 0
  return {
    x1 = ox, y1 = oy,
    x2 = ox + (tonumber(def.width) or 0) * 32,
    y2 = oy + (tonumber(def.height) or 0) * 32,
  }
end

local function placementOverlap(a, b)
  if not (a and b) then return 0 end
  local w = math.min(a.x2, b.x2) - math.max(a.x1, b.x1)
  local h = math.min(a.y2, b.y2) - math.max(a.y1, b.y1)
  if w <= 0 or h <= 0 then return 0 end
  return w * h
end

local function overlapsPlaced(rect, placed, exceptId)
  for id, other in pairs(placed or {}) do
    if id ~= exceptId and placementOverlap(rect, other.rect) > 0 then
      return id, other
    end
  end
  return nil
end

-- OPEN WORLD walks every map reachable through Gold's cardinal connection
-- table and solves each map into one coordinate space rooted at the CURRENT
-- map. Doors, caves and buildings reached by warps are intentionally excluded:
-- they are not physically adjacent terrain and must not be glued into the
-- outdoor plane. Breadth-first order queues direct areas first, then farther
-- rings, so the nearby world becomes ready while the rest builds in background.
local function allConnectedNeighborSpecs(world)
  local rootMap = world and world.map
  local root = rootMap and rootMap.def
  local maps = world and world.maps
  if not (rootMap and root and maps) then return {} end
  local rootId = rootMap.id or root.id

  if openWorldGraphCache.rootId == rootId
      and openWorldGraphCache.maps == maps
      and type(openWorldGraphCache.specs) == "table" then
    return openWorldGraphCache.specs
  end

  local native = nativeNeighborIndex(world)
  local out, seen = {}, { [rootId] = true }
  local placed = {
    [rootId] = { id = rootId, def = root, ox = 0, oy = 0,
      rect = placementRect(root, 0, 0) },
  }
  local queue = { { id = rootId, def = root, ox = 0, oy = 0, depth = 0 } }
  local head = 1
  while head <= #queue do
    local source = queue[head]
    head = head + 1
    for _, dir in ipairs(CARDINAL_CONNECTIONS) do
      local conn = source.def.connections and source.def.connections[dir]
      local id = conn and (conn.mapId or conn.map)
      local def = id and maps[id] or nil
      if def and not seen[id] then
        local ox, oy
        -- Gold's own neighbour builder is the coordinate authority whenever it
        -- already knows this map (it keeps more than the immediate ring warm).
        -- v0.2.45-v0.2.56 only trusted native offsets at depth 1, then solved
        -- deeper maps independently; on some connection loops that let a far
        -- map land on TOP of the current map. Collision stayed correct because
        -- Gold still owned movement, but the overlapping voxel mesh painted a
        -- different road/grass layout under the player: the "invisible road"
        -- failure reported in v0.2.56.
        local n = native[id]
        if n then ox, oy = tonumber(n.ox), tonumber(n.oy) end
        if not (ox and oy) then
          ox, oy = connectionPlacement(source.def, def, conn, dir,
                                       source.ox, source.oy)
        end

        local rect = placementRect(def, ox, oy)
        local clashId = overlapsPlaced(rect, placed, id)
        if clashId then
          -- Cardinally stitched map BODIES may touch at an edge but should not
          -- occupy the same world pixels. Skip an inconsistent placement rather
          -- than allowing a far map to visually overwrite the collision-authority
          -- current map. Leaving it unseen lets another graph path place it later.
          Bridge.openWorldOverlapRejects = (Bridge.openWorldOverlapRejects or 0) + 1
          if logOnce then
            logOnce(("open-world-overlap:%s:%s:%s"):format(tostring(rootId),
                tostring(id), tostring(clashId)), "warn",
              "OPEN WORLD skipped overlapping map placement %s over %s",
              tostring(id), tostring(clashId))
          end
        else
          local rec = {
            id = id, dir = dir, ox = ox, oy = oy, depth = source.depth + 1,
            parentId = source.id,
          }
          out[#out + 1] = rec
          seen[id] = true
          placed[id] = { id = id, def = def, ox = ox, oy = oy, rect = rect }
          queue[#queue + 1] = {
            id = id, def = def, ox = ox, oy = oy, depth = rec.depth,
          }
        end
      end
    end
  end

  openWorldGraphCache = { rootId = rootId, maps = maps, specs = out }
  Bridge.openWorldGraphBuilds = Bridge.openWorldGraphBuilds + 1
  Bridge.openWorldGraphRoot = rootId
  Bridge.openWorldGraphError = nil
  return out
end

-- Internal probes used by the release regression suite. They are intentionally
-- underscored and do not participate in the public mod API.
Bridge._allConnectedNeighborSpecs = allConnectedNeighborSpecs
Bridge._placementOverlap = placementOverlap

local function adaptedNeighborMap(world, id)
  local maps, tilesets = world and world.maps, world and world.tilesets
  local def = maps and maps[id]
  local sourceTileset = def and tilesets and tilesets[def.tileset]
  local Map = goldMapModule()
  if not (def and sourceTileset and Map) then
    return nil, "missing Gold neighbour map/tileset adapter data"
  end

  local hit = neighborMapCache[id]
  if not hit or hit.def ~= def or hit.sourceTileset ~= sourceTileset
      or hit.blocks ~= def.blocks then
    local ok, map = pcall(Map.new, def, sourceTileset)
    if not ok or type(map) ~= "table" then
      return nil, "Gold neighbour Map.new failed: " .. tostring(map)
    end
    hit = { map = map, def = def, sourceTileset = sourceTileset, blocks = def.blocks }
    neighborMapCache[id] = hit
  end

  local ok, err = attachRenderer(world, hit.map)
  if not ok then return nil, err end
  return hit.map
end

local function adaptedNeighbors(world)
  local openWorld = effectiveOpenWorld()
  -- Read the public options every rendered frame, then apply them as a residency
  -- mode change. v0.2.45 accidentally crashed below before this could produce
  -- a valid voxel state, which made ON/OFF look identical in game.
  applyOpenWorldMode(openWorld)

  local specs
  if openWorld then
    local ok, result = pcall(allConnectedNeighborSpecs, world)
    if ok and type(result) == "table" then
      specs = result
      Bridge.openWorldGraphError = nil
    else
      Bridge.openWorldFallbacks = Bridge.openWorldFallbacks + 1
      Bridge.openWorldGraphError = tostring(result)
      specs = directNeighborSpecs(world)
      logOnce("open-world-graph:" .. tostring(result), "warn",
        "OPEN WORLD graph build failed; using direct-map streaming this frame: %s",
        tostring(result))
    end
  else
    specs = directNeighborSpecs(world)
  end

  local out, byId, direct = {}, {}, {}
  local native = nativeNeighborIndex(world)
  for _, spec in ipairs(specs) do
    local map, err = adaptedNeighborMap(world, spec.id)
    if map then
      local depth = tonumber(spec.depth) or 1
      local rec = {
        id = spec.id, map = map, ox = spec.ox, oy = spec.oy, dir = spec.dir,
        depth = depth, parentId = spec.parentId,
        -- Only a directly connected destination near the player gets urgent
        -- build time. Far maps stay cooperative background jobs so OPEN WORLD
        -- never starves the terrain currently under the player.
        urgent = depth == 1 and neighborUrgent(world, spec.dir) or false,
      }
      out[#out + 1] = rec
      byId[spec.id] = rec
      if depth == 1 then
        direct[#direct + 1] = rec
        local n = native[spec.id]
        if n then n.map = map end
      end
    else
      logOnce("neighbor-adapt:" .. tostring(spec.id) .. ":" .. tostring(err),
        "warn", "Gold connected-map voxel adapter skipped %s: %s",
        tostring(spec.id), tostring(err))
    end
  end

  -- v0.2.82: a separately imported Gen-1 cache may contribute a second,
  -- visual-only Kanto connection graph east of Gold. It enters the SAME
  -- neighbor list, so ChunkMesher/VoxelScene treat it as ordinary voxel land
  -- and all existing terrain/structure behavior remains centralized.
  if openWorld and TwinRegionWorld
      and type(TwinRegionWorld.regionRecords) == "function" then
    local okRegion, foreign = pcall(TwinRegionWorld.regionRecords, world, out)
    if okRegion and type(foreign) == "table" then
      for _, rec in ipairs(foreign) do
        if rec and rec.map then
          out[#out + 1] = rec
          byId[rec.id or rec.map.id] = rec
        end
      end
    elseif not okRegion then
      logOnce("gen1-region:" .. tostring(foreign), "warn",
        "GEN-1 KANTO REGION could not join the voxel world this frame: %s",
        tostring(foreign))
    end
  end

  Bridge.openWorldMaps = openWorld and (#out + 1) or 0
  Bridge.openWorldDirectMaps = #direct
  return out, byId, direct
end

local function adaptedGhosts(world, byId)
  local out = {}
  for _, g in ipairs(world and world.ghosts or {}) do
    local id = (g.map and g.map.id) or (g.npc and g.npc.mapId)
    local nb = id and byId[id]
    if nb and g.npc then
      out[#out + 1] = {
        npc = g.npc, map = nb.map, ox = nb.ox, oy = nb.oy, peers = g.peers,
      }
    end
  end
  return out
end

local function currentMasks(neighbors)
  local masks = {}
  for _, nb in ipairs(neighbors or {}) do
    -- OPEN WORLD carries far maps here too. Only first-ring maps can overlap
    -- the current map's border apron, so only they participate in mask tests.
    if (nb.depth == nil or nb.depth <= 1) and nb.map and nb.map.def then
      masks[#masks + 1] = {
        nb.ox, nb.oy,
        nb.ox + nb.map.def.width * 32,
        nb.oy + nb.map.def.height * 32,
      }
    end
  end
  return masks
end

local function mergedEntities(world)
  local out, seen = {}, {}
  local function add(e)
    if type(e) == "table" and not seen[e] then
      seen[e] = true
      out[#out + 1] = e
    end
  end

  -- VoxelScene expects all standing actors in state.entities.  Gold keeps the
  -- player and native NPCs separately, so include them explicitly rather than
  -- relying on the Gen-1 World.entities convention.
  add(world.player)
  if type(world.npcs) == "table" then
    for _, e in ipairs(world.npcs) do add(e) end
  end
  if type(world.entities) == "table" then
    for _, e in ipairs(world.entities) do add(e) end
  end

  -- Fly Your Pokemon owns a presentation-only mount entity. Gold can rebuild
  -- its auxiliary entity list during a seamless map handoff; explicitly merge
  -- the active mount as well so the trainer can never cross a seam while the
  -- Stadium Pokemon underneath vanishes for a frame (or permanently if a
  -- provider replaced the list). add() de-duplicates the normal case.
  local fly = V and V.mod and V.mod.exports and V.mod.exports.flyYourPokemon
  local flyState = type(fly) == "table" and fly.state or nil
  if flyState and flyState.world == world and flyState.mountEntity
      and flyState.mountRenderActive == true then
    add(flyState.mountEntity)
  end

  Bridge.extraEntitiesMerged = 0
  local provider = Bridge.extraEntitiesProvider
  if type(provider) == "function" then
    local ok, extra = pcall(provider, world)
    if ok and type(extra) == "table" then
      local before = #out
      for _, e in ipairs(extra) do add(e) end
      Bridge.extraEntitiesMerged = #out - before
    elseif not ok then
      local err = "visible Wilds provider failed: " .. tostring(extra)
      Bridge.lastError = err
      logOnce("extra-entities:" .. tostring(extra), "warn",
        "Gold visible-Wilds voxel entity provider failed: %s", tostring(extra))
    end
  end
  return out
end

local function directKantoNeighbors(state)
  if type(state) ~= "table" then return {}, false end
  local direct = state._stadiumDirectNeighbors
  if type(direct) == "table" then return direct, true end
  direct = {}
  for _, rec in ipairs(state.neighbors or {}) do
    if (tonumber(rec.depth) or 50) <= 1 then direct[#direct + 1] = rec end
  end
  return direct, false
end

function Bridge._callKantoExcursionState(world, twin)
  twin = twin or TwinRegionWorld
  local fn = twin and twin.excursionState
  if type(fn) ~= "function" then
    return false, nil, "Kanto excursion-state helper is unavailable"
  end
  if Bridge._kantoExcursionStateFn ~= fn then
    Bridge._kantoExcursionStateFn = fn
    Bridge._kantoExcursionStateTrusted = false
  end
  if Bridge._kantoExcursionStateTrusted then
    Bridge.kantoExcursionStateDirectCalls = (Bridge.kantoExcursionStateDirectCalls or 0) + 1
    local state, err = fn(world)
    return true, state, err
  end
  Bridge.kantoExcursionStateProtectedCalls = (Bridge.kantoExcursionStateProtectedCalls or 0) + 1
  local ok, state, err = pcall(fn, world)
  if ok then Bridge._kantoExcursionStateTrusted = true end
  return ok, state, err
end

local function makeState(world)
  if not (world and world.map and world.camera and world.player) then
    return nil, "Gold world/map/player is not ready"
  end

  -- v0.2.85: PALLET TELEPORT is a Yellow-backed Kanto sub-runtime. The live
  -- Gold World stays resident and unchanged underneath while the voxel renderer
  -- streams Yellow's current map + neighbour sectors, NPCs, roaming encounter
  -- Pokemon and interior warps. RETURN TO JOHTO stays lossless because no
  -- Yellow coordinate is ever written into Gold's save/world objects.
  if TwinRegionWorld and type(TwinRegionWorld.excursionIsActive) == "function"
      and TwinRegionWorld.excursionIsActive()
      and type(TwinRegionWorld.excursionState) == "function" then
    local okExcursion, state, err = Bridge._callKantoExcursionState(world)
    if okExcursion and type(state) == "table" then
      -- v0.3.60: TwinRegionWorld already knows direct-vs-second-ring depth while
      -- filling its reusable neighbor records. Consume that frame-cache array
      -- directly instead of allocating and filtering another table here.
      local direct, reused = directKantoNeighbors(state)
      if reused then
        Bridge.kantoDirectNeighborReuses = (Bridge.kantoDirectNeighborReuses or 0) + 1
      end
      V.goldNeighbors = direct
      V.goldOpenWorldMaps = state.neighbors or {}
      local kantoOpenWorld = state._stadiumOpenWorldNeighbors == true
      Bridge.openWorld = kantoOpenWorld
      Bridge.openWorldMaps = kantoOpenWorld and (#(state.neighbors or {}) + 1) or 0
      Bridge.openWorldDirectMaps = #direct

      -- Kanto's excursionState owns its own base actor list, so the ordinary
      -- mergedEntities(world) path is intentionally bypassed.  Still append
      -- presentation-only provider entities (notably AmbientFlyers) to that
      -- Kanto list. TwinRegionWorld trims this tail before cached actor reuse.
      Bridge.extraEntitiesMerged = 0
      local provider = Bridge.extraEntitiesProvider
      if type(provider) == "function" and type(state.entities) == "table" then
        local okExtra, extra = pcall(provider, state)
        if okExtra and type(extra) == "table" then
          local seen = {}
          for _, e in ipairs(state.entities) do seen[e] = true end
          local before = #state.entities
          for _, e in ipairs(extra) do
            if type(e) == "table" and not seen[e] then
              seen[e] = true
              state.entities[#state.entities + 1] = e
            end
          end
          Bridge.extraEntitiesMerged = #state.entities - before
        elseif not okExtra then
          logOnce("kanto-extra-entities:" .. tostring(extra), "warn",
            "Kanto ambient entity provider failed: %s", tostring(extra))
        end
      end
      return state
    end
    if not okExcursion then err = state end
    return nil, "Gen-1 Pallet excursion failed: " .. tostring(err or state)
  end

  local attached, attachErr = attachRenderer(world, world.map)
  if not attached then return nil, attachErr end

  local neighbors, byId, directNeighbors = adaptedNeighbors(world)
  -- Third-person collision only needs maps touching the current one. OPEN
  -- WORLD may render dozens of farther areas; scanning them per boom sample
  -- adds CPU cost without changing the collision result near the player.
  V.goldNeighbors = directNeighbors
  V.goldOpenWorldMaps = neighbors

  local ocean = nil
  if TwinRegionWorld and type(TwinRegionWorld.oceanDescriptor) == "function" then
    local okOcean, value = pcall(TwinRegionWorld.oceanDescriptor, world, neighbors)
    if okOcean then
      ocean = value
    else
      logOnce("world-ocean:" .. tostring(value), "warn",
        "WORLD OCEAN could not be prepared this frame: %s", tostring(value))
    end
  end

  return {
    map = world.map,
    camera = world.camera,
    player = world.player,
    entities = mergedEntities(world),
    neighbors = neighbors,
    ghosts = adaptedGhosts(world, byId),
    flyAnim = world.flyAnim,
    -- Carry the true-directional renderer state with the exact live Gold world
    -- used to build this frame.  Do not make OverworldStadium rediscover the
    -- world through Game.overworld/StateStack: those facades can lag behind the
    -- first map and only become current after a connection transition.
    _stadiumFreeMoveActive = world._stadiumFreeMoveActive == true,
    _stadiumFreeVisualMoving = world._stadiumFreeVisualMoving == true,
    _stadiumFreeAnimDist = tonumber(world._stadiumFreeAnimDist) or 0,
    _stadiumOpenWorldNeighbors = Bridge.openWorld == true,
    _stadiumOpenWorldMapCount = Bridge.openWorldMaps,
    _stadiumOcean = ocean,
    _stadiumTwinWorldStatus = TwinRegionWorld and TwinRegionWorld.status
      and TwinRegionWorld.status() or nil,
    _stadiumResidencyRegion = "johto",
  }
end

-- Sibling Gold-only modules (notably OverworldBattle) can request the same
-- adapted state the free-roam renderer uses, including normalized tileset ids.
V.goldStateForWorld = makeState

local normalizedFrameCanvas = nil
local normalizedFrameW, normalizedFrameH = nil, nil

-- Host-specific output geometry. Gold drawWorld owns a logical scene canvas
-- and draws it directly; Gen1 worldOverride owns physical framebuffer pixels
-- (plus an optional TouchSkin drawable). Internal-resolution rendering is
-- normalized back to whichever output contract the active generation uses.
local function frameGeometry(ctx, factor)
  factor = math.max(0.05, math.min(1, tonumber(factor) or 1))

  -- Gold's official World:drawPipeline contract is NOT Gen1 Renderer.worldOverride.
  -- World.lua draws the returned canvas directly at (0,0), with no DPI
  -- conversion or framebuffer normalization.  On Android, returning the
  -- physical 2x/2.75x framebuffer here therefore shows only the upper-left
  -- logical slice and looks massively zoomed.  Generation 2 must return the
  -- exact logical Gold scene size supplied by the pipeline/compose context.
  -- Older Gold render.compose also scales an arbitrary source to ctx.ww/wh,
  -- so the same logical geometry is correct there too.
  if tonumber(ctx and ctx.generation) == 2 then
    local fw, fh = tonumber(ctx and ctx.ww), tonumber(ctx and ctx.wh)
    if not (fw and fh and fw > 0 and fh > 0) then
      local G = love and love.graphics
      if G and type(G.getDimensions) == "function" then
        local ok, w, h = pcall(G.getDimensions)
        if ok then fw, fh = tonumber(w), tonumber(h) end
      end
    end
    fw, fh = math.max(1, math.floor(tonumber(fw) or 1)),
             math.max(1, math.floor(tonumber(fh) or 1))
    return {
      x = 0, y = 0, width = fw, height = fh,
      frameWidth = fw, frameHeight = fh,
      renderWidth = math.max(1, math.floor(fw * factor + 0.5)),
      renderHeight = math.max(1, math.floor(fh * factor + 0.5)),
      factor = factor, source = "gold-logical-pipeline", cropped = false,
    }
  end

  -- Gen 1's Renderer:endFrame worldOverride really is a physical-framebuffer
  -- contract, including an optional TouchSkin gameplay rectangle. Keep the
  -- v0.3.47 normalization only on that generation.
  if EngineViewportCompat and type(EngineViewportCompat.renderGeometry) == "function" then
    local ok, g = pcall(EngineViewportCompat.renderGeometry, factor)
    if ok and type(g) == "table" then return g end
  end

  local G = love and love.graphics
  local fullW, fullH
  if G and type(G.getPixelDimensions) == "function" then
    local ok, w, h = pcall(G.getPixelDimensions)
    if ok then fullW, fullH = tonumber(w), tonumber(h) end
  end
  if not (fullW and fullH and fullW > 0 and fullH > 0) then
    fullW, fullH = tonumber(ctx and ctx.pw), tonumber(ctx and ctx.ph)
  end
  if not (fullW and fullH and fullW > 0 and fullH > 0) and G then
    fullW, fullH = G.getDimensions()
  end
  fullW, fullH = math.max(1, math.floor(tonumber(fullW) or 1)),
                 math.max(1, math.floor(tonumber(fullH) or 1))
  return {
    x = 0, y = 0, width = fullW, height = fullH,
    frameWidth = fullW, frameHeight = fullH,
    renderWidth = math.max(1, math.floor(fullW * factor + 0.5)),
    renderHeight = math.max(1, math.floor(fullH * factor + 0.5)),
    factor = factor, source = "fallback", cropped = false,
  }
end

Bridge._frameGeometry = frameGeometry

local function ensureNormalizedFrame(w, h)
  if normalizedFrameCanvas and normalizedFrameW == w and normalizedFrameH == h then
    return normalizedFrameCanvas
  end
  if normalizedFrameCanvas and type(normalizedFrameCanvas.release) == "function" then
    pcall(normalizedFrameCanvas.release, normalizedFrameCanvas)
  end
  normalizedFrameCanvas = nil
  normalizedFrameW, normalizedFrameH = nil, nil

  local ok, canvas
  if PixelCanvas and type(PixelCanvas.new) == "function" then
    ok, canvas = PixelCanvas.new(w, h)
  else
    ok, canvas = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
  end
  if not (ok and canvas) then return nil end
  pcall(canvas.setFilter, canvas, "nearest", "nearest")
  normalizedFrameCanvas = canvas
  normalizedFrameW, normalizedFrameH = w, h
  return canvas
end

-- VoxelScene may deliberately render below native resolution. Also, Android
-- TouchSkin may reserve a gameplay rectangle smaller than the framebuffer.
-- The engine does NOT scale a drawWorld worldOverride for us: it blits the
-- returned framebuffer image 1:1 (modulo DPI). Therefore always return a full
-- frame canvas and place/upscale the scene into the engine's drawable rect.
local function normalizeFrame(scene, geometry)
  if not (scene and geometry) then return scene end
  local okDim, cw, ch = pcall(scene.getDimensions, scene)
  if not okDim or not (cw and ch and cw > 0 and ch > 0) then return scene end
  local fw, fh = tonumber(geometry.frameWidth), tonumber(geometry.frameHeight)
  local x, y = tonumber(geometry.x) or 0, tonumber(geometry.y) or 0
  local w, h = tonumber(geometry.width), tonumber(geometry.height)
  if not (fw and fh and w and h and fw > 0 and fh > 0 and w > 0 and h > 0) then
    return scene
  end

  -- True 100% full-frame path needs no copy at all.
  if x == 0 and y == 0 and w == fw and h == fh and cw == fw and ch == fh then
    Bridge.frameNormalized = false
    return scene
  end

  local target = ensureNormalizedFrame(math.floor(fw), math.floor(fh))
  if not target then return scene end
  local G = love and love.graphics
  if not G then return scene end
  local previous = nil
  if type(G.getCanvas) == "function" then
    local okPrev, value = pcall(G.getCanvas)
    if okPrev then previous = value end
  end
  local ok = pcall(function()
    G.push("all")
    G.origin()
    G.setCanvas(target)
    G.clear(0, 0, 0, 1)
    G.setColor(1, 1, 1, 1)
    G.draw(scene, x, y, 0, w / cw, h / ch)
    G.setCanvas(previous)
    G.pop()
  end)
  if not ok then
    pcall(G.setCanvas, previous)
    pcall(G.pop)
    return scene
  end
  Bridge.frameNormalized = true
  Bridge.frameNormalizeCopies = (Bridge.frameNormalizeCopies or 0) + 1
  return target
end

Bridge._normalizeFrame = normalizeFrame

local function viewDimensions(world, ctx)
  -- The active drawWorld pipeline is the most precise authority: Gen1Recomp
  -- passes the exact view it is about to composite. Prefer it over cached
  -- world fields so a resized/rotated mobile frame cannot lag one tick behind.
  local vw, vh = tonumber(ctx and ctx.vw), tonumber(ctx and ctx.vh)
  if vw and vh and vw > 0 and vh > 0 then return vw, vh end

  vw, vh = tonumber(world and world.viewW), tonumber(world and world.viewH)
  if vw and vh and vw > 0 and vh > 0 then return vw, vh end

  local ww, wh = tonumber(ctx and ctx.ww), tonumber(ctx and ctx.wh)
  if not (ww and wh and ww > 0 and wh > 0) then
    if EngineViewportCompat and type(EngineViewportCompat.drawableLogicalRect) == "function" then
      local _, _, dw, dh = EngineViewportCompat.drawableLogicalRect()
      ww, wh = dw, dh
    elseif EngineViewportCompat and type(EngineViewportCompat.logicalDimensions) == "function" then
      ww, wh = EngineViewportCompat.logicalDimensions()
    else
      ww, wh = love.graphics.getDimensions()
    end
  end
  local scale = 1
  if world and type(world.zoomScale) == "function" then
    local ok, s = pcall(world.zoomScale, world)
    if ok and tonumber(s) and tonumber(s) > 0 then scale = tonumber(s) end
  end
  return math.max(1, math.ceil(ww / scale)), math.max(1, math.ceil(wh / scale))
end

local function release3DPresentation(reason)
  Bridge.active = false
  if Voxel and type(Voxel.setLevel) == "function" then
    pcall(Voxel.setLevel, 0)
    if type(Voxel.update) == "function" then pcall(Voxel.update, 0, 0) end
  end
  if FirstPerson then
    if type(FirstPerson.forceRelease) == "function" then
      pcall(FirstPerson.forceRelease, reason or "voxel disabled")
    elseif type(FirstPerson.releaseBody) == "function" then
      pcall(FirstPerson.releaseBody)
    end
  end
  if GoldCameraControls and type(GoldCameraControls.release) == "function" then
    pcall(GoldCameraControls.release, Bridge.game and Bridge.game.world)
  end
  -- The Yellow excursion is presentation-local over a hidden Johto world and
  -- currently has no native Gold 2D map owner. Never force voxels back on to
  -- keep it visible: leaving 3D while visiting Kanto returns losslessly to the
  -- saved Johto anchor instead. Re-entering Kanto while 2D is selected is
  -- refused explicitly in TwinRegionWorld.teleportToPalletTown().
  if TwinRegionWorld and type(TwinRegionWorld.excursionIsActive) == "function"
      and type(TwinRegionWorld.returnToJohto) == "function" then
    local okActive, active = pcall(TwinRegionWorld.excursionIsActive)
    if okActive and active then
      pcall(TwinRegionWorld.returnToJohto)
      Bridge.twoDForcedKantoReturns = (Bridge.twoDForcedKantoReturns or 0) + 1
    end
  end
end

function Bridge.install()
  if Bridge.installed then return true, V end

  local poseOK, poseErr = ensurePlayerPose()
  if not poseOK then return false, poseErr end

  local ok, a, b, c, d, e, f, g, h, i = pcall(function()
    return V.require("VoxelState"), V.require("Voxel3D"),
      V.require("VoxelScene"), V.require("ChunkMesher"),
      V.require("FirstPerson"), V.require("CamControl"),
      V.require("GoldCameraControls"), V.require("EngineViewportCompat"),
      V.require("PixelCanvas")
  end)
  if not ok then return false, tostring(a) end
  Voxel, Voxel3D, VoxelScene, ChunkMesher, FirstPerson, CamControl, GoldCameraControls,
    EngineViewportCompat, PixelCanvas = a, b, c, d, e, f, g, h, i

  if not (type(Voxel) == "table" and type(Voxel.setLevel) == "function") then
    return false, "VoxelState renderer is unavailable"
  end
  if not (type(Voxel3D) == "table" and type(Voxel3D.available) == "function") then
    return false, "Voxel3D renderer is unavailable"
  end
  if not (type(VoxelScene) == "table" and type(VoxelScene.render) == "function") then
    return false, "VoxelScene renderer is unavailable"
  end
  if not (type(ChunkMesher) == "table" and type(ChunkMesher.pump) == "function"
       and type(ChunkMesher.get) == "function") then
    return false, "ChunkMesher renderer is unavailable"
  end

  if not (type(FirstPerson) == "table" and type(FirstPerson.update) == "function"
       and type(FirstPerson.install) == "function") then
    return false, "FirstPerson/ThirdPerson camera rig is unavailable"
  end
  if not (type(CamControl) == "table" and type(CamControl.install) == "function"
       and type(CamControl.pinchBy) == "function") then
    return false, "Voxel pinch-zoom controller is unavailable"
  end
  if not (type(GoldCameraControls) == "table"
       and type(GoldCameraControls.install) == "function") then
    return false, "Gold camera-relative movement adapter is unavailable"
  end

  -- Install this before the first world frame so F6 works even if another
  -- feature wraps Game2:keypressed after game.ready.
  installCameraStepHotkey()

  -- v0.2.82 twin-region/ocean layer. Keep it optional to the proven Gold
  -- renderer: a missing Gen-1 cache should hide only the companion region,
  -- never disable the current Gold terrain.
  local okTwin, twinOrErr = pcall(V.require, "TwinRegionWorld")
  if okTwin and type(twinOrErr) == "table" then
    TwinRegionWorld = twinOrErr
    -- Shared only inside this mod's private renderer namespace.  The input
    -- adapter reads this dynamically so a Pallet excursion can freeze Gold's
    -- hidden player without creating a dependency cycle at module load time.
    V.TwinRegionWorld = TwinRegionWorld
    Bridge.twinWorldAvailable = true
    Bridge.twinWorldError = nil
  else
    Bridge.twinWorldAvailable = false
    Bridge.twinWorldError = tostring(twinOrErr)
  end

  -- In-world battles are optional to the renderer's survival: install them
  -- through this same Gold module namespace, but never let a battle hook
  -- failure disable the proven free-roam voxel path.
  local okBattle, battleOrErr = pcall(V.require, "OverworldBattle")
  if okBattle and type(battleOrErr) == "table" then
    OverworldBattle = battleOrErr
    local okInstall, installErr = pcall(OverworldBattle.install)
    Bridge.battleInstalled = okInstall and installErr ~= false
    if not Bridge.battleInstalled then
      Bridge.battleError = tostring(installErr or "battle install declined")
    end
  else
    Bridge.battleInstalled = false
    Bridge.battleError = tostring(battleOrErr)
  end

  -- Optional in-world capture minigame.  Keep it isolated from renderer
  -- survival exactly like the battle presentation: a bad capture asset/hook
  -- may fall back to normal battles but must never disable the voxel world.
  local okCapture, captureOrErr = pcall(V.require, "OverworldCapture")
  if okCapture and type(captureOrErr) == "table" then
    OverworldCapture = captureOrErr
    Bridge.captureAvailable = true
    Bridge.captureError = nil
  else
    Bridge.captureAvailable = false
    Bridge.captureError = tostring(captureOrErr)
  end

  -- Mod Manager persists the option and emits this event live. The frame path
  -- still re-reads mod.options:get every time, but the event immediately drops
  -- the cached full-world graph so OFF cannot remain visually sticky for even
  -- one stale cache generation.
  if not Bridge.openWorldOptionListenerInstalled
      and mod and mod.events and type(mod.events.on) == "function" then
    local okListener = pcall(mod.events.on, mod.events, "mod.options_changed",
      function(payload)
        if type(payload) ~= "table" then return end
        if payload.mod ~= nil and payload.mod ~= mod.id then return end
        if payload.key == "voxel3d" then
          if optionEnabled() then
            Bridge.active = true
            applyOpenWorldMode(effectiveOpenWorld())
          else
            release3DPresentation("3D VOXEL WORLD disabled")
          end
        elseif payload.key == "openWorld" then
          applyOpenWorldMode(payload.value)
        elseif payload.key == "gen1Region" and TwinRegionWorld then
          -- The Kanto switch now promotes residency by itself; no separate
          -- OPEN WORLD toggle is required. Drop discovery state and immediately
          -- apply the effective residency answer so the next frame can build it.
          if type(TwinRegionWorld.invalidateRegion) == "function" then
            pcall(TwinRegionWorld.invalidateRegion)
          end
          applyOpenWorldMode(effectiveOpenWorld())
        elseif payload.key == "worldOcean" and TwinRegionWorld then
          if type(TwinRegionWorld.invalidateOcean) == "function" then
            pcall(TwinRegionWorld.invalidateOcean)
          end
        end
      end)
    Bridge.openWorldOptionListenerInstalled = okListener == true
  end

  Bridge.installed = true
  -- OPEN WORLD is residency only.  It may stay enabled while 3D VOXEL WORLD
  -- is OFF, but it does not own renderer activation; turning voxel3d back ON
  -- resumes the same open-world residency choice without rewriting it.
  Bridge.active = voxelModeEnabled()
  applyOpenWorldMode(effectiveOpenWorld())
  if not Bridge.active then
    -- A save can boot directly into native 2D. Do the same cleanup performed
    -- by a live ON->OFF switch so stale camera/pipeline state from an earlier
    -- session cannot capture mouse/right-stick input before the first frame.
    release3DPresentation("3D VOXEL WORLD disabled at boot")
  end
  logOnce("installed", "info",
    "Gen-2 voxel renderer provider ready for Gold render.compose")
  return true, V
end

function Bridge.ensure()
  if not Bridge.installed then return Bridge.install() end
  return true, V
end

function Bridge.renderFrame(world, ctx)
  Bridge.framesAttempted = Bridge.framesAttempted + 1
  -- Renderer activation belongs to 3D VOXEL WORLD.  OPEN WORLD may retain its
  -- residency preference while this returns disabled; no stitched native-2D
  -- overview is drawn because the neighbour graph is consumed only by the
  -- voxel scene itself.
  Bridge.active = voxelModeEnabled()
  Bridge.mapId = world and world.map and world.map.id or nil

  if not Bridge.active then return nil, "voxel disabled", "disabled" end
  if not Bridge.installed then
    local ok, err = Bridge.install()
    if not ok then
      Bridge.framesFailed = Bridge.framesFailed + 1
      Bridge.lastError = tostring(err)
      return nil, Bridge.lastError, "failed"
    end
  end

  -- GoldComposeBridge supplies the live Game2 owner explicitly; current World
  -- objects also keep it as world.game. The camera modules use this instead of
  -- the Gen-1 singleton when deciding whether free roam is actually on top.
  bindGame((world and world.game) or Bridge.game)

  local okAvailable, available = pcall(Voxel3D.available)
  if not okAvailable or not available then
    local err = okAvailable and "Voxel3D reports graphics/depth support unavailable"
      or ("Voxel3D availability check failed: " .. tostring(available))
    Bridge.framesFailed = Bridge.framesFailed + 1
    Bridge.lastError = err
    logOnce("available:" .. err, "warn", "%s", err)
    return nil, err, "failed"
  end

  local state, stateErr = makeState(world)
  if not state then
    Bridge.framesFailed = Bridge.framesFailed + 1
    Bridge.lastError = tostring(stateErr)
    return nil, Bridge.lastError, "failed"
  end

  -- During a Pallet excursion the visible root is a namespaced Gen-1 map, not
  -- the hidden Gold map that still owns gameplay/save state. Keep diagnostics
  -- and one-time mesh priming aligned to what is actually on screen.
  Bridge.mapId = state.map and state.map.id or Bridge.mapId

  -- Prime the CURRENT Gold map synchronously once on entry.  The original
  -- renderer queues terrain through an async coroutine because Gen 1's normal
  -- pipeline has a dedicated update/pump cadence.  Gold's compose hook does
  -- not have that host contract, and a failed async job was previously cached
  -- as false and mistaken for "still pending" forever.  A one-time direct
  -- build gives Gold a drawable terrain mesh immediately (or a concrete error).
  if Bridge.syncBuildMapId ~= state.map.id then
    Bridge.syncBuildMapId = state.map.id
    Bridge.syncBuilds = Bridge.syncBuilds + 1

    local sharedBodies = state._stadiumSharedWorldBodies == true
    if sharedBodies then
      -- v0.3.43 Kanto promotion path.  v0.3.42 correctly RENDERED BODY-only
      -- sectors, but this legacy one-time prime still synchronously built a FULL
      -- bordered/apron mesh whenever the current map id changed.  That mesh is
      -- never drawn in shared Kanto and the blocking build caused a visible hitch
      -- at sector handoffs.  A connected neighbour normally already has BODY in
      -- RAM; a cold warp queues an urgent persistent-cache-first BODY upload and
      -- lets the normal cooperative pump finish it without blocking this frame.
      local body = type(ChunkMesher.peek) == "function"
        and ChunkMesher.peek(state.map, true) or nil
      if not body and type(ChunkMesher.request) == "function" then
        ChunkMesher.request(state.map, true, nil, true)
        Bridge.sharedBodyDeferred = (Bridge.sharedBodyDeferred or 0) + 1
      else
        Bridge.sharedBodyPromotions = (Bridge.sharedBodyPromotions or 0) + 1
      end
    else
      -- Native Johto / non-shared worlds keep the historical synchronous prime:
      -- a destination already visible as a neighbour is reused immediately; a
      -- truly cold map is built once with its full neighbour masks.
      local warm = (type(ChunkMesher.peek) == "function")
        and (ChunkMesher.peek(state.map, false) or ChunkMesher.peek(state.map, true))
      local okPrime, primeMeshOrErr = true, warm
      if not warm then
        okPrime, primeMeshOrErr = pcall(ChunkMesher.get, state.map, false,
                                        currentMasks(state.neighbors))
      end
      if not okPrime then
        Bridge.syncBuildFailures = Bridge.syncBuildFailures + 1
        Bridge.framesFailed = Bridge.framesFailed + 1
        Bridge.lastError = "Gen-2 voxel mesh prime crashed: " .. tostring(primeMeshOrErr)
        logOnce("prime-crash:" .. tostring(state.map.id) .. ":" .. Bridge.lastError,
          "error", "%s", Bridge.lastError)
        return nil, Bridge.lastError, "failed"
      end
      if not primeMeshOrErr then
        local meshErr = type(ChunkMesher.lastError) == "function"
          and ChunkMesher.lastError(state.map.id) or nil
        Bridge.syncBuildFailures = Bridge.syncBuildFailures + 1
        Bridge.framesFailed = Bridge.framesFailed + 1
        Bridge.lastError = meshErr and ("Gen-2 voxel mesh build failed: " .. tostring(meshErr))
          or "Gen-2 voxel mesh build produced no terrain"
        logOnce("prime-empty:" .. tostring(state.map.id) .. ":" .. Bridge.lastError,
          "error", "%s", Bridge.lastError)
        return nil, Bridge.lastError, "failed"
      end
    end
  end

  local ok, canvasOrErr = pcall(function()
    -- Poll Android touch contacts before resolving this frame's camera mode so
    -- a slider drag takes effect on the very same rendered frame.
    local liveGame = (world and world.game) or Bridge.game
    updateCameraSliderTouches(liveGame)
    updateDioramaPinchTouches(liveGame)
    updateRightLookTouches(liveGame, false)
    pollCameraHotkey(liveGame)
    local mode = optionCameraMode()
    -- A capture begun from DIORAMA temporarily dives to the already-proven
    -- 3RD-person rig so the player can physically aim with mouse/right stick.
    -- The saved camera option is never changed; leaving the minigame returns
    -- to DIORAMA automatically on the next frame.
    local captureMode = nil
    if OverworldCapture and type(OverworldCapture.cameraOverride) == "function" then
      local okCaptureMode, value = pcall(OverworldCapture.cameraOverride)
      if okCaptureMode then captureMode = value end
    end
    local renderMode = captureMode or mode
    local level = cameraLevelForMode(renderMode)
    local dt = frameDt()
    Bridge.cameraMode, Bridge.cameraLevel = mode, level
    Bridge.captureCameraOverride = captureMode

    -- DIORAMA keeps the FULL preset semantics (so zoom still targets the
    -- diorama distance), but its pitch is independently configurable. This
    -- deliberately separates TILT from DioramaZoom: changing tilt rotates the
    -- camera; changing zoom only changes distance. FIRST/THIRD keep their own
    -- placed-camera rigs.
    if renderMode == "diorama" and type(Voxel.setFullAngle) == "function" then
      Voxel.setFullAngle(optionDioramaTilt())
    end
    Voxel.setLevel(level)
    if type(Voxel.update) == "function" then Voxel.update(dt, level) end
    if FirstPerson and type(FirstPerson.update) == "function" then
      FirstPerson.update(dt)
    end
    if OverworldCapture and type(OverworldCapture.afterCameraUpdate) == "function" then
      pcall(OverworldCapture.afterCameraUpdate)
    end
    -- v0.3.58: a visible Kanto gameplay frame never gives persistent cache
    -- warmers a multi-millisecond idle slice. Even while standing still, those
    -- cache-only jobs can trigger a GC/CPU hitch on mobile or a 60-Hz desktop.
    -- Pass the Kanto-visible hint for the whole excursion so background cooking
    -- stays in the tiny cooperative budget. Current/urgent/visible terrain is
    -- NOT throttled by ChunkMesher.pump; only cacheOnly jobs read this flag.
    local kantoInteractive = state and state._stadiumYellowKanto == true
    -- v0.4.31 also prewarms nearby Johto sectors. Mark every visible world
    -- frame interactive so cache-only cooks use ChunkMesher's tiny gameplay
    -- slice instead of stealing several milliseconds from player movement.
    -- Real/current/visible terrain jobs do not use this flag.
    local meshPumpHint = state and true or false
    if kantoInteractive then
      Bridge.kantoCacheThrottleFrames = (Bridge.kantoCacheThrottleFrames or 0) + 1
      -- If the current shared Kanto body is already present, every real mesh job
      -- left in the queue is neighbour/prefetch work. Give that work the smooth
      -- Kanto-visible slice. A cold current body stays on the normal urgent
      -- budget so a warp/toggle does not wait unnecessarily.
      local currentReady = type(ChunkMesher.peek) == "function"
        and ChunkMesher.peek(state.map, true) ~= nil
      if currentReady then
        meshPumpHint = "kanto-visible"
        Bridge.kantoVisibleMeshThrottleFrames = (Bridge.kantoVisibleMeshThrottleFrames or 0) + 1
      end
    end
    ChunkMesher.pump(false, meshPumpHint)
    local vw, vh = viewDimensions(world, ctx)
    -- Kanto owns a presentation-local camera proxy. Center it with the SAME
    -- logical world coverage VoxelScene is about to consume.
    if state and state._stadiumYellowKanto == true and TwinRegionWorld
        and type(TwinRegionWorld.centerExcursionCamera) == "function" then
      pcall(TwinRegionWorld.centerExcursionCamera, state, vw, vh)
    end

    -- v0.3.48 host-correct framing. Gold's World:drawPipeline draws its
    -- returned canvas directly in logical scene units, while Gen1's
    -- Renderer.worldOverride expects physical framebuffer pixels. frameGeometry
    -- separates those contracts instead of forcing Android Gold through the
    -- Gen1 physical-frame path (the v0.3.47 cause of the giant zoom). Internal
    -- graphics resolution is still normalized back to the host's required size.
    local rf = renderResolutionFactor()
    local geometry = frameGeometry(ctx, rf)
    local rw = math.max(160, tonumber(geometry.renderWidth) or 160)
    local rh = math.max(144, tonumber(geometry.renderHeight) or 144)
    rw, rh = math.floor(rw), math.floor(rh)
    Bridge.renderFactor, Bridge.renderWidth, Bridge.renderHeight = rf, rw, rh
    Bridge.frameWidth, Bridge.frameHeight = geometry.frameWidth, geometry.frameHeight
    Bridge.drawableX, Bridge.drawableY = geometry.x, geometry.y
    Bridge.drawableWidth, Bridge.drawableHeight = geometry.width, geometry.height
    Bridge.drawableSource = geometry.source
    local canvas = VoxelScene.render(state, rw, rh, vw, vh, nil)
    if canvas then canvas = normalizeFrame(canvas, geometry) end
    -- v0.3.05: steady-state gets ONE visible-frame mesh-build slice. The old
    -- bridge pumped immediately before AND after every render, effectively
    -- doubling Quality.buildSlices() and allowing background meshing to eat a
    -- full 16.7 ms frame by itself. If the current terrain is still missing,
    -- keep the second emergency slice so enabling 3D / crossing a cold warp
    -- does not take twice as many frames to become drawable.
    if not canvas then ChunkMesher.pump(false, meshPumpHint) end
    return canvas
  end)

  if not ok then
    Bridge.framesFailed = Bridge.framesFailed + 1
    Bridge.lastError = tostring(canvasOrErr)
    logOnce("render:" .. Bridge.lastError, "error",
      "Gold compose voxel frame failed; flat Gold + visible Wilds fallback will be used: %s",
      Bridge.lastError)
    return nil, Bridge.lastError, "failed"
  end

  if not canvasOrErr then
    local meshErr = type(ChunkMesher.lastError) == "function"
      and ChunkMesher.lastError(state.map.id) or nil
    if meshErr then
      Bridge.framesFailed = Bridge.framesFailed + 1
      Bridge.lastError = "Gen-2 voxel mesh failed after prime: " .. tostring(meshErr)
      logOnce("mesh-failed:" .. tostring(state.map.id) .. ":" .. Bridge.lastError,
        "error", "%s", Bridge.lastError)
      return nil, Bridge.lastError, "failed"
    end
    Bridge.framesPending = Bridge.framesPending + 1
    Bridge.meshPendingFrames = Bridge.meshPendingFrames + 1
    return nil, "voxel mesh pending", "pending"
  end

  Bridge.frames3d = Bridge.frames3d + 1
  Bridge.lastError = nil
  return canvasOrErr, nil, "rendered"
end

function Bridge.updateBattle(dt)
  if not (OverworldBattle and type(OverworldBattle.update) == "function") then
    return false
  end
  -- Poll Android right-thumb look even though Gold's BattleState is on top.
  -- The live-world battle uses the same FirstPerson/ThirdPerson yaw/pitch as
  -- free roam, so steering here changes the camera the battle actually draws.
  local battleActive = false
  pcall(function() battleActive = OverworldBattle.shot() ~= nil or OverworldBattle.battle() ~= nil end)
  updateRightLookTouches(Bridge.game, battleActive)
  local ok, err = pcall(OverworldBattle.update, tonumber(dt) or (1 / 60))
  if not ok then
    Bridge.battleError = tostring(err)
    return false
  end
  return true
end

function Bridge.battleShot()
  if not (OverworldBattle and type(OverworldBattle.shot) == "function") then
    return nil
  end
  local ok, shot = pcall(OverworldBattle.shot)
  return ok and shot or nil
end

function Bridge.battleScreen()
  if not (OverworldBattle and type(OverworldBattle.battle) == "function") then
    return nil
  end
  local ok, battle = pcall(OverworldBattle.battle)
  return ok and battle or nil
end

function Bridge.battleStage()
  if not (OverworldBattle and type(OverworldBattle.stage) == "function") then
    return nil
  end
  local ok, stage = pcall(OverworldBattle.stage)
  return ok and stage or nil
end

function Bridge.setExtraEntitiesProvider(fn)
  if fn ~= nil and type(fn) ~= "function" then
    return false, "extra entity provider must be a function or nil"
  end
  Bridge.extraEntitiesProvider = fn
  return true
end

function Bridge.status()
  return {
    installed = Bridge.installed,
    active = Bridge.active,
    mapId = Bridge.mapId,
    framesAttempted = Bridge.framesAttempted,
    frames3d = Bridge.frames3d,
    framesPending = Bridge.framesPending,
    framesFailed = Bridge.framesFailed,
    extraEntitiesProvider = type(Bridge.extraEntitiesProvider) == "function",
    extraEntitiesMerged = Bridge.extraEntitiesMerged,
    connectedMaps = V.goldNeighbors and #V.goldNeighbors or 0,
    openWorld = Bridge.openWorld == true,
    pokemonModels = modelsEnabled(),
    playerModel = playerModelsEnabled(),
    performance = (graphicsQuality() and type(graphicsQuality().status) == "function")
      and graphicsQuality().status() or nil,
    renderFactor = Bridge.renderFactor or 1,
    cameraStepHotkeyInstalled = Bridge.cameraStepHotkeyInstalled == true,
    cameraStepHotkeyError = Bridge.cameraStepHotkeyError,
    renderWidth = Bridge.renderWidth, renderHeight = Bridge.renderHeight,
    frameWidth = Bridge.frameWidth, frameHeight = Bridge.frameHeight,
    drawableX = Bridge.drawableX, drawableY = Bridge.drawableY,
    drawableWidth = Bridge.drawableWidth, drawableHeight = Bridge.drawableHeight,
    drawableSource = Bridge.drawableSource,
    frameNormalized = Bridge.frameNormalized == true,
    frameNormalizeCopies = Bridge.frameNormalizeCopies or 0,
    openWorldMaps = Bridge.openWorldMaps or 0,
    openWorldDirectMaps = Bridge.openWorldDirectMaps or 0,
    openWorldGraphBuilds = Bridge.openWorldGraphBuilds or 0,
    openWorldGraphRoot = Bridge.openWorldGraphRoot,
    openWorldGraphError = Bridge.openWorldGraphError,
    openWorldFallbacks = Bridge.openWorldFallbacks or 0,
    openWorldOverlapRejects = Bridge.openWorldOverlapRejects or 0,
    twinWorldAvailable = Bridge.twinWorldAvailable == true,
    twinWorldError = Bridge.twinWorldError,
    twinWorld = (TwinRegionWorld and type(TwinRegionWorld.status) == "function")
      and TwinRegionWorld.status() or nil,
    openWorldLoadedMaps = (function()
      if not (Bridge.openWorld and ChunkMesher and type(ChunkMesher.peek) == "function") then
        return 0
      end
      local n = Bridge.mapId and 1 or 0
      for _, nb in ipairs((V and V.goldOpenWorldMaps) or {}) do
        if ChunkMesher.peek(nb.map, true) or ChunkMesher.peek(nb.map, false) then
          n = n + 1
        end
      end
      return n
    end)(),
    openWorldPendingBuilds = (ChunkMesher and type(ChunkMesher.pending) == "function")
      and ChunkMesher.pending() or 0,
    voxelDiskCache = (ChunkMesher and type(ChunkMesher.diskCacheStatus) == "function")
      and ChunkMesher.diskCacheStatus() or nil,
    syncBuildMapId = Bridge.syncBuildMapId,
    syncBuilds = Bridge.syncBuilds,
    syncBuildFailures = Bridge.syncBuildFailures,
    meshPendingFrames = Bridge.meshPendingFrames,
    kantoCacheThrottleFrames = Bridge.kantoCacheThrottleFrames or 0,
    kantoVisibleMeshThrottleFrames = Bridge.kantoVisibleMeshThrottleFrames or 0,
    kantoDirectNeighborReuses = Bridge.kantoDirectNeighborReuses or 0,
    cameraMode = Bridge.cameraMode,
    cameraLevel = Bridge.cameraLevel,
    cameraProvider = Bridge.cameraProvider,
    selectorDetected = Bridge.selectorDetected,
    externalCameraLevel = Bridge.externalCameraLevel,
    externalCameraLabel = Bridge.externalCameraLabel,
    cameraInputInstalled = Bridge.cameraInputInstalled,
    cameraInputError = Bridge.cameraInputError,
    pinchZoomInstalled = Bridge.pinchZoomInstalled,
    pinchZoomError = Bridge.pinchZoomError,
    cameraMovementInstalled = Bridge.cameraMovementInstalled,
    cameraMovementError = Bridge.cameraMovementError,
    cameraMovement = (GoldCameraControls and GoldCameraControls.status
      and GoldCameraControls.status()) or nil,
    cameraHotkeyCycles = Bridge.cameraHotkeyCycles,
    cameraHotkeyPollCycles = Bridge.cameraHotkeyPollCycles,
    cameraModeStickHolds = Bridge.cameraModeStickHolds or 0,
    twoDForcedKantoReturns = Bridge.twoDForcedKantoReturns or 0,
    shadowLookDeferrals = (VoxelScene and VoxelScene.shadowLookDeferrals) or 0,
    shadowRefreshErrors = (VoxelScene and VoxelScene.shadowRefreshErrors) or 0,
    lastShadowError = VoxelScene and VoxelScene.lastShadowError or nil,
    f6Down = Bridge.f6Down,
    cameraSliderInstalled = Bridge.cameraSliderInstalled,
    cameraSliderTouches = Bridge.cameraSliderTouches,
    cameraSliderChanges = Bridge.cameraSliderChanges,
    viewport = EngineViewportCompat and type(EngineViewportCompat.status) == "function"
      and EngineViewportCompat.status() or nil,
    platform = platformName(),
    battleInstalled = Bridge.battleInstalled,
    battleError = Bridge.battleError,
    battleActive = Bridge.battleShot() ~= nil,
    captureAvailable = Bridge.captureAvailable,
    captureError = Bridge.captureError,
    captureCameraOverride = Bridge.captureCameraOverride,
    capture = (OverworldCapture and OverworldCapture.status
      and OverworldCapture.status()) or nil,
    meshError = (ChunkMesher and type(ChunkMesher.lastError) == "function"
      and Bridge.mapId and ChunkMesher.lastError(Bridge.mapId)) or nil,
    lastError = Bridge.lastError,
  }
end

-- Test/diagnostic accessors; no engine mutation.
Bridge._mergedEntities = mergedEntities
Bridge._adaptedNeighbors = adaptedNeighbors
Bridge._currentMasks = currentMasks
Bridge._makeState = makeState
Bridge._directKantoNeighbors = directKantoNeighbors
Bridge._directNeighborSpecs = directNeighborSpecs
Bridge._allConnectedNeighborSpecs = allConnectedNeighborSpecs
Bridge._neighborUrgent = neighborUrgent
Bridge._selectorCameraMode = selectorCameraMode
Bridge._externalCameraEnabled = externalCameraEnabled
Bridge._optionCameraControl = optionCameraControl
Bridge._optionDioramaTilt = optionDioramaTilt

return Bridge
