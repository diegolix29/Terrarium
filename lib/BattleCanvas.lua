-- Battle Canvas: painted PNG fight backgrounds.
--
-- When BATTLE BACKGROUNDS is on, the fight uses the arena PNG as a
-- screen-space backdrop instead of the overworld mesh. SCENERY mode then
-- stamps a scenery PNG as a bottom-anchored prop on top of that arena
-- picture. Pokemon, discs, and HUD still draw in front.

local V = ...

local BattleCanvas = {}

BattleCanvas.ASSET_DIR_BATTLE = "assets/battle/"
BattleCanvas.ASSET_DIR_SCENERY = "assets/scenery/"

BattleCanvas.enabled = nil
BattleCanvas.style = nil

local battleCache = {}
local sceneryCache = {}
local failed = {}

local function status(s)
  _G.__ds_battle_canvas_status = s
  local mod = V and V.mod
  if mod and mod.log then
    mod.log:info("[BattleCanvas] %s", s)
  end
end
status("loaded; awaiting battle requests")

local function loadImageFromMod(paths, cacheKey)
  if failed[cacheKey] then return nil end
  local isScenery = cacheKey:sub(1, 8) == "scenery_"
  local name = isScenery and cacheKey:sub(9) or cacheKey
  if isScenery then
    if sceneryCache[name] then return sceneryCache[name] end
  elseif battleCache[name] then
    return battleCache[name]
  end

  local mod = V and V.mod
  if not mod or not mod.read then
    status(("loadImage: no mod available for %s"):format(cacheKey))
    return nil
  end

  local ok, img = pcall(function()
    for _, path in ipairs(paths) do
      local data = mod:read(path)
      if data then
        local okFD, fileData = pcall(love.filesystem.newFileData, data, path)
        if not okFD then
          status(("newFileData failed for %s: %s"):format(path, tostring(fileData)))
        else
          local okID, imageData = pcall(love.image.newImageData, fileData)
          if not okID then
            status(("newImageData failed for %s: %s"):format(path, tostring(imageData)))
          else
            local okImg, image = pcall(love.graphics.newImage, imageData)
            if okImg and image then
              pcall(image.setFilter, image, "linear", "linear")
              status(("loaded %s"):format(path))
              return image
            end
            status(("newImage failed for %s: %s"):format(path, tostring(image)))
          end
        end
      end
    end
    return nil
  end)

  if ok and img then
    if isScenery then
      sceneryCache[name] = img
    else
      battleCache[name] = img
    end
    return img
  end

  failed[cacheKey] = true
  status(("failed to load %s"):format(cacheKey))
  return nil
end

function BattleCanvas.getSettings()
  if not BattleCanvas.enabled or not BattleCanvas.style then
    return { enabled = false, style = "off" }
  end
  local enabled = BattleCanvas.enabled:get() == true
  local style = BattleCanvas.style:get() or "off"
  return { enabled = enabled, style = style }
end

-- True when the option wants a PNG fight backdrop (arena or scenery).
function BattleCanvas.usingPaintedStage()
  local settings = BattleCanvas.getSettings()
  return settings.enabled and settings.style ~= "off"
end

function BattleCanvas.loadBattleBackground(name)
  if not name then return nil end
  return loadImageFromMod({
    BattleCanvas.ASSET_DIR_BATTLE .. "arena_" .. name .. ".compact.png",
    BattleCanvas.ASSET_DIR_BATTLE .. name .. ".compact.png",
    BattleCanvas.ASSET_DIR_BATTLE .. "arena_" .. name .. ".png",
    BattleCanvas.ASSET_DIR_BATTLE .. name .. ".png",
  }, name)
end

function BattleCanvas.loadScenery(name)
  if not name then return nil end
  return loadImageFromMod({
    BattleCanvas.ASSET_DIR_SCENERY .. name .. ".compact.png",
    BattleCanvas.ASSET_DIR_SCENERY .. name .. ".png",
    BattleCanvas.ASSET_DIR_SCENERY .. "scenery_" .. name .. ".compact.png",
    BattleCanvas.ASSET_DIR_SCENERY .. "scenery_" .. name .. ".png",
  }, "scenery_" .. name)
end

local function livePlayer()
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game) then return nil end
  if Game.overworld and Game.overworld.player then return Game.overworld.player end
  if Game.player then return Game.player end
  return Game.save and Game.save.player
end

local function playerCellIsWater(map, player)
  if not (map and player and type(map.isWaterCell) == "function") then
    return false
  end
  if player.cellX == nil or player.cellY == nil then return false end
  local ok, water = pcall(map.isWaterCell, map, player.cellX, player.cellY)
  return ok and water == true
