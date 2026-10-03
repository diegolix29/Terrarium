-- Terrarium effects on Platinum's own 3D world.
--
-- Gen 1-3 voxelize tilesets into a diorama. Gen 4 already IS a 3D world:
-- NSBMD chunks, BDHC height, and Gen4View / Gen4Camera. Replacing that
-- pass with VoxelScene would throw the cartridge's meshes away. This module
-- therefore never owns the world: it declines the drawWorld pipeline so
-- Gen4Ground keeps the frame, then paints Terrarium grass / wind / weather
-- / VFX into the engine's live colour+depth target using that camera.
--
-- Glass panes on Sinnoh houses are already in the NSBMD textures. The
-- tileset GlassMask scan is for 8px GB art and is not run here.

local V = ...

local Host = {
  installed = false,
}

local GRASS_BEHAVIOURS = {
  TALL_GRASS = true,
  VERY_TALL_GRASS = true,
  MUD_WITH_GRASS = true,
  MUD_DEEP_WITH_GRASS = true,
}

local grassCache = { mapId = nil, mesh = nil, at = -1 }

local function engineRequire(name)
  local req = (V and V.engineRequire) or require
  local ok, mod = pcall(req, name)
  return ok and mod or nil
end

local function game()
  return engineRequire("src.core.Game")
end

function Host.generation()
  local GameVersion = engineRequire("src.core.GameVersion")
  if GameVersion and type(GameVersion.generation) == "function" then
    local ok, n = pcall(GameVersion.generation)
    if ok and tonumber(n) then return tonumber(n) end
  end
  return nil
end

function Host.isGen4()
  if Host.generation() == 4 then return true end
  local g = game()
  local data = g and g.data
  return data and data.gen4_terrain ~= nil
end

function Host.groundOf(state)
  state = state or (game() and game().overworld)
  local map = state and state.map
  local renderer = map and map.renderer
  return renderer and renderer.gen4Ground or nil
end

function Host.isState(state)
  return Host.groundOf(state) ~= nil
end

function Host.isMap(map)
  return map and map.renderer and map.renderer.gen4Ground ~= nil
end

-- Permission / behaviour byte for a 16px cell. Gen 4 stores that in
-- def.blocks (255 is the reserved blocked cell, not a behaviour).
function Host.behaviourAt(map, cx, cy)
  if not (map and map.def) then return nil end
  local def = map.def
  local w = tonumber(def.width) or 0
  local h = tonumber(def.height) or 0
  cx, cy = tonumber(cx), tonumber(cy)
  if not (cx and cy and w > 0) then return nil end
  if cx < 0 or cy < 0 or cx >= w or cy >= h then return nil end
  if def.blocks then
    local v = def.blocks[cy * w + cx + 1]
    if v == nil or v == 255 then return nil end
    return v
  end
  if type(map.cellBehaviour) == "function" then
    local ok, b = pcall(map.cellBehaviour, map, cx, cy)
    if ok then return b end
  end
  return nil
end

function Host.behaviourName(value)
  local Gen4Behaviors = engineRequire("src.import.Gen4Behaviors")
  if Gen4Behaviors and type(Gen4Behaviors.name) == "function" then
    local ok, name = pcall(Gen4Behaviors.name, value)
    if ok then return name end
  end
  return nil
end

function Host.isTallGrass(map, cx, cy)
  local name = Host.behaviourName(Host.behaviourAt(map, cx, cy))
  return name and GRASS_BEHAVIOURS[name] == true
end

-- World-pixel project through the camera that actually drew this frame.
-- Matches Voxel3D.project's (sx, sy, scale) contract so WindFX / Weather /
-- AmbientLife / Vfx can run unchanged.
function Host.project(wx, wy, wz)
  local ground = Host._drawGround
  if not ground then return nil end
  wy = tonumber(wy) or 0
  wx, wz = tonumber(wx) or 0, tonumber(wz) or 0
  local view = ground.view3d
  if view and view.isFree and view:isFree() and type(view.project) == "function" then
    local vw = ground.freeW or Host._vw or 1
    local vh = ground.freeH or Host._vh or 1
    local sx, sy, scale = view:project(
      wx + (ground.offsetX or 0), wy, wz + (ground.offsetY or 0), vw, vh)
    return sx, sy, scale
  end
  local Gen4Camera = engineRequire("src.render.Gen4Camera")
  if not (Gen4Camera and Gen4Camera.project) then return nil end
  local cam = ground.camera or Gen4Camera.forMap(ground.def)
  local ow = game() and game().overworld
  local c = ow and ow.camera
  local camX = (c and c.x or 0) + (ground.offsetX or 0)
  local camY = (c and c.y or 0) + (ground.offsetY or 0)
  local dx = wx + (ground.offsetX or 0) - camX
  local dz = wz + (ground.offsetY or 0) - camY
  local sx, sy = Gen4Camera.project(cam, dx, wy, dz)
  return sx, sy, 1
