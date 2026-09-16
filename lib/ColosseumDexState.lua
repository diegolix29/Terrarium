-- Conservative production ColosseumDex display/state compatibility layer.
-- This is the graduated speculative implementation: it installs no hooks,
-- mutates no host data registry, and never writes a native Pokedex bitfield.
-- It builds a read-only 001-386 catalog and stores ONLY nonnative seen/caught
-- state in a separate modData document.
local V=... or {}
local Identity=assert(V.ColosseumDexIdentity or V.IdentityCompat,"ColosseumDexIdentity dependency required")
local OwnedSidecar=V.ColosseumDexOwnedSidecar or V.OwnedPokemonSidecar

local C={
  VERSION=1,
  SCHEMA="expanded-national-dex-v1",
  BUCKET="expandedNationalDexV1",
  MAX_DEX=386,
}

local function fail(code,path,detail)
  return nil,{code=code,path=path,detail=detail}
end

local function copy(v,seen)
  if type(v)~="table" then return v end
  seen=seen or {};if seen[v] then return seen[v] end
  local out={};seen[v]=out
  for k,val in pairs(v)do out[copy(k,seen)]=copy(val,seen) end
  return out
end

local function nativeLimit(generation)
  return Identity.nativeDexLimit(tonumber(generation))
end

local function rowDex(row)
  return tonumber(row and (row.dex or row.number))
end

local function rowId(row)
  return row and (row.id or row.name)
end

local function rowStable(row)
  local dex=rowDex(row);local id=rowId(row)
  if not dex or not id then return nil end
  return row.stableKey or row.__nationalDex or Identity.stableId(dex,row.name or id)
end

local function tables(registry)
  return registry and (registry.byDex or registry.recordsByDex),
         registry and (registry.byId or registry.recordsById)
end

local function resolve(registry,identity)
  local byDex,byId=tables(registry)
  local row
  if type(identity)=="number" then row=byDex and byDex[identity]
  elseif type(identity)=="string" then
    row=byId and byId[identity]
    if not row then local dex=tonumber(identity);if dex then row=byDex and byDex[dex] end end
  elseif type(identity)=="table" then
    -- A table supplied by a runtime caller is an identity claim, not a trusted
    -- registry row. Re-anchor it through the immutable catalog so forged
    -- storage/stable-key metadata can never route an extended species into a
    -- native Pokédex write.
    local claimedDex=tonumber(identity.dex or identity.number)
    local claimedId=identity.id or identity.species
    if claimedId~=nil and type(claimedId)~="string" then
      return fail("unknown-dex-identity","identity",identity)
    end
    if identity.id~=nil and identity.species~=nil and identity.id~=identity.species then
      return fail("dex-identity-mismatch","identity",tostring(identity.id).." != "..tostring(identity.species))
    end
    local dexRow=claimedDex and byDex and byDex[claimedDex] or nil
    local idRow=claimedId and byId and byId[claimedId] or nil
    if claimedDex and claimedId then
      if not dexRow or not idRow or dexRow~=idRow then
        return fail("dex-identity-mismatch","identity",tostring(claimedDex).." / "..tostring(claimedId))
      end
      row=dexRow
    elseif claimedDex then row=dexRow
    elseif claimedId then row=idRow
    end
  end
  local dex=rowDex(row);local id=rowId(row)
  if not row or not dex or dex%1~=0 or dex<1 or dex>C.MAX_DEX or type(id)~="string" then
    return fail("unknown-dex-identity","identity",identity)
  end
  return row
end

local function dexKey(dex)return ("%03d"):format(assert(tonumber(dex)))end

function C.newDocument(generation)
  generation=tonumber(generation)
  assert(generation==1 or generation==2,"host generation must be 1 or 2")
  return {schema=C.SCHEMA,version=C.VERSION,hostGeneration=generation,
    nativeLimit=nativeLimit(generation),seen={},caught={}}
end

