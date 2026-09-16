-- Pokemon Colosseum models for overworld Pokemon entities.
--
-- This module renders overworld Pokemon (wild spawns, roamers, followers)
-- as live Colosseum 3D models with idle animation, using the SAME bridge
-- (lib/ColosseumMon.lua) that OverworldStadium / StadiumFollower /
-- RoamerStadium3D already use successfully -- rather than driving
-- PokemonActors directly. ColosseumMon owns actor acquisition, per-frame
-- idle-state advancement, and matrix/draw, so every consumer of it (this
-- module included) gets the same tested idle-animation behaviour.
--
-- Integration contract:
--   * VoxelScene captures the real entity beside each rendered pose.
--   * prepare(posed) resolves an exact species and confirms a Colosseum
--     model is available for it, and records that on the pose.
--   * draw(pose) asks ColosseumMon to update/matrix/draw that model instead
--     of the 2D sprite.
--
-- Companion mods can tag a spawned NPC:
--
--   local ds = mod.find("DRAMATIC_SHAPE")
--   local ow = ds and ds.exports and ds.exports.lib
--              and ds.exports.lib.require("OverworldColosseum")
--   if ow then ow.tag(npc, "PIKACHU") end
--
-- Accepted tags are National Dex numbers (1-386) or engine species strings.
local V = ...

local ColosseumDex = nil  -- Load lazily
local ColosseumMon = V.require("ColosseumMon")

local OverworldColosseum = {}

-- Initialize global tag state in V namespace to share across module instances
if not V._colosseumTagState then
  V._colosseumTagState = {
    tagged = setmetatable({}, { __mode = "k" }),
    taggedById = {},
    entityDexCache = setmetatable({}, { __mode = "k" }),
    nameCache = {},
    frameNo = 0,
    reported = {},
  }
end

local tagged = V._colosseumTagState.tagged
local taggedById = V._colosseumTagState.taggedById
local entityDexCache = V._colosseumTagState.entityDexCache
local nameCache = V._colosseumTagState.nameCache
local frameNo = V._colosseumTagState.frameNo
local reported = V._colosseumTagState.reported

-- Reverse mapping from ColosseumDex species names to dex numbers
local colosseumNameToDex = nil

local function logOnce(key, fmt, ...)
  if reported[key] then return end
  reported[key] = true
  local log = V.mod and V.mod.log
  if log and log.warn then pcall(log.warn, log, fmt, ...) end
end

-- Build reverse mapping from ColosseumDex species names to dex numbers
local function buildColosseumNameMapping()
  if colosseumNameToDex then return colosseumNameToDex end

  if not ColosseumDex then
    local ok, cd = pcall(V.require, "ColosseumDex")
    if ok and cd then
      ColosseumDex = cd
    else
      return {}
    end
  end

  if not ColosseumDex or not ColosseumDex.species then
    return {}
  end

  local mapping = {}
  for dex, data in pairs(ColosseumDex.species) do
    if type(data) == "table" and data[1] then
      local speciesName = data[1]
      mapping[speciesName] = dex
      -- Also add lowercase variant for case-insensitive matching
      mapping[speciesName:lower()] = dex
    end
  end

  colosseumNameToDex = mapping
  return mapping
end

-- Resolve species name to dex number using ColosseumDex
local function resolveSpeciesNameToDex(speciesName)
  if type(speciesName) ~= "string" then return nil end

  -- Try to load ColosseumDex if not already loaded
  if not ColosseumDex then
    local ok, cd = pcall(V.require, "ColosseumDex")
    if ok and cd then
      ColosseumDex = cd
    end
  end

  -- Build mapping if not already built
  local mapping = buildColosseumNameMapping()
  if not mapping then return nil end

  -- Try exact match first
  if mapping[speciesName] then
    return mapping[speciesName]
  end

  -- Try lowercase match
  if mapping[speciesName:lower()] then
    return mapping[speciesName:lower()]
  end

  return nil
