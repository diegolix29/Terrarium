-- Gen4Sky: the voxel scene's SKY, drawn behind Platinum's own 3D world, with the
-- engine's horizon image hidden.
--
-- WHAT YOU GET (the same things Gen 1-3 has, same modules, same settings)
--
--   lib/Sky.lua         banded dithered sky for the hour, volumetric clouds, the
--                       twilight glow, sun / moon disc, stars, fog bands, rainbow,
--                       the distant rain curtain, god rays.
--   lib/HorizonArt.lua  the painted panorama cylinder.
--   lib/SkyLayer.lua    star dome, twinklers, shooting stars, cloud decks, birds,
--                       planes, blimps, rainbows.
--   lib/Backdrop.lua    the chosen panorama (HORIZON ART row) and the SCENERY ring.
--   (lib/Skyline.lua is NOT drawn: it stands up silhouettes from the Gen 1-3
--   connection graph, and a Platinum map has none.)
--
-- THE SEAM (engine untouched)
--
-- Gen 1-3 paint all of that BEFORE the terrain, depth writes off, so every real
-- surface draws over it. Platinum's free-camera pass has the same shape:
-- Gen4Ground:drawFree binds the colour + depth canvas and then draws terrain
-- through Gen4Model:draw. So this wraps Gen4Model.draw and, on the FIRST shape of
-- a drawFree call, while the canvas is bound and its depth is still clear, it
--
--   1. clears the canvas colour to the sky's haze   (this alone wipes any engine
--                                                    backdrop drawn earlier in the
--                                                    pass; depth is left alone)
--   2. Sky.paint(...)                               (the 2D banded sky + sun/moon/
--                                                    stars/clouds, exactly as Voxel3D
--                                                    calls it)
--   3. Gen4Bridge.runPre(ground)                    (an open Voxel3D scene on Gen4's
--                                                    own view-projection: HorizonArt,
--                                                    SkyLayer, Backdrop + scenery)
--
-- and then the engine draws the world over it. Same order as the voxel scene, same
-- result: the sky never occludes anything.
--
-- HIDING THE ENGINE'S HORIZON IMAGE
--
-- I could not read the engine source (it is not in the zip), so there are three
-- independent nets. Any one that catches it is enough; each logs what it did.
--   a. Step 1 above: an image the engine paints into the canvas BEFORE the first
--      terrain shape is overwritten by the opaque haze.
--   b. Method neutraliser (S.autoHide): engine functions whose name says
--      draw/paint/render + horizon/sky/backdrop/panorama (on Gen4Ground, Gen4View,
--      Gen4Camera, Tilt and a few likely modules) are swapped for no-ops for the
--      length of drawFree, and put back after. Grep the log for "Gen4Sky: hiding".
--      If the engine throws with one swapped, auto-hide switches itself off and the
--      frame is redrawn once without it.
--   c. Shape filter: terrain/prop shapes whose material/texture name says skybox /
--      horizon / panorama are skipped (S.SHAPE_WORDS).
-- If none of those catches it, turn on S.LOG_CANDIDATES: it logs every function the
-- scan looked at, and the name you need is in that list; add it to S.HIDE_EXTRA.
--
-- WHEN IT STANDS DOWN (it never leaves a hole)
--   * Indoors / not a Gen 4 outdoor map (Gen4Spawn.isOutdoor).
--   * Sky.bands() is nil (the sky has nothing to paint): the engine keeps its own.
--   * The canvas bound at the first shape is not the free canvas.
--   * Any failure: logged once, the engine's frame carries on untouched.
--
-- LIMITS
--   * Free cameras only (third / first person, numeric CAM TILT rungs), same as the
--     rest of Gen4Bridge. The default CARTRIDGE (oblique) rung is not covered.
--   * Day/night TINT on the sky meshes comes from Voxel3D.tint, which Gen 1-3's frame
--     loop sets; if nothing sets it on Gen 4 the meshes are untinted. The 2D sky
--     (bands, clouds, glow, stars) follows the clock regardless.
--   * Far plane: Gen4View's far distance is read from view.far / zFar / farPlane. If
--     none exists the panorama is drawn at its Gen 1-3 radius (900); if it does not
--     show, set S.FAR to Gen 4's far distance and everything is scaled to fit,
--     about the eye, so the angles do not change.
--   * NOT RUN IN LOVE + PLATINUM. Stub-tested only (tools/test_gen4_sky.lua).

