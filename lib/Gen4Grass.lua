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

-- One shared per-frame build budget (lib/Gen4Budget.lua); see Gen4Sand.
local Budget = optional("Gen4Budget") or { allow = function() return true end, charge = function() end }
local clock = (love and love.timer and love.timer.getTime) or os.clock

-- Resolved once: these were pcall(V.require, ...) per CELL and per frame.
local cellsMod
local function getCells()
  if cellsMod == nil then cellsMod = optional("Gen4Cells") or false end
  return cellsMod or nil
end
local grass3dMod, windMod
local function getGrass3D()
  if not grass3dMod then grass3dMod = optional("Grass3D") end
  return grass3dMod
end
local function getWind()
  if not windMod then windMod = optional("Wind") end
  return windMod
end

-- World-space grass chunks, keyed by the chunk's world-pixel origin -- not by
-- the live Map. A Gen 4 route change is a new Map crop of the same grid, so
-- meshes already built for the overlapping window must survive it. Weak keys
-- on Map were why the meadow vanished and rebuilt at every border.
local chunks = {}
local win = { list = {}, dirty = true }

local function isTallGrass(map, cx, cy)
  -- Gen4Cells reads the live Map inside its crop and the shared layout beyond
  -- it, so grass grows on the neighbouring maps' ground too (a Gen 4 Map is
  -- only a rectangle cut out of the grid the engine draws around you).
  local Cells = getCells()
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
-- Vertices are stamped in WORLD pixels (tile + map origin / 8) so a mesh
-- built on one crop is still in the right place on the next.
local function buildChunk(Grass3D, scene, map, kx, ky, ox, oz)
  local C = Grass.CHUNK
  local ox8, oz8 = (ox or 0) / 8, (oz or 0) / 8
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
            bucket[#bucket + 1] = Grass3D.instanceForTile(tx + ox8, ty + oz8, y)
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
  local Wind = getWind()
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

local function numKey(kx, ky) return (ky + 32768) * 65536 + (kx + 32768) end

-- Map-local grass chunk (kx, ky) -> world-pixel origin, unique across crops.
local function worldChunkKey(kx, ky, ox, oz, span)
  return numKey(math.floor(kx * span + (ox or 0) + 0.5),
                math.floor(ky * span + (oz or 0) + 0.5))
end

function Grass.draw(scene)
  local map = scene.map
  if not map then return end
  local Grass3D = getGrass3D()
  if not (Grass3D and Grass3D.available and Grass3D.available()) then
    once("bake", "the 3D grass bake is unavailable (assets/ground/grass, or GRASS "
         .. "set to VOXEL) -- no grass drawn on Gen 4")
    return
  end
  local tex = Grass3D.texture()
  if not tex then return end

  local fx, fz = scene.focusPx()
  local span = Grass.CHUNK * 16
  local kx0, ky0 = math.floor(fx / span), math.floor(fz / span)
  local ground, view = scene.ground, scene.view
  local px = ground and ground.chunkPx
  local grid = (px and view and tonumber(view.x) and tonumber(view.z)) and true or false
  local camCx, camCy = 0, 0
  if grid then camCx, camCy = math.floor(view.x / px), math.floor(view.z / px) end
  local ox, oz = scene.offsetX, scene.offsetZ

  -- WHICH CHUNKS: every one the engine draws ground for (the engine chunks
  -- within WINDOW of the camera's), nearest first. The list only changes when
  -- the camera or focus crosses a chunk boundary, so it is built and sorted
  -- then and reused every other frame.
  if not (win.want and win.kx0 == kx0 and win.ky0 == ky0 and win.camCx == camCx
          and win.camCy == camCy and win.ox == ox and win.oz == oz and win.grid == grid) then
    local want = {}
    if grid then
      local W = Grass.WINDOW
      local x0, x1 = (camCx - W) * px - ox, (camCx + W + 1) * px - ox
      local z0, z1 = (camCy - W) * px - oz, (camCy + W + 1) * px - oz
      for ky = math.floor(z0 / span), math.ceil(z1 / span) - 1 do
        for kx = math.floor(x0 / span), math.ceil(x1 / span) - 1 do
          local dx, dy = kx - kx0, ky - ky0
          want[#want + 1] = { dx * dx + dy * dy, kx, ky, worldChunkKey(kx, ky, ox, oz, span) }
        end
      end
    else
      local R = Grass.RADIUS
      for ky = ky0 - R, ky0 + R do
        for kx = kx0 - R, kx0 + R do
          local dx, dy = kx - kx0, ky - ky0
          if dx * dx + dy * dy <= R * R + 1 then
            want[#want + 1] = { dx * dx + dy * dy, kx, ky, worldChunkKey(kx, ky, ox, oz, span) }
          end
        end
      end
    end
    table.sort(want, function(a, b) return a[1] < b[1] end)
    win.want, win.kx0, win.ky0, win.camCx, win.camCy = want, kx0, ky0, camCx, camCy
    win.ox, win.oz, win.grid, win.dirty = ox, oz, grid, true
  end

  -- BUILD what the shared budget allows, nearest first; nothing past the first
  -- refusal can build this frame either. Hits the world-keyed table, so a
  -- route swap that still sees the same meadow does not rebuild it.
  local want = win.want
  local builds = 0
  for i = 1, #want do
    local w = want[i]
    if not chunks[w[4]] then
      if builds < Grass.BUILDS_PER_FRAME and Budget.allow(false) then
        builds = builds + 1
        local t0 = clock()
        local ok, built = pcall(buildChunk, Grass3D, scene, map, w[2], w[3])
        Budget.charge(t0, "grass")
        if not ok then
          once("chunk", "a chunk failed to build and was skipped: %s", tostring(built))
          built = { buckets = {} }
        end
        -- Mesh vertices are map-local; keep the offset they were built under
        -- so a later crop with a different origin still places them in world.
        built.ox, built.oz = ox, oz
        for _, b in ipairs(built.buckets or {}) do
          b.cox, b.coz = ox, oz
        end
        chunks[w[4]] = built
        win.dirty = true
      else
        break
      end
    end
  end

  if win.dirty then
    local list = {}
    for i = 1, #want do
      local chunk = chunks[want[i][4]]
      if chunk then for _, b in ipairs(chunk.buckets) do list[#list + 1] = b end end
    end
    win.list, win.dirty = list, false
  end
  local list = win.list
  if not list or #list == 0 then return end

  local sway = prepare(Grass3D, scene)
  -- these meshes are not on the voxel grid and carry no window art
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  for i = 1, #list do
    local b = list[i]
    local cox, coz = b.cox or ox, b.coz or oz
    local m = b.m
    if not m or b.mox ~= cox or b.moz ~= coz then
      m = Mat4.translate(cox, b.y, coz)          -- once per bucket, not per frame
      b.m, b.mox, b.moz = m, cox, coz
    end
    Voxel3D.draw(b.mesh, tex, m, 0, nil, sway)
  end
  Voxel3D.grassH, Voxel3D.grassLoad, Voxel3D.crush = nil, nil, nil
  Voxel3D.seams(true)
  Voxel3D.glass(true)
end

function Grass.invalidate()
  for _, chunk in pairs(chunks) do
    for _, b in ipairs(chunk.buckets or {}) do
      if b.mesh and b.mesh.release then pcall(b.mesh.release, b.mesh) end
    end
  end
  chunks = {}
  win = {}
end

return Grass