end

local function dtForFrame()
  local dt = 1 / 60
  if love and love.timer and love.timer.getDelta then
    local ok, got = pcall(love.timer.getDelta)
    if ok and type(got) == "number" and got > 0 and got < 0.25 then
      dt = got
    end
  end
  return dt
end

local function gameObject()
  local ok, Game = pcall(require, "src.core.Game")
  if not ok or type(Game) ~= "table" then return nil end
  return Game
end

local function gameData()
  local Game = gameObject()
  return Game and Game.data or nil
end

local function cleanName(v)
  if type(v) ~= "string" then return nil end
  local s = v:upper()
  s = s:gsub("[^A-Z0-9]", "")
  return s ~= "" and s or nil
end

local function dexNumber(v)
  if type(v) == "number" then
    local n = math.floor(v)
    return n >= 1 and n <= 386 and n or nil
  elseif type(v) == "string" then
    local n = tonumber(v)
    if n then return dexNumber(n) end
  end
  return nil
end

local function speciesDex(v)
  -- Resolve English species names to dex numbers using game data
  if type(v) == "number" then
    local n = math.floor(v)
    return n >= 1 and n <= 386 and n or nil
  elseif type(v) == "string" then
    local n = tonumber(v)
    if n then return dexNumber(n) end
    
    -- Try to resolve English species name using game data
    local data = gameData()
    if data and data.pokemon then
      -- Try exact match first
      for dex, mon in pairs(data.pokemon) do
        if mon.name and mon.name:upper() == v:upper() then
          local dexNum = tonumber(dex)
          if dexNum and dexNum >= 1 and dexNum <= 386 then
            return dexNum
          end
        end
      end
    end
  end
  return nil
end

local function facingVector(facing)
  if facing == "down" then return 0, 1
  elseif facing == "up" then return 0, -1
  elseif facing == "left" then return -1, 0
  elseif facing == "right" then return 1, 0
  end
  return 0, 1  -- Default to down
end

-- Colosseum overworld models are enabled iff ColosseumMon itself is enabled
-- (its own ModSetting-style option gate, default on) -- this is the exact
-- same check OverworldStadium's Colosseum fallback relies on.
local function colosseumEnabled()
  local ok, value = pcall(ColosseumMon.enabled)
  return ok and value == true
end

function OverworldColosseum.safeClaimWilds(state)
  if not (state and state.entities) then return end
  for _, e in ipairs(state.entities) do
    if e and e.wildsAmbientPokemon then
      tagged[e] = false
    end
  end
end

-- Confirm a Colosseum model is available for this pose's species via
-- ColosseumMon (the same bridge OverworldStadium/StadiumFollower/
-- RoamerStadium3D already use). ColosseumMon owns acquisition and caching
-- internally -- there is nothing else to load or cache here.
local function prepareOneFromCache(p, dex)
  if not (p and p.entity and dex) then return false end
  if p.stadiumMon then return false end  -- OverworldStadium already claimed this pose
  -- OverworldStadium's own Colosseum fallback (prepareOneColosseum) sets these
  -- and draws the pose itself. Claiming it here too would drive the SAME shared
  -- actor twice per frame from two different modules.
  if p.colosseumDex or p.colosseumMatrix then return false end

  local ok, available = pcall(ColosseumMon.available, dex, "normal")
  if not ok or not available then
    if not reported["no-model-" .. tostring(dex)] then
      reported["no-model-" .. tostring(dex)] = true
      local log = V.mod and V.mod.log
      if log and log.info then
        pcall(log.info, log, "Colosseum: no model available yet for dex %d", dex)
      end
    end
    return false
  end

  p._colosseumDex = dex
  p._colosseumVariant = "normal"
  p._colosseumActor = true  -- flag consumed by the shadow-cast seam
  return true
end