local function validateStateMap(map,name,generation,registry)
  if type(map)~="table" then return false,{code="invalid-dex-sidecar",path="sidecar."..name,detail="expected table"} end
  local limit=nativeLimit(generation)
  for k,stable in pairs(map)do
    if type(k)~="string" then return false,{code="invalid-dex-key",path="sidecar."..name,detail=k} end
    local dex=tonumber(k)
    if not dex or dex%1~=0 or dex<=limit or dex>C.MAX_DEX or k~=dexKey(dex) then
      return false,{code="invalid-extended-dex",path="sidecar."..name.."."..tostring(k),detail=dex}
    end
    local row=select(1,resolve(registry,dex))
    if not row then return false,{code="missing-registry-row",path="sidecar."..name.."."..k,detail=dex} end
    local expected=rowStable(row)
    if stable~=expected then
      return false,{code="stable-identity-mismatch",path="sidecar."..name.."."..k,detail=stable}
    end
  end
  return true
end

function C.validateDocument(doc,generation,registry)
  generation=tonumber(generation)
  if generation~=1 and generation~=2 then return false,{code="invalid-host-generation",path="generation",detail=generation} end
  if type(doc)~="table" then return false,{code="invalid-dex-sidecar",path="sidecar",detail="expected table"} end
  local allowed={schema=true,version=true,hostGeneration=true,nativeLimit=true,seen=true,caught=true}
  for k in pairs(doc)do
    if not allowed[k] then return false,{code="unknown-dex-sidecar-field",path="sidecar."..tostring(k),detail="unknown document field"} end
  end
  if doc.schema~=C.SCHEMA then return false,{code="dex-sidecar-schema-mismatch",path="sidecar.schema",detail=doc.schema} end
  if doc.version~=C.VERSION then return false,{code="dex-sidecar-version-mismatch",path="sidecar.version",detail=doc.version} end
  if tonumber(doc.hostGeneration)~=generation then return false,{code="dex-sidecar-host-mismatch",path="sidecar.hostGeneration",detail=doc.hostGeneration} end
  if tonumber(doc.nativeLimit)~=nativeLimit(generation) then return false,{code="dex-sidecar-native-limit-mismatch",path="sidecar.nativeLimit",detail=doc.nativeLimit} end
  local ok,err=validateStateMap(doc.seen,"seen",generation,registry);if not ok then return false,err end
  ok,err=validateStateMap(doc.caught,"caught",generation,registry);if not ok then return false,err end
  for k,stable in pairs(doc.caught)do
    if doc.seen[k]~=stable then
      return false,{code="caught-without-seen",path="sidecar.caught."..k,detail=stable}
    end
  end
  return true
end

function C.document(save,generation,registry)
  local raw=save and save.modData and save.modData[C.BUCKET]
  if raw==nil then return C.newDocument(generation),{created=true} end
  local ok,err=C.validateDocument(raw,generation,registry);if not ok then return nil,err end
  return copy(raw),{created=false}
end

function C.markRoute(generation,registry,identity,kind)
  generation=tonumber(generation);kind=kind or "seen"
  if generation~=1 and generation~=2 then return fail("invalid-host-generation","generation",generation) end
  if kind~="seen" and kind~="caught" then return fail("invalid-dex-mark","kind",kind) end
  local row,err=resolve(registry,identity);if not row then return nil,err end
  local dex=rowDex(row);local id=rowId(row);local limit=nativeLimit(generation)
  if dex<=limit then
    return {route="native",dex=dex,species=id,
      nativeField=kind=="seen" and "seen" or (generation==1 and "owned" or "caught")}
  end
  return {route="extended-sidecar",dex=dex,species=id,key=dexKey(dex),stableKey=rowStable(row),field=kind}
end

-- Returns a COPY with only modData.expandedNationalDexV1 changed. Native
-- save.pokedex is intentionally never touched here.
function C.markExtended(save,generation,registry,identity,kind)
  local route,err=C.markRoute(generation,registry,identity,kind);if not route then return nil,err end
  if route.route~="extended-sidecar" then
    return fail("native-dex-state-owned-by-host","identity",route.species)
  end
  local doc,derr=C.document(save,generation,registry);if not doc then return nil,derr end
  doc.seen[route.key]=route.stableKey
  if kind=="caught" then doc.caught[route.key]=route.stableKey end
  local out=copy(save or {})
  out.modData=out.modData or {}
  out.modData[C.BUCKET]=doc
  return out,doc,route
