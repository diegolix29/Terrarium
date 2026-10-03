-- HD animated Pokemon sheets: the 2D fallback for Pokemon with no 3D model.
--
-- WHAT THIS IS
--   A small, self-contained sheet resolver + frame player. It answers one
--   question -- "is there HD art for this battler, and which frame is it on
--   right now?" -- and hands the answer to whichever host asks:
--
--     * applyToTextures(battle, out)   the OverworldBattle billboard seam.
--       Every Platinum (and Gen 1-3 overworld) battle draws its 2D Pokemon as
--       BattleBillboard cards from these descriptors. Swapping a descriptor
--       is a no-op for any side the Stadium/Colosseum 3D models already
--       cover, because sideTexture() returns nil for those.
--     * spriteApi                      a CurrentSpriteModels battleSprites v1
--       provider, for battles where CSM owns 2D drawing.
--
-- WHAT IT IS NOT
--   It is not Kanto in Motion. No UI, no battle logic, no downloader, no
--   KIM dependency at runtime. The sheet GEOMETRY was ported from KIM's
--   generated tables (data/hd_sheet_meta.lua, see tools/port_kim_meta.py);
--   the loader below is written for Terrarium. Art credit: JDChaos,
--   "Battle Sprites Reloded" (via Kanto in Motion by HaseoSora).
--
-- WHERE THE IMAGES COME FROM (existence-checked, never a blind 1..N loop)
--   1. mod.cache   hd_sheets/<front|back>/<normal|shiny>/<stem>.png
--   2. the mod     assets/hd-pokemon/<front|back>/<normal|shiny>/<stem>.png
--   <stem> is "NNN", "NNN-m" / "NNN-f" (gender) or "NNN-<form>" (Giratina
--   origin, etc.). KIM's own cache is private to KIM and KIM does not load on
--   Platinum, so it cannot be read from here; copy KIM's
--   assets/battle/hd-pokemon tree into assets/hd-pokemon/ instead.
--
-- CAP: National Dex 1..493 (Gen 4). Anything above is ignored.
--
-- A missing file at ANY step returns nil, which every host treats as "leave
-- the native art alone".
local V = ...

local M = {
  VERSION = 1,
  MAX_DEX = 493,        -- Gen 4 ceiling; 494+ do not exist on Platinum
  COLOSSEUM_MAX = 386,  -- highest dex the Colosseum actor catalog can model
  FRAME_MS = 50,        -- every KIM record uses 50 ms frames
}

M.config = {
  enabled = true,
  filter = "nearest",   -- KIM draws these with nearest filtering
  maxSheets = 8,        -- resident sheets (each holds decoded ImageData)
  cacheDir = "hd_sheets",
  packageDir = "assets/hd-pokemon",
  -- displayScale for a sheet with no metadata row (HD px -> GB px). These are
  -- the medians of KIM's own Gen 2 records.
  defaultScale = { front = 0.33, back = 0.315 },
  -- CSM path only. CSM normalises every 2D battler to one slot height, which
  -- would erase KIM's per-species sizing, so frames are padded on top until
  -- (frameH * displayScale) keeps its ratio to this reference height (in GB
  -- pixels). Species larger than the reference are capped at the slot.
  slotFront = 90,
  slotBack = 112,
}

local mod = V and V.mod

local function clock()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

-- ------- Gen 4 names (387..493), only a safety net for dex resolution -------

local G4_NAMES = [[
TURTWIG GROTLE TORTERRA CHIMCHAR MONFERNO INFERNAPE PIPLUP PRINPLUP EMPOLEON
STARLY STARAVIA STARAPTOR BIDOOF BIBAREL KRICKETOT KRICKETUNE SHINX LUXIO LUXRAY
BUDEW ROSERADE CRANIDOS RAMPARDOS SHIELDON BASTIODON BURMY WORMADAM MOTHIM COMBEE
VESPIQUEN PACHIRISU BUIZEL FLOATZEL CHERUBI CHERRIM SHELLOS GASTRODON AMBIPOM
DRIFLOON DRIFBLIM BUNEARY LOPUNNY MISMAGIUS HONCHKROW GLAMEOW PURUGLY CHINGLING
STUNKY SKUNTANK BRONZOR BRONZONG BONSLY MIMEJR HAPPINY CHATOT SPIRITOMB GIBLE
GABITE GARCHOMP MUNCHLAX RIOLU LUCARIO HIPPOPOTAS HIPPOWDON SKORUPI DRAPION
CROAGUNK TOXICROAK CARNIVINE FINNEON LUMINEON MANTYKE SNOVER ABOMASNOW WEAVILE
MAGNEZONE LICKILICKY RHYPERIOR TANGROWTH ELECTIVIRE MAGMORTAR TOGEKISS YANMEGA
LEAFEON GLACEON GLISCOR MAMOSWINE PORYGONZ GALLADE PROBOPASS DUSKNOIR FROSLASS
ROTOM UXIE MESPRIT AZELF DIALGA PALKIA HEATRAN REGIGIGAS GIRATINA CRESSELIA
PHIONE MANAPHY DARKRAI SHAYMIN ARCEUS
]]

