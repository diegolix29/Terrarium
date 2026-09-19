-- A HARNESS FOR THE MOD'S GROUND LOOKUP, run here rather than on the player.
--
-- Every round of "npcs are still in the ground" has cost a relaunch, a walk to
-- Mauville and a log. The function under test is pure logic over four
-- collaborators -- TileShape, Structures, Gen3 and the Map -- so all four can
-- be faked, and then the QUESTIONS it asks and the ORDER it asks them in are
-- testable here in milliseconds.
--
-- What this cannot do is prove the real Structures agrees with the fake one.
-- What it can do is prove that when every reader declines, the answer is the
-- elevation grid's and not the datum -- which is the bug that put characters
-- underground on every raised plaza.
-- The engine checkout, for tests/love_stub below.  This used to be an
-- absolute path from the machine the harness was first written on, which
-- meant it only ever resolved there -- run anywhere else, the very first
-- require failed and the whole suite was skipped.  ENGINE_ROOT names it;
-- the default walks up out of <mod>/tests to where the mods folder and
-- the engine normally sit side by side.
local ENGINE = os.getenv("ENGINE_ROOT")
  or (((arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$")) or ".")
      .. "/../../..")
package.path = ENGINE .. "/?.lua;" .. package.path
love = require("tests.love_stub")
love.timer = love.timer or {}
love.timer.getDelta = function() return 1 / 60 end
love.timer.getTime = love.timer.getTime or function() return 0 end

-- the mod's lib folder: this file normally sits in <mod>/tests/, so the
-- default is its sibling.  MOD_LIB overrides it for running from elsewhere.
local MODLIB = os.getenv("MOD_LIB")
  or (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$") or ".")
     .. "/../lib/"

-- ---- the fakes -----------------------------------------------------------
local fake = {}

fake.shapes = {}            -- one table, shared by tileset like the real one
fake.shapeAt = {}           -- [key] = shape record returned by TileShape.at
fake.terrace = {}           -- [cellKey] = synthZ
fake.stamp = {}             -- [tileKey] = stamped height
fake.run = {}               -- [tileKey] = measured run height
fake.flat = {}              -- [tileKey] = flat ground height
fake.stand = {}             -- [tileKey] = standHeight
fake.stair = {}             -- [tileKey] = true
fake.elev = {}              -- [cellKey] = elevation nibble
fake.gridHeight = {}        -- [cellKey] = ctx.groundHeight answer
fake.walkable = {}          -- [cellKey] = bool (default true)

local function ck(x, y) return y * 8192 + x end

local TileShape = {
  forMap = function() return fake.shapes end,
  at = function(_, _, _, tx, ty) return fake.shapeAt[ck(tx, ty)] end,
}
local Structures = {
  terraceAt   = function(_, cx, cy) return fake.terrace[ck(cx, cy)] end,
  stampGround = function(_, tx, ty) return fake.stamp[ck(tx, ty)] end,
  runHeight   = function(_, tx, ty) return fake.run[ck(tx, ty)] end,
  flatGroundAt= function(_, tx, ty) return fake.flat[ck(tx, ty)] end,
  -- whether the map has been through the build; fake.built is set per
  -- test, and defaults to built so every existing case is unchanged
  built       = function(map) return fake.built ~= false end,
  standHeight = function(_, tx, ty) return fake.stand[ck(tx, ty)] end,
  stairAt     = function(_, tx, ty) return fake.stair[ck(tx, ty)] or false end,
  flightEnds  = function() return nil end,
}
local Gen3 = {
  mapIsGen3 = function() return true end,
  tileAt    = function(_, tx, ty) return ck(tx, ty) end,
  forMap    = function()
    return {
      elevationAt  = function(cx, cy) return fake.elev[ck(cx, cy)] end,
      groundHeight = function(cx, cy) return fake.gridHeight[ck(cx, cy)] or 0 end,
    }
  end,
}

-- REAL STUBS for the two modules the billboard maths actually reads numbers
-- from.  As inert tables their fields answer FUNCTIONS, so `leanAngle()` came
-- back a function and billboardMatrix died on the first arithmetic -- which is
-- a harness gap, not a bug in the file, and it hid card_test entirely.
local VoxelState = { angle = 0 }
local FirstPerson = setmetatable({
  cardBlend  = function() return 0 end,
  cardYaw    = function() return 0 end,
  hidePlayer = function() return false end,
  signature  = function() return "" end,
}, { __index = function() return function() end end })

-- everything else VoxelScene pulls in at load, as inert tables
local inert = setmetatable({}, { __index = function(t, k)
  local v = setmetatable({}, { __index = function() return function() end end })
  rawset(t, k, v); return v
end })

local V = {}
V.mod = { log = { info = function() end, warn = function() end,
                  error = function() end } }
V.data = function() return {} end
V.require = function(name)
  if name == "TileShape" then return TileShape end
  if name == "Structures" then return Structures end
  if name == "Gen3" then return Gen3 end
  if name == "VoxelState" then return VoxelState end
  if name == "FirstPerson" then return FirstPerson end
  local f = io.open(MODLIB .. name .. ".lua", "r")
  if f then f:close() end
  return inert[name]
end
V.engineRequire = require

local function newMap(id)
  return {
    id = id,
    widthCells = 64, heightCells = 64,
    tileset = { id = "TS", blockTiles = 2 },
    def = { width = 64, height = 64 },
    inBounds = function(_, x, y)
      return x >= 0 and y >= 0 and x < 64 and y < 64
    end,
    isWalkableCell = function(_, x, y)
      local v = fake.walkable[ck(x, y)]
      if v == nil then return true end
      return v
    end,
    isWaterCell = function() return false end,
    tileAt = function(_, tx, ty) return ck(tx, ty) end,
    blockAt = function() return 0 end,
  }
end

-- ---- load the real module ------------------------------------------------
local chunk, err = loadfile(MODLIB .. "VoxelScene.lua")
if not chunk then print("LOAD FAIL: " .. tostring(err)); os.exit(1) end
local ok, VoxelScene = pcall(chunk, V)
if not ok then print("INIT FAIL: " .. tostring(VoxelScene)); os.exit(1) end
if type(VoxelScene) ~= "table" or type(VoxelScene.groundAt) ~= "function" then
  print("NO groundAt on the module"); os.exit(1)
end
print("loaded VoxelScene, groundAt present")
return { VoxelScene = VoxelScene, fake = fake, newMap = newMap, ck = ck }
