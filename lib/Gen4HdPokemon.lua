-- HD Reloded 2D cards for roamers and followers in Platinum's own 3D world.
--
-- Gen 4 does not run VoxelScene. This pass is registered on Gen4Bridge so it
-- draws into the still-open Gen4Ground free canvas (colour + depth), depth-
-- tested against NSBMD terrain. Stadium / Colosseum models still win: those
-- are drawn earlier by Gen4WorldHost, which marks Host._drew3d so this pass
-- leaves them alone.
--
-- SIZE: an HD overworld card is born exactly one tile tall for EVERY species
-- (HDPokemonSheets.applyOverworld: scale = 16 / frameH), which is right for the
-- 2D Gen 1-3 overworld but wrong on Platinum's native world. Here each card is
-- re-scaled through Gen4PokemonScale so its height comes from PokemonHeights,
-- exactly like the Colosseum / Stadium models drawn beside it.

local V = ...

local Voxel3D = V.require("Voxel3D")
local Mat4 = V.require("Mat4")
local SpriteBillboards = V.require("SpriteBillboards")
-- Optional on purpose: if the shared sizing module ever fails to load, HD cards
-- fall back to the old one-tile size instead of disappearing.
local Scale = V.optional and V.optional("Gen4PokemonScale") or nil

local Hd = {}

local function hdModule()
  local HD = V.HDPokemonSheets or (V.mod and V.mod.exports and V.mod.exports.hdPokemonSheets)
  if HD then return HD end
  local ok, m = pcall(V.require, "HDPokemonSheets")
  if ok and type(m) == "table" then
    V.HDPokemonSheets = m
    return m
  end
  return nil
end

local function gameOf()
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game) then return nil end
  if type(Game.get) == "function" then
    local inst = Game:get()
    if inst then return inst end
  end
  return Game
end

function Hd.isFollower(e)
  if type(e) ~= "table" then return false end
  return e.isFollower == true or e.wildsFollower == true
    or e.pikachuFollower == true or e.follower == true
    or e._wildsFollowerSpecies ~= nil
end

function Hd.wantsEntity(e, state)
  if type(e) ~= "table" or e.hidden then return false end
  if state and e == state.player then return false end
  if Hd.isFollower(e) or e.roamer or e.overworldWildSpawn then return true end
  if e.species or e._wildsFollowerSpecies then return true end
  local def = e.sprite and e.sprite.def
  return def ~= nil and (def.hdDex ~= nil or def.dsSpecies ~= nil)
end

local function bindOverlay(e, facing, game)
  local HD = hdModule()
  if not (HD and type(HD.bindOverworldDef) == "function") then return nil end
  local sprite = e.sprite
  local base = sprite and sprite.def
  if type(base) ~= "table" then return nil end
  local data = game and game.data
  local dex = tonumber(base.hdDex)
    or (HD.dexOf and (HD.dexOf(e, data) or HD.dexOf(base.dsSpecies, data)
                      or HD.dexOf(base.hdDex, data)))
  if not dex then return nil end
  return HD.bindOverworldDef(e, base, {
    dex = dex,
    facing = HD.sheetFacing(facing, Hd.isFollower(e) and "follower" or "roamer"),
    shiny = e.shiny or e.isShiny,
    game = game,
    key = "g4:" .. tostring(e) .. ":" .. tostring(dex),
  })
end

-- Species-correct size multiplier for a bound HD overlay (1 = the old,
-- species-blind one-tile card). `cardH` is the card's natural world height.
local function sizeFor(overlay, cardH)
  if not (Scale and Scale.active and Scale.active()) then return 1 end
  local ok, k = pcall(Scale.cardScale, overlay and overlay.hdDex, cardH)
  if ok and type(k) == "number" and k > 0 then return k end
  return 1
end

