-- Mt. Battle 100 shared archetype catalog + move-safety policy +
-- anti-frustration composition caps. Single source of truth consumed by
-- both TeamGenGen1.lua and TeamGenGen2.lua.
--
-- MOVE SAFETY: this is a CURATED, conservative pool policy, not a strict
-- mirror of lib/doubles/NativeAdapter.lua's current `unsupported`/
-- `unsafeEffects` tables. Those tables were found (this session) to be
-- nearly empty right now -- Gen 1 doubles support is gated dynamically
-- instead, by inspecting each move's native effect record shape at
-- A:supports() call time (NativeAdapter.lua:213-223: an effect whose
-- record has callsMove/perform is refused; nothing else is statically
-- named). A parallel, unrelated effort (found in passing, a different
-- checkout at C:\Users\User\Documents\Codex\2026-09-08\i) is actively
-- working to unblock several of these same moves one at a time with their
-- own focused smoke tests. Given that moving target, Mt. Battle's own
-- generator intentionally stays conservative regardless of what the
-- engine currently permits: EXCLUDED here names mechanically complex
-- moves (turn-chaining, damage-reflection, move-copying, forced-switch,
-- full-copy/transform) that are a bad fit for a locked-stakes, no-reroll,
-- 100-fight gauntlet even when technically "supported" -- reliability
-- over movepool breadth. Call Archetypes.isMoveAllowed with a live
-- NativeAdapter instance (when available) for a second, dynamic check on
-- top of this static policy -- belt and suspenders, not either/or.
local A={}

-- Single source of truth for the excluded-move constant, generation-
-- agnostic move ids (both gens use the same uppercase ids for the moves
-- named here). Filtered out during MOVEPOOL CANDIDATE CONSTRUCTION in
-- TeamGenGen1/2.lua, never as a post-hoc validity check -- structurally
-- impossible for one of these to reach a generated roster.
A.EXCLUDED_MOVES={
  BIDE=true,COUNTER=true,MIRROR_COAT=true,MIRROR_MOVE=true,METRONOME=true,
  MIMIC=true,SLEEP_TALK=true,FUTURE_SIGHT=true,BATON_PASS=true,
  TRANSFORM=true,ATTRACT=true,PURSUIT=true,BEAT_UP=true,DESTINY_BOND=true,
  NIGHTMARE=true,SKETCH=true,ROAR=true,WHIRLWIND=true,TELEPORT=true,
  -- Gen I binding family: multi-turn trap damage with its own edge cases
  -- (partial-trap continuation across a KO/replacement).
  BIND=true,WRAP=true,FIRE_SPIN=true,CLAMP=true,
}

-- Optional dynamic second check: if a NativeAdapter-shaped object exposing
-- :supports(moveDef) is provided (the real lib/doubles/NativeAdapter.lua
-- instance for this fight's generation), consult it too. A move that
-- fails EITHER check is excluded. `adapter` is optional specifically so
-- TeamGenGen1/2's own headless tests can call this without constructing a
-- full doubles kernel.
function A.isMoveAllowed(moveId,moveDef,adapter)
  if not moveId or A.EXCLUDED_MOVES[moveId] then return false end
  if adapter and type(adapter.supports)=="function" then
    local ok=adapter:supports(moveDef)
    if not ok then return false end
  end
  return true
end

-- Effect-name taxonomies for the anti-frustration caps. Generation-aware:
-- Gen 1 move data uses the retro effect-constant names (SLEEP_EFFECT,
-- ATTACK_DOWN1_EFFECT, ...), Gen 2 uses the EFFECT_XXX convention
-- (verified directly against src/battle/TrainerAI.lua's STATUS_EFFECTS/
-- ENCOURAGE_EFFECTS and src/battle/gen2/Ai.lua's STALL_EFFECTS/
-- STATUS_EFFECTS -- these ARE the authoritative taxonomies, not a
-- hand-rolled list, per the plan).
A.STATUS_EFFECTS={
  [1]={SLEEP_EFFECT=true,POISON_EFFECT=true,PARALYZE_EFFECT=true,
       POISON_SIDE_EFFECT1=true,POISON_SIDE_EFFECT2=true,
       PARALYZE_SIDE_EFFECT=true,PARALYZE_SIDE_EFFECT2=true,
       BURN_SIDE_EFFECT1=true,BURN_SIDE_EFFECT2=true,
       FREEZE_SIDE_EFFECT=true,CONFUSION_EFFECT=true,
       CONFUSION_SIDE_EFFECT=true},
  [2]={poison=true,paralyze=true,sleep=true,burn=true,freeze=true,confuse=true},
}
A.EVASION_EFFECTS={
  [1]={EVASION_UP1_EFFECT=true,EVASION_UP2_EFFECT=true},
  [2]={evasion_up=true},
}
-- Stall/residual/recovery-heavy effects (the composition axis most likely
-- to produce a tedious, RNG-dominated grind if stacked across a whole
-- team) -- mirrors src/battle/gen2/Ai.lua's STALL_EFFECTS/RESIDUAL_EFFECTS
-- taxonomy shape for Gen 2; Gen 1 has no equivalent named table so this
-- is the closest matching set of retro effect names.
A.STALL_EFFECTS={
  [1]={HEAL_EFFECT=true,LEECH_SEED_EFFECT=true,TOXIC_EFFECT=true},
  [2]={recover=true,leech_seed=true,toxic=true,rest=true,ingrain=true},
}

-- Hard per-team caps (not a scored/weighted validator -- see the plan's
-- "generator scope" section for why a threshold check is the right size
-- for an initial buildable version). A generated roster whose OWN moves
-- (across all its members) exceed any cap is rejected by the generator
-- and re-rolled from the same RNG stream, never silently shipped.
A.FRUSTRATION_CAPS={
  statusMovesPerTeam=3,
  evasionMovesPerTeam=1,
  stallMovesPerTeam=3,
}

function A.effectCategory(taxonomy,generation,effectId)
  local set=taxonomy[generation]
  return set and effectId and set[effectId]==true
end

-- Named archetypes: each is a data record (role-slot tendencies + a soft
-- typing lean), never structural logic -- kept as plain data so the
-- catalog can be tuned without touching generator code. `roles` is a
-- weighted bag TeamGenGen1/2.lua samples from when assigning each roster
-- slot a job before picking a species for it.
A.ARCHETYPES={
  {id="balanced",label="Balanced",
   roles={"sweeper","wall","support","revenge_killer","pivot","cleric"}},
  {id="hyper_offense",label="Hyper Offense",
   roles={"sweeper","sweeper","wallbreaker","suicide_lead","sweeper"}},
  {id="bulky_offense",label="Bulky Offense",
   roles={"bulky_attacker","wallbreaker","pivot","sweeper","wall"}},
  {id="stall",label="Stall",
   roles={"wall","wall","cleric","support","phazer"}},
  {id="setup_sweep",label="Setup Sweep",
   roles={"setup_sweeper","support","wall","pivot","setup_sweeper"}},
  {id="speed_control",label="Speed Control",
   roles={"speed_control","sweeper","pivot","wall","support"}},
}

-- Deterministic archetype pick from a seeded stream (RunSeedManager's
-- per-fight stream, so this consumes the FIRST draw in the fight's fixed
-- call order -- see the plan's RunSeedManager section on draw-order
-- determinism).
function A.pickArchetype(stream)
  return stream:pick(A.ARCHETYPES)
end

return A
