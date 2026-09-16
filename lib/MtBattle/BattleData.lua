-- Mt. Battle challenge-local data projection.
--
-- The host's native Data tables are immutable inputs here.  A Gen-1 save may
-- only contain Kanto species, but GC6E01 PokemonStats contains mechanics rows
-- for National Dex 001-386.  Build a private per-game view that adds only the
-- missing species and source-core move fields needed by Mt. Battle.  Nothing is
-- registered into game.data and nothing in the save/Pokedex is touched.
local V=... or {}
local Source=V.ColosseumPokemonMoveData
local Names=V.ColosseumDexNames or {}
local MoveCatalog=V.ColosseumMoveCatalog
local req=V.engineRequire or require
local BD={MAX_DEX=386}

-- High-frequency GC6E01 moves that are absent from the Red host but whose
-- *move-specific* mechanics are source-proven end-to-end at the Mt. Battle
-- adapter seams.  These rows are challenge-local only: ordinary game.data,
-- saves, Pokedex identity and the global move registry are never touched.
--
-- The shared Red damage kernel (critical/random/final-damage rules) remains a
-- separately tracked Mt. Battle parity blocker. `sourceProven` below certifies
-- only the move-owned CommonMoveData flags, hit check, effect phase/chance and
-- Substitute/ability cadence; every emitted definition explicitly marks full
-- execution exactness false until the shared damage kernel reaches GC6E01.
local GEN1_SOURCE_MOVES={
  -- Gen-I Mt. Battle clones have no held-Pokemon item identity.  Retail Thief's
  -- effect 105 therefore has no reachable steal target in this challenge ruleset;
  -- its exact reachable behavior is the source Dark-type damaging hit.
  [168]={name="Thief",effectName="NO_ADDITIONAL_EFFECT",sourceProven=true,
    source={priority=0,pp=10,typeId=17,target=0,accuracy=100,effectChance=100,makesContact=1,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=0,soundBased=0,power=40,effect=105}},
  [178]={name="Cotton Spore",effectName="CBE_G3_SPEED_DOWN2",sourceProven=true,
    source={priority=0,pp=40,typeId=12,target=0,accuracy=85,effectChance=0,makesContact=0,
      blockedByProtect=1,magicCoatReflects=1,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=0,soundBased=0,power=0,effect=60}},
  [184]={name="Scary Face",effectName="CBE_G3_SPEED_DOWN2",sourceProven=true,
    source={priority=0,pp=10,typeId=0,target=0,accuracy=90,effectChance=0,makesContact=0,
      blockedByProtect=1,magicCoatReflects=1,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=0,soundBased=0,power=0,effect=60}},
  [224]={name="Megahorn",effectName="NO_ADDITIONAL_EFFECT",sourceProven=true,
    source={priority=0,pp=10,typeId=6,target=0,accuracy=85,effectChance=0,makesContact=1,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=1,soundBased=0,power=120,effect=0}},
  [231]={name="Iron Tail",effectName="DEFENSE_DOWN_HIT_G3",sourceProven=true,
    source={priority=0,pp=15,typeId=8,target=0,accuracy=75,effectChance=30,makesContact=1,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=0,soundBased=0,power=100,effect=69}},
  [246]={name="AncientPower",effectName="CBE_G3_ALL_UP_HIT",sourceProven=true,
    source={priority=0,pp=5,typeId=5,target=0,accuracy=100,effectChance=10,makesContact=1,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=0,soundBased=0,power=60,effect=140}},
  [249]={name="Rock Smash",effectName="DEFENSE_DOWN_HIT_G3",sourceProven=true,
    source={priority=0,pp=15,typeId=1,target=0,accuracy=100,effectChance=50,makesContact=1,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=0,soundBased=0,power=20,effect=69}},
  [263]={name="Facade",effectName="CBE_G3_FACADE",sourceProven=true,
    source={priority=0,pp=20,typeId=0,target=0,accuracy=100,effectChance=0,makesContact=1,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=0,soundBased=0,power=70,effect=169}},
  [280]={name="Brick Break",effectName="CBE_G3_BRICK_BREAK",sourceProven=true,
    source={priority=0,pp=15,typeId=1,target=0,accuracy=100,effectChance=0,makesContact=1,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=1,soundBased=0,power=75,effect=186}},
  [306]={name="Crush Claw",effectName="DEFENSE_DOWN_HIT_G3",sourceProven=true,
    source={priority=0,pp=10,typeId=0,target=0,accuracy=95,effectChance=50,makesContact=1,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=0,soundBased=0,power=75,effect=69}},
  [309]={name="Meteor Mash",effectName="CBE_G3_ATTACK_UP_HIT",sourceProven=true,
    source={priority=0,pp=10,typeId=8,target=0,accuracy=85,effectChance=20,makesContact=1,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=1,soundBased=0,power=100,effect=139}},
  [317]={name="Rock Tomb",effectName="SPEED_DOWN_HIT_G3",sourceProven=true,
    source={priority=0,pp=10,typeId=5,target=0,accuracy=80,effectChance=100,makesContact=0,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=0,soundBased=0,power=50,effect=70}},
  [318]={name="Silver Wind",effectName="CBE_G3_ALL_UP_HIT",sourceProven=true,
    source={priority=0,pp=5,typeId=6,target=0,accuracy=100,effectChance=10,makesContact=0,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=1,soundBased=0,power=60,effect=140}},
  [324]={name="Signal Beam",effectName="CONFUSION_HIT_G3",sourceProven=true,
    source={priority=0,pp=15,typeId=6,target=0,accuracy=100,effectChance=10,makesContact=0,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=1,soundBased=0,power=75,effect=76}},
  -- These self-buffs are Snatchable in CommonMoveData. Snatch itself remains
  -- fail-closed on the Gen-I challenge kernel, so their ordinary execution is
  -- exact only while raw 289 is unavailable. projectedMoves enforces that
  -- reachability invariant; if a future bridge graduates Snatch first, these
  -- rows disappear until interception is implemented too.
  [334]={name="Iron Defense",effectName="DEFENSE_UP2_EFFECT",sourceProven=true,requiresUnavailableRaw=289,
    source={priority=0,pp=15,typeId=8,target=5,accuracy=0,effectChance=0,makesContact=0,
      blockedByProtect=0,magicCoatReflects=0,snatchSteals=1,mirrorMoveCopies=0,
      kingsRockFlinch=0,soundBased=0,power=0,effect=51}},
  [339]={name="Bulk Up",effectName="CBE_G3_BULK_UP",sourceProven=true,requiresUnavailableRaw=289,
    source={priority=0,pp=20,typeId=1,target=5,accuracy=0,effectChance=0,makesContact=0,
      blockedByProtect=0,magicCoatReflects=0,snatchSteals=1,mirrorMoveCopies=0,
      kingsRockFlinch=0,soundBased=0,power=0,effect=208}},
  [341]={name="Mud Shot",effectName="SPEED_DOWN_HIT_G3",sourceProven=true,
    source={priority=0,pp=15,typeId=4,target=0,accuracy=95,effectChance=100,makesContact=0,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=1,soundBased=0,power=55,effect=70}},
  [347]={name="Calm Mind",effectName="CBE_G3_CALM_MIND",sourceProven=true,requiresUnavailableRaw=289,
    source={priority=0,pp=20,typeId=14,target=5,accuracy=0,effectChance=0,makesContact=0,
      blockedByProtect=0,magicCoatReflects=0,snatchSteals=1,mirrorMoveCopies=0,
      kingsRockFlinch=0,soundBased=0,power=0,effect=211}},
  [349]={name="Dragon Dance",effectName="CBE_G3_DRAGON_DANCE",sourceProven=true,requiresUnavailableRaw=289,
    source={priority=0,pp=20,typeId=16,target=5,accuracy=0,effectChance=0,makesContact=0,
      blockedByProtect=0,magicCoatReflects=0,snatchSteals=1,mirrorMoveCopies=0,
      kingsRockFlinch=0,soundBased=0,power=0,effect=212}},
  [352]={name="Water Pulse",effectName="CONFUSION_HIT_G3",sourceProven=true,
    source={priority=0,pp=20,typeId=11,target=0,accuracy=100,effectChance=20,makesContact=0,
      blockedByProtect=1,magicCoatReflects=0,snatchSteals=0,mirrorMoveCopies=1,
      kingsRockFlinch=1,soundBased=0,power=60,effect=76}},
}

