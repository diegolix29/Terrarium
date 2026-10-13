-- Gen4Flowers: small voxel flowers standing where Platinum's flower beds are.
--
-- WHICH BEDS
--
-- Gen4Lawn already names the flower-bed terrain texture: `nhana`. This reads
-- the same terrain shapes (ground.terrain.chunks[land].shapes, found by that
-- texture name) the way Gen4Rocks reads `imped`, and plants a flower wherever
-- the shape says one grows. Edit Flowers.TEXTURES / Flowers.PREFIXES to add
-- another bed texture (e.g. Jubilife's `c1_f_ud`).
--
-- A bed can be drawn two ways and both are handled, because the cartridge's
-- geometry was not on hand when this was written (see "NOT VERIFIED"):
--
--   FLAT     the bed is a floor polygon with a flower picture on it. Flowers are
--            scattered over the polygon's area (DENSITY per 16x16 cell), each
--            standing on that triangle's own plane. The floor stays, so Gen4Lawn
--            repaints it with grass.png (see below) and the flowers grow out of it.
--   CARDS    the bed is upright billboards, like the tree and rock cards. Each
--            card becomes a small clump at its foot. Gen4Hide then drops the
--            native card, but ONLY when every triangle of that shape was a card
--            (never leaving a hole, never hiding a floor).
--
-- WHAT A FLOWER IS
--
-- Built from 1-unit voxels (the voxel scene's 8 px tile is 8 of these): a thin
-- stem, two leaves, and a head of a yellow centre with four petals around it.
-- Height, spin, petal colour and centre colour come from a hash of where it
-- stands, so beds look varied but never change between frames.
--
-- WHERE THE COLOURS COME FROM (grass.png)
--
-- Stems and leaves are coloured FROM assets/ground/grass/grass.png: the file is
-- read once, its green texels are sampled and sorted dark to light, and eight of
-- them become the foliage shades of a small generated atlas. So the stalks match
-- the meadow beside them whatever the picture looks like. Petals and centres
-- are the palette below (a grass picture has no flower colours to borrow). If
-- grass.png cannot be read, built-in greens are used and it is logged once.
-- Gen4Lawn also paints the bed's floor with grass.png once flowers exist there.
--
-- WIND
--
-- Flowers sway like the voxel scene's own (Wind.amount * Wind.FLOWER_SHARE).
-- Each mesh is one terrace height, drawn translated up to it, because the wind
-- shader reads a vertex's raw Y as "how far up this plant" (same as Gen4Grass).
--
-- KNOBS: enabled, WINDOW, DENSITY, MAX_PER_LAND, CARD_CLUMP, HEIGHT_MIN/MAX,
-- PETALS, CENTRES, SWAY. Bridge.disabled.flowers turns it off.
--
-- NOT VERIFIED: not run in LOVE + Platinum. The cartridge's nhana geometry (flat
-- polygon vs card) is assumed from the tests below; the log line
-- "Gen4Flowers: land N: ..." says which it found. assets/ is not in the zip, so
-- grass.png's real colours were not seen.

local V = ...
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")

local Flowers = {
  enabled = true,
  TEXTURES = { nhana = true },       -- terrain texture / material names (lower case)
  PREFIXES = { "nhana" },            -- ...and any name starting with one of these
  WINDOW = 2,                        -- lands each way around the camera
  DENSITY = 2.0,                     -- flowers per 16x16 cell of flat bed
  MAX_PER_LAND = 1500,               -- hard cap on one land; density thins to fit
  CARD_CLUMP = 3,                    -- flowers per upright card
  HEIGHT_MIN = 4,                    -- stem height range (world units; a cell is 16)
  HEIGHT_MAX = 7,
  SINK = 0.4,                        -- planted this far into the ground
  SWAY = true,
  BUILDS_PER_FRAME = 3,
  MAX_RESIDENT = 20,
  MAX_VERTS = 60000,                 -- split a mesh before it needs 32-bit indices
  LOG = true,
  DIR = "assets/ground/grass/",
  GRASS_FILE = "grass.png",
  -- 8 petal colours, then 8 centre colours (r, g, b 0..1). Edit freely.
  PETALS = {
    { 0.97, 0.97, 0.95 },            -- white
    { 0.98, 0.62, 0.74 },            -- pink
    { 0.92, 0.22, 0.28 },            -- red
    { 0.99, 0.84, 0.25 },            -- yellow
    { 0.98, 0.58, 0.20 },            -- orange
    { 0.66, 0.42, 0.88 },            -- violet
    { 0.35, 0.55, 0.95 },            -- blue
    { 0.99, 0.80, 0.86 },            -- pale pink
  },
  CENTRES = {
    { 0.98, 0.82, 0.18 }, { 0.95, 0.65, 0.12 }, { 0.62, 0.38, 0.14 }, { 0.99, 0.95, 0.70 },
    { 0.98, 0.82, 0.18 }, { 0.95, 0.65, 0.12 }, { 0.98, 0.82, 0.18 }, { 0.62, 0.38, 0.14 },
  },
  -- used only when grass.png cannot be sampled (dark to light)
  FALLBACK_GREENS = {
    { 0.14, 0.34, 0.12 }, { 0.18, 0.42, 0.15 }, { 0.22, 0.50, 0.18 }, { 0.27, 0.57, 0.21 },
    { 0.33, 0.64, 0.25 }, { 0.40, 0.70, 0.29 }, { 0.48, 0.76, 0.34 }, { 0.58, 0.82, 0.40 },
  },
  version = 0,                       -- bumps whenever the set of built lands changes
  coverVersion = 0,                  -- bumps whenever the set of hidden native shapes changes
}

local FX16 = 4096
local GRID = 8
local ROW_PETAL, ROW_CENTRE, ROW_GREEN = 0, 1, 2
local LIGHT = { 0.35, 0.80, 0.50 }       -- toward the light: up and a little to the front

local warned = {}
local function once(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if V.mod and V.mod.log then V.mod.log:info("Gen4Flowers: " .. fmt:format(...)) end
end

local function optional(name)
  local ok, mod = pcall(V.require, name)
  return ok and mod or nil
end

local Budget = optional("Gen4Budget") or { allow = function() return true end, charge = function() end }
local clock = (love and love.timer and love.timer.getTime) or os.clock

-- ---------------------------------------------------------------- texture --

local function readBytes(file)
  local rel = Flowers.DIR .. file
  local abs = tostring(V.path or "") .. "/" .. rel
  if love and love.filesystem and love.filesystem.read then
    for _, p in ipairs({ rel, abs }) do
      local ok, data = pcall(love.filesystem.read, p)
      if ok and type(data) == "string" and #data > 0 then return data end
    end
  end
  local okA, Assets = pcall(require, "src.render.Assets")
  if okA and Assets and Assets.read then
    for _, p in ipairs({ abs, rel }) do
      local ok, data = pcall(Assets.read, p)
      if ok and type(data) == "string" and #data > 0 then return data end
    end
  end
  if io and io.open then
    local f = io.open(abs, "rb")
    if f then
      local data = f:read("*a")
      f:close()
      if type(data) == "string" and #data > 0 then return data end
    end
  end
  return nil
end

-- Green texels of grass.png, dark to light, as 8 { r, g, b } (or nil).
local function sampleGreens()
  local bytes = readBytes(Flowers.GRASS_FILE)
  if not bytes then return nil, "file not found" end
  if not (love and love.image and love.image.newImageData and love.filesystem
          and love.filesystem.newFileData) then
    return nil, "no image decoder"
  end
  local okD, data = pcall(function()
    return love.image.newImageData(love.filesystem.newFileData(bytes, Flowers.GRASS_FILE))
  end)
  if not (okD and data) then return nil, "could not decode" end
  local w, h = data:getWidth(), data:getHeight()
  local step = 24
  local found = {}
  for iy = 0, step - 1 do
    for ix = 0, step - 1 do
      local x = math.min(w - 1, math.floor((ix + 0.5) * w / step))
      local y = math.min(h - 1, math.floor((iy + 0.5) * h / step))
      local okP, r, g, b, a = pcall(data.getPixel, data, x, y)
      if okP and r and (a or 1) > 0.5 then
        local hi, lo = math.max(r, g, b), math.min(r, g, b)
        -- green: the strongest channel, clearly more than blue, some colour in it
        if g >= r and g >= b and g > 0.2 and (hi - lo) > 0.12 then
          found[#found + 1] = { r, g, b, 0.3 * r + 0.59 * g + 0.11 * b }
        end
      end
    end
  end
  if #found < 3 then return nil, "only " .. #found .. " green texel(s) in it" end
  table.sort(found, function(p, q) return p[4] < q[4] end)
  local out = {}
  for i = 1, GRID do
    local at = math.floor((i - 1) / (GRID - 1) * (#found - 1) + 1.5)
    local p = found[math.max(1, math.min(#found, at))]
    out[i] = { p[1], p[2], p[3] }
  end
  return out
end

local texture                 -- Image | false
local function flowerTexture()
  if texture ~= nil then return texture or nil end
  local ok, img = pcall(function()
    local greens, why = sampleGreens()
    if greens then
      once("greens", "foliage colours sampled from %s%s", Flowers.DIR, Flowers.GRASS_FILE)
    else
      once("greens", "%s%s not usable (%s) -- built-in greens used", Flowers.DIR,
           Flowers.GRASS_FILE, tostring(why))
      greens = Flowers.FALLBACK_GREENS
    end
    local data = love.image.newImageData(GRID, GRID)
    for y = 0, GRID - 1 do
      for x = 0, GRID - 1 do
        local c = greens[1]
        if y == ROW_PETAL then c = Flowers.PETALS[x + 1] or Flowers.PETALS[1]
        elseif y == ROW_CENTRE then c = Flowers.CENTRES[x + 1] or Flowers.CENTRES[1]
        elseif y == ROW_GREEN then c = greens[x + 1] or greens[#greens] end
        data:setPixel(x, y, c[1], c[2], c[3], 1)
      end
    end
    local image = love.graphics.newImage(data)
    image:setFilter("nearest", "nearest")
    return image
  end)
  texture = ok and img or false
  if not texture then once("tex", "could not build the flower atlas: %s", tostring(img)) end
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

-- Pair consecutive upright triangles into cards (as Gen4Rocks does): a pair that
-- shares an edge has four distinct corners. -> { {cx, baseY, cz, planeW, planeH} }
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
      cards[#cards + 1] = { sx / 4, ymin, sz / 4, math.max(xmax - xmin, zmax - zmin),
                            math.max(0.01, ymax - ymin) }
      i = i + 2
    else
      i = i + 1
    end
  end
  return cards
end

-- Is this terrain shape a flower bed?
local function isBedShape(s)
  local tex = tostring(s.texture or s.srcTexture or ""):lower()
  local mat = tostring(s.material or s.srcMaterial or ""):lower()
  if Flowers.TEXTURES[tex] or Flowers.TEXTURES[mat] then return true end
  for _, p in ipairs(Flowers.PREFIXES) do
    if (tex ~= "" and tex:sub(1, #p) == p) or (mat ~= "" and mat:sub(1, #p) == p) then return true end
  end
  return false
end

-- ------------------------------------------------------------------- mesh --

-- 0..1 from three numbers; two rounds of a 32-bit LCG (a*n stays under 2^53).
local function hash(a, b, c)
  local n = math.floor(a * 127.1 + b * 311.7 + (c or 0) * 74.7) % 4294967296
  n = (n * 1664525 + 1013904223) % 4294967296
  n = (n * 1664525 + 1013904223) % 4294967296
  return n / 4294967296
end

local FACE_N = {
  [1] = { 1, 0, 0 }, [2] = { -1, 0, 0 }, [3] = { 0, 1, 0 },
  [5] = { 0, 0, 1 }, [6] = { 0, 0, -1 },
}

-- One bucket = one terrace height = one (or a few) meshes.
local function newBucket(y) return { y = y, verts = {}, map = {}, meshes = {} } end

local function sealBucket(bk)
  if #bk.verts == 0 then return end
  local mesh = Voxel3D.newMesh(bk.verts, bk.map)
  if mesh then bk.meshes[#bk.meshes + 1] = mesh end
  bk.verts, bk.map = {}, {}
end

-- A box of `size` (sx, sy, sz) whose base-centre is at local (lx, ly, lz), turned
-- by yaw (cs, sn) about the flower's origin (fx, fz). `faces` lists the Voxel3D
-- face ids to emit (1 +X, 2 -X, 3 +Y, 5 +Z, 6 -Z; the underside is never drawn).
-- `cell` is the atlas cell every face samples.
local function box(bk, fx, fz, cs, sn, lx, ly, lz, sx, sy, sz, faces, row, col)
  local u, v = cellUV(row, col)
  for _, f in ipairs(faces) do
    local n = FACE_N[f]
    local nx, nz = n[1] * cs - n[3] * sn, n[1] * sn + n[3] * cs
    local lit = math.max(0, nx * LIGHT[1] + n[2] * LIGHT[2] + nz * LIGHT[3])
    local shade = math.min(1.0, 0.55 + 0.5 * lit)
    if n[2] > 0.5 then shade = -shade end            -- faces the sky (snow flag)
    local base = #bk.verts
    local corners = Voxel3D.FACE_CORNERS[f]
    for k = 1, 4 do
      local c = corners[k]
      local px, pz = lx + (c[1] - 0.5) * sx, lz + (c[3] - 0.5) * sz
      bk.verts[base + k] = { fx + px * cs - pz * sn, ly + c[2] * sy, fz + px * sn + pz * cs,
                             u, v, shade, 0 }
    end
    local m = bk.map
    m[#m + 1], m[#m + 2], m[#m + 3] = base + 1, base + 2, base + 3
    m[#m + 1], m[#m + 2], m[#m + 3] = base + 1, base + 3, base + 4
  end
end

local STEM_FACES = { 1, 2, 5, 6 }
local LEAF_L = { 2, 3, 5, 6 }          -- leaf on the -X side: outer end, top, two flanks
local LEAF_R = { 1, 3, 5, 6 }
local HEAD_TOP = { 3 }
local PETAL_PX, PETAL_NX = { 1, 3, 5, 6 }, { 2, 3, 5, 6 }
local PETAL_PZ, PETAL_NZ = { 5, 3, 1, 2 }, { 6, 3, 1, 2 }

-- One flower rooted at (x, ry, z) in its bucket's space (ry is the sub-terrace
-- remainder, so a stem's base is ~0 and the wind reads it as ground level).
local function buildFlower(bk, x, ry, z, seed1, seed2)
  local h = Flowers.HEIGHT_MIN + hash(seed1, seed2, 1) * (Flowers.HEIGHT_MAX - Flowers.HEIGHT_MIN)
  local yaw = hash(seed1, seed2, 2) * 6.2832
  local cs, sn = math.cos(yaw), math.sin(yaw)
  local pCol = math.floor(hash(seed1, seed2, 3) * #Flowers.PETALS) % GRID
  local cCol = math.floor(hash(seed1, seed2, 4) * #Flowers.CENTRES) % GRID
  local stemCol = 1 + math.floor(hash(seed1, seed2, 5) * 4)           -- darker half
  local leafCol = 3 + math.floor(hash(seed1, seed2, 6) * 5)           -- lighter half
  local y0 = ry - Flowers.SINK
  local top = y0 + h
  -- stem (reaches into the head so no gap shows)
  box(bk, x, z, cs, sn, 0, y0, 0, 1.0, h, 1.0, STEM_FACES, ROW_GREEN, stemCol)
  -- two leaves, one a little higher than the other
  box(bk, x, z, cs, sn, -1.1, y0 + h * 0.28, 0, 1.4, 0.7, 0.9, LEAF_L, ROW_GREEN, leafCol)
  box(bk, x, z, cs, sn, 1.1, y0 + h * 0.42, 0, 1.4, 0.7, 0.9, LEAF_R, ROW_GREEN, leafCol)
  -- head: centre a hair proud of four petals
  box(bk, x, z, cs, sn, 0, top - 0.2, 0, 1.6, 1.2, 1.6, HEAD_TOP, ROW_CENTRE, cCol)
  box(bk, x, z, cs, sn, 1.55, top - 0.2, 0, 1.5, 1.0, 1.5, PETAL_PX, ROW_PETAL, pCol)
  box(bk, x, z, cs, sn, -1.55, top - 0.2, 0, 1.5, 1.0, 1.5, PETAL_NX, ROW_PETAL, pCol)
  box(bk, x, z, cs, sn, 0, top - 0.2, 1.55, 1.5, 1.0, 1.5, PETAL_PZ, ROW_PETAL, pCol)
  box(bk, x, z, cs, sn, 0, top - 0.2, -1.55, 1.5, 1.0, 1.5, PETAL_NZ, ROW_PETAL, pCol)
end

-- ------------------------------------------------------------------ lands --

local landEntries = setmetatable({}, { __mode = "k" })   -- land -> entry
local resident = 0
local list = {}
local window = {}
local tick = 0
Flowers.active = {}
local lastCoverSig = ""

local function plant(buckets, order, x, y, z)
  local key = math.floor(y + 0.5)
  local bk = buckets[key]
  if not bk then bk = newBucket(key); buckets[key] = bk; order[#order + 1] = bk end
  buildFlower(bk, x, y - key, z, x, z)
  if #bk.verts > Flowers.MAX_VERTS then sealBucket(bk) end
end

local function buildLand(ground, land)
  local out = { flowers = 0, shapes = {}, buckets = {} }
  local record = ground.terrain.chunks[land]
  if not (record and record.shapes) then return out end
  local posScale = record.posScale or 1
  local buckets, order = {}, {}
  local shapesSeen, flatTris, cardCount = 0, 0, 0

  for _, s in ipairs(record.shapes) do
    if isBedShape(s) then
      shapesSeen = shapesSeen + 1
      local positions, tris = readShape(ground, s, posScale)
      if positions then
        -- split the shape into floor triangles and upright ones
        local flat, upright, area = {}, {}, 0
        for _, t in ipairs(tris) do
          local a, b, c = positions[t[1]], positions[t[2]], positions[t[3]]
          if a and b and c then
            local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
            local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
            local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            local len = math.sqrt(nx * nx + ny * ny + nz * nz)
            if len > 1e-6 then
              -- either winding: only how flat it lies matters
              if math.abs(ny) / len >= 0.6 then
                local ar = len * 0.5
                flat[#flat + 1] = { a, b, c, ar }
                area = area + ar
              else
                upright[#upright + 1] = t
              end
            end
          end
        end
        flatTris = flatTris + #flat

        -- FLAT: scatter over the area, thinned so one land never exceeds the cap
        local cellArea = 256
        local expectedAll = area / cellArea * Flowers.DENSITY
        local scale = expectedAll > Flowers.MAX_PER_LAND and (Flowers.MAX_PER_LAND / expectedAll) or 1
        for _, tri in ipairs(flat) do
          local a, b, c = tri[1], tri[2], tri[3]
          local expected = tri[4] / cellArea * Flowers.DENSITY * scale
          local cx, cz = (a[1] + b[1] + c[1]) / 3, (a[3] + b[3] + c[3]) / 3
          local n = math.floor(expected)
          if hash(cx, cz, 91) < expected - n then n = n + 1 end
          for i = 1, n do
            local r1, r2 = hash(cx, cz, i * 3 + 7), hash(cx, cz, i * 3 + 8)
            if r1 + r2 > 1 then r1, r2 = 1 - r1, 1 - r2 end
            local x = a[1] + r1 * (b[1] - a[1]) + r2 * (c[1] - a[1])
            local y = a[2] + r1 * (b[2] - a[2]) + r2 * (c[2] - a[2])
            local z = a[3] + r1 * (b[3] - a[3]) + r2 * (c[3] - a[3])
            plant(buckets, order, x, y, z)
            out.flowers = out.flowers + 1
          end
        end

        -- CARDS: a small clump at each upright card's foot
        local cards = (#upright > 0) and cardsOf(positions, upright) or {}
        cardCount = cardCount + #cards
        for _, c in ipairs(cards) do
          local reach = math.max(2, math.min(c[4] * 0.5, 10))
          for k = 1, Flowers.CARD_CLUMP do
            local ang = hash(c[1], c[3], k * 2) * 6.2832
            local dist = reach * math.sqrt(hash(c[1], c[3], k * 2 + 1))
            plant(buckets, order, c[1] + math.cos(ang) * dist, c[2], c[3] + math.sin(ang) * dist)
            out.flowers = out.flowers + 1
          end
        end

        -- Hide the native shape only when it was upright cards all the way
        -- through. A floor stays (Gen4Lawn repaints it); a mix stays.
        if #flat == 0 and #cards > 0 then out.shapes[#out.shapes + 1] = s end
      end
    end
  end

  for _, bk in ipairs(order) do
    sealBucket(bk)
    for _, mesh in ipairs(bk.meshes) do out.buckets[#out.buckets + 1] = { mesh = mesh, y = bk.y } end
  end
  if Flowers.LOG and shapesSeen > 0 then
    once("land" .. tostring(land),
         "land %s: %d bed shape(s) -> %d flowers (%d flat triangle(s), %d upright card(s)); %d native shape(s) hidden",
         tostring(land), shapesSeen, out.flowers, flatTris, cardCount, #out.shapes)
  end
  return out
end

-- True once this land's flowers are built AND are being drawn (Gen4Lawn gates its
-- grass.png on it, so a bed is never repainted with no flowers on it: switched
-- off here or through the Bridge, it answers false and the bed keeps its look).
local function switchedOn()
  if not Flowers.enabled then return false end
  local Bridge = optional("Gen4Bridge")
  return not (Bridge and Bridge.disabled and Bridge.disabled.flowers)
end

-- Gen4Lawn keys its cached material swaps on this: it changes when a land is
-- built or evicted AND when the effect is switched on or off, so the grass.png
-- floor comes and goes together with the flowers.
function Flowers.gateKey()
  return tostring(Flowers.version) .. (switchedOn() and "+" or "-")
end

function Flowers.isBuilt(land)
  if not switchedOn() then return false end
  local e = land ~= nil and landEntries[land]
  return (e and #e.buckets > 0) and true or false
end

local function prepare(ground)
  local view = ground and ground.view3d
  if not (Flowers.enabled and ground and view and ground.grid and ground.terrain
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
  local W = Flowers.WINDOW
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
      if builds < Flowers.BUILDS_PER_FRAME and Budget.allow(false) then
        builds = builds + 1
        local t0 = clock()
        local ok, built = pcall(buildLand, ground, land)
        Budget.charge(t0, "flowers")
        if not ok then
          once("build", "a land failed to build and was skipped: %s", tostring(built))
          built = { flowers = 0, shapes = {}, buckets = {} }
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
      if #entry.buckets > 0 then out[#out + 1] = { entry = entry, x = w[2] * px + half, z = w[3] * px + half } end
    end
  end
  if changed then Flowers.version = Flowers.version + 1 end
  -- evict the oldest lands past the cap
  if resident > Flowers.MAX_RESIDENT then
    local old = {}
    for land, e in pairs(landEntries) do
      if e.used ~= tick then old[#old + 1] = { e.used or 0, land, e } end
    end
    table.sort(old, function(a, b) return a[1] < b[1] end)
    local i = 1
    while resident > Flowers.MAX_RESIDENT and old[i] do
      local e = old[i][3]
      for _, b in ipairs(e.buckets or {}) do
        if b.mesh and b.mesh.release then pcall(b.mesh.release, b.mesh) end
      end
      landEntries[old[i][2]] = nil
      resident = resident - 1
      Flowers.version = Flowers.version + 1
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
  Flowers.active = active
  local coverSig = table.concat(sig, ",")
  if coverSig ~= lastCoverSig then
    lastCoverSig = coverSig
    Flowers.coverVersion = Flowers.coverVersion + 1
  end
end

function Flowers.prepare(ground)
  prepare(ground)
end

-- Gen4Hide asks this per native shape: true only where every triangle of an
-- upright-card bed has a voxel flower standing in for it right now.
function Flowers.isCovered(record)
  return record ~= nil and Flowers.active[record] == true
end

function Flowers.draw(scene)
  if not Flowers.enabled then return end
  local tex = flowerTexture()
  if not tex then return end
  prepare(scene.ground)
  if #list == 0 then return end

  local Wind = optional("Wind")
  local sway = 0
  if Flowers.SWAY and Wind and Wind.amount then
    local ok, v = pcall(Wind.amount)
    if ok and tonumber(v) then sway = v * (Wind.FLOWER_SHARE or 0.55) end
  end
  local prevH, prevLoad = Voxel3D.grassH, Voxel3D.grassLoad
  if sway > 0 then
    Voxel3D.grassH = Flowers.HEIGHT_MAX + 2
    local wet, snow, gust = 0, 0, 0
    if Wind and Wind.load then
      local okL, a, b, c = pcall(Wind.load)
      if okL then wet, snow, gust = a or 0, b or 0, c or 0 end
    end
    Voxel3D.grassLoad = { wet, snow, gust }
  end

  Voxel3D.seams(false)
  Voxel3D.glass(false)
  local visible = scene.sphereVisible
  local radius = ((scene.ground and scene.ground.chunkPx) or 512) * 0.72 + 80
  for _, item in ipairs(list) do
    if (not visible) or visible(item.x, 0, item.z, radius) then
      local mats = item.mats
      if not mats then mats = {}; item.mats = mats end
      for i, b in ipairs(item.entry.buckets) do
        local m = mats[i]
        if not m then m = Mat4.translate(item.x, b.y, item.z); mats[i] = m end
        Voxel3D.draw(b.mesh, tex, m, 0, nil, sway, false)
      end
    end
  end
  Voxel3D.seams(true)
  Voxel3D.glass(true)
  Voxel3D.grassH, Voxel3D.grassLoad = prevH, prevLoad
end

function Flowers.invalidate()
  for _, e in pairs(landEntries) do
    for _, b in ipairs(e.buckets or {}) do
      if b.mesh and b.mesh.release then pcall(b.mesh.release, b.mesh) end
    end
  end
  landEntries = setmetatable({}, { __mode = "k" })
  resident, list, window = 0, {}, {}
  Flowers.active = {}
  texture = nil
  Flowers.version = Flowers.version + 1
  Flowers.coverVersion = Flowers.coverVersion + 1
end

return Flowers
