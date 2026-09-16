-- Mt. Battle 100 battle launcher: turns "fight N's generated roster" into
-- a running battle, for either generation, using Level 50 clones of the
-- player's real party (never the real save-linked mons).
--
-- Gen 1 mechanics use a challenge-local proxy game/save/data view.  This avoids
-- the historical temporary save.party swap and allows projected ColosseumDex
-- species to exist only for the lifetime of the Mt. Battle fight.  The Red
-- kernel remains authoritative; BattleData supplies narrowly-scoped adapters
-- for source split-Special/type data that Red cannot represent natively.
--
-- Gen 2 mechanics (verified in Phase 0 Spike 5): Battle.new({party=,
-- trainer=,battleType=,save=}) needs no such workaround -- opts.party is
-- used directly, no fallback to game.save.party exists at all.
local V=... or {}
local req=V.engineRequire or require
local LevelClone=V.MtBattleLevelClone
local TrainerPoolG1=V.MtBattleTrainerPoolG1
local Difficulty=V.MtBattleDifficulty
local BattleObserver=V.MtBattleBattleObserver
local PlayerBehaviorTracker=V.MtBattlePlayerBehaviorTracker
local SaveState=V.MtBattleSaveState
local BattleData=V.MtBattleBattleData
local BL={}
local LEVEL_LOCK=(LevelClone and tonumber(LevelClone.LEVEL_LOCK)) or 50
-- constants/battle_constants.asm / src/world/gen2/World.lua: BATTLETYPE_CANLOSE.
-- Gen2 Battle.lua stores the numeric byte verbatim; the earlier string
-- "canlose" never matched cartridge semantics and could leak ordinary loss
-- handling into a challenge fight.
local GEN2_BATTLETYPE_CANLOSE=1

local function applyPersistentTeamState(game,clones,data)
  if not (SaveState and type(SaveState.state)=="function" and type(clones)=="table") then return clones end
  data=data or (BattleData and type(BattleData.data)=="function" and BattleData.data(game)) or (game and game.data)
  if type(SaveState.repairTeamPP)=="function" then SaveState.repairTeamPP(game,data) end
  local save=SaveState.state(game)
  local team=type(save.lastTeamStatus)=="table" and save.lastTeamStatus or {}
  for i,mon in ipairs(clones) do
    local row=team[i]
    if type(row)=="table" and (row.species==nil or row.species==mon.species) then
      local maxHp=tonumber(mon.maxHp or mon.maxHP) or (type(mon.stats)=="table" and tonumber(mon.stats.hp)) or tonumber(row.maxHp) or 1
      maxHp=math.max(1,math.floor(maxHp))
      mon.hp=math.max(0,math.min(maxHp,math.floor(tonumber(row.hp) or maxHp)))
      mon.status=(row.status~=nil and row.status~="") and row.status or nil
      local savedMoves=type(row.moves)=="table" and row.moves or {}
      for j,mv in ipairs(type(mon.moves)=="table" and mon.moves or {}) do
        local saved=savedMoves[j]
        if type(mv)=="table" and type(saved)=="table" and (saved.id==nil or saved.id==mv.id) then
          local maxPp,ups
          if type(SaveState.movePPLimit)=="function" then maxPp,ups=SaveState.movePPLimit(mv,data,saved)
          else
            local def=data and data.moves and data.moves[mv.id]
            ups=math.max(0,math.min(3,math.floor(tonumber(mv.ppUps or saved.ppUps) or 0)))
            maxPp=tonumber(mv.maxPp or mv.maxPP)
            if not maxPp or maxPp<=0 then
              local base=tonumber(def and def.pp) or 0
              maxPp=base+ups*math.floor(base/5)
            end
            if maxPp<=0 then maxPp=math.max(tonumber(saved.maxPp) or 0,tonumber(saved.pp) or 0,tonumber(mv.pp) or 0) end
          end
          maxPp=math.max(0,math.floor(maxPp or 0))
          mv.maxPp=maxPp;mv.maxPP=maxPp;mv.ppUps=ups or 0
          mv.pp=math.max(0,math.min(maxPp,math.floor(tonumber(saved.pp) or maxPp)))
        end
      end
    end
  end
  return clones
