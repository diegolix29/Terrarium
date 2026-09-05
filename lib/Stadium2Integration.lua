-- Stadium 2 Integration Module
--
-- This module bridges the Stadium 2 system with the existing voxel implementation,
-- providing unified access to both Stadium 1 (Gen 1 Pokemon) and Stadium 2 (Gen 2 Pokemon).

local V = ...

local Stadium2Integration = {}

-- Runtime pack loader for battle/overworld rigs.
--
-- Stadium2Install only differs at BUILD time (which ROM is extracted).  Both
-- Stadium 1 and Stadium 2 builds land as full DSM3 packs read by StadiumPack
-- and consumed by StadiumRig.  Stadium2Pack.load delegates there too.
function Stadium2Integration.getPackLoader(species)
  return V.require("StadiumPack")
end

-- Get the appropriate install module based on species number
function Stadium2Integration.getInstallModule(species)
  if type(species) ~= "number" then
    return V.require("StadiumInstall") -- Default to Stadium 1
  end
  
  if species > 151 then
    return V.require("Stadium2Install") -- Gen 2 Pokemon
  else
    return V.require("StadiumInstall") -- Gen 1 Pokemon
  end
end

-- Check if any Stadium models are available
function Stadium2Integration.anyAvailable()
  local StadiumInstall = V.require("StadiumInstall")
  local Stadium2Install = V.require("Stadium2Install")
  
  return StadiumInstall.available() or Stadium2Install.available()
end

-- Check if models are available for a specific species
function Stadium2Integration.speciesAvailable(species)
  local packLoader = Stadium2Integration.getPackLoader(species)
  local installModule = Stadium2Integration.getInstallModule(species)
  
  return installModule.available() or packLoader.available()
end

-- Get the total count of Pokemon supported
function Stadium2Integration.totalSupported()
  local StadiumInstall = V.require("StadiumInstall")
  local Stadium2Install = V.require("Stadium2Install")
  
  local count = 0
  if StadiumInstall.available() then
    count = count + StadiumInstall.COUNT
  end
  if Stadium2Install.available() then
    count = count + Stadium2Install.COUNT
  end
  
  return count
end

-- Get ROM status information
function Stadium2Integration.romStatus()
  local StadiumInstall = V.require("StadiumInstall")
  local Stadium2Install = V.require("Stadium2Install")
  
  return {
    stadium1 = {
      present = StadiumInstall.romPresent(),
      ready = StadiumInstall.ready(),
      count = StadiumInstall.COUNT
    },
    stadium2 = {
      present = Stadium2Install.romPresent(),
      ready = Stadium2Install.ready(),
      count = Stadium2Install.COUNT
    }
  }
end

-- Build missing models
function Stadium2Integration.buildMissing(progressCallback)
  local results = {}
  
  -- Build Stadium 1 models if needed
  local StadiumInstall = V.require("StadiumInstall")
  if StadiumInstall.romPresent() and not StadiumInstall.ready() then
    -- This would call the existing Stadium 1 build system
    results.stadium1 = "Stadium 1 build system already exists"
  end
  
  -- Build Stadium 2 models if needed
  local Stadium2Install = V.require("Stadium2Install")
  if Stadium2Install.romPresent() and not Stadium2Install.ready() then
    local ok, err = Stadium2Install.build(progressCallback)
    results.stadium2 = ok and "success" or ("failed: " .. (err or "unknown"))
  end
  
  return results
end

-- Get ROM hint paths for user
function Stadium2Integration.romHints()
  local StadiumInstall = V.require("StadiumInstall")
  local Stadium2Install = V.require("Stadium2Install")
  
  return {
    stadium1 = StadiumInstall.romHintFile(),
    stadium2 = Stadium2Install.romHintFile()
  }
end

return Stadium2Integration