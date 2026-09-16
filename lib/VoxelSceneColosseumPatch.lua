-- Pokemon Colosseum Overworld Models: rendering is integrated through
-- VoxelScenePatch.lua alongside the Stadium overworld hooks.
--
-- safePrepare / safeDraw / safeCast on OverworldColosseum are invoked from the
-- same three VoxelScene structural seams as OverworldStadium.
local V = ...
local M = {}

function M.install(BaseV)
  return V.OverworldColosseum ~= nil
end

return M
