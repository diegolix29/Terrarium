-- Pokemon Stadium 2 / Pokemon Stadium GS ROM reader.
--
-- Unlike Stadium 1, Stadium 2 keeps battle model FRAGMENTs and their skeletal
-- animation banks in two parallel resource archives.  The public reverse-
-- engineering layout used here is:
--
--   0x027ED000  battle Pokemon model archive (282 entries)
--   0x02D7D000  battle animation-bank archive (282 entries)
--
-- Archive entry N is paired with animation entry N.  Entry 0 is a non-roster
-- slot; National Dex species 1..251 live at archive entries 1..251.  The mod
-- never ships any bytes from either game -- the player selects their own ROM
-- and this reader builds local DSM packs in the save directory.

local V = ...

local StadiumRom = V.require("StadiumRom")
local StadiumFragment = V.require("StadiumFragment")

local StadiumRom2 = {}

StadiumRom2.MODEL_ARCHIVE = 0x027ED000
StadiumRom2.ANIM_ARCHIVE  = 0x02D7D000
StadiumRom2.RESOURCE_TABLE = 0x00437620
StadiumRom2.ARCHIVE_COUNT = 282
StadiumRom2.N_POKEMON = 251

-- Canonical US image published by pret/pokestadiumgs.
StadiumRom2.US_MD5 = "1561c75d11cedf356a8ddb1a4a5f9d5d"
StadiumRom2.JP_MD5 = "a17aadcc962393d476edc321e59c504b"

local byte = string.byte
local sub = string.sub

local Rom = {}
Rom.__index = Rom

local function be32(s, o)
  local a, b, c, d = byte(s, o + 1, o + 4)
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function archiveInString(data, off)
  off = off or 0
  if type(data) ~= "string" or off < 0 or off + 0x10 > #data then return nil end
  local count = be32(data, off + 0x0C)
  if not count or count <= 0 or count >= 4096 then return nil end
  if off + 0x10 + count * 0x10 > #data then return nil end

  local out = {}
  for i = 0, count - 1 do
    local rec = off + 0x10 + i * 0x10
    local rel = be32(data, rec)
    local size = be32(data, rec + 4)
    if not rel or not size or rel < 0 or size < 0 then return nil end
    local start = off + rel
    if start < off or start + size > #data then return nil end
    out[i + 1] = { start = start, size = size, index = i }
  end
  return out
end

