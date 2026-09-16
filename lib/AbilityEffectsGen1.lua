-- Optional GC6E01 ability hooks over the supplied native Gen I engine. Battler
-- and party identities stay native; OFF delegates to the pre-existing methods.
-- Source-proven formula inputs (stat/power/accuracy order) are inserted before
-- the host's native calculation; categories with unresolved retail seams remain
-- deliberately fail-closed/isolated rather than being called complete parity.
local V=... or {}
local unpack=unpack or table.unpack
local function pack(...)return {n=select('#',...),...}end
local req=V.engineRequire or require
local Abilities=V.Abilities or error("AbilityEffectsGen1 requires Abilities to load first")
local Weather=V.AbilityWeather or error("AbilityEffectsGen1 requires AbilityWeather to load first")
local M={}
local installed=false
-- Cached at install time (real modules in production, stubs in tests) so
-- trigger functions never call req() themselves.
local StatusRegistry, MoveEffects


local function enabled(battle)
  return Abilities.enabledBattle(battle)
end

local function dexOf(battle, mon)
  if not mon then return nil end
  local def=battle and battle.data and battle.data.pokemon and battle.data.pokemon[mon.species]
  return Abilities.dexOf(mon, def)
end

-- `battler` here is whatever the engine calls user/target/attacker/defender:
-- a table carrying `.mon`. Resolves and caches the individual's ability.
local function abilityOf(battle, battler)
  battler=battler and (battler.battler or battler)
  local mon=battler and battler.mon
  if not mon then return nil end
  return Abilities.current(battle, mon, dexOf(battle, mon))
end

local function hasAbility(battle, battler, id)
  return abilityOf(battle, battler)==id
end

local function fieldHasAbility(battle,id)
  for _,value in ipairs(Abilities.actives(battle) or {}) do
    if abilityOf(battle,value)==id then return true end
  end
  return false
end

-- ---------------------------------------------------------------------
-- category tables, driven by AbilityData so a data fix doesn't need a
-- code change
-- ---------------------------------------------------------------------

local LOW_HP_TYPE={}       -- id -> moveType, e.g. OVERGROW->GRASS
for id,meta in pairs(Abilities.data.byId) do
  if meta.category=="low_hp_power" then LOW_HP_TYPE[id]=meta.moveType end
end

local STATUS_VETO={}       -- id -> status code the ability blocks
for id,meta in pairs(Abilities.data.byId) do
  if meta.category=="status_veto" then STATUS_VETO[id]=meta.status end
end

local STAT_VETO={}         -- id -> "ALL" or a specific stat name
for id,meta in pairs(Abilities.data.byId) do
  if meta.category=="stat_veto" then STAT_VETO[id]=meta.stat end
end

local CONTACT_REACTIVE={}  -- id -> {effect=status or "RANDOM_MINOR", chance=, options=}
local CONTACT_DAMAGE={}    -- id -> max-HP recoil fraction (Rough Skin)
for id,meta in pairs(Abilities.data.byId) do
  if meta.category=="contact_reactive" and meta.effect~="ATTRACT" then
    CONTACT_REACTIVE[id]={effect=meta.effect, chance=meta.chance, options=meta.options}
  elseif meta.category=="contact_damage" then
    CONTACT_DAMAGE[id]=meta.fraction or (1/16)
  end
end

-- Colosseum determines physical/special by move TYPE, not a per-move flag
-- (the reference document is explicit about this, and the engine's own move
-- fixture shape carries no separate category field either): Normal/Fighting/
-- Flying/Poison/Ground/Rock/Bug/Ghost/Steel are physical; Fire/Water/Grass/
-- Electric/Ice/Psychic/Dragon/Dark are special.
local PHYSICAL_TYPES={NORMAL=true,FIGHTING=true,FLYING=true,POISON=true,GROUND=true,
  ROCK=true,BUG=true,GHOST=true,STEEL=true}
local function isPhysical(move)
  if not move then return false end
  -- GC6E01 is a Gen-III battle engine: physical/special is owned by TYPE,
  -- never by the per-move category field introduced in later generations.
  return PHYSICAL_TYPES[move.type]==true
