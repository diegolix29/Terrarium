-- Mt. Battle 100 deterministic run seeding.
--
-- Algorithm: Park-Miller "minimal standard" LCG (M=2^31-1, a Mersenne
-- prime; A=16807) -- the same well-understood generator
-- src/link/LinkBattle.lua's makeRng uses for cross-machine link-battle
-- determinism, reimplemented here as a small standalone utility since that
-- one is a private closure, not require()able.
--
-- masterSeed is rolled ONCE, at BEGIN CHALLENGE confirmation (never at hub
-- entry, never re-rolled on save/reload/Continue). subSeed(N) is a PURE
-- function of (masterSeed, N) alone: it does not require fights 1..N-1 to
-- have been generated first, so the generator can be driven lazily
-- (one fight ahead of the player) without losing determinism.
local V=... or {}
local SM={}

local M=2147483647 -- 2^31 - 1
local A=16807

-- Lua 5.1 numbers are doubles: masterSeed*A stays exact (<= ~2^45) well
-- within the 2^53 exact-integer range, so plain multiplication + % is
-- safe with no overflow shim needed.
local function lcgStep(seed)
  return (seed*A)%M
end

-- Clamp into the LCG's valid nonzero range [1, M-1]. 0 is a fixed point
-- (stays 0 forever) and must never be used as a seed.
local function normalize(n)
  n=math.floor(math.abs(n or 0))%M
  if n==0 then n=1 end
  return n
end

-- Deterministic sub-seed for fight N: seed the LCG at masterSeed, then
-- advance it exactly N steps. Equivalent to (masterSeed * A^N) mod M,
-- computed by direct iteration -- N is always <= 100 for Mt. Battle, so an
-- O(N) loop is simpler and just as fast as modular exponentiation would be
-- at this scale, with no risk of an exponentiation-shift bug.
function SM.subSeed(masterSeed,fightIndex)
  local seed=normalize(masterSeed)
  local n=math.max(0,math.floor(fightIndex or 0))
  for _=1,n do seed=lcgStep(seed) end
  return seed
end

-- A fresh, independent LCG stream seeded at `seed`. Every RNG draw a single
-- fight's generation makes must come from ONE such stream, consumed in a
-- fixed call order -- generator code must never branch its draw order on
-- unordered pairs() iteration, or two runs with the same seed could diverge.
local Stream={}
Stream.__index=Stream
function SM.newStream(seed)
  return setmetatable({seed=normalize(seed)},Stream)
end
-- Raw next state, advanced in place.
function Stream:nextRaw()
  self.seed=lcgStep(self.seed)
  return self.seed
end
-- Uniform float in [0,1).
function Stream:nextFloat()
  return (self:nextRaw()-1)/(M-1)
end
-- Uniform integer in [lo,hi], inclusive.
function Stream:nextInt(lo,hi)
  lo=math.floor(lo);hi=math.floor(hi)
  if hi<=lo then return lo end
  return lo+math.floor(self:nextFloat()*(hi-lo+1))
end
-- Fisher-Yates-style pick of one element from a non-empty array, without
-- mutating it.
function Stream:pick(list)
  if not list or #list==0 then return nil end
  return list[self:nextInt(1,#list)]
end

-- Rolls a brand-new master seed at BEGIN CHALLENGE confirmation and writes
-- it (plus the advanced runNonce) into save state. Mixes real engine
-- entropy (love.math.random) with wall-clock time and a save-persisted,
-- always-incrementing nonce, so even a reload-and-reconfirm save-scum draws
-- a fresh seed for the WHOLE 100-fight sequence -- there is no way to peek
-- an upcoming fight and reload to reroll just that one, since nothing is
-- rolled per-fight, only once for the entire run.
function SM.roll(game,SaveState)
  SaveState=SaveState or V.MtBattleSaveState
  local s=SaveState.state(game)
  s.runNonce=(s.runNonce or 0)+1
  local entropy=0
  local ok,r=pcall(function()
    if love and love.math and love.math.random then return love.math.random(0,M-1) end
    return nil
  end)
  if ok and type(r)=="number" then entropy=r end
  local wall=0
  local ok2,t=pcall(os.time)
  if ok2 and type(t)=="number" then wall=t end
  -- Simple integer mix (not cryptographic -- this only needs to resist
  -- casual reset-scumming, not adversarial prediction): combine the three
  -- sources with distinct odd multipliers so any one of them changing
  -- changes the result, then fold into the LCG's valid range.
  local mixed=entropy*2654435761 + wall*40503 + s.runNonce*2246822519
  s.masterSeed=normalize(mixed)
  s.active=true
  return s.masterSeed
end

SM.M=M
SM.A=A
SM.normalize=normalize

return SM
