-- Gen4Bridge: Terrarium's effects, drawn INTO the engine's own Gen 4 world.
--
-- WHY THIS EXISTS
--
-- On Gen 1/2/3 this mod builds the 3D world itself: it extrudes the tilemap
-- into voxels and owns the frame through the `voxel` render pipeline. Gen 4
-- (Platinum) already has a real 3D world -- src/render/Gen4Ground.lua draws
-- terrain and buildings from the cartridge's own models through a real camera
-- (src/render/Gen4View.lua) -- so there is nothing to extrude, and letting the
-- voxel pipeline take the world pass would REPLACE that world with a voxelised
-- tilemap. So on Gen 4 the `voxel` pipeline stands down (see main.lua:
-- `available`) and this module runs instead. It adds effects on top of the
-- engine's world and never replaces any of it.
--
-- HOW IT HOOKS IN (engine untouched)
--
-- In a free camera (third / first person, and every numeric CAM TILT rung)
-- Gen4Ground:drawFree() leaves its canvas OPEN -- colour + depth -- while the
-- overworld draws characters into it, and Gen4Ground:endFree() closes it. This
-- module wraps endFree(): just before the original runs, the canvas still holds
-- terrain + buildings + characters with a live depth buffer, so anything drawn
-- now is depth-tested against the real scene. That is the whole seam.
--
-- The mod's own shader renderer (Voxel3D) already has an "external target"
-- mode (beginScene with slot "current") that draws into whatever canvas is
-- bound, and an explicit-camera mode (Voxel3D.camera with view/proj). We feed
-- it Gen4View's own view-projection matrix, so a mesh placed at a Gen 4 world
-- position lands exactly where the engine would put it, and every uniform the
-- shader takes (wind, water, tint, glass mask, lamps, fog) keeps working.
--
-- Coordinates are shared: +x east, +y up, +z south, one unit per map pixel,
-- sixteen per tile -- the voxel scene's convention too. A Gen 4 map adds its
-- matrix origin (ground.offsetX / offsetY) to a map-pixel position.
--
-- NOT COVERED YET: the CARTRIDGE (oblique) rung, where Gen4Ground bakes chunks
-- with its own depth units. Effects only draw when the camera is a free one.
-- See GEN4_PORT_NOTES.md.

local V = ...
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")

local Bridge = {
  effects = {},      -- name -> draw(scene)
  order = {},        -- registration order == draw order
  pre = {},          -- name -> draw(scene): effects drawn BEFORE the terrain (the sky),
  preOrder = {},     -- into the same open Voxel3D scene, see Bridge.runPre
  after = {},        -- fn(ground, view, vw, vh): screen passes run once the effects
                     -- are drawn and BEFORE the engine blits the frame (Gen4Reflect)
  disabled = {},     -- name -> true when switched off
  enabled = true,    -- master switch
  installed = false,
  reported = {},
}

local function report(key, fmt, ...)
  if Bridge.reported[key] then return end
  Bridge.reported[key] = true
  if V.mod and V.mod.log then
    V.mod.log:warn("Gen4Bridge: " .. fmt:format(...))
  end
end

-- ------------------------------------------------------------ detection --

local function generation()
  local ok, GameVersion = pcall(require, "src.core.GameVersion")
  if not (ok and GameVersion and GameVersion.generation) then return nil end
  local okGen, value = pcall(GameVersion.generation)
  return okGen and tonumber(value) or nil
end

function Bridge.isGen4()
  return generation() == 4
end

-- True when this module owns Terrarium's world-side effects: a Gen 4 game AND
-- the hook is in. main.lua's `voxel` pipeline asks this to stand down.
function Bridge.active()
  return Bridge.installed and Bridge.isGen4()
end

-- ------------------------------------------------------------- registry --

