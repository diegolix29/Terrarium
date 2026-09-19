local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
package.path = HERE .. "/?.lua;" .. package.path
local H = dofile(HERE .. "/ground_harness.lua")
local VS, fake, newMap, ck = H.VoxelScene, H.fake, H.newMap, H.ck

local fail, checks = 0, 0
local function eq(got, want, what)
  checks = checks + 1
  if got ~= want then
    fail = fail + 1
    print(("FAIL %s (got %s, wanted %s)"):format(what, tostring(got), tostring(want)))
  end
end
local function clear()
  for _, t in pairs({ fake.shapeAt, fake.terrace, fake.stamp, fake.run,
                      fake.flat, fake.stand, fake.stair, fake.elev,
                      fake.gridHeight, fake.walkable }) do
    for k in pairs(t) do t[k] = nil end
  end
  fake.shapes = {}          -- a fresh analysis, so the memo starts empty
  fake.built = true
  VS.groundTick()
end
-- a cell's tile key, the way groundAt derives it
local function tk(cx, cy) return ck(cx * 2, cy * 2 + 1) end
local function ground(cx, cy) fake.shapeAt[tk(cx, cy)] = { class = "ground", h = 0, flat = true } end

-- ---- the ladder, in order ------------------------------------------------
clear()
ground(5, 5)
fake.terrace[ck(5, 5)] = 32
eq(VS.groundAt(newMap("A"), 5, 5), 32, "a walkable cell stands on its terrace")

clear()
ground(6, 6)
fake.stamp[tk(6, 6)] = 16
eq(VS.groundAt(newMap("A"), 6, 6), 16, "a stamped prop cell answers its stamp")

clear()
ground(7, 7)
fake.run[tk(7, 7)] = 48
eq(VS.groundAt(newMap("A"), 7, 7), 48, "a measured run beats the class height")

clear()
fake.shapeAt[tk(8, 8)] = { class = "wall", h = 16, flat = true }
eq(VS.groundAt(newMap("A"), 8, 8), 16, "and a cell with its own height uses it")

-- THE BUG THAT PUT CHARACTERS UNDERGROUND.  Every reader declines, the four
-- neighbours disagree, and the terrain was raised off the elevation grid.
clear()
ground(9, 9)
fake.gridHeight[ck(9, 9)] = 32
eq(VS.groundAt(newMap("A"), 9, 9), 32,
   "with every reader silent the ELEVATION GRID answers, not the datum")

clear()
ground(10, 10)
eq(VS.groundAt(newMap("A"), 10, 10), 0,
   "...and a cell the grid puts at the datum really is at the datum")

-- ---- THE MAUVILLE BUG: two maps, one tileset ----------------------------
clear()
local mauville, route = newMap("MAUVILLE"), newMap("ROUTE")
ground(10, 10)
fake.terrace[ck(10, 10)] = 32
eq(VS.groundAt(mauville, 10, 10), 32, "the first map reads its terrace")
-- the same cell on another map drawn with the SAME tileset: the shapes table
-- is shared (TileShape caches by tileset id), so a cache keyed on it would
-- hand this map the first one's height
fake.terrace[ck(10, 10)] = nil
fake.gridHeight[ck(10, 10)] = 0
eq(VS.groundAt(route, 10, 10), 0,
   "and the second map does NOT inherit it -- the cache is keyed per map")

-- ---- the memo: same answer, far fewer questions -------------------------
clear()
ground(12, 12)
fake.terrace[ck(12, 12)] = 16
local asked = 0
local realTerrace = fake.terrace
fake.terrace = setmetatable({}, { __index = function(_, k)
  asked = asked + 1
  return realTerrace[k]
end })
local m = newMap("A")
for _ = 1, 50 do VS.groundAt(m, 12, 12) end
eq(VS.groundAt(m, 12, 12), 16, "the memoised answer is the same answer")
if asked > 3 then
  fail = fail + 1
  print(("FAIL fifty asks about one standing actor cost %d lookups"):format(asked))
end
checks = checks + 1
fake.terrace = realTerrace

-- ---- THE MESH'S OWN HEIGHT, which is the rung the ladder was missing ------
--
-- After the datum was fixed, characters still sank on maps with a RAISED
-- TIER.  The tileset's class height for a tier cell is 0 -- the tileset does
-- not know this map lifted it -- so `s.h > 0` rejected it and the cell fell
-- through to the four-neighbour vote, which only answers when all four agree.
-- Beside a building, a fence or the map edge it cannot, and the walker landed
-- on the datum with the tier drawn a course over their head.

