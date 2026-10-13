-- Gen4Lawn: wear the mod's own ground pictures (grass.png, roads.png...) on chosen
-- Platinum terrain textures -- and only those. Edit Lawn.TEXTURES below.
--
-- WHY Gen4GreenGround CHANGED THE WHOLE GROUND
--
-- It asked "is this cell not tall grass, not sand, not water?" using the
-- tile behaviour byte. That byte is a MOVEMENT fact (walkable, ledge, tall
-- grass, sand...). Roads, paths, plazas, flower beds and lawn are ALL plain
-- walkable behaviour 0, so "everything that is not X" is every floor in the
-- map. Behaviour can never mean "green".
--
-- HOW THE ENGINE KNOWS WHAT IS LAWN
--
-- Terrain chunks are Gen4Models whose shapes are separate polygon layers, each
-- with its own MATERIAL/TEXTURE name (Gen4Model.lua, GRASS_MATERIALS notes):
--     ngrass      lawn            (224 shapes)
--     bf_ngrass   lawn, another area's prefix (9)
--     nectgr      wild-Pokemon grass (kept native; Gen4Grass owns it)
--     s_grass     red-soil grass clump
--     l_grass_*   standing grass wall columns
-- Roads/paths are other textures, so they are never touched.
--
-- HOW IT IS APPLIED (no overlay, no lift, no z-fight)
--
-- Gen4Model:draw(vp, pose, materials) already accepts
--     materials[<shape.material>] = { image = <path>, uv = {a,b,c,d,tx,ty} }
-- (it is how the engine animates textures). Inside Gen4Ground:drawFree this
-- wraps Model.draw and adds that entry for every lawn shape, so the SAME
-- polygons the cartridge paints as lawn are drawn with grass.png instead.
-- Cells follow the real terrain height and shape, and nothing else changes.
--
-- Install AFTER/alongside Gen4Hide (main.lua, next to Gen4Hide.install()).

local V = ...

