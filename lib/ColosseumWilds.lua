-- Colosseum models for overworld Pokemon (followers, roamers, wildlife).
--
-- This module handles the rendering of Colosseum models for Pokemon in the
-- overworld, replacing their sprites with 3D Colosseum models when available.

local V = ...

local Mat4 = V.require("Mat4")
local PokemonActors = V.require("PokemonActors")
local ColosseumDex = V.require("ColosseumDex")
local OverworldColosseum = V.require("OverworldColosseum")
local Voxel3D = V.require("Voxel3D")
local ModSetting = V.require("ModSetting")

local ColosseumWilds = {}

-- Currently loaded PokemonActors instances per entity
local entityMons = setmetatable({}, { __mode = "k" })

-- Last seen frame for cleanup
local slots = setmetatable({}, { __mode = "k" })
local frameNo = 0

-- Configuration
local WILDS_SCALE = 0.8

-- Configuration
ColosseumWilds.KEY = "colosseumWilds"
ColosseumWilds.LABEL = "COLOSSEUM MODELS"

-- Persisted setting for Colosseum wilds toggle
ColosseumWilds.setting = ModSetting.new(ColosseumWilds.KEY, ColosseumWilds.LABEL,
                                     { true, false }, { "ON", "OFF" })
  :setGate(function(value)
    return PokemonActors ~= nil
  end)

-- Check if Colosseum wilds feature is enabled
function ColosseumWilds.enabled()
  if not ColosseumWilds.setting:get() then
    return false
  end
  return PokemonActors ~= nil
end

-- Enable or disable the feature
function ColosseumWilds.setEnabled(enabled)
  local currentGame = V.mod.world and V.mod.world.game
  ColosseumWilds.setting:setValue(enabled == true, currentGame)
  if not enabled then
    ColosseumWilds.clearCache()
  end
end

-- Clear the entity model cache
function ColosseumWilds.clearCache()
  for entity, mon in pairs(entityMons) do
    if mon and mon.finish then
      mon:finish()
    end
    entityMons[entity] = nil
  end
end

-- Check if an entity should use Colosseum models
function ColosseumWilds.isColosseumEntity(entity)
  if not entity then return false end
  
  -- Check if entity has a Colosseum tag
  local dex = OverworldColosseum.getTaggedDex(entity)
  if dex then
    return true, dex
  end
  
  return false, nil
end

-- Load a Colosseum model for an entity
function ColosseumWilds.loadModel(entity, dex)
  if not entity or not dex then return nil end
  
  -- Check if already loaded
  if entityMons[entity] then
    return entityMons[entity]
  end
  
  -- Check if dex is supported by Colosseum
  if not ColosseumDex.supported(dex) then
    return nil
  end
  
  -- Load the model
  local mon = PokemonActors.loadOverworldModel(dex, "normal")
  if mon then
    entityMons[entity] = mon
    slots[entity] = frameNo
  end
  
  return mon
end

-- Render a Colosseum model for an entity
function ColosseumWilds.render(entity, x, y)
  if not entity then return false end
  
  local dex = OverworldColosseum.getTaggedDex(entity)
  if not dex then return false end
  
  local mon = ColosseumWilds.loadModel(entity, dex)
  if not mon then return false end
  
  -- Update frame tracking
  slots[entity] = frameNo
  
  -- Render the model
  if mon.draw then
    local pose = { px = x, py = y, _colosseumModel = mon }
    mon:draw(pose)
    return true
  end
  
  return false
end

-- Cleanup unused models
function ColosseumWilds.cleanup()
  frameNo = frameNo + 1
  local cleanupThreshold = 60  -- Remove models not seen for 60 frames
  
  for entity, lastFrame in pairs(slots) do
    if frameNo - lastFrame > cleanupThreshold then
      local mon = entityMons[entity]
      if mon and mon.finish then
        mon:finish()
      end
      entityMons[entity] = nil
      slots[entity] = nil
    end
  end
end

-- Install the rendering hooks
function ColosseumWilds.install()
  -- This is a placeholder - actual integration would happen
  -- through the voxel rendering pipeline or entity rendering hooks
  return true
end

return ColosseumWilds
