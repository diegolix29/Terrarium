-- FOLLOWER MODEL RENDER: swap a follower NPC's 2D sprite for a static
-- .glb model, reusing the same Voxel3D draw path PlayerModel.lua uses for
-- the player. This does NOT touch engines/src/world/NPC.lua on disk --
-- it monkey-patches NPC:draw at runtime, the same way the rest of this
-- mod layers behavior onto the base engine (see BattleCache's
-- mod.hooks:wrap, Compatibility's restorePokePcIfPresent, etc).
--
-- Usage (e.g. from the dev console, src/dev/Console.lua, which eval's
-- arbitrary Lua against a live game -- no extra command wiring needed):
--
--   local ModelRender = V.require("model_render")
--   ModelRender.attach(followerNpc, "follower_models/test_quad.glb")
--   ...
--   ModelRender.detach(followerNpc)  -- back to the normal sprite
--
-- A follower model is a STATIC mesh (see GLBModel's own scope note) --
-- animated followers still go through the sprite walk-cycle path.

local V = ...
local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")
local GLBModel = V.require("GLBModel")
local DebugLog = V.require("debug_log")

local ModelRender = {}

ModelRender.DIR = "follower_models"

-- Configuration for automatic GLB loading
-- Set this to your GLB filename to auto-load on game start
ModelRender.autoLoadFile = "test.glb"  -- Change this to your GLB filename
ModelRender.autoLoadScale = 4.0 -- Default scale for auto-loaded models

local meshCache = {}   -- filename -> mesh (or false on a load that failed, so we don't retry every frame)
local textureCache = {} -- filename -> texture

local patched = false
local originalDraw = nil

local function fs()
  return love and love.filesystem
end

-- Load (and cache) a .glb by filename under ModelRender.DIR. Returns
-- mesh, texture on success, or nil, err on failure.
local function loadGLB(filename)
  if meshCache[filename] ~= nil then
    if meshCache[filename] == false then
      return nil, "cached failure"
    end
    return meshCache[filename], textureCache[filename]
  end

  local f = fs()
  if not (f and f.read) then return nil, "no filesystem" end

  local path = ModelRender.DIR .. "/" .. filename
  local ok, data = pcall(f.read, path)
  if not ok or not data then
    meshCache[filename] = false
    return nil, "could not read " .. path
  end

  local mesh, texture, err, stats = GLBModel.load(data, Voxel3D)
  if stats then
    DebugLog.info(nil, "[FollowerModel] %s: vertices=%s triangles=%s hasTexCoords=%s",
      filename, tostring(stats.vertexCount), tostring(stats.triangleCount), tostring(stats.hasTexCoords))
  end
  if not mesh then
    DebugLog.warn(nil, "[FollowerModel] failed to load %s: %s", filename, tostring(err))
    meshCache[filename] = false
    return nil, err
  end

  meshCache[filename] = mesh
  textureCache[filename] = texture
  return mesh, texture
end

-- Model-space -> world transform, same convention PlayerModel.draw uses:
-- centered over the entity's tile, facing rotated to match movement dir.
local function modelMatrix(npc)
  local px = npc.px or 0
  local py = npc.py or 0
  local m = Mat4.translate(px + 8, 0, py + 8)

  local yaw = 0
  local facing = npc.facing
  if facing == "right" then yaw = math.pi / 2
  elseif facing == "up" then yaw = math.pi
  elseif facing == "left" then yaw = -math.pi / 2
  end
  if yaw ~= 0 then
    m = Mat4.mul(m, Mat4.rotateY(yaw))
  end

  local scale = (npc.model3d and npc.model3d.scale) or 4.0
  m = Mat4.mul(m, Mat4.scale(scale, scale, scale))
  return m
end

-- Monkey-patch NPC:draw once, globally: any npc with a `model3d` field
-- draws its mesh through Voxel3D instead of the normal sprite path.
-- Every other NPC (the overwhelming majority: no model3d set) falls
-- straight through to the original sprite draw, untouched.
local function installPatch()
  if patched then return true end
  local ok, NPC = pcall(require, "src.world.NPC")
  if not (ok and NPC and NPC.draw) then
    return false, "src.world.NPC not available"
  end
  originalDraw = NPC.draw
  NPC.draw = function(self, camX, camY)
    if self.model3d and self.model3d.mesh then
      local drawn = pcall(Voxel3D.draw, self.model3d.mesh, self.model3d.texture, modelMatrix(self))
      if drawn then return end
      -- Draw failed (e.g. Voxel3D pass not active this frame) -- fall
      -- back to the sprite so the follower never just vanishes.
    end
    return originalDraw(self, camX, camY)
  end
  patched = true
  return true
end

-- Attach a .glb model to a follower NPC, replacing its sprite draw.
-- filename is relative to ModelRender.DIR ("follower_models/").
function ModelRender.attach(npc, filename, opts)
  if not npc then return false, "no npc" end
  local okPatch, patchErr = installPatch()
  if not okPatch then return false, patchErr end

  local mesh, texture = loadGLB(filename)
  if not mesh then return false, texture end -- texture holds the err string here

  npc.model3d = {
    mesh = mesh,
    texture = texture,
    filename = filename,
    scale = opts and opts.scale,
  }
  return true
end

-- Detach: the NPC goes back to drawing its normal sprite next frame.
function ModelRender.detach(npc)
  if npc then npc.model3d = nil end
end

-- Exposed for tests / diagnostics.
ModelRender._loadGLB = loadGLB
ModelRender._modelMatrix = modelMatrix

-- Auto-install function: automatically loads GLB model for follower on init
function ModelRender.installAutoLoad(filename, scale)
  ModelRender.autoLoadFile = filename
  ModelRender.autoLoadScale = scale or 4.0
  return true
end

-- Internal function to apply auto-load when follower is available
function ModelRender.applyAutoLoad()
  if not ModelRender.autoLoadFile then return end
  
  -- Try to access the follower system
  local ok, Follower = pcall(V.require, "follower/init")
  if not (ok and Follower) then return end
  
  -- Try to get the global follower instance
  local followerInstance = V._followerInstance
  if not followerInstance then return end
  
  -- Try to get the current follower's render object
  local render = followerInstance.render
  if not render then return end
  
  -- Load the GLB model
  local mesh, texture = loadGLB(ModelRender.autoLoadFile)
  if not mesh then return end
  
  -- Store the original sprite for restoration
  if not render._originalSprite then
    render._originalSprite = render.sprite
  end
  
  -- Replace the sprite with our GLB model
  render.sprite = nil
  render.model3d = {
    mesh = mesh,
    texture = texture,
    filename = ModelRender.autoLoadFile,
    scale = ModelRender.autoLoadScale,
    isFollowerModel = true
  }
  
  -- Hook into the draw function to render our GLB model
  if not render._originalDraw then
    render._originalDraw = render.draw
    render.draw = function(self, camX, camY)
      if self.model3d and self.model3d.mesh then
        -- Calculate position based on follower state
        local px = self.px or 0
        local py = self.py or 0
        local m = Mat4.translate(px + 8, 0, py + 8)
        
        -- Apply rotation based on facing
        local yaw = 0
        local facing = self.facing or "down"
        if facing == "right" then yaw = math.pi / 2
        elseif facing == "up" then yaw = math.pi
        elseif facing == "left" then yaw = -math.pi / 2
        end
        if yaw ~= 0 then
          m = Mat4.mul(m, Mat4.rotateY(yaw))
        end
        
        -- Apply scale
        local scale = self.model3d.scale or 4.0
        m = Mat4.mul(m, Mat4.scale(scale, scale, scale))
        
        -- Draw the GLB model
        local drawn = pcall(Voxel3D.draw, self.model3d.mesh, self.model3d.texture, m)
        if drawn then return end
      end
      
      -- Fall back to original draw if GLB rendering fails
      if self._originalDraw then
        return self._originalDraw(self, camX, camY)
      end
    end
  end
  
  DebugLog.info(nil, "[ModelRender] Auto-loaded GLB model: %s", ModelRender.autoLoadFile)
end

-- Helper for console testing: find and attach to the first follower NPC
function ModelRender.attachToFollower(filename, opts)
  local ok, NPC = pcall(require, "src.world.NPC")
  if not (ok and NPC) then return false, "NPC module not available" end
  
  -- Find NPCs that might be followers (have movement patterns or are in overworld)
  local followers = {}
  for _, npc in pairs(NPC.list or {}) do
    if npc and (npc.movement or npc.script or npc.isFollower) then
      table.insert(followers, npc)
    end
  end
  
  if #followers == 0 then return false, "no follower NPCs found" end
  
  -- Attach to the first found follower
  local npc = followers[1]
  local success, err = ModelRender.attach(npc, filename, opts)
  if success then
    return true, "Attached to NPC at " .. (npc.px or 0) .. "," .. (npc.py or 0)
  else
    return false, err
  end
end

-- Replace the first follower Pokemon sprite with a GLB model
-- This specifically targets the follower Pokemon system
function ModelRender.replaceFollowerPokemon(filename, opts)
  opts = opts or {}
  
  -- Try to access the follower system
  local ok, Follower = pcall(V.require, "follower/init")
  if not (ok and Follower) then
    return false, "follower system not available"
  end
  
  -- Try to get the global follower instance (if it exists)
  local followerInstance = V._followerInstance
  if not followerInstance then
    return false, "no active follower instance found - wait for game to fully load"
  end
  
  -- Try to get the current follower's render/entity object
  local render = followerInstance.render
  if not render then
    return false, "follower has no render object"
  end
  
  -- Load the GLB model
  local mesh, texture = loadGLB(filename)
  if not mesh then
    return false, "failed to load GLB: " .. tostring(texture)
  end
  
  -- Store the original sprite for restoration
  if not render._originalSprite then
    render._originalSprite = render.sprite
  end
  
  -- Replace the sprite with our GLB model
  render.sprite = nil  -- Disable sprite rendering
  render.model3d = {
    mesh = mesh,
    texture = texture,
    filename = filename,
    scale = opts.scale or 4.0,
    isFollowerModel = true
  }
  
  -- Hook into the draw function to render our GLB model
  if not render._originalDraw then
    render._originalDraw = render.draw
    render.draw = function(self, camX, camY)
      if self.model3d and self.model3d.mesh then
        -- Calculate position based on follower state
        local px = self.px or 0
        local py = self.py or 0
        local m = Mat4.translate(px + 8, 0, py + 8)
        
        -- Apply rotation based on facing
        local yaw = 0
        local facing = self.facing or "down"
        if facing == "right" then yaw = math.pi / 2
        elseif facing == "up" then yaw = math.pi
        elseif facing == "left" then yaw = -math.pi / 2
        end
        if yaw ~= 0 then
          m = Mat4.mul(m, Mat4.rotateY(yaw))
        end
        
        -- Apply scale
        local scale = self.model3d.scale or 4.0
        m = Mat4.mul(m, Mat4.scale(scale, scale, scale))
        
        -- Draw the GLB model
        local drawn = pcall(Voxel3D.draw, self.model3d.mesh, self.model3d.texture, m)
        if drawn then return end
      end
      
      -- Fall back to original draw if GLB rendering fails
      if self._originalDraw then
        return self._originalDraw(self, camX, camY)
      end
    end
  end
  
  return true, "Replaced follower Pokemon with GLB model: " .. filename
end

-- Restore the original follower Pokemon sprite
function ModelRender.restoreFollowerPokemon()
  local ok, Follower = pcall(V.require, "follower/init")
  if not (ok and Follower) then return false, "follower system not available" end
  
  local followerInstance = V._followerInstance
  if not followerInstance then return false, "no active follower instance" end
  
  local render = followerInstance.render
  if not render then return false, "follower has no render object" end
  
  -- Restore original sprite
  if render._originalSprite then
    render.sprite = render._originalSprite
  end
  
  -- Restore original draw function
  if render._originalDraw then
    render.draw = render._originalDraw
  end
  
  -- Clear GLB model
  render.model3d = nil
  
  return true, "Restored original follower Pokemon sprite"
end

-- List all NPCs for debugging
function ModelRender.listNPCs()
  local ok, NPC = pcall(require, "src.world.NPC")
  if not (ok and NPC) then return false, "NPC module not available" end
  
  local list = {}
  for id, npc in pairs(NPC.list or {}) do
    if npc then
      table.insert(list, {
        id = id,
        x = npc.px or 0,
        y = npc.py or 0,
        facing = npc.facing or "unknown",
        hasModel3d = npc.model3d ~= nil
      })
    end
  end
  return list
end

return ModelRender
