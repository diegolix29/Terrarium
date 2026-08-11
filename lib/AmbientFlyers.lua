-- Ambient sky Pokemon for the Gen-2 voxel overworld.
--
-- These are presentation-only entities. They never enter Gold's gameplay
-- world.entities / world.npcs arrays, never collide, never start battles, and
-- never touch encounter RNG. GoldVoxelBridge asks visibleEntities() for them
-- and merges them into the voxel/Stadium render scene only.
local V = ...
local mod = V and V.mod
local M = { installed = false, version = "1.0" }

local state = {
  entities = {},
  mapId = nil,
  timeBucket = nil,
  clock = 0,
  rng = 1,
  spawnSerial = 0,
  hookInstalled = false,
  updateAccum = 0,
  skippedTicks = 0,
  updateTicks = 0,
}
M.state = state

local AERIAL = {
  BUTTERFREE=true, BEEDRILL=true,
  PIDGEY=true, PIDGEOTTO=true, PIDGEOT=true,
  SPEAROW=true, FEAROW=true,
  ZUBAT=true, GOLBAT=true, CROBAT=true,
  VENOMOTH=true, FARFETCHD=true, SCYTHER=true,
  AERODACTYL=true, DRAGONITE=true,
  HOOTHOOT=true, NOCTOWL=true,
  LEDYBA=true, LEDIAN=true,
  HOPPIP=true, SKIPLOOM=true, JUMPLUFF=true,
  TOGETIC=true, NATU=true, XATU=true,
  YANMA=true, MURKROW=true, GLIGAR=true,
  DELIBIRD=true, MANTINE=true, SKARMORY=true,
}

local LEGENDARY = {
  ARTICUNO=true, ZAPDOS=true, MOLTRES=true, MEWTWO=true, MEW=true,
  RAIKOU=true, ENTEI=true, SUICUNE=true, LUGIA=true, HO_OH=true, CELEBI=true,
}

local NOCTURNAL = {
  ZUBAT=true, GOLBAT=true, CROBAT=true,
  HOOTHOOT=true, NOCTOWL=true, MURKROW=true,
}

local DAYLIGHT = {
  BUTTERFREE=true, BEEDRILL=true,
  PIDGEY=true, PIDGEOTTO=true, PIDGEOT=true,
  SPEAROW=true, FEAROW=true,
  LEDYBA=true, LEDIAN=true, YANMA=true,
}

local FALLBACK = {
  forest = {
    day={"BUTTERFREE","BEEDRILL","LEDYBA","LEDIAN","PIDGEY","FARFETCHD","YANMA"},
    night={"HOOTHOOT","NOCTOWL","ZUBAT","GOLBAT","CROBAT","MURKROW"},
  },
  mountain = {
    day={"SPEAROW","FEAROW","GLIGAR","SKARMORY","ZUBAT"},
    night={"ZUBAT","GOLBAT","CROBAT","GLIGAR","NOCTOWL","MURKROW"},
  },
  coast = {
    day={"PIDGEY","PIDGEOTTO","SPEAROW","FEAROW","MANTINE"},
    night={"HOOTHOOT","NOCTOWL","MURKROW","ZUBAT","MANTINE"},
  },
  ruins = {
    day={"NATU","XATU","TOGETIC","PIDGEY"},
    night={"NATU","XATU","HOOTHOOT","NOCTOWL","ZUBAT"},
  },
  cold = {
    day={"DELIBIRD","SPEAROW","FEAROW","PIDGEY"},
    night={"DELIBIRD","HOOTHOOT","NOCTOWL","ZUBAT"},
  },
  town = {
    day={"PIDGEY","PIDGEOTTO","SPEAROW","BUTTERFREE"},
    night={"HOOTHOOT","NOCTOWL","MURKROW","ZUBAT"},
  },
  route = {
    day={"PIDGEY","SPEAROW","LEDYBA","YANMA","HOPPIP","TOGETIC"},
    night={"HOOTHOOT","NOCTOWL","ZUBAT","MURKROW","CROBAT"},
  },
}

local function upper(v)
  return type(v) == "string" and v:upper():gsub("[^A-Z0-9]+", "_") or ""
end

local function opt(key, default)
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return default end
  local ok, value = pcall(options.get, options, key)
  if not ok or value == nil then return default end
  return value
