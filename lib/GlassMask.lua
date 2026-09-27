-- Voxel world mode: the glass in the windows, found rather than listed.
--
-- Buildings and doors in the overworld art carry small panes -- framed in
-- black, with a diagonal shine drawn in. This module finds them by SHAPE in
-- the tileset image itself: a border row of black texels, some rows of
-- black-flanked non-black glass under it, and a closing border row. No tile
-- ids are hardcoded, so a total conversion that draws its own windows in
-- the same idiom gets glass for free, and art with no windows gets an empty
-- mask and costs nothing.
--
-- "Some rows" of "a" width covers most of what's out there (see WIDTHS and
-- ROWS_MIN/ROWS_MAX below), but not everything: a handful of real panes are
-- drawn in ways the shape rules still can't safely generalize to without
-- also catching art that isn't glass (see the MANUAL table -- each entry
-- there was checked by hand against the actual tileset, not guessed).
--
-- The scan slides at PIXEL granularity because the art does: the building
-- window sits a row down inside its tile, and the door's pane straddles a
-- 2x2 tile block entirely -- a per-tile matcher finds neither.
--
-- What the scan yields is a MASK TEXTURE the same size as the tileset
-- atlas: opaque white on glass texels, transparent everywhere else. Terrain
-- meshes sample the atlas by normalized coordinates (ChunkMesher.uvRect),
-- so the scene shader can sample this mask with the SAME coordinates and
-- know, per fragment, whether it is drawing glass -- on any wall, at any
-- angle, in free-roam or a staged battle, with no geometry work anywhere.
-- The recoloured atlases (display modes, RED++) keep the tileset's layout,
-- so the alignment holds under every palette.
--
-- What the shader does with the answer (Voxel3D): by day a thin glint
-- sweeps across the panes -- a pseudo reflection, view-anchored, preserving
-- the art under it -- and after dark the panes are LIT: the texel's own
-- shine pattern, warmed and brightened, exempt from the sun, the shadow
-- map and the hour's tint, as a window with a lamp behind it is.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Assets = require("src.render.Assets")

-- Gen 3/FRLG: found by CATALOG, not by shape (see GEN3 WINDOWS below).
local okG3, Gen3 = pcall(V.require, "Gen3")
if not okG3 or type(Gen3) ~= "table" then Gen3 = { isGen3 = function() return false end } end
local okWM, WindowMetatiles = pcall(V.require, "Gen3WindowMetatiles")
if not okWM then WindowMetatiles = nil end

local GlassMask = {}

-- pane geometry the scan accepts. Kanto's simplest door/building panes are
-- six glass texels across with 4 or 5 rows between the two border rows, but
-- that turned out to be the FLOOR of what the art actually draws, not the
-- whole of it: Johto (and a couple of spots in Kanto itself) use wider
-- panes, taller multi-storey panes with no black divider between floors,
-- and small accent windows. Rather than one fixed width and two exact row
-- counts, the scan now tries a short list of widths and accepts any row
-- count in a range -- still found by shape, still no tile ids hardcoded.
GlassMask.WIDTHS = { 6, 8 }      -- glass texels across a pane
GlassMask.ROWS_MIN = 3
GlassMask.ROWS_MAX = 16

-- kept for anything still reading the old names
GlassMask.GLASS_W = GlassMask.WIDTHS[1]
GlassMask.ROWS = { 4, 5 }

-- Whether a channel triple is the border black. The raw tileset art is the
-- four DMG greys, so black is genuinely zero; the threshold forgives a
-- rescaled asset without accepting the dark grey rung (85/255 = 0.33).
local function isBlack(r, g, b)
  return r < 0.12 and g < 0.12 and b < 0.12
end

GlassMask._isBlack = isBlack     -- named for the suite

