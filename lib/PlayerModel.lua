-- PLAYER MODEL: loading and rendering custom 3D models for the player character.
--
-- This module handles loading .obj and .glb files and rendering them
-- in place of the default player sprite. It integrates with the existing
-- Voxel3D rendering pipeline. (.gltf, the multi-file JSON variant, is not
-- supported -- export as single-file .glb instead. See GLBModel.lua.)

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")
local PlayerModelInstall = V.require("PlayerModelInstall")
local StadiumPack = V.require("StadiumPack")
local Stadium2Pack = V.require("Stadium2Pack")
local StadiumRig = V.require("StadiumRig")
local StadiumMon = V.require("StadiumMon")
local ColosseumMon = V.require("ColosseumMon")
local ColosseumTrainer = V.require("ColosseumTrainer")
local GeneratedAssets = V.require("GeneratedAssets")
local CharacterWalkCycle = V.require("CharacterWalkCycle")

local PlayerModel = {}

-- Cache for loaded models to avoid reloading every frame
local modelCache = {}

-- Cache for loaded textures to avoid reloading every frame
local textureCache = {}

-- Current loaded model data
local currentModel = nil
local currentTexture = nil
local currentFilename = nil
local currentRig = nil
local currentStadiumModel = nil
local isStadiumModel = false

-- The Colosseum (GC6E01) actor path, used whenever no Stadium/Stadium2 model
-- covers this dex (every Gen III species, and any dex at all when only a
-- Colosseum disc -- no Stadium ROM -- has been imported). Mirrors
-- StadiumFollower's usingColosseum/colosseumVariant pair.
local usingColosseum = false
local colosseumVariant = "normal"
local currentColosseumDex = nil

-- A Colosseum trainer/character model standing in for the player sprite
-- (see PlayerModel.loadColosseumCharacter / lib/ColosseumTrainer.lua).
-- Static geometry only: the source dense-morph/idle-breath system that
-- animates a trainer in battle lives entirely in the battle-only
-- PlayerTrainer.lua/TrainerMorph.lua pipeline (its own shader, its own
-- vp/pose contract) and isn't something this overworld module can reach or
-- drive -- see ColosseumTrainer.lua's header for why. A motionless standing
-- figure using each model's authored rest pose is still a real, correctly
-- shaped/textured/scaled overworld option, the same kind of deliberate
-- scope limit GLBModel.lua documents for its own static-only .glb models.
local usingCharacter = false
local characterWalkTime = 0  -- Track walking animation time
local characterIdleTime = 0  -- Track idle animation time
local characterNativeTrack = nil  -- Store native animation track
local characterNativeAge = 0  -- Track native animation age
local currentCharacterId = nil
local characterGroups = nil    -- array of {mesh=, texture=, baseVertices=} for the current character
local characterCache = {}      -- id -> {groups=, scale=, walkRig=}, kept separate from modelCache/textureCache below since a character is several mesh+texture pairs, not one

-- Per-vertex hip/knee/shoulder bucket rig for the current character (see
-- lib/CharacterWalkCycle.lua) and the smoothed 0..1 blend that eases the
-- swing in when the player starts moving and back out when they stop.
-- characterWalkVertexBuffers holds one reusable vertexData table per mesh
-- group so CharacterWalkCycle.apply doesn't allocate a fresh table of
-- tables every single frame the player is walking.
local characterWalkRig = nil
local characterWalkBlend = 0
local characterWalkVertexBuffers = {}

