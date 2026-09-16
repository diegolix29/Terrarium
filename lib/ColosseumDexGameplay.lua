-- One ordinary-startup entry point used by main.lua and integration tests.
local V=... or {}
local Species=assert(V.ColosseumDexSpecies,'ColosseumDexSpecies required')
local Bridge=assert(V.ColosseumDexSaveBridge,'ColosseumDexSaveBridge required')
local Encounters=assert(V.ExpandedWildEncounters,'ExpandedWildEncounters required')
local G={VERSION=1}
local state={active=false,native=0,added=0,coverage=0,suppressed=0,blocker='gameplay startup has not run'}
local modRef,generation
function G.status()
  local out={};for k,v in pairs(state) do out[k]=v end
  local p=Bridge.status();out.persistence=p;out.species=Species.status()
  out.active=state.active and p.ready==true
  if not p.ready then out.blocker=p.blocker end
  return out
end
function G.install(mod,gen)
  modRef=mod;generation=tonumber(gen)
  if mod.exports then mod.exports.colosseumDexSpawns=G.status end
  local src=Species.status()
  if not src.ready then state.blocker=src.blocker;return false,state.blocker end
  local ok,why=Bridge.install(mod,gen)
  if not ok then state.blocker=why;return false,why end
  ok,why=Encounters.install(mod,gen,{
    persistenceReady=function() return Bridge.status().ready==true end,
    speciesReady=function(id,dex,ctx,level)
      local data=ctx and ctx.data or (modRef.game and modRef.game.data)
      return Species.usable(data,id,level)
    end,
    mode=function()
      local settings=V.BattleSettings
      return settings and settings.wildSpawnMode and settings.wildSpawnMode(modRef.game) or 'mixed'
    end,
    observe=function(enc,reason,ctx)
      state.lastReason=reason;state.lastMap=ctx and ctx.mapId
      state.lastSpecies=enc and enc.species
      state.lastMethod=ctx and (ctx.kind or (ctx.terrain=="water" and "surf" or "land"))
      if reason=="expanded-added-coverage" then state.coverage=state.coverage+1 end
      if enc and enc.__cbeExpandedDex then state.added=state.added+1
      elseif enc then state.native=state.native+1 else state.suppressed=state.suppressed+1 end
    end,
  })
  state.active=ok==true;state.blocker=nil;state.generation=gen
  if not ok then state.blocker=why end
  if mod.exports then mod.exports.colosseumDexSpawns=G.status end
  local logger=mod.log
  if logger and logger.info and ok then
    pcall(logger.info,logger,'ColosseumDex wild spawns ACTIVE: Gen %d; %d source species registered; checked save bridge installed',gen,src.registered)
  end
  return ok,why
end
return G
