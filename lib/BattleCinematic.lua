-- Stadium-style cinematic orbit camera for Gold live-overworld battles.
-- It frames both combatants in the actual encounter world, eases between
-- menu/attack framing, and yields temporarily to manual look input.
local V = ...
local FirstPerson = V.require("FirstPerson")

local BattleCinematic = {}

BattleCinematic.enabled = true
BattleCinematic.angle = nil
BattleCinematic.radius = 96
BattleCinematic.height = 48
BattleCinematic.fov = 55
BattleCinematic.manualHold = 0
BattleCinematic.manualPitch = 0
BattleCinematic.lastActive = false
BattleCinematic.t = 0
BattleCinematic.focusX = nil
BattleCinematic.focusZ = nil
BattleCinematic.activeSide = nil

local TAU = math.pi * 2
local function wrap(a)
  a = (a or 0) % TAU
  if a < 0 then a = a + TAU end
  return a
end
local function approach(a, b, k)
  return a + (b - a) * math.max(0, math.min(1, k))
end

local function approachAngle(a, b, k)
  local d = ((b - a + math.pi) % TAU) - math.pi
  return wrap(a + d * math.max(0, math.min(1, k)))
end

local function eventActiveSide(screen)
  if type(screen) ~= "table" then return nil end
  -- During a real move animation Gold exposes the attacker through hudSide.
  -- Treat `anim` as opaque unless it is a table: older/newer engine builds can
  -- legitimately use a falsey/sentinel value while changing animation phases.
  local anim = type(screen.anim) == "table" and screen.anim or nil
  if anim and anim.clearsHud
      and (anim.hudSide == "player" or anim.hudSide == "enemy") then
    return anim.hudSide
  end
  -- OverworldBattle's tiny advanceQueue observer keeps the acting side alive
  -- through the rest of the same resolving turn (damage text / HP drain).
  if screen.phase == "resolving"
      and (screen._stadiumActiveSide == "player" or screen._stadiumActiveSide == "enemy") then
    return screen._stadiumActiveSide
  end
  return nil
end

local function settingOn()
  local mod = V.mod
  if mod and mod.options and type(mod.options.get) == "function" then
    local ok, v = pcall(mod.options.get, mod.options, "battleSmartCamera")
    if ok and v ~= nil then
      return not (v == false or v == 0 or v == "0" or v == "false" or v == "off")
    end
  end
  return true
end

local function stadiumBattleFxPort()
  local port = V and V.StadiumBattleFXPort
  if type(port) == "table" then return port end
  if V and type(V.require) == "function" then
    local ok, got = pcall(V.require, "StadiumBattleFXPort")
    if ok and type(got) == "table" then return got end
  end
  return nil
end

function BattleCinematic.reset()
  BattleCinematic.angle = nil
  BattleCinematic.radius = 96
  BattleCinematic.height = 48
  BattleCinematic.fov = 55
  BattleCinematic.manualHold = 0
  BattleCinematic.manualPitch = 0
  BattleCinematic.t = 0
BattleCinematic.focusX = nil
BattleCinematic.focusZ = nil
BattleCinematic.activeSide = nil
  BattleCinematic.lastActive = false
end

function BattleCinematic.manualLook(dyaw, dpitch)
  BattleCinematic.angle = wrap((BattleCinematic.angle or FirstPerson.yaw or 0) - (tonumber(dyaw) or 0))
  BattleCinematic.manualPitch = math.max(-0.55, math.min(0.55,
    BattleCinematic.manualPitch + (tonumber(dpitch) or 0)))
  BattleCinematic.manualHold = 2.5
  return true
end

function BattleCinematic.manualActive()
  return BattleCinematic.manualHold > 0
end