local nameToDex
local function nameKey(s)
  return (tostring(s):upper():gsub("[^A-Z0-9]", ""))
end

local function buildNames()
  nameToDex = {}
  local n = 386
  for word in G4_NAMES:gmatch("%S+") do
    n = n + 1
    nameToDex[word] = n
  end
  M._g4NameCount = n - 386
  -- Opportunistic: the Colosseum namespace publishes 1..386 names.
  local names = V and V.ColosseumDexNames
  if type(names) == "table" then
    for dex, name in pairs(names) do
      if tonumber(dex) and type(name) == "string" then
        nameToDex[nameKey(name)] = tonumber(dex)
      end
    end
  end
end

local function dexFromName(species)
  if species == nil then return nil end
  if not nameToDex then buildNames() end
  return nameToDex[nameKey(species)]
end

-- ------- metadata (geometry ported from KIM, plus optional Gen 4 sidecar) ----

local meta

local function readPackaged(rel)
  if not (mod and type(mod.read) == "function") then return nil end
  local ok, src = pcall(mod.read, mod, rel)
  if ok and type(src) == "string" and src ~= "" then return src end
  return nil
end

local function loadLuaTable(rel)
  local src = readPackaged(rel)
  if not src then return nil end
  local chunk = load(src, "@" .. rel)
  if not chunk then return nil end
  local ok, value = pcall(chunk)
  if ok and type(value) == "table" then return value end
  return nil
end

local function loadMeta()
  if meta then return meta end
  meta = { front = { normal = {}, shiny = {} }, back = { normal = {}, shiny = {} } }
  M._metaCount = { kim = 0, sidecar = 0 }
  local function merge(rel, counter)
    local t = loadLuaTable(rel)
    if not t then return end
    for facing, colors in pairs(t) do
      if meta[facing] then
        for color, rows in pairs(colors) do
          if meta[facing][color] then
            for stem, rec in pairs(rows) do
              meta[facing][color][stem] = rec
              M._metaCount[counter] = M._metaCount[counter] + 1
            end
          end
        end
      end
    end
  end
  merge("data/hd_sheet_meta.lua", "kim")
  -- Sidecar for sheets KIM has no rows for (Gen 4). Same format; wins on a tie.
  merge("data/hd_sheet_meta_gen4.lua", "sidecar")
  return meta
end

-- ------- file presence (memoised, negatives included) ----------------------

local presence = {}   -- rel -> "cache" | "pkg" | false
local failed = {}     -- rel -> true when bytes did not decode
local selCache = {}   -- nested memo of stem selection
local FACINGS = { front = true, back = true }
local COLORS = { normal = true, shiny = true }

local function relOf(facing, color, stem)
  return facing .. "/" .. color .. "/" .. stem .. ".png"
end

local function cacheKeyOf(rel) return M.config.cacheDir .. "/" .. rel end
local function pkgPathOf(rel) return M.config.packageDir .. "/" .. rel end

local function sized(info)
  if type(info) ~= "table" then return info ~= nil and info ~= false end
  return (tonumber(info.size) or 1) > 0
end