end

local function shallow(t)
  local out={}
  for k,v in pairs(t or {}) do out[k]=v end
  return out
end

local function isBurnStatus(status)
  local s=status and tostring(status):upper() or ""
  return s=="BRN" or s=="BURN"
end

-- ---------------------------------------------------------------------
-- 1. Damage / accuracy / crit -- BattleState:computeDamage / accuracyRoll.
--    Hooked at the METHOD level (self=battle), not the lower Damage.compute
--    / Damage.accuracyRoll module functions, since those never receive a
--    battle reference (confirmed: Damage.compute's opts is rng/forceCrit/
--    explode/typeless/screens only) and abilities need one for the toggle
--    check and dex/ability resolution.
-- ---------------------------------------------------------------------

local function installDamage(BattleState, Damage)
  local origCompute=BattleState.computeDamage
  BattleState.computeDamage=function(self, user, target, move, opts)
    if not enabled(self) then return origCompute(self, user, target, move, opts) end
    local atkAbility=abilityOf(self, user)
    local defAbility=abilityOf(self, target)
    local moveType=move and move.type

    -- Type immunity / absorb (Levitate, Volt Absorb, Water Absorb) short-
    -- circuit before the native formula even runs.
    if defAbility then
      local meta=Abilities.meta(defAbility)
      if meta and (meta.category=="type_immune" or meta.category=="type_immune_boost")
          and meta.moveType==moveType then
        if meta.category=="type_immune_boost" then Abilities.runtime(self,target.mon).flashFire=true end
        Abilities.message(self,Abilities.displayName(defAbility).." blocked the move!")
        return 0, {crit=false, typeMult=0, immune=true, ability=defAbility}
      end
      if meta and meta.category=="type_absorb_heal" and meta.moveType==moveType then
        local defMon=target.mon
        if defMon and defMon.hp then
          local heal=math.max(1,math.floor(Abilities.maxHP(defMon)*(meta.healFraction or 0.25)))
          defMon.hp=math.min(Abilities.maxHP(defMon),defMon.hp+heal)
          Abilities.message(self,Abilities.displayName(defAbility).." restored HP!")
        end
        return 0, {crit=false, typeMult=0, absorbed=true, ability=defAbility}
      end
    end

    -- GC6E01 fn_80213E74 applies these abilities to the formula INPUTS, not to
    -- the final HP damage.  That distinction is visible whenever integer floors,
    -- stat stages, screens, STAB/type rows or the random roll are involved.
    -- Keep the native host formula authoritative and feed it a detached view of
    -- the exact source-side stat/power mutations.
    local calcUser,calcTarget,calcMove=user,target,move
    local needUserCopy=false
    local mon=user and user.mon
    local physical=isPhysical(move)
    if physical and (atkAbility=="HUGE_POWER" or atkAbility=="PURE_POWER" or atkAbility=="HUSTLE"
        or (atkAbility=="GUTS" and mon and mon.status)) then
      needUserCopy=true
    end
    local thickFat=false
    if defAbility then
      local meta=Abilities.meta(defAbility)
      if meta and meta.category=="type_damage_half" then
        for _,t in ipairs(meta.moveTypes or {}) do if t==moveType then thickFat=true;break end end
      end
    end
    if thickFat then needUserCopy=true end
    if needUserCopy then
      calcUser=shallow(user);calcUser.curStats=shallow(user and user.curStats)
      if physical then
        local attack=tonumber(calcUser.curStats.attack)
        if attack then
          if atkAbility=="HUGE_POWER" or atkAbility=="PURE_POWER" then attack=attack*2
          elseif atkAbility=="HUSTLE" then attack=math.floor(attack*150/100)
          elseif atkAbility=="GUTS" and mon and mon.status then attack=math.floor(attack*150/100) end
          calcUser.curStats.attack=attack
        end
        -- In retail, Guts both boosts Attack and exempts the holder from the
        -- later burn Attack-halving branch.  The Red host's burn penalty is read
        -- only from attacker.mon.status inside Damage.compute, so detach just
        -- that status for the one formula call instead of mutating the real mon.
        if atkAbility=="GUTS" and mon and isBurnStatus(mon.status) then
          calcUser.mon=shallow(mon);calcUser.mon.status=nil
        end
      end
      if thickFat and calcUser.curStats.special then
        calcUser.curStats.special=math.floor(calcUser.curStats.special/2)
      end
    end
    local partnerMeta=atkAbility and Abilities.meta(atkAbility)
    if partnerMeta and partnerMeta.category=="field_partner_special_boost"
        and fieldHasAbility(self,partnerMeta.partnerAbility) then
      if calcUser==user then calcUser=shallow(user);calcUser.curStats=shallow(user and user.curStats) end
      if calcUser.curStats and calcUser.curStats.special then
        calcUser.curStats.special=math.floor(calcUser.curStats.special*(partnerMeta.multiplier or 1.5))
      end
    end
    if physical and defAbility=="MARVEL_SCALE" and target and target.mon and target.mon.status then
      calcTarget=shallow(target);calcTarget.curStats=shallow(target.curStats)
      if calcTarget.curStats.defense then
        calcTarget.curStats.defense=math.floor(calcTarget.curStats.defense*150/100)
      end
    end
    local lowHpType=atkAbility and LOW_HP_TYPE[atkAbility]
    if lowHpType and moveType==lowHpType and mon and mon.hp
        and mon.hp<=math.floor(Abilities.maxHP(mon)/3)
        and move and tonumber(move.power) and move.power>0 then
      calcMove=shallow(move);calcMove.power=math.floor(move.power*150/100)
    end

    -- Crit immunity (Battle Armor / Shell Armor): Damage.critRoll only
    -- receives the attacker, not the defender, so it can't check the
    -- holder's own ability. Force it to miss for the duration of this one
    -- compute call instead, now that both battlers are known here.
    local critMeta=defAbility and Abilities.meta(defAbility)
    local dmg,info
    if critMeta and critMeta.category=="crit_immune" and Damage and Damage.critRoll then
      local origCrit=Damage.critRoll
      Damage.critRoll=function() return false end
      local ok,a,b=pcall(origCompute, self, calcUser, calcTarget, calcMove, opts)
      Damage.critRoll=origCrit
      if not ok then error(a) end
      dmg,info=a,b
    else
      dmg,info=origCompute(self, calcUser, calcTarget, calcMove, opts)
    end
    if not dmg or dmg<=0 then return dmg,info end

    -- Wonder Guard (GC6E01 ability 0x19): the source-proven core check is made
    -- against the resolved x10 type multiplier after the host formula has
    -- established the actual matchup. Ordinary damaging hits that are not
    -- super-effective are cancelled; status moves never reach this branch.
    if defAbility=="WONDER_GUARD" and (tonumber(info and info.typeMult) or 10)<=10 then
      local blocked=type(info)=="table" and shallow(info) or {}
      blocked.ability=defAbility;blocked.wonderGuard=true;blocked.typeMult=0;blocked.immune=true
      Abilities.message(self,"WONDER GUARD blocked the move!")
      return 0,blocked
    end

    -- Flash Fire's activation path is already source-owned, but its precise
    -- boosted-damage insertion point is not yet recovered end-to-end.  Leave
    -- that one isolated late modifier as explicitly unresolved rather than
    -- contaminating the now-exact Huge Power/Hustle/Guts/low-HP/Thick Fat path.
    if atkAbility then
      local activeMeta=Abilities.meta(atkAbility)
      if activeMeta and activeMeta.category=="type_immune_boost" and activeMeta.moveType==moveType
          and Abilities.runtime(self,user.mon).flashFire then
        dmg=math.floor(dmg*(activeMeta.multiplier or 1.5))
      end
    end
    return dmg,info
  end

  -- GC6E01 applies ability accuracy multipliers AFTER the attacker's Accuracy
  -- and defender's Evasion stages, with an integer floor after each operation:
  -- Compound Eyes x130%, Sand Veil x80%, then Hustle x80% for physical types.
  -- Red exposes the post-stage value through Damage.accuracyThreshold, so wrap
  -- only that threshold for this synchronous roll rather than scaling base move
  -- accuracy ahead of the native stage math.
  local function adjustThreshold(self,user,target,move,value)
    value=math.floor(tonumber(value) or 0)
    local atkAbility=abilityOf(self,user)
    if atkAbility=="COMPOUNDEYES" then value=math.floor(value*130/100) end
    local defAbility=abilityOf(self,target)
    if defAbility=="SAND_VEIL" then
      local hasCloudNine=function(b)return hasAbility(self,b,"CLOUD_NINE")end
      if Weather.sandAccuracyMultiplier(self,1,hasCloudNine)<1 then value=math.floor(value*80/100) end
    end
    if atkAbility=="HUSTLE" and isPhysical(move) then value=math.floor(value*80/100) end
    return value
  end

  local origAccuracy=BattleState.accuracyRoll
  BattleState.accuracyRoll=function(self,move,user,target)
    if not enabled(self) then return origAccuracy(self,move,user,target) end
    local atkAbility=abilityOf(self,user);local defAbility=abilityOf(self,target)
    local active=atkAbility=="COMPOUNDEYES" or (atkAbility=="HUSTLE" and isPhysical(move))
      or defAbility=="SAND_VEIL"
    local threshold=Damage and Damage.accuracyThreshold
    if not (active and threshold) then return origAccuracy(self,move,user,target) end
    Damage.accuracyThreshold=function(ruleset,m,a,d)
      return adjustThreshold(self,user,target,move,threshold(ruleset,m,a,d))
    end
    local result=pack(pcall(origAccuracy,self,move,user,target))
    Damage.accuracyThreshold=threshold
    if not result[1] then error(result[2],0) end
    return unpack(result,2,result.n)
  end
