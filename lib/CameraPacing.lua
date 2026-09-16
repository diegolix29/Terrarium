-- Camera-only fast-forward comfort layer. Never writes battle, save, actor,
-- source animation or MoveFX state. At 1x, untouched source samples stay exact.
-- Faster battle logic must not imply faster optical movement or more edits.
local P={version=1}
local function finite(x)return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function clamp(x,a,b)return math.max(a,math.min(b,x))end
local function atan(y,x)return math.atan2 and math.atan2(y,x) or math.atan(y,x)end
local function copy(p)return {eye={p.eye[1],p.eye[2],p.eye[3]},focus={p.focus[1],p.focus[2],p.focus[3]},fov=p.fov,curve=0}end
local function valid(p)
  if type(p)~="table" or type(p.eye)~="table" or type(p.focus)~="table" or not finite(p.fov) or p.fov<=0 or p.fov>=math.pi then return false end
  local r=0
  for i=1,3 do if not finite(p.eye[i]) or not finite(p.focus[i]) then return false end;r=r+(p.eye[i]-p.focus[i])^2 end
  return r>1e-10
end
local function safeSpeed(v)
  v=tonumber(v);return finite(v) and clamp(v,1,64) or 1
end
function P.speed(ctx,session,mod)
  local battle=type(ctx)=="table" and ctx.battle
  local game=(type(ctx)=="table" and ctx.game) or (battle and battle.game)
    or (session and session.screen and session.screen.game)
    or (session and session.host and session.host.game) or (mod and mod.game)
  game=(game and game.__cbeMtBattleHostGame) or game
  if game and type(game.logicSpeed)=="function" then
    local ok,value=pcall(game.logicSpeed,game)
    if ok and finite(tonumber(value)) then return safeSpeed(value) end
  end
  local opts=game and game.save and game.save.options or {}
  return safeSpeed(opts.speedBattle or opts.speed)
end
function P.config(speed)
  speed=safeSpeed(speed)
  local tier=speed>=8 and 2 or (speed>=4 and 1 or 0)
  return {active=speed>1.05,wide=speed>=4,hold=.90+tier*.15,
    yaw=math.rad(24-tier*5),pitch=math.rad(12-tier*2),
    fov=math.rad(10-tier*2),focus=10-tier*2,range=.26-tier*.035,rate=3.0-tier*.4}
end
local function polar(p)
  local x,y,z=p.eye[1]-p.focus[1],p.eye[2]-p.focus[2],p.eye[3]-p.focus[3]
  local h=math.sqrt(x*x+z*z)
  return atan(x,z),atan(y,math.max(1e-8,h)),math.sqrt(h*h+y*y)
end
local function orbit(a,b,t)
  local ay,ap,ar=polar(a);local by,bp,br=polar(b)
  local yaw=ay+((by-ay+math.pi)%(2*math.pi)-math.pi)*t
  local pitch=ap+(bp-ap)*t;local r=ar+(br-ar)*t
  local f={};for i=1,3 do f[i]=a.focus[i]+(b.focus[i]-a.focus[i])*t end
  local h=math.cos(pitch)*r
  return {eye={f[1]+math.sin(yaw)*h,f[2]+math.sin(pitch)*r,f[3]+math.cos(yaw)*h},focus=f,fov=a.fov+(b.fov-a.fov)*t,curve=0}
end
local function limited(a,b,dt,c,hardLimit)
  local ay,ap,ar=polar(a);local by,bp,br=polar(b)
  local alpha=hardLimit and 1 or (1-math.exp(-dt*c.rate))
  local yaw=ay+clamp(((by-ay+math.pi)%(2*math.pi)-math.pi)*alpha,-c.yaw*dt,c.yaw*dt)
  local pitch=ap+clamp((bp-ap)*alpha,-c.pitch*dt,c.pitch*dt)
  local radius=ar+clamp((br-ar)*alpha,-math.max(1,ar)*c.range*dt,math.max(1,ar)*c.range*dt)
  local dx,dy,dz=b.focus[1]-a.focus[1],b.focus[2]-a.focus[2],b.focus[3]-a.focus[3]
  local d=math.sqrt(dx*dx+dy*dy+dz*dz)
  -- Scale only stage-unit translation, not angular speed, for compact/large arenas.
  local limit=c.focus*clamp(ar/60,.35,3)*dt
  local t=d>1e-8 and math.min(alpha,limit/d) or 0
  local f={a.focus[1]+dx*t,a.focus[2]+dy*t,a.focus[3]+dz*t}
  local h=math.cos(pitch)*radius
  return {eye={f[1]+math.sin(yaw)*h,f[2]+math.sin(pitch)*radius,f[3]+math.cos(yaw)*h},focus=f,
    fov=a.fov+clamp((b.fov-a.fov)*alpha,-c.fov*dt,c.fov*dt),curve=0}
