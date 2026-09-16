-- GLB MODEL: minimal binary-glTF (.glb) loader.
--
-- Companion to the .obj path in PlayerModel.lua. Parses the first mesh
-- primitive out of a .glb file's JSON + BIN chunks and returns vertex data
-- already shaped for Voxel3D.FORMAT, the same vertex layout objToMesh()
-- builds for OBJ models and terrain chunks share:
--   { "VertexPosition", "float", 3 }
--   { "VertexTexCoord", "float", 2 }
--   { "VertexShade",    "float", 1 }
--   { "VertexWater",    "float", 1 }
--
-- Deliberately narrow: one mesh, one primitive, TRIANGLES, POSITION +
-- (optional) TEXCOORD_0 + indices. That covers a single static follower
-- prop. Skinning/animation is out of scope here -- StadiumRig already
-- owns animated models (see PlayerModel.loadStadium) and a GLB follower
-- swap is meant to be the same kind of static drop-in .obj already is.
--
-- Parsing (parseGLB / buildVertexData) touches no love.* API and can be
-- exercised with a plain `lua` interpreter; only GLBModel.load() needs a
-- real LOVE runtime, for love.graphics.newMesh / newImage.

local V = ...
local JsonDecode = V and V.require and V.require("json_decode") or require("json_decode")

local GLBModel = {}

local GLB_MAGIC = 0x46546C67 -- "glTF"
local CHUNK_JSON = 0x4E4F534A -- "JSON"
local CHUNK_BIN  = 0x004E4942 -- "BIN\0"

local COMPONENT_TYPE_SIZE = {
  [5120] = 1, -- BYTE
  [5121] = 1, -- UNSIGNED_BYTE
  [5122] = 2, -- SHORT
  [5123] = 2, -- UNSIGNED_SHORT
  [5125] = 4, -- UNSIGNED_INT
  [5126] = 4, -- FLOAT
}

local TYPE_COMPONENTS = {
  SCALAR = 1, VEC2 = 2, VEC3 = 3, VEC4 = 4, MAT4 = 16,
}

local function u32(data, offset)
  -- offset is 0-based byte offset. Little-endian.
  local b1, b2, b3, b4 = data:byte(offset + 1, offset + 4)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- Parse the 12-byte GLB header + chunk table. Returns jsonText, binData
-- (binData may be nil for a glTF with no embedded buffer), or nil+error.
local function parseGLB(data)
  if not data or #data < 12 then return nil, nil, "truncated: no header" end
  local magic = u32(data, 0)
  if magic ~= GLB_MAGIC then return nil, nil, "not a glb file (bad magic)" end
  local totalLength = u32(data, 8)
  if totalLength > #data then return nil, nil, "truncated: declared length exceeds file size" end

  local jsonText, binData
  local offset = 12
  while offset + 8 <= #data do
    local chunkLength = u32(data, offset)
    local chunkType = u32(data, offset + 4)
    local chunkStart = offset + 8
    local chunkEnd = chunkStart + chunkLength
    if chunkEnd > #data then return jsonText, binData, "truncated: chunk overruns file" end
    local chunkData = data:sub(chunkStart + 1, chunkEnd)
    if chunkType == CHUNK_JSON then
      jsonText = chunkData
    elseif chunkType == CHUNK_BIN then
      binData = chunkData
    end
    offset = chunkEnd
  end
  if not jsonText then return nil, nil, "no JSON chunk found" end
  return jsonText, binData
end

-- Read `count` little-endian components of `componentType` out of `buf`
-- starting at byte `byteOffset`, `numComponents` per element, honoring an
-- explicit stride (0 = tightly packed).
local function readAccessorArray(buf, byteOffset, componentType, numComponents, count, stride)
  local compSize = COMPONENT_TYPE_SIZE[componentType]
  if not compSize then return nil, "unsupported componentType " .. tostring(componentType) end
  local tightStride = compSize * numComponents
  stride = (stride and stride > 0) and stride or tightStride

  local out = {}
  local pos = 1
  for elem = 0, count - 1 do
    local elemStart = byteOffset + elem * stride
    local vals = {}
    for c = 0, numComponents - 1 do
      local at = elemStart + c * compSize
      local v
      if componentType == 5126 then -- FLOAT
        v = love and love.data and love.data.unpack
          and love.data.unpack("<f", buf, at + 1)
          or string.unpack("<f", buf, at + 1)
      elseif componentType == 5125 then -- UNSIGNED_INT
        v = u32(buf, at)
      elseif componentType == 5123 then -- UNSIGNED_SHORT
        local b1, b2 = buf:byte(at + 1, at + 2)
        v = b1 + b2 * 256
      elseif componentType == 5121 then -- UNSIGNED_BYTE
        v = buf:byte(at + 1)
      else
        return nil, "unsupported componentType " .. tostring(componentType)
      end
      vals[c + 1] = v
    end
    out[elem + 1] = vals
    pos = pos + 1
  end
  return out
end

