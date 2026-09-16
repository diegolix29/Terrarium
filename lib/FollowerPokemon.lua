-- FOLLOWER POKEMON: Stadium models that follow the player character.
--
-- This module handles loading and rendering Stadium models that follow
-- the player around the map, similar to Pikachu in Pokémon Yellow.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")
local StadiumPack = V.require("StadiumPack")
local StadiumRig = V.require("StadiumRig")

local FollowerPokemon = {}

-- Cache for loaded follower rigs to avoid reloading
local rigCache = {}

-- Cache for loaded follower sprites to avoid reloading
local spriteCache = {}

-- Current follower data
local currentRig = nil
local currentStadiumModel = nil
local currentDex = nil
local currentFilename = nil
local currentSprite = nil
local usingSpriteFallback = false

-- Follower positioning
local followerOffset = { x = 0, y = 0, z = -2 }  -- Behind player by 2 tiles
local followerScale = 0.8  -- Slightly smaller than player

-- Load a sprite as fallback for follower using the sprite service
local function loadSpriteFallback(dex)
  if not dex then return false, "no dex number" end
  
  print("FollowerPokemon.loadSpriteFallback: Attempting to load sprite for dex", dex)
  
  -- Check sprite cache first
  if spriteCache[dex] then
    currentSprite = spriteCache[dex]
    currentDex = dex
    currentFilename = "follower_sprite_" .. dex
    usingSpriteFallback = true
    print("FollowerPokemon.loadSpriteFallback: Loaded sprite from cache")
    return true
  end
  
  -- Try to use the sprite service for proper fallback chain
  local okSpriteService, SpriteService = pcall(function() return V.require("follower.sprite_service") end)
  if okSpriteService and SpriteService then
    -- Try to get mod instance for sprite service
    local okMod, mod = pcall(function() return V.mod end)
    if okMod and mod then
      -- Create a sprite service instance
      local okNew, svc = pcall(function() return SpriteService.new(mod, {}) end)
      if okNew and svc then
        -- Try to get species name from dex number
        local species = nil
        local okGame, game = pcall(function() return V.require("src.core.Game") end)
        if okGame and game then
          local currentGame = game.get and game:get()
          if currentGame and currentGame.data and currentGame.data.pokemon then
            for speciesId, def in pairs(currentGame.data.pokemon) do
              if def and def.dex == dex then
                species = speciesId
                break
              end
            end
          end
        end
        
        -- Use the sprite service to resolve the follower sprite
        local okResolve, def = pcall(function() 
          return svc:resolveFollowerSprite({
            species = species or tostring(dex),
            shiny = false,
            surface = "land",
            role = "primary",
            game = okGame and game and game.get and game:get(),
          })
        end)
        
        if okResolve and def and def.image then
          -- Try to load the image
          local okImage, Assets = pcall(function() return V.require("src.render.Assets") end)
          if okImage and Assets then
            local image = Assets.image(def.image)
            if image then
              -- Cache the sprite
              spriteCache[dex] = image
              currentSprite = image
              currentDex = dex
              currentFilename = "follower_sprite_" .. dex
              usingSpriteFallback = true
              
              print("FollowerPokemon.loadSpriteFallback: Successfully loaded sprite via sprite service from", def.image)
              return true
            end
          end
        end
      end
    end
  end
  
  -- Fallback to original method if sprite service fails
  print("FollowerPokemon.loadSpriteFallback: Sprite service unavailable, trying direct load")
  
  -- Try to get Pokemon data to find the sprite path
  local ok, game = pcall(function() return V.require("src.core.Game") end)
  if not ok or not game then
    print("FollowerPokemon.loadSpriteFallback: Could not access Game module")
    return false, "could not access game data"
  end
  
  local currentGame = game.get and game:get()
  if not currentGame then
    print("FollowerPokemon.loadSpriteFallback: Could not get current game instance")
    return false, "could not get game instance"
  end
  
  local data = currentGame.data
  if not data then
    print("FollowerPokemon.loadSpriteFallback: No game data available")
    return false, "no game data"
  end
  
  -- Try to get species name from dex number
  local species = nil
  if data.pokemon then
    for speciesId, def in pairs(data.pokemon) do
      if def and def.dex == dex then
        species = speciesId
        break
      end
    end
  end
  
  if not species then
    print("FollowerPokemon.loadSpriteFallback: Could not find species for dex", dex)
    return false, "could not find species"
  end
  
  -- Try to get the Pokemon definition to find the sprite path directly
  local pokemonDef = data.pokemon and data.pokemon[species]
  if not pokemonDef then
    print("FollowerPokemon.loadSpriteFallback: Could not find Pokemon definition for", species)
    return false, "could not find pokemon definition"
  end
  
  -- Try to get the front sprite path from the Pokemon definition
  local spritePath = pokemonDef.spriteFront
  if not spritePath or spritePath == "" then
    print("FollowerPokemon.loadSpriteFallback: No spriteFront defined for", species)
    return false, "no sprite front defined"
  end
  
  -- Try to load the image
  local okImage, Assets = pcall(function() return V.require("src.render.Assets") end)
  if not okImage or not Assets then
    print("FollowerPokemon.loadSpriteFallback: Could not access Assets module")
    return false, "could not access assets"
  end
  
  local image = Assets.image(spritePath)
  if not image then
    print("FollowerPokemon.loadSpriteFallback: Could not load sprite image from", spritePath)
    return false, "could not load sprite image"
  end
  
  -- Cache the sprite
  spriteCache[dex] = image
  currentSprite = image
  currentDex = dex
  currentFilename = "follower_sprite_" .. dex
  usingSpriteFallback = true
  
  print("FollowerPokemon.loadSpriteFallback: Successfully loaded sprite fallback from", spritePath)
  return true
