-- Terrarium Advance Voxel Mod - Generation Router
--
-- This mod provides full 3D diorama overworld rendering for both
-- Gen 1 (Red/Blue/Yellow) and Gen 2 (Gold/Silver/Crystal) games.
-- It routes to generation-specific backends for optimal compatibility.

local mod = ...

-- Generation detection
local function detectGeneration()
  local ok, GameVersion = pcall(require, "src.core.GameVersion")
  if ok and type(GameVersion) == "table" then
    if type(GameVersion.generation) == "function" then
      local okGen, generation = pcall(GameVersion.generation)
      if okGen and tonumber(generation) then return tonumber(generation) end
    end
    if type(GameVersion.isGen2) == "function" then
      local okGen2, yes = pcall(GameVersion.isGen2)
      if okGen2 and yes then return 2 end
    end
  end
  return 1 -- Default to Gen 1
end

local generation = detectGeneration()
mod.log:info("Terrarium Advance Voxel Mod: Generation %s detected", tostring(generation))

-- Route to generation-specific backend
if generation == 1 then
  -- Gen 1 backend
  local source, readErr = mod:read("gen1/main.lua")
  if not source then
    error(("TERRARIUM: missing Gen 1 backend: %s"):format(tostring(readErr)), 0)
  end
  local chunk, compileErr = load(source, "@" .. mod.path .. "/gen1/main.lua")
  if not chunk then
    error(("TERRARIUM: Gen 1 backend failed to compile: %s"):format(tostring(compileErr)), 0)
  end
  return chunk(mod)
else
  -- Gen 2 backend
  local source, readErr = mod:read("gen2/main.lua")
  if not source then
    error(("TERRARIUM: missing Gen 2 backend: %s"):format(tostring(readErr)), 0)
  end
  local chunk, compileErr = load(source, "@" .. mod.path .. "/gen2/main.lua")
  if not chunk then
    error(("TERRARIUM: Gen 2 backend failed to compile: %s"):format(tostring(compileErr)), 0)
  end
  return chunk(mod)
end