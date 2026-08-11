-- Kanto Gen-2 presentation projection (v0.3.41).
--
-- Yellow remains the gameplay/map-layout authority for the companion Kanto,
-- but presentation is projected through the closest live Gold/Silver tileset.
-- A matched Yellow tile inherits the donor Gen-2 tile's texture and authored
-- voxel-shape vocabulary. Since v0.3.72 its COLOR slot is resolved separately
-- from a Johto donor, so geometry can stay Kanto-correct while palette ramps
-- match Johto. The map's source tile ids/collision are never rewritten, so
-- warps, Cut, Surf, encounters and scripts stay Yellow.
--
-- GEOMETRY donor order:
--   1. Gold/Silver's native map with the SAME map id (PALLET_TOWN -> PALLET_TOWN)
--   2. native TILESET_KANTO for outdoor Kanto
--   3. a functionally similar Gen-2 interior tileset
--   4. TILESET_JOHTO as a safe outdoor fallback
--
-- COLOR donor rule in v0.3.78:
--   outdoor town/city -> TILESET_JOHTO / CHERRYGROVE_CITY
--   outdoor route     -> TILESET_JOHTO / ROUTE_29
--   indoor            -> closest functional Gen-2 interior
-- The selected donor contributes a MAP-FREQUENCY-WEIGHTED material family.
-- Every Kanto roof uses one dominant Johto roof palette, every facade one
-- facade family, routes one route family, etc.  v0.3.78 deliberately stops at
-- the PalMap ramp: Kanto/native-Kanto 2bpp shade positions stay untouched.
-- Rare alternate Johto slots cannot drift neighbouring surfaces, and no
-- histogram transfer can invent checker/dither pixels.
--
-- This is deliberately presentation-only.  It mutates only the voxel profile's
-- in-memory table by adding synthetic per-source entries; generated ROM/cache
-- data and Gold's real map definitions remain untouched.

local V = ...
local Assets = require("src.render.Assets")
local GoldColorAtlas = V.require("GoldColorAtlas")
local okPermissions, Permissions = pcall(require, "src.world.gen2.Permissions")
if not okPermissions then Permissions = nil end

local M = { PROJECTION_REV = "g2-johto-colors-380-r1" }
local VoxelProfile = V.data("voxel_heights")

local function copy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, x in pairs(v) do out[copy(k, seen)] = copy(x, seen) end
  return out
end

local function sanitize(s)
  return tostring(s or "unknown"):gsub("[^%w_]+", "_")
end

