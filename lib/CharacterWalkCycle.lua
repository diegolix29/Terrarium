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
-- Native locomotion tracks were tried: they dropped feet and corrupted other
-- clips' lower body, so they stay unextracted. Overworld walking instead
-- overlays this gait on the live idle/victory pose PlayerModel samples each
-- frame (see CharacterNativeAnim.sample / copyPositions), so Wes keeps his
-- victory body language while only arms/hands and legs/feet stride.
--
-- Wes is the reference gait (shared HIP_SWING / timing). Painted limb
-- membership for each trainer lives in lib/walk_membership/<id>.lua and is
-- applied in M.build as the walk overlay only -- never into model_cache or
-- native_v1. A cache walk_overrides.lua, if present, can still patch on top.

local V = ...
local TrainerRig = V.require("TrainerRig")
local GeneratedAssets = V.require("GeneratedAssets")

local M = { version = 10 }

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
local SEAM_SOFTEN = 0.22

-- Gait half-width fractions. Spine/ribs stay idle; feet sit closer to the
-- centerline than sleeves. Arms below the hip must be farther out than a
-- thigh or the hip itself is stolen as a left/right arm.
local ARM_LATERAL_CUTOFF = 0.42
local ARM_BELOW_HIP_CUTOFF = 0.58
local LEG_LATERAL_CUTOFF = 0.12
local FOOT_LATERAL_CUTOFF = 0.03

-- Height (as a fraction of the hip) above which a "leg" vertex is treated
-- as pelvis/hip mesh and left on the idle pose. Long coats and hanging
-- hair that dip into the thigh band are rejected separately as "back".
local HIP_LOCK_FRACTION = 0.86

-- Prefer a torso/head/hip joint over a limb joint unless the limb is
-- clearly closer. Only used to pick thigh vs shin vs arm, not to drop a
-- limb the geometry already accepted (that froze the trailing leg/arm).
local LOCK_BIAS = 1.18

-- Stop walking up a foot's parent chain once the joint is this high
-- (fraction of model height). Keeps the pelvis/spine out of the leg set.
local LEG_CHAIN_MAX_NY = 0.46

-- Stop walking up a hand's parent chain once the joint is this close to
-- the centerline (fraction of model height). Keeps clavicle/chest idle.
local ARM_CHAIN_MIN_LAT = 0.11

-- Rest-pose hands hang near mid-thigh on most Colosseum trainers. Joint
-- walk-up and the no-parent fallback must still treat that band as arm,
-- not as a second pair of legs.
local ARM_CHAIN_MIN_NY = 0.20

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

-- Swing amplitudes, in radians. Overlay sits on an already-posed idle clip,
-- so keep the stride small and the sine a little rounded at the peaks.
local HIP_SWING = 0.2
local KNEE_BEND = 5
local ARM_SWING = 0.4
-- Legs and arms do not share a front bias. (hipSin - LEG_FRONT) is what
-- finally plants the step ahead of the body; using that same term on the
-- arms yanked them into a backstroke/climbing pose. Arms keep the opposite
-- bias so they still reach forward while the same-side leg does.
local LEG_FRONT = -0.65
local ARM_FRONT = -0.80

-- A small torso bob riding on top of the leg motion, the way a real walk
-- bobs down-and-up once per FOOTFALL (twice per full left/right cycle) --
-- see red_3d_player's own `bounce=0.5-0.5*math.cos(phase*2)` for the same
-- idea applied to its bone rig.
local BOB_AMOUNT = 0.3

-- ------- jump pose tuning (see M.applyJump below)
--
-- A manual hop (main.lua's JUMP key, thrown when it isn't crossing a real
-- ledge) is one clean up/down arc rather than a repeating stride, so it
-- doesn't have a "phase" to loop the way HIP_SWING/KNEE_BEND above do --
-- just a single 0 (takeoff) .. 1 (landing) progress. JUMP_HIP_MAX/
-- JUMP_KNEE_MAX/JUMP_ARM_MAX are the pose at full airborne tuck (progress
-- 0.5); JUMP_LOAD_FRAC/JUMP_SETTLE_FRAC are how much of the jump, at each
-- end, is spent easing into/out of a shallower JUMP_CROUCH_FRAC anticipation
-- crouch before the legs pull all the way up. Same "retune the constant,
-- not the FK math" note as HIP_FRACTION_OF_SHOULDER etc. above applies here.
local JUMP_LOAD_FRAC = 0.18    -- fraction of the jump spent easing into the windup crouch
local JUMP_SETTLE_FRAC = 0.18  -- fraction spent easing out of the landing crouch
local JUMP_CROUCH_FRAC = 0.30  -- windup/landing crouch depth, as a fraction of full tuck
local JUMP_HIP_MAX = 0.35      -- hip flexion (radians) at full airborne tuck
local JUMP_KNEE_MAX = 1.10     -- knee bend (radians) at full airborne tuck -- deeper than
                                -- KNEE_BEND since a hop tucks both feet up, not one recovering leg
local JUMP_ARM_MAX = 0.50      -- arm swing (radians), back and away from the tucked legs

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

local function dist2pt(x, y, z, p)
  if not p then return math.huge end
  local dx = x - (p[1] or 0)
  local dy = y - (p[2] or 0)
  local dz = z - (p[3] or 0)
  return dx * dx + dy * dy + dz * dz
