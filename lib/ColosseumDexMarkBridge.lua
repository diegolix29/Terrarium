-- Central live-save guard for ColosseumDex seen/caught routing.
--
-- The host writes Pokedex flags directly in a number of battle/script/gift/
-- evolution/trade paths.  Editing every engine call site would be brittle and
-- would still leave future direct assignments exposed.  Instead, this module
-- keeps the host's native flag tables as the storage for native species and
-- installs a narrow metatable guard that diverts known nonnative National-Dex
-- keys into expandedNationalDexV1.
--
-- Native keys preserve raw table semantics exactly.  Extended keys are NEVER
-- rawset into save.pokedex.{seen,owned,caught}; reads are answered from the
-- sidecar so host "already seen/caught" checks retain their behavior.
local V=... or {}
local Identity=assert(V.ColosseumDexIdentity,"ColosseumDexIdentity dependency required")
local Names=assert(V.ColosseumDexNames,"ColosseumDexNames dependency required")
local State=assert(V.ColosseumDexState,"ColosseumDexState dependency required")

local B={VERSION=1}
local mod=V.mod
local guarded=setmetatable({},{__mode="k"})
local installed=false
local runtimeGeneration=nil
local stats={guards=0,migrated=0,extendedWrites=0,blockedWrites=0,lastError=nil}

-- A private immutable identity registry is sufficient for State's routing and
-- validation functions.  It deliberately contains no host/native raw indexes.
local registry={byDex={},byId={}}
local dexById={}
for dex=1,386 do
  local id=assert(Names[dex],"missing National-Dex identity "..tostring(dex))
  local row={dex=dex,id=id,name=id,stableKey=Identity.stableId(dex,id),index=nil}
  registry.byDex[dex]=row;registry.byId[id]=row;dexById[id]=dex
end

local function currentGeneration(explicit)
  local n=tonumber(explicit)
  if n==1 or n==2 then return n end
  if runtimeGeneration then return runtimeGeneration end
  local compat=V.GenerationCompat
  if compat and type(compat.current)=="function" then
    local ok,value=pcall(compat.current)
    value=ok and tonumber(value) or nil
    if value==1 or value==2 then runtimeGeneration=value;return value end
  end
  return nil
end

local function keyDex(key)
  if type(key)=="number" then
    return key%1==0 and key>=1 and key<=386 and key or nil
  end
  if type(key)~="string" then return nil end
  local n=tonumber(key)
  if n and n%1==0 and n>=1 and n<=386 then return n end
  return dexById[key:upper()]
end

local function extendedIdentity(key,generation)
  local dex=keyDex(key);if not dex then return nil end
  local class=Identity.storageClass(generation,dex)
  if class~="extended" then return nil end
  return dex,Names[dex]
end

local function logFailure(message)
  stats.blockedWrites=stats.blockedWrites+1
  stats.lastError=tostring(message)
  local l=mod and mod.log
  if l and type(l.error)=="function" then
    pcall(l.error,l,"ColosseumDex mark routing blocked: %s",stats.lastError)
  end
end

local function routeExtended(save,generation,species,kind)
  if type(save)~="table" then return false,"save unavailable" end
  if save.modData~=nil and type(save.modData)~="table" then
    return false,"save.modData is not a table"
  end
  local route,err=State.markRoute(generation,registry,species,kind)
  if not route then return false,err and (err.code or err.detail) or "mark route failed" end
  if route.route~="extended-sidecar" then return false,"identity is not extended" end
  local doc,derr=State.document(save,generation,registry)
  if not doc then return false,derr and (derr.code or derr.detail) or "dex sidecar invalid" end
  doc.seen[route.key]=route.stableKey
  if kind=="caught" then doc.caught[route.key]=route.stableKey end
  save.modData=save.modData or {}
  save.modData[State.BUCKET]=doc
  stats.extendedWrites=stats.extendedWrites+1
  return true
end

local function sidecarFlag(save,generation,dex,kind)
  local md=type(save)=="table" and save.modData or nil
  local doc=type(md)=="table" and md[State.BUCKET] or nil
  if type(doc)~="table" or doc.schema~=State.SCHEMA or doc.version~=State.VERSION
      or tonumber(doc.hostGeneration)~=generation then return nil end
  local map=kind=="seen" and doc.seen or doc.caught
  if type(map)~="table" then return nil end
  local key=State.dexKey(dex)
  local row=registry.byDex[dex]
  return map[key]==row.stableKey and true or nil
end

local function fallbackIndex(oldIndex,t,key)
  if type(oldIndex)=="function" then return oldIndex(t,key) end
  if type(oldIndex)=="table" then return oldIndex[key] end
  return nil
end

local function fallbackNewIndex(oldNewIndex,t,key,value)
  if type(oldNewIndex)=="function" then return oldNewIndex(t,key,value) end
  if type(oldNewIndex)=="table" then oldNewIndex[key]=value;return end
  rawset(t,key,value)
end

