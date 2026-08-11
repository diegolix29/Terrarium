-- Shared Stadium-style UI scale policy.
--
-- The older custom menus scaled strictly from an 800x600 desktop baseline.
-- On a phone-sized landscape drawable (for example 844x390 logical points)
-- that produced ~0.65x controls even though the user is touching the screen
-- with a finger.  This helper keeps the desktop rule intact but gives
-- Android/iOS a short-side readability floor, while every caller still caps
-- panel width/height against the actual drawable rectangle.

local V = ...
local mod = V and V.mod

local M = {
  platform = nil,
  queries = 0,
}

local function platformName()
  if M.platform ~= nil then return M.platform end
  local ok, Platform = pcall(require, "src.core.Platform")
  if ok and type(Platform) == "table" and type(Platform.detect) == "function" then
    local okDetect, info = pcall(Platform.detect)
    if okDetect and type(info) == "table" and type(info.os) == "string" then
      M.platform = string.lower(info.os)
      return M.platform
    end
  end
  local okOS, name = pcall(function()
    return love and love.system and love.system.getOS and love.system.getOS() or nil
  end)
  M.platform = okOS and type(name) == "string" and string.lower(name) or "unknown"
  return M.platform
end

function M.isMobile()
  local p = platformName()
  return p == "android" or p == "ios"
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

-- minScale/maxScale let each renderer retain its historical bounds.
-- `maxScale` defaults to 1 for menu chrome; dialogue can deliberately pass a
-- larger value.  The phone floor is based on logical points, not physical
-- pixels, so Retina density cannot make the UI absurdly large.
function M.scale(ww, wh, minScale, maxScale)
  M.queries = M.queries + 1
  ww, wh = tonumber(ww) or 800, tonumber(wh) or 600
  minScale = tonumber(minScale) or 0.18
  maxScale = tonumber(maxScale) or 1

  local base = math.min(ww / 800, wh / 600)
  if M.isMobile() then
    local short = math.max(1, math.min(ww, wh))
    -- 430 logical points is roughly the short side of a modern large iPhone
    -- in landscape.  A 390-point phone therefore lands around 0.91 instead of
    -- the old 0.65, while tablets and desktop-sized mobile windows still obey
    -- the caller's cap.
    local touchFloor = short / 430
    base = math.max(base, touchFloor)
  end
  return clamp(base, minScale, maxScale)
end

function M.status()
  return { platform = platformName(), mobile = M.isMobile(), queries = M.queries }
end

return M
