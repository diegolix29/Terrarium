-- Slot-owned retail ball_open chapters. Never run the side-wide Waza owner
-- controller: it would hide or move the partner that has already arrived.
local V=...
local R={version=1,serial=0}
local balls={POKE_BALL='monsterball',GREAT_BALL='superball',ULTRA_BALL='hyperball',MASTER_BALL='masterball',
 SAFARI_BALL='safariball',NET_BALL='netball',DIVE_BALL='diveball',NEST_BALL='nestball',
 REPEAT_BALL='repeatball',TIMER_BALL='timerball',LUXURY_BALL='gorgeousball',PREMIER_BALL='puremiyaball'}
local function copy(t)local out={};for k,v in pairs(t or {})do out[k]=v end;return out end
local function stemFor(mon)
 local key=mon and (mon.pokeball or mon.pokeBall or mon.ball)
 return balls[tostring(key or 'POKE_BALL'):upper()] or 'monsterball'
end
R.ballStem=stemFor
local function faintSpec(mon)
 local stem=stemFor(mon)
 local spec,why=V.MoveFXExtractor and V.MoveFXExtractor.peekFaintReturn and V.MoveFXExtractor.peekFaintReturn(stem)
 if not spec then return nil,stem,why or 'Source downin WZX cache unavailable' end
 if V.WazaPhasePolicy then spec=V.WazaPhasePolicy.select(spec,{phase='downin'}) end
 local found=false
 for _,phase in ipairs(spec.wazaPhases or {})do if phase.name=='downin' and tonumber(phase.sequenceKind)==10 then found=true;break end end
 if not found or tonumber(spec.sourceSelector)~=0x10 or spec.sourceItemBallField~='downinWzxDataId'
     or tonumber(spec.sourceResourceGroup)~=4 then
  return nil,stem,'Source faint-return cache is not ItemBallData.downinWzxDataId selector 0x10'
 end
 return spec,stem
end

