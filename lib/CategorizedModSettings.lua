-- Categorized options browser for STADIUM2_OVERWORLD_MODELS.
--
-- Gen1Recomp's ManagerState options_schema support intentionally exposes one
-- flat list.  This mod now has enough controls that the list is unwieldy on a
-- phone, so keep ManagerState as the option/persistence owner but present THIS
-- mod through a small category root.  Entering a category swaps optionRows for
-- a subset built by ManagerState:buildOptionRows(), so toggles, choices,
-- persistence, mod.options_changed and RESET DEFAULTS all keep the engine's
-- existing behavior.

local V = ...
local mod = V and V.mod

local M = {
  installed = false,
  opens = 0,
  categoryOpens = 0,
  lastError = nil,
}

local MOD_ID = (mod and mod.id) or "STADIUM2_OVERWORLD_MODELS"

local function customUIEnabled()
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return true end
  local ok, value = pcall(options.get, options, "customUI")
  if not ok or value == nil then return true end
  return value ~= false
end

-- v0.4.30: user-controlled typography scale for the modern Mod Settings UI.
-- Keep geometry/touch targets independent so larger text does not inflate the
-- slim row height the user chose in v0.4.28-v0.4.29.
local function uiTextScale()
  local options = mod and mod.options
  local percent = 100
  if options and type(options.get) == "function" then
    local ok, value = pcall(options.get, options, "uiTextSize")
    if ok and tonumber(value) then percent = tonumber(value) end
  end
  percent = math.max(75, math.min(160, percent))
  return percent / 100
end

local CATEGORIES = {
  {
    id = "ui", label = "UI / MENUS",
    description = "Switch the custom Stadium-style menus on or return to Gold's originals.",
    keys = { customUI=true, uiTextSize=true, controllerLayout=true, showFpsCounter=true, shoulderSpeedControl=true },
  },
  {
    id = "performance", label = "PERFORMANCE / GRAPHICS",
    description = "PC-style preset plus resolution, shadows, reflections, draw distance and streaming budgets.",
    keys = {
      performancePreset=true, frameRateLimit=true, graphicsResolution=true, graphicsShadows=true,
      graphicsReflections=true, graphicsDrawDistance=true,
      graphicsKantoRadius=true, graphicsBuildRate=true,
    },
  },
  {
    id = "world", label = "WORLD",
    description = "Voxel world, OPEN WORLD, ocean, Kanto, and persistent cache.",
    keys = {
      voxel3d=true, openWorld=true, worldOcean=true, gen1Region=true,
      voxelDiskCache=true,
    },
  },
  {
    id = "weather", label = "WEATHER FX",
    description = "Weather FX 4.10 conditions, 3D/2D presentation, intensity, seasons, lightning and sound.",
    keys = {
      weatherMode=true, quality=true, intensity=true, exotic=true, speed=true,
      daytime=true, seasons=true, hemisphere=true, seasonNotify=true,
      lightning=true, sfx=true, splash=true, indoors=true, present=true,
      debugRain=true,
    },
  },
  {
    id = "camera", label = "CAMERA / DISPLAY",
    description = "Camera ownership/mode plus Android/iPhone display controls.",
    keys = {
      cameraControl=true, cameraMode=true, worldZoomRange=true, cameraSlider=true, screenFlip=true, iosOrientationFix=true, iosForceFlip=true,
    },
  },
  {
    id = "battle", label = "BATTLE",
    description = "Live 3D battles, cinematic camera, battle UI and shortcuts.",
    keys = {
      battleBackgroundFile=true, transparentBattleUI=true, battle3dWorld=true, doubleBattleMode=true,
      stadiumBattleAnimations=true, battleModernMotion=true,
      battleMovementFeel=true, battleImpactFeedback=true,
      battleSmartCamera=true, battleCommands=true, battleShortcutMode=true,
    },
  },
  {
    id = "models", label = "3D MODELS",
    description = "Independent Pokémon/player 3D model layers and Stadium 2 model-pack source.",
    keys = {
      stadium3dSprites=true, customPlayerSprite=true, customPlayerSpriteFile=true,
      player3dModel=true, stadiumRomFile=true,
    },
  },
  {
    id = "mounts", label = "FLY YOUR POKéMON",
    description = "Flight, Ground Ride, Visible Surf, progression, mount rendering and per-species sizing.",
    keys = {
      mountFlightMode=true, mountFlightPokemon=true, mountSettingsView=true,
      mountShowRider=true, mountFlightSpeed=true,
      mountGroundSpeed=true, mountManualAltitude=true, mountVisibleSurf=true,
      mountRealisticSizes=true, mountHints=true, mountCries=true, mountMenu=true,
      mountShowFollowers=true, mountSoundRumble=true, mountVerticalSpeed=true,
      mountAltitudeDisplay=true, mountFlightBoost=true, mountCameraFollow=true,
      mountCameraAltitude=true, mountLandingMarker=true, mountDynamicShadow=true,
      mountAirEncounters=true, ambientFlyingPokemon=true, ambientFlyingDensity=true,
      mountShortcut=true, mountControllerShortcuts=true, mountGroundGallop=true,
      mountGallopHud=true, mountGroundDust=true, mountTwoWayLedges=true,
      mountRemountAfterBattle=true, mountRequireFly=true, mountRequireSurf=true, mountBadgeChecks=true,
      mountStoryGates=true, mountQuestCollisions=true,
      mountRenderer=true, mountFlyingMusic=true, mountSizeOverrides=true,
    },
  },
  {
    id = "wilds", label = "WILD POKéMON",
    description = "Visible wild Pokémon, sprite style, spawn density and terrain rules.",
    keys = {
      enabled=true, sprite_style=true, sprite_fade=true,
      spawn_density=true, random_encounters=true,
      water_spawns=true, cave_spawns=true, town_pokemon=true,
      pokemon_grass_render_mode=true, wild_silhouettes=true,
    },
  },
  {
    id = "followers", label = "FOLLOWERS / BEHAVIOR",
    description = "Lead follower, Pokémon control and roaming behavior.",
    keys = {
      partyFollower=true, follow_control=true, trainer_trail=true,
      follower_count=true, follower_player_spacing=true,
      follower_pokemon_spacing=true, enable_idle=true, enable_wander=true,
      enable_aggressive=true, enable_hidden=true,
    },
  },
  {
    id = "developer", label = "DEVELOPER",
    description = "Debug and diagnostic controls.",
    keys = { dev_overlay=true },
  },
}

local byId = {}
for _, category in ipairs(CATEGORIES) do byId[category.id] = category end

-- The category root is a compact icon grid instead of another long OptionRows
-- list.  ManagerState still owns persistence/actions; the grid only owns the
-- presentation and root-level navigation.
local GRID_PAGE_SIZE = 16
local GRID_COLUMNS = 4
local GRID_ROWS = 4
local PHONE_LANDSCAPE_COLUMNS = 5
local PHONE_PORTRAIT_COLUMNS = 3
-- v0.4.14: every current root tile fits on one screen.  There are thirteen
-- rows today (eleven named categories, OTHER and RESET ALL), so a compact
-- 4x4 grid leaves only three empty cells and removes page switching entirely.

local GRID_STYLE = {
  ui          = { icon="ui",          lines={"UI", "MENUS"} },
  performance = { icon="performance", lines={"PERF", "GFX"} },
  world       = { icon="world",       lines={"WORLD", ""} },
  weather     = { icon="weather",     lines={"WEATHR", "FX"} },
  camera      = { icon="camera",      lines={"CAMERA", "DISPLAY"} },
  battle      = { icon="battle",      lines={"BATTLE", ""} },
  models      = { icon="models",      lines={"3D", "MODELS"} },
  mounts      = { icon="mounts",      lines={"FLY", "PKMN"} },
  wilds       = { icon="wilds",       lines={"WILD", "PKMN"} },
  followers   = { icon="followers",   lines={"FOLLOW", "BEHAVE"} },
  developer   = { icon="developer",   lines={"DEV", "TOOLS"} },
  other       = { icon="other",       lines={"OTHER", ""} },
  reset       = { icon="reset",       lines={"RESET", "ALL"} },
}

local function gridMeta(id, title, count)
  local style = GRID_STYLE[id] or GRID_STYLE.other
  return {
    id = id,
    title = title or id,
    count = count,
    icon = style.icon,
    line1 = style.lines[1],
    line2 = style.lines[2],
  }
end

local function gridRootActive(self)
  return self and self.screen == "options"
    and self._stadium2CategorizedOptions
    and self._stadium2OptionCategory == nil
    and customUIEnabled()
end

local function categoryPageActive(self)
  return self and self.screen == "options"
    and self._stadium2CategorizedOptions
    and self._stadium2OptionCategory ~= nil
    and customUIEnabled()
end

local function mobilePlatform()
  local helper = mod and mod.exports and mod.exports.mobileUiScale
  if helper and type(helper.isMobile) == "function" then
    local ok, value = pcall(helper.isMobile)
    if ok then return value and true or false end
  end
  local ok, name = pcall(function()
    return love and love.system and love.system.getOS and love.system.getOS() or nil
  end)
  name = ok and type(name) == "string" and string.lower(name) or ""
  return name == "android" or name == "ios"
end

local function navigationGridColumns()
  if not mobilePlatform() then return GRID_COLUMNS end
  local w, h = 800, 600
  local G = love and love.graphics
  if G and type(G.getDimensions) == "function" then
    local ok, gw, gh = pcall(G.getDimensions)
    if ok and tonumber(gw) and tonumber(gh) then w, h = gw, gh end
  end
  return w >= h and PHONE_LANDSCAPE_COLUMNS or PHONE_PORTRAIT_COLUMNS
end

local function lastIndexInColumn(n, column, columns)
  local i = n
  while i > 1 and ((i - 1) % columns) ~= column do i = i - 1 end
  return i
