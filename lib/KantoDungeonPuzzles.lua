-- v0.3.85 physical dungeon-puzzle parity for the Yellow Kanto excursion.
--
-- Story-free Kanto intentionally does not execute Yellow map ASM, but these
-- scripts are physical map mechanics rather than story state:
--   * Victory Road boulders latch floor switches and open authored gate blocks.
--   * Pokemon Mansion statues toggle one shared switch that swaps alternating
--     sets of door blocks on all four floors.
-- Keep the data here so TwinRegionWorld can apply the same rules both before a
-- map is meshed and immediately after a live switch/boulder interaction.

local M = { VERSION = "0.3.85" }

M.MANSION_EVENT = "EVENT_MANSION_SWITCH_ON"
M.MANSION_RESET_MAP = "CINNABAR_ISLAND"

-- Hidden-event coordinates from data/events/hidden_events.asm.  Yellow only
-- invokes these while the player faces UP toward the statue.
M.MANSION_SWITCHES = {
  POKEMON_MANSION_1F = { [5 * 1024 + 2] = true },
  POKEMON_MANSION_2F = { [11 * 1024 + 2] = true },
  POKEMON_MANSION_3F = { [5 * 1024 + 10] = true },
  POKEMON_MANSION_B1F = {
    [3 * 1024 + 20] = true,
    [25 * 1024 + 18] = true,
  },
}

-- ReplaceTileBlock's `lb bc, y, x`: store x as bx and y as by.
-- Every row names the exact block for switch OFF and ON, so re-entering a
-- floor always reconstructs the retail state even after this process already
-- mutated the shared map definition earlier in the session.
M.MANSION_BLOCKS = {
  POKEMON_MANSION_1F = {
    { bx=12, by=6,  off=0x0e, on=0x2d },
    { bx=8,  by=3,  off=0x2d, on=0x0e },
    { bx=10, by=8,  off=0x2d, on=0x0e },
    { bx=13, by=13, off=0x2d, on=0x0e },
  },
  POKEMON_MANSION_2F = {
    { bx=4, by=2,  off=0x0e, on=0x5f },
    { bx=9, by=4,  off=0x54, on=0x0e },
    { bx=3, by=11, off=0x5f, on=0x0e },
  },
  POKEMON_MANSION_3F = {
    { bx=7, by=2, off=0x0e, on=0x5f },
    { bx=7, by=5, off=0x5f, on=0x0e },
  },
  POKEMON_MANSION_B1F = {
    { bx=13, by=8,  off=0x0e, on=0x2d },
    { bx=6,  by=11, off=0x0e, on=0x5f },
    { bx=4,  by=3,  off=0x5f, on=0x0e },
    { bx=8,  by=8,  off=0x54, on=0x0e },
  },
}

M.VICTORY_SWITCHES = {
  VICTORY_ROAD_1F = {
    [13 * 1024 + 17] = {
      event="EVENT_VICTORY_ROAD_1_BOULDER_ON_SWITCH",
      block={ bx=4, by=6, open=0x1d },
    },
  },
  VICTORY_ROAD_2F = {
    [16 * 1024 + 1] = {
      event="EVENT_VICTORY_ROAD_2_BOULDER_ON_SWITCH1",
      block={ bx=3, by=4, open=0x15 },
    },
    [16 * 1024 + 9] = {
      event="EVENT_VICTORY_ROAD_2_BOULDER_ON_SWITCH2",
      block={ bx=11, by=7, open=0x1d },
    },
  },
  VICTORY_ROAD_3F = {
    [5 * 1024 + 3] = {
      event="EVENT_VICTORY_ROAD_3_BOULDER_ON_SWITCH1",
      block={ bx=3, by=5, open=0x1d },
    },
  },
}

-- Victory Road 3F's fourth boulder can be pushed into the physical hole at
-- (23,15).  Yellow hides that 3F object and reveals the authored 2F boulder at
-- (23,16), which can then be pushed onto either 2F floor switch.
M.VICTORY_BOULDER_HOLE = {
  map="VICTORY_ROAD_3F", x=23, y=15,
  event="EVENT_VICTORY_ROAD_3_BOULDER_ON_SWITCH2",
  destMap="VICTORY_ROAD_2F", destX=23, destY=16,
}

function M.key(x, y)
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return nil end
  return math.floor(y) * 1024 + math.floor(x)
end

function M.mansionSwitchAt(mapId, x, y, facing)
  if tostring(facing or "") ~= "up" then return false end
  local rows = M.MANSION_SWITCHES[tostring(mapId or "")]
  local key = M.key(x, y)
  return type(rows) == "table" and key and rows[key] == true or false
end

function M.mansionBlocks(mapId, on)
  local rows = M.MANSION_BLOCKS[tostring(mapId or "")]
  if type(rows) ~= "table" then return nil end
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = { bx=row.bx, by=row.by, block=on and row.on or row.off }
  end
  return out
end

function M.victorySwitchAt(mapId, x, y)
  local rows = M.VICTORY_SWITCHES[tostring(mapId or "")]
  local key = M.key(x, y)
  return type(rows) == "table" and key and rows[key] or nil
end

function M.victorySwitchRows(mapId)
  local rows = M.VICTORY_SWITCHES[tostring(mapId or "")]
  if type(rows) ~= "table" then return nil end
  local out = {}
  for _, row in pairs(rows) do out[#out + 1] = row end
  table.sort(out, function(a, b)
    local aa, bb = a.block or {}, b.block or {}
    if aa.by == bb.by then return (aa.bx or 0) < (bb.bx or 0) end
    return (aa.by or 0) < (bb.by or 0)
  end)
  return out
end

function M.victoryBoulderHole(mapId, x, y)
  local h = M.VICTORY_BOULDER_HOLE
  return tostring(mapId or "") == h.map
    and tonumber(x) == h.x and tonumber(y) == h.y and h or nil
end

return M
