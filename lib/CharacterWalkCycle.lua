-- lib/CharacterWalkCycle.lua
--
-- A procedural, per-vertex walk cycle for the overworld Colosseum
-- trainer/character player models (see PlayerModel.loadColosseumCharacter).
--
-- WHY THIS EXISTS, AND WHY IT ISN'T THE SAME TRICK RED_3D_PLAYER USES:
-- red_3d_player's humanoids (lib/HumanoidRigger.lua, lib/DonorRigCloner.lua)
-- are real bone-rigged skeletons -- every vertex has joint weights, so a
-- walk cycle is just rotating named bones (thigh, knee, shoulder, ...) and
-- the skin follows cleanly. The Colosseum trainer cache this mod loads is a
-- different shape entirely: it comes from Pokemon Colosseum's BATTLE actor
-- data (extract/TrainerExtractor.lua), which only ever needed to stand
-- still and gesture at a wild/trainer opponent -- a battle never moves a
-- trainer around, so nothing in the source game ever authored a walk clip
-- for these models to begin with. What TrainerExtractor bakes out per
-- vertex is a rest pose plus twelve named MORPH TARGETS (gesture1-5,
-- reaction1-5, breath, look -- see lib/TrainerRig.lua's R.mixJointPoint)
-- and a few labelled joint LANDMARK POINTS used only to place a thrown
-- Poke Ball (TrainerRig.lua's R.status(): "proceduralDeformation=false",
-- "purpose=trainer throw/release anchoring"). There is no per-vertex skin
-- weight anywhere in that cache, so there are no bones here to rotate.
--
-- Short of going back into extract/TrainerExtractor.lua and HSD.lua to pull
-- a real joint hierarchy + skin weights out of the source discs (a much
-- bigger job, and Colosseum's battle actors may not even have authored
-- locomotion joints to extract), the only animation surface this module has
-- to work with is the rest-pose vertex positions themselves. So instead of
-- rotating bones, this rotates BUCKETS of vertices -- picked by height and
-- left/right side, reusing the same per-character shoulder-height/width
-- landmarks TrainerRig.profile already exposes for the throw-anchor system
-- -- as a coarse two-joint (hip+knee) leg and one-joint (shoulder) arm
-- swing. It's a heuristic "pseudo-skin", not a real one: a vertex sitting
-- exactly on the seam (inner thigh, armpit, groin) has no blend weight to
-- soften it, only a smoothed-but-still-approximate side/height bucket, so
-- up close it can stretch a little rather than deform the way a properly
-- skinned mesh would. At Terrarium's overworld scale/camera that reads
-- fine in testing; if a particular character's proportions make it look
-- wrong, retune HIP_FRACTION_OF_SHOULDER/KNEE_FRACTION_OF_HIP/SEAM_SOFTEN
-- below rather than the FK math itself.

local V = ...
local TrainerRig = V.require("TrainerRig")

local M = { version = 1 }

-- ------- tuning constants (generic human-ish proportions + gait feel)

-- Hip height as a fraction of the character's own shoulder height
-- (TrainerRig.profile already gives per-character shoulder height as a
-- fraction of total height -- see lib/TrainerRig.lua's PROFILES table).
-- ~0.62 is the ordinary hip/shoulder height ratio for a standing human;
-- it holds up fine even for Terrarium's stockier Cipher-admin models.
local HIP_FRACTION_OF_SHOULDER = 0.62

-- Knee height as a fraction of the way from the ground up to the hip.
local KNEE_FRACTION_OF_HIP = 0.50

-- How far out (as a fraction of the model's own half-width) a vertex has
-- to sit from the centerline before it counts as fully "leg" or "arm"
-- rather than "torso/spine". Vertices between 0 and this fraction fade in
-- smoothly (see smooth01 below) instead of snapping straight to full
-- weight, which is what keeps the crotch and spine from visibly tearing
-- when the two legs/arms swing apart.
local SEAM_SOFTEN = 0.16

-- Lateral distance (as a fraction of half-width) above which a vertex in
-- the hip-to-shoulder height band counts as "arm" rather than "torso".
local ARM_LATERAL_CUTOFF = 0.35

-- Which local axis is "forward" for a step (the other horizontal axis is
-- left the vertex's untouched "side" coordinate). TrainerExtractor centers
-- every model on both X and Z, so a forward/back stride is a rotation in
-- the (up, forward) plane around a pivot on the vertical centerline.
-- extract/TrainerExtractor.lua's normalize keeps X as the left/right split
-- (see PROFILES' halfWidth, which is measured off X) and these battle
-- actors are conventionally built facing along Z, so FORWARD_INDEX=3 (Z)
-- is the expected default. If a character's legs swing side-to-side on
-- screen instead of front-to-back once you test this in-game, that
-- character's source mesh is built facing X instead -- flip this one
-- constant to 1 rather than touching the rotation code below.
local FORWARD_INDEX = 3
local SIDE_INDEX = (FORWARD_INDEX == 3) and 1 or 3

-- Swing amplitudes, in radians. Same idea as red_3d_player's default GAIT
-- curves (main.lua's boneDelta fallback): opposite legs 180 degrees out of
-- phase, the arm on a given side counter-swings that side's own leg, and
-- the knee only really folds on the trailing (recovering) leg.
local HIP_SWING = 0.55
local KNEE_BEND = 0.85
local ARM_SWING = 0.42
local KNEE_LAG = 0.12 -- fraction of a full stride the knee-bend peak lags the hip

-- A small torso bob riding on top of the leg motion, the way a real walk
-- bobs down-and-up once per FOOTFALL (twice per full left/right cycle) --
-- see red_3d_player's own `bounce=0.5-0.5*math.cos(phase*2)` for the same
-- idea applied to its bone rig.
local BOB_AMOUNT = 0.05

local function clamp(v, a, b) if v < a then return a elseif v > b then return b else return v end end
local function smooth01(t) t = clamp(t, 0, 1); return t * t * (3 - 2 * t) end

-- Rotate a (up, forward) pair around a pivot expressed in the same two
-- coordinates. Both legs and the arm use this -- the leg additionally
-- chains a second rotation around the knee's own post-hip-rotation
-- position (see apply() below), which is what keeps the thigh and shin
-- joined instead of the shin rotating around its ORIGINAL, pre-swing spot.
local function rotate2(up, fwd, pivotUp, pivotFwd, angle)
  if angle == 0 then return up, fwd end
  local c, s = math.cos(angle), math.sin(angle)
  local du, df = up - pivotUp, fwd - pivotFwd
  return pivotUp + du * c - df * s, pivotFwd + du * s + df * c
end

-- Build (once, when a character model loads -- see PlayerModel.loadColosseumCharacter)
-- the per-vertex bucket assignment for one character's mesh groups: which
-- limb each vertex belongs to, which side, and how much weight it gets.
-- Cheap and one-shot -- O(total vertex count), never called per frame.
--
-- `groups` is PlayerModel's array of {mesh=, texture=, baseVertices=, baseUVs=}.
-- `bounds` is the trainer cache's own cache.bounds (min/max/center), the
-- same table TrainerRig.profile already reads for the throw-anchor system.
function M.build(id, groups, bounds)
  local prof = TrainerRig.profile(id, bounds)
  local minY = prof.minY
  local hipY = minY + prof.height * prof.shoulder * HIP_FRACTION_OF_SHOULDER
  local shoulderY = minY + prof.height * prof.shoulder
  local kneeY = minY + (hipY - minY) * KNEE_FRACTION_OF_HIP
  local centerSide = (SIDE_INDEX == 1) and prof.centerX or prof.centerZ
  local halfWidth = math.max(prof.halfWidth, 0.001)
  local softenSide = halfWidth * SEAM_SOFTEN

  local rig = {
    hipY = hipY, kneeY = kneeY, shoulderY = shoulderY,
    centerSide = centerSide, groups = {},
  }

  for gi, g in ipairs(groups) do
    local buckets = {}
    local base = g.baseVertices
    if base then
      for vi, v in ipairs(base) do
        local up = v[2]
        local sideCoord = v[SIDE_INDEX]
        local side = (sideCoord >= centerSide) and 1 or -1
        local lateral = smooth01(math.abs(sideCoord - centerSide) / math.max(softenSide, 0.0001))

        local bucket, weight
        if up < hipY then
          bucket = (up < kneeY) and "shin" or "thigh"
          weight = lateral
        elseif up <= shoulderY * 1.02 and lateral > ARM_LATERAL_CUTOFF then
          -- Between hip and shoulder height AND clearly off to one side:
          -- an arm, not the chest/spine (which sits in this same height
          -- band but close to the centerline).
          bucket = "arm"
          weight = lateral
        else
          bucket = "torso"
          weight = 0
        end

        buckets[vi] = { bucket = bucket, side = side, weight = weight }
      end
    end
    rig.groups[gi] = buckets
  end

  return rig
end

-- Advance/decay a smooth 0..1 blend toward `movingNow`, so starting or
-- stopping eases the swing in/out over a few frames instead of snapping --
-- same idea as red_3d_player's startBlendRate/stopBlendRate.
function M.updateBlend(current, movingNow, dt, riseRate, fallRate)
  current = current or 0
  local target = movingNow and 1 or 0
  local rate = movingNow and (riseRate or 10) or (fallRate or 6)
  if current < target then
    current = math.min(target, current + rate * dt)
  elseif current > target then
    current = math.max(target, current - rate * dt)
  end
  return current
end

-- Produce a fresh vertexData array (in Voxel3D.FORMAT order: pos3, uv2,
-- shade1, water1) for one mesh group, at gait `phase` (radians, one full
-- lap = one full left-right-left stride) and swing `blend` (0..1). Written
-- to `out` in place when given, so callers can reuse the same table every
-- frame instead of allocating one per vertex per frame.
function M.apply(rig, groupIndex, group, phase, blend, out)
  out = out or {}
  local buckets = rig.groups[groupIndex]
  local base, uv = group.baseVertices, group.baseUVs
  if not buckets or not base then return out end

  local hipY, kneeY, shoulderY = rig.hipY, rig.kneeY, rig.shoulderY

  -- Both legs' hip-phase and knee-phase sines only ever take one of two
  -- values per frame (the left leg is always exactly half a cycle behind
  -- the right), so compute each pair once here instead of per vertex.
  local hipSinR = math.sin(phase)
  local kneeSinR = math.sin(phase - KNEE_LAG * math.pi * 2)
  local bob = blend * BOB_AMOUNT * (0.5 - 0.5 * math.cos(phase * 2))

  for vi = 1, #base do
    local v = base[vi]
    local side = v[SIDE_INDEX]
    local up = v[2] + bob
    local fwd = v[FORWARD_INDEX]

    local b = buckets[vi]
    if b and b.weight > 0 and blend > 0 then
      local hipSin = (b.side < 0) and -hipSinR or hipSinR
      local hipAngle = HIP_SWING * hipSin * b.weight * blend

      if b.bucket == "arm" then
        -- The arm swings opposite its own side's leg, which is the same
        -- as just negating this side's own hip sine.
        local armAngle = -ARM_SWING * hipSin * b.weight * blend
        up, fwd = rotate2(up, fwd, shoulderY, 0, armAngle)
      elseif b.bucket == "thigh" then
        up, fwd = rotate2(up, fwd, hipY, 0, hipAngle)
      elseif b.bucket == "shin" then
        -- Forward-kinematics chain: rotate the whole leg (this vertex AND
        -- the knee pivot itself) around the hip first, then bend further
        -- around the knee's NEW (already-swung) position -- not its rest
        -- position -- so the shin stays joined to the thigh instead of
        -- rotating around a point the thigh has already left behind.
        local kneeSin = (b.side < 0) and -kneeSinR or kneeSinR
        local kneeAngle = KNEE_BEND * math.max(0, kneeSin) * b.weight * blend
        local kneeUpNow, kneeFwdNow = rotate2(kneeY, 0, hipY, 0, hipAngle)
        up, fwd = rotate2(up, fwd, hipY, 0, hipAngle)
        up, fwd = rotate2(up, fwd, kneeUpNow, kneeFwdNow, kneeAngle)
      end
    end

    -- Reassemble (side, up, fwd) back into (x, y, z) using whichever axis
    -- FORWARD_INDEX/SIDE_INDEX picked -- these are fixed module constants,
    -- not per-vertex, so this is just undoing the split above.
    local ox, oy, oz
    oy = up
    if FORWARD_INDEX == 3 then ox, oz = side, fwd else ox, oz = fwd, side end

    local slot = out[vi]
    local uvv = uv[vi]
    if slot then
      slot[1], slot[2], slot[3] = ox, oy, oz
      slot[4], slot[5] = uvv[1] or 0, uvv[2] or 0
      slot[6], slot[7] = 1.0, 0.0
    else
      out[vi] = { ox, oy, oz, uvv[1] or 0, uvv[2] or 0, 1.0, 0.0 }
    end
  end

  return out
end

return M