end

local function ownedExtendedDexes(save,generation,registry)
  local out={}
  local bucket=OwnedSidecar and OwnedSidecar.BUCKET or "expandedOwnedPokemonV1"
  local doc=save and save.modData and save.modData[bucket]
  if not doc then return out end
  if not OwnedSidecar then return fail("owned-sidecar-provider-required","save.modData."..bucket,"OwnedPokemonSidecar dependency not injected") end
  local valid,verr=OwnedSidecar.validateDocument(doc,generation,nativeLimit(generation))
  if not valid then return nil,verr end
  for uid,entry in pairs(doc.mons or {})do
    local dex=tonumber(entry and entry.dex)
    local row=select(1,resolve(registry,dex))
    if not dex or not row or Identity.storageClass(generation,dex)~="extended" then
      return fail("invalid-owned-dex-identity","save.modData."..bucket..".mons."..tostring(uid),dex)
    end
    local id=rowId(row);local stable=rowStable(row)
    if entry.uid~=uid or entry.stableKey~=stable or entry.species~=id
       or entry.sidecarKey~=Identity.sidecarKey(dex,uid) then
      return fail("owned-dex-identity-mismatch","save.modData."..bucket..".mons."..tostring(uid),entry and entry.species)
    end
    local _,stateErr=OwnedSidecar.unpackState(entry.state,generation,
      "save.modData."..bucket..".mons."..tostring(uid)..".state")
    if stateErr then return nil,stateErr end
    out[dex]=true
  end
  return out
end

