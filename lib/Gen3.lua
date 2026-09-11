-- Minimal Gen 3 voxel support for Terrarium Advance Mod
-- Based on DRAMATIC_SHAPE's comprehensive Gen3.lua but simplified for basic functionality

local V = ...

local Gen3 = {}

-- Constants from DRAMATIC_SHAPE's Gen3.lua
local SHEET_COLS = 16
local CELL = 16          -- a metatile edge, in world pixels
local TILE = 8           -- the mesher's own quad edge
local COURSE = 16        -- one elevation step, in world pixels

Gen3.SHEET_COLS = SHEET_COLS
Gen3.CELL = CELL
Gen3.COURSE = COURSE

-- Engine access functions
local function engineGame()
  local ok, Game = pcall(require, "src.core.Game")
  if ok and type(Game) == "table" and (Game.data or Game.overworld) then
    return Game
  end
  local g = rawget(_G, "Game")
  if type(g) == "table" then return g end
  return (ok and type(Game) == "table") and Game or nil
end

local function engineData()
  local Game = engineGame()
  return Game and Game.data or nil
end

Gen3.engineData = engineData

-- Gen 3 detection
function Gen3.isGen3(tileset)
  if type(tileset) ~= "table" then return false end
  return tonumber(tileset.blockTiles) == 2 and tonumber(tileset.blockCells) == 1
end

function Gen3.mapIsGen3(map)
  return map ~= nil and Gen3.isGen3(map.tileset)
end

-- Synthetic tile ID functions
function Gen3.tileId(metatile, tx, ty)
  return (tonumber(metatile) or 0) * 4 + (ty % 2) * 2 + (tx % 2)
end

function Gen3.tileAt(map, tx, ty)
  if not map then return nil end
  local ts = map.tileset
  if ts and ts.blocks then return map:tileAt(tx, ty) end
  local okB, id = pcall(map.blockAt, map, math.floor(tx / 2), math.floor(ty / 2))
  if not okB or id == nil then return nil end
  return Gen3.tileId(id, tx, ty)
end

function Gen3.metatileOf(tileId)
  return math.floor((tonumber(tileId) or 0) / 4)
end

function Gen3.quadrantOf(tileId)
  return (tonumber(tileId) or 0) % 4
end

function Gen3.tileOrigin(tileId, cols)
  cols = cols or SHEET_COLS
  local id = tonumber(tileId) or 0
  local m, q = math.floor(id / 4), id % 4
  local ax = (m % cols) * CELL + (q % 2) * TILE
  local ay = math.floor(m / cols) * CELL + math.floor(q / 2) * TILE
  return ax, ay
end

function Gen3.tileCount(metatiles)
  return (tonumber(metatiles) or 0) * 4
end

function Gen3.idSpace(tileset, ctx)
  if ctx and (ctx.metatiles or 0) > 0 then return ctx.metatiles end
  local data = engineData()
  local layout = data and data.constants and data.constants.gen3Layout
  local inPrimary = tonumber(layout and layout.metatilesInPrimary) or 512
  local total = tonumber(tileset and tileset.metatileCount) or 0
  return math.max(inPrimary + total, inPrimary * 2)
end

-- Context caching for Gen 3 maps
local ctxCache = setmetatable({}, { __mode = "k" })
local ctxMisses = setmetatable({}, { __mode = "k" })
local CTX_RETRIES = 8

