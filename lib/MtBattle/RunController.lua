-- Mt. Battle run state machine: BEGIN CHALLENGE -> fight loop ->
-- Continue -> forfeiture/finale -> XP distribution. Owns the sequencing;
-- BattleLauncher.lua owns turning one fight into a running battle,
-- TeamGenGen1/2.lua own building one fight's roster.
local V=... or {}
local SaveState=V.MtBattleSaveState
local SeedManager=V.MtBattleSeedManager
local XPBank=V.MtBattleXPBank
local ChallengeBag=V.MtBattleChallengeBag
local Difficulty=V.MtBattleDifficulty
local AntiRepeat=V.MtBattleAntiRepeat
local TeamGenGen1=V.MtBattleTeamGenGen1
local TeamGenGen2=V.MtBattleTeamGenGen2
local AreaLeaderManager=V.MtBattleAreaLeaderManager
local RecordsManager=V.MtBattleRecordsManager
local PlayerBehaviorTracker=V.MtBattlePlayerBehaviorTracker
local LevelClone=V.MtBattleLevelClone
local Fingerprint=V.MtBattleFingerprint
local BattleData=V.MtBattleBattleData
local SummitVariation=V.MtBattleSummitVariation
local RC={}

RC.TOTAL_FIGHTS=100
RC.FIGHTS_PER_AREA=10
RC.SUPPORTED_TOTAL_FIGHTS=(SaveState and SaveState.SUPPORTED_TOTAL_FIGHTS) or {3,5,10,25,50,100}

local function normalizeTotalFights(value)
  if SaveState and type(SaveState.normalizeTotalFights)=="function" then
    return SaveState.normalizeTotalFights(value)
  end
  local n=tonumber(value)
  for _,allowed in ipairs(RC.SUPPORTED_TOTAL_FIGHTS) do
    if n==allowed then return allowed end
  end
  return RC.TOTAL_FIGHTS
end

local function supportedTotalFights(value)
  if SaveState and type(SaveState.isSupportedTotalFights)=="function" then
    return SaveState.isSupportedTotalFights(value)
  end
  local n=tonumber(value)
  for _,allowed in ipairs(RC.SUPPORTED_TOTAL_FIGHTS) do
    if n==allowed then return true end
  end
  return false
end

function RC.totalFights(gameOrSave)
  local save=gameOrSave
  if type(gameOrSave)=="table" and gameOrSave.save then save=SaveState.state(gameOrSave) end
  return normalizeTotalFights(type(save)=="table" and save.totalFights or nil)
end

-- Compress the established 1..100 difficulty envelope into shorter formats
-- without changing Battle 100 at all. Fight identity, area cadence, seeded RNG,
-- and special-fight numbering still use the real run fight index; this virtual
-- index is ONLY for selecting the existing difficulty/AI/team-quality budget.
-- That keeps a 3/5/10 battle run from being permanently stuck in T1 while its
-- last opponent still reaches the same maximum budget as Battle 100.
function RC.difficultyFightIndex(fightIndex,totalFights)
  totalFights=normalizeTotalFights(totalFights)
  fightIndex=math.max(1,math.min(totalFights,math.floor(tonumber(fightIndex) or 1)))
  if totalFights<=1 or totalFights==RC.TOTAL_FIGHTS then return fightIndex end
  return math.max(1,math.min(RC.TOTAL_FIGHTS,
    math.floor(1+((fightIndex-1)*(RC.TOTAL_FIGHTS-1))/(totalFights-1)+.5)))
end

local function areaForFight(fightIndex,totalFights)
  totalFights=normalizeTotalFights(totalFights)
  fightIndex=math.max(1,math.min(totalFights,math.floor(tonumber(fightIndex) or 1)))
  return math.floor((fightIndex-1)/RC.FIGHTS_PER_AREA)+1
end