end

-- True when this fight should use a water/surf PNG, not the map's land art.
-- Map-id matching otherwise always wins (Cinnabar -> gym, Pallet -> grass)
-- even while the player is mid-Surf.
function BattleCanvas.onWater(map, arena)
  if arena and (arena.water == true or arena.surfing == true) then
    return true
  end
  local player = livePlayer()
  if player then
    if player.surfing == true or player.isSurfing == true then return true end
    local surface = player.surface
    if surface == "water" or surface == "surfing" or surface == "surf" then
      return true
    end
    if playerCellIsWater(map, player) then return true end
  end
  return false
end

local function waterBackground(map)
  local mapId = (map and map.id) or ""
  if mapId:find("cerulean") then return "cerulean-canal" end
  if mapId:find("cinnabar") then return "coast-cinnabar" end
  if mapId:find("vermilion") then return "ship-bow" end
  if mapId:find("rock") then return "rock-water-route10" end
  if mapId:find("seafoam") then return "cave-seafoam" end
  return "coast-surf"
end

function BattleCanvas.selectBattleBackground(map, arena)
  if BattleCanvas.onWater(map, arena) then
    return waterBackground(map)
  end
  if not map then 
    status("selectBattleBackground: no map provided, defaulting to grass-kanto-open")
    return "grass-kanto-open" 
  end

  local def = map.def
  local tid = def and (def.tileset or (map.tileset and map.tileset.id))
  local mapId = map.id or ""
  
  -- Try to get map ID from other sources if standard map.id is missing
  if mapId == "" then
    mapId = tostring(map.name or map._id or map.identifier or "")
  end
  
  -- Normalize tileset ID for Gen 2 compatibility
  local normalizedTid = tid
  if tid then
    -- Convert Gen 2 tileset names like "TilesetCave" to "CAVERN"
    normalizedTid = tid:gsub("Tileset", ""):upper()
  end
  
  local bgMap = {
    OVERWORLD = "grass-kanto-open",
    FOREST = "forest-viridian",
    PLATEAU = "safari-kanto",
    SHIP_PORT = "ship-bow",
    CAVERN = "cave-mt-moon",
    UNDERGROUND = "cave-rock-tunnel",
    -- Gen 2 specific mappings
    JOHTO = "grass-kanto-open",
    CAVE = "cave-mt-moon",
  }

  -- Try map ID patterns first (more specific)
  if mapId:find("viridian") then return "gym-viridian" end
  if mapId:find("pallet") then return "grass-route1" end
  if mapId:find("pewter") then return "gym-pewter" end
  if mapId:find("cerulean") then return "cerulean-canal" end
  if mapId:find("lavender") then return "tower-lavender" end
  if mapId:find("celadon") then return "gym-celadon" end
  if mapId:find("fuchsia") then return "gym-fuchsia" end
  if mapId:find("saffron") then return "gym-saffron" end
  if mapId:find("cinnabar") then return "gym-cinnabar" end
  if mapId:find("seafoam") then return "cave-seafoam" end
  if mapId:find("victory") then return "cave-victory-road" end
  if mapId:find("indigo") then return "league-champion" end
  if mapId:find("mt_moon") then return "cave-mt-moon" end
  if mapId:find("rock") then return "rock-water-route10" end
  if mapId:find("power") then return "industrial-power-plant" end
  if mapId:find("silph") then return "industrial-silph" end
  if mapId:find("gym") then return "gym-viridian" end -- Fallback for any gym
  if mapId:find("forest") then return "forest-viridian" end
  if mapId:find("cave") then return "cave-mt-moon" end
  if mapId:find("fall") then return "cave-mt-moon" end -- Waterfall areas are often caves
  if mapId:find("route") then return "grass-kanto-open" end
  
  -- Try tileset matching with both original and normalized names
  if tid and bgMap[tid] then 
    return bgMap[tid] 
  end
  if normalizedTid and bgMap[normalizedTid] then 
    return bgMap[normalizedTid] 
  end
  
  -- Try to detect from map properties
  if def then
    if def.indoor or def.cave or def.underground then
      return "cave-mt-moon"
    end
    if def.water or def.ocean or def.sea then
      return "coast-surf"
    end
  end
  
  return "grass-kanto-open"
end

