-- StadiumBattleFX 2.1.7 -> Gold/Stadium2 integration layer.
--
-- The imported source lives in lib/StadiumBattleFX217/ under its original MIT
-- license.  This file does NOT run that mod's Gen-1 battle host wholesale: our
-- Gold port already owns the live overworld arena, Stadium2 model provider,
-- controller layer and battle camera.  Instead it loads the source-calibrated
-- data/extractors in a private namespace and adapts the useful presentation
-- systems to Gold's battle events.
local V = ...
local M = {}

local mod = V and V.mod
local unpack = table.unpack or unpack
local sourceModules = {}
local installed = false
local currentGame, activeGoldBattle, announcerBattle
local arenaToken = 0
local caption = { text=nil, t=0, priority=0 }
local screenPulse, sourcePlayer

local function option(key, default)
  local opts = mod and mod.options
  if opts and type(opts.get) == "function" then
    local ok, value = pcall(opts.get, opts, key)
    if ok and value ~= nil then return value end
  end
  return default
end

local function on(key, default)
  local v = option(key, default)
  return not (v == false or v == 0 or v == "0" or v == "false" or v == "off")
end

local OPTION_ALIAS = {
  enabled = "stadiumFxPortEnabled",
  trainer_portraits = "stadiumTrainerPortraits",
  attack_camera = "stadiumFxAttackCamera",
  attack_speed = "stadiumFxAttackSpeed",
  announcer = "stadiumAnnouncer",
  announcer_scope = "stadiumAnnouncerScope",
  battle_cinematics_zoom = "stadiumFxCinematicZoom",
}

local proxyOptions = {}
function proxyOptions:get(key)
  local mapped = OPTION_ALIAS[key]
  if mapped then return option(mapped, nil) end
  return nil
end

local proxyMod = setmetatable({
  id = (mod and mod.id) or "STADIUM2_OVERWORLD_MODELS",
  path = mod and mod.path,
  log = mod and mod.log,
  options = proxyOptions,
  storage = mod and mod.storage,
  assets = mod and mod.assets,
  exports = { version = "2.1.7" },
}, { __index = mod })

-- Prefer a path from the embedded source tree, then fall back to this combined
-- mod's root.  The latter is intentional: a personalized announcer voice pack
-- can be copied into assets/announcer/ without editing the embedded source.
function proxyMod:read(relative)
  if not (mod and type(mod.read) == "function") then return nil end
  local embedded = "lib/StadiumBattleFX217/" .. tostring(relative or "")
  local ok, bytes = pcall(mod.read, mod, embedded)
  if ok and type(bytes) == "string" then return bytes end
  local ok2, bytes2 = pcall(mod.read, mod, relative)
  if ok2 then return bytes2 end
end

local ns = { mod=proxyMod, path=proxyMod.path, engineRequire=require, hostRequire=V and V.require }
local function sourceChunk(name)
  local rel = "lib/StadiumBattleFX217/" .. name .. ".lua"
  local source = mod and mod:read(rel)
  if type(source) ~= "string" then error("StadiumBattleFX port missing " .. rel, 0) end
  local loader = loadstring or load
  local chunk, err = loader(source, "@" .. tostring(mod.path or "") .. "/" .. rel)
  if not chunk then error(rel .. ": " .. tostring(err), 0) end
  return chunk
end
function ns.require(name)
  if sourceModules[name] ~= nil then return sourceModules[name] end
  local value = sourceChunk(name)(ns)
  sourceModules[name] = value
  return value
end

local function safeSource(name)
  local ok, value = pcall(ns.require, name)
  if ok then return value end
  if mod and mod.log and mod.log.warn then
    pcall(mod.log.warn, mod.log, "StadiumBattleFX source module %s unavailable: %s",
      tostring(name), tostring(value))
  end
  return nil
end

-- Keep StadiumBattleFX's own diagnostic logger active inside the embedded
-- namespace.  It writes only through mod.storage and mirrors important lines to
-- this combined mod's host logger.
local Storage = safeSource("ModStorage")
ns.storage = Storage
local SourceLogClass = safeSource("StadiumLog")
local SourceLog
if SourceLogClass and type(SourceLogClass.new) == "function" then
  local okLog, value = pcall(SourceLogClass.new, mod and mod.log)
  if okLog then SourceLog = value end
end
if not SourceLog then
  SourceLog = {
    info = function(_, fmt, ...) if mod and mod.log and mod.log.info then pcall(mod.log.info, mod.log, fmt, ...) end end,
    warn = function(_, fmt, ...) if mod and mod.log and mod.log.warn then pcall(mod.log.warn, mod.log, fmt, ...) end end,
    error = function(_, fmt, ...) if mod and mod.log and mod.log.error then pcall(mod.log.error, mod.log, fmt, ...) end end,
    event = function() end, flush = function() return true end, contents = function() return "" end,
  }
end
ns.log = SourceLog

-- The uploaded mod's DramaticShape* modules are really provider adapters.
-- Route their model requests into the already-active Stadium2 battle renderer
-- instead of installing StadiumBattleFX's competing Stadium1 model host.
local HostProxy = {}
function HostProxy.animationViewport()
  -- Keep authored particles in the 160x144 logical battle layer.  The current
  -- Stadium2 renderer already exposes projected attachment points in that same
  -- space, while whole-screen operations are replayed later by ScreenFx.present.
  return nil
end
function HostProxy.call(slot, method, ...)
  if slot ~= "models" then return false, "combined build owns provider slot " .. tostring(slot) end
  local okS, Stadium = pcall(V.require, "Stadium")
  if not (okS and type(Stadium) == "table") then return false, "Stadium2 model host unavailable" end
  local args = {...}
  if method == "showing" then return true, Stadium.showing and Stadium.showing(args[1]) or false end
  if method == "footprint" then return true, Stadium.footprint and Stadium.footprint(args[1]) or nil end
  if method == "attachment" then
    local x,y = Stadium.attachment and Stadium.attachment(args[1], args[2])
    return true, x, y
  end
  if method == "center" then
    local x,y = Stadium.attachment and Stadium.attachment(args[1], 0x64)
    return true, x, y
  end
  if method == "screenAttachment" then
    local x,y = Stadium.attachment and Stadium.attachment(args[1], args[2])
    return true, x, y
  end
  if method == "screenCenter" then
    local x,y = Stadium.attachment and Stadium.attachment(args[1], 0x64)
    return true, x, y
  end
  if method == "attachmentTags" then
    local a,b = M.nativeAttachmentTags and M.nativeAttachmentTags(args[1], args[2], args[3])
    return true, a, b
  end
  if method == "moveSync" then
    return true, M.nativeMoveSync and M.nativeMoveSync(args[1], args[2]) or nil
  end
  if method == "synchronizeMove" then
    -- Stadium2 keeps its own Gen2 skeletal clip clock.  Do not seek it using
    -- Stadium1 frame indices; the native row is still used for attachments and
    -- camera cuts.
    return true, false
  end
  if method == "hit" then
    if M.hitReactionsEnabled and not M.hitReactionsEnabled() then return true, false end
    return true, Stadium.hit and Stadium.hit(args[1], args[2]) or false
  end
  if method == "faint" then
    -- Gold's existing Stadium lifecycle already queues fainting on the HP-drain
    -- boundary; acknowledge the source request without firing it twice.
    return true, M.faintAnimationsEnabled and M.faintAnimationsEnabled() or false
  end
  return false, "unsupported combined Stadium2 model method: " .. tostring(method)
end
sourceModules["BattleHost"] = HostProxy
sourceModules["BattleArtCompat"] = {
  presentationState = function() return nil end, active = function() return false end,
  refresh = function() end, status = function() return { active=false, owner="STADIUM2_OVERWORLD_MODELS" } end,
}
local MoveSpecs = safeSource("effects/MoveSpecs")
local Assets = safeSource("StadiumAssets")
local ArenaAssets = safeSource("StadiumArenaAssets")
local Portraits = safeSource("StadiumTrainerPortraits")
local Announcer = safeSource("Announcer")
local SourceMat4 = safeSource("Mat4")
local AuthenticRenderer = safeSource("effects/StadiumAuthenticRenderer")
local GenericRenderer = safeSource("effects/GenericMoveRenderer")
local ScreenFx = safeSource("effects/StadiumScreenFx")
local SourceCinematics = safeSource("AttackCinematics")
local ModelInstall = safeSource("StadiumInstall")
local StadiumPack = safeSource("StadiumPack")
local NativeInterpreter = safeSource("effects/StadiumNativeInterpreter")
local ThunderShockSpec = safeSource("effects/ThunderShockSpec")
local FailureNotice = safeSource("FailureNotice")
local SourceLogExport = safeSource("StadiumLogExport")
local SourceFxPlayerClass = safeSource("effects/StadiumFxPlayer")
local DramaticShapeAttachment = safeSource("DramaticShapeAttachment")
local DramaticShapeHit = safeSource("DramaticShapeHit")
local DramaticShapeFaint = safeSource("DramaticShapeFaint")