-- Pure presentation descriptor for the pause AFTER a completed battle.  It
-- deliberately contains no generated opponent data and consumes no RNG: the
-- next encounter remains lazy until the player explicitly chooses NEXT
-- BATTLE.  Area-leader/finale context is cadence metadata, not a spoiler.
function RC.intermissionFor(completedFightIndex,totalFights)
  totalFights=normalizeTotalFights(totalFights)
  completedFightIndex=math.max(1,math.floor(tonumber(completedFightIndex) or 1))
  local complete=completedFightIndex>=totalFights
  local area=areaForFight(completedFightIndex,totalFights)
  local areaBreak=(completedFightIndex%RC.FIGHTS_PER_AREA)==0
  local nextFight
  if not complete then nextFight=completedFightIndex+1 end
  local nextIsAreaLeader=nextFight and AreaLeaderManager and AreaLeaderManager.isAreaLeader(nextFight) or false
  -- The special Colosseum-style champion/finale treatment belongs only to the
  -- compatibility Battle 100 path. A 10/50-fight run may end on an Area Leader,
  -- but that does not turn that trainer into Battle 100's finale encounter.
  local nextIsFinale=totalFights==RC.TOTAL_FIGHTS and nextFight==RC.TOTAL_FIGHTS
  return {
    kind=complete and "complete" or (areaBreak and "areaBreak" or "between"),
    result="win",completedFight=completedFightIndex,nextFight=nextFight,
    area=area,areaProgress=((completedFightIndex-1)%RC.FIGHTS_PER_AREA)+1,
    areaBreak=areaBreak,complete=complete,totalFights=totalFights,
    isFinale=complete and totalFights==RC.TOTAL_FIGHTS or false,
    nextArea=nextFight and areaForFight(nextFight,totalFights) or nil,
    nextIsAreaLeader=nextIsAreaLeader==true,nextIsFinale=nextIsFinale==true,
  }
end

