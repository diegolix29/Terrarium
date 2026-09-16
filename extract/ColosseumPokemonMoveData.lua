-- Pokemon Colosseum GC6E01 source-backed Pokemon/move mechanics data.
--
-- PokemonStats supplies species identity-adjacent mechanics (growth code,
-- catch/gender/EXP, type/ability ids, split base stats), level-up rows and 58
-- literal TM/HM compatibility booleans. CommonMoveData supplies the move-side
-- execution flags. The retail start.dol table supplies the exact move taught by
-- each machine slot. Runtime code projects only what the active host can execute
-- exactly enough and fails closed for everything else.
local V=... or {}
local FSYS=assert(V.FSYS,"FSYS dependency required")
local SpeciesIndex=assert(V.ColosseumSpeciesIndex,"ColosseumSpeciesIndex dependency required")
local M={}

local CACHE_VERSION=4
local CACHE_PATH="cache/mt_battle/colosseum_move_pools_v1.lua"
local MOVES_BASE=0x11E048
local MOVES_STRIDE=0x38
local MOVE_COUNT=354
local STATS_BASE=0x12336C
local STATS_STRIDE=0x11C
local TM_COMPAT_OFFSET=0x34
local MACHINE_COUNT=58
local LEVEL_OFFSET=0xBA
local LEVEL_SLOTS=20
local DOL_TM_TABLE_OFFSET=0x365018
local DOL_TM_STRIDE=8
local POKEMON_TYPE_IDS={
  [0]=true,[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true,[7]=true,[8]=true,
  [10]=true,[11]=true,[12]=true,[13]=true,[14]=true,[15]=true,[16]=true,[17]=true,
}

local function be16(s,p)
  local a,b=s:byte(p+1,p+2);if not b then return nil end
  return a*256+b
end
local function be32(s,p)
  local a,b,c,d=s:byte(p+1,p+4);if not d then return nil end
  return ((a*256+b)*256+c)*256+d
end
local function s8(v)
  return v>=0x80 and v-0x100 or v
end

-- GC6E01 PokemonStats uses the game's internal species ids. 1-251 retain
-- National-Dex identity; the Hoenn block contains 25 non-National rows before
-- Treecko and places Chimecho at internal 411. This mapping was independently
-- verified against the retail PokemonStats signatures for all dex 252-386.
local function internalForDex(dex)return SpeciesIndex.internalForDex(dex)end

local function commonRelBlob(disc)
  assert(disc and type(disc.file)=="function","GC6E01 disc unavailable")
  local file=disc:file("common.fsys")
  if not file and type(disc.find)=="function" then
    for _,candidate in ipairs(disc:find("common.fsys") or {}) do file=candidate;break end
  end
  assert(file,"GC6E01 common.fsys unavailable")
  local arc=assert(FSYS.open(disc,file))
  local entry
  for _,candidate in ipairs(arc:list() or {}) do
    if tostring(candidate.name or ""):lower():find("common_rel",1,true) then entry=candidate;break end
  end
  assert(entry,"GC6E01 common_rel member unavailable")
  local blob=assert(arc:extract(entry,{maxOutput=8*1024*1024}))
  assert(type(blob)=="string" and #blob>=STATS_BASE+411*STATS_STRIDE,"GC6E01 common_rel is too short for PokemonStats")
  return blob
end

local function machineRows(disc)
  assert(disc and type(disc.read)=="function","GC6E01 raw disc reader unavailable")
  local header=disc.header
  if type(header)~="string" or #header<0x424 then header=disc:read(0,0x440) end
  local dolOffset=assert(be32(header,0x420),"GC6E01 main.dol offset unavailable")
  assert(dolOffset>0,"GC6E01 main.dol offset invalid")
  local blob=disc:read(dolOffset+DOL_TM_TABLE_OFFSET,MACHINE_COUNT*DOL_TM_STRIDE)
  assert(type(blob)=="string" and #blob==MACHINE_COUNT*DOL_TM_STRIDE,"GC6E01 TM/HM table short read")
  local out={}
  for slot=1,MACHINE_COUNT do
    local at=(slot-1)*DOL_TM_STRIDE
    local flag=blob:byte(at+1)
    local expected=slot>50 and 1 or 0
    assert(flag==expected,("GC6E01 machine %d kind flag mismatch"):format(slot))
    for off=1,5 do
      assert(blob:byte(at+off+1)==0,("GC6E01 machine %d padding mismatch"):format(slot))
    end
    local rawMoveId=assert(be16(blob,at+6),("GC6E01 machine %d move id missing"):format(slot))
    assert(rawMoveId>0 and rawMoveId<=400,("GC6E01 machine %d move id out of range: %d"):format(slot,rawMoveId))
    out[slot]={slot=slot,kind=slot>50 and "HM" or "TM",
      number=slot>50 and slot-50 or slot,rawMoveId=rawMoveId}
  end
  return out
end

local function parse(blob,machines)
  assert(type(blob)=="string","common_rel blob required")
  assert(type(machines)=="table" and #machines==MACHINE_COUNT,"58 machine rows required")
  -- CommonMoveData is the same retail table battle execution reads. Keep the
  -- fields that materially gate whether a host mechanic is an exact match so
  -- runtime registrations can validate against the user's own GC6E01 bytes,
  -- rather than trusting a hand-maintained projection of power/chance/target.
  local moves={}
  for rawMoveId=1,MOVE_COUNT do
    local base=MOVES_BASE+(rawMoveId-1)*MOVES_STRIDE
    assert(base+MOVES_STRIDE<=#blob,("CommonMoveData row %d exceeds common_rel"):format(rawMoveId))
    local effectId=assert(be16(blob,base+0x1C))
    assert(effectId==rawMoveId,("CommonMoveData row %d identity mismatch: %d"):format(rawMoveId,effectId))
    moves[rawMoveId]={rawMoveId=rawMoveId,
      priority=s8(blob:byte(base+0x00+1)),pp=blob:byte(base+0x01+1),
      typeId=blob:byte(base+0x02+1),target=blob:byte(base+0x03+1),
      accuracy=blob:byte(base+0x04+1),effectChance=blob:byte(base+0x05+1),
      makesContact=blob:byte(base+0x06+1),blockedByProtect=blob:byte(base+0x07+1),
      magicCoatReflects=blob:byte(base+0x08+1),snatchSteals=blob:byte(base+0x09+1),
      mirrorMoveCopies=blob:byte(base+0x0A+1),kingsRockFlinch=blob:byte(base+0x0B+1),
      soundBased=blob:byte(base+0x10+1),hmFlag=blob:byte(base+0x12+1),
      recoil=blob:byte(base+0x13+1),power=blob:byte(base+0x17+1),
      effect=blob:byte(base+0x1B+1),animationId=assert(be16(blob,base+0x32))}
  end
  local species={}
  for dex=1,386 do
    local internal=assert(internalForDex(dex))
    local base=STATS_BASE+(internal-1)*STATS_STRIDE
    assert(base+STATS_STRIDE<=#blob,("PokemonStats row %d/%d exceeds common_rel"):format(dex,internal))
    local levelMoves={}
    local terminated=false
    for slot=0,LEVEL_SLOTS-1 do
      local at=base+LEVEL_OFFSET+slot*4
      local level=blob:byte(at+1)
      local pad=blob:byte(at+2)
      local rawMoveId=assert(be16(blob,at+2))
      if rawMoveId==0 then terminated=true;break end
      assert(not terminated,("PokemonStats dex %d has a move after terminator"):format(dex))
      assert(pad==0,("PokemonStats dex %d level move %d has nonzero pad"):format(dex,slot+1))
      assert(level and level>=1 and level<=100,("PokemonStats dex %d level move %d has invalid level %s"):format(dex,slot+1,tostring(level)))
      assert(rawMoveId<=400,("PokemonStats dex %d level move %d id out of range: %d"):format(dex,slot+1,rawMoveId))
      levelMoves[#levelMoves+1]={level=level,rawMoveId=rawMoveId}
    end
    local machineSlots={}
    for slot=1,MACHINE_COUNT do
      local value=blob:byte(base+TM_COMPAT_OFFSET+slot)
      assert(value==0 or value==1,("PokemonStats dex %d machine slot %d is not boolean: %s"):format(dex,slot,tostring(value)))
      if value==1 then machineSlots[#machineSlots+1]=slot end
    end
    local type1,type2=blob:byte(base+0x30+1),blob:byte(base+0x31+1)
    assert(POKEMON_TYPE_IDS[type1] and POKEMON_TYPE_IDS[type2],
      ("PokemonStats dex %d has unsupported type ids %s/%s"):format(dex,tostring(type1),tostring(type2)))
    local baseStats={
      hp=blob:byte(base+0x85+1),attack=blob:byte(base+0x87+1),defense=blob:byte(base+0x89+1),
      specialAttack=blob:byte(base+0x8B+1),specialDefense=blob:byte(base+0x8D+1),speed=blob:byte(base+0x8F+1),
    }
    for key,value in pairs(baseStats) do
      assert(value and value>=1,("PokemonStats dex %d has invalid %s base stat %s"):format(dex,key,tostring(value)))
    end
    species[dex]={dex=dex,internalSpecies=internal,
      growthRateId=blob:byte(base+0x00+1),catchRate=blob:byte(base+0x01+1),
      genderRatio=blob:byte(base+0x02+1),baseExp=blob:byte(base+0x07+1),
      baseHappiness=blob:byte(base+0x09+1),typeIds={type1,type2},
      abilityIds={blob:byte(base+0x32+1),blob:byte(base+0x33+1)},baseStats=baseStats,
      levelMoves=levelMoves,machineSlots=machineSlots}
  end
  return {version=CACHE_VERSION,discId="GC6E01",source="GC6E01 common_rel PokemonStats/CommonMoveData + retail start.dol TM/HM table",
    dexCount=386,moveCount=MOVE_COUNT,machineCount=MACHINE_COUNT,moves=moves,machines=machines,species=species}
end

local function valid(data)
  if type(data)~="table" or data.version~=CACHE_VERSION or data.discId~="GC6E01"
      or data.dexCount~=386 or data.moveCount~=MOVE_COUNT or data.machineCount~=MACHINE_COUNT
      or type(data.moves)~="table" or type(data.machines)~="table" or type(data.species)~="table" then return false end
  for rawMoveId=1,MOVE_COUNT do
    local m=data.moves[rawMoveId]
    local raw=type(m)=="table" and tonumber(m.rawMoveId or m[1]) or nil
    local animation=type(m)=="table" and tonumber(m.animationId or m[19]) or nil
    if raw~=rawMoveId or animation==nil then return false end
  end
  for slot=1,MACHINE_COUNT do
    local m=data.machines[slot]
    local raw=type(m)=="table" and tonumber(m.rawMoveId or m[4]) or nil
    local kind=type(m)=="table" and (m.kind or m[2]) or nil
    if not raw or (kind~="TM" and kind~="HM") then return false end
  end
  for dex=1,386 do
    local s=data.species[dex]
    if type(s)~="table" or s.dex~=dex or tonumber(s.internalSpecies)~=internalForDex(dex)
        or type(s.levelMoves)~="table" or type(s.machineSlots)~="table"
        or type(s.typeIds)~="table" or type(s.abilityIds)~="table" or type(s.baseStats)~="table"
        or tonumber(s.growthRateId)==nil or tonumber(s.catchRate)==nil or tonumber(s.genderRatio)==nil
        or tonumber(s.baseExp)==nil or tonumber(s.baseHappiness)==nil then return false end
  end
  return true
end

local function serialize(data)
  local out={"-- Generated from the user-supplied Pokemon Colosseum GC6E01 source.\n",
    "return {version=4,discId=\"GC6E01\",source=\"GC6E01 common_rel PokemonStats/CommonMoveData + retail start.dol TM/HM table\",dexCount=386,moveCount=354,machineCount=58,moves={\n"}
  for rawMoveId=1,MOVE_COUNT do
    local m=data.moves[rawMoveId]
    out[#out+1]=( "[%d]={%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d},\n" ):format(
      rawMoveId,m.rawMoveId,m.priority,m.pp,m.typeId,m.target,m.accuracy,m.effectChance,
      m.makesContact,m.blockedByProtect,m.magicCoatReflects,m.snatchSteals,m.mirrorMoveCopies,
      m.kingsRockFlinch,m.soundBased,m.hmFlag,m.recoil,m.power,m.effect,m.animationId)
  end
  out[#out+1]="},machines={\n"
  for slot=1,MACHINE_COUNT do
    local m=data.machines[slot]
    out[#out+1]=("{%d,%q,%d,%d},\n"):format(m.slot,m.kind,m.number,m.rawMoveId)
  end
  out[#out+1]="},species={\n"
  for dex=1,386 do
    local s=data.species[dex]
    local st=s.baseStats
    out[#out+1]=( "[%d]={dex=%d,internalSpecies=%d,growthRateId=%d,catchRate=%d,genderRatio=%d,baseExp=%d,baseHappiness=%d,typeIds={%d,%d},abilityIds={%d,%d},baseStats={hp=%d,attack=%d,defense=%d,specialAttack=%d,specialDefense=%d,speed=%d},levelMoves={" ):format(
      dex,dex,s.internalSpecies,s.growthRateId,s.catchRate,s.genderRatio,s.baseExp,s.baseHappiness,
      s.typeIds[1],s.typeIds[2],s.abilityIds[1],s.abilityIds[2],
      st.hp,st.attack,st.defense,st.specialAttack,st.specialDefense,st.speed)
    for _,r in ipairs(s.levelMoves) do out[#out+1]=( "{%d,%d}," ):format(r.level,r.rawMoveId) end
    out[#out+1]="},machineSlots={"
    for _,slot in ipairs(s.machineSlots) do out[#out+1]=tostring(slot).."," end
    out[#out+1]="}},\n"
  end
  out[#out+1]="}}\n"
  return table.concat(out)
end

-- Cache rows use compact array records. Normalize them once after loading so
-- runtime callers see the same named fields whether data was freshly decoded or
-- reused from a previous release's installation-scoped cache.
local function normalize(data)
  if not valid(data) then return nil end
  for rawMoveId=1,MOVE_COUNT do
    local m=data.moves[rawMoveId]
    if m.rawMoveId==nil then
      data.moves[rawMoveId]={rawMoveId=m[1],priority=m[2],pp=m[3],typeId=m[4],target=m[5],
        accuracy=m[6],effectChance=m[7],makesContact=m[8],blockedByProtect=m[9],
        magicCoatReflects=m[10],snatchSteals=m[11],mirrorMoveCopies=m[12],kingsRockFlinch=m[13],
        soundBased=m[14],hmFlag=m[15],recoil=m[16],power=m[17],effect=m[18],animationId=m[19]}
    end
  end
  for slot=1,MACHINE_COUNT do
    local m=data.machines[slot]
    if m.slot==nil then data.machines[slot]={slot=m[1],kind=m[2],number=m[3],rawMoveId=m[4]} end
  end
  for dex=1,386 do
    local s=data.species[dex]
    for i,r in ipairs(s.levelMoves) do
      if r.level==nil then s.levelMoves[i]={level=r[1],rawMoveId=r[2]} end
    end
  end
  return data
end

local function readCache(mod)
  if not (mod and mod.cache and type(mod.cache.read)=="function") then return nil end
  local ok,src=pcall(mod.cache.read,mod.cache,CACHE_PATH)
  if not ok or type(src)~="string" then return nil end
  local chunk=load(src,"@generated/"..CACHE_PATH)
  if not chunk then return nil end
  local ran,data=pcall(chunk)
  if not ran then return nil end
  return normalize(data)
end

local function writeCache(mod,data)
  if not (mod and mod.cache and type(mod.cache.write)=="function") then return false end
  local ok,a=pcall(mod.cache.write,mod.cache,CACHE_PATH,serialize(data))
  return ok and a~=false
end

function M.extract(disc)
  return parse(commonRelBlob(disc),machineRows(disc))
end

function M.load(mod,openDisc)
  local cached=readCache(mod)
  if cached then cached.cached=true;return cached end
  assert(type(openDisc)=="function","GC6E01 source opener unavailable")
  local disc,why=openDisc();assert(disc,why or "GC6E01 source unavailable")
  local data=M.extract(disc)
  writeCache(mod,data)
  data.cached=false
  return data
end

M.cachePath=CACHE_PATH
M._test={parse=parse,valid=valid,normalize=normalize,serialize=serialize,internalForDex=internalForDex,
  constants={movesBase=MOVES_BASE,movesStride=MOVES_STRIDE,moveCount=MOVE_COUNT,
    statsBase=STATS_BASE,statsStride=STATS_STRIDE,tmCompatOffset=TM_COMPAT_OFFSET,
    machineCount=MACHINE_COUNT,levelOffset=LEVEL_OFFSET,levelSlots=LEVEL_SLOTS,
    dolTmTableOffset=DOL_TM_TABLE_OFFSET,dolTmStride=DOL_TM_STRIDE}}
return M
