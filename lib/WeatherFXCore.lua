-- Embedded Weather FX 4.10 visual/weather-state port for the Gold voxel host.
--
-- This intentionally ports Weather FX's weather presentation/state/audio only.
-- Steel/Fairy/Dark registry changes, Delta species, encounter substitution,
-- tornado warps and battle-rule mutations are not installed into this mod.
-- The original Weather FX source is vendored under weatherfx/ so its visual
-- modules/assets remain together; Campo's MIT voxel-atmos licence/notice are
-- preserved in weatherfx/lib/voxel_atmos/.
local HostV = ...
local hostMod = HostV and HostV.mod

local Core = {
  installed = false,
  lastError = nil,
  lastLevel = 0,
  updates = 0,
  draws = 0,
}

local loadChunk = loadstring or load
local modules = {}

local wxMod = {
  id = "STADIUM2_OVERWORLD_MODELS_WEATHER_FX",
  path = (hostMod and hostMod.path or "") .. "/weatherfx",
  manifest = { id = "weather_fx_embedded", version = "4.10.0" },
  options = hostMod and hostMod.options,
  log = hostMod and hostMod.log,
  save = nil, -- assigned to the weather-only scoped adapter below
  world = hostMod and hostMod.world,
  device = hostMod and hostMod.device,
  game = hostMod and hostMod.game,
  events = hostMod and hostMod.events,
  hooks = hostMod and hostMod.hooks,
  content = hostMod and hostMod.content,
  commands = hostMod and hostMod.commands,
}

-- The parent mod already has persistent state for followers, mounts, renderers,
-- etc. Weather FX's standalone save keys are deliberately generic ("id",
-- "left", "fronts"). Keep those keys in a private prefix so embedding the
-- weather runtime can never overwrite another subsystem's state.
local WEATHER_SAVE_PREFIX = "weatherFx."
local scopedSave = {}
function scopedSave:get(key, fallback)
  local backing = hostMod and hostMod.save
  if not (backing and type(backing.get) == "function") then return fallback end
  local ok, value = pcall(backing.get, backing, WEATHER_SAVE_PREFIX .. tostring(key))
  if not ok or value == nil then return fallback end
  return value
end
function scopedSave:set(key, value)
  local backing = hostMod and hostMod.save
  if not (backing and type(backing.set) == "function") then return false end
  local ok = pcall(backing.set, backing, WEATHER_SAVE_PREFIX .. tostring(key), value)
  return ok
end
wxMod.save = scopedSave

function wxMod:read(rel)
  if not (hostMod and type(hostMod.read) == "function") then return nil end
  return hostMod:read("weatherfx/" .. tostring(rel or ""))
end

-- Weather FX normally discovers STADIUM2_OVERWORLD_MODELS as another mod.
-- Embedded here, hand it the already-live host namespace directly and ignore
-- competing voxel hosts so the atmosphere cannot attach to the wrong renderer.
local selfHost = { exports = { lib = HostV } }
function wxMod:find(id)
  id = tostring(id or "")
  if id == "STADIUM2_OVERWORLD_MODELS" then return selfHost end
  if id == "DRAMALESS_SHAPE" or id == "potato_voxel"
      or id == "POTATO_VOXEL" or id == "PotatoVoxel" then
    return nil
  end
  if hostMod and type(hostMod.find) == "function" then
    local ok, value = pcall(hostMod.find, hostMod, id)
    if ok then return value end
  end
  return nil
end

local WX = { mod = wxMod, path = wxMod.path, host = HostV }

local function chunkFor(rel)
  local source, readErr = wxMod:read(rel)
  if type(source) ~= "string" then
    error(("embedded Weather FX: missing %s: %s"):format(rel, tostring(readErr)), 0)
  end
  if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
  local chunk, err = loadChunk(source, "@" .. wxMod.path .. "/" .. rel)
  if not chunk then error(("embedded Weather FX: %s: %s"):format(rel, tostring(err)), 0) end
  return chunk
end

function WX.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  modules[name] = false
  local value = chunkFor("lib/" .. tostring(name) .. ".lua")(WX)
  if value == nil then
    modules[name] = nil
    error("embedded Weather FX module returned nil: " .. tostring(name), 0)
  end
  modules[name] = value
  return value
end

local Config, Types, Settings, Scene, TOD, Seasons, State, Draw, Audio, VoxelAtmos, Rainbow

local function option(key, fallback)
  local opts = hostMod and hostMod.options
  if opts and type(opts.get) == "function" then
    local ok, value = pcall(opts.get, opts, key)
    if ok and value ~= nil then return value end
  end
  return fallback
end

