-- One-shot installer for the HD sheet pack(s) used by lib/HDPokemonSheets.lua.
--
-- Downloads each configured release ZIP with the engine's streaming Fetch,
-- reads the ZIP directly (no unzip dependency) and copies ONLY the sheet PNGs
-- for National Dex 1..493 into mod.cache under hd_sheets/<facing>/<color>/.
-- That is exactly where HDPokemonSheets looks first, so nothing else needs to
-- be told: it re-scans when the install finishes.
--
-- The cap is HDPokemonSheets.MAX_DEX (493), not whatever the pack happens to
-- hold: files for dex 494+ are never written, and nothing here assumes the pack
-- stops at 386. Whatever 1..493 files a release actually contains are
-- installed; the end-of-install log says how many landed in 1-386 and in
-- 387-493, so it is obvious what a given pack covers.
--
-- Needs the "network" permission (manifest) and the engine's Fetch/ModUpdate.
-- Pumped once per frame from main.lua's input.step wrap; the OPTIONS-menu row
-- (I.row) starts/cancels it and shows live progress through its value().
--
-- ZIP + release flow is modelled on the engine APIs Kanto in Motion uses for
-- its own asset pack; the code is written for this mod.
local V = ...
local mod = V and V.mod

local I = { VERSION = 1, ID = "hd_sheets_install", LABEL = "HD SHEETS" }

I.config = {
  -- Processed in order. Add a second entry to pull a Gen 4 (387-493) pack from
  -- another release: same layout, assets/battle/hd-pokemon/<facing>/<color>/NNN.png
  sources = {
    {
      name = "Terri-Assets HD Pokemon (full 1-493)",
      repo = "MINIMI75/Terri-Assets",
      version = "1.0.0",
      packId = nil, -- no asset-pack.json for this pack
      prefix = "hd-pokemon/",
      userAgent = "terrarium-hd-sheets",
    },
    {
      name = "Kanto in Motion assets",
      repo = "HaseoSora/Kanto-in-Motion-Assets",
      version = "1.0.0",
      packId = "kanto_in_motion_assets", -- checked against asset-pack.json when set
      prefix = "assets/battle/hd-pokemon/",
      userAgent = "terrarium-hd-sheets",
    },
  },
  tempName = "terrarium_hd_sheets.tmp.zip",
  -- Manual route: drop the release ZIP here (save folder) and press the row.
  -- No network is used and the file is never deleted.
  localZip = "terrarium_hd_sheets_pack.zip",
  apiTemp = "terrarium_hd_sheets_releases.tmp.json",
  extractBudget = 0.010,       -- seconds of unpacking per frame
  maxSeconds = 15 * 60,        -- the release ZIP is large; Fetch's default is too short
  maxFile = 64 * 1024 * 1024,
}

local st = {
  state = "idle",   -- idle | checking | downloading | extracting | done | error
  error = nil,
  srcIndex = 0,
  total = 0, bytes = 0,            -- download
  files = {}, pos = 1,             -- extraction queue
  counts = nil,
  coverage = nil,
}

local function HD()
  local ok, m = pcall(V.require, "HDPokemonSheets")
  return ok and m or nil
end

local function maxDex()
  local hd = HD()
  return hd and hd.MAX_DEX or 493
end

local function lowMax()
  local hd = HD()
  return hd and hd.COLOSSEUM_MAX or 386
end

local function cacheDir()
  local hd = HD()
  return hd and hd.config and hd.config.cacheDir or "hd_sheets"
end

local function log(level, fmt, ...)
  local l = mod and mod.log
  if l and type(l[level]) == "function" then pcall(l[level], l, fmt, ...) end
end

local function cacheOk()
  local c = mod and mod.cache
  return c and type(c.read) == "function" and type(c.write) == "function" and type(c.info) == "function"
end

local function cacheInfo(key)
  local ok, info = pcall(function() return mod.cache:info(key) end)
  return ok and info or nil
end

