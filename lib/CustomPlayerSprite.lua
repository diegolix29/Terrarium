-- Custom animated Gold player sprite picker for STADIUM2_OVERWORLD_MODELS.
--
-- The engine's SpriteRenderer already owns Gold's movement cadence and pose
-- contract, so this module only supplies a user-selected sheet as a normal
-- sprite definition.  The required layout is one vertical strip of 6 frames:
--   0 stand down
--   1 stand up
--   2 stand left
--   3 walk down
--   4 walk up
--   5 walk left
-- Right-facing is mirrored by SpriteRenderer, and up/down walking alternates
-- the OAM flip with stepFlip exactly like the cartridge renderer.
--
-- The picked image is copied into the engine save directory and referenced by
-- a revisioned filename.  A new selection never overwrites an already-decoded
-- texture, avoiding the same stale PNG cache problem fixed for battle
-- backgrounds in v0.2.97.
local V = ...
local M = {}
local Compat = V.require("EngineCompat")

local PICKED_ROM = "picked_rom.gb"
local PENDING_FLAG = "stadium2_custom_player_sprite_picker_pending.flag"
local OTHER_PENDING_FLAGS = {
  "stadium2_battle_background_picker_pending.flag",
  "stadium_overworld_picker_pending.flag",
}
local DESKTOP_STAGE = "stadium2_custom_player_sprite_pick.bin"
local META_FILE = "stadium2_custom_player_sprite.meta"
local BASE_NAME = "stadium2_custom_player_sprite"
local REV_PREFIX = BASE_NAME .. "_r"
local MAX_BYTES = 16 * 1024 * 1024
local EXTENSIONS = { "png", "jpg", "bmp" }

local function text(s, ...)
  local ok, Strings = pcall(require, "src.core.Strings")
  if ok and type(Strings) == "function" then
    local okText, value = pcall(Strings, s, ...)
    if okText then return value end
  end
  if select("#", ...) > 0 then
    local okFmt, value = pcall(string.format, s, ...)
    if okFmt then return value end
  end
  return s
end

local function fs()
  return Compat.fs()
end

local function safeRemove(path)
  local f = fs()
  if f and type(f.remove) == "function" then pcall(f.remove, path) end
end

local function fileInfo(path)
  local f = fs()
  if not (f and type(f.getInfo) == "function") then return nil end
  local ok, info = pcall(f.getInfo, path, "file")
  return ok and info or nil
end

local function writeFile(path, data)
  local f = fs()
  if not (f and type(f.write) == "function") then
    return false, "save filesystem unavailable"
  end
  local ok, a, b = pcall(f.write, path, data)
  if not ok then return false, tostring(a) end
  if a == false or a == nil then return false, tostring(b or "write failed") end
  return true
end

local function readFile(path)
  local f = fs()
  if not (f and type(f.read) == "function") then
    return nil, "save filesystem unavailable"
  end
  local ok, a, b = pcall(f.read, path)
  if not ok then return nil, tostring(a) end
  if type(a) ~= "string" then return nil, tostring(b or "read failed") end
  return a
end

local function setStatus(value, err)
  M._status = value
  M._lastError = err and tostring(err) or nil
end

local function optionEnabled(key, default)
  local mod = V and V.mod
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return default end
  local ok, value = pcall(options.get, options, key)
  if not ok or value == nil then return default end
  return not (value == false or value == 0 or value == "0"
    or value == "false" or value == "off")
end

function M.enabled()
  return optionEnabled("customPlayerSprite", false)
end

local function formatOf(data)
  if type(data) ~= "string" then return nil end
  if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png", "PNG" end
  local a, b, c = data:byte(1, 3)
  if a == 0xFF and b == 0xD8 and c == 0xFF then return "jpg", "JPG" end
  if data:sub(1, 2) == "BM" then return "bmp", "BMP" end
  return nil
end

local function legacyPathFor(ext)
  return BASE_NAME .. "." .. tostring(ext)
end

local function pathFor(ext, revision)
  return REV_PREFIX .. tostring(revision) .. "." .. tostring(ext)
end

