-- Run from the mod root with: texlua tools/test_gen4_flowers.lua
-- Stubs the engine (no LOVE, no ROM) and drives the REAL Gen4Flowers, Gen4Lawn and
-- Gen4Hide through the same wrapper chain main.lua installs (Hide first, then Lawn).
local fails, passes = 0, 0
local function check(c, m) if c then passes = passes + 1 else fails = fails + 1; print("FAIL: " .. m) end end

-- ------------------------------------------------------------------ stubs --
local drawCalls = {}
local state = { seams = true, glass = true }
local Voxel3D
Voxel3D = {
  FACE_CORNERS = {
    [1] = { { 1, 0, 0 }, { 1, 0, 1 }, { 1, 1, 1 }, { 1, 1, 0 } },
    [2] = { { 0, 0, 1 }, { 0, 0, 0 }, { 0, 1, 0 }, { 0, 1, 1 } },
    [3] = { { 0, 1, 0 }, { 1, 1, 0 }, { 1, 1, 1 }, { 0, 1, 1 } },
    [4] = { { 0, 0, 1 }, { 1, 0, 1 }, { 1, 0, 0 }, { 0, 0, 0 } },
    [5] = { { 0, 0, 1 }, { 1, 0, 1 }, { 1, 1, 1 }, { 0, 1, 1 } },
    [6] = { { 1, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 } },
  },
  newMesh = function(verts, map)
    if #verts == 0 then return nil end
    return { verts = verts, map = map, release = function() end }
  end,
  seams = function(on) state.seams = on end,
  glass = function(on) state.glass = on end,
  draw = function(mesh, tex, model, pull, sun, sway, water)
    drawCalls[#drawCalls + 1] = { mesh = mesh, tex = tex, model = model, sway = sway, grassH = Voxel3D.grassH }
  end,
}
local Mat4 = { translate = function(x, y, z) return { x, y, z } end }
local Wind = { FLOWER_SHARE = 0.5, amount = function() return 1.0 end, load = function() return 0, 0, 0 end }

-- a 64x64 "grass.png": a green ramp, brown tips and transparent columns that must NOT count as foliage
local fakeGrass = { isGrass = true }
local function grassPixel(x, y)
  if (x + y) % 11 == 0 then return 0.55, 0.35, 0.15, 1 end
  if x % 13 == 0 then return 0, 0, 0, 0 end
  local t = (x * 3 + y * 5) % 40 / 40
  return 0.10 + 0.2 * t, 0.35 + 0.45 * t, 0.08 + 0.1 * t, 1
end
local atlas
local grassReadable = true
love = {
  filesystem = {
    read = function(p) if grassReadable and p:find("grass.png", 1, true) then return "PNGBYTES" end end,
    newFileData = function() return fakeGrass end,
  },
  image = {
    newImageData = function(a)
      if a == fakeGrass then
        return { getWidth = function() return 64 end, getHeight = function() return 64 end,
                 getPixel = function(_, x, y) return grassPixel(x, y) end }
      end
      local px = {}
      atlas = { px = px, setPixel = function(_, x, y, r, g, b) px[x .. "," .. y] = { r, g, b } end }
      return atlas
    end,
  },
  graphics = { newImage = function(d) return { data = d, setFilter = function() end } end },
  timer = { getTime = function() return 0 end },
}

local V = { path = "mods/terri_mod", logs = {} }
V.mod = { log = { info = function(_, m) V.logs[#V.logs + 1] = m end } }
local loaded = {}
local ALLOW = { Gen4Flowers = true, Gen4Lawn = true, Gen4Hide = true }
V.require = function(name)
  if name == "Voxel3D" then return Voxel3D end
  if name == "Mat4" then return Mat4 end
  if name == "Wind" then return Wind end
  if name == "Gen4Rocks" then return { version = 0 } end      -- Lawn's other whenBuilt source
  if not ALLOW[name] then error("module not available in this test: " .. name) end
  if not loaded[name] then loaded[name] = assert(loadfile("lib/" .. name .. ".lua"))(V) end
  return loaded[name]
end

-- ----------------------------------------------------- fake terrain shapes --
local POS_SCALE = 32
local function s16(n)
  n = math.floor(n + 0.5)
  if n < 0 then n = n + 65536 end
  return string.char(n % 256, math.floor(n / 256))
end
-- positions in world units are stored the way the cartridge cache does: fixed point / 4096 * posScale
local function shape(name, tex, verts, tris, scale)
  scale = scale or POS_SCALE
  local vb, ib = {}, {}
  for _, v in ipairs(verts) do
    vb[#vb + 1] = s16(v[1] / scale * 4096) .. s16(v[2] / scale * 4096) .. s16(v[3] / scale * 4096)
                  .. s16(0) .. s16(0) .. s16(0)                       -- 12-byte stride
  end
  for _, t in ipairs(tris) do
    ib[#ib + 1] = s16(t[1] - 1) .. s16(t[2] - 1) .. s16(t[3] - 1)
  end
  return { name = name, texture = tex, material = "m_" .. name, vertices = table.concat(vb),
           indices = table.concat(ib), vertexCount = #verts, triangleCount = #tris }
end
local function floorQuad(name, tex, half, y, scale)
  return shape(name, tex, { { -half, y, -half }, { half, y, -half }, { half, y, half }, { -half, y, half } },
               { { 1, 2, 3 }, { 1, 3, 4 } }, scale)
end
-- upright cards: n vertical quads (facing +z), 16 wide and 12 tall, standing at the given z
local function cardsShape(name, tex, zs)
  local verts, tris = {}, {}
  for i, z in ipairs(zs) do
    local x0 = (i - 1) * 24
    local b = #verts
    verts[b + 1], verts[b + 2], verts[b + 3], verts[b + 4] =
      { x0, 5, z }, { x0 + 16, 5, z }, { x0 + 16, 17, z }, { x0, 17, z }
    tris[#tris + 1] = { b + 1, b + 2, b + 3 }
    tris[#tris + 1] = { b + 1, b + 3, b + 4 }
  end
  return shape(name, tex, verts, tris)
end

local lands = {
  FLAT = { posScale = POS_SCALE, shapes = {
    floorQuad("bed", "nhana", 32, 10),                       -- 64x64 = 16 cells -> 32 flowers
    floorQuad("rocks", "imped", 32, 10),                     -- not a bed: ignored
  } },
  CARDS = { posScale = POS_SCALE, shapes = {
    cardsShape("onlycards", "nhana", { 0, 8, 16 }),          -- 3 upright cards
    false,                                                   -- replaced below by the mixed shape
  } },
  PREFIX = { posScale = POS_SCALE, shapes = { floorQuad("variant", "Nhana_B", 16, 3) } },
  CAP = { posScale = 512, shapes = { floorQuad("meadow", "nhana", 1000, 0, 512) } },
}

-- the mixed shape needs real mixed geometry in ONE shape: one card + one floor triangle
do
  local verts = { { 40, 5, 0 }, { 56, 5, 0 }, { 56, 17, 0 }, { 40, 17, 0 },   -- card (2 tris)
                  { 0, 5, 20 }, { 12, 5, 20 }, { 0, 5, 32 } }                 -- floor triangle
  lands.CARDS.shapes[2] = shape("mixed", "nhana", verts, { { 1, 2, 3 }, { 1, 3, 4 }, { 5, 6, 7 } })
end

-- ----------------------------------------------------------- engine stubs --
local modelDraws = {}
local models = {}
local Model = { draw = function(self, vp, pose, materials)
  modelDraws[#modelDraws + 1] = { shapes = self.shapes, materials = materials, land = self.tag }
end }
local Ground = {
  terrain = { chunks = lands },
  grid = { width = 4, height = 1, land = { "FLAT", "CARDS", "PREFIX", "CAP" } },
  view3d = { x = 256, z = 256 }, chunkPx = 512, half = 256,
  slice = function() return nil end,
}
function Ground:modelFor(land)
  local m = models[land]
  if not m then
    m = { tag = land, shapes = {} }
    for _, s in ipairs(lands[land].shapes) do m.shapes[#m.shapes + 1] = { name = s.name, material = s.material } end
    models[land] = m
  end
  return m
end
local drawOrder = { "FLAT", "CARDS" }
function Ground:drawFree()
  for _, land in ipairs(drawOrder) do Model.draw(self:modelFor(land), "vp", "pose", nil) end
  return true
end
package.loaded["src.render.Gen4Model"] = Model
package.loaded["src.render.Gen4Ground"] = Ground
package.loaded["src.render.Assets"] = { exists = function(p) return p:find("grass.png", 1, true) ~= nil end }

local Flowers = V.require("Gen4Flowers")
local Hide = V.require("Gen4Hide")
local Lawn = V.require("Gen4Lawn")
Lawn.LOG_NAMES = false

local function drawFrame()
  modelDraws = {}
  Ground:drawFree()
  local byLand = {}
  for _, d in ipairs(modelDraws) do byLand[d.land] = d end
  return byLand
end
local function names(shapes) local t = {} for _, s in ipairs(shapes) do t[#t + 1] = s.name end return table.concat(t, ",") end

-- ============================================================ 1. gating ===
-- Flowers off first: nothing is built, nothing is hidden, nhana keeps its native look.
Flowers.enabled = false
check(Hide.install() == true, "Hide installs on the stub ground")
check(Lawn.install() == true, "Lawn installs after Hide (main.lua's order)")
local f = drawFrame()
check(f.FLAT.materials == nil or f.FLAT.materials.m_bed == nil, "flowers OFF: the bed keeps its native texture")
check(names(f.CARDS.shapes) == "onlycards,mixed", "flowers OFF: no native card is hidden")
check(Flowers.isBuilt("FLAT") == false, "flowers OFF: isBuilt is false")

-- ====================================================== 2. flat bed, ON ===
Flowers.enabled = true
f = drawFrame()
check(Flowers.isBuilt("FLAT"), "FLAT land is built once enabled")
local m = f.FLAT.materials and f.FLAT.materials.m_bed
check(m ~= nil and m.image:find("grass.png", 1, true) ~= nil,
      "Lawn paints the nhana floor with grass.png on the first frame flowers exist (cache sees the new version)")
check(f.FLAT.materials.m_rocks == nil, "a non-nhana shape is not repainted")
check(names(f.FLAT.shapes) == "bed,rocks", "a FLAT bed's floor is never hidden (no hole under the flowers)")

-- ============================================ 3. cards hidden only if all ===
check(names(f.CARDS.shapes) == "mixed", "all-card shape hidden; mixed card+floor shape kept (got '" .. names(f.CARDS.shapes) .. "')")
check(Flowers.isBuilt("CARDS"), "CARDS land built")
check(Flowers.isBuilt("PREFIX"), "prefix-matched, mixed-case 'Nhana_B' counts as a bed")

-- Built, then switched OFF: the grass.png floor and the card hiding must go with the flowers
-- (Lawn's cache has to notice the switch), and come back when they are switched on again.
Flowers.enabled = false
local off = drawFrame()
check(off.FLAT.materials == nil or off.FLAT.materials.m_bed == nil,
      "switched off after being built: the bed floor goes back to its native texture")
check(names(off.CARDS.shapes) == "onlycards,mixed", "switched off after being built: native cards come back")
Flowers.enabled = true
local on = drawFrame()
check(on.FLAT.materials and on.FLAT.materials.m_bed and on.FLAT.materials.m_bed.image:find("grass.png", 1, true),
      "switched back on: grass.png floor returns")
check(names(on.CARDS.shapes) == "mixed", "switched back on: all-card shape hidden again")

-- ======================================================= 4. counts/geometry ===
drawCalls = {}
Flowers.draw({ ground = Ground, sphereVisible = function() return true end })
check(#drawCalls >= 3, "draw issues calls for the lands in the window (got " .. #drawCalls .. ")")
local totalVerts, flowerQuads = 0, 29
local bad = 0
for _, c in ipairs(drawCalls) do
  totalVerts = totalVerts + #c.mesh.verts
  for _, v in ipairs(c.mesh.verts) do
    for i = 1, 6 do if v[i] ~= v[i] or v[i] == math.huge or v[i] == -math.huge then bad = bad + 1 end end
    if not (v[4] > 0 and v[4] < 1 and v[5] > 0 and v[5] < 1) then bad = bad + 1 end
  end
  check(#c.mesh.map % 6 == 0 and #c.mesh.verts % 4 == 0, "mesh holds whole quads")
end
check(bad == 0, "no NaN/inf and every UV is inside the atlas (" .. bad .. " bad)")
-- FLAT: 64x64 at density 2 = exactly 32 flowers * 29 quads * 4 verts
local flatCall
for _, c in ipairs(drawCalls) do if c.model[1] == 256 and c.model[2] == 10 then flatCall = c end end
check(flatCall ~= nil, "FLAT bed is drawn translated up to its terrace height (y = 10)")
check(flatCall and #flatCall.mesh.verts == 32 * flowerQuads * 4,
      "FLAT bed: 32 flowers (got " .. (flatCall and #flatCall.mesh.verts / (flowerQuads * 4) or 0) .. ")")
if flatCall then
  local minx, maxx, miny, maxy = 1e9, -1e9, 1e9, -1e9
  for _, v in ipairs(flatCall.mesh.verts) do
    minx, maxx = math.min(minx, v[1]), math.max(maxx, v[1])
    miny, maxy = math.min(miny, v[2]), math.max(maxy, v[2])
  end
  check(minx > -32 - 4 and maxx < 32 + 4, "flowers stay on the bed (x " .. minx .. " .. " .. maxx .. ")")
  check(miny >= -0.5 and maxy <= Flowers.HEIGHT_MAX + 1.5, "stems are planted and stay under their height (y " .. miny .. " .. " .. maxy .. ")")
end
check(drawCalls[1].sway == 0.5, "sway = Wind.amount * FLOWER_SHARE (" .. tostring(drawCalls[1].sway) .. ")")
check(drawCalls[1].grassH == Flowers.HEIGHT_MAX + 2, "bend height is set for the draw")
check(Voxel3D.grassH == nil and Voxel3D.grassLoad == nil, "bend height/load are restored after the draw")
check(state.seams and state.glass, "seams/glass passes are switched back on")

-- ============================================================ 5. density cap ===
Ground.view3d.x = 3 * 512 + 256          -- camera over the CAP land
for _ = 1, 3 do drawFrame() end
drawCalls = {}
Flowers.draw({ ground = Ground })
local capVerts, capMeshes, biggest = 0, 0, 0
for _, c in ipairs(drawCalls) do
  if c.model[1] == 3 * 512 + 256 then
    capMeshes = capMeshes + 1
    capVerts = capVerts + #c.mesh.verts
    biggest = math.max(biggest, #c.mesh.verts)
  end
end
local capFlowers = capVerts / (flowerQuads * 4)
check(capFlowers <= Flowers.MAX_PER_LAND + 5 and capFlowers >= Flowers.MAX_PER_LAND * 0.9,
      "a 4,000,000 sq-unit meadow is thinned to the cap (got " .. capFlowers .. " of " .. Flowers.MAX_PER_LAND .. ")")
check(capMeshes >= 3 and biggest <= Flowers.MAX_VERTS + 29 * 4,
      "a big land is split into several meshes under the 16-bit limit (" .. capMeshes .. " meshes, biggest " .. biggest .. ")")

-- ============================================================= 6. texture ===
-- the atlas was built from grass.png
local function px(x, y) return atlas.px[x .. "," .. y] end
local greensOK, ascending, last = true, true, -1
for x = 0, 7 do
  local c = px(x, 2)
  if not (c and c[2] >= c[1] and c[2] >= c[3] and c[2] > 0.3) then greensOK = false end
  local luma = c and (0.3 * c[1] + 0.59 * c[2] + 0.11 * c[3]) or 0
  if luma < last - 1e-9 then ascending = false end
  last = luma
end
check(greensOK, "foliage row is all green texels sampled from grass.png (brown tips and transparent texels excluded)")
check(ascending, "foliage row runs dark to light")
check(px(0, 0)[1] == Flowers.PETALS[1][1] and px(2, 1)[2] == Flowers.CENTRES[3][2], "petal and centre rows come from the palette")
local sampled = false
for _, l in ipairs(V.logs) do if l:find("sampled from", 1, true) then sampled = true end end
check(sampled, "the log says the foliage colours came from grass.png")

-- ========================================================== 7. determinism ===
local before = flatCall and flatCall.mesh.verts[1]
local x1, y1, z1 = before[1], before[2], before[3]
Flowers.invalidate()
grassReadable = false                      -- and exercise the fallback while we are here
Ground.view3d.x = 256
for _ = 1, 2 do drawFrame() end
drawCalls = {}
Flowers.draw({ ground = Ground })
local again
for _, c in ipairs(drawCalls) do if c.model[1] == 256 and c.model[2] == 10 then again = c end end
check(again and again.mesh.verts[1][1] == x1 and again.mesh.verts[1][2] == y1 and again.mesh.verts[1][3] == z1,
      "rebuilding a bed gives the same flowers (no shimmer between builds)")
local fallbackOK = true
for x = 0, 7 do
  local c, g = px(x, 2), Flowers.FALLBACK_GREENS[x + 1]
  if not (c and c[1] == g[1] and c[2] == g[2] and c[3] == g[3]) then fallbackOK = false end
end
check(fallbackOK, "grass.png unreadable -> built-in greens, no error")

-- ================================================ 8. Bridge/uninstall paths ===
Flowers.invalidate()
check(Flowers.isBuilt("FLAT") == false, "invalidate drops every built land")
Lawn.uninstall(); Hide.uninstall()
check(Lawn.installed == false and Hide.installed == false, "both uninstall cleanly")

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
