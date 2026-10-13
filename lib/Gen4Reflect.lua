-- Gen4Reflect: the voxel scene's water reflections, on Gen 4's water.
--
-- WHERE THE REFLECTION COMES FROM
--
-- It is not in the water. It is RayFX (the "RTX" row, RT and MAX): a screen
-- pass that runs over the finished frame, marches a ray across the DEPTH
-- buffer, and reflects wherever it decides a pixel is water. RayFX decides by
-- HEIGHT alone -- "the only class in the shape profile that stands below
-- zero" -- so a band of Y around the voxel scene's recessed water. Gen 4's
-- water is at whatever height the artist put it, so nothing there ever fell in
-- the band and the pass reflected nothing.
--
-- WHAT THIS DOES
--
--   1. Gen 4's depth buffer is made READABLE (the engine makes it write-only;
--      a pass cannot sample a depth it is writing). Gen4Model.newTarget is
--      wrapped to hand back a readable twin of the depth it would have made.
--   2. Each frame, once Gen4Bridge's effects are drawn and before the engine
--      blits the picture, RayFX.apply runs over the Gen 4 colour + depth with
--      its water band moved to Gen4Water's sheet (GW.level), then the result
--      is copied back into the colour canvas the engine is about to blit.
--
-- Everything else about the reflection -- what it reflects, the swell-leaning
-- normal, the fresnel, rain, the sky, the RTX row that turns it OFF / AO / RT /
-- MAX -- is RayFX's own, so it behaves as it does in Gen 1-3.
--
-- LIMITS
--
--   * It runs only at RT and MAX (RayFX.level). AO is part of the same pass and
--     comes with it: there is no way to ask RayFX for the reflection alone.
--   * ONE water height per frame: the sheet nearest the camera. A second lake
--     at another height in the same view is not reflected.
--   * If the driver will not give a readable depth canvas, nothing changes.

local V = ...

local R = {
  enabled = true,
  installed = false,
  BAND_ABOVE = 0.5,   -- world units above the swell's crest that still count as water
}

local readable = setmetatable({}, { __mode = "k" })    -- depth canvas -> true
local warned = {}
local function once(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if V.mod and V.mod.log then V.mod.log:info("Gen4Reflect: " .. fmt:format(...)) end
end

local function optional(name)
  local ok, mod = pcall(V.require, name)
  return ok and mod or nil
end

-- -------------------------------------------------------- readable depth --

local function wrapNewTarget(Model)
  local original = Model.newTarget
  R.originalNewTarget = original
  Model.newTarget = function(w, h, ...)
    local colour, depth = original(w, h, ...)
    if not (R.enabled and colour and depth) then return colour, depth end
    local okF, format = pcall(depth.getFormat, depth)
    if not (okF and format) then return colour, depth end
    local ok, twin = pcall(love.graphics.newCanvas, w, h,
                           { format = format, readable = true })
    if not (ok and twin) then
      once("depth", "the driver will not give a readable %s depth canvas -- "
           .. "Gen 4 water reflections are off", tostring(format))
      return colour, depth
    end
    if depth.release then pcall(depth.release, depth) end
    readable[twin] = true
    return colour, twin
  end
end

-- ------------------------------------------------------------- the pass --

-- True while Gen4WorldHost.renderPose is drawing the Colosseum overworld arena's
-- backdrop world. That world is drawn every frame at arena resolution, and a
-- full-screen RayFX march on top of it was the most expensive thing in the
-- frame, so the reflection is left to the overworld's own pass.
local function inArenaPass()
  local Host = optional("Gen4WorldHost")
  return Host ~= nil and type(Host.inPose) == "function" and Host.inPose() or false
end

function R.run(ground, view, vw, vh)
  if not R.enabled then return end
  if inArenaPass() then return end
  local RayFX = optional("RayFX")
  if not (RayFX and RayFX.level and RayFX.apply) then return end
  local level = RayFX.level()
  if level ~= "rt" and level ~= "max" then return end

  local Bridge = optional("Gen4Bridge")
  if Bridge and Bridge.disabled and Bridge.disabled.water then return end
  local GW = optional("Gen4Water")
  local y = GW and GW.level
  if not tonumber(y) then return end            -- no water in view

  if not (ground.liveTargetFor and ground.freeW and ground.freeH) then return end
  local colour, depth = ground:liveTargetFor(ground.freeW, ground.freeH)
  if not (colour and depth) then return end
  if not readable[depth] then
    once("unreadable", "the Gen 4 depth buffer was made before Gen4Reflect installed "
         .. "-- Gen 4 water reflections are off")
    return
  end
  local w, h = ground.freeW, ground.freeH
  local vp = view:matrix(w, h)
  if not vp then return end

  local Water = optional("Water")
  local swell = (Water and Water.swell and Water.swell()) or 0

  -- move RayFX's water band onto the sheet for this one call
  local keepY, keepBase = RayFX.WATER_Y, RayFX.WATER_BASE
  RayFX.WATER_Y = y + swell + R.BAND_ABOVE
  RayFX.WATER_BASE = y
  local g = love.graphics
  g.setCanvas()                                  -- let go of colour + depth
  local ok, out = pcall(RayFX.apply, {
    canvas = colour,
    depth = depth,
    vp = vp,
    eye = { view.x, view.y, view.z },
    slot = "gen4",
    w = w, h = h,
    sky = nil,
    body = nil,
    curve = { 0, 0, 0 },                         -- Gen 4 draws a flat world
  })
  RayFX.WATER_Y, RayFX.WATER_BASE = keepY, keepBase
  if not ok then
    R.enabled = false
    once("apply", "RayFX failed on the Gen 4 frame and was switched off: %s", tostring(out))
    return
  end
  if not out then return end                     -- RayFX declined: leave the frame

  -- copy the processed frame back where the engine is about to blit from
  local prevBlend, prevAlpha = g.getBlendMode()
  local okCopy, errCopy = pcall(function()
    g.setCanvas(colour)
    g.setShader()
    g.setColor(1, 1, 1, 1)
    g.setBlendMode("replace", "premultiplied")
    g.draw(out, 0, 0)
  end)
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setCanvas()
  if not okCopy then
    R.enabled = false
    once("copy", "copying the reflected frame back failed and Gen4Reflect was switched off: %s",
         tostring(errCopy))
  end
end

-- --------------------------------------------------------------- install --

function R.install()
  if R.installed then return true end
  local okM, Model = pcall(require, "src.render.Gen4Model")
  if not (okM and type(Model) == "table" and type(Model.newTarget) == "function") then
    return false
  end
  local Bridge = optional("Gen4Bridge")
  if not (Bridge and Bridge.after) then return false end
  wrapNewTarget(Model)
  Bridge.after[#Bridge.after + 1] = R.run
  R.Model, R.Bridge = Model, Bridge
  R.installed = true
  return true
end

function R.uninstall()
  if not R.installed then return end
  R.Model.newTarget = R.originalNewTarget
  for i, fn in ipairs(R.Bridge.after) do
    if fn == R.run then table.remove(R.Bridge.after, i); break end
  end
  R.installed = false
end

return R
