-- Gold/Silver GBC-color atlas adapter for the voxel renderer.
--
-- Gen2Recomp stores Gold's generated tileset art as the original four GB
-- shades. The native 2D world supplies color later, per 8x8 tile, from that
-- tileset's PalMap (`tilePalettes`) and the current map/time-of-day palette
-- set. Voxel terrain cannot use the native per-quad shader after the map has
-- become 3D geometry, so this module performs the same shade substitution once
-- into a private atlas and gives that colored atlas to TerrainAtlas.
--
-- Deliberately Gen-2 only. It does not touch GbcPalette.mode and therefore
-- respects the player's COLOR option: GBC stays color, DMG stays grayscale,
-- and CLASSIC keeps the DMG staging texture which the engine's final classic
-- presentation pass turns green.

local Assets = require("src.render.Assets")
local GbcPalette = require("src.render.GbcPalette")
local Palettes = require("src.world.gen2.Palettes")

local GoldColorAtlas = {}

local cache = {}
local dataCache = {}
local lastError = nil

local function hourFor(world)
  if world and type(world.hour) == "function" then
    local ok, value = pcall(world.hour, world)
    value = ok and tonumber(value) or nil
    if value then return math.floor(value) % 24 end
  end
  local value = tonumber(world and world.clockHour)
  if value then return math.floor(value) % 24 end
  return nil -- Palettes.daytimeFor falls back to the host RTC.
end

local function flashUsedFor(world)
  if type(world) ~= "table" then return false end
  for _, key in ipairs({ "flashUsed", "usedFlash", "flashActive" }) do
    local value = world[key]
    if type(value) == "boolean" then return value end
  end
  -- Keep this conservative. A missing flash flag means a PALETTE_DARK map
  -- remains dark rather than being incorrectly lit.
  return false
end

local function paletteSetFor(world, map)
  local game = world and world.game
  local data = game and game.data and game.data.gen2Palettes
  if not data then
    return nil, nil, "Gold palette data is unavailable"
  end
  local daytime = Palettes.daytimeFor(map and map.def, hourFor(world), flashUsedFor(world))
  local set = Palettes.bgSet(data, map and map.def, daytime)
  if not set then
    return nil, daytime, "Gold map palette set could not be resolved"
  end
  return set, daytime
end

local function modeName()
  return tostring(GbcPalette.mode or "gbc")
end

-- v0.3.59 cheap invalidation probe for Kanto's Gold-material projection.
-- worldPaletteProfile below walks the PalMap several times and serializes all
-- eight active palettes. That work is appropriate when the active material
-- family changes, but not as a four-times-per-second polling mechanism.
-- Return stable scalar/reference inputs so TwinRegionWorld can skip the full
-- profile while daytime, color mode, palette-set identity and PalMap identity
-- are unchanged.
function GoldColorAtlas.worldPaletteInputs(world, map)
  map = map or (world and world.map)
  local set, daytime, err = paletteSetFor(world, map)
  if not set then return nil, nil, nil, nil, err end
  local ts = map and map.tileset or {}
  return daytime, modeName(), set, ts and ts.tilePalettes or nil, nil
end

local function shadeIndex(r)
  -- Exact companion of src/render/GbcPalette.lua's shader math. Generated 2bpp
  -- source pixels are 1, 2/3, 1/3, 0, so this lands on 1..4 with headroom.
  local shade = math.floor((1 - (tonumber(r) or 0)) * 3 + 0.5)
  if shade < 0 then shade = 0 elseif shade > 3 then shade = 3 end
  return shade + 1
end

local function tilePaletteIndex(tilePalettes, tile)
  local slot = tilePalettes and tilePalettes[tile + 1]
  slot = tonumber(slot)
  if not slot then return 1 end
  -- Gold's generated PalMap is 1-based in Lua. Be tolerant of a modded table
  -- that carried the original 0..7 bytes instead.
  if slot >= 1 and slot <= 8 then return math.floor(slot) end
  if slot >= 0 and slot <= 7 then return math.floor(slot) + 1 end
  return 1
end

local function resolvedPalette(set, slot)
  local colors = set and (set[slot] or set[1])
  if not colors then return nil end
  if type(GbcPalette.resolve) == "function" then
    local ok, resolved = pcall(GbcPalette.resolve, colors)
    if ok and resolved then return resolved end
  end
  return colors
end

