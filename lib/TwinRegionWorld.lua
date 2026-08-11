-- Stadium twin-region world extension (v0.3.68 Kanto Saffron/Museum physical parity).
--
-- Two deliberately independent visual layers for the Gold voxel renderer:
--   * WORLD OCEAN: a low reflective water plane beneath/around the stitched
--     world, so survey zoom sees ocean rather than an empty void.
--   * GEN-1 KANTO REGION: reads the player's already-imported Pokemon Yellow
--     cache, reconstructs Yellow's connected Kanto graph, applies the active
--     Johto/Gold palette-material profile, namespaces runtime
--     ids, and places Kanto east of Gold across a short ocean gap.
--
-- Gold remains the SAVE authority, while the Kanto excursion is a story-free
-- Yellow world runtime of its own: current-map + two-hop sector streaming, true directional 360-degree
-- first/third-person movement, Johto-matched terrain/material colors, NPC/sign
-- dialogue, shops/centers/PCs, persistent
-- item pickups, Yellow trainer/Gym battles, Yellow encounter roaming Pokemon +
-- real Gold-runtime wild battles/captures, outdoor connections and interior
-- warps. Gold's actual world remains untouched underneath, so RETURN TO JOHTO
-- stays lossless and Kanto resumes where the player left it.

local V = ...
local mod = V.mod
local Quality = V.require("Quality")
local FirstPerson = V.require("FirstPerson")
local ChunkMesher = V.require("ChunkMesher")
local KantoGen2Style = V.require("KantoGen2Style")

local Twin = {
  PREFIX = "__GEN1__",
  REGION_GAP = 384,       -- 12 Gen-1 blocks of visible sea between regions.
  OCEAN_MARGIN = 768,     -- 24 blocks beyond the outermost rendered land.
  OCEAN_Y = -5.0,         -- below native map water (-2), so lakes win depth.
  cacheVersion = nil,
  regionMaps = 0,
  regionVisible = false,
  oceanVisible = false,
  lastError = nil,
  regionBuilds = 0,
  atlasLoads = 0,
  atlasFallbacks = 0,
  cacheReads = 0,
  cachePrefixRestores = 0,
  mapAdapter = "private-gen1",
  excursionActive = false,
  excursionMap = nil,
  excursionSourceMap = nil,
  excursionCellX = nil,
  excursionCellY = nil,
  excursionTeleports = 0,
  excursionReturns = 0,
  excursionSteps = 0,
  kantoNpcs = 0,
  kantoPokemon = 0,
  kantoWarps = 0,
  kantoConnections = 0,
  kantoConnectionRepairs = 0,
  kantoConnectionWarnings = 0,
  kantoConnectionEdgeRejects = 0,
  kantoWarpRecoveries = 0,
  kantoWarpFailures = 0,
  yellowExtraWarpArrivals = 0,
  yellowWarpPadTransitions = 0,
  yellowWarpHoleTransitions = 0,
  yellowDungeonFalls = 0,
  yellowLedgeHops = 0,
  yellowLedgeSeamHops = 0,
  yellowPhysicalEvents = 0,
  yellowClosedDoorRestamps = 0,
  yellowCardKeyDoors = 0,
  yellowTrashSwitches = 0,
  yellowTrashResets = 0,
  yellowTrashDoorOpens = 0,
  yellowForcedBikeMounts = 0,
  yellowCyclingRoadRolls = 0,
  yellowCyclingRoadBrakes = 0,
  yellowCyclingRoadBounces = 0,
  yellowPairCollisionBlocks = 0,
  yellowFreePairCollisionBlocks = 0,
  yellowBikeMounts = 0,
  yellowBikeDismounts = 0,
  kantoFieldIndexBuilds = 0,
  kantoStateCacheHits = 0,
  kantoStateCacheLoads = 0,
  kantoBlockBatchRefreshes = 0,
  kantoSectorMaps = 0,
  kantoPalette = "gen2-native-per-map",
  kantoPaletteSyncs = 0,
  kantoRegionUnloads = 0,
  kantoPrefetchMaps = 0,
  kantoActorMapSkips = 0,
  kantoPaletteExactTiles = 0,
  kantoCacheWarmQueued = 0,
  kantoCacheWarmHits = 0,
  kantoCacheWarmLive = 0,
  kantoCacheWarmCursor = 0,
  yellowWildBattles = 0,
  yellowWildWins = 0,
  yellowWildCatches = 0,
  yellowSignsRead = 0,
  yellowItemsPicked = 0,
  yellowMartVisits = 0,
  yellowCenterHeals = 0,
  yellowTowerPurifiedHeals = 0,
  yellowTowerPurifiedSteps = 0,
  yellowSaffronDrinks = 0,
  yellowSaffronGateBlocks = 0,
  yellowMuseumTickets = 0,
  yellowMuseumGateBlocks = 0,
  yellowOldAmberGifts = 0,
  yellowMuseumObjectMigrations = 0,
  yellowBikeVouchers = 0,
  yellowLocalBikeVouchers = 0,
  yellowBicycleExchanges = 0,
  yellowBikeShopBrowses = 0,
  yellowPcOpens = 0,
  yellowSurfStarts = 0,
  yellowSurfingPikachuRuns = 0,
  yellowSurfingPikachuFinishes = 0,
  yellowSurfingPikachuPrints = 0,
  yellowResumeLoads = 0,
  yellowKantoEntryRepairs = 0,
  yellowCuts = 0,
  yellowStrengthUses = 0,
  yellowBoulderPushes = 0,
  yellowTrainerSightEngages = 0,
  yellowNpcSteps = 0,
  yellowSeafoamDrops = 0,
  yellowSeafoamCurrents = 0,
  yellowFlyUses = 0,
  yellowFlyPoints = 0,
  yellowHiddenItems = 0,
  yellowHiddenPcUses = 0,
  yellowGymStatues = 0,
  yellowHiddenCoins = 0,
  yellowSpinnerRuns = 0,
  yellowSpinnerIndexHits = 0,
  yellowBadgeGateBlocks = 0,
  yellowBadgeGateIndexHits = 0,
  yellowGameCornerPosterOpens = 0,
  yellowGameCornerPosterRestamps = 0,
  yellowGameCornerRocketExits = 0,
  yellowGameCornerRocketMigrations = 0,
  yellowFlashUses = 0,
  yellowDigUses = 0,
  yellowTeleportUses = 0,
  yellowWhiteouts = 0,
  yellowCenterSpawns = 0,
  yellowLocalItemPickups = 0,
  yellowSemanticItemConversions = 0,
  yellowFossilsTaken = 0,
  yellowFossilsSubmitted = 0,
  yellowFossilsRevived = 0,
  yellowCinnabarGymKeyBlocks = 0,
  yellowRocketLiftKeyDrops = 0,
  yellowSilphScopeDrops = 0,
  yellowRocketElevatorUses = 0,
  yellowRocketDuoBattles = 0,
  yellowRocketDuoWins = 0,
  yellowTowerGhostBlocks = 0,
  yellowMarowakBattles = 0,
  yellowMarowakWins = 0,
  yellowTowerRocketBattles = 0,
  yellowTowerRocketWins = 0,
  yellowFujiRescues = 0,
  yellowPokeFlutes = 0,
  yellowSnorlaxBattles = 0,
  yellowSnorlaxClears = 0,
  yellowBillHelps = 0,
  yellowSSTickets = 0,
  yellowSSAnneGateBlocks = 0,
  yellowSSAnneRivalBattles = 0,
  yellowSSAnneRivalWins = 0,
  yellowCaptainCutGifts = 0,
  yellowSSAnneDepartures = 0,
  yellowSilphDuoBattles = 0,
  yellowSilphDuoWins = 0,
  yellowSilphGiovanniBattles = 0,
  yellowSilphGiovanniWins = 0,
  yellowSilphLiberations = 0,
  yellowSaffronStateMigrations = 0,
  yellowMasterBallGifts = 0,
  yellowNonGymGiovanniBattles = 0,
  johtoAnchorRestores = 0,
  lastWildSpecies = nil,
  lastWildLevel = nil,
}

local CACHE_VERSIONS = { "yellow" }
local regionCache = nil
local regionAttemptAt = -math.huge
local RETRY_SECONDS = 5
local oceanMesh, oceanMeshKey, oceanTexture = nil, nil, nil
local RuntimeSheets = V.require("runtime_sheets")
local runtimeSheets = RuntimeSheets.new(mod)
pcall(runtimeSheets.load, runtimeSheets)
local Assets = require("src.render.Assets")

-- Pallet excursion state is deliberately presentation-local. Gold's real map,
-- save position, scripts and NPC state remain untouched underneath, so RETURN
-- TO JOHTO is lossless and saving can never write a foreign Gen-1 coordinate.
local excursion = {
  active = false,
  world = nil,
  region = nil,
  sourceMapId = nil,
  cellX = 0, cellY = 0,
  drawPx = 0, drawPy = 0,
  facing = "down", stepFlip = false,
  moving = false, fromPx = 0, fromPy = 0, toPx = 0, toPy = 0, moveT = 0,
  moveDurationCurrent = nil,
  hopActive = false, hopProgress = 0, hopLift = 0, hopSeam = false,
  animClock = 0, animDistance = 0, lastWorldX = 0, lastWorldZ = 0,
  -- Johto-style true-directional body. Coordinates are the centre of the
  -- visible Kanto player in the current foreign map's 16px cell space.
  freeActive = false, freeX = nil, freeZ = nil, freeMapId = nil,
  freeVisualMoving = false, freeCellCrossings = 0, freeWallSlides = 0,
  toMapId = nil, toCellX = nil, toCellY = nil,
  moveDuration = 0.115,
  lastTick = nil,
  currentRecord = nil,
  playerProxy = nil,
  cameraProxy = { x = 0, y = 0 },
  ignoreWarpKey = nil, -- legacy compatibility field; normal runtime uses scalar fields below
  ignoreWarpMap = nil, ignoreWarpX = nil, ignoreWarpY = nil,
  -- Gen1Recomp remembers the last outside map for LAST_MAP warps. Kanto is
  -- presentation-local, so keep the same state here without touching Gold.
  lastOutside = nil,
  standingOnWarp = false,
  prevA = false,
  battleBusy = false,
  trainerEngaging = false,
  strengthActive = false,
  npcAiClock = 0, npcAiCursor = 0,
  forcedMoves = nil, forcedMoveIndex = 0, seafoamCurrentLock = false,
  biking = false, forcedBike = false,
  flashActive = false,
  towerPurifiedZone = false,
  safari = nil, safariEncounter = nil,
  johtoAnchor = nil,
  lastInteraction = nil,
}

-- The Kanto excursion uses the same physical scale as GoldCameraControls:
-- 16px cells, a 5.5px circular body and 1px per 60Hz logic frame.  Keeping the
-- constants identical is what makes a corridor/wall feel the same on either
-- side of the region seam.
local KANTO_FREE_RADIUS = 5.5
local KANTO_FREE_SPEED = 60.0 -- world pixels per second
local KANTO_FREE_EPS = 0.01

local function clearDirectionalBody(snap)
  if snap and excursion.freeActive then
    excursion.drawPx = excursion.cellX * 16
    excursion.drawPy = excursion.cellY * 16
  end
  excursion.freeActive = false
  excursion.freeX, excursion.freeZ, excursion.freeMapId = nil, nil, nil
  excursion.freeVisualMoving = false
  if FirstPerson and type(FirstPerson.releaseBody) == "function" then
    pcall(FirstPerson.releaseBody)
  end
end

local function adoptDirectionalBody()
  excursion.freeX = (tonumber(excursion.drawPx) or excursion.cellX * 16) + 8
  excursion.freeZ = (tonumber(excursion.drawPy) or excursion.cellY * 16) + 8
  excursion.freeMapId = excursion.sourceMapId
  excursion.freeActive = true
  excursion.freeVisualMoving = false
end


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

local function customPlayerSpriteActive()
  local picker = mod and mod.exports and mod.exports.customPlayerSprite
  local fn = picker and picker.active
  if type(fn) ~= "function" then
    Twin._customPlayerActiveRef, Twin._customPlayerActiveFn = nil, nil
    Twin._customPlayerActiveTrusted = false
    return false
  end
  if Twin._customPlayerActiveRef ~= picker or Twin._customPlayerActiveFn ~= fn then
    Twin._customPlayerActiveRef, Twin._customPlayerActiveFn = picker, fn
    Twin._customPlayerActiveTrusted = false
    local ok, active = pcall(fn)
    Twin.kantoCustomPlayerActiveProtectedCalls =
      (Twin.kantoCustomPlayerActiveProtectedCalls or 0) + 1
    if not ok then return false end
    Twin._customPlayerActiveTrusted = true
    return active == true
  end
  if Twin._customPlayerActiveTrusted then
    Twin.kantoCustomPlayerActiveDirectCalls =
      (Twin.kantoCustomPlayerActiveDirectCalls or 0) + 1
    return fn() == true
  end
  return false
end
Twin._customPlayerSpriteActive = customPlayerSpriteActive

local function option(key, default)
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return default end
  local ok, value = pcall(options.get, options, key)
  if not ok then return default end
  return toggleValue(value, default)
end

-- Small persistent namespace for the story-free Yellow region. Gold/Silver's
-- save remains authoritative for party, bag, Pokédex and badges; these keys
-- only remember foreign-region placement/progress that the native Gold save
-- has no map slots for.
-- Persistent Kanto state is read far more often than it is written (door
-- events, trainer wins, boulder positions, hidden-item flags). Crossing the
-- mod.save bridge for the same immutable-for-this-frame table on every query
-- was measurable on Android. Keep a visit-local read-through cache; it is
-- explicitly cleared when entering/leaving Kanto, so a replaced save/new game
-- is always re-read on the next excursion. Writes update the cache immediately.
Twin._persistenceTableCache = Twin._persistenceTableCache or {}

local function persistenceGet(key, fallback)
  local cached = Twin._persistenceTableCache[key]
  if cached ~= nil then
    Twin.kantoStateCacheHits = (Twin.kantoStateCacheHits or 0) + 1
    return cached
  end
  local api = mod and mod.save
  if not (api and type(api.get) == "function") then return fallback end
  local ok, value = pcall(api.get, api, key)
  if not ok or value == nil then value = fallback end
  if type(value) == "table" then
    Twin._persistenceTableCache[key] = value
    Twin.kantoStateCacheLoads = (Twin.kantoStateCacheLoads or 0) + 1
  end
  return value
end

local function persistenceSet(key, value)
  local api = mod and mod.save
  if not (api and type(api.set) == "function") then return false end
  local ok = pcall(api.set, api, key, value) == true
  if ok then
    if type(value) == "table" then Twin._persistenceTableCache[key] = value
    else Twin._persistenceTableCache[key] = nil end
  end
  return ok
end

-- Kanto-only world mutation state. These never write foreign coordinates or
-- Yellow story flags into Gold's native save; they only remember the physical
-- state of the story-free companion region between visits. One namespace also
-- keeps this already-large module below Lua's 200-local main-chunk limit.
local KantoState = {
  CUT_BLOCKS_KEY = "yellowCutBlocksV1",
  BOULDER_POS_KEY = "yellowBoulderPositionsV1",
  BOULDER_VIS_KEY = "yellowBoulderVisibilityV1",
  SEAFOAM_KEY = "yellowSeafoamStateV1",
  FLY_VISITED_KEY = "yellowFlyVisitedV1",
  HIDDEN_TAKEN_KEY = "yellowHiddenTakenV1",
  HEAL_POINT_KEY = "yellowHealPointV1",
  TRADE_DONE_KEY = "yellowTradeDoneV1",
  EVENTS_KEY = "yellowPhysicalEventsV1",
  TRASH_KEY = "yellowTrashPuzzleV1",
  HIDDEN_OBJECTS_KEY = "yellowHiddenObjectsV1",
  SHOWN_OBJECTS_KEY = "yellowShownObjectsV1",
  FOSSIL_LAB_KEY = "yellowFossilLabV1",
}

KantoState.Spatial = V.require("KantoSpatial")
-- Self-contained regression harnesses from older releases stub V.require with
-- an empty table. Fall back to the local module only in that harness shape;
-- production always resolves through the mod loader above.
if type(KantoState.Spatial.ensure) ~= "function" then
  KantoState.Spatial = assert(loadfile("lib/KantoSpatial.lua"))()
end

KantoState.FrameCache = V.require("KantoFrameCache")
if type(KantoState.FrameCache.ensure) ~= "function" then
  KantoState.FrameCache = assert(loadfile("lib/KantoFrameCache.lua"))()
end

KantoState.Tower = V.require("KantoTower")
if type(KantoState.Tower.step) ~= "function" then
  KantoState.Tower = assert(loadfile("lib/KantoTower.lua"))()
end

KantoState.Civic = V.require("KantoCivic")
if type(KantoState.Civic.gateTrigger) ~= "function" then
  KantoState.Civic = assert(loadfile("lib/KantoCivic.lua"))()
end

KantoState.StarterGifts = V.require("KantoStarterGifts")
if type(KantoState.StarterGifts.match) ~= "function" then
  KantoState.StarterGifts = assert(loadfile("lib/KantoStarterGifts.lua"))()
end
Twin._starterGiftsForTest = KantoState.StarterGifts

KantoState.Rewards = V.require("KantoRewards")
if type(KantoState.Rewards.match) ~= "function" then
  KantoState.Rewards = assert(loadfile("lib/KantoRewards.lua"))()
end
Twin._rewardsForTest = KantoState.Rewards

KantoState.Items = V.require("KantoItems")
if type(KantoState.Items.resolveGoldItem) ~= "function" then
  KantoState.Items = assert(loadfile("lib/KantoItems.lua"))()
end
Twin._kantoItemsForTest = KantoState.Items

KantoState.DungeonPuzzles = V.require("KantoDungeonPuzzles")
if type(KantoState.DungeonPuzzles.mansionSwitchAt) ~= "function" then
  KantoState.DungeonPuzzles = assert(loadfile("lib/KantoDungeonPuzzles.lua"))()
end
Twin._kantoDungeonPuzzlesForTest = KantoState.DungeonPuzzles

KantoState.SSAnne = V.require("KantoSSAnne")
if type(KantoState.SSAnne.billPc) ~= "function" then
  KantoState.SSAnne = assert(loadfile("lib/KantoSSAnne.lua"))()
end
Twin._kantoSSAnneForTest = KantoState.SSAnne

KantoState.Silph = V.require("KantoSilph")
if type(KantoState.Silph.duoStep) ~= "function" then
  KantoState.Silph = assert(loadfile("lib/KantoSilph.lua"))()
end
Twin._kantoSilphForTest = KantoState.Silph

KantoState.League = V.require("KantoLeague")
if type(KantoState.League.room) ~= "function" then
  KantoState.League = assert(loadfile("lib/KantoLeague.lua"))()
end
Twin._kantoLeagueForTest = KantoState.League

KantoState.Rival = V.require("KantoRival")
if type(KantoState.Rival.step) ~= "function" then
  KantoState.Rival = assert(loadfile("lib/KantoRival.lua"))()
end
Twin._kantoRivalForTest = KantoState.Rival

KantoState.Postgame = V.require("KantoPostgame")
if type(KantoState.Postgame.blocksWarp) ~= "function" then
  KantoState.Postgame = assert(loadfile("lib/KantoPostgame.lua"))()
end
Twin._kantoPostgameForTest = KantoState.Postgame

KantoState.SafariProgress = V.require("KantoSafariProgress")
if type(KantoState.SafariProgress.requiredBadge) ~= "function" then
  KantoState.SafariProgress = assert(loadfile("lib/KantoSafariProgress.lua"))()
end
Twin._kantoSafariProgressForTest = KantoState.SafariProgress

function KantoState.table(key)
  local value = persistenceGet(key, {})
  return type(value) == "table" and value or {}
end

function KantoState.clearPersistenceCache()
  Twin._persistenceTableCache = {}
  return true
end

function KantoState.objectId(obj)
  return tostring(obj and (obj.index or obj.name) or "?")
end

function KantoState.objectHidden(mapId, obj)
  local state = KantoState.table(KantoState.HIDDEN_OBJECTS_KEY)
  local perMap = state[tostring(mapId or "")]
  return type(perMap) == "table" and perMap[KantoState.objectId(obj)] == true or false
end

function KantoState.setObjectHidden(mapId, obj, hidden)
  mapId = tostring(mapId or "")
  if mapId == "" or not obj then return false end
  local state = KantoState.table(KantoState.HIDDEN_OBJECTS_KEY)
  state[mapId] = type(state[mapId]) == "table" and state[mapId] or {}
  local key = KantoState.objectId(obj)
  local before = state[mapId][key] == true
  if hidden == false then state[mapId][key] = nil else state[mapId][key] = true end
  local after = state[mapId][key] == true
  if before == after then return false end
  persistenceSet(KantoState.HIDDEN_OBJECTS_KEY, state)
  return true
end

-- Yellow hides several item/NPC objects in map data and reveals them later from
-- script (Lift Key, Silph Scope, Mr. Fuji state, etc.). A persisted "not hidden"
-- bit cannot override obj.hidden=true, so keep a separate force-visible layer.
-- Explicit hide still wins, which lets one-time pickups/rescues remove a shown
-- object again without mutating the imported cache.
function KantoState.objectShown(mapId, obj)
  local state = KantoState.table(KantoState.SHOWN_OBJECTS_KEY)
  local perMap = state[tostring(mapId or "")]
  return type(perMap) == "table" and perMap[KantoState.objectId(obj)] == true or false
end

function KantoState.setObjectShown(mapId, obj, shown)
  mapId = tostring(mapId or "")
  if mapId == "" or not obj then return false end
  local state = KantoState.table(KantoState.SHOWN_OBJECTS_KEY)
  state[mapId] = type(state[mapId]) == "table" and state[mapId] or {}
  local key = KantoState.objectId(obj)
  local before = state[mapId][key] == true
  if shown == false then state[mapId][key] = nil else state[mapId][key] = true end
  local after = state[mapId][key] == true
  if before == after then return false end
  persistenceSet(KantoState.SHOWN_OBJECTS_KEY, state)
  return true
end
Twin._kantoObjectHidden = KantoState.objectHidden
Twin._setKantoObjectHidden = KantoState.setObjectHidden
Twin._kantoObjectShown = KantoState.objectShown
Twin._setKantoObjectShown = KantoState.setObjectShown

function KantoState.objectRange(value)
  if type(value) == "number" then return math.max(0, math.floor(value)) end
  local str = tostring(value or "")
  local hex = str:match("^%$([0-9a-fA-F]+)$")
  local n = hex and tonumber(hex, 16) or tonumber(str)
  return n and math.max(0, math.floor(n)) or 0
end

-- Current Gen1Recomp applies pair-collision rows AFTER ordinary destination
-- passability: some otherwise-walkable tile pairs are uncrossable elevation
-- edges in caves/forest, with a separate table while surfing. Regions built
-- by v0.3.51+ pre-index these pairs by tileset; the list scan is retained as a
-- compatibility fallback for injected tests/older cache shapes.
function KantoState.pairBlocked(region, map, sx, sy, tx, ty, surfing)
  if not (map and type(map.cellTile) == "function") then return false end
  if type(map.inBounds) == "function" then
    if not map:inBounds(sx, sy) or not map:inBounds(tx, ty) then return false end
  end
  local a, b
  if map._stadiumForeignGen1Map == true then
    a, b = tonumber(map:cellTile(sx, sy)), tonumber(map:cellTile(tx, ty))
  else
    local okA, gotA = pcall(map.cellTile, map, sx, sy)
    local okB, gotB = pcall(map.cellTile, map, tx, ty)
    a, b = okA and tonumber(gotA) or nil, okB and tonumber(gotB) or nil
  end
  if not (a and b) then return false end
  local tileset = tostring(map.def and map.def.tileset or "")
  if tileset == "" then return false end
  local lo, hi = math.min(a, b), math.max(a, b)
  local mode = surfing == true and "water" or "land"
  local indexed = region and region.fieldIndex and region.fieldIndex.tilePairs
  local set = indexed and indexed[mode] and indexed[mode][tileset]
  if type(set) == "table" then return set[lo * 256 + hi] == true end

  local field = region and region.loaded and region.loaded.field
  local rows = field and field.tilePairs and field.tilePairs[mode]
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    if tostring(row.tileset or "") == tileset then
      local ra, rb = tonumber(row.a), tonumber(row.b)
      if ra and rb and ((ra == a and rb == b) or (ra == b and rb == a)) then
        return true
      end
    end
  end
  return false
end

function KantoState.bikeAllowed(region, mapId)
  mapId = tostring(mapId or "")
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if not def then return false end
  local index = region.fieldIndex
  if index then
    if index.bikeMaps and index.bikeMaps[mapId] then return true end
    if index.bikeTilesets and index.bikeTilesets[tostring(def.tileset or "")] then return true end
    return false
  end
  local field = region.loaded and region.loaded.field
  local br = field and field.bikeRiding or {
    tilesets = { "OVERWORLD", "FOREST", "UNDERGROUND", "SHIP_PORT", "CAVERN" },
    maps = { "ROUTE_23", "INDIGO_PLATEAU" },
  }
  for _, id in ipairs(br.maps or {}) do if tostring(id) == mapId then return true end end
  local tileset = tostring(def.tileset or "")
  for _, id in ipairs(br.tilesets or {}) do if tostring(id) == tileset then return true end end
  return false
end


-- Story-free Yellow still needs a small persistent event surface for physical
-- world state.  These are NOT copied into Gold's native save and they never
-- dispatch Yellow map ASM; they only drive geometry that the retail maps
-- derive from event flags (Silph doors, Rocket lift gates, Vermilion locks).
function KantoState.event(name)
  if not name then return false end
  return KantoState.table(KantoState.EVENTS_KEY)[tostring(name)] == true
end

function KantoState.setEvent(name, on)
  if not name then return false end
  name = tostring(name)
  local state = KantoState.table(KantoState.EVENTS_KEY)
  local before = state[name] == true
  if on == false then state[name] = nil else state[name] = true end
  local after = state[name] == true
  if before == after then return false end
  persistenceSet(KantoState.EVENTS_KEY, state)
  Twin.yellowPhysicalEvents = (Twin.yellowPhysicalEvents or 0) + 1
  return true
end

function KantoState.itemHeld(world, itemId)
  itemId = tostring(itemId or "")
  if itemId == "" then return false end
  if KantoState.Items.isLocalOnly(itemId) then
    return KantoState.event(KantoState.Items.localEvent(itemId))
  end
  local inv = world and world.game and world.game.save and world.game.save.inventory
  return type(inv) == "table" and (tonumber(inv[itemId]) or 0) > 0 or false
end

function KantoState.giveLocalItem(itemId)
  itemId = tostring(itemId or "")
  if not KantoState.Items.isLocalOnly(itemId) then return false end
  local changed = KantoState.setEvent(KantoState.Items.localEvent(itemId), true)
  if changed then Twin.yellowLocalItemPickups = (Twin.yellowLocalItemPickups or 0) + 1 end
  return changed or KantoState.event(KantoState.Items.localEvent(itemId))
end

function KantoState.takeLocalItem(itemId)
  itemId = tostring(itemId or "")
  if not KantoState.Items.isLocalOnly(itemId) then return false end
  if not KantoState.event(KantoState.Items.localEvent(itemId)) then return false end
  KantoState.setEvent(KantoState.Items.localEvent(itemId), false)
  return true
end

-- Current Gen1Recomp's hand-ported closed-door fallback.  Keep the facts in
-- the mod too because the inactive Yellow cache is loaded outside Data:seedDefaults
-- and older hosts/caches may therefore miss one or more of these rows.
KantoState.CLOSED_DOOR_FALLBACK = {
  ROCKET_HIDEOUT_B1F = {
    { block=0x54, bx=12, by=8, open=0x0e,
      event="EVENT_BEAT_ROCKET_HIDEOUT_1_TRAINER_4" },
  },
  ROCKET_HIDEOUT_B4F = {
    { block=0x2d, bx=12, by=5, open=0x0e, events={
      "EVENT_BEAT_ROCKET_HIDEOUT_4_TRAINER_0",
      "EVENT_BEAT_ROCKET_HIDEOUT_4_TRAINER_1" } },
  },
  SILPH_CO_2F = {
    { block=0x54, bx=2, by=2, open=0x0e, event="EVENT_SILPH_CO_2_UNLOCKED_DOOR1" },
    { block=0x54, bx=2, by=5, open=0x0e, event="EVENT_SILPH_CO_2_UNLOCKED_DOOR2" },
  },
  SILPH_CO_3F = {
    { block=0x5f, bx=4, by=4, open=0x0e, event="EVENT_SILPH_CO_3_UNLOCKED_DOOR1" },
    { block=0x5f, bx=8, by=4, open=0x0e, event="EVENT_SILPH_CO_3_UNLOCKED_DOOR2" },
  },
  SILPH_CO_4F = {
    { block=0x54, bx=2, by=6, open=0x0e, event="EVENT_SILPH_CO_4_UNLOCKED_DOOR1" },
    { block=0x54, bx=6, by=4, open=0x0e, event="EVENT_SILPH_CO_4_UNLOCKED_DOOR2" },
  },
  SILPH_CO_5F = {
    { block=0x5f, bx=3, by=2, open=0x0e, event="EVENT_SILPH_CO_5_UNLOCKED_DOOR1" },
    { block=0x5f, bx=3, by=6, open=0x0e, event="EVENT_SILPH_CO_5_UNLOCKED_DOOR2" },
    { block=0x5f, bx=7, by=5, open=0x0e, event="EVENT_SILPH_CO_5_UNLOCKED_DOOR3" },
  },
  SILPH_CO_6F = {
    { block=0x5f, bx=2, by=6, open=0x0e, event="EVENT_SILPH_CO_6_UNLOCKED_DOOR" },
  },
  SILPH_CO_7F = {
    { block=0x54, bx=5, by=3, open=0x0e, event="EVENT_SILPH_CO_7_UNLOCKED_DOOR1" },
    { block=0x54, bx=10, by=2, open=0x0e, event="EVENT_SILPH_CO_7_UNLOCKED_DOOR2" },
    { block=0x54, bx=10, by=6, open=0x0e, event="EVENT_SILPH_CO_7_UNLOCKED_DOOR3" },
  },
  SILPH_CO_8F = {
    { block=0x5f, bx=3, by=4, open=0x0e, event="EVENT_SILPH_CO_8_UNLOCKED_DOOR" },
  },
  SILPH_CO_9F = {
    { block=0x5f, bx=1, by=4, open=0x0e, event="EVENT_SILPH_CO_9_UNLOCKED_DOOR1" },
    { block=0x54, bx=9, by=2, open=0x0e, event="EVENT_SILPH_CO_9_UNLOCKED_DOOR2" },
    { block=0x54, bx=9, by=5, open=0x0e, event="EVENT_SILPH_CO_9_UNLOCKED_DOOR3" },
    { block=0x5f, bx=5, by=6, open=0x0e, event="EVENT_SILPH_CO_9_UNLOCKED_DOOR4" },
  },
  SILPH_CO_10F = {
    { block=0x54, bx=5, by=4, open=0x0e, event="EVENT_SILPH_CO_10_UNLOCKED_DOOR" },
  },
  SILPH_CO_11F = {
    { block=0x20, bx=3, by=6, open=0x03, event="EVENT_SILPH_CO_11_UNLOCKED_DOOR" },
  },
}

KantoState.TRASH_FALLBACK = {
  map = "VERMILION_GYM",
  firstLockEvent = "EVENT_1ST_LOCK_OPENED",
  secondLockEvent = "EVENT_2ND_LOCK_OPENED",
  firstLockCandidates = { 0, 2, 4, 6, 8, 10, 12, 14 },
  doorBlock = { bx = 2, by = 2, block = 5 },
  cans = {
    {x=1,y=7,can=0}, {x=1,y=9,can=1}, {x=1,y=11,can=2},
    {x=3,y=7,can=3}, {x=3,y=9,can=4}, {x=3,y=11,can=5},
    {x=5,y=7,can=6}, {x=5,y=9,can=7}, {x=5,y=11,can=8},
    {x=7,y=7,can=9}, {x=7,y=9,can=10}, {x=7,y=11,can=11},
    {x=9,y=7,can=12}, {x=9,y=9,can=13}, {x=9,y=11,can=14},
  },
  -- Canonical order is left, up, down, right with absent neighbours omitted.
  adjacent = {
    [0]={1,3}, [1]={0,2,4}, [2]={1,5},
    [3]={0,4,6}, [4]={1,3,5,7}, [5]={2,4,8},
    [6]={3,7,9}, [7]={4,6,8,10}, [8]={5,7,11},
    [9]={6,10,12}, [10]={7,9,11,13}, [11]={8,10,14},
    [12]={9,13}, [13]={10,12,14}, [14]={11,13},
  },
}

KantoState.GAME_CORNER_POSTER_FALLBACK = {
  map = "GAME_CORNER",
  x = 8, y = 2,
  closedBlock = 0x2A, openBlock = 0x43,
  event = "EVENT_FOUND_ROCKET_HIDEOUT",
  posterText = "TEXT_GAMECORNER_POSTER",
}

function KantoState.gameCornerPoster(region)
  local field = region and region.loaded and region.loaded.field
  local def = field and field.gameCornerPoster
  if type(def) == "table" and tonumber(def.x) and tonumber(def.y)
      and tonumber(def.closedBlock) and tonumber(def.openBlock) then
    return def
  end
  return KantoState.GAME_CORNER_POSTER_FALLBACK
end

function KantoState.closedDoorRows(region, mapId)
  local field = region and region.loaded and region.loaded.field
  local fromCache = field and field.cardKeyDoors and field.cardKeyDoors.closedDoors
  if type(fromCache) == "table" and type(fromCache[mapId]) == "table" then
    return fromCache[mapId]
  end
  return KantoState.CLOSED_DOOR_FALLBACK[mapId]
end

function KantoState.closedDoorSkipped(region, mapId)
  local field = region and region.loaded and region.loaded.field
  local cached = field and field.cardKeyDoors and field.cardKeyDoors.skipMaps
  if cached and cached.yellow and cached.yellow[mapId] ~= nil then
    return cached.yellow[mapId] == true
  end
  -- Yellow's B4F map has no DoorCallbackScript; Jessie & James do not set the
  -- Red/Blue pair of guard flags.  B1F still uses its retail callback.
  return mapId == "ROCKET_HIDEOUT_B4F"
end

function KantoState.trashPuzzle(region)
  local field = region and region.loaded and region.loaded.field
  local extracted = field and field.hiddenExtras and field.hiddenExtras.trashCans
  if type(extracted) == "table" and type(extracted.cans) == "table"
      and type(extracted.adjacent) == "table" then
    if extracted.doorBlock == nil then
      extracted.doorBlock = KantoState.TRASH_FALLBACK.doorBlock
    end
    return extracted
  end
  return KantoState.TRASH_FALLBACK
end

function KantoState.trashState()
  return KantoState.table(KantoState.TRASH_KEY)
end

function KantoState.saveTrash(state)
  return persistenceSet(KantoState.TRASH_KEY, type(state) == "table" and state or {})
end

function KantoState.randomInt(a, b)
  local rng = love and love.math and love.math.random
  if type(rng) == "function" then
    local ok, value = pcall(rng, a, b)
    if ok and tonumber(value) then return math.floor(tonumber(value)) end
  end
  return math.random(a, b)
end

function KantoState.rollTrashFirst(region, keepSecond)
  local puzzle = KantoState.trashPuzzle(region)
  local choices = puzzle.firstLockCandidates or KantoState.TRASH_FALLBACK.firstLockCandidates
  if type(choices) ~= "table" or #choices == 0 then return nil end
  local state = KantoState.trashState()
  state.first = tonumber(choices[KantoState.randomInt(1, #choices)]) or 0
  if not keepSecond then state.second = nil end
  KantoState.saveTrash(state)
  return state.first
end

-- Reproduce GymTrashScript's retail mask bug: the candidate COUNT is used as
-- a bit mask.  A zero AND indexes the byte before the candidate list and reads
-- bank padding, which behaves as can 0.
function KantoState.pickTrashSecond(region, first)
  local puzzle = KantoState.trashPuzzle(region)
  local rows = puzzle.adjacent or KantoState.TRASH_FALLBACK.adjacent
  local row = rows[tonumber(first)] or rows[tostring(first)]
    or KantoState.TRASH_FALLBACK.adjacent[tonumber(first)]
  if type(row) ~= "table" or #row == 0 then return 0 end
  local mask = #row
  local r = KantoState.randomInt(0, 255)
  local a, b, bitValue, masked = r, mask, 1, 0
  while a > 0 or b > 0 do
    local abit, bbit = a % 2, b % 2
    if abit == 1 and bbit == 1 then masked = masked + bitValue end
    a, b, bitValue = math.floor(a / 2), math.floor(b / 2), bitValue * 2
  end
  return tonumber(row[masked]) or 0
end

function KantoState.trainerHeaderEvent(region, mapId, obj)
  local all = region and region.loaded and region.loaded.trainerHeaders
  if type(all) ~= "table" or type(obj) ~= "table" then return nil end
  local def = region.loaded.maps and region.loaded.maps[mapId]
  local rows = (def and def.label and all[def.label]) or all[mapId]
  local header = type(rows) == "table" and rows[tonumber(obj.index) or -1] or nil
  return header and header.event or nil
end

function KantoState.migrateTrainerEvents(region, mapId)
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" then return end
  local wins = persistenceGet("yellowTrainerWinsV1", {})
  if type(wins) ~= "table" then return end
  for _, obj in ipairs(def.objects or {}) do
    if obj.trainerClass then
      local id = tostring(mapId) .. ":" .. tostring(obj.index or obj.name or obj.x) .. ":"
        .. tostring(obj.trainerClass or "TRAINER") .. ":" .. tostring(obj.trainerParty or 1)
      if wins[id] == true then
        local ev = KantoState.trainerHeaderEvent(region, mapId, obj)
        if ev then KantoState.setEvent(ev, true) end
      end
    end
  end
end

function KantoState.doorOpen(door)
  if type(door) ~= "table" then return false end
  if type(door.events) == "table" then
    for _, ev in ipairs(door.events) do
      if not KantoState.event(ev) then return false end
    end
    return true
  end
  return door.event and KantoState.event(door.event) or false
end

function KantoState.puzzleOriginalBlock(def, mapId, bx, by)
  if not (type(def) == "table" and type(def.blocks) == "table"
      and tonumber(def.width) and tonumber(bx) and tonumber(by)) then return nil end
  def._kantoDungeonOriginalBlocks = type(def._kantoDungeonOriginalBlocks) == "table"
    and def._kantoDungeonOriginalBlocks or {}
  local key = tostring(mapId or "") .. ":" .. tostring(bx) .. "," .. tostring(by)
  if def._kantoDungeonOriginalBlocks[key] == nil then
    local i = tonumber(by) * tonumber(def.width) + tonumber(bx) + 1
    def._kantoDungeonOriginalBlocks[key] = def.blocks[i]
  end
  return def._kantoDungeonOriginalBlocks[key]
end

function KantoState.applyDungeonPuzzleBlocks(region, mapId, def)
  if not (type(def) == "table" and type(def.blocks) == "table") then return 0 end
  local P = KantoState.DungeonPuzzles
  local changed = 0
  local mansion = P.mansionBlocks(mapId, KantoState.event(P.MANSION_EVENT))
  for _, row in ipairs(type(mansion) == "table" and mansion or {}) do
    local bx, by, block = tonumber(row.bx), tonumber(row.by), tonumber(row.block)
    if bx and by and block and bx >= 0 and by >= 0
        and bx < (tonumber(def.width) or 0) and by < (tonumber(def.height) or 0) then
      local i = by * def.width + bx + 1
      if def.blocks[i] ~= block then def.blocks[i] = block; changed = changed + 1 end
    end
  end
  for _, row in ipairs(P.victorySwitchRows(mapId) or {}) do
    local b = row.block or {}
    local bx, by = tonumber(b.bx), tonumber(b.by)
    if bx and by and bx >= 0 and by >= 0
        and bx < (tonumber(def.width) or 0) and by < (tonumber(def.height) or 0) then
      local original = KantoState.puzzleOriginalBlock(def, mapId, bx, by)
      local block = KantoState.event(row.event) and tonumber(b.open) or tonumber(original)
      local i = by * def.width + bx + 1
      if block and def.blocks[i] ~= block then def.blocks[i] = block; changed = changed + 1 end
    end
  end
  return changed
end

function KantoState.restampDungeonPuzzleMap(region, mapId, map)
  if not (map and map.def) then return 0 end
  local P = KantoState.DungeonPuzzles
  local changed = 0
  local mansion = P.mansionBlocks(mapId, KantoState.event(P.MANSION_EVENT))
  for _, row in ipairs(type(mansion) == "table" and mansion or {}) do
    if KantoState.refreshBlock(map, row.bx, row.by, row.block, true) then changed = changed + 1 end
  end
  for _, row in ipairs(P.victorySwitchRows(mapId) or {}) do
    local b = row.block or {}
    local original = KantoState.puzzleOriginalBlock(map.def, mapId, b.bx, b.by)
    local block = KantoState.event(row.event) and b.open or original
    if block and KantoState.refreshBlock(map, b.bx, b.by, block, true) then changed = changed + 1 end
  end
  if changed > 0 and ChunkMesher and type(ChunkMesher.refresh) == "function" then
    pcall(ChunkMesher.refresh, map.id)
    Twin.yellowDungeonPuzzleRefreshes = (Twin.yellowDungeonPuzzleRefreshes or 0) + 1
  end
  return changed
end

function KantoState.applyLeagueBlocks(region, mapId, def)
  if not (def and type(def.blocks) == "table") then return 0 end
  local L = KantoState.League
  local changed = 0
  for _, row in ipairs(L.blocks(mapId, KantoState.event) or {}) do
    local bx, by, block = tonumber(row.bx), tonumber(row.by), tonumber(row.block)
    if bx and by and block and bx >= 0 and by >= 0
        and bx < (tonumber(def.width) or 0) and by < (tonumber(def.height) or 0) then
      local i = by * def.width + bx + 1
      if def.blocks[i] ~= block then def.blocks[i] = block; changed = changed + 1 end
    end
  end
  return changed
end

function KantoState.restampLeagueMap(region, mapId, map)
  if not (map and map.def) then return 0 end
  local changed = 0
  for _, row in ipairs(KantoState.League.blocks(mapId, KantoState.event) or {}) do
    if KantoState.refreshBlock(map, row.bx, row.by, row.block, true) then
      changed = changed + 1
    end
  end
  if changed > 0 and ChunkMesher and type(ChunkMesher.refresh) == "function" then
    pcall(ChunkMesher.refresh, map.id)
    Twin.yellowLeagueBlockRefreshes = (Twin.yellowLeagueBlockRefreshes or 0) + 1
  end
  return changed
end
Twin._restampKantoLeagueMap = KantoState.restampLeagueMap

function KantoState.applyPhysicalBlocks(region, mapId, def)
  if type(def) ~= "table" or type(def.blocks) ~= "table" then return 0 end
  KantoState.migrateTrainerEvents(region, mapId)
  local changed = 0
  if not KantoState.closedDoorSkipped(region, mapId) then
    for _, door in ipairs(KantoState.closedDoorRows(region, mapId) or {}) do
      local bx, by = tonumber(door.bx), tonumber(door.by)
      local block = KantoState.doorOpen(door) and tonumber(door.open) or tonumber(door.block)
      if bx and by and block and bx >= 0 and by >= 0
          and bx < (tonumber(def.width) or 0) and by < (tonumber(def.height) or 0) then
        local i = by * def.width + bx + 1
        if def.blocks[i] ~= block then def.blocks[i] = block; changed = changed + 1 end
      end
    end
  end
  local puzzle = KantoState.trashPuzzle(region)
  if mapId == tostring(puzzle.map or "VERMILION_GYM")
      and KantoState.event(puzzle.secondLockEvent or "EVENT_2ND_LOCK_OPENED") then
    local door = puzzle.doorBlock or KantoState.TRASH_FALLBACK.doorBlock
    local bx, by, block = tonumber(door.bx), tonumber(door.by), tonumber(door.block)
    if bx and by and block and bx >= 0 and by >= 0
        and bx < (tonumber(def.width) or 0) and by < (tonumber(def.height) or 0) then
      local i = by * def.width + bx + 1
      if def.blocks[i] ~= block then def.blocks[i] = block; changed = changed + 1 end
    end
  end
  -- Game Corner's poster switch is another pure geometry callback: the
  -- authored floor ships block $2a at (8,2), and EVENT_FOUND_ROCKET_HIDEOUT
  -- swaps it to $43. Story-free Kanto mirrors only that block/event state.
  local poster = KantoState.gameCornerPoster(region)
  if mapId == tostring(poster.map or "GAME_CORNER") then
    local bx, by = tonumber(poster.x), tonumber(poster.y)
    local open = KantoState.event(poster.event or "EVENT_FOUND_ROCKET_HIDEOUT")
    local block = open and tonumber(poster.openBlock) or tonumber(poster.closedBlock)
    if bx and by and block and bx >= 0 and by >= 0
        and bx < (tonumber(def.width) or 0) and by < (tonumber(def.height) or 0) then
      local i = by * def.width + bx + 1
      if def.blocks[i] ~= block then def.blocks[i] = block; changed = changed + 1 end
    end
  end
  changed = changed + KantoState.applyDungeonPuzzleBlocks(region, mapId, def)
  changed = changed + KantoState.applySSAnneDockBlocks(region, mapId, def)
  changed = changed + KantoState.applyLeagueBlocks(region, mapId, def)
  return changed
end

function KantoState.refreshBlock(map, bx, by, block, deferRefresh)
  if not (map and type(map.setBlock) == "function" and tonumber(block)) then return false end
  bx, by, block = tonumber(bx), tonumber(by), math.floor(tonumber(block))
  if not (bx and by) then return false end
  if type(map.blockAt) == "function" and map:blockAt(bx, by) == block then return false end
  if not map:setBlock(bx, by, block) then return false end
  if not deferRefresh and ChunkMesher and type(ChunkMesher.refresh) == "function" then
    pcall(ChunkMesher.refresh, map.id)
  end
  return true
end

function KantoState.restampClosedDoors(region, mapId, map)
  if KantoState.closedDoorSkipped(region, mapId) then return 0 end
  local changed = 0
  for _, door in ipairs(KantoState.closedDoorRows(region, mapId) or {}) do
    local block = KantoState.doorOpen(door) and tonumber(door.open) or tonumber(door.block)
    if block and KantoState.refreshBlock(map, door.bx, door.by, block, true) then
      changed = changed + 1
    end
  end
  if changed > 0 then
    if ChunkMesher and type(ChunkMesher.refresh) == "function" then
      pcall(ChunkMesher.refresh, map.id)
      Twin.kantoBlockBatchRefreshes = (Twin.kantoBlockBatchRefreshes or 0) + 1
    end
    Twin.yellowClosedDoorRestamps = (Twin.yellowClosedDoorRestamps or 0) + changed
  end
  return changed
end

function KantoState.restampGameCornerPoster(region, mapId, map)
  local poster = KantoState.gameCornerPoster(region)
  if mapId ~= tostring(poster.map or "GAME_CORNER") then return false end
  local open = KantoState.event(poster.event or "EVENT_FOUND_ROCKET_HIDEOUT")
  local block = open and tonumber(poster.openBlock) or tonumber(poster.closedBlock)
  if not block then return false end
  if KantoState.refreshBlock(map, poster.x, poster.y, block) then
    Twin.yellowGameCornerPosterRestamps = (Twin.yellowGameCornerPosterRestamps or 0) + 1
    return true
  end
  return false
end

function KantoState.migrateSpecialPhysicalObjects(region, mapId)
  if mapId ~= "GAME_CORNER" then return false end
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" then return false end
  local wins = persistenceGet("yellowTrainerWinsV1", {})
  if type(wins) ~= "table" then return false end
  for _, obj in ipairs(def.objects or {}) do
    if tostring(obj.text or "") == "TEXT_GAMECORNER_ROCKET" then
      local id = tostring(mapId) .. ":" .. tostring(obj.index or obj.name or obj.x) .. ":"
        .. tostring(obj.trainerClass or "TRAINER") .. ":" .. tostring(obj.trainerParty or 1)
      if wins[id] == true and KantoState.setObjectHidden(mapId, obj, true) then
        if region.npcCache then region.npcCache[mapId] = nil end
        if region.pokemonCache then region.pokemonCache[mapId] = nil end
        KantoState.Spatial.invalidate(region, mapId, true, true)
        Twin.yellowGameCornerRocketMigrations = (Twin.yellowGameCornerRocketMigrations or 0) + 1
        return true
      end
    end
  end
  return false
end

function KantoState.migrateMuseumAmber(region, mapId)
  local Civic = KantoState.Civic
  if tostring(mapId or "") ~= tostring(Civic.MUSEUM_MAP or "MUSEUM_1F")
      or not KantoState.event(Civic.OLD_AMBER_EVENT or "EVENT_GOT_OLD_AMBER") then
    return false
  end
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" then return false end
  local changed = false
  for _, obj in ipairs(def.objects or {}) do
    if Civic.isAmberDisplay(mapId, obj) and KantoState.setObjectHidden(mapId, obj, true) then
      changed = true
    end
  end
  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
    Twin.yellowMuseumObjectMigrations = (Twin.yellowMuseumObjectMigrations or 0) + 1
  end
  return changed
end
Twin._migrateMuseumAmber = KantoState.migrateMuseumAmber

-- Yellow's Melanie script hides the pet BULBASAUR object after she hands that
-- Pokemon to the player.  The dialogue sandbox intentionally cannot execute
-- HideObject, so keep the one authored physical mutation as companion-local
-- state and repair it on map entry after an upgrade/reload.
function KantoState.hideStarterGiftObject(region, spec)
  if not (region and spec and spec.objectText) then return false end
  local mapId = tostring(spec.map or "")
  local def = region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" then return false end
  local changed = false
  for _, obj in ipairs(def.objects or {}) do
    if KantoState.StarterGifts.isGiftObject(spec, obj)
        and KantoState.setObjectHidden(mapId, obj, true) then
      changed = true
    end
  end
  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
  end
  return changed
end
Twin._hideKantoStarterGiftObject = KantoState.hideStarterGiftObject

function KantoState.migrateStarterGiftObjects(region, mapId)
  local changed = false
  for _, spec in ipairs(KantoState.StarterGifts.forMap(mapId)) do
    if spec.objectText and KantoState.event(spec.event)
        and KantoState.hideStarterGiftObject(region, spec) then
      changed = true
      Twin.yellowStarterGiftObjectMigrations =
        (Twin.yellowStarterGiftObjectMigrations or 0) + 1
    end
  end
  return changed
end
Twin._migrateKantoStarterGiftObjects = KantoState.migrateStarterGiftObjects

-- Scripted reward objects that physically disappear after a successful claim
-- (Celadon EEVEE and the selected Fighting Dojo ball).  Keep this separate
-- from the Yellow-starter helper because these rewards exist in Red too.
function KantoState.hideRewardObject(region, spec)
  if not (region and spec and spec.objectText) then return false end
  local mapId = tostring(spec.map or "")
  local def = region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" then return false end
  local changed = false
  for _, obj in ipairs(def.objects or {}) do
    if KantoState.Rewards.isPhysicalObject(spec, obj)
        and KantoState.setObjectHidden(mapId, obj, true) then
      changed = true
    end
  end
  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
  end
  return changed
end
Twin._hideKantoRewardObject = KantoState.hideRewardObject

function KantoState.migrateRewardObjects(region, mapId)
  local changed = false
  for _, spec in ipairs(KantoState.Rewards.forMap(mapId)) do
    if KantoState.event(spec.event) and KantoState.hideRewardObject(region, spec) then
      changed = true
      Twin.yellowRewardObjectMigrations = (Twin.yellowRewardObjectMigrations or 0) + 1
    end
  end
  return changed
end
Twin._migrateKantoRewardObjects = KantoState.migrateRewardObjects

function KantoState.revealObjectByText(region, mapId, textConst)
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" then return false end
  local changed = false
  for _, obj in ipairs(def.objects or {}) do
    if tostring(obj.text or "") == tostring(textConst or "") then
      -- Clear an explicit companion hide and set force-visible so an imported
      -- obj.hidden=true row can still be revealed by its Yellow event.
      KantoState.setObjectHidden(mapId, obj, false)
      if KantoState.setObjectShown(mapId, obj, true) then changed = true end
    end
  end
  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
  end
  return changed
end
Twin._revealKantoObjectByText = KantoState.revealObjectByText

function KantoState.hideObjectsByText(region, mapId, texts)
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" or type(texts) ~= "table" then return false end
  local changed = false
  for _, obj in ipairs(def.objects or {}) do
    if texts[tostring(obj.text or "")] then
      KantoState.setObjectShown(mapId, obj, false)
      if KantoState.setObjectHidden(mapId, obj, true) then changed = true end
    end
  end
  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
  end
  return changed
end
Twin._hideKantoObjectsByText = KantoState.hideObjectsByText

function KantoState.migrateSSAnneObjects(region, mapId)
  local S = KantoState.SSAnne
  local B, R = S.BILL, S.RIVAL
  mapId = tostring(mapId or "")
  local changed = false
  if mapId == B.map then
    local hide = {}
    if not KantoState.event(B.met2Event) then
      changed = KantoState.revealObjectByText(region, mapId, B.pokemonText) or changed
      hide[B.ticketText], hide[B.rareText] = true, true
    elseif KantoState.event(B.leftEvent) then
      changed = KantoState.revealObjectByText(region, mapId, B.rareText) or changed
      hide[B.pokemonText], hide[B.ticketText] = true, true
    else
      changed = KantoState.revealObjectByText(region, mapId, B.ticketText) or changed
      hide[B.pokemonText], hide[B.rareText] = true, true
    end
    changed = KantoState.hideObjectsByText(region, mapId, hide) or changed
  elseif mapId == R.map then
    -- Yellow's rival is hidden until the 36/37,8 trigger. Keep it hidden on
    -- ordinary map entry; ssAnneRivalStep force-reveals it for the encounter.
    changed = KantoState.hideObjectsByText(region, mapId, { [R.text] = true }) or changed
  end
  return changed
end
Twin._migrateKantoSSAnneObjects = KantoState.migrateSSAnneObjects

-- v0.3.88: Silph Co's finale changes object state across the whole tower and
-- Saffron City. Yellow implements that with one long toggle-id list; the
-- excursion uses semantic object facts so extractor index changes cannot make
-- Team Rocket reappear or hide the wrong civilian.
function KantoState.setSilphObjectVisible(region, mapId, obj, visible)
  if not (region and obj) then return false end
  local changed = false
  if visible then
    changed = KantoState.setObjectHidden(mapId, obj, false) or changed
    changed = KantoState.setObjectShown(mapId, obj, true) or changed
  else
    changed = KantoState.setObjectShown(mapId, obj, false) or changed
    changed = KantoState.setObjectHidden(mapId, obj, true) or changed
  end
  return changed
end
Twin._setKantoSilphObjectVisible = KantoState.setSilphObjectVisible

function KantoState.migrateSilphState(region, mapId)
  local S = KantoState.Silph
  mapId = tostring(mapId or "")
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" then return false end
  local liberated = KantoState.event(S.FINAL.giovanniEvent)
  local changed = false
  if mapId == S.SAFFRON.map then
    for _, obj in ipairs(def.objects or {}) do
      if S.isSaffronRocket(obj) then
        changed = KantoState.setSilphObjectVisible(region, mapId, obj, not liberated) or changed
      elseif S.isSaffronCivilian(obj) then
        changed = KantoState.setSilphObjectVisible(region, mapId, obj, liberated) or changed
      end
    end
    if changed then
      Twin.yellowSaffronStateMigrations = (Twin.yellowSaffronStateMigrations or 0) + 1
    end
  elseif liberated and S.isSilphFloor(mapId) then
    for _, obj in ipairs(def.objects or {}) do
      if S.isSilphRocket(mapId, obj) then
        changed = KantoState.setSilphObjectVisible(region, mapId, obj, false) or changed
      end
    end
  end
  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
  end
  return changed
end
Twin._migrateKantoSilphState = KantoState.migrateSilphState

function KantoState.applySilphLiberation(region)
  local S = KantoState.Silph
  if not KantoState.event(S.FINAL.giovanniEvent) then return 0 end
  local maps = region and region.loaded and region.loaded.maps
  if type(maps) ~= "table" then return 0 end
  local changed = 0
  for mapId in pairs(maps) do
    if mapId == S.SAFFRON.map or S.isSilphFloor(mapId) then
      if KantoState.migrateSilphState(region, mapId) then changed = changed + 1 end
    end
  end
  return changed
end
Twin._applyKantoSilphLiberation = KantoState.applySilphLiberation

function KantoState.applySSAnneDockBlocks(region, mapId, def)
  local S = KantoState.SSAnne
  if tostring(mapId or "") ~= S.SHIP.dockMap
      or not KantoState.event(S.SHIP.leftEvent)
      or type(def) ~= "table" or type(def.blocks) ~= "table" then return 0 end
  local changed = 0
  for _, row in ipairs(S.SHIP.departureBlocks or {}) do
    local bx, by, block = tonumber(row.bx), tonumber(row.by), tonumber(row.block)
    if bx and by and block and bx >= 0 and by >= 0
        and bx < (tonumber(def.width) or 0) and by < (tonumber(def.height) or 0) then
      local i = by * def.width + bx + 1
      if def.blocks[i] ~= block then def.blocks[i] = block; changed = changed + 1 end
    end
  end
  return changed
end
Twin._applyKantoSSAnneDockBlocks = KantoState.applySSAnneDockBlocks

function KantoState.restampSSAnneDock(region, mapId, map)
  local S = KantoState.SSAnne
  if tostring(mapId or "") ~= S.SHIP.dockMap
      or not KantoState.event(S.SHIP.leftEvent) or not map then return 0 end
  local changed = 0
  for _, row in ipairs(S.SHIP.departureBlocks or {}) do
    if KantoState.refreshBlock(map, row.bx, row.by, row.block, true) then changed = changed + 1 end
  end
  if changed > 0 and ChunkMesher and type(ChunkMesher.refresh) == "function" then
    pcall(ChunkMesher.refresh, map.id)
  end
  return changed
end
Twin._restampKantoSSAnneDock = KantoState.restampSSAnneDock

function KantoState.migrateQuestObjects(region, mapId)
  mapId = tostring(mapId or "")
  local changed = false
  local hide = {}
  local rocket = KantoState.Items.ROCKET_HIDEOUT
  if mapId == tostring(rocket.map or "") then
    if KantoState.event(rocket.droppedLiftKeyEvent) then
      changed = KantoState.revealObjectByText(region, mapId, rocket.liftKeyText) or changed
    end
    if KantoState.event(rocket.giovanniEvent) then
      changed = KantoState.revealObjectByText(region, mapId, rocket.silphScopeText) or changed
      hide[tostring(rocket.giovanniText)] = true
    end
    if KantoState.event(rocket.duoEvent) then
      hide.TEXT_ROCKETHIDEOUTB4F_JESSIE = true
      hide.TEXT_ROCKETHIDEOUTB4F_JAMES = true
    end
  end

  local tower = KantoState.Items.POKEMON_TOWER
  if mapId == tostring(tower.fujiMap or "") then
    if KantoState.event(tower.rocketEvent) then
      for text in pairs(tower.rocketTexts or {}) do hide[tostring(text)] = true end
    end
    if KantoState.event(tower.rescueEvent) then hide[tostring(tower.fujiText)] = true end
  elseif mapId == tostring(tower.fujiHouseMap or "") and KantoState.event(tower.rescueEvent) then
    changed = KantoState.revealObjectByText(region, mapId, tower.fujiHouseText) or changed
  end

  local sleepy = KantoState.Items.SNORLAX[mapId]
  if sleepy and KantoState.event(sleepy.event) then hide[tostring(sleepy.text)] = true end
  if next(hide) ~= nil then changed = KantoState.hideObjectsByText(region, mapId, hide) or changed end
  return changed
end
Twin._migrateKantoQuestObjects = KantoState.migrateQuestObjects

-- v0.3.90 rival actors are script-revealed in Yellow. Keep them absent while
-- roaming normally, reveal them only on their authored trigger cell, then
-- persist the disappearance after victory. This also repairs old imports where
-- toggle state accidentally left a rival standing in the open.
function KantoState.migrateRivalObjects(region, mapId)
  local changed = false
  for _, spec in ipairs(KantoState.Rival.forMap(mapId)) do
    local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
    for _, obj in ipairs(def and def.objects or {}) do
      if KantoState.Rival.isObject(spec, obj) then
        KantoState.setObjectShown(mapId, obj, false)
        if KantoState.setObjectHidden(mapId, obj, true) then changed = true end
      end
    end
  end
  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
  end
  return changed
end
Twin._migrateKantoRivalObjects = KantoState.migrateRivalObjects

-- Yellow's Hall of Fame script hides the Cerulean Cave guard. Mirror that
-- physical postgame state from the companion-local Hall-of-Fame event. Before
-- induction the guard is force-visible, so an extractor/toggle mismatch can
-- never make the postgame cave look open early.
function KantoState.migratePostgameObjects(region, mapId)
  local P = KantoState.Postgame
  local cave = P.CERULEAN_CAVE
  if tostring(mapId or "") ~= tostring(cave.cityMap or "") then return false end
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" then return false end
  local unlocked = P.ceruleanCaveUnlocked(KantoState.event)
  local changed = false
  for _, obj in ipairs(def.objects or {}) do
    if P.isCeruleanGuard(mapId, obj) then
      if unlocked then
        KantoState.setObjectShown(mapId, obj, false)
        if KantoState.setObjectHidden(mapId, obj, true) then changed = true end
      else
        if KantoState.setObjectHidden(mapId, obj, false) then changed = true end
        if KantoState.setObjectShown(mapId, obj, true) then changed = true end
      end
    end
  end
  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
  end
  return changed
end
Twin._migrateKantoPostgameObjects = KantoState.migratePostgameObjects

-- v0.3.94: Cerulean robbery aftermath parity.
-- Yellow starts with GUARD1 hidden and GUARD2 + the Rocket visible.  After the
-- thief has actually returned TM28, CeruleanHideRocket flips those physical
-- actors: GUARD1 appears, GUARD2 disappears, and the Rocket disappears.
-- Keep this as a migration so old saves reconstruct the same world on reload.
function KantoState.migrateCeruleanRobberyObjects(region, mapId)
  mapId = tostring(mapId or "")
  if mapId ~= "CERULEAN_CITY" then return false end
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" then return false end

  local returned = KantoState.event("EVENT_KANTO_RETURNED_STOLEN_TM28")
  local changed = false
  for _, obj in ipairs(def.objects or {}) do
    local name = tostring(obj.name or "")
    local text = tostring(obj.text or "")
    local isRocket = name == "CERULEANCITY_ROCKET" or text == "TEXT_CERULEANCITY_ROCKET"
    local isGuard1 = name == "CERULEANCITY_GUARD1"
    local isGuard2 = name == "CERULEANCITY_GUARD2"

    if isRocket then
      KantoState.setObjectShown(mapId, obj, not returned)
      if KantoState.setObjectHidden(mapId, obj, returned) then changed = true end
    elseif isGuard1 then
      KantoState.setObjectShown(mapId, obj, returned)
      if KantoState.setObjectHidden(mapId, obj, not returned) then changed = true end
    elseif isGuard2 then
      KantoState.setObjectShown(mapId, obj, not returned)
      if KantoState.setObjectHidden(mapId, obj, returned) then changed = true end
    end
  end

  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
    Twin.yellowCeruleanRobberyMigrations = (Twin.yellowCeruleanRobberyMigrations or 0) + 1
  end
  return changed
end
Twin._migrateKantoCeruleanRobberyObjects = KantoState.migrateCeruleanRobberyObjects

function KantoState.onMapEntered(region, mapId)
  local P = KantoState.DungeonPuzzles
  -- Yellow resets the Mansion's global statue switch when Cinnabar Island is
  -- loaded, and Victory Road 2F resets the temporary 1F boulder-switch bit.
  -- These are local Kanto physical flags only; Gold story state is untouched.
  if tostring(mapId or "") == tostring(P.MANSION_RESET_MAP or "CINNABAR_ISLAND") then
    KantoState.setEvent(P.MANSION_EVENT, false)
  end
  if tostring(mapId or "") == "VICTORY_ROAD_2F" then
    KantoState.setEvent("EVENT_VICTORY_ROAD_1_BOULDER_ON_SWITCH", false)
  end
  KantoState.migrateSpecialPhysicalObjects(region, mapId)
  KantoState.migrateMuseumAmber(region, mapId)
  KantoState.migrateStarterGiftObjects(region, mapId)
  KantoState.migrateRewardObjects(region, mapId)
  KantoState.migrateQuestObjects(region, mapId)
  KantoState.migrateSSAnneObjects(region, mapId)
  KantoState.migrateSilphState(region, mapId)
  KantoState.migrateRivalObjects(region, mapId)
  KantoState.migratePostgameObjects(region, mapId)
  KantoState.migrateCeruleanRobberyObjects(region, mapId)
  local voyage = KantoState.SSAnne
  if mapId == voyage.BILL.routeMap then
    if not KantoState.event(voyage.BILL.met2Event)
        and KantoState.event(voyage.BILL.saidEvent) then
      -- Yellow resets an abandoned pre-separation attempt when Route 25 loads.
      KantoState.setEvent(voyage.BILL.saidEvent, false)
      KantoState.migrateSSAnneObjects(region, voyage.BILL.map)
    elseif KantoState.event(voyage.BILL.met2Event)
        and KantoState.event(voyage.BILL.ticketEvent)
        and not KantoState.event(voyage.BILL.leftEvent) then
      KantoState.setEvent(voyage.BILL.leftEvent, true)
      KantoState.migrateSSAnneObjects(region, voyage.BILL.map)
    end
  end
  if mapId == "VERMILION_CITY" then
    -- scripts/VermilionCity.asm rolls wFirstLockTrashCanIndex on every map load,
    -- even mid-puzzle; it does not clear the already-open first lock or second.
    KantoState.rollTrashFirst(region, true)
  end
  local map = region and region.mapsById and region.mapsById[mapId]
  if type(map) == "table" then
    KantoState.restampClosedDoors(region, mapId, map)
    KantoState.restampGameCornerPoster(region, mapId, map)
    KantoState.restampDungeonPuzzleMap(region, mapId, map)
    KantoState.restampSSAnneDock(region, mapId, map)
  end
  return true
end
Twin._kantoOnMapEntered = KantoState.onMapEntered

function Twin.oceanEnabled()
  return option("worldOcean", false)
end

-- v0.4.32: OPEN WORLD is a real Kanto excursion setting too. Earlier Kanto
-- builds always marked the Yellow sector streamer as open-world internally,
-- so the public OPEN WORLD row had no effect once the player entered Kanto.
function Twin.openWorldEnabled()
  return option("openWorld", false)
end

function Twin.gen1Enabled()
  return option("gen1Region", false)
end

local function now()
  local timer = love and love.timer
  if not (timer and type(timer.getTime) == "function") then return 0 end
  if Twin._timerProbeRef ~= timer or Twin._timerProbeFn ~= timer.getTime then
    Twin._timerProbeRef, Twin._timerProbeFn, Twin._timerProbeTrusted = timer, timer.getTime, false
    local ok, value = pcall(Twin._timerProbeFn)
    if not (ok and tonumber(value)) then return 0 end
    Twin._timerProbeTrusted = true
    return tonumber(value)
  end
  if Twin._timerProbeTrusted then
    local value = Twin._timerProbeFn()
    return tonumber(value) or 0
  end
  return 0
end

Twin._now = now

local function deepCopy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do out[deepCopy(k, seen)] = deepCopy(v, seen) end
  return out
end

local function compileTable(bytes, label)
  if type(bytes) ~= "string" or bytes == "" then return nil, "empty " .. label end
  local loadcode = loadstring or load
  local chunk, err = loadcode(bytes, "@stadium-gen1-cache/" .. label)
  if not chunk then return nil, "could not compile " .. label .. ": " .. tostring(err) end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= "table" then
    return nil, "could not load " .. label .. ": " .. tostring(value)
  end
  return value
end

-- Engine-owned cache access is important on the current sandbox: raw
-- love.filesystem is hidden from mods, while CacheFs already knows the save
-- directory / portable folder and per-version layout.
local function cacheModule()
  local ok, value = pcall(require, "src.import.CacheFs")
  return ok and type(value) == "table" and value or nil
end

local function readVersion(CacheFs, version, rel)
  if not (CacheFs and type(CacheFs.read) == "function") then return nil end

  -- CacheFs.prefix is a mutable importer cursor, not part of the path the
  -- running game wants to read.  On a Gold boot it can still contain the
  -- active version while an import/launcher path is unwinding; blindly asking
  -- for "red/data/..." then becomes "gold/red/data/..." and every Kanto
  -- probe misses.  Temporarily clear it around this one engine-owned read and
  -- restore it even if the read throws.
  local savedPrefix = CacheFs.prefix
  CacheFs.prefix = ""
  local ok, bytes = pcall(CacheFs.read, version .. "/" .. rel)
  CacheFs.prefix = savedPrefix
  Twin.cachePrefixRestores = (Twin.cachePrefixRestores or 0) + 1
  if ok and type(bytes) == "string" then
    Twin.cacheReads = (Twin.cacheReads or 0) + 1
    return bytes
  end
  return nil
end

local function loadGeneratedTables()
  local CacheFs = cacheModule()
  if not CacheFs then return nil, "Gen1Recomp CacheFs is unavailable" end
  if type(CacheFs.migrateLegacyRedCache) == "function" then
    pcall(CacheFs.migrateLegacyRedCache)
  end

  -- v0.2.85 deliberately uses Pokemon Yellow as the Kanto authority.  The
  -- previous Red/Blue/Yellow first-hit policy could make two players see
  -- different terrain palettes, NPC sheets and encounter tables depending on
  -- whichever Gen-1 game they happened to import first.
  local version = "yellow"
  local required = {
    maps = "data/generated/maps.lua",
    tilesets = "data/generated/tilesets.lua",
    sprites = "data/generated/sprites.lua",
    encounters = "data/generated/encounters.lua",
    pokemon = "data/generated/pokemon.lua",
    palettes = "data/generated/palettes.lua",
  }
  local loaded = { version = version, CacheFs = CacheFs }
  for key, rel in pairs(required) do
    local bytes = readVersion(CacheFs, version, rel)
    if not bytes then
      return nil, "Pokemon Yellow import is missing " .. rel
    end
    local value, err = compileTable(bytes, version .. "/" .. rel)
    if not value then return nil, err end
    loaded[key] = value
  end
  -- Non-story interaction data is optional for old Yellow caches. Terrain and
  -- teleport remain usable without it; a freshly imported/current cache adds
  -- authored trainer parties and plain NPC text for the Kanto battle layer.
  for key, rel in pairs({
    trainers = "data/generated/trainers.lua",
    text = "data/generated/text.lua",
    -- Current Yellow caches split object TEXT_* constants from their resolved
    -- text labels. v0.3.27 loaded text.lua but skipped this table, so most NPCs
    -- had a visible body and collision but pressing A resolved no line at all.
    textPointers = "data/generated/text_pointers.lua",
    trainerHeaders = "data/generated/trainer_headers.lua",
    -- Gen-1 item metadata is needed for semantic TM/HM translation into Gold:
    -- item ids changed between generations, but the machine's move did not.
    items = "data/generated/items.lua",
    -- Current Gen1Recomp exports field movement metadata on newer caches. Old
    -- caches may not have it, so keep this optional.
    field = "data/generated/field.lua",
  }) do
    local bytes = readVersion(CacheFs, version, rel)
    if bytes then
      local value = compileTable(bytes, version .. "/" .. rel)
      if type(value) == "table" then loaded[key] = value end
    end
  end
  return loaded
end

local function mapIsOutdoor(_Map, def)
  if not def then return false end
  -- Match current Gen1Recomp Map.isOutdoor: authored override first, then
  -- OVERWORLD only. PLATEAU is "outside" for LAST_MAP memory but is not the
  -- same semantic class as ordinary outdoor terrain.
  if def.outdoor ~= nil then return def.outdoor == true end
  return def.tileset == "OVERWORLD"
end

local function mapIsOutside(_Map, def)
  if not def then return false end
  -- Match current Gen1Recomp Map.isOutside. This wider test is what warp
  -- memory needs so Route 23 / Indigo Plateau style maps return correctly.
  return mapIsOutdoor(_Map, def)
      or def.tileset == "OVERWORLD"
      or def.tileset == "PLATEAU"
end

local function setFrom(values, defaults)
  local out = {}
  values = values or defaults or {}
  for k, v in pairs(values) do
    if type(v) == "boolean" then
      if v then out[tonumber(k) or k] = true end
    else
      local value = tonumber(v) or v
      out[value] = true
    end
  end
  return out
end

-- Current Gen1Recomp Map.lua distinguishes teleporter pads / fall-through
-- holes from ordinary doors so WarpFound2 can use the correct transition.
-- New Yellow caches may author `warpPadTiles`; these vanilla rows are the
-- stale-cache fallback used by the engine today.
local WARP_PAD_TILES = {
  FACILITY = { [0x20] = "pad", [0x11] = "hole" },
  CAVERN = { [0x22] = "hole" },
  INTERIOR = { [0x55] = "pad" },
}

-- Private Gen-1 map adapter.  Do NOT require("src.world.Map") here: under a
-- Gold mod Gen2Compat deliberately aliases that name to the live Gen-2 Map
-- class.  The voxel mesher needs Gen-1 tile ids / walkable lists for the
-- inactive Kanto cache, so construct the tiny generation-1 surface locally.
local ForeignGen1Map = {}
ForeignGen1Map.__index = ForeignGen1Map

function ForeignGen1Map.new(def, tileset)
  local self = setmetatable({}, ForeignGen1Map)
  self._stadiumForeignGen1Map = true
  self._cellTileCache = {}
  self.def = def
  self.id = def.id
  self.tileset = tileset
  self.widthCells = (tonumber(def.width) or 0) * 2
  self.heightCells = (tonumber(def.height) or 0) * 2
  self.walkable = setFrom(tileset.walkable)
  self.doorTiles = setFrom(tileset.doorTiles)
  self.warpTiles = setFrom(tileset.warpTiles)
  self.counterTiles = setFrom(tileset.counterTiles)
  self.warpPadTiles = tileset.warpPadTiles or WARP_PAD_TILES[def.tileset]
  self.waterTiles = setFrom(tileset.waterTiles, { 0x14 })
  local shore = tileset.shoreTiles
  if shore == nil and def.tileset ~= "SHIP_PORT" then shore = { 0x32, 0x48 } end
  for tile in pairs(setFrom(shore)) do self.waterTiles[tile] = true end
  self._warpAt = {}
  for i, warp in ipairs(def.warps or {}) do
    if warp.x ~= nil and warp.y ~= nil then
      self._warpAt[(tonumber(warp.y) or 0) * self.widthCells + (tonumber(warp.x) or 0)] = {
        index = i, def = warp,
      }
    end
  end
  self._signAt = {}
  for _, sign in ipairs(def.signs or {}) do
    if sign.x ~= nil and sign.y ~= nil then
      self._signAt[(tonumber(sign.y) or 0) * self.widthCells + (tonumber(sign.x) or 0)] = sign
    end
  end
  return self
end

function ForeignGen1Map:blockAt(bx, by)
  if bx < 0 or by < 0 or bx >= self.def.width or by >= self.def.height then
    return self.def.borderBlock or 0
  end
  return self.def.blocks[by * self.def.width + bx + 1] or self.def.borderBlock or 0
end

function ForeignGen1Map:setBlock(bx, by, blockId)
  bx, by, blockId = tonumber(bx), tonumber(by), tonumber(blockId)
  if not (bx and by and blockId) then return false end
  bx, by = math.floor(bx), math.floor(by)
  if bx < 0 or by < 0 or bx >= self.def.width or by >= self.def.height then
    return false
  end
  self.def.blocks[by * self.def.width + bx + 1] = math.floor(blockId)
  -- One Gen-1 block is 4x4 tiles = 2x2 collision cells.  Kanto movement
  -- queries the same cell tile many times per rendered frame (walkability,
  -- water, grass, warp carpet, elevation).  Invalidate only the four cached
  -- collision cells touched by this dynamic restamp instead of discarding the
  -- whole map cache.
  if self._cellTileCache then
    local x0, y0 = bx * 2, by * 2
    for oy = 0, 1 do
      local base = (y0 + oy) * self.widthCells + x0
      self._cellTileCache[base] = nil
      self._cellTileCache[base + 1] = nil
    end
  end
  return true
end

function ForeignGen1Map:tileAt(tx, ty)
  local blocks = self.tileset and self.tileset.blocks
  if not blocks then return nil end
  local blockId = self:blockAt(math.floor(tx / 4), math.floor(ty / 4))
  local block = blocks[(tonumber(blockId) or 0) + 1]
  if not block then return nil end
  return block[(ty % 4) * 4 + (tx % 4) + 1]
end

function ForeignGen1Map:cellTile(cx, cy)
  -- Keep border-extension semantics uncached: out-of-bounds cells intentionally
  -- read def.borderBlock and different outside coordinates can share a simple
  -- row-major key.  Authored in-bounds collision cells are immutable except for
  -- setBlock(), which performs exact 2x2 invalidation above.
  if self._cellTileCache and self:inBounds(cx, cy)
      and cx == math.floor(cx) and cy == math.floor(cy) then
    local key = cy * self.widthCells + cx
    local cached = self._cellTileCache[key]
    if cached ~= nil then return cached ~= false and cached or nil end
    local tile = self:tileAt(cx * 2, cy * 2 + 1)
    self._cellTileCache[key] = tile ~= nil and tile or false
    Twin.kantoCellTileCacheMisses = (Twin.kantoCellTileCacheMisses or 0) + 1
    return tile
  end
  return self:tileAt(cx * 2, cy * 2 + 1)
end

function ForeignGen1Map:inBounds(cx, cy)
  return cx >= 0 and cy >= 0 and cx < self.widthCells and cy < self.heightCells
end

function ForeignGen1Map:isWalkableCell(cx, cy)
  if not self:inBounds(cx, cy) then return false end
  return self.walkable[self:cellTile(cx, cy)] == true
end
ForeignGen1Map.isWalkable = ForeignGen1Map.isWalkableCell

function ForeignGen1Map:isPassableCell(cx, cy, surfing)
  if not self:inBounds(cx, cy) then return false end
  -- Hot movement path: read the cached collision tile once.  The older shape
  -- called isWalkableCell() and then isWaterCell(), which repeated bounds/tile
  -- work for every Surf probe.  Walkability and water membership are immutable
  -- lookup sets for this adapter, so one tile read is exactly equivalent.
  local tile = self:cellTile(cx, cy)
  if self.walkable[tile] == true then return true end
  return surfing == true and self.waterTiles[tile] == true
end

function ForeignGen1Map:isWaterCell(cx, cy)
  -- Match current Gen1Recomp Map:isWaterCell: border-extension is allowed
  -- here. Callers that require a standable destination separately check
  -- inBounds/passability.
  return self.waterTiles[self:cellTile(cx, cy)] == true
end

function ForeignGen1Map:isGrassCell(cx, cy)
  if not self:inBounds(cx, cy) then return false end
  local grass = self.tileset and self.tileset.grassTile
  return grass ~= nil and self:cellTile(cx, cy) == grass
end

function ForeignGen1Map:isDoorTileCell(cx, cy)
  return self.doorTiles[self:cellTile(cx, cy)] == true
end

function ForeignGen1Map:isWarpTileCell(cx, cy)
  local tile = self:cellTile(cx, cy)
  return self.doorTiles[tile] == true or self.warpTiles[tile] == true
end

function ForeignGen1Map:warpPadOrHoleAt(cx, cy)
  local table_ = self.warpPadTiles or WARP_PAD_TILES[self.def.tileset]
  return table_ and table_[self:cellTile(cx, cy)] or nil
end

function ForeignGen1Map:warpAtCell(cx, cy)
  return self._warpAt[cy * self.widthCells + cx]
end

function ForeignGen1Map:warpAt(cx, cy)
  return self:warpAtCell(cx, cy)
end

function ForeignGen1Map:signAtCell(cx, cy)
  return self._signAt[cy * self.widthCells + cx]
end

function ForeignGen1Map:connection(dir)
  return self.def.connections and self.def.connections[dir]
end

function ForeignGen1Map:isOutdoor()
  return mapIsOutdoor(nil, self.def)
end

function ForeignGen1Map:isOutside()
  return mapIsOutside(nil, self.def)
end

function ForeignGen1Map.connectionLanding(destDef, conn, dir, fromCx, fromCy)
  if not (destDef and conn) then return nil end
  local destW, destH = (tonumber(destDef.width) or 0) * 2, (tonumber(destDef.height) or 0) * 2
  local offset = tonumber(conn.offset) or 0
  local x, y
  if dir == "up" then
    x, y = fromCx - offset * 2, destH - 1
  elseif dir == "down" then
    x, y = fromCx - offset * 2, 0
  elseif dir == "left" then
    x, y = destW - 1, fromCy - offset * 2
  else
    x, y = 0, fromCy - offset * 2
  end
  if destW <= 0 or destH <= 0 then return nil end
  -- A connection macro describes only the overlapping strip.  Clamping a
  -- perpendicular coordinate that falls outside that strip invents a route
  -- corner landing (and can strand the player behind collision).  Current
  -- Gen1Recomp fails the crossing instead, after reading the actual neighbour
  -- strip; preserve that exact overlap here.
  if x < 0 or y < 0 or x >= destW or y >= destH then return nil end
  return x, y
end

function ForeignGen1Map:isCounterCell(cx, cy)
  return self.counterTiles[self:cellTile(cx, cy)] == true
end

-- Narrow regression seams: these are underscored and not used by runtime code.
Twin._ForeignGen1Map = ForeignGen1Map
Twin._readVersion = readVersion

local function connectionPlacement(sourceDef, destDef, conn, dir, sourceX, sourceY)
  sourceX, sourceY = sourceX or 0, sourceY or 0
  local offset = tonumber(conn and conn.offset) or 0
  if dir == "north" then
    return sourceX + offset * 32, sourceY - destDef.height * 32
  elseif dir == "south" then
    return sourceX + offset * 32, sourceY + sourceDef.height * 32
  elseif dir == "west" then
    return sourceX - destDef.width * 32, sourceY + offset * 32
  elseif dir == "east" then
    return sourceX + sourceDef.width * 32, sourceY + offset * 32
  end
  return nil, nil
end

local function rectFor(def, ox, oy)
  return {
    x1 = ox, y1 = oy,
    x2 = ox + (tonumber(def and def.width) or 0) * 32,
    y2 = oy + (tonumber(def and def.height) or 0) * 32,
  }
end

local function extendBounds(bounds, rect)
  if not rect then return bounds end
  if not bounds then
    return { x1 = rect.x1, y1 = rect.y1, x2 = rect.x2, y2 = rect.y2 }
  end
  bounds.x1 = math.min(bounds.x1, rect.x1)
  bounds.y1 = math.min(bounds.y1, rect.y1)
  bounds.x2 = math.max(bounds.x2, rect.x2)
  bounds.y2 = math.max(bounds.y2, rect.y2)
  return bounds
end

local OPPOSITE_CONNECTION = {
  north = "south", south = "north", west = "east", east = "west",
}

-- Imported caches can survive engine updates and custom edits. Vanilla Gen-1
-- surface connections are reciprocal and the reverse offset is the negative
-- of the forward offset. Repair only that invariant; never invent arbitrary
-- map placement. This turns stale one-way seams back into traversable Kanto
-- without changing correct vanilla data.
local function repairSurfaceConnections(maps)
  local repaired, warnings = 0, 0
  if type(maps) ~= "table" then return maps, repaired, warnings end
  for sourceId, source in pairs(maps) do
    local connections = source and source.connections
    if type(connections) == "table" then
      for _, dir in ipairs({ "north", "south", "west", "east" }) do
        local conn = connections[dir]
        local destId = conn and (conn.map or conn.mapId)
        local dest = destId and maps[destId]
        if dest then
          dest.connections = dest.connections or {}
          local reverseDir = OPPOSITE_CONNECTION[dir]
          local reverse = dest.connections[reverseDir]
          local expectedOffset = -(tonumber(conn.offset) or 0)
          if not reverse then
            dest.connections[reverseDir] = {
              map = sourceId,
              offset = expectedOffset,
              _stadiumRepaired = true,
            }
            repaired = repaired + 1
          else
            local backId = reverse.map or reverse.mapId
            if backId == sourceId then
              local actual = tonumber(reverse.offset) or 0
              if actual ~= expectedOffset then
                reverse.offset = expectedOffset
                reverse._stadiumRepaired = true
                repaired = repaired + 1
              end
            else
              -- A real conflicting authored edge is not safe to overwrite.
              warnings = warnings + 1
            end
          end
        elseif conn then
          warnings = warnings + 1
        end
      end
    end
  end
  return maps, repaired, warnings
end
Twin._repairSurfaceConnections = repairSurfaceConnections

-- Pure graph solver, intentionally exported for regression tests. It follows
-- Gen-1 surface cardinal connections and uses the same block-offset equations
-- as Gen1Recomp's OverworldController.
function Twin._solveGraph(maps, Map, rootId)
  if type(maps) ~= "table" then return nil, "maps table missing" end
  local root = maps[rootId]
  if not root or not mapIsOutside(Map, root) then
    for id, def in pairs(maps) do
      if mapIsOutside(Map, def) then rootId, root = id, def break end
    end
  end
  if not root then return nil, "Gen-1 cache contains no surface maps" end

  local queue = { { id = rootId, def = root, ox = 0, oy = 0, depth = 0 } }
  local seen = { [rootId] = true }
  local placements = {}
  local qi = 1
  while queue[qi] do
    local cur = queue[qi]
    qi = qi + 1
    placements[#placements + 1] = cur
    for _, dir in ipairs({ "north", "south", "west", "east" }) do
      local conn = cur.def.connections and cur.def.connections[dir]
      local id = conn and (conn.map or conn.mapId)
      local dest = id and maps[id]
      if dest and not seen[id] and mapIsOutside(Map, dest) then
        local ox, oy = connectionPlacement(cur.def, dest, conn, dir, cur.ox, cur.oy)
        if ox and oy then
          seen[id] = true
          queue[#queue + 1] = {
            id = id, def = dest, ox = ox, oy = oy,
            depth = cur.depth + 1, parentId = cur.id, dir = dir,
          }
        end
      end
    end
  end

  local bounds
  for _, rec in ipairs(placements) do bounds = extendBounds(bounds, rectFor(rec.def, rec.ox, rec.oy)) end
  if not bounds then return nil, "Gen-1 surface graph is empty" end

  -- Normalize once. Later Gold re-rooting only translates this whole region;
  -- it never changes the internal Kanto layout.
  for _, rec in ipairs(placements) do
    rec.ox = rec.ox - bounds.x1
    rec.oy = rec.oy - bounds.y1
  end
  bounds.x2, bounds.y2 = bounds.x2 - bounds.x1, bounds.y2 - bounds.y1
  bounds.x1, bounds.y1 = 0, 0
  return { rootId = rootId, placements = placements, bounds = bounds }
end

local function tileSet(list)
  local out = {}
  for _, value in ipairs(list or {}) do out[tonumber(value) or value] = true end
  return out
end

local function decodeCachedAtlas(CacheFs, version, path)
  if type(path) ~= "string" or path == "" then return nil end
  local bytes = readVersion(CacheFs, version, path)
  if not bytes then return nil end
  if not (love and love.data and love.data.newByteData
      and love.image and love.image.newImageData
      and love.graphics and love.graphics.newImage) then return nil end
  local decodedPixels = nil
  local ok, image = pcall(function()
    local encoded = love.data.newByteData(bytes)
    local pixels = love.image.newImageData(encoded)
    local img = love.graphics.newImage(pixels)
    if img.setFilter then img:setFilter("nearest", "nearest") end
    decodedPixels = pixels
    return img
  end)
  if ok and image then
    Twin.atlasLoads = Twin.atlasLoads + 1
    return image, decodedPixels
  end
  return nil, nil
end


local TOWN_PALETTES = {
  PALLET = "PALLET", VIRIDIAN = "VIRIDIAN", PEWTER = "PEWTER",
  CERULEAN = "CERULEAN", VERMILION = "VERMILION", LAVENDER = "LAVENDER",
  CELADON = "CELADON", FUCHSIA = "FUCHSIA", CINNABAR = "CINNABAR",
  SAFFRON = "SAFFRON", INDIGO = "INDIGO",
}

local CAVE_WORDS = {
  "MT_MOON", "ROCK_TUNNEL", "SEAFOAM", "VICTORY_ROAD", "DIGLETTS_CAVE",
  "CERULEAN_CAVE", "POWER_PLANT", "POKEMON_MANSION",
}

local function paletteNameForMap(id, def)
  id = tostring(id or (def and def.id) or "")
  local authored = def and (def.palette or def.sgbPalette or def.cgbPalette)
  if type(authored) == "string" and authored ~= "" then return authored end
  for prefix, pal in pairs(TOWN_PALETTES) do
    if id:find(prefix, 1, true) == 1 then return pal end
  end
  -- Pallet's three famous interiors are not named with a PALLET_ prefix in
  -- the Gen-1 map constants, but Yellow colors them as part of that town's
  -- presentation. Keep them with Pallet rather than the generic route ramp.
  if id:find("REDS_HOUSE", 1, true) == 1
      or id:find("BLUES_HOUSE", 1, true) == 1
      or id == "OAKS_LAB" then
    return "PALLET"
  end
  for _, word in ipairs(CAVE_WORDS) do
    if id:find(word, 1, true) then return "CAVE" end
  end
  if id:find("POKEMON_TOWER", 1, true) then return "LAVENDER" end
  if id:find("ROUTE_", 1, true) == 1 then return "ROUTE" end
  if def and (def.tileset == "CAVERN" or def.tileset == "CEMETERY") then return "CAVE" end
  return "ROUTE"
end

local function yellowPalette(loaded, mapId, def)
  local name = paletteNameForMap(mapId, def)
  local p = loaded and loaded.palettes
  local colors = p and p.cgbBase and p.cgbBase[name]
  if not colors then
    local ok, built = pcall(require, "data.palettes_yellow")
    colors = ok and built and built.cgbBase and built.cgbBase[name] or nil
  end
  if not colors then
    colors = { {255,255,255}, {132,255,33}, {90,189,255}, {25,25,25} }
    name = "ROUTE"
  end
  return colors, name
end

local function releaseImage(image)
  if image and image ~= false and type(image.release) == "function" then
    pcall(image.release, image)
  end
end

local function resetColoredRegion(region)
  if not region then return end
  for _, rec in pairs(region.colorAtlases or {}) do
    if type(rec) == "table" then releaseImage(rec.image) end
  end
  for _, sprite in pairs(region.spriteCache or {}) do
    if type(sprite) == "table" and sprite.def then
      releaseImage(sprite.def._stadiumImage)
    end
  end
  region.colorAtlases = {}
  region.spriteCache = {}
  region.npcCache = {}
  region.npcSpatialCache = {}
  region.pokemonSpatialCache = {}
  region.npcRoleCache = {}
  region.actorGeneration = (tonumber(region.actorGeneration) or 0) + 1
  region.mapsById = {}
  -- v0.3.38 presentation styles are map-specific because native Gold Kanto
  -- can give PALLET_TOWN, ROUTE_1, interiors, etc. their own Gen-2 palette
  -- and tileset donor. Remap/donor pixel caches survive a palette refresh;
  -- only the map/atlas adapters need rebuilding.
  region.gen2StyleMaps = {}
  region.surveyPrepared = 0
  region.surveyCursor = 1
  region.sectorCache = {}
  for _, rec in ipairs(region.records or {}) do rec.map = nil end
end

local function releaseImageData(data)
  if data and data ~= false and type(data.release) == "function" then
    pcall(data.release, data)
  end
end

-- v0.3.31 hard region residency: when Gold is active, Kanto keeps only its
-- lightweight imported tables/graph and persistent gameplay state. GPU images,
-- decoded ImageData, map adapters and actor presentation caches are discarded.
-- Re-entering Kanto rebuilds only the current/prefetched sector, so Johto and
-- Kanto no longer accumulate render residency in the same session.
local function unloadKantoRenderData(region)
  if not region then return false end
  if ChunkMesher and type(ChunkMesher.cancelWarmRegion) == "function" then
    pcall(ChunkMesher.cancelWarmRegion, "kanto")
  end
  region.diskWarmSeen = {}
  region.diskWarmCursor = 1
  resetColoredRegion(region)
  for _, data in pairs(region.rawAtlasPixels or {}) do releaseImageData(data) end
  for _, data in pairs(region.spritePixels or {}) do releaseImageData(data) end
  region.rawAtlasPixels = {}
  region.spritePixels = {}
  region.pokemonCache = {}
  region.npcSpatialCache = {}
  region.pokemonSpatialCache = {}
  region.npcRoleCache = {}
  region.actorGeneration = (tonumber(region.actorGeneration) or 0) + 1
  region.johtoTextureRemaps = {}
  region.johtoTexturePixels = nil
  region.johtoTextureTileset = nil
  region.johtoTextureKey = nil
  region.gen2StyleMaps = {}
  region.gen2RemapCache = {}
  region.gen2DonorCache = {}
  region.paletteCheckAt = nil
  Twin.kantoRegionUnloads = (Twin.kantoRegionUnloads or 0) + 1
  return true
end

Twin._unloadKantoRenderData = unloadKantoRenderData

local function johtoPaletteReference(world)
  if not world then return nil end
  -- Prefer a canonical Johto outdoor map so Kanto does not accidentally take
  -- its material family from whichever hidden Gold map the player happened to
  -- leave underneath (including Gold's native Kanto or an interior).
  local maps = world.maps
  local defs = type(maps) == "table" and maps or nil
  local preferred = { "NEW_BARK_TOWN", "CHERRYGROVE_CITY", "ROUTE_29" }
  local function wrap(def, id)
    if type(def) ~= "table" then return nil end
    local tilesetId = def.tileset
    if tilesetId ~= "TILESET_JOHTO" and tilesetId ~= "TilesetJohto" then return nil end
    local ts = type(world.tilesets) == "table" and world.tilesets[tilesetId] or nil
    return { id = id or def.id, def = def, tileset = ts or {} }
  end
  if defs then
    for _, id in ipairs(preferred) do
      local ref = wrap(defs[id], id)
      if ref then return ref end
    end
    for id, def in pairs(defs) do
      local ref = wrap(def, id)
      if ref then return ref end
    end
  end
  local current = world.map
  if current and current.def then return current end
  return nil
end

Twin._johtoPaletteReference = johtoPaletteReference

local function johtoTextureTileset(world)
  if not world then return nil end
  local pools = {
    world.tilesets,
    world.game and world.game.data and world.game.data.gen2Tilesets,
    world.game and world.game.data and world.game.data.tilesets,
  }
  for _, pool in ipairs(pools) do
    if type(pool) == "table" then
      for _, id in ipairs({ "TILESET_JOHTO", "TilesetJohto" }) do
        if type(pool[id]) == "table" then return pool[id], id end
      end
    end
  end
  local current = world.map and world.map.tileset
  local id = current and (current._stadiumEngineTilesetId or current.id)
  if id == "TILESET_JOHTO" or id == "TilesetJohto" then return current, id end
  return nil
end

local function syncJohtoTextureDonor(region, world)
  if not region then return false end
  local ts, id = johtoTextureTileset(world)
  local image = ts and ts.image
  if not (ts and type(image) == "string" and image ~= "") then
    region.johtoTexturePixels, region.johtoTextureTileset = nil, nil
    region.johtoTextureKey = nil
    return false
  end
  local key = tostring(id or ts.id or "JOHTO") .. "|" .. image
  if region.johtoTextureKey == key and region.johtoTexturePixels then return false end
  local ok, pixels = pcall(Assets.imageData, image)
  if not (ok and pixels and type(pixels.getPixel) == "function") then
    region.johtoTexturePixels, region.johtoTextureTileset = nil, nil
    region.johtoTextureKey = nil
    return false
  end
  local changed = region.johtoTextureKey ~= key or region.johtoTexturePixels ~= pixels
  region.johtoTexturePixels = pixels
  region.johtoTextureTileset = ts
  region.johtoTextureKey = key
  region.johtoTextureRemaps = {}
  return changed
end

-- v0.3.30: the Yellow-derived region now follows the ACTIVE GOLD/JOHTO
-- palette-material family.  The imported Yellow atlas remains the geometric
-- source -- copying Johto tile ids would corrupt Kanto buildings/collision --
-- but each semantic surface (water, grass, ground, doors, structures) is baked
-- through the exact eight-slot Gold profile used by the Johto map underneath.
-- That gives Kanto the same day/night/color-mode material treatment while
-- preserving its towns, landmarks and collision vocabulary.
local function syncGoldPalette(region, world)
  if not (region and world and world.map) then return false end
  -- Building a Gold palette profile walks the Johto PalMap. Doing that at
  -- presentation FPS was wasted work: the meaningful inputs (time-of-day /
  -- display color mode) change slowly. Keep Kanto responsive to option changes
  -- while reducing the steady-state profile work to four checks per second.
  local t = now()
  if t > 0 and region.goldPaletteKey and region.paletteCheckAt
      and t - region.paletteCheckAt < 0.25 then
    return true
  end
  region.paletteCheckAt = t > 0 and t or nil
  local okColor, GoldColorAtlas = pcall(V.require, "GoldColorAtlas")
  if not okColor or type(GoldColorAtlas) ~= "table" then return false end

  local paletteMap = johtoPaletteReference(world) or world.map

  -- v0.3.59: most checks find that nothing about Gold's visible material
  -- family changed. Compare the cheap inputs first so the expensive
  -- worldPaletteProfile PalMap scans/key serialization only run at an actual
  -- daypart/color-mode/palette-set change.
  if type(GoldColorAtlas.worldPaletteInputs) == "function" then
    local okInputs, daytime, mode, setRef, palMapRef =
      pcall(GoldColorAtlas.worldPaletteInputs, world, paletteMap)
    if okInputs and setRef ~= nil then
      if region.goldPaletteInputsReady
          and region.goldPaletteInputDaytime == daytime
          and region.goldPaletteInputMode == mode
          and region.goldPaletteInputSet == setRef
          and region.goldPaletteInputPalMap == palMapRef then
        return true
      end
      region.goldPaletteInputsReady = true
      region.goldPaletteInputDaytime = daytime
      region.goldPaletteInputMode = mode
      region.goldPaletteInputSet = setRef
      region.goldPaletteInputPalMap = palMapRef
    end
  end

  local profile, key
  if type(GoldColorAtlas.worldPaletteProfile) == "function" then
    local okProfile, got, gotKey = pcall(GoldColorAtlas.worldPaletteProfile,
      world, paletteMap)
    if okProfile and type(got) == "table" and gotKey then
      profile, key = got, tostring(gotKey)
    end
  end

  local colors
  if profile and type(profile.slots) == "table" then
    colors = profile.slots[profile.default or 1] or profile.slots[1]
  elseif type(GoldColorAtlas.worldRamp) == "function" then
    local okRamp, got, gotKey = pcall(GoldColorAtlas.worldRamp, world, paletteMap)
    if okRamp and type(got) == "table" and gotKey then
      colors, key = got, tostring(gotKey)
    end
  end
  if type(colors) ~= "table" or not key then return false end
  -- v0.3.38: this canonical Johto profile is now only the COLOR/TIME invalidation
  -- clock and the fallback palette. Individual Yellow Kanto maps resolve a
  -- native Gen-2 donor in KantoGen2Style (same Gold map id first, then
  -- TILESET_KANTO / matching Gen-2 interior / Johto fallback).
  region.goldWorld = world
  if region.goldPaletteKey == key and region.goldColors then return true end

  region.goldPaletteProfile = profile and deepCopy(profile) or nil
  region.goldColors = deepCopy(colors)
  local ref = johtoPaletteReference(world)
  region.goldPaletteReference = ref and (ref.id or (ref.def and ref.def.id)) or nil
  region.goldPaletteKey = key
  resetColoredRegion(region)
  Twin.kantoPalette = profile and "gen2-native-per-map" or "gold-synced-ramp"
  Twin.kantoTextureStyle = profile and "gen2-native-projected-tiles" or "gold-ramp-materials"
  Twin.kantoPaletteSyncs = (Twin.kantoPaletteSyncs or 0) + 1
  return true
end

local function activeKantoPalette(region, mapId, def)
  if region and type(region.goldColors) == "table" then
    return region.goldColors, "GOLD_SYNC_" .. tostring(region.goldPaletteKey or "active")
  end
  return yellowPalette(region and region.loaded, mapId, def)
end

local function activeKantoProfile(region)
  local profile = region and region.goldPaletteProfile
  if type(profile) == "table" and type(profile.slots) == "table" then
    return profile
  end
  return nil
end

Twin._syncGoldPalette = syncGoldPalette
Twin._activeKantoPalette = activeKantoPalette

local function shadeColor(colors, r)
  local c = r > 0.83 and colors[1] or r > 0.50 and colors[2]
    or r > 0.17 and colors[3] or colors[4]
  return (c[1] or 0) / 255, (c[2] or 0) / 255, (c[3] or 0) / 255
end

local function colorizeAtlasPixels(src, colors)
  if not (src and love and love.image and love.image.newImageData) then return nil end
  local w, h = src:getDimensions()
  local out = love.image.newImageData(w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r, g, b, a = src:getPixel(x, y)
      local cr, cg, cb = shadeColor(colors, r)
      out:setPixel(x, y, cr, cg, cb, a)
    end
  end
  return out
end

local function profileSlotForTile(profile, semantic, tile)
  if not profile then return nil end
  if semantic.water[tile] then return profile.water or profile.default end
  if semantic.shore[tile] then return profile.shore or profile.water or profile.default end
  if semantic.grassTile == tile then return profile.grass or profile.ground or profile.default end
  if semantic.doors[tile] or semantic.warps[tile] then
    return profile.door or profile.structure or profile.default
  end
  if semantic.walk[tile] then return profile.ground or profile.default end
  return profile.structure or profile.default
end

local function semanticForTileset(ts)
  return {
    water = tileSet(ts and ts.waterTiles),
    shore = tileSet(ts and ts.shoreTiles),
    walk = tileSet(ts and ts.walkable),
    doors = tileSet(ts and ts.doorTiles),
    warps = tileSet(ts and ts.warpTiles),
    grassTile = tonumber(ts and ts.grassTile),
  }
end

local function textureCategory(semantic, tile)
  if semantic.grassTile == tile then return "grass" end
  if semantic.water[tile] then return "water" end
  if semantic.shore[tile] then return "shore" end
  if semantic.doors[tile] or semantic.warps[tile] then return "door" end
  if semantic.walk[tile] then return "ground" end
  return "structure"
end

local function tilesetPaletteSlot(ts, tile)
  local pal = ts and ts.tilePalettes
  if type(pal) ~= "table" then return nil end
  local slot = tonumber(pal[(tonumber(tile) or 0) + 1])
  if slot == nil then return nil end
  -- Gen2 generated PalMaps are 1..8 in Lua; tolerate raw 0..7 tables too.
  if slot >= 1 and slot <= 8 then return math.floor(slot) end
  if slot >= 0 and slot <= 7 then return math.floor(slot) + 1 end
  return nil
end

Twin._tilesetPaletteSlot = tilesetPaletteSlot

local function atlasTileCount(data)
  if not (data and type(data.getDimensions) == "function") then return 0 end
  local w, h = data:getDimensions()
  return math.floor(w / 8) * math.floor(h / 8)
end

local function tileMse(a, aPerRow, at, b, bPerRow, bt)
  local ax, ay = (at % aPerRow) * 8, math.floor(at / aPerRow) * 8
  local bx, by = (bt % bPerRow) * 8, math.floor(bt / bPerRow) * 8
  local sum = 0
  for py = 0, 7 do
    for px = 0, 7 do
      local ar = select(1, a:getPixel(ax + px, ay + py)) or 0
      local br = select(1, b:getPixel(bx + px, by + py)) or 0
      local d = ar - br
      sum = sum + d * d
    end
  end
  return sum / 64
end

local TEXTURE_MATCH_THRESHOLD = {
  water = 0.16, shore = 0.16, grass = 0.16,
  ground = 0.10, door = 0.055, structure = 0.028,
}

local function johtoTextureRemap(region, src, sourceTs)
  local donor, donorTs = region and region.johtoTexturePixels,
    region and region.johtoTextureTileset
  if not (donor and donorTs and src) then return nil end
  region.johtoTextureRemaps = region.johtoTextureRemaps or {}
  local sourceId = tostring(sourceTs and sourceTs.id or sourceTs and sourceTs.image or "source")
  local key = sourceId .. "|" .. tostring(region.johtoTextureKey or "johto")
  local cached = region.johtoTextureRemaps[key]
  if cached then return cached end

  local sourcePer = tonumber(sourceTs and sourceTs.tilesPerRow) or 16
  local donorPer = tonumber(donorTs and donorTs.tilesPerRow) or 16
  local sourceSem, donorSem = semanticForTileset(sourceTs), semanticForTileset(donorTs)
  local donorByCategory = { water={}, shore={}, grass={}, ground={}, door={}, structure={} }
  for t = 0, atlasTileCount(donor) - 1 do
    local cat = textureCategory(donorSem, t)
    donorByCategory[cat][#donorByCategory[cat] + 1] = t
  end
  -- A Johto cache may not expose shoreTiles separately. Water is the safe
  -- texture donor for shoreline cells; ground is the safe fallback for grass.
  if #donorByCategory.shore == 0 then donorByCategory.shore = donorByCategory.water end
  if #donorByCategory.grass == 0 then donorByCategory.grass = donorByCategory.ground end

  local remap, matches = {}, 0
  for t = 0, atlasTileCount(src) - 1 do
    local cat = textureCategory(sourceSem, t)
    local candidates = donorByCategory[cat]
    if candidates and #candidates > 0 then
      local best, bestErr = nil, math.huge
      for _, dt in ipairs(candidates) do
        local err = tileMse(src, sourcePer, t, donor, donorPer, dt)
        if err < bestErr then best, bestErr = dt, err end
      end
      if best and bestErr <= (TEXTURE_MATCH_THRESHOLD[cat] or 0.03) then
        remap[t] = best
        matches = matches + 1
      end
    end
  end
  region.johtoTextureRemaps[key] = remap
  Twin.kantoTextureMatches = (Twin.kantoTextureMatches or 0) + matches
  return remap
end

Twin._johtoTextureRemap = johtoTextureRemap

local function colorizeAtlasPixelsProfile(src, profile, ts, region)
  if not (src and profile and love and love.image and love.image.newImageData) then return nil end
  local w, h = src:getDimensions()
  local out = love.image.newImageData(w, h)
  local perRow = math.max(1, math.floor(w / 8))
  local cache = {}
  local semantic = semanticForTileset(ts)
  local textureRemap = johtoTextureRemap(region, src, ts)
  local donor = region and region.johtoTexturePixels
  local donorTs = region and region.johtoTextureTileset
  local donorPerRow = tonumber(donorTs and donorTs.tilesPerRow) or 16
  for y = 0, h - 1 do
    local ty = math.floor(y / 8)
    for x = 0, w - 1 do
      local tile = ty * perRow + math.floor(x / 8)
      local donorTile = textureRemap and textureRemap[tile]
      -- If the pattern matcher found an actual Johto donor tile, use that
      -- donor tile's OWN PalMap slot as well as its pixels. This closes the
      -- v0.3.30 color mismatch where a Johto-looking tile was still shaded by
      -- Kanto's broad semantic ground/water/structure slot. Unique Kanto art
      -- still falls back to the conservative semantic mapping below.
      local slot = donorTile and tilesetPaletteSlot(donorTs, donorTile)
        or profileSlotForTile(profile, semantic, tile) or 1
      local colors = cache[slot]
      if colors == nil then
        colors = profile.slots and (profile.slots[slot] or profile.slots[profile.default or 1]) or false
        cache[slot] = colors or false
      end
      local r, g, b, a = src:getPixel(x, y)
      if donorTile and donor then
        local lx, ly = x % 8, y % 8
        local dx = (donorTile % donorPerRow) * 8 + lx
        local dy = math.floor(donorTile / donorPerRow) * 8 + ly
        local dr, dg, db = donor:getPixel(dx, dy)
        r, g, b = dr or r, dg or g, db or b
        if lx == 0 and ly == 0 then
          Twin.kantoPaletteExactTiles = (Twin.kantoPaletteExactTiles or 0) + 1
        end
      end
      if colors then
        local cr, cg, cb = shadeColor(colors, r)
        r, g, b = cr, cg, cb
      end
      out:setPixel(x, y, r, g, b, a)
    end
  end
  return out
end

-- Yellow overworld sprites pass through OBP0=$D0 before the map's CGBBase
-- palette colors them.  Reproduce that tiny shade remap here because these
-- inactive-cache images never enter Yellow's normal SpriteRenderer pipeline.
local function colorizeObjPixels(src, colors)
  if not (src and love and love.image and love.image.newImageData) then return nil end
  local w, h = src:getDimensions()
  local out = love.image.newImageData(w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r, g, b, a = src:getPixel(x, y)
      if a <= 0 then
        out:setPixel(x, y, 0, 0, 0, 0)
      else
        local c
        if r > 0.83 then c = colors[1]
        elseif r > 0.50 then c = colors[1]
        elseif r > 0.17 then c = colors[2]
        else c = colors[4] end
        out:setPixel(x, y, (c[1] or 0)/255, (c[2] or 0)/255, (c[3] or 0)/255, a)
      end
    end
  end
  return out
end

local function imageFromPixels(pixels)
  if not (pixels and love and love.graphics and love.graphics.newImage) then return nil end
  local ok, image = pcall(love.graphics.newImage, pixels)
  if ok and image then
    if image.setFilter then image:setFilter("nearest", "nearest") end
    return image
  end
  return nil
end

Twin._paletteNameForMap = paletteNameForMap
Twin._yellowPalette = yellowPalette

-- Last-resort atlas when encoded-image-from-ByteData is unavailable on a host.
-- The map/block layout remains authentic; colors are semantic so water, grass,
-- paths and solids stay legible instead of making the foreign region disappear.
local function semanticAtlas(ts)
  if not (love and love.image and love.image.newImageData
      and love.graphics and love.graphics.newImage) then return nil end
  local maxTile = 0
  for _, block in ipairs(ts.blocks or {}) do
    for _, t in ipairs(block or {}) do maxTile = math.max(maxTile, tonumber(t) or 0) end
  end
  maxTile = math.max(maxTile, 127)
  local perRow = tonumber(ts.tilesPerRow) or 16
  local rows = math.ceil((maxTile + 1) / perRow)
  local water = tileSet(ts.waterTiles or { 0x14 })
  local shore = tileSet(ts.shoreTiles or { 0x32, 0x48 })
  local walk = tileSet(ts.walkable)
  local doors = tileSet(ts.doorTiles)
  local warps = tileSet(ts.warpTiles)
  local grass = tonumber(ts.grassTile)
  local builtPixels = nil
  local ok, image = pcall(function()
    local data = love.image.newImageData(perRow * 8, rows * 8)
    for t = 0, maxTile do
      local r, g, b = 0.20, 0.30, 0.19
      if water[t] then r, g, b = 0.15, 0.43, 0.72
      elseif shore[t] then r, g, b = 0.33, 0.62, 0.78
      elseif t == grass then r, g, b = 0.30, 0.58, 0.27
      elseif doors[t] or warps[t] then r, g, b = 0.62, 0.42, 0.19
      elseif walk[t] then r, g, b = 0.57, 0.62, 0.37 end
      local ox, oy = (t % perRow) * 8, math.floor(t / perRow) * 8
      local wobble = ((t * 37) % 9 - 4) * 0.009
      for y = 0, 7 do
        for x = 0, 7 do
          local p = ((x + y + t) % 4 == 0) and 0.035 or 0
          data:setPixel(ox + x, oy + y,
            math.max(0, math.min(1, r + wobble + p)),
            math.max(0, math.min(1, g + wobble + p)),
            math.max(0, math.min(1, b + wobble + p)), 1)
        end
      end
    end
    local img = love.graphics.newImage(data)
    if img.setFilter then img:setFilter("nearest", "nearest") end
    builtPixels = data
    return img
  end)
  if ok and image then
    Twin.atlasFallbacks = Twin.atlasFallbacks + 1
    return image, builtPixels
  end
  return nil, nil
end

local function cloneConnections(def, valid)
  local out = deepCopy(def.connections or {})
  for _, conn in pairs(out) do
    if type(conn) == "table" then
      local id = conn.map or conn.mapId
      if id and valid[id] then
        conn.map = Twin.PREFIX .. id
        conn.mapId = Twin.PREFIX .. id
      end
    end
  end
  return out
end

local function sourceAtlasPixels(region, tilesetId, sourceTs)
  local hit = region.rawAtlasPixels[tilesetId]
  if hit ~= nil then return hit or nil end
  local _, pixels = decodeCachedAtlas(region.loaded.CacheFs, region.version, sourceTs.image)
  region.rawAtlasPixels[tilesetId] = pixels or false
  return pixels
end

local function atlasForMap(region, mapId, sourceDef, sourceTs)
  local raw = sourceAtlasPixels(region, sourceDef.tileset, sourceTs)
  local style = raw and KantoGen2Style.forMap(region, region.goldWorld, mapId,
    sourceDef, sourceTs, raw, region.validOutdoor and region.validOutdoor[mapId] == true) or nil

  local colors, paletteName = activeKantoPalette(region, mapId, sourceDef)
  if style then
    paletteName = "GEN2_" .. tostring(style.donorRef and style.donorRef.id or style.donorProfileId)
      .. "_" .. tostring(style.paletteKey or "active")
    Twin.kantoTextureMatches = math.max(Twin.kantoTextureMatches or 0,
      tonumber(style.matches) or 0)
    Twin.kantoPaletteExactTiles = math.max(Twin.kantoPaletteExactTiles or 0,
      tonumber(style.matches) or 0)
    region.lastGen2Donor = style.donorKey
    region.lastGen2DonorMap = style.donorRef and style.donorRef.id or nil
    region.lastGen2DonorProfile = style.donorProfileId
    region.lastGen2ColorDonor = style.colorDonorKey
    region.lastGen2ColorDonorMap = style.colorDonorRef and style.colorDonorRef.id or nil
  end
  local key = tostring(sourceDef.tileset) .. "|" .. tostring(style and style.key or paletteName)
  local cached = region.colorAtlases[key]
  if cached then return cached.image, cached.pixels, cached.raw, paletteName, cached.style end

  local profile = activeKantoProfile(region)
  local pixels
  if raw and style then
    pixels = KantoGen2Style.colorize(raw, sourceTs, style)
  elseif raw then
    pixels = profile and colorizeAtlasPixelsProfile(raw, profile, sourceTs, region)
      or colorizeAtlasPixels(raw, colors)
  end
  local image = pixels and imageFromPixels(pixels) or nil
  if not image then
    local tsFallback = deepCopy(sourceTs)
    image, pixels = semanticAtlas(tsFallback)
    raw = raw or pixels
  end
  if not image then return nil, nil, raw, paletteName, style end
  region.colorAtlases[key] = { image = image, pixels = pixels, raw = raw,
    palette = paletteName, style = style }
  return image, pixels, raw, paletteName, style
end

local function ensureForeignMap(region, sourceId)
  if not (region and sourceId) then return nil end
  local hit = region.mapsById[sourceId]
  if hit ~= nil then return hit or nil end
  local sourceDef = region.loaded.maps[sourceId]
  if not sourceDef then region.mapsById[sourceId] = false; return nil end
  local sourceTs = region.loaded.tilesets[sourceDef.tileset]
  if not sourceTs then region.mapsById[sourceId] = false; return nil end

  local atlas, _, rawPixels, paletteName, gen2Style =
    atlasForMap(region, sourceId, sourceDef, sourceTs)
  if not atlas then region.mapsById[sourceId] = false; return nil end
  local ts = deepCopy(sourceTs)
  local sourceProfileId = ts.id or sourceDef.tileset
  if gen2Style then
    ts.id = KantoGen2Style.installSyntheticProfile(sourceProfileId, gen2Style)
    ts._stadiumGen2DonorId = gen2Style.donorProfileId
    ts._stadiumGen2DonorMap = gen2Style.donorRef and gen2Style.donorRef.id or nil
    ts._stadiumGen2Projection = true
    ts._stadiumProjectionRevision = KantoGen2Style.PROJECTION_REV
  else
    ts.id = sourceProfileId
  end
  ts.animation = nil
  ts.animatedTiles = {}
  ts.trueColor = true
  ts._stadiumPixelData = rawPixels
  ts.image = ("__stadium_yellow_cache/%s/%s/%s.png")
    :format(region.version, tostring(sourceDef.tileset):lower(), tostring(paletteName):lower():gsub("[^%w_%-]", "_"))

  local def = deepCopy(sourceDef)
  if region.validOutdoor[sourceId] then
    def.connections = cloneConnections(sourceDef, region.validOutdoor)
    -- Gold's voxel renderer asks the live Gen-2 Map alias whether the current
    -- map is outdoors before it enables sky/day-night/weather.  A Yellow map
    -- has no Gen-2 `environment` byte, so stamp the generation-neutral
    -- `outdoor` override the alias honors instead of letting Kanto look like
    -- an indoor black/flat scene.
    def.outdoor = true
  else
    def.outdoor = false
  end
  def.sourceId = sourceDef.id or sourceId
  def.id = Twin.PREFIX .. sourceId
  -- Reapply Kanto Cut mutations before the adapter/mesher sees the map so the
  -- persistent sector-cache signature includes the changed block layout.
  local cutState = KantoState.table(KantoState.CUT_BLOCKS_KEY)
  local perMapCuts = cutState[sourceId]
  if type(perMapCuts) == "table" then
    for key, blockId in pairs(perMapCuts) do
      local bx, by = tostring(key):match("^(-?%d+),(-?%d+)$")
      bx, by = tonumber(bx), tonumber(by)
      if bx and by and bx >= 0 and by >= 0 and bx < (tonumber(def.width) or 0)
          and by < (tonumber(def.height) or 0) and tonumber(blockId) then
        def.blocks[by * def.width + bx + 1] = math.floor(tonumber(blockId))
      end
    end
  end
  -- Retail map scripts stamp physical Kanto door state on load.  Story-free
  -- Kanto does the same directly from extracted/fallback field data without
  -- running the Yellow VM.
  KantoState.applyPhysicalBlocks(region, sourceId, def)
  local ok, map = pcall(ForeignGen1Map.new, def, ts)
  if not ok or type(map) ~= "table" then
    region.mapsById[sourceId] = false
    return nil
  end
  map.id = Twin.PREFIX .. sourceId
  map.sourceId = sourceId
  map.renderer = { image = atlas, gbcAtlas = false }
  map._stadiumSourceId = sourceId
  map._stadiumPaletteName = paletteName
  map._stadiumGen2DonorId = gen2Style and gen2Style.donorProfileId or nil
  map._stadiumGen2DonorMap = gen2Style and gen2Style.donorRef and gen2Style.donorRef.id or nil
  map._stadiumGen2TextureMatches = gen2Style and gen2Style.matches or 0
  -- Keep the SOURCE-tile material classification beside the private map.
  -- Entry validation uses this to refuse a cell whose Yellow collision says
  -- walkable but whose authored/projected tile is actually a tree/roof/prop.
  map._stadiumGen2SourceCategories = gen2Style and gen2Style.categories or nil
  map._stadiumGen2Remap = gen2Style and gen2Style.remap or nil
  map._stadiumProjectionRevision = gen2Style and KantoGen2Style.PROJECTION_REV or nil
  region.mapsById[sourceId] = map
  return map
end

function KantoState.buildFieldIndex(field)
  field = type(field) == "table" and field or {}
  local fieldIndex = {
    tilePairs = { land = {}, water = {} },
    bikeMaps = {}, bikeTilesets = {}, darkMaps = {}, slopeMaps = {},
    clearForcedBikeMaps = {}, forcedBikeTiles = {},
    spinners = {}, badgeGates = {}, ledges = {},
    warpCarpets = nil,
  }
  for _, mode in ipairs({ "land", "water" }) do
    for _, row in ipairs(field.tilePairs and field.tilePairs[mode] or {}) do
      local ts, a, b = tostring(row.tileset or ""), tonumber(row.a), tonumber(row.b)
      if ts ~= "" and a and b then
        fieldIndex.tilePairs[mode][ts] = fieldIndex.tilePairs[mode][ts] or {}
        local lo, hi = math.min(a, b), math.max(a, b)
        fieldIndex.tilePairs[mode][ts][lo * 256 + hi] = true
      end
    end
  end
  local bike = field.bikeRiding or {
    tilesets = { "OVERWORLD", "FOREST", "UNDERGROUND", "SHIP_PORT", "CAVERN" },
    maps = { "ROUTE_23", "INDIGO_PLATEAU" },
  }
  for _, id in ipairs(bike.maps or {}) do fieldIndex.bikeMaps[tostring(id)] = true end
  for _, id in ipairs(bike.tilesets or {}) do fieldIndex.bikeTilesets[tostring(id)] = true end
  for _, id in ipairs(field.darkMaps and field.darkMaps.maps or {}) do
    fieldIndex.darkMaps[tostring(id)] = true
  end
  local forced = field.forcedMovement or {}
  for _, id in ipairs(forced.slopeMaps or {}) do fieldIndex.slopeMaps[tostring(id)] = true end
  for _, id in ipairs(forced.clearMaps or {}) do fieldIndex.clearForcedBikeMaps[tostring(id)] = true end
  for mapId, rows in pairs(forced.tiles or {}) do
    local perMap = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
      if row.mode == "bike" and tonumber(row.x) and tonumber(row.y) then
        perMap[math.floor(tonumber(row.y)) * 1024 + math.floor(tonumber(row.x))] = row
      end
    end
    fieldIndex.forcedBikeTiles[tostring(mapId)] = perMap
  end
  -- Spinner cells are exact coordinates, so a single integer-key lookup can
  -- replace the authored-list scan on every landing.
  for mapId, rows in pairs(field.spinners or {}) do
    local perMap = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
      local x, y = tonumber(row.x), tonumber(row.y)
      if x and y then perMap[math.floor(y) * 1024 + math.floor(x)] = row end
    end
    fieldIndex.spinners[tostring(mapId)] = perMap
  end
  -- Ledge rules are immutable and are tested whenever the continuous body
  -- presses into a ledge collision. Index by tileset/facing/source+front tile
  -- so a held direction does not rescan every authored ledge row each frame.
  for _, row in ipairs(field.ledges or {}) do
    local tileset = tostring(row.tileset or "OVERWORLD")
    local dir = tostring(row.facing or "")
    local standing, front = tonumber(row.standingTile), tonumber(row.ledgeTile)
    if dir ~= "" and standing and front then
      local perTileset = fieldIndex.ledges[tileset]
      if not perTileset then perTileset = {}; fieldIndex.ledges[tileset] = perTileset end
      local perDir = perTileset[dir]
      if not perDir then perDir = {}; perTileset[dir] = perDir end
      perDir[math.floor(standing) * 256 + math.floor(front)] = row
    end
  end

  -- ExtraWarpCheck carpet metadata is also static. Newer Yellow caches carry
  -- these lists; flatten them once so collision/door checks are all O(1).
  local carpets = field.warpCarpets
  if type(carpets) == "table" then
    local idx = {
      edgeMaps = {}, function2Maps = {}, function2Tilesets = {},
      tiles = { up = {}, down = {}, left = {}, right = {} },
      ssAnneBow = carpets.ssAnneBow,
    }
    for _, id in ipairs(carpets.edgeMaps or {}) do idx.edgeMaps[tostring(id)] = true end
    for _, id in ipairs(carpets.function2Maps or {}) do idx.function2Maps[tostring(id)] = true end
    for _, id in ipairs(carpets.function2Tilesets or {}) do
      idx.function2Tilesets[tostring(id)] = true
    end
    for dir, rows in pairs(carpets.tiles or {}) do
      local out = idx.tiles[dir] or {}
      idx.tiles[dir] = out
      for _, tile in ipairs(rows or {}) do
        local n = tonumber(tile)
        if n then out[math.floor(n)] = true end
      end
    end
    fieldIndex.warpCarpets = idx
  end

  -- Badge gates are also immutable. Route 22 uses exact checkpoint cells;
  -- Route 23 uses northbound guard rows with an optional max-X span.
  for mapId, def in pairs(field.badgeGates or {}) do
    if type(def) == "table" then
      local idx = { coords = {}, upRows = {} }
      for _, c in ipairs(def.coords or {}) do
        local x, y = tonumber(c.x), tonumber(c.y)
        if x and y then
          idx.coords[math.floor(y) * 1024 + math.floor(x)] = {
            badge = def.badge, failText = def.failText,
          }
        end
      end
      for _, g in ipairs(def.guards or {}) do
        local y = tonumber(g.y)
        if y then idx.upRows[math.floor(y)] = {
          badge = g.badge, maxX = tonumber(g.maxX), failText = def.failText,
        } end
      end
      fieldIndex.badgeGates[tostring(mapId)] = idx
    end
  end
  return fieldIndex
end
Twin._buildKantoFieldIndex = KantoState.buildFieldIndex

local function buildRegion()
  local loaded, err = loadGeneratedTables()
  if not loaded then return nil, err end

  -- Work on a private copy: the imported Yellow cache remains immutable.
  loaded.maps = deepCopy(loaded.maps)
  local repaired, warnings
  loaded.maps, repaired, warnings = repairSurfaceConnections(loaded.maps)
  Twin.kantoConnectionRepairs = repaired or 0
  Twin.kantoConnectionWarnings = warnings or 0

  local solved, solveErr = Twin._solveGraph(loaded.maps, ForeignGen1Map, "PALLET_TOWN")
  if not solved then return nil, solveErr end

  local validOutdoor = {}
  for _, rec in ipairs(solved.placements) do validOutdoor[rec.id] = true end

  -- Hot field rules are immutable for the lifetime of an imported cache. Build
  -- compact lookup sets once per Kanto region instead of rescanning authored
  -- arrays on every movement/frame. The original tables remain authoritative.
  local field = loaded.field or {}
  local fieldIndex = KantoState.buildFieldIndex(field)
  Twin.kantoFieldIndexBuilds = (Twin.kantoFieldIndexBuilds or 0) + 1

  local region = {
    version = loaded.version,
    loaded = loaded,
    records = {},
    recordBySource = {},
    mapsById = {},
    bounds = solved.bounds,
    rootId = solved.rootId,
    validOutdoor = validOutdoor,
    rawAtlasPixels = {},
    colorAtlases = {},
    spritePixels = {},
    spriteCache = {},
    npcCache = {},
    pokemonCache = {},
    npcSpatialCache = {},
    pokemonSpatialCache = {},
    npcRoleCache = {},
    actorGeneration = 0,
    sectorCache = {},
    fieldIndex = fieldIndex,
  }

  -- Keep the graph/layout cheap.  Actual Yellow tile atlases are prepared
  -- lazily in small batches instead of decoding every Kanto map on the frame
  -- the toggle is switched on.  This removes the largest v0.2.85 hitch while
  -- preserving the complete survey graph; every record eventually becomes a
  -- normal ForeignGen1Map as background budget allows.
  for _, rec in ipairs(solved.placements) do
    local built = {
      sourceId = rec.id, id = Twin.PREFIX .. rec.id, map = nil,
      ox = rec.ox, oy = rec.oy, depth = rec.depth,
    }
    region.records[#region.records + 1] = built
    region.recordBySource[rec.id] = built
  end
  region.surveyCursor = 1
  region.surveyPrepared = 0

  if #region.records == 0 then
    return nil, "Pokemon Yellow outdoor maps could not be rendered"
  end
  Twin.regionBuilds = Twin.regionBuilds + 1
  Twin.cacheVersion = loaded.version
  Twin.regionMaps = #region.records
  local Dialogue = V.require("KantoDialogue")
  if Dialogue and type(Dialogue.audit) == "function" then
    local okAudit, audit = pcall(Dialogue.audit, region)
    if okAudit then Twin.kantoDialogueAudit = audit end
  end
  return region
end

Twin._ensureForeignMap = ensureForeignMap

local function ensureRegion()
  if regionCache then return regionCache end
  local t = now()
  if t - regionAttemptAt < RETRY_SECONDS then return nil, Twin.lastError end
  regionAttemptAt = t
  local region, err = buildRegion()
  if region then
    regionCache = region
    Twin.lastError = nil
    return region
  end
  Twin.lastError = tostring(err)
  return nil, Twin.lastError
end

-- Bounds in the current Gold map's world coordinate system. `neighbors` may
-- already include foreign maps; callers choose which set they pass.
function Twin._worldBounds(rootMap, neighbors)
  if not (rootMap and rootMap.def) then return nil end
  local bounds = rectFor(rootMap.def, 0, 0)
  for _, nb in ipairs(neighbors or {}) do
    if nb.map and nb.map.def then
      bounds = extendBounds(bounds, rectFor(nb.map.def, tonumber(nb.ox) or 0, tonumber(nb.oy) or 0))
    end
  end
  return bounds
end

function Twin._regionBase(gold, regionBounds)
  if not (gold and regionBounds) then return nil, nil end
  local rh = regionBounds.y2 - regionBounds.y1
  local goldCy = (gold.y1 + gold.y2) * 0.5
  return gold.x2 + Twin.REGION_GAP, math.floor(goldCy - rh * 0.5)
end

function Twin._oceanRect(bounds)
  if not bounds then return nil end
  local margin = Twin.OCEAN_MARGIN
  return {
    x1 = math.floor((bounds.x1 - margin) / 32) * 32,
    y1 = math.floor((bounds.y1 - margin) / 32) * 32,
    x2 = math.ceil((bounds.x2 + margin) / 32) * 32,
    y2 = math.ceil((bounds.y2 + margin) / 32) * 32,
  }
end

-- Four strips around LAND, never one plane under it.  Besides matching the
-- requested coastline/perimeter look, this cuts ocean fill/depth/reflection
-- work dramatically on large Gold+Kanto survey shots.
function Twin._oceanRects(bounds)
  if not bounds then return {} end
  local outer = Twin._oceanRect(bounds)
  local land = {
    x1 = math.floor(bounds.x1 / 32) * 32,
    y1 = math.floor(bounds.y1 / 32) * 32,
    x2 = math.ceil(bounds.x2 / 32) * 32,
    y2 = math.ceil(bounds.y2 / 32) * 32,
  }
  local rects = {
    { x1=outer.x1, y1=outer.y1, x2=outer.x2, y2=land.y1 },
    { x1=outer.x1, y1=land.y2, x2=outer.x2, y2=outer.y2 },
    { x1=outer.x1, y1=land.y1, x2=land.x1, y2=land.y2 },
    { x1=land.x2, y1=land.y1, x2=outer.x2, y2=land.y2 },
  }
  local out = {}
  for _, r in ipairs(rects) do
    if r.x2 > r.x1 and r.y2 > r.y1 then out[#out + 1] = r end
  end
  return out
end


local function sourceIdOf(rec)
  return rec and (rec.sourceId or (type(rec.id) == "string" and rec.id:gsub("^" .. Twin.PREFIX, ""))) or nil
end

local function recordBySource(region, sourceId)
  if not region then return nil end
  if type(region.recordBySource) == "table" and region.recordBySource[sourceId] then
    return region.recordBySource[sourceId]
  end
  if type(region.records) ~= "table" then return nil end
  for _, rec in ipairs(region.records) do
    if sourceIdOf(rec) == sourceId then return rec end
  end
  return nil
end

local function recordAt(region, gx, gy)
  if not (region and type(region.records) == "table") then return nil end
  gx, gy = tonumber(gx) or 0, tonumber(gy) or 0
  for _, rec in ipairs(region.records) do
    local def = rec.map and rec.map.def
    if def then
      local x1, y1 = tonumber(rec.ox) or 0, tonumber(rec.oy) or 0
      local x2 = x1 + (tonumber(def.width) or 0) * 32
      local y2 = y1 + (tonumber(def.height) or 0) * 32
      if gx >= x1 and gx < x2 and gy >= y1 and gy < y2 then return rec end
    end
  end
  return nil
end

local function passable(map, cx, cy, surfing)
  if not map then return false end
  local fn = map.isPassableCell or map.isWalkableCell or map.isWalkable
  if type(fn) ~= "function" then return false end
  -- ForeignGen1Map is our private adapter: its collision methods are pure and
  -- already bounds-safe.  Continuous third-person movement can call passable
  -- dozens of times per frame, so routing every one through pcall was a large
  -- avoidable protected-call tax.  Retain pcall for unknown/external map
  -- implementations so compatibility behavior stays defensive.
  if map._stadiumForeignGen1Map == true then
    return fn(map, cx, cy, surfing == true) == true
  end
  local ok, value = pcall(fn, map, cx, cy, surfing == true)
  return ok and value == true
end

Twin._passable = passable

local function walkable(map, cx, cy)
  return passable(map, cx, cy, false)
end

local function nearbyWalkable(map, x, y, surfing)
  local candidates = {
    {x, y + 1}, {x, y}, {x - 1, y + 1}, {x + 1, y + 1},
    {x - 1, y}, {x + 1, y}, {x, y + 2}, {x, y - 1},
  }
  for _, c in ipairs(candidates) do
    if passable(map, c[1], c[2], surfing) then return c[1], c[2] end
  end
  for r = 1, 5 do
    for dy = -r, r do
      for dx = -r, r do
        if math.max(math.abs(dx), math.abs(dy)) == r
           and passable(map, x + dx, y + dy, surfing) then
          return x + dx, y + dy
        end
      end
    end
  end
  return nil, nil
end


local function cachedImageData(region, path, cacheKey)
  if not (region and type(path) == "string") then return nil end
  local hit = region.spritePixels[cacheKey or path]
  if hit ~= nil then return hit or nil end
  local bytes = readVersion(region.loaded.CacheFs, region.version, path)
  if not bytes or not (love and love.data and love.data.newByteData and love.image and love.image.newImageData) then
    region.spritePixels[cacheKey or path] = false
    return nil
  end
  local ok, pixels = pcall(function()
    return love.image.newImageData(love.data.newByteData(bytes))
  end)
  region.spritePixels[cacheKey or path] = ok and pixels or false
  return ok and pixels or nil
end

local function makeSpriteObject(def)
  local sprite = { def = def }
  function sprite:resolveImage()
    if self.def._stadiumImage then return self.def._stadiumImage end
    local ok, image = pcall(Assets.image, self.def.image)
    return ok and image or nil
  end
  return sprite
end

local function npcSpriteFor(region, mapId, spriteKey)
  local source = region.loaded.sprites and region.loaded.sprites[spriteKey]
  if not source then return nil end
  local mapDef = region.loaded.maps[mapId]
  local colors, paletteName = activeKantoPalette(region, mapId, mapDef)
  local key = tostring(spriteKey) .. "|" .. tostring(paletteName)
  if region.spriteCache[key] ~= nil then return region.spriteCache[key] or nil end
  local raw = cachedImageData(region, source.image, source.image)
  local colored = raw and colorizeObjPixels(raw, colors) or nil
  local image = colored and imageFromPixels(colored) or nil
  if not image then region.spriteCache[key] = false; return nil end
  local def = deepCopy(source)
  def.trueColor = true
  def._stadiumImage = image
  def.image = ("__stadium_yellow_sprite/%s/%s.png")
    :format(tostring(paletteName):lower():gsub("[^%w_%-]", "_"), tostring(spriteKey):lower())
  local sprite = makeSpriteObject(def)
  region.spriteCache[key] = sprite
  return sprite
end

local function facingFromObject(obj)
  -- Current Yellow maps.py stores STAY/WALK in `movement`; a stationary
  -- object's actual SPRITE_FACING_* value is in `range`. Older caches/mods
  -- sometimes baked the facing into movement, so accept both shapes.
  local m = (tostring(obj and obj.movement or "") .. " "
    .. tostring(obj and obj.range or "")):upper()
  if m:find("UP", 1, true) then return "up" end
  if m:find("LEFT", 1, true) then return "left" end
  if m:find("RIGHT", 1, true) then return "right" end
  return "down"
end

Twin._facingFromObject = facingFromObject

local function simpleEntity(sprite, mapId, cx, cy, facing)
  local e = {
    sprite = sprite, mapId = mapId,
    cellX = cx, cellY = cy, px = cx * 16, py = cy * 16,
    facing = facing or "down", moving = false, stepFlip = false,
  }
  function e:pose()
    return self.sprite, self.px, self.py, self.facing, 0, self.stepFlip, false
  end
  return e
end

local function dexForSpecies(region, species)
  local p = region.loaded.pokemon and region.loaded.pokemon[species]
  local d = p and tonumber(p.dex)
  if d and d >= 1 and d <= 251 then return d end
  return tonumber(species)
end

local function pokemonSprite(dex)
  if not runtimeSheets:isReady() then pcall(runtimeSheets.load, runtimeSheets) end
  local def = runtimeSheets:spriteDef(dex, "normal", "SPRITE_YELLOW_KANTO_" .. tostring(dex))
  if not def then return nil end
  return makeSpriteObject(def)
end

local function pokemonEntity(region, mapId, species, cx, cy, index, level)
  local dex = dexForSpecies(region, species)
  if not dex then return nil end
  -- The 2D Yellow follower sheet is optional for a Stadium model.  Earlier
  -- builds returned nil here when that sheet was unavailable, which meant a
  -- perfectly valid Stadium 2 rig could never enter the Kanto entity list.
  -- Keep a model-only entity alive; VoxelScenePatch can rescue a nil sprite as
  -- long as the Pokemon identity below resolves to an installed Stadium pack.
  local sprite = pokemonSprite(dex)
  local e = simpleEntity(sprite, mapId, cx, cy, ({"down","left","right","up"})[(index % 4) + 1])
  e.overworldWildSpawn = true
  e.wildsAmbientPokemon = true
  e.visibleSprite = true
  e.spawnFx = { done = true, bodyShown = true }
  e.species = species
  e.level = tonumber(level) or 2
  e.wildLevel = e.level
  e.stadiumDex = dex
  e.pokemonDex = dex
  e.ambientSpecies = dex
  e._stadiumKantoPokemon = true
  e.stadiumModel = true
  e.name = "YELLOW_WILD_" .. tostring(mapId) .. "_" .. tostring(index)
  return e
end

Twin._pokemonEntity = pokemonEntity

local function hashString(value)
  local h = 2166136261
  for i = 1, #tostring(value) do
    h = (h * 16777619 + tostring(value):byte(i)) % 4294967296
  end
  return h
end

local function candidateCells(map, mode, occupied)
  local out = {}
  for y = 0, map.heightCells - 1 do
    for x = 0, map.widthCells - 1 do
      local key = y * 1024 + x
      if not occupied[key] then
        local good = false
        if mode == "water" then
          good = map:isWaterCell(x, y)
        elseif mode == "grass" then
          good = map:isGrassCell(x, y)
        else
          good = map:isWalkableCell(x, y)
        end
        if good and not map:warpAtCell(x, y) then out[#out + 1] = {x, y} end
      end
    end
  end
  return out
end

function Twin._kantoVisibleEncounterCount(rate, mode, cellCount, maxCount)
  rate = math.max(0, tonumber(rate) or 0)
  cellCount = math.max(0, math.floor(tonumber(cellCount) or 0))
  maxCount = math.max(1, math.floor(tonumber(maxCount) or (mode == "water" and 5 or 10)))
  if cellCount <= 0 then return 0 end

  -- v0.4.22: the old formula produced only two visible Pokemon on most Yellow
  -- routes because their encounter rates are well below 45.  Kanto is now a
  -- visibly populated free-roam region: grass starts around five bodies and
  -- water around three, with higher-rate/large maps gaining a little more.
  local base = mode == "water" and 3 or 5
  local count = base + math.floor(rate / 35)
  if mode ~= "water" and cellCount >= 180 then count = count + 1 end
  local cellCap = math.max(1, math.floor(cellCount / (mode == "water" and 7 or 5)))
  return math.min(maxCount, cellCap, count)
end

local function spawnFromEncounter(region, mapId, map, tableDef, mode, occupied, out, maxCount)
  if type(tableDef) ~= "table" or type(tableDef.slots) ~= "table" or #tableDef.slots == 0 then return end
  local cells = candidateCells(map, mode, occupied)
  if #cells == 0 and mode == "grass" then cells = candidateCells(map, "walk", occupied) end
  if #cells == 0 then return end
  local rate = tonumber(tableDef.rate) or 0
  local count = Twin._kantoVisibleEncounterCount(rate, mode, #cells, maxCount)
  local seed = hashString(mapId .. ":" .. mode)
  local spawned, attempt = 0, 0
  -- Retry alternate deterministic cells when one is already occupied.  The old
  -- one-pass loop silently lost requested spawns whenever its hash collided
  -- with an NPC/static Pokemon or another selected cell.
  while spawned < count and attempt < math.max(12, count * 8) do
    attempt = attempt + 1
    local ci = ((seed + attempt * 7919 + spawned * 104729) % #cells) + 1
    local si = ((seed + attempt * 3571 + spawned * 8191) % #tableDef.slots) + 1
    local cell, slot = cells[ci], tableDef.slots[si]
    if cell and slot and slot.species then
      local key = cell[2] * 1024 + cell[1]
      if not occupied[key] then
        local e = pokemonEntity(region, mapId, slot.species, cell[1], cell[2], #out + 1, slot.level)
        if e then
          occupied[key] = true
          out[#out + 1] = e
          spawned = spawned + 1
        end
      end
    end
  end
end

local itemAlreadyPicked
local staticPokemonCleared

function KantoState.isBoulder(obj)
  return tostring(obj and obj.sprite or ""):upper() == "SPRITE_BOULDER"
end

function KantoState.boulderPosition(mapId, obj)
  local state = KantoState.table(KantoState.BOULDER_POS_KEY)
  local perMap = state[mapId]
  local pos = type(perMap) == "table" and perMap[KantoState.objectId(obj)] or nil
  if type(pos) == "table" and tonumber(pos.x) and tonumber(pos.y) then
    return math.floor(tonumber(pos.x)), math.floor(tonumber(pos.y))
  end
  return tonumber(obj and obj.x) or 0, tonumber(obj and obj.y) or 0
end

function KantoState.persistBoulderPosition(mapId, obj, x, y)
  local state = KantoState.table(KantoState.BOULDER_POS_KEY)
  state[mapId] = type(state[mapId]) == "table" and state[mapId] or {}
  state[mapId][KantoState.objectId(obj)] = { x = math.floor(x), y = math.floor(y) }
  return persistenceSet(KantoState.BOULDER_POS_KEY, state)
end

function KantoState.boulderVisible(mapId, obj)
  local state = KantoState.table(KantoState.BOULDER_VIS_KEY)
  local perMap = state[mapId]
  -- Do not use `table and value or nil` here: false is meaningful persistent
  -- state (the source boulder was hidden after a floor drop). Collapsing false
  -- to nil makes the reader fall back to obj.hidden and resurrects the rock.
  local v
  if type(perMap) == "table" then v = perMap[KantoState.objectId(obj)] end
  if v ~= nil then return v == true end
  return obj and obj.hidden ~= true
end

function KantoState.setBoulderVisible(mapId, obj, visible)
  local state = KantoState.table(KantoState.BOULDER_VIS_KEY)
  state[mapId] = type(state[mapId]) == "table" and state[mapId] or {}
  state[mapId][KantoState.objectId(obj)] = visible == true
  return persistenceSet(KantoState.BOULDER_VIS_KEY, state)
end
Twin._kantoBoulderVisible = KantoState.boulderVisible
Twin._kantoBoulderPosition = KantoState.boulderPosition

function KantoState.seafoamEvent(event)
  return event and KantoState.table(KantoState.SEAFOAM_KEY)[event] == true or false
end

function KantoState.setSeafoamEvent(event)
  if not event then return false end
  local state = KantoState.table(KantoState.SEAFOAM_KEY)
  state[event] = true
  return persistenceSet(KantoState.SEAFOAM_KEY, state)
end

function KantoState.isDisguisedStaticPokemon(obj)
  return obj and obj.pokemon ~= nil
    and tostring(obj.sprite or ""):upper() == "SPRITE_POKE_BALL"
end
Twin._isDisguisedStaticPokemon = KantoState.isDisguisedStaticPokemon

local function entitiesForMap(region, mapId)
  if region.npcCache[mapId] and region.pokemonCache[mapId] then
    return region.npcCache[mapId], region.pokemonCache[mapId]
  end
  local map = ensureForeignMap(region, mapId)
  if not map then return {}, {} end
  local occupied, npcs, mons = {}, {}, {}
  for _, obj in ipairs(map.def.objects or {}) do
    local visible = (obj.hidden ~= true or KantoState.objectShown(mapId, obj))
      and not KantoState.objectHidden(mapId, obj)
    if KantoState.isBoulder(obj) then visible = KantoState.boulderVisible(mapId, obj) end
    if visible and obj.x ~= nil and obj.y ~= nil
        and not (obj.item and itemAlreadyPicked and itemAlreadyPicked(mapId, obj))
        and not (obj.pokemon and staticPokemonCleared and staticPokemonCleared(mapId, obj)) then
      local cx, cy
      if KantoState.isBoulder(obj) then cx, cy = KantoState.boulderPosition(mapId, obj)
      else cx, cy = tonumber(obj.x) or 0, tonumber(obj.y) or 0 end
      occupied[cy * 1024 + cx] = true
      if obj.pokemon and not KantoState.isDisguisedStaticPokemon(obj) then
        local e = pokemonEntity(region, mapId, obj.pokemon, cx, cy, #mons + 1, obj.level)
        if e then
          e.sourceObject = obj
          e.staticYellowPokemon = true
          mons[#mons + 1] = e
        end
      else
        -- Power Plant's Voltorb/Electrode traps are deliberately authored as
        -- SPRITE_POKE_BALL objects with a Pokemon payload.  Keep that disguise
        -- in the overworld; revealing a full Pokemon model before interaction
        -- gives the trap away and is not what Yellow draws.
        local sprite = npcSpriteFor(region, mapId, obj.sprite)
        if sprite then
          local e = simpleEntity(sprite, mapId, cx, cy, facingFromObject(obj))
          e.def = obj
          e.name = obj.name or ("YELLOW_NPC_" .. tostring(obj.index or #npcs + 1))
          e.objectIndex = obj.index
          e.isBoulder = KantoState.isBoulder(obj)
          e.homeX, e.homeY = tonumber(obj.x) or cx, tonumber(obj.y) or cy
          e.wander = tostring(obj.movement or ""):upper() == "WALK" and not e.isBoulder
          e.wanderRange = KantoState.objectRange(obj.range)
          if e.wander then e._kantoWanderHash = hashString(tostring(e.name)) end
          if KantoState.isDisguisedStaticPokemon(obj) then
            e.staticYellowPokemon = true
            e.sourceObject = obj
            e.disguisedStaticPokemon = true
            e.pokemonSpecies = obj.pokemon
            e.pokemonLevel = tonumber(obj.level) or 2
          end
          npcs[#npcs + 1] = e
        end
      end
    end
  end
  local enc = region.loaded.encounters and region.loaded.encounters[mapId]
  if enc then
    spawnFromEncounter(region, mapId, map, enc.grass, "grass", occupied, mons, 10)
    spawnFromEncounter(region, mapId, map, enc.water, "water", occupied, mons, 5)
  end
  region.npcCache[mapId] = npcs
  region.pokemonCache[mapId] = mons
  KantoState.Spatial.ensure(region, mapId, "npc", npcs)
  KantoState.Spatial.ensure(region, mapId, "pokemon", mons)
  KantoState.Spatial.roles(region, mapId, npcs)
  return npcs, mons
end

local function pokemonAt(region, mapId, cx, cy)
  local _, mons = entitiesForMap(region, mapId)
  return KantoState.Spatial.at(region, mapId, "pokemon", mons, cx, cy)
end

local ENCOUNTER_WEIGHTS = { 20, 20, 15, 10, 10, 10, 5, 5, 4, 1 }

local function randomInt(lo, hi)
  local mathApi = love and love.math
  local fn = mathApi and type(mathApi.random) == "function" and mathApi.random or nil
  if fn then
    -- Classic step encounters can ask the RNG twice on one landing (rate, then
    -- slot). Validate a newly-seen Love RNG function once and then call it
    -- directly, mirroring the trusted timer/input hot paths. If a host/mod
    -- replaces love.math.random the identity change automatically re-arms the
    -- defensive probe.
    if Twin._rngProbeRef ~= mathApi or Twin._rngProbeFn ~= fn then
      Twin._rngProbeRef, Twin._rngProbeFn, Twin._rngProbeTrusted = mathApi, fn, false
      local ok, value = pcall(fn, lo, hi)
      if ok and tonumber(value) then
        Twin._rngProbeTrusted = true
        Twin.kantoRngProbeReads = (Twin.kantoRngProbeReads or 0) + 1
        return math.floor(value)
      end
    elseif Twin._rngProbeTrusted then
      Twin.kantoRngFastCalls = (Twin.kantoRngFastCalls or 0) + 1
      return math.floor(tonumber(fn(lo, hi)) or lo)
    end
  end
  return math.random(lo, hi)
end
Twin._randomInt = randomInt

local function chooseEncounterSlot(slots, rng)
  if type(slots) ~= "table" or #slots == 0 then return nil end
  rng = rng or randomInt
  local roll = rng(1, 100)
  local sum = 0
  for i, weight in ipairs(ENCOUNTER_WEIGHTS) do
    sum = sum + weight
    if roll <= sum then return slots[math.min(i, #slots)] end
  end
  return slots[#slots]
end

local function encounterTableForCell(region, mapId, map, cx, cy)
  local enc = region and region.loaded and region.loaded.encounters
    and region.loaded.encounters[mapId]
  if not (enc and map) then return nil end
  if type(map.isWaterCell) == "function" and map:isWaterCell(cx, cy) then
    return enc.water, "water"
  end
  if type(map.isGrassCell) == "function" and map:isGrassCell(cx, cy) then
    return enc.grass, "grass"
  end
  -- Yellow caves use the same `grass` encounter table even though the floor
  -- is not literally a grass tile. Outdoor towns/routes require actual grass;
  -- indoor/cave maps with encounter data can roll on ordinary walkable floor.
  if not (region.validOutdoor and region.validOutdoor[mapId]) and enc.grass then
    return enc.grass, "cave"
  end
  return nil
end

function Twin._invalidateEncounterOptionCache()
  excursion.randomEncountersEnabled = nil
end

local function classicRandomEncountersEnabled()
  local cached = excursion.randomEncountersEnabled
  if cached ~= nil then
    Twin.kantoEncounterOptionCacheHits = (Twin.kantoEncounterOptionCacheHits or 0) + 1
    return cached == true
  end
  cached = option("random_encounters", false) == true
  excursion.randomEncountersEnabled = cached
  Twin.kantoEncounterOptionReads = (Twin.kantoEncounterOptionReads or 0) + 1
  return cached
end
Twin._classicRandomEncountersEnabled = classicRandomEncountersEnabled

local function makeGoldWild(world, species, level)
  local game = world and world.game
  if not (game and game.data and species and level) then return nil end
  local okMon, Mon = pcall(require, "src.battle.gen2.Mon")
  if not okMon or type(Mon) ~= "table" or type(Mon.new) ~= "function" then return nil end
  local ok, wild = pcall(Mon.new, game.data, species, tonumber(level) or 2)
  return ok and wild or nil
end

local markStaticPokemonCleared

function KantoState.removeStaticPresentationEntity(region, mapId, sourceEntity)
  if not (region and sourceEntity) then return false end
  local removed = false
  local stores = {
    { cache = region.pokemonCache, kind = "pokemon" },
    { cache = region.npcCache, kind = "npc" },
  }
  for _, row in ipairs(stores) do
    local list = row.cache and row.cache[mapId]
    if type(list) == "table" then
      for i = #list, 1, -1 do
        if list[i] == sourceEntity then
          if KantoState.Spatial and type(KantoState.Spatial.remove) == "function" then
            KantoState.Spatial.remove(region, mapId, row.kind, sourceEntity,
              sourceEntity.cellX, sourceEntity.cellY)
          end
          table.remove(list, i)
          removed = true
          break
        end
      end
    end
  end
  return removed
end
Twin._removeStaticPresentationEntity = KantoState.removeStaticPresentationEntity

function KantoState.restoreStaticPresentationCaches(region, mapId)
  if not region then return end
  if region.pokemonCache then region.pokemonCache[mapId] = nil end
  if region.npcCache then region.npcCache[mapId] = nil end
  if KantoState.Spatial and type(KantoState.Spatial.invalidate) == "function" then
    KantoState.Spatial.invalidate(region, mapId, true, true)
  end
end
Twin._restoreStaticPresentationCaches = KantoState.restoreStaticPresentationCaches

local function startYellowWildBattle(world, region, mapId, species, level, sourceEntity)
  -- Before the SILPH SCOPE, Pokemon Tower's ordinary encounter slots are
  -- unidentified ghosts. Do not leak the real species into Gold's battle,
  -- Pokedex, or capture system just because the Yellow cache already knows it.
  local towerId = tostring(mapId or "")
  if towerId:match("^POKEMON_TOWER_[3-6]F$")
      and not KantoState.itemHeld(world, "SILPH_SCOPE") then
    Twin.yellowTowerGhostBlocks = (Twin.yellowTowerGhostBlocks or 0) + 1
    if type(Twin._kantoShowMessage) == "function" then
      Twin._kantoShowMessage(world,
        "GHOST! The SILPH SCOPE is needed to identify it!")
    end
    return true
  end
  if excursion.safari and type(Twin._startKantoSafariEncounter) == "function" then
    return Twin._startKantoSafariEncounter(world, region, mapId, species, level, sourceEntity)
  end
  if excursion.battleBusy then return false end
  if not (world and type(world.startBattle) == "function") then
    Twin.lastBattleError = "Gold wild battle API unavailable"
    return false
  end
  local wild = makeGoldWild(world, species, level)
  if not wild then
    Twin.lastBattleError = "Gold could not build Yellow wild Pokemon " .. tostring(species)
    return false
  end
  local save = world.game and world.game.save
  if save then
    save.pokedex = save.pokedex or { seen = {}, caught = {} }
    save.pokedex.seen = save.pokedex.seen or {}
    save.pokedex.caught = save.pokedex.caught or {}
    save.pokedex.seen[species] = true
  end
  excursion.battleBusy = true
  Twin.yellowWildBattles = (Twin.yellowWildBattles or 0) + 1
  Twin.lastWildSpecies, Twin.lastWildLevel = species, tonumber(level) or 2

  -- Consume the touched presentation actor while the battle is up.  Normal
  -- static Pokemon live in pokemonCache; disguised Power Plant trap balls live
  -- in npcCache.  One helper handles both so neither leaves a duplicate body
  -- underneath the battle screen.
  if sourceEntity then KantoState.removeStaticPresentationEntity(region, mapId, sourceEntity) end

  local caughtBefore = save and save.pokedex and save.pokedex.caught
    and save.pokedex.caught[species] == true
  local ok, started, err = pcall(world.startBattle, world, { wild = wild }, function(outcome)
    excursion.battleBusy = false
    excursion.prevA = false
    if outcome == "win" or outcome == true then
      Twin.yellowWildWins = (Twin.yellowWildWins or 0) + 1
    elseif outcome == "lose" and Twin._handleKantoBattleLoss then
      pcall(Twin._handleKantoBattleLoss, world)
    end
    local caughtNow = save and save.pokedex and save.pokedex.caught
      and save.pokedex.caught[species] == true
    if caughtNow and not caughtBefore then
      Twin.yellowWildCatches = (Twin.yellowWildCatches or 0) + 1
    end
    if sourceEntity and sourceEntity.staticYellowPokemon and sourceEntity.sourceObject then
      -- Yellow's EndTrainerBattle hides a one-off map Pokemon after any
      -- completed wild battle (win/catch/run); only a blackout/reset path skips
      -- the trainer flag + HideObject tail. Gold reports those outcomes as
      -- "win", "caught", "run" and "lose" respectively. Treating RUN as a
      -- completed encounter prevents Articuno/Zapdos/Moltres/Mewtwo from
      -- respawning after the player deliberately flees, while a loss still
      -- restores the object for a retry.
      local cleared = outcome == "win" or outcome == true
        or outcome == "caught" or outcome == "run" or caughtNow
      if cleared then
        markStaticPokemonCleared(mapId, sourceEntity.sourceObject)
      else
        -- A blackout is the one reset path that does not consume Yellow's
        -- one-off object. Rebuild either cache kind so a legendary model OR a
        -- disguised trap ball returns for a retry.
        KantoState.restoreStaticPresentationCaches(region, mapId)
      end
    end
  end)
  if not ok or started == false then
    excursion.battleBusy = false
    Twin.lastBattleError = tostring(ok and err or started)
    return false
  end
  Twin.lastBattleError = nil
  return true
end

local function rollYellowStepEncounter(world, region, mapId, map, cx, cy, rng)
  if not classicRandomEncountersEnabled()
      and not (excursion.safari and tostring(mapId or ""):find("^SAFARI_ZONE_")) then
    return false
  end
  local tableDef = encounterTableForCell(region, mapId, map, cx, cy)
  if type(tableDef) ~= "table" or type(tableDef.slots) ~= "table"
      or #tableDef.slots == 0 then return false end
  local rate = math.max(0, math.min(255, tonumber(tableDef.rate) or 0))
  if rate <= 0 then return false end
  rng = rng or randomInt
  if rng(0, 255) >= rate then return false end
  local slot = chooseEncounterSlot(tableDef.slots, rng)
  if not (slot and slot.species) then return false end
  return startYellowWildBattle(world, region, mapId, slot.species,
    tonumber(slot.level) or 2, nil)
end

Twin._chooseEncounterSlot = chooseEncounterSlot
Twin._encounterTableForCell = encounterTableForCell
Twin._rollYellowStepEncounter = rollYellowStepEncounter
Twin._startYellowWildBattle = startYellowWildBattle

local function npcAt(region, mapId, cx, cy, except)
  local npcs = entitiesForMap(region, mapId)
  return KantoState.Spatial.at(region, mapId, "npc", npcs, cx, cy, except)
end

local function occupiedByNpc(region, mapId, cx, cy, except)
  return npcAt(region, mapId, cx, cy, except) ~= nil
end

local DIR_CONN = { up = "north", down = "south", left = "west", right = "east" }

-- v0.3.32 desktop sector cooker.  GPU residency stays bounded to the live
-- neighborhood, but the expensive BODY geometry for every Yellow outdoor map
-- is derived once in the background and serialized through ChunkMesher's
-- engine-owned persistent cache.  On future visits a direct/predicted sector
-- can upload this BODY immediately while its exact FULL seam-masked variant
-- finishes offscreen.  The queue is deliberately small; ChunkMesher itself
-- gives cache-only work a much larger CPU slice on desktop only when no real
-- render job is waiting.
local function scheduleKantoDiskWarm(region, rootMap, neighbors, allowPrepare)
  if not (region and ChunkMesher
      and type(ChunkMesher.diskCacheEnabled) == "function"
      and ChunkMesher.diskCacheEnabled()
      and type(ChunkMesher.warmDisk) == "function") then return end
  if region.diskWarmComplete == true then return end
  local records = region.records or {}
  if #records == 0 then return end
  region.diskWarmSeen = region.diskWarmSeen or {}
  region.diskWarmCursor = tonumber(region.diskWarmCursor) or 1

  local mode = Quality and Quality.buildMode and Quality.buildMode() or "balanced"
  local targetPending = mode == "fast" and 4 or (mode == "smooth" and 1 or 2)
  local pending = type(ChunkMesher.warmPending) == "function"
    and ChunkMesher.warmPending("kanto") or 0
  if pending >= targetPending then return end

  -- v0.3.58: visible Kanto gameplay must never decode/colorize an unrelated
  -- map merely to warm its persistent mesh cache. ensureForeignMap can create
  -- ImageData/atlases and is much more expensive than the cooperative mesher
  -- itself. During gameplay, queue cache writes ONLY for maps already prepared
  -- because they are current/visible neighbors. Menus/covered states may keep
  -- using the historical whole-region cooker below.
  if allowPrepare ~= true then
    local i = 0
    while pending < targetPending do
      local map
      if i == 0 then
        map = rootMap
      else
        local nb = neighbors and neighbors[i]
        if not nb then break end
        map = nb.map
      end
      i = i + 1
      if map and map.sourceId and not region.diskWarmSeen[map.sourceId] then
        local ok, state = ChunkMesher.warmDisk(map, true, nil, "kanto")
        if ok then
          region.diskWarmSeen[map.sourceId] = true
          if state == "queued" then
            pending = pending + 1
            Twin.kantoCacheWarmQueued = (Twin.kantoCacheWarmQueued or 0) + 1
          elseif state == "hit" then
            Twin.kantoCacheWarmHits = (Twin.kantoCacheWarmHits or 0) + 1
          elseif state == "live" then
            Twin.kantoCacheWarmLive = (Twin.kantoCacheWarmLive or 0) + 1
          end
        end
      end
    end
    Twin.kantoCacheWarmVisibleOnly = (Twin.kantoCacheWarmVisibleOnly or 0) + 1
    return
  end

  local prepares = Quality and Quality.kantoSurveyBatch and Quality.kantoSurveyBatch() or 1
  local scanned, prepared = 0, 0
  while pending < targetPending and prepared < prepares and scanned < #records do
    if region.diskWarmCursor > #records then region.diskWarmCursor = 1 end
    local rec = records[region.diskWarmCursor]
    region.diskWarmCursor = region.diskWarmCursor + 1
    scanned = scanned + 1
    if rec and not region.diskWarmSeen[rec.sourceId] then
      local map = rec.map or ensureForeignMap(region, rec.sourceId)
      if map then
        rec.map = map
        local ok, state = ChunkMesher.warmDisk(map, true, nil, "kanto")
        if ok then
          region.diskWarmSeen[rec.sourceId] = true
          prepared = prepared + 1
          if state == "queued" then
            pending = pending + 1
            Twin.kantoCacheWarmQueued = (Twin.kantoCacheWarmQueued or 0) + 1
          elseif state == "hit" then
            Twin.kantoCacheWarmHits = (Twin.kantoCacheWarmHits or 0) + 1
          elseif state == "live" then
            Twin.kantoCacheWarmLive = (Twin.kantoCacheWarmLive or 0) + 1
          end
        end
      end
    end
  end
  -- Once a complete pass finds nothing left to queue/probe, stop rescanning
  -- the entire Kanto record list every render frame.  A region invalidation
  -- creates fresh runtime state, so this latch cannot hide a later map edit.
  if scanned >= #records and prepared == 0 and pending == 0 then
    region.diskWarmComplete = true
    Twin.kantoCacheWarmComplete = (Twin.kantoCacheWarmComplete or 0) + 1
  end
  Twin.kantoCacheWarmCursor = region.diskWarmCursor
end

Twin._scheduleKantoDiskWarm = scheduleKantoDiskWarm

local function sectorRecords(region, sourceId, hops)
  hops = hops or 2
  local root = recordBySource(region, sourceId)
  if not root then return {} end
  if not root.map then root.map = ensureForeignMap(region, sourceId) end
  if not root.map then return {} end

  -- The connection topology/offsets never change during an excursion. Cache the
  -- solved sector list once per root/radius rather than re-running the BFS on
  -- every rendered frame. resetColoredRegion clears this when palette/map
  -- adapters are rebuilt, so cached records never retain released maps.
  region.sectorCache = region.sectorCache or {}
  -- v0.3.59: sourceId/radius are already stable scalar keys. Keep a nested
  -- cache instead of allocating "map|radius" strings every visible Kanto frame.
  local perRoot = region.sectorCache[sourceId]
  if type(perRoot) ~= "table" then
    perRoot = {}
    region.sectorCache[sourceId] = perRoot
  end
  local cached = perRoot[hops]
  if type(cached) == "table" then return cached end

  local out, seen = {}, { [sourceId] = true }
  local q, qi = { { id = sourceId, depth = 0 } }, 1
  while q[qi] do
    local cur = q[qi]; qi = qi + 1
    local def = region.loaded.maps[cur.id]
    if def and cur.depth < hops then
      for _, dir in ipairs({"north","south","west","east"}) do
        local conn = def.connections and def.connections[dir]
        local id = conn and (conn.map or conn.mapId)
        local rec = id and recordBySource(region, id)
        if rec and not seen[id] then
          if not rec.map then rec.map = ensureForeignMap(region, id) end
          if rec.map then
            seen[id] = true
            local depth = cur.depth + 1
            out[#out + 1] = {
              sourceId = id, id = rec.id, map = rec.map,
              ox = (tonumber(rec.ox) or 0) - (tonumber(root.ox) or 0),
              oy = (tonumber(rec.oy) or 0) - (tonumber(root.oy) or 0),
              depth = depth, dir = dir,
            }
            q[#q + 1] = { id = id, depth = depth }
          end
        end
      end
    end
  end
  perRoot[hops] = out
  return out
end

-- Whole-Kanto connected view for OPEN WORLD. Build the topology once without
-- decoding every Yellow map in one frame, then progressively materialize map
-- adapters in BFS order. Direct neighbours are always prepared immediately so
-- seam crossings remain instant; farther maps join a few at a time and can hit
-- the persistent BODY cache added in v0.4.31 instead of rebuilding cold.
function Twin._openWorldRecords(region, sourceId)
  local root = recordBySource(region, sourceId)
  if not (region and root) then return {}, 0, 0 end
  if not root.map then root.map = ensureForeignMap(region, sourceId) end
  if not root.map then return {}, 0, 0 end

  region.openWorldSectorCache = region.openWorldSectorCache or {}
  local state = region.openWorldSectorCache[sourceId]
  if type(state) ~= "table" then
    local all, active = {}, {}
    local seen = { [sourceId] = true }
    local q, qi = { { id = sourceId, depth = 0 } }, 1
    while q[qi] do
      local cur = q[qi]; qi = qi + 1
      local def = region.loaded and region.loaded.maps and region.loaded.maps[cur.id]
      if def then
        for _, dir in ipairs({"north","south","west","east"}) do
          local conn = def.connections and def.connections[dir]
          local id = conn and (conn.map or conn.mapId)
          local rec = id and recordBySource(region, id)
          if rec and not seen[id] then
            seen[id] = true
            local depth = cur.depth + 1
            local d = {
              sourceId = id, id = rec.id, map = rec.map,
              ox = (tonumber(rec.ox) or 0) - (tonumber(root.ox) or 0),
              oy = (tonumber(rec.oy) or 0) - (tonumber(root.oy) or 0),
              depth = depth, dir = dir, _record = rec,
            }
            all[#all + 1] = d
            if d.map then active[#active + 1] = d end
            q[#q + 1] = { id = id, depth = depth }
          end
        end
      end
    end
    state = {
      all = all, active = active, cursor = 1,
      prepared = #active, directReady = false,
    }
    region.openWorldSectorCache[sourceId] = state
  end

  local function prepare(d)
    if not d or d.map then return false end
    local rec = d._record or recordBySource(region, d.sourceId)
    if not rec then return false end
    if not rec.map then rec.map = ensureForeignMap(region, d.sourceId) end
    if not rec.map then return false end
    d.map = rec.map
    state.active[#state.active + 1] = d
    state.prepared = (state.prepared or 0) + 1
    return true
  end

  if not state.directReady then
    for _, d in ipairs(state.all) do
      if (tonumber(d.depth) or 99) <= 1 then prepare(d) end
    end
    state.directReady = true
  end

  if (state.prepared or 0) < #state.all then
    local batch = math.max(2, (Quality.kantoSurveyBatch and Quality.kantoSurveyBatch() or 1) * 2)
    local made, scanned = 0, 0
    while made < batch and scanned < #state.all do
      if state.cursor > #state.all then state.cursor = 1 end
      local d = state.all[state.cursor]
      state.cursor = state.cursor + 1
      scanned = scanned + 1
      if prepare(d) then made = made + 1 end
    end
  end

  Twin.kantoOpenWorldPrepared = state.prepared or 0
  Twin.kantoOpenWorldTotal = #state.all
  return state.active, state.prepared or 0, #state.all
end

Twin._sectorRecords = sectorRecords
Twin._entitiesForMap = entitiesForMap

-- Pallet entry is intentionally canonical.  The Yellow source fixes Red's
-- house at warp (5,5), with the safe outdoor landing immediately south at
-- (5,6).  Older bridge revisions tried to infer the doorway from opaque cache
-- destinations and then widened the search too far; a stale/patched cache could
-- therefore select a visually tree-filled cell elsewhere in Pallet.  v0.3.40
-- never searches the whole town for an entry point.
local PALLET_DOOR_X, PALLET_DOOR_Y = 5, 5
local PALLET_ENTRY_REVISION = 341

local function palletVisualGround(map, cx, cy)
  if not (map and type(map.cellTile) == "function") then return false end
  local ok, tile = pcall(map.cellTile, map, cx, cy)
  if not ok or tile == nil then return false end
  local cats = map._stadiumGen2SourceCategories
  local cat = type(cats) == "table" and cats[tonumber(tile)] or nil
  if type(cat) == "string" then
    if cat == "door" or cat == "water" or cat:sub(1, 10) == "structure:" then
      return false
    end
    if cat == "structure" then return false end
  end
  return true
end

local function palletBodyCell(map, cx, cy)
  if not (map and type(map.inBounds) == "function") then return false end
  cx, cy = tonumber(cx), tonumber(cy)
  if not (cx and cy) then return false end
  cx, cy = math.floor(cx), math.floor(cy)
  if not map:inBounds(cx, cy) then return false end

  -- The renderer border-extends map:blockAt outside the authored body.  Never
  -- treat that border block as a legal teleport landing even if its collision
  -- tile happens to be in the source walkable set.
  if type(map.blockAt) == "function" then
    local bx, by = math.floor(cx / 2), math.floor(cy / 2)
    local ok, block = pcall(map.blockAt, map, bx, by)
    local border = map.def and tonumber(map.def.borderBlock)
    if ok and border ~= nil and tonumber(block) == border then return false end
  end
  return true
end

function Twin._palletCellSafe(region, map, cx, cy)
  cx, cy = tonumber(cx), tonumber(cy)
  if not (cx and cy) then return false end
  cx, cy = math.floor(cx), math.floor(cy)
  if not palletBodyCell(map, cx, cy) then return false end
  if not passable(map, cx, cy, false) then return false end
  if not palletVisualGround(map, cx, cy) then return false end
  if type(map.warpAtCell) == "function" and map:warpAtCell(cx, cy) then return false end
  if region and occupiedByNpc(region, "PALLET_TOWN", cx, cy, nil) then return false end
  return true
end

function Twin._palletStart(region)
  local rec = recordBySource(region, "PALLET_TOWN")
  if rec and not rec.map then rec.map = ensureForeignMap(region, "PALLET_TOWN") end
  if not (rec and rec.map and rec.map.def) then return nil, nil, nil end
  local map, def = rec.map, rec.map.def

  -- A named destination can confirm the canonical coordinate, but it never
  -- overrides it with another warp.  Opaque/numeric cache destinations are
  -- common and are not a reason to guess from source order.
  local wx, wy = PALLET_DOOR_X, PALLET_DOOR_Y
  for _, warp in ipairs(def.warps or {}) do
    local dest = tostring(warp.destMap or warp.map or warp.mapId or "")
    if dest == "REDS_HOUSE_1F" or dest:find("REDS_HOUSE", 1, true) then
      local x, y = tonumber(warp.x), tonumber(warp.y)
      if x and y then wx, wy = math.floor(x), math.floor(y) end
      break
    end
  end

  -- Stay immediately around Red's front door.  Do NOT widen this into an
  -- arbitrary-radius search: that was how a damaged semantic projection could
  -- turn an invalid entry into a distant tree-belt landing.
  local candidates = {
    {wx, wy + 1},
    {wx - 1, wy + 1}, {wx + 1, wy + 1},
    {wx, wy + 2},
  }
  for _, c in ipairs(candidates) do
    if Twin._palletCellSafe(region, map, c[1], c[2]) then
      return c[1], c[2], rec
    end
  end
  return nil, nil, rec
end

-- A saved Pallet point must be connected to the canonical Red-house landing
-- through authored, passable cells.  This is a corruption/resume guard, not a
-- general movement rule; normal play still uses the source collision exactly.
function Twin._palletReachable(map, sx, sy, tx, ty)
  if not (map and type(map.inBounds) == "function") then return false end
  sx, sy, tx, ty = tonumber(sx), tonumber(sy), tonumber(tx), tonumber(ty)
  if not (sx and sy and tx and ty) then return false end
  sx, sy, tx, ty = math.floor(sx), math.floor(sy), math.floor(tx), math.floor(ty)
  if not (palletBodyCell(map, sx, sy) and palletBodyCell(map, tx, ty)) then return false end
  if not (passable(map, sx, sy, false) and passable(map, tx, ty, false)) then return false end
  if sx == tx and sy == ty then return true end
  local qx, qy, head = { sx }, { sy }, 1
  local seen = { [sy * 1024 + sx] = true }
  local maxNodes = math.max(1, (tonumber(map.widthCells) or 0) * (tonumber(map.heightCells) or 0))
  while qx[head] ~= nil and head <= maxNodes do
    local x, y = qx[head], qy[head]; head = head + 1
    for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1} }) do
      local nx, ny = x + d[1], y + d[2]
      local key = ny * 1024 + nx
      if not seen[key] and palletBodyCell(map, nx, ny) and passable(map, nx, ny, false) then
        if nx == tx and ny == ty then return true end
        seen[key] = true
        qx[#qx + 1], qy[#qy + 1] = nx, ny
      end
    end
  end
  return false
end

function Twin.excursionIsActive()
  return excursion.active == true
end

-- Lightweight Kanto world view for presentation-only systems such as ambient
-- sky Pokemon.  Unlike excursionState(), this never ticks input, builds sector
-- records, or touches the renderer; it simply exposes the already-current
-- Yellow map/player/encounter table so a per-step ambience update cannot tick
-- the Kanto runtime twice.
Twin._ambientFlyerWorld = Twin._ambientFlyerWorld or { player = {} }
function Twin.ambientFlyerWorld(baseWorld)
  if not (excursion.active and excursion.region and excursion.sourceMapId) then return nil end
  local region = excursion.region
  local map = ensureForeignMap(region, excursion.sourceMapId)
  if not map then return nil end
  local ambientFlyerWorld = Twin._ambientFlyerWorld
  local p = ambientFlyerWorld.player
  p.px, p.py = tonumber(excursion.drawPx) or 0, tonumber(excursion.drawPy) or 0
  p.cellX, p.cellY = tonumber(excursion.cellX) or 0, tonumber(excursion.cellY) or 0
  p.facing = excursion.facing or "down"
  ambientFlyerWorld.map = map
  ambientFlyerWorld.encounters = region.loaded and region.loaded.encounters or nil
  ambientFlyerWorld.daytime = baseWorld and baseWorld.daytime or nil
  ambientFlyerWorld.timeOfDay = baseWorld and baseWorld.timeOfDay or nil
  ambientFlyerWorld.time_of_day = baseWorld and baseWorld.time_of_day or nil
  ambientFlyerWorld.hour = baseWorld and baseWorld.hour or nil
  ambientFlyerWorld.currentHour = baseWorld and baseWorld.currentHour or nil
  ambientFlyerWorld._stadiumYellowKanto = true
  return ambientFlyerWorld
end

function Twin.teleportLabel()
  return excursion.active and "RETURN TO JOHTO" or "KANTO FREE ROAM"
end

local function gameWorld(game)
  if type(game) == "table" then
    if type(game.overworld) == "table" then return game.overworld end
    if type(game.world) == "table" then return game.world end
  end
  local bridge = mod and mod.world
  if bridge and type(bridge.overworld) == "function" then
    local ok, world = pcall(bridge.overworld, bridge)
    if ok and type(world) == "table" then return world end
  end
  return nil
end

local POSITION_KEY = "yellowFreeRoamPositionV1"
local PICKED_ITEMS_KEY = "yellowPickedItemsV1"
local STATIC_POKEMON_KEY = "yellowStaticPokemonV1"

-- v0.3.63: cell landings used to allocate a fresh position table, deep-copy
-- LAST_MAP state, and cross mod.save on every single Kanto cell.  The save API
-- is a save-slot namespace, not a movement clock; keep one lightweight
-- snapshot and checkpoint ordinary travel in small batches.  Explicit state
-- transitions (warps, Fly, Surf/Bike changes, menus and RETURN TO JOHTO) still
-- call this with the default force=true and therefore remain exact.
Twin.KANTO_POSITION_CHECKPOINT_STEPS = 8

local function persistExcursionPosition(force)
  if not (excursion.active and excursion.region and excursion.sourceMapId) then return false end
  if force == nil then force = true end

  local snap = excursion.positionSnapshot
  if type(snap) ~= "table" then
    snap = {}
    excursion.positionSnapshot = snap
    Twin.kantoPositionSnapshotCreates = (Twin.kantoPositionSnapshotCreates or 0) + 1
  end

  local outside = excursion.lastOutside
  local savedOutside = snap.lastOutside
  local outsideChanged
  if type(outside) == "table" then
    if type(savedOutside) ~= "table" then
      savedOutside = {}
      snap.lastOutside = savedOutside
      outsideChanged = true
    end
    local oid, ox, oy = outside.id, outside.x, outside.y
    if savedOutside.id ~= oid or savedOutside.x ~= ox or savedOutside.y ~= oy then
      outsideChanged = true
    end
  else
    outsideChanged = savedOutside ~= nil
  end

  local changed = snap.mapId ~= excursion.sourceMapId
    or snap.x ~= excursion.cellX or snap.y ~= excursion.cellY
    or snap.facing ~= excursion.facing
    or snap.surfing ~= (excursion.surfing == true)
    or snap.biking ~= (excursion.biking == true)
    or snap.forcedBike ~= (excursion.forcedBike == true)
    or snap.entryRevision ~= PALLET_ENTRY_REVISION
    or outsideChanged == true

  snap.mapId, snap.x, snap.y = excursion.sourceMapId, excursion.cellX, excursion.cellY
  snap.facing = excursion.facing
  snap.surfing = excursion.surfing == true
  snap.biking = excursion.biking == true
  snap.forcedBike = excursion.forcedBike == true
  snap.entryRevision = PALLET_ENTRY_REVISION
  if type(outside) == "table" then
    savedOutside.id, savedOutside.x, savedOutside.y = outside.id, outside.x, outside.y
    snap.lastOutside = savedOutside
  else
    snap.lastOutside = nil
  end

  -- Keep same-process reads current even before the next durable checkpoint.
  Twin._persistenceTableCache[POSITION_KEY] = snap
  if changed then excursion.positionDirty = true end

  if force ~= true then
    if not changed then
      Twin.kantoPositionCheckpointSkips = (Twin.kantoPositionCheckpointSkips or 0) + 1
      return true
    end
    excursion.positionDirtySteps = (tonumber(excursion.positionDirtySteps) or 0) + 1
    local interval = math.max(1, tonumber(Twin.KANTO_POSITION_CHECKPOINT_STEPS) or 8)
    if excursion.positionDirtySteps < interval then
      Twin.kantoPositionDeferredSteps = (Twin.kantoPositionDeferredSteps or 0) + 1
      return true
    end
  elseif not excursion.positionDirty and not changed then
    Twin.kantoPositionForcedNoops = (Twin.kantoPositionForcedNoops or 0) + 1
    return true
  end

  local ok = persistenceSet(POSITION_KEY, snap)
  if ok then
    excursion.positionDirty = false
    excursion.positionDirtySteps = 0
    Twin.kantoPositionCheckpoints = (Twin.kantoPositionCheckpoints or 0) + 1
  end
  return ok
end

function Twin._flushExcursionPosition()
  if not excursion.positionDirty then return true end
  return persistExcursionPosition(true)
end
Twin._persistExcursionPosition = persistExcursionPosition

local function resumePosition(region)
  local saved = persistenceGet(POSITION_KEY, nil)
  if type(saved) ~= "table" or type(saved.mapId) ~= "string" then return nil end
  local map = ensureForeignMap(region, saved.mapId)
  if not map then return nil end

  -- v0.3.41 deliberately remigrates EVERY pre-341 Kanto position, including
  -- positions already stamped by v0.3.40.  v0.3.40 correctly repaired the
  -- LOCAL Pallet cell, but its camera proxy still baked in a 160x144 viewport;
  -- on a wide desktop viewport that made the player LOOK one whole map east in
  -- the border apron.  Resetting the presentation-local position once keeps
  -- old saves deterministic while the viewport-correct camera contract lands.
  if (tonumber(saved.entryRevision) or 0) < PALLET_ENTRY_REVISION then
    Twin.yellowKantoEntryRepairs = (Twin.yellowKantoEntryRepairs or 0) + 1
    if saved.mapId == "PALLET_TOWN" then
      Twin.yellowPalletSpawnRepairs = (Twin.yellowPalletSpawnRepairs or 0) + 1
    end
    return nil
  end

  local x, y
  if saved.mapId == "PALLET_TOWN" then
    -- Never repair a Pallet resume by searching around the saved point.  A bad
    -- point must be discarded and rebuilt from the canonical door landing.
    x, y = tonumber(saved.x), tonumber(saved.y)
    if not (x and y) then return nil end
    x, y = math.floor(x), math.floor(y)
    if not Twin._palletCellSafe(region, map, x, y) then
      Twin.yellowPalletSpawnRepairs = (Twin.yellowPalletSpawnRepairs or 0) + 1
      return nil
    end
    local sx, sy = Twin._palletStart(region)
    if sx == nil or not Twin._palletReachable(map, sx, sy, x, y) then
      Twin.yellowPalletSpawnRepairs = (Twin.yellowPalletSpawnRepairs or 0) + 1
      return nil
    end
  else
    x, y = nearbyWalkable(map, tonumber(saved.x), tonumber(saved.y), saved.surfing == true)
    if not x then return nil end
  end

  local rec = recordBySource(region, saved.mapId)
  if not rec and not region.validOutdoor[saved.mapId] then
    rec = { sourceId = saved.mapId, id = Twin.PREFIX .. saved.mapId,
      map = map, ox = 0, oy = 0, depth = 0 }
  end
  return x, y, rec, saved
end

function Twin.teleportToPalletTown(game)
  -- v0.4.16: Kanto Free Roam is presentation-local over Gold's hidden Johto
  -- world and currently uses this mod's foreign-map renderer. Native 2D must
  -- remain authoritative when selected, so never silently turn voxels back on
  -- just to enter Kanto. Refuse the transition cleanly and leave Gold exactly
  -- where it is; switching 3D on later makes the same menu action available.
  if V and type(V.world3DEnabled) == "function" then
    local ok3d, enabled3d = pcall(V.world3DEnabled)
    if ok3d and enabled3d ~= true then
      Twin.twoDEntryBlocks = (Twin.twoDEntryBlocks or 0) + 1
      return false, "KANTO FREE ROAM needs 3D VOXEL WORLD. Native 2D remains active."
    end
  end
  KantoState.clearPersistenceCache()
  local region, err = ensureRegion()
  if not region then return false, err or "Pokemon Yellow Kanto cache unavailable" end
  local world = gameWorld(game)
  if not (world and world.player) then return false, "Gold overworld is not ready" end
  syncGoldPalette(region, world)
  local cx, cy, rec, resumed = resumePosition(region)
  if not (cx and cy and rec) then
    cx, cy, rec = Twin._palletStart(region)
    resumed = nil
  else
    Twin.yellowResumeLoads = (Twin.yellowResumeLoads or 0) + 1
  end
  if not (cx and cy and rec) then return false, "Pallet Town start tile unavailable" end

  -- Preserve the real Gold location as an explicit anchor. Most Kanto actions
  -- never touch the hidden Johto world, but Gen-2 battle whiteout legitimately
  -- moves that world to its blackout spawn. RETURN TO JOHTO restores this
  -- anchor while keeping the battle's money/party/save consequences.
  do
    local wm = world.map and (world.map.id or (world.map.def and world.map.def.id))
    local wp = world.player
    excursion.johtoAnchor = wm and wp and {
      mapId = wm, x = tonumber(wp.cellX), y = tonumber(wp.cellY),
      facing = wp.facing or "down",
    } or nil
  end

  excursion.active = true
  excursion.world = world
  excursion.region = region
  excursion.sourceMapId = resumed and resumed.mapId or "PALLET_TOWN"
  KantoState.onMapEntered(region, excursion.sourceMapId)
  excursion.cellX, excursion.cellY = cx, cy
  excursion.drawPx, excursion.drawPy = cx * 16, cy * 16
  excursion.facing = (resumed and resumed.facing) or "down"
  excursion.surfing = resumed and resumed.surfing == true or false
  excursion.biking = resumed and resumed.biking == true or false
  excursion.forcedBike = resumed and resumed.forcedBike == true or false
  excursion.stepFlip = false
  excursion.moving = false
  excursion.moveT = 0
  excursion.animClock = 0
  excursion.animDistance = 0
  excursion.lastWorldX, excursion.lastWorldZ = 0, 0
  excursion.freeActive = false
  excursion.freeX, excursion.freeZ, excursion.freeMapId = nil, nil, nil
  excursion.freeVisualMoving = false
  excursion.lastTick = now()
  excursion.currentRecord = rec
  Twin._clearWarpIgnore()
  excursion.randomEncountersEnabled = nil
  excursion.lastOutside = resumed and deepCopy(resumed.lastOutside)
    or { id = "PALLET_TOWN", x = cx, y = cy }
  excursion.standingOnWarp = false
  excursion.prevA = false
  excursion.battleBusy = false
  excursion.trainerEngaging = false
  excursion.strengthActive = false
  excursion.npcAiClock, excursion.npcAiCursor = 0, 0
  excursion.forcedMovementCheckKey = nil -- legacy diagnostic field; no longer allocated per frame
  excursion.forcedMovementCheckMap, excursion.forcedMovementCheckX, excursion.forcedMovementCheckY = nil, nil, nil
  excursion.cyclingBrakeHeld = false
  excursion.forcedMoves, excursion.forcedMoveIndex, excursion.seafoamCurrentLock = nil, 0, false
  excursion.flashActive = false
  excursion.towerPurifiedZone = false
  excursion.safari, excursion.safariEncounter = nil, nil
  excursion.lastInteraction = nil
  -- A Kanto entry may follow a save-slot/new-game replacement.  The reusable
  -- position snapshot is visit-local: discard the prior visit's scalars here so
  -- the validated entry point always performs its one required durable write.
  excursion.positionSnapshot = nil
  excursion.positionDirty = nil
  excursion.positionDirtySteps = 0
  KantoState.FrameCache.release(excursion)
  if FirstPerson and type(FirstPerson.releaseBody) == "function" then
    pcall(FirstPerson.releaseBody)
  end
  Twin.excursionActive = true
  Twin.excursionMap = rec.map and rec.map.id or nil
  Twin.excursionSourceMap = excursion.sourceMapId
  Twin.excursionCellX, Twin.excursionCellY = cx, cy
  Twin.excursionTeleports = (Twin.excursionTeleports or 0) + 1
  do
    local field = region.loaded and region.loaded.field
    local fly = field and (field.flyWarps or field.fly_warps)
    if type(fly) == "table" and type(fly[excursion.sourceMapId]) == "table" then
      local visited = KantoState.table(KantoState.FLY_VISITED_KEY)
      visited[excursion.sourceMapId] = true
      persistenceSet(KantoState.FLY_VISITED_KEY, visited)
    end
  end
  -- Commit the validated/corrected entry point immediately. This also replaces
  -- any legacy/pre-341 Pallet/tree-apron position even if the player quits before using
  -- RETURN TO JOHTO.
  persistExcursionPosition()
  -- RETURN TO JOHTO is an artificial region boundary the cartridge never had.
  -- If a saved Kanto excursion resumes directly on Tower 5F's purified pad,
  -- treat it as a fresh visit so the physical heal/no-battle rule is active
  -- immediately rather than waiting for the next cell crossing.
  if Twin._handleTowerPurifiedZone then
    pcall(Twin._handleTowerPurifiedZone, world, region, excursion.sourceMapId, cx, cy)
  end
  return true
end

function Twin.returnToJohto()
  if not excursion.active then return true end
  persistExcursionPosition()
  -- A Kanto battle loss can invoke Gold's native whiteout on the hidden world.
  -- Put that logical world back where KANTO FREE ROAM started before revealing
  -- it again; save-level consequences (money, party HP/status, flags) remain.
  do
    local world, anchor = excursion.world, excursion.johtoAnchor
    if world and anchor and anchor.mapId and type(world.setMap) == "function" then
      local curId = world.map and (world.map.id or (world.map.def and world.map.def.id))
      local p = world.player
      local moved = curId ~= anchor.mapId or not p
        or tonumber(p.cellX) ~= tonumber(anchor.x) or tonumber(p.cellY) ~= tonumber(anchor.y)
      if moved then
        local ok = pcall(world.setMap, world, anchor.mapId, anchor.x, anchor.y, anchor.facing or "down")
        if ok then Twin.johtoAnchorRestores = (Twin.johtoAnchorRestores or 0) + 1 end
      end
    end
  end
  -- Hard residency boundary: keep only lightweight Yellow source/gameplay data
  -- while Johto is active. Render maps, decoded atlases and actor sheets are
  -- rebuilt lazily on the next KANTO FREE ROAM entry. Drop reusable frame
  -- scratch first so it cannot pin map/actor/GPU references across regions.
  KantoState.FrameCache.release(excursion)
  unloadKantoRenderData(excursion.region)
  excursion.active = false
  excursion.world = nil
  excursion.moving = false
  clearDirectionalBody(false)
  excursion.playerProxy = nil
  excursion.inputProbeRef, excursion.inputProbeFn, excursion.inputProbeTrusted = nil, nil, nil
  excursion.overlayProbeRef, excursion.overlayProbeFn, excursion.overlayProbeTrusted = nil, nil, nil
  excursion.lastTick = nil
  excursion.sourceMapId = nil
  Twin._clearWarpIgnore()
  excursion.randomEncountersEnabled = nil
  excursion.lastOutside = nil
  excursion.standingOnWarp = false
  excursion.prevA = false
  excursion.battleBusy = false
  excursion.trainerEngaging = false
  excursion.strengthActive = false
  excursion.npcAiClock, excursion.npcAiCursor = 0, 0
  excursion.forcedMovementCheckMap, excursion.forcedMovementCheckX, excursion.forcedMovementCheckY = nil, nil, nil
  excursion.flashActive = false
  excursion.towerPurifiedZone = false
  excursion.safari, excursion.safariEncounter = nil, nil
  excursion.johtoAnchor = nil
  excursion.lastInteraction = nil
  if FirstPerson and type(FirstPerson.releaseBody) == "function" then
    pcall(FirstPerson.releaseBody)
  end
  Twin.excursionActive = false
  Twin.excursionMap = nil
  Twin.excursionSourceMap = nil
  Twin.excursionCellX, Twin.excursionCellY = nil, nil
  Twin.excursionReturns = (Twin.excursionReturns or 0) + 1
  KantoState.clearPersistenceCache()
  return true
end

function Twin.toggleTeleport(game)
  if excursion.active then return Twin.returnToJohto() end
  return Twin.teleportToPalletTown(game)
end

local function overlayOpen(world)
  local game = world and world.game
  local stack = game and game.stack
  local fn = stack and type(stack.top) == "function" and stack.top or nil
  if not fn then return false end
  -- The Gold state stack is stable throughout normal play. The old Kanto tick
  -- protected stack:top() on every rendered frame, even after thousands of
  -- successful calls. Probe a new stack/method once, then use the direct path;
  -- replacing either object or method automatically restores the guard.
  if excursion.overlayProbeRef ~= stack or excursion.overlayProbeFn ~= fn then
    excursion.overlayProbeRef, excursion.overlayProbeFn = stack, fn
    local ok, top = pcall(fn, stack)
    excursion.overlayProbeTrusted = ok == true
    Twin.kantoOverlayProbeReads = (Twin.kantoOverlayProbeReads or 0) + 1
    return ok and top ~= nil
  end
  if excursion.overlayProbeTrusted then
    Twin.kantoOverlayFastCalls = (Twin.kantoOverlayFastCalls or 0) + 1
    return fn(stack) ~= nil
  end
  local ok, top = pcall(fn, stack)
  return ok and top ~= nil
end
Twin._overlayOpen = overlayOpen

local function inputDown(input, key)
  if not input then return false end
  local fn = type(input.isDown) == "function" and input.isDown
    or type(input.down) == "function" and input.down or nil
  if not fn then return false end
  -- The Gold input object is stable for an excursion. Validate a newly-seen
  -- object/method once, then call it directly on subsequent button probes. A
  -- third-person frame can ask A/B plus four directions, so repeated protected
  -- calls here were pure frame-time overhead. Replacing/changing the input
  -- object automatically re-arms the defensive probe.
  if excursion.inputProbeRef ~= input or excursion.inputProbeFn ~= fn then
    excursion.inputProbeRef, excursion.inputProbeFn = input, fn
    local ok, value = pcall(fn, input, key)
    excursion.inputProbeTrusted = ok == true
    return ok and value == true
  end
  if excursion.inputProbeTrusted then return fn(input, key) == true end
  local ok, value = pcall(fn, input, key)
  return ok and value == true
end

Twin._inputDown = inputDown

local function saveGet(key, fallback)
  return persistenceGet(key, fallback)
end

local function saveSet(key, value)
  return persistenceSet(key, value)
end

local TRAINER_WINS_KEY = "yellowTrainerWinsV1"
-- A trainer class alone is not enough to prove a Gym battle. Giovanni uses
-- OPP_GIOVANNI in Rocket Hideout B4F, Silph Co 11F and Viridian Gym; only the
-- last of those awards EARTHBADGE. Keep every leader tied to its authored Gym
-- map so a story boss can never leak a Kanto badge into Gold.
local GYM_MAP_BY_CLASS = {
  OPP_BROCK="PEWTER_GYM", OPP_MISTY="CERULEAN_GYM",
  OPP_LT_SURGE="VERMILION_GYM", OPP_ERIKA="CELADON_GYM",
  OPP_KOGA="FUCHSIA_GYM", OPP_SABRINA="SAFFRON_GYM",
  OPP_BLAINE="CINNABAR_GYM", OPP_GIOVANNI="VIRIDIAN_GYM",
}
local GOLD_CLASS_ALIAS = {
  OPP_BROCK="BROCK", OPP_MISTY="MISTY", OPP_LT_SURGE="LT_SURGE",
  OPP_ERIKA="ERIKA", OPP_KOGA="KOGA", OPP_SABRINA="SABRINA",
  OPP_BLAINE="BLAINE", OPP_GIOVANNI="ROCKET_EXECUTIVE",
  OPP_RIVAL1="RIVAL1", OPP_RIVAL2="RIVAL2", OPP_RIVAL3="RIVAL3",
  -- Gold has no Lorelei/Agatha trainer classes, so borrow its Elite Four
  -- presentation classes while keeping Yellow's actual roster/name/money.
  OPP_LORELEI="WILL", OPP_BRUNO="BRUNO", OPP_AGATHA="KAREN", OPP_LANCE="CHAMPION",
}

local function trainerWinId(mapId, obj)
  if type(obj) == "table" and obj._stadiumTrainerWinMap == mapId
      and type(obj._stadiumTrainerWinId) == "string" then
    Twin.kantoTrainerIdCacheHits = (Twin.kantoTrainerIdCacheHits or 0) + 1
    return obj._stadiumTrainerWinId
  end
  local id = tostring(mapId) .. ":" .. tostring(obj and (obj.index or obj.name or obj.x)) .. ":"
    .. tostring(obj and obj.trainerClass or "TRAINER") .. ":" .. tostring(obj and obj.trainerParty or 1)
  if type(obj) == "table" then
    obj._stadiumTrainerWinMap, obj._stadiumTrainerWinId = mapId, id
  end
  Twin.kantoTrainerIdCacheBuilds = (Twin.kantoTrainerIdCacheBuilds or 0) + 1
  return id
end
Twin._trainerWinId = trainerWinId

local function trainerWins()
  local value = saveGet(TRAINER_WINS_KEY, {})
  return type(value) == "table" and value or {}
end

local function trainerDefeated(mapId, obj)
  return trainerWins()[trainerWinId(mapId, obj)] == true
end

local function markTrainerDefeated(mapId, obj)
  local wins = trainerWins()
  wins[trainerWinId(mapId, obj)] = true
  saveSet(TRAINER_WINS_KEY, wins)
end

local function clearTrainerDefeated(mapId, obj)
  local wins = trainerWins()
  local id = trainerWinId(mapId, obj)
  if wins[id] == nil then return false end
  wins[id] = nil
  saveSet(TRAINER_WINS_KEY, wins)
  return true
end
Twin._clearKantoTrainerDefeated = clearTrainerDefeated

local function showMessage(world, text, onDone, opts)
  local game = world and world.game
  if not (game and game.stack and text and text ~= "") then return false end
  local TextBox = mod and mod.ui and mod.ui.TextBox
  if not (TextBox and type(TextBox.new) == "function") then
    local ok, Native = pcall(require, "src.render.TextBox")
    if ok then TextBox = Native end
  end
  if not (TextBox and type(TextBox.new) == "function") then return false end
  local ok, box = pcall(TextBox.new, game, tostring(text), onDone, opts)
  if not ok or not box then return false end
  if type(game.stack.push) == "function" then
    pcall(game.stack.push, game.stack, box)
    return true
  end
  return false
end

Twin._kantoShowMessage = showMessage

local function askYesNo(world, text, onChoice)
  local game = world and world.game
  if not (game and game.stack and text and text ~= "") then return false end
  local TextBox = mod and mod.ui and mod.ui.TextBox
  if not (TextBox and type(TextBox.new) == "function") then
    local ok, Native = pcall(require, "src.render.TextBox")
    if ok then TextBox = Native end
  end
  if not (TextBox and type(TextBox.new) == "function") then return false end
  local ok, box = pcall(TextBox.new, game, tostring(text), nil, {
    choice = function(yes) if onChoice then onChoice(yes == true) end end,
  })
  if not ok or not box then return false end
  game.stack:push(box)
  return true
end

local function facingCell(cx, cy, facing)
  if facing == "up" then return cx, cy - 1 end
  if facing == "down" then return cx, cy + 1 end
  if facing == "left" then return cx - 1, cy end
  return cx + 1, cy
end

local function directionFromWorldVector(wx, wz)
  wx, wz = tonumber(wx) or 0, tonumber(wz) or 0
  if math.abs(wx) <= 1e-5 and math.abs(wz) <= 1e-5 then return nil end
  if math.abs(wx) > math.abs(wz) then return wx > 0 and "right" or "left" end
  return wz > 0 and "down" or "up"
end
Twin._directionFromWorldVector = directionFromWorldVector

-- Current Gen1Recomp runs ExtraWarpCheck on a completed step when the d-pad
-- is still held. FIRST/THIRD PERSON owns movement outside Input's cardinal
-- state, so ask that controller first and fall back to the engine buttons.
local function directionStillHeld(world, dir)
  if not dir then return false end
  if FirstPerson and type(FirstPerson.driving) == "function" and FirstPerson.driving()
      and type(FirstPerson.moveVector) == "function"
      and type(FirstPerson.moveWorld) == "function" then
    local mx, mz = FirstPerson.moveVector()
    local wx, wz = FirstPerson.moveWorld(mx or 0, mz or 0)
    if math.abs(tonumber(wx) or 0) > 1e-5 or math.abs(tonumber(wz) or 0) > 1e-5 then
      return directionFromWorldVector(wx, wz) == dir
    end
  end
  local input = world and world.game and world.game.input
  return inputDown(input, dir)
end

local function objectAt(region, mapId, map, cx, cy)
  local entity = npcAt(region, mapId, cx, cy)
  if entity and entity.def then return entity.def, entity end
  local def = map and map.def
  for _, obj in ipairs((def and def.objects) or {}) do
    local visible = (obj.hidden ~= true or KantoState.objectShown(mapId, obj))
      and not KantoState.objectHidden(mapId, obj)
    if visible and not KantoState.isBoulder(obj)
        and not (obj.item and itemAlreadyPicked and itemAlreadyPicked(mapId, obj))
        and not (obj.pokemon and staticPokemonCleared
          and staticPokemonCleared(mapId, obj))
        and tonumber(obj.x) == cx and tonumber(obj.y) == cy then
      return obj, nil
    end
  end
  return nil, nil
end
Twin._objectAtForTest = objectAt

local function sourceMapDef(region, mapId)
  return region and region.loaded and region.loaded.maps and region.loaded.maps[mapId] or nil
end

local function mapPointerTable(region, mapId)
  local loaded = region and region.loaded
  local all = loaded and loaded.textPointers
  if type(all) ~= "table" then return nil end
  local def = sourceMapDef(region, mapId)
  local label = def and def.label
  return (label and all[label]) or all[mapId] or nil
end

-- Object/sign map data stores TEXT_* constants. text_pointers.lua resolves
-- those constants to the actual _TextLabel plus safe TX_SCRIPT markers such
-- as mart/nurse/pc. Story/cutscene text_asm entries are intentionally refused.
local function interactionInfo(region, mapId, textConst)
  if not textConst then return nil end
  local pointers = mapPointerTable(region, mapId)
  local info = pointers and pointers[textConst] or nil
  if type(info) ~= "table" then
    -- Old caches occasionally exposed the real text label directly.
    local direct = region and region.loaded and region.loaded.text
      and region.loaded.text[textConst]
    return direct and { text = textConst, direct = true } or nil
  end
  return info
end

local function interactionText(region, mapId, textConst)
  local loaded = region and region.loaded
  local info = interactionInfo(region, mapId, textConst)
  if not (loaded and info) then return nil, info end
  local label = info.text
  local body = label and loaded.text and loaded.text[label] or nil
  if not body and info.direct then body = loaded.text and loaded.text[textConst] end
  -- v0.3.53: text_asm is no longer thrown away here.  The caller routes it
  -- through KantoDialogue's detached presentation sandbox; any text_far that
  -- accompanies the asm marker is still useful as a safe fallback.
  return body, info
end

function Twin._startStaticPokemonInteraction(world, region, mapId, obj, entity)
  if not (obj and obj.pokemon) then return false end
  local function battle()
    return startYellowWildBattle(world, region, mapId, obj.pokemon,
      tonumber(obj.level) or 2, entity)
  end
  -- Yellow's static encounter text is part of the reveal: Power Plant trap
  -- balls say "Bzzzt!", the legendary birds cry, and Mewtwo says "Mew!" before
  -- the battle. If the imported text body is available, present it first; an
  -- older cache with no body still gets the real battle rather than a dead NPC.
  local body = interactionText(region, mapId, obj.text)
  if body and body ~= "" then
    local shown = showMessage(world, body, battle)
    if shown then return true end
  end
  return battle()
end

local function signAt(map, cx, cy)
  if map and type(map.signAtCell) == "function" then
    local hit = map:signAtCell(cx, cy)
    if hit then return hit end
  end
  for _, sign in ipairs((map and map.def and map.def.signs) or {}) do
    if tonumber(sign.x) == cx and tonumber(sign.y) == cy then return sign end
  end
  return nil
end

local function itemPickId(mapId, obj)
  return tostring(mapId) .. ":" .. tostring(obj.index or obj.name or (tostring(obj.x)..","..tostring(obj.y)))
end

local function pickedItems()
  local value = persistenceGet(PICKED_ITEMS_KEY, {})
  return type(value) == "table" and value or {}
end

itemAlreadyPicked = function(mapId, obj)
  return pickedItems()[itemPickId(mapId, obj)] == true
end

local function markItemPicked(mapId, obj)
  local value = pickedItems()
  value[itemPickId(mapId, obj)] = true
  persistenceSet(PICKED_ITEMS_KEY, value)
end

local function staticPokemonId(mapId, obj)
  return tostring(mapId) .. ":" .. tostring(obj and (obj.index or obj.name) or "?")
end

local function staticPokemonProgress()
  local value = persistenceGet(STATIC_POKEMON_KEY, {})
  return type(value) == "table" and value or {}
end

staticPokemonCleared = function(mapId, obj)
  return staticPokemonProgress()[staticPokemonId(mapId, obj)] == true
end

markStaticPokemonCleared = function(mapId, obj)
  local value = staticPokemonProgress()
  value[staticPokemonId(mapId, obj)] = true
  persistenceSet(STATIC_POKEMON_KEY, value)
end

Twin._markStaticPokemonCleared = function(mapId, obj)
  if markStaticPokemonCleared then return markStaticPokemonCleared(mapId, obj) end
  return false
end

local function pushScreen(game, screen)
  if game and game.stack and screen and type(game.stack.push) == "function" then
    game.stack:push(screen)
    return true
  end
  return false
end

local function openYellowMart(world, info)
  local game = world and world.game
  if not (game and info and type(info.mart) == "table") then return false end
  local okMart, MartMenu = pcall(require, "src.ui.gen2.MartMenu")
  if not okMart or type(MartMenu) ~= "table" or type(MartMenu.new) ~= "function" then
    return showMessage(world, "The MART is unavailable on this build.")
  end
  local items = game.data and game.data.items or {}
  local stock = {}
  local yellowItems = excursion.region and excursion.region.loaded and excursion.region.loaded.items
  for _, id in ipairs(info.mart) do
    local resolved, mode = KantoState.Items.resolveGoldItem(items, yellowItems, id)
    if resolved then
      stock[#stock + 1] = resolved
      if mode == "machine" then
        Twin.yellowSemanticItemConversions = (Twin.yellowSemanticItemConversions or 0) + 1
      end
    end
  end
  if #stock == 0 then return showMessage(world, "This MART has no compatible stock.") end
  local screen
  screen = MartMenu.new(game, {
    save = game.save, items = items, marts = { lists = { stock } },
    martType = 0, martId = 0, text = world.text,
    onClose = function()
      if game.stack and game.stack:top() == screen then game.stack:pop() end
    end,
  })
  if pushScreen(game, screen) then
    Twin.yellowMartVisits = (Twin.yellowMartVisits or 0) + 1
    return true
  end
  return false
end

local function healGoldParty(world, counterName)
  counterName = counterName or "yellowCenterHeals"
  if world and type(world.healParty) == "function" then
    local ok = pcall(world.healParty, world)
    if ok then
      Twin[counterName] = (Twin[counterName] or 0) + 1
      return true
    end
  end
  -- Compatibility fallback for older Gen1Recomp builds. Prefer the engine's
  -- canonical HealParty helper so PP-Up-adjusted move PP is restored too; the
  -- final table fallback keeps very old/minimal hosts usable.
  local game = world and world.game
  local party = game and game.save and game.save.party
  if type(party) ~= "table" then return false end
  local healed = false
  local okPokemon, Pokemon = pcall(require, "src.pokemon.Pokemon")
  if okPokemon and type(Pokemon) == "table" and type(Pokemon.heal) == "function" then
    for _, mon in ipairs(party) do
      local ok = pcall(Pokemon.heal, mon)
      healed = ok or healed
    end
  else
    for _, mon in ipairs(party) do
      local maxhp = tonumber(mon.maxHp) or tonumber(mon.maxHP)
        or (mon.stats and tonumber(mon.stats.hp)) or tonumber(mon.hp) or 1
      mon.hp = math.max(1, maxhp)
      mon.status, mon.statusTurns, mon.statusId = nil, nil, nil
      healed = true
    end
  end
  if healed then Twin[counterName] = (Twin[counterName] or 0) + 1 end
  return healed
end

Twin._healGoldParty = healGoldParty

local function useYellowNurse(world)
  local healed = healGoldParty(world)
  if not healed then return false end
  if Twin._rememberKantoCenter then
    pcall(Twin._rememberKantoCenter, excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY)
  end
  return showMessage(world, "Your POKéMON are fighting fit!\fWe hope to see you again!")
end

-- v0.4.00: imported Yellow caches are not guaranteed to preserve the
-- extractor's `nurse=true` TX_SCRIPT marker.  Do not make healing depend on
-- that optional metadata.  A Nurse sprite/text inside an authored Pokemon
-- Center is unambiguously the healing counter and should always route to the
-- Gold party healer.
function Twin._isYellowCenterNurseForTest(mapId, obj, map)
  local id = tostring(mapId or ""):upper()
  local ts = tostring(map and map.def and map.def.tileset or ""):upper()
  local center = id:find("POKECENTER", 1, true)
      or id:find("POKEMON_CENTER", 1, true)
      or ts:find("POKECENTER", 1, true)
  if not center then return false end
  local sprite = tostring(obj and obj.sprite or ""):upper()
  local text = tostring(obj and obj.text or ""):upper()
  local name = tostring(obj and obj.name or ""):upper()
  return sprite:find("NURSE", 1, true) ~= nil
      or text:find("NURSE", 1, true) ~= nil
      or name:find("NURSE", 1, true) ~= nil
end


local function openYellowPc(world)
  local game = world and world.game
  if not game then return false end
  -- Prefer the host Gen-2 PC route so Boxes, Mail, hooks and save behavior are
  -- exactly the same in Yellow Kanto as they are in Johto.
  if type(world.openPc) == "function" then
    local ok, opened = pcall(world.openPc, world, {})
    if ok and opened ~= false then
      Twin.yellowPcOpens = (Twin.yellowPcOpens or 0) + 1
      return true
    end
  end
  local okPc, PcMenu = pcall(require, "src.ui.gen2.PcMenu")
  if not okPc or type(PcMenu) ~= "table" or type(PcMenu.new) ~= "function" then
    return showMessage(world, "The PC is unavailable on this build.")
  end
  local screen
  local ok, built = pcall(PcMenu.new, game, {
    save = game.save, onClose = function()
      if game.stack and game.stack:top() == screen then game.stack:pop() end
    end,
  })
  if not ok or not built then return false end
  screen = built
  if pushScreen(game, screen) then
    Twin.yellowPcOpens = (Twin.yellowPcOpens or 0) + 1
    return true
  end
  return false
end

Twin._openYellowPc = openYellowPc

local function pickupYellowItem(world, region, mapId, obj)
  if not (obj and obj.item) or itemAlreadyPicked(mapId, obj) then return false end
  local game = world and world.game
  local save = game and game.save
  if not (save and game.data) then return false end
  save.inventory = save.inventory or {}
  local itemId = tostring(obj.item)

  -- Gen-1-only/conflicting key items live in the Kanto companion namespace.
  -- In particular, Yellow's CARD_KEY must never become Gold's Radio Tower
  -- CARD_KEY merely because the constants share a name.
  if KantoState.Items.isLocalOnly(itemId) then
    if not KantoState.giveLocalItem(itemId) then return false end
    markItemPicked(mapId, obj)
    region.npcCache[mapId] = nil
    KantoState.Spatial.invalidate(region, mapId, true, false)
    Twin.yellowItemsPicked = (Twin.yellowItemsPicked or 0) + 1
    local fossil = KantoState.Items.fossil(itemId)
    if fossil then Twin.yellowFossilsTaken = (Twin.yellowFossilsTaken or 0) + 1 end
    return showMessage(world, "Found " .. tostring((fossil and fossil.display)
      or itemId:gsub("_", " ")) .. "!")
  end

  local yellowItems = region and region.loaded and region.loaded.items
  local goldId, mode, move = KantoState.Items.resolveGoldItem(game.data.items, yellowItems, itemId)
  if not goldId then
    local label = itemId:gsub("_", " ")
    if mode == "no-machine" and move then
      return showMessage(world, label .. " teaches " .. tostring(move):gsub("_", " ")
        .. ", but Gold has no equivalent TM/HM. The item was left here.")
    end
    return showMessage(world, label .. " has no safe Gold item equivalent yet. The item was left here.")
  end
  local okBag, Bag = pcall(require, "src.inventory.Bag")
  if not okBag or type(Bag) ~= "table" or type(Bag.add) ~= "function" then return false end
  local added = Bag.add(save, goldId, 1, game.data)
  if not added then return showMessage(world, "Your PACK can't hold this item.") end
  markItemPicked(mapId, obj)
  region.npcCache[mapId] = nil
  KantoState.Spatial.invalidate(region, mapId, true, false)
  Twin.yellowItemsPicked = (Twin.yellowItemsPicked or 0) + 1
  if mode == "machine" then Twin.yellowSemanticItemConversions = (Twin.yellowSemanticItemConversions or 0) + 1 end
  local def = game.data.items and game.data.items[goldId]
  return showMessage(world, "Found " .. tostring((def and def.name) or goldId) .. "!")
end

local GYM_BADGE = {
  OPP_BROCK="BOULDER", OPP_MISTY="CASCADE", OPP_LT_SURGE="THUNDER",
  OPP_ERIKA="RAINBOW", OPP_KOGA="SOUL", OPP_SABRINA="MARSH",
  OPP_BLAINE="VOLCANO", OPP_GIOVANNI="EARTH",
}
local KANTO_BADGE_ORDER = {
  "BOULDER", "CASCADE", "THUNDER", "RAINBOW",
  "SOUL", "MARSH", "VOLCANO", "EARTH",
}

function KantoState.kantoBadgeOwned(world, token)
  local name = tostring(token or ""):gsub("BADGE$", "")
  local badges = world and world.game and world.game.save and world.game.save.player
    and world.game.save.player.kantoBadges
  if type(badges) ~= "table" then return false end
  if badges[name] == true then return true end
  for i, badge in ipairs(KANTO_BADGE_ORDER) do
    if badge == name then return badges[i] == true end
  end
  return false
end

function KantoState.hasKantoFieldBadge(world, moveId)
  local required = KantoState.SafariProgress.requiredBadge(moveId)
  if not required then return true, nil end
  return KantoState.kantoBadgeOwned(world, required), required
end
Twin._kantoFieldBadgeForTest = KantoState.hasKantoFieldBadge

local function awardGymBadge(world, trainerClass)
  local badge = GYM_BADGE[trainerClass]
  local player = world and world.game and world.game.save and world.game.save.player
  if not (badge and player) then return nil end
  player.kantoBadges = player.kantoBadges or {}
  player.kantoBadges[badge] = true
  for index, name in ipairs(KANTO_BADGE_ORDER) do
    if name == badge then player.kantoBadges[index] = true break end
  end
  return badge
end
Twin._awardGymBadge = awardGymBadge

local function trainerHeader(region, mapId, obj)
  if type(obj) == "table" and obj._stadiumTrainerHeaderMap == mapId
      and obj._stadiumTrainerHeaderCached == true then
    Twin.kantoTrainerHeaderCacheHits = (Twin.kantoTrainerHeaderCacheHits or 0) + 1
    return obj._stadiumTrainerHeader ~= false and obj._stadiumTrainerHeader or nil
  end
  local all = region and region.loaded and region.loaded.trainerHeaders
  local header
  if type(all) == "table" then
    local def = sourceMapDef(region, mapId)
    local rows = (def and def.label and all[def.label]) or all[mapId]
    header = type(rows) == "table" and rows[tonumber(obj and obj.index) or -1] or nil
  end
  if type(obj) == "table" then
    obj._stadiumTrainerHeaderMap = mapId
    obj._stadiumTrainerHeader = header or false
    obj._stadiumTrainerHeaderCached = true
  end
  Twin.kantoTrainerHeaderCacheBuilds = (Twin.kantoTrainerHeaderCacheBuilds or 0) + 1
  return header
end
Twin._trainerHeader = trainerHeader

local function textByLabel(region, label)
  return label and region and region.loaded and region.loaded.text
    and region.loaded.text[label] or nil
end

-- ROM-free regression hooks for the Yellow free-roam conversion.
Twin._interactionInfo = interactionInfo
Twin._interactionText = interactionText
Twin._staticPokemonCleared = function(mapId, obj)
  return staticPokemonCleared and staticPokemonCleared(mapId, obj) or false
end

local function yellowTrainer(region, world, obj, mapId)
  local all = region and region.loaded and region.loaded.trainers
  local source = all and all[obj.trainerClass]
  if not source then return nil, "Yellow trainer table is unavailable" end
  local parties = source.parties or {}
  local idx = tonumber(obj.trainerParty) or 1
  local party = parties[idx] or parties[idx + 1]
  if not party and idx > 1 then party = parties[idx - 1] end
  if not party then party = parties[1] end
  if not party then return nil, "Yellow trainer party is unavailable" end

  local wanted = GOLD_CLASS_ALIAS[obj.trainerClass]
    or tostring(obj.trainerClass or ""):gsub("^OPP_", "")
  local goldClasses = world and world.game and world.game.data
    and world.game.data.trainers and world.game.data.trainers.classes or {}
  if not goldClasses[wanted] then wanted = "YOUNGSTER" end
  local goldClass = goldClasses[wanted] or {}
  return {
    class = tonumber(goldClass.index) or tonumber(source.index) or 1,
    classId = wanted,
    className = goldClass.name or source.name or wanted,
    id = "YELLOW_" .. tostring(obj.trainerClass) .. "_" .. tostring(idx),
    name = source.name or tostring(obj.trainerClass):gsub("^OPP_", ""),
    baseMoney = tonumber(source.baseMoney) or tonumber(goldClass.baseMoney) or 10,
    roster = deepCopy(party),
    attributes = deepCopy(goldClass.attributes or {}),
    items = deepCopy(goldClass.items or {}),
    _stadiumYellowTrainer = true,
    _stadiumYellowGym = GYM_MAP_BY_CLASS[obj.trainerClass] == tostring(mapId or ""),
  }
end

local function tryYellowSurf(world, map, tx, ty)
  if excursion.forcedBike then
    return showMessage(world, "Cycling is fun!\nForget SURFING!")
  end
  if excursion.surfing or not (map and type(map.isWaterCell) == "function"
      and map:isWaterCell(tx, ty)) then return false end
  local game = world and world.game
  local save = game and game.save
  if not (save and type(save.party) == "table") then return false end
  local okField, FieldMoves = pcall(require, "src.world.gen2.FieldMoves")
  if not okField or type(FieldMoves) ~= "table" then return false end
  local mon = type(FieldMoves.partyMoveUser) == "function"
    and FieldMoves.partyMoveUser(save.party, "SURF", {
      save = save, data = game.data, party = save.party, moveId = "SURF",
    }) or nil
  if not mon then return false end
  local hasBadge = KantoState.hasKantoFieldBadge(world, "SURF")
  if not hasBadge then
    return showMessage(world, "Sorry! The SOUL BADGE\nis required.")
  end
  return askYesNo(world, "The water is calm.\nWant to SURF?", function(yes)
    if not yes then return end
    excursion.surfing = true
    excursion.biking, excursion.forcedBike = false, false
    Twin.yellowSurfStarts = (Twin.yellowSurfStarts or 0) + 1
    persistExcursionPosition()
  end)
end

Twin._tryYellowSurf = tryYellowSurf

local KantoGameplay = {
  OPPOSITE_DIR = { up = "down", down = "up", left = "right", right = "left" },
  DIR_DELTA = { up = {0, -1}, down = {0, 1}, left = {-1, 0}, right = {1, 0} },
}
local NPC_WANDER_DIRS = { "up", "right", "down", "left" }

local function leagueBossObject(region, mapId)
  local room = KantoState.League.room(mapId)
  local def = sourceMapDef(region, mapId)
  if not (room and def) then return nil end
  for _, obj in ipairs(def.objects or {}) do
    if tostring(obj.trainerClass or "") == tostring(room.class or "")
        or tostring(obj.text or "") == tostring(room.text or "") then
      return obj
    end
  end
  return nil
end
Twin._kantoLeagueBossObject = leagueBossObject

function KantoGameplay.resetLeagueRun(region)
  local L = KantoState.League
  local changed = false
  for mapId, room in pairs(L.ROOMS or {}) do
    local obj = leagueBossObject(region, mapId)
    if obj then changed = clearTrainerDefeated(mapId, obj) or changed end
    if room.event then changed = KantoState.setEvent(room.event, false) or changed end
    if room.beatEvent then changed = KantoState.setEvent(room.beatEvent, false) or changed end
    if room.lockEvent then changed = KantoState.setEvent(room.lockEvent, false) or changed end
  end
  changed = KantoState.setEvent(L.CHAMPION_EVENT, false) or changed
  changed = KantoState.setEvent(L.START_EVENT, false) or changed

  -- Restore the authored closed/open block state immediately, rather than
  -- waiting for a future re-import. Hall of Fame completion itself is kept.
  for mapId in pairs(L.ROOMS or {}) do
    local def = sourceMapDef(region, mapId)
    if def then KantoState.applyLeagueBlocks(region, mapId, def) end
    local live = region and region.mapsById and region.mapsById[mapId]
    if live then KantoState.restampLeagueMap(region, mapId, live) end
  end
  Twin.yellowLeagueResets = (Twin.yellowLeagueResets or 0) + 1
  return changed
end
Twin._resetKantoLeagueRun = KantoGameplay.resetLeagueRun

function KantoGameplay.leagueWarpBlocked(region, mapId, destId)
  local L = KantoState.League
  return L.blocksRetreat(mapId, destId, KantoState.event(L.START_EVENT), KantoState.event)
end
Twin._kantoLeagueWarpBlocked = KantoGameplay.leagueWarpBlocked

function KantoGameplay.leagueWarpTransition(region, fromMap, destMap)
  local L = KantoState.League
  fromMap, destMap = tostring(fromMap or ""), tostring(destMap or "")
  if fromMap == "INDIGO_PLATEAU_LOBBY" and destMap == "LORELEIS_ROOM" then
    KantoState.setEvent(L.START_EVENT, true)
    Twin.yellowLeagueStarts = (Twin.yellowLeagueStarts or 0) + 1
  end
  return false
end
Twin._kantoLeagueWarpTransition = KantoGameplay.leagueWarpTransition

function KantoGameplay.afterLeagueTrainerWin(region, mapId, obj, physicalEvent)
  local L = KantoState.League
  local room = L.room(mapId)
  if not room then return false end
  -- Only the room's one authored boss can advance the League.
  if tostring(obj and obj.trainerClass or "") ~= tostring(room.class or "")
      and tostring(obj and obj.text or "") ~= tostring(room.text or "") then
    return false
  end
  if physicalEvent and tostring(physicalEvent) ~= tostring(room.event) then return false end
  KantoState.setEvent(room.event, true)
  if room.beatEvent then KantoState.setEvent(room.beatEvent, true) end
  local live = ensureForeignMap(region, mapId)
  if live then KantoState.restampLeagueMap(region, mapId, live) end
  Twin.yellowEliteFourWins = (Twin.yellowEliteFourWins or 0) + 1
  return true
end
Twin._afterKantoLeagueTrainerWin = KantoGameplay.afterLeagueTrainerWin

function KantoGameplay.kantoRivalChampionParty()
  local L = KantoState.League
  return L.rivalParty(saveGet(L.RIVAL_KEY, L.DEFAULT_RIVAL_PARTY))
end
Twin._kantoRivalChampionParty = KantoGameplay.kantoRivalChampionParty

function KantoGameplay.finishKantoHallOfFame(world, region)
  KantoGameplay.resetLeagueRun(region)
  local x, y = Twin._palletStart(region)
  if x ~= nil then
    KantoGameplay.relocate(region, KantoState.League.HALL.returnMap, x, y,
      KantoState.League.HALL.returnFacing, { id = "PALLET_TOWN", x = x, y = y })
  end
  Twin.yellowHallOfFameFinishes = (Twin.yellowHallOfFameFinishes or 0) + 1
  return true
end

function KantoGameplay.startKantoHallOfFame(world, region)
  local game, save = world and world.game, world and world.game and world.game.save
  if not (game and save) then return false end
  local L = KantoState.League
  local oldSpawn = save.spawnAfterChampion
  local entry
  local okCore, Core = pcall(require, "src.core.gen2.HallOfFame")
  if okCore and Core and type(Core.induct) == "function" then
    local ok, row = pcall(Core.induct, save, save.party or {})
    if ok then entry = row end
    -- This is Yellow's parallel League inside the Kanto excursion. Keep the
    -- Gold Hall-of-Fame record/count, but do not hijack Gold's own next-boot
    -- SPAWN_LANCE byte if another campaign has one pending.
    save.spawnAfterChampion = oldSpawn
  end
  KantoState.setEvent(L.HOF_EVENT, true)
  Twin.yellowHallOfFameInductions = (Twin.yellowHallOfFameInductions or 0) + 1

  local function done() KantoGameplay.finishKantoHallOfFame(world, region) end
  local okUI, HallUI = pcall(require, "src.ui.gen2.HallOfFame")
  if entry and okUI and HallUI and type(HallUI.new) == "function"
      and game.stack and type(game.stack.push) == "function" then
    local ok, screen = pcall(HallUI.new, game, {
      mode = "induct", save = save, entry = entry, onDone = done,
    })
    if ok and screen then
      pcall(game.stack.push, game.stack, screen)
      return true
    end
  end
  -- Older host builds without the Gen-2 HOF screen still get the persistent
  -- record/event and a safe return instead of being stranded in the room.
  return done()
end
Twin._startKantoHallOfFame = KantoGameplay.startKantoHallOfFame

function KantoGameplay.championInteraction(world, region, mapId, obj)
  local L, C = KantoState.League, KantoState.League.CHAMPION
  if tostring(mapId or "") ~= C.map then return false end
  if obj and tostring(obj.text or "") ~= tostring(C.text) then return false end
  if KantoState.event(C.event) then
    local after = textByLabel(region, C.after) or "I was looking forward to seeing you again."
    return showMessage(world, after)
  end
  local lance = L.ROOMS.LANCES_ROOM
  if not KantoState.event(lance.beatEvent or lance.event) then return false end
  if excursion.battleBusy then return true end

  local party = KantoGameplay.kantoRivalChampionParty()
  local fake = { trainerClass = C.class, trainerParty = party, text = C.text,
    index = obj and obj.index or "CHAMPION" }
  local trainer, err = yellowTrainer(region, world, fake, mapId)
  if not trainer then
    Twin.lastBattleError = tostring(err)
    return showMessage(world, "Champion data is unavailable. Re-import Pokemon Yellow.")
  end
  local function battle()
    excursion.battleBusy = true
    local ok, started = pcall(world.startScriptedBattle, world, trainer, nil, function(outcome)
      excursion.battleBusy = false
      excursion.prevA = false
      if outcome == "win" or outcome == true then
        KantoState.setEvent(C.event, true)
        Twin.yellowChampionWins = (Twin.yellowChampionWins or 0) + 1
        local after = textByLabel(region, C.after) or "I hate to admit it, but you are the new champion!"
        local oak = textByLabel(region, C.oakCongrats) or "Congratulations! You are the new POKEMON LEAGUE champion!"
        local come = textByLabel(region, C.oakCome) or "Come with me."
        showMessage(world, after, function()
          showMessage(world, oak, function()
            showMessage(world, come, function()
              KantoGameplay.relocate(region, C.hallMap, C.hallX, C.hallY, C.hallFacing,
                excursion.lastOutside)
              local hallText = textByLabel(region, L.HALL.oakText)
              if hallText then
                showMessage(world, hallText, function()
                  KantoGameplay.startKantoHallOfFame(world, region)
                end)
              else
                KantoGameplay.startKantoHallOfFame(world, region)
              end
            end)
          end)
        end)
      elseif outcome == "lose" and Twin._handleKantoBattleLoss then
        pcall(Twin._handleKantoBattleLoss, world)
      end
    end)
    if not ok or started == false then
      excursion.battleBusy = false
      Twin.lastBattleError = "Champion battle could not start"
      return false
    end
    return true
  end
  local intro = textByLabel(region, C.intro) or "I am the most powerful trainer in the world!"
  if showMessage(world, intro, battle) then return true end
  return battle()
end
Twin._kantoChampionInteraction = KantoGameplay.championInteraction

function KantoGameplay.handleLeagueStep(world, region, mapId, x, y)
  local L = KantoState.League
  if not KantoState.event(L.START_EVENT) then return false end
  -- Yellow closes Lance's entrance only after the player has crossed into the
  -- room proper. Do not close it on map load: that would put the door in front
  -- of a manually-driven player before they can traverse the long hallway.
  local lance = L.ROOMS.LANCES_ROOM
  if tostring(mapId or "") == "LANCES_ROOM" and tonumber(y) and tonumber(y) <= 10
      and not KantoState.event(lance.lockEvent) then
    KantoState.setEvent(lance.lockEvent, true)
    local live = ensureForeignMap(region, mapId)
    if live then KantoState.restampLeagueMap(region, mapId, live) end
    Twin.yellowLanceDoorLocks = (Twin.yellowLanceDoorLocks or 0) + 1
  end
  if L.championStep(mapId, x, y) and not KantoState.event(L.CHAMPION_EVENT) then
    local def = sourceMapDef(region, mapId)
    local rival
    for _, obj in ipairs(def and def.objects or {}) do
      if tostring(obj.text or "") == tostring(L.CHAMPION.text) then rival = obj break end
    end
    return KantoGameplay.championInteraction(world, region, mapId, rival)
  end
  return false
end
Twin._handleKantoLeagueStep = KantoGameplay.handleLeagueStep

function KantoGameplay.handleTowerPurifiedZone(world, region, mapId, x, y)
  local onPad, entered = KantoState.Tower.step(excursion, mapId, x, y)
  if not onPad then return false end
  Twin.yellowTowerPurifiedSteps = (Twin.yellowTowerPurifiedSteps or 0) + 1
  if not entered then return true end

  healGoldParty(world, "yellowTowerPurifiedHeals")
  local text = textByLabel(region, KantoState.Tower.TEXT) or KantoState.Tower.FALLBACK_TEXT
  local game = world and world.game
  local function say() showMessage(world, text) end
  if not KantoState.Tower.present(game, say) then say() end
  return true
end
Twin._handleTowerPurifiedZone = KantoGameplay.handleTowerPurifiedZone

function KantoGameplay.playSound(world, id)
  local game = world and world.game
  if not (game and game.data and id) then return false end
  local ok, Sound = pcall(require, "src.core.Sound")
  if not (ok and Sound and type(Sound.play) == "function") then return false end
  return pcall(Sound.play, game.data, id) == true
end

-- v0.3.36 story-free Kanto activities.  Yellow supplies the authored maps,
-- encounter/trade/slot tables and Game Corner prices; Gold/Silver remains the
-- owner of party, boxes, Pokédex, money, coins and inventory.
KantoGameplay.SAFARI_STEP_MAPS = {
  SAFARI_ZONE_CENTER=true, SAFARI_ZONE_EAST=true, SAFARI_ZONE_NORTH=true,
  SAFARI_ZONE_WEST=true, SAFARI_ZONE_CENTER_REST_HOUSE=true,
  SAFARI_ZONE_EAST_REST_HOUSE=true, SAFARI_ZONE_NORTH_REST_HOUSE=true,
  SAFARI_ZONE_WEST_REST_HOUSE=true, SAFARI_ZONE_SECRET_HOUSE=true,
}
KantoGameplay.TRADE_BY_TEXT = {
  TEXT_ROUTE11GATE2F_YOUNGSTER=1,
  TEXT_ROUTE2TRADEHOUSE_GAMEBOY_KID=2,
  TEXT_CINNABARLABFOSSILROOM_SCIENTIST2=4,
  TEXT_ROUTE18GATE2F_YOUNGSTER=6,
  TEXT_ROUTE18GATE2F_COOK=6,
  TEXT_CERULEANTRADEHOUSE_GAMBLER=7,
  TEXT_CINNABARLABTRADEROOM_GRAMPS=8,
  TEXT_CINNABARLABTRADEROOM_BEAUTY=9,
  TEXT_UNDERGROUNDPATHROUTE5_LITTLE_GIRL=10,
}
KantoGameplay.ROD_GIVERS = {
  TEXT_VERMILIONOLDRODHOUSE_FISHING_GURU="OLD_ROD",
  TEXT_FUCHSIAGOODRODHOUSE_FISHING_GURU="GOOD_ROD",
  TEXT_ROUTE12SUPERRODHOUSE_FISHING_GURU="SUPER_ROD",
}
KantoGameplay.PRIZE_WINDOWS = {
  {
    {kind="mon", species="ABRA", level=15, cost=230},
    {kind="mon", species="VULPIX", level=18, cost=1000},
    {kind="mon", species="WIGGLYTUFF", level=22, cost=2680},
  },
  {
    {kind="mon", species="SCYTHER", level=30, cost=6500},
    {kind="mon", species="PINSIR", level=30, cost=6500},
    {kind="mon", species="PORYGON", level=26, cost=9999},
  },
  {
    {kind="item", item="TM_DRAGON_RAGE", cost=3300},
    {kind="item", item="TM_HYPER_BEAM", cost=5500},
    {kind="item", item="TM_SUBSTITUTE", cost=7700},
  },
}
KantoGameplay.PRIZE_TEXT = {
  TEXT_GAMECORNERPRIZEROOM_PRIZE_VENDOR_1=1,
  TEXT_GAMECORNERPRIZEROOM_PRIZE_VENDOR_2=2,
  TEXT_GAMECORNERPRIZEROOM_PRIZE_VENDOR_3=3,
}
KantoGameplay.SLOT_PAYOUT = { ["7"]=300, BAR=100, CHERRY=8,
  MOUSE=15, FISH=15, BIRD=15 }
KantoGameplay.SLOT_LINES = {
  {0,1,2, bet=3}, {2,1,0, bet=3}, {2,2,2, bet=2},
  {0,0,0, bet=2}, {1,1,1, bet=1},
}

KantoGameplay.Dialogue = V.require("KantoDialogue")

function KantoGameplay.isSafariStepMap(mapId)
  return KantoGameplay.SAFARI_STEP_MAPS[tostring(mapId or "")] == true
end

function KantoGameplay.listMenu(world, title, items, onChoose, footer)
  local game = world and world.game
  local ListMenu = mod and mod.ui and mod.ui.ListMenu
  if not (game and game.stack and ListMenu and type(ListMenu.new) == "function") then return false end
  local menu
  local ok, built = pcall(ListMenu.new, game, title, items, {
    pageJump = true,
    footer = footer,
    onChoose = function(item, m)
      if onChoose then onChoose(item, m or menu) end
    end,
  })
  if not ok or not built then return false end
  menu = built
  game.stack:push(menu)
  return true
end

function KantoGameplay.storageHasRoom(world)
  local save = world and world.game and world.game.save
  if not save then return false end
  save.party = save.party or {}
  if #save.party < 6 then return true end
  local okBoxes, Boxes = pcall(require, "src.core.gen2.Boxes")
  if not (okBoxes and Boxes and type(Boxes.isFull) == "function") then return false end
  return not Boxes.isFull(save, save.currentBox or 1)
end

function KantoGameplay.storeGoldMon(world, mon)
  local game = world and world.game
  local save = game and game.save
  if not (save and mon) then return false, "Gen-2 storage is unavailable." end
  -- Catches, prizes and Kanto gifts become genuine Gold-owned party records.
  -- In-game trades mark `traded` and keep their foreign OT, so never restamp
  -- that path.  Current Gen1Recomp exposes this as Mon.stampOT; older hosts
  -- simply skip the optional normalization and retain their existing record.
  if mon.traded ~= true then
    local okMon, Mon = pcall(require, "src.battle.gen2.Mon")
    if okMon and type(Mon) == "table" and type(Mon.stampOT) == "function" then
      local okStamp = pcall(Mon.stampOT, save, mon)
      if okStamp then Twin.yellowGoldOtStamps = (Twin.yellowGoldOtStamps or 0) + 1 end
    end
  end
  save.party = save.party or {}
  local where
  if #save.party < 6 then
    save.party[#save.party + 1] = mon
    where = "party"
  else
    local okBoxes, Boxes = pcall(require, "src.core.gen2.Boxes")
    if not (okBoxes and Boxes and type(Boxes.box) == "function"
        and not Boxes.isFull(save, save.currentBox or 1)) then
      return false, "Your party and current BOX are full."
    end
    local box = Boxes.box(save, save.currentBox or 1)
    box[#box + 1] = mon
    where = Boxes.name and Boxes.name(save, save.currentBox or 1) or "BOX"
  end
  save.pokedex = save.pokedex or { seen = {}, caught = {} }
  save.pokedex.seen = save.pokedex.seen or {}
  save.pokedex.caught = save.pokedex.caught or {}
  save.pokedex.seen[mon.species] = true
  save.pokedex.caught[mon.species] = true
  return true, where
end

Twin._storeGoldMon = KantoGameplay.storeGoldMon

function KantoGameplay.goldPikachuHappiness(world)
  local save = world and world.game and world.game.save
  if not save then return 0 end
  -- Compatibility with a Yellow-origin save bridge: current Yellow stores the
  -- follower value directly.  Normal Gold has per-mon happiness, so use the
  -- happiest PIKACHU in the actual party and do not substitute another lead.
  local legacy = tonumber(save.pikachuHappiness)
  if legacy then return math.max(0, math.min(255, math.floor(legacy))) end
  local best = 0
  for _, mon in ipairs(save.party or {}) do
    if tostring(mon and mon.species or "") == "PIKACHU" then
      best = math.max(best, tonumber(mon.happiness) or 0)
    end
  end
  return math.max(0, math.min(255, math.floor(best)))
end
Twin._kantoPikachuHappiness = KantoGameplay.goldPikachuHappiness

function KantoGameplay.makeGoldGift(world, spec)
  local game = world and world.game
  if not (game and game.data and spec and spec.species) then return nil end
  local okMon, Mon = pcall(require, "src.battle.gen2.Mon")
  if not (okMon and type(Mon) == "table" and type(Mon.new) == "function") then return nil end
  -- Gen 2 initializes gifts/hatched Pokemon at 120 happiness; wild captures
  -- start at 70.  This distinction matters immediately for friendship moves
  -- and evolutions after returning to Johto.
  local ok, mon = pcall(Mon.new, game.data, spec.species,
    tonumber(spec.level) or 10, { happiness = 120 })
  return ok and mon or nil
end
Twin._makeKantoGoldGift = KantoGameplay.makeGoldGift

function KantoGameplay.starterGiftFallback(spec, kind)
  local id = tostring(spec and spec.id or "POKEMON")
  local text = {
    storage = "You have no room for another POKéMON.",
    build = "Gen-2 host couldn't create that gift POKéMON.",
  }
  if kind == "received" then return "Received " .. id .. "!" end
  if spec and spec.id == "BULBASAUR" then
    if kind == "intro" then return "I take care of injured POKéMON.BULBASAUR needs a trainer it can trust." end
    if kind == "ask" then return "Your PIKACHU looks happy.Would you take care of BULBASAUR?" end
    if kind == "declined" then return "Oh... I hope you'll change your mind." end
    if kind == "after" then return "How is BULBASAUR doing?" end
  elseif spec and spec.id == "CHARMANDER" then
    if kind == "ask" then return "This CHARMANDER needs a good trainer.Will you take care of it?" end
    if kind == "declined" then return "Oh... Please come back if you change your mind." end
    if kind == "after" then return "How is CHARMANDER doing?" end
  elseif spec and spec.id == "SQUIRTLE" then
    if kind == "locked" then return "This SQUIRTLE needs a good trainer.Come back when you've earned the THUNDERBADGE." end
    if kind == "ask" then return "You have the THUNDERBADGE!Will you take care of SQUIRTLE?" end
    if kind == "declined" then return "Please come back if you change your mind." end
    if kind == "after" then return "How is SQUIRTLE doing?" end
  end
  return text[kind] or id
end

function KantoGameplay.starterGiftText(region, spec, kind)
  local label = spec and spec.texts and spec.texts[kind]
  return textByLabel(region, label) or KantoGameplay.starterGiftFallback(spec, kind)
end

function KantoGameplay.completeStarterGift(world, region, spec)
  if not KantoGameplay.storageHasRoom(world) then
    Twin.yellowStarterGiftStorageRefusals =
      (Twin.yellowStarterGiftStorageRefusals or 0) + 1
    return showMessage(world, KantoGameplay.starterGiftFallback(spec, "storage"))
  end
  local mon = KantoGameplay.makeGoldGift(world, spec)
  if not mon then return showMessage(world, KantoGameplay.starterGiftFallback(spec, "build")) end
  local stored = KantoGameplay.storeGoldMon(world, mon)
  if not stored then
    Twin.yellowStarterGiftStorageRefusals =
      (Twin.yellowStarterGiftStorageRefusals or 0) + 1
    return showMessage(world, KantoGameplay.starterGiftFallback(spec, "storage"))
  end

  -- Completion is deliberately last: a full box, failed Mon build, or failed
  -- store never consumes the one-time reward.  These events live only in the
  -- Kanto companion namespace and are never copied into Gold story flags.
  KantoState.setEvent(spec.event, true)
  if spec.objectText then KantoState.hideStarterGiftObject(region, spec) end
  Twin.yellowStarterGifts = (Twin.yellowStarterGifts or 0) + 1
  local counter = "yellow" .. tostring(spec.id):sub(1, 1)
    .. tostring(spec.id):sub(2):lower() .. "Gifts"
  Twin[counter] = (Twin[counter] or 0) + 1
  return showMessage(world, KantoGameplay.starterGiftText(region, spec, "received"))
end

function KantoGameplay.starterGift(world, region, spec)
  if not spec then return false end
  if KantoState.event(spec.event) then
    return showMessage(world, KantoGameplay.starterGiftText(region, spec, "after"))
  end

  local function offer()
    return askYesNo(world, KantoGameplay.starterGiftText(region, spec, "ask"), function(yes)
      if yes then
        KantoGameplay.completeStarterGift(world, region, spec)
      else
        showMessage(world, KantoGameplay.starterGiftText(region, spec, "declined"))
      end
    end)
  end

  if spec.id == "BULBASAUR" then
    local happy = KantoGameplay.goldPikachuHappiness(world)
    return showMessage(world, KantoGameplay.starterGiftText(region, spec, "intro"), function()
      if happy >= (tonumber(spec.happiness) or 147) then offer() end
    end)
  end
  if spec.badge and not KantoGameplay.ownsKantoBadge(world, spec.badge) then
    return showMessage(world, KantoGameplay.starterGiftText(region, spec, "locked"))
  end
  return offer()
end
Twin._talkKantoStarterGift = KantoGameplay.starterGift

-- -------------------------------------------------------------------------
-- v0.3.71: story-free Kanto scripted rewards that have an unambiguous Gold
-- representation.  Red/Yellow's hand-ported scripts cannot mutate a Gold save
-- from the detached dialogue sandbox, so these few authored transactions are
-- repeated here against the active Gen-2 inventory/party/box/Pokedex state.

function KantoGameplay.fillRewardText(text, world, subs)
  text, subs = tostring(text or ""), subs or {}
  local save = world and world.game and world.game.save or {}
  local player = save.player and save.player.name or "GOLD"
  text = text:gsub("{PLAYER}", tostring(subs.PLAYER or player))
  text = text:gsub("{RAM:[^}]*}", tostring(subs.RAM or ""))
  text = text:gsub("{NUM:[^}]*}", tostring(subs.NUM or ""))
  return text
end

function KantoGameplay.rewardText(world, region, label, fallback, subs)
  return KantoGameplay.fillRewardText(textByLabel(region, label) or fallback or "", world, subs)
end

function KantoGameplay.markGoldSeen(world, species)
  local save = world and world.game and world.game.save
  if not (save and species) then return false end
  save.pokedex = save.pokedex or { seen = {}, caught = {} }
  save.pokedex.seen = save.pokedex.seen or {}
  save.pokedex.seen[species] = true
  return true
end

function KantoGameplay.rewardItemCount(save, itemId)
  local inv = save and save.inventory
  if type(inv) ~= "table" or not itemId then return 0 end
  local value = inv[itemId]
  if value == true then return 1 end
  if type(value) == "number" then return math.max(0, math.floor(value)) end
  if type(value) == "table" then return math.max(0, math.floor(tonumber(value.count) or 0)) end
  return 0
end

function KantoGameplay.resolveRewardItem(game, reward)
  return KantoState.Rewards.resolveItem(game and game.data, reward)
end

function KantoGameplay.hasUniqueReward(game, save, reward)
  if not (reward and reward.unique) then return false end
  local id = KantoGameplay.resolveRewardItem(game, reward)
  return id ~= nil and KantoGameplay.rewardItemCount(save, id) > 0
end

function KantoGameplay.rewardBagAdd(game, save, reward)
  local itemId, itemDef = KantoGameplay.resolveRewardItem(game, reward)
  if not itemId then return false, nil, "That reward has no safe Gen-2 equivalent." end
  local okBag, Bag = pcall(require, "src.inventory.Bag")
  if not (okBag and type(Bag) == "table" and type(Bag.add) == "function") then
    return false, itemId, "The Gen-2 PACK is unavailable."
  end
  local ok, added = pcall(Bag.add, save, itemId, 1, game.data)
  if not (ok and added == true) then return false, itemId, "You have no room for it!" end
  return true, itemId, itemDef
end

function KantoGameplay.completeRewardPokemon(world, region, spec)
  if not KantoGameplay.storageHasRoom(world) then
    return showMessage(world, KantoGameplay.rewardText(world, region,
      spec.texts and spec.texts.full, "Your party and current BOX are full."))
  end
  local mon = KantoGameplay.makeGoldGift(world, spec)
  if not mon then return showMessage(world, "Gen-2 host couldn't create that POKéMON.") end
  local stored = KantoGameplay.storeGoldMon(world, mon)
  if not stored then
    return showMessage(world, KantoGameplay.rewardText(world, region,
      spec.texts and spec.texts.full, "Your party and current BOX are full."))
  end
  KantoState.setEvent(spec.event, true)
  if spec.finalEvent then KantoState.setEvent(spec.finalEvent, true) end
  if spec.objectText then KantoState.hideRewardObject(region, spec) end
  Twin.yellowScriptedPokemonRewards = (Twin.yellowScriptedPokemonRewards or 0) + 1
  KantoGameplay.playSound(world, "Get_Key_Item")
  return true
end

function KantoGameplay.scriptedPokemonReward(world, region, spec)
  if KantoState.event(spec.event) then
    if spec.objectText then KantoState.hideRewardObject(region, spec) end
    local label = spec.texts and (KantoState.event("EVENT_BEAT_SILPH_CO_GIOVANNI")
      and spec.texts.saved or spec.texts.after)
    local fallback = spec.id == "MAGIKARP" and "No refunds!" or
      (spec.id == "LAPRAS" and "Please take good care of LAPRAS." or "The POKé BALL is empty.")
    return showMessage(world, KantoGameplay.rewardText(world, region, label, fallback,
      { RAM = spec.species }))
  end

  if spec.mode == "sale" then
    return askYesNo(world, KantoGameplay.rewardText(world, region,
      spec.texts.ask, "I have a deal just for you! MAGIKARP, only ¥500!"), function(yes)
      if not yes then
        showMessage(world, KantoGameplay.rewardText(world, region,
          spec.texts.declined, "No? You won't get a better deal than this!"))
        return
      end
      local save = world.game.save
      local money = KantoState.Rewards.money(save)
      if money < (tonumber(spec.price) or 0) then
        showMessage(world, KantoGameplay.rewardText(world, region,
          spec.texts.noMoney, "You don't have enough money."))
        return
      end
      if not KantoGameplay.storageHasRoom(world) then
        showMessage(world, KantoGameplay.rewardText(world, region,
          spec.texts.full, "Your party and current BOX are full."))
        return
      end
      local mon = KantoGameplay.makeGoldGift(world, spec)
      if not mon then showMessage(world, "Gen-2 host couldn't create MAGIKARP.") return end
      local stored = KantoGameplay.storeGoldMon(world, mon)
      if not stored then
        showMessage(world, KantoGameplay.rewardText(world, region,
          spec.texts.full, "Your party and current BOX are full."))
        return
      end
      -- Charge only after the Pokemon exists in Gold storage.  This preserves
      -- the cart's no-charge-on-full-box behavior and makes the exchange atomic.
      KantoState.Rewards.setMoney(save, money - (tonumber(spec.price) or 0))
      KantoState.setEvent(spec.event, true)
      Twin.yellowMagikarpPurchases = (Twin.yellowMagikarpPurchases or 0) + 1
      KantoGameplay.playSound(world, "Get_Key_Item")
      showMessage(world, KantoGameplay.rewardText(world, region,
        spec.texts.received, "Received MAGIKARP!", { RAM = spec.species }))
    end)
  end

  local function give()
    if not KantoGameplay.completeRewardPokemon(world, region, spec) then return end
    local received = KantoGameplay.rewardText(world, region,
      spec.texts and spec.texts.received, "Received " .. spec.species .. "!",
      { RAM = spec.species })
    local description = spec.texts and spec.texts.description
    return showMessage(world, received, description and function()
      showMessage(world, KantoGameplay.rewardText(world, region, description,
        "Please take good care of " .. spec.species .. "."))
    end or nil)
  end

  if spec.texts and spec.texts.intro then
    return showMessage(world, KantoGameplay.rewardText(world, region,
      spec.texts.intro, "I want you to have this POKéMON."), give)
  end
  return give()
end

function KantoGameplay.dojoReward(world, region, spec)
  if KantoState.event("EVENT_GOT_HITMONLEE") or KantoState.event("EVENT_GOT_HITMONCHAN") then
    return showMessage(world, KantoGameplay.rewardText(world, region,
      "_FightingDojoBetterNotGetGreedyText", "Better not get greedy..."))
  end
  if spec.prerequisite and not KantoState.event(spec.prerequisite) then
    return showMessage(world, "You'll have to beat the master first!")
  end

  -- Retail shows the species' Pokedex entry before asking.  The Gold bridge
  -- always performs the stateful half (mark seen) and then asks; no Gen-2
  -- standalone entry screen is exposed by current Gen1Recomp.
  KantoGameplay.markGoldSeen(world, spec.species)
  return askYesNo(world, KantoGameplay.rewardText(world, region, spec.ask,
    "You want " .. spec.species .. "?"), function(yes)
    if not yes then return end
    if not KantoGameplay.storageHasRoom(world) then
      showMessage(world, KantoGameplay.rewardText(world, region,
        "_BoxIsFullText", "Your party and current BOX are full."))
      return
    end
    if not KantoGameplay.completeRewardPokemon(world, region, spec) then return end
    showMessage(world, ("%s got\n%s!"):format(
      tostring(world.game.save.player and world.game.save.player.name or "GOLD"), spec.species))
  end)
end

function KantoGameplay.oaksAideReward(world, region, spec)
  local game, save = world and world.game, world and world.game and world.game.save
  if not (game and save) then return false end
  local rewardId = KantoGameplay.resolveRewardItem(game, spec.reward)
  if KantoState.event(spec.event) or KantoGameplay.hasUniqueReward(game, save, spec.reward) then
    KantoState.setEvent(spec.event, true) -- migrate an already-owned unique reward
    return showMessage(world, KantoGameplay.rewardText(world, region, spec.repeatText,
      "I already gave you the " .. tostring(spec.reward.display or rewardId or "reward") .. "!"))
  end

  local rewardName = tostring(spec.reward.display or rewardId or "reward")
  local ask = KantoGameplay.rewardText(world, region, "_OaksAideHiText",
    ("Have you caught %d kinds of POKéMON?"):format(spec.threshold),
    { NUM = spec.threshold, RAM = rewardName })
  return askYesNo(world, ask, function(yes)
    if not yes then
      showMessage(world, KantoGameplay.rewardText(world, region,
        "_OaksAideComeBackText", "Come back later!", { NUM = spec.threshold, RAM = rewardName }))
      return
    end
    local owned = KantoState.Rewards.countOwned(save)
    if owned < spec.threshold then
      showMessage(world, KantoGameplay.rewardText(world, region,
        "_OaksAideUhOhText", ("You have only caught %d!"):format(owned),
        { NUM = owned, RAM = rewardName }))
      return
    end
    local added, itemId, why = KantoGameplay.rewardBagAdd(game, save, spec.reward)
    if not added then
      showMessage(world, why or ("No room for the " .. rewardName .. "!"))
      return
    end
    KantoState.setEvent(spec.event, true)
    Twin.yellowOakAideRewards = (Twin.yellowOakAideRewards or 0) + 1
    KantoGameplay.playSound(world, "Get_Key_Item")
    showMessage(world, ("%s got\n%s!"):format(
      tostring(save.player and save.player.name or "GOLD"), rewardName))
  end)
end

function KantoGameplay.scriptedItemGift(world, region, spec)
  local game, save = world and world.game, world and world.game and world.game.save
  if not (game and save) then return false end
  if KantoState.event(spec.event) or KantoGameplay.hasUniqueReward(game, save, spec.reward) then
    if spec.reward.unique then KantoState.setEvent(spec.event, true) end
    return showMessage(world, KantoGameplay.rewardText(world, region,
      spec.texts and spec.texts.after, "You already received it."))
  end
  return showMessage(world, KantoGameplay.rewardText(world, region,
    spec.texts and spec.texts.intro, "I want you to have this."), function()
    local added, itemId, why = KantoGameplay.rewardBagAdd(game, save, spec.reward)
    if not added then
      local full = spec.texts and spec.texts.full
      showMessage(world, full and KantoGameplay.rewardText(world, region, full, why)
        or why or "You have no room for it!")
      return
    end
    KantoState.setEvent(spec.event, true)
    Twin.yellowScriptedItemRewards = (Twin.yellowScriptedItemRewards or 0) + 1
    KantoGameplay.playSound(world, "Get_Key_Item")
    local name = tostring(spec.reward.display or (game.data.items[itemId] and game.data.items[itemId].name) or itemId)
    local received = spec.texts and spec.texts.received
    if received then
      showMessage(world, KantoGameplay.rewardText(world, region, received,
        ("%s got\n%s!"):format(tostring(save.player and save.player.name or "GOLD"), name),
        { RAM = name }))
    else
      showMessage(world, ("%s got\n%s!"):format(
        tostring(save.player and save.player.name or "GOLD"), name))
    end
  end)
end


-- Yellow-only TM bridge. Some Gen-1 TM numbers map to different moves in
-- Gold. Never reinterpret the numeric TM id. Instead, those Yellow rewards
-- create persistent Kanto-local one-use machine credits that teach the exact
-- Yellow move and check the imported Yellow species' original tmhm list.
function KantoGameplay.yellowTmCompatible(region, mon, moveId)
  if not (region and region.loaded and type(region.loaded.pokemon) == "table"
      and mon and moveId) then return false end
  local species = region.loaded.pokemon[tostring(mon.species or "")]
  if type(species) ~= "table" then return false end
  for _, entry in ipairs(species.tmhm or {}) do
    local id = type(entry) == "table" and (entry.move or entry.id or entry.teaches) or entry
    if tostring(id or "") == tostring(moveId) then return true end
  end
  return false
end
Twin._yellowTmCompatibleForTest = KantoGameplay.yellowTmCompatible

function KantoGameplay.monKnowsMove(mon, moveId)
  for _, entry in ipairs(mon and mon.moves or {}) do
    local id = type(entry) == "table" and (entry.id or entry.move) or entry
    if tostring(id or "") == tostring(moveId) then return true end
  end
  return false
end

function KantoGameplay.openLocalTmCredit(world, region, spec)
  local game, save = world and world.game, world and world.game and world.game.save
  if not (game and save and spec and spec.move and spec.creditEvent) then return false end
  if not KantoState.event(spec.creditEvent) then
    return showMessage(world, "That Kanto TM has already been used.")
  end

  local okParty, PartyMenu = pcall(require, "src.ui.gen2.PartyMenu")
  if not (okParty and type(PartyMenu) == "table" and type(PartyMenu.new) == "function"
      and game.stack and type(game.stack.push) == "function") then
    return showMessage(world, "The Gen-2 POKEMON party menu is unavailable.")
  end

  local moveDef = game.data and game.data.moves and game.data.moves[spec.move]
  local moveName = tostring(moveDef and moveDef.name or spec.move):gsub("_", " ")
  local screen
  local ok, built = pcall(PartyMenu.new, game, {
    save = save,
    party = save.party or {},
    prompt = "teach",
    tmhm = { move = spec.move },
    -- The ABLE/NOT ABLE display must use Yellow's compatibility table, not
    -- Gold's TM/HM table, because these three moves are Gen-1-only machines.
    pokemon = region.loaded and region.loaded.pokemon or {},
    moves = game.data and game.data.moves or {},
    onChoose = function(_, mon)
      if not mon then return end
      if not KantoGameplay.yellowTmCompatible(region, mon, spec.move) then
        KantoGameplay.playSound(world, "Denied")
        showMessage(world, ("%s can't learn %s!"):format(
          tostring(mon.nickname or mon.species or "POKEMON"), moveName))
        return
      end
      if KantoGameplay.monKnowsMove(mon, spec.move) then
        showMessage(world, ("%s already knows %s!"):format(
          tostring(mon.nickname or mon.species or "POKEMON"), moveName))
        return
      end
      if type(game.learnMoveOn) ~= "function" then
        showMessage(world, "The Gen-2 move-learning screen is unavailable.")
        return
      end
      game:learnMoveOn(mon, spec.move, function(learned)
        if not learned then return end
        -- The machine is single-use. EVENT_GOT_TMxx remains true because it
        -- records having received the Yellow reward; only the local credit is
        -- consumed when the move is actually learned.
        KantoState.setEvent(spec.creditEvent, false)
        Twin.yellowLocalTmTeaches = (Twin.yellowLocalTmTeaches or 0) + 1
        local explanation = spec.explanationText
        if explanation then
          showMessage(world, KantoGameplay.rewardText(world, region,
            explanation, ("%s learned %s!"):format(
              tostring(mon.nickname or mon.species or "POKEMON"), moveName)))
        end
      end)
    end,
    onCancel = function() end,
  })
  if not ok or not built then
    return showMessage(world, "The Gen-2 POKEMON party menu could not open.")
  end
  screen = built
  game.stack:push(screen)
  return true
end
Twin._openKantoLocalTmCredit = KantoGameplay.openLocalTmCredit


-- v0.3.96: Saffron Copycat parity.
-- Yellow gives TM31 MIMIC only when the player owns a POKE DOLL, then removes
-- exactly one doll and permanently marks EVENT_GOT_TM31. Gold's TM31 is a
-- different move, so the reward is represented with the same local Yellow-TM
-- credit bridge used by the Celadon rooftop rewards.
function KantoGameplay.copycatTrade(world, region, mapId, obj)
  local Rewards = KantoState.Rewards
  if not (Rewards and type(Rewards.isCopycat) == "function"
      and Rewards.isCopycat(mapId, obj and obj.text)) then return false end

  local game, save = world and world.game, world and world.game and world.game.save
  if not (game and save) then return true end
  save.inventory = save.inventory or {}
  local spec = Rewards.COPYCAT

  -- If the Yellow TM was already received, a pending credit can still be
  -- taught later; otherwise Copycat switches permanently to her explanation.
  if KantoState.event(spec.event) then
    if KantoState.event(spec.creditEvent) then
      return showMessage(world, KantoGameplay.rewardText(world, region,
        spec.explanationText,
        "TM31 contains MIMIC!"), function()
          KantoGameplay.openLocalTmCredit(world, region, spec)
        end)
    end
    return showMessage(world, KantoGameplay.rewardText(world, region,
      spec.explanationText, "TM31 contains MIMIC!"))
  end

  local haveDoll = (tonumber(save.inventory[spec.item]) or 0) > 0
  if not haveDoll then
    return showMessage(world, KantoGameplay.rewardText(world, region,
      spec.introText, "Do you like POKEMON too?"))
  end

  return showMessage(world, KantoGameplay.rewardText(world, region,
    spec.preReceiveText,
    "Oh! That's a POKE DOLL! Is that for me?"), function()
      local okBag, Bag = pcall(require, "src.inventory.Bag")
      if not (okBag and type(Bag) == "table") then
        showMessage(world, "The Gen-2 PACK is unavailable.")
        return
      end

      -- The local credit has no PACK slot and therefore cannot collide with
      -- Gold's unrelated TM31. Consume the doll only when the reward state is
      -- successfully created.
      if not KantoGameplay.removeGoldItem(save, spec.item, 1, Bag) then
        showMessage(world, "You don't have a POKE DOLL anymore.")
        return
      end

      KantoState.setEvent(spec.event, true)
      KantoState.setEvent(spec.creditEvent, true)
      Twin.yellowCopycatTrades = (Twin.yellowCopycatTrades or 0) + 1
      KantoGameplay.playSound(world, "Get_Key_Item")
      local received = KantoGameplay.rewardText(world, region,
        spec.receivedText, "Received TM31 MIMIC!",
        { RAM = "TM31" })
      showMessage(world, received, function()
        KantoGameplay.openLocalTmCredit(world, region, spec)
      end)
    end)
end
Twin._talkKantoCopycat = KantoGameplay.copycatTrade

function KantoGameplay.celadonDrinkGirl(world, region, mapId, obj)
  local Rewards = KantoState.Rewards
  if not (Rewards and type(Rewards.isCeladonDrinkGirl) == "function"
      and Rewards.isCeladonDrinkGirl(mapId, obj and obj.text)) then return false end

  local game, save = world and world.game, world and world.game and world.game.save
  if not (game and save) then return true end
  save.inventory = save.inventory or {}
  local cfg = Rewards.CELADON_DRINK_GIRL
  local entries = {}

  local order = { "FRESH_WATER", "SODA_POP", "LEMONADE" }
  for _, drinkId in ipairs(order) do
    local spec = cfg.rewards[drinkId]
    if spec then
      local got = KantoState.event(spec.event)
      local pending = KantoState.event(spec.creditEvent)
      if pending then
        entries[#entries + 1] = {
          label = "USE " .. tostring(spec.display),
          value = { mode = "credit", spec = spec },
        }
      elseif not got and (tonumber(save.inventory[drinkId]) or 0) > 0 then
        local def = game.data and game.data.items and game.data.items[drinkId]
        entries[#entries + 1] = {
          label = "GIVE " .. tostring(def and def.name or drinkId):gsub("_", " "),
          value = { mode = "drink", spec = spec },
        }
      end
    end
  end

  if #entries == 0 then
    local allDone = true
    for _, spec in pairs(cfg.rewards or {}) do
      if not KantoState.event(spec.event) then allDone = false break end
    end
    return showMessage(world, KantoGameplay.rewardText(world, region,
      allDone and cfg.notThirstyText or cfg.thirstyText,
      allDone and "I'm not thirsty anymore." or "I'm thirsty! I want something to drink!"))
  end

  return KantoGameplay.listMenu(world, "THIRSTY GIRL", entries, function(item, menu)
    if menu and type(menu.close) == "function" then menu:close() end
    local value = item and item.value
    local spec = value and value.spec
    if not spec then return end

    if value.mode == "credit" then
      KantoGameplay.openLocalTmCredit(world, region, spec)
      return
    end

    local okBag, Bag = pcall(require, "src.inventory.Bag")
    if not (okBag and type(Bag) == "table") then
      showMessage(world, "The Gen-2 PACK is unavailable.")
      return
    end
    -- Yellow removes the selected drink before GiveItem.  Here the same drink
    -- is consumed before the local machine credit is created, so canceling the
    -- teaching screen never refunds the drink; the earned TM credit persists.
    if not KantoGameplay.removeGoldItem(save, spec.drink, 1, Bag) then
      showMessage(world, "You don't have that drink anymore.")
      return
    end

    KantoState.setEvent(spec.event, true)
    KantoState.setEvent(spec.creditEvent, true)
    Twin.yellowCeladonDrinkRewards = (Twin.yellowCeladonDrinkRewards or 0) + 1
    KantoGameplay.playSound(world, "Get_Key_Item")

    local yay = KantoGameplay.rewardText(world, region, spec.yayText,
      "Yay! Thank you!")
    showMessage(world, yay, function()
      local received = KantoGameplay.rewardText(world, region, spec.receivedText,
        ("Received %s!"):format(tostring(spec.display)),
        { RAM = tostring(spec.id) })
      showMessage(world, received, function()
        KantoGameplay.openLocalTmCredit(world, region, spec)
      end)
    end)
  end)
end
Twin._talkKantoCeladonDrinkGirl = KantoGameplay.celadonDrinkGirl

function KantoGameplay.buyVendingDrink(world, drink)
  local game, save = world and world.game, world and world.game and world.game.save
  if not (game and save and drink and drink.id) then return false end
  local price = tonumber(drink.price) or 0
  local money = KantoState.Rewards.money(save)
  if money < price then return showMessage(world, "Not enough\nmoney.") end
  local def = game.data and game.data.items and game.data.items[drink.id]
  if not def then return showMessage(world, "That drink is unavailable in this Gold cache.") end
  local okBag, Bag = pcall(require, "src.inventory.Bag")
  if not (okBag and type(Bag) == "table" and type(Bag.add) == "function") then
    return showMessage(world, "The Gen-2 PACK is unavailable.")
  end
  local ok, added = pcall(Bag.add, save, drink.id, 1, game.data)
  if not (ok and added == true) then return showMessage(world, "You have no room\nfor it!") end
  -- The item is accepted before money moves, exactly like the hand-ported
  -- vending script.  A full PACK therefore never charges the player.
  KantoState.Rewards.setMoney(save, money - price)
  Twin.yellowVendingPurchases = (Twin.yellowVendingPurchases or 0) + 1
  return showMessage(world, ("%s\npopped out!"):format(tostring(def.name or drink.id)))
end
Twin._buyKantoVendingDrink = KantoGameplay.buyVendingDrink

function KantoGameplay.openKantoVending(world)
  local game = world and world.game
  if not game then return false end
  local items = {}
  for _, drink in ipairs(KantoState.Rewards.VENDING.drinks or {}) do
    local def = game.data and game.data.items and game.data.items[drink.id]
    if def then
      items[#items + 1] = {
        label = ("%s ¥%d"):format(tostring(def.name or drink.id), tonumber(drink.price) or 0),
        value = drink,
      }
    end
  end
  return KantoGameplay.listMenu(world, "VENDING MACHINE", items, function(item, menu)
    if menu and type(menu.close) == "function" then menu:close() end
    if item and item.value then KantoGameplay.buyVendingDrink(world, item.value) end
  end)
end


-- v0.3.97: generic authored Yellow TM gift whose move has no safe Gold TM
-- equivalent. The received event is permanent; the local one-use machine
-- credit survives cancel/incompatible choices until the move is learned.
function KantoGameplay.yellowTmGift(world, region, spec)
  local game, save = world and world.game, world and world.game and world.game.save
  if not (game and save and spec and spec.event and spec.creditEvent and spec.move) then
    return false
  end

  if KantoState.event(spec.event) then
    if KantoState.event(spec.creditEvent) then
      return showMessage(world, KantoGameplay.rewardText(world, region,
        spec.explanationText, tostring(spec.display or spec.move)), function()
          KantoGameplay.openLocalTmCredit(world, region, spec)
        end)
    end
    return showMessage(world, KantoGameplay.rewardText(world, region,
      spec.explanationText, tostring(spec.display or spec.move)))
  end

  return showMessage(world, KantoGameplay.rewardText(world, region,
    spec.introText, "Please take this."), function()
      KantoState.setEvent(spec.event, true)
      KantoState.setEvent(spec.creditEvent, true)
      Twin.yellowStandaloneTmRewards = (Twin.yellowStandaloneTmRewards or 0) + 1
      KantoGameplay.playSound(world, "Get_Key_Item")
      showMessage(world, KantoGameplay.rewardText(world, region,
        spec.receivedText, ("Received %s!"):format(tostring(spec.display or spec.move)),
        { RAM = tostring(spec.display or spec.move) }), function()
          KantoGameplay.openLocalTmCredit(world, region, spec)
        end)
    end)
end
Twin._talkKantoYellowTmGift = KantoGameplay.yellowTmGift

function KantoGameplay.scriptedReward(world, region, spec)
  if not spec then return false end
  if spec.kind == "pokemon" then return KantoGameplay.scriptedPokemonReward(world, region, spec) end
  if spec.kind == "dojo" then return KantoGameplay.dojoReward(world, region, spec) end
  if spec.kind == "aide" then return KantoGameplay.oaksAideReward(world, region, spec) end
  if spec.kind == "item" then return KantoGameplay.scriptedItemGift(world, region, spec) end
  if spec.kind == "yellow_tm" then return KantoGameplay.yellowTmGift(world, region, spec) end
  if spec.kind == "vending" then return KantoGameplay.openKantoVending(world) end
  return false
end
Twin._talkKantoScriptedReward = KantoGameplay.scriptedReward

-- v0.3.91: Yellow Safari Zone mainline rewards. Gold Teeth remain a
-- Kanto-local key item; HM03/HM04 are genuine Gold HMs resolved by move.
function KantoGameplay.wardenReward(world, region)
  local spec = KantoState.SafariProgress.WARDEN
  local game, save = world and world.game, world and world.game and world.game.save
  if not (spec and game and save) then return false end

  local function text(label, fallback, subs)
    return KantoGameplay.rewardText(world, region, label, fallback, subs)
  end

  if KantoState.event(spec.hmEvent) then
    return showMessage(world, text(spec.texts.after,
      "WARDEN: HM04 teaches STRENGTH!"))
  end

  local gave = KantoState.event(spec.gaveEvent)
  local haveTeeth = KantoState.itemHeld(world, spec.teethItem)
  if not gave and not haveTeeth then
    return showMessage(world, text(spec.texts.gibberish,
      "WARDEN: Hif fuff hefifoo!"))
  end

  local function giveStrength()
    -- Cross-generation migration: Gold may already own its native Strength HM.
    -- Yellow still requires returning the teeth, but never duplicates the HM.
    if KantoGameplay.hasUniqueReward(game, save, spec.reward) then
      KantoState.setEvent(spec.hmEvent, true)
      return showMessage(world, text(spec.texts.after,
        "WARDEN: HM04 teaches STRENGTH!"))
    end
    local added, itemId, why = KantoGameplay.rewardBagAdd(game, save, spec.reward)
    if not added then
      return showMessage(world, text(spec.texts.full, why or "Your PACK is stuffed full!"))
    end
    KantoState.setEvent(spec.hmEvent, true)
    Twin.yellowWardenStrengthRewards = (Twin.yellowWardenStrengthRewards or 0) + 1
    KantoGameplay.playSound(world, "Get_Key_Item")
    local name = tostring(spec.reward.display
      or (game.data.items[itemId] and game.data.items[itemId].name) or itemId)
    return showMessage(world, text(spec.texts.received,
      ("%s got\n%s!"):format(tostring(save.player and save.player.name or "GOLD"), name),
      { RAM = name }))
  end

  local function thankAndGive()
    return showMessage(world, text(spec.texts.thanks,
      "WARDEN: Thanks, kid! Let me give you something for your trouble."), giveStrength)
  end

  if not gave and haveTeeth then
    KantoState.takeLocalItem(spec.teethItem)
    KantoState.setEvent(spec.gaveEvent, true)
    Twin.yellowGoldTeethReturns = (Twin.yellowGoldTeethReturns or 0) + 1
    KantoGameplay.playSound(world, "Get_Key_Item")
    return showMessage(world, text(spec.texts.gave,
      "GOLD gave the GOLD TEETH to the WARDEN!"), thankAndGive)
  end

  -- Yellow removes the teeth before attempting GiveItem. If the PACK was full,
  -- later conversations retry HM04 without asking for the teeth again.
  return thankAndGive()
end
Twin._talkKantoWarden = KantoGameplay.wardenReward

function KantoGameplay.safariCatchAttempt(mon, catchRate, rng)
  rng = rng or randomInt
  local maxHp = math.max(1, tonumber(mon and (mon.maxHp or (mon.stats and mon.stats.hp))) or 1)
  local hp = math.max(1, tonumber(mon and mon.hp) or maxHp)
  local f = math.min(255, math.floor(math.floor(maxHp * 255 / 12)
    / math.max(1, math.floor(hp / 4))))
  local rate = math.max(0, math.min(255, math.floor(tonumber(catchRate) or 0)))
  local r = rng(0, 150)
  local caught = r <= rate and rng(0, 255) <= f
  if caught then return true, 3 end
  local y = math.floor(rate * 100 / 150)
  local z = y > 255 and 255 or math.floor(f * y / 255)
  local shakes = z < 10 and 0 or (z < 30 and 1 or (z < 70 and 2 or 3))
  return false, shakes
end

function KantoGameplay.safariEnemyFlees(mon, state, rng)
  rng = rng or randomInt
  if (state.baitFactor or 0) > 0 then
    state.baitFactor = state.baitFactor - 1
  elseif (state.escapeFactor or 0) > 0 then
    state.escapeFactor = state.escapeFactor - 1
    if state.escapeFactor == 0 then state.catchRate = state.baseCatchRate end
  end
  local speed = math.floor(tonumber(mon and mon.stats and mon.stats.speed) or 1) % 256
  if speed > 127 then return true end
  local threshold = (speed * 2) % 256
  if (state.baitFactor or 0) > 0 then threshold = math.floor(threshold / 4) end
  if (state.escapeFactor or 0) > 0 then threshold = math.min(255, threshold * 2) end
  return rng(0, 255) < threshold
end

function KantoGameplay.safariGameOver(world, reason)
  if not excursion.safari then return false end
  excursion.safari, excursion.safariEncounter = nil, nil
  excursion.battleBusy = false
  Twin.yellowSafariGames = (Twin.yellowSafariGames or 0) + 1
  local moved = KantoGameplay.relocate(excursion.region, "SAFARI_ZONE_GATE", 4, 3, "down",
    excursion.lastOutside)
  local text = tostring(reason or "PA: Game over!") .. "\fPA: Your SAFARI GAME is over!"
  showMessage(world, text)
  return moved == true
end

function KantoGameplay.safariStep(world)
  local st = excursion.safari
  if not (st and KantoGameplay.isSafariStepMap(excursion.sourceMapId)) then return false end
  st.steps = math.max(0, (tonumber(st.steps) or 0) - 1)
  Twin.yellowSafariSteps = (Twin.yellowSafariSteps or 0) + 1
  if st.steps > 0 then return false end
  KantoGameplay.safariGameOver(world, "PA: Ding-dong!\nTime's up!")
  return true
end

function KantoGameplay.openSafariMenu(world, state)
  if not (excursion.safari and state and excursion.safariEncounter == state) then return false end
  local species = tostring(state.species or "POKéMON")
  local function endEncounter(text, after)
    excursion.battleBusy = false
    excursion.safariEncounter = nil
    local function done()
      if after then after() end
    end
    if not showMessage(world, text, done) then done() end
  end
  local function enemyTurn(prefix)
    local function resolve()
      if not excursion.safari then return end
      if KantoGameplay.safariEnemyFlees(state.mon, state) then
        Twin.yellowSafariFlees = (Twin.yellowSafariFlees or 0) + 1
        endEncounter("Wild " .. species .. " fled!", function()
          if excursion.safari and excursion.safari.balls <= 0 then
            KantoGameplay.safariGameOver(world, "PA: You're out of\nSAFARI BALLs!")
          end
        end)
        return
      end
      if excursion.safari.balls <= 0 then
        excursion.safariEncounter = nil
        excursion.battleBusy = false
        KantoGameplay.safariGameOver(world, "PA: You're out of\nSAFARI BALLs!")
        return
      end
      KantoGameplay.openSafariMenu(world, state)
    end
    if prefix and prefix ~= "" then
      if not showMessage(world, prefix, resolve) then resolve() end
    else resolve() end
  end
  local items = {
    {label="SAFARI BALL", right=tostring(excursion.safari.balls or 0), value="ball"},
    {label="BAIT", value="bait"}, {label="ROCK", value="rock"}, {label="RUN", value="run"},
  }
  return KantoGameplay.listMenu(world, "SAFARI", items, function(item, menu)
    if menu and menu.close then menu:close() end
    local action = item and item.value
    if action == "run" or not action then
      Twin.yellowSafariRuns = (Twin.yellowSafariRuns or 0) + 1
      endEncounter("Got away safely!")
      return
    end
    if action == "ball" then
      if (excursion.safari.balls or 0) <= 0 then
        KantoGameplay.safariGameOver(world, "PA: You're out of\nSAFARI BALLs!")
        return
      end
      if not KantoGameplay.storageHasRoom(world) then
        showMessage(world, "Your party and current BOX are full.", function()
          KantoGameplay.openSafariMenu(world, state)
        end)
        return
      end
      excursion.safari.balls = excursion.safari.balls - 1
      Twin.yellowSafariBallsThrown = (Twin.yellowSafariBallsThrown or 0) + 1
      local caught, shakes = KantoGameplay.safariCatchAttempt(state.mon, state.catchRate)
      if caught then
        local stored = KantoGameplay.storeGoldMon(world, state.mon)
        if stored then
          Twin.yellowSafariCatches = (Twin.yellowSafariCatches or 0) + 1
          endEncounter("Gotcha!\n" .. species .. " was caught!", function()
            if excursion.safari and excursion.safari.balls <= 0 then
              KantoGameplay.safariGameOver(world, "PA: You're out of\nSAFARI BALLs!")
            end
          end)
        else
          enemyTurn("The BOX is full!")
        end
      else
        local fail = shakes >= 3 and "Shoot! It was so close!"
          or (shakes == 2 and "Aww! It appeared to be caught!"
          or (shakes == 1 and "Darn! The POKéMON broke free!" or "The POKéMON broke free!"))
        enemyTurn(fail)
      end
      return
    end
    if action == "bait" then
      state.catchRate = math.floor((state.catchRate or state.baseCatchRate) / 2)
      state.baitFactor = math.min(255, (state.baitFactor or 0) + randomInt(1, 5))
      state.escapeFactor = 0
      enemyTurn("Threw some BAIT.\nWild " .. species .. " is eating!")
      return
    end
    state.catchRate = math.min(255, (state.catchRate or state.baseCatchRate) * 2)
    state.escapeFactor = math.min(255, (state.escapeFactor or 0) + randomInt(1, 5))
    state.baitFactor = 0
    enemyTurn("Threw a ROCK.\nWild " .. species .. " is angry!")
  end)
end

function KantoGameplay.startSafariEncounter(world, region, mapId, species, level, sourceEntity)
  if excursion.battleBusy or not excursion.safari then return false end
  local mon = makeGoldWild(world, species, level)
  if not mon then return false end
  local ydef = region and region.loaded and region.loaded.pokemon and region.loaded.pokemon[species]
  local gdef = world and world.game and world.game.data and world.game.data.pokemon
    and world.game.data.pokemon[species]
  local base = tonumber(ydef and ydef.catchRate) or tonumber(gdef and gdef.catchRate) or 45
  local state = { mon=mon, species=species, level=tonumber(level) or 2,
    baseCatchRate=base, catchRate=base, baitFactor=0, escapeFactor=0,
    mapId=mapId, sourceEntity=sourceEntity }
  excursion.battleBusy = true
  excursion.safariEncounter = state
  Twin.yellowSafariEncounters = (Twin.yellowSafariEncounters or 0) + 1
  local save = world and world.game and world.game.save
  if save then
    save.pokedex = save.pokedex or {seen={}, caught={}}
    save.pokedex.seen = save.pokedex.seen or {}
    save.pokedex.seen[species] = true
  end
  local name = (gdef and gdef.name) or species
  if not showMessage(world, "Wild " .. tostring(name) .. " appeared!", function()
    KantoGameplay.openSafariMenu(world, state)
  end) then
    KantoGameplay.openSafariMenu(world, state)
  end
  return true
end
Twin._startKantoSafariEncounter = KantoGameplay.startSafariEncounter
Twin._safariCatchAttempt = KantoGameplay.safariCatchAttempt
Twin._safariEnemyFlees = KantoGameplay.safariEnemyFlees
Twin._safariStepMaps = KantoGameplay.SAFARI_STEP_MAPS

function KantoGameplay.startSafariGame(world)
  if excursion.safari then return showMessage(world, "Good Luck!") end
  local game = world and world.game
  local save = game and game.save
  if not save then return false end
  save.money = tonumber(save.money) or 0
  return askYesNo(world, "Welcome to the SAFARI ZONE!\fWould you like to join the hunt?", function(yes)
    if not yes then showMessage(world, "Come again!"); return end
    local balls, paid
    if save.money >= 500 then
      save.money = save.money - 500
      balls, paid = 30, "That'll be ¥500 please!"
    elseif save.money > 0 then
      balls = math.min(math.floor(save.money / 23) + 1, 29)
      paid = "Not enough for the full fee.\fI'll take what you have."
      save.money = 0
    else
      excursion.safariNags = (excursion.safariNags or 0) + 1
      if excursion.safariNags < 4 then
        showMessage(world, "You don't have any money.\fCome back when you can pay!")
        return
      end
      balls, paid = 1, "Oh, all right.\fOne SAFARI BALL, on the house."
    end
    excursion.safari = { balls=balls, steps=500 }
    excursion.safariNags = 0
    Twin.yellowSafariAdmissions = (Twin.yellowSafariAdmissions or 0) + 1
    showMessage(world, paid .. "\fYou received " .. tostring(balls) .. " SAFARI BALLs!\fCatch all the POKéMON you can!")
  end)
end

function KantoGameplay.explainSafari(world)
  return askYesNo(world, "Is it your first time here?", function(yes)
    if yes then
      showMessage(world, "Use SAFARI BALLs to catch POKéMON.\fBAIT makes them calmer but harder to catch.\fROCKs make them easier to catch but more likely to flee.")
    else
      showMessage(world, "Sorry, you're a regular here!")
    end
  end)
end

function KantoGameplay.facingWater(region)
  local map = region and excursion.sourceMapId and ensureForeignMap(region, excursion.sourceMapId)
  if not map then return false end
  local x, y = facingCell(excursion.cellX, excursion.cellY, excursion.facing)
  return map:inBounds(x, y) and type(map.isWaterCell) == "function" and map:isWaterCell(x, y)
end

function KantoGameplay.fishingGroup(region, rod, mapId)
  local field = region and region.loaded and region.loaded.field or {}
  if rod == "OLD_ROD" then return { always={species="MAGIKARP", level=5} } end
  if rod == "GOOD_ROD" then
    return { pool={ {species="GOLDEEN", level=10}, {species="POLIWAG", level=10} } }
  end
  return { pool=field.superRod and field.superRod[mapId] or nil }
end

function KantoGameplay.rollFishingGroup(group, rng)
  rng = rng or randomInt
  if type(group) ~= "table" or #group == 0 then return nil end
  while true do
    local r = rng(0, 255)
    if r % 2 == 1 then return nil end
    local pick = math.floor(r / 2) % 4
    if pick < #group then return group[pick + 1] end
  end
end
Twin._rollFishingGroup = KantoGameplay.rollFishingGroup

function KantoGameplay.useFishingRod(world, rod)
  local game = world and world.game
  local save = game and game.save
  local region = excursion.region
  if not (save and save.inventory and save.inventory[rod]) then return false, "You don't have that ROD." end
  if not KantoGameplay.facingWater(region) then return false, "Not even a nibble!" end
  local def = KantoGameplay.fishingGroup(region, rod, excursion.sourceMapId)
  local slot = def.always or KantoGameplay.rollFishingGroup(def.pool)
  Twin.yellowFishingUses = (Twin.yellowFishingUses or 0) + 1
  if not slot then showMessage(world, "Not even a nibble!"); return true end
  local function bite()
    startYellowWildBattle(world, region, excursion.sourceMapId, slot.species, slot.level, nil)
  end
  if not showMessage(world, ". . .\fOh! It's a bite!", bite) then bite() end
  return true
end

function KantoGameplay.slotAt(wheel, pos, off)
  if type(wheel) ~= "table" or #wheel == 0 then return nil end
  return wheel[((pos + off - 1) % #wheel) + 1]
end

function KantoGameplay.slotEvaluate(wheels, stops, bet)
  if type(wheels) ~= "table" or #wheels < 3 then return nil end
  for _, line in ipairs(KantoGameplay.SLOT_LINES) do
    if bet >= line.bet then
      local a = KantoGameplay.slotAt(wheels[1], stops[1], line[1])
      local b = KantoGameplay.slotAt(wheels[2], stops[2], line[2])
      local c = KantoGameplay.slotAt(wheels[3], stops[3], line[3])
      if a and a == b and b == c then
        return {symbol=a, payout=KantoGameplay.SLOT_PAYOUT[a] or 15}
      end
    end
  end
  return nil
end
Twin._slotEvaluate = KantoGameplay.slotEvaluate
Twin._prizeWindows = KantoGameplay.PRIZE_WINDOWS
Twin._tradeByText = KantoGameplay.TRADE_BY_TEXT

function KantoGameplay.openSlotMachine(world, region)
  local game = world and world.game
  local save = game and game.save
  local field = region and region.loaded and region.loaded.field
  local wheels = field and field.slotWheels
  if not (save and type(wheels) == "table" and #wheels >= 3) then return false end
  save.inventory = save.inventory or {}
  if not save.inventory.COIN_CASE then return showMessage(world, "A COIN CASE is required!") end
  if (tonumber(save.coins) or 0) <= 0 then return showMessage(world, "You don't have any coins!") end
  local function openBet()
    local items = { {label="BET 3", value=3}, {label="BET 2", value=2},
      {label="BET 1", value=1}, {label="CANCEL"} }
    KantoGameplay.listMenu(world, "SLOT MACHINE", items, function(item, menu)
      if menu and menu.close then menu:close() end
      local bet = item and item.value
      if not bet then return end
      if (save.coins or 0) < bet then
        showMessage(world, "Not enough coins.", openBet)
        return
      end
      save.coins = save.coins - bet
      local stops = { randomInt(1,#wheels[1]), randomInt(1,#wheels[2]), randomInt(1,#wheels[3]) }
      local win = KantoGameplay.slotEvaluate(wheels, stops, bet)
      if win then save.coins = math.min(9999, save.coins + win.payout) end
      Twin.yellowSlotSpins = (Twin.yellowSlotSpins or 0) + 1
      if win then Twin.yellowSlotWins = (Twin.yellowSlotWins or 0) + 1 end
      local middle = {
        KantoGameplay.slotAt(wheels[1], stops[1], 1) or "?",
        KantoGameplay.slotAt(wheels[2], stops[2], 1) or "?",
        KantoGameplay.slotAt(wheels[3], stops[3], 1) or "?",
      }
      local text = table.concat(middle, " | ")
      text = text .. (win and ("\f" .. tostring(win.symbol) .. "! +" .. tostring(win.payout) .. " coins!")
        or "\fNo match.")
      showMessage(world, text, function()
        askYesNo(world, "One more go?", function(yes) if yes then openBet() end end)
      end)
    end, "COINS " .. tostring(save.coins or 0))
  end
  openBet()
  return true
end

function KantoGameplay.coinClerk(world)
  local save = world and world.game and world.game.save
  if not save then return false end
  save.inventory = save.inventory or {}
  return askYesNo(world, "Do you need some game coins?\f¥1000 for 50.", function(yes)
    if not yes then showMessage(world, "Please come play sometime!"); return end
    if not save.inventory.COIN_CASE then showMessage(world, "You don't have a COIN CASE!"); return end
    if (save.coins or 0) >= 9990 then showMessage(world, "Oops! Your COIN CASE is full."); return end
    if (save.money or 0) < 1000 then showMessage(world, "You can't afford the coins!"); return end
    save.money = save.money - 1000
    save.coins = math.min(9999, (save.coins or 0) + 50)
    Twin.yellowCoinPurchases = (Twin.yellowCoinPurchases or 0) + 1
    showMessage(world, "Thanks! Here are your 50 coins!")
  end)
end

function KantoGameplay.prizeName(game, p)
  if p.kind == "mon" then
    local d = game and game.data and game.data.pokemon and game.data.pokemon[p.species]
    return tostring((d and d.name) or p.species) .. " L" .. tostring(p.level)
  end
  local goldId = game and KantoState.Items.resolveGoldItem(game.data and game.data.items,
    excursion.region and excursion.region.loaded and excursion.region.loaded.items, p.item)
  local d = goldId and game and game.data and game.data.items and game.data.items[goldId]
  return tostring((d and d.name) or p.item)
end

function KantoGameplay.givePrize(world, p)
  local game = world and world.game
  local save = game and game.save
  if not (game and save and p) then return false, "Prize system unavailable." end
  if p.kind == "mon" then
    if not (game.data.pokemon and game.data.pokemon[p.species]) then
      return false, "That Yellow prize has no Gen-2 species equivalent."
    end
    if not KantoGameplay.storageHasRoom(world) then return false, "Your party and current BOX are full." end
    local mon = makeGoldWild(world, p.species, p.level)
    return KantoGameplay.storeGoldMon(world, mon)
  end
  local goldId, mode, move = KantoState.Items.resolveGoldItem(game.data.items,
    excursion.region and excursion.region.loaded and excursion.region.loaded.items, p.item)
  if not goldId then
    return false, move and ("Gold has no TM/HM for " .. tostring(move):gsub("_", " ") .. ".")
      or "That Yellow TM has no safe Gen-2 equivalent."
  end
  local okBag, Bag = pcall(require, "src.inventory.Bag")
  if not (okBag and Bag and type(Bag.add) == "function" and Bag.add(save, goldId, 1, game.data)) then
    return false, "Your PACK doesn't have enough room."
  end
  if mode == "machine" then Twin.yellowSemanticItemConversions = (Twin.yellowSemanticItemConversions or 0) + 1 end
  return true, "PACK"
end

function KantoGameplay.openPrizeCounter(world, window)
  local game = world and world.game
  local save = game and game.save
  local prizes = KantoGameplay.PRIZE_WINDOWS[tonumber(window)]
  if not (game and save and prizes) then return false end
  save.inventory = save.inventory or {}
  if not save.inventory.COIN_CASE then return showMessage(world, "A COIN CASE is required!") end
  local function openWindow()
    local items = {}
    for _, p in ipairs(prizes) do
      items[#items + 1] = {label=KantoGameplay.prizeName(game,p), right=tostring(p.cost), value=p}
    end
    items[#items + 1] = {label="NO THANKS"}
    KantoGameplay.listMenu(world, "PRIZES (COINS)", items, function(item, menu)
      if menu and menu.close then menu:close() end
      local p = item and item.value
      if not p then return end
      if (save.coins or 0) < p.cost then showMessage(world, "Sorry, you need more coins."); return end
      askYesNo(world, "So, you want " .. KantoGameplay.prizeName(game,p) .. "?", function(yes)
        if not yes then showMessage(world, "Oh, fine then."); return end
        local ok, why = KantoGameplay.givePrize(world, p)
        if not ok then showMessage(world, why); return end
        save.coins = save.coins - p.cost
        Twin.yellowPrizes = (Twin.yellowPrizes or 0) + 1
        showMessage(world, "Here you go!")
      end)
    end, "COINS " .. tostring(save.coins or 0))
  end
  if not showMessage(world, "We exchange your coins for prizes.", openWindow) then openWindow() end
  return true
end

function KantoGameplay.tradeDoneId(mapId, textConst)
  return tostring(mapId) .. ":" .. tostring(textConst)
end

function KantoGameplay.openTrade(world, region, mapId, obj, tradeIndex)
  local game = world and world.game
  local save = game and game.save
  local field = region and region.loaded and region.loaded.field
  local row = field and field.trades and field.trades[tradeIndex]
  if not (game and save and row and row.give and row.get) then
    return showMessage(world, "This Yellow trade needs a current Yellow import.")
  end
  local done = KantoState.table(KantoState.TRADE_DONE_KEY)
  local key = KantoGameplay.tradeDoneId(mapId, obj.text)
  if done[key] then return showMessage(world, "Take good care of " .. tostring(row.nickname or row.get) .. "!") end
  save.party = save.party or {}
  local matches = {}
  for i, mon in ipairs(save.party) do
    if mon and mon.species == row.give then matches[#matches + 1] = {index=i, mon=mon} end
  end
  if #matches == 0 then
    return showMessage(world, "I'm looking for " .. tostring(row.give) .. ".\fWant to trade for my " .. tostring(row.get) .. "?")
  end
  return askYesNo(world, "Trade your " .. tostring(row.give) .. " for my " .. tostring(row.get) .. "?", function(yes)
    if not yes then return end
    local items = {}
    for _, m in ipairs(matches) do
      local mon = m.mon
      local def = game.data.pokemon and game.data.pokemon[mon.species]
      local name = mon.nickname or (def and def.name) or mon.species
      items[#items + 1] = {label=name .. " L" .. tostring(mon.level or 1), value=m}
    end
    items[#items + 1] = {label="CANCEL"}
    KantoGameplay.listMenu(world, "TRADE WHICH?", items, function(item, menu)
      if menu and menu.close then menu:close() end
      local choice = item and item.value
      if not choice then return end
      local old = save.party[choice.index]
      if not old or old.species ~= row.give then showMessage(world, "That POKéMON can't be traded here."); return end
      local received = makeGoldWild(world, row.get, tonumber(old.level) or 5)
      if not received then showMessage(world, "Gen-2 host couldn't create that trade POKéMON."); return end
      received.nickname = row.nickname and tostring(row.nickname) or nil
      received.traded = true
      save.party[choice.index] = received
      save.pokedex = save.pokedex or {seen={},caught={}}
      save.pokedex.seen = save.pokedex.seen or {}; save.pokedex.caught = save.pokedex.caught or {}
      save.pokedex.seen[row.get], save.pokedex.caught[row.get] = true, true
      done[key] = true; persistenceSet(KantoState.TRADE_DONE_KEY, done)
      Twin.yellowTrades = (Twin.yellowTrades or 0) + 1
      showMessage(world, "Thanks!\fTake good care of " .. tostring(received.nickname or row.get) .. "!")
    end)
  end)
end

KantoGameplay.SummerBeach = V.require("KantoSummerBeach")
Twin._surfingPikachuForTest = KantoGameplay.SummerBeach and KantoGameplay.SummerBeach.surfingPikachu
Twin._startSurfingPikachuForTest = KantoGameplay.SummerBeach and KantoGameplay.SummerBeach.startMinigame
Twin._resetSummerBeachVisitForTest = KantoGameplay.SummerBeach and KantoGameplay.SummerBeach.resetVisit

function KantoGameplay.giveRod(world, rod)
  local game = world and world.game
  local save = game and game.save
  if not (game and save) then return false end
  save.inventory = save.inventory or {}
  if save.inventory[rod] then return showMessage(world, "How are the fish biting?") end
  local idef = game.data.items and game.data.items[rod]
  if not idef then return showMessage(world, "That Yellow ROD has no Gen-2 item equivalent.") end
  return askYesNo(world, "Do you like to fish?\fWant my " .. tostring(idef.name or rod) .. "?", function(yes)
    if not yes then return end
    local okBag, Bag = pcall(require, "src.inventory.Bag")
    if okBag and Bag and Bag.add(save, rod, 1, game.data) then
      Twin.yellowRodGifts = (Twin.yellowRodGifts or 0) + 1
      showMessage(world, "Received " .. tostring(idef.name or rod) .. "!")
    else showMessage(world, "Your PACK can't hold it.") end
  end)
end

function KantoGameplay.civicText(region, label, fallback)
  return textByLabel(region, label) or fallback
end

function KantoGameplay.queueCivicBounce(dir)
  if not KantoGameplay.DIR_DELTA[dir] then return false end
  excursion.forcedMoves, excursion.forcedMoveIndex = { dir }, 1
  excursion.seafoamCurrentLock = false
  return true
end

function KantoGameplay.saffronDrink(world, region)
  local game = world and world.game
  local save = game and game.save
  if not save then return nil end
  save.inventory = save.inventory or {}
  local drink = KantoState.Civic.takeDrink(save.inventory)
  if not drink then return nil end
  KantoState.setEvent(KantoState.Civic.SAFFRON_EVENT, true)
  Twin.yellowSaffronDrinks = (Twin.yellowSaffronDrinks or 0) + 1
  return drink
end
Twin._takeKantoSaffronDrink = KantoGameplay.saffronDrink

function KantoGameplay.saffronGuardTalk(world, region, mapId, obj)
  local Civic = KantoState.Civic
  local gate = Civic.gate(mapId)
  if not (gate and obj and tostring(obj.text or "") == tostring(gate.guardText or "")) then
    return false
  end
  if KantoState.event(Civic.SAFFRON_EVENT) then
    return showMessage(world, KantoGameplay.civicText(region,
      "_SaffronGateGuardThanksForTheDrinkText", "Gee, that was tasty!"))
  end
  local drink = KantoGameplay.saffronDrink(world, region)
  if drink then
    return showMessage(world, KantoGameplay.civicText(region,
      "_SaffronGateGuardImParchedText", "Whoa, boy!\nI'm parched!"), function()
        showMessage(world, KantoGameplay.civicText(region,
          "_SaffronGateGuardYouCanGoOnThroughText", "You can go on through!"))
      end)
  end
  return showMessage(world, KantoGameplay.civicText(region,
    "_SaffronGateGuardGeeImThirstyText", "Gee, I'm thirsty though!\nThe road's closed."))
end
Twin._talkKantoSaffronGuard = KantoGameplay.saffronGuardTalk

function KantoGameplay.saffronGateStep(world, region, mapId, x, y)
  local Civic = KantoState.Civic
  if not Civic.gateTrigger(mapId, x, y) or KantoState.event(Civic.SAFFRON_EVENT) then
    return false
  end
  if KantoGameplay.saffronDrink(world, region) then
    showMessage(world, KantoGameplay.civicText(region,
      "_SaffronGateGuardImParchedText", "Whoa, boy!\nI'm parched!"), function()
        showMessage(world, KantoGameplay.civicText(region,
          "_SaffronGateGuardYouCanGoOnThroughText", "You can go on through!"))
      end)
    return true
  end
  local back = Civic.gateBounce(mapId, excursion.facing)
  Twin.yellowSaffronGateBlocks = (Twin.yellowSaffronGateBlocks or 0) + 1
  local function bounce() KantoGameplay.queueCivicBounce(back) end
  if not showMessage(world, KantoGameplay.civicText(region,
      "_SaffronGateGuardGeeImThirstyText", "Gee, I'm thirsty though!\nThe road's closed."), bounce) then
    bounce()
  end
  return true
end
Twin._handleKantoSaffronGateStep = KantoGameplay.saffronGateStep

function KantoGameplay.museumTicket(world, region, fromGate)
  local Civic = KantoState.Civic
  if KantoState.event(Civic.MUSEUM_TICKET_EVENT) then
    return showMessage(world, KantoGameplay.civicText(region,
      "_Museum1FScientist1TakePlentyOfTimeText", "Take your time, and enjoy it all!"))
  end
  local game = world and world.game
  local save = game and game.save
  if not save then return false end
  local function bounce()
    if fromGate then
      Twin.yellowMuseumGateBlocks = (Twin.yellowMuseumGateBlocks or 0) + 1
      KantoGameplay.queueCivicBounce("down")
    end
  end
  return askYesNo(world, KantoGameplay.civicText(region,
    "_Museum1FScientist1WouldYouLikeToComeInText",
    "It's ¥50 for a child's ticket.\nWould you like to come in?"), function(yes)
      if not yes then
        if not showMessage(world, KantoGameplay.civicText(region,
            "_Museum1FScientist1ComeAgainText", "Come again!"), bounce) then bounce() end
        return
      end
      if (tonumber(save.money) or 0) < (tonumber(Civic.MUSEUM_PRICE) or 50) then
        if not showMessage(world, KantoGameplay.civicText(region,
            "_Museum1FScientist1DontHaveEnoughMoneyText", "You don't have enough money."), bounce) then
          bounce()
        end
        return
      end
      save.money = (tonumber(save.money) or 0) - (tonumber(Civic.MUSEUM_PRICE) or 50)
      KantoState.setEvent(Civic.MUSEUM_TICKET_EVENT, true)
      Twin.yellowMuseumTickets = (Twin.yellowMuseumTickets or 0) + 1
      showMessage(world, KantoGameplay.civicText(region,
        "_Museum1FScientist1ThankYouText", "Right, ¥50! Thank you!"))
    end)
end
Twin._openKantoMuseumTicket = KantoGameplay.museumTicket

function KantoGameplay.museumGateStep(world, region, mapId, x, y)
  local Civic = KantoState.Civic
  if not Civic.museumTicketTrigger(mapId, x, y)
      or KantoState.event(Civic.MUSEUM_TICKET_EVENT) then
    return false
  end
  return KantoGameplay.museumTicket(world, region, true)
end
Twin._handleKantoMuseumGateStep = KantoGameplay.museumGateStep

function KantoGameplay.hideMuseumAmber(region, mapId)
  local Civic = KantoState.Civic
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  if type(def) ~= "table" then return false end
  local changed = false
  for _, candidate in ipairs(def.objects or {}) do
    if Civic.isAmberDisplay(mapId, candidate)
        and KantoState.setObjectHidden(mapId, candidate, true) then
      changed = true
    end
  end
  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
  end
  return changed
end
Twin._hideKantoMuseumAmber = KantoGameplay.hideMuseumAmber

function KantoGameplay.giveMuseumAmber(world, region, mapId)
  local Civic = KantoState.Civic
  if KantoState.event(Civic.OLD_AMBER_EVENT) then
    return showMessage(world, KantoGameplay.civicText(region,
      "_Museum1FScientist2GetTheOldAmberCheckText", "Take good care of the OLD AMBER."))
  end
  local game = world and world.game
  local save = game and game.save
  if not (game and save) then return false end
  return showMessage(world, KantoGameplay.civicText(region,
    "_Museum1FScientist2TakeThisToAPokemonLabText",
    "Take this to a POKéMON LAB. It may contain ancient DNA."), function()
      -- Gold has no OLD_AMBER id, but Yellow still requires bag room before
      -- handing it over.  Honor Gold's real key-item pocket capacity without
      -- inventing a foreign item record in the Gold inventory.
      local okBag, Bag = pcall(require, "src.inventory.Bag")
      if okBag and Bag and type(KantoGameplay.syntheticKeyItemRoom) == "function"
          and not KantoGameplay.syntheticKeyItemRoom(game, save, Bag) then
        showMessage(world, KantoGameplay.civicText(region,
          "_Museum1FScientist2YouDontHaveSpaceText", "You have no room for the OLD AMBER."))
        return
      end
      -- Keep OLD AMBER in the Kanto-local key-item namespace so it can reach
      -- the Cinnabar resurrection service without colliding with Johto data.
      if not KantoState.giveLocalItem("OLD_AMBER") then return end
      KantoState.setEvent(Civic.OLD_AMBER_EVENT, true)
      KantoGameplay.hideMuseumAmber(region, mapId)
      Twin.yellowOldAmberGifts = (Twin.yellowOldAmberGifts or 0) + 1
      if type(KantoGameplay.playSound) == "function" then KantoGameplay.playSound(world, "Get_Item1") end
      showMessage(world, KantoGameplay.civicText(region,
        "_Museum1FScientist2ReceivedOldAmberText", "Received OLD AMBER!"))
    end)
end
Twin._giveKantoMuseumAmber = KantoGameplay.giveMuseumAmber

function KantoGameplay.syncBikeServiceEvents(save)
  local Civic = KantoState.Civic
  if not save then return false, false, false end
  save.inventory = save.inventory or {}
  local hasBike = Civic.hasItem(save.inventory, "BICYCLE")
  local hasGoldVoucher = Civic.hasItem(save.inventory, "BIKE_VOUCHER")
  -- Cross-region migration: Gold may already own the Bicycle/Voucher before
  -- this Kanto service existed. Treat those real items as authoritative and
  -- backfill only Kanto-local completion bits, never Gold story flags.
  if hasBike then
    KantoState.setEvent(Civic.BICYCLE_EVENT, true)
    KantoState.setEvent(Civic.BIKE_VOUCHER_EVENT, true)
  elseif hasGoldVoucher then
    KantoState.setEvent(Civic.BIKE_VOUCHER_EVENT, true)
  end
  local bikeDone = hasBike or KantoState.event(Civic.BICYCLE_EVENT)
  local received = KantoState.event(Civic.BIKE_VOUCHER_EVENT)
  local voucherHeld = (received and not bikeDone) or hasGoldVoucher
  return voucherHeld, hasBike, bikeDone
end
Twin._syncKantoBikeServiceEvents = KantoGameplay.syncBikeServiceEvents

function KantoGameplay.syntheticKeyItemRoom(game, save, Bag)
  if not (save and Bag) then return true end
  -- Gold/Silver does not normally define BIKE_VOUCHER. When it is absent,
  -- keep the voucher in Kanto-local state but still honor the real Gold key-
  -- item pocket capacity so the Yellow GiveItem bag-full branch remains real.
  if type(Bag.slots) == "function" and type(Bag.capacity) == "function" then
    local okSlots, slots = pcall(Bag.slots, save, game and game.data, "KEY_ITEM")
    local okCap, cap = pcall(Bag.capacity, game and game.data, "KEY_ITEM")
    if okSlots and okCap and tonumber(slots) and tonumber(cap) then
      return tonumber(slots) < tonumber(cap)
    end
  end
  return true
end
Twin._kantoSyntheticKeyItemRoom = KantoGameplay.syntheticKeyItemRoom

function KantoGameplay.fanClubChairman(world, region)
  local Civic = KantoState.Civic
  local game = world and world.game
  local save = game and game.save
  if not (game and save) then return false end
  local _, _, bikeDone = KantoGameplay.syncBikeServiceEvents(save)
  if KantoState.event(Civic.BIKE_VOUCHER_EVENT) or bikeDone then
    return showMessage(world, KantoGameplay.civicText(region,
      "_PokemonFanClubChairFinalText", "My favorite POKeMON is still the best!"))
  end
  return askYesNo(world, KantoGameplay.civicText(region,
    "_PokemonFanClubChairmanIntroText",
    "I just love my POKeMON!\fDo you want to hear about them?"), function(yes)
      if not yes then
        showMessage(world, KantoGameplay.civicText(region,
          "_PokemonFanClubNoStoryText", "Come back if you want to hear my story!"))
        return
      end
      showMessage(world, KantoGameplay.civicText(region,
        "_PokemonFanClubChairmanStoryText",
        "My favorite RAPIDASH is cute, lovely, smart, plus amazing..."), function()
          local okBag, Bag = pcall(require, "src.inventory.Bag")
          if not (okBag and type(Bag) == "table") then
            showMessage(world, KantoGameplay.civicText(region,
              "_BagFullText", "You can't carry any more items!"))
            return
          end
          local itemDef = game.data and game.data.items and game.data.items.BIKE_VOUCHER
          local awarded = false
          if itemDef and type(Bag.add) == "function" then
            awarded = Bag.add(save, "BIKE_VOUCHER", 1, game.data) == true
          elseif KantoGameplay.syntheticKeyItemRoom(game, save, Bag) then
            -- No Gen-2 item equivalent: the Kanto event IS the held voucher.
            awarded = true
            Twin.yellowLocalBikeVouchers = (Twin.yellowLocalBikeVouchers or 0) + 1
          end
          if not awarded then
            showMessage(world, KantoGameplay.civicText(region,
              "_BagFullText", "You can't carry any more items!"))
            return
          end
          KantoState.setEvent(Civic.BIKE_VOUCHER_EVENT, true)
          Twin.yellowBikeVouchers = (Twin.yellowBikeVouchers or 0) + 1
          if type(KantoGameplay.playSound) == "function" then
            KantoGameplay.playSound(world, "Get_Key_Item")
          end
          showMessage(world, KantoGameplay.civicText(region,
            "_PokemonFanClubReceivedBikeVoucherText", "Received a BIKE VOUCHER!"), function()
              showMessage(world, KantoGameplay.civicText(region,
                "_PokemonFanClubExplainBikeVoucherText",
                "Exchange that BIKE VOUCHER for a BICYCLE!"))
            end)
        end)
    end)
end
Twin._talkKantoFanClubChairman = KantoGameplay.fanClubChairman

function KantoGameplay.removeGoldItem(save, itemId, count, Bag)
  count = tonumber(count) or 1
  local inv = save and save.inventory
  if type(inv) ~= "table" then return false end
  local have = KantoState.Civic.itemCount(inv, itemId)
  if have < count then return false end
  if Bag and type(Bag.remove) == "function" then
    Bag.remove(save, itemId, count)
    return true
  end
  have = have - count
  inv[itemId] = have > 0 and have or nil
  return true
end

function KantoGameplay.bikeShopExchange(world, region)
  local Civic = KantoState.Civic
  local game = world and world.game
  local save = game and game.save
  if not (game and save) then return false end
  save.inventory = save.inventory or {}
  local voucherHeld = select(1, KantoGameplay.syncBikeServiceEvents(save))
  if not voucherHeld then return false end
  local okBag, Bag = pcall(require, "src.inventory.Bag")
  local itemOk = game.data and game.data.items and game.data.items.BICYCLE
  if not (okBag and type(Bag) == "table" and type(Bag.add) == "function"
      and itemOk and Bag.add(save, "BICYCLE", 1, game.data)) then
    return showMessage(world, KantoGameplay.civicText(region,
      "_BikeShopBagFullText", "Your PACK is full. Make room for the BICYCLE."))
  end
  -- Original atomicity: only spend a physical voucher after GiveItem accepted
  -- the Bicycle. On normal Gold hosts the voucher is Kanto-local, so setting
  -- EVENT_GOT_BICYCLE consumes that held state without inventing a Gen-2 item.
  if Civic.hasItem(save.inventory, "BIKE_VOUCHER")
      and not KantoGameplay.removeGoldItem(save, "BIKE_VOUCHER", 1, Bag) then
    KantoGameplay.removeGoldItem(save, "BICYCLE", 1, Bag)
    return showMessage(world, "The BIKE VOUCHER exchange could not be completed.")
  end
  KantoState.setEvent(Civic.BIKE_VOUCHER_EVENT, true)
  KantoState.setEvent(Civic.BICYCLE_EVENT, true)
  Twin.yellowBicycleExchanges = (Twin.yellowBicycleExchanges or 0) + 1
  if type(KantoGameplay.playSound) == "function" then
    KantoGameplay.playSound(world, "Get_Key_Item")
  end
  return showMessage(world, KantoGameplay.civicText(region,
    "_BikeShopExchangedVoucherText", "Exchanged the BIKE VOUCHER for a BICYCLE!"))
end
Twin._exchangeKantoBikeVoucher = KantoGameplay.bikeShopExchange

function KantoGameplay.bikeShopClerk(world, region)
  local Civic = KantoState.Civic
  local game = world and world.game
  local save = game and game.save
  if not (game and save) then return false end
  local hasVoucher, hasBike, bikeDone = KantoGameplay.syncBikeServiceEvents(save)
  if hasBike or bikeDone then
    return showMessage(world, KantoGameplay.civicText(region,
      "_BikeShopClerkHowDoYouLikeYourBicycleText", "How do you like your BICYCLE?"))
  end
  if hasVoucher then
    return showMessage(world, KantoGameplay.civicText(region,
      "_BikeShopClerkOhThatsAVoucherText", "Oh, that's a BIKE VOUCHER!"), function()
        KantoGameplay.bikeShopExchange(world, region)
      end)
  end

  local function comeAgain()
    showMessage(world, KantoGameplay.civicText(region,
      "_BikeShopComeAgainText", "Come again sometime!"))
  end
  local function chooseBike(buy)
    if buy then
      showMessage(world, KantoGameplay.civicText(region,
        "_BikeShopCantAffordText", "Sorry! You can't afford it!"), comeAgain)
    else
      comeAgain()
    end
  end
  local function openSale()
    Twin.yellowBikeShopBrowses = (Twin.yellowBikeShopBrowses or 0) + 1
    local pitch = KantoGameplay.civicText(region,
      "_BikeShopClerkDoYouLikeItText", "It's a cool BIKE! Do you want it?")
    local items = {
      { label = "BICYCLE", right = "¥1000000", value = true },
      { label = "CANCEL", value = false },
    }
    local opened = KantoGameplay.listMenu(world, pitch, items, function(item, menu)
      if menu and type(menu.close) == "function" then menu:close() end
      chooseBike(item and item.value == true)
    end)
    if not opened then
      askYesNo(world, pitch, chooseBike)
    end
  end
  return showMessage(world, KantoGameplay.civicText(region,
    "_BikeShopClerkWelcomeText", "Welcome to our BIKE SHOP!"), openSale)
end
Twin._talkKantoBikeShopClerk = KantoGameplay.bikeShopClerk

function KantoGameplay.handleCivicStep(world, region, mapId, x, y)
  if KantoGameplay.saffronGateStep(world, region, mapId, x, y) then return true end
  if KantoGameplay.museumGateStep(world, region, mapId, x, y) then return true end
  return false
end
Twin._handleKantoCivicStep = KantoGameplay.handleCivicStep

function KantoGameplay.ensureKantoLocalItem(world, region, itemId)
  itemId = tostring(itemId or "")
  if KantoState.itemHeld(world, itemId) then return true end
  if not KantoState.Items.isLocalOnly(itemId) then return false end
  -- Migration for saves made by older releases: if THIS Kanto excursion had
  -- already consumed the corresponding object, recreate only the Kanto-local
  -- ownership bit. Never infer ownership from Gold's same-named inventory key.
  for oldMapId, def in pairs(region and region.loaded and region.loaded.maps or {}) do
    for _, candidate in ipairs(type(def) == "table" and def.objects or {}) do
      if tostring(candidate.item or "") == itemId and itemAlreadyPicked(oldMapId, candidate) then
        KantoState.giveLocalItem(itemId)
        return true
      end
    end
  end
  if itemId == "OLD_AMBER" and KantoState.event(KantoState.Civic.OLD_AMBER_EVENT) then
    KantoState.giveLocalItem(itemId)
    return true
  end
  if itemId == "POKE_FLUTE"
      and KantoState.event(KantoState.Items.POKEMON_TOWER.fluteEvent) then
    KantoState.giveLocalItem(itemId)
    return true
  end
  return false
end

function KantoGameplay.takeMtMoonFossil(world, region, mapId, obj)
  if tostring(mapId or "") ~= KantoState.Items.MT_MOON.map then return false end
  local itemId = KantoState.Items.mtMoonFossil(obj and obj.text)
  if not itemId then return false end
  if not KantoState.event(KantoState.Items.MT_MOON.prerequisite) then
    return showMessage(world, "The SUPER NERD won't let you take a FOSSIL yet.")
  end
  if KantoState.itemHeld(world, "DOME_FOSSIL") or KantoState.itemHeld(world, "HELIX_FOSSIL")
      or KantoState.event("EVENT_GOT_DOME_FOSSIL") or KantoState.event("EVENT_GOT_HELIX_FOSSIL") then
    return showMessage(world, "You already chose a FOSSIL.")
  end
  local spec = KantoState.Items.fossil(itemId)
  return askYesNo(world, "Do you want the " .. tostring(spec and spec.display or itemId) .. "?", function(yes)
    if not yes then return end
    if not KantoState.giveLocalItem(itemId) then return end
    if spec and spec.event then KantoState.setEvent(spec.event, true) end
    local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
    if type(def) == "table" then
      for _, candidate in ipairs(def.objects or {}) do
        if KantoState.Items.mtMoonFossil(candidate.text) then
          KantoState.setObjectHidden(mapId, candidate, true)
        end
      end
    end
    region.npcCache[mapId], region.pokemonCache[mapId] = nil, nil
    KantoState.Spatial.invalidate(region, mapId, true, true)
    Twin.yellowFossilsTaken = (Twin.yellowFossilsTaken or 0) + 1
    showMessage(world, "Received the " .. tostring(spec and spec.display or itemId:gsub("_", " ")) .. "!")
  end)
end

function KantoGameplay.fossilLabState()
  local state = KantoState.table(KantoState.FOSSIL_LAB_KEY)
  return type(state) == "table" and state or {}
end

function KantoGameplay.saveFossilLabState(state)
  state = type(state) == "table" and state or {}
  persistenceSet(KantoState.FOSSIL_LAB_KEY, state)
  return state
end

function KantoGameplay.fossilsHeld(world, region)
  local rows = {}
  for _, id in ipairs({ "DOME_FOSSIL", "HELIX_FOSSIL", "OLD_AMBER" }) do
    if KantoGameplay.ensureKantoLocalItem(world, region or excursion.region, id)
        or KantoState.itemHeld(world, id) then
      rows[#rows + 1] = KantoState.Items.fossil(id)
    end
  end
  return rows
end

function KantoGameplay.submitFossil(world, spec)
  if not (spec and spec.item and KantoState.itemHeld(world, spec.item)) then return false end
  if not KantoState.takeLocalItem(spec.item) then return false end
  KantoGameplay.saveFossilLabState({ item = spec.item, species = spec.species,
    level = spec.level or 30, ready = false })
  KantoState.setEvent("EVENT_GAVE_FOSSIL_TO_LAB", true)
  KantoState.setEvent("EVENT_LAB_STILL_REVIVING_FOSSIL", true)
  Twin.yellowFossilsSubmitted = (Twin.yellowFossilsSubmitted or 0) + 1
  return true
end

function KantoGameplay.fossilScientist(world, region)
  local state = KantoGameplay.fossilLabState()
  if state.species then
    if state.ready ~= true then
      return showMessage(world, "It takes time to revive your FOSSIL. Go for a walk outside!")
    end
    if not KantoGameplay.storageHasRoom(world) then
      return showMessage(world, "Your party and current BOX are full. I will keep your revived POKéMON safe.")
    end
    local mon = KantoGameplay.makeGoldGift(world, { species = state.species, level = state.level or 30 })
    if not mon then return showMessage(world, "The revived POKéMON could not be created on this build.") end
    local stored = KantoGameplay.storeGoldMon(world, mon)
    if not stored then return showMessage(world, "Your party and current BOX are full.") end
    local species = state.species
    KantoGameplay.saveFossilLabState({})
    KantoState.setEvent("EVENT_GAVE_FOSSIL_TO_LAB", false)
    KantoState.setEvent("EVENT_LAB_STILL_REVIVING_FOSSIL", false)
    KantoState.setEvent("EVENT_LAB_HANDING_OVER_FOSSIL_MON", false)
    Twin.yellowFossilsRevived = (Twin.yellowFossilsRevived or 0) + 1
    return showMessage(world, tostring(species) .. " was resurrected from the FOSSIL!")
  end

  local fossils = KantoGameplay.fossilsHeld(world, region)
  if #fossils == 0 then
    return showMessage(world, "I study POKéMON fossils. Bring me a DOME FOSSIL, HELIX FOSSIL, or OLD AMBER!")
  end
  local function offer(spec)
    return askYesNo(world, "You have a " .. tostring(spec.display) .. "! Shall I resurrect it?", function(yes)
      if not yes then return showMessage(world, "Come again!") end
      if KantoGameplay.submitFossil(world, spec) then
        showMessage(world, "I took the " .. tostring(spec.display) .. ". Go for a walk outside while I work!")
      end
    end)
  end
  if #fossils == 1 then return offer(fossils[1]) end
  local rows = {}
  for _, spec in ipairs(fossils) do rows[#rows + 1] = { label = spec.display, value = spec } end
  rows[#rows + 1] = { label = "CANCEL" }
  return KantoGameplay.listMenu(world, "WHICH FOSSIL?", rows, function(item, menu)
    if menu and type(menu.close) == "function" then menu:close() end
    if item and item.value then offer(item.value) end
  end)
end

function KantoGameplay.markFossilReadyOnMapEntry(mapId)
  if tostring(mapId or "") ~= "CINNABAR_ISLAND" then return false end
  local state = KantoGameplay.fossilLabState()
  if not state.species or state.ready == true then return false end
  state.ready = true
  KantoGameplay.saveFossilLabState(state)
  KantoState.setEvent("EVENT_LAB_STILL_REVIVING_FOSSIL", false)
  return true
end


-- v0.3.84: Kanto's Rocket Hideout -> Pokemon Tower -> Poke Flute quest chain.
-- Gold owns battle/Pokemon/save state; these methods only persist the foreign
-- Yellow quest facts and physical object visibility needed to make Kanto play
-- as a connected region.
function KantoGameplay.questObjectByText(region, mapId, textConst)
  local def = sourceMapDef(region, mapId)
  if type(def) ~= "table" then return nil end
  for _, obj in ipairs(def.objects or {}) do
    if tostring(obj.text or "") == tostring(textConst or "") then return obj end
  end
  return nil
end

function KantoGameplay.hasAllKantoBadges(world)
  local badges = world and world.game and world.game.save and world.game.save.player
    and world.game.save.player.kantoBadges
  if type(badges) ~= "table" then return false end
  for index, name in ipairs(KANTO_BADGE_ORDER) do
    if badges[name] ~= true and badges[index] ~= true then return false end
  end
  return true
end
Twin._hasAllKantoBadges = KantoGameplay.hasAllKantoBadges

function KantoGameplay.rivalStarter()
  local R = KantoState.Rival
  return R.starter(saveGet(R.STARTER_KEY, R.DEFAULT_STARTER))
end
Twin._kantoRivalStarter = KantoGameplay.rivalStarter

function KantoGameplay.setRivalStarter(value)
  local R = KantoState.Rival
  value = R.starter(value)
  saveSet(R.STARTER_KEY, value)
  return value
end
Twin._setKantoRivalStarterForTest = KantoGameplay.setRivalStarter

function KantoGameplay.recordOakLabRivalOutcome(outcome)
  local R = KantoState.Rival
  if outcome ~= "win" and outcome ~= true and outcome ~= "lose" then return false end
  local won = outcome == "win" or outcome == true
  KantoGameplay.setRivalStarter(R.starterFromLabResult(won))
  KantoState.setEvent(R.LAB_EVENT, true)
  Twin.yellowOakLabRivalResults = (Twin.yellowOakLabRivalResults or 0) + 1
  return true
end
Twin._recordOakLabRivalOutcomeForTest = KantoGameplay.recordOakLabRivalOutcome

-- Scripted Yellow rival encounters do not carry trainerClass/party on the
-- object row; their map script chooses those at runtime. Reconstruct that
-- tiny piece here while Gold remains the actual trainer-battle authority.
function KantoGameplay.handleRivalStep(world, region, mapId, x, y)
  local R = KantoState.Rival
  local spec = R.step(mapId, x, y)
  -- Route 22 reuses the same two trigger cells for the optional early rival
  -- and the eight-badge League warm-up. Once the early battle is completed
  -- or permanently skipped by Boulder Badge, select the late encounter.
  if spec and spec.id == "ROUTE22_FIRST" then
    local badges = world and world.game and world.game.save and world.game.save.player
      and world.game.save.player.kantoBadges
    local boulder = type(badges) == "table" and (badges.BOULDER == true or badges[1] == true)
    if KantoState.event(spec.event) or boulder then
      spec = R.ENCOUNTERS.ROUTE22
    end
  end
  if not spec or KantoState.event(spec.event) then return false end
  if spec.requiresLabBattle and not KantoState.event(KantoState.Rival.LAB_EVENT) then return false end
  if spec.requiresBeforeBoulder then
    local badges = world and world.game and world.game.save and world.game.save.player
      and world.game.save.player.kantoBadges
    if type(badges) == "table" and (badges.BOULDER == true or badges[1] == true) then return false end
  end
  if spec.id == "ROUTE22" and not KantoState.event(KantoState.Rival.ENCOUNTERS.ROUTE22_FIRST.event) then
    -- Yellow allows the early battle to be skipped, but Brock permanently
    -- removes it. If Boulder is already owned, late Route 22 may proceed.
    local badges = world and world.game and world.game.save and world.game.save.player
      and world.game.save.player.kantoBadges
    if not (type(badges) == "table" and (badges.BOULDER == true or badges[1] == true)) then
      return false
    end
  end
  if spec.requiresAllBadges and not KantoGameplay.hasAllKantoBadges(world) then return false end
  if spec.id == "ROUTE22" and KantoState.event(KantoState.League.START_EVENT) then return false end
  if excursion.battleBusy then return true end

  local obj = KantoGameplay.questObjectByText(region, mapId, spec.text)
  if obj then KantoState.revealObjectByText(region, mapId, spec.text) end
  local party = R.party(spec, KantoGameplay.rivalStarter())
  local fake = { trainerClass = spec.class, trainerParty = party, text = spec.text,
    index = obj and obj.index or spec.id }
  local trainer, err = yellowTrainer(region, world, fake, mapId)
  if not trainer then
    Twin.lastBattleError = tostring(err)
    return showMessage(world, "Rival data is unavailable. Re-import Pokemon Yellow.")
  end

  local function battle()
    Twin.yellowRivalBattles = (Twin.yellowRivalBattles or 0) + 1
    return KantoGameplay.runQuestTrainerBattle(world, trainer, function(outcome)
      if outcome == "win" or outcome == true then
        KantoState.setEvent(spec.event, true)
        if spec.id == "ROUTE22_FIRST" then
          local R = KantoState.Rival
          KantoGameplay.setRivalStarter(R.starterAfterFirstRoute22Win(KantoGameplay.rivalStarter()))
          Twin.yellowRoute22FirstRivalWins = (Twin.yellowRoute22FirstRivalWins or 0) + 1
        end
        KantoState.hideObjectsByText(region, mapId, { [spec.text] = true })
        Twin.yellowRivalWins = (Twin.yellowRivalWins or 0) + 1
        local after = textByLabel(region, spec.after) or spec.fallbackAfter
        if after then showMessage(world, after) end
      end
    end)
  end

  local intro = textByLabel(region, spec.intro) or spec.fallbackIntro
  if intro and showMessage(world, intro, battle) then return true end
  return battle() or true
end
Twin._handleKantoRivalStep = KantoGameplay.handleRivalStep

function KantoGameplay.afterQuestTrainerWin(region, mapId, obj)
  mapId = tostring(mapId or "")
  if mapId == "CERULEAN_CITY" and obj
      and tostring(obj.text or "") == "TEXT_CERULEANCITY_ROCKET" then
    if KantoState.setEvent("EVENT_BEAT_CERULEAN_ROCKET_THIEF", true) then
      Twin.yellowCeruleanRocketWins = (Twin.yellowCeruleanRocketWins or 0) + 1
    end
    -- He must remain visible until TM28 is successfully accepted.
    KantoState.migrateCeruleanRobberyObjects(region, mapId)
    return true
  end

  local q = KantoState.Items.ROCKET_HIDEOUT
  if mapId ~= tostring(q.map or "") or not obj then return false end
  local textConst = tostring(obj.text or "")
  local changed = false
  if textConst == tostring(q.rocketText or "") then
    if KantoState.setEvent(q.droppedLiftKeyEvent, true) then
      Twin.yellowRocketLiftKeyDrops = (Twin.yellowRocketLiftKeyDrops or 0) + 1
    end
    changed = KantoState.revealObjectByText(region, mapId, q.liftKeyText) or changed
  elseif textConst == tostring(q.giovanniText or "") then
    if KantoState.setEvent(q.giovanniEvent, true) then
      Twin.yellowSilphScopeDrops = (Twin.yellowSilphScopeDrops or 0) + 1
    end
    changed = KantoState.setObjectHidden(mapId, obj, true) or changed
    KantoState.setObjectShown(mapId, obj, false)
    changed = KantoState.revealObjectByText(region, mapId, q.silphScopeText) or changed
  end
  if changed then
    if region.npcCache then region.npcCache[mapId] = nil end
    if region.pokemonCache then region.pokemonCache[mapId] = nil end
    KantoState.Spatial.invalidate(region, mapId, true, true)
  end
  return changed
end

function KantoGameplay.transferToWarp(region, mapId, warpIndex)
  local def = sourceMapDef(region, mapId)
  if type(def) ~= "table" then return false end
  warpIndex = tonumber(warpIndex)
  local warp = warpIndex and def.warps and def.warps[warpIndex] or nil
  if not warp and warpIndex then
    for i, row in ipairs(def.warps or {}) do
      if tonumber(row.index) == warpIndex or i == warpIndex then warp = row break end
    end
  end
  local x, y = warp and tonumber(warp.x), warp and tonumber(warp.y)
  if not (x and y and ensureForeignMap(region, mapId)) then return false end
  x, y = math.floor(x), math.floor(y)
  excursion.sourceMapId = mapId
  KantoState.onMapEntered(region, mapId)
  excursion.cellX, excursion.cellY = x, y
  excursion.drawPx, excursion.drawPy = x * 16, y * 16
  excursion.toMapId, excursion.toCellX, excursion.toCellY = nil, nil, nil
  excursion.moving, excursion.moveT = false, 0
  excursion.forcedMoves, excursion.forcedMoveIndex, excursion.seafoamCurrentLock = nil, 0, false
  excursion.strengthActive = false
  excursion.currentRecord = recordBySource(region, mapId)
  Twin._setWarpIgnore(mapId, x, y)
  excursion.standingOnWarp = true
  clearDirectionalBody(false)
  Twin.excursionSourceMap, Twin.excursionCellX, Twin.excursionCellY = mapId, x, y
  persistExcursionPosition()
  return true
end

function KantoGameplay.rocketElevator(world, region)
  local spec = KantoState.Items.ROCKET_ELEVATOR
  if not KantoGameplay.ensureKantoLocalItem(world, region, "LIFT_KEY") then
    return showMessage(world, "It appears to need a key.")
  end
  local rows = {}
  for _, floor in ipairs(spec.floors or {}) do
    rows[#rows + 1] = { label = floor.label, value = floor }
  end
  rows[#rows + 1] = { label = "CANCEL" }
  return KantoGameplay.listMenu(world, "ELEVATOR", rows, function(item, menu)
    if menu and type(menu.close) == "function" then menu:close() end
    local floor = item and item.value
    if not floor then return end
    if KantoGameplay.transferToWarp(region, floor.map, floor.warp) then
      Twin.yellowRocketElevatorUses = (Twin.yellowRocketElevatorUses or 0) + 1
    else
      showMessage(world, "The elevator cannot reach that floor on this cache.")
    end
  end)
end

function KantoGameplay.makeQuestTrainer(world, spec)
  spec = spec or {}
  local classes = world and world.game and world.game.data and world.game.data.trainers
    and world.game.data.trainers.classes or {}
  local classId = tostring(spec.classId or "CHANNELER")
  if not classes[classId] then classId = classes.YOUNGSTER and "YOUNGSTER" or classId end
  local class = classes[classId] or {}
  return {
    class = tonumber(class.index) or 1,
    classId = classId,
    className = class.name or classId,
    id = spec.id or "YELLOW_KANTO_QUEST",
    name = spec.name or "GHOST",
    baseMoney = tonumber(spec.baseMoney) or 0,
    roster = deepCopy(spec.roster or {}),
    attributes = deepCopy(class.attributes or {}),
    items = deepCopy(class.items or {}),
    _stadiumYellowTrainer = true,
    _stadiumKantoQuestTrainer = true,
  }
end

function KantoGameplay.runQuestTrainerBattle(world, trainer, onDone)
  if excursion.battleBusy then return true end
  if not (world and type(world.startScriptedBattle) == "function" and trainer) then
    Twin.lastBattleError = "Gold scripted battle API unavailable"
    return false
  end
  excursion.battleBusy = true
  local ok, started, err = pcall(world.startScriptedBattle, world, trainer, nil, function(outcome)
    excursion.battleBusy = false
    excursion.prevA = false
    if outcome == "lose" and Twin._handleKantoBattleLoss then
      pcall(Twin._handleKantoBattleLoss, world)
    end
    if onDone then onDone(outcome) end
  end)
  if not ok or started == false then
    excursion.battleBusy = false
    Twin.lastBattleError = tostring(ok and err or started)
    return false
  end
  Twin.lastBattleError = nil
  return true
end

function KantoGameplay.rocketHideoutDuoStep(world, region, mapId, x, y)
  local q = KantoState.Items.ROCKET_HIDEOUT
  if tostring(mapId or "") ~= tostring(q.map or "")
      or tonumber(y) ~= tonumber(q.duoY) or not (q.duoX and q.duoX[tonumber(x)])
      or KantoState.event(q.duoEvent) then return false end
  KantoState.revealObjectByText(region, mapId, "TEXT_ROCKETHIDEOUTB4F_JESSIE")
  KantoState.revealObjectByText(region, mapId, "TEXT_ROCKETHIDEOUTB4F_JAMES")
  local trainer, err = yellowTrainer(region, world,
    { trainerClass = "OPP_ROCKET", trainerParty = q.duoParty or 43 })
  if not trainer then Twin.lastBattleError = err return false end
  Twin.yellowRocketDuoBattles = (Twin.yellowRocketDuoBattles or 0) + 1
  local function battle()
    KantoGameplay.runQuestTrainerBattle(world, trainer, function(outcome)
      if outcome == "win" or outcome == true then
        KantoState.setEvent(q.duoEvent, true)
        KantoState.hideObjectsByText(region, mapId, {
          TEXT_ROCKETHIDEOUTB4F_JESSIE = true,
          TEXT_ROCKETHIDEOUTB4F_JAMES = true,
        })
        Twin.yellowRocketDuoWins = (Twin.yellowRocketDuoWins or 0) + 1
      end
    end)
  end
  return showMessage(world, "Stop right there! TEAM ROCKET won't let you reach the BOSS!", battle)
    or battle() or true
end

function KantoGameplay.towerMarowakStep(world, region, mapId, x, y)
  local q = KantoState.Items.POKEMON_TOWER
  if tostring(mapId or "") ~= tostring(q.marowakMap or "")
      or tonumber(x) ~= tonumber(q.marowakX) or tonumber(y) ~= tonumber(q.marowakY)
      or KantoState.event(q.marowakEvent) then return false end
  if not KantoGameplay.ensureKantoLocalItem(world, region, "SILPH_SCOPE") then
    Twin.yellowTowerGhostBlocks = (Twin.yellowTowerGhostBlocks or 0) + 1
    return showMessage(world, "Be gone... The ghost cannot be identified without the SILPH SCOPE!")
  end
  local trainer = KantoGameplay.makeQuestTrainer(world, {
    id = "YELLOW_RESTLESS_SOUL", name = "RESTLESS SOUL", classId = "CHANNELER",
    roster = { { species = "MAROWAK", level = 30 } },
  })
  Twin.yellowMarowakBattles = (Twin.yellowMarowakBattles or 0) + 1
  local function battle()
    KantoGameplay.runQuestTrainerBattle(world, trainer, function(outcome)
      if outcome == "win" or outcome == true then
        KantoState.setEvent(q.marowakEvent, true)
        Twin.yellowMarowakWins = (Twin.yellowMarowakWins or 0) + 1
        showMessage(world, "The ghost was the restless soul of CUBONE's mother. Its spirit was calmed.")
      end
    end)
  end
  return showMessage(world, "The SILPH SCOPE unveiled the ghost! MAROWAK appeared!", battle)
    or battle() or true
end

function KantoGameplay.towerRocketStep(world, region, mapId, x, y)
  local q = KantoState.Items.POKEMON_TOWER
  if tostring(mapId or "") ~= tostring(q.fujiMap or "")
      or tonumber(y) ~= tonumber(q.rocketY) or not (q.rocketX and q.rocketX[tonumber(x)])
      or KantoState.event(q.rocketEvent) or not KantoState.event(q.marowakEvent) then return false end
  for text in pairs(q.rocketTexts or {}) do KantoState.revealObjectByText(region, mapId, text) end
  local trainer, err = yellowTrainer(region, world,
    { trainerClass = "OPP_ROCKET", trainerParty = q.rocketParty or 44 })
  if not trainer then Twin.lastBattleError = err return false end
  Twin.yellowTowerRocketBattles = (Twin.yellowTowerRocketBattles or 0) + 1
  local function battle()
    KantoGameplay.runQuestTrainerBattle(world, trainer, function(outcome)
      if outcome == "win" or outcome == true then
        KantoState.setEvent(q.rocketEvent, true)
        KantoState.hideObjectsByText(region, mapId, q.rocketTexts or {})
        Twin.yellowTowerRocketWins = (Twin.yellowTowerRocketWins or 0) + 1
      end
    end)
  end
  return showMessage(world, "What do you want? Why are you here? TEAM ROCKET is keeping old man FUJI here!", battle)
    or battle() or true
end

function KantoGameplay.rescueMrFuji(world, region, mapId, obj)
  local q = KantoState.Items.POKEMON_TOWER
  if tostring(mapId or "") ~= tostring(q.fujiMap or "")
      or tostring(obj and obj.text or "") ~= tostring(q.fujiText or "") then return false end
  if not KantoState.event(q.marowakEvent) then
    return showMessage(world, "A restless spirit blocks the way to MR. FUJI.")
  end
  if not KantoState.event(q.rocketEvent) then
    return showMessage(world, "TEAM ROCKET is still holding MR. FUJI here.")
  end
  if KantoState.event(q.rescueEvent) then return true end
  KantoState.setEvent(q.rescueEvent, true)
  KantoState.setObjectHidden(mapId, obj, true)
  KantoState.setObjectShown(mapId, obj, false)
  KantoState.revealObjectByText(region, q.fujiHouseMap, q.fujiHouseText)
  Twin.yellowFujiRescues = (Twin.yellowFujiRescues or 0) + 1
  return showMessage(world, "MR. FUJI: You came to save me? Thank you. Come with me to my home.", function()
    KantoGameplay.transferToWarp(region, q.fujiHouseMap, 1)
  end)
end

function KantoGameplay.mrFujiFlute(world, region, mapId, obj)
  local q = KantoState.Items.POKEMON_TOWER
  if tostring(mapId or "") ~= tostring(q.fujiHouseMap or "")
      or tostring(obj and obj.text or "") ~= tostring(q.fujiHouseText or "") then return false end
  if not KantoState.event(q.rescueEvent) then return false end
  if KantoState.event(q.fluteEvent) then
    KantoState.giveLocalItem("POKE_FLUTE") -- old-save migration if the event predates local ownership
    return showMessage(world, "MR. FUJI: Has my POKé FLUTE helped you?")
  end
  if KantoState.itemHeld(world, "POKE_FLUTE") then
    KantoState.setEvent(q.fluteEvent, true)
    return showMessage(world, "MR. FUJI: Has my POKé FLUTE helped you?")
  end
  KantoState.giveLocalItem("POKE_FLUTE")
  KantoState.setEvent(q.fluteEvent, true)
  Twin.yellowPokeFlutes = (Twin.yellowPokeFlutes or 0) + 1
  return showMessage(world, "MR. FUJI: This may help your quest. Received the POKé FLUTE!")
end

function KantoGameplay.snorlaxInteraction(world, region, mapId, obj)
  local spec = KantoState.Items.SNORLAX[tostring(mapId or "")]
  if not spec or tostring(obj and obj.text or "") ~= tostring(spec.text or "") then return false end
  if KantoState.event(spec.event) then
    KantoState.setObjectHidden(mapId, obj, true)
    return true
  end
  if not KantoGameplay.ensureKantoLocalItem(world, region, "POKE_FLUTE") then
    return showMessage(world, "SNORLAX is sleeping soundly.")
  end
  return askYesNo(world, "Play the POKé FLUTE?", function(yes)
    if not yes then return end
    local wild = makeGoldWild(world, spec.species or "SNORLAX", spec.level or 30)
    if not wild or not (world and type(world.startBattle) == "function") then
      showMessage(world, "SNORLAX cannot battle on this build.")
      return
    end
    Twin.yellowSnorlaxBattles = (Twin.yellowSnorlaxBattles or 0) + 1
    excursion.battleBusy = true
    local function startSnorlaxBattle()
      local ok, started, err = pcall(world.startBattle, world, { wild = wild }, function(outcome)
        excursion.battleBusy = false
        excursion.prevA = false
        if outcome == "lose" then
          if Twin._handleKantoBattleLoss then pcall(Twin._handleKantoBattleLoss, world) end
          return
        end
        KantoState.setEvent(spec.event, true)
        KantoState.setObjectHidden(mapId, obj, true)
        KantoState.setObjectShown(mapId, obj, false)
        if region.npcCache then region.npcCache[mapId] = nil end
        KantoState.Spatial.invalidate(region, mapId, true, true)
        Twin.yellowSnorlaxClears = (Twin.yellowSnorlaxClears or 0) + 1
      end)
      if not ok or started == false then
        excursion.battleBusy = false
        Twin.lastBattleError = tostring(ok and err or started)
      end
    end
    if not showMessage(world, "SNORLAX woke up!", startSnorlaxBattle) then
      startSnorlaxBattle()
    end
  end)
end

-- v0.3.88: Silph Co 11F finale -> Saffron liberation -> Master Ball.
-- Yellow owns the authored trigger cells/object roles; Gold owns every battle
-- and the actual MASTER BALL item. No Yellow story VM is allowed to mutate
-- Gold state.
function KantoGameplay.silphDuoStep(world, region, mapId, x, y)
  local S, F = KantoState.Silph, KantoState.Silph.FINAL
  if not S.duoStep(mapId, x, y) or KantoState.event(F.duoEvent) then return false end
  KantoState.revealObjectByText(region, F.map, F.jamesText)
  KantoState.revealObjectByText(region, F.map, F.jessieText)
  local trainer, err = yellowTrainer(region, world,
    { trainerClass = "OPP_ROCKET", trainerParty = F.duoParty }, F.map)
  if not trainer then Twin.lastBattleError = err return false end
  Twin.yellowSilphDuoBattles = (Twin.yellowSilphDuoBattles or 0) + 1
  local intro = textByLabel(region, F.duoIntroLabel)
    or "TEAM ROCKET: Prepare for trouble!"
  local function battle()
    KantoGameplay.runQuestTrainerBattle(world, trainer, function(outcome)
      if outcome == "win" or outcome == true then
        KantoState.setEvent(F.duoEvent, true)
        KantoState.hideObjectsByText(region, F.map, {
          [F.jamesText] = true, [F.jessieText] = true,
        })
        Twin.yellowSilphDuoWins = (Twin.yellowSilphDuoWins or 0) + 1
        local after = textByLabel(region, F.duoAfterLabel)
        if after then showMessage(world, after) end
      end
    end)
  end
  return showMessage(world, intro, battle) or battle() or true
end
Twin._kantoSilphDuoStep = KantoGameplay.silphDuoStep

function KantoGameplay.silphGiovanniBattle(world, region)
  local S, F = KantoState.Silph, KantoState.Silph.FINAL
  if KantoState.event(F.giovanniEvent) then return false end
  if not KantoState.event(F.duoEvent) then
    return showMessage(world, "TEAM ROCKET is still blocking the President's office.")
  end
  local obj = KantoGameplay.questObjectByText(region, F.map, F.giovanniText)
    or { text = F.giovanniText, trainerClass = "OPP_GIOVANNI", trainerParty = F.giovanniParty }
  local trainer, err = yellowTrainer(region, world, obj, F.map)
  if not trainer then Twin.lastBattleError = err return false end
  -- This is the exact regression v0.3.88 closes: Silph Giovanni is a Rocket
  -- boss, not the Viridian Gym Leader encounter, and must never award EARTH.
  if trainer._stadiumYellowGym then
    Twin.lastBattleError = "Silph Giovanni was incorrectly classified as a Gym battle"
    return false
  end
  Twin.yellowNonGymGiovanniBattles = (Twin.yellowNonGymGiovanniBattles or 0) + 1
  Twin.yellowSilphGiovanniBattles = (Twin.yellowSilphGiovanniBattles or 0) + 1
  local intro = textByLabel(region, F.giovanniIntroLabel)
    or "GIOVANNI: So! I must say, I am impressed you got here!"
  local function battle()
    KantoGameplay.runQuestTrainerBattle(world, trainer, function(outcome)
      if outcome == "win" or outcome == true then
        if obj and obj.trainerClass then markTrainerDefeated(F.map, obj) end
        local newlyLiberated = KantoState.setEvent(F.giovanniEvent, true)
        KantoState.applySilphLiberation(region)
        Twin.yellowSilphGiovanniWins = (Twin.yellowSilphGiovanniWins or 0) + 1
        if newlyLiberated then
          Twin.yellowSilphLiberations = (Twin.yellowSilphLiberations or 0) + 1
        end
        local after = textByLabel(region, F.giovanniAfterLabel)
          or "GIOVANNI: You ruined our plans for SILPH! TEAM ROCKET will never fall!"
        showMessage(world, after)
      end
    end)
  end
  return showMessage(world, intro, battle) or battle() or true
end
Twin._kantoSilphGiovanniBattle = KantoGameplay.silphGiovanniBattle

function KantoGameplay.silphGiovanniStep(world, region, mapId, x, y)
  local S, F = KantoState.Silph, KantoState.Silph.FINAL
  if not S.giovanniStep(mapId, x, y) or KantoState.event(F.giovanniEvent) then return false end
  return KantoGameplay.silphGiovanniBattle(world, region)
end
Twin._kantoSilphGiovanniStep = KantoGameplay.silphGiovanniStep

function KantoGameplay.handleSilphStep(world, region, mapId, x, y)
  if KantoGameplay.silphDuoStep(world, region, mapId, x, y) then return true end
  if KantoGameplay.silphGiovanniStep(world, region, mapId, x, y) then return true end
  return false
end
Twin._handleKantoSilphStep = KantoGameplay.handleSilphStep

function KantoGameplay.silphGiovanniInteraction(world, region, mapId, obj)
  local S, F = KantoState.Silph, KantoState.Silph.FINAL
  if not S.isGiovanni(mapId, obj) then return false end
  if KantoState.event(F.giovanniEvent) then
    KantoState.migrateSilphState(region, mapId)
    return true
  end
  return KantoGameplay.silphGiovanniBattle(world, region)
end
Twin._kantoSilphGiovanniInteraction = KantoGameplay.silphGiovanniInteraction

function KantoGameplay.silphPresidentInteraction(world, region, mapId, obj)
  local S, F = KantoState.Silph, KantoState.Silph.FINAL
  if not S.isPresident(mapId, obj and obj.text) then return false end
  if not KantoState.event(F.giovanniEvent) then
    return showMessage(world, "TEAM ROCKET is holding SILPH CO. hostage!")
  end
  if KantoState.event(F.masterBallEvent) then
    return showMessage(world, textByLabel(region, F.presidentAfterLabel)
      or "The MASTER BALL will catch any POKéMON without fail!")
  end
  local game, save = world and world.game, world and world.game and world.game.save
  if not (game and save and game.data) then return false end
  save.inventory = save.inventory or {}
  local goldId = game.data.items and game.data.items.MASTER_BALL and "MASTER_BALL" or nil
  if not goldId then
    goldId = KantoState.Items.resolveGoldItem(game.data.items,
      region and region.loaded and region.loaded.items, "MASTER_BALL")
  end
  if not goldId then
    return showMessage(world, "Gold has no compatible MASTER BALL item in this build.")
  end
  local intro = textByLabel(region, F.presidentIntroLabel)
    or "PRESIDENT: Thank you for saving SILPH! Take this unique MASTER BALL!"
  local function give()
    local okBag, Bag = pcall(require, "src.inventory.Bag")
    if not (okBag and Bag and type(Bag.add) == "function") then return false end
    if not Bag.add(save, goldId, 1, game.data) then
      return showMessage(world, textByLabel(region, F.presidentNoRoomLabel)
        or "You have no room for this.")
    end
    KantoState.setEvent(F.masterBallEvent, true)
    Twin.yellowMasterBallGifts = (Twin.yellowMasterBallGifts or 0) + 1
    return showMessage(world, textByLabel(region, F.presidentReceivedLabel)
      or "Received MASTER BALL!")
  end
  return showMessage(world, intro, give) or give() or true
end
Twin._kantoSilphPresidentInteraction = KantoGameplay.silphPresidentInteraction

-- v0.3.87: Bill -> S.S. Ticket -> S.S. Anne rival -> Captain/CUT ->
-- departure. Yellow owns the authored maps/text and progression order; Gold
-- remains the sole owner of party, battle, HM inventory and save data.
function KantoGameplay.giveResolvedYellowItem(world, region, yellowId, amount)
  yellowId, amount = tostring(yellowId or ""), math.max(1, tonumber(amount) or 1)
  local game = world and world.game
  local save = game and game.save
  if yellowId == "" or not (game and save and game.data) then return false, "unavailable" end
  if KantoState.Items.isLocalOnly(yellowId) then
    return KantoState.giveLocalItem(yellowId), yellowId, "local"
  end
  save.inventory = save.inventory or {}
  local goldId, mode, move = KantoState.Items.resolveGoldItem(game.data.items,
    region and region.loaded and region.loaded.items, yellowId)
  if not goldId then return false, mode or "missing", move end
  -- HMs/key machines should not become duplicate bag entries just because the
  -- player already obtained the same Gold machine in Johto.
  if (tonumber(save.inventory[goldId]) or 0) > 0 then return true, goldId, "owned" end
  local okBag, Bag = pcall(require, "src.inventory.Bag")
  if not (okBag and Bag and type(Bag.add) == "function") then return false, "bag" end
  if not Bag.add(save, goldId, amount, game.data) then return false, "full" end
  if mode == "machine" then
    Twin.yellowSemanticItemConversions = (Twin.yellowSemanticItemConversions or 0) + 1
  end
  return true, goldId, mode
end
Twin._giveKantoResolvedYellowItem = KantoGameplay.giveResolvedYellowItem

function KantoGameplay.billObjectInteraction(world, region, mapId, obj)
  local S, B = KantoState.SSAnne, KantoState.SSAnne.BILL
  if tostring(mapId or "") ~= B.map then return false end
  local kind = S.billObject(obj and obj.text)
  if not kind then return false end

  if kind == "pokemon" then
    if KantoState.event(B.met2Event) then
      KantoState.migrateSSAnneObjects(region, B.map)
      return true
    end
    if KantoState.event(B.saidEvent) then
      return showMessage(world, "BILL is waiting inside the TELEPORTER.\fUse the PC to run the CELL SEPARATOR!")
    end
    KantoState.setEvent(B.saidEvent, true)
    KantoState.hideObjectsByText(region, B.map, { [B.pokemonText] = true })
    Twin.yellowBillHelps = (Twin.yellowBillHelps or 0) + 1
    return showMessage(world,
      "BILL: Hiya! I'm a POKéMON... No I'm not!\fHelp me out! Use my PC while I'm inside the TELEPORTER.")
  end

  if kind == "ticket" then
    if not KantoState.event(B.met2Event) then return false end
    if not KantoState.event(B.ticketEvent) then
      KantoState.giveLocalItem(B.ticketItem)
      KantoState.setEvent(B.ticketEvent, true)
      Twin.yellowSSTickets = (Twin.yellowSSTickets or 0) + 1
      return showMessage(world, "BILL: Thanks! This cruise ticket is yours.\fReceived the S.S. TICKET!")
    end
    -- Old-save repair: the event predates local-only ticket ownership.
    KantoState.giveLocalItem(B.ticketItem)
    return showMessage(world, "BILL: The S.S. ANNE is in VERMILION CITY. Why don't you go instead of me?")
  end

  if kind == "rare" then
    return showMessage(world,
      "BILL's favorite POKéMON:\nEEVEE / FLAREON\fJOLTEON / VAPOREON")
  end
  return false
end
Twin._kantoBillObjectInteraction = KantoGameplay.billObjectInteraction

function KantoGameplay.billPcInteraction(world, region, mapId, x, y)
  local S, B = KantoState.SSAnne, KantoState.SSAnne.BILL
  if not S.billPc(mapId, x, y, excursion.facing) then return false end
  if KantoState.event(B.leftEvent) then
    return showMessage(world, "BILL's PC lists EEVEE, FLAREON, JOLTEON and VAPOREON.")
  end
  if KantoState.event(B.usedEvent) then
    return showMessage(world, "The CELL SEPARATOR is idle now.")
  end
  if not KantoState.event(B.saidEvent) then
    return showMessage(world, "A TELEPORTER monitor. It isn't ready yet.")
  end

  KantoState.setEvent(B.usedEvent, true)
  KantoState.setEvent(B.metEvent, true)
  KantoState.setEvent(B.met2Event, true)
  KantoState.hideObjectsByText(region, B.map, { [B.pokemonText] = true, [B.rareText] = true })
  KantoState.revealObjectByText(region, B.map, B.ticketText)
  KantoState.giveLocalItem(B.ticketItem)
  KantoState.setEvent(B.ticketEvent, true)
  Twin.yellowSSTickets = (Twin.yellowSSTickets or 0) + 1
  KantoGameplay.playSound(world, "Switch")
  return showMessage(world,
    "The CELL SEPARATOR started!\fBILL returned to normal!\fBILL: Yeehah! Thanks, bud! Take this.\fReceived the S.S. TICKET!")
end
Twin._kantoBillPcInteraction = KantoGameplay.billPcInteraction

function KantoGameplay.ssAnneGuardTalk(world, region, mapId, obj)
  local S, B, G = KantoState.SSAnne, KantoState.SSAnne.BILL, KantoState.SSAnne.GATE
  if not S.guardObject(mapId, obj and obj.text) then return false end
  if KantoState.event(S.SHIP.leftEvent) then
    return showMessage(world, "The ship set sail.")
  end
  if not KantoGameplay.ensureKantoLocalItem(world, region, B.ticketItem) then
    return showMessage(world, "Welcome to the S.S. ANNE!\fYou need a ticket to get aboard.")
  end
  return showMessage(world, "Welcome to the S.S. ANNE!\fYou flashed the S.S. TICKET!")
end
Twin._kantoSSAnneGuardTalk = KantoGameplay.ssAnneGuardTalk

function KantoGameplay.ssAnneGateStep(world, region, mapId, x, y)
  local S, B, G = KantoState.SSAnne, KantoState.SSAnne.BILL, KantoState.SSAnne.GATE
  if not S.gateStep(mapId, x, y, excursion.facing) then return false end
  local function bounce()
    return KantoGameplay.relocate(region, G.map, G.x, G.y - 1, "up", excursion.lastOutside)
  end
  if KantoState.event(S.SHIP.leftEvent) then
    Twin.yellowSSAnneGateBlocks = (Twin.yellowSSAnneGateBlocks or 0) + 1
    return showMessage(world, "The ship set sail.", bounce) or (bounce() and true)
  end
  if not KantoGameplay.ensureKantoLocalItem(world, region, B.ticketItem) then
    Twin.yellowSSAnneGateBlocks = (Twin.yellowSSAnneGateBlocks or 0) + 1
    return showMessage(world, "You need a ticket to get aboard the S.S. ANNE.", bounce)
      or (bounce() and true)
  end
  if not KantoState.event(G.flashedEvent) then
    KantoState.setEvent(G.flashedEvent, true)
    return showMessage(world, "Welcome to the S.S. ANNE!\fYou flashed the S.S. TICKET!")
  end
  return false
end
Twin._kantoSSAnneGateStep = KantoGameplay.ssAnneGateStep

function KantoGameplay.ssAnneRivalStep(world, region, mapId, x, y)
  local S, R = KantoState.SSAnne, KantoState.SSAnne.RIVAL
  if not S.rivalStep(mapId, x, y) or KantoState.event(R.event) then return false end
  KantoState.revealObjectByText(region, R.map, R.text)
  local trainer, err = yellowTrainer(region, world,
    { trainerClass = R.trainerClass, trainerParty = R.trainerParty })
  if not trainer then Twin.lastBattleError = err return false end
  local intro = textByLabel(region, "_SSAnne2FRivalText")
    or "RIVAL: Bonjour! I heard there was a CUT master on board!"
  Twin.yellowSSAnneRivalBattles = (Twin.yellowSSAnneRivalBattles or 0) + 1
  local function battle()
    KantoGameplay.runQuestTrainerBattle(world, trainer, function(outcome)
      if outcome == "win" or outcome == true then
        KantoState.setEvent(R.event, true)
        KantoState.hideObjectsByText(region, R.map, { [R.text] = true })
        Twin.yellowSSAnneRivalWins = (Twin.yellowSSAnneRivalWins or 0) + 1
        showMessage(world, textByLabel(region, "_SSAnne2FRivalCutMasterText")
          or "RIVAL: The CUT master was seasick. Go see him yourself!")
      end
    end)
  end
  return showMessage(world, intro, battle) or battle() or true
end
Twin._kantoSSAnneRivalStep = KantoGameplay.ssAnneRivalStep

function KantoGameplay.ssAnneCaptainInteraction(world, region, mapId, obj)
  local S, C = KantoState.SSAnne, KantoState.SSAnne.CAPTAIN
  if not S.captainObject(mapId, obj and obj.text) then return false end
  if KantoState.event(C.gotEvent) then
    return showMessage(world, textByLabel(region, "_SSAnneCaptainsRoomCaptainNotSickAnymoreText")
      or "CAPTAIN: Whew! I'm not sick anymore!")
  end
  KantoState.setEvent(C.rubbedEvent, true)
  local ok, itemOrWhy = KantoGameplay.giveResolvedYellowItem(world, region, C.item, 1)
  if not ok then
    return showMessage(world, textByLabel(region, "_SSAnneCaptainsRoomCaptainHM01NoRoomText")
      or "CAPTAIN: Your PACK has no room for HM01.")
  end
  KantoState.setEvent(C.gotEvent, true)
  Twin.yellowCaptainCutGifts = (Twin.yellowCaptainCutGifts or 0) + 1
  return showMessage(world,
    "You rubbed the CAPTAIN's back.\fCAPTAIN: Whew! Thank you! I feel much better!\fReceived HM01 CUT!")
end
Twin._kantoSSAnneCaptainInteraction = KantoGameplay.ssAnneCaptainInteraction

function KantoGameplay.handleSSAnneStep(world, region, mapId, x, y)
  if KantoGameplay.ssAnneGateStep(world, region, mapId, x, y) then return true end
  if KantoGameplay.ssAnneRivalStep(world, region, mapId, x, y) then return true end
  return false
end
Twin._handleKantoSSAnneStep = KantoGameplay.handleSSAnneStep

function KantoGameplay.ssAnneWarpTransition(region, fromMap, toMap)
  local S, C = KantoState.SSAnne, KantoState.SSAnne.CAPTAIN
  if not S.shipExitTransition(fromMap, toMap)
      or not KantoState.event(C.gotEvent)
      or KantoState.event(S.SHIP.leftEvent) then return false end
  KantoState.setEvent(S.SHIP.leftEvent, true)
  local dock = ensureForeignMap(region, S.SHIP.dockMap)
  if dock then KantoState.restampSSAnneDock(region, S.SHIP.dockMap, dock) end
  Twin.yellowSSAnneDepartures = (Twin.yellowSSAnneDepartures or 0) + 1
  local world = excursion.world
  local function leaveDock()
    KantoGameplay.relocate(region, S.SHIP.cityMap, S.SHIP.exitX, S.SHIP.exitY,
      S.SHIP.exitFacing, excursion.lastOutside)
  end
  if not showMessage(world, "S.S. ANNE set sail!", leaveDock) then leaveDock() end
  return true
end
Twin._kantoSSAnneWarpTransition = KantoGameplay.ssAnneWarpTransition

function KantoGameplay.itemGateForStep(region, mapId, tx, ty, dir)
  local tower = KantoState.Items.POKEMON_TOWER
  if tostring(mapId or "") == tostring(tower.marowakMap or "")
      and tonumber(tx) == tonumber(tower.marowakX)
      and tonumber(ty) == tonumber(tower.marowakY)
      and not KantoState.event(tower.marowakEvent) then
    return { item = "SILPH_SCOPE", quest = "tower_marowak",
      message = "The ghost cannot be identified without the SILPH SCOPE!" }
  end
  return KantoState.Items.stepGate(mapId, tx, ty, dir)
end

function KantoGameplay.showItemGateBlock(world, region, mapId, itemGate)
  if itemGate and itemGate.quest == "tower_marowak" then
    Twin.yellowTowerGhostBlocks = (Twin.yellowTowerGhostBlocks or 0) + 1
  else
    Twin.yellowCinnabarGymKeyBlocks = (Twin.yellowCinnabarGymKeyBlocks or 0) + 1
  end
  local line = itemGate and itemGate.message
    or interactionText(region, mapId, itemGate and itemGate.text)
    or ("A " .. tostring(itemGate and itemGate.item or "KEY"):gsub("_", " ") .. " is required.")
  return showMessage(world, line)
end


-- v0.3.93: Cerulean stolen-TM mainline parity.
-- In Yellow the Rocket thief stays after defeat until he successfully returns
-- TM28 DIG; a full bag leaves him in place so the player can retry.  Gold has
-- TM28 DIG too, so this can be represented exactly without a Gen-1-only item.
function KantoGameplay.ceruleanRocketTM(world, region, mapId, obj)
  if tostring(mapId or "") ~= "CERULEAN_CITY"
      or tostring(obj and obj.text or "") ~= "TEXT_CERULEANCITY_ROCKET" then
    return false
  end
  if not KantoState.event("EVENT_BEAT_CERULEAN_ROCKET_THIEF") then
    return false -- let the normal trainer interaction start the battle
  end
  if KantoState.event("EVENT_KANTO_RETURNED_STOLEN_TM28") then
    KantoState.setObjectHidden(mapId, obj, true)
    return showMessage(world, "The Rocket thief is gone.")
  end

  local game, save = world and world.game, world and world.game and world.game.save
  if not (game and save) then return true end
  local reward = {
    candidates = { "TM28", "TM_DIG" },
    teaches = { "DIG" },
    display = "TM28",
  }
  return showMessage(world, KantoGameplay.rewardText(world, region,
    "_CeruleanCityRocketIllReturnTheTMText",
    "OK! I'll return the TM I stole!"), function()
      local added, itemId, why = KantoGameplay.rewardBagAdd(game, save, reward)
      if not added then
        showMessage(world, KantoGameplay.rewardText(world, region,
          "_CeruleanCityRocketTM28NoRoomText",
          why or "You have no room for TM28!"))
        return
      end
      KantoState.setEvent("EVENT_KANTO_RETURNED_STOLEN_TM28", true)
      KantoState.migrateCeruleanRobberyObjects(region, mapId)
      Twin.yellowCeruleanTM28Returns = (Twin.yellowCeruleanTM28Returns or 0) + 1
      KantoGameplay.playSound(world, "Get_Key_Item")
      showMessage(world, KantoGameplay.rewardText(world, region,
        "_CeruleanCityRocketReceivedTM28Text",
        "Received TM28 DIG!"))
    end)
end
Twin._talkKantoCeruleanRocketTM = KantoGameplay.ceruleanRocketTM

function KantoGameplay.ceruleanRobbedHouseTalk(world, region, mapId, obj)
  if tostring(mapId or "") ~= "CERULEAN_TRASHED_HOUSE" or not obj then return false end
  local text = tostring(obj.text or "")
  if text ~= "TEXT_CERULEANTRASHEDHOUSE_FISHING_GURU" then return false end
  local save = world and world.game and world.game.save
  local inv = save and save.inventory or {}
  local hasDig = (tonumber(inv.TM28) or 0) > 0 or (tonumber(inv.TM_DIG) or 0) > 0
  if hasDig then
    return showMessage(world, textByLabel(region,
      "_CeruleanTrashedHouseFishingGuruWhatsLostIsLostText")
      or "What's lost is lost. I decided to teach DIG without a TM.")
  end
  return showMessage(world, textByLabel(region,
    "_CeruleanTrashedHouseFishingGuruTheyStoleATMText")
    or "TEAM ROCKET must be trying to DIG their way into no good!")
end
Twin._talkKantoCeruleanRobbedHouse = KantoGameplay.ceruleanRobbedHouseTalk

function KantoGameplay.trySpecialObjectInteraction(world, region, mapId, obj)
  local textConst = obj and obj.text
  if not textConst then return false end
  if KantoGameplay.SummerBeach and type(KantoGameplay.SummerBeach.interact) == "function"
      and KantoGameplay.SummerBeach.interact({
        world = world, region = region, mapId = mapId, obj = obj, excursion = excursion,
        twin = Twin, persistenceGet = persistenceGet, persistenceSet = persistenceSet,
        showMessage = showMessage, askYesNo = askYesNo, textByLabel = textByLabel,
      }) then return true end
  if KantoGameplay.ceruleanRobbedHouseTalk(world, region, mapId, obj) then return true end
  if KantoGameplay.ceruleanRocketTM(world, region, mapId, obj) then return true end
  if KantoGameplay.championInteraction(world, region, mapId, obj) then return true end
  if KantoGameplay.silphPresidentInteraction(world, region, mapId, obj) then return true end
  if KantoGameplay.silphGiovanniInteraction(world, region, mapId, obj) then return true end
  if KantoGameplay.billObjectInteraction(world, region, mapId, obj) then return true end
  if KantoGameplay.ssAnneGuardTalk(world, region, mapId, obj) then return true end
  if KantoGameplay.ssAnneCaptainInteraction(world, region, mapId, obj) then return true end
  if KantoGameplay.takeMtMoonFossil(world, region, mapId, obj) then return true end
  if tostring(mapId or "") == KantoState.Items.FOSSIL_LAB.map
      and tostring(textConst) == KantoState.Items.FOSSIL_LAB.scientist then
    return KantoGameplay.fossilScientist(world, region)
  end
  if KantoGameplay.snorlaxInteraction(world, region, mapId, obj) then return true end
  if KantoGameplay.rescueMrFuji(world, region, mapId, obj) then return true end
  if KantoGameplay.mrFujiFlute(world, region, mapId, obj) then return true end
  local tower = KantoState.Items.POKEMON_TOWER
  if tostring(mapId or "") == tostring(tower.fujiMap or "")
      and tower.rocketTexts and tower.rocketTexts[tostring(textConst)] then
    return KantoGameplay.towerRocketStep(world, region, mapId, 10, tower.rocketY)
  end
  local Civic = KantoState.Civic
  local gate = Civic.gate(mapId)
  if gate and tostring(textConst) == tostring(gate.guardText or "") then
    return KantoGameplay.saffronGuardTalk(world, region, mapId, obj)
  end
  if Civic.isMuseumClerk(mapId, textConst) then
    return KantoGameplay.museumTicket(world, region, false)
  end
  if Civic.isAmberScientist(mapId, textConst) then
    return KantoGameplay.giveMuseumAmber(world, region, mapId)
  end
  if Civic.isFanClubChairman(mapId, textConst) then
    return KantoGameplay.fanClubChairman(world, region)
  end
  if Civic.isBikeShopClerk(mapId, textConst) then
    return KantoGameplay.bikeShopClerk(world, region)
  end
  if KantoGameplay.copycatTrade(world, region, mapId, obj) then return true end
  if KantoGameplay.celadonDrinkGirl(world, region, mapId, obj) then return true end
  local SafariProgress = KantoState.SafariProgress
  if SafariProgress.isSecretHouse(mapId, textConst) then
    return KantoGameplay.scriptedItemGift(world, region, SafariProgress.SECRET_HOUSE)
  end
  if SafariProgress.isWarden(mapId, textConst) then
    return KantoGameplay.wardenReward(world, region)
  end
  local reward = KantoState.Rewards.match(mapId, textConst)
  if reward then
    return KantoGameplay.scriptedReward(world, region, reward)
  end
  local starterGift = KantoState.StarterGifts.match(mapId, textConst)
  if starterGift then
    return KantoGameplay.starterGift(world, region, starterGift)
  end
  if mapId == "SAFARI_ZONE_GATE" and textConst == "TEXT_SAFARIZONEGATE_SAFARI_ZONE_WORKER1" then
    return KantoGameplay.startSafariGame(world)
  end
  if mapId == "SAFARI_ZONE_GATE" and textConst == "TEXT_SAFARIZONEGATE_SAFARI_ZONE_WORKER2" then
    return KantoGameplay.explainSafari(world)
  end
  if mapId == "GAME_CORNER" and (textConst == "TEXT_GAMECORNER_CLERK"
      or textConst == "TEXT_GAMECORNER_CLERK1") then
    return KantoGameplay.coinClerk(world)
  end
  local rod = KantoGameplay.ROD_GIVERS[textConst]
  if rod then return KantoGameplay.giveRod(world, rod) end
  local tradeIndex = KantoGameplay.TRADE_BY_TEXT[textConst]
  if tradeIndex then return KantoGameplay.openTrade(world, region, mapId, obj, tradeIndex) end
  return false
end
Twin._tryKantoSpecialObjectInteraction = KantoGameplay.trySpecialObjectInteraction

function KantoGameplay.openGameCornerPoster(world, region, map)
  local poster = KantoState.gameCornerPoster(region)
  if not (map and tostring(map.id or map.sourceId or ""):gsub("^__GEN1__", "")
      == tostring(poster.map or "GAME_CORNER")) then return false end
  local text = textByLabel(region, "_GameCornerPosterSwitchBehindPosterText")
    or "Hey!\fA switch behind\nthe poster!?\nLet's push it!"
  local event = poster.event or "EVENT_FOUND_ROCKET_HIDEOUT"
  if KantoState.event(event) then return showMessage(world, text) end
  KantoGameplay.playSound(world, "Switch")
  return showMessage(world, text, function()
    KantoState.setEvent(event, true)
    KantoGameplay.playSound(world, "Go_Inside")
    if KantoState.refreshBlock(map, poster.x, poster.y, poster.openBlock) then
      Twin.yellowGameCornerPosterOpens = (Twin.yellowGameCornerPosterOpens or 0) + 1
    end
  end)
end
Twin._openGameCornerPoster = KantoGameplay.openGameCornerPoster

function KantoGameplay.trySpecialSignInteraction(world, region, mapId, sign)
  local elevator = KantoState.Items.ROCKET_ELEVATOR
  if tostring(mapId or "") == tostring(elevator.map or "")
      and sign and tostring(sign.text or "") == tostring(elevator.text or "") then
    return KantoGameplay.rocketElevator(world, region)
  end
  local poster = KantoState.gameCornerPoster(region)
  if mapId == tostring(poster.map or "GAME_CORNER")
      and sign and tostring(sign.text or "") == tostring(poster.posterText or "TEXT_GAMECORNER_POSTER") then
    local map = ensureForeignMap(region, mapId)
    return KantoGameplay.openGameCornerPoster(world, region, map)
  end
  local window = sign and KantoGameplay.PRIZE_TEXT[sign.text]
  if mapId == "GAME_CORNER_PRIZE_ROOM" and window then
    return KantoGameplay.openPrizeCounter(world, window)
  end
  return false
end

function KantoGameplay.goldFieldMoveUser(world, moveId)
  local game = world and world.game
  local save = game and game.save
  if not (save and type(save.party) == "table") then return nil, nil, false end
  local okField, FieldMoves = pcall(require, "src.world.gen2.FieldMoves")
  if not okField or type(FieldMoves) ~= "table" then return nil, nil, false end
  local mon = type(FieldMoves.partyMoveUser) == "function"
    and FieldMoves.partyMoveUser(save.party, moveId, {
      save = save, data = game.data, party = save.party, moveId = moveId,
    }) or nil
  -- While walking Yellow Kanto, field HMs obey Yellow's badge table rather
  -- than Gold's Johto table. This prevents a completed Johto save from
  -- silently bypassing Kanto's own gym progression (and avoids requiring
  -- Johto-only badges such as Fog/Storm inside the imported region).
  local hasBadge = KantoState.hasKantoFieldBadge(world, moveId)
  return FieldMoves, mon, hasBadge == true
end

function KantoGameplay.isCenterMap(region, mapId)
  local def = sourceMapDef(region, mapId)
  local id = tostring(mapId or "")
  local ts = tostring(def and def.tileset or "")
  return id:find("POKECENTER", 1, true) ~= nil
      or id:find("POKEMON_CENTER", 1, true) ~= nil
      or ts:find("POKECENTER", 1, true) ~= nil
end

function KantoGameplay.safeCenterCell(map, x, y)
  if not map then return nil end
  local candidates = {
    {x, y - 1}, {x - 1, y}, {x + 1, y}, {x, y + 1}, {x, y},
    {x, y - 2}, {x - 1, y - 1}, {x + 1, y - 1},
  }
  for _, c in ipairs(candidates) do
    if passable(map, c[1], c[2], false) then
      local warp = type(map.warpAtCell) == "function" and map:warpAtCell(c[1], c[2]) or nil
      if not warp then return c[1], c[2] end
    end
  end
  return nearbyWalkable(map, x, y, false)
end

function KantoGameplay.rememberCenter(region, mapId, x, y)
  if not KantoGameplay.isCenterMap(region, mapId) then return false end
  local map = ensureForeignMap(region, mapId)
  if not map then return false end
  local sx, sy = KantoGameplay.safeCenterCell(map, tonumber(x) or 0, tonumber(y) or 0)
  if sx == nil then return false end
  persistenceSet(KantoState.HEAL_POINT_KEY, {
    mapId = mapId, x = sx, y = sy, facing = "up",
    lastOutside = deepCopy(excursion.lastOutside),
  })
  Twin.yellowCenterSpawns = (Twin.yellowCenterSpawns or 0) + 1
  return true
end
Twin._rememberKantoCenter = KantoGameplay.rememberCenter

function KantoGameplay.healPoint(region)
  local saved = persistenceGet(KantoState.HEAL_POINT_KEY, nil)
  if type(saved) ~= "table" or type(saved.mapId) ~= "string" then return nil end
  local map = ensureForeignMap(region, saved.mapId)
  if not map then return nil end
  local x, y = KantoGameplay.safeCenterCell(map, tonumber(saved.x) or 0, tonumber(saved.y) or 0)
  if x == nil then return nil end
  return { mapId = saved.mapId, x = x, y = y, facing = saved.facing or "up",
    lastOutside = deepCopy(saved.lastOutside) }
end

function KantoGameplay.relocate(region, mapId, x, y, facing, lastOutside)
  local map = region and mapId and ensureForeignMap(region, mapId)
  if not map then return false end
  x, y = nearbyWalkable(map, tonumber(x) or 0, tonumber(y) or 0, false)
  if x == nil then return false end
  excursion.sourceMapId = mapId
  KantoState.onMapEntered(region, mapId)
  excursion.cellX, excursion.cellY = x, y
  excursion.drawPx, excursion.drawPy = x * 16, y * 16
  excursion.facing = facing or "down"
  excursion.moving, excursion.moveT = false, 0
  excursion.toMapId, excursion.toCellX, excursion.toCellY = nil, nil, nil
  excursion.surfing, excursion.strengthActive = false, false
  excursion.biking, excursion.forcedBike = false, false
  excursion.forcedMovementCheckKey = nil
  excursion.forcedMoves, excursion.forcedMoveIndex, excursion.seafoamCurrentLock = nil, 0, false
  Twin._clearWarpIgnore()
  excursion.standingOnWarp = false
  excursion.lastOutside = deepCopy(lastOutside or excursion.lastOutside)
  clearDirectionalBody(false)
  excursion.currentRecord = recordBySource(region, mapId)
  Twin.excursionSourceMap, Twin.excursionCellX, Twin.excursionCellY = mapId, x, y
  persistExcursionPosition()
  return true
end

function KantoGameplay.handleBattleLoss(world)
  if not (excursion.active and excursion.region) then return false end
  if KantoState.League.isRunMap(excursion.sourceMapId)
      or KantoState.event(KantoState.League.START_EVENT) then
    KantoGameplay.resetLeagueRun(excursion.region)
  end
  healGoldParty(world)
  local point = KantoGameplay.healPoint(excursion.region)
  local ok
  if point then
    ok = KantoGameplay.relocate(excursion.region, point.mapId, point.x, point.y,
      point.facing, point.lastOutside)
  else
    local x, y = Twin._palletStart(excursion.region)
    ok = x ~= nil and KantoGameplay.relocate(excursion.region, "PALLET_TOWN", x, y,
      "down", { id = "PALLET_TOWN", x = x, y = y })
  end
  if ok then
    excursion.flashActive = false
    excursion.lastInteraction = "KANTO WHITEOUT"
    Twin.yellowWhiteouts = (Twin.yellowWhiteouts or 0) + 1
  end
  return ok == true
end
Twin._handleKantoBattleLoss = KantoGameplay.handleBattleLoss

function KantoGameplay.isDarkMap(region, mapId)
  mapId = tostring(mapId or "")
  if region and region.fieldIndex and region.fieldIndex.darkMaps then
    return region.fieldIndex.darkMaps[mapId] == true
  end
  local field = region and region.loaded and region.loaded.field
  local dark = field and field.darkMaps
  for _, id in ipairs(type(dark) == "table" and dark.maps or {}) do
    if tostring(id) == mapId then return true end
  end
  return false
end

function KantoGameplay.isDungeonMap(region, mapId)
  local def = sourceMapDef(region, mapId)
  local ts = tostring(def and def.tileset or "")
  if ts == "CAVERN" or ts == "CEMETERY" then return true end
  local id = tostring(mapId or "")
  for _, word in ipairs({ "MT_MOON", "ROCK_TUNNEL", "SEAFOAM", "VICTORY_ROAD",
      "DIGLETTS_CAVE", "CERULEAN_CAVE", "POKEMON_MANSION" }) do
    if id:find(word, 1, true) then return true end
  end
  return false
end

function KantoGameplay.ownsKantoBadge(world, token)
  return KantoState.kantoBadgeOwned(world, token)
end

function KantoGameplay.fieldActions(world)
  if not (excursion.active and excursion.region and excursion.sourceMapId) then return {} end
  local rows = {}
  local save = world and world.game and world.game.save
  if save and save.inventory and (tonumber(save.inventory.BICYCLE) or 0) > 0 then
    rows[#rows + 1] = { id = "BICYCLE",
      label = excursion.biking and "GET OFF BICYCLE" or "BICYCLE" }
  end
  if save and save.inventory and KantoGameplay.facingWater(excursion.region) then
    for _, rod in ipairs({ "OLD_ROD", "GOOD_ROD", "SUPER_ROD" }) do
      if save.inventory[rod] then
        rows[#rows + 1] = { id = "FISH_" .. rod, label = rod:gsub("_", " ") }
      end
    end
  end
  if KantoGameplay.isDarkMap(excursion.region, excursion.sourceMapId) and not excursion.flashActive then
    local _, mon, badge = KantoGameplay.goldFieldMoveUser(world, "FLASH")
    if mon and badge then rows[#rows + 1] = { id = "FLASH", label = "FLASH" } end
  end
  if KantoGameplay.isDungeonMap(excursion.region, excursion.sourceMapId) and excursion.lastOutside then
    local _, mon = KantoGameplay.goldFieldMoveUser(world, "DIG")
    if mon then rows[#rows + 1] = { id = "DIG", label = "DIG" } end
  end
  local def = sourceMapDef(excursion.region, excursion.sourceMapId)
  if mapIsOutdoor(nil, def) then
    local _, mon = KantoGameplay.goldFieldMoveUser(world, "TELEPORT")
    if mon and KantoGameplay.healPoint(excursion.region) then
      rows[#rows + 1] = { id = "TELEPORT", label = "TELEPORT" }
    end
  end
  return rows
end

function Twin.kantoFieldActions(game)
  return KantoGameplay.fieldActions(gameWorld(game))
end

function Twin.kantoUseFieldAction(game, action)
  if not excursion.active then return false, "Kanto free roam is not active" end
  local world, region = gameWorld(game), excursion.region
  action = tostring(action or ""):upper()
  local rod = action:match("^FISH_(.+)$")
  if rod then
    return KantoGameplay.useFishingRod(world, rod)
  end
  if action == "BICYCLE" then
    return KantoGameplay.toggleBicycle(world)
  end
  if action == "FLASH" then
    if not KantoGameplay.isDarkMap(region, excursion.sourceMapId) then return false, "It isn't dark here." end
    local _, mon, badge = KantoGameplay.goldFieldMoveUser(world, "FLASH")
    if not mon then return false, "No Gen-2 party member knows FLASH." end
    if not badge then return false, "A new BADGE is required for FLASH." end
    excursion.flashActive = true
    Twin.yellowFlashUses = (Twin.yellowFlashUses or 0) + 1
    return true
  elseif action == "DIG" then
    if not KantoGameplay.isDungeonMap(region, excursion.sourceMapId) then return false, "Can't use DIG here." end
    local _, mon = KantoGameplay.goldFieldMoveUser(world, "DIG")
    if not mon then return false, "No Gen-2 party member knows DIG." end
    local out = excursion.lastOutside
    if not (out and out.id) then return false, "No Kanto cave entrance is remembered." end
    if not KantoGameplay.relocate(region, out.id, out.x, out.y, "down", out) then
      return false, "The Kanto cave exit is unavailable."
    end
    excursion.flashActive = false
    Twin.yellowDigUses = (Twin.yellowDigUses or 0) + 1
    return true
  elseif action == "TELEPORT" then
    local _, mon = KantoGameplay.goldFieldMoveUser(world, "TELEPORT")
    if not mon then return false, "No Gen-2 party member knows TELEPORT." end
    local point = KantoGameplay.healPoint(region)
    if not point then return false, "Visit a Kanto POKéMON CENTER first." end
    if not KantoGameplay.relocate(region, point.mapId, point.x, point.y, point.facing, point.lastOutside) then
      return false, "The Kanto heal point is unavailable."
    end
    excursion.flashActive = false
    Twin.yellowTeleportUses = (Twin.yellowTeleportUses or 0) + 1
    return true
  end
  return false, "Unknown Kanto field action"
end

function KantoGameplay.cutSwapFor(region, map, cx, cy)
  if not (region and map and map:inBounds(cx, cy)) then return nil end
  local ts = map.def and map.def.tileset
  local tile = map:cellTile(cx, cy)
  local isGrass = ts == "OVERWORLD" and tile == 0x52
  if not ((ts == "OVERWORLD" and tile == 0x3d)
      or (ts == "GYM" and tile == 0x50) or isGrass) then return nil end
  local bx, by = math.floor(cx / 2), math.floor(cy / 2)
  local block = map:blockAt(bx, by)
  local swaps = region.loaded and region.loaded.field and region.loaded.field.cutTreeSwaps
  for _, sw in ipairs(type(swaps) == "table" and swaps or {}) do
    if tonumber(sw.before) == tonumber(block) and tonumber(sw.after) then
      return { bx = bx, by = by, before = block, after = tonumber(sw.after), grass = isGrass }
    end
  end
  return nil
end

function KantoGameplay.persistCutBlock(region, mapId, map, swap)
  if not (region and mapId and map and swap
      and KantoState.refreshBlock(map, swap.bx, swap.by, swap.after)) then
    return false
  end
  local state = KantoState.table(KantoState.CUT_BLOCKS_KEY)
  state[mapId] = type(state[mapId]) == "table" and state[mapId] or {}
  state[mapId][tostring(swap.bx) .. "," .. tostring(swap.by)] = math.floor(swap.after)
  persistenceSet(KantoState.CUT_BLOCKS_KEY, state)
  Twin.yellowCuts = (Twin.yellowCuts or 0) + 1
  return true
end

function KantoGameplay.tryYellowCut(world, region, mapId, map, tx, ty)
  local swap = KantoGameplay.cutSwapFor(region, map, tx, ty)
  if not swap then return false end
  local FieldMoves, mon, hasBadge = KantoGameplay.goldFieldMoveUser(world, "CUT")
  if not (mon and hasBadge) then
    local text = FieldMoves and FieldMoves.TEXT and FieldMoves.TEXT.CAN_CUT
      or "This tree can be\nCUT!"
    return showMessage(world, tostring(text))
  end
  local ask = FieldMoves and FieldMoves.TEXT and FieldMoves.TEXT.ASK_CUT
    or "This tree can be\nCUT!\fWant to use CUT?"
  return askYesNo(world, tostring(ask), function(yes)
    if not yes then return end
    KantoGameplay.persistCutBlock(region, mapId, map, swap)
    local name = mon.nickname or mon.name or mon.species or "POKEMON"
    local used = FieldMoves and FieldMoves.TEXT and FieldMoves.TEXT.USE_CUT
      or (name .. " used CUT!")
    showMessage(world, tostring(used):gsub("{STRBUF}", tostring(name)))
  end)
end
Twin._tryYellowCut = KantoGameplay.tryYellowCut
Twin._cutSwapFor = KantoGameplay.cutSwapFor

function KantoGameplay.tryYellowStrength(world, boulder)
  if not (boulder and boulder.isBoulder) then return false end
  local FieldMoves, mon, hasBadge = KantoGameplay.goldFieldMoveUser(world, "STRENGTH")
  if not (FieldMoves and mon and hasBadge) then
    local text = FieldMoves and FieldMoves.TEXT and FieldMoves.TEXT.BOULDERS_MAY_MOVE
      or "A POKEMON may be\nable to move this."
    return showMessage(world, tostring(text))
  end
  if excursion.strengthActive then
    local text = FieldMoves.TEXT and FieldMoves.TEXT.BOULDERS_MOVE
      or "Boulders may now\nbe moved!"
    return showMessage(world, tostring(text))
  end
  local ask = FieldMoves.TEXT and FieldMoves.TEXT.ASK_STRENGTH
    or "A POKEMON may be\nable to move this.\fWant to use\nSTRENGTH?"
  return askYesNo(world, tostring(ask), function(yes)
    if not yes then return end
    excursion.strengthActive = true
    Twin.yellowStrengthUses = (Twin.yellowStrengthUses or 0) + 1
    local name = mon.nickname or mon.name or mon.species or "POKEMON"
    local used = FieldMoves.TEXT and FieldMoves.TEXT.USE_STRENGTH
      or (name .. " used STRENGTH!")
    local after = FieldMoves.TEXT and FieldMoves.TEXT.MOVE_BOULDER
      or (name .. " can move boulders.")
    showMessage(world, tostring(used):gsub("{STRBUF}", tostring(name))
      .. "\f" .. tostring(after):gsub("{STRBUF}", tostring(name)))
  end)
end
Twin._tryYellowStrength = KantoGameplay.tryYellowStrength

function KantoGameplay.seafoamDef(region, mapId)
  local field = region and region.loaded and region.loaded.field
  return field and type(field.seafoam) == "table" and field.seafoam[mapId] or nil
end

function KantoGameplay.seafoamEventsSatisfied(events)
  if type(events) ~= "table" or #events == 0 then return false end
  for _, event in ipairs(events) do
    if not KantoState.seafoamEvent(event) then return false end
  end
  return true
end

function KantoGameplay.seafoamHoleAt(region, mapId, x, y)
  local def = KantoGameplay.seafoamDef(region, mapId)
  for _, hole in ipairs(def and def.holes or {}) do
    if tonumber(hole.x) == x and tonumber(hole.y) == y then return hole, def end
  end
  return nil, def
end

function KantoGameplay.findBoulderObject(region, mapId, x, y)
  local def = region and region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  for _, obj in ipairs(def and def.objects or {}) do
    if KantoState.isBoulder(obj) and tonumber(obj.x) == tonumber(x) and tonumber(obj.y) == tonumber(y) then
      return obj
    end
  end
  return nil
end

function KantoGameplay.dropSeafoamBoulder(region, mapId, boulder, hole, def)
  if not (region and boulder and hole and def) then return false end
  local destId = def.holeDestination
  local landing = hole.landsAt
  if not (destId and type(landing) == "table") then return false end
  local destObj = KantoGameplay.findBoulderObject(region, destId, landing.x, landing.y)
  if not destObj then return false end
  KantoState.setBoulderVisible(mapId, boulder.def, false)
  KantoState.setBoulderVisible(destId, destObj, true)
  KantoState.persistBoulderPosition(destId, destObj, tonumber(landing.x) or 0, tonumber(landing.y) or 0)
  KantoState.setSeafoamEvent(hole.boulderEvent)
  region.npcCache[mapId] = nil
  region.npcCache[destId] = nil
  KantoState.Spatial.invalidate(region, mapId, true, false)
  KantoState.Spatial.invalidate(region, destId, true, false)
  Twin.yellowSeafoamDrops = (Twin.yellowSeafoamDrops or 0) + 1
  return true
end
Twin._seafoamHoleAt = KantoGameplay.seafoamHoleAt
Twin._dropSeafoamBoulder = KantoGameplay.dropSeafoamBoulder

function KantoGameplay.dropVictoryRoadBoulder(region, mapId, boulder, hole)
  if not (region and boulder and boulder.def and hole) then return false end
  local destId = tostring(hole.destMap or "")
  local destObj = KantoGameplay.findBoulderObject(region, destId, hole.destX, hole.destY)
  if destId == "" or not destObj then return false end
  KantoState.setBoulderVisible(mapId, boulder.def, false)
  KantoState.setBoulderVisible(destId, destObj, true)
  KantoState.persistBoulderPosition(destId, destObj,
    tonumber(hole.destX) or 0, tonumber(hole.destY) or 0)
  KantoState.setEvent(hole.event, true)
  if region.npcCache then
    region.npcCache[mapId], region.npcCache[destId] = nil, nil
  end
  KantoState.Spatial.invalidate(region, mapId, true, false)
  KantoState.Spatial.invalidate(region, destId, true, false)
  Twin.yellowVictoryRoadBoulderDrops = (Twin.yellowVictoryRoadBoulderDrops or 0) + 1
  return true
end
Twin._dropVictoryRoadBoulder = KantoGameplay.dropVictoryRoadBoulder

function KantoGameplay.activateVictoryRoadSwitch(region, mapId, map, boulder)
  if not (boulder and map) then return false end
  local P = KantoState.DungeonPuzzles
  local row = P.victorySwitchAt(mapId, boulder.cellX, boulder.cellY)
  if not row then return false end
  local changed = KantoState.setEvent(row.event, true)
  KantoState.restampDungeonPuzzleMap(region, mapId, map)
  if changed then Twin.yellowVictoryRoadSwitches = (Twin.yellowVictoryRoadSwitches or 0) + 1 end
  return true
end
Twin._activateVictoryRoadSwitch = KantoGameplay.activateVictoryRoadSwitch

function KantoGameplay.tryPushBoulder(world, region, mapId, boulder, dir)
  if not (excursion.strengthActive and boulder and boulder.isBoulder and KantoGameplay.DIR_DELTA[dir]) then
    return false
  end
  local map = ensureForeignMap(region, mapId)
  if not map then return false end
  local d = KantoGameplay.DIR_DELTA[dir]
  local nx, ny = boulder.cellX + d[1], boulder.cellY + d[2]
  local hole, seafoam = KantoGameplay.seafoamHoleAt(region, mapId, nx, ny)
  local victoryHole = KantoState.DungeonPuzzles.victoryBoulderHole(mapId, nx, ny)
  local anyHole = hole or victoryHole
  if not map:inBounds(nx, ny) or (not anyHole and not passable(map, nx, ny, false))
      or occupiedByNpc(region, mapId, nx, ny, boulder)
      or pokemonAt(region, mapId, nx, ny)
      or (map:warpAtCell(nx, ny) and not anyHole) then
    return false
  end
  if hole and KantoGameplay.dropSeafoamBoulder(region, mapId, boulder, hole, seafoam) then
    Twin.yellowBoulderPushes = (Twin.yellowBoulderPushes or 0) + 1
    return true
  end
  if victoryHole and KantoGameplay.dropVictoryRoadBoulder(region, mapId, boulder, victoryHole) then
    Twin.yellowBoulderPushes = (Twin.yellowBoulderPushes or 0) + 1
    return true
  end
  local oldX, oldY = boulder.cellX, boulder.cellY
  KantoState.Spatial.move(region, mapId, "npc", boulder, oldX, oldY, nx, ny)
  boulder.cellX, boulder.cellY = nx, ny
  boulder.px, boulder.py = nx * 16, ny * 16
  boulder.stepFlip = not boulder.stepFlip
  boulder.facing = dir
  KantoState.persistBoulderPosition(mapId, boulder.def, nx, ny)
  KantoGameplay.activateVictoryRoadSwitch(region, mapId, map, boulder)
  Twin.yellowBoulderPushes = (Twin.yellowBoulderPushes or 0) + 1
  return true
end
Twin._tryPushBoulder = KantoGameplay.tryPushBoulder

function KantoGameplay.tryFreeBoulderPush(world, region, mapId, wx, wz)
  if not excursion.strengthActive then return false end
  local dir = directionFromWorldVector(wx, wz)
  if not dir then return false end
  local tx, ty = facingCell(excursion.cellX, excursion.cellY, dir)
  local boulder = npcAt(region, mapId, tx, ty)
  if not (boulder and boulder.isBoulder) then return false end
  -- Wait until the circular body actually reaches the shared cell edge; this
  -- prevents a held stick from pushing a rock from the middle of the tile.
  local x, z = excursion.freeX or 0, excursion.freeZ or 0
  local edgeDistance
  if dir == "right" then edgeDistance = (excursion.cellX + 1) * 16 - x
  elseif dir == "left" then edgeDistance = x - excursion.cellX * 16
  elseif dir == "down" then edgeDistance = (excursion.cellY + 1) * 16 - z
  else edgeDistance = z - excursion.cellY * 16 end
  if edgeDistance > KANTO_FREE_RADIUS + 1.25 then return false end
  return KantoGameplay.tryPushBoulder(world, region, mapId, boulder, dir)
end
Twin._tryFreeBoulderPush = KantoGameplay.tryFreeBoulderPush

function KantoGameplay.engageYellowTrainer(world, region, mapId, obj, header, entity, fromSight)
  if not (obj and obj.trainerClass) then return false end
  if trainerDefeated(mapId, obj) then
    if fromSight then return false end
    local after = textByLabel(region, header and header.after)
    if after then return showMessage(world, after) end
    return showMessage(world, "Already defeated "
      .. tostring(obj.trainerClass):gsub("^OPP_", "") .. ".")
  end
  if excursion.battleBusy then return true end
  local trainer, err = yellowTrainer(region, world, obj, mapId)
  if not trainer then
    Twin.lastBattleError = tostring(err)
    showMessage(world, "Trainer data is unavailable. Re-import Pokemon Yellow.")
    excursion.trainerEngaging = false
    return true
  end
  if not (world and type(world.startScriptedBattle) == "function") then
    Twin.lastBattleError = "Gold trainer battle API unavailable"
    excursion.trainerEngaging = false
    return true
  end

  local function startTrainerBattle()
    if excursion.battleBusy then return end
    excursion.battleBusy = true
    Twin.yellowTrainerBattles = (Twin.yellowTrainerBattles or 0) + 1
    if trainer._stadiumYellowGym then
      Twin.yellowGymBattles = (Twin.yellowGymBattles or 0) + 1
    end
    local ok, started, errStart = pcall(world.startScriptedBattle, world, trainer, nil, function(outcome)
      excursion.battleBusy = false
      excursion.trainerEngaging = false
      excursion.prevA = false
      if tostring(mapId or "") == "OAKS_LAB"
          and tostring(obj and obj.text or "") == "TEXT_OAKSLAB_RIVAL"
          and tonumber(obj and obj.trainerParty) == 1 then
        KantoGameplay.recordOakLabRivalOutcome(outcome)
      end
      if outcome == "win" or outcome == true then
        markTrainerDefeated(mapId, obj)
        -- Game Corner's poster guard is one of the few defeated trainers that
        -- physically leaves the map. Persist only that disappearance so the
        -- switch cell becomes reachable, without running his Yellow exit ASM.
        if mapId == "GAME_CORNER" and tostring(obj.text or "") == "TEXT_GAMECORNER_ROCKET"
            and KantoState.setObjectHidden(mapId, obj, true) then
          region.npcCache[mapId], region.pokemonCache[mapId] = nil, nil
          KantoState.Spatial.invalidate(region, mapId, true, true)
          Twin.yellowGameCornerRocketExits = (Twin.yellowGameCornerRocketExits or 0) + 1
        end
        local physicalEvent = (header and header.event)
          or KantoState.trainerHeaderEvent(region, mapId, obj)
        if physicalEvent then KantoState.setEvent(physicalEvent, true) end
        KantoGameplay.afterQuestTrainerWin(region, mapId, obj)
        KantoGameplay.afterLeagueTrainerWin(region, mapId, obj, physicalEvent)
        local liveMap = ensureForeignMap(region, mapId)
        if liveMap then KantoState.restampClosedDoors(region, mapId, liveMap) end
        Twin.yellowTrainerWins = (Twin.yellowTrainerWins or 0) + 1
        if trainer._stadiumYellowGym then
          Twin.yellowGymWins = (Twin.yellowGymWins or 0) + 1
          local badge = awardGymBadge(world, obj.trainerClass)
          if badge then showMessage(world, "Received the " .. badge .. " BADGE!") end
        else
          local after = textByLabel(region, header and header.after)
          if after then showMessage(world, after) end
        end
      elseif outcome == "lose" and Twin._handleKantoBattleLoss then
        pcall(Twin._handleKantoBattleLoss, world)
      end
    end)
    if not ok or started == false then
      excursion.battleBusy = false
      excursion.trainerEngaging = false
      Twin.lastBattleError = tostring(ok and errStart or started)
      return false
    end
    Twin.lastBattleError = nil
    return true
  end

  local battleText = textByLabel(region, header and header.battle)
  if battleText and showMessage(world, battleText, startTrainerBattle) then return true end
  return startTrainerBattle()
end

function KantoGameplay.trainerSightDistance(entity, px, py, range)
  if not (entity and entity.def and entity.def.trainerClass) or entity.moving then return nil end
  range = tonumber(range) or 0
  if range <= 0 then return nil end
  local ex, ey, facing = entity.cellX, entity.cellY, entity.facing
  if facing == "up" and px == ex and py < ey then
    local d = ey - py; return d <= range and d or nil
  elseif facing == "down" and px == ex and py > ey then
    local d = py - ey; return d <= range and d or nil
  elseif facing == "left" and py == ey and px < ex then
    local d = ex - px; return d <= range and d or nil
  elseif facing == "right" and py == ey and px > ex then
    local d = px - ex; return d <= range and d or nil
  end
  return nil
end
Twin._trainerSightDistance = KantoGameplay.trainerSightDistance

function KantoGameplay.trainerSightClear(region, mapId, map, entity, distance)
  local d = KantoGameplay.DIR_DELTA[entity.facing]
  if not d then return false end
  for step = 1, distance - 1 do
    local x, y = entity.cellX + d[1] * step, entity.cellY + d[2] * step
    if not map:inBounds(x, y) or not passable(map, x, y, excursion.surfing)
        or occupiedByNpc(region, mapId, x, y, entity) then return false end
  end
  return true
end

function KantoGameplay.checkYellowTrainerSight(world)
  if excursion.battleBusy or excursion.trainerEngaging then return false end
  local region, mapId = excursion.region, excursion.sourceMapId
  local map = region and ensureForeignMap(region, mapId)
  if not map then return false end
  local npcs = entitiesForMap(region, mapId)
  local roles = KantoState.Spatial.roles(region, mapId, npcs)
  local wins = trainerWins()
  for _, entity in ipairs(roles.trainers or {}) do
    local obj = entity.def
    -- Alignment/facing is cheaper than persistence/header work and rejects the
    -- overwhelming majority of trainers on an ordinary route step. Use an
    -- effectively unbounded range first; only aligned candidates touch the
    -- cached win id/header and the authored sight-range/line-of-sight checks.
    local rawDistance = obj and KantoGameplay.trainerSightDistance(entity,
      excursion.cellX, excursion.cellY, math.huge) or nil
    if rawDistance and wins[trainerWinId(mapId, obj)] ~= true then
      local header = trainerHeader(region, mapId, obj)
      local range = tonumber(header and header.range) or 0
      local distance = range > 0 and rawDistance <= range and rawDistance or nil
      if distance and KantoGameplay.trainerSightClear(region, mapId, map, entity, distance) then
        excursion.trainerEngaging = true
        clearDirectionalBody(true)
        -- Yellow's trainer walk-up stops one cell away. Keep it atomic in this
        -- presentation-local layer so collision and battle ownership cannot
        -- race the camera while the intro box is opening.
        if distance > 1 then
          local d = KantoGameplay.DIR_DELTA[entity.facing]
          local oldX, oldY = entity.cellX, entity.cellY
          local nx, ny = excursion.cellX - d[1], excursion.cellY - d[2]
          KantoState.Spatial.move(region, mapId, "npc", entity, oldX, oldY, nx, ny)
          entity.cellX, entity.cellY = nx, ny
          entity.px, entity.py = entity.cellX * 16, entity.cellY * 16
        end
        Twin.yellowTrainerSightEngages = (Twin.yellowTrainerSightEngages or 0) + 1
        return KantoGameplay.engageYellowTrainer(world, region, mapId, obj, header, entity, true)
      end
    end
  end
  return false
end
Twin._checkYellowTrainerSight = KantoGameplay.checkYellowTrainerSight

function KantoGameplay.tickKantoNpcAI(world, dt, covered)
  if covered == nil then covered = overlayOpen(world) end
  if excursion.battleBusy or excursion.trainerEngaging or covered then return end

  -- v0.3.64: the previous render-rate path resolved the current map, NPC list
  -- and role cache every frame before discovering that there were no moving
  -- actors and the 0.70s wander clock was not due. Peek the already-built role
  -- record first. Active movers can interpolate directly from that tiny list;
  -- otherwise an idle frame touches no map/entity tables at all.
  excursion.npcAiClock = (excursion.npcAiClock or 0) + dt
  local region, mapId = excursion.region, excursion.sourceMapId
  local peek = type(KantoState.Spatial.peekRoles) == "function"
    and KantoState.Spatial.peekRoles(region, mapId) or nil
  local moving = peek and peek.moving or nil
  if moving and #moving > 0 then
    for i = #moving, 1, -1 do
      local e = moving[i]
      if e and e.moving and e._moveT then
        e._moveT = math.min(1, e._moveT + dt / 0.18)
        local k = e._moveT * e._moveT * (3 - 2 * e._moveT)
        e.px = e._fromPx + (e._toPx - e._fromPx) * k
        e.py = e._fromPy + (e._toPy - e._fromPy) * k
        if e._moveT >= 1 then
          e.moving, e._moveT = false, nil
          e.px, e.py = e.cellX * 16, e.cellY * 16
          e.stepFlip = not e.stepFlip
          -- The authoritative list identity is already stored by the role
          -- record, so mover removal does not need entitiesForMap().
          KantoState.Spatial.setMoving(region, mapId, peek.list, e, false)
        end
      else
        KantoState.Spatial.setMoving(region, mapId, peek.list, e, false)
      end
    end
    Twin.kantoNpcMoverFastFrames = (Twin.kantoNpcMoverFastFrames or 0) + 1
  end

  if excursion.npcAiClock < 0.70 then
    Twin.kantoNpcIdleFastFrames = (Twin.kantoNpcIdleFastFrames or 0) + 1
    return
  end
  excursion.npcAiClock = excursion.npcAiClock - 0.70

  -- Only the infrequent wander decision needs the map/collision and complete
  -- authoritative NPC list. This also lazily builds roles on a newly-entered
  -- map, so no AI state is lost when the fast idle path started from a miss.
  local map = region and ensureForeignMap(region, mapId)
  if not map then return end
  local npcs = entitiesForMap(region, mapId)
  local roles = KantoState.Spatial.roles(region, mapId, npcs)
  local wanderers = roles.wanderers or {}
  if #wanderers == 0 then return end

  local idleCount = 0
  for i = 1, #wanderers do
    if not wanderers[i].moving then idleCount = idleCount + 1 end
  end
  if idleCount == 0 then return end
  excursion.npcAiCursor = (excursion.npcAiCursor or 0) + 1
  local wanted = ((excursion.npcAiCursor - 1) % idleCount) + 1
  local seen, e = 0, nil
  for i = 1, #wanderers do
    local cand = wanderers[i]
    if not cand.moving then
      seen = seen + 1
      if seen == wanted then e = cand; break end
    end
  end
  if not e then return end

  local startDir = ((tonumber(e._kantoWanderHash) or hashString(tostring(e.name)))
      + excursion.npcAiCursor) % 4
  e._kantoWanderHash = tonumber(e._kantoWanderHash) or hashString(tostring(e.name))
  local roam = math.max(1, tonumber(e.wanderRange) or 0)
  for offset = 0, 3 do
    local dir = NPC_WANDER_DIRS[((startDir + offset) % 4) + 1]
    local d = KantoGameplay.DIR_DELTA[dir]
    local nx, ny = e.cellX + d[1], e.cellY + d[2]
    if math.abs(nx - e.homeX) <= roam and math.abs(ny - e.homeY) <= roam
        and map:inBounds(nx, ny) and passable(map, nx, ny, false)
        and not occupiedByNpc(region, mapId, nx, ny, e)
        and not pokemonAt(region, mapId, nx, ny)
        and not map:warpAtCell(nx, ny)
        and not (nx == excursion.cellX and ny == excursion.cellY) then
      e.facing = dir
      e._fromPx, e._fromPy = e.px, e.py
      local oldX, oldY = e.cellX, e.cellY
      KantoState.Spatial.move(region, mapId, "npc", e, oldX, oldY, nx, ny)
      e.cellX, e.cellY = nx, ny
      e._toPx, e._toPy = nx * 16, ny * 16
      e._moveT, e.moving = 0, true
      KantoState.Spatial.setMoving(region, mapId, npcs, e, true)
      Twin.yellowNpcSteps = (Twin.yellowNpcSteps or 0) + 1
      break
    end
  end
end
Twin._tickKantoNpcAI = KantoGameplay.tickKantoNpcAI

function KantoGameplay.markFlyVisited(region, mapId)
  local field = region and region.loaded and region.loaded.field
  local fly = field and (field.flyWarps or field.fly_warps)
  if type(fly) ~= "table" or type(fly[mapId]) ~= "table" then return false end
  local state = KantoState.table(KantoState.FLY_VISITED_KEY)
  if state[mapId] then return true end
  state[mapId] = true
  return persistenceSet(KantoState.FLY_VISITED_KEY, state)
end

function Twin.kantoFlyPoints(game)
  if not excursion.active then return {}, "Kanto free roam is not active" end
  local region = excursion.region
  local field = region and region.loaded and region.loaded.field
  local fly = field and (field.flyWarps or field.fly_warps)
  if type(fly) ~= "table" then return {}, "Re-import Pokemon Yellow to add Fly landing data" end
  local _, mon, badge = KantoGameplay.goldFieldMoveUser(excursion.world, "FLY")
  if not mon or not badge then return {}, "A Pokemon with FLY and the THUNDER Badge is required" end
  local visited = KantoState.table(KantoState.FLY_VISITED_KEY)
  local order = field.flyWarpOrder or field.flyWarpsOrder or field.flyOrder or {}
  local seen, out = {}, {}
  local function isFlyTown(id)
    return id == "PALLET_TOWN" or id == "LAVENDER_TOWN" or id == "INDIGO_PLATEAU"
      or tostring(id):match("_CITY$") ~= nil or tostring(id):match("_ISLAND$") ~= nil
  end
  local function add(id)
    if seen[id] or not isFlyTown(id) or not visited[id] or type(fly[id]) ~= "table" then return end
    seen[id] = true
    local def = region.loaded.maps and region.loaded.maps[id]
    local name = def and (def.name or def.displayName) or tostring(id):gsub("_", " ")
    out[#out + 1] = { id = id, name = name }
  end
  for _, id in ipairs(type(order) == "table" and order or {}) do add(id) end
  local rest = {}
  for id in pairs(fly) do if not seen[id] then rest[#rest + 1] = id end end
  table.sort(rest)
  for _, id in ipairs(rest) do add(id) end
  Twin.yellowFlyPoints = #out
  return out
end

function Twin.kantoFlyTo(game, mapId)
  if not excursion.active then return false, "Kanto free roam is not active" end
  local points, err = Twin.kantoFlyPoints(game)
  local allowed = false
  for _, point in ipairs(points) do if point.id == mapId then allowed = true break end end
  if not allowed then return false, err or "That Kanto Fly point has not been visited" end
  local region = excursion.region
  local field = region.loaded and region.loaded.field
  local fly = field and (field.flyWarps or field.fly_warps)
  local landing = fly and fly[mapId]
  local map = landing and ensureForeignMap(region, mapId) or nil
  if not map then return false, "Kanto Fly destination is unavailable" end
  local x, y = tonumber(landing.x), tonumber(landing.y)
  if x == nil or y == nil then return false, "Kanto Fly landing coordinates are unavailable" end
  if not passable(map, x, y, false) then x, y = nearbyWalkable(map, x, y, false) end
  if x == nil then return false, "No safe Kanto Fly landing cell was found" end
  excursion.sourceMapId, excursion.cellX, excursion.cellY = mapId, x, y
  excursion.drawPx, excursion.drawPy = x * 16, y * 16
  excursion.toMapId, excursion.toCellX, excursion.toCellY = nil, nil, nil
  excursion.moving, excursion.surfing, excursion.strengthActive = false, false, false
  excursion.currentRecord = recordBySource(region, mapId)
  Twin._clearWarpIgnore()
  excursion.standingOnWarp = false
  excursion.forcedMoves, excursion.forcedMoveIndex, excursion.seafoamCurrentLock = nil, 0, false
  clearDirectionalBody(false)
  Twin.excursionSourceMap, Twin.excursionCellX, Twin.excursionCellY = mapId, x, y
  Twin.yellowFlyUses = (Twin.yellowFlyUses or 0) + 1
  persistExcursionPosition()
  return true
end

function KantoGameplay.hiddenTakenId(mapId, kind, x, y)
  return tostring(mapId) .. ":" .. tostring(kind) .. ":" .. tostring(x) .. "," .. tostring(y)
end


function KantoGameplay.cardKeyDoorRow(region, mapId, tx, ty)
  local bx, by = math.floor((tonumber(tx) or 0) / 2), math.floor((tonumber(ty) or 0) / 2)
  for _, door in ipairs(KantoState.closedDoorRows(region, mapId) or {}) do
    if tonumber(door.bx) == bx and tonumber(door.by) == by and door.event then
      return door
    end
  end
  return nil
end

function KantoGameplay.tryCardKeyDoor(world, region, mapId, map, tx, ty)
  if not (map and tostring(mapId):match("^SILPH_CO_%d+F$")) then return false end
  local door = KantoGameplay.cardKeyDoorRow(region, mapId, tx, ty)
  if not door or KantoState.doorOpen(door) then return false end
  local field = region and region.loaded and region.loaded.field
  local card = field and field.cardKeyDoors or {}
  local tile = map:cellTile(tx, ty)
  local locked = false
  for _, t in ipairs(type(card.doorTiles) == "table" and card.doorTiles or { 0x18, 0x24 }) do
    if tonumber(t) == tonumber(tile) then locked = true break end
  end
  if mapId == "SILPH_CO_11F" and tonumber(tile) == tonumber(card.silphCo11F
      and card.silphCo11F.doorTile or 0x5e) then locked = true end
  -- A stale projected tileset can lose the literal locked tile id.  The exact
  -- closed block row is still enough to identify the authored door safely.
  if not locked and tonumber(map:blockAt(door.bx, door.by)) ~= tonumber(door.block) then
    return false
  end
  if not KantoGameplay.ensureKantoLocalItem(world, region, "CARD_KEY") then
    return showMessage(world, "A CARD KEY is required.")
  end
  KantoState.setEvent(door.event, true)
  KantoState.refreshBlock(map, door.bx, door.by, door.open)
  Twin.yellowCardKeyDoors = (Twin.yellowCardKeyDoors or 0) + 1
  return showMessage(world, "CARD KEY opened the door!")
end
Twin._tryCardKeyDoor = KantoGameplay.tryCardKeyDoor

function KantoGameplay.trashText(region, label, fallback)
  local body = textByLabel(region, label)
  return body and tostring(body) or tostring(fallback or "")
end

function KantoGameplay.openTrashDoor(region, map)
  local puzzle = KantoState.trashPuzzle(region)
  local door = puzzle.doorBlock or KantoState.TRASH_FALLBACK.doorBlock
  if KantoState.refreshBlock(map, door.bx, door.by, door.block) then
    Twin.yellowTrashDoorOpens = (Twin.yellowTrashDoorOpens or 0) + 1
  end
  return true
end

function KantoGameplay.tryTrashCan(world, region, mapId, map, tx, ty)
  local puzzle = KantoState.trashPuzzle(region)
  if tostring(mapId) ~= tostring(puzzle.map or "VERMILION_GYM") then return false end
  local can
  for _, row in ipairs(puzzle.cans or {}) do
    if tonumber(row.x) == tonumber(tx) and tonumber(row.y) == tonumber(ty) then
      can = tonumber(row.can)
      break
    end
  end
  if can == nil then return false end

  local firstEvent = puzzle.firstLockEvent or "EVENT_1ST_LOCK_OPENED"
  local secondEvent = puzzle.secondLockEvent or "EVENT_2ND_LOCK_OPENED"
  if KantoState.event(secondEvent) then
    return showMessage(world, KantoGameplay.trashText(region,
      "_VermilionGymTrashText", "Nope, there's only trash here."))
  end

  local state = KantoState.trashState()
  if tonumber(state.first) == nil then state.first = KantoState.rollTrashFirst(region, false) end
  if not KantoState.event(firstEvent) then
    if can ~= tonumber(state.first) then
      return showMessage(world, KantoGameplay.trashText(region,
        "_VermilionGymTrashText", "Nope, there's only trash here."))
    end
    KantoState.setEvent(firstEvent, true)
    state = KantoState.trashState()
    state.second = KantoState.pickTrashSecond(region, can)
    KantoState.saveTrash(state)
    Twin.yellowTrashSwitches = (Twin.yellowTrashSwitches or 0) + 1
    return showMessage(world, KantoGameplay.trashText(region,
      "_VermilionGymTrashSuccessText1", "Hey! There's a switch under the trash!\fTurn it on!"))
  end

  if can == tonumber(state.second) then
    KantoState.setEvent(secondEvent, true)
    KantoGameplay.openTrashDoor(region, map)
    Twin.yellowTrashSwitches = (Twin.yellowTrashSwitches or 0) + 1
    return showMessage(world, KantoGameplay.trashText(region,
      "_VermilionGymTrashSuccessText3", "The motorized door opened!"))
  end

  KantoState.setEvent(firstEvent, false)
  state = KantoState.trashState()
  state.second = nil
  KantoState.saveTrash(state)
  KantoState.rollTrashFirst(region, false)
  Twin.yellowTrashResets = (Twin.yellowTrashResets or 0) + 1
  return showMessage(world, KantoGameplay.trashText(region,
    "_VermilionGymTrashFailText", "Nope! There's only trash here.\fThe electric locks were reset!"))
end
Twin._tryTrashCan = KantoGameplay.tryTrashCan

function KantoGameplay.tryMansionSwitch(world, region, mapId, map, tx, ty)
  local P = KantoState.DungeonPuzzles
  if not P.mansionSwitchAt(mapId, tx, ty, excursion.facing) then return false end
  return askYesNo(world, "A secret switch!\fPress it?", function(yes)
    if not yes then
      showMessage(world, "Not quite yet!")
      return
    end
    local nextState = not KantoState.event(P.MANSION_EVENT)
    KantoState.setEvent(P.MANSION_EVENT, nextState)
    KantoState.restampDungeonPuzzleMap(region, mapId, map)
    KantoGameplay.playSound(world, "Go_Inside")
    Twin.yellowMansionSwitches = (Twin.yellowMansionSwitches or 0) + 1
    showMessage(world, "Who wouldn't?")
  end)
end
Twin._tryMansionSwitch = KantoGameplay.tryMansionSwitch

function KantoGameplay.tryHiddenInteraction(world, region, mapId, map, tx, ty)
  local field = region and region.loaded and region.loaded.field
  -- Dynamic-interior fallbacks are intentionally usable with a stale cache
  -- whose field table is absent/incomplete; ordinary hidden tables simply
  -- read as empty in that case.
  if type(field) ~= "table" then field = {} end
  if KantoGameplay.tryMansionSwitch(world, region, mapId, map, tx, ty) then return true end
  if KantoGameplay.billPcInteraction(world, region, mapId, tx, ty) then return true end
  local hidden = field.hiddenItems and field.hiddenItems[mapId]
  for _, h in ipairs(type(hidden) == "table" and hidden or {}) do
    if tonumber(h.x) == tx and tonumber(h.y) == ty then
      local key = KantoGameplay.hiddenTakenId(mapId, "item", tx, ty)
      local taken = KantoState.table(KantoState.HIDDEN_TAKEN_KEY)
      if taken[key] then return false end
      local g = world and world.game
      local okBag, Bag = pcall(require, "src.inventory.Bag")
      if not (g and g.save and g.data and okBag and Bag and type(Bag.add) == "function") then return false end
      local item = tostring(h.item or "")
      if not (g.data.items and g.data.items[item]) then
        return showMessage(world, "This Yellow item has no Gen-2 inventory equivalent.")
      end
      if not Bag.add(g.save, item, 1, g.data) then return showMessage(world, "Your PACK can't hold this item.") end
      taken[key] = true
      persistenceSet(KantoState.HIDDEN_TAKEN_KEY, taken)
      Twin.yellowHiddenItems = (Twin.yellowHiddenItems or 0) + 1
      local idef = g.data.items[item]
      return showMessage(world, "Found " .. tostring((idef and idef.name) or item) .. "!")
    end
  end
  local coins = field.hiddenCoins and field.hiddenCoins[mapId]
  for _, h in ipairs(type(coins) == "table" and coins or {}) do
    if tonumber(h.x) == tx and tonumber(h.y) == ty then
      local key = KantoGameplay.hiddenTakenId(mapId, "coins", tx, ty)
      local taken = KantoState.table(KantoState.HIDDEN_TAKEN_KEY)
      if taken[key] then return false end
      local g = world and world.game
      if not (g and g.save) then return false end
      g.save.inventory = g.save.inventory or {}
      if not g.save.inventory.COIN_CASE then return showMessage(world, "A COIN CASE is required!") end
      local amount = math.max(0, tonumber(h.coins) or 0)
      g.save.coins = math.min(9999, (tonumber(g.save.coins) or 0) + amount)
      taken[key] = true
      persistenceSet(KantoState.HIDDEN_TAKEN_KEY, taken)
      Twin.yellowHiddenCoins = (Twin.yellowHiddenCoins or 0) + 1
      return showMessage(world, "Found " .. tostring(amount) .. " coins!")
    end
  end
  local machines = field.slotMachines and field.slotMachines[mapId]
  for seatIndex, h in ipairs(type(machines) == "table" and machines or {}) do
    if tonumber(h.x) == tx and tonumber(h.y) == ty then
      local state = tostring(h.state or "ok")
      if state == "out_of_order" then return showMessage(world, "OUT OF ORDER\nThis is broken.") end
      if state == "out_to_lunch" then return showMessage(world, "OUT TO LUNCH\nThis is reserved.") end
      if state == "keys" then return showMessage(world, "Someone's keys!\nThey'll be back.") end
      Twin.yellowSlotMachines = (Twin.yellowSlotMachines or 0) + 1
      return KantoGameplay.openSlotMachine(world, region, seatIndex)
    end
  end
  local extras = field.hiddenExtras
  if type(extras) ~= "table" then extras = {} end
  if KantoGameplay.tryTrashCan(world, region, mapId, map, tx, ty) then return true end
  for _, h in ipairs(extras.pcTiles and extras.pcTiles[mapId] or {}) do
    if tonumber(h.x) == tx and tonumber(h.y) == ty
        and (not h.facing or tostring(h.facing) == tostring(excursion.facing)) then
      Twin.yellowHiddenPcUses = (Twin.yellowHiddenPcUses or 0) + 1
      return openYellowPc(world)
    end
  end
  for _, h in ipairs(extras.printTrash and extras.printTrash[mapId] or {}) do
    if tonumber(h.x) == tx and tonumber(h.y) == ty then
      return showMessage(world, "Nope, there's only trash here.")
    end
  end
  local leaders = { PEWTER_GYM="BROCK", CERULEAN_GYM="MISTY", VERMILION_GYM="LT. SURGE",
    CELADON_GYM="ERIKA", FUCHSIA_GYM="KOGA", SAFFRON_GYM="SABRINA",
    CINNABAR_GYM="BLAINE", VIRIDIAN_GYM="GIOVANNI" }
  for _, h in ipairs(extras.gymStatues and extras.gymStatues[mapId] or {}) do
    if tonumber(h.x) == tx and tonumber(h.y) == ty then
      local leader = leaders[mapId] or "?"
      local badgeByGym = { PEWTER_GYM="BOULDER", CERULEAN_GYM="CASCADE", VERMILION_GYM="THUNDER",
        CELADON_GYM="RAINBOW", FUCHSIA_GYM="SOUL", SAFFRON_GYM="MARSH",
        CINNABAR_GYM="VOLCANO", VIRIDIAN_GYM="EARTH" }
      local g = world and world.game
      local owned = g and g.save and g.save.player and g.save.player.kantoBadges or {}
      local winner = owned and owned[badgeByGym[mapId]] and (g.save.player.name or "PLAYER") or "---"
      Twin.yellowGymStatues = (Twin.yellowGymStatues or 0) + 1
      return showMessage(world, "POKéMON GYM\nLEADER: " .. leader .. "\fWINNING TRAINERS:\n" .. winner)
    end
  end
  return false
end
Twin._tryHiddenInteraction = KantoGameplay.tryHiddenInteraction

local function interactExcursion(world)
  local region, mapId = excursion.region, excursion.sourceMapId
  local map = region and mapId and ensureForeignMap(region, mapId)
  if not map then return false end
  local tx, ty = facingCell(excursion.cellX, excursion.cellY, excursion.facing)
  local mon = pokemonAt(region, mapId, tx, ty)
  if mon and mon.species then
    excursion.lastInteraction = tostring(mon.name or mon.species)
    if mon.staticYellowPokemon and mon.sourceObject then
      return Twin._startStaticPokemonInteraction(world, region, mapId,
        mon.sourceObject, mon)
    end
    return startYellowWildBattle(world, region, mapId, mon.species,
      tonumber(mon.level) or tonumber(mon.wildLevel) or 2, mon)
  end

  local obj, entity = objectAt(region, mapId, map, tx, ty)
  if obj and itemAlreadyPicked(mapId, obj) then obj, entity = nil, nil end
  if obj then
    excursion.lastInteraction = tostring(obj.name or obj.index or "object")
    if entity and not entity.isBoulder then
      entity.facing = KantoGameplay.OPPOSITE_DIR[excursion.facing] or entity.facing
    end

    if entity and entity.isBoulder then
      return KantoGameplay.tryYellowStrength(world, entity)
    end

    if Twin._isYellowCenterNurseForTest(mapId, obj, map) then
      return useYellowNurse(world)
    end

    if KantoGameplay.trySpecialObjectInteraction(world, region, mapId, obj) then return true end

    -- Static map Pokemon can also arrive through objectAt when their visual
    -- representation is deliberately an NPC sprite (Power Plant trap balls) or
    -- when an older asset cache could not build the Pokemon overworld model.
    if obj.pokemon then
      return Twin._startStaticPokemonInteraction(world, region, mapId, obj, entity)
    end

    if obj.item then
      return pickupYellowItem(world, region, mapId, obj)
    end

    if obj.trainerClass then
      return KantoGameplay.engageYellowTrainer(world, region, mapId, obj,
        trainerHeader(region, mapId, obj), entity, false)
    end

    local body, info = interactionText(region, mapId, obj.text)
    if info then
      if info.mart then return openYellowMart(world, info) end
      if info.nurse then return useYellowNurse(world) end
      if info.pc then return openYellowPc(world) end
      if info.cableClub then
        return showMessage(world, "The Cable Club isn't used by Kanto free roam.")
      end
      if info.asm then
        -- v0.3.53: hand-ported text_asm dialogue runs through a detached
        -- presentation sandbox.  Dedicated Kanto handlers above still own
        -- real gameplay actions; the fallback may speak/ask/show a list but
        -- cannot mutate Gold, warp, battle, or run cutscene movement.
        local Dialogue = KantoGameplay.Dialogue
        if Dialogue and type(Dialogue.try) == "function" then
          local ok, handled = pcall(Dialogue.try, {
            world = world, region = region, mapId = mapId, map = map,
            textConst = obj.text, obj = obj, entity = entity, info = info,
            excursion = excursion,
            kantoEvents = KantoState.table(KantoState.EVENTS_KEY),
            adapters = {
              show = showMessage, ask = askYesNo, list = KantoGameplay.listMenu,
              trainerDefeated = trainerDefeated,
            },
          })
          if ok and handled then
            Twin.yellowDialogueAsmHandled = (Twin.yellowDialogueAsmHandled or 0) + 1
            return true
          end
        end
        if body then return showMessage(world, body) end
        Twin.yellowDialogueFallbacks = (Twin.yellowDialogueFallbacks or 0) + 1
        return showMessage(world, "...")
      end
    end
    if body then return showMessage(world, body) end
    -- Old/incomplete Yellow caches can be missing a text_pointers row even
    -- though the engine has a hand-ported TEXT_* handler.  Give every visible
    -- NPC one last dialogue-only resolution pass; KantoDialogue guarantees a
    -- harmless ellipsis rather than silently swallowing A if no authored line
    -- can be recovered.
    if obj.text and KantoGameplay.Dialogue and type(KantoGameplay.Dialogue.try) == "function" then
      local ok, handled = pcall(KantoGameplay.Dialogue.try, {
        world = world, region = region, mapId = mapId, map = map,
        textConst = obj.text, obj = obj, entity = entity, info = info,
        excursion = excursion,
        kantoEvents = KantoState.table(KantoState.EVENTS_KEY),
        adapters = {
          show = showMessage, ask = askYesNo, list = KantoGameplay.listMenu,
          trainerDefeated = trainerDefeated,
        },
      })
      if ok and handled then
        Twin.yellowDialogueRecovered = (Twin.yellowDialogueRecovered or 0) + 1
        return true
      end
    end
  end

  -- Yellow's data-driven hidden-event table: hidden items, PC tiles, trash
  -- cans and Gym statues are safe gameplay interactions and do not execute
  -- story/cutscene ASM.
  if KantoGameplay.tryHiddenInteraction(world, region, mapId, map, tx, ty) then return true end

  -- Silph's CARD KEY doors are physical block swaps, not story VM.  Gold's
  -- inventory owns the key item; the Yellow event name only persists geometry.
  if KantoGameplay.tryCardKeyDoor(world, region, mapId, map, tx, ty) then return true end

  -- Yellow-authored Cut terrain rules + Gold party/badge authority.
  if KantoGameplay.tryYellowCut(world, region, mapId, map, tx, ty) then return true end

  -- Signs are background events, not object events. They use the same TEXT_*
  -- pointer table as NPCs and are safe to expose when the pointer is plain text.
  local sign = signAt(map, tx, ty)
  if sign then
    if KantoGameplay.trySpecialSignInteraction(world, region, mapId, sign) then return true end
    local body, info = interactionText(region, mapId, sign.text)
    if info and info.asm then
      local Dialogue = KantoGameplay.Dialogue
      if Dialogue and type(Dialogue.try) == "function" then
        local ok, handled = pcall(Dialogue.try, {
          world = world, region = region, mapId = mapId, map = map,
          textConst = sign.text, obj = sign, info = info, excursion = excursion,
          kantoEvents = KantoState.table(KantoState.EVENTS_KEY),
          adapters = {
            show = showMessage, ask = askYesNo, list = KantoGameplay.listMenu,
            trainerDefeated = trainerDefeated,
          },
        })
        if ok and handled then
          Twin.yellowDialogueAsmHandled = (Twin.yellowDialogueAsmHandled or 0) + 1
          Twin.yellowSignsRead = (Twin.yellowSignsRead or 0) + 1
          return true
        end
      end
      if body then return showMessage(world, body) end
      Twin.yellowDialogueFallbacks = (Twin.yellowDialogueFallbacks or 0) + 1
      return showMessage(world, "...")
    end
    if body then
      Twin.yellowSignsRead = (Twin.yellowSignsRead or 0) + 1
      excursion.lastInteraction = "SIGN:" .. tostring(sign.text or "")
      return showMessage(world, body)
    end
    if sign.text and KantoGameplay.Dialogue and type(KantoGameplay.Dialogue.try) == "function" then
      local ok, handled = pcall(KantoGameplay.Dialogue.try, {
        world = world, region = region, mapId = mapId, map = map,
        textConst = sign.text, obj = sign, info = info, excursion = excursion,
        kantoEvents = KantoState.table(KantoState.EVENTS_KEY),
        adapters = { show = showMessage, ask = askYesNo, list = KantoGameplay.listMenu,
          trainerDefeated = trainerDefeated },
      })
      if ok and handled then
        Twin.yellowDialogueRecovered = (Twin.yellowDialogueRecovered or 0) + 1
        Twin.yellowSignsRead = (Twin.yellowSignsRead or 0) + 1
        return true
      end
    end
  end
  if tryYellowSurf(world, map, tx, ty) then return true end
  return false
end

Twin._yellowTrainer = yellowTrainer
Twin._trainerDefeated = trainerDefeated

function KantoGameplay.badgeGateForStep(region, mapId, tx, ty, dir)
  mapId = tostring(mapId or "")
  local indexed = region and region.fieldIndex and region.fieldIndex.badgeGates
  local idx = indexed and indexed[mapId]
  if type(idx) == "table" then
    if dir == "up" then
      local row = idx.upRows and idx.upRows[math.floor(tonumber(ty) or -9999)]
      if row and (not row.maxX or tonumber(tx) <= tonumber(row.maxX)) then
        Twin.yellowBadgeGateIndexHits = (Twin.yellowBadgeGateIndexHits or 0) + 1
        return row
      end
    end
    local exact = idx.coords and idx.coords[math.floor(tonumber(ty) or -9999) * 1024
      + math.floor(tonumber(tx) or -9999)]
    if exact then
      Twin.yellowBadgeGateIndexHits = (Twin.yellowBadgeGateIndexHits or 0) + 1
      return exact
    end
    return nil
  end
  local gates = region and region.loaded and region.loaded.field and region.loaded.field.badgeGates
  local def = gates and gates[mapId]
  if type(def) ~= "table" then return nil end
  if mapId == "ROUTE_23" and dir == "up" then
    for _, g in ipairs(def.guards or {}) do
      if tonumber(g.y) == tonumber(ty) and (not g.maxX or tonumber(tx) <= tonumber(g.maxX)) then
        return { badge = g.badge, failText = def.failText }
      end
    end
  elseif mapId == "ROUTE_22_GATE" then
    for _, c in ipairs(def.coords or {}) do
      if tonumber(c.x) == tonumber(tx) and tonumber(c.y) == tonumber(ty) then
        return { badge = def.badge, failText = def.failText }
      end
    end
  end
  return nil
end

-- Current Gen1Recomp extracts CheckForceBikeOrSurf into field.forcedMovement.
-- Keep the story-free excursion on that same physical data instead of hard-
-- coding Route 16/17/18 coordinates. Only the forced Cycling Road bike state
-- is mirrored here; Seafoam's forced-surf/current system already has its own
-- richer implementation below.
Twin._badgeGateForStep = KantoGameplay.badgeGateForStep

function KantoGameplay.forcedMovement(region)
  local field = region and region.loaded and region.loaded.field
  local fm = field and field.forcedMovement
  return type(fm) == "table" and fm or nil
end

function KantoGameplay.isSlopeMap(region, mapId)
  mapId = tostring(mapId or "")
  if region and region.fieldIndex and region.fieldIndex.slopeMaps then
    return region.fieldIndex.slopeMaps[mapId] == true
  end
  local fm = KantoGameplay.forcedMovement(region)
  for _, id in ipairs(fm and fm.slopeMaps or {}) do
    if tostring(id) == mapId then return true end
  end
  return false
end

function KantoGameplay.forcedBikeTile(region, mapId, x, y)
  mapId = tostring(mapId or "")
  if region and region.fieldIndex and region.fieldIndex.forcedBikeTiles then
    local rows = region.fieldIndex.forcedBikeTiles[mapId]
    local key = math.floor(tonumber(y) or -9999) * 1024 + math.floor(tonumber(x) or -9999)
    return type(rows) == "table" and rows[key] or nil
  end
  local fm = KantoGameplay.forcedMovement(region)
  local rows = fm and fm.tiles and fm.tiles[mapId]
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    if row.mode == "bike" and tonumber(row.x) == tonumber(x)
        and tonumber(row.y) == tonumber(y) then return row end
  end
  return nil
end

function KantoGameplay.clearForcedBikeMap(region, mapId)
  mapId = tostring(mapId or "")
  if region and region.fieldIndex and region.fieldIndex.clearForcedBikeMaps then
    return region.fieldIndex.clearForcedBikeMaps[mapId] == true
  end
  local fm = KantoGameplay.forcedMovement(region)
  for _, id in ipairs(fm and fm.clearMaps or {}) do
    if tostring(id) == mapId then return true end
  end
  return false
end

-- Called once per landed Kanto cell from tickExcursion. Returns true only when
-- the no-bicycle refusal took over the frame with a message/bounce.
function KantoGameplay.syncForcedBike(world, region, mapId, x, y)
  if KantoGameplay.clearForcedBikeMap(region, mapId) then
    -- Route 16/18 gate scripts clear only BIT_ALWAYS_ON_BIKE. The rider stays
    -- mounted until the player actually uses the BICYCLE to dismount.
    excursion.forcedBike = false
  end
  if not KantoGameplay.forcedBikeTile(region, mapId, x, y) then return false end
  if excursion.biking then
    excursion.forcedBike = true
    return false
  end
  local save = world and world.game and world.game.save
  local inv = save and save.inventory
  if type(inv) == "table" and (tonumber(inv.BICYCLE) or 0) > 0 then
    excursion.biking, excursion.forcedBike, excursion.surfing = true, true, false
    Twin.yellowForcedBikeMounts = (Twin.yellowForcedBikeMounts or 0) + 1
    persistExcursionPosition()
    return false
  end
  excursion.biking, excursion.forcedBike = false, false
  local back = KantoGameplay.OPPOSITE_DIR[excursion.facing] or "left"
  excursion.forcedMoves, excursion.forcedMoveIndex = { back }, 1
  excursion.seafoamCurrentLock = false
  Twin.yellowCyclingRoadBounces = (Twin.yellowCyclingRoadBounces or 0) + 1
  return showMessage(world, "You need a\nBICYCLE for the\nCycling Road!")
end

function KantoGameplay.bikeAllowed(region, mapId)
  return KantoState.bikeAllowed(region, mapId)
end

function KantoGameplay.toggleBicycle(world)
  if not (excursion.active and excursion.region and excursion.sourceMapId) then
    return false, "Kanto free roam is not active"
  end
  local save = world and world.game and world.game.save
  local inventory = save and save.inventory
  if not (type(inventory) == "table" and (tonumber(inventory.BICYCLE) or 0) > 0) then
    return false, "You don't have a BICYCLE."
  end
  if excursion.forcedBike then return false, "You can't get off here." end
  if excursion.biking then
    excursion.biking = false
    excursion.cyclingBrakeHeld, excursion.cyclingRollActive = false, false
    Twin.yellowBikeDismounts = (Twin.yellowBikeDismounts or 0) + 1
    persistExcursionPosition()
    return true
  end
  if excursion.surfing then return false, "No cycling allowed here." end
  if not KantoState.bikeAllowed(excursion.region, excursion.sourceMapId) then
    return false, "No cycling allowed here."
  end
  excursion.biking = true
  excursion.surfing = false
  excursion.cyclingBrakeHeld, excursion.cyclingRollActive = false, false
  Twin.yellowBikeMounts = (Twin.yellowBikeMounts or 0) + 1
  persistExcursionPosition()
  return true
end

function KantoGameplay.bikeStepDuration(region, mapId, dir)
  if not excursion.biking then return nil end
  -- DoBikeSpeedup suppresses the 2x boost on Route 17 while steering
  -- UP/LEFT/RIGHT; DOWN (including the automatic hill roll) stays fast.
  if KantoGameplay.isSlopeMap(region, mapId) and dir ~= "down" then
    return excursion.moveDuration
  end
  return excursion.moveDuration * 0.5
end

function KantoGameplay.cyclingRoadIntent(region, mapId, input, dir, worldX, worldZ)
  worldX, worldZ = tonumber(worldX) or 0, tonumber(worldZ) or 0
  if not excursion.biking or not KantoGameplay.isSlopeMap(region, mapId) or dir then
    excursion.cyclingBrakeHeld, excursion.cyclingRollActive = false, false
    return dir, worldX, worldZ, false
  end
  if inputDown(input, "a") or inputDown(input, "b") then
    if not excursion.cyclingBrakeHeld then
      Twin.yellowCyclingRoadBrakes = (Twin.yellowCyclingRoadBrakes or 0) + 1
    end
    excursion.cyclingBrakeHeld, excursion.cyclingRollActive = true, false
    return nil, 0, 0, true
  end
  if not excursion.cyclingRollActive then
    Twin.yellowCyclingRoadRolls = (Twin.yellowCyclingRoadRolls or 0) + 1
  end
  excursion.cyclingBrakeHeld, excursion.cyclingRollActive = false, true
  return "down", 0, 1, false
end

local function moveCandidate(region, mapId, cx, cy, dir, world)
  local map = ensureForeignMap(region, mapId)
  if not map then return nil end
  local dx, dy = 0, 0
  if dir == "left" then dx = -1 elseif dir == "right" then dx = 1
  elseif dir == "up" then dy = -1 elseif dir == "down" then dy = 1 end
  local tx, ty = cx + dx, cy + dy
  if map:inBounds(tx, ty) then
    local gate = KantoGameplay.badgeGateForStep(region, mapId, tx, ty, dir)
    if gate and not KantoGameplay.ownsKantoBadge(world, gate.badge) then
      Twin.yellowBadgeGateBlocks = (Twin.yellowBadgeGateBlocks or 0) + 1
      local line = textByLabel(region, gate.failText)
        or ("You need the " .. tostring(gate.badge or "BADGE") .. " to pass.")
      showMessage(world, line)
      return nil
    end
    local itemGate = KantoGameplay.itemGateForStep(region, mapId, tx, ty, dir)
    if itemGate and not KantoGameplay.ensureKantoLocalItem(world, region, itemGate.item) then
      KantoGameplay.showItemGateBlock(world, region, mapId, itemGate)
      return nil
    end
    if not passable(map, tx, ty, excursion.surfing) then return nil end
    if KantoState.pairBlocked(region, map, cx, cy, tx, ty, excursion.surfing) then
      Twin.yellowPairCollisionBlocks = (Twin.yellowPairCollisionBlocks or 0) + 1
      return nil
    end
    local blocker = npcAt(region, mapId, tx, ty)
    if blocker then
      if not (blocker.isBoulder
          and KantoGameplay.tryPushBoulder(world, region, mapId, blocker, dir)) then
        return nil
      end
    end
    return mapId, tx, ty
  end

  -- Outdoor edge crossing uses Gen1Recomp's connection landing equations.
  -- Repaired cache connections live in region.loaded.maps, so both directions
  -- of a vanilla seam remain traversable even when an old imported cache was
  -- missing the reciprocal entry.
  local connDir = DIR_CONN[dir]
  local sourceDef = region.loaded.maps[mapId]
  local conn = sourceDef and sourceDef.connections and sourceDef.connections[connDir]
  local destId = conn and (conn.map or conn.mapId)
  if not destId or not region.validOutdoor[destId] then return nil end
  local destMap = ensureForeignMap(region, destId)
  if not destMap then return nil end
  local lx, ly = ForeignGen1Map.connectionLanding(destMap.def, conn, dir, cx, cy)
  if lx == nil then
    Twin.kantoConnectionEdgeRejects = (Twin.kantoConnectionEdgeRejects or 0) + 1
    return nil
  end
  if not passable(destMap, lx, ly, excursion.surfing)
      or occupiedByNpc(region, destId, lx, ly) then
    return nil
  end
  Twin.kantoConnections = (Twin.kantoConnections or 0) + 1
  return destId, lx, ly
end

local function warpKey(mapId, cx, cy)
  -- Legacy/debug helper only. Normal warp-bounce suppression uses the scalar
  -- fields below so an ordinary landing never allocates "map:x:y" strings.
  return tostring(mapId) .. ":" .. tostring(cx) .. ":" .. tostring(cy)
end

function Twin._clearWarpIgnore()
  excursion.ignoreWarpMap, excursion.ignoreWarpX, excursion.ignoreWarpY = nil, nil, nil
  excursion.ignoreWarpKey = nil
end

function Twin._setWarpIgnore(mapId, cx, cy)
  excursion.ignoreWarpMap = mapId
  excursion.ignoreWarpX = tonumber(cx)
  excursion.ignoreWarpY = tonumber(cy)
  -- Boolean sentinel preserves the old field's "armed/not armed" shape without
  -- constructing a string.  Older tests/external code that writes nil to the
  -- legacy field therefore still clears a stale scalar arm on the next probe.
  excursion.ignoreWarpKey = false
end

function Twin._warpIgnoreMatches(mapId, cx, cy)
  if excursion.ignoreWarpMap ~= nil then
    if excursion.ignoreWarpKey == nil then
      -- Compatibility: legacy callers historically cleared only ignoreWarpKey.
      excursion.ignoreWarpMap, excursion.ignoreWarpX, excursion.ignoreWarpY = nil, nil, nil
      return false
    end
    return excursion.ignoreWarpMap == mapId
      and excursion.ignoreWarpX == tonumber(cx)
      and excursion.ignoreWarpY == tonumber(cy)
  end
  local legacy = excursion.ignoreWarpKey
  return type(legacy) == "string" and legacy == warpKey(mapId, cx, cy)
end


local function targetCell(cx, cy, dir)
  if dir == "up" then return cx, cy - 1 end
  if dir == "down" then return cx, cy + 1 end
  if dir == "left" then return cx - 1, cy end
  return cx + 1, cy
end

local function ledgeRuleAt(region, map, cx, cy, dir)
  if not (region and map and dir) then return nil end
  local fx, fy = targetCell(cx, cy, dir)
  -- HandleLedges reads a physical ledge tile in front of the player.  The
  -- landing may cross a map seam, but the ledge tile itself belongs to the
  -- current map (Route 4 / Route 17 are the important vanilla examples).
  if not map:inBounds(fx, fy) then return nil end
  local standing = map:cellTile(cx, cy)
  local front = map:cellTile(fx, fy)
  local tileset = map.def and map.def.tileset

  local indexed = region.fieldIndex and region.fieldIndex.ledges
  local perTileset = indexed and indexed[tostring(tileset or "")]
  local perDir = perTileset and perTileset[dir]
  if perDir and standing ~= nil and front ~= nil then
    local row = perDir[(tonumber(standing) or 0) * 256 + (tonumber(front) or 0)]
    if row and row.input == dir then
      Twin.yellowLedgeIndexHits = (Twin.yellowLedgeIndexHits or 0) + 1
      return row
    end
    return nil
  end

  local field = region.loaded and region.loaded.field
  local ledges = field and field.ledges
  if type(ledges) ~= "table" then return nil end
  for _, row in ipairs(ledges) do
    if (row.tileset or "OVERWORLD") == tileset
        and row.facing == dir and row.input == dir
        and tonumber(row.standingTile) == tonumber(standing)
        and tonumber(row.ledgeTile) == tonumber(front) then
      return row
    end
  end
  return nil
end

local function ledgeLanding(region, mapId, cx, cy, dir)
  local map = ensureForeignMap(region, mapId)
  if not map or not ledgeRuleAt(region, map, cx, cy, dir) then return nil end
  local d = KantoGameplay.DIR_DELTA[dir]
  if not d then return nil end
  local lx, ly = cx + d[1] * 2, cy + d[2] * 2
  if map:inBounds(lx, ly) then
    if not passable(map, lx, ly, false) or occupiedByNpc(region, mapId, lx, ly) then
      return nil
    end
    return mapId, lx, ly, false
  end

  local sourceDef = region.loaded and region.loaded.maps and region.loaded.maps[mapId]
  local conn = sourceDef and sourceDef.connections and sourceDef.connections[DIR_CONN[dir]]
  local destId = conn and (conn.map or conn.mapId)
  if not destId or not region.validOutdoor[destId] then return nil end
  local destMap = ensureForeignMap(region, destId)
  if not destMap then return nil end
  local tx, ty = ForeignGen1Map.connectionLanding(destMap.def, conn, dir, cx, cy)
  if tx == nil or not passable(destMap, tx, ty, false)
      or occupiedByNpc(region, destId, tx, ty) then
    return nil
  end
  return destId, tx, ty, true
end

local function startLedgeHop(world, dir)
  if excursion.moving or excursion.surfing or not dir then return false end
  local mapId, tx, ty, seam = ledgeLanding(excursion.region,
    excursion.sourceMapId, excursion.cellX, excursion.cellY, dir)
  if not mapId then return false end

  -- A free-roam body may have reached the ledge at a fractional position.
  -- Re-anchor to the authored standing cell before the two-cell hop, exactly
  -- like the grid path, then let the voxel player pose supply vertical lift.
  clearDirectionalBody(true)
  excursion.facing = dir
  excursion.fromPx, excursion.fromPy = excursion.cellX * 16, excursion.cellY * 16
  excursion.drawPx, excursion.drawPy = excursion.fromPx, excursion.fromPy
  local d = KantoGameplay.DIR_DELTA[dir]
  if seam then
    -- Keep interpolation continuous in the old map's local coordinates; the
    -- destination coordinates become authoritative only when the hop lands.
    excursion.toPx = excursion.fromPx + d[1] * 32
    excursion.toPy = excursion.fromPy + d[2] * 32
  else
    excursion.toPx, excursion.toPy = tx * 16, ty * 16
  end
  excursion.toMapId, excursion.toCellX, excursion.toCellY = mapId, tx, ty
  excursion.moveT = 0
  -- Gen1Recomp's ledge arc is 32 fixed 60 Hz frames (two simulated steps).
  -- Keep that timing even though Kanto's ordinary grid step is deliberately
  -- faster, so the hop reads as the same physical traversal in every camera.
  excursion.moveDurationCurrent = 32 / 60
  excursion.hopActive, excursion.hopProgress, excursion.hopLift = true, 0, 0
  excursion.hopSeam = seam == true
  excursion.moving = true
  Twin.yellowLedgeHops = (Twin.yellowLedgeHops or 0) + 1
  if seam then Twin.yellowLedgeSeamHops = (Twin.yellowLedgeSeamHops or 0) + 1 end
  return true
end

Twin._ledgeRuleAt = ledgeRuleAt
Twin._ledgeLanding = ledgeLanding
Twin._tryStartLedgeHop = startLedgeHop

local function collisionWarpAllowed(map, cx, cy, dir)
  if not (map and dir) then return false end
  local tx, ty = targetCell(cx, cy, dir)
  if not map:inBounds(tx, ty) then return true end

  -- Newer Yellow caches may include current Gen1Recomp field.warpCarpets.
  -- Honor the common data-driven carpet rule when present.  Otherwise a warp
  -- tile directly in front is a conservative fallback for old caches.
  local region = excursion.region
  local indexed = region and region.fieldIndex and region.fieldIndex.warpCarpets
  if indexed then
    local mapId = tostring(map.sourceId or map.id or "")
    local useCarpet
    if indexed.edgeMaps[mapId] then
      useCarpet = false
    elseif indexed.function2Maps[mapId] then
      useCarpet = true
    else
      useCarpet = indexed.function2Tilesets[tostring(map.def and map.def.tileset or "")] == true
    end
    if not useCarpet then return not map:inBounds(tx, ty) end
    local front = map:cellTile(tx, ty)
    local bow = indexed.ssAnneBow
    if bow and mapId == tostring(bow.map or "") then
      return front == tonumber(bow.tile)
    end
    local tiles = indexed.tiles and indexed.tiles[dir]
    Twin.yellowWarpCarpetIndexHits = (Twin.yellowWarpCarpetIndexHits or 0) + 1
    return tiles and tiles[tonumber(front)] == true or false
  end

  local carpets = region and region.loaded and region.loaded.field
      and region.loaded.field.warpCarpets
  if type(carpets) == "table" then
    local function inList(list, value)
      for _, item in ipairs(list or {}) do if item == value then return true end end
      return false
    end
    local mapId = map.sourceId or map.id
    local useCarpet
    if inList(carpets.edgeMaps, mapId) then
      useCarpet = false
    elseif inList(carpets.function2Maps, mapId) then
      useCarpet = true
    else
      useCarpet = inList(carpets.function2Tilesets, map.def and map.def.tileset)
    end
    if not useCarpet then
      return not map:inBounds(tx, ty)
    end
    local front = map:cellTile(tx, ty)
    if carpets.ssAnneBow and mapId == carpets.ssAnneBow.map then
      return front == carpets.ssAnneBow.tile
    end
    local tiles = carpets.tiles and carpets.tiles[dir]
    return inList(tiles, front)
  end
  -- Old Yellow caches do not carry field.warpCarpets. Match Gen1Recomp's
  -- no-metadata fallback exactly: ExtraWarpCheck is an edge-facing test, not
  -- "the tile in front happens to be a door". The warp record remains under
  -- the player's current cell in all three trigger modes.
  return not map:inBounds(tx, ty)
end
Twin._collisionWarpAllowed = collisionWarpAllowed

-- Resolve a Yellow warp using the same important invariants as current
-- Gen1Recomp's Warp.lua. mode is "arrive", "edge", or "collision".
local function resolveWarp(region, mapId, cx, cy, mode, dir)
  local map = ensureForeignMap(region, mapId)
  local found = map and map:warpAtCell(cx, cy)
  local warp = found and (found.def or found)
  if not warp then return nil end
  if Twin._warpIgnoreMatches(mapId, cx, cy) then return nil end

  mode = mode or "arrive"
  if mode == "arrive" then
    -- A normal step warp only fires when the collision tile is a door/warp
    -- tile. Merely sharing coordinates with a warp record is not enough.
    if not map:isWarpTileCell(cx, cy) then return nil end
  elseif mode == "edge" then
    local tx, ty = targetCell(cx, cy, dir)
    if map:inBounds(tx, ty) then return nil end
  elseif mode == "collision" then
    if not collisionWarpAllowed(map, cx, cy, dir) then return nil end
  end

  local rawDestId = warp.destMap or warp.map or warp.mapId
  if KantoGameplay.leagueWarpBlocked(region, mapId, rawDestId) then
    Twin.yellowLeagueRetreatBlocks = (Twin.yellowLeagueRetreatBlocks or 0) + 1
    return nil
  end
  local post = KantoState.Postgame
  local caveUnlocked = post.ceruleanCaveUnlocked(KantoState.event)
  if post.blocksWarp(mapId, rawDestId, caveUnlocked) then
    Twin.yellowCeruleanCaveBlocks = (Twin.yellowCeruleanCaveBlocks or 0) + 1
    return nil
  end
  local destId = rawDestId
  local voyage = KantoState.SSAnne
  if voyage and KantoState.event(voyage.SHIP.leftEvent)
      and tostring(mapId or "") == voyage.SHIP.dockMap
      and tostring(rawDestId or "") == voyage.SHIP.shipMap then
    return nil
  end
  local lastOutside = excursion.lastOutside
  local isLast = destId == "LAST_MAP" or destId == "LASTMAP"
  if isLast then destId = lastOutside and lastOutside.id or nil end
  local destMap = destId and ensureForeignMap(region, destId) or nil
  if not destMap then
    Twin.kantoWarpFailures = (Twin.kantoWarpFailures or 0) + 1
    return nil
  end

  local destIndex = tonumber(warp.destWarp or warp.warp or warp.warpId) or 1
  local destWarp = destMap.def.warps and destMap.def.warps[destIndex]
  local dx, dy
  if destWarp then
    dx, dy = tonumber(destWarp.x), tonumber(destWarp.y)
  elseif isLast and lastOutside then
    -- Current Gen1Recomp uses the remembered entry coordinate only as the
    -- fallback for malformed/out-of-range LAST_MAP data.
    dx, dy = tonumber(lastOutside.x), tonumber(lastOutside.y)
    Twin.kantoWarpRecoveries = (Twin.kantoWarpRecoveries or 0) + 1
  else
    -- Never teleport to an arbitrary map center: that was a major source of
    -- Kanto wall/void softlocks in the old adapter.
    Twin.kantoWarpFailures = (Twin.kantoWarpFailures or 0) + 1
    return nil
  end
  if dx == nil or dy == nil or not destMap:inBounds(dx, dy) then
    Twin.kantoWarpFailures = (Twin.kantoWarpFailures or 0) + 1
    return nil
  end

  local sourceDef = region.loaded.maps[mapId]
  local destDef = region.loaded.maps[destId]
  local sourceOutside = mapIsOutside(nil, sourceDef)
  local destOutside = mapIsOutside(nil, destDef)

  -- LAST_MAP remembers the outside side, not a stack of arbitrary interiors.
  -- This is important for nested buildings/caves and two-sided route gates.
  if sourceOutside and not destOutside then
    excursion.lastOutside = { id = mapId, x = cx, y = cy }
  elseif destOutside and not sourceOutside and not isLast then
    excursion.lastOutside = { id = destId, x = dx, y = dy }
  end

  Twin.kantoWarps = (Twin.kantoWarps or 0) + 1
  return destId, dx, dy
end

local function applyWarp(region, mapId, cx, cy, mode, dir)
  local sourceMap = ensureForeignMap(region, mapId)
  local padKind = sourceMap and type(sourceMap.warpPadOrHoleAt) == "function"
    and sourceMap:warpPadOrHoleAt(cx, cy) or nil
  local destId, dx, dy = resolveWarp(region, mapId, cx, cy, mode, dir)
  if not destId then return false end
  if padKind == "pad" then
    Twin.yellowWarpPadTransitions = (Twin.yellowWarpPadTransitions or 0) + 1
  elseif padKind == "hole" then
    Twin.yellowWarpHoleTransitions = (Twin.yellowWarpHoleTransitions or 0) + 1
  end
  KantoGameplay.leagueWarpTransition(region, mapId, destId)
  excursion.sourceMapId = destId
  KantoState.onMapEntered(region, destId)
  excursion.cellX, excursion.cellY = dx, dy
  excursion.forcedMovementCheckKey = nil
  excursion.drawPx, excursion.drawPy = dx * 16, dy * 16
  excursion.toMapId, excursion.toCellX, excursion.toCellY = nil, nil, nil
  Twin._setWarpIgnore(destId, dx, dy)
  excursion.standingOnWarp = true
  excursion.currentRecord = recordBySource(region, destId)
  excursion.strengthActive = false
  excursion.forcedMoves, excursion.forcedMoveIndex, excursion.seafoamCurrentLock = nil, 0, false
  local destMap = ensureForeignMap(region, destId)
  if excursion.surfing and destMap and not destMap:isWaterCell(dx, dy) then excursion.surfing = false end
  KantoGameplay.rememberCenter(region, destId, dx, dy)
  if not KantoGameplay.isDarkMap(region, destId) then excursion.flashActive = false end
  clearDirectionalBody(false)
  Twin.excursionSourceMap = destId
  Twin.excursionCellX, Twin.excursionCellY = dx, dy
  persistExcursionPosition()
  if KantoGameplay.ssAnneWarpTransition(region, mapId, destId) then return true end
  -- Returning through the gate while a Safari game is live is an explicit
  -- early-exit choice. NO restores the source warp cell with that warp ignored
  -- until the player steps away, matching the cart's one-step walk back in.
  if excursion.safari and destId == "SAFARI_ZONE_GATE"
      and KantoGameplay.isSafariStepMap(mapId) then
    local backMap, backX, backY, backFacing = mapId, cx, cy, excursion.facing
    askYesNo(excursion.world, "Leaving early?", function(yes)
      if yes then
        excursion.safari, excursion.safariEncounter = nil, nil
        excursion.battleBusy = false
        Twin.yellowSafariEarlyExits = (Twin.yellowSafariEarlyExits or 0) + 1
        showMessage(excursion.world, "Please return any remaining SAFARI BALLs.\fCome again!")
      else
        KantoGameplay.relocate(region, backMap, backX, backY, backFacing, excursion.lastOutside)
        Twin._setWarpIgnore(backMap, backX, backY)
        excursion.standingOnWarp = true
        showMessage(excursion.world, "Good Luck!")
      end
    end)
  end
  return true
end

-- Story-free Kanto intentionally does not execute Yellow map ASM, but a few
-- map scripts contain PHYSICAL floor behavior rather than story progression.
-- Current Gen1Recomp's Victory Road parity test documents this walkable hole:
-- VICTORY_ROAD_3F (23,15) falls to VICTORY_ROAD_2F (22,16). Seafoam's holes
-- remain handled by the richer extracted field.seafoam system below. Keep this
-- table deliberately tiny: every row must correspond to a verified physical
-- floor trigger that story-free Kanto otherwise loses by not running map ASM.
local KANTO_DUNGEON_HOLES = {
  VICTORY_ROAD_3F = {
    ["23,15"] = { map = "VICTORY_ROAD_2F", x = 22, y = 16 },
  },
  -- Pokemon Mansion 3F's three broken-floor triggers are dungeon warps in
  -- Yellow, not ordinary warp events. DungeonWarpList/DungeonWarpData sends
  -- the first two holes to 1F (16,14) and the right-hand hole to 2F (18,14).
  -- Keeping them here gives the private Kanto adapter the same physical falls
  -- without executing Yellow's story ASM.
  POKEMON_MANSION_3F = {
    ["16,14"] = { map = "POKEMON_MANSION_1F", x = 16, y = 14 },
    ["17,14"] = { map = "POKEMON_MANSION_1F", x = 16, y = 14 },
    ["19,14"] = { map = "POKEMON_MANSION_2F", x = 18, y = 14 },
  },
}

local function resolveDungeonHole(_region, mapId, x, y)
  local rows = KANTO_DUNGEON_HOLES[mapId]
  local row = rows and rows[tostring(x) .. "," .. tostring(y)] or nil
  return row and row.map or nil, row and row.x or nil, row and row.y or nil
end

local function applyDungeonHole(region, mapId, x, y)
  local destId, dx, dy = resolveDungeonHole(region, mapId, x, y)
  if not destId then return false end
  local destMap = ensureForeignMap(region, destId)
  if not (destMap and destMap:inBounds(dx, dy) and passable(destMap, dx, dy, false)) then
    Twin.kantoWarpFailures = (Twin.kantoWarpFailures or 0) + 1
    return false
  end
  excursion.sourceMapId = destId
  KantoState.onMapEntered(region, destId)
  excursion.cellX, excursion.cellY = dx, dy
  excursion.forcedMovementCheckKey = nil
  excursion.drawPx, excursion.drawPy = dx * 16, dy * 16
  excursion.toMapId, excursion.toCellX, excursion.toCellY = nil, nil, nil
  Twin._setWarpIgnore(destId, dx, dy)
  excursion.standingOnWarp = true
  excursion.currentRecord = recordBySource(region, destId)
  excursion.strengthActive = false
  excursion.forcedMoves, excursion.forcedMoveIndex, excursion.seafoamCurrentLock = nil, 0, false
  excursion.surfing = false
  if not KantoGameplay.isDarkMap(region, destId) then excursion.flashActive = false end
  clearDirectionalBody(false)
  Twin.excursionSourceMap = destId
  Twin.excursionCellX, Twin.excursionCellY = dx, dy
  Twin.yellowDungeonFalls = (Twin.yellowDungeonFalls or 0) + 1
  persistExcursionPosition()
  return true
end

function KantoGameplay.queueForcedMoves(moves)
  local out = {}
  for _, row in ipairs(type(moves) == "table" and moves or {}) do
    local dir, count = row.dir, math.max(1, tonumber(row.count) or 1)
    if KantoGameplay.DIR_DELTA[dir] then
      for _ = 1, count do out[#out + 1] = dir end
    end
  end
  if #out == 0 then return false end
  excursion.forcedMoves, excursion.forcedMoveIndex = out, 1
  excursion.seafoamCurrentLock = true
  return true
end

function KantoGameplay.queueSeafoamMoves(moves)
  local ok = KantoGameplay.queueForcedMoves(moves)
  if ok then Twin.yellowSeafoamCurrents = (Twin.yellowSeafoamCurrents or 0) + 1 end
  return ok
end

function KantoGameplay.trySpinner(region, mapId, x, y)
  mapId = tostring(mapId or "")
  local indexed = region and region.fieldIndex and region.fieldIndex.spinners
  local perMap = indexed and indexed[mapId]
  if type(perMap) == "table" then
    local row = perMap[math.floor(tonumber(y) or -9999) * 1024
      + math.floor(tonumber(x) or -9999)]
    if row and KantoGameplay.queueForcedMoves(row.moves) then
      Twin.yellowSpinnerIndexHits = (Twin.yellowSpinnerIndexHits or 0) + 1
      Twin.yellowSpinnerRuns = (Twin.yellowSpinnerRuns or 0) + 1
      KantoGameplay.playSound(excursion.world, "Arrow_Tiles")
      return true
    end
    return false
  end
  local field = region and region.loaded and region.loaded.field
  local rows = field and field.spinners and field.spinners[mapId]
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    if tonumber(row.x) == tonumber(x) and tonumber(row.y) == tonumber(y)
        and KantoGameplay.queueForcedMoves(row.moves) then
      Twin.yellowSpinnerRuns = (Twin.yellowSpinnerRuns or 0) + 1
      KantoGameplay.playSound(excursion.world, "Arrow_Tiles")
      return true
    end
  end
  return false
end
Twin._trySpinner = KantoGameplay.trySpinner

function KantoGameplay.trySeafoamCurrent(region, mapId, x, y)
  if excursion.seafoamCurrentLock then return false end
  local def = KantoGameplay.seafoamDef(region, mapId)
  if not def then return false end
  if KantoGameplay.seafoamEventsSatisfied(def.currentsDisabledByEvents) then return false end
  if type(def.entryCurrent) == "table" and tonumber(def.entryCurrent.x) == x
      and tonumber(def.entryCurrent.y) == y then
    return KantoGameplay.queueSeafoamMoves(def.entryCurrent.moves)
  end
  for _, cur in ipairs(def.currents or {}) do
    if tonumber(cur.x) == x and tonumber(cur.y) == y then
      return KantoGameplay.queueSeafoamMoves(cur.moves)
    end
  end
  if type(def.forcedExit) == "table"
      and not KantoGameplay.seafoamEventsSatisfied(def.forcedExit.activeUntilEvents) then
    for _, c in ipairs(def.forcedExit.coords or {}) do
      if tonumber(c.x) == x and tonumber(c.y) == y then
        local n = y >= 17 and 2 or 1
        local rows = { { dir = "up", count = n } }
        return KantoGameplay.queueSeafoamMoves(rows)
      end
    end
  end
  return false
end
Twin._trySeafoamCurrent = KantoGameplay.trySeafoamCurrent

local function afterExcursionCellLanding(world)
  -- Summer Beach House's "asked" and "surfed" bits are map-load-local in
  -- Yellow.  Clear them after any landing outside the shack so re-entry starts
  -- a fresh visit while the persisted high score remains Kanto-local.
  if KantoGameplay.SummerBeach and type(KantoGameplay.SummerBeach.resetVisit) == "function" then
    KantoGameplay.SummerBeach.resetVisit(excursion, excursion.sourceMapId)
  end
  if KantoGameplay.safariStep(world) then return true end

  -- Warp bounce suppression is normally scalar.  Clear it only after the
  -- player actually leaves the destination cell; this avoids allocating a
  -- comparison string on every completed Kanto step.
  if excursion.ignoreWarpMap ~= nil then
    if not Twin._warpIgnoreMatches(excursion.sourceMapId, excursion.cellX, excursion.cellY) then
      Twin._clearWarpIgnore()
      excursion.standingOnWarp = false
    end
  elseif excursion.ignoreWarpKey ~= nil
      and not Twin._warpIgnoreMatches(excursion.sourceMapId, excursion.cellX, excursion.cellY) then
    -- Compatibility for older tests/external integrations that still seed the
    -- legacy string field.
    Twin._clearWarpIgnore()
    excursion.standingOnWarp = false
  end

  -- We need the current adapter later for Surf/encounter ownership anyway.
  -- Its warp table is already O(1), so probe it once up front. Most Kanto
  -- cells have no warp: skip both resolveWarp passes and all pad/collision tile
  -- work entirely on those ordinary landings.
  local landedMap = ensureForeignMap(excursion.region, excursion.sourceMapId)
  local landedWarp = landedMap and landedMap:warpAtCell(excursion.cellX, excursion.cellY) or nil
  if not landedWarp then
    Twin.kantoWarpLandingFastSkips = (Twin.kantoWarpLandingFastSkips or 0) + 1
  end

  -- Physical script hole before ordinary map warps. This restores Victory
  -- Road's walkable fall without enabling any Yellow story/cutscene ASM.
  if applyDungeonHole(excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY) then
    return true
  end
  if landedWarp and applyWarp(excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY, "arrive") then
    return true
  end
  -- Match CheckWarpsNoCollision's second arm: a non-door warp square also
  -- fires when ExtraWarpCheck passes and the direction is still held, while
  -- authored forced movement (Seafoam/spinner runs) acts like BIT_FORCED_WARP.
  local forcedWarp = type(excursion.forcedMoves) == "table" or excursion.seafoamCurrentLock == true
  if landedWarp and (forcedWarp or directionStillHeld(world, excursion.facing))
      and applyWarp(excursion.region, excursion.sourceMapId,
        excursion.cellX, excursion.cellY, "collision", excursion.facing) then
    Twin.yellowExtraWarpArrivals = (Twin.yellowExtraWarpArrivals or 0) + 1
    return true
  end
  if excursion.surfing and landedMap and not landedMap:isWaterCell(excursion.cellX, excursion.cellY) then
    excursion.surfing = false
  end
  persistExcursionPosition(false)
  KantoGameplay.markFlyVisited(excursion.region, excursion.sourceMapId)
  if not KantoGameplay.isDarkMap(excursion.region, excursion.sourceMapId) then
    excursion.flashActive = false
  end
  if KantoGameplay.trySpinner(excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY) then return true end
  if excursion.surfing and KantoGameplay.trySeafoamCurrent(excursion.region,
      excursion.sourceMapId, excursion.cellX, excursion.cellY) then return true end

  -- v0.3.84 restores the Kanto quest gates that are physical/progression
  -- critical but cannot safely run Yellow's story ASM against Gold's save.
  if KantoGameplay.rocketHideoutDuoStep(world, excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY) then return true end
  if KantoGameplay.towerMarowakStep(world, excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY) then return true end
  if KantoGameplay.towerRocketStep(world, excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY) then return true end
  if KantoGameplay.handleSilphStep(world, excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY) then return true end
  if KantoGameplay.handleSSAnneStep(world, excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY) then return true end
  if KantoGameplay.handleRivalStep(world, excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY) then return true end
  if KantoGameplay.handleLeagueStep(world, excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY) then return true end

  -- Story-free civic access scripts: Saffron's four thirsty gate guards and
  -- Pewter Museum's ticket rope. Gold owns money/items; Kanto persists only
  -- the foreign-region access flags. These consume the landing before trainer
  -- sight or wild encounters, matching Yellow's map-script ordering.
  if KantoGameplay.handleCivicStep(world, excursion.region, excursion.sourceMapId,
      excursion.cellX, excursion.cellY) then return true end

  -- Pokemon Tower 5F's purified 2x2 pad is a physical map-script rule, not
  -- story progression. It heals Gold's real party once per entry and consumes
  -- every landing while occupied, reproducing BIT_NO_BATTLES without running
  -- Yellow's story VM. Stepping off clears the visit-local latch.
  if KantoGameplay.handleTowerPurifiedZone(world, excursion.region,
      excursion.sourceMapId, excursion.cellX, excursion.cellY) then return true end

  -- Yellow trainer headers carry their authentic inclusive sight range. A
  -- completed Kanto cell takes trainer ownership before wild encounters, just
  -- like the original overworld script pass does.
  if KantoGameplay.checkYellowTrainerSight(world) then return true end

  -- Visible-first encounter ownership matches the rest of this mod: touching a
  -- roaming Yellow Pokemon always starts a real Gold battle. If CLASSIC STEP
  -- ENC is enabled, ordinary Yellow grass/cave encounter rates also roll here.
  local mon = pokemonAt(excursion.region, excursion.sourceMapId,
    excursion.cellX, excursion.cellY)
  if mon and mon.species then
    if startYellowWildBattle(world, excursion.region, excursion.sourceMapId,
        mon.species, tonumber(mon.level) or 2, mon) then return true end
  end
  rollYellowStepEncounter(world, excursion.region, excursion.sourceMapId, landedMap,
    excursion.cellX, excursion.cellY)
  return excursion.battleBusy == true
end

local function finishExcursionStep(world)
  local oldMapId = excursion.sourceMapId
  excursion.sourceMapId = excursion.toMapId or excursion.sourceMapId
  if excursion.sourceMapId ~= oldMapId then
    KantoState.onMapEntered(excursion.region, excursion.sourceMapId)
    if KantoGameplay.markFossilReadyOnMapEntry then
      KantoGameplay.markFossilReadyOnMapEntry(excursion.sourceMapId)
    end
    excursion.strengthActive = false
    if not KantoGameplay.isDarkMap(excursion.region, excursion.sourceMapId) then excursion.flashActive = false end
  end
  excursion.cellX = excursion.toCellX or excursion.cellX
  excursion.cellY = excursion.toCellY or excursion.cellY
  excursion.drawPx, excursion.drawPy = excursion.cellX * 16, excursion.cellY * 16
  excursion.moving = false
  excursion.moveDurationCurrent = nil
  excursion.hopActive, excursion.hopProgress, excursion.hopLift, excursion.hopSeam = false, 0, 0, false
  excursion.stepFlip = not excursion.stepFlip
  Twin.excursionSteps = (Twin.excursionSteps or 0) + 1
  if excursion.sourceMapId ~= oldMapId then persistExcursionPosition(true) end
  afterExcursionCellLanding(world)
end

local function freeBlockedCell(region, mapId, map, cx, cy)
  if cx == excursion.cellX and cy == excursion.cellY then return nil end
  if not map:inBounds(cx, cy) then return "bounds" end
  if not passable(map, cx, cy, false) then return "tile" end
  if occupiedByNpc(region, mapId, cx, cy) then return "entity" end
  return nil
end

local function freeSlideX(region, mapId, map, dx)
  if math.abs(dx) <= 1e-9 then return nil end
  local r = KANTO_FREE_RADIUS
  local x, z = excursion.freeX, excursion.freeZ
  local nx = x + dx
  local z0 = math.floor((z - r + KANTO_FREE_EPS) / 16)
  local z1 = math.floor((z + r - KANTO_FREE_EPS) / 16)
  local edge = dx > 0 and math.floor((nx + r) / 16)
    or math.floor((nx - r) / 16)
  local hit
  for cz = z0, z1 do
    hit = freeBlockedCell(region, mapId, map, edge, cz)
    if hit then break end
  end
  if hit then
    if dx > 0 then nx = math.min(nx, edge * 16 - r - KANTO_FREE_EPS)
    else nx = math.max(nx, (edge + 1) * 16 + r + KANTO_FREE_EPS) end
  end
  excursion.freeX = nx
  return hit
end

local function freeSlideZ(region, mapId, map, dz)
  if math.abs(dz) <= 1e-9 then return nil end
  local r = KANTO_FREE_RADIUS
  local x, z = excursion.freeX, excursion.freeZ
  local nz = z + dz
  local x0 = math.floor((x - r + KANTO_FREE_EPS) / 16)
  local x1 = math.floor((x + r - KANTO_FREE_EPS) / 16)
  local edge = dz > 0 and math.floor((nz + r) / 16)
    or math.floor((nz - r) / 16)
  local hit
  for cx = x0, x1 do
    hit = freeBlockedCell(region, mapId, map, cx, edge)
    if hit then break end
  end
  if hit then
    if dz > 0 then nz = math.min(nz, edge * 16 - r - KANTO_FREE_EPS)
    else nz = math.max(nz, (edge + 1) * 16 + r + KANTO_FREE_EPS) end
  end
  excursion.freeZ = nz
  return hit
end

local function handoffFreeConnection(world, dir)
  local region, sourceId = excursion.region, excursion.sourceMapId
  local destId, tx, ty = moveCandidate(region, sourceId,
    excursion.cellX, excursion.cellY, dir, world)
  if not destId or destId == sourceId then return false end

  -- Preserve the sub-cell offset perpendicular to the seam.  Forward motion
  -- snaps to the destination cell centre exactly like Gold's connection
  -- handoff; the sideways fraction survives, so diagonal travel does not
  -- suddenly jump to the middle of a route at a seam.
  local offX = (excursion.freeX or (excursion.cellX * 16 + 8))
    - (excursion.cellX * 16 + 8)
  local offZ = (excursion.freeZ or (excursion.cellY * 16 + 8))
    - (excursion.cellY * 16 + 8)
  excursion.sourceMapId = destId
  KantoState.onMapEntered(region, destId)
  excursion.strengthActive = false
  excursion.cellX, excursion.cellY = tx, ty
  excursion.freeMapId = destId
  excursion.freeX, excursion.freeZ = tx * 16 + 8, ty * 16 + 8
  if dir == "left" or dir == "right" then
    excursion.freeZ = excursion.freeZ + math.max(-7.0, math.min(7.0, offZ))
  else
    excursion.freeX = excursion.freeX + math.max(-7.0, math.min(7.0, offX))
  end
  excursion.drawPx, excursion.drawPy = excursion.freeX - 8, excursion.freeZ - 8
  excursion.currentRecord = recordBySource(region, destId)
  Twin.excursionSourceMap = destId
  Twin.excursionCellX, Twin.excursionCellY = tx, ty
  excursion.freeCellCrossings = (excursion.freeCellCrossings or 0) + 1
  Twin.kantoFreeCellCrossings = (Twin.kantoFreeCellCrossings or 0) + 1
  persistExcursionPosition(true)
  afterExcursionCellLanding(world)
  return true
end

local function tryFreeSpecialHandoff(world, hit, dir, moved, requested)
  if not (hit and dir) then return false end
  if moved >= requested * 0.75 then return false end
  -- A ledge is intentionally a collision tile. Give its authored one-way hop
  -- first refusal before ordinary wall/warp handling in 1ST/3RD PERSON.
  if hit == "tile" and startLedgeHop(world, dir) then return true end
  if hit == "bounds" and handoffFreeConnection(world, dir) then return true end
  if (hit == "tile" or hit == "bounds") and applyWarp(excursion.region,
      excursion.sourceMapId, excursion.cellX, excursion.cellY,
      hit == "bounds" and "edge" or "collision", dir) then
    return true
  end
  return false
end

local function tickDirectionalBody(world, dt, wx, wz)
  local region, mapId = excursion.region, excursion.sourceMapId
  local map = ensureForeignMap(region, mapId)
  if not map then return false end
  if not excursion.freeActive or excursion.freeMapId ~= mapId
      or excursion.freeX == nil or excursion.freeZ == nil then
    adoptDirectionalBody()
  end

  wx, wz = tonumber(wx) or 0, tonumber(wz) or 0
  local mag = math.sqrt(wx * wx + wz * wz)
  if mag > 1 then
    wx, wz, mag = wx / mag, wz / mag, 1
  end
  excursion.lastWorldX, excursion.lastWorldZ = wx, wz
  if mag <= 1e-6 then
    excursion.freeVisualMoving = false
    return true
  end

  local dir = directionFromWorldVector(wx, wz)
  excursion.facing = (FirstPerson and type(FirstPerson.pointBody) == "function"
      and FirstPerson.pointBody(wx, wz)) or dir or excursion.facing
  excursion.animClock = (excursion.animClock or 0) + math.max(1, dt * 60)

  local speed = KANTO_FREE_SPEED
  if excursion.biking then
    local moveDir = directionFromWorldVector(wx, wz)
    if not (KantoGameplay.isSlopeMap(region, mapId) and moveDir ~= "down") then
      speed = speed * 2
    end
  end
  local distance = speed * math.max(0, math.min(0.05, dt))
  -- On the first frame after a state handoff `dt` can be zero. Johto's fixed
  -- step would still move on the next logic frame; leave this frame stationary
  -- rather than inventing elapsed time.
  if distance <= 1e-6 then
    excursion.freeVisualMoving = false
    return true
  end
  local dx, dz = wx * distance, wz * distance
  -- The continuous body must obey the same extracted badge gates as the grid
  -- mover. Test the cell each axis is about to enter before wall sliding; this
  -- keeps Route 23/22 closed in FIRST/THIRD PERSON instead of only DIORAMA.
  do
    local cx, cy = excursion.cellX, excursion.cellY
    local nx = math.floor((excursion.freeX + dx) / 16)
    local ny = math.floor((excursion.freeZ + dz) / 16)
    if ny ~= cy then
      local d = ny < cy and "up" or "down"
      local gate = KantoGameplay.badgeGateForStep(region, mapId, cx, ny, d)
      if gate and not KantoGameplay.ownsKantoBadge(world, gate.badge) then
        dz = 0
        Twin.yellowBadgeGateBlocks = (Twin.yellowBadgeGateBlocks or 0) + 1
        showMessage(world, textByLabel(region, gate.failText)
          or ("You need the " .. tostring(gate.badge or "BADGE") .. " to pass."))
      end
      local itemGate = KantoGameplay.itemGateForStep(region, mapId, cx, ny, d)
      if itemGate and not KantoGameplay.ensureKantoLocalItem(world, region, itemGate.item) then
        dz = 0
        KantoGameplay.showItemGateBlock(world, region, mapId, itemGate)
      end
    end
    if nx ~= cx then
      local d = nx < cx and "left" or "right"
      local gate = KantoGameplay.badgeGateForStep(region, mapId, nx, cy, d)
      if gate and not KantoGameplay.ownsKantoBadge(world, gate.badge) then
        dx = 0
        Twin.yellowBadgeGateBlocks = (Twin.yellowBadgeGateBlocks or 0) + 1
        showMessage(world, textByLabel(region, gate.failText)
          or ("You need the " .. tostring(gate.badge or "BADGE") .. " to pass."))
      end
      local itemGate = KantoGameplay.itemGateForStep(region, mapId, nx, cy, d)
      if itemGate and not KantoGameplay.ensureKantoLocalItem(world, region, itemGate.item) then
        dx = 0
        KantoGameplay.showItemGateBlock(world, region, mapId, itemGate)
      end
    end
  end
  -- Continuous 1ST/3RD PERSON movement still crosses the same 16px cell
  -- boundaries as the original grid mover. Refuse an axis before wall-slide
  -- resolution when that boundary is one of the extracted elevation pairs.
  local pairHitX, pairHitZ
  local pcx = math.floor((excursion.freeX or 0) / 16)
  local pcy = math.floor((excursion.freeZ or 0) / 16)
  if math.abs(dx) > 1e-9 then
    local tx = math.floor(((excursion.freeX or 0) + dx) / 16)
    if tx ~= pcx and map:inBounds(tx, pcy)
        and KantoState.pairBlocked(region, map, pcx, pcy, tx, pcy, false) then
      dx, pairHitX = 0, "tile"
      Twin.yellowPairCollisionBlocks = (Twin.yellowPairCollisionBlocks or 0) + 1
      Twin.yellowFreePairCollisionBlocks = (Twin.yellowFreePairCollisionBlocks or 0) + 1
    end
  end
  if math.abs(dz) > 1e-9 then
    local ty = math.floor(((excursion.freeZ or 0) + dz) / 16)
    if ty ~= pcy and map:inBounds(pcx, ty)
        and KantoState.pairBlocked(region, map, pcx, pcy, pcx, ty, false) then
      dz, pairHitZ = 0, "tile"
      Twin.yellowPairCollisionBlocks = (Twin.yellowPairCollisionBlocks or 0) + 1
      Twin.yellowFreePairCollisionBlocks = (Twin.yellowFreePairCollisionBlocks or 0) + 1
    end
  end

  KantoGameplay.tryFreeBoulderPush(world, region, mapId, wx, wz)
  local oldX, oldZ = excursion.freeX, excursion.freeZ
  local hitX = pairHitX or freeSlideX(region, mapId, map, dx)
  local hitZ = pairHitZ or freeSlideZ(region, mapId, map, dz)
  if hitX or hitZ then
    excursion.freeWallSlides = (excursion.freeWallSlides or 0) + 1
    Twin.kantoFreeWallSlides = (Twin.kantoFreeWallSlides or 0) + 1
  end

  local movedX, movedZ = excursion.freeX - oldX, excursion.freeZ - oldZ
  local moved = math.sqrt(movedX * movedX + movedZ * movedZ)
  excursion.freeVisualMoving = moved > 0.01
  excursion.animDistance = (excursion.animDistance or 0) + moved
  while excursion.animDistance >= 16 do
    excursion.animDistance = excursion.animDistance - 16
    excursion.stepFlip = not excursion.stepFlip
  end
  excursion.drawPx, excursion.drawPy = excursion.freeX - 8, excursion.freeZ - 8
  Twin.kantoFreeFrames = (Twin.kantoFreeFrames or 0) + 1

  local ncx = math.floor(excursion.freeX / 16)
  local ncy = math.floor(excursion.freeZ / 16)
  if map:inBounds(ncx, ncy) and (ncx ~= excursion.cellX or ncy ~= excursion.cellY) then
    excursion.cellX, excursion.cellY = ncx, ncy
    excursion.freeCellCrossings = (excursion.freeCellCrossings or 0) + 1
    Twin.kantoFreeCellCrossings = (Twin.kantoFreeCellCrossings or 0) + 1
    Twin.excursionSteps = (Twin.excursionSteps or 0) + 1
    Twin.excursionCellX, Twin.excursionCellY = ncx, ncy
    if afterExcursionCellLanding(world) then
      clearDirectionalBody(true)
      return true
    end
  end

  local hit, blockedDir
  if hitX and (not hitZ or math.abs(dx) >= math.abs(dz)) then
    hit, blockedDir = hitX, dx > 0 and "right" or "left"
  elseif hitZ then
    hit, blockedDir = hitZ, dz > 0 and "down" or "up"
  end
  if tryFreeSpecialHandoff(world, hit, blockedDir, moved, distance) then
    return true
  end
  return true
end

function Twin.tickExcursion(world)
  if not excursion.active then return false end
  excursion.overlayCovered = nil
  if world and excursion.world ~= world then excursion.world = world end
  local t = now()
  local dt = excursion.lastTick and math.max(0, math.min(0.05, t - excursion.lastTick)) or 0
  excursion.lastTick = t

  if excursion.moving then
    clearDirectionalBody(false)
    local oldPx, oldPy = excursion.drawPx, excursion.drawPy
    local duration = excursion.moveDurationCurrent or excursion.moveDuration
    excursion.moveT = math.min(1, excursion.moveT + dt / math.max(0.001, duration))
    if excursion.hopActive then
      excursion.hopProgress = excursion.moveT
      excursion.hopLift = math.sin(math.pi * excursion.moveT) * 8
    end
    local k = excursion.moveT
    k = k * k * (3 - 2 * k)
    excursion.drawPx = excursion.fromPx + (excursion.toPx - excursion.fromPx) * k
    excursion.drawPy = excursion.fromPy + (excursion.toPy - excursion.fromPy) * k
    local moved = math.sqrt((excursion.drawPx - oldPx)^2 + (excursion.drawPy - oldPy)^2)
    excursion.animDistance = (excursion.animDistance or 0) + moved
    excursion.animClock = (excursion.animClock or 0) + dt * 60
    if excursion.moveT >= 1 then finishExcursionStep(world) end
    return true
  end

  if excursion.battleBusy or excursion.trainerEngaging then
    clearDirectionalBody(true); return true
  end
  local covered = overlayOpen(world)
  excursion.overlayCovered = covered
  if covered then
    -- A menu/overlay is a natural save checkpoint. Flush any coalesced travel
    -- position once when gameplay becomes covered; subsequent covered frames
    -- are no-ops because positionDirty is cleared.
    Twin._flushExcursionPosition()
    -- Mod settings are normally changed from an overlay/menu. Re-arm the
    -- cached encounter toggle while covered so the first landing after the UI
    -- closes observes any change without paying an options bridge call on every
    -- ordinary step.
    Twin._invalidateEncounterOptionCache()
    clearDirectionalBody(true)
    return true
  end
  KantoGameplay.tickKantoNpcAI(world, dt, false)

  -- CheckForceBikeOrSurf runs on placement/landing. Cache the checked cell so
  -- an idle Android frame does not rescan the extracted force table at render
  -- rate; a real cell/map transition changes the key and re-arms the check.
  if excursion.forcedMovementCheckMap ~= excursion.sourceMapId
      or excursion.forcedMovementCheckX ~= excursion.cellX
      or excursion.forcedMovementCheckY ~= excursion.cellY then
    excursion.forcedMovementCheckMap = excursion.sourceMapId
    excursion.forcedMovementCheckX, excursion.forcedMovementCheckY = excursion.cellX, excursion.cellY
    if KantoGameplay.syncForcedBike(world, excursion.region, excursion.sourceMapId,
        excursion.cellX, excursion.cellY) then return true end
  end

  -- Seafoam currents are extracted as simulated joypad runs. Consume one
  -- authored direction at a time through the same Kanto grid mover, so warps,
  -- boulders, collisions and sector handoffs retain their normal ownership.
  if type(excursion.forcedMoves) == "table" then
    local dir = excursion.forcedMoves[excursion.forcedMoveIndex or 1]
    if not dir then
      excursion.forcedMoves, excursion.forcedMoveIndex, excursion.seafoamCurrentLock = nil, 0, false
    else
      excursion.forcedMoveIndex = (excursion.forcedMoveIndex or 1) + 1
      if startLedgeHop(world, dir) then return true end
      local mapId, tx, ty = moveCandidate(excursion.region, excursion.sourceMapId,
        excursion.cellX, excursion.cellY, dir, world)
      if mapId then
        excursion.facing = dir
        excursion.fromPx, excursion.fromPy = excursion.drawPx, excursion.drawPy
        excursion.toPx, excursion.toPy = tx * 16, ty * 16
        excursion.toMapId, excursion.toCellX, excursion.toCellY = mapId, tx, ty
        excursion.moveDurationCurrent = nil
        excursion.hopActive, excursion.hopProgress, excursion.hopLift, excursion.hopSeam = false, 0, 0, false
        excursion.moveT, excursion.moving = 0, true
      else
        excursion.forcedMoves, excursion.forcedMoveIndex, excursion.seafoamCurrentLock = nil, 0, false
      end
      return true
    end
  end

  local input = world and world.game and world.game.input
  -- FIRST/THIRD PERSON controller ownership cannot change halfway through this
  -- Kanto tick. Resolve the controller state/functions once instead of asking
  -- `driving()` and re-checking three method types in several movement branches.
  local fpDrivingFn = FirstPerson and type(FirstPerson.driving) == "function" and FirstPerson.driving or nil
  local fpMoveVector = FirstPerson and type(FirstPerson.moveVector) == "function" and FirstPerson.moveVector or nil
  local fpMoveWorld = FirstPerson and type(FirstPerson.moveWorld) == "function" and FirstPerson.moveWorld or nil
  local fpPointBody = FirstPerson and type(FirstPerson.pointBody) == "function" and FirstPerson.pointBody or nil
  local fpDriving = fpDrivingFn and fpDrivingFn() == true or false

  local aNow = inputDown(input, "a")
  local aPressed = aNow and not excursion.prevA
  excursion.prevA = aNow
  if aPressed then
    -- Match Johto's first-person interaction rule: when the camera is the
    -- player's head, A targets the cardinal nearest the live look direction,
    -- even if the body was standing still after a strafe.
    if fpDriving and fpMoveWorld then
      local lx, lz = fpMoveWorld(0, 1)
      local lookDir = directionFromWorldVector(lx, lz)
      if lookDir then excursion.facing = lookDir end
    end
    if interactExcursion(world) then return true end
  end

  -- EXACT Johto movement contract: 1ST/3RD PERSON gets a continuous circular
  -- body with analog magnitude + diagonal travel.  Surf remains on the native
  -- grid, matching GoldCameraControls' own special-state handoff. DIORAMA also
  -- remains ordinary grid movement.
  if not excursion.surfing and fpDriving and fpMoveVector and fpMoveWorld then
    local mx, mz = fpMoveVector()
    local worldX, worldZ = fpMoveWorld(mx or 0, mz or 0)
    local intentDir = directionFromWorldVector(worldX, worldZ)
    intentDir, worldX, worldZ = KantoGameplay.cyclingRoadIntent(
      excursion.region, excursion.sourceMapId, input, intentDir, worldX, worldZ)
    return tickDirectionalBody(world, dt, worldX, worldZ)
  end

  clearDirectionalBody(true)
  excursion.drawPx, excursion.drawPy = excursion.cellX * 16, excursion.cellY * 16
  local dir
  local worldX, worldZ = 0, 0
  if fpDriving and fpMoveVector and fpMoveWorld then
    -- Surf/special mode: same as Johto, camera-relative intent quantized only
    -- for the native grid mover.
    local mx, mz = fpMoveVector()
    worldX, worldZ = fpMoveWorld(mx or 0, mz or 0)
    dir = directionFromWorldVector(worldX, worldZ)
  else
    if inputDown(input, "up") then dir = "up"; worldZ = -1
    elseif inputDown(input, "down") then dir = "down"; worldZ = 1
    elseif inputDown(input, "left") then dir = "left"; worldX = -1
    elseif inputDown(input, "right") then dir = "right"; worldX = 1 end
  end
  -- JoypadOverworld: idle bike gets simulated PAD_DOWN; held A/B brakes,
  -- while a real held direction wins. Shared with 1ST/3RD PERSON above.
  dir, worldX, worldZ = KantoGameplay.cyclingRoadIntent(
    excursion.region, excursion.sourceMapId, input, dir, worldX, worldZ)
  if not dir then
    excursion.lastWorldX, excursion.lastWorldZ = 0, 0
    return true
  end
  excursion.lastWorldX, excursion.lastWorldZ = worldX, worldZ
  if fpPointBody and (math.abs(worldX) > 1e-5 or math.abs(worldZ) > 1e-5) then
    excursion.facing = fpPointBody(worldX, worldZ) or dir
  else
    excursion.facing = dir
  end
  if startLedgeHop(world, dir) then return true end
  local mapId, tx, ty = moveCandidate(excursion.region, excursion.sourceMapId,
    excursion.cellX, excursion.cellY, dir, world)
  if not mapId then
    local currentMap = ensureForeignMap(excursion.region, excursion.sourceMapId)
    local ntx, nty = targetCell(excursion.cellX, excursion.cellY, dir)
    local mode = currentMap and not currentMap:inBounds(ntx, nty) and "edge" or "collision"
    if applyWarp(excursion.region, excursion.sourceMapId,
        excursion.cellX, excursion.cellY, mode, dir) then
      return true
    end
    return true
  end

  excursion.fromPx, excursion.fromPy = excursion.drawPx, excursion.drawPy
  if mapId == excursion.sourceMapId then
    excursion.toPx, excursion.toPy = tx * 16, ty * 16
  else
    local dx, dy = 0, 0
    if dir == "left" then dx = -16 elseif dir == "right" then dx = 16
    elseif dir == "up" then dy = -16 elseif dir == "down" then dy = 16 end
    excursion.toPx, excursion.toPy = excursion.fromPx + dx, excursion.fromPy + dy
  end
  excursion.toMapId, excursion.toCellX, excursion.toCellY = mapId, tx, ty
  excursion.moveDurationCurrent = KantoGameplay.bikeStepDuration(
    excursion.region, excursion.sourceMapId, dir)
  excursion.hopActive, excursion.hopProgress, excursion.hopLift, excursion.hopSeam = false, 0, 0, false
  excursion.moveT = 0
  excursion.moving = true
  return true
end

Twin._moveCandidate = moveCandidate
Twin._resolveWarp = resolveWarp
Twin._resolveDungeonHole = resolveDungeonHole
Twin._applyDungeonHole = applyDungeonHole
Twin._afterExcursionCellLanding = afterExcursionCellLanding
Twin._finishExcursionStep = finishExcursionStep
Twin._directionStillHeld = directionStillHeld
Twin._kantoEvent = KantoState.event
Twin._setKantoEvent = KantoState.setEvent
Twin._kantoItemHeld = KantoState.itemHeld
Twin._giveKantoLocalItem = KantoState.giveLocalItem
Twin._takeKantoLocalItem = KantoState.takeLocalItem
Twin._ensureKantoLocalItem = KantoGameplay.ensureKantoLocalItem
Twin._pickupYellowItem = pickupYellowItem
Twin._takeMtMoonFossil = KantoGameplay.takeMtMoonFossil
Twin._kantoFossilLabState = KantoGameplay.fossilLabState
Twin._kantoFossilScientist = KantoGameplay.fossilScientist
Twin._markKantoFossilReady = KantoGameplay.markFossilReadyOnMapEntry
Twin._kantoItemGateForStep = KantoGameplay.itemGateForStep
Twin._kantoAfterQuestTrainerWin = KantoGameplay.afterQuestTrainerWin
Twin._kantoRocketElevator = KantoGameplay.rocketElevator
Twin._kantoTransferToWarp = KantoGameplay.transferToWarp
Twin._kantoRocketHideoutDuoStep = KantoGameplay.rocketHideoutDuoStep
Twin._kantoTowerMarowakStep = KantoGameplay.towerMarowakStep
Twin._kantoTowerRocketStep = KantoGameplay.towerRocketStep
Twin._kantoRescueMrFuji = KantoGameplay.rescueMrFuji
Twin._kantoMrFujiFlute = KantoGameplay.mrFujiFlute
Twin._kantoSnorlaxInteraction = KantoGameplay.snorlaxInteraction
Twin._closedDoorRows = KantoState.closedDoorRows
Twin._applyPhysicalBlocks = KantoState.applyPhysicalBlocks
Twin._restampClosedDoors = KantoState.restampClosedDoors
Twin._trashPuzzle = KantoState.trashPuzzle
Twin._rollTrashFirst = KantoState.rollTrashFirst
Twin._pickTrashSecond = KantoState.pickTrashSecond
Twin._onKantoMapEntered = KantoState.onMapEntered
Twin._forcedMovement = KantoGameplay.forcedMovement
Twin._isCyclingSlopeMap = KantoGameplay.isSlopeMap
Twin._forcedBikeTile = KantoGameplay.forcedBikeTile
Twin._syncForcedBike = KantoGameplay.syncForcedBike
Twin._bikeAllowed = KantoGameplay.bikeAllowed
Twin._toggleBicycle = KantoGameplay.toggleBicycle
Twin._pairBlocked = KantoState.pairBlocked
Twin._bikeStepDuration = KantoGameplay.bikeStepDuration
Twin._cyclingRoadIntent = KantoGameplay.cyclingRoadIntent
Twin._resetKantoStateCacheForTest = KantoState.clearPersistenceCache
Twin._tickDirectionalBody = tickDirectionalBody
Twin._clearDirectionalBody = clearDirectionalBody
Twin._adoptDirectionalBody = adoptDirectionalBody
Twin._civicForTest = KantoState.Civic
Twin._excursionForTest = excursion

local function recoverExcursionToPallet(reason)
  local region = excursion.region
  local cx, cy, rec = region and Twin._palletStart(region)
  if not (cx and cy and rec) then return false end
  excursion.sourceMapId = "PALLET_TOWN"
  KantoState.onMapEntered(region, "PALLET_TOWN")
  excursion.cellX, excursion.cellY = cx, cy
  excursion.drawPx, excursion.drawPy = cx * 16, cy * 16
  excursion.toMapId, excursion.toCellX, excursion.toCellY = nil, nil, nil
  excursion.moving = false
  excursion.moveT = 0
  excursion.moveDurationCurrent = nil
  excursion.hopActive, excursion.hopProgress, excursion.hopLift, excursion.hopSeam = false, 0, 0, false
  clearDirectionalBody(false)
  Twin._clearWarpIgnore()
  excursion.randomEncountersEnabled = nil
  excursion.biking, excursion.forcedBike = false, false
  excursion.lastOutside = { id = "PALLET_TOWN", x = cx, y = cy }
  excursion.standingOnWarp = false
  excursion.currentRecord = rec
  excursion.lastInteraction = reason and ("RECOVER: " .. tostring(reason)) or "RECOVER"
  Twin.kantoWarpRecoveries = (Twin.kantoWarpRecoveries or 0) + 1
  Twin.excursionSourceMap = "PALLET_TOWN"
  Twin.excursionCellX, Twin.excursionCellY = cx, cy
  return true
end

function Twin.recoverKanto()
  if not excursion.active then return false, "Kanto excursion is not active" end
  if recoverExcursionToPallet("manual") then return true end
  return false, "Pallet Town recovery tile unavailable"
end

local function makePlayerProxy(world)
  local source = world and world.player
  if not source then return nil end
  local proxy = excursion.playerProxy
  if not proxy or proxy._stadiumSourcePlayer ~= source then
    proxy = { _stadiumSourcePlayer = source, _stadiumGen1Excursion = true }
    setmetatable(proxy, { __index = function(_, key) return source[key] end })
    function proxy:walkPhase()
      if not self.moving then return 0 end
      -- Match Gold's native Gen-2 walk-phase contract exactly. Player:walkPhase
      -- returns ONLY 0/1 from the 16-frame animClock; the old excursion proxy
      -- returned 1/2, which looked acceptable in DIORAMA's stock card but made
      -- third-person/custom-player renderers interpret half the cycle as an
      -- unsupported/idle phase.
      local clock = (tonumber(self.animClock) or 0) % 16
      return (clock >= 4 and clock < 12) and 1 or 0
    end
    function proxy:pose()
      return self.sprite, self.px, self.py + (self.spriteYOffset or 0),
        self.facing or "down", self:walkPhase(), self.stepFlip == true, self.hopping == true
    end
    excursion.playerProxy = proxy
  end
  return proxy
end

-- Resolve the visible Kanto trainer card only when one of its real identity
-- inputs changes. The old path re-entered npcSpriteFor() at presentation FPS,
-- rebuilding palette/cache-key strings even though map/bike/palette/custom-skin
-- state normally remains stable for hundreds of frames.
function Twin._updateKantoProxySprite(world, region, mapId, proxy, customSprite)
  if not (world and world.player and proxy) then return nil, false end
  local sourceSprite = world.player.sprite
  local paletteKey = region and region.goldPaletteKey
  local bikeSprite = excursion.biking == true
  if proxy._stadiumSpriteMap == mapId and proxy._stadiumSpriteBike == bikeSprite
      and proxy._stadiumSpritePalette == paletteKey
      and proxy._stadiumSpriteCustom == (customSprite == true)
      and proxy._stadiumSpriteSource == sourceSprite then
    Twin.kantoProxySpriteCacheHits = (Twin.kantoProxySpriteCacheHits or 0) + 1
    return proxy.sprite, true
  end

  -- v0.3.78: the visible Kanto player is the native Gold player card, not a
  -- Yellow RED sheet recolored through Kanto's map palette.  The latter made
  -- the player share the same cream/olive family as walls and ground, which is
  -- exactly the screenshot clue that the color pipeline was conceptually
  -- wrong.  Reusing Gold's live SpriteRenderer also reuses PAL_OW_RED and the
  -- active time-of-day/color-mode object palette verbatim.  Kanto world color
  -- projection is now BG-only; character color stays character color.
  if sourceSprite then
    proxy.sprite = sourceSprite
  elseif customSprite ~= true then
    -- Old/import-incomplete host fallback only: if Gold has no player card at
    -- all, retain the historical Yellow sheet rather than drawing nothing.
    local field = region and region.loaded and region.loaded.field
    local cards = field and field.playerSprites or {}
    local spriteId = bikeSprite and (cards.bike or "SPRITE_RED_BIKE") or "SPRITE_RED"
    proxy.sprite = npcSpriteFor(region, mapId, spriteId)
      or npcSpriteFor(region, mapId, "SPRITE_RED")
  end
  proxy._stadiumSpriteMap, proxy._stadiumSpriteBike = mapId, bikeSprite
  proxy._stadiumSpritePalette, proxy._stadiumSpriteCustom = paletteKey, customSprite == true
  proxy._stadiumSpriteSource = sourceSprite
  Twin.kantoProxySpriteCacheMisses = (Twin.kantoProxySpriteCacheMisses or 0) + 1
  return proxy.sprite, false
end

local function neighborActorMapNearPlayer(nb, actorCells)
  if actorCells == math.huge then return true end
  local def = nb and nb.map and nb.map.def
  if not def then return false end
  local limit = math.max(0, tonumber(actorCells) or 0) * 16
  local px, py = tonumber(excursion.drawPx) or 0, tonumber(excursion.drawPy) or 0
  local x1, y1 = tonumber(nb.ox) or 0, tonumber(nb.oy) or 0
  local x2 = x1 + (tonumber(def.width) or 0) * 32
  local y2 = y1 + (tonumber(def.height) or 0) * 32
  local dx = px < x1 and x1 - px or (px > x2 and px - x2 or 0)
  local dy = py < y1 and y1 - py or (py > y2 and py - y2 or 0)
  return dx <= limit and dy <= limit
end

local function kantoPrefetchFor(rec, rootMap)
  local depth = tonumber(rec and rec.depth) or 99
  if depth <= 1 then return true end
  if depth > 2 then return false end
  local wx, wz = tonumber(excursion.lastWorldX) or 0, tonumber(excursion.lastWorldZ) or 0
  local mag = math.sqrt(wx * wx + wz * wz)
  if mag < 0.15 then return false end
  local def = rec and rec.map and rec.map.def
  local rdef = rootMap and rootMap.def
  if not (def and rdef) then return false end
  local dx = (tonumber(rec.ox) or 0) + (tonumber(def.width) or 0) * 16
    - (tonumber(rdef.width) or 0) * 16
  local dz = (tonumber(rec.oy) or 0) + (tonumber(def.height) or 0) * 16
    - (tonumber(rdef.height) or 0) * 16
  local dmag = math.sqrt(dx * dx + dz * dz)
  if dmag < 1 then return false end
  return (dx / dmag) * (wx / mag) + (dz / dmag) * (wz / mag) > 0.30
end

local function kantoUrgentFor(rec, map)
  if (tonumber(rec and rec.depth) or 99) > 1 then return false end
  local margin = 5
  local dir = rec and rec.dir
  local cx, cy = excursion.cellX, excursion.cellY
  local w = map and map.widthCells or 0
  local h = map and map.heightCells or 0
  if dir == "west" then return cx <= margin end
  if dir == "east" then return cx >= w - 1 - margin end
  if dir == "north" then return cy <= margin end
  if dir == "south" then return cy >= h - 1 - margin end
  return false
end

Twin._neighborActorMapNearPlayer = neighborActorMapNearPlayer
Twin._kantoPrefetchFor = kantoPrefetchFor

-- v0.3.66: v0.3.65 made the connected-neighbor DESCRIPTORS persistent,
-- but still recalculated every descriptor's seam urgency and directional
-- prefetch flag at presentation FPS. Those flags depend only on completed
-- player cell + world travel vector. Skip the loop when those exact scalar
-- inputs are unchanged, and use the per-descriptor normalized direction that
-- was precomputed when the neighbor view was built.
function Twin._refreshKantoNeighborDynamics(frameCache, neighbors, map)
  local wx, wz = tonumber(excursion.lastWorldX) or 0, tonumber(excursion.lastWorldZ) or 0
  if KantoState.FrameCache.neighborDynamics(frameCache, excursion.cellX, excursion.cellY, wx, wz) then
    Twin.kantoNeighborDynamicSkips = (Twin.kantoNeighborDynamicSkips or 0) + 1
    Twin.kantoPrefetchMaps = (Twin.kantoPrefetchMaps or 0)
      + (tonumber(frameCache and frameCache.neighborPrefetchCount) or 0)
    return false
  end

  local mag = math.sqrt(wx * wx + wz * wz)
  local moveX, moveZ
  if mag >= 0.15 then moveX, moveZ = wx / mag, wz / mag end
  local cx, cy = excursion.cellX, excursion.cellY
  local w = map and map.widthCells or 0
  local h = map and map.heightCells or 0
  local prefetchCount = 0
  for i = 1, #(neighbors or {}) do
    local nb = neighbors[i]
    local depth = tonumber(nb and nb.depth) or 99
    local prefetch = depth <= 1
    if not prefetch and depth <= 2 and moveX then
      -- Hot-reload/back-compat safety: a descriptor created by an older module
      -- instance may not carry v0.3.66's precomputed vector yet. Derive it
      -- once here rather than changing directional-prefetch semantics.
      if nb._stadiumPrefetchNX == nil or nb._stadiumPrefetchNZ == nil then
        local def = nb.map and nb.map.def
        local rdef = map and map.def
        if def and rdef then
          local dx = (tonumber(nb.ox) or 0) + (tonumber(def.width) or 0) * 16
            - (tonumber(rdef.width) or 0) * 16
          local dz = (tonumber(nb.oy) or 0) + (tonumber(def.height) or 0) * 16
            - (tonumber(rdef.height) or 0) * 16
          local dmag = math.sqrt(dx * dx + dz * dz)
          if dmag >= 1 then
            nb._stadiumPrefetchNX, nb._stadiumPrefetchNZ = dx / dmag, dz / dmag
          end
        end
      end
      if nb._stadiumPrefetchNX ~= nil and nb._stadiumPrefetchNZ ~= nil then
        prefetch = nb._stadiumPrefetchNX * moveX + nb._stadiumPrefetchNZ * moveZ > 0.30
      end
    end

    local urgent = false
    if depth <= 1 then
      local dir = nb and nb.dir
      if dir == "west" then urgent = cx <= 5
      elseif dir == "east" then urgent = cx >= w - 6
      elseif dir == "north" then urgent = cy <= 5
      elseif dir == "south" then urgent = cy >= h - 6 end
    end
    nb.urgent, nb.prefetch = urgent, prefetch
    if prefetch then prefetchCount = prefetchCount + 1 end
  end
  if frameCache then frameCache.neighborPrefetchCount = prefetchCount end
  Twin.kantoPrefetchMaps = (Twin.kantoPrefetchMaps or 0) + prefetchCount
  Twin.kantoNeighborDynamicRefreshes = (Twin.kantoNeighborDynamicRefreshes or 0) + 1
  return true
end

function Twin.excursionState(world)
  if not excursion.active then return nil end
  local region = excursion.region or ensureRegion()
  if not region then return nil, Twin.lastError end
  excursion.region = region
  syncGoldPalette(region, world)
  Twin.tickExcursion(world)
  -- tickExcursion already checks the Gold overlay before accepting input/NPC AI
  -- on ordinary frames. Reuse that result for cache-warm pacing instead of
  -- calling the protected stack probe two or three times in the same frame.
  local covered = excursion.overlayCovered
  if covered == nil then
    covered = overlayOpen(world)
    excursion.overlayCovered = covered
  end

  local mapId = excursion.sourceMapId or "PALLET_TOWN"
  local map = ensureForeignMap(region, mapId)
  local darkMap = KantoGameplay.isDarkMap(region, mapId)
  if not darkMap then excursion.flashActive = false end
  local invalidCurrent = not map or not map:inBounds(excursion.cellX, excursion.cellY)
  if not invalidCurrent and mapId == "PALLET_TOWN" then
    invalidCurrent = not Twin._palletCellSafe(region, map, excursion.cellX, excursion.cellY)
  end
  if invalidCurrent then
    if recoverExcursionToPallet(not map and ("missing map " .. tostring(mapId))
        or ("invalid/authored-border cell " .. tostring(mapId))) then
      mapId = excursion.sourceMapId
      map = ensureForeignMap(region, mapId)
    end
  end
  if not map then return nil, "Pokemon Yellow map unavailable: " .. tostring(mapId) end
  local outdoor = region.validOutdoor[mapId] == true
  local rootRec = outdoor and recordBySource(region, mapId) or nil
  excursion.currentRecord = rootRec

  local proxy = makePlayerProxy(world)
  if not proxy then return nil, "Gold player proxy unavailable" end
  -- The normal Kanto excursion deliberately uses Red's Yellow-era card, but
  -- an explicitly imported custom trainer should follow the player across the
  -- region seam too. The Johto player already owns the custom SpriteRenderer,
  -- so reusing that object keeps the exact same dimensions/poses and does not
  -- create a second texture cache.
  local customSprite = customPlayerSpriteActive()
  Twin._updateKantoProxySprite(world, region, mapId, proxy, customSprite)
  proxy.px, proxy.py = excursion.drawPx, excursion.drawPy
  proxy.cellX, proxy.cellY = excursion.cellX, excursion.cellY
  proxy.facing = excursion.facing
  proxy.moving = excursion.moving or excursion.freeVisualMoving == true
  proxy.surfing = excursion.surfing == true
  proxy.onBike = excursion.biking == true
  proxy.biking = excursion.biking == true
  -- The proxy falls back to the hidden Johto player through __index.  Fishing
  -- is not a persistent Kanto locomotion mode, so pin it false explicitly or a
  -- Johto fishing animation can leak through and suppress the Kanto 3D player.
  proxy.fishing = false
  proxy.stepFlip = excursion.stepFlip
  proxy.animClock = excursion.animClock or 0
  proxy._stadiumMoveWorldX = excursion.lastWorldX or 0
  proxy._stadiumMoveWorldZ = excursion.lastWorldZ or 0
  proxy.spriteYOffset = -(tonumber(excursion.hopLift) or 0)
  proxy.hopping = excursion.hopActive == true
  proxy.jumping = proxy.hopping
  proxy.hopFrames = proxy.hopping and math.max(1, math.ceil((1 - (excursion.hopProgress or 0)) * 32)) or nil

  -- Kanto uses the same re-rooted connected-sector streamer as Gold.  The
  -- graphics preset only changes how many rings are PREFETCHED; crossing any
  -- seam immediately prepares the new root, so no setting removes a map.
  -- v0.3.58 reuses the render-state arrays/records instead of allocating them
  -- at presentation FPS. This changes no culling or quality rule; it only
  -- removes steady-state Lua garbage and the GC spikes that came with it.
  local frameCache = KantoState.FrameCache.ensure(excursion)
  local sectorRadius = Quality.kantoRadius()
  local kantoOpenWorld = outdoor and Twin.openWorldEnabled() == true
  local sector, openPrepared, openTotal
  if outdoor then
    if kantoOpenWorld then
      sector, openPrepared, openTotal = Twin._openWorldRecords(region, mapId)
    else
      sector = sectorRecords(region, mapId, sectorRadius)
      openPrepared, openTotal = 0, 0
    end
  end
  -- The open-world active list grows progressively while distant maps decode.
  -- Include its prepared count in the view identity so FrameCache rebuilds the
  -- reusable neighbour array exactly when another map joins, not every frame.
  local neighborViewKey = kantoOpenWorld
    and ("open:" .. tostring(openPrepared or 0) .. "/" .. tostring(openTotal or 0))
    or sectorRadius
  local neighborHit, neighbors, directNeighbors = KantoState.FrameCache.neighborView(
    frameCache, mapId, neighborViewKey, sector)
  if not neighborHit and outdoor then
    for _, rec in ipairs(sector) do
      local ni = #neighbors + 1
      local nb = KantoState.FrameCache.record(frameCache, "neighborPool", ni, "neighbor")
      nb.id, nb.map, nb.ox, nb.oy = rec.id, rec.map, rec.ox, rec.oy
      nb.depth, nb.foreignRegion = rec.depth, "yellow"
      nb.parentId, nb.dir = map.id, rec.dir or "connected"
      -- Second-ring directional prefetch used to normalize this immutable
      -- root-to-neighbor vector every presentation frame. Cache it once with
      -- the descriptor; record() scrubs it automatically when the pool slot is
      -- reused for a different connected view.
      if (tonumber(nb.depth) or 99) == 2 and nb.map and nb.map.def and map.def then
        local dx = (tonumber(nb.ox) or 0) + (tonumber(nb.map.def.width) or 0) * 16
          - (tonumber(map.def.width) or 0) * 16
        local dz = (tonumber(nb.oy) or 0) + (tonumber(nb.map.def.height) or 0) * 16
          - (tonumber(map.def.height) or 0) * 16
        local dmag = math.sqrt(dx * dx + dz * dz)
        if dmag >= 1 then
          nb._stadiumPrefetchNX, nb._stadiumPrefetchNZ = dx / dmag, dz / dmag
        end
      end
      neighbors[ni] = nb
      if (tonumber(nb.depth) or 99) <= 1 then directNeighbors[#directNeighbors + 1] = nb end
    end
    KantoState.FrameCache.trimPool(frameCache, "neighborPool", #neighbors)
  elseif not neighborHit then
    KantoState.FrameCache.trimPool(frameCache, "neighborPool", 0)
  end
  -- Only these two flags depend on live movement/cell position. v0.3.66 also
  -- keeps that dynamic result until those exact scalar inputs change, so idle
  -- and steady-direction 60/120-Hz frames do not walk the connected list.
  Twin._refreshKantoNeighborDynamics(frameCache, neighbors, map)
  Twin.kantoSectorMaps = #neighbors + 1
  scheduleKantoDiskWarm(region, map, neighbors, covered)

  local npcs, mons = entitiesForMap(region, mapId)
  local actorCells = Quality.actorDistanceCells()
  local actorHit, entities, ghosts, drawnNpcs, drawnMons = KantoState.FrameCache.actorView(
    frameCache, mapId, excursion.cellX, excursion.cellY, actorCells, sectorRadius,
    tonumber(region.actorGeneration) or 0)
  if actorHit then
    -- GoldVoxelBridge may append presentation-only ambient flyers to this
    -- reusable array after excursionState returns.  Strip those tail entries
    -- before reusing the cached base actor view on the next frame.
    local baseCount = 1 + (tonumber(drawnNpcs) or 0) + (tonumber(drawnMons) or 0)
    for i = #entities, baseCount + 1, -1 do entities[i] = nil end
  end
  entities[1] = proxy

  if not actorHit then
    drawnNpcs, drawnMons = 0, 0
    for _, e in ipairs(npcs) do
      if KantoState.FrameCache.localActorVisible(e, excursion.cellX, excursion.cellY, actorCells) then
        entities[#entities + 1] = e; drawnNpcs = drawnNpcs + 1
      end
    end
    for _, e in ipairs(mons) do
      if KantoState.FrameCache.localActorVisible(e, excursion.cellX, excursion.cellY, actorCells) then
        entities[#entities + 1] = e; drawnMons = drawnMons + 1
      end
    end

    -- The current-map prefilter is exactly cell-based. Neighbor filtering used
    -- sub-cell player pixels in older releases, so cache one extra candidate
    -- cell on each side. VoxelScene's camera-space actor cull remains final and
    -- exact; the safety margin only guarantees a cached candidate set cannot
    -- omit an actor while the player traverses the current 16px cell.
    local candidateCells = actorCells == math.huge and math.huge or actorCells + 1
    for _, nb in ipairs(neighbors) do
      if nb.depth <= sectorRadius then
        local sid = nb.map and nb.map.sourceId
        if sid and neighborActorMapNearPlayer(nb, candidateCells) then
          local nn, nm = entitiesForMap(region, sid)
          for _, e in ipairs(nn) do
            if KantoState.FrameCache.neighborActorVisible(e, nb.ox, nb.oy,
                excursion.drawPx, excursion.drawPy, candidateCells) then
              local gi = #ghosts + 1
              local g = KantoState.FrameCache.record(frameCache, "ghostPool", gi, "ghost")
              g.npc, g.map, g.ox, g.oy = e, nb.map, nb.ox, nb.oy
              ghosts[gi] = g
            end
          end
          -- Directly connected maps keep their roaming Pokemon visible across
          -- the seam. Second-ring Pokemon are omitted to keep Stadium rig count
          -- bounded while the terrain itself still streams two hops.
          if nb.depth <= 1 then
            for _, e in ipairs(nm) do
              if KantoState.FrameCache.neighborActorVisible(e, nb.ox, nb.oy,
                  excursion.drawPx, excursion.drawPy, candidateCells) then
                local gi = #ghosts + 1
                local g = KantoState.FrameCache.record(frameCache, "ghostPool", gi, "ghost")
                g.npc, g.map, g.ox, g.oy = e, nb.map, nb.ox, nb.oy
                ghosts[gi] = g
              end
            end
          end
        elseif sid then
          Twin.kantoActorMapSkips = (Twin.kantoActorMapSkips or 0) + 1
        end
      end
    end
    KantoState.FrameCache.setActorViewCounts(frameCache, drawnNpcs, drawnMons)
    KantoState.FrameCache.trimPool(frameCache, "ghostPool", #ghosts)
  end

  Twin.kantoNpcs, Twin.kantoPokemon = #npcs, #mons
  Twin.kantoNpcsDrawn, Twin.kantoPokemonDrawn = drawnNpcs, drawnMons

  -- Do NOT bake the Game Boy 160x144 half-size (80/72) into this camera.
  -- GoldVoxelBridge knows the actual logical voxel viewport only after it has
  -- built the render state. v0.3.40 used -80/-72 here, then VoxelScene added
  -- vw/2,vh/2; at 1024-wide desktop coverage that shifted the scene centre
  -- 432px east, almost exactly one Pallet body into the border-tree apron.
  -- centerExcursionCamera() below applies the real half viewport immediately
  -- before VoxelScene.render(). Keep these values self-consistent for callers
  -- that inspect state before that final centering pass.
  excursion.cameraProxy.x = excursion.drawPx
  excursion.cameraProxy.y = excursion.drawPy
  local ocean = nil
  if outdoor then
    -- Ocean geometry depends only on the current stitched root/radius and the
    -- ocean option, not on per-frame actor/camera motion. Reuse the descriptor
    -- instead of rebuilding component bounds/rect/key tables every frame.
    local oceanEnabled = Twin.oceanEnabled()
    -- WORLD OCEAN follows the actual Kanto residency shape. In streamed mode
    -- it rings the local connected sector; with OPEN WORLD it expands as the
    -- whole Yellow graph becomes ready. The prepared-count key prevents a
    -- small first-frame coastline from being cached forever while maps load.
    local oceanScope = kantoOpenWorld
      and ("open:" .. tostring(#neighbors) .. "/" .. tostring(openTotal or 0))
      or ("sector:" .. tostring(sectorRadius))
    local oceanHit, cachedOcean = KantoState.FrameCache.ocean(
      frameCache, map.id, oceanScope, oceanEnabled)
    if oceanHit then
      ocean = cachedOcean
      Twin.oceanVisible = ocean ~= nil
      Twin.oceanRects = ocean and #ocean.rects or 0
    else
      frameCache.worldStub.map = map
      ocean = Twin.oceanDescriptor(frameCache.worldStub, neighbors)
      KantoState.FrameCache.setOcean(frameCache, map.id, oceanScope, oceanEnabled, ocean)
    end
  else
    Twin.oceanVisible, Twin.oceanRects = false, 0
  end

  Twin.excursionMap = map.id
  Twin.excursionSourceMap = mapId
  Twin.excursionCellX, Twin.excursionCellY = excursion.cellX, excursion.cellY
  local renderState = KantoState.FrameCache.state(frameCache)
  renderState.map, renderState.camera, renderState.player = map, excursion.cameraProxy, proxy
  renderState.entities, renderState.neighbors, renderState.ghosts = entities, neighbors, ghosts
  renderState._stadiumDirectNeighbors = directNeighbors
  renderState.flyAnim = nil
  -- Render-side movement contract mirrors Johto's true-directional bridge.
  -- GoldCameraControls still leaves the hidden Johto player alone while the
  -- excursion is active; these flags describe only the visible Kanto proxy.
  renderState._stadiumFreeMoveActive = true
  renderState._stadiumFreeVisualMoving = excursion.moving or excursion.freeVisualMoving == true
  renderState._stadiumFreeAnimDist = excursion.animDistance or 0
  renderState._stadiumFreeWorldX = excursion.lastWorldX or 0
  renderState._stadiumFreeWorldZ = excursion.lastWorldZ or 0
  renderState._stadiumOpenWorldNeighbors = kantoOpenWorld
  -- v0.3.42: Yellow outdoor maps share one stitched world-space with their
  -- connected bodies. Do not give every map its own synthetic 256px apron;
  -- those repeated border rings were the giant rock/tree fields between
  -- Pallet/routes/towns. VoxelScene renders BODY meshes for the whole Kanto
  -- component and lets neighbour bodies own every seam.
  renderState._stadiumSharedWorldBodies = outdoor
  renderState._stadiumOpenWorldMapCount = kantoOpenWorld and (#neighbors + 1) or 0
  renderState._stadiumKantoOpenWorldPrepared = openPrepared or 0
  renderState._stadiumKantoOpenWorldTotal = openTotal or 0
  renderState._stadiumOcean = ocean
  renderState._stadiumFrameScratch = frameCache.voxelScratch
  renderState._stadiumGen1Excursion = true
  renderState._stadiumYellowKanto = true
  renderState._stadiumDarkTint = darkMap and not excursion.flashActive
    and frameCache.darkTint or nil
  renderState._stadiumResidencyRegion = "kanto"
  return renderState
end

-- Final camera contract for the Kanto presentation proxy. `vw`/`vh` are the
-- logical world coverage VoxelScene will use this frame (not the output-canvas
-- pixel dimensions).  Keeping the desired scene centre separate from viewport
-- half-size makes the same Pallet cell render under the player at 160x144,
-- 1024x768, ultrawide, zoomed, or any future desktop resolution.
function Twin.centerExcursionCamera(state, vw, vh)
  if not (excursion.active and type(state) == "table" and state._stadiumYellowKanto == true) then
    return false
  end
  local cam = state.camera or excursion.cameraProxy
  local p = state.player
  vw, vh = tonumber(vw), tonumber(vh)
  local px = p and tonumber(p.px) or tonumber(excursion.drawPx)
  local py = p and tonumber(p.py) or tonumber(excursion.drawPy)
  if not (cam and vw and vh and vw > 0 and vh > 0 and px and py) then return false end
  cam.x = px - vw * 0.5
  cam.y = py - vh * 0.5
  excursion.cameraProxy.x, excursion.cameraProxy.y = cam.x, cam.y
  Twin.kantoCameraRecenters = (Twin.kantoCameraRecenters or 0) + 1
  Twin.kantoCameraCenterX, Twin.kantoCameraCenterY = px, py
  Twin.kantoCameraViewW, Twin.kantoCameraViewH = vw, vh
  return true
end

-- Test-only injection seam; it never runs in normal gameplay but lets the
-- regression driver exercise Pallet placement/movement without a copyrighted
-- ROM cache.
function Twin._setRegionCacheForTest(value)
  regionCache = value
  excursion.region = value
  regionAttemptAt = -math.huge
end

function Twin.regionRecords(world, goldNeighbors)
  Twin.regionVisible = false
  -- v0.3.31: Gold and Yellow Kanto are separate residency domains. While the
  -- player is in Johto, do not progressively materialize/render the foreign
  -- Yellow graph beside Gold. KANTO FREE ROAM activates its own sector streamer
  -- and RETURN TO JOHTO releases it again. This is the largest steady-state RAM
  -- and mesh-work reduction for phones.
  if not excursion.active then return {} end
  -- GEN-1 KANTO REGION is its own switch.  v0.2.82/83 accidentally made it
  -- conditional on OPEN WORLD as well, so turning the Kanto row ON by itself
  -- visibly did nothing.  GoldVoxelBridge now promotes residency to open-world
  -- automatically while this switch is enabled; no second toggle is required.
  if not Twin.gen1Enabled() then return {} end
  local region = ensureRegion()
  if not region then return {} end
  syncGoldPalette(region, world)
  local gold = Twin._worldBounds(world and world.map, goldNeighbors)
  if not gold then return {} end

  local rw = region.bounds.x2 - region.bounds.x1
  local rh = region.bounds.y2 - region.bounds.y1
  local baseX, baseY = Twin._regionBase(gold, region.bounds)
  -- Prepare only a few never-seen Yellow maps per survey frame.  The graph is
  -- still complete; this converts the v0.2.85 one-frame 30+ atlas decode into
  -- progressive background streaming governed by MESH BUILD RATE.
  local batch = Quality.kantoSurveyBatch()
  local limit = Quality.kantoSurveyLimit(#region.records)
  local cursor = tonumber(region.surveyCursor) or 1
  local prepared, scanned = 0, 0
  while prepared < batch and scanned < #region.records
      and (region.surveyPrepared or 0) < limit do
    if cursor > #region.records then cursor = 1 end
    local rec = region.records[cursor]
    cursor = cursor + 1
    scanned = scanned + 1
    if rec and not rec.map then
      rec.map = ensureForeignMap(region, rec.sourceId)
      if rec.map then
        region.surveyPrepared = (region.surveyPrepared or 0) + 1
        prepared = prepared + 1
      end
    end
  end
  region.surveyCursor = cursor
  region.surveyLimit = limit

  local out = {}
  for _, rec in ipairs(region.records) do
    if rec.map then
      out[#out + 1] = {
        id = rec.id, map = rec.map,
        ox = baseX + rec.ox, oy = baseY + rec.oy,
        depth = 50 + (tonumber(rec.depth) or 0),
        parentId = "__GEN1_REGION__", dir = "east",
        urgent = false, foreignRegion = "yellow",
      }
    end
  end
  Twin.regionVisible = #out > 0
  Twin.regionMaps = #out
  Twin.regionX = baseX
  Twin.regionY = baseY
  Twin.regionWidth = rw
  Twin.regionHeight = rh
  return out
end

local function makeOceanTexture()
  if oceanTexture then return oceanTexture end
  if not (love and love.image and love.image.newImageData
      and love.graphics and love.graphics.newImage) then return nil end
  local ok, image = pcall(function()
    local data = love.image.newImageData(16, 16)
    for y = 0, 15 do
      for x = 0, 15 do
        local wave = ((math.floor((x + y * 2) / 4) + math.floor(y / 3)) % 2)
        local r = wave == 0 and 0.10 or 0.13
        local g = wave == 0 and 0.39 or 0.46
        local b = wave == 0 and 0.70 or 0.78
        data:setPixel(x, y, r, g, b, 1)
      end
    end
    local img = love.graphics.newImage(data)
    if img.setWrap then img:setWrap("repeat", "repeat") end
    if img.setFilter then img:setFilter("nearest", "nearest") end
    return img
  end)
  oceanTexture = ok and image or false
  return oceanTexture or nil
end

local function componentBounds(rootMap, neighbors)
  if not (rootMap and rootMap.def) then return {} end
  local rootForeign = rootMap.sourceId ~= nil or tostring(rootMap.id or ""):find(Twin.PREFIX, 1, true) == 1
  local gold, yellow
  if rootForeign then yellow = rectFor(rootMap.def, 0, 0)
  else gold = rectFor(rootMap.def, 0, 0) end
  for _, nb in ipairs(neighbors or {}) do
    if nb.map and nb.map.def then
      local r = rectFor(nb.map.def, tonumber(nb.ox) or 0, tonumber(nb.oy) or 0)
      if nb.foreignRegion == "yellow" or nb.map.sourceId then
        yellow = extendBounds(yellow, r)
      else
        gold = extendBounds(gold, r)
      end
    end
  end
  local out = {}
  if gold then out[#out + 1] = gold end
  if yellow then out[#out + 1] = yellow end
  return out
end

local function oceanForComponents(components)
  if not components or #components == 0 then return nil end
  local rects = {}
  if #components == 1 then
    for _, r in ipairs(Twin._oceanRects(components[1])) do rects[#rects + 1] = r end
  else
    -- Treat Gold + Yellow as one archipelago envelope: four outer perimeter
    -- strips plus one sea channel between the horizontally separated land
    -- components. This avoids overlapping coplanar rings in the gap.
    local combined
    for _, bounds in ipairs(components) do combined = extendBounds(combined, bounds) end
    for _, r in ipairs(Twin._oceanRects(combined)) do rects[#rects + 1] = r end
    table.sort(components, function(a,b) return a.x1 < b.x1 end)
    for i = 1, #components - 1 do
      local a, b = components[i], components[i + 1]
      if b.x1 > a.x2 then
        rects[#rects + 1] = {
          x1 = a.x2, x2 = b.x1,
          y1 = math.min(a.y1, b.y1), y2 = math.max(a.y2, b.y2),
        }
      end
    end
  end
  if #rects == 0 then return nil end
  local parts = {}
  for _, r in ipairs(rects) do
    parts[#parts + 1] = table.concat({r.x1,r.y1,r.x2,r.y2}, ",")
  end
  local key = table.concat(parts, ";")
  if oceanMeshKey ~= key then
    if oceanMesh and oceanMesh.release then pcall(oceanMesh.release, oceanMesh) end
    oceanMesh = nil
    oceanMeshKey = key
    local Voxel3D = V.require("Voxel3D")
    local verts, inds = {}, {}
    for _, r in ipairs(rects) do
      local base = #verts
      local tw, th = math.max(1, (r.x2-r.x1)/16), math.max(1, (r.y2-r.y1)/16)
      verts[#verts+1] = {r.x1, Twin.OCEAN_Y, r.y1, 0, 0, 1}
      verts[#verts+1] = {r.x2, Twin.OCEAN_Y, r.y1, tw, 0, 1}
      verts[#verts+1] = {r.x2, Twin.OCEAN_Y, r.y2, tw, th, 1}
      verts[#verts+1] = {r.x1, Twin.OCEAN_Y, r.y2, 0, th, 1}
      inds[#inds+1], inds[#inds+2], inds[#inds+3] = base+1,base+2,base+3
      inds[#inds+1], inds[#inds+2], inds[#inds+3] = base+1,base+3,base+4
    end
    oceanMesh = Voxel3D.newMesh(verts, inds)
  end
  local tex = makeOceanTexture()
  if not (oceanMesh and tex) then return nil end
  local all
  for _, r in ipairs(rects) do all = extendBounds(all, r) end
  return { mesh=oceanMesh, texture=tex, model=nil, rects=rects, bounds=all,
           perimeterOnly=true }
end

function Twin.oceanDescriptor(world, neighbors)
  Twin.oceanVisible = false
  if not Twin.oceanEnabled() then return nil end
  local components = componentBounds(world and world.map, neighbors)
  local ocean = oceanForComponents(components)
  Twin.oceanVisible = ocean ~= nil
  Twin.oceanRects = ocean and #ocean.rects or 0
  return ocean
end

function Twin.invalidateRegion()
  if excursion.active then Twin.returnToJohto() end
  regionCache = nil
  regionAttemptAt = -math.huge
  Twin.cacheVersion = nil
  Twin.regionMaps = 0
  Twin.regionVisible = false
  Twin.lastError = nil
end

function Twin.invalidateOcean()
  KantoState.FrameCache.invalidateOcean(excursion)
  if oceanMesh and oceanMesh.release then pcall(oceanMesh.release, oceanMesh) end
  if oceanTexture and oceanTexture ~= false and oceanTexture.release then
    pcall(oceanTexture.release, oceanTexture)
  end
  oceanMesh, oceanMeshKey, oceanTexture = nil, nil, nil
  Twin.oceanVisible = false
end

function Twin.status()
  local Dialogue = V.require("KantoDialogue")
  local dialogueAudit = Twin.kantoDialogueAudit or {}
  return {
    oceanEnabled = Twin.oceanEnabled(),
    oceanVisible = Twin.oceanVisible == true,
    openWorldEnabled = Twin.openWorldEnabled(),
    kantoOpenWorldPrepared = Twin.kantoOpenWorldPrepared or 0,
    kantoOpenWorldTotal = Twin.kantoOpenWorldTotal or 0,
    gen1Enabled = Twin.gen1Enabled(),
    gen1Visible = Twin.regionVisible == true,
    gen1CacheVersion = Twin.cacheVersion,
    gen1Maps = Twin.regionMaps or 0,
    gen1X = Twin.regionX,
    gen1Y = Twin.regionY,
    gen1Width = Twin.regionWidth,
    gen1Height = Twin.regionHeight,
    regionGap = Twin.REGION_GAP,
    regionBuilds = Twin.regionBuilds or 0,
    atlasLoads = Twin.atlasLoads or 0,
    atlasFallbacks = Twin.atlasFallbacks or 0,
    cacheReads = Twin.cacheReads or 0,
    cachePrefixRestores = Twin.cachePrefixRestores or 0,
    mapAdapter = Twin.mapAdapter,
    excursionActive = excursion.active == true,
    excursionMap = Twin.excursionMap,
    excursionSourceMap = Twin.excursionSourceMap,
    excursionCellX = Twin.excursionCellX,
    excursionCellY = Twin.excursionCellY,
    excursionTeleports = Twin.excursionTeleports or 0,
    excursionReturns = Twin.excursionReturns or 0,
    excursionSteps = Twin.excursionSteps or 0,
    kantoNpcs = Twin.kantoNpcs or 0,
    kantoPokemon = Twin.kantoPokemon or 0,
    kantoNpcsDrawn = Twin.kantoNpcsDrawn or 0,
    kantoPokemonDrawn = Twin.kantoPokemonDrawn or 0,
    yellowTrainerBattles = Twin.yellowTrainerBattles or 0,
    yellowTrainerWins = Twin.yellowTrainerWins or 0,
    yellowGymBattles = Twin.yellowGymBattles or 0,
    yellowGymWins = Twin.yellowGymWins or 0,
    yellowBattleError = Twin.lastBattleError,
    kantoWarps = Twin.kantoWarps or 0,
    kantoConnections = Twin.kantoConnections or 0,
    kantoConnectionRepairs = Twin.kantoConnectionRepairs or 0,
    kantoConnectionWarnings = Twin.kantoConnectionWarnings or 0,
    kantoConnectionEdgeRejects = Twin.kantoConnectionEdgeRejects or 0,
    kantoWarpRecoveries = Twin.kantoWarpRecoveries or 0,
    kantoWarpFailures = Twin.kantoWarpFailures or 0,
    yellowExtraWarpArrivals = Twin.yellowExtraWarpArrivals or 0,
    yellowWarpPadTransitions = Twin.yellowWarpPadTransitions or 0,
    yellowWarpHoleTransitions = Twin.yellowWarpHoleTransitions or 0,
    yellowDungeonFalls = Twin.yellowDungeonFalls or 0,
    yellowLedgeHops = Twin.yellowLedgeHops or 0,
    yellowLedgeSeamHops = Twin.yellowLedgeSeamHops or 0,
    yellowPhysicalEvents = Twin.yellowPhysicalEvents or 0,
    yellowClosedDoorRestamps = Twin.yellowClosedDoorRestamps or 0,
    yellowCardKeyDoors = Twin.yellowCardKeyDoors or 0,
    yellowTrashSwitches = Twin.yellowTrashSwitches or 0,
    yellowTrashResets = Twin.yellowTrashResets or 0,
    yellowTrashDoorOpens = Twin.yellowTrashDoorOpens or 0,
    yellowForcedBikeMounts = Twin.yellowForcedBikeMounts or 0,
    yellowCyclingRoadRolls = Twin.yellowCyclingRoadRolls or 0,
    yellowCyclingRoadBrakes = Twin.yellowCyclingRoadBrakes or 0,
    yellowCyclingRoadBounces = Twin.yellowCyclingRoadBounces or 0,
    yellowPairCollisionBlocks = Twin.yellowPairCollisionBlocks or 0,
    yellowFreePairCollisionBlocks = Twin.yellowFreePairCollisionBlocks or 0,
    yellowBikeMounts = Twin.yellowBikeMounts or 0,
    yellowBikeDismounts = Twin.yellowBikeDismounts or 0,
    kantoFieldIndexBuilds = Twin.kantoFieldIndexBuilds or 0,
    yellowBiking = excursion.biking == true,
    yellowForcedBike = excursion.forcedBike == true,
    kantoStateCacheHits = Twin.kantoStateCacheHits or 0,
    kantoStateCacheLoads = Twin.kantoStateCacheLoads or 0,
    kantoBlockBatchRefreshes = Twin.kantoBlockBatchRefreshes or 0,
    kantoLastOutside = excursion.lastOutside and excursion.lastOutside.id or nil,
    kantoStandingOnWarp = excursion.standingOnWarp == true,
    kantoSectorMaps = Twin.kantoSectorMaps or 0,
    kantoSectorRadius = Quality.kantoRadius(),
    kantoSurveyPrepared = regionCache and regionCache.surveyPrepared or 0,
    kantoSurveyLimit = regionCache and regionCache.surveyLimit or 0,
    oceanRects = Twin.oceanRects or 0,
    kantoPalette = Twin.kantoPalette,
    kantoPaletteKey = regionCache and regionCache.goldPaletteKey or nil,
    kantoPaletteReference = regionCache and regionCache.goldPaletteReference or nil,
    kantoPaletteSyncs = Twin.kantoPaletteSyncs or 0,
    kantoRegionUnloads = Twin.kantoRegionUnloads or 0,
    kantoPrefetchMaps = Twin.kantoPrefetchMaps or 0,
    kantoNeighborDynamicSkips = Twin.kantoNeighborDynamicSkips or 0,
    kantoNeighborDynamicRefreshes = Twin.kantoNeighborDynamicRefreshes or 0,
    kantoNeighborDynamicCacheHits = KantoState.FrameCache.neighborDynamicHits or 0,
    kantoNeighborDynamicCacheMisses = KantoState.FrameCache.neighborDynamicMisses or 0,
    kantoProxySpriteCacheHits = Twin.kantoProxySpriteCacheHits or 0,
    kantoProxySpriteCacheMisses = Twin.kantoProxySpriteCacheMisses or 0,
    kantoCustomPlayerActiveProtectedCalls = Twin.kantoCustomPlayerActiveProtectedCalls or 0,
    kantoCustomPlayerActiveDirectCalls = Twin.kantoCustomPlayerActiveDirectCalls or 0,
    kantoCacheWarmVisibleOnly = Twin.kantoCacheWarmVisibleOnly or 0,
    kantoActorMapSkips = Twin.kantoActorMapSkips or 0,
    kantoFrameCacheFrames = KantoState.FrameCache.frames or 0,
    kantoFrameCacheReuses = KantoState.FrameCache.cacheReuses or 0,
    kantoFrameStateReuses = KantoState.FrameCache.stateReuses or 0,
    kantoFrameArrayReuses = KantoState.FrameCache.arrayReuses or 0,
    kantoFrameNeighborRecordReuses = KantoState.FrameCache.neighborRecordReuses or 0,
    kantoFrameGhostRecordReuses = KantoState.FrameCache.ghostRecordReuses or 0,
    kantoOceanCacheHits = KantoState.FrameCache.oceanHits or 0,
    kantoOceanCacheMisses = KantoState.FrameCache.oceanMisses or 0,
    kantoFrameCacheReleases = KantoState.FrameCache.releases or 0,
    kantoActorViewHits = KantoState.FrameCache.actorViewHits or 0,
    kantoActorViewMisses = KantoState.FrameCache.actorViewMisses or 0,
    kantoFramePoolTrims = KantoState.FrameCache.poolTrims or 0,
    kantoNpcSpatialBuilds = KantoState.Spatial.npcBuilds or 0,
    kantoPokemonSpatialBuilds = KantoState.Spatial.pokemonBuilds or 0,
    kantoNpcSpatialHits = KantoState.Spatial.npcHits or 0,
    kantoPokemonSpatialHits = KantoState.Spatial.pokemonHits or 0,
    kantoSpatialMoves = KantoState.Spatial.moves or 0,
    kantoNpcRoleBuilds = KantoState.Spatial.roleBuilds or 0,
    kantoNpcRoleHits = KantoState.Spatial.roleHits or 0,
    kantoNpcMovingAdds = KantoState.Spatial.movingAdds or 0,
    kantoNpcMovingRemoves = KantoState.Spatial.movingRemoves or 0,
    kantoActorGenerations = KantoState.Spatial.generations or 0,
    kantoPaletteExactTiles = Twin.kantoPaletteExactTiles or 0,
    kantoCacheWarmQueued = Twin.kantoCacheWarmQueued or 0,
    kantoCacheWarmHits = Twin.kantoCacheWarmHits or 0,
    kantoCacheWarmLive = Twin.kantoCacheWarmLive or 0,
    kantoCacheWarmCursor = Twin.kantoCacheWarmCursor or 0,
    kantoCacheWarmPending = (ChunkMesher and type(ChunkMesher.warmPending) == "function")
      and ChunkMesher.warmPending("kanto") or 0,
    kantoExactJohtoSlots = regionCache and regionCache.goldPaletteProfile ~= nil or false,
    kantoExactGen2Slots = regionCache and regionCache.goldPaletteProfile ~= nil or false,
    kantoTextureStyle = Twin.kantoTextureStyle,
    kantoTextureMatches = Twin.kantoTextureMatches or 0,
    kantoTextureDonor = regionCache and (regionCache.lastGen2Donor or regionCache.johtoTextureKey) or nil,
    kantoTextureDonorMap = regionCache and regionCache.lastGen2DonorMap or nil,
    kantoTextureDonorProfile = regionCache and regionCache.lastGen2DonorProfile or nil,
    kantoColorDonor = regionCache and regionCache.lastGen2ColorDonor or nil,
    kantoColorDonorMap = regionCache and regionCache.lastGen2ColorDonorMap or nil,
    kantoTrueDirectional = excursion.active and excursion.freeActive == true,
    kantoFreeFrames = Twin.kantoFreeFrames or 0,
    kantoFreeCellCrossings = Twin.kantoFreeCellCrossings or 0,
    kantoFreeWallSlides = Twin.kantoFreeWallSlides or 0,
    kantoPlayerFacing = excursion.facing,
    kantoCameraRelative = excursion.active and FirstPerson and FirstPerson.driving() or false,
    kantoPlayerAnimClock = excursion.animClock or 0,
    classicRandomEncounters = classicRandomEncountersEnabled(),
    yellowWildBattles = Twin.yellowWildBattles or 0,
    yellowWildWins = Twin.yellowWildWins or 0,
    yellowWildCatches = Twin.yellowWildCatches or 0,
    yellowSignsRead = Twin.yellowSignsRead or 0,
    yellowDialogueAsmHandled = Twin.yellowDialogueAsmHandled or 0,
    yellowDialogueRecovered = Twin.yellowDialogueRecovered or 0,
    yellowDialogueFallbacks = Twin.yellowDialogueFallbacks or 0,
    kantoDialogueNpcText = dialogueAudit.npcText or 0,
    kantoDialogueSignText = dialogueAudit.signText or 0,
    kantoDialogueAsm = dialogueAudit.asm or 0,
    kantoDialoguePlain = dialogueAudit.plain or 0,
    kantoDialogueServices = dialogueAudit.service or 0,
    kantoDialogueMissingPointer = dialogueAudit.missingPointer or 0,
    kantoDialogueGuaranteed = dialogueAudit.guaranteedInteractive or 0,
    kantoDialogueSessions = Dialogue and Dialogue.sessions or 0,
    kantoDialogueHandled = Dialogue and Dialogue.handled or 0,
    kantoDialogueBridgeFallbacks = Dialogue and Dialogue.fallbacks or 0,
    kantoDialogueSuppressedCommands = Dialogue and Dialogue.suppressedCommands or 0,
    kantoDialogueSuppressedStates = Dialogue and Dialogue.suppressedStates or 0,
    kantoDialoguePresentationAudio = Dialogue and Dialogue.presentationAudio or 0,
    kantoDialogueErrors = Dialogue and Dialogue.errors or 0,
    yellowItemsPicked = Twin.yellowItemsPicked or 0,
    yellowMartVisits = Twin.yellowMartVisits or 0,
    yellowCenterHeals = Twin.yellowCenterHeals or 0,
    yellowTowerPurifiedHeals = Twin.yellowTowerPurifiedHeals or 0,
    yellowTowerPurifiedSteps = Twin.yellowTowerPurifiedSteps or 0,
    yellowSaffronDrinks = Twin.yellowSaffronDrinks or 0,
    yellowSaffronGateBlocks = Twin.yellowSaffronGateBlocks or 0,
    yellowMuseumTickets = Twin.yellowMuseumTickets or 0,
    yellowMuseumGateBlocks = Twin.yellowMuseumGateBlocks or 0,
    yellowOldAmberGifts = Twin.yellowOldAmberGifts or 0,
    yellowMuseumObjectMigrations = Twin.yellowMuseumObjectMigrations or 0,
    yellowBikeVouchers = Twin.yellowBikeVouchers or 0,
    yellowLocalBikeVouchers = Twin.yellowLocalBikeVouchers or 0,
    yellowBicycleExchanges = Twin.yellowBicycleExchanges or 0,
    yellowBikeShopBrowses = Twin.yellowBikeShopBrowses or 0,
    kantoTowerPurifiedActive = excursion.towerPurifiedZone == true,
    kantoTowerPurifiedEntries = KantoState.Tower.entries or 0,
    yellowPcOpens = Twin.yellowPcOpens or 0,
    yellowSurfStarts = Twin.yellowSurfStarts or 0,
    yellowSurfing = excursion.surfing == true,
    yellowResumeLoads = Twin.yellowResumeLoads or 0,
    yellowCuts = Twin.yellowCuts or 0,
    yellowStrengthUses = Twin.yellowStrengthUses or 0,
    yellowStrengthActive = excursion.strengthActive == true,
    yellowBoulderPushes = Twin.yellowBoulderPushes or 0,
    yellowTrainerSightEngages = Twin.yellowTrainerSightEngages or 0,
    yellowNpcSteps = Twin.yellowNpcSteps or 0,
    yellowSeafoamDrops = Twin.yellowSeafoamDrops or 0,
    yellowSeafoamCurrents = Twin.yellowSeafoamCurrents or 0,
    yellowFlyUses = Twin.yellowFlyUses or 0,
    yellowFlyPoints = Twin.yellowFlyPoints or 0,
    yellowHiddenCoins = Twin.yellowHiddenCoins or 0,
    yellowSpinnerRuns = Twin.yellowSpinnerRuns or 0,
    yellowBadgeGateBlocks = Twin.yellowBadgeGateBlocks or 0,
    yellowFlashUses = Twin.yellowFlashUses or 0,
    yellowDigUses = Twin.yellowDigUses or 0,
    yellowTeleportUses = Twin.yellowTeleportUses or 0,
    yellowWhiteouts = Twin.yellowWhiteouts or 0,
    yellowCenterSpawns = Twin.yellowCenterSpawns or 0,
    yellowLocalItemPickups = Twin.yellowLocalItemPickups or 0,
    yellowSemanticItemConversions = Twin.yellowSemanticItemConversions or 0,
    yellowFossilsTaken = Twin.yellowFossilsTaken or 0,
    yellowFossilsSubmitted = Twin.yellowFossilsSubmitted or 0,
    yellowFossilsRevived = Twin.yellowFossilsRevived or 0,
    yellowCinnabarGymKeyBlocks = Twin.yellowCinnabarGymKeyBlocks or 0,
    yellowRocketLiftKeyDrops = Twin.yellowRocketLiftKeyDrops or 0,
    yellowSilphScopeDrops = Twin.yellowSilphScopeDrops or 0,
    yellowRocketElevatorUses = Twin.yellowRocketElevatorUses or 0,
    yellowRocketDuoBattles = Twin.yellowRocketDuoBattles or 0,
    yellowRocketDuoWins = Twin.yellowRocketDuoWins or 0,
    yellowTowerGhostBlocks = Twin.yellowTowerGhostBlocks or 0,
    yellowMarowakBattles = Twin.yellowMarowakBattles or 0,
    yellowMarowakWins = Twin.yellowMarowakWins or 0,
    yellowTowerRocketBattles = Twin.yellowTowerRocketBattles or 0,
    yellowTowerRocketWins = Twin.yellowTowerRocketWins or 0,
    yellowFujiRescues = Twin.yellowFujiRescues or 0,
    yellowPokeFlutes = Twin.yellowPokeFlutes or 0,
    yellowSnorlaxBattles = Twin.yellowSnorlaxBattles or 0,
    yellowSnorlaxClears = Twin.yellowSnorlaxClears or 0,
    yellowBillHelps = Twin.yellowBillHelps or 0,
    yellowSSTickets = Twin.yellowSSTickets or 0,
    yellowSSAnneGateBlocks = Twin.yellowSSAnneGateBlocks or 0,
    yellowSSAnneRivalBattles = Twin.yellowSSAnneRivalBattles or 0,
    yellowSSAnneRivalWins = Twin.yellowSSAnneRivalWins or 0,
    yellowCaptainCutGifts = Twin.yellowCaptainCutGifts or 0,
    yellowSSAnneDepartures = Twin.yellowSSAnneDepartures or 0,
    yellowSilphDuoBattles = Twin.yellowSilphDuoBattles or 0,
    yellowSilphDuoWins = Twin.yellowSilphDuoWins or 0,
    yellowSilphGiovanniBattles = Twin.yellowSilphGiovanniBattles or 0,
    yellowSilphGiovanniWins = Twin.yellowSilphGiovanniWins or 0,
    yellowSilphLiberations = Twin.yellowSilphLiberations or 0,
    yellowSaffronStateMigrations = Twin.yellowSaffronStateMigrations or 0,
    yellowMasterBallGifts = Twin.yellowMasterBallGifts or 0,
    yellowCeruleanTM28Returns = Twin.yellowCeruleanTM28Returns or 0,
    yellowNonGymGiovanniBattles = Twin.yellowNonGymGiovanniBattles or 0,
    johtoAnchorRestores = Twin.johtoAnchorRestores or 0,
    kantoFlashActive = excursion.flashActive == true,
    yellowHiddenItems = Twin.yellowHiddenItems or 0,
    yellowHiddenPcUses = Twin.yellowHiddenPcUses or 0,
    yellowGymStatues = Twin.yellowGymStatues or 0,
    yellowFishingUses = Twin.yellowFishingUses or 0,
    yellowSafariActive = excursion.safari ~= nil,
    yellowSafariBalls = excursion.safari and excursion.safari.balls or 0,
    yellowSafariStepsLeft = excursion.safari and excursion.safari.steps or 0,
    yellowSafariAdmissions = Twin.yellowSafariAdmissions or 0,
    yellowSafariEncounters = Twin.yellowSafariEncounters or 0,
    yellowSafariCatches = Twin.yellowSafariCatches or 0,
    yellowSafariFlees = Twin.yellowSafariFlees or 0,
    yellowSlotSpins = Twin.yellowSlotSpins or 0,
    yellowSlotWins = Twin.yellowSlotWins or 0,
    yellowCoinPurchases = Twin.yellowCoinPurchases or 0,
    yellowPrizes = Twin.yellowPrizes or 0,
    yellowTrades = Twin.yellowTrades or 0,
    yellowRodGifts = Twin.yellowRodGifts or 0,
    lastWildSpecies = Twin.lastWildSpecies,
    lastWildLevel = Twin.lastWildLevel,
    yellowCacheRequired = true,
    error = Twin.lastError,
  }
end

return Twin
