-- Gen4StartMenuHook: puts the TERRARIUM BATTLES row on Platinum's start menu.
--
-- WHY IT WAS MISSING
--
-- Every other version's start menu runs its finished row list through the
-- engine's `ui.start_menu.items` hook, which is how BattleSettings adds
-- TERRARIUM BATTLES (src/ui/StartMenu.lua, src/ui/Gen3StartMenu.lua). Gen 4's
-- menu (src/ui/Gen4StartMenu.lua) builds its rows from the cartridge's own list
-- and never calls the hook, so the mod's row simply never appeared there.
--
-- WHAT THIS DOES (engine files untouched)
--
--   * new    after the engine builds the menu, insert the row before OPTIONS,
--            the same place the Game Boy menus put it.
--   * select the injected row pops the menu and runs its onSelect, exactly as
--            Gen 1's generic StartMenu does, so BattleSettings' own return
--            logic (BACK -> reopen the start menu) works unchanged.
--   * layout Platinum's panel is sized for its seven rows and its short labels:
--            an eighth row would run off the 192px screen, and a long label
--            would run off the right edge. So the panel widens leftwards to fit
--            the widest label, and once there are more rows than fit the list
--            scrolls with the cursor.
--
-- The hook is deliberately NOT the general `ui.start_menu.items` seam: other
-- mods on that hook add rows meant for the Game Boy games (fly menus, teleport
-- lists), which do not belong on a Platinum menu.

local Hook = { installed = false, factory = nil }

local SCREEN_H = 192

local function log(level, fmt, ...)
  local ok, Logger = pcall(require, "src.core.Logger")
  if ok and Logger and Logger[level] then pcall(Logger[level], fmt, ...) end
end

local function isGen4()
  local ok, GameVersion = pcall(require, "src.core.GameVersion")
  if not (ok and GameVersion and GameVersion.generation) then return false end
  local okGen, value = pcall(GameVersion.generation)
  return okGen and tonumber(value) == 4
end

-- How many rows fit below the panel's top edge at this layout.
local function capacity(L)
  local top = math.floor((L.panelY or 8) / 8)
  local rowTiles = L.rowTiles or 3
  return math.max(1, math.floor((SCREEN_H / 8 - top) / rowTiles))
end

-- Grow the panel to the left until the widest label fits between the icon
-- column and the right edge. Copies the layout: the record it came from is the
-- cartridge's own and is shared.
local function widen(self)
  local L0 = self.layout
  local okFont, Font = pcall(require, "src.render.Font")
  if not (okFont and Font and Font.width and L0) then return end
  local widest = 0
  for _, row in ipairs(self.rows) do
    local ok, w = pcall(Font.width, row.label or "")
    if ok and type(w) == "number" and w > widest then widest = w end
  end
  local avail = (L0.panelX + L0.panelW - 6) - (L0.iconX + 14)
  if widest <= avail then return end
  local grow = math.ceil((widest - avail) / 8) * 8
  grow = math.min(grow, math.max(0, math.floor((L0.panelX - 8) / 8) * 8))
  if grow <= 0 then return end
  local L = {}
  for k, v in pairs(L0) do L[k] = v end
  L.panelX = L0.panelX - grow
  L.panelW = L0.panelW + grow
  L.iconX = L0.iconX - grow
  L.cursorX = L0.cursorX - grow
  self.layout = L
end

local function inject(self)
  if not (Hook.factory and isGen4()) then return end
  for _, row in ipairs(self.rows) do
    if row.entry and row.entry.__terrariumBattleEntry then return end
  end
  local ok, entry = pcall(Hook.factory, self.game)
  if not (ok and type(entry) == "table" and type(entry.label) == "string"
          and type(entry.onSelect) == "function") then
    log("warn", "gen4 start menu hook: no usable battle entry (%s)", tostring(entry))
    return
  end
  local at = #self.rows + 1
  for i, row in ipairs(self.rows) do
    if row.id == "options" then at = i break end
  end
  table.insert(self.rows, at, {
    id = "terrariumBattles", label = entry.label, icon = nil, entry = entry,
  })
  widen(self)
end

function Hook.install(factory)
  Hook.factory = factory
  if Hook.installed then return true end
  local ok, Menu = pcall(require, "src.ui.Gen4StartMenu")
  if not (ok and type(Menu) == "table" and type(Menu.new) == "function") then
    return false      -- not a Gen 4 build of the engine
  end
  Hook.Menu = Menu
  Hook.original = { new = Menu.new, select = Menu.select, drawPanel = Menu.drawPanel }

  Menu.new = function(...)
    local self = Hook.original.new(...)
    if type(self) == "table" and type(self.rows) == "table" then
      local okInject, err = pcall(inject, self)
      if not okInject then log("warn", "gen4 start menu hook failed: %s", tostring(err)) end
    end
    return self
  end

  Menu.select = function(self, ...)
    local row = self.rows and self.rows[self.index]
    if not (row and row.entry) then return Hook.original.select(self, ...) end
    -- Same contract as Gen 1's generic StartMenu: pop first, then run the row.
    self.game.stack:pop()
    local okRun, err = pcall(row.entry.onSelect)
    if not okRun then
      log("warn", "gen4 start menu: '%s' failed: %s", tostring(row.label), tostring(err))
      pcall(self:reopen())
    end
  end

  -- More rows than the panel can hold: draw a window of them that follows the
  -- cursor. drawPanel reads self.rows / self.index, so swap in the window for
  -- the call and put the real ones back.
  Menu.drawPanel = function(self, ...)
    local total = #self.rows
    local cap = capacity(self.layout or {})
    if total <= cap then return Hook.original.drawPanel(self, ...) end
    local scroll = self.terrariumScroll or 0
    if self.index <= scroll then scroll = self.index - 1 end
    if self.index > scroll + cap then scroll = self.index - cap end
    scroll = math.max(0, math.min(scroll, total - cap))
    self.terrariumScroll = scroll
    local rows, index, window = self.rows, self.index, {}
    for i = 1, cap do window[i] = rows[scroll + i] end
    self.rows, self.index = window, index - scroll
    local ok, err = pcall(Hook.original.drawPanel, self, ...)
    self.rows, self.index = rows, index
    if not ok then error(err, 0) end
  end

  Hook.installed = true
  return true
end

function Hook.uninstall()
  if not Hook.installed then return end
  local M, o = Hook.Menu, Hook.original
  M.new, M.select, M.drawPanel = o.new, o.select, o.drawPanel
  Hook.installed = false
end

return Hook