end

-- ---------------------------------------------------------------------
-- 2. Status infliction veto + Synchronize reflect -- StatusRegistry.lua
-- ---------------------------------------------------------------------

local function installStatus(StatusRegistry)
  local origInflict=StatusRegistry.inflict
  StatusRegistry.inflict=function(battle, target, status, opts)
    if not enabled(battle) then return origInflict(battle, target, status, opts) end
    local defAbility=abilityOf(battle, target)
    if defAbility and STATUS_VETO[defAbility]==status then
      return {}
    end
    local before=target.mon and target.mon.status
    local ok=origInflict(battle, target, status, opts)
    local after=target.mon and target.mon.status
    -- Synchronize: reflect BRN/PSN/PAR back onto whoever inflicted it,
    -- once, guarded against ping-ponging with another Synchronize holder.
    if ok and after and after~=before and not (opts and opts.viaSynchronize)
        and (status=="BRN" or status=="PSN" or status=="PAR") then
      local source=(opts and opts.sourceBattler) or battle.__cbeAbilitySource
      if source and hasAbility(battle, target, "SYNCHRONIZE") and source~=target then
        StatusRegistry.inflict(battle, source, status, {secondary=true, viaSynchronize=true})
      end
    end
    return ok
  end
end

-- ---------------------------------------------------------------------
-- 3. Stat-stage veto -- MoveEffects.changeStage (exported)
-- ---------------------------------------------------------------------