local function weatherLevel()
  -- DEBUG RAIN in the embedded settings is a real weather override, not just
  -- a label. The standalone mod normally raises its render-pipeline ladder;
  -- this port owns the level directly, so pin heavy rain here instead.
  if Settings and Settings.debugRain and Settings.debugRain(Config) then
    for i, candidate in ipairs(Types and Types.PINNED or {}) do
      if candidate == "RAIN_HEAVY" then return i + 2 end
    end
  end
  local mode = tostring(option("weatherMode", "auto") or "auto")
  local lower = mode:lower()
  if lower == "off" then return 0 end
  if lower == "auto" then return 1 end
  if lower == "cycle" then return 2 end
  local id = mode:upper()
  if Types and Types.PINNED then
    for i, candidate in ipairs(Types.PINNED) do
      if candidate == id then return i + 2 end
    end
  end
  -- Migrate the old v0.3.17 values gracefully.
  if lower == "clear" then
    for i, candidate in ipairs(Types.PINNED or {}) do if candidate == "CLEAR" then return i + 2 end end
  elseif lower == "rain" or lower == "rain_fog" then
    for i, candidate in ipairs(Types.PINNED or {}) do if candidate == "RAIN_HEAVY" then return i + 2 end end
  elseif lower == "fog" then
    for i, candidate in ipairs(Types.PINNED or {}) do if candidate == "FOG" then return i + 2 end end
  end
  return 1
end


local WEATHER_OPTION_KEYS = {
  "weatherMode", "quality", "intensity", "exotic", "speed",
  "daytime", "seasons", "hemisphere", "seasonNotify", "lightning",
  "sfx", "splash", "indoors", "present", "debugRain",
}
local lastOptions = {}

local function pinnedWeatherFromMode(mode)
  mode = tostring(mode or "auto")
  local lower = mode:lower()
  if lower == "off" or lower == "auto" or lower == "cycle" then return nil end
  local id = mode:upper()
  if Types and Types.byId and Types.byId[id] then return id end
  if lower == "clear" then return "CLEAR" end
  if lower == "rain" or lower == "rain_fog" then return "RAIN_HEAVY" end
  if lower == "fog" then return "FOG" end
  return nil
end

local function clearSoftWeather()
  if not State then return end
  State.softFrom, State.softTo = nil, nil
  State.softT, State.softDur = 0, 0
  State.mapsTowardCommit = 0
  State.overrideMap = nil
end

local function snapshotValue(key)
  if key == "weatherMode" then return tostring(option("weatherMode", "auto") or "auto") end
  if Settings and Settings.get then return Settings.get(key) end
  return option(key, nil)
end

local function applyLiveOptions(force)
  if not (Settings and State) then return false end
  local changed, any = {}, false
  for _, key in ipairs(WEATHER_OPTION_KEYS) do
    local value = snapshotValue(key)
    if force or lastOptions[key] ~= value then
      changed[key], any = true, true
      lastOptions[key] = value
    end
  end
  if not any then return false end

  if force or changed.weatherMode or changed.debugRain then
    local mode = tostring(option("weatherMode", "auto") or "auto")
    local lower = mode:lower()
    clearSoftWeather()
    if lower == "off" and not (Settings.debugRain and Settings.debugRain(Config)) then
      State.level = 0
      State.mode = "OFF"
      State.pinnedBy = "off"
    elseif lower == "cycle" then
      State.mode = "CYCLE"
      State.pinnedBy = "cycle"
      State.left = 0
      State.fresh = true
    elseif lower == "auto" then
      State.mode = "AUTO"
      State.pinnedBy = "auto"
      State.left = 0
      State.fresh = true
    else
      local id = pinnedWeatherFromMode(mode)
      if id then
        State.level = weatherLevel()
        State.mode = "PIN"
        State.pinnedBy = "menu"
        -- A player explicitly choosing a weather should see it NOW. The
        -- standalone state machine's long regional crossfade is for walking
        -- between fronts, not for a menu selection.
        pcall(State.set, id, true)
      end
    end
  end

  if Draw and Draw.invalidate and (force or changed.weatherMode or changed.quality
      or changed.intensity or changed.present or changed.splash
      or changed.lightning or changed.debugRain) then
    pcall(Draw.invalidate)
  end
  if Audio and Audio.invalidate and (force or changed.sfx or changed.weatherMode) then
    pcall(Audio.invalidate)
  end
  if VoxelAtmos and VoxelAtmos.invalidate and (force or changed.weatherMode
      or changed.quality or changed.intensity or changed.speed
      or changed.lightning or changed.present) then
    pcall(VoxelAtmos.invalidate)
  end
  return true
end

local function refreshProxyServices()
  -- Loader-owned facades can appear after entry execution; keep references live.
  wxMod.options = hostMod and hostMod.options or wxMod.options
  wxMod.log = hostMod and hostMod.log or wxMod.log
  -- wxMod.save intentionally remains the weather-only scoped adapter.
  wxMod.world = hostMod and hostMod.world or wxMod.world
  wxMod.device = hostMod and hostMod.device or wxMod.device
  wxMod.game = hostMod and hostMod.game or wxMod.game
  wxMod.events = hostMod and hostMod.events or wxMod.events
  wxMod.hooks = hostMod and hostMod.hooks or wxMod.hooks