local GEN1_ACCURACY_STAGE={
  {33,100},{36,100},{43,100},{50,100},{60,100},{75,100},{1,1},
  {133,100},{166,100},{2,1},{233,100},{133,50},{3,1},
}

local function hostGeneration()
  local compat=V.GenerationCompat
  if compat and type(compat.current)=="function" then
    local ok,value=pcall(compat.current)
    if ok and tonumber(value) then return tonumber(value) end
  end
  return nil
end

local function sourceMoveMatches(raw,plan)
  local row=Source and Source.moves and Source.moves[raw]
  if type(row)~="table" or tonumber(row.rawMoveId)~=raw then return false end
  for key,value in pairs(plan.source or {}) do
    if tonumber(row[key])~=tonumber(value) then return false end
  end
  return true
end

local function abilityIs(battle,battler,id)
  local effects=V.AbilityEffectsGen1
  if effects and type(effects.hasAbility)=="function" then
    local ok,value=pcall(effects.hasAbility,battle,battler,id)
    if ok then return value==true end
  end
  local abilities=V.Abilities
  if abilities and type(abilities.current)=="function" and battler and battler.mon then
    local def=battle and battle.data and battle.data.pokemon and battle.data.pokemon[battler.mon.species]
    local dex=type(abilities.dexOf)=="function" and abilities.dexOf(battler.mon,def) or nil
    local ok,value=pcall(abilities.current,battle,battler.mon,dex)
    if ok then return value==id end
  end
  return false
end

