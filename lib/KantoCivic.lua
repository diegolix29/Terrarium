-- v0.3.69 story-free Kanto civic/service rules.
--
-- These are small physical/service rules from Pokemon Yellow that do not need
-- the Yellow story VM: Saffron's four thirsty gate guards, Pewter Museum's
-- admission rope/Old Amber handoff, and the Fan Club -> Bike Shop voucher
-- chain. Gold owns money/items; the
-- companion region owns only the foreign-region completion flags.

local Civic = {}

Civic.VERSION = "0.3.69"

Civic.SAFFRON_EVENT = "EVENT_GAVE_GUARDS_DRINK"
Civic.MUSEUM_TICKET_EVENT = "EVENT_BOUGHT_MUSEUM_TICKET"
Civic.OLD_AMBER_EVENT = "EVENT_GOT_OLD_AMBER"
Civic.MUSEUM_MAP = "MUSEUM_1F"
Civic.MUSEUM_PRICE = 50
Civic.DRINKS = { "FRESH_WATER", "SODA_POP", "LEMONADE" }

-- Vermilion Fan Club -> Cerulean Bike Shop service chain.  Gold owns the
-- actual key items; Kanto persistence only remembers that the foreign-region
-- service was completed so the chairman/shop cannot duplicate rewards.
Civic.FAN_CLUB_MAP = "POKEMON_FAN_CLUB"
Civic.BIKE_SHOP_MAP = "BIKE_SHOP"
Civic.BIKE_VOUCHER_EVENT = "EVENT_RECEIVED_BIKE_VOUCHER"
Civic.BICYCLE_EVENT = "EVENT_GOT_BICYCLE"
Civic.FAN_CLUB = { chairmanText = "TEXT_POKEMONFANCLUB_CHAIRMAN" }
Civic.BIKE_SHOP = { clerkText = "TEXT_BIKESHOP_CLERK" }

local function packed(x, y)
  return (tonumber(y) or 0) * 1024 + (tonumber(x) or 0)
end

Civic.SAFFRON_GATES = {
  ROUTE_5_GATE = {
    guardText = "TEXT_ROUTE5GATE_GUARD",
    horizontal = false,
    triggers = { [packed(3, 3)] = true, [packed(4, 3)] = true },
  },
  ROUTE_6_GATE = {
    guardText = "TEXT_ROUTE6GATE_GUARD",
    horizontal = false,
    triggers = { [packed(3, 2)] = true, [packed(4, 2)] = true },
  },
  ROUTE_7_GATE = {
    guardText = "TEXT_ROUTE7GATE_GUARD",
    horizontal = true,
    triggers = { [packed(3, 3)] = true, [packed(3, 4)] = true },
  },
  ROUTE_8_GATE = {
    guardText = "TEXT_ROUTE8GATE_GUARD",
    horizontal = true,
    triggers = { [packed(2, 3)] = true, [packed(2, 4)] = true },
  },
}

Civic.MUSEUM = {
  map = Civic.MUSEUM_MAP,
  clerkText = "TEXT_MUSEUM1F_SCIENTIST1",
  amberScientistText = "TEXT_MUSEUM1F_SCIENTIST2",
  amberObjectText = "TEXT_MUSEUM1F_OLD_AMBER",
  amberObjectName = "MUSEUM1F_OLD_AMBER",
  ticketCells = { [packed(9, 4)] = true, [packed(10, 4)] = true },
}

function Civic.key(x, y)
  return packed(x, y)
end

function Civic.gate(mapId)
  return Civic.SAFFRON_GATES[tostring(mapId or "")]
end

function Civic.gateTrigger(mapId, x, y)
  local gate = Civic.gate(mapId)
  return gate ~= nil and gate.triggers[packed(x, y)] == true or false
end

function Civic.gateByText(textConst)
  textConst = tostring(textConst or "")
  for mapId, gate in pairs(Civic.SAFFRON_GATES) do
    if gate.guardText == textConst then return mapId, gate end
  end
  return nil
end

function Civic.gateBounce(mapId, facing)
  local gate = Civic.gate(mapId)
  if not gate then return nil end
  if gate.horizontal then
    return facing == "left" and "right" or "left"
  end
  return facing == "up" and "down" or "up"
end

function Civic.takeDrink(inventory)
  if type(inventory) ~= "table" then return nil end
  for _, id in ipairs(Civic.DRINKS) do
    local count = inventory[id] == true and 1 or (tonumber(inventory[id]) or 0)
    if count > 0 then
      count = count - 1
      inventory[id] = count > 0 and count or nil
      return id
    end
  end
  return nil
end

function Civic.museumTicketTrigger(mapId, x, y)
  return tostring(mapId or "") == Civic.MUSEUM_MAP
    and Civic.MUSEUM.ticketCells[packed(x, y)] == true
end

function Civic.isMuseumClerk(mapId, textConst)
  return tostring(mapId or "") == Civic.MUSEUM_MAP
    and tostring(textConst or "") == Civic.MUSEUM.clerkText
end

function Civic.isAmberScientist(mapId, textConst)
  return tostring(mapId or "") == Civic.MUSEUM_MAP
    and tostring(textConst or "") == Civic.MUSEUM.amberScientistText
end

function Civic.isAmberDisplay(mapId, obj)
  if tostring(mapId or "") ~= Civic.MUSEUM_MAP or type(obj) ~= "table" then return false end
  return tostring(obj.name or "") == Civic.MUSEUM.amberObjectName
    or tostring(obj.text or "") == Civic.MUSEUM.amberObjectText
end

function Civic.isFanClubChairman(mapId, textConst)
  return tostring(mapId or "") == Civic.FAN_CLUB_MAP
    and tostring(textConst or "") == Civic.FAN_CLUB.chairmanText
end

function Civic.isBikeShopClerk(mapId, textConst)
  return tostring(mapId or "") == Civic.BIKE_SHOP_MAP
    and tostring(textConst or "") == Civic.BIKE_SHOP.clerkText
end

function Civic.itemCount(inventory, itemId)
  if type(inventory) ~= "table" then return 0 end
  local value = inventory[itemId]
  if value == true then return 1 end
  return math.max(0, tonumber(value) or 0)
end

function Civic.hasItem(inventory, itemId)
  return Civic.itemCount(inventory, itemId) > 0
end

return Civic
