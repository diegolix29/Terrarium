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
-- SMOOTH MODE (GT.SMOOTH, on by default)
--
-- The per-row slabs above leave stair-stepped ledges. Smooth mode keeps the
-- same disc profile but puts the depth on the grid CORNERS, so neighbouring
-- cells share it and the surface is continuous (see smoothSurface): the front
-- view is still the sprite, the plan view is still round, and the shading
-- follows the surface slope instead of jumping per block. GT.SMOOTH = false
-- brings the blocky look back; GT.SMOOTH_PASSES and GT.RIM tune the roundness.
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
-- DRAW DISTANCE (lib/Gen4Distance.lua, row "G4 DRAW DIST"): only lands within
-- the chosen reach of the camera get voxel trees, built or drawn. Farther lands
-- keep Platinum's flat cards (Gen4Hide hides cards only on covered lands), and
-- baked lands the camera has left are released (GT.MAX_RESIDENT).
--
-- FACING (GT.FACING, GT.setFacing)
--
-- A tree is round and both z ends carry the same art, so which way it "faces"
-- is only which side wears the bright front shade. Every surface is shaded by
-- its own normal against the facing -- not by a Voxel3D face id.
--
-- The engine's own native tree cards turn to face the camera every frame
-- (Gen4Model turnToCamera, billboardYaw = view.yaw). A baked tree cannot turn,
-- so the DEFAULT, "camera", bakes each tree lit from the south and from the
-- north and GT.draw shows the one whose lit end looks at the camera (the
-- south-lit one while the view looks north, the north-lit one while it looks
-- south). That costs a second mesh per land.
--
-- A fixed facing ("south" | "north" | "east" | "west" | degrees) bakes one mesh
-- and keeps the lit side on that world direction whatever the camera does. The
-- shade is baked, so change it with GT.setFacing(...), which re-bakes;
-- assigning GT.FACING alone only reaches lands built later.
--
-- KNOBS: GT.enabled, GT.FACING, GT.SMOOTH, GT.SMOOTH_PASSES, GT.RIM, GT.WINDOW,
-- GT.TEX_STEP, GT.MAX_QUADS, GT.WARM_BUDGET, GT.HYSTERESIS, GT.MAX_RESIDENT.
-- Bridge.disabled.trees turns the effect off.

local V = ...
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")

