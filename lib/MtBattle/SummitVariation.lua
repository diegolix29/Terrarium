-- Deterministic Mt. Battle Summit presentation plan.
--
-- The source D2 crater arena remains one canonical resident scene.  A run gets a
-- tiny presentation table derived from its one master seed: each fight rotates
-- the COMPLETE authored shell as a unit (so lava/mountains/crowd never tear away
-- from their HSD relationships), starts source animation at a deterministic
-- phase, and carries the battle number used by Arena's center decal.  Nothing in
-- this module allocates GPU objects or touches cache identity/payload bytes.
local V=... or {}
local SeedManager=V.MtBattleSeedManager
local SV={VERSION=2,MAX_FIGHTS=100}

local PI=math.pi
-- A challenge fight must never be byte-for-byte/presentation-identical to the
-- untouched Platform 100 establishing view. Keep the range conservative, but
-- rotate the COMPLETE authored D2 shell as one rigid scene. Earlier v1 plans
-- independently translated/rotated broad texture families ("rock", "lava",
-- "crowd"). Some of those same source atlases are also deck/bridge/floor
-- materials, so the transforms literally tore adjacent retail polygons apart and
-- exposed holes in the battlefield. Version 2 removes every relative transform.
local YAW_DEGREES={-12,-9,-6,-3,3,6,9,12}
local M=2147483647
local precomputeCalls=0
local validated=setmetatable({},{__mode="k"})

local function normalizeSeed(seed)
  if SeedManager and type(SeedManager.normalize)=="function" then return SeedManager.normalize(seed) end
  local n=math.floor(math.abs(tonumber(seed) or 0))%M
  return n==0 and 1 or n
end

-- O(1) integer mix.  All intermediates stay below Lua 5.1's exact-integer
-- ceiling, so desktop/mobile produce identical plans without bit libraries.
local function mix(seed,fight,salt)
  local x=(normalizeSeed(seed)+(math.floor(tonumber(fight) or 0)+1)*104729+(salt or 0)*8191)%M
  x=(x*16807)%M
  x=(x+(salt or 0)*65537+math.floor(tonumber(fight) or 0)*4099)%M
  return (x*48271)%M
end

function SV.forFight(masterSeed,fightIndex)
  local fight=math.max(1,math.min(SV.MAX_FIGHTS,math.floor(tonumber(fightIndex) or 1)))
  -- A seed-specific phase plus a step coprime with eight guarantees adjacent
  -- fights cannot land on the same yaw and every eight-fight window visits all
  -- authored-shell orientations once.
  local phase=mix(masterSeed,0,17)%#YAW_DEGREES
  local yawIndex=((phase+(fight-1)*3)%#YAW_DEGREES)+1
  local yawDegrees=YAW_DEGREES[yawIndex]
  local anim=mix(masterSeed,fight,31)%1200
  return {
    version=SV.VERSION,battleNumber=fight,
    yawDegrees=yawDegrees,yaw=yawDegrees*(PI/180),
    animationOffset=anim/60,
  }
end

function SV.precompute(masterSeed,totalFights)
  precomputeCalls=precomputeCalls+1
  local total=math.max(1,math.min(SV.MAX_FIGHTS,math.floor(tonumber(totalFights) or SV.MAX_FIGHTS)))
  local out={}
  for fight=1,total do out[fight]=SV.forFight(masterSeed,fight) end
  return out
end

local function validPlan(plan,fight)
  return type(plan)=="table" and plan.version==SV.VERSION and plan.battleNumber==fight
    and type(plan.yaw)=="number" and type(plan.animationOffset)=="number"
    and plan.rockOffsetX==nil and plan.lavaOffsetX==nil and plan.crowdOffsetX==nil
end

-- Persist the precomputed table in the challenge save so Continue/reload never
-- recomputes presentation state and the renderer only performs table lookups.
function SV.ensure(save,totalFights)
  if type(save)~="table" then return {} end
  local total=math.max(1,math.min(SV.MAX_FIGHTS,math.floor(tonumber(totalFights or save.totalFights) or SV.MAX_FIGHTS)))
  local seed=normalizeSeed(save.masterSeed)
  local plans=save.summitVariations
  local reusable=type(plans)=="table" and save.summitVariationSeed==seed
    and tonumber(save.summitVariationTotal)==total
  local signature=tostring(seed)..":"..tostring(total)..":"..tostring(plans)
  if reusable and validated[save]~=signature then
    for i=1,total do if not validPlan(plans[i],i) then reusable=false;break end end
  end
  if not reusable then
    plans=SV.precompute(seed,total)
    save.summitVariations=plans
    save.summitVariationSeed=seed
    save.summitVariationTotal=total
    signature=tostring(seed)..":"..tostring(total)..":"..tostring(plans)
  end
  validated[save]=signature
  return plans
end

function SV.forSave(save,fightIndex)
  if type(save)~="table" then return nil end
  local maxFight=math.max(1,math.min(SV.MAX_FIGHTS,math.floor(tonumber(save.totalFights) or SV.MAX_FIGHTS)))
  local fight=math.max(1,math.min(maxFight,math.floor(tonumber(fightIndex or save.currentFight) or 1)))
  local plans=SV.ensure(save,save.totalFights)
  return plans[fight]
end

SV.YAW_DEGREES=YAW_DEGREES
SV._test={mix=mix,validPlan=validPlan,precomputeCalls=function() return precomputeCalls end}
return SV
