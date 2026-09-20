-- Mid-battle SUSPEND & QUIT for Mt. Battle.
--
-- An unfinished attempt is deliberately NOT a battle result.  Suspension keeps
-- currentFight/currentEncounter/XP/Continues unchanged, rewinds the Challenge
-- Bag to the fight-start snapshot, persists the active run, then tears down the
-- battle without emitting battle.ended.  Re-entry therefore rebuilds the same
-- deterministic encounter from its start instead of manufacturing a loss.
local V=... or {}
local req=V.engineRequire or require
local SaveState=V.MtBattleSaveState
local HubScreens=V.MtBattleHubScreens
local BattleRuntime=V.BattleRuntime
local BattleData=V.MtBattleBattleData
local DoublesRuntime=V.DoublesRuntime
local ColosseumMusic=V.ColosseumMusic
local SR={installed=false}

local function restoreMusic(game)
  local world=game and game.world
  if world and type(world.restoreMapMusic)=="function" then pcall(world.restoreMapMusic,world) end
  local ok,Music=pcall(req,"src.core.Music")
  if ok and Music and type(Music.restoreMap)=="function" and game and game.data then pcall(Music.restoreMap,game.data) end
  if ColosseumMusic and type(ColosseumMusic.restoreOverworldMusic)=="function" then
    pcall(ColosseumMusic.restoreOverworldMusic,game)
  end
end

local function top(game)
  local stack=game and game.stack
  return stack and type(stack.top)=="function" and stack:top() or nil
end

local function battleFor(screen,generation)
  return generation==2 and screen and screen.battle or screen
end

local function hostGameFor(screen,generation)
  local battle=battleFor(screen,generation)
  local screenGame=screen and screen.game
  return (screenGame and screenGame.__cbeMtBattleHostGame)
    or (battle and battle.game and battle.game.__cbeMtBattleHostGame)
    or screenGame
    or (battle and battle.game)
end

local function safeDecision(screen,generation)
  if not screen then return false end
  local battle=battleFor(screen,generation)
  if not (battle and battle.cbeMtBattleChallenge==true and battle.cbeMtBattleLevelLock==true) then return false end
  local doubles=DoublesRuntime and type(DoublesRuntime.session)=="function" and DoublesRuntime.session(screen) or nil
  if doubles and not doubles.closed then return doubles.core and doubles.core.phase=="command" end
  if screen.phase~="menu" then return false end
  -- Gen 1 represents a forced post-faint replacement as phase=menu just before
  -- it opens Party.  Do not claim START at that unsupported boundary.
  if generation==1 and screen.player and screen.player.mon and (tonumber(screen.player.mon.hp) or 0)<=0 then return false end
  return true
end

local function persist(game)
  if not (game and type(game.writeSave)=="function") then return false end
  local ok,written=pcall(game.writeSave,game)
  return ok and written~=false
end

local function popBattleScreen(game,screen)
  local stack=game and game.stack
  if not (stack and type(stack.top)=="function" and type(stack.pop)=="function") then return false,"state stack unavailable" end
  if stack:top()~=screen then return false,"battle screen is not active" end
  stack:pop()
  return true
end

