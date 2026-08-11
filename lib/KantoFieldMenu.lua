-- START-menu KANTO FIELD action (v0.3.52: Bicycle + story-free physical field actions).
-- Story-free Yellow companion field moves that must operate on Kanto-local
-- location state while still using Gold/Silver's real party + badge authority.
local V = ...
local mod = V and V.mod
local Twin = V and V.TwinRegionWorld

local M = { installed = false, opens = 0, uses = 0, lastAction = nil, lastError = nil }

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
  local rows = Twin.kantoFieldActions and Twin.kantoFieldActions(game) or {}
  closeStartMenu(game)
  if type(rows) ~= "table" or #rows == 0 then
    say(game, "No usable Kanto field moves here.")
    return false, "No usable Kanto field moves here"
  end
  local items = {}
  for _, row in ipairs(rows) do
    items[#items + 1] = { label = tostring(row.label or row.id), value = row.id }
  end
  items[#items + 1] = { label = "CANCEL", value = nil }
  local menu
  menu = mod.ui.ListMenu.new(game, "KANTO FIELD", items, {
    pageJump = true,
    onChoose = function(item, m)
      if not item or item.value == nil then
        if m and m.close then m:close() end
        return
      end
      local ok, why = Twin.kantoUseFieldAction(game, item.value)
      if m and m.close then m:close() end
      if ok then
        M.uses = M.uses + 1
        M.lastAction = item.value
        M.lastError = nil
      else
        M.lastError = tostring(why or "Field move failed")
        say(game, M.lastError)
      end
    end,
  })
  if not menu then return false, "Kanto field menu could not be created" end
  game.stack:push(menu)
  M.opens = M.opens + 1
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
        if type(item) == "table" and item._stadium2KantoField then return out end
      end
      local row = {
        label = "KANTO FIELD",
        desc = { "Bike / Fishing / Flash", "Dig / Teleport" },
        _stadium2KantoField = true,
        onSelect = function(selectedGame) M.open(selectedGame or game) end,
      }
      local insertAt = #out + 1
      -- Put it immediately after KANTO FLY when that row exists, otherwise
      -- before RETURN TO JOHTO.
      for i, item in ipairs(out) do
        if type(item) == "table" and item._stadium2KantoFly then insertAt = i + 1 end
      end
      if insertAt == #out + 1 then
        for i, item in ipairs(out) do
          if type(item) == "table" and item._stadium2PalletTeleport then insertAt = i break end
        end
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
  return {
    installed = M.installed, opens = M.opens, uses = M.uses,
    lastAction = M.lastAction, lastError = M.lastError,
  }
end

return M
