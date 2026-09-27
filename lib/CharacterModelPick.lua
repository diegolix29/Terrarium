-- CHARACTER MODEL: cycling through Colosseum character models for the player sprite.
--
-- This system allows changing the player sprite to use Colosseum character models
-- (Wes, Red, Leaf, Brendan, May, Dakim, Nascour, Miror B) instead of Pokemon models.
-- It follows the same pattern as PlayerModelPick but uses trainer characters.

local V = ...
local TrainerRoster = V.TrainerRoster
local PlayerModelInstall = V.require("PlayerModelInstall")
local ColosseumTrainer = V.require("ColosseumTrainer")
local GeneratedAssets = V.require("GeneratedAssets")

local CharacterModelPick = {}

CharacterModelPick.LABEL = "CHARACTER MODEL"
CharacterModelPick.ID = "DRAMATIC_SHAPE:characterModel"
CharacterModelPick.ANIMATION_ID = "DRAMATIC_SHAPE:characterAnimation"

-- Use the same character list as ColosseumTrainer for consistency
CharacterModelPick.CHARACTERS = {}
for _, id in ipairs(ColosseumTrainer.CHARACTERS) do
  table.insert(CharacterModelPick.CHARACTERS, {
    id = id,
    label = ColosseumTrainer.labelFor(id)
  })
end

-- Cycle through character models for the player
-- dir: 1 for forward (right arrow), -1 for backward (left arrow)
function CharacterModelPick.cycleCharacterModel(dir)
  dir = dir or 1  -- Default to forward if no direction specified
  
  -- Get current character model from settings
  local currentId = CharacterModelPick.getCurrentCharacterId()
  print("CharacterModelPick.cycleCharacterModel: Current ID:", currentId)
  
  -- Find current index in character list
  local currentIndex = 0
  for i, char in ipairs(CharacterModelPick.CHARACTERS) do
    if char.id == currentId then
      currentIndex = i
      break
    end
  end
  
  print("CharacterModelPick.cycleCharacterModel: Current index:", currentIndex)
  
  -- Move to next/previous character based on direction
  local nextIndex
  if dir > 0 then
    -- Forward (right arrow): count up
    nextIndex = currentIndex + 1
    if nextIndex > #CharacterModelPick.CHARACTERS then
      nextIndex = 0  -- Disable (back to normal player sprite)
    end
  else
    -- Backward (left arrow): count down
    if currentIndex == 0 then
      -- If currently disabled, go to the last character
      nextIndex = #CharacterModelPick.CHARACTERS
    else
      nextIndex = currentIndex - 1
      if nextIndex < 0 then
        nextIndex = 0  -- Disable
      end
    end
  end
  
  print("CharacterModelPick.cycleCharacterModel: Next index:", nextIndex)
  
  -- Set the new character model
  if nextIndex == 0 then
    -- Disable character model (back to normal player sprite)
    CharacterModelPick.setCharacterModel("off")
  else
    local character = CharacterModelPick.CHARACTERS[nextIndex]
    print("CharacterModelPick.cycleCharacterModel: Setting character to", character.id, character.label)
    CharacterModelPick.setCharacterModel(character.id)
  end
end

-- Get the current character model ID from settings
function CharacterModelPick.getCurrentCharacterId()
  local mod = V.mod
  local Config = V.require("config")
  
  if Config and type(Config.get) == "function" then
    return Config.get(mod, "character_model") or "off"
  elseif mod.options and type(mod.options.get) == "function" then
    return mod.options:get("character_model") or "off"
  end
  return "off"
end

-- Set the character model in settings
function CharacterModelPick.setCharacterModel(characterId)
  local mod = V.mod
  local Config = V.require("config")
  
  characterId = characterId or "off"
  
  if Config and type(Config.setOption) == "function" then
    Config.setOption(mod, "character_model", characterId, "character_model_set", {})
  elseif mod.options and type(mod.options.set) == "function" then
    mod.options:set("character_model", characterId)
  end
  
  -- Set appropriate default animation based on character
  local defaultAnim = "idle"
  if characterId == "wes" then
    defaultAnim = "victory"
  elseif characterId == "off" then
    defaultAnim = "idle"
  end
  
  if Config and type(Config.setOption) == "function" then
    Config.setOption(mod, "character_animation", defaultAnim, "character_animation_set", {})
  elseif mod.options and type(mod.options.set) == "function" then
    mod.options:set("character_animation", defaultAnim)
  end
  
  -- Load the model and write marker immediately
  local PlayerModel = V.require("PlayerModel")
  local PlayerModelInstall = V.require("PlayerModelInstall")
  
  if characterId ~= "off" then
    PlayerModel.clear()
    local ok = PlayerModel.loadColosseumCharacter(characterId)
    if ok then
      PlayerModelInstall.writeMarker("colosseum_character_" .. characterId)
    end
  else
    PlayerModel.clear()
    PlayerModelInstall.writeMarker("")
  end
