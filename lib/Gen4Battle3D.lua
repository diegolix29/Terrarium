-- Gen4Battle3D: a battle fought IN Platinum's own 3D world, with Terrarium's
-- actors stood up on top of it.
--
-- WHAT THE GEN 1-3 PATH DOES, AND WHY IT CANNOT BE USED HERE
--
-- OverworldBattle stages a fight by extruding the tilemap into voxels, solving a
-- camera over them and rendering that to a canvas behind the battle screen. Gen
-- 4 already HAS a real 3D world (src/render/Gen4Ground.lua), so there is nothing
-- to build and the voxel arena would replace the game's own terrain, buildings
-- and lighting with a copy. Here the world is the engine's, unchanged.
--
-- WHAT IS THE ENGINE'S, AND STAYS THE ENGINE'S
--
--   * the world: Gen4Ground keeps drawing the live map under the battle. The
--     engine's own BATTLE BG "world" mechanism does that -- a battle that
--     reports bgMode() == "world" is non-opaque, so the overworld under it keeps
--     drawing (Game.drawBaseInStack).
--   * the healthboxes, the text area and the menus: untouched.
--
-- WHAT THIS MODULE ADDS (engine files untouched, all by wrapping)
--
--   * the CAMERA: Gen4Ground:placeCamera is asked every frame where to point the
--     free camera. While a battle is staged it is pointed at the midpoint of the
--     two combatants. It STARTS behind the player looking toward the foe, and
--     the player can move it from there -- orbit all the way round, raise and
--     lower it, zoom -- with the same devices as the Gen 1-3 battles (mouse,
--     right stick, drag, wheel, Q/E, pinch: lib/CamControl.lua routes them here
--     while a Gen 4 battle is live). The player's own kept look (orbit, zoom) is
--     restored after every call, so when the battle ends the camera is exactly
--     where they left it. On a CAM TILT rung the view is switched to the
--     third-person lens for the fight, because a tilt rung's camera is fixed by
--     design and could not be moved; it is switched back afterwards.
--   * the ACTORS: the two Pokemon are the engine's own battle pics (the same
--     image battle:battlerPic hands the 2D screen), stood up as camera-facing
--     quads on the ground, drawn through Gen4Bridge so they are depth-tested
--     against the real terrain and buildings. SPRITES ONLY: Gen 4 has no 3D
--     Pokemon models in this pipeline, so the COLOSSEUM and STADIUM rungs of the
--     3D-BTL row draw sprites here rather than models.
--   * the 2D FIELD is switched off (BattleState:drawBattleField, the seam the
--     engine names for exactly this) and the 2D pics with it, or every Pokemon
--     would be drawn twice.
--
-- WHEN IT DECLINES (the engine's own 2D Sinnoh battle then plays, unchanged)
--
--   * the camera is not a free one. On the default CARTRIDGE rung Gen4Ground
--     bakes an oblique picture with its own depth units and has no camera to
--     move -- see GEN4_PORT_NOTES.md.
--   * first person (the player IS the eye).
--   * there is no clear stretch of ground: the foe stands 3-4 tiles away, on
--     walkable cells, at a similar height.
--
-- KNOWN GAPS: move-animation particles, the thrown ball and the healthboxes are
-- Platinum's 2D layers, positioned for the DS screen's slots; they are not yet
-- tracked to the 3D actors.

local V = ...
local Bridge = V.require("Gen4Bridge")
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")

local M = {
  SCALE = 0.5,        -- world units per sprite pixel (80px pic -> 40 units)
  HD_HEIGHT = 20,     -- world units tall for HD Pokemon sprites (any pixel size); lower = smaller
  MIN_DIST = 3,       -- tiles between the two combatants
  MAX_DIST = 4,
  MAX_STEP = 12,      -- tallest ground step allowed between them, world units
  ZOOM = 1.25,        -- starting third-person orbit radius multiple
  RISE = 8,           -- starting extra elevation, degrees
  installed = false,

  -- camera controls: same devices as BattleCam, with their own scales because
  -- this orbit is a full turn rather than a fraction of a range
  ZOOM_STEP = 1.15,           -- radius multiple per wheel notch
  ORBIT_MOUSE = 0.0045,       -- radians per mouse count
  PITCH_MOUSE = 0.12,         -- degrees per mouse count
  ORBIT_DRAG = 3.4,           -- radians per screen width
  PITCH_DRAG = 70,            -- degrees per screen height
  ORBIT_STICK = 2.6,          -- radians per second, full tilt
  PITCH_STICK = 70,           -- degrees per second, full tilt
  STICK_DEAD = 0.2,
  EASE = 0.07,                -- seconds for the eye to catch its goal
}

local session = nil
local quad = nil

-- The player's adjustments to the shot, as offsets from where it was solved.
-- Goals are what the input sets; the values are eased toward them per frame so
-- a click of the wheel or a flick of the mouse glides rather than jumps.
local cam = { orbit = 0, orbitGoal = 0, rise = 0, riseGoal = 0,
              zoom = 1, zoomGoal = 1, at = nil }

local function resetCamera()
  cam.orbit, cam.orbitGoal, cam.rise, cam.riseGoal = 0, 0, 0, 0
  cam.zoom, cam.zoomGoal, cam.at = 1, 1, nil
end
local atan2 = math.atan2 or math.atan

local DELTA = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
local TURN = {
  up = { "up", "right", "left", "down" },
  down = { "down", "left", "right", "up" },
  left = { "left", "up", "down", "right" },
  right = { "right", "down", "up", "left" },
}

local function log(level, fmt, ...)
  if V.mod and V.mod.log and V.mod.log[level] then
    V.mod.log[level](V.mod.log, "Gen4Battle3D: " .. fmt:format(...))
  end
end

local warned = {}
local function once(key, level, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  log(level, fmt, ...)
end

local function game() return require("src.core.Game") end

-- ------------------------------------------------------------- lifecycle --

function M.active(battle)
  if not session then return false end
  return battle == nil or session.battle == battle
end

local function overworld()
  local g = game()
  return g and g.overworld
end

-- The battle is over when the overworld is on top again after having been
-- covered. Polled from the wrappers rather than trusted to an event, so a
-- battle that ends some unusual way cannot leave the world hidden for good.
local function alive()
  if not session then return false end
  local g = game()
  local top = g and g.stack and g.stack:top()
  local ow = g and g.overworld
  if top ~= nil and top ~= ow then
    session.armed = true
  elseif session.armed then
    M.finish()
    return false
  end
  return true
end

-- Whether a Gen 4 battle is staged AND on screen -- `armed` is set by alive()
-- once the battle covers the overworld, which is when the player may steer it,
-- and not during the transition wipe that plays first. Asked by CamControl to
-- decide where the wheel, mouse, stick and touch go.
function M.live()
  return session ~= nil and session.armed == true
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function riseBounds()
  local View = M.View
  local lo = (View and View.ORBIT_RISE_MIN) or -12
  local hi = (View and View.ORBIT_RISE_MAX) or 60
  return lo - M.RISE, hi - M.RISE
end

local function setOrbit(v) cam.orbitGoal = v; return true end
local function setRise(v)
  local lo, hi = riseBounds()
  local was = cam.riseGoal
  cam.riseGoal = clamp(v, lo, hi)
  return cam.riseGoal ~= was
end

-- Every entry point mirrors BattleCam's, argument for argument, so CamControl
-- can hand its inputs to either camera through one name.
function M.mouseOrbit(dx) return setOrbit(cam.orbitGoal + (dx or 0) * M.ORBIT_MOUSE) end
function M.mousePitch(dy) return setRise(cam.riseGoal + (dy or 0) * M.PITCH_MOUSE) end
function M.dragOrbit(f) return setOrbit(cam.orbitGoal + (f or 0) * M.ORBIT_DRAG) end
function M.dragPitch(f) return setRise(cam.riseGoal + (f or 0) * M.PITCH_DRAG) end

local function curve(v)
  local a = math.abs(v or 0)
  if a < M.STICK_DEAD then return 0 end
  a = (a - M.STICK_DEAD) / (1 - M.STICK_DEAD)
  return ((v < 0) and -1 or 1) * a * a
end
function M.stickOrbit(x, dt)
  local v = curve(x)
  if v == 0 then return false end
  return setOrbit(cam.orbitGoal + v * M.ORBIT_STICK * (dt or 0))
end
function M.stickPitch(y, dt)
  local v = curve(y)
  if v == 0 then return false end
  return setRise(cam.riseGoal + v * M.PITCH_STICK * (dt or 0))
end

-- Notches, POSITIVE pulls the camera OUT (like every zoom in the mod).
function M.stepZoom(notches)
  if not session then return false end
  local View = M.View
  local lo = ((View and View.ZOOM_MIN) or 0.45) / M.ZOOM
  local hi = ((View and View.ZOOM_MAX) or 2.6) / M.ZOOM
  local was = cam.zoomGoal
  cam.zoomGoal = clamp(was * (M.ZOOM_STEP ^ (notches or 0)), lo, hi)
  return cam.zoomGoal ~= was
end

-- Ease the values toward their goals by the time since the last frame. The
-- clock is read here rather than passed in because placeCamera -- the one
-- place this runs -- is called once per drawn frame.
local function advance()
  local now = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
  local dt = cam.at and (now - cam.at) or 0
  cam.at = now
  if dt < 0 then dt = 0 elseif dt > 0.1 then dt = 0.1 end
  local k = 1 - math.exp(-dt / M.EASE)
  local function toward(cur, goal)
    local d = goal - cur
    if math.abs(d) < 1e-4 then return goal end
    return cur + d * k
  end
  cam.orbit = toward(cam.orbit, cam.orbitGoal)
  cam.rise = toward(cam.rise, cam.riseGoal)
  cam.zoom = toward(cam.zoom, cam.zoomGoal)
  return dt
end

local function pickFoe(state, ground, mode)
  local map, player = state.map, state.player
  local cx, cy = player.cellX, player.cellY
  if not (map and cx and cy and map.inBounds and map.isWalkableCell) then return nil end
  local px = cx * 16 + (ground.FEET_X or 8)
  local pz = cy * 16 + (ground.FEET_X or 8)
  local baseY = ground:groundY(px, pz) or 0

  local order = TURN[tostring(player.facing)] or TURN.up
  for _, dir in ipairs(order) do
    local d = DELTA[dir]
    for dist = M.MAX_DIST, M.MIN_DIST, -1 do
      local ex, ey = cx + d[1] * dist, cy + d[2] * dist
      local clear = map:inBounds(ex, ey)
      for step = 1, dist do
        if not clear then break end
        local sx, sy = cx + d[1] * step, cy + d[2] * step
        local okW, walk = pcall(map.isWalkableCell, map, sx, sy)
        clear = okW and walk and true or false
      end
      if clear then
        local fx = ex * 16 + (ground.FEET_X or 8)
        local fz = ey * 16 + (ground.FEET_X or 8)
        local gy = ground:groundY(fx, fz) or 0
        if math.abs(gy - baseY) <= M.MAX_STEP then
          return { cx = ex, cy = ey, x = fx, z = fz, dir = dir }
        end
      end
    end
  end
  return nil
end

-- Stage a battle in the engine's own world. True when it did, which is also
-- the only case where anything visible changes.
function M.begin(state, battle)
  M.finish()
  if not (Bridge.isGen4() and Bridge.installed) then return false end
  if not (state and state.map and state.player and battle) then return false end
  local ground = state.map.renderer and state.map.renderer.gen4Ground
  if not (ground and ground.freeMode and ground.groundY) then return false end
  local okMode, mode = pcall(ground.freeMode, ground)
  if not okMode then return false end
  if mode ~= "third" and mode ~= "field3d" then
    once("mode:" .. tostring(mode), "info",
         "camera is '%s' -- the 3D battle needs third person or a tilt rung; "
         .. "playing the standard Gen 4 battle", tostring(mode))
    return false
  end

  local foe = pickFoe(state, ground, mode)
  if not foe then
    once("nofoe", "info", "no clear ground for a 3D battle here; playing the standard one")
    return false
  end

  local player = state.player
  local pxFeet = player.cellX * 16 + (ground.FEET_X or 8)
  local pzFeet = player.cellY * 16 + (ground.FEET_X or 8)
  local dx, dz = foe.x - pxFeet, foe.z - pzFeet
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 1 then return false end

  session = {
    battle = battle, state = state, ground = ground, mode = mode,
    player = { x = pxFeet, z = pzFeet },
    enemy = { x = foe.x, z = foe.z },
    -- Gen4View:follow looks along (sin f, -cos f), so this looks player -> foe
    yaw = atan2(dx / len, -dz / len),
    pivotX = (pxFeet + foe.x) / 2 - (ground.FEET_X or 8),
    pivotZ = (pzFeet + foe.z) / 2 - (ground.FEET_X or 8),
    zoom = M.ZOOM, rise = M.RISE,
    armed = false,
  }
  resetCamera()

  -- Nobody else stands in the shot, and the player's own sprite gives way to
  -- the Pokemon that takes its place. Only the DRAW lists change, and only while
  -- the overworld is frozen under the battle; both go back in finish().
  session.entities, session.ghosts = state.entities, state.ghosts
  state.entities, state.ghosts = {}, {}

  -- The overworld must keep drawing under the battle, and undimmed.
  battle.isOpaque = false
  battle.BG_WORLD_DIM = 0

  log("info", "staged in the native world (%s camera, foe %d tiles %s)",
      mode, math.max(math.abs(foe.cx - player.cellX), math.abs(foe.cy - player.cellY)),
      foe.dir)
  return true
end

local function restoreViews(s)
  for _, saved in ipairs(s.views or {}) do
    if saved.view and saved.view.mode == "third" then saved.view.mode = saved.mode end
  end
  s.views = nil
end

function M.finish()
  local s = session
  if not s then return end
  session = nil
  restoreViews(s)
  resetCamera()
  if s.state then
    if s.entities then s.state.entities = s.entities end
    if s.ghosts then s.state.ghosts = s.ghosts end
  end
end

-- ---------------------------------------------------------------- actors --

local function unitQuad()
  if quad then return quad end
  local verts, map = {}, {}
  verts[1] = { -0.5, 0, 0, 0, 1, 1, 0 }   -- bottom-left
  verts[2] = {  0.5, 0, 0, 1, 1, 1, 0 }   -- bottom-right
  verts[3] = {  0.5, 1, 0, 1, 0, 1, 0 }   -- top-right
  verts[4] = { -0.5, 1, 0, 0, 0, 1, 0 }   -- top-left
  Voxel3D.pushQuad(map, 0)
  quad = Voxel3D.newMesh(verts, map)
  return quad
end

local function drawActor(scene, battle, battler, spot)
  if not battler or battler.fainted then return end
  local okEngine, Gen4Battle = pcall(require, "src.battle.Gen4Battle")
  if okEngine and Gen4Battle then
    local okH, hidden = pcall(Gen4Battle.battlerHidden, battle, battler)
    if okH and hidden then return end
  end
  if not battle.battlerPic then return end
  local pic
  local isHd = false
  local HDSheets = V.HDPokemonSheets or (V.mod and V.mod.exports and V.mod.exports.hdPokemonSheets)
  if HDSheets and type(HDSheets.frame) == "function" then
    -- 3D battles use the FRONT sheet for both sides; back sheets are for
    -- followers and roamers only.
    local side = "front"
    local mon = battler.mon or battler
    local dex = mon and (mon.dex or mon.nationalDex or mon.speciesIndex)
    local shiny = mon and (mon.shiny or mon.isShiny)
    if dex then
      local image, info = HDSheets.frame({dex = dex, facing = side, shiny = shiny})
      if image then pic = image; isHd = true end
    end
  end
  if not pic then
    local okP, enginePic = pcall(battle.battlerPic, battle, battler)
    if not (okP and enginePic and enginePic.getWidth) then return end
    pic = enginePic
  end
  if isHd then pcall(pic.setFilter, pic, "linear", "linear")
  else pcall(pic.setFilter, pic, "nearest", "nearest") end

  local scale = 1
  local yLower = 0
  if okEngine and Gen4Battle then
    local okA, absorb = pcall(Gen4Battle.ballAbsorb, battle, battler)
    if okA and type(absorb) == "number" then scale = absorb end
    local okO, off = pcall(Gen4Battle.spriteYOffset, battle, battler)
    if okO and type(off) == "number" then yLower = off end
  end
  if scale <= 0.001 then return end

  local unit = M.SCALE
  if isHd then unit = M.HD_HEIGHT / math.max(1, pic:getHeight()) end
  local w = pic:getWidth() * unit * scale
  local h = pic:getHeight() * unit * scale
  local gy = scene.groundY(spot.x, spot.z) or 0
  local wx, wz = scene.toWorld(spot.x, spot.z)
  local y = math.max(gy - 3, gy - yLower * unit)

  -- face the camera: rotateY maps +z to (sin a, cos a)
  local ex, ez = scene.eye[1], scene.eye[3]
  local a = atan2(ex - wx, ez - wz)
  local model = Mat4.mul(Mat4.mul(Mat4.translate(wx, y, wz), Mat4.rotateY(a)),
                         Mat4.scale(w, h, 1))
  Voxel3D.draw(unitQuad(), pic, model, 0)
end

local function drawActors(scene)
  if not alive() then return end
  local s = session
  if s.ground ~= scene.ground then return end
  Voxel3D.seams(false)
  Voxel3D.glass(false)
  drawActor(scene, s.battle, s.battle.enemy, s.enemy)
  drawActor(scene, s.battle, s.battle.player, s.player)
  Voxel3D.seams(true)
  Voxel3D.glass(true)
end

-- --------------------------------------------------------------- install --

function M.install()
  if M.installed then return true end
  if not Bridge.isGen4() then return false end
  local okG, Ground = pcall(require, "src.render.Gen4Ground")
  local okV, View = pcall(require, "src.render.Gen4View")
  local okB, BattleState = pcall(require, "src.battle.BattleState")
  if not (okG and okV and okB and Ground.placeCamera and View.look
          and BattleState.drawBattleField and BattleState.drawBattlerPic
          and BattleState.bgMode) then
    return false
  end
  M.Ground, M.View, M.BattleState = Ground, View, BattleState
  M.original = {
    placeCamera = Ground.placeCamera,
    drawBattleField = BattleState.drawBattleField,
    drawBattlerPic = BattleState.drawBattlerPic,
    bgMode = BattleState.bgMode,
  }

  -- the camera
  function Ground:placeCamera(px, py, facing)
    local s = session
    if not (s and s.ground == self and self.view3d and alive()) then
      return M.original.placeCamera(self, px, py, facing)
    end
    -- a tilt rung's camera is fixed by design; use the third-person lens for
    -- the fight so it can be moved, and put it back when the fight is over
    local view = self.view3d
    if view.mode == "field3d" then
      s.views = s.views or {}
      s.views[#s.views + 1] = { view = view, mode = "field3d" }
      view.mode = "third"
    end
    -- stick input is a held position, so only a tick can turn it into travel
    local dt = advance()
    pcall(function() V.require("CamControl").tick(dt) end)
    local kept = View.look
    local o, y, r, z, h = kept.orbiting, kept.yaw, kept.rise, kept.zoom, kept.heading
    local yaw = s.yaw + cam.orbit
    kept.orbiting, kept.yaw, kept.rise, kept.zoom = true, yaw, s.rise + cam.rise, s.zoom * cam.zoom
    local ok, err = pcall(M.original.placeCamera, self, s.pivotX, s.pivotZ, yaw)
    kept.orbiting, kept.yaw, kept.rise, kept.zoom, kept.heading = o, y, r, z, h
    if not ok then error(err, 0) end
  end

  -- the world stays; the engine's 2D field and 2D pics step aside
  function BattleState:drawBattleField(...)
    if session and session.battle == self then return end
    return M.original.drawBattleField(self, ...)
  end
  function BattleState:drawBattlerPic(...)
    if session and session.battle == self then return end
    return M.original.drawBattlerPic(self, ...)
  end
  function BattleState:bgMode(...)
    if session and session.battle == self then return "world" end
    return M.original.bgMode(self, ...)
  end

  Bridge.register("battleActors", drawActors)
  M.installed = true
  return true
end

function M.uninstall()
  if not M.installed then return end
  M.Ground.placeCamera = M.original.placeCamera
  M.BattleState.drawBattleField = M.original.drawBattleField
  M.BattleState.drawBattlerPic = M.original.drawBattlerPic
  M.BattleState.bgMode = M.original.bgMode
  Bridge.setEffect("battleActors", false)
  M.finish()
  M.installed = false
end

return M