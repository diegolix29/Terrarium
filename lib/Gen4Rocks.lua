-- Gen4Rocks: small grey voxel rocks standing where Platinum's route rocks are.
--
-- WHAT PLATINUM DRAWS
--
-- Route clutter and fence runs share the terrain texture `imped` (found with
-- the Gen4Lawn colour probe). Both are flat cards, like the tree cards
-- Gen4Trees replaces:
--   * a roughly square card is a rock sprite
--   * a long banner -- wide (east/west) OR tall (north/south / standing) -- is a fence
-- Only the square cards become voxel rocks. Banner cards are Gen4Fence's: it
-- stands real 3D fences on them (and falls back to leaving them native).
--
-- WHAT THIS BUILDS INSTEAD
--
-- For every card of an `imped` shape: a low-poly boulder (a lumpy 80-facet
-- sphere, flattened underneath and planted in the ground) plus one or two small
-- satellite stones. Shape, squash and lumps come from a hash of the card's
-- position, so rocks differ but never change between frames. Each facet is lit
-- flat from the upper-front (so the rock reads as faceted stone, not a block)
-- and wears a grey texel with the odd darker crack / lighter face / mossy tint.
--
-- HIDING THE NATIVE CARD
--
-- Gen4Hide drops a native `imped` shape only when EVERY card in that shape
-- converted to a rock. A shape that is all fence banners, or mixed, keeps
-- drawing natively so fences never vanish. Lawn no longer paints the whole
-- `imped` material transparent (that was turning fences into holes).
--
-- KNOBS: Rocks.SIZE, MIN_W, MAX_W, FENCE_ASPECT, FENCE_MIN_W, Y_OFFSET, SINK,
-- WINDOW, enabled. Bridge.disabled.rocks turns it off.

local V = ...
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")

local Rocks = {
  enabled = true,
  TEXTURES = { imped = true },   -- terrain texture names that are rocks OR fence banners
  WINDOW = 2,                    -- lands each way around the camera
  SIZE = 1.35,                    -- rock width as a fraction of the card's width
  MIN_W = 14,                    -- never narrower than this (world units; a tile is 16)
  MAX_W = 28,                    -- ...never wider than this
  FENCE_ASPECT = 1.75,           -- longest/shortest edge at or above this is a banner
  FENCE_MIN_W = 40,              -- ...or any card this long in XZ or Y (a rock is one tile)
  HEIGHT = 0.9,                 -- rock height as a fraction of its width
  LUMP = 0.30,                   -- how lumpy the surface is (0 = smooth egg, 0.4 = very rough)
  SATELLITES = 2,                -- up to this many small stones beside each rock
  -- Trees need Y_OFFSET = -10 because a tall card still shows after the sink.
  -- A rock is only ~8 units tall: the same -10 buries the whole mesh under the
  -- terrain, Lawn then hides the native card, and nothing is left on screen.
  Y_OFFSET = 0,
  SINK = 1.0,                    -- planted this far into the ground
  BUILDS_PER_FRAME = 4,
  MAX_RESIDENT = 20,
  LOG = true,
  version = 0,                   -- bumps whenever the set of built lands changes
}

local FX16, UV_UNITS = 4096, 16
local LIGHT = { 0.35, 0.80, 0.50 }      -- toward the light: up and a little to the front

