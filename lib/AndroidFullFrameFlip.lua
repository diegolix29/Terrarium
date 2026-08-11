-- Mobile whole-frame orientation compatibility.
--
-- Android keeps the historical manual `screenFlip` emergency helper.
--
-- iOS is native-first and NEVER auto-rotates the finished Game2 frame.  The
-- old v0.3.67 path watched love.window.getDisplayOrientation and applied a
-- second 180-degree canvas transform for `landscapeFlipped`; on modern UIKit /
-- SDL that can invert an already-correct iPhone frame.  Instead, when
-- IPHONE ORIENTATION FIX is ON we explicitly tell SDL that the normal iPhone
-- orientations are Portrait + LandscapeLeft + LandscapeRight.  UIKit remains
-- the sole owner of the framebuffer, touch transform, safe area and rotation.
--
-- The hint is written under both names used by Gen1Recomp's mobile runtimes:
-- SDL3/iOS reads SDL_ORIENTATIONS, while older SDL2 builds use
-- SDL_IOS_ORIENTATIONS.  Current Gen1Recomp also exposes src.core.Orientation;
-- that is used as a guarded fallback when direct FFI is unavailable.
--
-- `iosForceFlip` remains an explicit emergency escape hatch.  Only that
-- manual option can rotate iOS by 180 degrees, and its touch coordinates are
-- remapped by the same inverse transform.

local V = ...
local mod = V and V.mod

local M = {
  installed = false,
  frames = 0,
  touches = 0,
  moves = 0,
  releases = 0,
  orientationQueries = 0,
  orientationChanges = 0,
  lastOrientation = nil,
  lastFlipReason = nil,
  lastError = nil,
  iosNativeAttempts = 0,
  iosNativeApplied = false,
  iosNativePath = nil,
  iosNativeError = nil,
}

local platformCached = nil
local function platformName()
  if platformCached ~= nil then return platformCached end

  local okPlatform, Platform = pcall(require, "src.core.Platform")
  if okPlatform and type(Platform) == "table" and type(Platform.detect) == "function" then
    local okDetect, info = pcall(Platform.detect)
    if okDetect and type(info) == "table" and type(info.os) == "string" then
      local name = string.lower(info.os)
      if name == "android" then platformCached = "Android"
      elseif name == "ios" then platformCached = "iOS"
      else platformCached = info.os end
      return platformCached
    end
  end

  local okOS, name = pcall(function()
    local sys = love and love.system
    if sys and type(sys.getOS) == "function" then return sys.getOS() end
    return nil
  end)
  if okOS and type(name) == "string" then
    local lower = string.lower(name)
    if lower == "android" then platformCached = "Android"
    elseif lower == "ios" then platformCached = "iOS"
    else platformCached = name end
    return platformCached
  end

  local platform = rawget(_G, "PLATFORM")
  if type(platform) == "string" then
    local lower = string.lower(platform)
    if lower == "android" then platformCached = "Android"
    elseif lower == "ios" then platformCached = "iOS"
    else platformCached = platform end
  else
    platformCached = "unknown"
  end
  return platformCached
end

local function isAndroid() return platformName() == "Android" end
local function isIOS() return platformName() == "iOS" end
local function isMobile() return isAndroid() or isIOS() end

local optionOwner, optionFn, optionTrusted = nil, nil, false
local function optionValue(key)
  local options = mod and mod.options
  local fn = options and type(options.get) == "function" and options.get or nil
  if options ~= optionOwner or fn ~= optionFn then
    optionOwner, optionFn, optionTrusted = options, fn, false
  end
  if not fn then return nil end
  if optionTrusted then return fn(options, key) end
  local ok, value = pcall(fn, options, key)
  if ok then
    optionTrusted = true
    return value
  end
  M.lastError = tostring(value)
  return nil
end

local function androidManualEnabled()
  return isAndroid() and optionValue("screenFlip") == true
end

local function iosFixEnabled()
  if not isIOS() then return false end
  local value = optionValue("iosOrientationFix")
  return value ~= false
end

local function iosForceFlipEnabled()
  return isIOS() and optionValue("iosForceFlip") == true
end