local TYPE_NAMES={
  [0]="NORMAL",[1]="FIGHTING",[2]="FLYING",[3]="POISON",[4]="GROUND",
  [5]="ROCK",[6]="BUG",[7]="GHOST",[8]="STEEL",[10]="FIRE",
  [11]="WATER",[12]="GRASS",[13]="ELECTRIC",[14]="PSYCHIC_TYPE",
  [15]="ICE",[16]="DRAGON",[17]="DARK",
}
local TYPE_CATEGORY={
  NORMAL="physical",FIGHTING="physical",FLYING="physical",POISON="physical",
  GROUND="physical",ROCK="physical",BUG="physical",GHOST="physical",STEEL="physical",
  FIRE="special",WATER="special",GRASS="special",ELECTRIC="special",
  PSYCHIC_TYPE="special",ICE="special",DRAGON="special",DARK="special",
}

-- Pokemon Gold's complete 108-row type_matchups table, already carried by the
-- host's cartridge-oracle regression (tests/engine/gen2_type_chart_merge_bug1268.lua,
-- sourced from data/types/type_matchups.asm).  Gen III Colosseum uses this same
-- pre-Fairy 17-type effectiveness matrix.  Keeping it here avoids inventing a
-- neutral fallback for DARK/STEEL while also avoiding any mutation of the host
-- TypeChart data table.
local TYPE_ROWS_TEXT=[[
NORMAL ROCK 5
NORMAL STEEL 5
FIRE FIRE 5
FIRE WATER 5
FIRE GRASS 20
FIRE ICE 20
FIRE BUG 20
FIRE ROCK 5
FIRE DRAGON 5
FIRE STEEL 20
WATER FIRE 20
WATER WATER 5
WATER GRASS 5
WATER GROUND 20
WATER ROCK 20
WATER DRAGON 5
ELECTRIC WATER 20
ELECTRIC ELECTRIC 5
ELECTRIC GRASS 5
ELECTRIC GROUND 0
ELECTRIC FLYING 20
ELECTRIC DRAGON 5
GRASS FIRE 5
GRASS WATER 20
GRASS GRASS 5
GRASS POISON 5
GRASS GROUND 20
GRASS FLYING 5
GRASS BUG 5
GRASS ROCK 20
GRASS DRAGON 5
GRASS STEEL 5
ICE WATER 5
ICE GRASS 20
ICE ICE 5
ICE GROUND 20
ICE FLYING 20
ICE DRAGON 20
ICE STEEL 5
ICE FIRE 5
FIGHTING NORMAL 20
FIGHTING ICE 20
FIGHTING POISON 5
FIGHTING FLYING 5
FIGHTING PSYCHIC_TYPE 5
FIGHTING BUG 5
FIGHTING ROCK 20
FIGHTING DARK 20
FIGHTING STEEL 20
POISON GRASS 20
POISON POISON 5
POISON GROUND 5
POISON ROCK 5
POISON GHOST 5
POISON STEEL 0
GROUND FIRE 20
GROUND ELECTRIC 20
GROUND GRASS 5
GROUND POISON 20
GROUND FLYING 0
GROUND BUG 5
GROUND ROCK 20
GROUND STEEL 20
FLYING ELECTRIC 5
FLYING GRASS 20
FLYING FIGHTING 20
FLYING BUG 20
FLYING ROCK 5
FLYING STEEL 5
PSYCHIC_TYPE FIGHTING 20
PSYCHIC_TYPE POISON 20
PSYCHIC_TYPE PSYCHIC_TYPE 5
PSYCHIC_TYPE DARK 0
PSYCHIC_TYPE STEEL 5
BUG FIRE 5
BUG GRASS 20
BUG FIGHTING 5
BUG POISON 5
BUG FLYING 5
BUG PSYCHIC_TYPE 20
BUG GHOST 5
BUG DARK 20
BUG STEEL 5
ROCK FIRE 20
ROCK ICE 20
ROCK FIGHTING 5
ROCK GROUND 5
ROCK FLYING 20
ROCK BUG 20
ROCK STEEL 5
GHOST NORMAL 0
GHOST PSYCHIC_TYPE 20
GHOST DARK 5
GHOST STEEL 5
GHOST GHOST 20
DRAGON DRAGON 20
DRAGON STEEL 5
DARK FIGHTING 5
DARK PSYCHIC_TYPE 20
DARK GHOST 20
DARK DARK 5
DARK STEEL 5
STEEL FIRE 5
STEEL WATER 5
STEEL ELECTRIC 5
STEEL ICE 20
STEEL ROCK 20
STEEL STEEL 5
]]