local function installStatStage(MoveEffects)
  local origChange=MoveEffects.changeStage
  MoveEffects.changeStage=function(battle, who, stat, delta, fromEnemy)
    if enabled(battle) and fromEnemy and delta<0 then
      local ability=abilityOf(battle, who)
      local veto=ability and STAT_VETO[ability]
      if veto=="ALL" or veto==stat then
        return {}
      end
    end
    return origChange(battle, who, stat, delta, fromEnemy)
  end
end

-- ---------------------------------------------------------------------
-- 4. OHKO gate (Sturdy), recoil veto (Rock Head), drain punish (Liquid
--    Ooze), secondary-effect table (Serene Grace / Shield Dust) --
--    MoveEffects.full / MoveEffects.secondary
-- ---------------------------------------------------------------------

-- Native records capture the original primary/secondary handlers at module
-- load. Resolve a detached record around the actual engine dispatch instead
-- of rewriting a shared registry or trusting a stale exported handler table.
local function installEffectRecords(BattleState)
  local original=BattleState.effectRecord
  if not original then return end
  BattleState.effectRecord=function(self,effect)
    local record=original(self,effect)
    if not enabled(self) or type(record)~="table" then return record end
    local out={};for k,v in pairs(record) do out[k]=v end
    if effect=="OHKO_EFFECT" then
      out.gate=function(ctx)
        if hasAbility(self,ctx.target,"STURDY") then return false,"STURDY blocked the one-hit KO!" end
        if record.gate then return record.gate(ctx) end
        return true
      end
    end
    if type(record.afterDamage)=="function" and (effect=="RECOIL_EFFECT" or effect=="DRAIN_HP_EFFECT") then
      out.afterDamage=function(ctx,...)
        if effect=="RECOIL_EFFECT" and not ctx.moveInst.struggle and ctx.move.id~="STRUGGLE"
            and hasAbility(self,ctx.user,"ROCK_HEAD") then return end
        if effect=="DRAIN_HP_EFFECT" and hasAbility(self,ctx.target,"LIQUID_OOZE") and (ctx.totalDealt or 0)>0 then
          self:applyDamage(ctx.user,math.max(1,math.floor(ctx.totalDealt/2)))
          Abilities.message(self,"LIQUID OOZE hurt the draining Pokemon!");return
        end
        return record.afterDamage(ctx,...)
      end
    end
    if type(record.run)=="function" then
      out.run=function(ctx,...)
        local targetAbility=abilityOf(self,ctx.target)
        if record.kind~="primary" and targetAbility=="SHIELD_DUST" then return {} end
        if ctx.user~=ctx.target then
          local stat=effect and effect:match("^(%w+)_DOWN")
          local veto=targetAbility and STAT_VETO[targetAbility]
          if stat and (veto=="ALL" or veto==stat:lower()) then return {} end
        end
        if targetAbility=="OWN_TEMPO" and effect and effect:find("CONFUSION",1,true) then return {} end
        if targetAbility=="INNER_FOCUS" and effect and effect:find("FLINCH",1,true) then return {} end
        if record.kind~="primary" and hasAbility(self,ctx.user,"SERENE_GRACE") and type(self.rng)=="function" then
          local rng,crng=self.rng,ctx.rng
          self.rng=function(lo,hi) local n=rng(lo,hi);if lo==0 and hi==255 then return math.floor(n/2) end;return n end
          ctx.rng=self.rng
          local results=pack(pcall(record.run,ctx,...));self.rng=rng;ctx.rng=crng
          if not results[1] then error(results[2],0) end
          return unpack(results,2,results.n)
        end
        return record.run(ctx,...)
      end
    end
    return out
  end
