local V = ...
local Trainer = V and V.Trainer
local PlayerTrainer = V and V.PlayerTrainer
local BattleDirector=V and V.BattleDirector
local CurrentSpriteModels=V and V.CurrentSpriteModels
local C = {}
local Pacing=V and V.CameraPacing

local DEFAULT = {orbit=1.33,elevation=0.46,radius=64,fov=40,focus={0,6.3,0}}
local MANUAL_RELEASE_DELAY = 1.35
local AUTO_RETURN_BLEND = 0.72
local AUTHORED_ZOOM_OUT = 1.045
-- Mobile touch layouts crop substantially more of the authored battle frame than
-- desktop. Preserve shot ownership/yaw/timing, but give automatic fallback
-- compositions more optical breathing room. Fully decoded retail HSD frames
-- still bypass this adaptation below and remain byte-for-byte optical samples.
local MOBILE_AUTO_PULLBACK = 1.16
local MOBILE_ACTION_PULLBACK = 1.10
local MOBILE_AUTO_FOV_BONUS = math.rad(1.8)
local MOBILE_ACTION_FOV_BONUS = math.rad(2.8)

-- Battle input can advance several queue checkpoints in a fraction of a
-- second. Those checkpoints may emit move/damage/turn events back-to-back,
-- but they are NOT camera buttons. Commit to readable shots and coalesce
-- lower-priority events rather than cutting once per queue notification.
local EVENT_HOLDS = {
  attack = 1.02,
  damage = 0.88,
  reaction = 0.96,
  capture = 1.35,
  faint = 2.05,
  switch = 1.42,
  exit = 1.22,
  passive = 1.05,
  command = 1.05,
}
local EVENT_PRIORITY = { passive=0, command=1, attack=2, damage=3, reaction=3, capture=4, switch=4, faint=5, exit=6 }
local MIN_INTERRUPT_AGE = 0.58
-- GC6E01 battleCameraStartRandom uses a 200-frame countdown and only starts a
-- new owner camera on a 50% random gate. While Waza camera ownership is active
-- the retail function continually restores the countdown instead of advancing
-- it. Mirror that cadence in presentation seconds. Pokemon-owned passive shots
-- can now also reuse the exact PKX +0x54 chest target identity and retail
-- DoPosition yaw formulas; only RNG identity, absolute radius/FOV and exact
-- pattern-row duration remain adapted/blocked.
local PASSIVE_RANDOM_INTERVAL = 200/60
local PASSIVE_RANDOM_GATE = 0.50
-- Until the exact 0x7B1800 floor curve can be transformed together with the
-- retail grid/floor scale, do not freeze on the final passive Waza frame for the
-- entire post-owner 200-frame countdown. This is deliberately a CBE fallback:
-- one finite camera-right truck that settles, then HOLDS. It never loops/orbits
-- and it does not alter the retail scheduler cadence above.
local PASSIVE_FLOOR_SETTLE_DURATION = 1.50
local PASSIVE_FLOOR_SETTLE_DISTANCE = 4.0

-- Camera-only pacing is independent of accelerated battle/MoveFX clocks. The
-- source sampler still sees the live action; at fast speeds its optical output
-- is intentionally adapted for readability rather than advertised as exact.
local function battleSpeed(ctx)
  if Pacing then return Pacing.speed(ctx,nil,V and V.mod) end
  local b=type(ctx)=="table" and (ctx.battle or (ctx.kind and ctx)) or nil
  local game=(b and b.game) or (ctx and ctx.game) or (V and V.mod and V.mod.game)
  local speed
  if game and type(game.logicSpeed)=="function" then
    local ok,value=pcall(game.logicSpeed,game)
    if ok then speed=tonumber(value) end
  end
  if not speed then
    local opts=game and game.save and game.save.options
    speed=tonumber(opts and (opts.speedBattle or opts.speed)) or 1
  end
  if speed~=speed or speed<1 or math.abs(speed)==math.huge then speed=1 end
  return speed
end

local function holdScale(speed)
  -- With CameraPacing installed, state.time already compensates accelerated
  -- ticks. Keep holds in presentation seconds; never divide them a second time.
  return 1
end

local function phaseAllowedAtSpeed(phase,speed)
  -- Preserve the complete source-style shot vocabulary at every speed. Dropping
  -- impact/reaction cuts at 4X was the main reason accelerated footage stayed
  -- parked on a distant master while the actors were already performing.
  return true
end

-- IMPORTANT: this is NOT a retail camera table. GC6E01 battleCameraStartRandom
-- chooses a live trainer/Pokemon owner, then fn_801D2C74 calls
-- battleCameraStartWaza(owner,NULL). Eye/radius/height/FOV are consequently
-- derived from that owner's live ModelSequence bounds/rotation plus the shared
-- HSD RNG stream. These four records are CBE readability fallbacks only when
-- the complete owner camera cannot be reconstructed; only their owner vocabulary
-- mirrors the source scheduler. Never promote their numeric fields to 1:1.
local PASSIVE_FALLBACK_TABLE_EXACT=false
local PASSIVE_SHOTS = {
  -- battleCameraStartRandom passes an actual trainer/Pokemon owner to
  -- battleCameraStartWaza. These four fallback records mirror that ownership;
  -- their coordinates remain CBE reconstructions, not retail shot values.
  -- Retail passive ownership calls battleCameraStartWaza(owner,NULL), which
  -- selects one of the same finite position modes 3/0/1/2 used by Waza cameras.
  -- These records provide only safe fallback endpoints; passiveMotionPose below
  -- decides whether a given owner shot is a position drift, dolly, lateral move,
  -- or timed Y-rotation. No mode is a perpetual stadium orbit.
  {owner="player-pokemon",eye={55,25,6},   focus={0,6.2,0},fov=36,hold=6.20,travel={-2.2,.55,-1.0},focusTravel={0,.10,0},arc=math.rad(14),lateral=10,dolly=.10},
  {owner="enemy-pokemon", eye={-54,25,-6}, focus={0,6.2,0},fov=36,hold=6.00,travel={2.1,.55,1.0},focusTravel={0,.10,0},arc=math.rad(-14),lateral=10,dolly=.10},
  {owner="player-trainer",eye={-32,22,42}, focus={0,6.4,0},fov=36,hold=5.80,travel={1.6,.45,-1.3},focusTravel={-.30,.08,-.40},arc=math.rad(11),lateral=9,dolly=.10},
  {owner="enemy-trainer", eye={32,22,-42}, focus={0,6.4,0},fov=36,hold=5.80,travel={-1.6,.45,1.3},focusTravel={.30,.08,.40},arc=math.rad(-11),lateral=9,dolly=.10},
}
-- Command framing is also a CBE fallback, not a recovered retail table. Retail
-- fn_801EF8F4 reloads the current floor camera animation through fn_801C2F00
-- passing exact floor camera animation/resource key 0x7B1800 for BOTH
-- simple/full camera modes; the mode bit only controls the random-owner
-- scheduler. GC6E01's FSYS loader passes each entry's nameHash unchanged as the
-- camera callback loadMode, and floorReadCameraPostFunc registers the parsed
-- HSD camera under that same key, so 0x7B1800's resource identity is now proven.
-- Production does not yet carry the complete floor-camera/floor-model/battle-grid
-- transform through runtime, so the pose itself remains explicitly non-exact and
-- these three command compositions remain readability fallbacks.
local COMMAND_FALLBACK_TABLE_EXACT=false
local RETAIL_FLOOR_CAMERA_ANIMATION_ID=0x7B1800
local RETAIL_FLOOR_CAMERA_ANIMATION_RATE=0.5
-- GC6E01 fn_801C2F00 / battleGridApplyFloorScale share this exact uniform
-- scale between every floor model and cameraSetOffsetScale.  The scan starts at
-- selector 0 and takes the largest live Pokemon ModelSequence::sequenceKind;
-- -2/-1/0 and every other value therefore take the switch default 1.0.
-- Keep this as a source-space transform only. CBE currently normalizes PKX body
-- geometry and uses presentation anchors, so applying these raw camera points to
-- the live renderer would falsely claim that the retail floor/grid/PKX coordinate
-- frame still exists end-to-end.
local RETAIL_FLOOR_CAMERA_SCALE={
  [1]=1.1000000238418579,
  [2]=1.2000000476837158,
  [3]=1.3999999761581421,
}
local function retailFloorCameraScale(selector)
  return RETAIL_FLOOR_CAMERA_SCALE[tonumber(selector)] or 1.0
end
local function retailFloorCameraMaxSelector(selectors)
  local maxSelector=0
  for _,value in ipairs(type(selectors)=="table" and selectors or {}) do
    value=tonumber(value)
    if value and value>maxSelector then maxSelector=value end
  end
  return maxSelector
end
local function retailFloorCameraOffsetPose(sample,selectors)
  if type(sample)~="table" or type(sample.eye)~="table" or type(sample.focus)~="table" then return nil end
  local selector=retailFloorCameraMaxSelector(selectors)
  local scale=retailFloorCameraScale(selector)
  -- fn_801C2F00 zeros offsetPosition/offsetRotation immediately before setting
  -- this uniform scale. _cameraOffsetAnimeUpdate then scales BOTH CObj eye and
  -- interest before those zero transforms, so this is the complete retail
  -- source-space result for the floor-camera path.
  return {
    eye={(tonumber(sample.eye[1]) or 0)*scale,(tonumber(sample.eye[2]) or 0)*scale,(tonumber(sample.eye[3]) or 0)*scale},
    focus={(tonumber(sample.focus[1]) or 0)*scale,(tonumber(sample.focus[2]) or 0)*scale,(tonumber(sample.focus[3]) or 0)*scale},
    fov=sample.fov,
  },{selector=selector,scale=scale,position={0,0,0},rotation={0,0,0},worldUp={0,1,0},exact=true}
end
local COMMAND_SHOTS = {
  {eye={67,31,8},focus={0,6.2,0},fov=48,hold=6.2,blend=1.25,travel={-1.8,.4,-.5}},
  {eye={66,32,-8},focus={0,6.2,0},fov=48,hold=6.0,blend=1.25,travel={-1.2,-.1,.7}},
  {eye={64,30,2},focus={0,6.2,0},fov=47,hold=6.1,blend=1.2,travel={1.0,.35,.6}},
}


local state = {
  time=0, idleClock=0, phaseAge=0, phase="intro", lastPose=nil, startPose=nil,
  eventSide=nil,eventIndex=0,eventResult=nil,resultPending=nil,resultAt=0,shotOffset=0,special=nil,specialUntil=0,
  actionAxisAttacker=nil,actionAxisSign=nil,
  passiveShotIndex=1,passiveShotAge=0,passiveTimer=PASSIVE_RANDOM_INTERVAL,passiveRng=1,
  passiveMotionMode=2,passiveLastMotionMode=nil,passiveSourcePlan=nil,passiveSourceTargetResolved=false,
  manual=false, manualLocked=false, manualIdle=0, returning=false, keys={},
  shotLockUntil=0,pendingEvent=nil,lastCutTime=-999,lastEventName=nil,logicSpeed=1,
  sourcePose=nil,sourcePoseAt=0,sourceIdentity=nil,sourceHandoff=nil,sourceHandoffAt=0,
  orbit=DEFAULT.orbit,elevation=DEFAULT.elevation,radius=DEFAULT.radius,fov=DEFAULT.fov,
  focus={DEFAULT.focus[1],DEFAULT.focus[2],DEFAULT.focus[3]},
  mouseX=nil,mouseY=nil,
}

local function clamp(v,a,b) if v<a then return a elseif v>b then return b else return v end end
local function atan2(y,x)
  if math.atan2 then return math.atan2(y,x) end
  if x>0 then return math.atan(y/x) end
  if x<0 then return math.atan(y/x)+(y>=0 and math.pi or -math.pi) end
  return y>0 and math.pi/2 or (y<0 and -math.pi/2 or 0)
end
local function smooth(t) t=clamp(t,0,1); return t*t*(3-2*t) end
local function copy3(v) return {v[1],v[2],v[3]} end
local function copyPose(p)
  if not p then return nil end
  return {eye=copy3(p.eye),focus=copy3(p.focus),fov=p.fov}
end
local function validSourcePose(p)
  if type(p)~="table" or type(p.eye)~="table" or type(p.focus)~="table" then return false end
  local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
  if not finite(p.fov) or p.fov<=0 or p.fov>=math.pi then return false end
  local distance=0
  for i=1,3 do
    if not finite(p.eye[i]) or not finite(p.focus[i]) then return false end
    distance=distance+(p.eye[i]-p.focus[i])^2
  end
  return distance>1e-10
end
local function orbitMix(a,b,t)
  if not a then return copyPose(b) end
  t=clamp(t,0,1)
  local function polar(p)
    local x,y,z=p.eye[1]-p.focus[1],p.eye[2]-p.focus[2],p.eye[3]-p.focus[3]
    local h=math.sqrt(x*x+z*z)
    return atan2(x,z),atan2(y,math.max(.000001,h)),math.sqrt(h*h+y*y)
  end
  local ay,ap,ar=polar(a);local by,bp,br=polar(b)
  local yaw=ay+((by-ay+math.pi)%(2*math.pi)-math.pi)*t
  local pitch=ap+(bp-ap)*t;local radius=ar+(br-ar)*t
  local focus={a.focus[1]+(b.focus[1]-a.focus[1])*t,
    a.focus[2]+(b.focus[2]-a.focus[2])*t,a.focus[3]+(b.focus[3]-a.focus[3])*t}
  local h=math.cos(pitch)*radius
  return {eye={focus[1]+math.sin(yaw)*h,focus[2]+math.sin(pitch)*radius,focus[3]+math.cos(yaw)*h},
    focus=focus,fov=a.fov+(b.fov-a.fov)*t}
end
local function mix(a,b,t) return orbitMix(a,b,smooth(t)) end
-- Presentation filtering is deliberately separate from state.time. The battle
-- scheduler and exact HSD source timeline keep their original fixed-step clock.
-- Repeated accelerated ticks cannot advance this display filter without time.
local function presentPose(pose,exact,manual)
  if not (love and love.timer and type(love.timer.getTime)=="function") then return pose end
  local ok,now=pcall(love.timer.getTime)
  if not ok or type(now)~="number" or now~=now or math.abs(now)==math.huge then return pose end
  local dt=state.displayClock and clamp(now-state.displayClock,0,.10) or 0
  state.displayClock=now
  if exact or manual or not state.displayPose then state.displayPose=copyPose(pose)
  else state.displayPose=orbitMix(state.displayPose,pose,1-math.exp(-dt*9)) end
  return copyPose(state.displayPose)
end
local function approach(a,b,maxDelta)
  local d=b-a
  if d>maxDelta then return a+maxDelta end
  if d< -maxDelta then return a-maxDelta end
  return b
