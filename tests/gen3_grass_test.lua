-- HOENN SAYS "GRASS" WITH A BEHAVIOUR BYTE, NOT WITH A TILE ID.
--
-- Two bugs, one cause, and the cause is a field that only exists on Gen 1
-- and Gen 2.
--
-- `tileset.grassTile` is a single TILE ID: the art tall grass is drawn with.
-- A Gen 3 tileset has no such field.  Hoenn names ground by BEHAVIOUR --
-- MB_TALL_GRASS (0x02) and MB_LONG_GRASS (0x03) on the metatile -- and the
-- extractor puts those in `grassTiles`, which is a different question with a
-- different answer space.  Map:isGrassCell reads the behaviour bytes and has
-- always been right on Gen 3, which is why wild encounters worked.
--
-- Two places asked the Gen 1/2 field instead, and both failed silently:
--
--   Flora.buildTufts wanted it for the blade ART and returned "tileset names
--   no grass tile" on its first line, so not one blade was built in the
--   region -- and the reason went to a debug status line, never the log; and
--
--   WildRoamers.terrainsFor used it as a GATE on whether a map has grass to
--   populate, so no grass roamer was ever placed in Hoenn.  The only ones
--   that spawned were the water kind, out on the sea, where you can neither
--   walk into one nor press A at one.
--
-- The fix in both is the same: stop asking the tileset what grass looks like
-- and ask the MAP where its grass is, which the engine answers per cell on
-- every generation.
--
-- The first half of this suite is a source lint -- the failure is a field
-- that is READ, which no runtime test can see -- and the second builds a
-- Gen 3-shaped map and a Gen 1/2-shaped one and checks the sampling logic
-- answers for both.
--
--   texlua tests/gen3_grass_test.lua
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local LIB = os.getenv("MOD_LIB") or (HERE .. "/../lib/")

local fail, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if not cond then fail = fail + 1; print("FAIL " .. what) end
end

local function read(name)
  local f = io.open(LIB .. name, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return (s:gsub("%-%-[^\n]*", ""))        -- comments out: prose is not code
end

-- ---- the lint ------------------------------------------------------------
--
-- `grassTile` may still be READ -- it is the right answer on Gen 1 and Gen 2
-- and should be preferred there -- but it must never be the ONLY answer, and
-- it must never be a gate.

local flora = read("Flora.lua")
check(flora ~= nil, "Flora.lua is readable")
if flora then
  check(flora:find("Hoenn.grassArt", 1, true) ~= nil,
        "Flora falls back to sampling the map's own grass art")
  check(flora:find('return nil, "tileset names no grass tile"', 1, true) == nil,
        "Flora no longer bails when the tileset names no grass tile")
  -- Every read of the field must have a fallback.  Checked across the line
  -- AND the one after it, because a fallback chain long enough to matter is
  -- usually the thing that wrapped.
  local lines = {}
  for line in flora:gmatch("[^\n]*") do lines[#lines + 1] = line end
  for i = 1, #lines do
    if lines[i]:find("tileset.grassTile", 1, true) then
      local stmt = lines[i] .. " " .. (lines[i + 1] or "")
      checks = checks + 1
      if not (stmt:find(" or ", 1, true)
              or lines[i]:find("^%s*local grassTile%s*=")) then
        fail = fail + 1
        print("FAIL Flora reads grassTile with no fallback: "
              .. lines[i]:gsub("^%s+", ""))
      end
    end
  end
end

local roam = read("WildRoamers.lua")
check(roam ~= nil, "WildRoamers.lua is readable")
if roam then
  check(roam:find("tileset.grassTile", 1, true) == nil,
        "WildRoamers no longer gates grass roamers on the Gen 1/2 tile id")
  check(roam:find("mapHasGrass(map)", 1, true) ~= nil,
        "...and asks the map whether it has grass instead")
end

-- ---- the sampling logic --------------------------------------------------
--
-- Both fixes share a shape: walk the cells, stop at the first one the engine
-- calls grass, and read the art off it through the bottom-left tile of the
-- cell -- the same tile ChunkMesher and the ground ladder read.

local function sampler(map, gen3TileAt)
  local wc, hc = map.widthCells, map.heightCells
  for cy = 0, hc - 1 do
    for cx = 0, wc - 1 do
      if map:isGrassCell(cx, cy) then
        local tx, ty = cx * 2, cy * 2 + 1
        return (gen3TileAt and gen3TileAt(map, tx, ty)) or map:tileAt(tx, ty)
      end
    end
  end
  return nil
end

-- a Hoenn-shaped map: behaviour bytes, no grassTile, art in its own sheets
local GRASS_CELLS = { ["3,4"] = true, ["5,4"] = true }
local hoenn = {
  widthCells = 10, heightCells = 10,
  tileset = { id = "TS_GEN3", grassTiles = { 0x02, 0x03 }, behaviourBytes = true },
  isGrassCell = function(_, cx, cy) return GRASS_CELLS[cx .. "," .. cy] or false end,
  tileAt = function(_, tx, ty) return 1000 + tx + ty end,
}
local function gen3TileAt(_, tx, ty) return 700 + tx + ty end

check(hoenn.tileset.grassTile == nil,
      "a Gen 3 tileset carries no grassTile -- which is the whole bug")
check(sampler(hoenn, gen3TileAt) == 700 + 6 + 9,
      "...and the art is taken off the first grass cell, through Gen3.tileAt")

-- a Kanto/Johto-shaped map: a named tile id, ordinary tileAt
local kanto = {
  widthCells = 10, heightCells = 10,
  tileset = { id = "TS_GEN2", grassTile = 82 },
  isGrassCell = function(_, cx, cy) return cx == 2 and cy == 2 end,
  tileAt = function(_, tx, ty) return 500 + tx + ty end,
}
check((kanto.tileset.grassTile) == 82,
      "a Gen 1/2 tileset names its grass tile, and that answer is preferred")
check(sampler(kanto, nil) == 500 + 4 + 5,
      "...and the sampler would still find one if it did not")

-- a map with no grass at all answers nothing, and nothing is populated
local barren = {
  widthCells = 6, heightCells = 6,
  tileset = { id = "TS_CITY" },
  isGrassCell = function() return false end,
  tileAt = function() return 0 end,
}
check(sampler(barren, nil) == nil,
      "a map with no grass cell has no grass art, and says so")

-- and the gate the roamers use is that same walk, stopping at the first hit
local function hasGrass(map)
  for cy = 0, map.heightCells - 1 do
    for cx = 0, map.widthCells - 1 do
      if map:isGrassCell(cx, cy) then return true end
    end
  end
  return false
end
check(hasGrass(hoenn) == true,  "a Hoenn route has grass to populate")
check(hasGrass(kanto) == true,  "so does a Kanto route")
check(hasGrass(barren) == false, "a city with no grass has none, on any generation")

print(("gen3 grass: %d/%d checks passed"):format(checks - fail, checks))
os.exit(fail == 0 and 0 or 1)