local V = ...

local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")

local S = {
  enabled = true,
  sky2d = true,          -- Sky.paint: bands, clouds, glow, sun/moon, stars, fog, rainbow, rain curtain
  horizonArt = true,     -- lib/HorizonArt.lua panorama
  skyLayer = true,       -- lib/SkyLayer.lua: stars, cloud decks, birds, planes, blimps
  backdrop = true,       -- lib/Backdrop.lua panorama
  scenery = true,        -- the scenery ring in front of the backdrop
  hideHorizon = true,    -- master switch for hiding the engine's horizon image
  autoHide = true,       -- net (b): swap matching engine draw functions for no-ops
  SHAPE_WORDS = { "skybox", "horizon", "panorama", "haikei" },   -- net (c)
  HIDE_EXTRA = {},       -- { { module = "src.render.Foo", name = "drawBar" }, ... } or { obj = table, name = "x" }
  CELL_ROWS = 240,       -- the sky's pixel grid: canvas height / this = one dither cell
  FAR = nil,             -- Gen 4's far distance, if the view does not say
  FAR_FIT = 0.85,        -- fraction of the far plane the panorama may reach
  SCENERY = nil,         -- force a scenery name (BattleCanvas.loadScenery); nil = Backdrop's pick
  SCENERY_HEIGHT = 160,  -- world units the scenery ring stands
  SCENERY_RADIUS = 0.95, -- of the backdrop radius
  LOG = true,
  LOG_CANDIDATES = false,
  installed = false,
}
S.status = "not installed"

local PANORAMA_RADIUS = 900     -- Backdrop / HorizonArt RADIUS
local SEG_PER_TILE = 16

-- ---------------------------------------------------------------- helpers --

local noted = {}
local function note(key, fmt, ...)
  if not S.LOG or noted[key] then return end
  noted[key] = true
  if V.mod and V.mod.log then V.mod.log:info("Gen4Sky: " .. fmt:format(...)) end
end

local function warnOnce(key, fmt, ...)
  if noted["w:" .. key] then return end
  noted["w:" .. key] = true
  if V.mod and V.mod.log then V.mod.log:warn("Gen4Sky: " .. fmt:format(...)) end
end

local function optional(name)
  local ok, mod = pcall(V.require, name)
  if ok and type(mod) == "table" then return mod end
  return nil
end

local function guarded(fn)
  local g = love and love.graphics
  if not (g and g.push and g.pop) then return pcall(fn) end
  local pushed = pcall(g.push, "all")
  local ok, err = pcall(fn)
  if pushed then pcall(g.pop) end
  return ok, err
end

local function outdoors(map)
  local Spawn = optional("Gen4Spawn")
  if not (Spawn and Spawn.isOutdoor) then return map ~= nil end
  if not map then
    note("nomap", "the ground has no map tag; treating it as outdoors")
    return true
  end
  local ok, r = pcall(Spawn.isOutdoor, map)
  return ok and r and true or false
end

-- Gen 1-3's sky modules decide "outdoors" from Gen 1-3 header fields, which say
-- "indoors" for every Platinum map. They are handed a stand-in map that wears an
-- open-air tileset and forwards everything else to the real one.
local function openAirMap(map)
  local proxy = { def = { tileset = "OVERWORLD", outdoor = true }, id = map and map.id }
  return setmetatable(proxy, { __index = map })
end

local function farOf(ground, view)
  if tonumber(S.FAR) then return tonumber(S.FAR) end
  for _, o in ipairs({ view, ground }) do
    if type(o) == "table" then
      for _, k in ipairs({ "far", "zFar", "zfar", "farPlane", "farDist" }) do
        local v = tonumber(o[k])
        if v and v > 0 then return v end
      end
    end
  end
  return nil
