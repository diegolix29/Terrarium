-- v0.3.90 Yellow rival-story facts for the Gold/Kanto excursion.
--
-- TwinRegionWorld owns Gold battles/save/UI. This module only records the
-- immutable Yellow encounter locations, event ids and party-number formulas.
local Rival = { VERSION = "0.3.98" }

Rival.STARTER_KEY = "yellowRivalStarterV1"
Rival.DEFAULT_STARTER = 1 -- old-save fallback retained for compatibility.
Rival.STARTER = {
  JOLTEON = 1,
  FLAREON = 2,
  VAPOREON = 3,
}
Rival.LAB_EVENT = "EVENT_BATTLED_RIVAL_IN_OAKS_LAB"

Rival.ENCOUNTERS = {
  ROUTE22_FIRST = {
    id = "ROUTE22_FIRST",
    map = "ROUTE_22",
    text = "TEXT_ROUTE22_RIVAL1",
    event = "EVENT_BEAT_ROUTE22_RIVAL_1ST_BATTLE",
    class = "OPP_RIVAL1",
    party = 2,
    triggers = { ["29,4"] = true, ["29,5"] = true },
    requiresLabBattle = true,
    requiresBeforeBoulder = true,
    intro = "_Route22RivalBeforeBattleText1",
    after = "_Route22RivalAfterBattleText1",
    fallbackIntro = "RIVAL: You're going to the POKEMON LEAGUE? Forget it! Let's see how good you are!",
    fallbackAfter = "RIVAL: I heard the LEAGUE has tough trainers. Smell ya later!",
  },
  CERULEAN = {
    id = "CERULEAN",
    map = "CERULEAN_CITY",
    text = "TEXT_CERULEANCITY_RIVAL",
    event = "EVENT_BEAT_CERULEAN_RIVAL",
    class = "OPP_RIVAL1",
    party = 3,
    triggers = { ["20,6"] = true, ["21,6"] = true },
    intro = "_CeruleanCityRivalPreBattleText",
    after = "_CeruleanCityRivalIWentToBillsText",
    fallbackIntro = "RIVAL: Yo! Let me see how strong your POKEMON have gotten!",
    fallbackAfter = "RIVAL: I went to BILL's place. Smell ya later!",
  },
  TOWER = {
    id = "TOWER",
    map = "POKEMON_TOWER_2F",
    text = "TEXT_POKEMONTOWER2F_RIVAL",
    event = "EVENT_BEAT_POKEMON_TOWER_RIVAL",
    class = "OPP_RIVAL2",
    partyOffset = 1, -- wRivalStarter + 1
    triggers = { ["15,5"] = true, ["14,6"] = true },
    intro = "_PokemonTower2FRivalWhatBringsYouHereText",
    after = "_PokemonTower2FRivalHowsYourDexText",
    fallbackIntro = "RIVAL: What brings you here? Let's go, pal!",
    fallbackAfter = "RIVAL: I've got a lot to accomplish. Smell ya later!",
  },
  ROUTE22 = {
    id = "ROUTE22",
    map = "ROUTE_22",
    text = "TEXT_ROUTE22_RIVAL2",
    event = "EVENT_BEAT_ROUTE22_RIVAL_2ND_BATTLE",
    class = "OPP_RIVAL2",
    partyOffset = 7, -- wRivalStarter + 7
    triggers = { ["29,4"] = true, ["29,5"] = true },
    requiresAllBadges = true,
    intro = "_Route22RivalBeforeBattleText2",
    after = "_Route22RivalAfterBattleText2",
    fallbackIntro = "RIVAL: You collected all the BADGES too? Then this is my LEAGUE warmup!",
    fallbackAfter = "RIVAL: That loosened me up! I'm ready for the POKEMON LEAGUE!",
  },
}

local ORDER = { "ROUTE22_FIRST", "CERULEAN", "TOWER", "ROUTE22" }

function Rival.starter(value)
  value = math.floor(tonumber(value) or Rival.DEFAULT_STARTER)
  if value < 1 or value > 3 then return Rival.DEFAULT_STARTER end
  return value
end

function Rival.starterFromLabResult(won)
  return won and Rival.STARTER.FLAREON or Rival.STARTER.VAPOREON
end

function Rival.starterAfterFirstRoute22Win(starter)
  starter = Rival.starter(starter)
  if starter == Rival.STARTER.FLAREON then
    return Rival.STARTER.JOLTEON
  end
  return starter
end

function Rival.party(encounter, starter)
  if type(encounter) ~= "table" then return nil end
  if encounter.party then return encounter.party end
  if encounter.partyOffset then return Rival.starter(starter) + encounter.partyOffset end
  return nil
end

function Rival.step(mapId, x, y)
  mapId = tostring(mapId or "")
  local key = tostring(math.floor(tonumber(x) or -999)) .. ","
    .. tostring(math.floor(tonumber(y) or -999))
  for _, id in ipairs(ORDER) do
    local row = Rival.ENCOUNTERS[id]
    if row.map == mapId and row.triggers[key] then return row end
  end
  return nil
end

function Rival.forMap(mapId)
  mapId = tostring(mapId or "")
  local out = {}
  for _, id in ipairs(ORDER) do
    local row = Rival.ENCOUNTERS[id]
    if row.map == mapId then out[#out + 1] = row end
  end
  return out
end

function Rival.isObject(encounter, obj)
  return type(encounter) == "table" and type(obj) == "table"
    and tostring(obj.text or "") == tostring(encounter.text or "")
end

return Rival