local function locate(facing, color, stem)
  local rel = relOf(facing, color, stem)
  local hit = presence[rel]
  if hit ~= nil then return hit, rel end
  hit = false
  local cache = mod and mod.cache
  if cache and type(cache.info) == "function" then
    local ok, info = pcall(cache.info, cache, cacheKeyOf(rel))
    if ok and info ~= nil and sized(info) then hit = "cache" end
  end
  if not hit and mod and type(mod.info) == "function" then
    local ok, info = pcall(mod.info, mod, pkgPathOf(rel))
    if ok and info ~= nil and sized(info) then hit = "pkg" end
  end
  presence[rel] = hit
  return hit, rel
end

local function readBytes(where, rel)
  if where == "cache" then
    local cache = mod and mod.cache
    if cache and type(cache.read) == "function" then
      local ok, bytes = pcall(cache.read, cache, cacheKeyOf(rel))
      if ok and type(bytes) == "string" and #bytes > 0 then return bytes end
    end
  elseif where == "pkg" then
    local ok, bytes = pcall(mod.read, mod, pkgPathOf(rel))
    if ok and type(bytes) == "string" and #bytes > 0 then return bytes end
  end
  return nil
end

-- ------- battler identity ---------------------------------------------------

-- Species that genuinely have per-form art. Anything else ignores `form`, so
-- Unown-style cosmetic forms keep KIM's single-sheet behaviour.
local FORM_AWARE = {
  [412] = true, [413] = true, [421] = true, [422] = true, [423] = true,
  [479] = true, [487] = true, [492] = true, [493] = true,
}
local DEFAULT_FORM = {
  [412] = "plant", [413] = "plant", [421] = "overcast", [422] = "west",
  [423] = "west", [479] = "normal", [487] = "altered", [492] = "land",
  [493] = "normal",
}
local GENERIC_DEFAULT_FORM = { [""] = true, ["0"] = true, normal = true, default = true, base = true }

local function speciesDex(data, mon)
  local species = mon.species
  if species == nil then species = mon.id end
  local defs = data and data.pokemon
  local def = defs and species ~= nil and (defs[species] or defs[tostring(species)])
  local dex = tonumber(def and (def.nationalDex or def.dex or def.number))
    or dexFromName(species)
    or tonumber(mon.nationalDex) or tonumber(mon.speciesIndex) or tonumber(mon.dex)
    or tonumber(def and def.index)
  if not dex and type(species) == "number" then dex = species end
  if dex and dex % 1 == 0 and dex >= 1 and dex <= M.MAX_DEX then return dex end
  return nil
end

local function monShiny(battler, mon)
  local support = V and V.ShinySupport
  if support and type(support.variant) == "function" then
    local ok, v = pcall(support.variant, battler)
    if ok and v == "shiny" then return true end
  end
  if mon.shiny == true then return true end
  local flag = mon.isShiny
  if type(flag) == "function" then
    local ok, v = pcall(flag, mon)
    if ok and v == true then return true end
  elseif flag == true then
    return true
  end
  if type(mon.dvs) == "table" then
    local okS, Stats = pcall(require, "src.pokemon.Stats")
    if okS and Stats and type(Stats.isShiny) == "function" then
      local ok, v = pcall(Stats.isShiny, mon.dvs)
      if ok and v == true then return true end
    end
  end
  return false
end

local function monGender(mon)
  local value = mon.gender
  if type(value) == "function" then
    local ok, resolved = pcall(value, mon)
    if ok then value = resolved end
  end
  if value == nil then value = mon.sex end
  if type(value) == "string" then
    local key = value:upper():gsub("[^A-Z]", "")
    if key == "F" or key == "FEMALE" or key == "GIRL" then return "f" end
    if key == "M" or key == "MALE" or key == "BOY" then return "m" end
  elseif type(value) == "number" then
    if value == 1 then return "f" end
    if value == 0 then return "m" end
  end
  return nil
end

-- Returns the normalised form key ("origin") for form-aware species, or nil
-- when the mon is in its default form / the species has no form art.
local function monForm(dex, mon)
  if not FORM_AWARE[dex] then return nil end
  local raw = mon.form
  if raw == nil then raw = mon.forme end
  if raw == nil then raw = mon.formName end
  if raw == nil then raw = mon.formId end
  if raw == nil then return nil end
  local key
  if type(raw) == "number" then
    if raw == 0 then return nil end
    key = "f" .. tostring(math.floor(raw))
  else
    key = tostring(raw):lower():gsub("[^a-z0-9]", "")
  end
  if GENERIC_DEFAULT_FORM[key] or key == DEFAULT_FORM[dex] then return nil end
  return key
