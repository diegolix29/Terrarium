-- Explicit destructive reset for CBE-generated runtime/cache data.
--
-- This module exists so the startup cache-policy screen and the later in-game
-- CacheManager use one authoritative deletion inventory. Ordinary startup,
-- update, validation and repair code must NEVER call this helper. The imported
-- GC6E01 source belongs to mod.imports and is deliberately outside this module.
--
-- No directory enumeration is used. Lazy Pokemon assets are owned by one legacy
-- manifest plus 13 bounded 32-species shards; the main source build has its own
-- bounded generated_paths manifest. Content-addressed cache/preserved/* archives
-- are intentionally not active-runtime inventory and remain available after a
-- reset so DELETE cannot accidentally destroy the preservation safety net.
local R={schema=1}

local POKEMON_SPECIES_COUNT=386
local POKEMON_MANIFEST_SHARD_SIZE=32
local POKEMON_MANIFEST_SHARDS=math.ceil(POKEMON_SPECIES_COUNT/POKEMON_MANIFEST_SHARD_SIZE)
local STAGES={"disc","fsys","arenas","trainers","capture","transition","movefx","audio_portable","audio","verify"}

local HARD_CACHE_MARKERS={
  "build/hard_cache_v5.complete","build/hard_cache_v4.complete","build/hard_cache_v3.complete","build/hard_cache_v2.complete",
  "build/hard_cache_team_v1.complete","build/hard_cache_catalog_151_v1.complete","build/hard_cache_catalog_251_v1.complete","build/hard_cache_catalog_v1.complete","build/hard_cache_catalog_v2.complete","build/hard_cache_catalog_v3.complete",
  "build/battle_cache_reuse_v1.complete","build/hard_cache_registry_v1.lua",
}

local ARENA_CACHE_PATHS={
  "cache/M1_water_cache.lua","cache/open_water_cache.lua","cache/orre_colosseum_cache.lua",
  "cache/M3_shrine_1F_bf_cache.lua","cache/M3_cave_1F_1_bf_cache.lua","cache/S1_out_bf_cache.lua",
  "cache/M2_earth_colo_cache.lua","cache/M4_bottom_colo_cache.lua","cache/D1_labo_B1_bf_cache.lua",
  "cache/realgam_colosseum_cache.lua","cache/outdoor_wild_cache.lua","cache/D2_mt_battle_platform100_cache.lua",
}
local ARENA_IDS={"water","open_water","orre_colosseum","relic_chamber","relic_cave","outskirts","pyrite_colosseum",
  "deep_colosseum","cipher_lab_underground","realgam_colosseum","outdoor_wild","mt_battle_summit"}

local EXPLICIT_GENERATED_PATHS={
  -- Source/runtime completion and migration state.
  ".cbe-runtime-v2.complete",".cbe-visual-v2.complete",
  ".cbe-arena-runtime-sidecars-v2.complete",".cbe-arena-v2.complete",".cbe-arena-v3.complete",".cbe-arena-v4.complete",
  ".cbe-arena-v5.complete",".cbe-arena-v6.complete",".cbe-arena-v7.complete",".cbe-arena-v8.complete",".cbe-arena-v9.complete",".cbe-arena-v10.complete",
  "build/arena_source_animation.complete","build/arena_source_animation_v2.complete",
  ".cbe-trainer-identity-v1.complete",".cbe-trainer-identity-v2.complete",".cbe-trainer-identity-v3.complete",".cbe-trainer-identity-v4.complete",
  ".cbe-trainer-identity-v5.complete",".cbe-trainer-identity-v6.complete",".cbe-trainer-identity-v7.complete",".cbe-trainer-identity-v8.complete",
  ".cbe-trainer-identity-v9.complete",".cbe-trainer-identity-v10.complete",".cbe-trainer-identity-v11.complete",".cbe-trainer-identity-v12.complete",
  ".cbe-trainer-identity-v13.complete",".cbe-trainer-identity-v14.complete",".cbe-trainer-identity-v15.complete",".cbe-trainer-identity-v16.complete",".cbe-trainer-identity-v17.complete",".cbe-trainer-identity-v18.complete",
  ".cbe-movefx-full-v1.complete",".cbe-movefx-full-v2.complete",".cbe-movefx-full-v3.complete",".cbe-movefx-full-v4.complete",
  ".cbe-waza-sfx-v1.complete","build/waza_sfx_v1.complete",

  -- Audio transactions and diagnostics.
  ".cbe-audio-v1.complete",".cbe-audio-portable-v1.complete",".cbe-audio-portable-v2.complete",
  ".cbe-audio-portable-v3.complete",".cbe-audio-portable-v3.pending",
  ".cbe-audio-portable-v4.complete",".cbe-audio-portable-v4.pending","build/audio_portable_v4.complete","build/audio_portable_v4.migrating",
  ".cbe-audio-portable-v5.complete",".cbe-audio-portable-v5.pending","build/audio_portable_v5.complete","build/audio_portable_v5.migrating",
  ".cbe-audio-portable-v6.complete",".cbe-audio-portable-v6.pending","build/audio_portable_v6.complete","build/audio_portable_v6.migrating",
  ".cbe-audio-portable-v7.complete",".cbe-audio-portable-v7.pending","build/audio_portable_v7.complete","build/audio_portable_v7.migrating",
  ".cbe-audio-portable-v9.complete",".cbe-audio-portable-v9.pending","build/audio_portable_v9.complete","build/audio_portable_v9.migrating",
  ".cbe-audio-canonical-v8.complete",".cbe-audio-canonical-v8.pending","build/audio_canonical_v8.complete","build/audio_canonical_v8.migrating",
  ".cbe-audio-source-recovery-v1.migrated",".cbe-audio-exhausted-v1.complete",
  "build/audio_portable_v9_assets.lua","build/audio_environment_v1.complete","build/audio_canonical_report.txt","build/audio_source_manifest.txt",
  "build/audio_warning.txt","build/audio_diagnostic.txt","build/audio_portable_report.txt",
  "assets/audio/intro/fanfare00.wav","build/boss_fanfare_v1.complete",

  -- Direct source-derived caches / acceleration metadata written after the
  -- main BuildPipeline manifest.
  "build/pokemon_full_inventory_v1.lua",
  "cache/mt_battle/colosseum_move_pools_v1.lua",
  "cache/ui/gc6e01_font0.bin","cache/ui/gc6e01_font0_supp.bin",

  -- Build state / probes.
  "build/format_probe.txt","build/camera_probe.txt","build/error.txt","build/state.txt","build/generated_paths.lua","build/hard_cache_last_failure_v1.txt",
  "build/stage_trainers.pending","build/stage_audio.pending","build/ball_release_warning.txt","build/boss_intro_warning.txt",
}

local function assetRead(mod,assets,path)
  if assets and type(assets.read)=="function" then
    local ok,v=pcall(assets.read,path);if ok and type(v)=="string" then return v end
    return nil
  end
  local cache=mod and mod.cache
  if not (cache and type(cache.read)=="function") then return nil end
  local ok,v=pcall(cache.read,cache,path);return ok and type(v)=="string" and v or nil
end

local function assetDelete(mod,assets,path)
  if assets and type(assets.delete)=="function" then
    local ok,a,b=pcall(assets.delete,path)
    if not ok then return false,tostring(a) end
    if a==false then return false,tostring(b or "delete failed") end
    return true
  end
  local cache=mod and mod.cache
  if not (cache and type(cache.delete)=="function") then return false,"cache delete unavailable" end
  local ok,a,b=pcall(cache.delete,cache,path)
  if not ok then return false,tostring(a) end
  if a==false then return false,tostring(b or "delete failed") end
  return true
end

local function deleteOnce(mod,assets,path,seen,stats)
  if type(path)~="string" or path=="" or seen[path] then return true end
  seen[path]=true
  local ok,why=assetDelete(mod,assets,path)
  if not ok then return false,("generated cache delete failed [%s]: %s"):format(path,tostring(why)) end
  stats.deleted=stats.deleted+1
  return true
end

local function manifestPaths(raw)
  if type(raw)~="string" then return {} end
  local chunk=load(raw,"@generated/cache-reset-manifest")
  if not chunk then return {} end
  local ok,value=pcall(chunk)
  if not ok or type(value)~="table" then return {} end
  return value
end

local function registryPaths(raw)
  if type(raw)~="string" then return {} end
  local chunk=load(raw,"@generated/cache-reset-registry")
  if not chunk then return {} end
  local ok,value=pcall(chunk)
  if not ok or type(value)~="table" or type(value.entries)~="table" then return {} end
  local out={}
  for path,info in pairs(value.entries) do
    -- Preservation archives are intentionally outside the active generated
    -- runtime. Even if a future registry implementation happens to observe one,
    -- DELETE keeps that byte-level rollback safety net intact.
    if type(path)=="string" and path~="" and not path:find("cache/preserved/",1,true) and type(info)=="table" then
      out[#out+1]=path
    end
  end
  table.sort(out);return out
end

local function runtimeBinPaths(raw)
  if type(raw)~="string" then return {} end
  local chunk=load(raw,"@generated/arena-reset-runtime")
  if not chunk then return {} end
  local ok,value=pcall(chunk);if not ok or type(value)~="table" then return {} end
  local out,seen={},{}
  local function walk(v,depth)
    if type(v)~="table" or depth>16 or seen[v] then return end;seen[v]=true
    for k,row in pairs(v) do
      if k=="runtimeBin" and type(row)=="string" and row~="" then out[#out+1]=row
      elseif type(row)=="table" then walk(row,depth+1) end
    end
  end
  walk(value,0);table.sort(out);return out
end

-- Failure-screen recovery for arena/cache-format failures. This is deliberately
-- narrower than reset(): valid Pokemon, MoveFX, trainer and audio caches remain
-- untouched. Imported GC6E01 source is owned by mod.imports and is never deleted.
-- Static decoded source textures are also retained because the arena rebuild can
-- safely reuse/overwrite them; only canonical scene/runtime metadata and packed
-- meshes are cleared.
function R.resetArenas(mod,assets)
  local seen={};local stats={deleted=0,scope="arenas",preservedArchives=true,importedSourcePreserved=true}
  local function remove(path)
    local ok,why=deleteOnce(mod,assets,path,seen,stats);if not ok then return false,why end
    return true
  end
  for _,id in ipairs(ARENA_IDS) do
    local meta=("cache/runtime_mesh_v8/arenas/%s/scene.lua"):format(id)
    for _,bin in ipairs(runtimeBinPaths(assetRead(mod,assets,meta))) do local ok,why=remove(bin);if not ok then return false,why,stats end end
    local ok,why=remove(meta);if not ok then return false,why,stats end
    ok,why=remove(("cache/arena_source_animation/%s.lua"):format(id));if not ok then return false,why,stats end
  end
  for _,path in ipairs(ARENA_CACHE_PATHS) do local ok,why=remove(path);if not ok then return false,why,stats end end
  for _,path in ipairs({
    ".cbe-runtime-v2.complete",".cbe-visual-v2.complete",".cbe-arena-runtime-sidecars-v2.complete",
    "build/arena_source_animation.complete","build/arena_source_animation_v2.complete",
    "build/arena_runtime_sidecars.lua","build/arena_repair.lua","build/arenas.lua",
    "build/stage_arenas.complete","build/stage_arenas.pending",
  }) do local ok,why=remove(path);if not ok then return false,why,stats end end
  for revision=2,10 do local ok,why=remove((".cbe-arena-v%d.complete"):format(revision));if not ok then return false,why,stats end end
  return true,"Arena generated cache cleared; GC6E01 source, Pokemon/MoveFX/trainer/audio caches, and preservation archives retained.",stats
end

local function deletePokemonManifest(mod,assets,path,seen,stats)
  for _,entry in ipairs(manifestPaths(assetRead(mod,assets,path))) do
    if type(entry)=="table" then
      for _,generatedPath in ipairs(entry.paths or {}) do
        local ok,why=deleteOnce(mod,assets,generatedPath,seen,stats);if not ok then return false,why end
      end
    end
  end
  return deleteOnce(mod,assets,path,seen,stats)
end

function R.reset(mod,assets)
  local seen={};local stats={deleted=0,pokemonSpecies=POKEMON_SPECIES_COUNT,pokemonManifestShards=POKEMON_MANIFEST_SHARDS,
    preservedArchives=true,importedSourcePreserved=true}

  -- Lazy 001-386 Pokemon payloads live outside BuildPipeline's finalized manifest.
  local ok,why=deletePokemonManifest(mod,assets,"cache/pokemon/manifest.lua",seen,stats);if not ok then return false,why,stats end
  for index=1,POKEMON_MANIFEST_SHARDS do
    ok,why=deletePokemonManifest(mod,assets,("cache/pokemon/manifest_v2/%02d.lua"):format(index),seen,stats)
    if not ok then return false,why,stats end
  end
  -- Older runtime-created compact metadata may not have been enrolled in either
  -- manifest. This explicit destructive path therefore covers all 386 identities.
  for dex=1,POKEMON_SPECIES_COUNT do
    ok,why=deleteOnce(mod,assets,("cache/pokemon/%d/metadata_v1.lua"):format(dex),seen,stats)
    if not ok then return false,why,stats end
  end

  -- Main source-build inventory. Carry malformed/absent manifests safely: the
  -- explicit bounded marker list below still clears transaction identity.
  local generatedRaw=assetRead(mod,assets,"build/generated_paths.lua")
  for _,path in ipairs(manifestPaths(generatedRaw)) do
    ok,why=deleteOnce(mod,assets,path,seen,stats);if not ok then return false,why,stats end
  end

  -- RuntimeMeshCache/GeneratedAssets can create source-derived sidecars after
  -- BuildPipeline and PokemonExtractor manifests have committed. The persisted
  -- positive metadata registry is a bounded ownership ledger for those paths;
  -- consume it before clearing the registry marker. This adds no directory scan.
  for _,path in ipairs(registryPaths(assetRead(mod,assets,"build/hard_cache_registry_v1.lua"))) do
    ok,why=deleteOnce(mod,assets,path,seen,stats);if not ok then return false,why,stats end
  end

  for _,path in ipairs(EXPLICIT_GENERATED_PATHS) do
    ok,why=deleteOnce(mod,assets,path,seen,stats);if not ok then return false,why,stats end
  end
  for _,path in ipairs(HARD_CACHE_MARKERS) do
    ok,why=deleteOnce(mod,assets,path,seen,stats);if not ok then return false,why,stats end
  end
  for _,id in ipairs(STAGES) do
    ok,why=deleteOnce(mod,assets,"build/stage_"..id..".complete",seen,stats);if not ok then return false,why,stats end
    ok,why=deleteOnce(mod,assets,"build/stage_"..id..".pending",seen,stats);if not ok then return false,why,stats end
  end
  return true,"Generated CBE runtime cleared; imported GC6E01 source and preservation archive retained.",stats
end


-- Total user-requested purge.  Newer Gen1Recomp hosts provide wipeAll() on the
-- already mod-scoped cache object, which recursively removes only
-- mod_cache/<this mod id>.  That is the only way to guarantee cleanup of old
-- preservation archives and historical cache iterations that predate today's
-- manifests.  Older hosts still get the bounded known-cache reset, but we do
-- not falsely report that as a complete wipe.
local function scopedLoveWipe(mod,cache)
  if not (love and love.filesystem and type(love.filesystem.getDirectoryItems)=="function"
      and type(love.filesystem.getInfo)=="function" and type(love.filesystem.remove)=="function") then return nil,"love filesystem purge unavailable" end
  if not (cache and type(cache._status)=="function") then return nil,"cache root unavailable" end
  local okStatus,status=pcall(cache._status,cache)
  local expected="mod_cache/"..tostring((mod and mod.id) or "COLOSSEUM_OVERHAUL")
  local root=okStatus and type(status)=="table" and tostring(status.root or "") or ""
  if root~=expected then return nil,"refusing whole-cache purge outside owned namespace: "..tostring(root) end
  local removed=0
  local function walk(path,removeSelf)
    local info=love.filesystem.getInfo(path)
    if not info then return true end
    if info.type=="directory" then
      for _,name in ipairs(love.filesystem.getDirectoryItems(path) or {}) do
        local ok,why=walk(path.."/"..name,true);if not ok then return false,why end
      end
      if removeSelf then
        local ok,why=love.filesystem.remove(path);if ok==false or ok==nil then return false,why or ("could not remove "..path) end
      end
    else
      local ok,why=love.filesystem.remove(path);if ok==false or ok==nil then return false,why or ("could not remove "..path) end
      removed=removed+1
      -- Large historical CBE caches can contain hundreds of thousands of tiny
      -- runtime page files. Keep Android/desktop event queues alive during the
      -- explicit destructive purge so the OS does not classify the app as hung.
      if removed%128==0 and love.event and type(love.event.pump)=="function" then pcall(love.event.pump) end
    end
    return true
  end
  local ok,why=walk(root,true);if not ok then return false,why end
  return true,removed
end

function R.wipeAll(mod,assets)
  local cache=mod and mod.cache
  if cache and type(cache.wipeAll)=="function" then
    local ok,a,b=pcall(cache.wipeAll,cache)
    if not ok then return false,"Whole CBE cache wipe failed: "..tostring(a),{complete=false,importedSourcePreserved=true} end
    if a==false or a==nil then return false,"Whole CBE cache wipe failed: "..tostring(b or "unknown error"),{complete=false,importedSourcePreserved=true} end
    return true,("All Colosseum Overhaul generated caches and historical iterations were wiped (%d files). Imported GC6E01 source was preserved."):format(tonumber(b) or 0),
      {complete=true,deleted=tonumber(b) or 0,preservedArchives=false,importedSourcePreserved=true,hostScopedWipe=true}
  end
  -- Compatibility for launchers that expose the old four-method mod.cache API.
  -- _status() returns this mod's already-scoped root; we accept only the exact
  -- expected namespace before using LOVE's filesystem recursion.
  local fsOK,fsCount=scopedLoveWipe(mod,cache)
  if fsOK==true then
    return true,("All Colosseum Overhaul generated caches and historical iterations were wiped (%d files). Imported GC6E01 source was preserved."):format(tonumber(fsCount) or 0),
      {complete=true,deleted=tonumber(fsCount) or 0,preservedArchives=false,importedSourcePreserved=true,compatScopedWipe=true}
  end
  local ok,why,stats=R.reset(mod,assets)
  stats=stats or {};stats.complete=false;stats.legacyHost=true;stats.preservedArchives=true
  if not ok then return false,why,stats end
  return false,"Known CBE cache files were cleared, but this launcher is too old for a guaranteed whole-cache wipe. Update Gen1Recomp, then use WIPE ALL CBE CACHES again to remove legacy preservation archives.",stats
end

R._test={pokemonSpeciesCount=POKEMON_SPECIES_COUNT,pokemonManifestShards=POKEMON_MANIFEST_SHARDS,
  explicitGeneratedPaths=EXPLICIT_GENERATED_PATHS,hardCacheMarkers=HARD_CACHE_MARKERS,stages=STAGES,registryPaths=registryPaths,
  runtimeBinPaths=runtimeBinPaths,arenaCachePaths=ARENA_CACHE_PATHS,arenaIds=ARENA_IDS,scopedLoveWipe=scopedLoveWipe}

return R
