-- Run from the mod root with: texlua tools/test_gen4_fence.lua
-- Stubs the engine (no LOVE, no ROM) and drives the REAL Gen4Fence, Gen4Rocks and
-- Gen4Hide through the same wrapper chain main.lua installs.
local fails, passes = 0, 0
local function check(c, m) if c then passes = passes + 1 else fails = fails + 1; print("FAIL: " .. m) end end

-- ------------------------------------------------------------------ stubs --
local drawCalls = {}
local state = { seams = true, glass = true }
local Voxel3D = {
  FACE_CORNERS = {},
  newMesh = function(verts, map)
    if #verts == 0 then return nil end
    return { verts = verts, map = map, release = function() end }
  end,
  seams = function(on) state.seams = on end,
  glass = function(on) state.glass = on end,
  draw = function(mesh, tex, model) drawCalls[#drawCalls + 1] = { mesh = mesh, tex = tex, model = model } end,
}
local Mat4 = { translate = function(x, y, z) return { x, y, z } end }
love = {
  image = { newImageData = function() return { setPixel = function() end } end },
  graphics = { newImage = function(d) return { data = d, setFilter = function() end } end },
  timer = { getTime = function() return 0 end },
}
local V = { path = "mods/terri_mod", logs = {} }
V.mod = { log = { info = function(_, m) V.logs[#V.logs + 1] = m end } }
local loaded = {}
local ALLOW = { Gen4Fence = true, Gen4Rocks = true, Gen4Hide = true }
V.require = function(name)
  if name == "Voxel3D" then return Voxel3D end
  if name == "Mat4" then return Mat4 end
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
local function shape(name, tex, verts, tris)
  local vb, ib = {}, {}
  for _, v in ipairs(verts) do
    vb[#vb + 1] = s16(v[1] / POS_SCALE * 4096) .. s16(v[2] / POS_SCALE * 4096) .. s16(v[3] / POS_SCALE * 4096)
                  .. s16(0) .. s16(0) .. s16(0)
  end
  for _, t in ipairs(tris) do ib[#ib + 1] = s16(t[1] - 1) .. s16(t[2] - 1) .. s16(t[3] - 1) end
  return { name = name, texture = tex, material = "m_" .. name, vertices = table.concat(vb),
           indices = table.concat(ib), vertexCount = #verts, triangleCount = #tris }
end
-- cards: each is 4 corners (bottom-left, bottom-right, top-right, top-left)
local function cardsShape(name, tex, cards, extraVerts, extraTris)
  local verts, tris = {}, {}
  for _, c in ipairs(cards) do
    local b = #verts
    for k = 1, 4 do verts[b + k] = c[k] end
    tris[#tris + 1] = { b + 1, b + 2, b + 3 }
    tris[#tris + 1] = { b + 1, b + 3, b + 4 }
  end
  for _, v in ipairs(extraVerts or {}) do verts[#verts + 1] = v end
  for _, t in ipairs(extraTris or {}) do tris[#tris + 1] = { t[1] + #cards * 4, t[2] + #cards * 4, t[3] + #cards * 4 } end
  return shape(name, tex, verts, tris)
end

-- east-west card LEANING back toward the camera: foot at z=100, top at z=96
local EW = { { 0, 5, 100 }, { 32, 5, 100 }, { 32, 17, 96 }, { 0, 17, 96 } }
-- north-south card in the YZ plane (seen edge-on: the "line" bug), 48 long
local NS = { { 60, 5, 0 }, { 60, 5, 48 }, { 60, 17, 48 }, { 60, 17, 0 } }
-- sloped east-west card: foot rises 5 -> 9
local SLOPE = { { 100, 5, 20 }, { 132, 9, 20 }, { 132, 21, 20 }, { 100, 17, 20 } }
-- 45 degree card
local DIAG = { { 200, 5, 0 }, { 224, 5, 24 }, { 224, 17, 24 }, { 200, 17, 0 } }
-- a square rock card
local ROCK = { { 300, 5, 0 }, { 316, 5, 0 }, { 316, 21, 0 }, { 300, 21, 0 } }
-- a banner too short to read a direction from (2 long, aspect > 1.75)
local TINY = { { 400, 5, 0 }, { 402, 5, 0 }, { 402, 6, 0 }, { 400, 6, 0 } }

local lands = {
  FENCES = { posScale = POS_SCALE, shapes = {
    cardsShape("ew", "imped", { EW }),
    cardsShape("ns", "imped", { NS }),
    cardsShape("slope", "imped", { SLOPE }),
    cardsShape("diag", "imped", { DIAG }),
    cardsShape("double", "imped", { EW, EW }),                     -- the same card twice
  } },
  MIXED = { posScale = POS_SCALE, shapes = {
    cardsShape("mixed", "imped", { EW, ROCK }),                    -- fence + rock in one shape
    cardsShape("rockonly", "imped", { ROCK }),
  } },
  ODD = { posScale = POS_SCALE, shapes = {
    cardsShape("tiny", "imped", { EW, TINY }),                      -- one card cannot be read
    cardsShape("withfloor", "imped", { EW }, { { 0, 5, 0 }, { 16, 5, 0 }, { 0, 5, 16 } }, { { 1, 2, 3 } }),
    cardsShape("other", "ngrass", { EW }),                          -- not ours
    cardsShape("named", "my_fence01", { ROCK }),                    -- by name: a square card is still a fence
  } },
  NS2 = { posScale = POS_SCALE, shapes = {
    cardsShape("nsrun", "imped", { { { 8, 5, 0 }, { 8, 5, 16 }, { 8, 13, 16 }, { 8, 13, 0 } },
                                   { { 8, 5, 16 }, { 8, 5, 32 }, { 8, 13, 32 }, { 8, 13, 16 } } }),
  } },
}

-- ----------------------------------------------------------- engine stubs --
local modelDraws = {}
local models = {}
local Model = { draw = function(self)
  modelDraws[#modelDraws + 1] = { shapes = self.shapes, land = self.tag }
end }
local Ground = {
  terrain = { chunks = lands },
  grid = { width = 4, height = 1, land = { "FENCES", "MIXED", "ODD", "NS2" } },
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
function Ground:drawFree()
  for _, land in ipairs({ "FENCES", "MIXED", "ODD", "NS2" }) do Model.draw(self:modelFor(land), "vp", "pose", nil) end
  return true
end
package.loaded["src.render.Gen4Model"] = Model
package.loaded["src.render.Gen4Ground"] = Ground

local Fence = V.require("Gen4Fence")
local Rocks = V.require("Gen4Rocks")
local Hide = V.require("Gen4Hide")

local function drawFrame()
  modelDraws = {}
  Ground:drawFree()
  local byLand = {}
  for _, d in ipairs(modelDraws) do byLand[d.land] = d end
  return byLand
end
local function names(shapes) local t = {} for _, s in ipairs(shapes) do t[#t + 1] = s.name end return table.concat(t, ",") end
local function has(str, name) return ("," .. str .. ","):find("," .. name .. ",", 1, true) ~= nil end

-- bounding box of the verts of ONE land's meshes, in land-local space
local function bounds(land)
  local e = Fence.isBuilt(land) and true
  local entry
  for _, c in ipairs(drawCalls) do
    if c.model[1] == ({ FENCES = 256, MIXED = 768, ODD = 1280, NS2 = 1792 })[land] then entry = entry or {}; entry[#entry + 1] = c.mesh end
  end
  local b = { x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9, z0 = 1e9, z1 = -1e9, n = 0 }
  for _, mesh in ipairs(entry or {}) do
    for _, v in ipairs(mesh.verts) do
      b.x0, b.x1 = math.min(b.x0, v[1]), math.max(b.x1, v[1])
      b.y0, b.y1 = math.min(b.y0, v[2]), math.max(b.y1, v[2])
      b.z0, b.z1 = math.min(b.z0, v[3]), math.max(b.z1, v[3])
      b.n = b.n + 1
    end
  end
  return b
end

-- ============================================================ 1. gating ===
Fence.enabled = false
check(Hide.install() == true, "Hide installs on the stub ground")
local f = drawFrame()
check(names(f.FENCES.shapes) == "ew,ns,slope,diag,double", "fences OFF: no native shape is hidden")
check(Fence.isBuilt("FENCES") == false, "fences OFF: nothing is built")

-- ================================================== 2. build + hide, ON ===
Fence.enabled = true
Rocks.enabled = true
for _ = 1, 3 do f = drawFrame() end
check(Fence.isBuilt("FENCES") and Fence.isBuilt("MIXED") and Fence.isBuilt("ODD"), "every land with fence cards is built")
check(names(f.FENCES.shapes) == "", "all-fence shapes are hidden (got '" .. names(f.FENCES.shapes) .. "')")
check(Rocks.isBuilt("MIXED"), "Rocks built the MIXED land (rock card + fence card)")
check(not has(names(f.MIXED.shapes), "mixed"), "a fence+rock shape is hidden once Rocks has built the land")
check(not has(names(f.MIXED.shapes), "rockonly") , "the rock-only shape is still Rocks' to hide")
check(has(names(f.ODD.shapes), "tiny"), "a shape with a card that cannot be read stays NATIVE (no hole)")
check(has(names(f.ODD.shapes), "withfloor"), "a shape with a floor triangle left over stays native")
check(has(names(f.ODD.shapes), "other"), "a non-imped shape is untouched")
check(not has(names(f.ODD.shapes), "named"), "a shape named *fence* converts every card, even a square one")

-- rocks off -> the mixed shape must come back (its boulders are not drawing)
Rocks.enabled = false
f = drawFrame()
check(has(names(f.MIXED.shapes), "mixed"), "Rocks off: the fence+rock shape comes back (no rock would be left)")
Rocks.enabled = true
f = drawFrame()
check(not has(names(f.MIXED.shapes), "mixed"), "Rocks back on: hidden again")

-- ================================================ 3. geometry per orientation ===
drawCalls = {}
Fence.draw({ ground = Ground, sphereVisible = function() return true end })
check(#drawCalls == 3, "draw issues a call per land in the window (" .. #drawCalls .. ")")
check(state.seams and state.glass, "seams/glass are switched back on")
local allVerts, bad = 0, 0
for _, c in ipairs(drawCalls) do
  check(#c.mesh.map % 6 == 0 and #c.mesh.verts % 4 == 0, "mesh holds whole quads")
  for _, v in ipairs(c.mesh.verts) do
    allVerts = allVerts + 1
    for i = 1, 6 do if v[i] ~= v[i] or math.abs(v[i]) == math.huge then bad = bad + 1 end end
    if not (v[4] > 0 and v[4] < 1 and v[5] > 0 and v[5] < 1) then bad = bad + 1 end
  end
end
check(bad == 0, "no NaN/inf and every UV is inside the atlas (" .. bad .. " bad)")

-- FENCES land holds EW, NS, SLOPE, DIAG, a double. Look at runs one at a time with a scratch land.
local function single(card, style)
  Fence.invalidate(); Rocks.invalidate()
  lands.SCRATCH = { posScale = POS_SCALE, shapes = { cardsShape("one", "imped", { card }) } }
  Ground.grid.land = { "SCRATCH", "SCRATCH", "SCRATCH", "SCRATCH" }
  Ground.view3d.x = 256
  Fence.STYLE = style or "rail"
  for _ = 1, 2 do drawFrame() end
  drawCalls = {}
  Fence.draw({ ground = Ground })
  Ground.grid.land = { "FENCES", "MIXED", "ODD", "NS2" }
  local b = { x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9, z0 = 1e9, z1 = -1e9, n = 0 }
  for _, c in ipairs(drawCalls) do
    if c.model[1] == 256 then
      for _, v in ipairs(c.mesh.verts) do
        b.x0, b.x1 = math.min(b.x0, v[1]), math.max(b.x1, v[1])
        b.y0, b.y1 = math.min(b.y0, v[2]), math.max(b.y1, v[2])
        b.z0, b.z1 = math.min(b.z0, v[3]), math.max(b.z1, v[3])
        b.n = b.n + 1
      end
    end
  end
  return b
end
local P = Fence.POST_W

local b = single(EW)
check(b.n > 0, "EW card builds a fence")
check(math.abs((b.x1 - b.x0) - (32 + P)) < 0.6, "EW run spans its card's length plus a post (" .. (b.x1 - b.x0) .. ")")
check(b.z0 > 100 - P and b.z1 < 100 + P, "EW fence stands at the card's FOOT (z=100), not at its leaning top (z " .. b.z0 .. ".." .. b.z1 .. ")")
check(b.z1 - b.z0 >= P - 0.01, "EW fence has real thickness across the run (" .. (b.z1 - b.z0) .. ")")
check(b.y0 < 5 and b.y1 > 5 + Fence.HEIGHT - 1, "EW fence stands on the ground and reaches its height (y " .. b.y0 .. ".." .. b.y1 .. ")")

b = single(NS)
check(b.n > 0, "NS card (edge-on in the engine) builds a fence")
check(math.abs((b.z1 - b.z0) - (48 + P)) < 0.6, "NS run spans its card's length along z (" .. (b.z1 - b.z0) .. ")")
check(b.x1 - b.x0 >= P - 0.01, "NS fence is NOT a line: it is " .. (b.x1 - b.x0) .. " thick across x")
check(b.x0 > 60 - P and b.x1 < 60 + P, "NS fence stands on the card's line x=60 (x " .. b.x0 .. ".." .. b.x1 .. ")")

b = single(DIAG)
check(b.n > 0 and (b.x1 - b.x0) > 24 and (b.z1 - b.z0) > 24, "a 45 degree card gives a diagonal fence (" .. (b.x1 - b.x0) .. " x " .. (b.z1 - b.z0) .. ")")

b = single(SLOPE)
check(b.n > 0 and b.y0 < 5.1, "sloped card: the low end stands at y=5")
-- the high end's posts reach foot 9 + height
check(b.y1 > 9 + Fence.HEIGHT, "sloped card: the high end stands at y=9 (top " .. b.y1 .. ")")

-- picket style: more geometry, same footprint
local rail = single(EW, "rail").n
local pick = single(EW, "picket")
check(pick.n > rail, "picket style builds pickets (" .. pick.n .. " > " .. rail .. " verts)")
check(math.abs((pick.x1 - pick.x0) - (32 + P)) < 0.6, "picket style spans the same run")
Fence.STYLE = "rail"

-- ================================================== 4. dedupe + shared posts ===
local two = single(NS)
local twoDouble
do
  Fence.invalidate()
  lands.SCRATCH = { posScale = POS_SCALE, shapes = { cardsShape("dup", "imped", { EW, EW }) } }
  Ground.grid.land = { "SCRATCH", "SCRATCH", "SCRATCH", "SCRATCH" }
  for _ = 1, 2 do drawFrame() end
  drawCalls = {}
  Fence.draw({ ground = Ground })
  local n = 0
  for _, c in ipairs(drawCalls) do if c.model[1] == 256 then n = n + #c.mesh.verts end end
  twoDouble = n
  Ground.grid.land = { "FENCES", "MIXED", "ODD", "NS2" }
end
check(twoDouble == single(EW).n, "a double-sided (duplicated) card is built once (" .. twoDouble .. " verts)")

-- two cards end to end: the shared post is made once
do
  Fence.invalidate()
  lands.SCRATCH = { posScale = POS_SCALE, shapes = lands.NS2.shapes }
  Ground.grid.land = { "SCRATCH", "SCRATCH", "SCRATCH", "SCRATCH" }
  for _ = 1, 2 do drawFrame() end
  drawCalls = {}
  Fence.draw({ ground = Ground })
  local n = 0
  for _, c in ipairs(drawCalls) do if c.model[1] == 256 then n = n + #c.mesh.verts end end
  -- one 16-long run = 2 posts + 1 bay.  Two end to end = 3 posts + 2 bays (not 4 posts)
  local post = 5 * 4
  local bay = 2 * 3 * 4
  check(n == 3 * post + 2 * bay, "two cards end to end share their middle post (" .. n .. " verts, want " .. (3 * post + 2 * bay) .. ")")
  Ground.grid.land = { "FENCES", "MIXED", "ODD", "NS2" }
end

-- long run: posts at least every POST_SPACING
do
  local long = single({ { 0, 5, 0 }, { 80, 5, 0 }, { 80, 17, 0 }, { 0, 17, 0 } })
  check(long.n == (5 * 4) * 6 + (2 * 3 * 4) * 5, "an 80-long run gets 6 posts and 5 bays (" .. long.n .. " verts)")
end

-- ======================================================== 5. determinism ===
local a1 = single(EW)
local a2 = single(EW)
check(a1.x0 == a2.x0 and a1.z1 == a2.z1 and a1.n == a2.n, "rebuilding gives identical geometry")

-- ================================================== 6. failure isolation ===
Fence.invalidate(); Rocks.invalidate()
Ground.grid.land = { "FENCES", "MIXED", "ODD", "NS2" }
lands.BROKEN = { posScale = POS_SCALE, shapes = { { name = "b", texture = "imped", vertices = 5, indices = 5, vertexCount = 9, triangleCount = 3 } } }
Ground.grid.land = { "BROKEN", "FENCES", "MIXED", "ODD" }
local okFrame = pcall(function() for _ = 1, 3 do drawFrame() end end)
check(okFrame, "a land with garbage geometry does not break the frame")
Ground.grid.land = { "FENCES", "MIXED", "ODD", "NS2" }

-- ===================================================== 7. invalidate/uninstall ===
Fence.invalidate()
check(Fence.isBuilt("FENCES") == false, "invalidate drops every built land")
Hide.uninstall()
check(Hide.installed == false, "Hide uninstalls cleanly")

-- the log line reports what was found
local logged = false
for _, l in ipairs(V.logs) do if l:find("fence run%(s%)") and l:find("north%-south") then logged = true end end
check(logged, "the per-land tuning line is logged")

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
