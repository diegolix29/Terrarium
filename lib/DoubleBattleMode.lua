-- Stadium custom double-battle extension for Gold.
--
-- Gold's native battle core is single-active-per-side. This module layers a
-- player-side duo on top without replacing the engine: the lead executes the
-- native round, then the second healthy non-EGG party member executes the move
-- the player selected for it. Both moves are selected through Gold's existing
-- move menu. The native battle remains authoritative for HP, PP, status,
-- fainting, EXP, catches, switches and battle end.
local V = ...
local mod = V and V.mod

local M = {
  installed = false,
  lastError = nil,
  duoTurns = 0,
  partnerMoves = 0,
}

local NO_PP = "There's no PP left for this move!"
local DISABLED = "The move is DISABLED!"

local function optionEnabled()
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return false end
  local ok, value = pcall(options.get, options, "doubleBattleMode")
  return ok and value == true
end

M.enabled = optionEnabled

local function healthy(mon)
  return type(mon) == "table" and not mon.isEgg and (tonumber(mon.hp) or 0) > 0
end

function M.partnerIndexForBattle(battle)
  if not (optionEnabled() and type(battle) == "table") then return nil end
  local party = battle.party or {}
  local active = tonumber(battle.playerIndex)
  -- Party order is authoritative: the first healthy slot other than the
  -- current native lead is the partner. At battle start this is slot #2 when
  -- slots #1 and #2 are healthy, exactly matching the user-facing option.
  for i, mon in ipairs(party) do
    if i ~= active and healthy(mon) then return i end
  end
  return nil
end

function M.partnerForBattle(battle)
  local index = M.partnerIndexForBattle(battle)
  return index and battle.party and battle.party[index] or nil, index
end

local function moveSlotById(mon, id)
  for i, move in ipairs((mon and mon.moves) or {}) do
    if move and move.id == id then return i end
  end
  return 1
end

local function usableMoveId(battle, mon, preferredId)
  if not (battle and mon) then return nil end
  if type(battle.forcedMove) == "function" then
    local ok, forced = pcall(battle.forcedMove, battle, mon)
    if ok and forced then return forced end
  end
  if preferredId then
    for _, move in ipairs(mon.moves or {}) do
      if move and move.id == preferredId and (tonumber(move.pp) or 0) > 0 then
        local disabled = type(battle.moveDisabled) == "function"
          and battle:moveDisabled(mon, move.id)
        if not disabled then return move.id end
      end
    end
  end
  for _, move in ipairs(mon.moves or {}) do
    if move and (tonumber(move.pp) or 0) > 0 then
      local disabled = type(battle.moveDisabled) == "function"
        and battle:moveDisabled(mon, move.id)
      if not disabled then return move.id end
    end
  end
  local Battle = require("src.battle.gen2.Battle")
  return Battle and Battle.STRUGGLE or "STRUGGLE"
end

local function hasChooseSwitch(events)
  for _, ev in ipairs(events or {}) do
    if type(ev) == "table" and ev.kind == "choose-switch" then return true end
  end
  return false
end