end

local function bindVoxelCamera(ground)
  local Voxel3D = V.require("Voxel3D")
  local view = ground.view3d
  if not (view and view.isFree and view:isFree()) then
    Voxel3D.camera = nil
    return false
  end
  local fx, fy, fz = 0, 0, -1
  if type(view.forward) == "function" then
    fx, fy, fz = view:forward()
  end
  local fov = tonumber(view.fovY) or 50
  if type(view.effectiveFovY) == "function" then
    fov = view:effectiveFovY(ground.freeH or 192) or fov
  end
  Voxel3D.camera = {
    eye = { view.x, view.y, view.z },
    focus = { view.x + fx, view.y + fy, view.z + fz },
    fov = math.rad(fov),
  }
  Voxel3D.eye = Voxel3D.camera.eye
  Voxel3D.focus = Voxel3D.camera.focus
  local vw = ground.freeW or 1
  local vh = ground.freeH or 1
  Voxel3D.vp = view:matrix(vw, vh)
  return true
end

local function rebuildGrass(state, ground)
  local map = state and state.map
  if not map then return nil end
  local Grass3D = V.require("Grass3D")
  if not (Grass3D and Grass3D.available and Grass3D.available()) then
    grassCache.mesh = nil
    return nil
  end
  local player = state.player
  local now = love and love.timer and love.timer.getTime() or 0
  local cx = player and math.floor((player.px or 0) / 16) or 0
  local cy = player and math.floor((player.py or 0) / 16) or 0
  local key = (map.id or "") .. ":" .. cx .. ":" .. cy
  if grassCache.mapId == key and grassCache.mesh and (now - (grassCache.at or 0)) < 0.35 then
    return grassCache.mesh
  end
  local instances = {}
  local radius = 12
  local x0 = math.max(0, cx - radius)
  local y0 = math.max(0, cy - radius)
  local x1 = math.min((map.widthCells or map.def.width or 0) - 1, cx + radius)
  local y1 = math.min((map.heightCells or map.def.height or 0) - 1, cy + radius)
  for ty = y0, y1 do
    for tx = x0, x1 do
      if Host.isTallGrass(map, tx, ty) then
        local gz = 0
        if ground.groundY then
          gz = ground:groundY(tx * 16 + 8, ty * 16 + 8) or 0
        end
        local inst = Grass3D.instanceForTile(tx * 2, ty * 2, gz)
        inst.wx = tx * 16
        inst.wz = ty * 16
        inst.gz = gz
        instances[#instances + 1] = inst
      end
    end
  end
  local mesh = nil
  if #instances > 0 then
    mesh = Grass3D.meshFromInstances(instances)
  end
  grassCache.mapId, grassCache.mesh, grassCache.at = key, mesh, now
  return mesh
end

local function drawGrass(state, ground)
  local mesh = rebuildGrass(state, ground)
  if not mesh then return end
  local Voxel3D = V.require("Voxel3D")
  if not bindVoxelCamera(ground) then return end
  local view = ground.view3d
  local vw = ground.freeW or Host._vw or 1
  local vh = ground.freeH or Host._vh or 1
  local player = state and state.player
  local cx = (player and player.px or 0) + 8 + (ground.offsetX or 0)
  local cz = (player and player.py or 0) + 8 + (ground.offsetY or 0)
  local Wind = V.require("Wind")
  local sway = (Wind.amount and Wind.amount()) or 0
  local Grass3D = V.require("Grass3D")
  if Grass3D and Grass3D.meta then
    local okm, m = pcall(Grass3D.meta)
    if okm and m and tonumber(m.height) then Voxel3D.grassH = m.height end
  end
  pcall(function()
    if not Voxel3D.beginScene(vw, vh, cx, cz, vw, vh, nil, "current") then
      return
    end
    -- beginScene rebuilds vp from Voxel3D.camera. Restore Gen4View's matrix
    -- so tufts sit in the same space as the NSBMD chunks already in this
    -- framebuffer.
    if view and type(view.matrix) == "function" then
      Voxel3D.vp = view:matrix(vw, vh)
    end
    Voxel3D.draw(mesh, Grass3D.texture and Grass3D.texture() or nil,
                 nil, 0, nil, sway)
    Voxel3D.endScene()
  end)
end

-- Cartridge / oblique field camera: no Gen4View matrix, so stamp tufts as
-- projected billboards on the world canvas after sprites.
local function drawGrassBillboards(state, ground, project)
  if not (state and state.map and project) then return end
  local Grass3D = V.require("Grass3D")
  local tex = Grass3D and Grass3D.texture and Grass3D.texture() or nil
  if not tex then return end
  local g = love.graphics
  local player = state.player
  local cx = player and math.floor((player.px or 0) / 16) or 0
  local cy = player and math.floor((player.py or 0) / 16) or 0
  local radius = 8
  local map = state.map
  local x0 = math.max(0, cx - radius)
  local y0 = math.max(0, cy - radius)
  local x1 = math.min((map.widthCells or map.def.width or 0) - 1, cx + radius)
  local y1 = math.min((map.heightCells or map.def.height or 0) - 1, cy + radius)
  g.setColor(1, 1, 1, 1)
  for ty = y0, y1 do
    for tx = x0, x1 do
      if Host.isTallGrass(map, tx, ty) then
        local gz = ground.groundY and ground:groundY(tx * 16 + 8, ty * 16 + 8) or 0
        local sx, sy, ps = project(tx * 16 + 8, gz + 8, ty * 16 + 8)
        if sx then
          local s = math.max(8, 16 * (ps or 1))
          g.draw(tex, sx, sy, 0, s / tex:getWidth(), s / tex:getHeight(),
                 tex:getWidth() * 0.5, tex:getHeight())
        end
      end
    end
  end
end

-- 2D field FX through Host.project. Called while the gen4 colour target is
-- still bound (free pass) or after sprites on the world canvas (field).
function Host.overlayFx(state, ground, sw, sh, scale)
  if not Host.effectsOn() then return end
  Host._drawGround = ground
  Host._vw, Host._vh = sw, sh
  local Voxel3D = V.require("Voxel3D")
  local prevVp = Voxel3D.vp
  -- Weather / WindFX / AmbientLife call Voxel3D.project when given that
  -- function. Hand Host.project so the engine camera is the only lens.
  local project = Host.project
  local view = ground.view3d
  local free = view and view.isFree and view:isFree()
  if not free then
    pcall(drawGrassBillboards, state, ground, project)
  end
  pcall(function() V.require("AmbientLife").draw(project, scale or 1) end)
  pcall(function() V.require("Vfx").draw(project, scale or 1) end)
  pcall(function() V.require("WindFX").draw(project, scale or 1) end)
  pcall(function() V.require("Interiors").draw(project, scale or 1) end)
  pcall(function() V.require("HiddenItems").draw(project, scale or 1) end)
  pcall(function()
    V.require("Weather").draw(project, scale or 1, sw, sh)
  end)
  Voxel3D.vp = prevVp
  Host._drawGround = nil
end

function Host.effectsOn()
  local ok, Voxel = pcall(V.require, "VoxelState")
  return ok and Voxel and Voxel.active and Voxel.active() == true
end

-- Called from the voxel pipeline's drawWorld when this is a Gen 4 map.
-- The pipeline returns nil so Gen4Ground keeps the frame; this only
-- installs the overlay wraps and remembers the view size.
function Host.noteFrame(ctx)
  pcall(Host.install)
  if ctx then
    Host._vw = tonumber(ctx.vw) or Host._vw
    Host._vh = tonumber(ctx.vh) or Host._vh
  end
end

local function spriteKey(mapX, mapY)
  return string.format("%d:%d", math.floor((mapX or 0) + 0.5),
                       math.floor((mapY or 0) + 0.5))
end

local function wantFieldActor(e, state)
  if not e or e.hidden then return false end
  if e.isFollower or e.wildsFollower or e._wildsFollowerSpecies then
    return true
  end
  if e.roamer or e.overworldWildSpawn or e.species then return true end
  local def = e.sprite and e.sprite.def
  if def and (def.hdDex or def.dsSpecies) then return true end
  local okHd, Hd = pcall(V.require, "Gen4HdPokemon")
  if okHd and Hd and Hd.wantsEntity and Hd.wantsEntity(e, state) then
    return true
  end
  local okTag, OC = pcall(V.require, "OverworldColosseum")
  if okTag and OC and type(OC.getTaggedDex) == "function" then
    local dex = OC.getTaggedDex(e)
    if dex then return true end
  end
  if e.model3d and e.model3d.mesh then return true end
  if state and e == state.player then
    local ok, PM = pcall(V.require, "PlayerModel")
    if ok and PM and PM.loaded and PM.loaded() then return true end
  end
  return false
end

local function beginFieldVoxel(state, ground)
  local Voxel3D = V.require("Voxel3D")
  if not bindVoxelCamera(ground) then return false end
  local view = ground.view3d
  local vw = ground.freeW or Host._vw or 1
  local vh = ground.freeH or Host._vh or 1
  local player = state and state.player
  local cx = (player and player.px or 0) + 8 + (ground.offsetX or 0)
  local cz = (player and player.py or 0) + 8 + (ground.offsetY or 0)
  if not Voxel3D.beginScene(vw, vh, cx, cz, vw, vh, nil, "current") then
    return false
  end
  if view and type(view.matrix) == "function" then
    Voxel3D.vp = view:matrix(vw, vh)
  end
  Voxel3D.eye = Voxel3D.camera and Voxel3D.camera.eye or Voxel3D.eye
  local sh = love.graphics.getShader()
  if sh then
    pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
    pcall(sh.send, sh, "eye", Voxel3D.eye)
  end
  return true
end

-- Colosseum / Stadium / GLB followers into the same framebuffer as the
-- NSBMD chunks. VoxelScene never runs on Platinum (drawWorld declines),
-- so these actors used to keep voxel y=0 and sit in the mesh.
local function drawFieldActors(state, ground)
  Host._skipFeet = {}
  Host._drew3d = {}
  if not (state and ground) then return end
  local view = ground.view3d
  if not (view and view.isFree and view:isFree()) then return end
  local Voxel3D = V.require("Voxel3D")
  local ox = ground.offsetX or 0
  local oz = ground.offsetY or 0
  local posed = {}
  local function add(e, mapX, mapY)
    if not wantFieldActor(e, state) then return end
    if ground.freeMode and ground:freeMode() == "first" and e == state.player then
      return
    end
    local gh = 0
    if ground.groundY then
      gh = ground:groundY((mapX or 0) + 8, (mapY or 0) + 8) or 0
    end
    -- World compass facing, not view:worldToScreen. That remap is for 2D
    -- sprite frames under an orbited camera; feeding it to a mesh rotateY
    -- locks the model on south (the cartridge's default look).
    local facing = e.facing or "down"
    posed[#posed + 1] = {
      sprite = e.sprite,
      px = (mapX or 0) + ox,
      py = (mapY or 0) + oz,
      facing = facing,
      phase = e.phase,
      flip = e.flip,
      gh = gh,
      lift = 0,
      entity = e,
      skipKey = spriteKey(mapX, mapY),
      isFollower = e.isFollower or e.wildsFollower or e._wildsFollowerSpecies ~= nil,
      isPlayer = e == state.player,
    }
  end
  for _, e in ipairs(state.entities or {}) do
    add(e, e.px, e.py)
  end
  for _, g in ipairs(state.ghosts or {}) do
    local npc = g and g.npc
    if npc then
      add(npc, (npc.px or 0) + (g.ox or 0), (npc.py or 0) + (g.oy or 0))
    end
  end
  if #posed == 0 then return end
  pcall(function()
    local OC = V.require("OverworldColosseum")
    if OC and OC.safePrepare then OC.safePrepare(posed) end
  end)
  pcall(function()
    local OS = V.require("OverworldStadium")
    if OS and OS.safePrepare then OS.safePrepare(posed) end
  end)
  if not beginFieldVoxel(state, ground) then return end
  pcall(function()
    local OC = V.require("OverworldColosseum")
    local OS = V.require("OverworldStadium")
    local SF = V.require("StadiumFollower")
    local PM = V.require("PlayerModel")
    local Hd = V.require("Gen4HdPokemon")
    local Mat4 = V.require("Mat4")
    for _, p in ipairs(posed) do
      local drew = false
      if p.isPlayer and PM and PM.loaded and PM.loaded() then
        drew = pcall(PM.draw, p.px, p.py, p.gh, p.facing, p.flip) and true or drew
      end
      if not drew and OC and OC.safeDraw then
        drew = OC.safeDraw(p) == true
      end
      if not drew and OS and OS.safeDraw then
        drew = OS.safeDraw(p) == true
      end
      local stadiumFollower3d = p.isFollower and SF and SF.loaded and SF.loaded()
        and not (SF.isUsingSpriteFallback and SF.isUsingSpriteFallback())
      if not drew and stadiumFollower3d then
        if SF.update then pcall(SF.update, 1 / 60) end
        drew = SF.draw(p.px, p.py, p.facing, p.gh) == true
      end
      local mdl = p.entity and p.entity.model3d
      if not drew and mdl and mdl.mesh then
        local m = Mat4.translate((p.px or 0) + 8, p.gh or 0, (p.py or 0) + 8)
        local Cam = V.require("Gen4ActorCam")
        local yaw = Cam and Cam.worldYaw(p.facing) or 0
        if yaw ~= 0 then m = Mat4.mul(m, Mat4.rotateY(yaw)) end
        local scale = mdl.scale or 4.0
        m = Mat4.mul(m, Mat4.scale(scale, scale, scale))
        drew = pcall(Voxel3D.draw, mdl.mesh, mdl.texture, m)
      end
      if drew then
        Host._drew3d[p.skipKey] = true
      elseif Hd and Hd.drawPose then
        local okHd, okDraw = pcall(Hd.drawPose, p, ground)
        drew = okHd and okDraw == true
      end
      if drew then Host._skipFeet[p.skipKey] = true end
    end
  end)
  Voxel3D.endScene()
end

-- 3D grass into the still-bound gen4 target, before characters (depth test
-- against houses). Followers use the same pass so they stand on BDHC height
-- instead of voxel y=0. Wind/weather wait for endFree, after sprites.
function Host.overlay3D(ground)
  local ow = game() and game().overworld
  if not (ground and ow) then return end
  Host._drawGround = ground
  if Host.effectsOn() then
    pcall(drawGrass, ow, ground)
  end
  pcall(drawFieldActors, ow, ground)
  Host._drawGround = nil
end


-- Battle: draw Sinnoh from the staged BattleCam, then let Stadium /
-- Colosseum actors paint into the same framebuffer via Voxel3D "current".
function Host.renderBattle(state, arena, textures, token)
  local ground = Host.groundOf(state) or Host.groundOf(state and { map = arena.map })
  if arena and arena.map and arena.map.renderer and arena.map.renderer.gen4Ground then
    ground = arena.map.renderer.gen4Ground
  end
  if not ground then return nil end
  if arena and arena.discs and not arena.showTerrain then return nil end

  local BattleScene = V.require("BattleScene")
  local BattleCam = V.require("BattleCam")
  local Voxel3D = V.require("Voxel3D")
  local lx, ly, s, pw, ph = BattleScene.letterbox()
  if not (pw and ph and pw > 0 and ph > 0) then return nil end

  local hostMap = (arena and arena.map) or (state and state.map)
  local ox = ground.offsetX or 0
  local oz = ground.offsetY or 0
  local groundY = 0
  if ground.groundY and arena and arena.mid then
    groundY = ground:groundY(arena.mid[1], arena.mid[2]) or 0
  elseif BattleScene.groundY then
    groundY = BattleScene.groundY(hostMap, arena) or 0
  end

  -- The telephoto rig stands five tiles back, which on a Sinnoh interior
  -- is through a wall. Wide is the same composition at a distance the room
  -- can actually hold.
  if arena and arena.cam == nil then arena.cam = "wide" end

  local cam = nil
  if BattleCam and BattleCam.rig then
    cam = select(1, BattleCam.rig(arena, groundY))
  end
  if not (cam and cam.eye and cam.focus) then return nil end
  cam.fov = BattleScene.letterboxFov(cam.fov, ph, s)

  -- Gen4View / NSBMD chunks live in origin-offset world units. BattleCam
  -- and Stadium cells are map-local. One space for the lens and the actors.
  local worldCam = {
    eye = { cam.eye[1] + ox, cam.eye[2] + 18, cam.eye[3] + oz },
    focus = { cam.focus[1] + ox, cam.focus[2], cam.focus[3] + oz },
    fov = cam.fov,
    curve = 0,
  }

  local Gen4View = engineRequire("src.render.Gen4View")
  if not Gen4View then return nil end
  local view = ground.view3d
  if not view then
    view = Gen4View.new("third")
    ground.view3d = view
  end
  local savedMode = view.mode
  -- field3d derives fov from the cartridge camera distance, which is not
  -- this fight's lens. Third-person uses view.fovY as-is.
  view.mode = "third"
  view.x, view.y, view.z = worldCam.eye[1], worldCam.eye[2], worldCam.eye[3]
  local dx = worldCam.focus[1] - worldCam.eye[1]
  local dy = worldCam.focus[2] - worldCam.eye[2]
  local dz = worldCam.focus[3] - worldCam.eye[3]
  local flat = math.sqrt(dx * dx + dz * dz)
  view.yaw = math.atan2(dx, -dz)
  view.pitch = math.deg(math.atan2(-dy, math.max(flat, 1e-6)))
  view.fovY = math.deg(worldCam.fov or view.fovY or 50)
  ground.cameraPlaced = true

  Host._inBattle = true
  local drawFree = Host._drawFree or ground.drawFree
  local endFree = Host._endFree or ground.endFree
  local painted = drawFree(ground, pw, ph)
  if not painted then
    view.mode = savedMode
    if endFree then pcall(endFree, ground) end
    Host._inBattle = false
    return nil
  end
  pcall(Host.overlay3D, ground)

  Voxel3D.camera = worldCam
  local cx, cz = arena.mid[1] + ox, arena.mid[2] + oz
  local vh = (BattleCam.frameH and BattleCam.frameH(arena)) or 34
  vh = vh * ph / (select(2, BattleScene.surface()) * s)
  local vw = vh * pw / ph
  local fw = ground.freeW or pw
  local fh = ground.freeH or ph
  local Mat4 = V.require("Mat4")
  local worldShift = (ox ~= 0 or oz ~= 0) and Mat4.translate(ox, 0, oz) or nil
  pcall(function()
    local St = V.require("Stadium")
    if St and St.update then
      -- Same floor the NSBMD mesh is standing on, not the voxel 0 that
      -- buried every actor in the terrain.
      pcall(St.update, 0, state, groundY)
    end
  end)
  pcall(function()
    if not Voxel3D.beginScene(fw, fh, cx, cz, vw, vh, nil, "current") then
      return
    end
    -- beginScene uploads its own vp. The terrain was drawn with
    -- Gen4View.matrix into this same target; replace AND re-send or
    -- Pokemon/trainers project through the old lens (inside the mesh,
    -- or off the camera entirely).
    if view and type(view.matrix) == "function" then
      Voxel3D.vp = view:matrix(fw, fh)
    end
    Voxel3D.focus = worldCam.focus
    -- BattleCam cells are map-local. worldCam.eye includes the chunk origin,
    -- so yawToward(cell, worldEye) treats every mon as if the lens were still
    -- due south. Pose cards against the map-local eye, then light them with
    -- the world eye the NSBMD pass already used.
    local mapEye = { cam.eye[1], worldCam.eye[2], cam.eye[3] }
    Voxel3D.eye = mapEye
    local pull = V.require("BattleBillboard").PULL
    local cards = BattleScene.monCards(arena, groundY, textures) or {}
    Voxel3D.eye = worldCam.eye
    local sh = love.graphics.getShader()
    if sh then
      pcall(sh.send, sh, "vp", "row", Voxel3D.vp)
      pcall(sh.send, sh, "eye", Voxel3D.eye)
    end
    pcall(function()
      for _, card in ipairs(cards) do
        local model = card.model
        if worldShift then model = Mat4.mul(worldShift, model) end
        Voxel3D.draw(V.require("BattleBillboard").mesh(), card.tex, model,
                     pull)
      end
    end)
    pcall(function()
      V.require("Stadium").draw(pull, worldShift)
    end)
    pcall(function()
      local CSM = V.CurrentSpriteModels
      if CSM and type(CSM.drawWorld) == "function" then
        CSM:drawWorld({
          width = pw, height = ph, arena = arena, battle = state,
          originX = ox, originZ = oz,
        })
      end
    end)
    Voxel3D.endScene()
  end)

  local Gen4Ground = engineRequire("src.render.Gen4Ground")
  local src = Gen4Ground and Gen4Ground.freeColour
  local colour = nil
  if src and love and love.graphics then
    local g = love.graphics
    local okNew, dest = pcall(g.newCanvas, pw, ph)
    if okNew and dest then
      local prev = { g.getCanvas() }
      pcall(g.setCanvas, dest)
      g.setColor(1, 1, 1, 1)
      local sw, sh = src.getWidth and src:getWidth() or pw,
                     src.getHeight and src:getHeight() or ph
      if sw ~= pw or sh ~= ph then
        pcall(g.draw, src, 0, 0, 0, pw / sw, ph / sh)
      else
        pcall(g.draw, src, 0, 0)
      end
      pcall(g.setCanvas, prev[1] or nil)
      colour = dest
    else
      colour = src
    end
  end
  if endFree then pcall(endFree, ground) end
  Host._inBattle = false
  if not colour then
    view.mode = savedMode
    return nil
  end

  local vp = (view and view.matrix) and view:matrix(pw, ph) or Voxel3D.vp
  local pmx, pmy = BattleScene.toGB(vp, arena.player[1] + ox, groundY,
                                    arena.player[2] + oz, lx, ly, s, pw, ph)
  local emx, emy = BattleScene.toGB(vp, arena.enemy[1] + ox, groundY,
                                    arena.enemy[2] + oz, lx, ly, s, pw, ph)
  view.mode = savedMode
  if not (pmx and emx) then
    pmx, pmy = 40, 100
    emx, emy = 120, 40
  end
  return {
    canvas = colour,
    player = { pmx, pmy },
    enemy = { emx, emy },
    playerSpan = 16,
    enemySpan = 16,
    lx = lx, ly = ly, scale = s, pw = pw, ph = ph,
    eye = { worldCam.eye[1], worldCam.eye[2], worldCam.eye[3] },
    focus = { worldCam.focus[1], worldCam.focus[2], worldCam.focus[3] },
    vp = vp,
    gen4World = true,
  }
end

-- ---------------------------------------------------------------------------
-- renderPose: the native Sinnoh world through an EXPLICIT camera.
--
-- Colosseum Battle Environments' OVERWORLD arena owns its own camera (a pose
-- in map-local world pixels: eye / focus / fov), its own actors and its own
-- depth buffer. On Gen 1-3 ArenaOverworldSnapshot fills that buffer with the
-- voxel field; Gen 4 has no voxel field to draw, so this draws the cartridge's
-- own terrain and buildings through the SAME pose instead.
--
-- Why the actors still line up: a Gen 4 world is the map-local world shifted
-- by (offsetX, offsetY). Putting the Gen 4 camera at pose + offset sees exactly
-- what the pose sees in map-local space, so CBE's actors -- which live in
-- map-local space and project through the pose -- need no shift at all.
--
-- No overworld cast is drawn: the entity lists are emptied for the duration of
-- the call (restored before it returns) so followers, NPCs and roamers do not
-- stand in the arena a second time next to the CBE actors.
--
-- Returns the colour canvas (owned and reused by this module; draw it, do not
-- keep it) or nil plus a reason. Every piece of engine state it touches is put
-- back whether or not the draw succeeds.
local atan2 = math.atan2 or math.atan

local function copyFreeColour(w, h)
  local g = love and love.graphics
  local Ground = engineRequire("src.render.Gen4Ground")
  local src = Ground and Ground.freeColour
  if not (g and src) then return nil end
  local dest = Host._poseCanvas
  if not (dest and Host._poseW == w and Host._poseH == h) then
    if dest and dest.release then pcall(dest.release, dest) end
    local okNew, made = pcall(g.newCanvas, w, h)
    if not (okNew and made) then
      Host._poseCanvas = nil
      return nil
    end
    dest = made
    Host._poseCanvas, Host._poseW, Host._poseH = made, w, h
  end
  local prevCanvas = g.getCanvas()
  local blendMode, alphaMode = g.getBlendMode()
  local depthCmp, depthWrite
  if g.getDepthMode then depthCmp, depthWrite = g.getDepthMode() end
  local ok = pcall(function()
    g.setCanvas(dest)
    if g.setDepthMode then g.setDepthMode() end
    g.clear(0, 0, 0, 0)
    g.setBlendMode("replace")
    g.setColor(1, 1, 1, 1)
    local sw = src.getWidth and src:getWidth() or w
    local sh = src.getHeight and src:getHeight() or h
    g.draw(src, 0, 0, 0, w / sw, h / sh)
  end)
  pcall(g.setBlendMode, blendMode, alphaMode)
  pcall(g.setCanvas, prevCanvas)
  if g.setDepthMode and depthCmp then pcall(g.setDepthMode, depthCmp, depthWrite) end
  return ok and dest or nil
end

function Host.renderPose(state, pocket, pose, w, h)
  w, h = math.floor(tonumber(w) or 0), math.floor(tonumber(h) or 0)
  if w < 2 or h < 2 then return nil, "bad size" end
  if not (pose and pose.eye and pose.focus and pose.fov) then
    return nil, "no camera pose"
  end
  local ground = (pocket and pocket.map and pocket.map.renderer
                  and pocket.map.renderer.gen4Ground) or Host.groundOf(state)
  if not ground then return nil, "no Gen 4 ground" end
  local Gen4View = engineRequire("src.render.Gen4View")
  local drawFree = Host._drawFree or ground.drawFree
  local endFree = Host._endFree or ground.endFree
  if not (Gen4View and drawFree and endFree) then
    return nil, "engine camera seams missing"
  end
  local g = love and love.graphics

  local view = ground.view3d
  local madeView = false
  if not view then
    view = Gen4View.new("third")
    ground.view3d = view
    madeView = true
  end
  local saved = {
    mode = view.mode, x = view.x, y = view.y, z = view.z,
    yaw = view.yaw, pitch = view.pitch, fovY = view.fovY,
    placed = ground.cameraPlaced,
  }
  local savedEntities, savedGhosts
  if state then
    savedEntities, savedGhosts = state.entities, state.ghosts
    state.entities, state.ghosts = {}, {}
  end
  if g and g.push then pcall(g.push, "transform") end
  if g and g.origin then pcall(g.origin) end

  local result, why
  local okAll, errAll = pcall(function()
    local ox, oz = ground.offsetX or 0, ground.offsetY or 0
    local ex, ey, ez = pose.eye[1] + ox, pose.eye[2], pose.eye[3] + oz
    local fx, fy, fz = pose.focus[1] + ox, pose.focus[2], pose.focus[3] + oz
    local dx, dy, dz = fx - ex, fy - ey, fz - ez
    local flat = math.sqrt(dx * dx + dz * dz)
    -- third person takes view.fovY as given; field3d would derive its own
    view.mode = "third"
    view.x, view.y, view.z = ex, ey, ez
    view.yaw = atan2(dx, -dz)
    view.pitch = math.deg(atan2(-dy, math.max(flat, 1e-6)))
    view.fovY = math.deg(pose.fov)
    ground.cameraPlaced = true

    Host._inBattle = true
    local painted = drawFree(ground, w, h)
    if not painted then
      why = "the engine declined to draw the world"
      pcall(endFree, ground)
      return
    end

    -- The colour has to be taken AFTER the bridge's passes (grass, water,
    -- sand) and BEFORE the engine closes the canvas. Bridge.after is exactly
    -- that window; with no bridge there is nothing to wait for.
    local Bridge = V.Gen4Bridge
    local hook
    local fired = false
    local function capture()
      if fired then return end
      fired = true
      result = copyFreeColour(w, h)
    end
    if Bridge and type(Bridge.after) == "table" then
      hook = function() capture() end
      Bridge.after[#Bridge.after + 1] = hook
    else
      capture()
    end
    local okEnd, errEnd = pcall(endFree, ground)
    if hook then
      for i = #Bridge.after, 1, -1 do
        if Bridge.after[i] == hook then table.remove(Bridge.after, i) break end
      end
    end
    if not fired then capture() end   -- the bridge never reached its hook
    if not okEnd then why = "endFree failed: " .. tostring(errEnd) end
  end)

  Host._inBattle = false
  if state then state.entities, state.ghosts = savedEntities, savedGhosts end
  view.mode, view.x, view.y, view.z = saved.mode, saved.x, saved.y, saved.z
  view.yaw, view.pitch, view.fovY = saved.yaw, saved.pitch, saved.fovY
  ground.cameraPlaced = saved.placed
  if madeView then ground.view3d = nil end
  if g and g.pop then pcall(g.pop) end
  if g and g.setScissor then pcall(g.setScissor) end

  if not okAll then return nil, tostring(errAll) end
  if not result and not why then why = "could not copy the world's colour" end
  return result, why
end

function Host.install()
  if Host.installed then return true end
  local Gen4Ground = engineRequire("src.render.Gen4Ground")
  if not (Gen4Ground and Gen4Ground.drawFree) then return false end

  local innerDrawFree = Gen4Ground.drawFree
  function Gen4Ground:drawFree(vw, vh)
    Host._vw, Host._vh = vw, vh
    local ok = innerDrawFree(self, vw, vh)
    if ok then pcall(Host.overlay3D, self) end
    return ok
  end

  local innerFreeEntity = Gen4Ground.freeEntity
  if type(innerFreeEntity) == "function" then
    function Gen4Ground:freeEntity(mapX, mapY, camX, camY, rise, draw)
      local skip = Host._skipFeet
      if skip and skip[spriteKey(mapX, mapY)] then
        return true
      end
      return innerFreeEntity(self, mapX, mapY, camX, camY, rise, draw)
    end
  end

  local innerEndFree = Gen4Ground.endFree
  if type(innerEndFree) == "function" then
    function Gen4Ground:endFree()
      if not Host._inBattle then
        local ow = game() and game().overworld
        local sw = self.freeW or Host._vw
        local sh = self.freeH or Host._vh
        if ow and sw and sh then
          pcall(Host.overlayFx, ow, self, sw, sh, 1)
        end
      end
      return innerEndFree(self)
    end
  end

  local TileRenderer = engineRequire("src.render.TileRenderer")
  if TileRenderer and type(TileRenderer.drawAbove) == "function" then
    local innerAbove = TileRenderer.drawAbove
    function TileRenderer:drawAbove(camX, camY, vw, vh)
      local r = innerAbove(self, camX, camY, vw, vh)
      -- Field (non-free) camera: sprites are already on the world canvas.
      if self.gen4Ground and not (self.gen4Ground.freeMode
          and self.gen4Ground:freeMode()) then
        local ow = game() and game().overworld
        if ow then
          pcall(Host.overlayFx, ow, self.gen4Ground, vw, vh, 1)
        end
      end
      return r
    end
  end

  Host._drawFree = innerDrawFree
  Host._endFree = innerEndFree
  Host.installed = true
  return true
end

return Host
