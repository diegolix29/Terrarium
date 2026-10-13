-- Gen4Cull: a conservative "is this chunk anywhere near the view?" test.
--
-- The Gen 4 effects (voxel trees above all) draw every mesh of every land in
-- their window each pass, whether or not the camera can see it: a Route 202
-- window is ~2 million tree quads, and the Colosseum overworld arena draws the
-- window a second time through its own camera. This answers "can the camera
-- possibly see a sphere here" so those loops can skip what is behind or far
-- beside it.
--
-- It tests the sphere against the CONE that circumscribes the view frustum
-- (through its corners), widened by a margin, so it only ever says "no" for a
-- sphere that is well outside the picture. A wrong "yes" costs a draw; a wrong
-- "no" would pop a tree, so every choice here leans to "yes".

local Cull = {}

local sqrt, acos, asin, atan, tan = math.sqrt, math.acos, math.asin, math.atan, math.tan
local ALWAYS = function() return true end

-- eye {x,y,z}; forward {x,y,z} (need not be unit); fovY the VERTICAL field of
-- view in radians; aspect = width / height; margin in radians (default 0.2).
-- Returns f(x, y, z, r) -> true unless a sphere of radius r at (x, y, z) lies
-- entirely outside the widened cone. Bad input gives a test that always says yes.
function Cull.sphereTest(eye, forward, fovY, aspect, margin)
  if type(eye) ~= "table" or type(forward) ~= "table" then return ALWAYS end
  local ex, ey, ez = tonumber(eye[1]), tonumber(eye[2]), tonumber(eye[3])
  local fx, fy, fz = tonumber(forward[1]), tonumber(forward[2]), tonumber(forward[3])
  fovY = tonumber(fovY)
  if not (ex and ey and ez and fx and fy and fz and fovY) then return ALWAYS end
  local len = sqrt(fx * fx + fy * fy + fz * fz)
  if not (len > 1e-9) or fovY <= 0 or fovY >= math.pi then return ALWAYS end
  fx, fy, fz = fx / len, fy / len, fz / len
  aspect = tonumber(aspect)
  if not (aspect and aspect > 0) then aspect = 1 end
  local half = atan(tan(fovY / 2) * sqrt(1 + aspect * aspect)) + (tonumber(margin) or 0.2)

  return function(x, y, z, r)
    local dx, dy, dz = x - ex, y - ey, z - ez
    local d = sqrt(dx * dx + dy * dy + dz * dz)
    if d <= r then return true end            -- the eye is inside the sphere
    local c = (dx * fx + dy * fy + dz * fz) / d
    if c > 1 then c = 1 elseif c < -1 then c = -1 end
    local s = r / d
    if s > 1 then s = 1 end
    return acos(c) - asin(s) <= half
  end
end

return Cull