end

local function firstIndexInColumn(n, column, columns)
  local i = 1 + column
  return i <= n and i or 1
end

-- Root grid D-pad/keyboard navigation.  Desktop keeps the 4x4 layout.  Phone
-- builds use the same columns the responsive renderer uses (5x3 landscape or
-- 3x5 portrait), so touch-pad D-pad movement matches what is actually shown.
local function updateGridRoot(self, input)
  local rows = self.optionRows or {}
  local n = #rows
  if input and type(input.wasPressed) == "function" and input:wasPressed("b") then
    if type(self.goBack) == "function" then self:goBack() end
    return true
  end
  if n == 0 or not (input and type(input.wasPressed) == "function") then return true end

  local columns = math.max(1, navigationGridColumns())
  local cur = math.max(1, math.min(n, tonumber(self.cursor) or 1))
  local rowStart = math.floor((cur - 1) / columns) * columns + 1
  local rowEnd = math.min(n, rowStart + columns - 1)

  if input:wasPressed("left") then
    if cur > rowStart then cur = cur - 1 else cur = rowEnd end
  elseif input:wasPressed("right") then
    if cur < rowEnd then cur = cur + 1 else cur = rowStart end
  elseif input:wasPressed("up") then
    local column = (cur - 1) % columns
    local candidate = cur - columns
    if candidate < 1 then candidate = lastIndexInColumn(n, column, columns) end
    cur = candidate
  elseif input:wasPressed("down") then
    local column = (cur - 1) % columns
    local candidate = cur + columns
    if candidate > n then candidate = firstIndexInColumn(n, column, columns) end
    cur = candidate
  elseif input:wasPressed("a") then
    local row = rows[cur]
    if row and row.activate then
      if type(self.confirmSound) == "function" then self:confirmSound() end
      row.activate()
    end
    return true
  end

  self.cursor = math.max(1, math.min(n, cur))
  self.scroll = 0
  return true
end

local modernFonts = {}
local gridIconImages = {}
local GRID_ICON_SOURCES = {
  ui = "assets/menu/mod_settings_icons/ui.png",
  performance = "assets/menu/mod_settings_icons/performance.png",
  world = "assets/menu/mod_settings_icons/world.png",
  weather = "assets/menu/mod_settings_icons/weather.png",
  camera = "assets/menu/mod_settings_icons/camera.png",
  battle = "assets/menu/mod_settings_icons/battle.png",
  models = "assets/menu/mod_settings_icons/models.png",
  mounts = "assets/menu/mod_settings_icons/mounts.png",
  wilds = "assets/menu/mod_settings_icons/wilds.png",
  followers = "assets/menu/mod_settings_icons/followers.png",
  developer = "assets/menu/mod_settings_icons/developer.png",
  other = "assets/menu/mod_settings_icons/other.png",
}

local function imageFromBytes(bytes, name)
  if type(bytes) ~= "string" or bytes == "" then return nil end
  if not (love and love.data and type(love.data.newByteData) == "function"
      and love.image and type(love.image.newImageData) == "function"
      and love.graphics and type(love.graphics.newImage) == "function") then
    return nil
  end
  local okBytes, byteData = pcall(love.data.newByteData, bytes)
  if not okBytes or not byteData then return nil end
  pcall(function() byteData.name = name end)
  local okData, imageData = pcall(love.image.newImageData, byteData)
  if not okData or not imageData then return nil end
  local okImage, image = pcall(love.graphics.newImage, imageData)
  if not okImage or not image then return nil end
  return image
end

