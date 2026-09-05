-- Gen 2 Voxel Bridge for Dramatic Shape
--
-- Adapts the existing Gen 1 voxel renderer to work on Gen 2 (Gold/Silver/Crystal)
-- by bridging Gen 2's map structure and rendering pipeline to the voxel modules.
--
-- Key adaptations:
-- - Normalizes Gen 2 tileset IDs (TILESET_JOHTO -> TilesetJohto)
-- - Handles Gen 2's GBC color atlas
-- - Adapts neighbor maps for connected areas
-- - Hooks into Gen 2's render.compose instead of pipeline system
-- - Merges entities from Gen 2's separate player/npcs/entities lists

-- Accept either mod object (direct load) or V namespace (via V.require)
local arg = ...
local mod = arg.mod or arg
local V = arg.mod and arg or { mod = mod, path = mod.path }

local Bridge = {
  installed = false,
  active = false,
  lastError = nil,
  framesAttempted = 0,
  frames3d = 0,
  framesFailed = 0,
  mapId = nil,
  worldOverrideCanvas = nil,
  worldOverrideFrame = 0,
}
-- IMPORTANT: when this bridge is loaded through the mod's shared V
-- namespace (the normal path -- gen2/main.lua's V.require("Gen2VoxelBridge")),
-- `V` above is literally that same shared table and it already carries a
-- working, cache-backed `require`. Re-defining V.require here with a fresh
-- private `modules` table would silently fork the module system: every
-- sibling this bridge loads (VoxelState, FirstPerson, CamControl, ...)
-- would become a SEPARATE instance from the one gen2/main.lua already
-- called .install() on, so input would land on one copy while rendering
-- reads another. Only build a private loader when there is no shared one
-- to reuse (e.g. this file loaded directly, standalone, for a test).
if type(V.require) ~= "function" then
  local modules = {}

  local function chunkFor(rel)
    local source, readErr = mod:read(rel)
    if type(source) ~= "string" then
      return nil, ("Gen2VoxelBridge: missing %s: %s"):format(rel, tostring(readErr))
    end
    if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
    local loadcode = loadstring or load
    local chunk, err = loadcode(source, "@" .. mod.path .. "/" .. rel)
    if not chunk then
      return nil, ("Gen2VoxelBridge: %s did not compile: %s"):format(rel, tostring(err))
    end
    return chunk
  end

  function V.require(name)
    local hit = modules[name]
    if hit ~= nil then return hit end
    local chunk, err = chunkFor("lib/" .. name .. ".lua")
    if not chunk then return nil, err end
    local value = chunk(V)
    modules[name] = value
    return value
  end
end

Bridge.lib = V

local Voxel, Voxel3D, VoxelScene, ChunkMesher
local GoldMap = nil
local neighborMapCache = {}
local GoldColorAtlas = nil
local loggedOnce = {}

local function logOnce(key, level, fmt, ...)
  if loggedOnce[key] then return end
  loggedOnce[key] = true
  local log = mod and mod.log
  local fn = log and log[level]
  if type(fn) == "function" then pcall(fn, log, fmt, ...) end
end

-- Check if voxel mode is enabled via mod options
local function optionEnabled()
  local ok, value = pcall(mod.options.get, mod.options, "voxel3d")
  if not ok or value == nil then return true end
  -- For 8-level system, OFF (0) is off, everything else is on
  local numValue = tonumber(value)
  if numValue ~= nil then
    return numValue > 0
  end
  return not (value == false or value == 0 or value == "0"
    or value == "false" or value == "off")
end

-- Get the current voxel level (0-7) from pipeline level (Gen 2) or mod options (Gen 1)
local function getVoxelLevel()
  -- Try to read from pipeline level first (Gen 2)
  local Pipelines = src and src.render and src.render.Pipelines
  if Pipelines and type(Pipelines.level) == "function" then
    local ok, level = pcall(Pipelines.level, "stadium2_gold_voxel")
    if ok and level ~= nil then
      local numLevel = tonumber(level)
      if numLevel ~= nil then return numLevel end
    end
  end

  -- Fallback to mod options (Gen 1)
  local ok, value = pcall(mod.options.get, mod.options, "voxel3d")
  if not ok or value == nil then return 0 end
  local numValue = tonumber(value)
  if numValue ~= nil then return numValue end
  if value == false or value == 0 or value == "0" or value == "false" or value == "off" then
    return 0
  end
  return 1 -- Default to FULL (1) if on but not numeric
end

-- Normalize Gen 2 tileset IDs (TILESET_JOHTO -> TilesetJohto)
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

-- Attach renderer to Gen 2 map
local function attachRenderer(world, map)
  if not (world and map and map.def) then
    return false, "Gold map/definition not ready"
  end
  if type(world.atlasFor) ~= "function" then
    return false, "Gold World:atlasFor is unavailable"
  end

  -- Get tileset atlas from Gen 2 world
  local ok, atlas, tileset = pcall(world.atlasFor, world, map.def)
  if not ok then return false, "Gold atlasFor failed: " .. tostring(atlas) end
  if not atlas then return false, "Gold atlasFor returned no tileset atlas" end

  map.tileset = tileset or map.tileset

  -- Normalize tileset ID for voxel modules
  if map.tileset then
    local engineId = map.def.tileset or map.tileset.id
    local profileId = profileTilesetId(engineId)
    if profileId then
      map.tileset._stadiumEngineTilesetId = map.tileset._stadiumEngineTilesetId or map.tileset.id or engineId
      map.tileset.id = profileId
    end
  end

  map.renderer = map.renderer or {}
  map.renderer.data = (world.game and world.game.data) or map.renderer.data

  -- Gold's generated tileset sheet is intentionally four-shade (DMG) source
  -- art -- the native 2D renderer assigns one of eight GBC palettes PER 8x8
  -- tile at draw/bake time, using the map/time-of-day palette set. Voxel
  -- geometry samples the atlas directly and has no per-quad shader once the
  -- map is 3D, so feeding it World:atlasFor's raw sheet produces a correct
  -- but MONOCHROME world -- this was the actual cause of voxel terrain
  -- rendering black-and-white while sprites (still drawn through the
  -- native 2D per-quad path) kept their normal GBC coloring. Bake the same
  -- Gen-2 PalMap into a private colored atlas before the voxel mesh sees
  -- it, exactly as lib/GoldVoxelBridge.lua's own (unused-by-the-active-
  -- render-path) attachRenderer already does.
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