function StadiumRom2.open(bytes)
  local data = StadiumRom.normalise(bytes)
  if not data then return nil, "not an N64 ROM (bad magic)" end
  local self = setmetatable({ data = data }, Rom)

  local models = self:archive(StadiumRom2.MODEL_ARCHIVE)
  local anims = self:archive(StadiumRom2.ANIM_ARCHIVE)
  -- Relax validation: check if there are at least enough entries for Pokemon
  -- Some ROM versions may have different archive counts
  if not models or #models < StadiumRom2.N_POKEMON + 1
      or not anims or #anims < StadiumRom2.N_POKEMON + 1 then
    return nil, ("not a compatible Pokemon Stadium 2 ROM (found %d model entries, %d animation entries, need at least %d)"):format(
      models and #models or 0, anims and #anims or 0, StadiumRom2.N_POKEMON + 1)
  end
  return self
end

function Rom:u8(o)
  return byte(self.data, o + 1)
end

function Rom:u32(o)
  return be32(self.data, o) or 0
end

function Rom:archive(off)
  return archiveInString(self.data, off)
end

function Rom:title()
  local raw = sub(self.data, 0x20 + 1, 0x20 + 20)
  return (raw:gsub("%z", ""):gsub("%s+$", ""))
end

function Rom:md5()
  if self.hash ~= nil then return self.hash or nil end
  local ok, hex = pcall(function()
    local digest = love.data.hash("md5", self.data)
    if type(digest) == "userdata" and digest.getString then
      digest = digest:getString()
    end
    return love.data.encode("string", "hex", digest)
  end)
  self.hash = (ok and hex) or false
  return self.hash or nil
end

function Rom:isExpectedUS()
  local hex = self:md5()
  return hex == nil or hex == StadiumRom2.US_MD5
end

function Rom:isKnownRevision()
  local hex = self:md5()
  return hex == nil or hex == StadiumRom2.US_MD5 or hex == StadiumRom2.JP_MD5
end

function Rom:models()
  if not self.modelDir then
    self.modelDir = self:archive(StadiumRom2.MODEL_ARCHIVE) or {}
  end
  return self.modelDir
end

function Rom:animationBanks()
  if not self.animDir then
    self.animDir = self:archive(StadiumRom2.ANIM_ARCHIVE) or {}
  end
  return self.animDir
end

-- There are 282 archive records, but only National Dex 1..251 are installed.
-- Stadium 2 indexes those Pokemon by their actual species number, so build
-- fileno 0 (Bulbasaur) maps to archive record 1, not record 0.
function Rom:modelCount()
  local n = #self:models() - 1
  return n > 0 and n or 0
end

local function rosterRecord(dir, fileno)
  if type(fileno) ~= "number" or fileno < 0 then return nil end
  -- fileno 0 (Bulbasaur) maps to archive index 1, which is dir[2] in 1-based Lua
  -- So we need: dir[fileno + 2]
  return dir[fileno + 2]
end

function Rom:model(fileno)
  local rec = rosterRecord(self:models(), fileno)
  if not rec then return nil end
  local blob = sub(self.data, rec.start + 1, rec.start + rec.size)
  -- Current US GS model entries are direct FRAGMENT resources, but accepting
  -- Stadium's PERS-SZP/Yay0 wrapper here costs nothing and makes the reader
  -- tolerant of resource variants that use it.
  return StadiumRom.decompress(blob)
end

local function bankPayloads(romData, rec)
  if not rec then return nil, "animation bank is missing" end
  local raw = sub(romData, rec.start + 1, rec.start + rec.size)
  raw = StadiumRom.decompress(raw)
  local dir = archiveInString(raw, 0)
  if not dir then return nil, "animation bank has an invalid archive header" end
  local out = {}
  for i = 1, #dir do
    local r = dir[i]
    out[i] = sub(raw, r.start + 1, r.start + r.size)
  end
  return out
end

function Rom:animationPayloads(fileno)
  local rec = rosterRecord(self:animationBanks(), fileno)
  return bankPayloads(self.data, rec)
end

-- StadiumBuild calls this after the model FRAGMENT has been decoded.  The GS
-- model supplies Bone.Channel, while the paired external bank supplies the
-- actual skeletal clips.  StadiumFragment owns the sampling math so Stadium 1
-- and Stadium 2 keep one implementation of the packed/hermite track formats.
function Rom:attachAnimations(data, fileno)
  local expectedSpecies = fileno + 1
  if tonumber(data and data.species) ~= expectedSpecies then
    return false, ("Stadium 2 archive mapping mismatch: entry %d decoded as species %s (expected %d)")
      :format(expectedSpecies, tostring(data and data.species), expectedSpecies)
  end
  local payloads, err = self:animationPayloads(fileno)
  if not payloads then return false, err end
  local anims, aerr = StadiumFragment.decodeGSAnimations(payloads, data.bones)
  if not anims or #anims == 0 then
    return false, aerr or "no Stadium 2 skeletal animations decoded"
  end
  data.anims = anims
  self._animCounts = self._animCounts or {}
  self._animCounts[data.species] = #anims
  return true
end

-- Stadium 2's real per-move battle routing table (which of the 165 moves
-- plays which clip) has not been reverse engineered. What HAS been reverse
-- engineered -- and is already decoded above in attachAnimations -- is each
-- species' own ordered bank of named clips (idle, attack, faint, entrance,
-- ...), same as Stadium 1's clip ordering convention. Rather than pin every
-- slot to clip 0 (which only ever shows idle motion), every move shares the
-- species' one general-purpose "attack" clip, and the named context slots
-- point at their real counterparts when the species has that many clips.
-- This is the same generic-routing approach other Stadium 2 ports use until
-- a real move-by-move table exists; it can be replaced without changing the
-- DSM format or importer UI. attachAnimations always runs first (see
-- StadiumBuild.species), so self._animCounts[species] is already populated.
function Rom:battleRows(species)
  local n = (self._animCounts and self._animCounts[species]) or 1
  local idle     = 0
  local attack   = n > 1 and 1 or idle
  local faint    = n > 2 and 2 or idle
  local entrance = n > 3 and 3 or idle

  local rows = {}
  for e = 0, 184 do rows[e] = { idle, -1 } end
  for m = 0, StadiumRom.N_MOVES - 1 do rows[m] = { attack, -1 } end

  -- Context slots start at 165, in StadiumBuild.CONTEXTS order: idle,
  -- attack_default, faint, entrance, six reaction slots, struggle, idle_alt,
  -- faint_alt, flinch, four more reaction slots, entrance_alt, idle_return.
  rows[165] = { idle, 0 }      -- idle
  rows[166] = { attack, 0 }    -- attack_default
  rows[167] = { faint, 0 }     -- faint
  rows[168] = { entrance, 0 }  -- entrance
  rows[176] = { idle, 0 }      -- idle_alt
  rows[177] = { faint, 0 }     -- faint_alt
  rows[183] = { entrance, 0 }  -- entrance_alt
  rows[184] = { idle, 0 }      -- idle_return

  rows.n = 185
  return rows
end

-- Read the rare colour (shiny) metadata for a species from Stadium 2 ROM.
-- The rare colour operation is stored as 4 bytes: hue (10.6 deg), saturation, lightness.
-- FF FF FF FF indicates a special texture (not recoloured).
function Rom:rareColour(species)
  if type(species) ~= "number" or species < 1 or species > StadiumRom2.N_POKEMON then
    return nil
  end

  -- Stadium 2 stores rare colour data in the resource table
  -- Offset calculation: base + (species - 1) * 4
  local offset = StadiumRom2.RESOURCE_TABLE + (species - 1) * 4
  if offset + 4 > #self.data then
    return nil
  end

  local Stadium2Palette = V.require("Stadium2Palette")
  return Stadium2Palette.decodeRare(self.data, offset)
end

return StadiumRom2