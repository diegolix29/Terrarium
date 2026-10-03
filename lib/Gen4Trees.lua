-- Gen4Trees: the voxel scene's round trees, standing in Gen 4's world.
--
-- WHAT PLATINUM DRAWS
--
-- A Sinnoh tree is a FLAT CARD: a 4-vertex quad leaning back toward the
-- cartridge's camera (normal (0, 0.819, 0.575)), many per terrain shape
-- (`tree01`, `tree2_01`, `tree04_2`, `tree3_02`, `bf_tree03`) plus the
-- `conttree*` forest-border strips (one wide card = several trees tiled).
--
-- WHAT THIS BUILDS INSTEAD: THE VOXEL SCENE'S OWN TREE
--
-- The same recipe Structures.roundTemplate uses for the Gen 1-3 trees:
--   * the card's art is cut into blocks (one block = TEX_STEP texels);
--   * each ROW is a DISC: the row's opaque span gives a centre and a
--     half-width, and every column of that row runs the circle's CHORD in z,
--     quantised to whole blocks -- so the front view IS the sprite and the
--     plan view is the sprite's own width profile turned in depth. Canopy
--     rows bulge round, trunk rows stay slim;
--   * front and back faces carry the art per block (runs of one colour are one
--     quad); side / step / underside faces take their own column's texel, so
--     the drawn outline sits on the silhouette's rim;
--   * a fully exposed cap keeps the outline only on its rim blocks and wears
--     the canopy a couple of rows deeper inside -- the dome, not a stripe;
--   * the same face shades (front 1.0, back .68, side .78, top 1.0, bottom
--     .55) so a Gen 4 tree is lit like a Gen 1-3 one.
-- Round in plan means it reads the same from every orbit angle.
--
-- BORDER TREES (`conttree*`)
--
-- A strip is split on each texture repeat and every repeat becomes its own
-- tree, so the border matches the trees inside the map. A sprite window that
-- is (nearly) all opaque has no outline to follow, so it is rounded to an
-- ellipse instead of being built as a slab (GT.DENSE_FRACTION).
--
-- WHEN A NATIVE CARD IS HIDDEN (Gen4Hide)
--
-- Per cache shape, by record, and only while this module has trees for it.
-- When a built shape lost its record pointer, Gen4Hide falls back to
-- isCoveredName: texture/material names only, and only names that converted
-- in every land of the window, so a name is never hidden where it was not built.
--
-- COST: baked ONCE PER LAND CHUNK, one mesh per texture. The first fill of a
-- window uses a bigger frame budget (WARM_BUDGET) so the whole window is
-- voxel trees within a moment, not a trickle of pop-in.
--
-- KNOBS: GT.enabled, GT.WINDOW, GT.TEX_STEP, GT.MAX_QUADS, GT.WARM_BUDGET.
-- Bridge.disabled.trees turns the effect off.

local V = ...
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")

