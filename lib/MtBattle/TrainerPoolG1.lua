-- Mt. Battle 100 Gen 1 synthetic trainer-slot pool.
--
-- Gen 1 requires a pre-registered trainer id before BattleState.newTrainer
-- can use it (BattleState.lua:854 asserts game.data.trainers[oppClass]),
-- and that registry freezes after mod-load (src/mods/Registry.lua:38,275)
-- -- so a run's 100 rosters, generated from a seed rolled at BEGIN
-- CHALLENGE (long after boot), cannot be registered as they're needed.
-- Workaround, verified end-to-end in Phase 0 Spike 6 against the real
-- engine mod-loading SDK: pre-register 100 generic trainer-id "slots" at
-- mod-load time, each with a pre-baked AI difficulty tier (aiClass/aiMods
-- are STATIC per BattleState.newTrainer's `self.enemyAIMods=self.trainer.
-- aiMods` -- confirmed NOT hook-overridable), and rewrite each slot's
-- PARTY at battle-construction time via the already-existing
-- `trainer.party` hook.
local V=... or {}
local Difficulty=V.MtBattleDifficulty
local GenerationCompat=V.GenerationCompat
local G1={}

G1.SLOT_COUNT=100
G1.SLOT_PREFIX="MTB_G1_"
G1.LEVEL_LOCK=50

-- `trainer.party` is the final Gen-1 seam before BattleState expands raw rows
-- with Pokemon.new(data,species,slot.level).  Persisted encounters from older
-- builds are hostile input here: a stale level must never become a live Mt.
-- Battle opponent.  Return a detached row array so enforcing the lock does not
-- mutate SaveState.currentEncounter, its species order, moves, shiny metadata,
-- or any other persisted encounter identity.
function G1.levelLockedRoster(roster)
  if type(roster)~="table" then return roster end
  local out={}
  for i,row in ipairs(roster) do
    if type(row)=="table" then
      local copy={}
      for k,v in pairs(row) do copy[k]=v end
      copy.level=G1.LEVEL_LOCK
      out[i]=copy
    else
      out[i]=row
    end
  end
  return out
end

function G1.slotId(fightIndex)
  return G1.SLOT_PREFIX..string.format("%03d",fightIndex)
end

function G1.fightIndexOf(oppClass)
  if type(oppClass)~="string" then return nil end
  local n=oppClass:match("^"..G1.SLOT_PREFIX.."(%d%d%d)$")
  return n and tonumber(n) or nil
end

-- BattleLauncher.lua calls this once, before launching any Gen 1 fight,
-- to hand the pool a way to answer "what roster does slot N actually
-- fight with right now" -- kept as an indirection (a settable provider
-- function) rather than baking RunController/SaveState access directly
-- into this file, so TrainerPoolG1.lua stays a pure registration+hook
-- module with no run-state dependency of its own.
--   provider: function(fightIndex) -> partyDef rows, or nil to decline
--     (falls through to the placeholder party -- should not happen once
--     BattleLauncher is wired up, but never crashes if it does)
function G1.setRosterProvider(fn)
  G1.rosterProvider=fn
end

-- Registers the 5 AI-difficulty ai_classes tiers and the 100 trainer
-- slots. MUST be called EXACTLY ONCE, from the mod's top-level script --
-- never from installRuntime(), which re-runs on mods.loaded and would
-- hit Registry's "already registered" rejection (record semantics,
-- confirmed live in Spike 6) on the second call.
--   placeholderSpecies: a species id guaranteed to exist in the real
--     merged pokemon registry -- only ever seen if the trainer.party hook
--     somehow declines (should not happen in normal operation), so its
--     choice has no gameplay impact, but it DOES need to validate at
--     mod-load time (Schemas.lua's parties field checks species
--     existence). Callers in a real game should pass a real starter-tier
--     species id; headless tests pass a fixture species instead.
function G1.install(mod,placeholderSpecies)
  -- This pool exists only because Gen 1's BattleState.newTrainer requires a
  -- pre-registered trainer id. Gen 2 (Gold/Crystal-class hosts) constructs the
  -- Mt. Battle trainer inline and its `trainers` registry has a different class
  -- schema (`trainers={...}` rather than Gen 1's `parties={...}`). Registering
  -- MTB_G1_* on a Gen 2 host therefore cannot be useful and is a schema error.
  if GenerationCompat and type(GenerationCompat.current)=="function" then
    local ok,generation=pcall(GenerationCompat.current)
    if ok and tonumber(generation)==2 then return false,"gen1-only" end
  end
  if G1.installed then return end
  G1.installed=true
  placeholderSpecies=placeholderSpecies or "FIXMON_A"

  for _,tier in ipairs(Difficulty.TIERS) do
    mod.content.ai_classes:register(tier.id,tier.gen1Class)
    -- Combined tier x personality variants (supplemental design doc's
    -- trainer-personality system): 5 tiers x 6 personalities = 30
    -- pre-registered ai_classes. A trainer SLOT's registered aiClass
    -- above is only ever a fallback default -- BattleLauncher.lua swaps
    -- each fight's REGISTERED trainer record to point at the run's
    -- seed-chosen combined id for the duration of that one launch, then
    -- restores it, since which personality a given fight gets is a
    -- per-RUN decision made long after this mod-load-time registration
    -- (record semantics forbid registering NEW ids mid-run -- confirmed
    -- live in Phase 0 Spike 6 -- so every combination that could ever be
    -- needed is pre-registered once, and only the trainer record's
    -- POINTER to one of them changes per launch).
    for _,personality in ipairs(Difficulty.PERSONALITIES) do
      local combinedId=Difficulty.combinedAiClassId(tier.id,personality.id)
      mod.content.ai_classes:register(combinedId,Difficulty.combinedGen1Class(tier,personality))
    end
  end

  for i=1,G1.SLOT_COUNT do
    local tier=Difficulty.tierFor(i)
    local record={
      id=G1.slotId(i),name="MT. BATTLE",
      aiClass=tier.id,aiMods=tier.aiMods,
      parties={{{species=placeholderSpecies,level=50}}},
    }
    -- Trainer #100: opt into the existing BossIntro cinematic for free
    -- (lib/BossIntro.lua:20 B.classify reads trainer.cbeBossIntro/
    -- cbeBossCategory directly off the battle's registered trainer
    -- record -- confirmed live in Phase 0 Spike 7). B.begin ALSO requires
    -- game.save.colosseumBattle.bossIntroEnabled==true, which is
    -- HubStage/RunController's responsibility to set for this one fight
    -- (not this module's -- registration has no save/game access).
    if i==G1.SLOT_COUNT then
      record.cbeBossIntro=true
      record.cbeBossCategory="champion"
    end
    mod.content.trainers:register(G1.slotId(i),record)
  end

  mod.hooks:wrap("trainer.party",function(next,oppClass,partyIndex,party)
    local fightIndex=G1.fightIndexOf(oppClass)
    if fightIndex and G1.rosterProvider then
      local roster=G1.rosterProvider(fightIndex)
      if roster then return G1.levelLockedRoster(roster) end
    end
    return next(oppClass,partyIndex,party)
  end,100,"mtbattle")
end

return G1
