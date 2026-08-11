-- User-selectable controller family for this mod's custom UI.
--
-- LÖVE/SDL reports mapped face buttons by POSITION (south=a, east=b,
-- west=x, north=y). Xbox and PlayStation confirm from south/cancel from east;
-- Nintendo's UI convention is the opposite: physical A (east) confirms and
-- physical B (south) cancels.  Keep battle command positions stable while
-- changing the displayed glyph/letter family and the menu A/B navigation map.

local V = ...
local mod = V and V.mod

local M = {
  installed = false,
  game = nil,
  applications = 0,
  lastLayout = nil,
}

local LAYOUTS = {
  playstation = {
    id = "playstation", name = "PLAYSTATION",
    confirm = { logical = "a", label = "CROSS", kind = "cross" },
    cancel  = { logical = "b", label = "CIRCLE", kind = "circle" },
    west    = { logical = "x", label = "SQUARE", kind = "square" },
    north   = { logical = "y", label = "TRIANGLE", kind = "triangle" },
    south   = { logical = "a", label = "CROSS", kind = "cross" },
    east    = { logical = "b", label = "CIRCLE", kind = "circle" },
  },
  xbox = {
    id = "xbox", name = "XBOX",
    confirm = { logical = "a", label = "A", kind = "letter" },
    cancel  = { logical = "b", label = "B", kind = "letter" },
    west    = { logical = "x", label = "X", kind = "letter" },
    north   = { logical = "y", label = "Y", kind = "letter" },
    south   = { logical = "a", label = "A", kind = "letter" },
    east    = { logical = "b", label = "B", kind = "letter" },
  },
  switch = {
    id = "switch", name = "NINTENDO SWITCH",
    -- SDL's south/east names remain a/b. Nintendo labels those physical
    -- positions B/A, so menu confirm/cancel are intentionally reversed here.
    confirm = { logical = "b", label = "A", kind = "letter" },
    cancel  = { logical = "a", label = "B", kind = "letter" },
    west    = { logical = "x", label = "Y", kind = "letter" },
    north   = { logical = "y", label = "X", kind = "letter" },
    south   = { logical = "a", label = "B", kind = "letter" },
    east    = { logical = "b", label = "A", kind = "letter" },
  },
}

local function normalize(value)
  value = tostring(value or "playstation"):lower()
  if value == "ps" or value == "ps4" or value == "ps5" then return "playstation" end
  if value == "nintendo" or value == "nx" then return "switch" end
  if value ~= "playstation" and value ~= "xbox" and value ~= "switch" then
    return "playstation"
  end
  return value
end

function M.current()
  local value = "playstation"
  local options = mod and mod.options
  if options and type(options.get) == "function" then
    local ok, got = pcall(options.get, options, "controllerLayout")
    if ok and got ~= nil then value = got end
  end
  return normalize(value)
end

function M.spec()
  return LAYOUTS[M.current()] or LAYOUTS.playstation
end

function M.face(role)
  return M.spec()[role] or LAYOUTS.playstation[role]
end

function M.confirmButton()
  return M.spec().confirm.logical
end

function M.cancelButton()
  return M.spec().cancel.logical
end

function M.confirmLabel()
  return M.spec().confirm.label
end

function M.cancelLabel()
  return M.spec().cancel.label
end

function M.layoutName()
  return M.spec().name
end

-- Replace the old mixed-family hints everywhere the custom glass UI uses them.
function M.prompt(text)
  text = tostring(text or "")
  text = text:gsub("CROSS/A", M.confirmLabel())
  text = text:gsub("CIRCLE/B", M.cancelLabel())
  return text
end

function M.navPrompt(prefix)
  local text = prefix or "D-PAD / ARROWS SELECT"
  return text .. "    " .. M.confirmLabel() .. " CONFIRM    "
    .. M.cancelLabel() .. " BACK"
end

local function applyBindingMap(input, layout)
  input.padBindings = input.padBindings or {}
  input.joyBindings = input.joyBindings or {}
  layout = layout or M.current()
  if layout == "switch" then
    input.padBindings.a = "b" -- south / Nintendo B -> GB B (back)
    input.padBindings.b = "a" -- east  / Nintendo A -> GB A (confirm)
    input.joyBindings[1] = "b"
    input.joyBindings[2] = "a"
  else
    input.padBindings.a = "a"
    input.padBindings.b = "b"
    input.joyBindings[1] = "a"
    input.joyBindings[2] = "b"
  end
end

local function installBindingGuard(input)
  if type(input) ~= "table" or input._stadium2ControllerLayoutApplyGuard then
    return
  end
  if type(input.applyBindings) ~= "function" then return end
  local native = input.applyBindings
  input.applyBindings = function(self, ...)
    local a, b, c = native(self, ...)
    -- The engine reapplies saved bindings after boot and when the Controls
    -- screen changes a binding. Reassert only the selected A/B family after
    -- that refresh so Nintendo confirm/back cannot silently fall back to the
    -- desktop Xbox-style mapping mid-session.
    applyBindingMap(self, M.current())
    return a, b, c
  end
  input._stadium2ControllerLayoutApplyGuard = true
end

local function applyInput(game, clearHeld)
  local input = game and game.input
  if type(input) ~= "table" then return false, "no live input" end
  installBindingGuard(input)

  local layout = M.current()
  if clearHeld and type(input.reset) == "function" then
    -- The option itself is usually changed with a face button. Reset before
    -- changing its meaning so that button's later release cannot leave the old
    -- GB A/B source stuck down. The next physical press uses the new layout.
    pcall(input.reset, input)
  end

  applyBindingMap(input, layout)

  M.game = game
  M.lastLayout = layout
  M.applications = M.applications + 1
  return true
end

function M.apply(game, clearHeld)
  game = game or M.game
  return applyInput(game, clearHeld == true)
end

function M.install()
  if M.installed then return true end
  if mod and mod.events and type(mod.events.on) == "function" then
    mod.events:on("game.ready", function(game)
      pcall(M.apply, game, false)
    end)
    mod.events:on("save.loaded", function()
      pcall(M.apply, M.game, false)
    end)
    mod.events:on("mod.options_changed", function(payload)
      if type(payload) ~= "table" then return end
      if payload.mod ~= nil and mod and payload.mod ~= mod.id then return end
      if payload.key == "controllerLayout" then
        pcall(M.apply, M.game, true)
      end
    end)
  end
  M.installed = true
  -- On hot reload, game.ready may have fired already.
  local game = mod and mod.world and mod.world.game or nil
  if game then pcall(M.apply, game, false) end
  return true
end

function M.status()
  return {
    installed = M.installed,
    layout = M.current(),
    appliedLayout = M.lastLayout,
    applications = M.applications,
    confirm = M.confirmLabel(),
    cancel = M.cancelLabel(),
  }
end

M.LAYOUTS = LAYOUTS
M.normalize = normalize
return M