clear()
ground(20, 20)                       -- tileset says this class is flat at 0
fake.flat[tk(20, 20)] = 16           -- ...but the mesh drew this tile at 16
eq(VS.groundAt(newMap("A"), 20, 20), 16,
   "a tier cell stands on what the MESH drew, not on the tileset class")

clear()
ground(21, 21)
fake.flat[tk(21, 21)] = 16
fake.walkable[ck(21, 21)] = false
eq(VS.groundAt(newMap("A"), 21, 21), 0,
   "...and an unwalkable cell does not take it (facades keep their own pass)")

-- ORDER: the three rungs above it are the mesher's own first two steps plus
-- the terrace, and each must still win.
clear()
ground(22, 22)
fake.flat[tk(22, 22)] = 16
fake.terrace[ck(22, 22)] = 32
eq(VS.groundAt(newMap("A"), 22, 22), 32, "the terrace still outranks the mesh shape")

clear()
ground(23, 23)
fake.flat[tk(23, 23)] = 16
fake.stamp[tk(23, 23)] = 48
eq(VS.groundAt(newMap("A"), 23, 23), 48, "a stamped cell still outranks it")

clear()
ground(24, 24)
fake.flat[tk(24, 24)] = 16
fake.run[tk(24, 24)] = 64
eq(VS.groundAt(newMap("A"), 24, 24), 64, "a measured run still outranks it")

-- A FLOOR THE MESH DREW AT ZERO IS AN ANSWER, not a decline -- otherwise the
-- grid below would overrule the drawing on a causeway map, which pins its
-- land to the datum on purpose and lets the bridge carry the lift.
clear()
ground(25, 25)
fake.flat[tk(25, 25)] = 0
fake.gridHeight[ck(25, 25)] = 32
eq(VS.groundAt(newMap("A"), 25, 25), 0,
   "the mesh drawing it at the datum beats the grid's opinion of the cell")

-- ...and a cell the mesh laid no flat shape for still falls all the way
-- through, exactly as before.
clear()
ground(26, 26)
fake.gridHeight[ck(26, 26)] = 32
eq(VS.groundAt(newMap("A"), 26, 26), 32,
   "a cell with no mesh shape still reaches the elevation grid")

-- ---- AN UNBUILT MAP'S ANSWER IS NEVER REMEMBERED -------------------------
--
-- Meshing a town takes seconds, and during them every reader in the ladder
-- answers nil, so a character is placed on the datum.  That is fine to draw
-- with and fatal to cache: the build finishes, the ground rises, and the
-- walker stays where they were put -- sunk, with nothing wrong-looking left
-- in the cell to explain it.

-- ONE map object throughout: the memo is keyed on the map table itself, so
-- a fresh newMap() per call would miss every time and the test would pass
-- whether or not anything was being cached.
clear()
local unbuilt = newMap("U")
ground(30, 30)
fake.built = false
eq(VS.groundAt(unbuilt, 30, 30), 0,
   "an unbuilt map still answers, so somebody can be drawn")
-- ...and that answer IS cached while the build runs.  Refusing to cache it
-- was the first cut, and it cost the most at exactly the worst moment: every
-- actor on a map still being meshed walked the whole ladder every frame, and
-- `voxel: poses` went from nine milliseconds to twelve.
eq(VS.groundAt(unbuilt, 30, 30), 0, "...and asking again is cheap, not a rewalk")

-- THE BUILD LANDS.  Structures now has state for the map, so the readers
-- start answering -- and the guess taken before any of them existed must not
-- survive it.  Both halves flip together here because in the real system
-- that is the same event: flatGroundAt answers nothing until the map is in
-- Structures' cache, which is exactly what `built` reports.
fake.flat[tk(30, 30)] = 32
fake.built = true
eq(VS.groundAt(unbuilt, 30, 30), 32,
   "the moment the build lands, the pre-build guess is thrown away")
eq(VS.groundAt(unbuilt, 30, 30), 32, "...and the new height is what is kept")

-- once built, the memo behaves exactly as before
clear()
local builtMap = newMap("B")
ground(31, 31)
fake.flat[tk(31, 31)] = 16
eq(VS.groundAt(builtMap, 31, 31), 16, "a built map answers from the mesh")
fake.flat[tk(31, 31)] = 48
eq(VS.groundAt(builtMap, 31, 31), 16,
   "...and is remembered, rather than asked again every frame")

print(("ground ladder: %d/%d checks passed"):format(checks - fail, checks))
os.exit(fail == 0 and 0 or 1)
