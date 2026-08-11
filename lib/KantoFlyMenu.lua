-- START-menu KANTO FLY action (v0.3.34).
-- Uses Gold/Silver's party + STORM Badge authority but Yellow's imported
-- fly_warp landing coordinates. It exists only while KANTO FREE ROAM is active.
local V = ...
local mod = V and V.mod
local Twin = V and V.TwinRegionWorld

local M = { installed = false, opens = 0, flights = 0, lastError = nil }

local function closeStartMenu(game)
  local stack = game and game.stack
  if stack and type(stack.pop) == "function" then pcall(stack.pop, stack) end
end

local function say(game, text)
  local TextBox = mod and mod.ui and mod.ui.TextBox
  if not (game and game.stack and TextBox and type(TextBox.new) == "function") then return false end
  local ok, box = pcall(TextBox.new, game, tostring(text))
  if ok and box then game.stack:push(box); return true end
  return false
end

function M.open(game)
  if not (Twin and Twin.excursionIsActive and Twin.excursionIsActive()) then
    return false, "Kanto free roam is not active"
  end
  if not (mod and mod.ui and mod.ui.ListMenu and type(mod.ui.ListMenu.new) == "function") then
    return false, "ListMenu unavailable"
  end
  local points, err = Twin.kantoFlyPoints(game)
  if type(points) ~= "table" or #points == 0 then
    closeStartMenu(game)
    say(game, err or "No visited Kanto Fly points yet.")
    return false, err
  end
  local items = {}
  for _, point in ipairs(points) do
    items[#items + 1] = { label = tostring(point.name), value = point.id }
  end
  items[#items + 1] = { label = "CANCEL", value = nil }
  closeStartMenu(game)
  local menu
  menu = mod.ui.ListMenu.new(game, "KANTO FLY", items, {
    pageJump = true,
    onChoose = function(item, m)
      if not item or item.value == nil then
        if m and m.close then m:close() end
        return
      end
      local ok, why = Twin.kantoFlyTo(game, item.value)
      if m and m.close then m:close() end
      if ok then
        M.flights = M.flights + 1
      else
        M.lastError = tostring(why or "Fly failed")
        say(game, M.lastError)
      end
    end,
  })
  if not menu then return false, "Kanto Fly menu could not be created" end
  game.stack:push(menu)
  M.opens = M.opens + 1
  M.lastError = nil
  return true
end

function M.install()
  if M.installed then return true end
  if not (mod and mod.hooks and type(mod.hooks.wrap) == "function") then
    return false, "mod.hooks:wrap unavailable"
  end
  local ok, err = pcall(function()
    mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
      local out = next(game, items)
      if type(out) ~= "table" or not (Twin and Twin.excursionIsActive and Twin.excursionIsActive()) then
        return out
      end
      for _, item in ipairs(out) do
        if type(item) == "table" and item._stadium2KantoFly then return out end
      end
      local row = {
        label = "KANTO FLY",
        desc = { "Visited Yellow", "Fly points" },
        _stadium2KantoFly = true,
        onSelect = function(selectedGame) M.open(selectedGame or game) end,
      }
      local insertAt = #out + 1
      for i, item in ipairs(out) do
        if type(item) == "table" and item._stadium2PalletTeleport then insertAt = i break end
      end
      table.insert(out, insertAt, row)
      return out
    end)
  end)
  if not ok then return false, tostring(err) end
  M.installed = true
  return true
end

function M.status()
  return { installed = M.installed, opens = M.opens, flights = M.flights, lastError = M.lastError }
end

return M
