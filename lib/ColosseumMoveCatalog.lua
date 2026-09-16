-- Runtime resolver for source-backed Pokemon Colosseum MOVE PREP acquisition
-- data. This module never registers or synthesizes battle mechanics. A retail
-- raw move id is selectable only when the active Gen1/Gen2 host exposes an
-- executable move definition carrying that same numeric move index (or an
-- explicitly source-backed colosseumMoveId registration).
local V=... or {}
local Source=V.ColosseumPokemonMoveData
local Names=V.ColosseumDexNames or {}
local Verified=V.ColosseumVerifiedMoves
local C={}

local function hostGeneration()
  local status=V.ColosseumVerifiedMoveStatus
  local n=tonumber(status and status.generation)
  if n then return n end
  local compat=V.GenerationCompat
  if compat and type(compat.current)=="function" then
    local ok,value=pcall(compat.current)
    if ok and tonumber(value) then return tonumber(value) end
  end
  return nil
end

local dexByName={}
for dex,name in pairs(Names) do
  if type(dex)=="number" and type(name)=="string" then dexByName[name:upper()]=dex end
end

local lastMoves,lastRawMap=nil,nil
local function rawMoveMap(data)
  local moves=data and data.moves
  if moves==lastMoves and lastRawMap then return lastRawMap end
  local out={}
  for id,def in pairs(moves or {}) do
    if type(def)=="table" then
      -- Challenge-local registrations may carry a host-local numeric `index`
      -- while explicitly declaring the retail GC6E01 move they execute. Source
      -- acquisition legality is keyed to that Colosseum identity, so it must win
      -- over an unrelated host index if both fields are present.
      local raw=tonumber(def.colosseumMoveId or def.index)
      if raw and raw%1==0 and raw>0 and not out[raw] then out[raw]={id=id,def=def} end
    end
  end
  lastMoves,lastRawMap=moves,out
  return out
end

local function dexFor(game,mon)
  if type(mon)~="table" then return nil end
  local n=tonumber(mon.nationalDex)
  if n and n%1==0 and n>=1 and n<=386 then return n end
  n=tonumber(mon.dex)
  if n and n%1==0 and n>=1 and n<=386 then return n end
  local data=game and game.data or {}
  local def=data.pokemon and mon.species and data.pokemon[mon.species]
  if type(def)=="table" then
    n=tonumber(def.nationalDex)
    if n and n%1==0 and n>=1 and n<=386 then return n end
    n=tonumber(def.dex)
    if n and n%1==0 and n>=1 and n<=386 then return n end
  end
  local key=type(mon.species)=="string" and mon.species:upper() or nil
  return key and dexByName[key] or nil
end

local function unavailable(mon,why)
  return nil,{sourceBacked=false,failedClosed=true,species=mon and mon.species or nil,
    resolved=0,unresolved=0,error=tostring(why or "GC6E01 MOVE PREP source unavailable"),unresolvedEntries={}}
end

