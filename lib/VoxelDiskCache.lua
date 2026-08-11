-- Persistent terrain-mesh cache for the Gold/Silver/Crystal + Yellow/Kanto voxel renderer.
--
-- v0.3.32 rebuilds the old disabled cache around Gen1Recomp's ENGINE-OWNED
-- persistence filesystem (EngineCompat.fs -> SaveData.persistenceFs).  The
-- previous cache was disabled because direct love.filesystem access and a
-- stale geometry format could resurrect incomplete/misaligned worlds.  This
-- implementation is deliberately conservative:
--
--   * every entry is keyed by a geometry revision + complete map/tile body
--     signature + mesh slot + seam-mask signature;
--   * terrain/water byte lengths are validated before a hit is accepted;
--   * metadata is written LAST, so an interrupted write is always a miss;
--   * both BODY and FULL variants are cacheable;
--   * current engine persistence routing is used, so portable mode follows the
--     same root as saves/options without exposing raw filesystem globals;
--   * raw vertex streams upload in cooperative chunks when the backend permits,
--     so a cache hit does not have to become one giant frame spike.
--
-- What is cached is the FINAL unindexed six-float vertex stream produced by
-- ChunkMesher.  Texture/palette images remain separate runtime resources, so a
-- palette recolor does not invalidate geometry.  UV layout IS part of the map
-- signature because UVs are baked into the vertex stream.

local V = ...
local Voxel3D = V.require("Voxel3D")
local Budget = V.require("BuildBudget")
local EngineCompat = V.require("EngineCompat")

local Cache = {
  hits = 0,
  misses = 0,
  probes = 0,
  probeHits = 0,
  writes = 0,
  errors = 0,
  bytesLoaded = 0,
  bytesWritten = 0,
  lastError = nil,
}

-- Bump whenever geometry semantics / raw vertex meaning changes.
local GEOM_REV = "g2vx-400-r1"
local BASE_DIR = "stadium2_voxel_cache/" .. GEOM_REV
local FLOATS_PER_VERTEX = 6
local BYTES_PER_VERTEX = FLOATS_PER_VERTEX * 4
local CHUNK_VERTS = 65536
local writeCounter = 0

local function activeGameId()
  local ok, GameVersion = pcall(require, "src.core.GameVersion")
  if ok and type(GameVersion) == "table" and type(GameVersion.get) == "function" then
    local okGet, id = pcall(GameVersion.get)
    if okGet and type(id) == "string" and id ~= "" then
      id = id:lower():gsub("[^%w_%-]", "_")
      return id
    end
  end
  return "gen2"
end

local function cacheDir()
  -- Gold/Silver/Crystal share many symbolic map ids but not necessarily the
  -- same tile bodies. Keep each edition's persistent mesh corpus separate so
  -- switching games cannot make PALLET_TOWN/ROUTE_* metadata thrash the same
  -- filenames even though signature validation would eventually reject it.
  return BASE_DIR .. "/" .. activeGameId()
end

local function optionEnabled()
  local mod = V.mod
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return true end
  local ok, value = pcall(options.get, options, "voxelDiskCache")
  if not ok or value == nil then return true end
  return not (value == false or value == 0 or value == "0"
    or value == "false" or value == "off")
end

local function fsBackend()
  if not optionEnabled() then return nil end
  local fs = EngineCompat.fs()
  if type(fs) ~= "table" then return nil end
  if type(fs.getInfo) ~= "function" or type(fs.read) ~= "function"
      or type(fs.write) ~= "function" then return nil end
  return fs
end

function Cache.enabled()
  if not fsBackend() then return false end
  return love and love.graphics and love.data
    and type(love.graphics.newMesh) == "function"
    and type(love.data.newByteData) == "function"
end

local function runtimeAvailable()
  return Cache.enabled()
end

local function sanitize(value)
  value = tostring(value or "map")
  value = value:gsub("[^%w_%-%.]", "_")
  if #value > 96 then value = value:sub(1, 96) end
  return value
end

