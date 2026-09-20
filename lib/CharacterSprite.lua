-- CHARACTER SPRITE: applying Colosseum character 3D models to the player.
--
-- This system follows the OverworldStadium pattern but for trainer character models.
-- Since OverworldColosseum only handles Pokemon models, we need a separate system
-- that uses the Trainer/TrainerRoster system for character models.
--
-- Integration contract (similar to OverworldStadium):
--   * Tags the player entity with character ID
--   * prepare() processes character models using TrainerRoster
--   * draw() renders 3D character models or falls back to sprite
--   * Uses VoxelScene integration for rendering pipeline

local V = ...
local CharacterModelPick = V.require("CharacterModelPick")
local TrainerRoster = V.TrainerRoster
local Trainer = V.Trainer
local ColosseumMon = V.ColosseumMon
local Mat4 = V.Mat4
local DebugLog = V.require("debug_log")

local CharacterSprite = {}

-- State for character model rendering
local frameNo = 0
local reported = {}
local characterSlots = setmetatable({}, { __mode = "k" })

local function logOnce(key, fmt, ...)
  if reported[key] then return end
  reported[key] = true
  local log = V.mod and V.mod.log
  if log and log.warn then
    pcall(log.warn, log, fmt, ...)
  end
end

-- Get the current character model ID from settings
function CharacterSprite.getCurrentCharacterId()
  local mod = V.mod
  local Config = V.require("config")
  
  if Config and type(Config.get) == "function" then
    return Config.get(mod, "character_model") or "off"
  elseif mod.options and type(mod.options.get) == "function" then
    return mod.options:get("character_model") or "off"
  end
  return "off"
end

-- Check if this is a player entity with character model enabled
local function isCharacterPlayerPose(p)
  if not p or not p.entity then return false end
  if not p.entity._characterTagged then return false end
  return true
end

-- Prepare character model for rendering (called by VoxelScene)
function CharacterSprite.prepare(posed)
  frameNo = frameNo + 1
  
  for i, p in ipairs(posed or {}) do
    -- Reset character data for this frame
    p.characterId = nil
    p.characterConfig = nil
    p.characterMatrix = nil
    
    -- Check if this is a player entity with character tag
    if isCharacterPlayerPose(p) then
      local characterId = p.entity._characterId
      
      if characterId and characterId ~= "off" then
        -- Get character configuration from TrainerRoster
        local charConfig = TrainerRoster.modelById(characterId)
        if charConfig then
          -- Store character data on the pose
          p.characterId = characterId
          p.characterConfig = charConfig
          
          -- Create or reuse character slot
          local slot = characterSlots[p.entity]
          if not slot then
            slot = { lastSeen = frameNo }
            characterSlots[p.entity] = slot
          end
          slot.lastSeen = frameNo
          slot.characterId = characterId
          slot.config = charConfig
          
          -- Calculate character matrix (similar to OverworldStadium)
          local px = p.px or 0
          local py = p.py or 0
          local facing = p.facing or "down"
          
          -- Create transformation matrix
          local matrix = Mat4.translate(px, 0, py)
          
          -- Apply rotation based on facing
          local yaw = 0
          if facing == "right" then
            yaw = math.pi / 2
          elseif facing == "up" then
            yaw = math.pi
          elseif facing == "left" then
            yaw = -math.pi / 2
          end
          
          if yaw ~= 0 then
            matrix = Mat4.mul(matrix, Mat4.rotateY(yaw))
          end
          
          -- Apply character scale from config
          local scale = charConfig.playerScaleMul or 1.0
          matrix = Mat4.mul(matrix, Mat4.scale(scale, scale, scale))
          
          p.characterMatrix = matrix
        else
          logOnce("character-config:" .. tostring(characterId),
            "Character model %s config not found; using sprite", tostring(characterId))
        end
      end
    end
  end
  
  -- Clean up stale slots
  local stale = 120  -- Same as OverworldStadium
  for entity, slot in pairs(characterSlots) do
    if frameNo - (slot.lastSeen or 0) > stale then
      characterSlots[entity] = nil
    end
  end
  
  return true