function BattleCanvas.selectSceneryForMap(map, arena)
  if BattleCanvas.onWater(map, arena) then
    local mapId = (map and map.id) or ""
    if mapId:find("cerulean") or mapId:find("cinnabar") then
      return "coastal_landmarks_v3"
    end
    return "harbor_edge"
  end
  if not map then 
    status("selectSceneryForMap: no map provided, defaulting to kanto_panorama")
    return "kanto_panorama" 
  end
  
  local def = map.def
  local tid = def and (def.tileset or (map.tileset and map.tileset.id))
  local mapId = map.id or ""
  
  -- Normalize tileset ID for Gen 2 compatibility
  local normalizedTid = tid
  if tid then
    -- Convert Gen 2 tileset names like "TilesetCave" to "CAVERN"
    normalizedTid = tid:gsub("Tileset", ""):upper()
  end
  
  local sceneryMap = {
    OVERWORLD = "kanto_panorama",
    FOREST = "forest_edge_a",
    PLATEAU = "route8_horizon",
    SHIP_PORT = "harbor_edge",
    CAVERN = "mt_moon_wall",
    UNDERGROUND = "mt_moon_wall",
    -- Gen 2 specific mappings
    JOHTO = "kanto_panorama",
    CAVE = "mt_moon_wall",
  }
  
  if mapId:find("viridian") then return "viridian_town" end
  if mapId:find("pallet") then return "rural_edge" end
  if mapId:find("pewter") then return "route8_midground" end
  if mapId:find("cerulean") then return "coastal_landmarks_v3" end
  if mapId:find("lavender") then return "pokemon_tower_wall" end
  if mapId:find("celadon") then return "metropolis" end
  if mapId:find("fuchsia") then return "mini_trees" end
  if mapId:find("saffron") then return "cinnabar_story_landmarks" end
  if mapId:find("cinnabar") then return "cinnabar_story_landmarks" end
  if mapId:find("forest") then return "forest_edge_a" end
  if mapId:find("moon") then return "mt_moon_wall" end
  if mapId:find("fall") then return "mt_moon_wall" end -- Waterfall areas as caves
  
  -- Try tileset matching with both original and normalized names
  if tid and sceneryMap[tid] then 
    return sceneryMap[tid] 
  end
  if normalizedTid and sceneryMap[normalizedTid] then 
    return sceneryMap[normalizedTid] 
  end
  
  return "kanto_panorama"
end

function BattleCanvas.getCanvasForBattle(map, arena)
  if not BattleCanvas.usingPaintedStage() then
    status("getCanvasForBattle: painted stage not enabled")
    return nil
  end
  
  -- Debug: log what we received
  status(("getCanvasForBattle: map=%s, arena=%s"):format(
    type(map), type(arena)))
  
  local bgName = BattleCanvas.selectBattleBackground(map, arena)
  status(("canvas pick %s (water=%s)"):format(
    tostring(bgName), tostring(BattleCanvas.onWater(map, arena))))
  local canvas = BattleCanvas.loadBattleBackground(bgName)
  if canvas then 
    status(("getCanvasForBattle: successfully loaded %s"):format(bgName))
    return canvas 
  end
  
  status(("getCanvasForBattle: failed to load %s, trying fallbacks"):format(bgName))
  if BattleCanvas.onWater(map, arena) then
    canvas = BattleCanvas.loadBattleBackground("coast-surf")
      or BattleCanvas.loadBattleBackground("coast-cinnabar")
      or BattleCanvas.loadBattleBackground("cerulean-canal")
    if canvas then return canvas end
  end
  
  status("getCanvasForBattle: all fallbacks failed, using grass-kanto-open")
  return BattleCanvas.loadBattleBackground("grass-kanto-open")
end

local function targetSize()
  local Voxel3D = V.require("Voxel3D")
  local c = Voxel3D and Voxel3D.canvas and Voxel3D.canvas()
  if c and c.getDimensions then
    return c:getDimensions()
  end
  local g = love and love.graphics
  local bound = g and g.getCanvas and g.getCanvas()
  if bound and bound.getDimensions then
    return bound:getDimensions()
  end
  if g and g.getDimensions then
    return g.getDimensions()
  end
  return 160, 144
end

local function drawCover(img, dw, dh)
  local iw, ih = img:getDimensions()
  if iw <= 0 or ih <= 0 then return end
  love.graphics.draw(img, 0, 0, 0, dw / iw, dh / ih)
end

-- Scenery sits BEHIND the arena PNG as a background layer, aspect preserved.
-- This positions scenery at the horizon line (upper portion) behind the arena.
local function drawBackgroundScenery(img, dw, dh)
  local iw, ih = img:getDimensions()
  if iw <= 0 or ih <= 0 then return end
  local scale = dw / iw
  local h = ih * scale
  if h > dh then
    scale = dh / ih
    h = dh
  end
  local x = (dw - iw * scale) * 0.5
  -- Position at horizon (upper portion) behind arena
  local y = dh * 0.05  -- 5% down from top
  love.graphics.draw(img, x, y, 0, scale, scale)
