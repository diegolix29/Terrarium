-- Mt. Battle Level-50 lock: challenge battle copies never receive native EXP.
-- The XP Bank independently computes the earned share and pays it only after
-- the run. This hook is intentionally narrow: ordinary battles and XP Bank
-- distribution continue through the engine's normal award functions.
local L={installed=false,suppressed=0}

local function belongsToLockedBattle(ctx)
  if type(ctx)~="table" then return false end
  local battle=ctx.battle
  if type(battle)=="table" and battle.cbeMtBattleLevelLock==true then return true end
  local mon=ctx.mon or ctx.pokemon
  return type(mon)=="table" and mon.__cbeMtBattleLevelLock==true
end

function L.install(mod)
  if L.installed then return true end
  local hooks=mod and mod.hooks
  if not (hooks and type(hooks.wrap)=="function") then return false end
  hooks:wrap("battle.exp_award",function(next,ctx,...)
    if belongsToLockedBattle(ctx) then
      L.suppressed=L.suppressed+1
      return nil
    end
    return next(ctx,...)
  end,5000,"mtbattle-level-lock")
  L.installed=true
  return true
end

L._test={belongsToLockedBattle=belongsToLockedBattle}
return L
