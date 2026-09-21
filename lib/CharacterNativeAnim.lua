-- lib/CharacterNativeAnim.lua
--
-- Plays the extracted Colosseum "native_v1" trainer animation tracks on the
-- overworld player mesh (see PlayerModel.loadColosseumCharacter).
--
-- WHAT THE CACHE CONTAINS
--   cache/trainers/<id>/native_v1/index.lua      -- clip table, per role
--   cache/trainers/<id>/native_v1/<role>_NN.f32  -- one file per MESH GROUP
--
-- The NN in <role>_NN is the mesh-group number, NOT a variant number:
-- idle_01 .. idle_16 are the sixteen material groups of the ONE idle clip.
-- Each file holds every frame of that clip for that group, back to back:
--     frame 0: vertex 1..V  (px py pz nx ny nz)   -- 6 float32 = 24 bytes
--     frame 1: vertex 1..V  ...
-- (written by extract/TrainerExtractor.lua writeNativeTracks; the vertex
-- order is the same as the rest-pose groups in model_cache.lua, which is
-- what lets a frame be dropped straight over the rest pose.)
--
-- WHY THIS IS ITS OWN MODULE
-- The battle renderer's TrainerMorph.trackSample/loadTracks are only
-- reachable from the Colosseum namespace, and they drive a battle-only
-- shader. PlayerModel gets the plain mod namespace, so it cannot see them
-- (V.TrainerMorph is nil there). This module re-implements just the clock
-- (same rules as TrainerMorph.sourceFps/trackSample) and the vertex upload.
--
-- VERTEX UPLOAD
-- The overworld character mesh uses Voxel3D.FORMAT (pos3, uv2, shade, water
-- = 7 floats). Each group keeps one ByteData "stage" in that layout with the
-- constant UV/shade/water columns filled once; a tick only rewrites the
-- three position floats per vertex (linear blend of the two neighbouring
-- source frames) through an FFI pointer and uploads the stage with a single
-- Mesh:setVertices. No per-frame Lua tables, no per-frame file reads. This
-- is the same FFI + ByteData pattern lib/ChunkMesher.lua already relies on.
-- Without FFI the module reports why and leaves the rest pose alone.

local V = ...
local GeneratedAssets = V.require("GeneratedAssets")

local M = {}

local ffi = nil
do
  local ok, mod = pcall(require, "ffi")
  if ok then ffi = mod end
end

local SRC_FLOATS = 6   -- px py pz nx ny nz, per vertex per frame
local DST_FLOATS = 7   -- Voxel3D.FORMAT: pos3, uv2, shade, water
local DST_BYTES = DST_FLOATS * 4
local MAX_DT = 0.1     -- a hitch (loading, alt-tab) must not skip half the loop
local MIN_STEP = 0.05  -- source frames; below this a re-upload changes nothing
                       -- visible, which also absorbs a second draw() in one
                       -- frame (shadow pass) so it costs nothing

-- ------- support check

function M.supported()
  if not ffi then return false, "ffi unavailable" end
  if not (love and love.data and love.data.newByteData) then
    return false, "love.data.newByteData unavailable"
  end
  return true
end

-- ------- clock (mirrors TrainerMorph.sourceFps / trackSample)

-- GC6E01 People actors run their HSD bank at half rate; the first native_v1
-- extractor labelled that clock 60 fps. TrainerMorph treats exactly that
-- legacy value as 30 -- the player has to agree or it plays at double speed.
local function sourceFps(index)
  local fps = tonumber(index and index.fps) or 30
  if tonumber(index and index.version) == 1 and fps == 60 then return 30 end
  return fps > 0 and fps or 30
end

-- Returns the two frame slots (0-based) to blend and the blend factor.
local function frameFor(role, seconds, fps)
  local frame = (math.max(0, seconds) * fps) % role.endFrame
  local a = math.min(math.floor(frame), role.count - 2)
  local b = a + 1
  local span = math.min(b, role.endFrame) - a
  local u = span > 0 and (frame - a) / span or 0
  if u < 0 then u = 0 elseif u > 1 then u = 1 end
  return frame, a, b, u
end

-- ------- loading

