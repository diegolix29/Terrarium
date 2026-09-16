-- Mt. Battle 100 anti-repetition: recency-window species/archetype
-- exclusion across the 100 fights, modeled on src/core/gen2/BattleTower.
-- lua's own prevTeams/chooseTrainer/chooseTeam bookkeeping (a real,
-- shipped precedent for exactly this problem -- avoid repeating a recent
-- draw without needing a full-run pre-shuffle).
--
-- State lives in game.save.mtBattleChallenge.usedSpecies/usedArchetypes
-- (via SaveState.lua) as {name -> lastUsedFightIndex}, a plain recency
-- cache, not additional entropy -- rebuilding it from scratch would only
-- cost "no memory of the last few fights," never break determinism.
local AR={}

-- Default recency window: a species/archetype used within the last N
-- fights is penalized (not banned outright -- a small roster of eligible
-- species for a given role must still be pickable even if everything in
-- it was recently used, rather than the generator failing to produce a
-- team at all).
AR.SPECIES_WINDOW=15
AR.ARCHETYPE_WINDOW=5

local function recency(usedTable,key,fightIndex,window)
  local last=usedTable[key]
  if not last then return 1.0 end
  local age=fightIndex-last
  if age>=window then return 1.0 end
  -- Linear ramp from a heavy penalty (just used) back to full weight (at
  -- the window edge) -- never zero, so a small eligible pool never stalls.
  return 0.1+0.9*(age/window)
end

-- Weight multiplier in [0.1,1.0] for picking `species` at `fightIndex`.
function AR.speciesWeight(save,species,fightIndex)
  return recency(save.usedSpecies,species,fightIndex,AR.SPECIES_WINDOW)
end

function AR.archetypeWeight(save,archetypeId,fightIndex)
  return recency(save.usedArchetypes,archetypeId,fightIndex,AR.ARCHETYPE_WINDOW)
end

-- Weighted pick from `candidates` (array of values) using `weightFn(v)` ->
-- number, consuming exactly one draw from `stream`. Never mutates
-- `candidates`. Falls back to a plain uniform pick if every weight is
-- zero (should not happen given the recency floor above, but a
-- defensive fallback beats an infinite loop or a divide-by-zero).
function AR.weightedPick(stream,candidates,weightFn)
  if not candidates or #candidates==0 then return nil end
  local total=0
  local weights={}
  for i,c in ipairs(candidates) do
    local w=math.max(0,weightFn(c) or 0)
    weights[i]=w;total=total+w
  end
  if total<=0 then return stream:pick(candidates) end
  local roll=stream:nextFloat()*total
  local acc=0
  for i,c in ipairs(candidates) do
    acc=acc+weights[i]
    if roll<=acc then return c end
  end
  return candidates[#candidates]
end

-- Record that `species`/`archetypeId` were used in this fight -- called
-- once per generated roster, after the roster is finalized (not
-- per-candidate-considered), so a rejected/re-rolled candidate never
-- pollutes the recency window. Also bumps the hard run-total usage count
-- (save.speciesUseCount) the coverage/cap guarantee below reads -- one
-- shared record point so the two never drift out of sync with each other.
function AR.record(save,fightIndex,speciesList,archetypeId)
  for _,species in ipairs(speciesList or {}) do
    save.usedSpecies[species]=fightIndex
    save.speciesUseCount[species]=(save.speciesUseCount[species] or 0)+1
  end
  if archetypeId then save.usedArchetypes[archetypeId]=fightIndex end
end

-- ===== Coverage/cap guarantee: every eligible species appears at least
-- once across the 100 fights, none more than MAX_USES times. =====
--
-- This is a HARD constraint (unlike the soft recency weighting above), so
-- it's enforced in two parts: AR.canUse is a simple eligibility filter
-- (never pick a species already at the cap); the "at least once" half
-- needs active FORCING as fight 100 approaches, computed lazily at each
-- fight's generation time rather than pre-planning all 100 rosters up
-- front (consistent with this generator's established one-fight-ahead
-- architecture -- see RunController.currentEncounter's own header on why
-- lazy generation was chosen). The forcing math is a simple, provably
-- sufficient "deadline" argument: at fight N, if the number of still-
-- unused eligible species would not fit into the WORST-CASE remaining
-- capacity (every future fight rolling the smallest possible roster) once
-- this fight's slots are spent normally, force enough of them into THIS
-- fight's roster now to keep the deadline achievable. Recomputed fresh
-- every fight, so it's self-correcting and needs no lookahead beyond
-- reading Difficulty's already-deterministic per-fight tier data.
AR.MAX_USES=4

function AR.useCount(save,species)
  local counts=save and save.speciesUseCount
  return type(counts)=="table" and (counts[species] or 0) or 0
end

-- Hard eligibility: never pick a species already at the cap, regardless
-- of recency weight (recency is a preference; this is a rule).
function AR.canUse(save,species)
  return AR.useCount(save,species)<AR.MAX_USES
end

-- Species from `eligibleSpeciesIds` never used at all so far (count==0).
function AR.unusedSpecies(save,eligibleSpeciesIds)
  local out={}
  for _,id in ipairs(eligibleSpeciesIds or {}) do
    if AR.useCount(save,id)==0 then out[#out+1]=id end
  end
  return out
end

-- Worst-case (minimum) total roster slots across fights
-- [fromFightIndex..totalFights], reading only Difficulty.tierFor(f)'s
-- rosterMin -- deterministic from the fight index alone, no stream draw,
-- so this can be computed for FUTURE fights without generating them.
-- Using the minimum (not an average/expected value) is what makes the
-- forcing guarantee hold even if every future roll comes in small.
function AR.minRemainingSlots(fromFightIndex,Difficulty,totalFights)
  totalFights=totalFights or 100
  local total=0
  for f=fromFightIndex,totalFights do
    total=total+Difficulty.tierFor(f).rosterMin
  end
  return total
end

-- How many of THIS fight's `teamSize` slots MUST go to never-used species
-- so that, even in the worst case, everyone still gets covered by the
-- last fight. need = unusedCount - minRemainingSlots(AFTER this fight);
-- clamped to [0, teamSize] since forcing can never exceed this fight's
-- own capacity or be negative.
--
-- Known, bounded, self-correcting approximation: this counts EVERY future
-- fight's rosterMin as available generic-forcing capacity, including
-- fight 49 (the Eeveelution-team override, whose slots are entirely
-- spoken for and contribute nothing to generic coverage -- see
-- SpecialFights.lua). That overestimates remaining capacity by at most
-- one fight's rosterMin (~4-5) for any fightIndex<49. This is corrected
-- fresh every fight (never compounds) and this generator's real species
-- pools have far more slack than a single fight's worth of slots, so it
-- is intentionally left as an approximation rather than coupling this
-- generation-agnostic module to a specific fight-index override.
function AR.forcedCoverageCount(save,fightIndex,teamSize,eligibleSpeciesIds,Difficulty,totalFights)
  totalFights=totalFights or 100
  local unused=#AR.unusedSpecies(save,eligibleSpeciesIds)
  local futureMin=fightIndex<totalFights
    and AR.minRemainingSlots(fightIndex+1,Difficulty,totalFights) or 0
  local need=unused-futureMin
  if need<0 then need=0 end
  if need>teamSize then need=teamSize end
  return need
end

return AR
