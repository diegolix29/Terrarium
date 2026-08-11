-- v0.3.70 story-free Yellow starter-gift rules for the Gold Kanto bridge.
--
-- The retail Yellow scripts are presentation/story bytecode, so the Kanto
-- bridge cannot run their give_pokemon commands against Gold directly.  This
-- module keeps only the immutable service facts needed by TwinRegionWorld:
-- exact map/text ownership, one-time event ids, species/levels, and the two
-- prerequisites that matter (Pikachu happiness and the Thunder Badge).
-- Gold remains authoritative for party/box/Pokedex/OT/happiness state.

local Gifts = {}

Gifts.VERSION = "0.3.70"
Gifts.BULBASAUR_HAPPINESS = 147

Gifts.GIFTS = {
  BULBASAUR = {
    id = "BULBASAUR",
    map = "CERULEAN_MELANIES_HOUSE",
    text = "TEXT_CERULEANMELANIESHOUSE_MELANIE",
    species = "BULBASAUR",
    level = 10,
    event = "EVENT_GOT_BULBASAUR_IN_CERULEAN",
    happiness = Gifts.BULBASAUR_HAPPINESS,
    objectName = "CERULEANMELANIESHOUSE_BULBASAUR",
    objectText = "TEXT_CERULEANMELANIESHOUSE_BULBASAUR",
    texts = {
      intro = "MelanieText1",
      ask = "MelanieText2",
      received = "MelanieText3",
      after = "MelanieText4",
      declined = "MelanieText5",
    },
  },
  CHARMANDER = {
    id = "CHARMANDER",
    map = "ROUTE_24",
    text = "TEXT_ROUTE24_COOLTRAINER_M4",
    species = "CHARMANDER",
    level = 10,
    event = "EVENT_54F",
    texts = {
      ask = "_Route24DamianText1",
      received = "_Route24DamianText2",
      declined = "_Route24DamianText3",
      after = "_Route24DamianText4",
    },
  },
  SQUIRTLE = {
    id = "SQUIRTLE",
    map = "VERMILION_CITY",
    text = "TEXT_VERMILIONCITY_OFFICER_JENNY",
    species = "SQUIRTLE",
    level = 10,
    event = "EVENT_GOT_SQUIRTLE_FROM_OFFICER_JENNY",
    badge = "THUNDER",
    texts = {
      locked = "_OfficerJennyText1",
      ask = "_OfficerJennyText2",
      received = "_OfficerJennyText3",
      declined = "_OfficerJennyText4",
      after = "_OfficerJennyText5",
    },
  },
}

local ORDER = { "BULBASAUR", "CHARMANDER", "SQUIRTLE" }

function Gifts.match(mapId, textConst)
  mapId, textConst = tostring(mapId or ""), tostring(textConst or "")
  for _, id in ipairs(ORDER) do
    local row = Gifts.GIFTS[id]
    if mapId == row.map and textConst == row.text then return row end
  end
  return nil
end

function Gifts.isGiftObject(spec, obj)
  if not (spec and obj and spec.objectText) then return false end
  if tostring(obj.text or "") == tostring(spec.objectText) then return true end
  return spec.objectName ~= nil
    and tostring(obj.name or "") == tostring(spec.objectName)
end

function Gifts.forMap(mapId)
  mapId = tostring(mapId or "")
  local out = {}
  for _, id in ipairs(ORDER) do
    local row = Gifts.GIFTS[id]
    if row.map == mapId then out[#out + 1] = row end
  end
  return out
end

return Gifts
