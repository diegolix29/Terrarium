-- Gen4Spawn: what "a place a Pokemon may stand" means on Platinum, for every
-- roamer this mod puts on the map (WildRoamers: grass / water / cave floor;
-- CityLife: the street Pokemon).
--
-- WHY THIS EXISTS
--
-- Roamer, WildRoamers and CityLife were written against Gen 1-3's Map, and they
-- ask it four things that Gen 4 does not answer the same way:
--
--   1. "is this grass?"   Map:isGrassCell tests a tileset's grass tile. Gen 4 has
--                         no such tileset; grass is a BEHAVIOUR byte on the cell
--                         (2 = tall grass, 3 = very tall grass). Gen4Grass already
--                         reads exactly that to plant the 3D tufts, so a roamer
--                         now stands exactly where the 3D grass grows
--                         (Gen4Grass.isGrassCell).
--   2. "is this water?"   Gen 4 water is drawn from the cartridge's water
--                         POLYGONS (Gen4Water), not from tiles. The per-cell
--                         question is still the engine's Map:isWaterCell, which
--                         is what the 3D sheet is laid over (Gen4Water.isWaterCell).
--   3. "can it step here?" Collision.canMove is the Gen 1-3 rule. On Gen 4 a step
--                         is: the cell is standable for this roamer's terrain,
--                         nobody (player included) is on or entering it, and the
--                         ground height does not jump (BDHC terrain is not flat).
--   4. "what lives here?" The mod read Game.data.encounters[map.id].grass/.water
--                         in the Gen 1-3 shape. Gen 4 tables are 12 grass slots /
--                         5 surf slots with percentages, a level RANGE per slot,
--                         and morning / day / night variants. encounterDef()
--                         finds the table and reshapes it to what pickSlot reads.
--
-- On any other generation active() is false and every caller keeps its old path
-- unchanged.
--
-- THE UPDATE TICK
--
-- WildRoamers.update and CityLife.update ride the voxel pipeline's update hook.
-- On Gen 4 that pipeline reports available() = false (it would replace Platinum's
-- world), and a pipeline that is unavailable may not be ticked at all. install()
-- wraps OverworldState:update and, ONLY when the pipeline has not ticked the
-- roamers within the last half second, drives them from there. Where the
-- pipeline does tick them, the driver never fires, so nothing runs twice.

local V = ...

local Spawn = {
  HALF_X = 16,        -- cells: how far the Gen 4 view reaches sideways (spawns land past it)
  HALF_Y = 12,        -- cells: and up/down. Gen 4's free camera sees far more than the GB's 10x9
  STEP_MAX = 12,      -- world units: tallest height change one roamer step may make
  SUBMERGE = 3,       -- world units a water roamer sits below the water sheet
  MAX_DEPTH = 48,     -- sheet more than this above the cell's ground is not THIS cell's water
  DRIVE_GRACE = 0.5,  -- seconds the pipeline may stay silent before the driver steps in
  installed = false,
}

local function optional(name)
  local ok, mod = pcall(V.require, name)
  return ok and mod or nil
end

local function game()
  local ok, Game = pcall(require, "src.core.Game")
  return ok and Game or nil
end