-- A generation-neutral four-shade ramp representing the currently visible
-- Gold world. Kanto's Gen-1 source art has no Gen-2 PalMap, so it cannot reuse
-- Gold's eight per-tile slots one-for-one. Averaging each shade across the
-- active Gold set preserves the exact Gold/Silver color mode + time-of-day
-- family while leaving Yellow's own tile silhouettes/layout untouched.
function GoldColorAtlas.worldRamp(world, map)
  map = map or (world and world.map)
  local set, daytime, err = paletteSetFor(world, map)
  if not set then return nil, nil, err end
  local out = {}
  for shade = 1, 4 do
    local sr, sg, sb, count = 0, 0, 0, 0
    for slot = 1, 8 do
      local colors = resolvedPalette(set, slot)
      local c = colors and colors[shade]
      if c then
        sr, sg, sb = sr + (c[1] or 0), sg + (c[2] or 0), sb + (c[3] or 0)
        count = count + 1
      end
    end
    if count == 0 then return nil, nil, "Gold palette ramp is empty" end
    out[shade] = {
      math.floor(sr / count + 0.5),
      math.floor(sg / count + 0.5),
      math.floor(sb / count + 0.5),
    }
  end
  local parts = { tostring(daytime or "DAY"), modeName() }
  for shade = 1, 4 do
    local c = out[shade]
    parts[#parts + 1] = table.concat({ c[1], c[2], c[3] }, ",")
  end
  local key = table.concat(parts, "#")
  return out, key, nil
end

-- v0.2.95: expose the ACTUAL eight active Gold/Johto background palettes, not
-- just the averaged four-shade compatibility ramp. Yellow/Kanto has no Gen-2
-- PalMap, so TwinRegionWorld uses the semantic slot hints below (water, grass,
-- walkable ground, doors/structures) to map Yellow source tiles onto the same
-- palette slots the current Johto map is using. This keeps Kanto in the exact
-- active Gold color family while preserving Yellow's layouts and tile art.
local function lookupHas(lookup, tile)
  if type(lookup) ~= "table" then return false end
  if lookup[tile] == true then return true end
  for _, v in ipairs(lookup) do
    if tonumber(v) == tile then return true end
  end
  return false
end

local function slotCounts(tilePalettes, predicate)
  local counts = {}
  if type(tilePalettes) ~= "table" then return counts end
  for k, _ in pairs(tilePalettes) do
    local tile = tonumber(k)
    if tile then
      -- Lua PalMap arrays are 1-based, while tile ids are 0-based.
      tile = tile - 1
      if not predicate or predicate(tile) then
        local slot = tilePaletteIndex(tilePalettes, tile)
        counts[slot] = (counts[slot] or 0) + 1
      end
    end
  end
  return counts
end

local function dominantSlot(counts, fallback)
  local best, bestN = tonumber(fallback) or 1, -1
  for slot = 1, 8 do
    local n = tonumber(counts and counts[slot]) or 0
    if n > bestN then best, bestN = slot, n end
  end
  return best
end

function GoldColorAtlas.worldPaletteProfile(world, map)
  map = map or (world and world.map)
  local set, daytime, err = paletteSetFor(world, map)
  if not set then return nil, nil, err end
  local slots = {}
  for slot = 1, 8 do
    slots[slot] = resolvedPalette(set, slot)
  end

  local ts = map and map.tileset or {}
  local tilePalettes = ts and ts.tilePalettes
  local all = slotCounts(tilePalettes)
  local defaultSlot = dominantSlot(all, 1)
  local waterLookup = (map and map.waterTiles) or (ts and ts.waterTiles)
  local walkLookup = (map and map.walkable) or (ts and ts.walkable)
  local doorLookup = (map and map.doorTiles) or (ts and ts.doorTiles)
  local grassTile = tonumber(ts and ts.grassTile)

  local waterSlot = dominantSlot(slotCounts(tilePalettes, function(tile)
    return lookupHas(waterLookup, tile)
  end), defaultSlot)
  local groundSlot = dominantSlot(slotCounts(tilePalettes, function(tile)
    return lookupHas(walkLookup, tile)
  end), defaultSlot)
  local doorSlot = dominantSlot(slotCounts(tilePalettes, function(tile)
    return lookupHas(doorLookup, tile)
  end), groundSlot)
  local grassSlot = grassTile and tilePaletteIndex(tilePalettes, grassTile) or groundSlot
  local structureSlot = dominantSlot(slotCounts(tilePalettes, function(tile)
    return not lookupHas(waterLookup, tile) and not lookupHas(walkLookup, tile)
      and tile ~= grassTile
  end), defaultSlot)

  local parts = { tostring(daytime or "DAY"), modeName(),
    tostring(defaultSlot), tostring(waterSlot), tostring(groundSlot),
    tostring(grassSlot), tostring(doorSlot), tostring(structureSlot) }
  for slot = 1, 8 do
    local colors = slots[slot]
    for shade = 1, 4 do
      local c = colors and colors[shade] or {0,0,0}
      parts[#parts + 1] = table.concat({ c[1] or 0, c[2] or 0, c[3] or 0 }, ",")
    end
  end
  local key = table.concat(parts, "#")
  return {
    slots = slots,
    default = defaultSlot,
    water = waterSlot,
    shore = waterSlot,
    ground = groundSlot,
    grass = grassSlot,
    door = doorSlot,
    structure = structureSlot,
    daytime = daytime,
    mode = modeName(),
  }, key, nil
end

-- Exported for the headless regression probe.
function GoldColorAtlas.recolorImageData(src, tilePalettes, paletteSet, newImageData)
  if not (src and src.getDimensions and src.getPixel and paletteSet) then
    return nil, "invalid recolor inputs"
  end
  newImageData = newImageData or (love and love.image and love.image.newImageData)
  if type(newImageData) ~= "function" then return nil, "ImageData creation unavailable" end

  local w, h = src:getDimensions()
  local out = newImageData(w, h)
  local perRow = math.max(1, math.floor(w / 8))
  local palettes = {}

  for y = 0, h - 1 do
    local tileY = math.floor(y / 8)
    for x = 0, w - 1 do
      local tile = tileY * perRow + math.floor(x / 8)
      local slot = tilePaletteIndex(tilePalettes, tile)
      local colors = palettes[slot]
      if colors == nil then
        colors = resolvedPalette(paletteSet, slot) or false
        palettes[slot] = colors
      end

      local r, g, b, a = src:getPixel(x, y)
      if colors and (a == nil or a > 0) then
        local c = colors[shadeIndex(r)]
        if c then
          r, g, b = (c[1] or 0) / 255, (c[2] or 0) / 255, (c[3] or 0) / 255
        end
      end
      out:setPixel(x, y, r, g, b, a)
    end
  end
  return out
end

local function atlasPath(tileset)
  return tileset and (tileset.image or tileset.path)
end

local function cacheKey(map, tileset, daytime, flashUsed)
  return table.concat({
    tostring(atlasPath(tileset) or tileset and tileset.id or "?"),
    tostring(map and map.id or "?"),
    tostring(daytime or "DAY"),
    modeName(),
    flashUsed and "flash" or "dark",
  }, "#")
end

function GoldColorAtlas.forMap(world, map, rawAtlas)
  lastError = nil
  if not (world and map and map.tileset) then
    lastError = "Gold world/map/tileset is not ready"
    return rawAtlas, nil, false, lastError
  end
  if map.tileset.trueColor then return rawAtlas, nil, false end
  if not (love and love.image and love.image.newImageData
      and love.graphics and love.graphics.newImage) then
    lastError = "LOVE pixel/image APIs are unavailable"
    return rawAtlas, nil, false, lastError
  end

  local set, daytime, palErr = paletteSetFor(world, map)
  if not set then
    lastError = palErr
    return rawAtlas, nil, false, lastError
  end

  local key = cacheKey(map, map.tileset, daytime, flashUsedFor(world))
  if cache[key] ~= nil then
    if cache[key] then return cache[key], dataCache[key], true, nil, key end
    return rawAtlas, nil, false, lastError, key
  end

  local path = atlasPath(map.tileset)
  if not path then
    lastError = "Gold tileset has no source image path"
    cache[key] = false
    return rawAtlas, nil, false, lastError, key
  end

  local ok, image, pixels = pcall(function()
    local src = Assets.imageData(path)
    local out, err = GoldColorAtlas.recolorImageData(
      src, map.tileset.tilePalettes, set, love.image.newImageData)
    if not out then error(err or "Gold atlas recolor failed") end
    local img = love.graphics.newImage(out)
    if img and type(img.setFilter) == "function" then img:setFilter("nearest", "nearest") end
    return img, out
  end)

  if not ok or not image then
    lastError = tostring(ok and "Gold atlas image creation failed" or image)
    cache[key] = false
    dataCache[key] = false
    return rawAtlas, nil, false, lastError, key
  end

  cache[key] = image
  dataCache[key] = pixels
  return image, pixels, true, nil, key
end

function GoldColorAtlas.lastError()
  return lastError
end

function GoldColorAtlas.invalidate()
  for _, image in pairs(cache) do
    if image and image ~= false and type(image.release) == "function" then
      pcall(image.release, image)
    end
  end
  cache = {}
  dataCache = {}
  lastError = nil
end

if type(Assets.register) == "function" then Assets.register(GoldColorAtlas.invalidate) end

return GoldColorAtlas
