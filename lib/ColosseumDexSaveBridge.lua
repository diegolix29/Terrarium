-- Checked copy-on-write integration at the HOST SAVE MODULE BOUNDARY.
-- No event temporarily removes Pokemon from game.save. Native projection and
-- sidecar are serialized by ONE original host writer into ONE .tmp/main/.bak
-- document. Reading hydrates only after the host's parse/migration succeeds,
-- before the game adopts the result. No custom filesystem or save path logic.
local V=... or {}
local R=assert(V.ColosseumDexRuntime,'ColosseumDexRuntime required')
local Owned=assert(V.ColosseumDexOwnedStorage,'ColosseumDexOwnedStorage required')
local Codec=assert(V.ColosseumDexOwnedSidecar,'ColosseumDexOwnedSidecar required')
local req=V.engineRequire or require
local B={VERSION=1}
local state={ready=false,installed=false,blocker='save bridge not installed',writes=0,loads=0,failures=0}
local gen,registry,owner,host,slot
local unpack=table.unpack or unpack
local function pack(...) return {n=select('#',...),...} end
local function message(err)
  if type(err)=='table' then return tostring(err.code)..' at '..tostring(err.path)..': '..tostring(err.detail) end
  return tostring(err)
end
local function report(err)
  state.failures=state.failures+1;state.lastError=message(err)
  local log=owner and owner.log
  if log and type(log.error)=='function' then pcall(log.error,log,'ColosseumDex save blocked: %s',state.lastError) end
  return state.lastError
end
local function isOurs(save)
  if type(save)~='table' or type(save.party)~='table' then return false end
  local g=tonumber(save.generation)
  if not g then
    local v=tostring(save.version or '')
    g=(v=='gold' or v=='silver' or v=='crystal') and 2 or 1
  end
  return g==gen
end
local function hasSidecar(save)
  return type(save)=='table' and type(save.modData)=='table' and save.modData[Codec.BUCKET]~=nil
end
local function hasExtended(save)
  local limit=gen==2 and 251 or 151
  local function expanded(mon)
    local row=type(mon)=='table' and registry.byId[mon.species]
    return row and row.dex>limit
  end
  for _,mon in ipairs(save.party or {}) do if expanded(mon) then return true end end
  for _,box in pairs(save.boxes or {}) do
    if type(box)=='table' then for _,mon in ipairs(box) do if expanded(mon) then return true end end end
  end
  local dc=save.daycare
  if dc and expanded(dc.mon) then return true end
  dc=save.dayCare
  if dc and (expanded(dc.man and dc.man.mon) or expanded(dc.lady and dc.lady.mon) or expanded(dc.egg)) then return true end
  return false
end
function B.prepare(save)
  if not isOurs(save) then return save,nil,{changed=false} end
  -- Other mods' native-only/custom saves are not ours to reinterpret.
  if not hasSidecar(save) and not hasExtended(save) then return save,nil,{changed=false} end
  return Owned.prepareWrite(save,gen,registry)
end
function B.restore(save)
  if not hasSidecar(save) then return save end
  if not isOurs(save) then return nil,'expanded sidecar belongs to another generation' end
  local species=V.ColosseumDexSpecies
  if species and species.status and species.status().ready~=true then
    return nil,'expanded species source unavailable; original save left untouched'
  end
  local restored,err=Owned.hydrate(save,gen,registry)
  if not restored then return nil,err end
  -- The disk layout is consumed, not kept as a stale runtime snapshot. Next
  -- save rebuilds it from the ACTUAL party/PC; releasing the last addition
  -- therefore cannot resurrect it or fail a "requires hydration" guard.
  restored.modData[Codec.BUCKET]=nil
  return restored