end
local function length3(x,y,z) return math.sqrt(x*x+y*y+z*z) end
local function approach3(a,b,maxDistance)
  if not a then return copy3(b) end
  local dx,dy,dz=b[1]-a[1],b[2]-a[2],b[3]-a[3]
  local d=length3(dx,dy,dz)
  if d<=maxDistance or d<1e-8 then return copy3(b) end
  local q=maxDistance/d
  return {a[1]+dx*q,a[2]+dy*q,a[3]+dz*q}
end
local function stableSourcePose(raw,retailExact,speed)
  if not raw then state.sourcePose=nil;state.sourceIdentity=nil;state.sourcePoseAt=state.time;return nil end
  local now=state.time
  local identity=raw.sourceShotId or raw.sourceSerial
  -- Once an embedded HSD Waza camera has passed the source decoder + owner/grid
  -- transform proof, its fixed-step samples are already the retail camera. The
  -- engine calls us once per accelerated logic tick, so pass the authored sample
  -- through at every speed instead of rate-limiting it on a second clock.
  if retailExact then
    state.sourceIdentity=identity;state.sourcePose=copyPose(raw);state.sourcePoseAt=now
    return copyPose(raw)
  end
  if raw.cut and state.sourceIdentity~=identity then
    state.sourceIdentity=identity;state.sourcePose=copyPose(raw);state.sourcePoseAt=now
    return copyPose(raw)
  end
  state.sourceIdentity=identity
  local dt=math.max(0,math.min(.08,now-(tonumber(state.sourcePoseAt) or now)))
  state.sourcePoseAt=now
  if not state.sourcePose then state.sourcePose=copyPose(raw);return copyPose(raw) end
  -- Unsupported/procedural source poses retain a bounded fixed-step limiter.
  -- This is only a safety fallback; decoded retail cameras bypass it above.
  local eyeSpeed=30
  local focusSpeed=22
  local fovSpeed=math.rad(24)
  state.sourcePose.eye=approach3(state.sourcePose.eye,raw.eye,eyeSpeed*dt)
  state.sourcePose.focus=approach3(state.sourcePose.focus,raw.focus,focusSpeed*dt)
  state.sourcePose.fov=approach(state.sourcePose.fov,raw.fov,fovSpeed*dt)
  return copyPose(state.sourcePose)
end
local function widenAuthored(pose)
  if not pose then return pose end
  local out=copyPose(pose)
  -- Widen field width without turning the camera into a fisheye lens.
  out.fov=2*math.atan(math.tan(out.fov*0.5)*AUTHORED_ZOOM_OUT)
  return out
end
local mobilePlatformCached=nil
local function mobilePlatform()
  if mobilePlatformCached~=nil then return mobilePlatformCached end
  if not (love and love.system and type(love.system.getOS)=="function") then return false end
  local ok,osName=pcall(love.system.getOS)
  if not ok then return false end
  osName=tostring(osName or ""):lower()
  mobilePlatformCached=(osName=="android" or osName=="ios")
  return mobilePlatformCached
end

-- Mobile battle controls consume a large lower-third region of the viewport.
-- Keep attack/impact cinematography above that HUD without changing actor/world
-- coordinates: lower the optical target slightly (subjects then project higher
-- on screen) and widen the lens just enough to retain the complete combat line.
-- This is applied after both semantic and source-Waza composition, so native
-- source camera poses cannot accidentally put the actual MoveFX behind buttons.
local function hudSafePose(pose,phase)
  if not pose or not mobilePlatform() or phase=="free" then return pose end
  local out=copyPose(pose)
  -- All automatic mobile shots need a modest baseline pullback. Previously only
  -- attack/reaction beats were adapted, so command/sendout/doubles masters could
  -- jump back to a much tighter scale between otherwise source-like edits.
  local fx,fy,fz=out.focus[1],out.focus[2],out.focus[3]
  out.eye={fx+(out.eye[1]-fx)*MOBILE_AUTO_PULLBACK,
    fy+(out.eye[2]-fy)*1.08,
    fz+(out.eye[3]-fz)*MOBILE_AUTO_PULLBACK}
  out.fov=math.min(math.rad(53),out.fov+MOBILE_AUTO_FOV_BONUS)

  local action=phase=="attack" or phase=="damage" or phase=="reaction" or phase=="faint"
  if action then
    -- Touch controls occupy the lower third during an action. Lower the optical
    -- target (subjects project upward) and pull back once more without changing
    -- the shot's authored side, target, cut timing, or motion path.
    out.focus[2]=out.focus[2]-1.70
    fx,fy,fz=out.focus[1],out.focus[2],out.focus[3]
    out.eye={fx+(out.eye[1]-fx)*MOBILE_ACTION_PULLBACK,
      fy+(out.eye[2]-fy)*1.035,
      fz+(out.eye[3]-fz)*MOBILE_ACTION_PULLBACK}
    out.fov=math.min(math.rad(53),out.fov+MOBILE_ACTION_FOV_BONUS)
  end
  return out
end
local function arenaFrame(pose,arena)
  if not pose then return pose end
  local out=copyPose(pose)
  local cam=arena and arena.camera
  local side=cam and tonumber(cam.side) or 58
  local baseK=clamp(side/58,0.93,1.10)
  -- Most arenas use the shared broadcast compositions at their authored radius.
  -- Some source venues (notably Pyrite) have spectator architecture much closer
  -- to the battle floor. Their retail cameras stay inside that lower bowl; use
  -- data-driven radial/elevation compression rather than deleting source stands.
  local radiusScale=clamp(cam and tonumber(cam.shotRadiusScale) or 1,0.55,1.20)
  local heightScale=clamp(cam and tonumber(cam.shotHeightScale) or 1,0.55,1.20)
  local k=baseK*radiusScale
  -- Larger environments move the camera itself farther away; this is more
  -- natural than endlessly increasing FOV and keeps Pokemon/trainer scale
  -- readable. Water Colosseum is k~=1 and therefore retains its stable framing.
  local f=out.focus
  -- Open Colosseum venues use noticeably higher broadcast positions. Venue
  -- heightScale still compresses Relic/Outskirts/Pyrite/Deep into their proven
  -- low source envelopes, while normal venues now retain the requested height.
  local vertical=(1.08+0.16*baseK)*heightScale
  out.eye={f[1]+(out.eye[1]-f[1])*k, f[2]+(out.eye[2]-f[2])*vertical, f[3]+(out.eye[3]-f[3])*k}
  -- Realgam's identity lives above the battle deck: stacked crowd galleries and
  -- tower machinery. Bias the same held-shot compositions slightly upward
  -- rather than inventing extra cuts or a wider/fisheye lens.
  if arena and arena.id=="realgam_colosseum" then
    out.eye[2]=out.eye[2]-.65
    out.focus[2]=out.focus[2]+1.35
  end
  return out
end


local function finite(v)
  return type(v)=="number" and v==v and v~=math.huge and v~=-math.huge
end
local function cameraAspect()
  if love and love.graphics and type(love.graphics.getDimensions)=="function" then
    local ok,w,h=pcall(love.graphics.getDimensions)
    if ok and tonumber(w) and tonumber(h) and h>0 then return clamp(w/h,.45,2.5) end
  end
  return 16/9
end
local function safeCameraSpec(arena)
  local c=arena and arena.camera
  local s=c and c.safe or nil
  return s or {minRadius=27,maxRadius=84,minY=6.5,maxY=42,maxPitch=32,minPitch=-10,minFov=31,maxFov=53}
end
local function clampCameraVolume(pose,arena,phase)
  if not (pose and pose.eye and pose.focus) then return pose end
  local out=copyPose(pose);local spec=safeCameraSpec(arena)
  local free=phase=="free"
  for i=1,3 do
    if not finite(out.eye[i]) then out.eye[i]=(i==2 and 20 or (i==1 and 54 or 13)) end
    if not finite(out.focus[i]) then out.focus[i]=(i==2 and 6 or 0) end
  end
  if not finite(out.fov) then out.fov=math.rad(40) end
  out.fov=clamp(out.fov,math.rad(spec.minFov or 31),math.rad(spec.maxFov or 52))
  -- Compact source rooms can have authentic overhead geometry close to the
  -- battle bowl. Let the venue narrow the optical target band as well as the
  -- eye volume so source-Waza and blended shots cannot tilt back into it.
  if free then
    -- Manual composition is not an authored broadcast shot: permit vertical
    -- aim/pan without imposing the narrow automatic optical-target band.
    -- Physical eye height and outer venue radius still use the SAME limits.
    out.focus[2]=clamp(out.focus[2],.75,math.max(1,math.min(24,(tonumber(spec.maxY) or 32)-1)))
  else
    out.focus[2]=clamp(out.focus[2],tonumber(spec.minFocusY) or 3.8,tonumber(spec.maxFocusY) or 9.2)
  end
  local dx,dz=out.eye[1]-out.focus[1],out.eye[3]-out.focus[3]
  local horizontal=math.max(.001,math.sqrt(dx*dx+dz*dz))
  local dy=out.eye[2]-out.focus[2]
  local pitch=math.deg(atan2(dy,horizontal))
  local maxPitch=free and 65 or (tonumber(spec.maxPitch) or 24)
  local minPitch=free and -18 or (tonumber(spec.minPitch) or -10)
  -- Source Waza modes permit substantially more vertical camera travel than the
  -- old 21-degree CBE ceiling. Retain a broadcast-height cap; compact venues
  -- still provide their own lower maxPitch through ArenaCatalog.
  if phase=="attack" or phase=="damage" or phase=="reaction" then maxPitch=math.min(maxPitch,28) end
  pitch=clamp(pitch,minPitch,maxPitch)
  local radius=math.sqrt(horizontal*horizontal+dy*dy)
  local minRadius=tonumber(spec.minRadius) or 27
  if free then minRadius=math.max(12,minRadius*.65) end
  radius=clamp(radius,minRadius,tonumber(spec.maxRadius) or 78)
  local pr=math.rad(pitch);local hr=math.max(.001,math.cos(pr)*radius)
  local oldh=math.sqrt(dx*dx+dz*dz)
  local nx,nz
  if oldh<.001 then nx,nz=1,0 else nx,nz=dx/oldh,dz/oldh end
  out.eye[1]=out.focus[1]+nx*hr
  out.eye[3]=out.focus[3]+nz*hr
  out.eye[2]=clamp(out.focus[2]+math.sin(pr)*radius,tonumber(spec.minY) or 6.5,tonumber(spec.maxY) or 32)
  return out
end
local arenaPoint,other,actionAxisSide,trainerVisible
local function projectPose(pose,p)
  local ex,ey,ez=pose.eye[1],pose.eye[2],pose.eye[3]
  local fx,fy,fz=pose.focus[1]-ex,pose.focus[2]-ey,pose.focus[3]-ez
  local fl=math.sqrt(fx*fx+fy*fy+fz*fz);if fl<.001 then return nil end
  fx,fy,fz=fx/fl,fy/fl,fz/fl
  -- right = forward x worldUp
  local rx,ry,rz=-fz,0,fx
  local rl=math.sqrt(rx*rx+rz*rz);if rl<.001 then return nil end
  rx,rz=rx/rl,rz/rl
  local ux,uy,uz=ry*fz-rz*fy,rz*fx-rx*fz,rx*fy-ry*fx
  local qx,qy,qz=p[1]-ex,p[2]-ey,p[3]-ez
  local depth=qx*fx+qy*fy+qz*fz;if depth<=.15 then return nil end
  local x=qx*rx+qy*ry+qz*rz
  local y=qx*ux+qy*uy+qz*uz
  local t=math.tan((pose.fov or math.rad(40))*.5);if t<=.001 then return nil end
  return x/(depth*t*cameraAspect()),y/(depth*t),depth
end
local function combatSubjects(arena,phase,side)
  side=side or "player"
  if phase=="attack" then return arenaPoint(arena,side,6.0),arenaPoint(arena,other(side),6.0) end
  if phase=="damage" or phase=="reaction" or phase=="faint" then
    return arenaPoint(arena,other(side),6.0),arenaPoint(arena,side,6.0)
  end
  if phase=="switch" then return arenaPoint(arena,side,6.0),arenaPoint(arena,other(side),6.0) end
end
local function subjectsReadable(pose,arena,phase,side)
  local a,b=combatSubjects(arena,phase,side);if not a then return true end
  local ax,ay,az=projectPose(pose,a);local bx,by,bz=projectPose(pose,b)
  if not (ax and bx) then return false end
  local xlim=(mobilePlatform() and .72 or .80)
  local ylim=(mobilePlatform() and .58 or .70)
  if math.abs(ax)>xlim or math.abs(bx)>xlim or math.abs(ay)>ylim or math.abs(by)>ylim then return false end
  return az>4 and bz>4
end
local function anyCombatSubjectReadable(pose,arena,phase,side)
  local a,b=combatSubjects(arena,phase,side);if not a then return true end
  local function visible(p)
    local x,y,z=projectPose(pose,p)
    return x~=nil and math.abs(x)<.90 and math.abs(y)<.82 and z>3.2
  end
  return visible(a) or visible(b)
end
local function safeCombatMaster(arena,side,phase)
  side=side or "player"
  local attacker=(phase=="damage" or phase=="reaction" or phase=="faint") and other(side) or side
  local a=arenaPoint(arena,attacker,6.0);local b=arenaPoint(arena,other(attacker),6.0)
  local mid={(a[1]+b[1])*.5,6.0,(a[3]+b[3])*.5}
  local dx,dz=b[1]-a[1],b[3]-a[3];local l=math.max(.001,math.sqrt(dx*dx+dz*dz))
  local rx,rz=-dz/l,dx/l
  local sign=actionAxisSide and actionAxisSide(arena,attacker) or (attacker=="player" and 1 or -1)
  local distance=(phase=="damage" and 51 or 55)
  return {eye={mid[1]+rx*distance*sign,23.0,mid[3]+rz*distance*sign},focus=mid,fov=math.rad(46)}
end
local function readabilityGuard(pose,arena,phase,side,sourceOwned)
  if not pose then return pose end
  local out=clampCameraVolume(pose,arena,phase)
  if phase~="attack" and phase~="damage" and phase~="reaction" and phase~="faint" and phase~="switch" then return out end
  -- Retail Waza cameras target a specific owner/model part and are allowed to
  -- isolate that subject. Do not force every decoded source shot back into a
  -- generic two-battler master; require at least one combat subject to remain
  -- readable. Semantic fallback shots still protect both battlers.
  local readable=sourceOwned and anyCombatSubjectReadable or subjectsReadable
  if readable(out,arena,phase,side) then return out end
  -- First preserve the requested axis and simply pull back/widen. This keeps as
  -- much source composition as possible before falling back to a safe master.
  for _=1,3 do
    local f=out.focus
    out.eye={f[1]+(out.eye[1]-f[1])*1.12,f[2]+(out.eye[2]-f[2])*1.05,f[3]+(out.eye[3]-f[3])*1.12}
    out.fov=math.min(math.rad(52),out.fov+math.rad(2.0))
    out=clampCameraVolume(out,arena,phase)
    if readable(out,arena,phase,side) then return out end
  end
  return clampCameraVolume(safeCombatMaster(arena,side,phase),arena,phase)