end

local function centroidRange(pts, a, b)
  local sx, sy, sz, n = 0, 0, 0, 0
  for i = a, b do
    local p = pts[i]
    sx = sx + (p[1] or 0)
    sy = sy + (p[2] or 0)
    sz = sz + (p[3] or 0)
    n = n + 1
  end
  if n == 0 then return nil end
  return { sx / n, sy / n, sz / n }
end

-- Two shoe clusters and two sleeve/hand clusters from the rest mesh.
-- Membership is "nearest shoe / nearest hand", not a world centerline cut,
-- so a trailing stance leg and a tucked or hanging arm still walk.
local function collectAnchors(groups, minY, height, hipY, shoulderY)
  local footLimit = minY + height * 0.15
  local sleeveLo, sleeveHi = hipY * 1.04, shoulderY * 0.92
  local tipLo, tipHi = hipY * 0.55, hipY * 1.08
  local sleeveLat = height * 0.13
  local tipLat = height * 0.20
  local feet, hands = {}, {}
  for _, g in ipairs(groups or {}) do
    local base = g.baseVertices
    if base then
      for i = 1, #base do
        local v = base[i]
        local y = v[2] or 0
        local ax = math.abs(v[1] or 0)
        if y <= footLimit then
          feet[#feet + 1] = v
        elseif y >= sleeveLo and y <= sleeveHi and ax > sleeveLat then
          hands[#hands + 1] = v
        elseif y >= tipLo and y <= tipHi and ax > tipLat then
          hands[#hands + 1] = v
        end
      end
    end
  end
  local function splitByX(pts)
    if #pts < 4 then return nil, nil end
    table.sort(pts, function(a, b) return (a[1] or 0) < (b[1] or 0) end)
    local n = #pts
    local loN = math.max(1, math.floor(n * 0.40))
    local hi0 = math.max(loN + 1, math.floor(n * 0.60) + 1)
    return centroidRange(pts, 1, loN), centroidRange(pts, hi0, n)
  end
  local function splitHands(pts)
    if #pts < 4 then return nil, nil end
    table.sort(pts, function(a, b) return (a[1] or 0) < (b[1] or 0) end)
    local n = #pts
    local q = math.max(2, math.floor(n * 0.22))
    return centroidRange(pts, 1, q), centroidRange(pts, n - q + 1, n)
  end
  local fL, fR = splitByX(feet)
  local hL, hR = splitHands(hands)
  return fL, fR, hL, hR
end

-- Which way the rest pose faces, from the feet vs the body center. Coat
-- tails and hanging hair sit on the opposite side of that axis and must
-- not inherit the leg swing just because they overlap the thigh height band.
local function facingSign(groups, bounds, minY, height, centerFwd)
  local footSum, footN = 0, 0
  local limit = minY + height * 0.10
  for _, g in ipairs(groups or {}) do
    local base = g.baseVertices
    if base then
      for i = 1, #base do
        local v = base[i]
        if (v[2] or 0) <= limit then
          footSum = footSum + (v[FORWARD_INDEX] or 0)
          footN = footN + 1
        end
      end
    end
  end
  if footN == 0 then return 1, centerFwd end
  local footFwd = footSum / footN
  local sign = (footFwd >= centerFwd) and 1 or -1
  return sign, footFwd
end

-- Label rest-pose HSD joints (model_cache.jointPositions / native_v1 index
-- roles[role].joints[1]) as arm, thigh, shin, or lock. Parent-chain walk
-- from the lowest joint per side (foot) and the most lateral upper-body
-- joint per side (hand) so pelvis, spine, chest, neck, and hair joints
-- stay locked. Constructed native clips already move the right vertices;
-- this is only a membership mask for the procedural overlay.
local function classifyJoints(positions, parents, bounds, minY, height, centerX)
  local n = type(positions) == "table" and #positions or 0
  if n < 4 then return nil end
  parents = type(parents) == "table" and parents or {}
  local children = {}
  for i = 1, n do children[i] = {} end
  for i = 1, n do
    local p = math.floor(tonumber(parents[i]) or 0)
    if p >= 1 and p <= n then
      children[p][#children[p] + 1] = i
    end
  end

  local function ny(i)
    local p = positions[i]
    return (((p and p[2]) or 0) - minY) / height
  end
  local function lat(i)
    local p = positions[i]
    return math.abs(((p and p[1]) or 0) - centerX) / height
  end
  local function sideOf(i)
    local p = positions[i]
    return (((p and p[1]) or 0) >= centerX) and 1 or -1
  end

  local foot, footY = { [-1] = nil, [1] = nil }, { [-1] = math.huge, [1] = math.huge }
  local hand, handScore = { [-1] = nil, [1] = nil }, { [-1] = -1, [1] = -1 }
  for i = 1, n do
    if type(positions[i]) == "table" then
      local s = sideOf(i)
      local y = positions[i][2] or 0
      if y < footY[s] then footY[s] = y; foot[s] = i end
      local h = ny(i)
      -- Wrist/palm, not hip. Hip JOBJs sit near 0.40 height with modest
      -- lateral and used to win this score, painting both thighs as arms.
      if h > 0.48 and h < 0.94 and lat(i) > 0.14 then
        local sc = lat(i) * 2.6 + (1 - math.abs(h - 0.68)) * 0.35
        if sc > handScore[s] then handScore[s] = sc; hand[s] = i end
      end
    end
  end

  local kind = {}
  for i = 1, n do kind[i] = "lock" end
  local parentCount = 0
  for i = 1, n do
    if (tonumber(parents[i]) or 0) > 0 then parentCount = parentCount + 1 end
  end

  -- Mark only the parent chain first. Never tag the root/pelvis/spine:
  -- those sit on the centerline (or branch to both legs AND the torso).
  -- Flooding from a ground-level root painted the whole actor as a leg,
  -- so the idle torso/head split into opposite gait phases.
  local kneeNy = LEG_CHAIN_MAX_NY * KNEE_FRACTION_OF_HIP
  local function isSpine(j)
    -- Centerline only. A thigh JOBJ with extra helper children is still a
    -- leg -- treating "3 children" as spine froze one side's chain.
    return lat(j) < 0.07
  end
  for _, s in ipairs({ -1, 1 }) do
    local j, guard = foot[s], 0
    while j and j >= 1 and j <= n and guard < 64 do
      guard = guard + 1
      if ny(j) >= LEG_CHAIN_MAX_NY or isSpine(j) then break end
      kind[j] = (ny(j) < kneeNy) and "shin" or "thigh"
      j = math.floor(tonumber(parents[j]) or 0)
    end
    j, guard = hand[s], 0
    while j and j >= 1 and j <= n and guard < 64 do
      guard = guard + 1
      if lat(j) < ARM_CHAIN_MIN_LAT or ny(j) < ARM_CHAIN_MIN_NY or isSpine(j) then break end
      kind[j] = "arm"
      j = math.floor(tonumber(parents[j]) or 0)
    end
  end

  local function flood(j, label, guard)
    local kids = children[j]
    if not kids or guard > 48 then return end
    for k = 1, #kids do
      local c = kids[k]
      if kind[c] == "lock" and not isSpine(c) then
        kind[c] = label
        flood(c, label, guard + 1)
      end
    end
  end
  for i = 1, n do
    if kind[i] ~= "lock" then flood(i, kind[i], 0) end
  end

  -- Caches without jointParents: classify each joint by rest pose alone.
  if parentCount < n * 0.5 then
    for i = 1, n do
      if type(positions[i]) == "table" then
        local h, l = ny(i), lat(i)
        if h < LEG_CHAIN_MAX_NY and l > 0.05 then
          kind[i] = (h < kneeNy) and "shin" or "thigh"
        elseif h > 0.50 and h < 0.96 and l > ARM_CHAIN_MIN_LAT then
          kind[i] = "arm"
        else
          kind[i] = "lock"
        end
      end
    end
  end

  local limb, lock = {}, {}
  local hipSum, hipN, kneeSum, kneeN, shSum, shN = 0, 0, 0, 0, 0, 0
  for i = 1, n do
    local p = positions[i]
    if type(p) == "table" then
      local row = { p = p, k = kind[i], side = sideOf(i) }
      if kind[i] == "lock" then
        lock[#lock + 1] = row
      else
        limb[#limb + 1] = row
        local y = p[2] or 0
        if kind[i] == "thigh" then hipSum = hipSum + y; hipN = hipN + 1
        elseif kind[i] == "shin" then kneeSum = kneeSum + y; kneeN = kneeN + 1
        else shSum = shSum + y; shN = shN + 1 end
      end
    end
  end
  if #limb == 0 then return nil end
  return {
    limb = limb, lock = lock,
    hipY = hipN > 0 and (hipSum / hipN) or nil,
    kneeY = kneeN > 0 and (kneeSum / kneeN) or nil,
    shoulderY = shN > 0 and (shSum / shN) or nil,
  }
end

local function bindNearest(vx, vy, vz, classified)
  local bestLimb, bestLimbD, bestLockD = nil, math.huge, math.huge
  local limb, lock = classified.limb, classified.lock
  for i = 1, #limb do
    local d = dist2pt(vx, vy, vz, limb[i].p)
    if d < bestLimbD then bestLimbD = d; bestLimb = limb[i] end
  end
  for i = 1, #lock do
    local d = dist2pt(vx, vy, vz, lock[i].p)
    if d < bestLockD then bestLockD = d end
  end
  if not bestLimb then return "torso", 0, 1 end
  -- Hair, back, and hip verts sit closer to lock joints than to a wrist
  -- or ankle. Bias lock so a tie (armpit, inner thigh, scalp) stays idle.
  if bestLockD <= bestLimbD * LOCK_BIAS then
    return "torso", 0, bestLimb.side
  end
  local ratio = math.sqrt(bestLockD) / (math.sqrt(bestLimbD) + 1e-8)
  local weight = smooth01((ratio - LOCK_BIAS) / 0.70)
  return bestLimb.k, weight, bestLimb.side
end

-- Height/side membership. Prefer nearest shoe / nearest sleeve or hanging
-- hand so both legs and both arms (including fingers) walk even when the
-- rest pose is a stance with arms down.
local function geometricBucket(up, vx, vz, fwd, hipY, kneeY, shoulderY, minY, height, centerSide, halfWidth, faceSign, centerFwd, footL, footR, handL, handR)
  local side = (vx >= centerSide) and 1 or -1
  local behind = ((fwd - centerFwd) * faceSign) < -(halfWidth * 0.12)
  local footTop = minY + height * 0.18

  if up >= shoulderY * 0.90 then
    return "torso", 0, side
  end
  if behind and up >= hipY then
    return "torso", 0, side
  end

  local dFoot = math.huge
  if footL and footR then
    local dFL = dist2pt(vx, up, vz, footL)
    local dFR = dist2pt(vx, up, vz, footR)
    dFoot = (dFL <= dFR) and dFL or dFR
  end
  local sideFrac = math.abs(vx - centerSide) / math.max(halfWidth, 0.0001)

  -- Legs first below the hip. Hanging fingers still win when they sit
  -- farther out than a thigh and much closer to a hand than a shoe.
  if footL and footR and up < hipY then
    local dL = dist2pt(vx, up, vz, footL)
    local dR = dist2pt(vx, up, vz, footR)
    side = (dL <= dR) and -1 or 1
    local dHip = dist2pt(vx, up, vz, {
      ((footL[1] or 0) + (footR[1] or 0)) * 0.5,
      hipY,
      ((footL[3] or 0) + (footR[3] or 0)) * 0.5,
    })
    if handL and handR and sideFrac > ARM_BELOW_HIP_CUTOFF and up > footTop then
      local dHL = dist2pt(vx, up, vz, handL)
      local dHR = dist2pt(vx, up, vz, handR)
      local dHand = (dHL <= dHR) and dHL or dHR
      if dHand * 1.35 < dFoot then
        return "arm", 1, (dHL <= dHR) and -1 or 1
      end
    end
    if up <= footTop then
      return "shin", 1, side
    end
    if up >= hipY * HIP_LOCK_FRACTION and dHip <= dFoot then
      return "torso", 0, side
    end
    if dFoot <= dHip * 1.25 or up < kneeY then
      return (up < kneeY) and "shin" or "thigh", 1, side
    end
  end

  if handL and handR and up >= hipY and up < shoulderY * 0.98 and sideFrac > ARM_LATERAL_CUTOFF then
    local dL = dist2pt(vx, up, vz, handL)
    local dR = dist2pt(vx, up, vz, handR)
    local handSide = (dL <= dR) and -1 or 1
    local dHand = (dL <= dR) and dL or dR
    local chest = {
      ((handL[1] or 0) + (handR[1] or 0)) * 0.5,
      ((handL[2] or 0) + (handR[2] or 0)) * 0.5,
      ((handL[3] or 0) + (handR[3] or 0)) * 0.5,
    }
    local dChest = dist2pt(vx, up, vz, chest)
    if dHand * 1.12 < dChest then
      return "arm", 1, handSide
    end
  end

  return "torso", 0, side
end

-- Any sole vert that sat just inside the cutoff still inherits the nearest
-- swinging shoe instead of stretching off the mesh.
local function stitchFeet(groups, rig, kneeY, minY, height, halfWidth)
  local radius = halfWidth * 0.38
  local r2 = radius * radius
  local footTop = minY + height * 0.18
  for gi, g in ipairs(groups or {}) do
    local base = g.baseVertices
    local buckets = rig.groups[gi]
    if base and buckets then
      local seeds = {}
      for vi = 1, #base do
        local b = buckets[vi]
        if b and (b.bucket == "shin" or b.bucket == "thigh") and (b.weight or 0) > 0.4 then
          local v = base[vi]
          if (v[2] or 0) <= footTop then
            seeds[#seeds + 1] = { v[1] or 0, v[2] or 0, v[3] or 0, b.side, b.bucket }
          end
        end
      end
      if #seeds > 0 then
        for vi = 1, #base do
          local b = buckets[vi]
          local v = base[vi]
          local up = v[2] or 0
          if b and (not b.weight or b.weight <= 0 or b.bucket == "torso") and up <= footTop then
            local bx, by, bz = v[1] or 0, up, v[3] or 0
            local best, bestD = nil, r2
            for s = 1, #seeds do
              local p = seeds[s]
              local dx, dy, dz = bx - p[1], by - p[2], bz - p[3]
              local d = dx * dx + dy * dy + dz * dz
              if d < bestD then bestD = d; best = p end
            end
            if best then
              buckets[vi] = { bucket = "shin", side = best[4], weight = 1 }
            end
          end
        end
      end
    end
  end
end

-- Palms and fingers sit past the sleeve cluster. Grow arm membership from
-- already-tagged arm verts so a hanging hand is not left on the idle pose.
local function stitchHands(groups, rig, minY, height, halfWidth, hipY)
  local radius = halfWidth * 0.28
  local r2 = radius * radius
  local lo = hipY * 1.02
  local hi = minY + height * 0.92
  local minLat = halfWidth * ARM_LATERAL_CUTOFF
  for gi, g in ipairs(groups or {}) do
    local base = g.baseVertices
    local buckets = rig.groups[gi]
    if base and buckets then
      local seeds = {}
      for vi = 1, #base do
        local b = buckets[vi]
        if b and b.bucket == "arm" and (b.weight or 0) > 0.4 then
          local v = base[vi]
          local y = v[2] or 0
          if y >= lo and y <= hi then
            seeds[#seeds + 1] = { v[1] or 0, y, v[3] or 0, b.side }
          end
        end
      end
      if #seeds > 0 then
        for vi = 1, #base do
          local b = buckets[vi]
          local v = base[vi]
          local up = v[2] or 0
          if b and up >= lo and up <= hi
             and math.abs(v[1] or 0) >= minLat
             and (not b.weight or b.weight <= 0 or b.bucket == "torso") then
            local bx, by, bz = v[1] or 0, up, v[3] or 0
            local best, bestD = nil, r2
            for s = 1, #seeds do
              local p = seeds[s]
              local dx, dy, dz = bx - p[1], by - p[2], bz - p[3]
              local d = dx * dx + dy * dy + dz * dz
              if d < bestD then bestD = d; best = p end
            end
            if best then
              buckets[vi] = { bucket = "arm", side = best[4], weight = 1 }
            end
          end
        end
      end
    end
  end
end

-- Split left/right from the actual shoes so a slightly off-center rest
-- pose does not dump one whole leg on the spine side of centerX.
local function footSplitX(groups, minY, height, fallback)
  local acc = { [-1] = 0, [1] = 0 }
  local n = { [-1] = 0, [1] = 0 }
  local limit = minY + height * 0.12
  for _, g in ipairs(groups or {}) do
    local base = g.baseVertices
    if base then
      for i = 1, #base do
        local v = base[i]
        if (v[2] or 0) <= limit then
          local x = v[SIDE_INDEX] or 0
          local s = (x >= fallback) and 1 or -1
          acc[s] = acc[s] + x
          n[s] = n[s] + 1
        end
      end
    end
  end
  if n[-1] > 0 and n[1] > 0 then
    return 0.5 * (acc[-1] / n[-1] + acc[1] / n[1])
  end
  return fallback
end

-- One physical leg must share one gait phase. Nearest-foot side wins so a
-- shin cannot stride opposite its own thigh.
local function unifyLegSides(groups, rig, footL, footR)
  if not (footL and footR and rig and rig.groups) then return end
  for gi, g in ipairs(groups or {}) do
    local base = g.baseVertices
    local buckets = rig.groups[gi]
    if base and buckets then
      for vi = 1, #base do
        local b = buckets[vi]
        if b and (b.bucket == "thigh" or b.bucket == "shin") then
          local v = base[vi]
          local dL = dist2pt(v[1] or 0, v[2] or 0, v[3] or 0, footL)
          local dR = dist2pt(v[1] or 0, v[2] or 0, v[3] or 0, footR)
          b.side = (dL <= dR) and -1 or 1
        end
      end
    end
  end
end

-- Build (once, when a character model loads -- see PlayerModel.loadColosseumCharacter)
-- the per-vertex bucket assignment for one character's mesh groups: which
-- limb each vertex belongs to, which side, and how much weight it gets.
-- Cheap and one-shot -- O(total vertex count), never called per frame.
--
-- `groups` is PlayerModel's array of {mesh=, texture=, baseVertices=, baseUVs=}.
-- `bounds` is the trainer cache's own cache.bounds (min/max/center), the
-- same table TrainerRig.profile already reads for the throw-anchor system.
-- `skeleton`, when given, is { jointPositions=, jointParents= } from
-- model_cache.lua (rest pose). native_v1/index.lua stores the same joint
-- coordinates per clip frame under roles[role].joints -- those authored
-- tracks already skin arms/legs correctly; we only use rest joints here
-- so the walk overlay does not swing torso, hip, back, or hair verts.
function M.build(id, groups, bounds, skeleton)
  local prof = TrainerRig.profile(id, bounds)
  local minY = prof.minY
  local hipY = minY + prof.height * prof.shoulder * HIP_FRACTION_OF_SHOULDER
  local shoulderY = minY + prof.height * prof.shoulder
  local kneeY = minY + (hipY - minY) * KNEE_FRACTION_OF_HIP
  local centerSide = (SIDE_INDEX == 1) and prof.centerX or prof.centerZ
  local centerFwd = (FORWARD_INDEX == 3) and prof.centerZ or prof.centerX
  if SIDE_INDEX == 1 then
    centerSide = footSplitX(groups, minY, prof.height, centerSide)
  end
  local halfWidth = math.max(prof.halfWidth, 0.001)
  local faceSign, footFwd = facingSign(groups, bounds, minY, prof.height, centerFwd)
  local footL, footR, handL, handR = collectAnchors(groups, minY, prof.height, hipY, shoulderY)

  local classified = nil
  local joints = skeleton and skeleton.jointPositions
  if (not joints or #joints == 0) and skeleton and skeleton.joints then
    joints = skeleton.joints
  end
  if type(joints) == "table" and #joints > 0 then
    classified = classifyJoints(joints, skeleton.jointParents, bounds, minY, prof.height, centerSide)
  end
  -- Pivots stay on the authored shoulder/hip profile. Joint averages were
  -- pulled toward the spine when a root joint got tagged as a leg.
  local rig = {
    hipY = hipY, kneeY = kneeY, shoulderY = shoulderY,
    centerSide = centerSide, version = M.version, groups = {},
    -- Pendulum origin between the body and the rest-pose shoes so a stride
    -- can swing past the hip plane. Pivoting at fwd=0 made "forward" look
    -- like a lift back to idle, and only the back half read as a step.
    strideSign = faceSign or 1,
    stridePivotFwd = 2 * ((footFwd or centerFwd) + centerFwd),
  }

  for gi, g in ipairs(groups) do
    local buckets = {}
    local base = g.baseVertices
    if base then
      for vi, v in ipairs(base) do
        local up = v[2] or 0
        local vx, vz = v[1] or 0, v[3] or 0
        local fwd = v[FORWARD_INDEX] or 0
        local bucket, weight, side = geometricBucket(
          up, vx, vz, fwd, hipY, kneeY, shoulderY, minY, prof.height,
          centerSide, halfWidth, faceSign, centerFwd, footL, footR, handL, handR
        )
        -- Joints may promote a missed hanging hand. They must not retag
        -- thigh as shin (or the reverse): that moves the FK seam off the
        -- knee and the two halves of one leg swing independently.
        if classified then
          local jBucket, jWeight, jSide = bindNearest(vx, up, vz, classified)
          if bucket == "arm" then
            if jSide then side = jSide end
            if jBucket == "arm" and jWeight and jWeight > 0 then
              weight = math.max(weight, jWeight)
            end
          elseif bucket == "thigh" or bucket == "shin" then
            -- keep geometric segment; side is unified from the feet below
          elseif jBucket == "arm" and jWeight and jWeight > 0.25
             and (up >= hipY * 0.98 or math.abs(vx - centerSide) > halfWidth * ARM_BELOW_HIP_CUTOFF) then
            bucket, weight, side = "arm", jWeight, jSide or side
          end
        end
        buckets[vi] = { bucket = bucket, side = side, weight = weight or 0 }
      end
    end
    rig.groups[gi] = buckets
  end
  stitchFeet(groups, rig, kneeY, minY, prof.height, halfWidth)
  stitchHands(groups, rig, minY, prof.height, halfWidth, hipY)
  unifyLegSides(groups, rig, footL, footR)

  return rig
end

function M.overridePath(id)
  return ("cache/trainers/%s/walk_overrides.lua"):format(tostring(id or ""))
end

local function isWalkOverlayPath(path)
  path = tostring(path or "")
  return path:find("walk_overrides%.lua", 1, true) ~= nil
      or path:find("walk_debug%.txt", 1, true) ~= nil
end

local function overrideGroups(raw)
  if type(raw) ~= "table" then return nil end
  if type(raw.groups) == "table" then return raw.groups end
  return raw
end

function M.applyOverrideTable(rig, raw)
  if not (rig and rig.groups) then return 0 end
  local groups = overrideGroups(raw)
  if not groups then return 0 end
  local applied = 0
  for groupIdx, groupOverrides in pairs(groups) do
    local gi = tonumber(groupIdx) or groupIdx
    if rig.groups[gi] and type(groupOverrides) == "table" then
      for vertexIdx, override in pairs(groupOverrides) do
        local vi = tonumber(vertexIdx) or vertexIdx
        local bucket = rig.groups[gi][vi]
        if bucket and type(override) == "table" then
          if override.bucket then bucket.bucket = override.bucket end
          if override.weight then bucket.weight = override.weight end
          if override.side then bucket.side = override.side end
          applied = applied + 1
        end
      end
    end
  end
  return applied
end

function M.bundledPath(id)
  return ("lib/walk_membership/%s.lua"):format(tostring(id or ""))
end

function M.loadBundled(id)
  if not id or id == "" then return nil end
  if not (GeneratedAssets and GeneratedAssets.packageLua) then return nil end
  local raw = select(1, GeneratedAssets.packageLua(M.bundledPath(id)))
  if type(raw) == "table" then return raw end
  return nil
end

function M.applyFromCache(rig, id)
  if not id or id == "" then return 0 end
  local n = 0
  local bundled = M.loadBundled(id)
  if bundled then
    n = n + M.applyOverrideTable(rig, bundled)
  end
  local path = M.overridePath(id)
  local extra = GeneratedAssets and GeneratedAssets.readLua and select(1, GeneratedAssets.readLua(path))
  if type(extra) == "table" then
    n = n + M.applyOverrideTable(rig, extra)
  end
  if n > 0 then
    print("CharacterWalkCycle: applied " .. n .. " painted verts for " .. tostring(id))
  end
  return n
end

function M.encodeOverrides(rig)
  local chunks = {
    "-- DRAMATIC_SHAPE walk overlay membership only.\n",
    "-- Do not treat this as model_cache or native_v1; idle/victory stay extracted.\n",
    "return {version=1,purpose=\"walk-overlay\",groups={\n",
  }
  for gi, buckets in ipairs(rig.groups or {}) do
    chunks[#chunks + 1] = "[" .. gi .. "]={"
    local first = true
    for vi, b in pairs(buckets or {}) do
      if type(b) == "table" and type(vi) == "number" then
        if not first then chunks[#chunks + 1] = "," end
        first = false
        chunks[#chunks + 1] = string.format(
          "[%d]={bucket=%q,side=%s,weight=%.3f}",
          vi, tostring(b.bucket or "torso"), tostring(b.side or 1), tonumber(b.weight) or 0
        )
      end
    end
    chunks[#chunks + 1] = "},\n"
  end
  chunks[#chunks + 1] = "}}\n"
  return table.concat(chunks)
end

function M.writeOverrides(id, rig)
  if not (GeneratedAssets and GeneratedAssets.write) then return false, "cache writer unavailable" end
  local path = M.overridePath(id)
  if not isWalkOverlayPath(path) then return false, "refusing non-overlay write" end
  local body = M.encodeOverrides(rig)
  return GeneratedAssets.write(path, body)
end

function M.debugPath(id)
  return ("cache/trainers/%s/walk_debug.txt"):format(tostring(id or ""))
end

function M.encodeDebug(id, groups, rig)
  local lines = {
    "# walk_debug v1 id=" .. tostring(id or ""),
    "# gi vi x y z bucket side weight",
  }
  for gi, g in ipairs(groups or {}) do
    local base = g.baseVertices
    local buckets = rig and rig.groups and rig.groups[gi]
    if base then
      for vi = 1, #base do
        local v = base[vi]
        local b = buckets and buckets[vi]
        lines[#lines + 1] = string.format(
          "%d %d %.5f %.5f %.5f %s %s %.3f",
          gi, vi, v[1] or 0, v[2] or 0, v[3] or 0,
          (b and b.bucket) or "torso", tostring((b and b.side) or 1),
          tonumber(b and b.weight) or 0
        )
      end
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.hostDebugName(id)
  return ("walk_debug_" .. tostring(id or "character") .. ".txt")
end

function M.writeDebug(id, groups, rig)
  local body = M.encodeDebug(id, groups, rig)
  local hostName = M.hostDebugName(id)
  local saveDir = nil
  if love and love.filesystem and love.filesystem.getSaveDirectory then
    saveDir = love.filesystem.getSaveDirectory()
  end
  local hostOk, hostErr = false, "love.filesystem.write unavailable"
  if love and love.filesystem and love.filesystem.write then
    hostOk, hostErr = love.filesystem.write(hostName, body)
  end
  local cacheOk, cacheErr = false, nil
  if GeneratedAssets and GeneratedAssets.write then
    local path = M.debugPath(id)
    if isWalkOverlayPath(path) then
      cacheOk, cacheErr = GeneratedAssets.write(path, body)
    end
  end
  if hostOk then
    return true, (saveDir and (saveDir .. "/" .. hostName) or hostName)
  end
  if cacheOk then
    return true, M.debugPath(id)
  end
  return false, tostring(hostErr or cacheErr or "walk_debug write failed")
end

function M.paint(rig, groups, x, y, z, radius, bucket, side, weight)
  if not (rig and rig.groups) then return 0 end
  local r2 = (radius or 0.08) * (radius or 0.08)
  local painted = 0
  for gi, g in ipairs(groups or {}) do
    local base = g.baseVertices
    local buckets = rig.groups[gi]
    if base and buckets then
      for vi = 1, #base do
        local v = base[vi]
        local dx = (v[1] or 0) - x
        local dy = (v[2] or 0) - y
        local dz = (v[3] or 0) - z
        if dx * dx + dy * dy + dz * dz <= r2 then
          local b = buckets[vi]
          if not b then
            b = {}
            buckets[vi] = b
          end
          b.bucket = bucket or "torso"
          if side then b.side = side end
          b.weight = (bucket == "torso") and 0 or (weight or 1)
          painted = painted + 1
        end
      end
    end
  end
  return painted
end

function M.bucketColor(bucket, side)
  if bucket == "arm" then
    return (side or 1) < 0 and {0.20, 0.75, 1.00} or {1.00, 0.45, 0.15}
  elseif bucket == "thigh" then
    return (side or 1) < 0 and {0.25, 0.90, 0.35} or {0.95, 0.85, 0.15}
  elseif bucket == "shin" then
    return (side or 1) < 0 and {0.10, 0.55, 0.25} or {0.85, 0.55, 0.10}
  end
  return {0.55, 0.55, 0.62}
end

-- Apply manual vertex overrides exported from the Python editor or the
-- in-game model viewer. `overridesPath` is a host filesystem path; prefer
-- M.applyFromCache for generated cache files.
function M.applyOverrides(rig, overridesPath)
  local ok, overrides = pcall(dofile, overridesPath)
  if not ok or type(overrides) ~= "table" then
    print("CharacterWalkCycle: failed to load overrides from " .. tostring(overridesPath))
    return
  end
  local n = M.applyOverrideTable(rig, overrides)
  print("CharacterWalkCycle: applied " .. n .. " manual overrides from " .. tostring(overridesPath))
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
-- `posedVertices`, when given, is the live idle/victory pose for this group
-- (CharacterNativeAnim.copyPositions). The gait then swings those posed verts
-- instead of the rest-pose mesh, so walking keeps the character's authored
-- idle body language. Buckets/pivots still come from the rest-pose rig.
function M.apply(rig, groupIndex, group, phase, blend, out, posedVertices)
  out = out or {}
  local buckets = rig.groups[groupIndex]
  local base, uv = group.baseVertices, group.baseUVs
  if not buckets or not base then return out end

  local hipY, kneeY, shoulderY = rig.hipY, rig.kneeY, rig.shoulderY
  local pivotFwd = rig.stridePivotFwd or 0
  local strideSign = rig.strideSign or 1

  -- Both legs' hip-phase and knee-phase sines only ever take one of two
  -- values per frame (the left leg is always exactly half a cycle behind
  -- the right), so compute each pair once here instead of per vertex.
  local hipSinR = math.sin(phase)
  local bob = blend * BOB_AMOUNT * (0.5 - 0.5 * math.cos(phase * 2))

  for vi = 1, #base do
    local v = (posedVertices and posedVertices[vi]) or base[vi]
    local side = v[SIDE_INDEX]
    local up = v[2] + bob
    local fwd = v[FORWARD_INDEX]

    local b = buckets[vi]
    if b and b.weight > 0 and blend > 0 then
      local hipSin = (b.side < 0) and -hipSinR or hipSinR
      local w = b.weight * blend
      local hipAngle = -strideSign * HIP_SWING * (hipSin - LEG_FRONT) * w
      if b.bucket == "arm" then
        local armAngle = strideSign * ARM_SWING * (hipSin + ARM_FRONT) * w
        up, fwd = rotate2(up, fwd, shoulderY, pivotFwd, armAngle)
      elseif b.bucket == "thigh" or b.bucket == "shin" then
        up, fwd = rotate2(up, fwd, hipY, pivotFwd, hipAngle)
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

-- Single 0..1 "how bent right now" curve for a manual hop: rises from 0
-- (standing) through a shallow JUMP_CROUCH_FRAC windup crouch at
-- JUMP_LOAD_FRAC, on up to a full 1.0 tuck at the midpoint (progress 0.5,
-- the top of the hop), back down through a shallow landing crouch at
-- 1 - JUMP_SETTLE_FRAC, and down to 0 again by progress 1 (feet planted).
-- Every limb in M.applyJump below reads this same curve, just scaled by
-- its own JUMP_*_MAX, rather than each keeping its own separate timing --
-- one shared curve is what keeps the hip/knee/arm moving as one motion
-- instead of three animations that happen to overlap.
local function jumpEnvelope(p)
  local L, S = JUMP_LOAD_FRAC, JUMP_SETTLE_FRAC
  if p <= L then
    return JUMP_CROUCH_FRAC * smooth01(p / L)
  elseif p <= 0.5 then
    return JUMP_CROUCH_FRAC + (1 - JUMP_CROUCH_FRAC) * smooth01((p - L) / (0.5 - L))
  elseif p <= 1 - S then
    return 1 - (1 - JUMP_CROUCH_FRAC) * smooth01((p - 0.5) / (0.5 - S))
  else
    return JUMP_CROUCH_FRAC * (1 - smooth01((p - (1 - S)) / S))
  end
end

-- Produce a fresh vertexData array for one mesh group during a manual
-- (cosmetic, in-place) hop -- see PlayerModel.draw for where `progress`
-- (0 at takeoff, 1 at landing) comes from. Same output shape and same
-- `out`-reuse convention as M.apply, and callers should use ONE or the
-- OTHER per frame, never both: a hop and a stride are different motions
-- of the same buckets, not two things to blend together.
--
-- Unlike M.apply, there is no left/right alternation here -- both feet
-- leave the ground together on a hop, so every bucket gets the same
-- magnitude regardless of `b.side` -- and no torso bob, since the actual
-- vertical travel of the whole model is the engine's own jump arc,
-- already baked into the `y` PlayerModel.draw is called with.
function M.applyJump(rig, groupIndex, group, progress, out, posedVertices)
  out = out or {}
  local buckets = rig.groups[groupIndex]
  local base, uv = group.baseVertices, group.baseUVs
  if not buckets or not base then return out end

  local hipY, kneeY, shoulderY = rig.hipY, rig.kneeY, rig.shoulderY
  local e = jumpEnvelope(clamp(progress or 0, 0, 1))
  local hipAngle = JUMP_HIP_MAX * e
  local kneeAngle = JUMP_KNEE_MAX * e
  local armAngle = JUMP_ARM_MAX * e

  for vi = 1, #base do
    local v = (posedVertices and posedVertices[vi]) or base[vi]
    local side = v[SIDE_INDEX]
    local up = v[2]
    local fwd = v[FORWARD_INDEX]

    local b = buckets[vi]
    if b and b.weight > 0 and e > 0 then
      if b.bucket == "arm" then
        -- Both arms swing back together, away from the tucked legs, same
        -- "negative = backward" sign M.apply's own arm swing uses.
        up, fwd = rotate2(up, fwd, shoulderY, 0, -armAngle * b.weight)
      elseif b.bucket == "thigh" then
        up, fwd = rotate2(up, fwd, hipY, 0, hipAngle * b.weight)
      elseif b.bucket == "shin" then
        -- Same hip-then-knee FK chain as M.apply: swing the whole leg
        -- (including the knee pivot) around the hip first, then fold the
        -- shin further around the knee's already-swung position.
        local kneeUpNow, kneeFwdNow = rotate2(kneeY, 0, hipY, 0, hipAngle * b.weight)
        up, fwd = rotate2(up, fwd, hipY, 0, hipAngle * b.weight)
        up, fwd = rotate2(up, fwd, kneeUpNow, kneeFwdNow, kneeAngle * b.weight)
      end
    end

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
