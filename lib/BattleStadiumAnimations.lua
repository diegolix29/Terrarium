-- Pokemon Stadium Overworld Models - Stage 1 battle performances
--
-- This module augments Dramatic Shape's Stadium battle actors without
-- replacing BattleState or the battle renderer.  It is intentionally a
-- compatibility layer: newer Dramatic Shape builds already know how to ask a
-- Stadium model for its per-move animation, while older builds only stand the
-- model on the field.  We let the installed build run first, inspect the live
-- Stadium session, and only supply whatever request it did not already make.
--
-- Stage 1 covers:
--   * exact per-species/per-move Stadium attack animation when the pack has it
--   * generic Stadium attack fallback when a move has no table entry
--   * send-out / entrance performance
--   * faint / collapse performance, delayed until the HP bar reaches zero
--   * a short whole-body recoil when damage lands (the Stadium model set has
--     no true universal hit/flinch skeletal animation; see StadiumMon.lua)
--
-- No Nintendo assets are bundled.  Everything is read from the user's
-- already-imported Dramatic Shape Stadium packs.
local V = ...
local M = {}

local function animationsEnabled()
  local opts = V and V.mod and V.mod.options
  if not (opts and type(opts.get) == "function") then return true end
  local ok, value = pcall(opts.get, opts, "stadiumBattleAnimations")
  if not ok or value == nil then return true end
  return not (value == false or value == 0 or value == "0" or value == "false" or value == "off")
end

local function stadiumFxPort()
  if V and type(V.StadiumBattleFXPort) == "table" then return V.StadiumBattleFXPort end
  if V and type(V.require) == "function" then
    local ok, value = pcall(V.require, "StadiumBattleFXPort")
    if ok and type(value) == "table" then V.StadiumBattleFXPort=value; return value end
  end
end

local function hitReactionsEnabled()
  local Port=stadiumFxPort()
  return not (Port and Port.hitReactionsEnabled and not Port.hitReactionsEnabled())
end

local function faintAnimationsEnabled()
  local Port=stadiumFxPort()
  return not (Port and Port.faintAnimationsEnabled and not Port.faintAnimationsEnabled())
end

local function safeLog(level, fmt, ...)
  local log = V and V.mod and V.mod.log
  local fn = log and log[level]
  if type(fn) == "function" then pcall(fn, log, fmt, ...) end
end

local function findUpvalue(fn, wanted)
  if type(fn) ~= "function" or not (debug and debug.getupvalue) then return nil end
  for i = 1, 80 do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then
      return function()
        local _, now = debug.getupvalue(fn, i)
        return now
      end
    end
  end
  return nil
end

local function installSessionGetter(Stadium)
  -- Stadium.update is the best candidate on current Dramatic Shape.  Fall back
  -- to any public function known to close over the same local session.
  for _, fn in ipairs({ Stadium.update, Stadium.animOf, Stadium.showing,
                        Stadium.draw, Stadium.cast, Stadium.active }) do
    local getter = findUpvalue(fn, "session")
    if getter then return getter end
  end
  return nil
end

local function sideOf(battle, battler)
  if not (battle and battler) then return nil end
  if battler == battle.player then return "player" end
  if battler == battle.enemy then return "enemy" end
  return nil
end

local function moveIndex(battle, moveInst)
  if not battle then return nil end
  if type(battle.moveDef) == "function" then
    local ok, def = pcall(battle.moveDef, battle, moveInst)
    if ok and type(def) == "table" then
      local n = tonumber(def.index)
      if n and n >= 1 then return n end
    end
  end
  if type(moveInst) == "table" then
    local n = tonumber(moveInst.index or moveInst.id)
    if n and n >= 1 then return n end
  end
  return nil
end

local function resolveMoveIndex(moveId, def)
  local index = tonumber(moveId)
  if index and index >= 1 then return index end
  if type(def) == "table" then
    index = tonumber(def.index or def.moveIndex or def.number)
    if not index then index = tonumber(def.id) end
    if index and index >= 1 then return index end
  end
  return nil
end

