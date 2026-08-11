-- v0.3.71 story-free scripted Kanto reward facts for the Gold bridge.
--
-- Gen1Recomp hand-ports these side events for Red/Yellow, but Kanto free roam
-- deliberately runs ordinary text_asm through a detached dialogue sandbox.
-- This table promotes only reward/service interactions whose result has an
-- unambiguous Gold/Silver representation.  The runtime owns mutation; this
-- file owns immutable map/text/species/item facts only.

local Rewards = {}

Rewards.VERSION = "0.3.99"

Rewards.POKEMON = {
  EEVEE = {
    id = "EEVEE", kind = "pokemon", mode = "gift",
    map = "CELADON_MANSION_ROOF_HOUSE",
    text = "TEXT_CELADONMANSION_ROOF_HOUSE_EEVEE_POKEBALL",
    species = "EEVEE", level = 25, event = "EVENT_GOT_EEVEE",
    objectName = "CELADONMANSION_ROOF_HOUSE_EEVEE_POKEBALL",
    objectText = "TEXT_CELADONMANSION_ROOF_HOUSE_EEVEE_POKEBALL",
    texts = { full = "_BoxIsFullText", received = "_GotMonText" },
  },
  LAPRAS = {
    id = "LAPRAS", kind = "pokemon", mode = "gift",
    map = "SILPH_CO_7F", text = "TEXT_SILPHCO7F_SILPH_WORKER_M1",
    species = "LAPRAS", level = 15, event = "EVENT_GOT_LAPRAS",
    texts = {
      intro = "_SilphCo7FSilphWorkerM1HaveThisPokemonText",
      received = "_GotMonText", description = "_SilphCo7FSilphWorkerM1LaprasDescriptionText",
      full = "_BoxIsFullText", after = "_SilphCo7FSilphWorkerM1IsOurPresidentOkText",
      saved = "_SilphCo7FSilphWorkerM1SavedText",
    },
  },
  MAGIKARP = {
    id = "MAGIKARP", kind = "pokemon", mode = "sale",
    map = "MT_MOON_POKECENTER", text = "TEXT_MTMOONPOKECENTER_MAGIKARP_SALESMAN",
    species = "MAGIKARP", level = 5, price = 500, event = "EVENT_BOUGHT_MAGIKARP",
    texts = {
      ask = "_MtMoonPokecenterMagikarpSalesmanIGotADealText",
      declined = "_MtMoonPokecenterMagikarpSalesmanNoText",
      noMoney = "_MtMoonPokecenterMagikarpSalesmanNoMoneyText",
      full = "_BoxIsFullText", received = "_GotMonText",
      after = "_MtMoonPokecenterMagikarpSalesmanNoRefundsText",
    },
  },
  HITMONLEE = {
    id = "HITMONLEE", kind = "dojo", mode = "choice",
    map = "FIGHTING_DOJO", text = "TEXT_FIGHTINGDOJO_HITMONLEE_POKE_BALL",
    species = "HITMONLEE", level = 30, event = "EVENT_GOT_HITMONLEE",
    prerequisite = "EVENT_BEAT_KARATE_MASTER", finalEvent = "EVENT_DEFEATED_FIGHTING_DOJO",
    objectName = "FIGHTINGDOJO_HITMONLEE_POKE_BALL",
    objectText = "TEXT_FIGHTINGDOJO_HITMONLEE_POKE_BALL",
    ask = "_FightingDojoHitmonleePokeBallText",
  },
  HITMONCHAN = {
    id = "HITMONCHAN", kind = "dojo", mode = "choice",
    map = "FIGHTING_DOJO", text = "TEXT_FIGHTINGDOJO_HITMONCHAN_POKE_BALL",
    species = "HITMONCHAN", level = 30, event = "EVENT_GOT_HITMONCHAN",
    prerequisite = "EVENT_BEAT_KARATE_MASTER", finalEvent = "EVENT_DEFEATED_FIGHTING_DOJO",
    objectName = "FIGHTINGDOJO_HITMONCHAN_POKE_BALL",
    objectText = "TEXT_FIGHTINGDOJO_HITMONCHAN_POKE_BALL",
    ask = "_FightingDojoHitmonchanPokeBallText",
  },
}

