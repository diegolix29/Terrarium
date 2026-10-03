-- Run with `texlua tools/test_gen4_sky.lua` from the mod root.
-- Real: lib/Gen4Bridge.lua, lib/Gen4Sky.lua, lib/Mat4.lua. Everything else is a stub.
local ROOT = "lib/"
local fails, passes = 0, 0
local function check(cond, msg) if cond then passes = passes + 1 else fails = fails + 1; print("FAIL: " .. msg) end end

local ev = {}
local function E(s) ev[#ev + 1] = s end
local function evstr() return table.concat(ev, ",") end
local function reset() ev = {} end

-- ------------------------------------------------------------------ love --
local canvasId = 0
local function newCanvas(w, h)
  canvasId = canvasId + 1
  return { id = canvasId, w = w, h = h, getDimensions = function(s) return s.w, s.h end }
end
local freeCanvas = newCanvas(256, 192)
local bound = nil
local depth = { "lequal", true }
local pushDepth = 0
love = { graphics = {
  getCanvas = function() return bound end,
  setCanvas = function(c) bound = c end,
  clear = function(r, g, b, a, st, dp) E(("clear(%.2f,%.2f,%.2f,stencil=%s,depth=%s)"):format(r, g, b, tostring(st), tostring(dp))) end,
  push = function() pushDepth = pushDepth + 1 end,
  pop = function() pushDepth = pushDepth - 1 end,
  origin = function() end,
  setDepthMode = function(a, b) depth = { a, b } end,
  getDepthMode = function() return depth[1], depth[2] end,
  setColor = function() end,
}}

-- ------------------------------------------------------------- the engine --
local engineShapes = {}
local Model = { draw = function(self) E("shape:" .. tostring(self.name)); engineShapes[#engineShapes + 1] = #self.shapes end }
local Tilt = { drawSkyPanorama = function() E("TILT-PANORAMA") end, drawSkyLayer = function() E("TILT-LAYER") end }
local strict = false          -- the engine "needs" the horizon call's result
local engineBug = false       -- the engine itself throws
local Ground = {}
Ground.drawHorizonImage = function(self) E("ENGINE-HORIZON"); return true end
Ground.drawFree = function(self, w, h)
  self.freeOpen, self.freeW, self.freeH = true, w, h
  bound = self.canvas or freeCanvas
  local r = self:drawHorizonImage()
  if strict and r ~= true then error("engine needs the horizon result") end
  if engineBug then error("engine bug") end
  for _, m in ipairs(self.models) do m:draw() end
  return true
end
Ground.endFree = function(self) self.freeOpen = false; E("endFree") end
Ground.forMap = function(map) return { terrariumMap = nil } end
Ground.freeColour = nil

local engine = {
  ["src.render.Gen4Ground"] = Ground, ["src.render.Gen4Model"] = Model,
  ["src.render.Tilt"] = Tilt,
  ["src.core.GameVersion"] = { generation = function() return 4 end },
}
local realRequire = require
require = function(n) if engine[n] then return engine[n] end return realRequire(n) end

-- -------------------------------------------------------- mod's modules --
local Mat4 = assert(loadfile(ROOT .. "Mat4.lua"))()
local drawn = {}              -- every Voxel3D.draw the layers made: { name, model }
local Voxel3D
Voxel3D = {
  camera = nil,
  beginScene = function(...) E("beginScene"); return true end,
  endScene = function() E("endScene") end,
  horizonY = function(h) E("horizonY"); return h * 0.3 end,
  skyBody = function(w, h) E("skyBody"); return { x = 10, y = 10 } end,
  pushQuad = function() end,
  newMesh = function(verts) return { verts = verts, release = function() end } end,
  draw = function(mesh, tex, model) drawn[#drawn + 1] = { mesh = mesh, model = model } end,
}
local bandsOn = true
local skyPaintThrows = false
local Sky
Sky = {
  bands = function() return bandsOn and { { 0.1, 0.2, 0.3 }, { 0.6, 0.7, 0.8 } } or nil end,
  dress = function(sky) local b = Sky.bands(); if not b then return sky end
    sky[1], sky[2], sky[3] = 0.6, 0.7, 0.8; sky.bands = b; return sky end,
  paint = function(w, h, sky, hy, cell, body, cx, cy)
    E(("Sky.paint(%dx%d,hy=%s,cell=%d,body=%s,cam=%d,%d)"):format(w, h, tostring(hy), cell, tostring(body ~= nil), cx, cy))
    if skyPaintThrows then error("paint boom") end
  end,
}
local layerFails = {}
local tiltSeenInSkyLayer
local backdropState
local function layer(name, fn)
  return { draw = function(state)
    E(name)
    if layerFails[name] then error(name .. " boom") end
    if fn then fn(state) end
  end }
end
local HorizonArt = layer("HorizonArt", function(state)
  Voxel3D.draw({ n = "horizon" }, nil, Mat4.translate(state.player.px, 0, state.player.py))
end)
local SkyLayer = layer("SkyLayer", function(state)
  tiltSeenInSkyLayer = Tilt.drawSkyPanorama
  Tilt.drawSkyPanorama()           -- what the real SkyLayer does first
  -- a cloud sitting 100 east of the player, 300 up
  Voxel3D.draw({ n = "cloud" }, nil, Mat4.translate(state.player.px + 100, 300, state.player.py))
end)
local scenery = { name = nil, loads = 0 }
local Backdrop
Backdrop = layer("Backdrop", function(state)
  backdropState = state
  Voxel3D.draw({ n = "backdrop" }, nil, Mat4.translate(state.player.px, 0, state.player.py))
  Backdrop.drawOverworldScenery(state, state.player.px, state.player.py)
end)
Backdrop.drawOverworldScenery = function() E("OLD-SCENERY-QUAD") end
Backdrop.selectSceneryForMap = function(map) scenery.picked = map.def.tileset; return "kanto_panorama" end
local image = { getDimensions = function() return 1024, 256 end }
local BattleCanvas = { loadScenery = function(n) scenery.name = n; scenery.loads = scenery.loads + 1; return image end }
local outdoorMap = true
local Spawn = { isOutdoor = function(map) return outdoorMap end }

local V
V = { mod = { log = { warn = function(_, m) E("WARN") ; V.lastWarn = m end, info = function() end } } }
local mods = { Voxel3D = Voxel3D, Mat4 = Mat4, Sky = Sky, HorizonArt = HorizonArt, SkyLayer = SkyLayer,
               Backdrop = Backdrop, BattleCanvas = BattleCanvas, Gen4Spawn = Spawn }
V.require = function(n)
  if mods[n] then return mods[n] end
  error("no stub " .. n)
end
local Bridge = assert(loadfile(ROOT .. "Gen4Bridge.lua"))(V)
mods.Gen4Bridge = Bridge
local GS = assert(loadfile(ROOT .. "Gen4Sky.lua"))(V)
mods.Gen4Sky = GS
-- Gen4Bridge.install asks for these; not under test here
mods.Gen4Water = { draw = function() end }
mods.Gen4Sand = { draw = function() end }
mods.Gen4Trees = { draw = function() end }

-- --------------------------------------------------------------- a ground --
local function newView(extra)
  local v = { x = 150, y = 60, z = 260 }
  function v:matrix() return Mat4.identity() end
  function v:forward() return 0, -0.5, -0.8660254 end
  function v:effectiveFovY() return 50 end
  for k, x in pairs(extra or {}) do v[k] = x end
  return v
end
local function newGround(opts)
  opts = opts or {}
  local g = setmetatable({ offsetX = 100, offsetY = 200, view3d = opts.view or newView(),
                           terrariumMap = { id = "twinleaf", def = { tileset = "GEN4" } },
                           models = opts.models or { { name = "A", shapes = { { name = "a1" } } },
                                                     { name = "B", shapes = { { name = "b1" } } } },
                           canvas = opts.canvas },
                         { __index = Ground })
  g.groundY = function() return 5 end
  for _, m in ipairs(g.models) do setmetatable(m, { __index = Model }) end
  return g
end
local function frame(g) reset(); drawn = {}; g:drawFree(256, 192); g:endFree() end

-- ----------------------------------------------------------------- install --
check(GS.install() == false or true, "install returns")
check(Bridge.install() == true, "bridge installs (and pulls Gen4Sky in)")
check(GS.installed == true, "Gen4Sky installed by the bridge")
check(Bridge.pre.sky == GS.drawLayers and Bridge.preOrder[1] == "sky", "sky registered as a PRE effect")
check(Backdrop.drawOverworldScenery ~= nil and scenery.loads == 0, "scenery ring installed")

-- -------------------------------------------------- 1. the normal frame --
do
  local g = newGround()
  frame(g)
  local s = evstr()
  check(s:find("clear%(0.60,0.70,0.80,stencil=false,depth=false%)"), "colour cleared to the haze, depth NOT cleared: " .. s)
  local order = { "clear", "horizonY", "skyBody", "Sky.paint", "beginScene", "HorizonArt", "SkyLayer", "Backdrop", "endScene", "shape:A", "shape:B", "endFree" }
  local at, okOrder = 1, true
  for _, name in ipairs(order) do
    local i = s:find(name, at, true)
    if not i then okOrder = false; print("  missing/ordered wrong: " .. name); break end
    at = i + #name
  end
  check(okOrder, "order: clear, sky paint, scene (horizon art, sky layer, backdrop), THEN terrain: " .. s)
  check(select(2, s:gsub("Sky.paint", "")) == 1, "sky painted once per drawFree, not once per shape")
  check(not s:find("ENGINE-HORIZON"), "engine horizon call hidden")
  check(not s:find("TILT-PANORAMA"), "engine sky panorama (Tilt) hidden while SkyLayer runs")
  check(Tilt.drawSkyPanorama ~= nil and Tilt.drawSkyPanorama() == nil and ev[#ev] == "TILT-PANORAMA", "Tilt restored afterwards")
  reset()
  check(Ground.drawHorizonImage ~= nil, "engine horizon function put back after the frame")
  g:drawHorizonImage(); check(evstr() == "ENGINE-HORIZON", "...and it works again outside drawFree")
  check(s:find("hy=57.6") and s:find("cell=1"), "horizonY and cell passed to Sky.paint: " .. s)
  check(s:find("cam=50,60"), "camera handed to the sky in MAP px (world - offset)")
  check(pushDepth == 0, "graphics state stack balanced")
  check(Voxel3D.draw ~= nil and #drawn >= 0 and drawn[1] ~= nil, "layers drew")
end

-- ------------------------------------------- 2. placement of the layers --
do
  local function worldOf(m, x, y, z) return m[1]*x + m[2]*y + m[3]*z + m[4], m[5]*x + m[6]*y + m[7]*z + m[8], m[9]*x + m[10]*y + m[11]*z + m[12] end
  local g = newGround()
  frame(g)
  local bd
  for _, d in ipairs(drawn) do if d.mesh.n == "backdrop" then bd = d end end
  check(bd ~= nil, "backdrop drew")
  if bd then
    -- the layer centres on the player at map (50,60); world = off + that, at ground height 5
    local x, y, z = worldOf(bd.model, 0, 0, 0)
    check(math.abs(x - 150) < 1e-6 and math.abs(y - 5) < 1e-6 and math.abs(z - 260) < 1e-6,
          ("backdrop centred under the eye at ground height: %g %g %g"):format(x, y, z))
  end
  local cl
  for _, d in ipairs(drawn) do if d.mesh.n == "cloud" then cl = d end end
  if cl then
    local x, y, z = worldOf(cl.model, 0, 0, 0)
    check(math.abs(x - 250) < 1e-6 and math.abs(y - 305) < 1e-6 and math.abs(z - 260) < 1e-6,
          ("cloud 100 east, 300 above the ground: %g %g %g"):format(x, y, z))
  end
  check(Voxel3D.draw ~= nil and #drawn > 0, "ok")
  -- Voxel3D.draw is the original again
  local before = #drawn
  Voxel3D.draw({ n = "plain" }, nil, Mat4.identity())
  check(#drawn == before + 1 and drawn[#drawn].model[4] == 0, "Voxel3D.draw restored (no adjustment leaks)")
  check(backdropState.map.def.tileset == "OVERWORLD" and backdropState.map.id == "twinleaf",
        "Gen 1-3 modules get an open-air stand-in map that still carries the real id")
  check(scenery.picked == "OVERWORLD", "scenery picked from the stand-in's tileset")
end

-- ----------------------------------------------- 3. far plane fit (scale) --
do
  local g = newGround({ view = newView({ far = 450 }) })
  frame(g)
  local function worldOf(m, x, y, z) return m[1]*x + m[2]*y + m[3]*z + m[4], m[5]*x + m[6]*y + m[7]*z + m[8], m[9]*x + m[10]*y + m[11]*z + m[12] end
  local cl
  for _, d in ipairs(drawn) do if d.mesh.n == "cloud" then cl = d end end
  local s = 0.85 * 450 / 900
  local x, y, z = worldOf(cl.model, 0, 0, 0)
  -- the cloud's offset from the eye: (100, 300-(60-5)=245, 0), scaled by s about the eye
  check(math.abs(x - (150 + 100 * s)) < 1e-6 and math.abs(y - (60 + 245 * s)) < 1e-6 and math.abs(z - 260) < 1e-6,
        ("scaled about the EYE (angles unchanged): %g %g %g"):format(x, y, z))
  GS.FAR = 300
  local g2 = newGround(); frame(g2)
  local cl2
  for _, d in ipairs(drawn) do if d.mesh.n == "cloud" then cl2 = d end end
  local s2 = 0.85 * 300 / 900
  local x2 = worldOf(cl2.model, 0, 0, 0)
  check(math.abs(x2 - (150 + 100 * s2)) < 1e-6, "S.FAR overrides when the view has none")
  GS.FAR = nil
end

-- --------------------------------------------------------- 4. scenery ring --
do
  scenery.loads = 0
  local g = newGround(); frame(g)
  check(not evstr():find("OLD%-SCENERY%-QUAD"), "Backdrop's old one-quad scenery is replaced")
  local ring
  for _, d in ipairs(drawn) do if d.mesh.verts and #d.mesh.verts > 100 then ring = d end end
  check(ring ~= nil, "scenery ring drawn")
  if ring then
    -- 1024x256, 160 tall -> tile 640 wide; circumference 2*pi*855 = 5372 -> 8 tiles -> 128 segments -> 512 verts
    check(#ring.mesh.verts == 8 * 16 * 4, "ring tiled by the image's aspect: " .. #ring.mesh.verts .. " verts")
  end
  GS.scenery = false; reset(); drawn = {}; g:drawFree(256, 192)
  local any = false
  for _, d in ipairs(drawn) do if d.mesh.verts and #d.mesh.verts > 100 then any = true end end
  check(not any, "S.scenery = false: no ring")
  GS.scenery = true
  GS.SCENERY = "harbor_edge"; frame(g); check(scenery.name == "harbor_edge", "S.SCENERY forces a scenery name"); GS.SCENERY = nil
end

-- ---------------------------------------------- 5. it never leaves a hole --
do
  outdoorMap = false
  local g = newGround(); frame(g)
  local s = evstr()
  check(not s:find("clear") and not s:find("Sky.paint") and not s:find("beginScene"), "indoors: no sky, no clear, no scene: " .. s)
  check(s:find("ENGINE%-HORIZON"), "indoors: engine horizon left alone")
  check(s:find("shape:A") and s:find("shape:B"), "indoors: world draws")
  outdoorMap = true

  bandsOn = false
  frame(g); s = evstr()
  check(not s:find("clear") and s:find("ENGINE%-HORIZON") and s:find("shape:A"), "no sky bands: engine horizon kept: " .. s)
  bandsOn = true

  skyPaintThrows = true
  frame(g); s = evstr()
  check(s:find("shape:A") and s:find("beginScene") and s:find("Backdrop"), "Sky.paint throws: layers and world still run")
  check(V.lastWarn and V.lastWarn:find("Sky.paint failed"), "...and it is logged")
  skyPaintThrows = false

  layerFails.SkyLayer = true
  frame(g); s = evstr()
  check(s:find("Backdrop") and s:find("shape:B") and s:find("endScene"), "one layer throwing does not stop the rest")
  check(Tilt.drawSkyPanorama ~= nil and Voxel3D.draw ~= nil, "state restored after a layer threw")
  layerFails.SkyLayer = nil

  -- the free canvas is not what is bound at the first shape
  local other = newCanvas(64, 64)
  local g2 = newGround({ canvas = other })
  frame(g2); s = evstr()
  check(not s:find("Sky.paint") and s:find("shape:A"), "a different canvas bound: no paint on it")

  -- no view yet
  local g3 = newGround(); g3.view3d = nil
  frame(g3); s = evstr()
  check(s:find("shape:A") and not s:find("Sky.paint"), "no view: skipped, world draws")
end

-- ------------------------------------------------- 6. switches and knobs --
do
  GS.hideHorizon = false
  local g = newGround(); frame(g); local s = evstr()
  check(not s:find("clear") and s:find("Sky.paint") and s:find("ENGINE%-HORIZON"), "hideHorizon=false: no wipe, engine call kept, sky still painted: " .. s)
  GS.hideHorizon = true

  GS.autoHide = false
  frame(g); s = evstr()
  check(s:find("ENGINE%-HORIZON") and s:find("clear"), "autoHide=false: only the wipe remains")
  GS.autoHide = true

  GS.sky2d = false
  frame(g); s = evstr()
  check(not s:find("Sky.paint") and s:find("clear") and s:find("Backdrop"), "sky2d=false: wipe + 3D layers only")
  GS.sky2d = true

  GS.horizonArt, GS.skyLayer, GS.backdrop = false, false, false
  frame(g); s = evstr()
  check(not s:find("HorizonArt") and not s:find("SkyLayer") and not s:find("Backdrop"), "layer switches")
  GS.horizonArt, GS.skyLayer, GS.backdrop = true, true, true

  Bridge.disabled.sky = true
  frame(g); s = evstr()
  check(not s:find("beginScene") and s:find("Sky.paint"), "Bridge.setEffect sky off: 3D layers skipped")
  Bridge.disabled.sky = nil

  GS.enabled = false
  frame(g); s = evstr()
  check(s == "ENGINE-HORIZON,shape:A,shape:B,endFree", "enabled=false: the engine frame is untouched: " .. s)
  GS.enabled = true
end

-- --------------------------------------- 7. shape filter, extra, errors --
do
  engineShapes = {}
  local sky = { name = "SKY", shapes = { { name = "x", material = "skybox_day" }, { name = "y" } } }
  local g = newGround({ models = { sky } })
  frame(g)
  check(engineShapes[1] == 1, "a shape named skybox is skipped (1 of 2 left)")
  check(#sky.shapes == 2, "...and the model's own list is put back")

end

do
  -- an engine that NEEDS the result of a call we turned into a no-op: auto-hide
  -- switches itself off, the frame is redrawn once, nothing propagates
  strict = true
  local g = newGround()
  local ok, err = pcall(frame, g)
  check(ok, "engine threw with a call hidden: swallowed, redrawn: " .. tostring(err))
  check(GS.autoHide == false, "auto-hide turned itself off")
  check(evstr():find("ENGINE%-HORIZON") and evstr():find("shape:B"), "the redraw ran the real engine call and the whole world")
  check(V.lastWarn and V.lastWarn:find("auto%-hide is OFF"), "...and says so in the log")
  GS.autoHide = true

  -- and an engine bug with NOTHING hidden is not swallowed
  GS.hideHorizon = false
  engineBug = true
  local ok2 = pcall(frame, newGround())
  check(not ok2, "an engine error with nothing hidden still propagates")
  engineBug = false
  GS.hideHorizon = true
  strict = false
end

-- ------------------------------------------------------------- uninstall --
do
  GS.uninstall()
  check(GS.installed == false, "uninstall")
  check(Ground.drawFree == GS.originalDrawFree and Model.draw == GS.originalModelDraw, "engine functions restored")
  check(Backdrop.drawOverworldScenery == GS.originalScenery, "Backdrop's own scenery function restored")
end

print(("%d passed, %d failed"):format(passes, fails))
os.exit(fails == 0 and 0 or 1)