-- The combined Gold mod already uses baserom.z64 for Stadium 2.  Never let the
-- Stadium 1 effect extractor mistake that file for its own cartridge.  Only
-- names that unambiguously mean Stadium 1 are considered here.
local stadium1Override
local sourceAssetsPreloaded = false
if Storage then
  local originalBundled = Storage.bundled
  local ROM_NAMES = {
    "baseroms/Pokemon Stadium (USA).z64",
    "baseroms/Pokemon Stadium (USA).n64",
    "baseroms/Pokemon Stadium (USA).v64",
    "baseroms/stadium1.z64", "baseroms/stadium1.n64", "baseroms/stadium1.v64",
    "baseroms/stadium_fx.z64", "baseroms/stadium_fx.n64", "baseroms/stadium_fx.v64",
    "baseroms/stadium1_fx.z64", "baseroms/stadium1_fx.n64", "baseroms/stadium1_fx.v64",
  }
  Storage.bundledRom = function()
    if type(stadium1Override) == "string" then return "__stadium1_fx_selected.z64", stadium1Override end
    for _, relative in ipairs(ROM_NAMES) do
      local bytes = originalBundled(relative)
      if type(bytes) == "string" then return relative, bytes end
    end
  end
  Storage.bundled = function(relative)
    if relative == "__stadium1_fx_selected.z64" and type(stadium1Override) == "string" then
      return stadium1Override
    end
    return originalBundled(relative)
  end
end

local function log(level, fmt, ...)
  local l = mod and mod.log
  local fn = l and l[level]
  if type(fn) == "function" then pcall(fn, l, fmt, ...) end
end

local function normalize(s)
  return tostring(s or ""):upper():gsub("[^A-Z0-9]", "")
end

function M.enabled() return on("stadiumFxPortEnabled", true) end
function M.screenEffectsEnabled() return M.enabled() and on("stadiumFxScreenEffects", true) end
function M.hitReactionsEnabled() return M.enabled() and on("stadiumFxHitReactions", true) end
function M.faintAnimationsEnabled() return M.enabled() and on("stadiumFxFaintAnimations", true) end
function M.attackCameraEnabled()
  return M.enabled() and on("stadiumFxAttackCamera", true)
    and (tonumber(option("stadiumFxAttackSpeed", "100")) or 100) > 0
end
function M.bossArenasEnabled() return M.enabled() and on("stadiumBossArenas", true) end
function M.portraitsEnabled() return M.enabled() and on("stadiumTrainerPortraits", true) end
function M.announcerEnabled() return M.enabled() and on("stadiumAnnouncer", true) end
function M.nativeSchedulerEnabled() return M.enabled() and on("stadiumFxNativeScheduler", true) end
function M.nativeSyncEnabled() return M.enabled() and on("stadiumFxNativeSync", true) end
function M.fallbackNoticeEnabled() return M.enabled() and on("stadiumFxFallbackNotice", true) end
function M.overlayMode()
  if not M.enabled() then return "off" end
  local value = tostring(option("stadiumFx2DLayer", "authentic") or "authentic"):lower()
  if value ~= "all" and value ~= "authentic" then return "off" end
  return value
end
function M.attackSpeed()
  if not M.enabled() then return 0 end
  local n = tonumber(option("stadiumFxAttackSpeed", "100")) or 100
  return math.max(0, math.min(100, n)) / 100
end
function M.cinematicZoom()
  local v = option("stadiumFxCinematicZoom", "25")
  if v == "off" then return 0 end
  return math.max(0, math.min(50, tonumber(v) or 25)) / 100
end

local function moveIndex(move, def)
  if type(move) == "number" then return move end
  if type(move) == "table" then
    local n = tonumber(move.index or move.moveIndex or move.number)
    if n then return n end
    move = move.id or move.name
  end
  if type(def) == "table" then
    local n = tonumber(def.index or def.moveIndex or def.number)
    if n then return n end
  end
  local n = tonumber(move)
  if n then return n end
  return nil
end

function M.moveSpec(move, def)
  if not (M.enabled() and MoveSpecs and type(MoveSpecs.get) == "function") then return nil end
  local index = moveIndex(move, def)
  if index and index >= 1 and index <= 165 then
    local spec = MoveSpecs.get(index)
    if spec then return spec end
  end
  local key = type(move) == "table" and (move.id or move.name) or move
  if type(key) == "string" then
    local spec = MoveSpecs.get(key) or MoveSpecs.get(normalize(key))
    if spec then return spec end
  end
  if type(def) == "table" then
    local id = def.id or def.name
    if id then return MoveSpecs.get(id) or MoveSpecs.get(normalize(id)) end
  end
end

-- StadiumBattleFX has 28 source visual families.  Map them to the already
-- depth-aware Gold world primitives, preserving exact source timing and
-- delivery while avoiding a second renderer fighting our Stadium2 scene.
local VISUAL_TO_WORLD = {
  barrier="psychic", beam="beam", bite="body", drain="drain",
  electric="thunderbolt", explosion="explode", flash="swift",
  grapple="body", ground="quake", haze="night", heal="drain",
  impact="body", kick="body", leaf="razorleaf", mist="blizzard",
  needle="swift", orb="swift", psychic="psychic", punch="body",
  rush="body", slash="windslash", sound="tornado", status="psychic",
  storm="blizzard", stream="beam", transform="psychic", wave="surf",
  wind="tornado",
}
function M.worldEffect(spec, fallback, moveType)
  if not spec then return fallback end
  local visual = normalize(spec.visual):lower()
  local mapped = VISUAL_TO_WORLD[visual]
  if visual == "stream" then
    local t = normalize(moveType)
    if t == "FIRE" then mapped = "flamethrower"
    elseif t == "WATER" then mapped = "hydro"
    elseif t == "ICE" then mapped = "icebeam"
    elseif t == "GRASS" then mapped = "drain" end
  elseif visual == "storm" then
    local t = normalize(moveType)
    if t == "ELECTRIC" then mapped = "thunder"
    elseif t == "ICE" then mapped = "blizzard"
    elseif t == "FLYING" then mapped = "tornado" end
  elseif visual == "orb" then
    local t = normalize(moveType)
    if t == "FIRE" then mapped = "fireblast"
    elseif t == "WATER" then mapped = "watergun"
    elseif t == "ELECTRIC" then mapped = "thunderbolt"
    elseif t == "PSYCHIC" then mapped = "psychic"
    elseif t == "GHOST" or t == "DARK" then mapped = "night" end
  end
  return mapped or fallback
end

function M.timing(spec, defaultDuration)
  local speed = M.attackSpeed()
  if speed <= 0 then return nil end
  local duration = tonumber(spec and spec.duration) or tonumber(defaultDuration) or 52
  local impact = tonumber(spec and spec.impactAt) or duration * 0.58
  -- ATTACK SPEED is presentation speed: 50% means a move takes twice as long.
  duration = duration / speed
  impact = impact / speed
  return duration, impact
end

function M.impactFraction(spec)
  local duration, impact = M.timing(spec, 52)
  if not duration then return 0.58 end
  return math.max(0.05, math.min(0.95, impact / math.max(1, duration)))
end

-- ----- Stadium 1 species/move synchronization metadata ----------------------------
--
-- The current battle renderer remains Stadium2, but the uploaded StadiumBattleFX
-- cache carries useful *presentation metadata* for the original 151 species:
-- per-move attachment bytes and the native camera selector/cut row.  Read only
-- those rows and feed them to the current renderer; never swap model ownership.
local metadataCache = {}

local function sideMon(side)
  local b = activeGoldBattle
  if not b then return nil end
  if side == "player" then return b.player end
  if side == "enemy" then return b.enemy end
  return nil
end

local function speciesDex(mon)
  if not mon then return nil end
  local direct = tonumber(mon.dex or mon.dexNo or mon.nationalDex)
  if direct then return math.floor(direct) end
  if type(mon.species) == "number" then return math.floor(mon.species) end
  local data = activeGoldBattle and activeGoldBattle.data
  local pokemon = data and data.pokemon
  local def = pokemon and pokemon[mon.species]
  if type(def) == "table" then
    local n = tonumber(def.dex or def.dexNo or def.nationalDex or def.index or def.number)
    if n then return math.floor(n) end
  end
  return nil
end

local function baseMetadata(side)
  if not (M.nativeSyncEnabled() and StadiumPack and type(StadiumPack.loadBase) == "function") then return nil end
  local dex = speciesDex(sideMon(side))
  if not dex or dex < 1 or dex > 151 then return nil end
  local cached = metadataCache[dex]
  if cached ~= nil then return cached or nil end
  local ok, model = pcall(StadiumPack.loadBase, dex)
  metadataCache[dex] = ok and model or false
  return ok and model or nil
end

function M.nativeMoveSync(side, moveId)
  local model = baseMetadata(side)
  moveId = math.floor(tonumber(moveId) or 0)
  if not (model and moveId >= 1 and moveId <= 165) then return nil end
  local raw = model.moveSync and model.moveSync[moveId]
  if type(raw) ~= "table" then return nil end
  local out = { species = speciesDex(sideMon(side)), frame = raw[1] }
  for offset = 4, 15 do out[("byte_%02X"):format(offset)] = raw[offset + 1] end
  return out
end

