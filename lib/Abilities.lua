-- Ability resolver: dex -> canonical id(s) -> per-individual pick -> display
-- name. No PID/personality value exists anywhere in the supported engines
-- (confirmed during investigation), so dual-ability species pick their slot
-- from a deterministic hash of each mon's own already-persisted dvs/otId --
-- no new save schema, nothing re-rolled on load.
local V=... or {}
local AbilityData=V.AbilityData or error("Abilities.lua requires AbilityData to load first")
local Source=V.ColosseumPokemonMoveData
local A={}

local function prefs(game)
  local owner=game and (game.save and game or (game.game and game.game.save and game.game)
    or (game.host and game.host.save and game.host))
  -- Initialize defaults even before the player has opened the BATTLE menu.
  -- The settings resolver only fills absent values; a saved OFF stays OFF.
  if owner and V.BattleSettings and V.BattleSettings.prefs then
    return V.BattleSettings.prefs(owner)
  end
  return owner and owner.save.colosseumBattle
end

function A.enabled(game)
  local p=prefs(game)
  return p and p.abilitiesEnabled==true
end

-- Simple deterministic polynomial hash over small integers. Deliberately
-- avoids bitwise operators (not in Lua 5.1/LuaJIT without the `bit` library,
-- and this project has previously had to work around LuaJIT-incompatible
-- helpers, so plain arithmetic is the safer default here).
local function mixInto(h, n)
  n=math.floor(tonumber(n) or 0)
  if n<0 then n=-n end
  return (h*31 + n) % 2147483647
end

local function hashMon(mon, dex)
  local h=17
  h=mixInto(h, dex)
  h=mixInto(h, mon and mon.otId)
  local dvs=mon and mon.dvs
  if type(dvs)=="table" then
    h=mixInto(h, dvs.attack)
    h=mixInto(h, dvs.defense)
    h=mixInto(h, dvs.speed)
    h=mixInto(h, dvs.special)
  end
  return h
end

