-- STADIUM 2 battles: reading one species' model off disk.
--
-- Similar to StadiumPack but for Pokemon Stadium 2 models (251 Pokemon)

local V = ...

local Stadium2Pack = {}

local byte = string.byte
local floor = math.floor

-- Cache directory for Stadium 2 models (same as Stadium2Install.DIR)
Stadium2Pack.CACHE_DIR = "dramatic_shape"
Stadium2Pack.DIR = "assets/stadium2"

-- LRU cache for loaded models (same as StadiumPack)
local cache = {}
local order = {}
local KEEP = 4

-- Shiny variant naming
local function packName(dir, species, shiny)
  return shiny and ("%s/%03d_shiny.dsm"):format(dir, species)
              or ("%s/%03d.dsm"):format(dir, species)
end

local function cacheKey(species, shiny)
  return shiny and ("%d_shiny"):format(species) or tostring(species)
end

local function touch(key)
  local n = #order
  local i = 1
  while i <= n do
    if order[i] == key then
      table.remove(order, i)
      break
    end
    i = i + 1
  end
  order[#order + 1] = key
end

-- Unpack a DSM4 file (Stadium 2 format)
function Stadium2Pack.unpack(bytes)
  if type(bytes) ~= "string" or #bytes < 16 then
    return nil, "pack too short"
  end

  local magic = bytes:sub(1, 4)
  if magic ~= "DSM3" and magic ~= "DSM4" then
    return nil, "not a DSM3/DSM4 file"
  end

  local pos = 5

  local function u8()
    if pos > #bytes then return nil end
    local v = byte(bytes, pos)
    pos = pos + 1
    return v
  end

  local function u16()
    if pos + 1 > #bytes then return nil end
    local a, b = byte(bytes, pos, pos + 1)
    pos = pos + 2
    return a * 256 + b
  end

  local function i16()
    local v = u16()
    if v == nil then return nil end
    if v >= 0x8000 then return v - 0x10000 end
    return v
  end

  local function u32()
    if pos + 3 > #bytes then return nil end
    local a, b, c, d = byte(bytes, pos, pos + 3)
    pos = pos + 4
    return ((a * 256 + b) * 256 + c) * 256 + d
  end

  local function i32()
    local v = u32()
    if v == nil then return nil end
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end

  local function f32()
    local sign = 1
    local v = u32()
    if v == nil then return nil end
    if v >= 0x80000000 then
      sign = -1
      v = v - 0x80000000
    end
    return sign * (v / 4294967296.0)
  end

  local species = u16()
  local nBones = u16()
  local nPrims = u16()
  local nTextures = u16()
  local nAnims = u16()
  local nAux = u16()
  local rootScale = f32()
  local static = u8()
  local height = f32()
  local floorY = f32()
  local radius = f32()

  -- Validate header reads
  if not species or not nBones or not nPrims or not nTextures or not nAnims or not nAux or not rootScale or static == nil or not height or not floorY or not radius then
    return nil, "truncated file (header incomplete)"
  end
  
  -- Read move table (165 moves)
  local moves = {}
  for i = 1, 165 do
    moves[i] = u16()
  end
  for i = 1, 165 do
    if moves[i] == nil then
      return nil, "truncated file (move table incomplete)"
    end
  end

  -- Read move aux table
  local moveAux = {}
  for i = 1, 165 do
    moveAux[i] = i16()
  end
  for i = 1, 165 do
    if moveAux[i] == nil then
      return nil, "truncated file (move aux table incomplete)"
    end
  end
  
  -- Read context table
  local contexts = {}
  for i = 1, 20 do
    contexts[i] = u16()
  end
  for i = 1, 20 do
    if contexts[i] == nil then
      return nil, "truncated file (context table incomplete)"
    end
  end
  
  -- Read bones
  local bones = {}
  for i = 1, nBones do
    local parent = i16()
    local t = { i16(), i16(), i16() }
    local r = { i16(), i16(), i16() }
    local sx = i32()
    local sy = i32()
    local sz = i32()
    if not parent or not t[1] or not t[2] or not t[3] or not r[1] or not r[2] or not r[3] or not sx or not sy or not sz then
      return nil, "truncated file (bones incomplete)"
    end
    bones[i] = {
      parent = parent,
      t = t,
      r = r,
      s = { sx / 65536.0, sy / 65536.0, sz / 65536.0 }
    }
  end
  
  -- Read primitives
  local prims = {}
  for i = 1, nPrims do
    local tex = u16()
    local cullByte = u8()
    local blendByte = u8()
    local texAnim = i16()
    local nverts = u16()
    local nidx = u16()
    if not tex or cullByte == nil or blendByte == nil or not texAnim or not nverts or not nidx then
      return nil, "truncated file (primitives incomplete)"
    end
    local prim = {
      tex = tex,
      cull = cullByte ~= 0,
      blend = blendByte ~= 0,
      texAnim = texAnim,
      texMap = {},
      fxFrames = {},
      nverts = nverts,
      nidx = nidx
    }

    local nTexMap = u8()
    if nTexMap == nil then
      return nil, "truncated file (primitive texMap count missing)"
    end
    for j = 1, nTexMap do
      local key = u8()
      local value = u16()
      if not key or not value then
        return nil, "truncated file (primitive texMap incomplete)"
      end
      prim.texMap[key] = value
    end

    local nFx = u16()
    if nFx == nil then
      return nil, "truncated file (primitive fx count missing)"
    end
    for j = 1, nFx do
      local fx = u16()
      if not fx then
        return nil, "truncated file (primitive fxFrames incomplete)"
      end
      prim.fxFrames[j] = fx
    end

    prims[i] = prim
  end
  
  -- Read textures
  local textures = {}
  for i = 1, nTextures do
    local w = u16()
    local h = u16()
    if not w or not h then
      return nil, "truncated file (textures incomplete)"
    end
    textures[i] = {
      w = w,
      h = h,
      data = nil
    }
  end
  
  -- Read animations (simplified)
  local anims = {}
  for i = 1, nAnims do
    anims[i] = {
      index = i - 1,
      frames = 1,
      tracks = {}
    }
  end
  
  return {
    species = species,
    bones = bones,
    prims = prims,
    textures = textures,
    anims = anims,
    rootScale = { rootScale, rootScale, rootScale },
    staticPose = static ~= 0,
    height = height,
    floorY = floorY,
    radius = radius,
    moves = moves,
    moveAux = moveAux,
    contexts = contexts
  }
end

local function readPack(species, shiny)
  local rel = packName(Stadium2Pack.CACHE_DIR, species, shiny)
  
  local install = V.require("Stadium2Install")
  local mod = V.mod
  local haveShipped = false
  
  if mod and mod.read then
    local okS, b = pcall(mod.read, mod, packName(Stadium2Pack.DIR, species, shiny))
    haveShipped = okS and type(b) == "string" and #b > 4
  end
  
  if love and love.filesystem and love.filesystem.getInfo
     and (install.ready() or (install.romPresent() and not haveShipped)) then
    local okInfo, info = pcall(love.filesystem.getInfo, rel, "file")
    if okInfo and info then
      local ok, bytes = pcall(love.filesystem.read, rel)
      if ok and type(bytes) == "string" and #bytes > 4 then 
        return bytes 
      end
    end
  end
  
  if haveShipped then
    local ok, bytes = pcall(mod.read, mod, packName(Stadium2Pack.DIR, species, shiny))
    if ok and type(bytes) == "string" and #bytes > 4 then 
      return bytes 
    end
  end
  
  return nil
end

-- Load a Stadium 2 model
function Stadium2Pack.load(species, shiny)
  if type(species) ~= "number" or species < 1 or species > 251 then
    return nil, "invalid species number (must be 1-251)"
  end
  
  local key = cacheKey(species, shiny)
  local hit = cache[key]
  if hit ~= nil then
    -- Don't return false from cache - retry on failure
    if hit == false then
      cache[key] = nil
    else
      touch(key)
      return hit
    end
  end

  local bytes = readPack(species, shiny)
  
  if not bytes then
    V.mod.log:warn("stadium2: %s could not be read (file not found or empty)", packName("", species, shiny):sub(2))
    if shiny then
      return Stadium2Pack.load(species, false)
    end
    cache[key] = false
    return nil
  end

  local ok, model, err = pcall(Stadium2Pack.unpack, bytes)
  if ok and model == nil then
    ok, err = false, err
  end
  if not ok then
    V.mod.log:warn("stadium2: %s did not read: %s -- that Pokemon "
                   .. "falls back to its flat pic",
                   packName("", species, shiny):sub(2), tostring(err or model))
    if shiny then
      cache[key] = false
      return Stadium2Pack.load(species, false)
    end
    cache[key] = false
    return nil
  end
  
  -- LRU management
  while #order > KEEP do
    local old = table.remove(order, 1)
    cache[old] = nil
  end
  cache[key] = model
  touch(key)
  
  return model
end

-- Check if Stadium 2 models are available
function Stadium2Pack.available()
  local ok, install = pcall(V.require, "Stadium2Install")
  return ok and install and install.ready()
end

-- Keep a species in the LRU cache (called by StadiumWilds)
function Stadium2Pack.keep(species, shiny)
  local key = cacheKey(species, shiny)
  if key and cache[key] then touch(key) end
end

-- Invalidate cache (for when packs are rebuilt)
function Stadium2Pack.invalidate()
  cache = {}
  order = {}
end

-- Forget cache (for when ROM is swapped)
function Stadium2Pack.forget()
  Stadium2Pack.invalidate()
end

return Stadium2Pack