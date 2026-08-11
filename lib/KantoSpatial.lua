-- Kanto actor cell/role index (v0.3.64).
-- Keeps collision/interaction lookups O(1), caches immutable NPC roles so
-- trainer/wanderer scans do not re-filter the full map list, and maintains a
-- tiny active-mover list for interpolation. Buckets (not singletons) preserve
-- correctness if two authored/runtime actors temporarily share a cell.

local M = {
  VERSION = "0.3.64",
  npcBuilds = 0,
  pokemonBuilds = 0,
  npcHits = 0,
  pokemonHits = 0,
  moves = 0,
  roleBuilds = 0,
  roleHits = 0,
  movingAdds = 0,
  movingRemoves = 0,
  generations = 0,
}

-- Gen-1 map cells are far narrower than 2048 columns. Packing x/y into one
-- number avoids allocating a "x:y" string for every collision/interaction
-- lookup and every wandering-NPC move.
local CELL_STRIDE = 2048
local function key(cx, cy)
  local x = math.floor(tonumber(cx) or 0)
  local y = math.floor(tonumber(cy) or 0)
  return y * CELL_STRIDE + x
end
M.key = key

local function cacheName(kind)
  return kind == "pokemon" and "pokemonSpatialCache" or "npcSpatialCache"
end

local function touch(region)
  if not region then return 0 end
  region.actorGeneration = (tonumber(region.actorGeneration) or 0) + 1
  M.generations = M.generations + 1
  return region.actorGeneration
end
M.touch = touch

local function build(list)
  local cells = {}
  for _, e in ipairs(list or {}) do
    local k = key(e.cellX, e.cellY)
    local bucket = cells[k]
    if not bucket then bucket = {}; cells[k] = bucket end
    bucket[#bucket + 1] = e
  end
  return cells
end

function M.ensure(region, mapId, kind, list)
  if not region then return {} end
  local name = cacheName(kind)
  region[name] = region[name] or {}
  local hit = region[name][mapId]
  if not hit or hit.list ~= list then
    hit = { list = list, cells = build(list) }
    region[name][mapId] = hit
    if kind == "pokemon" then M.pokemonBuilds = M.pokemonBuilds + 1
    else M.npcBuilds = M.npcBuilds + 1 end
  end
  return hit.cells
end

function M.at(region, mapId, kind, list, cx, cy, except)
  local cells = M.ensure(region, mapId, kind, list)
  local bucket = cells[key(cx, cy)]
  for _, e in ipairs(bucket or {}) do
    if e ~= except then
      if kind == "pokemon" then M.pokemonHits = M.pokemonHits + 1
      else M.npcHits = M.npcHits + 1 end
      return e
    end
  end
  return nil
end

-- Trainer/wander flags are immutable for a built Kanto entity list. Cache the
-- filtered lists once and keep the transient moving walkers alongside them.
-- Rebuilding from a replacement authoritative list also recovers any actor
-- already mid-step, so cache invalidation cannot freeze an interpolation.
local function buildRoles(list)
  local rec = {
    list = list,
    trainers = {},
    wanderers = {},
    moving = {},
    movingSet = {},
  }
  for _, e in ipairs(list or {}) do
    local def = e and e.def
    if def and def.trainerClass then rec.trainers[#rec.trainers + 1] = e end
    if e and e.wander then rec.wanderers[#rec.wanderers + 1] = e end
    if e and e.moving and e._moveT then
      rec.moving[#rec.moving + 1] = e
      rec.movingSet[e] = true
    end
  end
  return rec
end

function M.roles(region, mapId, list)
  if not region then return buildRoles(list) end
  region.npcRoleCache = region.npcRoleCache or {}
  local rec = region.npcRoleCache[mapId]
  if not rec or rec.list ~= list then
    rec = buildRoles(list)
    region.npcRoleCache[mapId] = rec
    M.roleBuilds = M.roleBuilds + 1
  else
    M.roleHits = M.roleHits + 1
  end
  return rec
end

-- Render-rate NPC AI can usually decide that no work is due without touching
-- the authoritative actor list at all. Expose the already-built role record
-- without creating a cache/table on a miss; callers that actually need a
-- rebuild still go through roles(region,mapId,list).
function M.peekRoles(region, mapId)
  local cache = region and region.npcRoleCache
  return cache and cache[mapId] or nil
end

function M.setMoving(region, mapId, list, entity, moving)
  if not (region and entity) then return end
  local rec = M.roles(region, mapId, list)
  local has = rec.movingSet[entity] == true
  if moving then
    if not has then
      rec.movingSet[entity] = true
      rec.moving[#rec.moving + 1] = entity
      M.movingAdds = M.movingAdds + 1
    end
    return
  end
  if not has then return end
  rec.movingSet[entity] = nil
  for i = #rec.moving, 1, -1 do
    if rec.moving[i] == entity then
      -- Swap-remove: ordering is irrelevant to interpolation and this avoids
      -- shifting the rest of the active mover list.
      rec.moving[i] = rec.moving[#rec.moving]
      rec.moving[#rec.moving] = nil
      break
    end
  end
  M.movingRemoves = M.movingRemoves + 1
end

function M.invalidate(region, mapId, npc, pokemon)
  if not region then return end
  local changed = false
  if npc then
    if region.npcSpatialCache then region.npcSpatialCache[mapId] = nil end
    if region.npcRoleCache then region.npcRoleCache[mapId] = nil end
    changed = true
  end
  if pokemon then
    if region.pokemonSpatialCache then region.pokemonSpatialCache[mapId] = nil end
    changed = true
  end
  if changed then touch(region) end
end

function M.move(region, mapId, kind, entity, fromX, fromY, toX, toY)
  if not (region and entity) then return end
  local oldKey, newKey = key(fromX, fromY), key(toX, toY)
  if oldKey == newKey then return end
  -- Actor-view culling is cached between cell crossings. Bump the generation
  -- even when the spatial bucket was not built yet so the render cache cannot
  -- reuse candidates computed for the old cell.
  touch(region)
  local name = cacheName(kind)
  local rec = region[name] and region[name][mapId]
  if not (rec and rec.cells) then return end
  local old = rec.cells[oldKey]
  if old then
    for i = #old, 1, -1 do
      if old[i] == entity then table.remove(old, i); break end
    end
    if #old == 0 then rec.cells[oldKey] = nil end
  end
  local dest = rec.cells[newKey]
  if not dest then dest = {}; rec.cells[newKey] = dest end
  dest[#dest + 1] = entity
  M.moves = M.moves + 1
end

function M.remove(region, mapId, kind, entity, cx, cy)
  if not (region and entity) then return end
  touch(region)
  local name = cacheName(kind)
  local rec = region[name] and region[name][mapId]
  local k = key(cx, cy)
  local bucket = rec and rec.cells and rec.cells[k]
  if not bucket then return end
  for i = #bucket, 1, -1 do
    if bucket[i] == entity then table.remove(bucket, i); break end
  end
  if #bucket == 0 then rec.cells[k] = nil end
end

function M.resetCounters()
  M.npcBuilds, M.pokemonBuilds = 0, 0
  M.npcHits, M.pokemonHits, M.moves = 0, 0, 0
  M.roleBuilds, M.roleHits = 0, 0
  M.movingAdds, M.movingRemoves = 0, 0
  M.generations = 0
end

return M