local function resolvedFaintEntries(spec)
 local phase
 for _,candidate in ipairs(spec and spec.wazaPhases or {})do if candidate.name=='downin' then phase=candidate;break end end
 if not (phase and V.WazaSequenceRuntime and type(V.WazaSequenceRuntime.resolveEntryStarts)=='function') then return nil end
 local entries={}
 for _,entry in ipairs(phase.entries or {})do local row={};for k,v in pairs(entry)do row[k]=v end;entries[#entries+1]=row end
 return V.WazaSequenceRuntime.resolveEntryStarts(entries,{0,0,0,0})
end
local function faintCompletionFrame(spec)
 local resolved=resolvedFaintEntries(spec);if not resolved then return nil end
 local stop
 for _,row in ipairs(resolved or {})do
  local e=row.entry or {}
  local frame
  if e.kind=='type1' and tonumber(e.subtype)==0 then
   -- Runtime state-0 starts on this frame and state-1 checks the source wait on
   -- subsequent 60 Hz ticks. A zero wait therefore completes on the next tick.
   frame=(tonumber(row.startFrame) or 0)+math.max(1,math.floor(tonumber(e.controllerParam) or 0))
  elseif e.kind=='type6' and tonumber(e.subtype)==9 then
   frame=tonumber(row.startFrame) or 0
  end
  if frame and (not stop or frame<stop) then stop=frame end
 end
 return stop
end
local function faintHideFrame(spec)
 local resolved=resolvedFaintEntries(spec);if not resolved then return nil end
 local hide
 for _,row in ipairs(resolved or {})do
  local e=row.entry or {}
  if e.kind=='type6' and tonumber(e.subtype)==2 then
   local frame=tonumber(row.startFrame) or 0
   if not hide or frame<hide then hide=frame end
  end
 end
 return hide
end
function R.faintHideFrameFor(mon)
 local spec,_,why=faintSpec(mon);if not spec then return nil,why end
 local frame=faintHideFrame(spec);if frame==nil then return nil,'Source downin WZX has no owner visibility-off controller' end
 return frame,frame/60
end
function R.faintStartDelayFor(mon,actor)
 local hideFrame=select(1,R.faintHideFrameFor(mon))
 if hideFrame==nil then return 0 end
 local nativeDuration
 if actor and type(actor.terminalDuration)=='function' then
  local ok,value=pcall(actor.terminalDuration,actor,'faint');if ok then nativeDuration=tonumber(value) end
 end
 if not nativeDuration and actor and type(actor.stateDuration)=='function' then
  local ok,value=pcall(actor.stateDuration,actor,'faint');if ok then nativeDuration=tonumber(value) end
 end
 if not nativeDuration then return 0 end
 -- The source downin effect begins early enough to overlap the native stumble/fall,
 -- but its visibility_off lands no earlier than the end of that authored body
 -- animation. This preserves Colosseum's tandem faint+withdraw presentation
 -- instead of letting the return controller erase the Kizetu motion.
 return math.max(0,nativeDuration-hideFrame/60)
end
function R.faintDurationFor(mon)
 local spec,_,why=faintSpec(mon);if not spec then return nil,why end
 local frames=faintCompletionFrame(spec)
 if not frames then return nil,'Source downin WZX has no executable completion controller' end
 return frames/60,frames
end

-- A faint-return WZX is its own retail resource group (fightOutPokemonKizetuEffect
-- passes group 4), not an attack/ordinary-return chapter. Keep its runtime world
-- isolated so starting it cannot supersede a live move sequence and so a doubles
-- owner controller can never hide/freeze the partner on the same battle side.
local function withFaintWorld(f,ctx,records,fn)
 local C,W,H=V.CurrentSpriteModels,V.WazaSequenceRuntime,V.WazaHandlers
 if not (f and C and W and H) then return false,'faint-return runtime unavailable' end
 local world=f.world
 if not world then
  world={active={},particles={},models={},effects={},controllers={player={},enemy={}}};f.world=world
 end
 local active,last,particles=W.active,W.last,C.moveFxActive
 local models,effects,controllers,lastModel=H.models,H.effects,H.controllers,H.lastModel
 W.active,W.last=world.active,world.last
 C.moveFxActive=world.particles
 H.models,H.effects,H.controllers,H.lastModel=world.models,world.effects,world.controllers,world.lastModel
 local ok,a,b
 if records and type(C.withDoublesPair)=='function' then
  ok,a,b=pcall(C.withDoublesPair,C,ctx,records,fn)
 else ok,a,b=pcall(fn,ctx) end
 world.active,world.last=W.active,W.last;W.active,W.last=active,last
 world.particles=C.moveFxActive;C.moveFxActive=particles
 world.models,world.effects,world.controllers,world.lastModel=H.models,H.effects,H.controllers,H.lastModel
 H.models,H.effects,H.controllers,H.lastModel=models,effects,controllers,lastModel
 if not ok then return false,a end
 return true,a,b
end

local function startFaintWorld(f,ctx,owner,target,records)
 local frames=faintCompletionFrame(f.spec)
 if not frames then return nil,'Source downin WZX has no executable completion controller' end
 local ok,inst,why=withFaintWorld(f,ctx,records,function(localCtx)
  return V.WazaSequenceRuntime:start(localCtx,owner,f.spec,{role='attack',target=target,allowPartial=false,
   globalTimingPoints={0,0,0,0},presentationSerial=f.serial})
 end)
 if not ok or not inst then return nil,tostring(ok and why or inst) end
 f.instance=inst;f.sourceFrames=frames;f.sourceDuration=frames/60
 return f
end

local function doublesFaintContext(s,r,f)
 local source=s.context
 if not source then return nil,nil,'doubles context unavailable' end
 local ctx=copy(source);ctx.arena=copy(source.arena);ctx.services=source.services;ctx.groundY=source.groundY
 local x,z,dx,dz=V.DoublesPresenter.actorAnchor(source,r.slot)
 if not x then return nil,nil,'doubles faint-return owner anchor unavailable' end
 -- Kizetu WZX has one Pokemon owner and no target argument. The portable source
 -- basis therefore uses that exact actor root plus its established field-facing
 -- axis; the synthetic `enemy` point exists only to express the owner's local +Z
 -- orientation to combatGeometry, never as effect ownership.
 ctx.arena.player={x,z};ctx.arena.enemy={x+dx,z+dz}
 if r.actor and type(r.actor.matrix)=='function' then pcall(r.actor.matrix,r.actor,x,ctx.groundY or 0,z,dx,dz) end
 f.context=ctx
 return ctx,{player=r}
end
function R.begin(s,r)
 local ctx=s.context;if not ctx then return end
 R.serial=R.serial+1
 local stem=stemFor(r.mon)
 local spec=V.MoveFXExtractor and V.MoveFXExtractor.peek(nil,{name=stem})
 local release={age=0,serial='release-'..R.serial,entries={},models={},stem=stem}
 r.release=release
 if not spec then release.error='Source ball_open cache unavailable';return end
 spec=V.WazaPhasePolicy.select(spec,{phase='open'});release.spec=spec
 local entries={}
 for _,phase in ipairs(spec.wazaPhases or {})do if phase.name=='open' then
  for _,e in ipairs(phase.entries or {})do local copy={};for k,v in pairs(e)do copy[k]=v end;entries[#entries+1]=copy end
 end end
 release.entries=V.WazaSequenceRuntime.resolveEntryStarts(entries,{0,0,0,0})
 local x,z,dx,dz=V.DoublesPresenter.anchor(ctx,r.slot)
 if not x then return end
 local k=(ctx.services or {}).figureScale or .38
 local height=r.actor and (r.actor.height or 16)*(r.actor.worldScale or 1) or 16
 local origin={x/k,((ctx.groundY or 0)+3.85)/k,z/k}
 release.origin={x,(ctx.groundY or 0)+3.85,z}
 -- The retail open-ball prop's visible/button face is aligned with local -Z.
 -- Rotate that axis toward the lane's field-facing vector so player and enemy
 -- throws both open toward the battlefield, including diagonal doubles lanes.
 -- Keep it facing into the field through
 -- the stationary open chapter, including mirrored/diagonal enemy lanes.
 dx,dz=tonumber(dx) or 0,tonumber(dz) or (r.slot:match('^player') and -1 or 1)
 local length=math.sqrt(dx*dx+dz*dz)
 if length<.0001 then dx,dz,length=0,(r.slot:match('^player') and -1 or 1),1 end
 release.forward={dx/length,dz/length}
 release.geometry={origin=origin,target={origin[1]+release.forward[1],origin[2],origin[3]+release.forward[2]},actor=r.actor,
  style='self',sourceVisualHeight=height,targetVisualHeight=height,referenceVisualHeight=height,
  fightDistance=1,sourceUnits={x=height/100,y=height/100,z=height/100}}
end
function R.update(s,r,dt)
 local a=r.release;if not a then return end
 a.age=a.age+dt
 if a.age>=50/60 and not a.cryPlayed then
  a.cryPlayed=true
  local ok,Sound=pcall(V.engineRequire or require,'src.core.Sound')
  local data=s.screen and s.screen.game and s.screen.game.data
  if ok and Sound.playCry and data and r.mon then
   local played,err=pcall(Sound.playCry,data,r.mon.species,11)
   if not played then a.cryError=tostring(err)end
  end
 end
 local frame=a.age*60
 if r.actor then r.actor.releaseFlash=math.max(0,math.min(1,(1.5-a.age)/.35)) end
 for _,row in ipairs(a.entries)do if not row.started and frame>=row.startFrame then
  row.started=true;local e=row.entry
  if e.kind=='particle' and a.geometry then
   V.CurrentSpriteModels:stageReleaseParticles(s.context,r.slot:match('^player') and 'player' or 'enemy',a.spec,e,a.geometry,a.serial)
  elseif e.kind=='model' and e.modelAsset then
   a.models[#a.models+1]={asset=e.modelAsset,start=row.startFrame,stop=row.startFrame+math.max(30,tonumber((e.timingPoints or {})[2]) or 30)}
  elseif e.kind=='sound' and V.WazaAudioRuntime then
   V.WazaAudioRuntime:start(s.context,{spec=a.spec,serial=a.serial,frame=frame,presentation="release"},e)
  end
 end end
end
function R.draw(s,ctx)
 local vp=ctx.services and ctx.services.stageVP
 if not (vp and V.WazaHandlers and V.WazaHandlers.drawAsset) then return end
 for _,r in ipairs(s.actorOrder or {})do local a=r.release
  if r.visible and a and a.origin then
   local p=a.origin;local u=1.1
   local forward=a.forward or {0,-1};local sn,cs=-forward[1],-forward[2]
   local matrix={u*cs,0,u*sn,p[1],0,u,0,p[2],-u*sn,0,u*cs,p[3],0,0,0,1}
   for _,m in ipairs(a.models)do local frame=a.age*60
    if frame>=m.start and frame<m.stop then
     local ok,why=V.WazaHandlers.drawAsset(ctx,m.asset,vp,matrix,frame-m.start,{opacity=1,cullMode='none'})
     if not ok then a.error=tostring(why) end
    end
   end
  end
 end
end
function R.finish(s,r)
 if r.actor then r.actor.releaseFlash=0 end
 local a=r.release
 if a and V.WazaAudioRuntime then
  for _,row in ipairs(a.entries)do if row.started and row.entry.kind=='sound' then
   V.WazaAudioRuntime:cancel(s.context,{serial=a.serial},row.entry)
  end end
 end
 if r.faintReturn then R.finishFaint(r.faintReturn,r.faintReturn.context,{player=r},'doubles-presentation-finish');r.faintReturn=nil end
 if r.actor then r.actor.cbeSourceFaintReturn=nil end
 r.release=nil
end

function R.beginFaintSingle(context,side,mon,actor)
 local spec,stem,why=faintSpec(mon);if not spec then return nil,why end
 R.serial=R.serial+1
 local f={serial='faint-return-'..R.serial,spec=spec,stem=stem,sourceSelector=0x10,
  sourceItemBallField='downinWzxDataId',sourceResourceGroup=4,age=0,actor=actor,context=context}
 local target=side=='player' and 'enemy' or 'player'
 local started,startWhy=startFaintWorld(f,context,side,target,nil)
 if started and actor then actor.cbeSourceFaintReturn=true end
 return started,startWhy
end
function R.updateFaintSingle(context,f,dt)
 if not (f and f.instance) then return false end
 f.age=f.age+math.max(0,tonumber(dt) or 0)
 local ok,why=withFaintWorld(f,context,nil,function(ctx)
  V.WazaSequenceRuntime:update(ctx,dt)
  if V.CurrentSpriteModels.updateReleaseFx then V.CurrentSpriteModels:updateReleaseFx(ctx,dt) end
 end)
 if not ok then f.error=tostring(why);return false end
 return true
end
function R.drawFaintSingle(context,f)
 if not (f and f.instance) then return false end
 local ok,drew=withFaintWorld(f,context,nil,function(ctx)
  local any=false
  if V.WazaHandlers and V.WazaHandlers.drawWorld then any=V.WazaHandlers.drawWorld(ctx)==true or any end
  if V.CurrentSpriteModels.drawReleaseFx then any=V.CurrentSpriteModels:drawReleaseFx(ctx)==true or any end
  return any
 end)
 return ok and drew==true
end
function R.beginFaint(s,r)
 local spec,stem,why=faintSpec(r and r.mon);if not spec then if r then r.faintReturnError=why end;return nil,why end
 R.serial=R.serial+1
 local f={serial='faint-return-'..R.serial,spec=spec,stem=stem,sourceSelector=0x10,
  sourceItemBallField='downinWzxDataId',sourceResourceGroup=4,age=0,actor=r.actor}
 local ctx,records,ctxWhy=doublesFaintContext(s,r,f);if not ctx then r.faintReturnError=ctxWhy;return nil,ctxWhy end
 local started,startWhy=startFaintWorld(f,ctx,'player','enemy',records)
 if not started then r.faintReturnError=startWhy;return nil,startWhy end
 if r.actor then r.actor.cbeSourceFaintReturn=true end
 r.faintReturn=f
 return f
end
function R.updateFaint(s,r,dt)
 local f=r and r.faintReturn;if not (f and f.instance) then return false end
 f.age=f.age+math.max(0,tonumber(dt) or 0)
 local ctx,records,why=doublesFaintContext(s,r,f);if not ctx then f.error=why;return false end
 local ok,err=withFaintWorld(f,ctx,records,function(localCtx)
  V.WazaSequenceRuntime:update(localCtx,dt)
  if V.CurrentSpriteModels.updateReleaseFx then V.CurrentSpriteModels:updateReleaseFx(localCtx,dt) end
 end)
 if not ok then f.error=tostring(err);return false end
 return true
end
function R.drawFaint(s,r,context)
 local f=r and r.faintReturn;if not (f and f.instance) then return false end
 local ctx,records=doublesFaintContext(s,r,f);if not ctx then return false end
 ctx.services=context and context.services or ctx.services
 local ok,drew=withFaintWorld(f,ctx,records,function(localCtx)
  local any=false
  if V.WazaHandlers and V.WazaHandlers.drawWorld then any=V.WazaHandlers.drawWorld(localCtx)==true or any end
  if V.CurrentSpriteModels.drawReleaseFx then any=V.CurrentSpriteModels:drawReleaseFx(localCtx)==true or any end
  return any
 end)
 return ok and drew==true
end
local function faintBodyComplete(f)
 local actor=f and f.actor
 if actor and type(actor.faintBodyComplete)=='function' then return actor:faintBodyComplete() end
 if actor and actor.pendingFaint then return false end
 return true
end
function R.faintComplete(f)
 return faintBodyComplete(f) and (not f or not f.instance or f.instance.done==true)
end
function R.faintDuration(f) return f and tonumber(f.sourceDuration) or nil end
function R.faintActorVisible(f,owner)
 if not f then return nil end
 if not faintBodyComplete(f) then return true end
 owner=owner or 'player'
 local st=f.world and f.world.controllers and f.world.controllers[owner]
 if st and st.hidden==true then return false end
 return nil
end
function R.faintActorMotionFrozen(f,owner)
 if not f then return false end
 owner=owner or 'player'
 local st=f.world and f.world.controllers and f.world.controllers[owner]
 return st and st.motionFrozen==true or false
end
function R.finishFaint(f,context,records,reason)
 if not f then return end
 withFaintWorld(f,context or f.context,records,function(ctx)
  if V.WazaSequenceRuntime and V.WazaSequenceRuntime.finish then V.WazaSequenceRuntime:finish(ctx,reason or 'faint-return-finished') end
  if V.CurrentSpriteModels and V.CurrentSpriteModels.clearReleaseFx then V.CurrentSpriteModels:clearReleaseFx() end
 end)
 if f.actor then f.actor.cbeSourceFaintReturn=nil end
 f.instance=nil;f.world=nil
end
return R
