-- Voxel world mode: turn a map's tile layer into one static 3D mesh.
--
-- The scene description comes from Structures.lua, which -- 3dSen-style --
-- detects each connected drawn thing on the map and picks its model:
--
--   flat      ground / water / void: a single quad.
--   top art   ledges, roofs (profile-authored): a box with the art on its
--             TOP face; partial side bands crop the art (a 6px ledge face
--             is the bottom of the lip drawing).
--   volume    walls, buildings, tree lines: each column rises to the
--             structure's REAL drawn height (Structures measures it,
--             repeat-aware and region-consistent -- a 6-row house is 48px,
--             a 40-row border forest is rows of 16px trees). The south
--             face folds the full artwork upright, 8px band by band, band
--             k sampling the map row k tiles north; the top wears the
--             structure's top rows.
--   object    small props with a silhouette (plants, signs, lone trees):
--             per-pixel voxel prisms prebuilt by Structures, standing on
--             synthesized ground -- this mesher just emits their quads.
--             Round trees arrive as STAMPS (a shared hull template plus a
--             cell offset) and expand here, straight into the vertex
--             stream, so no map retains per-cell copies of its forests.
--
-- Side faces are never stretched: all sides are 8px bands with the art
-- tiled per band and cropped at partial bands.
--
-- Texturing samples the TILESET ATLAS, not a rendered copy of the map. The
-- atlas is 128x48; a map-space canvas covering the biggest routes would be
-- ~5 MB each with up to five live at once (connected maps), which is real
-- memory on the mobile targets. Sampling the atlas costs 24 KB, and costs
-- nothing in fidelity because TerrainAtlas hands back the same atlas
-- TileRenderer draws with -- including the fully recolored one RED++
-- bakes -- so terrain color comes through untouched.
--
-- BUILDS ARE ASYNCHRONOUS. A frame never blocks on meshing: VoxelScene
-- requests what it wants to draw, request() queues a build job, and
-- pump() -- called once a frame from the pipeline's update -- advances
-- the queue inside a few-millisecond budget (BuildBudget suspends the
-- job's coroutine mid-loop when the slice is spent). Until a mesh lands
-- the scene simply draws without it: the engine's flat path while the
-- current map has nothing, the body-only variant while the full one (the
-- border ring) is still cooking, neighbours popping in as they finish.
-- The synchronous get() remains for probes and tests.
--
-- Meshes are cached per map id and EVICTED down to the live set (current
-- map + connected neighbours) whenever that set changes -- setLive()
-- releases far maps' GPU meshes and their Structures analysis, which is
-- what used to grow the heap by gigabytes over a cross-region trek.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Assets = require("src.render.Assets")
local Structures = V.require("Structures")
local TileShape = V.require("TileShape")
local Voxel3D = V.require("Voxel3D")
local Budget = V.require("BuildBudget")
local Gen3 = V.require("Gen3")

-- Persistent geometry cache. Optional on purpose: a build without the module
-- (or one whose option is off) simply meshes every time, exactly as before.
local DiskCache = nil
do
  local okCache, cacheMod = pcall(V.require, "VoxelDiskCache")
  if okCache and type(cacheMod) == "table" and type(cacheMod.load) == "function" then
    DiskCache = cacheMod
  end
end

local ffi = nil
do
  local ok, mod = pcall(require, "ffi")
  if ok then ffi = mod end
end

local ChunkMesher = {}

-- Anything geometry depends on that neither the map body nor the editor's
-- tile pins nor the companion config describes. Bumping it invalidates every
-- entry at once; it is the escape hatch for a rules change this file makes.
function ChunkMesher.setCacheRulesTag(tag)
  if DiskCache and type(DiskCache.setRulesTag) == "function" then
    DiskCache.setRulesTag(tag)
  end
end

function ChunkMesher.cacheStatus()
  if DiskCache and type(DiskCache.status) == "function" then
    return DiskCache.status()
  end
  return { enabled = false, unavailable = true }
end

function ChunkMesher.clearCache()
  if DiskCache and type(DiskCache.clear) == "function" then
    return DiskCache.clear()
  end
  return false
end

-- Ring of border blocks meshed around the body, matching the width
-- TileRenderer draws so the two modes end at the same place.
local RING = 3

-- A sliver of a texel, to keep a quad's sampling inside its own tile.
local INSET = 0.02

-- The south face of a volume is the artwork itself, so it draws at full
-- brightness; its top face darkens a touch so the plateau behind a
-- standing drawing reads as depth rather than repeating the same art at
-- the same energy.
local VOLUME_TOP_SHADE = 0.85

local cache = {}     -- map id -> { full = mesh|false, body = ..., grass = ... }
local gen = {}       -- map id -> generation, bumped by invalidate/evict

-- Horizontal neighbours: tile step, face direction id (see Voxel3D).
local SIDES = {
  { 1, 0, 1 },    -- +X east
  { -1, 0, 2 },   -- -X west
  { 0, 1, 5 },    -- +Z south
  { 0, -1, 6 },   -- -Z north
}

local function keyOf(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

-- Face sign: -1 for up-facing quads (pointing at the sky), +1 otherwise.
local function faceSign(c, sky)
  if sky ~= nil then return sky and -1 or 1 end
  local a, b, d = c[1], c[2], c[3]
  local dx, dz = b[1] - a[1], b[3] - a[3]
  local ex, ez = d[1] - a[1], d[3] - a[3]
  local ny = dz * ex - dx * ez
  return (ny > 1e-6 or ny < -1e-6) and -1 or 1
end

-- ------------------------------------------------------------ vertex sinks

local function newTableSink()
  local verts, indices, quads = {}, {}, 0
  return {
    push = function(c, uv, shade, sky, water)
      local flat = type(shade) ~= "table"
      local w = water and 1.0 or 0.0
      for i = 1, 4 do
        local cc, t = c[i], uv[i]
        verts[#verts + 1] = { cc[1], cc[2], cc[3], t[1], t[2],
                              flat and shade or shade[i], w }
      end
      Voxel3D.pushQuad(indices, quads)
      quads = quads + 1
    end,
    results = function()
      return verts, indices, quads
    end,
    vertexCount = function()
      return quads * 6
    end,
    finish = function()
      return Voxel3D.newMesh(verts, indices)
    end,
  }
end

local TRI_ORDER = { 1, 2, 3, 1, 3, 4 }

local function newFfiSink(cap0)
  local capQuads = cap0 or 4096
  local buf = ffi.new("float[?]", capQuads * 4 * 7)      -- 4 verts/quad, 7 floats/vert
  local ibuf = ffi.new("uint32_t[?]", capQuads * 6)      -- 6 indices/quad
  local nQuads = 0
  local sink
  sink = {
    push = function(c, uv, shade, sky, water)
      if nQuads + 1 > capQuads then
        local grownV = ffi.new("float[?]", capQuads * 2 * 4 * 7)
        ffi.copy(grownV, buf, nQuads * 4 * 7 * 4)
        local grownI = ffi.new("uint32_t[?]", capQuads * 2 * 6)
        ffi.copy(grownI, ibuf, nQuads * 6 * 4)
        buf, ibuf, capQuads = grownV, grownI, capQuads * 2
      end
      local flat = type(shade) ~= "table"
      local s = faceSign(c, sky)
      local w = water and 1.0 or 0.0
      local base = nQuads * 4 * 7
      for i = 1, 4 do
        local cc, t = c[i], uv[i]
        buf[base] = cc[1]
        buf[base + 1] = cc[2]
        buf[base + 2] = cc[3]
        buf[base + 3] = t[1]
        buf[base + 4] = t[2]
        buf[base + 5] = s * (flat and shade or shade[i])
        buf[base + 6] = w
        base = base + 7
      end
      local ibase, vbase = nQuads * 6, nQuads * 4
      for k = 1, 6 do
        ibuf[ibase + k - 1] = vbase + TRI_ORDER[k] - 1
      end
      nQuads = nQuads + 1
    end,
    finish = function()
      if nQuads == 0 then return nil end
      local n = nQuads * 4
      local ok, mesh = pcall(function()
        local m = love.graphics.newMesh(Voxel3D.FORMAT, n,
                                        "triangles", "static")
        local CHUNK = 65536
        local i = 0
        while i < n do
          local count = math.min(CHUNK, n - i)
          local bytes = count * 7 * 4
          local data = love.data.newByteData(bytes)
          ffi.copy(data:getFFIPointer(), buf + i * 7, bytes)
          m:setVertices(data, i + 1)
          data:release()
          i = i + count
          Budget.check()
        end
        local nIdx = nQuads * 6
        Budget.check()
        if n <= 65535 then
          local u16 = ffi.new("uint16_t[?]", nIdx)
          for k = 0, nIdx - 1 do
            u16[k] = ibuf[k]
            if k % 16384 == 0 then Budget.tick() end
          end
          local bytes = nIdx * 2
          local data = love.data.newByteData(bytes)
          ffi.copy(data:getFFIPointer(), u16, bytes)
          m:setVertexMap(data, "uint16", nIdx)
          data:release()
        else
          local bytes = nIdx * 4
          local data = love.data.newByteData(bytes)
          ffi.copy(data:getFFIPointer(), ibuf, bytes)
          m:setVertexMap(data, "uint32", nIdx)
          data:release()
        end
        return m
      end)
      return ok and mesh or nil
    end,
  }
  return sink
end

local function newSink(cap0)
  if ffi and love and love.data and love.data.newByteData
     and love.graphics and love.graphics.newMesh then
    return newFfiSink(cap0)
  end
  return newTableSink()
end

-- ------------------------------------------------------- spatial chunking

local CHUNK_X = 256
local CHUNK_Z = 64
local CHUNK_MARGIN = 96

local Group = {}
Group.__index = Group

function Group:release()
  for _, ch in ipairs(self.chunks) do
    if ch.mesh and ch.mesh.release then pcall(ch.mesh.release, ch.mesh) end
  end
  self.chunks = {}
end

local function newChunkedSink()
  local buckets, order = {}, {}

  local function bucketFor(x, z)
    local bx = math.floor(x / CHUNK_X)
    local bz = math.floor(z / CHUNK_Z)
    local k = bz * 8192 + bx
    local b = buckets[k]
    if not b then
      b = { sink = newSink(512), ymax = 0,
            x0 = bx * CHUNK_X - CHUNK_MARGIN,
            z0 = bz * CHUNK_Z - CHUNK_MARGIN,
            x1 = (bx + 1) * CHUNK_X + CHUNK_MARGIN,
            z1 = (bz + 1) * CHUNK_Z + CHUNK_MARGIN }
      buckets[k] = b
      order[#order + 1] = b
    end
    return b
  end

  return {
    push = function(c, uv, shade, sky, water)
      local corner = c[1]
      local b = bucketFor(corner[1], corner[3])
      local y = c[1][2]
      if c[2][2] > y then y = c[2][2] end
      if c[3][2] > y then y = c[3][2] end
      if c[4][2] > y then y = c[4][2] end
      if y > b.ymax then b.ymax = y end
      b.sink.push(c, uv, shade, sky, water)
    end,
    finish = function()
      local chunks = {}
      for _, b in ipairs(order) do
        local mesh = b.sink.finish()
        if mesh then
          chunks[#chunks + 1] = { mesh = mesh, x0 = b.x0, z0 = b.z0,
                                  x1 = b.x1, z1 = b.z1, ymax = b.ymax }
        end
      end
      if #chunks == 0 then return nil end
      return setmetatable({ chunks = chunks }, Group)
    end,
  }
end

-- -------------------------------------------------------------- geometry

local function runGeometry(map, bodyOnly, masks, sink, waterSink)
  local push = sink.push
  local waterPush = waterSink and waterSink.push or nil
  local tileset = map.tileset
  local S = Structures.forMap(map)
  local perRow = tileset.tilesPerRow or 16
  local atlasW = tileset.imageWidth or (perRow * 8)
  local atlasH = tileset.imageHeight or 48

  if Gen3 and Gen3.isGen3(tileset) then
    local okD, info = pcall(Gen3.describe, tileset)
    if okD and info then
      perRow, atlasW, atlasH = info.perRow, info.width, info.height
    end
  end

  local LEDGE_HOP = {
    { -1, 0, { [0xA0] = true, [0xA4] = true }, "right" },
    { 1, 0, { [0xA1] = true, [0xA5] = true }, "left" },
    { 0, -1, { [0xA3] = true, [0xA4] = true, [0xA5] = true }, "down" },
  }

  local ledgeDropCache = {}
  local function ledgeDrop(cx, cy)
    local k = keyOf(cx, cy)
    local hit = ledgeDropCache[k]
    if hit then return hit end
    local d = "down"
    if map.cellTile then
      for _, r in ipairs(LEDGE_HOP) do
        local ok, class = pcall(map.cellTile, map, cx + r[1], cy + r[2])
        if ok and class and r[3][class] then d = r[4]; break end
      end
    end
    ledgeDropCache[k] = d
    return d
  end

  local function shapeHeight(tx, ty, s)
    if s.class ~= "ledge" then return s.h end
    if S.isGen3 then return s.h end
    local d = ledgeDrop(math.floor(tx / 2), math.floor(ty / 2))
    local onDrop
    if d == "up" then onDrop = ty % 2 == 0
    elseif d == "right" then onDrop = tx % 2 == 1
    elseif d == "left" then onDrop = tx % 2 == 0
    else onDrop = ty % 2 == 1 end
    return onDrop and s.h or 0
  end

  local stampH = {}
  local function heightAt(tx, ty)
    local k = keyOf(tx, ty)
    if S.skip[k] then
      local hit = stampH[k]
      if hit == nil then
        local okS, z = pcall(Structures.stampGround, map, tx, ty)
        hit = (okS and tonumber(z)) or 0
        stampH[k] = hit
      end
      return hit
    end
    local run = S.runs[k]
    if run then return run.h end
    local s = S.shapeAt[k]
    return s and shapeHeight(tx, ty, s) or 0
  end

  local HULL_CLASS = {
    cylinder = true, canopy = true, stump = true, can = true,
    planter = true, billboard = true, post = true,
  }
  
  local SEAM_DATUM = -16
  local function occludeH(tx, ty)
    if not S.isGen3 then return heightAt(tx, ty) end
    local k = keyOf(tx, ty)
    if S.seamOpen and S.seamOpen[k] then return SEAM_DATUM end
    if S.skip[k] or S.runs[k] then return heightAt(tx, ty) end
    local s = S.shapeAt[k]
    if s and HULL_CLASS[s.class] then
      local b = s.base or 0
      local h = shapeHeight(tx, ty, s)
      return (b < h) and b or h
    end
    return heightAt(tx, ty)
  end

  local function isWaterAt(tx, ty)
    local k = keyOf(tx, ty)
    local s = S.shapeAt[k]
    if not s then return false end
    return s.class == "water"
  end

  local function tileOrigin(tile)
    return (tile % perRow) * 8, math.floor(tile / perRow) * 8
  end

  local function uvRect(tile, vTop, vBot)
    local ax, ay = tileOrigin(tile)
    local vi = math.min(INSET, ((vBot or 8) - (vTop or 0)) / 4)
    return (ax + INSET) / atlasW, (ax + 8 - INSET) / atlasW,
           (ay + (vTop or 0) + vi) / atlasH, (ay + (vBot or 8) - vi) / atlasH
  end

  -- ------------------------------------------------------ ambient occlusion

  local AO_STRENGTH = 2.4
  local AO_STEP = 0.09 * AO_STRENGTH
  local AO_EDGE = 1 - 0.14 * AO_STRENGTH
  local AO_GROUND = 0.12 * AO_STRENGTH
  local AO_RISE = 6
  local AO_FLOOR = 0.25

  local aoTop = { 0, 0, 0, 0 }
  local aoSide = { 0, 0, 0, 0 }

  local function aoShades(tx, ty, h, shade)
    local n = heightAt(tx, ty - 1) > h
    local s = heightAt(tx, ty + 1) > h
    local e = heightAt(tx + 1, ty) > h
    local w = heightAt(tx - 1, ty) > h
    local nw = heightAt(tx - 1, ty - 1) > h
    local ne = heightAt(tx + 1, ty - 1) > h
    local sw = heightAt(tx - 1, ty + 1) > h
    local se = heightAt(tx + 1, ty + 1) > h
    if not (n or s or e or w or nw or ne or sw or se) then return shade end
    local function corner(a, b, d)
      local k = 0
      if a then k = k + 1 end
      if b then k = k + 1 end
      if d and not (a and b) then k = k + 1 end
      return shade * math.max(AO_FLOOR, 1 - AO_STEP * k)
    end
    aoTop[1], aoTop[2] = corner(n, w, nw), corner(n, e, ne)
    aoTop[3], aoTop[4] = corner(s, e, se), corner(s, w, sw)
    return aoTop
  end

  local LATERAL = {
    [1] = { 0, 1, 0, -1 },    -- east face:  left south, right north
    [2] = { 0, -1, 0, 1 },    -- west face:  left north, right south
    [5] = { -1, 0, 1, 0 },    -- south face: left west,  right east
    [6] = { 1, 0, -1, 0 },    -- north face: left east,  right west
  }
  
  local aoProp = { 0, 0, 0, 0 }
  local function groundShades(c, shade)
    if type(shade) == "table" then return shade end
    local y1, y2, y3, y4 = c[1][2], c[2][2], c[3][2], c[4][2]
    if math.min(y1, y2, y3, y4) >= AO_RISE then return shade end
    for i = 1, 4 do
      local t = c[i][2] / AO_RISE
      aoProp[i] = shade * (t >= 1 and 1 or (1 - AO_GROUND * (1 - t)))
    end
    return aoProp
  end

  local AO_CORNER = math.max(AO_FLOOR, AO_EDGE * AO_EDGE)
  local function sideShades(hl, hr, y0, y1, crease, shade)
    if not (crease or hl > y0 or hr > y0) then return shade end
    local base = crease and AO_EDGE or 1
    aoSide[1] = shade * (hl > y0 and (crease and AO_CORNER or AO_EDGE) or base)
    aoSide[2] = shade * (hr > y0 and (crease and AO_CORNER or AO_EDGE) or base)
    aoSide[3] = shade * (hr > y1 and AO_EDGE or 1)
    aoSide[4] = shade * (hl > y1 and AO_EDGE or 1)
    return aoSide
  end

  local function topQuad(x0, z0, h, tile, shade, water, to, vTop, vBot)
    local u0, u1, v0, v1 = uvRect(tile, vTop or 0, vBot or 8)
    ;(to or push)({ { x0, h, z0 }, { x0 + 8, h, z0 },
                    { x0 + 8, h, z0 + 8 }, { x0, h, z0 + 8 } },
                  { { u0, v0 }, { u1, v0 }, { u1, v1 }, { u0, v1 } },
                  aoShades(x0 / 8, z0 / 8, h, shade), nil, water)
  end

  local function sideQuad(d, x0, z0, y0, y1, tile, vTop, vBot, shade, water)
    local x1, z1 = x0 + 8, z0 + 8
    local c
    if d == 5 then
      c = { { x0, y0, z1 }, { x1, y0, z1 }, { x1, y1, z1 }, { x0, y1, z1 } }
    elseif d == 6 then
      c = { { x1, y0, z0 }, { x0, y0, z0 }, { x0, y1, z0 }, { x1, y1, z0 } }
    elseif d == 1 then
      c = { { x1, y0, z1 }, { x1, y0, z0 }, { x1, y1, z0 }, { x1, y1, z1 } }
    else
      c = { { x0, y0, z0 }, { x0, y0, z1 }, { x0, y1, z1 }, { x0, y1, z0 } }
    end
    local u0, u1, v0, v1 = uvRect(tile, vTop, vBot)
    push(c, { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } }, shade, nil, water)
  end

  local def = map.def
  local tw, th = def.width * 4, def.height * 4
  local r = bodyOnly and 0 or RING * 4

  local function masked(px0, pz0, px1, pz1)
    if not masks then return false end
    for _, mk in ipairs(masks) do
      if px1 > mk[1] and px0 < mk[3] and pz1 > mk[2] and pz0 < mk[4] then
        return true
      end
    end
    return false
  end

  local function maskedClosed(px0, pz0, px1, pz1)
    if not masks then return false end
    for _, mk in ipairs(masks) do
      if px1 >= mk[1] and px0 <= mk[3] and pz1 >= mk[2] and pz0 <= mk[4] then
        return true
      end
    end
    return false
  end

  for ty = -r, th + r - 1 do
    for tx = -r, tw + r - 1 do
      Budget.tick()
      local k = keyOf(tx, ty)
      local s, tile = S.shapeAt[k], S.tileAt[k]
      local inBody = tx >= 0 and ty >= 0 and tx < tw and ty < th
      if not inBody and masked(tx * 8, ty * 8, tx * 8 + 8, ty * 8 + 8) then
        s = nil
      end

      if not inBody and S.hideBareRing and not S.skip[k] then
        if s == nil or s.apron or not S.outdoor then
          if not S.outdoor and s and not s.apron then s = nil end
        else
          s = { class = "ground", art = "flat", flat = true,
                h = s.h or 0, base = s.base or 0, gen3 = s.gen3,
                apron = true }
        end
      end

      if s and S.skip[k] then
        local g = S.ground[k]
        if g then
          local gy = heightAt(tx, ty)
          if type(gy) ~= "number" then gy = s.base or 0 end
          topQuad(tx * 8, ty * 8, gy, g, 1, false)
          
          for _, side in ipairs(SIDES) do
            local nh = occludeH(tx + side[1], ty + side[2])
            if nh < gy then
              local d = side[3]
              local lat = LATERAL[d]
              local hl = lat and heightAt(tx + lat[1], ty + lat[2]) or 0
              local hr = lat and heightAt(tx + lat[3], ty + lat[4]) or 0
              for band = math.floor(nh / 8), math.ceil(gy / 8) - 1 do
                local y0 = math.max(nh, band * 8)
                local y1 = math.min(gy, band * 8 + 8)
                if y1 > y0 then
                  sideQuad(d, tx * 8, ty * 8, y0, y1, g,
                           (band * 8 + 8) - y1, (band * 8 + 8) - y0,
                           sideShades(hl, hr, y0, y1, y0 <= nh,
                                      Voxel3D.FACE_SHADE[d]), false)
                end
              end
            end
          end
        end
      elseif s and s.sub and s.sub.res and s.sub.h then
        local res = math.max(1, math.min(8, math.floor(s.sub.res)))
        local step = 8 / res
        local hs = s.sub.h
        local base = S.runs[k] and S.runs[k].h or shapeHeight(tx, ty, s)
        local x0, z0 = tx * 8, ty * 8
        local tile = S.tileAt[k]

        local shift = 0
        do
          local z0 = s.sub.z0
          if type(z0) == "number" then shift = base - z0 end
        end

        local function subH(i, j)
          if i < 0 or j < 0 or i >= res or j >= res then return nil end
          local v = tonumber(hs[j * res + i + 1])
          if v == nil then return base end
          return v + shift
        end

        local function subUV(i, j)
          local ax, ay = tileOrigin(tile)
          local u0 = (ax + i * step) / atlasW
          local u1 = (ax + (i + 1) * step) / atlasW
          local v0 = (ay + j * step) / atlasH
          local v1 = (ay + (j + 1) * step) / atlasH
          return u0, u1, v0, v1
        end

        for j = 0, res - 1 do
          for i = 0, res - 1 do
            local hh = subH(i, j) or base
            local sx, sz = x0 + i * step, z0 + j * step
            local u0, u1, v0, v1 = subUV(i, j)
            -- top
            push({ { sx, hh, sz }, { sx + step, hh, sz },
                   { sx + step, hh, sz + step }, { sx, hh, sz + step } },
                 { { u0, v0 }, { u1, v0 }, { u1, v1 }, { u0, v1 } },
                 aoShades(tx, ty, hh, 1))
            -- sides
            for _, side in ipairs(SIDES) do
              local ni, nj = i + side[1], j + side[2]
              local nh = subH(ni, nj)
              if nh == nil then
                nh = occludeH(tx + side[1], ty + side[2])
              end
              if nh < hh then
                local d = side[3]
                local x1, z1 = sx + step, sz + step
                local c
                if d == 5 then
                  c = { { sx, nh, z1 }, { x1, nh, z1 }, { x1, hh, z1 }, { sx, hh, z1 } }
                elseif d == 6 then
                  c = { { x1, nh, sz }, { sx, nh, sz }, { sx, hh, sz }, { x1, hh, sz } }
                elseif d == 1 then
                  c = { { x1, nh, z1 }, { x1, nh, sz }, { x1, hh, sz }, { x1, hh, z1 } }
                else
                  c = { { sx, nh, sz }, { sx, nh, z1 }, { sx, hh, z1 }, { sx, hh, sz } }
                end
                push(c, { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
                     Voxel3D.FACE_SHADE[d] or 1)
              end
            end
          end
        end

      elseif s then
        local run = S.runs[k]
        local h = run and run.h or shapeHeight(tx, ty, s)
        local x0, z0 = tx * 8, ty * 8

        if run and run.rise > 0 then
          local gext = run.gableExtent or run.extent
          local mid = gext / 2
          local shed = run.shedRoof
          local shedDepth = shed

          local function gableH(d)
            local t
            if shed then
              t = d / shedDepth
            else
              t = d <= mid and d / mid or (gext - d) / (gext - mid)
            end
            return run.h + run.rise * math.max(0, math.min(1, t))
          end
          
          local d0 = run.front - ty
          local hS = gableH(d0)
          local hN = gableH(d0 + 1)
          
          local roofTile, rv0, rv1
          if S.isGen3 and (run.roofRows or 0) > 0 then
            local span = math.max(mid, 0.5)
            local artRows = run.roofArtRows or run.roofRows
            local artTop = run.roofArtTop or run.north
            local band = artRows * 8
            local artDepth = math.max(1, math.min(gext, artRows))
            if S.isGen3 and run.gen3RoofRows then artDepth = math.max(1, gext) end
            
            local function artPix(d)
              local t
              if shed then
                t = 1 - d / artDepth
              else
                t = math.abs(d - mid) / span
              end
              return math.max(0, math.min(1, t)) * band
            end
            
            local a, b = artPix(d0), artPix(d0 + 1)
            local p0, p1 = math.min(a, b), math.max(a, b)
            if p1 - p0 < 0.5 then
              if p0 <= 0.001 then p0, p1 = 4, 8 else p1 = p0 + 0.5 end
            end
            local ai = math.floor(((p0 + p1) / 2) / 8)
            if ai < 0 then ai = 0 end
            if ai > artRows - 1 then ai = artRows - 1 end
            roofTile = S.tileAt[keyOf(tx, artTop + ai)] or Gen3.tileAt(map, tx, artTop + ai)
            rv0 = math.max(0, math.min(7.5, p0 - ai * 8))
            rv1 = math.max(rv0 + 0.5, math.min(8, p1 - ai * 8))
          else
            local rel = 1 - math.abs(d0 + 0.5 - mid) / math.max(mid, 0.5)
            local idx = math.min(run.roofRows - 1, math.floor((1 - rel) * run.roofRows))
            roofTile = S.tileAt[keyOf(tx, run.north + idx)] or Gen3.tileAt(map, tx, run.north + idx)
            rv0, rv1 = 0, 8
          end
          
          local swY, seY, neY, nwY = hS, hS, hN, hN
          local hipW = heightAt(tx - 1, ty) < run.h
          local hipE = heightAt(tx + 1, ty) < run.h
          if hipW then
            swY = math.max(run.h, hS - 8)
            nwY = math.max(run.h, hN - 8)
          end
          if hipE then
            seY = math.max(run.h, hS - 8)
            neY = math.max(run.h, hN - 8)
          end
          local u0, u1, v0, v1 = uvRect(roofTile, rv0, rv1)
          push({ { x0, swY, z0 + 8 }, { x0 + 8, seY, z0 + 8 },
                 { x0 + 8, neY, z0 }, { x0, nwY, z0 } },
               { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } }, 0.95, nil, s.class == "water")

          local function profileH(nr, d)
            local ne = nr.gableExtent or nr.extent
            local ndepth = nr.shedRoof
            local t
            if ndepth then
              t = d / ndepth
            else
              local nm = ne / 2
              t = d <= nm and d / nm or (ne - d) / (ne - nm)
            end
            return nr.h + (nr.rise or 0) * math.max(0, math.min(1, t))
          end
          
          local function roofEdge(ntx)
            local nr = S.runs[keyOf(ntx, ty)]
            if not nr then return nil end
            if (nr.rise or 0) <= 0 then return nr.h, nr.h end
            local nd = nr.front - ty
            return profileH(nr, nd), profileH(nr, nd + 1)
          end
          
          local function flank(nsY, nnY, sY, nY, east)
            local bS = math.max(run.h, math.min(nsY or run.h, sY))
            local bN = math.max(run.h, math.min(nnY or run.h, nY))
            if sY - bS < 0.5 and nY - bN < 0.5 then return end
            local fx = east and (x0 + 8) or x0
            if east then
              push({ { fx, bS, z0 + 8 }, { fx, bN, z0 },
                     { fx, nY, z0 }, { fx, sY, z0 + 8 } },
                   { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
                   Voxel3D.FACE_SHADE[1], nil, s.class == "water")
            else
              push({ { fx, bN, z0 }, { fx, bS, z0 + 8 },
                     { fx, sY, z0 + 8 }, { fx, nY, z0 } },
                   { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
                   Voxel3D.FACE_SHADE[2], nil, s.class == "water")
            end
          end
          
          if hipW then
            flank(nil, nil, swY, nwY, false)
          else
            local ns, nn = roofEdge(tx - 1)
            flank(ns, nn, swY, nwY, false)
          end
          if hipE then
            flank(nil, nil, seY, neY, true)
          else
            local ns, nn = roofEdge(tx + 1)
            flank(ns, nn, seY, neY, true)
          end

          local function rowEdge(nty, southSide)
            local nr = S.runs[keyOf(tx, nty)]
            if not nr then return nil end
            if (nr.rise or 0) <= 0 then return nr.h, nr.h end
            local nd = nr.front - nty
            local e = southSide and profileH(nr, nd + 1) or profileH(nr, nd)
            local w, ee = e, e
            if heightAt(tx - 1, nty) < nr.h then w = math.max(nr.h, e - 8) end
            if heightAt(tx + 1, nty) < nr.h then ee = math.max(nr.h, e - 8) end
            return w, ee
          end
          
          local function rowFlank(nw, nee, wY, eY, south)
            local bW = math.max(run.h, math.min(nw or run.h, wY))
            local bE = math.max(run.h, math.min(nee or run.h, eY))
            if wY - bW < 0.5 and eY - bE < 0.5 then return end
            if south then
              push({ { x0, bW, z0 + 8 }, { x0 + 8, bE, z0 + 8 },
                     { x0 + 8, eY, z0 + 8 }, { x0, wY, z0 + 8 } },
                   { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
                   Voxel3D.FACE_SHADE[5], nil, s.class == "water")
            else
              push({ { x0 + 8, bE, z0 }, { x0, bW, z0 },
                     { x0, wY, z0 }, { x0 + 8, eY, z0 } },
                   { { u0, v1 }, { u1, v1 }, { u1, v0 }, { u0, v0 } },
                   Voxel3D.FACE_SHADE[6], nil, s.class == "water")
            end
          end
          
          local sw, se = rowEdge(ty + 1, true)
          rowFlank(sw, se, swY, seY, true)
          local nw2, ne2 = rowEdge(ty - 1, false)
          rowFlank(nw2, ne2, nwY, neY, false)

        elseif run then
          local roomTop = nil
          if S.isGen3 and not S.outdoor and S.gen3RoomWallTop
             and not run.gen3RoofRows and s.class == "wall" then
            roomTop = S.gen3RoomWallTop[(ty % 2) * 2 + (tx % 2) + 1]
          end
          local m = math.min(2, run.extent)
          local artTop = run.north
          if S.isGen3 and (run.roofArtRows or 0) > 0 and run.roofArtTop
             and run.roofArtTop <= run.front then
            artTop = run.roofArtTop
            m = math.min(run.roofArtRows, run.front - artTop + 1)
          end
          if roomTop then
            topQuad(x0, z0, h, roomTop, VOLUME_TOP_SHADE, s.class == "water")
          elseif S.isGen3 and run.extent > m then
            local d = ty - run.north
            local band = m * 8
            local p0 = (d / run.extent) * band
            local p1 = ((d + 1) / run.extent) * band
            local ai = math.floor(((p0 + p1) / 2) / 8)
            if ai < 0 then ai = 0 end
            if ai > m - 1 then ai = m - 1 end
            local topTile = S.tileAt[keyOf(tx, artTop + ai)] or Gen3.tileAt(map, tx, artTop + ai)
            local tv0 = math.max(0, math.min(7.5, p0 - ai * 8))
            local tv1 = math.max(tv0 + 0.5, math.min(8, p1 - ai * 8))
            topQuad(x0, z0, h, topTile, VOLUME_TOP_SHADE, s.class == "water", nil, tv0, tv1)
          else
            local topTile = S.tileAt[keyOf(tx, artTop + ((ty - run.north) % m))] or Gen3.tileAt(map, tx, artTop + ((ty - run.north) % m))
            topQuad(x0, z0, h, topTile, VOLUME_TOP_SHADE, s.class == "water")
          end
        else
          local topTile = tile
          local capV0, capV1 = nil, nil
          if s.furnCap and s.art == "upright" and s.authored then
            local cap = s.furnCap
            local dRow = ty - cap.north
            if dRow < 0 then dRow = 0 end
            if dRow > cap.ext - 1 then dRow = cap.ext - 1 end
            local capBand = cap.rows * 8
            local cp0 = (dRow / cap.ext) * capBand
            local cp1 = ((dRow + 1) / cap.ext) * capBand
            local ci = math.floor(((cp0 + cp1) / 2) / 8)
            if ci < 0 then ci = 0 end
            if ci > cap.rows - 1 then ci = cap.rows - 1 end
            topTile = S.tileAt[keyOf(tx, cap.n + ci)] or topTile
            capV0 = math.max(0, math.min(7.5, cp0 - ci * 8))
            capV1 = math.max(capV0 + 0.5, math.min(8, cp1 - ci * 8))
          elseif s.art == "upright" and s.authored then
            local north, front = ty, ty
            while ty - north < 6 do
              local bs = S.shapeAt[keyOf(tx, north - 1)]
              if bs and bs.authored and bs.class == s.class then
                north = north - 1
              else
                break
              end
            end
            while front - ty < 6 do
              local bs = S.shapeAt[keyOf(tx, front + 1)]
              if bs and bs.authored and bs.class == s.class then
                front = front + 1
              else
                break
              end
            end
            local row = math.min(ty, front - math.floor(h / 8))
            if row < north then
              local above = S.shapeAt[keyOf(tx, north - 1)]
              row = (above and above.authored and above.art == "upright")
                    and (north - 1) or north
            end
            topTile = S.tileAt[keyOf(tx, row)]
          end
          topQuad(x0, z0, h, topTile,
                  s.art == "upright" and VOLUME_TOP_SHADE or 1, s.class == "water",
                  (s.class == "water") and waterPush or nil, capV0, capV1)
        end

        if s.class == "bridge" then
          local floorH, floorT = nil, nil
          for _, side in ipairs(SIDES) do
            local ntx, nty = tx + side[1], ty + side[2]
            local ns = S.shapeAt[keyOf(ntx, nty)]
            if ns and ns.class ~= "bridge" then
              local nh2 = heightAt(ntx, nty)
              if floorH == nil or nh2 < floorH then
                floorH = nh2
                floorT = S.tileAt[keyOf(ntx, nty)]
              end
            end
          end
          if floorT and floorH and h - floorH > 8 then
            topQuad(x0, z0, floorH, floorT, 1, false)
          end
        end

        for _, side in ipairs(SIDES) do
          local nh = occludeH(tx + side[1], ty + side[2])
          local bottom = nh
          if s.class == "bridge" and h - nh > 8 then bottom = h - 8 end
          if bottom < h then
            local d = side[3]
            local lat = LATERAL[d]
            local hl = lat and heightAt(tx + lat[1], ty + lat[2]) or 0
            local hr = lat and heightAt(tx + lat[3], ty + lat[4]) or 0
            for band = math.floor(bottom / 8), math.ceil(h / 8) - 1 do
              local y0 = math.max(bottom, band * 8)
              local y1 = math.min(h, band * 8 + 8)
              if y1 > y0 then
                local src, shade = tile, Voxel3D.FACE_SHADE[d]
                local vT, vB = nil, nil
                if run then
                  local bb = band - math.floor((run.base or 0) / 8)
                  if bb < 0 then bb = 0 end
                  local function foldTile(row)
                    return S.tileAt[keyOf(tx, row)] or Gen3.tileAt(map, tx, row)
                  end
                  local period = nil
                  if S.isGen3 and not run.gen3RoofRows and (run.unit or 0) > 0 and run.extent > run.unit then
                    if run.fromRepeat then
                      period = run.unit
                    elseif run.extent >= 16 then
                      period = run.unit
                    end
                  end
                  local artNorth = run.gen3ArtNorth or run.north
                  if artNorth > run.north then artNorth = run.north end
                  local roomWall = nil
                  if S.isGen3 and not S.outdoor and S.gen3RoomWallTop
                     and not run.gen3RoofRows and s.class == "wall" then
                    roomWall = S.gen3RoomWallTop
                  end
                  local stretched = false
                  if S.isGen3 and not roomWall
                     and not run.gen3RoofRows and not period
                     and not run.door and (run.front or 0) >= (artNorth or 0)
                  then
                    local faceH = h - bottom
                    local rows = run.front - artNorth + 1
                    if rows >= 1 and faceH > rows * 8 then stretched = true end
                  end

                  if run.face then
                    local faceH = h - bottom
                    local rows = run.face.rows or 1
                    local idx = 0
                    if faceH > 0 and rows > 0 then
                      local tm = ((h - y1) + (h - y0)) / (2 * faceH)
                      idx = math.floor(tm * rows)
                      if idx < 0 then idx = 0 end
                      if idx > rows - 1 then idx = rows - 1 end
                    end
                    if run.face.dir == "north" then
                      src = foldTile(run.front - idx)
                    else
                      src = foldTile(run.north + idx)
                    end
                  elseif stretched then
                    local faceH = h - bottom
                    local rows = run.front - artNorth + 1
                    local tm = ((h - y1) + (h - y0)) / (2 * faceH)
                    local idx = math.floor(tm * rows)
                    if idx < 0 then idx = 0 end
                    if idx > rows - 1 then idx = rows - 1 end
                    if d == 6 then
                      src = foldTile(artNorth + idx)
                    else
                      src = foldTile(run.front - idx)
                    end
                  elseif d == 6 then
                    if period then
                      src = foldTile(artNorth + (bb % period))
                    elseif roomWall and artNorth + bb > run.front then
                      src = roomWall[((artNorth + bb) % 2) * 2 + (tx % 2) + 1] or src
                    else
                      src = foldTile(math.min(run.front, artNorth + bb))
                    end
                  else
                    if period then
                      src = foldTile(run.front - (bb % period))
                    elseif roomWall and run.front - bb < artNorth then
                      src = roomWall[((run.front - bb) % 2) * 2 + (tx % 2) + 1] or src
                    else
                      src = foldTile(math.max(artNorth, run.front - bb))
                    end
                  end
                  if d == 5 then shade = 1 end
                elseif s.art == "upright" then
                  if d == 5 then shade = 1 end
                  local front = ty
                  while front < ty + 6 do
                    local fs2 = S.shapeAt[keyOf(tx, front + 1)]
                    if fs2 and fs2.authored and fs2.class == s.class then
                      front = front + 1
                    else
                      break
                    end
                  end
                  local rows = 0
                  while rows < 6 do
                    local rk = keyOf(tx, front - rows)
                    local rs = S.shapeAt[rk]
                    if rs and rs.class == s.class and not S.runs[rk] and not S.skip[rk] then
                      rows = rows + 1
                    else
                      break
                    end
                  end
                  if S.isGen3 and rows > 0 and h > 0 then
                    local artH = rows * 8
                    local p0 = (y0 / h) * artH
                    local p1 = (y1 / h) * artH
                    local ri = math.floor(((p0 + p1) / 2) / 8)
                    if ri < 0 then ri = 0 end
                    if ri > rows - 1 then ri = rows - 1 end
                    local sk = keyOf(tx, front - ri)
                    src = S.tileAt[sk] or src
                    vB = math.min(8, math.max(0.5, 8 - (p0 - ri * 8)))
                    vT = math.max(0, math.min(vB - 0.5, 8 - (p1 - ri * 8)))
                  else
                    local fk = keyOf(tx, front - band)
                    local fs = S.shapeAt[fk]
                    if fs and fs.authored and fs.class == s.class then
                      src = S.tileAt[fk]
                    end
                  end
                end
                
                if s.rock and vT == nil and vB == nil then
                  local faceH = h - bottom
                  if faceH > 8 then
                    vT = 8 * (h - y1) / faceH
                    vB = 8 * (h - y0) / faceH
                  end
                end
                
                sideQuad(d, x0, z0, y0, y1, src,
                         vT or ((band * 8 + 8) - y1),
                         vB or ((band * 8 + 8) - y0),
                         sideShades(hl, hr, y0, y1, y0 <= nh, shade), s.class == "water")
              end
            end
          end
        end
      end
    end
  end

  local bw, bh = tw * 8, th * 8
  local function keepQuad(x0, z0, x1, z1)
    local overBody = x1 > 0 and x0 < bw and z1 > 0 and z0 < bh
    if bodyOnly then return overBody end
    return overBody or not maskedClosed(x0, z0, x1, z1)
  end

  local function outwardOnEdge(q, x0, z0, x1, z1)
    if z0 == z1 and (z0 == 0 or z0 == bh) and x1 > 0 and x0 < bw then
      local nz = (q[2][1] - q[1][1]) * (q[3][2] - q[1][2])
                 - (q[2][2] - q[1][2]) * (q[3][1] - q[1][1])
      return (z0 == bh and nz > 0) or (z0 == 0 and nz < 0)
    end
    if x0 == x1 and (x0 == 0 or x0 == bw) and z1 > 0 and z0 < bh then
      local nx = (q[2][2] - q[1][2]) * (q[3][3] - q[1][3])
                 - (q[2][3] - q[1][3]) * (q[3][2] - q[1][2])
      return (x0 == bw and nx > 0) or (x0 == 0 and nx < 0)
    end
    return false
  end

  local scUV = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }
  local function quadUV(q)
    if q.uv then return q.uv end
    for i = 1, 4 do
      scUV[i][1], scUV[i][2] = q.u, q.v
    end
    return scUV
  end

  for _, q in ipairs(S.objectQuads) do
    Budget.tick()
    local x0 = math.min(q[1][1], q[2][1], q[3][1], q[4][1])
    local x1 = math.max(q[1][1], q[2][1], q[3][1], q[4][1])
    local z0 = math.min(q[1][3], q[2][3], q[3][3], q[4][3])
    local z1 = math.max(q[1][3], q[2][3], q[3][3], q[4][3])
    if q.own or outwardOnEdge(q, x0, z0, x1, z1)
       or keepQuad(x0, z0, x1, z1) then
      push({ q[1], q[2], q[3], q[4] }, quadUV(q), groundShades(q, q.shade), nil, false)
    end
  end

  local function containedInMask(x0, z0, x1, z1)
    if not masks then return false end
    for _, mk in ipairs(masks) do
      if x0 >= mk[1] and x1 <= mk[3] and z0 >= mk[2] and z1 <= mk[4] then
        return true
      end
    end
    return false
  end

  local sc = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
  for _, st in ipairs(S.roundStamps or {}) do
    local mx, mz = st.mx, st.mz
    local my = st.my or 0
    local sr = st.r or 8
    
    if S.isGen3 then
      local acx = math.floor((mx - sr) / 16) * 2
      local acz = math.floor((mz - sr) / 16) * 2
      if S.skip[keyOf(acx, acz)] then
        local fy = heightAt(acx, acz)
        if type(fy) == "number" then my = fy end
      end
    end
    
    local sx0, sz0, sx1, sz1 = mx - sr, mz - sr, mx + sr, mz + sr
    local interior = sx0 > 0 and sx1 < bw and sz0 > 0 and sz1 < bh
    local overBody = sx1 > 0 and sx0 < bw and sz1 > 0 and sz0 < bh
    local keepAll, skipAll
    if bodyOnly then
      keepAll = interior
      skipAll = not overBody
    else
      keepAll = interior or not maskedClosed(sx0, sz0, sx1, sz1)
      skipAll = not overBody and containedInMask(sx0, sz0, sx1, sz1)
    end
    
    if not skipAll then
      for _, q in ipairs(st.quads) do
        Budget.tick()
        for i = 1, 4 do
          local c, s2 = q[i], sc[i]
          s2[1] = c[1] + mx
          s2[2] = c[2] + my
          s2[3] = c[3] + mz
        end
        local ok = keepAll
        if not ok then
          local x0 = math.min(sc[1][1], sc[2][1], sc[3][1], sc[4][1])
          local x1 = math.max(sc[1][1], sc[2][1], sc[3][1], sc[4][1])
          local z0 = math.min(sc[1][3], sc[2][3], sc[3][3], sc[4][3])
          local z1 = math.max(sc[1][3], sc[2][3], sc[3][3], sc[4][3])
          ok = keepQuad(x0, z0, x1, z1)
        end
        if ok then
          push(sc, quadUV(q), groundShades(sc, q.shade), q.sky, false)
        end
      end
    end
  end
end

function ChunkMesher.geometry(map, bodyOnly, masks, split)
  local sink = newTableSink()
  local waterSink = split and newTableSink() or nil
  runGeometry(map, bodyOnly, masks, sink, waterSink)
  if not waterSink then return sink.results() end
  local v, i, n = sink.results()
  local wv, wi, wn = waterSink.results()
  return v, i, n, wv, wi, wn
end

function ChunkMesher.build(map, bodyOnly, masks)
  local sink = newChunkedSink()
  runGeometry(map, bodyOnly, masks, sink)
  return sink.finish()
end

-- ---------------------------------------------------------------- prebake

function ChunkMesher.bake(map, slot, masks)
  slot = slot or "body"
  if not DiskCache then return false, "no disk cache" end
  if type(DiskCache.enabled) == "function" and not DiskCache.enabled() then
    return false, "disabled"
  end
  if type(DiskCache.has) == "function" then
    local okHas, hit = pcall(DiskCache.has, map, slot, masks)
    if okHas and hit then return false, "cached" end
  end
  local sink = newSink()
  if type(sink.writeRaw) ~= "function" then
    return false, "no ffi sink"
  end
  local waterSink = newSink()
  local okGeom, err = pcall(runGeometry, map, slot == "body", masks, sink, waterSink)
  if not okGeom then return false, tostring(err) end
  local okStore, stored = pcall(DiskCache.store, map, slot, masks, sink, waterSink)
  if not okStore then return false, tostring(stored) end
  return stored and true or false, stored and nil or "store declined"
end

local function quadsMesh(quads)
  if #quads == 0 then return nil end
  local verts, indices, n = {}, {}, 0
  for _, q in ipairs(quads) do
    local s = faceSign(q, q.sky)
    for i = 1, 4 do
      local c = q[i]
      local uv = q.uv and q.uv[i] or { q.u, q.v }
      verts[#verts + 1] = { c[1], c[2], c[3], uv[1], uv[2], s * q.shade, 0.0 }
    end
    Voxel3D.pushQuad(indices, n)
    n = n + 1
  end
  return Voxel3D.newMesh(verts, indices)
end

local function buildGrassMesh(map)
  local S = Structures.forMap(map)
  if S.grassInstances and #S.grassInstances > 0 then
    local ok, G = pcall(V.require, "Grass3D")
    if ok and G and G.meshFromInstances then
      local mesh = G.meshFromInstances(S.grassInstances)
      if mesh then return mesh end
    end
  end
  return quadsMesh(S.grassQuads)
end

local function buildDecorMesh(map)
  local S = Structures.forMap(map)
  if S.decorInstances and #S.decorInstances > 0 then
    local ok, G = pcall(V.require, "Grass3D")
    if ok and G and G.decorMeshFromInstances then
      return G.decorMeshFromInstances(S.decorInstances)
    end
  end
  return nil
end

local function buildRoadMesh(map)
  local S = Structures.forMap(map)
  if S.roadInstances and #S.roadInstances > 0 then
    local ok, G = pcall(V.require, "Grass3D")
    if ok and G and G.roadMeshFromInstances then
      return G.roadMeshFromInstances(S.roadInstances)
    end
  end
  return nil
end

local function buildGroundMesh(map)
  local S = Structures.forMap(map)
  if S.groundInstances and #S.groundInstances > 0 then
    local ok, G = pcall(V.require, "Grass3D")
    if ok and G and G.groundMeshFromInstances then
      return G.groundMeshFromInstances(S.groundInstances)
    end
  end
  return nil
end

local function buildFlowerMesh(map)
  return quadsMesh(Structures.forMap(map).flowerQuads)
end

local function buildCustomSurfaceMesh(map)
  local S = Structures.forMap(map)
  if S.customSurfaceMesh then
    return S.customSurfaceMesh
  end
  return nil
end

local function buildFigureMeshes(map)
  local out = {}
  for _, f in ipairs(Structures.forMap(map).figures or {}) do
    local mesh = quadsMesh(f.quads)
    if mesh then
      out[#out + 1] = { mesh = mesh, wx = f.wx, wz = f.wz, y = f.y }
    end
  end
  return out
end

local function releaseFigures(list)
  for _, f in ipairs(type(list) == "table" and list or {}) do
    if f.mesh and f.mesh.release then pcall(f.mesh.release, f.mesh) end
  end
end

local function swapSlot(c, slot, mesh)
  local old = c[slot]
  if old and old ~= mesh and old.release then pcall(old.release, old) end
  c[slot] = mesh
end

-- ------------------------------------------------------------- the cache

local function entry(id)
  local c = cache[id]
  if not c then
    c = {}
    cache[id] = c
  end
  return c
end

local function releaseEntry(c)
  for _, slot in ipairs({ "full", "body", "grass", "flowers", "custom", "road", "ground", "decor" }) do
    local mesh = c[slot]
    if mesh and mesh.release then pcall(mesh.release, mesh) end
    c[slot] = nil
  end
  releaseFigures(c.figures)
  c.figures = nil
  c.stale = nil
end

-- ---------------------------------------------------------- async builds

local jobs = {}       -- FIFO of pending jobs
local jobIndex = {}   -- "id:slot" -> job

local clock = (love and love.timer and love.timer.getTime) or os.clock

local function jobKey(id, slot)
  return id .. ":" .. slot
end

local buildErrors = {}

function ChunkMesher.buildFailure(mapId)
  return buildErrors[mapId]
end

local function finishJob(job, ok, err)
  jobIndex[jobKey(job.id, job.slot)] = nil
  for i, j in ipairs(jobs) do
    if j == job then
      table.remove(jobs, i)
      break
    end
  end
  if not ok then
    buildErrors[job.id] = tostring(err)
    print("[warn] voxel mesh build failed for " .. tostring(job.id)
          .. ": " .. tostring(err))
    if (gen[job.id] or 0) == job.gen then
      entry(job.id)[job.slot] = false
    end
  end
end

local function runJob(job)
  local map = job.map
  local c = entry(job.id)

  if c.grass == nil or c.flowers == nil or c.figures == nil or c.custom == nil or c.road == nil or c.ground == nil or c.decor == nil
     or (c.stale and c.stale.aux) then
    local okG, grass = pcall(buildGrassMesh, map)
    local okF, flowers = pcall(buildFlowerMesh, map)
    local okX, figures = pcall(buildFigureMeshes, map)
    local okC, custom = pcall(buildCustomSurfaceMesh, map)
    local okR, road = pcall(buildRoadMesh, map)
    local okGnd, ground = pcall(buildGroundMesh, map)
    local okD, decor = pcall(buildDecorMesh, map)
    if (gen[job.id] or 0) ~= job.gen then
      if okG and grass and grass.release then pcall(grass.release, grass) end
      if okF and flowers and flowers.release then pcall(flowers.release, flowers) end
      if okX then releaseFigures(figures) end
      if okC and custom and custom.release then pcall(custom.release, custom) end
      if okR and road and road.release then pcall(road.release, road) end
      if okGnd and ground and ground.release then pcall(ground.release, ground) end
      if okD and decor and decor.release then pcall(decor.release, decor) end
      return
    end
    swapSlot(c, "grass", (okG and grass) or false)
    swapSlot(c, "flowers", (okF and flowers) or false)
    swapSlot(c, "figures", (okX and figures) or false)
    swapSlot(c, "custom", (okC and custom) or false)
    swapSlot(c, "road", (okR and road) or false)
    swapSlot(c, "ground", (okGnd and ground) or false)
    swapSlot(c, "decor", (okD and decor) or false)
    releaseFigures(c.figures)
    c.figures = (okX and figures) or false
    if c.stale then c.stale.aux = nil end
  end
  if cachedTerrain == nil then
    local sink = newChunkedSink()
    runGeometry(map, job.slot == "body", job.masks, sink)
    local mesh = sink.finish()
    if (gen[job.id] or 0) ~= job.gen then
      if mesh and mesh.release then pcall(mesh.release, mesh) end
      return
    end
    swapSlot(c, job.slot, mesh or false)
  end
  if c.stale then
    c.stale[job.slot] = nil
    if not (c.stale.full or c.stale.body or c.stale.aux) then
      c.stale = nil
    end
  end
end

function ChunkMesher.request(map, bodyOnly, masks, urgent)
  local slot = bodyOnly and "body" or "full"
  local c = cache[map.id]
  local stale = c and c.stale and (c.stale[slot] or c.stale.aux)
  if c and c[slot] ~= nil and not stale then return c[slot] or nil end
  local key = jobKey(map.id, slot)
  local job = jobIndex[key]
  if not job then
    job = { id = map.id, map = map, slot = slot, masks = masks,
            urgent = urgent or false, gen = gen[map.id] or 0 }
    jobIndex[key] = job
    jobs[#jobs + 1] = job
  elseif urgent then
    job.urgent = true
  end
  return (c and c[slot]) or nil
end

function ChunkMesher.pending()
  return #jobs
end

local URGENT_SLICE = 0.012
local IDLE_SLICE = 0.005
local COVERED_SLICE = 0.030
local COLD_SLICE = 0.024

local FRAME_TARGET = 1 / 60
local SHARE = 0.75
local MIN_SLICE = 0.0015

ChunkMesher.frameTarget = FRAME_TARGET

function ChunkMesher.setFrameTarget(seconds)
  seconds = tonumber(seconds)
  if seconds and seconds > 0 then
    ChunkMesher.frameTarget = seconds
  end
end

local lastSpend = 0    -- seconds this module burned last pump
local avgOther = nil   -- smoothed seconds the REST of the frame costs

local function sliceFor(urgent, covered)
  if covered then return COVERED_SLICE end
  local cap = urgent and URGENT_SLICE or IDLE_SLICE
  local dt = (love and love.timer and love.timer.getDelta
              and love.timer.getDelta()) or ChunkMesher.frameTarget
  local other = math.max(0, dt - lastSpend)
  avgOther = avgOther and (avgOther * 0.8 + other * 0.2) or other
  local headroom = ChunkMesher.frameTarget - avgOther
  return math.max(MIN_SLICE, math.min(cap, headroom * SHARE))
end

function ChunkMesher.lastSlice() return lastSpend end

function ChunkMesher.pump(covered)
  local seamDirty = Structures.gen3SeamDirty
  if seamDirty then
    local due = nil
    for id in pairs(seamDirty) do
      seamDirty[id] = nil
      if cache[id] then due = due or {}; due[#due + 1] = id end
    end
    if due then
      for _, id in ipairs(due) do ChunkMesher.refresh(id) end
    end
  end
  
  if #jobs == 0 then lastSpend = 0 return end
  local pick = jobs[1]
  for _, j in ipairs(jobs) do
    if j.urgent then
      pick = j
      break
    end
  end
  local started = clock()
  local cold = false
  if pick.urgent and not covered then
    local cc = cache[pick.id]
    if not (cc and (cc.full or cc.body)) then cold = true end
  end
  local slice = cold and COLD_SLICE or sliceFor(pick.urgent, covered)
  local deadline = started + slice
  while pick do
    if not pick.co then
      pick.co = coroutine.create(runJob)
    end
    Budget.begin(pick.co, deadline - clock())
    local ok, err = coroutine.resume(pick.co, pick)
    Budget.finish()
    if not ok then
      finishJob(pick, false, err)
    elseif coroutine.status(pick.co) == "dead" then
      finishJob(pick, true)
    else
      lastSpend = clock() - started
      return
    end
    if clock() >= deadline or #jobs == 0 then
      lastSpend = clock() - started
      return
    end
    pick = jobs[1]
    for _, j in ipairs(jobs) do
      if j.urgent then
        pick = j
        break
      end
    end
  end
  lastSpend = clock() - started
end

function ChunkMesher.get(map, bodyOnly, masks)
  local slot = bodyOnly and "body" or "full"
  local c = entry(map.id)
  if c.grass == nil or c.flowers == nil or c.custom == nil or c.road == nil or c.ground == nil or c.decor == nil or (c.stale and c.stale.aux) then
    local okG, grass = pcall(buildGrassMesh, map)
    local okF, flowers = pcall(buildFlowerMesh, map)
    local okC, custom = pcall(buildCustomSurfaceMesh, map)
    local okR, road = pcall(buildRoadMesh, map)
    local okGnd, ground = pcall(buildGroundMesh, map)
    local okD, decor = pcall(buildDecorMesh, map)
    swapSlot(c, "grass", (okG and grass) or false)
    swapSlot(c, "flowers", (okF and flowers) or false)
    swapSlot(c, "custom", (okC and custom) or false)
    swapSlot(c, "road", (okR and road) or false)
    swapSlot(c, "ground", (okGnd and ground) or false)
    swapSlot(c, "decor", (okD and decor) or false)
    if c.stale then c.stale.aux = nil end
  end
  if c[slot] == nil or (c.stale and c.stale[slot]) then
    local ok, mesh = pcall(ChunkMesher.build, map, bodyOnly, masks)
    if not ok then
      print("[warn] voxel mesh build failed for " .. tostring(map.id)
            .. ": " .. tostring(mesh))
    end
    swapSlot(c, slot, (ok and mesh) or false)
    if c.stale then
      c.stale[slot] = nil
      if not (c.stale.full or c.stale.body or c.stale.aux) then
        c.stale = nil
      end
    end
    local key = jobKey(map.id, slot)
    local job = jobIndex[key]
    if job then finishJob(job, true) end
  end
  return c[slot] or nil
end

function ChunkMesher.peek(map, bodyOnly)
  local c = cache[map.id]
  local mesh = c and c[bodyOnly and "body" or "full"]
  return mesh or nil
end

function ChunkMesher.grass(map)
  local c = cache[map.id]
  return c and c.grass or nil
end

function ChunkMesher.flowers(map)
  local c = cache[map.id]
  return c and c.flowers or nil
end

function ChunkMesher.custom(map)
  local c = cache[map.id]
  return c and c.custom or nil
end

function ChunkMesher.decor(map)
  local c = cache[map.id]
  return c and c.decor or nil
end

function ChunkMesher.road(map)
  local c = cache[map.id]
  return c and c.road or nil
end

function ChunkMesher.ground(map)
  local c = cache[map.id]
  return c and c.ground or nil
end

function ChunkMesher.figures(map)
  local c = cache[map.id]
  local list = c and c.figures
  return (type(list) == "table") and list or nil
end

function ChunkMesher.refresh(mapId)
  if not mapId then return ChunkMesher.invalidate() end
  local c = cache[mapId]
  if not (c and (c.full or c.body)) then
    return ChunkMesher.invalidate(mapId)
  end
  Structures.invalidate(mapId)
  gen[mapId] = (gen[mapId] or 0) + 1
  for i = #jobs, 1, -1 do
    local job = jobs[i]
    if job.id == mapId then
      jobIndex[jobKey(job.id, job.slot)] = nil
      table.remove(jobs, i)
    end
  end
  c.stale = { aux = true,
              full = (c.full ~= nil) or nil,
              body = (c.body ~= nil) or nil }
end

local prevLive = {}

function ChunkMesher.setLive(live)
  for id, c in pairs(cache) do
    if not live[id] and not prevLive[id] then
      releaseEntry(c)
      cache[id] = nil
      gen[id] = (gen[id] or 0) + 1
      Structures.invalidate(id)
    end
  end
  for i = #jobs, 1, -1 do
    local job = jobs[i]
    if not live[job.id] and not prevLive[job.id] then
      jobIndex[jobKey(job.id, job.slot)] = nil
      table.remove(jobs, i)
    end
  end
  prevLive = live
end

function ChunkMesher.invalidate(mapId)
  Structures.invalidate(mapId)
  if mapId then
    local c = cache[mapId]
    if c then releaseEntry(c) end
    cache[mapId] = nil
    gen[mapId] = (gen[mapId] or 0) + 1
  else
    for _, c in pairs(cache) do releaseEntry(c) end
    cache = {}
    for id in pairs(gen) do gen[id] = gen[id] + 1 end
  end
  for i = #jobs, 1, -1 do
    local job = jobs[i]
    if mapId == nil or job.id == mapId then
      jobIndex[jobKey(job.id, job.slot)] = nil
      table.remove(jobs, i)
    end
  end
end

Assets.register(function() ChunkMesher.invalidate() end)

return ChunkMesher