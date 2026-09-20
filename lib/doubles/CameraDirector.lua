-- Four-battler cinematography. Read-only: no battle input, targets or rules are
-- changed. All poses use STAGE coordinates and the existing venue safety guard.
local V=...
local C={version=1}
local Pacing=V and V.CameraPacing
local function platformOS()
  if love and love.system and type(love.system.getOS)=='function' then
    local ok,value=pcall(love.system.getOS);if ok and value then return tostring(value) end
  end
  return 'Unknown'
end
local MOBILE_RUNTIME=(function()local os=platformOS();return os=='Android' or os=='iOS'end)()
local function clamp(x,a,b)return math.max(a,math.min(b,x))end
local function mix(a,b,t)return a+(b-a)*t end
local function copy(p)return {eye={p.eye[1],p.eye[2],p.eye[3]},focus={p.focus[1],p.focus[2],p.focus[3]},fov=p.fov or .8,curve=0}end
local function smoothstep(t)t=clamp(t,0,1);return t*t*(3-2*t)end
-- Interpolate around the focus, not through it. Cartesian eye blends can pass
-- through the battlefield; the venue's minimum-radius clamp then flips the eye
-- to the other side in one frame. Shortest-arc interpolation has no such pole.
local function orbitBlend(a,b,t)
  t=clamp(t,0,1)
  local function polar(p)
    local x,y,z=p.eye[1]-p.focus[1],p.eye[2]-p.focus[2],p.eye[3]-p.focus[3]
    local horizontal=math.sqrt(x*x+z*z)
    return math.atan2(x,z),math.atan2(y,math.max(.000001,horizontal)),math.sqrt(horizontal*horizontal+y*y)
  end
  local ay,ap,ar=polar(a);local by,bp,br=polar(b)
  local delta=(by-ay+math.pi)%(math.pi*2)-math.pi
  local yaw,pitch,radius=ay+delta*t,mix(ap,bp,t),mix(ar,br,t)
  local focus={mix(a.focus[1],b.focus[1],t),mix(a.focus[2],b.focus[2],t),mix(a.focus[3],b.focus[3],t)}
  local horizontal=math.cos(pitch)*radius
  return {eye={focus[1]+math.sin(yaw)*horizontal,focus[2]+math.sin(pitch)*radius,focus[3]+math.cos(yaw)*horizontal},
    focus=focus,fov=mix(a.fov,b.fov,t),curve=0}
end
local function blendPose(a,b,t) return orbitBlend(a,b,smoothstep(t)) end
local function editDuration(a,b)
  local ay=math.atan2(a.eye[1]-a.focus[1],a.eye[3]-a.focus[3])
  local by=math.atan2(b.eye[1]-b.focus[1],b.eye[3]-b.focus[3])
  local delta=math.abs((by-ay+math.pi)%(math.pi*2)-math.pi)
  return clamp(.18+delta*.14,.18,.52)
end
local function point(s,ctx,id,token)
  if not id then return end
  local x,z=V.DoublesPresenter.anchor(ctx,id);if not x then return end
  local slot=s.core.slots and s.core.slots[id]
  local rec=s.actors and s.actors[token or (slot and slot.battlerId)]
  local a=rec and rec.actor
  local k=(ctx.services or {}).figureScale or (ctx.arena or {}).figureScale or .38
  local h=clamp(a and (a.height or 16)*(a.worldScale or 1)*k or 7,2,26)
  return {x,(ctx.groundY or 0)+h*.52,z},h,rec