Rewards.AIDES = {
  ROUTE_2_GATE = {
    id = "OAK_AIDE_FLASH", kind = "aide", map = "ROUTE_2_GATE",
    text = "TEXT_ROUTE2GATE_OAKS_AIDE", threshold = 10,
    event = "EVENT_GOT_HM_FLASH",
    reward = { candidates = { "HM05", "HM_FLASH" }, teaches = { "FLASH" }, display = "HM05", unique = true },
    repeatText = "_Route2GateOaksAideFlashExplanationText",
  },
  ROUTE_11_GATE_2F = {
    id = "OAK_AIDE_ITEMFINDER", kind = "aide", map = "ROUTE_11_GATE_2F",
    text = "TEXT_ROUTE11GATE2F_OAKS_AIDE", threshold = 30,
    event = "EVENT_GOT_ITEMFINDER",
    reward = { candidates = { "ITEMFINDER" }, display = "ITEMFINDER", unique = true },
    repeatText = "_Route11Gate2FOaksAideItemfinderDescriptionText",
  },
  ROUTE_15_GATE_2F = {
    id = "OAK_AIDE_EXP", kind = "aide", map = "ROUTE_15_GATE_2F",
    text = "TEXT_ROUTE15GATE2F_OAKS_AIDE", threshold = 50,
    event = "EVENT_GOT_EXP_ALL",
    -- Gold has EXP.SHARE rather than Gen-1 EXP.ALL; this is the semantic
    -- successor, not a TM-number reinterpretation.
    reward = { candidates = { "EXP_SHARE", "EXP_ALL" }, names = { "EXP.SHARE", "EXP SHARE", "EXP.ALL" }, display = "EXP.SHARE", unique = true },
    repeatText = "_Route15Gate2FOaksAideExpAllText",
  },
}

Rewards.ITEM_GIFTS = {
  MR_PSYCHIC = {
    id = "MR_PSYCHIC", kind = "item", map = "MR_PSYCHICS_HOUSE",
    text = "TEXT_MRPSYCHICSHOUSE_MR_PSYCHIC", event = "EVENT_GOT_TM29",
    reward = { candidates = { "TM29", "TM_PSYCHIC_M" }, teaches = { "PSYCHIC_M", "PSYCHIC" }, display = "TM29" },
    texts = { intro = "_MrPsychicsHouseMrPsychicText", after = "_MrPsychicsHouseMrPsychicNoMoreText" },
  },
  FLY_GIRL = {
    id = "FLY_GIRL", kind = "item", map = "ROUTE_16_FLY_HOUSE",
    text = "TEXT_ROUTE16FLYHOUSE_BRUNETTE_GIRL", event = "EVENT_GOT_HM02",
    reward = { candidates = { "HM02", "HM_FLY" }, teaches = { "FLY" }, display = "HM02", unique = true },
    texts = { intro = "_Route16FlyHouseBrunetteGirlText", after = "_Route16FlyHouseBrunetteGirlHm02ExplanationText" },
  },
  CELADON_COIN_CASE = {
    id = "CELADON_COIN_CASE", kind = "item", map = "CELADON_DINER",
    text = "TEXT_CELADONDINER_GYM_GUIDE", event = "EVENT_GOT_COIN_CASE",
    reward = { candidates = { "COIN_CASE" }, names = { "COIN CASE" }, display = "COIN CASE", unique = true },
    texts = {
      intro = "_CeladonDinerGymGuideImFlatOutBustedText",
      received = "_CeladonDinerGymGuideReceivedCoinCaseText",
      full = "_CeladonDinerGymGuideCoinCaseNoRoomText",
      after = "_CeladonDinerGymGuideWinItBackText",
    },
  },
  ROUTE12_SWIFT = {
    id = "ROUTE12_SWIFT", kind = "item", map = "ROUTE_12_GATE_2F",
    text = "TEXT_ROUTE12GATE2F_BRUNETTE_GIRL", event = "EVENT_GOT_TM39",
    -- Resolve by move semantics, never by Yellow's numeric TM id.
    reward = { teaches = { "SWIFT" }, display = "TM39 SWIFT" },
    texts = {
      intro = "_Route12Gate2FBrunetteGirlYouCanHaveThisText",
      received = "_Route12Gate2FBrunetteGirlReceivedTM39Text",
      full = "_Route12Gate2FBrunetteGirlTM39NoRoomText",
      after = "_Route12Gate2FBrunetteGirlTM39ExplanationText",
    },
  },
}

