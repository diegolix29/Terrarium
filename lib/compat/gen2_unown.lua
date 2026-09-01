-- Compatibility shim for STADIUM2_IMPORTER's src.core.gen2.Unown dependency
-- This module provides the Unown letter calculation API that STADIUM2_IMPORTER expects
-- using the base engine's Sprites.formIndex logic

local Sprites = require("src.pokemon.Sprites")

local Unown = {}

-- Extract middle two bits of a DV (GetUnownLetter logic from Gen 2)
local function mid2(dv)
  return math.floor((dv or 0) / 2) % 4
end

-- Calculate Unown letter index (1-26, where 1=A) from DVs
-- Matches the Gen 2 ROM routine at 20:$5749
function Unown.letterFromDVs(dvs)
  if type(dvs) ~= "table" then return 1 end
  local packed = mid2(dvs.attack) * 64 + mid2(dvs.defense) * 16
    + mid2(dvs.speed) * 4 + mid2(dvs.special)
  local index = math.floor(packed / 10) + 1
  if index < 1 or index > 26 then return 1 end
  return index
end

-- Get Unown letter index from a pre-calculated unownLetter field
function Unown.index(letter)
  if type(letter) == "number" then
    if letter >= 1 and letter <= 26 then return letter end
    return 1
  end
  if type(letter) == "string" then
    local upper = letter:upper()
    local byte = string.byte(upper)
    if byte >= 65 and byte <= 90 then
      return byte - 64 -- A=1, B=2, ..., Z=26
    end
  end
  return 1
end

-- Convert letter index to letter name
function Unown.name(index)
  index = tonumber(index) or 1
  if index < 1 or index > 26 then index = 1 end
  return string.char(64 + index) -- 1=A, 2=B, ..., 26=Z
end

return Unown
