-- Gen4Hide: switch off Platinum's OWN grass and water where Terrarium draws its
-- 3D versions instead, so the two stop overlapping.
--
-- THE SEAM (engine untouched)
--
-- Terrain is a Gen4Model per land chunk, and Gen4Model:draw walks model.shapes
-- one material at a time. So hiding something native is "don't draw that shape".
-- This wraps Gen4Model.draw and, only while Gen4Ground:drawFree is running (the
-- free cameras -- the only ones Gen4Bridge draws into), hands draw() a filtered
-- copy of the shape list. The model's real list is put back straight after, and
-- every other pass (the CARTRIDGE rung's baked chunks, canopies, buildings'
-- depth passes) sees the world exactly as before.
--
-- WHAT IS HIDDEN
--
--   grass  The standing cards the engine stamps over wild-Pokemon grass
--          (Gen4Model.addGrassCards: a shape named "<shape>Cards", index nil).
--          The flat grass quad under them is LEFT, as the ground: removing it
--          would open a hole in the terrain under your tufts.
--   water  Shapes whose MATERIAL or TEXTURE name says water (`sea`, `water01`,
--          `water02`, `water:lambert5`, anything with water/lake/river in it --
--          see classify()), and terrain shapes the cartridge states as
--          translucent that are not a shadow/glass/cloud (Gen4Terrain.append
--          measured every water material as translucent). Waterfalls and
--          fountains are never hidden: the sheet does not cover them.
--          A built Gen4Model shape keeps only `material`, not `texture`, so
--          Gen4Ground:modelFor is wrapped to copy the cache's own texture name
--          and alpha onto each terrain shape (srcTexture / srcAlpha).
--
-- HIDDEN ONLY WHERE THE SHEET EXISTS
--
--   A water shape is dropped only when Gen4Water has built geometry FROM THAT
--   SHAPE (GW.isCovered(shape.src)). Terrain shapes and prop shapes (lakes are
--   props: build models) are both tagged with the cache record they came from
--   (`src`), and Gen4Water marks every record it emitted triangles for. A
--   water shape the sheet could not use -- a vertical fall, a chunk not built
--   yet -- keeps drawing natively, so "hidden and not replaced" cannot happen.
--   trees  Terrain and prop shapes Gen4Trees has voxelised for every triangle
--          (GT.isCovered). Forest-border `conttree*` strips stay native.
--
-- WHEN IT STANDS DOWN (so it can never leave a hole)
--
--   grass  when Grass3D has no bake, or the "grass" effect was disabled.
--   water  when the "water" effect was disabled or failed, or Gen4Water has not
--          finished building the sheet around the camera yet (GW.ready).
--   trees  when the "trees" effect was disabled or Gen4Trees is missing.
--
-- Flip Hide.grass / Hide.water / Hide.trees to false to compare against the native look.

local V = ...

local Hide = {
  grass = true,
  water = true,
  trees = true,
  active = false,
  installed = false,
  -- exact material/texture names (lower case) that are water
  WATER_NAMES = { sea = true, water01 = true, water02 = true },
  -- Lua patterns tried on the same names
  WATER_PATTERNS = { "^sea[^%a]", "[^%a]sea[^%a]", "[^%a]sea$", "^water", "[^%a]water" },
  -- plain substrings that mean water
  WATER_SUBSTRINGS = { "water", "lake", "river", "wtr", "mizu", "umi_", "pond", "suimen" },
  -- never hidden, whatever else matches: shadows, glass, clouds, and the
  -- vertical / decorative water the sheet does not replace
  KEEP_SUBSTRINGS = { "kage", "shadow", "shade", "garasu", "glass", "cloud", "kumo",
                      "fall", "funsui", "fount" },
  -- translucent terrain (alpha < 31 in the cartridge) that is not KEEP is water
  -- or a water edge: the importer measured every water material that way.
  ALPHA_HEURISTIC = true,
  -- log every distinct shape once, with what was decided. Grep the mod log for
  -- "Gen4Hide:". Off now that the native water is gone; turn on to find a name
  -- that still draws.
  LOG_NAMES = false,
}

local logged = {}
local function note(key, fmt, ...)
  if logged[key] then return end
  logged[key] = true
  if V.mod and V.mod.log then V.mod.log:info("Gen4Hide: " .. fmt:format(...)) end
end

local function optional(name)
  local ok, mod = pcall(V.require, name)
  return ok and mod or nil
end

-- ------------------------------------------------------------ classifiers --

local function lowered(s) return tostring(s or ""):lower() end

function Hide.isGrassCards(shape)
  local name = shape.name
  return shape.index == nil and type(name) == "string" and name:sub(-5) == "Cards"
end

local function namesOf(shape)
  return lowered(shape.srcMaterial or shape.material), lowered(shape.srcTexture or shape.texture)
end

local function containsAny(name, list)
  for _, sub in ipairs(list) do
    if name:find(sub, 1, true) then return true end
  end
  return false
end

