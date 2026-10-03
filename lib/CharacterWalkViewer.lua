-- In-game Colosseum character studio.
--
-- OPTIONS → CHARACTER MODEL → CHARACTER VIEWER → OPEN (press A).
-- Opening dumps walk_debug_<id>.txt into the LOVE save folder for
-- tools/paint_walk_override.py. This screen never writes extracted clips.

local V = ...
local Voxel3D = V.require("Voxel3D")
local CharacterWalkCycle = V.require("CharacterWalkCycle")
local PlayerModel = V.require("PlayerModel")
local CharacterModelPick = V.require("CharacterModelPick")

local Viewer = {}
Viewer.__index = Viewer
Viewer.SCREEN = "DRAMATIC_SHAPE:characterWalkViewer"
Viewer.name = "CharacterWalkViewer"
Viewer.isOpaque = true

local W, H = 160, 144

local Font = nil
local function font()
  if Font then return Font end
  local ok, F = pcall(require, "src.render.Font")
  if ok then Font = F end
  return Font
end

local function text(str, x, y)
  local F = font()
  if not F then return end
  love.graphics.setColor(1, 1, 1, 1)
  F.draw(str, math.floor(x), math.floor(y))
end

local function dumpDebug()
  local id = PlayerModel.getCharacterId()
  if not id then return false, "character not loaded" end
  if not PlayerModel.getWalkRig() then
    pcall(PlayerModel.reloadWalkOverrides, id)
  end
  local rig = PlayerModel.getWalkRig()
  local groups = PlayerModel.getCharacterGroups()
  if not groups then return false, "no mesh groups" end
  return CharacterWalkCycle.writeDebug(id, groups, rig)
end

function Viewer.new(game)
  local self = setmetatable({
    game = game,
    yaw = 0.35,
    walking = true,
    status = "",
    phase = 0,
  }, Viewer)
  local cid = CharacterModelPick.getCurrentCharacterId()
  if cid and cid ~= "off" then
    pcall(PlayerModel.loadColosseumCharacter, cid)
  end
  local ok, where = dumpDebug()
  if ok then
    self.status = "SAVED"
    print("CharacterWalkViewer: walk_debug at " .. tostring(where))
  else
    self.status = "DUMP FAIL"
    print("CharacterWalkViewer: walk_debug failed: " .. tostring(where))
  end
  return self
end

local function pop(self)
  if self.game and self.game.stack and self.game.stack:top() == self then
    self.game.stack:pop()
  end
end

function Viewer:update()
  local input = self.game and self.game.input
  if not (input and input.wasPressed) then return end
  if input:wasPressed("b") then pop(self); return end
  if input:wasPressed("select") then
    self.walking = not self.walking
    return
  end
  if input:wasPressed("start") then
    local ok, where = dumpDebug()
    self.status = ok and "SAVED" or "DUMP FAIL"
    print("CharacterWalkViewer: " .. tostring(where))
    return
  end
  if input:isDown("left") then self.yaw = self.yaw - 0.05 end
  if input:isDown("right") then self.yaw = self.yaw + 0.05 end
  if self.walking then
    self.phase = self.phase + 0.12
  end
end

local function project(self, x, y, z)
  local c, s = math.cos(self.yaw), math.sin(self.yaw)
  local rx = x * c + z * s
  local h = math.max(0.05, self.maxY - self.minY)
  local scale = math.min(70, (H - 40) / h)
  local cx, cy = 80, 18 + self.maxY * scale
  return cx + rx * scale, cy - y * scale
end