local function sourceAbilityIds(dex)
  local row=Source and Source.species and Source.species[tonumber(dex)]
  local ids=row and row.abilityIds
  if type(ids)~="table" then return nil end
  local out={}
  for _,id in ipairs(ids) do
    id=tonumber(id)
    if id and id>0 then out[#out+1]=id end
  end
  if #out==0 then return nil end
  return out
end

-- Pure: same mon+dex always resolves to the same id. Does not mutate mon.
-- Native 001-251 retain the established table exactly. ColosseumDex species
-- use the ability ids decoded straight from GC6E01 PokemonStats; importantly,
-- the raw slot is selected BEFORE checking whether its mechanic is supported,
-- so an unresolved second ability fails closed instead of silently turning into
-- the species' other implemented ability.
function A.resolve(mon, dex)
  dex=tonumber(dex)
  local options=dex and AbilityData.bySpecies[dex]
  if options and #options>0 then
    if #options==1 then return options[1] end
    local h=hashMon(mon,dex)
    return options[(h%2)+1]
  end
  local raw=sourceAbilityIds(dex)
  if not raw then return nil end
  local slot=1
  if #raw>1 then slot=(hashMon(mon,dex)%#raw)+1 end
  local id=AbilityData.byNumeric and AbilityData.byNumeric[raw[slot]]
  return id and AbilityData.byId[id] and id or nil
end

-- Read-only resolution. Never stamp saved party records: Trace and cached
-- species assignments must not become permanent abilities after save/evolution.
-- Explicit abilities supplied by another mod remain authoritative.
function A.ensure(mon, dex)
  if not mon then return nil end
  local external=mon.abilityId or mon.ability
  if external~=nil then
    return type(external)=="string" and AbilityData.byId[external] and external or nil
  end
  return A.resolve(mon, dex)
end

local states=setmetatable({}, {__mode="k"})
function A.enabledBattle(battle)
  if not battle or battle.link or battle.linkBattle or battle.spectator or battle.demo or battle.safari or battle.ghost or battle.inBattleTowerBattle or battle.tutorial
      or battle.__cbeAbilitiesSuppressed then return false end
  return A.enabled(battle)
end
function A.runtime(battle, mon)
  local state=states[battle]
  if not state then state=setmetatable({}, {__mode="k"});states[battle]=state end
  if not state[mon] then state[mon]={} end
  return state[mon]
end
function A.current(battle, mon, dex)
  if not A.enabledBattle(battle) or not mon then return nil end
  local state=states[battle] and states[battle][mon]
  return (state and state.trace) or A.ensure(mon, dex)
end
function A.reset(battle, mon)
  if not mon then states[battle]=nil
  elseif states[battle] then states[battle][mon]=nil end
end
function A.actives(battle)
  if type(battle.__cbeAbilityActives)=="function" then return battle.__cbeAbilityActives() end
  local out={}
  for _,v in pairs({battle.player,battle.enemy}) do
    local m=v and (v.mon or v)
    if m and (m.hp or 0)>0 then out[#out+1]=v end
  end
  return out
end
function A.random(battle)
  if type(battle.rng)=="function" then return battle.rng(0,65535)/65536 end
  if type(battle.random)=="function" then return battle.random() end
  return math.random()
end
function A.pick(battle,n) return math.min(n,math.floor(A.random(battle)*n)+1) end
function A.maxHP(mon) return math.max(1,mon.maxHp or mon.maxHP or (mon.stats and mon.stats.hp) or mon.hp or 1) end
function A.message(battle,text)
  if type(battle.say)=="function" then battle:say(text)
  elseif type(battle.emit)=="function" then battle:emit({kind="message",text=text}) end
end
function A.types(battle,value)
  local mon=value and (value.mon or value)
  local d=mon and battle.data and battle.data.pokemon and battle.data.pokemon[mon.species]
  return (value and value.curTypes) or (mon and mon.types) or (d and d.types) or {}
end

-- Resolve a live host move back to the authoritative GC6E01 CommonMoveData
-- row without mutating the host definition. Native Gen-I/II definitions carry
-- their cartridge move number in `.index`; source-backed >251 registrations
-- carry `.colosseumMoveId`. This lets ability mechanics such as Soundproof use
-- the retail per-move flags for both native and extended moves instead of a
-- hand-maintained name list.
function A.sourceMoveRow(move)
  if type(move)~="table" then return nil end
  local raw=tonumber(move.colosseumMoveId or move.index)
  if not raw then return nil end
  local row=Source and Source.moves and Source.moves[raw]
  if type(row)~="table" or tonumber(row.rawMoveId)~=raw then return nil end
  return row
end

function A.isSoundMove(move)
  if type(move)~="table" then return false end
  -- Verified >251 registrations cache the exact source bit directly; honor it
  -- even in focused tests where the full source table is intentionally absent.
  if move.colosseumSoundBased~=nil then return move.colosseumSoundBased==true end
  local row=A.sourceMoveRow(move)
  return row~=nil and tonumber(row.soundBased)==1
end
function A.cure(battle,value)
  local mon=value and (value.mon or value); if not mon then return end
  mon.status=nil;mon.statusTurns=nil;mon.toxicCounter=nil
  if value.mon then
    value.toxicCounter=nil;value.sleepTurns=nil
    -- Status penalties are baked into Gen I battler bookkeeping, not saved stats.
    value.statusPenaltyStacks={}
  elseif type(battle.emit)=="function" and type(battle.sideOf)=="function" then
    battle:emit({kind="status",side=battle:sideOf(mon),status=nil,text="The status condition was cured!"})
  end
end

function A.meta(id)
  return id and AbilityData.byId[id]
end

function A.displayName(id)
  local meta=id and AbilityData.byId[id]
  return meta and meta.display or nil
end

function A.speciesOptions(dex)
  dex=tonumber(dex)
  local native=dex and AbilityData.bySpecies[dex]
  if native then return native end
  local raw=sourceAbilityIds(dex)
  if not raw then return nil end
  local out,seen={},{}
  for _,numeric in ipairs(raw) do
    local id=AbilityData.byNumeric and AbilityData.byNumeric[numeric]
    -- UI/catalog surfaces advertise only mechanics this runtime actually owns.
    if id and AbilityData.byId[id] and not seen[id] then seen[id]=true;out[#out+1]=id end
  end
  return #out>0 and out or nil
end

-- Species-level label for contexts with no live mon (Pokedex dossier):
-- single-ability species return that name; dual-ability species join both.
function A.speciesLabel(dex)
  local options=A.speciesOptions(dex)
  if not options or #options==0 then return nil end
  local names={}
  for _,id in ipairs(options) do
    names[#names+1]=A.displayName(id) or id
  end
  return table.concat(names, " / ")
end

function A.isContactMove(moveId,moveDef)
  if type(moveDef)=="table" and type(moveDef.makesContact)=="boolean" then
    return moveDef.makesContact
  end
  return moveId~=nil and AbilityData.contactMoves[moveId]==true
end

function A.dexOf(mon, def)
  if mon and mon.dex and tonumber(mon.dex) then return tonumber(mon.dex) end
  return def and tonumber(def.dex or def.index or def.number) or nil
end

A.data=AbilityData
return A
