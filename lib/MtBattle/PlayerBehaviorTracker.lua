-- Mt. Battle 100 limited player-behavior adaptation (supplemental design
-- doc). The starting-team fingerprint remains the PRIMARY generator
-- input (Fingerprint.lua, unchanged) -- this module is a secondary,
-- deliberately weak influence that only engages in deeper rounds and
-- never hard-counters: "must never become immediate psychic
-- counter-generation... later opponents become better prepared for
-- strategies the player has repeatedly demonstrated," nothing stronger.
--
-- Scope note, stated plainly rather than glossed over: this module
-- provides the real, tested AGGREGATION and INFLUENCE-WEIGHT logic. The
-- actual CAPTURE of what happened turn-by-turn in a live battle (which
-- lead was sent out, which move types were thrown, how often the player
-- switched) needs a battle-event-stream integration (Runtime hooks on
-- the real turn/switch events) that was not wired into a live battle
-- loop in this pass -- RunController calls RC.recordFight(save,summary)
-- once per completed fight with a `summary` table the CALLER assembles;
-- assembling that summary from real battle events is a follow-up
-- integration task, the same class of gap as OverworldGate's live-boot
-- limits (Phase 0 Spike 3) -- honestly flagged, not silently assumed.
--
-- State lives in game.save.mtBattleChallenge (per-run, reset every BEGIN
-- CHALLENGE -- behavior from a PREVIOUS run must never leak into a new
-- one, since a new run may bring a completely different team).
local PBT={}

PBT.ADAPTATION_START_FIGHT=50 -- "deeper rounds" -- before this, zero influence
PBT.MAX_LEAN=0.15 -- hard cap: at most a 15% weight nudge, never a hard filter

local function tracker(save)
  save.behaviorTracker=save.behaviorTracker or {
    leadSpecies={},moveTypesUsed={},switches=0,fightsObserved=0,
    statusMovesUsed=0,setupMovesUsed=0,repeatWinConditions={},
  }
  return save.behaviorTracker
end

-- summary: {leadSpecies=, moveTypes={type=count,...}, switches=,
--   statusMovesUsed=, setupMovesUsed=, winConditionSpecies=}
function PBT.recordFight(save,summary)
  if not summary then return end
  local t=tracker(save)
  t.fightsObserved=t.fightsObserved+1
  if summary.leadSpecies then
    t.leadSpecies[summary.leadSpecies]=(t.leadSpecies[summary.leadSpecies] or 0)+1
  end
  for moveType,count in pairs(summary.moveTypes or {}) do
    t.moveTypesUsed[moveType]=(t.moveTypesUsed[moveType] or 0)+count
  end
  t.switches=t.switches+(summary.switches or 0)
  t.statusMovesUsed=t.statusMovesUsed+(summary.statusMovesUsed or 0)
  t.setupMovesUsed=t.setupMovesUsed+(summary.setupMovesUsed or 0)
  if summary.winConditionSpecies then
    t.repeatWinConditions[summary.winConditionSpecies]=
      (t.repeatWinConditions[summary.winConditionSpecies] or 0)+1
  end
end

-- The most-used move type across observed fights, or nil if nothing's
-- been observed yet (or the tracker was never engaged -- a save with no
-- behaviorTracker table is treated as "no data", not an error).
function PBT.dominantMoveType(save)
  local t=save.behaviorTracker
  if not t then return nil end
  local best,bestCount=nil,0
  for moveType,count in pairs(t.moveTypesUsed) do
    if count>bestCount then best,bestCount=moveType,count end
  end
  return best
end

-- A small [1-MAX_LEAN, 1+MAX_LEAN] multiplier for weighting a candidate
-- during generation: types the player has leaned on get a MILD bump for
-- an opponent building coverage/resistance against them (a defensive
-- reaction to observed play, not a counter-pick of the player's front-
-- line type), and only once fightIndex reaches ADAPTATION_START_FIGHT.
-- Never returns something outside [1-MAX_LEAN,1+MAX_LEAN] -- the hard
-- cap the doc requires ("must never become immediate psychic counter-
-- generation").
function PBT.typeLean(save,fightIndex,candidateType)
  if fightIndex<PBT.ADAPTATION_START_FIGHT then return 1.0 end
  local t=save.behaviorTracker
  if not t or t.fightsObserved==0 then return 1.0 end
  local dominant=PBT.dominantMoveType(save)
  if not dominant or candidateType~=dominant then return 1.0 end
  -- Ramps in gradually across the back half of the run rather than
  -- snapping to the full MAX_LEAN the instant fight 50 is reached.
  local progress=math.min(1,(fightIndex-PBT.ADAPTATION_START_FIGHT)/50)
  return 1.0+PBT.MAX_LEAN*progress
end

return PBT