local function cacheWrite(key, bytes)
  local ok, wrote, err = pcall(function() return mod.cache:write(key, bytes) end)
  if not ok then return false, tostring(wrote) end
  if wrote == false then return false, tostring(err or "cache write failed") end
  return true
end

-- ------- ZIP ---------------------------------------------------------------

local function le16(s, p)
  local a, b = s:byte(p, p + 1)
  if not b then return nil end
  return a + b * 256
end

local function le32(s, p)
  local a, b, c, d = s:byte(p, p + 3)
  if not d then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

local function rawFilesystem()
  local okS, SaveData = pcall(require, "src.core.SaveData")
  if not okS or not SaveData or type(SaveData.persistenceFs) ~= "function" then
    return nil, "persistence filesystem is unavailable"
  end
  local okF, fs = pcall(SaveData.persistenceFs)
  if not okF or type(fs) ~= "table" then return nil, "raw filesystem is unavailable" end
  if type(fs.newFile) ~= "function" or type(fs.getInfo) ~= "function" or type(fs.remove) ~= "function" then
    return nil, "ZIP install needs the random-access save filesystem (not available in portable mode)"
  end
  return fs
end

local function closeReader()
  local r = st.reader
  if r and r.file and type(r.file.close) == "function" then pcall(function() r.file:close() end) end
  st.reader = nil
end

local function removeTemp()
  local fs = st.fs
  if fs and type(fs.remove) == "function" then pcall(fs.remove, I.config.tempName) end
end

local function cleanup()
  closeReader()
  removeTemp()
end

local function cancelNetwork()
  if not st.job then return end
  local ok, Fetch = pcall(require, "src.net.Fetch")
  if ok and Fetch then
    if type(Fetch.cancel) == "function" then pcall(Fetch.cancel, st.job) end
    if type(Fetch.release) == "function" then pcall(Fetch.release, st.job) end
  end
  st.job = nil
end

local function fail(message)
  cleanup()
  cancelNetwork()
  st.releaseHandle = nil
  st.apiPhase = false
  pcall(function() if st.fs then st.fs.remove(I.config.apiTemp) end end)
  st.state = "error"
  st.error = tostring(message or "unknown installer error")
  log("error", "HD sheet installer: %s", st.error)
end