local function parseMeta(raw)
  if type(raw) ~= "string" then return nil, 0, nil, nil end
  local path, revision, fw, fh = raw:match(
    "^([^\r\n]+)[\r\n]+(%d+)[\r\n]+(%d+)[xX](%d+)")
  if not path then
    path, revision = raw:match("^([^\r\n]+)[\r\n]+(%d+)")
  end
  if not path then path = raw:match("^([^\r\n]+)") end
  revision = tonumber(revision)
    or tonumber(path and path:match("_r(%d+)%.[^%.]+$")) or 0
  return path, revision, tonumber(fw), tonumber(fh)
end

local function readMeta()
  local raw = readFile(META_FILE)
  local path, revision, fw, fh = parseMeta(raw)
  if path and fileInfo(path) then return path, revision, fw, fh end
  return nil, revision or 0, nil, nil
end

local function metaPath()
  local path, revision = readMeta()
  if path then return path end
  -- Forward-compatible legacy scan in case a development build wrote a fixed
  -- path before revisioned sprite resources shipped.
  for _, ext in ipairs(EXTENSIONS) do
    local legacy = legacyPathFor(ext)
    if fileInfo(legacy) then
      writeFile(META_FILE, legacy .. "\n" .. tostring(revision or 0) .. "\n")
      return legacy
    end
  end
  return nil
end

local function removeLegacyImages(keep)
  for _, ext in ipairs(EXTENSIONS) do
    local path = legacyPathFor(ext)
    if path ~= keep then safeRemove(path) end
  end
end

local function imageDimensions(path)
  if not (love and love.graphics and type(love.graphics.newImage) == "function") then
    return nil, nil, "image decoder unavailable"
  end
  local ok, image = pcall(love.graphics.newImage, path)
  if not (ok and image) then return nil, nil, tostring(image) end
  local iw, ih
  if type(image.getDimensions) == "function" then
    iw, ih = image:getDimensions()
  else
    iw = type(image.getWidth) == "function" and image:getWidth() or nil
    ih = type(image.getHeight) == "function" and image:getHeight() or nil
  end
  if type(image.setFilter) == "function" then
    pcall(image.setFilter, image, "nearest", "nearest")
  end
  return tonumber(iw), tonumber(ih), nil
end

local function validateLayout(path)
  local iw, ih, err = imageDimensions(path)
  if not iw or not ih then return nil, err or "image has no dimensions" end
  if iw < 8 or ih < 48 or iw > 1024 or ih > 6144 then
    return nil, "sprite sheet must be 8-1024 px wide and contain six usable frames"
  end
  if ih % 6 ~= 0 then
    return nil, "sprite sheet height must divide evenly into 6 vertical animation frames"
  end
  local fh = ih / 6
  if fh < 8 or fh > 1024 then
    return nil, "each animation frame must be 8-1024 pixels tall"
  end
  return { width = iw, height = ih, frameWidth = iw, frameHeight = fh }
end

local function cacheToken(path, fw, fh)
  local info = path and fileInfo(path)
  if not info then return nil end
  return table.concat({ path, tostring(info.size or ""), tostring(info.modtime or ""),
    tostring(fw or ""), tostring(fh or "") }, ":")
end

local function currentDef()
  local path, _, fw, fh = readMeta()
  if not path then path = metaPath() end
  if not path then return nil end

  if not (fw and fh) then
    local layout, err = validateLayout(path)
    if not layout then
      setStatus("BAD SHEET", err)
      return nil
    end
    fw, fh = layout.frameWidth, layout.frameHeight
  end

  local token = cacheToken(path, fw, fh)
  if not token then return nil end
  if M._def and M._defToken == token then return M._def end

  M._def = {
    id = "STADIUM2_CUSTOM_PLAYER",
    image = path,
    frames = 6,
    walker = true,
    trueColor = true,
    frameWidth = fw,
    frameHeight = fh,
    anchorX = fw / 2,
    anchorY = fh,
    paletteId = 0,
    palette = "PAL_OW_RED",
    stadium2CustomPlayer = true,
  }
  M._defToken = token
  return M._def
end

function M.definition()
  return currentDef()
end

function M.active()
  return M.enabled() and currentDef() ~= nil
end