local GT = {
  enabled = true,
  WINDOW = 2,             -- chunks each way (same window as Gen4Ground / water)
  TEX_STEP = 2,           -- texels per block edge (1 = full resolution, 4x the quads)
  MAX_BLOCKS = 40,        -- most blocks across one card, whatever the step says
  MIN_HALF = 1,           -- a column's chord is never thinner than this many blocks each side
  MAX_HALF = 9,           -- a tree is never deeper than 2x this many world units, however wide its run
  TREE_UNIT = 33,         -- width of one tree on a card (an ordinary Sinnoh tree card): wider cards are split into this many trees
  MAX_TREE_H = 220,       -- a card taller than this is not a tree
  MIN_TREE_H = 0.5,       -- ...nor one flatter than this (a ground quad)
  Y_OFFSET = -10,          -- the WHOLE tree layer is moved this far along y when drawn (negative = down). The quick fix for floating trees
  SINK = 1.5,             -- planted this far below the card's base (world units; a tile is 16)
  PAD_SINK = true,        -- also sink by the transparent rows at the foot of the art, so the trunk (not the empty padding) meets the ground
  MAX_PAD_FRAC = 0.35,    -- ...but never by more than this fraction of the tree's height
  MAX_QUADS = 450000,     -- stop covering shapes in a land past this many quads (walkable trees go first, then the border)
  BUILDS_PER_FRAME = 4,
  BUILD_BUDGET = 0.006,   -- seconds, steady state
  WARM_BUDGET = 0.04,     -- seconds per frame while the window is still filling
  DENSE_FRACTION = 0.92,  -- a sprite window this opaque has no silhouette to follow (no real alpha, or a wall tile): it is rounded, never built as a slab
  LOG = true,
  coverVersion = 0,       -- bumps whenever the set of covered shapes changes
  active = {},            -- cache shape record -> true (covered AND in the window)
  coveredNames = {},      -- texture/material names that converted in EVERY land of the window (Gen4Hide's fallback when a shape has no cache pointer)
}

-- the cartridge's tree lean, the same constants Gen4Model classifies by
local TREE_NY, TREE_NZ, TREE_TOL = 0.819, 0.575, 0.04
local STRIP_REPEATS = 1.25
local FX16, UV_UNITS = 4096, 16

local warned = {}
local function once(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if V.mod and V.mod.log then V.mod.log:info("Gen4Trees: " .. fmt:format(...)) end
end

local function optional(name)
  local ok, mod = pcall(V.require, name)
  return ok and mod or nil
end

local cache = setmetatable({}, { __mode = "k" })   -- ground -> { lands = {} }

-- ----------------------------------------------------------- decoding --

local function s16(data, at)
  local a, b = data:byte(at + 1, at + 2)
  if not b then return 0 end
  local value = a + b * 256
  if value >= 32768 then value = value - 65536 end
  return value
end

-- A shape's vertices { x, y, z, u, v } (u, v in TEXELS) and triangles, read the
-- way Gen4Model.new reads them. Stride is measured off the buffer.
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
  -- Vertex layout (both the 14- and 16-byte strides, see Gen4Model.new):
  -- pos s16 x3 at +0, u s16 at +6, v s16 at +8, colour at +10, normal at +13.
  -- The UV is ALWAYS at +6 / +8. It was read from the end of the vertex
  -- (stride - 4) before, which landed on the normal bytes, so every vertex had
  -- the same "UV" and every sprite sampled ONE texel -- a solid green block.
  local uvAt = 6
  local pos = {}
  for i = 1, count do
    local at = (i - 1) * stride
    pos[i] = {
      s16(vdata, at) / FX16 * posScale,
      s16(vdata, at + 2) / FX16 * posScale,
      s16(vdata, at + 4) / FX16 * posScale,
      s16(vdata, at + uvAt) / UV_UNITS,
      s16(vdata, at + uvAt + 2) / UV_UNITS,
    }
  end
  local triList = {}
  for t = 0, tris - 1 do
    local a1, a2, b1, b2, c1, c2 = idata:byte(t * 6 + 1, t * 6 + 6)
    if not c2 then break end
    triList[#triList + 1] = { a1 + a2 * 256 + 1, b1 + b2 * 256 + 1, c1 + c2 * 256 + 1 }
  end
  return pos, triList
end

-- Is this triangle one half of a tree card? The cartridge lean is
-- (0, 0.819, 0.575) toward the default camera, but trees also face east/west
-- and some caches store an upright billboard. Match any yaw of that lean, or
-- a nearly-vertical card.
local function isCardTri(pa, pb, pc)
  local ux, uy, uz = pb[1] - pa[1], pb[2] - pa[2], pb[3] - pa[3]
  local vx, vy, vz = pc[1] - pa[1], pc[2] - pa[2], pc[3] - pa[3]
  local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
  local len = math.sqrt(nx * nx + ny * ny + nz * nz)
  if len < 1e-6 then return false end
  nx, ny, nz = nx / len, ny / len, nz / len
  if ny < 0 then nx, ny, nz = -nx, -ny, -nz end
  local horiz = math.sqrt(nx * nx + nz * nz)
  return math.abs(ny - TREE_NY) < TREE_TOL and math.abs(horiz - TREE_NZ) < TREE_TOL
end

local TREE_SUB = { "tree", "palm", "yashi", "matsu", "sugi" }

local function namesOf(s)
  return (tostring(s.texture or "") .. "\n" .. tostring(s.material or "")
          .. "\n" .. tostring(s.name or "")):lower()
end

-- The names a covered shape may be hidden by when its cache-record pointer is
-- missing: texture and material only. The shape's own name ("polygon8") is
-- NOT one -- it is reused by unrelated shapes in other lands.
local function nameKeys(s)
  local out = {}
  -- explicit fields, NOT ipairs over a table literal: ipairs stops at the first
  -- nil, and a cache record has no srcTexture (so nothing was ever registered)
  local fields = { s.srcTexture, s.texture, s.srcMaterial, s.material }
  for i = 1, 4 do
    local k = tostring(fields[i] or ""):lower()
    if k ~= "" and k ~= "nil" then out[#out + 1] = k end
  end
  return out
end

function GT.isTreeName(s)
  local n = namesOf(s):gsub("street", "")
  -- conttree IS a tree: the void-fill border, same sprite, tiled
  for _, sub in ipairs(TREE_SUB) do
    if n:find(sub, 1, true) then return true end
  end
  return false
end

-- Pair triangles into 4-corner cards. NSBMD tree quads often duplicate
-- vertices, so the two halves do not share indices -- matching only on
-- index would leave every tree native. Union-find on shared vertices would
-- glue neighbouring trees into one blob. Consecutive tris (the usual export
-- order) plus unique XYZ is the pairing that actually finds a card.
local function posKey(p)
  return string.format("%.3f:%.3f:%.3f", p[1], p[2], p[3])
end

local function uniquePosList(positions, a, b)
  local seen, list = {}, {}
  local function add(i)
    local p = positions[i]
    if not p then return end
    local k = posKey(p)
    if not seen[k] then seen[k] = i; list[#list + 1] = i end
  end
  for k = 1, 3 do add(a[k]) end
  for k = 1, 3 do add(b[k]) end
  return list
end

local function uvSpanU(positions, verts)
  local lo, hi = math.huge, -math.huge
  for _, i in ipairs(verts) do
    local u = positions[i][4]
    if u < lo then lo = u end
    if u > hi then hi = u end
  end
  return hi - lo
end

local function acceptCard(positions, verts, maxUvW)
  if #verts ~= 4 then return false end
  return not maxUvW or uvSpanU(positions, verts) <= maxUvW
end

local function cardsFromTris(positions, tris, maxUvW, leanOnly)
  local used, cards = {}, {}
  -- a triangle that is not itself a tree card (ground, wall, roof) is never
  -- paired: two ground triangles share an edge and would pass as a "card"
  local isCard = {}
  for i, t in ipairs(tris) do
    local pa, pb, pc = positions[t[1]], positions[t[2]], positions[t[3]]
    if not leanOnly or (pa and pb and pc and isCardTri(pa, pb, pc)) then isCard[i] = true else used[i] = 'x' end
  end
  for i = 1, #tris - 1, 2 do
    local verts = uniquePosList(positions, tris[i], tris[i + 1])
    if isCard[i] and isCard[i + 1] and acceptCard(positions, verts, maxUvW) then
      used[i], used[i + 1] = true, true
      cards[#cards + 1] = verts
    end
  end
  for i = 1, #tris do
    if not used[i] then
      local bestJ, bestN
      for j = i + 1, #tris do
        if not used[j] then
          local verts = uniquePosList(positions, tris[i], tris[j])
          if acceptCard(positions, verts, maxUvW) then
            local n = #verts
            if not bestN or n < bestN then bestJ, bestN = j, n end
          end
        end
      end
      if bestJ then
        used[i], used[bestJ] = true, true
        cards[#cards + 1] = uniquePosList(positions, tris[i], tris[bestJ])
      end
    end
  end
  local leftover = 0
  for i = 1, #tris do
    if used[i] ~= true then leftover = leftover + 1 end
  end
  return cards, leftover
end

-- ----------------------------------------------------------- textures --

local textures = {}   -- path -> { data, image, w, h } | false

local function textureFor(ground, s, set)
  set = set or ground.set
  local list = set and set.textures
  if not list then return nil end
  local rec = (s.palette and list[tostring(s.texture) .. "#" .. s.palette]) or list[s.texture]
  local path = rec and rec.path
  if not path then return nil end
  local hit = textures[path]
  if hit ~= nil then return hit or nil end
  local okA, Assets = pcall(require, "src.render.Assets")
  local okD, data = pcall(function()
    return love.image.newImageData(okA and Assets.resolve(path) or path)
  end)
  if not (okD and data) then textures[path] = false; return nil end
  local okI, image = pcall(love.graphics.newImage, data)
  if not (okI and image) then textures[path] = false; return nil end
  image:setFilter("nearest", "nearest")
  image:setWrap("clamp", "clamp")
  local w, h = data:getDimensions()
  hit = { data = data, image = image, w = w, h = h, path = path }
  textures[path] = hit
  return hit
end

-- ------------------------------------------------------------ meshing --

local ROUND_SHADE = { front = 1.0, back = 0.68, side = 0.78, top = 1.0, bottom = 0.55 }

-- one axis-aligned quad of face `f` (Voxel3D face ids), `shade` as baked
local function quad(b, f, x0, y0, z0, dx, dy, dz, u, v, shade)
  if dz <= 0 or dx <= 0 or dy <= 0 then return end
  local corners = Voxel3D.FACE_CORNERS[f]
  if f == 3 then shade = -shade end          -- the mesher's "faces the sky" flag
  local n = #b.verts / 4
  for k = 1, 4 do
    local c = corners[k]
    b.verts[#b.verts + 1] = { x0 + c[1] * dx, y0 + c[2] * dy, z0 + c[3] * dz, u, v, shade, 0 }
  end
  Voxel3D.pushQuad(b.map, n)
end

local function nearBase(positions, comp, ymin)
  local sx, sz, n = 0, 0, 0
  for _, i in ipairs(comp) do
    if positions[i][2] - ymin <= 0.5 then
      sx, sz, n = sx + positions[i][1], sz + positions[i][3], n + 1
    end
  end
  if n < 1 then
    for _, i in ipairs(comp) do
      sx, sz, n = sx + positions[i][1], sz + positions[i][3], n + 1
    end
  end
  if n < 1 then return 0, 0 end
  return sx / n, sz / n
end

local function meanWhere(positions, comp, axis, value, tol, field)
  local sum, n = 0, 0
  for _, i in ipairs(comp) do
    if math.abs(positions[i][axis] - value) <= tol then
      sum, n = sum + positions[i][field], n + 1
    end
  end
  if n == 0 then return nil end
  return sum / n
end

-- The parts of [za, zb] that a neighbour covering [nza, nzb] does not.
local function exposedPieces(za, zb, nza, nzb, emit)
  if not nza then emit(za, zb, true); return end
  if za < nza then emit(za, math.min(zb, nza), false) end
  if zb > nzb then emit(math.max(za, nzb), zb, false) end
end

-- ONE TREE, the voxel scene's way (see the header). `uL..uR` / `vB..vT` is the
-- art's texel window, `pivX/pivZ` the trunk's foot, `width` / `height` the
-- card's size in world units.
local function emitTree(b, tex, uL, uR, vB, vT, pivX, baseY, pivZ, width, height)
  if width < 1 or height < 1 then return 0 end
  local nx = math.max(1, math.min(GT.MAX_BLOCKS, math.floor(math.abs(uR - uL) / GT.TEX_STEP + 0.5)))
  local ny = math.max(1, math.min(GT.MAX_BLOCKS, math.floor(math.abs(vB - vT) / GT.TEX_STEP + 0.5)))
  local sx, sy = width / nx, height / ny
  local originX = pivX - width * 0.5

  -- sample the art; row 1 is the top
  local grid, lo, hi, any = {}, {}, {}, false
  for j = 1, ny do
    local row = {}
    local v = vT + (vB - vT) * ((j - 0.5) / ny)
    local ty = math.floor(v) % tex.h
    for i = 1, nx do
      local u = uL + (uR - uL) * ((i - 0.5) / nx)
      local tx = math.floor(u) % tex.w
      local okP, r, g, bl, a = pcall(tex.data.getPixel, tex.data, tx, ty)
      if not okP then r, g, bl, a = 0, 0, 0, 0 end
      if a > 1 then r, g, bl, a = r / 255, g / 255, bl / 255, a / 255 end
      if a >= 0.5 then
        row[i] = { key = math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256
                         + math.floor(bl * 255 + 0.5),
                   u = (tx + 0.5) / tex.w, v = (ty + 0.5) / tex.h }
        lo[j] = lo[j] or i
        hi[j] = i
        any = true
      end
    end
    grid[j] = row
  end
  if not any then return 0, "empty" end   -- nothing opaque: nothing to draw, and nothing native to keep

  -- FLOATING TREES: a sprite is usually drawn with a few empty rows under the
  -- trunk, and the tree stood on the card's base with that padding underneath
  -- it. Drop the whole tree by the empty rows so the lowest opaque block, the
  -- trunk's foot, sits where the card's base is.
  if GT.PAD_SINK then
    local lastRow = ny
    while lastRow > 1 and not lo[lastRow] do lastRow = lastRow - 1 end
    local pad = math.min((ny - lastRow) * sy, height * GT.MAX_PAD_FRAC)
    baseY = baseY - pad
  end

  -- A window that is (nearly) all opaque has no tree outline to follow: the
  -- texture has no real alpha, or it is a forest-wall tile. Run through the
  -- disc recipe below it would be one solid slab -- the "big green block".
  -- Give it the outline a tree has instead: an ellipse inscribed in the
  -- window, cut from the same texels. Real sprites (corners transparent, far
  -- below DENSE_FRACTION) never reach this.
  local opaque = 0
  for j = 1, ny do for i = 1, nx do if grid[j][i] then opaque = opaque + 1 end end end
  local dense = opaque >= GT.DENSE_FRACTION * nx * ny
  if dense then
    for j = 1, ny do
      local ey = ((j - 0.5) / ny) * 2 - 1
      local half = math.sqrt(math.max(0, 1 - ey * ey))
      for i = 1, nx do
        local ex = ((i - 0.5) / nx) * 2 - 1
        if math.abs(ex) > half then grid[j][i] = nil end
      end
    end
  end

  -- every RUN of a row is a disc: a row's opaque cells that touch form one
  -- tree-sized blob (a border sprite holds several trees side by side, and
  -- one disc across all of them was a wall). Its z chord is a circle of the
  -- run's half-width, but never deeper than MAX_HALF world units a side.
  local capHalf = math.max(GT.MIN_HALF, GT.MAX_HALF / sx)
  for j = 1, ny do
    local row = grid[j]
    local i = 1
    while i <= nx do
      if row[i] then
        local k = i
        while row[k + 1] do k = k + 1 end
        local cc = (i - 1 + k) * 0.5
        local hw = (k - i + 1) * 0.5
        local depthHalf = math.min(hw, capHalf)
        for c = i, k do
          local dx = (c - 0.5) - cc
          local chord = depthHalf * math.sqrt(math.max(0, 1 - (dx * dx) / (hw * hw)))
          local n = math.max(GT.MIN_HALF, math.floor(chord + 0.5))
          row[c].za, row[c].zb = pivZ - n * sx, pivZ + n * sx
        end
        i = k + 1
      else
        i = i + 1
      end
    end
  end

  local before = #b.verts / 4
  for j = 1, ny do
    local row = grid[j]
    local y0 = baseY + (ny - j) * sy
    -- front and back: the drawing per block, runs of one colour and one chord
    local i = 1
    while i <= nx do
      local cell = row[i]
      if cell then
        local k = i
        while row[k + 1] and row[k + 1].key == cell.key
              and row[k + 1].za == cell.za do k = k + 1 end
        local x0, w = originX + (i - 1) * sx, (k - i + 1) * sx
        quad(b, 5, x0, y0, cell.zb - 0.001, w, sy, 0.001, cell.u, cell.v, ROUND_SHADE.front)
        quad(b, 6, x0, y0, cell.za, w, sy, 0.001, cell.u, cell.v, ROUND_SHADE.back)
        i = k + 1
      else
        i = i + 1
      end
    end
    -- sides, top, underside: the column's own texel, only where no neighbour covers
    for i2 = 1, nx do
      local cell = row[i2]
      if cell then
        local x0 = originX + (i2 - 1) * sx
        local za, zb = cell.za, cell.zb
        local L, R = row[i2 - 1], row[i2 + 1]
        exposedPieces(za, zb, L and L.za, L and L.zb, function(a, c)
          quad(b, 2, x0, y0, a, 0.001, sy, c - a, cell.u, cell.v, ROUND_SHADE.side)
        end)
        exposedPieces(za, zb, R and R.za, R and R.zb, function(a, c)
          quad(b, 1, x0 + sx - 0.001, y0, a, 0.001, sy, c - a, cell.u, cell.v, ROUND_SHADE.side)
        end)
        local up = grid[j - 1] and grid[j - 1][i2]
        exposedPieces(za, zb, up and up.za, up and up.zb, function(a, c, whole)
          if whole and (c - a) >= 3 * sx then
            -- the dome cap: outline on the rim blocks, canopy a couple of rows deeper inside
            local deep = (grid[j + 2] and grid[j + 2][i2]) or (grid[j + 1] and grid[j + 1][i2]) or cell
            quad(b, 3, x0, y0 + sy - 0.001, a, sx, 0.001, sx, cell.u, cell.v, ROUND_SHADE.top)
            quad(b, 3, x0, y0 + sy - 0.001, a + sx, sx, 0.001, c - a - 2 * sx, deep.u, deep.v, ROUND_SHADE.top)
            quad(b, 3, x0, y0 + sy - 0.001, c - sx, sx, 0.001, sx, cell.u, cell.v, ROUND_SHADE.top)
          else
            quad(b, 3, x0, y0 + sy - 0.001, a, sx, 0.001, c - a, cell.u, cell.v, ROUND_SHADE.top)
          end
        end)
        if j < ny then
          local dn = grid[j + 1] and grid[j + 1][i2]
          exposedPieces(za, zb, dn and dn.za, dn and dn.zb, function(a, c)
            quad(b, 4, x0, y0, a, sx, 0.001, c - a, cell.u, cell.v, ROUND_SHADE.bottom)
          end)
        end
      end
    end
  end
  return #b.verts / 4 - before
end

-- One card -> trees in bucket `b`. A wide card is the same sprite tiled
-- (`conttree*`): one tree per texture repeat.
local function buildCard(b, tex, positions, comp, strip)
  local xmin, xmax, ymin, ymax = math.huge, -math.huge, math.huge, -math.huge
  local zmin, zmax = math.huge, -math.huge
  local umin, umax, vmin, vmax = math.huge, -math.huge, math.huge, -math.huge
  for _, i in ipairs(comp) do
    local p = positions[i]
    if p[1] < xmin then xmin = p[1] end
    if p[1] > xmax then xmax = p[1] end
    if p[2] < ymin then ymin = p[2] end
    if p[2] > ymax then ymax = p[2] end
    if p[3] < zmin then zmin = p[3] end
    if p[3] > zmax then zmax = p[3] end
    if p[4] < umin then umin = p[4] end
    if p[4] > umax then umax = p[4] end
    if p[5] < vmin then vmin = p[5] end
    if p[5] > vmax then vmax = p[5] end
  end
  local spanX, spanZ = xmax - xmin, zmax - zmin
  -- WHICH WAY THE CARD RUNS comes from its NORMAL. A card leans back 35 degrees,
  -- so a TALL narrow tree has more z extent than x extent (height * 0.575 >
  -- width once it is taller than ~1.7x its width). Comparing the extents took
  -- every such tree for a card running along z: it sampled one texel column,
  -- came out as a deep green slab, and was given the wrong height. The
  -- normal's horizontal part points across the card, so the card runs along
  -- the OTHER axis.
  local alongZ
  do
    local best, bx, bz = 0, 0, 0
    local n = #comp
    for a = 1, n - 2 do
      for c = a + 1, n - 1 do
        for d = c + 1, n do
          local pa, pb, pc = positions[comp[a]], positions[comp[c]], positions[comp[d]]
          local ux, uy, uz = pb[1] - pa[1], pb[2] - pa[2], pb[3] - pa[3]
          local vx, vy, vz = pc[1] - pa[1], pc[2] - pa[2], pc[3] - pa[3]
          local nx = uy * vz - uz * vy
          local ny = uz * vx - ux * vz
          local nz = ux * vy - uy * vx
          local len = nx * nx + ny * ny + nz * nz
          if len > best then best, bx, bz = len, nx, nz end
        end
      end
    end
    if math.abs(bx) > 1e-9 or math.abs(bz) > 1e-9 then
      alongZ = math.abs(bx) > math.abs(bz)
    else
      alongZ = spanZ > spanX            -- a flat quad: no lean to read
    end
  end
  local width = alongZ and spanZ or spanX
  local lean = alongZ and spanX or spanZ     -- the extent the card's lean adds
  local height = math.sqrt((ymax - ymin) ^ 2 + lean ^ 2)
  if width < 1 or height < 1 then return 0, true end
  -- not a tree: a flat quad, or something far bigger than any tree
  if (ymax - ymin) < GT.MIN_TREE_H or height > GT.MAX_TREE_H then
    once("flat:" .. tostring(tex.path), "card '%s' is not a tree: dy %.1f height %.1f", tostring(tex.path), ymax - ymin, height)
    return 0, true
  end

  local uL, uR
  if not alongZ then
    uL = meanWhere(positions, comp, 1, xmin, 0.5, 4) or umin
    uR = meanWhere(positions, comp, 1, xmax, 0.5, 4) or umax
  else
    uL = meanWhere(positions, comp, 3, zmin, 0.5, 4) or umin
    uR = meanWhere(positions, comp, 3, zmax, 0.5, 4) or umax
  end
  local vB = meanWhere(positions, comp, 2, ymin, 0.5, 5) or vmax
  local vT = meanWhere(positions, comp, 2, ymax, 0.5, 5) or vmin

  local pivX, pivZ = nearBase(positions, comp, ymin)
  local baseY = ymin - GT.SINK
  -- ONE TREE PER TREE-WIDTH of card: an ordinary card is one tree (~33 wide),
  -- a border strip is several side by side, each its own slice of the art
  local trees = math.max(1, math.floor(width / GT.TREE_UNIT + 0.5))
  if strip then
    -- a border strip is the sprite tiled: one tree per texture REPEAT, so each
    -- slice is exactly one drawn tree (slicing by world width cut repeats in
    -- half, which is what turned borders into slabs)
    local repeats = math.abs(uR - uL) / math.max(1, tex.w)
    if repeats >= 1.5 then trees = math.floor(repeats + 0.5) end
  end
  local each = width / trees
  local made, solid = 0, nil
  for k = 0, trees - 1 do
    local a = uL + (uR - uL) * (k / trees)
    local c = uL + (uR - uL) * ((k + 1) / trees)
    local mid = -width * 0.5 + (k + 0.5) * each
    local px, pz = pivX, pivZ
    if alongZ then pz = pivZ + mid else px = pivX + mid end
    local m = emitTree(b, tex, a, c, vB, vT, px, baseY, pz, each, height)
    made = made + m
  end
  once("card:" .. tostring(tex.path),
       "card '%s' tex %dx%d: width %.1f height %.1f dy %.1f -> %d tree(s) of %.1f; u %.1f..%.1f v %.1f..%.1f",
       tostring(tex.path), tex.w, tex.h, width, height, ymax - ymin, trees, each,
       uL, uR, vB, vT)
  return made, false
end

local function packedFor(ground, object)
  local index = object.model
  if index == nil then return nil end
  if object.archive == "fldeff" then
    local set = ground.fldeffSet
    local at = set and set.byMember and set.byMember[index]
    return at and set.models and set.models[at], set
  end
  local set = ground.buildingSet
  return set and set.models and set.models[index + 1], set
end

local function objectPlace(object)
  local function scale(v) return (v and v ~= 0) and v or 1 end
  local yaw = object.yaw or object.rotY or object.rotationY or 0
  if math.abs(yaw) > 8 then yaw = math.rad(yaw) end
  return { sx = scale(object.scaleX), sy = scale(object.scaleY), sz = scale(object.scaleZ),
           x = object.x or 0, y = object.y or 0, z = object.z or 0, yaw = yaw }
end

local function applyPlace(positions, place)
  if not place then return positions end
  local c, s = math.cos(place.yaw or 0), math.sin(place.yaw or 0)
  local out = {}
  for i, p in ipairs(positions) do
    local x, y, z = p[1] * place.sx, p[2] * place.sy, p[3] * place.sz
    out[i] = { x * c - z * s + place.x, y + place.y, x * s + z * c + place.z, p[4], p[5] }
  end
  return out
end

-- One land chunk -> { buckets = {{mesh, tex}}, shapes = {record,...}, quads }
local function buildLand(ground, land)
  local record = ground.terrain.chunks[land]
  local out = { buckets = {}, shapes = {}, quads = 0, failed = {} }
  if not (record and record.shapes) then return out end
  local byPath, order = {}, {}
  local skipped = {}

  local function takeShape(s, posScale, texSet, place)
    local skip
    local named = GT.isTreeName(s)
    local strip = namesOf(s):find("conttree", 1, true) ~= nil
    if out.quads >= GT.MAX_QUADS then
      skip = "quad budget"
    end
    local positions, tris, tex, comps
    if not skip then
      positions, tris = readShape(ground, s, posScale)
      if not positions then skip = "unreadable" end
    end
    if not skip then
      positions = applyPlace(positions, place)
      if not named then
        local allCards = true
        for _, t in ipairs(tris) do
          local pa, pb, pc = positions[t[1]], positions[t[2]], positions[t[3]]
          if not (pa and pb and pc and isCardTri(pa, pb, pc)) then
            allCards = false
            break
          end
        end
        if not allCards then skip = "not all cards" end
      end
    end
    if not skip then
      tex = textureFor(ground, s, texSet)
      if not tex then skip = "no texture" end
    end
    if not skip then
      local leftover
      comps, leftover = cardsFromTris(positions, tris, (not strip) and STRIP_REPEATS * tex.w or nil, false)
      -- a tree-named shape is trees all through: stray triangles are dropped
      -- with it rather than keeping the whole shape native
      if #comps == 0 or leftover > 0 then skip = "not all cards" end
    end

    if skip then
      skipped[skip] = (skipped[skip] or 0) + 1
      if named then
        for _, k in ipairs(nameKeys(s)) do out.failed[k] = true end
        once("named:" .. tostring(land) .. tostring(s.texture or s.name) .. skip,
             "land %s: tree shape '%s' left native: %s", tostring(land), (namesOf(s):gsub("\n", "|")), skip)
      end
      return
    end
    local b = byPath[tex.path]
    if not b then
      b = { verts = {}, map = {}, tex = tex.image }
      byPath[tex.path] = b
      order[#order + 1] = b
    end
    -- ALL OR NOTHING PER SHAPE. A shape is hidden once it is covered, so every
    -- card in it has to have become trees; if one did not, undo the lot and
    -- leave the native shape drawing (it used to vanish with 0 quads).
    local v0, m0, built, ok, bad = #b.verts, #b.map, 0, true, 0
    for _, comp in ipairs(comps) do
      local n, failed = buildCard(b, tex, positions, comp, strip)
      if failed then bad = bad + 1 end
      built = built + n
    end
    -- A card that is not a tree (flat, giant, degenerate) draws nothing, as it
    -- always did; it must not put the shape's real trees back to native cards.
    -- Only a shape that built nothing at all stays native.
    if built <= 0 then ok = false end
    if not ok or built <= 0 then
      for i = #b.verts, v0 + 1, -1 do b.verts[i] = nil end
      for i = #b.map, m0 + 1, -1 do b.map[i] = nil end
      skipped["card unusable"] = (skipped["card unusable"] or 0) + 1
      for _, k in ipairs(nameKeys(s)) do out.failed[k] = true end
      once("unusable:" .. tostring(s.texture or s.name),
           "shape '%s' left native: nothing built from %d cards (%d not trees)", (namesOf(s):gsub("\n", "|")), #comps, bad)
      return
    end
    out.quads = out.quads + built
    out.shapes[#out.shapes + 1] = s
    once("ok:" .. tostring(s.texture or s.name),
         "shape '%s' voxelised: %d cards (%d skipped as not trees), %d quads (land %s)", (namesOf(s):gsub("\n", "|")), #comps, bad, built, tostring(land))
  end

  local function isStrip(s) return namesOf(s):find("conttree", 1, true) ~= nil end
  for pass = 1, 2 do
    local wantStrip = (pass == 2)
    for _, s in ipairs(record.shapes) do
      if isStrip(s) == wantStrip then
        local okS, errS = pcall(takeShape, s, record.posScale or 1, ground.set, nil)
        if not okS then
          skipped["error"] = (skipped["error"] or 0) + 1
          for _, k in ipairs(nameKeys(s)) do out.failed[k] = true end
          once("shape:" .. tostring(s.texture or s.name), "tree shape '%s' ERRORED and was left native: %s", tostring(s.texture or s.name), tostring(errS))
        end
      end
    end
    for _, object in ipairs(record.objects or {}) do
      local packed, texSet = packedFor(ground, object)
      if packed and packed.shapes then
        local place = objectPlace(object)
        for _, s in ipairs(packed.shapes) do
          if isStrip(s) == wantStrip then
            local okS, errS = pcall(takeShape, s, packed.posScale or 1, texSet, place)
            if not okS then
              skipped["error"] = (skipped["error"] or 0) + 1
              for _, k in ipairs(nameKeys(s)) do out.failed[k] = true end
              once("shape:" .. tostring(s.texture or s.name), "prop tree shape '%s' ERRORED and was left native: %s", tostring(s.texture or s.name), tostring(errS))
            end
          end
        end
      end
    end
  end

  for _, b in ipairs(order) do
    local mesh = Voxel3D.newMesh(b.verts, b.map)
    if mesh then out.buckets[#out.buckets + 1] = { mesh = mesh, tex = b.tex } end
  end
  if GT.LOG and (#out.shapes > 0 or next(skipped)) then
    local why = {}
    for k, n in pairs(skipped) do why[#why + 1] = ("%d %s"):format(n, k) end
    once("land" .. tostring(land),
         "land %s: %d tree shapes voxelised (%d quads); left native: %s",
         tostring(land), #out.shapes, out.quads, #why > 0 and table.concat(why, ", ") or "none")
  end
  return out
end

-- ------------------------------------------------------------- window --

local lastSignature = ""

-- Work out which lands are in the window, build what the budget allows, and
-- publish GT.active (shape records covered RIGHT NOW). Idempotent per frame;
-- Gen4Hide calls it before the native pass, GT.draw calls it again.
function GT.prepare(ground)
  local active, list, names = {}, {}, {}
  GT.active, GT.list, GT.coveredNames = active, list, names
  local view = ground and ground.view3d
  if not (GT.enabled and ground and view and ground.grid and ground.terrain
          and ground.slice and ground.chunkPx and ground.half and ground.set) then
    return
  end
  local rec = cache[ground]
  if not rec then rec = { lands = {} }; cache[ground] = rec end

  local grid, px, half = ground.grid, ground.chunkPx, ground.half
  local W = GT.WINDOW
  local camCx, camCy = math.floor(view.x / px), math.floor(view.z / px)
  local want = {}
  for cy = camCy - W, camCy + W do
    for cx = camCx - W, camCx + W do
      if cx >= 0 and cy >= 0 and cx < grid.width and cy < grid.height then
        local dx, dz = cx - camCx, cy - camCy
        want[#want + 1] = { dx * dx + dz * dz, cx, cy, grid.land[cy * grid.width + cx + 1] }
      end
    end
  end
  table.sort(want, function(a, b) return a[1] < b[1] end)

  local now = love.timer and love.timer.getTime
  local started = now and now() or 0
  local builds = 0
  local sig = {}
  local failedNames = {}
  local missing = 0
  for _, w in ipairs(want) do
    if not rec.lands[w[4]] then missing = missing + 1 end
  end
  -- a window that is still filling gets the bigger budget, so the old cards
  -- are not on screen beside the new trees for long
  local budget = (missing > 1) and GT.WARM_BUDGET or GT.BUILD_BUDGET
  local perFrame = (missing > 1) and #want or GT.BUILDS_PER_FRAME
  for _, w in ipairs(want) do
    local land = w[4]
    local entry = rec.lands[land]
    if not entry then
      local over = builds >= perFrame
        or (builds > 0 and now and (now() - started) > budget)
      if not over then
        builds = builds + 1
        local ok, built = pcall(buildLand, ground, land)
        if ok then
          entry = built
        else
          entry = { buckets = {}, shapes = {}, quads = 0, failed = {} }
          once("build", "a land chunk failed to build and was skipped: %s", tostring(built))
        end
        rec.lands[land] = entry
      end
    end
    if entry then
      sig[#sig + 1] = tostring(land)
      for _, s in ipairs(entry.shapes) do
        active[s] = true
        for _, k in ipairs(nameKeys(s)) do names[k] = true end
      end
      for k in pairs(entry.failed or {}) do failedNames[k] = true end
      if #entry.buckets > 0 then
        list[#list + 1] = { entry = entry, x = w[2] * px + half, z = w[3] * px + half }
      end
    end
  end
  -- a name that failed in ANY land of the window is not safe to hide by name
  for k in pairs(failedNames) do names[k] = nil end
  local signature = table.concat(sig, ",")
  if signature ~= lastSignature then
    lastSignature = signature
    GT.coverVersion = GT.coverVersion + 1
  end
end

-- Gen4Hide asks this per cache shape record.
function GT.isCovered(record)
  return record ~= nil and GT.active[record] == true
end

-- The fallback Gen4Hide uses when a built shape did not keep its cache `src`
-- pointer (so `isCovered` cannot answer): hide by texture / material name --
-- but only names that converted in EVERY land of the window (see `prepare`),
-- and never by the shape's own name. This is what lets BOTH kinds of tree
-- lose their native card once their voxel tree is standing.
function GT.isCoveredName(shape)
  local names = GT.coveredNames
  if not (shape and names) then return false end
  for _, k in ipairs(nameKeys(shape)) do
    if names[k] then return true end
  end
  return false
end

-- ---------------------------------------------------------------- draw --

function GT.draw(scene)
  if not GT.enabled then return end
  GT.prepare(scene.ground)
  if #GT.list == 0 then return end
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  for _, item in ipairs(GT.list) do
    for _, b in ipairs(item.entry.buckets) do
      Voxel3D.draw(b.mesh, b.tex, Mat4.translate(item.x, GT.Y_OFFSET or 0, item.z), 0, nil, 0, false)
    end
  end
  Voxel3D.seams(true)
  Voxel3D.glass(true)
end

-- Drop every baked tree: a map was edited, or the mod was reloaded.
function GT.invalidate()
  for _, rec in pairs(cache) do
    for _, entry in pairs(rec.lands) do
      for _, b in ipairs(entry.buckets or {}) do
        if b.mesh and b.mesh.release then pcall(b.mesh.release, b.mesh) end
      end
    end
  end
  cache = setmetatable({}, { __mode = "k" })
  textures = {}
  GT.active, GT.list, GT.coveredNames = {}, {}, {}
  GT.coverVersion = GT.coverVersion + 1
end

return GT