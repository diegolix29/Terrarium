-- Source-backed additions for ORDINARY gameplay, not the Mt. Battle projection.
-- Names are runtime keys only: never assign an index, patch a native species,
-- extend a raw cartridge index map, or append to a native Pokedex ordering.
local V=... or {}
local Source=V.ColosseumPokemonMoveData
local Names=assert(V.ColosseumDexNames,'ColosseumDexNames required')
local PortraitIndex=V.ColosseumPortraitIndex
local req=V.engineRequire or require
local S={VERSION=1}
local result={ready=false,registered=0,blocker='species registration has not run'}
local TYPE={ [0]='NORMAL',[1]='FIGHTING',[2]='FLYING',[3]='POISON',[4]='GROUND',
  [5]='ROCK',[6]='BUG',[7]='GHOST',[8]='STEEL',[10]='FIRE',[11]='WATER',
  [12]='GRASS',[13]='ELECTRIC',[14]='PSYCHIC_TYPE',[15]='ICE',[16]='DRAGON',[17]='DARK' }
-- The source PokemonStats growth byte uses the Generation III enumeration.
-- The two piecewise curves follow integer arithmetic in the GBA source tables.
local CURVE_NAMES={[0]='MEDIUM_FAST',[1]='ERRATIC',[2]='FLUCTUATING',
  [3]='MEDIUM_SLOW',[4]='FAST',[5]='SLOW'}
local function expFor(code,n)
  n=math.max(1,math.min(100,math.floor(tonumber(n) or 1)))
  local c=n*n*n
  if code==0 then return c end
  if code==1 then
    if n<=50 then return math.floor(c*(100-n)/50) end
    if n<=68 then return math.floor(c*(150-n)/100) end
    if n<=98 then return math.floor(c*math.floor((1911-10*n)/3)/500) end
    return math.floor(c*(160-n)/100)
  end
  if code==2 then
    if n<=15 then return math.floor(c*(math.floor((n+1)/3)+24)/50) end
    if n<=36 then return math.floor(c*(n+14)/50) end
    return math.floor(c*(math.floor(n/2)+32)/50)
  end
  if code==3 then return math.max(0,math.floor(6*c/5)-15*n*n+100*n-140) end
  if code==4 then return math.floor(4*c/5) end
  if code==5 then return math.floor(5*c/4) end
  error('unsupported source growth code '..tostring(code))
end
local function get(reg,id)
  return reg and type(reg.get)=='function' and reg:get(id) or nil
end
local function each(reg,fn)
  if not (reg and type(reg.each)=='function') then return false end
  for id,def in reg:each() do fn(id,def) end;return true
end
local function registerMissing(reg,id,row)
  if get(reg,id)==nil then reg:register(id,row);return true end
  return false