-- A 31-bit rolling hash is exact in Lua's double-number integer range and is
-- intentionally arithmetic-only so LuaJIT 5.1 needs no bit library.
local MOD = 2147483647
local function hashAdd(h, value)
  if type(value) == "string" then
    for i = 1, #value do h = (h * 65599 + value:byte(i) + 1) % MOD end
    return h
  end
  local n = tonumber(value) or 0
  n = math.floor(n * 1000 + (n >= 0 and 0.5 or -0.5))
  return (h * 65599 + (n % MOD) + 1) % MOD
end

-- Memo is safe only while the map body is unchanged. ChunkMesher calls
-- invalidateMap() on refresh/invalidate so a Cut/door/block mutation cannot
-- reuse the pre-edit signature.
local signatureMemo = setmetatable({}, { __mode = "k" })
local function bodySignature(map)
  local memo = signatureMemo[map]
  if memo then return memo end
  local def = map and map.def or {}
  local tw = math.max(0, (tonumber(def.width) or 0) * 4)
  local th = math.max(0, (tonumber(def.height) or 0) * 4)
  local h = 146959
  h = hashAdd(h, GEOM_REV)
  h = hashAdd(h, activeGameId())
  h = hashAdd(h, map and map.id or "")
  h = hashAdd(h, def.sourceId or "")
  h = hashAdd(h, def.tileset or (map and map.tileset and map.tileset.id) or "")
  h = hashAdd(h, def.width or 0)
  h = hashAdd(h, def.height or 0)
  h = hashAdd(h, def.borderBlock or def.border or 0)
  h = hashAdd(h, def.outdoor == true and 1 or 0)
  -- Border/apron decisions also depend on cardinal connection identity and
  -- offset. Include them even though FULL seam masks are signed separately.
  for _, dir in ipairs({ "north", "south", "west", "east" }) do
    local conn = def.connections and def.connections[dir]
    h = hashAdd(h, dir)
    if type(conn) == "table" then
      h = hashAdd(h, conn.map or conn.mapId or "")
      h = hashAdd(h, conn.offset or conn.xOffset or conn.yOffset or 0)
    else
      h = hashAdd(h, "-")
    end
  end
  local ts = map and map.tileset or {}
  -- v0.3.40: projected Kanto geometry depends on the synthetic voxel profile,
  -- not only on Yellow's original def.tileset id.  Include that presentation
  -- identity so a cached v0.3.38/older BODY cannot resurrect stale trees/walls
  -- after the Gen-2 projection changes shape classification.
  h = hashAdd(h, ts.id or "")
  h = hashAdd(h, ts._stadiumGen2DonorId or (map and map._stadiumGen2DonorId) or "")
  h = hashAdd(h, ts._stadiumProjectionRevision or (map and map._stadiumProjectionRevision) or "")
  h = hashAdd(h, ts.tilesPerRow or 16)
  h = hashAdd(h, ts.imageWidth or 0)
  h = hashAdd(h, ts.imageHeight or 0)
  if map and type(map.tileAt) == "function" then
    for y = 0, th - 1 do
      for x = 0, tw - 1 do
        h = hashAdd(h, map:tileAt(x, y) or -1)
        Budget.tick()
      end
    end
  end
  memo = tostring(h)
  signatureMemo[map] = memo
  return memo
end

local function maskSignature(masks)
  local rows = {}
  for _, m in ipairs(type(masks) == "table" and masks or {}) do
    rows[#rows + 1] = table.concat({
      tostring(tonumber(m[1]) or 0), tostring(tonumber(m[2]) or 0),
      tostring(tonumber(m[3]) or 0), tostring(tonumber(m[4]) or 0),
    }, ",")
  end
  table.sort(rows)
  local h = 8191
  for _, row in ipairs(rows) do h = hashAdd(h, row) end
  return tostring(h)
end

local function signature(map, slot, masks)
  return table.concat({ GEOM_REV, bodySignature(map), tostring(slot),
    maskSignature(masks) }, "|")
end

