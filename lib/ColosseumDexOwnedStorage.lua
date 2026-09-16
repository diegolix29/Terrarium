-- Production mixed native/expanded ColosseumDex owned-Pokemon storage adapter.
--
-- A runtime-expanded Pokemon lives as an ordinary logical party/box table while
-- the game is running. prepareWrite() produces a COPY in which native party/box
-- arrays contain only host-native Pokemon and the removed nonnative mons plus
-- exact slot layouts live in one modData sidecar bucket. hydrate() reverses it.
-- The live save passed in is never mutated.
local V=... or {}
local IdentityCompat=assert(V.ColosseumDexIdentity or V.IdentityCompat,"ColosseumDexIdentity dependency required")
local Sidecar=assert(V.ColosseumDexOwnedSidecar or V.OwnedPokemonSidecar,"ColosseumDexOwnedSidecar dependency required")
local A={}
local hydratedSaves=setmetatable({},{__mode="k"})

local function fail(code,path,detail)return nil,{code=code,path=path,detail=detail}end
local function deepCopy(v)return Sidecar.deepCopy(v)end

local function nativeLimit(gen)return IdentityCompat.nativeDexLimit(gen)end

local function registryRow(registry,species)
  if not registry then return nil end
  local row=(registry.byId and registry.byId[species]) or (registry.recordsById and registry.recordsById[species])
  if row then return row end
  return nil
end

local function rowDex(row)
  return tonumber(row and (row.dex or row.number or row.index))
end

local function rowStable(row,dex,species)
  return row and (row.stableKey or row.__nationalDex) or IdentityCompat.stableId(dex,species)
end

local function classify(registry,generation,mon,path)
  if type(mon)~="table" or type(mon.species)~="string" or mon.species=="" then
    return fail("invalid-mon",path,"missing species")
  end
  local row=registryRow(registry,mon.species)
  if not row then return fail("unknown-species",path..".species",mon.species) end
  local dex=rowDex(row)
  if not dex then return fail("unprojectable-identity",path..".species",mon.species) end
  local class,why=IdentityCompat.storageClass(generation,dex)
  if not class then return fail("unprojectable-identity",path..".species",why) end
  return {class=class,dex=dex,row=row,stableKey=rowStable(row,dex,mon.species)}
end

-- Known non-array owned locations. Version 2 preserves these in the same
-- document rather than permitting a deposit which makes the next save fail.
local OTHER_PATHS={daycare={"daycare","mon"},man={"dayCare","man","mon"},
  lady={"dayCare","lady","mon"},egg={"dayCare","egg"}}
local function atPath(save,path)
  local t=save;for _,k in ipairs(path) do t=type(t)=="table" and t[k] or nil end;return t
