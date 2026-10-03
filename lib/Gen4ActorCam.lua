-- Facing, look, and camera-relative walk for actors on Platinum's own camera.
--
-- Voxel FirstPerson / ThirdPerson / FreeMove key off Voxel.level (the 1ST/3RD
-- tilt rungs) and Voxel3D.camera. Gen4WorldHost never gives that rig the
-- frame: Gen4View draws the world. If those voxel helpers stay in charge,
-- the player model keeps the four-way grid facing and FreeMove steers by
-- the wrong yaw -- or never runs at all.
--
-- This module is the gen4 stand-in for that free-roam flag. The gate is
-- Gen4View mode "third" / "first" (the native 3D chase / head cam), not
-- the voxel pipeline rung. Tilt field3d stays the cartridge camera and
-- keeps grid walking.

local V = ...

local Cam = {}

Cam.bodyYaw = nil

local function host()
  local ok, H = pcall(V.require, "Gen4WorldHost")
  return ok and H or nil
end

function Cam.ground(state)
  local H = host()
  if H and H.groundOf then return H.groundOf(state) end
  return nil
end

function Cam.onGen4(state)
  return Cam.ground(state) ~= nil
end

function Cam.view(ground)
  ground = ground or Cam.ground()
  return ground and ground.view3d or nil
end

function Cam.mode(ground)
  local view = Cam.view(ground)
  return view and view.mode or nil
end

-- True while Gen4View is drawing a real 3D lens (third, first, or field3d).
function Cam.active(ground)
  local view = Cam.view(ground)
  return view and view.isFree and view:isFree() == true
end

-- The voxel 3RD equivalent: camera stands with the player, look is free,
-- walk is camera-relative. field3d is only a tilted cartridge camera.
function Cam.freeRoam(ground)
  local m = Cam.mode(ground)
  return m == "third" or m == "first"
end

function Cam.driving()
  if not Cam.freeRoam() then return false end
  local H = host()
  if H and H._inBattle then return false end
  local ok, FirstPerson = pcall(V.require, "FirstPerson")
  if not (ok and FirstPerson and FirstPerson.onTop) then return false end
  return FirstPerson.onTop() == true
end

function Cam.eye(ground)
  local view = Cam.view(ground)
  if not (view and view.x) then return nil end
  return { view.x, view.y or 0, view.z or 0 }
end

function Cam.lookYaw(ground)
  local view = Cam.view(ground)
  return (view and view.yaw) or 0
end

-- World bearing of the look, in the same atan2(east, south) space a mesh
-- rotateY uses (+Z / yaw 0 = south). Gen4View yaw 0 looks NORTH, so the
-- unrotated FirstPerson formula (sin, cos) does not apply.
function Cam.lookBearing(ground)
  local yaw = Cam.lookYaw(ground)
  return math.atan2(math.sin(yaw), -math.cos(yaw))
end

-- Yaw that turns a +Z (south) card toward the live Gen4View eye.
-- Same convention as FirstPerson.cardYaw and BattleBillboard.yawToward:
-- atan2(east, south) so 0 faces a camera standing south of the actor.
--
-- `wx`/`wz` must be in the SAME space as view.x/view.z (absolute matrix
-- coordinates, including Gen4Ground.offsetX/offsetY).
function Cam.cardYaw(wx, wz, ground)
  local eye = Cam.eye(ground)
  if not eye then return 0 end
  wx, wz = tonumber(wx) or 0, tonumber(wz) or 0
  local dx, dz = eye[1] - wx, eye[3] - wz
  if dx * dx + dz * dz < 1e-9 then return 0 end
  return math.atan2(dx, dz)
end

-- Camera-space (mx right, mz forward) into map (east, south), using
-- Gen4View.yaw. Matches OverworldState's orbited free-walk rotation:
-- screen up becomes the look's forward even before the player has
-- touched orbit (voxel 3RD always does this; the grid path only did it
-- after orbiting, which is why 3rd person still felt like NES walking).
function Cam.moveWorld(mx, mz)
  mx, mz = tonumber(mx) or 0, tonumber(mz) or 0
  local yaw = Cam.lookYaw()
  local c, s = math.cos(yaw), math.sin(yaw)
  return mx * c + mz * s, mx * s - mz * c
end

local function facingOf(a)
  local s, c = math.sin(a), math.cos(a)
  if math.abs(s) > math.abs(c) then
    return s > 0 and "right" or "left"
  end
  return c > 0 and "down" or "up"
end

function Cam.bodyBearing(wx, wz)
  if Cam.mode() == "third" and wx and wz and (wx ~= 0 or wz ~= 0) then
    return math.atan2(wx, wz)
  end
  return Cam.lookBearing()
end

function Cam.pointBody(wx, wz)
  Cam.bodyYaw = Cam.bodyBearing(wx, wz)
  return facingOf(Cam.bodyYaw)
end

function Cam.releaseBody()
  Cam.bodyYaw = nil
end

-- Continuous rotateY for the player mesh while free-roam owns the walk.
function Cam.modelYaw()
  return Cam.bodyYaw or Cam.lookBearing()
end

-- Model rotateY from a WORLD compass facing.
--
-- Gen4's +Z is south. Identity (yaw 0) faces that south look -- the same
-- pose the 2D "down" sheet uses under the cartridge camera. Orbiting the
-- third-person camera must NOT go through view:worldToScreen: that remap
-- is for picking a sprite frame, and feeding it to rotateY locks a mesh
-- onto world-south.
function Cam.worldYaw(facing)
  facing = type(facing) == "string" and string.lower(facing) or facing
  if facing == "right" then return math.pi / 2 end
  if facing == "up" then return math.pi end
  if facing == "left" then return -math.pi / 2 end
  return 0
end

function Cam.facingVector(facing)
  local yaw = Cam.worldYaw(facing)
  return math.sin(yaw), math.cos(yaw)
end

return Cam
