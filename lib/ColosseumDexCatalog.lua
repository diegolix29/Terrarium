-- Immutable 001-386 ColosseumDex identity/catalog registry.
--
-- This is intentionally a presentation/state registry, not a replacement for
-- game.data.pokemon. Extended rows never receive a host `index`; callers that
-- need raw cartridge species ids must go through nativeIndex(), which refuses
-- Johto-on-Gen1 and Hoenn-on-either-host.
local V=... or {}
local Identity=assert(V.ColosseumDexIdentity,"ColosseumDexIdentity dependency required")
local Names=assert(V.ColosseumDexNames,"ColosseumDexNames dependency required")
local AssetDex=V.ColosseumDex

local C={VERSION=1,MAX_DEX=386}

local function fail(code,path,detail)
  return nil,{code=code,path=path,detail=detail}
end

local function validGeneration(generation)
  generation=tonumber(generation)
  if generation~=1 and generation~=2 then return nil end
  return generation
end

local function byDexFromPokemon(pokemon,limit)
  local out={}
  for key,def in pairs(type(pokemon)=="table" and pokemon or {}) do
    if type(def)=="table" then
      local dex=tonumber(def.dex)
      if dex and dex%1==0 and dex>=1 and dex<=limit then
        if out[dex] and out[dex].def~=def then
          return fail("duplicate-native-dex","hostPokemon."..tostring(dex),dex)
        end
        out[dex]={id=def.id or key,def=def}
      end
    end
  end
  return out
end

local function sanitizedDisplayDef(def)
  if type(def)~="table" then return nil end
  local out={}
  -- Only source-backed presentation fields cross this boundary. In particular
  -- `index` is never copied from an extended provider.
  for _,key in ipairs({"id","name","dex","types","spriteFront","spriteBack","icon","dexEntry"}) do
    if def[key]~=nil then out[key]=def[key] end
  end
  return out
end

local function extendedDefFor(opts,dex,id)
  local defs=opts.extendedDefinitions
  if type(defs)~="table" then return nil end
  local def=defs[id] or defs[dex]
  if type(def)~="table" or def.sourceBacked~=true then return nil end
  local claimed=tonumber(def.dex)
  if claimed and claimed~=dex then return false,{code="extended-dex-mismatch",path="extendedDefinitions."..id..".dex",detail=claimed} end
  return def
end

function C.build(opts)
  opts=opts or {}
  local generation=validGeneration(opts.hostGeneration or opts.generation)
  if not generation then return fail("invalid-host-generation","generation",opts.hostGeneration or opts.generation) end
  local limit=Identity.nativeDexLimit(generation)
  local native,nerr=byDexFromPokemon(opts.hostPokemon or (opts.data and opts.data.pokemon),limit)
  if not native then return nil,nerr end

  local registry={
    version=C.VERSION,hostGeneration=generation,nativeLimit=limit,maxDex=C.MAX_DEX,
    count=C.MAX_DEX,complete=true,byDex={},byId={},dexToId={},problems={},
  }
  for dex=1,C.MAX_DEX do
    local canonical=Names[dex]
    if type(canonical)~="string" or canonical=="" then
      return fail("missing-national-identity","names."..tostring(dex),dex)
    end
    local host=native[dex]
    local id=canonical
    local row={dex=dex,id=id,name=id,stableKey=Identity.stableId(dex,id),
      storageClass=Identity.storageClass(generation,dex),displayOnly=true,index=nil}

    if host then
      local hostId=tostring(host.id or "")
      if hostId~=canonical then
        return fail("native-identity-mismatch","hostPokemon."..tostring(dex),hostId.." != "..canonical)
      end
      row.name=host.def.name or canonical
      row.types=host.def.types
      row.sourceKind="host-native"
      row.sourceDef=host.def
    else
      local ext,eerr=extendedDefFor(opts,dex,canonical)
      if ext==false then return nil,eerr end
      if ext then
        row.name=ext.name or canonical
        row.types=ext.types
        row.sourceKind="source-backed-extended"
        row.sourceDef=sanitizedDisplayDef(ext)
      else
        -- Name + National number + Colosseum actor identity are independently
        -- source-backed. Mechanics/detail fields stay absent rather than guessed.
        row.sourceKind="national-identity"
      end
    end

    if AssetDex and type(AssetDex.supported)=="function" and not AssetDex.supported(dex) then
      registry.complete=false
      registry.problems[#registry.problems+1]={code="missing-colosseum-actor",dex=dex,species=id}
    end
    registry.byDex[dex]=row
    registry.byId[id]=row
    registry.dexToId[dex]=id
  end
  return registry
end

function C.resolve(registry,identity)
  if type(registry)~="table" then return fail("invalid-registry","registry","expected table") end
  local row
  if type(identity)=="number" then row=registry.byDex and registry.byDex[identity]
  elseif type(identity)=="string" then
    row=registry.byId and registry.byId[identity]
    if not row then local dex=tonumber(identity);row=dex and registry.byDex and registry.byDex[dex] or nil end
  elseif type(identity)=="table" then
    -- Treat caller-provided tables as identity CLAIMS only. Never trust their
    -- storageClass/sourceDef/stableKey fields: those fields decide whether a
    -- raw cartridge index may be used and therefore must come from this
    -- registry's canonical row.
    local claimedDex=tonumber(identity.dex or identity.number)
    local claimedId=identity.id or identity.species
    if claimedId~=nil and type(claimedId)~="string" then
      return fail("unknown-dex-identity","identity",identity)
    end
    if identity.id~=nil and identity.species~=nil and identity.id~=identity.species then
      return fail("dex-identity-mismatch","identity",tostring(identity.id).." != "..tostring(identity.species))
    end
    local byDex=claimedDex and registry.byDex and registry.byDex[claimedDex] or nil
    local byId=claimedId and registry.byId and registry.byId[claimedId] or nil
    if claimedDex and claimedId then
      if not byDex or not byId or byDex~=byId then
        return fail("dex-identity-mismatch","identity",tostring(claimedDex).." / "..tostring(claimedId))
      end
      row=byDex
    elseif claimedDex then row=byDex
    elseif claimedId then row=byId
    end
  end
  if not row or not tonumber(row.dex) or type(row.id)~="string" then
    return fail("unknown-dex-identity","identity",identity)
  end
  return row
end

function C.nativeIndex(registry,identity)
  local row,err=C.resolve(registry,identity);if not row then return nil,err end
  if row.storageClass~="native" then
    return fail("extended-native-index-blocked","identity",row.id)
  end
  local index=tonumber(row.sourceDef and row.sourceDef.index)
  if not index then return fail("missing-native-index","identity",row.id) end
  return index
end

return C