end

-- Draw the arena PNG as a screen-space backdrop on the bound battle canvas.
-- Returns true when the PNG replaced the overworld backdrop.
function BattleCanvas.drawPaintedStage(map, arena)
  if not BattleCanvas.usingPaintedStage() then return false end
  local backdrop = BattleCanvas.getCanvasForBattle(map, arena)
  if not backdrop then return false end

  local g = love.graphics
  if not (g and g.draw) then return false end

  local dw, dh = targetSize()
  local prevShader = g.getShader and g.getShader() or nil
  local cmp, write
  if g.getDepthMode then cmp, write = g.getDepthMode() end
  if g.setDepthMode then g.setDepthMode("always", false) end
  if g.setShader then g.setShader() end
  if g.setBlendMode then g.setBlendMode("alpha") end
  g.setColor(1, 1, 1, 1)

  -- Draw scenery BEHIND arena (background layer)
  local sceneryName = BattleCanvas.selectSceneryForMap(map, arena)
  local scenery = BattleCanvas.loadScenery(sceneryName)
  if scenery then
    drawBackgroundScenery(scenery, dw, dh)
  end

  -- Draw arena ON TOP of scenery (foreground layer)
  drawCover(backdrop, dw, dh)

  if g.setShader then g.setShader(prevShader) end
  if g.setDepthMode then g.setDepthMode(cmp or "lequal", write ~= false) end
  g.setColor(1, 1, 1, 1)
  return true
end

-- Kept for callers that still pass a canvas; draws into the bound target.
function BattleCanvas.drawCanvas(canvas)
  if not canvas then return end
  local g = love.graphics
  if not g then return end
  local dw, dh = targetSize()
  local prevShader = g.getShader and g.getShader() or nil
  local cmp, write
  if g.getDepthMode then cmp, write = g.getDepthMode() end
  if g.setDepthMode then g.setDepthMode("always", false) end
  if g.setShader then g.setShader() end
  g.setColor(1, 1, 1, 1)
  drawCover(canvas, dw, dh)
  if g.setShader then g.setShader(prevShader) end
  if g.setDepthMode then g.setDepthMode(cmp or "lequal", write ~= false) end
end

function BattleCanvas.getAvailableBattleBackgrounds()
  local names = {
    "cape-route25", "cave-cerulean", "cave-diglett", "cave-mt-moon",
    "cave-rock-tunnel", "cave-seafoam", "cave-victory-road",
    "cerulean-canal", "coast-cinnabar", "coast-surf",
    "forest-viridian", "grass-kanto-open", "grass-route1",
    "gym-celadon", "gym-cerulean", "gym-cinnabar", "gym-fighting-dojo",
    "gym-fuchsia", "gym-pewter", "gym-saffron", "gym-vermilion", "gym-viridian",
    "indigo-gate-route22", "indigo-road-route23", "industrial-power-plant",
    "industrial-silph", "interior-oaks-lab", "league-agatha", "league-bruno",
    "league-champion", "league-lance", "league-lorelei", "mansion-cinnabar",
    "moon-approach-route3", "moon-exit-route4", "rock-water-route10",
    "rocket-game-corner", "rocket-hideout", "route2-forest-gate",
    "safari-kanto", "ship-bow", "ship-cabins", "ship-corridor",
    "tower-lavender", "vermilion-gate-route11", "nugget_bridge_a"
  }
  local available = {}
  for _, name in ipairs(names) do
    if BattleCanvas.loadBattleBackground(name) then
      available[#available + 1] = name
    end
  end
  return available
end

function BattleCanvas.getAvailableScenery()
  local names = {
    "cinnabar_story_landmarks", "coastal_landmarks_v3", "forest_edge_a",
    "forest_edge_b", "forest_edge_c", "harbor_edge", "kanto_panorama",
    "metropolis", "mini_trees", "mt_moon_ceiling", "mt_moon_wall",
    "pokecenter_room_ceiling", "pokecenter_room_wall", "pokemon_tower_ceiling",
    "pokemon_tower_wall", "route8_horizon", "route8_midground", "rural_edge",
    "viridian_forest_gate", "viridian_town"
  }
  local available = {}
  for _, name in ipairs(names) do
    if BattleCanvas.loadScenery(name) then
      available[#available + 1] = name
    end
  end
  return available
end

function BattleCanvas.clearCache()
  for _, img in pairs(battleCache) do
    if img and img.release then pcall(img.release, img) end
  end
  for _, img in pairs(sceneryCache) do
    if img and img.release then pcall(img.release, img) end
  end
  battleCache = {}
  sceneryCache = {}
  failed = {}
  status("cache cleared")
end

return BattleCanvas
