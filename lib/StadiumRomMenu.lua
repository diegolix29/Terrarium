-- Pokemon Stadium ROM menu bridge
--
-- v0.1.14: primary UI is this mod's own Mod Manager -> Options screen.
-- The recomp engine's standard option schema has toggles/choices/numbers/text but no
-- native "action" row, so we register a supported placeholder choice and then
-- replace only that generated row with a file-picker activate callback.
-- The older general OPTIONS hook is retained solely as a compatibility fallback.
--
-- Preferred path: delegate to Dramatic Shape's own StadiumRomPick module when
-- it exists.  Android: always use gen1recomp's native document picker before any Dramatic Shape helper.  The
-- Android bridge delivers a chosen file as picked_rom.gb regardless of the
-- source extension. We validate the N64 byte-order magic, normalize the data
-- to z64 byte order when needed, then stage the exact path Dramatic Shape asks
-- for: baseroms/baserom.z64.
local V = ...
local M = {}
local Compat = V.require("EngineCompat")

local PICKED_ROM = "picked_rom.gb"
local PICKED_STADIUM = "picked_stadium.z64"
local PENDING_FLAG = "stadium_overworld_picker_pending.flag"
local BATTLE_BACKGROUND_PENDING_FLAG = "stadium2_battle_background_picker_pending.flag"
local CUSTOM_PLAYER_PENDING_FLAG = "stadium2_custom_player_sprite_picker_pending.flag"

local function isGen2()
  local ok, install = pcall(V.require, "StadiumInstall")
  return ok and type(install) == "table"
     and type(install.gameGeneration) == "function"
     and install.gameGeneration() == 2
end

local function romLabel()
  -- Gen-2 builds use one Android document-picker row for both private sources:
  -- Stadium 2 feeds the 001-251 model/world importer; Stadium 1 USA v1.0 feeds
  -- StadiumBattleFX plus the locally decoded announcer voice cache.
  return isGen2() and "STADIUM 1 / 2 ROM FILE" or "STADIUM ROM FILE"
end

-- Android compatibility note:
-- The recomp engine's currently deployed native picker copies the generic "rom"
-- selection to picked_rom.gb.  Some voxel-host/mobile builds already reserve
-- a dedicated picked_stadium.z64 target.  Watch both names so the companion
-- works with either bridge without another release.

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

local function picker()
  local ok, value = pcall(V.require, "StadiumRomPick")
  if ok and type(value) == "table" then return value end
  return nil
end

local function rawRow()
  local p = picker()
  if not p or type(p.row) ~= "function" then return nil end
  local ok, row = pcall(p.row)
  if not ok then ok, row = pcall(p.row, p) end
  if ok and type(row) == "table" then return row end
  return nil
end

-- Poll the embedded Dramatic/Dramaless Stadium picker without ever allowing
-- its optional desktop bridge to crash the Mod Manager.  v0.1.64 called this
-- helper from M.poll() but accidentally never defined it, so opening this
-- mod's Options page on desktop immediately raised a nil-global error.
local function notifyDramaticShape(game)
  local p = picker()
  if not p or type(p.poll) ~= "function" then return false end
  local ok, result = pcall(p.poll, game)
  if not ok then ok, result = pcall(p.poll, p, game) end
  return ok and result ~= false
end

local function safeRemove(path)
  local f = Compat.fs()
  if f and type(f.remove) == "function" then pcall(f.remove, path) end
end

local function setStatus(value)
  M._status = value
end

local function pickedPath()
  local f = Compat.fs()
  if not (f and type(f.getInfo) == "function") then return nil end
  local okStadium, stadium = pcall(f.getInfo, PICKED_STADIUM, "file")
  if okStadium and stadium then return PICKED_STADIUM end
  local okRom, rom = pcall(f.getInfo, PICKED_ROM, "file")
  if okRom and rom then return PICKED_ROM end
  return nil
end

local function stadiumReady()
  local ok, install = pcall(V.require, "StadiumInstall")
  if not ok or type(install) ~= "table" or type(install.ready) ~= "function" then
    return false
  end
  local okReady, ready = pcall(install.ready)
  if not okReady then okReady, ready = pcall(install.ready, install) end
  return okReady and ready == true
end

local function cleanupStagingIfReady()
  if not stadiumReady() then return false end
  -- The ROM is only an import source.  Once all Stadium packs are current,
  -- remove any Android picker leftovers so a later boot cannot mistake them
  -- for a fresh import.
  safeRemove(PENDING_FLAG)
  safeRemove(PICKED_ROM)
  safeRemove(PICKED_STADIUM)
  setStatus("READY")
  return true
