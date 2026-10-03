-- Gen4Grass: the voxel scene's own authored 3D grass, planted in Gen 4's world.
--
-- This used to be a separate hand-made tuft. It is not any more: the tuft is the
-- SAME OUTSIDE MESH the voxel scene stamps on every tall-grass tile -- the bake
-- under assets/ground/grass/ (grass.mesh.bin + grass.png), loaded and stamped by
-- lib/Grass3D.lua -- so the two worlds grow the same meadow. Wind (Wind.amount /
-- Wind.load), the bend curve (Voxel3D.grassH) and foot-crush (Grass3D.crushFrame)
-- are the voxel scene's own too; nothing here reimplements any of them.
--
-- WHERE IT GROWS
--
-- On tall grass and very tall grass, and nowhere else. A Gen 4 map stores the
-- tile behaviour in the cell itself (Map:blockAt IS the behaviour byte -- see
-- Gen4Battle.behaviourUnder in the engine), and tall grass is 2 and very tall
-- grass is 3. The previous version asked Map:isEncounterCell, which is the
-- broader question "can a wild Pokemon come from here": it answers yes for
-- surfable water, which is how grass ended up growing on the lakes. Water is
-- also excluded by Map:isWaterCell as a second, independent guard.
--
-- SCALE AND DENSITY
--
-- One world unit is one map pixel and a cell is 16 of them in BOTH worlds, so
-- nothing is rescaled. What differs is the grid the bake is stamped on: the
-- voxel scene plants one tuft per 8-pixel TILE, which is four to a cell, and
-- that is what this does too (2x2 per cell, Grass3D.instanceForTile for each).
-- (An earlier version treated Gen 4's cell as a single tile and stamped one
-- double-size tuft per cell; that was wrong -- it was half the density at twice
-- the size, and doubled the wind and crush values to match.)
--
-- HEIGHT
--
-- Gen 4 terrain is not flat. Tufts are bucketed by the ground height under each
-- one and each bucket is its own small mesh drawn translated up to that height,
-- exactly how ChunkMesher.buildGrassMesh does it: the wind shader reads a
-- vertex's raw Y as "how far up THIS tuft", so the height has to live in the
-- draw's translation and never in the vertex data.
--
-- If the bake is not on disk, or the GRASS row is set to VOXEL (the classic flat
-- slab, which has no equivalent here), nothing is drawn -- no substitute grass.

local V = ...
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")

local Grass = {
  CHUNK = 4,             -- cells per side of one baked mesh
  WINDOW = 2,            -- engine chunks each way that Platinum draws ground for
                         -- (Gen4Ground FREE_RADIUS): grass grows on all of them
  RADIUS = 3,            -- fallback only: grass chunks around the focus, used when
                         -- the ground's chunk grid is not available
  BUILDS_PER_FRAME = 24, -- most chunk meshes built in one frame
  BUILD_BUDGET = 0.004,  -- seconds of building per frame (at least one is built)
  TALL_GRASS = 2,        -- Gen 4 tile behaviours
  VERY_TALL_GRASS = 3,
}

local warned = {}
local function once(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if V.mod and V.mod.log then V.mod.log:info("Gen4Grass: " .. fmt:format(...)) end
end

local function optional(name)
  local ok, mod = pcall(V.require, name)
  return ok and mod or nil
end

-- map -> { chunks = { ["cx:cy"] = { buckets = { {mesh, y}, ... } } } }
local cache = setmetatable({}, { __mode = "k" })

local function isTallGrass(map, cx, cy)
  -- Gen4Cells reads the live Map inside its crop and the shared layout beyond
  -- it, so grass grows on the neighbouring maps' ground too (a Gen 4 Map is
  -- only a rectangle cut out of the grid the engine draws around you).
  local Cells = optional("Gen4Cells")
  local b
  if Cells then b = Cells.behaviour(map, cx, cy)
  elseif map.blockAt and map.inBounds and map:inBounds(cx, cy) then
    local okB, v = pcall(map.blockAt, map, cx, cy)
    b = okB and v or nil
  end
  if not (b == Grass.TALL_GRASS or b == Grass.VERY_TALL_GRASS) then return false end
  -- never on water, whatever the behaviour byte says (only the live Map can
  -- be asked; beyond its crop the behaviour byte alone has to do)
  if map.isWaterCell and map.inBounds and map:inBounds(cx, cy) then
    local okW, water = pcall(map.isWaterCell, map, cx, cy)
    if okW and water then return false end
  end
  return true