local function goldMoveDef(screen, moveId)
  local battle = screen and screen.battle
  if battle and type(battle.moveDef) == "function" then
    local okDef, def = pcall(battle.moveDef, battle, moveId)
    if okDef and type(def) == "table" then return def end
  end
  local data = (screen and screen.game and screen.game.data)
    or (battle and battle.data) or {}
  local moves = data and data.moves
  if type(moves) == "table" then
    local direct = moves[moveId]
    if type(direct) == "table" then return direct end
    local want = tonumber(moveId)
    for _, def in pairs(moves) do
      if type(def) == "table" then
        local index = tonumber(def.index or def.moveIndex or def.number)
        if want and index == want then return def end
        if type(moveId) == "string" then
          local id = tostring(def.id or def.name or "")
          if id == moveId then return def end
        end
      end
    end
  end
  return nil
end

local function requestAttack(mon, index)
  if not (mon and mon.rig) then return false end
  if mon.state == "faint" then return false end
  if index and type(mon.attack) == "function" then
    local ok, played = pcall(mon.attack, mon, index)
    if ok and played then return true end
  end
  if type(mon.request) == "function" then
    local ok, played = pcall(mon.request, mon, "attack")
    return ok and played and true or false
  end
  if type(mon.play) == "function" then
    local ok, played = pcall(mon.play, mon, "attack")
    return ok and played and true or false
  end
  return false
end

local function requestState(mon, state)
  if not (mon and mon.rig) then return false end
  if type(mon.request) == "function" then
    local ok, played = pcall(mon.request, mon, state)
    return ok and played and true or false
  end
  if type(mon.play) == "function" then
    local ok, played = pcall(mon.play, mon, state)
    return ok and played and true or false
  end
  return false
end

local function battlerHP(battler)
  if not battler then return nil end
  local mon = battler.mon
  local hp = type(mon) == "table" and tonumber(mon.hp) or nil
  if hp == nil then hp = tonumber(battler.hp) end
  return hp
end

local function barAtZero(battler)
  if not battler then return true end
  if battler.shownHP == nil then return true end
  return tonumber(battler.shownHP) and tonumber(battler.shownHP) <= 0 or false
end

local function battlerIsFainted(battler)
  if not battler then return false end
  if battler.fainted then return true end
  local hp = battlerHP(battler)
  return hp ~= nil and hp <= 0
end

