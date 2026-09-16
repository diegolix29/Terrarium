-- Production owned-Pokemon sidecar codec for ColosseumDex species that do not
-- fit the host generation's native species-id space. This is a plain-data codec
-- and deliberately installs no save hooks by itself.
local S={
  VERSION=2,
  SCHEMA="expanded-owned-v2",
  BUCKET="expandedOwnedPokemonV1",
}

local function failure(code,path,detail)
  return nil,{code=code,path=path,detail=detail}
end

local function copyScalar(v,path)
  local t=type(v)
  if t=="number" and (v~=v or v==math.huge or v==-math.huge) then return failure("non-finite-value",path,v) end
  if t=="nil" or t=="string" or t=="number" or t=="boolean" then return v end
  return failure("nonprojectable-value",path,"unsupported value type "..t)
end

local function copyMap(src,allowed,path,ranges)
  if src==nil then return nil end
  if type(src)~="table" then return failure("nonprojectable-field",path,"expected table") end
  local out={}
  for k,v in pairs(src) do
    if not allowed[k] then return failure("nonprojectable-field",path.."."..tostring(k),"unknown nested field") end
    local n=tonumber(v)
    local range=ranges and ranges[k]
    if range then
      if not n or n%1~=0 or n<range[1] or n>range[2] then
        return failure("field-out-of-range",path.."."..tostring(k),v)
      end
      out[k]=n
    else
      local c,e=copyScalar(v,path.."."..tostring(k));if e then return nil,e end
      out[k]=c
    end
  end
  return out
end

local DV_FIELDS={hp=true,attack=true,defense=true,speed=true,special=true,
  specialAttack=true,specialDefense=true}
local DV_RANGES={hp={0,15},attack={0,15},defense={0,15},speed={0,15},special={0,15},
  specialAttack={0,15},specialDefense={0,15}}
local STAT_FIELDS={hp=true,attack=true,defense=true,speed=true,special=true,
  specialAttack=true,specialDefense=true}
local STATEXP_RANGES={hp={0,65535},attack={0,65535},defense={0,65535},speed={0,65535},
  special={0,65535},specialAttack={0,65535},specialDefense={0,65535}}

local MOVE_FIELDS={id=true,pp=true,ppUps=true,maxPp=true,maxPP=true}
local function copyMoves(rows,path)
  if rows==nil then return {} end
  if type(rows)~="table" then return failure("nonprojectable-field",path,"moves must be a table") end
  if #rows>4 then return failure("too-many-moves",path,#rows) end
  local out={}
  for i,row in ipairs(rows) do
    if type(row)~="table" then return failure("nonprojectable-field",path.."["..i.."]","move row must be a table") end
    local m={}
    for k,v in pairs(row) do
      if not MOVE_FIELDS[k] then return failure("nonprojectable-field",path.."["..i.."]."..tostring(k),"unknown move field") end
      if k=="id" then
        if type(v)~="string" or v=="" then return failure("invalid-move-id",path.."["..i.."].id",v) end
        m.id=v
      else
        local n=tonumber(v)
        if not n or n%1~=0 or n<0 then return failure("field-out-of-range",path.."["..i.."]."..k,v) end
        m[k]=n
      end
    end
    if not m.id then return failure("invalid-move-id",path.."["..i.."].id","missing") end
    out[i]=m
  end
  return out
end

local function copyTypes(types,path)
  if types==nil then return nil end
  if type(types)~="table" then return failure("nonprojectable-field",path,"types must be a table") end
  local out={}
  for i,v in ipairs(types) do
    if type(v)~="string" or v=="" then return failure("nonprojectable-field",path.."["..i.."]","type id must be a string") end
    out[i]=v
  end
  return out
end

local COMMON={
  nickname=true,level=true,dvs=true,statExp=true,stats=true,hp=true,status=true,moves=true,
  ot=true,otName=true,otId=true,traded=true,shiny=true,
  __expandedOwnedUid=true,__nationalDex=true,
}
local G1={exp=true,catchRate=true}
local G2={name=true,experience=true,pokerus=true,maxHp=true,types=true,item=true,happiness=true,
  caughtLevel=true,caughtTime=true,caughtLocation=true,caughtByGender=true,
  gender=true,unownLetter=true,isEgg=true,statusTurns=true,eggSteps=true}

local function allowedFor(generation)
  local out={};for k in pairs(COMMON) do out[k]=true end
  local extra=tonumber(generation)==2 and G2 or G1
  for k in pairs(extra) do out[k]=true end
  return out
end

local function intField(state,key,lo,hi,path)
  if state[key]==nil then return nil end
  local n=tonumber(state[key])
  if not n or n%1~=0 or n<lo or n>hi then return failure("field-out-of-range",path.."."..key,state[key]) end
  return n
end