end
local function saveWrapped(record,save,...)
  local delegate=record.bridge
  if not delegate or not delegate.isOurs(save) then return record.save(save,...) end
  local ok,disk,err=pcall(delegate.prepare,save)
  if not ok or not disk then return false,delegate.report(ok and err or disk) end
  -- Codec errors happen before the host starts ANY write. Preflight its own
  -- serializer too: a bad unrelated value must not replace a good save.
  local encoded,why=pcall(record.serializer.encode,disk)
  if not encoded then return false,delegate.report(why) end
  -- Verify that the native-only disk copy can restore exactly once before
  -- the I/O boundary. This also detects duplicate UIDs/layout conflicts.
  if delegate.hasSidecar(disk) then
    local restored,e=delegate.restore(disk)
    if not restored then return false,delegate.report(e) end
  end
  local ret=pack(pcall(record.save,disk,...))
  if not ret[1] then return false,delegate.report(ret[2]) end
  if ret[2]~=true then delegate.report(ret[3] or 'host writer returned failure');return unpack(ret,2,ret.n) end
  if disk~=save then
    -- Let the host retain its normal bookkeeping without adopting compacted
    -- party arrays or replacing the live modData backing held by the loader.
    if disk.meta~=nil then save.meta=disk.meta end
    if disk.savedAt~=nil then save.savedAt=disk.savedAt end
  end
  delegate.state.writes=delegate.state.writes+1
  return unpack(ret,2,ret.n)
end
local function loadWrapped(record,...)
  local ret=pack(record.load(...))
  if ret[1] and record.bridge and record.bridge.hasSidecar(ret[1]) then
    local ok,restored,why=pcall(record.bridge.restore,ret[1])
    if not ok or not restored then
      local err=record.bridge.report(ok and why or restored)
      return nil,nil,'ColosseumDex restoration refused: '..err
    end
    ret[1]=restored;record.bridge.state.loads=record.bridge.state.loads+1
  end
  return unpack(ret,1,ret.n)
end
function B.install(mod,generation)
  gen=tonumber(generation);owner=mod
  if gen~=1 and gen~=2 then state.blocker='unsupported save generation';return false,state.blocker end
  registry=R.registry(nil,{generation=gen})
  if not registry then state.blocker='ColosseumDex identity registry unavailable';return false,state.blocker end
  local path=gen==2 and 'src.core.gen2.Save' or 'src.core.SaveData'
  local ok,h=pcall(req,path)
  local serOK,serializer=pcall(req,'src.core.SaveSerializer')
  if not ok or type(h)~='table' or type(h.save)~='function' or type(h.load)~='function'
      or not serOK or type(serializer.encode)~='function' then
    state.blocker='checked host save/load modules unavailable';return false,state.blocker
  end
  local record=h.__colosseumDexSaveBridgeV1
  if record and (h.save~=record.saveWrapper or h.load~=record.loadWrapper) then
    state.blocker='another module replaced the installed save bridge';return false,state.blocker
  end
  record=record or {save=h.save,load=h.load,serializer=serializer}
  record.bridge={prepare=B.prepare,restore=B.restore,isOurs=isOurs,hasSidecar=hasSidecar,report=report,state=state}
  if not record.saveWrapper then
    record.saveWrapper=function(save,...) return saveWrapped(record,save,...) end
    record.loadWrapper=function(...) return loadWrapped(record,...) end
  end
  h.save=record.saveWrapper;h.load=record.loadWrapper;h.__colosseumDexSaveBridgeV1=record
  host=h;slot=record
  state.ready=true;state.installed=true;state.blocker=nil;state.generation=gen
  state.module=path;state.policy='one-document/native-projection-plus-owned-sidecar'
  return true
end
function B.status()
  local out={};for k,v in pairs(state) do out[k]=v end
  if state.ready and (not host or host.save~=slot.saveWrapper or host.load~=slot.loadWrapper) then
    out.ready=false;out.blocker='save bridge was replaced after installation'
  end
  return out
end
B._test={hasExtended=hasExtended,isOurs=isOurs}
return B
