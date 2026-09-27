-- Conservative view-frustum test for static props (currently: ChunkMesher's
-- authored figures -- couches, signs, standing furniture). Ported from the
-- Voxel Ascendant fork's PropVisibility/PropSpatialIndex pair and trimmed
-- down to what this fork's figures actually need: a translated (never
-- rotated or scaled) static mesh, one per authored figure.
--
-- The test is deliberately conservative in both directions it can be wrong:
-- a missing bound or a matrix that is not a pure translation always keeps
-- the prop (never cull something this module cannot reason about), and a
-- rejected prop's bounds have already been padded by the world curve's worst
-- droop for its distance, so nothing that would actually cross into frame
-- gets skipped. Over-drawing a couch just off-frame is cheap; a couch that
-- silently stops rendering is a bug report.

local M = {}

-- One map's worth of figures rarely changes shape after it is built --
-- ChunkMesher.figures(map) returns the same static list, released as a
-- whole when the map is invalidated -- so this is a correctness-preserving
-- cache, not a heuristic: a mesh's bounds cannot change without the mesh
-- itself changing identity. Weak keys so a released map's meshes are not
-- kept alive by this table alone.
local staticBounds = setmetatable({}, { __mode = "k" })

-- AABB of a static LOVE mesh's vertices, in the mesh's own local space (the
-- space ChunkMesher.buildFigureMeshes builds figure quads in, before the
-- wx/y/wz translation figureMatrix applies at draw time). Only meaningful
-- for a mesh that never changes after creation.
function M.staticMeshBounds(mesh)
  if type(mesh) ~= "table" and type(mesh) ~= "userdata" then return nil end
  if not (mesh.getVertexCount and mesh.getVertex) then return nil end
  local cached = staticBounds[mesh]
  if cached ~= nil then return cached or nil end
  local okCount, count = pcall(mesh.getVertexCount, mesh)
  if not okCount or not count or count == 0 then
    staticBounds[mesh] = false
    return nil
  end
  local b = { math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge }
  for i = 1, count do
    local ok, x, y, z = pcall(mesh.getVertex, mesh, i)
    if not ok then
      staticBounds[mesh] = false
      return nil
    end
    if x < b[1] then b[1] = x end
    if y < b[2] then b[2] = y end
    if z < b[3] then b[3] = z end
    if x > b[4] then b[4] = x end
    if y > b[5] then b[5] = y end
    if z > b[6] then b[6] = z end
  end
  staticBounds[mesh] = b
  return b
end

-- Builds a per-frame `accepts(b, m)` closure from the current camera's
-- view-projection matrix `vp` (Voxel3D.vp -- row-major, see Mat4.lua) plus
-- the world curve's bend constant `k` and its center (Voxel3D.curveK,
-- curveX, curveZ). `b` is a local-space AABB (see staticMeshBounds above)
-- and `m` is the row-major model matrix placing it (see Mat4.lua):
-- translation lives at m[4]/m[8]/m[12], exactly where Mat4.translate puts
-- it, so `Mat4.translate(wx, y, wz)` is a valid `m` on its own.
--
-- No `vp` (camera not set up yet, or a probe with nothing to compare
-- against) means "cannot judge, keep everything".
function M.forView(vp, k, cx, cz)
  if not vp then return function() return true end end

  local planes = {}
  for axis = 0, 2 do
    for _, sign in ipairs({ -1, 1 }) do
      local p = {}
      -- Horizontal planes get a little slack: the world curve bends a prop
      -- down as it recedes, and a straight frustum test with no margin would
      -- clip something the curved projection still draws a sliver of.
      local margin = axis < 2 and 1.05 or 1
      for i = 1, 4 do
        p[i] = vp[12 + i] * margin + sign * vp[axis * 4 + i]
      end
      p[5], p[6], p[7] = p[1] >= 0, p[2] >= 0, p[3] >= 0
      planes[#planes + 1] = p
    end
  end

  k, cx, cz = k or 0, cx or 0, cz or 0
  local function curveRange(lo, hi, c)
    local a, b = lo - c, hi - c
    if a <= 0 and b >= 0 then return 0, math.max(a * a, b * b) end
    return math.min(a * a, b * b), math.max(a * a, b * b)
  end

  return function(b, m)
    if not b or not m then return true end
    -- A rotated or scaled placement is outside what this test reasons
    -- about correctly (see the module comment) -- keep it, and let the
    -- ordinary draw call be the only judge.
    if m[1] ~= 1 or m[2] ~= 0 or m[3] ~= 0 or m[5] ~= 0 or m[6] ~= 1
       or m[7] ~= 0 or m[9] ~= 0 or m[10] ~= 0 or m[11] ~= 1 then
      return true
    end
    local x0, y0, z0 = b[1] + m[4], b[2] + m[8], b[3] + m[12]
    local x1, y1, z1 = b[4] + m[4], b[5] + m[8], b[6] + m[12]

    if k ~= 0 then
      -- Same worst-case droop WorldCurve.drop applies per vertex, but
      -- bounded over the whole box's footprint rather than sampled once, so
      -- the padded box always contains the true curved position.
      local nearX, farX = curveRange(x0, x1, cx)
      local nearZ, farZ = curveRange(z0, z1, cz)
      local near, far = k * (nearX + nearZ), k * (farX + farZ)
      y0, y1 = y0 - math.max(near, far), y1 - math.min(near, far)
    end

    for _, p in ipairs(planes) do
      local far = p[1] * (p[5] and x1 or x0) + p[2] * (p[6] and y1 or y0)
        + p[3] * (p[7] and z1 or z0) + p[4]
      if far < -1e-5 then return false end
    end
    return true
  end
end

return M
