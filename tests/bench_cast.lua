-- HOW LONG THE CAST PASS SPENDS ON THE CPU, PER FRAME, WITHOUT THE GAME.
--
-- `voxel: cast` measured 78 ms a frame in Mauville and there is no way to
-- iterate on that by walking to Mauville.  So: the REAL drawEntity, the REAL
-- SpriteBillboards and the REAL billboard/caster/snug maths, against a
-- counting stand-in for the graphics device, driven with a town-sized crowd.
--
-- What this measures is the CPU side only -- frame setup, the per-card
-- lookups, the transform builds and the allocation they cause.  It does not
-- measure the driver or the GPU, which is the right scope: the frame profile
-- put `present` at half a millisecond, so the game is CPU-bound and this is
-- the half that can be moved.
--
-- Absolute numbers here are texlua (plain Lua 5.3), not LuaJIT, so they run
-- several times slower than the game.  Read the RATIO between two runs, not
-- the milliseconds.
--
--   texlua tests/bench_cast.lua [lib-dir] [frames]
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local LIB = arg[1] or os.getenv("MOD_LIB") or (HERE .. "/../lib/")
if LIB:sub(-1) ~= "/" then LIB = LIB .. "/" end
local FRAMES = tonumber(arg[2]) or 200
-- the engine checkout, so VoxelScene's `require` calls resolve for real
package.path = (os.getenv("ENGINE_ROOT") or (HERE .. "/../../../..")) ..
  "/?.lua;" .. package.path
local ACTORS = 150

-- ---- a graphics device that only counts ---------------------------------
local drawCalls = 0
local function imageStub(w, h)
  return {
    getDimensions = function() return w, h end,
    setFilter = function() end,
    setMipmapFilter = function() end,
  }
end
local IMAGES = setmetatable({}, { __index = function(t, k)
  local v = imageStub(24, 160)      -- a 4-frame 24x40 walker sheet
  rawset(t, k, v); return v
end })
package.loaded["src.render.Assets"] = {
  image = function(name) return IMAGES[name] end,
  register = function() end,
}
-- engine modules VoxelScene pulls in at load, stubbed so the file can be
-- loaded outside the game
package.loaded["src.render.PaletteFX"] = {
  usesGbcPack = function() return false end,
  register = function() end,
}
package.loaded["src.core.Logger"] = {
  info = function() end, warn = function() end, error = function() end,
  debug = function() end, report = function() end, flush = function() end,
}
package.loaded["src.core.FrameProfile"] = {
  section = function() return nil end, count = function() end,
  add = function() end, now = os.clock,
}
package.loaded["src.render.SpriteRenderer"] = {
  STAND = { up = 0, down = 1, left = 2, right = 3 },
  WALK  = { up = 4, down = 5, left = 6, right = 7 },
  FRAMES = {},
  frameFor = function() return 0, false end,
  facingFrame = function() return 0, false end,
}
love = nil   -- buildCard's filtering branch is skipped without it

local Mat4 = assert(loadfile(LIB .. "Mat4.lua"))(nil)

-- the real caster maths, lifted out of Voxel3D without its shaders
local casterMatrix
do
  local inert = setmetatable({}, { __index = function(t, k)
    local v = setmetatable({}, { __index = function() return function() end end })
    rawset(t, k, v); return v
  end })
  local V = { require = function(n) return n == "Mat4" and Mat4 or inert[n] end,
              mod = { log = { info = function() end, warn = function() end } },
              data = function() return {} end, engineRequire = require }
  local ok, mod = pcall(function() return assert(loadfile(LIB .. "Voxel3D.lua"))(V) end)
  casterMatrix = ok and type(mod) == "table" and mod.casterMatrix or nil
end
if not casterMatrix then
  print("could not load Voxel3D headless -- cannot benchmark honestly")
  os.exit(1)
end

-- the real ShadowMap.snug, likewise
local snug
do
  local inert = setmetatable({}, { __index = function(t, k)
    local v = setmetatable({}, { __index = function() return function() end end })
    rawset(t, k, v); return v
  end })
  local V = { require = function(n) return n == "Mat4" and Mat4 or inert[n] end,
              mod = { log = { info = function() end, warn = function() end } },
              data = function() return {} end, engineRequire = require }
  local ok, mod = pcall(function() return assert(loadfile(LIB .. "ShadowMap.lua"))(V) end)
  snug = ok and type(mod) == "table" and mod.snug or nil