-- Get Gen 2 Map module
local function goldMapModule()
  if GoldMap then return GoldMap end
  local ok, Map = pcall(require, "src.world.gen2.Map")
  if ok and type(Map) == "table" and type(Map.new) == "function" then
    GoldMap = Map
    return GoldMap
  end
  return nil
end

-- Adapt neighbor map for voxel renderer
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

-- Get direct neighbor specs
local function directNeighborSpecs(world)
  local root = world and world.map and world.map.def
  local maps = world and world.maps
  if not (root and maps) then return {} end

  local native = {}
  for _, nb in ipairs(world and world.neighbors or {}) do
    if nb and nb.id then native[nb.id] = nb end
  end

  local out, seen = {}, {}
  local CARDINAL = { "north", "south", "west", "east" }
  for _, dir in ipairs(CARDINAL) do
    local conn = root.connections and root.connections[dir]
    local id = conn and (conn.mapId or conn.map)
    local def = id and maps[id] or nil
    if def and not seen[id] then
      seen[id] = true
      local n = native[id]
      local ox, oy = n and tonumber(n.ox), n and tonumber(n.oy)
      if not (ox and oy) then
        local offset = tonumber(conn and conn.offset) or 0
        if dir == "north" then
          ox, oy = offset * 32, -def.height * 32
        elseif dir == "south" then
          ox, oy = offset * 32, root.height * 32
        elseif dir == "west" then
          ox, oy = -def.width * 32, offset * 32
        else -- east
          ox, oy = root.width * 32, offset * 32
        end
      end
      out[#out + 1] = {
        id = id, map = nil, ox = ox, oy = oy, dir = dir, depth = 1,
      }
    end
  end

  -- Load actual Map objects for neighbors
  for _, spec in ipairs(out) do
    local map, err = adaptedNeighborMap(world, spec.id)
    if map then
      spec.map = map
    else
      mod.log:warn("Gold neighbor adapter skipped %s: %s", spec.id, tostring(err))
    end
  end

  return out
end

