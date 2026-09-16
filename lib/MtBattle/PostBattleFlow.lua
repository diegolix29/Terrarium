-- Mt. Battle 100 post-battle orchestration.
--
-- battle.ended is the authoritative result boundary, but it is NOT a safe UI
-- boundary on either engine generation: Gen 1 still pushes BattleReturn after
-- emitting it, while Gen 2 emits it before the battle screen/evolutions have
-- fully drained.  This module therefore commits only run bookkeeping on the
-- event and leaves a persisted pendingIntermission descriptor. BattleRuntime
-- calls pump() later, once a stable overworld frame is back on top.
local V=... or {}
local SaveState=V.MtBattleSaveState
local RunController=V.MtBattleRunController
local RecordsManager=V.MtBattleRecordsManager
local HubStage=V.MtBattleHubStage
local HubScreens=V.MtBattleHubScreens
local ColosseumMusic=V.ColosseumMusic
local XPDistribution=V.MtBattleXPDistribution
local BattleData=V.MtBattleBattleData
local req=V.engineRequire or require
local PF={installed=false,mod=nil}

local function shallowCopy(t)
  local out={}
  for k,v in pairs(t or {}) do out[k]=v end
  return out
end

local function deepCopy(v)
  if type(v)~="table" then return v end
  local out={};for k,x in pairs(v) do out[k]=deepCopy(x) end;return out
end
local function restoreTable(target,snapshot)
  for k in pairs(target) do target[k]=nil end
  for k,v in pairs(snapshot) do target[k]=v end
end

local function numeric(v,default)
  v=tonumber(v)
  if not v then return default or 0 end
  return v
end

local function teamStatus(battle,game)
  local model=(battle and battle._model) or battle
  local party=(model and model.playerParty) or (model and model.party) or {}
  game=game or (battle and battle.game)
  local data=(model and model.data) or (battle and battle.data)
    or (BattleData and type(BattleData.data)=="function" and BattleData.data(game))
    or (game and game.data) or {}
  local moveDefs=data.moves or {}
  local out={}
  for i=1,6 do
    local mon=party[i]
    if mon then
      local hp=math.max(0,numeric(mon.hp,0))
      local maxHp=numeric(mon.maxHp or mon.maxHP,0)
      if maxHp<=0 and type(mon.stats)=="table" then maxHp=numeric(mon.stats.hp,0) end
      if maxHp<=0 then maxHp=math.max(1,hp) end
      local rawStatus=mon.status
      if type(rawStatus)=="table" then rawStatus=rawStatus.id or rawStatus.name end
      local status=rawStatus and tostring(rawStatus) or nil
      local moves={}
      for j,mv in ipairs(type(mon.moves)=="table" and mon.moves or {}) do
        local id=type(mv)=="table" and mv.id or mv
        local def=id and moveDefs and moveDefs[id] or nil
        local base=tonumber(def and def.pp) or 0
        local pp=type(mv)=="table" and tonumber(mv.pp) or base
        local maxPp,ups
        if SaveState and type(SaveState.movePPLimit)=="function" then
          maxPp,ups=SaveState.movePPLimit(mv,data)
        else
          ups=math.max(0,math.min(3,math.floor(type(mv)=="table" and (tonumber(mv.ppUps) or 0) or 0)))
          maxPp=type(mv)=="table" and tonumber(mv.maxPp or mv.maxPP) or nil
          if not maxPp or maxPp<=0 then maxPp=base+ups*math.floor(base/5) end
        end
        maxPp=math.max(0,math.floor(maxPp or 0))
        moves[j]={id=id,pp=math.max(0,math.min(maxPp,math.floor(pp or maxPp))),
          ppUps=ups or 0,maxPp=maxPp,maxPP=maxPp}
      end
      out[i]={species=mon.species,nickname=mon.nickname,hp=hp,maxHp=maxHp,
        hpPercent=math.max(0,math.min(100,math.floor((hp/maxHp)*100+.5))),
        status=status,fainted=hp<=0,moves=moves}
    end
  end
  return out
end

