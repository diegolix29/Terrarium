-- Gen4Fence: real 3D fences where Platinum draws its flat fence banners.
--
-- WHAT PLATINUM DRAWS
--
-- Fence runs share the terrain texture `imped` with the route rocks (see
-- Gen4Rocks). A fence is a flat CARD: two triangles, one picture of a fence on
-- them. Two things go wrong with a card:
--   * an east-west run is a card that LEANS back toward the camera, so it reads
--     as a tilted sticker rather than something standing in the world;
--   * a north-south run is a card in the YZ plane. A free camera looks along
--     it, so it is seen edge-on and collapses to a LINE.
--
-- WHAT THIS BUILDS INSTEAD
--
-- For every banner card of an `imped` shape it works out the card's run: the
-- direction it extends along the ground, its two ends, and the ground height
-- at each end. That is read from the card's FOOTPRINT (principal axis of its
-- four corners in x/z), so it does not care whether the card is upright, leaning
-- or lying, nor whether it runs east-west, north-south or on a diagonal. Then
-- it stands a solid fence on that line:
--   STYLE "rail"     posts every POST_SPACING units and two rails between them
--   STYLE "picket"   posts, two rails behind, and a row of pickets in front
-- Every part is a real box with a top and both sides, so the fence has thickness
-- from any angle and a north-south run is as solid as an east-west one.
-- STYLE "iron" (the default) is a metal railing: dark steel posts with caps, two flat
-- bars, and thin vertical bars with finials. "rail" and "picket" are the wooden ones.
--
-- STANDING ON THE GROUND
--
-- A card's lowest corner is not always where the ground is (a card can hover over
-- its tile), so every post is snapped to the real terrain: the land's own floor
-- triangles are read and the post's base is put on the one nearest the card's foot
-- (within SNAP_RANGE; anything further is left alone). Floor triangles come from the
-- same cache record as the cards, so they are in the same space and a land shared
-- by several places on the map stays correct. Y_OFFSET (per direction) is applied
-- after that if a direction still floats or sinks.
-- Runs follow the terrain (each bay is a prism whose base slopes with the card's
-- own foot heights). Adjacent cards share their end post; cards stacked on top of
-- each other (double-sided banners) are built once.
--
-- HIDING THE NATIVE CARD
--
-- Gen4Hide drops a native `imped` shape only when this module has built every
-- card in it (and, for a shape that also holds rocks, only when Gen4Rocks has
-- built that land). Anything this module cannot make sense of stays native, so a
-- fence is never replaced by a hole. See Fence.isCovered.
--
-- KNOBS: Fence.STYLE, HEIGHT, USE_CARD_HEIGHT, POST_W, POST_SPACING, RAIL_*,
-- PICKET_*, SINK, MIN_RUN, MAX_RUN, WINDOW, enabled. Bridge.disabled.fence turns
-- it off; Hide.fences = false brings the native cards back.
--
-- TUNING: with LOG on, each land that has fences writes one line (grep
-- "Gen4Fence:") with how many runs went each way and the card heights/depths it
-- saw. If the fences stand in the wrong place or at the wrong height, that line
-- is what to look at.
--
-- NOT VERIFIED: not run in LOVE + Platinum (no ROM or engine here). Tested with
-- stubs in tools/test_gen4_fence.lua. The card geometry is read generically, but
-- Platinum's real fence cards were not available to measure.

local V = ...
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")