local Lawn = {
  enabled = true,
  installed = false,
  -- texture name (lower case) -> { image = <file under assets/ground/grass/>, uv = scale }
  -- uv: 1 = one repeat per whatever the native tile covered; 0.5 = twice as large.
  TEXTURES = {
    ngrass    = { image = "grass.png", uv = 1 },     -- lawn
    bf_ngrass = { image = "grass.png", uv = 1 },     -- lawn, another area's prefix
    -- imped is rocks AND fence banners. Gen4Rocks hides only rock-only shapes;
    -- Lawn must not paint the whole material transparent or fences vanish.
    hage      = { image = "mulch.png",   uv = 1 },
    nsand     = { image = "mulch.png",    uv = 1 },
    nsandp    = { image = "mulch.png",  uv = 1 },
    lgreen    = { image = "highgrass.png",    uv = 1 },
    lgreenp   = { image = "highgrass.png",    uv = 1 },
    allpeak   = { image = "edges.png",   uv = 1 },

    -- Twinleaf / Route 201 leftover ids (from Gen4Lawn LOG_NAMES). Same swirl
    -- probes already in this folder, plus extra hues for groups that had none.
    nectgr    = { image = "highgrass.png",    uv = 1 },   -- wild-Pokemon grass floor
    -- flower beds: grass.png floor, but only on a land where Gen4Flowers has built
    -- its voxel flowers (whenBuilt), so a bed is never left bare or half-changed
    nhana     = { image = "grass.png", uv = 1, whenBuilt = "Gen4Flowers" },
    beach     = { image = "sand.png",    uv = 1 },
    beachp    = { image = "sand.png",    uv = 1 },
    hamabe    = { image = "sand.png",    uv = 1 },   -- shore
    seaside3  = { image = "sand.png",    uv = 1 },
    criff     = { image = "edges.png",   uv = 1 },
    criffp    = { image = "edges.png",   uv = 1 },
    searock   = { image = "edges.png",   uv = 1 },
    fenter    = { image = "shadow tree.png",    uv = 1 },
    newstep   = { image = "9step.png",    uv = 1 },
    cyclestop = { image = "step.png",    uv = 1 },
    ["s_snow"]   = { image = "dsnow.png",   uv = 1 },
    ["s_snow02"] = { image = "dsnow.png",   uv = 1 },
    ["s_snow04"] = { image = "dsnow.png",   uv = 1 },
    ["s_sonwp"]  = { image = "dsnow.png",   uv = 1 },
    puddle    = { image = "waterp.png",  uv = 1 },
    puddlep   = { image = "waterp.png",  uv = 1 },
    puddle_b  = { image = "waterp.png",  uv = 1 },
    sea       = { image = "waterp.png",  uv = 1 },
    lake      = { image = "waterp.png",  uv = 1 },
    ["lakep.1"] = { image = "waterp.png", uv = 1 },
    asasea    = { image = "waterp.png",  uv = 1 },   -- shallows
    tshadow   = { image = "highgrass.png",  uv = 1 },
    tree01    = { image = "trees.png",   uv = 1 },
    tree04_2  = { image = "trees.png",   uv = 1 },
    conttree_b = { image = "trees.png",  uv = 1 },
    conttree_t = { image = "trees.png",  uv = 1 },

    -- Jubilife (c1_*) from Route 201 land 15/17
    c1_g1     = { image = "flagstone.png",   uv = 1 },
    c1_r1     = { image = "road.png",    uv = 1 },
    c1_r1_k1  = { image = "pavers.png",    uv = 1 },
    c1_r1_k2  = { image = "pavers.png",    uv = 1 },
    c1_r1_ud  = { image = "pavers.png",    uv = 1 },
    c1_r1_lr  = { image = "pavers.png",    uv = 1 },
    c1_r1_s1  = { image = "road.png",    uv = 1 },
    c1_d_1    = { image = "ground.png",  uv = 1 },
    c1_d_2    = { image = "ground.png",  uv = 1 },
    c1_d_3    = { image = "ground.png",  uv = 1 },
    c1_d_4    = { image = "ground.png",  uv = 1 },
    c1_f_ud   = { image = "horizontal fence.png", uv = 1 },
    c1_f_l    = { image = "vertical fence.png", uv = 1 },
    c1_f_r    = { image = "vertical fence.png", uv = 1 },
    c1_f_k1   = { image = "fence corner.png", uv = 1 },
    c1_f_k2   = { image = "fence corner.png", uv = 1 },
    c1_o02    = { image = "metal aged.png",  uv = 1 },
    c1_o02b   = { image = "light.png",  uv = 1 },
    c1_lamp01 = { image = "lamp.png",    uv = 1 },
    c1_lamp02 = { image = "lamp.png",    uv = 1 },
  },
  DIR = "/assets/ground/grass/",
  LOG_NAMES = true,      -- log every distinct land/texture/material once (grep "Gen4Lawn:")
}

local logged = {}
local function note(key, fmt, ...)
  if logged[key] then return end
  logged[key] = true
  if V.mod and V.mod.log then V.mod.log:info("Gen4Lawn: " .. fmt:format(...)) end
end

local imagePaths = {}     -- file -> path | false (missing)
local function resolvePath(file)
  local hit = imagePaths[file]
  if hit ~= nil then return hit or nil end
  imagePaths[file] = false
  local okA, Assets = pcall(require, "src.render.Assets")
  if okA and Assets then
    local path = V.path .. Lawn.DIR .. file
    local okE, exists = pcall(Assets.exists, path)
    if okE and exists then imagePaths[file] = path end
  end
  if not imagePaths[file] then
    note("img:" .. file, "no %s%s -- that texture keeps its native look", Lawn.DIR, file)
  end
  return imagePaths[file] or nil
end

-- model -> { source = shapes, count = n, mats = table|false }
local cache = setmetatable({}, { __mode = "k" })