-- Diagnostic only.  This value never decides whether the frame is flipped.
-- On iOS the OS/SDL view controller owns the transform; using the orientation
-- string to rotate the already-presented frame was the source of the bug.
local orientationOwner, orientationFn, orientationTrusted = nil, nil, false
local function displayOrientation()
  if not isIOS() then return nil end
  local window = love and love.window
  local fn = window and type(window.getDisplayOrientation) == "function"
    and window.getDisplayOrientation or nil
  if window ~= orientationOwner or fn ~= orientationFn then
    orientationOwner, orientationFn, orientationTrusted = window, fn, false
  end
  if not fn then return nil end

  local value
  if orientationTrusted then
    value = fn()
  else
    local ok, result = pcall(fn)
    if not ok then
      M.lastError = tostring(result)
      return nil
    end
    orientationTrusted = true
    value = result
  end

  M.orientationQueries = M.orientationQueries + 1
  if type(value) ~= "string" then return nil end
  value = string.lower(value):gsub("[^a-z]", "")
  if value ~= M.lastOrientation then
    M.lastOrientation = value
    M.orientationChanges = M.orientationChanges + 1
  end
  return value
end

-- Match mobile/ios/overlays/love-ios.plist: iPhone permits ordinary portrait
-- plus BOTH landscapes, but never PortraitUpsideDown.  Explicitly naming the
-- mask avoids depending on a device's stale system-rotation state.
local IOS_HINT = "Portrait LandscapeLeft LandscapeRight"
local iosNativeAttempted = false

local function setIOSHintDirect()
  local okFfi, ffi = pcall(require, "ffi")
  if not okFfi or type(ffi) ~= "table" or not ffi.C then
    return false, "ffi unavailable"
  end
  if type(ffi.cdef) == "function" then
    -- A duplicate declaration is harmless; LuaJIT may report it as an error
    -- when src.core.Orientation already declared SDL_SetHint, so ignore cdef's
    -- result and try the symbol either way.
    pcall(ffi.cdef, [[int SDL_SetHint(const char *name, const char *value);]])
  end
  local ok, a, b = pcall(function()
    local first = ffi.C.SDL_SetHint("SDL_ORIENTATIONS", IOS_HINT)
    local second = ffi.C.SDL_SetHint("SDL_IOS_ORIENTATIONS", IOS_HINT)
    return first, second
  end)
  if not ok then return false, tostring(a) end
  -- SDL returns a boolean/int, but some FFI test shims return nil.  Reaching
  -- both calls without an exception is enough to know the hint path exists.
  if a == false or a == 0 then
    if b == false or b == 0 then return false, "SDL rejected orientation hints" end
  end
  return true
end

local function setIOSHintViaEngine()
  local ok, Orientation = pcall(require, "src.core.Orientation")
  if not ok or type(Orientation) ~= "table" or type(Orientation.apply) ~= "function" then
    return false, "src.core.Orientation unavailable"
  end
  -- Current Gen1Recomp (commit 8c0d0ace+) supports iOS here.  LANDSCAPE is
  -- the strongest safe fallback for the reported upside-down landscape case:
  -- it explicitly enables BOTH landscape directions and lets UIKit select the
  -- physically upright one.  Direct SDL hinting above is preferred because it
  -- also leaves ordinary portrait available.
  local okApply, applied = pcall(Orientation.apply, "landscape")
  if not okApply then return false, tostring(applied) end
  if applied ~= true then return false, "engine orientation apply declined iOS" end
  return true
end

local function requestIOSNativeOrientation(force)
  if not isIOS() or not iosFixEnabled() then return false end
  if iosNativeAttempted and not force then return M.iosNativeApplied end
  iosNativeAttempted = true
  M.iosNativeAttempts = M.iosNativeAttempts + 1
  M.iosNativeApplied = false
  M.iosNativePath = nil
  M.iosNativeError = nil

  local okDirect, directErr = setIOSHintDirect()
  if okDirect then
    M.iosNativeApplied = true
    M.iosNativePath = "sdl-mask"
    return true
  end

  local okEngine, engineErr = setIOSHintViaEngine()
  if okEngine then
    M.iosNativeApplied = true
    M.iosNativePath = "engine-landscape"
    return true
  end

  M.iosNativeError = tostring(directErr) .. "; " .. tostring(engineErr)
  return false
