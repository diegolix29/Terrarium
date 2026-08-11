-- STADIUM 2 battles: importing the ROM, instead of being told where to put it.
--
-- Similar to StadiumRomPick but for Pokemon Stadium 2 (Gen 2 Pokemon support)

local V = ...

local Stadium2Install = V.require("Stadium2Install")

local Stadium2RomPick = {}

Stadium2RomPick.LABEL = "STADIUM 2 ROM"
Stadium2RomPick.ID = "DRAMATIC_SHAPE:stadium2Rom"
Stadium2RomPick.PICKED = "picked_rom.gb" -- Same as Stadium 1 (reused safely)
Stadium2RomPick.armed = false

local PROMPT = "Choose your Pokemon Stadium 2 (US) ROM"

local function haveShell()
  local ok, popen = pcall(function() return io and io.popen end)
  return (ok and popen) and true or false
end

local function haveFiles()
  local ok, open = pcall(function() return io and io.open end)
  return (ok and open) and true or false
end

local function osName()
  local ok, name = pcall(function() return love.system.getOS() end)
  return ok and name or nil
end

local function commandOutput(cmd)
  if not haveShell() then return nil end
  local ok, pipe = pcall(io.popen, cmd)
  if not (ok and pipe) then return nil end
  local okRead, out = pcall(pipe.read, pipe, "*a")
  pcall(pipe.close, pipe)
  if not (okRead and type(out) == "string") then return nil end
  out = out:gsub("^%s+", ""):gsub("%s+$", "")
  return (out ~= "") and out or nil
end

local function canDialog()
  local p = osName()
  if p == "Windows" or p == "OS X" or p == "Linux" then
    return haveShell() and haveFiles()
  end
  if p == "Android" then
    return (love and love.system and love.system.pickFile) and true or false
  end
  return false
end

Stadium2RomPick.canDialog = canDialog
Stadium2RomPick.available = canDialog

local function pickFile()
  local os = osName()
  if not os then return nil end
  
  if os == "Windows" then
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms;",
      "$d=New-Object System.Windows.Forms.OpenFileDialog;",
      "$d.Title='" .. PROMPT .. "';",
      "$d.Filter='Nintendo 64 ROM (*.z64;*.n64;*.v64)|*.z64;*.n64;*.v64"
      .. "|All files (*.*)|*.*';",
      "if($d.ShowDialog() -eq 'OK'){[Console]::OutputEncoding="
      .. "[Text.Encoding]::UTF8; [Console]::Write($d.FileName)}",
    })
    return commandOutput(
      'powershell -NoProfile -STA -Command "' .. script .. '"')
  elseif os == "OS X" then
    return commandOutput(
      ([[osascript -e 'POSIX path of (choose file with prompt "%s" of type ]]
       .. [[{"z64", "n64", "v64"})' 2>/dev/null]]):format(PROMPT))
  elseif os == "Linux" then
    if commandOutput("which zenity") ~= nil then
      return commandOutput(
        ([[zenity --file-selection --title="%s" ]]
         .. [[--file-filter="Nintendo 64 ROM | *.z64 *.n64 *.v64"]]):format(PROMPT))
    elseif commandOutput("which kdialog") ~= nil then
      return commandOutput(
        ([[kdialog --getopenfilename --title="%s" "*.z64 *.n64 *.v64"]]):format(PROMPT))
    end
  end
  return nil
end

function Stadium2RomPick.chooseAndroid()
  local love_system = love and love.system
  local fn = love_system and love_system.pickFile
  if not fn then return false end
  local f = love and love.filesystem
  if f and f.remove then pcall(f.remove, Stadium2RomPick.PICKED) end
  local ok, opened = pcall(fn)
  if not (ok and opened) then return false end
  Stadium2RomPick.armed = true
  return true
end

function Stadium2RomPick.choose()
  if osName() == "Android" then
    return Stadium2RomPick.chooseAndroid()
  end
  return pickFile()
end

function Stadium2RomPick.read(path)
  if not haveFiles() then return nil, "no file access" end
  local ok, fp = pcall(io.open, path, "rb")
  if not (ok and fp) then return nil, "could not open that file" end
  local okRead, bytes = pcall(fp.read, fp, "*a")
  pcall(fp.close, fp)
  if not (okRead and type(bytes) == "string" and #bytes > 0) then
    return nil, "could not read that file"
  end
  return bytes
end

function Stadium2RomPick.import(game)
  if Stadium2Install.status.state == "building" then return false end
  local Stadium2Screen = V.require("Stadium2Screen")

  if not Stadium2RomPick.canDialog() then
    if game and game.stack then
      game.stack:push(Stadium2Screen.newNote(game, "STADIUM 2 ROM",
        "PUT STADIUM 2 (US) HERE:",
        Stadium2Install.romHintFile()))
    end
    return false
  end

  if osName() == "Android" then
    Stadium2RomPick.choose()
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
  if game and game.stack then
    game.stack:push(Stadium2Screen.new(game, true))
  end
  return true
end

function Stadium2RomPick.row()
  local ok, Stadium2Install = pcall(V.require, "Stadium2Install")
  if not ok or not Stadium2Install then 
    print("Stadium2RomPick.row(): Stadium2Install failed to load:", Stadium2Install)
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

function Stadium2RomPick.poll(game)
  if not Stadium2RomPick.armed then return false end
  local f = love and love.filesystem
  if not (f and f.getInfo) then return false end
  local ok, info = pcall(f.getInfo, Stadium2RomPick.PICKED, "file")
  if not (ok and info) then return false end

  local okRead, bytes = pcall(f.read, Stadium2RomPick.PICKED)
  pcall(f.remove, Stadium2RomPick.PICKED)
  Stadium2RomPick.armed = false

  if not (okRead and bytes and #bytes > 0) then return false end

  local function fail(why)
    Stadium2Install.status.state = "failed"
    Stadium2Install.status.error = why
    local Stadium2Screen = V.require("Stadium2Screen")
    if game and game.stack then
      game.stack:push(Stadium2Screen.new(game, true))
    end
    return false
  end

  local ok, beginErr = Stadium2Install.beginFrom(bytes, "Android pick")
  if not ok then return fail(tostring(beginErr)) end
  local Stadium2Screen = V.require("Stadium2Screen")
  if game and game.stack then
    game.stack:push(Stadium2Screen.new(game, true))
  end
  return true
end

return Stadium2RomPick