local function paths(map, slot)
  local stem = cacheDir() .. "/" .. sanitize(map and map.id) .. "_" .. sanitize(slot)
  return stem .. ".meta", stem .. ".terrain.bin", stem .. ".water.bin"
end

local function readAll(fs, path)
  local ok, contents = pcall(fs.read, path)
  if not ok then return nil end
  return contents
end

local function parseMeta(text)
  if type(text) ~= "string" then return nil end
  local magic, sig, terrain, water = text:match("^(.-)\n(.-)\n(%d+)\n(%d+)\n?")
  if magic ~= "VXM3" then return nil end
  return sig, tonumber(terrain), tonumber(water)
end

local function fileSize(fs, path)
  local ok, info = pcall(fs.getInfo, path)
  if ok and type(info) == "table" then
    if info.size == nil then return -1 end
    return tonumber(info.size) or 0
  end
  -- Some portable/headless persistence backends expose getInfo without size.
  -- In that case return -1 and let the actual read length be authoritative.
  if ok and info then return -1 end
  return 0
end

local function validEntry(fs, map, slot, masks)
  local metaPath, terrainPath, waterPath = paths(map, slot)
  local meta = readAll(fs, metaPath)
  if not meta then return false end
  local sig, terrainCount, waterCount = parseMeta(meta)
  if not sig or sig ~= signature(map, slot, masks) then return false end
  if not terrainCount or terrainCount <= 0 or waterCount == nil then return false end
  local terrainSize = fileSize(fs, terrainPath)
  local waterSize = fileSize(fs, waterPath)
  local wantTerrain = terrainCount * BYTES_PER_VERTEX
  local wantWater = waterCount * BYTES_PER_VERTEX
  if terrainSize >= 0 and terrainSize ~= wantTerrain then return false end
  if waterCount > 0 then
    if waterSize >= 0 and waterSize ~= wantWater then return false end
  elseif waterSize > 0 then
    -- A stale file is harmless because count 0 is authoritative, but treating
    -- it as valid would hide interrupted cleanup and waste disk forever.
    return false
  end
  return true, terrainCount, waterCount, terrainPath, waterPath
end

-- Cheap metadata/signature check used by cache-only region warmers.  It never
-- allocates a Mesh or uploads GPU data.
function Cache.probe(map, slot, masks)
  if not runtimeAvailable() then return false end
  local fs = fsBackend()
  Cache.probes = Cache.probes + 1
  local ok = validEntry(fs, map, slot, masks)
  if ok then Cache.probeHits = Cache.probeHits + 1 end
  return ok == true
end

local function meshFromChunks(fs, path, count)
  count = math.floor(tonumber(count) or 0)
  if count <= 0 then return nil, true end
  local expected = count * BYTES_PER_VERTEX

  local okMesh, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, count,
    "triangles", "static")
  if not okMesh or not mesh then return nil, false, tostring(mesh) end

  local function fail(err)
    if mesh and mesh.release then pcall(mesh.release, mesh) end
    return nil, false, tostring(err)
  end

  -- Preferred path on normal desktop/mobile LÖVE persistence: stream from the
  -- engine-owned File object, so a 20MB cached route never needs a second 20MB
  -- Lua string alive all at once.
  if type(fs.newFile) == "function" then
    local okFile, file = pcall(fs.newFile, path)
    if okFile and file then
      local okOpen, opened = pcall(file.open, file, "r")
      if okOpen and opened ~= false then
        local at, readBytes = 0, 0
        while at < count do
          local verts = math.min(CHUNK_VERTS, count - at)
          local bytes = verts * BYTES_PER_VERTEX
          local okRead, chunk = pcall(file.read, file, bytes)
          if not okRead or type(chunk) ~= "string" or #chunk ~= bytes then
            pcall(file.close, file)
            return fail("short cached mesh read")
          end
          local data = love.data.newByteData(chunk)
          mesh:setVertices(data, at + 1)
          if data.release then pcall(data.release, data) end
          at = at + verts
          readBytes = readBytes + bytes
          Budget.check()
        end
        pcall(file.close, file)
        if readBytes ~= expected then return fail("cached mesh byte count mismatch") end
        return mesh, true
      end
    end
  end

  -- Portable-mode persistence intentionally exposes only read/write.  It still
  -- gets the same validated cache; slice the one returned string into upload
  -- chunks so GPU submission remains cooperative.
  local raw = readAll(fs, path)
  if type(raw) ~= "string" or #raw ~= expected then
    return fail("cached mesh byte count mismatch")
  end
  local at, byteAt = 0, 1
  while at < count do
    local verts = math.min(CHUNK_VERTS, count - at)
    local bytes = verts * BYTES_PER_VERTEX
    local chunk = raw:sub(byteAt, byteAt + bytes - 1)
    local data = love.data.newByteData(chunk)
    mesh:setVertices(data, at + 1)
    if data.release then pcall(data.release, data) end
    at = at + verts
    byteAt = byteAt + bytes
    Budget.check()
  end
  return mesh, true
