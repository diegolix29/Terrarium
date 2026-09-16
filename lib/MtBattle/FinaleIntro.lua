-- Mt. Battle 100 Trainer #100 finale: opts fight 100 into the existing
-- BossIntro cinematic (verified live in Phase 0 Spike 7 -- trainer.
-- cbeBossIntro=true + cbeBossCategory="champion" is sufficient, no new
-- choreography code needed) and ensures its two extra preconditions are
-- met (game.save.colosseumBattle.bossIntroEnabled==true, and a live
-- StandaloneHost session matching the battle -- the latter is satisfied
-- automatically once BattleLauncher's real battle.started fires, per
-- StandaloneHost's own auto-attach behavior).
--
-- Gen 1's boss-classification fields are baked into the TrainerPoolG1
-- registration for slot 100 already (TrainerPoolG1.lua's install loop);
-- this module owns the save-preference toggle (both gens) and the Gen 2
-- inline trainerMeta fields (Battle.new's trainer table has no
-- pre-registration step to bake them into ahead of time).
local FI={}

FI.FINALE_FIGHT=100

-- Temporarily forces bossIntroEnabled on for the duration of fight 100,
-- returning a restore() closure -- mirrors HubStage.forcePresentation's
-- exact pattern (read-modify-write game.save.colosseumBattle, remember
-- the original, hand back a restore function) rather than a second
-- copy of the same idiom.
function FI.forceBossIntro(game)
  local prefs=game and game.save and game.save.colosseumBattle
  if type(prefs)~="table" then return function() end end
  local original=prefs.bossIntroEnabled
  prefs.bossIntroEnabled=true
  return function() prefs.bossIntroEnabled=original end
end

-- trainerMeta fields to merge into BattleLauncher.launchGen2's inline
-- trainer table for fight 100 specifically -- Gen 2's Battle.new has no
-- pre-registration step, so these can't be baked in ahead of time the
-- way TrainerPoolG1 does for Gen 1.
function FI.gen2TrainerMeta(baseMeta)
  local meta={}
  for k,v in pairs(baseMeta or {}) do meta[k]=v end
  meta.cbeBossIntro=true
  meta.cbeBossCategory="champion"
  return meta
end

function FI.isFinale(fightIndex)
  return fightIndex==FI.FINALE_FIGHT
end

return FI