local function installFlagGuard(save,generation,field,kind,forceScrub)
  local pokedex=save.pokedex
  local flags=pokedex and pokedex[field]
  if type(flags)~="table" then return false,"save.pokedex."..field.." missing" end

  local info=guarded[flags]
  if info and not forceScrub then
    info.save=save;info.generation=generation;info.kind=kind
    return true
  end

  local existingMt=getmetatable(flags)
  if existingMt~=nil and type(existingMt)~="table" then
    return false,"save.pokedex."..field.." has a protected metatable"
  end
  if not info and existingMt and type(existingMt.__cbeColosseumDexMarkBridge)=="table" then
    info=existingMt.__cbeColosseumDexMarkBridge
    info.save=save;info.generation=generation;info.kind=kind;info.field=field
    guarded[flags]=info
    if not forceScrub then return true end
  end

  -- Scan once when a table is first guarded, and again only at save.write.
  -- Normal input.step calls stay O(1) after attachment; the serialization
  -- boundary still repairs rawset/foreign legacy bypasses before bytes are made.
  for key,value in pairs(flags) do
    local _,species=extendedIdentity(key,generation)
    if species then
      if value==true then
        local ok,why=routeExtended(save,generation,species,kind)
        if ok then stats.migrated=stats.migrated+1 else logFailure(why) end
      end
      rawset(flags,key,nil)
    end
  end
  if info then
    info.save=save;info.generation=generation;info.kind=kind;info.field=field
    return true
  end

  local mt={}
  if existingMt then for k,v in pairs(existingMt) do mt[k]=v end end
  local oldIndex,oldNewIndex=mt.__index,mt.__newindex
  info={save=save,generation=generation,kind=kind,field=field,
    oldIndex=oldIndex,oldNewIndex=oldNewIndex}
  mt.__cbeColosseumDexMarkBridge=info
  mt.__index=function(t,key)
    local dex=extendedIdentity(key,info.generation)
    if dex then
      local value=sidecarFlag(info.save,info.generation,dex,info.kind)
      if value~=nil then return value end
    end
    return fallbackIndex(info.oldIndex,t,key)
  end
  mt.__newindex=function(t,key,value)
    local _,species=extendedIdentity(key,info.generation)
    if species then
      if value==true then
        local ok,why=routeExtended(info.save,info.generation,species,info.kind)
        if not ok then logFailure(why) end
      else
        -- No current host path clears individual dex bits.  Refuse unexpected
        -- extended values rather than materializing them in the native table.
        logFailure("unsupported extended dex flag value for "..tostring(species))
      end
      return
    end
    return fallbackNewIndex(info.oldNewIndex,t,key,value)
  end
  local ok,why=pcall(setmetatable,flags,mt)
  if not ok then return false,tostring(why) end
  guarded[flags]=info;stats.guards=stats.guards+1
  return true
end

function B.ensureSave(save,generation,forceScrub)
  generation=currentGeneration(generation)
  if generation~=1 and generation~=2 then return false,"host generation unavailable" end
  if type(save)~="table" then return false,"save unavailable" end
  if type(save.pokedex)~="table" then return false,"save.pokedex unavailable" end
  if type(save.pokedex.seen)~="table" then return false,"save.pokedex.seen unavailable" end
  local fields=generation==1 and {{"seen","seen"},{"owned","caught"}}
    or {{"seen","seen"},{"caught","caught"}}
  for _,row in ipairs(fields) do
    if type(save.pokedex[row[1]])~="table" then
      return false,"save.pokedex."..row[1].." unavailable"
    end
    local ok,why=installFlagGuard(save,generation,row[1],row[2],forceScrub==true)
    if not ok then return false,why end
  end
  return true
end

function B.ensureGame(game,forceScrub)
  if type(game)~="table" then return false,"game unavailable" end
  return B.ensureSave(game.save,currentGeneration(),forceScrub)
end

function B.status()
  return {version=B.VERSION,installed=installed,guards=stats.guards,migrated=stats.migrated,
    extendedWrites=stats.extendedWrites,blockedWrites=stats.blockedWrites,lastError=stats.lastError,
    policy="native-raw/extended-expandedNationalDexV1"}
end

function B.install()
  if installed then if mod and mod.game then B.ensureGame(mod.game) end;return true,"already-installed" end
  if not (mod and mod.hooks and type(mod.hooks.wrap)=="function") then return false,"mod hooks unavailable" end

  -- Save lifecycle events cover new/continued games; input.step covers the host
  -- checkpoint restore path, which deliberately emits neither save.loaded nor
  -- save.created.  save.write is the last fail-safe before serialization.
  if mod.events and type(mod.events.on)=="function" then
    for _,name in ipairs({"save.created","save.loading","save.loaded"}) do
      mod.events:on(name,function(payload)
        local save=type(payload)=="table" and (payload.save or payload.raw) or nil
        if save then
          local ok,why=B.ensureSave(save,currentGeneration())
          if not ok then logFailure(why) end
        end
      end)
    end
    mod.events:on("game.ready",function(payload)
      local game=type(payload)=="table" and payload.game or nil
      if game then local ok,why=B.ensureGame(game);if not ok then logFailure(why) end end
    end)
  end
  mod.hooks:wrap("input.step",function(next,game,dt)
    local ok,why=B.ensureGame(game);if not ok then logFailure(why) end
    return next(game,dt)
  end,50000)
  mod.hooks:wrap("save.write",function(next,game,...)
    local ok,why=B.ensureGame(game,true);if not ok then logFailure(why) end
    return next(game,...)
  end,50000)
  installed=true
  if mod.game then local ok,why=B.ensureGame(mod.game);if not ok then logFailure(why) end end
  return true,"installed"
end

B._test={registry=registry,keyDex=keyDex,extendedIdentity=extendedIdentity,
  routeExtended=routeExtended,sidecarFlag=sidecarFlag}
return B