end

local function n64Format(data)
  if type(data) ~= "string" or #data < 4 then return nil end
  local a, b, c, d = data:byte(1, 4)
  if a == 0x80 and b == 0x37 and c == 0x12 and d == 0x40 then return "z64" end
  if a == 0x37 and b == 0x80 and c == 0x40 and d == 0x12 then return "v64" end
  if a == 0x40 and b == 0x12 and c == 0x37 and d == 0x80 then return "n64" end
  return nil
end

local function canonicalU8(data, offset, format)
  local source = offset
  if format == "v64" then
    local word = offset - offset % 2
    source = word + (1 - offset % 2)
  elseif format == "n64" then
    local word = offset - offset % 4
    source = word + (3 - offset % 4)
  end
  return data:byte(source + 1)
end

local function canonicalU32(data, offset, format)
  local a = canonicalU8(data, offset, format)
  local b = canonicalU8(data, offset + 1, format)
  local c = canonicalU8(data, offset + 2, format)
  local d = canonicalU8(data, offset + 3, format)
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function looksLikeStadium1US(data, format)
  return canonicalU32(data, 0x10, format) == 0x90F5D9B3
     and canonicalU32(data, 0x14, format) == 0x9D0EDCF0
end

local function stadium1VoiceStatus()
  if type(V.stadium1ImportStatus) ~= "function" then return nil end
  local ok, value = pcall(V.stadium1ImportStatus)
  if ok and type(value) == "table" then return value end
  return nil
end

local function resolveGame(game)
  if game and game.stack then return game end
  -- Gold's live owner is Game2.  Keep the Gen-1 fallback only for older shared
  -- builds; requiring src.core.Game first on a Gen-2 sandbox is a dead-module
  -- warning and can be rejected by stricter compatibility gates.
  local ok2, Game2 = pcall(require, "src.core.Game2")
  if ok2 and Game2 and Game2.stack then return Game2 end
  local ok1, Game = pcall(require, "src.core.Game")
  if ok1 and Game and Game.stack then return Game end
  return game
end

local function pushBuildScreen(game)
  game = resolveGame(game)
  if not (game and game.stack) then return false end
  local okScreen, StadiumScreen = pcall(V.require, "StadiumScreen")
  if not (okScreen and type(StadiumScreen) == "table"
      and type(StadiumScreen.new) == "function") then return false end
  local ok = pcall(function()
    game.stack:push(StadiumScreen.new(game, true))
  end)
  return ok
end

local function failStadium1Android(why)
  safeRemove(PENDING_FLAG)
  safeRemove(PICKED_ROM)
  safeRemove(PICKED_STADIUM)
  setStatus("S1 IMPORT ERROR")
  return true, why
end

local function failAndroid(game, why)
  local okInstall, install = pcall(V.require, "StadiumInstall")
  if okInstall and type(install) == "table" and type(install.status) == "table" then
    install.status.state = "failed"
    install.status.error = tostring(why or "could not import Stadium ROM")
  end
  safeRemove(PENDING_FLAG)
  safeRemove(PICKED_ROM)
  safeRemove(PICKED_STADIUM)
  setStatus("IMPORT ERROR")
  pushBuildScreen(game)
  return true, why
end

