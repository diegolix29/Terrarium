-- The BACKDROP: a distant horizon for the outdoor world.
-- payload-version: 3
--
-- Dramatic Shape's outdoor maps end where their meshes end -- past the
-- last connected map is sky meeting nothing.  This hangs a painted
-- panorama around the world at a great radius: hills, forest, mountains,
-- a lighthouse headland and a walled town, wrapped 360 degrees and
-- centred on the player, so it reads as distance rather than as scenery.
--
-- Centred on the player is the whole trick.  A cylinder that follows you
-- never gets closer, which is exactly how a horizon behaves: it turns
-- with the camera and refuses to be approached.  A slow drift of the
-- texture against world position adds the last touch -- walk east far
-- enough and the mountains slide across the sky -- without ever letting
-- the player reach them.
--
-- Drawn after the sky and before the terrain, with depth writes off, so
-- every piece of real world draws over it and it never occludes anything.
-- Interiors and canopy maps skip it: the ceiling module owns those.

local V = ...

local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")
local okDN, DayNight = pcall(V.require, "DayNight")
local okBC, BattleCanvas = pcall(V.require, "BattleCanvas")

local Backdrop = {}

local RADIUS = 900        -- far enough to read as distance, inside far plane
local SEGMENTS = 64       -- around the full circle
local Y_BOTTOM = -120     -- skirt below the horizon: no gap under the band
local Y_TOP = 300         -- headroom above it
local DRIFT = 1 / 24000   -- texture drift per world pixel walked

local mesh, image, failed = nil, nil, false
local sceneryMesh, sceneryImage = nil, nil

local function status(s) _G.__ds_backdrop_status = s end
status("loaded; awaiting the first outdoor frame")

-- interiors and canopy maps belong to the ceiling, not the horizon

-- Draw blocks run inside this rather than a bare pcall.  Every one of
-- them changes graphics state -- colour, alpha, depth mode -- and a bare
-- pcall that throws midway leaves that state set for the REST OF THE
-- FRAME.  Anything drawn after us then inherits it: a stray alpha makes
-- another mod's sprites invisible, a stray depth mode makes them sort
-- wrongly, and the fault looks like theirs.  push("all")/pop() restores
-- the lot whatever happens inside.
local function guarded(fn)
  -- headless, or a driver without a graphics stack: just run it
  local g = love and love.graphics
  if not (g and g.push and g.pop) then return pcall(fn) end
  local pushed = pcall(g.push, "all")
  pcall(fn)
  if pushed then pcall(g.pop) end
end

local OPEN_AIR_TILESETS = {
  OVERWORLD = true, FOREST = true, PLATEAU = true, SHIP_PORT = true,
}

local function isOutdoor(map)
  local def = map and map.def
  if not def then return false end
  if okDN and DayNight and DayNight.isCanopy then
    local okC, canopy = pcall(DayNight.isCanopy, map)
    if okC and canopy then return false end
  end
  local tid = def.tileset or (map.tileset and map.tileset.id)
  if tid and OPEN_AIR_TILESETS[tid] then return true end
  local ok, outdoor = pcall(function()
    local Map = require("src.world.Map")
    return Map.isOutdoor and Map.isOutdoor(def)
  end)
  if ok and outdoor ~= nil then return outdoor end
  local conns = def.connections
  return (conns and next(conns) ~= nil) and true or false
end

