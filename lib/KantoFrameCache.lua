-- Kanto steady-state render-frame scratch cache (v0.3.66).
--
-- Kanto free roam is rendered from a foreign Gen-1 map while Gold remains the
-- gameplay/save authority. TwinRegionWorld must therefore synthesize a voxel
-- render state every frame. The contents change continuously, but the TABLE
-- identities do not need to. Reuse the state, arrays and tiny descriptor
-- records so a 60/120-Hz Kanto session does not manufacture garbage merely by
-- standing still or walking through an already-built sector.
--
-- This is presentation scratch only. release() deliberately drops every map,
-- actor and mesh reference at RETURN TO JOHTO so the hard Kanto residency
-- boundary remains intact.

local M = {
  VERSION = "0.3.66",
  frames = 0,
  cacheReuses = 0,
  stateReuses = 0,
  arrayReuses = 0,
  neighborRecordReuses = 0,
  ghostRecordReuses = 0,
  releases = 0,
  oceanHits = 0,
  oceanMisses = 0,
  actorViewHits = 0,
  actorViewMisses = 0,
  poolTrims = 0,
  neighborViewHits = 0,
  neighborViewMisses = 0,
  neighborDynamicHits = 0,
  neighborDynamicMisses = 0,
}

local function wipeArray(t)
  for i = #t, 1, -1 do t[i] = nil end
  return t
end
M.wipeArray = wipeArray

function M.ensure(owner)
  if not owner then return nil end
  local c = owner.renderFrameCache
  if not c then
    c = {
      state = {},
      neighbors = {}, directNeighbors = {}, entities = {}, ghosts = {},
      neighborPool = {}, ghostPool = {},
      actorViewMap = nil, actorViewX = nil, actorViewY = nil,
      actorViewCells = nil, actorViewRadius = nil, actorViewGeneration = nil,
      actorViewNpcs = 0, actorViewMons = 0,
      oceanMap = nil, oceanRadius = nil, oceanEnabled = nil, ocean = nil,
      worldStub = {}, darkTint = { 0.10, 0.12, 0.16 },
      voxelScratch = {
        posed = {}, posePool = {}, atlasCache = {},
        waterDraws = {}, waterPool = {}, cullView = {},
        worldContext = {}, darkTint = { 1, 1, 1 },
        -- v0.3.59 VoxelScene prefetch/culling scratch. These tables carry only
        -- presentation references and are scrubbed on RETURN TO JOHTO below.
        live = {}, liveApplied = {}, neighborVisible = {},
        nbMesh = {}, nbWater = {}, detailReady = {},
      },
    }
    owner.renderFrameCache = c
  else
    M.cacheReuses = M.cacheReuses + 1
  end
  M.frames = M.frames + 1
  return c
end

function M.state(cache)
  if not cache then return {} end
  local t = cache.state
  if not t then t = {}; cache.state = t
  else
    for k in pairs(t) do t[k] = nil end
    M.stateReuses = M.stateReuses + 1
  end
  return t
end

function M.array(cache, name)
  if not cache then return {} end
  local t = cache[name]
  if not t then t = {}; cache[name] = t
  else M.arrayReuses = M.arrayReuses + 1 end
  return wipeArray(t)
end

function M.record(cache, poolName, index, kind)
  local pool = cache and cache[poolName]
  if not pool then return {} end
  local rec = pool[index]
  if not rec then rec = {}; pool[index] = rec
  else
    -- VoxelScene caches the immutable translation matrix on a neighbour record.
    -- Preserve that tiny derived object across frame scrubs; VoxelScene also
    -- validates the cached ox/oy before reuse when a pool slot changes maps.
    local model, mx, mz
    if kind ~= "ghost" then
      model, mx, mz = rec._stadiumModel, rec._stadiumModelX, rec._stadiumModelZ
    end
    for k in pairs(rec) do rec[k] = nil end
    if model then
      rec._stadiumModel, rec._stadiumModelX, rec._stadiumModelZ = model, mx, mz
    end
    if kind == "ghost" then M.ghostRecordReuses = M.ghostRecordReuses + 1
    else M.neighborRecordReuses = M.neighborRecordReuses + 1 end
  end
  return rec
end


-- The Kanto actor prefilter is cell-based. Local visibility already depends only
-- on player cell; neighbor candidates use a one-cell safety margin and the
-- final VoxelScene camera cull remains authoritative. Reuse the candidate
-- arrays until the player crosses a cell, quality radius changes, or any actor
-- changes cell/list membership.

