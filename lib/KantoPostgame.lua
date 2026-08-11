-- v0.3.90 Yellow postgame physical-state facts for the Gold/Kanto excursion.
local Postgame = { VERSION = "0.3.90" }

Postgame.HOF_EVENT = "EVENT_KANTO_YELLOW_HALL_OF_FAME"
Postgame.CERULEAN_CAVE = {
  cityMap = "CERULEAN_CITY",
  caveMap = "CERULEAN_CAVE_1F",
  guardText = "TEXT_CERULEANCITY_SUPER_NERD3",
  guardX = 4,
  guardY = 12,
  entranceX = 4,
  entranceY = 11,
  lockedText = "This is CERULEAN CAVE! Only a POKEMON LEAGUE champion may enter.",
}

function Postgame.ceruleanCaveUnlocked(eventFn)
  return type(eventFn) == "function" and eventFn(Postgame.HOF_EVENT) == true
end

function Postgame.blocksWarp(fromMap, toMap, unlocked)
  local cave = Postgame.CERULEAN_CAVE
  return not unlocked
    and tostring(fromMap or "") == cave.cityMap
    and tostring(toMap or "") == cave.caveMap
end

function Postgame.isCeruleanGuard(mapId, obj)
  local cave = Postgame.CERULEAN_CAVE
  return tostring(mapId or "") == cave.cityMap and type(obj) == "table"
    and tostring(obj.text or "") == cave.guardText
end

return Postgame