end

-- ---------------------------------------------------------------------
-- 5+6. Contact-reactive triggers (Static/Poison Point/Flame Body/Effect
--      Spore) and PP cost (Pressure) -- both wrap BattleState:performMove,
--      since that's the one call site with user, target AND moveInst
--      together. applyDamage alone never sees the move id, and there is
--      no single "the main hit just landed" chokepoint separate from the
--      effect-specific afterDamage callbacks used above -- performMove's
--      own before/after HP diff is the most reliable proxy available.
-- ---------------------------------------------------------------------

local function triggerContact(battle, attacker, defender, moveId, moveDef, dealt)
  if not (dealt and dealt>0) then return end
  if not Abilities.isContactMove(moveId,moveDef) then return end
  local defAbility=abilityOf(battle, defender)
  local fraction=defAbility and CONTACT_DAMAGE[defAbility]
  if fraction and attacker and attacker.mon and (attacker.mon.hp or 0)>0 then
    battle:applyDamage(attacker,math.max(1,math.floor(Abilities.maxHP(attacker.mon)*fraction)))
    Abilities.message(battle,Abilities.displayName(defAbility).." hurt the attacker!")
    return
  end
  local reactive=defAbility and CONTACT_REACTIVE[defAbility]
  if not reactive then return end
  local roll=Abilities.random(battle)
  if reactive.effect=="RANDOM_MINOR" then
    if roll<=reactive.chance then
      local pick=reactive.options[Abilities.pick(battle,#reactive.options)]
      StatusRegistry.inflict(battle, attacker, pick, {secondary=true, sourceBattler=defender})
    end
  elseif roll<=reactive.chance then
    StatusRegistry.inflict(battle, attacker, reactive.effect, {secondary=true, sourceBattler=defender})
  end
end

local function installPerformMoveEffects(BattleState)
  local orig=BattleState.performMove
  if not orig then return end
  BattleState.performMove=function(self, user, target, moveInst, isCalled)
    if not enabled(self) then return orig(self, user, target, moveInst, isCalled) end
    local before=target and target.mon and target.mon.hp
    local hadSub=target and target.substituteHP
    local beforePP=moveInst and moveInst.pp
    local source=self.__cbeAbilitySource;self.__cbeAbilitySource=user

    -- GC6E01 hit-check handles Soundproof (ability 0x2B) after the move has
    -- already been selected/paid for and announced, but before ordinary
    -- accuracy, damage or effect execution. Red's performMove has exactly one
    -- matching synchronous seam: `record.perform`, reached after PP debit +
    -- announcement and before either the status or damaging pipeline.
    -- Substitute only this one target's record for the duration of the call;
    -- doubles dispatches each target separately, so a Soundproof holder cannot
    -- suppress the same spread move against its non-Soundproof partner.
    local moveDef=moveInst and type(self.moveDef)=="function" and self:moveDef(moveInst) or nil
    local soundBlocked=target and target~=user and hasAbility(self,target,"SOUNDPROOF")
      and Abilities.isSoundMove and Abilities.isSoundMove(moveDef)
    local savedEffectRecord=rawget(self,"effectRecord")
    if soundBlocked then
      local resolve=self.effectRecord
      self.effectRecord=function(battle,effect)
        if moveDef and effect==moveDef.effect then
          return {kind="full",perform=function()
            if type(battle.cancelMoveAnim)=="function" then battle:cancelMoveAnim() end
            Abilities.message(battle,"SOUNDPROOF blocked the move!")
          end}
        end
        return resolve(battle,effect)
      end
    end
    local result=pack(pcall(orig,self,user,target,moveInst,isCalled))
    if soundBlocked then self.effectRecord=savedEffectRecord end
    self.__cbeAbilitySource=source
    if not result[1] then error(result[2],0) end
    if target and moveInst then
      -- Only a real native PP debit can acquire an extra Pressure charge.
      -- Called/spread repetitions, charge releases and interrupted turns cannot.
      if type(beforePP)=="number" and type(moveInst.pp)=="number" and moveInst.pp<beforePP
          and not self.__cbeDoublesKernel and target~=user and hasAbility(self,target,"PRESSURE") then
        moveInst.pp=math.max(0,moveInst.pp-1)
      end
      local after=target.mon and target.mon.hp
      if before and after and after<before and not hadSub and user and (user.mon.hp or 0)>0 then
        local moveDef=self.data and self.data.moves and self.data.moves[moveInst.id]
        triggerContact(self,user,target,moveInst.id,moveDef,before-after)
      end
    end
    return unpack(result,2,result.n)
  end
end

-- ---------------------------------------------------------------------
-- 7. Trap / switch block (Arena Trap, Magnet Pull, Shadow Tag) --
--    BattleState:resolveSwitch is the only switch entry point found in
--    this engine; there is no separate "can switch" gate to veto earlier,
--    so a trapped attempt is refused at this point instead. See the plan's
--    risk ledger: this is the best available interception point, not a
--    perfect reproduction of the original "can't even select Run/switch"
--    presentation.
-- ---------------------------------------------------------------------

local function trapsSwitch(battle, outgoing, incoming)
  if not enabled(battle) or not outgoing or not outgoing.mon or (outgoing.mon.hp or 0)<=0 then return false end
  local opponent=(battle.player==outgoing) and battle.enemy or battle.player
  local trapAbility=abilityOf(battle, opponent)
  if not trapAbility then return false end
  local meta=Abilities.meta(trapAbility)
  if not (meta and meta.category=="trap_block") then return false end
  if trapAbility=="MAGNET_PULL" then
    local def=battle.data and battle.data.pokemon and outgoing.mon and battle.data.pokemon[outgoing.mon.species]
    local types=Abilities.types(battle,outgoing)
    local isSteel=false
    for _,t in ipairs(types) do if t=="STEEL" then isSteel=true end end
    if not isSteel then return false end
  else
    -- Arena Trap: grounded only (Flying/Levitate exempt). Shadow Tag: everyone.
    if trapAbility=="ARENA_TRAP" then
      local outAbility=abilityOf(battle, outgoing)
      if outAbility=="LEVITATE" then return false end
      local def=battle.data and battle.data.pokemon and outgoing.mon and battle.data.pokemon[outgoing.mon.species]
      for _,t in ipairs(Abilities.types(battle,outgoing)) do if t=="FLYING" then return false end end
    end
  end
  return true
end

local function installSwitchTrap(BattleState)
  local orig=BattleState.resolveSwitch
  if not orig then return end
  BattleState.resolveSwitch=function(self, newMon)
    if trapsSwitch(self, self.player, newMon) then
      self:say("It cannot escape!")
      return
    end
    return orig(self, newMon)
  end
end

-- Early Bird source proof: GC6E01's sleep-state update increments the sleep
-- counter by `ability==0x30 ? 2 : 1` each attempted sleeping turn.  Red stores
-- the inverse countdown, so the identical operation is one EXTRA decrement
-- before its native sleep handler.  Keep both Red status paths covered: normal
-- moves go through Status.beforeMove; recharge turns use preRechargeChecks.
local function installEarlyBird(BattleState,StatusRegistry)
  local function extraTick(battle,battler)
    if not (battle and battler and battler.mon and enabled(battle)) then return end
    if battler.mon.status=="SLP" and abilityOf(battle,battler)=="EARLY_BIRD" then
      battler.sleepTurns=(battler.sleepTurns or 1)-1
    end
  end
  local before=StatusRegistry and StatusRegistry.beforeMove
  if before then
    StatusRegistry.beforeMove=function(battler,rng,battle,selectedMoveId)
      extraTick(battle,battler)
      return before(battler,rng,battle,selectedMoveId)
    end
  end
  local pre=BattleState.preRechargeChecks
  if pre then
    BattleState.preRechargeChecks=function(self,user,target)
      extraTick(self,user)
      return pre(self,user,target)
    end
  end
end

-- ---------------------------------------------------------------------
-- Global installer
-- ---------------------------------------------------------------------

function M.installGlobal(ctx)
  if installed then return true end
  local req2=(ctx and ctx.engineRequire) or req
  local Damage=(ctx and ctx.Damage) or req2('src.battle.Damage')
  StatusRegistry=(ctx and ctx.StatusRegistry) or req2('src.battle.StatusRegistry')
  local Status
  if ctx then
    Status=ctx.Status or (ctx.StatusRegistry and ctx.StatusRegistry.beforeMove and ctx.StatusRegistry)
  else
    Status=req2('src.battle.Status')
  end
  MoveEffects=(ctx and ctx.MoveEffects) or req2('src.battle.MoveEffects')
  local BattleState=(ctx and ctx.BattleState) or req2('src.battle.BattleState')
  installDamage(BattleState, Damage)
  installStatus(StatusRegistry)
  installStatStage(MoveEffects)
  installEffectRecords(BattleState)
  installPerformMoveEffects(BattleState)
  installSwitchTrap(BattleState)
  installEarlyBird(BattleState,Status)
  installed=true
  return true
end

-- ---------------------------------------------------------------------
-- Shared lifecycle logic, callable from both the native battle.started /
-- battle.battler_switched event listeners AND the doubles controller's
-- own onEnter hook (doubles does not run the native switch pipeline).
-- ---------------------------------------------------------------------

-- mon entering battle; opponent is whichever battler(s) are on the other
-- side (a single battler in singles, a list in doubles).
-- `battler` is the entering Pokemon's battler (has .mon), matching every
-- other function in this module. `opponents` is a battler, or a list of
-- battlers (doubles), for whoever is already on the opposing side.
function M.onEnter(battle, battler, opponents)
  if not enabled(battle) then return end
  battler=battler and (battler.battler or battler)
  if not (battler and battler.mon and (battler.mon.hp or 0)>0) then return end
  local ability=abilityOf(battle, battler)
  if not ability then return end
  local meta=Abilities.meta(ability)
  if not meta then return end
  local list=opponents
  if list and list.mon then list={list} end -- normalize a single battler to a list
  if meta.category=="switch_in_stat" then
    Abilities.message(battle,"INTIMIDATE activated!")
    for _,opp in ipairs(list or {}) do
      opp=opp.battler or opp
      local messages=MoveEffects.changeStage(battle,opp,meta.stat,meta.stages or -1,true)
      for _,text in ipairs(messages or {}) do Abilities.message(battle,text) end
    end
  elseif meta.category=="switch_in_weather" then
    Weather.set(battle, 1, meta.weather, {abilityLocked=meta.turns=="infinite"})
    Abilities.message(battle,"SAND STREAM stirred up a sandstorm!")
  elseif meta.category=="switch_in_copy_ability" then
    local pool={}
    for _,opp in ipairs(list or {}) do
      local oppAbility=abilityOf(battle, opp)
      if oppAbility and oppAbility~="TRACE" then pool[#pool+1]=oppAbility end
    end
    if #pool>0 then
      local mon=battler.mon
      Abilities.runtime(battle,mon).trace=pool[Abilities.pick(battle,#pool)]
      Abilities.message(battle,"TRACE copied "..(Abilities.displayName(Abilities.runtime(battle,mon).trace) or "an ability").."!")
      M.onEnter(battle,battler,list)
    end
  end
end

function M.onLeave(battle, battler)
  battler=battler and (battler.battler or battler)
  if not (battler and battler.mon) then return end
  if not enabled(battle) then Abilities.reset(battle,battler.mon);return end
  if hasAbility(battle, battler, "NATURAL_CURE") then
    Abilities.cure(battle,battler)
  end
  Abilities.reset(battle,battler.mon)
end

-- actives: list of battlers currently on the field (both sides).
function M.onEndOfTurn(battle, actives)
  if not enabled(battle) then return end
  for _,battler in ipairs(actives or {}) do
    battler=battler.battler or battler
    local mon=battler.mon
    if mon and (mon.hp or 0)>0 then
      local ability=abilityOf(battle,battler)
      if ability=="SHED_SKIN" and mon.status and Abilities.random(battle)<1/3 then
        Abilities.cure(battle,battler)
      elseif ability=="SPEED_BOOST" then
        for _,text in ipairs(MoveEffects.changeStage(battle,battler,"speed",1,false) or {}) do Abilities.message(battle,text) end
      end
    end
  end
  local hasCloudNine=function(b) return hasAbility(battle,b,"CLOUD_NINE") end
  Weather.tick(battle, 1, {
    hasCloudNine=hasCloudNine,
    actives=function()
      local out={}
      for _,battler in ipairs(actives or {}) do
        battler=battler.battler or battler
        local mon=battler.mon
        if mon and (mon.hp or 0)>0 then
          out[#out+1]={
            mon=mon,
            dealDamage=function(dmg) battle:applyDamage(battler, dmg) end,
            types=function()
              local def=battle.data and battle.data.pokemon and battle.data.pokemon[mon.species]
              return def and def.types or {}
            end,
            maxHp=function() return Abilities.maxHP(mon) end,
            isImmune=function() return battler.invulnerable==true or hasAbility(battle,battler,"SAND_VEIL") end,
          }
        end
      end
      return out
    end,
    message=function(text) Abilities.message(battle,text) end,
  })
end

function M.speedMultiplier(battle,battler)
  local meta=Abilities.meta(abilityOf(battle,battler))
  if not meta or meta.category~="weather_speed" then return 1 end
  return Weather.speedMultiplierFor(battle,1,battler,function(b)return hasAbility(battle,b,"CLOUD_NINE")end,meta.weather,meta.multiplier)
end
M.enabled=enabled
M.abilityOf=abilityOf
M.hasAbility=hasAbility
M.dexOf=dexOf

return M