local warned = {}
local function once(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if V.mod and V.mod.log then V.mod.log:info("Gen4Rocks: " .. fmt:format(...)) end
end

local function optional(name)
  local ok, mod = pcall(V.require, name)
  return ok and mod or nil
end

local Budget = optional("Gen4Budget") or { allow = function() return true end, charge = function() end }
local clock = (love and love.timer and love.timer.getTime) or os.clock

-- ---------------------------------------------------------------- texture --

-- An 8x8 picture generated here (no file to ship). Rows 0-5 are the stone
-- (mid greys, a hint of warm/cool), row 6 darker cracks, row 7 lighter faces and
-- a mossy tint. Each facet samples ONE texel, picked by hash.
local GRID = 8
local texture                 -- Image | false
local function rockTexture()
  if texture ~= nil then return texture or nil end
  local ok, img = pcall(function()
    local data = love.image.newImageData(GRID, GRID)
    for y = 0, GRID - 1 do
      for x = 0, GRID - 1 do
        local n = ((x * 7 + y * 13 + x * y * 3) % 6) / 5           -- 0..1
        local g = 0.46 + 0.14 * n
        local r, gg, b = g * 1.02, g, g * 0.97                       -- slightly warm stone
        if x % 2 == 1 then r, gg, b = g * 0.97, g, g * 1.04 end     -- ...and slightly cool
        if y == 6 then r, gg, b = g * 0.62, g * 0.62, g * 0.64       -- cracks / shadowed
        elseif y == 7 then
          if x < 5 then r, gg, b = g * 1.28, g * 1.28, g * 1.25      -- light faces
          else r, gg, b = g * 0.85, g * 1.05, g * 0.72 end           -- moss
        end
        data:setPixel(x, y, math.min(r, 1), math.min(gg, 1), math.min(b, 1), 1)
      end
    end
    local image = love.graphics.newImage(data)
    image:setFilter("nearest", "nearest")
    return image
  end)
  texture = ok and img or false
  if not texture then once("tex", "could not build the rock texture: %s", tostring(img)) end
  return texture or nil
end

-- ---------------------------------------------------------------- decoding --

local function s16(data, at)
  local a, b = data:byte(at + 1, at + 2)
  if not b then return 0 end
  local value = a + b * 256
  if value >= 32768 then value = value - 65536 end
  return value
end

local function readShape(ground, s, posScale)
  local vdata, idata = s.vertices, s.indices
  if type(vdata) ~= "string" or type(idata) ~= "string" then
    vdata = ground:slice(s.vertexAt, s.vertexBytes)
    idata = ground:slice(s.indexAt, s.indexBytes)
  end
  local count, tris = s.vertexCount or 0, s.triangleCount or 0
  if not (vdata and idata) or count < 3 or tris < 1 then return nil end
  local stride = math.floor(#vdata / count)
  if stride < 10 then return nil end
  local pos = {}
  for i = 1, count do
    local at = (i - 1) * stride
    pos[i] = { s16(vdata, at) / FX16 * posScale,
               s16(vdata, at + 2) / FX16 * posScale,
               s16(vdata, at + 4) / FX16 * posScale }
  end
  local list = {}
  for t = 0, tris - 1 do
    local a1, a2, b1, b2, c1, c2 = idata:byte(t * 6 + 1, t * 6 + 6)
    if not c2 then break end
    list[#list + 1] = { a1 + a2 * 256 + 1, b1 + b2 * 256 + 1, c1 + c2 * 256 + 1 }
  end
  return pos, list
end

local function posKey(p)
  return string.format("%.2f,%.2f,%.2f", p[1], p[2], p[3])
end

-- Pair consecutive triangles into cards: each pair that shares an edge has four
-- distinct corners. Returns { {cx, baseY, cz, planeW, planeH}, ... }.
local function cardsOf(positions, tris)
  local cards = {}
  local i = 1
  while i < #tris do
    local seen, corners = {}, {}
    for _, t in ipairs({ tris[i], tris[i + 1] }) do
      for k = 1, 3 do
        local p = positions[t[k]]
        if p then
          local key = posKey(p)
          if not seen[key] then seen[key] = true; corners[#corners + 1] = p end
        end
      end
    end
    if #corners == 4 then
      local sx, sz, ymin, ymax = 0, 0, math.huge, -math.huge
      local xmin, xmax, zmin, zmax = math.huge, -math.huge, math.huge, -math.huge
      for _, p in ipairs(corners) do
        sx, sz = sx + p[1], sz + p[3]
        ymin, ymax = math.min(ymin, p[2]), math.max(ymax, p[2])
        xmin, xmax = math.min(xmin, p[1]), math.max(xmax, p[1])
        zmin, zmax = math.min(zmin, p[3]), math.max(zmax, p[3])
      end
      local planeW = math.max(xmax - xmin, zmax - zmin)
      local planeH = math.max(0.01, ymax - ymin)
      cards[#cards + 1] = { sx / 4, ymin, sz / 4, planeW, planeH }
      i = i + 2
    else
      i = i + 1        -- not a pair: slide by one and try again
    end
  end
  return cards
end

-- Banners share `imped` with rocks. Horizontal runs are wide in XZ; vertical
-- runs are tall in Y. Either way the card is elongated -- a rock is square.
local function isFenceCard(c)
  local w, h = c[4] or 0, math.max(c[5] or 0, 0.01)
  local long, short = w, h
  if h > w then long, short = h, w end
  if long >= (Rocks.FENCE_MIN_W or 40) then return true end
  return (long / short) >= (Rocks.FENCE_ASPECT or 1.75)
end
-- Gen4Fence classifies cards with this same test, so a card is never both a
-- boulder and a fence.
Rocks.isFenceCard = isFenceCard

-- ------------------------------------------------------------------ mesh --

local function hash(x, z)
  local h = math.floor(x * 73.1 + z * 151.7) % 2147483647
  h = (h * 1103515245 + 12345) % 2147483648
  return h / 2147483648
end

-- Unit icosphere, subdivided once: 42 vertices, 80 triangles. Built once.
local template
local function icosphere()
  if template then return template end
  local t = (1 + math.sqrt(5)) / 2
  local v = {
    { -1, t, 0 }, { 1, t, 0 }, { -1, -t, 0 }, { 1, -t, 0 },
    { 0, -1, t }, { 0, 1, t }, { 0, -1, -t }, { 0, 1, -t },
    { t, 0, -1 }, { t, 0, 1 }, { -t, 0, -1 }, { -t, 0, 1 },
  }
  local function norm(p)
    local l = math.sqrt(p[1] * p[1] + p[2] * p[2] + p[3] * p[3])
    return { p[1] / l, p[2] / l, p[3] / l }
  end
  for i = 1, #v do v[i] = norm(v[i]) end
  local f = {
    { 1, 12, 6 }, { 1, 6, 2 }, { 1, 2, 8 }, { 1, 8, 11 }, { 1, 11, 12 },
    { 2, 6, 10 }, { 6, 12, 5 }, { 12, 11, 3 }, { 11, 8, 7 }, { 8, 2, 9 },
    { 4, 10, 5 }, { 4, 5, 3 }, { 4, 3, 7 }, { 4, 7, 9 }, { 4, 9, 10 },
    { 5, 10, 6 }, { 3, 5, 12 }, { 7, 3, 11 }, { 9, 7, 8 }, { 10, 9, 2 },
  }
  local cache, out = {}, {}
  local function mid(a, b)
    local key = a < b and (a .. ":" .. b) or (b .. ":" .. a)
    local hit = cache[key]
    if hit then return hit end
    local pa, pb = v[a], v[b]
    v[#v + 1] = norm({ (pa[1] + pb[1]) / 2, (pa[2] + pb[2]) / 2, (pa[3] + pb[3]) / 2 })
    cache[key] = #v
    return #v
  end
  for _, tri in ipairs(f) do
    local a, b, c = tri[1], tri[2], tri[3]
    local ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
    out[#out + 1] = { a, ab, ca }
    out[#out + 1] = { b, bc, ab }
    out[#out + 1] = { c, ca, bc }
    out[#out + 1] = { ab, bc, ca }
  end
  template = { verts = v, faces = out }
  return template
end

-- One boulder centred at (cx, cz), standing on baseY. `w` is its width.
local function boulder(b, cx, baseY, cz, w, seed)
  local tpl = icosphere()
  local r1, r2, r3, r4 = hash(seed, 1.7), hash(2.3, seed), hash(seed + 4.1, seed - 9.2), hash(seed * 0.37, 5.5)
  local ax, az = 0.5 * w * (0.85 + 0.35 * r1), 0.5 * w * (0.85 + 0.35 * r2)   -- half widths
  local hy = w * Rocks.HEIGHT * (0.8 + 0.4 * r3) * 0.5                          -- half height
  local yaw = r4 * 6.2832
  local cs, sn = math.cos(yaw), math.sin(yaw)
  local p1, p2, p3 = r1 * 6.28, r2 * 6.28, r3 * 6.28
  local flatY = -0.38                                  -- unit-sphere y below which it is cut flat
  local pts = {}
  for i, u in ipairs(tpl.verts) do
    -- smooth lumps (three low-frequency sines) plus a little per-vertex jitter
    local lump = math.sin(u[1] * 2.3 + p1) * math.sin(u[2] * 2.9 + p2)
               + 0.6 * math.sin(u[3] * 3.1 + p3 + u[1])
    local jit = hash(seed + i * 0.731, i * 1.37 + seed) - 0.5
    local r = 1 + Rocks.LUMP * 0.5 * lump + Rocks.LUMP * 0.45 * jit
    local x, y, z = u[1] * r, u[2] * r, u[3] * r
    if y < flatY then y = flatY end                    -- flat underside that sits in the ground
    local lx, lz = x * ax, z * az
    pts[i] = { cx + lx * cs - lz * sn, y * hy, cz + lx * sn + lz * cs }
  end
  local lift = baseY - Rocks.SINK - flatY * hy       -- put the flat underside at the ground (minus the sink)
  for fi, face in ipairs(tpl.faces) do
    local a, c2, d = pts[face[1]], pts[face[2]], pts[face[3]]
    -- face normal, oriented away from the rock's centre
    local ux, uy, uz = c2[1] - a[1], c2[2] - a[2], c2[3] - a[3]
    local vx, vy, vz = d[1] - a[1], d[2] - a[2], d[3] - a[3]
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    local len = math.sqrt(nx * nx + ny * ny + nz * nz)
    if len > 1e-6 then
      nx, ny, nz = nx / len, ny / len, nz / len
      local mx, my, mz = (a[1] + c2[1] + d[1]) / 3 - cx, (a[2] + c2[2] + d[2]) / 3, (a[3] + c2[3] + d[3]) / 3 - cz
      if nx * mx + ny * my + nz * mz < 0 then nx, ny, nz = -nx, -ny, -nz end
      local lit = math.max(0, nx * LIGHT[1] + ny * LIGHT[2] + nz * LIGHT[3])
      local shade = math.min(1.0, 0.50 + 0.55 * lit)
      if ny > 0.55 then shade = -shade end             -- faces the sky (same flag the voxel trees use)
      -- texel: mostly stone, sometimes a crack / light face / moss
      local roll = hash(seed + fi * 3.3, fi + seed * 0.1)
      local cell
      if roll < 0.82 then cell = math.floor(hash(fi, seed) * 48)
      elseif roll < 0.90 then cell = 48 + math.floor(hash(seed, fi) * 8)
      else cell = 56 + math.floor(hash(fi * 2.1, seed) * 8) end
      local u = ((cell % GRID) + 0.5) / GRID
      local v = (math.floor(cell / GRID) % GRID + 0.5) / GRID
      local base = #b.verts
      b.verts[base + 1] = { a[1], a[2] + lift, a[3], u, v, shade, 0 }
      b.verts[base + 2] = { c2[1], c2[2] + lift, c2[3], u, v, shade, 0 }
      b.verts[base + 3] = { d[1], d[2] + lift, d[3], u, v, shade, 0 }
      b.map[#b.map + 1], b.map[#b.map + 2], b.map[#b.map + 3] = base + 1, base + 2, base + 3
    end
  end
end

local function buildRock(b, cx, baseY, cz, cardW)
  local w = math.max(Rocks.MIN_W, math.min(Rocks.MAX_W, cardW * Rocks.SIZE))
  boulder(b, cx, baseY, cz, w, cx * 0.91 + cz * 1.73)
  local extra = math.min(Rocks.SATELLITES or 0, math.floor(hash(cx + 5.5, cz - 1.1) * 3))
  for k = 1, extra do
    local ang = hash(cx * k, cz + k) * 6.2832
    local dist = w * (0.55 + 0.25 * hash(cz, cx * k + 2))
    local sw = w * (0.28 + 0.2 * hash(cx + k, cz * 2.3))
    boulder(b, cx + math.cos(ang) * dist, baseY, cz + math.sin(ang) * dist, sw, cx * 0.57 + cz * 2.11 + k * 7.7)
  end
  return 80
end

-- ------------------------------------------------------------------ lands --

local landEntries = setmetatable({}, { __mode = "k" })   -- land -> { mesh, rocks, shapes }
local resident = 0
local list = {}
local window = {}
local tick = 0
Rocks.active = {}
Rocks.coverVersion = 0
local lastCoverSig = ""

local function buildLand(ground, land)
  local out = { rocks = 0, fences = 0, shapes = {} }
  local record = ground.terrain.chunks[land]
  if not (record and record.shapes) then return out end
  local b = { verts = {}, map = {} }
  local shapesSeen, leftover = 0, 0
  for _, s in ipairs(record.shapes) do
    local tex = tostring(s.texture or s.srcTexture or ""):lower()
    local mat = tostring(s.material or s.srcMaterial or ""):lower()
    if Rocks.TEXTURES[tex] or Rocks.TEXTURES[mat]
        or tex:find("imped", 1, true) or mat:find("imped", 1, true) then
      shapesSeen = shapesSeen + 1
      local positions, tris = readShape(ground, s, record.posScale or 1)
      if positions then
        local cards = cardsOf(positions, tris)
        if #cards == 0 then leftover = leftover + 1 end
        local rockN, fenceN = 0, 0
        for _, c in ipairs(cards) do
          if isFenceCard(c) then
            fenceN = fenceN + 1
            out.fences = out.fences + 1
          else
            buildRock(b, c[1], c[2], c[3], c[4])
            rockN = rockN + 1
            out.rocks = out.rocks + 1
          end
        end
        -- Hide this native shape only when it was rocks all the way through.
        -- A banner, or a mix, stays on screen so fences are never replaced.
        if rockN > 0 and fenceN == 0 then
          out.shapes[#out.shapes + 1] = s
        end
      end
    end
  end
  if #b.verts > 0 then out.mesh = Voxel3D.newMesh(b.verts, b.map) end
  if Rocks.LOG and shapesSeen > 0 then
    once("land" .. tostring(land),
         "land %s: %d imped shape(s) -> %d rocks, %d fence banner(s) left native (%d shape(s) had no usable cards)",
         tostring(land), shapesSeen, out.rocks, out.fences, leftover)
  end
  return out
end

function Rocks.isBuilt(land)
  local e = land ~= nil and landEntries[land]
  return (e and e.mesh) and true or false
end

local function prepare(ground)
  local view = ground and ground.view3d
  if not (Rocks.enabled and ground and view and ground.grid and ground.terrain
          and ground.slice and ground.chunkPx and ground.half) then
    list = {}
    return
  end
  local grid, px, half = ground.grid, ground.chunkPx, ground.half
  local camCx, camCy = math.floor(view.x / px), math.floor(view.z / px)
  local qx, qy = math.floor(view.x * 4 / px), math.floor(view.z * 4 / px)
  if window.done and window.ground == ground and window.qx == qx and window.qy == qy then
    list = window.list
    return
  end
  tick = tick + 1
  local want = {}
  local W = Rocks.WINDOW
  for cy = camCy - W, camCy + W do
    for cx = camCx - W, camCx + W do
      if cx >= 0 and cy >= 0 and cx < grid.width and cy < grid.height then
        local land = grid.land[cy * grid.width + cx + 1]
        if land then
          local dx, dz = cx - camCx, cy - camCy
          want[#want + 1] = { dx * dx + dz * dz, cx, cy, land }
        end
      end
    end
  end
  table.sort(want, function(a, b) return a[1] < b[1] end)
  local builds, pending, out = 0, 0, {}
  local changed = false
  for _, w in ipairs(want) do
    local land = w[4]
    local entry = landEntries[land]
    if not entry then
      if builds < Rocks.BUILDS_PER_FRAME and Budget.allow(false) then
        builds = builds + 1
        local t0 = clock()
        local ok, built = pcall(buildLand, ground, land)
        Budget.charge(t0, "rocks")
        if not ok then
          once("build", "a land failed to build and was skipped: %s", tostring(built))
          built = { rocks = 0 }
        end
        landEntries[land] = built
        entry = built
        resident = resident + 1
        changed = true
      else
        pending = pending + 1
      end
    end
    if entry then
      entry.used = tick
      if entry.mesh then out[#out + 1] = { entry = entry, x = w[2] * px + half, z = w[3] * px + half } end
    end
  end
  if changed then Rocks.version = Rocks.version + 1 end
  -- evict the oldest lands past the cap
  if resident > Rocks.MAX_RESIDENT then
    local old = {}
    for land, e in pairs(landEntries) do
      if e.used ~= tick then old[#old + 1] = { e.used or 0, land, e } end
    end
    table.sort(old, function(a, b) return a[1] < b[1] end)
    local i = 1
    while resident > Rocks.MAX_RESIDENT and old[i] do
      local e = old[i][3]
      if e.mesh and e.mesh.release then pcall(e.mesh.release, e.mesh) end
      landEntries[old[i][2]] = nil
      resident = resident - 1
      Rocks.version = Rocks.version + 1
      i = i + 1
    end
  end
  list = out
  window.ground, window.qx, window.qy, window.list, window.done = ground, qx, qy, out, (pending == 0)

  local active, sig = {}, {}
  for _, w in ipairs(want) do
    local entry = landEntries[w[4]]
    if entry then
      for _, s in ipairs(entry.shapes or {}) do
        active[s] = true
        sig[#sig + 1] = tostring(s)
      end
    end
  end
  Rocks.active = active
  local coverSig = table.concat(sig, ",")
  if coverSig ~= lastCoverSig then
    lastCoverSig = coverSig
    Rocks.coverVersion = Rocks.coverVersion + 1
  end
end

function Rocks.prepare(ground)
  prepare(ground)
end

function Rocks.isCovered(record)
  return record ~= nil and Rocks.active[record] == true
end

function Rocks.draw(scene)
  if not Rocks.enabled then return end
  local tex = rockTexture()
  if not tex then return end
  prepare(scene.ground)
  if #list == 0 then return end
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  local visible = scene.sphereVisible
  local radius = ((scene.ground and scene.ground.chunkPx) or 512) * 0.72 + 80
  for _, item in ipairs(list) do
    if (not visible) or visible(item.x, 0, item.z, radius) then
      Voxel3D.draw(item.entry.mesh, tex, Mat4.translate(item.x, Rocks.Y_OFFSET or 0, item.z), 0, nil, 0, false)
    end
  end
  Voxel3D.seams(true)
  Voxel3D.glass(true)
end

function Rocks.invalidate()
  for _, e in pairs(landEntries) do
    if e.mesh and e.mesh.release then pcall(e.mesh.release, e.mesh) end
  end
  landEntries = setmetatable({}, { __mode = "k" })
  resident, list, window = 0, {}, {}
  texture = nil
  Rocks.version = Rocks.version + 1
end

return Rocks