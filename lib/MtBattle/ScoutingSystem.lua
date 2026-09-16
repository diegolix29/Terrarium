-- Mt. Battle 100 Scouting (supplemental design doc, explicitly framed as
-- optional/future: "A future scouting layer may provide broad
-- information before an Area or major encounter... Do not reveal
-- complete teams or movesets. Scouting is optional and should be
-- balance-tested"). Built as a real module rather than left as a stub,
-- but Scouting itself is off by default, independently of the production
-- battle Ability system, and derives its
-- hints ONLY from information already decided by generation (archetype,
-- personality, isAreaLeader) -- it reveals no species, no moves, no
-- stats, and consumes NO additional stream draws (a scouted hint must
-- never perturb determinism: the encounter is generated identically
-- whether or not the player chooses to read a hint about it).
local SS={}

SS.DEFAULT_ENABLED=false

function SS.enabled(game)
  local prefs=game and game.save and game.save.colosseumBattle
  if type(prefs)~="table" or prefs.mtBattleScoutingEnabled==nil then return SS.DEFAULT_ENABLED end
  return prefs.mtBattleScoutingEnabled==true
end

function SS.setEnabled(game,value)
  if not (game and game.save) then return end
  game.save.colosseumBattle=game.save.colosseumBattle or {}
  game.save.colosseumBattle.mtBattleScoutingEnabled=value and true or false
end

-- Broad, non-specific hints per personality -- "increased status usage,
-- defensive tendencies, aggressive offense, or a general trainer
-- specialty" per the doc's own examples, one deliberately vague line
-- each, never naming a move, item, or species.
SS.PERSONALITY_HINTS={
  aggressive="This trainer presses the attack without much caution.",
  technical="This trainer reads matchups closely and switches with purpose.",
  defensive="This trainer plays a patient, defensive game.",
  disruptive="This trainer leans on status and battlefield control.",
  setup="This trainer looks to build an advantage before striking.",
  unpredictable="This trainer's approach is hard to read.",
}

SS.ARCHETYPE_HINTS={
  balanced="Their team looks well-rounded, with no obvious gap.",
  hyper_offense="Their team is built to end things quickly.",
  bulky_offense="Their team hits hard while shrugging off return fire.",
  stall="Their team is built to wear you down over time.",
  setup_sweep="Their team wants room to set up before sweeping.",
  speed_control="Their team pays close attention to who moves first.",
}

SS.AREA_LEADER_HINT="This is an Area Leader -- expect a stronger, more complete team."

-- Builds the hint set for one already-generated encounter. Returns nil
-- if scouting is disabled (the caller should not show a scouting screen
-- at all in that case) or if the encounter has no personality/archetype
-- to describe (shouldn't happen for a real Mt. Battle encounter, but
-- never errors on a partial/test encounter either).
function SS.hintsFor(game,encounter)
  if not SS.enabled(game) then return nil end
  if not encounter then return nil end
  local lines={}
  if encounter.personality and SS.PERSONALITY_HINTS[encounter.personality] then
    lines[#lines+1]=SS.PERSONALITY_HINTS[encounter.personality]
  end
  if encounter.archetype and SS.ARCHETYPE_HINTS[encounter.archetype] then
    lines[#lines+1]=SS.ARCHETYPE_HINTS[encounter.archetype]
  end
  if encounter.isAreaLeader then
    lines[#lines+1]=SS.AREA_LEADER_HINT
  end
  if #lines==0 then return nil end
  return lines
end

return SS
