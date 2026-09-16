-- Mt. Battle 100 difficulty curve: fight index (1-100) -> AI-difficulty
-- budget, for both gens' native AI configurability (confirmed real and
-- previously unused by this mod -- src/battle/TrainerAI.lua's aiClass/
-- aiMods for Gen 1, src/battle/gen2/Ai.lua's FLAGS bit-field for Gen 2).
-- All-data, no structural logic, specifically so the curve can be tuned
-- without touching generator/launcher code (see the plan's explicit
-- "keep balance-sensitive values centralized" requirement).
local D={}

-- Five discrete tiers rather than 100 unique configs -- Gen 1 needs a
-- registered ai_classes RECORD per distinct config (TrainerPoolG1.lua
-- registers these five once, at mod-load time, and every trainer slot's
-- aiClass field references one by id); Gen 2's attributes bytes are
-- per-trainer-record anyway so a tier's flags/switch bytes get baked
-- directly into each of the 100 registered records.
D.TIERS={
  {id="MTB_AI_T1",band={1,20},label="Strong",
   aiMods={3},                                   -- Gen1 TrainerAI.LAYERS: type-effectiveness awareness only
   -- uses=0: per data/scripts/ai_classes.lua's shape, 0 uses means the
   -- item branch never triggers -- matches "battles 1-40: generally none".
   gen1Class={uses=0,switchChance=0,chance=64,hpBelow=2,item=nil},
   gen2Flags={"BASIC","TYPES"},gen2SwitchLo=20,gen2SwitchHi=0,
   itemChance=0.0,rosterMin=6,rosterMax=6,optimizationAttempts=3,
   movePowerTarget=65,moveSearchJitter=1.45,
   powerCenter=360,powerSpread=80,powerFloor=275,
   archetypeWeights={balanced=1.45,hyper_offense=.95,bulky_offense=1.20,stall=.55,setup_sweep=.75,speed_control=.75}},
  {id="MTB_AI_T2",band={21,40},label="Difficult",
   aiMods={1,3},
   gen1Class={uses=0,switchChance=20,chance=96,hpBelow=3,item=nil},
   gen2Flags={"BASIC","TYPES","OFFENSIVE"},gen2SwitchLo=40,gen2SwitchHi=0,
   itemChance=0.0,rosterMin=6,rosterMax=6,optimizationAttempts=4,
   movePowerTarget=75,moveSearchJitter=.95,
   powerCenter=395,powerSpread=75,powerFloor=310,
   archetypeWeights={balanced=1.30,hyper_offense=1.00,bulky_offense=1.20,stall=.70,setup_sweep=.90,speed_control=.90}},
  {id="MTB_AI_T3",band={41,60},label="Highly coordinated",
   aiMods={1,2,3},
   gen1Class={uses=1,switchChance=30,chance=128,hpBelow=3,item="POTION"},
   gen2Flags={"BASIC","TYPES","OFFENSIVE","SMART"},gen2SwitchLo=60,gen2SwitchHi=0,
   itemChance=0.15,rosterMin=6,rosterMax=6,optimizationAttempts=5,
   movePowerTarget=85,moveSearchJitter=.55,
   powerCenter=430,powerSpread=70,powerFloor=350,
   archetypeWeights={balanced=1.15,hyper_offense=1.05,bulky_offense=1.15,stall=.85,setup_sweep=1.05,speed_control=1.05}},
  {id="MTB_AI_T4",band={61,80},label="Heavily optimized",
   aiMods={1,2,3},
   gen1Class={uses=2,switchChance=40,chance=160,hpBelow=4,item="SUPER_POTION"},
   gen2Flags={"BASIC","TYPES","OFFENSIVE","SMART","OPPORTUNIST","AGGRESSIVE"},
   gen2SwitchLo=80,gen2SwitchHi=0,
   itemChance=0.3,rosterMin=6,rosterMax=6,optimizationAttempts=6,
   movePowerTarget=95,moveSearchJitter=.22,
   powerCenter=465,powerSpread=65,powerFloor=390,
   archetypeWeights={balanced=1.05,hyper_offense=1.10,bulky_offense=1.10,stall=1.00,setup_sweep=1.15,speed_control=1.15}},
  {id="MTB_AI_T5",band={81,100},label="Brutal / maximum",
   aiMods={1,2,3},
   gen1Class={uses=3,switchChance=50,chance=200,hpBelow=5,item="FULL_RESTORE"},
   gen2Flags={"BASIC","TYPES","OFFENSIVE","SMART","OPPORTUNIST","AGGRESSIVE","CAUTIOUS","RISKY"},
   gen2SwitchLo=100,gen2SwitchHi=0,
   itemChance=0.5,rosterMin=6,rosterMax=6,optimizationAttempts=7,
   movePowerTarget=110,moveSearchJitter=.04,
   powerCenter=500,powerSpread=60,powerFloor=425,
   archetypeWeights={balanced=1.00,hyper_offense=1.15,bulky_offense=1.10,stall=1.10,setup_sweep=1.20,speed_control=1.25}},
}

