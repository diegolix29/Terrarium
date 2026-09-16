-- Mt. Battle rental-team catalogue.
--
-- The catalogue is deliberately plain data: browsing rentals never creates a
-- Pokemon object, never touches save.party/boxes, and never rolls runtime RNG.
-- BEGIN CHALLENGE is the first point at which LevelClone turns the selected
-- rows into a locked Level-50 battle snapshot.  This keeps rental setup both
-- deterministic and completely isolated from the player's real save team.
local V=... or {}
local Dex=V.ColosseumDex
local DexRuntime=V.ColosseumDexRuntime
local DexNames=V.ColosseumDexNames or {}
local MoveCatalog=V.ColosseumMoveCatalog
local Source=V.ColosseumPokemonMoveData
local BattleData=V.MtBattleBattleData
local RP={}
local MAX_DEX=386

local function dexNumber(def)
  return tonumber(def and (def.dex or def.number or def.index))
end

local function generationForDex(dex)
  dex=tonumber(dex)
  if not dex then return nil end
  if dex>=1 and dex<=151 then return 1 end
  if dex<=251 then return 2 end
  if dex<=386 then return 3 end
  return nil
end

local function supported(def)
  if not (def and def.baseStats and def.types) then return false end
  if not (Dex and type(Dex.supported)=="function") then return true end
  local dex=dexNumber(def)
  if not dex then return false end
  local ok,value=pcall(Dex.supported,dex)
  return ok and value==true
end

local function assetSupported(dex)
  if not (Dex and type(Dex.supported)=="function") then return true end
  local ok,value=pcall(Dex.supported,dex)
  return ok and value==true
end

