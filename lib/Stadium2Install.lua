-- STADIUM 2 battles: finding the ROM, and building the models out of it once.
--
-- Similar to StadiumInstall but for Pokemon Stadium 2 (251 Pokemon)
--
-- Uses EngineCompat for sandbox-safe file access (same as VOXEL_ULTIMATE)

local V = ...

local Stadium2Install = {}
local Compat = V.require("EngineCompat")

-- Where a ROM is looked for, and where the built packs are kept.
Stadium2Install.ROM_DIR = "baseroms"
Stadium2Install.DIR = "dramatic_shape"
Stadium2Install.MARKER = Stadium2Install.DIR .. "/pack2.info"

-- Format for Stadium 2 packs. DSM5 carries the real 251-move dispatch table
-- (StadiumRom2.lua's Rom:battleRows/Rom.PACK_MAGIC); DSM3 was the old
-- generic-clip shape borrowed from Stadium 1's 165-move format.
Stadium2Install.FORMAT = "DSM4"

-- Bumped alongside FORMAT so existing players' pack2.info marker reads as
-- stale (old format/rev, see readyCache below) and rebuilds instead of the
-- old DSM3 packs being read as if they were the new shape.
Stadium2Install.REV = 2

-- Stadium 2 has 251 Pokemon
Stadium2Install.COUNT = 251

-- Build status tracking
local status = { state = "idle", done = 0, total = Stadium2Install.COUNT }
Stadium2Install.status = status

-- Job object for per-frame building
local job = nil

-- Named ROM files for Stadium 2
local NAMED = {
  Stadium2Install.ROM_DIR .. "/stadium2.z64",
  Stadium2Install.ROM_DIR .. "/stadium2.n64",
  Stadium2Install.ROM_DIR .. "/stadium2.v64",
}

local function fs()
  return Compat.fs()
end

local function isFile(path)
  local f = fs()
  if not (f and f.getInfo) then return false end
  local ok, info = pcall(f.getInfo, path, "file")
  return (ok and info) and true or false
end

-- The ROM's path on the PhysFS read path, or nil.
function Stadium2Install.romPath()
  local f = fs()
  if not f then return nil end
  for _, path in ipairs(NAMED) do
    if isFile(path) then return path end
  end
  local ok, items = pcall(f.getDirectoryItems, Stadium2Install.ROM_DIR)
  if ok and items then
    table.sort(items)
    for _, name in ipairs(items) do
      if name:lower():match("stadium[._-]?2%.[nvz]64$") or name:lower():match("pokemon[._-]?stadium[._-]?2%.[nvz]64$") then
        local path = Stadium2Install.ROM_DIR .. "/" .. name
        if isFile(path) then return path end
      end
    end
  end
  return nil
end

function Stadium2Install.romPresent()
  return Stadium2Install.romPath() ~= nil
end

function Stadium2Install.ensureRomDir()
  local f = fs()
  if not (f and f.createDirectory) then return false end
  local ok = pcall(f.createDirectory, Stadium2Install.ROM_DIR)
  return ok and true or false
end

function Stadium2Install.romHint()
  Stadium2Install.ensureRomDir()
  local f = fs()
  local base = (f and f.getSaveDirectory and select(2, pcall(f.getSaveDirectory)))
  if type(base) ~= "string" then base = "the game folder" end
  return base .. "/" .. Stadium2Install.ROM_DIR
end

function Stadium2Install.forget()
  readyCache = nil
end

function Stadium2Install.romHintFile()
  return Stadium2Install.romHint() .. "/stadium2.z64"
end

-- Marker handling
local function readMarker()
  local f = fs()
  if not (f and isFile(Stadium2Install.MARKER)) then return nil end
  local ok, text = pcall(f.read, Stadium2Install.MARKER)
  if not (ok and type(text) == "string") then return nil end
  local format, count, md5, rev = text:match("^(%S+)%s+(%d+)%s*(%S*)%s*(%S*)")
  if not format then return nil end
  return { format = format, count = tonumber(count), md5 = md5,
           rev = tonumber(rev) }
end

local readyCache = nil

function Stadium2Install.ready()
  if readyCache ~= nil then return readyCache end
  local m = readMarker()
  readyCache = (m ~= nil and m.format == Stadium2Install.FORMAT
                and m.count == Stadium2Install.COUNT
                and m.rev == Stadium2Install.REV) and true or false
  return readyCache
end

function Stadium2Install.available()
  if Stadium2Install.ready() then return true end
  return Stadium2Install.romPresent()
end

-- Whether there is work to do: a ROM to build from, and no CURRENT set.
function Stadium2Install.pending()
  if Stadium2Install.available() then return false end
  return Stadium2Install.romPresent()
end

-- Begin build from ROM bytes (called by ROM picker)
function Stadium2Install.beginFrom(bytes, label)
  local f = fs()
  if not f then return false, "no filesystem" end
  if type(bytes) ~= "string" or #bytes == 0 then return false, "empty file" end

  local StadiumBuild = V.require("StadiumBuild")
  local StadiumRom2 = V.require("StadiumRom2")

  local rom, err = StadiumRom2.open(bytes)
  if not rom then
    return false, "Gold/Silver/Crystal needs a Pokemon Stadium 2 ROM: " .. tostring(err)
  end

  if not rom:isExpectedUS() then
    V.mod.log:warn("stadium2: %s is md5 %s -- canonical Pokemon Stadium 2 US "
                   .. "is md5 %s. The archive layout will still be validated "
                   .. "before a build is started.",
                   tostring(label or "the ROM"), tostring(rom:md5()),
                   tostring(StadiumRom2.US_MD5))
  end

  local models = rom:modelCount()
  if not (models and models >= Stadium2Install.COUNT) then
    return false, "needs Pokemon Stadium 2 with the full 251-Pokemon model archive"
  end

  pcall(f.createDirectory, Stadium2Install.DIR)

  local function writePack(species, bytes)
    local packPath = ("%s/%03d.dsm"):format(Stadium2Install.DIR, species)
    local ok, err = f.write(packPath, bytes)
    if not ok then return false, tostring(err) end
    return true
  end

  job = StadiumBuild.job(rom, writePack, Stadium2Install.COUNT)
  job.md5 = rom:md5()
  job.sourceGame = "Pokemon Stadium 2"
  status.state = "building"
  status.done = 0
  status.total = job.total
  status.error = nil
  readyCache = nil

  return true
end

-- One species. Returns true while there is more to do.
function Stadium2Install.step()
  if not job then return false end
  local more = job:step()
  status.done = job.done
  status.species = job.species
  if job.error then
    status.state = "failed"
    status.error = job.error
    job = nil
    return false
  end
  if not more then
    local f = fs()
    -- `job.total > 0` as well as "nothing failed", because a job with nothing
    -- IN it satisfies the second on its own -- and the marker this writes is
    -- what makes a set count as installed, so it must never be written for a
    -- build that did not happen. beginFrom refuses such a ROM outright; this
    -- is the same rule stated where the consequence is.
    local wrote = #job.failed == 0 and job.total > 0
    if wrote and f then
      pcall(f.write, Stadium2Install.MARKER,
            ("%s %d %s %d\n"):format(Stadium2Install.FORMAT, job.total,
                                     tostring(job.md5 or ""),
                                     Stadium2Install.REV))
      readyCache = nil
    end
    if not wrote then
      status.state = "failed"
      -- EVERY species failing is not a bad build, it is the wrong file: the
      -- offsets the reader walks are Pokemon Stadium's, so a different game
      -- -- or the Game Boy cartridge the player already imported once, which
      -- is the mistake a file picker invites -- misses on all 251 rather than
      -- on a few. Worth telling apart, because "0 of 251 models were built"
      -- reads as a broken mod and this reads as a wrong click.
      if #job.failed >= job.total then
        status.error = "needs a compatible Pokemon Stadium 2 ROM / GS model+animation archives"
      else
        status.error = ("%d of %d models could not be built")
                       :format(#job.failed, job.total)
      end
    else
      status.state = "done"
    end
    job = nil
    return false
  end
  return true
end

function Stadium2Install.cancel()
  job = nil
  status.state = "idle"
end

return Stadium2Install