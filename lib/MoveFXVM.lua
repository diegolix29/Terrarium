local M={version=17,source="GC6E01 FieldParticleFile + PSGeneratorState/PSParticle retail runtime"}

-- Colosseum has two distinct particle-runtime layers:
--   Waza Type-3 -> PSGeneratorState -> emitted PSParticle -> particle bytecode.
-- 1.9.x collapsed both layers into a synthetic emitter and then interpreted the
-- generator record as though it were already a particle. This VM keeps the two
-- source objects distinct and uses bank-local script ids/table lookups exactly.

local FRAME_DT=1/60
local MAX_TOTAL_PARTICLES=768
local MAX_TOTAL_GENERATORS=192
local MAX_STEPS_PER_UPDATE=30
local MAX_COMMANDS_PER_FRAME=256
local MAX_EMIT_PER_FRAME=96
local MAX_EFFECT_SECONDS=30 -- watchdog only; source objects normally retire themselves

local function hasBit(v,bit) return math.floor((tonumber(v) or 0)/bit)%2>=1 end
local function setBit(v,bit,on)
  v=tonumber(v) or 0
  local present=hasBit(v,bit)
  if on then return present and v or (v+bit) end
  return present and (v-bit) or v
end
local function clamp(v,a,b) if v<a then return a elseif v>b then return b else return v end end
local function atan2(y,x)
  if type(math.atan2)=="function" then return math.atan2(y,x) end
  if x>0 then return math.atan(y/x) end
  if x<0 then return math.atan(y/x)+(y>=0 and math.pi or -math.pi) end
  return y>0 and math.pi/2 or (y<0 and -math.pi/2 or 0)
end
local function phaseRole(phase)
  phase=tostring(phase or "all"):lower()
  return (phase:match("^damage") or phase=="status") and "damage" or "attack"
end
local function vecLength(v)
  local x,y,z=tonumber(v and v[1]) or 0,tonumber(v and v[2]) or 0,tonumber(v and v[3]) or 0
  return math.sqrt(x*x+y*y+z*z)
end
local function normalizeTo(v,length)
  local n=vecLength(v);if n<1e-9 then return {0,0,tonumber(length) or 0} end
  local k=(tonumber(length) or 0)/n
  return {(v[1] or 0)*k,(v[2] or 0)*k,(v[3] or 0)*k}
end
local function add3(a,b) return {(a and a[1] or 0)+(b and b[1] or 0),(a and a[2] or 0)+(b and b[2] or 0),(a and a[3] or 0)+(b and b[3] or 0)} end

local function hexToBytes(hex)
  if type(hex)~="string" or hex=="" then return "" end
  local out={};for i=1,#hex-1,2 do local n=tonumber(hex:sub(i,i+1),16);if not n then break end;out[#out+1]=string.char(n) end
  return table.concat(out)
end
local function u8(data,pos) if pos>#data then return 0,#data+1 end;return data:byte(pos) or 0,pos+1 end
local function s8(data,pos) local v;v,pos=u8(data,pos);if v>=128 then v=v-256 end;return v,pos end
local function u16(data,pos) local a,b=data:byte(pos,pos+1);if not b then return 0,#data+1 end;return a*256+b,pos+2 end
local function u32(data,pos) local a,b,c,d=data:byte(pos,pos+3);if not d then return 0,#data+1 end;return ((a*256+b)*256+c)*256+d,pos+4 end
local function f32(data,pos)
  local bits,nextPos=u32(data,pos);local sign=bits>=2147483648 and -1 or 1;if bits>=2147483648 then bits=bits-2147483648 end
  local exp=math.floor(bits/8388608);local mant=bits-exp*8388608
  if exp==255 then return mant==0 and sign*1e30 or 0,nextPos end
  if exp==0 then return mant==0 and 0 or sign*(mant/8388608)*(2^-126),nextPos end
  return sign*(1+mant/8388608)*(2^(exp-127)),nextPos
end
local function readTime(data,pos)
  local b;b,pos=u8(data,pos);if b>=128 then local b2;b2,pos=u8(data,pos);return (b-128)*256+b2,pos end;return b,pos
end
local function rng(seed)
  -- Retail HSD_Randf / fn_801ADC7C is the MSVC-style 32-bit LCG, not the
  -- Park-Miller generator older CBE revisions used. Particle placement,
  -- randomized colour/scale commands and positive generator emission rates all
  -- consume this sequence, so the wrong RNG changes the visible character of
  -- every source bank even when its bytecode is otherwise decoded perfectly.
  local state=math.floor(tonumber(seed) or 0)%4294967296
  if state<0 then state=state+4294967296 end
  return function()
    state=(state*0x343FD+0x269EC3)%4294967296
    return math.floor(state/65536)/65536
  end
end
-- Retail particles and generators consume one HSD_Randf stream.  A separate
-- RNG per generator/particle changes not just decoration but emitter density,
-- cone angles, colour ramps and child selection.  Keep one module-level stream
-- for normal runtime so overlapping Waza consume randomness in execution order,
-- while tests/tools may supply an explicit stream/seed to M.start().
local sharedRandom=rng(1)
local function resetSharedRandom(seed) sharedRandom=rng(seed or 1) end

local function countBits(mask,n)
  local c=0;for i=0,n-1 do if hasBit(mask,2^i) then c=c+1 end end;return c
end

-- Framing is part of ownership. A source program is executable only if every
-- instruction boundary is known. Notably AC consumes two floats after time and
-- F1 consumes a u16 table index. Consuming the following opcode as an extra
-- argument turns the source CF color ramp into a bogus 0x82 position command
-- in Seismic Toss/Vital Throw (and consumes loop delays in other banks).
local function programSupported(commandHex,visit)
  local data=hexToBytes(commandHex);if data=="" then return false end
  local pos=1;local guard=0
  local function need(n) if pos+n-1>#data then return false end;pos=pos+n;return true end
  local function timeArg() if pos>#data then return false end;local b=data:byte(pos) or 0;pos=pos+1;if b>=128 then return need(1) end;return true end
  while pos<=#data and guard<8192 do
    guard=guard+1;local op=data:byte(pos);if visit then visit(op,pos) end;pos=pos+1
    if op<0x80 then
      if hasBit(op,0x20) and not need(1) then return false end
      if hasBit(op,0x40) and not need(1) then return false end
    elseif op>=0x80 and op<=0x9F then if not need(countBits(op%8,3)*4) then return false end
    elseif op==0xA0 or op==0xB6 then if not timeArg() or not need(4) then return false end
    elseif op==0xAC then if not timeArg() or not need(8) then return false end
    elseif op==0xFE or op==0xFF then return true
    elseif op==0xA1 or op==0xAD or (op>=0xAE and op<=0xB2) or op==0xB4 or op==0xB5
        or op==0xE2 or op==0xE6 or op==0xE7 or op==0xF5 or op==0xF6 or op==0xF7
        or op==0xFB or op==0xFC or op==0xFD then
    elseif op==0xA2 or op==0xA3 or op==0xA9 or op==0xAB or op==0xE8 then if not need(4) then return false end
    elseif op==0xA4 or op==0xA5 or op==0xB9 or op==0xF2 then if not need(2) then return false end
    elseif op==0xF1 then if not need(2) then return false end
    elseif op==0xA6 or op==0xAA then if not need(4) then return false end
    elseif op==0xA7 or op==0xB7 or op==0xBF or op==0xE1 or op==0xE3 or op==0xE4 or op==0xE5 or op==0xFA then if not need(1) then return false end
    elseif op==0xA8 or op==0xBE then if not need(12) then return false end
    elseif op==0xB3 then if not timeArg() or not need(3) then return false end
    elseif op==0xB8 then if not need(9) then return false end
    elseif op==0xBA or op==0xBB or op==0xE0 then if not need(4) then return false end
    elseif op==0xBC then if not need(2) then return false end
    elseif op==0xBD then if not need(8) then return false end
    elseif op>=0xC0 and op<=0xCF then if not timeArg() or not need(countBits(op-0xC0,4)) then return false end
    elseif op>=0xD0 and op<=0xDF then if not timeArg() or not need(countBits(op-0xD0,4)) then return false end
    elseif op==0xE9 then
      if not need(2) then return false end;local mask=data:byte(pos-2) or 0;if not need(countBits(mask,4)) then return false end
    elseif op==0xEA or op==0xEB then
      if not timeArg() or not need(1) then return false end;local flags=data:byte(pos-1) or 0
      local n=(hasBit(flags,1) and 1 or 0)+(hasBit(flags,8) and 1 or 0);if not need(n) then return false end
    elseif op==0xEC then if not need(5) then return false end
    elseif op==0xED then if not need(9) then return false end
    elseif op==0xEF or op==0xF0 then if not need(3) then return false end
    elseif op==0xF3 then if not need(9) or not timeArg() then return false end
    elseif op==0xF4 then if not need(16) then return false end
    else return false end
  end
  return guard<8192 and pos==#data+1
