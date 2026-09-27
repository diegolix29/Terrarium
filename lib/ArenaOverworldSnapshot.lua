-- Caches the live voxel FIELD (ChunkMesher pocket + BattleArena marks) at
-- battle start so Colosseum Battle Environments' OVERWORLD entry can stage
-- the fight on the same 3D ground OverworldBattle uses -- not a PNG blit of
-- the last overworld frame (which included the player sprite).
--
-- CBE still owns camera, actors, crowd and move FX. This module only holds
-- the map pocket and draws its terrain into the already-bound arena canvas
-- (Voxel3D.beginScene slot "current").
local V = ...
local M = {}

local field = nil

local function log(level, fmt, ...)
  local m = V.mod
  local l = m and m.log
  if l and type(l[level]) == "function" then pcall(l[level], l, fmt, ...) end
end

local function voxel(name)
  if type(V.voxelRequire) == "function" then
    local ok, mod = pcall(V.voxelRequire, name)
    if ok then return mod end
  end
  return V[name]
end

local function engineReq(name)
  local req = V.engineRequire or require
  local ok, mod = pcall(req, name)
  if ok then return mod end
  return nil
end

-- True only when CBE is on and the player's selected arena is OVERWORLD.
-- Do not call ArenaCatalog.resolve here: that binds the battle, and capture
-- runs at pushBattle -- before battle.started's releaseBattle / re-acquire.
local function wantsSnapshot(battle)
  local ArenaCatalog = V.ArenaCatalog
  if not (ArenaCatalog and type(ArenaCatalog.enabled) == "function") then
    return false, "catalog missing"
  end
  local game = (battle and battle.game) or (V.mod and V.mod.game)
  local okEnabled, enabled = pcall(ArenaCatalog.enabled, game)
  if not (okEnabled and enabled) then return false, "cbe off" end
  local selected = "auto"
  if type(ArenaCatalog.selected) == "function" then
    local okSel, sel = pcall(ArenaCatalog.selected, game)
    if okSel and sel then selected = sel end
  end
  local def = type(ArenaCatalog.definition) == "function"
    and ArenaCatalog.definition(selected) or nil
  if type(def) == "table" and def.liveOverworld == true then
    return true, selected
  end
  return false, "arena=" .. tostring(selected)
end

local function overworldState(hint)
  if hint and hint.map and hint.player then return hint end
  local Game = engineReq("src.core.Game")
  return Game and Game.overworld or nil
end

-- Same map pocket OverworldBattle.stageFor uses on an A rung: authored or
-- searched cells, never the carried Stadium discs and never a BattleCanvas PNG.
local function findPocket(state, battle)
  local BattleArena = voxel("BattleArena")
  if not (BattleArena and type(BattleArena.find) == "function") then
    return nil, "BattleArena missing"
  end
  local map, player = state.map, state.player
  if not (map and player) then return nil, "no map/player" end
  local bt = battle and tostring(battle.battleType or ""):lower() or ""
  local surfing = (bt == "fish" or bt == "fishing")
    or (player.surfing == true)
  local ok, arena = pcall(BattleArena.find, map, player.cellX, player.cellY, surfing)
  if not (ok and arena) then return nil, "no pocket" end
  arena.surfing = surfing and true or false
  if surfing then arena.water = true end
  return arena
end

local function groundYFor(pocket)
  local BattleScene = voxel("BattleScene")
  local host = pocket.map
  if BattleScene and type(BattleScene.groundY) == "function" and host then
    local ok, y = pcall(BattleScene.groundY, host, pocket)
    if ok and y then return y end
  end
  return 0
end

function M.capture(battle, stateHint)
  local wanted, why = wantsSnapshot(battle)
  if not wanted then return false end
  local Voxel3D = V.Voxel3D or voxel("Voxel3D")
  if not (Voxel3D and Voxel3D.available and Voxel3D.available()) then
    log("warn", "overworld arena field skipped: voxel unavailable")
    return false
  end
  local state = overworldState(stateHint)
  if not state then
    log("warn", "overworld arena field skipped: no overworld state")
    return false
  end
  local pocket, whyPocket = findPocket(state, battle)
  if not pocket then
    log("warn", "overworld arena field skipped: %s", tostring(whyPocket))
    return false
  end
  local VoxelScene = voxel("VoxelScene")
  local ChunkMesher = voxel("ChunkMesher")
  if VoxelScene and type(VoxelScene.prefetch) == "function" then
    pcall(VoxelScene.prefetch, state)
  end
  if ChunkMesher and type(ChunkMesher.pump) == "function" then
    pcall(ChunkMesher.pump, true)
  end
  local host = pocket.map or state.map
  field = {
    state = state,
    pocket = pocket,
    host = host,
    groundY = groundYFor(pocket),
    mapId = host and host.id or (state.map and state.map.id),
  }
  log("info", "overworld arena field cached map=%s pocket=%s@(%s,%s) (arena=%s)",
      tostring(field.mapId), tostring(pocket.shape),
      tostring(pocket.x), tostring(pocket.y), tostring(why))
  return true