function M.nativeAttachmentTags(side, moveId, stage)
  local model = baseMetadata(side)
  moveId = math.floor(tonumber(moveId) or 0)
  if not model then return nil end
  if stage == "impact" then
    return model.ctxAttachA and model.ctxAttachA[4] or nil,
           model.ctxAttachB and model.ctxAttachB[4] or nil
  end
  if moveId < 1 or moveId > 165 then return nil end
  return model.moveAttachA and model.moveAttachA[moveId] or nil,
         model.moveAttachB and model.moveAttachB[moveId] or nil
end

function M.attachmentTag(spec, role)
  local attachments = type(spec) == "table" and spec.attachments or nil
  local value = type(attachments) == "table" and attachments[role] or nil
  value = tonumber(value)
  if value then return math.floor(value) end
  if M.nativeSyncEnabled() and type(spec) == "table" then
    local attacker = screenPulse and screenPulse.side or "player"
    local side = role == "target" and (attacker == "player" and "enemy" or "player") or attacker
    local stage = role == "target" and "impact" or "primary"
    local a = M.nativeAttachmentTags(side, spec.id, stage)
    if a ~= nil then return math.floor(tonumber(a) or 0x64) end
  end
  return 0x64
end

-- ----- Stadium 1 ROM-derived caches -------------------------------------------------
local jobsStarted = false
local function modelInstallState()
  local st = ModelInstall and ModelInstall.status
  return type(st) == "table" and st.state or nil
end

local function startCaches()
  if jobsStarted or not Storage or not M.enabled() then return end
  jobsStarted = true
  local path = Storage.bundledRom()
  if not path then return end
  if Assets and Assets.pending and Assets.pending() then pcall(Assets.begin, false) end
  if ArenaAssets and ArenaAssets.pending and ArenaAssets.pending() then pcall(ArenaAssets.begin, false) end
  if Portraits and Portraits.pending and Portraits.pending() then pcall(Portraits.begin) end
  if M.nativeSyncEnabled() and ModelInstall and ModelInstall.pending and ModelInstall.pending() then
    pcall(ModelInstall.begin)
  end
end

local function stepCaches()
  if Assets and Assets.status and Assets.status().state == "building" then pcall(Assets.step) end
  if ArenaAssets and ArenaAssets.status and ArenaAssets.status().state == "building" then pcall(ArenaAssets.step) end
  if Portraits and Portraits.status and Portraits.status().state == "building" then pcall(Portraits.step) end
  if ModelInstall and modelInstallState() == "building" then pcall(ModelInstall.step) end
  if Announcer and Announcer.cacheStatus and Announcer.cacheStatus().state == "building" then pcall(Announcer.stepCache) end
  local building = modelInstallState() == "building"
  for _, item in ipairs({Assets, ArenaAssets, Portraits}) do
    if item and item.status and item.status().state == "building" then building = true end
  end
  if not building then stadium1Override = nil end
end

function M.rebuildCaches()
  jobsStarted = false
  sourceAssetsPreloaded = false
  metadataCache = {}
  if Assets and Assets.cancel then pcall(Assets.cancel) end
  if ArenaAssets and ArenaAssets.cancel then pcall(ArenaAssets.cancel) end
  if Portraits and Portraits.cancel then pcall(Portraits.cancel) end
  if ModelInstall and ModelInstall.cancel then pcall(ModelInstall.cancel) end
  if Announcer and Announcer.cancelCache then pcall(Announcer.cancelCache) end
  if ModelInstall and ModelInstall.forget then pcall(ModelInstall.forget) end
  if StadiumPack and StadiumPack.forget then pcall(StadiumPack.forget) end
  startCaches()
  return true
end

function M.importStadium1(bytes)
  if not (Assets and type(Assets.validateRom) == "function") then
    return false, "Stadium 1 extractor unavailable"
  end
  local ok, reader, validateErr = pcall(Assets.validateRom, bytes)
  if not ok or not reader then
    return false, tostring((ok and validateErr) or reader or "needs Pokemon Stadium (USA) v1.0")
  end

  -- validateRom has already normalized .z64/.v64/.n64 to canonical z64 order.
  -- Retain that one string for every Stadium 1 cache so the importer does not
  -- keep both the picker copy and a second 32 MiB normalized copy alive.
  local normalized = type(reader.bytes) == "string" and reader.bytes or bytes
  stadium1Override = normalized
  M.rebuildCaches()

  -- The source model cache provides the exact 151x165 attachment/camera rows.
  if M.nativeSyncEnabled() and ModelInstall and type(ModelInstall.beginFrom) == "function" then
    pcall(ModelInstall.cancel)
    pcall(ModelInstall.forget)
    if StadiumPack and StadiumPack.forget then pcall(StadiumPack.forget) end
    metadataCache = {}
    local okBuild, started, err = pcall(ModelInstall.beginFrom, normalized, "selected Stadium 1 ROM")
    if not okBuild then log("warn", "Stadium native sync cache could not start: %s", tostring(started))
    elseif not started then log("warn", "Stadium native sync cache declined ROM: %s", tostring(err)) end
  end

  -- The same selected ROM builds the private 823-clip announcer bank in Lua on
  -- both PC and Android. Start it after rebuildCaches(), because that function
  -- cancels any older/incomplete cache job first.
  if Announcer and type(Announcer.beginRomCache) == "function" then
    local okVoice, startedVoice, voiceErr = pcall(Announcer.beginRomCache, normalized, false)
    if not okVoice then
      log("warn", "Stadium announcer ROM cache could not start: %s", tostring(startedVoice))
    elseif not startedVoice then
      log("warn", "Stadium announcer ROM cache declined ROM: %s", tostring(voiceErr))
    else
      log("info", "Stadium announcer ROM cache accepted selected Stadium 1 ROM")
    end
  else
    log("warn", "Stadium announcer ROM decoder is unavailable")
  end
  return true
end

function M.announcerImportStatus()
  if Announcer and type(Announcer.cacheStatus) == "function" then
    local ok, value = pcall(Announcer.cacheStatus)
    if ok and type(value) == "table" then return value end
  end
  return { state = "unavailable", ready = false, installed = false, total = 823, done = 0 }
end

function M.testAnnouncerVoice(index)
  if not (Announcer and type(Announcer.testVoice) == "function") then
    return false, "Stadium announcer playback is unavailable"
  end
  local ok, played, err = pcall(Announcer.testVoice, index or 223)
  if not ok then
    err = tostring(played)
    played = false
  end
  if not played then
    local reason = tostring(err or "announcer test clip could not play")
    log("warn", "Stadium announcer test failed: %s", reason)
    if FailureNotice and type(FailureNotice.show) == "function" then
      pcall(FailureNotice.show, "ANNOUNCER TEST", reason)
    end
    return false, reason
  end
  log("info", "Stadium announcer test voice started")
  return true
end

function M.assets() return Assets end
function M.portraits() return Portraits end
function M.arenaAssets() return ArenaAssets end

