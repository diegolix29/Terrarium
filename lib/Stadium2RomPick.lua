-- STADIUM 2 battles: importing the ROM, instead of being told where to put it.
--
-- Similar to StadiumRomPick but for Pokemon Stadium 2 (Gen 2 Pokemon support)
--
-- Uses the same EngineCompat approach as StadiumRomPick to work within the mod sandbox

local V = ...

local Stadium2Install = V.require("Stadium2Install")
local Compat = V.require("EngineCompat")

local Stadium2RomPick = {}

Stadium2RomPick.LABEL = "STADIUM 2 ROM"
Stadium2RomPick.ID = ((V.mod and V.mod.id) or "STADIUM2_OVERWORLD_MODELS") .. ":stadium2Rom"
Stadium2RomPick.PICKED = "picked_stadium2.z64"
Stadium2RomPick.armed = false

local PROMPT = "Choose your Pokemon Stadium 2 (US) ROM"

-- ------- the host, at arm's length
--
-- Everything below goes through EngineCompat. Current Gen1Recomp deliberately
-- sandboxes raw io and love.system/love.filesystem away from mod chunks, while
-- engine-owned Platform / SaveData / HostShell still provide the same services
-- safely. Older builds fall back through the same guarded compatibility layer.

local function haveShell()
  local shell = Compat.hostShell()
  return shell and type(shell.popen) == "function"
end

local function haveFiles()
  local f = Compat.fs()
  return f and type(f.read) == "function" and type(f.getInfo) == "function"
end

local function osName()
  return Compat.osName()
end

-- Run a command and return its trimmed stdout, or nil for anything that did
-- not produce a line -- a cancelled dialog, a missing zenity, a shell that
-- is not there.
local function commandOutput(cmd)
  if not haveShell() then return nil end
  return Compat.pipeOutput(Compat.hostShell(), cmd)
end

-- ------- can this machine open a DIALOG
--
-- Desktop only, and honestly so.
function Stadium2RomPick.canDialog()
  local hasShell = Compat.hostShell() ~= nil
  local hasFiles = Compat.fs() ~= nil
  return hasShell and hasFiles
end

Stadium2RomPick.available = Stadium2RomPick.canDialog