end

function M.field()
  return field
end

function M.clear()
  field = nil
end

-- BattleCam pose in world pixels, so CBE's compositor and the voxel field
-- share one camera.
function M.cameraPose()
  if not (field and field.pocket) then return nil end
  local BattleCam = voxel("BattleCam")
  if not (BattleCam and type(BattleCam.rig) == "function") then return nil end
  local ok, cam = pcall(BattleCam.rig, field.pocket, field.groundY or 0)
  if not (ok and cam and cam.eye and cam.focus and cam.fov) then return nil end
  return cam
end

local function trainerBehind(pocket, side)
  local p, e = pocket.player, pocket.enemy
  if not (p and e) then return nil end
  local dx, dz = p[1] - e[1], p[2] - e[2]
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 1e-3 then dx, dz, len = 0, 1, 1 end
  dx, dz = dx / len, dz / len
  local behind = 19.2  -- 20% closer (was 24)
  if side == "player" then
    return { p[1] + dx * behind, p[2] + dz * behind }
  end
  return { e[1] - dx * behind, e[2] - dz * behind }
end

-- Rewrite CBE arena marks into world-pixel space so Pokemon/trainers stand
-- on the cached pocket instead of the generic stadium disc.
function M.applyTo(arena, def)
  if not (arena and field and field.pocket) then return false end
  local pocket = field.pocket
  arena.liveField = true
  arena.mid = { pocket.mid[1], pocket.mid[2] }
  arena.groundY = field.groundY or 0
  arena.map = field.host
  arena.playerCell = pocket.playerCell
  arena.enemyCell = pocket.enemyCell
  local BattleCam = voxel("BattleCam")
  if BattleCam and type(BattleCam.rigFor) == "function" then
    arena.camera = BattleCam.rigFor(pocket)
  end
  local profile = {
    pokemon = { player = pocket.player, enemy = pocket.enemy },
    trainers = {
      player = trainerBehind(pocket, "player"),
      enemy = trainerBehind(pocket, "enemy"),
    },
    trainerScale = def and def.trainerScale,
  }
  if V.PlayerTrainer and type(V.PlayerTrainer.setArenaProfile) == "function" then
    pcall(V.PlayerTrainer.setArenaProfile, V.PlayerTrainer, profile)
  end
  if V.Trainer and type(V.Trainer.setArenaProfile) == "function" then
    pcall(V.Trainer.setArenaProfile, V.Trainer, profile)
  end
  return true
end

local function paletteFor(state, home)
  local PaletteFX = engineReq("src.render.PaletteFX")
  if not (PaletteFX and state and type(state.paletteNameFor) == "function") then
    return function() return nil end
  end
  local Game = engineReq("src.core.Game")
  local data = Game and Game.data
  return function(map)
    return PaletteFX.pal(data, state:paletteNameFor(map or home))
  end
end

