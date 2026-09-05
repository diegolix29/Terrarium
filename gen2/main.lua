-- Terrarium Advance Voxel Mod - Gen 2 Backend
--
-- Gen 2-specific backend with full feature set, using Gen 2 voxel rendering bridges.

local mod = ...

local IS_GEN2 = true
mod.log:info("Terrarium Advance Voxel Mod: Gen 2 backend loading")

-- ------- the mod namespace
local V = { mod = mod, path = mod.path }

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then
    error(("TERRARIUM: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("TERRARIUM: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  return chunk
end

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local value = chunkFor("lib/" .. name .. ".lua")(V)
  modules[name] = value
  return value
end

local dataFiles = {}
function V.data(name)
  local hit = dataFiles[name]
  if hit ~= nil then return hit end
  local value = chunkFor("data/" .. name .. ".lua")(V)
  dataFiles[name] = value
  return value
end

-- ------- load core voxel modules
local VoxelScene = V.require("VoxelScene")
local Voxel3D = V.require("Voxel3D")
local Voxel = V.require("VoxelState")
local ChunkMesher = V.require("ChunkMesher")
local TerrainAtlas = V.require("TerrainAtlas")
local Grass3D = V.require("Grass3D")
local Water = V.require("Water")
local GroundFX = V.require("GroundFX")
local MiniMap = V.require("MiniMap")
local Mat4 = V.require("Mat4")
local ShadowMap = V.require("ShadowMap")
local SpriteBillboards = V.require("SpriteBillboards")
local Quality = V.require("Quality")
local VoxelGrid = V.require("VoxelGrid")
local WorldCurve = V.require("WorldCurve")
local Aerial = V.require("Aerial")
local Skyline = V.require("Skyline")
local ViewBox = V.require("ViewBox")
local TiltShift = V.require("TiltShift")
local Vfx = V.require("Vfx")
local Wind = V.require("Wind")
local WindFX = V.require("WindFX")
local Weather = V.require("Weather")
local Sky = V.require("Sky")
local Light = V.require("Light")
local RayFX = V.require("RayFX")
local Anime = V.require("Anime")
local ForestAtmos = V.require("ForestAtmos")
local Shadows = V.require("Shadows")
local AntiAlias = V.require("AntiAlias")
local DrawDistance = V.require("DrawDistance")
local DayNight = V.require("DayNight")
local StreetLamps = V.require("StreetLamps")
local Ecology = V.require("Ecology")
local AmbientLife = V.require("AmbientLife")
local Interiors = V.require("Interiors")
local CityLife = V.require("CityLife")
local Shelter = V.require("Shelter")
local Carry = V.require("Carry")
local Routines = V.require("Routines")
local AutoFarm = V.require("AutoFarm")
local QoL = V.require("QoL")
local HiddenItems = V.require("HiddenItems")
local ExpShare = V.require("ExpShare")
local Comforts = V.require("Comforts")
local Shiny = V.require("Shiny")
local ShinyBattle = V.require("ShinyBattle")
local ShinyUI = V.require("ShinyUI")
local DayTint = V.require("DayTint")
local FirstPerson = V.require("FirstPerson")
local FreeMove = V.require("FreeMove")
local CamControl = V.require("CamControl")
local Horde = V.require("Horde")
local HordeGun = V.require("HordeGun")
local LetsGo = V.require("LetsGo")
local Follower = V.require("follower/init")
local FollowersWaterCompat = V.require("followers_water_compat")
local FollowerSettings = V.require("follower/settings")
local SpriteResolver = V.require("sprite_resolver")
local Config = V.require("config")
local SettingsMenu = V.require("SettingsMenu")
local ModSetting = V.require("ModSetting")
local OptionRows = V.require("OptionRows")
local Ceiling = V.require("Ceiling")
local Backdrop = V.require("Backdrop")
local SkyLayer = V.require("SkyLayer")
local Flora = V.require("Flora")

-- ------- battles/wildlife/vr/sound, ported over from the Gen 1 backend
-- These lib/ modules already existed and were already loaded by Gen 1's
-- main.lua; Gen 2's port simply never required them, so none of their
-- settings rows, installs or per-frame updates ever ran here. WildRoamers
-- already special-cases Gen 2's Player module internally (see
-- lib/WildRoamers.lua), and OverworldBattle/AmbientSound/VR are engine-
-- generation-agnostic, so they are safe to wire in the same way Gen 1 does.
local OverworldBattle = V.require("OverworldBattle")
local WildRoamers = V.require("WildRoamers")
local AmbientSound = V.require("AmbientSound")
local VR = V.require("VR")

-- Stadium 2 model support (Gen 2 Pokemon 152-251) -- optional, only added
-- to the settings menu if the module loaded. Ported from Gen 1's main.lua;
-- the actual per-frame ROM-picker polling and build-progress screen push
-- live in Gen2VoxelBridge.Bridge.updateBattle (see lib/Gen2VoxelBridge.lua),
-- since that already runs every frame unconditionally.
local okS2, Stadium2Setting = pcall(V.require, "Stadium2Setting")

-- ------- Gen 2 voxel rendering bridges
local Gen2VoxelBridge = V.require("Gen2VoxelBridge")
local GoldVoxelBridge = V.require("GoldVoxelBridge")
local GoldPipelineBridge = V.require("GoldPipelineBridge")
local GoldComposeBridge = V.require("GoldComposeBridge")

-- ------- constants
local PIPE_VOXEL = "voxel"
local PIPE_TILT = "tiltshift"

local KEY_VOXEL = "v"
local KEY_TILT = "t"
local KEY_GRID = "g"
local KEY_CURVE = "c"
local KEY_HAZE = "h"
local KEY_SKYLINE = "k"
local KEY_MAP = "p"
local KEY_FX = "j"
local KEY_JUMP = "space"

V.KEYS = {
  VOXEL = KEY_VOXEL,
  TILT = KEY_TILT,
  GRID = KEY_GRID,
  CURVE = KEY_CURVE,
  HAZE = KEY_HAZE,
  SKYLINE = KEY_SKYLINE,
  MAP = KEY_MAP,
  FX = KEY_FX,
  JUMP = KEY_JUMP,
}

-- ------- install Gen 2 voxel bridges
local okBridge, bridgeErr = pcall(Gen2VoxelBridge.install, mod, V)
if not okBridge then
  mod.log:warn("Gen2VoxelBridge install failed: %s", tostring(bridgeErr))
end

local okGoldVoxel, goldVoxelErr = pcall(GoldVoxelBridge.install, mod, V)
if not okGoldVoxel then
  mod.log:warn("GoldVoxelBridge install failed: %s", tostring(goldVoxelErr))
end

-- GoldPipelineBridge needs the VoxelBridge reference
local okGoldPipeline, goldPipelineErr = pcall(GoldPipelineBridge.install, mod, Gen2VoxelBridge)
if not okGoldPipeline then
  mod.log:warn("GoldPipelineBridge install failed: %s", tostring(goldPipelineErr))
else
  -- Sync the pipeline to set initial level
  pcall(GoldPipelineBridge.sync)
  mod.log:info("GoldPipelineBridge synced")
  -- Also sync on game.ready to ensure it's active when game loads
  mod.events:on("game.ready", function(ev)
    pcall(GoldPipelineBridge.sync, ev)
    mod.log:info("GoldPipelineBridge synced on game.ready")
  end)

  -- Hook engine's Pipelines to preserve our pipeline level
  local Pipelines = require("src.render.Pipelines")

  -- Removed Pipelines function hook logging (was clogging logs every frame)

  -- Hook applyOptions to preserve voxel pipeline level
  if Pipelines and type(Pipelines.applyOptions) == "function" then
    local originalApplyOptions = Pipelines.applyOptions
    Pipelines.applyOptions = function(...)
      -- Save current voxel pipeline level before applyOptions
      local savedVoxelLevel = 0
      local okRead, current = pcall(Pipelines.level, "stadium2_gold_voxel")
      if okRead and current ~= nil then
        savedVoxelLevel = tonumber(current) or 0
      end

      if mod and mod.log and savedVoxelLevel > 0 then
        mod.log:info("Pipelines.applyOptions: saving voxel level %d before apply", savedVoxelLevel)
      end

      -- Call original applyOptions
      local ok, result = pcall(originalApplyOptions, ...)

      -- Restore voxel pipeline level if it was reset to 0
      if ok then
        local newLevel = 0
        local okRead2, current2 = pcall(Pipelines.level, "stadium2_gold_voxel")
        if okRead2 and current2 ~= nil then
          newLevel = tonumber(current2) or 0
        end

        if savedVoxelLevel > 0 and newLevel == 0 then
          if mod and mod.log then
            mod.log:info("Pipelines.applyOptions: restoring voxel level from %d to %d after apply", newLevel, savedVoxelLevel)
          end
          pcall(Pipelines.setLevel, "stadium2_gold_voxel", savedVoxelLevel)
        end
      end

      return ok and result or nil
    end
    mod.log:info("Hooked Pipelines.applyOptions to preserve voxel pipeline level")
  end

  -- Hook syncOptions to preserve voxel pipeline level
  if Pipelines and type(Pipelines.syncOptions) == "function" then
    local originalSyncOptions = Pipelines.syncOptions
    Pipelines.syncOptions = function(...)
      -- Save current voxel pipeline level before sync
      local savedVoxelLevel = 0
      local okRead, current = pcall(Pipelines.level, "stadium2_gold_voxel")
      if okRead and current ~= nil then
        savedVoxelLevel = tonumber(current) or 0
      end

      if mod and mod.log and savedVoxelLevel > 0 then
        mod.log:info("Pipelines.syncOptions: saving voxel level %d before sync", savedVoxelLevel)
      end

      -- Call original syncOptions
      local ok, result = pcall(originalSyncOptions, ...)

      -- Restore voxel pipeline level if it was reset to 0
      if ok then
        local newLevel = 0
        local okRead2, current2 = pcall(Pipelines.level, "stadium2_gold_voxel")
        if okRead2 and current2 ~= nil then
          newLevel = tonumber(current2) or 0
        end

        if savedVoxelLevel > 0 and newLevel == 0 then
          if mod and mod.log then
            mod.log:info("Pipelines.syncOptions: restoring voxel level from %d to %d after sync", newLevel, savedVoxelLevel)
          end
          pcall(Pipelines.setLevel, "stadium2_gold_voxel", savedVoxelLevel)
        end
      end

      return ok and result or nil
    end
    mod.log:info("Hooked Pipelines.syncOptions to preserve voxel pipeline level")
  end

  -- Hook setLevel to track who's resetting the pipeline
  if Pipelines and type(Pipelines.setLevel) == "function" then
    local originalSetLevel = Pipelines.setLevel
    local setLevelCallCount = 0
    local initialized = false
    Pipelines.setLevel = function(id, level, ...)
      setLevelCallCount = setLevelCallCount + 1

      -- Log ALL setLevel calls for stadium2_gold_voxel
      if id == "stadium2_gold_voxel" and mod and mod.log then
        local currentLevel = 0
        local okRead, current = pcall(Pipelines.level, id)
        if okRead and current ~= nil then
          currentLevel = tonumber(current) or 0
        end
        local newLevel = tonumber(level) or 0
        mod.log:info("Pipelines.setLevel: %s %d -> %d (Call #%d)", id, currentLevel, newLevel, setLevelCallCount)
      end

      -- Allow first setLevel call (initial sync from mod options)
      if not initialized and id == "stadium2_gold_voxel" then
        initialized = true
        return originalSetLevel(id, level, ...)
      end

      -- Log if someone is trying to reset our voxel pipeline to 0 when it's non-zero
      if id == "stadium2_gold_voxel" and (tonumber(level) or 0) == 0 then
        local currentLevel = 0
        local okRead, current = pcall(Pipelines.level, id)
        if okRead and current ~= nil then
          currentLevel = tonumber(current) or 0
        end
        if currentLevel > 0 and mod and mod.log then
          mod.log:warn("Pipelines.setLevel: BLOCKING reset voxel pipeline from %d to 0. Call #%d",
            currentLevel, setLevelCallCount)
          -- Don't allow the reset
          return
        end
      end

      return originalSetLevel(id, level, ...)
    end
    mod.log:info("Hooked Pipelines.setLevel to prevent voxel pipeline reset")
  end
end

local okGoldCompose, goldComposeErr = pcall(GoldComposeBridge.install, mod, Gen2VoxelBridge, GoldPipelineBridge)
if not okGoldCompose then
  mod.log:warn("GoldComposeBridge install failed: %s", tostring(goldComposeErr))
end

-- ------- install GoldCameraControls for Gen 2 free movement
local GoldCameraControls = V.require("GoldCameraControls")
local okInstall, installErr = pcall(GoldCameraControls.install)
if okInstall then
  mod.log:info("GoldCameraControls installed for Gen 2 free movement")
else
  mod.log:warn("GoldCameraControls install failed: %s", tostring(installErr))
end

-- ------- register tilt-shift pipeline
mod.content.render_pipelines:register(PIPE_TILT, {
  label = "T-SHIFT",
  levels = TiltShift.LABELS,
  hotkey = KEY_TILT,
  priority = 10,
  update = function(dt, level)
    TiltShift.update(dt, level)
  end,
  worldPresent = function(canvas)
    canvas = TiltShift.apply(canvas)
    if (TiltShift.level or 0) > 0 then
      canvas = MiniMap.present(canvas)
    end
    return canvas
  end,
  invalidate = function()
    TiltShift.invalidate()
  end,
})

-- ------- follower water compat
V.followersWater = FollowersWaterCompat.new(mod, {
  resolveWaterSprite = function(speciesId, shiny, form, o)
    if SpriteResolver and SpriteResolver.resolveFollowerSprite then
      return SpriteResolver:resolveFollowerSprite({
        species = speciesId,
        shiny = shiny,
        form = form,
        surface = "surfing",
        style = Config.spriteStyle(mod),
        role = "primary",
      })
    end
    return nil
  end,
  resolveLandSprite = function(speciesId, shiny, form, o)
    if SpriteResolver and SpriteResolver.resolveFollowerSprite then
      return SpriteResolver:resolveFollowerSprite({
        species = speciesId,
        shiny = shiny,
        form = form,
        surface = "land",
        style = Config.spriteStyle(mod),
        role = "primary",
      })
    end
    return nil
  end,
})

-- ------- follower settings
local followControlSetting = ModSetting.new(
  "follow_control",
  "FOLLOW CONTROL",
  { "trainer", "pokemon" },
  { "TRAINER", "POKÉMON" }
)

local trainerTrailSetting = ModSetting.new(
  "trainer_trail",
  "TRAINER TRAIL",
  { true, false },
  { "ON", "OFF" }
)

local followerCountSetting = ModSetting.new(
  "follower_count",
  "FOLLOWER COUNT",
  { "0", "1", "2", "3", "4", "5", "6" },
  { "0", "1", "2", "3", "4", "5", "6" }
)

-- ------- StadiumBattleFX settings (ported from Gen 1 backend)
local stadiumFxEnabled = ModSetting.new("stadiumFxPortEnabled", "STADIUM FX",
  { true, false }, { "ON", "OFF" })
local stadiumTrainerPortraits = ModSetting.new("stadiumTrainerPortraits", "TRAINER PORTRAITS",
  { true, false }, { "ON", "OFF" })
local stadiumFxAttackCamera = ModSetting.new("stadiumFxAttackCamera", "ATTACK CAMERA",
  { true, false }, { "ON", "OFF" })
local stadiumFxAttackSpeed = ModSetting.new("stadiumFxAttackSpeed", "ATTACK SPEED",
  { "50", "75", "100", "125", "150" }, { "50%", "75%", "100%", "125%", "150%" })
local stadiumAnnouncer = ModSetting.new("stadiumAnnouncer", "ANNOUNCER",
  { true, false }, { "ON", "OFF" })
local stadiumAnnouncerScope = ModSetting.new("stadiumAnnouncerScope", "ANNOUNCER SCOPE",
  { "gym", "trainer", "all" }, { "GYM ONLY", "TRAINER", "ALL BATTLES" })
local stadiumFxCinematicZoom = ModSetting.new("stadiumFxCinematicZoom", "CINEMATIC ZOOM",
  { "off", "10", "25", "50" }, { "OFF", "10%", "25%", "50%" })
local stadiumBossArenas = ModSetting.new("stadiumBossArenas", "BOSS ARENAS",
  { true, false }, { "ON", "OFF" })
local stadiumFxScreenEffects = ModSetting.new("stadiumFxScreenEffects", "SCREEN EFFECTS",
  { true, false }, { "ON", "OFF" })
local stadiumFxHitReactions = ModSetting.new("stadiumFxHitReactions", "HIT REACTIONS",
  { true, false }, { "ON", "OFF" })
local stadiumFxFaintAnimations = ModSetting.new("stadiumFxFaintAnimations", "FAINT ANIMATIONS",
  { true, false }, { "ON", "OFF" })
local stadiumFxNativeScheduler = ModSetting.new("stadiumFxNativeScheduler", "NATIVE SCHEDULER",
  { true, false }, { "ON", "OFF" })
local stadiumFxNativeSync = ModSetting.new("stadiumFxNativeSync", "NATIVE SYNC",
  { true, false }, { "ON", "OFF" })
local stadiumFxFallbackNotice = ModSetting.new("stadiumFxFallbackNotice", "FALLBACK NOTICE",
  { true, false }, { "ON", "OFF" })
local stadiumFx2DLayer = ModSetting.new("stadiumFx2DLayer", "2D EFFECT LAYER",
  { "authentic", "all", "off" }, { "AUTHENTIC", "ALL", "OFF" })

-- ------- ds_fp_ceiling settings (ported from Gen 1 backend)
-- These feed lib/Ceiling.lua, lib/Backdrop.lua, lib/SkyLayer.lua and
-- lib/Flora.lua through the _G.__ds_ceiling_config bridge below. Without
-- that bridge those four modules see no companion config, mark themselves
-- "orphaned" and quietly no-op -- which is why ceilings, the horizon
-- backdrop, the sky layer and forest flora never rendered on Gen 2.
local fpShadows = ModSetting.new("fpshadows", "CONTACT SHADOW", { true, false }, { "ON", "OFF" })
local fpRails = ModSetting.new("fprails", "RAIL AND SKIRTING", { true, false }, { "ON", "OFF" })
local fpSpill = ModSetting.new("fpspill", "DOORWAY LIGHT", { true, false }, { "ON", "OFF" })
local fpFittings = ModSetting.new("fpfittings", "CEILING LAMPS", { true, false }, { "ON", "OFF" })
local fpBacks = ModSetting.new("fpbacks", "BUILDING BACKS", { true, false }, { "ON", "OFF" })
local fpRock = ModSetting.new("fprock", "CAVE ROCK", { true, false }, { "ON", "OFF" })
local fpPools = ModSetting.new("fppools", "CAVE POOLS", { true, false }, { "ON", "OFF" })
local fpSconces = ModSetting.new("fpsconces", "CAVE TORCHES", { true, false }, { "ON", "OFF" })
local fpBats = ModSetting.new("fpbats", "BATS", { true, false }, { "ON", "OFF" })
local fpDark = ModSetting.new("fpdark", "CAVE DARKNESS", { true, false }, { "ON", "OFF" })
local fpThird = ModSetting.new("fpthird", "3RD CEILING", { "NONE", "CUTAWAY", "FULL" }, { "NONE", "CUTAWAY", "FULL" })
local fpBackdrop = ModSetting.new("fpbackdrop", "HORIZON", { true, false }, { "ON", "OFF" })
local fpHorizonart = ModSetting.new("fphorizonart", "HORIZON ART", { "KANTO", "FUJI", "VALLEY", "CITY" }, { "KANTO", "FUJI", "VALLEY", "CITY" })
local fpClouds = ModSetting.new("fpclouds", "CLOUDS", { true, false }, { "ON", "OFF" })
local fpStars = ModSetting.new("fpstars", "NIGHT SKY", { true, false }, { "ON", "OFF" })
local fpBirds = ModSetting.new("fpbirds", "BIRDS", { true, false }, { "ON", "OFF" })
local fpAircraft = ModSetting.new("fpaircraft", "AIRCRAFT", { true, false }, { "ON", "OFF" })
local fpRainbows = ModSetting.new("fprainbows", "RAINBOWS", { true, false }, { "ON", "OFF" })
local fpRain = ModSetting.new("fprain", "RAIN", { "OFF", "SOMETIMES", "ALWAYS" }, { "OFF", "SOMETIMES", "ALWAYS" })
local fpLightning = ModSetting.new("fplightning", "LIGHTNING", { true, false }, { "ON", "OFF" })
local fpUmbrellas = ModSetting.new("fpumbrellas", "NPC UMBRELLAS", { true, false }, { "ON", "OFF" })
local fpPuddles = ModSetting.new("fppuddles", "PUDDLES", { true, false }, { "ON", "OFF" })
local fpGrass = ModSetting.new("fpgrass", "GRASS HEIGHT", { "OFF", "SUBTLE", "WILD" }, { "OFF", "SUBTLE", "WILD" })
local fpWind = ModSetting.new("fpwind", "WIND", { "OFF", "BREEZE", "GUSTY" }, { "OFF", "BREEZE", "GUSTY" })
local fpParticles = ModSetting.new("fpparticles", "PARTICLES", { true, false }, { "ON", "OFF" })
local fpInsects = ModSetting.new("fpinsects", "INSECTS", { true, false }, { "ON", "OFF" })
local fpGroundflock = ModSetting.new("fpgroundflock", "GROUND FLOCK", { true, false }, { "ON", "OFF" })
local fpCanopy = ModSetting.new("fpcanopy", "FOREST CANOPY", { true, false }, { "ON", "OFF" })
local fpVines = ModSetting.new("fpvines", "HANGING VINES", { true, false }, { "ON", "OFF" })
local fpShafts = ModSetting.new("fpshafts", "SUN SHAFTS", { true, false }, { "ON", "OFF" })
local fpFog = ModSetting.new("fpfog", "LAVENDER FOG", { true, false }, { "ON", "OFF" })
local fpLights = ModSetting.new("fplights", "LAMPLIGHT", { true, false }, { "ON", "OFF" })
local fpJump = ModSetting.new("fpjump", "JUMP FEEL", { "OFF", "SUBTLE", "BIG" }, { "OFF", "SUBTLE", "BIG" })
local fpDoorstep = ModSetting.new("fpdoorstep", "DOORWAY STEP", { true, false }, { "ON", "OFF" })

-- ------- mod settings
local voxel3dSetting = ModSetting.new(
  "voxel3d",
  "VOXEL 3D",
  { "0", "1", "2", "3", "4", "5", "6", "7" },
  { "OFF", "FULL", "15", "35", "50", "75", "1ST", "3RD" }
)

-- Whether battles are staged on the map at all -- OverworldBattle.begin and
-- wantsFront both gate on enabled() alone, so this helper (used only by the
-- BACK SPRITES row's `when`) mirrors that same single source of truth.
local function stagedBattles()
  return OverworldBattle and OverworldBattle.enabled() or false
end

local SETTINGS = {
  { voxel3dSetting, "Voxel 3D rendering level.", full = true, cat = "world" },
  { Quality.setting, "Resolution quality.", full = true, cat = "perf" },
  { Quality.shadowSetting, "Shadow quality.", full = true, cat = "perf" },
  { ForestAtmos.setting, "Forest atmosphere.", full = true, cat = "perf" },
  { Shadows.setting, "Real shadows.", full = true, cat = "perf" },
  { AntiAlias.setting, "Anti-aliasing.", full = true, cat = "perf" },
  { DrawDistance.setting, "Draw distance.", full = true, cat = "perf" },
  { Grass3D.simpleMeshes, "Simple grass meshes.", full = true, cat = "perf" },
  { Wind.setting, "Wind effect.", full = true, cat = "weather" },
  { Water.setting, "3D water.", full = true, cat = "world" },
  { Light.setting, "Lighting.", full = true, cat = "world" },
  { RayFX.setting, "Ray tracing effects.", full = true, cat = "fx" },
  { Anime.setting, "Cel animation.", full = true, cat = "fx" },
  { Vfx.setting, "Impact effects.", full = true, cat = "fx" },
  { AmbientLife and AmbientLife.setting, "Ambient life.", full = true, cat = "wildlife" },
  { Weather.setting, "Weather system.", full = true, cat = "weather" },
  { Sky.cloudSetting, "Clouds.", full = true, cat = "weather" },
  { GroundFX.setting, "Ground effects.", when = function() return Weather.enabled() end, full = true, cat = "weather" },
  { Interiors and Interiors.setting, "Interior details.", full = true, cat = "town" },
  { CityLife and CityLife.setting, "City Pokemon.", full = true, cat = "town" },
  { Shelter and Shelter.setting, "Shelter behavior.", when = function() return Weather.enabled() end, full = true, cat = "town" },
  { Carry.setting, "Bag capacity.", full = true, cat = "qol" },
  { Carry.stackSetting, "Item stack size.", full = true, cat = "qol" },
  { Routines and Routines.setting, "NPC routines.", full = true, cat = "town" },
  { AutoFarm and AutoFarm.setting, "Auto-farm bot.", full = true, cat = "qol" },
  { QoL and QoL.setting, "Quality of life.", full = true, cat = "qol" },
  { ExpShare.setting, "Exp share.", full = true, cat = "qol" },
  { VoxelGrid.setting, "Voxel grid.", cat = "world" },
  { WorldCurve.setting, "World curve.", cat = "world" },
  { Aerial.setting, "Aerial haze.", cat = "world" },
  { Skyline.setting, "Skyline.", cat = "world" },
  { ViewBox.setting, "View box.", full = true, cat = "world" },
  { MiniMap.setting, "Minimap.", full = true, cat = "world" },
  { DayNight.setting, "Time of day.", cat = "world" },
  { DayNight.darkSetting, "Night darkness.", full = true, cat = "world" },
  { StreetLamps and StreetLamps.setting, "Street lamps.", full = true, cat = "world" },
  { Ecology.setting, "Ecology.", full = true, cat = "wildlife" },
  { Shiny.setting, "Shiny rate.", cat = SettingsMenu.ROOT, full = true },

  -- ------- Stadium 2 models support (ported from Gen 1 backend)
  okS2 and Stadium2Setting and { Stadium2Setting.setting,
    "Enable Pokemon Stadium 2 models for Gen 2 Pokemon (152-251). "
    .. "Requires a Pokemon Stadium 2 (US) ROM. When ON, Gen 2 Pokemon use "
    .. "Stadium 2 models instead of sprites. When OFF, all Pokemon use "
    .. "sprites or Stadium 1 models.",
    full = true, cat = "battles" },
  { followControlSetting, "Follower control.", cat = "followers" },
  { trainerTrailSetting, "Trainer trail.", cat = "followers" },
  { followerCountSetting, "Follower count.", cat = "followers" },

  -- ------- ambient sound (ported from Gen 1 backend)
  { AmbientSound and AmbientSound.setting,
    "The sound of the place: crickets after dark, birdsong through the day, "
    .. "water, rain and thunder.", full = true, cat = "weather" },

  -- ------- battles on the map (ported from Gen 1 backend)
  { LetsGo.setting,
    "Pokemon GO-style catching -- flick to throw the ball, with FULL "
    .. "adding half-price balls and party experience (needs 3D-BTL).",
    full = true, cat = "battles" },
  { OverworldBattle and OverworldBattle.setting,
    "Fight on the map: the battle draws over the nearest clear ground, "
    .. "shot over the shoulder with a slow parallax drift.",
    when = function() return not VR.enabled() end,
    full = true, cat = "battles" },
  { OverworldBattle and OverworldBattle.backSetting,
    "Keep your own Pokemon on the battle menu, seen from behind in its "
    .. "original slot, instead of standing it on the map facing the foe.",
    when = function() return stagedBattles() and not VR.enabled() end,
    full = true, cat = "battles" },

  -- ------- StadiumBattleFX settings (ported from Gen 1 backend)
  { stadiumFxEnabled,
    "Enables Pokemon Stadium-style battle effects, including attack animations, "
    .. "camera movements, and presentation enhancements.", cat = "battles" },
  { stadiumTrainerPortraits,
    "Shows Stadium-style trainer portraits during battles.", cat = "battles" },
  { stadiumFxAttackCamera,
    "Enables dynamic camera movements during attack animations.", cat = "battles" },
  { stadiumFxAttackSpeed,
    "Adjusts the speed of attack animations.", cat = "battles" },
  { stadiumAnnouncer,
    "Enables the Stadium announcer voice during battles.", cat = "battles" },
  { stadiumAnnouncerScope,
    "Controls when the announcer speaks: gym only, trainer, or all battles.",
    cat = "battles" },
  { stadiumFxCinematicZoom,
    "Controls the intensity of camera zoom effects during powerful attacks.",
    cat = "battles" },
  { stadiumBossArenas,
    "Enables special gym leader and Elite Four arena backgrounds.", cat = "battles" },
  { stadiumFxScreenEffects,
    "Enables screen-wide effects like flashes, shakes, and color tints.", cat = "battles" },
  { stadiumFxHitReactions,
    "Enables Pokemon flinch and recoil animations when taking damage.", cat = "battles" },
  { stadiumFxFaintAnimations,
    "Enables special Pokemon fainting animations when HP reaches zero.", cat = "battles" },
  { stadiumFxNativeScheduler,
    "Uses the game's native animation timing for Stadium effects.", cat = "battles" },
  { stadiumFxNativeSync,
    "Syncs Stadium model animations with the game's battle timing.", cat = "battles" },
  { stadiumFxFallbackNotice,
    "Shows a notification when Stadium effects fall back to generic animations.",
    cat = "battles" },
  { stadiumFx2DLayer,
    "Controls which 2D battle effects are shown: authentic, all, or none.",
    cat = "battles" },

  -- ------- wild Pokemon standing in the grass (ported from Gen 1 backend)
  { WildRoamers and WildRoamers.setting,
    "Wild Pokemon you can see: the map's own encounter table decides who is "
    .. "standing in the grass right now, and the fight starts when you walk "
    .. "into one. ROAM switches the blind roll off; MIX leaves it on as well; "
    .. "OFF is the dice alone.",
    full = true, cat = "wildlife" },
  { WildRoamers and WildRoamers.countSetting,
    "How many wild Pokemon stand within reach at once.",
    when = function() return WildRoamers.enabled() end, full = true, cat = "wildlife" },

  -- ------- VR (ported from Gen 1 backend)
  { VR.setting,
    "PCVR through OpenXR on Windows, either following the VOXEL ladder "
    .. "or as a DIORAMA you carry and turn with the grips.",
    when = function() return VR.supported() end, full = true, cat = "vr" },
  { VR.smoothTurn,
    "Turns smoothly with the right stick instead of snapping 45 degrees.",
    when = function() return VR.enabled() and not VR.dioramaMode() end,
    cat = "vr" },

  -- ------- ds_fp_ceiling integrated settings (ported from Gen 1 backend)
  { Ceiling.setting,
    "Interior ceilings and walls in first-person mode. Rooms get walls, "
    .. "ceilings with configurable headroom, and proper doors.", cat = "world" },
  { Ceiling.headroom, "Ceiling height: AIRY (32px), MID (24px), or SNUG (16px).", cat = "world" },
  { Ceiling.cutaway, "Sims-style cutaway in diorama view.", cat = "world" },
  { fpShadows, "Contact shadows under furniture and props.", cat = "world" },
  { fpRails, "Rail and skirting boards along walls.", cat = "world" },
  { fpSpill, "Light spilling from doorways into dark rooms.", cat = "world" },
  { fpFittings, "Ceiling lamps and light fixtures.", cat = "world" },
  { fpBacks, "Building backs - rear walls on exterior buildings.", cat = "world" },
  { fpRock, "Rock formations in caves.", cat = "world" },
  { fpPools, "Water pools in cave floors.", cat = "world" },
  { fpSconces, "Wall torches in caves.", cat = "world" },
  { fpBats, "Flying bats in caves.", cat = "world" },
  { fpDark, "Cave darkness effect in unlit areas.", cat = "world" },
  { fpThird, "Ceiling visibility in third-person mode: NONE, CUTAWAY, or FULL.", cat = "world" },
  { fpBackdrop, "Distant horizon backdrop for outdoor maps.", cat = "world" },
  { fpHorizonart, "Horizon art style: KANTO, FUJI, VALLEY, or CITY.", cat = "world" },
  { fpClouds, "Clouds drifting across the sky.", cat = "world" },
  { fpStars, "Stars and nebula at night.", cat = "world" },
  { fpBirds, "Birds flying in the sky.", cat = "world" },
  { fpAircraft, "Rare aircraft (planes and blimps) in the sky.", cat = "world" },
  { fpRainbows, "Rainbows after rain showers.", cat = "world" },
  { fpRain, "Rain frequency: OFF, SOMETIMES, or ALWAYS.", cat = "world" },
  { fpLightning, "Lightning during storms.", cat = "world" },
  { fpUmbrellas, "NPCs open umbrellas during rain.", cat = "world" },
  { fpPuddles, "Puddles form on the ground during rain.", cat = "world" },
  { fpGrass, "Grass height: OFF, SUBTLE, or WILD.", cat = "world" },
  { fpWind, "Wind effect on grass: OFF, BREEZE, or GUSTY.", cat = "world" },
  { fpParticles, "Particle effects (seeds, drips, fireflies, etc.).", cat = "world" },
  { fpInsects, "Insects buzzing around.", cat = "world" },
  { fpGroundflock, "Ground flocks of birds that flush when approached.", cat = "world" },
  { fpCanopy, "Forest canopy overhead.", cat = "world" },
  { fpVines, "Hanging vines in forests.", cat = "world" },
  { fpShafts, "Sun shafts through forest canopy.", cat = "world" },
  { fpFog, "Lavender Town fog effect.", cat = "world" },
  { fpLights, "Street lamps and town lighting.", cat = "world" },
  { fpJump, "Jump feel: OFF, SUBTLE, or BIG.", cat = "world" },
  { fpDoorstep, "Step up/down when passing through doorways.", cat = "world" },
}

local filtered = {}
for _, row in ipairs(SETTINGS) do
  if row[1] ~= nil then filtered[#filtered + 1] = row end
end
SETTINGS = filtered

local schema = {}
for i, entry in ipairs(SETTINGS) do
  if type(entry[1]) == "table" and type(entry[1].schema) == "function" then
    schema[#schema + 1] = entry[1]:schema(entry[2])
  end
end
mod.options:define(schema)
SettingsMenu.define(SETTINGS)

-- ------- ds_fp_ceiling config bridge (ported from Gen 1 backend)
--
-- The Ceiling, Backdrop, SkyLayer and Flora modules expect a companion
-- mod (ds_fp_ceiling) to publish configuration via _G.__ds_ceiling_config.
-- Without this bridge those four modules see no companion config, mark
-- themselves "orphaned" and quietly disable -- this is the actual fix for
-- ceilings, the horizon backdrop, the sky layer and forest flora not
-- rendering on Gen 2.
local HEADROOM = { AIRY = 32, MID = 24, SNUG = 16 }
_G.__ds_ceiling_config = function()
  local ceilingOn = true
  local headroomVal = 32
  local cutawayOn = true
  if Ceiling and Ceiling.setting then
    local ok, v = pcall(function() return Ceiling.setting:get() end)
    if ok then ceilingOn = (v ~= false) end
  end
  if Ceiling and Ceiling.headroom then
    local ok, v = pcall(function() return Ceiling.headroom:get() end)
    if ok and v then headroomVal = HEADROOM[v] or 32 end
  end
  if Ceiling and Ceiling.cutaway then
    local ok, v = pcall(function() return Ceiling.cutaway:get() end)
    if ok then cutawayOn = (v ~= false) end
  end

  local function getSetting(settingObj, default)
    if settingObj then
      local ok, v = pcall(function() return settingObj:get() end)
      if ok then return v end
    end
    return default
  end

  local horizonArt = getSetting(fpHorizonart, "VALLEY")
  local backdropMap = { KANTO = "backdrop.png", FUJI = "backdrop2.png", VALLEY = "backdrop3.png", CITY = "backdrop4.png" }
  local backdropFile = backdropMap[horizonArt] or "backdrop.png"
  _G.__ds_backdrop_path = mod.path .. "/lib/" .. backdropFile

  return {
    ceiling = ceilingOn,
    headroom = headroomVal,
    cutaway = cutawayOn,
    shadows = getSetting(fpShadows, true) ~= false,
    rails = getSetting(fpRails, true) ~= false,
    spill = getSetting(fpSpill, true) ~= false,
    fittings = getSetting(fpFittings, true) ~= false,
    rock = getSetting(fpRock, true) ~= false,
    backs = getSetting(fpBacks, true) ~= false,
    pools = getSetting(fpPools, true) ~= false,
    sconces = getSetting(fpSconces, true) ~= false,
    bats = getSetting(fpBats, true) ~= false,
    third = getSetting(fpThird, "CUTAWAY"),
    backdrop = getSetting(fpBackdrop, true) ~= false,
    horizonart = horizonArt,
    jump = getSetting(fpJump, "SUBTLE"),
    grass = getSetting(fpGrass, "OFF"),
    particles = getSetting(fpParticles, true) ~= false,
    dark = getSetting(fpDark, true) ~= false,
    rain = getSetting(fpRain, "SOMETIMES"),
    umbrellas = getSetting(fpUmbrellas, true) ~= false,
    puddles = getSetting(fpPuddles, true) ~= false,
    lightning = getSetting(fpLightning, true) ~= false,
    lights = getSetting(fpLights, true) ~= false,
    shafts = getSetting(fpShafts, true) ~= false,
    canopy = getSetting(fpCanopy, true) ~= false,
    vines = getSetting(fpVines, true) ~= false,
    fog = getSetting(fpFog, true) ~= false,
    doorstep = getSetting(fpDoorstep, true) ~= false,
    clouds = getSetting(fpClouds, true) ~= false,
    stars = getSetting(fpStars, true) ~= false,
    birds = getSetting(fpBirds, true) ~= false,
    aircraft = getSetting(fpAircraft, true) ~= false,
    rainbows = getSetting(fpRainbows, true) ~= false,
    insects = getSetting(fpInsects, true) ~= false,
    groundflock = getSetting(fpGroundflock, true) ~= false,
    wind = getSetting(fpWind, "BREEZE"),
  }
end
_G.__ds_posters_dir = mod.path .. "/"

-- ------- battles on the map (ported from Gen 1 backend)
-- The wraps this needs -- OverworldState:pushBattle, BattleState:draw and
-- BattleState:drawHUDs -- all live in lib/OverworldBattle.lua.
if OverworldBattle then
  local ok, err = pcall(OverworldBattle.install)
  if ok then
    mod.log:info("OverworldBattle installed for Gen 2")
  else
    mod.log:warn("OverworldBattle install failed: %s", tostring(err))
  end
end

-- ------- wild Pokemon standing in the grass (ported from Gen 1 backend)
-- The two seams this needs -- Player:tryMove and OverworldState:talkTo --
-- live in lib/WildRoamers.lua, which already special-cases Gen 2's own
-- Player module internally.
if WildRoamers then
  local ok, err = pcall(WildRoamers.install)
  if ok then
    mod.log:info("WildRoamers installed for Gen 2")
  else
    mod.log:warn("WildRoamers install failed: %s", tostring(err))
  end
end

-- ------- what the world sounds like (ported from Gen 1 backend)
if AmbientSound then
  local ok, err = pcall(AmbientSound.register, mod)
  if ok then
    mod.log:info("AmbientSound registered for Gen 2")
  else
    mod.log:warn("AmbientSound register failed: %s", tostring(err))
  end
end

-- ------- LET'S GO, the flick-to-throw capture mode (ported from Gen 1
-- backend). Gen 1's main.lua gates this behind `if not IS_GEN2`, but that
-- check was written for a shared main.lua that was never actually shared --
-- IS_GEN2 is an undefined global there, so it silently always installs on
-- Gen 1. lib/LetsGo.lua itself has no Gen 1-only engine assumptions (it
-- only touches the generic src.core.Game / src.battle.BattleState seams),
-- so it installs the same way here.
if LetsGo then
  local ok, err = pcall(LetsGo.install)
  if ok then
    mod.log:info("LetsGo installed for Gen 2")
  else
    mod.log:warn("LetsGo install failed: %s", tostring(err))
  end
end

-- ------- ui.options.rows hook - Manual pipeline rows for Gen 2
mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end
  
  -- Use the engine's Pipelines registry (same one GoldPipelineBridge verified)
  local okPipelines, Pipelines = pcall(require, "src.render.Pipelines")
  local registry = okPipelines and Pipelines or nil
  
  -- Debug: log what the registry contains
  if Pipelines then
    mod.log:info("Pipelines type: %s, has get: %s, has setLevel: %s", type(Pipelines), tostring(type(Pipelines.get) == "function"), tostring(type(Pipelines.setLevel) == "function"))
    -- Try to list what's in the registry
    for k, v in pairs(Pipelines) do
      mod.log:info("Pipelines.%s = %s", tostring(k), tostring(type(v)))
    end
  else
    mod.log:warn("Pipelines is nil")
  end
  
  -- Helper to get current pipeline level
  local function getPipelineLevel(id)
    if Pipelines and type(Pipelines.level) == "function" then
      local ok, level = pcall(Pipelines.level, id)
      if ok and level ~= nil then
        mod.log:info("getPipelineLevel(%s) = %d", id, tonumber(level) or 0)
        return tonumber(level) or 0
      end
    end
    mod.log:info("getPipelineLevel(%s) = 0 (not found)", id)
    return 0
  end
  
  -- Helper to get label for level
  local function getVoxelLabel(level)
    local labels = { "OFF", "FULL", "15", "35", "50", "75", "1ST", "3RD" }
    return labels[(level % 8) + 1] or "OFF"
  end
  
  local function getTiltLabel(level)
    local labels = { "OFF", "LIGHT", "MEDIUM", "HEAVY" }
    return labels[(level % 4) + 1] or "OFF"
  end
  
  -- Log throttle counter
  local voxelLogFrame = 0

  -- Insert VOXEL 3D row
  table.insert(out, 15, {
    id = "voxel3d",
    label = "VOXEL 3D",
    value = function()
      local level = getPipelineLevel("stadium2_gold_voxel")
      voxelLogFrame = voxelLogFrame + 1
      if voxelLogFrame % 15 == 0 then
        mod.log:info("VOXEL 3D value: current level=%d, label=%s", level, getVoxelLabel(level))
      end
      return getVoxelLabel(level)
    end,
    activate = function(g)
      local current = getPipelineLevel("stadium2_gold_voxel")
      local nextVal = (current + 1) % 8
      mod.log:info("VOXEL 3D activate: current=%d, next=%d", current, nextVal)
      if Pipelines and type(Pipelines.setLevel) == "function" then
        local ok, err = pcall(Pipelines.setLevel, "stadium2_gold_voxel", nextVal)
        mod.log:info("VOXEL 3D: %d -> %d, setLevel ok=%s, err=%s", current, nextVal, tostring(ok), tostring(err))
        -- Also sync mod option
        if ok then
          pcall(mod.options.set, mod.options, "voxel3d", tostring(nextVal))
        end
      end
    end,
  })
  
  -- Insert TILT-SHIFT row
  table.insert(out, 16, {
    id = "tiltshift",
    label = "TILT-SHIFT",
    value = function()
      local level = getPipelineLevel("tiltshift")
      return getTiltLabel(level)
    end,
    activate = function(g)
      local current = getPipelineLevel("tiltshift")
      local nextVal = (current + 1) % 4
      if Pipelines and type(Pipelines.setLevel) == "function" then
        pcall(Pipelines.setLevel, "tiltshift", nextVal)
        mod.log:info("TILT-SHIFT: %d -> %d", current, nextVal)
      end
    end,
  })
  
  -- Insert mod root row at top
  table.insert(out, 1, {
    id = SettingsMenu.id(SettingsMenu.ROOT),
    label = SettingsMenu.ROOT_LABEL,
    activate = function(g)
      g.stack:push(SettingsMenu.new(g, SettingsMenu.ROOT))
    end,
  })
  
  return out
end)

mod.events:on("mod.options_changed", function(payload)
  if not (payload and payload.mod == mod.id) then return end
  for _, entry in ipairs(SETTINGS) do
    if payload.key == entry[1].key then entry[1]:sync(payload.value) end
  end
  -- Sync pipeline level when voxel3d setting changes
  if payload.key == "voxel3d" then
    local Pipelines = require("src.render.Pipelines")
    if Pipelines and type(Pipelines.setLevel) == "function" then
      local level = tonumber(payload.value) or 0
      pcall(Pipelines.setLevel, "stadium2_gold_voxel", level)
      mod.log:info("voxel3d option changed to %d, pipeline synced", level)
    end
  end
end)

-- ------- time of day
mod.events:on("save.writing", function() DayNight.store() end)
mod.events:on("save.loaded", function() DayNight.restore() end)
mod.events:on("save.created", function() DayNight.restore() end)
mod.hooks:wrap("world.tod", function(next, tod, ctx)
  local out = next(tod, ctx)
  if out ~= tod then return out end
  return DayNight.tod()
end)
DayTint.install()

-- ------- camera and movement
FirstPerson.install()
FreeMove.install()
CamControl.install()

-- ------- quality of life
if QoL then QoL.install() end
Carry.install()
if Water.installWalk then pcall(Water.installWalk) end
Comforts.install(mod)
ExpShare.install(mod)
mod.hooks:wrap("movement.speed", function(next, frames, ctx)
  if not QoL then return next(frames, ctx) end
  return QoL.runSpeed(next(frames, ctx), ctx)
end)
mod.hooks:wrap("evolution.check", function(next, game, mon, evo, trigger)
  if not QoL then return next(game, mon, evo, trigger) end
  return QoL.tradeEvolution(next(game, mon, evo, trigger), game, mon, evo, trigger)
end)

-- ------- auto-farm
if AutoFarm then AutoFarm.install() end
mod.hooks:wrap("input.step", function(next, game, dt)
  local out = next(game, dt)
  if AutoFarm then AutoFarm.update() end
  return out
end)

-- ------- ecology
mod.hooks:wrap("encounter.species", function(next, enc, ctx)
  local out = next(enc, ctx)
  if not Ecology.enabled() then return out end
  local ok, tuned = pcall(Ecology.substitute, out, ctx)
  return (ok and tuned) or out
end)

-- ------- shiny
ShinyBattle.install()
ShinyUI.install()
mod.events:on("save.loaded", function() ShinyBattle.markParty() end)
mod.events:on("save.created", function() ShinyBattle.markParty() end)

-- ------- town features
if CityLife then CityLife.install() end
if Interiors then Interiors.install() end

-- ------- follower system
local followerInstance = Follower.new(mod, {
  logic = V,
  render = V,
})
mod.events:on("content.loaded", function()
  pcall(function() followerInstance:registerContent() end)
end)
mod.events:on("mods.loaded", function()
  local Game = require("src.core.Game")
  pcall(function() followerInstance:reassertAfterModsLoaded(Game) end)
end)
mod.events:on("save.loaded", function()
  pcall(function() followerInstance:onSaveLoaded() end)
end)
mod.events:on("map.entered", function(ev)
  pcall(function() followerInstance:onMapEntered(ev) end)
end)
mod.events:on("mod.options_changed", function(payload)
  if payload and payload.mod == mod.id then
    pcall(function() followerInstance:onOptionsChanged(payload) end)
  end
end)
mod.exports.follower = followerInstance

-- ------- OverworldStadium integration (ported from Gen 1 backend)
--
-- Enables animated 3D Pokemon Stadium models for roamers and the full
-- StadiumBattleFX217 battle presentation layer (attack cameras, announcer,
-- boss arenas, trainer portraits). This is self-contained infrastructure
-- that patches the shared lib/VoxelScene.lua renderer by text anchor
-- (see lib/VoxelScenePatch.lua) rather than assuming a Gen 1-only pipeline,
-- so it is safe to install here exactly as Gen 1's main.lua does -- Gen 1's
-- own comment on this function says it targets "both Gen1 and Gen2".
local function loadLocal(rel, arg)
  local source, readErr = mod:read(rel)
  if not source then return nil, ("missing %s: %s"):format(rel, tostring(readErr)) end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then return nil, ("%s did not compile: %s"):format(rel, tostring(err)) end
  return chunk(arg)
end

local function installOverworldStadium()
  local Config, configErr = loadLocal("lib/OverworldStadiumConfig.lua", V)
  if not Config then
    mod.log:warn("OverworldStadiumConfig not loaded: %s", tostring(configErr))
    return false
  end

  local PokemonHeights, heightsErr = loadLocal("lib/PokemonHeights.lua", V)
  if not PokemonHeights then
    mod.log:warn("PokemonHeights not loaded: %s", tostring(heightsErr))
    return false
  end

  local PokemonLocomotion, locoErr = loadLocal("lib/PokemonLocomotion.lua", V)
  if not PokemonLocomotion then
    mod.log:warn("PokemonLocomotion not loaded: %s", tostring(locoErr))
    return false
  end

  local StadiumRomMenu, menuErr = loadLocal("lib/StadiumRomMenu.lua", V)
  if not StadiumRomMenu then
    mod.log:warn("StadiumRomMenu not loaded: %s", tostring(menuErr))
    return false
  end

  local managerOptionsInstalled = StadiumRomMenu.installModManagerOptions(mod)
  if not managerOptionsInstalled then
    StadiumRomMenu.installOptionsHook(mod)
  end

  local OverworldV = {
    mod = mod,
    path = mod.path,
  }
  setmetatable(OverworldV, { __index = V })
  function OverworldV.require(name)
    if name == "OverworldStadiumConfig" then return Config end
    if name == "PokemonHeights" then return PokemonHeights end
    if name == "PokemonLocomotion" then return PokemonLocomotion end
    return V.require(name)
  end

  local OverworldStadium, stadiumErr = loadLocal("lib/OverworldStadium.lua", OverworldV)
  if not OverworldStadium then
    mod.log:warn("OverworldStadium not loaded: %s", tostring(stadiumErr))
    return false
  end
  V.OverworldStadium = OverworldStadium

  local VoxelScenePatch, patchErr = loadLocal("lib/VoxelScenePatch.lua", OverworldV)
  if VoxelScenePatch then
    local rendererInstalled, rendererErr = VoxelScenePatch.install(mod, V, OverworldV, OverworldStadium)
    if rendererInstalled then
      mod.log:info("Pokemon Stadium overworld renderer installed (Gen 2)")
    else
      mod.log:warn("Stadium overworld renderer not installed: %s", tostring(rendererErr))
    end
  else
    mod.log:warn("VoxelScenePatch not loaded: %s", tostring(patchErr))
  end

  local BattleStadiumAnimations, animErr = loadLocal("lib/BattleStadiumAnimations.lua", OverworldV)
  if BattleStadiumAnimations then
    local battleAnimationsInstalled, battleAnimationsErr = BattleStadiumAnimations.install()
    if battleAnimationsInstalled then
      mod.log:info("Pokemon Stadium Stage 1 battle performances enabled (Gen 2)")
    else
      mod.log:warn("Stadium Stage 1 battle performances not installed: %s", tostring(battleAnimationsErr))
    end
  else
    mod.log:warn("BattleStadiumAnimations not loaded: %s", tostring(animErr))
  end

  local BattleStadiumEffects, effectsErr = loadLocal("lib/BattleStadiumEffects.lua", OverworldV)
  if BattleStadiumEffects then
    local battleEffectsInstalled, battleEffectsErr = BattleStadiumEffects.install()
    if battleEffectsInstalled then
      mod.log:info("Pokemon Stadium Phase 2-4 battle presentation enabled (Gen 2)")
    else
      mod.log:warn("Stadium Phase 2-4 presentation not installed: %s", tostring(battleEffectsErr))
    end
  else
    mod.log:warn("BattleStadiumEffects not loaded: %s", tostring(effectsErr))
  end

  local BattleStadium3DFx, fxErr = loadLocal("lib/BattleStadium3DFx.lua", OverworldV)
  if BattleStadium3DFx then
    local battle3DInstalled, battle3DErr = BattleStadium3DFx.install()
    if battle3DInstalled then
      mod.log:info("Pokemon Stadium Phase 5 world-space battle effects enabled (Gen 2)")
    else
      mod.log:warn("Stadium Phase 5 world-space effects not installed: %s", tostring(battle3DErr))
    end
  else
    mod.log:warn("BattleStadium3DFx not loaded: %s", tostring(fxErr))
  end

  local StadiumBattleFXPort, portErr = loadLocal("lib/StadiumBattleFXPort.lua", OverworldV)
  if StadiumBattleFXPort then
    OverworldV.StadiumBattleFXPort = StadiumBattleFXPort
    local portInstalled, portInstallErr = pcall(StadiumBattleFXPort.install)
    if portInstalled and portInstallErr ~= false then
      mod.log:info("StadiumBattleFX 2.1.7 Gold presentation layer installed (Gen 2)")
    else
      mod.log:warn("StadiumBattleFX port not installed: %s", tostring(portInstallErr))
    end

    V.importStadium1 = function(bytes, source)
      return StadiumBattleFXPort.importStadium1(bytes)
    end
  else
    mod.log:warn("StadiumBattleFXPort not loaded: %s", tostring(portErr))
  end

  mod.exports.overworld = OverworldStadium
  mod.exports.romMenu = StadiumRomMenu
  mod.exports.tag = function(entity, speciesOrDex)
    return OverworldStadium.tag(entity, speciesOrDex)
  end
  mod.exports.untag = function(entity)
    return OverworldStadium.untag(entity)
  end

  return true
end

pcall(installOverworldStadium)

-- ------- exports
mod.exports.version = "1.15.0-mobile.snow.1"
mod.exports.lib = V
mod.exports.pipelines = { voxel = "stadium2_gold_voxel", tiltshift = PIPE_TILT }
mod.exports.keys = V.KEYS