-- -> nil (keep), or a short reason the shape is water
function Hide.classify(shape)
  local m, t = namesOf(shape)
  if containsAny(m, Hide.KEEP_SUBSTRINGS) or containsAny(t, Hide.KEEP_SUBSTRINGS) then
    return nil
  end
  for _, n in ipairs({ m, t }) do
    if n ~= "" then
      if Hide.WATER_NAMES[n] then return "name" end
      for _, pat in ipairs(Hide.WATER_PATTERNS) do
        if n:find(pat) then return "pattern" end
      end
      if containsAny(n, Hide.WATER_SUBSTRINGS) then return "substring" end
    end
  end
  if Hide.ALPHA_HEURISTIC and shape.srcKind ~= "prop" and shape.srcTexture
     and tonumber(shape.srcAlpha) and shape.srcAlpha < 31 then
    return "alpha"
  end
  return nil
end

function Hide.isWater(shape) return Hide.classify(shape) ~= nil end

-- ------------------------------------------------------------ per-frame --

local function grassOn()
  if not Hide.grass then return false end
  local Bridge = optional("Gen4Bridge")
  if Bridge and Bridge.disabled and Bridge.disabled.grass then return false end
  local G3 = optional("Grass3D")
  if not (G3 and G3.available) then return false end
  local ok, avail = pcall(G3.available)
  return ok and avail and true or false
end

-- Native tree cards are hidden shape by shape, ONLY where Gen4Trees has voxel
-- trees for every triangle of the shape right now (GT.isCovered).
local function treesOn()
  if not Hide.trees then return false end
  local Bridge = optional("Gen4Bridge")
  if Bridge and Bridge.disabled and Bridge.disabled.trees then return false end
  local GT = optional("Gen4Trees")
  return (GT and type(GT.isCovered) == "function" and GT.enabled) and true or false
end

local lastWaterState
local function waterOn()
  if not Hide.water then return false end
  local Bridge = optional("Gen4Bridge")
  local state, on
  if Bridge and Bridge.disabled and Bridge.disabled.water then
    state, on = "water effect disabled/failed -> native water kept", false
  else
    local GW = optional("Gen4Water")
    if GW == nil then
      state, on = "Gen4Water did not load -> native water kept", false
    elseif type(GW.isCovered) == "function" then
      state, on = "hiding native water shape by shape, where Gen4Water covers it", true
    elseif GW.ready == false then
      state, on = "Gen4Water sheet not built yet -> native water kept", false
    else
      -- ready == true, or an older Gen4Water with no flag at all
      state, on = (GW.ready == nil) and "Gen4Water has no ready flag -> hiding anyway"
                                     or "Gen4Water sheet ready -> hiding native water", true
    end
  end
  if state ~= lastWaterState then
    lastWaterState = state
    note("state:" .. state, "%s", state)
  end
  return on
end

-- model -> { key = "gw", list = {...} }
local cache = setmetatable({}, { __mode = "k" })

