-- Compatibility shim for Gen1Recomp's GameViewport + mobile TouchSkin layers.
--
-- There are TWO rectangles to keep distinct on current mobile builds:
--   1. GameViewport: the game-owned rectangle inside the OS window.
--   2. TouchSkin.viewport: the drawable gameplay rectangle inside that game
--      viewport after Android/iOS controls reserve screen space.
--
-- LOVE's window/touch APIs describe the OS/game-viewport surface, while the
-- renderer sizes the actual overworld against the TouchSkin drawable. A custom
-- world pipeline that stretches that smaller world view across the full phone
-- framebuffer looks zoomed/cropped. These helpers mirror the engine's own
-- Renderer.displayMetrics ordering so custom 3D output uses the same rectangle.
--
-- Older Gen1Recomp builds may have neither module. Every helper therefore
-- degrades to the historical whole-window behaviour.

local V = ...

local Compat = {
  checked = false,
  viewport = nil,
  available = false,
  touchChecked = false,
  touchSkin = nil,
  touchAvailable = false,
  localPointCalls = 0,
  outsidePoints = 0,
  outsideDrawablePoints = 0,
  drawableQueries = 0,
}

local function validSize(w, h)
  w, h = tonumber(w), tonumber(h)
  return w and h and w > 0 and h > 0
end

local function finite(v)
  v = tonumber(v)
  return v and v == v and v > -math.huge and v < math.huge
end

local function loadViewport()
  if Compat.checked then return Compat.viewport end
  Compat.checked = true
  local ok, viewport = pcall(require, "src.render.GameViewport")
  if ok and type(viewport) == "table" then
    Compat.viewport = viewport
    Compat.available = true
  end
  return Compat.viewport
end

local function loadTouchSkin()
  if Compat.touchChecked then return Compat.touchSkin end
  Compat.touchChecked = true
  local ok, skin = pcall(require, "src.core.TouchSkin")
  if ok and type(skin) == "table" then
    Compat.touchSkin = skin
    Compat.touchAvailable = true
  end
  return Compat.touchSkin
end

function Compat.active()
  local viewport = loadViewport()
  if not (viewport and type(viewport.active) == "function") then return false end
  local ok, active = pcall(viewport.active)
  return ok and active == true
end

-- Logical LOVE units of the game viewport, BEFORE a TouchSkin viewport is
-- applied. This matches GameViewport.dimensions() in the engine.
function Compat.logicalDimensions()
  local viewport = loadViewport()
  if viewport and type(viewport.dimensions) == "function" then
    local ok, w, h = pcall(viewport.dimensions)
    if ok and validSize(w, h) then return w, h, "viewport" end
  end
  local G = love and love.graphics
  if G and type(G.getDimensions) == "function" then
    local ok, w, h = pcall(G.getDimensions)
    if ok and validSize(w, h) then return w, h, "window" end
  end
  return 1, 1, "fallback"
end

-- Physical framebuffer pixels of the WHOLE game viewport, before TouchSkin
-- reserves its controls. This is intentionally not the final drawable size.
function Compat.pixelDimensions()
  local viewport = loadViewport()
  if viewport and type(viewport.pixelDimensions) == "function" then
    local ok, w, h = pcall(viewport.pixelDimensions)
    if ok and validSize(w, h) then return w, h, "viewport" end
  end
  local G = love and love.graphics
  if G and type(G.getPixelDimensions) == "function" then
    local ok, w, h = pcall(G.getPixelDimensions)
    if ok and validSize(w, h) then return w, h, "window-pixel" end
  end
  if G and type(G.getDimensions) == "function" then
    local ok, w, h = pcall(G.getDimensions)
    if ok and validSize(w, h) then return w, h, "window" end
  end
  return 1, 1, "fallback"
end

-- The exact physical gameplay rectangle Renderer.displayMetrics() uses after
-- TouchSkin.viewport(pw, ph). Returns:
--   x, y, width, height, fullPixelWidth, fullPixelHeight, source
-- x/y/width/height are integer framebuffer pixels and are clamped to the full
-- game viewport. With no active TouchSkin viewport this is simply the full
-- framebuffer rectangle.
function Compat.drawablePixelRect()
  Compat.drawableQueries = Compat.drawableQueries + 1
  local fullW, fullH, pixelSource = Compat.pixelDimensions()
  fullW, fullH = math.max(1, math.floor(tonumber(fullW) or 1)),
                 math.max(1, math.floor(tonumber(fullH) or 1))

  local x, y, w, h = 0, 0, fullW, fullH
  local source = pixelSource
  local skin = loadTouchSkin()
  if skin and type(skin.viewport) == "function" then
    local ok, sx, sy, sw, sh = pcall(skin.viewport, fullW, fullH)
    if ok and finite(sx) and finite(sy) and validSize(sw, sh) then
      -- Match Renderer.displayMetrics(): viewport coordinates are physical
      -- pixels. Clamp defensively because imported RetroArch skins are user
      -- data and may contain fractional/out-of-range rectangles.
      sx, sy = math.floor(sx), math.floor(sy)
      sw, sh = math.floor(sw), math.floor(sh)
      sx = math.max(0, math.min(sx, fullW - 1))
      sy = math.max(0, math.min(sy, fullH - 1))
      sw = math.max(1, math.min(sw, fullW - sx))
      sh = math.max(1, math.min(sh, fullH - sy))
      x, y, w, h = sx, sy, sw, sh
      source = "touch-skin"
    end
  end
  return x, y, w, h, fullW, fullH, source