end

-- Draw character model (called by VoxelScene)
function CharacterSprite.draw(p)
  if not p or not p.characterId or not p.characterConfig then return false end

  local characterId = p.characterId
  local charConfig = p.characterConfig
  local matrix = p.characterMatrix

  if not matrix then return false end

  -- For now, try to use the Trainer system to render the character
  -- This is complex, so we'll log it and return false to fall back to sprite
  logOnce("character-draw:" .. tostring(characterId),
    "Attempting to draw character 3D model for %s (using Trainer system)", tostring(characterId))

  -- TODO: Integrate with Trainer rendering system
  -- The Trainer system is quite complex and would need:
  -- 1. Loading the trainer model from cache
  -- 2. Setting up the rig/skeleton
  -- 3. Rendering with proper shaders
  -- For now, return false to fall back to sprite
  return false
end

-- Safe entry points for VoxelScene integration
function CharacterSprite.safePrepare(posed)
  local ok, result = pcall(CharacterSprite.prepare, posed)
  if not ok then
    logOnce("prepare-frame", "Character overworld prepare error: %s", tostring(result))
    return false
  end
  return result ~= false
end

function CharacterSprite.safeDraw(p)
  local ok, result = pcall(CharacterSprite.draw, p)
  return ok and result == true
end

-- Tag the player entity for character model rendering
function CharacterSprite.tagPlayer(game, ow)
  if not game or not ow then return end
  
  local player = ow.player
  if not player then return end
  
  local characterId = CharacterSprite.getCurrentCharacterId()
  if characterId == "off" then
    -- Remove character tag if disabled
    player._characterTagged = false
    player._characterId = nil
    return
  end
  
  -- Check if character is available
  if TrainerRoster and TrainerRoster.available and TrainerRoster.available(characterId) then
    player._characterTagged = true
    player._characterId = characterId
  else
    player._characterTagged = false
    player._characterId = nil
  end
end

-- Hook into game updates to tag the player
function CharacterSprite.installHooks(mod)
  if not mod or not mod.hooks then return false end
  
  -- Hook into overworld update to tag player for character rendering
  mod.hooks:wrap("overworld.update", function(next, game, ow, dt)
    -- Call original function
    local result = next(game, ow, dt)
    
    -- Tag player for character rendering
    CharacterSprite.tagPlayer(game, ow)
    
    return result
  end, 100)
  
  -- Hook into VoxelScene.prepare to add character model preparation
  local VoxelScene = V.require("VoxelScene")
  if VoxelScene and VoxelScene.prepare then
    local originalPrepare = VoxelScene.prepare
    VoxelScene.prepare = function(posed)
      -- Call original prepare (includes OverworldStadium.prepare)
      local result = originalPrepare(posed)

      -- Add character model preparation
      CharacterSprite.safePrepare(posed)

      return result
    end
  end

  -- Hook into VoxelScene.draw to handle character rendering
  if VoxelScene and VoxelScene.draw then
    local originalDraw = VoxelScene.draw
    VoxelScene.draw = function(p)
      -- Check if this pose should use character 3D
      if p and p.characterId then
        -- Try to draw using character 3D model
        if CharacterSprite.safeDraw(p) then
          return true  -- Character 3D drawn successfully
        end
      end

      -- Fall back to original draw
      return originalDraw(p)
    end
  end

  return true
end

-- Check if character sprite is currently active
function CharacterSprite.isActive()
  local characterId = CharacterSprite.getCurrentCharacterId()
  return characterId ~= nil and characterId ~= "off"
end

-- Clear character model state
function CharacterSprite.clearCache()
  characterSlots = {}
  frameNo = 0
  DebugLog.info(V.mod, "CharacterSprite: Cache cleared")
end

return CharacterSprite