-- Draw cached voxel terrain into the currently bound CBE arena framebuffer.
-- Caller owns clear/sky; this only submits field meshes with the CBE pose.
function M.draw(w, h, pose)
  if not (field and field.pocket and field.state) then return false end
  local Voxel3D = V.Voxel3D or voxel("Voxel3D")
  local VoxelScene = voxel("VoxelScene")
  local ChunkMesher = voxel("ChunkMesher")
  local TerrainAtlas = voxel("TerrainAtlas")
  local Mat4 = V.Mat4 or voxel("Mat4")
  if not (Voxel3D and VoxelScene and ChunkMesher and TerrainAtlas
      and type(Voxel3D.beginScene) == "function") then
    return false
  end
  local state = overworldState(field.state) or field.state
  local pocket = field.pocket
  local host = pocket.map or field.host or state.map
  if not host then return false end
  if ChunkMesher.pump then pcall(ChunkMesher.pump, true) end

  local Map = engineReq("src.world.Map")
  local outdoor = host.def and Map and Map.isOutdoor and Map.isOutdoor(host.def) or false
  local DayNight = voxel("DayNight")
  if DayNight then
    if type(DayNight.applyRig) == "function" then pcall(DayNight.applyRig, outdoor) end
    if type(DayNight.tint) == "function" then
      Voxel3D.tint = DayNight.tint(outdoor or (DayNight.isCanopy and DayNight.isCanopy(host)))
    end
    if type(DayNight.lampColor) == "function" then Voxel3D.lampColor = DayNight.lampColor() end
    if type(DayNight.windowLight) == "function" then Voxel3D.glassNight = outdoor and DayNight.windowLight() or 0 end
  end
  Voxel3D.skyAmount = outdoor and 1 or 0
  Voxel3D.glassGlint = 0
  Voxel3D.lampLights = nil
  Voxel3D.lampFlicker = 0
  local GlassMask = voxel("GlassMask")
  if outdoor and GlassMask and type(GlassMask.texture) == "function" then
    Voxel3D.glassMask = GlassMask.texture(host.tileset)
  else
    Voxel3D.glassMask = nil
  end
  local ForestAtmos = voxel("ForestAtmos")
  if ForestAtmos and type(ForestAtmos.frame) == "function" then
    local atmos = ForestAtmos.frame(host)
    Voxel3D.fog = atmos and {
      color = atmos.fog.color,
      density = atmos.fog.density * 0.5,
      start = atmos.fog.start,
      heightK = atmos.fog.heightK,
    } or nil
  end

  local neighbors = (host == state.map) and (state.neighbors or {}) or {}
  local terrain, nbMesh = VoxelScene.prefetch(state)
  if host ~= state.map then
    terrain = ChunkMesher.peek(host, false) or ChunkMesher.peek(host, true) or terrain
    nbMesh = nbMesh or {}
  end
  if not terrain then return false end

  local water = ChunkMesher.pair and select(2, ChunkMesher.pair(host, false))
  if not water and ChunkMesher.pair then
    water = select(2, ChunkMesher.pair(host, true))
  end

  local pal = paletteFor(state, host)
  local function atlasFor(map)
    return TerrainAtlas.forMap(map, VoxelScene._modeColors(pal, map))
  end

  local cam = pose
  if not (cam and cam.eye and cam.focus and cam.fov) then
    cam = M.cameraPose()
  end
  if not cam then return false end

  local BattleCam = voxel("BattleCam")
  local cx, cy = pocket.mid[1], pocket.mid[2]
  local vh = (BattleCam and BattleCam.frameH and BattleCam.frameH(pocket)) or 34
  local vw = vh * (w / math.max(1, h))

  local prevCam = Voxel3D.camera
  Voxel3D.camera = cam
  local ok = pcall(function()
    if not Voxel3D.beginScene(w, h, cx, cy, vw, vh, nil, "current") then
      return
    end
    Voxel3D.drawGroup(terrain, atlasFor(host), nil, nil, nil, nil)
    for i, nb in ipairs(neighbors) do
      if nbMesh and nbMesh[i] and nb.map then
        local model = Mat4 and Mat4.translate and Mat4.translate(nb.ox, 0, nb.oy) or nil
        Voxel3D.drawGroup(nbMesh[i], atlasFor(nb.map), model, nil, nil, nil)
      end
    end
    if water then Voxel3D.draw(water, atlasFor(host)) end
    local Wind = voxel("Wind")
    local sway = (Wind and Wind.amount and Wind.amount()) or 0
    local pitch = 0.2
    local pull = (VoxelScene.pull and VoxelScene.pull(math.max(pitch, 0.05))) or 0
    local grassTex = atlasFor(host)
    local Grass3D = voxel("Grass3D")
    if Grass3D and Grass3D.available and Grass3D.available() and Grass3D.texture then
      local gt = Grass3D.texture()
      if gt then grassTex = gt end
    end
    for _, b in ipairs(ChunkMesher.grass(host) or {}) do
      local model = Mat4 and Mat4.translate and Mat4.translate(0, b.y, 0) or nil
      Voxel3D.draw(b.mesh, grassTex, model, pull, nil, sway)
    end
    for _, nb in ipairs(neighbors) do
      for _, b in ipairs(ChunkMesher.grass(nb.map) or {}) do
        local model = Mat4 and Mat4.translate and Mat4.translate(nb.ox, b.y, nb.oy) or nil
        Voxel3D.draw(b.mesh, grassTex, model, pull, nil, sway)
      end
    end
    Voxel3D.endScene()
  end)
  Voxel3D.camera = prevCam
  if not ok then
    pcall(Voxel3D.endScene)
    return false
  end
  return true
end

-- Kept so older Arena.lua backdrop code does not error. Always empty: the
-- field is 3D geometry, not a still of the player.
function M.image()
  return nil, 0, 0
end

function M.install()
  local req = V.engineRequire or require
  local ok, OverworldState = pcall(req, "src.world.OverworldController")
  if not (ok and OverworldState) then
    log("warn", "overworld arena field hook not installed: OverworldController unavailable")
    return false
  end
  if OverworldState.cbeOverworldSnapshotHook then return true end
  local inner = OverworldState.pushBattle
  function OverworldState:pushBattle(battle)
    pcall(M.capture, battle, self)
    return inner(self, battle)
  end
  OverworldState.cbeOverworldSnapshotHook = true
  log("info", "overworld arena field hook installed on OverworldState.pushBattle")
  return true
end

return M