end

-- Retained as a compatibility probe for existing diagnostics/tests.  The mod
-- no longer infers orientation support from unrelated features such as Silver;
-- an iOS host is considered native when the SDL/engine request actually lands.
local function modernNativeIOSOrientation()
  if not isIOS() then return false end
  return requestIOSNativeOrientation(false)
end

local function effectiveFlip()
  if androidManualEnabled() then
    return true, "android-manual"
  end
  if isIOS() then
    local orientation = displayOrientation()
    if iosForceFlipEnabled() then
      return true, "ios-force-180"
    end
    if iosFixEnabled() then
      local ok = requestIOSNativeOrientation(false)
      return false, ok and ("ios-native-" .. tostring(M.iosNativePath or "mask"))
        or "ios-native-request-failed"
    end
    return false, "ios-fix-disabled-" .. tostring(orientation or "unknown")
  end
  return false, nil
end

local frameCanvas, frameW, frameH
local function ensureCanvas(w, h)
  if frameCanvas and frameW == w and frameH == h then return frameCanvas end
  local G = love and love.graphics
  if not (G and type(G.newCanvas) == "function") then return nil end
  local ok, canvas = pcall(G.newCanvas, w, h)
  if not ok or not canvas then return nil end
  if type(canvas.setFilter) == "function" then
    pcall(canvas.setFilter, canvas, "nearest", "nearest")
  end
  if frameCanvas and frameCanvas ~= canvas and type(frameCanvas.release) == "function" then
    pcall(frameCanvas.release, frameCanvas)
  end
  frameCanvas, frameW, frameH = canvas, w, h
  return canvas
end

local function dimensions()
  local G = love and love.graphics
  if not (G and type(G.getDimensions) == "function") then return nil, nil end
  local w, h = G.getDimensions()
  w, h = tonumber(w), tonumber(h)
  if not (w and h and w > 0 and h > 0) then return nil, nil end
  return math.max(1, math.floor(w + 0.5)), math.max(1, math.floor(h + 0.5))
end

local function remapPointRaw(x, y)
  local w, h = dimensions()
  if not (w and h) then return x, y end
  x, y = tonumber(x) or 0, tonumber(y) or 0
  return w - x, h - y
end

local function remapDeltaRaw(dx, dy)
  return -(tonumber(dx) or 0), -(tonumber(dy) or 0)
end

local function remapPoint(x, y)
  if not effectiveFlip() then return x, y end
  return remapPointRaw(x, y)
end

local function remapDelta(dx, dy)
  if not effectiveFlip() then return dx, dy end
  return remapDeltaRaw(dx, dy)
end