-- Target overworld world-unit height for a standing human figure. Matches
-- FirstPerson.EYE_HEIGHT (13, near the top of the head on the default 16px
-- player sprite) -- see FirstPerson.lua -- so a Colosseum character model
-- lines up with the same world scale the sprite and camera already assume.
-- Source Colosseum trainer models are normalized to their own real HSD
-- source-unit height by TrainerExtractor (see model_cache.lua's `bounds`),
-- so the actual per-model scale is CHARACTER_HEIGHT / that source height,
-- computed once when a character is loaded (see loadColosseumCharacter).
local CHARACTER_HEIGHT = 16

-- Animation state
local animTime = 0

-- ------- OBJ file parsing (basic implementation)
--
-- Parses a simple .obj file to extract vertices, texture coordinates, faces, and material info.
-- This is a minimal implementation focused on getting basic geometry working with textures.
local function parseObj(objData)
  local vertices = {}
  local texCoords = {}
  local faces = {}
  local mtlFile = nil
  local currentMaterial = nil
  
  for line in objData:gmatch("[^\r\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line:sub(1, 1) == "#" or line == "" then
      -- Skip comments and empty lines
    elseif line:sub(1, 2) == "v " then
      -- Vertex: v x y z
      local x, y, z = line:match("^v%s+([%d%.%-]+)%s+([%d%.%-]+)%s+([%d%.%-]+)")
      if x and y and z then
        table.insert(vertices, { tonumber(x), tonumber(y), tonumber(z) })
      end
    elseif line:sub(1, 3) == "vt " then
      -- Texture coordinate: vt u v
      local u, v = line:match("^vt%s+([%d%.%-]+)%s+([%d%.%-]+)")
      if u and v then
        table.insert(texCoords, { tonumber(u), tonumber(v) })
      end
    elseif line:sub(1, 7) == "mtllib " then
      -- Material library: mtllib filename.mtl
      mtlFile = line:match("^mtllib%s+(.+)")
    elseif line:sub(1, 7) == "usemtl " then
      -- Use material: usemtl material_name
      currentMaterial = line:match("^usemtl%s+(.+)")
    elseif line:sub(1, 2) == "f " then
      -- Face: f v1/t1/n1 v2/t2/n2 v3/t3/n3 (texture and normals optional)
      -- Parse with texture coordinates
      local v1, t1, v2, t2, v3, t3 = line:match("^f%s+(%d+)/(%d*)/?%d*%s+(%d+)/(%d*)/?%d*%s+(%d+)/(%d*)/?%d*")
      if v1 and v2 and v3 then
        table.insert(faces, {
          v = { tonumber(v1), tonumber(v2), tonumber(v3) },
          t = { t1 ~= "" and tonumber(t1) or nil, t2 ~= "" and tonumber(t2) or nil, t3 ~= "" and tonumber(t3) or nil },
          material = currentMaterial
        })
      else
        -- Try without texture coordinates
        v1, v2, v3 = line:match("^f%s+(%d+)%s+(%d+)%s+(%d+)")
        if v1 and v2 and v3 then
          table.insert(faces, {
            v = { tonumber(v1), tonumber(v2), tonumber(v3) },
            t = { nil, nil, nil },
            material = currentMaterial
          })
        end
      end
    end
  end
  
  return vertices, texCoords, faces, mtlFile
end

-- Parse MTL file to extract texture map references
local function parseMtl(mtlData)
  local materials = {}
  local currentMaterial = nil
  
  for line in mtlData:gmatch("[^\r\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line:sub(1, 1) == "#" or line == "" then
      -- Skip comments and empty lines
    elseif line:sub(1, 7) == "newmtl " then
      -- New material: newmtl material_name
      currentMaterial = line:match("^newmtl%s+(.+)")
      materials[currentMaterial] = {}
    elseif line:sub(1, 7) == "map_Kd " then
      -- Diffuse texture map: map_Kd filename.png
      if currentMaterial and materials[currentMaterial] then
        local textureFile = line:match("^map_Kd%s+(.+)")
        materials[currentMaterial].texture = textureFile
      end
    end
  end
  
  return materials
end

-- Convert OBJ data to a mesh compatible with Voxel3D
local function objToMesh(vertices, texCoords, faces)
  if #vertices == 0 or #faces == 0 then
    return nil
  end
  
  -- Build vertex buffer in Voxel3D.FORMAT
  -- Format: { "VertexPosition", "float", 3 }, { "VertexTexCoord", "float", 2 }, { "VertexShade", "float", 1 }
  -- LÖVE expects table of tables, where each vertex is its own table
  local vertexData = {}
  
  for faceIndex, face in ipairs(faces) do
    for i = 1, 3 do
      local vertexIndex = face.v[i]
      local texCoordIndex = face.t[i]
      
      -- OBJ indices are 1-based, convert to 0-based
      local v = vertices[vertexIndex] or vertices[1]
      local tc = texCoordIndex and texCoords[texCoordIndex]
      
      if v then
        -- Create a vertex table with 6 values: x, y, z, u, v, shade
        local vertex = {
          v[1],           -- x
          v[2],          -- y (flipped to match coordinate system)
          v[3],          -- z (flipped to face the right direction)
          tc and tc[1] or 0,  -- u (texture coordinate)
          tc and tc[2] or 0,  -- v (texture coordinate, flipped for LOVE)
          1.0             -- shade
        }
        table.insert(vertexData, vertex)
      end
    end
  end

  if #vertexData == 0 then
    return nil
  end

  -- Create mesh
  local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, vertexData, "triangles")
  if not ok then
    return nil
  end

  return mesh
end

-- ------- Model loading

-- Load a model from a file. Returns success plus mesh or error message.
function PlayerModel.load(filename)
  if not filename then return false, "no filename" end

  -- Check cache first
  if modelCache[filename] then
    currentModel = modelCache[filename]
    currentTexture = textureCache[filename]
    currentFilename = filename
    return true
  end
  
  local path = PlayerModelInstall.DIR .. "/" .. filename
  local f = love and love.filesystem
  if not (f and f.read) then return false, "no filesystem" end
  
  -- Read file
  local ok, data = pcall(f.read, path)
  if not ok or not data then
    return false, "could not read file"
  end

  -- Determine file type and parse accordingly
  local ext = filename:lower():match("%.([^.]+)$")
  local mesh = nil
  local texture = nil
  
  if ext == "obj" then
    local vertices, texCoords, faces, mtlFile = parseObj(data)

    -- Load texture if MTL file is specified
    if mtlFile then
      local mtlPath = PlayerModelInstall.DIR .. "/" .. mtlFile
      local mtlOk, mtlData = pcall(f.read, mtlPath)
      if mtlOk and mtlData then
        local materials = parseMtl(mtlData)

        -- Get the first material's texture (simplified - uses first found texture)
        for matName, matData in pairs(materials) do
          if matData.texture then
            local texturePath = PlayerModelInstall.DIR .. "/" .. matData.texture
            local texOk, texData = pcall(f.read, texturePath)
            if texOk and texData then
              local imgOk, image = pcall(love.graphics.newImage, love.filesystem.newFileData(texData, matData.texture))
              if imgOk and image then
                texture = image
                break
              end
            end
          end
        end
      end
    end

    mesh = objToMesh(vertices, texCoords, faces)
  elseif ext == "glb" then
    local GLBModel = V.require("GLBModel")
    local glbMesh, glbTexture, glbErr, glbStats = GLBModel.load(data, Voxel3D)
    if not glbMesh then
      return false, glbErr or "failed to load glb"
    end
    mesh = glbMesh
    texture = glbTexture
  elseif ext == "gltf" then
    -- .gltf (JSON + separate .bin/.png files) isn't handled yet -- only the
    -- single-file .glb container is. Convert with e.g. Blender's glTF
    -- exporter set to "glTF Binary (.glb)".
    return false, ".gltf not supported yet - please export as .glb"
  else
    return false, "unsupported file format: " .. (ext or "unknown")
  end
  
  if not mesh then
    return false, "failed to create mesh from model"
  end

  -- Cache the mesh and texture
  modelCache[filename] = mesh
  textureCache[filename] = texture
  currentModel = mesh
  currentTexture = texture
  currentFilename = filename

  return true
end

-- Load a 3D model by dex number (e.g., 150 for Mewtwo), preferring a
-- Colosseum-sourced model (see ColosseumMon) when the player has that disc
-- imported, since it alone covers the complete 386-species Gen I-III
-- roster and keeps every species drawn in the same art style. Falls back to
-- Stadium2Pack (1-251) or StadiumPack (1-151) for whichever of those two the
-- player happens to have imported instead, so a player with only one source
-- installed is capped at that source's own roster rather than failing outright.
function PlayerModel.loadStadium(dex)
  if not dex then return false, "no dex number" end

  -- Check cache first (Stadium/Stadium2 rigs only -- a Colosseum actor is
  -- ColosseumMon's own shared cache, checked via .available()/.matrix() below
  -- instead of here)
  local cacheKey = "stadium_" .. dex
  if usingColosseum and currentColosseumDex == dex then
    currentFilename = "colosseum_" .. dex
    return true
  end
  if modelCache[cacheKey] then
    currentModel = modelCache[cacheKey]
    currentRig = textureCache[cacheKey]  -- Reuse textureCache for rig cache
    currentStadiumModel = currentRig and currentRig.model
    currentFilename = "stadium_" .. dex
    isStadiumModel = true
    usingColosseum = false
    return true
  end

  -- Colosseum first: covers the whole 386-species roster on its own, so
  -- prefer it whenever the player has that disc imported instead of mixing
  -- art styles species-by-species with whichever Stadium pack is present.
  if ColosseumMon.available(dex, colosseumVariant) then
    currentRig = nil
    currentStadiumModel = nil
    currentModel = nil
    currentTexture = nil
    currentFilename = "colosseum_" .. dex
    isStadiumModel = false
    usingColosseum = true
    currentColosseumDex = dex
    return true
  end

  -- No Colosseum disc imported (or this dex isn't in ColosseumDex, which
  -- shouldn't happen for 1-386) -- fall back to whichever Stadium pack the
  -- player has. Stadium2Pack covers 1-251; StadiumPack covers 1-151. Try
  -- whichever is the better fit for this dex first, then the other, so a
  -- player with only one imported isn't capped below what that one pack
  -- alone provides.
  local model
  local stadium2Available = Stadium2Pack.available()

  if stadium2Available then
    model = Stadium2Pack.load(dex, false)
    if not model then
      model = StadiumPack.load(dex, false)
    end
  elseif dex > 151 then
    model = StadiumPack.load(dex, false)
  else
    model = StadiumPack.load(dex, false)
    if not model then
      model = Stadium2Pack.load(dex, false)
    end
  end
  
  if model and not model.staticPose then
    -- Create the rig
    local rig = StadiumRig.new(model)
    if rig then
      -- Cache the rig and model
      modelCache[cacheKey] = rig  -- Store rig in modelCache
      textureCache[cacheKey] = rig  -- Store rig in textureCache for consistency
      currentRig = rig
      currentStadiumModel = model
      currentModel = nil  -- No static mesh for Stadium models
      currentTexture = nil
      currentFilename = "stadium_" .. dex
      isStadiumModel = true
      usingColosseum = false

      -- Start idle animation
      rig:pose(1, 0, true)  -- Animation 1 is idle, time 0, loop true
      rig:skin(0)  -- No rotation initially

      return true
    end
  end

  return false, "could not load colosseum or stadium model"
end

-- Get the current dex number loaded, whether the source is a Stadium/
-- Stadium2 rig or a Colosseum actor -- callers (PlayerModelPick's cycler)
-- don't need to know which backend answered.
function PlayerModel.getStadiumDex()
  if not currentFilename then return nil end
  if isStadiumModel then
    local dexStr = currentFilename:match("^stadium_(%d+)$")
    return dexStr and tonumber(dexStr) or nil
  end
  if usingColosseum then
    local dexStr = currentFilename:match("^colosseum_(%d+)$")
    return dexStr and tonumber(dexStr) or nil
  end
  return nil
end

-- Load a Colosseum trainer/character model (e.g. "red", "wes", "miror_b" --
-- see ColosseumTrainer.CHARACTERS) to stand in for the player's own
-- overworld appearance. Static rest-pose mesh only -- see the state comment
-- above for why. Builds one love.graphics.Mesh + optional texture per
-- material group in the trainer's model_cache.lua, the same per-group shape
-- PlayerTrainer.lua's battle renderer reads, just without that renderer's
-- dense vertex-morph/shader machinery this module has no way to drive.
function PlayerModel.loadColosseumCharacter(id)
  if not id or id == "" then return false, "no character id" end

  local cached = characterCache[id]
  if cached then
    characterGroups = cached.groups
    characterWalkRig = cached.walkRig
    characterWalkVertexBuffers = {}
    currentCharacterId = id
    currentFilename = "colosseum_character_" .. id
    usingCharacter = true
    isStadiumModel = false
    usingColosseum = false
    currentModel = nil
    currentTexture = nil
    currentRig = nil
    currentStadiumModel = nil
    return true
  end

  local cfg = ColosseumTrainer.configFor(id)
  if not cfg or not cfg.cache then
    return false, "colosseum trainer data not available: " .. tostring(id)
  end

  local cache, err = GeneratedAssets.readLua(cfg.cache)
  if type(cache) ~= "table" or type(cache.groups) ~= "table" or #cache.groups == 0 then
    return false, tostring(err or "empty trainer cache")
  end

  if not (love and love.graphics and love.graphics.newMesh) then
    return false, "love.graphics unavailable"
  end

  local groups = {}
  for gi, g in ipairs(cache.groups) do
    local vertices = g.vertices
    if type(vertices) == "table" and #vertices > 0 then
      -- Store base vertices and UVs for native animation offset application
      local baseVertices = {}
      local baseUVs = {}
      for _, v in ipairs(vertices) do
        baseVertices[#baseVertices + 1] = {v[1] or 0, v[2] or 0, v[3] or 0}
        baseUVs[#baseUVs + 1] = {v[4] or 0, v[5] or 0}
      end

      -- Base (rest-pose) position + UV only -- v[1..3] is the authored
      -- source position TrainerExtractor.normalize already centered on X/Z
      -- and grounded at Y=0 (feet), v[4..5] is U/V. The dense format also
      -- carries a baked normal at v[6..8] and twelve morph-target position
      -- triples after that (see TrainerExtractor.cacheLua), none of which
      -- Voxel3D.FORMAT has room for or uses -- shade is left flat (1.0),
      -- the same fallback GLBModel/objToMesh use for a model with no baked
      -- per-vertex lighting channel of their own.
      local vertexData = {}
      for vi, v in ipairs(vertices) do
        vertexData[#vertexData + 1] = {
          v[1] or 0, v[2] or 0, v[3] or 0,
          v[4] or 0, v[5] or 0,
          1.0, 0.0,
        }
      end
      local meshOk, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, vertexData, "triangles", "dynamic")
      if meshOk and mesh then
        local texture = nil
        local tex = g.texture
        if tex and tex.path and love.image then
          local bytes, texErr = GeneratedAssets.read(tex.path)
          if bytes then
            local dataOk, imgData = pcall(love.image.newImageData, tex.w, tex.h, "rgba8", bytes)
            if dataOk and imgData then
              local imgOk, img = pcall(love.graphics.newImage, imgData)
              if imgOk and img then
                texture = img
              end
            end
          end
        end
        groups[#groups + 1] = { mesh = mesh, texture = texture, baseVertices = baseVertices, baseUVs = baseUVs }
      end
    end
  end

  if #groups == 0 then
    return false, "no drawable mesh groups for " .. tostring(id)
  end

  local b = cache.bounds
  local sourceHeight = b and ((tonumber(b.max and b.max[2]) or 0) - (tonumber(b.min and b.min[2]) or 0)) or 0
  local scale = (sourceHeight > 0) and (CHARACTER_HEIGHT / sourceHeight) or 1.0

  -- Build the hip/knee/shoulder vertex-bucket rig once here (see
  -- lib/CharacterWalkCycle.lua) rather than every frame -- it's the same
  -- per-character shoulder/width landmarks TrainerRig.profile already
  -- computes for the throw-anchor system, just sorted into buckets.
  local walkRigOk, walkRig = pcall(CharacterWalkCycle.build, id, groups, b)
  if not walkRigOk then walkRig = nil end

  characterCache[id] = { groups = groups, scale = scale, walkRig = walkRig }
  characterGroups = groups
  characterWalkRig = walkRig
  characterWalkVertexBuffers = {}
  currentCharacterId = id
  currentFilename = "colosseum_character_" .. id
  usingCharacter = true
  isStadiumModel = false
  usingColosseum = false
  currentModel = nil
  currentTexture = nil
  currentRig = nil
  currentStadiumModel = nil
  
  -- Load the native animation track for idle animations
  local trackPath = ("cache/trainers/%s/native_v1/index.lua"):format(id)
  local track, trackErr = GeneratedAssets.readLua(trackPath)
  if track and track.version == 1 and track.roles then
    characterNativeTrack = track
    characterNativeAge = 0
  else
    characterNativeTrack = nil
  end

  return true
end

-- Get the id of the currently loaded Colosseum character, or nil.
function PlayerModel.getCharacterId()
  if usingCharacter then return currentCharacterId end
  return nil
end

-- Get the current character model ID from settings (delegates to CharacterModelPick)
function PlayerModel.getCurrentCharacterId()
  local CharacterModelPick = V.require("CharacterModelPick")
  return CharacterModelPick.getCurrentCharacterId()
end

-- Load the currently installed model (if any).
function PlayerModel.loadInstalled()
  local filename = PlayerModelInstall.modelFilename()
  if not filename then return false end
  
  -- Check if this is a Stadium/Colosseum model marker (format:
  -- stadium_player_X). loadStadium(dex) tries Stadium/Stadium2 first and
  -- falls back to Colosseum, so the marker format didn't need to change --
  -- only the accepted range, now the full 386-species Gen I-III roster
  -- Colosseum covers rather than just Stadium's 151.
  local dexStr = filename:match("stadium_player_(%d+)")
  if dexStr then
    local dex = tonumber(dexStr)
    if dex and dex >= 1 and dex <= 386 then
      return PlayerModel.loadStadium(dex)
    end
  end

  -- Or a Colosseum trainer/character marker (format:
  -- colosseum_character_ID -- see loadColosseumCharacter/followerRow).
  local characterId = filename:match("^colosseum_character_(.+)$")
  if characterId then
    return PlayerModel.loadColosseumCharacter(characterId)
  end
  
  -- Check if it's a character model setting (from CharacterModelPick)
  local CharacterModelPick = V.require("CharacterModelPick")
  local currentCharacterId = CharacterModelPick.getCurrentCharacterId()
  if currentCharacterId and currentCharacterId ~= "off" then
    return PlayerModel.loadColosseumCharacter(currentCharacterId)
  end
  
  -- Otherwise load as regular OBJ model
  return PlayerModel.load(filename)
end

-- Clear the current model. Leaves modelCache/textureCache/characterCache
-- alone (same contract as the Stadium/Colosseum branches above) -- only
-- clearCache() below tears those down.
function PlayerModel.clear()
  if currentRig then
    currentRig:release()
    currentRig = nil
  end
  currentModel = nil
  currentTexture = nil
  currentFilename = nil
  currentStadiumModel = nil
  isStadiumModel = false
  usingColosseum = false
  currentColosseumDex = nil
  usingCharacter = false
  currentCharacterId = nil
  characterGroups = nil
  characterWalkTime = 0  -- Reset walk animation time
  characterWalkBlend = 0
  characterWalkRig = nil
  characterWalkVertexBuffers = {}
end

-- Check if a model is currently loaded.
function PlayerModel.loaded()
  return currentModel ~= nil or (currentRig ~= nil and currentStadiumModel ~= nil) or usingColosseum or usingCharacter
end

-- Get the filename of the currently loaded model.
function PlayerModel.filename()
  return currentFilename
end

-- ------- Rendering

-- Draw the player model at the given position with the given transform.
-- This integrates with the existing Voxel3D pipeline.
function PlayerModel.draw(px, py, y, facing, mirror)
  -- In free-roam mode with FreeMove, use the actual body facing direction
  local FirstPerson = V.require("FirstPerson")
  local b = FirstPerson.cardBlend()
  if b > 0 then
    -- Use the continuous body facing from FirstPerson instead of grid facing
    facing = FirstPerson.pointBody(0, 0)
  end
  
  -- Handle a Colosseum-sourced model (Gen III dex, or any dex with no
  -- Stadium ROM imported). Mirrors StadiumFollower's Colosseum branch:
  -- camera-relative free-roam rotation isn't wired through ColosseumMon's
  -- simpler toward-vector API yet, so this draws facing the raw movement
  -- direction in that mode too, same known gap as the follower.
  if usingColosseum and currentColosseumDex then
    local dt = 1 / 60  -- Assume 60 FPS, same assumption the Stadium branch makes
    ColosseumMon.update(currentColosseumDex, colosseumVariant, dt)

    -- Check if we're in free-roam mode (1st or 3rd person)
    local FirstPerson = V.require("FirstPerson")
    local b = FirstPerson.cardBlend()
    
    -- Detect if player is moving by checking actual input
    local Game = require("src.core.Game")
    local isMoving = Game.input:isDown("up") or Game.input:isDown("down") 
                    or Game.input:isDown("left") or Game.input:isDown("right")
    
    local fx, fz
    local m
    
    if isMoving and b > 0 then
      -- When moving in free-roam mode, detect which key is pressed and use that direction
      local moveDirection = facing
      if Game.input:isDown("up") then
        moveDirection = "up"
      elseif Game.input:isDown("down") then
        moveDirection = "down"
      elseif Game.input:isDown("left") then
        moveDirection = "left"
      elseif Game.input:isDown("right") then
        moveDirection = "right"
      end
      
      -- Calculate rotation based on camera yaw and movement direction
      local cameraYaw = FirstPerson.cardYaw(px + 8, py + 8)
      local yaw = 0
      
      if moveDirection == "down" then
        yaw = (cameraYaw + math.pi) * b
      elseif moveDirection == "up" then
        yaw = cameraYaw * b
      elseif moveDirection == "right" then
        yaw = (cameraYaw - math.pi / 2) * b
      elseif moveDirection == "left" then
        yaw = (cameraYaw + math.pi / 2) * b
      end
      
      -- Create base matrix with position
      m = Mat4.translate(px + 8, y, py + 8)
      
      -- Apply the calculated rotation
      if yaw ~= 0 then
        m = Mat4.mul(m, Mat4.rotateY(yaw))
      end
      
      -- Use forward direction for towardFor (the rotation handles the actual direction)
      fx, fz = ColosseumMon.towardFor("up")
      local tempM = ColosseumMon.matrix(currentColosseumDex, colosseumVariant, 0, 0, 0, fx, fz)
      if tempM then
        -- Extract just the scale/transform parts from the Colosseum matrix
        -- and apply them to our positioned+rotated matrix
        m = Mat4.mul(m, tempM)
      end
    elseif b > 0 then
      -- When idle in free-roam mode, follow camera yaw
      local cameraYaw = FirstPerson.cardYaw(px + 8, py + 8)
      
      -- Create base matrix with position
      m = Mat4.translate(px + 8, y, py + 8)
      
      -- Apply camera yaw rotation
      m = Mat4.mul(m, Mat4.rotateY(cameraYaw))
      
      -- Use forward direction for towardFor
      fx, fz = ColosseumMon.towardFor("up")
      local tempM = ColosseumMon.matrix(currentColosseumDex, colosseumVariant, 0, 0, 0, fx, fz)
      if tempM then
        m = Mat4.mul(m, tempM)
      end
    else
      -- In other modes, use simple movement direction
      -- Create base matrix with position
      m = Mat4.translate(px + 8, y, py + 8)
      
      -- Apply simple rotation based on facing
      local yaw = 0
      if facing == "right" then
        yaw = math.pi / 2
      elseif facing == "up" then
        yaw = math.pi
      elseif facing == "left" then
        yaw = -math.pi / 2
      end
      
      if yaw ~= 0 then
        m = Mat4.mul(m, Mat4.rotateY(yaw))
      end
      
      -- Use facing direction for towardFor
      fx, fz = ColosseumMon.towardFor(facing)
      local tempM = ColosseumMon.matrix(currentColosseumDex, colosseumVariant, 0, 0, 0, fx, fz)
      if tempM then
        m = Mat4.mul(m, tempM)
      end
    end

    if mirror then
      m = Mat4.mul(m, Mat4.scale(-1, 1, 1))
    end

    return ColosseumMon.draw(currentColosseumDex, colosseumVariant, m)
  end

  -- Handle Stadium models (animated skeletal models)
  if isStadiumModel and currentRig and currentStadiumModel then
    -- Update animation time
    local dt = 1 / 60  -- Assume 60 FPS for simplicity
    animTime = animTime + dt
    
    -- Use idle animation for both walking and standing still
    currentRig:pose(1, animTime * 30, true)  -- Idle animation at 30 FPS
    currentRig:anchor(0.75, dt)  -- Anchor to prevent drifting
    currentRig:textures(nil)  -- Update textures (eyes blinking)
    
    -- Calculate the model matrix based on position and facing
    local m = Mat4.translate(px + 8, y, py + 8)
    
    -- Check if we're in free-roam mode (1st or 3rd person)
    local FirstPerson = V.require("FirstPerson")
    local b = FirstPerson.cardBlend()
    
    -- Apply rotation based on facing direction
    local yaw = 0
    if b > 0 then
      -- In free-roam mode, use camera-relative rotation like StadiumFollower
      local cameraYaw = FirstPerson.cardYaw(px + 8, py + 8)
      
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
    
    -- Apply mirroring if needed
    if mirror then
      m = Mat4.mul(m, Mat4.scale(-1, 1, 1))
    end
    
    -- Apply scaling for Stadium model (use similar scale to Pokemon in battles)
    local model = currentStadiumModel
    local scale = StadiumMon.scaleFor(model) * 1.5  -- 0.5 * 4 = 2.0 (4x larger for Mewtwo)
    m = Mat4.mul(m, Mat4.scale(scale, scale, scale))
    
    -- Stand the model on its own lowest point and give back HOVER_CAP of
    -- any authored hover, same as StadiumWilds/battle Pokemon -- otherwise
    -- a species authored with a hover (or centred on its origin) renders
    -- sunk into the ground instead of standing on it.
    local lift = StadiumMon.liftFor(model)
    if lift ~= 0 then
      m = Mat4.mul(m, Mat4.translate(0, -lift, 0))
    end
    
    -- Skin the mesh with the calculated yaw
    currentRig:skin(yaw)
    
    -- Draw using the rig's built-in draw method
    currentRig:draw(m)
    
    return true
  end
  
  -- Handle Colosseum character models (static rest-pose trainer models)
  if usingCharacter and characterGroups then
    -- Debug: log character draw (throttled)
    if math.floor(characterIdleTime) > (PlayerModel._lastDrawLogTime or -999) then
      PlayerModel._lastDrawLogTime = math.floor(characterIdleTime)
      print("[PlayerModel.draw] Drawing character:", currentCharacterId, "idleTime:", characterIdleTime, "walkTime:", characterWalkTime, "hasNativeTrack:", characterNativeTrack ~= nil)
    end

    -- Use the same movement behavior as Pokemon player models
    local FirstPerson = V.require("FirstPerson")
    local b = FirstPerson.cardBlend()

    -- Detect if player is moving by checking actual input
    local Game = require("src.core.Game")
    local isMoving = Game.input:isDown("up") or Game.input:isDown("down")
                    or Game.input:isDown("left") or Game.input:isDown("right")

    -- Update animation time
    if isMoving then
      characterWalkTime = characterWalkTime + 0.15  -- Walk animation speed / gait phase
      characterIdleTime = 0  -- Reset idle when walking
    else
      characterIdleTime = characterIdleTime + 0.016  -- Idle animation speed (60fps)
      -- characterWalkTime deliberately isn't reset here -- see the
      -- characterWalkBlend easing right below. Freezing the gait phase
      -- where it stopped (rather than snapping it to 0) is what lets the
      -- leg swing relax smoothly back to neutral instead of jumping.
    end

    -- Smoothed 0..1 "how much walk swing should show right now" -- eases
    -- up over a few frames when the player starts moving, and back down
    -- over a few frames when they stop, instead of an instant on/off cut.
    -- See lib/CharacterWalkCycle.lua.
    characterWalkBlend = CharacterWalkCycle.updateBlend(characterWalkBlend, isMoving, 0.016, 10, 6)

    -- Procedural leg/arm swing (see lib/CharacterWalkCycle.lua's header for
    -- why this is a per-vertex heuristic rather than real bone animation
    -- like red_3d_player's humanoids: these Colosseum battle-actor models
    -- carry no skin weights, only baked idle morph targets). Runs whenever
    -- there's any swing left to show, not just while isMoving is literally
    -- true this frame, so characterWalkBlend's stop-easing above actually
    -- has motion to ease out of.
    if characterWalkRig and characterWalkBlend > 0.001 then
      for gi, group in ipairs(characterGroups) do
        if group.mesh and group.baseVertices then
          local buf = CharacterWalkCycle.apply(
            characterWalkRig, gi, group,
            characterWalkTime, characterWalkBlend,
            characterWalkVertexBuffers[gi]
          )
          characterWalkVertexBuffers[gi] = buf
          group.mesh:setVertices(buf)
        end
      end
    end

    -- Sample native idle animation from track if available. Held off
    -- until the walk swing has eased all the way back out (rather than
    -- simply "not isMoving") so the two systems don't fight over the same
    -- frame's vertex positions during the stop transition.
    if characterNativeTrack and not isMoving and characterWalkBlend <= 0.001 then
      local TrainerMorph = V.TrainerMorph
      if TrainerMorph then
        local clip, a, b, u, role = TrainerMorph.trackSample(characterNativeTrack, nil, characterIdleTime, nil, nil)

        -- Debug: log sampling result
        if math.floor(characterIdleTime) > (PlayerModel._lastNativeSampleLogTime or -999) then
          PlayerModel._lastNativeSampleLogTime = math.floor(characterIdleTime)
          print("[PlayerModel.draw] Native sample result: clip:", clip, "a:", a, "b:", b, "u:", u, "role:", role)
          if clip then
            print("[PlayerModel.draw] Clip has groups:", clip.groups and #clip.groups or "nil")
          end
        end

        if clip and a and b and clip.groups then
          -- Debug: log native sampling (throttled)
          if math.floor(characterIdleTime) > (PlayerModel._lastNativeSampleLogTime or -999) then
            PlayerModel._lastNativeSampleLogTime = math.floor(characterIdleTime)
            print("[PlayerModel.draw] Native idle sample: clip:", a, b, "u:", u, "role:", role, "groups:", #clip.groups, "characterGroups:", #characterGroups)
          end

          -- Apply vertex offsets from native track to each mesh group
          for gi, group in ipairs(characterGroups) do
            local clipGroup = clip.groups[gi]
            if clipGroup and clipGroup.path and group.baseVertices then
              -- Read native vertex data for this frame
              local clipPath = clipGroup.path
              local verticesPerFrame = #group.baseVertices
              local bytesPerVertex = 24  -- 6 floats * 4 bytes each (NativePosition + NativeNormal)
              local frameOffsetA = (a - 1) * verticesPerFrame * bytesPerVertex
              local frameOffsetB = (b - 1) * verticesPerFrame * bytesPerVertex

              local bytes = GeneratedAssets.read(clipPath)
              if bytes and #bytes >= frameOffsetB + verticesPerFrame * bytesPerVertex then
                -- Apply interpolated offsets to mesh
                local vertexData = {}
                for vi = 1, #group.baseVertices do
                  local base = group.baseVertices[vi]
                  local uv = group.baseUVs[vi]
                  local offsetA = frameOffsetA + (vi - 1) * bytesPerVertex
                  local offsetB = frameOffsetB + (vi - 1) * bytesPerVertex

                  -- Read interpolated position (first 3 floats = NativePosition)
                  local ax, ay, az = 0, 0, 0
                  local bx, by, bz = 0, 0, 0

                  -- Parse frame A position
                  if offsetA + 12 <= #bytes then
                    ax = string.unpack("<f", bytes, offsetA + 1)
                    ay = string.unpack("<f", bytes, offsetA + 5)
                    az = string.unpack("<f", bytes, offsetA + 9)
                  end

                  -- Parse frame B position
                  if offsetB + 12 <= #bytes then
                    bx = string.unpack("<f", bytes, offsetB + 1)
                    by = string.unpack("<f", bytes, offsetB + 5)
                    bz = string.unpack("<f", bytes, offsetB + 9)
                  end

                  -- Native track stores absolute positions, use them directly (interpolated)
                  local ox = ax + (bx - ax) * u
                  local oy = ay + (by - ay) * u
                  local oz = az + (bz - az) * u

                  vertexData[#vertexData + 1] = {
                    ox, oy, oz,
                    uv[1] or 0, uv[2] or 0,
                    1.0, 0.0
                  }
                end

                -- Update mesh with new vertex positions
                if group.mesh then
                  group.mesh:setVertices(vertexData)
                end
              else
                -- Debug: log why bytes check failed
                if math.floor(characterIdleTime) > (PlayerModel._lastNativeSampleLogTime or -999) then
                  print("[PlayerModel.draw] Bytes check failed: bytes:", bytes and #bytes or "nil", "needed:", frameOffsetB + verticesPerFrame * bytesPerVertex, "path:", clipPath)
                end
              end
            else
              -- Debug: log why clipGroup check failed
              if math.floor(characterIdleTime) > (PlayerModel._lastNativeSampleLogTime or -999) then
                print("[PlayerModel.draw] ClipGroup check failed: clipGroup:", clipGroup, "has baseVertices:", group.baseVertices ~= nil)
              end
            end
          end
        end
      end
    end
    
    -- Calculate the model matrix based on position and facing
    local m = Mat4.translate(px + 8, y, py + 8)
    
    -- Apply rotation based on facing direction (same as Pokemon models)
    local yaw = 0
    
    if b > 0 then
      -- In free-roam mode, use camera-relative rotation like Pokemon models
      local cameraYaw = FirstPerson.cardYaw(px + 8, py + 8)
      
      if isMoving then
        -- When moving in free-roam mode, detect which key is pressed and use that direction
        local moveDirection = facing
        if Game.input:isDown("up") then
          moveDirection = "up"
        elseif Game.input:isDown("down") then
          moveDirection = "down"
        elseif Game.input:isDown("left") then
          moveDirection = "left"
        elseif Game.input:isDown("right") then
          moveDirection = "right"
        end
        
        -- Calculate rotation based on camera yaw and movement direction
        if moveDirection == "down" then
          yaw = (cameraYaw + math.pi) * b
        elseif moveDirection == "up" then
          yaw = cameraYaw * b
        elseif moveDirection == "right" then
          yaw = (cameraYaw - math.pi / 2) * b
        elseif moveDirection == "left" then
          yaw = (cameraYaw + math.pi / 2) * b
        end
      else
        -- When idle in free-roam mode, follow camera yaw
        yaw = cameraYaw * b
      end
    else
      -- In other modes, use simple movement direction
      if facing == "right" then
        yaw = math.pi / 2
      elseif facing == "up" then
        yaw = math.pi
      elseif facing == "left" then
        yaw = -math.pi / 2
      end
    end
    
    -- Add 180-degree rotation so character faces the right direction
    m = Mat4.mul(m, Mat4.rotateY(yaw + math.pi))
    
    -- The old whole-body bob+rock hack that used to stand in for a walk
    -- animation lived here -- it's gone now that CharacterWalkCycle
    -- actually swings the legs/arms per vertex (including its own, much
    -- smaller torso bob, timed to the footfalls rather than a flat sine on
    -- the whole matrix). See the vertex-buffer block above.

    -- Apply mirroring if needed
    if mirror then
      m = Mat4.mul(m, Mat4.scale(-1, 1, 1))
    end
    
    -- Apply character scale from cache
    local cached = characterCache[currentCharacterId]
    local scale = cached and cached.scale or 1.0
    m = Mat4.mul(m, Mat4.scale(scale, scale, scale))
    
    -- Draw each material group with its texture
    local drawn = false
    for _, group in ipairs(characterGroups) do
      if group.mesh then
        Voxel3D.draw(group.mesh, group.texture, m)
        drawn = true
      end
    end
    
    return drawn
  end
  
  -- Handle static OBJ models
  if not currentModel then 
    return false 
  end
  
  -- Calculate the model matrix based on position and facing
  local m = Mat4.translate(px + 8, y, py + 8)
  
  -- Apply rotation based on facing direction
  local yaw = 0
  if facing == "right" then
    yaw = math.pi / 2
  elseif facing == "up" then
    yaw = math.pi
  elseif facing == "left" then
    yaw = -math.pi / 2
  end
  
  if yaw ~= 0 then
    m = Mat4.mul(m, Mat4.rotateY(yaw))
  end
  
  -- Apply mirroring if needed
  if mirror then
    m = Mat4.mul(m, Mat4.scale(-1, 1, 1))
  end
  
  -- Apply scaling to match game world units
  -- Increased scale to make the model more visible
  local scale = 4.0  -- Increased from 0.1 to 1.0
  m = Mat4.mul(m, Mat4.scale(scale, scale, scale))
  
  -- Draw the mesh using Voxel3D with texture
  Voxel3D.draw(currentModel, currentTexture, m)
  
  return true
end

-- ------- Cleanup

-- Clear the model cache to free memory.
function PlayerModel.clearCache()
  for key, mesh in pairs(modelCache) do
    if mesh then
      -- Check if this is a rig (Stadium model) or a mesh (OBJ model)
      if type(mesh) == "table" and mesh.release then
        pcall(function() mesh:release() end)
      elseif type(mesh) == "userdata" then
        pcall(function() mesh:release() end)
      end
    end
  end
  for _, texture in pairs(textureCache) do
    if texture then
      pcall(function() texture:release() end)
    end
  end
  -- Clear character cache
  for id, cached in pairs(characterCache) do
    if cached and cached.groups then
      for _, group in ipairs(cached.groups) do
        if group.mesh then
          pcall(function() group.mesh:release() end)
        end
        if group.texture then
          pcall(function() group.texture:release() end)
        end
      end
    end
  end
  modelCache = {}
  textureCache = {}
  characterCache = {}
  currentModel = nil
  currentTexture = nil
  currentFilename = nil
  currentRig = nil
  currentStadiumModel = nil
  isStadiumModel = false
  usingColosseum = false
  currentColosseumDex = nil
  usingCharacter = false
  currentCharacterId = nil
  characterGroups = nil
  characterWalkTime = 0
  characterWalkBlend = 0
  characterWalkRig = nil
  characterWalkVertexBuffers = {}
  -- ColosseumMon's actor cache is shared with StadiumFollower/StadiumWilds/
  -- RoamerStadium3D, so this is a full teardown (ROM change, mod unload),
  -- same as StadiumFollower.clearCache -- not something to call per-swap.
  pcall(ColosseumMon.clearCache)
end

return PlayerModel