end
M.programSupported=programSupported

local function exactPhaseMatches(g,entry)
  if type(entry)~="table" then return true end
  return not (entry.phase~=nil and g.phase~=nil and tostring(entry.phase):lower()~=tostring(g.phase):lower())
end
local function bankMatchesEntry(g,entry)
  if type(entry)~="table" then return true end
  if entry.sourceBank~=nil and g.sourceBank~=nil and tonumber(entry.sourceBank)~=tonumber(g.sourceBank) then return false end
  if entry.bank~=nil and g.bank~=nil and tonumber(entry.bank)~=tonumber(g.bank) then return false end
  return true
end
local function executable(g,role,entry)
  return phaseRole(g.phase)==role and exactPhaseMatches(g,entry) and type(g.commandHex)=="string" and #g.commandHex>=2 and programSupported(g.commandHex)
end
local function selectRoot(spec,entry,role)
  local wanted=type(entry)=="table" and tonumber(entry.selector~=nil and entry.selector or entry.rootRef) or nil
  local same,any,marked=nil,nil,nil
  for _,g in ipairs(type(spec)=="table" and (spec.generatorPrograms or {}) or {}) do
    if executable(g,role,entry) then
      any=any or g;if g.root==true then marked=marked or g end
      local id=tonumber(g.scriptId~=nil and g.scriptId or g.bankIndex)
      if wanted~=nil and id==wanted then if bankMatchesEntry(g,entry) then return g else same=same or g end end
    end
  end
  -- An explicit Type-3 selector is a bank-local identity. Using an unrelated
  -- root disguises an incomplete cache as a different move effect.
  if wanted~=nil then return nil end
  if type(entry)=="table" and (entry.bank~=nil or entry.sourceBank~=nil) then
    for _,g in ipairs(spec.generatorPrograms or {}) do
      if executable(g,role,entry) and bankMatchesEntry(g,entry) and g.root==true then return g end
    end
    return nil
  end
  return marked or any
end
function M.hasRole(spec,role)
  role=tostring(role or "attack")
  for _,g in ipairs(type(spec)=="table" and (spec.generatorPrograms or {}) or {}) do if executable(g,role,nil) and g.root==true then return true end end
  return false
end
function M.hasEntry(spec,entry,role)
  if type(spec)~="table" or type(entry)~="table" or #(spec.textures or {})<1 then return false end
  local root=selectRoot(spec,entry,tostring(role or phaseRole(entry.phase)))
  if not root then return false end
  for _,tex in ipairs(spec.textures) do
    if tex.bank==nil or root.bank==nil or tonumber(tex.bank)==tonumber(root.bank) then return true end
  end
  return false
end
function M.programSpawnsChildren(commandHex)
  local found=false
  local valid=programSupported(commandHex,function(op)
    if op==0xA4 or op==0xA5 or op==0xAA or op==0xB9 or op==0xEF or op==0xF0 or op==0xF1 or op==0xF2 then found=true end
  end)
  return valid and found
end

local function templateKey(bank,id) return tostring(tonumber(bank) or 1)..":"..tostring(tonumber(id) or 0) end
local function addFault(fx,kind,detail)
  fx.opcodeFaults=fx.opcodeFaults or {};if #fx.opcodeFaults<64 then fx.opcodeFaults[#fx.opcodeFaults+1]={frame=fx.frame,kind=kind,detail=detail} end
end
local function lookupScriptId(fx,bank,tableIndex)
  local t=fx.spec and fx.spec.lookupTables and fx.spec.lookupTables[tonumber(bank) or bank]
  local v=t and (t[tableIndex]~=nil and t[tableIndex] or t[tostring(tableIndex)])
  if v==nil then addFault(fx,"lookup-miss",tostring(bank)..":"..tostring(tableIndex));return nil end
  return tonumber(v)
end
local function findTemplate(fx,bank,scriptId)
  return fx.templateById[templateKey(bank,scriptId)]
end

local function generatorBasisVelocity(g)
  return {tonumber(g.velocityX) or tonumber(g.params and g.params[3]) or 0,tonumber(g.velocityY) or tonumber(g.params and g.params[4]) or 0,tonumber(g.velocityZ) or tonumber(g.params and g.params[5]) or 0}
end
local function generatorDirectionTransform(v,velocity,mode)
  -- Exact velocity-derived basis used by retail generateParticle_8017424C.
  -- Mode 1 is the one native exception: its line-vector is transformed only by
  -- generator Euler/AppSRT (identity at creation), not by velocity direction.
  if mode==1 then return {v[1] or 0,v[2] or 0,v[3] or 0} end
  local m=vecLength(velocity);if m<=1e-9 then return {v[1] or 0,v[2] or 0,v[3] or 0} end
  local e=normalizeTo(velocity,1)
  local yaw
  if math.abs(e[3])<1e-9 then yaw=e[2]>=0 and math.pi/2 or -math.pi/2 else yaw=atan2(e[2],e[3]) end
  local sy,cy=math.sin(yaw),math.cos(yaw)
  local flat=e[3]*cy+e[2]*sy
  local pitch
  if math.abs(flat)<1e-9 then pitch=e[1]>=0 and math.pi/2 or -math.pi/2 else pitch=atan2(e[1],flat) end
  local sp,cp=math.sin(pitch),math.cos(pitch)
  return {
    cp*(v[1] or 0)+sp*(v[2] or 0),
    (-sy*sp)*(v[1] or 0)+cy*(v[2] or 0)+(sy*cp)*(v[3] or 0),
    (-cy*sp)*(v[1] or 0)-sy*(v[2] or 0)+(cy*cp)*(v[3] or 0),
  }
end

