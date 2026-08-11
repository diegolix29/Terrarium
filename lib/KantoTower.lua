-- Story-free Pokemon Tower physical field rules (v0.3.57).
--
-- This module deliberately owns only presentation-local Kanto state. It does
-- not execute Yellow story scripts or write Yellow flags into the Gold save.
-- Pokemon Tower 5F's purified 2x2 pad is a physical overworld rule: entering
-- it heals once, remaining on it suppresses encounters, stepping off clears
-- the latch, and re-entering heals again.

local M = {
  VERSION = "0.3.57",
  MAP = "POKEMON_TOWER_5F",
  TEXT = "_PokemonTower5FPurifiedZoneText",
  FALLBACK_TEXT = "Entered purified,\nprotected zone!\fYour POKéMON are\nfully healed!",
  steps = 0,
  entries = 0,
  leaves = 0,
}

local CELLS = {
  [10 * 256 + 8] = true,
  [11 * 256 + 8] = true,
  [10 * 256 + 9] = true,
  [11 * 256 + 9] = true,
}

function M.isPurifiedCell(mapId, x, y)
  if tostring(mapId or "") ~= M.MAP then return false end
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return false end
  return CELLS[x * 256 + y] == true
end

-- Returns onPad, entered, left. `state` is the Kanto excursion table, never
-- the Gold save, so the latch is visit-local just like the original RAM event.
function M.step(state, mapId, x, y)
  local onPad = M.isPurifiedCell(mapId, x, y)
  local was = state and state.towerPurifiedZone == true
  if onPad then
    M.steps = M.steps + 1
    if state then state.towerPurifiedZone = true end
    if not was then M.entries = M.entries + 1 end
    return true, not was, false
  end
  if state then state.towerPurifiedZone = false end
  if was then M.leaves = M.leaves + 1 end
  return false, false, was
end

function M.reset(state)
  if state then state.towerPurifiedZone = false end
end

-- White palette-style heal presentation: GBFadeOutToWhite (24 frames),
-- Delay3 x2 (6 frames), then GBFadeInFromWhite (24 frames). Gold's world is
-- already a 160x144 logical pipeline, so this overlay is generation-safe and
-- does not touch the Android/physical framebuffer contract.
local WhiteHeal = {}
WhiteHeal.__index = WhiteHeal
WhiteHeal.isOpaque = false

local OUT_FRAMES, HOLD_FRAMES, IN_FRAMES = 24, 6, 24
local STEP = 8

local function stairOut(t)
  if t < STEP then return 0 end
  if t < STEP * 2 then return 0.5 end
  return 1
end

local function stairIn(t)
  if t < STEP then return 1 end
  if t < STEP * 2 then return 0.5 end
  return 0
end

function WhiteHeal:alpha()
  local t = self.t or 0
  if t < OUT_FRAMES then return stairOut(t) end
  t = t - OUT_FRAMES
  if t < HOLD_FRAMES then return 1 end
  t = t - HOLD_FRAMES
  return stairIn(t)
end

function WhiteHeal:update(_dt)
  self.t = (self.t or 0) + 1
  if self.t < OUT_FRAMES + HOLD_FRAMES + IN_FRAMES then return end
  local stack = self.game and self.game.stack
  if stack and type(stack.pop) == "function" then pcall(stack.pop, stack) end
  if self.onDone then self.onDone() end
end

function WhiteHeal:draw()
  local a = self:alpha()
  if not (love and love.graphics) then return end
  love.graphics.setColor(1, 1, 1, a)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(1, 1, 1, 1)
end

function M.present(game, onDone)
  local stack = game and game.stack
  if not (stack and type(stack.push) == "function") then
    if onDone then onDone() end
    return false
  end
  stack:push(setmetatable({ game = game, onDone = onDone, t = 0 }, WhiteHeal))
  return true
end

function M.resetCounters()
  M.steps, M.entries, M.leaves = 0, 0, 0
end

return M
