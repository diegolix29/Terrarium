-- Mt. Battle 100 Level 50 normalization.
--
-- Wraps the engine's own tournament/auto-level primitive
-- (src/link/Protocol.lua's packMon/unpackMon, and packMon2/unpackMon2 for
-- Gen 2) rather than reimplementing stat math: verified directly that
-- unpackMon(data, packMon(mon), {forceLevel=N}) builds a brand-new table
-- via Stats.calc, never touches the source mon, and (per Protocol.lua's own
-- comment) is exactly the "auto-level tournament" mode built for a Lv12 and
-- a Lv100 party to battle on equal footing -- precisely Mt. Battle's
-- Level 50 requirement. Moves are carried through UNCHANGED (packMon/
-- unpackMon never touch a mon's learnset eligibility), matching the design
-- requirement that a player's moves are preserved regardless of what a
-- normal Level 50 learnset would allow.
local V=... or {}
local req=V.engineRequire or require
local BattleData=V.MtBattleBattleData
local LC={}
LC.LEVEL_LOCK=50

local function protocol() return req("src.link.Protocol") end

local function lockedMoveRows(mon)
  local out={}
  for i,mv in ipairs((mon and mon.moves) or {}) do
    if type(mv)=="table" then
      -- Engine move rows are deliberately shallow save data. Gen 1 stores
      -- {id,pp,ppUps}; Gen 2 additionally stores maxPp. Keep the maxPP alias
      -- accepted by the presentation/doubles bridge, but do not recursively
      -- freeze arbitrary table-valued annotations: runtime/mod metadata can be
      -- cyclic and is not part of Mt. Battle's moveset-lock contract.
      out[i]={id=mv.id,pp=mv.pp}
      if mv.ppUps~=nil then out[i].ppUps=mv.ppUps end
      if mv.maxPp~=nil then out[i].maxPp=mv.maxPp end
      if mv.maxPP~=nil then out[i].maxPP=mv.maxPP end
    else
      -- A malformed/bare move row is not an engine save shape, but preserving
      -- the scalar keeps the helper non-recursive and no less tolerant than it
      -- was before.
      out[i]=mv
    end
  end
  return out
end

-- Rental teams do not have a live save/PC mon to resolve on later fights, so
-- freeze deterministic Gen-1 DVs alongside species+moves.  The hash is stable
-- across reloads and consumes no engine RNG; it exists only to give the rental
-- clone a repeatable legal stat block, never to alter the player's save.
local function rentalDVs(species,slot)
  local h=5381
  local key=tostring(species or "")..":"..tostring(slot or 0)
  -- Keep the multiply comfortably below Lua's exact-integer range even on
  -- the engine's double-number Lua 5.1 build.
  for i=1,#key do h=(h*131+key:byte(i))%2147483647 end
  local function nibble(shift) return math.floor(h/(2^shift))%16 end
  local dvs={attack=nibble(0),defense=nibble(4),speed=nibble(8),special=nibble(12)}
  dvs.hp=(dvs.attack%2)*8+(dvs.defense%2)*4+(dvs.speed%2)*2+(dvs.special%2)
  return dvs
end

local function copyDVs(dvs)
  if type(dvs)~="table" then return nil end
  return {hp=dvs.hp,attack=dvs.attack,defense=dvs.defense,speed=dvs.speed,special=dvs.special}
end

-- Clone one real mon at a forced level. Returns a brand-new table; the
-- source `mon` is read-only here and is never mutated.
--   generation: 1 or 2
--   data: game.data (species/move defs the clone's stats are computed from)
function LC.clone(mon,generation,level,data)
  local P=protocol()
  if generation==2 then
    local packed=P.packMon2(mon)
    return P.unpackMon2(data,packed,{forceLevel=level})
  end
  local packed=P.packMon(mon)
  local clone=P.unpackMon(data,packed,{forceLevel=level})
  -- Protocol.unpackMon is the correct tournament/auto-level transport, but the
  -- Red host's Stats.calc can only return one `special` field. BattleData's
  -- challenge-local definitions carry the exact GC6E01 SpA/SpD values for native
  -- Kanto species too, so finish that one projected case with the same split-stat
  -- calculator used for extended rentals/opponents. Forced-level clones already
  -- start full/fresh by Protocol contract; update hp to the source max as well.
  local def=clone and data and data.pokemon and data.pokemon[clone.species]
  if clone and def and def.__cbeMtBattleSource and BattleData and type(BattleData.gen1Stats)=="function" then
    clone.stats=BattleData.gen1Stats(def,clone.level,clone.dvs,clone.statExp)
    clone.hp=clone.stats and clone.stats.hp or clone.hp
  end
  return clone
end

-- Build a disposable opponent party for one Mt. Battle launch. Gen 2's native
-- Battle.new keeps trainer.party by reference, so handing it the persisted
-- currentEncounter.mons array would let battle HP/status/PP mutations leak back
-- into the saved encounter (and would also trust any legacy level field). The
-- link/tournament clone primitive is already the engine's source of truth for
-- forced-level stat reconstruction, so use it here as well. Explicit per-mon
-- identity flags that Protocol intentionally derives/omits are restored from the
-- encounter copy only after the new runtime object exists.
function LC.opponentParty(mons,generation,level,data)
  level=tonumber(level) or LC.LEVEL_LOCK
  local out={}
  for i,mon in ipairs(mons or {}) do
    if type(mon)~="table" then return nil,("opponent slot "..i.." is invalid") end
    local clone=LC.clone(mon,generation,level,data)
    if not clone then return nil,("opponent slot "..i.." failed to clone") end
    clone.level=level
    clone.__cbeMtBattleLevelLock=true
    -- Team generation can explicitly force a shiny ace after Mon.new. Protocol
    -- correctly derives ordinary shininess from DVs and therefore does not carry
    -- that override; preserve the already-persisted challenge identity here.
    if mon.shiny~=nil then clone.shiny=mon.shiny and true or false end
    if mon.isShiny~=nil then clone.isShiny=mon.isShiny and true or false end
    if mon.abilityId~=nil then clone.abilityId=mon.abilityId end
    if mon.abilityName~=nil then clone.abilityName=mon.abilityName end
    out[i]=clone
  end
  return out
end

-- Freeze the only player-mon state Mt. Battle promises must remain identical
-- for the complete 1-100 run. Battle HP/status remain per-battle data, but the
-- selected species and pre-challenge moveset cannot drift after BEGIN CHALLENGE
-- because of a level-up, menu mutation, save reload, or another subsystem.
function LC.snapshotRoster(game,generation,rosterSource,moveOverrides)
  local out={}
  local challengeData=(BattleData and type(BattleData.data)=="function" and BattleData.data(game))
    or (game and game.data)
  for i,entry in ipairs(rosterSource or {}) do
    local detached=entry and (entry.source=="rental" or entry.source=="custom")
    if detached then
      local def=challengeData and challengeData.pokemon and challengeData.pokemon[entry.species]
      local override=type(moveOverrides)=="table" and moveOverrides[i] or nil
      local moveSource=(type(override)=="table" and #override>0) and {moves=override} or entry
      local moves=lockedMoveRows(moveSource)
      local sourceLabel=entry.source=="custom" and "custom" or "rental"
      if not (def and def.baseStats and def.types) then
        return nil,("roster slot "..i.." "..sourceLabel.." species is unavailable")
      end
      if #moves==0 then return nil,("roster slot "..i.." "..sourceLabel.." has no legal moves") end
      out[i]={species=entry.species,moves=moves,level=50,
        rental=entry.source=="rental" or nil,custom=entry.source=="custom" or nil,
        dvs=rentalDVs(entry.species,entry.index or i)}
    else
      local mon=LC.resolveSource(game,generation,entry)
      if not mon then return nil,("roster slot "..i.." could not be resolved for snapshot") end
      if entry and entry.species~=nil and mon.species~=entry.species then
        return nil,("roster slot "..i.." species changed after selection")
      end
      local override=type(moveOverrides)=="table" and moveOverrides[i] or nil
      local moveSource=(type(override)=="table" and #override>0) and {moves=override} or mon
      out[i]={species=mon.species,moves=lockedMoveRows(moveSource)}
    end
  end
  return out
end

-- Resolve a real mon from a rosterSource entry without ever copying it out
-- of the save (SaveState.lua's rosterSource stores indices, not data, for
-- exactly this reason -- see the schema rationale in the plan). Returns the
-- LIVE mon table (do not mutate it; pass it straight to LC.clone).
--   entry: {source="party", index=N} or {source="pc", box=B, slot=N}
function LC.resolveSource(game,generation,entry)
  if not (game and game.save and entry) then return nil end
  local save=game.save
  if entry.source=="party" then
    local party=save.party
    return party and party[entry.index] or nil
  elseif entry.source=="pc" then
    -- Both generations persist occupied storage at save.boxes. Resolving an
    -- OWNED selection is read-only: never initialize/rearrange native storage
    -- or require/open a PC screen just to build a detached challenge snapshot.
    local boxes=save.boxes
    local box=boxes and boxes[entry.box]
    return box and box[entry.slot] or nil
  end
  return nil
end

-- Builds the full six-clone Level 50 battle party from a locked rosterSource.
-- Owned party/PC rows resolve their native object read-only; rental/custom rows
-- are reconstructed only from their immutable rosterSnapshot, so an overworld
-- party change can never replace a detached challenge team on a later fight.
-- Returns: array of clones (same order as rosterSource), or nil+error if
-- any entry fails to resolve (e.g. the source mon was somehow removed --
-- should not happen once a roster is locked, since Mt. Battle never
-- removes party/PC Pokemon, but this is checked rather than assumed).
function LC.playerParty(game,generation,level,data,rosterSource,rosterSnapshot)
  local out={}
  local challengeData=(BattleData and type(BattleData.data)=="function" and BattleData.data(game)) or data
  for i,entry in ipairs(rosterSource or {}) do
    local locked=type(rosterSnapshot)=="table" and rosterSnapshot[i] or nil
    local clone
    local detached=entry and (entry.source=="rental" or entry.source=="custom")
    if detached then
      local markerOk=locked and locked.species and ((entry.source=="rental" and locked.rental)
        or (entry.source=="custom" and locked.custom))
      if not markerOk then
        return nil,("roster slot "..i.." "..tostring(entry.source).." snapshot is missing")
      end
      local dvs=copyDVs(locked.dvs) or rentalDVs(locked.species,entry.index or i)
      if generation==2 then
        local Mon=req("src.pokemon.Pokemon")
        clone=Mon.new(challengeData,locked.species,level,{dvs=dvs,moves=lockedMoveRows(locked)})
      elseif BattleData and type(BattleData.newGen1Mon)=="function" then
        clone=BattleData.newGen1Mon(challengeData,locked.species,level,dvs,lockedMoveRows(locked))
      else
        local Pokemon=req("src.pokemon.Pokemon")
        local seq={dvs.attack,dvs.defense,dvs.speed,dvs.special};local at=0
        local function rng() at=at+1;return seq[at] or 0 end
        local ok,value=pcall(Pokemon.new,challengeData,locked.species,level,rng)
        if ok then clone=value end
      end
      if not clone then return nil,("roster slot "..i.." "..tostring(entry.source).." failed to clone") end
      if entry.source=="rental" then clone.__cbeMtBattleRental=true
      else clone.__cbeMtBattleCustom=true end
    else
      local mon=LC.resolveSource(game,generation,entry)
      if not mon then return nil,("roster slot "..i.." could not be resolved") end
      clone=LC.clone(mon,generation,level,data)
      if not clone then return nil,("roster slot "..i.." failed to clone") end
    end
    if locked then
      if locked.species and clone.species~=locked.species then
        return nil,("roster slot "..i.." species changed after challenge lock")
      end
      clone.moves=lockedMoveRows(locked)
    end
    -- The locked move IDs override Protocol/Mon's generated rows. Restore the
    -- definition-derived capacity AFTER that assignment, not before it. Gen II
    -- Mon.new's maxPp used to disappear here whenever the locked row lacked it.
    for _,mv in ipairs(type(clone.moves)=="table" and clone.moves or {}) do
      if type(mv)=="table" then
        local defs=challengeData and challengeData.moves or {}
        local def=mv.id and (defs[mv.id] or defs[tostring(mv.id)])
        local base=math.max(0,tonumber(def and def.pp) or 0)
        local ups=math.max(0,math.min(3,math.floor(tonumber(mv.ppUps) or 0)))
        local cap=tonumber(mv.maxPp or mv.maxPP)
        if not cap or cap<=0 then cap=base+ups*math.floor(base/5) end
        cap=math.max(0,math.floor(cap),math.floor(tonumber(mv.pp) or 0))
        mv.maxPp=cap
        if mv.maxPP~=nil then mv.maxPP=cap end
        if mv.pp==nil then mv.pp=cap end
      end
    end
    clone.level=level
    clone.__cbeMtBattleLevelLock=true
    out[i]=clone
  end
  return out
end

LC._test={rentalDVs=rentalDVs}

return LC