-- `k` scales the card uniformly about its feet-centre. The scale is applied
-- after the yaw and BEFORE the -half centring, so the card stays centred on
-- (wx, wz) and keeps standing on gy at any size.
local function cardMatrix(wx, gy, wz, worldW, ground, k)
  local Cam = V.require("Gen4ActorCam")
  local yaw = 0
  if Cam and Cam.cardYaw then
    yaw = Cam.cardYaw(wx, wz, ground) or 0
  end
  local half = (worldW or 16) / 2
  local m = Mat4.translate(wx, gy, wz)
  if yaw ~= 0 then m = Mat4.mul(m, Mat4.rotateY(yaw)) end
  if k and k ~= 1 then m = Mat4.mul(m, Mat4.scale(k, k, k)) end
  return Mat4.mul(m, Mat4.translate(-half, 0, 0))
end

local function spriteKey(mapX, mapY)
  return string.format("%d:%d", math.floor((mapX or 0) + 0.5),
                       math.floor((mapY or 0) + 0.5))
end

function Hd.drawPose(p, ground)
  if type(p) ~= "table" then return false end
  local e = p.entity or p
  if not Hd.wantsEntity(e) then return false end
  local overlay = bindOverlay(e, p.facing or e.facing or "down", gameOf())
  if not overlay or not overlay.hdImage then return false end
  local mesh = SpriteBillboards.mesh(overlay, 0)
  if not mesh then return false end
  local _, _, worldW, worldH = SpriteBillboards.getSpriteDimensions(overlay, 0)
  local wx = (p.px or 0) + 8
  local wz = (p.py or 0) + 8
  local gy = (p.gh or 0) + (p.lift or 0)
  Voxel3D.draw(mesh, overlay.hdImage,
               cardMatrix(wx, gy, wz, worldW, ground, sizeFor(overlay, worldH)))
  return true
end

-- `skip(mapX, mapY)` is Host.isSkipped (position, with tolerance); `drawn` is the
-- set of entities Gen4WorldHost already gave a 3D model this frame. The entity
-- check is exact, so it does not depend on the position match at all.
local function drawOne(e, mapX, mapY, scene, game, skip, drawn)
  if not Hd.wantsEntity(e) then return end
  if drawn and drawn[e] then return end
  if skip and skip(mapX, mapY) then return end
  local overlay = bindOverlay(e, e.facing or "down", game)
  if not overlay or not overlay.hdImage then return end
  local mesh = SpriteBillboards.mesh(overlay, 0)
  if not mesh then return end
  local _, _, worldW, worldH = SpriteBillboards.getSpriteDimensions(overlay, 0)
  local gy = 0
  if scene.groundY then
    gy = scene.groundY((mapX or 0) + 8, (mapY or 0) + 8) or 0
  end
  local wx, wz = scene.toWorld(mapX or 0, mapY or 0)
  Voxel3D.draw(mesh, overlay.hdImage,
               cardMatrix(wx + 8, gy, wz + 8, worldW, scene.ground,
                          sizeFor(overlay, worldH)))
end

function Hd.draw(scene)
  if not scene or type(scene.toWorld) ~= "function" then return end
  local game = gameOf()
  local ow = game and game.overworld
  if not ow then return end
  local Host
  do
    local ok, h = pcall(V.require, "Gen4WorldHost")
    if ok then Host = h end
  end
  -- Field actors already drew 3D or HD and hid the 16px feet; do not stack
  -- a second card in the endFree pass.
  local skip
  if Host and type(Host.isSkipped) == "function" then
    skip = Host.isSkipped
  elseif Host and Host._skipFeet then
    local t = Host._skipFeet
    skip = function(x, y) return t[spriteKey(x, y)] end
  end
  local drawn = Host and Host._drawnEnt
  local seen = {}          -- an entity in both lists is still one card
  if Voxel3D.glass then Voxel3D.glass(false) end
  scene.opaque()
  for _, e in ipairs(ow.entities or {}) do
    if not seen[e] then
      seen[e] = true
      pcall(drawOne, e, e.px, e.py, scene, game, skip, drawn)
    end
  end
  for _, g in ipairs(ow.ghosts or {}) do
    local npc = g and g.npc
    if npc and not seen[npc] then
      seen[npc] = true
      pcall(drawOne, npc, (npc.px or 0) + (g.ox or 0), (npc.py or 0) + (g.oy or 0),
            scene, game, skip, drawn)
    end
  end
end

return Hd