-- v0.3.91 Yellow Safari/Fuchsia progression facts for the Gold Kanto bridge.
--
-- Yellow's Gold Teeth do not exist in Gold/Silver and therefore stay in the
-- companion Kanto item namespace. The two HM rewards are resolved by move
-- semantics into the active Gold item table, while Yellow's own one-time
-- events remain companion-local so they cannot collide with Johto story state.

local Safari = { VERSION = "0.3.91" }

Safari.GOLD_TEETH = {
  item = "GOLD_TEETH",
  map = "SAFARI_ZONE_WEST",
  text = "TEXT_SAFARIZONEWEST_GOLD_TEETH",
}

Safari.SECRET_HOUSE = {
  id = "SAFARI_SURF",
  kind = "item",
  map = "SAFARI_ZONE_SECRET_HOUSE",
  text = "TEXT_SAFARIZONESECRETHOUSE_FISHING_GURU",
  event = "EVENT_GOT_HM03",
  reward = {
    candidates = { "HM03", "HM_SURF" },
    teaches = { "SURF" },
    display = "HM03",
    unique = true,
  },
  texts = {
    intro = "_SafariZoneSecretHouseFishingGuruYouHaveWonText",
    received = "_SafariZoneSecretHouseFishingGuruReceivedHM03Text",
    after = "_SafariZoneSecretHouseFishingGuruHM03ExplanationText",
    full = "_SafariZoneSecretHouseFishingGuruHM03NoRoomText",
  },
}

Safari.WARDEN = {
  map = "WARDENS_HOUSE",
  text = "TEXT_WARDENSHOUSE_WARDEN",
  teethItem = "GOLD_TEETH",
  gaveEvent = "EVENT_GAVE_GOLD_TEETH",
  hmEvent = "EVENT_GOT_HM04",
  reward = {
    candidates = { "HM04", "HM_STRENGTH" },
    teaches = { "STRENGTH" },
    display = "HM04",
    unique = true,
  },
  texts = {
    gibberish = "_WardensHouseWardenGibberish1Text",
    gave = "_WardensHouseWardenGaveTheGoldTeethText",
    thanks = "_WardensHouseWardenThanksText",
    received = "_WardensHouseWardenReceivedHM04Text",
    after = "_WardensHouseWardenHM04ExplanationText",
    full = "_WardensHouseWardenHM04NoRoomText",
  },
}

-- Pokemon Yellow engine/menus/start_sub_menus.asm field-HM badge checks.
Safari.FIELD_BADGES = {
  CUT = "CASCADE",
  FLY = "THUNDER",
  SURF = "SOUL",
  STRENGTH = "RAINBOW",
  FLASH = "BOULDER",
}

function Safari.requiredBadge(moveId)
  return Safari.FIELD_BADGES[tostring(moveId or ""):upper()]
end

function Safari.isSecretHouse(mapId, textConst)
  return tostring(mapId or "") == Safari.SECRET_HOUSE.map
    and tostring(textConst or "") == Safari.SECRET_HOUSE.text
end

function Safari.isWarden(mapId, textConst)
  return tostring(mapId or "") == Safari.WARDEN.map
    and tostring(textConst or "") == Safari.WARDEN.text
end

return Safari
