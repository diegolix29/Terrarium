-- Mt. Battle 100 XP Bank: computes each fight's 50% XP share without
-- awarding it (the player's real Pokemon never gain battle levels during
-- the run), accrues it into the locked bank, and -- only after Trainer
-- #100 falls -- distributes it to arbitrary owned Pokemon.
--
-- Reuses the engine's REAL formulas and REAL award functions for every
-- step, verified directly:
--   Gen 1: src/battle/Experience.lua's gainFor (pure) and apply (award).
--   Gen 2: src/battle/gen2/Mon.lua's experienceGain (pure) and
--          gainExperience (award).
-- A synthetic defeatedDef={baseExp=amount, baseStats=all-zero} at level=7,
-- participants=1 makes both pure formulas return exactly `amount`
-- (floor(amount*7/7)==amount, zero stat-exp from all-zero baseStats) --
-- this is the identity that lets bank distribution hand an arbitrary
-- integer to the real award function instead of reimplementing it. Both
-- formulas clamp to a minimum of 1, so a mon allocated 0 must be skipped
-- by the caller, never passed through with amount=0.
local V=... or {}
local req=V.engineRequire or require
local XP={}

local function experience() return req("src.battle.Experience") end
local function gen2Mon() return req("src.battle.gen2.Mon") end
local function runtime() return req("src.mods.Runtime") end

local ZERO_STATS_G1={hp=0,attack=0,defense=0,speed=0,special=0}

-- Real per-defeat share, using the REAL formula against the real defeated
-- species/level -- NOT the identity trick (that's for distribution only).
-- Returns floor(realAmount * 0.5), i.e. the "50% of eligible earned battle
-- XP" the design calls for, per defeated opponent.
--   defeatedDef: game.data.pokemon[species] of the fainted opponent
--   level: 50 (Mt. Battle's fixed level)
--   participants: how many of the player's clones are eligible to have
--     earned this KO (Mt. Battle trainers are always trainer battles)
function XP.computeShare(generation,data,defeatedDef,level,participants)
  local real
  if generation==2 then
    real=gen2Mon().experienceGain(defeatedDef,level,participants,true,{})
  else
    real=experience().gainFor(defeatedDef,level,true,participants,false,data and data.constants)
  end
  return math.floor((real or 0)*0.5)
end

-- Adds `share` (already halved by computeShare) to the bank. Forfeiture is
-- a separate explicit call (XP.forfeit), never implicit -- the bank must
-- never silently drain.
function XP.accrue(game,SaveState,share)
  if not share or share<=0 then return end
  local s=SaveState.state(game)
  s.xpBank=(s.xpBank or 0)+share
end

-- Zeroes the bank on a failed run (0 continues remaining + a loss). No
-- partial payout, ever -- this is the entire point of the bank being
-- locked rather than paid out per-fight.
function XP.forfeit(game,SaveState)
  local s=SaveState.state(game)
  s.xpBank=0
end

-- Scoped, synchronous suppression of Runtime.emit for the duration of
-- `fn()`. Lua/LOVE is single-threaded and this call is synchronous, so
-- swap-call-restore is safe -- the same temporary-monkeypatch-and-restore
-- idiom this codebase already uses elsewhere (e.g. StandaloneHost's
-- native-draw suppression). Used only for the PREVIEW path: a discarded
-- clone must never fire a real pokemon.level_up event (a Pokedex/UI/
-- achievement listener would otherwise react to fake data).
local function withoutEvents(fn)
  local R=runtime()
  local original=R.emit
  R.emit=function() end
  local ok,a,b,c=pcall(fn)
  R.emit=original
  if not ok then error(a,0) end
  return a,b,c
end

-- Deep-copies a plain-data mon table (species/level/exp/stats/moves/etc --
-- no metatables or functions, same assumption Protocol.packMon/unpackMon
-- already make about mon shape).
local function deepCopy(t)
  if type(t)~="table" then return t end
  local out={}
  for k,v in pairs(t) do out[k]=deepCopy(v) end
  return out
end

-- Preview what granting `amount` XP would do to `mon`, with ZERO side
-- effects: no mutation of the real mon, no Runtime events fired. Returns
-- {fromLevel=,toLevel=,fromStats=,toStats=} for a UI like
-- "GROWLITHE Lv.22 -> Lv.37" -- toLevel==fromLevel when amount is too
-- small to gain a level (or was skipped entirely, see the module comment).
function XP.preview(generation,data,mon,amount)
  local fromLevel,fromStats=mon.level,mon.stats
  if not amount or amount<=0 then
    return {fromLevel=fromLevel,toLevel=fromLevel,fromStats=fromStats,toStats=fromStats}
  end
  local clone=deepCopy(mon)
  withoutEvents(function()
    if generation==2 then
      gen2Mon().gainExperience(clone,amount,data)
    else
      local defeatedDef={baseExp=amount,baseStats=ZERO_STATS_G1}
      experience().apply(data,clone,defeatedDef,7,false,1,false)
    end
  end)
  return {fromLevel=fromLevel,toLevel=clone.level,fromStats=fromStats,toStats=clone.stats}
end

-- Actually grants `amount` XP to `mon` for real, through the REAL award
-- path (same function normal battle XP uses), including real
-- pokemon.level_up events and real "moves learnable" prompts. Call only
-- after the player confirms an allocation in the XP Distribution screen.
function XP.commit(generation,data,mon,amount)
  if not amount or amount<=0 then return end
  if generation==2 then
    gen2Mon().gainExperience(mon,amount,data)
  else
    local defeatedDef={baseExp=amount,baseStats=ZERO_STATS_G1}
    experience().apply(data,mon,defeatedDef,7,false,1,false)
  end
end

return XP
