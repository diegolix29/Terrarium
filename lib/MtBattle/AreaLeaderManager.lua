-- Mt. Battle 100 Area Leaders: every 10th trainer (10,20,...,100) per the
-- supplemental design doc. Stronger milestone presentation + a larger
-- generation/optimization budget; does NOT refill the Challenge Bag or
-- reset endurance resources (RunController/ChallengeBag are untouched by
-- Area Leader status -- this module only answers "is fight N an Area
-- Leader" and "what extra budget does it get", nothing about resources).
local ALM={}

-- Milestone trainers keep a recognizable tactical identity instead of being
-- ordinary random trainers with slightly higher stats. The theme is a strong
-- deterministic lean, not a forced species/type script, so the run-wide
-- coverage guarantee and seeded variation remain authoritative.
ALM.LEADER_ARCHETYPE_BY_AREA={
  "balanced","bulky_offense","speed_control","setup_sweep","hyper_offense",
  "bulky_offense","stall","speed_control","setup_sweep","balanced",
}

function ALM.isAreaLeader(fightIndex)
  return fightIndex%10==0
end

-- Widens the roster size range and nudges the generator's re-roll
-- attempt budget up for an Area Leader fight, layered on top of
-- Difficulty.tierFor's normal tier -- returns a NEW tier-shaped table
-- (never mutates the shared Difficulty.TIERS entry, which every other
-- fight in the same band still reads unmodified).
function ALM.applyBudget(tier,fightIndex)
  local boosted={}
  for k,v in pairs(tier) do boosted[k]=v end
  -- Every Mt. Battle trainer already owns a full six-Pokemon roster. Area
  -- Leaders get stronger optimization/item budgets, never a larger party than
  -- ordinary trainers.
  boosted.rosterMin=6
  boosted.rosterMax=6
  boosted.itemChance=math.min(1,tier.itemChance+0.15)
  -- Milestone fights should feel authored/stronger without hard-filtering the
  -- species pool. Shift the soft power envelope upward and narrow it slightly;
  -- RosterCore still allows outliers when coverage/anti-repeat requires them.
  if tonumber(tier.powerCenter) then boosted.powerCenter=tier.powerCenter+20 end
  if tonumber(tier.powerSpread) then boosted.powerSpread=math.max(35,tier.powerSpread*.88) end
  if tonumber(tier.powerFloor) then boosted.powerFloor=tier.powerFloor+15 end
  boosted.optimizationAttempts=(tonumber(tier.optimizationAttempts) or 5)+2
  boosted.isAreaLeader=true
  local area=math.max(1,math.min(10,math.floor(((tonumber(fightIndex) or 10)-1)/10)+1))
  boosted.leaderArea=area
  boosted.leaderArchetype=ALM.LEADER_ARCHETYPE_BY_AREA[area]
  return boosted
end

-- Presentation tier for BossIntro.classify-style category selection
-- (lib/BossIntro.lua:20-31, verified live in Phase 0 Spike 7): Area
-- Leaders 10-90 get a lesser, still-real category ("elite-four" -- a
-- recognized, whitelisted CATEGORIES entry short of the full "champion"
-- treatment); fight 100 is BOTH an Area Leader (100%10==0) AND the
-- finale, and FinaleIntro.lua's "champion" override takes priority for
-- it specifically (checked by the caller, not this module -- see
-- FinaleIntro.isFinale).
function ALM.bossCategory(fightIndex)
  if not ALM.isAreaLeader(fightIndex) then return nil end
  return "elite-four"
end

return ALM
