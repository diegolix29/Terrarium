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
             placed = self.cameraPlaced, inBattle = Host._inBattle, poseDraw = Host._poseDraw, w = w, h = h,
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
  check(seen.poseDraw == true, "Host._poseDraw set during the draw")
  check(seen.entities == 0, "overworld cast hidden during the draw")
  check(state.entities == origEnt and state.ghosts == origGh, "cast restored by identity")
  check(existing.mode == "field3d" and existing.x == 1 and existing.y == 2 and existing.z == 3
        and existing.yaw == 0.5 and existing.pitch == 12 and existing.fovY == 50, "player's view restored exactly")
  check(ground.cameraPlaced == false, "cameraPlaced restored")
  check(Host._inBattle == false, "_inBattle cleared")
  check(Host._poseDraw == false and Host.inPose() == false, "_poseDraw cleared after the draw")
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
  local clockT = 100
  love.timer = { getTime = function() return clockT end }
  engine["src.core.Game"] = { stack = { states = { { isOverworld = true, isOpaque = false }, { isOpaque = false } },
                                         visibleBase = function() return 1 end } }
  V.Gen4Bridge = { stats = { runs = 0, pres = 0 } }
  local gs = 0
  love.graphics.getStats = function()
    gs = gs + 7
    return { drawcalls = gs, canvasswitches = 0, shaderswitches = 0, texturememory = 5 * 1024 * 1024, canvases = 3, images = 9 }
  end
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
  local mainRequireOf = { Gen4WorldHost = Host, Gen4Bridge = V.Gen4Bridge }
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
  local stackLine
  for _, l in ipairs(logs) do if l:find("Gen4 arena stack:") then stackLine = l end end
  check(stackLine and stackLine:find("depth 2") and stackLine:find("visibleBase 1")
        and stackLine:find("%(overworld%)") and stackLine:find("drawn under the arena: YES"),
        "first arena frame logs the stack and says the overworld is drawn under it")
  check(seen.w == 256 and seen.h == 192, "world drawn at the full arena size by default")
  check(Snap.field().worldSize[1] == 256 and Snap.field().worldSize[2] == 192, "render size remembered")

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

  -- world reuse: count real renders through the engine's drawFree
  local n0 = 0
  local innerDraw = ground.drawFree
  ground.drawFree = function(self, w, h)
    n0 = n0 + 1; V.Gen4Bridge.stats.runs = V.Gen4Bridge.stats.runs + 1
    return innerDraw(self, w, h)
  end
  Snap.REFRESH = 0.25
  clockT = clockT + 1                       -- expire whatever is cached
  check(Snap.draw(256, 192, pose) == true and n0 == 1, "an expired cache re-renders")
  for _ = 1, 5 do Snap.draw(256, 192, pose) end
  check(n0 == 1, "a static pose reuses the world instead of re-rendering")
  check(Snap.field().worldColour ~= nil, "reused world is still available to blit")
  clockT = clockT + 0.1; Snap.draw(256, 192, pose)
  check(n0 == 1, "still reused inside REFRESH")
  clockT = clockT + 0.2; Snap.draw(256, 192, pose)
  check(n0 == 2, "re-rendered once REFRESH has passed")
  local moved = { eye = { 10.5, 40, 90 }, focus = pose.focus, fov = pose.fov }
  Snap.draw(256, 192, moved)
  check(n0 == 3, "a moved camera re-renders at once")
  local drift = { eye = { 10.51, 40, 90 }, focus = pose.focus, fov = pose.fov }
  Snap.draw(256, 192, drift)
  check(n0 == 3, "drift under POSE_EPS keeps the cached world")
  Snap.draw(128, 96, drift)
  check(n0 == 4, "a new canvas size re-renders")
  Snap.REFRESH = 0
  Snap.draw(128, 96, drift); Snap.draw(128, 96, drift)
  check(n0 == 6, "REFRESH = 0 renders every frame (the old behaviour)")
  Snap.WORLD_SCALE = 0.5
  Snap.draw(256, 192, drift)
  check(seen.w == 128 and seen.h == 96, "WORLD_SCALE = 0.5 renders at half size")
  Snap.WORLD_SCALE = 1

  -- an fov helper that depends on canvas height: the mismatch is reported once
  ground.view3d.effectiveFovY = function(self, hh) return self.fovY * hh / 200 end
  logs = {}
  Snap.draw(256, 192, { eye = { 12, 40, 90 }, focus = pose.focus, fov = pose.fov })
  Snap.draw(256, 192, { eye = { 14, 40, 90 }, focus = pose.focus, fov = pose.fov })
  local fovLogs = 0; for _, l in ipairs(logs) do if l:find("FOV mismatch") then fovLogs = fovLogs + 1 end end
  check(fovLogs == 1, "a world/actor fov mismatch is logged once")
  ground.view3d.effectiveFovY = function(self) return self.fovY end
  Snap.field().fovWarned = nil; logs = {}
  Snap.draw(256, 192, { eye = { 16, 40, 90 }, focus = pose.focus, fov = pose.fov })
  fovLogs = 0; for _, l in ipairs(logs) do if l:find("FOV mismatch") then fovLogs = fovLogs + 1 end end
  check(fovLogs == 0, "no warning when the helper matches the pose fov")
  logs = {}
  clockT = clockT + 6
  Snap.draw(256, 192, drift)
  local sofar
  for _, l in ipairs(logs) do if l:find("Gen4 arena world %(so far%)") then sofar = l end end
  check(sofar ~= nil, "running totals are logged every few seconds, not only at the end")
  local st = Snap.stats()
  check(st and st.frames > 0 and st.renders + st.reuses == st.frames, "every successful frame is counted as render or reuse")

  -- world fails: blit is a no-op, the failure is logged once
  Snap.REFRESH = 0
  ground.drawFree = function() error("gpu") end
  logs = {}
  check(Snap.draw(256, 192, pose) == false, "draw reports failure")
  check(Snap.draw(256, 192, pose) == false, "draw reports failure again")
  local n = 0; for _, l in ipairs(logs) do if l:find("native arena world not drawn") then n = n + 1 end end
  check(n == 1, "the same failure is logged once, not every frame")
  check(Snap.blit(256, 192) == false, "no stale world blitted after a failed frame")

  Snap.clear()
  check(Snap.nativeWorld() == false, "clear drops the native flag")
  local summary
  for _, l in ipairs(logs) do if l:find("Gen4 arena world %(fight over%)") and l:find("world renders") then summary = l end end
  check(summary ~= nil, "clear logs the per-fight summary")
  check(summary and summary:find("world renders") and summary:find("overworld world passes"), "summary names renders and overworld passes")
  local bl, gl
  for _, l in ipairs(logs) do
    if l:find("Gen4Bridge.run x") then bl = l end
    if l:find("a world render costs") then gl = l end
  end
  check(bl and bl:find("Gen4Bridge.run x" .. n0 .. " and"), "summary reports how often Bridge.run ran during the fight")
  check(gl and gl:find("7 draw calls") and gl:find("GPU textures 5.0 MB"), "summary reports draw calls per world render and GPU texture memory")
  engine["src.core.Game"].stack.visibleBase = function() return 2 end
  check(Snap.capture(nil, state) == true, "capture again for the stack check")
  logs = {}
  Snap.draw(256, 192, pose)
  local no
  for _, l in ipairs(logs) do if l:find("drawn under the arena: no") then no = true end end
  check(no, "an opaque state above the overworld is reported as not drawn under the arena")
  Snap.clear()

  -- a non-Gen-4 state still takes the voxel path (and still needs voxel)
  local plain = { entities = {}, ghosts = {}, map = {}, player = { cellX = 1, cellY = 1 } }
  check(Snap.capture(nil, plain) == false, "Gen 1-3 with voxel unavailable still declines")
  V.Voxel3D.available = function() return true end
  check(Snap.capture(nil, plain) == true and Snap.nativeWorld() == false, "Gen 1-3 with voxel keeps the voxel path")
