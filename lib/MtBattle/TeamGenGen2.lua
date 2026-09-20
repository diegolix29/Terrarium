-- Mt. Battle 100 Gen 2 opponent roster synthesis. Produces ALREADY-
-- CONSTRUCTED Mon objects (via Mon.new), not raw rows -- Gen 2's
-- Battle.new/trainer.party hook expects pre-built mon objects, unlike
-- Gen 1's raw {species=,level=,moves=} rows the engine expands itself
-- (verified in Phase 0 Spike 5, matching src/core/gen2/BattleTower.lua's
-- own battleParty() approach).
--
-- Correction from an earlier pass: Gen 2 ALSO exposes an already-decoded
-- `tmhm` move-id list (src/mods/Schemas.lua:878, identical shape to
-- Gen 1's own `tmhm` field) -- `tmhmRaw` (line 881) is only the raw
-- bitfield bytes kept alongside it "so a re-export round-trips; the
-- engine reads `tmhm`" per that field's own comment. The earlier
-- assumption that Gen 2 TM/HM needed raw-byte decoding was wrong; movePool
-- below now draws from both levelMoves and tmhm, matching Gen 1's
-- movePool exactly.
--
-- Held items remain a small curated pool, but are role/personality weighted and
-- participate in whole-team quality scoring rather than being arbitrary flavor.
local V=... or {}
local Archetypes=V.MtBattleArchetypes
local AntiRepeat=V.MtBattleAntiRepeat
local RosterCore=V.MtBattleRosterCore
local Difficulty=V.MtBattleDifficulty
local ShinyRollManager=V.MtBattleShinyRollManager
local TrainerIdentityGenerator=V.MtBattleTrainerIdentityGenerator
local PlayerBehaviorTracker=V.MtBattlePlayerBehaviorTracker
local SpecialFights=V.MtBattleSpecialFights
local BattleData=V.MtBattleBattleData
local req=V.engineRequire or require
local G2={}

-- A leading nil is not a stable Lua array entry: `#pool`/ipairs may see the
-- pool as empty, which made the intended Gen2 held-item logic silently collapse
-- to no items. Keep the no-item weight explicit and map it back to nil only
-- after the deterministic weighted pick.
G2.NO_ITEM="__MTB_NO_ITEM__"
G2.ITEM_POOL={G2.NO_ITEM,G2.NO_ITEM,"LEFTOVERS","BERRY","MIRACLE_BERRY"}

function G2.pickHeldItem(stream,role,personality)
  local pid=personality and personality.id
  local item=AntiRepeat.weightedPick(stream,G2.ITEM_POOL,function(candidate)
    if candidate==G2.NO_ITEM then return 1 end
    if role=="wall" or role=="cleric" then
      if candidate=="LEFTOVERS" then return 2.4 end
      if candidate=="MIRACLE_BERRY" then return 1.4 end
    elseif role=="sweeper" or role=="wallbreaker" or role=="revenge_killer" then
      if candidate=="BERRY" then return 1.5 end
    end
    if pid=="defensive" and candidate=="LEFTOVERS" then return 1.35 end
    if pid=="technical" and candidate=="MIRACLE_BERRY" then return 1.25 end
    return 1
  end)
  if item==G2.NO_ITEM then return nil end
  return item
end

local function behaviorCtx()
  if not PlayerBehaviorTracker then return nil end
  local ok,TypeChart=pcall(req,"src.battle.TypeChart")
  if not ok then return nil end
  return {PlayerBehaviorTracker=PlayerBehaviorTracker,TypeChart=TypeChart}
end

local Mon
local function mon() Mon=Mon or (V.engineRequire or require)("src.pokemon.Pokemon");return Mon end

function G2.movePool(data,speciesDef,adapter)
  local seen,out={},{}
  local function add(id)
    if id and not seen[id] then
      local mdef=data.moves and data.moves[id]
      if mdef and Archetypes.isMoveAllowed(id,mdef,adapter) then
        seen[id]=true;out[#out+1]=id
      end
    end
  end
  for _,entry in ipairs((speciesDef and speciesDef.levelMoves) or {}) do
    if not tonumber(entry.level) or tonumber(entry.level)<=100 then add(entry.move) end
  end
  for _,id in ipairs((speciesDef and speciesDef.tmhm) or {}) do add(id) end
  if #out==0 then
    local fallback=BattleData and BattleData.fallbackMove and BattleData.fallbackMove(data,speciesDef)
    out={fallback or "TACKLE"}
  end
  return out
end

local function moveRows(data,ids)
  local rows={}
  for _,id in ipairs(ids) do
    local mdef=data.moves and data.moves[id]
    rows[#rows+1]={id=id,pp=mdef and mdef.pp or 0,maxPp=mdef and mdef.pp or 0}
  end
  return rows
end

function G2.buildRoster(stream,data,save,fightIndex,tier,archetype,eligibleSpeciesIds,adapter,personality)
  local rosterSize=6
  local gated=SpecialFights and SpecialFights.gateEligible(eligibleSpeciesIds,fightIndex) or eligibleSpeciesIds
  -- Fight 49: fixed all-Eeveelution species list (still role/movepool/
  -- item-scored normally below -- only the SPECIES are forced).
  local speciesPerSlot
  if SpecialFights and SpecialFights.isEeveelutionFight(fightIndex) then
    speciesPerSlot=SpecialFights.eeveelutionSpeciesList(data,rosterSize,stream,eligibleSpeciesIds)
    if #speciesPerSlot==0 then
      speciesPerSlot=RosterCore.pickRosterSpecies(stream,AntiRepeat,Difficulty,save,fightIndex,data,
        archetype,rosterSize,gated,behaviorCtx(),tier)
    end
  elseif SpecialFights then
    speciesPerSlot=RosterCore.pickRosterSpecies(stream,AntiRepeat,Difficulty,save,fightIndex,data,
      archetype,rosterSize,gated,behaviorCtx(),tier)
  else
    -- SpecialFights not wired (older callers/tests) -- fall back to the
    -- pre-existing per-slot pick with no coverage/cap/dedup guarantee.
    speciesPerSlot={}
    for i=1,rosterSize do
      local role=archetype.roles[((i-1)%#archetype.roles)+1]
      speciesPerSlot[i]=RosterCore.pickSpecies(stream,AntiRepeat,save,fightIndex,data,role,gated,behaviorCtx())
    end
  end
  local mons,speciesUsed,roles={},{},{}
  local teamCoveredTypes={}
  local teamMoveBudget={counts={status=0,evasion=0,stall=0},caps=Archetypes.FRUSTRATION_CAPS}
  local M=mon()
  for i=1,rosterSize do
    local role=archetype.roles[((i-1)%#archetype.roles)+1]
    local species=speciesPerSlot[i]
    if species then
      local def=data.pokemon[species]
      local pool=G2.movePool(data,def,adapter)
      local memberTypes={}
      for _,t in ipairs(def.types or {}) do memberTypes[t]=true end
      local moveIds=RosterCore.pickMoveset(stream,data,pool,role,memberTypes,Archetypes,2,personality,
        teamCoveredTypes,teamMoveBudget,tier)
      local item=G2.pickHeldItem(stream,role,personality)
      -- Deterministic DVs (RosterCore.streamDVs), NOT Mon.randomDVs()'s
      -- uncontrolled global RNG -- a real determinism gap found and
      -- fixed while adding the shiny-roll system (see RosterCore.lua's
      -- own header comment on this exact fix).
      local built=M.new(data,species,50,{moves=moveRows(data,moveIds),item=item,dvs=RosterCore.streamDVs(stream)})
      if built then
        mons[#mons+1]=built
        speciesUsed[#speciesUsed+1]=species
        roles[#mons]=role
      end
    end
  end
  return {mons=mons,speciesUsed=speciesUsed,roles=roles,frustrationCounts=teamMoveBudget.counts}
end

function G2.frustrationCounts(data,mons)
  local counts={status=0,evasion=0,stall=0}
  for _,m in ipairs(mons) do
    for _,mv in ipairs(m.moves or {}) do
      local mdef=data.moves and data.moves[mv.id]
      if mdef then
        if Archetypes.effectCategory(Archetypes.STATUS_EFFECTS,2,mdef.effect) then counts.status=counts.status+1 end
        if Archetypes.effectCategory(Archetypes.EVASION_EFFECTS,2,mdef.effect) then counts.evasion=counts.evasion+1 end
        if Archetypes.effectCategory(Archetypes.STALL_EFFECTS,2,mdef.effect) then counts.stall=counts.stall+1 end
      end
    end
  end
  return counts
end

function G2.withinFrustrationCaps(counts)
  local caps=Archetypes.FRUSTRATION_CAPS
  return counts.status<=caps.statusMovesPerTeam
    and counts.evasion<=caps.evasionMovesPerTeam
    and counts.stall<=caps.stallMovesPerTeam
end

function G2.generate(stream,data,save,fightIndex,tier,eligibleSpeciesIds,adapter,maxAttempts,isAreaLeader)
  local archetype=(RosterCore and RosterCore.pickArchetype)
    and RosterCore.pickArchetype(stream,Archetypes,AntiRepeat,save,fightIndex,tier)
    or Archetypes.pickArchetype(stream)
  local personality=Difficulty and Difficulty.personalityFor(stream:nextInt(1,#Difficulty.PERSONALITIES)) or nil
  local identity=(TrainerIdentityGenerator and personality)
    and TrainerIdentityGenerator.generate(stream,fightIndex,isAreaLeader,personality) or nil
  local result,bestScore
  local attempts=maxAttempts or (tier and tier.optimizationAttempts) or 5
  for _=1,attempts do
    local candidate=G2.buildRoster(stream,data,save,fightIndex,tier,archetype,eligibleSpeciesIds,adapter,personality)
    local counts=G2.frustrationCounts(data,candidate.mons)
    if #candidate.mons==6 and G2.withinFrustrationCaps(counts) then
      local quality=(RosterCore and RosterCore.teamQuality)
        and RosterCore.teamQuality(data,candidate.mons,candidate.roles,tier,
          {Archetypes=Archetypes,generation=2,archetype=archetype.id}) or 0
      if not result or quality>bestScore then result,bestScore=candidate,quality end
    end
  end
  if not result or #result.mons~=6 then
    error(("Mt. Battle Gen 2 fight %d failed to build a legal six-Pokemon roster after %d attempts")
      :format(fightIndex,attempts),0)
  end
  result.qualityScore=bestScore
  result.archetype=archetype.id
  result.personality=personality and personality.id
  result.identity=identity
  result.isAreaLeader=isAreaLeader and true or false
  if ShinyRollManager then
    -- Fight 100 gets TWO guaranteed shiny aces; every other Area Leader
    -- (fight 40 included) still gets exactly one; a non-Area-Leader fight
    -- gets zero -- see SpecialFights.aceCountFor.
    local aceCount=0
    if isAreaLeader then
      aceCount=(SpecialFights and SpecialFights.aceCountFor(fightIndex)) or 1
    end
    local shiny,aceSlot,aceSlots=ShinyRollManager.assign(stream,#result.mons,aceCount,archetype,
      function(i) return result.roles[i] end)
    for i,m in ipairs(result.mons) do m.shiny=shiny[i] and true or false end
    result.aceSlot=aceSlot
    result.aceSlots=aceSlots
  end
  return result
end

return G2