end

local function enabled()
  local v = opt("ambientFlyingPokemon", true)
  return not (v == false or v == 0 or v == "0" or v == "false" or v == "off")
end

local function density()
  local v = tostring(opt("ambientFlyingDensity", "normal")):lower()
  if v ~= "low" and v ~= "high" then v = "normal" end
  return v
end

local function voxelEnabled()
  local v = opt("voxel3d", true)
  return not (v == false or v == 0 or v == "0" or v == "false" or v == "off")
end

local function performanceTier()
  local picked = tostring(opt("performancePreset", "auto")):lower()
  if picked == "auto" then
    local runtime = mod and mod.exports and mod.exports.performanceRuntime
    if runtime and type(runtime.status) == "function" then
      local ok, st = pcall(runtime.status)
      local tier = ok and st and st.adaptive and st.adaptive.adaptiveTier
      if tier == "low" or tier == "medium" or tier == "high" then picked = tier end
    end
    if picked == "auto" then picked = "medium" end
  elseif picked == "custom" then
    local r = tonumber(opt("graphicsResolution", "55")) or 55
    picked = r >= 75 and "high" or "medium"
  end
  return picked
end

local function updateInterval()
  local tier = performanceTier()
  if tier == "low" then return 1 / 20 end
  if tier == "medium" then return 1 / 30 end
  if tier == "high" then return 1 / 45 end
  return 1 / 60
end

local function liveGame()
  return (V and V.game) or (mod and mod.game)
end

local function liveWorld(game)
  game = game or liveGame()
  local base = game and (game.world or game.overworld) or nil
  local twin = V and V.TwinRegionWorld
  if twin and type(twin.excursionIsActive) == "function"
      and type(twin.ambientFlyerWorld) == "function" then
    local okActive, active = pcall(twin.excursionIsActive)
    if okActive and active then
      local okWorld, kanto = pcall(twin.ambientFlyerWorld, base)
      if okWorld and type(kanto) == "table" then return kanto end
    end
  end
  return base
end

local function hashString(s)
  local h = 5381
  s = tostring(s or "")
  for i = 1, #s do
    -- Small multiplier keeps every intermediate exactly representable by the
    -- Lua-number builds used by older LÖVE ports. This RNG is visual-only.
    h = (h * 131 + s:byte(i)) % 2147483647
  end
  if h <= 0 then h = 1 end
  return h
end

local function reseed(mapId)
  local tick = 0
  if os and os.time then
    local ok, t = pcall(os.time)
    if ok and type(t) == "number" then tick = t end
  end
  state.rng = (hashString(mapId) + (tick % 1000003) * 31 + state.spawnSerial * 7919) % 2147483647
  if state.rng <= 0 then state.rng = 1 end
end

local function rnd()
  state.rng = (state.rng * 48271) % 2147483647
  return state.rng / 2147483647
end

local function randRange(a, b)
  return a + (b - a) * rnd()
end

local function randInt(a, b)
  if b <= a then return a end
  return a + math.floor(rnd() * (b - a + 1))
end

local function timeBucket(world)
  local raw = upper(world and (world.daytime or world.timeOfDay or world.time_of_day))
  if raw:find("NITE", 1, true) or raw:find("NIGHT", 1, true) then return "night" end
  local hour = tonumber(world and (world.hour or world.currentHour))
  if hour and (hour >= 18 or hour < 6) then return "night" end
  return "day"
end

local function mapEnvironment(world)
  local map = world and world.map
  return upper(map and (map.environment or map.env or (map.def and map.def.environment)))
end

local function outdoors(world)
  local env = mapEnvironment(world)
  if env == "" then return true end
  if env:find("CAVE",1,true) or env:find("DUNGEON",1,true)
      or env:find("INDOOR",1,true) or env:find("BUILDING",1,true) then
    return false
  end
  return true
end