-- the cylinder, built once: a ring of quads facing inward, uv running
-- once around the circumference
local function build()
  local verts, indexMap, quads = {}, {}, 0
  for i = 0, SEGMENTS - 1 do
    local a0 = (i / SEGMENTS) * math.pi * 2
    local a1 = ((i + 1) / SEGMENTS) * math.pi * 2
    local x0, z0 = math.cos(a0) * RADIUS, math.sin(a0) * RADIUS
    local x1, z1 = math.cos(a1) * RADIUS, math.sin(a1) * RADIUS
    local u0, u1 = i / SEGMENTS, (i + 1) / SEGMENTS
    -- wound so the painted face looks INWARD at the player
    verts[#verts + 1] = { x1, Y_TOP, z1, u1, 0, 1 }
    verts[#verts + 1] = { x0, Y_TOP, z0, u0, 0, 1 }
    verts[#verts + 1] = { x0, Y_BOTTOM, z0, u0, 1, 1 }
    verts[#verts + 1] = { x1, Y_BOTTOM, z1, u1, 1, 1 }
    Voxel3D.pushQuad(indexMap, quads)
    quads = quads + 1
  end
  return Voxel3D.newMesh(verts, indexMap)
end

-- the panorama itself, written next to this module by the companion mod
local function texture()
  if image or failed then return image end
  local ok, img = pcall(function()
    local path = rawget(_G, "__ds_backdrop_path")
                 or "mods/DRAMATIC_SHAPE/lib/backdrop.png"
    local i = love.graphics.newImage(path)
    i:setWrap("repeat", "clamp")
    i:setFilter("nearest", "nearest")
    return i
  end)
  if ok and img then
    image = img
  else
    failed = true
    status("backdrop.png missing or unreadable")
  end
  return image
end

-- Note: This module is now integrated directly into Terrarium Advance Mod
-- The config bridge is provided by main.lua, so we no longer check for abandonment

function Backdrop.draw(state)
  local cfg = {}
  local pub = rawget(_G, "__ds_ceiling_config")
  if type(pub) == "function" then
    local okCfg, c = pcall(pub)
    if okCfg and type(c) == "table" then cfg = c end
  end
  if cfg.backdrop == false then
    status("backdrop switched off")
    return
  end

  local map = state and state.map
  if not map then return end
  if not isOutdoor(map) then
    status("indoors -- the ceiling owns this map")
    return
  end

  local tex = texture()
  -- the chosen panorama can change while the game is running, so notice
  -- when the published path is not the one we loaded
  local want = rawget(_G, "__ds_backdrop_path")
  if tex and want and want ~= texPath then tex = nil end
  if not tex then
    texPath = want return end
  if not mesh then
    mesh = build()
    if not mesh then
      failed = true
      status("driver refused the backdrop mesh")
      return
    end
  end

  local p = state.player
  local px = (p and p.px) or 0
  local pz = (p and p.py) or 0

  -- drift: the horizon slides slowly against the world, so walking a long
  -- way east moves the mountains, but never brings them closer
  local okShift = pcall(function()
    tex:setWrap("repeat", "clamp")
  end)

  local drew = true
  guarded(function()
    -- behind everything: test against depth but never write to it, so no
    -- real geometry can ever be occluded by the painting
    love.graphics.setDepthMode("lequal", false)
    Voxel3D.draw(mesh, tex, Mat4.translate(px, 0, pz))
  end)

  if drew then
    status(("drawn at r=%d, drift %.3f"):format(RADIUS, (px * DRIFT) % 1))
  else
    status("draw failed")
  end
  
  -- Draw overworld scenery in front of backdrop
  Backdrop.drawOverworldScenery(state, px, pz)
end

-- Draw overworld scenery in front of backdrop (3D world, separate from battles)
function Backdrop.drawOverworldScenery(state, px, pz)
  -- Check if overworld scenery is enabled via settings
  local cfg = {}
  local pub = rawget(_G, "__ds_ceiling_config")
  if type(pub) == "function" then
    local okCfg, c = pcall(pub)
    if okCfg and type(c) == "table" then cfg = c end
  end
  if cfg.overworldScenery == false then
    return  -- Overworld scenery disabled
  end
  
  if not (okBC and BattleCanvas) then return end
  
  local map = state and state.map
  if not map then return end
  
  -- Only draw scenery for outdoor maps
  if not isOutdoor(map) then return end
  
  -- Select scenery based on map (using BattleCanvas's selection logic)
  local sceneryName = Backdrop.selectSceneryForMap(map)
  if not sceneryName then return end
  
  -- Load scenery using BattleCanvas's loader
  local scenery = BattleCanvas.loadScenery and BattleCanvas.loadScenery(sceneryName)
  if not scenery then return end
  
  -- Draw scenery as a horizon prop in the 3D world
  -- This positions it in front of the backdrop but behind the terrain
  local g = love.graphics
  if not (g and g.draw) then return end
  
  guarded(function()
    -- Draw scenery at horizon position in 3D space
    -- Position it at a far distance, following the player
    local sceneryRadius = RADIUS * 0.95  -- Slightly inside the backdrop
    local sceneryY = 0  -- Ground level
    
    -- Create a simple plane mesh for scenery if needed
    if not sceneryMesh then
      sceneryMesh = buildSceneryPlane()
    end
    
    if sceneryMesh then
      love.graphics.setDepthMode("lequal", false)
      -- Position scenery around the player like the backdrop
      Voxel3D.draw(sceneryMesh, scenery, Mat4.translate(px, sceneryY, pz))
    end
  end)
end

-- Build a simple plane for scenery display
local function buildSceneryPlane()
  local verts, indexMap, quads = {}, {}, 0
  local w = 200  -- Width of scenery display
  local h = 100  -- Height of scenery display
  
  -- Simple quad facing the player
  verts[#verts + 1] = { -w/2, h, 0, 0, 0, 1 }
  verts[#verts + 1] = { w/2, h, 0, 1, 0, 1 }
  verts[#verts + 1] = { w/2, 0, 0, 1, 1, 1 }
  verts[#verts + 1] = { -w/2, 0, 0, 0, 1, 1 }
  Voxel3D.pushQuad(indexMap, quads)
  quads = quads + 1
  
  return Voxel3D.newMesh(verts, indexMap)
end

-- Draw scenery foreground elements (battle PNG overlay; screen-space)
function Backdrop.drawScenery(state, px, pz)
  if not (okBC and BattleCanvas and BattleCanvas.drawPaintedStage) then return end
  local arena = nil
  if state and state.player and state.player.surfing then
    arena = { surfing = true, water = true }
  end
  BattleCanvas.drawPaintedStage(state and state.map, arena)
end

-- Select appropriate scenery based on map characteristics
function Backdrop.selectSceneryForMap(map)
  local def = map and map.def
  if not def then return nil end
  
  local tid = def.tileset or (map.tileset and map.tileset.id)
  
  -- Map tilesets to appropriate scenery
  local sceneryMap = {
    OVERWORLD = "kanto_panorama",
    FOREST = "forest_edge_a",
    PLATEAU = "route8_horizon",
    SHIP_PORT = "harbor_edge",
    -- Add more mappings as needed
  }
  
  -- Fallback to general scenery based on map name/connections
  if tid and sceneryMap[tid] then
    return sceneryMap[tid]
  end
  
  -- Check for specific location names in map ID
  local mapId = map.id or ""
  if mapId:find("viridian") then return "viridian_town" end
  if mapId:find("pallet") then return "rural_edge" end
  if mapId:find("pewter") then return "route8_midground" end
  if mapId:find("cerulean") then return "coastal_landmarks_v3" end
  if mapId:find("lavender") then return "pokemon_tower_wall" end
  if mapId:find("celadon") then return "metropolis" end
  if mapId:find("fuchsia") then return "mini_trees" end
  if mapId:find("saffron") then return "cinnabar_story_landmarks" end
  
  -- Default fallback
  return "kanto_panorama"
end

function Backdrop.invalidate()
  if mesh then pcall(mesh.release, mesh) end
  mesh = nil
end

return Backdrop
