local V=...
local M={}

-- Shared trainer animation binding. Native track caches stream adjacent source
-- frames (positions and normals) through seven shader attributes. Older caches
-- retain the sparse-pose fallback. Unsupported attribute binding uses that
-- fallback for both the visible body and hand anchors.

-- Dense source layout. Trainer cache formatVersion 27 carries the exact HSD
-- COLOR0A0 channel beside XYZ/UV/normal before the authored pose positions.
-- GC6E01 Nascour uses that channel for six translucent body/glow groups; the
-- old 44-float cache discarded it and therefore could not reproduce source
-- vertex alpha. Trainers without COLOR0A0 receive an identity white color.
M.DENSE_STRIDE=48
M.DENSE_FORMAT={
  {"VertexPosition","float",3},
  {"VertexTexCoord","float",2},
  {"SourceColor","float",4},
  {"VertexNormal","float",3},
  {"BreathPosition","float",3},
  {"LookPosition","float",3},
  {"Gesture1Position","float",3},
  {"Gesture2Position","float",3},
  {"Gesture3Position","float",3},
  {"Gesture4Position","float",3},
  {"Gesture5Position","float",3},
  {"Reaction1Position","float",3},
  {"Reaction2Position","float",3},
  {"Reaction3Position","float",3},
  {"Reaction4Position","float",3},
  {"Reaction5Position","float",3},
}

-- Compact layout used only by the CPU fallback path below.
M.COMPACT_STRIDE=24
M.COMPACT_FORMAT={
  {"VertexPosition","float",3},
  {"VertexTexCoord","float",2},
  {"SourceColor","float",4},
  {"VertexNormal","float",3},
  {"BreathPosition","float",3},
  {"LookPosition","float",3},
  {"ActionAPosition","float",3},
  {"ActionBPosition","float",3},
}

M.POSE_OFFSET={
  breath=13,look=16,
  gesture1=19,gesture2=22,gesture3=25,gesture4=28,gesture5=31,
  reaction1=34,reaction2=37,reaction3=40,reaction4=43,reaction5=46,
}
M.ACTION_KEYS={
  "gesture1","gesture2","gesture3","gesture4","gesture5",
  "reaction1","reaction2","reaction3","reaction4","reaction5",
}
-- Dense attribute name backing each source-pose weight.
M.ATTRIBUTE={
  gesture1="Gesture1Position",gesture2="Gesture2Position",gesture3="Gesture3Position",
  gesture4="Gesture4Position",gesture5="Gesture5Position",
  reaction1="Reaction1Position",reaction2="Reaction2Position",reaction3="Reaction3Position",
  reaction4="Reaction4Position",reaction5="Reaction5Position",
}

-- Seven-attribute vertex program. This is the previously Windows-only shader,
-- which is now the shader for every platform. Its blend math is unchanged:
-- the two active poses are combined by relative weight, then mixed against the
-- bind pose by their total, and idle breath/look remain a secondary layer that
-- fades out while an authored action owns the body.
M.VERTEX=[[
uniform mat4 vp; uniform mat4 model;
uniform float breathMix; uniform float lookMix;
uniform float actionAMix; uniform float actionBMix; uniform float sourcePoseGain;
uniform float nativeTrackMix; uniform float nativeTrackEnabled;
attribute vec3 VertexNormal;
attribute vec4 SourceColor;
attribute vec3 BreathPosition;
attribute vec3 LookPosition;
attribute vec3 ActionAPosition;
attribute vec3 ActionBPosition;
varying vec3 worldPos; varying vec3 worldNormal;
varying vec4 sourceColor;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  vec3 base=vertex_position.xyz;
  float a=max(actionAMix,0.0)*sourcePoseGain;
  float b=max(actionBMix,0.0)*sourcePoseGain;
  float sum=a+b;
  float action=clamp(sum,0.0,1.0);
  vec3 p=base;
  if (sum>0.0001) {
    vec3 target=(ActionAPosition*a+ActionBPosition*b)/sum;
    p=mix(base,target,action);
  }
  float secondary=1.0-action;
  p+=(BreathPosition-base)*breathMix*secondary*(1.0-nativeTrackEnabled);
  p+=(LookPosition-base)*lookMix*secondary*(1.0-nativeTrackEnabled);
  vec4 world=model*vec4(p,1.0); worldPos=world.xyz;
  sourceColor=SourceColor;
  vec3 n=mix(VertexNormal,mix(BreathPosition,LookPosition,nativeTrackMix),nativeTrackEnabled*action);
  worldNormal=normalize((model*vec4(normalize(n),0.0)).xyz);
  return vp*world;
}]]