end

-- --------------------------------------------------- the 2D sky (Sky.paint) --

local function setCamera(view, vw, vh)
  local saved = {
    vp = Voxel3D.vp, eye = Voxel3D.eye, focus = Voxel3D.focus, fovY = Voxel3D.fovY,
    lookFlat = Voxel3D.lookFlat, descent = Voxel3D.descent, skyRayLive = Voxel3D.skyRayLive,
  }
  local fx, fy, fz = view:forward()
  Voxel3D.vp = view:matrix(vw, vh)             -- Gen4's world->clip, Y already flipped
  Voxel3D.eye = { view.x, view.y, view.z }
  Voxel3D.focus = { view.x + fx * 128, view.y + fy * 128, view.z + fz * 128 }
  local okF, fov = pcall(view.effectiveFovY, view, vh)
  if okF and tonumber(fov) then Voxel3D.fovY = math.rad(fov) end
  local flat = math.sqrt(fx * fx + fz * fz)
  Voxel3D.descent = math.max(0, math.min(1, -fy))
  if flat > 1e-6 then Voxel3D.lookFlat = { fx / flat, 0, fz / flat } end
  Voxel3D.skyRayLive = nil                     -- the frame-hung sky: the classic look
  return saved
end

local function restoreCamera(saved)
  for k, v in pairs(saved) do Voxel3D[k] = v end
  -- keys whose saved value was nil must be cleared too
  for _, k in ipairs({ "vp", "eye", "focus", "fovY", "lookFlat", "descent", "skyRayLive" }) do
    if saved[k] == nil then Voxel3D[k] = nil end
  end
end

-- the engine's own horizon is gone by now (step 1); paint ours. Returns true when
-- the sky went down.
local function paintSky2D(ground, view, vw, vh, map, wipe)
  local Sky = optional("Sky")
  if not (Sky and Sky.dress and Sky.paint) then return false end
  local sky = Sky.dress({ 0.5, 0.7, 0.9, 1 })
  if not (sky and sky.bands and sky.bands[1]) then return false end
  sky.map = map
  local g = love.graphics
  -- (1) the canvas colour to the haze. Colour only: the depth the engine cleared is
  -- left alone, and anything painted into the colour before this is wiped.
  if wipe then g.clear(sky[1], sky[2], sky[3], 1, false, false) end
  if not S.sky2d then return true end
  local saved = setCamera(view, vw, vh)
  local ok, err = pcall(function()
    local horizonY = Voxel3D.horizonY and Voxel3D.horizonY(vh) or nil
    local body = Voxel3D.skyBody and Voxel3D.skyBody(vw, vh) or nil
    local cell = math.max(1, math.floor(vh / math.max(1, S.CELL_ROWS) + 0.5))
    local offX, offZ = ground.offsetX or 0, ground.offsetY or 0
    Sky.paint(vw, vh, sky, horizonY, cell, body, view.x - offX, view.z - offZ)
  end)
  restoreCamera(saved)
  if not ok then warnOnce("paint", "Sky.paint failed: %s", tostring(err)) end
  return true
end

-- -------------------------------------------- the scenery ring (Backdrop) --
-- Backdrop.drawOverworldScenery draws one 200x100 quad AT THE PLAYER's feet (and
-- its plane builder is declared after its use, so it never ran). On Gen 4 it is
-- replaced with a real ring: the scenery image tiled around the horizon, just
-- inside the panorama. Gen 1-3 never reach this file's version of it.

local ring = { mesh = nil, key = nil }

local function releaseRing()
  if ring.mesh and ring.mesh.release then pcall(ring.mesh.release, ring.mesh) end
  ring.mesh, ring.key = nil, nil
end