end

-- 6. the overworld's own passes are counted; renderPose's are not ------------------
do
  local n = 0
  local G = { drawFree = function() n = n + 1; return true end, endFree = function() end }
  local saved = engine["src.render.Gen4Ground"]
  engine["src.render.Gen4Ground"] = G
  local H2 = assert(loadfile(ROOT .. "Gen4WorldHost.lua"))(V)
  check(H2.install() == true, "install hooks a stub ground")
  G.drawFree({}, 10, 10); G.drawFree({}, 10, 10)
  check(H2.stats.draws == 2, "the overworld's own passes are counted")
  H2._drawFree({}, 10, 10)
  check(H2.stats.draws == 2 and n == 3, "the unwrapped drawFree renderPose uses is not counted")
  engine["src.render.Gen4Ground"] = saved
end

-- 7. Gen4Reflect stands down during the arena's world pass --------------------------
do
  local lvl = 0
  local Vr = { mod = V.mod, pose = true }
  Vr.require = function(name)
    if name == "Gen4WorldHost" then return { inPose = function() return Vr.pose end } end
    if name == "RayFX" then return { level = function() lvl = lvl + 1; return "off" end, apply = function() end } end
  end
  local R = assert(loadfile(ROOT .. "Gen4Reflect.lua"))(Vr)
  R.run({}, {}, 1, 1)
  check(lvl == 0, "Gen4Reflect does nothing inside the arena's world pass")
  Vr.pose = false
  R.run({}, {}, 1, 1)
  check(lvl == 1, "Gen4Reflect still runs in the overworld's own pass")
end

-- 8. Gen4Cull: only ever says "no" for a sphere well outside the view ----------------
do
  local Cull = assert(loadfile(ROOT .. "Gen4Cull.lua"))()
  local see = Cull.sphereTest({ 0, 50, 0 }, { 0, 0, -1 }, math.rad(50), 4 / 3)
  check(see(0, 0, -1000, 100) == true, "a sphere dead ahead is visible")
  check(see(600, 0, -1000, 300) == true, "a big sphere straddling the view edge is kept")
  check(see(0, 0, 1000, 100) == false, "a sphere behind the camera is culled")
  check(see(1000, 0, 0, 100) == false, "a sphere far off to the side is culled")
  check(see(10, 0, 5, 200) == true, "a sphere containing the eye is always visible")
  local down = Cull.sphereTest({ 0, 500, 0 }, { 0, -1, 0 }, math.rad(50), 1)
  check(down(0, 0, 0, 100) == true and down(0, 1000, 0, 100) == false, "looking straight down: ground visible, sky behind culled")
  local dflt = function(f) return f(0, 0, 1000, 1) == true end
  check(dflt(Cull.sphereTest(nil, { 0, 0, -1 }, 1, 1)), "no eye: nothing is culled")
  check(dflt(Cull.sphereTest({ 0, 0, 0 }, { 0, 0, 0 }, 1, 1)), "zero forward: nothing is culled")
  check(dflt(Cull.sphereTest({ 0, 0, 0 }, { 0, 0, -1 }, nil, 1)), "no fov: nothing is culled")
  check(dflt(Cull.sphereTest({ 0, 0, 0 }, { 0, 0, -1 }, math.pi, 1)), "180 degree fov: nothing is culled")
end

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
