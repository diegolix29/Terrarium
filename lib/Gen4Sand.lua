-- Gen4Sand: the voxel scene's textured 3D ground, laid over Gen 4's beach sand.
--
-- WHAT "THE 3D GROUND" IS IN THE VOXEL SCENE
--
-- Structures.lua stamps one thin textured quad per 8-pixel TILE on every tile a
-- hack has named as bare ground (isCustomGroundTile): Grass3D.instanceForTile
-- gives it a hashed yaw and scale, the quad is the 4-vertex template Grass3D
-- loads (+-4 around the tile, UV 0..1, shade 0.8), and the whole lot is drawn
-- with the texture Grass3D.groundTexture() returns (assets/ground/grass/
-- ground.png). That is the look this reuses: same instance hash, same quad,
-- same texture, same shade -- only WHERE it stands is Gen 4's.
--
-- WHERE IT GOES
--
-- On cells whose tile behaviour is SAND (33, 0x21 -- Gen4Behaviors) and nowhere
-- else, never on water. The behaviour byte is `Map:blockAt` on Gen 4, the same
-- fact Gen4Grass reads for tall grass. It is laid OVER the engine's own sand
-- rather than replacing it (a terrain chunk is one mesh; there is no per-cell
-- hole to cut), a little above it (LIFT) so the two never fight. Sand the
-- behaviour does not cover (a shore strip painted as NONE) stays native: add
-- its behaviour to Sand.BEHAVIOURS.
--
-- HEIGHT
--
-- Platinum's ground is not flat. Each 8 px tile is baked at the ground height
-- under its centre (Gen4Ground:groundY), bucketed by height like the grass is,
-- and drawn translated up to it.
--
-- HOW FAR
--
-- Every engine chunk the ground is drawn for (WINDOW = Gen4Ground FREE_RADIUS),
-- nearest first, built under a per-frame time budget -- the same rule as grass.
--
-- MODES
--
--   "stamp"  the voxel scene's own look: Grass3D's hashed yaw/scale per tile
--            (default). Overlapping quads share a plane, so if you ever see
--            shimmer where they overlap, use "tile".
--   "tile"   axis-aligned 8 px quads, no overlap, no shimmer, no random patching.
--
-- If ground.png is not on disk nothing is drawn (logged once): there is no
-- untextured stand-in.

local V = ...
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")

local Sand = {
  enabled = true,
  MODE = "stamp",
  BEHAVIOURS = { [33] = true },   -- SAND
  CHUNK = 4,                      -- cells per side of one baked mesh
  WINDOW = 2,                     -- engine chunks each way (Gen4Ground FREE_RADIUS)
  RADIUS = 3,                     -- fallback chunks around the focus without a chunk grid
  BUILDS_PER_FRAME = 24,
  BUILD_BUDGET = 0.004,           -- seconds
  LIFT = 0.4,                     -- world units above the native ground
  PULL = 0,                       -- Voxel3D.draw's toward-the-eye bias, if LIFT is not enough
  SHADE = 0.8,                    -- Grass3D's quad template shade
  HALF = 4,                       -- Grass3D's quad template is +-4 about the tile
}