local TYPE_ROWS={}
for a,d,m in TYPE_ROWS_TEXT:gmatch("([A-Z_]+)%s+([A-Z_]+)%s+(%d+)") do
  TYPE_ROWS[#TYPE_ROWS+1]={attacker=a,defender=d,multiplier=tonumber(m)}
end
local TYPE_RECORDS={}
for id,category in pairs(TYPE_CATEGORY) do TYPE_RECORDS[id]={id=id,name=id=="PSYCHIC_TYPE" and "PSYCHIC" or id,category=category} end

local function copyTable(src)
  local out={}
  for k,v in pairs(src or {}) do out[k]=v end
  return out
end

local function sourceReady()
  return type(Source)=="table" and Source.discId=="GC6E01"
    and type(Source.species)=="table" and type(Source.moves)=="table"
end

local function canonicalTypes(row)
  local ids=row and row.typeIds or nil
  local a=ids and TYPE_NAMES[tonumber(ids[1])] or nil
  local b=ids and TYPE_NAMES[tonumber(ids[2])] or nil
  if not a or not b then return nil end
  if a==b then return {a} end
  return {a,b}
end

local function rawMoveMap(moves)
  local out={}
  for id,def in pairs(moves or {}) do
    if type(def)=="table" then
      local raw=tonumber(def.colosseumMoveId or def.index)
      if raw and raw>=1 and raw<=354 and not out[raw] then out[raw]=id end
    end
  end
  return out
end

local function projectedMoves(base,generation)
  local out={}
  for id,def in pairs((base and base.moves) or {}) do
    out[id]=type(def)=="table" and copyTable(def) or def
  end
  if not sourceReady() then return out end
  local byRaw=rawMoveMap(out)
  for raw,row in pairs(Source.moves) do
    local id=byRaw[raw]
    local def=id and out[id]
    local typeName=TYPE_NAMES[tonumber(row and row.typeId)]
    if type(def)=="table" and typeName then
      -- Keep the host effect executor, but take source-owned core move fields.
      -- `accuracy==0` is GC6E01's always-hit sentinel; presenting it as 100 plus
      -- the explicit flag lets the existing verified-move runtime skip the roll
      -- without turning the host's 0%-accuracy path into an automatic miss.
      def.type=typeName
      def.category=TYPE_CATEGORY[typeName]
      def.power=tonumber(row.power) or def.power
      def.pp=tonumber(row.pp) or def.pp
      def.priority=tonumber(row.priority) or def.priority or 0
      def.accuracy=(tonumber(row.accuracy)==0) and 100 or (tonumber(row.accuracy) or def.accuracy)
      def.colosseumAlwaysHit=tonumber(row.accuracy)==0 or def.colosseumAlwaysHit
      def.makesContact=tonumber(row.makesContact)==1
      def.colosseumMoveId=raw
      def.colosseumSource="GC6E01"
      def.__cbeMtBattleSourceMove=true
    end
  end

  -- Red has no native ids for these Gen-III moves. Admit a challenge-local
  -- definition only when the player's own GC6E01 CommonMoveData row matches
  -- every mechanics-bearing field we audited. A corrupt/stale source cache
  -- therefore removes the move from MOVE PREP rather than silently drifting.
  generation=tonumber(generation) or hostGeneration()
  if generation==1 then
    for raw,plan in pairs(GEN1_SOURCE_MOVES) do
      local dependencyRaw=tonumber(plan.requiresUnavailableRaw)
      if not byRaw[raw] and not (dependencyRaw and byRaw[dependencyRaw])
          and sourceMoveMatches(raw,plan) then
        local row=Source.moves[raw]
        local typeName=TYPE_NAMES[tonumber(row.typeId)]
        if typeName then
          local id=("CMOVE_%d"):format(raw)
          out[id]={
            id=id,name=plan.name,index=nil,
            type=typeName,category=TYPE_CATEGORY[typeName],
            power=tonumber(row.power),accuracy=tonumber(row.accuracy),pp=tonumber(row.pp),
            priority=tonumber(row.priority) or 0,effect=plan.effectName,
            makesContact=tonumber(row.makesContact)==1,
            colosseumMoveId=raw,colosseumSource="GC6E01",
            colosseumTargetCode=tonumber(row.target),
            colosseumEffectChance=tonumber(row.effectChance) or 0,
            colosseumBlockedByProtect=tonumber(row.blockedByProtect)==1,
            colosseumMagicCoatReflects=tonumber(row.magicCoatReflects)==1,
            colosseumSnatchSteals=tonumber(row.snatchSteals)==1,
            colosseumMirrorMoveCopies=tonumber(row.mirrorMoveCopies)==1,
            colosseumKingsRockFlinch=tonumber(row.kingsRockFlinch)==1,
            colosseumSoundBased=tonumber(row.soundBased)==1,
            __cbeMtBattleSourceMove=true,
            __cbeMtBattleGen3MoveMechanicsSourceProven=plan.sourceProven==true,
            __cbeMtBattleFullExecutionExact=false,
            -- Honest exactness boundary: this move-specific adapter still calls
            -- Mt. Battle's shared Red damage kernel, whose critical/random/final
            -- rounding remains a separate known GC6E01 parity blocker.
            __cbeMtBattleSharedDamageKernel="GEN1_HOST_SHARED_BLOCKER",
          }
          byRaw[raw]=id
        end
      end
    end
  end
  return out
end

local function sourceSecondaryBeforeAccuracy(ctx)
  -- GC6E01 keeps Substitute state 0x14 alive through the indirect additional-
  -- effect dispatcher even when the hit reduced substitute HP to zero; its
  -- cleanup runs later. Red clears substituteHP immediately on break, so retain
  -- the pre-hit occupancy on this per-move ctx to reproduce that source phase.
  ctx.__cbeMtBattleSourceHadSub=ctx.target and ctx.target.substituteHP~=nil
  ctx.__cbeMtBattleSecondaryPass=nil
end

local function sourceSecondaryAfterDamage(ctx)
  -- GC6E01 fn_80224820 reads CommonMoveData +0x05, doubles that byte for
  -- Serene Grace (ability 0x20), consumes RNG%100, then succeeds on <=.
  -- Preserve the inclusive comparison exactly -- source 20 is 21 passing
  -- residues, source 50 is 51, and even 100 still consumes one RNG draw.
  local chance=tonumber(ctx.move and ctx.move.colosseumEffectChance) or 0
  if abilityIs(ctx.battle,ctx.user,"SERENE_GRACE") then chance=chance*2 end
  ctx.__cbeMtBattleSecondaryPass=(ctx.rng(0,99)<=chance)
end

local function statSecondary(stat)
  return function(ctx)
    if ctx.__cbeMtBattleSourceHadSub or not ctx.__cbeMtBattleSecondaryPass then return {} end
    return ctx.changeStage(ctx.target,stat,-1,true) or {}
  end
end

local function confusionSecondary(ctx)
  if ctx.__cbeMtBattleSourceHadSub or not ctx.__cbeMtBattleSecondaryPass then return {} end
  if ctx.target.confusedTurns then return {} end
  -- GC6E01 confusion duration is 2..5 turns; the host battler uses the same
  -- countdown representation. Own Tempo/Shield Dust are applied by the already-
  -- installed AbilityEffectsGen1 effect-record wrapper before this run callback.
  ctx.target.confusedTurns=ctx.rng(2,5)
  local Strings=req("src.core.Strings")
  return {Strings("%s\nbecame confused!",ctx.displayName(ctx.target))}
end

local function speedDown2Primary(ctx)
  return ctx.changeStage(ctx.target,"speed",-2,true) or {}
end

local function selfCompositePrimary(stats)
  return function(ctx)
    local out={}
    for _,stat in ipairs(stats) do
      for _,msg in ipairs(ctx.changeStage(ctx.user,stat,1,false) or {}) do out[#out+1]=msg end
    end
    return out
  end
end

local function userStatSecondaryAfterDamage(stats)
  return function(ctx,totalDealt)
    if (tonumber(totalDealt) or 0)<=0 then return end
    -- GC6E01 uses the same CommonMoveData +0x05 dispatcher for self-boosting
    -- damaging effects.  Apply the boost here, before the host's faint queue,
    -- because the source effect belongs to the attacker and is not suppressed by
    -- the defender's Shield Dust/Substitute state.
    sourceSecondaryAfterDamage(ctx)
    if not ctx.__cbeMtBattleSecondaryPass then return end
    for _,stat in ipairs(stats) do
      for _,msg in ipairs(ctx.changeStage(ctx.user,stat,1,false) or {}) do
        ctx.sayNext(msg)
      end
    end
  end
end

local function facadeDamage(ctx)
  local move=copyTable(ctx.move)
  local status=ctx.user and ctx.user.mon and ctx.user.mon.status
  local key=status and tostring(status):upper() or ""
  -- pokemonIsJoutaiKaragenki covers burn/paralysis/poison/toxic, not sleep or
  -- freeze. Gen1 represents toxic as PSN plus a counter, so PSN covers both.
  if key=="BRN" or key=="PAR" or key=="PSN" then move.power=(tonumber(move.power) or 0)*2 end
  return ctx.battle:computeDamage(ctx.user,ctx.target,move,{rng=ctx.battle.rng})
end

local function brickBreakDamage(ctx)
  -- Retail effect 186 executes fn_80214450 after hit check and before critical/
  -- type/damage. Red singles stores the two screens on the defending battler;
  -- the doubles adapter mirrors that side state onto both active battlers, so
  -- clear every same-side active there as the retail side-condition command does.
  local cleared=false
  local active=ctx.battle and ctx.battle.__cbeAbilityActives
  if type(active)=="function" and ctx.target then
    local ok,values=pcall(active)
    if ok and type(values)=="table" then
      for _,b in ipairs(values) do
        if b and b.isPlayer==ctx.target.isPlayer then
          b.reflect=nil;b.lightScreen=nil;cleared=true
        end
      end
    end
  end
  if not cleared then
    ctx.target.reflect=nil
    ctx.target.lightScreen=nil
  end
  return ctx.battle:computeDamage(ctx.user,ctx.target,ctx.move,{rng=ctx.battle.rng})
end

local function waterAbsorbGate(ctx)
  if not (ctx.move and ctx.move.type=="WATER") then return true end
  if not abilityIs(ctx.battle,ctx.target,"WATER_ABSORB") then return true end
  local abilities=V.Abilities
  local mon=ctx.target and ctx.target.mon
  if mon and mon.hp then
    local maxHp=abilities and type(abilities.maxHP)=="function" and abilities.maxHP(mon)
      or (mon.stats and mon.stats.hp) or mon.maxHp or mon.maxHP or mon.hp
    mon.hp=math.min(maxHp,mon.hp+math.max(1,math.floor(maxHp/4)))
  end
  if abilities and type(abilities.message)=="function" then
    abilities.message(ctx.battle,"Water Absorb restored HP!")
  end
  return false
end

local function projectedMoveEffects(base,moves)
  local custom={}
  if moves.CMOVE_178 or moves.CMOVE_184 then
    custom.CBE_G3_SPEED_DOWN2={kind="primary",accuracyChecked=true,run=speedDown2Primary}
  end
  if moves.CMOVE_339 then custom.CBE_G3_BULK_UP={kind="primary",run=selfCompositePrimary({"attack","defense"})} end
  if moves.CMOVE_347 then
    -- One Gen-I Special stage represents both source Sp.Atk and Sp.Def because
    -- attachGen1Battle maps that stage onto the split source stat selected by
    -- each damage formula call.
    custom.CBE_G3_CALM_MIND={kind="primary",run=selfCompositePrimary({"special"})}
  end
  if moves.CMOVE_349 then custom.CBE_G3_DRAGON_DANCE={kind="primary",run=selfCompositePrimary({"attack","speed"})} end
  if moves.CMOVE_231 or moves.CMOVE_249 or moves.CMOVE_306 then custom.DEFENSE_DOWN_HIT_G3={kind="full",
    beforeAccuracy=sourceSecondaryBeforeAccuracy,afterDamage=sourceSecondaryAfterDamage,
    run=statSecondary("defense")} end
  if moves.CMOVE_263 then custom.CBE_G3_FACADE={kind="full",chooseDamage=facadeDamage} end
  if moves.CMOVE_280 then custom.CBE_G3_BRICK_BREAK={kind="full",chooseDamage=brickBreakDamage} end
  if moves.CMOVE_309 then custom.CBE_G3_ATTACK_UP_HIT={kind="full",
    afterDamage=userStatSecondaryAfterDamage({"attack"})} end
  if moves.CMOVE_246 or moves.CMOVE_318 then custom.CBE_G3_ALL_UP_HIT={kind="full",
    -- Gen-I has one Special stage. Mt. Battle's split-stat damage adapter maps
    -- that shared stage onto source Sp.Atk for offense and source Sp.Def for
    -- defense, so one +1 `special` change reproduces the two Gen-III boosts.
    afterDamage=userStatSecondaryAfterDamage({"attack","defense","speed","special"})} end
  if moves.CMOVE_317 or moves.CMOVE_341 then custom.SPEED_DOWN_HIT_G3={kind="full",
    beforeAccuracy=sourceSecondaryBeforeAccuracy,afterDamage=sourceSecondaryAfterDamage,
    run=statSecondary("speed")} end
  if moves.CMOVE_324 or moves.CMOVE_352 then custom.CONFUSION_HIT_G3={kind="full",gate=waterAbsorbGate,
    beforeAccuracy=sourceSecondaryBeforeAccuracy,afterDamage=sourceSecondaryAfterDamage,
    run=confusionSecondary} end
  if next(custom)==nil then return nil end
  local native=base and base.move_effects
  local fallback=req("src.battle.MoveEffects").RECORDS
  return setmetatable(custom,{__index=function(_,effect)
    local record=type(native)=="table" and native[effect] or nil
    if record~=nil then return record end
    return fallback and fallback[effect] or nil
  end})
end

local function moveLists(game,dex,id)
  local level1,level,tmhm={},{},{}
  if not (MoveCatalog and type(MoveCatalog.pool)=="function") then return level1,level,tmhm,0,0 end
  local rows,diag=MoveCatalog.pool(game,{species=id,dex=dex,nationalDex=dex,moves={}})
  if not (diag and diag.sourceBacked) then return level1,level,tmhm,0,0 end
  local seenLevel,seenMachine={},{ }
  for _,row in ipairs(rows or {}) do
    if row.source=="LEVEL" then
      if not seenLevel[row.id] then
        seenLevel[row.id]=true
        local at=tonumber(row.level) or 1
        level[#level+1]={level=at,move=row.id}
        if at<=1 then level1[#level1+1]=row.id end
      end
    elseif row.id and not seenMachine[row.id] then
      seenMachine[row.id]=true;tmhm[#tmhm+1]=row.id
    end
  end
  return level1,level,tmhm,#(rows or {}),tonumber(diag.unresolved) or 0
end

local function projectedSpecies(base,viewGame)
  local out={}
  for id,def in pairs((base and base.pokemon) or {}) do out[id]=def end
  if not sourceReady() then return out,{} end
  local ids={}
  for dex=1,BD.MAX_DEX do
    local id=Names[dex]
    local src=Source.species[dex]
    if type(id)=="string" and type(src)=="table" then
      ids[#ids+1]=id
      local types=canonicalTypes(src)
      if types then
        local bs=src.baseStats or {}
        local level1,level,tmhm,resolved,unresolved=moveLists(viewGame,dex,id)
        -- Mt. Battle is a Colosseum ruleset even when the host cartridge already
        -- owns this National-Dex identity.  Keeping the native definition by
        -- reference made Kanto species on a Red host silently retain Gen-I
        -- mechanics (one Special stat and, e.g., MAGNEMITE without STEEL), while
        -- only Johto/Hoenn received the GC6E01 projection.  Clone the host row so
        -- engine-only fields such as growth/evolution metadata remain available,
        -- then overlay the source-owned battle fields for *every* 001-386 row.
        -- The host table itself is never mutated and the projection is built once
        -- per game by BD.view(), so this adds no per-fight/per-frame work.
        local native=out[id]
        local def=type(native)=="table" and copyTable(native) or {}
        def.id=def.id or id
        def.name=def.name or id:gsub("_"," ")
        def.dex=dex;def.nationalDex=dex
        def.types=types
        def.baseStats={hp=bs.hp,attack=bs.attack,defense=bs.defense,speed=bs.speed,
          specialAttack=bs.specialAttack,specialDefense=bs.specialDefense,
          -- Compatibility only. MtBattle's Gen1 damage adapter selects SpA
          -- versus SpD explicitly and never treats this as a unified source stat.
          special=bs.specialAttack}
        def.catchRate=src.catchRate;def.baseExp=src.baseExp;def.genderRatio=src.genderRatio
        def.level1Moves=level1;def.learnset=level;def.levelMoves=level;def.tmhm=tmhm
        if type(def.evolutions)~="table" then def.evolutions={} end
        def.__cbeMtBattleSource=true;def.__cbeMtBattleDex=dex
        def.__cbeMtBattleResolvedMoves=resolved
        def.__cbeMtBattleUnresolvedMoves=unresolved
        out[id]=def
      end
    end
  end
  return out,ids
end

local cache=setmetatable({},{__mode="k"})

local function build(game)
  local base=game and game.data
  if type(base)~="table" then return nil,"host data unavailable" end
  if not sourceReady() then return nil,"GC6E01 PokemonStats/CommonMoveData unavailable" end
  local generation=hostGeneration()
  local moves=projectedMoves(base,generation)
  local moveEffects=projectedMoveEffects(base,moves)
  local trainers={}
  for id,record in pairs(base.trainers or {}) do trainers[id]=type(record)=="table" and copyTable(record) or record end
  local own={
    moves=moves,trainers=trainers,
    type_chart={generation=3,source="host pokegold type_matchups oracle / GC6E01-compatible",
      types=TYPE_RECORDS,matchups=TYPE_ROWS},
  }
  if moveEffects then own.move_effects=moveEffects end
  local data=setmetatable(own,{__index=base})
  local shell={data=data,save=game.save}
  setmetatable(shell,{__index=game})
  local pokemon,ids=projectedSpecies(base,shell)
  data.pokemon=pokemon
  return {data=data,eligible=ids}
end

function BD.view(game)
  if type(game)~="table" then return nil,"game unavailable" end
  local hit=cache[game]
  if hit and hit.base==game.data and hit.source==Source then return hit end
  local built,why=build(game)
  if not built then return nil,why end
  built.base=game.data;built.source=Source;cache[game]=built
  return built
end

function BD.data(game)
  local view,why=BD.view(game);return view and view.data or nil,why
end

function BD.eligibleSpecies(game)
  local view,why=BD.view(game)
  if not view then return nil,why end
  local out={};for i,id in ipairs(view.eligible) do out[i]=id end;return out
end

-- A battle receives a proxy game/save. Reads fall through to the real host, but
-- challenge party/Pokedex/bag/money writes land on private tables. This removes
-- the old synchronous game.save.party swap entirely.
function BD.game(game,party)
  local data,why=BD.data(game);if not data then return nil,why end
  local live=game.save or {}
  local run=V.MtBattleSaveState and V.MtBattleSaveState.state and V.MtBattleSaveState.state(game) or nil
  local save=setmetatable({
    party=party or {},inventory=(run and run.bag) or {},money=live.money or 0,
    pokedex={seen={},owned={}},
  },{__index=live})
  return setmetatable({data=data,save=save,__cbeMtBattleHostGame=game},{__index=game})
end

function BD.fallbackMove(data,def)
  if def and def.__cbeMtBattleSource and data and data.moves and data.moves.STRUGGLE then return "STRUGGLE" end
  return nil
end

-- Gen1's stat routine has one Special word. Run it twice against the two
-- source base stats using the SAME host DV/stat-exp inputs, then carry both
-- results. `special` remains an execution-compatibility alias to SpA only;
-- attachGen1Battle substitutes SpA/SpD around damage evaluation.
function BD.gen1Stats(def,level,dvs,statExp)
  local Stats=req("src.pokemon.Stats")
  if not (def and def.__cbeMtBattleSource and def.baseStats and def.baseStats.specialAttack) then
    return Stats.calc(def,level,dvs,statExp)
  end
  local b=def.baseStats
  local function one(special)
    return Stats.calc({baseStats={hp=b.hp,attack=b.attack,defense=b.defense,speed=b.speed,special=special}},level,dvs,statExp)
  end
  local a=one(b.specialAttack);local d=one(b.specialDefense)
  a.specialAttack=a.special;a.specialDefense=d.special
  return a
end

function BD.newGen1Mon(data,species,level,dvs,moves)
  local def=data and data.pokemon and data.pokemon[species]
  if not def then return nil,"species unavailable in challenge view" end
  local Stats=req("src.pokemon.Stats")
  dvs=dvs or Stats.randomDVs()
  local statExp={hp=0,attack=0,defense=0,speed=0,special=0}
  local stats=BD.gen1Stats(def,level,dvs,statExp)
  local mon={species=species,level=level,dvs=dvs,statExp=statExp,stats=stats,hp=stats.hp,
    catchRate=def.catchRate,moves={}}
  for i,mv in ipairs(moves or {}) do
    local id=type(mv)=="table" and mv.id or mv;local mdef=data.moves and data.moves[id]
    if id and mdef then mon.moves[i]={id=id,pp=(type(mv)=="table" and mv.pp) or mdef.pp or 0,
      ppUps=type(mv)=="table" and mv.ppUps or nil} end
  end
  return mon
end

local function pack(...) return {n=select('#',...),...} end
local unpack=table.unpack or unpack

function BD.attachGen1Battle(battle,hostGame)
  if not (battle and battle.data and battle.data.type_chart) then return battle end
  if battle.__cbeMtBattleDataAdapter then return battle end
  battle.__cbeMtBattleDataAdapter=true

  -- Source-accurate hit check only for the six audited challenge-local rows.
  -- Native Red moves keep the exact host path, including the 1/256 quirk. The
  -- GC6E01 path instead uses its 13-entry stage table and RNG%100+1, with the
  -- retail Compound Eyes -> Sand Veil -> Hustle ordering. Held-item accuracy is
  -- intentionally absent: Gen1 challenge clones carry no held-item identity and
  -- this adapter must not invent one.
  local originalAccuracy=battle.accuracyRoll
  if type(originalAccuracy)=="function" then
    battle.accuracyRoll=function(self,move,user,target,...)
      if not (type(move)=="table" and move.__cbeMtBattleGen3MoveMechanicsSourceProven==true) then
        return originalAccuracy(self,move,user,target,...)
      end
      local base=tonumber(move.accuracy) or 0
      if base<=0 then return true end
      local aStage=user and user.stages and tonumber(user.stages.accuracy) or 0
      local eStage=target and target.stages and tonumber(target.stages.evasion) or 0
      local index=math.max(0,math.min(12,math.floor(aStage-eStage+6)))
      local ratio=GEN1_ACCURACY_STAGE[index+1]
      local accuracy=math.floor(base*ratio[1]/ratio[2])
      if abilityIs(self,user,"COMPOUNDEYES") then accuracy=math.floor(accuracy*130/100) end
      if abilityIs(self,target,"SAND_VEIL") and V.AbilityWeather
          and type(V.AbilityWeather.sandAccuracyMultiplier)=="function" then
        local mult=V.AbilityWeather.sandAccuracyMultiplier(self,1,
          function(b) return abilityIs(self,b,"CLOUD_NINE") end)
        if mult<1 then accuracy=math.floor(accuracy*80/100) end
      end
      if TYPE_CATEGORY[move.type]=="physical" and abilityIs(self,user,"HUSTLE") then
        accuracy=math.floor(accuracy*80/100)
      end
      return (self.rng(0,99)+1)<=accuracy
    end
  end
  local originalCompute=battle.computeDamage
  if type(originalCompute)=="function" then
    battle.computeDamage=function(self,user,target,move,opts)
      local typeRec=self.data.type_chart.types and self.data.type_chart.types[move and move.type]
      if not (typeRec and typeRec.category=="special") then
        return originalCompute(self,user,target,move,opts)
      end
      local us=user and user.curStats;local ts=target and target.curStats
      if not (us and ts) then return originalCompute(self,user,target,move,opts) end
      local oldU,oldT=us.special,ts.special
      us.special=us.specialAttack or oldU
      ts.special=ts.specialDefense or oldT
      local r=pack(pcall(originalCompute,self,user,target,move,opts))
      us.special,ts.special=oldU,oldT
      if not r[1] then error(r[2],0) end
      return unpack(r,2,r.n)
    end
  end
  local TypeChart=req("src.battle.TypeChart")
  local restored=false
  local function restore()
    if restored then return end;restored=true
    if hostGame and hostGame.data then pcall(TypeChart.load,hostGame.data) end
  end
  battle.__cbeMtBattleRestoreHostTypeChart=restore
  local originalExit=battle.exit
  if type(originalExit)=="function" then
    battle.exit=function(self,...)
      local r=pack(pcall(originalExit,self,...));restore()
      if not r[1] then error(r[2],0) end
      return unpack(r,2,r.n)
    end
  end
  return battle
end

function BD.restoreHostTypes(battle)
  local fn=battle and battle.__cbeMtBattleRestoreHostTypeChart
  if type(fn)=="function" then fn();battle.__cbeMtBattleRestoreHostTypeChart=nil end
end

BD._test={TYPE_NAMES=TYPE_NAMES,TYPE_CATEGORY=TYPE_CATEGORY,TYPE_ROWS=TYPE_ROWS,
  canonicalTypes=canonicalTypes,projectedMoves=projectedMoves,build=build,
  GEN1_SOURCE_MOVES=GEN1_SOURCE_MOVES,GEN1_ACCURACY_STAGE=GEN1_ACCURACY_STAGE,
  sourceMoveMatches=sourceMoveMatches,projectedMoveEffects=projectedMoveEffects}
return BD
