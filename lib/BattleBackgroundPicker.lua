-- Custom classic battle-background picker for Pokemon Gold/Silver.
--
-- A/Confirm or Right on the Mod Manager option opens a native desktop/mobile
-- file picker. Left removes the custom image and restores Gold's normal white
-- battle paper. The selected bytes are copied into the engine save directory;
-- the mod never keeps or reopens an arbitrary host path.
--
-- On Android/iOS current Gen1Recomp intentionally hides love.system.pickFile
-- from mod sandboxes. EngineCompat reaches the engine-owned RomImporter bridge,
-- whose generic document picker returns a selection as picked_rom.gb. A
-- feature-specific pending marker keeps that shared staging filename from being
-- mistaken for a Stadium ROM by StadiumRomMenu.
local V = ...
local M = {}
local Compat = V.require("EngineCompat")

local PICKED_ROM = "picked_rom.gb"
local PENDING_FLAG = "stadium2_battle_background_picker_pending.flag"
local OTHER_PENDING_FLAGS = {
  "stadium2_custom_player_sprite_picker_pending.flag",
  "stadium_overworld_picker_pending.flag",
}
local DESKTOP_STAGE = "stadium2_battle_background_pick.bin"
local META_FILE = "stadium2_battle_background.meta"
local BASE_NAME = "stadium2_custom_battle_background"
local REV_PREFIX = BASE_NAME .. "_r"
local MAX_BYTES = 32 * 1024 * 1024
local SCREEN_W, SCREEN_H = 160, 144

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

-- v0.2.97 stores every successful replacement under a NEW filename.  The
-- previous build reused one path per extension; on some graphics/filesystem
-- combinations that let a decoded PNG stay resident even after a later pick
-- overwrote or replaced the backing file.  A revisioned path guarantees LOVE
-- sees a new image resource on every successful selection.
local function readMeta()
  local raw = readFile(META_FILE)
  if type(raw) ~= "string" then return nil, 0 end
  local path, revision = raw:match("^([^\r\n]+)[\r\n]+(%d+)")
  if not path then path = raw:match("^([^\r\n]+)") end
  revision = tonumber(revision) or tonumber(path and path:match("_r(%d+)%.[^%.]+$")) or 0
  if path and fileInfo(path) then return path, revision end
  return nil, revision
end

local function metaPath()
  local path, revision = readMeta()
  if path then return path end

  -- Upgrade a v0.2.96 install in place.  Its active image used the legacy
  -- non-revisioned filename; keep it visible until the user picks a replacement.
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

local function imageCacheKey(path)
  local info = path and fileInfo(path)
  if not info then return nil end
  return table.concat({ path, tostring(info.size or ""), tostring(info.modtime or "") }, ":")
end

local function loadImage(path)
  path = path or metaPath()
  if not path then return nil end
  local key = imageCacheKey(path)
  if not key then return nil end
  if M._image and M._imageKey == key then return M._image end

  if not (love and love.graphics and type(love.graphics.newImage) == "function") then
    return nil
  end
  local ok, image = pcall(love.graphics.newImage, path)
  if not (ok and image) then
    setStatus("BAD IMAGE", image)
    return nil
  end
  if type(image.getWidth) ~= "function" or type(image.getHeight) ~= "function" then
    setStatus("BAD IMAGE", "image decoder returned no dimensions")
    return nil
  end
  local iw, ih = image:getWidth(), image:getHeight()
  if not iw or not ih or iw < 1 or ih < 1 or iw > 8192 or ih > 8192 then
    setStatus("BAD SIZE", "image dimensions must be between 1 and 8192 pixels")
    return nil
  end
  if type(image.setFilter) == "function" then pcall(image.setFilter, image, "linear", "linear") end
  M._image = image
  M._imageKey = key
  M._imagePath = path
  M._imageWidth, M._imageHeight = iw, ih
  return image
end