-- The connected Kanto sector graph is immutable while the player remains on
-- the same root map at the same quality radius.  Keep the pooled neighbor
-- descriptors/direct-neighbor array intact across presentation frames; callers
-- only need to refresh the dynamic urgent/prefetch booleans.  `source` is the
-- cached sectorRecords table identity, so a rebuilt region cannot accidentally
-- reuse stale map references even when mapId/radius happen to match.
function M.neighborView(cache, mapId, radius, source)
  if not cache then return false, {}, {} end
  if cache.neighborViewMap == mapId and cache.neighborViewRadius == radius
      and cache.neighborViewSource == source then
    M.neighborViewHits = M.neighborViewHits + 1
    return true, cache.neighbors, cache.directNeighbors
  end
  cache.neighborViewMap, cache.neighborViewRadius = mapId, radius
  cache.neighborViewSource = source
  -- Dynamic seam urgency/prefetch is valid only for this exact connected-view
  -- identity. A root/radius/sector rebuild re-arms it even if the player has
  -- not changed cell or travel vector since the previous frame.
  cache.neighborDynamicX, cache.neighborDynamicY = nil, nil
  cache.neighborDynamicWorldX, cache.neighborDynamicWorldZ = nil, nil
  cache.neighborPrefetchCount = 0
  wipeArray(cache.neighbors or {})
  wipeArray(cache.directNeighbors or {})
  M.neighborViewMisses = M.neighborViewMisses + 1
  return false, cache.neighbors, cache.directNeighbors
end

-- `urgent` and directional second-ring `prefetch` depend only on the player's
-- completed cell plus the current world-travel vector. Camera interpolation,
-- animation clocks and actor motion do not affect them. Keep the last exact
-- inputs so an idle/steady-direction presentation frame can skip the entire
-- connected-neighbor dynamic loop. Values are scalar-only; no map refs are
-- added to the cache by this layer.
function M.neighborDynamics(cache, cx, cy, worldX, worldZ)
  if not cache then return false end
  worldX, worldZ = tonumber(worldX) or 0, tonumber(worldZ) or 0
  if cache.neighborDynamicX == cx and cache.neighborDynamicY == cy
      and cache.neighborDynamicWorldX == worldX
      and cache.neighborDynamicWorldZ == worldZ then
    M.neighborDynamicHits = M.neighborDynamicHits + 1
    return true
  end
  cache.neighborDynamicX, cache.neighborDynamicY = cx, cy
  cache.neighborDynamicWorldX, cache.neighborDynamicWorldZ = worldX, worldZ
  M.neighborDynamicMisses = M.neighborDynamicMisses + 1
  return false
end

function M.invalidateNeighborView(owner)
  local c = owner and owner.renderFrameCache
  if not c then return end
  c.neighborViewMap, c.neighborViewRadius, c.neighborViewSource = nil, nil, nil
  c.neighborDynamicX, c.neighborDynamicY = nil, nil
  c.neighborDynamicWorldX, c.neighborDynamicWorldZ = nil, nil
  c.neighborPrefetchCount = 0
  wipeArray(c.neighbors or {})
  wipeArray(c.directNeighbors or {})
end

function M.actorView(cache, mapId, cx, cy, actorCells, sectorRadius, generation)
  if not cache then return false, {}, {} end
  if cache.actorViewMap == mapId and cache.actorViewX == cx and cache.actorViewY == cy
      and cache.actorViewCells == actorCells and cache.actorViewRadius == sectorRadius
      and cache.actorViewGeneration == generation then
    M.actorViewHits = M.actorViewHits + 1
    return true, cache.entities, cache.ghosts, cache.actorViewNpcs or 0, cache.actorViewMons or 0
  end
  cache.actorViewMap, cache.actorViewX, cache.actorViewY = mapId, cx, cy
  cache.actorViewCells, cache.actorViewRadius = actorCells, sectorRadius
  cache.actorViewGeneration = generation
  cache.actorViewNpcs, cache.actorViewMons = 0, 0
  wipeArray(cache.entities or {})
  wipeArray(cache.ghosts or {})
  M.actorViewMisses = M.actorViewMisses + 1
  return false, cache.entities, cache.ghosts, 0, 0
end

function M.setActorViewCounts(cache, npcs, mons)
  if cache then
    cache.actorViewNpcs = tonumber(npcs) or 0
    cache.actorViewMons = tonumber(mons) or 0
  end
end

function M.invalidateActorView(owner)
  local c = owner and owner.renderFrameCache
  if not c then return end
  c.actorViewMap, c.actorViewX, c.actorViewY = nil, nil, nil
  c.actorViewCells, c.actorViewRadius, c.actorViewGeneration = nil, nil, nil
  c.actorViewNpcs, c.actorViewMons = 0, 0
  wipeArray(c.entities or {})
  wipeArray(c.ghosts or {})
end

-- Pool records are intentionally retained for allocation reuse, but slots above
-- the current high-water mark must not retain old route/map/actor references.
-- Scrub only the tail that became unused; future frames can reuse the same tiny
-- tables without keeping an exited Kanto sector resident.
function M.trimPool(cache, poolName, used)
  local pool = cache and cache[poolName]
  if not pool then return end
  used = math.max(0, math.floor(tonumber(used) or 0))
  local key = poolName .. "Used"
  local prev = tonumber(cache[key])
  if prev == nil then prev = #pool end
  if used < prev then
    for i = used + 1, prev do
      local rec = pool[i]
      if rec then
        for k in pairs(rec) do rec[k] = nil end
      end
    end
    M.poolTrims = M.poolTrims + 1
  end
  cache[key] = used
end