local function installData(data)
  if type(data) ~= "string" or #data == 0 then
    setStatus("IMPORT ERROR", "selected file could not be read")
    return false, M._lastError
  end
  if #data > MAX_BYTES then
    setStatus("TOO LARGE", "player sprite exceeds 16 MiB")
    return false, M._lastError
  end

  local ext, label = formatOf(data)
  if not ext then
    setStatus("NOT IMAGE", "choose a PNG, JPEG, or BMP image")
    return false, M._lastError
  end

  local oldPath, oldRevision = readMeta()
  if not oldPath then oldPath = metaPath() end
  oldRevision = tonumber(oldRevision) or 0
  M._revision = math.max(tonumber(M._revision) or 0, oldRevision) + 1
  local target = pathFor(ext, M._revision)

  safeRemove(target)
  local okWrite, writeErr = writeFile(target, data)
  if not okWrite then
    setStatus("WRITE ERROR", writeErr)
    return false, M._lastError
  end

  local layout, layoutErr = validateLayout(target)
  if not layout then
    safeRemove(target)
    setStatus("BAD SHEET", layoutErr)
    return false, M._lastError
  end

  local meta = table.concat({ target, tostring(M._revision),
    tostring(layout.frameWidth) .. "x" .. tostring(layout.frameHeight), "" }, "\n")
  local okMeta, metaErr = writeFile(META_FILE, meta)
  if not okMeta then
    safeRemove(target)
    setStatus("WRITE ERROR", metaErr)
    return false, M._lastError
  end

  if oldPath and oldPath ~= target then safeRemove(oldPath) end
  removeLegacyImages(target)
  M._def, M._defToken = nil, nil
  local def = currentDef()
  if not def then
    -- The file already decoded during validateLayout, so this is mainly a
    -- persistence/fs guard. Keep the new file but report the issue clearly.
    setStatus("BAD SHEET", M._lastError or "sprite definition could not be built")
    return false, M._lastError
  end
  setStatus("CUSTOM " .. label)
  return true
end

local function consumeMobilePick()
  if not fileInfo(PENDING_FLAG) then return false end
  local pickedInfo = fileInfo(PICKED_ROM)
  if not pickedInfo then return false end
  if tonumber(pickedInfo.size) and pickedInfo.size > MAX_BYTES then
    safeRemove(PICKED_ROM)
    safeRemove(PENDING_FLAG)
    setStatus("TOO LARGE", "player sprite exceeds 16 MiB")
    return true
  end

  local data, err = readFile(PICKED_ROM)
  local ok, why = false, err
  if data then ok, why = installData(data) end
  safeRemove(PICKED_ROM)
  safeRemove(PENDING_FLAG)
  if not ok and not M._status then setStatus("IMPORT ERROR", why) end
  return true
end

function M.poll()
  if not fileInfo(PENDING_FLAG) then
    M._pendingIdleFrames = 0
    return false
  end
  if fileInfo(PICKED_ROM) then
    M._pendingIdleFrames = 0
    return consumeMobilePick()
  end
  M._pendingIdleFrames = (M._pendingIdleFrames or 0) + 1
  if M._pendingIdleFrames > 120 then
    safeRemove(PENDING_FLAG)
    M._pendingIdleFrames = 0
    if M._status == "PICK..." then M._status = nil end
  end
  return false
end

local function otherPickerPending()
  for _, flag in ipairs(OTHER_PENDING_FLAGS) do
    if fileInfo(flag) then return true, flag end
  end
  return false
end

local function startMobilePicker()
  local f = fs()
  if not (f and type(f.write) == "function") then
    setStatus("NO PICKER", "save filesystem unavailable")
    return false
  end
  local pending = otherPickerPending()
  if pending then
    setStatus("PICKER BUSY", "another file picker is already active")
    return false
  end

  safeRemove(PICKED_ROM)
  safeRemove(PENDING_FLAG)
  local okMark = writeFile(PENDING_FLAG, "custom-player-sprite\n")
  if not okMark then
    setStatus("NO PICKER", "could not create picker marker")
    return false
  end
  setStatus("PICK...")

  local opener = Compat.openMobileFilePicker or Compat.openMobileRomPicker
  local ok, launched, why = pcall(opener)
  if not ok or not launched then
    safeRemove(PENDING_FLAG)
    setStatus("NO PICKER", ok and why or launched)
    return false
  end
  return true
end