end

-- Normalised identity of one battler, or nil when it is not a supported species.
local function identify(data, battler)
  if type(battler) ~= "table" then return nil end
  local mon = type(battler.mon) == "table" and battler.mon or battler
  local dex = speciesDex(data, mon)
  if not dex then return nil end
  return {
    dex = dex,
    shiny = monShiny(battler, mon),
    gender = monGender(mon),
    form = monForm(dex, mon),
  }
end
M.identify = identify

-- ------- stem selection (existence-based, memoised) -------------------------

local function stemCandidates(dex, gender, form)
  local base = string.format("%03d", dex)
  if form then return { base .. "-" .. form } end
  if gender then return { base .. "-" .. gender, base, base .. "-m", base .. "-f" } end
  return { base, base .. "-m", base .. "-f" }
end

-- First candidate stem whose file exists. A form that has no file resolves to
-- nothing, so e.g. Giratina-Origin stays native instead of showing Altered art.
local function chooseStem(facing, color, dex, gender, form)
  local a = selCache[facing]; if not a then a = {}; selCache[facing] = a end
  local b = a[color]; if not b then b = {}; a[color] = b end
  local c = b[dex]; if not c then c = {}; b[dex] = c end
  local gk = gender or "-"
  local d = c[gk]; if not d then d = {}; c[gk] = d end
  local fk = form or "-"
  local hit = d[fk]
  if hit ~= nil then return hit or nil end
  hit = false
  for _, stem in ipairs(stemCandidates(dex, gender, form)) do
    if locate(facing, color, stem) then hit = stem; break end
  end
  d[fk] = hit
  return hit or nil
end

-- ------- sheets --------------------------------------------------------------

local sheets = {}
local sheetCount = 0
local starts = {}
local startCount = 0
M._stats = { loaded = 0, evicted = 0, decodeFailed = 0, adjusted = 0, static = 0 }

local function layoutFor(rec, iw, ih, facing)
  if rec then
    local w, h, cols, frames, scale = rec[1], rec[2], rec[3], rec[4], rec[5]
    local rows = math.ceil(frames / cols)
    if cols * w <= iw and rows * h <= ih then
      return w, h, cols, frames, scale, rec[6] or M.FRAME_MS
    end
    -- Sheet was re-encoded at another size: keep the frame count, re-derive
    -- the cell from the image so we never read outside it.
    local nw, nh = math.floor(iw / cols), math.floor(ih / rows)
    if nw > 0 and nh > 0 then
      M._stats.adjusted = M._stats.adjusted + 1
      return nw, nh, cols, frames, scale, rec[6] or M.FRAME_MS
    end
  end
  M._stats.static = M._stats.static + 1
  return iw, ih, 1, 1, M.config.defaultScale[facing] or 0.33, M.FRAME_MS
end

local function releaseSheet(s)
  for _, cache in pairs(s.images) do
    for _, image in pairs(cache) do
      if type(image) == "userdata" or type(image) == "table" then
        if image.release then pcall(image.release, image) end
      end
    end
  end
  if s.data and s.data.release then pcall(s.data.release, s.data) end
  s.images = {}
  s.data = nil
end

local function evict(keep)
  local now = clock()
  while sheetCount > M.config.maxSheets do
    local oldestKey, oldest
    for key, s in pairs(sheets) do
      if s ~= keep and (not oldest or s.used < oldest.used) then oldestKey, oldest = key, s end
    end
    -- Never evict a sheet drawn in the last quarter second (a battle needs two).
    if not oldest or now - oldest.used < 0.25 then break end
    releaseSheet(oldest)
    sheets[oldestKey] = nil
    sheetCount = sheetCount - 1
    M._stats.evicted = M._stats.evicted + 1
  end
end