local function drawDots(self, groups, rig)
  self.minY, self.maxY = 0, 1
  for _, g in ipairs(groups or {}) do
    for _, v in ipairs(g.baseVertices or {}) do
      local y = v[2] or 0
      if y < self.minY then self.minY = y end
      if y > self.maxY then self.maxY = y end
    end
  end
  local blend = self.walking and 1 or 0
  for gi, g in ipairs(groups or {}) do
    local src = g.baseVertices
    if blend > 0 and rig then
      src = CharacterWalkCycle.apply(rig, gi, g, self.phase, blend, nil) or src
    end
    local buckets = rig and rig.groups and rig.groups[gi]
    for vi, v in ipairs(src or {}) do
      local b = buckets and buckets[vi]
      local col = CharacterWalkCycle.bucketColor(b and b.bucket, b and b.side)
      local px, py = project(self, v[1] or 0, v[2] or 0, v[3] or 0)
      love.graphics.setColor(col[1], col[2], col[3], 1)
      love.graphics.rectangle("fill", math.floor(px), math.floor(py), 1, 1)
    end
  end
end

local function drawStudio(self)
  local G = love.graphics
  local prevCanvas = G.getCanvas and G.getCanvas() or nil
  local h = PlayerModel.previewHeight()
  local dist = math.max(1.2, h * 2.15)
  local focusY = h * 0.48
  local prevCam = Voxel3D.camera
  Voxel3D.camera = {
    eye = { math.sin(self.yaw) * dist, focusY + h * 0.08, math.cos(self.yaw) * dist },
    focus = { 0, focusY, 0 },
    fov = math.rad(28),
  }
  local canvas = nil
  local opened = Voxel3D.beginScene(W, H, 0, 0, W, H, { 0.18, 0.20, 0.24, 1 }, "characterWalk")
  if opened then
    pcall(PlayerModel.drawPreview, 0, self.walking)
    canvas = Voxel3D.endScene()
  end
  Voxel3D.camera = prevCam
  pcall(G.setShader)
  pcall(G.setDepthMode)
  if prevCanvas then
    pcall(G.setCanvas, prevCanvas)
  else
    pcall(G.setCanvas)
  end
  pcall(G.setColor, 1, 1, 1, 1)
  if canvas then
    local cw = canvas.getWidth and canvas:getWidth() or W
    local ch = canvas.getHeight and canvas:getHeight() or H
    local ok = pcall(G.draw, canvas, 0, 0, 0, W / math.max(1, cw), H / math.max(1, ch))
    if ok then return true end
  end
  return false
end

function Viewer:draw()
  love.graphics.setColor(0.10, 0.11, 0.14, 1)
  love.graphics.rectangle("fill", 0, 0, W, H)

  local id = PlayerModel.getCharacterId()
  local groups = PlayerModel.getCharacterGroups()
  if not (id and groups) then
    text("SET CHARACTER MODEL", 8, 64)
    love.graphics.setColor(1, 1, 1, 1)
    return
  end

  local studio = false
  local ok, drew = pcall(drawStudio, self)
  studio = ok and drew == true
  if not studio then
    drawDots(self, groups, PlayerModel.getWalkRig())
  end

  love.graphics.setColor(0, 0, 0, 0.45)
  love.graphics.rectangle("fill", 0, 0, W, 22)
  love.graphics.rectangle("fill", 0, H - 16, W, 16)
  text(tostring(id):upper(), 4, 2)
  text(self.walking and "WALK" or "IDLE", 120, 2)
  if self.status ~= "" then text(self.status, 4, 12) end
  text("L/R ORBIT  SEL WALK  B BACK", 4, 136)
  love.graphics.setColor(1, 1, 1, 1)
end

function Viewer.row()
  return {
    id = Viewer.SCREEN,
    label = "CHARACTER VIEWER",
    value = function()
      local cid = CharacterModelPick.getCurrentCharacterId()
      if not cid or cid == "off" then return "SET MODEL" end
      return "OPEN"
    end,
    activate = function(game)
      local cid = CharacterModelPick.getCurrentCharacterId()
      if not cid or cid == "off" then return end
      pcall(PlayerModel.loadColosseumCharacter, cid)
      if game and game.stack then
        game.stack:push(Viewer.new(game))
      end
    end,
  }
end

return Viewer