Rewards.YELLOW_TM_GIFTS = {
  CELADON_COUNTER = {
    id = "CELADON_COUNTER", kind = "yellow_tm",
    map = "CELADON_MART_3F", text = "TEXT_CELADONMART3F_CLERK",
    event = "EVENT_GOT_TM18",
    creditEvent = "EVENT_KANTO_CELADON_TM18_CREDIT",
    move = "COUNTER",
    display = "TM18 COUNTER",
    introText = "_CeladonMart3FClerkTM18PreReceiveText",
    receivedText = "_CeladonMart3FClerkReceivedTM18Text",
    explanationText = "_CeladonMart3FClerkTM18ExplanationText",
    noRoomText = "_CeladonMart3FClerkTM18NoRoomText",
  },
  CINNABAR_METRONOME = {
    id = "CINNABAR_METRONOME", kind = "yellow_tm",
    map = "CINNABAR_LAB_METRONOME_ROOM",
    text = "TEXT_CINNABARLABMETRONOMEROOM_SCIENTIST1",
    event = "EVENT_GOT_TM35",
    creditEvent = "EVENT_KANTO_CINNABAR_TM35_CREDIT",
    move = "METRONOME",
    display = "TM35 METRONOME",
    introText = "_CinnabarLabMetronomeRoomScientist1Text",
    receivedText = "_CinnabarLabMetronomeRoomScientist1ReceivedTM35Text",
    explanationText = "_CinnabarLabMetronomeRoomScientist1TM35ExplanationText",
    noRoomText = "_CinnabarLabMetronomeRoomScientist1TM35NoRoomText",
  },
  SILPH_SELFDESTRUCT = {
    id = "SILPH_SELFDESTRUCT", kind = "yellow_tm",
    map = "SILPH_CO_2F", text = "TEXT_SILPHCO2F_SILPH_WORKER_F",
    event = "EVENT_GOT_TM36",
    creditEvent = "EVENT_KANTO_SILPH_TM36_CREDIT",
    move = "SELFDESTRUCT",
    display = "TM36 SELFDESTRUCT",
    introText = "SilphCo2FSilphWorkerFPleaseTakeThisText",
    receivedText = "_SilphCo2FSilphWorkerFReceivedTM36Text",
    explanationText = "_SilphCo2FSilphWorkerFTM36ExplanationText",
    noRoomText = "_SilphCo2FSilphWorkerFTM36NoRoomText",
  },
}

function Rewards.yellowTmGift(mapId, textConst)
  mapId, textConst = tostring(mapId or ""), tostring(textConst or "")
  for _, row in pairs(Rewards.YELLOW_TM_GIFTS) do
    if row.map == mapId and row.text == textConst then return row end
  end
  return nil
end

Rewards.COPYCAT = {
  map = "COPYCATS_HOUSE_2F",
  text = "TEXT_COPYCATSHOUSE2F_COPYCAT",
  item = "POKE_DOLL",
  event = "EVENT_GOT_TM31",
  creditEvent = "EVENT_KANTO_COPYCAT_TM31_CREDIT",
  move = "MIMIC",
  display = "TM31 MIMIC",
  introText = "_CopycatsHouse2FCopycatDoYouLikePokemonText",
  preReceiveText = "_CopycatsHouse2FCopycatTM31PreReceiveText",
  receivedText = "_CopycatsHouse2FCopycatReceivedTM31Text",
  explanationText = "_CopycatsHouse2FCopycatTM31Explanation2Text",
  firstExplanationText = "_CopycatsHouse2FCopycatTM31Explanation1Text",
  noRoomText = "_CopycatsHouse2FCopycatTM31NoRoomText",
}

function Rewards.isCopycat(mapId, textConst)
  return tostring(mapId or "") == Rewards.COPYCAT.map
      and tostring(textConst or "") == Rewards.COPYCAT.text
end

Rewards.CELADON_DRINK_GIRL = {
  map = "CELADON_MART_ROOF",
  text = "TEXT_CELADONMARTROOF_LITTLE_GIRL",
  rewards = {
    FRESH_WATER = {
      id = "TM13", drink = "FRESH_WATER", move = "ICE_BEAM",
      event = "EVENT_GOT_TM13",
      creditEvent = "EVENT_KANTO_CELADON_TM13_CREDIT",
      display = "TM13 ICE BEAM",
      yayText = "_CeladonMartRoofLittleGirlYayFreshWaterText",
      receivedText = "_CeladonMartRoofLittleGirlReceivedTM13Text",
      explanationText = "_CeladonMartRoofLittleGirlTM13ExplanationText",
    },
    SODA_POP = {
      id = "TM48", drink = "SODA_POP", move = "ROCK_SLIDE",
      event = "EVENT_GOT_TM48",
      creditEvent = "EVENT_KANTO_CELADON_TM48_CREDIT",
      display = "TM48 ROCK SLIDE",
      yayText = "_CeladonMartRoofLittleGirlYaySodaPopText",
      receivedText = "_CeladonMartRoofLittleGirlReceivedTM48Text",
      explanationText = "_CeladonMartRoofLittleGirlTM48ExplanationText",
    },
    LEMONADE = {
      id = "TM49", drink = "LEMONADE", move = "TRI_ATTACK",
      event = "EVENT_GOT_TM49",
      creditEvent = "EVENT_KANTO_CELADON_TM49_CREDIT",
      display = "TM49 TRI ATTACK",
      yayText = "_CeladonMartRoofLittleGirlYayLemonadeText",
      receivedText = "_CeladonMartRoofLittleGirlReceivedTM49Text",
      explanationText = "_CeladonMartRoofLittleGirlTM49ExplanationText",
    },
  },
  thirstyText = "_CeladonMartRoofLittleGirlImThirstyText",
  giveText = "_CeladonMartRoofLittleGirlGiveHerADrinkText",
  whichText = "_CeladonMartRoofLittleGirlGiveHerWhichDrinkText",
  notThirstyText = "_CeladonMartRoofLittleGirlImNotThirstyText",
}