local function startDesktopPicker()
  if type(Compat.chooseImageFile) ~= "function" then
    setStatus("NO PICKER", "desktop image picker unavailable")
    return false
  end
  local okPick, path = pcall(Compat.chooseImageFile, "Choose Animated Player Sprite Sheet")
  if not okPick then
    setStatus("NO PICKER", path)
    return false
  end
  if type(path) ~= "string" or path == "" then
    M._status = nil
    return false
  end

  safeRemove(DESKTOP_STAGE)
  local okStage, stagedOrErr = Compat.stageExternal(path, DESKTOP_STAGE)
  if not okStage then
    setStatus("COPY ERROR", stagedOrErr)
    return false
  end
  local stagedInfo = fileInfo(DESKTOP_STAGE)
  if stagedInfo and tonumber(stagedInfo.size) and stagedInfo.size > MAX_BYTES then
    safeRemove(DESKTOP_STAGE)
    setStatus("TOO LARGE", "player sprite exceeds 16 MiB")
    return false
  end
  local data, readErr = readFile(DESKTOP_STAGE)
  safeRemove(DESKTOP_STAGE)
  if not data then
    setStatus("READ ERROR", readErr)
    return false
  end
  return installData(data)
end

function M.choose()
  local osName = Compat.osName()
  if osName == "Android" or osName == "iOS" then return startMobilePicker() end
  return startDesktopPicker()
end

function M.reset()
  local ownedGenericPick = fileInfo(PENDING_FLAG) ~= nil
  safeRemove(PENDING_FLAG)
  safeRemove(DESKTOP_STAGE)
  if ownedGenericPick then safeRemove(PICKED_ROM) end
  local current = metaPath()
  if current then safeRemove(current) end
  removeLegacyImages(nil)
  safeRemove(META_FILE)
  M._def, M._defToken = nil, nil
  setStatus("DEFAULT")
  return true
end

function M.value()
  pcall(M.poll)
  if fileInfo(PENDING_FLAG) then return text("PICK...") end
  local path = metaPath()
  if path then
    local _, _, fw, fh = readMeta()
    local dims = (fw and fh) and (" " .. tostring(fw) .. "x" .. tostring(fh)) or ""
    return text("CUSTOM" .. dims)
  end
  return text("DEFAULT")
end

-- Keep the engine's newest requested base sprite so disabling the custom skin
-- restores the correct state even if another system swapped the player sprite
-- while our override was active.
local function syncPlayer(player)
  if type(player) ~= "table" then return false end
  local def = M.active() and currentDef() or nil
  local wantedToken = def and M._defToken or nil

  if def then
    if player._stadium2CustomPlayerToken ~= wantedToken then
      local okRenderer, SpriteRenderer = pcall(require, "src.render.SpriteRenderer")
      if not (okRenderer and type(SpriteRenderer) == "table"
          and type(SpriteRenderer.new) == "function") then
        setStatus("NO RENDERER", "SpriteRenderer unavailable")
        return false
      end
      local okNew, sprite = pcall(SpriteRenderer.new, def, "player")
      if not (okNew and sprite) then
        setStatus("BAD SHEET", sprite)
        return false
      end
      player.spriteDef = def
      player.sprite = sprite
      player._stadium2CustomPlayerToken = wantedToken
      player._stadium2CustomPlayerActive = true
    end
    return true
  end

  if player._stadium2CustomPlayerActive then
    local base = player._stadium2BaseSpriteDef
    player._stadium2CustomPlayerActive = nil
    player._stadium2CustomPlayerToken = nil
    if base then
      -- Route the restore through the live Player method when possible so any
      -- engine/companion wrappers and palette bookkeeping see the same sprite
      -- change they would have seen without this mod. M.active() is false here
      -- (disabled/reset), so our own setSprite wrapper passes the base through.
      if type(player.setSprite) == "function" then
        local okSet = pcall(player.setSprite, player, base)
        if okSet then return true end
      end
      local okRenderer, SpriteRenderer = pcall(require, "src.render.SpriteRenderer")
      if okRenderer and type(SpriteRenderer) == "table"
          and type(SpriteRenderer.new) == "function" then
        local okNew, sprite = pcall(SpriteRenderer.new, base, "player")
        if okNew and sprite then
          player.spriteDef = base
          player.sprite = sprite
          return true
        end
      end
    end
  end
  return false
end

function M.syncPlayer(player)
  return syncPlayer(player)
end