local function loadGridIconImage(kind)
  local cached = gridIconImages[kind]
  if cached ~= nil then return cached or nil end
  local path = GRID_ICON_SOURCES[kind]
  if not path then
    gridIconImages[kind] = false
    return nil
  end

  -- Packaged mods live in their own sandbox/archive namespace.  A relative
  -- love.graphics.newImage("assets/...") looks in the game filesystem, not
  -- this mod's zip, so it silently missed these icons and fell back to the
  -- vector glyphs.  mod:read is the authoritative packaged-asset API: decode
  -- the returned PNG bytes into ByteData -> ImageData -> Image just like the
  -- Weather FX/background loaders elsewhere in this mod.
  local image = nil
  if mod and type(mod.read) == "function" then
    local okRead, bytes = pcall(mod.read, mod, path)
    if okRead and bytes then image = imageFromBytes(bytes, path) end
  end

  -- Unpacked/development fallback.  assets.path can expose a directly
  -- loadable host path on older engines; raw relative path is last-resort for
  -- headless/local source-tree tests.  Neither path is used when mod:read
  -- succeeded, so packaged builds stay sandbox-safe.
  if not image then
    local candidates = {}
    if mod and mod.assets and type(mod.assets.path) == "function" then
      local okPath, resolved = pcall(mod.assets.path, mod.assets, path)
      if okPath and type(resolved) == "string" and resolved ~= "" then
        candidates[#candidates + 1] = resolved
      end
    end
    candidates[#candidates + 1] = path
    local G = love and love.graphics
    if G and type(G.newImage) == "function" then
      for _, candidate in ipairs(candidates) do
        local ok, got = pcall(G.newImage, candidate)
        if ok and got then image = got break end
      end
    end
  end

  if image then
    if type(image.setFilter) == "function" then
      pcall(image.setFilter, image, "linear", "linear")
    end
    gridIconImages[kind] = image
  else
    gridIconImages[kind] = false
  end
  return gridIconImages[kind] or nil
end

local function controllerPrompt(text)
  local C = mod and mod.exports and mod.exports.controllerLayout
  if C and type(C.prompt) == "function" then
    local ok, value = pcall(C.prompt, text)
    if ok and value then return value end
  end
  return tostring(text or "")
end

local function targetDimensions()
  local G = love and love.graphics
  if not G then return 160, 144 end
  if type(G.getCanvas) == "function" then
    local ok, canvas = pcall(G.getCanvas)
    if ok and canvas and type(canvas.getDimensions) == "function" then
      local w, h = canvas:getDimensions()
      if w and h and w > 0 and h > 0 then return w, h end
    end
  end
  if type(G.getDimensions) == "function" then
    local ok, w, h = pcall(G.getDimensions)
    if ok and w and h and w > 0 and h > 0 then return w, h end
  end
  return 160, 144
end

local function uiScaleFor(ww, wh)
  local helper = mod and mod.exports and mod.exports.mobileUiScale
  if helper and type(helper.scale) == "function" then
    local ok, value = pcall(helper.scale, ww, wh, 0.18, 1.15)
    if ok and tonumber(value) then return tonumber(value) end
  end
  return math.max(0.18, math.min(1.15, math.min(ww / 800, wh / 600)))
end

local function gridLayoutFor(ww, wh, s, n)
  local mobile = mobilePlatform()
  local columns = GRID_COLUMNS
  if mobile then
    -- Current canvas can remain 160x144 even on a portrait phone.  Orientation
    -- must follow the physical drawable/window or the renderer and D-pad would
    -- both think every phone is landscape merely because the game canvas is.
    local ow, oh = ww, wh
    local G = love and love.graphics
    if G and type(G.getDimensions) == "function" then
      local okDims, sw, sh = pcall(G.getDimensions)
      if okDims and tonumber(sw) and tonumber(sh) and sw > 0 and sh > 0 then
        ow, oh = sw, sh
      end
    end
    columns = ow >= oh and PHONE_LANDSCAPE_COLUMNS or PHONE_PORTRAIT_COLUMNS
  end
  local rows = math.max(1, math.ceil(math.max(1, tonumber(n) or 1) / columns))

  local margin, panelW, panelH, x, y
  if mobile then
    -- Phone builds need the whole drawable, not the desktop right drawer.
    -- This is especially important on 844x390/932x430 landscape devices:
    -- squeezing 13 apps into half the width makes both labels and touch targets
    -- too small.  Keep only a safe outer gutter and use 5x3 in landscape or
    -- 3x5 in portrait.
    margin = math.max(5 * s, math.min(ww, wh) * 0.012)
    panelW = math.max(1, ww - margin * 2)
    panelH = math.max(1, wh - margin * 2)
    x, y = margin, margin
  else
    margin = math.max(12 * s, wh * 0.018)
    panelW = math.min(math.max(ww * 0.42, 390 * s), ww * 0.52)
    panelH = math.min(wh - margin * 2, math.max(wh * 0.84, 520 * s))
    if ww < 900 then
      panelW = math.min(math.max(ww * 0.48, 360 * s), ww - margin * 1.5)
    end
    x = ww - panelW - margin
    y = (wh - panelH) * 0.5
  end

  return {
    mobile = mobile,
    columns = columns,
    rows = rows,
    margin = margin,
    panelW = panelW,
    panelH = panelH,
    x = x,
    y = y,
  }
end

local function modernFont(size)
  size = math.max(5, math.floor((tonumber(size) or 10) + 0.5))
  if modernFonts[size] ~= nil then return modernFonts[size] or nil end
  local G = love and love.graphics
  if not (G and type(G.newFont) == "function") then
    modernFonts[size] = false
    return nil
  end
  local ok, f = pcall(G.newFont, size)
  modernFonts[size] = ok and f or false
  return modernFonts[size] or nil
end

local function cleanText(text)
  text = tostring(text or "")
  text = text:gsub("<PO><KE>", "POKé")
  text = text:gsub("<PK><MN>", "POKéMON")
  text = text:gsub("<POKE>", "POKé")
  text = text:gsub("<NEXT>", " ")
  text = text:gsub("[\v\f\r]", " ")
  text = text:gsub("\n", " ")
  text = text:gsub("%s+", " ")
  return text
end

local function clipped(text, f, maxW)
  text = cleanText(text)
  if not f or type(f.getWidth) ~= "function" or f:getWidth(text) <= maxW then
    return text
  end
  local suffix = "..."
  while #text > 0 and f:getWidth(text .. suffix) > maxW do
    text = text:sub(1, -2)
  end
  return text .. suffix
end

local function roundRect(G, mode, x, y, w, h, r)
  if type(G.rectangle) == "function" then G.rectangle(mode, x, y, w, h, r, r) end
end

-- The icons are authored in a tiny 14x14 logical space, then scaled as one
-- vector group.  This keeps the same category symbols crisp in the 160x144
-- fallback and on a 3x phone render without shipping raster icon assets.
local function drawGridIcon(G, kind, x, y, size)
  if not G then return end
  local image = loadGridIconImage(kind)
  if image and type(G.draw) == "function" and type(image.getDimensions) == "function" then
    local iw, ih = image:getDimensions()
    if iw and ih and iw > 0 and ih > 0 then
      local fit = math.min((size or 14) / iw, (size or 14) / ih)
      local dx = x + (((size or 14) - iw * fit) * 0.5)
      local dy = y + (((size or 14) - ih * fit) * 0.5)
      G.draw(image, dx, dy, 0, fit, fit)
      return
    end
  end
  local canTransform = type(G.push) == "function" and type(G.pop) == "function"
    and type(G.translate) == "function" and type(G.scale) == "function"
  local transformed = false
  if canTransform then
    -- Some desktop/mobile LÖVE builds accept push() but not the newer
    -- push("all") stack-type argument.  The RESET vector icon is the only
    -- current root icon that regularly reaches this transform path, so that
    -- incompatibility could crash the whole menu even though all PNG icons
    -- had already drawn correctly.  Use the oldest portable form.
    local okPush = pcall(G.push)
    if okPush then
      local okTranslate = pcall(G.translate, x, y)
      local okScale = pcall(G.scale, size / 14, size / 14)
      if okTranslate and okScale then
        transformed = true
        x, y, size = 0, 0, 14
      else
        pcall(G.pop)
      end
    end
  end

  local s = size
  local cx, cy = x + s * 0.5, y + s * 0.5
  local function line(...) if G.line then G.line(...) end end
  local function rect(mode, ...) if G.rectangle then G.rectangle(mode, ...) end end
  local function circle(mode, ...) if G.circle then G.circle(mode, ...) end end
  local function poly(mode, ...) if G.polygon then G.polygon(mode, ...) end end

  if kind == "ui" then
    rect("line", x + 1, y + 1, s - 2, s - 5)
    line(x + 3, y + s - 2, x + s - 3, y + s - 2)
    line(cx, y + s - 4, cx, y + s - 2)
    rect("fill", x + 3, y + 4, 2, 2)
    rect("fill", x + 7, y + 4, 2, 2)
  elseif kind == "performance" then
    rect("fill", x + 2, y + s - 5, 2, 4)
    rect("fill", x + 6, y + s - 9, 2, 8)
    rect("fill", x + 10, y + s - 13, 2, 12)
    line(x + 1, y + s - 1, x + s - 1, y + s - 1)
  elseif kind == "world" then
    circle("line", cx, cy, s * 0.42)
    line(cx, y + 1, cx, y + s - 1)
    line(x + 1, cy, x + s - 1, cy)
    line(x + 3, y + 4, x + s - 3, y + s - 4)
  elseif kind == "weather" then
    circle("line", x + 5, y + 6, 4)
    circle("line", x + 9, y + 6, 4)
    line(x + 2, y + 9, x + 12, y + 9)
    line(x + 4, y + 11, x + 3, y + 14)
    line(x + 8, y + 11, x + 7, y + 14)
    line(x + 12, y + 11, x + 11, y + 14)
  elseif kind == "camera" then
    rect("line", x + 1, y + 4, s - 2, s - 6)
    rect("line", x + 4, y + 2, 5, 3)
    circle("line", cx, y + 9, 3)
  elseif kind == "battle" then
    line(x + 2, y + 2, x + s - 2, y + s - 2)
    line(x + s - 2, y + 2, x + 2, y + s - 2)
    line(x + 2, y + 8, x + 6, y + 12)
    line(x + 8, y + 12, x + 12, y + 8)
  elseif kind == "models" then
    poly("line", x + 3, y + 4, x + 8, y + 1, x + 13, y + 4,
                 x + 13, y + 10, x + 8, y + 13, x + 3, y + 10)
    line(x + 3, y + 4, x + 8, y + 7, x + 13, y + 4)
    line(x + 8, y + 7, x + 8, y + 13)
  elseif kind == "mounts" then
    line(x + 1, y + 8, x + 5, y + 4, x + 7, y + 8, x + 9, y + 4, x + 13, y + 8)
    line(x + 3, y + 10, x + 6, y + 8, x + 8, y + 10, x + 11, y + 8)
    line(x + 7, y + 10, x + 7, y + 14)
  elseif kind == "wilds" then
    circle("line", cx, cy, s * 0.43)
    line(x + 1, cy, x + s - 1, cy)
    circle("line", cx, cy, 2)
  elseif kind == "followers" then
    circle("line", x + 4, y + 4, 2)
    circle("line", x + 10, y + 5, 2)
    line(x + 4, y + 6, x + 4, y + 12)
    line(x + 10, y + 7, x + 10, y + 13)
    line(x + 2, y + 9, x + 6, y + 9)
    line(x + 8, y + 10, x + 12, y + 10)
  elseif kind == "developer" then
    circle("line", cx, cy, 4)
    circle("fill", cx, cy, 1.5)
    line(cx, y, cx, y + 3)
    line(cx, y + s - 3, cx, y + s)
    line(x, cy, x + 3, cy)
    line(x + s - 3, cy, x + s, cy)
  elseif kind == "reset" then
    line(x + 3, y + 4, x + 10, y + 4, x + 12, y + 6)
    line(x + 12, y + 6, x + 9, y + 6)
    line(x + 12, y + 6, x + 12, y + 3)
    line(x + 11, y + 9, x + 9, y + 12, x + 4, y + 12, x + 2, y + 9)
  else
    circle("fill", x + 3, cy, 1.5)
    circle("fill", cx, cy, 1.5)
    circle("fill", x + s - 3, cy, 1.5)
  end

  if transformed then pcall(G.pop) end
end

local function drawGridRootUnsafe(self, Font, Theme)
  local G = love and love.graphics
  if not G then return false end
  local rows = self.optionRows or {}
  local n = #rows
  local cursor = math.max(1, math.min(math.max(1, n), tonumber(self.cursor) or 1))
  local first = 1
  local ww, wh = targetDimensions()
  if not (ww and wh and ww > 0 and wh > 0) then return false end
  local s = uiScaleFor(ww, wh)
  local ts = uiTextScale()

  local pushed = false
  if type(G.push) == "function" and type(G.pop) == "function" then
    local okPush = pcall(G.push)
    pushed = okPush and true or false
  end
  if type(G.origin) == "function" then G.origin() end
  if type(G.setBlendMode) == "function" then pcall(G.setBlendMode, "alpha") end

  -- Desktop retains the right-side glass drawer.  Mobile uses the full safe
  -- drawable and changes grid shape with orientation so every icon remains a
  -- finger-sized target instead of compressing the 4x4 desktop drawer.
  local layout = gridLayoutFor(ww, wh, s, n)
  local margin = layout.margin
  local panelW, panelH = layout.panelW, layout.panelH
  local x, y = layout.x, layout.y
  local columns, gridRows = layout.columns, layout.rows
  local radius = layout.mobile
    and math.max(12 * s, math.min(ww, wh) * 0.025)
    or math.max(16 * s, wh * 0.024)

  G.setColor(0.018, 0.026, 0.045, 0.86)
  roundRect(G, "fill", x, y, panelW, panelH, radius)
  G.setColor(1, 1, 1, 0.20)
  if type(G.setLineWidth) == "function" then G.setLineWidth(math.max(1, 2 * s)) end
  roundRect(G, "line", x, y, panelW, panelH, radius)

  local padX = layout.mobile
    and math.max(9 * s, panelW * 0.022)
    or math.max(14 * s, panelW * 0.042)
  local padY = layout.mobile
    and math.max(7 * s, panelH * 0.018)
    or math.max(14 * s, panelH * 0.028)
  local headerH = layout.mobile
    and math.max(46 * s, panelH * 0.14)
    or math.max(70 * s, panelH * 0.13)
  local footerH = layout.mobile
    and math.max(36 * s, panelH * 0.095)
    or math.max(34 * s, panelH * 0.065)
  local titleFont = modernFont(math.max(layout.mobile and 17 * s or 18 * s, wh * 0.021) * ts)
  local metaFont = modernFont(math.max(layout.mobile and 9 * s or 10 * s, wh * 0.013) * ts)
  local labelFont = modernFont(math.max(layout.mobile and 9 * s or 10 * s, wh * 0.0135) * ts)
  local smallFont = modernFont(math.max(layout.mobile and 8 * s or 9 * s, wh * 0.0115) * ts)

  if titleFont and type(G.setFont) == "function" then G.setFont(titleFont) end
  G.setColor(1, 1, 1, 0.98)
  if type(G.print) == "function" then G.print("MOD SETTINGS", x + padX, y + padY) end

  local selected = rows[cursor]
  local meta = selected and selected._stadium2Grid
  local selectedTitle = cleanText(meta and meta.title or (selected and selected.label) or "")
  local selectedCount = meta and tonumber(meta.count)
  local subtitle = selectedTitle
  if selectedCount then subtitle = subtitle .. "  •  " .. tostring(selectedCount) .. " SETTINGS" end
  if metaFont and type(G.setFont) == "function" then G.setFont(metaFont) end
  G.setColor(1, 1, 1, 0.60)
  if type(G.print) == "function" then
    G.print(clipped(subtitle, G.getFont and G.getFont() or metaFont, panelW - padX * 2),
      x + padX, y + padY + math.max(28 * s, headerH * 0.42))
  end

  local gridX = x + padX
  local gridY = y + headerH
  local gridW = panelW - padX * 2
  local gridH = panelH - headerH - footerH - padY * 0.5
  local gapX = math.max(layout.mobile and 3 * s or 4 * s, gridW * (layout.mobile and 0.012 or 0.02))
  local gapY = math.max(layout.mobile and 3 * s or 6 * s, gridH * (layout.mobile and 0.012 or 0.016))
  local cellW = (gridW - gapX * (columns - 1)) / columns
  local cellH = (gridH - gapY * (gridRows - 1)) / gridRows
  local focusR = math.max(layout.mobile and 8 * s or 10 * s, cellW * 0.16)
  local touchHits = {}

  for slot = 0, GRID_PAGE_SIZE - 1 do
    local index = first + slot
    local row = rows[index]
    if not row then break end
    local col = slot % columns
    local rr = math.floor(slot / columns)
    local cx = gridX + col * (cellW + gapX)
    local cy = gridY + rr * (cellH + gapY)
    touchHits[#touchHits + 1] = { index = index, x = cx, y = cy, w = cellW, h = cellH }
    local focused = index == cursor
    local gm = row._stadium2Grid or gridMeta("other", row.label)

    if focused then
      G.setColor(0.080, 0.150, 0.275, 0.95)
      roundRect(G, "fill", cx, cy, cellW, cellH, focusR)
      G.setColor(1, 1, 1, 0.36)
      if type(G.setLineWidth) == "function" then G.setLineWidth(math.max(1, 1.8 * s)) end
      roundRect(G, "line", cx, cy, cellW, cellH, focusR)
    end

    -- v0.4.20: let the artwork itself define the icon silhouette.  The old
    -- translucent rounded-square "well" created a visible border around every
    -- raster icon (and nested the supplied rounded-square art inside another
    -- rounded square).  Use that space for the artwork instead.
    local iconBox = math.min(cellW * (layout.mobile and 0.88 or 0.84),
      cellH * (layout.mobile and 0.60 or 0.58))
    local iconSize = iconBox * 0.96
    local ix = cx + (cellW - iconBox) * 0.5
    local iy = cy + cellH * 0.035
    G.setColor(1, 1, 1, focused and 1.0 or 0.96)
    drawGridIcon(G, gm.icon, ix + (iconBox - iconSize) * 0.5,
      iy + (iconBox - iconSize) * 0.5, iconSize)

    local labelY = iy + iconBox + cellH * 0.025
    local textW = cellW - math.max(4 * s, cellW * 0.06) * 2
    local textX = cx + (cellW - textW) * 0.5
    local label = gm.title or row.label or ""
    if labelFont and type(G.setFont) == "function" then G.setFont(labelFont) end
    G.setColor(1, 1, 1, focused and 0.98 or 0.88)
    if type(G.printf) == "function" then
      G.printf(clipped(label, G.getFont and G.getFont() or labelFont, textW),
        textX, labelY, textW, "center")
    elseif type(G.print) == "function" then
      G.print(clipped(label, G.getFont and G.getFont() or labelFont, textW), textX, labelY)
    end

    if smallFont and type(G.setFont) == "function" then G.setFont(smallFont) end
    G.setColor(1, 1, 1, focused and 0.62 or 0.42)
    local detail = gm.count and (tostring(gm.count) .. " set")
      or (gm.id == "reset" and "defaults") or "open"
    if type(G.printf) == "function" then
      G.printf(clipped(detail, G.getFont and G.getFont() or smallFont, textW),
        textX, cy + cellH * 0.84, textW, "center")
    elseif type(G.print) == "function" then
      G.print(clipped(detail, G.getFont and G.getFont() or smallFont, textW), textX, cy + cellH * 0.84)
    end
  end

  local footerY = y + panelH - footerH
  local backRect = nil
  if smallFont and type(G.setFont) == "function" then G.setFont(smallFont) end
  if layout.mobile then
    local backW = math.max(74 * s, panelW * 0.15)
    local backH = math.max(28 * s, footerH * 0.72)
    local backX = x + padX
    local backY = footerY + (footerH - backH) * 0.5
    backRect = { x = backX, y = backY, w = backW, h = backH }
    G.setColor(1, 1, 1, 0.10)
    roundRect(G, "fill", backX, backY, backW, backH, backH * 0.34)
    G.setColor(1, 1, 1, 0.78)
    if type(G.printf) == "function" then
      G.printf("BACK", backX, backY + backH * 0.28, backW, "center")
    elseif type(G.print) == "function" then
      G.print("BACK", backX + backW * 0.28, backY + backH * 0.28)
    end
    G.setColor(1, 1, 1, 0.52)
    if type(G.print) == "function" then
      G.print(self.notice or "TAP AN ICON", backX + backW + math.max(10 * s, panelW * 0.025),
        footerY + footerH * 0.36)
    end
  else
    G.setColor(1, 1, 1, 0.54)
    local prompt = self.notice or controllerPrompt("D-PAD MOVE    A OPEN    B BACK")
    if type(G.print) == "function" then G.print(prompt, x + padX, footerY + footerH * 0.36) end
  end
  if type(G.printf) == "function" then
    G.setColor(1, 1, 1, 0.56)
    G.printf(tostring(n) .. " APPS",
      x + panelW - padX - math.max(90 * s, panelW * 0.18),
      footerY + footerH * 0.36,
      math.max(90 * s, panelW * 0.18), "right")
  end

  local screenW, screenH = ww, wh
  if type(G.getDimensions) == "function" then
    local okDims, sw, sh = pcall(G.getDimensions)
    if okDims and tonumber(sw) and tonumber(sh) then screenW, screenH = sw, sh end
  end
  self._stadium2GridTouchLayout = {
    mobile = layout.mobile,
    targetW = ww, targetH = wh,
    screenW = screenW, screenH = screenH,
    hits = touchHits,
    back = backRect,
  }

  G.setColor(1, 1, 1, 1)
  if pushed then pcall(G.pop) end
  return true
end

-- Minimal compatibility renderer used only when the richer glass renderer
-- hits a backend-specific graphics error.  Crucially, this is still the icon
-- APP GRID: it never replaces the category root with ManagerState's native
-- flat list.  It uses only very old/simple LOVE drawing calls and pcall guards
-- each optional operation so one unsupported cosmetic feature cannot take the
-- manager down.
local function drawPortableGridRoot(self, Font, Theme)
  local G = love and love.graphics
  if not G then return false end
  local rows = self.optionRows or {}
  local n = #rows
  if n == 0 then return false end
  local cursor = math.max(1, math.min(n, tonumber(self.cursor) or 1))
  local ww, wh = targetDimensions()
  if not (ww and wh and ww > 0 and wh > 0) then return false end
  local s = uiScaleFor(ww, wh)
  local ts = uiTextScale()
  local layout = gridLayoutFor(ww, wh, s, n)
  local x, y, panelW, panelH = layout.x, layout.y, layout.panelW, layout.panelH
  local columns, gridRows = layout.columns, layout.rows
  local padX = math.max(6 * s, panelW * 0.018)
  local padY = math.max(5 * s, panelH * 0.014)
  local headerH = math.max(32 * s, panelH * 0.10)
  local footerH = math.max(28 * s, panelH * 0.08)
  local gridX, gridY = x + padX, y + headerH
  local gridW = panelW - padX * 2
  local gridH = panelH - headerH - footerH
  local gapX = math.max(2 * s, gridW * 0.010)
  local gapY = math.max(2 * s, gridH * 0.010)
  local cellW = (gridW - gapX * (columns - 1)) / columns
  local cellH = (gridH - gapY * (gridRows - 1)) / gridRows
  local hits = {}

  if type(G.setColor) == "function" then pcall(G.setColor, 0.02, 0.03, 0.06, 0.94) end
  if type(G.rectangle) == "function" then pcall(G.rectangle, "fill", x, y, panelW, panelH) end
  if type(G.setColor) == "function" then pcall(G.setColor, 1, 1, 1, 1) end

  local titleFont = modernFont(math.max(14 * s, wh * 0.018) * ts)
  local labelFont = modernFont(math.max(8 * s, wh * 0.011) * ts)
  if titleFont and type(G.setFont) == "function" then pcall(G.setFont, titleFont) end
  if type(G.print) == "function" then pcall(G.print, "MOD SETTINGS", x + padX, y + padY) end

  for slot = 0, GRID_PAGE_SIZE - 1 do
    local index = 1 + slot
    local row = rows[index]
    if not row then break end
    local col = slot % columns
    local rr = math.floor(slot / columns)
    local cx = gridX + col * (cellW + gapX)
    local cy = gridY + rr * (cellH + gapY)
    hits[#hits + 1] = { index=index, x=cx, y=cy, w=cellW, h=cellH }
    local gm = row._stadium2Grid or gridMeta("other", row.label)
    local focused = index == cursor

    -- Oldest-path focus marker.  If rectangles are the failing primitive the
    -- icon/label grid still renders; if they work, the selected app gets a
    -- simple translucent tile behind it.
    if focused and type(G.rectangle) == "function" then
      if type(G.setColor) == "function" then pcall(G.setColor, 0.20, 0.42, 0.90, 0.42) end
      pcall(G.rectangle, "fill", cx, cy, cellW, cellH)
    end

    local iconBox = math.min(cellW * 0.90, cellH * 0.66)
    local iconSize = iconBox * 0.98
    local ix = cx + (cellW - iconBox) * 0.5
    local iy = cy + cellH * 0.025
    if type(G.setColor) == "function" then pcall(G.setColor, 1, 1, 1, 1) end
    -- drawGridIcon's raster path is the normal path for all twelve supplied
    -- PNGs.  Guard it so RESET's vector fallback cannot crash this renderer.
    pcall(drawGridIcon, G, gm.icon,
      ix + (iconBox - iconSize) * 0.5,
      iy + (iconBox - iconSize) * 0.5, iconSize)

    if labelFont and type(G.setFont) == "function" then pcall(G.setFont, labelFont) end
    if type(G.setColor) == "function" then pcall(G.setColor, 1, 1, 1, focused and 1 or 0.82) end
    local label = cleanText(gm.title or row.label or "")
    local labelY = iy + iconBox + math.max(1 * s, cellH * 0.01)
    if type(G.printf) == "function" then
      pcall(G.printf, label, cx, labelY, cellW, "center")
    elseif type(G.print) == "function" then
      pcall(G.print, label, cx + cellW * 0.08, labelY)
    end
  end

  local screenW, screenH = ww, wh
  if type(G.getDimensions) == "function" then
    local okDims, sw, sh = pcall(G.getDimensions)
    if okDims and tonumber(sw) and tonumber(sh) then screenW, screenH = sw, sh end
  end
  self._stadium2GridTouchLayout = {
    mobile=layout.mobile, targetW=ww, targetH=wh,
    screenW=screenW, screenH=screenH, hits=hits, back=nil,
  }
  self._stadium2GridCompatibilityRenderer = true
  M.compatibilityGridActive = true
  if type(G.setColor) == "function" then pcall(G.setColor, 1, 1, 1, 1) end
  return true
end

-- Try the full glass app-grid first.  If a desktop/phone backend rejects a
-- cosmetic call, unwind and immediately redraw using the compatibility GRID.
-- Never fall back to the old flat options list just because rendering failed.
local function drawGridRoot(self, Font, Theme)
  self._stadium2GridCompatibilityRenderer = nil
  M.compatibilityGridActive = false
  local ok, result = xpcall(function()
    return drawGridRootUnsafe(self, Font, Theme)
  end, function(err) return tostring(err) end)
  if ok and result then return true end

  M.lastError = "custom settings draw degraded: " .. tostring(result)
  local G = love and love.graphics
  if G then
    if type(G.pop) == "function" then pcall(G.pop) end
    if type(G.origin) == "function" then pcall(G.origin) end
    if type(G.setColor) == "function" then pcall(G.setColor, 1, 1, 1, 1) end
    if type(G.setBlendMode) == "function" then pcall(G.setBlendMode, "alpha") end
  end
  local safeOk, safeShown = pcall(drawPortableGridRoot, self, Font, Theme)
  if safeOk and safeShown then return true end
  M.lastError = M.lastError .. "; compatibility grid failed: " .. tostring(safeShown)
  return false
end


-- Modern category renderer. The app-grid root has always owned its own draw
-- path; category pages previously dropped back into Gen1Recomp's 160x144
-- OptionRows renderer. On phones that made WILD PKMN / FLY PKMN (and every
-- other category) look like the original Game Boy UI. Keep ManagerState's
-- update/persistence logic, but present those exact same rows as modern cards.
local function safeRowValue(row, game)
  if not row or type(row.value) ~= "function" then return "" end
  local ok, value = pcall(row.value, game)
  if not ok then ok, value = pcall(row.value) end
  if not ok or value == nil then return "" end
  if row.id == "uiTextSize" and tonumber(value) then
    return tostring(math.floor(tonumber(value) + 0.5)) .. "%"
  end
  return cleanText(value)
end

local function categoryPanelLayout(ww, wh, s)
  local mobile = mobilePlatform()
  local margin, panelW, panelH, x, y
  if mobile then
    margin = math.max(5 * s, math.min(ww, wh) * 0.012)
    panelW = math.max(1, ww - margin * 2)
    panelH = math.max(1, wh - margin * 2)
    x, y = margin, margin
  else
    margin = math.max(12 * s, wh * 0.018)
    -- v0.4.27: category pages are a compact settings drawer, not a set of
    -- giant four-up cards. Keep enough width for long option values without
    -- letting the drawer dominate a desktop window.
    panelW = math.min(math.max(ww * 0.40, 390 * s), ww * 0.50)
    panelH = math.min(wh - margin * 2, math.max(wh * 0.82, 500 * s))
    if ww < 900 then panelW = math.min(math.max(ww * 0.50, 360 * s), ww - margin * 1.5) end
    x = ww - panelW - margin
    y = (wh - panelH) * 0.5
  end
  return {mobile=mobile, margin=margin, panelW=panelW, panelH=panelH, x=x, y=y}
end

-- The stock OptionRows viewport is fixed at four rows, which made the modern
-- full-height category page stretch each card to enormous sizes. The custom
-- renderer owns its own viewport, so use a denser count appropriate to the
-- physical shape while ManagerState continues to own values/actions.
local function categoryVisibleRows(layout)
  if not layout then return 10 end
  if layout.mobile then
    if layout.panelH > layout.panelW * 1.22 then return 11 end -- portrait phone
    return 8 -- landscape phone: slimmer cards but still finger-friendly
  end
  return 10 -- desktop drawer should read like a compact settings list
end

local function clampCategoryScroll(self)
  if not categoryPageActive(self) then return end
  local rows = self.optionRows or {}
  local n = #rows
  if n <= 0 then self.scroll = 0 return end
  local ww, wh = targetDimensions()
  local s = uiScaleFor(ww, wh)
  local visible = categoryVisibleRows(categoryPanelLayout(ww, wh, s))
  local cursor = math.max(1, math.min(n, tonumber(self.cursor) or 1))
  -- Ignore the stock four-row scroll offset after nativeUpdate. Recompute the
  -- smallest offset that keeps this cursor visible in our denser viewport, so
  -- portrait does not start scrolling at row 5 just because OptionRows would.
  local maxScroll = math.max(0, n - visible)
  self.scroll = math.max(0, math.min(cursor - visible, maxScroll))
end

local function drawCategoryPageUnsafe(self)
  local G = love and love.graphics
  if not G then return false end
  local rows = self.optionRows or {}
  local n = #rows
  local ww, wh = targetDimensions()
  if not (ww and wh and ww > 0 and wh > 0) then return false end
  local s = uiScaleFor(ww, wh)
  local ts = uiTextScale()
  local layout = categoryPanelLayout(ww, wh, s)
  local x, y, panelW, panelH = layout.x, layout.y, layout.panelW, layout.panelH
  local pushed = false
  if type(G.push) == "function" and type(G.pop) == "function" then
    local okPush = pcall(G.push)
    pushed = okPush and true or false
  end
  if type(G.origin) == "function" then pcall(G.origin) end
  if type(G.setBlendMode) == "function" then pcall(G.setBlendMode, "alpha") end

  local radius = math.max(layout.mobile and 12 * s or 16 * s, math.min(panelW,panelH)*0.022)
  G.setColor(0.018, 0.026, 0.045, 0.92)
  roundRect(G, "fill", x, y, panelW, panelH, radius)
  G.setColor(1,1,1,0.20)
  if type(G.setLineWidth)=="function" then G.setLineWidth(math.max(1,2*s)) end
  roundRect(G, "line", x, y, panelW, panelH, radius)

  local padX = layout.mobile and math.max(8*s,panelW*0.018) or math.max(12*s,panelW*0.030)
  local padY = layout.mobile and math.max(6*s,panelH*0.010) or math.max(10*s,panelH*0.018)
  -- v0.4.28: the compact drawer should read like a list, not stacked tiles.
  -- Shrink the framing chrome further and size rows only a little taller than
  -- the text itself.
  local headerH
  local footerH
  if layout.mobile then
    headerH = math.min(math.max(42*s,panelH*0.082),78*s)
    footerH = math.min(math.max(24*s,panelH*0.040),36*s)
  else
    headerH = math.min(math.max(54*s,panelH*0.100),82*s)
    footerH = math.min(math.max(24*s,panelH*0.045),38*s)
  end
  local titleFont = modernFont((layout.mobile
    and math.max(14*s, math.min(wh*0.016,23*s))
    or math.max(16*s, math.min(wh*0.018,21*s))) * ts)
  local descFont = modernFont((layout.mobile
    and math.max(7.0*s, math.min(wh*0.0088,12*s))
    or math.max(8.6*s, math.min(wh*0.0102,11.2*s))) * ts)
  local rowFont = modernFont((layout.mobile
    and math.max(8.8*s, math.min(wh*0.0098,13.0*s))
    or math.max(10.0*s, math.min(wh*0.0114,13.0*s))) * ts)
  local valueFont = modernFont((layout.mobile
    and math.max(8.6*s, math.min(wh*0.0095,12.8*s))
    or math.max(9.8*s, math.min(wh*0.0111,12.8*s))) * ts)
  local smallFont = modernFont((layout.mobile
    and math.max(6.8*s, math.min(wh*0.0078,10.2*s))
    or math.max(7.8*s, math.min(wh*0.0090,10.4*s))) * ts)

  local title = cleanText(self._stadium2OptionCategoryLabel or "MOD SETTINGS")
  local description = cleanText(self._stadium2OptionCategoryDescription or "Changes save immediately.")
  if titleFont and type(G.setFont)=="function" then G.setFont(titleFont) end
  G.setColor(1,1,1,0.98)
  if type(G.print)=="function" then G.print(title, x+padX, y+padY) end
  if descFont and type(G.setFont)=="function" then G.setFont(descFont) end
  G.setColor(1,1,1,0.58)
  local descY = y + padY + math.max(27*s, headerH*0.38)
  if type(G.printf)=="function" then
    G.printf(clipped(description, G.getFont and G.getFont() or descFont, panelW-padX*2),
      x+padX, descY, panelW-padX*2, "left")
  end

  -- v0.4.27: render a denser custom viewport instead of inheriting the stock
  -- four-row Game Boy viewport. updateOptions normalizes ManagerState.scroll
  -- to this same count after every navigation/action.
  local visible = categoryVisibleRows(layout)
  local bodyX = x + padX
  local bodyY = y + headerH
  local bodyW = panelW - padX*2
  local bodyH = panelH - headerH - footerH
  local gap = math.max(layout.mobile and 1.5*s or 2*s, math.min(bodyH*0.006, 4*s))
  local rowH = (bodyH - gap*(visible-1)) / visible
  local scroll = math.max(0, tonumber(self.scroll) or 0)
  local cursor = math.max(1, math.min(math.max(1,n), tonumber(self.cursor) or 1))
  local hits = {}

  for slot=1,visible do
    local index = scroll + slot
    local row = rows[index]
    if not row then break end
    local ry = bodyY + (slot-1)*(rowH+gap)
    local focused = index == cursor
    hits[#hits+1] = {index=index,x=bodyX,y=ry,w=bodyW,h=rowH}
    G.setColor(focused and 0.080 or 0.035, focused and 0.150 or 0.052,
      focused and 0.275 or 0.085, focused and 0.96 or 0.78)
    local rowRadius = math.max(5*s, math.min(rowH*0.12, 10*s))
    roundRect(G,"fill",bodyX,ry,bodyW,rowH,rowRadius)
    G.setColor(1,1,1,focused and 0.34 or 0.10)
    roundRect(G,"line",bodyX,ry,bodyW,rowH,rowRadius)

    local name = cleanText(row.label or row.id or "SETTING")
    local value = safeRowValue(row, self.game)
    local textX = bodyX + math.max(8*s,bodyW*0.018)
    local valueW = math.max(74*s,bodyW*0.28)
    local nameW = bodyW - valueW - math.max(22*s,bodyW*0.050)
    if rowFont and type(G.setFont)=="function" then G.setFont(rowFont) end
    G.setColor(1,1,1,focused and 0.98 or 0.86)
    if type(G.print)=="function" then
      G.print(clipped(name,G.getFont and G.getFont() or rowFont,nameW),textX,ry+rowH*0.24)
    end
    if valueFont and type(G.setFont)=="function" then G.setFont(valueFont) end
    G.setColor(focused and 0.72 or 0.70, focused and 0.86 or 0.76, 1, focused and 1 or 0.82)
    if type(G.printf)=="function" then
      G.printf(clipped(value,G.getFont and G.getFont() or valueFont,valueW),
        bodyX+bodyW-valueW-math.max(8*s,bodyW*0.018),ry+rowH*0.24,valueW,"right")
    end
    if row.id == "uiTextSize" and type(G.rectangle) == "function" then
      local pct = math.max(75, math.min(160, tonumber(tostring(value):match("%d+")) or 100))
      local frac = (pct - 75) / 85
      local trackW = math.min(valueW, bodyW * 0.22)
      local trackH = math.max(2, math.min(3*s, rowH*0.055))
      local trackX = bodyX + bodyW - trackW - math.max(8*s,bodyW*0.018)
      local trackY = ry + rowH * 0.68
      hits[#hits].slider = {x=trackX,y=trackY-rowH*0.16,w=trackW,h=math.max(trackH,rowH*0.34)}
      G.setColor(1,1,1,0.18)
      roundRect(G,"fill",trackX,trackY,trackW,trackH,trackH*0.5)
      G.setColor(focused and 0.72 or 0.58, focused and 0.86 or 0.72, 1, focused and 0.95 or 0.75)
      roundRect(G,"fill",trackX,trackY,trackW*frac,trackH,trackH*0.5)
    end
  end

  local footerY = y + panelH - footerH
  local backRect
  if smallFont and type(G.setFont)=="function" then G.setFont(smallFont) end
  if layout.mobile then
    local backW = math.max(72*s,panelW*0.15)
    local backH = math.max(27*s,footerH*0.72)
    local backX = x+padX
    local backY = footerY+(footerH-backH)*0.5
    backRect={x=backX,y=backY,w=backW,h=backH}
    G.setColor(1,1,1,0.10)
    roundRect(G,"fill",backX,backY,backW,backH,backH*0.34)
    G.setColor(1,1,1,0.80)
    if type(G.printf)=="function" then G.printf("CATEGORIES",backX,backY+backH*0.27,backW,"center") end
    G.setColor(1,1,1,0.50)
    if type(G.print)=="function" then
      G.print(self.notice or "TAP A SETTING • D-PAD SCROLL",
        backX+backW+math.max(10*s,panelW*0.025), footerY+footerH*0.36)
    end
  else
    G.setColor(1,1,1,0.54)
    if type(G.print)=="function" then
      G.print(self.notice or controllerPrompt("D-PAD SELECT    LEFT/RIGHT CHANGE    A OPEN    B CATEGORIES"),
        x+padX,footerY+footerH*0.36)
    end
  end
  if type(G.printf)=="function" then
    G.setColor(1,1,1,0.48)
    G.printf(tostring(cursor).." / "..tostring(n),x+panelW-padX-math.max(70*s,panelW*0.14),
      footerY+footerH*0.36,math.max(70*s,panelW*0.14),"right")
  end

  local screenW,screenH=ww,wh
  if type(G.getDimensions)=="function" then
    local okDims,sw,sh=pcall(G.getDimensions)
    if okDims and tonumber(sw) and tonumber(sh) then screenW,screenH=sw,sh end
  end
  self._stadium2CategoryTouchLayout={
    mobile=layout.mobile,targetW=ww,targetH=wh,screenW=screenW,screenH=screenH,
    hits=hits,back=backRect,
  }
  G.setColor(1,1,1,1)
  if pushed then pcall(G.pop) end
  return true
end

local function drawPortableCategoryPage(self)
  local G=love and love.graphics
  if not G then return false end
  local rows=self.optionRows or {}
  local n=#rows
  local ww,wh=targetDimensions()
  if not (ww and wh and ww>0 and wh>0) then return false end
  local s=uiScaleFor(ww,wh)
  local ts=uiTextScale()
  local layout=categoryPanelLayout(ww,wh,s)
  local x,y,w,h=layout.x,layout.y,layout.panelW,layout.panelH
  local pad=math.max(7*s,w*0.02)
  local headerH=layout.mobile and math.min(math.max(34*s,h*0.075),68*s) or math.min(math.max(40*s,h*0.090),72*s)
  local footerH=layout.mobile and math.min(math.max(22*s,h*0.035),34*s) or math.min(math.max(24*s,h*0.040),34*s)
  local bodyH=h-headerH-footerH
  local visible=categoryVisibleRows(layout)
  local gap=math.max(1.5*s,math.min(bodyH*0.005,4*s))
  local rowH=(bodyH-gap*(visible-1))/visible
  local scroll=math.max(0,tonumber(self.scroll) or 0)
  local cursor=math.max(1,math.min(math.max(1,n),tonumber(self.cursor) or 1))
  local f=modernFont(math.max(10.5*s,wh*0.0135)*ts)
  if type(G.setColor)=="function" then pcall(G.setColor,0.02,0.03,0.06,0.96) end
  if type(G.rectangle)=="function" then pcall(G.rectangle,"fill",x,y,w,h) end
  if f and type(G.setFont)=="function" then pcall(G.setFont,f) end
  if type(G.setColor)=="function" then pcall(G.setColor,1,1,1,1) end
  if type(G.print)=="function" then pcall(G.print,cleanText(self._stadium2OptionCategoryLabel or "MOD SETTINGS"),x+pad,y+pad) end
  local hits={}
  for slot=1,visible do
    local index=scroll+slot
    local row=rows[index]
    if not row then break end
    local ry=y+headerH+(slot-1)*(rowH+gap)
    hits[#hits+1]={index=index,x=x+pad,y=ry,w=w-pad*2,h=rowH}
    if index==cursor and type(G.rectangle)=="function" then
      if type(G.setColor)=="function" then pcall(G.setColor,0.12,0.24,0.45,0.80) end
      pcall(G.rectangle,"fill",x+pad,ry,w-pad*2,rowH)
    end
    if type(G.setColor)=="function" then pcall(G.setColor,1,1,1,index==cursor and 1 or 0.82) end
    if type(G.print)=="function" then pcall(G.print,cleanText(row.label or row.id or "SETTING"),x+pad*1.6,ry+rowH*0.20) end
    local value=safeRowValue(row,self.game)
    if type(G.printf)=="function" then pcall(G.printf,value,x+w*0.64,ry+rowH*0.20,w*0.28,"right") end
  end
  local screenW,screenH=ww,wh
  if type(G.getDimensions)=="function" then local ok,sw,sh=pcall(G.getDimensions); if ok and sw and sh then screenW,screenH=sw,sh end end
  self._stadium2CategoryTouchLayout={mobile=layout.mobile,targetW=ww,targetH=wh,screenW=screenW,screenH=screenH,hits=hits,back=nil}
  if type(G.setColor)=="function" then pcall(G.setColor,1,1,1,1) end
  return true
end

local function drawCategoryPage(self)
  local ok,result=xpcall(function() return drawCategoryPageUnsafe(self) end,function(err) return tostring(err) end)
  if ok and result then return true end
  M.lastError="custom category draw degraded: "..tostring(result)
  local G=love and love.graphics
  if G then
    if type(G.pop)=="function" then pcall(G.pop) end
    if type(G.origin)=="function" then pcall(G.origin) end
    if type(G.setColor)=="function" then pcall(G.setColor,1,1,1,1) end
  end
  local safeOk,safeShown=pcall(drawPortableCategoryPage,self)
  if safeOk and safeShown then return true end
  M.lastError=M.lastError.."; portable category failed: "..tostring(safeShown)
  return false
end

local OPTION_TYPES = { toggle=true, choice=true, number=true, text=true }

local function optionSchema(self, m)
  if self and type(self.schemaFor) == "function" then
    local ok, schema = pcall(self.schemaFor, self, m)
    if ok and type(schema) == "table" then return schema end
  end
  return nil
end

local MOUNT_SIMPLE = {
  mountFlightMode=true, mountFlightPokemon=true, mountSettingsView=true,
  mountShowRider=true, mountFlightSpeed=true,
  mountGroundSpeed=true, mountManualAltitude=true, mountVisibleSurf=true,
  mountRealisticSizes=true, mountHints=true, mountAirEncounters=true,
  ambientFlyingPokemon=true, ambientFlyingDensity=true,
  mountShortcut=true, mountControllerShortcuts=true,
  mountRequireFly=true, mountRequireSurf=true, mountBadgeChecks=true,
  mountFlyingMusic=true, mountRenderer=true, mountSizeOverrides=true,
}

local function optionValue(key, default)
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return default end
  local ok, value = pcall(options.get, options, key)
  if not ok or value == nil then return default end
  return value
end

local function categoryOwns(category, key)
  if category.keys[key] then return true end
  return category.id == "mounts" and type(key) == "string"
    and key:match("^mountSize_") ~= nil
end

local function schemaSubset(schema, category)
  local out = {}
  local advanced = tostring(optionValue("mountSettingsView", "simple")) == "advanced"
  local sizes = tostring(optionValue("mountSizeOverrides", "hidden")) == "edit"
  for _, row in ipairs(schema or {}) do
    if type(row) == "table" and categoryOwns(category, row.key) then
      local keep = true
      if category.id == "mounts" then
        local sizeRow = type(row.key) == "string" and row.key:match("^mountSize_") ~= nil
        if sizeRow then keep = advanced and sizes
        elseif not advanced and not MOUNT_SIMPLE[row.key] then keep = false end
      end
      if keep then out[#out + 1] = row end
    end
  end
  return out
end

local function categorizedKeys()
  local set = {}
  for _, category in ipairs(CATEGORIES) do
    for key in pairs(category.keys) do set[key] = true end
  end
  return set
end

local KNOWN_KEYS = categorizedKeys()

local function uncategorizedSubset(schema)
  local out = {}
  for _, row in ipairs(schema or {}) do
    if type(row) == "table" and type(row.key) == "string"
       and not KNOWN_KEYS[row.key]
       and not row.key:match("^mountSize_") then
      out[#out + 1] = row
    end
  end
  return out
end

local function countOptions(schema)
  local n = 0
  for _, row in ipairs(schema or {}) do
    if type(row) == "table" and type(row.key) == "string"
       and OPTION_TYPES[row.type] then
      n = n + 1
    end
  end
  return n
end

local showRoot, showCategory

local function rememberRootPosition(self)
  if not self then return end
  if self._stadium2OptionCategory == nil then
    self._stadium2RootCursor = tonumber(self.cursor) or 1
    self._stadium2RootScroll = tonumber(self.scroll) or 0
  end
end

showCategory = function(self, categoryId)
  -- Preserve the exact category-folder row the player entered from.  The
  -- engine's flat options screen normally resets cursor/scroll when a new row
  -- set is installed; without this, B from any category always jumped to the
  -- first folder instead of returning to the folder just opened.
  rememberRootPosition(self)
  local category = byId[categoryId]
  local schema = self and self._stadium2FullOptionSchema
  local currentMod = self and self._stadium2CategorizedMod
  if not (category and type(schema) == "table" and currentMod) then return false end
  local subset = schemaSubset(schema, category)
  if #subset == 0 then return false end
  if type(self.buildOptionRows) ~= "function" then return false end

  local ok, rows = pcall(self.buildOptionRows, self, currentMod, subset)
  if not ok or type(rows) ~= "table" then
    M.lastError = "category build failed: " .. tostring(rows)
    return false
  end

  self.optionRows = rows
  self.cursor = 1
  self.scroll = 0
  self._stadium2OptionCategory = category.id
  self._stadium2OptionCategoryLabel = category.label
  self._stadium2OptionCategoryDescription = category.description
  self._stadium2GridRoot = false
  self._stadium2GridTouchLayout = nil
  self._stadium2CategoryTouchLayout = nil
  M.categoryOpens = M.categoryOpens + 1
  M.lastError = nil
  return true
end

showRoot = function(self, restorePosition)
  if not customUIEnabled() then return false end
  local schema = self and self._stadium2FullOptionSchema
  local currentMod = self and self._stadium2CategorizedMod
  if not (type(schema) == "table" and currentMod) then return false end

  local rows = {}
  for _, category in ipairs(CATEGORIES) do
    local subset = schemaSubset(schema, category)
    if #subset > 0 then
      local catId = category.id
      rows[#rows + 1] = {
        id = "__stadium_category_" .. catId,
        label = category.label,
        value = function() return tostring(countOptions(subset)) .. " SETTINGS" end,
        activate = function() showCategory(self, catId) end,
        _stadium2Grid = gridMeta(catId, category.label, countOptions(subset)),
      }
    end
  end

  -- Future options should never disappear just because this release did not
  -- know their category yet.  They land in OTHER automatically.
  local other = uncategorizedSubset(schema)
  if #other > 0 then
    rows[#rows + 1] = {
      id = "__stadium_category_other",
      label = "OTHER",
      value = function() return tostring(countOptions(other)) .. " SETTINGS" end,
      _stadium2Grid = gridMeta("other", "OTHER", countOptions(other)),
      activate = function()
        rememberRootPosition(self)
        if type(self.buildOptionRows) ~= "function" then return end
        local ok, built = pcall(self.buildOptionRows, self, currentMod, other)
        if ok and type(built) == "table" then
          self.optionRows = built
          self.cursor, self.scroll = 1, 0
          self._stadium2OptionCategory = "other"
          self._stadium2OptionCategoryLabel = "OTHER"
          self._stadium2OptionCategoryDescription = "Additional settings not assigned to a category yet."
          self._stadium2GridRoot = false
          self._stadium2GridTouchLayout = nil
          self._stadium2CategoryTouchLayout = nil
        end
      end,
    }
  end

  rows[#rows + 1] = {
    id = "__stadium_reset_all",
    label = "RESET ALL DEFAULTS",
    value = function() return "" end,
    _stadium2Grid = gridMeta("reset", "RESET ALL DEFAULTS"),
    activate = function()
      if type(self.setOption) ~= "function" then return end
      for _, row in ipairs(schema) do
        if type(row) == "table" and type(row.key) == "string"
           and OPTION_TYPES[row.type] then
          self:setOption(MOD_ID, row.key, row.default)
        end
      end
      if type(self.notify) == "function" then self:notify("ALL DEFAULTS RESTORED") end
    end,
  }

  self.optionRows = rows
  if restorePosition then
    self.cursor = math.max(1, math.min(#rows, tonumber(self._stadium2RootCursor) or 1))
    self.scroll = math.max(0, tonumber(self._stadium2RootScroll) or 0)
    -- Keep a stale saved scroll from placing the restored cursor outside the
    -- visible window after categories are added/removed between opens.
    if self.cursor < self.scroll + 1 then self.scroll = math.max(0, self.cursor - 1) end
  else
    self.cursor = 1
    self.scroll = 0
    self._stadium2RootCursor = 1
    self._stadium2RootScroll = 0
  end
  self._stadium2OptionCategory = nil
  self._stadium2OptionCategoryLabel = nil
  self._stadium2OptionCategoryDescription = nil
  self._stadium2CategorizedOptions = true
  self._stadium2GridRoot = true
  self._stadium2CategoryTouchLayout = nil
  return true
end

local function inRect(x, y, r)
  return r and x >= r.x and y >= r.y and x <= r.x + r.w and y <= r.y + r.h
end

local function clearGridPresentation(self)
  if not self then return end
  self._stadium2CategorizedOptions = nil
  self._stadium2OptionCategory = nil
  self._stadium2OptionCategoryLabel = nil
  self._stadium2OptionCategoryDescription = nil
  self._stadium2GridRoot = nil
  self._stadium2GridTouchLayout = nil
  self._stadium2CategoryTouchLayout = nil
end

local function safeShowRoot(self, restorePosition)
  local ok, shown = pcall(showRoot, self, restorePosition)
  if ok then return shown and true or false end
  M.lastError = "custom settings root failed: " .. tostring(shown)
  return false
end

local function handleGridTouch(self, x, y, event)
  if not gridRootActive(self) then return false end
  local layout = self._stadium2GridTouchLayout
  if not (layout and type(layout.hits) == "table") then return false end

  -- On normal mobile gameplay the pointer hook gives both OS-window points and
  -- GameViewport-local coordinates.  If the custom menu is being drawn into a
  -- 160x144-ish game target, the latter are exact; otherwise use window points.
  local tw, th = tonumber(layout.targetW), tonumber(layout.targetH)
  if type(event) == "table" and event.insideGame and tw and th
      and tw <= 320 and th <= 288
      and tonumber(event.gameX) and tonumber(event.gameY) then
    x, y = tonumber(event.gameX), tonumber(event.gameY)
  else
    x, y = tonumber(x), tonumber(y)
    if not (x and y) then return false end
    local sw, sh = tonumber(layout.screenW), tonumber(layout.screenH)
    if sw and sh and tw and th and sw > 0 and sh > 0
        and (math.abs(sw - tw) > 1 or math.abs(sh - th) > 1) then
      x, y = x * tw / sw, y * th / sh
    end
  end
  if not (x and y) then return false end

  if inRect(x, y, layout.back) then
    if type(self.goBack) == "function" then
      local okBack, err = pcall(self.goBack, self)
      if not okBack then M.lastError = "settings BACK touch failed: " .. tostring(err) end
    end
    return true
  end

  for _, hit in ipairs(layout.hits) do
    if inRect(x, y, hit) then
      local rows = self.optionRows or {}
      local row = rows[hit.index]
      if not row then return false end
      self.cursor = hit.index
      self.scroll = 0
      if type(self.confirmSound) == "function" then pcall(self.confirmSound, self) end
      if type(row.activate) == "function" then
        local okActivate, err = pcall(row.activate)
        if not okActivate then
          M.lastError = "settings icon activation failed: " .. tostring(err)
        end
      end
      return true
    end
  end
  return false
end


local function pointerToTarget(layout,x,y,event)
  local tw,th=tonumber(layout and layout.targetW),tonumber(layout and layout.targetH)
  if type(event)=="table" and event.insideGame and tw and th
      and tw<=320 and th<=288 and tonumber(event.gameX) and tonumber(event.gameY) then
    return tonumber(event.gameX),tonumber(event.gameY)
  end
  x,y=tonumber(x),tonumber(y)
  if not (x and y) then return nil,nil end
  local sw,sh=tonumber(layout and layout.screenW),tonumber(layout and layout.screenH)
  if sw and sh and tw and th and sw>0 and sh>0
      and (math.abs(sw-tw)>1 or math.abs(sh-th)>1) then
    x,y=x*tw/sw,y*th/sh
  end
  return x,y
end

local function handleCategoryTouch(self,x,y,event)
  if not categoryPageActive(self) then return false end
  local layout=self._stadium2CategoryTouchLayout
  if not (layout and type(layout.hits)=="table") then return false end
  x,y=pointerToTarget(layout,x,y,event)
  if not (x and y) then return false end
  if inRect(x,y,layout.back) then
    return safeShowRoot(self,true)
  end
  for _,hit in ipairs(layout.hits) do
    if inRect(x,y,hit) then
      local row=(self.optionRows or {})[hit.index]
      if not row then return false end
      self.cursor=hit.index
      -- UI TEXT SIZE is a real tap-to-set slider on touch/mouse. The row still
      -- supports LEFT/RIGHT in 5% increments and A opens the engine numeric
      -- picker, but tapping the visible track jumps directly to that size.
      if row.id=="uiTextSize" and hit.slider and inRect(x,y,hit.slider)
          and type(self.setOption)=="function" then
        local frac=math.max(0,math.min(1,(x-hit.slider.x)/math.max(1,hit.slider.w)))
        local target=75+math.floor(((frac*85)/5)+0.5)*5
        target=math.max(75,math.min(160,target))
        local okSet,err=pcall(self.setOption,self,MOD_ID,"uiTextSize",target)
        if not okSet then M.lastError="ui text slider failed: "..tostring(err) end
        return true
      end
      -- A direct touch behaves like the manager's A/right action: toggles and
      -- choices advance once; editor/submenu rows open. Persistence remains in
      -- ManagerState's row callbacks rather than being duplicated here.
      if type(row.activate)=="function" then
        if type(self.confirmSound)=="function" then pcall(self.confirmSound,self) end
        local okAct,err=pcall(row.activate)
        if not okAct then M.lastError="category touch activate failed: "..tostring(err) end
      elseif type(row.step)=="function" then
        local okStep,err=pcall(row.step,self.game,1)
        if not okStep then M.lastError="category touch step failed: "..tostring(err) end
      end
      return true
    end
  end
  return false
end

local function topState(game)
  local stack = game and game.stack
  if not stack then return nil end
  if type(stack.top) == "function" then
    local ok, state = pcall(stack.top, stack)
    if ok and state then return state end
  end
  if type(stack.states) == "table" then return stack.states[#stack.states] end
  return nil
end

local function installPointerHook()
  if not (mod and mod.hooks and type(mod.hooks.wrap) == "function") then
    return false, "mod.hooks:wrap unavailable"
  end
  local ok, unwrapOrErr = pcall(function()
    return mod.hooks:wrap("input.pointer", function(nextFn, game, event)
      local claimed = false
      if type(nextFn) == "function" then
        local okNext, result = pcall(nextFn, game, event)
        if okNext then claimed = result and true or false end
      end
      if claimed or type(event) ~= "table" or event.phase ~= "pressed" then
        return claimed
      end
      local state = topState(game)
      if not (gridRootActive(state) or categoryPageActive(state)) then return claimed end
      local handler = gridRootActive(state) and handleGridTouch or handleCategoryTouch
      local okTouch, consumed = pcall(handler, state, event.x, event.y, event)
      if not okTouch then
        M.lastError = "settings pointer failed: " .. tostring(consumed)
        return true
      end
      return consumed or claimed
    end)
  end)
  if not ok then return false, tostring(unwrapOrErr) end
  M.pointerUnwrap = unwrapOrErr
  return true
end

function M.install()
  if M.installed then return true end
  local ok, ManagerState = pcall(require, "src.mods.ManagerState")
  if not (ok and type(ManagerState) == "table") then
    return false, "src.mods.ManagerState unavailable"
  end
  if ManagerState._stadium2CategoriesGridPatchedV426 then
    M.installed = true
    return true
  end
  if type(ManagerState.openOptions) ~= "function"
      or type(ManagerState.updateOptions) ~= "function" then
    return false, "ManagerState options methods unavailable"
  end

  local nativeOpen = ManagerState.openOptions
  local nativeUpdate = ManagerState.updateOptions
  local nativeDraw = ManagerState.draw
  local okFont, Font = pcall(require, "src.render.Font")
  local okTheme, Theme = pcall(require, "src.ui.Theme")

  ManagerState.openOptions = function(self, m, ...)
    -- The category app grid remains the primary presentation on every open.
    clearGridPresentation(self)
    self._stadium2FullOptionSchema = nil
    self._stadium2CategorizedMod = nil
    self._stadium2RootCursor = 1
    self._stadium2RootScroll = 0

    local result = nativeOpen(self, m, ...)
    if not (m and m.id == MOD_ID and self.screen == "options") then return result end
    if not customUIEnabled() then return result end

    local schema = optionSchema(self, m)
    if not schema then
      M.lastError = "this mod option schema unavailable"
      return result
    end
    self._stadium2FullOptionSchema = schema
    self._stadium2CategorizedMod = m
    if safeShowRoot(self, false) then
      M.opens = M.opens + 1
      M.lastError = nil
    end
    return result
  end

  ManagerState.updateOptions = function(self, input, ...)
    if self and self._stadium2CategorizedOptions and not customUIEnabled() then
      local currentMod = self._stadium2CategorizedMod
      local schema = self._stadium2FullOptionSchema
      clearGridPresentation(self)
      if currentMod and type(schema) == "table" and type(self.buildOptionRows) == "function" then
        local okRows, rows = pcall(self.buildOptionRows, self, currentMod, schema)
        if okRows and type(rows) == "table" then
          self.optionRows = rows
          self.cursor, self.scroll = 1, 0
        end
      end
    end

    -- Re-enable the category app grid live when CUSTOM UI is turned back on.
    if self and not self._stadium2CategorizedOptions
       and customUIEnabled() and self.screen == "options"
       and self._stadium2CategorizedMod and self._stadium2FullOptionSchema then
      if safeShowRoot(self, true) then return end
    end

    if gridRootActive(self) then
      local okGrid, handled = pcall(updateGridRoot, self, input)
      if okGrid then return handled end
      M.lastError = "custom settings input failed: " .. tostring(handled)
      return true
    end

    if self and self._stadium2CategorizedOptions and self.screen == "options"
       and self._stadium2OptionCategory ~= nil
       and input and type(input.wasPressed) == "function"
       and input:wasPressed("b") then
      if safeShowRoot(self, true) then return end
    end
    local result = nativeUpdate(self, input, ...)
    if categoryPageActive(self) then clampCategoryScroll(self) end
    return result
  end

  if type(nativeDraw) == "function" and okFont and Font then
    ManagerState.draw = function(self, ...)
      if gridRootActive(self) then
        local shown = drawGridRoot(self, Font, okTheme and Theme or nil)
        if shown then return end
        -- Last-resort: keep ManagerState alive if both grid renderers fail.
        -- Do not mutate the category rows into the native flat list.
      elseif categoryPageActive(self) then
        local shown = drawCategoryPage(self)
        if shown then return end
        -- If even the portable custom category renderer fails, let the engine
        -- draw rather than crash. Normal PC/phone paths never reach this.
      end
      return nativeDraw(self, ...)
    end
  end

  -- Current Gen1Recomp routes uncaptured mouse/touch events through the public
  -- input.pointer hook on both Gen 1 and Gen 2.  Using that supported seam is
  -- safer than replacing Game/Game2.touchpressed and coexists with the mobile
  -- on-screen D-pad, whose claimed touches never reach this hook.
  local pointerOk, pointerErr = installPointerHook()
  M.pointerHookInstalled = pointerOk and true or false
  if not pointerOk and pointerErr then M.pointerHookError = pointerErr end

  ManagerState._stadium2CategoriesPatched = true
  ManagerState._stadium2CategoriesGridPatchedV426 = true
  M.installed = true
  return true
end

M.showRoot = showRoot
M.showCategory = showCategory
M.categories = CATEGORIES
M.gridRootActive = gridRootActive
M.categoryPageActive = categoryPageActive
M.updateGridRoot = updateGridRoot
M.drawGridRoot = drawGridRoot
M.drawPortableGridRoot = drawPortableGridRoot
M.drawCategoryPage = drawCategoryPage
M.drawPortableCategoryPage = drawPortableCategoryPage
M.categoryVisibleRows = categoryVisibleRows
M.clampCategoryScroll = clampCategoryScroll
M.handleGridTouch = handleGridTouch
M.handleCategoryTouch = handleCategoryTouch
M.gridLayoutFor = gridLayoutFor

function M.status()
  return {
    installed = M.installed,
    opens = M.opens,
    categoryOpens = M.categoryOpens,
    lastError = M.lastError,
    pointerHookInstalled = M.pointerHookInstalled and true or false,
    pointerHookError = M.pointerHookError,
    compatibilityGridActive = M.compatibilityGridActive and true or false,
    modId = MOD_ID,
  }
end

return M