end

-- Load a Stadium model by dex number as a follower
function FollowerPokemon.load(dex)
  if not dex then return false, "no dex number" end
  
  print("FollowerPokemon.load: Attempting to load dex", dex)
  
  -- Check 3D model cache first
  if rigCache[dex] then
    currentRig = rigCache[dex]
    currentStadiumModel = currentRig and currentRig.model
    currentDex = dex
    currentFilename = "follower_" .. dex
    usingSpriteFallback = false
    print("FollowerPokemon.load: Loaded 3D model from cache")
    return true
  end
  
  -- Check sprite cache first
  if spriteCache[dex] then
    currentSprite = spriteCache[dex]
    currentDex = dex
    currentFilename = "follower_sprite_" .. dex
    usingSpriteFallback = true
    print("FollowerPokemon.load: Loaded sprite from cache")
    return true
  end
  
  -- Try to load the Stadium model first
  local model = StadiumPack.load(dex)
  if model and not model.staticPose then
    -- Create the rig
    local rig = StadiumRig.new(model)
    if rig then
      -- Cache the rig
      rigCache[dex] = rig
      currentRig = rig
      currentStadiumModel = model
      currentDex = dex
      currentFilename = "follower_" .. dex
      usingSpriteFallback = false
      
      -- Start idle animation
      rig:pose(1, 0, true)  -- Animation 1 is idle, time 0, loop true
      rig:skin(0)  -- No rotation initially
      
      print("FollowerPokemon.load: Successfully loaded Stadium model")
      return true
    end
  end
  
  -- If 3D model failed, try sprite fallback
  print("FollowerPokemon.load: 3D model unavailable, trying sprite fallback")
  local spriteOk, spriteErr = loadSpriteFallback(dex)
  if spriteOk then
    return true
  else
    print("FollowerPokemon.load: Sprite fallback also failed:", spriteErr)
    return false, "could not load 3D model or sprite: " .. tostring(spriteErr)
  end
end

-- Clear the current follower
function FollowerPokemon.clear()
  if currentRig then
    currentRig:release()
    currentRig = nil
  end
  currentStadiumModel = nil
  currentSprite = nil
  currentDex = nil
  currentFilename = nil
  usingSpriteFallback = false
end

-- Check if a follower is currently loaded
function FollowerPokemon.loaded()
  return (currentRig ~= nil and currentStadiumModel ~= nil) or (currentSprite ~= nil)
end

-- Get the dex number of the currently loaded follower
function FollowerPokemon.dex()
  return currentDex
end

-- Get the filename of the currently loaded follower
function FollowerPokemon.filename()
  return currentFilename
end

-- Check if the follower is using sprite fallback
function FollowerPokemon.isUsingSpriteFallback()
  return usingSpriteFallback
end

