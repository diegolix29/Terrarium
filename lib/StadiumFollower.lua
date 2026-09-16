-- STADIUM FOLLOWER: Replace Yellow's Pikachu follower with any Stadium Pokémon.
--
-- This module extends the gen1recomp Pikachu follower system to use 3D Stadium
-- models instead of 2D sprites. It hooks into the overworld rendering to draw
-- Stadium models for the follower NPC.
--
-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local StadiumPack = V.require("StadiumPack")
local Stadium2Pack = V.require("Stadium2Pack")
local StadiumRig = V.require("StadiumRig")
local StadiumMon = V.require("StadiumMon")
local Voxel3D = V.require("Voxel3D")
local ColosseumMon = V.require("ColosseumMon")
local ColosseumDex = V.require("ColosseumDex")

local StadiumFollower = {}

-- Cache for loaded follower rigs
local rigCache = {}

-- Cache for loaded follower sprites
local spriteCache = {}

-- Current follower species (nil = disabled, 1-151 = dex number)
local currentSpecies = nil

-- ------- Persistence

-- Where the follower marker file is kept
StadiumFollower.MARKER = "stadium_follower.info"

-- Format version for the marker file
StadiumFollower.FORMAT = "SF1"

local function fs()
  return love and love.filesystem
end

local function isFile(path)
  local f = fs()
  if not (f and f.getInfo) then return false end
  local ok, info = pcall(f.getInfo, path, "file")
  return (ok and info) and true or false
end