function M.install()
  if M.installed then return true end

  local okMobile, onMobile = pcall(isMobile)
  if not okMobile or not onMobile then
    M.installed = true
    M.platformActive = false
    if not okMobile then M.lastError = tostring(onMobile) end
    return true
  end
  M.platformActive = true
  M.platform = platformName()

  -- Apply the iOS mask before the first patched Game2 frame.  A failed request
  -- intentionally does NOT trigger an automatic 180-degree fallback; that is
  -- safer than double-rotating every iPhone.  IPHONE FORCE 180 is explicit.
  if isIOS() and iosFixEnabled() then requestIOSNativeOrientation(true) end

  local ok, Game2 = pcall(require, "src.core.Game2")
  if not (ok and type(Game2) == "table" and type(Game2.draw) == "function") then
    return false, "src.core.Game2.draw unavailable"
  end
  if Game2._stadium2WholeFrameFlipPatched then
    M.installed = true
    return true
  end

  local nativeDraw = Game2.draw
  Game2.draw = function(self, ...)
    local flip, reason = effectiveFlip()
    M.lastFlipReason = reason
    if not flip then return nativeDraw(self, ...) end

    local G = love and love.graphics
    if not (G and type(G.setCanvas) == "function" and type(G.draw) == "function") then
      return nativeDraw(self, ...)
    end
    local w, h = dimensions()
    local canvas = w and ensureCanvas(w, h) or nil
    if not canvas then return nativeDraw(self, ...) end

    local previous = nil
    if type(G.getCanvas) == "function" then
      local okPrev, value = pcall(G.getCanvas)
      if okPrev then previous = value end
    end

    G.push("all")
    G.setCanvas(canvas)
    G.origin()
    G.clear(0, 0, 0, 1)

    local okDraw, err = pcall(nativeDraw, self, ...)

    G.setCanvas(previous)
    G.origin()
    G.setShader()
    G.setScissor()
    G.setBlendMode("alpha")
    G.setColor(1, 1, 1, 1)
    G.draw(canvas, w, h, math.pi)
    G.pop()

    if not okDraw then
      M.lastError = tostring(err)
      error(err, 0)
    end
    M.frames = M.frames + 1
    M.lastError = nil
  end

  local nativePressed = Game2.touchpressed
  if type(nativePressed) == "function" then
    Game2.touchpressed = function(self, id, x, y, dx, dy, pressure, ...)
      if effectiveFlip() then
        x, y = remapPointRaw(x, y)
        dx, dy = remapDeltaRaw(dx, dy)
        M.touches = M.touches + 1
      end
      return nativePressed(self, id, x, y, dx, dy, pressure, ...)
    end
  end

  local nativeMoved = Game2.touchmoved
  if type(nativeMoved) == "function" then
    Game2.touchmoved = function(self, id, x, y, dx, dy, pressure, ...)
      if effectiveFlip() then
        x, y = remapPointRaw(x, y)
        dx, dy = remapDeltaRaw(dx, dy)
        M.moves = M.moves + 1
      end
      return nativeMoved(self, id, x, y, dx, dy, pressure, ...)
    end
  end

  local nativeReleased = Game2.touchreleased
  if type(nativeReleased) == "function" then
    Game2.touchreleased = function(self, id, x, y, dx, dy, pressure, ...)
      if effectiveFlip() then
        x, y = remapPointRaw(x, y)
        dx, dy = remapDeltaRaw(dx, dy)
        M.releases = M.releases + 1
      end
      return nativeReleased(self, id, x, y, dx, dy, pressure, ...)
    end
  end

  -- Re-apply immediately when the compatibility toggle is changed live.
  if mod and mod.events and type(mod.events.on) == "function" then
    pcall(mod.events.on, mod.events, "mod.options_changed", function(payload)
      if type(payload) ~= "table" then return end
      if payload.mod ~= nil and payload.mod ~= mod.id then return end
      if payload.key == "iosOrientationFix" and isIOS() then
        iosNativeAttempted = false
        if payload.value ~= false then requestIOSNativeOrientation(true) end
      end
    end)
  end

  Game2._stadium2WholeFrameFlipPatched = true
  M.installed = true
  return true
end

M.enabled = function() return effectiveFlip() end
M.effectiveFlip = effectiveFlip
M.displayOrientation = displayOrientation
M.androidManualEnabled = androidManualEnabled
M.iosFixEnabled = iosFixEnabled
M.iosForceFlipEnabled = iosForceFlipEnabled
M.modernNativeIOSOrientation = modernNativeIOSOrientation
M.requestIOSNativeOrientation = requestIOSNativeOrientation
M.remapPoint = remapPoint
M.remapDelta = remapDelta

function M.status()
  local flip, reason = effectiveFlip()
  return {
    installed = M.installed,
    enabled = flip,
    flipReason = reason,
    frames = M.frames,
    touches = M.touches,
    moves = M.moves,
    releases = M.releases,
    orientationQueries = M.orientationQueries,
    orientationChanges = M.orientationChanges,
    orientation = M.lastOrientation,
    iosNativeAttempts = M.iosNativeAttempts,
    iosNativeApplied = M.iosNativeApplied,
    iosNativePath = M.iosNativePath,
    iosNativeError = M.iosNativeError,
    lastError = M.lastError,
    platformActive = M.platformActive == true,
    platform = M.platform or platformName(),
    width = frameW,
    height = frameH,
  }
end

return M