-- Trainer AI personalities (supplemental design doc): flavor layered ON
-- TOP of a fight's difficulty tier, never replacing it. Gen 1's AI system
-- is genuinely limited to 3 scoring layers (TrainerAI.LAYERS) plus
-- aiClass item-use tuning -- confirmed by direct read, no 4th layer
-- exists to invent -- so personality differentiation there is coarser
-- than Gen 2's richer 10-flag bit field; this is an honest reflection of
-- that real constraint, not a shortcut. "Unpredictable" maps to an EMPTY
-- Gen1 aiMods list and Gen2 flags=0 quite precisely on purpose: Ai.lua's
-- own header comment states a class with no flags "simply picks at
-- random," which IS "more variation among similarly valued decisions"
-- -- a real engine behavior, not an invented one.
D.PERSONALITIES={
  {id="aggressive",label="Aggressive",
   gen1Mods={3},gen1ClassDelta={switchChance=-10,chance=32},
   gen2Flags={"OFFENSIVE","AGGRESSIVE"}},
  {id="technical",label="Technical",
   gen1Mods={1,2,3},gen1ClassDelta={switchChance=15,chance=0},
   gen2Flags={"SMART","OPPORTUNIST","TYPES"}},
  {id="defensive",label="Defensive",
   gen1Mods={1,3},gen1ClassDelta={switchChance=20,chance=48,hpBelowDelta=1},
   gen2Flags={"CAUTIOUS","BASIC"}},
  {id="disruptive",label="Disruptive",
   gen1Mods={1},gen1ClassDelta={switchChance=5,chance=64},
   gen2Flags={"STATUS","BASIC"}},
  {id="setup",label="Setup-Oriented",
   gen1Mods={2,3},gen1ClassDelta={switchChance=-15,chance=16},
   gen2Flags={"SETUP","OFFENSIVE"}},
  {id="unpredictable",label="Unpredictable",
   gen1Mods={},gen1ClassDelta={switchChance=0,chance=0},
   gen2Flags={}},
}

function D.personalityFor(index)
  local n=#D.PERSONALITIES
  return D.PERSONALITIES[((index-1)%n)+1]
end

-- Combined Gen1 ai_classes id for one (tier,personality) pair -- what
-- TrainerPoolG1.lua pre-registers 30 of (5 tiers x 6 personalities) at
-- mod-load time, and what BattleLauncher.lua's per-fight aiClass swap
-- points a trainer record at for the duration of one launch.
function D.combinedAiClassId(tierId,personalityId)
  return tierId.."_"..personalityId
end

-- Merges a tier's base gen1Class record with a personality's delta into
-- one full ai_classes record (uses/item/hpBelow come from the tier;
-- switchChance/chance are personality-adjusted, clamped to the
-- documented 0..256 range).
function D.combinedGen1Class(tier,personality)
  local base=tier.gen1Class
  local delta=personality.gen1ClassDelta or {}
  local out={}
  for k,v in pairs(base) do out[k]=v end
  out.switchChance=math.max(0,math.min(256,(base.switchChance or 0)+(delta.switchChance or 0)))
  out.chance=math.max(0,math.min(256,(base.chance or 0)+(delta.chance or 0)))
  if delta.hpBelowDelta then out.hpBelow=math.max(1,(base.hpBelow or 1)+delta.hpBelowDelta) end
  return out
end

-- Merges a tier's Gen2 flag list with a personality's flags (union, no
-- duplicates) for D.gen2Attributes to encode.
function D.combinedGen2Flags(tier,personality)
  local seen,out={},{}
  for _,name in ipairs(tier.gen2Flags or {}) do
    if not seen[name] then seen[name]=true;out[#out+1]=name end
  end
  for _,name in ipairs(personality.gen2Flags or {}) do
    if not seen[name] then seen[name]=true;out[#out+1]=name end
  end
  return out
end

function D.tierFor(fightIndex)
  for _,tier in ipairs(D.TIERS) do
    if fightIndex>=tier.band[1] and fightIndex<=tier.band[2] then return tier end
  end
  return D.TIERS[#D.TIERS]
end

-- Gen2's attributes array is {item1,item2,baseMoney,aiLo,aiHi,switchLo,
-- switchHi,pad} (Ai.flagsOf's own documented layout). Builds the raw byte
-- array from a tier's named flag list + switch bytes.
function D.gen2Attributes(tier,item1,item2,baseMoney,AiFlags)
  local word=0
  for _,name in ipairs(tier.gen2Flags or {}) do
    word=word+(AiFlags[name] or 0)
  end
  local lo=word%256
  local hi=math.floor(word/256)%256
  return {item1 or 0,item2 or 0,baseMoney or 0,lo,hi,tier.gen2SwitchLo or 0,tier.gen2SwitchHi or 0,0}
end

return D