-- Read the marker file to get the saved follower species
local function readMarker()
  local f = fs()
  if not (f and isFile(StadiumFollower.MARKER)) then return nil end
  local ok, text = pcall(f.read, StadiumFollower.MARKER)
  if not (ok and type(text) == "string") then return nil end
  local format, dexStr = text:match("^(%S+)%s+(.+)$")
  if not format or format ~= StadiumFollower.FORMAT then return nil end
  local dex = tonumber(dexStr)
  -- Was capped at 151 (StadiumPack's own range) before the Colosseum fallback
  -- existed. Now covers the complete Gen I-III roster (see setSpecies below).
  return dex and (dex > 0 and dex <= ColosseumDex.speciesCount) and dex or nil
end

-- Write the marker file with the current follower species
local function writeMarker(dex)
  local f = fs()
  if not (f and f.write) then return false end
  local content = StadiumFollower.FORMAT .. " " .. (dex or 0)
  local ok, err = pcall(f.write, StadiumFollower.MARKER, content)
  return ok, err
end

-- Current rig and model
local currentRig = nil
local currentModel = nil
local currentSprite = nil
local usingSpriteFallback = false
-- Colosseum-backed follower state (used when dex is out of StadiumPack's
-- 1-151 range, or no Stadium ROM is installed at all).
local usingColosseum = false
local colosseumVariant = "normal"

-- Animation state
local animTime = 0
local currentAnim = 1  -- 1 = idle

-- ------- Configuration

-- Scale for the follower model (smaller than player)
local FOLLOWER_SCALE = 0.9  -- 0.3 * 3 = 0.9 (3x larger)

-- Load a sprite as fallback for follower
local function loadSpriteFallback(dex)
  if not dex then return false, "no dex number" end
  
  print("StadiumFollower.loadSpriteFallback: Attempting to load sprite for dex", dex)
  
  -- Check sprite cache first
  if spriteCache[dex] then
    currentSprite = spriteCache[dex]
    currentSpecies = dex
    usingSpriteFallback = true
    print("StadiumFollower.loadSpriteFallback: Loaded sprite from cache")
    return true
  end
  
  -- Try to get Pokemon data to find the sprite path
  local ok, game = pcall(function() return V.require("src.core.Game") end)
  if not ok or not game then
    print("StadiumFollower.loadSpriteFallback: Could not access Game module")
    return false, "could not access game data"
  end
  
  local currentGame = game.get and game:get()
  if not currentGame then
    print("StadiumFollower.loadSpriteFallback: Could not get current game instance")
    return false, "could not get game instance"
  end
  
  local data = currentGame.data
  if not data then
    print("StadiumFollower.loadSpriteFallback: No game data available")
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
    print("StadiumFollower.loadSpriteFallback: Could not find species for dex", dex)
    return false, "could not find species"
  end
  
  -- Try to get the Pokemon definition to find the sprite path directly
  local pokemonDef = data.pokemon and data.pokemon[species]
  if not pokemonDef then
    print("StadiumFollower.loadSpriteFallback: Could not find Pokemon definition for", species)
    return false, "could not find pokemon definition"
  end
  
  -- Try to get the front sprite path from the Pokemon definition
  local spritePath = pokemonDef.spriteFront
  if not spritePath or spritePath == "" then
    print("StadiumFollower.loadSpriteFallback: No spriteFront defined for", species)
    return false, "no sprite front defined"
  end
  
  -- Try to load the image
  local okImage, Assets = pcall(function() return V.require("src.render.Assets") end)
  if not okImage or not Assets then
    print("StadiumFollower.loadSpriteFallback: Could not access Assets module")
    return false, "could not access assets"
  end
  
  local image = Assets.image(spritePath)
  if not image then
    print("StadiumFollower.loadSpriteFallback: Could not load sprite image from", spritePath)
    return false, "could not load sprite image"
  end
  
  -- Cache the sprite
  spriteCache[dex] = image
  currentSprite = image
  currentSpecies = dex
  usingSpriteFallback = true
  
  print("StadiumFollower.loadSpriteFallback: Successfully loaded sprite fallback from", spritePath)
  return true
end

-- ------- Species Management

-- Set the follower species by dex number (1-151)
function StadiumFollower.setSpecies(dex)
  if dex == currentSpecies then return true end
  
  -- Clear current rig and sprite
  if currentRig then
    currentRig:release()
    currentRig = nil
  end
  currentModel = nil
  currentSprite = nil
  currentSpecies = nil
  usingSpriteFallback = false
  usingColosseum = false
  
  if not dex or dex < 1 or dex > ColosseumDex.speciesCount then
    -- Save the disabled state
    writeMarker(nil)
    return true  -- Disabled
  end
  
  -- Check 3D model cache first
  if dex <= 151 and rigCache[dex] then
    currentRig = rigCache[dex]
    currentModel = currentRig.model
    currentSpecies = dex
    usingSpriteFallback = false
    -- Save the enabled state
    writeMarker(dex)
    return true
  end
  
  -- Check sprite cache first
  if spriteCache[dex] then
    currentSprite = spriteCache[dex]
    currentSpecies = dex
    usingSpriteFallback = true
    -- Save the enabled state
    writeMarker(dex)
    return true
  end
  
  -- Try Colosseum models first (covers complete 1-386 roster)
  if ColosseumMon.available(dex, "normal") then
    currentSpecies = dex
    usingSpriteFallback = false
    usingColosseum = true
    colosseumVariant = "normal"
    writeMarker(dex)
    print("StadiumFollower: Loaded Colosseum follower dex", dex)
    return true
  end
  
  -- Fall back to Stadium models if Colosseum isn't available
  local model = dex <= 151 and StadiumPack.load(dex, false) or nil
  
  if model and not model.staticPose then
    -- Create the rig
    local rig = StadiumRig.new(model)
    if rig then
      -- Cache and set current
      rigCache[dex] = rig
      currentRig = rig
      currentModel = model
      currentSpecies = dex
      usingSpriteFallback = false
      
      -- Save the enabled state
      writeMarker(dex)
      
      -- Start idle animation
      rig:pose(1, 0, true)
      rig:skin(0)
      
      print("StadiumFollower: Loaded Stadium follower dex", dex)
      return true
    end
  end
  
  -- If every 3D source failed, try sprite fallback
  -- so this is what makes a Gen III follower (dex 252-386) possible at all,
  -- and it also catches a plain "no Stadium ROM imported" install.
  if ColosseumMon.available(dex, "normal") then
    currentSpecies = dex
    usingSpriteFallback = false
    usingColosseum = true
    colosseumVariant = "normal"
    writeMarker(dex)
    print("StadiumFollower: Loaded Colosseum follower dex", dex)
    return true
  end
  
  -- If every 3D source failed, try sprite fallback
  print("StadiumFollower: 3D model unavailable for dex", dex, ", trying sprite fallback")
  local spriteOk, spriteErr = loadSpriteFallback(dex)
  if spriteOk then
    -- Save the enabled state
    writeMarker(dex)
    print("StadiumFollower: Loaded sprite fallback for dex", dex)
    return true
  else
    print("StadiumFollower: Sprite fallback also failed:", spriteErr)
    return false, "could not load 3D model or sprite: " .. tostring(spriteErr)
  end
end

-- Get the current follower species
function StadiumFollower.getSpecies()
  return currentSpecies
end

-- Read the saved follower species from marker file without loading the model
function StadiumFollower.readSaved()
  return readMarker()
end

-- Load the saved follower species from marker file and set it (which loads the model)
function StadiumFollower.loadSaved()
  local saved = readMarker()
  if saved and saved > 0 then
    print("StadiumFollower: Loading saved follower dex", saved)
    -- setSpecies now handles both 3D model and sprite fallback internally
    local ok = StadiumFollower.setSpecies(saved)
    if ok then
      print("StadiumFollower: Successfully loaded saved follower")
    else
      print("StadiumFollower: Failed to load saved follower")
    end
  else
    print("StadiumFollower: No saved follower or disabled")
  end
end

-- Try to load deferred follower species (called when Stadium models become available)
function StadiumFollower.tryDeferredLoad()
  if StadiumFollower.deferredLoad then
    print("StadiumFollower: Loading deferred follower dex", StadiumFollower.deferredLoad)
    local ok = StadiumFollower.setSpecies(StadiumFollower.deferredLoad)
    if ok then
      print("StadiumFollower: Successfully loaded deferred follower")
      StadiumFollower.deferredLoad = nil
    else
      print("StadiumFollower: Failed to load deferred follower")
    end
  end
end

-- Check for deferred load and try to load if models are now available
function StadiumFollower.checkDeferred()
  if StadiumFollower.deferredLoad then
    local okInstall, StadiumInstall = pcall(V.require, "StadiumInstall")
    if okInstall and StadiumInstall and StadiumInstall.available() then
      StadiumFollower.tryDeferredLoad()
    end
  end
end

-- ------- Rendering

-- Update animation state
function StadiumFollower.update(dt)
  if usingColosseum then
    ColosseumMon.update(currentSpecies, colosseumVariant, dt)
    return
  end
  if not currentRig then return end
  
  animTime = animTime + dt
  currentRig:pose(currentAnim, animTime * 30, true)  -- 30 FPS
  currentRig:anchor(0.75, dt)
  currentRig:textures(nil)
end

-- Draw the follower at the given position
-- x, y: world coordinates (pixel position)
-- facing: direction the follower is facing ("up", "down", "left", "right")
function StadiumFollower.draw(x, y, facing)
  print("[StadiumFollower.draw] Called with x:", x, "y:", y, "facing:", facing, "currentRig:", currentRig ~= nil, "currentModel:", currentModel ~= nil, "currentSprite:", currentSprite ~= nil, "usingSpriteFallback:", usingSpriteFallback)
  
  -- Handle sprite fallback
  if usingSpriteFallback and currentSprite then
    return StadiumFollower.drawSprite(x, y, facing)
  end
  
  -- Handle Colosseum 3D model (dex outside StadiumPack's 1-151 range, or no
  -- Stadium ROM installed at all)
  if usingColosseum then
    local fx, fz = ColosseumMon.towardFor(facing)
    -- Camera-relative free-roam rotation isn't wired through ColosseumMon's
    -- simpler toward-vector API yet; it draws facing the raw movement
    -- direction in that mode, same as StadiumWilds' wild Pokemon already do.
    local matrix = ColosseumMon.matrix(currentSpecies, colosseumVariant, x, 0, y, fx, fz)
    if not matrix then return false end
    return ColosseumMon.draw(currentSpecies, colosseumVariant, matrix)
  end

  -- Handle 3D model
  if not currentRig or not currentModel then return false end

  -- Calculate the model matrix
  local m = Mat4.translate(x, 0, y)

  -- Check if we're in free-roam mode (1st or 3rd person)
  local FirstPerson = V.require("FirstPerson")
  local b = FirstPerson.cardBlend()

  -- Apply rotation based on facing direction
  local yaw = 0

  if b > 0 then
    -- In free-roam mode, use camera-relative rotation like the player model
    local cameraYaw = FirstPerson.cardYaw(x, y)

    if facing == "down" then
      -- Moving backwards: face the camera
      yaw = cameraYaw * b

    elseif facing == "up" then
      -- Moving forward: face away from the camera
      yaw = (cameraYaw + math.pi) * b

    elseif facing == "left" then
      -- Moving left: turn 90 degrees left
      yaw = (cameraYaw + math.pi / 2) * b

    elseif facing == "right" then
      -- Moving right: turn 90 degrees right
      yaw = (cameraYaw - math.pi / 2) * b
    end

  else
    -- In other modes, rotate based on movement direction
    if facing == "right" then
      yaw = math.pi / 2
    elseif facing == "up" then
      yaw = math.pi
    elseif facing == "left" then
      yaw = -math.pi / 2
    end
  end

  if yaw ~= 0 then
    m = Mat4.mul(m, Mat4.rotateY(yaw))
  end
  
  -- Apply scaling
  local model = currentModel
  local scale = StadiumMon.scaleFor(model) * FOLLOWER_SCALE
  m = Mat4.mul(m, Mat4.scale(scale, scale, scale))
  
  -- Stand the model on its own lowest point and give back HOVER_CAP of any
  -- authored hover, same as StadiumWilds/PlayerModel/battle Pokemon --
  -- otherwise a hovering or origin-centred species renders sunk into the
  -- ground instead of standing on it.
  local lift = StadiumMon.liftFor(model)
  if lift ~= 0 then
    m = Mat4.mul(m, Mat4.translate(0, -lift, 0))
  end
  
  -- Skin and draw
  currentRig:skin(yaw)
  currentRig:draw(m)
  
  return true
end

-- Draw the sprite fallback at the given position
function StadiumFollower.drawSprite(x, y, facing)
  if not currentSprite then
    return false
  end
  
  print("[StadiumFollower.drawSprite] Drawing sprite at x:", x, "y:", y, "facing:", facing)
  
  -- Try to use love.graphics for sprite rendering
  local lg = love and love.graphics
  if not lg then
    print("[StadiumFollower.drawSprite] love.graphics not available")
    return false
  end
  
  lg.push()
  lg.translate(x, y)
  lg.scale(FOLLOWER_SCALE, FOLLOWER_SCALE)
  
  -- Draw sprite centered
  local sw, sh = currentSprite:getDimensions()
  lg.draw(currentSprite, -sw/2, -sh/2)
  
  lg.pop()
  
  return true
end

-- ------- Cleanup

-- Clear all cached rigs
function StadiumFollower.clearCache()
  for dex, rig in pairs(rigCache) do
    if rig then
      pcall(function() rig:release() end)
    end
  end
  rigCache = {}
  
  -- Clear sprite cache
  spriteCache = {}
  
  currentRig = nil
  currentModel = nil
  currentSprite = nil
  currentSpecies = nil
  usingSpriteFallback = false
  usingColosseum = false
  animTime = 0
  pcall(ColosseumMon.clearCache)
end

-- Check if a follower is currently loaded
function StadiumFollower.loaded()
  local result = (currentRig ~= nil and currentModel ~= nil) or (currentSprite ~= nil) or usingColosseum
  print("[StadiumFollower.loaded] Returning:", result, "currentRig:", currentRig ~= nil, "currentModel:", currentModel ~= nil, "currentSprite:", currentSprite ~= nil, "currentSpecies:", currentSpecies, "usingSpriteFallback:", usingSpriteFallback)
  return result
end

-- Check if the follower is using sprite fallback
function StadiumFollower.isUsingSpriteFallback()
  return usingSpriteFallback
end

return StadiumFollower