end
local function resetManual()
  state.orbit=DEFAULT.orbit;state.elevation=DEFAULT.elevation;state.radius=DEFAULT.radius;state.fov=DEFAULT.fov
  state.focus={DEFAULT.focus[1],DEFAULT.focus[2],DEFAULT.focus[3]}
  state.mouseX=nil;state.mouseY=nil
end
local function isDown(key) return love and love.keyboard and love.keyboard.isDown and love.keyboard.isDown(key) and true or false end
local function pressed(key)
  local d=isDown(key); local was=state.keys[key]; state.keys[key]=d
  return d and not was
end
local function mouseDown(button)
  return love and love.mouse and love.mouse.isDown and love.mouse.isDown(button) and true or false
end
local function battleOf(ctx)
  if type(ctx)~="table" then return nil end
  return ctx.battle or (ctx.kind and ctx) or nil
end
local function battleHash(ctx)
  local b=battleOf(ctx)
  local id=(b and b.trainer and (b.trainer.id or b.trainer.name)) or (b and b.oppClass) or (b and b.kind) or "battle"
  local h=0
  for i=1,#tostring(id) do h=(h*33+tostring(id):byte(i))%65521 end
  return h
end
local function sideValue(value)
  if value==nil then return nil end
  if type(value)=="string" then
    local key=value:lower()
    if key=="player" or key=="ally" or key=="friendly" or key=="p1" then return "player" end
    if key=="enemy" or key=="opponent" or key=="foe" or key=="p2" then return "enemy" end
    local n=tonumber(value)
    if n==1 then return "player" elseif n==2 then return "enemy" end
    return nil
  end
  if type(value)=="number" then
    if value==1 then return "player" elseif value==2 then return "enemy" end
    return nil
  end
  if type(value)=="table" then
    -- Current Gen1Recomp Battlers explicitly expose isPlayer=false for foes.
    -- The old truthiness test recognized only the player half of that contract.
    if type(value.isPlayer)=="boolean" then return value.isPlayer and "player" or "enemy" end
    for _,k in ipairs({"side","index","id","name","team","ownerSide"}) do
      local resolved=sideValue(value[k])
      if resolved then return resolved end
    end
  end
  return nil
end

local function sideFrom(ctx,payload,fields)
  local b=battleOf(ctx)
  if type(payload)~="table" then return nil end
  for _,key in ipairs(fields or {"user","attacker","source","battler","side","target"}) do
    local value=payload[key]
    local resolved=sideValue(value)
    if resolved then return resolved end
    if b and value then
      if value==b.player then return "player" end
      if value==b.enemy then return "enemy" end
    end
  end
  return nil
end
arenaPoint=function(arena,side,y)
  -- Camera coordinates live in STAGE space. Pokemon providers receive an
  -- actor view-projection with figureScale already multiplied into it, so
  -- arena.player/enemy are intentionally inverse-scaled actor coordinates.
  -- Focusing the camera on those raw actor coordinates double-counts that
  -- inverse and pushes the visible Pokemon toward an edge. The visual anchors
  -- are the real on-stage positions after the actor transform is applied.
  local p=arena and ((side=="player" and arena.visualPlayer) or (side=="enemy" and arena.visualEnemy))
  if not p and arena then p=arena[side] end
  p=p or (side=="player" and {0,14.5} or {0,-14.5})
  return {p[1] or 0,y or 6.5,p[2] or 0}
end
local function trainerPoint(side,y)
  if side=="player" and PlayerTrainer and type(PlayerTrainer.anchor)=="function" then return PlayerTrainer:anchor(y) end
  if side=="enemy" and Trainer and type(Trainer.anchor)=="function" then return Trainer:anchor(y) end
  if side=="player" then return {13.2,y or 7.0,25.8} end
  return {-13.2,y or 7.0,-25.8}
end
other=function(side) return side=="enemy" and "player" or "enemy" end
local function manualPose()
  local r=state.radius; local ce=math.cos(state.elevation); local f=state.focus
  return {
    eye={f[1]+math.sin(state.orbit)*r*ce, f[2]+math.sin(state.elevation)*r, f[3]+math.cos(state.orbit)*r*ce},
    focus={f[1],f[2],f[3]}, fov=math.rad(state.fov),
  }
end

local function shotPose(s,u)
  u=smooth(clamp(u or 0,0,1))
  local tr=s.travel or {0,0,0}; local fr=s.focusTravel or {0,0,0}
  local pose={
    eye={s.eye[1]+tr[1]*u,s.eye[2]+tr[2]*u,s.eye[3]+tr[3]*u},
    focus={s.focus[1]+fr[1]*u,s.focus[2]+fr[2]*u,s.focus[3]+fr[3]*u},
    fov=math.rad(s.fov),
  }
  -- Finite source-style camera arc. Colosseum's Waza position mode 2 performs a
  -- timed Y rotation between authored endpoints; model that grammar as a single
  -- eased sweep inside the held shot rather than a clock-driven endless orbit.
  local arc=tonumber(s.arc) or 0
  if math.abs(arc)>1e-7 then
    local a=arc*u;local ca,sa=math.cos(a),math.sin(a)
    local dx,dz=pose.eye[1]-pose.focus[1],pose.eye[3]-pose.focus[3]
    pose.eye[1]=pose.focus[1]+dx*ca+dz*sa
    pose.eye[3]=pose.focus[3]-dx*sa+dz*ca
  end
  return pose
end
local function hsdRandStep(seed)
  -- Exact SysDolphin/HSD LCG arithmetic recovered from GC6E01:
  --   state = state * 0x343FD + 0x269EC3 (u32 wrap)
  --   Randf = high16(state) / 65536.0
  -- The battle-specific seed identity is still not available from the host, so
  -- only the RNG *algorithm/sample math* is exact here; seed provenance remains
  -- explicitly non-exact.
  seed=math.floor(tonumber(seed) or 1)%4294967296
  local next=(seed*0x343FD+0x269EC3)%4294967296
  local high=math.floor(next/65536)%65536
  return next,high/65536
end
local function nextPassiveRandom()
  local seed,value=hsdRandStep(state.passiveRng)
  state.passiveRng=seed
  return value
end
local function hsdRandBoundedStep(seed,range)
  range=math.floor(tonumber(range) or 0)
  if range<=0 then return seed,0 end
  -- Exact GC6E01 _fadeEffectGetRandom__FUl: consume two successive HSD u16
  -- samples, combine as (second << 16) | first, then modulo the requested range.
  local seed1,a=hsdRandStep(seed)
  local seed2,b=hsdRandStep(seed1)
  local lo=math.floor(a*65536)
  local hi=math.floor(b*65536)
  return seed2,((hi*65536)+lo)%range
end
local function nextPassiveBounded(range)
  local seed,value=hsdRandBoundedStep(state.passiveRng,range)
  state.passiveRng=seed
  return value