local function ringFor(image)
  local iw, ih = image:getDimensions()
  if not (iw and ih and iw > 0 and ih > 0) then return nil end
  local radius = PANORAMA_RADIUS * S.SCENERY_RADIUS
  local height = S.SCENERY_HEIGHT
  local tileW = height * iw / ih
  local tiles = math.max(1, math.floor((2 * math.pi * radius) / tileW + 0.5))
  local key = tostring(image) .. ":" .. tiles .. ":" .. height .. ":" .. radius
  if ring.mesh and ring.key == key then return ring.mesh end
  releaseRing()
  local verts, indexMap, quads = {}, {}, 0
  local segs = tiles * SEG_PER_TILE
  local yTop, yBot = height, -20
  for i = 0, segs - 1 do
    local a0, a1 = (i / segs) * math.pi * 2, ((i + 1) / segs) * math.pi * 2
    local x0, z0 = math.cos(a0) * radius, math.sin(a0) * radius
    local x1, z1 = math.cos(a1) * radius, math.sin(a1) * radius
    local j = i % SEG_PER_TILE
    local u0, u1 = j / SEG_PER_TILE, (j + 1) / SEG_PER_TILE
    -- wound like Backdrop.build: the painted face looks INWARD at the player
    verts[#verts + 1] = { x1, yTop, z1, u1, 0, 1 }
    verts[#verts + 1] = { x0, yTop, z0, u0, 0, 1 }
    verts[#verts + 1] = { x0, yBot, z0, u0, 1, 1 }
    verts[#verts + 1] = { x1, yBot, z1, u1, 1, 1 }
    Voxel3D.pushQuad(indexMap, quads)
    quads = quads + 1
  end
  local mesh = Voxel3D.newMesh(verts, indexMap)
  if mesh then ring.mesh, ring.key = mesh, key end
  return mesh
end

local function drawSceneryRing(state, px, pz)
  if not S.scenery then return end
  local pub = rawget(_G, "__ds_ceiling_config")
  if type(pub) == "function" then
    local ok, cfg = pcall(pub)
    if ok and type(cfg) == "table" and cfg.overworldScenery == false then return end
  end
  local Backdrop, BC = optional("Backdrop"), optional("BattleCanvas")
  if not (BC and BC.loadScenery) then return end
  local name = S.SCENERY
  if not name and Backdrop and Backdrop.selectSceneryForMap then
    name = Backdrop.selectSceneryForMap(state and state.map)
  end
  if not name then return end
  local image = BC.loadScenery(name)
  if not image then
    note("scenery:" .. tostring(name), "scenery '%s' did not load; no ring", tostring(name))
    return
  end
  local mesh = ringFor(image)
  if not mesh then return end
  guarded(function()
    love.graphics.setDepthMode("lequal", false)
    love.graphics.setColor(1, 1, 1, 1)
    Voxel3D.draw(mesh, image, Mat4.translate(px, 0, pz))
  end)
end

-- ------------------------------------------- the 3D layers (a pre effect) --

-- Every layer is built for the Gen 1-3 world: centred on the player in MAP pixels,
-- sky objects at heights measured from y = 0. Gen 4's world is map pixels plus the
-- matrix origin, with real heights. So the layers are drawn through ONE adjustment
-- matrix, applied to every Voxel3D.draw they make for the length of the call:
--
--   world = off + (0, baseY, 0) + e + s * (p - e)
--
-- e is the eye in layer space (map px, height above the ground under the camera).
-- Scaling by s about the eye leaves every angle exactly as it was, so the panorama
-- can be pulled inside Gen 4's far plane without changing what it looks like.
local function adjustment(ground, view)
  local offX, offZ = ground.offsetX or 0, ground.offsetY or 0
  local ex, ez = view.x - offX, view.z - offZ
  local okG, gy = pcall(ground.groundY, ground, ex, ez)
  local baseY = (okG and tonumber(gy)) or 0
  local ey = view.y - baseY
  local far = farOf(ground, view)
  local s = 1
  if far then s = math.min(1, S.FAR_FIT * far / PANORAMA_RADIUS) end
  if far then
    note("far", "far plane %.0f: sky scaled by %.2f about the eye", far, s)
  else
    note("nofar", "no far plane found on the view; sky drawn at its Gen 1-3 size (set Gen4Sky.FAR if it does not show)")
  end
  local about = Mat4.mul(Mat4.translate(ex, ey, ez),
                         Mat4.mul(Mat4.scale(s, s, s), Mat4.translate(-ex, -ey, -ez)))
  return Mat4.mul(Mat4.translate(offX, baseY, offZ), about), ex, ez
end

local function layers(state)
  local function run(name, on, fn)
    if not on then return end
    local mod = optional(name)
    if not (mod and type(mod.draw) == "function") then return end
    local ok, err = pcall(fn, mod)
    if not ok then warnOnce("layer:" .. name, "%s failed: %s", name, tostring(err)) end
  end
  -- the voxel scene's own order: horizon art, the sky layer, then the backdrop
  run("HorizonArt", S.horizonArt, function(m) m.draw(state) end)
  run("SkyLayer", S.skyLayer, function(m) m.draw(state) end)
  run("Backdrop", S.backdrop, function(m) m.draw(state) end)
end

function S.drawLayers(scene)
  if not S.enabled then return end
  local ground, view = scene.ground, scene.view
  local map = scene.map
  if not outdoors(map) then return end

  local adjust, ex, ez = adjustment(ground, view)
  local state = {
    map = openAirMap(map),
    player = { px = ex, py = ez, cellX = math.floor(ex / 16), cellY = math.floor(ez / 16),
               surfing = false },
  }

  local ident = Mat4.identity()
  local drawOriginal = Voxel3D.draw
  Voxel3D.draw = function(mesh, texture, model, pull, sunModel, ...)
    return drawOriginal(mesh, texture, Mat4.mul(adjust, model or ident), pull,
                        sunModel and Mat4.mul(adjust, sunModel) or nil, ...)
  end

  -- SkyLayer opens with the engine's own sky panorama (Tilt:drawSkyPanorama), a
  -- full-screen picture. That is the engine's horizon image: not wanted here.
  local Tilt = S.tilt
  local tiltSaved = {}
  if Tilt then
    for _, k in ipairs({ "drawSkyPanorama", "drawSkyLayer" }) do
      if type(Tilt[k]) == "function" then
        tiltSaved[k] = Tilt[k]
        Tilt[k] = function() end
      end
    end
  end

  local ok, err = pcall(layers, state)

  for k, fn in pairs(tiltSaved) do Tilt[k] = fn end
  Voxel3D.draw = drawOriginal
  if not ok then error(err, 0) end
end

-- ------------------------------------------- hiding the engine's horizon --

local WORDS = { "horizon", "skybox", "backdrop", "panorama", "skyline", "sky" }
local VERBS = { "^draw", "^paint", "^render", "^blit", "^show", "draw$", "paint$", "render$" }

local function nameMatches(name)
  local l = tostring(name):lower()
  local hit = false
  for _, w in ipairs(WORDS) do if l:find(w, 1, true) then hit = true; break end end
  if not hit then return false end
  for _, v in ipairs(VERBS) do if l:find(v) then return true end end
  return false
end

local CANDIDATE_MODULES = {
  "src.render.Gen4Ground", "src.render.Gen4View", "src.render.Gen4Camera",
  "src.render.Gen4Model", "src.render.Tilt", "src.render.Gen4Sky",
  "src.render.Gen4Horizon", "src.render.Gen4Backdrop", "src.render.Gen4Skybox",
  "src.render.Horizon", "src.render.Backdrop", "src.render.Skybox",
}

local targets, scanned = {}, false

local function scanObject(obj, label)
  if type(obj) ~= "table" then return end
  local seen = {}
  local function visit(t)
    if type(t) ~= "table" or seen[t] then return end
    seen[t] = true
    for k, v in pairs(t) do
      if type(k) == "string" and type(v) == "function" then
        if S.LOG_CANDIDATES then note("cand:" .. label .. "." .. k, "saw %s.%s", label, k) end
        if nameMatches(k) then
          targets[#targets + 1] = { obj = t, name = k, label = label }
          note("hide:" .. label .. "." .. k, "hiding engine call %s.%s during drawFree", label, k)
        end
      end
    end
    local mt = getmetatable(t)
    if mt and type(mt.__index) == "table" then visit(mt.__index) end
  end
  visit(obj)
end

local function scan(Ground)
  if scanned then return end
  scanned = true
  targets = {}
  scanObject(Ground, "Gen4Ground")
  for _, name in ipairs(CANDIDATE_MODULES) do
    if name ~= "src.render.Gen4Ground" and name ~= "src.render.Gen4Model" then
      local ok, mod = pcall(require, name)
      if ok and type(mod) == "table" then
        scanObject(mod, name:gsub("^src%.render%.", ""))
        if name == "src.render.Tilt" then S.tilt = mod end
      end
    end
  end
  for _, extra in ipairs(S.HIDE_EXTRA) do
    local obj = extra.obj
    if not obj and extra.module then
      local ok, mod = pcall(require, extra.module)
      obj = ok and mod or nil
    end
    if type(obj) == "table" and type(obj[extra.name]) == "function" then
      targets[#targets + 1] = { obj = obj, name = extra.name, label = extra.module or "extra" }
      note("hide:extra:" .. extra.name, "hiding engine call %s.%s during drawFree",
           tostring(extra.module or "extra"), extra.name)
    end
  end
  -- Tilt is also what SkyLayer asks for the panorama; keep the handle even if no
  -- name matched
  if not S.tilt then
    local ok, mod = pcall(require, "src.render.Tilt")
    if ok and type(mod) == "table" then S.tilt = mod end
  end
end

local function neutralise()
  local swapped = {}
  for _, t in ipairs(targets) do
    local original = rawget(t.obj, t.name)
    if type(original) == "function" then
      swapped[#swapped + 1] = { t = t, original = original }
      rawset(t.obj, t.name, function() end)
    end
  end
  return swapped
end

local function restore(swapped)
  for _, rec in ipairs(swapped) do rawset(rec.t.obj, rec.t.name, rec.original) end
end

local function shapeIsHorizon(shape)
  local m = tostring(shape.srcMaterial or shape.material or ""):lower()
  local t = tostring(shape.srcTexture or shape.texture or ""):lower()
  local n = tostring(shape.name or ""):lower()
  for _, w in ipairs(S.SHAPE_WORDS) do
    if m:find(w, 1, true) or t:find(w, 1, true) or n:find(w, 1, true) then return true end
  end
  return false
end

-- ------------------------------------------------------------------ hooks --

local armed      -- the ground whose drawFree is running, until the sky is painted
local hiding     -- true while the engine's horizon is being kept out of the frame

local function freeCanvasBound(ground)
  local g = love and love.graphics
  if not (g and g.getCanvas) then return false end
  local ok, c = pcall(g.getCanvas)
  if not (ok and c) then return false end
  local okD, cw, ch = pcall(c.getDimensions, c)
  if not okD then return true end
  if cw == ground.freeW and ch == ground.freeH then return true end
  -- some other pass (a shadow map, a bake): wait for the real one
  note("canvas", "a %sx%s canvas was bound at a terrain shape, not the %sx%s free canvas; waiting",
       tostring(cw), tostring(ch), tostring(ground.freeW), tostring(ground.freeH))
  return false
end

local function onFirstShape(ground)
  local view, vw, vh = ground.view3d, ground.freeW, ground.freeH
  if not (view and vw and vh and view.matrix and view.forward) then return true end
  if not freeCanvasBound(ground) then return false end   -- keep armed: wait for the real one
  local map = ground.terrariumMap
  local painted = false
  local gok, gerr = guarded(function()
    local g = love.graphics
    if g.origin then g.origin() end
    local sky = paintSky2D(ground, view, vw, vh, map, S.hideHorizon)
    painted = sky
    if sky then
      local Bridge = optional("Gen4Bridge")
      if Bridge and Bridge.runPre and not (Bridge.disabled and Bridge.disabled.sky) then
        Bridge.runPre(ground)
      end
    end
  end)
  if not gok then warnOnce("first", "sky pass failed: %s", tostring(gerr)) end
  S.status = painted and "sky painted" or "sky had nothing to paint; engine horizon kept"
  return true
end

function S.install()
  if S.installed then return true end
  local okG, Ground = pcall(require, "src.render.Gen4Ground")
  local okM, Model = pcall(require, "src.render.Gen4Model")
  if not (okG and type(Ground) == "table" and type(Ground.drawFree) == "function"
          and okM and type(Model) == "table" and type(Model.draw) == "function") then
    S.status = "no Gen 4 engine to hook"
    return false
  end
  local Bridge = optional("Gen4Bridge")
  if not (Bridge and Bridge.registerPre) then
    S.status = "Gen4Bridge has no registerPre (old Gen4Bridge.lua)"
    return false
  end
  S.Ground, S.Model = Ground, Model
  -- SkyLayer opens with Tilt:drawSkyPanorama (the engine's sky picture); drawLayers
  -- stubs it for the length of the call, so the handle must exist whatever autoHide is
  local okT, Tilt = pcall(require, "src.render.Tilt")
  S.tilt = (okT and type(Tilt) == "table") and Tilt or nil
  S.originalDrawFree, S.originalModelDraw = Ground.drawFree, Model.draw
  S.originalScenery = nil

  Bridge.registerPre("sky", S.drawLayers)

  -- Gen 4 only ever loads this on a Gen 4 cartridge, so replacing the scenery ring
  -- here cannot reach Gen 1-3
  local Backdrop = optional("Backdrop")
  if Backdrop then
    S.originalScenery = Backdrop.drawOverworldScenery
  end

  local originalFree = Ground.drawFree
  Ground.drawFree = function(self, ...)
    if not S.enabled then return originalFree(self, ...) end
    local Sky = optional("Sky")
    local okB, bands = pcall(function() return Sky and Sky.bands and Sky.bands() end)
    local active = okB and bands and outdoors(self.terrariumMap) and true or false
    armed = active and self or nil
    local swapped
    if active and S.hideHorizon and S.autoHide then
      pcall(scan, Ground)
      swapped = neutralise()
    end
    hiding = active and S.hideHorizon
    local ok, a, b = pcall(originalFree, self, ...)
    hiding, armed = false, nil
    if swapped then restore(swapped) end
    if ok then return a, b end
    if swapped and #swapped > 0 then
      -- something we turned into a no-op was needed. Stop doing that and redraw once.
      S.autoHide = false
      warnOnce("autohide", "drawFree threw with %d engine call(s) hidden (%s); auto-hide is OFF "
               .. "from now on -- add the right name to HIDE_EXTRA instead", #swapped, tostring(a))
      return originalFree(self, ...)
    end
    error(a, 0)
  end

  local originalDraw = Model.draw
  Model.draw = function(self, ...)
    if armed then
      local ground = armed
      local okH, done = pcall(onFirstShape, ground)
      if not okH then
        warnOnce("first", "sky pass failed: %s", tostring(done))
        done = true
      end
      if done then armed = nil end
    end
    if hiding and #S.SHAPE_WORDS > 0 and type(self.shapes) == "table" then
      local real = self.shapes
      local keep, dropped = {}, 0
      for _, shape in ipairs(real) do
        if shapeIsHorizon(shape) then
          dropped = dropped + 1
          note("shape:" .. tostring(shape.name), "skipping engine horizon shape '%s'", tostring(shape.name))
        else
          keep[#keep + 1] = shape
        end
      end
      if dropped > 0 then
        self.shapes = keep
        local ok, r = pcall(originalDraw, self, ...)
        self.shapes = real
        if not ok then error(r, 0) end
        return r
      end
    end
    return originalDraw(self, ...)
  end

  if Backdrop then Backdrop.drawOverworldScenery = drawSceneryRing end

  S.installed = true
  S.status = "installed"
  return true
end

function S.uninstall()
  if not S.installed then return end
  S.Ground.drawFree = S.originalDrawFree
  S.Model.draw = S.originalModelDraw
  local Backdrop = optional("Backdrop")
  if Backdrop and S.originalScenery then Backdrop.drawOverworldScenery = S.originalScenery end
  releaseRing()
  S.installed = false
  S.status = "uninstalled"
end

return S
