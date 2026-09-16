-- lib/ColosseumMon.lua
--
-- Overworld adapter for the Colosseum (GC6E01) 3D Pokemon model cache.
--
-- StadiumPack / Stadium2Pack only cover Pokemon Stadium's roster (national
-- dex 1-151) and Pokemon Stadium 2's roster (1-251). Neither game ever
-- shipped a Gen III model, so PlayerModel / StadiumFollower / StadiumWilds /
-- RoamerStadium3D have never been able to show a 3D Hoenn Pokemon, and a
-- Gen III game has NO Stadium-sourced model to fall back to at all.
--
-- Pokemon Colosseum ships battle models for the complete 386-species
-- Gen I-III roster (see lib/ColosseumDex.lua), and the extraction/runtime
-- pipeline that decodes them already exists: extract/PokemonExtractor.lua
-- builds the on-disk cache, lib/PokemonActors.lua ("CBE") turns a cached
-- species into a live, drawable Actor. This module is a thin, defensive
-- bridge so the existing overworld consumers can fall back to a
-- Colosseum-sourced model wherever a Stadium-sourced one is not available --
-- every Gen III species, and every species at all when the player has only
-- imported the Colosseum disc and no Stadium ROM.
--
-- CBE is wired into this mod through a *different* internal loader
-- (main.lua's colosseumPackage/loadColosseumModule, not V.require), so its
-- PokemonActors singleton is reached indirectly, published cross-module via
-- mod.exports.pokemonActorsOverworld (see main.lua's
-- initializeColosseumIntegration). Everything here is therefore defensive:
-- the export may not exist yet (Colosseum disc not imported, or CBE failed
-- to initialize), or a given species may still be mid-extraction. Every
-- entry point degrades to "no model this frame" rather than erroring, so a
-- caller can always fall through to its existing 2D sprite path.

local V = ...
local Dex = V.require("ColosseumDex")
local Voxel3D = V.require("Voxel3D")

local M = {}

-- cacheKey(dex,variant) -> Actor, memoized so repeated overworld draws
-- (several wild Pokemon on screen, one follower, one player model) don't
-- repeatedly walk PokemonActors' own acquire path every frame. A miss is
-- never cached -- PokemonActors already backs off failed extractions
-- internally (see pendingExtract in PokemonActors.lua), so retrying a miss
-- here is cheap and picks up a species the moment it finishes extracting.
local actors = {}

local function service()
  local mod = V.mod
  return mod and mod.exports and mod.exports.pokemonActorsOverworld
end

-- Mirrors the enabled()/roamerStadiumModels pattern used by RoamerStadium3D
-- and the rest of this overworld family. Off means "never substitute a
-- Colosseum model", not "hide Pokemon that have no model" -- callers keep
-- falling through to their normal sprite/Stadium path either way.
function M.enabled()
  local opts = V.mod and V.mod.options
  if not (opts and type(opts.get) == "function") then return true end
  local ok, value = pcall(opts.get, opts, "colosseumOverworldModels")
  if not ok or value == nil then return true end
  return not (value == false or value == 0 or value == "0" or value == "false" or value == "off")
end

local function cacheKey(dex, variant)
  return (variant == "shiny") and (tostring(dex) .. ":shiny") or dex
end

-- Trainer-figure scale the actor's world height is derived from. nil keeps
-- PokemonActors' own battle default, which puts a mid-size Pokemon at roughly
-- the 14 world pixels StadiumMon.REF_HEIGHT uses for the same job. Set a
-- number here to make the whole overworld cast larger or smaller; smaller
-- figureScale means a LARGER Pokemon (it is the divisor of the reference
-- trainer height).
M.figureScale = nil

-- Finish a freshly acquired actor the same way the information viewers do.
--
-- This matters more than it looks. PokemonActors hands back a BATTLE actor:
-- Actor.new starts it at state="spawn" with spawnScale=0, because in a real
-- send-out the battle presentation grows it in. Actor:matrix multiplies
-- worldScale by that spawn value, so an actor that nobody spawns is placed in
-- the world at scale ZERO. It draws without error, reports success, suppresses
-- the 2D sprite the pose would otherwise have drawn -- and is invisible. That
-- is exactly the "overworld Pokemon are still sprites / vanish" symptom.
--
-- UIMain's Pokedex/Summary/PC viewer avoids it with two lines immediately
-- after acquire ("Portable battle actors may start at spawnScale=0.
-- Information surfaces have no send-out lifecycle, so park them at full-size
-- idle."). The overworld has no send-out lifecycle either, so it needs the
-- same treatment.
local function finishOverworldActor(actor)
  if not actor then return nil end

  -- 1. Full size, out of the send-out grow-in state. spawn(1) also performs
  --    the spawn -> idle transition for us.
  pcall(actor.spawn, actor, 1)
  if (tonumber(actor.spawnScale) or 0) < 1 then actor.spawnScale = 1 end

  -- 2. Park on the authored looping idle bank. Redundant after a well-behaved
  --    spawn(1), but the portable-actor contract does not promise that, and
  --    this is the only thing standing between a live idle and a bind pose.
  pcall(actor.selectNativeSlot, actor, "idle")
  if type(actor.idle) == "function" then pcall(actor.idle, actor)
  elseif type(actor.play) == "function" then pcall(actor.play, actor, "idle") end

  -- 3. Let a provider that defers GPU work do it once, here, rather than on
  --    the first draw call inside the scene pass.
  if type(actor.build) == "function" then pcall(actor.build, actor) end

  return actor
end

-- One COLD acquisition per frame. acquire() falls through to a synchronous
-- source extraction for a species that has never been built, and walking into
-- a new area can easily expose four or five unbuilt species on the same frame.
-- Spreading them out costs one sprite frame each instead of stacking several
-- disc reads into one visible stall. Species that are already resident or
-- already on disk are unaffected and acquire immediately.
local coldAcquireToken = nil

-- true / false / nil when the provider is too old to answer.
local function diskCacheReady(svc, dex, variant)
  if type(svc.cacheReady) ~= "function" then return nil end
  local ok, value = pcall(svc.cacheReady, "overworld", dex, variant)
  if not ok then return nil end
  return value == true
end

local function residentAlready(svc, dex, variant)
  if type(svc.peek) ~= "function" then return false end
  local ok, value = pcall(svc.peek, "overworld", dex, variant)
  return ok and type(value) == "table" and value.resident == true
end

-- Returns a live Actor for dex/variant, or nil. Never forces synchronous
-- source extraction beyond what PokemonActors.acquire already does on its
-- own (disk-cache read if extracted, background-friendly retry/backoff if
-- not); this is the same cost a battle send-out already pays.
local function actorFor(dex, variant)
  dex = tonumber(dex)
  if not (dex and Dex.supported(dex)) then return nil end
  local svc = service()
  if not (svc and type(svc.acquire) == "function") then return nil end
  local key = cacheKey(dex, variant)
  local cached = actors[key]
  if cached then return cached end

  if not residentAlready(svc, dex, variant)
      and diskCacheReady(svc, dex, variant) == false then
    local token = Voxel3D.vp or true
    if coldAcquireToken == token then return nil end
    coldAcquireToken = token
  end

  local ok, actor = pcall(svc.acquire, "overworld", dex, variant, {
    context = {
      services = { informationSurface = false },
      arena = { figureScale = M.figureScale },
    },
  })
  if not ok or not actor then return nil end
  actors[key] = finishOverworldActor(actor)
  return actors[key]
end

-- Whether a Colosseum model is available (already resident, or reachable
-- from the imported disc) for this dex right now. Cheap: does not force
-- extraction merely to answer.
function M.available(dex, variant)
  if not M.enabled() then return false end
  dex = tonumber(dex)
  if not (dex and Dex.supported(dex)) then return false end
  if actors[cacheKey(dex, variant)] then return true end
  local svc = service()
  if not (svc and type(svc.available) == "function") then return false end
  local ok, value = pcall(svc.available, "overworld", dex)
  return ok and value == true
end

-- Advance this species' shared actor exactly once per rendered frame.
--
-- One Actor is shared by every entity of the same species, and more than one
-- consumer can ask for it on the same frame: OverworldColosseum calls update()
-- once per posed entity, OverworldStadium's Colosseum fallback calls it again
-- from its own prepare(), and StadiumFollower / RoamerStadium3D may be showing
-- the same species at the same time. Every one of those calls used to add a
-- full dt, so two Zigzagoon on screen idled at double speed and the authored
-- loop visibly raced. Voxel3D.vp is rebuilt once per scene, so its table
-- identity is a free, allocation-free per-frame stamp.
function M.update(dex, variant, dt)
  local actor = actorFor(dex, variant)
  if not actor then return false end
  local token = Voxel3D.vp
  if token ~= nil then
    if rawget(actor, "__owFrameToken") == token then return true end
    actor.__owFrameToken = token
  end
  pcall(actor.idle, actor)
  local ok = pcall(actor.update, actor, dt or 0)
  return ok
end

-- x, groundY, z: world position. towardX/towardZ: facing vector, same
-- convention as Actor:matrix / StadiumMon:matrix (see M.towardFor below for
-- the up/down/left/right helper the Stadium consumers already use).
function M.matrix(dex, variant, x, groundY, z, towardX, towardZ)
  local actor = actorFor(dex, variant)
  if not actor then return nil end
  local ok, m = pcall(actor.matrix, actor, x, groundY, z, towardX, towardZ)
  if not ok then return nil end
  return m
end

-- Draws the actor previously resolved by matrix()/update() for this
-- dex/variant. Must be called with a matrix from M.matrix() in the same
-- frame -- mirrors the StadiumMon/StadiumRig two-step (matrix, then draw)
-- pattern the existing overworld consumers already use.
function M.draw(dex, variant, matrix)
  if not matrix then return false end
  local actor = actors[cacheKey(dex, variant)]
  local svc = service()
  if not (actor and svc and type(svc.withRenderer) == "function") then return false end
  local vp = Voxel3D.vp
  if not vp then return false end
  local ok, accepted = pcall(svc.withRenderer, vp, function()
    -- Same build -> draw order the information viewer uses inside its own
    -- withRenderer block. build() is a no-op for the current provider but is
    -- part of the portable-actor contract, and a provider that streams its
    -- geometry needs the call.
    if type(actor.build) == "function" and actor:build() == false then
      error("colosseum overworld build declined")
    end
    local drew = actor:draw(matrix)
    if drew == false then error("colosseum overworld draw declined") end
    return true
  end, { eye = Voxel3D.eye })
  return ok and accepted ~= false
end

-- Facing string ("up"/"down"/"left"/"right") -> toward vector, matching the
-- convention already used by StadiumWilds/RoamerStadium3D.
local TOWARD_BY_FACING = {
  down = { 0, 1 }, up = { 0, -1 }, left = { -1, 0 }, right = { 1, 0 },
}
function M.towardFor(facing)
  local t = TOWARD_BY_FACING[facing] or TOWARD_BY_FACING.down
  return t[1], t[2]
end

function M.release(dex, variant)
  local key = cacheKey(dex, variant)
  local actor = actors[key]
  if actor then pcall(actor.release, actor) end
  actors[key] = nil
end

-- Release every pooled actor. Call on ROM/pack change, option toggle, or mod
-- teardown, same contract as StadiumFollower.clearCache/StadiumWilds.clearCache.
function M.clearCache()
  for _, actor in pairs(actors) do
    pcall(actor.release, actor)
  end
  actors = {}
end

return M