end

-- Construction and activation are deliberately separate.  BattleState.
-- newTrainer only BUILDS a Gen-1 battle; the native overworld normally starts
-- it through OverworldState:pushBattle, which owns the battle-transition wipe
-- and only then pushes the battle onto StateStack (where :enter emits
-- battle.started).  Mt. Battle used to stop after construction, leaving the
-- run marked active while the player remained in the setup hub.
function BL.activateGen1(game,battle)
  if not (game and game.stack and battle) then return false,"missing game stack or battle" end
  local overworld=game.overworld
  if type(overworld)=="table" and type(overworld.pushBattle)=="function" then
    local ok,why=pcall(overworld.pushBattle,overworld,battle)
    if not ok then
      if BattleData and BattleData.restoreHostTypes then BattleData.restoreHostTypes(battle) end
      return false,tostring(why)
    end
    return true
  end
  local states=game.stack.states
  if type(states)=="table" then
    for i=#states,1,-1 do
      local state=states[i]
      if state~=battle and type(state)=="table" and type(state.pushBattle)=="function" then
        local ok,why=pcall(state.pushBattle,state,battle)
        if not ok then
          if BattleData and BattleData.restoreHostTypes then BattleData.restoreHostTypes(battle) end
          return false,tostring(why)
        end
        return true
      end
    end
  end
  -- Stripped/headless hosts may not expose an OverworldState.  A direct push
  -- still obeys StateStack's contract and, unlike the old code, guarantees
  -- BattleState:enter actually runs.  Production Gen1 reaches the native
  -- pushBattle branch above and therefore keeps its retail transition.
  if type(game.stack.push)=="function" then
    local ok,why=pcall(game.stack.push,game.stack,battle)
    if not ok then
      if BattleData and BattleData.restoreHostTypes then BattleData.restoreHostTypes(battle) end
      return false,tostring(why)
    end
    return true
  end
  return false,"no Gen 1 battle activation path"
end

-- Attaches the live behavior observer (BattleObserver.lua) to a just-
-- launched battle, if all three collaborators are available -- kept
-- optional/guarded rather than required, so BattleLauncher stays usable
-- in isolation (e.g. tests that only load LevelClone/TrainerPoolG1)
-- without dragging in the whole behavior-tracking stack.
local function attachBehaviorObserver(game,generation,battle)
  if V.MtBattleBattlePoints then V.MtBattleBattlePoints.bindBattle(game,battle,SaveState.state(game).currentEncounter) end
  if not (BattleObserver and PlayerBehaviorTracker and SaveState) then return end
  local detach=BattleObserver.attach(battle,generation,function(summary)
    PlayerBehaviorTracker.recordFight(SaveState.state(game),summary)
  end)
  -- A normal result makes BattleObserver detach itself.  SUSPEND & QUIT has no
  -- battle.ended event by design, so retain the explicit detach closure for that
  -- no-result teardown path.
  battle.__cbeMtBattleDetachObserver=detach
end