-- A read-only merged state view. Native rows read ONLY the host's native
-- Pokedex table. Extended rows read ONLY this module's sidecar, with a possessed
-- extended mon from the owned-Pokemon sidecar treated as caught+seen (the same physical
-- invariant the host enforces for possessed native Pokemon).
function C.snapshot(save,generation,registry)
  generation=tonumber(generation)
  if generation~=1 and generation~=2 then return fail("invalid-host-generation","generation",generation) end
  local doc,derr=C.document(save,generation,registry);if not doc then return nil,derr end
  local owned,oerr=ownedExtendedDexes(save,generation,registry);if not owned then return nil,oerr end
  local byDex=tables(registry)
  local nativeDex=(save and save.pokedex) or {}
  local nativeSeen=nativeDex.seen or {}
  local nativeCaught=(generation==1 and nativeDex.owned) or nativeDex.caught or {}
  local limit=nativeLimit(generation)
  local rowsByDex,rows={},{}
  local counts={seen=0,caught=0,nativeSeen=0,nativeCaught=0,extendedSeen=0,extendedCaught=0,ownedInferred=0}
  for dex=1,C.MAX_DEX do
    local src=byDex and byDex[dex]
    if not src then return fail("missing-registry-row","registry.byDex."..dex,dex) end
    local id=rowId(src);local isNative=dex<=limit
    local seen,caught,stateSource
    if isNative then
      caught=nativeCaught[id]==true
      seen=nativeSeen[id]==true
      -- Gen1 PokedexMenu explicitly counts an owned row as seen even if the
      -- stored seen table is malformed/missing that key.
      if generation==1 and caught then seen=true end
      stateSource="native-pokedex"
    else
      local key=dexKey(dex)
      seen=doc.seen[key]~=nil;caught=doc.caught[key]~=nil
      stateSource="extended-dex-sidecar"
      if owned[dex] then
        if not caught then counts.ownedInferred=counts.ownedInferred+1 end
        caught=true;seen=true;stateSource="owned-sidecar-invariant"
      end
    end
    if seen then counts.seen=counts.seen+1;if isNative then counts.nativeSeen=counts.nativeSeen+1 else counts.extendedSeen=counts.extendedSeen+1 end end
    if caught then counts.caught=counts.caught+1;if isNative then counts.nativeCaught=counts.nativeCaught+1 else counts.extendedCaught=counts.extendedCaught+1 end end
    local row={dex=dex,species=id,name=src.name or id,stableKey=rowStable(src),types=copy(src.types or {}),
      sourceKind=src.sourceKind or src.__source,storageClass=isNative and "native" or "extended",
      seen=seen,caught=caught,stateSource=stateSource,registryRow=src}
    rowsByDex[dex]=row;rows[#rows+1]=row
  end
  return {generation=generation,nativeLimit=limit,maxDex=C.MAX_DEX,rows=rows,rowsByDex=rowsByDex,counts=counts}
end

local function blockedDexes(limit)
  local out={};for dex=limit+1,C.MAX_DEX do out[#out+1]=dex end;return out
end

-- Source-backed list ordering. Gen1 has one National order. Gen2 OLD is the
-- National/index order and can extend naturally to 386. Gold NEW and A-Z are
-- literal 251-entry ROM tables; without a new explicit policy no >251 species
-- is appended or re-sorted here.
function C.catalog(snapshot,mode,opts)
  if type(snapshot)~="table" or type(snapshot.rowsByDex)~="table" then return fail("invalid-dex-snapshot","snapshot","snapshot required") end
  opts=opts or {};mode=tostring(mode or "NATIONAL"):upper()
  local rows={}
  if snapshot.generation==1 then
    if mode~="NATIONAL" and mode~="OLD" then return fail("unsupported-dex-order","mode",mode) end
    for dex=1,C.MAX_DEX do rows[#rows+1]=snapshot.rowsByDex[dex] end
    return {generation=1,mode="NATIONAL",rows=rows,extendedPlacement="national-source-order"}
  end
  if mode=="NATIONAL" or mode=="OLD" then
    for dex=1,C.MAX_DEX do rows[#rows+1]=snapshot.rowsByDex[dex] end
    return {generation=2,mode="OLD",rows=rows,extendedPlacement="national-source-order"}
  end
  if mode~="NEW" and mode~="A-Z" then return fail("unsupported-dex-order","mode",mode) end
  local dexData=opts.gen2Pokedex or {}
  local order=(mode=="NEW" and dexData.newOrder) or dexData.alphabeticalOrder
  if type(order)~="table" then return fail("missing-native-dex-order","mode",mode) end
  for _,id in ipairs(order)do
    local found
    for dex=1,snapshot.nativeLimit do
      local row=snapshot.rowsByDex[dex]
      if row and row.species==id then found=row;break end
    end
    if not found then return fail("native-order-identity-mismatch","mode",id) end
    rows[#rows+1]=found
  end
  return {generation=2,mode=mode,rows=rows,extendedPlacement="blocked-no-retail-order",
    blockedExtendedDexes=blockedDexes(snapshot.nativeLimit),
    blocker="Gold NEW/A-Z order tables contain only the 251 native species; no retail placement for National Dex 252-386 is source-proven"}
end

function C.listItems(catalog)
  local out={}
  for _,row in ipairs((catalog and catalog.rows) or {})do
    out[#out+1]={dex=row.dex,species=row.species,
      label=("%03d %s"):format(row.dex,row.seen and row.name or "-----"),
      ball=row.caught and true or nil,value=row.seen and row.species or nil,
      seen=row.seen,caught=row.caught,storageClass=row.storageClass}
  end
  return out
end

-- Generic array navigation matching the host containers' arithmetic rather than
-- a byte-sized species cursor. pageSize=7 is Gen1 ListMenu's default; Gen2 uses
-- direct +/-1 wrap on the list.
function C.navigate(rows,index,delta,opts)
  local n=type(rows)=="table" and #rows or 0
  if n==0 then return 1,0 end
  opts=opts or {};index=math.max(1,math.min(n,math.floor(tonumber(index) or 1)))
  delta=math.floor(tonumber(delta) or 0)
  if opts.page then delta=delta*(tonumber(opts.pageSize) or 7) end
  local nextIndex=index+delta
  if opts.wrap then nextIndex=((nextIndex-1)%n)+1
  else nextIndex=math.max(1,math.min(n,nextIndex)) end
  local visible=math.max(1,math.floor(tonumber(opts.visibleRows) or 7))
  local scroll=math.max(0,math.min(nextIndex-1,math.max(0,n-visible)))
  return nextIndex,scroll
end

-- Display-only species record: deliberately omits native `index`. Feeding a
-- National Dex number into raw world/script species-index APIs is outside this
-- layer and remains blocked.
function C.presentation(registry,identity,generation)
  local row,err=resolve(registry,identity);if not row then return nil,err end
  local dex=rowDex(row);local src=row.sourceDef or {}
  return {id=rowId(row),name=row.name or rowId(row),dex=dex,numberText=("%03d"):format(dex),
    stableKey=rowStable(row),types=copy(row.types or {}),storageClass=Identity.storageClass(generation,dex),
    sourceKind=row.sourceKind,displayOnly=true,index=nil,
    spriteFront=src.spriteFront,spriteBack=src.spriteBack,icon=src.icon}
end

-- Source provenance for the DATA page. A Johto row displayed by a Gen1 host may
-- reuse the exact Gold donor dex record, but needs a cross-generation renderer:
-- Gen1 DexEntryMenu and Gen2 PokedexMenu expect different entry shapes.
function C.detail(snapshotRow,generation,opts)
  opts=opts or {};generation=tonumber(generation)
  if type(snapshotRow)~="table" then return fail("invalid-dex-row","row","row required") end
  local dex=tonumber(snapshotRow.dex);local id=snapshotRow.species
  if not snapshotRow.seen then return {status="hidden-unseen",dex=dex,species=id} end
  if dex<=nativeLimit(generation) then
    if generation==1 then
      local def=opts.gen1Pokemon and opts.gen1Pokemon[id]
      if def and def.dexEntry then return {status="source-backed-native",format="gen1",entry=copy(def.dexEntry)} end
    else
      local e=opts.gen2Pokedex and opts.gen2Pokedex.entries and opts.gen2Pokedex.entries[id]
      if e then return {status="source-backed-native",format="gen2",entry=copy(e)} end
    end
    return {status="blocked-missing-native-entry",dex=dex,species=id}
  end
  if generation==1 and dex<=251 then
    local e=opts.gen2Pokedex and opts.gen2Pokedex.entries and opts.gen2Pokedex.entries[id]
    if e then
      return {status="source-backed-cross-gen",format="gen2-donor",entry=copy(e),
        blocker="Gen1 DexEntryMenu cannot consume the Gen2 donor entry shape directly; a cross-generation renderer/normalizer is required"}
    end
    return {status="blocked-missing-johto-donor-entry",dex=dex,species=id}
  end
  local e=opts.extendedEntries and opts.extendedEntries[id]
  if type(e)=="table" and e.sourceBacked==true then
    local out=copy(e);out.sourceBacked=nil
    return {status="source-backed-extended",format=e.format or "extended",entry=out}
  end
  return {status="blocked-no-source-backed-entry",dex=dex,species=id,
    blocker="ColosseumDexCatalog proves identity/name/actor coverage for this species but does not provide source-backed Pokedex description/measurement presentation"}
end

function C.actions(snapshotRow,generation,opts)
  opts=opts or {}
  local d=C.detail(snapshotRow,generation,opts)
  local cry=type(opts.cryAvailable)=="function" and opts.cryAvailable(snapshotRow.species,snapshotRow)==true
  local area=type(opts.areaAvailable)=="function" and opts.areaAvailable(snapshotRow.species,snapshotRow)==true
  return {
    DATA={available=d and d.status and d.status:sub(1,13)=="source-backed",detail=d},
    CRY={available=cry,blocker=cry and nil or "no source-backed host cry provider for this extended species"},
    AREA={available=area,blocker=area and nil or "no source-backed host nest/area provider for this extended species"},
  }
end

-- Exact consequence of GenSave.lua's fixed 19B owned + 19B seen flag arrays and
-- unbounded `bitSet(..., dex-1, ...)` loop. Offsets are relative to sMainData.
function C.gen1RawDexWriteRisk(dex)
  dex=tonumber(dex)
  if not dex or dex%1~=0 or dex<1 then return nil,"invalid dex" end
  local bit=dex-1;local byte=math.floor(bit/8);local bitInByte=bit%8
  local ownedOffset=byte;local seenOffset=19+byte
  local function region(off)
    if off<19 then return "owned-array" end
    if off<38 then return "seen-array" end
    if off==38 then return "numBagItems" end
    return "later-main-data"
  end
  local status
  if dex<=151 then status="native"
  elseif byte==18 then status="invalid-padding-bit"
  else status="corrupts-neighboring-native-data" end
  return {dex=dex,status=status,bitIndex=bit,byteIndex=byte,bitInByte=bitInByte,
    ownedWriteOffset=ownedOffset,ownedWriteRegion=region(ownedOffset),
    seenWriteOffset=seenOffset,seenWriteRegion=region(seenOffset)}
end

C.HOST_SEAMS={
  [1]={
    {id="dex.catalog",source="src/ui/PokedexMenu.lua",anchor="for species, def in pairs(game.data.pokemon) do",
      requirement="inject/use an extended catalog view instead of expanding game.data.pokemon or constants.dexSize"},
    {id="dex.entry",source="src/ui/DexEntryMenu.lua",anchor="self.def = game.data.pokemon[species]",
      requirement="resolve DATA pages through a display provider; Johto donor entries need a cross-gen renderer"},
    {id="pokemon.presentation",source="src/ui/SummaryMenu.lua",anchor="Font.draw(mon.nickname or def.name",
      requirement="menus need a display-definition resolver for extended species; never assign a raw Gen1 species index"},
    {id="dex.state",source="src/battle/BattleState.lua",anchor="dex.seen[species] = true",
      requirement="central seen/caught router: native writes stay native, >151 writes go to expandedNationalDexV1"},
    {id="raw-sram-guard",source="src/save_convert/GenSave.lua",anchor="for dex, species in pairs(cw.pokemonByDex) do",
      requirement="keep extended defs out of GenSave crosswalk or hard-bound raw Pokedex serialization to dex<=151"},
    {id="sidecar-persistence",source="src/core/SaveData.lua",anchor="SaveSerializer.encode(gameOnly)",
      requirement="persist expandedNationalDexV1 as opaque modData; raw .sav export remains native-only"},
  },
  [2]={
    {id="dex.catalog",source="src/ui/gen2/PokedexMenu.lua",anchor="self.dex = opts.pokedex or data.gen2Pokedex",
      requirement="Game2 caller can pass a merged immutable dex/pokemon view; OLD/National may include 252-386"},
    {id="dex.order",source="src/ui/gen2/PokedexMenu.lua",anchor="if mode == \"NEW\" and dex.newOrder then return dex.newOrder end",
      requirement="do not place 252-386 in NEW/A-Z without a deliberate non-retail ordering policy"},
    {id="pokemon.presentation",source="src/ui/gen2/SummaryMenu.lua",anchor="return mon and self.pokemon and self.pokemon[mon.species] or nil",
      requirement="summary/party/box presentation needs an extended display-definition resolver; raw world species index remains native"},
    {id="raw-index-guard",source="src/world/gen2/World.lua",anchor="if type(def) == \"table\" and def.index == index then return id, def end",
      requirement="display-only extended definitions must not acquire native def.index values or enter raw world/script species-index lookup"},
    {id="dex.state",source="src/ui/gen2/BattleState.lua",anchor="save.pokedex.caught[enemy.species] = true",
      requirement="central seen/caught router: native writes stay native, >251 writes go to expandedNationalDexV1"},
    {id="caller-injection",source="src/core/Game2.lua",anchor="Screens.push(self, \"Gen2PokedexMenu\", { onClose = back })",
      requirement="supply the merged dex/pokemon view at the existing PokedexMenu opts seam"},
    {id="sidecar-persistence",source="src/core/gen2/Save.lua",anchor="local encoded = SaveSerializer.encode(save)",
      requirement="lazily persist expandedNationalDexV1 in modData/unknown save fields; do not rewrite native caught/seen tables for extended rows"},
  },
}

function C.hostSeams(generation)return copy(C.HOST_SEAMS[tonumber(generation)] or {})end
C.resolve=resolve
C.dexKey=dexKey
C.deepCopy=copy
return C