local function loadSheet(facing, color, stem)
  local where, rel = locate(facing, color, stem)
  if not where then return nil end
  local s = sheets[rel]
  if s then s.used = clock(); return s end
  if failed[rel] then return nil end
  if not (love and love.filesystem and love.image and love.graphics) then return nil end
  local bytes = readBytes(where, rel)
  local data
  if bytes then
    local ok, decoded = pcall(function()
      return love.image.newImageData(love.filesystem.newFileData(bytes, stem .. ".png"))
    end)
    if ok then data = decoded end
  end
  if not data then
    failed[rel] = true
    M._stats.decodeFailed = M._stats.decodeFailed + 1
    return nil
  end
  local iw, ih = data:getDimensions()
  local rec = loadMeta()[facing][color][stem]
  local w, h, cols, frames, scale, ms = layoutFor(rec, iw, ih, facing)
  s = {
    rel = rel, data = data, iw = iw, ih = ih, w = w, h = h, cols = cols,
    frames = frames, scale = scale, ms = ms, images = {}, used = clock(),
    stem = stem, facing = facing, color = color, source = where, hasMeta = rec ~= nil,
  }
  sheets[rel] = s
  sheetCount = sheetCount + 1
  M._stats.loaded = M._stats.loaded + 1
  evict(s)
  return s
end

-- One decoded frame as its own Image. `padH` (optional) makes the image
-- taller than the cell by adding transparent rows on TOP, keeping the feet on
-- the bottom edge.
local function frameImage(s, index, padH)
  if not s.data then return nil end
  local tall = (padH and padH > s.h) and padH or s.h
  local cache = s.images[tall]
  if not cache then cache = {}; s.images[tall] = cache end
  local image = cache[index]
  if image then return image end
  local col = (index - 1) % s.cols
  local row = math.floor((index - 1) / s.cols)
  local ok, made = pcall(function()
    local fd = love.image.newImageData(s.w, tall)
    fd:paste(s.data, 0, tall - s.h, col * s.w, row * s.h, s.w, s.h)
    local img = love.graphics.newImage(fd)
    if img.setFilter then img:setFilter(M.config.filter, M.config.filter) end
    return img
  end)
  if not ok or not made then return nil end
  cache[index] = made
  return made
end

local function frameIndex(s, key)
  if s.frames <= 1 then return 1 end
  local now = clock()
  local t0 = starts[key]
  if not t0 then
    if startCount > 64 then starts = {}; startCount = 0 end
    t0 = now; starts[key] = t0; startCount = startCount + 1
  end
  local total = s.frames * s.ms
  local ms = ((now - t0) * 1000) % total
  return math.floor(ms / s.ms) + 1
end

-- ------- public: generic query ---------------------------------------------

function M.supported(dex)
  dex = tonumber(dex)
  return dex ~= nil and dex % 1 == 0 and dex >= 1 and dex <= M.MAX_DEX
end

-- True when a sheet file exists for the query (no decode, no allocation).
function M.available(dex, facing, shiny, gender, form)
  if not (M.supported(dex) and FACINGS[facing]) then return false end
  return chooseStem(facing, shiny and "shiny" or "normal", dex, gender, form) ~= nil
end

-- Current frame for a query. Returns image, info or nil.
--   query = {dex, facing = "front"|"back", shiny, gender = "m"|"f", form, key, padH}
-- info = {w, h, scale, frame, frames, stem, source, imageH}
function M.frame(query)
  if type(query) ~= "table" or not M.supported(query.dex) then return nil end
  local facing = query.facing
  if not FACINGS[facing] then return nil end
  local color = query.shiny and "shiny" or "normal"
  local stem = chooseStem(facing, color, query.dex, query.gender, query.form)
  if not stem then return nil end
  local s = loadSheet(facing, color, stem)
  if not s then return nil end
  local index = frameIndex(s, tostring(query.key or "") .. ":" .. s.rel)
  local image = frameImage(s, index, query.padH)
  if not image then return nil end
  local _, imageH = image:getDimensions()
  return image, {
    w = s.w, h = s.h, scale = s.scale, frame = index, frames = s.frames,
    stem = s.stem, source = s.source, imageH = imageH,
  }
end

local function dexFromData(data, species)
  if not (data and data.pokemon and species ~= nil) then return nil end
  local def = data.pokemon[species] or data.pokemon[tostring(species)]
  if type(def) == "table" then
    local d = tonumber(def.nationalDex or def.dex or def.number or def.index)
    if M.supported(d) then return d end
  end
  if type(species) ~= "string" then return nil end
  local key = nameKey(species)
  for id, row in pairs(data.pokemon) do
    if type(row) == "table" then
      if nameKey(tostring(id)) == key
          or (type(row.name) == "string" and nameKey(row.name) == key) then
        local d = tonumber(row.nationalDex or row.dex or row.number or row.index)
        if M.supported(d) then return d end
      end
    end
  end
  return nil
