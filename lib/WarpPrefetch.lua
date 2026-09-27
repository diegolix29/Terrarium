-- Warm a semantic destination while the engine's existing warp fade covers
-- the overworld. This module never changes the warp, map, transition or
-- renderer state: it only puts the already-known destination into
-- ChunkMesher's generation-checked in-memory queue, exactly as VoxelScene
-- would once the player actually arrives. Any failure therefore falls back
-- to the ordinary post-warp build, which was going to run anyway.
--
-- Adapted from the Voxel Ascendant fork's WarpPrefetch. Two things did not
-- come with it: the HorizonWall pre-warm (this fork's horizon renderer,
-- HorizonArt, has no equivalent staged-mesh API to drive the same way) and
-- the separate PRELOAD option (this fork has no such setting) -- so the only
-- gate here is Voxel.active(), same as every other per-frame voxel hook in
-- this mod (see main.lua's update).

local V = ...

local ChunkMesher = V.require("ChunkMesher")
local Voxel = V.require("VoxelState")

local WarpPrefetch = {}

local MARKER = "__terrariumWarpPrefetchV1"
local OWNER = "TERRARIUM"

local function enabled()
  local ok, value = pcall(Voxel.active)
  return ok and value == true
end

local function arm(state, game, mapId)
  -- Loading a Map object may allocate renderer state. Keep that work out of
  -- startWarpTo itself: the wrapper records only two references and returns
  -- immediately to the engine's unmodified transition implementation.
  state.pending = { game = game, mapId = mapId }
  state.warmingMap = nil
  state.warmingBodyOnly = nil
end

function WarpPrefetch.install(game)
  local ow = game and game.overworld
  if type(ow) ~= "table" or type(ow.startWarpTo) ~= "function" then
    return false
  end

  local existing = rawget(ow, MARKER)
  if existing ~= nil then
    -- Hot reload reuses the live OverworldState. Adopt the existing wrapper
    -- instead of stacking another one; an inconsistent/foreign marker is
    -- deliberately left alone.
    if type(existing) ~= "table" or existing.owner ~= OWNER
       or ow.startWarpTo ~= existing.wrapper then
      return false
    end
    existing.arm = arm
    existing.game = game
    return true
  end

  local state = {
    owner = OWNER,
    game = game,
    original = ow.startWarpTo,
    arm = arm,
  }
  state.wrapper = function(self, mapId, ...)
    state.arm(state, state.game, mapId)
    -- Tail return preserves every original return value and every argument,
    -- including optional Fly/onDone/options records.
    return state.original(self, mapId, ...)
  end
  rawset(ow, MARKER, state)
  ow.startWarpTo = state.wrapper
  return true
end

-- Call once per frame with the same `covered` value ChunkMesher.pump gets
-- (see main.lua: stack:top() ~= ow, or ow.transitioning -- either one means
-- nothing of the world is on screen to hitch right now). Returns true while
-- a warm-up request is in flight, purely for callers that want to know.
function WarpPrefetch.update(game, covered)
  local ow = game and game.overworld
  if type(ow) ~= "table" then return false end
  local state = rawget(ow, MARKER)
  if type(state) ~= "table" or state.owner ~= OWNER
     or ow.startWarpTo ~= state.wrapper then
    return false
  end

  if not covered then
    state.warmingMap = nil
    state.warmingBodyOnly = nil
  elseif state.warmingMap and type(ChunkMesher.ready) == "function" then
    local readyOK, ready = pcall(ChunkMesher.ready, state.warmingMap,
      state.warmingBodyOnly == true)
    if readyOK and ready then
      state.warmingMap = nil
      state.warmingBodyOnly = nil
    end
  end

  local pending = state.pending
  if not pending or not covered then return state.warmingMap ~= nil end
  state.pending = nil
  if not enabled() or type(pending.mapId) ~= "string" then return false end

  local ok, map = pcall(function()
    local loader = require("src.world.MapLoader")
    return loader.load(pending.game and pending.game.data, pending.mapId)
  end)
  if not ok or not map then return false end

  -- Ordinary interiors need no neighbour seam masks at all when they have no
  -- connections of their own -- most of them (Pokemon Centers, marts, gyms,
  -- Oak's Lab) are exactly this: closed maps that VoxelScene will itself
  -- request as a single unmasked "full" build. Building that here, during
  -- the door's fade, means the cold structure analysis is not the thing
  -- eating the first visible frames after the fade lifts.
  --
  -- A destination WITH connections (an outdoor route continuing into its
  -- neighbours) still waits for VoxelScene, which is the only thing that
  -- knows the actual neighbour masks its full-ring cache key needs; warming
  -- an unmasked guess here would just be discarded on arrival. Ascendant's
  -- HorizonWall.preferBody also lets some connected outdoor maps warm as
  -- body-only; this fork's horizon renderer (HorizonArt) has no equivalent
  -- classifier, so that case is left to VoxelScene rather than guessed at.
  local connections = map.def and map.def.connections
  if type(connections) == "table" and next(connections) ~= nil then
    return false
  end
  local bodyOnly = false

  local requestOK = pcall(ChunkMesher.request, map, bodyOnly, nil, true)
  if requestOK then
    state.warmingMap = map
    state.warmingBodyOnly = bodyOnly
  end
  return requestOK
end

WarpPrefetch.MARKER = MARKER

return WarpPrefetch