local function installData(data)
  if type(data) ~= "string" or #data == 0 then
    setStatus("IMPORT ERROR", "selected file could not be read")
    return false, M._lastError
  end
  if #data > MAX_BYTES then
    setStatus("TOO LARGE", "background image exceeds 32 MiB")
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

  -- Do not touch the active image until the replacement has been written AND
  -- decoded.  A bad/canceled pick therefore cannot strand the user on a half
  -- replaced background or resurrect the prior PNG through fallback scanning.
  safeRemove(target)
  local okWrite, writeErr = writeFile(target, data)
  if not okWrite then
    setStatus("WRITE ERROR", writeErr)
    return false, M._lastError
  end

  local previousImage, previousKey, previousPath = M._image, M._imageKey, M._imagePath
  local previousW, previousH = M._imageWidth, M._imageHeight
  local image = loadImage(target)
  if not image then
    safeRemove(target)
    M._image, M._imageKey, M._imagePath = previousImage, previousKey, previousPath
    M._imageWidth, M._imageHeight = previousW, previousH
    return false, M._lastError or "image decoder rejected selected file"
  end

  local okMeta, metaErr = writeFile(META_FILE, target .. "\n" .. tostring(M._revision) .. "\n")
  if not okMeta then
    safeRemove(target)
    M._image, M._imageKey, M._imagePath = previousImage, previousKey, previousPath
    M._imageWidth, M._imageHeight = previousW, previousH
    setStatus("WRITE ERROR", metaErr)
    return false, M._lastError
  end

  -- Commit complete: only now retire the previous resource.  The live image
  -- object already points at the new revisioned path, so JPG<->PNG and
  -- PNG<->PNG replacement cannot remain latched to an old decoded texture.
  if oldPath and oldPath ~= target then safeRemove(oldPath) end
  removeLegacyImages(target)
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
    setStatus("TOO LARGE", "background image exceeds 32 MiB")
    return true
  end

  local data, err = readFile(PICKED_ROM)
  local ok, why = false, err
  if data then ok, why = installData(data) end

  -- We own picked_rom.gb only while our feature-specific pending marker exists.
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

  -- Android/iOS does not create a result file when the document picker is
  -- canceled. The game loop is paused while the picker is open, so counting
  -- resumed frames is a safe way to retire a canceled/stale marker without
  -- timing out a player who spends a long time browsing folders.
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
    if fileInfo(flag) then return true end
  end
  return false
end

local function startMobilePicker()
  local f = fs()
  if not (f and type(f.write) == "function") then
    setStatus("NO PICKER", "save filesystem unavailable")
    return false
  end

  if otherPickerPending() then
    setStatus("PICKER BUSY", "another file picker is already active")
    return false
  end

  -- Clear only stale generic data before claiming it for this picker. The
  -- Stadium/player importers have their own markers and their pollers yield
  -- while this one exists, so the uses of picked_rom.gb cannot cross-consume.
  safeRemove(PICKED_ROM)
  safeRemove(PENDING_FLAG)
  local okMark = writeFile(PENDING_FLAG, "battle-background\n")
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

  local okPick, path = pcall(Compat.chooseImageFile, "Choose 2D Battle Background")
  if not okPick then
    setStatus("NO PICKER", path)
    return false
  end
  if type(path) ~= "string" or path == "" then
    -- Cancel is not an error and must keep the current background intact.
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
    setStatus("TOO LARGE", "background image exceeds 32 MiB")
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
  if osName == "Android" or osName == "iOS" then
    return startMobilePicker()
  end
  return startDesktopPicker()
end

function M.reset()
  local ownedGenericPick = fileInfo(PENDING_FLAG) ~= nil
  safeRemove(PENDING_FLAG)
  safeRemove(DESKTOP_STAGE)
  -- Remove picked_rom.gb only when this background picker owned an in-flight
  -- selection; otherwise that generic staging name may belong to ROM import.
  if ownedGenericPick then safeRemove(PICKED_ROM) end
  local current = metaPath()
  if current then safeRemove(current) end
  removeLegacyImages(nil)
  safeRemove(META_FILE)
  M._image, M._imageKey, M._imagePath = nil, nil, nil
  M._imageWidth, M._imageHeight = nil, nil
  setStatus("DEFAULT")
  return true
end

function M.value()
  pcall(M.poll)
  if fileInfo(PENDING_FLAG) then return text("PICK...") end
  local path = metaPath()
  if path then
    local ext = path:match("%.([^%.]+)$")
    return text("CUSTOM " .. tostring(ext or "IMG"):upper())
  end
  return text("DEFAULT")
end

function M.active()
  return metaPath() ~= nil
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

function M.transparentUiEnabled()
  return optionEnabled("transparentBattleUI", true)
end

-- Gold's HP/EXP HUD is not drawn entirely with rectangle fills.  The HP label,
-- bar cells, end caps and the player EXP strip are opaque tile images whose
-- lightest source shade is the battle paper.  The v0.2.98 rectangle filter
-- correctly removed menu/text-box paper, but these tiles still carried their
-- own white pixels, which is the white strip visible behind/under the bars.
--
-- Build transparent copies of ONLY the battle-HUD sheets and key their
-- lightest source shade to alpha 0.  The coloured HP/EXP fill shades and black
-- border ink remain opaque and still run through Gen1Recomp's own GBC palette
-- shader.  The original engine images are untouched, so toggling the option
-- OFF restores cartridge rendering immediately without a reload.
local HUD_TRANSPARENT_KEYS = {
  hpBar = true,
  expBar = true,
  enemyBorder = true,
  playerBorder = true,
}
local transparentHudImages = {}