local function newGenerator(fx,template,position,parentParticle,phaseFlags)
  if not template or #fx.generators>=MAX_TOTAL_GENERATORS then return nil end
  fx.spawnSerial=fx.spawnSerial+1;local g=template.gen;local rate=tonumber(g.random) or tonumber(g.emissionRate) or tonumber(g.params and g.params[8]) or 0
  local random=fx.random or sharedRandom
  -- Retail HSD_Generator initializes `count` differently for kind bit 0x100.
  -- That branch is visible on the very first emitted frame, so treating every
  -- generator as count=0/random() shifts authored launch density and timing.
  local flags=tonumber(g.flags) or 0
  local acc
  if hasBit(flags,0x100) then
    if rate<0 then acc=(1+rate>1.1920929e-7) and 1 or 0 else acc=.9999999 end
  elseif rate<0 then acc=0
  else acc=random() end
  local runtimeFlags=tonumber(g.flags) or 0
  if phaseFlags~=nil then
    -- EF/F0 replace, rather than OR, the source generator's 3-bit phase field.
    -- Retail stores it at flags bits 25..27 before the child generator runs.
    local old=math.floor(runtimeFlags/0x02000000)%8
    runtimeFlags=runtimeFlags-old*0x02000000+(math.floor(tonumber(phaseFlags) or 0)%8)*0x02000000
  end
  local inst={template=template,gen=g,bank=tonumber(g.bank) or 1,scriptId=tonumber(g.scriptId~=nil and g.scriptId or g.bankIndex) or 0,
    position={position and position[1] or 0,position and position[2] or 0,position and position[3] or 0},
    random=random,accumulator=acc,rate=rate,maxLife=tonumber(g.maxLife) or 0,age=0,alive=true,childCount=0,parentParticle=parentParticle,
    autoRoot=template.autoRoot==true,runtimeFlags=runtimeFlags,runtimeAngleFlags=tonumber(g.angleFlags) or 0,phaseFlags=phaseFlags}
  fx.generators[#fx.generators+1]=inst;fx.emitters=fx.generators;return inst
end

local function sourceParticleState(template)
  local g=template.gen;return {
    flags=tonumber(g.flags) or 0,animIndex=tonumber(g.animIndex) or tonumber(g.texGroup) or 0,
    repeatCount=tonumber(g.repeatCount) or tonumber(g.particleLife) or 0,
    size=tonumber(g.particleSize) or tonumber(g.params and g.params[9]) or 1,
    gravity=tonumber(g.gravity) or tonumber(g.params and g.params[1]) or 0,
    friction=tonumber(g.friction) or tonumber(g.params and g.params[2]) or 1,
    velocity={tonumber(g.velocityX) or tonumber(g.params and g.params[3]) or 0,tonumber(g.velocityY) or tonumber(g.params and g.params[4]) or 0,tonumber(g.velocityZ) or tonumber(g.params and g.params[5]) or 0},
  }
end
local function alphaCompareCurrent(p)
  local a=p and p.alphaCompare
  if type(a)~="table" then return 0x33,1,255 end
  local p1,p2=tonumber(a.p1) or 1,tonumber(a.p2) or 255
  local count,remain=tonumber(a.count) or 0,tonumber(a.remaining) or 0
  if count>0 then
    local scale=clamp(remain/count,0,1)
    p1=math.floor((tonumber(a.target1) or p1)+(p1-(tonumber(a.target1) or p1))*scale+.5)
    p2=math.floor((tonumber(a.target2) or p2)+(p2-(tonumber(a.target2) or p2))*scale+.5)
  end
  return tonumber(a.mode) or 0x33,clamp(p1,0,255),clamp(p2,0,255)
end
local function newParticleFromTemplate(fx,template,position,velocity,parent,generator,inheritVelocity,flagsOverride)
  if not template or #fx.particles>=MAX_TOTAL_PARTICLES then return nil end
  fx.spawnSerial=fx.spawnSerial+1;local g=template.gen;local st=sourceParticleState(template);local flags=tonumber(flagsOverride) or st.flags
  local vel={st.velocity[1],st.velocity[2],st.velocity[3]};if velocity then vel={velocity[1] or 0,velocity[2] or 0,velocity[3] or 0} end
  if inheritVelocity and parent then vel={parent.velocity[1],parent.velocity[2],parent.velocity[3]} end
  local p={alive=true,frame=0,bank=tonumber(g.bank) or 1,sourceBank=g.sourceBank,gptOffset=g.gptOffset,scriptId=tonumber(g.scriptId~=nil and g.scriptId or g.bankIndex) or 0,
    animIndex=st.animIndex,position={position and position[1] or 0,position and position[2] or 0,position and position[3] or 0},velocity=vel,
    scaleFactor=st.gravity,gravity=st.gravity,frictionFactor=st.friction,friction=st.friction,
    repeatCount=math.max(1,math.floor(st.repeatCount)+1),size=st.size,sizeTarget=st.size,sizeTime=0,
    rotation=0,heading=0,headingSpeed=0,headingAccel=0,headingTime=0,
    prim={255,255,255,255},primTarget={255,255,255,255},primTime=0,primCountdown=0,primDisplay={255,255,255,255},
    env={0,0,0,0},envTarget={0,0,0,0},envTime=0,envCountdown=0,envDisplay={0,0,0,0},
    flags=flags,textureIndex=0,textureOff=not hasBit(flags,0x400),objRefIndex=0,
    -- Texture coordinate reversal is owned by the retail 0x40000/0x80000
    -- bits (E4/E5). Low bits 0x20/0x40 are a separate particle mode family
    -- manipulated by AE..B1 and must never mirror the source card.
    flipS=hasBit(flags,0x40000),flipT=hasBit(flags,0x80000),
    primEnv=hasBit(flags,0x80),texEdge=hasBit(flags,0x8),nearest=hasBit(flags,0x200),
    blendMode=math.floor(flags/0x400000)%4,
    alphaCompare={mode=0x33,p1=(math.floor(flags/0x400000)%4)>=2 and 0 or 1,p2=255,
      target1=(math.floor(flags/0x400000)%4)>=2 and 0 or 1,target2=255,count=0,remaining=0},
    trail=hasBit(flags,0x100000),trailAlpha=1,dirVec=hasBit(flags,0x200000),noZComp=hasBit(flags,0x10000000),
    -- 0x8000 + bits 12..14 are the PS particle-camera tracking slot, not a
    -- Pokemon body-joint selector. Waza owner/body attachment is handled by the
    -- Type-3 entry/AppSRT layer outside this script state.
    jointId=nil,updateJoint=false,jointExplicit=false,cameraSlot=0,
    cameraTrackSlot=hasBit(flags,0x8000) and (math.floor(flags/0x1000)%8) or nil,
    cmdPos=1,wait=1,savedPC=1,loopCount=0,loopPos=1,data=template.data,random=fx.random or sharedRandom,
    generator=generator,parent=parent}
  -- Keep the birth part transform outside script-local positions. Source
  -- position opcodes (80..8F) must not erase the emitter's world attachment.
  -- Children inherit that birth frame, so old foam does not slide with a wave.
  local owner=parent or (generator and generator.parentParticle)
  local matrix=owner and owner.attachmentMatrix or (generator and generator.autoRoot and fx.emissionTransform)
  if matrix then p.attachmentMatrix={};for k=1,12 do p.attachmentMatrix[k]=matrix[k] end end
  fx.particles[#fx.particles+1]=p;if generator then generator.childCount=generator.childCount+1 end;return p
end

local function emitGeneratorParticle(fx,gen)
  local g=gen.gen;local random=gen.random;local mode=(tonumber(g.angleFlags) or 0)%16
  local radius=tonumber(g.radius) or tonumber(g.params and g.params[6]) or 0
  local angle=tonumber(g.angle) or tonumber(g.params and g.params[7]) or 0
  local sx=tonumber(g.shapeX) or tonumber(g.params and g.params[10]) or 0
  local sy=tonumber(g.shapeY) or tonumber(g.params and g.params[11]) or 0
  local sz=tonumber(g.shapeZ) or tonumber(g.params and g.params[12]) or 0
  local baseVel=generatorBasisVelocity(g);local speed=vecLength(baseVel);local pos={0,0,0};local vel={baseVel[1],baseVel[2],baseVel[3]}
  if mode==1 then
    -- Retail mode 1 is a line emitter: one random scalar selects a point along
    -- the complete source vector. Unlike the other built-in shapes, mode 1 is
    -- explicitly exempt from the velocity-derived direction basis.
    local r=random();pos=generatorDirectionTransform({r*sx,r*sy,r*sz},baseVel,mode)
  elseif mode==5 then
    -- Retail PSGeneratorState mode 5 is an oriented rectangular volume/surface,
    -- not an axis-aligned random box. Negative source extents set shapeFlags;
    -- those bits snap the corresponding coordinate to a face, including the
    -- area-weighted two/three-face cases. psCreateGeneratorID initializes the
    -- rect transform as diag(shapeX,shapeY,shapeZ), so reproduce that exact
    -- source contract before applying the velocity-aligned generator basis.
    local x,y,z=random(),random(),random()
    local shapeFlags=(sx<0 and 1 or 0)+(sy<0 and 2 or 0)+(sz<0 and 4 or 0)
    if shapeFlags==1 then x=x>.5 and 1 or 0
    elseif shapeFlags==2 then y=y>.5 and 1 or 0
    elseif shapeFlags==3 then
      local d=sx+sy;local choose=(math.abs(d)>1e-9) and sx/d or .5
      if random()>choose then y=y>.5 and 1 or 0 else x=x>.5 and 1 or 0 end
    elseif shapeFlags==4 then z=z>.5 and 1 or 0
    elseif shapeFlags==5 then
      local d=sx+sz;local choose=(math.abs(d)>1e-9) and sx/d or .5
      if random()>choose then z=z>.5 and 1 or 0 else x=x>.5 and 1 or 0 end
    elseif shapeFlags==6 then
      local d=sy+sz;local choose=(math.abs(d)>1e-9) and sy/d or .5
      if random()>choose then z=z>.5 and 1 or 0 else y=y>.5 and 1 or 0 end
    elseif shapeFlags==7 then
      local yz,xy=sy*sz,sx*sy;local total=sx*(sy+sz)+yz
      local q=random();local inv=math.abs(total)>1e-9 and 1/total or 0
      if inv~=0 and q<inv*xy then z=z>.5 and 1 or 0
      elseif inv~=0 and q>1-inv*sx*sz then y=y>.5 and 1 or 0
      else x=x>.5 and 1 or 0 end
    end
    pos=generatorDirectionTransform({(x-.5)*sx,(y-.5)*sy,(z-.5)*sz},baseVel,mode)
    -- The native rect matrix's Z column supplies emission direction.
    local axis={0,0,sz};local axisLen=vecLength(axis)
    vel=axisLen>1e-9 and generatorDirectionTransform(normalizeTo(axis,speed),baseVel,mode) or generatorDirectionTransform(baseVel,baseVel,mode)
  elseif mode==8 then
    -- Retail mode 8 is a spherical/spherical-cap emitter. psCreateGeneratorID
    -- derives the cap angle and radial velocity scale from the source velocity;
    -- older CBE fell through to the planar cone path, pinning all births to Z=0.
    local cap=math.abs(baseVel[1])
    local latitude
    if cap==0 or math.abs(cap-math.pi)<.001 then
      latitude=math.pi*math.sqrt(random());if random()<.5 then latitude=math.pi-latitude end
    else latitude=cap*math.sqrt(random()) end
    local longitude=2*math.pi*random()
    local radial=radius<0 and -radius or radius*math.sqrt(random())
    local unit={math.sin(latitude)*math.cos(longitude),math.sin(longitude)*math.sin(latitude),math.cos(latitude)}
    unit=generatorDirectionTransform(unit,baseVel,mode)
    pos={unit[1]*radial,unit[2]*radial,unit[3]*radial}
    local radialSpeed=(baseVel[1] or 0)<0 and -speed or speed
    if radius>=0 and radialSpeed<0 and math.abs(radius)>1e-9 then radialSpeed=radialSpeed*(radial/radius) end
    vel={unit[1]*radialSpeed,unit[2]*radialSpeed,unit[3]*radialSpeed}
  elseif mode==2 then
    local theta=random()*math.pi*2;local rr=radius<0 and math.abs(radius) or math.abs(radius)*random();pos={rr*math.cos(theta),rr*math.sin(theta),0}
  else
    local minAngle,maxAngle=sx,sy;if minAngle==0 and maxAngle==0 then minAngle,maxAngle=0,math.pi*2 end
    -- When source `angle` is negative, generateParticle_8017424C chooses one
    -- random starting azimuth for the whole emission batch and then advances by
    -- an even angular step for every particle.  Independent random theta values
    -- turn authored rings/fans into noisy sprays.
    local theta
    if angle<0 and gen.angleBatch then
      gen.angleBatch.current=gen.angleBatch.current+gen.angleBatch.step
      theta=gen.angleBatch.current
    else theta=minAngle+(maxAngle-minAngle)*random() end
    local radiusFactor=radius<0 and 0 or random();if mode==3 or mode==4 then radiusFactor=math.sqrt(radiusFactor) end
    local rr=radius<0 and -radius or radiusFactor*radius
    local cone
    if mode==6 then
      if angle<0 then
        if math.abs(rr)<1e-9 then cone=sz>=0 and -angle or (math.pi-angle)
        else cone=math.pi-atan2(sz,rr)-angle end
      else
        cone=radiusFactor*angle
        if math.abs(rr)<1e-9 then cone=sz>=0 and angle or (math.pi+angle)
        else cone=angle+(math.pi-atan2(sz,rr)) end
      end
    elseif mode==7 then cone=angle<0 and (math.pi-angle) or (math.pi+angle)
    else cone=radiusFactor*math.abs(angle) end
    pos={rr*math.cos(theta),rr*math.sin(theta),(mode==6 or mode==7) and random()*sz or 0}
    if mode==6 then pos[1]=pos[1]*(1-(sz~=0 and pos[3]/sz or 0));pos[2]=pos[2]*(1-(sz~=0 and pos[3]/sz or 0)) end
    pos=generatorDirectionTransform(pos,baseVel,mode)
    if speed>1e-9 then
      vel={speed*math.sin(cone)*math.cos(theta),speed*math.sin(cone)*math.sin(theta),speed*math.cos(cone)}
      if mode==3 then for i=1,3 do vel[i]=vel[i]*radiusFactor end end
      vel=generatorDirectionTransform(vel,baseVel,mode)
    end
  end
  pos=add3(gen.position,pos)
  -- Root emitters follow their live Waza attachment at emission time. Existing
  -- particles and child generators retain their source-space positions.
  -- Explicit joint-follow particles are positioned by their own joint opcode.
  if gen.autoRoot and not gen.parentParticle and fx.emissionOrigin and not hasBit(tonumber(g.flags) or 0,0x8000) then
    pos=add3(pos,fx.emissionOrigin)
  end
  return newParticleFromTemplate(fx,gen.template,pos,vel,nil,gen,false,gen.runtimeFlags)
end

local stepParticle
local function spawnParticle(fx,parent,scriptId,inheritVelocity,tableLookup,interpretNow)
  if tableLookup then scriptId=lookupScriptId(fx,parent.bank,scriptId) end;if scriptId==nil then return nil end
  local t=findTemplate(fx,parent.bank,scriptId);if not t then addFault(fx,"script-miss",tostring(parent.bank)..":"..tostring(scriptId));return nil end
  -- psGenerateParticleID0 children keep the parent's generator ownership. That
  -- childCount is what prevents the source generator from retiring while late
  -- sparks/debris are still alive.
  local p=newParticleFromTemplate(fx,t,parent.position,nil,parent,parent and parent.generator or nil,inheritVelocity)
  if p and parent then p.jointId=parent.jointId;p.updateJoint=parent.updateJoint;p.jointExplicit=parent.jointExplicit end
  -- A4/AA/B9/F1/F2 immediately recurse into psInterpretParticle0 in retail.
  -- Waiting until the next CBE frame visibly delays secondary streams by 1/60s.
  if p and interpretNow and stepParticle then stepParticle(p,fx) end
  return p
end
local function spawnGenerator(fx,parent,scriptId,tableLookup,phaseFlags)
  if tableLookup then scriptId=lookupScriptId(fx,parent.bank,scriptId) end;if scriptId==nil then return nil end
  local t=findTemplate(fx,parent.bank,scriptId);if not t then addFault(fx,"generator-miss",tostring(parent.bank)..":"..tostring(scriptId));return nil end
  return newGenerator(fx,t,parent.position,parent,phaseFlags)
end
local function cameraTarget(fx,id)
  id=tonumber(id);local slots=fx and fx.cameraSlots
  return id and type(slots)=="table" and slots[id] or nil
end

-- Exact 3-D modifyDir cone used by the retail A9 particle opcode. The previous
-- portable path performed a deterministic X/Z yaw, flattening authored sprays
-- and consuming no HSD_Randf sample.
local function randomConeDirection(p,angle,base)
  local vx,vy,vz=(base and base[1]) or p.velocity[1],(base and base[2]) or p.velocity[2],(base and base[3]) or p.velocity[3]
  local magnitude=vecLength(p.velocity);if magnitude<=1e-9 then return {p.velocity[1],p.velocity[2],p.velocity[3]} end
  local yaw=math.abs(vz)<1e-9 and (vy>=0 and math.pi/2 or -math.pi/2) or atan2(vy,vz)
  local sy,cy=math.sin(yaw),math.cos(yaw);local flattened=vz*cy+vy*sy
  local pitch=math.abs(flattened)<1e-9 and (vx>=0 and math.pi/2 or -math.pi/2) or atan2(vx,flattened)
  local sp,cp=math.sin(pitch),math.cos(pitch)
  local azimuth=math.pi*2*p.random();local radial=magnitude*math.sin(angle)
  local rx,ry=radial*math.cos(azimuth),radial*math.sin(azimuth);local forward=magnitude*math.cos(angle)
  return {rx*cp+forward*sp,sp*(-rx*sy)+ry*cy+cp*(forward*sy),sp*(-rx*cy)-ry*sy+cp*(forward*cy)}
end

local function bakeAttachment(p)
  local a=p and p.attachmentMatrix;if type(a)~="table" then return false end
  local q=p.position
  p.position={a[1]*q[1]+a[2]*q[2]+a[3]*q[3]+a[4],
    a[5]*q[1]+a[6]*q[2]+a[7]*q[3]+a[8],a[9]*q[1]+a[10]*q[2]+a[11]*q[3]+a[12]}
  p.attachmentMatrix=nil;p.appSRTBaked=true;return true
end

local function copyColor(c)return {c[1],c[2],c[3],c[4]} end
local function sourceColorCurrent(c,t,time,countdown)
  time=tonumber(time) or 0;countdown=tonumber(countdown) or 0
  if time<=0 then return copyColor(c) end
  local scale=math.floor(countdown*65536/time)
  local out={}
  for i=1,4 do
    -- Retail uses signed 16.16 integer interpolation and an arithmetic >>16.
    out[i]=clamp(math.floor(((tonumber(t[i]) or 0)*65536+scale*((tonumber(c[i]) or 0)-(tonumber(t[i]) or 0)))/65536),0,255)
  end
  return out
end
local function commitColor(p,prefix)
  local c=p[prefix];local t=p[prefix.."Target"];local time=p[prefix.."Time"] or 0
  local countdown=p[prefix.."Countdown"] or 0
  if time>0 then p[prefix]=sourceColorCurrent(c,t,time,countdown) end
  p[prefix.."Display"]=copyColor(p[prefix])
end
local function resetColorCountdown(p,prefix)
  local time=tonumber(p[prefix.."Time"]) or 0
  if time<=0 then
    p[prefix]=copyColor(p[prefix.."Target"]);p[prefix.."Countdown"]=0
  else p[prefix.."Countdown"]=time end
  p[prefix.."Display"]=copyColor(p[prefix])
end
local function advanceColor(p,prefix)
  local time=tonumber(p[prefix.."Time"]) or 0
  local countdown=tonumber(p[prefix.."Countdown"]) or 0
  if time>0 then
    countdown=math.max(0,countdown-1);p[prefix.."Countdown"]=countdown
    if countdown==0 then
      p[prefix.."Time"]=0;p[prefix]=copyColor(p[prefix.."Target"])
    end
  end
  p[prefix.."Display"]=sourceColorCurrent(p[prefix],p[prefix.."Target"],p[prefix.."Time"],p[prefix.."Countdown"])
end
local function advanceHeading(p)
  local time=tonumber(p.headingTime) or 0
  if time<=0 then return end
  local accel=tonumber(p.headingAccel) or 0
  local speed=tonumber(p.headingSpeed) or 0
  if accel~=0 then
    p.heading=(tonumber(p.heading) or 0)+speed
    if speed>=0 then speed=speed+accel else speed=speed-accel end
    time=time-1;p.headingTime=time
    if time==0 then p.headingAccel=0;p.headingSpeed=0 else p.headingSpeed=speed end
  else
    local heading=tonumber(p.heading) or 0
    heading=heading+(speed-heading)/time
    time=time-1;p.headingTime=time;p.heading=heading
    if time==0 then p.heading=speed end
  end
end
local function sourceByteRandomDelta(p,signedAmount,factor)
  -- Retail U8ClampAdd receives `(s8)amount * 2 * HSD_Randf()`.  The sign is
  -- authored by the byte; randomness only chooses magnitude.  A symmetric
  -- +/- sampler reverses intended colour bias (notably hot/cold particle cores).
  local q=factor~=nil and factor or p.random()
  return (tonumber(signedAmount) or 0)*2*q
end
local function byteAdd(cur,delta)
  -- U8ClampAdd clamps in float then casts to u8 (truncate toward zero; after
  -- clamping the domain is non-negative, so floor is the exact conversion).
  return math.floor(clamp((tonumber(cur) or 0)+(tonumber(delta) or 0),0,255))
end

local function executeComplex(p,fx,op)
  local d=p.data;local pos=p.cmdPos;local bits=op%8
  if op>=0x80 and op<=0x87 then
    if hasBit(bits,1) then p.position[1],pos=f32(d,pos) end;if hasBit(bits,2) then p.position[2],pos=f32(d,pos) end;if hasBit(bits,4) then p.position[3],pos=f32(d,pos) end
  elseif op>=0x88 and op<=0x8F then
    if hasBit(bits,1) then local v;v,pos=f32(d,pos);p.position[1]=p.position[1]+v end;if hasBit(bits,2) then local v;v,pos=f32(d,pos);p.position[2]=p.position[2]+v end;if hasBit(bits,4) then local v;v,pos=f32(d,pos);p.position[3]=p.position[3]+v end
  elseif op>=0x90 and op<=0x97 then
    if hasBit(bits,1) then p.velocity[1],pos=f32(d,pos) end;if hasBit(bits,2) then p.velocity[2],pos=f32(d,pos) end;if hasBit(bits,4) then p.velocity[3],pos=f32(d,pos) end
  elseif op>=0x98 and op<=0x9F then
    if hasBit(bits,1) then local v;v,pos=f32(d,pos);p.velocity[1]=p.velocity[1]+v end;if hasBit(bits,2) then local v;v,pos=f32(d,pos);p.velocity[2]=p.velocity[2]+v end;if hasBit(bits,4) then local v;v,pos=f32(d,pos);p.velocity[3]=p.velocity[3]+v end
  elseif op==0xA0 then p.sizeTime,pos=readTime(d,pos);p.sizeTarget,pos=f32(d,pos);if p.sizeTime==0 then p.size=p.sizeTarget end
  elseif op==0xA1 then p.flags=p.flags-(hasBit(p.flags,0x400) and 0x400 or 0);p.textureOff=true
  elseif op==0xA2 then p.scaleFactor,pos=f32(d,pos);p.gravity=p.scaleFactor;p.flags=setBit(p.flags,1,p.scaleFactor~=0)
  elseif op==0xA3 then p.frictionFactor,pos=f32(d,pos);p.friction=p.frictionFactor;p.flags=setBit(p.flags,2,p.frictionFactor~=1)
  elseif op==0xA4 then local id;id,pos=u16(d,pos);p.cmdPos=pos;spawnParticle(fx,p,id,false,false,true);return
  elseif op==0xA5 then local id;id,pos=u16(d,pos);p.cmdPos=pos;spawnGenerator(fx,p,id,false);return
  elseif op==0xA6 then local base,range;base,pos=u16(d,pos);range,pos=u16(d,pos);p.repeatCount=base+math.floor(range*p.random())
  elseif op==0xA7 then
    local threshold;threshold,pos=u8(d,pos)
    -- Retail conditional kill compares the byte threshold to 100*Randf().
    -- The old VM inverted the branch, used a 0..255 random domain, and merely
    -- yielded for one frame, allowing particles that should be gone to linger.
    if threshold>=math.floor(100*p.random()) then p.alive=false;p.cmdPos=pos;return "kill" end
  elseif op==0xA8 then
    local x,y,z;x,pos=f32(d,pos);y,pos=f32(d,pos);z,pos=f32(d,pos)
    -- Retail order is amplitude - 2*amplitude*Randf for each axis.  The
    -- distribution is symmetric, but keeping the sign/order preserves the
    -- actual shared RNG sequence spatially rather than mirroring every sample.
    p.position[1]=p.position[1]+x*(1-2*p.random())
    p.position[2]=p.position[2]+y*(1-2*p.random())
    p.position[3]=p.position[3]+z*(1-2*p.random())
  elseif op==0xA9 then local a;a,pos=f32(d,pos);p.velocity=randomConeDirection(p,a)
  elseif op==0xAA then local base,range;base,pos=u16(d,pos);range,pos=u16(d,pos);local idx=base+(range>0 and math.floor(range*p.random()) or 0);p.cmdPos=pos;spawnParticle(fx,p,idx,false,true,true);return
  elseif op==0xAB then local f;f,pos=f32(d,pos);for i=1,3 do p.velocity[i]=p.velocity[i]*f end
  elseif op==0xAC then local tm,base,range;tm,pos=readTime(d,pos);base,pos=f32(d,pos);range,pos=f32(d,pos);p.sizeTime=tm;p.sizeTarget=base+range*p.random();if tm==0 then p.size=p.sizeTarget end
  elseif op==0xAD then
    -- Verified retail transition: set bit 0x80. The portable renderer uses
    -- that state to select the two-colour/intensity TEV approximation.
    p.flags=setBit(p.flags,0x80,true);p.primEnv=true
  elseif op==0xAE then
    -- AE..B1 are the source 0x20/0x40 state machine. They are not S/T mirror
    -- controls; E4/E5 own texture-coordinate flips.
    p.flags=setBit(setBit(p.flags,0x20,false),0x40,false)
  elseif op==0xAF then
    p.flags=setBit(setBit(p.flags,0x40,false),0x20,true)
  elseif op==0xB0 then
    p.flags=setBit(setBit(p.flags,0x20,false),0x40,true)
  elseif op==0xB1 then
    p.flags=setBit(setBit(p.flags,0x20,true),0x40,true)
  elseif op==0xB2 then bakeAttachment(p)
  elseif op==0xB3 then
    local a=p.alphaCompare or {mode=0x33,p1=1,p2=255,target1=1,target2=255,count=0,remaining=0}
    local _,cur1,cur2=alphaCompareCurrent(p);a.p1,a.p2=cur1,cur2
    a.count,pos=readTime(d,pos);a.mode,pos=u8(d,pos);a.target1,pos=u8(d,pos);a.target2,pos=u8(d,pos)
    if a.count==0 then a.p1,a.p2=a.target1,a.target2;a.remaining=0 else a.remaining=a.count end
    p.alphaCompare=a
  elseif op==0xB4 then p.flags=setBit(p.flags,0x200,true);p.nearest=true
  elseif op==0xB5 then p.flags=setBit(p.flags,0x200,false);p.nearest=false
  elseif op==0xB6 then
    p.headingTime,pos=readTime(d,pos);local target;target,pos=f32(d,pos);p.headingSpeed=p.headingSpeed+target
    if p.headingTime==0 then p.heading=p.headingSpeed end
  elseif op==0xB7 then
    local slot;slot,pos=u8(d,pos);local t=cameraTarget(fx,(tonumber(p.cameraSlot) or 0)+slot)
    if t then p.velocity=normalizeTo({t[1]-p.position[1],t[2]-p.position[2],t[3]-p.position[3]},vecLength(p.velocity)) end
  elseif op==0xB8 then
    local slot,force,radius;slot,pos=u8(d,pos);force,pos=f32(d,pos);radius,pos=f32(d,pos)
    local t=cameraTarget(fx,(tonumber(p.cameraSlot) or 0)+slot)
    if t and radius>=0 then
      local dx,dy,dz=t[1]-p.position[1],t[2]-p.position[2],t[3]-p.position[3];local d2=dx*dx+dy*dy+dz*dz
      if d2<=radius*radius then p.alive=false;p.cmdPos=pos;return "kill"
      elseif d2>1e-12 then local k=force/d2;p.velocity[1]=p.velocity[1]+dx*k;p.velocity[2]=p.velocity[2]+dy*k;p.velocity[3]=p.velocity[3]+dz*k end
    end
  elseif op==0xB9 then local id;id,pos=u16(d,pos);p.cmdPos=pos;spawnParticle(fx,p,id,true,false,true);return
  elseif op==0xBA or op==0xBB then
    -- BA/BB retarget colour1/color2. They do not directly randomize the current
    -- displayed colour while an interpolation is in flight.
    local prefix=op==0xBA and "prim" or "env";commitColor(p,prefix)
    local target=p[prefix.."Target"]
    for i=1,4 do local v;v,pos=s8(d,pos);target[i]=byteAdd(target[i],sourceByteRandomDelta(p,v)) end
    resetColorCountdown(p,prefix)
  elseif op==0xBC then local base,range;base,pos=u8(d,pos);range,pos=u8(d,pos);p.objRefIndex=base+(range>0 and math.floor(range*p.random()) or 0);p.textureIndex=p.objRefIndex;p.textureOff=false;p.flags=p.flags+((not hasBit(p.flags,0x400)) and 0x400 or 0)
  elseif op==0xBD then local base,range;base,pos=f32(d,pos);range,pos=f32(d,pos);p.velocity=normalizeTo(p.velocity,base+range*p.random())
  elseif op==0xBE then local x,y,z;x,pos=f32(d,pos);y,pos=f32(d,pos);z,pos=f32(d,pos);p.velocity[1]=p.velocity[1]*x;p.velocity[2]=p.velocity[2]*y;p.velocity[3]=p.velocity[3]*z
  elseif op==0xBF then
    local slot;slot,pos=u8(d,pos);slot=((tonumber(p.cameraSlot) or 0)+slot)%8
    p.cameraTrackSlot=slot;p.flags=setBit(p.flags,0x8000,true)
    local old=math.floor(p.flags/0x1000)%8;p.flags=p.flags-old*0x1000+slot*0x1000
  elseif op>=0xC0 and op<=0xCF then
    commitColor(p,"prim");p.primTime,pos=readTime(d,pos);p.primTarget=copyColor(p.prim);local m=op-0xC0
    for i=1,4 do if hasBit(m,2^(i-1)) then p.primTarget[i],pos=u8(d,pos) end end;resetColorCountdown(p,"prim")
  elseif op>=0xD0 and op<=0xDF then
    commitColor(p,"env");p.envTime,pos=readTime(d,pos);p.envTarget=copyColor(p.env);local m=op-0xD0
    for i=1,4 do if hasBit(m,2^(i-1)) then p.envTarget[i],pos=u8(d,pos) end end;resetColorCountdown(p,"env")
  elseif op==0xE0 then
    -- E0 uses one random magnitude per channel and applies that SAME signed
    -- delta to both colour targets.
    commitColor(p,"prim");commitColor(p,"env")
    for i=1,4 do
      local v;v,pos=s8(d,pos);local delta=sourceByteRandomDelta(p,v)
      p.primTarget[i]=byteAdd(p.primTarget[i],delta);p.envTarget[i]=byteAdd(p.envTarget[i],delta)
    end
    resetColorCountdown(p,"prim");resetColorCountdown(p,"env")
  elseif op==0xE1 then p.callbackId,pos=u8(d,pos)
  elseif op==0xE2 then p.flags=setBit(p.flags,0x8,true);p.flag8=true
  elseif op==0xE3 then p.pad0B,pos=u8(d,pos)
  elseif op==0xE4 then
    local mode;mode,pos=u8(d,pos);mode=mode%4
    if mode==0 then p.flipS=false elseif mode==1 then p.flipS=true elseif mode==2 then p.flipS=not p.flipS else p.flipS=p.random()>=.5 end
    p.flags=setBit(p.flags,0x40000,p.flipS)
  elseif op==0xE5 then
    local mode;mode,pos=u8(d,pos);mode=mode%4
    if mode==0 then p.flipT=false elseif mode==1 then p.flipT=true elseif mode==2 then p.flipT=not p.flipT else p.flipT=p.random()>=.5 end
    p.flags=setBit(p.flags,0x80000,p.flipT)
  elseif op==0xE6 then p.flags=setBit(p.flags,0x200000,true);p.dirVec=true
  elseif op==0xE7 then p.flags=setBit(p.flags,0x200000,false);p.dirVec=false
  elseif op==0xE8 then
    local trail;trail,pos=f32(d,pos)
    -- Retail E8 controls HSD_Particle::trail. It does not multiply the whole
    -- billboard's opacity; only the previous endpoint of the velocity trail
    -- uses this scalar during drawing.
    if trail<0 then p.flags=setBit(p.flags,0x100000,false);p.trail=false
    else p.flags=setBit(p.flags,0x100000,true);p.trail=true;p.trailAlpha=trail end
  elseif op==0xE9 then
    local mask,count;mask,pos=u8(d,pos);count,pos=u8(d,pos)
    commitColor(p,"prim");commitColor(p,"env")
    local function quantized()
      local r=p.random();if count==0 then return r end
      return math.floor((count+1)*r)/count
    end
    -- RGB share one quantized random factor. Alpha intentionally consumes a
    -- second sample in retail. Bits 0x10/0x20 select primary/environment target.
    local rgbFactor=quantized()
    for i=1,3 do if hasBit(mask,2^(i-1)) then
      local v;v,pos=s8(d,pos);local delta=sourceByteRandomDelta(p,v,rgbFactor)
      if hasBit(mask,0x10) then p.primTarget[i]=byteAdd(p.primTarget[i],delta) end
      if hasBit(mask,0x20) then p.envTarget[i]=byteAdd(p.envTarget[i],delta) end
    end end
    if hasBit(mask,8) then
      local v;v,pos=s8(d,pos);local delta=sourceByteRandomDelta(p,v,quantized())
      if hasBit(mask,0x10) then p.primTarget[4]=byteAdd(p.primTarget[4],delta) end
      if hasBit(mask,0x20) then p.envTarget[4]=byteAdd(p.envTarget[4],delta) end
    end
    resetColorCountdown(p,"prim");resetColorCountdown(p,"env");p.randomColorCount=count
  elseif op==0xEA or op==0xEB then
    local tm,flags;tm,pos=readTime(d,pos);flags,pos=u8(d,pos);local rgb,alpha;if hasBit(flags,1) then rgb,pos=u8(d,pos) end;if hasBit(flags,8) then alpha,pos=u8(d,pos) end
    p.channelSize=p.channelSize or {};p.channelSize[op==0xEA and "x" or "y"]={time=tm,flags=flags,rgb=rgb,alpha=alpha}
  elseif op==0xEC then local idx,v;idx,pos=u8(d,pos);v,pos=f32(d,pos);p.custom=p.custom or {};p.custom[idx]=v
  elseif op==0xED then
    local base,range,count;base,pos=f32(d,pos);range,pos=f32(d,pos);count,pos=u8(d,pos)
    local r=p.random();if count~=0 then r=math.floor((count+1)*r)/count end
    local delta=base+range*r;p.headingSpeed=p.headingSpeed+delta;p.heading=p.heading+delta;p.headingRandomCount=count
  elseif op==0xEF then local id,flags;id,pos=u16(d,pos);flags,pos=u8(d,pos);p.cmdPos=pos;spawnGenerator(fx,p,id,false,flags);p.spawnFlags=flags;return
  elseif op==0xF0 then local idx,flags;idx,pos=u16(d,pos);flags,pos=u8(d,pos);p.cmdPos=pos;spawnGenerator(fx,p,idx,true,flags);p.spawnFlags=flags;return
  elseif op==0xF1 then local idx;idx,pos=u16(d,pos);p.cmdPos=pos;spawnParticle(fx,p,idx,false,true,true);return
  elseif op==0xF2 then local idx;idx,pos=u16(d,pos);p.cmdPos=pos;spawnParticle(fx,p,idx,true,true,true);return
  elseif op==0xF3 then
    local reverse;reverse,pos=u8(d,pos)
    p.headingSpeed,pos=f32(d,pos);p.headingAccel,pos=f32(d,pos);p.headingTime,pos=readTime(d,pos)
    if p.headingTime~=0 then
      if reverse==0 then p.headingSpeed=p.headingSpeed+p.headingAccel*.5
      else p.headingSpeed=-p.headingSpeed-p.headingAccel*.5 end
    else p.headingSpeed=0;p.headingAccel=0 end
  elseif op==0xF4 then
    local vals={};for i=1,4 do vals[i],pos=f32(d,pos) end;p.generatorDirection=vals
    if p.generator then
      local base=generatorBasisVelocity(p.generator.gen)
      base={base[1]+vals[2],base[2]+vals[3],base[3]+vals[4]}
      p.velocity=randomConeDirection(p,vals[1],base)
    end
  elseif op==0xF5 then
    p.generatorTrack2000=true
    if p.generator then p.generator.runtimeAngleFlags=setBit(p.generator.runtimeAngleFlags or 0,0x2000,true) end
  elseif op==0xF6 then
    p.generatorTrack1000=true
    if p.generator then p.generator.runtimeAngleFlags=setBit(p.generator.runtimeAngleFlags or 0,0x1000,true) end
  elseif op==0xF7 then p.noZComp=true
  elseif op==0xFA then p.loopCount,pos=u8(d,pos);p.loopPos=pos
  elseif op==0xFB then p.loopCount=(p.loopCount or 0)-1;if p.loopCount>0 then pos=p.loopPos or pos end
  elseif op==0xFC then p.savedPC=pos
  elseif op==0xFD then pos=p.savedPC or pos
  else addFault(fx,"opcode",string.format("0x%02X",op));p.alive=false
  end
  p.cmdPos=math.min(pos,#d+1)
end

local function executeParticle(p,fx)
  local d=p.data;local guard=0
  while p.alive and p.cmdPos<=#d and guard<MAX_COMMANDS_PER_FRAME do
    guard=guard+1;local op;op,p.cmdPos=u8(d,p.cmdPos)
    if op<0x80 then
      local delay=op%32;if hasBit(op,0x20) then local x;x,p.cmdPos=u8(d,p.cmdPos);delay=delay*256+x end
      if hasBit(op,0x40) then p.objRefIndex,p.cmdPos=u8(d,p.cmdPos);p.textureIndex=p.objRefIndex;p.textureOff=false end
      if delay>0 then p.wait=delay;return end
    elseif op==0xFE or op==0xFF then p.repeatCount=1;return
    else local r=executeComplex(p,fx,op);if r=="yield" then return end end
  end
  if guard>=MAX_COMMANDS_PER_FRAME then addFault(fx,"command-guard",p.scriptId);p.alive=false end
end

local function advanceLerp(p)
  local time=tonumber(p.sizeTime) or 0
  if time<=0 then return end
  p.size=p.size+((tonumber(p.sizeTarget) or p.size)-p.size)/time
  p.sizeTime=time-1
  if p.sizeTime<=0 then p.size=tonumber(p.sizeTarget) or p.size;p.sizeTime=0 end
end

stepParticle=function(p,fx)
  if not p.alive then return end;p.frame=p.frame+1
  -- Retail decrements an existing alpha-compare interpolation before running
  -- this frame's bytecode. A B3 encountered below therefore starts at its full
  -- authored duration and is first advanced on the following source frame.
  local ac=p.alphaCompare
  if ac and (tonumber(ac.count) or 0)>0 then
    ac.remaining=math.max(0,(tonumber(ac.remaining) or 0)-1)
    if ac.remaining==0 then ac.p1,ac.p2=ac.target1,ac.target2;ac.count=0 end
  end
  -- Retail advances existing colour ramps before interpreting this frame's
  -- bytecode. A newly-created CF/DF/BA/BB/E0/E9 ramp therefore remains at its
  -- exact start colour until the following source frame.
  advanceColor(p,"prim");advanceColor(p,"env")
  -- A0/AC target the source PSParticle::lerpValue (the physical quad scale in
  -- the particle renderer). Retail advances an existing lerp before bytecode,
  -- so a command authored this frame does not visibly move until the next one.
  advanceLerp(p)
  -- Heading timers are likewise advanced before this frame's bytecode. B6/F3
  -- encountered below establish state for the next source frame.
  advanceHeading(p)
  if p.wait>0 then p.wait=p.wait-1 end;if p.wait==0 then executeParticle(p,fx) end;if not p.alive then return end
  -- The retail interpreter decrements lifetime before physics. FE/FF and B8's
  -- in-radius termination therefore do not receive one spurious final motion
  -- step after the source object is already dead.
  p.repeatCount=(p.repeatCount or 1)-1
  if p.repeatCount<=0 then p.alive=false;return end
  -- GX particle physics is opt-in: an unused zero friction field is NOT a
  -- request to erase velocity. A2/A3 above update the same low flag bits.
  if hasBit(p.flags,1) then p.velocity[2]=p.velocity[2]-(p.scaleFactor or 0) end
  if hasBit(p.flags,2) then for i=1,3 do p.velocity[i]=p.velocity[i]*(p.frictionFactor or 1) end end
  for i=1,3 do p.position[i]=p.position[i]+p.velocity[i] end
  if p.cameraTrackSlot~=nil then fx.cameraSlots[p.cameraTrackSlot]={p.position[1],p.position[2],p.position[3]} end
  p.rotation=p.heading
end

local function stepGenerator(g,fx)
  if not g.alive then return end;g.age=g.age+1
  -- A finite generator stops emitting at its own authored lifetime; its
  -- particles (and late children) retain their own lifetimes after that.
  if not g.emissionStopped and g.maxLife<=0 and fx.frame>fx.sourceEndFrame then
    g.emissionStopped=true;g.rate=0;g.accumulator=0
  end
  if not g.emissionStopped then
    local rate=g.rate or 0
    if rate<0 then g.accumulator=g.accumulator-rate else g.accumulator=g.accumulator+rate*g.random() end
    g.angleBatch=nil
    local source=g.gen or {};local mode=(tonumber(source.angleFlags) or 0)%16
    local angle=tonumber(source.angle) or tonumber(source.params and source.params[7]) or 0
    local count=math.floor(g.accumulator)
    if angle<0 and count>0 and (mode==0 or mode==3 or mode==4 or mode==6 or mode==7) then
      local lo=tonumber(source.shapeX) or tonumber(source.params and source.params[10]) or 0
      local hi=tonumber(source.shapeY) or tonumber(source.params and source.params[11]) or 0
      if lo==0 and hi==0 then lo,hi=0,math.pi*2 end
      local step=(hi-lo)/count
      g.angleBatch={current=lo+step*g.random(),step=step}
    end
    local emitted=0
    while g.accumulator>=1 and emitted<MAX_EMIT_PER_FRAME and #fx.particles<MAX_TOTAL_PARTICLES do
      emitGeneratorParticle(fx,g);g.accumulator=g.accumulator-1;emitted=emitted+1
    end
    if g.maxLife>0 then
      g.maxLife=g.maxLife-1
      if g.maxLife<=0 then g.emissionStopped=true;g.rate=0;g.accumulator=0 end
    end
  end
  if g.emissionStopped and g.childCount<=0 then g.alive=false end
end

local function safeFrame(v) v=tonumber(v);if not v or v<0 or v>7200 then return 0 end;return math.floor(v+.5) end
function M.start(spec,opts)
  opts=type(opts)=="table" and opts or {};local role=tostring(opts.role or "attack")
  local random=type(opts.random)=="function" and opts.random or (opts.randomSeed~=nil and rng(opts.randomSeed) or sharedRandom)
  local fx={spec=spec,role=role,age=0,frame=0,accumulator=0,particles={},generators={},emitters={},templates={},templateById={},joints=opts.joints or {},cameraSlots={},spawnSerial=0,done=false,opcodeFaults={},random=random}
  local entry=type(opts.entry)=="table" and opts.entry or nil;local root=selectRoot(spec,entry,role)
  for i,g in ipairs(type(spec)=="table" and (spec.generatorPrograms or {}) or {}) do
    if executable(g,role,entry) then local t={gen=g,index=i,data=hexToBytes(g.commandHex or ""),autoRoot=(g==root)};fx.templates[#fx.templates+1]=t;fx.templateById[templateKey(g.bank,g.scriptId~=nil and g.scriptId or g.bankIndex)]=t end
  end
  if root then
    local t=fx.templateById[templateKey(root.bank,root.scriptId~=nil and root.scriptId or root.bankIndex)]
    local start=(entry and opts.sequenceStartHandled) and 0 or safeFrame(root.sequence and root.sequence.start);fx.rootStartFrame=start
    if start<=0 then newGenerator(fx,t,{0,0,0},nil) else fx.pendingRoot=t end
  end
  local duration=tonumber(opts.sourceDurationFrames)
  if not duration or duration<=0 then
    duration=0;for _,g in ipairs(type(spec)=="table" and (spec.generatorPrograms or {}) or {}) do if phaseRole(g.phase)==role then duration=math.max(duration,tonumber(g.maxLife) or 0) end end
    if duration<=0 then duration=math.ceil((tonumber(spec and spec.duration) or 2)*60) end
  end
  fx.sourceEndFrame=math.max(1,math.min(MAX_EFFECT_SECONDS*60,duration))
  fx.hardEndFrame=MAX_EFFECT_SECONDS*60
  return fx
end
function M.update(fx,dt)
  if type(fx)~="table" or fx.done then return false end;local step=math.max(0,tonumber(dt) or 0);fx.age=fx.age+step;fx.accumulator=fx.accumulator+step;local steps=0
  while fx.accumulator+1e-10>=FRAME_DT and steps<MAX_STEPS_PER_UPDATE do
    fx.accumulator=fx.accumulator-FRAME_DT;steps=steps+1;fx.frame=fx.frame+1
    if fx.pendingRoot and fx.frame>=fx.rootStartFrame then newGenerator(fx,fx.pendingRoot,{0,0,0},nil);fx.pendingRoot=nil end
    for _,g in ipairs(fx.generators) do stepGenerator(g,fx) end
    for i=#fx.particles,1,-1 do
      local p=fx.particles[i];stepParticle(p,fx)
      if not p.alive then
        if p.cameraTrackSlot~=nil then fx.cameraSlots[p.cameraTrackSlot]=nil end
        if p.generator then p.generator.childCount=math.max(0,(p.generator.childCount or 1)-1) end
        table.remove(fx.particles,i)
      end
    end
    for i=#fx.generators,1,-1 do if not fx.generators[i].alive then table.remove(fx.generators,i) end end;fx.emitters=fx.generators
  end
  if #fx.generators==0 and #fx.particles==0 and not fx.pendingRoot and fx.frame>0 then
    fx.done=true;fx.finishReason="source-objects-drained"
  elseif fx.frame>=fx.hardEndFrame then
    fx.done=true;fx.finishReason="particle-watchdog";fx.truncated=true
    addFault(fx,"particle-watchdog",fx.frame)
  end
  return not fx.done
end
function M.visibleParticles(fx) return type(fx)=="table" and fx.particles or {} end
function M.status(fx) if type(fx)~="table" then return nil end;return {role=fx.role,age=fx.age,frame=fx.frame,templates=#fx.templates,generators=#fx.generators,emitters=#fx.generators,particles=#fx.particles,done=fx.done,finishReason=fx.finishReason,truncated=fx.truncated==true,sourceEndFrame=fx.sourceEndFrame,hardEndFrame=fx.hardEndFrame,opcodeFaults=fx.opcodeFaults} end
M._test={hexToBytes=hexToBytes,selectRoot=selectRoot,lookupScriptId=lookupScriptId,alphaCompareCurrent=alphaCompareCurrent,
  rng=rng,resetSharedRandom=resetSharedRandom,generatorDirectionTransform=generatorDirectionTransform,
  randomConeDirection=randomConeDirection,bakeAttachment=bakeAttachment,cameraTarget=cameraTarget}
return M
