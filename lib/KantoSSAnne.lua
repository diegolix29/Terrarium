-- v0.3.87 mainline Yellow progression bridge for Gold's Kanto excursion.
-- Pure facts/predicates live here; TwinRegionWorld owns Gold save/battle/UI work.

local S = { VERSION = "0.3.87" }

S.BILL = {
  map = "BILLS_HOUSE",
  routeMap = "ROUTE_25",
  pokemonText = "TEXT_BILLSHOUSE_BILL_POKEMON",
  ticketText = "TEXT_BILLSHOUSE_BILL_SS_TICKET",
  rareText = "TEXT_BILLSHOUSE_BILL_CHECK_OUT_MY_RARE_POKEMON",
  pc = { x = 1, y = 4, facing = "up" },
  saidEvent = "EVENT_BILL_SAID_USE_CELL_SEPARATOR",
  usedEvent = "EVENT_USED_CELL_SEPARATOR_ON_BILL",
  metEvent = "EVENT_MET_BILL",
  met2Event = "EVENT_MET_BILL_2",
  ticketEvent = "EVENT_GOT_SS_TICKET",
  leftEvent = "EVENT_LEFT_BILLS_HOUSE_AFTER_HELPING",
  ticketItem = "S_S_TICKET",
}

S.GATE = {
  map = "VERMILION_CITY",
  guardText = "TEXT_VERMILIONCITY_SAILOR1",
  x = 18, y = 30, facing = "down",
  flashedEvent = "EVENT_STADIUM_SS_ANNE_TICKET_FLASHED",
}

S.RIVAL = {
  map = "SS_ANNE_2F",
  y = 8,
  x = { [36] = true, [37] = true },
  text = "TEXT_SSANNE2F_RIVAL",
  event = "EVENT_BEAT_SS_ANNE_RIVAL",
  trainerClass = "OPP_RIVAL2",
  trainerParty = 1,
}

S.CAPTAIN = {
  map = "SS_ANNE_CAPTAINS_ROOM",
  text = "TEXT_SSANNECAPTAINSROOM_CAPTAIN",
  rubbedEvent = "EVENT_RUBBED_CAPTAINS_BACK",
  gotEvent = "EVENT_GOT_HM01",
  item = "HM_CUT",
}

S.SHIP = {
  dockMap = "VERMILION_DOCK",
  shipMap = "SS_ANNE_1F",
  cityMap = "VERMILION_CITY",
  leftEvent = "EVENT_SS_ANNE_LEFT",
  exitX = 18, exitY = 29, exitFacing = "up",
  -- VermilionDockSSAnneLeavesScript writes four lower ship blocks to water.
  departureBlocks = {
    { bx = 5, by = 2, block = 0x0d },
    { bx = 6, by = 2, block = 0x0d },
    { bx = 7, by = 2, block = 0x0d },
    { bx = 8, by = 2, block = 0x0d },
  },
}

function S.billObject(text)
  text = tostring(text or "")
  if text == S.BILL.pokemonText then return "pokemon" end
  if text == S.BILL.ticketText then return "ticket" end
  if text == S.BILL.rareText then return "rare" end
  return nil
end

function S.billPc(mapId, x, y, facing)
  local pc = S.BILL.pc
  return tostring(mapId or "") == S.BILL.map
    and tonumber(x) == pc.x and tonumber(y) == pc.y
    and tostring(facing or "") == pc.facing
end

function S.gateStep(mapId, x, y, facing)
  return tostring(mapId or "") == S.GATE.map
    and tonumber(x) == S.GATE.x and tonumber(y) == S.GATE.y
    and tostring(facing or "") == S.GATE.facing
end

function S.rivalStep(mapId, x, y)
  return tostring(mapId or "") == S.RIVAL.map
    and tonumber(y) == S.RIVAL.y and S.RIVAL.x[tonumber(x)] == true
end

function S.captainObject(mapId, text)
  return tostring(mapId or "") == S.CAPTAIN.map
    and tostring(text or "") == S.CAPTAIN.text
end

function S.guardObject(mapId, text)
  return tostring(mapId or "") == S.GATE.map
    and tostring(text or "") == S.GATE.guardText
end

function S.shipExitTransition(fromMap, toMap)
  return tostring(fromMap or "") == S.SHIP.shipMap
    and tostring(toMap or "") == S.SHIP.dockMap
end

return S