function SR.suspend(game,screen,generation)
  generation=generation or ((screen and screen.battle) and 2 or 1)
  local battle=battleFor(screen,generation)
  local save=SaveState and SaveState.state(game)
  if not (save and save.active==true) then return false,"run is not active" end
  if not (battle and battle.cbeMtBattleChallenge==true) then return false,"not an Mt. Battle fight" end
  if battle.__cbeMtBattlePostHandled then return false,"battle result already committed" end
  if battle.__cbeMtBattleSuspended then return false,"battle already suspended" end
  local stack=game and game.stack
  if not (stack and type(stack.top)=="function" and type(stack.pop)=="function") then return false,"state stack unavailable" end
  if stack:top()~=screen then return false,"battle screen is not active" end

  -- Save the in-memory bag in case the disk write is vetoed/fails. A suspended
  -- attempt is discarded, so item consumption from it must rewind just like a
  -- Continue retry, but without spending the Continue itself.
  local liveBag=save.bag
  SaveState.restoreBag(game)
  if not SaveState.pauseSession(game,persist) then
    save.bag=liveBag
    return false,"save write failed"
  end

  -- Late native events from this discarded attempt are not an earned result.
  battle.__cbeMtBattleSuspended=true
  screen.__cbeMtBattleSuspended=true
  local detach=battle.__cbeMtBattleDetachObserver
  battle.__cbeMtBattleDetachObserver=nil
  if type(detach)=="function" then pcall(detach) end

  local doubles=DoublesRuntime and type(DoublesRuntime.session)=="function" and DoublesRuntime.session(screen) or nil
  if doubles and not doubles.closed and type(DoublesRuntime.abort)=="function" then pcall(DoublesRuntime.abort,doubles) end

  local restoreFinale=battle.__cbeMtBattleRestoreFinalePrefs
  battle.__cbeMtBattleRestoreFinalePrefs=nil
  if type(restoreFinale)=="function" then pcall(restoreFinale) end

  -- Close CBE presentation before popping so the overlay never leaves camera,
  -- arena or MoveFX ownership behind. No battle.ended is emitted here.
  if BattleRuntime and type(BattleRuntime.closeWithoutResult)=="function" then
    pcall(BattleRuntime.closeWithoutResult,battle,"mt-battle-suspended")
  end

  -- Gen 2's ordinary result path performs these screen-local teardown steps in
  -- finishBattle(). Suspension must not call finishBattle itself (that would
  -- invoke onDone/result processing), but it still has to silence the low-HP
  -- alarm, clear battle cursors, and discard volatile state on the challenge
  -- clones before the view is popped. Gen 1 owns equivalent cleanup in
  -- BattleState:exit(), which StateStack:pop invokes below.
  if generation==2 then
    if type(screen.stopAlarm)=="function" then pcall(screen.stopAlarm,screen) end
    if type(screen.clearMenuCursors)=="function" then pcall(screen.clearMenuCursors,screen) end
    if battle and type(battle.clearAllVolatiles)=="function" then pcall(battle.clearAllVolatiles,battle) end
  end
  local ok,why=popBattleScreen(game,screen)
  if not ok then return false,why end
  if BattleData and type(BattleData.restoreHostTypes)=="function" then pcall(BattleData.restoreHostTypes,battle) end
  restoreMusic(game)
  return true
end

function SR.open(game,screen,generation)
  if game.__cbeMtBattleSuspendOpen then return true end
  if not safeDecision(screen,generation) then return false end
  local save=SaveState.state(game)
  game.__cbeMtBattleSuspendOpen=true
  HubScreens.pushSuspendRunConfirm(game,{
    fight=save.currentFight,totalFights=save.totalFights,
    onConfirm=function()
      game.__cbeMtBattleSuspendOpen=nil
      return SR.suspend(game,screen,generation)
    end,
    onCancel=function() game.__cbeMtBattleSuspendOpen=nil end,
  })
  return true
end

function SR.install(mod)
  if SR.installed then return true end
  mod=mod or V.mod
  local generation=(V.GenerationCompat and V.GenerationCompat.current and V.GenerationCompat.current()) or 1
  local class=req(generation==2 and "src.ui.battle.BattleState" or "src.battle.BattleState")
  local old=class and class.update
  if type(old)~="function" then return false,"battle update unavailable" end
  SR.updateWrapper=function(screen,dt,...)
    local input=screen and screen.game and screen.game.input
    if input and type(input.wasPressed)=="function" and input:wasPressed("start")
        and safeDecision(screen,generation) then
      if SR.open(hostGameFor(screen,generation),screen,generation) then return end
    end
    return old(screen,dt,...)
  end
  class.update=SR.updateWrapper
  SR.installed=true
  return true
end

SR._test={safeDecision=safeDecision,battleFor=battleFor,hostGameFor=hostGameFor}
return SR