-- Resolve an accessor by index into a flat array of {x,y,z,...} tables.
local function readAccessor(gltf, bin, accessorIndex)
  local accessor = gltf.accessors and gltf.accessors[accessorIndex + 1]
  if not accessor then return nil, "missing accessor " .. tostring(accessorIndex) end
  local numComponents = TYPE_COMPONENTS[accessor.type]
  if not numComponents then return nil, "unsupported accessor type " .. tostring(accessor.type) end

  local bufferView = gltf.bufferViews and gltf.bufferViews[(accessor.bufferView or 0) + 1]
  if not bufferView then return nil, "accessor has no bufferView (sparse accessors unsupported)" end
  if not bin then return nil, "glb has no BIN chunk to read from" end

  local byteOffset = (bufferView.byteOffset or 0) + (accessor.byteOffset or 0)
  return readAccessorArray(bin, byteOffset, accessor.componentType, numComponents,
    accessor.count, bufferView.byteStride)
end

-- Build Voxel3D.FORMAT-shaped vertex data (array of {x,y,z,u,v,shade,water})
-- from a parsed glTF document's first mesh primitive.
function GLBModel.buildVertexData(gltf, bin)
  if not (gltf and gltf.meshes and gltf.meshes[1]) then
    return nil, "no meshes in glTF document"
  end
  local mesh = gltf.meshes[1]
  local prim = mesh.primitives and mesh.primitives[1]
  if not prim then return nil, "mesh has no primitives" end
  if prim.mode ~= nil and prim.mode ~= 4 then
    return nil, "only TRIANGLES primitives are supported (mode=" .. tostring(prim.mode) .. ")"
  end
  if not (prim.attributes and prim.attributes.POSITION ~= nil) then
    return nil, "primitive has no POSITION attribute"
  end

  local positions, err = readAccessor(gltf, bin, prim.attributes.POSITION)
  if not positions then return nil, "POSITION: " .. tostring(err) end

  local texCoords
  if prim.attributes.TEXCOORD_0 ~= nil then
    texCoords, err = readAccessor(gltf, bin, prim.attributes.TEXCOORD_0)
    if not texCoords then return nil, "TEXCOORD_0: " .. tostring(err) end
  end

  local indices
  if prim.indices ~= nil then
    local rawIdx, idxErr = readAccessor(gltf, bin, prim.indices)
    if not rawIdx then return nil, "indices: " .. tostring(idxErr) end
    indices = {}
    for i, v in ipairs(rawIdx) do indices[i] = v[1] end
  else
    -- Non-indexed: implicit 0,1,2,3,...
    indices = {}
    for i = 0, #positions - 1 do indices[i + 1] = i end
  end

  if #indices % 3 ~= 0 then
    return nil, "index count " .. #indices .. " is not a multiple of 3"
  end

  local vertexData = {}
  for i = 1, #indices do
    local vi = indices[i] -- 0-based glTF index
    local p = positions[vi + 1]
    if not p then return nil, "index " .. vi .. " out of range (positions has " .. #positions .. ")" end
    local tc = texCoords and texCoords[vi + 1]
    vertexData[#vertexData + 1] = {
      p[1], p[2], p[3],           -- x, y, z
      tc and tc[1] or 0,          -- u
      tc and tc[2] or 0,          -- v
      1.0,                        -- shade (flat-lit; matches objToMesh default)
      0.0,                        -- water
    }
  end

  return vertexData, nil, {
    vertexCount = #vertexData,
    triangleCount = #vertexData / 3,
    hasTexCoords = texCoords ~= nil,
  }
end

-- Parse raw .glb bytes all the way to Voxel3D-ready vertex data + the
-- decoded glTF JSON (callers use the JSON to go pull out an embedded
-- texture, base color, etc). No love.* dependency.
function GLBModel.parse(data)
  local jsonText, bin, headerErr = parseGLB(data)
  if not jsonText then return nil, nil, headerErr or "failed to parse glb header" end

  local gltf, jsonErr = JsonDecode.decode(jsonText)
  if not gltf then return nil, nil, "bad JSON chunk: " .. tostring(jsonErr) end

  local vertexData, buildErr, stats = GLBModel.buildVertexData(gltf, bin)
  if not vertexData then return nil, gltf, buildErr end

  return vertexData, gltf, nil, stats
end

-- Full load: parse + hand off to love.graphics.newMesh, matching the
-- return contract PlayerModel.load()'s OBJ branch uses (mesh, texture).
-- Requires a real LOVE runtime; call GLBModel.parse() directly to test
-- the parsing logic headless.
function GLBModel.load(data, Voxel3D)
  local vertexData, gltf, err, stats = GLBModel.parse(data)
  if not vertexData then return nil, nil, err end

  if not (love and love.graphics and love.graphics.newMesh) then
    return nil, nil, "no love.graphics available", stats
  end
  local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, vertexData, "triangles")
  if not ok then return nil, nil, "love.graphics.newMesh failed: " .. tostring(mesh), stats end

  -- Embedded base color texture, if the glb ships one (image referenced
  -- by the first material, pulled from bufferView -> image, PNG/JPEG).
  local texture = nil
  -- (Left for a follow-up: GLB image extraction. A follower without an
  -- embedded texture still renders -- untextured, shaded by VertexShade --
  -- same fallback objToMesh leaves for a texture-less OBJ.)

  return mesh, texture, nil, stats
end

return GLBModel
