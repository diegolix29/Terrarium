-- Direct player control for Gold live-world Stadium battles.
--
-- Presentation-only: Gold still owns turns, HP, damage, PP, switching, items,
-- status and outcomes.  This module owns only the live 3D actor anchor.  The
-- v0.3.20 movement model is velocity-based instead of teleporting the model a
-- fixed amount every tick, giving the left stick acceleration, deceleration,
-- analog speed, arena-wall sliding and a softer opponent separation.
local V = ...
local M = {}

M.SPEED = 42.0
M.DEADZONE = 0.16
M.ARENA_RADIUS = 62.0
M.MIN_ENEMY_GAP = 12.0
M.MAX_ENEMY_GAP = 92.0

local state = {
  active = false,
  attackHeld = false,
  attackPulse = 0,
  origins = {},
  velocity = {},
  selectedSide = nil,
  lastArena = nil,
  moved = false,
  speedNow = 0,
}

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function opt(key, default)
  local options = V and V.mod and V.mod.options
  if not (options and type(options.get) == "function") then return default end
  local ok, value = pcall(options.get, options, key)
  if not ok or value == nil then return default end
  return value
end

local function movementFeel()
  local mode = tostring(opt("battleMovementFeel", "modern")):lower()
  if mode == "tight" then
    return { accel = 16.0, decel = 22.0, turn = 20.0, speed = 1.03 }
  elseif mode == "smooth" then
    return { accel = 7.2, decel = 8.8, turn = 8.5, speed = 0.94 }
  end
  return { accel = 10.5, decel = 14.0, turn = 12.0, speed = 1.0 }
end

local function mechanics()
  local ok, mod = pcall(V.require, "BattleModernMechanics")
  return ok and type(mod) == "table" and mod or nil
end

local function mappedPad()
  local J = love and love.joystick
  if not (J and type(J.getJoysticks) == "function") then return nil end
  local ok, list = pcall(J.getJoysticks)
  if not ok or type(list) ~= "table" then return nil end
  local best, bestMag = nil, -1
  for _, js in ipairs(list) do
    local okPad, isPad = pcall(function()
      return js and type(js.isGamepad) == "function" and js:isGamepad()
    end)
    if okPad and isPad and type(js.getGamepadAxis) == "function" then
      local okX, lx = pcall(js.getGamepadAxis, js, "leftx")
      local okY, ly = pcall(js.getGamepadAxis, js, "lefty")
      if okX and okY then
        lx, ly = tonumber(lx) or 0, tonumber(ly) or 0
        local mag = lx * lx + ly * ly
        if mag > bestMag then best, bestMag = { js=js, x=lx, y=ly }, mag end
      end
    end
  end
  return best
end

local function buttonDown(js, button)
  if not (js and type(js.isGamepadDown) == "function") then return false end
  local ok, down = pcall(js.isGamepadDown, js, button)
  return ok and down and true or false
end

local function keyboardMove()
  local K = love and love.keyboard
  if not (K and type(K.isDown) == "function") then return 0, 0 end
  local function down(key)
    local ok, yes = pcall(K.isDown, key)
    return ok and yes and 1 or 0
  end
  -- Arrow keys remain the command-diamond shortcuts. WASD is locomotion.
  return down("d") - down("a"), down("s") - down("w")
end

local function cameraBasis(arena)
  -- Use the camera that actually rendered the last live-battle frame so analog
  -- movement stays camera-relative even while BattleCinematic is orbiting.
  local okV, Voxel3D = pcall(V.require, "Voxel3D")
  local cam = okV and Voxel3D and Voxel3D.camera or nil
  local eye, focus = cam and cam.eye, cam and cam.focus
  local fx, fz
  if type(eye) == "table" and type(focus) == "table" then
    fx = (tonumber(focus[1]) or 0) - (tonumber(eye[1]) or 0)
    fz = (tonumber(focus[3]) or 0) - (tonumber(eye[3]) or 0)
  end
  local len = fx and math.sqrt(fx * fx + fz * fz) or 0
  if not (len and len > 0.001) then
    local p, e = arena and arena.player, arena and arena.enemy
    fx = ((e and tonumber(e[1])) or 0) - ((p and tonumber(p[1])) or 0)
    fz = ((e and tonumber(e[2])) or 0) - ((p and tonumber(p[2])) or 0)
    len = math.sqrt(fx * fx + fz * fz)
  end
  if not (len and len > 0.001) then fx, fz, len = 0, -1, 1 end
  fx, fz = fx / len, fz / len
  return fx, fz, -fz, fx
end

local function reset()
  state.active = false
  state.attackHeld = false
  state.attackPulse = 0
  state.origins = {}
  state.velocity = {}
  state.selectedSide = nil
  state.lastArena = nil
  state.moved = false
  state.speedNow = 0
end