end
local function renderDelta(s,opts)
  local now
  if love and love.timer and type(love.timer.getTime)=="function" then
    local ok,v=pcall(love.timer.getTime);if ok and finite(v) then now=v end
  end
  local clock=tonumber(opts.clock)
  local dt=0
  if now then
    if s.renderClock then dt=clamp(now-s.renderClock,0,.1) end
    s.renderClock=now
  else
    if finite(clock) and finite(s.logicClock) then
      dt=clamp((clock-s.logicClock)/(opts.clockIsPresentation and 1 or safeSpeed(opts.speed)),0,.1)
    end
    -- On timer recovery, establish a fresh epoch rather than spending a hitch.
    s.renderClock=nil
  end
  if finite(clock) then s.logicClock=clock end
  return dt
end
function P.apply(s,target,opts)
  opts=opts or {};s=s or {}
  if not valid(target) then return s.output and copy(s.output) or (valid(opts.seed) and copy(opts.seed) or nil),s end
  local c=P.config(opts.speed);local dt=renderDelta(s,opts)
  s.frameOrigin=s.output and copy(s.output) or nil;s.frameDt=dt
  s.age=(s.age or 0)+dt
  s.speed=safeSpeed(opts.speed);s.wide=c.wide
  if not c.active then
    if s.active then s.returning=true end
    s.active=false
    if not s.returning then
      s.output=copy(target);s.target=nil;s.key=nil;s.adapted=false;s.hold=0
      return copy(s.output),s
    end
    -- Returning to 1x must not reintroduce a snap by interpolating toward a
    -- different moving endpoint on every frame. Keep the same bounded filter
    -- until a current, settled source composition can take over continuously.
    local ay,ap,ar=polar(s.output);local by,bp,br=polar(target)
    local distance=0;for i=1,3 do distance=distance+(s.output.focus[i]-target.focus[i])^2 end
    local close=math.abs((by-ay+math.pi)%(2*math.pi)-math.pi)<1e-6
      and math.abs(bp-ap)<1e-6 and math.abs(br-ar)<1e-5
      and distance<1e-10 and math.abs(target.fov-s.output.fov)<1e-6
    if close then
      s.returning=nil;s.target=nil;s.key=nil;s.output=copy(target);s.adapted=false;s.hold=0
      return copy(s.output),s
    end
  elseif not s.active then
    s.active=true;s.returning=nil
    s.output=copy(s.output or (valid(opts.seed) and opts.seed) or target)
    s.frameOrigin=s.frameOrigin or copy(s.output)
    s.target=copy(target);s.key=opts.key;s.committedAt=s.age
    s.edits=(s.edits or 0)+1
  end
  s.adapted=true
  -- Exactly one current destination. Newer events replace candidates instead of
  -- queuing delayed launch/impact shots to replay after the move has finished.
  if opts.key==s.key then
    s.target=copy(target);s.suppressedKey=nil
  elseif s.age-(s.committedAt or s.age)>=c.hold*(opts.critical and .65 or 1) then
    s.target=copy(target);s.key=opts.key;s.committedAt=s.age;s.edits=(s.edits or 0)+1;s.suppressedKey=nil
  elseif opts.key~=s.suppressedKey then
    s.suppressedKey=opts.key;s.coalesced=(s.coalesced or 0)+1
  end
  if dt>0 then s.output=limited(s.output,s.target,dt,c) end
  s.hold=c.hold
  return copy(s.output),s
end
-- A final venue projection must not defeat pacing. In particular an exact
-- 1x source shot may legitimately begin outside a heuristic comfort volume.
-- Converge toward the projected pose within this frame's motion budget instead
-- of instantly clipping its focus/FOV when fast-forward is toggled mid-shot.
function P.constrain(s,projected)
  if not (s and s.output and valid(projected)) then return s and s.output and copy(s.output) or projected end
  if not s.adapted then return projected end
  local out=limited(s.frameOrigin or s.output,projected,s.frameDt or 0,P.config(s.speed),true)
  s.output=copy(out)
  return out
end
P._test={polar=polar,valid=valid,limited=limited,orbit=orbit}
return P