local warned = {}
local function once(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if V.mod and V.mod.log then V.mod.log:info("Gen4Sand: " .. fmt:format(...)) end
end

local function optional(name)
  local ok, mod = pcall(V.require, name)
  return ok and mod or nil
end

local cache = setmetatable({}, { __mode = "k" })    -- map -> { chunks = {} }
local texture                                        -- Image | false | nil (untried)

local function groundTexture(Grass3D)
  if texture ~= nil then return texture or nil end
  if not (Grass3D and Grass3D.groundTexture) then texture = false; return nil end
  local ok, img = pcall(Grass3D.groundTexture)
  texture = (ok and img) or false
  if not texture then
    once("tex", "no ground texture (assets/ground/grass/ground.png) -- Gen 4 beach keeps "
         .. "its native sand")
  end
  return texture or nil
end

local function isSand(map, cx, cy)
  -- Gen4Cells: the live Map inside its crop, the shared layout beyond it, so
  -- the beach carries on over the neighbouring maps.
  local Cells = optional("Gen4Cells")
  local b
  if Cells then b = Cells.behaviour(map, cx, cy)
  elseif map.blockAt and map.inBounds and map:inBounds(cx, cy) then
    local okB, v = pcall(map.blockAt, map, cx, cy)
    b = okB and v or nil
  end
  if not Sand.BEHAVIOURS[b] then return false end
  if map.isWaterCell and map.inBounds and map:inBounds(cx, cy) then
    local okW, water = pcall(map.isWaterCell, map, cx, cy)
    if okW and water then return false end
  end
  return true
end

-- One quad, as Grass3D's stamp() does it: rotate the template corner by yaw,
-- scale it, move it to the tile's centre.
local function pushQuad(verts, indices, cx0, cz0, yaw, scale, half)
  local c, s = math.cos(yaw), math.sin(yaw)
  local corners = { { -half, -half, 0, 0 }, { half, -half, 1, 0 },
                    { half, half, 1, 1 }, { -half, half, 0, 1 } }
  local base = #verts
  for _, k in ipairs(corners) do
    local x, z = k[1] * scale, k[2] * scale
    verts[#verts + 1] = { cx0 + x * c - z * s, 0, cz0 + x * s + z * c, k[3], k[4], Sand.SHADE, 0 }
  end
  indices[#indices + 1], indices[#indices + 2], indices[#indices + 3] = base + 1, base + 2, base + 3
  indices[#indices + 1], indices[#indices + 2], indices[#indices + 3] = base + 1, base + 3, base + 4
end

-- One chunk: sand tiles bucketed by ground height, one mesh per height.
local function buildChunk(Grass3D, scene, map, kx, ky)
  local C = Sand.CHUNK
  local order, buckets = {}, {}
  local cells = 0
  for cy = ky * C, ky * C + C - 1 do
    for cx = kx * C, kx * C + C - 1 do
      if isSand(map, cx, cy) then
        cells = cells + 1
        local y = math.floor((scene.groundY(cx * 16 + 8, cy * 16 + 8) or 0) + 0.5)
        local b = buckets[y]
        if not b then b = { verts = {}, indices = {} }; buckets[y] = b; order[#order + 1] = y end
        for ty = cy * 2, cy * 2 + 1 do
          for tx = cx * 2, cx * 2 + 1 do
            if Sand.MODE == "tile" then
              pushQuad(b.verts, b.indices, tx * 8 + 4, ty * 8 + 4, 0, 1, Sand.HALF)
            else
              local inst = Grass3D.instanceForTile(tx, ty, y)
              pushQuad(b.verts, b.indices, inst.wx + 4, inst.wz + 4,
                       inst.yaw or 0, inst.scale or 1, Sand.HALF)
            end
          end
        end
      end
    end
  end
  local out = {}
  for _, y in ipairs(order) do
    local b = buckets[y]
    local mesh = Voxel3D.newMesh(b.verts, b.indices)
    if mesh then out[#out + 1] = { mesh = mesh, y = y } end
  end
  if cells > 0 then once("chunk", "sand ground built (%d cells in the first chunk)", cells) end
  return { buckets = out }
end

function Sand.draw(scene)
  if not Sand.enabled then return end
  local map = scene.map
  if not map then return end
  local Grass3D = optional("Grass3D")
  if not (Grass3D and Grass3D.instanceForTile) then return end
  local tex = groundTexture(Grass3D)
  if not tex then return end

  local rec = cache[map]
  if not rec then rec = { chunks = {} }; cache[map] = rec end

  local fx, fz = scene.focusPx()
  local span = Sand.CHUNK * 16
  local kx0, ky0 = math.floor(fx / span), math.floor(fz / span)

  local want = {}
  local ground, view = scene.ground, scene.view
  local px = ground and ground.chunkPx
  if px and view and tonumber(view.x) and tonumber(view.z) then
    local W = Sand.WINDOW
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
    local R = Sand.RADIUS
    for ky = ky0 - R, ky0 + R do
      for kx = kx0 - R, kx0 + R do
        local dx, dy = kx - kx0, ky - ky0
        if dx * dx + dy * dy <= R * R + 1 then want[#want + 1] = { dx * dx + dy * dy, kx, ky } end
      end
    end
  end
  table.sort(want, function(a, b) return a[1] < b[1] end)

  local now = love.timer and love.timer.getTime
  local started = now and now() or 0
  local builds, list = 0, {}
  for _, w in ipairs(want) do
    local key = w[2] .. ":" .. w[3]
    local chunk = rec.chunks[key]
    if not chunk and builds < Sand.BUILDS_PER_FRAME
       and (builds == 0 or not now or (now() - started) < Sand.BUILD_BUDGET) then
      builds = builds + 1
      local ok, built = pcall(buildChunk, Grass3D, scene, map, w[2], w[3])
      if ok then
        chunk = built
      else
        chunk = { buckets = {} }
        once("build", "a chunk failed to build and was skipped: %s", tostring(built))
      end
      rec.chunks[key] = chunk
    end
    if chunk then for _, b in ipairs(chunk.buckets) do list[#list + 1] = b end end
  end
  if #list == 0 then return end

  Voxel3D.seams(false)
  Voxel3D.glass(false)
  for _, b in ipairs(list) do
    Voxel3D.draw(b.mesh, tex, Mat4.translate(scene.offsetX, b.y + Sand.LIFT, scene.offsetZ),
                 Sand.PULL, nil, 0)
  end
  Voxel3D.seams(true)
  Voxel3D.glass(true)
end

function Sand.invalidate()
  for _, rec in pairs(cache) do
    for _, chunk in pairs(rec.chunks) do
      for _, b in ipairs(chunk.buckets or {}) do
        if b.mesh and b.mesh.release then pcall(b.mesh.release, b.mesh) end
      end
    end
  end
  cache = setmetatable({}, { __mode = "k" })
  texture = nil
end

return Sand