-- Gen 1: launches slot `fightIndex` against the player's Level 50 clones.
-- The opponent ROSTER itself comes from TrainerPoolG1's rosterProvider
-- hook (set by RunController, not this function) -- this handles the
-- player side, the personality/identity swap-and-restore, the actual
-- construction call, and post-construction shininess.
--   rosterSource: SaveState's rosterSource array (see the plan's schema)
--   encounter: optional -- the persisted currentEncounter (RunController.
--     currentEncounter's output). When present, carries personality/
--     identity/shiny assignments (supplemental design doc) to apply for
--     this one launch; when absent, the trainer's PLAIN mod-load-time
--     registration is used unmodified (keeps this function usable
--     without the full personality system wired up, e.g. in isolation
--     tests).
-- Returns: the constructed battle object, or nil+error.
function BL.launchGen1(game,fightIndex,rosterSource,encounter)
  local BattleState=req("src.battle.BattleState")
  local challengeData=(BattleData and BattleData.data and BattleData.data(game)) or game.data
  local locked=SaveState and SaveState.state(game).rosterSnapshot or nil
  local clones,err=LevelClone.playerParty(game,1,LEVEL_LOCK,challengeData,rosterSource,locked)
  if not clones then return nil,err end
  applyPersistentTeamState(game,clones,challengeData)
  local challengeGame,gameErr
  if BattleData and type(BattleData.game)=="function" then challengeGame,gameErr=BattleData.game(game,clones) end
  challengeGame=challengeGame or game
  if gameErr and challengeGame==game then return nil,gameErr end

  local slotId=TrainerPoolG1.slotId(fightIndex)
  -- BattleData clones trainer records into the challenge view, so per-run AI
  -- identity changes never touch the frozen/global host registry.
  local record=challengeData.trainers[slotId]
  if not record then return nil,"Mt. Battle trainer slot unavailable in challenge view" end
  -- Production BattleData gives each challenge its own trainer-record clone. Keep
  -- the older isolation/fallback path safe too: if no challenge view exists and
  -- this is the host's registered record, any one-launch identity/AI mutation
  -- must be undone immediately after BattleState copies the values it consumes.
  local hostRecord=(challengeData==game.data)
  local originalRecord=hostRecord and {
    aiClass=record.aiClass,aiMods=record.aiMods,name=record.name,
  } or nil
  if encounter and encounter.tierId and encounter.personality and Difficulty then
    local personality=nil
    for _,p in ipairs(Difficulty.PERSONALITIES) do if p.id==encounter.personality then personality=p end end
    if personality then
      record.aiClass=Difficulty.combinedAiClassId(encounter.tierId,personality.id)
      record.aiMods=personality.gen1Mods
    end
  end
  if encounter and encounter.identity and encounter.identity.name then
    record.name=encounter.identity.name
  end

  -- Pokemon.new normally evaluates the host growth curve even though Mt.
  -- Battle's level lock discards EXP completely. Some Hoenn rows use growth
  -- classes absent from Red, so allowing that fallback would manufacture an
  -- irrelevant-but-wrong value. Substitute only projected source rows with the
  -- challenge-local constructor for this synchronous call, then restore the
  -- engine function unconditionally. Native rows still execute Pokemon.new.
  local Pokemon=req("src.pokemon.Pokemon")
  local originalPokemonNew=Pokemon.new
  if BattleData and type(BattleData.newGen1Mon)=="function" then
    Pokemon.new=function(data,species,level,rng)
      local def=data and data.pokemon and data.pokemon[species]
      if def and def.__cbeMtBattleSource then
        local Stats=req("src.pokemon.Stats")
        local dvs=Stats.randomDVs(rng)
        return BattleData.newGen1Mon(data,species,level,dvs)
      end
      return originalPokemonNew(data,species,level,rng)
    end
  end

  -- A resumed process may have a persisted currentEncounter but no surviving
  -- process-local rosterProvider closure. Install the exact saved rows only for
  -- this synchronous constructor call, then restore whatever provider was
  -- present. TrainerPoolG1's hook produces a detached Level-50 row view, so even
  -- a legacy {level=70} encounter neither launches above the lock nor gets
  -- rewritten in the save.
  local previousRosterProvider,temporaryRosterProvider
  if encounter and type(encounter.rows)=="table" and TrainerPoolG1
      and type(TrainerPoolG1.setRosterProvider)=="function" then
    previousRosterProvider=TrainerPoolG1.rosterProvider
    TrainerPoolG1.setRosterProvider(function(index)
      if tonumber(index)==tonumber(fightIndex) then return encounter.rows end
      if previousRosterProvider then return previousRosterProvider(index) end
      return nil
    end)
    temporaryRosterProvider=true
  end
  local ok,battle=pcall(BattleState.newTrainer,challengeGame,slotId,1,{})
  if temporaryRosterProvider then TrainerPoolG1.setRosterProvider(previousRosterProvider) end
  Pokemon.new=originalPokemonNew
  if originalRecord then
    record.aiClass=originalRecord.aiClass
    record.aiMods=originalRecord.aiMods
    record.name=originalRecord.name
  end
  if not ok then
    -- newBattle loaded the private type chart before the constructor failed.
    -- Put the host module singleton back immediately; no failed launch may leak
    -- Mt. Battle's chart into ordinary battles/menus.
    local TypeChart=req("src.battle.TypeChart");pcall(TypeChart.load,game.data)
    return nil,tostring(battle)
  end


  -- Defense in depth for stripped/older hosts whose trainer.party hook did not
  -- run: never publish a non-50 Mt. Battle enemy. Re-clone only when a mismatch
  -- is actually observed, preserving the normal six-row fast path.
  local enemyLevelMismatch=false
  for _,mon in ipairs(battle.enemyParty or {}) do
    if tonumber(mon.level)~=LEVEL_LOCK then enemyLevelMismatch=true;break end
  end
  if enemyLevelMismatch then
    if not (LevelClone and type(LevelClone.opponentParty)=="function") then
      return nil,"Mt. Battle opponent level-lock clone unavailable"
    end
    local normalized,why=LevelClone.opponentParty(battle.enemyParty,1,LEVEL_LOCK,challengeData)
    if not normalized then return nil,why end
    battle.enemyParty=normalized
  end

  -- BattleState.newTrainer has to use Red's constructor, whose Stats.calc owns
  -- one Special word. Recompute only source-projected enemy rows into the
  -- challenge-local split representation before the first battler is exposed.
  if BattleData and type(BattleData.gen1Stats)=="function" then
    for _,mon in ipairs(battle.enemyParty or {}) do
      local def=challengeData.pokemon and challengeData.pokemon[mon.species]
      if def and def.__cbeMtBattleSource then
        mon.stats=BattleData.gen1Stats(def,mon.level,mon.dvs,mon.statExp)
        mon.hp=mon.stats.hp
      end
    end
  end

  battle.playerParty=clones
  battle.cbeMtBattleLevelLock=true
  battle.cbeMtBattleChallenge=true
  battle.cbeMtBattleSummitVariation=encounter and encounter.summitVariation or nil
  battle.cbeMtBattleNumber=encounter and encounter.fightIndex or fightIndex
  battle.player=BattleState.makeBattler(challengeData,clones[1],true,nil)
  battle.playerIndex=1
  if battle.enemyParty and battle.enemyParty[1] then
    battle.enemy=BattleState.makeBattler(challengeData,battle.enemyParty[1],false,nil)
  end
  if BattleData and type(BattleData.attachGen1Battle)=="function" then BattleData.attachGen1Battle(battle,game) end

  -- Shininess (supplemental design doc): applied post-construction since
  -- native BattleState.newTrainer's party-row expansion never reads a
  -- `shiny` field -- this mod's own rendering layer (CurrentSpriteModels.
  -- lua:511) reads mon.shiny directly, generation-agnostic, so a plain
  -- post-construction field set is sufficient and correct.
  if encounter and encounter.rows then
    for i,row in ipairs(encounter.rows) do
      if row.shiny and battle.enemyParty[i] then battle.enemyParty[i].shiny=true end
    end
  end

  attachBehaviorObserver(game,1,battle)
  return battle