local function mapClass(world)
  if not outdoors(world) then return nil end
  local map = world and world.map
  local id = upper(map and map.id)
  if id == "" then return nil end

  if id:find("ILEX",1,true) or id:find("FOREST",1,true)
      or id:find("VIRIDIAN_FOREST",1,true) then return "forest" end
  if id:find("RUINS",1,true) or id:find("ALPH",1,true) then return "ruins" end
  if id:find("ICE",1,true) or id:find("SNOW",1,true) then return "cold" end
  if id:find("SEA",1,true) or id:find("OCEAN",1,true)
      or id:find("WHIRL",1,true) or id:find("CIANWOOD",1,true)
      or id:find("OLIVINE",1,true) or id:find("CINNABAR",1,true)
      or id == "ROUTE_40" or id == "ROUTE_41" then return "coast" end
  if id:find("MOUNT",1,true) or id:find("MT_",1,true)
      or id:find("BLACKTHORN",1,true) or id == "ROUTE_45" or id == "ROUTE_46"
      or id == "ROUTE_27" or id == "ROUTE_28" then return "mountain" end
  if id:find("CITY",1,true) or id:find("TOWN",1,true)
      or id:find("ISLAND",1,true) or id:find("PLATEAU",1,true) then return "town" end
  return "route"
end

