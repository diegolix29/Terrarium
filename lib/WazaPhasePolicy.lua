local V=...
local P={version=4}
local memo=setmetatable({},{__mode='k'})
function P.role(name)
 name=tostring(name or 'all'):lower()
 return (name=='status' or name:match('^damage')) and 'damage' or 'attack'
end
local function named(phases,name)
 for _,p in ipairs(phases)do if tostring(p.name or p.phase or 'all'):lower()==name then return p end end
end
function P.select(spec,opts)
 if type(spec)~='table' or type(spec.wazaPhases)~='table' then return spec end
 opts=opts or {}
 if spec.phaseSelection and not next(opts) then return spec end
 local source=spec.sourceSpec or spec
 local moveId=tonumber(opts.moveId or (spec.phaseSelection and spec.phaseSelection.moveId) or source.moveId)
 local dex=tonumber(opts.dex or (spec.phaseSelection and spec.phaseSelection.dex))
 local stage=opts.stage or (spec.phaseSelection and spec.phaseSelection.stage) or 'attack'
 local explicit=opts.phase
 local damagePhase=opts.damagePhase or (spec.phaseSelection and spec.phaseSelection.damageOverride)
 local key=table.concat({tostring(moveId or ''),tostring(dex or ''),stage,tostring(damagePhase or ''),tostring(explicit or '')},':')
 memo[source]=memo[source] or setmetatable({},{__mode='v'});if memo[source][key] then return memo[source][key] end
 local phases=source.wazaPhases
  local attack
  local retailModelPhase
 local retailModelBlocker
  if explicit then attack=named(phases,tostring(explicit):lower()) end
  if not attack and stage=='charge' then attack=named(phases,'special') or named(phases,'special_sp1') end
 local row=V and V.ColosseumDex and V.ColosseumDex.species and V.ColosseumDex.species[dex]
 local species=row and row[1]
 if not attack and stage~='charge' and dex then
  -- MoveFX extraction resolves retail main.dol lbl_80373750 against the exact
  -- FSYS id of every WZX chapter and bakes the result into the cache.  Runtime
  -- therefore follows the complete source model-specific selector table instead
  -- of maintaining a small hand list of famous variants.
  local byMove=type(source.retailModelPhasesByMove)=="table" and source.retailModelPhasesByMove or nil
  local byDex=byMove and moveId and (byMove[moveId] or byMove[tostring(moveId)]) or nil
  if type(byDex)~="table" then byDex=type(source.retailModelPhases)=="table" and source.retailModelPhases or nil end
  retailModelPhase=byDex and (byDex[dex] or byDex[tostring(dex)]) or nil
  local blockerMoves=type(source.retailModelOverrideBlockersByMove)=="table" and source.retailModelOverrideBlockersByMove or nil
  local blockers=blockerMoves and moveId and (blockerMoves[moveId] or blockerMoves[tostring(moveId)]) or nil
  if type(blockers)~="table" then blockers=type(source.retailModelOverrideBlockers)=="table" and source.retailModelOverrideBlockers or nil end
  retailModelBlocker=blockers and (blockers[dex] or blockers[tostring(dex)]) or nil
  if retailModelPhase then
   attack=named(phases,retailModelPhase)
   if not attack then retailModelBlocker="retail model-specific attack chapter missing from decoded Waza phases" end
  end
 end
 if not attack and not retailModelBlocker and stage~='charge' and species then
  attack=named(phases,species)
  -- The PKX spells Charmeleon "lizardo"; some WZX variants spell it "rizardo".
  if not attack and dex==5 then attack=named(phases,'rizardo') end
 end
 if not attack and not retailModelBlocker then
  for _,name in ipairs({'attack','all','special','sp1'})do attack=named(phases,name);if attack then break end end
 end
 -- Numbered banks are conditional source variants, not proven hit ordinals.
 -- Keep the primary reaction unless a caller supplies an explicit variant.
 local damage=damagePhase and P.role(damagePhase)=='damage' and named(phases,tostring(damagePhase):lower())
 damage=damage or named(phases,'damage') or named(phases,'status')
 -- Some source banks contain only one noncanonical chapter. Preserve it;
 -- arbitrary species/numbered variants in larger banks are never layered.
 if not attack and not retailModelBlocker and #phases==1 and P.role(phases[1].name)=='attack' then attack=phases[1] end
 local selected,keep={},{}
 for _,phase in ipairs({attack or false,damage or false})do
  if phase then selected[#selected+1]=phase;keep[tostring(phase.name or phase.phase or 'all'):lower()]=true end
 end
 local out={};for k,v in pairs(source)do out[k]=v end
 -- A decoded stem can back several moves. Its importer's ID is not the
 -- active move's identity for travel geometry and model-specific playback.
 out.moveId=moveId or source.moveId
 out.wazaPhases=selected;out.sourceSpec=source
 out.phaseSelection={moveId=moveId,dex=dex,stage=stage,damageOverride=damagePhase,attack=attack and attack.name,damage=damage and damage.name,
  retailModelOverride=retailModelPhase,retailModelOverrideBlocked=retailModelBlocker}
 if source.generatorPrograms then
  out.generatorPrograms={}
  for _,g in ipairs(source.generatorPrograms)do if keep[tostring(g.phase or 'all'):lower()] then out.generatorPrograms[#out.generatorPrograms+1]=g end end
 end
 if type(source.sounds)=="table" then
  out.sounds={}
  for _,sound in ipairs(source.sounds) do
   -- Unphased legacy records have no variant attribution and stay intact.
   if sound.phase==nil or keep[tostring(sound.phase):lower()] then out.sounds[#out.sounds+1]=sound end
  end
 end
 memo[source][key]=out;return out
end
function P.cameraStyle(spec)
  local style=spec and spec.style or "impact"
  if style~="impact" then return style end
  spec=P.select(spec)
  if not spec then return style end
  if spec.moveId==89 or spec.moveId==222 then return "wave" end
  local attack
  for _,ph in ipairs(spec.wazaPhases or {})do if P.role(ph.name)=="attack" then attack=ph;break end end
  if not attack then return style end
  if spec.phaseSelection and spec.phaseSelection.stage=="charge" then return "self" end
  local kind=tonumber(attack.sequenceKind or (attack.root and attack.root.kind))
  if kind==1 or kind==6 or kind==12 or kind==13 then
    for _,e in ipairs(attack.entries or {})do
      if (e.kind=="particle" or e.kind=="model") and tonumber(e.attachment)==1 then return "projectile" end
    end
  end
  if kind==2 or kind==3 or kind==4 or kind==5 or kind==7 then return "contact" end
  if attack.name=="special" and not (spec.phaseSelection and spec.phaseSelection.damage) then return "self" end
  if kind==0 then return spec.phaseSelection and not spec.phaseSelection.damage and "self" or "target" end
  return style
end
return P
