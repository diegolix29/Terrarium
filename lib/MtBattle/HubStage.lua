-- Mt. Battle 100 3D hub rendering vehicle: drives StandaloneHost across
-- the offer/prep/team-select/rules/bag-review/BEGIN CHALLENGE beats (and
-- the between-fight beats) using a hand-built, battle-shaped placeholder
-- table -- StandaloneHost.H.begin only needs battle.game/kind/oppClass/
-- player/enemy to be present (lib/StandaloneHost.lua:67-85 contextFor,
-- confirmed by direct read in Phase 0 Spike 2). The real GPU/mesh/shader
-- path beyond that point has no headless test anywhere in this codebase's
-- history (tests/BossIntroCueTests.lua:10 stubs StandaloneHost entirely
-- rather than exercising it) -- this module follows that same established
-- convention: StandaloneHost is an INJECTED dependency (V.StandaloneHost),
-- so a test can substitute a lightweight stand-in exactly like
-- BossIntroCueTests does, and real device verification remains the only
-- way to confirm actual on-screen rendering, same as every other
-- presentation feature this mod has ever shipped.
local V=... or {}
local HS={}
local SaveState=V.MtBattleSaveState
local SummitVariation=V.MtBattleSummitVariation
local GenerationCompat=V.GenerationCompat

local function standaloneHost() return V.StandaloneHost end

-- StandaloneHost.lua returns its host table directly. Early Mt. Battle
-- headless tests wrapped their stub as {H={...}}, which masked the live
-- interface and caused `host.H.begin` to crash on device. Accept the real
-- flat API first, while retaining the nested form as a compatibility shim
-- for older tests/third-party injectors.
local function hostApi()
  local host=standaloneHost()
  if type(host)~="table" then return nil end
  if type(host.begin)=="function" or type(host.finish)=="function" then return host end
  if type(host.H)=="table" then return host.H end
  return nil
end

-- Forces mt_battle_summit + doubles-enabled for the run's duration,
-- returning a restore() closure that puts the player's real preferences
-- back exactly as they were. Mirrors lib/BattleSettings.lua's prefs()
-- idiom (read-modify-write the live game.save.colosseumBattle table)
-- rather than reimplementing preference storage.
function HS.forcePresentation(game)
  local prefs=game and game.save and game.save.colosseumBattle
  if type(prefs)~="table" then
    game.save=game.save or {}
    prefs={}
    game.save.colosseumBattle=prefs
  end
  local original={arena=prefs.arena,doubleBattlesEnabled=prefs.doubleBattlesEnabled,
    arenasEnabled=prefs.arenasEnabled}
  prefs.arena="mt_battle_summit"
  prefs.doubleBattlesEnabled=true
  prefs.arenasEnabled=true
  return function()
    prefs.arena=original.arena
    prefs.doubleBattlesEnabled=original.doubleBattlesEnabled
    prefs.arenasEnabled=original.arenasEnabled
  end
end

-- Builds the minimal battle-shaped placeholder StandaloneHost.contextFor
-- needs. `trainerModel` selects the Wes/Red 3D model (TrainerRoster's
-- existing model catalog owns the actual resolution -- this just carries
-- the identifying field a real trainer battle's `trainer` table would
-- have, per BossIntro.lua's own classify() precedent of reading
-- trainer.* fields).
function HS.placeholderBattle(game,trainerModel,label)
  local variation,number
  local generation=tonumber(game and game.save and game.save.generation)
  if GenerationCompat and type(GenerationCompat.current)=="function" then
    local ok,value=pcall(GenerationCompat.current)
    if ok and tonumber(value) then generation=tonumber(value) end
  end
  generation=generation or 1
  local save=SaveState and type(SaveState.state)=="function" and SaveState.state(game)
    or (game and game.save and game.save.mtBattleChallenge)
  if save and save.active==true and SummitVariation and type(SummitVariation.forSave)=="function" then
    number=math.max(1,math.min(math.floor(tonumber(save.totalFights) or 100),math.floor(tonumber(save.currentFight) or 1)))
    variation=SummitVariation.forSave(save,number)
  end
  return {
    game=game,kind="trainer",oppClass="MTB_HUB",
    trainer={name=label or "MT. BATTLE",cbeBossIntro=false,playerModel=trainerModel},
    player=nil,enemy=nil, -- StandaloneHost's contextFor tolerates absent battlers for a non-combat scene
    __mtbHub=true,__cbeGeneration=generation,
    cbeMtBattleSummitVariation=variation,cbeMtBattleNumber=number,
  }
end

-- Begins (or replaces) the hub's 3D presentation session for one beat.
-- Returns true/false,reason -- same contract as StandaloneHost.H.begin.
function HS.beginBeat(game,trainerModel,label)
  local host=hostApi()
  if not (host and type(host.begin)=="function") then return false,"StandaloneHost.begin unavailable" end
  return host.begin(HS.placeholderBattle(game,trainerModel,label))
end

-- Ends the hub's presentation session, e.g. when handing off to a real
-- fight's own battle.started event (StandaloneHost.H.begin already calls
-- H.finish("replaced") internally on the next begin, so this is only
-- needed when the hub session must end with NOTHING taking over, e.g.
-- the player backs out to the overworld before BEGIN CHALLENGE).
function HS.endSession(reason)
  local host=hostApi()
  if host and type(host.finish)=="function" then host.finish(reason or "hub-closed") end
end

return HS