-- BEGIN CHALLENGE: locks the roster, rolls the master seed (the ONLY
-- seed roll for the whole run -- see SeedManager's algorithm doc), and
-- initializes every other piece of run state fresh. `rosterSource` is
-- the array of {source=,index=}/{source=,box=,slot=} entries the
-- Team Select screen produced (Phase 4) -- stored as indices only, per
-- the schema's own rationale (never a data snapshot).
function RC.beginChallenge(game,generation,rosterSource,bagOverrides,moveOverrides,runOptions,rulesetId)
  local requestedTotal,requestedRuleset
  if type(runOptions)=="table" then
    requestedTotal=runOptions.totalFights
    if requestedTotal==nil then requestedTotal=runOptions.format end
    requestedRuleset=runOptions.rulesetId or runOptions.ruleset
  else
    requestedTotal=runOptions
  end
  if rulesetId~=nil then requestedRuleset=rulesetId end
  if requestedTotal~=nil and not supportedTotalFights(requestedTotal) then
    error("unsupported Mt. Battle format: "..tostring(requestedTotal),0)
  end
  if requestedRuleset~=nil and type(requestedRuleset)~="string" then
    error("invalid Mt. Battle ruleset id",0)
  end
  local save=SaveState.reset(game)
  save.generation=generation
  save.totalFights=normalizeTotalFights(requestedTotal)
  save.rulesetId=requestedRuleset
  -- Species availability is never tied to the host save/battle generation.
  -- Mt. Battle always draws from Gen 1 + 2 + 3 / ColosseumDex 001-386.
  save.generationPreference="all"
  save.rosterSource=rosterSource
  if LevelClone and LevelClone.snapshotRoster then
    local snapshot,why=LevelClone.snapshotRoster(game,generation,rosterSource,moveOverrides)
    if not snapshot then error("Mt. Battle roster lock failed: "..tostring(why),0) end
    save.rosterSnapshot=snapshot
  end
  if Fingerprint and type(Fingerprint.analyze)=="function" then
    save.fingerprint=Fingerprint.analyze(game and game.data or {},save.rosterSnapshot)
  end
  save.currentFight=1
  save.fightsWon=0
  save.continuesTotal=1
  save.continuesUsed=0
  save.pendingIntermission=nil
  save.lastTeamStatus={}
  save.awaitingFinale=false
  ChallengeBag.resetToDefault(game,SaveState,bagOverrides,save.totalFights)
  SeedManager.roll(game,SaveState) -- sets masterSeed, active=true
  if V.MtBattleBattlePoints then V.MtBattleBattlePoints.ensureRun(game,save) end
  -- Presentation randomness is derived up front from the ONE run seed. This is
  -- deliberately outside every fight RNG stream and is persisted, so opening an
  -- arena never consumes gameplay RNG and mobile never regenerates layouts per
  -- frame/retry/resume.
  if SummitVariation and type(SummitVariation.ensure)=="function" then
    SummitVariation.ensure(save,save.totalFights)
  end
  if RecordsManager and type(RecordsManager.recordRunStarted)=="function" then
    RecordsManager.recordRunStarted(game,save.rosterSnapshot,{
      totalFights=save.totalFights,generation=save.generation,rulesetId=save.rulesetId,
      generationPreference=save.generationPreference,
    })
  end
  return save
end

-- Builds (or returns the already-persisted) encounter for `fightIndex`.
-- Generated LAZILY, one fight ahead, and persisted verbatim the moment
-- it's built -- reload-safety rests on this being idempotent per fight
-- (see the schema's currentEncounter rationale: regenerating from the
-- seed on every load is only safe if generator code never changes
-- between save and reload, which cannot be guaranteed across a mod
-- update mid-run).
--   data: game.data
--   eligibleSpeciesIds: species pool the generator may draw from
--   adapter: optional live NativeAdapter for the dynamic move-safety check
function RC.currentEncounter(game,data,eligibleSpeciesIds,adapter)
  local save=SaveState.state(game)
  local fightIndex=save.currentFight
  local totalFights=RC.totalFights(save)
  if fightIndex>totalFights then error("Mt. Battle run is complete; no next encounter",0) end
  if save.currentEncounter and save.currentEncounter.fightIndex==fightIndex then
    if save.currentEncounter.summitVariation==nil and SummitVariation and type(SummitVariation.forSave)=="function" then
      save.currentEncounter.summitVariation=SummitVariation.forSave(save,fightIndex)
    end
    return save.currentEncounter
  end
  local subSeed=SeedManager.subSeed(save.masterSeed,fightIndex)
  local stream=SeedManager.newStream(subSeed)
  -- Area Leaders (every 10th trainer, supplemental design doc): a wider
  -- roster budget layered on the normal tier, computed fresh per call
  -- (AreaLeaderManager.applyBudget never mutates the shared Difficulty.
  -- TIERS entry -- every other fight in the same band still reads it
  -- unmodified).
  local isAreaLeader=AreaLeaderManager and AreaLeaderManager.isAreaLeader(fightIndex)
  local difficultyFightIndex=RC.difficultyFightIndex(fightIndex,totalFights)
  local tier=Difficulty.tierFor(difficultyFightIndex)
  if isAreaLeader and AreaLeaderManager then tier=AreaLeaderManager.applyBudget(tier,fightIndex) end
  local challengeData=data
  local filteredEligible=eligibleSpeciesIds
  if BattleData and type(BattleData.data)=="function" and type(BattleData.eligibleSpecies)=="function" then
    local projected=BattleData.data(game)
    local all=BattleData.eligibleSpecies(game)
    if projected and type(all)=="table" and #all>0 then
      challengeData=projected
      filteredEligible=all
    end
  end
  if #(filteredEligible or {})==0 then
    error("Mt. Battle has no source-backed eligible species",0)
  end
  local Gen=(save.generation==2) and TeamGenGen2 or TeamGenGen1
  local result=Gen.generate(stream,challengeData,save,fightIndex,tier,filteredEligible,adapter,nil,isAreaLeader)
  local encounter={fightIndex=fightIndex,difficultyFightIndex=difficultyFightIndex,subSeed=subSeed,tierId=tier.id,
    totalFights=totalFights,isRunFinal=fightIndex==totalFights,
    generationPreference=save.generationPreference,
    isFinale=totalFights==RC.TOTAL_FIGHTS and fightIndex==RC.TOTAL_FIGHTS,
    archetype=result.archetype,
    personality=result.personality,identity=result.identity,
    isAreaLeader=result.isAreaLeader,aceSlot=result.aceSlot,aceSlots=result.aceSlots,
    summitVariation=SummitVariation and type(SummitVariation.forSave)=="function" and SummitVariation.forSave(save,fightIndex) or nil,
    rows=result.rows,      -- Gen1 shape
    mons=result.mons,      -- Gen2 shape (already-constructed Mon objects)
    speciesUsed=result.speciesUsed}
  save.currentEncounter=encounter
  AntiRepeat.record(save,fightIndex,result.speciesUsed,result.archetype)
  SaveState.snapshotBag(game) -- fresh snapshot at the START of this fight
  if SaveState.snapshotTeam then SaveState.snapshotTeam(game) end
  return encounter
end

-- Computes and accrues this fight's 50% XP share for each defeated
-- opponent, then advances to the next fight. `defeatedDefs` is the array
-- of game.data.pokemon[...] species defs for every opponent that fell
-- (both gens share this shape -- baseExp lives on the species def either
-- way). Does NOT launch the next fight -- that's RunController's caller's
-- job (HubStage/BattleLauncher), this only advances bookkeeping.
-- `behaviorSummary` (optional): this fight's PlayerBehaviorTracker
-- summary, if the caller assembled one from real battle events (see
-- PlayerBehaviorTracker.lua's own scope note on that wiring).
function RC.recordWin(game,data,defeatedDefs,participants,behaviorSummary,bpEvidence)
  local save=SaveState.state(game)
  for _,def in ipairs(defeatedDefs or {}) do
    local share=XPBank.computeShare(save.generation,data,def,50,participants or 1)
    XPBank.accrue(game,SaveState,share)
  end

  -- Records: species/shininess come from the encounter about to be
  -- cleared, not from `defeatedDefs` (which is just species defs, no
  -- per-slot shiny info) -- read it BEFORE clearing currentEncounter
  -- below.
  if RecordsManager then
    local enc=save.currentEncounter
    local species,shinyFlags={},{}
    if enc then
      local slots=enc.rows or enc.mons or {}
      for i,slot in ipairs(slots) do species[i]=slot.species;shinyFlags[i]=slot.shiny end
    end
    RecordsManager.recordFightWon(game,species,shinyFlags,save.currentEncounter and save.currentEncounter.isAreaLeader,
      save.currentEncounter and save.currentEncounter.aceSlot)
  end
  if PlayerBehaviorTracker and behaviorSummary then
    PlayerBehaviorTracker.recordFight(save,behaviorSummary)
  end

  local completedFightIndex=save.currentFight
  local bpAward
  if V.MtBattleBattlePoints then
    bpAward=V.MtBattleBattlePoints.recordWin(game,save,completedFightIndex,bpEvidence)
  end
  local totalFights=RC.totalFights(save)
  save.fightsWon=save.fightsWon+1
  save.currentFight=save.currentFight+1
  save.currentEncounter=nil -- next call to currentEncounter() generates fight N+1
  save.pendingIntermission=RC.intermissionFor(completedFightIndex,totalFights)
  if type(bpAward)=="table" then save.pendingIntermission.bpAward=bpAward end

  if completedFightIndex==totalFights and RecordsManager then
    local team=nil
    if LevelClone and save.rosterSource then
      team={}
      for i,entry in ipairs(save.rosterSource) do
        local locked=save.rosterSnapshot and save.rosterSnapshot[i]
        if locked and locked.species then
          team[i]=locked.species
        else
          local mon=LevelClone.resolveSource(game,save.generation,entry)
          team[i]=mon and mon.species or nil
        end
      end
    end
    local itemsUsed=V.MtBattleChallengeBag and V.MtBattleChallengeBag.totalConsumed(game,SaveState) or nil
    -- Live PostBattleFlow appends the terminal attempt after recordWin; legacy
    -- direct callers may have already appended it. Count that win exactly once.
    local history=save.battleHistory or {}
    local last=history[#history]
    local appended=last and last.fightIndex==completedFightIndex
      and (last.result=="win" or last.result==nil)
    local attemptCount=math.max(save.fightsWon,#history+(appended and 0 or 1))
    RecordsManager.recordCompletion(game,save.continuesUsed,itemsUsed,save.xpBank,team,{
      totalFights=totalFights,generation=save.generation,rulesetId=save.rulesetId,
      fightsWon=save.fightsWon,battlesPlayed=attemptCount,
    })
  end

  return save.xpBank
end

-- A loss pauses the run on the SAME persisted encounter.  The single Continue
-- is intentionally NOT consumed here: only the player's explicit USE CONTINUE
-- action may spend it.  With none remaining the run is forfeited immediately,
-- while the failure descriptor remains available for the post-battle screen.
function RC.recordLoss(game)
  local save=SaveState.state(game)
  local fightIndex=save.currentFight
  local totalFights=RC.totalFights(save)
  local canContinue=save.continuesUsed<save.continuesTotal
  if canContinue then
    save.pendingIntermission={
      kind="continue",result="lose",completedFight=nil,nextFight=fightIndex,
      area=areaForFight(fightIndex,totalFights),areaProgress=((fightIndex-1)%RC.FIGHTS_PER_AREA)+1,
      continueAvailable=true,complete=false,totalFights=totalFights,
      nextIsAreaLeader=AreaLeaderManager and AreaLeaderManager.isAreaLeader(fightIndex) or false,
      nextIsFinale=totalFights==RC.TOTAL_FIGHTS and fightIndex==RC.TOTAL_FIGHTS,
    }
    return save.pendingIntermission
  end
  -- PostBattleFlow appends the just-finished battle attempt immediately after
  -- recordLoss returns.  Archive the failed run with that terminal attempt
  -- included, without changing explicit END RUN semantics (which calls
  -- RC.forfeit directly and therefore counts only attempts actually recorded).
  RC.forfeit(game,{battlesPlayed=#(save.battleHistory or {})+1})
  save.pendingIntermission={
    kind="failed",result="lose",completedFight=nil,nextFight=nil,
    failedFight=fightIndex,area=areaForFight(fightIndex,totalFights),
    areaProgress=((fightIndex-1)%RC.FIGHTS_PER_AREA)+1,
    continueAvailable=false,complete=false,totalFights=totalFights,
  }
  return save.pendingIntermission
end

function RC.clearIntermission(game)
  local save=SaveState.state(game)
  local previous=save.pendingIntermission
  save.pendingIntermission=nil
  return previous
end

-- A completed run hands off to the existing completion/XP layer. The durable
-- field keeps its historical `awaitingFinale` name for save compatibility; the
-- presentation layer can distinguish a true Battle 100 finale via totalFights.
-- Do not call finish() here: finish marks xpDistributed and would make the
-- actual XP Distribution commit refuse the bank.  awaitingFinale is a durable
-- boundary marker only; the accumulated bank remains locked and intact.
function RC.acknowledgeCompletion(game)
  local save=SaveState.state(game)
  if not RC.isComplete(game) then return false,"run is not complete" end
  save.pendingIntermission=nil
  save.awaitingFinale=true
  return true
end

-- A Continue is available and consumed here: `useContinue` returns true
-- and rewinds the Challenge Bag to bagSnapshot WITHOUT touching
-- currentFight/currentEncounter (the whole point: the SAME persisted
-- roster is replayed, never regenerated) if continuesUsed<continuesTotal;
-- returns false (nothing consumed) otherwise, meaning the caller must
-- call RC.forfeit instead.
function RC.useContinue(game)
  local save=SaveState.state(game)
  if save.continuesUsed>=save.continuesTotal then return false end
  save.continuesUsed=save.continuesUsed+1
  ChallengeBag.restore(game,SaveState)
  if SaveState.restoreTeam then SaveState.restoreTeam(game) end
  return true
end

function RC.hasContinueAvailable(game)
  local save=SaveState.state(game)
  return save.continuesUsed<save.continuesTotal
end

-- No continues remain and the player lost: zero the bank, end the run.
-- The entire XP bank is forfeited -- no partial payout, by design.
function RC.forfeit(game,opts)
  opts=opts or {}
  local save=SaveState.state(game)
  local forfeitedXp=save.xpBank or 0
  local itemsUsed=ChallengeBag and type(ChallengeBag.totalConsumed)=="function"
    and ChallengeBag.totalConsumed(game,SaveState) or nil
  XPBank.forfeit(game,SaveState)
  if RecordsManager then RecordsManager.recordFailure(game,save.fightsWon,{
    totalFights=RC.totalFights(save),generation=save.generation,rulesetId=save.rulesetId,
    battlesPlayed=opts.battlesPlayed~=nil and opts.battlesPlayed or #(save.battleHistory or {}),continuesUsed=save.continuesUsed,
    itemsUsed=itemsUsed,xpBank=forfeitedXp,failedFight=save.currentFight,
  }) end
  save.active=false
  return save
end

function RC.isComplete(game)
  local save=SaveState.state(game)
  return save.currentFight>RC.totalFights(save)
end

-- Final trainer defeated: the run is complete but NOT yet closed out --
-- active stays true until XPDistribution.lua (Phase 5) confirms the
-- allocation and calls RC.finish(). This window is what lets the XP
-- Distribution screen still read the bank/roster state.
function RC.finish(game)
  local save=SaveState.state(game)
  save.active=false
  save.xpDistributed=true
  save.awaitingFinale=false
  save.pendingIntermission=nil
  return save
end

return RC