function OverworldColosseum.tag(entity, speciesOrDex)
  if type(entity) ~= "table" then
    return false
  end
  if speciesOrDex == nil then
    tagged[entity] = nil
    if entity.id then
      taggedById[entity.id] = nil
    end
    return true
  end
  if speciesOrDex == false then
    tagged[entity] = false
    if entity.id then
      taggedById[entity.id] = false
    end
    return true
  end

  -- Log what we're trying to tag (first few times)
  if not reported["tag-input"] then
    reported["tag-input"] = {}
  end
  if not reported["tag-input"][tostring(speciesOrDex)] and #reported["tag-input"] < 10 then
    reported["tag-input"][tostring(speciesOrDex)] = true
    local log = V.mod and V.mod.log
    if log and log.info then
      pcall(log.info, log, "Colosseum: tag called with speciesOrDex='%s' (type=%s)", tostring(speciesOrDex), type(speciesOrDex))
    end
  end

  -- Handle engine species constants like SPECIES_249, SPECIES_094, etc.
  if type(speciesOrDex) == "string" then
    local match = speciesOrDex:match("^SPECIES_(%d+)$")
    if match then
      local dex = tonumber(match)
      if dex and dex >= 1 and dex <= 386 then
        tagged[entity] = dex
        -- Also store by entity ID for more reliable matching
        if entity.id then
          taggedById[entity.id] = dex
          local log = V.mod and V.mod.log
          if log and log.info then
            pcall(log.info, log, "Colosseum: Tagged entity id='%s' with dex=%d", tostring(entity.id), dex)
          end
        end
        return true
      end
    end
  end
  
  local dex = nil
  
  -- Priority 1: Check if entity.sprite has dsSpecies (this is the dex number used by the sprite system)
  if entity.sprite and entity.sprite.dsSpecies then
    dex = dexNumber(entity.sprite.dsSpecies)
    if dex then
      tagged[entity] = dex
      if entity.id then
        taggedById[entity.id] = dex
      end
      return true
    end
  end

  -- Priority 2: Check if speciesOrDex is already a dex number
  dex = dexNumber(speciesOrDex)
  if dex then
    tagged[entity] = dex
    if entity.id then
      taggedById[entity.id] = dex
    end
    return true
  end

  -- Priority 3: Check if entity has dex/id field
  dex = dexNumber(entity.dex or entity.id or entity.speciesId)
  if dex then
    tagged[entity] = dex
    if entity.id then
      taggedById[entity.id] = dex
    end
    return true
  end
  
  -- Priority 4: Extract species name and try to resolve
  local speciesName = speciesOrDex
  if type(speciesOrDex) == "table" then
    speciesName = speciesOrDex.name or speciesOrDex.id or speciesOrDex.species or speciesOrDex.dex
  end
  
  if type(speciesName) ~= "string" then
    print("Colosseum: Could not resolve species from:", tostring(speciesOrDex))
    return false
  end
  
  -- Trim whitespace from species name
  speciesName = speciesName:match("^%s*(.-)%s*$")

  -- Log the species name being resolved (first few times)
  if not reported["species-resolve"] then
    reported["species-resolve"] = {}
  end
  if not reported["species-resolve"][speciesName] and #reported["species-resolve"] < 10 then
    reported["species-resolve"][speciesName] = true
    local log = V.mod and V.mod.log
    if log and log.info then
      pcall(log.info, log, "Colosseum: Trying to resolve species name: '%s'", tostring(speciesName))
    end
  end

  -- Try to get dex from species name using ColosseumDex first
  dex = resolveSpeciesNameToDex(speciesName)
  if dex then
    tagged[entity] = dex
    if entity.id then
      taggedById[entity.id] = dex
      local log = V.mod and V.mod.log
      if log and log.info then
        pcall(log.info, log, "Colosseum: Tagged entity id='%s' with dex=%d (from species name)", tostring(entity.id), dex)
      end
    end
    return true
  end

  -- Fallback: try manual species mapping
  dex = speciesDex(speciesName)
  if dex then
    tagged[entity] = dex
    if entity.id then
      taggedById[entity.id] = dex
      local log = V.mod and V.mod.log
      if log and log.info then
        pcall(log.info, log, "Colosseum: Tagged entity id='%s' with dex=%d (from species name fallback)", tostring(entity.id), dex)
      end
    end
    return true
  end

  -- Fallback: try to get dex from entity sprite if available
  if entity.sprite and entity.sprite.dsSpecies then
    local spriteDex = dexNumber(entity.sprite.dsSpecies)
    if spriteDex then
      tagged[entity] = spriteDex
      if entity.id then
        taggedById[entity.id] = spriteDex
      end
      return true
    end
  end

  -- Fallback: try to get dex from entity species field
  if entity.species then
    local entityDex = dexNumber(entity.species)
    if entityDex then
      tagged[entity] = entityDex
      return true
    end
  end

  -- Log failure for unknown species
  if not reported["unknown-species"] then
    reported["unknown-species"] = {}
  end
  if not reported["unknown-species"][speciesName] and #reported["unknown-species"] < 5 then
    reported["unknown-species"][speciesName] = true
    local log = V.mod and V.mod.log
    if log and log.warn then
      pcall(log.warn, log, "Colosseum: Could not resolve species name: '%s' - not in mapping", tostring(speciesName))
    end
  end

  return false
