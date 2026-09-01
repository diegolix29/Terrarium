-- Stadium Model Handlers - Stub implementation
-- This is a simplified version of the full model handlers system
-- from the reference Stadium2_importer mod. For now it provides
-- basic compatibility with the pack format.

local Handlers = {}

-- Compatibility exports - these will be expanded as needed
Handlers.BY_DESCRIPTOR = {}
Handlers.BY_TARGET = {}
Handlers.FAMILY_IDS = {}
Handlers.FAMILY_NAMES = {}
Handlers.CONFIDENCE_IDS = {}
Handlers.CONFIDENCE_NAMES = {}

-- Pack extension data into the pack format
function Handlers.packExtension(records, sourceBase, fragmentData, renderInfo)
  -- For now, return empty string if no handlers
  -- This maintains compatibility with the pack format
  if not records or #records == 0 then return "" end
  
  -- Basic S2HX format stub
  local parts = { "S2HX", string.char(4, 0), string.char(0, 0) } -- version 4, 0 records
  return table.concat(parts)
end

-- Read extension data from pack format
function Handlers.readExtension(packBytes)
  -- For now, return nil if no extension present
  if type(packBytes) ~= "string" or #packBytes < 20 then return nil end
  local footer = #packBytes - 7
  if packBytes:sub(footer, footer + 3) ~= "S2HF" then return nil end
  -- Basic stub - return empty extension structure
  return { version = 4, sourceBase = 0x8FF00000, records = {}, fragment = "", render = nil }
end

-- Evaluate a handler record
function Handlers.evaluate(record, phase, runtime)
  return nil
end

-- Run handlers
function Handlers.run(records, phase, runtime, state)
  return state or {}
end

-- Run extension handlers
function Handlers.runExtension(extension, phase, runtime, state)
  return nil, nil
end

return Handlers