local function encounterNode(game, world, mapId)
  local roots = {}
  local function root(v) if type(v) == "table" then roots[#roots + 1] = v end end
  root(world and world.encounters)
  root(game and game.data and game.data.gen2Encounters)
  root(game and game.data and game.data.encounters)
  for _, root in ipairs(roots) do
    if type(root) == "table" then
      local node = root[mapId]
      if node ~= nil then return node end
      if type(root.maps) == "table" and root.maps[mapId] ~= nil then return root.maps[mapId] end
    end
  end
  return nil
end

local function collectEncounterSpecies(node, out, seen, depth)
  if depth > 6 or type(node) ~= "table" then return end
  local raw = node.species or node.pokemonSpecies or node.pokemon
  if type(raw) == "string" then
    local sp = upper(raw)
    if AERIAL[sp] and not LEGENDARY[sp] and not seen[sp] then
      seen[sp] = true
      out[#out + 1] = sp
    end
  end
  for k, v in pairs(node) do
    if k ~= "species" and k ~= "pokemonSpecies" and k ~= "pokemon"
        and type(v) == "table" then
      collectEncounterSpecies(v, out, seen, depth + 1)
    end
  end
end

local function neighborIds(world)
  local out = {}
  local def = world and world.map and world.map.def
  local conns = def and def.connections
  if type(conns) ~= "table" then return out end
  for _, dir in ipairs({"north","south","east","west"}) do
    local conn = conns[dir]
    local id = conn and (conn.mapId or conn.map or conn.dest)
    if type(id) == "string" then out[#out + 1] = id end
  end
  return out
end

local function speciesPool(game, world)
  local map = world and world.map
  local mapId = map and map.id
  local cls = mapClass(world)
  local tod = timeBucket(world)
  if not (mapId and cls) then return {} end

  local weighted = {}
  local function add(sp, weight)
    sp = upper(sp)
    if not AERIAL[sp] or LEGENDARY[sp] then return end
    local w = math.max(1, math.floor(tonumber(weight) or 1))
    if tod == "night" and NOCTURNAL[sp] then w = w + 3 end
    if tod == "day" and DAYLIGHT[sp] then w = w + 2 end
    if tod == "day" and NOCTURNAL[sp] then w = math.max(1, math.floor(w * 0.35)) end
    for _ = 1, w do weighted[#weighted + 1] = sp end
  end

  local localSpecies = {}
  collectEncounterSpecies(encounterNode(game, world, mapId), localSpecies, {}, 0)
  for _, sp in ipairs(localSpecies) do add(sp, 7) end

  -- If the town itself has no grass table, nearby routes are the most honest
  -- source of birds/bats that would plausibly cross its skyline.
  if #localSpecies < 2 then
    for _, id in ipairs(neighborIds(world)) do
      local nearby = {}
      collectEncounterSpecies(encounterNode(game, world, id), nearby, {}, 0)
      for _, sp in ipairs(nearby) do add(sp, 3) end
    end
  end

  local fb = FALLBACK[cls] or FALLBACK.route
  for _, sp in ipairs((fb and fb[tod]) or {}) do add(sp, 2) end

  -- Rare ambience: only a small chance to put the more unusual local flyers
  -- into the draw. They still have to match the map class.
  if cls == "mountain" and rnd() < 0.18 then add("SKARMORY", 1) end
  if cls == "ruins" and rnd() < 0.15 then add("XATU", 1) end
  if cls == "coast" and rnd() < 0.18 then add("MANTINE", 1) end
  if cls == "route" and tod == "day" and rnd() < 0.10 then add("TOGETIC", 1) end

  return weighted
end

local spriteCache = {}
local function resolveSprite(species, game)
  if spriteCache[species] ~= nil then
    return spriteCache[species] or nil
  end
  local resolver = mod and mod.exports and mod.exports.resolveFollowerSprite
  if type(resolver) ~= "function" then
    spriteCache[species] = false
    return nil
  end
  local ok, def = pcall(resolver, {
    species = species, surface = "land", role = "ambient_flyer", game = game,
  })
  if not (ok and type(def) == "table" and def.image) then
    spriteCache[species] = false
    return nil
  end
  local okR, SpriteRenderer = pcall(require, "src.render.SpriteRenderer")
  if not (okR and SpriteRenderer and type(SpriteRenderer.new) == "function") then
    spriteCache[species] = false
    return nil
  end
  local wrapped = setmetatable({ id = "AMBIENT_SKY_" .. species }, { __index = def })
  local okS, sprite = pcall(SpriteRenderer.new, wrapped, "ambient_flying_pokemon")
  if okS and sprite then
    spriteCache[species] = sprite
    return sprite
  end
  spriteCache[species] = false
  return nil
end

local function mapDimensions(map)
  if not map then return 0, 0 end
  local wc = tonumber(map.widthCells or map.width)
  local hc = tonumber(map.heightCells or map.height)
  if (not wc or not hc) and type(map.def) == "table" then
    wc = wc or tonumber(map.def.widthCells or map.def.width)
    hc = hc or tonumber(map.def.heightCells or map.def.height)
  end
  return math.max(1, wc or 20) * 16, math.max(1, hc or 18) * 16
end

local function facingFromVelocity(vx, vz)
  if math.abs(vx) > math.abs(vz) then return vx >= 0 and "right" or "left" end
  return vz >= 0 and "down" or "up"
end

local function targetCount(world)
  local d = density()
  local kanto = world and world._stadiumYellowKanto == true
  local base
  if kanto then
    -- Kanto is a broad streamed presentation world and previously got zero sky
    -- Pokemon because its renderer bypassed the normal Gold entity provider.
    -- Give it a visibly active skyline while retaining performance-tier caps.
    base = d == "low" and 2 or (d == "high" and 6 or 4)
  else
    base = d == "low" and 1 or (d == "high" and 4 or 2)
  end
  local tier = performanceTier()
  if tier == "low" then base = math.min(base, kanto and 2 or 1)
  elseif tier == "medium" then base = math.min(base, kanto and 4 or 2) end
  local map = world and world.map
  local w, h = mapDimensions(map)
  local area = w * h
  if tier ~= "low" and d == "normal" and area > 240000 then
    base = math.min(kanto and 5 or 3, base + 1)
  end
  if d == "high" and area < 100000 then base = math.min(base, kanto and 4 or 3) end
  return base
end
M._targetCountForTest = targetCount

local function makeEntity(game, world, species, index)
  local p = world and world.player
  local map = world and world.map
  if not (p and map) then return nil end
  local w, h = mapDimensions(map)
  if w < 64 or h < 64 then return nil end

  local radius = math.min(math.max(72, math.min(w, h) * 0.32), 180)
  local angle = randRange(0, math.pi * 2)
  local px = math.max(12, math.min(w - 12, (tonumber(p.px) or p.cellX * 16) + math.cos(angle) * radius))
  local py = math.max(12, math.min(h - 12, (tonumber(p.py) or p.cellY * 16) + math.sin(angle) * radius))
  local heading = randRange(0, math.pi * 2)
  local speed = randRange(11, 24)
  local baseAlt = randRange(28, 58)
  local sprite = resolveSprite(species, game)

  local e = {
    id = "ambient_sky_" .. tostring(index) .. "_" .. species,
    passable = true,
    ambientFlyingPokemon = true,
    _ambientFlyingPokemon = true,
    ambientSpecies = species,
    species = species,
    sprite = sprite,
    spriteDef = sprite and sprite.def or nil,
    px = px, py = py,
    cellX = math.floor(px / 16), cellY = math.floor(py / 16),
    facing = facingFromVelocity(math.cos(heading), math.sin(heading)),
    heading = heading,
    speed = speed,
    baseAltitude = baseAlt,
    altitude = baseAlt,
    phaseOffset = randRange(0, math.pi * 2),
    turnTimer = randRange(2.5, 7.0),
    turnBias = randRange(-0.16, 0.16),
    -- Dedicated Stadium airborne metadata.  Do not impersonate the player's
    -- mount: ambient flyers must not inherit MOUNT RENDERER=2D or any mount
    -- teardown/purge rules. OverworldStadium recognizes these fields only in
    -- its presentation path.
    _ambientFlyingScale = randRange(0.82, 1.02),
    _ambientFlyingAnimTime = 0,
    _ambientFlyingClimb = 0,
    _ambientFlyingBank = 0,
    worldRenderer = (V and V.voxelHostId) or "DRAMATIC_SHAPE",
    voxelDisabled = false,
    voxelRegistered = true,
    voxelUpdateOk = true,
    render2DFallback = sprite ~= nil,
    stadiumModel = true,
  }
  e.pose = function(self)
    local phase = math.floor((state.clock * 5 + self.phaseOffset) % 2)
    return self.sprite, self.px, self.py - (self.altitude or self.baseAltitude or 0),
      self.facing, phase, false, false
  end
  local ow = V and V.OverworldStadium
  if ow and type(ow.tag) == "function" then pcall(ow.tag, e, species) end
  return e
end

local function clearEntities()
  local ow = V and V.OverworldStadium
  if ow and type(ow.untag) == "function" then
    for _, e in ipairs(state.entities) do pcall(ow.untag, e) end
  end
  state.entities = {}
end

local function spawnForWorld(game, world)
  clearEntities()
  if not enabled() or not mapClass(world) then
    state.mapId = world and world.map and world.map.id or nil
    state.timeBucket = timeBucket(world)
    return 0
  end
  local mapId = world.map and world.map.id
  state.spawnSerial = state.spawnSerial + 1
  reseed(mapId)
  local pool = speciesPool(game, world)
  if #pool == 0 then
    state.mapId = mapId
    state.timeBucket = timeBucket(world)
    return 0
  end

  local count = targetCount(world)
  local used = {}
  for i = 1, count do
    local species
    for _ = 1, 8 do
      local candidate = pool[randInt(1, #pool)]
      if not used[candidate] or #pool < count * 2 then species = candidate break end
    end
    species = species or pool[randInt(1, #pool)]
    used[species] = true
    local e = makeEntity(game, world, species, i)
    if e then state.entities[#state.entities + 1] = e end
  end
  state.mapId = mapId
  state.timeBucket = timeBucket(world)
  return #state.entities
end

local function atan2(y, x)
  if math.atan2 then return math.atan2(y, x) end
  if x > 0 then return math.atan(y / x) end
  if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
  if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
  if x == 0 and y > 0 then return math.pi / 2 end
  if x == 0 and y < 0 then return -math.pi / 2 end
  return 0
end

local function turnToward(e, target, maxStep)
  local d = target - e.heading
  while d > math.pi do d = d - math.pi * 2 end
  while d < -math.pi do d = d + math.pi * 2 end
  if d > maxStep then d = maxStep elseif d < -maxStep then d = -maxStep end
  e.heading = e.heading + d
end

function M.update(game, dt)
  game = game or liveGame()
  local world = liveWorld(game)
  if not (world and world.map and world.player) then return false end
  -- Ambient sky Pokemon only exist in the voxel presentation.  Native 2D used
  -- to keep advancing their trig/steering math at 60 Hz even though no caller
  -- could draw them; stand down completely until voxels are active again.
  if not voxelEnabled() then
    state.updateAccum = 0
    return false
  end
  dt = tonumber(dt) or 1 / 60
  if dt < 0 then dt = 0 elseif dt > 0.10 then dt = 0.10 end
  state.updateAccum = (state.updateAccum or 0) + dt
  local interval = updateInterval()
  if state.updateAccum < interval then
    state.skippedTicks = (state.skippedTicks or 0) + 1
    return false
  end
  dt = math.min(0.10, state.updateAccum)
  state.updateAccum = 0
  state.updateTicks = (state.updateTicks or 0) + 1
  state.clock = state.clock + dt

  local id = world.map.id
  local bucket = timeBucket(world)
  if id ~= state.mapId or bucket ~= state.timeBucket then
    spawnForWorld(game, world)
  elseif not enabled() then
    if #state.entities > 0 then clearEntities() end
    return false
  end

  local w, h = mapDimensions(world.map)
  local centerX, centerY = w * 0.5, h * 0.5
  for _, e in ipairs(state.entities) do
    local oldAlt = e.altitude or e.baseAltitude or 0
    e.turnTimer = (e.turnTimer or 0) - dt
    if e.turnTimer <= 0 then
      e.turnTimer = randRange(2.5, 7.5)
      e.turnBias = randRange(-0.22, 0.22)
    end
    e.heading = e.heading + (e.turnBias or 0) * dt

    local margin = 28
    local nx = e.px + math.cos(e.heading) * e.speed * dt
    local ny = e.py + math.sin(e.heading) * e.speed * dt
    if nx < margin or nx > w - margin or ny < margin or ny > h - margin then
      local target = atan2(centerY - e.py, centerX - e.px)
      turnToward(e, target, math.min(0.18, dt * 2.8))
      nx = e.px + math.cos(e.heading) * e.speed * dt
      ny = e.py + math.sin(e.heading) * e.speed * dt
    end
    e.px = math.max(8, math.min(w - 8, nx))
    e.py = math.max(8, math.min(h - 8, ny))
    e.cellX, e.cellY = math.floor(e.px / 16), math.floor(e.py / 16)
    e.facing = facingFromVelocity(math.cos(e.heading), math.sin(e.heading))
    e.altitude = e.baseAltitude + math.sin(state.clock * 0.75 + e.phaseOffset) * 4.5
    e._ambientFlyingAnimTime = state.clock + e.phaseOffset
    e._ambientFlyingClimb = e.altitude - oldAlt
    e._ambientFlyingBank = math.max(-1, math.min(1, (e.turnBias or 0) * 5))
  end
  return true
end

function M.visibleEntities(world)
  if not voxelEnabled() or not enabled() or not world or world.map == nil
      or world.map.id ~= state.mapId then return {} end
  return state.entities
end

function M.refresh(game)
  game = game or liveGame()
  local world = liveWorld(game)
  if not (world and world.map) then
    clearEntities()
    state.mapId = nil
    return 0
  end
  return spawnForWorld(game, world)
end

function M.status()
  local species = {}
  for _, e in ipairs(state.entities) do species[#species + 1] = e.ambientSpecies end
  return {
    installed = M.installed,
    enabled = enabled(),
    density = density(),
    mapId = state.mapId,
    timeBucket = state.timeBucket,
    count = #state.entities,
    species = species,
    renderOnly = true,
    kanto = (liveWorld(liveGame()) or {})._stadiumYellowKanto == true,
    shadows = false,
    performanceTier = performanceTier(),
    updateHz = math.floor(1 / updateInterval() + 0.5),
    updateTicks = state.updateTicks or 0,
    skippedTicks = state.skippedTicks or 0,
  }
end

function M.install()
  if M.installed then return true end
  if mod and mod.events and type(mod.events.on) == "function" then
    mod.events:on("game.ready", function(game) pcall(M.refresh, game) end)
    mod.events:on("map.entered", function() pcall(M.refresh, liveGame()) end)
    mod.events:on("save.loaded", function() pcall(M.refresh, liveGame()) end)
    mod.events:on("mod.options_changed", function(payload)
      if not payload or payload.mod ~= mod.id then return end
      if payload.key == "ambientFlyingPokemon" or payload.key == "ambientFlyingDensity"
          or payload.key == "voxel3d" or payload.key == "performancePreset" then
        state.updateAccum = 0
        pcall(M.refresh, liveGame())
      end
    end)
  end
  if mod and mod.hooks and type(mod.hooks.wrap) == "function" then
    local ok, err = pcall(mod.hooks.wrap, mod.hooks, "input.step",
      function(nextFn, game, dt)
        local a, b, c = nextFn(game, dt)
        pcall(M.update, game, dt)
        return a, b, c
      end, -250)
    if not ok then return false, tostring(err) end
    state.hookInstalled = true
  end
  M.installed = true
  pcall(M.refresh, liveGame())
  return true
end

return M