local function buildTransparentHudImage(path, original)
  if transparentHudImages[path] ~= nil then
    return transparentHudImages[path] or original
  end
  local okAssets, Assets = pcall(require, "src.render.Assets")
  local G = love and love.graphics
  local I = love and love.image
  if not (okAssets and Assets and type(Assets.imageData) == "function"
      and G and type(G.newImage) == "function"
      and I and type(I.newImageData) == "function") then
    transparentHudImages[path] = false
    return original
  end

  local okData, source = pcall(Assets.imageData, path)
  if not (okData and source and type(source.getDimensions) == "function"
      and type(source.mapPixel) == "function") then
    transparentHudImages[path] = false
    return original
  end

  local okBuild, image = pcall(function()
    local w, h = source:getDimensions()
    local copy = I.newImageData(w, h)
    if type(copy.paste) == "function" then
      copy:paste(source, 0, 0, 0, 0, w, h)
    else
      -- Extremely old LOVE fallback.  Do not mutate Assets' cached ImageData.
      error("ImageData:paste unavailable")
    end
    copy:mapPixel(function(_, _, r, g, b, a)
      -- The extracted HUD sheets are grayscale.  Shade 0 is near-white and is
      -- the paper/background; every darker shade is actual HUD artwork.
      if (a or 1) > 0 and r > 0.83 and g > 0.83 and b > 0.83 then
        return r, g, b, 0
      end
      return r, g, b, a
    end)
    local out = G.newImage(copy)
    if out and type(out.setFilter) == "function" then
      pcall(out.setFilter, out, "nearest", "nearest")
    end
    return out
  end)

  if not (okBuild and image) then
    transparentHudImages[path] = false
    return original
  end
  transparentHudImages[path] = image
  return image
end

local function installTransparentHudTiles()
  local okHud, BattleHud = pcall(require, "src.ui.gen2.BattleHud")
  if not (okHud and type(BattleHud) == "table"
      and type(BattleHud.image) == "function") then
    return false
  end
  if BattleHud._stadium2TransparentHudTilesPatched then return true end

  local innerImage = BattleHud.image
  function BattleHud:image(key)
    local original = innerImage(self, key)
    if not original or not M.transparentUiEnabled()
        or not HUD_TRANSPARENT_KEYS[key] then
      return original
    end
    local path = self.gfx and self.gfx[key]
    if type(path) ~= "string" or path == "" then return original end
    return buildTransparentHudImage(path, original)
  end

  BattleHud._stadium2TransparentHudTilesPatched = true
  return true
end

function M.draw()
  local image = loadImage()
  if not image then return false end
  local G = love and love.graphics
  if not G then return false end
  local iw = M._imageWidth or image:getWidth()
  local ih = M._imageHeight or image:getHeight()
  if not iw or not ih or iw <= 0 or ih <= 0 then return false end

  -- Cover the 160x144 Game Boy panel without distortion. Transparent source
  -- pixels blend over white, matching Gold's normal battle paper.
  local scale = math.max(SCREEN_W / iw, SCREEN_H / ih)
  local dw, dh = iw * scale, ih * scale
  local dx, dy = (SCREEN_W - dw) * 0.5, (SCREEN_H - dh) * 0.5

  G.setColor(1, 1, 1, 1)
  G.rectangle("fill", 0, 0, SCREEN_W, SCREEN_H)
  G.setColor(1, 1, 1, 1)
  G.draw(image, dx, dy, 0, scale, scale)
  G.setColor(0, 0, 0, 1)
  return true
end