-- Battle 100 move access is independent from the Lv.50 stat normalization.
-- Rentals therefore draw from the four most-recent level-up moves available by
-- Lv.100, matching the same eligibility ceiling used by MOVE PREP/opponents. We reproduce the
-- tiny pure-data rule here instead of constructing a temporary Pokemon, so
-- opening/scrolling the rental screen cannot consume RNG or mutate anything.
-- If a modded species has no level-up row at all, use its first legal TM/HM
-- entries as a deterministic compatibility fallback; species with no usable
-- move in game.data are excluded from the rental catalogue.
local function moveRowsAt100(data,def)
  local ids,seen={},{}
  local function add(id)
    if id and not seen[id] and data and data.moves and data.moves[id] then
      seen[id]=true
      ids[#ids+1]=id
    end
  end
  for _,id in ipairs((def and def.level1Moves) or {}) do add(id) end
  for _,entry in ipairs((def and def.learnset) or {}) do
    local level=tonumber(entry.level)
    if level and level<=100 then add(entry.move) end
  end
  for _,entry in ipairs((def and def.levelMoves) or {}) do
    local level=tonumber(entry.level)
    if level and level<=100 then add(entry.move) end
  end
  while #ids>4 do table.remove(ids,1) end
  if #ids==0 then
    for _,id in ipairs((def and def.tmhm) or {}) do
      add(id)
      if #ids>=4 then break end
    end
  end
  local rows={}
  for _,id in ipairs(ids) do
    local mdef=data.moves[id]
    rows[#rows+1]={id=id,pp=(mdef and mdef.pp) or 0}
  end
  return rows
end

-- The retail acquisition catalogue is already sorted LEVEL -> HM -> TM. Keep
-- the historical rental default of the four most-recent level-up moves; only
-- fall back to compatible machines when the source row has no executable level
-- move in the active host. Unsupported source move ids stay absent (and are
-- reported by ColosseumMoveCatalog) rather than being substituted by name.
local function sourceMoveRowsAt100(data,rows)
  local level,machines={},{}
  for _,row in ipairs(rows or {}) do
    local id=row and row.id
    local def=id and data and data.moves and data.moves[id]
    if def then
      local dst={id=id,pp=tonumber(def.pp) or 0}
      if row.source=="LEVEL" then level[#level+1]=dst else machines[#machines+1]=dst end
    end
  end
  while #level>4 do table.remove(level,1) end
  if #level>0 then return level end
  local out={}
  for i=1,math.min(4,#machines) do out[#out+1]=machines[i] end
  return out
end

local function copyMoves(rows)
  local out={}
  for i,mv in ipairs(rows or {}) do
    out[i]={id=mv.id,pp=mv.pp,ppUps=mv.ppUps,maxPp=mv.maxPp,maxPP=mv.maxPP}
  end
  return out
end

local function runtimeRegistry(game)
  if not (DexRuntime and type(DexRuntime.registry)=="function") then return nil end
  local ok,registry=pcall(DexRuntime.registry,game,{})
  if ok and type(registry)=="table" and type(registry.byDex)=="table" then return registry end
  return nil
end

local function canonicalId(registry,dex)
  local row=registry and registry.byDex and registry.byDex[dex]
  local id=row and row.id or DexNames[dex]
  return type(id)=="string" and id or nil,row
end

-- Full source-backed rental browsing is intentionally independent of the host
-- Pokédex/native species ceiling. ColosseumDex owns National identities 001-386
-- and the GC6E01 PokemonStats cache owns source mechanics for those same rows.
-- A row that cannot yet be represented by the active battle kernel remains in
-- the catalogue with selectable=false; the UI can show the whole generation
-- category while selection fails closed instead of silently truncating at 151.
local function sourceCandidates(game)
  local data=(BattleData and type(BattleData.data)=="function" and BattleData.data(game))
    or (game and game.data) or {}
  local registry=runtimeRegistry(game)
  -- Identity coverage is independently graduated from mechanics extraction.
  -- Therefore a temporary GC6E01 mechanics-cache failure may disable extended
  -- choices, but must never collapse the visible rental catalogue back to the
  -- host's native dex. If neither the graduated registry nor the canonical name
  -- table is available (isolated/legacy tests), use the native fallback below.
  if not (registry or type(DexNames[1])=="string") then return nil end
  local sourceAvailable=type(Source)=="table" and Source.discId=="GC6E01" and type(Source.species)=="table"
  local out={}
  for dex=1,MAX_DEX do
    local species,identity=canonicalId(registry,dex)
    if not species then return nil end
    local sourceSpecies=sourceAvailable and Source.species[dex] or nil

    local def=data.pokemon and data.pokemon[species]
    local sourceRows,diag
    -- BattleData already resolved/sorted the exact GC6E01 acquisition rows once
    -- while constructing its cached challenge view. Re-running MoveCatalog.pool
    -- for all 386 entries every time the rental browser opens duplicated that
    -- work (and hundreds of short-lived row tables) for no change in semantics.
    -- Only legacy/native fallback data still needs a direct catalogue resolve.
    if not (def and def.__cbeMtBattleSource)
        and sourceSpecies and MoveCatalog and type(MoveCatalog.pool)=="function" then
      sourceRows,diag=MoveCatalog.pool(game,{species=species,dex=dex,nationalDex=dex,moves={}})
    end
    local moves
    if def and def.__cbeMtBattleSource then moves=moveRowsAt100(data,def)
    elseif diag and diag.sourceBacked then moves=sourceMoveRowsAt100(data,sourceRows)
    elseif def then moves=moveRowsAt100(data,def)
    else moves={} end
    if #moves==0 and BattleData and type(BattleData.fallbackMove)=="function" then
      local fallback=BattleData.fallbackMove(data,def)
      local mdef=fallback and data.moves and data.moves[fallback]
      if fallback and mdef then moves={{id=fallback,pp=tonumber(mdef.pp) or 0}} end
    end
    local hostReady=supported(def)
    local modelReady=assetSupported(dex)
    local selectable=hostReady and modelReady and #moves>0
    local reason
    if not modelReady then reason="Colosseum actor unavailable"
    elseif not sourceSpecies and not hostReady then reason="GC6E01 rental mechanics source unavailable"
    elseif not hostReady then reason="challenge-local source species projection unavailable"
    elseif #moves==0 then reason=(diag and diag.error) or "no source-proven executable rental moves"
    end
    local stats=sourceSpecies and sourceSpecies.baseStats or {}
    out[#out+1]={
      source="rental",species=species,name=(identity and identity.name) or species,
      dex=dex,generation=generationForDex(dex),level=50,moves=copyMoves(moves),
      selectable=selectable,failedClosed=not selectable,unavailableReason=reason,
      sourceBacked=true,sourceMechanics=sourceSpecies~=nil,
      sourceBaseStats={hp=stats.hp,attack=stats.attack,defense=stats.defense,speed=stats.speed,
        specialAttack=stats.specialAttack,specialDefense=stats.specialDefense},
      sourceTypeIds={sourceSpecies and sourceSpecies.typeIds and sourceSpecies.typeIds[1],sourceSpecies and sourceSpecies.typeIds and sourceSpecies.typeIds[2]},
      unresolvedMoveCount=tonumber(def and def.__cbeMtBattleUnresolvedMoves) or tonumber(diag and diag.unresolved) or 0,
    }
  end
  return out
end

local function identityFallbackCandidates(game)
  -- Never collapse the visible rental browser back to the host Pokédex ceiling.
  -- If the tiny GC6E01 mechanics cache is temporarily unavailable, the National
  -- identity table still lets setup show every Gen 1/2/3 row and explain why an
  -- affected row is unavailable. This path is deliberately read-only and does
  -- not fabricate mechanics for Johto/Hoenn on a Gen1 host.
  if type(DexNames[1])~="string" then return nil end
  local data=game and game.data or {}
  local out={}
  for dex=1,MAX_DEX do
    local species=DexNames[dex]
    if type(species)~="string" then return nil end
    local def=data.pokemon and data.pokemon[species]
    local moves=def and moveRowsAt100(data,def) or {}
    local modelReady=assetSupported(dex)
    local hostReady=supported(def)
    out[#out+1]={source="rental",species=species,name=species:gsub("_"," "),dex=dex,
      generation=generationForDex(dex),level=50,moves=copyMoves(moves),
      selectable=hostReady and modelReady and #moves>0,failedClosed=not (hostReady and modelReady and #moves>0),
      unavailableReason=not modelReady and "Colosseum actor unavailable"
        or (not hostReady and "GC6E01 rental mechanics source unavailable")
        or (#moves==0 and "no source-proven executable rental moves" or nil),
      sourceBacked=false,sourceMechanics=false}
  end
  return out
end

-- Returns one candidate per National-Dex identity whenever the graduated
-- identity catalog is present. This is always 001-386 even on a Gen-1 host.
-- Missing GC6E01 mechanics only makes affected rows non-selectable; it never
-- shrinks the visible catalog. Isolated legacy callers without that identity
-- catalog retain the pre-existing native-data fallback below.
function RP.candidates(game)
  local data=game and game.data
  local source=sourceCandidates(game)
  if not source then source=identityFallbackCandidates(game) end
  if source then
    for i,row in ipairs(source) do row.index=i end
    return source
  end
  local out={}
  for species,def in pairs((data and data.pokemon) or {}) do
    if supported(def) then
      local moves=moveRowsAt100(data,def)
      if #moves>0 then
        local dex=dexNumber(def)
        out[#out+1]={source="rental",species=species,dex=dex,generation=generationForDex(dex),level=50,moves=moves,
          selectable=true,failedClosed=false,sourceBacked=false}
      end
    end
  end
  table.sort(out,function(a,b)
    local ad,bd=a.dex,b.dex
    if ad and bd and ad~=bd then return ad<bd end
    if ad and not bd then return true end
    if bd and not ad then return false end
    return tostring(a.species)<tostring(b.species)
  end)
  for i,row in ipairs(out) do
    row.index=i
    row.moves=copyMoves(row.moves)
  end
  return out
end

RP._test={moveRowsAt100=moveRowsAt100,moveRowsAt50=moveRowsAt100,sourceMoveRowsAt100=sourceMoveRowsAt100,
  sourceCandidates=sourceCandidates,identityFallbackCandidates=identityFallbackCandidates,
  supported=supported,generationForDex=generationForDex}

return RP