function S.packState(mon,generation,path)
  path=path or "mon"
  if type(mon)~="table" then return failure("invalid-mon",path,"expected table") end
  local allowed=allowedFor(generation)
  for k in pairs(mon) do
    if k~="species" and not allowed[k] then
      return failure("nonprojectable-field",path.."."..tostring(k),"field is not in the owned sidecar schema")
    end
  end
  local state={}
  local level,e=intField(mon,"level",1,100,path);if e then return nil,e end;state.level=level
  local hp,e2=intField(mon,"hp",0,9999,path);if e2 then return nil,e2 end;state.hp=hp
  local dvs,e3=copyMap(mon.dvs,DV_FIELDS,path..".dvs",DV_RANGES);if e3 then return nil,e3 end;state.dvs=dvs
  local statExp,e4=copyMap(mon.statExp,STAT_FIELDS,path..".statExp",STATEXP_RANGES);if e4 then return nil,e4 end;state.statExp=statExp
  local stats,e5=copyMap(mon.stats,STAT_FIELDS,path..".stats");if e5 then return nil,e5 end;state.stats=stats
  local moves,e6=copyMoves(mon.moves,path..".moves");if e6 then return nil,e6 end;state.moves=moves

  for _,k in ipairs({"nickname","status","ot","otName","traded","shiny"}) do
    if mon[k]~=nil then local v,err=copyScalar(mon[k],path.."."..k);if err then return nil,err end;state[k]=v end
  end
  if mon.otId~=nil then local v,err=intField(mon,"otId",0,65535,path);if err then return nil,err end;state.otId=v end

  if tonumber(generation)==1 then
    for _,k in ipairs({"exp","catchRate"}) do
      if mon[k]~=nil then local v,err=intField(mon,k,0,2147483647,path);if err then return nil,err end;state[k]=v end
    end
  else
    for _,k in ipairs({"experience","pokerus","maxHp","happiness","caughtLevel","caughtTime","caughtLocation","statusTurns","eggSteps"}) do
      if mon[k]~=nil then local v,err=intField(mon,k,0,2147483647,path);if err then return nil,err end;state[k]=v end
    end
    for _,k in ipairs({"name","item","gender","caughtByGender","unownLetter","isEgg"}) do
      if mon[k]~=nil then local v,err=copyScalar(mon[k],path.."."..k);if err then return nil,err end;state[k]=v end
    end
    local types,err=copyTypes(mon.types,path..".types");if err then return nil,err end;state.types=types
  end
  return state
end

local function deepCopy(v,seen)
  if type(v)~="table" then return v end
  seen=seen or {};if seen[v] then return seen[v] end
  local out={};seen[v]=out
  for k,val in pairs(v) do out[deepCopy(k,seen)]=deepCopy(val,seen) end
  return out
end

function S.unpackState(state,generation,path)
  path=path or "state"
  if type(state)~="table" then return failure("invalid-sidecar-state",path,"expected table") end
  for _,k in ipairs({"species","__expandedOwnedUid","__nationalDex"}) do
    if state[k]~=nil then return failure("nonprojectable-field",path.."."..k,"identity/runtime marker must not be stored inside state") end
  end
  -- Re-run the exact allowlist/range validator by treating state like a mon.
  local probe=deepCopy(state);probe.species="__PROBE__"
  local packed,err=S.packState(probe,generation,path)
  if not packed then return nil,err end
  return deepCopy(packed)
end

function S.validateDocument(doc,hostGeneration,nativeLimit)
  if type(doc)~="table" then return false,{code="invalid-sidecar",path="sidecar",detail="expected table"} end
  local allowed={schema=true,version=true,hostGeneration=true,nativeLimit=true,featureRequired=true,
    nativeFallbackUnsafe=true,partyLayout=true,boxLayouts=true,mons=true,extendedCount=true,partyMail=true,otherLayouts=true}
  for k in pairs(doc) do
    if not allowed[k] then return false,{code="unknown-sidecar-field",path="sidecar."..tostring(k),detail="unknown document field"} end
  end
  if doc.schema~=S.SCHEMA and doc.schema~="expanded-owned-v1" then return false,{code="sidecar-schema-mismatch",path="sidecar.schema",detail=doc.schema} end
  if not ((doc.version==S.VERSION and doc.schema==S.SCHEMA) or (doc.version==1 and doc.schema=="expanded-owned-v1")) then return false,{code="sidecar-version-mismatch",path="sidecar.version",detail=doc.version} end
  if doc.featureRequired~=true then return false,{code="invalid-sidecar",path="sidecar.featureRequired",detail="must be true"} end
  if tonumber(doc.hostGeneration)~=tonumber(hostGeneration) then
    return false,{code="sidecar-host-mismatch",path="sidecar.hostGeneration",detail=doc.hostGeneration}
  end
  if tonumber(doc.nativeLimit)~=tonumber(nativeLimit) then
    return false,{code="sidecar-native-limit-mismatch",path="sidecar.nativeLimit",detail=doc.nativeLimit}
  end
  if type(doc.partyLayout)~="table" or type(doc.boxLayouts)~="table" or type(doc.mons)~="table" then
    return false,{code="invalid-sidecar",path="sidecar",detail="missing layouts/mons"}
  end
  return true
end

S.deepCopy=deepCopy
S.failure=failure
return S