-- Temporarily make the partner the engine's "player" battler so every existing
-- move/status/effect helper correctly identifies it as the player side. The
-- native lead is restored before the screen sees the generated events.
local function partnerAttack(battle, partnerIndex, moveId)
  local party = battle and battle.party or nil
  local partner = party and party[partnerIndex] or nil
  if not healthy(partner) or not battle.enemy or (battle.enemy.hp or 0) <= 0 then
    return {}
  end

  local lead, leadIndex = battle.player, battle.playerIndex
  local leadStages = battle.stages and battle.stages.player
  battle._stadiumDuoStages = battle._stadiumDuoStages or {}
  local partnerStages = battle._stadiumDuoStages[partnerIndex]
  if not partnerStages then
    local Battle = require("src.battle.gen2.Battle")
    partnerStages = (Battle and Battle.newStages and Battle.newStages()) or {}
    battle._stadiumDuoStages[partnerIndex] = partnerStages
  end

  battle.player = partner
  battle.playerIndex = partnerIndex
  if battle.stages then battle.stages.player = partnerStages end
  battle.participants = battle.participants or {}
  battle.participants[partnerIndex] = true
  if type(battle.syncSides) == "function" then pcall(battle.syncSides, battle) end

  local chosen = usableMoveId(battle, partner, moveId)
  local canAct = true
  if type(battle.canAct) == "function" then
    local ok, value = pcall(battle.canAct, battle, partner)
    canAct = ok and value ~= false
  end
  if canAct and chosen and type(battle.useMove) == "function" then
    local okMove, moveErr = pcall(battle.useMove, battle, partner, battle.enemy, chosen)
    if okMove then
      M.partnerMoves = M.partnerMoves + 1
    else
      M.lastError = tostring(moveErr)
    end
  end
  if type(battle.resolveFaints) == "function" then
    local okFaint, faintErr = pcall(battle.resolveFaints, battle)
    if not okFaint then M.lastError = tostring(faintErr) end
  end
  local events = type(battle.takeEvents) == "function" and battle:takeEvents() or {}
  -- A recoil/self-damage faint belongs to the PARTNER, not the native lead.
  -- Gold's single-active resolver offers a replacement for whatever `player`
  -- points at, so drop only that modal choose-switch event and let party-order
  -- duo selection naturally pick the next healthy partner on the next round.
  if (tonumber(partner.hp) or 0) <= 0 then
    local filtered = {}
    for _, ev in ipairs(events) do
      if not (type(ev) == "table" and ev.kind == "choose-switch") then
        filtered[#filtered + 1] = ev
      end
    end
    events = filtered
    if type(battle.faintAnnounced) == "table" then battle.faintAnnounced.player = nil end
    battle.faintInterrupt = nil
  end
  battle._stadiumDuoStages[partnerIndex] = battle.stages and battle.stages.player or partnerStages

  battle.player = lead
  battle.playerIndex = leadIndex
  if battle.stages then battle.stages.player = leadStages end
  if type(battle.syncSides) == "function" then pcall(battle.syncSides, battle) end
  return events
end

local function clearSelection(screen)
  screen._stadiumDuoSelectingPartner = nil
  screen._stadiumDuoPrimaryAction = nil
  screen._stadiumDuoPartnerIndex = nil
  screen._stadiumDuoPrimaryMoveIndex = nil
  screen._stadiumDuoHandoffFrame = nil
end

local function beginPartnerSelection(screen, battle, primary, primaryMoveIndex)
  local partner, partnerIndex = M.partnerForBattle(battle)
  if not partner then return false end

  screen._stadiumDuoPrimaryAction = primary
  screen._stadiumDuoPrimaryMoveIndex = primaryMoveIndex
    or moveSlotById(battle and battle.player, primary and primary.move)
  screen._stadiumDuoPartnerIndex = partnerIndex
  screen._stadiumDuoSelectingPartner = true
  screen._stadiumDuoHandoffFrame = screen._stadiumDuoFrame
  screen.phase = "moves"

  local count = #(partner.moves or {})
  local preferred = tonumber(primaryMoveIndex) or tonumber(screen.moveIndex) or 1
  screen.moveIndex = math.max(1, math.min(preferred, math.max(1, count)))
  screen.moveSwapIndex = nil

  -- With no usable move there is no legal choice to wait for: Gold's normal
  -- rule is STRUGGLE.  Every ordinary partner with at least one legal move
  -- stays on this move screen until the player confirms it explicitly.
  if type(battle.hasUsableMoves) == "function" and not battle:hasUsableMoves(partner) then
    local BattleCore = require("src.battle.gen2.Battle")
    local struggle = BattleCore and BattleCore.STRUGGLE or "STRUGGLE"
    screen:submit({ kind = "duo", primary = primary,
      partnerIndex = partnerIndex, partnerMove = struggle })
    return true
  end
  return true
end

function M.install()
  if M.installed then return true end
  local okBattle, Battle = pcall(require, "src.battle.gen2.Battle")
  local okState, BattleState = pcall(require, "src.ui.gen2.BattleState")
  if not (okBattle and type(Battle) == "table") then
    return false, "src.battle.gen2.Battle unavailable"
  end
  if not (okState and type(BattleState) == "table") then
    return false, "src.ui.gen2.BattleState unavailable"
  end
  if BattleState._stadiumDoubleBattleMode then
    M.installed = true
    return true
  end

  -- Mark the queue event currently being presented so Stadium's animation
  -- bridge can route a partner move to the second 3D actor rather than making
  -- the lead model perform both attacks.
  local innerAdvanceQueue = BattleState.advanceQueue
  if type(innerAdvanceQueue) == "function" then
    function BattleState:advanceQueue(...)
      local event = type(self.queue) == "table" and self.queue[1] or nil
      self._stadiumDuoPartnerEvent = type(event) == "table"
        and event._stadiumDuoPartner == true or false
      local out = { innerAdvanceQueue(self, ...) }
      self._stadiumDuoPartnerEvent = false
      local unpackFn = table.unpack or unpack
      return unpackFn(out)
    end
  end

  -- A primary move and a partner move must come from two distinct input
  -- updates.  Some controller/intent paths can dispatch twice while one confirm
  -- edge is being consumed; the frame tag prevents that same edge from also
  -- choosing the partner's attack.
  local innerUpdate = BattleState.update
  if type(innerUpdate) == "function" then
    function BattleState:update(...)
      self._stadiumDuoFrame = (tonumber(self._stadiumDuoFrame) or 0) + 1
      return innerUpdate(self, ...)
    end
  end

  local innerPlayerMoves = BattleState.playerMoves
  if type(innerPlayerMoves) == "function" then
    function BattleState:playerMoves(...)
      if optionEnabled() and self._stadiumDuoSelectingPartner then
        local battle = self.battle
        local index = self._stadiumDuoPartnerIndex
        local mon = battle and battle.party and battle.party[index]
        if healthy(mon) then return mon.moves or {} end
      end
      return innerPlayerMoves(self, ...)
    end
  end

  local innerChooseMove = BattleState.chooseMove
  if type(innerChooseMove) == "function" then
    function BattleState:chooseMove(index, ...)
      if not optionEnabled() then
        clearSelection(self)
        return innerChooseMove(self, index, ...)
      end
      if self.phase ~= "moves" then return innerChooseMove(self, index, ...) end
      local battle = self.battle
      if not battle then return innerChooseMove(self, index, ...) end

      if not self._stadiumDuoSelectingPartner then
        local partner = M.partnerForBattle(battle)
        if not partner then return innerChooseMove(self, index, ...) end
        local move = (battle.player and battle.player.moves or {})[index]
        if not move then return innerChooseMove(self, index, ...) end
        if (tonumber(move.pp) or 0) <= 0
            or (type(battle.moveDisabled) == "function" and battle:moveDisabled(battle.player, move.id)) then
          return innerChooseMove(self, index, ...)
        end

        self.moveIndex = index
        self.moveSwapIndex = nil
        return beginPartnerSelection(self, battle,
          { kind = "move", move = move.id }, index)
      end

      -- Never let the A/Cross edge that selected Pokemon #1 also select
      -- Pokemon #2.  A second move requires a second update/confirm.
      if self._stadiumDuoHandoffFrame ~= nil
          and self._stadiumDuoHandoffFrame == self._stadiumDuoFrame then
        return true
      end

      local partnerIndex = self._stadiumDuoPartnerIndex
      local partner = battle.party and battle.party[partnerIndex]
      if not healthy(partner) then
        local primary = self._stadiumDuoPrimaryAction
        clearSelection(self)
        return self:submit(primary)
      end
      local move = (partner.moves or {})[index]
      if not move then return nil, "invalid partner move slot" end
      self.moveIndex = index
      self.moveSwapIndex = nil
      if (tonumber(move.pp) or 0) <= 0 then
        if type(self.refuseMove) == "function" then self:refuseMove(NO_PP) end
        return true
      elseif type(battle.moveDisabled) == "function" and battle:moveDisabled(partner, move.id) then
        if type(self.refuseMove) == "function" then self:refuseMove(DISABLED) end
        return true
      end
      return self:submit({ kind = "duo", primary = self._stadiumDuoPrimaryAction,
        partnerIndex = partnerIndex, partnerMove = move.id })
    end
  end

  local innerCancelMove = BattleState.cancelMove
  if type(innerCancelMove) == "function" then
    function BattleState:cancelMove(...)
      if optionEnabled() and self.phase == "moves" and self._stadiumDuoSelectingPartner then
        local index = self._stadiumDuoPrimaryMoveIndex or 1
        clearSelection(self)
        self.moveIndex = index
        return true
      end
      clearSelection(self)
      return innerCancelMove(self, ...)
    end
  end

  local innerSubmit = BattleState.submit
  if type(innerSubmit) ~= "function" then return false, "BattleState.submit unavailable" end
  function BattleState:submit(action, ...)
    if not optionEnabled() or type(action) ~= "table" then
      clearSelection(self)
      return innerSubmit(self, action, ...)
    end

    local battle = self.battle
    local primary, partnerIndex, partnerMove
    if action.kind == "duo" then
      primary = action.primary or { kind = "move" }
      partnerIndex = action.partnerIndex
      partnerMove = action.partnerMove
    elseif action.kind == "move" then
      if self._stadiumDuoSelectingPartner then
        -- Direct battle-intent/controller paths can submit a move without
        -- passing through chooseMove.  While the partner selector is active,
        -- that submitted move belongs to Pokemon #2 -- but never on the same
        -- update that handed control over from Pokemon #1.
        if self._stadiumDuoHandoffFrame ~= nil
            and self._stadiumDuoHandoffFrame == self._stadiumDuoFrame then
          return true
        end
        primary = self._stadiumDuoPrimaryAction
        partnerIndex = self._stadiumDuoPartnerIndex
        partnerMove = action.move
        if not primary or not partnerIndex then
          clearSelection(self)
          return innerSubmit(self, action, ...)
        end
      else
        -- Locked-in moves, STRUGGLE, and validated battle-intent paths may
        -- bypass chooseMove.  v0.2.93 auto-picked Pokemon #2 here; that made
        -- the partner feel uncontrollable.  Instead, stop on Pokemon #2's move
        -- menu and require a real second choice whenever it has one.
        local started = beginPartnerSelection(self, battle, action,
          moveSlotById(battle and battle.player, action.move))
        if started then return started end
        clearSelection(self)
        return innerSubmit(self, action, ...)
      end
    else
      -- PACK / PKMN / RUN keep Gold's native turn semantics. The duo is back
      -- on the next FIGHT command; this avoids inventing a second action for a
      -- turn where the player did not choose one.
      clearSelection(self)
      return innerSubmit(self, action, ...)
    end

    clearSelection(self)
    self.phase = "resolving"
    local events = battle:takeTurn(primary)
    -- If the lead fainted, Gold is waiting for its native replacement choice;
    -- do not sneak a partner action past that modal state.
    if not battle.over and not hasChooseSwitch(events) then
      local extra = partnerAttack(battle, partnerIndex, partnerMove)
      for _, ev in ipairs(extra or {}) do
        if type(ev) == "table" then ev._stadiumDuoPartner = true end
        events[#events + 1] = ev
      end
      M.duoTurns = M.duoTurns + 1
    end

    self:pushAll(events)
    self.message = nil
    self.messageTimer = 0
    self:advanceQueue()
  end

  BattleState._stadiumDoubleBattleMode = true
  M.installed = true
  return true
end

function M.status()
  return {
    installed = M.installed,
    enabled = optionEnabled(),
    duoTurns = M.duoTurns,
    partnerMoves = M.partnerMoves,
    lastError = M.lastError,
  }
end

return M