end

-- Get the current character model configuration
function CharacterModelPick.getCurrentCharacterConfig()
  local currentId = CharacterModelPick.getCurrentCharacterId()
  if currentId == "off" then
    return nil
  end
  
  -- Get the character configuration from TrainerRoster
  if TrainerRoster and TrainerRoster.modelById then
    return TrainerRoster.modelById(currentId)
  end
  
  return nil
end

-- Create the settings row for character model selection
function CharacterModelPick.row()
  return {
    id = CharacterModelPick.ID,
    label = CharacterModelPick.LABEL,
    value = function()
      local currentId = CharacterModelPick.getCurrentCharacterId()
      if currentId == "off" then
        return "OFF"
      end
      
      -- Find the character label
      for _, char in ipairs(CharacterModelPick.CHARACTERS) do
        if char.id == currentId then
          return char.label
        end
      end
      
      return currentId:upper()
    end,
    step = function(game, dir)
      CharacterModelPick.cycleCharacterModel(dir)
      return true
    end,
  }
end

-- Get available animations for a character
function CharacterModelPick.getAvailableAnimations(characterId)
  if not characterId or characterId == "off" then
    return {}
  end
  
  local path = ("cache/trainers/%s/native_v1/index.lua"):format(characterId)
  local index, err = GeneratedAssets.readLua(path)
  
  if type(index) ~= "table" or type(index.roles) ~= "table" then
    return {}
  end
  
  local animations = {}
  for roleName, roleData in pairs(index.roles) do
    if type(roleData) == "table" and roleData.count and roleData.count > 0 then
      table.insert(animations, {
        name = roleName,
        label = roleName:upper()
      })
    end
  end
  
  -- Sort animations alphabetically
  table.sort(animations, function(a, b)
    return a.name < b.name
  end)
  
  return animations
end

-- Get the current animation selection from settings
function CharacterModelPick.getCurrentAnimation()
  local mod = V.mod
  local Config = V.require("config")
  
  -- Get the stored animation setting
  local storedAnim = nil
  if Config and type(Config.get) == "function" then
    storedAnim = Config.get(mod, "character_animation")
  elseif mod.options and type(mod.options.get) == "function" then
    storedAnim = mod.options:get("character_animation")
  end
  
  -- Return stored animation or default to idle
  return storedAnim or "idle"
end

-- Set the animation in settings
function CharacterModelPick.setAnimation(animationName)
  local mod = V.mod
  local Config = V.require("config")
  
  animationName = animationName or "idle"
  
  if Config and type(Config.setOption) == "function" then
    Config.setOption(mod, "character_animation", animationName, "character_animation_set", {})
  elseif mod.options and type(mod.options.set) == "function" then
    mod.options:set("character_animation", animationName)
  end
  
  -- Reload the animation in PlayerModel
  local PlayerModel = V.require("PlayerModel")
  pcall(PlayerModel.reloadCharacterAnimation)
end

-- Cycle through available animations
function CharacterModelPick.cycleAnimation(dir)
  dir = dir or 1
  
  local currentId = CharacterModelPick.getCurrentCharacterId()
  if currentId == "off" then
    return
  end
  
  local animations = CharacterModelPick.getAvailableAnimations(currentId)
  if #animations == 0 then
    return
  end
  
  local currentAnim = CharacterModelPick.getCurrentAnimation()
  local currentIndex = 0
  for i, anim in ipairs(animations) do
    if anim.name == currentAnim then
      currentIndex = i
      break
    end
  end
  
  local nextIndex = currentIndex + dir
  if nextIndex < 1 then
    nextIndex = #animations
  elseif nextIndex > #animations then
    nextIndex = 1
  end
  
  CharacterModelPick.setAnimation(animations[nextIndex].name)
end

-- Create the settings row for animation selection
function CharacterModelPick.animationRow()
  return {
    id = CharacterModelPick.ANIMATION_ID,
    label = "ANIMATION",
    value = function()
      local currentId = CharacterModelPick.getCurrentCharacterId()
      if currentId == "off" then
        return "OFF"
      end
      
      local currentAnim = CharacterModelPick.getCurrentAnimation()
      return currentAnim:upper()
    end,
    step = function(game, dir)
      local currentId = CharacterModelPick.getCurrentCharacterId()
      if currentId == "off" then
        return false
      end
      CharacterModelPick.cycleAnimation(dir)
      return true
    end,
    when = function()
      local currentId = CharacterModelPick.getCurrentCharacterId()
      return currentId ~= "off"
    end,
  }
end

return CharacterModelPick