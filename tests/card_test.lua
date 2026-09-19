-- WHERE A CHARACTER CARD ACTUALLY LANDS, measured here instead of in Mauville.
--
-- The report is "npcs under ground with their heads popping up" while the
-- Pokemon standing beside them are fine -- and those two take different draw
-- paths: a Pokemon is a model placed at `mon:matrix(x, gh, z, ...)`, and an
-- NPC is a billboard placed by billboardMatrix.  So the question is narrow:
-- for a given ground height, what Y does the card's matrix put its feet at?
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
-- the engine repo, for the real SpriteRenderer the frame pick goes through;
-- ENGINE_ROOT overrides it when the checkout is somewhere else
package.path = (os.getenv("ENGINE_ROOT") or (HERE .. "/../../../..")) ..
  "/?.lua;" .. package.path
love = require("tests.love_stub")
love.timer = love.timer or {}
love.timer.getDelta = function() return 1/60 end
love.timer.getTime = function() return 0 end

local MODLIB = os.getenv("MOD_LIB") or (HERE .. "/../lib/")

local captured = nil
local blend = 0

local Mat4 = assert(loadfile(MODLIB .. "Mat4.lua"))(nil)
local stubs = {
  Mat4 = Mat4,
  FirstPerson = {
    cardBlend = function() return blend end,
    cardYaw = function() return 0 end,
    hidePlayer = function() return false end,
    playerFacing = function(f) return f end,
    apparentFacing = function(f) return f end,
  },
  SpriteBillboards = {
    mesh = function() return { "mesh" } end,
    getSpriteDimensions = function() return 16, 32, 16, 32 end,
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
  -- the card's PITCH reads a number off here (leanAngle); as an inert table
  -- it answered a function and billboardMatrix died on the first arithmetic
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

-- the engine's sprite renderer picks the frame; stub it so frameFor is cheap
package.loaded["src.render.SpriteRenderer"] = {
  frameFor = function() return 0, false end,
  FRAMES = {}, facingFrame = function() return 0, false end,
}

local fail, checks = 0, 0
local function near(got, want, what, tol)
  checks = checks + 1
  tol = tol or 0.001
  if type(got) ~= "number" or math.abs(got - want) > tol then
    fail = fail + 1
    print(("FAIL %s (got %s, wanted %s)"):format(what, tostring(got), tostring(want)))
  end
end

local sprite = {
  def = { image = "x", scale = 1.0, trueColor = true },
  resolveImage = function() return {} end,
}

-- Mat4.translate(x, y, z) -- find which slot carries the Y translation by
-- building a known one rather than assuming a row/column convention.
local probe = Mat4.translate(0, 123, 0)
local ySlot = nil
for i = 1, 16 do if math.abs((probe[i] or 0) - 123) < 0.001 then ySlot = i end end
if not ySlot then print("could not locate the Y translation slot"); os.exit(1) end

local function feetOf(gh, lift, b)
  blend = b or 0
  captured = nil
  VS.drawEntity(sprite, 100, 200, "down", 0, false, gh, nil, lift or 0, 0, false, 0)
  if not captured then return nil end
  return captured[ySlot]
end

-- ---- the top-down rungs: feet on the ground ------------------------------
near(feetOf(0, 0, 0), 0, "flat ground: the card's origin is the ground")
near(feetOf(32, 0, 0), 32, "a terrace at 32 puts it at 32")
near(feetOf(32, 8, 0), 40, "...plus its hop")

-- ---- first person, where the lean goes away -----------------------------
near(feetOf(32, 0, 1), 32, "in first person the card is still AT the ground")
near(feetOf(32, 0, 0.5), 32, "...and halfway through the blend too")

-- ---- THE CAMERA YAW ACTUALLY REACHES THE CARD ---------------------------
--
-- `drawCast` took four parameters and was called with five, and each
-- `drawEntity` inside it passed eleven arguments into a twelve-parameter
-- list, so the yaw slid off the end and every billboard in the world was
-- built with `yaw = nil`.  Lua pads and truncates silently, so the only
-- evidence was the picture.  Ask the matrix instead.
--
-- Mat4.translate(x, y, z) alone leaves the X/Z slots at the translation; a
-- rotateY chained onto it mixes them.  So compare a card built with a yaw
-- against the same card built without one -- if the two matrices are
-- identical, the yaw never arrived.
local function matrixFor(yaw)
  captured = nil
  blend = 0
  VS.drawEntity(sprite, 100, 200, "down", 0, false, 0, nil, 0, 0, false, yaw)
  return captured
end
do
  local a, b = matrixFor(0), matrixFor(math.pi / 2)
  checks = checks + 1
  if not (a and b) then
    fail = fail + 1
    print("FAIL the yaw probe captured no matrix")
  else
    local differs = false
    for i = 1, 16 do
      if math.abs((a[i] or 0) - (b[i] or 0)) > 0.001 then differs = true break end
    end
    if not differs then
      fail = fail + 1
      print("FAIL a quarter turn of camera yaw did not change the card matrix "
            .. "-- the yaw is not reaching billboardMatrix")
    end
  end
end

-- ...and the feet stay put through the turn: a yaw swings the card about its
-- own centre, it does not lift or drop it.
near(select(1, (function()
  captured = nil
  blend = 0
  VS.drawEntity(sprite, 100, 200, "down", 0, false, 32, nil, 0, 0, false,
                math.pi / 2)
  return captured and captured[ySlot]
end)()), 32, "a yawed card still stands on its ground")

print(("card placement: %d/%d checks passed"):format(checks - fail, checks))
os.exit(fail == 0 and 0 or 1)
