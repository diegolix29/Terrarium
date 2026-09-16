local C={}

-- Arena selection stays centralized in this module. The
-- StadiumBattleFX provider is acquired once per battle; the selected id is
-- resolved here before any cache is loaded and is then stamped onto the arena
-- record for that battle.  No later render/update call is allowed to choose a
-- different environment.
local runtimeSelected=nil
-- Explicit menu choices are staged for the NEXT arena acquisition. This is
-- separate from the save object because Gen1Recomp can hand providers a battle
-- context whose game/save reference was captured before the BATTLE overlay wrote
-- the new value. A staged manual choice must win exactly once.
local pendingSelected=nil
local boundBattle=nil
local boundSelected=nil
local boundResolved=nil
local lastRandomResolved=nil
local primedRandom=nil

local DEFINITIONS={
  water={
    id="water",label="WATER COLOSSEUM",cache="cache/M1_water_cache.lua",ready=true,
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=1100,maxGroupSpanRaw=2600,vertexRadiusRaw=1050,
    pokemon={player={0,14.5},enemy={0,-14.5}},figureScale=0.40,trainers={player={13.2,25.8},enemy={-13.2,-25.8}},trainerScale={player=0.425,enemy=0.205},
    camera={side=54,back=13,height=27,lookX=0,lookY=6.1,frameH=47,safe={minRadius=26,maxRadius=76,minY=6.5,maxY=39,maxPitch=31,minPitch=-10,minFov=31,maxFov=53}},
    backdrop={top={0.025,0.075,0.145},bottom={0.13,0.25,0.34}},profile="water",crowd="source-hsd-exact",
  },
  open_water={
    id="open_water",label="ORRE OPEN SEA",cache="cache/open_water_cache.lua",ready=true,
    -- Original water-route composition using retail GC6E01 Water Colosseum
    -- water/stone plus Mt. Battle volcanic rock.  Geometry stays authored like
    -- Wildlands; source pixels/material behavior stay Colosseum-native.
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=6400,maxGroupSpanRaw=13200,vertexRadiusRaw=6300,
    pokemon={player={-4.8,17.5},enemy={4.8,-17.5}},figureScale=0.36,
    trainers={player={14.0,29.0},enemy={-14.0,-29.0}},trainerScale={player=0.425,enemy=0.205},
    camera={side=61,back=18,height=25.5,lookX=0,lookY=5.7,frameH=50,
      safe={minRadius=29,maxRadius=88,minY=7,maxY=39,maxPitch=29,minPitch=-10,minFov=31,maxFov=54}},
    backdrop={top={0.008,0.026,0.082},bottom={0.145,0.245,0.335}},profile="open_water",crowd="none",
  },
  orre_colosseum={
    id="orre_colosseum",label="ORRE COLOSSEUM",cache="cache/orre_colosseum_cache.lua",ready=true,
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=3200,maxGroupSpanRaw=7200,vertexRadiusRaw=3100,
    pokemon={player={-4.4,16.8},enemy={4.4,-16.8}},figureScale=0.335,trainers={player={10.8,24.8},enemy={-10.8,-24.8}},trainerScale={player=0.405,enemy=0.198},
    -- The authored rock perimeter intersects the old radius-58.5 orbit near
    -- the west camera. Keep the lens inside the battle bowl so the native rock
    -- remains background scenery; preserve the floor, stands and battler marks.
    camera={side=46,back=14,height=23,lookX=0,lookY=7.0,frameH=50,shotRadiusScale=0.82,
      safe={minRadius=28,maxRadius=55,minY=7.0,maxY=36,maxPitch=29,minPitch=-9,minFov=31,maxFov=52}},
    backdrop={top={0.10,0.31,0.63},bottom={0.72,0.84,0.93}},profile="orre",crowd="source-hsd-exact",preserveSourceShell=true,
  },
  cipher_lab_underground={
    id="cipher_lab_underground",label="CIPHER LAB UNDERGROUND",cache="cache/D1_labo_B1_bf_cache.lua",ready=true,
    stageScale=.25,stageYaw=0,sceneRadiusRaw=1800,maxGroupSpanRaw=4000,vertexRadiusRaw=1750,
    pokemon={player={0,14.5},enemy={0,-14.5}},figureScale=.38,
    trainers={player={12,24},enemy={-12,-24}},trainerScale={player=.415,enemy=.202},
    camera={side=38,back=12,height=13,lookX=0,lookY=5.2,frameH=34,
      safe={minRadius=24,maxRadius=43,minY=6,maxY=18,maxPitch=17,minPitch=-7,minFov=34,maxFov=50}},
    backdrop={top={.025,.04,.055},bottom={.045,.06,.07}},profile="cipher_lab",crowd="none",
  },
  relic_chamber={
    id="relic_chamber",label="RELIC CHAMBER",cache="cache/M3_shrine_1F_bf_cache.lua",ready=true,
    -- M3_shrine_1F_bf is the retail Relic Forest/Stone battle stage. Keep a
    -- substantially larger portion of its native shell now that extraction
    -- obeys HSD render-pass visibility; do not replace the missing distance with
    -- CBE-authored rows of procedural trees.
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=7800,maxGroupSpanRaw=20000,vertexRadiusRaw=7400,
    pokemon={player={-4.0,16.2},enemy={4.0,-16.2}},figureScale=0.38,trainers={player={11.0,25.0},enemy={-11.0,-25.0}},trainerScale={player=0.415,enemy=0.202},
    camera={side=34,back=8,height=10.8,lookX=0,lookY=5.15,frameH=29.5,shotRadiusScale=0.60,shotHeightScale=0.42,
      safe={minRadius=23,maxRadius=36,minY=6.6,maxY=13.5,maxPitch=11.5,minPitch=-5.5,minFov=34,maxFov=48,minFocusY=4.5,maxFocusY=6.3}},
    -- M3_shrine_1F_bf owns the complete submitted shell, including its authored
    -- foliage/overhead carriers. Do not hide source groups per camera shot or
    -- synthesize closure behind them in canonical source mode.
    backdrop={top={0.16,0.36,0.62},bottom={0.70,0.78,0.58}},profile="relic",crowd="none",
    preserveSourceShell=true,sourceShellOnly=true,worldShell="source",
  },
  relic_cave={
    id="relic_cave",label="RELIC CAVE",cache="cache/M3_cave_1F_1_bf_cache.lua",ready=true,
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=2800,maxGroupSpanRaw=6800,vertexRadiusRaw=2700,
    pokemon={player={-4.2,16.6},enemy={4.2,-16.6}},figureScale=0.375,trainers={player={11.4,25.2},enemy={-11.4,-25.2}},trainerScale={player=0.415,enemy=0.202},
    camera={side=52,back=15,height=23,lookX=0,lookY=5.7,frameH=47,safe={minRadius=26,maxRadius=72,minY=6.0,maxY=35,maxPitch=29,minPitch=-10,minFov=31,maxFov=51}},
    backdrop={top={0.025,0.050,0.030},bottom={0.13,0.12,0.075}},profile="relic_cave",crowd="none",
  },
  outskirts={
    id="outskirts",label="OUTSKIRTS",cache="cache/S1_out_bf_cache.lua",ready=true,
    -- Keep substantially more of S1_out_bf's outer source shell in the packed
    -- runtime. The original opening battle reads as a vast desert, not a 3D box.
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=16000,maxGroupSpanRaw=42000,vertexRadiusRaw=15000,
    pokemon={player={-4.6,17.4},enemy={4.6,-17.4}},figureScale=0.355,trainers={player={13.4,27.6},enemy={-13.4,-27.6}},trainerScale={player=0.415,enemy=0.202},
    -- Retail Outskirt Stand cameras are much lower and more horizontal than the
    -- old CBE master. Compress automatic choreography toward the source framing.
    camera={side=49,back=12,height=13.5,lookX=0,lookY=5.2,frameH=41,shotRadiusScale=0.82,shotHeightScale=0.62,
      safe={minRadius=27,maxRadius=63,minY=6.4,maxY=21,maxPitch=16,minPitch=-8,minFov=32,maxFov=50}},
    -- The expanded canonical cache is the retail S1_out_bf battle stage itself.
    -- Do not layer a second CBE-authored desert world beneath/around it: retain
    -- every submitted source group and let the source shell own world geometry.
    -- The backdrop remains only a fail-open color behind any genuinely uncovered
    -- pixels until the retail camera/background descriptor is decoded.
    backdrop={top={0.11,0.30,0.58},bottom={0.93,0.77,0.48}},profile="outskirts",crowd="none",
    preserveSourceShell=true,sourceShellOnly=true,worldShell="source",
  },
  pyrite_colosseum={
    id="pyrite_colosseum",label="PYRITE COLOSSEUM",cache="cache/M2_earth_colo_cache.lua",ready=true,
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=3600,maxGroupSpanRaw=8600,vertexRadiusRaw=3500,
    pokemon={player={-5.0,18.0},enemy={5.0,-18.0}},figureScale=0.35,trainers={player={13.0,27.8},enemy={-13.0,-27.8}},trainerScale={player=0.405,enemy=0.198},
    -- Pyrite's authentic battle cameras live INSIDE the lower bowl. Generic CBE
    -- masters at radius ~55-65 climb into the spectator gallery, putting rails
    -- and crowd cards between the lens and battlers. Compress authored shots
    -- into the source arena floor while preserving their screen direction.
    camera={side=39,back=12,height=15.5,lookX=0,lookY=5.8,frameH=30,shotRadiusScale=0.72,shotHeightScale=0.72,
      safe={minRadius=24,maxRadius=43,minY=6.5,maxY=22.5,maxPitch=19,minPitch=-9,minFov=31,maxFov=50}},
    backdrop={top={0.14,0.35,0.61},bottom={0.73,0.69,0.53}},profile="pyrite",crowd="source-hsd-exact",
  },
  deep_colosseum={
    id="deep_colosseum",label="DEEP COLOSSEUM",cache="cache/M4_bottom_colo_cache.lua",ready=true,
    -- M4_bottom_colo's identity is the enormous underground shell: ceiling
    -- rotor, pipe forest, distant masonry and audience banks. Preserve that
    -- outer geometry instead of trimming it to the battle disc.
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=12000,maxGroupSpanRaw=32000,vertexRadiusRaw=11500,
    pokemon={player={-5.8,19.5},enemy={5.8,-19.5}},figureScale=0.300,trainers={player={14.0,30.5},enemy={-14.0,-30.5}},trainerScale={player=0.365,enemy=0.180},
    -- Source Deep Colosseum framing is low, wide and architectural: battlers are
    -- small against the chamber and ceiling machinery. Keep CBE shots inside
    -- that floor-level photographic envelope.
    camera={side=51,back=14,height=12.2,lookX=0,lookY=4.8,frameH=46,shotRadiusScale=0.84,shotHeightScale=0.60,
      safe={minRadius=28,maxRadius=66,minY=5.8,maxY=19.0,maxPitch=14,minPitch=-8,minFov=32,maxFov=50}},
    backdrop={top={0.005,0.006,0.006},bottom={0.018,0.020,0.019}},profile="deep",crowd="source-hsd-exact",worldShell="industrial",
  },
  realgam_colosseum={
    id="realgam_colosseum",label="REALGAM COLOSSEUM",cache="cache/realgam_colosseum_cache.lua",ready=true,
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=4400,maxGroupSpanRaw=9000,vertexRadiusRaw=4300,
    pokemon={player={-4.8,17.5},enemy={4.8,-17.5}},figureScale=0.35,trainers={player={12.5,27.0},enemy={-12.5,-27.0}},trainerScale={player=0.405,enemy=0.198},
    camera={side=58,back=17,height=27,lookX=0,lookY=6.6,frameH=51,safe={minRadius=29,maxRadius=82,minY=7.0,maxY=39,maxPitch=31,minPitch=-8,minFov=31,maxFov=53}},
    backdrop={top={0.43,0.64,0.82},bottom={0.72,0.84,0.93}},profile="realgam",crowd="source-hsd-exact",
  },
  outdoor_wild={
    id="outdoor_wild",label="ORRE WILDLANDS",cache="cache/outdoor_wild_cache.lua",ready=true,
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=620,maxGroupSpanRaw=1350,vertexRadiusRaw=610,
    pokemon={player={-4.5,18.0},enemy={4.5,-18.0}},figureScale=0.365,trainers={player={14.0,29.5},enemy={-14.0,-29.5}},trainerScale={player=0.425,enemy=0.205},
    camera={side=59,back=18,height=29,lookX=0,lookY=6.0,frameH=51,safe={minRadius=29,maxRadius=87,minY=7.0,maxY=43,maxPitch=33,minPitch=-10,minFov=31,maxFov=54}},
    backdrop={top={0.08,0.31,0.65},bottom={0.68,0.84,0.76}},profile="outdoor",crowd="none",
  },
  mt_battle_summit={
    id="mt_battle_summit",label="MT. BATTLE SUMMIT",cache="cache/D2_mt_battle_platform100_cache.lua",ready=true,
    stageScale=0.25,stageYaw=0,sceneRadiusRaw=7000,maxGroupSpanRaw=15000,vertexRadiusRaw=6900,
    pokemon={player={-6.0,21.0},enemy={6.0,-21.0}},figureScale=0.34,trainers={player={17.0,30.0},enemy={-17.0,-30.0}},trainerScale={player=0.445,enemy=0.215},
    camera={side=61,back=19,height=31,lookX=0,lookY=6.6,frameH=53.5,safe={minRadius=31,maxRadius=91,minY=7.5,maxY=45,maxPitch=34,minPitch=-10,minFov=31,maxFov=54}},
    backdrop={top={0.30,0.38,0.49},bottom={0.72,0.72,0.69}},profile="summit",crowd="source-hsd-exact",
    -- D2_crater_colo is the retail battle stage itself. The battlefield floor,
    -- bridge, crater and audience shell are one authored HSD scene; generic
    -- battle-radius clipping can punch holes in its deck and is not permitted.
    preserveSourceShell=true,
  },
}

