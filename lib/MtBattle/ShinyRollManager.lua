-- Mt. Battle 100 shiny determination -- per the supplemental design doc:
-- every Area Leader (every 10th trainer) has exactly one guaranteed
-- shiny ace; every OTHER enemy Pokemon (Area Leader or not) independently
-- rolls a deterministic 1/2048 shiny chance. Shininess is cosmetic only
-- (no stat/move/ability/XP/AI/damage effect) -- this module only decides
-- true/false per roster slot; applying it to the actual mon
-- (Gen1: a post-construction battle.enemyParty[i].shiny=true;
-- Gen2: Mon.new's opts.shiny, both confirmed real fields this mod's own
-- rendering layer already reads -- lib/CurrentSpriteModels.lua:511
-- `mon and mon.shiny and "shiny" or "normal"`, generation-agnostic) is
-- TeamGenGen1/2.lua's job.
--
-- Determinism: every roll consumes exactly one draw from the FIGHT's own
-- seeded stream (SeedManager.newStream(subSeed)), in the SAME fixed call
-- order every other generation step already uses -- so "Continues/
-- reloads never reroll an encounter" automatically extends to shininess
-- too, with no separate persistence needed beyond the already-persisted
-- roster (a shiny flag lives on the persisted row/mon, same as species
-- and moves).
local SRM={}

SRM.SHINY_ODDS=1/2048

-- One roll, one stream draw. Call this in a FIXED position in the
-- generation call order for every non-ace slot -- never skip a draw
-- conditionally, or every later draw in that fight desyncs from what a
-- re-run of the same seed would produce.
function SRM.rollNormal(stream)
  return stream:nextFloat()<SRM.SHINY_ODDS
end

-- Picks which roster slot(s) become guaranteed shiny aces: "the most
-- strategically appropriate team member(s)" per the doc, operationalized
-- as the member(s) filling the archetype's OWN signature roles --
-- roles[1], roles[2], ... in Archetypes.ARCHETYPES' already-curated,
-- priority-ordered role list (e.g. hyper_offense's first role is
-- "sweeper", stall's is "wall") -- rather than an arbitrary/random pick,
-- so each ace is thematically one of the team's centerpieces, not
-- incidental. `roleOfSlot(i)` maps roster slot i -> its assigned role
-- (both TeamGenGen1/2 already compute this per-slot via
-- archetype.roles[((i-1)%#archetype.roles)+1] during buildRoster).
-- Returns an array of up to `n` DISTINCT slot indices, in ace-priority
-- order (first entry is the primary ace, matching the pre-existing
-- single-ace behavior exactly when n==1).
function SRM.chooseAceSlots(rosterSize,archetype,roleOfSlot,n)
  n=math.max(0,math.min(math.floor(n or 1),rosterSize))
  local chosen,taken={},{}
  for k=1,n do
    local wantRole=archetype.roles[k] or archetype.roles[1]
    local slot=nil
    for i=1,rosterSize do
      if not taken[i] and roleOfSlot(i)==wantRole then slot=i;break end
    end
    if not slot then
      -- Signature role for this ace slot is unavailable (already taken by
      -- an earlier ace, or this archetype/roster doesn't have it) --
      -- degenerate fallback: designate the first remaining slot, same
      -- spirit as the original single-ace fallback ("an empty/unusual
      -- roster still designates SOMEONE").
      for i=1,rosterSize do
        if not taken[i] then slot=i;break end
      end
    end
    if slot then chosen[#chosen+1]=slot;taken[slot]=true end
  end
  return chosen
end

-- Single-ace convenience wrapper, kept for existing callers/tests --
-- identical to chooseAceSlots(...,1)[1].
function SRM.chooseAceSlot(rosterSize,archetype,roleOfSlot)
  return SRM.chooseAceSlots(rosterSize,archetype,roleOfSlot,1)[1]
end

-- Full per-roster shininess assignment: returns an array of booleans,
-- index i = whether roster slot i is shiny. Consumes exactly rosterSize
-- stream draws (one per non-ace slot; ace slots consume none -- they're
-- an assignment, not a roll) in slot order, so the deferred call order
-- stays simple and auditable.
--   aceCount: how many guaranteed shiny aces this fight gets (0 for a
--     normal fight, 1 for a standard Area Leader, 2 for fight 100 --
--     see SpecialFights.aceCountFor; the caller decides this, not SRM).
-- Returns shiny, firstAceSlot (nil if aceCount==0, backward compatible
-- with the pre-multi-ace single-aceSlot callers/records), allAceSlots
-- (always an array, possibly empty).
function SRM.assign(stream,rosterSize,aceCount,archetype,roleOfSlot)
  local shiny={}
  local aceSlots={}
  if aceCount and aceCount>0 then
    aceSlots=SRM.chooseAceSlots(rosterSize,archetype,roleOfSlot,aceCount)
  end
  local aceSet={}
  for _,slot in ipairs(aceSlots) do aceSet[slot]=true end
  for i=1,rosterSize do
    if aceSet[i] then shiny[i]=true
    else shiny[i]=SRM.rollNormal(stream) end
  end
  return shiny,aceSlots[1],aceSlots
end

return SRM