local function consumeAndroidPick(game)
  local f = Compat.fs()
  if not (f and type(f.getInfo) == "function" and type(f.read) == "function") then
    return false
  end
  local okPending, pending = pcall(f.getInfo, PENDING_FLAG, "file")
  if not (okPending and pending) then return false end

  local source = pickedPath()
  if not source then return false end

  -- Do not consume the only copy until the game stack exists. Android may
  -- recreate the process while the system document picker is open; leaving
  -- the file in place lets game.ready finish the import safely afterwards.
  game = resolveGame(game)
  if not (game and game.stack) then return false end

  local okRead, data, err = pcall(f.read, source)
  if not okRead then
    return failAndroid(game, data or "could not read selected file")
  end
  if type(data) ~= "string" then
    return failAndroid(game, err or "could not read selected file")
  end

  -- Reject obvious wrong picks here. Both private importers perform full
  -- normalization/validation again, including .v64 and .n64 byte order.
  local format = n64Format(data)
  if not format then
    return failAndroid(game, "selected file is not an N64 ROM image")
  end

  -- Pokemon Stadium (USA) v1.0 has a unique header CRC pair. Detect it before
  -- handing the file to StadiumInstall, because this Gen-2 build's ordinary
  -- importer expects Stadium 2. StadiumBattleFX performs canonical MD5
  -- validation before any speech/effect offsets are trusted.
  if looksLikeStadium1US(data, format) and type(V.importStadium1) == "function" then
    local okS1, startedS1, s1Err = pcall(V.importStadium1, data, source)
    if not okS1 then return failStadium1Android(startedS1) end
    if not startedS1 then return failStadium1Android(s1Err or "Stadium 1 ROM was rejected") end

    safeRemove(source)
    safeRemove(PENDING_FLAG)
    safeRemove(PICKED_ROM)
    safeRemove(PICKED_STADIUM)
    setStatus("S1 VOICE IMPORTING")
    -- StadiumBattleFX advances its ROM/voice jobs from input.step, so unlike
    -- StadiumInstall it needs no model-build screen to stay alive.
    return true
  end

  local okInstall, install = pcall(V.require, "StadiumInstall")
  if not (okInstall and type(install) == "table"
      and type(install.beginFrom) == "function") then
    return failAndroid(game, "voxel host has no Stadium importer")
  end

  -- Stadium 2 path: unchanged from v0.3.22. Feed the picked bytes straight to
  -- the voxel host and avoid persisting a second 32 MiB ROM copy.
  local okBegin, started, beginErr = pcall(install.beginFrom, data, source)
  if not okBegin then
    return failAndroid(game, started)
  end
  if not started then
    return failAndroid(game, beginErr or "Stadium ROM was rejected")
  end

  safeRemove(source)
  safeRemove(PENDING_FLAG)
  safeRemove(PICKED_ROM)
  safeRemove(PICKED_STADIUM)
  setStatus("S2 IMPORTING")

  if not pushBuildScreen(game) then
    -- Keep a marker so game.ready / the manager update can attach the screen
    -- that drives StadiumInstall.step(). The build itself remains alive.
    if type(f.write) == "function" then pcall(f.write, PENDING_FLAG, "build-screen\n") end
  end
  return true
end

function M.poll(game)
  -- The custom battle-background picker reuses the engine's generic mobile
  -- document bridge, which also stages its result as picked_rom.gb. Yield
  -- while that feature-specific marker exists so a valid PNG/JPEG/BMP can
  -- never be deleted or fed to StadiumInstall as an N64 ROM.
  local f = Compat.fs()
  if f and type(f.getInfo) == "function" then
    local okBg, pendingBg = pcall(f.getInfo, BATTLE_BACKGROUND_PENDING_FLAG, "file")
    if okBg and pendingBg then return false end
    local okPlayer, pendingPlayer = pcall(f.getInfo, CUSTOM_PLAYER_PENDING_FLAG, "file")
    if okPlayer and pendingPlayer then return false end
  end

  -- Consume a fresh Android SAF result BEFORE cleanupStagingIfReady(). An
  -- already-ready Stadium 2 cache must never delete a newly selected Stadium 1
  -- file as stale picker debris.
  local consumed = consumeAndroidPick(game)
  if consumed then return true end
  if cleanupStagingIfReady() then return true end

  local osName = Compat.osName()
  if osName ~= "Android" and osName ~= "iOS" and not consumed then
    notifyDramaticShape(game)
  end
  return consumed and true or false
end

local function invokeRow(row, game)
  if type(row) ~= "table" then return false end
  if type(row.activate) == "function" then
    local ok = pcall(row.activate, game)
    if not ok then ok = pcall(row.activate, row, game) end
    return ok
  end
  if type(row.step) == "function" then
    local ok = pcall(row.step, game, 1)
    if not ok then ok = pcall(row.step, row, game, 1) end
    return ok
  end
  return false
end

local function startAndroidPicker()
  local f = Compat.fs()
  if not (f and type(f.write) == "function") then
    setStatus("NO PICKER")
    return false
  end
  if type(f.getInfo) == "function" then
    local okBg, pendingBg = pcall(f.getInfo, BATTLE_BACKGROUND_PENDING_FLAG, "file")
    local okPlayer, pendingPlayer = pcall(f.getInfo, CUSTOM_PLAYER_PENDING_FLAG, "file")
    if (okBg and pendingBg) or (okPlayer and pendingPlayer) then
      setStatus("PICKER BUSY")
      return false
    end
  end

  -- Own the generic mobile ROM pick before opening the engine bridge. Current
  -- Gen1Recomp sandboxes hide love.system / love.filesystem from mod code, so
  -- EngineCompat asks the engine-owned RomImporter to open its native picker.
  -- The bridge returns the selection as picked_rom.gb; our poller validates it
  -- as N64 data and feeds the bytes directly to StadiumInstall.
  pcall(f.write, PENDING_FLAG, "stadium\n")
  safeRemove(PICKED_ROM)
  safeRemove(PICKED_STADIUM)
  setStatus("PICK...")

  local ok, launched, why = pcall(Compat.openMobileRomPicker)
  if not ok or not launched then
    safeRemove(PENDING_FLAG)
    setStatus("NO PICKER")
    return false, ok and why or launched
  end
  return true
