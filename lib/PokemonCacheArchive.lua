-- Packs the lazily-extracted "cache/pokemon/*" hard cache (the bulk of CBE's
-- ~20 GB on-disk footprint -- raw RGBA texture dumps, action banks and
-- runtime_mesh_v1 float32 sidecars for up to 386 species x2 variants) into one
-- real 7-Zip archive, then serves individual species back out of that archive
-- on demand instead of requiring every species to sit on disk as loose files.
--
-- Nothing about extraction changes: PokemonExtractor still writes loose files
-- through mod.cache exactly as before, and every one of the ~100 call sites
-- across lib/ that read a "cache/pokemon/..." path through GeneratedAssets
-- keep working completely unmodified. This module only adds a fallback at the
-- bottom of GeneratedAssets.read/info/exists: if a loose file is missing AND a
-- packed archive exists, the owning species' files are extracted back out of
-- the archive and rewritten through mod.cache ("rehydration"), bounded by a
-- small hot-cache cap so disk usage cannot silently grow back to 20 GB.
--
-- The archive itself is a real OS file. It intentionally does NOT live inside
-- mod.cache (which is a byte-oriented KV store built for many small files,
-- not a multi-GB blob) -- it lives in LOVE's own save directory, which every
-- supported platform guarantees, independent of whatever backend mod.cache
-- uses. Only small bookkeeping files (index/markers) live in mod.cache, so
-- they participate in the normal RESET/WIPE flows.
--
-- Packing/reading both shell out to a real 7-Zip CLI. No 7-Zip binary is
-- embedded in this mod (see third_party/7zip/README.md for how to obtain
-- one); when none is found, A.available() is false and every entry point here
-- fails soft, leaving the existing loose-file behavior completely unchanged.
local V=...
local mod=V.mod
local WorkBudget=V.WorkBudget
local A={schema=1}

local ARCHIVE_ROOT="cbe_pokemon_cache"                 -- LOVE save-dir folder (real OS path)
local ARCHIVE_FILE=ARCHIVE_ROOT.."/pokemon_cache.7z"
local SCRATCH_DIR=ARCHIVE_ROOT.."/_stage"
local HOT_DIR=ARCHIVE_ROOT.."/_hot"