end

-- Gen 2: launches an ad-hoc CANLOSE battle against the player's Level 50
-- clones and an inline (pre-built Mon objects) opponent roster. Gen 2's
-- Mon objects already carry their own .shiny field from construction
-- (TeamGenGen2.lua sets it directly at Mon.new/post-build time) -- no
-- post-processing needed the way Gen 1's raw rows require.
--   opponentMons: array of already-constructed Mon objects (TeamGenGen2.
--     generate's output) -- Gen 2's Battle.new needs pre-built mons, not
--     raw rows (Spike 5).
--   trainerMeta: {name=,attributes=} for the inline trainer table -- a
--     plain manual override (no pre-registration needed on Gen 2 at all,
--     unlike Gen 1). If `encounter` is also given and carries a
--     personality/identity, those take priority over a same-named field
--     in trainerMeta (encounter is the seed-determined source of truth;
--     trainerMeta is just the entry point for callers/tests that don't
--     have a full encounter).
--   encounter: optional -- RunController.currentEncounter's output.
--     Supplies the personality-adjusted AI attributes (Difficulty.
--     combinedGen2Flags/gen2Attributes) and the identity name, mirroring
--     launchGen1's registered-record swap but with no registration
--     constraint to work around (Gen 2's trainer table is inline every
--     launch, Spike 5).
-- Returns: the constructed battle object, or nil+error. Caller (RunController)
-- supplies onDone via World:startBattle separately -- this function only
-- builds the Battle.new-shaped object; wiring it onto the world's own
-- screen stack is HubStage.lua's job (Phase 4).
function BL.launchGen2(game,rosterSource,opponentMons,trainerMeta,encounter)
  local Battle=req("src.battle.gen2.Battle")
  local challengeData=(BattleData and BattleData.data and BattleData.data(game)) or game.data
  local locked=SaveState and SaveState.state(game).rosterSnapshot or nil
  local clones,err=LevelClone.playerParty(game,2,LEVEL_LOCK,challengeData,rosterSource,locked)
  if not clones then return nil,err end
  applyPersistentTeamState(game,clones,challengeData)
  local challengeGame=BattleData and BattleData.game and BattleData.game(game,clones) or nil
  local challengeSave=(challengeGame and challengeGame.save) or game.save

  -- Battle.new retains trainer.party by reference and then mutates those Mon
  -- objects during combat. Never hand it SaveState.currentEncounter.mons
  -- directly: clone the persisted opponent identities into a fresh forced-Lv50
  -- party so stale levels are hostile input and retries/resumes keep the saved
  -- encounter byte/logically unchanged.
  if not (LevelClone and type(LevelClone.opponentParty)=="function") then
    return nil,"Mt. Battle Gen 2 opponent level-lock clone unavailable"
  end
  local lockedOpponents,lockErr=LevelClone.opponentParty(opponentMons,2,LEVEL_LOCK,challengeData)
  if not lockedOpponents then return nil,lockErr end

  local name=(trainerMeta and trainerMeta.name) or "MT. BATTLE"
  local attributes=trainerMeta and trainerMeta.attributes
  if encounter and encounter.identity and encounter.identity.name then
    name=encounter.identity.name
  end
  if encounter and encounter.tierId and encounter.personality and Difficulty then
    local personality=nil
    for _,p in ipairs(Difficulty.PERSONALITIES) do if p.id==encounter.personality then personality=p end end
    local tier=nil
    for _,t in ipairs(Difficulty.TIERS) do if t.id==encounter.tierId then tier=t end end
    if personality and tier then
      local Ai=req("src.battle.gen2.Ai")
      local mergedFlagNames=Difficulty.combinedGen2Flags(tier,personality)
      local mergedTier={gen2Flags=mergedFlagNames,gen2SwitchLo=tier.gen2SwitchLo,gen2SwitchHi=tier.gen2SwitchHi}
      -- baseMoney (prize payout) has no designed value yet -- 0 is a
      -- safe, honest placeholder rather than an invented number; a real
      -- balance pass owns this, same as every other TBD constant in the
      -- design doc's own "Open Balance Decisions" list.
      attributes=Difficulty.gen2Attributes(mergedTier,nil,nil,0,Ai.FLAGS)
    end
  end

  local trainer={name=name,party=lockedOpponents,attributes=attributes}
  -- Gen 2 trainers are inline rather than pre-registered.  Preserve the
  -- FinaleIntro classification fields supplied by EntryFlow before Battle.new
  -- so fight 100 reaches the same existing BossIntro classifier as Gen 1.
  if trainerMeta then
    trainer.cbeBossIntro=trainerMeta.cbeBossIntro
    trainer.cbeBossCategory=trainerMeta.cbeBossCategory
  end
  local battle=Battle.new{data=challengeData,party=clones,trainer=trainer,
    save=challengeSave,battleType=GEN2_BATTLETYPE_CANLOSE}
  battle.cbeMtBattleLevelLock=true
  battle.cbeMtBattleChallenge=true
  battle.cbeMtBattleSummitVariation=encounter and encounter.summitVariation or nil
  battle.cbeMtBattleNumber=encounter and encounter.fightIndex or nil
  attachBehaviorObserver(game,2,battle)
  return battle
end

BL._test=BL._test or {};BL._test.applyPersistentTeamState=applyPersistentTeamState
return BL