-- Draw the follower at the player's position
function FollowerPokemon.draw(px, py, y, facing, mirror)
  -- Handle sprite fallback
  if usingSpriteFallback and currentSprite then
    return FollowerPokemon.drawSprite(px, py, y, facing, mirror)
  end
  
  -- Handle 3D model
  if not (currentRig and currentStadiumModel) then
    return false
  end
  
  -- Update animation time
  local dt = 1 / 60  -- Assume 60 FPS for simplicity
  currentRig:pose(1, (currentRig.frameAt or 0) + dt, true)  -- Idle animation
  currentRig:anchor(0.75, dt)  -- Anchor to prevent drifting
  currentRig:textures(nil)  -- Update textures (eyes blinking)
  
  -- Calculate follower position based on player facing
  local offsetX, offsetZ = 0, -2  -- Default: behind player
  local followerYaw = 0
  
  -- Check if we're in free-roam mode (1st or 3rd person)
  local FirstPerson = V.require("FirstPerson")
  local b = FirstPerson.cardBlend()
  
  if b > 0 then
    -- In free-roam mode, use camera-relative rotation like the player model
    if facing == "down" then
      -- When moving backwards, face the camera
      followerYaw = FirstPerson.cardYaw(px + 8, py + 8) * b
    else
      -- When moving in other directions, face forward (away from camera)
      followerYaw = (FirstPerson.cardYaw(px + 8, py + 8) + math.pi) * b
    end
    -- In free-roam mode, calculate offset based on camera direction
    local camYaw = FirstPerson.cardYaw(px + 8, py + 8)
    offsetX = -math.sin(camYaw) * 2
    offsetZ = math.cos(camYaw) * 2
  else
    -- In other modes, rotate based on movement direction
    if facing == "right" then
      offsetX, offsetZ = -2, 0
      followerYaw = math.pi / 2
    elseif facing == "up" then
      offsetX, offsetZ = 0, 2
      followerYaw = math.pi
    elseif facing == "left" then
      offsetX, offsetZ = 2, 0
      followerYaw = -math.pi / 2
    end
  end
  
  -- Calculate the model matrix based on player position and offset
  local m = Mat4.translate(px + 8 + offsetX, y, py + 8 + offsetZ)
  
  -- Apply rotation based on facing direction
  if followerYaw ~= 0 then
    m = Mat4.mul(m, Mat4.rotateY(followerYaw))
  end
  
  -- Apply mirroring if needed
  if mirror then
    m = Mat4.mul(m, Mat4.scale(-1, 1, 1))
  end
  
  -- Apply scaling for follower model
  local model = currentStadiumModel
  local root = model.rootScale or 1
  local h = model.height or 52.25
  local k = root * 14 / math.max(h, 1e-6)  -- REF_HEIGHT = 14 from StadiumMon
  local scale = k * followerScale
  m = Mat4.mul(m, Mat4.scale(scale, scale, scale))
  
  -- Skin the mesh with the calculated yaw
  currentRig:skin(followerYaw)
  
  -- Draw using the rig's built-in draw method
  currentRig:draw(m)
  
  return true
end

-- Draw the sprite fallback at the player's position
function FollowerPokemon.drawSprite(px, py, y, facing, mirror)
  if not currentSprite then
    return false
  end
  
  -- Calculate follower position based on player facing
  local offsetX, offsetZ = 0, -2  -- Default: behind player
  
  -- Check if we're in free-roam mode (1st or 3rd person)
  local FirstPerson = V.require("FirstPerson")
  local b = FirstPerson.cardBlend()
  
  if b > 0 then
    -- In free-roam mode, calculate offset based on camera direction
    local camYaw = FirstPerson.cardYaw(px + 8, py + 8)
    offsetX = -math.sin(camYaw) * 2
    offsetZ = math.cos(camYaw) * 2
  else
    -- In other modes, rotate based on movement direction
    if facing == "right" then
      offsetX, offsetZ = -2, 0
    elseif facing == "up" then
      offsetX, offsetZ = 0, 2
    elseif facing == "left" then
      offsetX, offsetZ = 2, 0
    end
  end
  
  -- Calculate screen position for sprite rendering
  local worldX = px + 8 + offsetX
  local worldY = y
  local worldZ = py + 8 + offsetZ
  
  -- Try to use Voxel3D to render the sprite as a billboard
  local okVoxel, voxel3d = pcall(function() return Voxel3D end)
  if okVoxel and voxel3d then
    -- Create a simple billboard quad for the sprite
    local spriteWidth = 16  -- Standard sprite width
    local spriteHeight = 16  -- Standard sprite height
    
    -- Apply scaling for sprite
    local scale = followerScale
    
    -- Draw the sprite as a billboard
    local lg = love and love.graphics
    if lg then
      lg.push()
      lg.translate(worldX, worldY, worldZ)
      lg.scale(scale, scale, scale)
      
      -- Draw sprite centered
      local sw, sh = currentSprite:getDimensions()
      lg.draw(currentSprite, -sw/2, -sh/2)
      
      lg.pop()
    end
  else
    -- Fallback: Try to draw using basic love.graphics if available
    local lg = love and love.graphics
    if lg then
      lg.push()
      lg.translate(worldX, worldY)
      lg.scale(followerScale, followerScale)
      
      -- Draw sprite centered
      local sw, sh = currentSprite:getDimensions()
      lg.draw(currentSprite, -sw/2, -sh/2)
      
      lg.pop()
    end
  end
  
  return true
end

-- Clear the follower cache to free memory
function FollowerPokemon.clearCache()
  for dex, rig in pairs(rigCache) do
    if rig then
      pcall(function() rig:release() end)
    end
  end
  rigCache = {}
  
  -- Clear sprite cache
  spriteCache = {}
  
  currentRig = nil
  currentStadiumModel = nil
  currentSprite = nil
  currentDex = nil
  currentFilename = nil
  usingSpriteFallback = false
end

return FollowerPokemon