-- Returns placed camera, centre x/z when a Gold live-world battle is active.
local function frameImpl(dt)
  if not settingOn() then
    BattleCinematic.lastActive = false
    return nil
  end
  local ok, OverworldBattle = pcall(V.require, "OverworldBattle")
  if not ok or not OverworldBattle or type(OverworldBattle.cameraContext) ~= "function" then
    return nil
  end
  local ctx = OverworldBattle.cameraContext()
  if not ctx or not ctx.arena then
    if BattleCinematic.lastActive then BattleCinematic.reset() end
    return nil
  end

  local arena = ctx.arena
  local p, e = arena.player, arena.enemy
  if not (type(p) == "table" and type(e) == "table") then return nil end
  local px, pz = tonumber(p[1]), tonumber(p[2])
  local ex, ez = tonumber(e[1]), tonumber(e[2])
  if not (px and pz and ex and ez) then return nil end
  -- Work only with validated numeric coordinates from this point onward.
  p, e = { px, pz }, { ex, ez }

  -- v0.3.20: follow temporary contact-lunge / hit-recoil positions instead of
  -- framing only the stable manual-control anchors.  These positions are
  -- presentation-only and never feed back into Gold's battle state.
  local modernMechanics
  do
    local okModern, got = pcall(V.require, "BattleModernMechanics")
    if okModern and type(got) == "table" then modernMechanics = got end
  end
  if modernMechanics and type(modernMechanics.actorPosition) == "function" then
    local okP, pp = pcall(modernMechanics.actorPosition, "player", arena)
    if okP and type(pp) == "table" and tonumber(pp[1]) and tonumber(pp[2]) then
      p = { tonumber(pp[1]), tonumber(pp[2]) }
    end
    local okE, ep = pcall(modernMechanics.actorPosition, "enemy", arena)
    if okE and type(ep) == "table" and tonumber(ep[1]) and tonumber(ep[2]) then
      e = { tonumber(ep[1]), tonumber(ep[2]) }
    end
  end
  px, pz, ex, ez = p[1], p[2], e[1], e[2]
  -- Keep DoubleBattleMode's selected-partner midpoint ownership when present;
  -- the active-side focus below still follows temporary combat offsets.
  local cx = arena.mid and tonumber(arena.mid[1]) or ((px + ex) * 0.5)
  local cz = arena.mid and tonumber(arena.mid[2]) or ((pz + ez) * 0.5)
  if not (cx and cz) then
    cx, cz = (px + ex) * 0.5, (pz + ez) * 0.5
  end
  local gy = tonumber(ctx.groundY) or 0
  local screen = ctx.screen
  local attack = screen and screen.anim ~= nil
  local resolving = screen and screen.phase == "resolving"
  local activeSide = eventActiveSide(screen)
  -- While the player is directly steering the Stadium actor, keep the camera
  -- in the same shoulder/follow family used for an active attack turn. The
  -- controller moves arena.player itself, so this naturally follows the model.
  local manualControl, manualAttack = false, false
  local okControl, Control = pcall(V.require, "BattlePokemonControl")
  if okControl and Control then
    local okA, a = pcall(Control.active)
    manualControl = okA and a and true or false
    local okAtk, atk = pcall(Control.attacking)
    manualAttack = okAtk and atk and true or false
  end
  if manualControl then activeSide = "player" end
  if manualAttack then attack = true end

  -- v0.3.21: translate StadiumBattleFX 2.1.7's authored move-camera profile
  -- into this Gold-safe live-world camera. The source timeline owns subject,
  -- optical width and a small orbit offset; it never writes battle state.
  local fxPort = stadiumBattleFxPort()
  local fxDirective
  if fxPort and type(fxPort.cameraDirective) == "function" then
    local okFx, got = pcall(fxPort.cameraDirective)
    if okFx and type(got) == "table" then
      fxDirective = got
      if got.attackerSide == "player" or got.attackerSide == "enemy" then
        activeSide = got.attackerSide
        attack = true
      end
    end
  end

  dt = math.max(0, math.min(0.1, tonumber(dt) or 1/60))

  -- Controller camera input is sampled INSIDE the camera that actually renders
  -- the Gold live-world battle. Earlier builds routed the right stick through
  -- CamControl.tick, but Gold's OverworldBattle intentionally skipped that
  -- tick; the values could therefore be correct without ever changing this
  -- camera. Polling SDL here removes that unreachable seam entirely.
  if type(FirstPerson.pollMappedRightStick) == "function" then
    pcall(FirstPerson.pollMappedRightStick)
  end
  local rx = type(FirstPerson.stickX) == "function" and FirstPerson.stickX() or 0
  local ry = type(FirstPerson.stickY) == "function" and FirstPerson.stickY() or 0
  rx, ry = tonumber(rx) or 0, tonumber(ry) or 0
  local rdead = 0.10
  if math.abs(rx) <= rdead then rx = 0 end
  if math.abs(ry) <= rdead then ry = 0 end
  if rx ~= 0 or ry ~= 0 then
    BattleCinematic.manualLook(rx * dt * 2.9, -ry * dt * 2.25)
  end

  BattleCinematic.t = BattleCinematic.t + dt
  if not BattleCinematic.angle then
    -- Start behind the player's side, offset enough to read both models.
    local dx, dz = e[1] - p[1], e[2] - p[2]
    BattleCinematic.angle = wrap(math.atan2(-dx, -dz) + 0.65)
  end

  if BattleCinematic.manualHold > 0 then
    BattleCinematic.manualHold = math.max(0, BattleCinematic.manualHold - dt)
  else
    if activeSide then
      -- Stadium-style shoulder shot: stay mostly behind and to the side of the
      -- Pokemon whose turn is currently playing, rather than orbiting both
      -- combatants evenly. A very small drift keeps the frame alive.
      local actor = activeSide == "player" and p or e
      local other = activeSide == "player" and e or p
      local dx, dz = other[1] - actor[1], other[2] - actor[2]
      local len = math.sqrt(dx * dx + dz * dz)
      if len < 0.001 then len = 1 end
      local ux, uz = dx / len, dz / len
      local px2, pz2 = -uz, ux
      local sideSign = activeSide == "player" and 1 or -1
      local bx = -ux + px2 * 0.48 * sideSign
      local bz = -uz + pz2 * 0.48 * sideSign
      local sourceOrbit = 0
      if fxDirective and BattleCinematic.manualHold <= 0 then
        sourceOrbit = tonumber(fxDirective.orbit) or 0
        if activeSide == "enemy" then sourceOrbit = -sourceOrbit end
      end
      local targetAngle = wrap(math.atan2(bx, bz)
        + math.sin(BattleCinematic.t * 0.72) * 0.10 + sourceOrbit)
      BattleCinematic.angle = approachAngle(BattleCinematic.angle, targetAngle, dt * 2.0)
    else
      -- Between turns/menu selection, widen back out and resume the slow orbit.
      local speed = resolving and 0.12 or 0.085
      BattleCinematic.angle = wrap(BattleCinematic.angle + speed * dt)
    end
    BattleCinematic.manualPitch = approach(BattleCinematic.manualPitch, 0, dt * 0.9)
  end

  -- Active-turn shots push closer; menu/inter-turn shots leave more breathing room.
  local wantRadius = activeSide and (attack and 69 or 76) or (resolving and 88 or 100)
  local wantHeight = activeSide and (attack and 35 or 40) or 48
  local wantFov = activeSide and (attack and 51.5 or 53.5) or (resolving and 55.0 or 57.0)

  if fxDirective and attack and BattleCinematic.manualHold <= 0 then
    -- StadiumBattleFX itself floors portable attack framing at 1.18x, with
    -- 1.30x for aerial moves, because the animated body can travel far outside
    -- its idle footprint. Preserve that safety policy in degrees here.
    local frameMin = fxDirective.profile == "aerial" and 1.30 or 1.18
    local optical = math.max(frameMin, tonumber(fxDirective.zoom) or 1)
    optical = optical * (1 + math.max(0, tonumber(fxDirective.compatibilityZoom) or 0))
    wantFov = math.max(43, math.min(72, wantFov * optical))
    local nativeElevation = tonumber(fxDirective.elevation) or 0
    if nativeElevation ~= 0 then
      -- Stadium1 native camera selectors encode distinct low/high rigs.  The
      -- combined renderer owns a different world scale, so preserve the angle
      -- family by translating it into a bounded eye-height offset rather than
      -- copying Stadium1's absolute camera coordinates.
      wantHeight = math.max(26, math.min(64, wantHeight + math.sin(nativeElevation) * 18))
    end
    if fxDirective.profile == "aerial" then
      wantHeight = math.max(wantHeight, 46)
      wantRadius = math.max(wantRadius, 76)
    elseif fxDirective.profile == "field" or fxDirective.profile == "explosion" then
      wantRadius = math.max(wantRadius, 88)
      wantHeight = math.max(wantHeight, 42)
    end
  end

  BattleCinematic.radius = approach(BattleCinematic.radius, wantRadius, dt * 2.8)
  BattleCinematic.height = approach(BattleCinematic.height, wantHeight, dt * 2.8)
  BattleCinematic.fov = approach(BattleCinematic.fov or 55, wantFov, dt * 3.4)

  -- Focus strongly favors the active Pokemon while retaining enough of the
  -- opponent's side to read the exchange. Between turns it eases to midpoint.
  local wantFx, wantFz = cx, cz
  if activeSide then
    local actor = activeSide == "player" and p or e
    local other = activeSide == "player" and e or p
    local actorWeight = attack and 0.82 or 0.74
    if fxDirective and attack and BattleCinematic.manualHold <= 0 then
      if fxDirective.subject == "attacker" then
        actorWeight = 0.91
      elseif fxDirective.subject == "target" then
        actorWeight = 0.14
      elseif fxDirective.subject == "center" or fxDirective.subject == "wide" then
        actorWeight = 0.50
      end
    end
    wantFx = actor[1] * actorWeight + other[1] * (1 - actorWeight)
    wantFz = actor[2] * actorWeight + other[2] * (1 - actorWeight)
  end
  BattleCinematic.focusX = approach(BattleCinematic.focusX or cx, wantFx, dt * 3.2)
  BattleCinematic.focusZ = approach(BattleCinematic.focusZ or cz, wantFz, dt * 3.2)
  BattleCinematic.activeSide = activeSide

  local a = BattleCinematic.angle
  local feedback = { shakeX=0, shakeY=0, zoom=0 }
  if modernMechanics and type(modernMechanics.cameraFeedback) == "function" then
    local okFeedback, got = pcall(modernMechanics.cameraFeedback)
    if okFeedback and type(got) == "table" then feedback = got end
  end
  local zoom = math.max(0, math.min(1, tonumber(feedback.zoom) or 0))
  local r = BattleCinematic.radius * (1 - zoom * 0.055)
  local fx, fz = BattleCinematic.focusX, BattleCinematic.focusZ
  local eyeY = gy + BattleCinematic.height + BattleCinematic.manualPitch * 42
  local shakeX = tonumber(feedback.shakeX) or 0
  local shakeY = tonumber(feedback.shakeY) or 0
  -- StadiumBattleFX 2.1.7 authored attack-camera timelines also carry an
  -- impact shake channel. Layer it over the v0.3.20 real-damage recoil rather
  -- than replacing it: the source pulse supplies move timing, while Gold still
  -- owns whether damage actually happened. The short deterministic window
  -- avoids per-frame randomness/jitter and never feeds back into battle state.
  if fxDirective and BattleCinematic.manualHold <= 0 then
    local authored = math.max(0, tonumber(fxDirective.shake) or 0)
    local impact = tonumber(fxDirective.impact) or -999
    local tick = tonumber(fxDirective.tick) or 0
    local dist = math.abs(tick - impact)
    if authored > 0 and dist < 9 then
      local envelope = 1 - dist / 9
      local seed = (tonumber(fxDirective.moveId) or 0) * 0.173
      local pulse = authored * envelope * 0.85
      shakeX = shakeX + math.sin(tick * 2.41 + seed) * pulse
      shakeY = shakeY + math.cos(tick * 2.07 + seed * 1.7) * pulse * 0.42
    end
  end
  local eye = {
    fx + math.sin(a) * r + math.cos(a) * shakeX,
    eyeY + shakeY,
    fz + math.cos(a) * r - math.sin(a) * shakeX,
  }
  local focus = { fx, gy + 12, fz }
  local cam = {
    eye = eye,
    focus = focus,
    up = { 0, 1, 0 },
    fov = math.rad((BattleCinematic.fov or 55) - zoom * 2.2),
    curve = 0,
    _stadiumBattleCinematic = true,
  }
  BattleCinematic.lastActive = true
  return cam, cx, cz
end

-- A presentation camera must never be able to take the game down. Gen1Recomp
-- battle internals are intentionally allowed to evolve, so keep the entire
-- optional cinematic behind one pcall. If a future/older BattleState exposes
-- a shape we did not expect, the live-world battle simply uses the ordinary
-- overworld camera for that frame and gameplay continues.
function BattleCinematic.frame(dt)
  local ok, cam, cx, cz = pcall(frameImpl, dt)
  if ok then return cam, cx, cz end

  if not BattleCinematic._errorLogged then
    BattleCinematic._errorLogged = true
    pcall(function()
      if V.mod and V.mod.log and type(V.mod.log.warn) == "function" then
        V.mod.log:warn("Stadium battle camera disabled after recoverable error: %s",
                       tostring(cam))
      end
    end)
  end
  BattleCinematic.reset()
  return nil
end

return BattleCinematic