end

-- Gen4Spawn asks "is this cell grass?" through this name. Same test the 3D
-- tufts are planted by, so a roamer stands exactly where the grass grows.
Grass.isGrassCell = isTallGrass

-- One chunk's meshes, or an empty record when it has no tall grass. Instances
-- come from Grass3D.instanceForTile, so the yaw/scale hash is the voxel
-- scene's own; only where they stand and how big they are is Gen 4's.
local function buildChunk(Grass3D, scene, map, kx, ky)
  local C = Grass.CHUNK
  local order, buckets = {}, {}
  for cy = ky * C, ky * C + C - 1 do
    for cx = kx * C, kx * C + C - 1 do
      if isTallGrass(map, cx, cy) then
        local y = math.floor((scene.groundY(cx * 16 + 8, cy * 16 + 8) or 0) + 0.5)
        local bucket = buckets[y]
        if not bucket then bucket = {}; buckets[y] = bucket; order[#order + 1] = y end
        -- the four 8 px tiles of this cell, each planted the way the voxel
        -- scene plants it (instanceForTile puts the origin at tile * 8)
        for ty = cy * 2, cy * 2 + 1 do
          for tx = cx * 2, cx * 2 + 1 do
            bucket[#bucket + 1] = Grass3D.instanceForTile(tx, ty, y)
          end
        end
      end
    end
  end
  local out = {}
  for _, y in ipairs(order) do
    local mesh = Grass3D.meshFromInstances(buckets[y])
    if mesh then out[#out + 1] = { mesh = mesh, y = y } end
  end
  return { buckets = out }
end

-- Voxel3D's per-scene grass state. beginScene() clears it every frame, so it is
-- set here each time, the way VoxelScene's grass pass sets it.
local lastAt = nil
local function prepare(Grass3D, scene)
  local Wind = optional("Wind")
  local sway = 0
  if Wind and Wind.amount then
    local ok, v = pcall(Wind.amount)
    if ok and tonumber(v) then sway = v end
  end
  local h
  local okM, meta = pcall(Grass3D.meta)
  if okM and meta and tonumber(meta.height) and meta.height > 0.5 then
    h = meta.height
  end
  Voxel3D.grassH = h
  local wet, snow, gust = 0, 0, 0
  if Wind and Wind.load then
    local okL, a, b, c = pcall(Wind.load)
    if okL then wet, snow, gust = a or 0, b or 0, c or 0 end
  end
  Voxel3D.grassLoad = { wet, snow, gust }

  -- Everyone walking the meadow parts it. Only the player is asked for: the
  -- springs are Grass3D's, this just says where the feet are, in Gen 4 world
  -- space.
  local feet = {}
  local okG, Game = pcall(require, "src.core.Game")
  local me = okG and Game and Game.overworld and Game.overworld.player
  if me and tonumber(me.px) and tonumber(me.py) then
    local moving = math.abs(me.lift or 0) > 0.15
    feet[1] = { me.px + 8 + scene.offsetX, me.py + 8 + scene.offsetZ,
                moving and 12 or 10, moving and 1.0 or 0.6 }
  end
  local now = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
  local dt = lastAt and (now - lastAt) or 0
  lastAt = now
  if dt < 0 then dt = 0 elseif dt > 0.1 then dt = 0.1 end
  local crush
  if Grass3D.crushFrame then
    local okC, c = pcall(Grass3D.crushFrame, feet, dt)
    if okC then crush = c end
  end
  Voxel3D.crush = crush or { n = #feet, p = feet }
  return sway
end

function Grass.draw(scene)
  local map = scene.map
  if not map then return end
  local Grass3D = optional("Grass3D")
  if not (Grass3D and Grass3D.available and Grass3D.available()) then
    once("bake", "the 3D grass bake is unavailable (assets/ground/grass, or GRASS "
         .. "set to VOXEL) -- no grass drawn on Gen 4")
    return
  end
  local tex = Grass3D.texture()
  if not tex then return end

  local rec = cache[map]
  if not rec then rec = { chunks = {} }; cache[map] = rec end

  local fx, fz = scene.focusPx()
  local span = Grass.CHUNK * 16
  local kx0, ky0 = math.floor(fx / span), math.floor(fz / span)

  -- WHICH CHUNKS: every one the engine draws ground for. The engine draws the
  -- engine chunks within WINDOW of the camera's, so grass is wanted on exactly
  -- that square (in map pixels: world minus the ground's offset) and not on a
  -- smaller circle around the player, which is what made it fade in only when
  -- you were close.
  local want = {}
  local ground, view = scene.ground, scene.view
  local px = ground and ground.chunkPx
  if px and view and tonumber(view.x) and tonumber(view.z) then
    local W = Grass.WINDOW
    local camCx, camCy = math.floor(view.x / px), math.floor(view.z / px)
    local x0, x1 = (camCx - W) * px - scene.offsetX, (camCx + W + 1) * px - scene.offsetX
    local z0, z1 = (camCy - W) * px - scene.offsetZ, (camCy + W + 1) * px - scene.offsetZ
    for ky = math.floor(z0 / span), math.ceil(z1 / span) - 1 do
      for kx = math.floor(x0 / span), math.ceil(x1 / span) - 1 do
        local dx, dy = kx - kx0, ky - ky0
        want[#want + 1] = { dx * dx + dy * dy, kx, ky }
      end
    end
  else
    local R = Grass.RADIUS
    for ky = ky0 - R, ky0 + R do
      for kx = kx0 - R, kx0 + R do
        local dx, dy = kx - kx0, ky - ky0
        if dx * dx + dy * dy <= R * R + 1 then
          want[#want + 1] = { dx * dx + dy * dy, kx, ky }
        end
      end
    end
  end
  -- nearest chunks first, so the ones under the camera are built before the far
  table.sort(want, function(a, b) return a[1] < b[1] end)

  local now = love.timer and love.timer.getTime
  local started = now and now() or 0
  local builds = 0
  local list = {}
  for _, w in ipairs(want) do
    local key = w[2] .. ":" .. w[3]
    local chunk = rec.chunks[key]
    if not chunk and builds < Grass.BUILDS_PER_FRAME
       and (builds == 0 or not now or (now() - started) < Grass.BUILD_BUDGET) then
      builds = builds + 1
      local ok, built = pcall(buildChunk, Grass3D, scene, map, w[2], w[3])
      if ok then
        chunk = built
      else
        chunk = { buckets = {} }
        once("chunk", "a chunk failed to build and was skipped: %s", tostring(built))
      end
      rec.chunks[key] = chunk
    end
    if chunk then
      for _, b in ipairs(chunk.buckets) do list[#list + 1] = b end
    end
  end
  if #list == 0 then return end

  local sway = prepare(Grass3D, scene)
  -- these meshes are not on the voxel grid and carry no window art
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  for _, b in ipairs(list) do
    Voxel3D.draw(b.mesh, tex, Mat4.translate(scene.offsetX, b.y, scene.offsetZ), 0, nil, sway)
  end
  Voxel3D.grassH, Voxel3D.grassLoad, Voxel3D.crush = nil, nil, nil
  Voxel3D.seams(true)
  Voxel3D.glass(true)
end

-- Drop every baked mesh: the GRASS row flipped, or a map was edited.
function Grass.invalidate()
  for _, rec in pairs(cache) do
    for _, chunk in pairs(rec.chunks) do
      for _, b in ipairs(chunk.buckets or {}) do
        if b.mesh and b.mesh.release then pcall(b.mesh.release, b.mesh) end
      end
    end
  end
  cache = setmetatable({}, { __mode = "k" })
end

return Grass