local function defeatedDefs(game,encounter)
  local out={}
  local data=(BattleData and type(BattleData.data)=="function" and BattleData.data(game))
    or (game and game.data)
  local pokemon=data and data.pokemon or {}
  for _,slot in ipairs((encounter and (encounter.rows or encounter.mons)) or {}) do
    local species=type(slot)=="table" and slot.species or nil
    local def=species and pokemon[species] or nil
    if def then out[#out+1]=def end
  end
  return out
end

local function gameFor(battle,payload)
  local battleGame=battle and battle.game
  return (battleGame and battleGame.__cbeMtBattleHostGame) or battleGame or (payload and payload.game)
    or (PF.mod and PF.mod.game) or (V.mod and V.mod.game)
end

local function persist(game)
  if game and type(game.writeSave)=="function" then
    -- Some hosts signal a failed save with a false return instead of raising.
    -- Do not collapse that into pcall success: SAVE/EXIT must keep the active
    -- run/intermission open until the durable write actually succeeds.
    local ok,written=pcall(game.writeSave,game)
    return ok and written~=false
  end
  return false
end

local function speciesLabel(game,mon)
  local id=mon and mon.species
  local def=id and game and game.data and game.data.pokemon and game.data.pokemon[id]
  return tostring((mon and mon.nickname) or (def and def.name) or id or "POKéMON")
end

-- Real reward recipients, never challenge clones/rentals. Keep party first,
-- then PC boxes in stable box/slot order. We intentionally read the save's
-- existing box tables instead of calling creation helpers: opening the finale
-- must not mutate empty PC storage just to enumerate it.
local function eligibleOwnedMons(game,generation)
  local save=game and game.save or {};local out={};local seen={}
  local function add(mon,prefix)
    if type(mon)~="table" or mon.isEgg or seen[mon] then return end
    seen[mon]=true
    out[#out+1]={mon=mon,label=tostring(prefix).."  "..speciesLabel(game,mon)}
  end
  local function occupied(rows)
    local ids={}
    for i,mon in pairs(type(rows)=="table" and rows or {}) do
      if type(i)=="number" and i>=1 and i==math.floor(i) and type(mon)=="table" then ids[#ids+1]=i end
    end
    table.sort(ids);return ids
  end
  for _,i in ipairs(occupied(save.party)) do add(save.party[i],"PARTY "..tostring(i)) end
  local boxes=type(save.boxes)=="table" and save.boxes or {}
  local boxCount=generation==2 and 14 or 12
  local moduleName=generation==2 and "src.core.gen2.Boxes" or "src.pokemon.Boxes"
  local okBoxes,Boxes=pcall(req,moduleName)
  if okBoxes and type(Boxes)=="table" then
    boxCount=tonumber(Boxes.NUM_BOXES or Boxes.COUNT) or boxCount
  end
  for b=1,boxCount do
    for _,slot in ipairs(occupied(boxes[b])) do
      add(boxes[b][slot],"BOX "..tostring(b).."/"..tostring(slot))
    end
  end
  return out
end

local function finaleModel(game)
  local save=SaveState.state(game)
  local run=(RecordsManager and type(RecordsManager.currentRun)=="function" and RecordsManager.currentRun(game)) or {}
  local summary=(RecordsManager and type(RecordsManager.summary)=="function" and RecordsManager.summary(game)) or {}
  return {
    xpBank=save.xpBank or 0,continuesUsed=save.continuesUsed or 0,
    bp=V.MtBattleBattlePoints and V.MtBattleBattlePoints.summary(game) or nil,
    totalFights=save.totalFights or run.totalFights or 100,
    run=run,summary=summary,team=run.roster or save.rosterSnapshot or {},
  }
end

-- Commit one real Mt. Battle result exactly once.  The level-lock marker is
-- written only by MtBattle/BattleLauncher, so ordinary trainer/wild battles
-- cannot enter this state machine even while a stale challenge save exists.
function PF.onBattleEnded(payload)
  local battle=type(payload)=="table" and payload.battle or nil
  if not (battle and battle.cbeMtBattleLevelLock==true) then return false,"not-mt-battle" end
  local native=battle._model or battle
  if battle.__cbeMtBattlePostHandled or native.__cbeMtBattlePostHandled then return false,"already-handled" end
  if battle.__cbeMtBattleSuspended or native.__cbeMtBattleSuspended then return false,"suspended-attempt" end
  local game=gameFor(battle,payload)
  if not (game and SaveState and RunController) then return false,"missing-game-or-controller" end
  local owner=battle.__cbeMtBattleBPOwnerSave or native.__cbeMtBattleBPOwnerSave
  if owner and owner~=game.save then return false,"stale-battle-save" end
  local save=SaveState.state(game)
  if save.active~=true then return false,"run-not-active" end
  local encounter=save.currentEncounter
  if not (encounter and encounter.fightIndex==save.currentFight) then
    return false,"encounter-mismatch"
  end

  local number=battle.cbeMtBattleNumber or native.cbeMtBattleNumber
  if number~=nil and number~=save.currentFight then return false,"stale-battle-fight" end
  local runId=battle.__cbeMtBattleBPRunId or native.__cbeMtBattleBPRunId
  if runId~=nil and runId~=save.bpRunId then return false,"stale-battle-run" end
  local attempt=battle.__cbeMtBattleBPAttempt or native.__cbeMtBattleBPAttempt
  if attempt~=nil and attempt~=(tonumber((save.attemptsByFight or {})[save.currentFight]) or 0)+1 then
    return false,"stale-battle-attempt"
  end
  local result=tostring(payload.result or payload.outcome or "")
  if result~="win" and result~="lose" then return false,"unsupported-result" end
  battle.__cbeMtBattlePostHandled=true;native.__cbeMtBattlePostHandled=true
  SaveState.enterSession(game) -- this result belongs to an explicitly played fight
  -- Fight 100 temporarily forces the existing Colosseum BossIntro preference
  -- on during construction/entry.  Restore the user's real setting at the
  -- authoritative battle result boundary, regardless of win/loss.
  local restoreFinale=battle.__cbeMtBattleRestoreFinalePrefs
  battle.__cbeMtBattleRestoreFinalePrefs=nil
  if type(restoreFinale)=="function" then pcall(restoreFinale) end
  save.lastTeamStatus=teamStatus(battle,game)

  if result=="win" then
    -- The bank represents half of the fight's eligible trainer-battle XP.
    -- RunController's existing tests and contract use the unshared (one
    -- participant) basis for that locked bank; distribution happens only after
    -- the complete climb and never mutates these battle clones.
    local challengeData=(BattleData and type(BattleData.data)=="function" and BattleData.data(game)) or game.data
    local evidence
    if V.MtBattleBattlePoints then
      local clean,reason=V.MtBattleBattlePoints.cleanWin(battle,save.lastTeamStatus)
      evidence={clean=clean,reason=reason}
    end
    RunController.recordWin(game,challengeData,defeatedDefs(game,encounter),1,nil,evidence)
  else
    RunController.recordLoss(game)
  end
  if RecordsManager and type(RecordsManager.recordBattleAttempt)=="function" then
    local playerKOs=battle.__cbeMtBattlePlayerKnockouts or native.__cbeMtBattlePlayerKnockouts
    if type(playerKOs)~="table" then
      playerKOs={}
      for i,row in ipairs(save.lastTeamStatus or {}) do
        if row.fainted then
          playerKOs[#playerKOs+1]={species=row.species,nickname=row.nickname,partyIndex=i}
        end
      end
    end
    RecordsManager.recordBattleAttempt(game,encounter,result,{
      playerKnockouts=playerKOs,
      enemyKnockouts=battle.__cbeMtBattleEnemyKnockouts or native.__cbeMtBattleEnemyKnockouts or {},
      bpAward=result=="win" and save.pendingIntermission and save.pendingIntermission.bpAward or nil,
      bpBalance=V.MtBattleBattlePoints and V.MtBattleBattlePoints.state(game).balance or 0,
    })
  end
  return true,SaveState.state(game).pendingIntermission
end

local function contextLabel(pending)
  if not pending or not pending.nextFight then return "" end
  if pending.nextIsFinale then return "FINAL AREA LEADER" end
  if pending.nextIsAreaLeader then return "AREA LEADER" end
  return "MT. BATTLE TRAINER"
end

function PF.viewModel(game,pending)
  if type(SaveState.repairTeamPP)=="function" then
    local data=(BattleData and type(BattleData.data)=="function" and BattleData.data(game)) or (game and game.data)
    SaveState.repairTeamPP(game,data)
  end
  local save=SaveState.state(game)
  pending=pending or save.pendingIntermission or {}
  local action="NEXT BATTLE"
  if pending.kind=="areaBreak" then action="CONTINUE"
  elseif pending.kind=="continue" then action="USE CONTINUE"
  elseif pending.kind=="failed" then action="RETURN"
  elseif pending.kind=="complete" then action="RESULTS" end
  return {
    kind=pending.kind or "between",result=pending.result,
    completedFight=pending.completedFight,failedFight=pending.failedFight,
    nextFight=pending.nextFight,area=pending.area or 1,
    areaProgress=pending.areaProgress or 0,areaBreak=pending.areaBreak==true,
    complete=pending.complete==true,nextIsAreaLeader=pending.nextIsAreaLeader==true,
    nextIsFinale=pending.nextIsFinale==true,nextContext=contextLabel(pending),
    fightsWon=save.fightsWon or 0,currentFight=save.currentFight or 1,
    totalFights=save.totalFights or RunController.TOTAL_FIGHTS or 100,
    continuesUsed=save.continuesUsed or 0,continuesTotal=save.continuesTotal or 1,
    continuesRemaining=math.max(0,(save.continuesTotal or 1)-(save.continuesUsed or 0)),
    xpBank=save.xpBank or 0,bag=shallowCopy(save.bag),
    bp=V.MtBattleBattlePoints and V.MtBattleBattlePoints.summary(game) or nil,
    bpAward=pending.bpAward,
    teamStatus=save.lastTeamStatus or {},action=action,itemUseAllowed=(pending.kind=="between" or pending.kind=="areaBreak"),
  }
end

local function endHub(game,reason)
  if HubStage and type(HubStage.endSession)=="function" then
    pcall(HubStage.endSession,reason)
  end
  if ColosseumMusic and type(ColosseumMusic.restoreOverworldMusic)=="function" then
    pcall(ColosseumMusic.restoreOverworldMusic,game)
  end
end

function PF.saveProgress(game)
  if not (game and SaveState) then return false,"save unavailable" end
  if not persist(game) then return false,"save write failed" end
  return true
end

-- Leaving an intermission is a pause, never an abandon. Keep every run field
-- and the persisted intermission descriptor intact so the next Mt. Battle entry
-- can reopen the same deterministic boundary.
function PF.leaveActiveRun(game)
  local save=SaveState.state(game)
  if save.active~=true then return false,"run is not active" end
  local paused,why=SaveState.pauseSession(game,persist)
  if not paused then return false,why end
  game.__cbeMtBattleIntermissionOpen=nil
  endHub(game,"resume-later")
  return true
end

-- This is the ONLY UI-driven abandon path. HubScreens places a dedicated
-- confirmation in front of it, so ordinary B/back/save actions never forfeit.
function PF.endRun(game)
  local save=SaveState.state(game)
  if save.active~=true then return false,"run is not active" end
  local before=deepCopy(save)
  local records=game.save.mtBattleRecords;local beforeRecords=deepCopy(records)
  RunController.forfeit(game)
  RunController.clearIntermission(game)
  if not persist(game) then
    restoreTable(save,before)
    if type(records)=="table" then restoreTable(records,beforeRecords);game.save.mtBattleRecords=records
    else game.save.mtBattleRecords=beforeRecords end
    return false,"save write failed - run not ended"
  end
  game.__cbeMtBattleIntermissionOpen=nil
  endHub(game,"user-ended-run")
  return true
end

local function stackTop(game)
  local stack=game and game.stack
  if stack and type(stack.top)=="function" then
    local ok,value=pcall(stack.top,stack);if ok then return value end
  end
  return nil
end

local function beginFinaleBeat(game,label)
  local save=SaveState.state(game)
  local total=save.totalFights or 100
  if HubStage and type(HubStage.beginBeat)=="function" then
    pcall(HubStage.beginBeat,game,"wes",label or ("MT. BATTLE "..tostring(total)))
  end
  if ColosseumMusic and type(ColosseumMusic.playMtBattleLobby)=="function" then
    pcall(ColosseumMusic.playMtBattleLobby,game)
  end
end

local function openFinaleComplete(game)
  local save=SaveState.state(game)
  if save.finaleCompletePending~=true then return false,"completion receipt not pending" end
  if game.__cbeMtBattleFinaleOpen then return false,"finale already open" end
  if not (HubScreens and type(HubScreens.pushFinaleComplete)=="function") then return false,"finale completion screen unavailable" end
  game.__cbeMtBattleFinaleOpen=true
  beginFinaleBeat(game,"MT. BATTLE "..tostring(save.totalFights or 100).." COMPLETE")
  local model={applied=save.finaleXpResults or {},totalFights=save.totalFights or 100,
    summary=RecordsManager and RecordsManager.summary and RecordsManager.summary(game) or {}}
  local state=HubScreens.pushFinaleComplete(game,model,function()
    local current=SaveState.state(game)
    current.finaleCompletePending=false
    if not persist(game) then
      current.finaleCompletePending=true
      return false,"SAVE FAILED - RECEIPT RETAINED"
    end
    game.__cbeMtBattleFinaleOpen=nil
    game.__cbeMtBattleFinaleCompleteState=nil
    game.__cbeMtBattleXPState=nil
    endHub(game,"challenge-complete")
  end)
  game.__cbeMtBattleFinaleCompleteState=state
  return true,state
end

local function openXPDistribution(game)
  if not (XPDistribution and XPDistribution.State and type(XPDistribution.State.new)=="function") then
    return false,"XP distribution unavailable"
  end
  if not (HubScreens and type(HubScreens.pushXPDistribution)=="function") then return false,"XP screen unavailable" end
  if game.__cbeMtBattleXPScreen then return true,game.__cbeMtBattleXPScreen end
  local save=SaveState.state(game)
  local xpState=game.__cbeMtBattleXPState
  if not xpState then
    xpState=XPDistribution.State.new(game,save.generation or 1,game.data,eligibleOwnedMons(game,save.generation or 1))
    game.__cbeMtBattleXPState=xpState
  end
  local screen
  screen=HubScreens.pushXPDistribution(game,xpState,function(state)
    -- A save refusal after native XP application retries the WRITE, not the XP
    -- award/events. The same allocation state retains its exact receipt and is
    -- locked against edits until saving succeeds.
    local applied,why=state.__cbeMtBattleAppliedReceipt,nil
    if not applied then applied,why=state:commit() end
    if not applied then return false,why end
    state.__cbeMtBattleAppliedReceipt=applied
    local current=SaveState.state(game)
    current.finaleXpResults=applied
    current.finaleCompletePending=true
    if not persist(game) then return false,"SAVE FAILED - START RETRIES SAVE; XP WILL NOT REPEAT" end
    game.__cbeMtBattleXPScreen=nil

    -- The XP screen popped itself before this callback. Under ordinary engine
    -- behavior the summary is now top and can be replaced immediately. If a
    -- level-up listener inserted another native screen, leave the durable
    -- receipt marker in place; the summary auto-retires when it resurfaces and
    -- the stable-overworld pump will present the completion receipt afterward.
    local summary=game.__cbeMtBattleFinaleSummaryState
    if summary and stackTop(game)==summary then
      game.stack:pop()
      game.__cbeMtBattleFinaleSummaryState=nil
      game.__cbeMtBattleFinaleOpen=nil
      openFinaleComplete(game)
    else
      game.__cbeMtBattleFinaleOpen=nil
    end
    return true
  end,function()
    game.__cbeMtBattleXPScreen=nil
  end)
  game.__cbeMtBattleXPScreen=screen
  return true,screen
end

function PF.openFinale(game)
  local save=SaveState.state(game)
  if save.finaleCompletePending==true then return openFinaleComplete(game) end
  if save.awaitingFinale~=true then return false,"finale not pending" end
  if game.__cbeMtBattleFinaleOpen then return true,game.__cbeMtBattleFinaleSummaryState end
  if not (HubScreens and type(HubScreens.pushFinaleSummary)=="function") then return false,"finale summary unavailable" end
  game.__cbeMtBattleFinaleOpen=true
  beginFinaleBeat(game,"MT. BATTLE "..tostring(save.totalFights or 100).." CHAMPION")
  local summary
  summary=HubScreens.pushFinaleSummary(game,finaleModel(game),function()
    local ok,why=openXPDistribution(game)
    return ok,why
  end)
  game.__cbeMtBattleFinaleSummaryState=summary
  return true,summary
end

local function launchPendingFight(game,pending,useContinue)
  local save=SaveState.state(game)
  -- Treat a technical launch refusal as non-destructive.  The player's one
  -- Continue is an explicit gameplay resource, so a missing screen/provider or
  -- failed transition must not spend it before the retry has actually entered
  -- the launch path successfully.
  local beforeContinues=save.continuesUsed
  local beforeBag=useContinue and shallowCopy(save.bag) or nil
  local beforeTeam=useContinue and SaveState.copyTeamStatus(save.lastTeamStatus) or nil
  if useContinue and not RunController.useContinue(game) then return false,"continue unavailable" end
  save.pendingIntermission=nil
  game.__cbeMtBattleIntermissionOpen=nil
  if HubStage and type(HubStage.endSession)=="function" then
    pcall(HubStage.endSession,"next-battle")
  end
  local EntryFlow=V.MtBattleEntryFlow
  if not (EntryFlow and type(EntryFlow.launchFight)=="function") then
    if useContinue then save.continuesUsed=beforeContinues;save.bag=beforeBag;save.lastTeamStatus=beforeTeam end
    save.pendingIntermission=pending
    return false,"battle launch unavailable"
  end
  -- Battle 1 deliberately owns EntryFlow's separate pre-fight briefing.  Every
  -- later fight has already been presented by this Summit/Wes intermission, so
  -- NEXT BATTLE should enter the fight rather than stacking a second pause.
  local called,battle,why=pcall(EntryFlow.launchFight,game,{skipBriefing=true})
  if not called then
    why=battle
    battle=nil
  end
  if battle==nil or battle==false then
    -- Keep the deterministic pause recoverable instead of silently falling
    -- through to the overworld. A later stable frame will reopen it.
    if useContinue then save.continuesUsed=beforeContinues;save.bag=beforeBag;save.lastTeamStatus=beforeTeam end
    save.pendingIntermission=pending
    return false,why or "battle launch failed"
  end
  return true,battle
end

function PF.advance(game)
  local save=SaveState.state(game)
  local pending=save.pendingIntermission
  if type(pending)~="table" then
    game.__cbeMtBattleIntermissionOpen=nil
    return false,"no pending intermission"
  end

  -- Do not leave a reward boundary (or spend a Continue) with an unsaved result.
  if (pending.kind=="between" or pending.kind=="areaBreak" or pending.kind=="continue")
      and not persist(game) then return false,"SAVE FAILED - RESULT RETAINED; RETRY" end
  if pending.kind=="between" or pending.kind=="areaBreak" then
    return launchPendingFight(game,pending,false)
  elseif pending.kind=="continue" then
    return launchPendingFight(game,pending,true)
  elseif pending.kind=="complete" then
    local beforeAwaiting=save.awaitingFinale
    local ok,why=RunController.acknowledgeCompletion(game)
    if not ok then return false,why end
    if not persist(game) then
      save.pendingIntermission=pending;save.awaitingFinale=beforeAwaiting
      return false,"SAVE FAILED - FINALE NOT ADVANCED"
    end
    game.__cbeMtBattleIntermissionOpen=nil
    -- Do not end the Summit host here. Battle 100 now has a real durable
    -- results -> XP allocation -> completion sequence. If the presentation
    -- cannot open on this exact frame, awaitingFinale remains persisted and
    -- pump() will retry it at the next stable-overworld boundary.
    local opened=PF.openFinale(game)
    return true,opened and "finale" or "finale-pending"
  elseif pending.kind=="failed" then
    RunController.clearIntermission(game)
    if not persist(game) then save.pendingIntermission=pending;return false,"SAVE FAILED - RESULT RETAINED" end
    game.__cbeMtBattleIntermissionOpen=nil
    endHub(game,"challenge-failed")
    return true,"failed"
  end
  return false,"unknown intermission kind"
end

-- Called only from BattleRuntime's stable-overworld work seam. Starting the
-- Summit host here (rather than in battle.ended) preserves the last battle
-- frame through Gen 1 BattleReturn and through Gen 2's native result/evolution
-- teardown.
function PF.pump(game)
  if not (game and SaveState and HubScreens and type(HubScreens.pushChallengeIntermission)=="function") then
    return false
  end
  local save=SaveState.state(game)
  -- The stable-overworld pump runs EVERY FRAME. A pending descriptor is not
  -- permission to reopen after B/QUIT; explicit suspension must survive both
  -- subsequent frames and a full process restart.
  if save.suspended==true then return false end
  if save.active==true and not SaveState.sessionEngaged(game) then
    -- Old saves and interrupted runs have no in-process session. Show the
    -- shared RESUME / RETURN TO OVERWORLD / END RUN choice, never auto-launch.
    local entry=V.MtBattleEntryFlow
    if entry and type(entry.start)=="function" then
      return entry.start(game,"wes")
    end
    return false,"resume controls unavailable"
  end
  if save.finaleCompletePending==true then
    if game.__cbeMtBattleFinaleOpen then return false end
    return openFinaleComplete(game)
  end
  if save.awaitingFinale==true then
    if game.__cbeMtBattleFinaleOpen then return false end
    return PF.openFinale(game)
  end
  local pending=save.pendingIntermission
  if type(pending)~="table" or game.__cbeMtBattleIntermissionOpen then return false end

  -- Commit the result-side pause only after the native battle teardown is over.
  -- EntryFlow already saves again when NEXT BATTLE generates/loads the next
  -- encounter; this write is what makes a reload *during* the intermission
  -- resume the same deterministic boundary instead of reverting to the battle.
  local saved=persist(game)
  game.__cbeMtBattleIntermissionOpen=true
  local label=pending.kind=="complete" and ("MT. BATTLE "..tostring(save.totalFights or pending.totalFights or 100).." CLEAR")
    or (pending.kind=="areaBreak" and ("AREA "..tostring(pending.area).." CLEAR"))
    or "MT. BATTLE"
  if HubStage and type(HubStage.beginBeat)=="function" then
    pcall(HubStage.beginBeat,game,"wes",label)
  end
  if ColosseumMusic and type(ColosseumMusic.playMtBattleLobby)=="function" then
    pcall(ColosseumMusic.playMtBattleLobby,game)
  end
  local model=PF.viewModel(game,pending)
  model.saveError=not saved and "SAVE FAILED - REWARDS IN MEMORY; START RETRIES SAVE" or nil
  HubScreens.pushChallengeIntermission(game,model,function()
    local ok,why=PF.advance(game)
    if ok==false then game.__cbeMtBattleIntermissionOpen=true end
    return ok,why
  end,{
    onSave=function() return PF.saveProgress(game) end,
    onExit=function() return PF.leaveActiveRun(game) end,
    onEndRun=function() return PF.endRun(game) end,
  })
  return true,model
end

function PF.install(mod)
  if PF.installed then return true end
  PF.mod=mod or V.mod
  local events=PF.mod and PF.mod.events
  if not (events and type(events.on)=="function") then return false,"events unavailable" end
  events:on("battle.ended",function(payload) PF.onBattleEnded(payload) end)
  PF.installed=true
  return true
end

function PF.status(game)
  local save=SaveState and SaveState.state(game or (PF.mod and PF.mod.game)) or nil
  return {installed=PF.installed,pending=save and save.pendingIntermission or nil,
    awaitingFinale=save and save.awaitingFinale==true or false}
end

PF._test={teamStatus=teamStatus,defeatedDefs=defeatedDefs,contextLabel=contextLabel,
  eligibleOwnedMons=eligibleOwnedMons,finaleModel=finaleModel}
return PF
