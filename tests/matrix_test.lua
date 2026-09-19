-- IS THE CARD'S MATRIX STILL THE SAME MATRIX?
--
-- billboardMatrix used to build its transform the readable way: a translate,
-- then a rotateY, then a rotateX, then maybe a scale, then another translate,
-- chained with Mat4.mul.  Every one of those allocates a fresh sixteen-slot
-- table and every mul does sixty-four multiplies, so one card cost about nine
-- tables and four full matrix products -- per card, per pass, and the cast is
-- drawn twice (once for the eye, once for the sun).  In a town that is
-- thousands of short-lived tables a frame, which is GC the frame has to pay
-- for somewhere.
--
-- The chain is fixed, so it collapses to one table constructor.  That is only
-- safe if the result is IDENTICAL, so this suite builds the reference chain
-- with the real Mat4 and compares all sixteen slots, over the whole parameter
-- space that matters: yaw on and off, mirrored and not, first-person blend in
-- and out, and a lean that is not the default.
--
-- Run it against the OLD implementation and it passes too -- that is the
-- point.  It pins the behaviour, not the optimisation.
--
--   texlua tests/matrix_test.lua
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local MODLIB = os.getenv("MOD_LIB") or (HERE .. "/../lib/")
package.path = (os.getenv("ENGINE_ROOT") or (HERE .. "/../../../..")) ..
  "/?.lua;" .. package.path

local captured, blend, lean, cardYaw = nil, 0, 0, 0

-- MIRRORING IS NOT AN INPUT, it is decided inside frameFor from the facing:
-- a sprite sheet with more than one frame draws "right" as a flipped "left".
-- So the mirrored cases are driven by facing the card right, not by a flag --
-- which is also the only way to be sure the test exercises the real path.
local function mirrorOf(facing) return facing == "right" end

local Mat4 = assert(loadfile(MODLIB .. "Mat4.lua"))(nil)
local stubs = {
  Mat4 = Mat4,
  FirstPerson = {
    cardBlend = function() return blend end,
    cardYaw   = function() return cardYaw end,
    hidePlayer = function() return false end,
    playerFacing = function(f) return f end,
    apparentFacing = function(f) return f end,
  },
  SpriteBillboards = {
    mesh = function() return { "mesh" } end,
    getSpriteDimensions = function() return 16, 32, 24, 40 end,
    getLodBiasForScale = function() return 0 end,
  },
  Voxel3D = {
    draw = function(_, _, matrix) captured = matrix end,
    setLodBias = function() end,
    casterMatrix = function() return {} end,
    glass = function() end, seams = function() end,
    vp = {}, eye = nil,
  },
  ShadowMap = { snug = function(m) return m end },
  TerrainAtlas = { forSprite = function() return nil end },
  VoxelState = { angle = 0 },
}
local inert = setmetatable({}, { __index = function(t, k)
  local v = setmetatable({}, { __index = function() return function() end end })
  rawset(t, k, v); return v
end })
local V = {}
V.mod = { log = { info = function() end, warn = function() end, error = function() end } }
V.data = function() return {} end
V.require = function(n) return stubs[n] or inert[n] end
V.engineRequire = require

local chunk = assert(loadfile(MODLIB .. "VoxelScene.lua"))
local ok, VS = pcall(chunk, V)
if not ok then print("INIT FAIL: " .. tostring(VS)); os.exit(1) end

package.loaded["src.render.SpriteRenderer"] = {
  STAND = { up = 0, down = 1, left = 2, right = 3 },
  WALK  = { up = 4, down = 5, left = 6, right = 7 },
  FRAMES = {},
  frameFor = function() return 0, false end,
  facingFrame = function() return 0, false end,
}

local fail, checks = 0, 0

-- the chain exactly as it was written, against the real Mat4
local function reference(px, py, y, mirror, yaw, w, h)
  local halfW, halfH = w / 2, h / 2
  local b = blend
  local m = Mat4.translate(px + halfW, y, py + halfH)
  if b > 0 then
    m = Mat4.mul(m, Mat4.rotateY(cardYaw * b))
  elseif yaw and yaw ~= 0 then
    m = Mat4.mul(m, Mat4.rotateY(yaw))
  end
  m = Mat4.mul(m, Mat4.rotateX((lean - math.pi / 2) * (1 - b)))
  if mirror then m = Mat4.mul(m, Mat4.scale(-1, 1, 1)) end
  return Mat4.mul(m, Mat4.translate(-halfW, 0, 0))
end

-- frames > 1, or frameFor never reaches the branch that decides mirroring
local sprite = {
  def = { image = "x", scale = 1.0, trueColor = true, frames = 4 },
  resolveImage = function() return {} end,
}

local function compare(what, px, py, gh, yaw, facing, b, ln, cy)
  blend, lean, cardYaw = b, ln, cy
  stubs.VoxelState.angle = ln
  local mirror = mirrorOf(facing)
  captured = nil
  VS.drawEntity(sprite, px, py, facing, 0, false, gh, nil, 0, 0, false, yaw)
  checks = checks + 1
  local want = reference(px, py, gh, mirror, yaw, 24, 40)
  if not captured then
    fail = fail + 1
    print("FAIL " .. what .. ": no matrix captured")
    return
  end
  for i = 1, 16 do
    local g, w2 = captured[i] or 0, want[i] or 0
    if math.abs(g - w2) > 1e-9 then
      fail = fail + 1
      print(("FAIL %s: slot %d is %.9f, the chain gives %.9f")
        :format(what, i, g, w2))
      return
    end
  end
end

--            what                        px    py   gh   yaw          mir    blend lean  cardYaw
compare("flat, no yaw",                   100,  200,  0,  0,           false, 0,    0,    0)
compare("flat, yaw a quarter turn",       100,  200,  0,  math.pi / 2, false, 0,    0,    0)
compare("yaw and a ground height",         64,   48, 32,  1.3,         false, 0,    0,    0)
compare("mirrored",                        64,   48, 32,  1.3,         true,  0,    0,    0)
compare("mirrored, no yaw",                64,   48, 32,  0,           true,  0,    0,    0)
compare("a lean that is not the default",  64,   48, 32,  1.3,         false, 0,    0.7,  0)
compare("first person, blend fully in",    64,   48, 32,  1.3,         false, 1,    0.7,  0.9)
compare("first person, halfway",           64,   48, 32,  1.3,         false, 0.5,  0.7,  0.9)
compare("first person, mirrored",          64,   48, 32,  1.3,         true,  0.5,  0.7,  0.9)
compare("negative yaw",                   -32,  -16,  8,  -2.1,        false, 0,    0.2,  0)
compare("a full turn of yaw",              10,   10,  0,  math.pi * 2, false, 0,    0,    0)
compare("blend just off zero",             10,   10,  0,  1.0,         true,  0.01, 0.4,  -1.7)

print(("card matrix: %d/%d checks passed"):format(checks - fail, checks))
os.exit(fail == 0 and 0 or 1)
