-- START-menu KANTO FREE ROAM / RETURN TO JOHTO action (v0.3.30).
--
-- This is an action row, not a persisted toggle. TwinRegionWorld owns the
-- excursion and deliberately leaves Gold's real world/save position untouched.
-- A second press from Kanto returns to that exact hidden Gold location.
local V = ...
local mod = V and V.mod
local Twin = V and V.TwinRegionWorld

local M = { installed = false, uses = 0, returns = 0, lastError = nil }

local function alreadyPresent(items)
  for _, item in ipairs(items or {}) do
    if type(item) == "table" and item._stadium2PalletTeleport then return true end
  end
  return false
end

local function insertAfterModSettings(items, row)
  local hasSettings = false
  for _, item in ipairs(items or {}) do
    if type(item) == "table" and item._stadium2DirectModSettings then
      hasSettings = true
      break
    end
  end
  local out, inserted = {}, false
  for _, item in ipairs(items or {}) do
    out[#out + 1] = item
    local target = type(item) == "table" and
      ((hasSettings and item._stadium2DirectModSettings)
       or (not hasSettings and item.value == "option"))
    if not inserted and target then
      out[#out + 1] = row
      inserted = true
    end
  end
  if not inserted then out[#out + 1] = row end
  return out
end

local function closeStartMenu(game)
  local stack = game and game.stack
  if stack and type(stack.pop) == "function" then
    pcall(stack.pop, stack)
  end
end

function M.activate(game)
  if not (Twin and type(Twin.toggleTeleport) == "function") then
    M.lastError = "TwinRegionWorld teleport API unavailable"
    return false, M.lastError
  end
  local wasAway = type(Twin.excursionIsActive) == "function"
    and Twin.excursionIsActive() == true
  local ok, result, err = pcall(Twin.toggleTeleport, game)
  if not ok then
    M.lastError = tostring(result)
    if mod and mod.log then mod.log:warn("Pallet teleport failed: %s", M.lastError) end
    return false, M.lastError
  end
  if result == false then
    M.lastError = tostring(err or "Pallet teleport unavailable")
    if mod and mod.log then mod.log:warn("Pallet teleport unavailable: %s", M.lastError) end
    return false, M.lastError
  end
  if wasAway then M.returns = M.returns + 1 else M.uses = M.uses + 1 end
  M.lastError = nil
  closeStartMenu(game)
  return true
end

function M.install()
  if M.installed then return true end
  if not (mod and mod.hooks and type(mod.hooks.wrap) == "function") then
    return false, "mod.hooks:wrap unavailable"
  end
  if not (Twin and type(Twin.toggleTeleport) == "function") then
    return false, "TwinRegionWorld teleport API unavailable"
  end
  local ok, err = pcall(function()
    mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
      local out = next(game, items)
      if type(out) ~= "table" or alreadyPresent(out) then return out end
      local away = type(Twin.excursionIsActive) == "function"
        and Twin.excursionIsActive() == true
      local row = {
        label = away and "RETURN TO JOHTO" or "KANTO FREE ROAM",
        desc = away and { "Return to", "Gold location" }
          or { "Yellow Kanto", "Free roam" },
        _stadium2PalletTeleport = true,
        onSelect = function(selectedGame)
          M.activate(selectedGame or game)
        end,
      }
      return insertAfterModSettings(out, row)
    end)
  end)
  if not ok then return false, tostring(err) end
  M.installed = true
  return true
end

function M.status()
  return {
    installed = M.installed, uses = M.uses, returns = M.returns,
    active = Twin and Twin.excursionIsActive and Twin.excursionIsActive() or false,
    label = Twin and Twin.teleportLabel and Twin.teleportLabel() or "KANTO FREE ROAM",
    lastError = M.lastError,
  }
end

return M