local function controlContext(screen, side)
  local okO, OverworldBattle = pcall(V.require, "OverworldBattle")
  if not okO or not OverworldBattle or type(OverworldBattle.cameraContext) ~= "function" then return nil end
  local ctx = OverworldBattle.cameraContext()
  if not (ctx and ctx.arena and ctx.screen == screen) then return nil end
  local okS, Stadium = pcall(V.require, "Stadium")
  if not okS or not Stadium then return nil end
  side = side or "player"
  if type(Stadium.controlReady) == "function" then
    local okReady, ready = pcall(Stadium.controlReady, side)
    if not (okReady and ready) then return nil end
  elseif side == "player" and type(Stadium.visible) == "function" then
    local okReady, ready = pcall(Stadium.visible, "player")
    if not (okReady and ready) then return nil end
  elseif side ~= "player" then
    return nil
  end
  return ctx, Stadium
end

local function velocityOf(side)
  local v = state.velocity[side]
  if type(v) ~= "table" then
    v = { x=0, z=0 }
    state.velocity[side] = v
  end
  return v
end

local function expApproach(current, target, rate, dt)
  local k = 1 - math.exp(-math.max(0, rate) * math.max(0, dt))
  return current + (target - current) * k
end

local function projectArenaBoundary(nx, nz, ox, oz, vx, vz)
  local dx, dz = nx - ox, nz - oz
  local d = math.sqrt(dx * dx + dz * dz)
  if d <= M.ARENA_RADIUS or d <= 0.001 then return nx, nz, vx, vz end
  local ux, uz = dx / d, dz / d
  nx, nz = ox + ux * M.ARENA_RADIUS, oz + uz * M.ARENA_RADIUS
  -- Remove only the velocity pointing farther outside. Tangential velocity is
  -- preserved, so running along the edge feels like a soft arena wall.
  local outward = vx * ux + vz * uz
  if outward > 0 then vx, vz = vx - ux * outward, vz - uz * outward end
  return nx, nz, vx, vz
end

local function separateOpponent(nx, nz, ex, ez, vx, vz)
  local dx, dz = nx - ex, nz - ez
  local d = math.sqrt(dx * dx + dz * dz)
  if d >= M.MIN_ENEMY_GAP then return nx, nz, vx, vz end
  if d <= 0.001 then dx, dz, d = 0, 1, 1 end
  local ux, uz = dx / d, dz / d
  nx, nz = ex + ux * M.MIN_ENEMY_GAP, ez + uz * M.MIN_ENEMY_GAP
  local inward = -(vx * ux + vz * uz)
  if inward > 0 then vx, vz = vx + ux * inward, vz + uz * inward end
  return nx, nz, vx, vz
end

local function applyCombatTether(nx, nz, ex, ez, vx, vz)
  local dx, dz = nx - ex, nz - ez
  local d = math.sqrt(dx * dx + dz * dz)
  if d <= M.MAX_ENEMY_GAP or d <= 0.001 then return nx, nz, vx, vz end
  local ux, uz = dx / d, dz / d
  -- This is intentionally much softer than the arena edge. The player can
  -- circle widely, but the presentation cannot drift so far away that the
  -- opponent and HUD stop reading as one encounter.
  local excess = math.min(1.5, (d - M.MAX_ENEMY_GAP) * 0.12)
  nx, nz = nx - ux * excess, nz - uz * excess
  local away = vx * ux + vz * uz
  if away > 0 then vx, vz = vx - ux * away * 0.75, vz - uz * away * 0.75 end
  return nx, nz, vx, vz
end