-- A few panes are drawn in a way the shape rules above still don't cover,
-- checked by hand against the actual art (not guessed): a 4-pane lattice
-- window whose glass strips are a single texel wide (any WIDTHS entry that
-- narrow matches far too much incidental art to scan for generally), a
-- small accent window the same width, and a barred window whose bottom
-- edge is never closed by a black row in the source art at all -- it just
-- runs into the wall texture below it.
--
-- These were verified against a reference export of Johto's sheet. That
-- export came out byte-identical to a reference export of Gen 1's
-- Overworld sheet, but that's a fact about two files handed to a chat, not
-- a confirmed fact about what the live engine loads for each -- so this is
-- keyed to match ONLY names that mean Johto specifically. Gen 1's tileset
-- gets none of these entries, on purpose: it was already working, and nothing
-- here has been checked against whatever Gen 1's tileset actually is at
-- runtime. Ask if Gen 1 should get the same fixes once its real id/path is
-- confirmed -- it's a one-line change, not a re-verification.
local johtoPanes = {
  { x = 59, y = 12, w = 2, h = 3 },   -- small accent window
  { x = 60, y = 28, w = 8, h = 4 },   -- barred window, open bottom edge
  { x = 36, y = 56, w = 1, h = 4 },   -- 4-pane lattice, outer-left
  { x = 38, y = 56, w = 1, h = 4 },   -- 4-pane lattice, inner-left
  { x = 49, y = 56, w = 1, h = 4 },   -- 4-pane lattice, inner-right
  { x = 51, y = 56, w = 1, h = 4 },   -- 4-pane lattice, outer-right
}

GlassMask.MANUAL = {
  ["johto"] = johtoPanes,
  ["tilesetjohto"] = johtoPanes,
  ["johto.png"] = johtoPanes,
}