-- Replace only Gold's initial white battle paper. This wrapper is installed
-- after OverworldBattle's Gold hook. In live voxel battles that inner wrapper
-- temporarily replaces Chrome.clear with transparency, so the voxel encounter
-- background still wins. When LIVE OVERWORLD BATTLES is OFF, the inner wrapper
-- falls through and our custom clear is what the classic/native 2D panel sees.
function M.install()
  if M._installed then return true end
  -- Independent of the custom image itself: the transparency toggle also
  -- applies to live-world battles and to classic battles using a picked image.
  -- Install this first so the engine HUD tiles are keyed before drawPanel.
  installTransparentHudTiles()
  local okState, BattleState = pcall(require, "src.ui.gen2.BattleState")
  local okChrome, Chrome = pcall(require, "src.ui.gen2.Chrome")
  if not (okState and type(BattleState) == "table"
      and type(BattleState.drawPanel) == "function") then
    return false, "Gold BattleState.drawPanel is unavailable"
  end
  if not (okChrome and type(Chrome) == "table" and type(Chrome.clear) == "function") then
    return false, "Gold Chrome.clear is unavailable"
  end

  if not BattleState._stadium2CustomBattleBackgroundPatched then
    local innerPanel = BattleState.drawPanel
    BattleState.drawPanel = function(self, ...)
      local customBackground = metaPath() ~= nil
      local transparentUI = M.transparentUiEnabled()
      if not customBackground and not transparentUI then
        return innerPanel(self, ...)
      end

      local G = love and love.graphics
      local originalClear = Chrome.clear
      local originalRectangle = G and G.rectangle

      if customBackground then
        Chrome.clear = function()
          local okDraw, drawn = pcall(M.draw)
          if not (okDraw and drawn) then originalClear() end
          love.graphics.setColor(0, 0, 0, 1)
        end
      end

      -- Gold's full 160x144 battle paper is a separate background choice and
      -- must remain intact in the classic scene.  The ugly slabs visible over
      -- LIVE OVERWORLD BATTLES are the later opaque-white UI clears/fills
      -- (HUD name/HP blocks plus Font.drawBox paper).  Drop only those white
      -- rectangles while this one battle panel is drawing.  Black borders,
      -- text, coloured HP/EXP tiles, Pokemon pics/models and attack flashes all
      -- use other draws/colours and pass through untouched.
      if transparentUI and G and type(originalRectangle) == "function"
          and type(G.getColor) == "function" then
        G.rectangle = function(mode, x, y, w, h, ...)
          if mode == "fill" then
            local fullBattlePaper = x == 0 and y == 0
              and w == SCREEN_W and h == SCREEN_H
            if not fullBattlePaper then
              local r, g, b, a = G.getColor()
              if r and g and b and (a == nil or a > 0.99)
                  and r > 0.99 and g > 0.99 and b > 0.99 then
                return
              end
            end
          end
          return originalRectangle(mode, x, y, w, h, ...)
        end
      end

      local ok, a, b, c = pcall(innerPanel, self, ...)
      if G and originalRectangle then G.rectangle = originalRectangle end
      Chrome.clear = originalClear
      if not ok then error(a, 0) end
      return a, b, c
    end
    BattleState._stadium2CustomBattleBackgroundPatched = true
  end

  M._installed = true
  return true
end

-- Turn the placeholder choice row into a real action row. A/Confirm and Right
-- choose a file; Left is a deterministic "restore default" gesture.
function M.installModManagerOptions(mod)
  if M._managerInstalled then return true end
  local okManager, ManagerState = pcall(require, "src.mods.ManagerState")
  if not okManager or type(ManagerState) ~= "table"
      or type(ManagerState.buildOptionRows) ~= "function" then
    return false
  end

  local modId = (mod and mod.id) or "STADIUM2_OVERWORLD_MODELS"
  if not ManagerState._stadium2BattleBackgroundOptionsPatched then
    local originalBuild = ManagerState.buildOptionRows
    ManagerState.buildOptionRows = function(self, m, schema)
      local rows = originalBuild(self, m, schema)
      if type(rows) ~= "table" or not m or m.id ~= modId then return rows end
      for _, row in ipairs(rows) do
        if type(row) == "table" and row.id == "battleBackgroundFile" then
          row.label = text("2D BATTLE BACKGROUND")
          row.value = function()
            local ok, value = pcall(M.value)
            return (ok and value) or text("DEFAULT")
          end
          row.activate = function()
            local opened = M.choose()
            if self.notify then
              self:notify(opened and "IMAGE PICKER OPENED" or "BACKGROUND UNCHANGED")
            end
            return opened
          end
          row.step = function(_, dir)
            if tonumber(dir) and tonumber(dir) < 0 then
              local reset = M.reset()
              if self.notify then self:notify("BATTLE BACKGROUND RESET") end
              return reset
            end
            return row.activate()
          end
          break
        end
      end
      return rows
    end
    ManagerState._stadium2BattleBackgroundOptionsPatched = true
  end

  if type(ManagerState.update) == "function"
      and not ManagerState._stadium2BattleBackgroundPollPatched then
    local originalUpdate = ManagerState.update
    ManagerState.update = function(self, dt, ...)
      pcall(M.poll)
      return originalUpdate(self, dt, ...)
    end
    ManagerState._stadium2BattleBackgroundPollPatched = true
  end

  M._managerInstalled = true
  return true
end

function M.status()
  return {
    installed = M._installed == true,
    active = M.active(),
    value = M.value(),
    path = metaPath(),
    error = M._lastError,
  }
end

-- If a mobile picker returned while the app was being recreated, consume it as
-- early as the save filesystem permits. StadiumRomMenu is explicitly taught to
-- yield while our pending marker exists.
pcall(M.poll)

return M
