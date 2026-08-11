-- v0.3.84 cross-generation Kanto quest/item semantics.
--
-- Yellow's item namespace cannot be copied blindly into Gold: several Gen-1
-- key items either do not exist in GSC or collide with unrelated Gen-2 story
-- keys (CARD_KEY is the important example).  Keep those Kanto-local, while
-- ordinary items pass through and TM/HM pickups resolve by the MOVE they teach
-- rather than by the machine number/name.

local Items = { VERSION = "0.3.91" }

Items.LOCAL_ONLY = {
  CARD_KEY = true,
  SECRET_KEY = true,
  DOME_FOSSIL = true,
  HELIX_FOSSIL = true,
  OLD_AMBER = true,
  SILPH_SCOPE = true,
  POKE_FLUTE = true,
  LIFT_KEY = true,
  -- Yellow Safari Zone quest key; Gold/Silver has no equivalent item.
  GOLD_TEETH = true,
  -- Gold also has an S.S. TICKET for the S.S. Aqua. Yellow's ticket must
  -- never unlock or contaminate that native Gen-2 story key.
  S_S_TICKET = true,
}

Items.FOSSILS = {
  DOME_FOSSIL = { item = "DOME_FOSSIL", species = "KABUTO", level = 30,
    event = "EVENT_GOT_DOME_FOSSIL", display = "DOME FOSSIL" },
  HELIX_FOSSIL = { item = "HELIX_FOSSIL", species = "OMANYTE", level = 30,
    event = "EVENT_GOT_HELIX_FOSSIL", display = "HELIX FOSSIL" },
  OLD_AMBER = { item = "OLD_AMBER", species = "AERODACTYL", level = 30,
    event = "EVENT_GOT_OLD_AMBER", display = "OLD AMBER" },
}

Items.MT_MOON = {
  map = "MT_MOON_B2F",
  prerequisite = "EVENT_BEAT_MT_MOON_EXIT_SUPER_NERD",
  objects = {
    TEXT_MTMOONB2F_DOME_FOSSIL = "DOME_FOSSIL",
    TEXT_MTMOONB2F_HELIX_FOSSIL = "HELIX_FOSSIL",
  },
}

Items.FOSSIL_LAB = {
  map = "CINNABAR_LAB_FOSSIL_ROOM",
  scientist = "TEXT_CINNABARLABFOSSILROOM_SCIENTIST1",
}

Items.ROCKET_HIDEOUT = {
  map = "ROCKET_HIDEOUT_B4F",
  droppedLiftKeyEvent = "EVENT_ROCKET_DROPPED_LIFT_KEY",
  giovanniEvent = "EVENT_BEAT_ROCKET_HIDEOUT_GIOVANNI",
  liftKeyText = "TEXT_ROCKETHIDEOUTB4F_LIFT_KEY",
  silphScopeText = "TEXT_ROCKETHIDEOUTB4F_SILPH_SCOPE",
  rocketText = "TEXT_ROCKETHIDEOUTB4F_ROCKET",
  giovanniText = "TEXT_ROCKETHIDEOUTB4F_GIOVANNI",
  duoEvent = "EVENT_BEAT_ROCKET_HIDEOUT_4_JESSIE_JAMES",
  duoY = 14, duoX = { [24] = true, [25] = true }, duoParty = 43,
}

Items.ROCKET_ELEVATOR = {
  map = "ROCKET_HIDEOUT_ELEVATOR",
  text = "TEXT_ROCKETHIDEOUTELEVATOR",
  floors = {
    { label = "B1F", map = "ROCKET_HIDEOUT_B1F", warp = 4 },
    { label = "B2F", map = "ROCKET_HIDEOUT_B2F", warp = 4 },
    { label = "B4F", map = "ROCKET_HIDEOUT_B4F", warp = 2 },
  },
}

Items.POKEMON_TOWER = {
  marowakMap = "POKEMON_TOWER_6F",
  marowakX = 10, marowakY = 16,
  marowakEvent = "EVENT_BEAT_GHOST_MAROWAK",
  fujiMap = "POKEMON_TOWER_7F",
  fujiText = "TEXT_POKEMONTOWER7F_MR_FUJI",
  rescueEvent = "EVENT_RESCUED_MR_FUJI",
  rocketEvent = "EVENT_BEAT_POKEMONTOWER_7_JESSIE_JAMES",
  rocketY = 12, rocketX = { [10] = true, [11] = true }, rocketParty = 44,
  rocketTexts = {
    TEXT_POKEMONTOWER7F_JESSIE = true,
    TEXT_POKEMONTOWER7F_JAMES = true,
  },
  fujiHouseMap = "MR_FUJIS_HOUSE",
  fujiHouseText = "TEXT_MRFUJISHOUSE_MR_FUJI",
  fluteEvent = "EVENT_GOT_POKE_FLUTE",
}

Items.SNORLAX = {
  ROUTE_12 = { text = "TEXT_ROUTE12_SNORLAX", species = "SNORLAX", level = 30,
    event = "EVENT_BEAT_ROUTE12_SNORLAX" },
  ROUTE_16 = { text = "TEXT_ROUTE16_SNORLAX", species = "SNORLAX", level = 30,
    event = "EVENT_BEAT_ROUTE16_SNORLAX" },
}

Items.STEP_GATES = {
  CINNABAR_ISLAND = {
    { x = 18, y = 4, dir = "up", item = "SECRET_KEY",
      text = "TEXT_CINNABARISLAND_DOOR_IS_LOCKED" },
  },
}

function Items.localEvent(itemId)
  return "KANTO_ITEM_" .. tostring(itemId or "")
end

function Items.isLocalOnly(itemId)
  return Items.LOCAL_ONLY[tostring(itemId or "")] == true
end

function Items.fossil(itemId)
  return Items.FOSSILS[tostring(itemId or "")]
end

function Items.mtMoonFossil(textConst)
  return Items.MT_MOON.objects[tostring(textConst or "")]
end

function Items.stepGate(mapId, x, y, dir)
  local rows = Items.STEP_GATES[tostring(mapId or "")]
  if type(rows) ~= "table" then return nil end
  x, y, dir = tonumber(x), tonumber(y), tostring(dir or "")
  for _, row in ipairs(rows) do
    if tonumber(row.x) == x and tonumber(row.y) == y
        and tostring(row.dir or "") == dir then
      return row
    end
  end
  return nil
end

local function machineMove(def)
  if type(def) ~= "table" then return nil end
  if def.teaches then return tostring(def.teaches) end
  local machine = def.machine
  return type(machine) == "table" and machine.move and tostring(machine.move) or nil
end
Items.machineMove = machineMove

-- Resolve a Yellow item into the active Gold item table.  Same-id ordinary
-- items win.  Gen-1 machines that changed numbers/names in Gen 2 are matched
-- by move semantics.  A move with no Gold TM/HM deliberately returns nil.
function Items.resolveGoldItem(goldItems, yellowItems, yellowId)
  yellowId = tostring(yellowId or "")
  if yellowId == "" or Items.isLocalOnly(yellowId) then return nil, "local" end
  if type(goldItems) ~= "table" then return nil, "missing" end
  if goldItems[yellowId] then return yellowId, "direct" end

  local ydef = type(yellowItems) == "table" and yellowItems[yellowId] or nil
  local move = machineMove(ydef)
  if not move then return nil, "missing" end
  for id, def in pairs(goldItems) do
    if machineMove(def) == move then return id, "machine", move end
  end
  return nil, "no-machine", move
end

return Items