-- Simple Gen 3 context for map
function Gen3.forMap(map)
  if not Gen3.mapIsGen3(map) then return nil end
  local hit = ctxCache[map]
  if hit ~= nil then return hit or nil end

  -- Try to get Gen 3 world from engine
  local Game = engineGame()
  local ow = Game and (Game.overworld or Game.world) or nil
  local world = nil
  if ow and type(ow.gen3WorldFor) == "function" then
    local got, w = pcall(ow.gen3WorldFor, ow, map.def, map, map.tileset)
    if got and type(w) == "table" and w.bottom then
      world = w
    end
  end

  if not world then
    local n = (ctxMisses[map] or 0) + 1
    ctxMisses[map] = n
    if n >= CTX_RETRIES then
      ctxCache[map] = false
      return nil
    end
    return nil
  end
  ctxMisses[map] = nil
  ctxCache[map] = false

  local def = map.def or {}
  local width = tonumber(def.width) or 0
  local height = tonumber(def.height) or 0
  local elevationCells = def.elevationCells
  local collisionCells = def.collisionCells

  local ctx = {
    world = world,
    seam = "engine",
    map = map,
    tileset = map.tileset,
    cols = world.cols or SHEET_COLS,
    cell = CELL,
    metatiles = world.metatiles or 0,
    width = width,
    height = height,
    elevationCells = elevationCells,
    collisionCells = collisionCells,
    elevHeight = nil,
    levels = 0,
    spec = nil,
    attrCache = {},
    classCache = {},
  }

  -- Load gen3_metatiles data for advanced role classification
  local roles = nil
  do
    local okR, t = pcall(V.data, "gen3_metatiles")
    if okR and type(t) == "table" then roles = t.roles end
  end
  local ts = map.tileset
  local key = (type(ts) == "table" and tostring(ts.id or ""))
              or (type(ts) == "string" and ts) or ""
  if key == "" and type(map.def) == "table" then
    key = tostring(map.def.tileset or "")
  end
  local p1, s1 = key:match("TILESET_(%x+)_(%x+)")
  if not p1 and type(ts) == "table" then
    p1 = tostring(ts.primaryKey or ""):match("TILESET_(%x+)")
    s1 = tostring(ts.secondaryKey or ""):match("TILESET_(%x+)")
  end
  if not p1 then p1 = key:match("TILESET_(%x+)") end
  ctx.ownerPrimary = p1 and ("P" .. p1) or nil
  ctx.ownerSecondary = s1 and ("S" .. s1) or nil

  local roleMemo = {}

  function ctx.metaRole(m)
    if not roles or not m then return nil end
    local owner = (m < 512) and ctx.ownerPrimary or ctx.ownerSecondary
    local t = owner and roles[owner]
    local r = t and t[m]
    if not r then return nil end
    return r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9]
  end

  -- Basic context functions
  function ctx.indexOf(cx, cy)
    if width <= 0 or height <= 0 then return nil end
    if cx < 0 or cy < 0 or cx >= width or cy >= height then return nil end
    return cy * width + cx + 1
  end

  function ctx.metatileAt(cx, cy)
    if cx < 0 or cy < 0 or cx >= width or cy >= height then
      -- Border handling could be added here
      return nil
    end
    if type(map.blockAt) ~= "function" then return nil end
    local ok, id = pcall(map.blockAt, map, cx, cy)
    if not ok then return nil end
    return id
  end

  function ctx.attributes(metatile)
    local m = tonumber(metatile) or 0
    local c = ctx.attrCache[m]
    if c then return c[1], c[2] end
    local b, l = 0, 0
    if type(world.attributes) == "function" then
      b, l = world.attributes(m)
    end
    ctx.attrCache[m] = { b or 0, l or 0 }
    return b or 0, l or 0
  end

  function ctx.coverAt(metatile)
    if type(world.topIsAbovePlayer) == "function" then
      return world.topIsAbovePlayer(metatile) and true or false
    end
    local _, layer = ctx.attributes(metatile)
    return layer ~= 1
  end

  function ctx.offMap(cx, cy)
    return cx < 0 or cy < 0 or cx >= width or cy >= height
  end

  function ctx.blockedAt(cx, cy)
    if not collisionCells then return false end
    local i = ctx.indexOf(cx, cy)
    if not i then return true end
    return (collisionCells[i] or 0) ~= 0
  end

  function ctx.elevationAt(cx, cy)
    if not elevationCells then return nil end
    local i = ctx.indexOf(cx, cy)
    return i and elevationCells[i] or nil
  end

  -- Simple ground height (can be expanded)
  function ctx.groundHeight(cx, cy)
    local e = ctx.elevationAt(cx, cy)
    if e == nil then return 0 end
    -- Basic elevation to height conversion
    return (tonumber(e) or 0) * COURSE
  end

  -- Simple class determination (can be expanded)
  function ctx.classAt(cx, cy, metatile)
    local m = metatile
    if m == nil then m = ctx.metatileAt(cx, cy) end
    if m == nil then return nil end

    local blocked = ctx.blockedAt(cx, cy)
    local key = m * 2 + (blocked and 1 or 0)
    local hit = ctx.classCache[key]
    if hit ~= nil then return hit end

    local b, l = ctx.attributes(m)
    -- Try to use gen3_shapes data for better classification
    local s = spec()
    local class = classFromSpec(s, b, l)
    if not class then
      -- Fallback to basic determination
      class = blocked and "wall" or "ground"
    end
    ctx.classCache[key] = class
    return class
  end

  -- Basic role function (can be expanded)
  function ctx.roleAt(cx, cy)
    local blocked = ctx.blockedAt(cx, cy)
    if not blocked then
      return "floor"
    end
    return "wall"
  end

  ctxCache[map] = ctx
  return ctx
end

-- Improved class determination using gen3_shapes data
local function classFromSpec(spec, behavior, layer)
  if not spec or not spec.behaviors then return nil end
  local entry = spec.behaviors[behavior]
  if not entry then return nil end
  return entry.class
end

-- Placeholder for analysis function (can be expanded)
function Gen3.analyse(tileset)
  return nil
end

-- Load Gen 3 data files
local function spec()
  local ok, s = pcall(V.data, "gen3_shapes")
  if ok and type(s) == "table" then return s end
  return nil
end

Gen3.spec = spec

-- Status function for debugging
function Gen3.status(map)
  if not Gen3.mapIsGen3(map) then return "not a Gen 3 map" end
  local ctx = Gen3.forMap(map)
  if not ctx then return "no Gen 3 context" end
  return "ok"
end

-- Placeholder for solid measurement (can be expanded)
function Gen3.solidForMap(map, metatile)
  return nil
end

return Gen3