function C.pool(game,mon)
  if type(Source)~="table" or Source.discId~="GC6E01" or type(Source.species)~="table" then
    return unavailable(mon,Source and Source.error or "GC6E01 MOVE PREP source unavailable")
  end
  local dex=dexFor(game,mon)
  if not dex then return unavailable(mon,"National-Dex identity unresolved for MOVE PREP") end
  local species=Source.species[dex]
  if type(species)~="table" then return unavailable(mon,("GC6E01 PokemonStats row missing for dex %03d"):format(dex)) end

  local data=game and game.data or {}
  local raw=rawMoveMap(data)
  local rows,byId,unresolved={},{},{}
  local unresolvedByKey={}
  local unresolvedAcquisitions=0
  local function unresolvedRow(kind,rawMoveId,extra)
    unresolvedAcquisitions=unresolvedAcquisitions+1
    -- A source move can legitimately appear more than once in PokemonStats:
    -- e.g. Onix learns Sandstorm/Iron Tail by level AND carries the matching TM
    -- compatibility bit. MOVE PREP cares whether the MOVE is executable, not how
    -- many acquisition paths point at the same raw id. The old diagnostic counted
    -- each provenance row separately, so one unsupported move could inflate the
    -- red warning twice and made nearly every source-backed species look worse
    -- than it was. Preserve all provenance labels on one fail-closed row instead.
    local machineSlot=extra and tonumber(extra.machineSlot) or nil
    local key=rawMoveId and ("raw:"..tostring(rawMoveId))
      or ("machine:"..tostring(machineSlot or #unresolved+1))
    local prior=unresolvedByKey[key]
    if prior then
      prior.sources=prior.sources or {prior.kind}
      local seen=false;for _,value in ipairs(prior.sources) do if value==kind then seen=true;break end end
      if not seen then prior.sources[#prior.sources+1]=kind end
      if kind=="LEVEL" and prior.kind~="LEVEL" then
        prior.kind="LEVEL"
        if extra and extra.level~=nil then prior.level=extra.level end
      end
      return prior
    end
    local row={dex=dex,kind=kind,rawMoveId=rawMoveId,
      reason=(Verified and type(Verified.reason)=="function" and Verified.reason(rawMoveId,hostGeneration()))
        or "no source-proven executable host move definition"}
    for k,v in pairs(extra or {}) do row[k]=v end
    row.sources={kind}
    unresolved[#unresolved+1]=row;unresolvedByKey[key]=row
    return row
  end
  local function add(rawMoveId,source,extra)
    rawMoveId=tonumber(rawMoveId)
    local hit=rawMoveId and raw[rawMoveId] or nil
    if not hit then unresolvedRow(source,rawMoveId,extra);return end
    local id,def=hit.id,hit.def
    local row=byId[id]
    if not row then
      row={id=id,name=tostring(def.name or id),source=source,rawMoveId=rawMoveId,sourceBacked=true}
      for k,v in pairs(extra or {}) do row[k]=v end
      rows[#rows+1]=row;byId[id]=row
    elseif row.source~="LEVEL" and source=="LEVEL" then
      row.source="LEVEL";row.level=extra and extra.level or row.level
    end
  end

  for _,entry in ipairs(species.levelMoves or {}) do
    local level=tonumber(entry.level or entry[1])
    local rawMoveId=tonumber(entry.rawMoveId or entry[2])
    if level and level<=100 then add(rawMoveId,"LEVEL",{level=level}) end
  end
  for _,slotValue in ipairs(species.machineSlots or {}) do
    local slot=tonumber(slotValue)
    local machine=slot and Source.machines and Source.machines[slot] or nil
    if not machine then
      unresolvedRow("MACHINE",nil,{machineSlot=slot,reason="source machine row missing"})
    else
      local kind=machine.kind or machine[2] or (slot>50 and "HM" or "TM")
      local number=machine.number or machine[3] or (slot>50 and slot-50 or slot)
      local rawMoveId=machine.rawMoveId or machine[4]
      add(rawMoveId,kind,{machineSlot=slot,machineNumber=number})
    end
  end

  table.sort(rows,function(a,b)
    local order={LEVEL=1,HM=2,TM=3}
    local ao,bo=order[a.source] or 4,order[b.source] or 4
    if ao~=bo then return ao<bo end
    if a.source=="LEVEL" and b.source=="LEVEL" then
      local al,bl=tonumber(a.level) or 0,tonumber(b.level) or 0
      if al~=bl then return al<bl end
    elseif a.machineNumber and b.machineNumber and a.machineNumber~=b.machineNumber then
      return a.machineNumber<b.machineNumber
    end
    if a.name~=b.name then return a.name<b.name end
    return tostring(a.id)<tostring(b.id)
  end)

  return rows,{sourceBacked=true,failedClosed=#unresolved>0,dex=dex,species=mon and mon.species or nil,
    source=Source.source,cached=Source.cached==true,resolved=#rows,unresolved=#unresolved,
    unresolvedAcquisitions=unresolvedAcquisitions,unresolvedEntries=unresolved}
end

function C.diagnostics(game,mon)
  local _,diag=C.pool(game,mon);return diag
end
function C.dexFor(game,mon) return dexFor(game,mon) end
function C.status()
  return {available=type(Source)=="table" and Source.discId=="GC6E01" and type(Source.species)=="table",
    source=Source and Source.source or nil,error=Source and Source.error or nil,dexCount=Source and Source.dexCount or 0}
end

C._test={dexFor=dexFor,rawMoveMap=rawMoveMap,hostGeneration=hostGeneration}
return C