function M.install()
  if M._installed then return true end
  local okPlayer, Player = pcall(require, "src.world.gen2.Player")
  if not (okPlayer and type(Player) == "table") then
    return false, "Gold Player class unavailable"
  end

  if not Player._stadium2CustomPlayerSpritePatched then
    if type(Player.setSprite) == "function" then
      local innerSetSprite = Player.setSprite
      Player.setSprite = function(self, spriteDef, ...)
        if not self._stadium2ApplyingCustomPlayer then
          self._stadium2BaseSpriteDef = spriteDef
        end
        if M.active() then
          local custom = currentDef()
          if custom then
            self._stadium2ApplyingCustomPlayer = true
            local a, b, c = innerSetSprite(self, custom, ...)
            self._stadium2ApplyingCustomPlayer = nil
            self._stadium2CustomPlayerToken = M._defToken
            self._stadium2CustomPlayerActive = true
            return a, b, c
          end
        end
        self._stadium2CustomPlayerActive = nil
        self._stadium2CustomPlayerToken = nil
        return innerSetSprite(self, spriteDef, ...)
      end
    end

    if type(Player.new) == "function" then
      local innerNew = Player.new
      Player.new = function(cx, cy, facing, spriteDef, ...)
        local player = innerNew(cx, cy, facing, spriteDef, ...)
        if type(player) == "table" then
          player._stadium2BaseSpriteDef = spriteDef
          pcall(syncPlayer, player)
        end
        return player
      end
    end

    -- Sync at movement-update cadence so changing the toggle/imported sheet in
    -- Mod Settings takes effect live without a map reload or restart.  This is
    -- only a token comparison once the selected texture is already current.
    if type(Player.update) == "function" then
      local innerUpdate = Player.update
      Player.update = function(self, ...)
        pcall(syncPlayer, self)
        return innerUpdate(self, ...)
      end
    end

    Player._stadium2CustomPlayerSpritePatched = true
  end

  M._installed = true
  return true
end

function M.installModManagerOptions(mod)
  if M._managerInstalled then return true end
  local okManager, ManagerState = pcall(require, "src.mods.ManagerState")
  if not okManager or type(ManagerState) ~= "table"
      or type(ManagerState.buildOptionRows) ~= "function" then
    return false
  end

  local modId = (mod and mod.id) or "STADIUM2_OVERWORLD_MODELS"
  if not ManagerState._stadium2CustomPlayerSpriteOptionsPatched then
    local originalBuild = ManagerState.buildOptionRows
    ManagerState.buildOptionRows = function(self, m, schema)
      local rows = originalBuild(self, m, schema)
      if type(rows) ~= "table" or not m or m.id ~= modId then return rows end
      for _, row in ipairs(rows) do
        if type(row) == "table" and row.id == "customPlayerSpriteFile" then
          row.label = text("PLAYER SPRITE SHEET")
          row.value = function()
            local ok, value = pcall(M.value)
            return (ok and value) or text("DEFAULT")
          end
          row.activate = function()
            local opened = M.choose()
            if self.notify then
              self:notify(opened and "SPRITE PICKER OPENED" or "SPRITE UNCHANGED")
            end
            return opened
          end
          row.step = function(_, dir)
            if tonumber(dir) and tonumber(dir) < 0 then
              local reset = M.reset()
              if self.notify then self:notify("PLAYER SPRITE RESET") end
              return reset
            end
            return row.activate()
          end
          break
        end
      end
      return rows
    end
    ManagerState._stadium2CustomPlayerSpriteOptionsPatched = true
  end

  if type(ManagerState.update) == "function"
      and not ManagerState._stadium2CustomPlayerSpritePollPatched then
    local originalUpdate = ManagerState.update
    ManagerState.update = function(self, dt, ...)
      pcall(M.poll)
      return originalUpdate(self, dt, ...)
    end
    ManagerState._stadium2CustomPlayerSpritePollPatched = true
  end

  M._managerInstalled = true
  return true
end

function M.status()
  local path, revision, fw, fh = readMeta()
  return {
    installed = M._installed == true,
    enabled = M.enabled(),
    active = M.active(),
    value = M.value(),
    path = path,
    revision = revision,
    frameWidth = fw,
    frameHeight = fh,
    error = M._lastError,
  }
end

pcall(M.poll)
return M
