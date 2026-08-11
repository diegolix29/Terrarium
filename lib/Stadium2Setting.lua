-- Stadium 2 Settings
--
-- Settings for Pokemon Stadium 2 model support (Gen 2 Pokemon, species 152-251)

local V = ...

local ModSetting = V.require("ModSetting")

local Stadium2Setting = {}

Stadium2Setting.KEY = "dramatic_shape:stadium2"
Stadium2Setting.LABEL = "STADIUM 2"

-- The setting: OFF by default, ON when models are available
Stadium2Setting.setting =
  ModSetting.new(Stadium2Setting.KEY, Stadium2Setting.LABEL,
                 { false, true },
                 { "OFF", "ON" })
  :setGate(function(value)
    if value == false then return true end -- OFF is always available
    -- ON requires Stadium 2 models to be built
    local ok, install = pcall(V.require, "Stadium2Install")
    return ok and install and install.ready()
  end)

-- Status display for Stadium 2 model availability (read-only)
-- This is NOT a ModSetting - it's just a display row
function Stadium2Setting.statusRow()
  local ok, install = pcall(V.require, "Stadium2Install")
  if not ok or not install then
    return {
      id = "dramatic_shape:stadium2_status",
      label = "STADIUM 2 STATUS",
      value = function() return "No ROM" end,
      step = function() return true end, -- No-op (read-only)
    }
  end
  
  return {
    id = "dramatic_shape:stadium2_status",
    label = "STADIUM 2 STATUS",
    value = function()
      if install.status and install.status.state == "building" then
        return "BUILDING"
      elseif install.ready() then
        return "READY (251 models)"
      else
        return "No ROM"
      end
    end,
    step = function() return true end, -- No-op (read-only)
  }
end

-- Check if Stadium 2 is enabled
function Stadium2Setting.enabled()
  return Stadium2Setting.setting:get() and true or false
end

-- Check if Stadium 2 models are available
function Stadium2Setting.modelsAvailable()
  local ok, install = pcall(V.require, "Stadium2Install")
  return ok and install and install.ready()
end

return Stadium2Setting