-- ----- trainer identity -------------------------------------------------------------
local GENERIC_CLASS = {
  YOUNGSTER="OPP_YOUNGSTER", BUG_CATCHER="OPP_BUG_CATCHER", BUGCATCHER="OPP_BUG_CATCHER",
  LASS="OPP_LASS", SAILOR="OPP_SAILOR", POKEMANIAC="OPP_POKEMANIAC",
  SUPER_NERD="OPP_SUPER_NERD", SUPER_NERD_M="OPP_SUPER_NERD", SUPERNERD="OPP_SUPER_NERD",
  HIKER="OPP_HIKER", BIKER="OPP_BIKER", BURGLAR="OPP_BURGLAR",
  JUGGLER="OPP_JUGGLER", FISHER="OPP_FISHER", FISHERMAN="OPP_FISHER",
  SWIMMER_M="OPP_SWIMMER", SWIMMER_F="OPP_SWIMMER", SWIMMER="OPP_SWIMMER",
  BEAUTY="OPP_BEAUTY", PSYCHIC="OPP_PSYCHIC_TR", BIRD_KEEPER="OPP_BIRD_KEEPER",
  BIRDKEEPER="OPP_BIRD_KEEPER", BLACKBELT_T="OPP_BLACKBELT", BLACKBELT="OPP_BLACKBELT",
  SCIENTIST="OPP_SCIENTIST", GENTLEMAN="OPP_GENTLEMAN", COOLTRAINER_M="OPP_COOLTRAINER_M",
  COOLTRAINER_F="OPP_COOLTRAINER_F", ACE_TRAINER_M="OPP_COOLTRAINER_M",
  ACE_TRAINER_F="OPP_COOLTRAINER_F", POKEFAN_M="OPP_POKEMANIAC",
}
local CHARACTER_CLASS = {
  BROCK="OPP_BROCK", MISTY="OPP_MISTY", LT_SURGE="OPP_LT_SURGE", LTSURGE="OPP_LT_SURGE",
  ERIKA="OPP_ERIKA", KOGA="OPP_KOGA", JANINE="OPP_KOGA",
  SABRINA="OPP_SABRINA", BLAINE="OPP_BLAINE",
  BRUNO="OPP_BRUNO", LANCE="OPP_LANCE", CHAMPION="OPP_LANCE",
  BLUE="OPP_RIVAL3", RED="OPP_RIVAL3",
}
function M.oppClass(value, trainer)
  local key = tostring(value or (trainer and (trainer.classId or trainer.class)) or ""):upper()
  key = key:gsub("[^A-Z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return CHARACTER_CLASS[key] or GENERIC_CLASS[key]
end

local VENUE = {
  BROCK="brock", MISTY="misty", LT_SURGE="surge", LTSURGE="surge",
  ERIKA="erika", JANINE="koga", SABRINA="sabrina", BLAINE="blaine",
  BLUE="giovanni",
  WILL="elite4", KOGA="elite4", BRUNO="elite4", KAREN="elite4",
  CHAMPION="champion", LANCE="champion",
}
local BOSS_RIG = { side=78.79, back=217.44, height=82, lookX=-.26, lookY=.34, frameH=34.11 }
function M.bossVenue(battle)
  battle = battle or activeGoldBattle
  local trainer = battle and battle.trainer
  local key = tostring(trainer and (trainer.classId or trainer.class) or ""):upper()
  key = key:gsub("[^A-Z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return VENUE[key]
end

function M.decorateArena(arena, battle)
  if not (arena and M.bossArenasEnabled()) then return arena end
  local venue = M.bossVenue(battle)
  if not venue then return arena end
  if not (ArenaAssets and ArenaAssets.ready and ArenaAssets.ready()) then return arena end
  arenaToken = arenaToken + 1
  arena._stadiumFxVenue = venue
  arena._stadiumFxArenaToken = arenaToken
  arena.discs = true
  arena.cam = "stadiumBattleFxBoss"
  local okCam, BattleCam = pcall(V.require, "BattleCam")
  if okCam and BattleCam and BattleCam.RIGS then BattleCam.RIGS.stadiumBattleFxBoss = BOSS_RIG end
  return arena
end

local function arenaMatrix(arena, groundY)
  local Mat4 = SourceMat4 or V.require("Mat4")
  local mid = arena and arena.mid
  if not mid then return nil end
  return Mat4.mul(Mat4.mul(Mat4.translate(mid[1], groundY or 0, mid[2]),
    Mat4.rotateY(math.pi / 2)), Mat4.scale(.100, .100, .100))
end

function M.drawArena(Voxel3D, arena, groundY)
  local venue = arena and arena._stadiumFxVenue
  if not (venue and ArenaAssets and ArenaAssets.get and Voxel3D) then return false end
  local stage = ArenaAssets.get(venue, Voxel3D)
  local matrix = arenaMatrix(arena, groundY)
  if not (stage and matrix) then return false end
  for _, group in ipairs(stage.groups or {}) do
    if not group.floorMark then
      local tint = group.tint or {1,1,1,1}
      if love and love.graphics and love.graphics.setColor then
        love.graphics.setColor(tint[1] or 1, tint[2] or 1, tint[3] or 1, tint[4] or 1)
      end
      Voxel3D.draw(group.mesh, group.texture, matrix)
    end
  end
  if love and love.graphics and love.graphics.setColor then love.graphics.setColor(1,1,1,1) end
  return true
end

function M.castArena(shadowMap, arena, groundY)
  local venue = arena and arena._stadiumFxVenue
  if not (venue and ArenaAssets and ArenaAssets.get and shadowMap and shadowMap.draw) then return false end
  local okV, Voxel3D = pcall(V.require, "Voxel3D")
  if not okV then return false end
  local stage = ArenaAssets.get(venue, Voxel3D)
  local matrix = arenaMatrix(arena, groundY)
  if not (stage and matrix) then return false end
  for _, group in ipairs(stage.groups or {}) do
    if not group.floorMark and not group.noShadow then
      shadowMap.draw(group.mesh, group.texture, matrix)
    end
  end
  return true
end
function M.arenaSky(arena)
  if arena and arena._stadiumFxVenue then return {0,0,0,1} end
end

-- ----- trainer portraits ------------------------------------------------------------
local function installPortraitBridge()
  local ok, BattleState = pcall(require, "src.ui.gen2.BattleState")
  if not (ok and type(BattleState) == "table" and type(BattleState.new) == "function") then return false end
  if BattleState._stadiumBattleFx217PortraitBridge then return true end
  local inner = BattleState.new
  BattleState.new = function(game, opts)
    local screen = inner(game, opts)
    if screen and M.portraitsEnabled()
        and Portraits and Portraits.ready and Portraits.ready() then
      local trainer = screen.battle and screen.battle.trainer
      local opp = M.oppClass(screen.enemyTrainerClass, trainer)
      local index = opp and Portraits.indexFor and Portraits.indexFor(opp)
      local image = index and Portraits.image and Portraits.image(index, false)
      if image then
        screen._stadiumBattleFxOriginalTrainerImage = screen.enemyTrainerImage
        screen.enemyTrainerImage = image
        screen.enemyTrainerTrueColor = true
        screen._stadiumBattleFxPortraitIndex = index
      end
    end
    return screen
  end
  BattleState._stadiumBattleFx217PortraitBridge = true
  return true
end

-- ----- Gold adapter for the original 823-clip announcer ------------------------------
local function battlerWrap(mon, isPlayer)
  return {
    mon = mon,
    isPlayer = isPlayer and true or false,
    shownHP = tonumber(mon and mon.hp) or 0,
    draining = false,
    fainted = tonumber(mon and mon.hp) ~= nil and tonumber(mon.hp) <= 0 or false,
    _drainTimer = 0,
  }
end

local BOSS_CLASSES = {
  FALKNER=true, BUGSY=true, WHITNEY=true, MORTY=true, CHUCK=true,
  JASMINE=true, PRYCE=true, CLAIR=true,
  BROCK=true, MISTY=true, LT_SURGE=true, LTSURGE=true, ERIKA=true,
  JANINE=true, SABRINA=true, BLAINE=true, BLUE=true,
  WILL=true, KOGA=true, BRUNO=true, KAREN=true, CHAMPION=true,
  LANCE=true, RED=true, MYSTICALMAN=true, EUSINE=true,
}

local function classKey(trainer)
  local key = tostring(trainer and (trainer.classId or trainer.class) or ""):upper()
  return key:gsub("[^A-Z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

local function announcerScopeAllows(gold)
  if not gold then return false end
  local scope = tostring(option("stadiumAnnouncerScope", "gym") or "gym"):lower()
  if scope == "all" then return true end
  if scope == "trainer" then return not gold.wild end
  if gold.wild then return false end
  return BOSS_CLASSES[classKey(gold.trainer)] == true
end

local function currentBattleScreen()
  if not (V and type(V.require) == "function") then return nil end
  local ok, ow = pcall(V.require, "OverworldBattle")
  if not (ok and ow and type(ow.battle) == "function") then return nil end
  local ok2, screen = pcall(ow.battle)
  return ok2 and screen or nil
end

local function syncAnnouncerBattle()
  local gold, b = activeGoldBattle, announcerBattle
  if not (gold and b) then return end

  b.data = gold.data
  b.player.mon = gold.player
  b.enemy.mon = gold.enemy

  for _, side in ipairs({ "player", "enemy" }) do
    local wrap = b[side]
    local mon = side == "player" and gold.player or gold.enemy
    wrap.draining = (tonumber(wrap._drainTimer) or 0) > 0
    wrap.shownHP = tonumber(mon and mon.hp) or wrap.shownHP
    wrap.fainted = (tonumber(wrap.shownHP) or 0) <= 0
  end

  local screen = currentBattleScreen()
  if screen then
    local phase = screen.phase
    if phase == "moves" then phase = "moveSelect" end
    b.phase = phase
    b.menuIndex = screen.menuIndex
    b.moveIndex = screen.moveIndex
    b.moveSwapIndex = screen.moveSwapIndex
    b.mimicIndex = screen.mimicIndex
    local text = screen.message
    if text == nil and type(screen.current) == "table" then text = screen.current.text end
    b.current = text and { text = text } or nil
    b.msgHold = (tonumber(screen.messageTimer) or 0) > 0
  end

  if b._animTimer and b._animTimer <= 0 then
    b.animPlaying, b.animName = false, nil
  end
  if b._sendTimer and b._sendTimer <= 0 then
    b.sendingOut, b.enemySendingOut = false, false
  end
end

local function captionText(text, priority, seconds)
  if not on("stadiumAnnouncerCaptions", true) then return end
  if not announcerScopeAllows(activeGoldBattle) then return end
  priority = tonumber(priority) or 10
  if caption.t > 0 and priority < caption.priority then return end
  caption.text, caption.priority, caption.t = tostring(text or ""), priority, seconds or 1.65
end

local function monName(mon)
  return tostring(mon and (mon.nickname or mon.name or mon.species) or "POKéMON")
end

local function moveLabel(move)
  return tostring(move and (move.name or move.id) or "MOVE")
end

local function sourceMoveRecord(move, moveId)
  local spec = M.moveSpec(moveId or move, move)
  if type(move) ~= "table" then
    return { id = moveId or move, name = moveId or move, index = spec and spec.id or tonumber(moveId) }
  end
  if tonumber(move.index) then return move end
  local copy = {}
  for k, v in pairs(move) do copy[k] = v end
  copy.index = spec and spec.id or moveIndex(moveId or move, move)
  return copy
end

local function beginAnnouncer(gold)
  activeGoldBattle = gold
  if not gold then announcerBattle = nil return end

  local trainer = gold.trainer
  local b
  b = {
    _gold = gold,
    kind = gold.wild and "wild" or "trainer",
    oppClass = M.oppClass(trainer and (trainer.classId or trainer.class), trainer),
    partyIndex = trainer and (trainer.memberId or trainer.index or 1) or 1,
    stadiumBoss = (not gold.wild and BOSS_CLASSES[classKey(trainer)] == true) or false,
    player = battlerWrap(gold.player, true),
    enemy = battlerWrap(gold.enemy, false),
    data = gold.data,
    phase = "intro",
    current = nil,
    msgHold = false,
    sendingOut = true,
    enemySendingOut = true,
    _sendTimer = .55,
  }
  -- The original announcer's idle-decision detector expects its BattleState
  -- object to be the stack top. Gold uses a separate pure-logic Battle plus a
  -- UI BattleState, so present a tiny read-only stack proxy that says exactly
  -- that without touching the real game stack.
  b.game = {
    input = currentGame and currentGame.input,
    stack = { top = function() return b end },
  }
  announcerBattle = b

  if M.announcerEnabled() and Announcer and Announcer.beginBattle then
    pcall(Announcer.beginBattle, b)
  end
  if M.announcerEnabled() and announcerScopeAllows(gold) then
    captionText(gold.wild and ("A wild " .. monName(gold.enemy) .. " appeared!")
      or ("Battle against " .. tostring(
        trainer and (trainer.name or trainer.classId or trainer.class) or "Trainer") .. "!"),
      90, 2.2)
  end
end

local function wrapperFor(mon)
  if not announcerBattle then return battlerWrap(mon, false) end
  if activeGoldBattle and mon == activeGoldBattle.player then return announcerBattle.player end
  if activeGoldBattle and mon == activeGoldBattle.enemy then return announcerBattle.enemy end
  return battlerWrap(mon, false)
end

local function updateAnnouncer(dt, game)
  if Storage and Storage.setGame then pcall(Storage.setGame, game) end
  currentGame = game or currentGame
  startCaches()
  stepCaches()

  if Announcer and Announcer.cachePending and Announcer.cachePending() then
    pcall(Announcer.beginCache, false)
  end

  if announcerBattle then
    local b = announcerBattle
    local step = math.max(0, tonumber(dt) or 0)
    b._animTimer = math.max(0, (b._animTimer or 0) - step)
    b._sendTimer = math.max(0, (b._sendTimer or 0) - step)
    if b.game then b.game.input = (game and game.input) or b.game.input end
    -- Drain timers are second-based; sync uses the real dt below.
    for _, side in ipairs({ "player", "enemy" }) do
      local wrap = b[side]
      wrap._drainTimer = math.max(0, (tonumber(wrap._drainTimer) or 0) - step)
      wrap.draining = wrap._drainTimer > 0
    end
    syncAnnouncerBattle()
    if M.announcerEnabled() and Announcer and Announcer.update then
      pcall(Announcer.update, dt, b.game)
    end
  end

  if caption.t > 0 then
    caption.t = math.max(0, caption.t - (tonumber(dt) or 0))
    if caption.t <= 0 then caption.text, caption.priority = nil, 0 end
  end
end

local function drawCaption()
  if not (caption.text and caption.t > 0 and M.announcerEnabled()
      and on("stadiumAnnouncerCaptions", true)
      and announcerScopeAllows(activeGoldBattle)) then return end
  local g = love and love.graphics
  if not g then return end
  local w = g.getWidth and g.getWidth() or 160
  local alpha = math.min(1, caption.t * 2.5)
  local text = caption.text
  local font = g.getFont and g.getFont() or nil
  local tw = font and font.getWidth and font:getWidth(text) or #text * 6
  local x = math.max(6, math.floor((w - tw) * .5))
  local y = 7
  g.setColor(0, 0, 0, .62 * alpha)
  g.rectangle("fill", x - 6, y - 3, tw + 12,
    (font and font:getHeight() or 12) + 6, 4, 4)
  g.setColor(1, 1, 1, alpha)
  g.print(text, x, y)
  g.setColor(1, 1, 1, 1)
end

local function fxCombatant(mon)
  return { mon=mon, isPlayer=(activeGoldBattle and mon == activeGoldBattle.player) and true or false }
end

local function fxPayload(payload)
  if type(payload) ~= "table" then return payload end
  local p = {}
  for k,v in pairs(payload) do p[k]=v end
  p.user = payload.user and fxCombatant(payload.user) or nil
  p.target = payload.target and fxCombatant(payload.target) or nil
  p.battler = payload.battler and fxCombatant(payload.battler) or nil
  p.move = sourceMoveRecord(payload.move, payload.moveId)
  return p
end

local function ensureSourcePlayer()
  if sourcePlayer or not SourceFxPlayerClass or type(SourceFxPlayerClass.new) ~= "function" then return sourcePlayer end
  local reporter = function(subject, reason)
    if M.fallbackNoticeEnabled() and FailureNotice and FailureNotice.show then
      pcall(FailureNotice.show, subject, reason)
    end
  end
  local ok, player = pcall(SourceFxPlayerClass.new, nil,
    function() return M.enabled() and M.overlayMode() ~= "off" end,
    SourceLog, nil, nil,
    -- Current Gold BattleCinematic owns the camera. We consume the source's
    -- native selector rows through M.cameraDirective instead of starting a
    -- second camera director.
    function() return false end,
    function() return M.hitReactionsEnabled() end,
    reporter,
    function() return M.attackSpeed() end)
  if ok then sourcePlayer = player else log("warn", "Stadium source player unavailable: %s", tostring(player)) end
  return sourcePlayer
end

local function updateSourcePlayer()
  local player = ensureSourcePlayer()
  if not (player and player.custom and type(player.update) == "function") then return end
  local ok, err = pcall(player.update, player)
  if not ok then
    log("warn", "Stadium source player update failed: %s", tostring(err))
    if M.fallbackNoticeEnabled() and FailureNotice and FailureNotice.show then
      pcall(FailureNotice.show, "STADIUM FX", err)
    end
    pcall(player.release, player)
  end
end

local function installEvents()
  local events = mod and mod.events
  if not (events and type(events.on) == "function") then return end

  events:on("battle.started", function(payload)
    beginAnnouncer(payload and payload.battle)
  end)

  events:on("battle.move_used", function(payload)
    if not (activeGoldBattle and payload and payload.battle == activeGoldBattle) then return end
    local fx = ensureSourcePlayer()
    if fx and type(fx.setMoveContext) == "function" then pcall(fx.setMoveContext, fx, fxPayload(payload)) end
    if announcerBattle then
      announcerBattle.animName = payload.move and payload.move.id or payload.moveId
      announcerBattle.animPlaying = true
      announcerBattle._animTimer = .70
    end
    if M.announcerEnabled() and Announcer and Announcer.moveUsed and announcerBattle then
      local p = {}
      for k, v in pairs(payload) do p[k] = v end
      p.battle = announcerBattle
      p.user = wrapperFor(payload.user)
      p.target = wrapperFor(payload.target)
      p.move = sourceMoveRecord(payload.move, payload.moveId)
      pcall(Announcer.moveUsed, p)
    end
    captionText(moveLabel(payload.move) .. "!", 25, 1.15)
  end)

  events:on("battle.damage_dealt", function(payload)
    if not (activeGoldBattle and payload and payload.battle == activeGoldBattle) then return end
    local fx = ensureSourcePlayer()
    if fx and type(fx.recordDamage) == "function" then pcall(fx.recordDamage, fx, fxPayload(payload)) end
    if announcerBattle then
      local p = {}
      for k, v in pairs(payload) do p[k] = v end
      p.battle = announcerBattle
      p.target = wrapperFor(payload.target)
      -- Hold the "HP is draining" presentation edge across the next announcer
      -- update so its original damageReady gate sees Gold's UI-like beat.
      p.target._drainTimer = math.max(tonumber(p.target._drainTimer) or 0, .12)
      p.target.draining = true
      if M.announcerEnabled() and Announcer and Announcer.damageDealt then
        pcall(Announcer.damageDealt, p)
      end
    end
    local mult = tonumber(payload.typeMult)
    if payload.crit then captionText("A critical hit!", 50, 1.45)
    elseif mult and mult > 10 then captionText("It's super effective!", 45, 1.35)
    elseif mult and mult < 10 then captionText("It's not very effective...", 40, 1.35) end
  end)

  events:on("battle.status_inflicted", function(payload)
    if not (activeGoldBattle and payload and payload.battle == activeGoldBattle) then return end
    if announcerBattle and M.announcerEnabled()
        and Announcer and Announcer.statusInflicted then
      local p = {}
      for k, v in pairs(payload) do p[k] = v end
      p.battle = announcerBattle
      p.target = wrapperFor(payload.target)
      pcall(Announcer.statusInflicted, p)
    end
    captionText(monName(payload.target) .. " is "
      .. tostring(payload.status or "affected") .. "!", 55, 1.5)
  end)

  events:on("battle.battler_switched", function(payload)
    if not (activeGoldBattle and payload and payload.battle == activeGoldBattle) then return end
    syncAnnouncerBattle()
    if announcerBattle then
      local battler = wrapperFor(payload.battler)
      if battler == announcerBattle.player then
        announcerBattle.sendingOut = true
      elseif battler == announcerBattle.enemy then
        announcerBattle.enemySendingOut = true
      end
      announcerBattle._sendTimer = .48
      if M.announcerEnabled() and Announcer and Announcer.battlerSwitched then
        local p = {}
        for k, v in pairs(payload) do p[k] = v end
        p.battle = announcerBattle
        p.battler = battler
        if payload.previous then p.previous = wrapperFor(payload.previous) end
        pcall(Announcer.battlerSwitched, p)
      end
    end
  end)

  events:on("battle.fainted", function(payload)
    if not (activeGoldBattle and payload and payload.battle == activeGoldBattle) then return end
    if announcerBattle and M.announcerEnabled() and Announcer and Announcer.fainted then
      local p = {}
      for k, v in pairs(payload) do p[k] = v end
      p.battle = announcerBattle
      p.battler = wrapperFor(payload.battler)
      p.battler.shownHP, p.battler.fainted = 0, true
      pcall(Announcer.fainted, p)
    end
    captionText(monName(payload.battler) .. " is down!", 80, 1.85)
  end)

  events:on("battle.ended", function(payload)
    if activeGoldBattle and payload and payload.battle == activeGoldBattle then
      if announcerBattle and M.announcerEnabled()
          and Announcer and Announcer.finishBattle then
        local p = {}
        for k, v in pairs(payload) do p[k] = v end
        p.battle = announcerBattle
        p.result = payload.result or payload.outcome or activeGoldBattle.outcome
        pcall(Announcer.finishBattle, p)
      end
      local result = payload.result or payload.outcome or activeGoldBattle.outcome
      if result == "win" then captionText("Victory!", 90, 2.0) end
    end
    if sourcePlayer and type(sourcePlayer.release) == "function" then pcall(sourcePlayer.release, sourcePlayer) end
    if ScreenFx and ScreenFx.clear then pcall(ScreenFx.clear) end
    activeGoldBattle, announcerBattle = nil, nil
  end)
end

-- ----- Source move presentation -----------------------------------------------------
--
-- This clock is deliberately independent of Gold's mutable AnimRunner object.
-- Gold is still the battle authority; StadiumBattleFX only owns presentation.
screenPulse = {
  spec = nil, side = "player", t = 0, duration = 1, impact = .55, token = 0,
}
local sourceFxCanvas

function M.noteMove(move, def, side)
  local spec = M.moveSpec(move, def)
  if not spec then return false end
  local duration, impact = M.timing(spec, 52)
  if not duration then
    screenPulse.spec = nil
    return false
  end
  screenPulse.token = screenPulse.token + 1
  screenPulse.spec = spec
  screenPulse.side = side == "enemy" and "enemy" or "player"
  screenPulse.t = 0
  screenPulse.duration = duration / 60
  screenPulse.impact = (impact or 30) / 60
  local player = ensureSourcePlayer()
  if player and type(player.start) == "function" then
    local okStart, err = pcall(player.start, player, spec.id, screenPulse.side == "player")
    if not okStart then log("warn", "Stadium source move start failed for %s: %s", tostring(spec.key), tostring(err)) end
  end
  return true
end

function M.updateScreenFx(dt)
  if screenPulse.spec then
    screenPulse.t = screenPulse.t + (tonumber(dt) or 0)
    if screenPulse.t > screenPulse.duration + .22 then screenPulse.spec = nil end
  end
end

function M.activeMove()
  if not screenPulse.spec then return nil end
  return {
    spec = screenPulse.spec,
    side = screenPulse.side,
    tick = (sourcePlayer and sourcePlayer.custom and tonumber(sourcePlayer.tick)) or (screenPulse.t * 60 * math.max(0.01, M.attackSpeed())),
    duration = screenPulse.duration * 60,
    impact = screenPulse.impact * 60,
    token = screenPulse.token,
  }
end

local NATIVE_SELECTOR_GROUPS = {
  [20]={0,3,2,6,7}, [21]={0,2,6,7}, [22]={2,6,7},
  [23]={4,5,8,9,10,11}, [24]={5,9,10,11},
}
local NATIVE_SELECTOR_SHOTS = {
  [0]={subject="attacker",orbit=0,elevation=0}, [1]={subject="attacker",orbit=0,elevation=0},
  [2]={subject="attacker",orbit=-math.rad(70),elevation=0},
  [3]={subject="attacker",orbit=0,elevation=math.rad(20)},
  [4]={subject="center",orbit=-math.rad(80),elevation=0},
  [5]={subject="center",orbit=0,elevation=math.rad(60)},
  [6]={subject="attacker",orbit=-math.rad(30),elevation=math.rad(10)},
  [7]={subject="attacker",orbit=-math.rad(30),elevation=0},
  [8]={subject="center",orbit=-math.rad(80),elevation=0},
  [9]={subject="center",orbit=-math.rad(80),elevation=0},
  [10]={subject="center",orbit=-math.rad(90),elevation=math.rad(40)},
  [11]={subject="center",orbit=-math.rad(90),elevation=-math.rad(10)},
}
local function resolveNativeSelector(selector, species, move, phase)
  selector=math.floor(tonumber(selector) or 2)
  local group=NATIVE_SELECTOR_GROUPS[selector]
  if not group then return selector end
  local seed=(tonumber(species) or 0)*257+(tonumber(move) or 0)*17+(tonumber(phase) or 0)*13
  return group[(seed % #group)+1]
end
local function nativeCameraSegments(spec, side)
  if not (M.nativeSyncEnabled() and spec) then return nil end
  local sync=M.nativeMoveSync(side or "player", spec.id)
  if type(sync)~="table" or sync.byte_0D==nil or sync.byte_0E==nil then return nil end
  local first=resolveNativeSelector(sync.byte_0D,sync.species,spec.id,1)
  local second=resolveNativeSelector(sync.byte_0E,sync.species,spec.id,2)
  local a=NATIVE_SELECTOR_SHOTS[first] or NATIVE_SELECTOR_SHOTS[2]
  local segments={{at=0,subject=a.subject,zoom=1.18,orbit=a.orbit,elevation=a.elevation,selector=first,rawSelector=sync.byte_0D}}
  if tonumber(sync.byte_0E) ~= 25 then
    local delay=tonumber(sync.byte_0F) or 0; if delay==0 then delay=15 end
    local b=NATIVE_SELECTOR_SHOTS[second] or NATIVE_SELECTOR_SHOTS[2]
    segments[#segments+1]={at=delay,subject=b.subject,zoom=1.18,orbit=b.orbit,elevation=b.elevation,selector=second,rawSelector=sync.byte_0E}
  end
  return segments, math.max(tonumber(spec.duration) or 52, (segments[#segments].at or 0)+18), "native", sync
end

local function cameraSegments(spec)
  local impact = math.max(12, tonumber(spec and spec.impactAt) or 38)
  local duration = math.max(impact + 12, tonumber(spec and spec.duration) or impact + 34)
  local profile = spec and spec.cinematic or "ranged"
  local segments
  if profile == "melee" then
    segments = {
      { at=0, subject="attacker", zoom=.72, orbit=-.035 },
      { at=impact*.52, subject="center", zoom=.88, orbit=.025 },
      { at=impact, subject="target", zoom=.66, shake=1 },
      { at=impact+16, subject="center", zoom=.90 },
    }
  elseif profile == "combo" then
    segments = {
      { at=0, subject="attacker", zoom=.76 },
      { at=impact*.55, subject="center", zoom=.88 },
      { at=impact, subject="target", zoom=.69, shake=1 },
      { at=impact+10, subject="center", zoom=.82, shake=.6 },
      { at=impact+20, subject="target", zoom=.65, shake=1 },
    }
  elseif profile == "sustained" then
    segments = {
      { at=0, subject="attacker", zoom=.68, orbit=-.025 },
      { at=impact*.40, subject="center", zoom=.80 },
      { at=impact, subject="target", zoom=.67, shake=.45 },
      { at=impact+22, subject="center", zoom=.86 },
    }
  elseif profile == "aerial" then
    segments = {
      { at=0, subject="attacker", zoom=.70 },
      { at=impact*.42, subject="wide", zoom=1.08, orbit=.075 },
      { at=impact, subject="target", zoom=.62, shake=1 },
      { at=impact+18, subject="center", zoom=.92 },
    }
  elseif profile == "field" then
    segments = {
      { at=0, subject="wide", zoom=1.10, orbit=.04 },
      { at=impact*.62, subject="center", zoom=.92 },
      { at=impact, subject="target", zoom=.76, shake=.8 },
      { at=impact+20, subject="wide", zoom=1.04 },
    }
  elseif profile == "status" then
    segments = {
      { at=0, subject="attacker", zoom=.74, orbit=-.02 },
      { at=impact, subject=(spec.anchor == "attacker" and "attacker" or "target"), zoom=.68 },
      { at=impact+22, subject="center", zoom=.90 },
    }
  elseif profile == "self" then
    segments = {
      { at=0, subject="attacker", zoom=.66, orbit=-.035 },
      { at=impact+16, subject="attacker", zoom=.72, orbit=.025 },
      { at=duration-14, subject="center", zoom=.90 },
    }
  elseif profile == "explosion" then
    segments = {
      { at=0, subject="attacker", zoom=.68 },
      { at=impact*.72, subject="wide", zoom=1.24, shake=1 },
      { at=impact+18, subject="target", zoom=.73, shake=.7 },
      { at=duration-18, subject="center", zoom=.96 },
    }
  else
    segments = {
      { at=0, subject="attacker", zoom=.72, orbit=-.025 },
      { at=impact*.44, subject="center", zoom=.88, orbit=.02 },
      { at=impact, subject="target", zoom=.68, shake=.55 },
      { at=impact+18, subject="center", zoom=.90 },
    }
  end
  return segments, duration, profile
end

local function externalAttackCameraClaimed()
  if not (mod and type(mod.find)=="function") then return false end
  local ok, found = pcall(mod.find, mod, "BATTLE_CINEMATICS")
  if not ok or found == nil then ok, found = pcall(mod.find, "BATTLE_CINEMATICS") end
  local query = found and found.exports and found.exports.cameraOwnership
  if type(query) ~= "function" then return false end
  local okOwn, ownership = pcall(query)
  if not okOwn or type(ownership) ~= "table" or ownership.protocol ~= 1 then return false end
  return type(ownership.claims)=="table" and ownership.claims.attack==true
end

function M.cameraDirective()
  if not (M.attackCameraEnabled() and screenPulse.spec) then return nil end
  if externalAttackCameraClaimed() then return nil end
  local spec = screenPulse.spec
  local segments, duration, profile, nativeSync = nativeCameraSegments(spec, screenPulse.side)
  if not segments then segments, duration, profile = cameraSegments(spec) end
  local tick = (sourcePlayer and sourcePlayer.custom and tonumber(sourcePlayer.tick))
    or (screenPulse.t * 60 * math.max(0.01, M.attackSpeed()))
  if tick >= duration then return nil end
  local index = 1
  for i = 2, #segments do
    if tick < segments[i].at then break end
    index = i
  end
  local cur = segments[index]
  local prev = index > 1 and segments[index - 1] or cur
  local blend = index > 1 and math.max(0, math.min(1, (tick - cur.at) / 4)) or 1
  blend = blend * blend * (3 - 2 * blend)
  local function mix(a, b)
    a, b = tonumber(a) or 0, tonumber(b) or tonumber(a) or 0
    return a + (b - a) * blend
  end
  return {
    profile = SourceCinematics and SourceCinematics.profileFor
      and SourceCinematics.profileFor(spec) or profile,
    subject = blend < .5 and prev.subject or cur.subject,
    zoom = mix(prev.zoom or 1, cur.zoom or prev.zoom or 1),
    orbit = mix(prev.orbit or 0, cur.orbit or prev.orbit or 0),
    elevation = mix(prev.elevation or 0, cur.elevation or prev.elevation or 0),
    shake = mix(prev.shake or 0, cur.shake or prev.shake or 0),
    nativeSync = nativeSync,
    nativeSelector = cur.selector,
    attackerSide = screenPulse.side,
    tick = tick,
    impact = tonumber(spec.impactAt) or screenPulse.impact * 60,
    duration = duration,
    moveId = tonumber(spec.id) or 0,
    compatibilityZoom = M.cinematicZoom(),
  }
end

local function sourceFrameRect(viewport)
  local shot
  if V and type(V.require) == "function" then
    local ok, ow = pcall(V.require, "OverworldBattle")
    if ok and ow and type(ow.shot) == "function" then
      local ok2, got = pcall(ow.shot)
      if ok2 then shot = got end
    end
  end
  if shot and shot.scale and shot.scale > 0 then
    return shot.lx or 0, shot.ly or 0, shot.scale, shot
  end

  local g = love and love.graphics
  if not g then return nil end
  local ww = viewport and viewport.width or (g.getWidth and g.getWidth() or 160)
  local wh = viewport and viewport.height or (g.getHeight and g.getHeight() or 144)
  local gw = viewport and viewport.gameWidth
  local gh = viewport and viewport.gameHeight
  local scale = viewport and viewport.scale
  if not (tonumber(scale) and scale > 0) then
    scale = math.min((tonumber(gw) or ww) / 160, (tonumber(gh) or wh) / 144)
  end
  local x = viewport and viewport.gameX
  local y = viewport and viewport.gameY
  if x == nil then x = (ww - 160 * scale) * .5 end
  if y == nil then y = (wh - 144 * scale) * .5 end
  return x, y, scale, nil
end

local function ensureSourceCanvas()
  if sourceFxCanvas or not (love and love.graphics and love.graphics.newCanvas) then
    return sourceFxCanvas
  end
  local ok, canvas = pcall(love.graphics.newCanvas, 160, 144)
  if ok and canvas then
    pcall(canvas.setFilter, canvas, "nearest", "nearest")
    sourceFxCanvas = canvas
  end
  return sourceFxCanvas
end

local function sourceAnchors(shot)
  local player = shot and shot.player or { 48, 103 }
  local enemy = shot and shot.enemy or { 112, 56 }
  return {
    player = { tonumber(player[1]) or 48, (tonumber(player[2]) or 103) - 10 },
    enemy = { tonumber(enemy[1]) or 112, (tonumber(enemy[2]) or 56) - 10 },
  }
end

function M.drawSourceOverlay(viewport, game)
  local mode = M.overlayMode()
  if mode == "off" or not screenPulse.spec then return false end
  if not (love and love.graphics) then return false end

  local x, y, scale, shot = sourceFrameRect(viewport)
  if not x then return false end
  local canvas = ensureSourceCanvas()
  if not canvas then return false end

  if Assets and Assets.ready and Assets.ready() and not sourceAssetsPreloaded
      and Assets.preload then
    pcall(Assets.preload)
    sourceAssetsPreloaded = true
  end

  local g = love.graphics
  local prevCanvas = g.getCanvas and g.getCanvas() or nil
  local player = ensureSourcePlayer()
  local spec = screenPulse.spec
  local kind = tostring(spec.kind or "generic")
  local useFullPlayer = player and player.custom and M.nativeSchedulerEnabled()
    and (mode == "all" or kind ~= "generic")
  local drew = false
  local okDraw, err = pcall(function()
    g.push("all")
    g.origin()
    g.setCanvas(canvas)
    g.clear(0,0,0,0)
    g.setBlendMode("alpha")
    g.setColor(1,1,1,1)
    local video = game and game.save and game.save.options and game.save.options.videoMode
    if ScreenFx and ScreenFx.setBorderless then pcall(ScreenFx.setBorderless, video == "borderless") end

    if useFullPlayer and type(player.draw) == "function" then
      player:draw()
      drew = player.custom and true or false
    else
      -- AUTHENTIC ONLY keeps exact cartridge-textured programs but deliberately
      -- skips the source generic fallback. ALL 165 is handled by StadiumFxPlayer.
      local anchors = sourceAnchors(shot)
      local side = screenPulse.side == "enemy" and "enemy" or "player"
      local attacker = side == "player" and anchors.player or anchors.enemy
      local target = side == "player" and anchors.enemy or anchors.player
      local ctx = { spec=spec, tick=(player and player.custom and player.tick) or screenPulse.t*60,
                    attachmentPass=nil }
      function ctx:anchor(which)
        local modelSide = which == "attacker" and side or (side == "player" and "enemy" or "player")
        local tag = M.attachmentTag(spec, which)
        local okS, Stadium = pcall(V.require, "Stadium")
        if okS and Stadium and Stadium.attachment then
          local ax,ay = Stadium.attachment(modelSide, tag)
          if type(ax)=="number" and type(ay)=="number" then return ax,ay end
        end
        if which == "attacker" then return attacker[1],attacker[2] end
        if which == "target" then return target[1],target[2] end
        return (attacker[1]+target[1])*.5,(attacker[2]+target[2])*.5
      end
      if AuthenticRenderer and Assets then
        local okA,result=pcall(AuthenticRenderer.draw,ctx,Assets)
        drew=okA and result==true
      end
    end
    g.setCanvas(prevCanvas)
    g.pop()
  end)
  if not okDraw then
    pcall(g.setCanvas,prevCanvas); pcall(g.pop)
    log("warn","Stadium source overlay failed: %s",tostring(err))
    if M.fallbackNoticeEnabled() and FailureNotice and FailureNotice.show then pcall(FailureNotice.show,"STADIUM FX",err) end
    return false
  end
  if not drew then return false end
  g.setColor(1,1,1,1)
  g.draw(canvas,x,y,0,scale,scale)
  return true
end

-- Lightweight Stadium-style whole-frame emphasis layered with the cartridge
-- effect renderer. This is especially useful when no Stadium 1 ROM cache is
-- present: timing/camera/hit reactions still read from the source roster.
function M.drawScreenFx()
  if not (M.screenEffectsEnabled() and screenPulse.spec and love and love.graphics) then return end
  local spec, t = screenPulse.spec, screenPulse.t
  local d = math.max(.1, screenPulse.duration)
  local p = math.max(0, math.min(1, t / d))
  local visual, typ = normalize(spec.visual):lower(), normalize(spec.type)
  local colors = {
    FIRE={1,.18,.03}, WATER={.08,.45,1}, ELECTRIC={1,.86,.08},
    ICE={.55,.92,1}, PSYCHIC={.85,.18,1}, POISON={.55,.1,.72},
    GRASS={.16,.72,.18}, GROUND={.5,.32,.13}, ROCK={.44,.39,.28},
    GHOST={.25,.08,.45}, FLYING={.65,.85,1}, NORMAL={1,.86,.65},
    FIGHTING={1,.3,.12},
  }
  local c, g = colors[typ] or {1,1,1}, love.graphics
  local w, h = g.getDimensions()
  local env = math.sin(math.pi * math.min(1, p))
  local alpha = .025 * env
  if visual == "explosion" then alpha = .09 * env
  elseif visual == "storm" or visual == "haze" or visual == "mist" then alpha = .06 * env
  elseif visual == "psychic" or visual == "flash" then alpha = .05 * env end
  if alpha > 0 then
    g.setColor(c[1], c[2], c[3], alpha)
    g.rectangle("fill", 0, 0, w, h)
  end
  if math.abs(t - screenPulse.impact) < .045
      and (visual == "explosion" or visual == "electric"
        or visual == "flash" or visual == "impact") then
    g.setColor(1, 1, 1, .13)
    g.rectangle("fill", 0, 0, w, h)
  end
  g.setColor(1, 1, 1, 1)
end

function M.activeBattle() return activeGoldBattle end

function M.status()
  local function stat(item)
    if item and type(item.status) == "function" then
      local ok, value = pcall(item.status)
      if ok then return value end
    end
    return nil
  end
  local announcerStatus, announcerCache
  if Announcer and type(Announcer.status) == "function" then
    local ok, value = pcall(Announcer.status)
    if ok and type(value) == "table" then announcerStatus = value end
  end
  if Announcer and type(Announcer.cacheStatus) == "function" then
    local ok, value = pcall(Announcer.cacheStatus)
    if ok and type(value) == "table" then announcerCache = value end
  end
  local active = M.activeMove()
  local spec = active and active.spec
  return {
    installed = installed,
    sourceVersion = "2.1.7",
    enabled = M.enabled(),
    moveSpecs = MoveSpecs and #(MoveSpecs.list or {}) or 0,
    overlayMode = M.overlayMode(),
    screenEffects = M.screenEffectsEnabled(),
    attackCamera = M.attackCameraEnabled(),
    attackSpeed = M.attackSpeed(),
    cinematicZoom = M.cinematicZoom(),
    hitReactions = M.hitReactionsEnabled(),
    faintAnimations = M.faintAnimationsEnabled(),
    bossArenas = M.bossArenasEnabled(),
    bossVenue = M.bossVenue(),
    trainerPortraitsEnabled = M.portraitsEnabled(),
    announcerEnabled = M.announcerEnabled(),
    announcerScope = tostring(option("stadiumAnnouncerScope", "gym") or "gym"),
    announcerCaptions = on("stadiumAnnouncerCaptions", true),
    nativeScheduler = M.nativeSchedulerEnabled(),
    nativeSync = M.nativeSyncEnabled(),
    fallbackNotice = M.fallbackNoticeEnabled(),
    nativeModelCache = ModelInstall and ModelInstall.status or nil,
    sourcePlayer = sourcePlayer and { custom=sourcePlayer.custom and true or false, tick=sourcePlayer.tick,
      kind=sourcePlayer.spec and sourcePlayer.spec.kind, nativeBirths=sourcePlayer.nativeBirths and #sourcePlayer.nativeBirths or 0 } or nil,
    announcer = announcerStatus,
    announcerCache = announcerCache,
    -- The public StadiumBattleFX source/release is deliberately voice-free.
    -- A local personalized pack may still be detected through announcerCache.
    announcerVoicePackBundled = false,
    announcerVoicePackInstalled = announcerCache and announcerCache.installed or false,
    effectAssets = stat(Assets),
    arenaAssets = stat(ArenaAssets),
    trainerPortraitCache = stat(Portraits),
    activeMove = spec and {
      id = spec.id, key = spec.key, name = spec.name,
      visual = spec.visual, delivery = spec.delivery,
      cinematic = spec.cinematic, tick = active.tick, duration = active.duration,
    } or nil,
  }
end

function M.audit()
  return {
    sourceVersion="2.1.7", copiedLuaModules=77,
    activeSystems={
      announcer=true, moveRoster=true, authenticRenderer=true, genericRenderer=true,
      dedicatedMoveRenderers=SourceFxPlayerClass~=nil, nativeScheduler=NativeInterpreter~=nil,
      thunderShock=ThunderShockSpec~=nil, nativeAttachmentCameraCache=ModelInstall~=nil and StadiumPack~=nil,
      screenFx=ScreenFx~=nil, attackCinematics=SourceCinematics~=nil,
      trainerPortraits=Portraits~=nil, bossArenas=ArenaAssets~=nil,
      diagnostics=SourceLog~=nil, fallbackNotice=FailureNotice~=nil,
    },
    intentionalBackendReplacements={
      "StadiumBattleFX Stadium1 model renderer -> existing Stadium2 251-species renderer",
      "embedded Gen1-only Stadium2 importer -> existing Gold-aware Stadium2 importer",
      "BattleHost/provider ownership -> combined mod live-world battle compositor",
      "portable ordinary arena themes -> encounter-site live overworld arenas",
      "BattleArt/PotatoVoxel external compatibility -> unnecessary inside combined renderer",
    },
  }
end

local function installActionRows()
  if not (mod and mod.hooks and type(mod.hooks.wrap)=="function") then return end
  mod.hooks:wrap("ui.options.rows", function(next, game, rows)
    local out=next(game,rows)
    if type(out)~="table" then return out end
    out[#out+1]={ id="STADIUM2_OVERWORLD_MODELS:stadiumFxRebuild", label="REBUILD STADIUM FX CACHE",
      value=function()
        local states={ Assets and Assets.status and Assets.status().state,
          ArenaAssets and ArenaAssets.status and ArenaAssets.status().state,
          Portraits and Portraits.status and Portraits.status().state,
          modelInstallState(), Announcer and Announcer.cacheStatus and Announcer.cacheStatus().state }
        for _,state in ipairs(states) do if state=="building" then return "BUILDING" end end
        return "REBUILD"
      end,
      activate=function() M.rebuildCaches(); return true end }
    out[#out+1]={ id="STADIUM2_OVERWORLD_MODELS:stadiumFxAnnouncerTest", label="TEST STADIUM ANNOUNCER",
      value=function()
        local status=M.announcerImportStatus()
        if status.state=="building" then return "BUILDING" end
        if status.state=="failed" then return "ERROR" end
        return status.ready and "PLAY" or "IMPORT S1"
      end,
      activate=function()
        M.testAnnouncerVoice(223)
        return true
      end }
    if SourceLogExport and type(SourceLogExport.row)=="function" then
      local ok,row=pcall(SourceLogExport.row)
      if ok and type(row)=="table" then out[#out+1]=row end
    end
    return out
  end)
end

function M.install()
  if installed then return true end
  installPortraitBridge()
  installEvents()
  if mod and mod.hooks and type(mod.hooks.wrap)=="function" then
    mod.hooks:wrap("input.step", function(next, game, dt)
      local out={next(game,dt)}
      updateAnnouncer(dt,game); M.updateScreenFx(dt); updateSourcePlayer()
      if FailureNotice and FailureNotice.update then pcall(FailureNotice.update,dt) end
      return unpack(out)
    end)
    mod.hooks:wrap("render.hud", function(next, game, viewport)
      -- Anchored source move graphics stay behind the HUD. Stadium's recorded
      -- screen-wide operations are replayed after composition exactly like the
      -- original mod so borderless margins are covered too.
      local sourceDrew = M.drawSourceOverlay(viewport,game)
      if not sourceDrew then M.drawScreenFx() end
      local out={next(game,viewport)}
      if M.screenEffectsEnabled() and ScreenFx and ScreenFx.present then pcall(ScreenFx.present,game,viewport)
      elseif ScreenFx and ScreenFx.clear then pcall(ScreenFx.clear) end
      if M.fallbackNoticeEnabled() and FailureNotice and FailureNotice.draw then pcall(FailureNotice.draw,viewport) end
      drawCaption()
      return unpack(out)
    end)
  end
  installActionRows()
  ensureSourcePlayer()
  startCaches()
  installed=true
  log("info","StadiumBattleFX 2.1.7 source-calibrated Gold integration installed (%d Gen-1 move specs)", MoveSpecs and #(MoveSpecs.list or {}) or 0)
  return true
end

M.source = ns
M.MoveSpecs = MoveSpecs
M.Assets = Assets
M.ArenaAssets = ArenaAssets
M.Portraits = Portraits
M.Announcer = Announcer
M.AuthenticRenderer = AuthenticRenderer
M.GenericRenderer = GenericRenderer
M.ScreenFx = ScreenFx
M.SourceCinematics = SourceCinematics
M.SourceFxPlayer = SourceFxPlayerClass
M.NativeInterpreter = NativeInterpreter
M.ThunderShockSpec = ThunderShockSpec
M.ModelInstall = ModelInstall
M.StadiumPack = StadiumPack
M.FailureNotice = FailureNotice
M.SourceLog = SourceLog
return M