function M.install()
  local okS, Stadium = pcall(V.require, "Stadium")
  local okM, StadiumMon = pcall(V.require, "StadiumMon")
  if not (okS and type(Stadium) == "table" and okM and type(StadiumMon) == "table") then
    return false, "Dramatic Shape Stadium modules unavailable"
  end
  if Stadium._stadiumOverworldStage1Installed then return true end

  local getSession = installSessionGetter(Stadium)
  if not getSession then
    return false, "could not access live Dramatic Shape Stadium session"
  end

  local pendingFaint = setmetatable({}, { __mode = "k" })
  local lastHP = setmetatable({}, { __mode = "k" })
  local goldLastHP = setmetatable({}, { __mode = "k" })

  -- Whole-body damage recoil. Stadium's extracted model set does not expose a
  -- universal victim/flinch clip, so this remains a small transform reaction
  -- layered on top of the real skeletal pose rather than pretending an attack
  -- clip is a damage animation.
  if type(StadiumMon.matrix) == "function" and not StadiumMon._stage1RecoilMatrix then
    local innerMatrix = StadiumMon.matrix
    StadiumMon.matrix = function(self, x, groundY, z, faceX, faceZ, ...)
      local recoil = hitReactionsEnabled() and (tonumber(self._stage1Recoil) or 0) or 0
      if recoil > 0 and faceX and faceZ then
        local len = math.sqrt(faceX * faceX + faceZ * faceZ)
        if len > 0.0001 then
          local push = math.sin(math.min(1, recoil) * math.pi) * 1.20
          x = x - (faceX / len) * push
          z = z - (faceZ / len) * push
        end
      end
      return innerMatrix(self, x, groundY, z, faceX, faceZ, ...)
    end
    StadiumMon._stage1RecoilMatrix = true
  end

  --------------------------------------------------------------------------
  -- GOLD / GEN 2
  --------------------------------------------------------------------------
  -- Gold does not call the legacy src.battle.BattleState.performMove seam.
  -- Its real presentation seam is src.ui.gen2.BattleState:animForMove(), the
  -- same call that starts the cart-authentic AnimRunner.  Drive the Stadium
  -- actor from that exact event so wild AND trainer battles animate.
  local goldMoveToken = 0
  local okGold, GoldBattleState = pcall(require, "src.ui.gen2.BattleState")
  if okGold and type(GoldBattleState) == "table"
      and type(GoldBattleState.animForMove) == "function"
      and not GoldBattleState._stadiumStage1GoldMove then
    local innerGoldMove = GoldBattleState.animForMove
    GoldBattleState.animForMove = function(self, moveId, side, ...)
      local started = innerGoldMove(self, moveId, side, ...)
      if animationsEnabled() and moveId ~= nil and (side == "player" or side == "enemy") then
        local def = goldMoveDef(self, moveId)
        local moveIndex = resolveMoveIndex(moveId, def)

        goldMoveToken = goldMoveToken + 1
        self._stadiumSkeletalMove = moveId
        self._stadiumSkeletalIndex = moveIndex
        self._stadiumSkeletalDef = def
        local modelSide = (side == "player" and self._stadiumDuoPartnerEvent)
          and "player2" or side
        self._stadiumSkeletalSide = side
        self._stadiumSkeletalModelSide = modelSide
        self._stadiumSkeletalToken = goldMoveToken
        self._stadiumSkeletalAppliedToken = nil

        local session = getSession()
        local mon = session and session[modelSide] or nil
        if mon and mon.rig and mon.state ~= "faint" then
          local played = false
          if moveIndex and type(mon.attackGen2) == "function" then
            local okPlay, out = pcall(mon.attackGen2, mon, moveIndex, def)
            played = okPlay and out and true or false
          end
          -- The exact move index is preferred, but a modded/unknown move still
          -- gets a real skeletal attack instead of silently doing nothing.
          if not played then played = requestAttack(mon, moveIndex) end
          if played then self._stadiumSkeletalAppliedToken = goldMoveToken end
        end
      end
      return started
    end
    GoldBattleState._stadiumStage1GoldMove = true
  end

  -- Gold applies battle HP to its active Mon directly. Watch that value on the
  -- same update that skins the models so a successful hit produces a visible
  -- target recoil in both wild and trainer fights. The pending move is keyed by
  -- our own token rather than by AnimRunner identity: Gold can replace the
  -- native runner before the 3D world update without cancelling the Stadium
  -- performance.
  if type(Stadium.updateGen2) == "function" and not Stadium._stage1GoldUpdateWrapped then
    local innerUpdateGen2 = Stadium.updateGen2
    Stadium.updateGen2 = function(dt, screen, groundY, ...)
      local out = { innerUpdateGen2(dt, screen, groundY, ...) }
      local session = getSession()
      local battle = screen and screen.battle
      if session and battle and animationsEnabled() then
        local token = screen._stadiumSkeletalToken
        local moveSide = screen._stadiumSkeletalSide
        local modelSide = screen._stadiumSkeletalModelSide or moveSide
        if token ~= nil and (moveSide == "player" or moveSide == "enemy")
            and screen._stadiumSkeletalAppliedToken ~= token then
          local mon = session[modelSide]
          if mon and mon.rig and mon.state ~= "faint" then
            local moveIndex = tonumber(screen._stadiumSkeletalIndex)
            local def = screen._stadiumSkeletalDef
              or goldMoveDef(screen, screen._stadiumSkeletalMove)
            if not moveIndex then
              moveIndex = resolveMoveIndex(screen._stadiumSkeletalMove, def)
              screen._stadiumSkeletalIndex = moveIndex
            end
            local played = false
            if moveIndex and type(mon.attackGen2) == "function" then
              local okPlay, outPlay = pcall(mon.attackGen2, mon, moveIndex, def)
              played = okPlay and outPlay and true or false
            end
            if not played then played = requestAttack(mon, moveIndex) end
            if played then screen._stadiumSkeletalAppliedToken = token end
          end
        end

        for _, side in ipairs({ "player", "enemy" }) do
          local battler = battle[side]
          local mon = session[side]
          local hp = battler and tonumber(battler.hp) or nil
          local prev = battler and goldLastHP[battler] or nil
          if hp ~= nil then
            if prev ~= nil and hp < prev and hp > 0 and mon and mon.rig and hitReactionsEnabled() then
              mon._stage1Recoil = 1
            end
            goldLastHP[battler] = hp
          end
          if mon and mon._stage1Recoil then
            local t = tonumber(mon._stage1Recoil) or 0
            t = t - (tonumber(dt) or 0) / 0.18
            if t <= 0 then t = nil end
            mon._stage1Recoil = t
          end
        end
      end
      return table.unpack(out)
    end
    Stadium._stage1GoldUpdateWrapped = true
  end

  --------------------------------------------------------------------------
  -- LEGACY / GEN 1 COMPATIBILITY
  --------------------------------------------------------------------------
  -- Newer Dramatic Shape builds already install the legacy Gen-1 Stadium state
  -- machine. Do not double-wrap it, but importantly DO NOT return early: that
  -- old early return was also skipping all of the Gold hooks above.
  local okB, BattleState = pcall(require, "src.battle.BattleState")
  if okB and type(BattleState) == "table" and not BattleState.dramaticShapeStadiumHook then
    if type(BattleState.performMove) == "function" and not BattleState._stadiumStage1Move then
      local innerMove = BattleState.performMove
      BattleState.performMove = function(self, user, target, moveInst, isCalled)
        local out = { innerMove(self, user, target, moveInst, isCalled) }
        if not animationsEnabled() then return table.unpack(out) end
        local session = getSession()
        local side = sideOf(self, user)
        local mon = session and side and session[side]
        if mon and mon.rig and mon.state ~= "attack" and mon.state ~= "faint" then
          requestAttack(mon, moveIndex(self, moveInst))
        end
        return table.unpack(out)
      end
      BattleState._stadiumStage1Move = true
    end

    if type(BattleState.onFaint) == "function" and not BattleState._stadiumStage1Faint then
      local innerFaint = BattleState.onFaint
      BattleState.onFaint = function(self, battler, ...)
        local session = getSession()
        local side = sideOf(self, battler)
        if session and side then
          pendingFaint[self] = pendingFaint[self] or {}
          pendingFaint[self][side] = true
        end
        return innerFaint(self, battler, ...)
      end
      BattleState._stadiumStage1Faint = true
    end

    if type(Stadium.update) == "function" and not Stadium._stage1UpdateWrapped then
      local innerUpdate = Stadium.update
      Stadium.update = function(dt, battle, groundY, ...)
        local out = { innerUpdate(dt, battle, groundY, ...) }
        local session = getSession()
        if session and battle then
          for _, side in ipairs({ "player", "enemy" }) do
            local battler = side == "player" and battle.player or battle.enemy
            local mon = session[side]
            local hp = battlerHP(battler)
            local prev = lastHP[battler]
            if hp ~= nil then
              if prev ~= nil and hp < prev and hp > 0 and mon and mon.rig then
                mon._stage1Recoil = 1
              end
              lastHP[battler] = hp
            end
            if mon and mon._stage1Recoil then
              local t = tonumber(mon._stage1Recoil) or 0
              t = t - (tonumber(dt) or 0) / 0.18
              if t <= 0 then t = nil end
              mon._stage1Recoil = t
            end
            local due = pendingFaint[battle] and pendingFaint[battle][side]
            if due then
              if not battlerIsFainted(battler) then
                pendingFaint[battle][side] = nil
              elseif barAtZero(battler) then
                pendingFaint[battle][side] = nil
                if faintAnimationsEnabled() and mon and mon.rig and mon.state ~= "faint" then requestState(mon, "faint") end
              end
            end
          end
        end
        return table.unpack(out)
      end
      Stadium._stage1UpdateWrapped = true
    end
  elseif okB and type(BattleState) == "table" and BattleState.dramaticShapeStadiumHook then
    Stadium._stadiumOverworldStage1Native = true
  end

  Stadium._stadiumOverworldStage1Installed = true
  safeLog("info", "Pokemon Stadium Stage 1: Gold move events now drive imported skeletal attack clips")
  return true
end

return M
