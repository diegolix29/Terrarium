-- Current Gen1Recomp compatibility helpers for sandboxed mod code.
--
-- Newer Gen1Recomp builds intentionally hide love.filesystem / love.system and
-- raw io/os process access from a mod's own environment.  This mod has always
-- needed three host services for Stadium imports: the save-directory
-- filesystem, platform detection, and the host file picker.  Ask engine-owned
-- modules for those services instead of dereferencing sandbox-blocked globals.
--
-- This module is deliberately tiny and defensive: every engine seam is pcall
-- guarded so an older recomp build simply falls back rather than taking Gold
-- down with it.
local V = ...

local Compat = {}
local cachedFs

local function req(name)
  local ok, value = pcall(require, name)
  if ok and type(value) == "table" then return value end
  return nil
end

function Compat.fs()
  if cachedFs then return cachedFs end

  -- Current engine-owned persistence routing.  This returns the same backend
  -- Gold saves/options use (portable mode included) without the mod naming or
  -- touching love.filesystem itself.
  local SaveData = req("src.core.SaveData")
  if SaveData and type(SaveData.persistenceFs) == "function" then
    local ok, f = pcall(SaveData.persistenceFs)
    if ok and type(f) == "table" then
      cachedFs = f
      return f
    end
  end

  -- Older pre-sandbox builds still expose love.filesystem directly.  Keep that
  -- compatibility path inside pcall so a current sandbox's proxy error is
  -- swallowed instead of becoming a crash.
  local ok, f = pcall(function()
    return love and love.filesystem
  end)
  if ok and type(f) == "table" then
    cachedFs = f
    return f
  end
  return nil
end