local GT = {
  enabled = true,
  WINDOW = 2,             -- chunks each way: the MOST lands ever considered (same window as Gen4Ground / water)
  HYSTERESIS = 1.15,      -- a land already built stays covered out to this multiple of the draw-distance reach, so the edge does not flicker
  MAX_RESIDENT = 14,      -- built lands kept in memory when the draw distance is limited (the rest are released, oldest first)
  MAX_RESIDENT_MAX = 30,  -- ...and at MAX, which has no distance limit
  SMOOTH = true,          -- build the tree as ONE continuous inflated surface (no stair-step slab walls). false = the old blocky stack of discs
  SMOOTH_PASSES = 1,      -- extra blur passes over the depth field (0 = as sampled, 2-3 = rounder, softer)
  RIM = 0.35,             -- depth kept at the silhouette, as a fraction of the depth just inside it (0 = razor edge, 1 = full slab wall)
  LAYER_OFFSET = {        -- hand nudge per LAYER (hat / middle / base), counted from the top, WORLD UNITS. x = sideways (+ east), y = up, z = toward the south. Each layer moves as ONE whole sprite, never cut into parts. All zero = off. Baked: use GT.setLayerOffset(...) or reload
    { x = 0, y = 12, z = -3 },    -- 1 = the top layer (the hat)
    { x = 0, y = 5, z = -8 },    -- 2 = the middle layer
    { x = 0, y = 2, z = -10 },   -- 3 = the bottom layer (the base)
  },
  LAYER_GROUP = 8,        -- cards of one shape whose centres are within this many world units (sideways) are the hat / middle / base of ONE tree, ranked by height. Works for normal trees AND border (conttree) strips
  SINGLE_OFFSET = false, -- a tree drawn as ONE card (all layers in one sprite) moves as one whole piece: "auto" = the average of LAYER_OFFSET[1..3], or { x =, y =, z = } by hand, or false = no offset
  STRIP_LAYER_GROUP = 20, -- like LAYER_GROUP, but for border (conttree) cards: a border card joins a tree if it is this near ANY card already in it (a leaned stack of cards drifts in z, so the first-card test used for normal trees split them). Raise it if hat / middle / base still land in different groups, lower it if two trees merge. false = use LAYER_GROUP
  STRIP_LAYER_OFFSET = {  -- the same hat / middle / base nudge, but ONLY for border (conttree) trees. A table of three { x, y, z } like LAYER_OFFSET; false = border trees share LAYER_OFFSET with the normal trees
    { x = 0, y = 12, z = -3 },    -- 1 = the top layer (the hat)
    { x = 0, y = 0, z = 0 },    -- 2 = the middle layer
    { x = 0, y = 5, z = -8 },   -- 3 = the bottom layer (the base)
  },
  STRIP_SHAPE_OFFSET = {   -- per border shape { hat, middle, base }; a shape not listed falls back to STRIP_LAYER_OFFSET
    conttree_t = { { x=0, y=12, z=-3 }, { x=0, y=0, z=0 }, { x=0, y=5, z=-8 } },
    conttree_b = { { x=0, y=2, z=-10 }, { x=0, y=0, z=0 }, { x=0, y=5, z=-8 } },
  },
  STRIP_SINGLE_OFFSET = false, -- a border tree drawn as ONE card: "same" = use SINGLE_OFFSET, "auto" = the average of STRIP_LAYER_OFFSET, { x =, y =, z = } by hand, or false = none
  DEBUG_LAYERS = false,   -- true: tint each layer (1 bright, 2 mid, 3 dark) so you can SEE which card took which layer
  FLAT = false,          -- front and back faces sit in (almost) the SAME place: the tree keeps the sprite's silhouette and height but has no depth, so both sides show the same art at the same spot. false = the round disc profile
  FLAT_HALF = 8.4,        -- ...half the slab's thickness in world units when FLAT (0.4 = 0.8 thick: enough that the two faces never z-fight)
  SAME_FACE = true,       -- both z ends of a tree wear the FRONT shade, like the native card that always turns its face to the camera. false = the old lit-front / dark-back pair (see FACING)
  FACING = "camera",      -- "camera" = the lit side follows the camera like the native cards do (two meshes per land, one drawn per frame); or a fixed world side: "south" (+z), "north" (-z), "east" (+x), "west" (-x), or a compass bearing in degrees (0 = north, 90 = east, 180 = south, 270 = west). Baked into the meshes: change it with GT.setFacing(), which re-bakes
  TEX_STEP = 2,           -- texels per block edge (1 = full resolution, 4x the quads)
  MAX_BLOCKS = 40,        -- most blocks across one card, whatever the step says
  MIN_HALF = 3,           -- a column's chord is never thinner than this many blocks each side
  MAX_HALF = 15,          -- a tree is never deeper than 2x this many world units, however wide its run
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
  LOG = false,            -- logging disabled for performance
  coverVersion = 0,       -- bumps whenever the set of covered shapes changes
  active = {},            -- cache shape record -> true (covered AND in the window)
  coveredNames = {},      -- texture/material names that converted in EVERY land of the window (Gen4Hide's fallback when a shape has no cache pointer)
  coveredLands = {},      -- land id -> true for every land inside the draw distance (Gen4Hide's name fallback is only valid there)
  limited = false,        -- true while a finite draw distance is in force
}

-- the cartridge's tree lean, the same constants Gen4Model classifies by
local TREE_NY, TREE_NZ, TREE_TOL = 0.819, 0.575, 0.04
local STRIP_REPEATS = 1.25
local FX16, UV_UNITS = 4096, 16

local warned = {}
local function once(key, fmt, ...)
  -- Logging disabled for performance
  if warned[key] then return end
  warned[key] = true
end

local function optional(name)
  local ok, mod = pcall(V.require, name)
  return ok and mod or nil
end

-- One shared per-frame build budget (lib/Gen4Budget.lua); see Gen4Sand. The
-- old private WARM_BUDGET (40 ms a frame) is gone: it was the biggest single
-- hitch on desktop and a multi-second freeze on a phone.
local Budget = optional("Gen4Budget") or { allow = function() return true end, charge = function() end }
local clock = (love and love.timer and love.timer.getTime) or os.clock

-- G4 DRAW DIST (lib/Gen4Distance.lua). Absent = the old behaviour, every land.
local Distance = optional("Gen4Distance")

-- Land meshes, keyed by the engine's land id (shared across crops of the
-- same grid). A route swap builds a new Ground, so a weak Ground-keyed cache
-- dropped every voxel tree and let native cards flash back. Number keys stay;
-- table keys (a land record) go with the record. Dropped only by invalidate().
local landEntries = setmetatable({}, { __mode = "k" })
local window = {}
local northLit = false -- camera mode: draw the north-lit variant (the camera looks south)
local resident = 0     -- built lands in landEntries
local tick = 0         -- bumps per window recompute; entry.used = last tick the land was wanted

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

-- WHICH WAY A TREE FACES. The tree is a round, symmetric solid and both of its
-- z ends carry the same art, so "facing" is purely which side wears the bright
-- `front` shade. It used to be welded to Voxel3D's face ids (5 = front, 6 =
-- back), i.e. to one world direction, and a hand swap of the two ids can only
-- ever move it to the other end of z. Here it is a direction in the ground
-- plane (+x east, +z south, the Bridge's convention) and every surface is
-- shaded by where its own normal points relative to it, so a face's id never
-- decides it.
local FACING_DIRS = { south = { 0, 1 }, north = { 0, -1 }, east = { 1, 0 }, west = { -1, 0 } }

local function facingVec()
  local f = GT.FACING
  local d = FACING_DIRS[type(f) == "string" and f:lower() or ""]
  if d then return d[1], d[2] end
  local bearing = tonumber(f)
  if bearing then
    local a = math.rad(bearing)
    return math.sin(a), -math.cos(a)        -- 0 = north (-z), 90 = east (+x)
  end
  return 0, 1                               -- anything unreadable: south
end

-- shade of a surface whose UNIT normal is (nx, ny, nz): front / back by the
-- part of the normal along the facing, side by the part across it, top /
-- bottom by the vertical part (the squares of the three parts sum to 1)
local function surfaceShade(nx, ny, nz, fx, fz)
  local along = nx * fx + nz * fz
  local across = nx * fz - nz * fx
  local horiz = (GT.SAME_FACE or along >= 0) and ROUND_SHADE.front or ROUND_SHADE.back
  local vert = (ny >= 0) and ROUND_SHADE.top or ROUND_SHADE.bottom
  return horiz * along * along + ROUND_SHADE.side * across * across + vert * ny * ny
end

-- The outward normal of each flat quad, keyed by where it stands (zb = the +z
-- end, za = the -z end, xr = +x, xl = -x). The meshers record the NORMAL on
-- every vertex and the shade is worked out afterwards (finishBucket), because
-- the shade depends on which way the tree faces and, in camera mode, a tree
-- is baked once for each of two facings.
local FACE_NORMALS = {
  zb = { 0, 0, 1 }, za = { 0, 0, -1 }, xr = { 1, 0, 0 }, xl = { -1, 0, 0 },
  top = { 0, 1, 0 }, bottom = { 0, -1, 0 },
}

-- The facings a tree is baked for, as { fx, fz } pairs. Camera mode bakes both
-- ends of z (lit side south, then lit side north) and GT.draw picks the one
-- that looks at the camera; every other setting is a single fixed facing.
local function variantFacings()
  if GT.SAME_FACE then return { { 0, 1 } } end   -- both ends shade alike: one mesh, nothing to swap
  if type(GT.FACING) == "string" and GT.FACING:lower() == "camera" then
    return { { 0, 1 }, { 0, -1 } }
  end
  local fx, fz = facingVec()
  return { { fx, fz } }
end

-- The layer (1 hat, 2 middle, 3 base) of the card being emitted, for GT.DEBUG_LAYERS.
local curLayer = nil
local DEBUG_TINT = { 1.0, 0.62, 0.38 }

-- one axis-aligned quad of face `f` (Voxel3D face ids), `normal` = FACE_NORMALS.*.
-- Vertex = { x, y, z, u, v, shade, 0, nx, ny, nz, sky, layer }; the shade (fields 6)
-- is filled in and the normal stripped by finishBucket before the mesh is made.
local function quad(b, f, x0, y0, z0, dx, dy, dz, u, v, normal)
  if dz <= 0 or dx <= 0 or dy <= 0 then return end
  local corners = Voxel3D.FACE_CORNERS[f]
  local sky = (f == 3)                         -- the mesher's "faces the sky" flag
  local n = #b.verts / 4
  for k = 1, 4 do
    local c = corners[k]
    b.verts[#b.verts + 1] = { x0 + c[1] * dx, y0 + c[2] * dy, z0 + c[3] * dz, u, v, 1, 0,
                              normal[1], normal[2], normal[3], sky, curLayer }
  end
  Voxel3D.pushQuad(b.map, n)
end

-- Turn a bucket's recorded normals into baked shades and make its mesh(es).
-- Returns the first mesh and, in camera mode, the second (lit from the north).
local function finishBucket(b)
  local verts = b.verts
  local facings = variantFacings()
  local count = #verts
  local shades = {}
  for k, fv in ipairs(facings) do
    local s = {}
    for i = 1, count do
      local v = verts[i]
      local value = surfaceShade(v[8], v[9], v[10], fv[1], fv[2])
      if GT.DEBUG_LAYERS and v[12] then value = value * (DEBUG_TINT[v[12]] or DEBUG_TINT[#DEBUG_TINT]) end
      s[i] = v[11] and -value or value
    end
    shades[k] = s
  end
  for i = 1, count do                      -- strip the bookkeeping fields
    local v = verts[i]
    v[8], v[9], v[10], v[11], v[12] = nil, nil, nil, nil, nil
  end
  local meshes = {}
  for k = 1, #facings do
    local s = shades[k]
    for i = 1, count do verts[i][6] = s[i] end
    meshes[k] = Voxel3D.newMesh(verts, b.map)
  end
  return meshes[1], meshes[2]
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

-- SMOOTH SURFACE. The blocky recipe gives every cell a flat z slab, so the
-- tree is a stack of stepped ledges. Here the depth lives on the grid CORNERS
-- instead: a corner shared by four opaque cells takes their mean half-depth,
-- a corner on the silhouette keeps GT.RIM of it, and every cell's front and
-- back face is a quad that follows its four corner depths. Neighbouring cells
-- share corners, so the surface is continuous: the ledges become slopes, the
-- canopy a pillow. Thin walls close the silhouette (and holes). Vertex shade
-- comes from the surface slope, blended from the same five face shades, so
-- the gradient runs smoothly across the tree instead of jumping per block.
local SMOOTH_SKY_NY = 0.6   -- a quad whose mean normal points this far up gets the "faces the sky" flag

local function smoothSurface(b, grid, nx, ny, sx, sy, originX, baseY, pivZ, lean)
  -- 1. half-depth at every grid corner (corner (i0, j0): j0 = 0 is the top edge of row 1)
  local D = {}
  for j0 = 0, ny do
    local up, dn = grid[j0], grid[j0 + 1]
    local r = {}
    for i0 = 0, nx do
      local sum, n = 0, 0
      local c1, c2 = up and up[i0], up and up[i0 + 1]
      local c3, c4 = dn and dn[i0], dn and dn[i0 + 1]
      if c1 then sum, n = sum + c1.h, n + 1 end
      if c2 then sum, n = sum + c2.h, n + 1 end
      if c3 then sum, n = sum + c3.h, n + 1 end
      if c4 then sum, n = sum + c4.h, n + 1 end
      if n == 4 then r[i0] = sum / 4
      elseif n > 0 then r[i0] = (GT.FLAT and 0.1 or GT.RIM) * sum / n end
    end
    D[j0] = r
  end

  local function at(t, j0, i0)
    local r = t[j0]
    return r and r[i0]
  end

  -- 2. soften: pull every corner toward the mean of its neighbours
  for _ = 1, GT.SMOOTH_PASSES or 0 do
    local nd = {}
    for j0 = 0, ny do
      local out = {}
      for i0 = 0, nx do
        local c = D[j0][i0]
        if c then
          local sum, n = 0, 0
          local a = at(D, j0, i0 - 1); if a then sum, n = sum + a, n + 1 end
          a = at(D, j0, i0 + 1);       if a then sum, n = sum + a, n + 1 end
          a = at(D, j0 - 1, i0);       if a then sum, n = sum + a, n + 1 end
          a = at(D, j0 + 1, i0);       if a then sum, n = sum + a, n + 1 end
          out[i0] = n > 0 and (c * 0.5 + 0.5 * sum / n) or c
        end
      end
      nd[j0] = out
    end
    D = nd
  end

  -- slope of the depth field at a corner (world units of z per world unit);
  -- outside the tree the depth is 0, so the rim tilts outward
  local function slope(i0, j0)
    local l, r = at(D, j0, i0 - 1) or 0, at(D, j0, i0 + 1) or 0
    local u, d = at(D, j0 - 1, i0) or 0, at(D, j0 + 1, i0) or 0
    return (r - l) / (2 * sx), (u - d) / (2 * sy)
  end

  -- 3. one face of one cell. Corner order and winding come from Voxel3D's own
  -- FACE_CORNERS: c[1] = right edge, c[2] = top edge, c[3] = +Z side. Which end
  -- is "front" is NOT read from the face id: each vertex records its surface
  -- normal and finishBucket shades it against the tree's facing.
  local function face(f, i, j, cell, flat)
    local corners = Voxel3D.FACE_CORNERS[f]
    local nq = #b.verts / 4
    local ups = 0
    local pts, nrm = {}, {}
    for k = 1, 4 do
      local c = corners[k]
      local i0, j0 = i - 1 + c[1], j - c[2]
      local d = D[j0][i0]
      local py = baseY + (ny - j0) * sy
      
      -- Lean logic removed to keep tree straight
      pts[k] = { originX + i0 * sx, py, pivZ + (c[3] == 1 and d or -d) }
      
      if flat then
        nrm[k] = flat
      else
        -- outward normal of z =  depth(x, y): (-gx, -gy,  1), normalised
        local gx, gy = slope(i0, j0)
        local inv = 1 / math.sqrt(gx * gx + gy * gy + 1)
        local zSide = (c[3] == 1) and 1 or -1
        nrm[k] = { -gx * inv, -gy * inv, zSide * inv }
        ups = ups + (-gy) * inv
      end
    end
    local sky
    if flat then sky = (f == 3) else sky = (ups / 4) > SMOOTH_SKY_NY end
    for k = 1, 4 do
      local p, n = pts[k], nrm[k]
      b.verts[#b.verts + 1] = { p[1], p[2], p[3], cell.u, cell.v, 1, 0, n[1], n[2], n[3], sky, curLayer }
    end
    Voxel3D.pushQuad(b.map, nq)
  end

  local sh = FACE_NORMALS
  for j = 1, ny do
    local row = grid[j]
    for i = 1, nx do
      local cell = row[i]
      if cell then
        face(5, i, j, cell)
        face(6, i, j, cell)
        if not row[i - 1] then face(2, i, j, cell, sh.xl) end
        if not row[i + 1] then face(1, i, j, cell, sh.xr) end
        if not (grid[j - 1] and grid[j - 1][i]) then face(3, i, j, cell, sh.top) end
        if j < ny and not (grid[j + 1] and grid[j + 1][i]) then face(4, i, j, cell, sh.bottom) end
      end
    end
  end
end

-- LAYER OFFSETS. The offset of layer `k` (1 = hat, 2 = middle, 3 = base) as an
-- { x, y, z } array (missing / bad values = 0), and whether it is non-zero.
local function layerOffset(k, strip, shapeKey)
  local src = GT.LAYER_OFFSET
  if strip then
    local per = shapeKey and type(GT.STRIP_SHAPE_OFFSET) == "table" and GT.STRIP_SHAPE_OFFSET[shapeKey]
    if type(per) == "table" then src = per
    elseif type(GT.STRIP_LAYER_OFFSET) == "table" then src = GT.STRIP_LAYER_OFFSET end
  end
  local cfg = type(src) == "table" and src or {}
  local o = type(cfg[k]) == "table" and cfg[k] or {}
  local x = tonumber(o.x or o[1]) or 0
  local y = tonumber(o.y or o[2]) or 0
  local z = tonumber(o.z or o[3]) or 0
  return { x, y, z }, (x ~= 0 or y ~= 0 or z ~= 0)
end

-- The offset of a tree drawn as ONE card (hat, middle and base all in one
-- sprite). It moves as one whole piece: "auto" is the average of the three
-- layer offsets, a table is a hand value, false is none.
local function singleOffset(strip)
  local cfg = GT.SINGLE_OFFSET
  if strip and GT.STRIP_SINGLE_OFFSET ~= "same" then cfg = GT.STRIP_SINGLE_OFFSET end
  if cfg == false then return { 0, 0, 0 }, false end
  if type(cfg) == "table" then
    local x = tonumber(cfg.x or cfg[1]) or 0
    local y = tonumber(cfg.y or cfg[2]) or 0
    local z = tonumber(cfg.z or cfg[3]) or 0
    return { x, y, z }, (x ~= 0 or y ~= 0 or z ~= 0)
  end
  local sx, sy, sz = 0, 0, 0
  for k = 1, 3 do
    local o = layerOffset(k, strip)
    sx, sy, sz = sx + o[1], sy + o[2], sz + o[3]
  end
  local x, y, z = sx / 3, sy / 3, sz / 3
  return { x, y, z }, (x ~= 0 or y ~= 0 or z ~= 0)
end

-- ONE TREE, the voxel scene's way (see the header). `uL..uR` / `vB..vT` is the
-- art's texel window, `pivX/pivZ` the trunk's foot, `width` / `height` the
-- card's size in world units.
local function emitTree(b, tex, uL, uR, vB, vT, pivX, baseY, pivZ, width, height, leanX, leanZ, cardLayer, isStrip, shapeKey)
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

  -- LAYER OFFSET: the WHOLE sprite moves as one rigid piece, never row by row.
  -- A card that is one layer of a multi-card tree (hat / middle / base) takes
  -- that layer's offset; a tree drawn as a single card takes SINGLE_OFFSET.
  -- Border strips and normal trees go through the same path.
  do
    local off, moved
    if cardLayer then off, moved = layerOffset(cardLayer, isStrip, shapeKey) else off, moved = singleOffset(isStrip) end
    if moved then
      -- Logging disabled for performance
      pivX, baseY, pivZ = pivX + off[1], baseY + off[2], pivZ + off[3]
      originX = originX + off[1]
    end
    curLayer = cardLayer
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
          -- the blocky recipe rounds the chord to whole blocks; the smooth one keeps it exact
          local n = GT.SMOOTH and chord or math.floor(chord + 0.5)
          n = math.max(GT.MIN_HALF, n)
          local half = n * sx
          if GT.FLAT then half = GT.FLAT_HALF end   -- one plane: no depth profile at all
          row[c].za, row[c].zb = pivZ - half, pivZ + half
          row[c].h = half
        end
        i = k + 1
      else
        i = i + 1
      end
    end
  end

  local before = #b.verts / 4
  if GT.SMOOTH then
    -- lean is explicitly removed (nil) to prevent smoothSurface from bending the tree
    smoothSurface(b, grid, nx, ny, sx, sy, originX, baseY, pivZ, nil)
    return #b.verts / 4 - before
  end
  local sh = FACE_NORMALS
  for j = 1, ny do
    local row = grid[j]
    local y0 = baseY + (ny - j) * sy
    
    -- Lean math block completely removed here

    -- the +Z end (zb) and the -Z end (za): the drawing per block, runs of one colour and one chord;
    -- which of them is the bright front is GT.FACING's call, not the face id's
    local i = 1
    while i <= nx do
      local cell = row[i]
      if cell then
        local k = i
        while row[k + 1] and row[k + 1].key == cell.key
              and row[k + 1].za == cell.za do k = k + 1 end
        local x0, w = originX + (i - 1) * sx, (k - i + 1) * sx
        
        -- shZ offsets removed from cell.zb and cell.za calculations
        quad(b, 5, x0, y0, cell.zb - 0.001, w, sy, 0.001, cell.u, cell.v, sh.zb)
        quad(b, 6, x0, y0, cell.za, w, sy, 0.001, cell.u, cell.v, sh.za)
        i = k + 1
      else
        i = i + 1
      end
    end
    -- sides, top, underside: the column's own texel, only where no neighbour covers
    for i2 = 1, nx do
      local cell = row[i2]
      if cell then
        -- shX offset removed from origin calculation
        local x0 = originX + (i2 - 1) * sx 
        local za, zb = cell.za, cell.zb
        local L, R = row[i2 - 1], row[i2 + 1]
        exposedPieces(za, zb, L and L.za, L and L.zb, function(a, c)
          quad(b, 2, x0, y0, a, 0.001, sy, c - a, cell.u, cell.v, sh.xl)
        end)
        exposedPieces(za, zb, R and R.za, R and R.zb, function(a, c)
          quad(b, 1, x0 + sx - 0.001, y0, a, 0.001, sy, c - a, cell.u, cell.v, sh.xr)
        end)
        local up = grid[j - 1] and grid[j - 1][i2]
        exposedPieces(za, zb, up and up.za, up and up.zb, function(a, c, whole)
          if whole and (c - a) >= 3 * sx then
            -- the dome cap: outline on the rim blocks, canopy a couple of rows deeper inside
            local deep = (grid[j + 2] and grid[j + 2][i2]) or (grid[j + 1] and grid[j + 1][i2]) or cell
            quad(b, 3, x0, y0 + sy - 0.001, a, sx, 0.001, sx, cell.u, cell.v, sh.top)
            quad(b, 3, x0, y0 + sy - 0.001, a + sx, sx, 0.001, c - a - 2 * sx, deep.u, deep.v, sh.top)
            quad(b, 3, x0, y0 + sy - 0.001, c - sx, sx, 0.001, sx, cell.u, cell.v, sh.top)
          else
            quad(b, 3, x0, y0 + sy - 0.001, a, sx, 0.001, c - a, cell.u, cell.v, sh.top)
          end
        end)
        if j < ny then
          local dn = grid[j + 1] and grid[j + 1][i2]
          exposedPieces(za, zb, dn and dn.za, dn and dn.zb, function(a, c)
            quad(b, 4, x0, y0, a, sx, 0.001, c - a, cell.u, cell.v, sh.bottom)
          end)
        end
      end
    end
  end
  return #b.verts / 4 - before
end

-- THE LAYERS OF A TREE. A tree can be made of several stacked cards (hat / middle /
-- base). Cards of one shape whose centres are within GT.LAYER_GROUP world units
-- of each other are ONE tree; inside it the cards are ranked from the top (1 = the
-- highest card) and that rank is the card's layer in GT.LAYER_OFFSET. This holds
-- for normal trees and for border (conttree) strips alike. Returns comp -> layer
-- (nil for a card that is alone: it takes GT.SINGLE_OFFSET as one whole piece).
local function cardLayers(positions, comps, strip, shapeKey)
  local out = {}
  local dist = tonumber(GT.LAYER_GROUP) or 0
  if strip and tonumber(GT.STRIP_LAYER_GROUP) then dist = tonumber(GT.STRIP_LAYER_GROUP) end
  if dist <= 0 or #comps < 2 then
    -- For strip trees with 1 card, assign layer based on vertical position
    if strip and #comps == 1 then
      local comp = comps[1]
      local y0, y1 = math.huge, -math.huge
      for _, i in ipairs(comp) do
        local p = positions[i]
        y0, y1 = math.min(y0, p[2]), math.max(y1, p[2])
      end
      local y = (y0 + y1) / 2
      -- Assign layer based on height: > 15 = top (1), 8-15 = middle (2), < 8 = bottom (3)
      if y > 15 then
        out[1] = 1  -- Use index as key
      elseif y > 8 then
        out[1] = 2
      else
        out[1] = 3
      end
    end
    return out
  end
  local info = {}
  for n, comp in ipairs(comps) do
    local x0, x1, y0, y1, z0, z1, v0 = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge, math.huge
    for _, i in ipairs(comp) do
      local p = positions[i]
      x0, x1 = math.min(x0, p[1]), math.max(x1, p[1])
      y0, y1 = math.min(y0, p[2]), math.max(y1, p[2])
      z0, z1 = math.min(z0, p[3]), math.max(z1, p[3])
      v0 = math.min(v0, p[5])
    end
    info[n] = { comp = comp, cx = (x0 + x1) / 2, cz = (z0 + z1) / 2, y = (y0 + y1) / 2, v = v0 }
  end
  -- Normal trees: a card joins the first group whose FIRST card is near.
  -- Border strips: a card joins a group if it is near ANY card in it, and a card
  -- that is near two groups links them into one tree.
  local function isNear(g, e)
    if not strip then
      local f = g[1]
      return math.abs(e.cx - f.cx) <= dist and math.abs(e.cz - f.cz) <= dist
    end
    for _, f in ipairs(g) do
      if math.abs(e.cx - f.cx) <= dist and math.abs(e.cz - f.cz) <= dist then return true end
    end
    return false
  end
  local raw = {}
  for n = 1, #info do
    local hit
    for gi = 1, #raw do
      local g = raw[gi]
      if g and isNear(g, info[n]) then
        if not hit then
          hit = g
          g[#g + 1] = info[n]
        elseif strip then
          for _, e in ipairs(g) do hit[#hit + 1] = e end
          raw[gi] = false
        end
      end
    end
    if not hit then raw[#raw + 1] = { info[n] } end
  end
  local group = {}
  for _, g in ipairs(raw) do
    if g then group[#group + 1] = g end
  end
  if strip then                              -- what the grouping found, so a wrong GT.STRIP_LAYER_GROUP can be SEEN
    local parts = {}
    for gi, g in ipairs(group) do
      if gi > 6 then break end
      local s = {}
      for _, e in ipairs(g) do s[#s + 1] = ("y%.0f/z%.0f/x%.0f"):format(e.y, e.cz, e.cx) end
      parts[#parts + 1] = ("[%d cards: %s]"):format(#g, table.concat(s, " "))
    end
    once("stripgroups:" .. #comps .. ":" .. #group,
         "border shape: %d cards -> %d groups (reach %.0f; each card is y/z/x of its centre): %s",
         #comps, #group, dist, table.concat(parts, " "))
  end
  for _, g in ipairs(group) do
    if #g >= 2 then
      table.sort(g, function(a, c)
        if math.abs(a.y - c.y) > 0.5 then return a.y > c.y end
        if a.v ~= c.v then return a.v < c.v end
        return a.cz > c.cz
      end)
      -- For strip trees, map position in group to layer 1/2/3 based on height
      -- If group has 2 cards: top=1, bottom=3 (skip middle)
      -- If group has 3+ cards: top=1, middle=2, bottom=3
      for k, e in ipairs(g) do
        local layer
        if strip then
          if #g == 2 then
            layer = (k == 1) and 1 or 3  -- skip layer 2 for 2-card groups
          else
            layer = math.min(k, 3)
          end
        else
          layer = k
        end
        -- Find the comp index in the original comps array
        local compIndex
        for idx, c in ipairs(comps) do
          if c == e.comp then compIndex = idx; break end
        end
        if compIndex then out[compIndex] = layer end
        if strip then
          once("layerassign:" .. tostring(shapeKey) .. ":" .. k .. ":" .. e.y .. ":" .. layer,
               "Strip %s card #%d at y=%.1f assigned layer %d (group size %d)", tostring(shapeKey), k, e.y, layer, #g)
        end
      end
    end
  end
  return out
end

-- One card -> trees in bucket `b`. A wide card is the same sprite tiled
-- (`conttree*`): one tree per texture repeat.
local function buildCard(b, tex, positions, comp, strip, layer, shapeKey)
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
  -- The card's lean as a shift from its foot to its top, read off its own vertices
  -- (top centroid minus base centroid). FLAT trees follow it so they stand where the
  -- native billboard did, and take the card's VERTICAL extent as their height.
  local leanX, leanZ = 0, 0
  if GT.FLAT then
    local tx, tz, tn, bx2, bz2, bn = 0, 0, 0, 0, 0, 0
    for _, i in ipairs(comp) do
      local p = positions[i]
      if p[2] - ymin <= 0.5 then bx2, bz2, bn = bx2 + p[1], bz2 + p[3], bn + 1 end
      if ymax - p[2] <= 0.5 then tx, tz, tn = tx + p[1], tz + p[3], tn + 1 end
    end
    if tn > 0 and bn > 0 then leanX, leanZ = tx / tn - bx2 / bn, tz / tn - bz2 / bn end
  end
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
  if GT.FLAT then height = math.max(1, ymax - ymin) end   -- the card's vertical extent; the lean carries the rest
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
    local m = emitTree(b, tex, a, c, vB, vT, px, baseY, pz, each, height, leanX, leanZ, layer, strip, shapeKey)
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
    local nm = namesOf(s)
    local shapeKey = strip and (nm:find("conttree_t", 1, true) and "conttree_t"
                         or nm:find("conttree_b", 1, true) and "conttree_b") or nil
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
    local layerOfCard = cardLayers(positions, comps, strip, shapeKey)
    do
      local sizes, n1 = {}, 0
      for _, k in pairs(layerOfCard) do sizes[k] = (sizes[k] or 0) + 1; n1 = n1 + 1 end
      once("cardlayers:" .. tostring(tex.path),
           "'%s': %d of %d cards are hat/middle/base layers (cards per layer: %s); the rest are single cards moved whole by SINGLE_OFFSET",
           tostring(tex.path), n1, #comps,
           (function() local t = {} for k = 1, 6 do if sizes[k] then t[#t + 1] = k .. "=" .. sizes[k] end end return table.concat(t, " ") end)())
    end
    for idx, comp in ipairs(comps) do
      local n, failed = buildCard(b, tex, positions, comp, strip, layerOfCard[idx], shapeKey)
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
    local mesh, meshN = finishBucket(b)
    if mesh then out.buckets[#out.buckets + 1] = { mesh = mesh, meshN = meshN, tex = b.tex } end
  end
  out.coveredKeys = {}
  for _, s in ipairs(out.shapes) do
    for _, k in ipairs(nameKeys(s)) do out.coveredKeys[k] = true end
  end
  -- Logging disabled for performance
  return out
end

-- ------------------------------------------------------------- window --

local lastSignature = ""

-- Hide native cards for this land's live shape records (the current Ground's
-- copies, which are not the pointers stored when the land was first built).
local function coverLiveShapes(ground, land, entry, active, names)
  local keys = entry.coveredKeys
  if not keys then
    keys = {}
    for _, s in ipairs(entry.shapes or {}) do
      for _, k in ipairs(nameKeys(s)) do keys[k] = true end
    end
    entry.coveredKeys = keys
  end
  for _, s in ipairs(entry.shapes or {}) do
    active[s] = true
    for _, k in ipairs(nameKeys(s)) do names[k] = true end
  end
  local record = ground.terrain and ground.terrain.chunks and ground.terrain.chunks[land]
  if not record then return end
  local function consider(s)
    for _, k in ipairs(nameKeys(s)) do
      if keys[k] then
        active[s] = true
        names[k] = true
        return
      end
    end
  end
  for _, s in ipairs(record.shapes or {}) do consider(s) end
  for _, object in ipairs(record.objects or {}) do
    local packed = packedFor(ground, object)
    if packed and packed.shapes then
      for _, s in ipairs(packed.shapes) do consider(s) end
    end
  end
end

-- Work out which lands are in the window, build what the budget allows, and
-- publish GT.active (shape records covered RIGHT NOW). Idempotent per frame;
-- Gen4Hide calls it before the native pass, GT.draw calls it again.
function GT.prepare(ground)
  local view = ground and ground.view3d
  if not (GT.enabled and ground and view and ground.grid and ground.terrain
          and ground.slice and ground.chunkPx and ground.half and ground.set) then
    GT.active, GT.list, GT.coveredNames, GT.coveredLands = {}, {}, {}, {}
    return
  end

  local grid, px, half = ground.grid, ground.chunkPx, ground.half
  local W = GT.WINDOW
  local camCx, camCy = math.floor(view.x / px), math.floor(view.z / px)

  -- DRAW DISTANCE. Only lands within `reach` of the eye get voxel trees; past
  -- it Platinum's flat cards keep drawing (Gen4Hide only hides covered lands).
  local reach = math.huge
  if Distance and Distance.reach then
    local okR, r = pcall(Distance.reach, px)
    if okR and tonumber(r) then reach = r end
  end
  GT.limited = reach ~= math.huge

  -- MEMO. Once every land of the window is built, the answer (which shapes are
  -- covered, which lands to draw) only changes when the camera moves a quarter
  -- chunk (the reach is measured to a land's NEAREST EDGE, so the chunk the
  -- camera stands in is not fine enough) -- or when Ground is replaced (new
  -- shape pointers to hide), or the draw distance changes.
  local qx, qy = math.floor(view.x * 4 / px), math.floor(view.z * 4 / px)
  if window.done and window.ground == ground and window.qx == qx
      and window.qy == qy and window.W == W and window.reach == reach then
    GT.active, GT.list, GT.coveredNames, GT.coveredLands =
      window.active, window.list, window.names, window.lands
    return
  end

  tick = tick + 1
  local want = {}
  local keepReach = reach * GT.HYSTERESIS
  for cy = camCy - W, camCy + W do
    for cx = camCx - W, camCx + W do
      if cx >= 0 and cy >= 0 and cx < grid.width and cy < grid.height then
        local land = grid.land[cy * grid.width + cx + 1]
        local lx, lz = cx * px + half, cy * px + half
        -- built lands get the wider (hysteresis) reach; new ones must be inside the plain one
        local r = (land and landEntries[land]) and keepReach or reach
        if Distance and Distance.landInReach then
          if Distance.landInReach(view.x, view.z, lx, lz, px, r) then
            local dx, dz = lx - view.x, lz - view.z
            want[#want + 1] = { dx * dx + dz * dz, cx, cy, land }
          end
        else
          local dx, dz = cx - camCx, cy - camCy
          want[#want + 1] = { dx * dx + dz * dz, cx, cy, land }
        end
      end
    end
  end
  table.sort(want, function(a, b) return a[1] < b[1] end)

  local builds = 0
  local sig = {}
  local failedNames = {}
  local missing = 0
  for _, w in ipairs(want) do
    if not landEntries[w[4]] then missing = missing + 1 end
  end
  -- a window that is still filling gets the larger shared limit, so the old
  -- cards are not on screen beside the new trees for long
  local warm = missing > 1
  local cap = Budget.covered and 12 or GT.BUILDS_PER_FRAME
  local pending = 0
  local active, list, names, lands = {}, {}, {}, {}
  for _, w in ipairs(want) do
    local land = w[4]
    local entry = land and landEntries[land]
    if not entry then
      if builds < cap and Budget.allow(warm) then
        builds = builds + 1
        local t0 = clock()
        local ok, built = pcall(buildLand, ground, land)
        Budget.charge(t0, "trees")
        if ok then
          entry = built
        else
          entry = { buckets = {}, shapes = {}, quads = 0, failed = {}, coveredKeys = {} }
          once("build", "a land chunk failed to build and was skipped: %s", tostring(built))
        end
        landEntries[land] = entry
        resident = resident + 1
      else
        pending = pending + 1
      end
    end
    if entry then
      entry.used = tick
      lands[land] = true
      sig[#sig + 1] = tostring(land)
      coverLiveShapes(ground, land, entry, active, names)
      for k in pairs(entry.failed or {}) do failedNames[k] = true end
      if #entry.buckets > 0 then
        list[#list + 1] = { entry = entry, x = w[2] * px + half, z = w[3] * px + half }
      end
    end
  end
  -- a name that failed in ANY land of the window is not safe to hide by name
  for k in pairs(failedNames) do names[k] = nil end
  local signature = table.concat(sig, ",")
  if signature ~= lastSignature or window.ground ~= ground then
    lastSignature = signature
    GT.coverVersion = GT.coverVersion + 1
  end

  -- Publish after the fill so a Ground swap does not clear hide/draw for a
  -- frame while overlapping lands are already in landEntries.
  GT.active, GT.list, GT.coveredNames, GT.coveredLands = active, list, names, lands
  window.ground, window.qx, window.qy, window.W, window.reach = ground, qx, qy, W, reach
  window.active, window.list, window.names, window.lands = active, list, names, lands
  window.done = pending == 0

  -- EVICT. landEntries was never freed before invalidate(), so every land the
  -- player had ever walked past kept its baked trees in GPU memory. Keep the
  -- most recently wanted ones and release the rest (oldest first); a released
  -- land simply rebuilds if the player walks back.
  local cap = GT.limited and GT.MAX_RESIDENT or GT.MAX_RESIDENT_MAX
  if resident > cap then
    local old = {}
    for land, entry in pairs(landEntries) do
      if entry.used ~= tick then old[#old + 1] = { entry.used or 0, land, entry } end
    end
    table.sort(old, function(a, b) return a[1] < b[1] end)
    local i = 1
    while resident > cap and old[i] do
      local item = old[i]
      for _, b in ipairs(item[3].buckets or {}) do
        if b.mesh and b.mesh.release then pcall(b.mesh.release, b.mesh) end
        if b.meshN and b.meshN.release then pcall(b.meshN.release, b.meshN) end
      end
      landEntries[item[2]] = nil
      resident = resident - 1
      i = i + 1
    end
    once("evict", "released baked tree lands past the draw distance (keeping %d)", cap)
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
function GT.isCoveredName(shape, land)
  local names = GT.coveredNames
  if not (shape and names) then return false end
  -- With a finite draw distance a name covers only the lands inside it: a
  -- terrain shape of a FAR land keeps its native cards (nothing replaces them).
  if land ~= nil and GT.limited and not GT.coveredLands[land] then return false end
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
  -- Every land in the window used to be drawn whatever the camera was looking
  -- at (~2M quads on Route 202). Skip the lands that are wholly outside the
  -- view cone; the radius is the land's half-diagonal plus tree height and
  -- terrain relief, so a visible tree is never dropped.
  local visible = scene.sphereVisible
  local ground = scene.ground
  local radius = ((ground and ground.chunkPx) or 512) * 0.72 + 160
  local drawn = 0
  -- CAMERA MODE: the engine turns its native tree cards to face the camera
  -- every frame (Gen4Model's turnToCamera, billboardYaw = view.yaw); a baked
  -- tree cannot turn, so it is baked lit from the south AND from the north
  -- (b.mesh / b.meshN) and the one whose lit end looks at the camera is drawn.
  -- Looking north (forward z < 0) the camera is south of the trees, so the
  -- south-lit mesh; looking south, the north-lit one. A small dead band keeps
  -- the choice from flickering when the view runs along east-west.
  local lookZ = scene.forward and scene.forward[3] or 0
  if lookZ > 0.05 then northLit = true elseif lookZ < -0.05 then northLit = false end
  for _, item in ipairs(GT.list) do
    if (not visible) or visible(item.x, 0, item.z, radius) then
      drawn = drawn + 1
      for _, b in ipairs(item.entry.buckets) do
        local mesh = (northLit and b.meshN) or b.mesh
        Voxel3D.draw(mesh, b.tex, Mat4.translate(item.x, GT.Y_OFFSET or 0, item.z), 0, nil, 0, false)
      end
    end
  end
  GT.lastDrawn, GT.lastTotal = drawn, #GT.list
  if visible and drawn < #GT.list then
    once("cull", "view culling skips tree lands the camera cannot see (%d of %d drawn this frame)",
         drawn, #GT.list)
  end
  Voxel3D.seams(true)
  Voxel3D.glass(true)
end

-- Drop every baked tree: a map was edited, or the mod was reloaded.
function GT.invalidate()
  for _, entry in pairs(landEntries) do
    for _, b in ipairs(entry.buckets or {}) do
      if b.mesh and b.mesh.release then pcall(b.mesh.release, b.mesh) end
      if b.meshN and b.meshN.release then pcall(b.meshN.release, b.meshN) end
    end
  end
  landEntries = setmetatable({}, { __mode = "k" })
  resident = 0
  window = {}
  lastSignature = ""
  textures = {}
  warned = {}                      -- so the layer log prints again after a re-bake
  GT.active, GT.list, GT.coveredNames, GT.coveredLands = {}, {}, {}, {}
  GT.coverVersion = GT.coverVersion + 1
end

-- Turn the trees: "south" / "north" / "east" / "west" or a compass bearing.
-- The shade is baked into each land's mesh, so this drops the baked lands and
-- the next frame rebuilds them facing the new way.
function GT.setFacing(value)
  GT.FACING = value
  GT.invalidate()
end

-- Move one layer: GT.setLayerOffset(layer, x, y, z), layer 1 = hat, 2 = middle,
-- 3 = base, world units, nil = leave that axis as it is. Re-bakes at once, so the
-- trees on screen update -- the quick way to pair the layers before writing the
-- numbers into GT.LAYER_OFFSET.
function GT.setLayerOffset(layer, x, y, z)
  if type(GT.LAYER_OFFSET) ~= "table" then GT.LAYER_OFFSET = {} end
  local o = GT.LAYER_OFFSET[layer]
  if type(o) ~= "table" then o = { x = 0, y = 0, z = 0 }; GT.LAYER_OFFSET[layer] = o end
  if x ~= nil then o.x = x end
  if y ~= nil then o.y = y end
  if z ~= nil then o.z = z end
  GT.invalidate()
end

-- Same as setLayerOffset, but for the border (conttree) trees only. If
-- GT.STRIP_LAYER_OFFSET is false this starts it as a copy of LAYER_OFFSET.
function GT.setStripLayerOffset(layer, x, y, z)
  if type(GT.STRIP_LAYER_OFFSET) ~= "table" then
    GT.STRIP_LAYER_OFFSET = {}
    for k = 1, 3 do
      local o = type(GT.LAYER_OFFSET) == "table" and GT.LAYER_OFFSET[k] or {}
      GT.STRIP_LAYER_OFFSET[k] = { x = o.x or 0, y = o.y or 0, z = o.z or 0 }
    end
  end
  local o = GT.STRIP_LAYER_OFFSET[layer]
  if type(o) ~= "table" then o = { x = 0, y = 0, z = 0 }; GT.STRIP_LAYER_OFFSET[layer] = o end
  if x ~= nil then o.x = x end
  if y ~= nil then o.y = y end
  if z ~= nil then o.z = z end
  GT.invalidate()
end

-- Per-shape offset setter for border trees. shape = "conttree_t" or "conttree_b",
-- layer = 1/2/3, x/y/z = world units (nil = leave unchanged). Re-bakes at once.
function GT.setStripShapeOffset(shape, layer, x, y, z)
  GT.STRIP_SHAPE_OFFSET = GT.STRIP_SHAPE_OFFSET or {}
  local t = GT.STRIP_SHAPE_OFFSET[shape]
  if type(t) ~= "table" then t = {}; GT.STRIP_SHAPE_OFFSET[shape] = t end
  local o = t[layer]
  if type(o) ~= "table" then o = { x = 0, y = 0, z = 0 }; t[layer] = o end
  if x ~= nil then o.x = x end
  if y ~= nil then o.y = y end
  if z ~= nil then o.z = z end
  GT.invalidate()
end

-- built lands currently held (tests and the log read this)
function GT.residentCount() return resident end

return GT