local function buildRole(id, roleName, clip, groups, dataByPath)
  if type(clip) ~= "table" then return nil, roleName .. ": no clip" end
  local count = tonumber(clip.count)
  local endFrame = tonumber(clip.endFrame)
  if not count or count < 2 or not endFrame or endFrame <= 0 then
    return nil, roleName .. ": bad frame count/length"
  end
  if type(clip.groups) ~= "table" then return nil, roleName .. ": no group list" end

  local states = {}
  for _, group in ipairs(groups) do
    local n = group.baseVertices and #group.baseVertices or 0
    local cg = clip.groups[group.srcIndex]
    if n > 0 then
      if type(cg) ~= "table" or type(cg.path) ~= "string" then
        return nil, ("%s: no track for group %s"):format(roleName, tostring(group.srcIndex))
      end
      if tonumber(cg.vertices) ~= n then
        return nil, ("%s: group %s has %s track vertices, mesh has %d")
          :format(roleName, tostring(group.srcIndex), tostring(cg.vertices), n)
      end
      local data = dataByPath[cg.path]
      if data == nil then
        data = GeneratedAssets.read(cg.path)
        if type(data) ~= "string" then
          return nil, ("%s: cannot read %s"):format(roleName, cg.path)
        end
        dataByPath[cg.path] = data
      end
      local want = n * SRC_FLOATS * 4 * count
      if #data ~= want then
        return nil, ("%s: %s is %d bytes, expected %d"):format(roleName, cg.path, #data, want)
      end

      -- One stage per group and role: UV/shade/water never change.
      local stage = love.data.newByteData(n * DST_BYTES)
      local out = ffi.cast("float*", stage:getFFIPointer())
      for i = 0, n - 1 do
        local uv = group.baseUVs and group.baseUVs[i + 1]
        local o = i * DST_FLOATS
        out[o + 3] = uv and uv[1] or 0
        out[o + 4] = uv and uv[2] or 0
        out[o + 5] = 1.0
        out[o + 6] = 0.0
      end
      states[#states + 1] = {
        mesh = group.mesh, n = n, data = data,  -- `data` anchors the pointer
        src = ffi.cast("const float*", data), stage = stage, out = out,
      }
    end
  end
  if #states == 0 then return nil, roleName .. ": nothing to animate" end
  return { count = count, endFrame = endFrame, groups = states, lastFrame = nil }
end

-- Load the requested roles (default: idle) for a character whose mesh groups
-- were built by PlayerModel.loadColosseumCharacter. Every group table must
-- carry `mesh`, `baseVertices`, `baseUVs` and `srcIndex` (its position in the
-- ORIGINAL cache.groups list -- PlayerModel skips empty groups, so its own
-- array index is not the track's group number).
-- Returns an animation handle, or nil plus a reason.
function M.load(id, groups, wantedRoles)
  local ok, why = M.supported()
  if not ok then return nil, why end
  if type(id) ~= "string" or id == "" or type(groups) ~= "table" then
    return nil, "bad arguments"
  end

  local path = ("cache/trainers/%s/native_v1/index.lua"):format(id)
  local index, err = GeneratedAssets.readLua(path)
  if type(index) ~= "table" or tonumber(index.version) ~= 1 or type(index.roles) ~= "table" then
    return nil, tostring(err or ("no native_v1 index for " .. id))
  end

  local anim = { id = id, fps = sourceFps(index), roles = {}, time = 0, dirty = true }
  local dataByPath = {}   -- aliased roles (gesture = idle ...) share files
  local firstFail
  for _, roleName in ipairs(wantedRoles or { "idle" }) do
    local role, roleErr = buildRole(id, roleName, index.roles[roleName], groups, dataByPath)
    if role then anim.roles[roleName] = role else firstFail = firstFail or roleErr end
  end
  if next(anim.roles) == nil then
    M.release(anim)
    return nil, firstFail or "no usable roles"
  end
  return anim
end

function M.hasRole(anim, roleName)
  return anim ~= nil and anim.roles[roleName] ~= nil
end

-- ------- playback

-- Forget the playhead. Call whenever something else (the walk cycle, a hop)
-- has written to the meshes, so the next tick restarts the clip at frame 0 and
-- always uploads it rather than trusting the last frame it remembers.
function M.reset(anim)
  if not anim then return end
  anim.time = 0
  anim.lastT = nil
  anim.dirty = true
end

local function nowSeconds()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

-- Advance the clip by real elapsed time and upload the resulting pose.
-- Returns true if the meshes were rewritten this call.
function M.tick(anim, roleName)
  local role = anim and anim.roles[roleName or "idle"]
  if not role then return false end

  local t = nowSeconds()
  local dt = anim.lastT and (t - anim.lastT) or 0
  anim.lastT = t
  if dt < 0 then dt = 0 elseif dt > MAX_DT then dt = MAX_DT end
  anim.time = anim.time + dt

  local frame, a, b, u = frameFor(role, anim.time, anim.fps)
  local last = role.lastFrame
  if not anim.dirty and last and math.abs(frame - last) < MIN_STEP then
    return false
  end
  role.lastFrame = frame
  anim.dirty = false

  local aOff, bOff = a * SRC_FLOATS, b * SRC_FLOATS
  for gi = 1, #role.groups do
    local g = role.groups[gi]
    local n, out = g.n, g.out
    local pa = g.src + aOff * n
    local pb = g.src + bOff * n
    for i = 0, n - 1 do
      local s, o = i * SRC_FLOATS, i * DST_FLOATS
      local ax, ay, az = pa[s], pa[s + 1], pa[s + 2]
      out[o]     = ax + (pb[s]     - ax) * u
      out[o + 1] = ay + (pb[s + 1] - ay) * u
      out[o + 2] = az + (pb[s + 2] - az) * u
    end
    g.mesh:setVertices(g.stage, 1)
  end
  return true
end

-- ------- teardown

function M.release(anim)
  if not anim then return end
  for _, role in pairs(anim.roles or {}) do
    for _, g in ipairs(role.groups or {}) do
      if g.stage and g.stage.release then pcall(g.stage.release, g.stage) end
      g.stage, g.out, g.src, g.data, g.mesh = nil, nil, nil, nil, nil
    end
  end
  anim.roles = {}
end

-- Exposed for tests / diagnostics.
M._frameFor = frameFor
M._sourceFps = sourceFps

return M