end

function Cache.load(map, slot, masks)
  if not runtimeAvailable() then return false end
  local fs = fsBackend()
  local valid, terrainCount, waterCount, terrainPath, waterPath
    = validEntry(fs, map, slot, masks)
  if not valid then
    Cache.misses = Cache.misses + 1
    return false
  end

  local terrain, okT, errT = meshFromChunks(fs, terrainPath, terrainCount)
  if not okT then
    Cache.errors = Cache.errors + 1
    Cache.lastError = errT
    return false
  end
  local water, okW, errW = meshFromChunks(fs, waterPath, waterCount)
  if not okW then
    if terrain and terrain.release then pcall(terrain.release, terrain) end
    Cache.errors = Cache.errors + 1
    Cache.lastError = errW
    return false
  end

  Cache.hits = Cache.hits + 1
  Cache.bytesLoaded = Cache.bytesLoaded
    + (terrainCount + waterCount) * BYTES_PER_VERTEX
  Cache.lastError = nil
  return true, terrain, water
end

local function createDir(fs)
  if type(fs.createDirectory) ~= "function" then return true end
  local ok, result = pcall(fs.createDirectory, cacheDir())
  return ok and result ~= false
end

local function remove(fs, path)
  if type(fs.remove) == "function" then pcall(fs.remove, path) end
end

local function writeText(fs, path, text)
  local ok, result = pcall(fs.write, path, text)
  return ok and result ~= false
end

local function cacheCapBytes()
  local osName = EngineCompat.osName()
  if osName == "Android" or osName == "iOS" then
    return 768 * 1024 * 1024
  end
  -- Raw floats are chosen for fastest loading; desktop gets a generous cap so
  -- an entire Kanto surface plus frequently visited Johto routes can persist.
  return 4 * 1024 * 1024 * 1024
end