local warned = {}
local function once(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if V.mod and V.mod.log then
    pcall(V.mod.log.info, V.mod.log, "Gen4Spawn: " .. fmt:format(...))
  end
end

-- ------------------------------------------------------------ detection --

local genCache
function Spawn.active()
  if genCache ~= nil then return genCache end
  local ok, GV = pcall(require, "src.core.GameVersion")
  if ok and GV and type(GV.generation) == "function" then
    local okG, n = pcall(GV.generation)
    n = okG and tonumber(n) or nil
    -- only a real answer is remembered; an early nil must not pin "not Gen 4"
    if n then genCache = (n == 4); return genCache end
  end
  return false
end

function Spawn.halfView()
  return Spawn.HALF_X, Spawn.HALF_Y
end

-- ------------------------------------------------------------ cell checks --

local function inBounds(map, cx, cy)
  if type(map.inBounds) ~= "function" then return true end
  local ok, r = pcall(map.inBounds, map, cx, cy)
  return ok and r and true or false
end

function Spawn.isGrass(map, cx, cy)
  local G = optional("Gen4Grass")
  if G and type(G.isGrassCell) == "function" then
    local ok, r = pcall(G.isGrassCell, map, cx, cy)
    return ok and r and true or false
  end
  return false
end

function Spawn.isWater(map, cx, cy)
  local W = optional("Gen4Water")
  if W and type(W.isWaterCell) == "function" then
    local ok, r = pcall(W.isWaterCell, map, cx, cy)
    return ok and r and true or false
  end
  if type(map.isWaterCell) == "function" then
    local ok, r = pcall(map.isWaterCell, map, cx, cy)
    return ok and r and true or false
  end
  return false
end

local function walkable(map, cx, cy)
  if type(map.isWalkableCell) ~= "function" then return true end
  local ok, r = pcall(map.isWalkableCell, map, cx, cy)
  return ok and r and true or false
end

-- "A wild Pokemon can come from here" -- the engine's own question, which on a
-- cave floor is true without any grass behaviour.
local function encounterCell(map, cx, cy)
  if type(map.isEncounterCell) ~= "function" then return false end
  local ok, r = pcall(map.isEncounterCell, map, cx, cy)
  return ok and r and true or false
end

-- kind: "grass" | "water" | "cave" | anything else (street / indoor: bare ground)
function Spawn.standable(kind, map, cx, cy)
  if not inBounds(map, cx, cy) then return false end
  if type(map.warpAtCell) == "function" then
    local ok, w = pcall(map.warpAtCell, map, cx, cy)
    if ok and w then return false end
  end
  if kind == "water" then return Spawn.isWater(map, cx, cy) end
  if Spawn.isWater(map, cx, cy) then return false end
  if not walkable(map, cx, cy) then return false end
  if kind == "grass" then return Spawn.isGrass(map, cx, cy) end
  if kind == "cave" then return encounterCell(map, cx, cy) end
  return true
end

local function groundOf(map)
  local r = map and map.renderer
  return r and r.gen4Ground or nil
end

local function groundY(ground, cx, cy)
  if not (ground and type(ground.groundY) == "function") then return nil end
  local ok, y = pcall(ground.groundY, ground, cx * 16 + 8, cy * 16 + 8)
  return ok and tonumber(y) or nil
end

-- One roamer step on Gen 4. Replaces Collision.canMove for roamers: that is the
-- Gen 1-3 rule (and refuses water to anything not surfing).
function Spawn.canStep(kind, map, entities, roamer, dir)
  local Collision = require("src.world.Collision")
  local tx, ty = Collision.target(roamer.cellX, roamer.cellY, dir)
  if not Spawn.standable(kind, map, tx, ty) then return false end
  if type(Collision.occupied) == "function" then
    local ok, busy = pcall(Collision.occupied, entities, tx, ty)
    if ok and busy then return false end
  end
  local Game = game()
  local p = Game and Game.overworld and Game.overworld.player
  if p and ((p.cellX == tx and p.cellY == ty) or (p.targetX == tx and p.targetY == ty)) then
    return false
  end
  if kind ~= "water" then
    local ground = groundOf(map)
    local a, b = groundY(ground, roamer.cellX, roamer.cellY), groundY(ground, tx, ty)
    if a and b and math.abs(a - b) > Spawn.STEP_MAX then return false end
  end
  return true
end

-- Whole-map questions, asked once per map and remembered.
local mapFacts = setmetatable({}, { __mode = "k" })
local function fact(map, key, compute)
  local f = mapFacts[map]
  if not f then f = {}; mapFacts[map] = f end
  if f[key] == nil then f[key] = compute() and true or false end
  return f[key]
end

local function anyCell(map, test)
  local wc, hc = map.widthCells or 0, map.heightCells or 0
  for cy = 0, hc - 1 do
    for cx = 0, wc - 1 do
      if test(cx, cy) then return true end
    end
  end
  return false
end

function Spawn.mapHasGrass(map)
  return fact(map, "grass", function()
    return anyCell(map, function(cx, cy)
      return inBounds(map, cx, cy) and Spawn.isGrass(map, cx, cy) and not Spawn.isWater(map, cx, cy)
    end)
  end)
end

-- Walkable, non-grass, non-water floor the engine counts as an encounter cell:
-- a cave. Only ever asked when the map has an encounter table and no grass.
function Spawn.mapHasEncounterFloor(map)
  return fact(map, "cave", function()
    return anyCell(map, function(cx, cy)
      return inBounds(map, cx, cy) and not Spawn.isWater(map, cx, cy)
        and walkable(map, cx, cy) and encounterCell(map, cx, cy)
    end)
  end)
end

-- ----------------------------------------------------------- outdoors --

local OUTDOOR_WORDS = { "CITY", "TOWN", "ROUTE", "OUTDOOR", "OUTSIDE", "FIELD", "SEA", "VILLAGE", "LAKE" }
local INDOOR_WORDS = { "INDOOR", "INSIDE", "BUILDING", "HOUSE", "CAVE", "DUNGEON", "UNDERGROUND",
                       "GYM", "CENTER", "MART", "INTERIOR", "ROOM" }

local function wordIn(text, words)
  text = tostring(text or ""):upper()
  for _, w in ipairs(words) do
    if text:find(w, 1, true) then return true end
  end
  return false
end

-- Is this Gen 4 map out in the open? Map.isOutdoor reads Gen 1/2 header fields
-- a Gen 4 def does not have, so it says "indoors" everywhere. This reads
-- whatever the def says about itself and only then falls back on the engine
-- answer; when the def says nothing a big open map is taken as outdoors.
function Spawn.isOutdoor(map)
  local def = map and map.def
  if type(def) ~= "table" then return false end
  if def.outdoor ~= nil then return def.outdoor and true or false end
  if def.isOutdoor ~= nil then return def.isOutdoor and true or false end
  for _, field in ipairs({ "mapType", "type", "environment", "kind", "category" }) do
    local v = def[field]
    if v ~= nil then
      if wordIn(v, INDOOR_WORDS) then return false end
      if wordIn(v, OUTDOOR_WORDS) then return true end
    end
  end
  local okM, Map = pcall(require, "src.world.Map")
  if okM and Map and type(Map.isOutdoor) == "function" then
    local ok, r = pcall(Map.isOutdoor, def)
    if ok and r then return true end
  end
  local w, h = tonumber(def.width) or 0, tonumber(def.height) or 0
  return w >= 24 and h >= 24
end

-- --------------------------------------------------------- encounters --

local GRASS_PCT = { 20, 20, 10, 10, 10, 10, 5, 5, 4, 4, 1, 1 }   -- Gen 4 land slots
local SURF_PCT = { 60, 30, 5, 4, 1 }                              -- Gen 4 surf slots
local GEN2_PCT = { 30, 30, 20, 10, 5, 4, 1 }                      -- 7-slot land tables

local KIND_KEYS = {
  grass = { "grass", "land", "walking", "tall_grass", "field" },
  water = { "water", "surf", "surfing" },
}
local TABLE_NAMES = { "encounters", "gen4_encounters", "encounters_gen4",
                      "wild_encounters", "wild", "encounter_tables" }
-- Platinum's record keeps the per-terrain rate beside the slot list:
-- { grass = { 12 slots }, grassRate = n, surf = { 5 slots }, surfRate = n, ... }
local RATE_KEYS = {
  grass = { "grassRate", "landRate", "walkRate" },
  water = { "surfRate", "waterRate" },
}
local DEF_FIELDS = { "encounters", "wild", "encounterTable", "wildEncounters" }

local function rawRate(raw)
  if type(raw) ~= "table" then return nil end
  return tonumber(raw.rate or raw.encounterRate or raw.encounter_rate or raw.chance)
end

local function slotOf(e)
  if type(e) ~= "table" then return nil end
  local sp = e.species
  if sp == nil then sp = e.pokemon end
  if sp == nil then sp = e.mon end
  if sp == nil then sp = e.dex end
  if sp == nil then sp = e.id end
  if sp == nil then sp = e[1] end
  if sp == nil or type(sp) == "table" then return nil end
  if sp == 0 then return nil end      -- Gen 4 tables pad unused slots with species 0
  local lo = tonumber(e.level or e.lvl or e.levelMin or e.minLevel or e.min_level or e.min or e[2])
  if not lo then return nil end
  local hi = tonumber(e.levelMax or e.maxLevel or e.max_level or e.max or e[3]) or lo
  return { species = sp, level = lo, levelMin = lo, levelMax = math.max(lo, hi) }
end

local function bucketsFor(n, kind)
  local pct
  if kind == "grass" and n == #GRASS_PCT then pct = GRASS_PCT
  elseif kind == "water" and n == #SURF_PCT then pct = SURF_PCT
  elseif kind == "grass" and n == #GEN2_PCT then pct = GEN2_PCT end
  local out, acc = {}, 0
  for i = 1, n do
    acc = acc + (pct and pct[i] or 100 / n)
    out[i] = math.min(256, math.floor(acc * 256 / 100 + 0.5))
  end
  out[n] = 256          -- the last bucket always catches the roll
  return out
end

-- Platinum keys its tables off the DS clock: 4:00-9:59 morning, 10:00-19:59
-- day, 20:00-3:59 night.
local function timeKey()
  local h = tonumber(os.date("%H")) or 12
  if h >= 4 and h < 10 then return "morning" end
  if h >= 10 and h < 20 then return "day" end
  return "night"
end

-- Morning / day / night variant of a table keyed by time of day, under any of
-- the spellings the engine's datasets use (morning, MORN, night, NITE ...).
local TIME_NAMES = {
  morning = { "morning", "MORNING", "morn", "MORN" },
  day     = { "day", "DAY" },
  night   = { "night", "NIGHT", "nite", "NITE" },
}
local function pickTime(t)
  if type(t) ~= "table" then return nil end
  for _, key in ipairs({ timeKey(), "day" }) do
    for _, name in ipairs(TIME_NAMES[key]) do
      if t[name] ~= nil then return t[name] end
    end
  end
  return nil
end

local function listOf(raw)
  if type(raw) ~= "table" then return nil end
  if type(raw.slots) == "table" and #raw.slots > 0 then return raw.slots end
  if type(raw[1]) == "table" then return raw end
  return nil
end

-- One terrain's table, in the shape WildRoamers.pickSlot reads:
--   { rate, slots = { {species, level, levelMin, levelMax}, ... }, buckets }
-- Idempotent on the Gen 1-3 shape, so a table already in that shape passes.
function Spawn.kindTable(encDef, kind)
  if type(encDef) ~= "table" then return nil end
  local raw
  for _, key in ipairs(KIND_KEYS[kind] or { kind }) do
    if type(encDef[key]) == "table" then raw = encDef[key]; break end
  end
  if not raw then return nil end
  local list, holder = listOf(raw), raw
  if not list then
    -- morning / day / night variants: today's by the clock, else any that exists
    local variant = pickTime(raw)
    list = listOf(variant)
    if list then holder = variant end
  end
  if not list and type(raw.slots) == "table" then
    -- { rates = { MORN, DAY, NITE }, slots = { MORN = {...}, DAY = {...}, ... } }
    list = listOf(pickTime(raw.slots))
  end
  if not list then return nil end
  local slots = {}
  for _, e in ipairs(list) do
    local s = slotOf(e)
    if s then slots[#slots + 1] = s end
  end
  if #slots == 0 then return nil end
  local buckets = holder.buckets or raw.buckets
  if not (type(buckets) == "table" and #buckets == #slots) then
    buckets = bucketsFor(#slots, kind)
  end
  local rate = rawRate(raw)
  if rate == nil and type(raw.rates) == "table" then rate = tonumber(pickTime(raw.rates)) end
  if rate == nil then rate = rawRate(holder) end
  if rate == nil then
    for _, key in ipairs(RATE_KEYS[kind] or {}) do
      if tonumber(encDef[key]) then rate = tonumber(encDef[key]); break end
    end
  end
  if rate == nil then rate = 1 end
  return { rate = rate, slots = slots, buckets = buckets }
end

local function now()
  return (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
end

local rawDefs = setmetatable({}, { __mode = "k" })   -- map -> raw record | false
local negUntil = setmetatable({}, { __mode = "k" })  -- map -> time a miss may be retried
Spawn.captured = {}                                   -- map id -> encDef the engine rolled with

-- The engine's own encounter.roll hands over the table it resolved for the map
-- it is standing on. Remembering it is the one lookup that cannot be wrong
-- about how a Platinum map finds its table.
function Spawn.noteEncounter(encDef)
  if type(encDef) ~= "table" then return end
  local Game = game()
  local map = Game and Game.overworld and Game.overworld.map
  if map and map.id ~= nil then
    if Spawn.captured[map.id] ~= encDef then
      once("captured:" .. tostring(map.id), "map %s: took the engine's own encounter table", tostring(map.id))
    end
    Spawn.captured[map.id] = encDef
    rawDefs[map], negUntil[map] = nil, nil
  end
end

local function findRaw(Game, map)
  local data = Game and Game.data
  if type(data) ~= "table" then return nil end
  local def = map.def or {}
  local keys = { map.id, def.id, def.name, def.index }
  local function usable(rec)
    return type(rec) == "table"
      and (Spawn.kindTable(rec, "grass") or Spawn.kindTable(rec, "water")) and true or false
  end
  local cap = map.id ~= nil and Spawn.captured[map.id] or nil
  if usable(cap) then return cap, "engine encounter.roll" end
  for _, name in ipairs(TABLE_NAMES) do
    local t = data[name]
    if type(t) == "table" then
      for _, k in ipairs(keys) do
        if k ~= nil and usable(t[k]) then return t[k], "data." .. name end
      end
    end
  end
  for _, field in ipairs(DEF_FIELDS) do
    if usable(def[field]) then return def[field], "map.def." .. field end
  end
  -- kind first: encounters.grass[mapId] / encounters.water[mapId]
  for _, name in ipairs(TABLE_NAMES) do
    local t = data[name]
    if type(t) == "table" then
      for _, k in ipairs(keys) do
        if k ~= nil then
          local rec = {}
          for _, kind in ipairs({ "grass", "water" }) do
            for _, kk in ipairs(KIND_KEYS[kind]) do
              local sub = t[kk]
              if type(sub) == "table" and type(sub[k]) == "table" then
                rec[kind] = sub[k]
                break
              end
            end
          end
          if usable(rec) then return rec, "data." .. name .. " (kind first)" end
        end
      end
    end
  end
  -- Platinum: data.encounters is a list (0, 1, 2 ...) and the MAP carries the
  -- index (or name) of its record in some header field. Look at every field
  -- named like enc* / wild* on the map def, the map itself and any map /
  -- header / zone table, most specific names first.
  local enc = data.encounters
  if type(enc) == "table" then
    local PRIORITY = { encounter = 1, encounterid = 1, encounterindex = 1, encountertable = 1,
                       wildencounter = 1, wildencounterid = 1, wildindex = 1, wild = 1,
                       enc = 1, encid = 1, encounterfile = 1, wildfile = 1 }
    local cands = {}
    local function scan(rec, src)
      if type(rec) ~= "table" then return end
      for k, v in pairs(rec) do
        local ks = tostring(k):lower()
        if (ks:find("enc", 1, true) or ks:find("wild", 1, true))
           and (type(v) == "number" or type(v) == "string") then
          cands[#cands + 1] = { v, src .. "." .. tostring(k), PRIORITY[ks] or 2 }
        end
      end
    end
    scan(def, "def")
    scan(map, "map")
    for k, t in pairs(data) do
      local ks = tostring(k):lower()
      if type(t) == "table" and (ks:find("map", 1, true) or ks:find("header", 1, true)
                                  or ks:find("zone", 1, true)) then
        if map.id ~= nil then scan(t[map.id], "data." .. tostring(k)) end
        if def.id ~= nil and def.id ~= map.id then scan(t[def.id], "data." .. tostring(k)) end
      end
    end
    table.sort(cands, function(a, b) return a[3] < b[3] end)
    local seen = {}
    for _, c in ipairs(cands) do
      local v = c[1]
      if type(v) == "string" and tonumber(v) and enc[tonumber(v)] ~= nil then v = tonumber(v) end
      local rec = enc[v]
      if usable(rec) then
        return rec, "data.encounters[" .. tostring(v) .. "] via " .. c[2]
      end
      seen[#seen + 1] = c[2] .. "=" .. tostring(c[1])
    end
    once("cands:" .. tostring(map.id), "map %s: encounter-looking fields tried: %s",
         tostring(map.id), #seen > 0 and table.concat(seen, ", ") or "none")
  end
  return nil
end

-- A short text picture of a table, so the real layout can be read off a log.
local function shape(v, depth)
  if type(v) ~= "table" then return type(v) .. ":" .. tostring(v) end
  if depth <= 0 then return "table" end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for i = 1, math.min(#keys, 6) do
    parts[#parts + 1] = tostring(keys[i]) .. "=" .. shape(v[keys[i]], depth - 1)
  end
  return "{" .. table.concat(parts, ", ")
    .. (#keys > 6 and (", ...(" .. #keys .. " keys)") or "") .. "}"
end

-- The map's normalised encounter record { grass = tbl|nil, water = tbl|nil }, or
-- nil. Where it was found is logged once per map, and when it was NOT found the
-- log lists the Game.data keys that look encounter-shaped so the real layout can
-- be read off a log instead of guessed.
function Spawn.encounterDef(Game, map)
  local raw = rawDefs[map]
  if raw == false and now() >= (negUntil[map] or 0) then raw = nil end
  if raw == nil then
    local src
    raw, src = findRaw(Game, map)
    rawDefs[map] = raw or false
    if not raw then negUntil[map] = now() + 2 end
    if raw then
      once("found:" .. tostring(map.id), "map %s: encounter table from %s", tostring(map.id), tostring(src))
    else
      local names = {}
      for k in pairs((Game and Game.data) or {}) do
        local s = tostring(k):lower()
        if s:find("enc", 1, true) or s:find("wild", 1, true) or s:find("swarm", 1, true)
           or s:find("grass", 1, true) or s:find("map", 1, true)
           or s:find("header", 1, true) or s:find("zone", 1, true) then
          names[#names + 1] = tostring(k)
        end
      end
      table.sort(names)
      local data = Game and Game.data
      local def = map.def or {}
      once("dump", "Game.data.encounters shape: %s",
           shape(data and data.encounters, 5):sub(1, 1800))
      once("defshape:" .. tostring(map.id), "map.def shape: %s", shape(def, 2):sub(1, 1500))
      once("dumpkeys:" .. tostring(map.id),
           "map keys tried: id=%s def.id=%s def.name=%s def.index=%s",
           tostring(map.id), tostring(def.id), tostring(def.name), tostring(def.index))
      once("none:" .. tostring(map.id),
           "map %s: no encounter table found (Game.data keys that look related: %s)",
           tostring(map.id), #names > 0 and table.concat(names, ", ") or "none")
    end
  end
  if not raw then return nil end
  return { grass = Spawn.kindTable(raw, "grass"), water = Spawn.kindTable(raw, "water") }
end

-- The terrains this Gen 4 map can put wild Pokemon on: { { kind, table_ }, ... }.
function Spawn.terrains(Game, map)
  local out = {}
  local enc = Spawn.encounterDef(Game, map)
  if not enc then return out end
  if enc.grass and (enc.grass.rate or 0) > 0 then
    if Spawn.mapHasGrass(map) then
      out[#out + 1] = { kind = "grass", table_ = enc.grass }
    elseif Spawn.mapHasEncounterFloor(map) then
      out[#out + 1] = { kind = "cave", table_ = enc.grass }
    end
  end
  if enc.water and (enc.water.rate or 0) > 0 then
    out[#out + 1] = { kind = "water", table_ = enc.water }
  end
  return out
end

-- ------------------------------------------------------------- drawing --

-- A water roamer is drawn at the ground under it, which is the lake BED. Lift it
-- to the water sheet (Gen4Water publishes the height of the nearest one) and let
-- the body sit SUBMERGE units under it, the way the voxel scene's waterline cut
-- does. Anything else keeps the ground height it was given.
function Spawn.actorY(e, gh)
  if not (e and e.roamer and e.kind == "water") then return gh end
  local GW = optional("Gen4Water")
  local level = GW and tonumber(GW.level)
  if level and gh and level > gh and level - gh <= Spawn.MAX_DEPTH then
    return level - Spawn.SUBMERGE
  end
  return gh
end

-- --------------------------------------------------------------- driver --

-- Tick the roamers from the overworld's own update, but only when the voxel
-- pipeline is not doing it.
function Spawn.drive()
  if not Spawn.active() then return end
  local t = now()
  if not Spawn.statusLogged then
    Spawn.statusLogged = true
    local W, A = optional("WildRoamers"), optional("RoamerArt")
    local okE, en = pcall(function() return W and W.enabled and W.enabled() end)
    local okA, av = pcall(function() return A and A.available and A.available() end)
    once("status", "driver running; WildRoamers.enabled=%s RoamerArt.available=%s",
         tostring(okE and en), tostring(okA and av))
  end
  for _, name in ipairs({ "WildRoamers", "CityLife" }) do
    local m = optional(name)
    if m and type(m.update) == "function"
       and not (m.lastPipelineTick and t - m.lastPipelineTick < Spawn.DRIVE_GRACE) then
      pcall(m.update, "driver")
    end
  end
end

function Spawn.install()
  if Spawn.installed or not Spawn.active() then return false end
  local ok, OS = pcall(require, "src.world.OverworldController")
  if ok and type(OS) == "table" and type(OS.update) == "function"
     and not OS.terrariumGen4Drive then
    local inner = OS.update
    function OS:update(...)
      local a, b, c = inner(self, ...)
      pcall(Spawn.drive)
      return a, b, c
    end
    OS.terrariumGen4Drive = true
    Spawn.updateWrapped = true
  else
    once("nowrap", "OverworldState.update could not be wrapped; roamers rely on the voxel "
         .. "pipeline tick or Gen4WorldHost's draw-time driver")
  end
  pcall(function()
    local hooks = V.mod and V.mod.hooks
    if hooks and type(hooks.wrap) == "function" then
      hooks:wrap("encounter.roll", function(next, encDef, ctx)
        pcall(Spawn.noteEncounter, encDef)
        return next(encDef, ctx)
      end)
      Spawn.rollHooked = true
    end
  end)
  Spawn.installed = true
  return true
end

return Spawn