end

local function applyEmbeddedPolicy()
  local cfg = Config and Config.get and Config.get() or nil
  if type(cfg) ~= "table" then return end

  -- This package is replacing presentation, not importing Weather FX's
  -- unrelated gameplay mod. Make that separation explicit in live config too,
  -- even if a user copies a standalone Weather FX config with those features on.
  if type(cfg.encounters) == "table" then cfg.encounters.enabled = false end
  if type(cfg.weatherVariants) == "table" then cfg.weatherVariants.enabled = false end
  if type(cfg.tornado) == "table" then cfg.tornado.enabled = false end
  if type(cfg.battle) == "table" then cfg.battle.enabled = false end
  if type(cfg.pokegear) == "table" then cfg.pokegear.enabled = false end
  if type(cfg.followerChip) == "table" then cfg.followerChip.enabled = false end
  if type(cfg.legendary) == "table" then cfg.legendary.encounters = false end

  -- The Stadium2 host already owns the visual day/night grade and Gold clock.
  -- Weather FX still uses that clock for forecast weighting, but must not paint
  -- a second full-screen time grade on top of the voxel renderer.
  if type(cfg.time) == "table" then
    cfg.time.source = "auto"
    cfg.time.grade = false
    cfg.time.publishTod = false
  end
end

function Core.install()
  if Core.installed then return true end
  local ok, err = pcall(function()
    Config = WX.require("Config")
    Types = WX.require("Types")
    Settings = WX.require("Settings")
    Scene = WX.require("Scene")
    TOD = WX.require("TimeOfDay")
    Seasons = WX.require("Seasons")
    State = WX.require("WeatherState")
    Draw = WX.require("Draw")
    Audio = WX.require("Audio")
    VoxelAtmos = WX.require("VoxelAtmosBridge")
    Rainbow = WX.require("Rainbow")

    Config.load()
    applyEmbeddedPolicy()
    refreshProxyServices()
    pcall(VoxelAtmos.init)
    pcall(State.restore)
    pcall(State.settle)
    applyLiveOptions(true)

    -- Persist only Weather FX's state inside this mod's own save namespace.
    if hostMod and hostMod.events and type(hostMod.events.on) == "function" then
      hostMod.events:on("save.loaded", function()
        refreshProxyServices(); pcall(State.restore); pcall(State.settle)
      end)
      hostMod.events:on("save.created", function()
        refreshProxyServices(); pcall(State.restore); pcall(State.settle)
      end)
      hostMod.events:on("save.writing", function() pcall(State.persist) end)
      hostMod.events:on("game.ready", function()
        refreshProxyServices(); pcall(VoxelAtmos.init); pcall(State.settle); applyLiveOptions(true)
      end)
      hostMod.events:on("mod.options_changed", function(payload)
        if type(payload) ~= "table" then return end
        if payload.mod ~= nil and hostMod and payload.mod ~= hostMod.id then return end
        for _, key in ipairs(WEATHER_OPTION_KEYS) do
          if payload.key == key then
            -- Invalidate the snapshot. The next fixed tick applies the option
            -- before WeatherState advances, so ManagerState and custom menus
            -- share one deterministic path.
            lastOptions[key] = nil
            return
          end
        end
      end)
    end

    -- Gold's fixed-step seam is already used by this project. Weather ticks
    -- here, independently of whether the current frame happens to render 3D.
    if hostMod and hostMod.hooks and type(hostMod.hooks.wrap) == "function" then
      hostMod.hooks:wrap("input.step", function(next_, game, dt)
        Core.update(dt or 1 / 60, game)
        return next_(game, dt)
      end, 35)
      hostMod.hooks:wrap("render.hud", function(next_, game, viewport)
        local a, b, c = next_(game, viewport)
        if Seasons and Seasons.drawNotify then pcall(Seasons.drawNotify) end
        return a, b, c
      end, 35)
    end
  end)
  if not ok then
    Core.lastError = tostring(err)
    if hostMod and hostMod.log then hostMod.log:warn("Embedded Weather FX disabled: %s", Core.lastError) end
    return false, Core.lastError
  end
  Core.installed = true
  if hostMod and hostMod.log then
    hostMod.log:info("Weather FX 4.10 visual port installed; legacy rain/fog/cloud renderer replaced")
  end
  return true
end