end
local function framing(points,height,fov,aspect)
  if #points==0 then return {0,6,0},38 end
  local minx,maxx,minz,maxz=points[1][1],points[1][1],points[1][3],points[1][3]
  local y=0
  for _,p in ipairs(points)do minx=math.min(minx,p[1]);maxx=math.max(maxx,p[1]);minz=math.min(minz,p[3]);maxz=math.max(maxz,p[3]);y=y+p[2] end
  local radius=math.sqrt((maxx-minx)^2+(maxz-minz)^2)*.53+height*.62+2
  -- Four-battler geometry needs a wider master than the same two endpoints in
  -- singles. Keep the action axis and source-like lens, but solve a little more
  -- range from the actual group size so partner slots never read like close-ups.
  local groupScale=#points>=4 and 1.10 or (#points>=2 and 1.05 or 1)
  -- Portrait mobile needs substantially more horizontal breathing room. Widen
  -- the source-like lens first, then solve range from the actual aspect rather
  -- than cropping a partner/target out of a four-battler composition.
  local solved=radius/math.tan(fov*.5)/clamp(aspect,.56,1.35)
  return {(minx+maxx)*.5,y/#points,(minz+maxz)*.5},math.max(23,solved*groupScale)
end
function C.neutral(base)
  local out=copy(base);out.eye[2]=out.eye[2]+5;out.focus[2]=out.focus[2]+.25;out.fov=math.min(1.45,out.fov*1.26);return out
end
local function guardPhase(phase)
  if phase=='launch' or phase=='transit' then return 'attack' end
  if phase=='impact' or phase=='damage' or phase=='reaction' or phase=='heal' or phase=='status' then return 'damage' end
  if phase=='faint' then return 'faint' end
  if phase=='recall' or phase=='trainer-throw' or phase=='sendout-reveal' then return 'switch' end
  return 'passive'
end
local function guard(p,ctx,phase)
  return V.Camera and V.Camera.guardPose and V.Camera:guardPose(p,ctx.arena,guardPhase(phase)) or p
end
local function sideOfAxis(base,source,target)
  local dx,dz=target[1]-source[1],target[3]-source[3]
  local len=math.max(.001,math.sqrt(dx*dx+dz*dz));local fx,fz=dx/len,dz/len
  local rx,rz=-fz,fx
  local midx,midz=(source[1]+target[1])*.5,(source[3]+target[3])*.5
  local sideDot=(base.eye[1]-midx)*rx+(base.eye[3]-midz)*rz
  return sideDot<0 and -1 or 1
end
local function axisPose(base,source,target,focus,range,back,side,lift,sign)
  local dx,dz=target[1]-source[1],target[3]-source[3]
  local len=math.max(.001,math.sqrt(dx*dx+dz*dz));local fx,fz=dx/len,dz/len
  local rx,rz=-fz,fx
  sign=sign or sideOfAxis(base,source,target)
  return {focus=focus,eye={focus[1]-fx*range*back+rx*range*side*sign,
      focus[2]+math.max(3,range*lift),focus[3]-fz*range*back+rz*range*side*sign}}
end
local function validSourcePose(p)
  if type(p)~='table' or type(p.eye)~='table' or type(p.focus)~='table' then return false end
  local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
  if not finite(p.fov) or p.fov<=0 or p.fov>=math.pi then return false end
  local length=0
  for i=1,3 do
    if not finite(p.eye[i]) or not finite(p.focus[i]) then return false end
    length=length+(p.eye[i]-p.focus[i])^2
  end
  return length>1e-10
end
local function approachPoint(a,b,maxDistance)
  local length=math.sqrt((b[1]-a[1])^2+(b[2]-a[2])^2+(b[3]-a[3])^2)
  local t=length>0 and math.min(1,maxDistance/length) or 1
  return {mix(a[1],b[1],t),mix(a[2],b[2],t),mix(a[3],b[3],t)}
end
local function cameraDt(state,s,ctx,clock)
  -- Battle logic can execute several fixed ticks between two rendered frames,
  -- especially on mobile and at higher battle speeds. Using the fixed-step
  -- visualClock directly for interpolation therefore advances the lens in chunky
  -- bursts even though the target pose itself is stable -- the nauseating camera
  -- stair-step seen in Gen-II doubles. Keep source/action timing on visualClock,
  -- but integrate NON-exact camera smoothing from the monotonic render clock on
  -- every platform. Repeated camera queries in one rendered frame then have dt=0,
  -- while 30/60/120 Hz frames receive their real presentation delta independent
  -- of speed. Desktop still retains source-authored hard edits/exact frame cuts;
  -- only continuous interpolation consumes this presentation-time delta.
  local dt
  if love and love.timer and type(love.timer.getTime)=='function' then
    local ok,now=pcall(love.timer.getTime)
    if ok and type(now)=='number' and now==now and math.abs(now)<math.huge then
      if state.lastRenderClock==nil then state.lastRenderClock=now;dt=0
      else dt=clamp(now-state.lastRenderClock,0,.10);state.lastRenderClock=now end
    end
  end
  if dt==nil then dt=clamp(clock-(state.lastClock or clock),0,.25) end
  state.lastClock=clock
  return dt
end
function C.pose(base,s,ctx)
  if not (s and s.core and ctx and V.DoublesPresenter)then return C.neutral(base)end
  local e=s.core.currentEvent;local m=s.movePresentation
  local clock=tonumber(s.visualClock) or 0
  if clock~=clock or math.abs(clock)==math.huge then clock=0 end
  local state=s.doublesCamera
  -- Render contexts may be reconstructed each draw. The combat core owns this
  -- camera's lifetime; resetting on table identity discards smoothing every frame.
  if not state or state.core~=s.core then
    state={core=s.core,lastClock=clock,
      masterYaw=math.atan2(base.eye[1]-base.focus[1],base.eye[3]-base.focus[3])}
    s.doublesCamera=state
  end
  state.mobileSourceInterpolated=false
  if not e then
    state.actionEvent=nil;state.actionAxisSign=nil;state.actionSource=nil;state.actionTargets=nil
  elseif e~=state.eventRecord and e.kind=='move' then
    state.actionEvent=e;state.actionAxisSign=nil;state.actionSource=nil;state.actionTargets=nil
  elseif e~=state.eventRecord and (e.kind=='send' or e.kind=='recall') then
    state.actionEvent=nil;state.actionAxisSign=nil;state.actionSource=nil;state.actionTargets=nil
  end
  -- GC6E01 battleCameraStartWaza hands the lens to the active Waza camera. When
  -- doubles has a fully decoded embedded HSD camera, use that authored frame
  -- verbatim instead of the synthetic axis composition below. This mirrors the
  -- singles exact-camera contract: no arena guard, smoothing, or viewport tweak
  -- may rewrite a proven retail eye/interest/FOV sample.
  local sourcePose
  local MP=V.DoublesMovePresentation
  if MP and type(MP.sourceCameraPose)=='function' then
    local ok,value=pcall(MP.sourceCameraPose,s)
    if ok and validSourcePose(value) and value.sourceCameraEmbeddedTransformUnsupported==nil then
      local exact=value.sourceCameraEmbeddedDecoded==true and value.sourceCameraRetailFrameExact==true
      local procedural=value.sourceCameraEmbedded~=true and value.sourceCameraMotionScalarExact==true
        and value.sourceCameraTargetResolved==true
      if exact or procedural then sourcePose=value end
    end
  end
  if sourcePose then
    state.mobileEdit=nil
    local exact=sourcePose.sourceCameraEmbeddedDecoded==true and sourcePose.sourceCameraRetailFrameExact==true
    local phase=sourcePose.sourceRole=='damage' and 'impact' or 'attack'
    local target=exact and copy(sourcePose) or guard(copy(sourcePose),ctx,phase)
    local sourceTarget=copy(target)
    local identity=sourcePose.sourceShotId or sourcePose.sourceSerial
    local dt=cameraDt(state,s,ctx,clock)
    local sameSource=state.sourceDriven and state.sourceShotId==identity and state.eventRecord==e
    -- A new source chapter is an edit. Within a chapter, mobile interpolates
    -- between exact retail samples using render time so multiple fixed battle
    -- ticks between frames cannot make the lens visibly stair-step. The decoded
    -- GC6E01 pose remains the target; desktop stays frame-exact. On mobile the
    -- edit itself receives a very short optical handoff rather than a one-frame
    -- teleport between launch/receiver cameras. This never invents a path inside
    -- a retail chapter: it only bridges two independently authored shot owners.
    if MOBILE_RUNTIME and state.pose and not sameSource then
      if not state.sourceEdit or state.sourceEdit.identity~=identity or state.sourceEdit.event~=e then
        state.sourceEdit={from=copy(state.pose),identity=identity,event=e,age=0,
          duration=editDuration(state.pose,target),sourceExact=exact}
      end
    end
    -- Continue an existing handoff on EVERY render. sameSource becomes true on
    -- frame two; the old nested branch abandoned its blend at exactly that point.
    if MOBILE_RUNTIME and state.sourceEdit then
      local edit=state.sourceEdit;edit.age=edit.age+dt
      target=blendPose(edit.from,target,edit.age/edit.duration)
      state.mobileSourceInterpolated=true
      if edit.age>=edit.duration then state.sourceEdit=nil end
    elseif exact and MOBILE_RUNTIME and sameSource and state.pose then
      target.eye=approachPoint(state.pose.eye,target.eye,42*dt)
      target.focus=approachPoint(state.pose.focus,target.focus,34*dt)
      target.fov=state.pose.fov+clamp(target.fov-state.pose.fov,-math.rad(34)*dt,math.rad(34)*dt)
      state.mobileSourceInterpolated=true
    elseif not exact and sameSource then
      target.eye=approachPoint(state.pose.eye,target.eye,30*dt)
      target.focus=approachPoint(state.pose.focus,target.focus,22*dt)
      target.fov=state.pose.fov+clamp(target.fov-state.pose.fov,-math.rad(24)*dt,math.rad(24)*dt)
      target=guard(target,ctx,phase)
    end
    state.pose=copy(target);state.target=sourceTarget;state.phase=phase
    state.eventId=e and e.eventId;state.eventRecord=e
    state.sourceTargetRetailExact=exact
    state.sourceRetailExact=exact and not state.mobileSourceInterpolated
    state.sourceDriven=true;state.sourceShotId=identity
    return copy(state.pose)
  end
  local finishingSourceEdit=state.sourceEdit
  state.sourceEdit=nil
  state.sourceRetailExact=false;state.sourceTargetRetailExact=false;state.sourceDriven=false;state.sourceShotId=nil
  local size=(ctx.services or {}).renderSize or {};local aspect=(size.width or 1280)/math.max(1,size.height or 720)
  local bx,bz=base.eye[1]-base.focus[1],base.eye[3]-base.focus[3]
  local yaw=state.masterYaw or math.atan2(bx,bz)
  local phase='command';local pose
  local kind=e and e.kind
  local age=tonumber(s.core.eventTime) or 0
  local points={};local maxH=5
  for _,r in ipairs(s.actorOrder or {})do if r.visible and not r.structuralHidden then
    local p,h=point(s,ctx,r.slot,r.battlerId);if p then points[#points+1]=p;maxH=math.max(maxH,h)end
  end end
  local fov=math.rad(aspect<1.0 and 49.5 or 43)
  local focus,range=framing(points,maxH,fov,aspect)
  local elevation=.31
  local variant=((tonumber(e and e.eventId) or tonumber(s.core.turn) or 1)%3)-1
  if aspect<1.0 then focus[2]=focus[2]-.55 end
  local p,h,r
  -- Lua's and-expression truncates multi-return values. Resolve explicitly.
  if e then p,h,r=point(s,ctx,e.slot,e.battlerId)end
  if e and (e.presentationConsumed or (kind=='move' and not m and state.phase=='impact'
      and state.eventRecord==e)) then
    -- Channel completion precedes the controller's following update. Holding
    -- this already-finished impact avoids a one-frame jump back to launch or
    -- transit while the same event is still the controller's current record.
    if state.pose then
      -- A consumed queue record ends choreography, not an in-flight optical
      -- handoff. Freezing the displayed mid-blend pose here left mobile stuck
      -- between launch and impact until the next event (then jumped again).
      -- Finish the existing edit to its SAVED target without reopening an event.
      local dt=cameraDt(state,s,ctx,clock)
      local edit=state.mobileEdit or finishingSourceEdit
      if MOBILE_RUNTIME and edit and state.target then
        edit.age=edit.age+dt
        state.pose=blendPose(edit.from,state.target,edit.age/edit.duration)
        if not edit.sourceExact then state.pose=guard(state.pose,ctx,state.phase) end
        state.mobileEdit=edit.age<edit.duration and edit or nil
      end
      return copy(state.pose)
    end
  elseif p and kind=='send' and not e.alreadyPresented then
    local send=r and r.sendout
    if send and (send.phase or 0)<.79 and V.Camera and V.Camera.sendoutShot then
      local side=e.slot:match('^player') and 'player' or 'enemy'
      pose=V.Camera:sendoutShot(ctx,ctx.arena,side);phase='trainer-throw'
    end
    if not pose then
      phase='sendout-reveal';focus=p;range=math.max(21,h*3.15);fov=math.rad(37.5)
      yaw=yaw+(e.slot:match('^player') and -.30 or .30)+variant*.12;elevation=.20
    end
  elseif p and kind=='recall' then
    phase='recall';focus=p;range=math.max(24,h*3.35);fov=math.rad(39)
    yaw=yaw+(e.slot:match('^player') and -.38 or .38);elevation=.29
  elseif p and kind=='faint' then
    phase='faint';focus={p[1],(ctx.groundY or 0)+h*.32,p[3]};range=math.max(22,h*3.0)
    yaw=yaw+(e.slot:match('^player') and .36 or -.36)+variant*.06;elevation=.22;fov=math.rad(36.5)
  elseif p and kind=='move' then
    local targetPoints={};local mh=h
    for _,id in ipairs(e.targets or {})do
      if id~=e.slot then local t,th=point(s,ctx,id,(e.targetBattlers or {})[id]);if t then targetPoints[#targetPoints+1]=t;mh=math.max(mh,th)end end
    end
    local all={p};for _,t in ipairs(targetPoints)do all[#all+1]=t end
    local centre,wide=framing(all,mh,math.rad(41),aspect)
    local elapsed=m and (m.chapterAge or 0) or age
    local launchEnd=m and m.impactTime and math.min(.65,m.impactTime*.60) or .48
    local targetCentre=centre
    if targetPoints[1] then targetCentre=framing(targetPoints,mh,math.rad(41),aspect) end
    if not state.actionAxisSign then state.actionAxisSign=sideOfAxis(state.pose or base,p,targetCentre) end
    state.actionSource={p[1],p[2],p[3]};state.actionTargets={}
    for _,id in ipairs(e.targets or {})do state.actionTargets[id]=true end
    local actionSign=state.actionAxisSign
    local spread=#targetPoints>1
    local transit=spread or elapsed>=launchEnd
    phase=transit and 'transit' or 'launch'
    if spread then
      -- Multi-target source effects need the complete receiving group from their
      -- first visible frame. This is the one case where the attack starts wide.
      focus=centre;range=wide;fov=math.rad(aspect<1.0 and 49.5 or 41);elevation=.27
      local q=axisPose(base,p,targetCentre,focus,range,.06,.84+variant*.035,elevation,actionSign)
      pose={eye=q.eye,focus=focus,fov=fov,curve=0}
    else
      -- Retail stream/projectile photography holds the attacker/effect origin
      -- through flight (e.g. Mantine BubbleBeam) and edits to the receiver at
      -- impact. `transit` remains a timing phase, not permission for a generic
      -- camera chase across the arena.
      focus={mix(p[1],targetCentre[1],.14),mix(p[2],targetCentre[2],.14),mix(p[3],targetCentre[3],.14)}
      range=math.max(23,h*3.1);fov=math.rad(aspect<1.0 and 46.5 or 39);elevation=.26
      local q=axisPose(base,p,targetCentre,focus,range,.31,.74+variant*.04,elevation,actionSign)
      pose={eye=q.eye,focus=focus,fov=fov,curve=0}
    end
    if m and m.impactStarted and #targetPoints>0 then
      local receive,rr=framing(targetPoints,mh,math.rad(38.5),aspect)
      focus=receive;range=math.max(rr,mh*3.2);fov=math.rad(aspect<1.0 and 48 or 38.5);elevation=.24+variant*.012;phase='impact'
      local q=axisPose(base,p,targetCentre,focus,range,-.17,.70+variant*.035,elevation,actionSign)
      pose={eye=q.eye,focus=focus,fov=fov,curve=0}
    end
  elseif p and (kind=='damage' or kind=='reaction' or kind=='heal' or kind=='status')then
    phase=kind;focus=p;range=math.max(23,h*3.2);fov=math.rad(38)
    elevation=.29
    if (kind=='damage' or kind=='reaction') and state.actionAxisSign and state.actionSource
        and state.actionTargets and state.actionTargets[e.slot] then
      -- Damage/reaction are the receiver edit of the immediately preceding move.
      -- Preserve the launch/impact side even though these are separate controller
      -- records; residual/status damage without a matching move target uses the
      -- ordinary target-owned fallback below.
      local q=axisPose(base,state.actionSource,p,focus,range,.02,.69,elevation,state.actionAxisSign)
      pose={eye=q.eye,focus=focus,fov=fov,curve=0}
    else
      yaw=yaw+(e.slot:match('^player') and .27 or -.27)+variant*.10
    end
  end
  if not pose then
    pose={focus=focus,eye={focus[1]+math.sin(yaw)*range,focus[2]+math.max(3,range*elevation),focus[3]+math.cos(yaw)*range},fov=fov,curve=0}
  end
  pose=guard(pose,ctx,phase)
  local dt=cameraDt(state,s,ctx,clock)
  local eventId=e and e.eventId
  -- Event tables are stable controller records even when a host does not assign
  -- numeric eventIds. Object identity therefore remains a reliable edit boundary.
  local eventChanged=e~=state.eventRecord
  local phaseChanged=phase~=state.phase
  local cut=state.pose and ((eventChanged and phase~='command') or phase=='impact' or phase=='faint'
    or phase=='damage' or phase=='reaction' or phase=='recall' or phase=='trainer-throw' or phase=='sendout-reveal')
  if state.pose then
    local editBoundary=cut and (eventChanged or phaseChanged)
    if MOBILE_RUNTIME and editBoundary then
      -- Mobile touch play made source-style hard edits read as camera stutter,
      -- especially when a move event immediately published its impact/damage
      -- record. Preserve the edit and action-axis target, but traverse the tiny
      -- optical gap over presentation time. Repeated fixed ticks in one render
      -- frame have dt=0 via cameraDt(), so fast-forward cannot accelerate it.
      state.mobileEdit={from=copy(state.pose),age=0,
        duration=editDuration(state.pose,pose),
        event=e,phase=phase}
    end
    if MOBILE_RUNTIME and state.mobileEdit then
      local edit=state.mobileEdit
      edit.age=edit.age+dt
      state.pose=blendPose(edit.from,pose,edit.age/edit.duration)
      state.pose=guard(state.pose,ctx,phase)
      if edit.age>=edit.duration then state.mobileEdit=nil end
    elseif editBoundary then
      -- Launch/impact/terminal beats are edits. Never interpolate through the
      -- battlers or across the 180 line simply because two source shots differ.
      state.pose=copy(pose)
    else
      -- Command returns and launch->transit handoffs are presentation-space
      -- interpolation. On mobile cameraDt() uses real rendered time so multiple
      -- fixed logic ticks cannot make the lens jump several samples at once.
      -- Action edits remain intentional cuts; only held handoffs are smoothed.
      local rate=phase=='command' and 3.0 or (phase=='transit' and 5.2 or 7.0)
      local a=1-math.exp(-dt*rate)
      state.pose=orbitBlend(state.pose,pose,a)
      state.pose=guard(state.pose,ctx,phase)
    end
  else state.pose=copy(pose)end
  state.phase=phase;state.eventId=eventId;state.eventRecord=e;state.target=pose
  return copy(state.pose)
end
-- Final display-layer pacing is shared with singles. Do not slow the battle
-- core or the source animation. At 4x+ keep all currently staged battlers in the
-- same shot through launch, impact and routine reactions, rather than recutting
-- to each receiver. Small move-owned yaw changes keep this a live composition.
local directedPose=C.pose
function C.pose(base,s,ctx)
  local pose=directedPose(base,s,ctx)
  if not (Pacing and s and s.core and ctx and pose) then return pose end
  local speed=Pacing.speed(ctx,s,V and V.mod);local cfg=Pacing.config(speed)
  local c=s.doublesCamera
  if not c then return pose end
  if ctx.__cbeBossCameraComfort then
    s.cameraComfort=ctx.__cbeBossCameraComfort;s.cameraComfort.core=s.core;ctx.__cbeBossCameraComfort=nil
  end
  if not s.cameraComfort or s.cameraComfort.core~=s.core then s.cameraComfort={core=s.core} end
  local e=s.core.currentEvent;local kind=e and e.kind or "command"
  local group=cfg.wide and (kind=="move" or kind=="damage" or kind=="reaction" or kind=="status" or kind=="heal" or kind=="command" or (e and e.presentationConsumed))
  if group then
    local points={};local height=5
    for _,r in ipairs(s.actorOrder or {}) do
      if r.visible and not r.structuralHidden then
        local p,h=point(s,ctx,r.slot,r.battlerId)
        if p then points[#points+1]=p;height=math.max(height,h) end
      end
    end
    local size=(ctx.services or {}).renderSize or {};local aspect=(size.width or 1280)/math.max(1,size.height or 720)
    local fov=math.rad(aspect<1 and 51 or 46)
    local focus,range=framing(points,height,fov,aspect)
    if #points==0 then focus={base.focus[1],base.focus[2],base.focus[3]};range=math.sqrt((base.eye[1]-base.focus[1])^2+(base.eye[3]-base.focus[3])^2) end
    if kind=="move" and (s.cameraComfort.age or 0)-(s.cameraComfort.actionYawAt or -math.huge)>=cfg.hold*2 then
      -- Even small wide-shot corrections must not chase alternating attackers
      -- every accelerated tick. Reconsider the live side at a slow cadence.
      s.cameraComfort.actionYaw=tostring(e.slot or ""):match("^player") and -.08 or .08
      s.cameraComfort.actionYawAt=s.cameraComfort.age or 0
      s.cameraComfort.groupReframes=(s.cameraComfort.groupReframes or 0)+1
    end
    local yaw=c.masterYaw+(s.cameraComfort.actionYaw or 0)
    pose=guard({eye={focus[1]+math.sin(yaw)*range,focus[2]+math.max(5,range*.32),focus[3]+math.cos(yaw)*range},focus=focus,fov=fov,curve=0},ctx,"command")
  end
  local key=group and "combat-group" or (tostring(kind)..":"..tostring(e)..":"..tostring(c.sourceShotId or c.phase))
  local paced
  local seed=base
  if cfg.active and V.Camera and V.Camera.guardPacedPose then
    pose=V.Camera:guardPacedPose(pose,ctx.arena)
    seed=V.Camera:guardPacedPose(base,ctx.arena)
  end
  paced,s.cameraComfort=Pacing.apply(s.cameraComfort,pose,{speed=speed,clock=s.visualClock,
    key=key,critical=kind=="send" or kind=="recall" or kind=="faint" or kind=="end",seed=seed})
  if paced and s.cameraComfort.adapted then
    -- The target's source identity remains available, but a comfort lens is not
    -- falsely described as a frame-exact retail camera.
    c.sourceRetailExact=false;c.comfortAdapted=true
    if cfg.active and V.Camera and V.Camera.guardPacedPose then paced=Pacing.constrain(s.cameraComfort,V.Camera:guardPacedPose(paced,ctx.arena)) end
    s.cameraComfort.output=copy(paced)
  else c.comfortAdapted=false end
  return paced or pose
end
function C.adopt(s,pose)
  if s and s.doublesCamera and validSourcePose(pose) then
    local state=s.doublesCamera
    s.cameraComfort={core=s.core,output=copy(pose)}
    state.pose=copy(pose);state.target=copy(pose)
    state.mobileEdit=nil;state.sourceEdit=nil;state.lastRenderClock=nil
  end
end
function C.status(s)
  local c=s and s.doublesCamera
  return {active=c~=nil,shot=c and c.phase,eventId=c and c.eventId,clock=c and c.lastClock,axisSign=c and c.actionAxisSign,sourceRetailExact=c and c.sourceRetailExact==true or false,sourceTargetRetailExact=c and c.sourceTargetRetailExact==true or false,sourceDriven=c and c.sourceDriven==true or false,sourceShotId=c and c.sourceShotId,mobileSourceInterpolated=c and c.mobileSourceInterpolated==true or false,cameraComfort=c and c.comfortAdapted==true or false,highSpeedMaster=s and s.cameraComfort and s.cameraComfort.wide==true or false,cameraComfortEdits=s and s.cameraComfort and s.cameraComfort.edits or 0,cameraComfortHold=s and s.cameraComfort and s.cameraComfort.hold or 0}
end
C._test={orbitBlend=orbitBlend,editDuration=editDuration}
return C