function M.densePose(row,key)
  local i=M.POSE_OFFSET[key] or 1
  return tonumber(row and row[i]) or tonumber(row and row[1]) or 0,
         tonumber(row and row[i+1]) or tonumber(row and row[2]) or 0,
         tonumber(row and row[i+2]) or tonumber(row and row[3]) or 0
end

function M.staticCompactVertex(x,y,z,u,v,nx,ny,nz)
  nx,ny,nz=nx or 0,ny or 1,nz or 0
  return {x,y,z,u,v,1,1,1,1,nx,ny,nz,x,y,z,x,y,z,x,y,z,x,y,z}
end

function M.staticDenseVertex(x,y,z,u,v,nx,ny,nz)
  nx,ny,nz=nx or 0,ny or 1,nz or 0
  local row={x,y,z,u,v,1,1,1,1,nx,ny,nz}
  for _=1,12 do row[#row+1]=x;row[#row+1]=y;row[#row+1]=z end
  return row
end

function M.compactVertex(row,keyA,keyB)
  local bx,by,bz=M.densePose(row,nil)
  local brx,bry,brz=M.densePose(row,"breath")
  local lx,ly,lz=M.densePose(row,"look")
  local ax,ay,az=M.densePose(row,keyA)
  local bx2,by2,bz2=M.densePose(row,keyB)
  return {bx,by,bz,tonumber(row[4]) or 0,tonumber(row[5]) or 0,
    tonumber(row[6]) or 1,tonumber(row[7]) or 1,tonumber(row[8]) or 1,tonumber(row[9]) or 1,
    tonumber(row[10]) or 0,tonumber(row[11]) or 1,tonumber(row[12]) or 0,
    brx,bry,brz,lx,ly,lz,ax,ay,az,bx2,by2,bz2}
end

-- The two heaviest source-pose weights, highest first. Identical selection to
-- the previous windowsActionPair.
function M.actionPair(motion)
  motion=motion or {}
  local keyA,keyB,wA,wB=nil,nil,0,0
  for _,key in ipairs(M.ACTION_KEYS) do
    local w=math.max(0,tonumber(motion[key]) or 0)
    if w>wA then keyB,wB=keyA,wA;keyA,wA=key,w
    elseif w>wB then keyB,wB=key,w end
  end
  return keyA,wA,keyB,wB
end

-- ---------------------------------------------------------------------------
-- Binding strategy
--
-- Preferred: rebind the dense mesh's own pose attributes into the two shader
-- slots with Mesh:attachAttribute. No extra buffers, no uploads, no cache
-- change -- and the pair only changes about four times across a ~1.5s clip.
--
-- LOVE moved attachAttribute's argument order between 11.2 and 11.3, and some
-- forks omit it entirely, so the exact call is probed once at runtime and the
-- CPU rewrite below is kept as a fallback.
-- ---------------------------------------------------------------------------
local attachStyle=nil   -- "step4" | "name3" | false
local probed=false

local function probeAttach()
  if probed then return attachStyle end
  probed=true;attachStyle=false
  if not (love and love.graphics and type(love.graphics.newMesh)=="function") then return attachStyle end
  local ok,m=pcall(love.graphics.newMesh,M.DENSE_FORMAT,3,"triangles","static")
  if not ok or not m or type(m.attachAttribute)~="function" then return attachStyle end
  -- 11.3+: (name, mesh, step, attachname)
  if pcall(m.attachAttribute,m,"ActionAPosition",m,"pervertex","Gesture1Position") then attachStyle="step4"
  -- 11.2: (name, mesh, attachname)
  elseif pcall(m.attachAttribute,m,"ActionAPosition",m,"Gesture1Position") then attachStyle="name3" end
  pcall(function() if m.release then m:release() end end)
  return attachStyle
end

-- "attached" keeps the dense mesh and rebinds; "dynamic" rewrites compact
-- vertex rows on the CPU when the active pair changes.
function M.mode()
  return probeAttach() and "attached" or "dynamic"
end
function M.attachStyle() return probeAttach() end
function M.dense() return M.mode()=="attached" end

local function attachOne(mesh,sourceAttr,slot)
  if attachStyle=="step4" then
    return pcall(mesh.attachAttribute,mesh,slot,mesh,"pervertex",sourceAttr)
  end
  return pcall(mesh.attachAttribute,mesh,slot,mesh,sourceAttr)
end

M.rebinds=0
M.rewrites=0

-- HSD schedules opaque geometry before its translucent material pass. Keep
-- the original group order for native-track indices and build a separate,
-- stable render list once when the model loads. Drawing an early XLU group
-- before the body lets later opaque triangles erase the visible overlay.
function M.materialOrder(groups)
  local order={}
  for pass=1,2 do
    for _,g in ipairs(groups or {}) do
      if (g.xlu and 2 or 1)==pass then order[#order+1]=g end
    end
  end
  return order
end

function M.textureWrap(spec,group,id)
  local s,t=spec.wrapS,spec.wrapT
  -- Pre-sweep caches omitted TOBJ wraps. GC6E01 boss999_a1's three 16x8
  -- unlit glow overlays are the only repeating trainer textures in the ten
  -- shipped source actors. Match that exact material, never all of Nascour.
  if s==nil and t==nil and id=="nascour" and spec.w==16 and spec.h==8
      and tonumber(group and group.renderFlags)==0x60006013 then s,t=1,1 end
  local function wrap(v)
    if tonumber(v)==1 then return "repeat" end
    if tonumber(v)==2 then return "mirroredrepeat" end
    return "clamp"
  end
  return wrap(s),wrap(t)
end

-- Pixel-engine state as emitted by retail HSD_MObjSetup/fn_801B29E4. Trainer
-- caches preserve an HSD_PEDesc when the source material supplies one; absent a
-- PEDesc, SysDolphin derives the same defaults from RENDER_XLU / NO_ZUPDATE /
-- ZMODE_ALWAYS. Keep this pure so both player and enemy runtimes use identical
-- depth/alpha/blend decisions.
local GX_COMPARE={
  [0]="never",[1]="less",[2]="equal",[3]="lequal",
  [4]="greater",[5]="notequal",[6]="gequal",[7]="always",
}
local function flag(v,bit) return math.floor((tonumber(v) or 0)/bit)%2==1 end
-- GC6E01 hsd_mobj.c MakeTExp: MAT0 aliases MAT; ALPHA_COMPAT
-- inherits the resolved diffuse selector. VTX-only excludes the material
-- multiplier, while BOTH retains it. Resolve at draw time so old v27 caches
-- and animated material samples use the same selectors without a cache rebuild.
function M.materialChannels(group,animated)
  group=group or {}
  local flags=tonumber(group.renderFlags)
  local diffuseMode=flags and flags%4 or (group.useVertexColor and 3 or 1)
  if diffuseMode==0 then diffuseMode=1 end
  local alphaMode=flags and math.floor(flags/0x2000)%4 or (group.useVertexAlpha and 3 or 1)
  if alphaMode==0 then alphaMode=diffuseMode end
  local d=animated and animated.diffuse or group.diffuse or {1,1,1}
  local alpha=tonumber(animated and animated.alpha) or tonumber(group.alpha) or 1
  return {
    color={diffuseMode==2 and 1 or (d[1] or 1),
      diffuseMode==2 and 1 or (d[2] or 1),
      diffuseMode==2 and 1 or (d[3] or 1),alphaMode==2 and 1 or alpha},
    vertexColor=diffuseMode>=2 and 1 or 0,
    vertexAlpha=alphaMode>=2 and 1 or 0,
  }
end

function M.materialState(group,animated)
  group=group or {}
  local p=type(group.pe)=="table" and group.pe or nil
  local state={exact=true}
  if p then
    local f=tonumber(p.flags) or 0
    state.depthCompare=flag(f,0x10) and (GX_COMPARE[tonumber(p.zComp) or 3] or "lequal") or "always"
    state.depthWrite=flag(f,0x20)
    state.alphaComp0=tonumber(p.alphaComp0) or 7;state.alphaRef0=tonumber(animated and animated.ref0) or tonumber(p.ref0) or 0
    state.alphaOp=tonumber(p.alphaOp) or 0
    state.alphaComp1=tonumber(p.alphaComp1) or 7;state.alphaRef1=tonumber(animated and animated.ref1) or tonumber(p.ref1) or 0
    state.blendType=tonumber(p.type) or 0;state.srcFactor=tonumber(p.srcFactor) or 4;state.dstFactor=tonumber(p.dstFactor) or 5
  else
    local f=tonumber(group.renderFlags) or 0
    state.depthCompare=flag(f,0x08000000) and "always" or "lequal"
    state.depthWrite=not flag(f,0x20000000)
    if flag(f,0x40000000) and not flag(f,0x20000000) then
      state.alphaComp0=4;state.alphaRef0=0;state.alphaOp=0;state.alphaComp1=4;state.alphaRef1=0
    else
      state.alphaComp0=7;state.alphaRef0=0;state.alphaOp=0;state.alphaComp1=7;state.alphaRef1=0
    end
    state.blendType=flag(f,0x40000000) and 1 or 0;state.srcFactor=4;state.dstFactor=5
  end
  if state.blendType==0 then state.blendMode="replace"
  elseif state.blendType==1 and state.srcFactor==4 and state.dstFactor==5 then state.blendMode="alpha"
  else state.blendMode="alpha";state.exact=false end
  return state
end

function M.applyMaterialState(group,animated)
  local s=M.materialState(group,animated)
  if love and love.graphics then
    if love.graphics.setDepthMode then pcall(love.graphics.setDepthMode,s.depthCompare,s.depthWrite) end
    if love.graphics.setBlendMode then
      local ok=pcall(love.graphics.setBlendMode,s.blendMode,"alphamultiply")
      if not ok then pcall(love.graphics.setBlendMode,s.blendMode) end
    end
  end
  return s
end

-- Point the two shader slots at the currently active source poses. Call once
-- per frame before drawing a trainer's groups; it is a no-op unless the active
-- pair actually changed.
-- Source-track playback is separate from the legacy sparse-pose fallback.
local TRACK_FORMAT={{"NativePosition","float",3},{"NativeNormal","float",3}}
local function nativeRole(kind)
  if not kind then return "idle" end
  if kind=="brace" or kind=="concern" or kind=="frustration" or kind=="defeat" then return "reaction" end
  return "gesture"
end
-- GC6E01 People actors run their HSD animation and TexAnim banks at
-- GSmodelSetAnimRate(..., 0.5f) / GSmodelSetTexAnimRate(..., 0.5f). The
-- native-v1 extractor originally mislabeled that source clock as 60 fps, which
-- made exact trainer tracks play at double retail speed. Treat only that known
-- legacy v1 value as the old metadata bug; arbitrary/synthetic track clocks are
-- left untouched. This is runtime-only compatibility, so no cache rewrite or
-- revision bump is required for existing users.
function M.sourceFps(track)
  local fps=tonumber(track and track.fps) or 30
  if track and tonumber(track.version)==1 and fps==60 then return 30 end
  return fps>0 and fps or 30
end
function M.sourceDuration(track,kind)
  local role=(kind and track and track.roles and track.roles[kind]) and kind or nativeRole(kind)
  local clip=track and track.roles and track.roles[role]
  local finish=clip and tonumber(clip.endFrame)
  if not finish or finish<=0 then return nil end
  return finish/M.sourceFps(track),clip,role
end
function M.loadTracks(id,groups)
  if not probeAttach() then return nil end
  local runtime=V.RuntimeMeshCache
  if not (runtime and runtime.readLua and V.GeneratedAssets) then return nil end
  local track=runtime.readLua(("cache/trainers/%s/native_v1/index.lua"):format(id))
  if type(track)~="table" or track.version~=1 or not track.roles then return nil end
  local loaded={}
  for role,clip in pairs(track.roles) do
    if not (clip.count and clip.count>=2 and clip.endFrame and clip.endFrame>0 and type(clip.groups)=="table" and #clip.groups==#groups) then return nil end
    local bytes={}
    for gi,g in ipairs(clip.groups) do
      if not groups[gi].mesh then return nil end
      local data=loaded[g.path] or (clip.bytes and clip.bytes[gi]) or V.GeneratedAssets.read(g.path)
      if type(data)~="string" or #data~=g.vertices*24*clip.count then return nil end
      loaded[g.path]=data;bytes[gi]=data
    end
    clip.bytes=bytes
  end
  for gi,g in ipairs(groups) do g.nativeTrack=track;g.nativeGroupIndex=gi end
  return track
end
function M.trackSample(track,kind,age,actionAge,duration)
  local role=(kind and track and track.roles[kind]) and kind or nativeRole(kind);local clip=track and track.roles[role]
  if not clip then return nil end
  local fps=M.sourceFps(track)
  local frame
  if not kind then frame=(math.max(0,age or 0)*fps)%clip.endFrame
  else
    -- A native clip owns its own duration. `duration` is the semantic fallback
    -- choreography duration and must never time-stretch an authored GC6E01 HSD
    -- bank. Retain the argument for API compatibility with older callers.
    local sourceDuration=clip.endFrame/fps
    frame=math.min(1,math.max(0,(actionAge or 0)/math.max(.001,sourceDuration)))*clip.endFrame
  end
  local a=math.min(math.floor(frame),clip.count-2)
  local b=a+1;local span=math.min(b,clip.endFrame)-a
  return clip,a+1,b+1,span>0 and (frame-a)/span or 0,role
end
-- Material/"texAnim" playback shares the exact native clip/frame clock in
-- retail People models. TrainerExtractor stores only source-proven diffuse,
-- alpha and PE-ref samples; unsupported material animation is omitted entirely.
function M.materialSample(group,motion)
  if type(group)~="table" or type(motion)~="table" then return nil end
  local track=group.nativeTrack;local gi=tonumber(group.nativeGroupIndex)
  if not track or not gi then return nil end
  local clip,a,b,u=M.trackSample(track,motion.nativeKind,motion.nativeAge,
    motion.nativeActionAge,motion.nativeDuration)
  local frames=clip and clip.materials and clip.materials[gi]
  local p=frames and frames[a];local q=frames and frames[b]
  if type(p)~="table" or type(q)~="table" then return nil end
  local function mix(i,default)
    local x=tonumber(p[i]);local y=tonumber(q[i])
    if x==nil then x=default end;if y==nil then y=x end
    return x+(y-x)*(tonumber(u) or 0)
  end
  return {diffuse={mix(1,1),mix(2,1),mix(3,1)},alpha=mix(4,1),ref0=mix(5,0),ref1=mix(6,0)}
end
-- A dense native track already contains the trainer's authored root translation,
-- weight shift and body lean for this frame.  The renderer must not layer CBE's
-- semantic whole-body motion on top of it or the source clip gets translated /
-- tilted twice.  Keep this query here so both player and enemy trainers make the
-- same source-ownership decision without duplicating role fallback rules.
function M.nativeTrackOwnsRoot(track,motion)
  if not (track and type(motion)=="table") then return false end
  local clip=M.trackSample(track,motion.nativeKind,motion.nativeAge,
    motion.nativeActionAge,motion.nativeDuration)
  return clip~=nil
end
local function smoothUnit(x)
  x=math.max(0,math.min(1,x));return x*x*(3-2*x)
end
function M.actionWeight(motion,track)
  local kind=motion.nativeKind
  if not kind then return 1 end
  local age=math.max(0,motion.nativeActionAge or 0)
  local duration=math.max(.001,M.sourceDuration(track,kind) or motion.nativeDuration or 1)
  local weight=smoothUnit(age/math.min(.12,duration*.2))
  if kind~="victory" and kind~="defeat" and kind~="throw" and kind~="sendout" and kind~="recall" then
    weight=weight*smoothUnit((duration-age)/math.min(.20,duration*.2))
  end
  if kind=="brace" or kind=="concern" then weight=weight*math.max(0,math.min(1,motion.nativeStrength or 1)) end
  return weight
end
local function idleReference(track,motion)
  local clip,a,b,u=M.trackSample(track,nil,motion.nativeAge)
  return clip,u and u>=.5 and b or a
end
function M.trackJoint(track,index,motion)
  local c,a,b,u=M.trackSample(track,motion.nativeKind,motion.nativeAge,motion.nativeActionAge,motion.nativeDuration)
  local p=c and c.joints and c.joints[a] and c.joints[a][index]
  local q=c and c.joints and c.joints[b] and c.joints[b][index]
  if not p or not q then return nil end
  local point={p[1]+(q[1]-p[1])*u,p[2]+(q[2]-p[2])*u,p[3]+(q[3]-p[3])*u}
  if motion.nativeKind then
    local idle,frame=idleReference(track,motion)
    local base=idle and idle.joints and idle.joints[frame] and idle.joints[frame][index]
    if base then local w=M.actionWeight(motion,track);for k=1,3 do point[k]=base[k]+(point[k]-base[k])*w end end
  end
  return point
end
-- Return the two exact cached source matrices bracketing the current trainer
-- clock plus the fractional source time. Do NOT lerp matrix entries here:
-- retail interpolates the underlying HSD animation channels before composing
-- the JObj matrix, and a raw 3x4 lerp can introduce shear. The throw renderer
-- may consume this only after it has an equivalent source-channel interpolation
-- path; exposing the bracket now closes the cache/runtime data boundary without
-- making a false 1:1 claim.
function M.trackThrowPartBracket(track,motion)
  local c,a,b,u=M.trackSample(track,motion and motion.nativeKind,motion and motion.nativeAge,
    motion and motion.nativeActionAge,motion and motion.nativeDuration)
  local part=c and c.throwPart
  local matrices=part and part.matrices
  local ma=matrices and matrices[a];local mb=matrices and matrices[b]
  if type(ma)~="table" or type(mb)~="table" then return nil end
  return ma,mb,u,tonumber(part.selector),tonumber(part.partIndex)
end
function M.releaseTracks(groups)
  for _,g in ipairs(groups or {}) do
    for _,mesh in ipairs(g.nativeBuffers or {}) do pcall(mesh.release,mesh) end
    g.nativeBuffers=nil;g.nativeTrack=nil;g.nativePair=nil;g.nativeIdleFrame=nil;g.nativeClip=nil;g.nativeFrames=nil
  end
end
local function bindNative(groups,motion)
  local track=groups and groups[1] and groups[1].nativeTrack
  local clip,a,b,u,role=M.trackSample(track,motion.nativeKind,motion.nativeAge,motion.nativeActionAge,motion.nativeDuration)
  if not clip or not probeAttach() then return false end
  local idle,idleFrame=idleReference(track,motion)
  local weight=M.actionWeight(motion,track)
  local pair=role..":"..a..":"..b
  for gi,g in ipairs(groups) do
    if g.nativePair~=pair then
      g.nativeBuffers=g.nativeBuffers or {}
      g.nativeFrames=g.nativeFrames or {}
      -- The old B frame is usually the new A frame. Rotate its GPU buffer
      -- rather than copying the same source vertices a second time.
      if g.nativeClip==clip and g.nativeFrames[2]==a then
        g.nativeBuffers[1],g.nativeBuffers[2]=g.nativeBuffers[2],g.nativeBuffers[1]
        g.nativeFrames[1],g.nativeFrames[2]=g.nativeFrames[2],g.nativeFrames[1]
      end
      for slot,frame in ipairs({a,b}) do
        if g.nativeClip~=clip or g.nativeFrames[slot]~=frame then
          local n=clip.groups[gi].vertices;local stride=n*24
          local bytes=clip.bytes[gi]:sub((frame-1)*stride+1,frame*stride)
          if not g.nativeBuffers[slot] then
            g.nativeBuffers[slot]=assert(love.graphics.newMesh(TRACK_FORMAT,n,"triangles","stream"))
          end
          local data=love.data.newByteData(bytes)
          g.nativeBuffers[slot]:setVertices(data)
          if data.release then data:release() end
          g.nativeFrames[slot]=frame
        end
      end
      g.nativeClip=clip;g.nativePair=pair
    end
    local function attach(slot,buffer,name)
      if attachStyle=="step4" then g.mesh:attachAttribute(slot,buffer,"pervertex",name)
      else g.mesh:attachAttribute(slot,buffer,name) end
    end
    if idle and (weight<1 or not g.nativeBuffers[3]) then
      if g.nativeIdleFrame~=idleFrame then
        local n=idle.groups[gi].vertices;local stride=n*24
        g.nativeBuffers[3]=g.nativeBuffers[3] or assert(love.graphics.newMesh(TRACK_FORMAT,n,"triangles","stream"))
        local data=love.data.newByteData(idle.bytes[gi]:sub((idleFrame-1)*stride+1,idleFrame*stride))
        g.nativeBuffers[3]:setVertices(data);if data.release then data:release() end
        g.nativeIdleFrame=idleFrame
      end
      attach("VertexPosition",g.nativeBuffers[3],"NativePosition")
      attach("VertexNormal",g.nativeBuffers[3],"NativeNormal")
    end
    attach("ActionAPosition",g.nativeBuffers[1],"NativePosition")
    attach("ActionBPosition",g.nativeBuffers[2],"NativePosition")
    -- Reuse the two secondary-pose slots for normals: still seven attributes.
    attach("BreathPosition",g.nativeBuffers[1],"NativeNormal")
    attach("LookPosition",g.nativeBuffers[2],"NativeNormal")
    g.posePair=nil;g.nativeAttached=true
  end
  motion.nativeMix=u;motion.nativeWeight=idle and M.actionWeight(motion,track) or 1;motion.nativeBound=true
  return true
end

function M.bindPair(groups,motion)
  motion=motion or {}
  motion.nativeBound=false
  if bindNative(groups,motion) then return end
  for _,g in ipairs(groups or {}) do
    if g.nativeAttached then
      for _,name in ipairs({"VertexPosition","VertexNormal","BreathPosition","LookPosition"}) do g.mesh:detachAttribute(name) end
      g.nativeAttached=nil;g.posePair=nil
    end
  end
  local keyA,_,keyB=M.actionPair(motion)
  local pair=tostring(keyA or "base").."|"..tostring(keyB or "base")
  local dense=M.dense()
  for _,grp in ipairs(groups or {}) do
    if grp.mesh and grp.posePair~=pair then
      if dense then
        -- With no action active both mixes are zero, so the bind pose is a
        -- correct and cheap thing to leave bound.
        local a=M.ATTRIBUTE[keyA] or "VertexPosition"
        local b=M.ATTRIBUTE[keyB] or "VertexPosition"
        local okA=attachOne(grp.mesh,a,"ActionAPosition")
        local okB=attachOne(grp.mesh,b,"ActionBPosition")
        if okA and okB then grp.posePair=pair;M.rebinds=M.rebinds+1 end
      else
        local source=grp.poseSourceRows
        if type(source)=="table" then
          local rows={}
          for i,row in ipairs(source) do rows[i]=M.compactVertex(row,keyA,keyB) end
          if pcall(grp.mesh.setVertices,grp.mesh,rows) then
            grp.posePair=pair;M.rewrites=M.rewrites+1
          end
        end
      end
    end
  end
end

-- Send the seven-attribute shader's morph uniforms.
function M.sendMixes(shader,motion)
  motion=motion or {}
  local _,wA,_,wB=M.actionPair(motion)
  if motion.nativeBound then local w=motion.nativeWeight or 1;wA=(1-motion.nativeMix)*w;wB=motion.nativeMix*w end
  shader:send("nativeTrackEnabled",motion.nativeBound and 1 or 0)
  shader:send("nativeTrackMix",motion.nativeMix or 0)
  shader:send("breathMix",motion.breath or 0)
  shader:send("lookMix",motion.look or 0)
  shader:send("actionAMix",wA or 0)
  shader:send("actionBMix",wB or 0)
  shader:send("sourcePoseGain",1)
end

function M.status()
  return {version=1,mode=M.mode(),attachStyle=probeAttach() or "unavailable",
    shaderAttributes=7,previousAttributes={nonWindows=15,windows=7},
    sourcePoses=10,rebinds=M.rebinds,rewrites=M.rewrites,
    denseStride=M.DENSE_STRIDE,unifiedAcrossPlatforms=true}
end

return M
