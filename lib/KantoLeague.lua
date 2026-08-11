-- Pokémon Yellow League progression facts used by the Gold/Kanto bridge.
-- v0.3.89: keep the authored Gen-1 room geometry/party selection while Gold
-- owns the actual battle engine and Hall of Fame save record.
local League = {}
League.VERSION = "0.3.90"

League.START_EVENT = "EVENT_KANTO_YELLOW_LEAGUE_STARTED"
League.HOF_EVENT = "EVENT_KANTO_YELLOW_HALL_OF_FAME"
League.CHAMPION_EVENT = "EVENT_BEAT_CHAMPION_RIVAL"
League.RIVAL_KEY = "yellowRivalStarterV1"
League.DEFAULT_RIVAL_PARTY = 1 -- Yellow's RIVAL_STARTER_JOLTEON enum.

League.ROOMS = {
  LORELEIS_ROOM = {
    order = 1, class = "OPP_LORELEI", party = 1,
    text = "TEXT_LORELEISROOM_LORELEI",
    event = "EVENT_BEAT_LORELEIS_ROOM_TRAINER_0",
    previous = "INDIGO_PLATEAU_LOBBY", next = "BRUNOS_ROOM",
    exit = { bx = 2, by = 0, closed = 0x24, open = 0x05 },
  },
  BRUNOS_ROOM = {
    order = 2, class = "OPP_BRUNO", party = 1,
    text = "TEXT_BRUNOSROOM_BRUNO",
    event = "EVENT_BEAT_BRUNOS_ROOM_TRAINER_0",
    previous = "LORELEIS_ROOM", next = "AGATHAS_ROOM",
    exit = { bx = 2, by = 0, closed = 0x24, open = 0x05 },
  },
  AGATHAS_ROOM = {
    order = 3, class = "OPP_AGATHA", party = 1,
    text = "TEXT_AGATHASROOM_AGATHA",
    event = "EVENT_BEAT_AGATHAS_ROOM_TRAINER_0",
    previous = "BRUNOS_ROOM", next = "LANCES_ROOM",
    exit = { bx = 2, by = 0, closed = 0x3b, open = 0x0e },
  },
  LANCES_ROOM = {
    order = 4, class = "OPP_LANCE", party = 1,
    text = "TEXT_LANCESROOM_LANCE",
    event = "EVENT_BEAT_LANCES_ROOM_TRAINER_0",
    beatEvent = "EVENT_BEAT_LANCE",
    lockEvent = "EVENT_LANCES_ROOM_LOCK_DOOR",
    previous = "AGATHAS_ROOM", next = "CHAMPIONS_ROOM",
    entrance = {
      { bx = 2, by = 6, open = 0x31, closed = 0x72 },
      { bx = 3, by = 6, open = 0x32, closed = 0x73 },
    },
  },
}

League.CHAMPION = {
  map = "CHAMPIONS_ROOM", text = "TEXT_CHAMPIONSROOM_RIVAL",
  class = "OPP_RIVAL3", event = League.CHAMPION_EVENT,
  triggerY = 6,
  intro = "_ChampionsRoomRivalIntroText",
  after = "_ChampionsRoomRivalAfterBattleText",
  oakCongrats = "_ChampionsRoomOakCongratulatesPlayerText",
  oakCome = "_ChampionsRoomOakComeWithMeText",
  hallMap = "HALL_OF_FAME", hallX = 5, hallY = 6, hallFacing = "up",
}

League.HALL = {
  map = "HALL_OF_FAME", oakText = "_HallOfFameOakText",
  returnMap = "PALLET_TOWN", returnFacing = "down",
}

League.RUN_MAPS = {
  LORELEIS_ROOM = true, BRUNOS_ROOM = true, AGATHAS_ROOM = true,
  LANCES_ROOM = true, CHAMPIONS_ROOM = true, HALL_OF_FAME = true,
}

function League.room(mapId) return League.ROOMS[tostring(mapId or "")] end
function League.isRunMap(mapId) return League.RUN_MAPS[tostring(mapId or "")] == true end
function League.isEliteMap(mapId) return League.room(mapId) ~= nil end

function League.blocks(mapId, eventFn)
  local room = League.room(mapId)
  if not room then return {} end
  eventFn = type(eventFn) == "function" and eventFn or function() return false end
  local out = {}
  if room.exit then
    out[#out + 1] = {
      bx = room.exit.bx, by = room.exit.by,
      block = eventFn(room.event) and room.exit.open or room.exit.closed,
    }
  end
  if room.entrance then
    local locked = eventFn(room.lockEvent)
    for _, row in ipairs(room.entrance) do
      out[#out + 1] = { bx = row.bx, by = row.by,
        block = locked and row.closed or row.open }
    end
  end
  return out
end

-- Once the League run begins, Yellow never lets the player walk backwards
-- through a room's entrance. A blackout resets the run instead.
function League.blocksRetreat(mapId, destId, started, eventFn)
  if not started then return false end
  mapId, destId = tostring(mapId or ""), tostring(destId or "")
  local room = League.room(mapId)
  if room and tostring(room.previous or "") == destId then return true end
  if mapId == League.CHAMPION.map and destId == "LANCES_ROOM" then return true end
  if mapId == League.HALL.map and destId == League.CHAMPION.map then return true end
  return false
end

function League.championStep(mapId, x, y)
  if tostring(mapId or "") ~= League.CHAMPION.map then return false end
  x, y = tonumber(x), tonumber(y)
  return x ~= nil and y ~= nil and y <= League.CHAMPION.triggerY
end

function League.rivalParty(value)
  value = math.floor(tonumber(value) or League.DEFAULT_RIVAL_PARTY)
  if value < 1 or value > 3 then value = League.DEFAULT_RIVAL_PARTY end
  return value
end

return League