local function movePlayer(side, dt, arena, lx, ly)
  local p = side == "player2" and arena.player2 or arena.player
  local e = arena.enemy
  if not (type(p) == "table" and type(e) == "table") then return false end
  local px, pz, ex, ez = tonumber(p[1]), tonumber(p[2]), tonumber(e[1]), tonumber(e[2])
  if not (px and pz and ex and ez) then return false end

  dt = math.max(0, math.min(0.05, tonumber(dt) or 0))
  local feel = movementFeel()
  local v = velocityOf(side)
  local mag = math.sqrt(lx * lx + ly * ly)
  local wishX, wishZ, inputScale = 0, 0, 0
  if mag > M.DEADZONE then
    inputScale = clamp((mag - M.DEADZONE) / (1 - M.DEADZONE), 0, 1)
    lx, ly = lx / mag, ly / mag
    local fx, fz, rx, rz = cameraBasis(arena)
    wishX = rx * lx + fx * (-ly)
    wishZ = rz * lx + fz * (-ly)
    local wl = math.sqrt(wishX * wishX + wishZ * wishZ)
    if wl > 0.001 then wishX, wishZ = wishX / wl, wishZ / wl end
  end

  local mechanicScale = 1
  local mech = mechanics()
  if mech and type(mech.movementScale) == "function" then
    local ok, s = pcall(mech.movementScale, side)
    if ok and tonumber(s) then mechanicScale = clamp(tonumber(s), 0, 1) end
  end
  local targetSpeed = M.SPEED * feel.speed * inputScale * mechanicScale
  local targetX, targetZ = wishX * targetSpeed, wishZ * targetSpeed

  local currentSpeed = math.sqrt(v.x * v.x + v.z * v.z)
  local rate
  if inputScale <= 0.001 then
    rate = feel.decel
  elseif currentSpeed > 0.5 and (v.x * targetX + v.z * targetZ) < 0 then
    rate = feel.turn
  else
    rate = feel.accel
  end
  v.x = expApproach(v.x, targetX, rate, dt)
  v.z = expApproach(v.z, targetZ, rate, dt)
  if inputScale <= 0.001 and math.abs(v.x) < 0.03 then v.x = 0 end
  if inputScale <= 0.001 and math.abs(v.z) < 0.03 then v.z = 0 end

  local origin = state.origins[side]
  if type(origin) ~= "table" then origin = { px, pz }; state.origins[side] = origin end
  local nx, nz = px + v.x * dt, pz + v.z * dt
  nx, nz, v.x, v.z = projectArenaBoundary(nx, nz, origin[1], origin[2], v.x, v.z)
  nx, nz, v.x, v.z = separateOpponent(nx, nz, ex, ez, v.x, v.z)
  nx, nz, v.x, v.z = applyCombatTether(nx, nz, ex, ez, v.x, v.z)

  local moved = math.abs(nx - px) > 0.0001 or math.abs(nz - pz) > 0.0001
  p[1], p[2] = nx, nz
  if side == "player2" then
    arena.player2Cell = { math.floor(nx / 16), math.floor(nz / 16) }
  else
    arena.playerCell = { math.floor(nx / 16), math.floor(nz / 16) }
  end
  arena.mid = arena.mid or { 0, 0 }
  arena.mid[1], arena.mid[2] = (nx + ex) * 0.5, (nz + ez) * 0.5
  state.speedNow = math.sqrt(v.x * v.x + v.z * v.z)
  state.moved = moved
  return moved
end

local function duoControl(screen)
  local duo = V and V.DoubleBattleMode
  if not (duo and type(duo.enabled) == "function" and duo.enabled()) then return false, "player" end
  local battle = screen and screen.battle
  if not (battle and type(duo.partnerForBattle) == "function") then return false, "player" end
  local ok, partner = pcall(duo.partnerForBattle, battle)
  if not (ok and partner) then return false, "player" end
  if not screen or screen.phase ~= "moves" then return true, nil end
  return true, screen._stadiumDuoSelectingPartner and "player2" or "player"
end

function M.update(dt, screen)
  local isDuo, moveSide = duoControl(screen)
  local contextSide = moveSide or "player"
  local ctx, Stadium = controlContext(screen, contextSide)
  if not ctx then
    state.active, state.selectedSide, state.moved, state.speedNow = false, nil, false, 0
    return false
  end

  local arena = ctx.arena
  if state.lastArena ~= arena then
    state.lastArena = arena
    state.origins, state.velocity = {}, {}
  end
  state.active = (not isDuo) or moveSide ~= nil
  state.selectedSide = moveSide
  state.moved = false
  state.attackPulse = math.max(0, state.attackPulse - (tonumber(dt) or 0))

  local pad = mappedPad()
  local lx, ly = 0, 0
  if pad then lx, ly = pad.x, pad.y end
  local kx, ky = keyboardMove()
  if kx ~= 0 or ky ~= 0 then lx, ly = kx, ky end
  if (not isDuo) or moveSide then movePlayer(moveSide or "player", dt, arena, lx, ly) end

  local down = pad and buttonDown(pad.js, "x") or false
  local allowManualAttack = screen and screen.phase == "resolving"
  if allowManualAttack and down and not state.attackHeld then
    local okAttack, played = false, false
    if type(Stadium.manualAttack) == "function" then okAttack, played = pcall(Stadium.manualAttack, "player") end
    if okAttack and played then state.attackPulse = 0.35 end
  end
  state.attackHeld = down
  return true
end

function M.active() return state.active and true or false end
function M.attacking() return state.attackPulse > 0 end
function M.moved() return state.moved and true or false end
function M.speed() return state.speedNow or 0 end
function M.reset() reset() end

function M.status()
  return {
    active = M.active(), attacking = M.attacking(), moved = M.moved(),
    selectedSide = state.selectedSide, speed = M.SPEED, speedNow = M.speed(),
    radius = M.ARENA_RADIUS, feel = tostring(opt("battleMovementFeel", "modern")),
    controls = "left stick/WASD uses analog acceleration and camera-relative locomotion; combat motion temporarily commits during attacks/hits",
  }
end

return M