end

function M.choose(game)
  -- IMPORTANT: on Android, bypass Dramatic Shape's legacy row completely.
  -- Its action opens the in-game "PUT STADIUM US 1.0 HERE" instruction screen
  -- seen in older builds. the recomp engine's love.system.pickFile instead launches
  -- Android's real Storage Access Framework / Files app.
  local osName = Compat.osName()
  if osName == "Android" or osName == "iOS" then
    if startAndroidPicker() then return true end
    setStatus("NO MOBILE PICKER")
    return false
  end

  -- Desktop/other-platform compatibility: use Dramatic Shape's own action when
  -- available because it owns the exact Stadium validation/build pipeline.
  local row = rawRow()
  if invokeRow(row, game) then return true end

  local p = picker()
  if p then
    for _, name in ipairs({ "choose", "pick", "open", "start", "request" }) do
      local fn = p[name]
      if type(fn) == "function" then
        local ok, result = pcall(fn, game)
        if not ok then ok, result = pcall(fn, p, game) end
        if ok and result ~= false then return true end
      end
    end
  end

  return startAndroidPicker()
end

local function labelString(row)
  if type(row) ~= "table" then return "" end
  local ok, s = pcall(tostring, row.label)
  return ok and (s or "") or ""
end

local function stadiumRowIndex(out, upstreamId)
  for i, row in ipairs(out) do
    if type(row) == "table" then
      if upstreamId ~= nil and row.id == upstreamId then return i end
      if row.id == "stadium_overworld:rom_file" then return i end
      local label = labelString(row):upper()
      if label:find("STADIUM", 1, true) and label:find("ROM", 1, true) then
        return i
      end
    end
  end
  return nil
end

local function insertionIndex(out)
  -- Put it immediately before MODS whenever possible so it is easy to find,
  -- even if an older OPTIONS menu does not group render-pipeline rows.
  for i, row in ipairs(out) do
    if type(row) == "table" and row.id == "mods" then return i end
  end
  return #out + 1
end

local function valueFromSource(source, game)
  if type(source) ~= "table" then return nil end
  local value = source.value
  if type(value) == "function" then
    local ok, result = pcall(value, game)
    if not ok then ok, result = pcall(value, source, game) end
    if ok and result ~= nil then return result end
  elseif value ~= nil then
    return value
  end
  return nil
end

local function makeRow(source)
  local out = {}
  if type(source) == "table" then
    for k, v in pairs(source) do out[k] = v end
  end

  out.id = (type(source) == "table" and source.id) or "stadium_overworld:rom_file"
  out.label = text(romLabel())
  out.step = nil

  out.value = function(game)
    -- A status probe must never be able to crash an options/menu render.
    pcall(M.poll, game)
    if M._status then return text(M._status) end
      local upstream = valueFromSource(source, game)
    if upstream ~= nil then return upstream end
    return text("CHOOSE")
  end

  out.activate = function(game)
    if type(source) == "table" then
      if invokeRow(source, game) then return true end
    end
    return M.choose(game)
  end
  return out
end

function M.ensureRow(rows, game)
  if type(rows) ~= "table" then return rows end
  pcall(M.poll, game)
  local source = rawRow()
  local row = makeRow(source)
  local at = stadiumRowIndex(rows, source and source.id or nil)
  if at then
    rows[at] = row
  else
    table.insert(rows, insertionIndex(rows), row)
  end
  return rows
end

