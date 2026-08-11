-- v0.3.88 Silph Co finale / Saffron liberation facts for the Yellow Kanto
-- excursion running inside Gold.
--
-- This module deliberately owns only immutable Yellow map/script facts. Gold
-- remains the battle/inventory/save authority; TwinRegionWorld performs the
-- companion-local event/object mutations.

local Silph = {}

Silph.VERSION = "0.3.88"

Silph.FINAL = {
  map = "SILPH_CO_11F",
  duoEvent = "EVENT_BEAT_SILPH_CO_11F_JESSIE_JAMES",
  giovanniEvent = "EVENT_BEAT_SILPH_CO_GIOVANNI",
  masterBallEvent = "EVENT_GOT_MASTER_BALL",
  duoParty = 45, -- Yellow script loads OPP_ROCKET party $2d.
  giovanniParty = 2,
  jamesText = "TEXT_SILPHCO11F_JAMES",
  jessieText = "TEXT_SILPHCO11F_JESSIE",
  giovanniText = "TEXT_SILPHCO11F_GIOVANNI",
  presidentText = "TEXT_SILPHCO11F_SILPH_PRESIDENT",
  duoIntroLabel = "_SilphCoJessieJamesText1",
  duoAfterLabel = "_SilphCoJessieJamesText4",
  giovanniIntroLabel = "_SilphCo11FGiovanniText",
  giovanniAfterLabel = "_SilphCo11FGiovanniYouRuinedOurPlansText",
  presidentIntroLabel = "_SilphCo11FSilphPresidentText",
  presidentReceivedLabel = "_SilphCo11FSilphPresidentReceivedMasterBallText",
  presidentAfterLabel = "_SilphCo11FSilphPresidentMasterBallDescriptionText",
  presidentNoRoomLabel = "_SilphCo11FSilphPresidentNoRoomText",
}

-- SilphCo11FDefaultScript's Jessie/James trigger: Y=3 and X<4.
function Silph.duoStep(mapId, x, y)
  return tostring(mapId or "") == Silph.FINAL.map
    and tonumber(y) == 3 and tonumber(x) ~= nil and tonumber(x) < 4
end

-- SilphCo11FScript_621c5 player-coordinate array.
function Silph.giovanniStep(mapId, x, y)
  if tostring(mapId or "") ~= Silph.FINAL.map then return false end
  x, y = tonumber(x), tonumber(y)
  return (x == 6 and y == 13) or (x == 7 and y == 12)
end

function Silph.isSilphFloor(mapId)
  mapId = tostring(mapId or "")
  local n = tonumber(mapId:match("^SILPH_CO_(%d+)F$"))
  return n ~= nil and n >= 2 and n <= 11
end

-- The nine pre-liberation Rockets present in Yellow's Saffron object/toggle
-- state (Rocket 9 is removed from Yellow's actual object list).
Silph.SAFFRON = {
  map = "SAFFRON_CITY",
  rocketTexts = {
    TEXT_SAFFRONCITY_ROCKET1 = true,
    TEXT_SAFFRONCITY_ROCKET2 = true,
    TEXT_SAFFRONCITY_ROCKET3 = true,
    TEXT_SAFFRONCITY_ROCKET4 = true,
    TEXT_SAFFRONCITY_ROCKET5 = true,
    TEXT_SAFFRONCITY_ROCKET6 = true,
    TEXT_SAFFRONCITY_ROCKET7 = true,
    TEXT_SAFFRONCITY_ROCKET8 = true,
  },
  civilianTexts = {
    TEXT_SAFFRONCITY_SCIENTIST = true,
    TEXT_SAFFRONCITY_SILPH_WORKER_M = true,
    TEXT_SAFFRONCITY_SILPH_WORKER_F = true,
    TEXT_SAFFRONCITY_GENTLEMAN = true,
    TEXT_SAFFRONCITY_PIDGEOT = true,
    TEXT_SAFFRONCITY_ROCKER = true,
  },
}

function Silph.isSaffronRocket(obj)
  return obj ~= nil and Silph.SAFFRON.rocketTexts[tostring(obj.text or "")] == true
end

function Silph.isSaffronCivilian(obj)
  return obj ~= nil and Silph.SAFFRON.civilianTexts[tostring(obj.text or "")] == true
end

-- SilphCo11FTeamRocketLeavesScript hides every Rocket actor throughout the
-- tower. Use semantic object facts rather than hard-coding toggle ids so this
-- survives extractor index changes.
function Silph.isSilphRocket(mapId, obj)
  if not Silph.isSilphFloor(mapId) or type(obj) ~= "table" then return false end
  local trainerClass = tostring(obj.trainerClass or "")
  if trainerClass == "OPP_ROCKET" or trainerClass == "OPP_GIOVANNI" then return true end
  local sprite = tostring(obj.sprite or "")
  if sprite == "SPRITE_ROCKET" or sprite == "SPRITE_GIOVANNI"
      or sprite == "SPRITE_JESSIE" or sprite == "SPRITE_JAMES" then return true end
  local text = tostring(obj.text or "")
  return text:find("ROCKET", 1, true) ~= nil
      or text:find("GIOVANNI", 1, true) ~= nil
      or text:find("JESSIE", 1, true) ~= nil
      or text:find("JAMES", 1, true) ~= nil
end

function Silph.isPresident(mapId, textConst)
  return tostring(mapId or "") == Silph.FINAL.map
    and tostring(textConst or "") == Silph.FINAL.presidentText
end

function Silph.isGiovanni(mapId, obj)
  return tostring(mapId or "") == Silph.FINAL.map and type(obj) == "table"
    and tostring(obj.text or "") == Silph.FINAL.giovanniText
end

return Silph