function Core.update(dt, game)
  if not Core.installed then
    local ok = Core.install()
    if not ok then return end
  end
  refreshProxyServices()
  dt = tonumber(dt) or 1 / 60
  if dt < 0 then dt = 0 end
  if dt > 0.25 then dt = 0.25 end
  local ok, err = pcall(function()
    Scene.sample()
    TOD.update(dt)
    Seasons.onMap(Scene.now.mapId)
    Seasons.update(dt, Scene.now.mapId)
    applyLiveOptions(false)
    local level = weatherLevel()
    Core.lastLevel = level
    State.update(dt, level, Scene.now.mapId, Scene.now.indoors)
    Draw.update(dt, level)
    VoxelAtmos.syncFromWeatherFx(State, Settings, level)
    VoxelAtmos.update(dt)
    Audio.update(dt)
    -- Weather FX's night-sky/building-light presentation is visual only.
    local okBL, BL = pcall(WX.require, "BuildingLight")
    if okBL and BL and BL.update then pcall(BL.update, dt) end
    local okNS, NS = pcall(WX.require, "NightSky")
    if okNS and NS and NS.update then pcall(NS.update, dt) end
  end)
  if not ok then
    Core.lastError = tostring(err)
    if hostMod and hostMod.log then hostMod.log:warn("Weather FX tick failed safely: %s", Core.lastError) end
    return
  end
  Core.updates = Core.updates + 1
end

function Core.setContext(outdoor, map)
  if not Core.installed then Core.install() end
  if not Scene then return end
  -- Scene.sample remains authority; this immediate hint prevents one-frame
  -- indoor/outdoor lag during a map seam or staged overworld battle.
  if Scene.now then
    Scene.now.outdoor = outdoor and true or false
    Scene.now.indoors = not (outdoor and true or false)
    if map then
      Scene.now.mapId = map.id or (map.def and map.def.id) or Scene.now.mapId
      local cam = map.camera
      if cam then Scene.now.camX, Scene.now.camY = cam.x or 0, cam.y or 0 end
    end
  end
end

function Core.paintSky(w, h, horizonY, cell, skyRay)
  if not Core.installed or Core.lastLevel <= 0 or not Rainbow then return end
  if not (Rainbow.active and Rainbow.alpha and Rainbow.alpha > 0.01) then return end
  if Settings and Settings.force2dPresent and Settings.force2dPresent() then return end
  if not (VoxelAtmos and VoxelAtmos.handlesRainbow and VoxelAtmos.handlesRainbow()) then return end
  local okV, Voxel3D = pcall(function() return HostV.require("Voxel3D") end)
  if not okV or not Voxel3D or type(Voxel3D.project) ~= "function" then return end
  pcall(Rainbow.draw3D, Voxel3D, w, h, horizonY, cell, skyRay)
end

function Core.paintOverlay(w, h)
  if not Core.installed or not Draw or not Scene then return end
  if Core.lastLevel <= 0 then return end
  w, h = tonumber(w) or 0, tonumber(h) or 0
  if w <= 1 or h <= 1 then return end
  local scale = h / 144
  if scale <= 0 then scale = 1 end
  pcall(Scene.setViewport, { x = 0, y = 0, w = w, h = h, scale = scale })
  local ok, err = pcall(Draw.frame, 0, 0, w, h, scale, false)
  if not ok then
    Core.lastError = tostring(err)
    if hostMod and hostMod.log then hostMod.log:warn("Weather FX draw failed safely: %s", Core.lastError) end
    return
  end
  Core.draws = Core.draws + 1
end

function Core.mode()
  if not State or not State.current then return "CLEAR" end
  local def = State.current()
  if type(def) == "table" then return tostring(def.id or "CLEAR") end
  return tostring(State.id or def or "CLEAR")
end

function Core.hasRain()
  return State and State.channel and (tonumber(State.channel("rain")) or 0) > 0.04 or false
end

function Core.hasFog()
  return State and State.channel and (tonumber(State.channel("fog")) or 0) > 0.04 or false
end

function Core.invalidate()
  if Draw and Draw.invalidate then pcall(Draw.invalidate) end
  if Audio and Audio.invalidate then pcall(Audio.invalidate) end
  if VoxelAtmos and VoxelAtmos.invalidate then pcall(VoxelAtmos.invalidate) end
end

function Core.status()
  return {
    installed = Core.installed,
    error = Core.lastError,
    weather = Core.mode(),
    level = Core.lastLevel,
    updates = Core.updates,
    draws = Core.draws,
    voxel = VoxelAtmos and VoxelAtmos.reason and VoxelAtmos.reason() or "not-ready",
    source = "Weather FX 4.10.0",
    settings = Settings and {
      mode = snapshotValue("weatherMode"), quality = snapshotValue("quality"),
      intensity = snapshotValue("intensity"), speed = snapshotValue("speed"),
      lightning = snapshotValue("lightning"), present = snapshotValue("present"),
    } or nil,
  }
end

Core.WX = WX
return Core