local function keysOf(t)
  local out = {}
  if type(t) == "table" then
    for k, v in pairs(t) do if type(v) == "function" then out[#out + 1] = tostring(k) end end
  end
  table.sort(out)
  return table.concat(out, ",")
end

-- What this engine build actually offers. Used to choose a route and, when no
-- route works, to say precisely what is missing instead of a vague "unavailable".
local function probe()
  local p = { lines = {} }
  local okM, M = pcall(require, "src.mods.ModUpdate")
  if okM and type(M) == "table" then
    p.releases = type(M.beginFetchReleases) == "function" and type(M.pumpFetchReleases) == "function"
    p.lines[#p.lines + 1] = "src.mods.ModUpdate: loaded; functions=[" .. keysOf(M) .. "]"
  else
    p.lines[#p.lines + 1] = "src.mods.ModUpdate: require failed: " .. tostring(M)
  end
  local okF, F = pcall(require, "src.net.Fetch")
  if okF and type(F) == "table" then
    p.download = type(F.download) == "function" and type(F.poll) == "function" and type(F.release) == "function"
    p.lines[#p.lines + 1] = "src.net.Fetch: loaded; functions=[" .. keysOf(F) .. "]"
  else
    p.lines[#p.lines + 1] = "src.net.Fetch: require failed: " .. tostring(F)
  end
  return p
end

local function diagnosis(headline)
  local lines = { headline }
  for _, l in ipairs(probe().lines) do lines[#lines + 1] = "  " .. l end
  local where = ""
  if love and love.filesystem and type(love.filesystem.getSaveDirectory) == "function" then
    local ok, dir = pcall(love.filesystem.getSaveDirectory)
    if ok and type(dir) == "string" then where = " (" .. dir .. ")" end
  end
  lines[#lines + 1] = "  Manual install: download the asset release ZIP in a browser, save it as '"
    .. I.config.localZip .. "' in the game's save folder" .. where
    .. ", then press the HD SHEETS row again."
  return table.concat(lines, "\n")
end

local function openReader()
  closeReader()
  local okNew, file, newErr = pcall(st.fs.newFile, st.zipName or I.config.tempName)
  if not okNew or not file then return nil, tostring(newErr or file or "could not open the downloaded ZIP") end
  local okOpen, opened, openErr = pcall(function() return file:open("r") end)
  if not okOpen or opened == false then
    pcall(function() file:close() end)
    return nil, tostring(openErr or opened or "could not open the downloaded ZIP")
  end
  local okSize, size = pcall(function() return file:getSize() end)
  if not okSize or not tonumber(size) or tonumber(size) < 22 then
    pcall(function() file:close() end)
    return nil, "downloaded file is too small to be a ZIP"
  end
  local r = { file = file, size = tonumber(size) }
  function r:readAt(offset, count)
    if offset < 0 or count < 0 or offset + count > self.size then return nil, "read outside the archive" end
    local okSeek, seeked = pcall(function() return self.file:seek(offset) end)
    if not okSeek or seeked == false then return nil, "ZIP seek failed" end
    local okRead, data, readErr = pcall(function() return self.file:read(count) end)
    if not okRead or type(data) ~= "string" then return nil, tostring(readErr or data or "ZIP read failed") end
    if #data ~= count then return nil, "ZIP read was truncated" end
    return data
  end
  st.reader = r
  return r
end

-- Every file entry in the archive: { name, method, compressedSize, size, localOffset }
local function scanDirectory(reader)
  local tailSize = math.min(reader.size, 22 + 65535 + 256)
  local tail, tailErr = reader:readAt(reader.size - tailSize, tailSize)
  if not tail then return nil, tailErr end
  local eocd
  for i = #tail - 21, 1, -1 do
    if tail:sub(i, i + 3) == "PK\005\006" then eocd = i; break end
  end
  if not eocd then return nil, "ZIP end record not found" end
  local entries, cdSize, cdOffset = le16(tail, eocd + 10), le32(tail, eocd + 12), le32(tail, eocd + 16)
  if not (entries and cdSize and cdOffset) then return nil, "ZIP end record is truncated" end
  if entries == 0xFFFF or cdSize == 0xFFFFFFFF or cdOffset == 0xFFFFFFFF then
    return nil, "ZIP64 packs are not supported"
  end
  if cdOffset + cdSize > reader.size then return nil, "ZIP directory is outside the archive" end
  local cd, cdErr = reader:readAt(cdOffset, cdSize)
  if not cd then return nil, cdErr end
  local out, pos = {}, 1
  for _ = 1, entries do
    if cd:sub(pos, pos + 3) ~= "PK\001\002" then return nil, "ZIP directory entry is invalid" end
    local flags = le16(cd, pos + 8) or 0
    local method = le16(cd, pos + 10)
    local compSize, size = le32(cd, pos + 20), le32(cd, pos + 24)
    local nameLen, extraLen, commentLen = le16(cd, pos + 28), le16(cd, pos + 30), le16(cd, pos + 32)
    local localOffset = le32(cd, pos + 42)
    if not (method and compSize and size and nameLen and extraLen and commentLen and localOffset) then
      return nil, "ZIP directory is truncated"
    end
    local nameStart = pos + 46
    local name = cd:sub(nameStart, nameStart + nameLen - 1):gsub("\\", "/")
    if flags % 2 == 1 then return nil, "encrypted ZIP entries are not supported" end
    if name:sub(-1) ~= "/" then
      out[#out + 1] = { name = name, method = method, compressedSize = compSize, size = size, localOffset = localOffset }
    end
    pos = nameStart + nameLen + extraLen + commentLen
  end
  return out
end

local function readEntry(reader, item)
  local hdr, hdrErr = reader:readAt(item.localOffset, 30)
  if not hdr then return nil, hdrErr end
  if hdr:sub(1, 4) ~= "PK\003\004" then return nil, "ZIP local header is invalid" end
  local method, nameLen, extraLen = le16(hdr, 9), le16(hdr, 27), le16(hdr, 29)
  if not (method and nameLen and extraLen) then return nil, "ZIP local header is truncated" end
  if method ~= item.method then return nil, "ZIP compression metadata mismatch" end
  local packed, packedErr = reader:readAt(item.localOffset + 30 + nameLen + extraLen, item.compressedSize)
  if not packed then return nil, packedErr end
  local bytes = packed
  if item.method == 8 then
    if not (love and love.data and type(love.data.decompress) == "function") then
      return nil, "raw DEFLATE support is unavailable"
    end
    local ok, inflated = pcall(love.data.decompress, "string", "deflate", packed)
    if not ok or type(inflated) ~= "string" then return nil, "DEFLATE decompression failed" end
    bytes = inflated
  elseif item.method ~= 0 then
    return nil, "unsupported ZIP compression method " .. tostring(item.method)
  end
  if #bytes ~= item.size then return nil, ("ZIP entry size mismatch (%d/%d)"):format(#bytes, item.size) end
  return bytes
end

-- ------- which entries are sheets ------------------------------------------

-- "assets/battle/hd-pokemon/front/normal/154-m.png" -> "front/normal/154-m.png", 154
local function sheetOf(name, prefix)
  if name:sub(1, #prefix) ~= prefix then return nil end
  local facing, color, num, rest = name:sub(#prefix + 1):match("^(%a+)/(%a+)/(%d%d%d)([%w%-]*)%.png$")
  if not facing or (facing ~= "front" and facing ~= "back") or (color ~= "normal" and color ~= "shiny") then
    return nil
  end
  return ("%s/%s/%s%s.png"):format(facing, color, num, rest), tonumber(num)
end
I._sheetOf = sheetOf

-- ------- state machine -----------------------------------------------------

local function source() return I.config.sources[st.srcIndex] end

local function finishAll()
  cleanup()
  st.state = "done"
  st.error = nil
  st.coverage = nil
  local hd = HD()
  if hd and hd.rescan then pcall(hd.rescan) end
  local c = I.coverage()
  log("info", "HD sheets installed: dex 1-%d %d/%d, dex %d-%d %d/%d (needs front+back)",
    lowMax(), c.low, lowMax(), lowMax() + 1, maxDex(), c.high, maxDex() - lowMax())
end

local function finishSource()
  closeReader()
  removeTemp()
  if st.srcIndex < #I.config.sources then
    I._startSource(st.srcIndex + 1)
  else
    finishAll()
  end
end

local function beginExtraction()
  local reader, openErr = openReader()
  if not reader then return fail("downloaded ZIP could not be read: " .. tostring(openErr)) end
  local entries, scanErr = scanDirectory(reader)
  if not entries then return fail("downloaded ZIP is invalid: " .. tostring(scanErr)) end
  local src = source()
  if src.packId then
    local meta
    for _, e in ipairs(entries) do if e.name == "asset-pack.json" then meta = e; break end end
    if not meta then return fail("asset ZIP has no asset-pack.json") end
    local raw, rawErr = readEntry(reader, meta)
    if not raw then return fail("could not read asset-pack.json: " .. tostring(rawErr)) end
    local id = raw:match('"id"%s*:%s*"([^"]+)"')
    local version = raw:match('"version"%s*:%s*"([^"]+)"')
    if version and src.version and version ~= src.version then
      return fail("asset pack version mismatch: " .. version)
    end
    if id and id ~= src.packId then return fail("this ZIP is not the expected asset pack") end
  end
  local cap = maxDex()
  local queue, c = {}, st.counts
  for _, e in ipairs(entries) do
    local rel, dex = sheetOf(e.name, src.prefix)
    if rel then
      if dex < 1 or dex > cap then
        c.over = c.over + 1                      -- dex 494+: never installed
      elseif e.size > I.config.maxFile then
        return fail("sheet exceeds the 64 MB cache limit: " .. e.name)
      else
        queue[#queue + 1] = { rel = rel, dex = dex, item = e }
      end
    else
      c.other = c.other + 1
    end
  end
  if #queue == 0 then return fail("the pack contains no HD sheets for dex 1-" .. cap) end
  table.sort(queue, function(a, b) return a.rel < b.rel end)
  st.files, st.pos = queue, 1
  st.state = "extracting"
  log("info", "HD sheet pack '%s': %d sheets for dex 1-%d (%d above the cap ignored)",
    tostring(src.name), #queue, cap, c.over)
end

local function pumpExtraction()
  local reader = st.reader
  if not reader then return fail("temporary ZIP closed during extraction") end
  local timer = love and love.timer and love.timer.getTime
  local started = timer and timer() or nil
  local processed = 0
  local dir, c = cacheDir(), st.counts
  while st.pos <= #st.files do
    local f = st.files[st.pos]
    local key = dir .. "/" .. f.rel
    local info = cacheInfo(key)
    if info and (tonumber(info.size) or -1) == f.item.size then
      c.existing = c.existing + 1
    else
      local bytes, readErr = readEntry(reader, f.item)
      if type(bytes) ~= "string" then
        return fail("could not extract " .. f.rel .. ": " .. tostring(readErr or "read failed"))
      end
      local ok, writeErr = cacheWrite(key, bytes)
      if not ok then return fail("could not install " .. f.rel .. ": " .. tostring(writeErr)) end
      c.written = c.written + 1
    end
    if f.dex <= lowMax() then c.low = c.low + 1 else c.high = c.high + 1 end
    st.pos = st.pos + 1
    processed = processed + 1
    if timer then
      if timer() - started >= I.config.extractBudget then break end
    elseif processed >= 2 then
      break
    end
  end
  if st.pos > #st.files then finishSource() end
end

local function beginDownload(release)
  if type(release) ~= "table" or not (release.zip and release.zip.url) then
    return fail("the GitHub release has no asset ZIP")
  end
  local okF, Fetch = pcall(require, "src.net.Fetch")
  if not okF or not Fetch or type(Fetch.download) ~= "function" then
    return fail("the engine's streaming downloader is unavailable")
  end
  removeTemp()
  st.zipName = I.config.tempName
  st.total = tonumber(release.zip.size) or 0
  st.bytes = 0
  st.job = Fetch.download(release.zip.url, I.config.tempName, {
    size = st.total > 0 and st.total or nil,
    userAgent = source().userAgent or "terrarium-hd-sheets",
    maxSeconds = I.config.maxSeconds,
  })
  if not st.job then return fail("could not start the ZIP download") end
  st.state = "downloading"
end

local function readSaveFile(name)
  local okN, file = pcall(st.fs.newFile, name)
  if not okN or not file then return nil end
  local okO, opened = pcall(function() return file:open("r") end)
  if not okO or opened == false then return nil end
  local okS, size = pcall(function() return file:getSize() end)
  local data
  if okS and tonumber(size) and tonumber(size) > 0 then
    local okR, got = pcall(function() return file:read(tonumber(size)) end)
    if okR and type(got) == "string" then data = got end
  end
  pcall(function() file:close() end)
  return data
end

-- GitHub's release list -> the release the source wants -> {version, zip={url,size}}
local function pickRelease(raw, src)
  local okJ, Json = pcall(require, "src.link.Json")
  if not (okJ and Json and type(Json.decode) == "function") then
    return nil, "the engine's JSON helper is unavailable"
  end
  local okD, data = pcall(Json.decode, raw)
  if not okD or type(data) ~= "table" then return nil, "could not read GitHub's release list" end
  for _, r in ipairs(data) do
    local tag = tostring(r.tag_name or r.name or ""):gsub("^[vV]", "")
    if tag == tostring(src.version) then
      for _, a in ipairs(r.assets or {}) do
        if tostring(a.name or ""):lower():sub(-4) == ".zip" and a.browser_download_url then
          return { version = src.version, zip = { url = a.browser_download_url, size = tonumber(a.size) or 0 } }
        end
      end
      return nil, "release v" .. tostring(src.version) .. " has no ZIP asset"
    end
  end
  return nil, "asset release v" .. tostring(src.version) .. " was not found"
end
I._pickRelease = pickRelease

local function pumpApi()
  local okF, Fetch = pcall(require, "src.net.Fetch")
  if not okF or not Fetch then return fail("the engine's downloader is unavailable") end
  local s = Fetch.poll(st.job)
  if s.status == "pending" then return end
  local job = st.job
  st.job = nil
  Fetch.release(job)
  if s.status ~= "ok" then return fail("could not read the release list: " .. tostring(s.err or "download failed")) end
  local raw = readSaveFile(I.config.apiTemp)
  pcall(st.fs.remove, I.config.apiTemp)
  if not raw then return fail("the release list was empty") end
  local release, err = pickRelease(raw, source())
  if not release then return fail(err) end
  st.apiPhase = false
  beginDownload(release)
end

local function pumpRelease()
  if st.apiPhase then return pumpApi() end
  local okM, ModUpdate = pcall(require, "src.mods.ModUpdate")
  if not okM or not ModUpdate then return fail("the engine's release checker is unavailable") end
  local done, releases, err = ModUpdate.pumpFetchReleases(st.releaseHandle)
  if not done then return end
  st.releaseHandle = nil
  if not releases then return fail(err or "could not check the asset release") end
  local src = source()
  for _, rel in ipairs(releases) do
    if tostring(rel.version or "") == src.version and rel.zip and rel.zip.url then
      return beginDownload(rel)
    end
  end
  fail("asset release v" .. tostring(src.version) .. " was not found")
end

local function pumpDownload()
  local okF, Fetch = pcall(require, "src.net.Fetch")
  if not okF or not Fetch then return fail("the engine's streaming downloader is unavailable") end
  local fs = st.fs
  local function sizeNow()
    if not fs then return end
    local ok, info = pcall(fs.getInfo, I.config.tempName, "file")
    if ok and info then st.bytes = tonumber(info.size) or st.bytes end
  end
  sizeNow()
  local s = Fetch.poll(st.job)
  if s.status == "pending" then
    if st.total > 0 and tonumber(s.progress) and tonumber(s.progress) > 0 then
      st.bytes = math.max(st.bytes or 0, st.total * tonumber(s.progress))
    end
    return
  end
  local job = st.job
  st.job = nil
  Fetch.release(job)
  if s.status ~= "ok" then return fail(s.err or "the ZIP download failed") end
  sizeNow()
  if (st.bytes or 0) <= 0 then return fail("the download finished but wrote no file") end
  if st.total > 0 and st.bytes ~= st.total then
    return fail(("the ZIP is incomplete (%d/%d bytes)"):format(st.bytes, st.total))
  end
  beginExtraction()
end

function I._startSource(index)
  st.srcIndex = index
  st.zipName = nil
  st.apiPhase = false
  local p = probe()
  if p.releases then
    -- the engine's own release checker (what Kanto in Motion uses)
    local ModUpdate = require("src.mods.ModUpdate")
    st.releaseHandle = ModUpdate.beginFetchReleases(source().repo, nil, { force = true })
    st.state = "checking"
  elseif p.download then
    -- older engine builds: read GitHub's release list with the streaming
    -- downloader and pick the asset ourselves
    local Fetch = require("src.net.Fetch")
    pcall(st.fs.remove, I.config.apiTemp)
    st.job = Fetch.download("https://api.github.com/repos/" .. source().repo .. "/releases?per_page=30",
      I.config.apiTemp, { userAgent = source().userAgent or "terrarium-hd-sheets", maxSeconds = 120 })
    if not st.job then return fail("could not start the release lookup") end
    st.apiPhase = true
    st.state = "checking"
  else
    fail(diagnosis("this engine build has no usable release downloader"))
  end
end

-- ------- public --------------------------------------------------------------

function I.start()
  if st.state == "checking" or st.state == "downloading" or st.state == "extracting" then return false end
  st.error = nil
  if not cacheOk() then
    st.state, st.error = "error", "this build does not provide mod.cache"
    return false
  end
  local fs, fsErr = rawFilesystem()
  if not fs then st.state, st.error = "error", fsErr; return false end
  st.fs = fs
  cleanup()
  st.counts = { written = 0, existing = 0, low = 0, high = 0, over = 0, other = 0 }
  st.files, st.pos, st.total, st.bytes = {}, 1, 0, 0
  if #I.config.sources == 0 then st.state, st.error = "error", "no sources configured"; return false end
  local okI, got = pcall(fs.getInfo, I.config.localZip, "file")
  if okI and got and (tonumber(got.size) or 0) > 22 then
    -- manual route: install from the ZIP the user placed in the save folder
    st.srcIndex = 1
    st.zipName = I.config.localZip
    log("info", "HD sheets: installing from local ZIP '%s'", I.config.localZip)
    beginExtraction()
    return st.state ~= "error"
  end
  I._startSource(1)
  return st.state ~= "error"
end

function I.cancel()
  if st.state == "checking" or st.state == "downloading" then
    cancelNetwork()
    st.releaseHandle = nil
    st.apiPhase = false
    pcall(function() if st.fs then st.fs.remove(I.config.apiTemp) end end)
    cleanup()
    st.state, st.error = "idle", nil
    return true
  end
  return false
end

function I.update()
  local s = st.state
  if s == "idle" or s == "done" or s == "error" then return end
  local ok, err = pcall(function()
    if s == "checking" then pumpRelease()
    elseif s == "downloading" then pumpDownload()
    elseif s == "extracting" then pumpExtraction()
    end
  end)
  if not ok then fail(err) end
end

function I.active()
  return st.state == "checking" or st.state == "downloading" or st.state == "extracting"
end

-- Dex with BOTH a front and a back normal sheet installed, split at the
-- Colosseum boundary. Cached; invalidated when an install finishes.
function I.coverage()
  if st.coverage then return st.coverage end
  local hd = HD()
  local c = { low = 0, high = 0, total = 0 }
  if hd then
    for dex = 1, maxDex() do
      if hd.available(dex, "front", false) and hd.available(dex, "back", false) then
        if dex <= lowMax() then c.low = c.low + 1 else c.high = c.high + 1 end
      end
    end
  end
  c.total = c.low + c.high
  st.coverage = c
  return c
end

function I.invalidate() st.coverage = nil end

function I.status()
  return {
    state = st.state, error = st.error, source = st.srcIndex,
    downloaded = st.bytes, total = st.total,
    extracted = st.pos - 1, queued = #st.files, counts = st.counts,
  }
end

-- Short text for the OPTIONS-menu value column.
function I.statusText()
  local s = st.state
  if s == "checking" then return "CHECKING" end
  if s == "downloading" then
    if st.total > 0 then return ("DOWNLOAD %d%%"):format(math.floor(100 * (st.bytes or 0) / st.total)) end
    return "DOWNLOADING"
  end
  if s == "extracting" then return ("UNPACK %d/%d"):format(st.pos - 1, #st.files) end
  if s == "error" then return "ERROR RETRY" end
  local c = I.coverage()
  if c.total == 0 then return "GET SHEETS" end
  return ("%d/%d"):format(c.total, maxDex())
end

function I.lastError() return st.error end

function I.row()
  return {
    id = I.ID,
    label = I.LABEL,
    value = function() return I.statusText() end,
    step = function()
      if I.active() then
        I.cancel()
      else
        pcall(I.start)
      end
      return true
    end,
  }
end

return I
