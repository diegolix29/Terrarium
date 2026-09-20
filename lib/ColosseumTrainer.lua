-- lib/ColosseumTrainer.lua
--
-- Overworld adapter for the Colosseum (GC6E01) 3D trainer/character model cache.
--
-- Pokemon Colosseum ships battle models for several trainer characters (Wes, Red,
-- Leaf, Brendan, May, Dakim, Nascour, Miror B) and other NPCs. The extraction
-- pipeline (extract/TrainerExtractor.lua) builds on-disk caches for these models,
-- and the battle renderer (lib/PlayerTrainer.lua/TrainerMorph.lua) drives them
-- with dense vertex-morph animation.
--
-- This module is a thin, defensive bridge so the overworld player model system
-- (PlayerModel.loadColosseumCharacter) can fall back to a Colosseum-sourced
-- trainer model. The overworld uses only the static rest-pose geometry (mesh +
-- texture per material group) because the battle animation system (HSD joints,
-- dense morph targets, custom shaders) lives entirely in the battle pipeline
-- and is not something the overworld can reach or drive. A motionless standing
-- figure using each model's authored rest pose is still a real, correctly
-- shaped/textured/scaled overworld option.
--
-- TrainerRoster is the source catalog (modelById lookup), exported through
-- mod.exports.trainerRosterOverworld by main.lua's Colosseum integration.
-- Everything here is defensive: the export may not exist yet (Colosseum disc
-- not imported, or TrainerRoster failed to initialize), or a given character
-- may still be mid-extraction. Every entry point degrades to "no model this
-- frame" rather than erroring.

local V = ...

local M = {}

-- Character catalog: the IDs PlayerModel/CharacterModelPick cycle through.
-- These match the exact source members in extract/TrainerExtractor.lua's
-- TARGETS table. Do not add entries without confirming they exist in the
-- real GC6E01 file table and have a TrainerExtractor target.
M.CHARACTERS = {
  "red",           -- Kanto male protagonist (akami_m_a1.pkx)
  "leaf",          -- Kanto female protagonist (akami_f_a1.pkx)
  "wes",           -- Colosseum male protagonist (ken_a1.dat)
  "brendan",       -- Hoenn male protagonist (agb_m_a1.pkx)
  "may",           -- Hoenn female protagonist (agb_f_a1.pkx)
  "cooltrainer_m", -- Cooltrainer male (traner_m_a1.dat)
  "cooltrainer_f", -- Cooltrainer female (traner_f_a1.dat)
  "dakim",         -- Cipher boss (battleyama_a1.dat)
  "nascour",       -- Cipher admin (boss999_a1.dat)
  "miror_b",       -- Miror B. (boss555_a1.dat)
}



-- Service accessor: reach TrainerRoster through the mod.exports bridge.
local function service()
  local mod = V.mod
  return mod and mod.exports and mod.exports.trainerRosterOverworld
end

-- Mirrors the enabled() pattern used by ColosseumMon. Off means "never
-- substitute a Colosseum trainer model", not "hide characters that have no
-- model" -- callers keep falling through to their normal sprite path either way.
function M.enabled()
  local opts = V.mod and V.mod.options
  if not (opts and type(opts.get) == "function") then return true end
  local ok, value = pcall(opts.get, opts, "colosseumTrainerModels")
  if not ok or value == nil then return true end
  return not (value == false or value == 0 or value == "0" or value == "false" or value == "off")
end

-- Whether a Colosseum trainer model is available (already extracted, or
-- reachable from the imported disc) for this character ID right now.
-- Cheap: does not force extraction merely to answer.
function M.available(id)
  if not M.enabled() then return false end
  if not id or id == "" then return false end
  if type(id) ~= "string" then return false end

  -- Check against the known character catalog
  local found = false
  for _, knownId in ipairs(M.CHARACTERS) do
    if knownId == id then
      found = true
      break
    end
  end
  if not found then return false end

  -- Ask TrainerRoster if this model exists
  local svc = service()
  if not (svc and type(svc.modelById) == "function") then return false end
  local ok, cfg = pcall(svc.modelById, id)
  return ok and cfg ~= nil
end

-- Get the configuration for a character ID. Returns a table with:
--   cache: path to the extracted model_cache.lua file
--   bounds: {min={x,y,z}, max={x,y,z}} for scaling
--   (other TrainerRoster fields as needed)
-- Returns nil if the character is not available.
function M.configFor(id)
  if not id or id == "" then return nil end

  local svc = service()
  if not (svc and type(svc.modelById) == "function") then return nil end

  local ok, cfg = pcall(svc.modelById, id)
  if not ok or not cfg then 
    return nil 
  end
  
  return cfg
end

-- Get the display label for a character ID. Returns the uppercased ID or
-- a friendly name if available.
function M.labelFor(id)
  if not id or id == "" then return "UNKNOWN" end

  -- Friendly names for known characters
  local labels = {
    red = "RED",
    leaf = "GREEN / LEAF",
    wes = "WES / SETH",
    brendan = "BRENDAN",
    may = "MAY",
    cooltrainer_m = "COOLTRAINER M",
    cooltrainer_f = "COOLTRAINER F",
    dakim = "DAKIM",
    nascour = "NASCOUR",
    miror_b = "MIROR B.",
  }

  return labels[id] or id:upper()
end

-- Clear any cached trainer data. Call on ROM/pack change, option toggle, or
-- mod teardown. TrainerRoster itself is stateless catalog lookup, so this
-- is mainly for symmetry with ColosseumMon.clearCache -- the real teardown
-- happens at the TrainerRoster/PokemonActors level in main.lua.
function M.clearCache()
  -- No per-module cache to clear here -- TrainerRoster is stateless.
  -- Kept for API symmetry with ColosseumMon.
end

return M