-- Open the dialog. Returns the chosen absolute path, or nil when the player
-- cancelled or no dialog could be opened.
function Stadium2RomPick.choose()
  local p = osName()
  if p == "OS X" then
    return commandOutput(
      ([[osascript -e 'POSIX path of (choose file with prompt "%s" of type ]]
       .. [[{"z64", "n64", "v64"})' 2>/dev/null]]):format(PROMPT))
  elseif p == "Windows" then
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms;",
      "$d=New-Object System.Windows.Forms.OpenFileDialog;",
      "$d.Title='" .. PROMPT .. "';",
      "$d.Filter='Nintendo 64 ROM (*.z64;*.n64;*.v64)|*.z64;*.n64;*.v64"
      .. "|All files (*.*)|*.*';",
      -- as UTF-8: the console's OEM codepage would mangle a non-ASCII path
      -- and crash the next text draw that showed it
      "if($d.ShowDialog() -eq 'OK'){[Console]::OutputEncoding="
      .. "[Text.Encoding]::UTF8; [Console]::Write($d.FileName)}",
    })
    return commandOutput(
      'powershell -NoProfile -STA -Command "' .. script .. '"')
  elseif p == "Linux" then
    local path = commandOutput(
      ([[zenity --file-selection --title="%s" ]]
       .. [[--file-filter="Nintendo 64 ROM | *.z64 *.n64 *.v64" 2>/dev/null]])
        :format(PROMPT))
    if path then return path end
    -- zenity is absent on plenty of installs (and on most handheld Linux
    -- distributions); KDE's own dialog is the usual second answer
    return commandOutput(
      [[kdialog --getopenfilename "$HOME" "*.z64 *.n64 *.v64|]]
      .. [[Nintendo 64 ROM" 2>/dev/null]])
  end
  return nil
end

-- Read an ABSOLUTE path, which love.filesystem cannot: it only sees inside
-- the physfs mount, and a picked file is anywhere on the disk. Returns the
-- bytes, or nil plus a reason short enough to fit the loading screen.
function Stadium2RomPick.read(path)
  if not haveFiles() then return nil, "no file access" end
  local okStage, relOrErr = Compat.stageExternal(path, Stadium2RomPick.PICKED)
  if not okStage then return nil, relOrErr or "could not open that file" end
  local f = Compat.fs()
  local okRead, bytes = pcall(f.read, Stadium2RomPick.PICKED)
  if type(f.remove) == "function" then pcall(f.remove, Stadium2RomPick.PICKED) end
  if not (okRead and type(bytes) == "string" and #bytes > 0) then
    return nil, "could not read that file"
  end
  return bytes
end

-- ------- the whole flow, from one keypress
--
-- Pick, read, start the build, and put the loading screen up over whatever
-- asked -- which is the OPTIONS menu, so the row is there again underneath
-- when the build finishes and now reads READY.
function Stadium2RomPick.import(game)
  if Stadium2Install.status.state == "building" then return false end
  local Stadium2Screen = V.require("Stadium2Screen")

  -- No dialog on this platform: say where the file goes, on screen, because
  -- that is the whole of what the player is missing and the console is not
  -- somewhere they can read it.
  if not Stadium2RomPick.canDialog() then
    if game and game.stack then
      game.stack:push(Stadium2Screen.newNote(game, "STADIUM 2 ROM",
        "PUT POKEMON STADIUM 2 (US) HERE:",
        Stadium2Install.romHintFile()))
    end
    return false
  end

  local path = Stadium2RomPick.choose()
  if not path then return false end

  local function fail(why)
    Stadium2Install.status.state = "failed"
    Stadium2Install.status.error = why
    if game and game.stack then
      game.stack:push(Stadium2Screen.new(game, true))
    end
    return false
  end

  local bytes, err = Stadium2RomPick.read(path)
  if not bytes then return fail(err or "could not read that file") end

  local ok, beginErr = Stadium2Install.beginFrom(bytes, path)
  if not ok then return fail(tostring(beginErr)) end

  -- StadiumBattleFXPort integration for Stadium 2 imports
  local okPort, StadiumBattleFXPort = pcall(V.require, "StadiumBattleFXPort")
  if okPort and StadiumBattleFXPort and type(StadiumBattleFXPort.importStadium2) == "function" then
    pcall(StadiumBattleFXPort.importStadium2, bytes)
  end

  if game and game.stack then
    game.stack:push(Stadium2Screen.new(game, true))
  end
  return true
end

function Stadium2RomPick.row()
  local ok, Stadium2Install = pcall(V.require, "Stadium2Install")
  if not ok or not Stadium2Install then 
    return nil 
  end
  
  local value
  if Stadium2Install.status and Stadium2Install.status.state == "building" then
    value = "BUILDING"
  elseif Stadium2Install.ready() then
    value = "READY"
  else
    value = Stadium2RomPick.canDialog() and "IMPORT" or "WHERE?"
  end
  
  return {
    id = Stadium2RomPick.ID,
    label = Stadium2RomPick.LABEL,
    value = value,
    step = function(game)
      pcall(Stadium2RomPick.import, game)
      return true
    end,
  }
end

-- ------- a pick that landed while we were not looking
--
-- The desktop dialog BLOCKS, so `import` above can read the answer on the
-- next line. A SAF pick cannot work that way: it is a separate activity,
-- Android is free to destroy the game while it is up, and the file appears
-- some frames later -- so the only way to notice one is to look for it.
--
-- Nothing writes this filename today (see canDialog). It is watched anyway so
-- that teaching the native bridge one more kind is the whole of the Android
-- picker work, with no second change needed here.
--
-- Consumed and DELETED either way: a 32 MB file left in the save directory
-- would be imported again on the next boot, and kept forever if the import
-- failed.
function Stadium2RomPick.poll(game)
  local f = Compat.fs()
  if not (f and type(f.getInfo) == "function") then return false end
  if Stadium2Install.status.state == "building" then return false end
  local ok, info = pcall(f.getInfo, Stadium2RomPick.PICKED, "file")
  if not (ok and info) then return false end

  local okRead, bytes = pcall(f.read, Stadium2RomPick.PICKED)
  if type(f.remove) == "function" then pcall(f.remove, Stadium2RomPick.PICKED) end
  if not (okRead and type(bytes) == "string") then return false end

  local okScreen, Stadium2Screen = pcall(V.require, "Stadium2Screen")
  local okBegin, started, err = pcall(Stadium2Install.beginFrom, bytes, Stadium2RomPick.PICKED)
  if not okBegin then
    Stadium2Install.status.state = "failed"
    Stadium2Install.status.error = tostring(started)
  elseif not started then
    Stadium2Install.status.state = "failed"
    Stadium2Install.status.error = tostring(err)
  else
    local okPort, StadiumBattleFXPort = pcall(V.require, "StadiumBattleFXPort")
    if okPort and StadiumBattleFXPort and type(StadiumBattleFXPort.importStadium2) == "function" then
      pcall(StadiumBattleFXPort.importStadium2, bytes)
    end
  end
  if okScreen and Stadium2Screen and game and game.stack
      and type(Stadium2Screen.new) == "function" then
    pcall(function() game.stack:push(Stadium2Screen.new(game, true)) end)
  end
  return true
end

return Stadium2RomPick