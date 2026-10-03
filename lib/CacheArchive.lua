-- Packs the two huge Colosseum generated trees -- cache/pokemon/* and
-- cache/movefx/* -- into per-unit zlib blobs in LOVE's save directory, then
-- serves files back on demand. Extraction still writes loose files through
-- mod.cache; this module only runs after the user asks to pack, and only
-- deletes a loose original after that file's unit has been written and
-- round-tripped.
--
-- Units match how the runtime actually loads the cache: one Pokemon
-- species/variant, or one MoveFX WZX stem. A packed install is typically an
-- order of magnitude smaller than the loose RGBA/Lua dump (the user's ~30 GB
-- tree compressing under 3 GB) without putting a multi-gigabyte blob through
-- the host's small-file cache API.
--
-- Compression is LÖVE's built-in zlib (love.data.compress). No 7-Zip binary
-- is required. Identity files (Pokemon manifests, MoveFX index/coverage) stay
-- loose so BuildPipeline's launch-time readiness checks do not have to
-- decompress anything.
local V=...
local mod=V.mod
local WorkBudget=V.WorkBudget
local A={schema=1}

local ARCHIVE_ROOT="cbe_cache_archive"
local POKEMON_DIR=ARCHIVE_ROOT.."/pokemon"
local MOVEFX_DIR=ARCHIVE_ROOT.."/movefx"

local INDEX_POKEMON="cache/archive_v1/pokemon.lua"
local INDEX_MOVEFX="cache/archive_v1/movefx.lua"
local HOT_PATH="cache/archive_v1/hot.lua"
local MARKER_POKEMON="build/cache_archive_pokemon_v1.complete"
local MARKER_MOVEFX="build/cache_archive_movefx_v1.complete"

local POKEMON_SPECIES_COUNT=386
local POKEMON_MANIFEST_SHARD_SIZE=32
local POKEMON_MANIFEST_SHARDS=math.ceil(POKEMON_SPECIES_COUNT/POKEMON_MANIFEST_SHARD_SIZE)

local HOT_CAP_BYTES=1536*1024*1024
local MAGIC="CBEUNIT1"
local VERSION=1

local job=nil
local indexMemo={pokemon=nil,movefx=nil}

local function call(obj,name,...)
  if not obj or type(obj[name])~="function" then return nil,"unavailable" end
  local ok,a,b=pcall(obj[name],obj,...)
  if not ok then return nil,tostring(a) end
  return a,b
end

local function sep() return package.config:sub(1,1) end
local function ensureDirFor(rel)
  local dir=rel:match("^(.*)/[^/]+$")
  if dir then love.filesystem.createDirectory(dir) end
end
local function rmrf(rel)
  local info=love.filesystem.getInfo and love.filesystem.getInfo(rel)
  if not info then return end
  if info.type=="directory" then
    for _,name in ipairs(love.filesystem.getDirectoryItems(rel) or {}) do rmrf(rel.."/"..name) end
    pcall(love.filesystem.remove,rel)
  else
    pcall(love.filesystem.remove,rel)
  end
end

local function u32(n)
  n=math.floor(tonumber(n) or 0)%4294967296
  if n<0 then n=n+4294967296 end
  local b1=n%256;n=math.floor(n/256)
  local b2=n%256;n=math.floor(n/256)
  local b3=n%256;n=math.floor(n/256)
  return string.char(b1,b2,b3,n%256)
end
local function u16(n)
  n=math.floor(tonumber(n) or 0)%65536
  if n<0 then n=n+65536 end
  return string.char(n%256,math.floor(n/256))
end
local function ru32(s,i)
  local a,b,c,d=s:byte(i,i+3);if not d then return nil end
  return a+b*256+c*65536+d*16777216
end
local function ru16(s,i)
  local a,b=s:byte(i,i+1);if not b then return nil end
  return a+b*256
end

function A.available()
  if love and love.data and type(love.data.compress)=="function" and type(love.data.decompress)=="function" then
    return {label="LÖVE zlib",kind="zlib"}
  end
  return nil
end
function A.running()
  return job~=nil
end

local function compressBytes(raw)
  local tool=A.available()
  if not tool then return raw,0 end
  local ok,out=pcall(love.data.compress,"string","zlib",raw,9)
  if ok and type(out)=="string" and #out>0 then return out,1 end
  return raw,0
end
local function decompressBytes(packed,codec)
  if tonumber(codec)~=1 then return packed end
  local ok,out=pcall(love.data.decompress,"string","zlib",packed)
  if ok and type(out)=="string" then return out end
  return nil
end

local function looseRead(path)
  local v=select(1,call(mod.cache,"read",path))
  return type(v)=="string" and v or nil
end
local function looseExists(path)
  local info=select(1,call(mod.cache,"info",path))
  return type(info)=="table" and (info.type==nil or info.type=="file")
end
local function looseWrite(path,bytes)
  return call(mod.cache,"write",path,bytes)
end
local function looseDelete(path)
  return call(mod.cache,"delete",path)
end

local function loadLua(raw)
  if type(raw)~="string" then return {} end
  local chunk=load(raw,"@generated/cache-archive-index")
  if not chunk then return {} end
  local ok,value=pcall(chunk)
  if not ok or type(value)~="table" then return {} end
  return value
end

local function emptyIndex()
  return {originalBytes=0,entries={},byUnit={},archiveBytes=0}
end

local function readIndex(kind)
  if indexMemo[kind] then return indexMemo[kind] end
  local path=kind=="movefx" and INDEX_MOVEFX or INDEX_POKEMON
  local v=loadLua(select(1,call(mod.cache,"read",path)))
  if type(v)~="table" then v=emptyIndex() end
  v.byUnit=v.byUnit or {};v.entries=v.entries or {}
  v.originalBytes=tonumber(v.originalBytes) or 0
  v.archiveBytes=tonumber(v.archiveBytes) or 0
  indexMemo[kind]=v
  return v
end

local function writeIndex(kind,idx)
  local path=kind=="movefx" and INDEX_MOVEFX or INDEX_POKEMON
  local out={"return {originalBytes=",tostring(math.floor(idx.originalBytes or 0)),
    ",archiveBytes=",tostring(math.floor(idx.archiveBytes or 0)),",entries={"}
  for p,size in pairs(idx.entries) do
    out[#out+1]=("[%q]=%d,"):format(p,math.floor(tonumber(size) or 0))
  end
  out[#out+1]="},byUnit={"
  for key,paths in pairs(idx.byUnit) do
    out[#out+1]=("[%q]={"):format(key)
    for _,p in ipairs(paths) do out[#out+1]=("%q,"):format(p) end
    out[#out+1]="},"
  end
  out[#out+1]="}}\n"
  indexMemo[kind]=idx
  return call(mod.cache,"write",path,table.concat(out))
end

local function pinnedLoose(path)
  if path=="cache/movefx/index.lua" or path=="build/movefx_coverage.txt" then return true end
  if path=="cache/pokemon/manifest.lua" or path=="cache/pokemon/_last_attempt.txt" then return true end
  if path:find("^cache/pokemon/manifest_v2/",1,false) then return true end
  if path:find("^cache/archive_v1/",1,true) then return true end
  if path:find("^build/cache_archive_",1,true) then return true end
  return false
end

local function kindFor(path)
  if type(path)~="string" then return nil end
  if path:find("^cache/pokemon/",1,true) then return "pokemon" end
  if path:find("^cache/movefx/",1,true) then return "movefx" end
  return nil
end

local function unitKey(kind,path)
  if kind=="pokemon" then
    local dex,rest=path:match("^cache/pokemon/(%d+)/(.*)$")
    if not dex then return "_meta" end
    return dex..(rest:match("^shiny/") and "/shiny" or "/normal")
  end
  local stem=path:match("^cache/movefx/([^/]+)/")
  return stem or "_meta"
end

local function unitRel(kind,key)
  local safe=tostring(key):gsub("[^%w%-_]+","_")
  local dir=kind=="movefx" and MOVEFX_DIR or POKEMON_DIR
  return dir.."/"..safe..".cbeu"
end

local function pumpEvents()
  if love and love.event and type(love.event.pump)=="function" then pcall(love.event.pump) end
end

----------------------------------------------------------------------
-- Inventory
----------------------------------------------------------------------
local function loadManifestChunk(raw)
  return loadLua(raw)
end

local function pokemonManifestPaths()
  local out={}
  local function take(raw)
    for _,e in ipairs(loadManifestChunk(raw)) do
      if type(e)=="table" and type(e.paths)=="table" then
        for _,path in ipairs(e.paths) do
          if type(path)=="string" then out[#out+1]=path end
        end
      end
    end
  end
  take(select(1,call(mod.cache,"read","cache/pokemon/manifest.lua")))
  for i=1,POKEMON_MANIFEST_SHARDS do
    take(select(1,call(mod.cache,"read",("cache/pokemon/manifest_v2/%02d.lua"):format(i))))
  end
  return out
end

local function generatedPrefixPaths(prefix)
  local out={}
  local raw=select(1,call(mod.cache,"read","build/generated_paths.lua"))
  local list=loadLua(raw)
  if type(list)=="table" then
    for _,path in ipairs(list) do
      if type(path)=="string" and path:find(prefix,1,true) then out[#out+1]=path end
    end
  end
  local registry=select(1,call(mod.cache,"read","build/hard_cache_registry_v1.lua"))
  local parsed=loadLua(registry)
  if type(parsed)=="table" and type(parsed.entries)=="table" then
    for path in pairs(parsed.entries) do
      if type(path)=="string" and path:find(prefix,1,true) then out[#out+1]=path end
    end
  end
  return out
end

local function addRuntimeSidecars(path,add)
  if type(path)~="string" or not path:find("%.lua$") then return end
  local root=path:gsub("%.lua$","").."_runtime_v1"
  add(root.."/base.lua")
  for i=0,48 do add(root..("/base_%02d.f32"):format(i)) end
end

local function collectMovefxFromIndex(add)
  local index=loadLua(select(1,call(mod.cache,"read","cache/movefx/index.lua")))
  local seenStem={}
  for _,row in pairs(type(index)=="table" and index.moves or {}) do
    local stem=type(row)=="table" and tostring(row.stem or "") or ""
    if stem~="" and not seenStem[stem] then
      seenStem[stem]=true
      local effect="cache/movefx/"..stem.."/effect.lua"
      add(effect)
      local raw=select(1,call(mod.cache,"read",effect))
      if type(raw)=="string" then
        for quoted in raw:gmatch('"cache/movefx/[^"]+"') do
          add(quoted:sub(2,-2))
        end
      end
    end
  end
end

local function queueFor(kind)
  local seen,queue={},{}
  local function add(path)
    if type(path)~="string" or seen[path] or pinnedLoose(path) then return end
    seen[path]=true
    if looseExists(path) then
      queue[#queue+1]={path=path,key=unitKey(kind,path)}
    end
    addRuntimeSidecars(path,add)
  end
  if kind=="pokemon" then
    for _,path in ipairs(pokemonManifestPaths()) do add(path) end
    for _,path in ipairs(generatedPrefixPaths("cache/pokemon/")) do add(path) end
  else
    for _,path in ipairs(generatedPrefixPaths("cache/movefx/")) do add(path) end
    collectMovefxFromIndex(add)
  end
  return queue
end

----------------------------------------------------------------------
-- Unit codec
----------------------------------------------------------------------
local function writeUnit(rel,items)
  ensureDirFor(rel)
  love.filesystem.createDirectory(rel:match("^(.*)/") or ARCHIVE_ROOT)
  local f=love.filesystem.newFile and love.filesystem.newFile(rel)
  if not (f and f.open) then return nil,"love.filesystem.newFile unavailable" end
  local okOpen,errOpen=f:open("w")
  if not okOpen then return nil,tostring(errOpen or "could not open unit file") end
  local function emit(s)
    local okw,errw=f:write(s)
    if okw==false or okw==nil then error("unit write failed: "..tostring(errw or "unknown"),0) end
  end
  emit(MAGIC)
  emit(u32(VERSION))
  emit(u32(#items))
  local original=0
  local packedTotal=16
  for _,item in ipairs(items) do
    local raw=item.bytes
    local packed,codec=compressBytes(raw)
    emit(u16(#item.path))
    emit(item.path)
    emit(u32(#raw))
    emit(string.char(codec))
    emit(u32(#packed))
    emit(packed)
    original=original+#raw
    packedTotal=packedTotal+2+#item.path+4+1+4+#packed
    item.bytes=nil
    if WorkBudget then WorkBudget.checkpoint(("PACK %s"):format(item.path)) end
    pumpEvents()
  end
  f:close()
  return original,packedTotal
end

local function parseUnit(bytes,wanted)
  if type(bytes)~="string" or #bytes<16 or bytes:sub(1,8)~=MAGIC then return nil,"not a CBE unit" end
  local ver=ru32(bytes,9);if ver~=VERSION then return nil,"unsupported unit version" end
  local count=ru32(bytes,13) or 0
  local i=17
  local files={}
  for _=1,count do
    local plen=ru16(bytes,i);if not plen then return nil,"truncated unit" end
    i=i+2
    local path=bytes:sub(i,i+plen-1);i=i+plen
    local rawSize=ru32(bytes,i);i=i+4
    local codec=bytes:byte(i);i=i+1
    local packedSize=ru32(bytes,i);i=i+4
    local packed=bytes:sub(i,i+packedSize-1);i=i+packedSize
    if wanted==nil or wanted==path then
      local raw=decompressBytes(packed,codec)
      if type(raw)~="string" or (rawSize and #raw~=rawSize) then return nil,"unit decompress failed: "..tostring(path) end
      files[path]=raw
      if wanted then return files end
    end
  end
  return files
end

local function verifyUnit(rel,items)
  local bytes=love.filesystem.read(rel)
  if type(bytes)~="string" then return false,"unit missing after write" end
  local files,err=parseUnit(bytes,items[1] and items[1].path or nil)
  if not files then return false,err end
  local first=items[1]
  if first and files[first.path]~=first.verify then return false,"unit round-trip mismatch" end
  return true
end

----------------------------------------------------------------------
-- Status / public lookup
----------------------------------------------------------------------
function A.contains(path)
  local kind=kindFor(path)
  if not kind or pinnedLoose(path) then return false end
  local idx=readIndex(kind)
  return idx.entries[path]~=nil
end

function A.infoEntry(path)
  local kind=kindFor(path)
  if not kind then return nil end
  local idx=readIndex(kind)
  local size=idx.entries[path]
  if not size then return nil end
  return {type="file",size=tonumber(size) or 0,archived=true}
end

local function archiveBytesOnDisk(kind)
  local dir=kind=="movefx" and MOVEFX_DIR or POKEMON_DIR
  local info=love.filesystem.getInfo and love.filesystem.getInfo(dir)
  if not (info and info.type=="directory") then
    local idx=readIndex(kind)
    return tonumber(idx.archiveBytes) or 0
  end
  local total=0
  for _,name in ipairs(love.filesystem.getDirectoryItems(dir) or {}) do
    local row=love.filesystem.getInfo(dir.."/"..name)
    if row and row.size then total=total+row.size end
  end
  return total
end

local function prettyBytes(n)
  n=tonumber(n) or 0
  if n>=1024^3 then return ("%.2f GiB"):format(n/(1024^3)) end
  if n>=1024^2 then return ("%.1f MiB"):format(n/(1024^2)) end
  if n>=1024 then return ("%.1f KiB"):format(n/1024) end
  return tostring(n).." B"
end

function A.status()
  local tool=A.available()
  local p=readIndex("pokemon")
  local m=readIndex("movefx")
  local pBytes=archiveBytesOnDisk("pokemon")
  local mBytes=archiveBytesOnDisk("movefx")
  local original=(p.originalBytes or 0)+(m.originalBytes or 0)
  local packed=pBytes+mBytes
  local pCount,mCount=0,0
  for _ in pairs(p.entries) do pCount=pCount+1 end
  for _ in pairs(m.entries) do mCount=mCount+1 end
  local pokemonPacked=looseExists(MARKER_POKEMON)
  local movefxPacked=looseExists(MARKER_MOVEFX)
  return {
    toolAvailable=tool and true or false,
    toolLabel=tool and tool.label or "LÖVE zlib unavailable",
    running=job~=nil,
    stage=job and job.label or ((pokemonPacked or movefxPacked) and "READY" or "NOT PACKED"),
    error=job and job.error or nil,
    pokemonPacked=pokemonPacked and true or false,
    movefxPacked=movefxPacked and true or false,
    pokemonEntries=pCount,
    movefxEntries=mCount,
    originalBytes=original,
    archiveBytes=packed,
    savedBytes=math.max(0,original-packed),
    originalLabel=prettyBytes(original),
    archiveLabel=prettyBytes(packed),
    savedLabel=prettyBytes(math.max(0,original-packed)),
    ratio=original>0 and packed/original or nil,
  }
end

----------------------------------------------------------------------
-- Packing
----------------------------------------------------------------------
local function packKind(kind)
  if not A.available() then error("love.data.compress (zlib) is unavailable on this host",0) end
  love.filesystem.createDirectory(ARCHIVE_ROOT)
  love.filesystem.createDirectory(kind=="movefx" and MOVEFX_DIR or POKEMON_DIR)
  local idx=readIndex(kind)
  local archived={}
  for path in pairs(idx.entries) do archived[path]=true end
  local queue={}
  for _,item in ipairs(queueFor(kind)) do
    if not archived[item.path] then queue[#queue+1]=item end
  end
  local byUnit={}
  for _,item in ipairs(queue) do
    local u=byUnit[item.key];if not u then u={key=item.key,items={}};byUnit[item.key]=u end
    u.items[#u.items+1]=item
  end
  local units={}
  for _,u in pairs(byUnit) do units[#units+1]=u end
  table.sort(units,function(a,b) return tostring(a.key)<tostring(b.key) end)

  local newly={}
  for ui,unit in ipairs(units) do
    if WorkBudget then WorkBudget.checkpoint(("PACK %s %d/%d"):format(kind:upper(),ui,#units)) end
    local batch={}
    for _,item in ipairs(unit.items) do
      local bytes=looseRead(item.path)
      if type(bytes)=="string" then
        local row={path=item.path,bytes=bytes,key=item.key,size=#bytes}
        if #batch==0 then row.verify=bytes end
        batch[#batch+1]=row
      end
    end
    if #batch>0 then
      local rel=unitRel(kind,unit.key)
      local original,packedTotal=writeUnit(rel,batch)
      local ok,why=verifyUnit(rel,batch)
      if not ok then error(("archive verify failed [%s/%s], originals kept: %s"):format(kind,tostring(unit.key),tostring(why)),0) end
      local paths=idx.byUnit[unit.key] or {}
      for _,item in ipairs(batch) do
        idx.entries[item.path]=item.size
        paths[#paths+1]=item.path
        newly[item.path]=item.size
      end
      idx.byUnit[unit.key]=paths
      idx.originalBytes=(idx.originalBytes or 0)+(tonumber(original) or 0)
      idx.archiveBytes=(idx.archiveBytes or 0)+(tonumber(packedTotal) or 0)
      writeIndex(kind,idx)
      for _,item in ipairs(batch) do
        looseDelete(item.path)
        local G=V.GeneratedAssets
        if G and G.invalidateInfo then G.invalidateInfo(item.path) end
      end
    end
    pumpEvents()
  end

  writeIndex(kind,idx)
  local marker=kind=="movefx" and MARKER_MOVEFX or MARKER_POKEMON
  local n=0;for _ in pairs(idx.entries) do n=n+1 end
  looseWrite(marker,("cbe-cache-archive=1\nkind=%s\nentries=%d\n"):format(kind,n))
  return true
end

local function packBody(scope)
  scope=scope or "all"
  if scope=="all" or scope=="pokemon" then packKind("pokemon") end
  if scope=="all" or scope=="movefx" then packKind("movefx") end
  return true
end

function A.beginPack(scope)
  if job then return false,"already running" end
  if not WorkBudget then return false,"WorkBudget module unavailable" end
  if not A.available() then return false,"love.data.compress unavailable" end
  scope=scope or "all"
  local label=scope=="pokemon" and "PACKING POKEMON CACHE"
    or (scope=="movefx" and "PACKING MOVEFX CACHE" or "PACKING POKEMON + MOVEFX")
  local co=WorkBudget.new(function()
    local ok,err=xpcall(function() packBody(scope) end,debug.traceback)
    if not ok then job.error=tostring(err);return false end
    return true
  end,label)
  job={co=co,label=label,error=nil}
  return true,"Packing started. Loose files are removed only after each unit verifies."
end

function A.pump(budgetMs)
  if not job then return "idle" end
  local ok,state=WorkBudget.resume(job.co,budgetMs or 40)
  if not ok then
    local err=job.error or tostring(state);job=nil
    return "error",err
  end
  if state=="done" then
    local finished=job;job=nil
    return finished.error and "error" or "done",finished.error
  end
  job.label=WorkBudget.label(job.co) or job.label
  return "working"
end

function A.cancelPack()
  if not job then return false end
  WorkBudget.cancel(job.co)
  job=nil
  return true
end

----------------------------------------------------------------------
-- Rehydrate
----------------------------------------------------------------------
local function readHotLog()
  local v=loadLua(select(1,call(mod.cache,"read",HOT_PATH)))
  if type(v)~="table" then v={order={},bytes=0} end
  v.order=v.order or {};v.bytes=tonumber(v.bytes) or 0
  return v
end
local function writeHotLog(hot)
  local out={"return {bytes=",tostring(math.floor(hot.bytes or 0)),",order={"}
  for _,key in ipairs(hot.order) do out[#out+1]=("%q,"):format(key) end
  out[#out+1]="}}\n"
  call(mod.cache,"write",HOT_PATH,table.concat(out))
end

local function hotName(kind,key) return kind.."/"..tostring(key) end

local function evictOldest(hot)
  local name=table.remove(hot.order,1)
  if not name then return 0 end
  local kind,key=name:match("^([^/]+)/(.*)$")
  if not kind then return 0 end
  local idx=readIndex(kind)
  local freed=0
  for _,path in ipairs(idx.byUnit[key] or {}) do
    local size=idx.entries[path]
    looseDelete(path)
    local G=V.GeneratedAssets
    if G and G.invalidateInfo then G.invalidateInfo(path) end
    freed=freed+(tonumber(size) or 0)
  end
  return freed
end

function A.readEntry(path)
  local kind=kindFor(path)
  if not kind then return nil,"not an archived cache path" end
  if pinnedLoose(path) then return nil,"identity file is not archived" end
  local idx=readIndex(kind)
  if not idx.entries[path] then return nil,"path not present in archive" end
  if not A.available() then return nil,"love.data.decompress unavailable" end
  local key=unitKey(kind,path)
  local unitPaths=idx.byUnit[key]
  if not unitPaths or #unitPaths==0 then return nil,"unit missing from archive index" end
  local hot=readHotLog()
  local name=hotName(kind,key)
  local already=false
  for _,k in ipairs(hot.order) do if k==name then already=true;break end end
  if not (already and looseExists(path)) then
    local rel=unitRel(kind,key)
    local blob=love.filesystem.read(rel)
    if type(blob)~="string" then return nil,"archived unit file missing: "..rel end
    local files,err=parseUnit(blob,nil)
    if not files then return nil,err end
    local unitBytes=0
    for _,p in ipairs(unitPaths) do
      local bytes=files[p]
      if type(bytes)=="string" then
        looseWrite(p,bytes)
        unitBytes=unitBytes+#bytes
        local G=V.GeneratedAssets
        if G and G.invalidateInfo then G.invalidateInfo(p) end
      end
    end
    if not already then
      hot.order[#hot.order+1]=name
      hot.bytes=hot.bytes+unitBytes
      while hot.bytes>HOT_CAP_BYTES and #hot.order>1 do hot.bytes=math.max(0,hot.bytes-evictOldest(hot)) end
      writeHotLog(hot)
    end
  end
  return looseRead(path)
end

function A.wipe()
  rmrf(ARCHIVE_ROOT)
  looseDelete(INDEX_POKEMON);looseDelete(INDEX_MOVEFX);looseDelete(HOT_PATH)
  looseDelete(MARKER_POKEMON);looseDelete(MARKER_MOVEFX)
  indexMemo={pokemon=nil,movefx=nil}
  job=nil
  return true
end

function A.install()
  local G=V.GeneratedAssets
  if not (G and not G._cacheArchiveInstalled) then return G end
  G._cacheArchiveInstalled=true
  local origRead,origInfo=G.read,G.info
  function G.info(path)
    path=tostring(path or "")
    local hit=origInfo(path)
    if type(hit)=="table" then return hit end
    return A.infoEntry(path)
  end
  function G.read(path)
    local data,err=origRead(path)
    if type(data)=="string" then return data end
    local archived,aerr=A.readEntry(tostring(path or ""))
    if type(archived)~="string" then return nil,err or aerr or ("generated asset missing: "..tostring(path)) end
    -- Rehydrate wrote the loose file; read it back so the info registry records
    -- the authoritative size instead of the miss origRead just stored.
    local again=origRead(path)
    return type(again)=="string" and again or archived
  end
  return G
end

A.install()
return A
