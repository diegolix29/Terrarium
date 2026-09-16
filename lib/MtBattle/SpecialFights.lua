-- Mt. Battle 100 fixed generation stipulations, per explicit user
-- direction: no legendary before fight 40; fight 49 is an all-Eeveelution
-- team; fight 100 gets two guaranteed shiny aces (fight 40 already gets
-- its one guaranteed shiny ace for free -- it's an Area Leader, every
-- 10th trainer, per AreaLeaderManager.isAreaLeader/ShinyRollManager,
-- unrelated to anything new in this module). Kept as its OWN module
-- (data + small pure functions, no generator structural logic) so these
-- tunable specifics stay out of TeamGenGen1/2.lua's actual generation
-- flow, matching this feature's established "balance-sensitive values
-- stay centralized and data-driven" convention (Difficulty.lua's own
-- header states the same principle).
local SF={}

-- No canonical `def.legendary` flag exists anywhere in this engine's
-- species schema (confirmed by a direct search of the engine source --
-- the closest thing, src/core/gen2/Breeding.lua's "No Eggs" group, is an
-- inference, not a flag) -- so this is Mt. Battle's OWN curated list,
-- generation-agnostic ids (a Gen 1 boot's data.pokemon simply won't
-- contain the Gen 2-only entries, so listing both here is harmless).
-- MEW is included even though it's more precisely "Mythical" than
-- "Legendary" in modern classification -- the spirit of "no legendary
-- before fight 40" clearly extends to a one-of-a-kind event species too,
-- and excluding it here would just make it eligible from fight 1, which
-- reads as a loophole, not a deliberate call.
SF.LEGENDARIES={
  ARTICUNO=true,ZAPDOS=true,MOLTRES=true,MEWTWO=true,MEW=true,
  RAIKOU=true,ENTEI=true,SUICUNE=true,LUGIA=true,HO_OH=true,CELEBI=true,
  -- Gen III (Hoenn): the Regis, the Eon duo, the weather trio, Jirachi,
  -- Deoxys -- same "no legendary before fight 40" spirit extended to the
  -- newly-added Gen III pool (docs/gen3/Gen3SpeciesData.lua). Harmless to
  -- list here even before Gen III species are registered into a live
  -- game's data.pokemon -- this is just a name check, not a lookup
  -- against a species table that has to already contain them.
  REGIROCK=true,REGICE=true,REGISTEEL=true,LATIAS=true,LATIOS=true,
  KYOGRE=true,GROUDON=true,RAYQUAZA=true,JIRACHI=true,DEOXYS=true,
}

function SF.isLegendary(speciesId)
  return SF.LEGENDARIES[speciesId]==true
end

-- Legendaries are ineligible before this fight (inclusive on 40 itself).
SF.LEGENDARY_GATE_FIGHT=40

-- Eeveelutions, in a fixed priority order (Gen 1's three first, matching
-- release order) -- EEVEE itself is the fallback filler if a fight's
-- team size exceeds however many evolutions exist in the active
-- generation's data (3 for Gen 1, 5 for Gen 2; a Gen 1 boot's
-- data.pokemon has no ESPEON/UMBREON entries, filtered out below the
-- same way every other eligibility check in this feature already
-- screens for baseStats+types presence).
SF.EEVEELUTIONS={"VAPOREON","JOLTEON","FLAREON","ESPEON","UMBREON"}
SF.EEVEE="EEVEE"

function SF.isEeveelution(speciesId)
  for _,id in ipairs(SF.EEVEELUTIONS) do
    if id==speciesId then return true end
  end
  return false
end

-- The one themed fight: battle 49 is an all-Eeveelution team.
SF.EEVEELUTION_FIGHT=49

function SF.isEeveelutionFight(fightIndex)
  return fightIndex==SF.EEVEELUTION_FIGHT
end