-- Normalize a path back to this mod's own relative namespace.  Current
-- sandboxes intentionally do not expose love.filesystem, while mod:info/read
-- are the supported way to inspect files shipped by the mod.
local function modRelativeCandidates(mod, path)
  if type(path) ~= "string" or path == "" then return {} end
  local out, seen = {}, {}
  local function add(v)
    if type(v) == "string" and v ~= "" and not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  add(path)
  local prefix = type(mod) == "table" and type(mod.path) == "string"
    and (mod.path:gsub("[/\\]+$", "") .. "/") or nil
  if prefix and path:sub(1, #prefix) == prefix then add(path:sub(#prefix + 1)) end
  local id = type(mod) == "table" and tostring(mod.id or "") or ""
  if id ~= "" then
    local mp = "mods/" .. id .. "/"
    local i = path:find(mp, 1, true)
    if i then add(path:sub(i + #mp)) end
  end
  for _, marker in ipairs({ "assets/", "lib/", "data/" }) do
    local i = path:find(marker, 1, true)
    if i then add(path:sub(i)) end
  end
  return out
end

function Compat.info(mod, path)
  if type(mod) == "table" and type(mod.info) == "function" then
    for _, rel in ipairs(modRelativeCandidates(mod, path)) do
      local ok, info = pcall(mod.info, mod, rel)
      if ok and info then return info, rel end
    end
  end
  local f = Compat.fs()
  if f and type(f.getInfo) == "function" then
    local ok, info = pcall(f.getInfo, path)
    if ok and info then return info, path end
  end
  return nil
end

function Compat.exists(mod, path)
  return Compat.info(mod, path) ~= nil
end

function Compat.read(mod, path)
  if type(mod) == "table" and type(mod.read) == "function" then
    for _, rel in ipairs(modRelativeCandidates(mod, path)) do
      local ok, data = pcall(mod.read, mod, rel)
      if ok and data ~= nil and data ~= false then return data, rel end
    end
  end
  local f = Compat.fs()
  if f and type(f.read) == "function" then
    local ok, data = pcall(f.read, path)
    if ok and data ~= nil then return data, path end
  end
  return nil
end

function Compat.osName()
  local Platform = req("src.core.Platform")
  if Platform then
    if type(Platform.detect) == "function" then
      local ok, info = pcall(Platform.detect)
      if ok and type(info) == "table" and type(info.os) == "string" then
        return info.os
      end
    end
  end

  local ok, name = pcall(function()
    local system = love and love.system
    return system and system.getOS and system.getOS()
  end)
  if ok and type(name) == "string" then return name end
  return "Unknown"
end

function Compat.hostShell()
  return req("src.core.HostShell")
end


local pipeOutput

-- Generic desktop file picker for addon-owned imports (WAD/PK3/etc.).
-- Current Gen1Recomp sandboxes love.system and raw external io from mod code,
-- but engine-owned HostShell is still the supported bridge used by the
-- built-in ROM importer and this mod's Stadium importer.  The selected host
-- path is only a transient token; callers must stage it immediately with
-- Compat.stageExternal before reading it.
function Compat.canFileDialog()
  local shell = Compat.hostShell()
  if not (shell and type(shell.popen) == "function") then return false end
  local p = Compat.osName()
  return p == "Windows" or p == "OS X" or p == "Linux"
end

function Compat.chooseFile(title, extensions, label)
  if not Compat.canFileDialog() then return nil end
  title = tostring(title or "Choose a file")
  label = tostring(label or "Files")
  extensions = extensions or {}

  local pats = {}
  for _, ext in ipairs(extensions) do
    ext = tostring(ext):gsub("^%.", "")
    if ext ~= "" then pats[#pats + 1] = "*." .. ext end
  end
  if #pats == 0 then pats[1] = "*.*" end

  local shell = Compat.hostShell()
  local osName = Compat.osName()
  local quote = type(shell.quote) == "function"
    and function(v) return shell.quote(v) end
    or function(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end

  if osName == "Windows" then
    local function psq(v) return "'" .. tostring(v):gsub("'", "''") .. "'" end
    local winPats = table.concat(pats, ";")
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms;",
      "$d=New-Object System.Windows.Forms.OpenFileDialog;",
      "$d.Title=", psq(title), ";",
      "$d.Filter=", psq(label .. " (" .. winPats .. ")|" .. winPats .. "|All files (*.*)|*.*"), ";",
      "if($d.ShowDialog() -eq 'OK'){[Console]::OutputEncoding=[Text.Encoding]::UTF8;[Console]::Write($d.FileName)}",
    })
    -- Match Gen1Recomp's own RomImporter/Stadium picker quoting on Windows:
    -- cmd.exe does not treat POSIX single quotes as shell quotes.
    return pipeOutput(shell, 'powershell -NoProfile -STA -Command "' .. script .. '"')
  elseif osName == "OS X" then
    local prompt = title:gsub("\\", "\\\\"):gsub('"', '\\"')
    return pipeOutput(shell, "osascript -e " .. quote('POSIX path of (choose file with prompt "' .. prompt .. '")') .. " 2>/dev/null")
  elseif osName == "Linux" then
    local filter = label .. " | " .. table.concat(pats, " ")
    local path = pipeOutput(shell,
      "zenity --file-selection --title=" .. quote(title)
      .. " --file-filter=" .. quote(filter) .. " 2>/dev/null")
    if path then return path end
    return pipeOutput(shell,
      "kdialog --getopenfilename \"$HOME\" " .. quote(table.concat(pats, " ") .. "|" .. label) .. " 2>/dev/null")
  end
  return nil
end

pipeOutput = function(shell, command)
  if not (shell and type(shell.popen) == "function") then return nil end
  local ok, pipe = pcall(shell.popen, command, "r")
  if not (ok and pipe) then return nil end
  local okRead, out = pcall(pipe.read, pipe, "*a")
  if type(shell.pclose) == "function" then
    pcall(shell.pclose, pipe)
  else
    pcall(pipe.close, pipe)
  end
  if not (okRead and type(out) == "string") then return nil end
  out = out:gsub("^%s+", ""):gsub("%s+$", "")
  return out ~= "" and out or nil
end

Compat.pipeOutput = pipeOutput

-- Open a host-native image picker on desktop. The returned absolute path is
-- only a transient selection token; callers should immediately stage it into
-- the engine save directory with Compat.stageExternal instead of reopening it
-- with io.*, which the mod sandbox does not expose.
function Compat.chooseImageFile(title)
  title = tostring(title or "Choose an image")
  local shell = Compat.hostShell()
  if not shell then return nil end
  local osName = Compat.osName()
  local quote = type(shell.quote) == "function"
    and function(v) return shell.quote(v) end
    or function(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end

  if osName == "Windows" then
    local function psq(v)
      return "'" .. tostring(v):gsub("'", "''") .. "'"
    end
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms;",
      "$d=New-Object System.Windows.Forms.OpenFileDialog;",
      "$d.Title=", psq(title), ";",
      "$d.Filter='Image files (*.png;*.jpg;*.jpeg;*.bmp)|*.png;*.jpg;*.jpeg;*.bmp|All files (*.*)|*.*';",
      "if($d.ShowDialog() -eq 'OK'){[Console]::Write($d.FileName)}",
    })
    return pipeOutput(shell,
      "powershell -NoProfile -STA -Command " .. quote(script))
  end

  if osName == "OS X" then
    local prompt = title:gsub("\\", "\\\\"):gsub('"', '\\"')
    local script = 'POSIX path of (choose file with prompt "' .. prompt .. '")'
    return pipeOutput(shell, "osascript -e " .. quote(script) .. " 2>/dev/null")
  end

  if osName == "Linux" then
    local path = pipeOutput(shell,
      "zenity --file-selection --title=" .. quote(title)
      .. " --file-filter=" .. quote("Images | *.png *.jpg *.jpeg *.bmp *.PNG *.JPG *.JPEG *.BMP")
      .. " 2>/dev/null")
    if path then return path end
    return pipeOutput(shell,
      "kdialog --getopenfilename \"$HOME\" "
      .. quote("*.png *.jpg *.jpeg *.bmp|Images") .. " 2>/dev/null")
  end

  return nil
end

-- Copy an absolute desktop picker path into the engine save directory so the
-- rest of the Stadium importer can use the engine-owned PhysFS backend.  This
-- avoids io.open, which current sandboxes intentionally do not expose.
function Compat.stageExternal(path, relative)
  if type(path) ~= "string" or path == "" then
    return false, "no selected file"
  end
  relative = relative or "picked_stadium.z64"

  local f = Compat.fs()
  if not f then return false, "save directory unavailable" end
  local saveDir
  if type(f.getSaveDirectory) == "function" then
    local okSave, resolved = pcall(f.getSaveDirectory)
    if okSave and type(resolved) == "string" and resolved ~= "" then saveDir = resolved end
  end
  if not saveDir then
    local SaveData = req("src.core.SaveData")
    if SaveData and type(SaveData.portableBaseDir) == "function" then
      local okBase, base = pcall(SaveData.portableBaseDir)
      if okBase and type(base) == "string" and base ~= "" then saveDir = base end
    end
  end
  if not saveDir then return false, "save directory unavailable" end

  local shell = Compat.hostShell()
  if not shell then return false, "host file access unavailable" end
  local dest = saveDir .. "/" .. relative
  local osName = Compat.osName()
  local command

  if osName == "Windows" then
    local function psq(s)
      return "'" .. tostring(s):gsub("'", "''") .. "'"
    end
    local script = table.concat({
      "$src=", psq(path), ";",
      "$dst=", psq(dest), ";",
      "Copy-Item -LiteralPath $src -Destination $dst -Force;",
      "[Console]::Write('OK')",
    })
    local quoted = type(shell.quote) == "function" and shell.quote(script)
      or ('"' .. script:gsub('"', '') .. '"')
    command = "powershell -NoProfile -NonInteractive -Command " .. quoted
  else
    local quote = type(shell.quote) == "function"
      and function(s) return shell.quote(s) end
      or function(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
    command = "cp -f -- " .. quote(path) .. " " .. quote(dest) .. " 2>/dev/null"
  end

  pipeOutput(shell, command)
  local okInfo, info = pcall(f.getInfo, relative, "file")
  if okInfo and info then return true, relative end
  return false, "could not copy selected file"
end

-- Current Android/iOS sandboxes intentionally hide love.system.pickFile from
-- mod code.  RomImporter owns that native bridge in the engine environment.
-- Call only its public choose method on a tiny throwaway receiver shaped so it
-- reaches the mobile ROM picker and does *not* start a Game Boy import.  The
-- selected file lands as picked_rom.gb; StadiumRomMenu consumes it directly.
function Compat.openMobileRomPicker()
  local osName = Compat.osName()
  if osName ~= "Android" and osName ~= "iOS" then
    return false, "not a mobile picker platform"
  end

  local RomImporter = req("src.import.RomImporter")
  if not (RomImporter and type(RomImporter.choose) == "function") then
    return false, "engine ROM picker unavailable"
  end

  local fake = {
    workState = nil,
    isNX = false,
    baseRomDiscovery = false,
    baseRoms = {},
    nativePicker = false,
    android = true, -- current engine uses this branch for Android + iOS
    ready = { red = true, blue = true, yellow = true, gold = true, silver = true, crystal = true },
    pickSkip = {},
    notice = nil,
    pickPending = nil,
    pickTimer = nil,
  }
  function fake:setError(message)
    self._compatError = tostring(message)
  end

  -- Current Gen1Recomp exposes Gold, Silver and Crystal as first-class Gen-2
  -- games with independent importer/cache/save identities. The native picker
  -- bridge is generic, but the throwaway request still has to name the active
  -- edition or Crystal can be routed through Gold-only ready/import state.
  local pickerVersion = "gold"
  local okVersion, GameVersion = pcall(require, "src.core.GameVersion")
  if okVersion and type(GameVersion) == "table" and type(GameVersion.get) == "function" then
    local okGet, current = pcall(GameVersion.get)
    if okGet and (current == "gold" or current == "silver" or current == "crystal") then
      pickerVersion = current
    end
  end

  local ok, err = pcall(RomImporter.choose, fake, pickerVersion)
  if not ok then return false, tostring(err) end
  if fake.pickPending or fake.pickerPendingKind then return true end
  if fake._compatError then return false, fake._compatError end
  if fake.notice and fake.notice.status then
    return false, tostring(fake.notice.status)
  end
  return false, "file picker did not open"
end

-- The Android/iOS native bridge is generic (*/*) even though the historical
-- engine entry point is named for ROM import. Expose a neutral alias for other
-- sandbox-safe file pickers such as custom battle backgrounds.
Compat.openMobileFilePicker = Compat.openMobileRomPicker

return Compat