function M.profileTilesetId(raw)
  if type(raw) ~= "string" or raw:sub(1, 8) ~= "TILESET_" then return raw end
  local out = { "Tileset" }
  for word in raw:sub(9):gmatch("[^_]+") do
    local lower = word:lower()
    out[#out + 1] = lower:sub(1, 1):upper() .. lower:sub(2)
  end
  return table.concat(out)
end

local function pools(world)
  return {
    world and world.tilesets,
    world and world.game and world.game.data and world.game.data.gen2Tilesets,
    world and world.game and world.game.data and world.game.data.tilesets,
  }
end

local function tilesetById(world, id)
  if not id then return nil end
  for _, pool in ipairs(pools(world)) do
    if type(pool) == "table" and type(pool[id]) == "table" then return pool[id], id end
  end
  local want = M.profileTilesetId(id)
  for _, pool in ipairs(pools(world)) do
    if type(pool) == "table" then
      for key, ts in pairs(pool) do
        if type(ts) == "table" and M.profileTilesetId(key) == want then return ts, key end
      end
    end
  end
  return nil
end

local function nativeMapRef(world, mapId)
  local def = world and world.maps and world.maps[mapId]
  if type(def) ~= "table" then return nil end
  local ts, engineId = tilesetById(world, def.tileset)
  if not ts then return nil end
  return { id = mapId, def = def, tileset = ts, engineId = engineId or def.tileset }
end

local function refForTileset(world, engineId, preferred)
  if preferred then
    local ref = nativeMapRef(world, preferred)
    if ref and M.profileTilesetId(ref.engineId) == M.profileTilesetId(engineId) then return ref end
  end
  local maps = world and world.maps
  if type(maps) ~= "table" then return nil end
  local want = M.profileTilesetId(engineId)
  for id, def in pairs(maps) do
    if type(def) == "table" and M.profileTilesetId(def.tileset) == want then
      return nativeMapRef(world, id)
    end
  end
  return nil
end

local INTERIOR_HINTS = {
  POKECENTER = { "POKECENTER", "POKEMONCENTER" },
  MART = { "MART" }, HOUSE = { "HOUSE" }, GYM = { "GYM" },
  DOJO = { "GYM", "DOJO" }, CAVERN = { "CAVE", "CAVERN" },
  CAVE = { "CAVE", "CAVERN" }, FOREST = { "FOREST" },
  GATE = { "GATE" }, LAB = { "LAB" }, MANSION = { "MANSION" },
  CEMETERY = { "CEMETERY", "TOWER" }, LOBBY = { "LOBBY", "MANSION" },
  FACILITY = { "FACILITY", "LAB" }, PLATEAU = { "KANTO", "JOHTO" },
  SHIP = { "SHIP" }, SHIP_PORT = { "PORT", "KANTO" },
}

local function hintedTileset(world, sourceId)
  local upper = tostring(sourceId or ""):upper()
  local hints = INTERIOR_HINTS[upper]
  if not hints then
    for key, row in pairs(INTERIOR_HINTS) do
      if upper:find(key, 1, true) then hints = row break end
    end
  end
  if not hints then return nil end
  for _, hint in ipairs(hints) do
    for _, pool in ipairs(pools(world)) do
      if type(pool) == "table" then
        for id, ts in pairs(pool) do
          if type(ts) == "table" and tostring(id):upper():find(hint, 1, true) then
            return ts, id
          end
        end
      end
    end
  end
  return nil
end

local function donorFor(world, mapId, sourceDef, outdoor)
  local same = nativeMapRef(world, mapId)
  if same and same.tileset and same.tileset.image then return same end

  if outdoor then
    local ts, id = tilesetById(world, "TILESET_KANTO")
    if ts and ts.image then
      return refForTileset(world, id or "TILESET_KANTO", "PALLET_TOWN")
        or { id = "GEN2_KANTO", def = { tileset = id or "TILESET_KANTO" },
             tileset = ts, engineId = id or "TILESET_KANTO" }
    end
  else
    local ts, id = hintedTileset(world, sourceDef and sourceDef.tileset)
    if ts and ts.image then
      return refForTileset(world, id)
        or { id = "GEN2_INTERIOR", def = { tileset = id }, tileset = ts, engineId = id }
    end
  end

  local ts, id = tilesetById(world, "TILESET_JOHTO")
  if ts and ts.image then
    return refForTileset(world, id or "TILESET_JOHTO", "NEW_BARK_TOWN")
      or { id = "GEN2_JOHTO", def = { tileset = id or "TILESET_JOHTO" },
           tileset = ts, engineId = id or "TILESET_JOHTO" }
  end
  return nil
end

-- v0.3.72: geometry and color are deliberately separate decisions.  Native
-- Gold Kanto is an excellent shape/texture donor for Kanto, but using that
-- donor's own palette profile made the companion region look like a second
-- color system beside Johto.  Outdoor Kanto now always takes its active color
-- family from TILESET_JOHTO (NEW_BARK_TOWN preferred); interiors take the
-- closest Johto/Gen-2 functional interior.  Only presentation is affected.
local function colorDonorFor(world, mapId, sourceDef, outdoor)
  if outdoor then
    local ts, id = tilesetById(world, "TILESET_JOHTO")
    if ts and ts.image then
      -- v0.3.73: a canonical NEW_BARK reference is not enough for visible
      -- town parity. TILESET_JOHTO contains several valid roof/tree/building
      -- palette slots, and New Bark does not exercise the same PokeCenter/Mart
      -- city material family shown by Johto towns. Prefer a real Johto CITY
      -- for Kanto towns/cities and Route 29 for Kanto routes, then fall back.
      local upper = tostring(mapId or (sourceDef and sourceDef.id) or ""):upper()
      local preferred
      if upper:find("ROUTE", 1, true) then
        preferred = { "ROUTE_29", "CHERRYGROVE_CITY", "NEW_BARK_TOWN" }
      else
        preferred = { "CHERRYGROVE_CITY", "NEW_BARK_TOWN", "ROUTE_29" }
      end
      for _, preferredId in ipairs(preferred) do
        local ref = refForTileset(world, id or "TILESET_JOHTO", preferredId)
        if ref then return ref end
      end
      return { id = "GEN2_JOHTO", def = { tileset = id or "TILESET_JOHTO" },
               tileset = ts, engineId = id or "TILESET_JOHTO" }
    end
  else
    local ts, id = hintedTileset(world, sourceDef and sourceDef.tileset)
    if ts and ts.image then
      return refForTileset(world, id)
        or { id = "GEN2_INTERIOR_COLOR", def = { tileset = id },
             tileset = ts, engineId = id }
    end
  end
  return nil
end

M._donorFor = donorFor
M._colorDonorFor = colorDonorFor

local function setFrom(values)
  local out = {}
  if type(values) ~= "table" then return out end
  for k, v in pairs(values) do
    if type(k) == "number" then out[tonumber(v) or v] = true
    elseif v == true then out[tonumber(k) or k] = true end
  end
  return out
end

local function semantic(ts)
  return {
    water = setFrom(ts and ts.waterTiles), shore = setFrom(ts and ts.shoreTiles),
    walk = setFrom(ts and ts.walkable), doors = setFrom(ts and ts.doorTiles),
    warps = setFrom(ts and ts.warpTiles), grass = tonumber(ts and ts.grassTile),
  }
end

local function category(s, tile)
  if s.grass == tile then return "grass" end
  if s.water[tile] then return "water" end
  if s.shore[tile] then return "shore" end
  if s.doors[tile] or s.warps[tile] then return "door" end
  if s.walk[tile] then return "ground" end
  return "structure"
end

local function listHas(values, tile)
  if type(values) ~= "table" then return false end
  for _, v in ipairs(values) do if tonumber(v) == tile then return true end end
  return false
end

-- Gen 2 has collision CLASSES per 16x16 cell, not Gen-1 walkable tile lists.
-- v0.3.41 also respects the voxel profile's authored shape pins.  Collision is
-- cell-wide (a 2x2 group of 8px graphics shares one COLL_* byte), so using the
-- collision vote alone can label one quadrant of a tree/roof/fence cell as
-- "ground".  That was enough for v0.3.38 to occasionally project a walkable
-- Yellow tile onto actual Gen-2 tree art.  Profile pins are the stronger visual
-- truth and therefore win whenever they describe a non-flat material.
local SHAPE_FAMILY = {
  cylinder="tree", canopy="tree", tree="tree", stump="tree",
  fence="fence", post="fence", rail="fence",
  sign="sign", signpost="sign",
  roof="roof",
  ledge="ledge", cliff="ledge", terrace="ledge",
  wall="wall",
  stair_e="stair", stair_w="stair", stair_down_e="stair", stair_down_w="stair",
  counter="furniture", table="furniture", desk="furniture", bed="furniture",
  stool="furniture", bookcase="furniture", relief="furniture",
  prop="prop", billboard="prop", planter="prop", can="prop", bike="prop",
}

local function profileMaterial(entry, tile)
  if type(entry) ~= "table" then return nil end
  if listHas(entry.water, tile) then return "water" end
  if listHas(entry.flower, tile) or listHas(entry.grass, tile) then return "grass" end
  if listHas(entry.ground, tile) then return "ground" end
  local classes = VoxelProfile and VoxelProfile.heights or {}
  for key in pairs(classes) do
    if key ~= "ground" and key ~= "water" and key ~= "void"
        and listHas(entry[key], tile) then
      return SHAPE_FAMILY[key] or "structure"
    end
  end
  return nil
end

local function visualCategory(base, entry, tile)
  local pinned = profileMaterial(entry, tile)
  if pinned == "ground" or pinned == "water" or pinned == "grass" then
    return pinned
  end
  if pinned then return "structure:" .. pinned end
  return base
end

local function donorSemantic(ts, entry)
  local votes = {}
  if Permissions and type(ts and ts.blocks) == "table" and type(ts.collision) == "table" then
    for bi, block in ipairs(ts.blocks) do
      local quad = ts.collision[bi]
      if type(block) == "table" and type(quad) == "table" then
        for pos, tile in ipairs(block) do
          tile = tonumber(tile)
          if tile then
            local p = pos - 1
            local tx, ty = p % 4, math.floor(p / 4)
            local ci = math.floor(ty / 2) * 2 + math.floor(tx / 2) + 1
            local coll = quad[ci]
            local kind = "structure"
            if coll ~= nil then
              if type(Permissions.isImmediateWarp) == "function" and Permissions.isImmediateWarp(coll) then
                kind = "door"
              elseif type(Permissions.isWater) == "function" and Permissions.isWater(coll) then
                kind = "water"
              elseif type(Permissions.isGrass) == "function" and Permissions.isGrass(coll) then
                kind = "grass"
              elseif type(Permissions.isWalkable) == "function" and Permissions.isWalkable(coll) then
                kind = "ground"
              end
            end
            votes[tile] = votes[tile] or {}
            votes[tile][kind] = (votes[tile][kind] or 0) + 1
          end
        end
      end
    end
  end
  return function(tile)
    local pinned = profileMaterial(entry, tile)
    if pinned == "ground" or pinned == "water" or pinned == "grass" then return pinned end
    if pinned then return "structure:" .. pinned end
    local row = votes[tile]
    if row then
      local door = row.door or 0
      local water = row.water or 0
      local grass = row.grass or 0
      local ground = row.ground or 0
      local structure = row.structure or 0

      -- v0.3.41: every generic surface donor must be PURE in the Gen-2 blockset.
      -- A graphics tile reused once inside a blocked/tree/roof cell is not
      -- eligible to replace Yellow walkable ground.  This is intentionally
      -- stricter than a majority vote: a false ground->tree match is far more
      -- visible (and confusing for collision) than keeping Yellow's silhouette.
      if door > 0 and water == 0 and grass == 0 and ground == 0 and structure == 0 then
        return "door"
      end
      if water > 0 and door == 0 and grass == 0 and ground == 0 and structure == 0 then
        return "water"
      end
      -- Grass must be pure too. A Gen-2 graphics tile reused by both tall
      -- grass and ordinary floor was previously allowed into the grass donor
      -- pool, which over-greened some Yellow paths/edges even though its
      -- collision vote was mixed. Keep mixed grass/ground art out of generic
      -- surface projection just like mixed blocked/ground art.
      if grass > 0 and door == 0 and water == 0 and ground == 0 and structure == 0 then
        return "grass"
      end
      if ground > 0 and door == 0 and water == 0 and grass == 0 and structure == 0 then
        return "ground"
      end
      return "structure"
    end
    return "structure"
  end
end

-- Small pure seams for ROM-free regression probes.
M._profileMaterial = profileMaterial
M._visualCategory = visualCategory
M._donorSemantic = donorSemantic

-- Building templates know something collision/palette tables do not: which
-- 8px graphics are ROOF courses and which are FACADE courses. The user's
-- side-by-side screenshots exposed this exact missing distinction: both are
-- "structure" to collision, but Johto intentionally paints them with very
-- different slots. Build a per-tile majority role from the authored template
-- grids so Kanto roofs can inherit Johto ROOF color rather than a random
-- structure color.
local function buildingRoleMap(buildings)
  if type(buildings) ~= "table" then return nil end
  local votes = {}
  for _, template in ipairs(buildings) do
    if type(template) == "table" and type(template.tiles) == "table" then
      local roofRows = math.max(0, math.floor((tonumber(template.roofRows) or 0) / 8 + 0.5))
      for y, row in ipairs(template.tiles) do
        if type(row) == "table" then
          local role = (roofRows > 0 and y <= roofRows)
            and "building:roof" or "building:facade"
          for _, tile in ipairs(row) do
            tile = tonumber(tile)
            if tile then
              votes[tile] = votes[tile] or {}
              votes[tile][role] = (votes[tile][role] or 0) + 1
            end
          end
        end
      end
    end
  end
  local out = {}
  for tile, row in pairs(votes) do
    local roof, facade = row["building:roof"] or 0, row["building:facade"] or 0
    if roof > facade then out[tile] = "building:roof"
    elseif facade > roof then out[tile] = "building:facade" end
  end
  return next(out) and out or nil
end
M._buildingRoleMap = buildingRoleMap

-- v0.3.73: derive the color vocabulary from the tiles the chosen Johto MAP
-- actually uses. The Johto tileset contains multiple roof/wall/tree palette
-- families; searching all of it allowed Kanto to choose a technically valid
-- but visibly different brown/olive roof while the compared Johto town was
-- using its bright magenta city family. Map block usage narrows the palette
-- vote to the donor scene the player is meant to match.
local function mapUsedTiles(ref)
  local def, ts = ref and ref.def, ref and ref.tileset
  if type(def) ~= "table" or type(ts) ~= "table"
      or type(def.blocks) ~= "table" or type(ts.blocks) ~= "table" then
    return nil
  end
  local used = {}
  local function addBlock(blockId)
    blockId = tonumber(blockId)
    local block = blockId and ts.blocks[math.floor(blockId) + 1]
    if type(block) ~= "table" then return end
    for _, tile in ipairs(block) do
      tile = tonumber(tile)
      if tile then used[tile] = true end
    end
  end
  for _, blockId in ipairs(def.blocks) do addBlock(blockId) end
  addBlock(def.borderBlock)
  return next(used) and used or nil
end

local function dominantMaterialSlots(ref, donorEntry, buildingRoles)
  local ts = ref and ref.tileset
  local used = mapUsedTiles(ref)
  if type(ts) ~= "table" or type(used) ~= "table" then return nil end
  local kind = donorSemantic(ts, donorEntry)
  local counts = {}
  for tile in pairs(used) do
    local categoryId = kind(tile)
    local slot
    -- palSlot is declared later in this chunk, so read the table directly here.
    if type(ts.tilePalettes) == "table" then
      local raw = tonumber(ts.tilePalettes[tile + 1])
      if raw ~= nil then
        slot = (raw >= 1 and raw <= 8) and math.floor(raw)
          or ((raw >= 0 and raw <= 7) and math.floor(raw) + 1 or nil)
      end
    end
    if categoryId and slot then
      counts[categoryId] = counts[categoryId] or {}
      counts[categoryId][slot] = (counts[categoryId][slot] or 0) + 1
      local buildingRole = buildingRoles and buildingRoles[tile]
      if buildingRole then
        counts[buildingRole] = counts[buildingRole] or {}
        counts[buildingRole][slot] = (counts[buildingRole][slot] or 0) + 1
      end
      -- An exact structure family also contributes to the broad structure
      -- fallback, but not vice versa.
      if categoryId:sub(1, 10) == "structure:" then
        counts.structure = counts.structure or {}
        counts.structure[slot] = (counts.structure[slot] or 0) + 1
      end
    end
  end
  local out = {}
  for categoryId, row in pairs(counts) do
    local best, bestN = nil, -1
    for slot = 1, 8 do
      local n = tonumber(row[slot]) or 0
      if n > bestN then best, bestN = slot, n end
    end
    if best then out[categoryId] = best end
  end
  return next(out) and out or nil
end

M._mapUsedTiles = mapUsedTiles

-- v0.3.77: count how often each 8x8 tile is actually placed by the donor map,
-- rather than treating every used tile id as one equal vote.  The side-by-side
-- screenshots exposed why this matters: Johto tilesets contain alternate roof
-- and facade families that may be technically present but visually rare.  A
-- unique-id vote can let those rare alternates steer Kanto.  Frequency weighting
-- makes the material family match what dominates the real Johto scene.
function M._mapTileFrequencies(ref)
  local def, ts = ref and ref.def, ref and ref.tileset
  if type(def) ~= "table" or type(ts) ~= "table"
      or type(def.blocks) ~= "table" or type(ts.blocks) ~= "table" then
    return nil
  end
  local counts = {}
  local function addBlock(blockId, weight)
    blockId = tonumber(blockId)
    local block = blockId and ts.blocks[math.floor(blockId) + 1]
    if type(block) ~= "table" then return end
    weight = math.max(1, math.floor(tonumber(weight) or 1))
    for _, tile in ipairs(block) do
      tile = tonumber(tile)
      if tile then counts[tile] = (counts[tile] or 0) + weight end
    end
  end
  local blockCounts = {}
  for _, blockId in ipairs(def.blocks) do
    blockId = tonumber(blockId)
    if blockId ~= nil then blockCounts[blockId] = (blockCounts[blockId] or 0) + 1 end
  end
  for blockId, n in pairs(blockCounts) do addBlock(blockId, n) end
  -- Only fall back to the border if the map has no ordinary block body.  The
  -- border is repeated outside the authored map and must not dominate a city.
  if not next(counts) and def.borderBlock ~= nil then addBlock(def.borderBlock, 1) end
  return next(counts) and counts or nil
end

-- One stable visible material per semantic family.  Slot selection is weighted
-- by actual donor-map placement frequency; the representative tile is the most
-- frequent tile using that winning slot.  `tile` is used only for its 2bpp shade
-- population -- never for spatial pixel placement.
function M._materialProfiles(ref, donorEntry, buildingRoles)
  local ts = ref and ref.tileset
  if type(ts) ~= "table" then return nil end
  local freq = M._mapTileFrequencies(ref)
  if not freq then
    local used = mapUsedTiles(ref)
    if not used then return nil end
    freq = {}; for tile in pairs(used) do freq[tile] = 1 end
  end
  local kind = donorSemantic(ts, donorEntry)
  local groups = {}
  local function rawSlot(tile)
    local raw = type(ts.tilePalettes) == "table" and tonumber(ts.tilePalettes[tile + 1]) or nil
    if raw == nil then return nil end
    if raw >= 1 and raw <= 8 then return math.floor(raw) end
    if raw >= 0 and raw <= 7 then return math.floor(raw) + 1 end
    return nil
  end
  local function add(categoryId, tile, weight)
    local slot = rawSlot(tile)
    if not (categoryId and slot) then return end
    local g = groups[categoryId]
    if not g then g = { slotWeights = {}, tiles = {} }; groups[categoryId] = g end
    g.slotWeights[slot] = (g.slotWeights[slot] or 0) + weight
    g.tiles[tile] = (g.tiles[tile] or 0) + weight
  end
  for tile, weight in pairs(freq) do
    tile, weight = tonumber(tile), math.max(1, math.floor(tonumber(weight) or 1))
    if tile then
      local base = kind(tile)
      local role = buildingRoles and buildingRoles[tile]
      add(role or base, tile, weight)
      if role then add(base, tile, weight) end
      if (role and role:sub(1, 9) == "building:")
          or (base and base:sub(1, 10) == "structure:") then
        add("structure", tile, weight)
      end
    end
  end
  local out = {}
  for categoryId, g in pairs(groups) do
    local bestSlot, bestSlotWeight = nil, -1
    for slot = 1, 8 do
      local n = tonumber(g.slotWeights[slot]) or 0
      if n > bestSlotWeight then bestSlot, bestSlotWeight = slot, n end
    end
    if bestSlot then
      local bestTile, bestTileWeight = nil, -1
      for tile, weight in pairs(g.tiles) do
        if rawSlot(tile) == bestSlot and (weight > bestTileWeight
            or (weight == bestTileWeight and (bestTile == nil or tile < bestTile))) then
          bestTile, bestTileWeight = tile, weight
        end
      end
      out[categoryId] = { slot = bestSlot, tile = bestTile, weight = bestSlotWeight }
    end
  end
  return next(out) and out or nil
end

-- Resolve fallback families without allowing a rare per-tile match to override
-- a coherent scene-wide material lock.
function M._materialProfile(style, categoryId)
  local p = style and style.materialProfiles
  if type(p) ~= "table" then return nil end
  local row = categoryId and p[categoryId]
  if row then return row end
  if categoryId == "shore" then return p.water or p.ground end
  if categoryId == "grass" then return p.grass or p.ground end
  if categoryId == "door" then return p.door or p["building:facade"] or p.structure end
  if type(categoryId) == "string"
      and (categoryId:sub(1, 10) == "structure:" or categoryId:sub(1, 9) == "building:") then
    return p.structure
  end
  return p[categoryId or ""] or p.structure
end

function M._mergeMaterialProfiles(primary, fallback)
  local out = primary or {}
  for categoryId, row in pairs(fallback or {}) do
    if out[categoryId] == nil then out[categoryId] = row end
  end
  return out
end

M._dominantMaterialSlots = dominantMaterialSlots

local function countTiles(data)
  if not (data and data.getDimensions) then return 0 end
  local w, h = data:getDimensions()
  return math.floor(w / 8) * math.floor(h / 8)
end

local function mse(a, aper, at, b, bper, bt)
  local ax, ay = (at % aper) * 8, math.floor(at / aper) * 8
  local bx, by = (bt % bper) * 8, math.floor(bt / bper) * 8
  local sum = 0
  for y = 0, 7 do
    for x = 0, 7 do
      local ar = select(1, a:getPixel(ax + x, ay + y)) or 0
      local br = select(1, b:getPixel(bx + x, by + y)) or 0
      local d = ar - br
      sum = sum + d * d
    end
  end
  return sum / 64
end

-- v0.3.40 is intentionally stricter than the old v0.3.30 visual matcher.
-- Generic surfaces always take the nearest Gen-2 donor inside their semantic
-- class.  Unique structures still require a recognizable pattern so landmarks
-- are not turned into arbitrary houses/rocks.
local LIMIT = { water=math.huge, shore=math.huge, grass=math.huge,
                ground=math.huge, door=0.18, structure=0.10,
                ["structure:tree"]=math.huge, ["structure:fence"]=math.huge,
                ["structure:sign"]=math.huge, ["structure:roof"]=math.huge,
                ["structure:ledge"]=math.huge, ["structure:wall"]=0.22,
                ["structure:stair"]=0.22, ["structure:furniture"]=0.16,
                ["structure:prop"]=0.18 }

-- v0.3.76 keeps the scene/role-restricted donor SELECTION but never pastes
-- that donor tile's pixel pattern onto Kanto. The selected Johto tile supplies
-- exact PalMap identity and the target 2bpp shade POPULATION; spatial texture
-- remains Kanto/native-Kanto.
local function buildSceneColorRemap(src, sourceTs, sourceEntry, sourceRoles,
                                    donor, donorTs, donorEntry, donorRoles, used)
  local sp = tonumber(sourceTs and sourceTs.tilesPerRow) or 16
  local dp = tonumber(donorTs and donorTs.tilesPerRow) or 16
  local ss = semantic(sourceTs)
  local donorKind = donorSemantic(donorTs, donorEntry)
  local by = { water={}, shore={}, grass={}, ground={}, door={}, structure={} }
  for dt in pairs(used or {}) do
    dt = tonumber(dt)
    if dt then
      local c = (donorRoles and donorRoles[dt]) or donorKind(dt)
      by[c] = by[c] or {}
      by[c][#by[c] + 1] = dt
      if c:sub(1, 10) == "structure:" or c:sub(1, 9) == "building:" then
        by.structure[#by.structure + 1] = dt
      end
    end
  end
  by.shore = (#by.water > 0) and by.water or by.ground
  if #by.grass == 0 then by.grass = by.ground end
  if #by.door == 0 then by.door = (#by.structure > 0) and by.structure or by.ground end

  local nearest, cats = {}, {}
  for t = 0, countTiles(src) - 1 do
    local c = (sourceRoles and sourceRoles[t])
      or visualCategory(category(ss, t), sourceEntry, t)
    local candidates = by[c]
    if (not candidates or #candidates == 0)
        and (c:sub(1, 10) == "structure:" or c:sub(1, 9) == "building:") then
      candidates = by.structure
    end
    if candidates and #candidates > 0 then
      local best, bestErr = nil, math.huge
      for _, dt in ipairs(candidates) do
        local e = mse(src, sp, t, donor, dp, dt)
        if e < bestErr then best, bestErr = dt, e end
      end
      if best then nearest[t], cats[t] = best, c end
    end
  end
  return nearest, cats
end
M._buildSceneColorRemap = buildSceneColorRemap

local function buildRemap(src, sourceTs, sourceEntry, donor, donorTs, donorEntry)
  local sp = tonumber(sourceTs and sourceTs.tilesPerRow) or 16
  local dp = tonumber(donorTs and donorTs.tilesPerRow) or 16
  local ss = semantic(sourceTs)
  local donorKind = donorSemantic(donorTs, donorEntry)
  local by = { water={}, shore={}, grass={}, ground={}, door={}, structure={} }
  for t = 0, countTiles(donor) - 1 do
    local c = donorKind(t)
    by[c] = by[c] or {}
    by[c][#by[c] + 1] = t
    -- Exact shape families are also eligible for the broad structure bucket,
    -- but broad structure tiles never enter a tree/fence/roof bucket.
    if c:sub(1, 10) == "structure:" then
      by.structure[#by.structure + 1] = t
    end
  end
  by.shore = (#by.water > 0) and by.water or by.ground
  if #by.grass == 0 then by.grass = by.ground end
  if #by.door == 0 then by.door = (#by.structure > 0) and by.structure or by.ground end

  local out, err, cats, nearest = {}, {}, {}, {}
  for t = 0, countTiles(src) - 1 do
    local c = visualCategory(category(ss, t), sourceEntry, t)
    local candidates = by[c]
    if (not candidates or #candidates == 0) and c:sub(1, 10) == "structure:" then
      candidates = by.structure
    end
    if candidates and #candidates > 0 then
      local best, bestErr = nil, math.huge
      for _, dt in ipairs(candidates) do
        local e = mse(src, sp, t, donor, dp, dt)
        if e < bestErr then best, bestErr = dt, e end
      end
      if best then
        nearest[t], err[t], cats[t] = best, bestErr, c
        local limit = LIMIT[c] or (c:sub(1, 10) == "structure:" and LIMIT.structure) or 0.06
        if bestErr <= limit then out[t] = best end
      end
    end
  end
  return out, err, cats, nearest
end

local function palSlot(ts, tile)
  local p = ts and ts.tilePalettes
  if type(p) ~= "table" then return nil end
  local n = tonumber(p[(tonumber(tile) or 0) + 1])
  if n == nil then return nil end
  if n >= 1 and n <= 8 then return math.floor(n) end
  if n >= 0 and n <= 7 then return math.floor(n) + 1 end
  return nil
end

local function profileSlot(profile, s, tile)
  if not profile then return 1 end
  if s.water[tile] then return profile.water or profile.default or 1 end
  if s.shore[tile] then return profile.shore or profile.water or profile.default or 1 end
  if s.grass == tile then return profile.grass or profile.ground or profile.default or 1 end
  if s.doors[tile] or s.warps[tile] then return profile.door or profile.structure or profile.default or 1 end
  if s.walk[tile] then return profile.ground or profile.default or 1 end
  return profile.structure or profile.default or 1
end

local function shadeIndex(r)
  -- Same rounding Gen1Recomp's native GoldColorAtlas uses for generated 2bpp
  -- art: 1, 2/3, 1/3, 0 -> palette shades 1..4 exactly.
  local shade = math.floor((1 - (tonumber(r) or 0)) * 3 + 0.5)
  if shade < 0 then shade = 0 elseif shade > 3 then shade = 3 end
  return shade + 1
end

M._shadeIndex = shadeIndex

-- Exact native-donor pixel color.  This is the same operation GoldColorAtlas
-- performs for a Gen-2 tile: PalMap chooses one of the eight active palettes,
-- then the 2bpp source shade indexes that four-color ramp.  Sampling this for
-- matched tiles avoids any semantic fallback entirely.
local function donorColor(style, tile, r)
  local slots = style and style.profile and style.profile.slots
  local slot = palSlot(style and style.donorTs, tile)
  local colors = slots and slot and slots[slot]
  local c = colors and colors[shadeIndex(r)]
  if not c then return nil end
  return (c[1] or 0) / 255, (c[2] or 0) / 255, (c[3] or 0) / 255
end
M._donorColor = donorColor

local function shade(colors, r)
  local c = colors[shadeIndex(r)] or colors[1] or {0,0,0}
  return (c[1] or 0)/255, (c[2] or 0)/255, (c[3] or 0)/255
end

-- v0.3.75 used a four-entry shade map. That cannot reproduce Johto when one
-- Kanto shade occupies most of a tile: every pixel of that source shade moved
-- together, so a 75% pale wall stayed a 75% single-color wall. v0.3.76 keeps
-- this helper for compatibility/tests, but colorize now uses the exact transfer
-- plan below, which can split one source shade into several target shades.
function M._tileShadeHistogram(data, per, tile)
  if not (data and data.getPixel and tile ~= nil) then return nil end
  per = math.max(1, math.floor(tonumber(per) or 1))
  tile = math.max(0, math.floor(tonumber(tile) or 0))
  local out = { 0, 0, 0, 0 }
  local ox, oy = (tile % per) * 8, math.floor(tile / per) * 8
  for y = 0, 7 do
    for x = 0, 7 do
      local r = select(1, data:getPixel(ox + x, oy + y)) or 0
      local i = shadeIndex(r)
      out[i] = out[i] + 1
    end
  end
  return out
end

function M._shadeBalanceMap(srcData, srcPer, srcTile, dstData, dstPer, dstTile)
  local a = M._tileShadeHistogram(srcData, srcPer, srcTile)
  local b = M._tileShadeHistogram(dstData, dstPer, dstTile)
  if not (a and b) then return nil end
  local at, bt = 0, 0
  for i = 1, 4 do at = at + a[i]; bt = bt + b[i] end
  if at <= 0 or bt <= 0 then return nil end

  local out, ac = {}, 0
  for i = 1, 4 do
    local n = a[i]
    if n <= 0 then
      out[i] = i
    else
      local q = (ac + n * 0.5) / at
      local bc, picked = 0, 4
      for j = 1, 4 do
        bc = bc + b[j] / bt
        if q <= bc then picked = j break end
      end
      out[i] = picked
    end
    ac = ac + n
  end
  -- Keep the mapping monotonic so a dark Kanto texel can never become lighter
  -- than a texel that was already lighter beside it.
  for i = 2, 4 do
    if out[i] < out[i - 1] then out[i] = out[i - 1] end
  end
  return out
end

local function shadeMapped(colors, r, map)
  local idx = shadeIndex(r)
  local c = colors[(map and map[idx]) or idx] or colors[idx] or colors[1] or {0,0,0}
  return (c[1] or 0)/255, (c[2] or 0)/255, (c[3] or 0)/255
end

-- v0.3.76 retained helper: exact shade-population transfer.  v0.3.78 no
-- longer uses this in the visible Kanto atlas.  The screenshot feedback made
-- the failure mode unambiguous: splitting one source shade across several
-- target shades creates a synthetic checker/dither texture that native Johto
-- does not have on those Kanto surfaces.  Keep the helper only for old cache /
-- regression compatibility; colorize() below now preserves each Kanto/native-
-- Kanto 2bpp shade index exactly and changes COLOR only.
local BAYER8 = {
   0,48,12,60, 3,51,15,63,
  32,16,44,28,35,19,47,31,
   8,56, 4,52,11,59, 7,55,
  40,24,36,20,43,27,39,23,
   2,50,14,62, 1,49,13,61,
  34,18,46,30,33,17,45,29,
  10,58, 6,54, 9,57, 5,53,
  42,26,38,22,41,25,37,21,
}

function M._shadeTransferPlan(srcData, srcPer, srcTile, dstData, dstPer, dstTile)
  local target = M._tileShadeHistogram(dstData, dstPer, dstTile)
  if not (srcData and srcData.getPixel and target) then return nil end
  srcPer = math.max(1, math.floor(tonumber(srcPer) or 1))
  srcTile = math.max(0, math.floor(tonumber(srcTile) or 0))
  local ox, oy = (srcTile % srcPer) * 8, math.floor(srcTile / srcPer) * 8
  local pixels = {}
  for y = 0, 7 do
    for x = 0, 7 do
      local r = select(1, srcData:getPixel(ox + x, oy + y)) or 0
      local pos = y * 8 + x + 1
      pixels[#pixels + 1] = {
        pos = pos, shade = shadeIndex(r), tie = BAYER8[pos] or (pos - 1),
      }
    end
  end
  table.sort(pixels, function(a, b)
    if a.shade ~= b.shade then return a.shade < b.shade end
    if a.tie ~= b.tie then return a.tie < b.tie end
    return a.pos < b.pos
  end)

  local plan, cursor = {}, 1
  for targetShade = 1, 4 do
    local n = math.max(0, math.floor(tonumber(target[targetShade]) or 0))
    for _ = 1, n do
      local px = pixels[cursor]
      if not px then break end
      plan[px.pos] = targetShade
      cursor = cursor + 1
    end
  end
  -- Defensive completion for malformed/transparent donor probes.
  while cursor <= #pixels do
    local px = pixels[cursor]
    plan[px.pos] = px.shade
    cursor = cursor + 1
  end
  return plan
end

local function shadeTransferred(colors, r, plan, lx, ly)
  local pos = (tonumber(ly) or 0) * 8 + (tonumber(lx) or 0) + 1
  local idx = (plan and plan[pos]) or shadeIndex(r)
  local c = colors[idx] or colors[shadeIndex(r)] or colors[1] or {0,0,0}
  return (c[1] or 0)/255, (c[2] or 0)/255, (c[3] or 0)/255
end

local function resolvedColorSlot(style, sourceTs, tile, geometryTile)
  local ss = semantic(sourceTs)
  local colorTs = style and (style.colorDonorTs or style.donorTs)
  local categoryId = style and style.categories and style.categories[tile]
  -- v0.3.77: scene-wide MATERIAL FAMILY LOCK wins first.  Per-tile nearest
  -- donors were individually valid but made neighbouring Kanto surfaces jump
  -- between Johto's alternate palette families.  One frequency-weighted slot
  -- per role is visually coherent and matches the donor scene as a whole.
  local materialProfile = M._materialProfile(style, categoryId)
  if materialProfile and materialProfile.slot then return materialProfile.slot end
  local materialSlot = categoryId and style.materialSlots and style.materialSlots[categoryId]
  if materialSlot then return materialSlot end
  local colorTile = style and style.colorSlotDonor and style.colorSlotDonor[tile]
  if colorTile ~= nil then
    local exact = palSlot(colorTs, colorTile)
    if exact then return exact end
  end
  -- Older styles did not have a dedicated color donor. Preserve their exact
  -- behavior by falling back to the geometry donor when both roles are the same.
  if colorTile == nil and style and colorTs == style.donorTs then
    colorTile = geometryTile or (style.slotDonor and style.slotDonor[tile])
  end
  return (colorTile ~= nil and palSlot(colorTs, colorTile))
    or profileSlot(style and style.profile, ss, tile)
end
M._resolvedColorSlot = resolvedColorSlot

function M.colorize(src, sourceTs, style)
  if not (src and style and love and love.image and love.image.newImageData) then return nil end
  local w, h = src:getDimensions()
  local out = love.image.newImageData(w, h)
  local sourcePer = math.max(1, math.floor(w / 8))
  local donor, donorTs = style.donorPixels, style.donorTs
  local donorPer = tonumber(donorTs and donorTs.tilesPerRow) or 16
  local slots = style.profile and style.profile.slots or nil
  local slotCache = {}
  for y = 0, h - 1 do
    local ty = math.floor(y / 8)
    for x = 0, w - 1 do
      local tile = ty * sourcePer + math.floor(x / 8)
      local dt = style.remap and style.remap[tile]
      local slot = resolvedColorSlot(style, sourceTs, tile, dt)
      local colors = slotCache[slot]
      if colors == nil then
        colors = slots and (slots[slot] or slots[style.profile.default or 1]) or false
        slotCache[slot] = colors or false
      end

      -- Spatial pattern authority stays with Kanto/native-Kanto.  Geometry
      -- matching may choose a native Gen-2 Kanto tile; otherwise the source
      -- Yellow/Kanto tile remains the shade-pattern source.
      local r, g, b, a = src:getPixel(x, y)
      if dt and donor then
        local lx, ly = x % 8, y % 8
        local dr, dg, db = donor:getPixel((dt % donorPer) * 8 + lx,
                                         math.floor(dt / donorPer) * 8 + ly)
        r, g, b = dr, dg, db
      end

      if colors then
        -- v0.3.78: Johto supplies the MATERIAL PALETTE, never a synthetic
        -- texture distribution.  Keeping the native Kanto/Gen-2-Kanto shade
        -- index per texel is what removes the screenshot-confirmed black/brown
        -- checker field from paths and the speckled facade noise.  The result
        -- is the same clean four-shade relationship the Gold renderer uses:
        -- source 2bpp shade -> selected Johto PalMap ramp.
        r, g, b = shade(colors, r)
      end
      out:setPixel(x, y, r, g, b, a)
    end
  end
  return out
end

local function numericArray(t)
  if type(t) ~= "table" or #t == 0 then return false end
  for i = 1, #t do if tonumber(t[i]) == nil then return false end end
  return true
end

local function uniqueList(values)
  local out, seen = {}, {}
  for _, v in ipairs(values or {}) do
    v = tonumber(v)
    if v and not seen[v] then seen[v] = true; out[#out + 1] = v end
  end
  table.sort(out)
  return out
end

local function mappedSources(remap, donorSet)
  local out = {}
  for src, dt in pairs(remap or {}) do
    if donorSet[dt] then out[#out + 1] = src end
  end
  return uniqueList(out)
end

local function reverseMap(remap)
  local out = {}
  for src, dt in pairs(remap or {}) do
    out[dt] = out[dt] or {}
    out[dt][#out[dt] + 1] = src
  end
  return out
end

local function convertConditions(rows, rev)
  if type(rows) ~= "table" then return nil end
  local out = {}
  for donorTile, rules in pairs(rows) do
    local sources = rev[tonumber(donorTile)]
    if sources then
      for _, src in ipairs(sources) do
        local dst = {}
        for _, rule in ipairs(type(rules) == "table" and rules or {}) do
          local nr = { class = rule.class }
          for _, side in ipairs({ "above", "below" }) do
            if type(rule[side]) == "table" then
              local list = {}
              for _, dt in ipairs(rule[side]) do
                for _, s in ipairs(rev[tonumber(dt)] or {}) do list[#list + 1] = s end
              end
              nr[side] = uniqueList(list)
            end
          end
          if (nr.above and #nr.above > 0) or (nr.below and #nr.below > 0) then
            dst[#dst + 1] = nr
          end
        end
        if #dst > 0 then out[src] = dst end
      end
    end
  end
  return next(out) and out or nil
end

function M.installSyntheticProfile(sourceProfileId, style)
  if not (style and style.donorProfileId and style.remap) then return sourceProfileId end
  local data = VoxelProfile
  if not (type(data) == "table" and type(data.tilesets) == "table") then return sourceProfileId end
  sourceProfileId = sourceProfileId or "OVERWORLD"
  local donor = data.tilesets[style.donorProfileId]
  if type(donor) ~= "table" then return sourceProfileId end

  local id = "KantoGen2_" .. sanitize(sourceProfileId) .. "_" .. sanitize(style.donorProfileId)
    .. "_" .. sanitize(M.PROJECTION_REV)
  if data.tilesets[id] then return id end

  local base = copy(data.tilesets[sourceProfileId] or {})
  local classes = data.heights or {}
  local matched = {}
  for src in pairs(style.remap) do matched[src] = true end

  -- Gen-2 classification wins for mapped tiles. Remove those tiles from any
  -- source authored SHAPE group first, then add them back under the donor's
  -- class. Non-shape metadata (tree_art, rail_face, figures...) is untouched
  -- here and handled explicitly below.
  for key, values in pairs(base) do
    if classes[key] ~= nil and numericArray(values) then
      local kept = {}
      for _, tile in ipairs(values) do if not matched[tonumber(tile)] then kept[#kept + 1] = tile end end
      base[key] = kept
    end
  end
  for key, values in pairs(donor) do
    if classes[key] ~= nil and numericArray(values) then
      local ds = {}; for _, t in ipairs(values) do ds[tonumber(t)] = true end
      local got = mappedSources(style.remap, ds)
      -- Flat Kanto material categories are authoritative for geometry. A
      -- nearest-image donor is allowed to choose their Johto COLOR family,
      -- but it may never promote water/shore/ground/grass into a standing
      -- wall/tree/prop class. This closes the source of the tall green meshes
      -- that appeared over Kanto water after geometry projection.
      if key ~= "ground" and key ~= "water" and key ~= "grass" and key ~= "flower"
          and type(style.categories) == "table" then
        local filtered = {}
        for _, src in ipairs(got) do
          local c = style.categories[src]
          if c ~= "water" and c ~= "shore" and c ~= "ground" and c ~= "grass" then
            filtered[#filtered + 1] = src
          end
        end
        got = filtered
      end
      if #got > 0 then
        local merged = {}; for _, t in ipairs(base[key] or {}) do merged[#merged + 1] = t end
        for _, t in ipairs(got) do merged[#merged + 1] = t end
        base[key] = uniqueList(merged)
      end
    end
  end

  -- Geometry metadata used by Structures rather than TileShape classes.
  for _, key in ipairs({ "tree_crown", "tree_art", "rail_face" }) do
    if numericArray(donor[key]) then
      local ds = {}; for _, t in ipairs(donor[key]) do ds[tonumber(t)] = true end
      local got = mappedSources(style.remap, ds)
      if #got > 0 then base[key] = got end
    end
  end
  for _, key in ipairs({ "planter_spray", "planter_tree_crown", "hop_lips",
                         "bookcase_relief" }) do
    if donor[key] ~= nil then base[key] = donor[key] end
  end
  if type(donor.heights) == "table" then
    base.heights = base.heights or {}
    for k, v in pairs(donor.heights) do base.heights[k] = v end
  end

  local rev = reverseMap(style.remap)
  local above = convertConditions(donor.when_above, rev)
  local below = convertConditions(donor.when_below, rev)
  if above then base.when_above = above end
  if below then base.when_below = below end

  -- Convert simple prop-ground relationships when both donor tiles have a
  -- source counterpart. These are visual only; Cut's gameplay swap stays on
  -- the original Yellow block data.
  if type(donor.prop_ground) == "table" then
    local pg = copy(base.prop_ground or {})
    for dt, dg in pairs(donor.prop_ground) do
      for _, src in ipairs(rev[tonumber(dt)] or {}) do
        local grounds = rev[tonumber(dg)]
        if grounds and grounds[1] then pg[src] = grounds[1] end
      end
    end
    if next(pg) then base.prop_ground = pg end
  end

  data.tilesets[id] = base
  -- Preserve Kanto/source exact building templates. The new terrain/material
  -- profile changes the surface vocabulary; it does not pretend a Yellow
  -- landmark has the same tile grid as a Johto house.
  data.buildings = data.buildings or {}
  if data.buildings[sourceProfileId] and not data.buildings[id] then
    data.buildings[id] = copy(data.buildings[sourceProfileId])
  end
  style.syntheticProfileId = id
  return id
end

function M.forMap(region, world, mapId, sourceDef, sourceTs, sourcePixels, outdoor)
  if not (region and world and sourceTs and sourcePixels) then return nil end
  region.gen2DonorCache = region.gen2DonorCache or {}
  local donorRef = donorFor(world, mapId, sourceDef, outdoor == true)
  if not donorRef or not donorRef.tileset then return nil end
  local donorTs = donorRef.tileset
  local engineId = donorRef.engineId or (donorRef.def and donorRef.def.tileset) or donorTs.id
  local donorProfileId = M.profileTilesetId(engineId)
  local donorPath = donorTs.image
  if type(donorPath) ~= "string" or donorPath == "" then return nil end

  local donorKey = tostring(engineId) .. "|" .. donorPath
  local donorRec = region.gen2DonorCache[donorKey]
  if not donorRec then
    local ok, pixels = pcall(Assets.imageData, donorPath)
    if not (ok and pixels and pixels.getPixel) then return nil end
    donorRec = { pixels = pixels, ts = donorTs }
    region.gen2DonorCache[donorKey] = donorRec
  end

  local remapKey = tostring(sourceDef and sourceDef.tileset or sourceTs.id or sourceTs.image)
    .. "|" .. donorKey
  region.gen2RemapCache = region.gen2RemapCache or {}
  local remapRec = region.gen2RemapCache[remapKey]
  if not remapRec then
    local shapes = VoxelProfile
    local donorEntry = shapes and shapes.tilesets and shapes.tilesets[donorProfileId]
    local sourceProfileId = M.profileTilesetId(sourceDef and sourceDef.tileset or sourceTs.id)
    local sourceEntry = shapes and shapes.tilesets and
      (shapes.tilesets[sourceProfileId] or shapes.tilesets[sourceDef and sourceDef.tileset])
    local remap, errors, cats, nearest = buildRemap(sourcePixels, sourceTs, sourceEntry,
      donorRec.pixels, donorTs, donorEntry)
    local n = 0; for _ in pairs(remap) do n = n + 1 end
    remapRec = { remap = remap, errors = errors, categories = cats,
      nearest = nearest, matches = n }
    region.gen2RemapCache[remapKey] = remapRec
  end

  -- Build a second donor record for visible COLOR. Outdoor Kanto must look
  -- like Johto even when its geometry comes from native TILESET_KANTO. Since
  -- v0.3.77 its scene is reduced to frequency-weighted material families so
  -- neighbouring Kanto tiles cannot drift among alternate valid Johto slots.
  local colorRef = colorDonorFor(world, mapId, sourceDef, outdoor == true) or donorRef
  local colorTs = colorRef and colorRef.tileset or donorTs
  local colorEngineId = colorRef and (colorRef.engineId
    or (colorRef.def and colorRef.def.tileset) or colorTs.id) or engineId
  local colorPath = colorTs and colorTs.image
  local colorKey = tostring(colorEngineId) .. "|" .. tostring(colorPath or "")
    .. "|map:" .. tostring(colorRef and colorRef.id or "none")
  local colorRec = region.gen2DonorCache[colorKey]
  if not colorRec and type(colorPath) == "string" and colorPath ~= "" then
    local ok, pixels = pcall(Assets.imageData, colorPath)
    if ok and pixels and pixels.getPixel then
      colorRec = { pixels = pixels, ts = colorTs }
      region.gen2DonorCache[colorKey] = colorRec
    end
  end

  -- Never interpret a geometry donor tile id in a different color donor's
  -- PalMap. Keep the scene restriction; v0.3.77 uses per-tile matches only as a
  -- fallback/diagnostic. The visible slot/shade target is locked by material
  -- family and actual donor-map placement frequency.
  -- Authored roof/facade roles remain aligned so multi-color Johto facade
  -- vocabulary survives without painting Johto bricks/stripes onto Kanto.
  local colorProfileId = M.profileTilesetId(colorEngineId)
  local shapes = VoxelProfile
  local colorShapes = shapes and shapes.tilesets
  local donorEntry = colorShapes and (colorShapes[colorProfileId]
    or colorShapes[colorEngineId])
  local sourceProfileIdForColor = M.profileTilesetId(sourceDef and sourceDef.tileset or sourceTs.id)
  local sourceEntry = colorShapes and
    (colorShapes[sourceProfileIdForColor] or colorShapes[sourceDef and sourceDef.tileset])
  local buildingSets = shapes and shapes.buildings
  local donorBuildingRoles = buildingRoleMap(buildingSets and
    (buildingSets[colorProfileId] or buildingSets[colorEngineId]))
  local sourceBuildingRoles = buildingRoleMap(buildingSets and
    (buildingSets[sourceProfileIdForColor] or buildingSets[sourceDef and sourceDef.tileset]))
  local materialProfiles = M._materialProfiles(colorRef, donorEntry, donorBuildingRoles) or {}
  -- A route donor can legitimately lack civic roofs/facades; a city donor can
  -- lack one of the route-only edge families. Fill only MISSING roles from the
  -- other canonical Johto outdoor scenes so no Kanto surface falls through to
  -- a generic structure slot just because its primary donor map does not show
  -- that family. Primary-scene choices always win.
  if outdoor == true and M.profileTilesetId(colorEngineId) == M.profileTilesetId("TILESET_JOHTO") then
    local preferred = (colorRef and colorRef.id == "ROUTE_29")
      and { "CHERRYGROVE_CITY", "NEW_BARK_TOWN" }
      or { "ROUTE_29", "NEW_BARK_TOWN" }
    for _, supplementId in ipairs(preferred) do
      local supplementRef = refForTileset(world, colorEngineId, supplementId)
      if supplementRef and supplementRef.id ~= (colorRef and colorRef.id) then
        materialProfiles = M._mergeMaterialProfiles(materialProfiles,
          M._materialProfiles(supplementRef, donorEntry, donorBuildingRoles))
      end
    end
  end
  local materialSlots = {}
  for categoryId, row in pairs(materialProfiles or {}) do
    if row and row.slot then materialSlots[categoryId] = row.slot end
  end
  if not next(materialSlots) then
    materialSlots = dominantMaterialSlots(colorRef, donorEntry, donorBuildingRoles) or {}
  end

  local colorSlotDonor = (colorTs == donorTs) and remapRec.nearest or nil
  local colorCategories = copy(remapRec.categories or {})
  -- Classify every Kanto source tile up front.  Previous versions only gained
  -- a category when a scene-remap candidate existed, which is another route to
  -- 'some good, some bad' fallbacks on uncommon facade/trim tiles.
  local sourceSemantics = semantic(sourceTs)
  for tile = 0, countTiles(sourcePixels) - 1 do
    colorCategories[tile] = (sourceBuildingRoles and sourceBuildingRoles[tile])
      or colorCategories[tile]
      or visualCategory(category(sourceSemantics, tile), sourceEntry, tile)
  end
  if colorRec and colorTs ~= donorTs then
    local colorRemapKey = tostring(sourceDef and sourceDef.tileset or sourceTs.id or sourceTs.image)
      .. "|color380|" .. colorKey
    local colorMapRec = region.gen2RemapCache[colorRemapKey]
    if not colorMapRec then
      local used = mapUsedTiles(colorRef)
      local nearest, cats = buildSceneColorRemap(sourcePixels, sourceTs, sourceEntry,
        sourceBuildingRoles, colorRec.pixels, colorTs, donorEntry,
        donorBuildingRoles, used)
      colorMapRec = { nearest = nearest, categories = cats }
      region.gen2RemapCache[colorRemapKey] = colorMapRec
    end
    colorSlotDonor = colorMapRec.nearest or colorSlotDonor
    for tile, c in pairs(colorMapRec.categories or {}) do
      if colorCategories[tile] == nil then colorCategories[tile] = c end
    end
  end

  local profile, paletteKey
  if type(GoldColorAtlas.worldPaletteProfile) == "function" then
    local ok, p, key = pcall(GoldColorAtlas.worldPaletteProfile, world, colorRef)
    if ok and type(p) == "table" and key then profile, paletteKey = p, tostring(key) end
  end
  if not profile then profile = region.goldPaletteProfile end
  paletteKey = paletteKey or tostring(region.goldPaletteKey or "gen2")
  if not profile then return nil end

  local style = {
    donorRef = donorRef, donorTs = donorTs, donorPixels = donorRec.pixels,
    donorKey = donorKey, donorProfileId = donorProfileId,
    colorDonorRef = colorRef, colorDonorTs = colorTs,
    colorDonorPixels = colorRec and colorRec.pixels or nil,
    colorDonorKey = colorKey, colorSlotDonor = colorSlotDonor,
    materialProfiles = materialProfiles, materialSlots = materialSlots,
    profile = profile, paletteKey = paletteKey,
    remap = remapRec.remap, errors = remapRec.errors,
    categories = colorCategories, slotDonor = remapRec.nearest,
    matches = remapRec.matches,
    key = M.PROJECTION_REV .. "|" .. donorKey .. "|" .. colorKey .. "|" .. paletteKey,
  }
  return style
end

return M