end

-- ---- the mod's own VoxelScene, with the real SpriteBillboards -----------
local SB
do
  local inert = setmetatable({}, { __index = function(t, k)
    local v = setmetatable({}, { __index = function() return function() end end })
    rawset(t, k, v); return v
  end })
  -- SpriteBillboards asks Voxel3D for newMesh/pushQuad.  These have to return
  -- something truthy or every card misses, drawEntity bails on the nil mesh,
  -- and the benchmark measures an early return instead of the pass.
  local vox = {
    newMesh = function(verts, idx) return { verts = verts, idx = idx } end,
    pushQuad = function(t, base)
      t[#t+1] = base+1; t[#t+1] = base+2; t[#t+1] = base+3
      t[#t+1] = base+1; t[#t+1] = base+3; t[#t+1] = base+4
    end,
  }
  local V = { require = function(n) return n == "Voxel3D" and vox or inert[n] end,
              engineRequire = require,
              mod = { log = { info = function() end, warn = function() end } },
              data = function() return {} end }
  SB = assert(loadfile(LIB .. "SpriteBillboards.lua"))(V)
end

local inert = setmetatable({}, { __index = function(t, k)
  local v = setmetatable({}, { __index = function() return function() end end })
  rawset(t, k, v); return v
end })
local stubs = {
  Mat4 = Mat4,
  SpriteBillboards = SB,
  FirstPerson = {
    cardBlend = function() return 0 end,
    cardYaw = function() return 0 end,
    hidePlayer = function() return false end,
    playerFacing = function(f) return f end,
    apparentFacing = function(f) return f end,
  },
  Voxel3D = {
    draw = function() drawCalls = drawCalls + 1 end,
    setLodBias = function() end,
    casterMatrix = casterMatrix,
    glass = function() end, seams = function() end, vp = {}, eye = nil,
  },
  ShadowMap = { snug = snug or function(m) return m end },
  TerrainAtlas = { forSprite = function() return nil end },
  VoxelState = { angle = 0 },
}
local V = { mod = { log = { info = function() end, warn = function() end,
                            error = function() end } },
            data = function() return {} end, engineRequire = require }
V.require = function(n) return stubs[n] or inert[n] end
local VS = assert(loadfile(LIB .. "VoxelScene.lua"))(V)

-- ---- a town's worth of actors -------------------------------------------
local FACING = { "down", "up", "left", "right" }
local cast = {}
for i = 1, ACTORS do
  cast[i] = {
    sprite = { def = { image = "npc" .. (i % 12), scale = 1.0, frames = 4 },
               resolveImage = function() return IMAGES["t"] end },
    px = (i * 37) % 640, py = (i * 53) % 320,
    gh = (i % 4) * 16, facing = FACING[(i % 4) + 1],
    phase = i % 2, flip = (i % 3) == 0,
  }
end

-- ALLOCATED, not merely kept.  What matters for a frame budget is how much
-- garbage the pass makes -- that is the work the collector has to do while
-- the game is trying to hold sixty frames -- and post-collection residue
-- says nothing about it.  So the collector is stopped and the heap growth
-- over the run is the answer.
collectgarbage("collect")
collectgarbage("stop")
local kb0 = collectgarbage("count")
local t0 = os.clock()
for _ = 1, FRAMES do
  for i = 1, ACTORS do
    local a = cast[i]
    -- the eye pass and the sun pass both build a card for every actor
    VS.drawEntity(a.sprite, a.px, a.py, a.facing, a.phase, a.flip, a.gh,
                  nil, 0, 0, false, 0.6)
    VS.drawEntity(a.sprite, a.px, a.py, a.facing, a.phase, a.flip, a.gh,
                  nil, 0, 0, false, 0.6)
  end
end
local dt = os.clock() - t0
local kb = collectgarbage("count") - kb0
collectgarbage("restart")

print(("lib: %s"):format(LIB))
print(("%d frames x %d actors x 2 passes  (%d draw calls)")
  :format(FRAMES, ACTORS, drawCalls))
print(("  cpu        %8.1f ms total    %6.3f ms/frame"):format(dt * 1000, dt * 1000 / FRAMES))
print(("  garbage    %8.1f KB allocated   %6.1f KB/frame"):format(kb, kb / FRAMES))