end

function OverworldColosseum.untag(entity)
  if type(entity) ~= "table" then return false end
  tagged[entity] = nil
  entityDexCache[entity] = nil
  return true
end

function OverworldColosseum.getTaggedDex(entity)
  if type(entity) ~= "table" then return nil end
  local direct = tagged[entity]
  if direct then
    -- direct is now stored as a dex number
    return tonumber(direct) or nil
  end
  if direct ~= nil then return direct or nil end

  -- Try looking up by entity ID
  if entity.id and taggedById[entity.id] then
    return tonumber(taggedById[entity.id]) or nil
  end

  return entityDexCache[entity] or nil
end

function OverworldColosseum.resolveDex(entity)
  if type(entity) ~= "table" then return nil end

  local function remember(d)
    if d and type(entity) == "table" then entityDexCache[entity] = d end
    return d
  end

  -- An explicit tag() call is authoritative developer intent (Roamer.lua,
  -- follower/control_engine.lua, ambient_pokemon.lua all call ow.tag(...)
  -- directly). It must win over every heuristic below -- in particular,
  -- Roamer entities are id'd "TR_ROAM_N" and can never match any single
  -- map's id prefix, and a wandering/ambient NPC can still be an explicitly
  -- tagged Pokemon. Check ID-keyed tags first (survives entity table
  -- identity changes across pose captures), then the direct table.
  if entity.id and taggedById[entity.id] then
    local idDex = taggedById[entity.id]
    if idDex ~= false and type(idDex) == "number" then
      return remember(idDex)
    end
  end

  local direct = tagged[entity]
  if direct ~= nil then
    if direct == false then return nil end
    if type(direct) == "number" then
      return remember(direct)
    end
  end

  -- Check cache
  local cached = entityDexCache[entity]
  if cached then return cached end

  -- Use same resolution approach as OverworldStadium
  -- Check entity fields for dex/species
  local keys = {
    "stadiumDex", "pokemonDex", "pokedex", "dexNo", "dexNumber",
    "stadiumSpecies", "pokemonSpecies", "species", "dex"
  }
  for _, key in ipairs(keys) do
    local d = speciesDex(entity[key])
    if d then return remember(d) end
  end

  -- Check nested entity structures
  for _, key in ipairs({ "def", "obj", "object", "objDef", "data", "event" }) do
    local sub = entity[key]
    if type(sub) == "table" then
      for _, innerKey in ipairs(keys) do
        local d = speciesDex(sub[innerKey])
        if d then return remember(d) end
      end
    end
  end

  -- Try to resolve from entity sprite
  if entity.sprite then
    -- Check sprite dsSpecies (dex number used by sprite system)
    if entity.sprite.dsSpecies then
      local spriteDex = dexNumber(entity.sprite.dsSpecies)
      if spriteDex then return remember(spriteDex) end
    end

    -- Check sprite species
    if entity.sprite.species then
      local spriteSpecies = entity.sprite.species
      -- Handle engine species constants
      if type(spriteSpecies) == "string" then
        local match = spriteSpecies:match("^SPECIES_(%d+)$")
        if match then
          local dex = tonumber(match)
          if dex and dex >= 1 and dex <= 386 then
            return remember(dex)
          end
        end
      end
      -- Try species name resolution
      local result = speciesDex(spriteSpecies)
      if result then return remember(result) end
    end
  end

  -- Fallback to entity fields for roaming/follower Pokemon
  local species = entity._wildsFollowerSpecies
               or entity.ambientSpecies
               or (entity.pokepcMon and entity.pokepcMon.species)
  if species then
    local result = speciesDex(species)
    if result then return remember(result) end
  end

  return nil