local function filtered(model, hideGrass, hideWater, hideTrees)
  local GT = hideTrees and optional("Gen4Trees") or nil
  local GW = hideWater and optional("Gen4Water") or nil
  local covered = GW and type(GW.isCovered) == "function" and GW.isCovered or nil
  local key = (hideGrass and "g" or "-") .. (hideWater and "w" or "-")
              .. (covered and tostring(GW.coverVersion or 0) or "")
              .. (GT and ("t" .. tostring(GT.coverVersion or 0)) or "-")
  local rec = cache[model]
  local shapes = model.shapes
  if rec and rec.key == key and rec.source == shapes and rec.count == #shapes then
    return rec.list
  end
  local list, hidden = {}, 0
  for _, shape in ipairs(shapes) do
    local drop = false
    if hideGrass and Hide.isGrassCards(shape) then
      drop = true
      note("g:" .. tostring(shape.name), "hid native grass cards '%s'", tostring(shape.name))
    elseif GT and ((shape.src and GT.isCovered(shape.src))
                   or (GT.isCoveredName and GT.isCoveredName(shape))) then
      drop = true
      note("t:" .. tostring(shape.srcTexture or shape.name),
           "hid native tree cards '%s' (voxel trees stand in)", tostring(shape.srcTexture or shape.name))
    elseif hideWater then
      local why = Hide.classify(shape)
      -- and only where the sheet really stands in for it
      if why and covered and not (shape.src and covered(shape.src)) then why = nil end
      if why then
        drop = true
        note("w:" .. (shape.srcMaterial or shape.material or "") .. "|" .. (shape.srcTexture or ""),
             "hid water by %s: material '%s' texture '%s' alpha %s",
             why, tostring(shape.srcMaterial or shape.material),
             tostring(shape.srcTexture or shape.texture), tostring(shape.srcAlpha))
      end
    end
    if Hide.LOG_NAMES and not drop then
      note("k:" .. (shape.srcMaterial or shape.material or "") .. "|" .. (shape.srcTexture or ""),
           "kept: material '%s' texture '%s' alpha %s",
           tostring(shape.srcMaterial or shape.material),
           tostring(shape.srcTexture or shape.texture), tostring(shape.srcAlpha))
    end
    if drop then hidden = hidden + 1 else list[#list + 1] = shape end
  end
  if hidden == 0 then list = shapes end   -- nothing to hide: draw the real list
  cache[model] = { key = key, source = shapes, count = #shapes, list = list }
  return list
end

-- ---------------------------------------------------------------- install --

function Hide.install()
  if Hide.installed then return true end
  local okM, Model = pcall(require, "src.render.Gen4Model")
  local okG, Ground = pcall(require, "src.render.Gen4Ground")
  if not (okM and type(Model) == "table" and type(Model.draw) == "function"
          and okG and type(Ground) == "table" and type(Ground.drawFree) == "function") then
    return false
  end
  Hide.Model, Hide.Ground = Model, Ground
  Hide.originalDraw, Hide.originalDrawFree = Model.draw, Ground.drawFree
  Hide.originalModelFor = Ground.modelFor

  -- A built shape keeps its material name but not its texture or alpha; the
  -- cache index still has them. Copy them on, matching by shape name in order.
  if type(Ground.modelFor) == "function" then
    local originalModelFor = Ground.modelFor
    Ground.modelFor = function(self, land, ...)
      local model = originalModelFor(self, land, ...)
      if model and type(model.shapes) == "table" then
        pcall(function()
          local chunks = self.terrain and self.terrain.chunks
          local record = chunks and chunks[land]
          if not (record and record.shapes) then return end
          local queues = {}
          for _, src in ipairs(record.shapes) do
            local q = queues[src.name or ""]
            if not q then q = { at = 1 }; queues[src.name or ""] = q end
            q[#q + 1] = src
          end
          for _, built in ipairs(model.shapes) do
            local q = queues[built.name or ""]
            local src = q and q[q.at]
            if src then
              q.at = q.at + 1
              built.srcMaterial = src.material
              built.srcTexture = src.texture
              built.srcAlpha = src.alpha
              built.srcKind, built.src = "terrain", src
            end
          end
        end)
      end
      return model
    end
  end

  -- The same for PROPS. Lakes are build models, and a built prop shape keeps
  -- only its material name, so the cache's own record (name, texture, alpha) is
  -- copied on, joined by the index the building was built with.
  Hide.originalBuilding = Ground.building
  if type(Ground.building) == "function" then
    local originalBuilding = Ground.building
    Ground.building = function(self, index, archive, ...)
      local model = originalBuilding(self, index, archive, ...)
      if model and not model.srcTagged and type(model.shapes) == "table" then
        model.srcTagged = true
        pcall(function()
          local packed
          if archive == "fldeff" then
            local set = self.fldeffSet
            local at = set and set.byMember and set.byMember[index]
            packed = at and set.models and set.models[at]
          else
            local set = self.buildingSet
            packed = set and set.models and set.models[index + 1]
          end
          if not (packed and packed.shapes) then return end
          for _, built in ipairs(model.shapes) do
            -- index 0 is a real shape; `built.index and` would skip it in Lua
            local idx = built.index
            local src = idx ~= nil and packed.shapes[idx + 1]
            if not src and idx ~= nil then src = packed.shapes[idx] end
            if not src and built.name then
              for _, cand in ipairs(packed.shapes) do
                if cand.name == built.name then src = cand; break end
              end
            end
            if src then
              built.srcMaterial, built.srcTexture, built.srcAlpha =
                src.material, src.texture, src.alpha
              built.srcKind, built.src = "prop", src
            end
          end
        end)
      end
      return model
    end
  end

  local drawFilter = { grass = false, water = false, trees = false }

  local originalDraw = Model.draw
  Model.draw = function(self, ...)
    if not Hide.active then return originalDraw(self, ...) end
    local real = self.shapes
    if type(real) ~= "table" then return originalDraw(self, ...) end
    local list = filtered(self, drawFilter.grass, drawFilter.water, drawFilter.trees)
    if list == real then return originalDraw(self, ...) end
    self.shapes = list
    local ok, a = pcall(originalDraw, self, ...)
    self.shapes = real          -- always put the model's own list back
    if not ok then error(a, 0) end
    return a
  end

  local originalFree = Ground.drawFree
  Ground.drawFree = function(self, ...)
    drawFilter.grass, drawFilter.water = grassOn(), waterOn()
    drawFilter.trees = treesOn()
    if drawFilter.trees then
      -- decide which tree shapes are covered THIS frame before the native pass
      local GT = optional("Gen4Trees")
      if not (GT and pcall(GT.prepare, self)) then drawFilter.trees = false end
    end
    Hide.active = drawFilter.grass or drawFilter.water or drawFilter.trees
    local ok, a, b = pcall(originalFree, self, ...)
    Hide.active = false
    if not ok then error(a, 0) end
    return a, b
  end

  Hide.installed = true
  return true
end

function Hide.uninstall()
  if not Hide.installed then return end
  Hide.Model.draw = Hide.originalDraw
  Hide.Ground.drawFree = Hide.originalDrawFree
  Hide.Ground.modelFor = Hide.originalModelFor
  if Hide.originalBuilding then Hide.Ground.building = Hide.originalBuilding end
  Hide.active, Hide.installed = false, false
end

return Hide