-- Best-effort LRU-ish pruning. Portable persistence does not expose directory
-- listing/stat metadata, so it simply skips pruning rather than bypassing the
-- engine-owned filesystem with raw io.*.
local function prune(fs)
  if not (type(fs.getDirectoryItems) == "function"
      and type(fs.getInfo) == "function" and type(fs.remove) == "function") then
    return
  end
  local ok, items = pcall(fs.getDirectoryItems, cacheDir())
  if not ok or type(items) ~= "table" then return end
  local groups, total = {}, 0
  for _, name in ipairs(items) do
    local path = cacheDir() .. "/" .. name
    local okInfo, info = pcall(fs.getInfo, path)
    if okInfo and info and info.type == "file" then
      local stem = name:gsub("%.terrain%.bin$", "")
                       :gsub("%.water%.bin$", "")
                       :gsub("%.meta$", "")
      local g = groups[stem] or { stem = stem, bytes = 0, time = math.huge }
      local bytes = tonumber(info.size) or 0
      g.bytes = g.bytes + bytes
      g.time = math.min(g.time, tonumber(info.modtime) or 0)
      groups[stem] = g
      total = total + bytes
    end
  end
  local cap = cacheCapBytes()
  if total <= cap then return end
  local order = {}
  for _, g in pairs(groups) do order[#order + 1] = g end
  table.sort(order, function(a, b) return a.time < b.time end)
  for _, g in ipairs(order) do
    if total <= cap then break end
    for _, suffix in ipairs({ ".meta", ".terrain.bin", ".water.bin" }) do
      remove(fs, cacheDir() .. "/" .. g.stem .. suffix)
    end
    total = total - g.bytes
  end
end

-- `terrainSink` / `waterSink` are ChunkMesher FFI sinks.  writeRaw(fs,path)
-- owns native-buffer serialization so this module never reaches into cdata.
function Cache.store(map, slot, masks, terrainSink, waterSink)
  if not runtimeAvailable() then return false end
  if not (terrainSink and type(terrainSink.vertexCount) == "function"
      and type(terrainSink.writeRaw) == "function") then return false end
  local fs = fsBackend()
  if not createDir(fs) then return false end

  local terrainCount = tonumber(terrainSink:vertexCount()) or 0
  local waterCount = (waterSink and type(waterSink.vertexCount) == "function")
    and (tonumber(waterSink:vertexCount()) or 0) or 0
  if terrainCount <= 0 then return false end

  local metaPath, terrainPath, waterPath = paths(map, slot)
  -- Remove metadata FIRST. If the process dies during either large binary
  -- write, no valid marker remains and the next run safely rebuilds.
  remove(fs, metaPath)

  local okT, errT = terrainSink:writeRaw(fs, terrainPath)
  if not okT then
    Cache.errors = Cache.errors + 1
    Cache.lastError = tostring(errT)
    return false
  end
  if waterCount > 0 and waterSink then
    local okW, errW = waterSink:writeRaw(fs, waterPath)
    if not okW then
      Cache.errors = Cache.errors + 1
      Cache.lastError = tostring(errW)
      return false
    end
  else
    remove(fs, waterPath)
  end

  -- Metadata LAST is the commit record.
  local meta = table.concat({ "VXM3", signature(map, slot, masks),
    tostring(terrainCount), tostring(waterCount), "" }, "\n")
  if not writeText(fs, metaPath, meta) then
    Cache.errors = Cache.errors + 1
    Cache.lastError = "could not write voxel cache metadata"
    return false
  end

  Cache.writes = Cache.writes + 1
  Cache.bytesWritten = Cache.bytesWritten
    + (terrainCount + waterCount) * BYTES_PER_VERTEX
  Cache.lastError = nil
  writeCounter = writeCounter + 1
  if writeCounter % 8 == 0 then pcall(prune, fs) end
  return true
end

function Cache.invalidateMap(map)
  if type(map) == "table" then signatureMemo[map] = nil end
end

function Cache.invalidateSignatures()
  signatureMemo = setmetatable({}, { __mode = "k" })
end

function Cache.clear()
  local fs = fsBackend()
  if not (fs and type(fs.getDirectoryItems) == "function"
      and type(fs.remove) == "function") then return false end
  local ok, items = pcall(fs.getDirectoryItems, cacheDir())
  if not ok then return false end
  for _, name in ipairs(items or {}) do remove(fs, cacheDir() .. "/" .. name) end
  return true
end

function Cache.status()
  local osName = EngineCompat.osName()
  return {
    enabled = Cache.enabled(),
    recoveryDisabled = false,
    backend = fsBackend() and "engine-persistence" or "unavailable",
    revision = GEOM_REV,
    desktop = osName ~= "Android" and osName ~= "iOS",
    hits = Cache.hits,
    misses = Cache.misses,
    probes = Cache.probes,
    probeHits = Cache.probeHits,
    writes = Cache.writes,
    errors = Cache.errors,
    bytesLoaded = Cache.bytesLoaded,
    bytesWritten = Cache.bytesWritten,
    lastError = Cache.lastError,
  }
end

Cache.activeGameId = activeGameId
Cache.cacheDir = cacheDir

return Cache
