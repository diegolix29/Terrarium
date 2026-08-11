-- ROAMER STADIUM 3D: draw wild Roamer Pokemon as 3D Stadium models instead
-- of their 2D sprite card.
--
-- This is the Roamer-side counterpart to StadiumFollower.lua / FollowerPokemon.lua:
-- same Mat4/StadiumPack/Stadium2Pack/StadiumRig/StadiumMon plumbing, same
-- facing -> yaw math, same scale/lift handling. The one real difference is
-- that a follower is a singleton (one player, one follower on screen) while
-- roamers are not -- several wild Pokemon can be standing on screen at once,
-- so rigs are pooled per species (dex) rather than held as a single
-- "currentRig" global. A pooled rig is a plain re-skin/re-pose per draw
-- call, so reusing one rig across several Roamer instances of the same
-- species within a single frame is safe as long as every draw supplies its
-- own facing/animTime right before drawing (which is what we do below).
--
-- No Nintendo assets are bundled. Everything is read from the user's
-- already-imported Stadium / Stadium 2 packs, exactly like StadiumFollower.

local V = ...

local Mat4 = V.require("Mat4")
local StadiumPack = V.require("StadiumPack")
local Stadium2Pack = V.require("Stadium2Pack")
local StadiumRig = V.require("StadiumRig")
local StadiumMon = V.require("StadiumMon")

local M = {}

-- Smaller than the player model, roughly follower-sized. Tune per playtest.
M.SCALE = 0.9

-- dex -> { rig = StadiumRig, model = <pack model> }
local rigCache = {}

-- ------- Options -----------------------------------------------------

-- Mirrors the animationsEnabled()/stadiumBattleAnimations pattern used
-- elsewhere in this mod (see BattleStadiumAnimations.lua upstream). Off by
-- default is wrong here since this is the headline feature, so default true.
function M.enabled()
  local opts = V and V.mod and V.mod.options
  if not (opts and type(opts.get) == "function") then return true end
  local ok, value = pcall(opts.get, opts, "roamerStadiumModels")
  if not ok or value == nil then return true end
  return not (value == false or value == 0 or value == "0" or value == "false" or value == "off")
end

-- ------- Rig pool ------------------------------------------------------

-- Whether Stadium models can be loaded at all right now (ROM imported,
-- packs built). Checked lazily and cheaply -- StadiumInstall.available()
-- already does its own caching, so no need to cache the result here too.
local function installAvailable()
  local ok, StadiumInstall = pcall(V.require, "StadiumInstall")
  return ok and StadiumInstall and StadiumInstall.available and StadiumInstall.available()
end

local function game()
  return require("src.core.Game")
end

-- The engine's species are string keys ("PIKACHU"), not dex numbers --
-- Roamer.species is one of these strings, same as everywhere else in the
-- engine (see Roamer.new / WildRoamers). Stadium packs are keyed by
-- National Dex number, so every entry point below needs to go through this
-- first. Mirrors Stadium.lua's own dexOf() exactly, since that's the
-- existing, working lookup for the same string -> dex conversion.
local function dexOf(species)
  if not species then return nil end
  local data = game() and game().data
  local def = data and data.pokemon and data.pokemon[species]
  return def and def.dex or nil
end

local function loadModel(dex)
  if dex > 151 then
    return Stadium2Pack.load(dex, false)
  end
  return StadiumPack.load(dex, false)
end

-- Returns { rig, model } for a species string, building and caching by dex
-- on first use. Returns nil if the species doesn't resolve to a dex, the
-- dex is out of range, packs aren't installed, or the species has no
-- riggable model (staticPose).
local function speciesRig(species)
  local dex = dexOf(species)
  if not dex or dex < 1 or dex > 251 then return nil end

  local cached = rigCache[dex]
  if cached then return cached end

  if not installAvailable() then return nil end

  local ok, model = pcall(loadModel, dex)
  if not (ok and model) then return nil end
  if model.staticPose then return nil end

  local okRig, rig = pcall(StadiumRig.new, model)
  if not (okRig and rig) then return nil end

  local entry = { rig = rig, model = model }
  rigCache[dex] = entry
  return entry
end

-- Whether this species has (or can build) a usable 3D model right now.
-- Cheap enough to call from Roamer:draw every frame -- worst case it's a
-- data.pokemon lookup plus a table lookup once the rig is cached.
function M.available(species)
  return M.enabled() and speciesRig(species) ~= nil
end

-- ------- Drawing ---------------------------------------------------------

local YAW_BY_FACING = {
  right = math.pi / 2,
  up = math.pi,
  left = -math.pi / 2,
  -- down = 0 (no entry needed)
}

-- Draw a roamer as a 3D Stadium model.
--   species  -- engine species string ("PIKACHU"), same value Roamer.species
--              already holds -- resolved to a dex number internally
--   x, y     -- world pixel position (same space Roamer.px/py already use)
--   facing   -- "up" / "down" / "left" / "right"
--   animTime -- seconds, monotonically increasing per-roamer (NOT shared --
--              pass each roamer's own clock so several of the same species
--              don't animate in lockstep)
--   moving   -- true while the roamer is mid-step, for the walk vs idle pose
-- Returns true if it drew a model, false if it fell through (caller should
-- fall back to sprite:draw in that case).
function M.draw(species, x, y, facing, animTime, moving)
  local entry = speciesRig(species)
  if not entry then return false end
  local rig, model = entry.rig, entry.model

  -- Anim 1 is idle in every Stadium pack (see StadiumFollower.lua); walk-cycle
  -- selection can follow later once StadiumMon's walk clip picking is
  -- confirmed safe to call per-species here. Idle-with-time still reads as
  -- alive; it's the same fallback OverworldStadium itself uses when a species
  -- has no distinct walk clip.
  local animIndex = 1
  local ok = pcall(function()
    rig:pose(animIndex, (animTime or 0) * 30, true) -- 30 fps, matches StadiumFollower
    rig:anchor(0.75, 0)
  end)
  if not ok then return false end

  local m = Mat4.translate(x, 0, y)
  local yaw = YAW_BY_FACING[facing] or 0
  if yaw ~= 0 then m = Mat4.mul(m, Mat4.rotateY(yaw)) end

  local scale = StadiumMon.scaleFor(model) * M.SCALE
  m = Mat4.mul(m, Mat4.scale(scale, scale, scale))

  local lift = StadiumMon.liftFor(model)
  if lift ~= 0 then m = Mat4.mul(m, Mat4.translate(0, -lift, 0)) end

  local okDraw = pcall(function()
    rig:skin(yaw)
    rig:draw(m)
  end)
  return okDraw
end

-- ------- Cleanup ---------------------------------------------------------

-- Release every pooled rig. Call on ROM/pack change or mod teardown, same
-- as StadiumFollower.clearCache.
function M.clearCache()
  for dex, entry in pairs(rigCache) do
    if entry.rig then
      pcall(function() entry.rig:release() end)
    end
  end
  rigCache = {}
end

return M