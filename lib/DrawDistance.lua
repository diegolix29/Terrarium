-- Desktop residency ring: whole current map plus all direct connections.
-- Keep the engine's complete state and two-hop discovery data untouched.
-- This replaces the old DrawDistance implementation with a more accurate
-- neighbor filtering system based on actual map connections.
local V = ...
local N = {}

-- Use the old key name for backward compatibility with existing saves
N.KEY = "drawDistance"
N.LABEL = "DRAW DIST"

N.setting = V.require('ModSetting').new(N.KEY, N.LABEL, {1, 0}, {'FAR', 'NEAR'})

function N.apply(state)
  if not state then return state end
  if not state.neighbors then
    state.neighbors = {}
    return state
  end
  -- FAR (1): render all neighbors (max quality, shows void fill trees)
  -- NEAR (0): filter to only connected neighbors (performance mode)
  if N.setting:get() == 1 then return state end
  if not (state.map and state.map.def) then return state end
  local keep = {[state.map.id] = true}
  local con = state.map.def.connections
  if type(con) ~= 'table' then return state end -- unknown custom-map topology
  for _, c in pairs(con) do
    if type(c) == 'table' and c.map then keep[c.map] = true end
  end
  local neighbors, seen = {}, {}
  for _, nb in ipairs(state.neighbors or {}) do
    local id = nb.map and nb.map.id
    if keep[id] and id ~= state.map.id and not seen[id] then
      neighbors[#neighbors + 1] = nb
      seen[id] = true
    end
  end
  if #neighbors == #(state.neighbors or {}) then return state end
  local out = {}
  for k, v in pairs(state) do out[k] = v end
  out.neighbors = neighbors
  return out
end

-- Legacy compatibility functions
function N.level()
  return N.setting:get() or 1  -- Default to FAR (1)
end

function N.neighborLimit()
  return N.setting:get() == 1 and math.huge or 0
end

function N.row()
  return N.setting:row()
end

function N.sync(value)
  N.setting:sync(value)
end

return N
