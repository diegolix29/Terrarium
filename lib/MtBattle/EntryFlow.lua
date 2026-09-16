-- Mt. Battle 100 entry flow: the real glue between OverworldGate's talk
-- trigger and everything else already built (HubStage, HubScreens,
-- RunController, BattleLauncher).
--
-- Both host generations share the same setup contract: THE CLIMB -> Team Review
-- (challenge-local MOVE PREP + the host's native PC screen + RENTAL TEAM) ->
-- START CHALLENGE for the prepared live party or the selected rental six. The
-- host generation still selects the battle kernel only at launch time below;
-- exposing the same setup features does not project Gen-1 mechanics onto Gen 2
-- or vice versa.
local V=... or {}
local req=V.engineRequire or require
local HubStage=V.MtBattleHubStage
local HubScreens=V.MtBattleHubScreens
local RunController=V.MtBattleRunController
local BattleLauncher=V.MtBattleBattleLauncher
local RentalPool=V.MtBattleRentalPool
local MovePrep=V.MtBattleMovePrep
local TrainerPoolG1=V.MtBattleTrainerPoolG1
local SaveState=V.MtBattleSaveState
local GenerationCompat=V.GenerationCompat
local ColosseumMusic=V.ColosseumMusic
local EF={}
local sessions=setmetatable({},{__mode="k"})

-- Do not treat every game.ready value as a usable live Game. Some entry paths
-- can retain an old/incomplete reference. In particular, a Gen-1 overworld
-- controller keeps its Game in a module upvalue, not necessarily self.game.
-- OverworldGate observes the real input.step game BEFORE the NPC can be used.
-- Never invent a StateStack or transplant one onto a snapshot: the entire hub,
-- its save writes and the native battle must share the real owner.
local observedGame,observedStack,observedSave=nil,nil,nil
local contextEpoch=0
EF.BUILD_TAG="MTB ENTRY FIX 1"

local function screenStack(game)
  if type(game)~="table" then return nil end
  local stack=game.stack
  if type(stack)~="table" or type(stack.push)~="function"
      or type(stack.pop)~="function" or type(stack.top)~="function" then return nil end
  return stack
end

function EF.observeGame(game)
  local stack=screenStack(game)
  local live=stack and game or nil
  local save=live and live.save or nil
  if live~=observedGame or stack~=observedStack or save~=observedSave then
    contextEpoch=contextEpoch+1
  end
  observedGame,observedStack,observedSave=live,stack,save
  return observedGame
end

function EF.resolveGame(game,overworld)
  if screenStack(game) then return game end
  local owner=type(overworld)=="table" and overworld.game or nil
  if screenStack(owner) then return owner end
  if screenStack(observedGame) then return observedGame end
  local live=V.mod and V.mod.game
  if screenStack(live) then return live end
  return nil,"Mt. Battle needs the live game's screen stack; leave the dialogue and try the NPC again."
end

local function entryDiagnostic(why)
  EF.lastEntryError=tostring(why)
  local log=V.mod and V.mod.log
  if log and type(log.warn)=="function" then
    pcall(log.warn,log,"%s: %s",EF.BUILD_TAG,EF.lastEntryError)
  end
  return false,EF.lastEntryError
end

local function sessionFor(game)
  local s=sessions[game]
  if not s then
    s={trainerModel="wes",launching=false,selectedFormat=100,generationPreference="all",selectedRoster=nil}
    sessions[game]=s
  end
  return s
end

local function saveNow(game)
  if game and type(game.writeSave)=="function" then
    -- A host save writer may report a handled I/O failure by returning false
    -- rather than throwing.  Treat that as a real failure so Mt. Battle never
    -- tells the player an active run is durable when the host rejected the
    -- write.  nil/no explicit return remains the normal successful host shape.
    local ok,written=pcall(game.writeSave,game)
    return ok and written~=false
  end
  return false
end

local function playLobby(game)
  if ColosseumMusic and type(ColosseumMusic.playMtBattleLobby)=="function" then
    pcall(ColosseumMusic.playMtBattleLobby,game)
  end
end

local function beginHubBeat(game,label)
  local s=sessionFor(game)
  if HubStage and type(HubStage.beginBeat)=="function" then
    pcall(HubStage.beginBeat,game,s.trainerModel or "wes",label or "MT. BATTLE")
  end
  playLobby(game)
end

local function endHub(game,reason)
  HubStage.endSession(reason)
  if ColosseumMusic and type(ColosseumMusic.restoreOverworldMusic)=="function" then
    pcall(ColosseumMusic.restoreOverworldMusic,game)
  end
end

-- Resolves each of a locked roster's eligible SPECIES ids (for the
-- generator's eligible-species pool) from game.data.pokemon, excluding
-- the FIXMON-style test-fixture/incomplete entries the same way
-- RosterCore.pickSpecies already screens for (baseStats+types present).
local function allEligibleSpecies(data)
  local out={}
  for id,def in pairs((data and data.pokemon) or {}) do
    if def and def.baseStats and def.types then out[#out+1]=id end
  end
  table.sort(out)
  return out
end

local function fallbackInfo(game,text,onDone)
  local stack=screenStack(game)
  if not stack then return entryDiagnostic("Mt. Battle dialogue owner is no longer active.") end
  local TextBox=req("src.render.TextBox")
  stack:push(TextBox.new(game,text,onDone))
  return true
end

local function showFightBriefing(game,encounter,onStart,onSuspend)
  local n=encounter and encounter.fightIndex or SaveState.state(game).currentFight
  local area=math.max(1,math.ceil((tonumber(n) or 1)/10))
  beginHubBeat(game,"BATTLE "..tostring(n))
  if HubScreens and type(HubScreens.pushFightBriefing)=="function" then
    return HubScreens.pushFightBriefing(game,encounter,onStart,onSuspend)
  end
  fallbackInfo(game,("MT. BATTLE AREA %d\nBATTLE %d\n\nA  ENTER BATTLE"):format(area,n),onStart)
end

local function challengeItemSave(game,battle)
  local live=game and game.save or {}
  local state=SaveState.state(game)
  -- Battle-item code expects a save-shaped table. Keep the Challenge Bag and
  -- clone party local to the run while inheriting read-only identity/options
  -- fields from the real save. Nothing here replaces game.save itself.
  local proxy={
    inventory=state.bag,
    party=(battle and (battle.playerParty or battle.party)) or {},
    player=live.player,
    bagOrder={},
  }
  return setmetatable(proxy,{__index=live})
end

local function pushGen1Battle(game,battle,encounter)
  battle.cbeMtBattleChallenge=true
  endHub(game,"battle-launch")
  local ok,why
  if BattleLauncher and type(BattleLauncher.activateGen1)=="function" then
    ok,why=BattleLauncher.activateGen1(game,battle)
  else
    ok,why=pcall(game.stack.push,game.stack,battle)
  end
  if not ok then
    sessionFor(game).launching=false
    beginHubBeat(game,"BATTLE ERROR")
    fallbackInfo(game,"MT. BATTLE could not enter this fight.\n\n"..tostring(why or "unknown activation error"))
    return nil,why
  end
  sessionFor(game).launching=false
  return battle
end

local function pushGen2Battle(game,battle,encounter)
  battle.cbeMtBattleChallenge=true
  local Screens=req("src.ui.Screens")
  local world=game and game.world
  local screen
  local function finish(result)
    if screen and game.stack and game.stack.top and game.stack:top()==screen then
      game.stack:pop()
    end
    if world and type(world.restoreMapMusic)=="function" then
      pcall(world.restoreMapMusic,world)
    end
  end
  local function pushView()
    screen=Screens.push(game,"Gen2BattleState",{
      battle=battle,save=game.save,onDone=finish,
      music={trainer=battle.trainer},
    })
    -- Gold/Crystal hosts can emit battle.started with the view rather than the
    -- underlying Battle model. Mirror challenge identity onto that view at the
    -- construction boundary so arena forcing survives either event shape.
    if type(screen)=="table" then
      screen.__cbeGeneration=2
      screen.cbeMtBattleChallenge=true
      screen.cbeMtBattleLevelLock=battle.cbeMtBattleLevelLock
      screen.cbeMtBattleNumber=battle.cbeMtBattleNumber
      screen.cbeMtBattleSummitVariation=battle.cbeMtBattleSummitVariation
    end
  end
  endHub(game,"battle-launch")
  if world and type(world.playBattleMusic)=="function" then
    pcall(world.playBattleMusic,world,{trainer=battle.trainer,battleType="canlose"})
  end
  if world and type(world.pushBattleTransition)=="function" then
    local environment=world.map and world.map.def and world.map.def.environment
    local ok=world:pushBattleTransition(battle,{
      trainer=true,environment=environment,
      playerLevel=battle.player and battle.player.level,
      enemyLevel=battle.enemy and battle.enemy.level,
    },pushView)
    if ok then sessionFor(game).launching=false;return battle end
  end
  pushView()
  sessionFor(game).launching=false
  return battle
end

local function buildAndPushBattle(game,save,encounter)
  local battle,err
  local finale=V.MtBattleFinaleIntro
  local fightIndex=tonumber(encounter and encounter.fightIndex) or tonumber(save.currentFight) or 1
  local isFinale=fightIndex==100
  local restoreFinale
  if isFinale and finale and type(finale.forceBossIntro)=="function" then
    restoreFinale=finale.forceBossIntro(game)
  end
  if save.generation==2 then
    local trainerMeta={name=(encounter.identity and encounter.identity.name) or "MT. BATTLE"}
    if isFinale and finale and type(finale.gen2TrainerMeta)=="function" then
      trainerMeta=finale.gen2TrainerMeta(trainerMeta)
    end
    battle,err=BattleLauncher.launchGen2(game,save.rosterSource,encounter.mons,trainerMeta,encounter)
  else
    battle,err=BattleLauncher.launchGen1(game,save.currentFight,save.rosterSource,encounter)
  end
  if not battle then
    if restoreFinale then pcall(restoreFinale) end
    sessionFor(game).launching=false
    beginHubBeat(game,"BATTLE ERROR")
    fallbackInfo(game,"MT. BATTLE could not start this fight.\n\n"..tostring(err or "unknown launch error"))
    return nil,err
  end
  battle.__cbeMtBattleItemSave=challengeItemSave(game,battle)
  battle.__cbeMtBattleRestoreFinalePrefs=restoreFinale
  local pushed,why
  if save.generation==2 then pushed,why=pushGen2Battle(game,battle,encounter)
  else pushed,why=pushGen1Battle(game,battle,encounter) end
  if not pushed and restoreFinale then
    battle.__cbeMtBattleRestoreFinalePrefs=nil
    pcall(restoreFinale)
  end
  return pushed,why
end

-- Launches fight `fightIndex` of an already-BEGIN-CHALLENGE'd run: builds
-- the encounter, launches the real battle for the save's generation, and
-- lets StandaloneHost auto-attach to it via the engine's own
-- battle.started event (BattleRuntime.lua, unchanged, no Mt.-Battle-
-- specific code needed there -- confirmed in the plan's Phase 0 findings).
function EF.launchFight(game,opts)
  opts=opts or {}
  local save=SaveState.state(game)
  if not save.active then return nil,"challenge is not active" end
  if RunController.isComplete(game) then return nil,"challenge is complete" end
  local s=sessionFor(game)
  if s.launching then return nil,"fight launch already in progress" end
  SaveState.enterSession(game)
  s.launching=true
  local function failLaunch(err)
    s.launching=false
    beginHubBeat(game,"BATTLE ERROR")
    fallbackInfo(game,"MT. BATTLE could not start this fight.\n\n"..tostring(err or "unknown launch error"))
    return nil,err
  end
  local data=game.data
  local adapter=nil -- live NativeAdapter instance, when Mt. Battle's own
                     -- doubles-kernel wiring is attached in a later pass
  local generated,encounter=pcall(RunController.currentEncounter,game,data,allEligibleSpecies(data),adapter)
  if not generated then return failLaunch(encounter) end
  saveNow(game)
  local function launch()
    local ok,a,b=pcall(buildAndPushBattle,game,save,encounter)
    if not ok then return failLaunch(a) end
    return a,b
  end
  if opts.skipBriefing then return launch() end
  local function suspendBeforeBattle()
    local paused,why=SaveState.pauseSession(game,saveNow)
    if not paused then return false,why end
    s.launching=false
    endHub(game,"resume-later")
    return true
  end
  local shown,a=pcall(showFightBriefing,game,encounter,launch,suspendBeforeBattle)
  if not shown then return failLaunch(a) end
  return true,encounter
end

-- BEGIN CHALLENGE confirmed: locks the roster, rolls the seed, then
-- launches fight 1 immediately.
local function beginAndLaunch(game,rosterSource,closeSetup,moveOverrides,totalFights)
  local generation=(GenerationCompat and GenerationCompat.current()) or 1
  if TrainerPoolG1 and TrainerPoolG1.setRosterProvider and generation==1 then
    -- Gen 1's roster provider reads whatever RunController most recently
    -- persisted for the CURRENT fight -- a thin closure over `game` is
    -- enough since TrainerPoolG1.rosterProvider is called synchronously,
    -- inside BattleLauncher.launchGen1's own BattleState.newTrainer call,
    -- always for the fight BattleLauncher is launching right now.
    TrainerPoolG1.setRosterProvider(function(fightIndex)
      local save=SaveState.state(game)
      local enc=save.currentEncounter
      if enc and enc.fightIndex==fightIndex then return enc.rows end
      return nil
    end)
  end
  totalFights=tonumber(totalFights) or tonumber(sessionFor(game).selectedFormat) or 100
  -- Mt. Battle always keeps the complete source-backed Gen 1 + 2 + 3 pool
  -- active. Generation tabs in the rental builder are browse categories only;
  -- no setup/UI state may narrow encounter generation eligibility.
  sessionFor(game).generationPreference="all"
  local runOptions={totalFights=totalFights,generationPreference="all"}
  local ok,why=pcall(RunController.beginChallenge,game,generation,rosterSource,nil,moveOverrides,runOptions)
  if not ok then
    sessionFor(game).launching=false
    if SaveState and SaveState.reset then SaveState.reset(game) end
    fallbackInfo(game,"MT. BATTLE could not lock this team.\n\n"..tostring(why or "unknown roster error"))
    return nil,why
  end
  -- Team Review uses keepOpen so MOVE PREP/PC can return to it. Once the run has
  -- actually locked successfully it must be removed before the fight briefing
  -- (or battle transition) is pushed; otherwise it would remain underneath and
  -- resurface after the fight.
  if type(closeSetup)=="function" then closeSetup() end
  -- The run becomes durable at the lock boundary, before Battle 1 construction.
  -- A technical launch failure must leave this active state resumable rather
  -- than silently erasing the player's selected six and deterministic seed.
  saveNow(game)
  local launched,a,b=pcall(EF.launchFight,game)
  if not launched or a==nil then
    sessionFor(game).launching=false
    local err=launched and b or a
    saveNow(game)
    fallbackInfo(game,"MT. BATTLE could not start Battle 1.\n\n"..tostring(err or "unknown launch error"))
    return nil,err
  end
  return a,b
end

local function currentPartyRoster(game)
  local party=game and game.save and game.save.party or {}
  local ready=#party==6
  for _,mon in ipairs(party) do
    if mon and mon.isEgg then ready=false end
  end
  if not ready then return nil,nil,"current party is not an eligible six" end
  local rosterSource={}
  for i=1,6 do rosterSource[i]={source="party",index=i,species=party[i].species} end
  return rosterSource,party
end

-- Once the player confirms the mixed/rental builder or loads a saved custom
-- team, that exact six is the setup session's source of truth. Do not silently
-- fall back to save.party if one of its owned source slots later changes; doing
-- so is how a rental selection used to launch the unrelated overworld party.
local function setupRoster(game)
  local s=sessionFor(game)
  if type(s.selectedRoster)=="table" then
    if #s.selectedRoster~=6 then return nil,nil,"selected team is not exactly six" end
    if MovePrep and type(MovePrep.rosterTeam)=="function" then
      local team,why=MovePrep.rosterTeam(game,s.selectedRoster)
      if not team then return nil,nil,why end
      return s.selectedRoster,team
    end
    return s.selectedRoster,s.selectedRoster
  end
  return currentPartyRoster(game)
end

local function bindMovePrep(game,rosterSource)
  local s=sessionFor(game);s.movePrep=s.movePrep or {}
  if MovePrep and type(MovePrep.bindRoster)=="function" then
    local prepared,ok,why=MovePrep.bindRoster(game,s.movePrep,rosterSource)
    s.movePrep=prepared or s.movePrep
    if not ok then return false,why end
  end
  return true
end

-- START CHALLENGE always consumes the exact setup roster. With no explicit
-- selection this is the current live party; after rentals/custom LOAD it is the
-- detached selected six. `closeSelf` is called only after RunController has
-- successfully frozen that source into rosterSnapshot.
local function validateAndStartPreparedTeam(game,closeSelf,totalFights)
  local rosterSource,_,why=setupRoster(game)
  if not rosterSource then
    fallbackInfo(game,"Your MT. BATTLE team isn't ready.\n\nBring/select exactly 6 POKeMON, then try START CHALLENGE again.")
    return nil,why
  end
  local bound,boundWhy=bindMovePrep(game,rosterSource)
  if not bound then
    fallbackInfo(game,"Your selected MT. BATTLE team changed.\n\nRebuild or reload the team before starting.")
    return nil,boundWhy
  end
  local prep=sessionFor(game).movePrep
  local overrides=(MovePrep and type(MovePrep.challengeOverrides)=="function")
    and MovePrep.challengeOverrides(game,prep,rosterSource) or nil
  return beginAndLaunch(game,rosterSource,closeSelf,overrides,totalFights)
end

local function openMovePrep(game)
  local rosterSource,_,why=setupRoster(game)
  if not rosterSource then
    fallbackInfo(game,"MOVE PREP requires exactly six selected POKeMON.\n\nUse BUILD CHALLENGE TEAM or CUSTOM TEAMS first.")
    return false,why or "team is not an eligible six"
  end
  if not (HubScreens and type(HubScreens.pushMovePrep)=="function") then
    return false,"move prep screen unavailable"
  end
  local bound,boundWhy=bindMovePrep(game,rosterSource)
  if not bound then return false,boundWhy end
  local s=sessionFor(game)
  return HubScreens.pushMovePrep(game,s.movePrep,function(prepared) s.movePrep=prepared or s.movePrep end)
end

-- Read owned Pokemon in stable physical-slot order. Both host generations
-- persist party/boxes here. Do not run BoxMenu/Boxes.ensure, move a Pokemon,
-- deduplicate species, or project rentals into the native save while browsing.
-- Numeric-key iteration also keeps occupied slots after a hole in a box/party.
local function occupiedSlots(rows)
  local indices={}
  for i,mon in pairs(type(rows)=="table" and rows or {}) do
    if type(i)=="number" and i>=1 and i==math.floor(i) and type(mon)=="table" then
      indices[#indices+1]=i
    end
  end
  table.sort(indices)
  return indices
end

local function ownedCandidates(game)
  local save=game and game.save or {}
  local candidates={}
  local function add(mon,row)
    if not mon or not mon.species then return end
    row.species=mon.species;row.name=mon.nickname or mon.name;row.level=mon.level
    row.selectable=not mon.isEgg
    row.disabledReason=mon.isEgg and "EGG / Cannot enter Mt. Battle until hatched" or nil
    candidates[#candidates+1]=row
  end
  local party=save.party or {}
  for _,i in ipairs(occupiedSlots(party)) do add(party[i],{source="party",index=i}) end
  local boxes=save.boxes or {}
  for _,b in ipairs(occupiedSlots(boxes)) do
    for _,slot in ipairs(occupiedSlots(boxes[b])) do
      add(boxes[b][slot],{source="pc",box=b,slot=slot})
    end
  end
  return candidates
end

local function openRentalSelect(game,closeSelf,totalFights)
  local rentals=RentalPool and type(RentalPool.candidates)=="function" and RentalPool.candidates(game) or {}
  -- OWNED contains the whole party + all stored boxes. Rental rows/order and
  -- their existing generation tabs remain untouched; the six picks are global.
  local candidates=ownedCandidates(game)
  for _,row in ipairs(rentals or {}) do candidates[#candidates+1]=row end
  local eligible=0
  for _,row in ipairs(candidates) do if row.selectable~=false then eligible=eligible+1 end end
  if eligible<6 then
    fallbackInfo(game,"MT. BATTLE team builder is unavailable.\n\nAt least six eligible owned or rental POKeMON are required.")
    return false,"not enough eligible candidates"
  end
  HubScreens.pushTeamSelect(game,candidates,function(rosterSource)
    local s=sessionFor(game)
    s.selectedRoster=rosterSource
    bindMovePrep(game,rosterSource)
    -- Selection returns to Team Review. MOVE PREP and CUSTOM TEAMS now operate
    -- on these exact six; START CHALLENGE is the only action that locks/launches.
  end,function() end,totalFights)
  return true
end

local function openCustomTeams(game)
  if not (HubScreens and type(HubScreens.pushCustomTeams)=="function" and SaveState
      and type(SaveState.customTeams)=="function") then
    return false,"custom teams unavailable"
  end
  local s=sessionFor(game)
  return HubScreens.pushCustomTeams(game,{
    teams=function() return SaveState.customTeams(game) end,
    onSave=function()
      local rosterSource,_,why=setupRoster(game)
      if not rosterSource then return false,why or "select exactly six Pokemon first" end
      local bound,boundWhy=bindMovePrep(game,rosterSource)
      if not bound then return false,boundWhy end
      if not (MovePrep and type(MovePrep.customRoster)=="function") then return false,"custom roster projection unavailable" end
      local rows,rowWhy=MovePrep.customRoster(game,s.movePrep,rosterSource)
      if not rows then return false,rowWhy end
      local entry,saveWhy=SaveState.saveCustomTeam(game,rows)
      if not entry then return false,saveWhy end
      if not saveNow(game) then
        SaveState.deleteCustomTeam(game,entry.id)
        return false,"save write failed"
      end
      return true,entry.name
    end,
    onLoad=function(id)
      local rows,entry=SaveState.loadCustomTeam(game,id)
      if not rows then return false,entry end
      s.selectedRoster=rows
      s.movePrep={}
      local bound,boundWhy=bindMovePrep(game,rows)
      if not bound then s.selectedRoster=nil;return false,boundWhy end
      return true,entry and entry.name
    end,
    onDelete=function(id)
      local ok,detail=SaveState.deleteCustomTeam(game,id)
      if not ok then return false,detail end
      if not saveNow(game) then
        if type(SaveState.restoreCustomTeam)=="function" then SaveState.restoreCustomTeam(game,detail) end
        return false,"save write failed"
      end
      return true,detail and detail.name
    end,
  })
end

local function openTeamReview(game,totalFights)
  totalFights=tonumber(totalFights) or tonumber(sessionFor(game).selectedFormat) or 100
  sessionFor(game).selectedFormat=totalFights
  local generation=(GenerationCompat and GenerationCompat.current()) or 1
  HubScreens.pushTeamReview(game,{
    totalFights=totalFights,generation=generation,
    onSave=function() return saveNow(game) end,
    teamProvider=function() local _,team=setupRoster(game);return team end,
    onStart=function(closeSelf) validateAndStartPreparedTeam(game,closeSelf,totalFights) end,
    onMovePrep=function() openMovePrep(game) end,
    onRental=function(closeSelf) openRentalSelect(game,closeSelf,totalFights) end,
    onCustomTeams=function() openCustomTeams(game) end,
    onCancel=function() endHub(game,"player-cancelled") end,
  })
end

-- ===== VR headset / cache-install flavor gate (explicit user request):
-- a themed pre-hub confirmation sequence using this engine's real
-- dialogue primitives (src.render.TextBox + src.ui.ChoiceBox -- the same
-- TextBox-then-ChoiceBox chaining pattern data/scripts/safari.lua's own
-- SAFARI_ZONE_GATE worker prompt and yellow_beach_house.lua's SURF offer
-- both already use). This is presentation only, not a new mechanical
-- system: declining either prompt just closes the dialogue and leaves
-- the player on the overworld; confirming both proceeds into the exact
-- same EF.start() hub entry this module already had. The second YES now
-- invokes BattleCache.openMtBattle: Gen 1 verifies/prepares Johto + Hoenn
-- model units, while Gen 2 verifies/prepares Hoenn. Existing valid disk
-- caches are reused, and the hub does not open until that pass completes. =====
function EF.showOffer(game,trainerModel)
  local resolved,why=EF.resolveGame(game)
  if not resolved then return entryDiagnostic(why) end
  game=resolved
  EF.observeGame(game)
  local epoch=contextEpoch
  local stack=screenStack(game)
  local save=game.save
  local sess=sessionFor(game)
  local top=stack:top()
  if sess.offerToken and top and top.__cbeMtBattleOfferToken==sess.offerToken then
    return true,"offer already open"
  end
  local token={}
  sess.offerToken=token
  EF.lastEntryError=nil
  local TextBox=req("src.render.TextBox")
  local ChoiceBox=req("src.ui.ChoiceBox")

  -- Text/choice/cache completion is asynchronous. Never reopen a hub against
  -- another save, a replaced stack, or a game that was exited while preparing.
  -- A new offer also invalidates every callback retained by the preceding one.
  local function current()
    return sess.offerToken==token and screenStack(game)==stack and game.save==save
      and contextEpoch==epoch and observedGame==game
  end
  local function finish()
    if sess.offerToken==token then sess.offerToken=nil end
  end
  local function pushText(text,onDone)
    if not current() then finish();return false,"entry context changed" end
    local callback=onDone and function()
      if not current() then finish();return end
      return onDone()
    end
    local state=TextBox.new(game,text,callback)
    state.__cbeMtBattleOfferToken=token
    stack:push(state)
    return true
  end
  local function pushChoice(onDone)
    if not current() then finish();return false,"entry context changed" end
    local state=ChoiceBox.new(game,function(yes)
      if not current() then finish();return end
      return onDone(yes)
    end)
    state.__cbeMtBattleOfferToken=token
    stack:push(state)
    return true
  end
  local function decline(text)
    local ok,detail=pushText(text)
    finish()
    return ok,detail
  end
  local function enterHub()
    if not current() then finish();return false,"entry context changed" end
    finish()
    local ok,detail=EF.start(game,trainerModel)
    if not ok then
      entryDiagnostic(detail or "Mt. Battle hub could not open.")
      fallbackInfo(game,"MT. BATTLE could not open.\n\n"..tostring(detail or "Please try again."))
    end
    return ok,detail
  end

  local function installCache()
    return pushText("Installing MT. BATTLE\ncache...",function()
      local cache=V.BattleCache
      if cache and type(cache.openMtBattle)=="function" then
        local ok,detail=cache.openMtBattle(game,enterHub)
        if not ok then
          entryDiagnostic(detail or "cache state unavailable")
          decline("MT. BATTLE cache couldn't\nstart. Close other cache\nwork and try again.")
        end
        return
      end
      -- Compatibility fallback only when the cache service is not installed;
      -- a real cache failure never counts as successful preparation.
      return enterHub()
    end)
  end

  local function confirmInstall()
    return pushText("This'll install the MT.\nBATTLE cache onto your\nsystem. Continue?",function()
      return pushChoice(function(yes)
        if yes then return installCache() end
        return decline("OK, maybe next time.")
      end)
    end)
  end

  return pushText("Hey kid, just got this\nnew VR headset from the\nORRE region. Wanna try\nit out?",function()
    return pushChoice(function(yes)
      if yes then return confirmInstall() end
      return decline("Oh well, some other\ntime then.")
    end)
  end)
end

-- The real entry point: called once the player has confirmed the VR
-- headset offer above (or directly, for callers that want to skip the
-- flavor gate). Enters the shared hub presentation on the Mt. Battle Summit.
-- The setup path is generation-neutral; the launch path keeps the native host
-- battle-kernel split documented above.
-- `trainerModel`: which 3D model (Wes/Red) the hub NPC/host presents as.
function EF.start(game,trainerModel)
  local resolved,why=EF.resolveGame(game)
  if not resolved then return entryDiagnostic(why) end
  game=resolved
  if not (HubStage and HubScreens and RunController) then return false,"not fully wired" end
  EF.observeGame(game)
  local sess=sessionFor(game)
  sess.offerToken=nil
  local existing=SaveState and type(SaveState.state)=="function" and SaveState.state(game) or nil
  sess.trainerModel=trainerModel or "wes"
  sess.launching=false
  sess.movePrep={}
  sess.selectedRoster=nil
  sess.selectedFormat=(existing and existing.active and existing.totalFights) or 100
  sess.generationPreference="all"
  local ok,why=HubStage.beginBeat(game,trainerModel,"MT. BATTLE")
  if not ok then return false,why end

  -- Retail source distinction: the Battle 100 setup hub deliberately uses
  -- bgm_archive.fsys/worldmap_song (setup 5), the Colosseum main-menu sequence,
  -- not mt_battle_song or pokecen_song. Keep this explicit so the
  -- optional Pokemon Center replacement and battle soundtrack stay isolated.
  playLobby(game)

  -- Re-entering Mt. Battle never starts a fresh setup over an active run. A
  -- persisted intermission/finale is reopened through the existing post-battle
  -- state machine; otherwise the already-locked current fight is resumed through
  -- the normal host-specific launch path. No roster, seed, Continue, or XP state
  -- is reset merely because the player left the hub or restarted the game.
  if existing and existing.active==true then
    local post=V.MtBattlePostBattleFlow
    local hasPostBoundary=type(existing.pendingIntermission)=="table"
      or existing.awaitingFinale==true or existing.finaleCompletePending==true
    local function resumeActiveRun()
      SaveState.enterSession(game)
      if hasPostBoundary then
        if not (post and type(post.pump)=="function") then
          return false,"Mt. Battle resume boundary unavailable"
        end
        local resumed,detail=post.pump(game)
        if resumed then return true,"resumed" end
        return false,detail or "Mt. Battle intermission could not resume"
      end
      local resumed,detail=EF.launchFight(game)
      if resumed then return true,"resumed" end
      return false,detail or "Mt. Battle fight could not resume"
    end
    local function suspendActiveRun()
      -- At this boundary no battle attempt is running, so suspension is only a
      -- durable save + hub exit. Do not clear currentEncounter, spend Continue,
      -- zero XP, or route through RunController.forfeit.
      local paused,why=SaveState.pauseSession(game,saveNow)
      if not paused then return false,why end
      sess.launching=false
      game.__cbeMtBattleIntermissionOpen=nil
      endHub(game,"resume-later")
      return true
    end
    local function endActiveRun()
      -- END RUN remains the destructive path and is invoked only after
      -- HubScreens' explicit confirmation. Reuse PostBattleFlow's established
      -- forfeiture/records teardown where available.
      if post and type(post.endRun)=="function" then return post.endRun(game) end
      return false,"Mt. Battle end-run controller unavailable"
    end
    if type(HubScreens.pushActiveRunControl)=="function" then
      HubScreens.pushActiveRunControl(game,{
        onResume=resumeActiveRun,onSuspend=suspendActiveRun,onEndRun=endActiveRun,
      })
      return true,"active-run-control"
    end
    -- A stripped control screen must not silently force an active challenge.
    endHub(game,"resume-controls-unavailable")
    return false,"Mt. Battle resume controls unavailable"
  end

  if type(HubScreens.pushClimbSetup)=="function" then
    HubScreens.pushClimbSetup(game,{
      totalFights=sess.selectedFormat,
      onSave=function() return saveNow(game) end,
      onFormatChanged=function(total) sess.selectedFormat=total end,
      onTeamSetup=function(total)
        sess.selectedFormat=total
        sess.generationPreference="all"
        openTeamReview(game,total)
      end,
      onCancel=function() endHub(game,"player-cancelled") end,
    })
    return true
  end

  -- Compatibility fallback for older/stripped HubScreens implementations.
  HubScreens.pushInfoScreen(game,function() openTeamReview(game,100) end,{kind="rules"})
  return true
end

EF._test={ownedCandidates=ownedCandidates,openRentalSelect=openRentalSelect}
return EF