end

function OverworldColosseum.prepare(posed)
  local enabled = colosseumEnabled()
  if not reported["prepare-check"] then
    reported["prepare-check"] = true
    local log = V.mod and V.mod.log
    if log and log.info then
      pcall(log.info, log, "Colosseum: prepare called, enabled=%s, posed count=%d", tostring(enabled), #posed)
    end
  end

  if not enabled then return true end
  frameNo = frameNo + 1

  local preparedCount = 0
  local entityCount = 0
  local stadiumCount = 0
  local resolvedCount = 0
  local supportedCount = 0
  local dexCheckCount = 0

  local debugSample = not reported["prepare-sample"]
  if debugSample then reported["prepare-sample"] = true end
  local seenIds
  if debugSample then seenIds = {} end
  local posedEntityIds
  if debugSample then posedEntityIds = {} end

  for _, p in ipairs(posed or {}) do
    p._colosseumActor = nil
    p._colosseumDex = nil
    p._colosseumVariant = nil

    if p.entity then
      entityCount = entityCount + 1
      if debugSample and p.entity.id then 
        seenIds[p.entity.id] = true
        posedEntityIds[#posedEntityIds + 1] = p.entity.id
      end
      if p.stadiumMon or p.colosseumDex or p.colosseumMatrix then
        stadiumCount = stadiumCount + 1
      else
        local okDex, dex = pcall(OverworldColosseum.resolveDex, p.entity)
        if okDex and dex then
          resolvedCount = resolvedCount + 1

          -- Log first few resolved dex values
          if resolvedCount <= 3 and not reported["dex-values"] then
            reported["dex-values"] = true
            local log = V.mod and V.mod.log
            if log and log.info then
              pcall(log.info, log, "Colosseum: resolved dex value %d (type=%s)", dex, type(dex))
            end
          end

          -- Confirm a Colosseum model is available for this species
          supportedCount = supportedCount + 1
          local ok, did = pcall(prepareOneFromCache, p, dex)
          if ok and did then
            preparedCount = preparedCount + 1
          end
        end
      end
    end
  end

  if debugSample then
    local log = V.mod and V.mod.log
    if log and log.info then
      pcall(log.info, log, "Colosseum: All entity IDs in posed this frame: %s",
        #posedEntityIds > 0 and table.concat(posedEntityIds, ", ") or "(none)")
      
      -- Log all tagged IDs first
      local allTagged = {}
      for id, dex in pairs(taggedById) do
        allTagged[#allTagged + 1] = id .. "=" .. tostring(dex)
      end
      pcall(log.info, log, "Colosseum: All tagged IDs in taggedById table: %s",
        #allTagged > 0 and table.concat(allTagged, ", ") or "(none)")
      
      local present, missing = {}, {}
      for id, dex in pairs(taggedById) do
        if seenIds[id] then
          present[#present + 1] = id .. "=" .. tostring(dex)
        else
          missing[#missing + 1] = id .. "=" .. tostring(dex)
        end
      end
      pcall(log.info, log, "Colosseum: tagged IDs present in posed this frame: %s",
        #present > 0 and table.concat(present, ", ") or "(none)")
      pcall(log.info, log, "Colosseum: tagged IDs NOT present in posed this frame (never reach resolveDex at all): %s",
        #missing > 0 and table.concat(missing, ", ") or "(none)")
    end
  end

  -- Stats are a one-shot diagnostic, not a per-frame report. This used to run
  -- an unguarded log.info on EVERY rendered frame: a string format plus a log
  -- write sixty times a second, forever, which is a real cost in the middle of
  -- the scene pass and drowns the log file.
  if not reported["prepare-stats"] then
    reported["prepare-stats"] = true
    local log = V.mod and V.mod.log
    if log and log.info then
      pcall(log.info, log, "Colosseum: detailed stats - total=%d, stadium=%d, resolved=%d, supported=%d, prepared=%d",
        entityCount, stadiumCount, resolvedCount, supportedCount, preparedCount)
    end
  end

  return true
end

function OverworldColosseum.safePrepare(posed)
  local ok, result = pcall(OverworldColosseum.prepare, posed)
  if not ok then
    logOnce("prepare-frame", "Colosseum overworld prepare error: %s", tostring(result))
    return false
  end
  return result ~= false
end

function OverworldColosseum.safeDraw(p)
  if not reported["safeDraw-called"] then
    reported["safeDraw-called"] = true
    local log = V.mod and V.mod.log
    if log and log.info then
      pcall(log.info, log, "Colosseum: safeDraw called")
    end
  end
  local ok, result = pcall(OverworldColosseum.draw, p)
  if not ok then
    logOnce("draw-frame", "Colosseum overworld draw error: %s", tostring(result))
    return false
  end
  return result ~= false
end

-- Shadow casting is best-effort and currently has no real geometry pass of
-- its own (matches the previous behaviour) -- it just confirms the actor is
-- genuinely posable so VoxelScenePatch's shadow seam doesn't treat a pose
-- that failed to resolve a matrix as "handled".
function OverworldColosseum.safeCast(p, ShadowMap)
  if not (p and p._colosseumDex and ShadowMap) then return false end
  local x = (p.px or 0) + 8
  local z = (p.py or 0) + 8
  local y = (p.gh or 0) + (p.lift or 0)
  local fx, fz = facingVector(p.facing or "down")
  local ok, matrix = pcall(ColosseumMon.matrix, p._colosseumDex, p._colosseumVariant or "normal", x, y, z, fx, fz)
  return ok and matrix ~= nil
end

-- Draws the Colosseum model for this pose via ColosseumMon -- the same
-- update -> matrix -> draw sequence RoamerStadium3D and StadiumFollower use.
-- ColosseumMon.update() re-asserts the idle state every frame, which is what
-- keeps the idle animation looping instead of freezing on the bind pose.
function OverworldColosseum.draw(p)
  local dex = p and p._colosseumDex
  if not dex then 
    -- Check if this entity is tagged for Colosseum rendering
    local entityId = p and p.entity and p.entity.id
    if not entityId or not taggedById[entityId] then
      -- Not tagged for Colosseum, fall back to sprite
      return false
    end
    -- Look up dex from taggedById
    dex = taggedById[entityId]
    if dex then
      p._colosseumDex = dex
      p._colosseumVariant = "normal"
    else
      return false
    end
  end
  local variant = p._colosseumVariant or "normal"
  
  -- Log that draw is being called (once per frame)
  if not reported["draw-called"] then
    reported["draw-called"] = true
    local log = V.mod and V.mod.log
    if log and log.info then
      pcall(log.info, log, "Colosseum: draw called for dex %d", dex)
    end
  end

  local x = (p.px or 0) + 8
  local z = (p.py or 0) + 8
  local y = (p.gh or 0) + (p.lift or 0)

  local renderFacing = p.facing or "down"
  local fx, fz = facingVector(renderFacing)

  -- Handle first-person camera rotation (mirrors OverworldStadium's handling)
  local okFirstPerson, FirstPerson = pcall(V.require, "FirstPerson")
  if okFirstPerson and FirstPerson then
    local b = FirstPerson.cardBlend()
    if b > 0 then
      local cameraYaw = FirstPerson.cardYaw(p.px or 0, p.py or 0)
      local face = type(renderFacing) == "string" and string.lower(renderFacing) or renderFacing
      local yaw = 0
      if face == "down" then yaw = cameraYaw * b
      elseif face == "up" then yaw = (cameraYaw + math.pi) * b
      elseif face == "left" then yaw = (cameraYaw + math.pi / 2) * b
      elseif face == "right" then yaw = (cameraYaw - math.pi / 2) * b
      end
      fx = math.sin(yaw)
      fz = math.cos(yaw)
    end
  end

  local dt = dtForFrame()
  local okUpdate = pcall(ColosseumMon.update, dex, variant, dt)
  if not okUpdate then 
    local log = V.mod and V.mod.log
    if log and log.warn then
      pcall(log.warn, log, "Colosseum: draw update failed for dex %d", dex)
    end
    return false 
  end

  local okMatrix, matrix = pcall(ColosseumMon.matrix, dex, variant, x, y, z, fx, fz)
  if not okMatrix or not matrix then 
    local log = V.mod and V.mod.log
    if log and log.warn then
      pcall(log.warn, log, "Colosseum: draw matrix failed for dex %d", dex)
    end
    return false 
  end

  local okDraw, drew = pcall(ColosseumMon.draw, dex, variant, matrix)
  if not okDraw or drew ~= true then
    local log = V.mod and V.mod.log
    if log and log.warn then
      pcall(log.warn, log, "Colosseum: draw failed for dex %d (ok=%s, drew=%s)", dex, tostring(okDraw), tostring(drew))
    end
  else
    if not reported["draw-success"] then
      reported["draw-success"] = true
      local log = V.mod and V.mod.log
      if log and log.info then
        pcall(log.info, log, "Colosseum: draw succeeded for dex %d", dex)
      end
    end
  end
  return okDraw and drew == true
end

-- Preload models for overworld use (called during initialization). This just
-- warms ColosseumMon's own per-species actor cache -- there is no separate
-- cache to maintain here any more.
function OverworldColosseum.preloadSpecies(dexList)
  if not V.ColosseumDex then
    local ok, CD = pcall(V.require, "ColosseumDex")
    if ok and CD then V.ColosseumDex = CD end
  end

  local count = 0
  for _, dex in ipairs(dexList or {}) do
    local ok, available = pcall(ColosseumMon.available, dex, "normal")
    if ok and available then count = count + 1 end
  end
  return count
end

-- VoxelScenePatch installs the pose-level hooks (safePrepare/safeDraw/safeCast).
function OverworldColosseum.install()
  if not V.ColosseumDex then
    local ok, CD = pcall(V.require, "ColosseumDex")
    if ok and CD then V.ColosseumDex = CD end
  end

  -- Preload common species for better first-encounter performance.
  local commonSpecies = { 25, 63, 142, 16, 19, 32, 131, 147, 150, 151 }  -- Pikachu, Abra, Aerodactyl, Pidgey, Rattata, NidoranM, Lapras, Dratini, Mewtwo, Mew
  OverworldColosseum.preloadSpecies(commonSpecies)
  return true
end

return OverworldColosseum