end

-- Same drawable rectangle expressed in GameViewport logical LOVE units.
-- Useful for Android camera UI/input, whose callback coordinates are logical
-- while the engine authored TouchSkin.viewport in framebuffer pixels.
function Compat.drawableLogicalRect()
  local lw, lh = Compat.logicalDimensions()
  local x, y, w, h, fullW, fullH, source = Compat.drawablePixelRect()
  local sx = (tonumber(lw) or 1) / math.max(1, fullW)
  local sy = (tonumber(lh) or 1) / math.max(1, fullH)
  return x * sx, y * sy, w * sx, h * sy, lw, lh, source
end

-- Geometry a custom 3D world should render into. `factor` is the user's
-- internal-resolution choice: the scene itself can be lower resolution, but
-- the returned pipeline image must still be normalized to full framebuffer
-- size so Gen1Recomp's 1:1 worldOverride compositor sees the expected canvas.
function Compat.renderGeometry(factor)
  factor = tonumber(factor) or 1
  factor = math.max(0.05, math.min(1, factor))
  local x, y, w, h, fullW, fullH, source = Compat.drawablePixelRect()
  return {
    x = x, y = y, width = w, height = h,
    frameWidth = fullW, frameHeight = fullH,
    renderWidth = math.max(1, math.floor(w * factor + 0.5)),
    renderHeight = math.max(1, math.floor(h * factor + 0.5)),
    factor = factor, source = source,
    cropped = x ~= 0 or y ~= 0 or w ~= fullW or h ~= fullH,
  }
end

-- LOVE touch positions are OS-window coordinates. Game2 normally converts
-- callback input through GameViewport.toLocal before gameplay sees it, but this
-- mod also polls love.touch directly on Android as a reliability fallback. Use
-- this helper only for those physical-touch poll paths; callback coordinates
-- are already local and must not be transformed a second time.
function Compat.toLocal(x, y)
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return nil, nil, false end
  Compat.localPointCalls = Compat.localPointCalls + 1
  local viewport = loadViewport()
  if viewport and type(viewport.toLocal) == "function" then
    local ok, lx, ly, inside = pcall(viewport.toLocal, x, y)
    if ok and tonumber(lx) and tonumber(ly) then
      if inside == false then Compat.outsidePoints = Compat.outsidePoints + 1 end
      return tonumber(lx), tonumber(ly), inside ~= false
    end
  end
  return x, y, true
end

-- Convert a raw OS-window touch into the drawable gameplay rectangle's local
-- coordinates. TouchControls must still be hit-tested in raw window space
-- BEFORE calling this helper, because those controls intentionally live outside
-- the gameplay viewport.
function Compat.toDrawableLocal(x, y)
  local lx, ly, inside = Compat.toLocal(x, y)
  if not inside then return nil, nil, false end
  local dx, dy, dw, dh = Compat.drawableLogicalRect()
  if lx < dx or ly < dy or lx >= dx + dw or ly >= dy + dh then
    Compat.outsideDrawablePoints = Compat.outsideDrawablePoints + 1
    return lx - dx, ly - dy, false
  end
  return lx - dx, ly - dy, true
end

function Compat.status()
  local w, h, source = Compat.logicalDimensions()
  local dx, dy, dw, dh, fpw, fph, drawableSource = Compat.drawablePixelRect()
  return {
    available = Compat.available,
    active = Compat.active(),
    width = w,
    height = h,
    source = source,
    fullPixelWidth = fpw,
    fullPixelHeight = fph,
    drawableX = dx,
    drawableY = dy,
    drawableWidth = dw,
    drawableHeight = dh,
    drawableSource = drawableSource,
    touchSkinAvailable = Compat.touchAvailable,
    localPointCalls = Compat.localPointCalls,
    outsidePoints = Compat.outsidePoints,
    outsideDrawablePoints = Compat.outsideDrawablePoints,
    drawableQueries = Compat.drawableQueries,
  }
end

return Compat
