local ROOT = "lib/"
local fails, passes = 0, 0
local function check(cond, msg) if cond then passes = passes + 1 else fails = fails + 1; print("FAIL: " .. msg) end end

-- ---------------------------------------------------------------- stubs --
local calls = {}
local function rec(name) return function(...) calls[#calls+1] = name; return end end
local canvasId = 0
local function newCanvas(w, h)
  canvasId = canvasId + 1
  return { id = canvasId, w = w, h = h, getWidth = function(s) return s.w end,
           getHeight = function(s) return s.h end, release = function() end }
end
local bound = nil
local depth = { "lequal", true }
local blend = { "alpha", "alphamultiply" }
local shader = "SHADER"
local drawn = {}
love = { graphics = {
  getCanvas = function() return bound end,
  setCanvas = function(c) bound = c end,
  newCanvas = newCanvas,
  getBlendMode = function() return blend[1], blend[2] end,
  setBlendMode = function(a, b) blend = { a, b } end,
  getDepthMode = function() return depth[1], depth[2] end,
  setDepthMode = function(a, b) if a then depth = { a, b } else depth = { "always", false } end end,
  getShader = function() return shader end,
  setShader = function(s) shader = s end,
  clear = rec("clear"), setColor = rec("setColor"),
  draw = function(c, x, y, r, sx, sy) drawn[#drawn+1] = { c = c, sx = sx, sy = sy, depth = depth[1], blend = blend[2], bound = bound } end,
  push = rec("push"), pop = rec("pop"), origin = rec("origin"), setScissor = rec("setScissor"),
}}

local freeColour = newCanvas(256, 192)
local engine = {}
engine["src.render.Gen4Ground"] = { freeColour = freeColour }
engine["src.render.Gen4View"] = { new = function(mode) return { mode = mode } end }

local V = { engineRequire = function(n) return assert(engine[n], "no stub " .. n) end,
            mod = { log = { warn = function() end, info = function() end } },
            Gen4Bridge = { after = {} } }
V.require = function(n) return V[n] end
local Host = assert(loadfile(ROOT .. "Gen4WorldHost.lua"))(V)
V.Gen4WorldHost = Host

-- a fake ground, closing like the engine: bridge hooks first, then it closes
local seen
local function makeGround(opts)
  opts = opts or {}
  local g = { offsetX = 100, offsetY = 200, view3d = opts.view, cameraPlaced = false,
              map = nil }
  g.drawFree = function(self, w, h)
    if opts.throwDraw then error("boom") end
    self.freeOpen = true; self.freeW, self.freeH = w, h
    local v = self.view3d
    seen = { mode = v.mode, x = v.x, y = v.y, z = v.z, yaw = v.yaw, pitch = v.pitch, fovY = v.fovY,
             placed = self.cameraPlaced, inBattle = Host._inBattle, w = w, h = h,
             entities = opts.state and #opts.state.entities or nil }
    if opts.declineDraw then return false end
    return true
  end
  g.endFree = function(self)
    for _, fn in ipairs(V.Gen4Bridge.after) do fn(self, self.view3d, self.freeW, self.freeH) end
    self.freeOpen = false
    seen.hooksAtClose = #V.Gen4Bridge.after
  end
  return g
end

local pose = { eye = { 10, 40, 90 }, focus = { 10, 6, 20 }, fov = math.rad(40) }

-- 1. camera, restore, hook ------------------------------------------------
do
  local state = { entities = { "a", "b" }, ghosts = { "g" } }
  local existing = { mode = "field3d", x = 1, y = 2, z = 3, yaw = 0.5, pitch = 12, fovY = 50 }
  local ground = makeGround({ view = existing, state = state })
  state.map = { renderer = { gen4Ground = ground } }
  local origEnt, origGh = state.entities, state.ghosts
  local colour, why = Host.renderPose(state, { map = state.map }, pose, 320, 240)
  check(colour ~= nil and why == nil, "renders a colour canvas")
  check(colour and colour.w == 320 and colour.h == 240, "canvas is the requested size")
  check(seen.mode == "third", "third-person lens during the draw")
  check(seen.x == 110 and seen.y == 40 and seen.z == 290, "eye = pose + world offset")
  check(math.abs(seen.fovY - 40) < 1e-6, "fov carried as degrees")
  check(seen.pitch > 0, "looks down at the ground (pitch positive)")
  -- yaw: looking from (10,90) to (10,20) is -z (north): engine yaw 0
  check(math.abs(seen.yaw) < 1e-9, "yaw looks along the pose (due north)")
  check(seen.placed == true, "cameraPlaced set during the draw")
  check(seen.inBattle == true, "Host._inBattle set during the draw")
  check(seen.entities == 0, "overworld cast hidden during the draw")
  check(state.entities == origEnt and state.ghosts == origGh, "cast restored by identity")
  check(existing.mode == "field3d" and existing.x == 1 and existing.y == 2 and existing.z == 3
        and existing.yaw == 0.5 and existing.pitch == 12 and existing.fovY == 50, "player's view restored exactly")
  check(ground.cameraPlaced == false, "cameraPlaced restored")
  check(Host._inBattle == false, "_inBattle cleared")
  check(#V.Gen4Bridge.after == 0, "temporary bridge hook removed")
  check(seen.hooksAtClose == 1, "hook was present when the canvas closed")
  check(ground.view3d == existing, "existing view kept")
end

-- 2. created view is discarded ------------------------------------------------
do
  local state = { entities = {}, ghosts = {} }
  local ground = makeGround({ state = state })
  state.map = { renderer = { gen4Ground = ground } }
  local colour = Host.renderPose(state, nil, pose, 128, 96)
  check(colour ~= nil, "renders with no pre-existing view")
  check(ground.view3d == nil, "a view made for the draw does not outlive it")
end

-- 3. canvas reuse + no bridge -------------------------------------------------
do
  local state = { entities = {}, ghosts = {} }
  local ground = makeGround({ view = { mode = "third" }, state = state })
  state.map = { renderer = { gen4Ground = ground } }
  local a = Host.renderPose(state, nil, pose, 128, 96)
  local b = Host.renderPose(state, nil, pose, 128, 96)
  check(a == b, "same-size canvas is reused, not reallocated per frame")
  local c = Host.renderPose(state, nil, pose, 200, 100)
  check(c ~= a and c.w == 200, "new size gets a new canvas")
  local savedBridge = V.Gen4Bridge; V.Gen4Bridge = nil
  local d = Host.renderPose(state, nil, pose, 200, 100)
  check(d ~= nil, "works with no bridge installed")
  V.Gen4Bridge = savedBridge
end

-- 4. failure paths restore everything -------------------------------------------
do
  local state = { entities = { 1 }, ghosts = { 2 } }
  local view = { mode = "cartridge", x = 5 }
  local ground = makeGround({ view = view, state = state, throwDraw = true })
  state.map = { renderer = { gen4Ground = ground } }
  local e0, g0 = state.entities, state.ghosts
  local colour, why = Host.renderPose(state, nil, pose, 128, 96)
  check(colour == nil and why and why:find("boom"), "a throwing draw reports and returns nil")
  check(state.entities == e0 and state.ghosts == g0, "cast restored after a throw")
  check(view.mode == "cartridge" and view.x == 5, "view restored after a throw")
  check(Host._inBattle == false, "_inBattle cleared after a throw")
  check(#V.Gen4Bridge.after == 0, "no stray hook after a throw")

  local g2 = makeGround({ view = { mode = "third" }, state = state, declineDraw = true })
  state.map = { renderer = { gen4Ground = g2 } }
  local c2, why2 = Host.renderPose(state, nil, pose, 128, 96)
  check(c2 == nil and why2 ~= nil, "a declined draw says why")
  check(#V.Gen4Bridge.after == 0, "no hook after a declined draw")

  check(select(2, Host.renderPose(state, nil, nil, 128, 96)) ~= nil, "no pose is refused")
  check(select(2, Host.renderPose(state, nil, pose, 0, 0)) ~= nil, "bad size is refused")
  check(select(2, Host.renderPose({ map = {} }, nil, pose, 64, 64)) ~= nil, "non-Gen-4 state is refused")
end

-- 5. ArenaOverworldSnapshot -------------------------------------------------------
do
  local logs = {}
  V.mod.log = { warn = function(_, f, ...) logs[#logs+1] = f:format(...) end,
                info = function(_, f, ...) logs[#logs+1] = f:format(...) end }
  local pocket = { map = {}, shape = "S", x = 3, y = 4, mid = { 50, 60 }, player = { 40, 70 }, enemy = { 60, 50 }, playerCell = { 2, 4 }, enemyCell = { 3, 3 } }
  V.ArenaCatalog = { enabled = function() return true end, selected = function() return "overworld" end,
                     definition = function() return { liveOverworld = true } end }
  V.voxelRequire = function(n)
    if n == "BattleArena" then return { find = function() return pocket end } end
    if n == "BattleScene" then return { groundY = function() return 12 end } end
    if n == "BattleCam" then return { rig = function() return pose end, rigFor = function() return {} end } end
  end
  V.Voxel3D = { available = function() return false end }   -- voxel unusable, as on Platinum
  -- the snapshot module really runs in the Colosseum namespace: no require, no
  -- Gen4WorldHost field; main-mod modules only through voxelRequire
  local mainRequireOf = { Gen4WorldHost = Host }
  local prevVR = V.voxelRequire
  local NS = { mod = V.mod, engineRequire = V.engineRequire, Voxel3D = V.Voxel3D,
               ArenaCatalog = V.ArenaCatalog,
               voxelRequire = function(n) return mainRequireOf[n] or prevVR(n) end }
  local Snap = assert(loadfile(ROOT .. "ArenaOverworldSnapshot.lua"))(NS)

  local state = { entities = {}, ghosts = {}, map = {}, player = { cellX = 2, cellY = 4 } }
  local ground = makeGround({ view = { mode = "third" }, state = state })
  state.map.renderer = { gen4Ground = ground }

  check(Snap.capture(nil, state) == true, "capture succeeds on Gen 4 with voxel unavailable")
  check(Snap.nativeWorld() == true, "field flagged as a native world")
  check(Snap.field().gen4 == true and Snap.field().groundY == 12, "field carries gen4 flag and ground height")
  check(pocket.cam == "wide", "interior-safe wide rig chosen")

  check(Snap.blit(100, 80) == false, "blit before a draw does nothing")
  check(Snap.draw(256, 192, pose) == true, "draw renders the native world")
  check(Snap.field().worldColour ~= nil, "world colour kept for the blit")
  check(seen.w == 256 and seen.h == 192, "world drawn at the arena canvas size")

  local arenaCanvas = newCanvas(256, 192); bound = arenaCanvas
  drawn = {}
  check(Snap.blit(256, 192) == true, "blit succeeds")
  check(#drawn == 1 and drawn[1].c == Snap.field().worldColour, "blit draws the world canvas")
  check(drawn[1].depth == "always", "blit ignores depth")
  check(drawn[1].blend == "premultiplied", "blit uses premultiplied alpha")
  check(depth[1] == "lequal" and depth[2] == true, "depth mode restored after blit")
  check(shader == "SHADER" and blend[2] == "alphamultiply", "shader and blend restored after blit")
  check(bound == arenaCanvas, "blit leaves the arena canvas bound")

  -- no pose given: falls back to the BattleCam pose
  check(Snap.draw(256, 192, nil) == true, "draw without a pose uses BattleCam's")

  -- world fails: blit is a no-op, the failure is logged once
  ground.drawFree = function() error("gpu") end
  logs = {}
  check(Snap.draw(256, 192, pose) == false, "draw reports failure")
  check(Snap.draw(256, 192, pose) == false, "draw reports failure again")
  local n = 0; for _, l in ipairs(logs) do if l:find("native arena world not drawn") then n = n + 1 end end
  check(n == 1, "the same failure is logged once, not every frame")
  check(Snap.blit(256, 192) == false, "no stale world blitted after a failed frame")

  Snap.clear()
  check(Snap.nativeWorld() == false, "clear drops the native flag")

  -- a non-Gen-4 state still takes the voxel path (and still needs voxel)
  local plain = { entities = {}, ghosts = {}, map = {}, player = { cellX = 1, cellY = 1 } }
  check(Snap.capture(nil, plain) == false, "Gen 1-3 with voxel unavailable still declines")
  V.Voxel3D.available = function() return true end
  check(Snap.capture(nil, plain) == true and Snap.nativeWorld() == false, "Gen 1-3 with voxel keeps the voxel path")
end

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