function M.installOptionsHook(mod)
  if M._installed then return true end
  local installedAny = false

  -- Preferred modern extension point.
  if mod and mod.hooks and type(mod.hooks.wrap) == "function" then
    local ok = pcall(function()
      mod.hooks:wrap("ui.options.rows", function(next, game, rows)
        local out = next(game, rows)
        return M.ensureRow(out, game)
      end)
    end)
    installedAny = ok or installedAny
  end

  -- Compatibility fallback: some released recomp builds predate (or do
  -- not dispatch) ui.options.rows.  Patch OptionsMenu.new itself as well.  On
  -- current builds this only sees that the hook already inserted our row and
  -- replaces it in-place, so there is never a duplicate.
  local okMenu, OptionsMenu = pcall(require, "src.ui.OptionsMenu")
  if okMenu and type(OptionsMenu) == "table" and type(OptionsMenu.new) == "function"
      and not OptionsMenu._stadiumOverworldRomMenuPatched then
    local originalNew = OptionsMenu.new
    OptionsMenu.new = function(game, opts)
      local menu = originalNew(game, opts)
      if type(menu) == "table" and type(menu.rows) == "table" then
        M.ensureRow(menu.rows, game)
      end
      return menu
    end
    OptionsMenu._stadiumOverworldRomMenuPatched = true
    installedAny = true
  end

  M._installed = installedAny
  return installedAny
end

-- Value shown beside STADIUM ROM FILE in the per-mod options screen.
function M.value(game)
  -- This function is evaluated while the Mod Manager draws the row. Keep
  -- every optional picker/importer failure contained to the mod.
  pcall(M.poll, game)
  local voice = stadium1VoiceStatus()
  if voice and voice.state == "building" then
    local done, total = tonumber(voice.done) or 0, tonumber(voice.total) or 823
    return text(("S1 VOICE %03d/%03d"):format(done, total))
  end
  if voice and voice.state == "failed" then return text("S1 VOICE ERROR") end
  if voice and voice.ready and voice.source == "rom" then
    return text(stadiumReady() and "S1 + S2 READY" or "S1 VOICE READY")
  end
  if M._status then return text(M._status) end
  local source = rawRow()
  local upstream = valueFromSource(source, game)
  if upstream ~= nil then return upstream end
  return text("CHOOSE")
end

-- The recomp engine exposes per-mod options from an options_schema, but its published
-- row types do not include a generic button/action.  Patch only the generated
-- row belonging to this mod so A/Confirm opens the ROM picker instead of merely
-- cycling a dummy choice.  No other mod's options are changed.
function M.installModManagerOptions(mod)
  if M._managerInstalled then return true end

  local okManager, ManagerState = pcall(require, "src.mods.ManagerState")
  if not okManager or type(ManagerState) ~= "table"
      or type(ManagerState.buildOptionRows) ~= "function" then
    return false
  end

  local modId = (mod and mod.id) or "STADIUM2_OVERWORLD_MODELS"
  local originalBuild = ManagerState.buildOptionRows

  -- Avoid stacking wrappers if a loader hot-reloads this mod.
  if not ManagerState._stadiumOverworldRomOptionsPatched then
    ManagerState.buildOptionRows = function(self, m, schema)
      local rows = originalBuild(self, m, schema)
      if type(rows) ~= "table" or not m or m.id ~= modId then
        return rows
      end

      for _, row in ipairs(rows) do
        if type(row) == "table" and row.id == "stadiumRomFile" then
          row.label = text(romLabel())
          row.value = function()
            local ok, value = pcall(M.value, self.game)
            if ok and value ~= nil then return value end
            return text("CHOOSE")
          end
          row.activate = function()
            local ok = M.choose(self.game)
            if self.notify then
              self:notify(ok and "ROM PICKER OPENED" or "ROM PICKER UNAVAILABLE")
            end
            return ok
          end
          row.step = function()
            return row.activate()
          end
          break
        end
      end
      return rows
    end
    ManagerState._stadiumOverworldRomOptionsPatched = true
  end

  -- Keep polling while the Mod Manager is active. On Android the native
  -- document picker returns asynchronously; this consumes the result on the
  -- first resumed frame instead of relying on the option row being redrawn or
  -- requiring another button press.
  if type(ManagerState.update) == "function"
      and not ManagerState._stadiumOverworldRomPollPatched then
    local originalUpdate = ManagerState.update
    ManagerState.update = function(self, dt, ...)
      pcall(M.poll, self and self.game)
      return originalUpdate(self, dt, ...)
    end
    ManagerState._stadiumOverworldRomPollPatched = true
  end

  M._managerInstalled = true
  return true
end

function M.available()
  -- The picker is available even without Dramatic Shape's optional helper;
  -- Android native-pick fallback is handled by M.choose.
  return true
end

-- If Android recreated the process while the document picker was open, finish
-- staging immediately on load instead of waiting for OPTIONS to be reopened.
pcall(M.poll, nil)

return M