function Rewards.isCeladonDrinkGirl(mapId, textConst)
  return tostring(mapId or "") == Rewards.CELADON_DRINK_GIRL.map
      and tostring(textConst or "") == Rewards.CELADON_DRINK_GIRL.text
end

Rewards.VENDING = {
  map = "CELADON_MART_ROOF",
  texts = {
    TEXT_CELADONMARTROOF_VENDING_MACHINE1 = true,
    TEXT_CELADONMARTROOF_VENDING_MACHINE2 = true,
    TEXT_CELADONMARTROOF_VENDING_MACHINE3 = true,
  },
  drinks = {
    { id = "FRESH_WATER", price = 200 },
    { id = "SODA_POP", price = 300 },
    { id = "LEMONADE", price = 350 },
  },
}

local ORDER = {
  Rewards.POKEMON.EEVEE, Rewards.POKEMON.LAPRAS, Rewards.POKEMON.MAGIKARP,
  Rewards.POKEMON.HITMONLEE, Rewards.POKEMON.HITMONCHAN,
  Rewards.AIDES.ROUTE_2_GATE, Rewards.AIDES.ROUTE_11_GATE_2F, Rewards.AIDES.ROUTE_15_GATE_2F,
  Rewards.ITEM_GIFTS.MR_PSYCHIC, Rewards.ITEM_GIFTS.FLY_GIRL,
  Rewards.ITEM_GIFTS.CELADON_COIN_CASE, Rewards.ITEM_GIFTS.ROUTE12_SWIFT,
}

function Rewards.match(mapId, textConst)
  mapId, textConst = tostring(mapId or ""), tostring(textConst or "")
  for _, row in ipairs(ORDER) do
    if row.map == mapId and row.text == textConst then return row end
  end
  local yellowTm = Rewards.yellowTmGift(mapId, textConst)
  if yellowTm then return yellowTm end
  if mapId == Rewards.VENDING.map and Rewards.VENDING.texts[textConst] then
    return { id = "CELADON_VENDING", kind = "vending", map = mapId, text = textConst }
  end
  return nil
end

function Rewards.forMap(mapId)
  mapId = tostring(mapId or "")
  local out = {}
  for _, row in ipairs(ORDER) do
    if row.map == mapId and row.objectText then out[#out + 1] = row end
  end
  return out
end

function Rewards.isPhysicalObject(spec, obj)
  if not (spec and obj and spec.objectText) then return false end
  if tostring(obj.text or "") == tostring(spec.objectText) then return true end
  return spec.objectName ~= nil and tostring(obj.name or "") == tostring(spec.objectName)
end

function Rewards.countOwned(save)
  local dex = save and save.pokedex or {}
  local found, n = {}, 0
  -- Gold hosts use `caught`; older compatibility saves sometimes expose
  -- `owned`.  Count the union so a mixed/migrated save cannot lose aide
  -- progress merely because both tables happen to exist.
  for _, bucket in ipairs({ dex.caught, dex.owned }) do
    if type(bucket) == "table" then
      for species, owned in pairs(bucket) do
        if owned and not found[species] then
          found[species], n = true, n + 1
        end
      end
    end
  end
  return n
end

local function normalized(s)
  return tostring(s or ""):upper():gsub("[^A-Z0-9]", "")
end

function Rewards.resolveItem(data, spec)
  local items = data and data.items
  if type(items) ~= "table" or type(spec) ~= "table" then return nil end
  for _, id in ipairs(spec.candidates or {}) do
    if items[id] then return id, items[id] end
  end
  local teaches = {}
  for _, move in ipairs(spec.teaches or {}) do teaches[tostring(move)] = true end
  local names = {}
  for _, name in ipairs(spec.names or {}) do names[normalized(name)] = true end
  for id, def in pairs(items) do
    if type(def) == "table" then
      if next(teaches) and teaches[tostring(def.teaches or "")] then return id, def end
      if next(names) and names[normalized(def.name or id)] then return id, def end
    end
  end
  return nil
end

function Rewards.money(save)
  if type(save) ~= "table" then return 0 end
  if save.money ~= nil then return math.max(0, math.floor(tonumber(save.money) or 0)) end
  local player = save.player
  return math.max(0, math.floor(tonumber(player and player.money) or 0))
end

function Rewards.setMoney(save, amount)
  if type(save) ~= "table" then return false end
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if save.money ~= nil or not (save.player and save.player.money ~= nil) then
    save.money = amount
  else
    save.player.money = amount
  end
  return true
end

return Rewards
