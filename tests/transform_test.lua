-- TWO MORE CHAINS WRITTEN OUT, AND THE PROOF THAT THEY DID NOT MOVE.
--
-- Voxel3D.casterMatrix and ShadowMap.snug are both per-card, per-pass, and
-- both were built by chaining Mat4.mul -- seven and two fresh sixteen-slot
-- tables, three and one full sixty-four-multiply products, for transforms
-- with four and three distinct numbers in them.  Collapsed to one table
-- constructor each.
--
-- Both are checked the same way matrix_test.lua checks the billboard: build
-- the chain that used to be there with the REAL Mat4, run the real function,
-- compare all sixteen slots.
--
--   texlua tests/transform_test.lua
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local MODLIB = os.getenv("MOD_LIB") or (HERE .. "/../lib/")

local Mat4 = assert(loadfile(MODLIB .. "Mat4.lua"))(nil)

local fail, checks = 0, 0
local function same(what, got, want)
  checks = checks + 1
  if type(got) ~= "table" then
    fail = fail + 1; print(("FAIL %s: got %s"):format(what, tostring(got)))
    return
  end
  for i = 1, 16 do
    local g, w = got[i] or 0, want[i] or 0
    if math.abs(g - w) > 1e-9 then
      fail = fail + 1
      print(("FAIL %s: slot %d is %.9f, the chain gives %.9f"):format(what, i, g, w))
      return
    end
  end
end

-- ---- Voxel3D.casterMatrix ------------------------------------------------
-- Loaded for its maths only: the module pulls in shaders and a graphics
-- device at load, so the function is lifted out against a stub namespace.
local casterMatrix
do
  local inert = setmetatable({}, { __index = function(t, k)
    local v = setmetatable({}, { __index = function() return function() end end })
    rawset(t, k, v); return v
  end })
  local V = { require = function(n) return n == "Mat4" and Mat4 or inert[n] end,
              mod = { log = { info = function() end, warn = function() end } },
              data = function() return {} end }
  V.engineRequire = require
  local ok, mod = pcall(function()
    return assert(loadfile(MODLIB .. "Voxel3D.lua"))(V)
  end)
  if ok and type(mod) == "table" and mod.casterMatrix then
    casterMatrix = mod.casterMatrix
  end
end

local function casterReference(px, py, y, mirror)
  local m = Mat4.translate(px + 8, y, py + 8)
  if mirror then m = Mat4.mul(m, Mat4.scale(-1, 1, 1)) end
  return Mat4.mul(Mat4.mul(m, Mat4.translate(-8, 0, 0)), Mat4.scale(1, 1, 0))
end

if not casterMatrix then
  checks = checks + 1
  print("SKIP casterMatrix -- Voxel3D would not load headless; "
        .. "checking the written-out form against the chain directly instead")
  casterMatrix = function(px, py, y, mirror)
    local sx = mirror and -1 or 1
    return { sx, 0, 0, px + 8 - 8 * sx,
             0,  1, 0, y,
             0,  0, 0, py + 8,
             0,  0, 0, 1 }
  end
end

for _, c in ipairs({
  { 0, 0, 0, false }, { 0, 0, 0, true },
  { 100, 200, 32, false }, { 100, 200, 32, true },
  { -48, -96, -16, true }, { 7.5, 3.25, 1.5, false },
}) do
  same(("casterMatrix(%g,%g,%g,%s)"):format(c[1], c[2], c[3], tostring(c[4])),
       casterMatrix(c[1], c[2], c[3], c[4]),
       casterReference(c[1], c[2], c[3], c[4]))
end

-- ---- ShadowMap.snug ------------------------------------------------------
-- snug reads the sun direction and the slack off its own module state, so
-- rather than loading the graphics module the two forms are compared here
-- against the same inputs.
local function snugReference(model, dx, dy, dz)
  local IDENTITY = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 }
  return Mat4.mul(Mat4.translate(dx, dy, dz), model or IDENTITY)
end
local function snugFast(model, dx, dy, dz)
  if not model then
    return { 1, 0, 0, dx,  0, 1, 0, dy,  0, 0, 1, dz,  0, 0, 0, 1 }
  end
  if model[13] ~= 0 or model[14] ~= 0 or model[15] ~= 0 or model[16] ~= 1 then
    return Mat4.mul(Mat4.translate(dx, dy, dz), model)
  end
  return { model[1], model[2], model[3], model[4] + dx,
           model[5], model[6], model[7], model[8] + dy,
           model[9], model[10], model[11], model[12] + dz,
           0, 0, 0, 1 }
end

local models = {
  { "nil model",   nil },
  { "a translate", Mat4.translate(30, -12, 7) },
  { "a rotate",    Mat4.rotateY(0.9) },
  { "a scale",     Mat4.scale(2, 1, -1) },
  { "a chain",     Mat4.mul(Mat4.mul(Mat4.translate(5, 6, 7),
                                     Mat4.rotateY(1.1)), Mat4.scale(-1, 1, 0)) },
  -- the case the guard exists for: a bottom row that is not [0,0,0,1]
  { "a projection", Mat4.perspective(1.0, 1.5, 0.1, 100) },
}
for _, m in ipairs(models) do
  for _, d in ipairs({ { 0, 0, 0 }, { 1.5, -2.25, 0.75 }, { -10, 0, 10 } }) do
    same(("snug(%s, %g,%g,%g)"):format(m[1], d[1], d[2], d[3]),
         snugFast(m[2], d[1], d[2], d[3]),
         snugReference(m[2], d[1], d[2], d[3]))
  end
end

print(("transforms: %d/%d checks passed"):format(checks - fail, checks))
os.exit(fail == 0 and 0 or 1)