local Fence = {
  enabled = true,
  TEXTURES = { imped = true },     -- terrain texture / material names (lower case): rocks AND fence banners
  PATTERNS = { "fence" },          -- substrings: a shape named like this is ALL fence (every card converts)
  WINDOW = 2,                      -- lands each way around the camera

  STYLE = "iron",                  -- "iron" (metal) | "rail" | "picket" (wood)
  HEIGHT = 12,                     -- fence height in world units (a tile is 16, the trainer 24)
  USE_CARD_HEIGHT = false,         -- true: take each card's own height, clamped to HEIGHT_MIN..HEIGHT_MAX
  HEIGHT_MIN = 8,
  HEIGHT_MAX = 16,
  POST_W = 2.6,                    -- post thickness (square)
  POST_EXTRA = 1.2,                -- posts stand this much above the top rail
  POST_SPACING = 16,               -- longest bay between posts (one tile)
  RAIL_THICK = 1.7,                -- rail height
  RAIL_DEPTH = 1.1,                -- rail thickness across the run
  RAILS = { 0.80, 0.42 },          -- rail centres, as a fraction of HEIGHT
  PICKET_W = 2.0,                  -- picket width along the run
  PICKET_PITCH = 3.6,              -- picket centre to centre
  PICKET_DEPTH = 0.9,
  PICKET_H = 0.94,                 -- picket height, as a fraction of HEIGHT
  SINK = 1.2,                      -- planted this far into the ground
  SNAP_TO_TERRAIN = true,          -- put every post on the land's own floor (see header)
  SNAP_RANGE = 24,                 -- ...if the floor is within this of the card's foot
  Y_OFFSET = { ew = 0, ns = 0, diag = 0 },   -- extra raise (+) / lower (-) per run direction, after the snap
  -- iron style
  IRON_POST_W = 2.0,
  IRON_POST_EXTRA = 0.6,           -- shaft stands this much above HEIGHT, then a cap
  IRON_CAP_W = 3.0,
  IRON_CAP_H = 1.2,
  IRON_RAILS = { 0.90, 0.16 },     -- flat bars: centres as a fraction of HEIGHT
  IRON_RAIL_H = 1.3,
  IRON_RAIL_D = 1.0,
  IRON_BAR_PITCH = 3.0,            -- vertical bars, centre to centre
  IRON_BAR_W = 0.9,
  IRON_BAR_H = 0.96,               -- as a fraction of HEIGHT
  IRON_FINIAL_W = 1.5,
  IRON_FINIAL_H = 1.2,

  MIN_RUN = 3,                     -- a card whose footprint is shorter than this is left native
  MAX_RUN = 192,                   -- ...and so is one longer than this (not a fence)
  SNAP_DEG = 10,                   -- a run within this many degrees of an axis is made exactly axis-aligned
  DEDUPE_DIST = 3.0,               -- two parallel runs closer than this are one fence (double-sided cards)
  POST_MERGE = 1.8,                -- two posts closer than this are one post

  BUILDS_PER_FRAME = 4,
  MAX_RESIDENT = 20,
  MAX_VERTS = 60000,               -- split a mesh before it needs 32-bit indices
  LOG = true,

  -- 8x8 atlas: one row per part, a base colour varied across the 8 columns (+-var)
  PALETTES = {
    wood = {
      var = 0.13,
      post   = { 0.43, 0.29, 0.16 },
      rail   = { 0.58, 0.41, 0.23 },
      picket = { 0.86, 0.81, 0.68 },
      cap    = { 0.31, 0.21, 0.12 },
    },
    iron = {
      var = 0.07,
      post   = { 0.20, 0.22, 0.26 },     -- dark steel posts
      rail   = { 0.30, 0.33, 0.38 },     -- flat bars
      picket = { 0.36, 0.40, 0.46 },     -- vertical bars
      cap    = { 0.58, 0.63, 0.70 },     -- bright caps and finials
    },
  },

  version = 0,                     -- bumps whenever the set of built lands changes
  coverVersion = 0,                -- bumps whenever the set of hidden native shapes changes
  active = {},
}

local GRID = 8
local ROW = { post = 0, rail = 1, picket = 2, cap = 3 }
local FX16 = 4096
local LIGHT = { 0.35, 0.80, 0.50 }       -- toward the light: up and a little to the front
local unpack = table.unpack or unpack