end
-- Only matchups INVOLVING added Gen-I types. Every original type/type pair
-- remains the host cartridge's own rule. These rows already exist in the
-- project's source-backed MtBattle/BattleData type oracle.
local NEW_TYPE_ROWS=[[
NORMAL STEEL 5
FIRE STEEL 20
GRASS STEEL 5
ICE STEEL 5
FIGHTING DARK 20
FIGHTING STEEL 20
POISON STEEL 0
GROUND STEEL 20
FLYING STEEL 5
PSYCHIC_TYPE DARK 0
PSYCHIC_TYPE STEEL 5
BUG DARK 20
BUG STEEL 5
ROCK STEEL 5
GHOST DARK 5
GHOST STEEL 5
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
local function installGrowthRuntime()
  -- Pokemon.new's Gen-I caller does not pass the registry; hook ONLY our
  -- namespaced curves at its shared resolver, preserving native curves.
  local ok,Growth=pcall(req,'src.pokemon.Growth')
  if not ok or type(Growth.expForLevel)~='function' then return false end
  if Growth.__colosseumDexCurves then return true end
  local original=Growth.expForLevel
  Growth.expForLevel=function(id,level,rates)
    local n=type(id)=='string' and id:match('^CBE_DEX_GROWTH_([0-5])$')
    if n then return expFor(tonumber(n),level) end
    return original(id,level,rates)
  end
  Growth.__colosseumDexCurves=true
  return true
end
function S.register(mod,generation)
  if result.ready then return S.status() end
  generation=tonumber(generation)
  local c=mod and mod.content
  local function fail(why) result.blocker=why;return S.status() end
  if generation~=1 and generation~=2 then return fail('unsupported host generation') end
  if not (Source and Source.discId=='GC6E01' and type(Source.species)=='table') then
    return fail('GC6E01 PokemonStats source unavailable')
  end
  for _,key in ipairs({'pokemon','moves','growth_rates','type_chart'}) do
    if not(c and c[key] and type(c[key].get)=='function' and type(c[key].register)=='function') then
      return fail('content registry unavailable: '..key)
    end
  end
  local rawMoves={}
  if not each(c.moves,function(id,def)
    local n=type(def)=='table' and tonumber(def.colosseumMoveId or def.index)
    if n and not rawMoves[n] then rawMoves[n]=id end
  end) then return fail('move registry iteration unavailable') end
  if not (PortraitIndex and type(PortraitIndex.faceForDex)=='function') then
    return fail('source portrait identity mapping unavailable')
  end
  local records,unavailable={},{}
  local normalPaths,shinyPaths={},{}
  local limit=generation==1 and 151 or 251
  local function asset(path)
    if mod.assets and type(mod.assets.path)=='function' then return mod.assets:path(path) end
    return path
  end
  -- Preflight the whole payload before registering any species.
  for dex=limit+1,386 do
    local id=Names[dex]
    if not get(c.pokemon,id) then
      local src=Source.species[dex]
      if type(src)~='table' or type(src.baseStats)~='table' or type(src.levelMoves)~='table'
          or not CURVE_NAMES[tonumber(src.growthRateId)] then
        return fail('incomplete source PokemonStats: '..tostring(id))
      end
      local types={}
      for _,n in ipairs(src.typeIds or {}) do
        local t=TYPE[tonumber(n)]
        if not t then return fail('unknown source type: '..id) end
        if types[#types]~=t then types[#types+1]=t end
      end
      if #types==0 then return fail('missing source types: '..id) end
      local bs=src.baseStats
      for _,k in ipairs({'hp','attack','defense','speed','specialAttack','specialDefense'}) do
        local n=tonumber(bs[k]);if not n or n<1 or n>255 then return fail('invalid base stat: '..id..'.'..k) end
      end
      local levels,first,tmhm={}, {}, {}
      for _,entry in ipairs(src.levelMoves) do
        local raw=tonumber(entry.rawMoveId or entry[2]);local level=tonumber(entry.level or entry[1])
        local move=rawMoves[raw]
        if move and level and level>=1 and level<=100 then
          levels[#levels+1]={level=level,move=move}
          if level<=1 then first[#first+1]=move end
        end
      end
      -- Preserve source order at equal levels. Never invent a substitute move.
      if #levels==0 or levels[1].level>1 then unavailable[#unavailable+1]=id end
      for _,slot in ipairs(src.machineSlots or {}) do
        local machine=Source.machines and Source.machines[slot]
        local move=machine and rawMoves[tonumber(machine.rawMoveId)]
        if move then tmhm[#tmhm+1]=move end
      end
      -- Existing source portraits are a visible native-screen fallback, not
      -- a fake carrier sprite or a blank image. Normal CBE battles still use
      -- the real 3D species model. Hoenn portrait IDs are NOT national IDs.
      local face=PortraitIndex.faceForDex(dex)
      if not face then return fail('missing source portrait mapping: '..id) end
      local front=asset(('assets/portraits/%03d_1.png'):format(face))
      normalPaths[id]=front
      shinyPaths[id]=asset(('assets/portraits/%03d_1_shiny.png'):format(face))
      local row={id=id,name=id:gsub('_',' '),dex=dex,types=types,
        baseStats={hp=bs.hp,attack=bs.attack,defense=bs.defense,speed=bs.speed},
        catchRate=src.catchRate,baseExp=src.baseExp,
        growthRate='CBE_DEX_GROWTH_'..src.growthRateId,tmhm=tmhm,evolutions={},
        spriteFront=front,spriteBack=front,trueColor=true}
      if generation==1 then
        row.baseStats.special=bs.specialAttack
        row.level1Moves=first;row.learnset=levels;row.frontSize=7
      else
        row.baseStats.specialAttack=bs.specialAttack;row.baseStats.specialDefense=bs.specialDefense
        row.levelMoves=levels;row.picSize=7;row.genderRatio=src.genderRatio
        row.growthRateId=src.growthRateId;row.source='GC6E01 PokemonStats'
      end
      records[#records+1]={id=id,row=row}
    end
  end
  if generation==1 then
    registerMissing(c.type_chart,'DARK',{name='DARK',category='special'})
    registerMissing(c.type_chart,'STEEL',{name='STEEL',category='physical'})
    for a,d,m in NEW_TYPE_ROWS:gmatch('([A-Z_]+)%s+([A-Z_]+)%s+(%d+)') do
      registerMissing(c.type_chart,a..'>'..d,{multiplier=tonumber(m)})
    end
  end
  for code=0,5 do
    local captured=code
    registerMissing(c.growth_rates,'CBE_DEX_GROWTH_'..code,{expForLevel=function(n) return expFor(captured,n) end})
  end
  if generation==1 and not installGrowthRuntime() then return fail('Gen-I growth resolver unavailable') end
  for _,entry in ipairs(records) do c.pokemon:register(entry.id,entry.row) end
  if mod.hooks and type(mod.hooks.wrap)=='function' then
    mod.hooks:wrap('pokemon.sprite',function(next,path,ctx)
      local resolved=next(path,ctx)
      local id=ctx and ctx.species
      if normalPaths[id] and (resolved==normalPaths[id] or resolved==shinyPaths[id]) then
        ctx.trueColor=true
        return ctx.mon and ctx.mon.shiny==true and shinyPaths[id] or normalPaths[id]
      end
      return resolved
    end,115)
  end
  result={ready=true,registered=#records,generation=generation,blockedStartingMoves=unavailable,
    source='GC6E01 PokemonStats',nativeLimit=limit,blocker=nil}
  return S.status()
end
function S.usable(data,species,level)
  local def=data and data.pokemon and data.pokemon[species]
  if type(def)~='table' then return false end
  local moves=data.moves or {};level=tonumber(level) or 1
  for _,id in ipairs(def.level1Moves or {}) do if moves[id] then return true end end
  for _,entry in ipairs(def.levelMoves or def.learnset or {}) do
    if entry.level<=level and moves[entry.move] then return true end
  end
  return false
end
function S.status()
  local out={};for k,v in pairs(result) do out[k]=v end;return out
end
S._test={expFor=expFor,types=TYPE,newTypeRows=NEW_TYPE_ROWS}
return S