end
local function setPath(save,path,value)
  local t=save
  for i=1,#path-1 do t[path[i]]=t[path[i]] or {};t=t[path[i]] end
  t[path[#path]]=value
end

local function hasPartyMail(save)
  local party=save and save.mail and save.mail.party
  if type(party)~="table" then return false end
  return next(party)~=nil
end

local function boxIndexes(boxes)
  local out={}
  for k,v in pairs(type(boxes)=="table" and boxes or {}) do
    if type(k)=="number" and k%1==0 and k>=1 and type(v)=="table" then out[#out+1]=k end
  end
  table.sort(out)
  return out
end

local function uidFor(mon,dex,used,counter)
  local uid=type(mon.__expandedOwnedUid)=="string" and mon.__expandedOwnedUid or nil
  if uid and uid~="" then
    if used[uid] then return nil,{code="duplicate-owned-uid",path="mon.__expandedOwnedUid",detail=uid} end
    used[uid]=true;return uid
  end
  repeat
    counter.n=counter.n+1
    uid=("x%03d-%04d"):format(dex,counter.n)
  until not used[uid] and not counter.reserved[uid]
  used[uid]=true
  return uid
end

local function appendList(list,path,generation,registry,doc,used,counter)
  local native={}
  local layout={}
  local extendedCount=0
  for i,mon in ipairs(list or {}) do
    local info,err=classify(registry,generation,mon,path.."["..i.."]");if not info then return nil,nil,nil,err end
    if info.class=="native" then
      native[#native+1]=deepCopy(mon)
      layout[#layout+1]={kind="native",ordinal=#native}
    else
      extendedCount=extendedCount+1
      local uid,uidErr=uidFor(mon,info.dex,used,counter);if not uid then return nil,nil,nil,uidErr end
      local state,e=Sidecar.packState(mon,generation,path.."["..i.."]");if not state then return nil,nil,nil,e end
      doc.mons[uid]={uid=uid,dex=info.dex,species=mon.species,stableKey=info.stableKey,
        sidecarKey=IdentityCompat.sidecarKey(info.dex,uid),state=state}
      layout[#layout+1]={kind="extended",uid=uid}
    end
  end
  return native,layout,extendedCount
end

local function scanAnyExtended(save,generation,registry)
  for i,mon in ipairs(save.party or {}) do
    local info,err=classify(registry,generation,mon,"save.party["..i.."]");if not info then return nil,err end
    if info.class=="extended" then return true end
  end
  for _,b in ipairs(boxIndexes(save.boxes)) do
    local box=save.boxes[b]
    for i,mon in ipairs(box or {}) do
      local info,err=classify(registry,generation,mon,("save.boxes[%d][%d]"):format(b,i));if not info then return nil,err end
      if info.class=="extended" then return true end
    end
  end
  for name,path in pairs(OTHER_PATHS) do
    local mon=atPath(save,path)
    if type(mon)=="table" then
      local info,err=classify(registry,generation,mon,"save."..table.concat(path,"."));if not info then return nil,err end
      if info.class=="extended" then return true end
    end
  end
  return false
end

local function partyHasExtended(save,generation,registry)
  for i,mon in ipairs(save.party or {}) do
    local info,err=classify(registry,generation,mon,"save.party["..i.."]");if not info then return nil,err end
    if info.class=="extended" then return true end
  end
  return false
end

function A.prepareWrite(save,generation,registry)
  generation=tonumber(generation)
  if generation~=1 and generation~=2 then return fail("invalid-host-generation","generation",generation) end
  if type(save)~="table" then return fail("invalid-save","save","expected table") end
  if save.box~=nil and save.boxes==nil then
    local any,err=scanAnyExtended({party=save.party or {},boxes={save.box or {}}},generation,registry)
    if err then return nil,err end
    if any then return fail("legacy-box-shape","save.box","run native box migration before expanded storage") end
  end
  local any,err=scanAnyExtended(save,generation,registry);if any==nil then return nil,err end
  local existing=save.modData and save.modData[Sidecar.BUCKET]
  if not any and existing==nil then return save,nil,{changed=false,nativeOnly=true} end
  if not any and existing~=nil and not hydratedSaves[save] then
    return fail("sidecar-requires-hydration","save.modData."..Sidecar.BUCKET,
      "refusing to erase a sidecar from a native disk projection that this adapter has not hydrated")
  end
  local partyExtended,partyErr=partyHasExtended(save,generation,registry);if partyExtended==nil then return nil,partyErr end

  local out=deepCopy(save)
  out.modData=out.modData or {}
  if not any then
    out.modData[Sidecar.BUCKET]=nil
    return out,nil,{changed=true,removedStaleSidecar=true,nativeOnly=true}
  end

  local doc={schema=Sidecar.SCHEMA,version=Sidecar.VERSION,hostGeneration=generation,
    nativeLimit=nativeLimit(generation),featureRequired=true,partyLayout={},boxLayouts={},mons={}}
  -- Reserve every existing identity before allocating IDs for new captures.
  -- Traversal encounters the party before the PC: without this first pass a
  -- fresh party mon could take an ID held by a previously hydrated boxed mon.
  local reserved={}
  local function reserve(mon,path)
    local uid=type(mon)=="table" and mon.__expandedOwnedUid
    if type(uid)=="string" and uid~="" then
      if reserved[uid] then return fail("duplicate-owned-uid",path..".__expandedOwnedUid",uid) end
      reserved[uid]=true
    end
    return true
  end
  for i,mon in ipairs(save.party or {}) do
    local ok,e=reserve(mon,"save.party["..i.."]");if not ok then return nil,e end
  end
  for _,b in ipairs(boxIndexes(save.boxes)) do
    for i,mon in ipairs(save.boxes[b]) do
      local ok,e=reserve(mon,("save.boxes[%d][%d]"):format(b,i));if not ok then return nil,e end
    end
  end
  for _,path in pairs(OTHER_PATHS) do
    local ok,e=reserve(atPath(save,path),"save."..table.concat(path,"."));if not ok then return nil,e end
  end
  local used,counter={}, {n=0,reserved=reserved}
  local nativeParty,partyLayout,partyExtended,e=appendList(save.party or {},"save.party",generation,registry,doc,used,counter)
  if not nativeParty then return nil,e end
  out.party=nativeParty;doc.partyLayout=partyLayout
  doc.nativeFallbackUnsafe=(#(save.party or {})>0 and #nativeParty==0)
  local totalExtended=partyExtended

  out.boxes={}
  for _,b in ipairs(boxIndexes(save.boxes)) do
    local box=save.boxes[b]
    local nativeBox,layout,count,boxErr=appendList(box,"save.boxes["..b.."]",generation,registry,doc,used,counter)
    if not nativeBox then return nil,boxErr end
    out.boxes[b]=nativeBox;doc.boxLayouts[b]=layout;totalExtended=totalExtended+count
  end
  -- Slot-indexed mail is transported with the logical party layout. The
  -- native projection must not attach it to a different, compacted party.
  if partyExtended>0 and generation==2 and hasPartyMail(save) then
    doc.partyMail=deepCopy(save.mail.party);out.mail.party={}
  end
  for name,path in pairs(OTHER_PATHS) do
    local mon=atPath(save,path)
    if type(mon)=="table" then
      local info,e=classify(registry,generation,mon,"save."..table.concat(path,"."));if not info then return nil,e end
      if info.class=="extended" then
        local _,layout,count,otherErr=appendList({mon},"save."..table.concat(path,"."),generation,registry,doc,used,counter)
        if not layout then return nil,otherErr end
        doc.otherLayouts=doc.otherLayouts or {};doc.otherLayouts[name]=layout
        setPath(out,path,nil);totalExtended=totalExtended+count
      end
    end
  end
  doc.extendedCount=totalExtended
  out.modData[Sidecar.BUCKET]=doc
  return out,doc,{changed=true,extendedCount=totalExtended,nativeFallbackUnsafe=doc.nativeFallbackUnsafe}
end

local function resolveExtended(entry,generation,registry,path)
  if type(entry)~="table" then return fail("invalid-sidecar-mon",path,"expected table") end
  local entryFields={uid=true,dex=true,species=true,stableKey=true,sidecarKey=true,state=true}
  for k in pairs(entry) do if not entryFields[k] then return fail("unknown-sidecar-field",path.."."..tostring(k),"unknown mon field") end end
  if type(entry.uid)~="string" or entry.uid=="" then return fail("invalid-sidecar-mon",path..".uid",entry.uid) end
  local dex=tonumber(entry.dex)
  if not dex or dex%1~=0 then return fail("invalid-sidecar-mon",path..".dex",entry.dex) end
  local class=IdentityCompat.storageClass(generation,dex)
  if class~="extended" then return fail("sidecar-native-species",path..".dex",dex) end
  local row=registry and registry.byDex and registry.byDex[dex]
  if not row and registry and registry.recordsByDex then row=registry.recordsByDex[dex] end
  if not row then return fail("missing-projected-species",path..".dex",dex) end
  local species=row.id or (registry.dexToId and registry.dexToId[dex])
  if type(species)~="string" then return fail("missing-projected-species",path..".dex",dex) end
  local stable=rowStable(row,dex,species)
  if entry.stableKey~=stable then return fail("stable-identity-mismatch",path..".stableKey",entry.stableKey) end
  if entry.species and entry.species~=species then return fail("species-identity-mismatch",path..".species",entry.species) end
  local expectedKey=IdentityCompat.sidecarKey(dex,entry.uid)
  if entry.sidecarKey~=expectedKey then return fail("sidecar-key-mismatch",path..".sidecarKey",entry.sidecarKey) end
  local state,err=Sidecar.unpackState(entry.state,generation,path..".state");if not state then return nil,err end
  state.species=species;state.__expandedOwnedUid=entry.uid;state.__nationalDex=stable
  return state
end

local function rebuildList(native,layout,doc,generation,registry,path,usedNative,usedExtended)
  if type(layout)~="table" then return fail("invalid-layout",path,"expected table") end
  local out={}
  for i,ref in ipairs(layout) do
    if type(ref)~="table" then return fail("invalid-layout",path.."["..i.."]","expected ref table") end
    if ref.kind=="native" then
      for k in pairs(ref) do if k~="kind" and k~="ordinal" then return fail("unknown-sidecar-field",path.."["..i.."]."..tostring(k),"unknown native ref field") end end
      local n=tonumber(ref.ordinal)
      if not n or n%1~=0 or not native[n] then return fail("missing-native-reference",path.."["..i.."]",ref.ordinal) end
      if usedNative[n] then return fail("duplicate-native-reference",path.."["..i.."]",n) end
      usedNative[n]=true;out[#out+1]=deepCopy(native[n])
    elseif ref.kind=="extended" then
      for k in pairs(ref) do if k~="kind" and k~="uid" then return fail("unknown-sidecar-field",path.."["..i.."]."..tostring(k),"unknown extended ref field") end end
      local uid=ref.uid
      if type(uid)~="string" or not doc.mons[uid] then return fail("missing-extended-reference",path.."["..i.."]",uid) end
      if usedExtended[uid] then return fail("duplicate-extended-reference",path.."["..i.."]",uid) end
      if doc.mons[uid].uid~=uid then return fail("sidecar-uid-mismatch","sidecar.mons."..uid..".uid",doc.mons[uid].uid) end
      local mon,err=resolveExtended(doc.mons[uid],generation,registry,"sidecar.mons."..uid);if not mon then return nil,err end
      usedExtended[uid]=true;out[#out+1]=mon
    else
      return fail("invalid-layout-kind",path.."["..i.."].kind",ref.kind)
    end
  end
  for i in ipairs(native) do if not usedNative[i] then return fail("unreferenced-native-mon",path,i) end end
  return out
end

function A.hydrate(save,generation,registry)
  generation=tonumber(generation)
  if generation~=1 and generation~=2 then return fail("invalid-host-generation","generation",generation) end
  if type(save)~="table" then return fail("invalid-save","save","expected table") end
  local doc=save.modData and save.modData[Sidecar.BUCKET]
  if doc==nil then return save,nil,{changed=false,noSidecar=true} end
  local valid,verr=Sidecar.validateDocument(doc,generation,nativeLimit(generation));if not valid then return nil,verr end
  local monCount=0;for _ in pairs(doc.mons) do monCount=monCount+1 end
  if doc.extendedCount~=nil and tonumber(doc.extendedCount)~=monCount then
    return fail("sidecar-count-mismatch","sidecar.extendedCount",doc.extendedCount)
  end
  if generation==2 and hasPartyMail(save) and #doc.partyLayout~=#(save.party or {}) and not doc.partyMail then
    return fail("mail-layout-nonprojectable","save.mail.party","cannot hydrate mixed Gen2 party while party mail exists")
  end
  local out=deepCopy(save)
  local usedExtended={}
  local usedNative={}
  local party,err=rebuildList(save.party or {},doc.partyLayout,doc,generation,registry,"sidecar.partyLayout",usedNative,usedExtended)
  if not party then return nil,err end
  out.party=party
  out.boxes={}
  for _,b in ipairs(boxIndexes(save.boxes)) do
    if doc.boxLayouts[b]==nil then return fail("missing-box-layout","sidecar.boxLayouts["..b.."]",b) end
  end
  for _,b in ipairs(boxIndexes(doc.boxLayouts)) do
    if not (save.boxes and save.boxes[b]) then return fail("missing-native-box","save.boxes["..b.."]",b) end
  end
  for _,b in ipairs(boxIndexes(doc.boxLayouts)) do
    local layout=doc.boxLayouts[b]
    local native=save.boxes and save.boxes[b] or {}
    local box,boxErr=rebuildList(native,layout,doc,generation,registry,"sidecar.boxLayouts["..b.."]",{},usedExtended)
    if not box then return nil,boxErr end
    out.boxes[b]=box
  end
  if doc.otherLayouts~=nil and type(doc.otherLayouts)~="table" then return fail("invalid-layout","sidecar.otherLayouts","expected table") end
  for name,layout in pairs(doc.otherLayouts or {}) do
    local path=OTHER_PATHS[name]
    if not path then return fail("unknown-owned-location","sidecar.otherLayouts."..tostring(name),name) end
    if atPath(save,path)~=nil then return fail("occupied-owned-location","save."..table.concat(path,"."),name) end
    if type(layout)~="table" or #layout~=1 or layout[1].kind~="extended" then return fail("invalid-layout","sidecar.otherLayouts."..name,"one extended reference required") end
    local list,err=rebuildList({},layout,doc,generation,registry,"sidecar.otherLayouts."..name,{},usedExtended)
    if not list then return nil,err end
    setPath(out,path,list[1])
  end
  if doc.partyMail~=nil then
    if generation~=2 or type(doc.partyMail)~="table" then return fail("invalid-mail-layout","sidecar.partyMail","Gen2 table required") end
    for slot,mail in pairs(doc.partyMail) do
      if type(slot)~="number" or slot%1~=0 or slot<1 or slot>#out.party or type(mail)~="table" then
        return fail("invalid-mail-layout","sidecar.partyMail."..tostring(slot),slot)
      end
    end
    if hasPartyMail(save) then return fail("mail-layout-conflict","save.mail.party","native projection must contain no displaced mail") end
    out.mail=out.mail or {};out.mail.party=deepCopy(doc.partyMail)
  end
  for uid in pairs(doc.mons) do if not usedExtended[uid] then return fail("unreferenced-extended-mon","sidecar.mons."..uid,uid) end end
  hydratedSaves[out]=true
  return out,doc,{changed=true,extendedCount=doc.extendedCount or 0,nativeFallbackUnsafe=doc.nativeFallbackUnsafe==true}
end

A.BUCKET=Sidecar.BUCKET
return A