function M.localActorVisible(e, cx, cy, actorCells)
  if actorCells == math.huge then return true end
  local dx = math.abs((tonumber(e and e.cellX) or 0) - (tonumber(cx) or 0))
  local dy = math.abs((tonumber(e and e.cellY) or 0) - (tonumber(cy) or 0))
  return dx <= actorCells and dy <= actorCells
end

function M.neighborActorVisible(e, ox, oy, px, py, actorCells)
  if actorCells == math.huge then return true end
  local ex = (tonumber(e and e.px) or (tonumber(e and e.cellX) or 0) * 16)
    + (tonumber(ox) or 0)
  local ey = (tonumber(e and e.py) or (tonumber(e and e.cellY) or 0) * 16)
    + (tonumber(oy) or 0)
  local limit = math.max(0, tonumber(actorCells) or 0) * 16
  return math.abs(ex - (tonumber(px) or 0)) <= limit
    and math.abs(ey - (tonumber(py) or 0)) <= limit
end

function M.ocean(cache, mapId, radius, enabled)
  if cache and cache.oceanMap == mapId and cache.oceanRadius == radius
      and cache.oceanEnabled == enabled then
    M.oceanHits = M.oceanHits + 1
    return true, cache.ocean
  end
  M.oceanMisses = M.oceanMisses + 1
  return false, nil
end

function M.setOcean(cache, mapId, radius, enabled, value)
  if not cache then return value end
  cache.oceanMap, cache.oceanRadius = mapId, radius
  cache.oceanEnabled, cache.ocean = enabled, value
  return value
end

function M.invalidateOcean(owner)
  local c = owner and owner.renderFrameCache
  if c then
    c.oceanMap, c.oceanRadius, c.oceanEnabled, c.ocean = nil, nil, nil, nil
  end
end

function M.release(owner)
  local c = owner and owner.renderFrameCache
  if not c then return end
  wipeArray(c.neighbors or {})
  wipeArray(c.directNeighbors or {})
  wipeArray(c.entities or {})
  wipeArray(c.ghosts or {})
  for _, pool in ipairs({ c.neighborPool, c.ghostPool }) do
    if pool then
      for _, rec in ipairs(pool) do
        for k in pairs(rec) do rec[k] = nil end
      end
      wipeArray(pool)
    end
  end
  local vs = c.voxelScratch
  if vs then
    wipeArray(vs.posed or {})
    wipeArray(vs.waterDraws or {})
    for _, name in ipairs({ "neighborVisible", "nbMesh", "nbWater", "detailReady" }) do
      local t = vs[name]
      if t then for k in pairs(t) do t[k] = nil end end
      vs[name .. "Count"] = nil
    end
    for _, name in ipairs({ "live", "liveApplied" }) do
      local t = vs[name]
      if t then for k in pairs(t) do t[k] = nil end end
    end
    vs.liveAppliedOpenWorld, vs.liveAppliedRegion = nil, nil
    for _, pool in ipairs({ vs.posePool, vs.waterPool }) do
      if pool then
        for _, rec in ipairs(pool) do
          for k in pairs(rec) do rec[k] = nil end
        end
        wipeArray(pool)
      end
    end
    vs.posePoolUsed, vs.waterPoolUsed = nil, nil
    if vs.atlasCache then for k in pairs(vs.atlasCache) do vs.atlasCache[k] = nil end end
    if vs.worldContext then for k in pairs(vs.worldContext) do vs.worldContext[k] = nil end end
    if vs.cullView then for k in pairs(vs.cullView) do vs.cullView[k] = nil end end
  end
  if c.state then
    for k in pairs(c.state) do c.state[k] = nil end
  end
  c.oceanMap, c.oceanRadius, c.oceanEnabled, c.ocean = nil, nil, nil, nil
  c.neighborViewMap, c.neighborViewRadius, c.neighborViewSource = nil, nil, nil
  c.neighborDynamicX, c.neighborDynamicY = nil, nil
  c.neighborDynamicWorldX, c.neighborDynamicWorldZ = nil, nil
  c.neighborPrefetchCount = 0
  c.actorViewMap, c.actorViewX, c.actorViewY = nil, nil, nil
  c.actorViewCells, c.actorViewRadius, c.actorViewGeneration = nil, nil, nil
  c.actorViewNpcs, c.actorViewMons = 0, 0
  c.neighborPoolUsed, c.ghostPoolUsed = nil, nil
  if c.worldStub then c.worldStub.map = nil end
  owner.renderFrameCache = nil
  M.releases = M.releases + 1
end

function M.resetCounters()
  M.frames, M.cacheReuses, M.stateReuses, M.arrayReuses = 0, 0, 0, 0
  M.neighborRecordReuses, M.ghostRecordReuses = 0, 0
  M.releases, M.oceanHits, M.oceanMisses = 0, 0, 0
  M.actorViewHits, M.actorViewMisses, M.poolTrims = 0, 0, 0
  M.neighborViewHits, M.neighborViewMisses = 0, 0
  M.neighborDynamicHits, M.neighborDynamicMisses = 0, 0
end

return M