local INDEX_PATH="cache/pokemon/archive_v1_index.lua"       -- mod.cache: small, list of packed entries
local COMPLETE_MARKER="build/pokemon_cache_archive_v1.complete" -- mod.cache: matches existing build/*.complete convention
local HOT_BOOKKEEPING_PATH="cache/pokemon/archive_v1_hot.lua"   -- mod.cache: LRU record of rehydrated species

local POKEMON_SPECIES_COUNT=386
local POKEMON_MANIFEST_SHARD_SIZE=32
local POKEMON_MANIFEST_SHARDS=math.ceil(POKEMON_SPECIES_COUNT/POKEMON_MANIFEST_SHARD_SIZE)

-- One 7z invocation per batch, not one per file: process-spawn + LZMA-open
-- overhead dominates at small sizes, and a 15-25k file cache would otherwise
-- mean 15-25k subprocess launches. Batches are also the unit that bounds how
-- much *extra* disk packing needs at any one instant (files are staged, added,
-- then deleted before the next batch starts).
local BATCH_MAX_FILES=48
local BATCH_MAX_BYTES=8*1024*1024
local COMPRESSION_LEVEL="-mx=9"

-- Rehydrated ("hot") species are written back through mod.cache so repeat
-- reads never re-shell-out. Capped so a long session touching many species
-- cannot quietly regrow the install back toward 20 GB.
local HOT_CAP_BYTES=1536*1024*1024

local function call(obj,name,...)
  if not obj or type(obj[name])~="function" then return nil,"unavailable" end
  local ok,a,b=pcall(obj[name],obj,...)
  if not ok then return nil,tostring(a) end
  return a,b
end
local function GA() return V.GeneratedAssets end
local function gaRead(path)
  local ga=GA();if ga and ga.read then local v,e=ga.read(path);if type(v)=="string" then return v end;return nil,e end
  return select(1,call(mod.cache,"read",path))
end
local function gaExists(path)
  local ga=GA();if ga and ga.exists then return ga.exists(path) and true or false end
  local info=select(1,call(mod.cache,"info",path))
  return type(info)=="table" and (info.type==nil or info.type=="file")
end
local function gaWrite(path,bytes)
  local ga=GA();if ga and ga.write then return ga.write(path,bytes) end
  return call(mod.cache,"write",path,bytes)
end
local function gaDelete(path)
  local ga=GA();if ga and ga.delete then return ga.delete(path) end
  return call(mod.cache,"delete",path)
end

local function sep() return package.config:sub(1,1) end
local function isWindows()
  if love and love.system and type(love.system.getOS)=="function" then
    local ok,v=pcall(love.system.getOS);if ok then return tostring(v)=="Windows" end
  end
  return sep()=="\\"
end
local function absPath(rel)
  return love.filesystem.getSaveDirectory()..sep()..tostring(rel):gsub("/",sep())
end
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

-- Windows os.execute goes through cmd.exe, which mishandles a quoted
-- executable path unless the *whole* invocation is wrapped in one more pair
-- of quotes (the same workaround extract/AudioWorker.lua already relies on
-- for amuserender.exe). A generated .cmd file sidesteps command-length limits
-- entirely, which matters once a batch's file-list argument gets long.
local function winQuote(s) return '"'..tostring(s):gsub('"','""')..'"' end
local function posixQuote(s) return "'"..tostring(s):gsub("'","'\\''").."'" end

local function runTool(exe,args,cwdAbs,logRel)
  ensureDirFor(logRel)
  local logAbs=absPath(logRel)
  local ok3
  if isWindows() then
    local line={winQuote(exe)}
    for _,a in ipairs(args) do line[#line+1]=winQuote(a) end
    local parts={"@echo off\r\n"}
    if cwdAbs then parts[#parts+1]="cd /d "..winQuote(cwdAbs).."\r\n" end
    parts[#parts+1]=table.concat(line," ").." > "..winQuote(logAbs).." 2>&1\r\nexit /b %errorlevel%\r\n"
    local cmdRel=SCRATCH_DIR.."/run.cmd"
    ensureDirFor(cmdRel)
    local okw,errw=love.filesystem.write(cmdRel,table.concat(parts))
    if not okw then return false,"temporary command file: "..tostring(errw) end
    local cmdAbs=absPath(cmdRel)
    local a,b,c=os.execute('cmd.exe /d /s /c "'..cmdAbs:gsub('"','""')..'"')
    ok3=(a==0) or (a==true and (c==nil or c==0))
  else
    local line={posixQuote(exe)}
    for _,a in ipairs(args) do line[#line+1]=posixQuote(a) end
    local cmd=(cwdAbs and ("cd "..posixQuote(cwdAbs).." && ") or "")..table.concat(line," ").." > "..posixQuote(logAbs).." 2>&1"
    local a,b,c=os.execute(cmd)
    ok3=(a==0) or (a==true and (c==nil or c==0))
  end
  local log=love.filesystem.read(logRel)
  return ok3,log or ""
end

----------------------------------------------------------------------
-- 7-Zip binary discovery
----------------------------------------------------------------------
local BUNDLED_WIN_PATH="third_party/7zip/7za.exe"
local WIN_CANDIDATES={"7z","7za","7zr"}
local POSIX_CANDIDATES={"7zz","7z","7za"}

local toolMemo=nil -- nil=not probed, false=none found, table={exe=,label=}

local function looksLike7z(log) return type(log)=="string" and (log:find("7%-Zip") or log:find("p7zip")) and true or false end

local function probeBundled()
  if not isWindows() then return nil end
  local ok,bytes=pcall(mod.read,mod,BUNDLED_WIN_PATH)
  if not ok or type(bytes)~="string" or #bytes==0 then return nil end
  local exeRel=SCRATCH_DIR.."/7za.exe"
  ensureDirFor(exeRel)
  local okw=love.filesystem.write(exeRel,bytes)
  if not okw then return nil end
  local exeAbs=absPath(exeRel)
  local okRun,log=runTool(exeAbs,{},nil,SCRATCH_DIR.."/probe.log")
  if looksLike7z(log) then return {exe=exeAbs,label="bundled 7za.exe"} end
  return nil
end

function A.available()
  if toolMemo~=nil then return toolMemo end
  toolMemo=false
  local candidates=isWindows() and WIN_CANDIDATES or POSIX_CANDIDATES
  for _,name in ipairs(candidates) do
    local ok,log=pcall(runTool,name,{},nil,SCRATCH_DIR.."/probe.log")
    if ok and looksLike7z(log) then toolMemo={exe=name,label=name.." (system PATH)"};break end
  end
  if not toolMemo then
    local bundled=probeBundled()
    if bundled then toolMemo=bundled end
  end
  rmrf(SCRATCH_DIR.."/probe.log")
  return toolMemo
end
function A.resetToolProbe() toolMemo=nil end

----------------------------------------------------------------------
-- Manifest reading (species -> files). Deliberately duplicated in miniature
-- from extract/PokemonExtractor.lua's readManifest/manifestPaths rather than
-- depending on that module directly: PokemonExtractor is not published on the
-- shared namespace, and this reader only ever needs read-only access to the
-- exact same manifest file it already maintains. Both the legacy single-file
-- manifest and the newer 32-species shards are read defensively, matching
-- GeneratedCacheReset.lua's own dual handling.
----------------------------------------------------------------------
local function loadManifestChunk(raw)
  if type(raw)~="string" then return {} end
  local chunk=load(raw,"@generated/cache-pokemon-archive-manifest")
  if not chunk then return {} end
  local ok,value=pcall(chunk)
  if not ok or type(value)~="table" then return {} end
  return value
end
local function allManifestUnits()
  local out={}
  for _,e in ipairs(loadManifestChunk(select(1,call(mod.cache,"read","cache/pokemon/manifest.lua")))) do
    if type(e)=="table" and type(e.paths)=="table" then out[#out+1]=e end
  end
  for i=1,POKEMON_MANIFEST_SHARDS do
    local raw=select(1,call(mod.cache,"read",("cache/pokemon/manifest_v2/%02d.lua"):format(i)))
    for _,e in ipairs(loadManifestChunk(raw)) do
      if type(e)=="table" and type(e.paths)=="table" then out[#out+1]=e end
    end
  end
  -- Small fixed extras worth keeping in the archive alongside the species
  -- payloads themselves, so a full restore (A.unpackAll) needs nothing else.
  out[#out+1]={dex=0,variant="_meta",stem="_manifest",paths={
    "cache/pokemon/manifest.lua","cache/pokemon/_last_attempt.txt",
  }}
  for i=1,POKEMON_MANIFEST_SHARDS do
    out[#out+1]={dex=0,variant="_meta",stem="_manifest_shard",paths={("cache/pokemon/manifest_v2/%02d.lua"):format(i)}}
  end
  return out
end
-- Groups by the ACTUAL on-disk layout, not the manifest's recorded variant
-- field. Most species share one cache root for both normal and shiny (shiny
-- is a runtime palette swap over the same cached model); only the "rare"
-- species in ColosseumDex.rare{} get a distinct ".../shiny" subtree. Keying
-- off the manifest's variant field instead of the path would misfile those
-- shared-root species under the wrong bucket depending on which variant
-- happened to be extracted last.
local function keyForPath(path)
  local dex,rest=path:match("^cache/pokemon/(%d+)/(.*)$")
  if not dex then return "_meta" end
  return dex..(rest:match("^shiny/") and "/shiny" or "/normal")
end

----------------------------------------------------------------------
-- Index (small, lives in mod.cache): which paths are currently archived,
-- grouped by species, plus size accounting for the status/UI screen.
----------------------------------------------------------------------
local function readIndex()
  local raw=select(1,call(mod.cache,"read",INDEX_PATH))
  local v=loadManifestChunk(raw)
  if type(v)~="table" then v={} end
  v.byUnit=v.byUnit or {}
  v.entries=v.entries or {}
  v.originalBytes=tonumber(v.originalBytes) or 0
  return v
end
local function writeIndex(idx)
  local out={"return {originalBytes=",tostring(math.floor(idx.originalBytes or 0)),",entries={"}
  for path,size in pairs(idx.entries) do
    out[#out+1]=("[%q]=%d,"):format(path,math.floor(tonumber(size) or 0))
  end
  out[#out+1]="},byUnit={"
  for key,paths in pairs(idx.byUnit) do
    out[#out+1]=("[%q]={"):format(key)
    for _,p in ipairs(paths) do out[#out+1]=("%q,"):format(p) end
    out[#out+1]="},"
  end
  out[#out+1]="}}\n"
  return call(mod.cache,"write",INDEX_PATH,table.concat(out))
end

----------------------------------------------------------------------
-- Status
----------------------------------------------------------------------
local job=nil -- {co=,label=,error=,cancelled=}

function A.status()
  local idx=readIndex()
  local archiveInfo=love.filesystem.getInfo and love.filesystem.getInfo(ARCHIVE_FILE)
  local archiveBytes=archiveInfo and archiveInfo.size or 0
  local entryCount=0;for _ in pairs(idx.entries) do entryCount=entryCount+1 end
  local packed=gaExists(COMPLETE_MARKER)
  local tool=A.available()
  return {
    toolAvailable=tool and true or false,
    toolLabel=tool and tool.label or nil,
    packed=packed and true or false,
    running=job~=nil,
    paused=false,
    stage=job and job.label or (packed and "READY" or "NOT PACKED"),
    error=job and job.error or nil,
    entries=entryCount,
    originalBytes=idx.originalBytes or 0,
    archiveBytes=archiveBytes,
    savedBytes=math.max(0,(idx.originalBytes or 0)-archiveBytes),
    ratio=(idx.originalBytes or 0)>0 and archiveBytes/idx.originalBytes or nil,
  }
end

----------------------------------------------------------------------
-- Packing
----------------------------------------------------------------------
local function verifyArchive(tool)
  local ok,log=runTool(tool.exe,{"t",absPath(ARCHIVE_FILE)},nil,SCRATCH_DIR.."/verify.log")
  return ok and log:find("Everything is Ok")~=nil,log
end

local function packBody()
  local tool=A.available()
  if not tool then error("no 7-Zip tool found (see third_party/7zip/README.md); loose cache/pokemon files are left exactly as-is",0) end
  love.filesystem.createDirectory(ARCHIVE_ROOT)
  local idx=readIndex()
  local archivedSet={}
  for path in pairs(idx.entries) do archivedSet[path]=true end

  local units=allManifestUnits()
  local queue={}
  for _,unit in ipairs(units) do
    for _,path in ipairs(unit.paths) do
      if not archivedSet[path] and gaExists(path) then
        queue[#queue+1]={path=path,key=keyForPath(path)}
      end
    end
  end

  local total=#queue
  local cursor=0
  local newlyArchived={} -- path -> {size=,key=}
  while cursor<total do
    local batch={}
    local batchBytes=0
    while cursor<total and #batch<BATCH_MAX_FILES and batchBytes<BATCH_MAX_BYTES do
      cursor=cursor+1
      local item=queue[cursor]
      local bytes=gaRead(item.path)
      if type(bytes)=="string" then
        local rel=SCRATCH_DIR.."/"..item.path
        ensureDirFor(rel)
        local okw=love.filesystem.write(rel,bytes)
        if okw then
          batch[#batch+1]=item;batchBytes=batchBytes+#bytes
          newlyArchived[item.path]={size=#bytes,key=item.key}
        end
      end
      if WorkBudget then WorkBudget.checkpoint(("PACK %d/%d"):format(cursor,total)) end
    end
    if #batch>0 then
      local args={"a",COMPRESSION_LEVEL,"-ms=off","-y",absPath(ARCHIVE_FILE)}
      for _,item in ipairs(batch) do args[#args+1]=item.path end
      local ok,log=runTool(tool.exe,args,absPath(SCRATCH_DIR),SCRATCH_DIR.."/add.log")
      rmrf(SCRATCH_DIR)
      if not ok then error("7-Zip add failed: "..tostring(log):sub(1,600),0) end
    end
    if WorkBudget then WorkBudget.checkpoint(("PACK %d/%d"):format(cursor,total)) end
  end

  if next(newlyArchived)==nil and gaExists(COMPLETE_MARKER) then
    return true -- nothing new to do; already packed and up to date
  end
  if love.filesystem.getInfo(ARCHIVE_FILE) then
    if WorkBudget then WorkBudget.checkpoint("VERIFYING ARCHIVE") end
    local ok,log=verifyArchive(tool)
    if not ok then error("archive verification failed, originals were NOT deleted: "..tostring(log):sub(1,600),0) end
  end

  -- Only after a full, successful integrity check do the loose originals
  -- actually get deleted. Anything that fails before this point leaves the
  -- pre-existing loose cache completely untouched.
  local deleted=0
  for path,info in pairs(newlyArchived) do
    idx.entries[path]=info.size
    idx.byUnit[info.key]=idx.byUnit[info.key] or {}
    table.insert(idx.byUnit[info.key],path)
    idx.originalBytes=(idx.originalBytes or 0)+info.size
    gaDelete(path)
    deleted=deleted+1
    if deleted%64==0 and WorkBudget then WorkBudget.checkpoint(("REMOVING LOOSE FILES %d"):format(deleted)) end
  end
  writeIndex(idx)
  gaWrite(COMPLETE_MARKER,("cbe-pokemon-cache-archive=1\nentries=%d\n"):format(deleted))
  return true
end

function A.beginPack()
  if job then return false,"already running" end
  if not WorkBudget then return false,"WorkBudget module unavailable" end
  local tool=A.available()
  if not tool then return false,"no 7-Zip tool found; see third_party/7zip/README.md" end
  local co=WorkBudget.new(function()
    local ok,err=xpcall(packBody,debug.traceback)
    if not ok then job.error=tostring(err);return false end
    return true
  end,"PACKING POKEMON CACHE")
  job={co=co,label="PACKING POKEMON CACHE",error=nil}
  return true,"Packing started."
end

-- Advances the pack job by up to budgetMs milliseconds. Call this from a UI
-- poll loop (see BattleSettings.lua's "PACK POKEMON CACHE" submenu) or any
-- other per-frame/per-tick hook; packing makes no progress unless pumped.
function A.pump(budgetMs)
  if not job then return "idle" end
  local ok,state=WorkBudget.resume(job.co,budgetMs or 40)
  if not ok then job=nil;return "error" end
  if state=="done" then
    local finishedJob=job;job=nil
    return finishedJob.error and "error" or "done"
  end
  job.label=WorkBudget.label(job.co) or job.label
  return "working"
end

function A.cancelPack()
  if not job then return false end
  WorkBudget.cancel(job.co)
  job=nil
  rmrf(SCRATCH_DIR)
  return true
end

----------------------------------------------------------------------
-- On-demand read: called by GeneratedAssets when a loose "cache/pokemon/..."
-- path is missing. Extracts every file belonging to that ONE species/variant
-- (never the whole archive) in a single subprocess call, rehydrates them
-- through mod.cache, and returns the bytes for the originally requested path.
----------------------------------------------------------------------
local function readHotLog()
  local raw=select(1,call(mod.cache,"read",HOT_BOOKKEEPING_PATH))
  local v=loadManifestChunk(raw)
  if type(v)~="table" then v={order={},bytes=0} end
  v.order=v.order or {};v.bytes=tonumber(v.bytes) or 0
  return v
end
local function writeHotLog(hot)
  local out={"return {bytes=",tostring(math.floor(hot.bytes or 0)),",order={"}
  for _,key in ipairs(hot.order) do out[#out+1]=("%q,"):format(key) end
  out[#out+1]="}}\n"
  call(mod.cache,"write",HOT_BOOKKEEPING_PATH,table.concat(out))
end

local function evictOldestUnit(idx,hot)
  local key=table.remove(hot.order,1)
  if not key then return 0 end
  local freed=0
  for _,path in ipairs(idx.byUnit[key] or {}) do
    local size=idx.entries[path]
    gaDelete(path)
    freed=freed+(tonumber(size) or 0)
  end
  return freed
end

function A.readEntry(path)
  if type(path)~="string" or not path:find("^cache/pokemon/") then return nil,"not a pokemon cache path" end
  if not gaExists(COMPLETE_MARKER) then return nil,"pokemon cache archive not built" end
  local tool=A.available()
  if not tool then return nil,"no 7-Zip tool found" end
  local dex,rest=path:match("^cache/pokemon/(%d+)/(.*)$")
  if not dex then return nil,"unrecognized pokemon cache path" end
  local variant=rest:match("^shiny/") and "shiny" or "normal"
  local key=unitKey(tonumber(dex),variant)

  local idx=readIndex()
  local unitPaths=idx.byUnit[key]
  if not unitPaths or #unitPaths==0 then return nil,"species not present in archive" end

  local hot=readHotLog()
  local alreadyHot=false
  for _,k in ipairs(hot.order) do if k==key then alreadyHot=true;break end end
  if not (alreadyHot and gaExists(path)) then
    love.filesystem.createDirectory(HOT_DIR)
    local args={"x","-y","-o"..absPath(HOT_DIR),absPath(ARCHIVE_FILE)}
    for _,p in ipairs(unitPaths) do args[#args+1]=p end
    local ok,log=runTool(tool.exe,args,nil,SCRATCH_DIR.."/extract.log")
    if not ok then return nil,"7-Zip extract failed: "..tostring(log):sub(1,400) end
    local unitBytes=0
    for _,p in ipairs(unitPaths) do
      local bytes=love.filesystem.read(HOT_DIR.."/"..p)
      if type(bytes)=="string" then gaWrite(p,bytes);unitBytes=unitBytes+#bytes end
    end
    rmrf(HOT_DIR)
    if not alreadyHot then
      hot.order[#hot.order+1]=key
      hot.bytes=hot.bytes+unitBytes
      while hot.bytes>HOT_CAP_BYTES and #hot.order>1 do hot.bytes=hot.bytes-evictOldestUnit(idx,hot) end
      writeHotLog(hot)
    end
  end
  return gaRead(path)
end

----------------------------------------------------------------------
-- Cache reset / wipe integration. Called from GeneratedCacheReset.lua so
-- RESET/WIPE also removes the real archive file, not just its mod.cache
-- bookkeeping.
----------------------------------------------------------------------
function A.wipe()
  rmrf(ARCHIVE_ROOT)
  gaDelete(INDEX_PATH);gaDelete(COMPLETE_MARKER);gaDelete(HOT_BOOKKEEPING_PATH)
  toolMemo=nil
  return true
end

return A