-- Candidate lookup keys for a tileset, tried in order: its engine id (raw,
-- and lowercased with any TILESET_ prefix stripped), then the basename of
-- its image path (with or without the extension). Whichever of these was
-- actually used to key GlassMask.MANUAL above is the one that matches.
local function manualKeysFor(tileset)
  local keys = {}
  local id = tileset and tileset.id
  if type(id) == "string" then
    keys[#keys + 1] = id:lower()
    keys[#keys + 1] = id:gsub("^TILESET_", ""):lower()
  end
  local path = tileset and tileset.image
  if type(path) == "string" then
    local base = path:match("([^/\\]+)$") or path
    keys[#keys + 1] = base:lower()
    keys[#keys + 1] = (base:gsub("%.%w+$", "")):lower()
  end
  return keys
end

local function manualRectsFor(tileset)
  for _, key in ipairs(manualKeysFor(tileset)) do
    local hit = GlassMask.MANUAL[key]
    if hit then return hit end
  end
  return nil
end

-- ------- GEN 3 WINDOWS: found by CATALOG, not by shape
--
-- The shape scan above assumes a black-bordered pane, calibrated against
-- Gen 1/2's art ("the raw tileset art is the four DMG greys, so black is
-- genuinely zero" -- see isBlack's own note). Checked against the real
-- extracted Emerald tile banks: the scan finds 11 rects total across all
-- 36 Emerald tilesets that carry glass, where the hand-verified catalog
-- (Gen3WindowMetatiles, read off the composited art metatile by metatile)
-- counts 570 window metatiles plus 66 glass doors. The border in this art
-- is a dark NAVY (measured (65,74,106) on TILESET_03DF704, i.e. blue
-- channel 0.42 -- nowhere near isBlack's 0.12 ceiling on any channel), not
-- a washed-out black, so no amount of loosening the threshold recovers
-- this without also catching ordinary mid-blue wall and water art (tried:
-- 0.20/0.28/0.35/0.45 -- rects barely move until 0.45, where they start
-- swallowing unrelated tiles). So Gen 3/FRLG windows are listed here
-- instead of found, from a catalog checked by hand against the composited
-- art tileset by tileset (see Gen3WindowMetatiles.lua's own header).
--
-- The catalog names METATILES, not pixels. A metatile is four 8px
-- quadrants whose synthetic ids are `m*4 + q`. The atlas GlassMask has
-- to paint is the RELAID tile sheet (`bakeLinear` / `atlasInfoFor`):
-- 16 TILES per row, each 8px, addressed the same way ChunkMesher.uvRect
-- does -- `(t % perRow) * 8`, not Gen3.tileOrigin's 16x16-cell layout
-- (that layout is the PRE-relay metatile sheet). Because 16 is a multiple
-- of 4, one metatile is always a 32x8 strip of four consecutive tiles.
--
-- The catalog itself is keyed by the INDIVIDUAL halves (`primaryKey` /
-- `secondaryKey`, e.g. TILESET_03DF704), never by the pair id the map
-- carries (TILESET_03DF704_03DF77C). Looking up tileset.id therefore
-- matches nothing and the mask stays empty on every Hoenn/Kanto map.
--
-- This needs no tileset image at all -- `Gen3.atlasInfoFor` is pure
-- arithmetic over the pair's own metatile count, not a GPU bake -- so it
-- works even where `Gen3.atlasDataForTileset` (which DOES bake) can't.
local function gen3CatalogKeys(tileset)
  local keys, seen = {}, {}
  local function add(k)
    if type(k) ~= "string" or k == "" or seen[k] then return end
    seen[k] = true
    keys[#keys + 1] = k
  end
  add(tileset and tileset.primaryKey)
  add(tileset and tileset.secondaryKey)
  local id = tostring(tileset and tileset.id or "")
  add(id)
  local p, s = id:match("^(TILESET_%x+)_(%x+)$")
  if p and s then
    add(p)
    add("TILESET_" .. s)
  end
  return keys
end

local function gen3Ids(tileset)
  if not WindowMetatiles then return nil end
  local ids, seen = {}, {}
  for _, key in ipairs(gen3CatalogKeys(tileset)) do
    for _, game in ipairs({ "emerald", "firered" }) do
      for _, bucket in ipairs({ WindowMetatiles.windows, WindowMetatiles.doors }) do
        local list = bucket and bucket[game] and bucket[game][key]
        if list then
          for _, id in ipairs(list) do
            if not seen[id] then
              seen[id] = true
              ids[#ids + 1] = id
            end
          end
        end
      end
    end
  end
  return #ids > 0 and ids or nil
end

local function gen3Rects(tileset)
  local ids = gen3Ids(tileset)
  if not ids then return nil end
  local infoOk, info = pcall(Gen3.atlasInfoFor, tileset)
  local perRow = (infoOk and info and info.perRow) or 16
  local rects = {}
  for _, m in ipairs(ids) do
    local t = (tonumber(m) or 0) * 4
    rects[#rects + 1] = {
      x = (t % perRow) * 8,
      y = math.floor(t / perRow) * 8,
      w = 32,
      h = 8,
    }
  end
  return rects
end

-- Pane vs everything else in a catalog metatile, measured off the verify
-- contact sheets (4x composites of the same metatiles, navy frame
-- (65,74,106), inner grey (98,98,123), cyan/blue glass, cool near-white
-- shine). Applied only INSIDE listed window/door cells, so blue roofs and
-- water elsewhere never get a vote.
local function isGen3Glass(r, g, b)
  if type(r) ~= "number" then return false end
  if b < 0.42 then return false end
  local br = b - r
  if b >= 0.85 and br >= 0.02 and b >= g then return true end
  if br < 0.11 then return false end
  if b < g - 0.03 then return false end
  return true
end

GlassMask._isGen3Glass = isGen3Glass

-- When the relaid atlas exists, keep only glass texels. If the bake has
-- not happened yet, the caller keeps the 32x8 strips so the mask is not
-- empty for the session.
local function gen3GlassPixels(tileset, ids, w, h, perRow)
  if not (ids and Gen3.atlasDataForTileset) then return nil end
  local ok, data = pcall(Gen3.atlasDataForTileset, tileset)
  if not (ok and data and data.getPixel) then return nil end
  local rects = {}
  for _, m in ipairs(ids) do
    local t0 = (tonumber(m) or 0) * 4
    for q = 0, 3 do
      local t = t0 + q
      local ox, oy = (t % perRow) * 8, math.floor(t / perRow) * 8
      for yy = 0, 7 do
        for xx = 0, 7 do
          local x, y = ox + xx, oy + yy
          if x < w and y < h then
            local pok, pr, pg, pb = pcall(data.getPixel, data, x, y)
            if pok and isGen3Glass(pr, pg, pb) then
              rects[#rects + 1] = { x = x, y = y, w = 1, h = 1 }
            end
          end
        end
      end
    end
  end
  return rects
end

-- Find every pane in an image, through a pure reader so the geometry is
-- testable headless: `getPixel(x, y)` returns r, g, b in 0..1 for 0-based
-- coordinates. Returns { {x=, y=, w=, h=}, ... } rects of GLASS texels
-- (the border is the detector's evidence, not part of the answer).
--
-- A closing border row is REQUIRED, same as before -- that's what keeps
-- this from also matching a flat counter or sign board (checked against
-- the actual tileset art: loosening this to accept any run that simply
-- ends up matching a shop counter in forest.png that plainly isn't glass).
-- The one real pane that has no closing row in its art at all -- its
-- bottom edge blends straight into the wall below it -- is handled by the
-- verified MANUAL table instead of loosening this rule for everyone.
function GlassMask.scan(getPixel, w, h)
  local function black(x, y)
    if x < 0 or x >= w or y < 0 or y >= h then return false end
    return isBlack(getPixel(x, y))
  end
  local function borderRow(x, y, gw)
    for c = 1, gw do
      if not black(x + c, y) then return false end
    end
    return true
  end
  local function glassRow(x, y, gw)
    if not (black(x, y) and black(x + gw + 1, y)) then return false end
    for c = 1, gw do
      if black(x + c, y) then return false end
    end
    return true
  end

  local rects = {}
  for y = 0, h - 1 do
    for _, gw in ipairs(GlassMask.WIDTHS) do
      for x = 0, w - gw - 2 do
        if borderRow(x, y, gw) then
          local n = 0
          while y + 1 + n < h and glassRow(x, y + 1 + n, gw) do
            n = n + 1
          end
          if n >= GlassMask.ROWS_MIN and n <= GlassMask.ROWS_MAX
             and y + 1 + n < h and borderRow(x, y + 1 + n, gw) then
            rects[#rects + 1] = { x = x + 1, y = y + 1, w = gw, h = n }
          end
        end
      end
    end
  end
  return rects
end

-- ------- the runtime cache, one entry per tileset image

local cache = {}       -- image path -> { rects, texture (or false) }

-- A Gen 3/FRLG tileset has no `.image` of its own to key a cache on (its
-- art is a pair baked at runtime, not a single file) -- the tileset's own
-- id is a fine substitute, since Gen3.atlasInfoFor already caches on the
-- same string.
local function cacheKeyFor(tileset)
  if Gen3.isGen3(tileset) then return "gen3:" .. tostring(tileset and tileset.id) end
  return tileset and tileset.image
end

local function entry(tileset)
  local key = cacheKeyFor(tileset)
  if not key then return nil end
  local hit = cache[key]
  if hit then return hit end

  local w, h, rects

  if Gen3.isGen3(tileset) then
    -- catalog, not scan (see GEN 3 WINDOWS above) -- pure arithmetic, no
    -- bake, so this works whether or not the atlas ever gets drawn
    local infoOk, info = pcall(Gen3.atlasInfoFor, tileset)
    if not (infoOk and info and info.width and info.height) then
      cache[key] = { rects = {}, texture = false }
      return cache[key]
    end
    w, h = info.width, info.height
    local ids = gen3Ids(tileset)
    local perRow = info.perRow or 16
    local pixels = ids and gen3GlassPixels(tileset, ids, w, h, perRow)
    if pixels and #pixels > 0 then
      rects = pixels
    else
      rects = gen3Rects(tileset) or {}
    end
  else
    local path = tileset and tileset.image
    if not path then return nil end
    local ok, data = pcall(Assets.imageData, path)
    if not (ok and data) then
      -- unreadable art is a verdict for the session, not a retry loop
      cache[key] = { rects = {}, texture = false }
      return cache[key]
    end

    local dimsOk, dw, dh = pcall(function() return data:getDimensions() end)
    if not dimsOk then
      cache[key] = { rects = {}, texture = false }
      return cache[key]
    end
    w, h = dw, dh

    local scanOk, scanned = pcall(GlassMask.scan, function(x, y)
      return data:getPixel(x, y)
    end, w, h)
    rects = scanOk and scanned or {}
  end

  -- Clip every rect -- scan-found AND manual -- to the image's ACTUAL
  -- dimensions before it ever reaches setPixel. A manual rect is measured
  -- against a reference export; if the live asset turns out to be a
  -- different size, the old code let one out-of-range setPixel abort the
  -- whole texture build inside a single pcall, silently losing every
  -- window on that sheet -- including ones the plain scan had already
  -- found correctly. Now a rect that doesn't fit is dropped, not fatal.
  local function fits(r)
    return r.x >= 0 and r.y >= 0 and r.w > 0 and r.h > 0
       and r.x + r.w <= w and r.y + r.h <= h
  end
  local clipped = {}
  for _, r in ipairs(rects) do
    if fits(r) then clipped[#clipped + 1] = r end
  end
  rects = clipped

  local manual = manualRectsFor(tileset)
  if manual then
    for _, r in ipairs(manual) do
      if fits(r) then
        rects[#rects + 1] = { x = r.x, y = r.y, w = r.w, h = r.h }
      end
    end
  end

  local texture = false
  if #rects > 0 and love.image and love.image.newImageData
     and love.graphics and love.graphics.newImage then
    local built = pcall(function()
      local mask = love.image.newImageData(w, h)
      for _, r in ipairs(rects) do
        for yy = r.y, r.y + r.h - 1 do
          for xx = r.x, r.x + r.w - 1 do
            mask:setPixel(xx, yy, 1, 1, 1, 1)
          end
        end
      end
      texture = love.graphics.newImage(mask)
      texture:setFilter("nearest", "nearest")
    end)
    if not built then texture = false end
  end
  cache[key] = { rects = rects, texture = texture }
  return cache[key]
end

-- The panes found in a tileset's art, as glass rects in atlas pixels.
function GlassMask.rects(tileset)
  local e = entry(tileset)
  return e and e.rects or {}
end

-- The mask texture for a tileset, or nil when it has no panes (or the art
-- is unreadable, or there is no GPU) -- callers bind the blank instead.
function GlassMask.texture(tileset)
  local e = entry(tileset)
  return (e and e.texture) or nil
end

-- A 1x1 transparent stand-in, for the frames (and drivers) with no mask:
-- the scene shader always declares the sampler, and an unbound sampler is
-- a driver-dependent crash rather than a fallback.
local blank = nil

function GlassMask.blank()
  if blank == nil then
    local ok, img = pcall(function()
      local data = love.image.newImageData(1, 1)
      data:setPixel(0, 0, 0, 0, 0, 0)
      return love.graphics.newImage(data)
    end)
    blank = (ok and img) or false
  end
  return blank or nil
end

-- Drop the GPU objects (window resize, hot reload). The rects survive --
-- they are a fact about the art -- but textures are rebuilt on demand.
function GlassMask.invalidate()
  for _, e in pairs(cache) do
    if e.texture and e.texture.release then pcall(e.texture.release, e.texture) end
    e.texture = false
  end
  cache = {}
  blank = nil
end

return GlassMask