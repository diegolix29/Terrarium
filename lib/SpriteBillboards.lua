-- Voxel world mode: characters as flat forward-facing sprite billboards.
--
-- Every character -- the player, NPCs, the ghosts standing on a neighbour
-- map -- is its CURRENT 2D sprite frame on a single flat quad. The sheets
-- carry real alpha and the shader discards it, so the quad cuts the
-- sprite's exact silhouette out of itself; no geometry is built from the
-- pixels and nothing about a sprite is voxelized.
--
-- That is deliberate. A sprite is a DRAWING, not an object seen from one
-- side: Gen 1's overworld figures are sprites with a fixed front-on
-- reading, and turning one into a solid -- whether a contoured slab or a
-- carved visual hull -- reconstructs a body the artist never drew and the
-- game never implied. It also had the mod ship a description of the ROM
-- art. One quad wearing the real frame is both more faithful and cheaper:
-- it needs no pixel access at all, only the sheet's dimensions.
--
-- The card always faces SOUTH -- the direction the 2D game implies -- and
-- only LEANS BACK, pivoting at its feet, by exactly the camera's pitch
-- (VoxelScene's billboardMatrix), so at every tilt level it reads face-on
-- like the flat game. Right-facing and the alternating walk step are
-- matrix mirrors, not extra meshes. UVs point into the live sheet image,
-- so RED++ OBP bakes, SGB palette bakes and sprite-replacing mods all
-- texture it with no rebuild.
--
-- The system now supports dynamic sprite dimensions with separate width and
-- height scaling, allowing for custom sprite sizes beyond the original 16x16 pixels.
-- Use def.scale for overall scaling, or def.heightScale for height-specific scaling.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Assets = require("src.render.Assets")
local Voxel3D = V.require("Voxel3D")

local SpriteBillboards = {}

local meshes = {}

-- One flat quad UV-mapped to a whole frame, with dynamic dimensions based on
-- the actual sprite size. A hair of inset keeps the sampler inside this frame
-- rather than picking up the neighbouring one along the shared edge.
local function buildCard(def, frame)
  local img = def.hdImage
  if not img then
    local ok, got = pcall(Assets.image, def.image)
    if ok then img = got end
  end
  if not img then return nil end
  local iw, ih = img:getDimensions()
  local frameWidth = def.hdFrameW or iw
  local frameHeight = def.hdFrameH or (ih / math.max(1, def.frames or 1))
  local scale = def.scale or 1.0
  local heightScale = def.heightScale or scale
  local worldWidth = frameWidth * scale
  local worldHeight = frameHeight * heightScale
  local fy = (frame or 0) * (def.hdFrameH and 0 or frameHeight)
  if fy + frameHeight > ih then fy = 0 end
  local insetX = 0.02
  local insetY = 0.05
  local u0, u1 = insetX / iw, (frameWidth - insetX) / iw
  local v0, v1 = (fy + insetY) / ih, (fy + frameHeight - insetY) / ih
  if def.hdImage then
    u0, u1, v0, v1 = 0, 1, 0, 1
  end
  local verts = {
    { 0, 0, 0, u0, v1, 1 }, { worldWidth, 0, 0, u1, v1, 1 },
    { worldWidth, worldHeight, 0, u1, v0, 1 }, { 0, worldHeight, 0, u0, v0, 1 },
  }
  local indices = {}
  Voxel3D.pushQuad(indices, 0)
  local mesh = Voxel3D.newMesh(verts, indices)
  if mesh and love and love.graphics then
    local filterMode = (scale < 1.0 or heightScale < 1.0) and "linear" or "nearest"
    pcall(function()
      mesh:setTexture(img)
      img:setFilter(filterMode, filterMode, 16)
    end)
  end
  return mesh
end

-- The card for one (sprite def, frame index), or nil (headless / no
-- image), cached like every other derived GPU object.
--
-- The solid draw, the sun pass and the player's occlusion silhouette all
-- take THIS mesh. That the three agree is load-bearing, not tidiness: the
-- silhouette is drawn with the depth test INVERTED, so any self-overlap in
-- the mesh would read as "behind something" and repaint the figure on open
-- ground whether or not anything hides it; and the sun must see the same
-- outline the camera does, or a shadow stops matching what casts it.
--
-- KEYED BY TABLE THEN FRAME, not by a built string.  `def.image .. "#" ..
-- frame` allocated a string on EVERY call -- and this is called once per
-- actor per pass, so a town spent a few hundred short-lived strings a frame
-- just to look something up it already had.  Two table indexes cost nothing
-- and allocate nothing on the hit path.
function SpriteBillboards.mesh(def, frame)
  local key = def.hdImage and def or def.image
  local byFrame = meshes[key]
  if not byFrame then byFrame = {}; meshes[key] = byFrame end
  local cached = byFrame[frame]
  if cached then
    -- HD Reloded animates by swapping the decoded frame image on the same
    -- def; keep the quad and retarget the texture so the card does not stay
    -- on frame 0.
    if def.hdImage then
      pcall(cached.setTexture, cached, def.hdImage)
    end
    return cached
  end
  if cached == false then return nil end
  local ok, m = pcall(buildCard, def, frame)
  byFrame[frame] = (ok and m) or false

  if ok and m then
    local scale = def.scale or 1.0
    local heightScale = def.heightScale or scale
    local img = def.hdImage
    if not img then
      local imgOk, got = pcall(Assets.image, def.image)
      if imgOk then img = got end
    end
    if img then
      SpriteBillboards.setHighQualityFiltering(img, scale, heightScale)
    end
  end
  return byFrame[frame] or nil
end

-- Get the dimensions of a sprite frame for dynamic sizing
-- Returns: textureWidth, textureHeight, worldWidth, worldHeight
--
-- MEASURED ONCE PER SPRITE, not once per card per pass.
--
-- This used to do a pcall into the asset store and a getDimensions() across
-- the graphics boundary EVERY time it was asked -- for every actor, in the
-- eye pass and again in the sun pass.  A town poses well over a hundred
-- actors, so that is several hundred asset lookups and several hundred trips
-- into LOVE per frame, to recompute four numbers that cannot change while
-- the image is loaded.
--
-- `frame` is not part of the answer and never was: every frame of a sheet is
-- the same size (the sheet is divided by def.frames), which is why the
-- parameter is ignored below.  So the cache is keyed on the def table alone.
--
-- Weak-keyed, and dropped wholesale by invalidate() when the asset store
-- reloads -- the same signal that already clears the meshes.
local dims = setmetatable({}, { __mode = "k" })
function SpriteBillboards.getSpriteDimensions(def, frame)
  local img = def.hdImage
  if not img then
    local ok, got = pcall(Assets.image, def.image)
    if ok then img = got end
  end
  local frameWidth = def.hdFrameW
  local frameHeight = def.hdFrameH
  if img and not (frameWidth and frameHeight) then
    local iw, ih = img:getDimensions()
    frameWidth = frameWidth or iw
    frameHeight = frameHeight or (ih / math.max(1, def.frames or 1))
  end
  frameWidth = frameWidth or 16
  frameHeight = frameHeight or 16
  local scale = def.scale or 1.0
  local heightScale = def.heightScale or scale
  local worldWidth = frameWidth * scale
  local worldHeight = frameHeight * heightScale
  local hit = dims[def]
  if hit and hit[5] == img and hit[1] == frameWidth and hit[2] == frameHeight
      and hit[3] == worldWidth and hit[4] == worldHeight then
    return hit[1], hit[2], hit[3], hit[4]
  end
  dims[def] = { frameWidth, frameHeight, worldWidth, worldHeight, img }
  return frameWidth, frameHeight, worldWidth, worldHeight
end

-- Set high-quality texture filtering for scaled sprites
-- This ensures that sprites scaled down to 0.25 or less still look sharp
function SpriteBillboards.setHighQualityFiltering(img, scale, heightScale)
  if not (img and love and love.graphics) then return end
  
  local filterMode = "linear"
  local anisotropy = 16 -- Maximum anisotropic filtering for quality
  
  -- Use the smaller of the two scales for quality determination
  local effectiveScale = math.min(scale or 1.0, heightScale or 1.0)
  
  -- For very small scales, use maximum quality settings
  if effectiveScale < 0.5 then
    anisotropy = 16
  elseif effectiveScale < 0.75 then
    anisotropy = 8
  else
    anisotropy = 4
  end
  
  pcall(function()
    img:setFilter(filterMode, filterMode, anisotropy)
    -- Set mipmap filter for better downscaling quality
    img:setMipmapFilter(filterMode, 0.5) -- 0.5 sharpness balance
  end)
end

-- Get the recommended LOD bias for a sprite based on scale
function SpriteBillboards.getLodBiasForScale(scale)
  local lodBias = 0.0
  if scale < 0.25 then
    lodBias = -2.0  -- Maximum sharpness for very small sprites
  elseif scale < 0.5 then
    lodBias = -1.5  -- High sharpness for small sprites
  elseif scale < 0.75 then
    lodBias = -1.0  -- Moderate sharpness
  else
    lodBias = -0.5  -- Slight sharpness boost
  end
  return lodBias
end

-- Kept as its own name because the shadow and ghost passes read as their
-- own thing at the call sites; it once carried a different mesh from the
-- solid draw, and now deliberately does not.
SpriteBillboards.shadowQuad = SpriteBillboards.mesh

function SpriteBillboards.invalidate()
  meshes = {}
  -- the measurements go with them: a reloaded image may be a different size
  dims = setmetatable({}, { __mode = "k" })
end

Assets.register(SpriteBillboards.invalidate)

return SpriteBillboards