-- Merge entities from Gen 2's separate lists
local function mergedEntities(world)
  local out, seen = {}, {}
  local function add(e)
    if type(e) == "table" and not seen[e] then
      seen[e] = true
      out[#out + 1] = e
    end
  end

  add(world.player)
  if type(world.npcs) == "table" then
    for _, e in ipairs(world.npcs) do add(e) end
  end
  if type(world.entities) == "table" then
    for _, e in ipairs(world.entities) do add(e) end
  end

  return out
end

-- Create voxel state from Gen 2 world
local function makeState(world)
  if not (world and world.map and world.camera and world.player) then
    return nil, "Gold world/map/player is not ready"
  end

  local attached, attachErr = attachRenderer(world, world.map)
  if not attached then return nil, attachErr end

  local neighbors = directNeighborSpecs(world)
  V.goldNeighbors = neighbors

  return {
    map = world.map,
    camera = world.camera,
    player = world.player,
    entities = mergedEntities(world),
    neighbors = neighbors,
  }
end

-- Frame timing
local function frameDt()
  local dt = 1 / 60
  local ok, Timer = pcall(require, "src.core.Timer")
  if ok and type(Timer) == "table" and type(Timer.getDelta) == "function" then
    local okDt, delta = pcall(Timer.getDelta)
    if okDt and tonumber(delta) and delta > 0 then dt = delta end
  end
  return dt
end

-- View dimensions
local function viewDimensions(world, ctx)
  local vw, vh = tonumber(ctx and ctx.vw), tonumber(ctx and ctx.vh)
  if vw and vh and vw > 0 and vh > 0 then return vw, vh end

  vw, vh = tonumber(world and world.viewW), tonumber(world and world.viewH)
  if vw and vh and vw > 0 and vh > 0 then return vw, vh end

  local ww, wh = tonumber(ctx and ctx.ww), tonumber(ctx and ctx.wh)
  if not (ww and wh and ww > 0 and wh > 0) then
    ww, wh = love.graphics.getDimensions()
  end
  return ww, wh
end

-- Render a frame of the voxel world
function Bridge.renderFrame(world, ctx)
  Bridge.framesAttempted = Bridge.framesAttempted + 1

  if not Bridge.installed then
    local ok, err = pcall(Bridge.install)
    if not ok then
      Bridge.framesFailed = Bridge.framesFailed + 1
      Bridge.lastError = tostring(err)
      return nil, Bridge.lastError, "failed"
    end
  end

  local okAvailable, available = pcall(Voxel3D.available)
  if not okAvailable or not available then
    local err = okAvailable and "Voxel3D reports graphics/depth support unavailable"
      or ("Voxel3D availability check failed: " .. tostring(available))
    Bridge.framesFailed = Bridge.framesFailed + 1
    Bridge.lastError = err
    return nil, err, "failed"
  end

  local state, stateErr = makeState(world)
  if not state then
    Bridge.framesFailed = Bridge.framesFailed + 1
    Bridge.lastError = tostring(stateErr)
    return nil, Bridge.lastError, "failed"
  end

  Bridge.mapId = state.map and state.map.id or Bridge.mapId

  -- Prime current map synchronously
  if Bridge.syncBuildMapId ~= state.map.id then
    Bridge.syncBuildMapId = state.map.id
    Bridge.syncBuilds = (Bridge.syncBuilds or 0) + 1

    local warm = (type(ChunkMesher.peek) == "function")
      and ChunkMesher.peek(state.map, false)
    local okPrime, primeMeshOrErr = true, warm
    if not warm then
      okPrime, primeMeshOrErr = pcall(ChunkMesher.get, state.map, false, nil)
    end
    if not okPrime then
      Bridge.syncBuildFailures = (Bridge.syncBuildFailures or 0) + 1
      Bridge.framesFailed = Bridge.framesFailed + 1
      Bridge.lastError = "Gen-2 voxel mesh prime crashed: " .. tostring(primeMeshOrErr)
      return nil, Bridge.lastError, "failed"
    end
    if not primeMeshOrErr then
      Bridge.syncBuildFailures = (Bridge.syncBuildFailures or 0) + 1
      Bridge.framesFailed = Bridge.framesFailed + 1
      Bridge.lastError = "Gen-2 voxel mesh build produced no terrain"
      return nil, Bridge.lastError, "failed"
    end
  end

  local ok, canvasOrErr = pcall(function()
    local dt = frameDt()
    local level = getVoxelLevel()
    Voxel.update(dt, level)
    
    -- Port all Gen 1 update calls to Gen 2 for full functionality
    local FirstPerson = V.require("FirstPerson")
    if FirstPerson and type(FirstPerson.update) == "function" then
      pcall(FirstPerson.update, dt)
    end
    
    -- Note: FreeMove is Gen 1 only (calls state:onStepComplete which doesn't exist in Gen 2)
    -- Gen 2 uses GoldCameraControls for free movement instead
    
    -- Atmosphere effects
    local ForestAtmos = V.require("ForestAtmos")
    if ForestAtmos and type(ForestAtmos.update) == "function" then
      pcall(ForestAtmos.update, dt)
    end
    
    -- Day/night cycle
    local DayNight = V.require("DayNight")
    if DayNight and type(DayNight.update) == "function" then
      pcall(DayNight.update, dt)
    end
    
    -- Weather system
    local Weather = V.require("Weather")
    if Weather and type(Weather.update) == "function" then
      pcall(Weather.update, dt)
    end
    
    -- Ground effects (footprints, etc)
    local GroundFX = V.require("GroundFX")
    if GroundFX and type(GroundFX.update) == "function" then
      pcall(GroundFX.update, dt)
    end
    
    -- Wind effects
    local WindFX = V.require("WindFX")
    if WindFX and type(WindFX.update) == "function" then
      pcall(WindFX.update, dt, Voxel.active())
    end
    
    -- Visual effects
    local Vfx = V.require("Vfx")
    if Vfx and type(Vfx.update) == "function" then
      pcall(Vfx.update, dt)
    end

    -- LET'S GO capture session -- poses the Poke Ball here, ahead of the
    -- battle's own update, so the ball drawn each frame is the ball that
    -- frame computed
    local LetsGo = V.require("LetsGo")
    if LetsGo and type(LetsGo.update) == "function" then
      pcall(LetsGo.update, dt)
    end

    -- NOTE: OverworldBattle.update is intentionally NOT ticked here.
    -- Gen 1 can tick it from this same always-running spot because its
    -- render_pipelines:register(PIPE_VOXEL, {update=...}) callback is
    -- called unconditionally by the engine every frame, battle or not,
    -- voxel-on or not. Gen 2 has no such unconditional pipeline update --
    -- this renderFrame function only runs while the 3D world is actually
    -- being composed, which is exactly the time a battle is NOT on top.
    -- OverworldBattle.update ticks from the top-level Bridge.updateBattle
    -- below instead, which GoldComposeBridge already calls every frame
    -- unconditionally (see composeCore in GoldComposeBridge.lua).

    -- Wild Pokemon standing in the grass -- keeps running on the same tick
    -- so a map arriving mid-transition still gets its roamers spawned
    local WildRoamers = V.require("WildRoamers")
    if WildRoamers and type(WildRoamers.update) == "function" then
      pcall(WildRoamers.update)
    end

    -- Ambient sound clocks (crickets, birds, rain, thunder)
    local AmbientSound = V.require("AmbientSound")
    if AmbientSound and type(AmbientSound.update) == "function" then
      pcall(AmbientSound.update, dt)
    end

    -- VR head/stick update, if a headset is active
    local VR = V.require("VR")
    if VR and type(VR.update) == "function" then
      pcall(VR.update, dt)
    end

    ChunkMesher.pump(false, false)
    local vw, vh = viewDimensions(world, ctx)
    local rw, rh = tonumber(ctx and ctx.ww) or 320, tonumber(ctx and ctx.wh) or 288
    rw, rh = math.floor(rw), math.floor(rh)
    return VoxelScene.render(state, rw, rh, vw, vh, nil)
  end)

  if not ok then
    if mod and mod.log and Bridge.framesAttempted % 30 == 0 then
      mod.log:info("Gen2VoxelBridge.renderFrame: pcall failed: %s", tostring(canvasOrErr))
    end
    Bridge.framesFailed = Bridge.framesFailed + 1
    Bridge.lastError = tostring(canvasOrErr)
    return nil, Bridge.lastError, "failed"
  end

  if not canvasOrErr then
    Bridge.framesPending = (Bridge.framesPending or 0) + 1
    return nil, "voxel mesh pending", "pending"
  end

  Bridge.frames3d = Bridge.frames3d + 1
  Bridge.lastError = nil
  return canvasOrErr, nil, "rendered"
end

-- ------- battle-canvas compositing (ported from lib/GoldVoxelBridge.lua)
--
-- Gen 1's engine exposes a separable worldOverride render pass, so a 3D
-- battle can draw straight into it. Gen 2's Game2 composites the overworld
-- and stack UI into ONE scene canvas with no such separable pass -- see
-- the header comment in lib/GoldComposeBridge.lua. GoldComposeBridge's
-- composeCore already calls VoxelBridge.setGame/.updateBattle every frame
-- UNCONDITIONALLY (mirroring the "Pipelines.update always runs" contract
-- Gen 1 gets natively), then, whenever the world itself is not the top
-- state, calls VoxelBridge.battleShot to see if there is a live 3D battle
-- canvas to composite instead of Gold's native battle screen. None of
-- these five were previously defined on this bridge, so
-- GoldComposeBridge's `type(VoxelBridge.X) == "function"` guards were all
-- silently false and the whole 3D-battle-compositing path never engaged
-- on Gen 2 -- Gold's own flat battle screen was drawn every time instead.
function Bridge.setGame(game)
  if type(game) ~= "table" then return false end
  Bridge.game = game
  V.game = game
  return true
end

function Bridge.updateBattle(dt)
  -- GoldComposeBridge calls this once every frame, unconditionally --
  -- the closest Gen 2 equivalent of Gen 1's "Pipelines.update always
  -- runs" contract (see the note above Bridge.setGame). Gen 1 piggybacks
  -- several unrelated one-time/polling jobs onto that same always-on
  -- hook for exactly that reason (its own comment: "restored from
  -- DRAMATIC_SHAPE... rides this hook for the same reason"). The Stadium
  -- ROM importers need the same guarantee: a picked ROM has to be polled
  -- and a pending build screen pushed even while the player is sitting
  -- in the options menu with 3D voxels off, which is exactly when
  -- Gen2VoxelBridge.renderFrame is NOT running.

  -- AGGRESSIVE: Force restore voxel pipeline level every frame during battle
  -- This prevents battle transition from resetting the pipeline
  local okPipelines, Pipelines = pcall(require, "src.render.Pipelines")
  if okPipelines and Pipelines and type(Pipelines.level) == "function" and type(Pipelines.setLevel) == "function" then
    local okRead, current = pcall(Pipelines.level, "stadium2_gold_voxel")
    if okRead and current ~= nil then
      local currentLevel = tonumber(current) or 0
      -- If voxel mode is enabled via mod option but pipeline is 0, restore it
      if currentLevel == 0 and optionEnabled() then
        local opts = mod and mod.options
        if opts and type(opts.get) == "function" then
          local ok, value = pcall(opts.get, opts, "voxel3d")
          if ok and value ~= nil then
            local wantedLevel = tonumber(value) or 1
            if wantedLevel > 0 then
              if mod and mod.log then
                mod.log:warn("Gen2VoxelBridge.updateBattle: DETECTED voxel level 0, restoring to %d", wantedLevel)
              end
              pcall(Pipelines.setLevel, "stadium2_gold_voxel", wantedLevel)
              -- Verify restoration worked
              local okVerify, verifyLevel = pcall(Pipelines.level, "stadium2_gold_voxel")
              if okVerify and mod and mod.log then
                mod.log:info("Gen2VoxelBridge.updateBattle: verification after restore - level is now %d", tonumber(verifyLevel) or 0)
              end
            end
          end
        end
      end
    end
  end

  pcall(function() V.require("StadiumScreen").maybePush() end)
  pcall(function() V.require("Stadium2Screen").maybePush() end)
  pcall(function()
    local PlayerModel = V.require("PlayerModel")
    local PlayerModelInstall = V.require("PlayerModelInstall")
    if PlayerModel and PlayerModelInstall
        and not PlayerModel.loaded() and PlayerModelInstall.installed() then
      PlayerModel.loadInstalled()
    end
  end)
  local liveGame = Bridge.game
  if not liveGame then
    local okGame, Game2 = pcall(require, "src.core.Game2")
    liveGame = (okGame and Game2) or nil
  end
  pcall(function() V.require("StadiumRomPick").poll(liveGame) end)
  pcall(function() V.require("Stadium2RomPick").poll(liveGame) end)

  -- LET'S GO capture session -- poses the Poke Ball here, ahead of the
  -- battle's own update, so the ball drawn each frame is the ball that
  -- frame computed
  pcall(function()
    local LetsGo = V.require("LetsGo")
    if LetsGo and type(LetsGo.update) == "function" then LetsGo.update(dt) end
  end)

  -- Wild Pokemon standing in the grass. WildRoamers.lua's own comment
  -- above its tick() says it wants exactly this hook ("the one tick the
  -- engine runs whatever is on top"); it was previously ticked from
  -- renderFrame instead, which only runs while the 3D world itself is
  -- drawing -- so roamers never spawned at all while voxels were off, and
  -- were one step removed from the "runs no matter what" guarantee
  -- WildRoamers' own internal gating (battle/menu/transition checks)
  -- expects to be driven from.
  pcall(function()
    local WildRoamers = V.require("WildRoamers")
    if WildRoamers and type(WildRoamers.update) == "function" then WildRoamers.update() end
  end)

  -- Ambient sound clocks (crickets, birds, rain, thunder)
  pcall(function()
    local AmbientSound = V.require("AmbientSound")
    if AmbientSound and type(AmbientSound.update) == "function" then AmbientSound.update(dt) end
  end)

  -- VR head/stick update, if a headset is active
  pcall(function()
    local VR = V.require("VR")
    if VR and type(VR.update) == "function" then VR.update(dt) end
  end)

  local OverworldBattle = V.require("OverworldBattle")
  if not (OverworldBattle and type(OverworldBattle.update) == "function") then
    return false
  end
  local ok, err = pcall(OverworldBattle.update, tonumber(dt) or (1 / 60))
  if not ok then
    Bridge.battleError = tostring(err)
    return false
  end
  Bridge.battleError = nil
  return true
end

function Bridge.battleShot()
  local OverworldBattle = V.require("OverworldBattle")
  if not (OverworldBattle and type(OverworldBattle.shot) == "function") then
    return nil
  end
  local ok, shot = pcall(OverworldBattle.shot)
  return ok and shot or nil
end

function Bridge.battleScreen()
  local OverworldBattle = V.require("OverworldBattle")
  if not (OverworldBattle and type(OverworldBattle.battle) == "function") then
    return nil
  end
  local ok, battle = pcall(OverworldBattle.battle)
  return ok and battle or nil
end

function Bridge.battleStage()
  local OverworldBattle = V.require("OverworldBattle")
  if not (OverworldBattle and type(OverworldBattle.stage) == "function") then
    return nil
  end
  local ok, stage = pcall(OverworldBattle.stage)
  return ok and stage or nil
end

-- Set world override canvas for battle compositing
-- This is called by OverworldBattle to provide the 3D battle canvas
function Bridge.setWorldOverride(canvas)
  local mod = V and V.mod
  if mod and mod.log then
    mod.log:info("Gen2VoxelBridge.setWorldOverride: called with canvas=%s", tostring(canvas ~= nil))
  end
  Bridge.worldOverrideCanvas = canvas
  Bridge.worldOverrideFrame = Bridge.framesRendered
end

-- ------- enable checks (ported from lib/GoldVoxelBridge.lua)
-- GoldComposeBridge already falls back to reading the pipeline level /
-- mod option directly when these are missing, so their absence was not
-- itself a hard failure -- but a direct answer is cheaper and matches
-- Bridge.active exactly, so composeCore's own cache and this bridge's
-- cache can never briefly disagree.
function Bridge.voxelModeEnabled()
  return optionEnabled()
end
Bridge.world3DEnabled = Bridge.voxelModeEnabled

-- Install the bridge
function Bridge.install()
  if Bridge.installed then return true, V end

  local ok, a, b, c, d = pcall(function()
    return V.require("VoxelState"), V.require("Voxel3D"),
      V.require("VoxelScene"), V.require("ChunkMesher")
  end)
  if not ok then return false, tostring(a) end
  Voxel, Voxel3D, VoxelScene, ChunkMesher = a, b, c, d

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

  Bridge.installed = true
  Bridge.active = optionEnabled()
  mod.log:info("Gen 2 voxel bridge installed")
  return true, V
end

function Bridge.ensure()
  if not Bridge.installed then return Bridge.install() end
  return true, V
end

function Bridge.status()
  return {
    installed = Bridge.installed,
    active = Bridge.active,
    mapId = Bridge.mapId,
    framesAttempted = Bridge.framesAttempted,
    frames3d = Bridge.frames3d,
    framesFailed = Bridge.framesFailed,
    lastError = Bridge.lastError,
  }
end

return Bridge