local ORDER={"auto","random","open_water","water","orre_colosseum","relic_chamber","relic_cave","outskirts","pyrite_colosseum","deep_colosseum","realgam_colosseum","outdoor_wild","mt_battle_summit","cipher_lab_underground"}
local VALID={auto=true,random=true,open_water=true,water=true,orre_colosseum=true,relic_chamber=true,relic_cave=true,outskirts=true,pyrite_colosseum=true,deep_colosseum=true,realgam_colosseum=true,outdoor_wild=true,mt_battle_summit=true,cipher_lab_underground=true}

local function randomDefinition()
  local pool={}
  for _,id in ipairs(ORDER) do
    if id~="auto" and id~="random" then
      local def=DEFINITIONS[id]
      if def and def.ready then pool[#pool+1]=def end
    end
  end
  if #pool==0 then return DEFINITIONS.water end
  if #pool==1 then return pool[1] end
  local candidates={}
  for _,def in ipairs(pool) do
    if def.id~=lastRandomResolved then candidates[#candidates+1]=def end
  end
  if #candidates==0 then candidates=pool end
  local chosen=candidates[math.random(1,#candidates)]
  lastRandomResolved=chosen.id
  return chosen
end

local function saved(game)
  local save=game and game.save
  local p=save and save.colosseumBattle
  local id=p and p.arena or "auto"
  if not VALID[id] then id="auto" end
  return id
end

local function ensurePrefs(game)
  if not (game and game.save) then return nil end
  local p=game.save.colosseumBattle
  if type(p)~="table" then p={};game.save.colosseumBattle=p end
  return p
end

-- Resolve the NEXT random arena before a battle object exists so Android can
-- prewarm that exact scene off the battle-entry seam. The choice is consumed
-- once when the next battle binds; it never changes during that battle.
function C.primeRandom(game)
  local selected=pendingSelected or (game and saved(game)) or runtimeSelected or "auto"
  if selected~="random" or boundBattle then return nil end
  if not primedRandom then primedRandom=randomDefinition() end
  return primedRandom
end


function C.enabled(game)
  local save=game and game.save
  local p=save and save.colosseumBattle
  if not p then return true end
  if p.arenasEnabled==nil then p.arenasEnabled=true end
  return p.arenasEnabled and true or false
end

function C.setEnabled(game,value)
  local p=ensurePrefs(game)
  if p then p.arenasEnabled=value and true or false end
  return value and true or false
end

function C.definition(id) return DEFINITIONS[id] end
function C.order() return ORDER end
function C.options()
  return {
    {id="auto",label="AUTO"},
    {id="random",label="RANDOM"},
    {id="open_water",label="ORRE OPEN SEA"},
    {id="water",label="WATER COLOSSEUM"},
    {id="orre_colosseum",label="ORRE COLOSSEUM"},
    {id="relic_chamber",label="RELIC CHAMBER"},
    {id="relic_cave",label="RELIC CAVE"},
    {id="outskirts",label="OUTSKIRTS"},
    {id="pyrite_colosseum",label="PYRITE COLOSSEUM"},
    {id="deep_colosseum",label="DEEP COLOSSEUM"},
    {id="realgam_colosseum",label="REALGAM COLOSSEUM"},
    {id="outdoor_wild",label="ORRE WILDLANDS"},
    {id="mt_battle_summit",label="MT. BATTLE SUMMIT"},
    {id="cipher_lab_underground",label="CIPHER LAB UNDERGROUND"},
  }
end

local function waterWildEncounter(game,battle)
  if not battle then return false end
  local wild=(battle.kind=="wild") or battle.wild==true
  if not wild then return false end
  -- Gen II retains the field World and its Player while the battle screen is
  -- entering; Gen I does the same through OverworldState.  Surf encounters are
  -- therefore identifiable without species guesses or engine patches. Fishing
  -- also belongs on the open-water stage even when the player is on shore.
  local bt=tostring(battle.battleType or ""):lower()
  if bt=="fish" or bt=="fishing" then return true end
  local world=game and (game.world or game.overworld)
  local player=world and world.player
  if player and player.surfing==true then return true end
  -- Older/stripped Gen I contexts can expose the live player directly on game.
  player=game and game.player
  return player and player.surfing==true or false
end

function C.setSelected(game,id)
  if not VALID[id] then id="auto" end
  runtimeSelected=id
  pendingSelected=id
  if id~="random" then primedRandom=nil end
  local p=ensurePrefs(game)
  if p then p.arena=id end
  if id=="random" then C.primeRandom(game) end
  -- Arena providers are acquired once at battle start. Never mutate a battle
  -- already in progress; stage the explicit choice so the NEXT acquire cannot
  -- be overwritten by an older battle.game.save snapshot.
  return id
end

function C.sync(game)
  -- Do not cache the first value forever. If mod load happens
  -- before the active save was fully attached, that stale AUTO/WATER value
  -- overrode later selection. Do not let background save synchronization erase
  -- a menu choice that is waiting to be acquired by the next battle.
  if game and game.save and pendingSelected==nil then runtimeSelected=saved(game) end
  return pendingSelected or runtimeSelected or "auto"
end

function C.selected(game)
  if pendingSelected~=nil then return pendingSelected end
  if game and game.save then
    runtimeSelected=saved(game)
    return runtimeSelected
  end
  return runtimeSelected or "auto"
end

local function mtBattleOwned(value)
  if type(value)~="table" then return false end
  if value.__mtbHub==true or value.cbeMtBattleChallenge==true then return true end
  local nested=value._model or value.battle or value.model
  return type(nested)=="table" and nested~=value
    and (nested.__mtbHub==true or nested.cbeMtBattleChallenge==true) or false
end

function C.resolve(game,battle)
  -- Mt. Battle 100 owns its venue independently of the player's ordinary CBE
  -- arena preference. Gen II may surface its Battle model, BattleState view, or
  -- CBE facade at arena acquisition; all three must retain Summit ownership.
  if mtBattleOwned(battle) then
    local summit=DEFINITIONS.mt_battle_summit or DEFINITIONS.water
    return summit,"mt_battle_challenge"
  end
  local selected
  if battle then
    -- Bind one immutable manual selection to this exact battle.  StadiumBattleFX
    -- acquires the arena once at battle.started; Agatha/Nascour, Lance, camera
    -- events, or later save reads cannot change the selected arena underneath it.
    if boundBattle~=battle then
      boundBattle=battle
      -- A selection made in the BATTLE overlay is authoritative for this
      -- acquisition even if ctx.game still exposes an older save snapshot.
      boundSelected=pendingSelected or C.selected(game)
      runtimeSelected=boundSelected
      pendingSelected=nil
      if boundSelected=="random" then
        boundResolved=primedRandom or randomDefinition()
        primedRandom=nil
      else
        boundResolved=nil
      end
    end
    selected=boundSelected or "auto"
  else
    selected=C.selected(game)
  end
  if selected=="random" then
    -- Random is chosen ONLY at the authoritative battle acquisition above.
    -- Status/menu/prewarm calls without a battle must never consume RNG or alter
    -- the no-repeat history, otherwise merely opening settings can change the
    -- arena the next battle receives.
    local def
    if battle then def=boundResolved
    else def=primedRandom or (lastRandomResolved and DEFINITIONS[lastRandomResolved]) or DEFINITIONS.water end
    if not def or not def.ready then def=DEFINITIONS.water end
    return def,selected
  end
  local wanted=selected
  if selected=="auto" then
    if waterWildEncounter(game,battle) then
      wanted="open_water"
    else
      wanted=(battle and (battle.kind=="wild" or battle.kind=="safari" or battle.wild==true)) and "outdoor_wild" or "water"
    end
  end
  local def=DEFINITIONS[wanted] or DEFINITIONS.water
  if not def.ready then def=DEFINITIONS.water end
  return def,selected
end

C._test=C._test or {}
C._test.mtBattleOwned=mtBattleOwned

function C.releaseBattle(battle)
  if not battle or boundBattle==battle then
    boundBattle=nil
    boundSelected=nil
    boundResolved=nil
  end
end

function C.status(game,battle)
  local def,selected=C.resolve(game,battle)
  return {enabled=C.enabled(game),selected=selected,resolved=def.id,cache=def.cache,runtimeSelected=runtimeSelected,pendingSelected=pendingSelected,boundSelected=boundSelected,boundResolved=boundResolved and boundResolved.id or nil,lastRandomResolved=lastRandomResolved,primedRandom=primedRandom and primedRandom.id or nil,boundBattle=boundBattle~=nil,definitions=DEFINITIONS}
end

return C