end
local PASSIVE_MOTIONS={3,0,1,2}
local function hsdSelectDifferentMotion(seed,lastMode)
  local mode
  repeat
    local value;seed,value=hsdRandStep(seed)
    local idx=math.min(#PASSIVE_MOTIONS,1+math.floor(value*#PASSIVE_MOTIONS))
    mode=PASSIVE_MOTIONS[idx]
  until mode~=lastMode
  return seed,mode
end
local function hsdSelectDifferentBounded(seed,range,current)
  range=math.floor(tonumber(range) or 0)
  if range<=1 then return seed,0 end
  local selected
  repeat seed,selected=hsdRandBoundedStep(seed,range) until selected~=current
  return seed,selected
end
local function choosePassiveMotion()
  -- _wazaSequenceCameraSelectMotion does NOT remove the prior mode before its
  -- draw. It samples the complete 3/0/1/2 interval table and retries when that
  -- draw lands on lbl_80478CD8. Preserve the retry itself so the local HSD stream
  -- consumes the same number of samples as retail for a given seed. Seed/global
  -- interleaving remains intentionally non-exact (see status()).
  local seed,mode=hsdSelectDifferentMotion(state.passiveRng,state.passiveLastMotionMode)
  state.passiveRng=seed
  state.passiveMotionMode=mode
  state.passiveLastMotionMode=state.passiveMotionMode
  state.passiveSourcePlan=nil;state.passiveSourceTargetResolved=false
end
local function passiveCandidates(ctx)
  local out={}
  for i,s in ipairs(PASSIVE_SHOTS) do
    local owner=s.owner or ""
    if owner=="player-trainer" then
      if trainerVisible and trainerVisible(ctx,"player") then out[#out+1]=i end
    elseif owner=="enemy-trainer" then
      if trainerVisible and trainerVisible(ctx,"enemy") then out[#out+1]=i end
    else out[#out+1]=i end
  end
  if #out==0 then for i=1,#PASSIVE_SHOTS do out[#out+1]=i end end
  return out
end
local function chooseDifferentPassiveShot(ctx)
  local candidates=passiveCandidates(ctx);if #candidates<2 then return end
  local current=tonumber(state.passiveShotIndex) or candidates[1]
  -- battleCameraStartRandom likewise calls _fadeEffectGetRandom(totalOwners) on
  -- the COMPLETE owner list, retrying only when its ordinal equals the previous
  -- lbl_80478CAC. Sampling an n-1 alternate list gives the same probabilities
  -- but consumes the wrong number of HSD RNG calls after a rejected draw.
  local currentOrdinal=-1
  for ordinal,i in ipairs(candidates) do if i==current then currentOrdinal=ordinal-1;break end end
  local seed,selected=hsdSelectDifferentBounded(state.passiveRng,#candidates,currentOrdinal)
  state.passiveRng=seed
  state.passiveShotIndex=candidates[selected+1]
  state.passiveShotAge=0
  choosePassiveMotion()
end

local function passiveFovEnvelope(retail,sample,index)
  if not (type(retail)=="table" and retail.exact==true and type(sample)=="table"
      and type(sample.fovRange)=="table") then return nil end
  index=math.max(1,math.min(3,math.floor(tonumber(index) or 1)))
  local range=index==1 and tonumber(sample.fovRange.near)
    or (index==2 and tonumber(sample.fovRange.mid) or tonumber(sample.fovRange.far))
  if not range or range<=0 then return nil end
  local scaleMin,scaleMax=tonumber(retail.scaleMin),tonumber(retail.scaleMax)
  -- _wazaSequenceCameraDoFOV advances its params pointer by four bytes before
  -- the second transition. Relative to the original buffer that makes the last
  -- segment read scaleMin=old scaleMax and scaleMax=old rotationMin.
  if index>=3 then scaleMin,scaleMax=scaleMax,tonumber(retail.rotationMin) end
  if scaleMin==nil or scaleMax==nil then return nil end
  local span=math.max(.75*scaleMin,scaleMax)
  local low=math.deg(2*math.atan(.5*span/range))
  local high=math.deg(2*math.atan(2*span/range))
  low=clamp(low,15,85);high=clamp(high,15,85)
  if high<low then low,high=high,low end
  return low,high
end

local function buildPassiveFovPlan(retail,sample,timing)
  local grammar=V and V.WazaCameraFov
  if not (grammar and type(grammar.mixBand)=="function" and type(grammar.staticChoice)=="function"
      and type(grammar.usesPattern)=="function") then return nil end
  local function draw() return nextPassiveRandom() end
  local function choose(flags,index)
    local low,high=passiveFovEnvelope(retail,sample,index);if not low then return nil end
    local a,b=grammar.mixBand(flags)
    return low+(high-low)*(a+(b-a)*draw())
  end
  local motion=tonumber(sample and sample.mode)
  if motion==nil then return nil end
  if not grammar.usesPattern(motion) then
    local value=choose(grammar.staticChoice(4),1);if not value then return nil end
    return {initial=value,keys={},frame0=0,formulaExact=true,rngExact=false,timingExact=true,
      patternUsed=false}
  end
  if not (type(timing)=="table" and timing.exact==true and tonumber(timing.sequenceKind)
      and type(timing.frames)=="table" and type(grammar.selectPattern)=="function"
      and type(grammar.selectDuration)=="function") then return nil end
  local count=math.max(0,math.floor(tonumber(timing.count) or 0))
  local shift=math.max(0,math.floor(tonumber(timing.frameShift) or 0));local scale=2^shift
  local frame0=(tonumber(timing.frames[1]) or 0)*scale
  local function randIndex(n)return nextPassiveBounded(math.max(1,n)) end
  -- Preserve retail RNG call order: pattern selection, initial FOV draw, then
  -- each segment's optional duration draw followed by its endpoint FOV draw.
  -- WazaCameraFov.plan() intentionally returns a complete plan and therefore
  -- cannot preserve this interleaving for a shared RNG stream.
  local row,rowIndex,tableName,selection=grammar.selectPattern(timing.sequenceKind,4,draw,randIndex)
  if not (row and row.descriptors and row.descriptors[1]) then return nil end
  local current=choose(row.descriptors[1].initialFlags,1);if not current then return nil end
  local out={initial=current,keys={},frame0=frame0,formulaExact=true,rngExact=false,timingExact=true,
    patternUsed=true,rowIndex=rowIndex,tableName=tableName,selection=selection}
  if count<=2 then return out end
  local prev=tonumber(timing.frames[1]) or 0
  for i=1,2 do
    local nextFrame=tonumber(timing.frames[i+1]) or prev
    local desc=row.descriptors[i]
    local key={start=current,finish=current,startFrame=prev*scale,endFrame=nextFrame*scale}
    if desc and prev~=nextFrame and tonumber(desc.mode) and desc.mode>=3 and desc.mode<5 then
      local duration=grammar.selectDuration(desc.durationMode,desc.thresholds,nextFrame-prev,draw)
      local ending=choose(desc.flags or 0,i+1);if not ending then return nil end
      key.finish=ending
      if desc.timingMode==2 then key.startFrame=(nextFrame-duration)*scale;key.endFrame=nextFrame*scale
      else key.startFrame=prev*scale;key.endFrame=(prev+duration)*scale end
      current=ending
    end
    out.keys[i]=key;prev=nextFrame
  end
  return out
end

local function passiveFovAt(plan,age)
  local fp=plan and plan.fovPlan;if not fp then return nil end
  local clock=(tonumber(fp.frame0) or 0)+math.max(0,tonumber(age) or 0)*60
  local value=tonumber(fp.initial)
  for _,key in ipairs(fp.keys or {}) do
    if clock<=key.startFrame then value=key.start;break end
    if clock<=key.endFrame then
      local span=key.endFrame-key.startFrame
      local t=span>0 and (clock-key.startFrame)/span or 1
      value=key.start+(key.finish-key.start)*clamp(t,0,1);break
    end
    value=key.finish
  end
  return value and math.rad(value) or nil
end

local function passivePokemonSourcePlan(ctx,s)
  local owner=tostring(s and s.owner or "")
  local side=owner=="player-pokemon" and "player" or (owner=="enemy-pokemon" and "enemy" or nil)
  if not side then return nil end
  local models=CurrentSpriteModels or (V and V.CurrentSpriteModels)
  local params=V and V.WazaCameraParams
  if not (models and type(models.wazaBasis)=="function" and params and type(params.calculate)=="function"
      and type(params.sampleMotion)=="function") then return nil end
  local otherSide=side=="player" and "enemy" or "player"
  local ok,root=pcall(models.wazaBasis,models,ctx,side,otherSide,nil,{
    role="attack",sourceStrict=true,ownerRoot=true})
  if not ok or type(root)~="table" or root.ownerModelRotationExact~=true then return nil end
  local selector=tonumber(root.sourceScaleSelector)
  local yaw=tonumber(root.ownerModelYaw)
  if selector==nil or yaw==nil then return nil end
  local retail=params.calculate(4,selector,root.ownerRetailWazaBound,yaw)
  if not (type(retail)=="table" and retail.exact==true) then return nil end
  local mode=tonumber(state.passiveMotionMode)
  local key=table.concat({tostring(state.passiveShotIndex),tostring(mode),side,tostring(selector),string.format("%.7f",yaw)},":")
  if state.passiveSourcePlan and state.passiveSourcePlan.key==key then return state.passiveSourcePlan end
  -- sequence=NULL always takes the owner-facing reverse rule. The local RNG is
  -- deterministic rather than retail HSD_Randf, so endpoint formulas are exact
  -- while the particular random sample remains explicitly non-exact.
  local sample=params.sampleMotion(mode,retail,function()return nextPassiveRandom() end,{
    rotationBase=yaw,reverse=side=="player",
  })
  if not (type(sample)=="table" and sample.worldRotationFormulaExact==true
      and tonumber(sample.worldRotation0) and tonumber(sample.worldRotation1)) then return nil end
  local timing=root.ownerCameraTiming
  local durationSeconds,durationExact
  if type(timing)=="table" and timing.motionDurationExact==true and tonumber(timing.motionDurationFrames) then
    local shift=math.max(0,math.floor(tonumber(timing.frameShift) or 0))
    local rate=math.max(1,tonumber(timing.rate) or 60)
    if mode~=0 then
      durationSeconds=math.max(0,tonumber(timing.motionDurationFrames))*(2^shift)/rate
      durationExact=true
    end
  end
  local plan={key=key,side=side,otherSide=otherSide,selector=selector,ownerYaw=yaw,
    reverse=side=="player",sample=sample,angleFormulaExact=true,angleRngExact=false,
    forward=type(root.forward)=="table" and copy3(root.forward) or nil,
    right=type(root.right)=="table" and copy3(root.right) or nil,
    targetField="pkx-current-slot+0x54/chest",targetFieldExact=true,
    physicalFormulaExact=true,radiusAbsoluteExact=false,
    durationSeconds=durationSeconds,durationExact=durationExact==true,fovExact=false}
  plan.fovPlan=buildPassiveFovPlan(retail,sample,timing)
  plan.fovFormulaExact=plan.fovPlan and plan.fovPlan.formulaExact==true or false
  plan.fovRngExact=plan.fovPlan and plan.fovPlan.rngExact==true or false
  plan.fovTimingExact=plan.fovPlan and plan.fovPlan.timingExact==true or false
  state.passiveSourcePlan=plan
  return plan
end

local function passivePokemonTarget(ctx,arena,plan)
  if not plan then return nil end
  local models=CurrentSpriteModels or (V and V.CurrentSpriteModels)
  if not (models and type(models.wazaBasis)=="function") then return nil end
  -- battleCameraStartWaza(owner,NULL) reads cameraParams+0x54. PKXMetadata's
  -- source 0xD0 row maps +0x4C/+0x50/+0x54 to origin/mouth/chest, so body slot 2
  -- is the exact source target identity for passive Pokemon cameras.
  local ok,basis=pcall(models.wazaBasis,models,ctx,plan.side,plan.otherSide,2,{
    role="attack",sourceStrict=true})
  if not ok or type(basis)~="table" or type(basis.origin)~="table" then return nil end
  local p=basis.origin
  if not (tonumber(p[1]) and tonumber(p[2]) and tonumber(p[3])) then return nil end
  local k=tonumber(arena and arena.figureScale) or tonumber(ctx and ctx.arena and ctx.arena.figureScale) or 1
  return {p[1]*k,p[2]*k,p[3]*k}
end

local function passiveMotionPose(s,focus,age,sourcePlan,figureScale)
  local duration=(sourcePlan and sourcePlan.durationExact and tonumber(sourcePlan.durationSeconds)) or s.hold or 1
  local raw=clamp((tonumber(age) or 0)/math.max(.01,duration),0,1)
  local u=smooth(raw);local fr=s.focusTravel or {0,0,0};local tr=s.travel or {0,0,0}
  focus=focus or s.focus
  if sourcePlan and sourcePlan.sample then
    local sample=sourcePlan.sample
    local sourceFov=passiveFovAt(sourcePlan,age) or math.rad(s.fov)
    -- cameraSetDistance/cameraSetHeight/cameraSetRotY establish the literal
    -- GC6E01 camera cylinder before cameraMovePosition/cameraMoveRotationXYZ
    -- starts. Older CBE builds only borrowed the sampled yaw/ratio while keeping
    -- the hand-authored PASSIVE_SHOTS radius and height. That made an otherwise
    -- source-backed Pokemon camera visibly too wide/tall for small parameter
    -- bands. Use the sampled retail physical cylinder directly; the shared RNG
    -- seed and exact position-move duration remain separate, explicitly blocked
    -- seams. Source timing interpolation itself is linear in camera.c.
    local k=tonumber(figureScale) or 1
    local theta=(tonumber(sample.worldRotation0) or 0)+
      ((tonumber(sample.worldRotation1) or tonumber(sample.worldRotation0) or 0)-(tonumber(sample.worldRotation0) or 0))*raw
    local distance=tonumber(sample.distance0)
    if sample.mode==0 and distance and tonumber(sample.distance1) then
      distance=distance+(sample.distance1-distance)*raw
    end
    local height=tonumber(sample.height)
    if distance and height then
      distance=distance*k;height=height*k
      if sample.mode==1 and tonumber(sample.lateral0) and tonumber(sample.lateral1)
          and type(sourcePlan.forward)=="table" and type(sourcePlan.right)=="table" then
        -- Mode 1 is the exceptional global-axis lateral move. In CBE battle
        -- coordinates the proven action basis is the retail axis transform, so
        -- reproduce cameraSetDistance + the authored +/-10 then +/-25..35 X
        -- displacement without turning it into an orbit.
        local lateral=(sample.lateral0+(sample.lateral1-sample.lateral0)*raw)*k
        local f,r=sourcePlan.forward,sourcePlan.right
        return {eye={focus[1]-f[1]*distance+r[1]*lateral,
                     focus[2]+height,
                     focus[3]-f[3]*distance+r[3]*lateral},
          focus={focus[1],focus[2],focus[3]},fov=sourceFov}
      end
      if tonumber(sample.worldRotation0) and tonumber(sample.worldRotation1) then
        return {eye={focus[1]+math.sin(theta)*distance,focus[2]+height,focus[3]+math.cos(theta)*distance},
          focus={focus[1],focus[2],focus[3]},fov=sourceFov}
      end
    end
  end
  local f={focus[1]+fr[1]*u,focus[2]+fr[2]*u,focus[3]+fr[3]*u}
  local eye={s.eye[1],s.eye[2],s.eye[3]}
  local mode=state.passiveMotionMode
  if mode==3 then
    -- Retail mode 3 is a finite cameraMovePosition. Exact owner ModelSequence
    -- bounds are not exported by the live bridge, so retain the established safe
    -- per-owner endpoint drift rather than fabricating a per-species transform.
    eye={eye[1]+tr[1]*u,eye[2]+tr[2]*u,eye[3]+tr[3]*u}
  elseif mode==0 then
    -- Retail mode 0 starts from a near distance and dollies toward a farther
    -- source-range sample. Keep height fixed and expand only the horizontal
    -- owner radius; venue guards still own the final physical camera volume.
    local dx,dz=eye[1]-f[1],eye[3]-f[3];local k=1+(tonumber(s.dolly) or .10)*u
    eye[1]=f[1]+dx*k;eye[3]=f[3]+dz*k
  elseif mode==1 then
    -- Retail mode 1 is one timed lateral position move (source offset constants
    -- are 25..35). CBE uses a conservative stage-space displacement because the
    -- owner ModelSequence scale class is not yet exported.
    local dx,dz=eye[1]-f[1],eye[3]-f[3];local l=math.max(.001,math.sqrt(dx*dx+dz*dz))
    local sign=(tonumber(s.arc) or 0)<0 and -1 or 1;local lateral=(tonumber(s.lateral) or 9)*u*sign
    eye[1]=eye[1]-dz/l*lateral;eye[3]=eye[3]+dx/l*lateral
  elseif mode==2 then
    -- Retail mode 2 is an explicit cameraMoveRotationXYZ Y sweep. Rotate around
    -- the live selected owner and stop exactly at the finite authored endpoint.
    local a=(tonumber(s.arc) or 0)*u;local ca,sa=math.cos(a),math.sin(a)
    local dx,dz=eye[1]-f[1],eye[3]-f[3]
    eye[1]=f[1]+dx*ca+dz*sa;eye[3]=f[3]-dx*sa+dz*ca
  end
  return {eye=eye,focus=f,fov=math.rad(s.fov)}
end
local function passiveFloorSettle(pose,age,duration,shotIndex)
  local elapsed=(tonumber(age) or 0)-math.max(0,tonumber(duration) or 0)
  if elapsed<=0 or not (pose and pose.eye and pose.focus) then return pose,false,false end
  local raw=clamp(elapsed/PASSIVE_FLOOR_SETTLE_DURATION,0,1)
  local u=smooth(raw)
  local dx,dz=pose.focus[1]-pose.eye[1],pose.focus[3]-pose.eye[3]
  local len=math.sqrt(dx*dx+dz*dz)
  if len<.001 then return pose,true,false end
  -- Translate eye AND interest together. That preserves the established action
  -- direction and lens instead of manufacturing an orbit around the subject.
  -- Alternating the truck side by owner slot avoids a one-way camera crawl while
  -- remaining deterministic and explicitly non-retail.
  local rx,rz=-dz/len,dx/len
  local sign=((tonumber(shotIndex) or 1)%2==0) and -1 or 1
  local shift=PASSIVE_FLOOR_SETTLE_DISTANCE*u*sign
  local out=copyPose(pose)
  out.eye[1]=out.eye[1]+rx*shift;out.eye[3]=out.eye[3]+rz*shift
  out.focus[1]=out.focus[1]+rx*shift;out.focus[3]=out.focus[3]+rz*shift
  return out,true,raw<1
end
local function passiveShot(ctx,arena)
  local s=PASSIVE_SHOTS[state.passiveShotIndex] or PASSIVE_SHOTS[1]
  if not s then return manualPose() end
  local owner=s.owner or "";local p
  local sourcePlan=passivePokemonSourcePlan(ctx,s)
  if sourcePlan then p=passivePokemonTarget(ctx,arena,sourcePlan) end
  state.passiveSourceTargetResolved=p~=nil and sourcePlan~=nil
  if not p and owner=="player-pokemon" then p=arenaPoint(arena,"player",6.0)
  elseif not p and owner=="enemy-pokemon" then p=arenaPoint(arena,"enemy",6.0)
  elseif owner=="player-trainer" then p=trainerPoint("player",6.8)
  elseif owner=="enemy-trainer" then p=trainerPoint("enemy",6.8) end
  -- Once the selected finite Waza-style motion completes, HOLD. Retail's random
  -- camera scheduler sees that Waza owner as active and restores its 200-frame
  -- countdown until the motion relinquishes the lens.
  local figureScale=tonumber(arena and arena.figureScale) or tonumber(ctx and ctx.arena and ctx.arena.figureScale) or 1
  local duration=(sourcePlan and sourcePlan.durationExact and tonumber(sourcePlan.durationSeconds)) or s.hold or 1
  local pose=passiveMotionPose(s,p,state.passiveShotAge,sourcePlan,figureScale)
  pose,state.passiveFloorFallbackActive,state.passiveFloorFallbackMoving=
    passiveFloorSettle(pose,state.passiveShotAge,duration,state.passiveShotIndex)
  return pose
end

trainerVisible=function(ctx,side)
  local provider=side=="player" and PlayerTrainer or Trainer
  if not (provider and type(provider.shouldRender)=="function") then return false end
  local ok,v=pcall(provider.shouldRender,provider,ctx)
  return ok and v==true
end

local function trainerPassiveMaster(ctx)
  -- During command/menu time keep both back-line trainers and both battler
  -- positions readable. Event cinematography is still free to cut tighter.
  -- This also gives high-speed battles a calm visual home instead of returning
  -- to a side-biased idle shot that can crop a human trainer entirely.
  local hasPlayer=trainerVisible(ctx,"player")
  local hasEnemy=trainerVisible(ctx,"enemy")
  if not (hasPlayer or hasEnemy) then return nil end
  -- Command/menu time is a composition HOLD. Do not run a deterministic tour
  -- while the player is reading UI; the retail random-owner scheduler belongs
  -- to passive battle-camera time, not an invented command carousel.
  local idx=((state.shotOffset or 0)%#COMMAND_SHOTS)+1
  local s=COMMAND_SHOTS[idx] or COMMAND_SHOTS[1]
  local shot=shotPose(s,math.min(1,state.idleClock/math.max(.01,s.hold or 1)))
  if hasEnemy and not hasPlayer then
    shot.focus={-2.0,5.9,-3.5}
  elseif hasPlayer and not hasEnemy then
    shot.focus={2.0,5.9,3.5}
  end
  return shot
end

actionAxisSide=function(arena,attackerSide)
  attackerSide=attackerSide or "player"
  if state.actionAxisAttacker==attackerSide and state.actionAxisSign then return state.actionAxisSign end
  local src=arenaPoint(arena,attackerSide,6.0)
  local dst=arenaPoint(arena,other(attackerSide),6.0)
  local dx,dz=dst[1]-src[1],dst[3]-src[3]
  local len=math.max(.001,math.sqrt(dx*dx+dz*dz));local rx,rz=-dz/len,dx/len
  local midx,midz=(src[1]+dst[1])*.5,(src[3]+dst[3])*.5
  local reference=state.startPose or state.lastPose
  local dot=reference and ((reference.eye[1]-midx)*rx+(reference.eye[3]-midz)*rz) or 0
  local sign
  if math.abs(dot)>.001 then sign=dot<0 and -1 or 1
  else sign=attackerSide=="player" and 1 or -1 end
  state.actionAxisAttacker=attackerSide;state.actionAxisSign=sign
  return sign
end
local function actionAxisPose(arena,attackerSide,focus,range,back,side,lift,fov)
  local src=arenaPoint(arena,attackerSide,6.0)
  local dst=arenaPoint(arena,other(attackerSide),6.0)
  local dx,dz=dst[1]-src[1],dst[3]-src[3]
  local len=math.max(.001,math.sqrt(dx*dx+dz*dz));local fx,fz=dx/len,dz/len
  local rx,rz=-fz,fx;local sign=actionAxisSide(arena,attackerSide)
  range=math.max(24,tonumber(range) or len*1.45)
  return {eye={focus[1]-fx*range*(back or .2)+rx*range*(side or .7)*sign,
      focus[2]+range*(lift or .22),focus[3]-fz*range*(back or .2)+rz*range*(side or .7)*sign},
    focus=focus,fov=fov or math.rad(42)}
end


local function eventShot(ctx,arena,side,kind,variant)
  side=side or "player"; variant=((variant or 1)-1)%3+1
  local a=arenaPoint(arena,side,6.2); local sgn=side=="player" and 1 or -1
  local z=a[3]
  if kind=="attack" then
    -- Move cinematography must keep the attacking Pokemon readable. The old
    -- trainer/Pokemon midpoint could put the human in the exact centre while
    -- both battlers were outside the crop (visible in the 1.5.40 Flame Wheel
    -- test). Frame the combat line itself; trainer reaction gets its own beat.
    local target=arenaPoint(arena,other(side),6.1)
    local focus={a[1]*.72+target[1]*.28,6.15,a[3]*.72+target[3]*.28}
    local fight=math.max(28,math.sqrt((target[1]-a[1])^2+(target[3]-a[3])^2)*1.48)
    if variant==1 then return actionAxisPose(arena,side,focus,fight,.22,.82,.34,math.rad(45)) end
    if variant==2 then return actionAxisPose(arena,side,focus,fight,.06,.88,.32,math.rad(45)) end
    return actionAxisPose(arena,side,focus,fight,.34,.74,.36,math.rad(46))
  elseif kind=="damage" then
    -- Preserve the attack's screen direction through impact. The old damage
    -- shot derived its sign from the *target* and could flip the 180-degree
    -- axis exactly when the Waza projectile arrived, which read as a violent
    -- camera jump at high battle speed.
    local attackerSide=other(side)
    local attacker=arenaPoint(arena,attackerSide,6.1)
    local focus={a[1]*.76+attacker[1]*.24,6.00,a[3]*.76+attacker[3]*.24}
    local fight=math.max(27,math.sqrt((a[1]-attacker[1])^2+(a[3]-attacker[3])^2)*1.40)
    if variant==1 then return actionAxisPose(arena,attackerSide,focus,fight,.10,.75,.30,math.rad(43)) end
    if variant==2 then return actionAxisPose(arena,attackerSide,focus,fight,-.02,.80,.29,math.rad(43)) end
    return actionAxisPose(arena,attackerSide,focus,fight,.20,.69,.32,math.rad(44))
  elseif kind=="reaction" then
    -- Reactions belong to the affected side, not to a specific model mod. If a
    -- trainer is actually present, keep the Pokemon as the foreground subject
    -- but include the human response so concern/brace/frustration can read.
    local hasTrainer=trainerVisible(ctx,side)
    local tp=hasTrainer and trainerPoint(side,7.0) or a
    local midx=hasTrainer and (a[1]*.68+tp[1]*.32) or a[1]
    local midz=hasTrainer and (a[3]*.68+tp[3]*.32) or a[3]
    local attackerSide=other(side);local focus={midx,6.05,midz}
    local attacker=arenaPoint(arena,attackerSide,6.0)
    local fight=math.max(25,math.sqrt((a[1]-attacker[1])^2+(a[3]-attacker[3])^2)*1.30)
    if variant==1 then return actionAxisPose(arena,attackerSide,focus,fight,.02,.66,.27,math.rad(hasTrainer and 37 or 34)) end
    if variant==2 then return actionAxisPose(arena,attackerSide,focus,fight,.13,.62,.29,math.rad(hasTrainer and 37 or 34)) end
    return actionAxisPose(arena,attackerSide,focus,fight,-.08,.70,.30,math.rad(hasTrainer and 38 or 35))
  elseif kind=="capture" then
    local target=arenaPoint(arena,"enemy",6.0); local hasTrainer=trainerVisible(ctx,"player")
    local tp=hasTrainer and trainerPoint("player",7.0) or target
    local status
    if PlayerTrainer and type(PlayerTrainer.captureStatus)=="function" then
      local ok,v=pcall(PlayerTrainer.captureStatus,PlayerTrainer,ctx)
      if ok and type(v)=="table" and v.active then status=v end
    end
    local phase=status and status.phase or "charge"
    local u=math.max(0,math.min(1,tonumber(status and status.progress) or 0))
    local liveBall=nil
    if PlayerTrainer and type(PlayerTrainer.captureBallPosition)=="function" then
      local ok,v=pcall(PlayerTrainer.captureBallPosition,PlayerTrainer,ctx)
      if ok and type(v)=="table" and tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3]) then liveBall=v end
    end

    -- Build every capture shot from the live trainer->enemy battle axis so the
    -- sequence keeps the same Colosseum screen direction in every arena.
    local dx,dz=target[1]-tp[1],target[3]-tp[3]
    local len=math.max(.001,math.sqrt(dx*dx+dz*dz));local fx,fz=dx/len,dz/len
    local rx,rz=-fz,fx
    local function eyeAt(point,back,side,y)
      return {point[1]-fx*back+rx*side,y,point[3]-fz*back+rz*side}
    end
    local function focusAt(point,y)
      return {point[1],y,point[3]}
    end

    -- Reference order: source hand/ball hold -> tracked side throw -> target
    -- impact/absorb -> tracked fall -> low resting/shake shot -> result. The
    -- live source prop is the focus whenever available, so camera and ball can
    -- no longer disagree about where the throw actually is.
    local ball=liveBall or target
    if phase=="charge" then
      -- Medium over-shoulder rather than an extreme body-centred close-up. This
      -- keeps the authentic small ball readable in the throwing hand.
      return {eye=eyeAt(tp,5.9,7.8,8.4),focus={ball[1],ball[2]+.05,ball[3]},fov=math.rad(31)}
    elseif phase=="throw" then
      local lead={ball[1]+fx*1.65,ball[2]-.10,ball[3]+fz*1.65}
      -- Do not bolt the camera directly to the projectile. A lightly tracking
      -- sideline dolly preserves the trainer->target axis while the ball moves
      -- freely through frame, which reads much closer to an authored battle
      -- shot and avoids the old weightless "camera carrying the ball" look.
      local trackU=.30+.34*u
      local track={tp[1]+dx*trackU,6.0,tp[3]+dz*trackU}
      return {eye=eyeAt(track,7.9,10.0,8.45),focus=lead,fov=math.rad(34)}
    elseif phase=="impact" then
      return {eye=eyeAt(target,13.2,-8.0,8.7),focus={ball[1],ball[2],ball[3]},fov=math.rad(29)}
    elseif phase=="absorb" then
      return {eye=eyeAt(target,11.8,-6.8,7.8),focus={ball[1],ball[2]-.10,ball[3]},fov=math.rad(28)}
    elseif phase=="fall" then
      return {eye=eyeAt(ball,8.6,7.0,5.0),focus={ball[1],ball[2]-.18,ball[3]},fov=math.rad(27)}
    elseif phase=="settle" then
      return {eye=eyeAt(ball,7.4,6.3,3.25),focus={ball[1],ball[2]+.06,ball[3]},fov=math.rad(25)}
    elseif phase=="shake" then
      -- Lock the lens to the LANDING POINT, not to the moving ball. 1.5.61
      -- tracked the ball's lateral wobble with the camera, visually cancelling
      -- the shake. The real source prop now rocks inside a stationary low shot,
      -- so every engine-authored shake count is unmistakable.
      local ground={target[1],.31,target[3]}
      return {eye=eyeAt(ground,5.35,4.55,2.42),focus={ground[1],ground[2]+.08,ground[3]},fov=math.rad(22)}
    elseif phase=="caught" then
      return {eye=eyeAt(ball,7.4,5.8,3.7),focus={ball[1],ball[2]+.04,ball[3]},fov=math.rad(26)}
    elseif phase=="breakout" then
      -- Give the native miss/open prop its own ground beat, then let the frame
      -- travel back up to the re-forming target instead of snapping immediately
      -- from ball to Pokemon.
      local ground={target[1],.31,target[3]}
      if u<.42 then
        return {eye=eyeAt(ground,7.2,5.8,3.15),focus={ground[1],ground[2]+.18,ground[3]},fov=math.rad(26)}
      end
      local q=smooth((u-.42)/.58)
      local focus={ground[1]+(target[1]-ground[1])*q,.55+(5.15-.55)*q,ground[3]+(target[3]-ground[3])*q}
      return {eye=eyeAt(target,10.6,-7.1,6.9),focus=focus,fov=math.rad(29)}
    end
    return {eye=eyeAt(target,12,8,8),focus=focusAt(target,4),fov=math.rad(30)}
  elseif kind=="faint" then
    -- Human reaction is part of the KO, not background dressing. Bias the
    -- composition toward the trainer while retaining the fallen Pokemon in the
    -- foreground, and stay close enough for the arms-up silhouette to read.
    local hasTrainer=trainerVisible(ctx,side)
    local tp=hasTrainer and trainerPoint(side,6.9) or a
    local focusBias=hasTrainer and .62 or 0
    local midx=tp[1]*focusBias+a[1]*(1-focusBias)
    local midz=tp[3]*focusBias+a[3]*(1-focusBias)
    if variant==1 then return {eye={-sgn*(hasTrainer and 28 or 36),15,sgn*8},focus={midx,6.15,midz},fov=math.rad(hasTrainer and 37 or 41)} end
    if variant==2 then return {eye={sgn*(hasTrainer and 25 or 34),15,sgn*10},focus={midx,6.0,midz},fov=math.rad(hasTrainer and 38 or 41)} end
    return {eye={-sgn*(hasTrainer and 21 or 38),18,sgn*5},focus={midx,6.0,midz},fov=math.rad(hasTrainer and 39 or 42)}
  elseif kind=="switch" then
    local hasTrainer=trainerVisible(ctx,side)
    local tp=hasTrainer and trainerPoint(side,7.0) or a
    local midx=hasTrainer and (tp[1]+a[1])*.5 or a[1]
    local midz=hasTrainer and (tp[3]+a[3])*.5 or a[3]
    if variant==1 then return {eye={-sgn*(hasTrainer and 33 or 39),16,sgn*8},focus={midx,6.2,midz},fov=math.rad(hasTrainer and 40 or 44)} end
    if variant==2 then return {eye={sgn*(hasTrainer and 30 or 38),16,sgn*11},focus={midx,6.3,midz},fov=math.rad(hasTrainer and 40 or 44)} end
    return {eye={-sgn*(hasTrainer and 25 or 40),14,sgn*4},focus={midx,5.9,midz},fov=math.rad(hasTrainer and 41 or 45)}
  end
  return {eye={46,20,z+sgn*8},focus={a[1],6,z},fov=math.rad(37)}
end

-- The send-out shot follows the visible trainer's choreography, not the
-- battle message timer. Composition remains a fallback until source camera
-- tracks have been decoded and mapped to this arena's coordinate transform.
local function liveSendoutShot(ctx,arena,requestedSide)
  local chosen,side
  for _,row in ipairs({{Trainer,"enemy"},{PlayerTrainer,"player"}}) do
    local actor=row[1]
    if (not requestedSide or row[2]==requestedSide) and actor and type(actor.sendoutStatus)=="function" then
      local ok,status=pcall(actor.sendoutStatus,actor)
      if ok and status and status.active and (not chosen or status.age<chosen.age) then chosen,side=status,row[2] end
    end
  end
  if not chosen then return nil end
  local pose=eventShot(ctx,arena,side,"switch",1)
  if chosen.ball then
    local tp=trainerPoint(side,6.6)
    local u=math.max(0,math.min(1,(chosen.phase-.31)/.48))
    -- During wind-up include the hand and torso; follow the projectile after release.
    pose.focus={tp[1]+(chosen.ball[1]-tp[1])*u,tp[2]+(chosen.ball[2]-tp[2])*u,tp[3]+(chosen.ball[3]-tp[3])*u}
  end
  return pose,side
end
-- Shared by the four-slot presenter so second throws keep the same hand/ball
-- framing and venue bounds as the initial singles-host sendout.
function C:sendoutShot(ctx,arena,side)
  local pose=liveSendoutShot(ctx,arena,side)
  return pose and clampCameraVolume(hudSafePose(pose,"switch"),arena,"switch") or nil
end
function C:guardPose(pose,arena,phase)
  -- Shared directors (notably the four-battler director) use this boundary too.
  -- Apply the same lower-third protection as singles before venue clamping so a
  -- mobile action camera cannot place the move/receiver underneath touch HUD.
  return clampCameraVolume(hudSafePose(pose,phase),arena,phase)
end
function C:guardFreePose(pose,arena)
  return clampCameraVolume(pose,arena,"free")
end
-- One stable automatic envelope for paced edits across event boundaries. Do not
-- repeatedly add HUD padding, or change the pitch limit on damage/faint handoffs.
function C:guardPacedPose(pose,arena)
  return clampCameraVolume(pose,arena,"attack")
end

local function introShot(ctx)
  local hasEnemy=Trainer and Trainer.shouldRender and Trainer:shouldRender(ctx)
  local hasPlayer=PlayerTrainer and PlayerTrainer.shouldRender and PlayerTrainer:shouldRender(ctx)
  local establish={eye={64,39,27},focus={0,6.1,-1},fov=math.rad(44)}
  local et=trainerPoint("enemy",6.6); local pt=trainerPoint("player",6.6)
  local enemy=hasEnemy and {eye={35,24,et[3]-15.5},focus={et[1]*0.66,6.5,et[3]+5.4},fov=math.rad(39)}
                         or {eye={-47,27,-27},focus={0,6.4,-8},fov=math.rad(39)}
  local player=hasPlayer and {eye={-35,24,pt[3]+15.5},focus={pt[1]*0.66,6.5,pt[3]-5.4},fov=math.rad(39)}
                           or {eye={49,27,27},focus={0,6.4,8},fov=math.rad(39)}
  local battle={eye={62,29,3},focus={0,6.3,0},fov=math.rad(39)}
  local t=state.phaseAge
  if t<0.78 then
    local drift={eye={48,36,44},focus={0,6.25,-1},fov=math.rad(43)}
    return mix(establish,drift,t/0.78)
  elseif t<1.48 then
    return mix({eye={48,36,44},focus={0,6.25,-1},fov=math.rad(43)},enemy,(t-0.78)/0.70)
  elseif t<1.98 then
    return enemy
  elseif t<2.72 then
    return mix(enemy,player,(t-1.98)/0.74)
  elseif t<3.18 then
    return player
  elseif t<3.92 then
    return mix(player,battle,(t-3.18)/0.74)
  end
  return battle
end

local function exitShot(ctx,arena,result)
  result=tostring(result or ""):lower()
  local player=arenaPoint(arena,"player",6.2); local enemy=arenaPoint(arena,"enemy",6.2)
  if result=="lose" or result=="loss" or result=="defeat" then
    local hasTrainer=trainerVisible(ctx,"enemy")
    if not hasTrainer then
      -- Wild/externally-presented opponents have no human victory anchor. Use
      -- a broad result master that keeps winner + fallen player readable
      -- instead of manufacturing a phantom trainer close-up.
      return {eye={46,19,-28},focus={(player[1]+enemy[1])*.5,5.9,(player[3]+enemy[3])*.5},fov=math.rad(45)}
    end
    local tp=trainerPoint("enemy",7.0)
    return {eye={38,19,-32},focus={(tp[1]+enemy[1])*.5,6.2,(tp[3]+enemy[3])*.5},fov=math.rad(40)}
  elseif result=="run" or result=="escape" then
    return {eye={55,25,18},focus={player[1],5.8,player[3]-5},fov=math.rad(42)}
  elseif result=="caught" or result=="capture" or result=="captured" then
    return {eye={42,20,18},focus={enemy[1],5.9,enemy[3]},fov=math.rad(40)}
  end
  local hasTrainer=trainerVisible(ctx,"player")
  if not hasTrainer then
    return {eye={-46,19,28},focus={(player[1]+enemy[1])*.5,5.9,(player[3]+enemy[3])*.5},fov=math.rad(45)}
  end
  local tp=trainerPoint("player",7.0)
  return {eye={-38,19,32},focus={(tp[1]+player[1])*.5,6.2,(tp[3]+player[3])*.5},fov=math.rad(40)}
end

local function targetFor(ctx,phase,base,arena)
  if state.manual then return manualPose() end
  local side=state.eventSide
  local pose
  local speed=battleSpeed(ctx)
  if phase=="attack" then pose=eventShot(ctx,arena,side or "player","attack",state.eventIndex)
  elseif phase=="damage" then pose=eventShot(ctx,arena,side or "enemy","damage",state.eventIndex)
  elseif phase=="reaction" then pose=eventShot(ctx,arena,side or "enemy","reaction",state.eventIndex)
  elseif phase=="capture" then pose=eventShot(ctx,arena,"enemy","capture",state.eventIndex)
  elseif phase=="faint" then pose=eventShot(ctx,arena,side or "enemy","faint",state.eventIndex)
  elseif phase=="intro" then pose=introShot(ctx)
  elseif phase=="exit" then pose=exitShot(ctx,arena,state.eventResult)
  elseif phase=="switch" or (state.special=="switch" and state.time<state.specialUntil) then
    pose=eventShot(ctx,arena,side or "player","switch",state.eventIndex)
  elseif phase=="command" then
    pose=trainerPassiveMaster(ctx) or shotPose(COMMAND_SHOTS[((state.shotOffset or 0)%#COMMAND_SHOTS)+1],1)
  elseif phase=="passive" then
    pose=passiveShot(ctx,arena)
  else
    pose=passiveShot(ctx,arena)
  end
  -- A Pokemon-owned passive shot is battleCameraStartWaza(owner,NULL), and the
  -- source-backed path above has already applied CalculateParams/DoPosition in
  -- the live battle coordinate system. arenaFrame's generic broadcast radius/
  -- height scaling is for reconstructed compositions; applying it here changes
  -- the retail physical cylinder (for example 5 units of sampled height became
  -- 6.2 at the default venue). Keep only the deliberately non-exact lens widen;
  -- final venue safety still clamps impossible camera positions in shot().
  if phase=="passive" and state.passiveSourcePlan
      and state.passiveSourcePlan.physicalFormulaExact==true
      and state.passiveSourceTargetResolved==true then
    -- When the retail DoFOV grammar is also available, its locally sampled lens
    -- already owns the optical result. Do not apply CBE's generic authored-lens
    -- widening on top. If only physical DoPosition is proven, retain the older
    -- deliberately non-exact fallback lens treatment.
    if state.passiveSourcePlan.fovFormulaExact==true then return pose end
    return widenAuthored(pose)
  end
  return widenAuthored(arenaFrame(pose,arena))
end

local function touchManual()
  if not state.manual then
    state.manual=true;state.startPose=copyPose(state.lastPose);state.phaseAge=0
  end
  state.manualIdle=0;state.returning=false
end
local function releaseManual()
  if not state.manual then return end
  state.manual=false;state.manualIdle=0;state.startPose=copyPose(state.lastPose);state.phaseAge=0;state.returning=true
  state.mouseX=nil;state.mouseY=nil
end
local function updateMouse()
  if not (love and love.mouse and love.mouse.getPosition) then state.mouseX=nil;state.mouseY=nil;return false end
  local x,y=love.mouse.getPosition()
  if state.mouseX==nil then state.mouseX=x;state.mouseY=y;return false end
  local dx,dy=x-state.mouseX,y-state.mouseY;state.mouseX,state.mouseY=x,y
  if dx==0 and dy==0 then return false end
  local dragging=mouseDown(1) or mouseDown(2) or mouseDown(3)
  if not dragging then return false end
  touchManual()
  if mouseDown(1) then
    state.orbit=state.orbit-dx*0.0075;state.elevation=state.elevation-dy*0.0058
  elseif mouseDown(2) then
    if isDown("lshift") or isDown("rshift") then state.fov=state.fov+dy*0.12 else state.radius=state.radius+dy*0.28 end
  elseif mouseDown(3) then
    local pan=state.radius*0.0025;local rx,rz=math.cos(state.orbit),-math.sin(state.orbit);local fx,fz=math.sin(state.orbit),math.cos(state.orbit)
    state.focus[1]=state.focus[1]-dx*pan*rx+dy*pan*0.18*fx;state.focus[3]=state.focus[3]-dx*pan*rz+dy*pan*0.18*fz;state.focus[2]=state.focus[2]+dy*0.025
  end
  return true
end
local function keyboardCameraActive()
  return isDown("j") or isDown("l") or isDown("i") or isDown("k") or isDown("u") or isDown("o") or isDown("n") or isDown("m")
end
local function clampManual()
  state.elevation=clamp(state.elevation,0.08,1.16);state.radius=clamp(state.radius,26,135);state.fov=clamp(state.fov,22,74)
  state.focus[1]=clamp(state.focus[1],-42,42);state.focus[2]=clamp(state.focus[2],1.5,22);state.focus[3]=clamp(state.focus[3],-42,42)
end

local function requestedPhase(name,ctx)
  if name=="battle.move_used" or name=="battle.presentation_move" then return "attack" end
  if name=="battle.damage_dealt" or name=="battle.presentation_damage" then return "damage" end
  if name=="battle.status_inflicted" then return "reaction" end
  if name=="battle.ball_thrown" then return "capture" end
  if name=="battle.exp_gained" then return nil end
  if name=="battle.fainted" or name=="battle.presentation_faint" then return "faint" end
  if name=="battle.battler_switched" then return "switch" end
  if name=="battle.turn_started" or name=="battle.turn_ended" then return "passive" end
  if name=="battle.ended" then return "exit" end
  local p=ctx and ctx.phase
  if p=="intro" or p=="command" or p=="passive" or p=="exit" then return p end
  return state.phase
end

local function eventSideFor(ctx,name,payload)
  -- Shot ownership is explicit in v8:
  --   move_used -> actor, damage/faint -> affected battler, switch -> switched side.
  -- Damage payloads are not guaranteed to expose `user`; resolving the target
  -- first avoids the old fallback that occasionally cut to the attacker's side.
  if name=="battle.move_used" or name=="battle.presentation_move" then
    return sideFrom(ctx,payload,{"user","attacker","source","battler","side"})
  elseif name=="battle.damage_dealt" or name=="battle.presentation_damage" then
    local target=sideFrom(ctx,payload,{"target","defender","targetSide","defenderSide","battler"})
    if target then return target end
    local actor=sideFrom(ctx,payload,{"user","attacker","source","side"})
    return actor and other(actor) or nil
  elseif name=="battle.status_inflicted" then
    return sideFrom(ctx,payload,{"target","battler","side","targetSide","source"})
  elseif name=="battle.ball_thrown" then
    return "enemy"
  elseif name=="battle.fainted" or name=="battle.presentation_faint" then
    return sideFrom(ctx,payload,{"battler","target","side","faintedSide","targetSide"})
  elseif name=="battle.battler_switched" then
    return sideFrom(ctx,payload,{"side","battler","target","switchedSide"})
  end
  return sideFrom(ctx,payload)
end

local function acceptEvent(ev)
  if not ev then return end
  local previousPhase=state.phase
  state.startPose=copyPose(state.lastPose)
  state.phase=ev.phase or state.phase
  state.phaseAge=0
  if ev.side then state.eventSide=ev.side end
  -- Establish one screen side for the full move sentence. Damage/reaction keep
  -- the sign selected by the attack; an orphan impact (for example a host that
  -- exposes no move-used event) establishes the same axis from its defender.
  if state.phase=="attack" then
    state.actionAxisAttacker=ev.side or state.eventSide or "player";state.actionAxisSign=nil
  elseif state.phase=="damage" and previousPhase~="attack" then
    state.actionAxisAttacker=other(ev.side or state.eventSide or "enemy");state.actionAxisSign=nil
  elseif state.phase=="capture" or state.phase=="switch" or state.phase=="exit" then
    state.actionAxisAttacker=nil;state.actionAxisSign=nil
  end
  if ev.indexed then
    -- One attack, its impact, and the optional trainer reaction are one camera
    -- sentence. Reusing the same variant keeps all three beats on the same
    -- side of the action axis instead of cycling to a new camera every event.
    local continuation=(state.phase=="damage" and previousPhase=="attack")
      or (state.phase=="reaction" and (previousPhase=="damage" or previousPhase=="attack"))
    if not continuation then state.eventIndex=state.eventIndex+1 end
  end
  state.lastCutTime=state.time
  state.lastEventName=ev.name
  local speed=battleSpeed(ev.ctx)
  state.logicSpeed=speed
  state.shotLockUntil=state.time+(EVENT_HOLDS[state.phase] or 0.55)*holdScale(speed)
  if state.phase=="switch" then
    state.special="switch";state.specialUntil=state.shotLockUntil
  end
end

local function queueEvent(ev)
  local nextPriority=EVENT_PRIORITY[ev.phase] or 0
  local age=state.time-state.lastCutTime

  -- Treat one move as an authored three-beat sequence instead of a generic
  -- priority queue: command/attack -> impact -> KO. Damage is the best timing
  -- signal we receive for impact, so it is allowed to take ownership as soon
  -- as the attack shot has actually registered on screen. A faint can then
  -- take ownership after the impact has had a short readable beat.
  local impactBeat = ev.phase=="damage" and state.phase=="attack" and age>=0.72
  local hardEnd = ev.phase=="exit" and age>=MIN_INTERRUPT_AGE
  if impactBeat or hardEnd then
    acceptEvent(ev)
    state.pendingEvent=nil
    return
  end

  local pending=state.pendingEvent
  if not pending or nextPriority>(EVENT_PRIORITY[pending.phase] or 0)
      or (nextPriority==(EVENT_PRIORITY[pending.phase] or 0) and ev.phase~="passive") then
    state.pendingEvent=ev
  end
end

function C:begin(ctx)
  state.comfort=nil;state.comfortMaster=nil
  state.time=0;state.idleClock=0;state.phaseAge=0;state.phase="intro";state.eventSide=nil;state.eventIndex=0;state.eventResult=nil;state.resultPending=nil;state.resultAt=0
  state.lastPose=nil;state.startPose=nil;state.displayPose=nil;state.displayClock=nil;state.special=nil;state.specialUntil=0
  state.shotLockUntil=0;state.pendingEvent=nil;state.lastCutTime=-999;state.lastEventName=nil;state.logicSpeed=battleSpeed(ctx)
  state.sourcePose=nil;state.sourceIdentity=nil;state.sourcePoseAt=0;state.sourceHandoff=nil;state.sourceHandoffAt=0
  state.actionAxisAttacker=nil;state.actionAxisSign=nil
  local hash=battleHash(ctx);state.shotOffset=hash%#PASSIVE_SHOTS
  local candidates=passiveCandidates(ctx)
  state.passiveShotIndex=candidates[(hash%#candidates)+1] or 1
  state.passiveShotAge=0;state.passiveTimer=PASSIVE_RANDOM_INTERVAL;state.passiveRng=hash+1
  state.passiveSourcePlan=nil;state.passiveSourceTargetResolved=false
  state.passiveFloorFallbackActive=false;state.passiveFloorFallbackMoving=false
  -- Initial passive motion is deterministic without consuming the local RNG;
  -- subsequent successful owner starts consume RNG exactly where retail would.
  state.passiveMotionMode=PASSIVE_MOTIONS[(hash%#PASSIVE_MOTIONS)+1]
  state.passiveLastMotionMode=state.passiveMotionMode
  state.manual=false;state.manualLocked=false;state.manualIdle=0;state.returning=false;resetManual()
end
function C:update(ctx,dt)
  dt=tonumber(dt) or 0
  if dt~=dt or math.abs(dt)==math.huge then dt=0 end
  local speed=battleSpeed(ctx)
  state.logicSpeed=speed
  -- Native hosts call this on each accelerated fixed step. Compensate that
  -- speed for CAMERA timers only. Actors, MoveFX, PP and native turn processing
  -- continue to consume their original dt in their respective owners.
  local cameraDt=math.max(0,math.min(.25,dt))
  if Pacing then cameraDt=cameraDt/speed end
  state.time=state.time+cameraDt
  state.phaseAge=state.phaseAge+cameraDt

  -- Win/loss/run/capture is committed on BattleState.result BEFORE the battle
  -- screen tears down and before battle.ended is emitted. Observe that native
  -- result directly so the final composition is visible while victory/blackout
  -- text is still on screen. This is intentionally engine-state driven: no
  -- model, animation or companion mod has to tell CBE that the battle ended.
  local b=battleOf(ctx)
  local result=b and b.result
  if result~=nil then result=tostring(result):lower() end
  if result and result~="" and result~=state.eventResult and result~=state.resultPending then
    state.resultPending=result
    local faintInFlight=state.phase=="faint"
      or (state.pendingEvent and state.pendingEvent.phase=="faint")
    -- Let the actual KO read before moving to the victory/defeat master. Runs
    -- and captures have no faint beat and can transition much sooner.
    local resultDelay=faintInFlight and 1.35 or 0.22
    if faintInFlight and BattleDirector and type(BattleDirector.faintDuration)=="function" then
      local side=(state.pendingEvent and state.pendingEvent.phase=="faint" and state.pendingEvent.side) or state.eventSide
      local ok,fd=pcall(BattleDirector.faintDuration,BattleDirector,ctx,side)
      if ok and tonumber(fd) then
        -- Never abandon an authored faint clip for the victory/defeat master.
        -- The short removal tail is part of Actor:terminalDuration(), so this
        -- cut lands only after the complete source collapse has actually read.
        resultDelay=math.max(resultDelay,tonumber(fd)+.10)
      end
    end
    -- Result delay is presentation-time. Battle fast-forward may resolve the
    -- result sooner, but the KO/result composition remains human-readable.
    state.resultAt=state.time+resultDelay
  end
  -- The authored opening is a presentation-time sequence, not a battle-state
  -- phase. Gen1Recomp can remain in intro/messages until the user dismisses
  -- text, so waiting for turn_started leaves the camera parked forever on the
  -- final intro angle. Hand control to the passive/menu master once the opening
  -- has actually played; the opening itself remains presentation-time stable.
  if state.phase=="intro" and state.phaseAge>=4.20 then
    state.startPose=copyPose(state.lastPose)
    state.phase="passive";state.phaseAge=0;state.idleClock=0
    state.lastCutTime=state.time;state.lastEventName="intro.complete";state.shotLockUntil=0
  end
  if state.phase=="passive" then
    state.idleClock=state.idleClock+cameraDt
    state.passiveShotAge=state.passiveShotAge+cameraDt
    local passive=PASSIVE_SHOTS[state.passiveShotIndex] or PASSIVE_SHOTS[1]
    local duration=(state.passiveSourcePlan and state.passiveSourcePlan.durationExact
      and tonumber(state.passiveSourcePlan.durationSeconds)) or (passive and passive.hold or 0)
    local motionActive=passive and state.passiveShotAge<duration
    if motionActive then
      -- The retail passive owner is itself a Waza camera. battleCameraStartRandom
      -- observes fn_801D2C6C()!=NULL during that motion and restores the complete
      -- 200-frame countdown every frame. The next owner therefore cannot preempt
      -- a slow pan/dolly halfway through.
      state.passiveTimer=PASSIVE_RANDOM_INTERVAL
    else
      state.passiveTimer=state.passiveTimer-cameraDt
      if state.passiveTimer<=0 then
        -- Once the finite owner camera has released, retail checks every 200
        -- source frames, gates at 50%, and starts a DIFFERENT owner on success.
        state.passiveTimer=PASSIVE_RANDOM_INTERVAL
        if nextPassiveRandom()<=PASSIVE_RANDOM_GATE then chooseDifferentPassiveShot(ctx) end
      end
    end
  elseif state.phase=="command" then
    state.passiveFloorFallbackActive=false;state.passiveFloorFallbackMoving=false
    state.idleClock=state.idleClock+cameraDt
    -- Command UI may use its restrained master variants, but does not consume
    -- the passive random-owner countdown behind the player's choices.
    state.passiveTimer=PASSIVE_RANDOM_INTERVAL
  else
    state.passiveFloorFallbackActive=false;state.passiveFloorFallbackMoving=false
    -- battleCameraStartRandom restores the 200-frame countdown every frame while
    -- Waza/other authored camera ownership is active. Do the same across action,
    -- capture, switch, faint and result cinematics.
    state.passiveTimer=PASSIVE_RANDOM_INTERVAL
  end
  if state.special and state.time>=state.specialUntil then state.special=nil end
  local captureStillActive=false
  if state.phase=="capture" and PlayerTrainer and type(PlayerTrainer.captureStatus)=="function" then
    local okCapture,captureStatus=pcall(PlayerTrainer.captureStatus,PlayerTrainer,ctx)
    captureStillActive=okCapture and type(captureStatus)=="table" and captureStatus.active==true
  end
  -- Capture owns the lens until its final shake/outcome beat has actually
  -- finished. In successful catches BattleState.result / battle.ended can be
  -- known almost immediately; allowing higher-priority exit events through
  -- here was the camera tell that revealed success the instant the ball left
  -- Red's hand. Queue everything non-capture behind the authored sequence.
  local pendingBlockedByCapture=captureStillActive and state.pendingEvent
    and state.pendingEvent.phase~="capture"
  if state.pendingEvent and not pendingBlockedByCapture and state.time>=state.shotLockUntil and state.time>=(state.pendingEvent.notBefore or 0) then
    local ev=state.pendingEvent;state.pendingEvent=nil;acceptEvent(ev)
  elseif not captureStillActive and not state.pendingEvent and state.time>=state.shotLockUntil and state.shotLockUntil>0
      and (state.phase=="attack" or state.phase=="damage" or state.phase=="reaction" or state.phase=="capture" or state.phase=="faint" or state.phase=="switch") then
    -- One-shot cinematic beats must relinquish the camera. Older builds left
    -- the director permanently parked on the last damaged/fainted Pokemon
    -- until another semantic event happened. Return to a held passive owner
    -- composition immediately after the readable hold.
    state.startPose=copyPose(state.lastPose)
    state.phase="passive";state.phaseAge=0;state.idleClock=0
    state.lastCutTime=state.time;state.lastEventName="auto.return";state.shotLockUntil=0
  end
  if state.resultPending and state.time>=state.resultAt and not captureStillActive then
    local committed=state.resultPending
    state.resultPending=nil;state.eventResult=committed
    -- battle.ended may already have been queued behind capture ownership. If it
    -- became the exit shot above, do not immediately restart the same camera
    -- blend from a duplicate BattleState.result observation.
    if state.phase~="exit" then
      state.pendingEvent=nil
      acceptEvent({name="battle.result",phase="exit",side=nil,indexed=false,ctx=ctx})
    end
  end
  -- The decision-only controller replaces unrestricted legacy mouse input.
  if V.FreeLookCamera then state.manualLocked=false;releaseManual();return end
  if pressed("f8") then
    state.manualLocked=not state.manualLocked
    if state.manualLocked then touchManual() else releaseManual() end
    state.mouseX=nil;state.mouseY=nil
  end
  if pressed("home") then resetManual() end
  local mouseMoved=updateMouse();local keyboardActive=keyboardCameraActive();if keyboardActive then touchManual() end
  if state.manual then
    local turn=1.35*cameraDt;local lift=0.90*cameraDt;local zoom=44*cameraDt;local lens=32*cameraDt
    if isDown("j") then state.orbit=state.orbit-turn end;if isDown("l") then state.orbit=state.orbit+turn end
    if isDown("i") then state.elevation=state.elevation+lift end;if isDown("k") then state.elevation=state.elevation-lift end
    if isDown("u") then state.radius=state.radius-zoom end;if isDown("o") then state.radius=state.radius+zoom end
    if isDown("n") then state.fov=state.fov-lens end;if isDown("m") then state.fov=state.fov+lens end
    clampManual()
    if state.manualLocked or mouseMoved or keyboardActive or mouseDown(1) or mouseDown(2) or mouseDown(3) then
      state.manualIdle=0
    else
      state.manualIdle=state.manualIdle+cameraDt;if state.manualIdle>=MANUAL_RELEASE_DELAY then releaseManual() end
    end
  end
end
function C:event(ctx,name,payload)
  -- move_used and damage_dealt are separate cinematic beats. Earlier builds
  -- discarded rapid damage events entirely, which is why some impacts never
  -- received a camera cut. The scheduler now preserves the impact and simply
  -- delays it until the attack shot has been readable.
  -- Gen 2 resolves its model before replaying the screen queue. Ignore that
  -- early semantic move event and cut only when StandaloneHost reports the
  -- corresponding visible queue row. Gen 1 keeps its native move boundary.
  local gen2=ctx and ctx.battle and ctx.battle.__cbeGeneration==2
  local queueSync=ctx and ctx.battle and ctx.battle.__cbePresentationQueueSync==true
  if queueSync and ((gen2 and (name=="battle.move_used" or name=="battle.damage_dealt" or name=="battle.fainted"))
      or ((not gen2) and name=="battle.fainted")) then return end
  local phase=requestedPhase(name,ctx)
  if not phase then return end
  local speed=battleSpeed(ctx)
  state.logicSpeed=speed
  if name=="battle.ended" and type(payload)=="table" then state.eventResult=payload.result or payload.outcome end
  -- Fast-forward can deliver several semantic beats between rendered frames,
  -- but they still belong to the same authored sequence. The scheduler below
  -- coalesces genuinely superseded events; speed itself never deletes a shot.
  if not phaseAllowedAtSpeed(phase,speed) then return end
  -- Variant ownership advances once per authored action, not once per queue
  -- notification. Damage/status/faint belong to the same move camera axis as
  -- the attack that caused them. Incrementing on every sub-event made a single
  -- move jump through several unrelated angles and was especially chaotic when
  -- 4X delivered all of those notifications in one rendered frame.
  local indexed=name=="battle.move_used" or name=="battle.presentation_move"
    or name=="battle.ball_thrown" or name=="battle.battler_switched"
  local ev={name=name,phase=phase,side=eventSideFor(ctx,name,payload),indexed=indexed,ctx=ctx}
  -- Gen1Recomp emits the faint semantic state before the complete visual fall
  -- has necessarily finished. Hold the impact composition briefly, then move
  -- to the trainer reaction instead of cutting on move selection / early KO.
  if phase=="faint" then
    local delay=.32
    if BattleDirector and type(BattleDirector.faintDuration)=="function" and ev.side then
      local ok,fd=pcall(BattleDirector.faintDuration,BattleDirector,ctx,ev.side)
      if ok and tonumber(fd) then delay=math.max(.14,math.min(.48,tonumber(fd)*.14)) end
    end
    ev.notBefore=state.time+delay
  end

  -- A successful wild catch can publish battle.ended/result before the CBE
  -- capture presentation has reached its reveal. Never let that already-known
  -- engine result select a different lens path. Defer exit behind the exact
  -- same throw/impact/absorb/fall/shake camera used by a failed catch.
  local captureOwnsLens=false
  if phase=="exit" and PlayerTrainer and type(PlayerTrainer.captureStatus)=="function" then
    local okCapture,captureStatus=pcall(PlayerTrainer.captureStatus,PlayerTrainer,ctx)
    captureOwnsLens=okCapture and type(captureStatus)=="table" and captureStatus.active==true
  end

  -- Intro owns its authored sequence until actual battle events begin.
  -- After that, inputs merely advancing text/menus cannot reset the camera:
  -- only semantic battle events enter this scheduler.
  if captureOwnsLens then
    queueEvent(ev)
  elseif state.time<state.shotLockUntil or (ev.notBefore and state.time<ev.notBefore) then
    queueEvent(ev)
  else
    acceptEvent(ev)
  end

  -- A major hit gets one human reaction beat after the impact. This is derived
  -- only from authoritative battle damage/max-HP data; external animation mods
  -- never need to expose their own notions of recoil or expression.
  if (name=="battle.damage_dealt" or name=="battle.presentation_damage") and ev.side and trainerVisible(ctx,ev.side) and type(payload)=="table" then
    local damage=tonumber(payload.damage or payload.amount or payload.hpDamage) or 0
    local target=payload.target or payload.defender or payload.battler
    local mon=type(target)=="table" and (target.mon or target) or nil
    local maxHp=mon and (tonumber(mon.maxHp) or tonumber(mon.maxHP) or (mon.stats and tonumber(mon.stats.hp))) or nil
    if damage>0 and maxHp and maxHp>0 and damage/maxHp>=0.24 then
      local reaction={name="battle.major_damage_reaction",phase="reaction",side=ev.side,indexed=false,notBefore=state.time+0.56,ctx=ctx}
      local pending=state.pendingEvent
      if not pending or (EVENT_PRIORITY[pending.phase] or 0)<=(EVENT_PRIORITY.reaction or 0) then state.pendingEvent=reaction end
    end
  end
end
function C:claim(ctx,phase)
  return phase=="passive" or phase=="intro" or phase=="command" or phase=="attack" or phase=="damage" or phase=="reaction" or phase=="capture" or phase=="faint" or phase=="switch" or phase=="exit"
end
function C:shot(ctx,phase,progress,base,arena)
  -- `phase` is the host's latest queue phase, not an instruction to cut.
  -- The event scheduler above is the sole owner of automatic shot changes.
  local activePhase=state.phase
  local target=targetFor(ctx,activePhase,base,arena);local pose
  -- The released-owner floor substitute only translates the already-resolved
  -- source cylinder; keep that cylinder on the same transform path so the first
  -- cooldown frame cannot jump through arenaFrame/readability scaling. Its
  -- translation itself remains explicitly non-exact in status().
  local sourcePhysicalPassive=activePhase=="passive" and state.passiveSourcePlan
    and state.passiveSourcePlan.physicalFormulaExact==true
    and state.passiveSourceTargetResolved==true
  local sendoutTarget
  if not state.manual and (activePhase=="intro" or activePhase=="switch" or activePhase=="passive" or activePhase=="command") then
    sendoutTarget=liveSendoutShot(ctx,arena)
    if sendoutTarget then target=sendoutTarget end
  end
  -- Waza phase framing follows the active effect and its live attachments.
  -- Supported embedded HSD Waza cameras now own this interface directly; the
  -- compositions below remain source-informed fallbacks for procedural roots or
  -- embedded transform/channel cases whose retail mapping is not yet proven.
  local wh=V and V.WazaHandlers
  local sourceOwnsLens=false
  local sourceExactLens=false
  if wh and type(wh.cameraPose)=="function" and not state.manual and (activePhase=="attack" or activePhase=="damage") then
    local previousSource=state.sourcePose and copyPose(state.sourcePose) or nil
    local ok,sourcePose=pcall(wh.cameraPose,ctx)
    if ok and validSourcePose(sourcePose) then
      local sourceRetailExact=sourcePose.sourceCameraEmbeddedDecoded==true
        and sourcePose.sourceCameraRetailFrameExact==true
        and sourcePose.sourceCameraEmbeddedTransformUnsupported==nil
      local speed=battleSpeed(ctx)
      -- The raw director retains the decoded frame. The final CameraPacing
      -- layer preserves it at 1x, but deliberately adapts its optics at fast
      -- battle speeds rather than replaying every source hard cut faster.
      sourceExactLens=sourceRetailExact
      target=stableSourcePose(sourcePose,sourceRetailExact,speed)
      sourceOwnsLens=true
      state.sourceHandoff=nil;state.sourceHandoffAt=0
      -- Source chapters own their held composition directly. `stableSourcePose`
      -- already limits live attachment/lens motion in wall-clock units; applying
      -- the generic semantic blend again would pull frame two back toward the
      -- pre-attack master immediately after the chapter's intentional cut.
    else
      -- A finished/missing source chapter must not leave a stale interpolation
      -- origin for the next effect within the same semantic attack phase. Preserve
      -- the last source composition briefly as an explicit handoff origin instead
      -- of snapping straight back to the semantic fallback master.
      if previousSource and not state.sourceHandoff then
        state.sourceHandoff=previousSource;state.sourceHandoffAt=state.time
      end
      state.sourcePose=nil;state.sourceIdentity=nil;state.sourcePoseAt=state.time
    end
  else
    if state.sourcePose and (activePhase=="attack" or activePhase=="damage") and not state.sourceHandoff then
      state.sourceHandoff=copyPose(state.sourcePose);state.sourceHandoffAt=state.time
    end
    state.sourcePose=nil;state.sourceIdentity=nil;state.sourcePoseAt=state.time
  end
  -- Proven embedded retail cameras own the final optical composition. Generic
  -- mobile-HUD, readability and venue-volume guards are CBE safety heuristics;
  -- applying them here would turn exact decoded eye/focus/FOV samples back into
  -- approximations. Unsupported/procedural source cameras still use the guards.
  if not sourceExactLens and not sourcePhysicalPassive then
    target=hudSafePose(target,activePhase)
    target=readabilityGuard(target,arena,activePhase,state.eventSide,sourceOwnsLens)
  end
  if state.manual then
    if state.phaseAge<0.24 and state.startPose then pose=mix(state.startPose,target,state.phaseAge/0.24) else pose=target end
  elseif state.returning then
    pose=mix(state.startPose or base,target,state.phaseAge/AUTO_RETURN_BLEND);if state.phaseAge>=AUTO_RETURN_BLEND then state.returning=false end
  elseif activePhase=="intro" then
    pose=mix(state.startPose or base,target,state.phaseAge/0.34)
  elseif activePhase=="passive" or activePhase=="command" then
    if state.startPose and state.phaseAge<0.72 then pose=mix(state.startPose,target,state.phaseAge/0.72) else pose=target end
  elseif sourceOwnsLens then
    pose=target
  elseif state.sourceHandoff and state.time-state.sourceHandoffAt<0.34 then
    -- When a decoded Waza chapter relinquishes the lens before the next semantic
    -- event arrives, blend from the final source frame. Reusing phaseAge here can
    -- be effectively instantaneous because the attack phase may already be old.
    pose=mix(state.sourceHandoff,target,(state.time-state.sourceHandoffAt)/0.34)
  else
    -- Semantic fallback compositions retain presentation-time easing. Decoded
    -- source Waza chapters bypass this path and are already rate-limited above.
    pose=mix(state.startPose or base,target,state.phaseAge/0.46)
  end
  -- Blending starts from the host base/previous shot. On compact venues that
  -- intermediate pose can itself lie outside the legal bowl even when the target
  -- is safe (Pyrite's old intro began in the spectator balcony for this reason).
  -- Re-apply the venue volume to the FINAL blended pose before the renderer sees it.
  if not sourceExactLens and not sourcePhysicalPassive then pose=clampCameraVolume(pose,arena,activePhase) end
  if state.sourceHandoff and state.time-state.sourceHandoffAt>=0.34 then state.sourceHandoff=nil;state.sourceHandoffAt=0 end
  pose=presentPose(pose,sourceExactLens or sourcePhysicalPassive,state.manual)
  if not sourceExactLens and not sourcePhysicalPassive then pose=clampCameraVolume(pose,arena,activePhase) end
  state.lastPose=copyPose(pose);return pose,nil
end
-- Fast-forward presentation policy requested after RC1. At 4x+ an ordinary
-- attack/impact/reaction sentence shares a broad two-battler composition. Sends,
-- faints, captures and results still select their meaningful current target,
-- but every edit travels on the same bounded real-time output layer.
if Pacing then
local directedShot=C.shot
function C:shot(ctx,phase,progress,base,arena)
  local previous=state.lastPose and copyPose(state.lastPose)
  local pose,extra=directedShot(self,ctx,phase,progress,base,arena)
  if not (Pacing and pose) then return pose,extra end
  local speed=battleSpeed(ctx);local cfg=Pacing.config(speed)
  if ctx and ctx.__cbeBossCameraComfort then
    state.comfort=ctx.__cbeBossCameraComfort;ctx.__cbeBossCameraComfort=nil
  end
  local active=state.phase
  if cfg.wide and not state.manual and (active=="attack" or active=="damage" or active=="reaction" or active=="passive" or active=="command") then
    if not state.comfortMaster then
      -- Bind orientation once, so opposing moves do not reverse the action axis.
      state.comfortMaster=copyPose(base)
    end
    local a=arenaPoint(arena,"player",6);local b=arenaPoint(arena,"enemy",6)
    local f={(a[1]+b[1])*.5,6,(a[3]+b[3])*.5}
    local origin=state.comfortMaster;local dx,dz=origin.eye[1]-origin.focus[1],origin.eye[3]-origin.focus[3]
    local length=math.max(.001,math.sqrt(dx*dx+dz*dz))
    local separation=math.sqrt((a[1]-b[1])^2+(a[3]-b[3])^2)
    local range=math.max(length,separation*.95/math.max(.56,cameraAspect()))
    pose={eye={f[1]+dx/length*range,f[2]+math.max(9,range*.34),f[3]+dz/length*range},focus=f,fov=math.rad(49),curve=0}
    pose=clampCameraVolume(hudSafePose(pose,"command"),arena,"command")
  end
  local group=cfg.wide and (active=="attack" or active=="damage" or active=="reaction" or active=="passive" or active=="command")
  local key=group and "combat-group" or (tostring(active)..":"..tostring(state.eventIndex)..":"..tostring(state.sourceIdentity or ""))
  local critical=active=="capture" or active=="faint" or active=="switch" or active=="exit"
  if state.manual then state.comfort=nil;return pose,extra end
  local out
  if cfg.active then pose=self:guardPacedPose(pose,arena) end
  out,state.comfort=Pacing.apply(state.comfort,pose,{speed=speed,clock=state.time,clockIsPresentation=true,
    key=key,critical=critical,seed=previous or self:guardPacedPose(base,arena)})
  if out then
    -- Normal source samples remain untouched; adapted output is explicitly
    -- non-exact. A volume constraint remains sovereign on compact arenas.
    if state.comfort.adapted and cfg.active then out=Pacing.constrain(state.comfort,self:guardPacedPose(out,arena)) end
    state.comfort.output=copyPose(out);state.lastPose=copyPose(out);state.displayPose=copyPose(out)
    return out,extra
  end
  return pose,extra
end
end -- CameraPacing: older hosts/standalone raw-director fixtures retain C.shot.
function C:finish(ctx,reason)
  state.comfort=nil;state.comfortMaster=nil
  state.lastPose=nil;state.startPose=nil;state.displayPose=nil;state.displayClock=nil;state.mouseX=nil;state.mouseY=nil;state.special=nil
  state.pendingEvent=nil;state.resultPending=nil;state.resultAt=0;state.shotLockUntil=0;state.lastCutTime=-999;state.lastEventName=nil
  state.sourcePose=nil;state.sourceIdentity=nil;state.sourcePoseAt=0;state.sourceHandoff=nil;state.sourceHandoffAt=0
  state.actionAxisAttacker=nil;state.actionAxisSign=nil
  state.passiveShotAge=0;state.passiveTimer=PASSIVE_RANDOM_INTERVAL;state.passiveMotionMode=2;state.passiveLastMotionMode=nil
  state.passiveSourcePlan=nil;state.passiveSourceTargetResolved=false
  state.passiveFloorFallbackActive=false;state.passiveFloorFallbackMoving=false
  state.manual=false;state.manualLocked=false;state.manualIdle=0;state.returning=false
end
function C:status()
  local passive=PASSIVE_SHOTS[state.passiveShotIndex]
  local source=state.passiveSourcePlan
  local passiveDuration=(source and source.durationExact and tonumber(source.durationSeconds))
    or (passive and (passive.hold or 0) or 0)
  return {manual=state.manual,manualLocked=state.manualLocked,manualIdle=state.manualIdle,radius=state.radius,elevation=state.elevation,fov=state.fov,focus=copy3(state.focus),idleShots=#PASSIVE_SHOTS,commandShots=#COMMAND_SHOTS,idleAxisCuts=true,director="colosseum-semantic-director-v22-hsd-passive-rng",shotOffset=state.shotOffset,eventIndex=state.eventIndex,authoredZoomOut=AUTHORED_ZOOM_OUT,phase=state.phase,eventSide=state.eventSide,shotLockRemaining=math.max(0,state.shotLockUntil-state.time),pendingEvent=state.pendingEvent and state.pendingEvent.phase or nil,lastEvent=state.lastEventName,eventResult=state.eventResult,resultPending=state.resultPending,logicSpeed=state.logicSpeed,clock=Pacing and "speed-compensated-presentation" or "battle-fixed-step-speed-coherent",highSpeedMaster=state.comfort and state.comfort.wide==true or false,cameraComfort=state.comfort and state.comfort.adapted==true or false,cameraComfortEdits=state.comfort and state.comfort.edits or 0,cameraComfortHold=state.comfort and state.comfort.hold or 0,mobileHudSafe=true,safeVolumes=true,subjectReadabilityGuard=true,sourceEyeSpeed=30,sourceFocusSpeed=22,sourceFovSpeed=24,sourceHandoff=state.sourceHandoff~=nil,actionAxisAttacker=state.actionAxisAttacker,actionAxisSign=state.actionAxisSign,passiveShotIndex=state.passiveShotIndex,passiveOwner=passive and passive.owner or nil,passiveShotAge=state.passiveShotAge,passiveMotionMode=state.passiveMotionMode,passiveLastMotionMode=state.passiveLastMotionMode,passiveMotionDuration=passiveDuration,passiveMotionActive=state.phase=="passive" and state.passiveShotAge<passiveDuration,passiveFloorFallbackActive=state.passiveFloorFallbackActive==true,passiveFloorFallbackMoving=state.passiveFloorFallbackMoving==true,passiveFloorFallbackExact=false,passiveFloorFallbackKind="finite-camera-right-truck",passiveFloorFallbackDuration=PASSIVE_FLOOR_SETTLE_DURATION,passiveTimer=state.passiveTimer,passiveRandomInterval=PASSIVE_RANDOM_INTERVAL,passiveRandomGate=PASSIVE_RANDOM_GATE,passiveRngAlgorithm="GC6E01 HSD 0x343FD+0x269EC3 high16/65536",passiveRngAlgorithmExact=true,passiveRngSeedExact=false,passiveFallbackTableExact=PASSIVE_FALLBACK_TABLE_EXACT,commandFallbackTableExact=COMMAND_FALLBACK_TABLE_EXACT,retailFloorCameraAnimationId=RETAIL_FLOOR_CAMERA_ANIMATION_ID,retailFloorCameraAnimationIdExact=true,retailFloorCameraResourceId=RETAIL_FLOOR_CAMERA_ANIMATION_ID,retailFloorCameraResourceIdExact=true,retailFloorCameraResourceKeySource="GC6E01 FSYS nameHash/loadMode",retailFloorCameraAnimationRate=RETAIL_FLOOR_CAMERA_ANIMATION_RATE,retailFloorCameraAnimationRateExact=true,retailFloorCameraFramesPerSecond=30,retailFloorCameraRestoreFrameExact=true,retailFloorCameraLoopExact=true,retailFloorCameraOffsetTransformExact=true,retailFloorCameraOffsetTransformRuntimeApplied=false,retailFloorCameraOffsetScaleExact=true,retailFloorCameraOffsetPositionExact=true,retailFloorCameraOffsetRotationExact=true,retailFloorCameraWorldUpExact=true,retailFloorCameraRuntimePlaybackActive=false,retailFloorCameraPoseExact=false,retailFloorCameraPoseBlocker="CBE PKX presentation normalization/custom anchors no longer share the retail floor/grid affine",passiveSourceMotionSet="3/0/1/2",passiveSourceAngleFormulaExact=source and source.angleFormulaExact==true or false,passiveSourceAngleRngExact=source and source.angleRngExact==true or false,passiveSourcePhysicalFormulaExact=source and source.physicalFormulaExact==true or false,passiveSourceScaleSelector=source and source.selector or nil,passiveSourceOwnerYaw=source and source.ownerYaw or nil,passiveSourceReverse=source and source.reverse or nil,passiveSourceTargetField=source and source.targetField or nil,passiveSourceTargetFieldExact=source and source.targetFieldExact==true or false,passiveSourceTargetResolved=state.passiveSourceTargetResolved==true,passiveSourceRadiusExact=source and source.radiusAbsoluteExact==true or false,passiveSourceDurationExact=source and source.durationExact==true or false,passiveSourceFovFormulaExact=source and source.fovFormulaExact==true or false,passiveSourceFovRngExact=source and source.fovRngExact==true or false,passiveSourceFovTimingExact=source and source.fovTimingExact==true or false,passiveSourceFovExact=source and source.fovExact==true or false,commandHeld=true,highBroadcast=true,finitePassiveArcs=true}
end
C._test=C._test or {}
C._test.orbitMix=orbitMix
C._test.hsdRandStep=hsdRandStep
C._test.hsdRandBounded=function(seed,range)
  return hsdRandBoundedStep(seed,range)
end
C._test.hsdSelectDifferentMotion=hsdSelectDifferentMotion
C._test.hsdSelectDifferentBounded=hsdSelectDifferentBounded
C._test.retailFloorCameraScale=retailFloorCameraScale
C._test.retailFloorCameraMaxSelector=retailFloorCameraMaxSelector
C._test.retailFloorCameraOffsetPose=retailFloorCameraOffsetPose
return C