local function builtVersion()
  -- Every module a whenBuilt gate can name: the cache must notice when its set of
  -- built lands changes. A module may give a richer `gateKey()` (Gen4Flowers also
  -- changes it when switched on/off); otherwise its `version` is used.
  local parts = {}
  for _, name in ipairs({ "Gen4Rocks", "Gen4Flowers" }) do
    local ok, M = pcall(V.require, name)
    if ok and type(M) == "table" then
      parts[#parts + 1] = tostring(type(M.gateKey) == "function" and M.gateKey() or M.version or 0)
    end
  end
  return table.concat(parts, "|")
end

local function lawnMaterials(model)
  local shapes = model.shapes
  local ver = builtVersion()
  local rec = cache[model]
  if rec and rec.source == shapes and rec.count == #shapes and rec.ver == ver then return rec.mats or nil end
  local mats = false
  for _, shape in ipairs(shapes) do
    local tex = tostring(shape.lawnTexture or ""):lower()
    local cfg = Lawn.TEXTURES[tex]
    local gate = true
    if cfg and cfg.whenBuilt then
      local ok, M = pcall(V.require, cfg.whenBuilt)
      gate = ok and type(M) == "table" and M.isBuilt and M.isBuilt(model.lawnLand) or false
    end
    local path = cfg and gate and shape.material and resolvePath(cfg.image)
    if path then
      local k = cfg.uv or 1
      mats = mats or {}
      mats[shape.material] = { image = path, uv = { k, 0, 0, k, 0, 0 } }
      note("swap:" .. tex, "swapping texture '%s' (material '%s') -> %s", tex, tostring(shape.material), cfg.image)
    end
  end
  cache[model] = { source = shapes, count = #shapes, mats = mats, ver = ver }
  return mats or nil
end

local drawing = false

function Lawn.install()
  if Lawn.installed then return true end
  local okM, Model = pcall(require, "src.render.Gen4Model")
  local okG, Ground = pcall(require, "src.render.Gen4Ground")
  if not (okM and type(Model) == "table" and type(Model.draw) == "function"
          and okG and type(Ground) == "table" and type(Ground.drawFree) == "function"
          and type(Ground.modelFor) == "function") then
    return false
  end
  Lawn.Model, Lawn.Ground = Model, Ground
  Lawn.originalDraw, Lawn.originalDrawFree, Lawn.originalModelFor =
    Model.draw, Ground.drawFree, Ground.modelFor

  -- A built terrain shape keeps its material name but not its texture name.
  -- Copy the cache record's texture on (matched by shape name, in order, like
  -- Gen4Hide does) as `lawnTexture`.
  local originalModelFor = Ground.modelFor
  Ground.modelFor = function(self, land, ...)
    local model = originalModelFor(self, land, ...)
    if model and type(model.shapes) == "table" then
      model.lawnLand = land
      pcall(function()
        local chunks = self.terrain and self.terrain.chunks
        local record = chunks and chunks[land]
        if not (record and record.shapes) then return end
        local queues = {}
        for _, src in ipairs(record.shapes) do
          local key = src.name or ""
          local q = queues[key]
          if not q then q = { at = 1 }; queues[key] = q end
          q[#q + 1] = src
        end
        for _, built in ipairs(model.shapes) do
          local q = queues[built.name or ""]
          local src = q and q[q.at]
          if src then
            q.at = q.at + 1
            built.lawnTexture = src.texture
            if Lawn.LOG_NAMES then
              local texName = tostring(src.texture)
              local mapped = Lawn.TEXTURES[texName:lower()] and " mapped" or " UNMAPPED"
              note("t:" .. tostring(land) .. "|" .. texName .. "|" .. tostring(src.material),
                   "land %s texture '%s' material '%s' shape '%s'%s",
                   tostring(land), texName, tostring(src.material),
                   tostring(src.name), mapped)
            end
          end
        end
      end)
    end
    return model
  end

  local originalDraw = Model.draw
  Model.draw = function(self, viewProjection, pose, materials, ...)
    if not (drawing and Lawn.enabled) or type(self.shapes) ~= "table" then
      return originalDraw(self, viewProjection, pose, materials, ...)
    end
    local lawn = lawnMaterials(self)
    if not lawn then return originalDraw(self, viewProjection, pose, materials, ...) end
    -- merge with whatever the caller passed; the lawn entry wins only for the
    -- lawn's own material name
    local merged = {}
    if materials then for k, v in pairs(materials) do merged[k] = v end end
    for k, v in pairs(lawn) do merged[k] = v end
    return originalDraw(self, viewProjection, pose, merged, ...)
  end

  local originalFree = Ground.drawFree
  Ground.drawFree = function(self, ...)
    drawing = true
    local ok, a, b = pcall(originalFree, self, ...)
    drawing = false
    if not ok then error(a, 0) end
    return a, b
  end

  Lawn.installed = true
  return true
end

function Lawn.invalidate()
  cache = setmetatable({}, { __mode = "k" })
  imagePaths = {}
end

function Lawn.uninstall()
  if not Lawn.installed then return end
  Lawn.Model.draw = Lawn.originalDraw
  Lawn.Ground.drawFree = Lawn.originalDrawFree
  Lawn.Ground.modelFor = Lawn.originalModelFor
  Lawn.installed, drawing = false, false
end

return Lawn