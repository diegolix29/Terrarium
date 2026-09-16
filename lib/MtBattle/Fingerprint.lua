-- Mt. Battle 100 player-team fingerprint: analyzes the locked 6 into a
-- SOFT-INFLUENCE summary the generator leans on for archetype/type
-- leaning -- never a computed hard-counter (see the design's "Adaptation
-- vs. Counterpicking" requirement). Deliberately shallow for this pass:
-- types, rough offense/defense category split, and a few coarse
-- movepool tags (has-recovery, has-setup, has-status). Ability-aware
-- synergy remains explicitly outside this generator's scope; the production
-- battle Ability system is enabled independently and defaults ON.
local F={}

-- speciesRows: array of {species=, level=, moves={id,...}} for the 6
-- Level-50 clones (LevelClone.playerParty's output re-shaped, or fed
-- straight from the roster -- this function only reads species/moves).
function F.analyze(data,speciesRows)
  local out={
    types={},           -- type name -> count of team members carrying it
    stab={},            -- type name -> count of STAB-eligible moves of that type
    physical=0,special=0,status=0,
    hasRecovery=0,hasSetup=0,hasStatus=0,hasPriority=0,
    coverageTypes={},   -- every distinct attacking-move type present, regardless of STAB
  }
  for _,row in ipairs(speciesRows or {}) do
    local def=data.pokemon and data.pokemon[row.species]
    local memberTypes={}
    if def and def.types then
      for _,t in ipairs(def.types) do
        out.types[t]=(out.types[t] or 0)+1
        memberTypes[t]=true
      end
    end
    local recovery,setup,status=false,false,false
    for _,mv in ipairs(row.moves or {}) do
      local id=type(mv)=="table" and mv.id or mv
      local mdef=data.moves and data.moves[id]
      if mdef then
        local cat=mdef.category
        if cat=="physical" then out.physical=out.physical+1
        elseif cat=="special" then out.special=out.special+1
        elseif cat=="status" then out.status=out.status+1;status=true end
        if mdef.type and (mdef.power or 0)>0 then
          out.coverageTypes[mdef.type]=(out.coverageTypes[mdef.type] or 0)+1
          if memberTypes[mdef.type] then out.stab[mdef.type]=(out.stab[mdef.type] or 0)+1 end
        end
        if mdef.priority and mdef.priority>0 then out.hasPriority=out.hasPriority+1 end
        local eff=tostring(mdef.effect or "")
        if eff:find("HEAL") or eff=="recover" or eff:find("recover") then recovery=true end
        if eff:find("UP1") or eff:find("UP2") or eff:find("_up") then setup=true end
      end
    end
    if recovery then out.hasRecovery=out.hasRecovery+1 end
    if setup then out.hasSetup=out.hasSetup+1 end
    if status then out.hasStatus=out.hasStatus+1 end
  end
  return out
end

-- A soft "lean" list: types the player's team is UNDER-covered against
-- (no STAB answer among the 6), sorted by how exposed the gap is. This is
-- an INFLUENCE input to archetype/species weighting, never a target list
-- the generator is allowed to hard-counter with -- TeamGenGen1/2.lua must
-- only ever use this to nudge sampling weights, never to filter down to
-- "the one type that beats them."
function F.coverageGaps(fingerprint,allTypes)
  local gaps={}
  for _,t in ipairs(allTypes or {}) do
    if not fingerprint.stab[t] or fingerprint.stab[t]==0 then
      gaps[#gaps+1]=t
    end
  end
  return gaps
end

return F