local warned = {}
local function once(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if V.mod and V.mod.log then V.mod.log:info("Gen4Fence: " .. fmt:format(...)) end
end

local function optional(name)
  local ok, mod = pcall(V.require, name)
  return ok and mod or nil
end

local Budget = optional("Gen4Budget") or { allow = function() return true end, charge = function() end }
local clock = (love and love.timer and love.timer.getTime) or os.clock

-- ---------------------------------------------------------------- texture --

local texture                 -- Image | false
local textureFor                 -- the palette name it was built for
local function paletteName()
  return (Fence.STYLE == "iron") and "iron" or "wood"
end
local function fenceTexture()
  if textureFor ~= paletteName() then texture = nil end          -- STYLE changed: rebuild
  if texture ~= nil then return texture or nil end
  textureFor = paletteName()
  local ok, img = pcall(function()
    local pal = Fence.PALETTES[textureFor]
    local data = love.image.newImageData(GRID, GRID)
    for name, row in pairs(ROW) do
      local c = pal[name]
      for x = 0, GRID - 1 do
        local k = (1 - pal.var) + 2 * pal.var * (((x * 5 + row * 3) % 8) / 7)   -- bar-to-bar variation
        data:setPixel(x, row, math.min(c[1] * k, 1), math.min(c[2] * k, 1), math.min(c[3] * k, 1), 1)
      end
    end
    for y = 4, GRID - 1 do                                            -- spare rows
      for x = 0, GRID - 1 do
        local c = pal.rail
        data:setPixel(x, y, c[1], c[2], c[3], 1)
      end
    end
    local image = love.graphics.newImage(data)
    image:setFilter("nearest", "nearest")
    return image
  end)
  texture = ok and img or false
  if not texture then once("tex", "could not build the fence texture: %s", tostring(img)) end
  return texture or nil
end

local function cellUV(row, col)
  return (col + 0.5) / GRID, (row + 0.5) / GRID
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

-- Pair consecutive triangles into cards (as Gen4Rocks does). Each card is
-- { cx, ymin, cz, planeW, planeH, corners = { p1..p4 } } -- the first five fields
-- are exactly what Gen4Rocks' classifier reads. Also returns which triangles
-- were used, so the caller can tell whether anything else (a floor) is left.
local function cardsOf(positions, tris)
  local cards, used = {}, {}
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
      cards[#cards + 1] = { sx / 4, ymin, sz / 4,
                            math.max(xmax - xmin, zmax - zmin), math.max(0.01, ymax - ymin),
                            corners = corners }
      used[i], used[i + 1] = true, true
      i = i + 2
    else
      i = i + 1
    end
  end
  return cards, used
end

-- Same test Gen4Rocks uses (wide OR tall and thin = banner; a rock is square).
-- Taken from Rocks when it exports it, so the two modules can never disagree
-- about which card is whose.
local function isFenceCard(c)
  local Rocks = optional("Gen4Rocks")
  if Rocks and type(Rocks.isFenceCard) == "function" then return Rocks.isFenceCard(c) end
  local w, h = c[4] or 0, math.max(c[5] or 0, 0.01)
  local long, short = w, h
  if h > w then long, short = h, w end
  if long >= 40 then return true end
  return (long / short) >= 1.75
end

-- Is this terrain shape ours? -> nil | "banner" (sort cards into fence / rock) | "all"
local function shapeKind(s)
  local tex = tostring(s.texture or s.srcTexture or ""):lower()
  local mat = tostring(s.material or s.srcMaterial or ""):lower()
  for _, p in ipairs(Fence.PATTERNS) do
    if (tex ~= "" and tex:find(p, 1, true)) or (mat ~= "" and mat:find(p, 1, true)) then return "all" end
  end
  if Fence.TEXTURES[tex] or Fence.TEXTURES[mat] or tex:find("imped", 1, true) or mat:find("imped", 1, true) then
    return "banner"
  end
  return nil
end

-- ------------------------------------------------------------ run reading --

-- A card's run: where its foot line starts and ends, and the ground height at
-- each end. Read from the footprint, so a leaning card, a card edge-on to the
-- camera and a diagonal one all give the right line.
--   -> { ax, az, bx, bz, ya, yb, ux, uz, len, depth, height } | nil
local function runOf(card)
  local pts = card.corners
  if not pts or #pts ~= 4 then return nil end
  local cx, cz = 0, 0
  for _, p in ipairs(pts) do cx, cz = cx + p[1], cz + p[3] end
  cx, cz = cx / 4, cz / 4

  -- principal axis of the footprint
  local sxx, szz, sxz = 0, 0, 0
  for _, p in ipairs(pts) do
    local dx, dz = p[1] - cx, p[3] - cz
    sxx, szz, sxz = sxx + dx * dx, szz + dz * dz, sxz + dx * dz
  end
  local theta = 0.5 * math.atan2(2 * sxz, sxx - szz)
  local ux, uz = math.cos(theta), math.sin(theta)
  -- snap near-axis runs: the cartridge's fences are on the grid
  local snap = math.sin(math.rad(Fence.SNAP_DEG or 0))
  if math.abs(uz) <= snap then ux, uz = (ux >= 0) and 1 or -1, 0
  elseif math.abs(ux) <= snap then ux, uz = 0, (uz >= 0) and 1 or -1 end
  if ux < -1e-9 or (math.abs(ux) <= 1e-9 and uz < 0) then ux, uz = -ux, -uz end   -- canonical direction
  local wx, wz = -uz, ux

  local smin, smax, ymin, ymax = math.huge, -math.huge, math.huge, -math.huge
  local proj = {}
  for i, p in ipairs(pts) do
    local dx, dz = p[1] - cx, p[3] - cz
    local s, t = dx * ux + dz * uz, dx * wx + dz * wz
    proj[i] = { s, t, p[2] }
    smin, smax = math.min(smin, s), math.max(smax, s)
    ymin, ymax = math.min(ymin, p[2]), math.max(ymax, p[2])
  end
  local len = smax - smin
  if len < Fence.MIN_RUN or len > Fence.MAX_RUN then return nil end

  -- the foot at each end: the lowest corner there
  local eps = math.max(0.6, 0.12 * len)
  local lowA, lowB
  for _, q in ipairs(proj) do
    if q[1] - smin <= eps and (not lowA or q[3] < lowA[3]) then lowA = q end
    if smax - q[1] <= eps and (not lowB or q[3] < lowB[3]) then lowB = q end
  end
  local ya, yb, tFoot = ymin, ymin, nil
  if lowA and lowB then
    ya, yb = lowA[3], lowB[3]
    tFoot = (lowA[2] + lowB[2]) * 0.5
  end
  if not tFoot or (ymax - ymin) < 1.5 then          -- lying flat: every corner is a foot
    local sum = 0
    for _, q in ipairs(proj) do sum = sum + q[2] end
    tFoot = sum / 4
  end
  local tmin, tmax = math.huge, -math.huge
  for _, q in ipairs(proj) do tmin, tmax = math.min(tmin, q[2]), math.max(tmax, q[2]) end

  return {
    ax = cx + ux * smin + wx * tFoot, az = cz + uz * smin + wz * tFoot,
    bx = cx + ux * smax + wx * tFoot, bz = cz + uz * smax + wz * tFoot,
    ya = ya, yb = yb, ux = ux, uz = uz, len = len, depth = tmax - tmin,
    height = ymax - ymin,
    axis = (uz == 0 and "ew") or (ux == 0 and "ns") or "diag",
  }
end

-- ------------------------------------------------------------------- mesh --

local function hash(a, b, c)
  local n = math.floor(a * 127.1 + b * 311.7 + (c or 0) * 74.7) % 4294967296
  n = (n * 1664525 + 1013904223) % 4294967296
  n = (n * 1664525 + 1013904223) % 4294967296
  return n / 4294967296
end

local function newBucket() return { verts = {}, map = {}, meshes = {} } end

local function sealBucket(bk)
  if #bk.verts == 0 then return end
  local mesh = Voxel3D.newMesh(bk.verts, bk.map)
  if mesh then bk.meshes[#bk.meshes + 1] = mesh end
  bk.verts, bk.map = {}, {}
end

local function quad(bk, p1, p2, p3, p4, nx, ny, nz, row, col)
  local u, v = cellUV(row, col)
  local lit = math.max(0, nx * LIGHT[1] + ny * LIGHT[2] + nz * LIGHT[3])
  local shade = math.min(1.0, 0.55 + 0.5 * lit)
  if ny > 0.5 then shade = -shade end            -- faces the sky (same flag the voxel trees use)
  local base = #bk.verts
  local v4 = { p1, p2, p3, p4 }
  for k = 1, 4 do
    local p = v4[k]
    bk.verts[base + k] = { p[1], p[2], p[3], u, v, shade, 0 }
  end
  local m = bk.map
  m[#m + 1], m[#m + 2], m[#m + 3] = base + 1, base + 2, base + 3
  m[#m + 1], m[#m + 2], m[#m + 3] = base + 1, base + 3, base + 4
  return 1
end

-- A box laid along a run. Frame: origin (ox, oz), run direction (ux, uz), across
-- direction (-uz, ux). It spans s0..s1 along the run and t0..t1 across it, and
-- stands on a base whose height at s is yAt(s), from `lo` to `hi` above that
-- base. So the same call makes a post (square, ends and all) or a rail on a slope
-- (top and both long sides; its ends sit inside the posts).
-- opts: ends (draw the +-u faces), top (default true)
local function prism(bk, ox, oz, ux, uz, s0, s1, t0, t1, yAt, lo, hi, row, col, ends)
  local wx, wz = -uz, ux
  local y0, y1 = yAt(s0), yAt(s1)
  local function P(s, t, y)
    return { ox + ux * s + wx * t, y, oz + uz * s + wz * t }
  end
  local n = 0
  -- top
  n = n + quad(bk, P(s0, t0, y0 + hi), P(s1, t0, y1 + hi), P(s1, t1, y1 + hi), P(s0, t1, y0 + hi),
               0, 1, 0, row, col)
  -- long sides
  n = n + quad(bk, P(s0, t1, y0 + lo), P(s1, t1, y1 + lo), P(s1, t1, y1 + hi), P(s0, t1, y0 + hi),
               wx, 0, wz, row, col)
  n = n + quad(bk, P(s1, t0, y1 + lo), P(s0, t0, y0 + lo), P(s0, t0, y0 + hi), P(s1, t0, y1 + hi),
               -wx, 0, -wz, row, col)
  if ends then
    n = n + quad(bk, P(s1, t0, y1 + lo), P(s1, t1, y1 + lo), P(s1, t1, y1 + hi), P(s1, t0, y1 + hi),
                 ux, 0, uz, row, col)
    n = n + quad(bk, P(s0, t1, y0 + lo), P(s0, t0, y0 + lo), P(s0, t0, y0 + hi), P(s0, t1, y0 + hi),
                 -ux, 0, -uz, row, col)
  end
  return n
end

-- Ground height under the run at distance s along it. run.ys holds the height at
-- every post (bay boundary); between two posts it is a straight slope.
local function heightAt(run, s)
  local ys, bays = run.ys, run.bays
  if not ys then return run.ya + (run.yb - run.ya) * (s / run.len) end
  local f = math.max(0, math.min(bays, s / run.len * bays))
  local i = math.min(bays - 1, math.floor(f))
  local t = f - i
  return ys[i + 1] + (ys[i + 2] - ys[i + 1]) * t
end

local function postWidth()
  return (Fence.STYLE == "iron") and Fence.IRON_POST_W or Fence.POST_W
end

-- One bay's rails (and pickets) between two posts, s0..s1 along the run.
local function buildBay(bk, run, s0, s1, H, seed)
  local ox, oz, ux, uz = run.ax, run.az, run.ux, run.uz
  local function yAt(s) return heightAt(run, s) end
  local n = 0
  local railCol = math.floor(hash(seed, s0, 11) * GRID) % GRID
  local pw = postWidth()
  local from, to = s0 + pw * 0.5 - 0.2, s1 - pw * 0.5 + 0.2          -- tuck the ends into the posts
  if to <= from then return 0 end

  if Fence.STYLE == "iron" then
    for i, f in ipairs(Fence.IRON_RAILS) do
      local mid = f * H
      n = n + prism(bk, ox, oz, ux, uz, from, to, -Fence.IRON_RAIL_D * 0.5, Fence.IRON_RAIL_D * 0.5, yAt,
                    mid - Fence.IRON_RAIL_H * 0.5, mid + Fence.IRON_RAIL_H * 0.5,
                    ROW.rail, (railCol + i * 2) % GRID, false)
    end
    local span = to - from
    local count = math.max(1, math.floor(span / Fence.IRON_BAR_PITCH + 0.5))
    local pitch = span / count
    local bw, fw = Fence.IRON_BAR_W, Fence.IRON_FINIAL_W
    local top = H * Fence.IRON_BAR_H
    for k = 0, count - 1 do
      local c = from + (k + 0.5) * pitch
      local col = math.floor(hash(seed + k, c, 5) * GRID) % GRID
      n = n + prism(bk, ox, oz, ux, uz, c - bw * 0.5, c + bw * 0.5, -bw * 0.5, bw * 0.5, yAt,
                    -Fence.SINK, top, ROW.picket, col, true)
      n = n + prism(bk, ox, oz, ux, uz, c - fw * 0.5, c + fw * 0.5, -fw * 0.5, fw * 0.5, yAt,
                    top, top + Fence.IRON_FINIAL_H, ROW.cap, col, true)
    end
  elseif Fence.STYLE == "picket" then
    -- rails sit behind the pickets
    for i, f in ipairs(Fence.RAILS) do
      local mid = f * H
      n = n + prism(bk, ox, oz, ux, uz, from, to, -Fence.RAIL_DEPTH - 0.1, -0.1, yAt,
                    mid - Fence.RAIL_THICK * 0.5, mid + Fence.RAIL_THICK * 0.5,
                    ROW.rail, (railCol + i) % GRID, false)
    end
    local span = to - from
    local count = math.max(1, math.floor(span / Fence.PICKET_PITCH + 0.5))
    local pitch = span / count
    for k = 0, count - 1 do
      local c = from + (k + 0.5) * pitch
      local h = H * Fence.PICKET_H
      local col = math.floor(hash(seed + k, c, 5) * GRID) % GRID
      n = n + prism(bk, ox, oz, ux, uz, c - Fence.PICKET_W * 0.5, c + Fence.PICKET_W * 0.5,
                    0, Fence.PICKET_DEPTH, yAt, -Fence.SINK, h, ROW.picket, col, true)
    end
  else
    for i, f in ipairs(Fence.RAILS) do
      local mid = f * H
      n = n + prism(bk, ox, oz, ux, uz, from, to, -Fence.RAIL_DEPTH * 0.5, Fence.RAIL_DEPTH * 0.5, yAt,
                    mid - Fence.RAIL_THICK * 0.5, mid + Fence.RAIL_THICK * 0.5,
                    ROW.rail, (railCol + i * 2) % GRID, false)
    end
  end
  return n
end

local function buildPost(bk, run, s, H, seed)
  local function yAt(x) return heightAt(run, x) end
  local half = postWidth() * 0.5
  local col = math.floor(hash(seed, s, 3) * GRID) % GRID
  -- a square post centred on the foot line at s
  if Fence.STYLE == "iron" then
    local h = H + Fence.IRON_POST_EXTRA
    local n = prism(bk, run.ax, run.az, run.ux, run.uz, s - half, s + half, -half, half, yAt,
                    -Fence.SINK, h, ROW.post, col, true)
    local ch = Fence.IRON_CAP_W * 0.5
    return n + prism(bk, run.ax, run.az, run.ux, run.uz, s - ch, s + ch, -ch, ch, yAt,
                     h, h + Fence.IRON_CAP_H, ROW.cap, col, true)
  end
  return prism(bk, run.ax, run.az, run.ux, run.uz, s - half, s + half, -half, half, yAt,
               -Fence.SINK, H + Fence.POST_EXTRA, ROW.post, col, true)
end

-- ------------------------------------------------------------------ lands --

local landEntries = setmetatable({}, { __mode = "k" })   -- land -> { meshes, shapes, ... }
local resident = 0
local list = {}
local window = {}
local tick = 0
local lastCoverSig = ""

-- Changes whenever Gen4Rocks builds/evicts a land or is switched on or off, so the
-- hidden set is re-decided for shapes that hold fences AND rocks.
local function rocksVersion()
  local R = optional("Gen4Rocks")
  if not R then return "none" end
  local Bridge = optional("Gen4Bridge")
  local off = (not R.enabled) or (Bridge and Bridge.disabled and Bridge.disabled.rocks)
  return tostring(R.version or 0) .. (off and "-" or "+")
end

-- Is Gen4Rocks drawing its boulders for this land right now? A shape that holds
-- fences AND rocks is only hidden then, or the rocks would vanish with it.
local function rocksDrawing(land)
  local R = optional("Gen4Rocks")
  if not (R and R.enabled and type(R.isBuilt) == "function") then return false end
  local Bridge = optional("Gen4Bridge")
  if Bridge and Bridge.disabled and Bridge.disabled.rocks then return false end
  return R.isBuilt(land) and true or false
end

-- Spatial hash of what a land has already built, so posts shared by two cards and
-- cards drawn twice are made once.
local function newLedger(ground, record, posScale)
  return { posts = {}, runs = {}, cell = 24, ground = ground, record = record, posScale = posScale,
           snapped = 0, snapSum = 0, points = 0 }
end

-- ---------------------------------------------------------- terrain floor --

-- Shapes that are not ground: the cards themselves, water, shadows, glass, cloud.
local NOT_GROUND = { "imped", "fence", "shadow", "kage", "water", "sea", "lake", "wtr", "mizu",
                     "cloud", "kumo", "glass", "garasu", "fall", "puddle" }

-- The land's up-facing triangles in a coarse grid, for "what is the ground height
-- at (x, z)". Built once per land that has a fence in it.
local function makeSampler(ground, record, posScale)
  local CELL = 16
  local cells, big = {}, {}
  for _, s in ipairs(record.shapes) do
    local tex = tostring(s.texture or s.srcTexture or ""):lower()
    local mat = tostring(s.material or s.srcMaterial or ""):lower()
    local skip = (s.index == nil and type(s.name) == "string" and s.name:sub(-5) == "Cards")
    for _, n in ipairs(NOT_GROUND) do
      if tex:find(n, 1, true) or mat:find(n, 1, true) then skip = true; break end
    end
    if not skip then
      local ok, positions, tris = pcall(readShape, ground, s, posScale)
      if ok and positions then
        for _, t in ipairs(tris) do
          local a, b, c = positions[t[1]], positions[t[2]], positions[t[3]]
          if a and b and c then
            local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
            local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
            local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            local len = math.sqrt(nx * nx + ny * ny + nz * nz)
            if len > 1e-6 and math.abs(ny) / len >= 0.8 then
              local tri = { a[1], a[3], a[2], b[1], b[3], b[2], c[1], c[3], c[2] }
              local x0 = math.floor(math.min(a[1], b[1], c[1]) / CELL)
              local x1 = math.floor(math.max(a[1], b[1], c[1]) / CELL)
              local z0 = math.floor(math.min(a[3], b[3], c[3]) / CELL)
              local z1 = math.floor(math.max(a[3], b[3], c[3]) / CELL)
              if (x1 - x0 + 1) * (z1 - z0 + 1) > 64 then
                big[#big + 1] = tri
              else
                for cx = x0, x1 do
                  for cz = z0, z1 do
                    local key = cx .. "," .. cz
                    local bucket = cells[key]
                    if not bucket then bucket = {}; cells[key] = bucket end
                    bucket[#bucket + 1] = tri
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  -- height of the floor under (x, z) nearest `ref`, or nil
  return function(x, z, ref)
    local best, bestD
    local function try(t)
      local x1, z1, x2, z2, x3, z3 = t[1], t[2], t[4], t[5], t[7], t[8]
      local det = (z2 - z3) * (x1 - x3) + (x3 - x2) * (z1 - z3)
      if math.abs(det) < 1e-9 then return end
      local l1 = ((z2 - z3) * (x - x3) + (x3 - x2) * (z - z3)) / det
      local l2 = ((z3 - z1) * (x - x3) + (x1 - x3) * (z - z3)) / det
      local l3 = 1 - l1 - l2
      if l1 >= -0.02 and l2 >= -0.02 and l3 >= -0.02 then
        local y = l1 * t[3] + l2 * t[6] + l3 * t[9]
        local d = math.abs(y - ref)
        if not bestD or d < bestD then best, bestD = y, d end
      end
    end
    local bucket = cells[math.floor(x / CELL) .. "," .. math.floor(z / CELL)]
    if bucket then for _, t in ipairs(bucket) do try(t) end end
    for _, t in ipairs(big) do try(t) end
    if best and bestD <= Fence.SNAP_RANGE then return best end
    return nil
  end
end

local function cellOf(ledger, x, z)
  return math.floor(x / ledger.cell), math.floor(z / ledger.cell)
end

local function addToLedger(ledger, kind, x, z, item)
  local cx, cz = cellOf(ledger, x, z)
  local key = cx .. "," .. cz
  local bucket = ledger[kind][key]
  if not bucket then bucket = {}; ledger[kind][key] = bucket end
  bucket[#bucket + 1] = item
end

local function nearby(ledger, kind, x, z)
  local cx, cz = cellOf(ledger, x, z)
  local out = {}
  for dx = -1, 1 do
    for dz = -1, 1 do
      local bucket = ledger[kind][(cx + dx) .. "," .. (cz + dz)]
      if bucket then for _, it in ipairs(bucket) do out[#out + 1] = it end end
    end
  end
  return out
end

-- Has an (almost) identical run already been built?
local function isDuplicate(ledger, run)
  local mx, mz = (run.ax + run.bx) * 0.5, (run.az + run.bz) * 0.5
  for _, r in ipairs(nearby(ledger, "runs", mx, mz)) do
    if math.abs(r.ux * run.ux + r.uz * run.uz) > 0.985 then
      local wx, wz = -r.uz, r.ux
      local off = math.abs((run.ax - r.ax) * wx + (run.az - r.az) * wz)
      local off2 = math.abs((run.bx - r.ax) * wx + (run.bz - r.az) * wz)
      if off <= Fence.DEDUPE_DIST and off2 <= Fence.DEDUPE_DIST then
        local a = (run.ax - r.ax) * r.ux + (run.az - r.az) * r.uz
        local b = (run.bx - r.ax) * r.ux + (run.bz - r.az) * r.uz
        local lo, hi = math.min(a, b), math.max(a, b)
        local overlap = math.min(hi, r.len) - math.max(lo, 0)
        if overlap >= 0.8 * math.min(run.len, r.len) then return true end
      end
    end
  end
  return false
end

local function postExists(ledger, x, z)
  for _, p in ipairs(nearby(ledger, "posts", x, z)) do
    local dx, dz = p[1] - x, p[2] - z
    if dx * dx + dz * dz < Fence.POST_MERGE * Fence.POST_MERGE then return true end
  end
  return false
end

-- Build one run into the bucket. Returns the number of quads made.
local function buildRun(bk, ledger, run)
  local H = Fence.HEIGHT
  if Fence.USE_CARD_HEIGHT and run.height >= Fence.HEIGHT_MIN then
    H = math.max(Fence.HEIGHT_MIN, math.min(Fence.HEIGHT_MAX, run.height))
  end
  local bays = math.max(1, math.ceil(run.len / Fence.POST_SPACING - 0.001))
  local seed = run.ax * 0.37 + run.az * 1.31
  local quads = 0
  -- ground height at every post: the card's own foot, snapped onto the land's floor
  if Fence.SNAP_TO_TERRAIN and ledger.sampler == nil then
    local ok, sm = pcall(makeSampler, ledger.ground, ledger.record, ledger.posScale)
    ledger.sampler = ok and sm or false
  end
  local sample = ledger.sampler
  local shift = (Fence.Y_OFFSET and Fence.Y_OFFSET[run.axis]) or 0
  run.bays, run.ys = bays, {}
  for i = 0, bays do
    local s = run.len * i / bays
    local foot = run.ya + (run.yb - run.ya) * (i / bays)
    local y = foot
    ledger.points = ledger.points + 1
    if sample then
      local g = sample(run.ax + run.ux * s, run.az + run.uz * s, foot)
      if g then
        y = g
        ledger.snapped = ledger.snapped + 1
        ledger.snapSum = ledger.snapSum + (g - foot)
      end
    end
    run.ys[i + 1] = y + shift
  end
  for i = 0, bays do
    local s = run.len * i / bays
    local x, z = run.ax + run.ux * s, run.az + run.uz * s
    if not postExists(ledger, x, z) then
      addToLedger(ledger, "posts", x, z, { x, z })
      quads = quads + buildPost(bk, run, s, H, seed + i)
    end
  end
  for i = 0, bays - 1 do
    quads = quads + buildBay(bk, run, run.len * i / bays, run.len * (i + 1) / bays, H, seed + i * 0.5)
  end
  return quads
end

local function buildLand(ground, land)
  local out = { runs = 0, quads = 0, shapes = {}, meshes = {} }
  local record = ground.terrain.chunks[land]
  if not (record and record.shapes) then return out end
  local posScale = record.posScale or 1
  local bk = newBucket()
  local ledger = newLedger(ground, record, posScale)
  local seen, ew, ns, diag, dupes, skipped = 0, 0, 0, 0, 0, 0
  local hMin, hMax, dMax = math.huge, 0, 0

  for _, s in ipairs(record.shapes) do
    local kind = shapeKind(s)
    if kind then
      seen = seen + 1
      local positions, tris = readShape(ground, s, posScale)
      if positions then
        local cards, used = cardsOf(positions, tris)
        local fenceN, rockN, skipN = 0, 0, 0
        for _, c in ipairs(cards) do
          if kind == "all" or isFenceCard(c) then
            local run = runOf(c)
            if run then
              fenceN = fenceN + 1
              if isDuplicate(ledger, run) then
                dupes = dupes + 1
              else
                addToLedger(ledger, "runs", (run.ax + run.bx) * 0.5, (run.az + run.bz) * 0.5, run)
                out.quads = out.quads + buildRun(bk, ledger, run)
                out.runs = out.runs + 1
                if run.axis == "ew" then ew = ew + 1 elseif run.axis == "ns" then ns = ns + 1 else diag = diag + 1 end
                hMin, hMax, dMax = math.min(hMin, run.height), math.max(hMax, run.height), math.max(dMax, run.depth)
                if #bk.verts > Fence.MAX_VERTS then sealBucket(bk) end
              end
            else
              skipN = skipN + 1
            end
          else
            rockN = rockN + 1
          end
        end
        skipped = skipped + skipN
        -- A floor triangle left over would vanish with the shape.
        local floorLeft = 0
        for i, t in ipairs(tris) do
          if not used[i] then
            local a, b, c = positions[t[1]], positions[t[2]], positions[t[3]]
            if a and b and c then
              local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
              local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
              local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
              local len = math.sqrt(nx * nx + ny * ny + nz * nz)
              if len > 1e-6 and math.abs(ny) / len >= 0.6 then floorLeft = floorLeft + 1 end
            end
          end
        end
        -- Hide the native shape only when every card in it has a stand-in.
        if fenceN > 0 and skipN == 0 and floorLeft == 0 then
          out.shapes[#out.shapes + 1] = { record = s, needRocks = rockN > 0 }
        end
      end
    end
  end

  sealBucket(bk)
  out.meshes = bk.meshes
  if Fence.LOG and seen > 0 then
    once("land" .. tostring(land),
         "land %s: %d imped shape(s) -> %d fence run(s) (%d east-west, %d north-south, %d diagonal), %d duplicate card(s) merged, %d card(s) left native; card height %.1f..%.1f, depth up to %.1f; terrain snap %d/%d post(s), moved %.1f on average; %d native shape(s) hidden",
         tostring(land), seen, out.runs, ew, ns, diag, dupes, skipped,
         hMin == math.huge and 0 or hMin, hMax, dMax,
         ledger.snapped, ledger.points, ledger.snapped > 0 and ledger.snapSum / ledger.snapped or 0,
         #out.shapes)
  end
  return out
end

local function switchedOn()
  if not Fence.enabled then return false end
  local Bridge = optional("Gen4Bridge")
  return not (Bridge and Bridge.disabled and Bridge.disabled.fence)
end

function Fence.isBuilt(land)
  if not switchedOn() then return false end
  local e = land ~= nil and landEntries[land]
  return (e and #e.meshes > 0) and true or false
end

local function prepare(ground)
  local view = ground and ground.view3d
  if not (Fence.enabled and ground and view and ground.grid and ground.terrain
          and ground.slice and ground.chunkPx and ground.half) then
    list = {}
    return
  end
  local grid, px, half = ground.grid, ground.chunkPx, ground.half
  local camCx, camCy = math.floor(view.x / px), math.floor(view.z / px)
  local qx, qy = math.floor(view.x * 4 / px), math.floor(view.z * 4 / px)
  local rv = rocksVersion()
  if window.done and window.ground == ground and window.qx == qx and window.qy == qy and window.rv == rv then
    list = window.list
    return
  end
  tick = tick + 1
  local want = {}
  local W = Fence.WINDOW
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
      if builds < Fence.BUILDS_PER_FRAME and Budget.allow(false) then
        builds = builds + 1
        local t0 = clock()
        local ok, built = pcall(buildLand, ground, land)
        Budget.charge(t0, "fence")
        if not ok then
          once("build", "a land failed to build and was skipped: %s", tostring(built))
          built = { runs = 0, quads = 0, shapes = {}, meshes = {} }
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
      if #entry.meshes > 0 then out[#out + 1] = { entry = entry, x = w[2] * px + half, z = w[3] * px + half } end
    end
  end
  if changed then Fence.version = Fence.version + 1 end
  -- evict the oldest lands past the cap
  if resident > Fence.MAX_RESIDENT then
    local old = {}
    for land, e in pairs(landEntries) do
      if e.used ~= tick then old[#old + 1] = { e.used or 0, land, e } end
    end
    table.sort(old, function(a, b) return a[1] < b[1] end)
    local i = 1
    while resident > Fence.MAX_RESIDENT and old[i] do
      local e = old[i][3]
      for _, m in ipairs(e.meshes or {}) do
        if m.release then pcall(m.release, m) end
      end
      landEntries[old[i][2]] = nil
      resident = resident - 1
      Fence.version = Fence.version + 1
      i = i + 1
    end
  end
  list = out
  window.ground, window.qx, window.qy, window.list, window.rv =
    ground, qx, qy, out, rv
  window.done = (pending == 0)

  -- which native shapes are stood in for right now
  local active, sig = {}, {}
  for _, w in ipairs(want) do
    local entry = landEntries[w[4]]
    if entry then
      for _, sh in ipairs(entry.shapes or {}) do
        if (not sh.needRocks) or rocksDrawing(w[4]) then
          active[sh.record] = true
          sig[#sig + 1] = tostring(sh.record)
        end
      end
    end
  end
  Fence.active = active
  local coverSig = table.concat(sig, ",")
  if coverSig ~= lastCoverSig then
    lastCoverSig = coverSig
    Fence.coverVersion = Fence.coverVersion + 1
  end
end

function Fence.prepare(ground)
  prepare(ground)
end

-- Gen4Hide asks this per native shape: true only where every card of the shape
-- has a 3D fence (or a boulder) standing in for it right now.
function Fence.isCovered(record)
  return record ~= nil and switchedOn() and Fence.active[record] == true
end

function Fence.draw(scene)
  if not Fence.enabled then return end
  local tex = fenceTexture()
  if not tex then return end
  prepare(scene.ground)
  if #list == 0 then return end
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  local visible = scene.sphereVisible
  local radius = ((scene.ground and scene.ground.chunkPx) or 512) * 0.72 + 80
  for _, item in ipairs(list) do
    if (not visible) or visible(item.x, 0, item.z, radius) then
      local model = item.model
      if not model then model = Mat4.translate(item.x, 0, item.z); item.model = model end
      for _, mesh in ipairs(item.entry.meshes) do
        Voxel3D.draw(mesh, tex, model, 0, nil, 0, false)
      end
    end
  end
  Voxel3D.seams(true)
  Voxel3D.glass(true)
end

function Fence.invalidate()
  for _, e in pairs(landEntries) do
    for _, m in ipairs(e.meshes or {}) do
      if m.release then pcall(m.release, m) end
    end
  end
  landEntries = setmetatable({}, { __mode = "k" })
  resident, list, window = 0, {}, {}
  Fence.active = {}
  texture = nil
  lastCoverSig = ""
  Fence.version = Fence.version + 1
  Fence.coverVersion = Fence.coverVersion + 1
end

return Fence