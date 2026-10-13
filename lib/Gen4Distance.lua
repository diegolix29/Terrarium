-- Gen4Distance: ONE draw-distance ladder for the Gen 4 effects.
--
-- WHY THIS EXISTS
--
-- DRAW DIST (DrawDistance) and RENDER DIST (ViewBox) only act inside
-- VoxelScene, which never runs on Platinum, so on Gen 4 neither row did
-- anything. Gen4Trees baked and drew a whole 5x5 block of lands (a Route 202
-- window is ~2M tree quads) however far away they were.
--
-- This module is the one place that says "how far, in world units, do the
-- expensive Gen 4 effects bother". Today only Gen4Trees reads it; grass, sand,
-- water and sprites can ask the same question later.
--
-- THE LADDER (in engine chunks of ground.chunkPx, 512 units each)
--
--   NEAR  1.0 chunks    voxel trees only around the player
--   MID   1.5 chunks    (default)
--   FAR   2.0 chunks
--   MAX   no limit      the old behaviour: every land of the window
--
-- Past the range, Platinum's own flat tree cards keep drawing (Gen4Hide only
-- hides cards on lands that have voxel trees), so the far field is cheap trees,
-- not bare ground.
--
-- The row is listed MID, FAR, MAX, NEAR because ModSetting's FIRST value is
-- its default.

local V = ...

local D = {}

D.KEY = "gen4DrawDist"
D.LABEL = "G4 DRAW DIST"

-- chunks of reach per rung; math.huge = unlimited
D.REACH = { near = 1.0, mid = 1.5, far = 2.0, max = math.huge }

local okS, ModSetting = pcall(function() return V.require("ModSetting") end)
if okS and type(ModSetting) == "table" and ModSetting.new then
  D.setting = ModSetting.new(D.KEY, D.LABEL,
                             { "mid", "far", "max", "near" },
                             { "MID", "FAR", "MAX", "NEAR" })
end

-- the rung name ("near" | "mid" | "far" | "max")
function D.level()
  if D.forced then return D.forced end
  local s = D.setting
  local v = s and s.get and s:get() or nil
  if D.REACH[v] then return v end
  return "mid"
end

-- Reach in world units for a ground whose chunks are `chunkPx` wide.
-- math.huge when the ladder is at MAX.
function D.reach(chunkPx)
  local chunks = D.REACH[D.level()] or D.REACH.mid
  if chunks == math.huge then return math.huge end
  return chunks * (tonumber(chunkPx) or 512)
end

-- Is a square land (centre cx, cz; side `px`) within `reach` of the eye (ex, ez)?
-- Distance is to the NEAREST POINT of the land, so a camera standing at a
-- chunk's edge still gets the trees right across that edge.
function D.landInReach(ex, ez, cx, cz, px, reach)
  if reach == math.huge then return true end
  local h = px * 0.5
  local dx = math.max(math.abs(ex - cx) - h, 0)
  local dz = math.max(math.abs(ez - cz) - h, 0)
  return dx * dx + dz * dz <= reach * reach
end

function D.row()
  return D.setting and D.setting:row() or nil
end

function D.sync(value)
  if D.setting and D.setting.sync then D.setting:sync(value) end
end

return D