-- register(name, drawFn [, opts]). drawFn(scene) runs inside an open Voxel3D
-- scene (shader bound, depth test on, depth write on). Effects that blend
-- (glass, water) should call scene.blend() first and scene.opaque() after.
function Bridge.register(name, fn)
  if type(fn) ~= "function" then return false end
  if not Bridge.effects[name] then Bridge.order[#Bridge.order + 1] = name end
  Bridge.effects[name] = fn
  return true
end

-- registerPre(name, drawFn): like register, but the effect runs BEFORE the first
-- terrain shape of the frame (Gen4Sky's hook calls Bridge.runPre then), with the
-- depth buffer still clear. Nothing is drawn over yet, so the effect is the
-- backdrop: everything the engine draws afterwards covers it. Same scene, same
-- error isolation as register.
function Bridge.registerPre(name, fn)
  if type(fn) ~= "function" then return false end
  if not Bridge.pre[name] then Bridge.preOrder[#Bridge.preOrder + 1] = name end
  Bridge.pre[name] = fn
  return true
end

function Bridge.setEffect(name, on)
  Bridge.disabled[name] = (on == false) or nil
end

-- --------------------------------------------------------------- scene --

local FOCUS_DISTANCE = 128   -- only used to give Voxel3D an eye->focus vector

local function buildScene(ground, view, vw, vh)
  local offX, offZ = ground.offsetX or 0, ground.offsetY or 0
  local fx, fy, fz = view:forward()
  local scene = {
    ground = ground, view = view, vw = vw, vh = vh,
    map = ground.terrariumMap,            -- tagged in install(); may be nil
    offsetX = offX, offsetZ = offZ,
    eye = { view.x, view.y, view.z },
    forward = { fx, fy, fz },
    clock = ground.clock,
    Voxel3D = Voxel3D, Mat4 = Mat4,
  }
  -- map pixel -> world x,z
  function scene.toWorld(px, py) return px + offX, py + offZ end
  -- terrain height (world units) at a map-pixel position
  function scene.groundY(px, py) return ground:groundY(px, py) end
  -- where the view ray meets the ground, in MAP PIXELS: the centre for culling.
  function scene.focusPx()
    local ex, ez = view.x - offX, view.z - offZ
    local gy = ground:groundY(ex, ez) or 0
    if fy < -0.05 then
      local t = math.min((view.y - gy) / -fy, 900)
      return ex + fx * t, ez + fz * t
    end
    return ex + fx * 160, ez + fz * 160
  end
  -- Voxel3D.depth() only knows "always" and test+write, so a blended pass
  -- (glass, water: tested against the scene but never written) sets the mode
  -- itself. The scene is open when these run, so the shader stays bound.
  function scene.blend()
    love.graphics.setDepthMode("lequal", false)
  end
  function scene.opaque()
    love.graphics.setDepthMode("lequal", true)
  end
  return scene
end

local function runScene(ground, view, vw, vh, order, effects, tag)
  local vp = view:matrix(vw, vh)          -- Gen4's world->clip, Y already flipped
  local fx, fy, fz = view:forward()
  local saved = Voxel3D.camera
  Voxel3D.camera = {
    eye = { view.x, view.y, view.z },
    focus = { view.x + fx * FOCUS_DISTANCE, view.y + fy * FOCUS_DISTANCE,
              view.z + fz * FOCUS_DISTANCE },
    fov = math.rad(view:effectiveFovY(vh)),
    curve = 0,                            -- Gen 4 draws a flat world: no horizon bend
    -- Voxel3D.viewProjection returns S * proj * view with S = scale(1,-1,1).
    -- Gen4View:matrix already applied that flip, so cancel it here:
    -- S * (S * vp) * I == vp.
    view = Mat4.identity(),
    proj = Mat4.mul(Mat4.scale(1, -1, 1), vp),
  }
  local began = Voxel3D.beginScene(vw, vh, view.x, view.z, vw, vh, nil, "current")
  if not began then
    Voxel3D.camera = saved
    return
  end
  local scene = buildScene(ground, view, vw, vh)
  for _, name in ipairs(order) do
    if not Bridge.disabled[name] then
      local ok, err = pcall(effects[name], scene)
      if not ok then
        report(tag .. name, "effect '%s' failed: %s", name, tostring(err))
        Bridge.disabled[name] = true      -- don't fail every frame
      end
    end
  end
  Voxel3D.endScene()
  Voxel3D.camera = saved
end

function Bridge.run(ground)
  if not (Bridge.enabled and #Bridge.order > 0) then return end
  local view, vw, vh = ground.view3d, ground.freeW, ground.freeH
  if not (view and vw and vh and view.matrix and view.forward) then return end
  if not Bridge.isGen4() then return end
  local ok, err = pcall(runScene, ground, view, vw, vh, Bridge.order, Bridge.effects, "fx:")
  if not ok then
    -- make sure a throw between beginScene/endScene can't leave state behind
    pcall(Voxel3D.endScene)
    report("scene", "scene failed: %s", tostring(err))
  end
  for i, fn in ipairs(Bridge.after) do
    local okA, errA = pcall(fn, ground, view, vw, vh)
    if not okA then
      report("after:" .. i, "screen pass %d failed: %s", i, tostring(errA))
    end
  end
end

-- The pre-terrain pass. Called by Gen4Sky from inside Gen4Ground:drawFree, on the
-- first terrain shape, while the free canvas is bound and its depth is clear.
-- Returns true when the scene ran.
function Bridge.runPre(ground)
  if not (Bridge.enabled and #Bridge.preOrder > 0) then return false end
  local view, vw, vh = ground.view3d, ground.freeW, ground.freeH
  if not (view and vw and vh and view.matrix and view.forward) then return false end
  if not Bridge.isGen4() then return false end
  local ok, err = pcall(runScene, ground, view, vw, vh, Bridge.preOrder, Bridge.pre, "pre:")
  if not ok then
    pcall(Voxel3D.endScene)
    report("prescene", "pre-terrain scene failed: %s", tostring(err))
    return false
  end
  return true
end

-- ------------------------------------------------------------- install --

function Bridge.install()
  if Bridge.installed then return true end
  local ok, Ground = pcall(require, "src.render.Gen4Ground")
  if not (ok and type(Ground) == "table" and type(Ground.endFree) == "function") then
    return false      -- not a Gen 4 build of the engine: nothing to hook
  end
  Bridge.Ground = Ground
  Bridge.originalEndFree = Ground.endFree
  Bridge.originalForMap = Ground.forMap

  -- Tag each ground with the Map it was built for; effects need the map's
  -- cell queries (grass, water) and Gen4Ground doesn't keep the map itself.
  if type(Ground.forMap) == "function" then
    local forMap = Ground.forMap
    Ground.forMap = function(map, data, ...)
      local g = forMap(map, data, ...)
      if g then g.terrariumMap = map end
      return g
    end
  end

  local original = Ground.endFree
  Ground.endFree = function(self, ...)
    -- Runs while the free canvas is still open (colour + depth): terrain,
    -- buildings and characters are already in it. See the header.
    if Ground.freeOpen and self and self.freeW then Bridge.run(self) end
    return original(self, ...)
  end
  Bridge.installed = true

  -- The passes that belong to every Gen 4 game, registered here so they are
  -- FIRST in draw order: the water sheet is opaque and writes depth, and what
  -- main.lua registers after install() (grass, the battle actors) draws over it.
  local okW, GW = pcall(V.require, "Gen4Water")
  if okW and type(GW) == "table" and GW.draw then
    Bridge.register("water", GW.draw)
  else
    report("water", "the water pass did not load: %s", tostring(GW))
  end
  -- The voxel scene's textured ground on the beach sand. Opaque, so it goes
  -- before grass and the actors, after the water it may sit beside.
  local okS, GS = pcall(V.require, "Gen4Sand")
  if okS and type(GS) == "table" and GS.draw then
    Bridge.register("sand", GS.draw)
  else
    report("sand", "the sand pass did not load: %s", tostring(GS))
  end
  -- The voxel scene's 3D trees in place of Platinum's flat tree cards. Opaque,
  -- after the ground passes, before grass and the actors.
  local okT, GT = pcall(V.require, "Gen4Trees")
  if okT and type(GT) == "table" and GT.draw then
    Bridge.register("trees", GT.draw)
  else
    report("trees", "the tree pass did not load: %s", tostring(GT))
  end
  -- The voxel scene's sky (bands, clouds, sun/moon, stars, painted horizon, scenery)
  -- on Gen 4, with the engine's own horizon image hidden. Pre-terrain, so it is
  -- the backdrop. See lib/Gen4Sky.lua.
  local okK, GK = pcall(V.require, "Gen4Sky")
  if okK and type(GK) == "table" and GK.install then
    local okI, errI = pcall(GK.install)
    if not (okI and errI ~= false) then report("sky", "the sky pass did not install: %s", tostring(errI)) end
  else
    report("sky", "the sky pass did not load: %s", tostring(GK))
  end
  return true
end

function Bridge.uninstall()
  if not Bridge.installed then return end
  pcall(function() V.require("Gen4Sky").uninstall() end)
  Bridge.Ground.endFree = Bridge.originalEndFree
  Bridge.Ground.forMap = Bridge.originalForMap
  Bridge.installed = false
end

return Bridge
