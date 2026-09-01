-- Compatibility shim for STADIUM2_IMPORTER's src.ui.gen2.BattleAnimView dependency
-- This module provides a minimal BattleAnimView interface for STADIUM2_IMPORTER
-- Since the base engine doesn't have this module, we provide a no-op implementation

local BattleAnimView = {}

-- Flag to prevent STADIUM2_IMPORTER from installing hooks multiple times
BattleAnimView.stadium2ImporterProjection = true

-- No-op present method - STADIUM2_IMPORTER will hook this if needed
function BattleAnimView:present(runner, drawBackground)
  return drawBackground and drawBackground() or nil
end

-- No-op drawObjects method - STADIUM2_IMPORTER will hook this if needed
function BattleAnimView:drawObjects(runner, battle)
  -- No-op: there's no actual animation view to draw objects for
  return nil
end

return BattleAnimView