end

-- Dex number from a species name, "SPECIES_025", a number, or an overworld
-- entity / pose. Used by roamers and followers (battle identify() wants a
-- battler table, which those entities are not).
function M.dexOf(src, data)
  if src == nil then return nil end
  if not data then
    local ok, Game = pcall(require, "src.core.Game")
    if ok and Game then
      data = Game.data
      if not data and type(Game.get) == "function" then
        local inst = Game:get()
        data = inst and inst.data
      end
    end
  end
  if type(src) == "number" then
    return M.supported(src) and src or nil
  end
  if type(src) == "string" then
    local n = tonumber(src)
    if M.supported(n) then return n end
    local tagged = src:match("SPECIES_(%d+)")
    if tagged then
      n = tonumber(tagged)
      return M.supported(n) and n or nil
    end
    return dexFromName(src) or dexFromData(data, src)
  end
  if type(src) ~= "table" then return nil end
  local e = src
  if type(src.entity) == "table" then e = src.entity end
  local sprite = e.sprite
  local def = sprite and sprite.def
  local candidates = {
    e.dex, e.nationalDex, e.speciesIndex,
    e.species, e._wildsFollowerSpecies, e.dsSpecies,
    sprite and (sprite.dsSpecies or sprite.species),
    def and def.dsSpecies, def and def.hdDex,
  }
  for i = 1, #candidates do
    local d = M.dexOf(candidates[i], data)
    if d then return d end
  end
  local id = identify(data, e)
  return id and id.dex or nil
end

-- Overworld cards only have front and back sheets. Followers default to the
-- back (walking behind the player); roamers face the camera with the front
-- unless they are walking north.
function M.sheetFacing(worldFacing, role)
  local face = type(worldFacing) == "string" and worldFacing:lower() or worldFacing
  if role == "follower" then
    if face == "down" then return "front" end
    return "back"
  end
  if face == "up" then return "back" end
  return "front"
end

-- Stamp the current HD frame onto a sprite def for SpriteBillboards. Does not
-- replace def.image: the 2D SpriteRenderer walk sheet stays in place.
function M.applyOverworld(def, query)
  if type(def) ~= "table" or type(query) ~= "table" then return false end
  if not M.isEnabled(query.game) then return false end
  local image, info = M.frame(query)
  if not image then return false end
  local scale = 16 / math.max(info.h or 1, 1)
  def.hdImage = image
  def.hdFrameW = info.w
  def.hdFrameH = info.h
  def.scale = scale
  def.heightScale = scale
  def.trueColor = true
  def.frames = 1
  def.walker = false
  return true
end

-- Per-entity overlay so two of the same species can hold different frames
-- without mutating the shared walk-sheet def the 2D blit still uses.
function M.bindOverworldDef(host, baseDef, query)
  if type(baseDef) ~= "table" then return nil end
  local overlay = type(host) == "table" and host._hdOverworldDef or nil
  if not overlay then
    overlay = {}
    if type(host) == "table" then host._hdOverworldDef = overlay end
  end
  overlay.id = baseDef.id
  overlay.image = baseDef.image
  overlay.dsSpecies = baseDef.dsSpecies
  overlay.hdDex = baseDef.hdDex or (query and query.dex)
  if not M.applyOverworld(overlay, query) then return nil end
  return overlay
end

-- ------- hosts -------------------------------------------------------------

local function gameOf(host)
  if type(host) ~= "table" then return nil end
  return host.game or (host.battle and host.battle.game) or (mod and mod.game)
end

local function dataOf(host)
  if type(host) ~= "table" then return nil end
  local game = gameOf(host)
  return host.data or (game and game.data)
end

function M.isEnabled(game)
  if M.config.enabled == false then return false end
  local save = game and game.save
  local p = type(save) == "table" and save.terrariumBattle
  if type(p) == "table" and p.hdSheetsEnabled == false then return false end
  return true
end

-- Every 3D battle mode (2D-3D A/B, STADIUM A/B, COLOSSEUM A/B) shows the FRONT
-- sheet for BOTH sides: the camera looks at the player's mon from the side, so
-- the back-view art is wrong there. Back sheets are reserved for followers and
-- roamers, which ask HDPokemonSheets.frame({facing = "back"}) directly.
local function facingFor(side) return "front" end