-- Filters `eligibleSpeciesIds` down to what's actually pickable at
-- `fightIndex` by the NORMAL generator -- the two gates this module
-- applies to the ordinary candidate pool (the Eeveelution fight's own
-- roster is a full override, built by eeveelutionSpeciesList below, not
-- filtered eligibility, so it's unaffected by this function). Never
-- mutates its input.
--   - Legendaries are ineligible before LEGENDARY_GATE_FIGHT.
--   - Eeveelutions are ineligible before EEVEELUTION_FIGHT. This is
--     deliberate, not just thematic: it's what GUARANTEES every
--     Eeveelution walks into fight 49 with a usage count of exactly 0,
--     so forcing all of them into that one team can never push any of
--     them past AntiRepeat.MAX_USES -- without this exclusion, the
--     coverage-forcing algorithm could plausibly (if unlikely) have
--     already pushed an Eeveelution to its cap in an earlier fight,
--     which would make fight 49's own hard requirement impossible to
--     satisfy without violating the equally-hard 4-use cap. Excluding
--     them pre-49 makes the two requirements provably compatible instead
--     of merely usually compatible.
function SF.gateEligible(eligibleSpeciesIds,fightIndex)
  local out={}
  for _,id in ipairs(eligibleSpeciesIds or {}) do
    local blockedLegendary=fightIndex<SF.LEGENDARY_GATE_FIGHT and SF.isLegendary(id)
    -- Reserve the complete Eevee family, including EEVEE itself, so fight 49's
    -- six-slot themed roster cannot consume the four-use run cap before the
    -- special fight occurs.
    local blockedEeveelution=fightIndex<SF.EEVEELUTION_FIGHT and (SF.isEeveelution(id) or id==SF.EEVEE)
    if not (blockedLegendary or blockedEeveelution) then out[#out+1]=id end
  end
  return out
end

-- Builds the FIXED species-per-slot list for the Eeveelution fight:
-- every evolution the active generation's data actually has (deduped,
-- in SF.EEVEELUTIONS order), then EEVEE filling any remaining slots up
-- to `teamSize`, then (only if teamSize is somehow smaller than the
-- available-evolutions count) truncated to teamSize -- deterministically
-- shuffled first via the fight's own stream so which evolutions get
-- dropped (in the truncation case) or repeated (EEVEE padding aside,
-- this never repeats an evolution) isn't a fixed table-order artifact.
function SF.eeveelutionSpeciesList(data,teamSize,stream,eligibleSpeciesIds)
  local allowed=nil
  if type(eligibleSpeciesIds)=="table" then
    allowed={};for _,id in ipairs(eligibleSpeciesIds) do allowed[id]=true end
  end
  local available={}
  for _,id in ipairs(SF.EEVEELUTIONS) do
    local def=data.pokemon and data.pokemon[id]
    if def and def.baseStats and def.types and (not allowed or allowed[id]) then available[#available+1]=id end
  end
  -- Fisher-Yates via the fight's own stream (Stream has no :shuffle of
  -- its own -- src/link/LinkBattle.lua's makeRng doesn't expose one
  -- either -- so this is the same manual in-place shuffle every other
  -- deterministic-ordering need in this codebase already hand-rolls).
  for i=#available,2,-1 do
    local j=stream:nextInt(1,i)
    available[i],available[j]=available[j],available[i]
  end
  local out={}
  for i=1,math.min(teamSize,#available) do out[#out+1]=available[i] end
  local eeveeDef=data.pokemon and data.pokemon[SF.EEVEE]
  local eeveeOk=eeveeDef and eeveeDef.baseStats and eeveeDef.types and (not allowed or allowed[SF.EEVEE])
  while #out<teamSize and eeveeOk do out[#out+1]=SF.EEVEE end
  -- A strict generation preference can keep only part of the Eevee family
  -- (GEN 2 ONLY keeps Espeon/Umbreon while excluding Gen-1 Eevee itself). Keep
  -- Battle 49 themed without leaking an excluded generation by cycling only the
  -- still-eligible evolutions. GEN 3 ONLY has no eligible Eevee-family member;
  -- callers detect the empty result and use the normal Gen-3 pool instead.
  local i=1
  while #out<teamSize and #available>0 do
    out[#out+1]=available[((i-1)%#available)+1];i=i+1
  end
  return out
end

-- Fight 100 gets TWO guaranteed shiny aces (every other Area Leader,
-- fight 40 included, still gets exactly one -- see ShinyRollManager.
-- assign, which this feeds). Only meaningful for a fight that's already
-- an Area Leader; the caller (TeamGenGen1/2.generate) gates on
-- isAreaLeader itself, same as before this stipulation existed.
SF.DOUBLE_ACE_FIGHT=100

function SF.aceCountFor(fightIndex)
  if fightIndex==SF.DOUBLE_ACE_FIGHT then return 2 end
  return 1
end

return SF
