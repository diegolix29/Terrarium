-- Modern live-battle presentation mechanics for Gold's Stadium/voxel battles.
--
-- Gold remains authoritative for turns, move legality, damage, HP, PP, status,
-- switching, items, catches and battle completion.  This module only turns
-- those existing battle events into a more physical 3D presentation:
--   * contact attacks visibly close distance and return to the battle anchor;
--   * damage produces distance-aware defender knockback and camera impact;
--   * the cinematic camera can follow those temporary presentation offsets;
--   * direct-control locomotion can briefly commit during an attack/hit rather
--     than skating straight through a skeletal performance.
--
-- All offsets are render-time only.  arena.player / arena.enemy remain the
-- stable manual-control anchors, so none of this can alter Gold's battle logic.
local V = ...
local M = {}

local clamp = function(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function opt(key, default)
  local options = V and V.mod and V.mod.options
  if not (options and type(options.get) == "function") then return default end
  local ok, value = pcall(options.get, options, key)
  if not ok or value == nil then return default end
  return value
end

local function enabled()
  local v = opt("battleModernMotion", true)
  return not (v == false or v == 0 or v == "0" or v == "false" or v == "off")
end

local function stadiumFxPort()
  if V and type(V.StadiumBattleFXPort) == "table" then return V.StadiumBattleFXPort end
  if V and type(V.require) == "function" then
    local ok, value = pcall(V.require, "StadiumBattleFXPort")
    if ok and type(value) == "table" then V.StadiumBattleFXPort=value; return value end
  end
end

local function feedbackScale()
  local v = tostring(opt("battleImpactFeedback", "normal")):lower()
  if v == "low" then return 0.58 end
  if v == "high" then return 1.35 end
  return 1.0
end

local function normalizeName(raw)
  return tostring(raw or ""):upper():gsub("[^A-Z0-9]", "")
end

local CONTACT_EXACT = {
  TACKLE=true, SCRATCH=true, POUND=true, CUT=true, BITE=true, PECK=true,
  WINGATTACK=true, SLAM=true, VINEWHIP=true, BODYSLAM=true, TAKE_DOWN=true,
  TAKEDOWN=true, DOUBLEEDGE=true, QUICKATTACK=true, RAGE=true, FURYSWIPES=true,
  SLASH=true, HYPERFANG=true, SUPERFANG=true, LOWKICK=true, KARATECHOP=true,
  SEISMICTOSS=true, STRENGTH=true, DIG=true, FLY=true, CRABHAMMER=true,
  STOMP=true, HEADBUTT=true, HORNATTACK=true, FURYATTACK=true, THRASH=true,
  CONSTRICT=true, WRAP=true, BIND=true, LEECHLIFE=true, FURYCUTTER=true,
  FALSESWIPE=true, MACH_PUNCH=true, MACHPUNCH=true, DYNAMICPUNCH=true,
  CROSSCHOP=true, MEGAHORN=true, IRONTAIL=true, STEELWING=true, ROLLOUT=true,
  REVERSAL=true, PURSUIT=true, EXTREMESPEED=true, CRUNCH=true, RAPIDSPIN=true,
  ROCKSMASH=true, VICEGRIP=true, GUILLOTINE=true, RAZORWIND=false,
}

local CONTACT_WORDS = {
  "PUNCH", "KICK", "CLAW", "CHOP", "HEADBUTT", "TACKLE", "SLASH",
  "BITE", "FANG", "HORN", "STOMP", "SLAM", "TAIL", "WINGATTACK",
}

local RANGED_WORDS = {
  "BEAM", "BOLT", "THUNDER", "WAVE", "WIND", "BLAST", "BUBBLE", "GUN",
  "SPRAY", "POWDER", "SPORE", "DANCE", "SONG", "SCREECH", "GROWL",
  "LIGHT", "SCREEN", "REFLECT", "METRONOME", "PSY", "SURF", "EARTHQUAKE",
  "ROCKTHROW", "ROCKSLIDE", "SPIKE", "BOMB", "BALL", "CANNON", "STORM",
  "SNOW", "BLIZZARD", "FIRESPIN", "WHIRLPOOL", "MUD", "SAND", "RAIN",
  "RECOVER", "REST", "HEAL", "SYNTHESIS", "SUNNY", "CURSE", "TOXIC",
}

local PHYSICAL_TYPES = {
  NORMAL=true, FIGHTING=true, FLYING=true, POISON=true, GROUND=true,
  ROCK=true, BUG=true, GHOST=true, STEEL=true,
}

local resetForScreen

local state = {
  screen = nil,
  move = nil,
  hit = { player=nil, enemy=nil, player2=nil },
  lastHP = { player=nil, enemy=nil },
  clock = 0,
  shakeT = 0,
  shakeDuration = 0,
  shakeStrength = 0,
  zoomKick = 0,
  installed = false,
  moveToken = 0,
}

local function moveDef(screen, moveId)
  local battle = screen and screen.battle
  if battle and type(battle.moveDef) == "function" then
    local ok, def = pcall(battle.moveDef, battle, moveId)
    if ok and type(def) == "table" then return def end
  end
  local data = (screen and screen.game and screen.game.data)
    or (battle and battle.data) or {}
  local moves = data and data.moves
  if type(moves) ~= "table" then return nil end
  if type(moves[moveId]) == "table" then return moves[moveId] end
  local want = tonumber(moveId)
  for _, def in pairs(moves) do
    if type(def) == "table" then
      local index = tonumber(def.index or def.moveIndex or def.number or def.id)
      if want and index == want then return def end
      if type(moveId) == "string" then
        local id = normalizeName(def.id or def.name)
        if id ~= "" and id == normalizeName(moveId) then return def end
      end
    end
  end
  return nil
end

local function moveType(def)
  local t = def and (def.type or def.moveType)
  if type(t) == "table" then t = t.id or t.name end
  return normalizeName(t)
end

local function movePower(def)
  return math.max(0, tonumber(def and def.power) or 0)
end

local function contactMove(def, moveId)
  local power = movePower(def)
  if power <= 0 then return false end
  local name = normalizeName((def and (def.id or def.name)) or moveId)
  if CONTACT_EXACT[name] ~= nil then return CONTACT_EXACT[name] == true end
  for _, word in ipairs(RANGED_WORDS) do
    if name:find(word, 1, true) then return false end
  end
  for _, word in ipairs(CONTACT_WORDS) do
    if name:find(word, 1, true) then return true end
  end
  return PHYSICAL_TYPES[moveType(def)] == true
end

local function hpOf(battler)
  if not battler then return nil, nil end
  local mon = type(battler.mon) == "table" and battler.mon or battler
  local hp = tonumber(mon and mon.hp) or tonumber(battler.hp)
  local max = tonumber(mon and (mon.maxHp or mon.maxHP or mon.hpMax))
    or tonumber(battler.maxHp or battler.maxHP or battler.hpMax)
  if hp == nil then return nil, max end
  if not max or max <= 0 then max = math.max(1, hp) end
  return hp, max
end

local function easeInOut(t)
  t = clamp(t, 0, 1)
  return t * t * (3 - 2 * t)
end

local function attackEnvelope(t)
  -- Fast commitment, tiny contact hold, then a controlled return.
  if t < 0.34 then return easeInOut(t / 0.34) end
  if t < 0.54 then return 1 end
  return 1 - easeInOut((t - 0.54) / 0.46)
end

local function hitEnvelope(t)
  t = clamp(t, 0, 1)
  return math.sin(t * math.pi) * (1 - 0.20 * t)
end

local function sideAnchor(arena, side)
  if not arena then return nil end
  if side == "player2" then return arena.player2 end
  return arena[side]
end

local function otherSide(side)
  if side == "enemy" then return "player" end
  return "enemy"
end

local function vectorBetween(arena, side, other)
  local a, b = sideAnchor(arena, side), sideAnchor(arena, other)
  if not (type(a) == "table" and type(b) == "table") then return 0, 0, 0 end
  local ax, az = tonumber(a[1]), tonumber(a[2])
  local bx, bz = tonumber(b[1]), tonumber(b[2])
  if not (ax and az and bx and bz) then return 0, 0, 0 end
  local dx, dz = bx - ax, bz - az
  local len = math.sqrt(dx * dx + dz * dz)
  if len <= 0.001 then return 0, 0, 0 end
  return dx / len, dz / len, len
end

function M.onMove(screen, moveId, side)
  if not enabled() or not screen or (side ~= "player" and side ~= "enemy") then return false end
  if state.screen ~= screen then resetForScreen(screen) end
  local def = moveDef(screen, moveId)
  local power = movePower(def)
  local contact = contactMove(def, moveId)
  local Port = stadiumFxPort()
  local spec = Port and Port.moveSpec and Port.moveSpec(moveId, def) or nil
  if spec then
    -- StadiumBattleFX's source roster explicitly tags contact/projectile/beam/
    -- screen/status delivery.  Prefer that authored answer over the heuristic
    -- name/type table for Gen-1 moves.
    if spec.delivery == "contact" then contact = true
    elseif spec.delivery == "projectile" or spec.delivery == "beam"
        or spec.delivery == "screen" or spec.delivery == "status" then contact = false end
  end
  local duration = contact and (power >= 100 and 0.76 or 0.64) or 0.50
  if Port and Port.timing and spec then
    local okTiming, frames = pcall(Port.timing, spec, duration * 60)
    if okTiming and tonumber(frames) then duration = math.max(.18, tonumber(frames) / 60) end
  end
  local modelSide = (side == "player" and screen._stadiumDuoPartnerEvent)
    and "player2" or side
  state.moveToken = state.moveToken + 1
  state.move = {
    token = state.moveToken,
    side = side,
    modelSide = modelSide,
    moveId = moveId,
    def = def,
    spec = spec,
    power = power,
    contact = contact,
    t = 0,
    duration = duration,
  }
  -- A tiny pre-impact push-in makes even ranged/status actions feel authored;
  -- actual shake waits for damage so misses/status moves never fake a hit.
  state.zoomKick = math.max(state.zoomKick, power > 0 and 0.18 or 0.08)
  return true
end

local function triggerHit(side, lost, maxHp)
  if not enabled() or lost <= 0 then return end
  local Port = stadiumFxPort()
  if Port and Port.hitReactionsEnabled and not Port.hitReactionsEnabled() then return end
  local frac = clamp(lost / math.max(1, maxHp or lost), 0, 1)
  local scale = feedbackScale()
  local strength = clamp((0.65 + frac * 5.2) * scale, 0.45, 4.8)
  state.hit[side] = {
    t = 0,
    duration = clamp(0.22 + frac * 0.38, 0.22, 0.48),
    distance = clamp((2.1 + frac * 10.0) * scale, 1.2, 8.8),
  }
  state.shakeT = 0
  state.shakeDuration = clamp(0.14 + frac * 0.24, 0.14, 0.34)
  state.shakeStrength = strength
  state.zoomKick = math.max(state.zoomKick, clamp((0.16 + frac * 0.62) * scale, 0.1, 0.72))
end

resetForScreen = function(screen)
  state.screen = screen
  state.move = nil
  state.hit.player, state.hit.enemy, state.hit.player2 = nil, nil, nil
  state.lastHP.player, state.lastHP.enemy = nil, nil
  state.shakeT, state.shakeDuration, state.shakeStrength = 0, 0, 0
  state.zoomKick = 0
end

function M.update(dt, screen)
  dt = clamp(tonumber(dt) or 0, 0, 0.10)
  if not screen then
    if state.screen ~= nil then resetForScreen(nil) end
    return false
  end
  if state.screen ~= screen then resetForScreen(screen) end
  state.clock = state.clock + dt

  if state.move then
    state.move.t = state.move.t + dt
    if state.move.t >= state.move.duration then state.move = nil end
  end
  for side, hit in pairs(state.hit) do
    if hit then
      hit.t = hit.t + dt
      if hit.t >= hit.duration then state.hit[side] = nil end
    end
  end

  if state.shakeDuration > 0 then
    state.shakeT = state.shakeT + dt
    if state.shakeT >= state.shakeDuration then
      state.shakeT, state.shakeDuration, state.shakeStrength = 0, 0, 0
    end
  end
  state.zoomKick = math.max(0, state.zoomKick - dt * 1.45)

  local battle = screen.battle
  if battle then
    for _, side in ipairs({ "player", "enemy" }) do
      local hp, maxHp = hpOf(battle[side])
      local prev = state.lastHP[side]
      if prev ~= nil and hp ~= nil and hp < prev then
        triggerHit(side, prev - hp, maxHp)
      end
      if hp ~= nil then state.lastHP[side] = hp end
    end
  end
  return enabled()
end

function M.actorOffset(side, arena)
  if not enabled() or not arena then return 0, 0 end
  local ox, oz = 0, 0

  local move = state.move
  if move and move.contact and move.modelSide == side then
    local other = otherSide(side)
    local ux, uz, dist = vectorBetween(arena, side, other)
    if dist > 0 then
      local p = attackEnvelope(move.t / move.duration)
      -- Never close the centres completely; the Stadium models vary wildly in
      -- size and the manual-control gap still has to remain visually legible.
      local maxClose = math.max(0, dist - 12)
      local want = clamp(6.0 + move.power * 0.075, 6.0, 15.0)
      local amount = math.min(maxClose * 0.56, want) * p
      ox, oz = ox + ux * amount, oz + uz * amount
    end
  end

  local hit = state.hit[side]
  if hit then
    local attacker = otherSide(side)
    local ux, uz = vectorBetween(arena, attacker, side)
    local p = hitEnvelope(hit.t / hit.duration)
    ox, oz = ox + ux * hit.distance * p, oz + uz * hit.distance * p
  end
  return ox, oz
end

function M.actorPosition(side, arena)
  local a = sideAnchor(arena, side)
  if type(a) ~= "table" then return nil end
  local x, z = tonumber(a[1]), tonumber(a[2])
  if not (x and z) then return nil end
  local ox, oz = M.actorOffset(side, arena)
  return { x + ox, z + oz }
end

function M.movementScale(side)
  if not enabled() then return 1 end
  local move = state.move
  if move and move.modelSide == side and move.contact then
    -- Commit to a contact attack instead of skating sideways through it.
    return 0.12
  end
  local hit = state.hit[side]
  if hit then return 0.42 end
  return 1
end

function M.cameraFeedback()
  if not enabled() then return { shakeX=0, shakeY=0, zoom=0 } end
  local Port = stadiumFxPort()
  if Port and Port.attackCameraEnabled and not Port.attackCameraEnabled() then
    return { shakeX=0, shakeY=0, zoom=0 }
  end
  local shakeX, shakeY = 0, 0
  if state.shakeDuration > 0 then
    local q = clamp(state.shakeT / state.shakeDuration, 0, 1)
    local env = (1 - q) * (1 - q)
    local s = state.shakeStrength * env
    -- Deterministic frequencies avoid touching the game's RNG stream.
    shakeX = math.sin(state.clock * 91.0) * s
    shakeY = math.sin(state.clock * 73.0 + 1.7) * s * 0.56
  end
  return { shakeX=shakeX, shakeY=shakeY, zoom=state.zoomKick }
end

function M.activeMove()
  return state.move
end

function M.reset()
  resetForScreen(nil)
end

function M.install()
  if state.installed then return true end
  local ok, BattleState = pcall(require, "src.ui.gen2.BattleState")
  if not (ok and type(BattleState) == "table" and type(BattleState.animForMove) == "function") then
    return false, "Gold BattleState.animForMove unavailable"
  end
  if not BattleState._stadiumModernMechanicsMove then
    local inner = BattleState.animForMove
    BattleState.animForMove = function(self, moveId, side, ...)
      local out = { inner(self, moveId, side, ...) }
      pcall(M.onMove, self, moveId, side)
      return (table.unpack or unpack)(out)
    end
    BattleState._stadiumModernMechanicsMove = true
  end
  state.installed = true
  return true
end

function M.status()
  local move = state.move
  return {
    enabled = enabled(),
    move = move and tostring(move.moveId) or nil,
    moveSide = move and move.modelSide or nil,
    contact = move and move.contact or false,
    impact = feedbackScale(),
  }
end

return M
