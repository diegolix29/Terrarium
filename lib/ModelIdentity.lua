-- Read-only National Dex and colour identity, shared by battle/cache consumers.
local V=...
local M={version=1}
local sourceNames,sourceDexByName=nil,{}
local function sourceDex(species)
  if species==nil then return nil end
  local names=V.ColosseumDexNames
  if type(names)~="table" then return nil end
  if names~=sourceNames then
    sourceNames=names;sourceDexByName={}
    for dex,name in pairs(names) do
      if tonumber(dex) and type(name)=="string" then sourceDexByName[name:upper()]=tonumber(dex) end
    end
  end
  return sourceDexByName[tostring(species):upper()]
end
function M.resolve(game,battler)
  if type(battler)~="table" then return nil,"Pokemon identity unavailable" end
  local mon=type(battler.mon)=="table" and battler.mon or battler
  local species=mon.species or mon.id
  local defs=game and game.data and game.data.pokemon
  local def=defs and (defs[species] or defs[tostring(species)])
  -- Species identity wins over detached numeric hints. This keeps 3D actors and
  -- HUD portraits on the exact same National-Dex identity even when a challenge
  -- clone carries a stale/foreign `dex` field.
  local dex=tonumber(def and (def.nationalDex or def.dex or def.number or def.index))
    or sourceDex(species)
    or tonumber(mon.nationalDex)
    or tonumber(mon.speciesIndex)
    or tonumber(mon.dex)
  if not dex and type(species)=="number" then dex=species end
  if not dex and defs and species then
    local wanted=tostring(species):upper()
    for _,candidate in pairs(defs) do
      if type(candidate)=="table" and (tostring(candidate.id):upper()==wanted
          or tostring(candidate.name):upper()==wanted) then
        dex=tonumber(candidate.nationalDex or candidate.dex or candidate.number or candidate.index);break
      end
    end
  end
  -- The Colosseum actor catalog now genuinely covers National Dex 1..386.
  -- Keep identity validation tied to that catalog instead of the old Gen I/II
  -- ceiling of 251 so cross-generation Mt. Battle consumers do not reject a
  -- source-backed Hoenn actor solely because its National Dex number is >251.
  local supported=dex and V.ColosseumDex and type(V.ColosseumDex.supported)=="function"
    and V.ColosseumDex.supported(dex)
  if not dex or dex%1~=0 or dex<1
      or (V.ColosseumDex and type(V.ColosseumDex.supported)=="function" and not supported)
      or (not V.ColosseumDex and dex>386) then
    return nil,"No supported National Dex mapping for "..tostring(species)
  end
  return dex,V.ShinySupport.variant(battler)
end
return M