-- ---- billboard seam (OverworldBattle.textures) ----

-- Replacement descriptor for one side, or nil to keep the engine's native pic.
-- `tex` is the descriptor sideTexture() produced: it only exists when nothing
-- 3D covers this side and the pic is visible, which is exactly "no model".
function M.textureFor(battle, side, tex)
  if type(battle) ~= "table" or not FACINGS[facingFor(side)] then return nil end
  if type(tex) ~= "table" or tex.trainer then return nil end
  if not M.isEnabled(gameOf(battle)) then return nil end
  local id = identify(dataOf(battle), battle[side])
  if not id then return nil end
  local image, info = M.frame({
    dex = id.dex, facing = facingFor(side), shiny = id.shiny,
    gender = id.gender, form = id.form, key = "bb:" .. side,
  })
  if not image then return nil end
  -- KIM's displayScale is HD pixels -> Game Boy pixels, which is the unit
  -- BattleBillboard sizes cards in. Feet-centred anchor, no padding needed.
  local cw, ch = info.w * info.scale, info.h * info.scale
  return {
    canvas = image, ax = cw / 2, ay = ch, cw = cw, ch = ch,
    trainer = false, hd = true, dex = id.dex, stem = info.stem,
  }
end

function M.applyToTextures(battle, out)
  if type(out) ~= "table" then return false end
  local changed = false
  for _, side in ipairs({ "enemy", "player" }) do
    local tex = out[side]
    if tex and not tex.hd then
      local ok, repl = pcall(M.textureFor, battle, side, tex)
      if ok and repl then out[side] = repl; changed = true end
    end
  end
  return changed
end

-- ---- CurrentSpriteModels seam ----

-- True when this side must be drawn by the 2D fallback because the Colosseum
-- actor catalog structurally has no model for it (dex above 386) AND an HD
-- sheet actually exists. CSM uses this to lift its "CBE owns the battle, never
-- draw 2D" rule for exactly these sides and nothing else.
function M.ownsSide(context, battler)
  if not M.isEnabled(gameOf(context)) then return false end
  local id = identify(dataOf(context), battler)
  if not id or id.dex <= M.COLOSSEUM_MAX then return false end
  return M.available(id.dex, "front", id.shiny, id.gender, id.form)
end

local function slotPad(scale, facing, cellH)
  local ref = facing == "back" and M.config.slotBack or M.config.slotFront
  local want = math.ceil(ref / math.max(scale, 0.01))
  if want > cellH then return want end
  return nil
end

M.spriteApi = {
  version = 1,
  portable = true,
  priority = 10,
  selected = function(context)
    return M.isEnabled(gameOf(context))
  end,
  resolve = function(context, side, battler, image)
    local id = identify(dataOf(context), battler)
    if not id then return nil end
    local facing = facingFor(side)
    -- Size is a property of the sheet, so ask for the geometry first.
    local color = id.shiny and "shiny" or "normal"
    local stem = chooseStem(facing, color, id.dex, id.gender, id.form)
    if not stem then return nil end
    local s = loadSheet(facing, color, stem)
    if not s then return nil end
    local img = M.frame({
      dex = id.dex, facing = facing, shiny = id.shiny, gender = id.gender,
      form = id.form, key = "csm:" .. side, padH = slotPad(s.scale, facing, s.h),
    })
    return img
  end,
}

-- ------- housekeeping ------------------------------------------------------

-- Forget every file-presence answer (after the user drops new sheets in).
function M.rescan()
  presence = {}; failed = {}; selCache = {}
  for key, s in pairs(sheets) do releaseSheet(s); sheets[key] = nil end
  sheetCount = 0; starts = {}; startCount = 0
  return true
end

function M.status()
  local m = loadMeta()
  return {
    version = M.VERSION, maxDex = M.MAX_DEX, enabled = M.config.enabled,
    residentSheets = sheetCount, maxSheets = M.config.maxSheets,
    metaRows = M._metaCount, stats = M._stats,
    cacheDir = M.config.cacheDir, packageDir = M.config.packageDir,
    hasFrontMeta = next(m.front.normal) ~= nil,
  }
end

return M
