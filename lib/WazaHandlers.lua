local V=...
local Waza=V and V.WazaSequenceRuntime
local Assets=V and V.GeneratedAssets
local CSM=V and V.CurrentSpriteModels
local Audio=V and V.WazaAudioRuntime
local RuntimeMeshCache=V and V.RuntimeMeshCache
local CameraFov=V and V.WazaCameraFov
local CameraParams=V and V.WazaCameraParams
local H={installed=false,models={},effects={},controllers={player={},enemy={}},opaque={},lastModel=nil,modelCache={},partsCache={},modelErrors={},textureCache={},drawError=nil,
  postCanvas=nil,postHistory=nil,postW=0,postH=0,distortShader=nil,postErrors=0}

-- Hard-cache slicing runs repeatedly while materializing Waza runtime meshes.
-- Platform identity cannot change mid-process, so resolve it once rather than
-- calling love.system.getOS() on every pump (a relatively expensive bridge on
-- Android). No timing budget changes: only the lookup is removed.
local function platformOS()
  if love and love.system and type(love.system.getOS)=="function" then
    local ok,value=pcall(love.system.getOS)
    if ok and value then return tostring(value) end
  end
  return "Unknown"
end
local PLATFORM_OS=platformOS()
local MOBILE_RUNTIME=PLATFORM_OS=="Android" or PLATFORM_OS=="iOS"

local FORMAT_STATIC={
  {"VertexPosition","float",3},{"VertexTexCoord","float",2},{"VertexNormal","float",3},
}
-- Base position/UV/normal plus twelve exact HSD-evaluated source positions.
-- Packing mirrors PokemonActors so Type-2 Waza models stay under generic GPU
-- attribute limits while preserving the retail 60 Hz pose stream.
local FORMAT_MORPH={
  {"VertexPosition","float",3},{"VertexTexCoord","float",2},{"VertexNormal","float",3},
  {"FramePack1","float",4},{"FramePack2","float",4},{"FramePack3","float",4},
  {"FramePack4","float",4},{"FramePack5","float",4},{"FramePack6","float",4},
  {"FramePack7","float",4},{"FramePack8","float",4},{"FramePack9","float",4},
}
local VERTEX_STATIC=[[
uniform mat4 vp;
uniform mat4 model;
attribute vec3 VertexNormal;
varying vec3 wNormal;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  vec4 world=model*vec4(vertex_position.xyz,1.0);
  wNormal=normalize((model*vec4(VertexNormal,0.0)).xyz);
  return vp*world;
}
]]
local VERTEX_MORPH=[[
uniform mat4 vp;
uniform mat4 model;
uniform float w0; uniform float w1; uniform float w2; uniform float w3;
uniform float w4; uniform float w5; uniform float w6; uniform float w7;
uniform float w8; uniform float w9; uniform float w10; uniform float w11; uniform float w12;
attribute vec3 VertexNormal;
attribute vec4 FramePack1; attribute vec4 FramePack2; attribute vec4 FramePack3;
attribute vec4 FramePack4; attribute vec4 FramePack5; attribute vec4 FramePack6;
attribute vec4 FramePack7; attribute vec4 FramePack8; attribute vec4 FramePack9;
varying vec3 wNormal;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  vec3 f1=FramePack1.xyz;
  vec3 f2=vec3(FramePack1.w,FramePack2.x,FramePack2.y);
  vec3 f3=vec3(FramePack2.z,FramePack2.w,FramePack3.x);
  vec3 f4=FramePack3.yzw;
  vec3 f5=FramePack4.xyz;
  vec3 f6=vec3(FramePack4.w,FramePack5.x,FramePack5.y);
  vec3 f7=vec3(FramePack5.z,FramePack5.w,FramePack6.x);
  vec3 f8=FramePack6.yzw;
  vec3 f9=FramePack7.xyz;
  vec3 f10=vec3(FramePack7.w,FramePack8.x,FramePack8.y);
  vec3 f11=vec3(FramePack8.z,FramePack8.w,FramePack9.x);
  vec3 f12=FramePack9.yzw;
  vec3 p=vertex_position.xyz*w0+f1*w1+f2*w2+f3*w3+f4*w4+f5*w5+f6*w6+f7*w7+f8*w8+f9*w9+f10*w10+f11*w11+f12*w12;
  vec4 world=model*vec4(p,1.0);
  wNormal=normalize((model*vec4(VertexNormal,0.0)).xyz);
  return vp*world;
}
]]
local PIXEL=[[
uniform vec4 materialColor;
uniform float useTexture;
uniform float opacity;
uniform float unlit;
uniform float forceOpaque;
uniform float envMode;
uniform vec3 effectTint;
uniform vec3 uvRow0;
uniform vec3 uvRow1;
varying vec3 wNormal;
vec4 effect(vec4 color, Image texture, vec2 uv, vec2 screen) {
  vec3 nn=normalize(wNormal);
  vec2 envUV=vec2(nn.x*0.5+0.5,0.5-nn.y*0.5);
  vec3 uvh=vec3(uv,1.0);
  vec2 sourceUV=vec2(dot(uvRow0,uvh),dot(uvRow1,uvh));
  vec4 t=Texel(texture,mix(sourceUV,envUV,envMode));
  float texA=mix(1.0,t.a,useTexture);
  float a=mix(texA,1.0,forceOpaque)*materialColor.a*opacity*color.a;
  if (a<0.025) discard;
  // Keep the source effect's keyed colour on textured groups too. Its RGB was
  // previously folded into materialColor, then discarded by this texture mix.
  vec3 base=mix(materialColor.rgb,t.rgb,useTexture)*effectTint;
  if (unlit > 0.5) return vec4(base,a);
  vec3 n=normalize(wNormal);
  vec3 l=normalize(vec3(-0.38,0.84,0.39));
  float key=0.70+0.30*abs(dot(n,l));
  return vec4(base*key,a);
}
]]
local shaderStatic,shaderMorph
local modelUseSerial=0
local runtimeMeshHits,runtimeMeshWrites,runtimeMeshFallbacks=0,0,0
local hardCacheQueue,hardCacheSeen={},{}
local hardCacheState={running=false,total=0,done=0,failed=0,last=nil}
local hardCacheRetries={}
local HARD_CACHE_ROW_RETRIES=1

local function key(inst,entry)
  local entryKey=entry and (entry.runtimeIdentifier or
    (tostring(entry.phase or "?")..":"..tostring(entry.identifier or entry.index or "?"))) or "?"
  return tostring(inst and inst.serial or "?")..":"..tostring(entryKey)
end
local function remove(t,k) t[k]=nil end

local function readLua(path)
  if not (Assets and type(Assets.read)=="function") then return nil,"generated asset service unavailable" end
  local src,err=Assets.read(path);if type(src)~="string" then return nil,err or ("missing "..tostring(path)) end
  local f,e=load(src,"@generated/"..tostring(path));if not f then return nil,e end
  local ok,v=pcall(f);if not ok then return nil,v end
  return v
end
local function imageFromRaw(spec)
  if not (spec and spec.path and love and love.image and love.graphics) then return nil end
  if H.textureCache[spec.path] then return H.textureCache[spec.path] end
  local bytes=Assets and Assets.read and Assets.read(spec.path)
  if type(bytes)~="string" then return nil,"missing "..tostring(spec.path) end
  local ok,d=pcall(love.image.newImageData,spec.w,spec.h,"rgba8",bytes);if not ok then return nil,d end
  local ok2,img=pcall(love.graphics.newImage,d);if not ok2 then return nil,img end
  if img.setFilter then pcall(img.setFilter,img,"linear","linear",8) end
  if img.setWrap then
    local function wn(v) v=tonumber(v) or 0;if v==1 then return "repeat" elseif v==2 then return "mirroredrepeat" end;return "clamp" end
    pcall(img.setWrap,img,wn(spec.wrapS),wn(spec.wrapT))
  end
  H.textureCache[spec.path]=img
  return img
end
local function ensureShader(morph)
  -- Do not use `morph and shaderMorph or shaderStatic`: when the morph
  -- shader is cold and the static shader is warm it returns the WRONG shader.
  -- That silently removed every animated Type-2 body on its first w0 upload.
  local current
  if morph then current=shaderMorph else current=shaderStatic end
  if current then return current end
  if not (love and love.graphics and love.graphics.newShader) then return nil,"LÖVE shader unavailable" end
  local ok,sh=pcall(love.graphics.newShader,morph and VERTEX_MORPH or VERTEX_STATIC,PIXEL)
  if not ok then return nil,sh end
  if morph then shaderMorph=sh else shaderStatic=sh end
  return sh
end

local function decodedVertices(group,expectedStride,checkpoint)
  if type(group)~="table" then return nil,"Waza vertex group missing" end
  if type(group.vertices)=="table" then return group.vertices end -- legacy cache
  local packed=group.verticesPacked
  if type(packed)~="string" then return nil,"Waza packed vertex payload missing" end
  local stride=tonumber(group.vertexStride) or tonumber(expectedStride) or 8
  if stride~=expectedStride then
    return nil,("Waza vertex stride %s does not match expected %s"):format(tostring(stride),tostring(expectedStride))
  end
  local rows={}
  for line in packed:gmatch("[^\r\n]+") do
    local row={}
    for token in line:gmatch("[^,]+") do
      local n=tonumber(token);if n==nil then return nil,"Waza packed vertex contains non-number" end
      row[#row+1]=n
    end
    if #row~=stride then return nil,("Waza packed vertex row has %d scalars; expected %d"):format(#row,stride) end
    rows[#rows+1]=row
    if checkpoint and #rows%128==0 then checkpoint() end
  end
  if #rows==0 then return nil,"Waza packed vertex payload empty" end
  group.vertices=rows;group.verticesPacked=nil
  return rows
end

-- Packed effects must not survive a different extractor/schema just because
-- their filename (or a missing cache size) happens to match. This namespace
-- refreshes only Waza binary sidecars; source/arena/actor/audio caches survive.
local RUNTIME_MESH_VERSION=2
local function extractorRevision()
  local x=V and V.MoveFXExtractor
  return tonumber(x and (x.runtimeRevision or x.revision)) or 0
end
local function runtimeRoot(path)
  return tostring(path or "cache/waza/model_cache.lua"):gsub("%.lua$","").."_runtime_v2_r"..extractorRevision()
end
local function runtimeMetaPath(path) return runtimeRoot(path).."/base.lua" end
local function runtimeBinPath(path,i) return runtimeRoot(path)..("/base_%02d.f32"):format(tonumber(i) or 0) end
local function sourceSize(path) local info=Assets and Assets.info and Assets.info(path) or nil;return info and tonumber(info.size) or nil end
local function runtimeUsable(meta,path,size)
  if type(meta)~="table" or tonumber(meta.runtimeMeshVersion)~=RUNTIME_MESH_VERSION
      or meta.sourcePath~=path or tonumber(meta.extractorRevision)~=extractorRevision()
      or type(meta.groups)~="table" or #meta.groups==0 then return false end
  local recorded=tonumber(meta.sourceSize)
  if size and recorded~=size then return false end
  local stride=(tonumber(meta.morphFrames) or 0)>0 and 44 or 8;local bpv=stride*4
  for i,g in ipairs(meta.groups) do
    local expected=runtimeBinPath(path,i)
    if type(g)~="table" or (g.runtimeBin~=nil and g.runtimeBin~=expected) then return false end
    local bin=g.runtimeBin or expected
    local info=Assets and Assets.info and Assets.info(bin) or nil
    if not info then return false end
    local n=tonumber(info.size)
    local count=tonumber(type(g)=="table" and g.vertexCount)
    if not count or count<3 or count%3~=0 or count~=math.floor(count) then return false end
    if n and n~=count*bpv then return false end
  end
  return true
end
local function compactGroup(g,path,i)
  local o={};for k,v in pairs(g or {}) do if k~="vertices" and k~="verticesPacked" then o[k]=v end end
  o.runtimeBin=runtimeBinPath(path,i)
  o.vertexCount=type(g.vertices)=="table" and #g.vertices or tonumber(g.vertexCount)
  return o
end
local function writeRuntimeMeta(path,cache,size,preserveExisting)
  if not (RuntimeMeshCache and RuntimeMeshCache.writeLua) then return false end
  local o={}
  for k,v in pairs(cache or {}) do if k~="groups" then o[k]=v end end
  o.runtimeMeshVersion=RUNTIME_MESH_VERSION;o.sourcePath=path;o.extractorRevision=extractorRevision()
  o.sourceSize=size
  o.groups={};for i,g in ipairs(cache.groups or {}) do o.groups[i]=compactGroup(g,path,i) end
  local ok=RuntimeMeshCache.writeLua(runtimeMetaPath(path),o,preserveExisting);if ok then runtimeMeshWrites=runtimeMeshWrites+1 end;return ok
end

local function loadCache(path)
  if not path then return nil,"Waza model cache missing" end
  if H.modelCache[path]~=nil then
    local hit=H.modelCache[path]
    if type(hit)=="table" then modelUseSerial=modelUseSerial+1;hit.__cbeUse=modelUseSerial end
    return hit or nil,H.modelErrors[path]
  end
  if not (love and love.graphics and love.graphics.newMesh) then return nil,"LÖVE mesh API unavailable" end
  local size=sourceSize(path)
  local cache,err,fromRuntime
  local preserveWazaRuntime=false
  if RuntimeMeshCache and type(RuntimeMeshCache.readLua)=="function" then
    local rtPath=runtimeMetaPath(path)
    local rt=select(1,RuntimeMeshCache.readLua(rtPath))
    preserveWazaRuntime=rt~=nil or (type(RuntimeMeshCache.exists)=="function" and RuntimeMeshCache.exists(rtPath)) or false
    if runtimeUsable(rt,path,size) then cache=rt;fromRuntime=true;runtimeMeshHits=runtimeMeshHits+1 end
  end
  if not cache then cache,err=readLua(path) end
  if not cache then H.modelCache[path]=false;H.modelErrors[path]=tostring(err);return nil,err end
  local morph=(tonumber(cache.morphFrames) or 0)>0
  local fmt=morph and FORMAT_MORPH or FORMAT_STATIC
  local textures,groups={},{}
  local canonicalFallback=nil
  for i,g in ipairs(cache.groups or {}) do
    local img
    if g.texture then
      local tp=g.texture.path;img=textures[tp]
      if not img then
        local why;img,why=imageFromRaw(g.texture)
        if not img then H.modelCache[path]=false;H.modelErrors[path]=tostring(why);return nil,why end
        textures[tp]=img
      end
    end
    local stride=morph and 44 or 8
    local mesh,vErr,vertices
    if fromRuntime and RuntimeMeshCache and type(RuntimeMeshCache.meshFromPath)=="function" then
      mesh,vErr=RuntimeMeshCache.meshFromPath(fmt,g.runtimeBin or runtimeBinPath(path,i),stride,"static")
    end
    if not mesh then
      local sourceGroup=g
      -- Same fail-open rule as trainer meshes: compact runtime metadata omits
      -- the textual vertex payload. A backend that rejects the persistent f32
      -- sidecar must reopen the canonical Waza cache instead of treating the
      -- effect as empty/invisible (Windows has already exposed this class of
      -- backend-specific sidecar failure for trainer models).
      if fromRuntime and type(g.vertices)~="table" and type(g.verticesPacked)~="string" then
        if canonicalFallback==nil then canonicalFallback=select(1,readLua(path)) or false end
        if canonicalFallback and canonicalFallback.groups and canonicalFallback.groups[i] then
          sourceGroup=canonicalFallback.groups[i];runtimeMeshFallbacks=runtimeMeshFallbacks+1
        end
      end
      vertices,vErr=decodedVertices(sourceGroup,stride)
      if not vertices then H.modelCache[path]=false;H.modelErrors[path]=tostring(vErr);return nil,vErr end
      local ok,built=pcall(love.graphics.newMesh,fmt,vertices,"triangles","static")
      if not ok then H.modelCache[path]=false;H.modelErrors[path]=tostring(built);return nil,built end
      mesh=built
      if RuntimeMeshCache and RuntimeMeshCache.supported and RuntimeMeshCache.supported() then RuntimeMeshCache.writeRows(runtimeBinPath(path,i),vertices,stride,nil,preserveWazaRuntime) end
    end
    if img then mesh:setTexture(img) end
    local effectLike=g.effect==true or (g.useConstant==true and g.useDiffuseLighting==false)
    groups[#groups+1]={mesh=mesh,image=img,diffuse=g.diffuse or {1,1,1},alpha=tonumber(g.alpha) or 1,
      xlu=g.xlu==true,noz=g.noz==true,renderFlags=tonumber(g.renderFlags) or 0,textureTexgen=g.textureTexgen,
      shadow=g.shadow==true,effect=g.effect==true,useConstant=g.useConstant==true,
      useVertexColor=g.useVertexColor==true,useDiffuseLighting=g.useDiffuseLighting~=false,
      -- GameCube Waza effect/constant passes are frequently additive/TEV-light
      -- carriers. Treating a black mask as opaque alpha geometry is what can
      -- turn a correct move into a one-frame black screen in the portable path.
      luminous=effectLike}
  end
  if #groups==0 then H.modelCache[path]=false;H.modelErrors[path]="Waza model cache empty";return nil,H.modelErrors[path] end
  if not fromRuntime and RuntimeMeshCache and RuntimeMeshCache.packSupported and RuntimeMeshCache.packSupported() then
    local all=true;local bpv=(morph and 44 or 8)*4
    for i=1,#(cache.groups or {}) do local info=Assets.info and Assets.info(runtimeBinPath(path,i)) or nil;local n=info and tonumber(info.size);if not info or (n and (n<bpv or n%bpv~=0)) then all=false;break end end
    if all then writeRuntimeMeta(path,cache,size,preserveWazaRuntime) end
  end
  local out={groups=groups,bounds=cache.bounds,source=cache.source,textures=textures,morph=morph,
    morphFrames=tonumber(cache.morphFrames) or 0,startFrame=tonumber(cache.startFrame) or 0,endFrame=tonumber(cache.endFrame) or 0,
    animation=cache.animation,textureAnimation=cache.textureAnimation}
  modelUseSerial=modelUseSerial+1;out.__cbeUse=modelUseSerial
  H.modelCache[path]=out;H.modelErrors[path]=nil;return out
end

-- CPU/disk-only runtime-sidecar backfill. This is the core of Hard Cache
-- Save for MoveFX: older portable caches may contain the exact canonical Waza
-- model but no binary sidecar because their cache backend omitted file sizes.
-- Bake one model per stable overworld scheduler slice and allocate no GPU mesh.
local function bakeRuntimeCache(path,checkpoint)
  local size=sourceSize(path)
  local preserveRuntime=false
  if RuntimeMeshCache and type(RuntimeMeshCache.readLua)=="function" then
    local metaPath=runtimeMetaPath(path)
    local meta=select(1,RuntimeMeshCache.readLua(metaPath))
    if runtimeUsable(meta,path,size) then return true,"ready" end
    preserveRuntime=meta~=nil or (type(RuntimeMeshCache.exists)=="function" and RuntimeMeshCache.exists(metaPath)) or false
  end
  if not (RuntimeMeshCache and RuntimeMeshCache.packSupported and RuntimeMeshCache.packSupported()) then return false,"float32 pack API unavailable" end
  local cache,err=readLua(path);if type(cache)~="table" then return false,err end
  local stride=(tonumber(cache.morphFrames) or 0)>0 and 44 or 8
  for i,g in ipairs(cache.groups or {}) do
    local rows,why=decodedVertices(g,stride,checkpoint);if not rows then return false,why end
    local ok,werr=RuntimeMeshCache.writeRows(runtimeBinPath(path,i),rows,stride,checkpoint,preserveRuntime);if not ok then return false,werr end
  end
  if #(cache.groups or {})==0 then return false,"Waza model cache empty" end
  local ok=writeRuntimeMeta(path,cache,size,preserveRuntime)
  if RuntimeMeshCache.invalidateLua then RuntimeMeshCache.invalidateLua(runtimeMetaPath(path)) end
  return ok==true,ok and "baked" or "metadata write failed"
end

local function collectHardCachePaths(value,depth,seenTables)
  depth=(depth or 0)+1;if depth>14 or type(value)~="table" then return end
  seenTables=seenTables or {};if seenTables[value] then return end;seenTables[value]=true
  for k,v in pairs(value) do
    if k=="cache" and type(v)=="string" and v:match("^cache/movefx/") and v:match("%.lua$") then
      if not hardCacheSeen[v] then hardCacheSeen[v]=true;hardCacheQueue[#hardCacheQueue+1]=v end
    elseif type(v)=="table" then collectHardCachePaths(v,depth,seenTables) end
  end
end

local hardTask=nil
local hardDeadline=0
local hardCacheHead=1
local function hardPending()
  return math.max(0,#hardCacheQueue-hardCacheHead+1)
end
local function hardClock()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end
local function hardCheckpoint()
  if hardClock()>=hardDeadline then coroutine.yield("cpu-slice") end
end
local function hardSlice()
  return MOBILE_RUNTIME and 0.003 or 0.006
end
function H.queueHardCacheSpecs(specs)
  hardTask=nil
  hardCacheQueue={};hardCacheHead=1;hardCacheSeen={};hardCacheRetries={};hardCacheState={running=false,total=0,done=0,failed=0,last=nil}
  for _,spec in ipairs(type(specs)=="table" and specs or {}) do collectHardCachePaths(spec,0,{}) end
  hardCacheState.total=#hardCacheQueue;hardCacheState.running=#hardCacheQueue>0
  return #hardCacheQueue
end
function H.pumpHardCache(maxItems)
  maxItems=math.max(1,math.floor(tonumber(maxItems) or 1));local n=0
  hardDeadline=hardClock()+hardSlice()
  -- This queue can contain many Type-2 model payloads across a six-mon moveset.
  -- Removing element 1 shifts every remaining Lua array entry, making a full
  -- Hard Cache bake O(n^2) bookkeeping on top of the actual source work. Keep a
  -- monotonic head instead. The queue is reset when drained, so retained path
  -- strings never outlive the current hard-cache pass.
  while n<maxItems and hardCacheHead<=#hardCacheQueue do
    local path=hardCacheQueue[hardCacheHead]
    if not hardTask then hardTask=coroutine.create(function() return bakeRuntimeCache(path,hardCheckpoint) end) end
    local resumed,ok,why=coroutine.resume(hardTask)
    if resumed and coroutine.status(hardTask)~="dead" then break end
    hardTask=nil;hardCacheHead=hardCacheHead+1;n=n+1
    hardCacheState.last=path
    if resumed and ok then hardCacheState.done=hardCacheState.done+1
    else
      local reason=tostring(resumed and why or ok)
      local retries=(hardCacheRetries[path] or 0)+1;hardCacheRetries[path]=retries
      if retries<=HARD_CACHE_ROW_RETRIES then
        -- Same bounded transient-retry policy as Pokemon storage rows. Canonical
        -- Waza Lua remains authoritative; a half-written runtime sidecar cannot
        -- become a completion proof because the retry revalidates it first.
        hardCacheState.retried=(hardCacheState.retried or 0)+1
        hardCacheState.lastRetry=path;hardCacheState.lastRetryError=reason
        hardCacheQueue[#hardCacheQueue+1]=path
      else
        hardCacheState.failed=hardCacheState.failed+1
        hardCacheState.lastFailed=path;hardCacheState.lastError=reason
        H.modelErrors[path]=reason
      end
    end
    if hardClock()>=hardDeadline then break end
  end
  local pending=hardPending()
  hardCacheState.running=pending>0
  if pending==0 then hardCacheQueue={};hardCacheHead=1;hardCacheRetries={} end
  return {processed=n,pending=pending,running=hardCacheState.running,done=hardCacheState.done,failed=hardCacheState.failed}
end
function H.cancelHardCache() hardTask=nil;hardCacheQueue={};hardCacheHead=1;hardCacheSeen={};hardCacheRetries={};hardCacheState.running=false end

function H.hardCacheStatus()
  return {running=hardCacheState.running,pending=hardPending(),total=hardCacheState.total,done=hardCacheState.done,failed=hardCacheState.failed,last=hardCacheState.last,
    lastFailed=hardCacheState.lastFailed,lastError=hardCacheState.lastError,retried=hardCacheState.retried or 0,
    lastRetry=hardCacheState.lastRetry,lastRetryError=hardCacheState.lastRetryError}
end

local function pageForAsset(asset,localFrame)
  local anim=type(asset)=="table" and asset.animation
  if not (type(anim)=="table" and anim.animated==true and type(anim.pages)=="table" and #anim.pages>0) then
    return asset and asset.cache,nil
  end
  local f=math.max(0,tonumber(localFrame) or 0)
  local selected=anim.pages[#anim.pages]
  for _,page in ipairs(anim.pages) do
    if f>= (tonumber(page.startFrame) or 0) and f<= (tonumber(page.endFrame) or math.huge) then selected=page;break end
  end
  return selected and selected.cache,selected
end

local function loadModel(asset,localFrame)
  local path,page=pageForAsset(asset,localFrame)
  local model,err=loadCache(path)
  if not model and page and asset and asset.cache then model,err=loadCache(asset.cache);page=nil end
  if model then model.asset=asset end
  return model,err,page
end

local function morphWeights(page,localFrame)
  local w={0,0,0,0,0,0,0,0,0,0,0,0,0}
  if not page then w[1]=1;return w end
  local start=tonumber(page.startFrame) or 0
  local n=math.max(0,math.min(12,tonumber(page.morphFrames) or ((tonumber(page.endFrame) or start)-start)))
  if n<=0 then w[1]=1;return w end
  local x=math.max(0,math.min(n,(tonumber(localFrame) or 0)-start))
  local i=math.floor(x);local t=x-i
  if i>=n then w[n+1]=1
  else w[i+1]=1-t;w[i+2]=t end
  return w
end
local UV_IDENTITY={1,0,0,0,1,0}
local function textureAnimationSample(model,groupIndex,localFrame)
  local anim=type(model)=="table" and model.textureAnimation or nil
  if not anim and type(model)=="table" and type(model.asset)=="table" then anim=model.asset.textureAnimation end
  local frames=type(anim)=="table" and type(anim.groups)=="table" and anim.groups[groupIndex] or nil
  if type(frames)~="table" or #frames==0 then return UV_IDENTITY end
  local last=math.max(0,math.min(#frames-1,math.floor(tonumber(anim.endFrame) or (#frames-1))))
  local x=math.max(0,math.min(last,tonumber(localFrame) or 0))
  local i=math.floor(x);local t=x-i
  local a=frames[i+1] or frames[1] or UV_IDENTITY
  local b=frames[math.min(last,i+1)+1] or a
  if t<=0 then return a end
  local out={};for k=1,6 do out[k]=(tonumber(a[k]) or UV_IDENTITY[k])+((tonumber(b[k]) or UV_IDENTITY[k])-(tonumber(a[k]) or UV_IDENTITY[k]))*t end
  return out
end
local function modelSpan(model,basis)
  local b=model and (model.normalizationBounds or model.bounds)
  local mn,mx=b and b.min,b and b.max
  if not (mn and mx) then return 16 end
  local sx=math.abs((tonumber(mx[1]) or 0)-(tonumber(mn[1]) or 0))
  local sy=math.abs((tonumber(mx[2]) or 0)-(tonumber(mn[2]) or 0))
  local sz=math.abs((tonumber(mx[3]) or 0)-(tonumber(mn[3]) or 0))
  if basis and basis.groundField then return math.max(.001,sx,sz) end
  return math.max(.001,sx,sy,sz)
end
-- Per-move reach overrides are allowed only when retail proves that the model
-- uses a local lane other than the common 100-unit attacker->target space.
-- Ice Beam (58) must NOT be listed here: GC6E01 reitoubeam Type-2 entry 8 is
-- played directly by _wazaSequenceModelEntryStart with no target-fit transform.
-- Its decoded HSD grows to Z=103.13538192332825 on the source end page, i.e. it
-- intentionally extends a little beyond the 100-unit target line. The old 85.9
-- override enlarged that source overshoot into roughly 20% of the live lane.
local function partTransformSelector(positionType)
  local pt=tonumber(positionType)
  if not pt then return 0 end
  pt=math.floor(pt)
  return (pt>=0 and pt<=6) and (pt+1) or 0
end
local function filteredPartTransform(part,positionType)
  if type(part)~="table" then return nil,0 end
  local selector=partTransformSelector(positionType)
  if selector==0 then return nil,selector end
  -- GSmodelAttachToGSpart's selector is an enum, not a binary mask. The exact
  -- component combinations are proven by _wazaSequenceModelEntryStart's switch:
  -- 1=P, 2=R, 3=S, 4=P+R, 5=R+S, 6=P+S, 7=P+R+S.
  local inheritPosition=(selector==1 or selector==4 or selector==6 or selector==7)
  local inheritRotation=(selector==2 or selector==4 or selector==5 or selector==7)
  local inheritScale=(selector==3 or selector==5 or selector==6 or selector==7)
  local out={};for i=1,12 do out[i]=tonumber(part[i]) or 0 end
  local scales={}
  for c=1,3 do
    local x,y,z=out[c],out[c+4],out[c+8];local n=math.sqrt(x*x+y*y+z*z)
    scales[c]=n>1e-9 and n or 1
  end
  if inheritRotation then
    if not inheritScale then
      for c=1,3 do local n=scales[c];out[c]=out[c]/n;out[c+4]=out[c+4]/n;out[c+8]=out[c+8]/n end
    end
  else
    for r=1,3 do for c=1,3 do out[(r-1)*4+c]=(r==c) and (inheritScale and scales[c] or 1) or 0 end end
  end
  if not inheritPosition then out[4],out[8],out[12]=0,0,0 end
  return out,selector
end
local function linkedParticleBirthTransform(part,positionType,flags)
  local selector=partTransformSelector(positionType)
  -- Retail _wazaSequenceParticleEntryStart passes `(node->flags >> 1) & 1`
  -- as fn_80118FB0's transform state. fn_80118FB0 only installs the GSpart/JObj
  -- follow when that state is non-zero. This is distinct from the Type-2 model
  -- attachment selector above: a flag-1 linked particle (Surf's authored foam
  -- rows) uses the linked Type-2 object as its source model, but does NOT inherit
  -- the selected part matrix. Applying selector-2 as a model-style rotation-only
  -- matrix made those generators rotate with wave parts even though retail does
  -- not install that attachment.
  local state=math.floor((tonumber(flags) or 0)/2)%2
  if state==0 then return nil,selector,state end
  local transform=filteredPartTransform(part,positionType)
  return transform,selector,state
end
local function modelMatrix(basis,model,asset)
  local o,r,u,f=basis.origin,basis.right,basis.up,basis.forward
  -- Type-2 HSD effects are raw source models, unlike Pokemon bodies which are
  -- normalized to a 16-unit cache height. Scaling them with actor.worldScale
  -- directly made a large source object enormous and a tiny source object
  -- microscopic. Fit the source bounds to the same live combat-space target
  -- span used by GPT1 instead. For ordinary ~16-unit assets this naturally
  -- collapses to essentially the previous Pokemon-relative scale.
  if basis.aimed or basis.fieldWave or (asset and asset.transformOnly) then
    -- Keep authored animation growth: fitting each morph page to its own
    -- bounds shrank a beam as it extended. CurrentSpriteModels has already
    -- converted each exact retail model/particle forward envelope into the
    -- live attacker->target unit, so use those source axes directly here.
    local v=basis.sourceUnits
    return {r[1]*v.x,u[1]*v.y,f[1]*v.z,o[1],r[2]*v.x,u[2]*v.y,f[2]*v.z,o[2],r[3]*v.x,u[3]*v.y,f[3]*v.z,o[3],0,0,0,1}
  end
  local desired=math.max(.10,tonumber(basis.modelTargetSpan) or tonumber(basis.referenceVisualHeight) or 16)
  local span=modelSpan(asset or (model and model.asset) or model,basis)
  local s=math.max(.01,math.min(24,desired/span))
  return {
    r[1]*s,u[1]*s,f[1]*s,o[1],
    r[2]*s,u[2]*s,f[2]*s,o[2],
    r[3]*s,u[3]*s,f[3]*s,o[3],
    0,0,0,1,
  }
end

-- A linked particle uses a part on the source effect model, NOT a Pokemon
-- body-map slot. Source 0x801D8B38 / 0x801D97F0 resolves flag 1 + linkedEntryKey
-- this way. The cache contains authored JOBJ matrices for the requested parts.
function H.linkedParticleFrame(ctx,inst,entry)
  if not (inst and entry and (tonumber(entry.flags) or 0)%2==1) then return nil end
  local wanted=tonumber(entry.linkedEntryKey)
  if not wanted or wanted<=0 then return nil,"invalid linked effect-model identity" end
  local linked
  for _,state in ipairs(inst.entries or {}) do
    local e=state.entry
    if e and e.phase==entry.phase and tonumber(e.identifier)==wanted and e.kind=="model" then linked=state;break end
  end
  if not linked or not linked.started then return nil,"linked effect-model has not started" end
  local e=linked.entry;local asset=e.modelAsset;local desc=asset and asset.parts
  if not (desc and desc.path) then return nil,"linked effect-model parts cache unavailable" end
  local data=H.partsCache[desc.path]
  if data==nil then
    local why;data,why=readLua(desc.path)
    if not (type(data)=="table" and data.revision==1 and type(data.tracks)=="table") then
      H.modelErrors[desc.path]=tostring(why or "invalid effect-model parts cache");H.partsCache[desc.path]=false
      return nil,H.modelErrors[desc.path]
    end
    H.partsCache[desc.path]=data
  end
  if data==false then return nil,H.modelErrors[desc.path] end
  local track=data.tracks[tonumber(entry.partIndex)]
  if not (track and track[1]) then return nil,"requested effect-model part is absent" end
  local frame=math.max(0,math.min(tonumber(data.endFrame) or 0,
    (tonumber(inst.frame) or 0)-(tonumber(linked.startFrame) or 0)))
  local first=math.floor(frame)+1;local a=track[first] or track[#track];local b=track[first+1] or a;local t=frame-math.floor(frame)
  local part={};for k=1,12 do part[k]=a[k]+(b[k]-a[k])*t end
  local originSide=inst.role=="damage" and inst.target or inst.side
  local otherSide=originSide==inst.side and inst.target or inst.side
  local basis=CSM:wazaBasis(ctx,originSide,otherSide,e.attachment,{moveId=tonumber(inst.moveId) or (inst.spec and inst.spec.moveId),
    style=inst.spec and inst.spec.style,role=inst.role,sourceStrict=true,positionType=e.positionType,flags=e.flags,modelEntry=e})
  if not basis then return nil,"linked effect-model world basis unavailable" end
  local m=modelMatrix(basis,nil,asset)
  local function column(i)
    local x,y,z=m[i],m[i+4],m[i+8];local n=math.sqrt(x*x+y*y+z*z)
    if n<1e-9 then return nil end
    return {x/n,y/n,z/n},n
  end
  local right,x=column(1);local up,y=column(2);local forward,z=column(3)
  if not (right and up and forward) then return nil,"singular linked effect-model transform" end
  basis.origin={m[4],m[8],m[12]};basis.right=right;basis.up=up;basis.forward=forward
  basis.sourceUnits={x=x,y=y,z=z};basis.modelLinked=true
  local particleTransform,selector,linkState=linkedParticleBirthTransform(part,entry.positionType,entry.flags)
  return {basis=basis,part=part,particleTransform=particleTransform,transformSelector=selector,
    particleLinkState=linkState,modelIdentifier=wanted,partIndex=entry.partIndex,frame=frame}
end

-- Source type 2 is proven by the retail main.dol dispatcher/loader to be the
-- Waza HSD effect-model entry. 1.6 compiles its HSD data during MoveFX cache
-- extraction and instantiates the cached model at the authored sequence frame.
local function modelStart(ctx,inst,entry,eventName,state)
  local asset=entry and entry.modelAsset
  if not (type(asset)=="table" and asset.cache) then
    H.modelErrors[key(inst,entry)]=tostring(entry and entry.modelError or "type-2 model asset unavailable")
    return false
  end
  local k=key(inst,entry)
  H.models[k]={context=ctx,instance=inst,entry=entry,state=state,asset=asset,startedFrame=inst.frame,rawPath=entry.rawPath,
    dataOffset=entry.dataOffset,dataSize=entry.dataSize or entry.embeddedSize,dataMagic=entry.dataMagic}
  H.lastModel=H.models[k]
  return true
end
local function modelUpdate(ctx,inst,entry,frame,state)
  local asset=entry and entry.modelAsset
  local anim=asset and asset.animation
  local localFrame=(tonumber(frame) or tonumber(inst.frame) or 0)-(tonumber(state and state.startFrame) or 0)
  if type(anim)=="table" and (anim.animated==true or anim.partsAnimated==true) then
    return localFrame < (tonumber(anim.endFrame) or 0) and true or "done"
  end
  -- Until the remaining Type-2 payload words prove a separate object lifetime,
  -- a static source model remains alive through the authored Waza timeline.
  return (tonumber(frame) or 0)<(tonumber(inst.sourceEndFrame) or 1) and true or "done"
end
local function modelFinish(ctx,inst,entry) remove(H.models,key(inst,entry));return true end
local function modelCancel(ctx,inst,entry) remove(H.models,key(inst,entry));return true end
local function opaqueFinish() return true end

local function controllerSide(inst)
  if not inst then return "player" end
  -- Damage rows operate on the struck owner; attack/controller rows on source.
  return (inst.role=="damage" and inst.target) or inst.side or "player"
end
local function controllerState(inst)
  local side=controllerSide(inst);H.controllers[side]=H.controllers[side] or {};return H.controllers[side],side
end

-- Source type 1 is the retail sequence wait/stop controller. GC6E01 converts
-- subtype-0 source frames by video-vsync/60; CBE's presentation scheduler is
-- fixed at 60 Hz, so the serialized count is already the exact runtime delay.
-- Other subtype payload words are preserved bit-exactly rather than inventing
-- RNG or easing semantics that are not in the retail dispatcher.
local function type1Start(ctx,inst,entry,event,state)
  local mode=tonumber(entry.subtype) or 0;if mode<0 or mode>3 then return false end
  -- Retail wazaSequenceEntryUpdate only treats runtime subtype 0 as the
  -- sequence-boundary waiter. Source subtype 1/2 entries return immediately;
  -- subtype 3 is normalized by the loader to subtype 0 with a zero delay after
  -- its auxiliary table is consumed. Older CBE made 1/2 into waits and could
  -- stop an otherwise valid move chapter at the wrong frame.
  state.controllerImmediate=(mode==1 or mode==2)
  local delay=(mode==0) and math.max(0,math.floor(tonumber(entry.controllerParam) or 0)) or 0
  state.controllerDelay=delay;state.controllerMode=mode
  return true
end
local function type1Update(ctx,inst,entry,frame,state)
  if state.controllerImmediate then return "done" end
  local elapsed=(tonumber(frame) or 0)-(tonumber(state.startFrame) or 0)
  if elapsed < (tonumber(state.controllerDelay) or 0) then return true end
  if Waza and type(Waza.requestStop)=="function" then Waza:requestStop(inst,"type1-sequence-boundary") end
  return "done"
end

-- Source type 6 is a zero-duration owner/model controller. Drive semantics by
-- the proven numeric dispatcher, not the older descriptive aliases serialized
-- by WazaSequenceExtractor. Current GC6E01 sequence.c shows:
--   0/1 toggle owner effect_handle resources, 2/3 visibility, 4 remove root null,
--   5/6 add/remove root null + refresh owner animation, 7/8 stop/resume owner
--   animation while adding/removing field_80 resources, 9 sequence cleanup.
local function type6Start(ctx,inst,entry)
  local st,side=controllerState(inst);local op=tonumber(entry.subtype)
  if op==0 then st.ownerAuxEffect=true
  elseif op==1 then st.ownerAuxEffect=false
  elseif op==2 then st.hidden=true
  elseif op==3 then st.hidden=false
  elseif op==4 then st.rootNull=false
  elseif op==5 then st.rootNull=true;st.ownerAnimationRefresh=(tonumber(st.ownerAnimationRefresh) or 0)+1
  elseif op==6 then st.rootNull=false;st.ownerAnimationRefresh=(tonumber(st.ownerAnimationRefresh) or 0)+1
  elseif op==7 then st.motionFrozen=true;st.fieldAuxEffect=true
  elseif op==8 then st.motionFrozen=false;st.fieldAuxEffect=false;st.ownerAnimationRefresh=(tonumber(st.ownerAnimationRefresh) or 0)+1
  elseif op==9 then
    if Waza and type(Waza.requestStop)=="function" then Waza:requestStop(inst,"type6-sequence-cleanup") end
  else return false end
  st.lastOp=op;st.lastOpAlias=entry.controllerOp;st.serial=inst.serial;st.frame=inst.frame;st.side=side
  return true
end

function H.actorVisible(_,side)
  local st=H.controllers[tostring(side or "")]
  if st and st.hidden==true then return false end
  return nil
end
function H.actorControllerState(_,side) return H.controllers[tostring(side or "")] end

local function effectStart(ctx,inst,entry,event,state)
  local family=tonumber(entry.effectType);if not family or family<0 or family>12 then return false end
  local k=key(inst,entry);local duration=math.max(1,math.floor(tonumber(entry.effectFrames) or tonumber(entry.effect and entry.effect.frames) or 1))
  local rec={context=ctx,instance=inst,entry=entry,state=state,family=family,effect=entry.effect or {},startedFrame=inst.frame,duration=duration,assets=entry.effectAssets or {},history={}}
  rec.textureSpec=entry.effectTextureAsset
  if not rec.textureSpec then for _,a in ipairs(rec.assets) do if type(a)=="table" and type(a.texture)=="table" then rec.textureSpec=a.texture;break end end end
  H.effects[k]=rec;state.effectEndFrame=(tonumber(state.startFrame) or inst.frame)+duration
  if type(entry.effectModelAsset)=="table" and entry.effectModelAsset.cache then
    H.models[k]={context=ctx,instance=inst,entry=entry,state=state,asset=entry.effectModelAsset,startedFrame=inst.frame,rawPath=entry.rawPath,effectRec=rec}
  end
  return true
end
local function effectUpdate(ctx,inst,entry,frame,state)
  return ((tonumber(frame) or 0)<(tonumber(state.effectEndFrame) or ((tonumber(state.startFrame) or 0)+1))) and true or "done"
end
local function releaseDynamicMeshes(rec)
  for _,mesh in pairs(rec and rec.dynamicMeshes or {}) do if mesh and mesh.release then pcall(mesh.release,mesh) end end
  if rec then rec.dynamicMeshes=nil end
end
local function effectFinish(ctx,inst,entry)
  local k=key(inst,entry);local rec=H.effects[k]
  releaseDynamicMeshes(rec)
  H.effects[k]=nil;H.models[k]=nil;return true
end

function H.install()
  if H.installed or not (Waza and type(Waza.registerHandler)=="function") then return false end
  Waza:registerHandler("model","cbe-waza-model",{start=modelStart,update=modelUpdate,finish=modelFinish,cancel=modelCancel})
  -- Type-3 stays on Colosseum's particle-bank path. 1.9.13 registered an
  -- HSD-model interpretation here; the retail loader instead passes these
  -- resources through loadParticle() and fn_801190DC.
  if Audio then
    Waza:registerHandler("sound","cbe-waza-audio",{
      start=function(...) return Audio:start(...) end,
      update=function(...) return Audio:update(...) end,
      finish=function(...) return Audio:finish(...) end,
      cancel=function(...) return Audio:cancel(...) end})
  end
  Waza:registerHandler("type1","cbe-waza-controller",{start=type1Start,update=type1Update,finish=opaqueFinish,cancel=opaqueFinish})
  Waza:registerHandler("type4","cbe-waza-tracefx",{start=effectStart,update=effectUpdate,finish=effectFinish,cancel=effectFinish})
  Waza:registerHandler("type6","cbe-waza-owner-controller",{start=type6Start,finish=opaqueFinish,cancel=opaqueFinish})
  H.installed=true
  return true
end


local function graphicsScope(g,fn)
  local okPush,pushErr=pcall(g.push,"all")
  if not okPush then return false,nil,pushErr end
  local ok,value=pcall(fn)
  pcall(g.setShader)
  pcall(g.setDepthMode)
  pcall(g.pop)
  if not ok then return false,nil,value end
  return true,value,nil
end

local function modelRenderFault(rec,grp,err)
  local inst=rec and rec.instance
  H.drawError=("Type-2 render fault move=%s entry=%s: %s")
    :format(tostring(inst and inst.moveId or "?"),tostring(rec and rec.entry and rec.entry.index or "?"),tostring(err))
  H.renderFaults=(tonumber(H.renderFaults) or 0)+1
  if type(grp)=="table" then
    grp._cbeRenderFaults=(tonumber(grp._cbeRenderFaults) or 0)+1
    if grp._cbeRenderFaults>=3 then grp._cbeRenderDisabled=true end
  end
end

local function effectRGBA(c,alpha)
  c=type(c)=="table" and c or {255,255,255,255};local a=(tonumber(c[4]) or 255)/255
  return (tonumber(c[1]) or 255)/255,(tonumber(c[2]) or 255)/255,(tonumber(c[3]) or 255)/255,math.max(0,math.min(1,a*(alpha or 1)))
end
local function lerp(a,b,t)return (tonumber(a) or 0)+((tonumber(b) or 0)-(tonumber(a) or 0))*t end
local function effectSides(rec)
  local inst=rec and rec.instance;if not inst then return "player","enemy" end
  local origin=(inst.role=="damage") and inst.target or inst.side
  local other=origin==inst.side and inst.target or inst.side
  return origin or "player",other or "enemy"
end
local function sourceBasis(ctx,rec,attachment)
  if not (CSM and type(CSM.wazaBasis)=="function") then return nil end
  local inst=rec.instance;local originSide,other=effectSides(rec)
  local ok,b=pcall(CSM.wazaBasis,CSM,ctx,originSide,other,attachment~=nil and attachment or (rec.entry and rec.entry.attachment),
    {moveId=tonumber(inst.moveId) or (inst.spec and inst.spec.moveId),style=inst.spec and inst.spec.style,role=inst.role,sourceStrict=true,positionType=rec.entry and rec.entry.positionType,flags=rec.entry and rec.entry.flags})
  return ok and b or nil
end
local function sourceLocalPoint(ctx,rec,pos,attachment)
  if not (type(pos)=="table" and CSM and type(CSM.wazaLocalPoint)=="function") then return nil end
  local inst=rec.instance;local originSide,other=effectSides(rec)
  local ok,p=pcall(CSM.wazaLocalPoint,CSM,ctx,originSide,other,attachment~=nil and attachment or (rec.entry and rec.entry.attachment),pos,
    {moveId=tonumber(inst.moveId) or (inst.spec and inst.spec.moveId),style=inst.spec and inst.spec.style,role=inst.role,sourceStrict=true,positionType=rec.entry and rec.entry.positionType,flags=rec.entry and rec.entry.flags})
  return ok and p or nil
end
local function projectSource(ctx,p)
  if not (CSM and type(CSM.projectWazaWorld)=="function") then return nil end
  local ok,x,y=pcall(CSM.projectWazaWorld,CSM,ctx,p);if ok then return x,y end
end
local function effectProgress(rec)
  local inst=rec and rec.instance
  local frame=(tonumber(inst and inst.frame) or 0)+(tonumber(inst and inst.accumulator) or 0)*60-(tonumber(rec and rec.startedFrame) or 0)
  return math.max(0,math.min(1,frame/math.max(1,tonumber(rec and rec.duration) or 1))),frame
end
local function effectImage(rec)
  if rec.image==false then return nil end
  if rec.image then return rec.image end
  if type(rec.textureSpec)~="table" then rec.image=false;return nil end
  local img,err=imageFromRaw(rec.textureSpec)
  if not img then H.drawError=("Type-4 source texture load failed family=%s move=%s: %s")
    :format(tostring(rec.family),tostring(rec.instance and rec.instance.moveId),tostring(err));rec.image=false;return nil end
  rec.image=img;return img
end
local function keyedColor(keys,p,default)
  -- Aura/blur keys are scalar energy, not RGBA. Do not index a scalar as a
  -- colour: this used to abort the complete world pass for e.g. Mega Punch.
  if type(default)~="table" then default={255,255,255,255} end
  if type(keys)=="table" and type(keys[1])=="table"
      and type(keys[1].from)~="table" and type(keys[1].to)~="table" then return default end
  if type(keys)~="table" or #keys==0 then return default end
  local total=0
  for _,k in ipairs(keys) do local d=tonumber(k.duration) or 0;if d>0 and d<100000 then total=total+d end end
  if total<=0 then return keys[#keys].to or keys[1].from or default end
  local at=p*total;local elapsed=0
  for _,k in ipairs(keys) do
    local d=tonumber(k.duration) or 0
    if d>0 and d<100000 then
      if at<=elapsed+d then
        local t=math.max(0,math.min(1,(at-elapsed)/d));local a=type(k.from)=="table" and k.from or default;local b=type(k.to)=="table" and k.to or a
        return {lerp(a[1],b[1],t),lerp(a[2],b[2],t),lerp(a[3],b[3],t),lerp(a[4],b[4],t)}
      end
      elapsed=elapsed+d
    end
  end
  return keys[#keys].to or default
end
local function sourceSurfaceColor(e,p)
  -- GC6E01 fn_80137780 normalizes unused channels before interpolation.
  -- Mode 0 is the full-screen filter and always animates RGBA. Modes 1/2
  -- normally animate RGB only; descriptor flag 4 disables RGB and flag 1
  -- enables alpha. Neutral GS material modulation is 128,128,128,255.
  e=type(e)=="table" and e or {}
  local c=keyedColor(e.keys,p,{128,128,128,255})
  local mode=tonumber(e.mode) or 0
  local layout=tonumber(e.layoutMode) or 0
  local flags=tonumber(e.flags) or 0
  local useRgb,useAlpha=true,false
  if layout~=1 and layout~=2 then
    if math.floor(flags/4)%2==1 then useRgb=false end
    if flags%2==1 then useAlpha=true end
  end
  if mode==0 then useRgb,useAlpha=true,true end
  return {
    useRgb and (tonumber(c[1]) or 128) or 127,
    useRgb and (tonumber(c[2]) or 128) or 127,
    useRgb and (tonumber(c[3]) or 128) or 127,
    useAlpha and (tonumber(c[4]) or 255) or 255,
  }
end

-- Type-4 family 0, mode 1 is not a ring/wave primitive. Retail
-- _wazaSequenceEffectEntryStart gathers the current floor archive's model list
-- and applies animated GS material modulation to those source models. Arena
-- asks for that live colour before drawing its HSD groups; Pokemon/trainers/UI
-- therefore do not inherit the battlefield-only operation.
function H.arenaModulation()
  local best
  for _,rec in pairs(H.effects) do
    local e=rec.effect or {}
    if tonumber(rec.family)==0 and tonumber(e.mode)==1 then
      if not best or (tonumber(rec.startedFrame) or 0)>(tonumber(best.startedFrame) or 0) then best=rec end
    end
  end
  if not best then return nil end
  local p=effectProgress(best)
  local c=sourceSurfaceColor(best.effect,p)
  return {c[1]/255,c[2]/255,c[3]/255,c[4]/255},best
end
local function keyedScalar(e,p,default)
  local keys=e and e.keys
  if type(keys)~="table" or #keys==0 then return tonumber(e and e.value) or default end
  local total=0;for _,k in ipairs(keys) do local d=tonumber(k.duration) or 0;if d>0 and d<100000 then total=total+d end end
  if total<=0 then return tonumber(keys[#keys].to) or tonumber(keys[1].from) or default end
  local at=p*total;local elapsed=0
  for _,k in ipairs(keys) do local d=tonumber(k.duration) or 0;if d>0 and d<100000 then
    if at<=elapsed+d then return lerp(k.from,k.to,math.max(0,math.min(1,(at-elapsed)/d))) end;elapsed=elapsed+d end end
  return tonumber(keys[#keys].to) or default
end
local function angle2(y,x)
  if type(math.atan2)=="function" then return math.atan2(y,x) end
  -- Lua 5.3+ accepts atan(y,x); the manual quadrant fallback keeps this safe
  -- on stripped Lua/LuaJIT hosts that expose only one-argument atan.
  local ok,v=pcall(math.atan,y,x);if ok and type(v)=="number" then return v end
  if x>0 then return math.atan(y/x) end
  if x<0 then return math.atan(y/x)+(y>=0 and math.pi or -math.pi) end
  return y>0 and math.pi*.5 or (y<0 and -math.pi*.5 or 0)
end
local function drawTexturedSegment(g,img,x1,y1,x2,y2,width)
  if not (img and x1 and y1 and x2 and y2) then return false end
  local dx,dy=x2-x1,y2-y1;local len=math.sqrt(dx*dx+dy*dy);if len<.25 then return false end
  local iw,ih=math.max(1,img:getWidth()),math.max(1,img:getHeight())
  g.draw(img,(x1+x2)*.5,(y1+y2)*.5,angle2(dy,dx),len/iw,math.max(.5,tonumber(width) or ih)/ih,iw*.5,ih*.5)
  return true
end
local function drawTraceRibbon(g,img,rec,e,p)
  local bA=sourceBasis(rec.context or {},rec,e.partA or (rec.entry and rec.entry.attachment))
  local bB=sourceBasis(rec.context or {},rec,e.partB or (rec.entry and rec.entry.attachment))
  if not (bA and bB and bA.origin and bB.origin) then return false end
  local ax,ay=projectSource(rec.context or {},bA.origin);local bx,by=projectSource(rec.context or {},bB.origin)
  if not (ax and bx) then return false end
  local frame=math.floor((tonumber(rec.instance and rec.instance.frame) or 0)+.5)
  if rec.historyFrame~=frame then
    rec.historyFrame=frame;rec.history[#rec.history+1]={ax=ax,ay=ay,bx=bx,by=by}
    local maxn=math.max(2,math.min(128,tonumber(e.maxSegments) or 24));while #rec.history>maxn do table.remove(rec.history,1) end
  end
  if #rec.history<2 then return false end
  local live=math.max(2,math.min(#rec.history,tonumber(e.liveSegments) or #rec.history))
  local first=#rec.history-live+1;local verts={}
  for i=first,#rec.history do
    local h=rec.history[i];local v=(i-first)/math.max(1,live-1);local fade=.18+.82*v
    verts[#verts+1]={h.ax,h.ay,0,v,1,1,1,fade}
    verts[#verts+1]={h.bx,h.by,1,v,1,1,1,fade}
  end
  local fmt={{"VertexPosition","float",2},{"VertexTexCoord","float",2},{"VertexColor","float",4}}
  rec.dynamicMeshes=rec.dynamicMeshes or {}
  local mesh=rec.dynamicMeshes.trace;local capacity=rec.traceCapacity or 0
  if not mesh or #verts>capacity then
    if mesh and mesh.release then pcall(mesh.release,mesh) end
    capacity=math.min(256,math.max(8,capacity*2,#verts))
    local ok,built=pcall(g.newMesh,fmt,capacity,"strip","stream")
    if not ok or not built then rec.dynamicMeshes.trace=nil;rec.traceCapacity=nil;return false end
    mesh=built;rec.dynamicMeshes.trace=mesh;rec.traceCapacity=capacity
  end
  local ok=pcall(mesh.setVertices,mesh,verts)
  if not ok then return false end
  if mesh.setDrawRange then mesh:setDrawRange(1,#verts) end
  if img then pcall(mesh.setTexture,mesh,img) end
  return pcall(g.draw,mesh)
end

local COLOR_MESH_FORMAT={{"VertexPosition","float",2},{"VertexColor","float",4}}
local function drawDynamicColorMesh(g,rec,slot,verts)
  rec.dynamicMeshes=rec.dynamicMeshes or {};local mesh=rec.dynamicMeshes[slot]
  if mesh and mesh.setVertices then
    local ok=pcall(mesh.setVertices,mesh,verts)
    if not ok then if mesh.release then pcall(mesh.release,mesh) end;mesh=nil;rec.dynamicMeshes[slot]=nil end
  end
  if not mesh then
    local ok,built=pcall(g.newMesh,COLOR_MESH_FORMAT,verts,"triangles","stream");if not ok or not built then return false end
    mesh=built;rec.dynamicMeshes[slot]=mesh
  end
  return pcall(g.draw,mesh)
end
local function drawAuraField(g,rec,cx,cy,rx,ry,alpha)
  local verts={};local segments=56
  for i=0,segments-1 do
    local a0=i/segments*math.pi*2;local a1=(i+1)/segments*math.pi*2
    verts[#verts+1]={cx,cy,1,1,1,alpha}
    verts[#verts+1]={cx+math.cos(a0)*rx,cy+math.sin(a0)*ry,1,1,1,0}
    verts[#verts+1]={cx+math.cos(a1)*rx,cy+math.sin(a1)*ry,1,1,1,0}
  end
  return drawDynamicColorMesh(g,rec,"aura",verts)
end

-- World-space implementation of the thirteen retail Type-4 effect families.
-- Full-screen families (filter/blur/distortion) are applied later in drawPost
-- so they can operate on the completed arena framebuffer instead of faking a
-- target-space ring.
local function drawProceduralEffects(ctx)
  if not (love and love.graphics) then return false end
  local g=love.graphics;local drew=false
  for _,rec in pairs(H.effects) do
    local fam=tonumber(rec.family) or -1;local e=rec.effect or {};local inst=rec.instance;rec.context=ctx
    if fam~=2 and fam~=8 and fam~=10 and not (rec.entry and rec.entry.effectModelAsset) then
      local b=sourceBasis(ctx,rec);local p=effectProgress(rec)
      if b and b.origin and b.target then
        local x1,y1=projectSource(ctx,b.origin);local x2,y2=projectSource(ctx,b.target)
        if x1 and x2 then
          local c=keyedColor(e.keys,p,e.color or e.colorA or {255,255,255,255})
          local r,gc,bb,a=effectRGBA(c,1-p*.12)
          g.push("all");g.setColor(r,gc,bb,a)
          if fam==0 then
            -- Family 0 is GS model/filter modulation. Mode 1 is consumed by
            -- Arena through H.arenaModulation; mode 0 is a framebuffer filter
            -- and mode 2 is owner-model modulation. None is a world-space ring.
          elseif fam==1 then
            -- electronStartEffect: branch chains use the actual serialized GS
            -- texture and authored count/depth. Descriptor vectors remain in
            -- Pokemon-local source units and are transformed by wazaLocalPoint.
            local img=effectImage(rec)
            local ws=sourceLocalPoint(ctx,rec,e.start);local we=sourceLocalPoint(ctx,rec,e.endv)
            local sx,sy,ex,ey;if ws then sx,sy=projectSource(ctx,ws) end;if we then ex,ey=projectSource(ctx,we) end
            sx,sy=sx or x1,sy or y1;ex,ey=ex or x2,ey or y2
            local count=math.max(1,math.min(16,tonumber(e.partA) or 3));local depth=math.max(1,math.min(5,tonumber(e.partB) or 2))
            if img then
              pcall(g.setBlendMode,"add","alphamultiply")
              for branch=1,count do
                local dx,dy=ex-sx,ey-sy;local len=math.max(1,math.sqrt(dx*dx+dy*dy));local nx,ny=-dy/len,dx/len
                local pieces=math.max(3,depth*3)
                for j=1,pieces do
                  local t0=(j-1)/pieces;local t1=j/pieces
                  local amp=len*(.018+.009*depth)*(1-p*.25)
                  local j0=(j==1) and 0 or math.sin((branch*37+j*19+(inst.serial or 0)*11)*1.731)*amp
                  local j1=(j==pieces) and 0 or math.sin((branch*37+(j+1)*19+(inst.serial or 0)*11)*1.731)*amp
                  local ax=sx+dx*t0+nx*j0;local ay=sy+dy*t0+ny*j0;local bx=sx+dx*t1+nx*j1;local by=sy+dy*t1+ny*j1
                  drew=drawTexturedSegment(g,img,ax,ay,bx,by,math.max(2,math.abs(tonumber(e.width) or 3))) or drew
                end
              end
            end
          elseif fam==3 then
            -- lightningStartEffect: textured source bolt with authored endpoint
            -- vectors and colour ramp, distinct from the electron branch system.
            local img=effectImage(rec);local ws=sourceLocalPoint(ctx,rec,e.start);local we=sourceLocalPoint(ctx,rec,e.endv)
            local sx,sy,ex,ey;if ws then sx,sy=projectSource(ctx,ws) end;if we then ex,ey=projectSource(ctx,we) end;sx,sy=sx or x1,sy or y1;ex,ey=ex or x2,ey or y2
            if img then
              pcall(g.setBlendMode,"add","alphamultiply");local dx,dy=ex-sx,ey-sy;local len=math.max(1,math.sqrt(dx*dx+dy*dy));local nx,ny=-dy/len,dx/len
              local pieces=math.max(5,math.min(24,tonumber(e.mode) or 10));local lastx,lasty=sx,sy
              for j=1,pieces do local t=j/pieces;local amp=len*.035*(1-.35*p);local jitter=(j==pieces) and 0 or math.sin((j*29+(inst.serial or 0)*13)*2.07)*amp
                local nxp=sx+dx*t+nx*jitter;local nyp=sy+dy*t+ny*jitter;drew=drawTexturedSegment(g,img,lastx,lasty,nxp,nyp,math.max(3,math.abs(tonumber(e.values and e.values[1]) or 4))) or drew;lastx,lasty=nxp,nyp end
            end
          elseif fam==4 then
            local img=effectImage(rec);if img then pcall(g.setBlendMode,"alpha","alphamultiply");drew=drawTraceRibbon(g,img,rec,e,p) or drew end
          elseif fam==9 then
            -- auraEffectStart: additive owner-centred glow. Scalar keyframes
            -- drive radius/energy rather than a fabricated attack projectile.
            pcall(g.setBlendMode,"add","alphamultiply");local v=math.abs(keyedScalar(e,p,1));local rad=math.max(10,math.min(180,22+v*18))*(.72+.28*math.sin(math.pi*p))
            g.setColor(r,gc,bb,1);drew=drawAuraField(g,rec,x1,y1,rad,rad*1.28,a*.34) or drew
          elseif fam==12 then
            -- billboardEffectStart: exact source GS texture, screen-facing by
            -- definition. Source scalars control sprite scale/rotation.
            local img=effectImage(rec);if img then
              pcall(g.setBlendMode,"alpha","alphamultiply")
              local scale=math.max(.08,math.min(8,math.abs(tonumber(e.a) or 1)*(0.7+0.3*math.sin(math.pi*p))))
              g.draw(img,x2,y2,(tonumber(e.b) or 0)*p,scale,scale,img:getWidth()*.5,img:getHeight()*.5);drew=true
            end
          end
          g.pop()
        end
      end
    end
  end
  return drew
end

local DISTORT_SHADER=[[
extern number amount;
extern number frequency;
extern number phase;
vec4 effect(vec4 color, Image texture, vec2 uv, vec2 screen) {
  vec2 q=uv;
  q.x += sin((uv.y+phase)*frequency)*amount;
  q.y += sin((uv.x+phase*0.73)*frequency*0.81)*amount*0.55;
  return Texel(texture,q)*color;
}
]]
local function releasePost()
  for _,c in ipairs({H.postCanvas,H.postHistory}) do if c and c.release then pcall(c.release,c) end end
  H.postCanvas=nil;H.postHistory=nil;H.postW=0;H.postH=0;H.postHistoryValid=false
end
local function ensurePost(w,h)
  if H.postCanvas and H.postHistory and H.postW==w and H.postH==h then return true end
  releasePost()
  if not (love and love.graphics and love.graphics.newCanvas) then return false end
  local ok,a=pcall(love.graphics.newCanvas,w,h,{dpiscale=1,msaa=0});if not ok then ok,a=pcall(love.graphics.newCanvas,w,h) end
  if not ok or not a then return false end
  local ok2,b=pcall(love.graphics.newCanvas,w,h,{dpiscale=1,msaa=0});if not ok2 then ok2,b=pcall(love.graphics.newCanvas,w,h) end
  if not ok2 or not b then if a.release then pcall(a.release,a) end;return false end
  H.postCanvas,H.postHistory,H.postW,H.postH=a,b,w,h;H.postHistoryValid=false
  return true
end
local function ensureDistortShader()
  if H.distortShader then return H.distortShader end
  if not (love and love.graphics and love.graphics.newShader) then return nil end
  local ok,sh=pcall(love.graphics.newShader,DISTORT_SHADER);if ok then H.distortShader=sh;return sh end
  H.drawError=tostring(sh);return nil
end
local function activePostFamilies()
  local filter,blur,distort
  for _,rec in pairs(H.effects) do
    local fam=tonumber(rec.family)
    if fam==2 then filter=rec elseif fam==8 then blur=rec elseif fam==10 then distort=rec end
  end
  return filter,blur,distort
end

-- Post-process Type-4 source families after the complete arena/actor/trainer
-- frame exists. This is the correct integration point for Colosseum's filter,
-- motion-blur and distortion systems; drawing target-space stand-ins earlier
-- in the world pass would fundamentally change what those Waza entries mean.
function H.drawPost(ctx,sourceCanvas,w,h)
  local filter,blur,distort=activePostFamilies()
  if not (filter or blur or distort) then H.postHistoryValid=false;return false end
  local g=love and love.graphics;if not (g and sourceCanvas and w and h and ensurePost(w,h)) then return false end
  local ok,err=pcall(function()
    g.push("all");if g.origin then g.origin() end;if g.setScissor then g.setScissor() end;g.setShader();g.setDepthMode();g.setBlendMode("alpha","alphamultiply")

    -- Distortion is a real framebuffer sample/displace pass. The serialized
    -- descriptor's three float controls scale amplitude/frequency/phase.
    if distort then
      g.setCanvas(H.postCanvas);g.clear(0,0,0,0);g.setColor(1,1,1,1);g.draw(sourceCanvas,0,0)
      g.setCanvas(sourceCanvas);g.clear(0,0,0,0)
      local sh=ensureDistortShader();local p,frame=effectProgress(distort);local vals=distort.effect and distort.effect.values or {}
      if sh then
        g.setShader(sh)
        local amount=math.max(0.001,math.min(.045,math.abs(tonumber(vals[1]) or .9)*.006*(.45+.55*math.sin(math.pi*p))))
        local freq=math.max(8,math.min(90,math.abs(tonumber(vals[2]) or 3)*8+18))
        sh:send("amount",amount);sh:send("frequency",freq);sh:send("phase",(tonumber(frame) or 0)*.012+(tonumber(vals[3]) or 0)*.01)
      end
      g.setColor(1,1,1,1);g.draw(H.postCanvas,0,0);g.setShader()
    end

    -- Retail blur keeps framebuffer history. Reuse a persistent canvas across
    -- frames and composite it with source-keyframed energy instead of merely
    -- smearing particles inside the MoveFX layer.
    if blur then
      local p=effectProgress(blur);local strength=math.abs(keyedScalar(blur.effect or {},p,.5));strength=math.max(.04,math.min(.72,strength*.28))
      if H.postHistoryValid then
        g.setCanvas(sourceCanvas);g.setBlendMode("alpha","alphamultiply");g.setColor(1,1,1,strength)
        local drift=math.max(0,math.min(4,strength*4));g.draw(H.postHistory,-drift,0);g.draw(H.postHistory,drift,0)
      end
      g.setCanvas(H.postHistory);g.clear(0,0,0,0);g.setBlendMode("alpha","alphamultiply");g.setColor(1,1,1,1);g.draw(sourceCanvas,0,0);H.postHistoryValid=true
      g.setCanvas(sourceCanvas)
    else H.postHistoryValid=false end

    if filter then
      g.setCanvas(sourceCanvas);g.setShader();g.setBlendMode("alpha","alphamultiply")
      local p=effectProgress(filter);local e=filter.effect or {};local c=e.color or {255,255,255,255};local r,gg,b,a=effectRGBA(c,1)
      local energy=math.sin(math.pi*p);local scale=math.abs(tonumber(e.a) or tonumber(e.c) or 1);local alpha=math.max(0,math.min(.92,a*energy*math.max(.12,math.min(1,scale))))
      g.setColor(r,gg,b,alpha);g.rectangle("fill",0,0,w,h)
    end
    g.setColor(1,1,1,1);g.setShader();g.setCanvas(sourceCanvas);g.pop()
  end)
  if not ok then H.postErrors=(tonumber(H.postErrors) or 0)+1;H.drawError="Type-4 postprocess: "..tostring(err);pcall(g.setCanvas,sourceCanvas);pcall(g.setShader);return false end
  return true
end

local function shiftedBasis(base,x,y,z,scale,yaw)
  local b={};for k,v in pairs(base or {}) do b[k]=v end
  local u=type(base.sourceUnits)=="table" and base.sourceUnits or {x=1,y=1,z=1}
  local ux=tonumber(u.x) or tonumber(u[1]) or 1;local uy=tonumber(u.y) or tonumber(u[2]) or 1;local uz=tonumber(u.z) or tonumber(u[3]) or 1
  local r,up,f=base.right or {1,0,0},base.up or {0,1,0},base.forward or {0,0,1};local o=base.origin or {0,0,0}
  local angle=tonumber(yaw) or 0
  if angle~=0 then
    local ca,sa=math.cos(angle),math.sin(angle)
    local oldR,oldF=r,f
    r={oldR[1]*ca+oldF[1]*sa,oldR[2]*ca+oldF[2]*sa,oldR[3]*ca+oldF[3]*sa}
    f={oldF[1]*ca-oldR[1]*sa,oldF[2]*ca-oldR[2]*sa,oldF[3]*ca-oldR[3]*sa}
    b.right=r;b.forward=f
  end
  local ox=(tonumber(x) or 0)*ux;local oy=(tonumber(y) or 0)*uy;local oz=(tonumber(z) or 0)*uz
  b.origin={o[1]+r[1]*ox+up[1]*oy+f[1]*oz,o[2]+r[2]*ox+up[2]*oy+f[2]*oz,o[3]+r[3]*ox+up[3]*oy+f[3]*oz}
  local t=base.target or o;b.target={t[1]+r[1]*ox+up[1]*oy+f[1]*oz,t[2]+r[2]*ox+up[2]*oy+f[2]*oz,t[3]+r[3]*ox+up[3]*oy+f[3]*oz}
  local sm=math.max(.04,math.min(8,tonumber(scale) or 1));b.modelTargetSpan=(tonumber(base.modelTargetSpan) or tonumber(base.referenceVisualHeight) or 16)*sm
  return b
end
local function stable01(serial,index,salt)
  local n=((tonumber(serial) or 1)*73856093+(tonumber(index) or 1)*19349663+(tonumber(salt) or 0)*83492791)%2147483647
  return n/2147483647
end

function H.drawWorld(ctx)
  if not (love and love.graphics and CSM and type(CSM.wazaBasis)=="function") then return false end
  local vp=ctx and ctx.services and (ctx.services.vp or ctx.services.stageVP)
  if type(vp)~="table" then return false end
  local g=love.graphics;local jobs={}
  for _,rec in pairs(H.models) do
    local inst,entry=rec.instance,rec.entry
    local originSide=(inst and inst.role=="damage") and inst.target or (inst and inst.side)
    local otherSide=originSide==(inst and inst.side) and (inst and inst.target) or (inst and inst.side)
    local er=rec.effectRec;local ee=er and er.effect or nil;local family=tonumber(er and er.family)
    local attachment=entry and entry.attachment
    if ee and (family==5 or family==7 or family==11) then attachment=ee.partA or attachment end
    local okBasis,basis=pcall(CSM.wazaBasis,CSM,ctx,originSide,otherSide,attachment,{
      moveId=inst and (tonumber(inst.moveId) or (inst.spec and inst.spec.moveId)),style=inst and inst.spec and inst.spec.style,role=inst and inst.role,
      sourceStrict=true,positionType=entry and entry.positionType,flags=entry and entry.flags,modelEntry=entry})
    local frac=(tonumber(inst and inst.accumulator) or 0)*60
    local localFrame=(tonumber(inst and inst.frame) or 0)+frac-(tonumber(rec.state and rec.state.startFrame) or tonumber(rec.startedFrame) or 0)
    local model,err,page
    if not rec.asset.transformOnly then model,err,page=loadModel(rec.asset,localFrame) end
    if okBasis and basis and model then
      if er and tonumber(er.family)==5 then
        -- leaffx: retail clones the embedded leaf model up to 32 times and
        -- drives each clone along a randomized Bezier path. Reconstruct that
        -- source behavior from the exact descriptor floats instead of drawing
        -- one stationary copy of the leaf asset.
        local e=er.effect or {};local vals=e.values or {};local p=effectProgress(er)
        local count=math.max(1,math.min(32,math.floor(tonumber(e.partA) or 1)))
        for li=1,count do
          local r1=stable01(inst and inst.serial,li,1);local r2=stable01(inst and inst.serial,li,2);local r3=stable01(inst and inst.serial,li,3)
          local scale=math.abs((tonumber(vals[1]) or 1)+(tonumber(vals[2]) or 0)*(r1*2-1));if scale<.05 then scale=1 end
          local h0=(tonumber(vals[3]) or 0)+(tonumber(vals[4]) or 0)*(r2*2-1)
          local radius=math.abs((tonumber(vals[5]) or .5)+(tonumber(vals[6]) or 0)*(r3*2-1))
          local speed=math.abs(tonumber(vals[7]) or .7)+.15
          local angle=r1*math.pi*2+(tonumber(inst and inst.frame) or 0)*.015*(.6+r2)
          local x=math.cos(angle)*radius+math.sin((p+r3)*math.pi*2)*radius*.28
          local z=math.sin(angle)*radius+math.cos((p+r2)*math.pi*2)*radius*.28
          local y=h0+(1-p)*radius*.45-p*speed
          jobs[#jobs+1]={rec=rec,basis=shiftedBasis(basis,x,y,z,scale,angle),model=model,page=page,
            localFrame=localFrame+(li-1)*.35,tint=keyedColor(e.keys,p,e.color)}
        end
      elseif er and tonumber(er.family)==6 then
        -- enviroEffectStart: keep the embedded HSD model and its environment
        -- texture generation, while applying the descriptor's local-space
        -- start/velocity/count/scalar controls in the live attacker basis.
        local e=er.effect or {};local vals=e.values or {};local p=effectProgress(er)
        local start=e.start or {0,0,0};local velocity=e.velocity or {0,0,0}
        local count=math.max(1,math.min(32,math.floor(tonumber(e.countA) or 1)))
        local spread=math.abs(tonumber(vals[2]) or 0);local baseScale=math.abs(tonumber(vals[1]) or 1)
        if baseScale<.02 or baseScale>16 then baseScale=1 end
        for mi=1,count do
          local lane=mi-(count+1)*.5;local phase=(mi-1)/math.max(1,count)
          local x=(tonumber(start[1]) or 0)+(tonumber(velocity[1]) or 0)*p+lane*spread
          local y=(tonumber(start[2]) or 0)+(tonumber(velocity[2]) or 0)*p
          local z=(tonumber(start[3]) or 0)+(tonumber(velocity[3]) or 0)*p
          jobs[#jobs+1]={rec=rec,basis=shiftedBasis(basis,x,y,z,baseScale,(p+phase)*math.pi*2),model=model,page=page,
            localFrame=localFrame+phase,tint=keyedColor(e.keys,p,e.color),environment=true}
        end
      elseif er and tonumber(er.family)==7 then
        -- seaEffectStart: the source wave model carries the authored shape and
        -- animation; descriptor vectors place and advect it in battle space.
        local e=er.effect or {};local p=effectProgress(er);local start=e.start or {0,0,0};local velocity=e.velocity or {0,0,0}
        local scale=math.abs(tonumber(e.a) or 1);if scale<.02 or scale>16 then scale=1 end
        local wave=math.sin(p*math.pi*2)*math.max(-8,math.min(8,tonumber(e.b) or 0))
        local x=(tonumber(start[1]) or 0)+(tonumber(velocity[1]) or 0)*p
        local y=(tonumber(start[2]) or 0)+(tonumber(velocity[2]) or 0)*p+wave
        local z=(tonumber(start[3]) or 0)+(tonumber(velocity[3]) or 0)*p
        jobs[#jobs+1]={rec=rec,basis=shiftedBasis(basis,x,y,z,scale),model=model,page=page,localFrame=localFrame,
          tint=keyedColor(e.keys,p,e.color)}
      elseif er and tonumber(er.family)==11 then
        -- patchiruEffectStart is an attachment/model family. partA selects the
        -- source anchor above; partB/mode control facing without replacing the
        -- embedded source model with a generated sprite.
        local e=er.effect or {};local p=effectProgress(er)
        local turns=(tonumber(e.mode) or 0)~=0 and p*(tonumber(e.partB) or 1) or 0
        jobs[#jobs+1]={rec=rec,basis=shiftedBasis(basis,0,0,0,1,turns*math.pi*2),model=model,page=page,
          localFrame=localFrame,tint=keyedColor(e.keys,p,e.color)}
      else jobs[#jobs+1]={rec=rec,basis=basis,model=model,page=page,localFrame=localFrame,
        tint=er and keyedColor((er.effect or {}).keys,effectProgress(er),(er.effect or {}).color) or nil} end
    elseif err then H.drawError=tostring(err) end
  end
  local proceduralDrew=drawProceduralEffects(ctx)
  if #jobs==0 then return proceduralDrew end
  local drew=proceduralDrew
  local ok,value,scopeErr=graphicsScope(g,function()
    local function pass(kind)
      if kind=="add" then pcall(g.setBlendMode,"add","alphamultiply")
      else pcall(g.setBlendMode,"alpha","alphamultiply") end
      for _,job in ipairs(jobs) do
        local sh,serr=ensureShader(job.model.morph)
        if sh then
          local okJob,jobErr=pcall(function()
            g.setShader(sh);sh:send("vp","row",vp);sh:send("model","row",modelMatrix(job.basis,job.model,job.rec and job.rec.asset))
            if job.model.morph then
              local weights=morphWeights(job.page,job.localFrame)
              for wi=0,12 do sh:send("w"..wi,weights[wi+1] or 0) end
            end
            for gi,grp in ipairs(job.model.groups) do
              if not grp._cbeRenderDisabled then
                local class=grp.luminous and "add" or (grp.xlu and "alpha" or "solid")
                if class==kind then
                  local okGrp,grpErr=pcall(function()
                    local d=grp.diffuse or {1,1,1};local tr,tg,tb,ta=effectRGBA(job.tint,1)
                    if not job.tint then tr,tg,tb,ta=1,1,1,1 end
                    sh:send("materialColor",{tonumber(d[1]) or 1,tonumber(d[2]) or 1,tonumber(d[3]) or 1,(tonumber(grp.alpha) or 1)*ta})
                    sh:send("effectTint",{tr,tg,tb})
                    sh:send("useTexture",grp.image and 1 or 0);sh:send("opacity",1);sh:send("forceOpaque",0)
                    local uv=textureAnimationSample(job.model,gi,job.localFrame)
                    sh:send("uvRow0",{uv[1],uv[2],uv[3]});sh:send("uvRow1",{uv[4],uv[5],uv[6]})
                    sh:send("envMode",job.environment and 1 or 0)
                    sh:send("unlit",(grp.luminous or grp.effect or grp.useConstant or not grp.useDiffuseLighting) and 1 or 0)
                    g.setDepthMode("lequal",class=="solid" and not grp.noz)
                    g.setColor(1,1,1,1);g.draw(grp.mesh);drew=true
                  end)
                  if not okGrp then modelRenderFault(job.rec,grp,grpErr);pcall(g.setShader,sh) end
                end
              end
            end
          end)
          if not okJob then modelRenderFault(job.rec,nil,jobErr);pcall(g.setShader) end
        else H.drawError=tostring(serr) end
      end
    end
    pass("solid");pass("alpha");pass("add")
    return drew
  end)
  if not ok then modelRenderFault(jobs[1] and jobs[1].rec,nil,scopeErr);return false end
  if value and not H.drawError then H.drawError=nil end
  return value==true
end

-- Draw one compiled GC6E01 type-2 source asset at an explicit world transform.
-- Capture uses this seam for the real Poké Ball model/texture/animation from
-- snatch_* WZX banks instead of rebuilding a lookalike sphere in PlayerTrainer.
function H.drawAsset(ctx,asset,vp,worldModel,localFrame,opts)
  opts=type(opts)=="table" and opts or {}
  if not (type(asset)=="table" and asset.cache and type(vp)=="table" and type(worldModel)=="table") then return false,"invalid source asset draw" end
  local model,err,page=loadModel(asset,localFrame)
  if not model then return false,err end
  local g=love and love.graphics;if not g then return false,"LÖVE graphics unavailable" end
  local opacity=math.max(0,math.min(1,tonumber(opts.opacity) or 1))
  local drew=false
  local ok,value,scopeErr=graphicsScope(g,function()
    local sh,serr=ensureShader(model.morph);if not sh then error(serr or "source model shader unavailable") end
    if opts.cullMode and g.setMeshCullMode then pcall(g.setMeshCullMode,opts.cullMode) end
    g.setShader(sh);sh:send("vp","row",vp);sh:send("model","row",worldModel)
    sh:send("effectTint",{1,1,1})
    if model.morph then
      local weights=morphWeights(page,localFrame)
      for wi=0,12 do sh:send("w"..wi,weights[wi+1] or 0) end
    end
    local function pass(kind)
      if kind=="add" then pcall(g.setBlendMode,"add","alphamultiply") else pcall(g.setBlendMode,"alpha","alphamultiply") end
      for gi,grp in ipairs(model.groups or {}) do
        if not grp._cbeRenderDisabled then
          local class=opts.forceOpaque and "solid" or (grp.luminous and "add" or (grp.xlu and "alpha" or "solid"))
          if class==kind then
            local d=grp.diffuse or {1,1,1}
            local materialAlpha=opts.forceOpaque and 1 or (tonumber(grp.alpha) or 1)
            sh:send("materialColor",{tonumber(d[1]) or 1,tonumber(d[2]) or 1,tonumber(d[3]) or 1,materialAlpha})
            sh:send("useTexture",grp.image and 1 or 0);sh:send("opacity",opts.forceOpaque and 1 or opacity);sh:send("forceOpaque",opts.forceOpaque and 1 or 0)
            local uv=textureAnimationSample(model,gi,localFrame)
            sh:send("uvRow0",{uv[1],uv[2],uv[3]});sh:send("uvRow1",{uv[4],uv[5],uv[6]})
            sh:send("envMode",0)
            local forcedUnlit=opts.unlit
            sh:send("unlit",forcedUnlit~=nil and (forcedUnlit and 1 or 0) or ((grp.luminous or grp.effect or grp.useConstant or not grp.useDiffuseLighting) and 1 or 0))
            if opts.depthAlways then
              g.setDepthMode("always",false)
            else
              -- Closed solid props (capture balls in particular) must write
              -- depth so their back shell cannot draw through the front shell.
              local writeDepth=(opts.forceOpaque==true) or (class=="solid" and not grp.noz)
              g.setDepthMode("lequal",writeDepth)
            end
            g.setColor(1,1,1,1);g.draw(grp.mesh);drew=true
          end
        end
      end
    end
    pass("solid");pass("alpha");pass("add")
    return drew
  end)
  if not ok then return false,scopeErr end
  return value==true,nil,model.bounds
end

function H.prewarm()
  -- Compile the two tiny HSD effect shaders during the normal game-ready
  -- frame rather than on the first Type-2 Waza draw.  Model/texture caches
  -- remain lazy; this moves only shader compilation off battle-critical frames.
  local okStatic,staticErr=ensureShader(false)
  local okMorph,morphErr=ensureShader(true)
  if not okStatic and staticErr then H.drawError=tostring(staticErr) end
  if not okMorph and morphErr then H.drawError=tostring(morphErr) end
  return okStatic~=nil or okMorph~=nil
end

-- Camera direction now follows the SAME live WazaSequence and source fight
-- geometry that position GPT1 particles and Type-2 HSD models. This is not a
-- fabricated per-move camera table: source timing, attachment selection,
-- attacker/target axis and actor-normalized scale all come from the decoded
-- Colosseum bank. A retail fight_common CObj probe gives a ~39.09 degree normal
-- battle lens, used here as the neutral source lens until the remaining camera
-- controller subtype is fully decoded.
local SOURCE_CAMERA_FOV=math.rad(39.09)
local function cadd(a,b,s)return {(a[1] or 0)+(b[1] or 0)*(s or 1),(a[2] or 0)+(b[2] or 0)*(s or 1),(a[3] or 0)+(b[3] or 0)*(s or 1)} end
local function clerp(a,b,t)return {(a[1] or 0)+((b[1] or 0)-(a[1] or 0))*t,(a[2] or 0)+((b[2] or 0)-(a[2] or 0))*t,(a[3] or 0)+((b[3] or 0)-(a[3] or 0))*t} end
local function cdist(a,b)local x=(b[1] or 0)-(a[1] or 0);local y=(b[2] or 0)-(a[2] or 0);local z=(b[3] or 0)-(a[3] or 0);return math.sqrt(x*x+y*y+z*z) end
local cameraContinuity={session=nil,currentSerial=nil,transitionFrom=nil,transitionStartFrame=0,lastPose=nil,actionKey=nil,axisSign=nil,
  motionKey=nil,motionMode=nil,lastMotionMode=nil}
local function latestCameraInstance()
  local best
  for _,inst in ipairs(Waza and Waza.active or {}) do
    if type(inst)=="table" and not inst.done and type(inst.spec)=="table" then
      local owns=true
      if type(Waza.canOwn)=="function" then local ok,v=pcall(Waza.canOwn,Waza,inst.spec,inst.role);owns=ok and v==true end
      if owns and (not best or (tonumber(inst.serial) or 0)>(tonumber(best.serial) or 0)) then best=inst end
    end
  end
  return best
end
local function cameraAttachment(inst)
  local fallback
  for _,st in ipairs(inst and inst.entries or {}) do
    local e=st.entry
    if type(e)=="table" and (e.kind=="model" or e.kind=="particle") then
      fallback=fallback or e.attachment
      if st.started and not st.closed then return e.attachment end
    end
  end
  return fallback
end
local function hasCameraFlag(flags,mask)
  flags=math.max(0,math.floor(tonumber(flags) or 0));mask=math.max(1,math.floor(tonumber(mask) or 1))
  return math.floor(flags/mask)%2==1
end
local function cameraPhaseRole(phase)
  local name=tostring(phase and (phase.name or phase.phase) or "all"):lower()
  return (name=="status" or name:match("^damage")) and "damage" or "attack"
end
local function sourceCameraPhase(inst,role)
  local fallback
  for _,phase in ipairs(type(inst and inst.spec)=="table" and (inst.spec.wazaPhases or {}) or {}) do
    if cameraPhaseRole(phase)==role and (phase.sequenceFlags~=nil or phase.sequenceKind~=nil or phase.cameraActive~=nil) then
      if #(phase.entries or {})>0 then return phase end
      fallback=fallback or phase
    end
  end
  return fallback
end
local function sourceMotionOptions(flags,modelId)
  -- GC6E01 _wazaSequenceCameraSelectMotion: bit 0 hard-selects mode 5;
  -- bits 3/4/5/6 admit modes 3/0/1/2. With no bits retail admits all four,
  -- and when several are admitted it avoids the immediately previous mode.
  -- ModelSequence +0x70 == 0x13A is the one source-proven hard mode-4 case.
  if CameraParams and type(CameraParams.motionOptions)=="function" then
    return CameraParams.motionOptions(flags,modelId)
  end
  if hasCameraFlag(flags,0x1) then return {5},true end
  local out={}
  if hasCameraFlag(flags,0x08) then out[#out+1]=3 end
  if hasCameraFlag(flags,0x10) then out[#out+1]=0 end
  if hasCameraFlag(flags,0x20) then out[#out+1]=1 end
  if hasCameraFlag(flags,0x40) then out[#out+1]=2 end
  if #out==0 then out={3,0,1,2} end
  return out,#out==1
end
local function chooseSourceMotion(inst,phase,role,ownerDex)
  local flags=math.max(0,math.floor(tonumber(phase and phase.sequenceFlags) or 0))
  local key=table.concat({tostring(inst.presentationSerial or inst.serial or 0),role,tostring(flags),
    tostring(phase and phase.sequenceKind or ""),tostring(ownerDex or "")},":")
  if cameraContinuity.motionKey==key and cameraContinuity.motionMode~=nil then return cameraContinuity.motionMode end
  local options,forced
  if CameraParams and type(CameraParams.motionOptionsForPokemonDex)=="function" and ownerDex~=nil then
    options,forced=CameraParams.motionOptionsForPokemonDex(flags,ownerDex)
  else
    options,forced=sourceMotionOptions(flags,phase and phase.modelSequenceId)
  end
  local pool={}
  for _,mode in ipairs(options) do
    if forced or #options==1 or mode~=cameraContinuity.lastMotionMode then pool[#pool+1]=mode end
  end
  if #pool==0 then pool=options end
  -- Retail uses its shared battle RNG here. CBE deliberately does not pretend
  -- to own that RNG stream; choose deterministically *within the exact source
  -- allowed set* while preserving retail's non-repeat rule.
  local salt=(flags%65536)+(tonumber(phase and phase.sequenceKind) or 0)*31+(role=="damage" and 97 or 17)
  local r=stable01(inst.presentationSerial or inst.serial or 1,inst.serial or 1,salt)
  local idx=math.min(#pool,math.floor(r*#pool)+1);local mode=pool[idx]
  cameraContinuity.motionKey=key;cameraContinuity.motionMode=mode;cameraContinuity.lastMotionMode=mode
  return mode
end
local function sourceParamsFlags(flags,ownerPosition)
  -- battleCameraStartWaza converts raw Waza root flags into the camera-parameter
  -- mask before CalculateParams/DoFOV. The 0x00400000 branch is selected from
  -- GSmodelGetPosition(owner->model).z, so callers must pass the owner-root
  -- position -- never the attack/effect origin (which can belong to the other
  -- battler during a damage chapter).
  local out=0
  if hasCameraFlag(flags,0x00200000) then out=2
  elseif hasCameraFlag(flags,0x00000200) then out=4
  elseif hasCameraFlag(flags,0x00400000) then out=((ownerPosition and (ownerPosition[3] or 0)<0) and 4 or 8) end
  if hasCameraFlag(flags,0x00000400) then out=out+0x20
  elseif hasCameraFlag(flags,0x00000800) then out=out+0x40
  elseif hasCameraFlag(flags,0x00001000) then out=out+0x80 end
  return out
end
local function sourceDistanceBand(paramsFlags)
  -- Neutral ModelSequence-size baseline from retail CalculateParams after its
  -- clamps: 0x20 => 25..40, 0x40 => 35..50, 0x80 => 48..60, default => 20..60.
  -- The owner ModelSequence kind can scale these before clamping; that owner
  -- class is not currently exported by the live actor bridge, so do not claim
  -- these are the exact per-Pokemon samples.
  if hasCameraFlag(paramsFlags,0x20) then return 25,40 end
  if hasCameraFlag(paramsFlags,0x40) then return 35,50 end
  if hasCameraFlag(paramsFlags,0x80) then return 48,60 end
  return 20,60
end
local function sourceRotationBand(paramsFlags)
  local low=paramsFlags%0x20
  if hasCameraFlag(low,0x01) then return 0,math.rad(30) end
  if hasCameraFlag(low,0x02) then return math.rad(18),math.rad(36) end
  -- Bits 4/8 branch again on the owner's ModelSequence kind. The bridge does
  -- not expose that class, so use the exact UNION of both retail ranges rather
  -- than inventing an averaged narrower interval.
  if hasCameraFlag(low,0x04) then return math.rad(18),math.rad(54) end
  if hasCameraFlag(low,0x08) then return math.rad(36),math.rad(72) end
  if hasCameraFlag(low,0x10) then return math.rad(72),math.rad(90) end
  return math.rad(18),math.rad(63)
end
local function sourceCameraTargetSlot(phase)
  -- battleCameraStartWaza selects cameraParams +0x4C + sequence[0x17]*4.
  -- fn_801DC5F0 initializes sequence[0x17]=2, and only root mode 5 replaces it
  -- with root payload +0x0C (`variant` in WazaSequenceExtractor).  The PKX row
  -- stores the 16 BODY_KEYS beginning at +0x4C, so this value is directly the
  -- existing CurrentSpriteModels body-slot index; no cache revision is needed.
  local root=type(phase)=="table" and phase.root or nil
  if type(root)~="table" then return nil,false end
  local mode=tonumber(root.mode)
  if mode==nil then return nil,false end
  local slot=mode==5 and tonumber(root.variant) or 2
  if slot==nil or slot<0 or slot>=16 or slot~=math.floor(slot) then return nil,false end
  return slot,true
end
local function sourceCameraDecision(inst,role,src,ownerRootBasis,ownerSide)
  local phase=sourceCameraPhase(inst,role);if not phase then return nil end
  if phase.cameraActive==false then return {active=false,phase=phase} end
  local flags=math.max(0,math.floor(tonumber(phase.sequenceFlags) or 0))
  local embeddedSize=math.max(0,math.floor(tonumber(phase.root and phase.root.embeddedSize) or 0))
  -- battleCameraStartWaza checks sequence +0x18/+0x20 first and immediately
  -- returns after cameraPlayOffsetAnime when the embedded HSD camera resource is
  -- valid. The extractor now decodes supported HSD_CObj/WObj camera tracks into
  -- executable source-local samples. Mark the embedded branch either way so CBE
  -- never runs the mutually-exclusive procedural selector when the source camera
  -- exists; unsupported transforms retain the safe source-shaped fallback.
  if embeddedSize>0 then
    local camera=type(phase.sourceCamera)=="table" and phase.sourceCamera or nil
    local curveDecoded=camera and camera.complete==true and type(camera.samples)=="table" and #camera.samples>0
    -- Embedded flag-0x4 cameras stay in battle-grid space. GC6E01's exact
    -- normalisation constants and PKX ModelSequence selector source are now
    -- decoded; cameraPose resolves that branch against all active selectors.
    -- +0x4000 belongs only to the non-grid branch. The live actor bridge can now
    -- provide the exact frame-0 GSmodel bound midpoint for Pokemon owners; keep
    -- the flag here and resolve availability only after cameraPose fetches that
    -- exact owner-root basis.
    local battleSpace=hasCameraFlag(flags,0x4)
    local boundCentre=(not battleSpace) and hasCameraFlag(flags,0x00004000)
    -- GC6E01 has one additional non-grid owner-position adjustment that cannot
    -- be approximated from Pokemon visual height.  When sequence +0x2E == 2
    -- (the fight-side damage/target sequence), owner flag bit 2 is active and a
    -- synthetic root null is present, battleCameraStartWaza adds the CHILD root
    -- local translation Y returned by GSmodelGetRootPosition to offsetPosition.
    -- CBE currently tracks the Type-6 add/remove-root-null controller state, but
    -- not the exact mutable child translation.  Retail model-entry teardown can
    -- write a nonzero value here, and one reachable path depends on the still-
    -- unavailable source-equivalent GSmodel bounds.  Fail closed whenever this
    -- special branch can be active rather than substituting actor/visual height.
    local rootNullSpecial=false
    if not battleSpace and role=="damage" then
      local ownerState=H.controllers[tostring(controllerSide(inst) or "")]
      rootNullSpecial=ownerState and ownerState.rootNull==true or false
    end
    local gridNormalised=battleSpace and hasCameraFlag(flags,0x00800000)
    local gridYIdentity=gridNormalised and hasCameraFlag(flags,0x01000000)
    local gridFacingFlip=battleSpace and hasCameraFlag(flags,0x02000000)
    -- GC6E01's retail side data is now source-proven rather than inferred from
    -- screen placement.  fightTarget type 4 is the relative host side
    -- (fightTargetIsHostSide), active FightFloorData rows bind it to
    -- FightSideData 2 (yrot=1), and battleGridAddPokemon converts nonzero yrot
    -- to owner byte +0x76 == -1.  Type 5 binds FightSideData 1 (yrot=0), which
    -- becomes +1.  cameraPose can therefore execute the conditional PI yaw when
    -- the CBE owner side is known, instead of treating the whole flag as opaque.
    local transformSupported=not rootNullSpecial
    local transformUnsupported=rootNullSpecial and "owner-root-null-y-unavailable" or nil
    return {active=true,phase=phase,flags=flags,sequenceKind=tonumber(phase.sequenceKind),embedded=true,embeddedSize=embeddedSize,
      camera=camera,embeddedCurveDecoded=curveDecoded,embeddedDecoded=curveDecoded and transformSupported,
      battleSpace=battleSpace,gridNormalised=gridNormalised,gridYIdentity=gridYIdentity,gridFacingFlip=gridFacingFlip,
      boundCentre=boundCentre,rootNullSpecial=rootNullSpecial,embeddedTransformUnsupported=transformUnsupported}
  end
  local ownerPosition=type(ownerRootBasis)=="table" and ownerRootBasis.origin or src
  local paramsFlags=sourceParamsFlags(flags,ownerPosition)
  local retailParams
  if CameraParams and type(CameraParams.calculate)=="function" and type(ownerRootBasis)=="table" then
    retailParams=CameraParams.calculate(paramsFlags,ownerRootBasis.sourceScaleSelector,
      ownerRootBasis.ownerRetailWazaBound,ownerRootBasis.ownerModelYaw)
  end
  local near,far
  if retailParams and retailParams.exact then near,far=retailParams.distanceMin,retailParams.distanceMax
  else near,far=sourceDistanceBand(paramsFlags) end
  local motion=chooseSourceMotion(inst,phase,role,ownerRootBasis and ownerRootBasis.ownerDex)
  local serial=tonumber(inst.presentationSerial or inst.serial) or 1
  local targetSlot,targetSlotExact=sourceCameraTargetSlot(phase)
  -- Exact scalar geometry is now shared with the decoded GC6E01 DoPosition
  -- formulas. Random draws remain CBE-local (the host does not expose the
  -- retail HSD_Randf stream), but the angle/distance/height bands, mode-1
  -- lateral start, mode-0 ordering gate and fixed mode-4/5 angles are no longer
  -- hand-tuned approximations whenever the exact owner bound/selector exists.
  local motionSample
  if retailParams and retailParams.exact and CameraParams and type(CameraParams.sampleMotion)=="function" then
    local salts={
      ["dolly-alternate"]=131,["dolly-distance-a"]=149,["dolly-distance-b"]=167,
      ["mode1-lateral"]=181,["distance"]=193,["height"]=197,
      ["rotation-a"]=211,["rotation-b"]=229,
    }
    local ownerFacing=ownerSide=="player" and -1 or (ownerSide=="enemy" and 1 or nil)
    local ownerReverse=ownerFacing and ownerFacing<0 and not hasCameraFlag(flags,0x80) or false
    motionSample=CameraParams.sampleMotion(motion,retailParams,function(key)
      return stable01(serial,inst.serial or 1,(salts[key] or 251)+(flags%997))
    end,{rotationBase=ownerRootBasis.ownerModelYaw,reverse=ownerFacing~=nil and ownerReverse or nil})
  end
  local r0=stable01(serial,inst.serial or 1,flags%10007+11)
  local r1=stable01(serial,inst.serial or 1,flags%10009+37)
  local distance0=motionSample and motionSample.distance0 or (near+(far-near)*r0)
  local distance1=motionSample and motionSample.distance1 or (near+(far-near)*r1)
  if not motionSample then
    if motion==1 then
      distance0=20+30*r0;distance1=distance0
    elseif motion==4 and CameraParams and type(CameraParams.mode4)=="function" then
      local m4=CameraParams.mode4();distance0=m4.distance;distance1=m4.distance
    elseif motion==5 then
      local selector=retailParams and retailParams.selector
      local exactDistance=CameraParams and type(CameraParams.mode5Distance)=="function" and selector~=nil
        and CameraParams.mode5Distance(selector) or nil
      distance0=exactDistance or 50;distance1=distance0
    end
  end
  local rot0,rot1
  if motionSample then
    rot0=motionSample.rotation0;rot1=motionSample.rotation1
  else
    local rotLo,rotHi
    if retailParams and retailParams.exact then rotLo,rotHi=retailParams.rotationMin,retailParams.rotationMax
    else rotLo,rotHi=sourceRotationBand(paramsFlags) end
    rot0=rotLo+(rotHi-rotLo)*stable01(serial,inst.serial or 1,53)
    rot1=rotLo+(rotHi-rotLo)*stable01(serial,inst.serial or 1,71)
    if rot1<rot0 then rot0,rot1=rot1,rot0 end
  end
  local ownerFacing=ownerSide=="player" and -1 or (ownerSide=="enemy" and 1 or nil)
  local ownerReverse=ownerFacing and ownerFacing<0 and not hasCameraFlag(flags,0x80) or false
  return {active=true,phase=phase,flags=flags,sequenceKind=tonumber(phase.sequenceKind),motion=motion,paramsFlags=paramsFlags,
    retailParams=retailParams,paramsExact=retailParams and retailParams.exact==true or false,
    motionSample=motionSample,motionScalarExact=motionSample and motionSample.scalarFormulaExact==true or false,
    motionRngExact=motionSample and motionSample.rngExact==true or false,
    motionWorldRotationExact=motionSample and motionSample.worldRotationFormulaExact==true or false,
    targetSlot=targetSlot,targetSlotExact=targetSlotExact,ownerSide=ownerSide,ownerFacing=ownerFacing,ownerReverse=ownerReverse,
    distance0=distance0,distance1=distance1,rotation0=rot0,rotation1=rot1}
end
local function sourceFovEnvelope(decision,visualHeight,distance,rangeIndex)
  -- DoFOV derives a lens from the owner's live GSmodel bounds and camera range.
  -- Exact GSmodel frame-0 bounds now cross the actor bridge.  The range sample is
  -- still driven by CBE's deterministic non-retail draw stream, so this improves
  -- the source geometry without claiming retail sample/RNG parity.
  local params=decision and decision.retailParams
  rangeIndex=tonumber(rangeIndex) or 1
  local exactGeometry=params and params.exact==true
  local span
  if exactGeometry then
    local scaleMin,scaleMax=tonumber(params.scaleMin),tonumber(params.scaleMax)
    -- The second transition executes after the retail params cursor advances by
    -- four bytes. Relative to the original 0x34-byte buffer, its scaleMin read
    -- therefore lands on +0x08 (scaleMax) and its scaleMax read on +0x0C
    -- (rotationMin). This odd overlap is literal GC6E01 behavior, not a typo.
    if rangeIndex>=3 then scaleMin,scaleMax=scaleMax,tonumber(params.rotationMin) end
    if scaleMin==nil or scaleMax==nil then exactGeometry=false
    else span=math.max(.75*scaleMin,scaleMax) end
  end
  if not exactGeometry then span=math.max(1,tonumber(visualHeight) or 6) end
  local range=math.max(1,tonumber(distance) or 40)
  local low=math.deg(2*math.atan(.5*span/range));local high=math.deg(2*math.atan(2*span/range))
  low=math.max(15,math.min(85,low));high=math.max(15,math.min(85,high));if high<low then low,high=high,low end
  return low,high,exactGeometry
end
local function sourceCameraFov(decision,visualHeight,ranges,serial,frame,timing)
  -- _wazaSequenceCameraDoPosition writes three radii at params +0x28/+0x2C/+0x30.
  -- DoFOV consumes range0 for its initial lens, then advances the params pointer
  -- by four bytes per transition so segment 1 uses range1 and segment 2 range2.
  -- Preserve that tuple instead of collapsing it to one representative radius.
  local function rangeAt(index)
    if type(ranges)=="table" then
      if index==1 then return tonumber(ranges.near or ranges[1]) end
      if index==2 then return tonumber(ranges.mid or ranges.middle or ranges[2]) end
      return tonumber(ranges.far or ranges[3])
    end
    return tonumber(ranges)
  end
  local function envelope(index)
    return sourceFovEnvelope(decision,visualHeight,rangeAt(index),index)
  end
  local low,high,boundGeometryExact=envelope(1)
  local draw=0
  local function rand01()
    draw=draw+1
    return stable01(serial,draw,149+draw*37+(tonumber(decision.sequenceKind) or 0)*11)
  end
  local function randIndex(n)return math.floor(rand01()*math.max(1,n)) end
  local function choose(flags,rangeIndex)
    local eLow,eHigh,eExact=envelope(rangeIndex or 1)
    if eExact~=boundGeometryExact then boundGeometryExact=boundGeometryExact and eExact end
    local a,b
    if CameraFov and type(CameraFov.mixBand)=="function" then a,b=CameraFov.mixBand(flags)
    else
      if hasCameraFlag(flags,1) then a,b=0,.20
      elseif hasCameraFlag(flags,4) then a,b=.75,1
      else a,b=.35,.60 end
    end
    local mix=a+(b-a)*rand01()
    return eLow+(eHigh-eLow)*mix
  end

  local usesPattern=CameraFov and CameraFov.usesPattern and CameraFov.usesPattern(decision.motion)
  if not CameraFov then
    local flags=hasCameraFlag(decision.paramsFlags,0x20) and 1
      or (hasCameraFlag(decision.paramsFlags,0x80) and 4 or 2)
    local value=choose(flags,1)
    return math.rad(value),{patternExact=false,timingExact=false,boundsExact=false,boundsProxy=true,reason="pattern-module-unavailable"}
  end

  -- Modes 0/4/5 never use the retail pattern table. Their static FOV band is
  -- source-exact even when camera timing metadata is absent because no FOV
  -- transition is scheduled.
  if not usesPattern then
    local flags=CameraFov.staticChoice(decision.paramsFlags)
    local value=choose(flags,1)
    return math.rad(value),{patternExact=true,patternUsed=false,timingExact=true,
      boundsExact=false,boundsProxy=not boundGeometryExact,boundGeometryExact=boundGeometryExact,
      rangeFormulaExact=decision and decision.motionSample and decision.motionSample.fovRangeFormulaExact==true or false,
      rangeSampleExact=false,tableName="none",rowIndex=nil,frameShift=timing and timing.frameShift or nil}
  end

  local timingExact=type(timing)=="table" and timing.exact==true
    and tonumber(timing.rate)==60 and tonumber(timing.count) and type(timing.frames)=="table"
  if not timingExact then
    -- Table semantics are decoded, but without the exact active PKX owner row we
    -- cannot place its two transition keys. Stay inside the source lens envelope
    -- rather than inventing transition frames.
    local value=low+(high-low)*(.35+.40*rand01())
    return math.rad(value),{patternExact=false,patternUsed=true,timingExact=false,
      boundsExact=false,boundsProxy=true,reason="owner-camera-timing-unavailable"}
  end

  local plan=CameraFov.plan(decision.sequenceKind,decision.paramsFlags,decision.motion,timing,rand01,randIndex)
  local current=choose(plan.initialFlags,1)
  local keys={}
  for i,segment in ipairs(plan.segments or {}) do
    local ending=current
    if not segment.hold then ending=choose(segment.descriptor and segment.descriptor.flags or 0,i+1) end
    keys[i]={start=current,finish=ending,startFrame=segment.startFrame,endFrame=segment.endFrame}
    current=ending
  end
  local cameraClock=(tonumber(plan.frame0) or 0)+math.max(0,tonumber(frame) or 0)
  local value
  if #keys==0 then value=current
  else
    value=keys[#keys].finish
    for _,key in ipairs(keys) do
      if cameraClock<=key.startFrame then value=key.start;break end
      if cameraClock<=key.endFrame then
        local span=key.endFrame-key.startFrame
        local t=span>0 and (cameraClock-key.startFrame)/span or 1
        value=key.start+(key.finish-key.start)*math.max(0,math.min(1,t));break
      end
      value=key.finish
    end
  end
  return math.rad(value),{patternExact=true,patternUsed=true,timingExact=true,boundsExact=false,boundsProxy=not boundGeometryExact,
    boundGeometryExact=boundGeometryExact,
    rangeFormulaExact=decision and decision.motionSample and decision.motionSample.fovRangeFormulaExact==true or false,
    rangeSampleExact=false,
    tableName=plan.tableName,rowIndex=plan.rowIndex,selection=plan.selection,frameShift=plan.frameShift,
    cameraClock=cameraClock,frame0=plan.frame0,keyCount=#keys}
end
local function offsetEye(focus,forward,right,back,side,height)
  local eye=cadd(focus,forward,-back)
  eye=cadd(eye,right,side)
  eye[2]=(eye[2] or 0)+height
  return eye
end

-- Exact fn_801DABAC f32 return values. In particular selector 1 is the binary32
-- value encoded by retail 1.33329999f, not the visually rounded Lua decimal.
local RETAIL_CAMERA_OWNER_SCALES={0.5,0.75,1.0,1.333299994468689,2.0,3.25}
local RETAIL_CAMERA_SCALE_BY_SELECTOR={[-2]=0.5,[-1]=0.75,[0]=1.0,[1]=1.333299994468689,[2]=2.0,[3]=3.25}
-- GC6E01 battleGridGetNormalisedScale performs one single-precision multiply:
-- base selector {-2/-1=.875, 0=1, 1=1.3999999761581421,
-- 2=1.7999999523162842, 3=2.75} * lbl_8047DFA0=1.7105263471603394.
-- Store the resulting f32 values directly. Recomputing this in Lua double made
-- a decoded battle-grid HSD camera slightly different from the retail scale
-- while still labelling the source frame exact. Unknown selectors take retail's
-- default base 1.0 and therefore the selector-0 result.
local RETAIL_GRID_NORMALISED_BY_SELECTOR={
  [-2]=1.4967105388641357,[-1]=1.4967105388641357,[0]=1.7105263471603394,
  [1]=2.3947367668151855,[2]=3.0789473056793213,[3]=4.7039475440979,
}
local RETAIL_GRID_NORMALISED_DEFAULT=1.7105263471603394
local function embeddedCameraSample(camera,frame)
  local samples=type(camera)=="table" and camera.samples or nil
  if type(samples)~="table" or #samples==0 then return nil end
  local f=math.max(0,math.min(#samples-1,tonumber(frame) or 0))
  local i0=math.floor(f)+1;local i1=math.min(#samples,i0+1);local t=f-math.floor(f)
  local a,b=samples[i0],samples[i1]
  if not (a and a.eye and a.focus and b and b.eye and b.focus) then return nil end
  local function v3(x,y)return {lerp(x[1],y[1],t),lerp(x[2],y[2],t),lerp(x[3],y[3],t)}end
  return {eye=v3(a.eye,b.eye),focus=v3(a.focus,b.focus),fov=lerp(tonumber(a.fov) or 40,tonumber(b.fov) or tonumber(a.fov) or 40,t)}
end
local function embeddedOwnerScale(basis,figureScale)
  -- Retail fn_801DABAC uses one of six discrete ModelSequence owner classes.
  -- `sequenceLoad` copies the PKX resource header's +0x0C sequenceKind directly
  -- into this selector. New metadata exports that word, so prefer it exactly.
  -- Old pre-v5 caches retain the previous visual-height classifier only as an
  -- explicit compatibility fallback until their tiny PKX sidecar is refreshed.
  local selector=basis and tonumber(basis.sourceScaleSelector)
  if selector~=nil then
    local exact=RETAIL_CAMERA_SCALE_BY_SELECTOR[selector]
    -- Retail's switch defaults to 1.0 for any selector outside -2..3.
    return exact or 1.0,nil,selector,true
  end
  local stageHeight=math.max(.01,(tonumber(basis and basis.sourceVisualHeight) or 17.25)*math.max(.01,figureScale or .4))
  local relative=stageHeight/6.90
  local best,bestErr=1,math.huge
  for _,v in ipairs(RETAIL_CAMERA_OWNER_SCALES) do local e=math.abs(relative-v);if e<bestErr then best,bestErr=v,e end end
  return best,relative,nil,false
end
local function embeddedOwnerPoint(basis,p,figureScale,stageScale,ownerScale,reverse)
  local origin=basis.origin
  local yaw=tonumber(basis and basis.ownerModelYaw)
  if yaw==nil or basis.ownerModelRotationExact~=true then return nil end
  local ox,oy,oz=origin[1]*figureScale,origin[2]*figureScale,origin[3]*figureScale
  local q=(stageScale or .25)*(ownerScale or 1)
  local x,y,z=(p[1] or 0)*q,(p[2] or 0)*q,(p[3] or 0)*q
  -- Retail order remains scale -> GSmodel rotation -> post-rotation world-Z
  -- mirror -> owner position.  CBE's battle line is a rotated presentation of
  -- retail's +/-X grid: for owner yaw theta, Q=Ry(theta-pi/2). Conjugating the
  -- retail reverse through Q gives
  --   Q * Fz * Ry(pi/2) = Ry(theta) * Fx,
  -- so the EXACT CBE-coordinate operation is an X reflection in camera-local
  -- coordinates followed by the owner's base yaw. This is not an approximation
  -- or a reordering in retail space; it is the same transform after the proven
  -- retail-world -> CBE-world coordinate change.
  if reverse then x=-x end
  local cs,sn=math.cos(yaw),math.sin(yaw)
  local dx,dz=cs*x+sn*z,-sn*x+cs*z
  return {ox+dx,oy+y,oz+dz}
end
local function retailGridScale(ctx)
  local selectors=ctx and ctx.cbeRetailScaleSelectors
  local complete=ctx and ctx.cbeRetailScaleSelectorsComplete
  if selectors==nil and CSM and type(CSM.retailScaleSelectors)=="function" then
    local ok,a,b=pcall(CSM.retailScaleSelectors,CSM)
    if ok then selectors,complete=a,b end
  end
  if complete~=true or type(selectors)~="table" or #selectors==0 then return nil,nil,false end
  local maxSelector=nil
  for _,value in ipairs(selectors)do
    local selector=tonumber(value)
    if selector==nil then return nil,nil,false end
    if maxSelector==nil or selector>maxSelector then maxSelector=selector end
  end
  local scale=RETAIL_GRID_NORMALISED_BY_SELECTOR[maxSelector] or RETAIL_GRID_NORMALISED_DEFAULT
  return scale,maxSelector,true
end
local function retailWazaOwnerFacing(side)
  -- Exact GC6E01 common_rel.fdat / fight-target contract:
  --   target type 4 (host)  -> FightSideData 2 -> yrot 1 -> grid +0x76 = -1
  --   target type 5 (other) -> FightSideData 1 -> yrot 0 -> grid +0x76 = +1
  -- Every non-dummy retail FightFloorData row uses the pair (2,1). CBE's
  -- canonical `player` side is the locally controlled/host side and `enemy` is
  -- the other side.  Do not derive this sign from actor X/Z placement.
  if side=="player" then return -1 end
  if side=="enemy" then return 1 end
  return nil
end
local function retailEmbeddedReverse(side,flags)
  -- battleCameraStartWaza derives `reverse` from the *Waza owner*, before it
  -- dispatches either embedded-camera transform branch.  A negative owner only
  -- reverses when sequence flag 0x80 is clear. cameraPlayOffsetAnime then stores
  -- shift=4, and _cameraOffsetAnimeUpdate applies that as a post-rotation Z
  -- mirror (flags[2]&4), before offsetPosition is added.
  if hasCameraFlag(flags,0x80) then return false,retailWazaOwnerFacing(side) end
  local facing=retailWazaOwnerFacing(side)
  if facing==nil then return nil,nil end
  return facing<0,facing
end
local function embeddedBattlePoint(ctx,p,stageScale,sx,sy,sz)
  local x=(tonumber(p and p[1]) or 0)*(sx or 1)*(stageScale or .25)
  local y=(tonumber(p and p[2]) or 0)*(sy or 1)*(stageScale or .25)
  local z=(tonumber(p and p[3]) or 0)*(sz or 1)*(stageScale or .25)
  local yaw=tonumber(ctx and ctx.arena and ctx.arena.stageYaw) or 0
  if yaw~=0 then
    local cs,sn=math.cos(yaw),math.sin(yaw)
    x,z=cs*x+sn*z,-sn*x+cs*z
  end
  return {x,y,z}
end
function H.cameraPose(ctx)
  if not (Waza and CSM and type(CSM.wazaBasis)=="function") then return nil end
  local inst=latestCameraInstance();if not inst then return nil end
  local role=tostring(inst.role or "attack")
  -- Camera grammar follows the attacker's action axis for the complete sentence.
  -- Damage/reaction Waza rows are target-owned effects, but rebuilding the camera
  -- basis as defender->attacker mirrors `right` and crosses the 180-degree line
  -- exactly at impact. Keep attacker->target orientation and simply move focus to
  -- the receiver for the damage chapter.
  local originSide=inst.side
  local otherSide=inst.target or (originSide=="player" and "enemy" or "player")
  -- Retail fight_waza.c loads WZX type 1 on the move user and type 2 on the
  -- target. fightOutPokemonLoadWazaEffect then attaches the sequence directly to
  -- that Pokemon's Waza owner, and wazaSequenceStart passes that exact owner to
  -- battleCameraStartWaza. Damage chapters are therefore target-owned for every
  -- owner-local camera transform/selector/facing decision, even though the
  -- presentation sentence below deliberately keeps attacker->target continuity.
  local sourceOwnerSide=(role=="damage") and otherSide or originSide
  local sourceOtherSide=(sourceOwnerSide==originSide) and otherSide or originSide
  local attachment=cameraAttachment(inst)
  local ok,basis=pcall(CSM.wazaBasis,CSM,ctx,originSide,otherSide,attachment,{
    moveId=tonumber(inst.moveId) or (inst.spec and inst.spec.moveId),style=inst.spec and inst.spec.style,role=role,sourceStrict=true})
  if not ok or type(basis)~="table" or type(basis.origin)~="table" or type(basis.target)~="table" then return nil end

  local src,dst=basis.origin,basis.target
  local forward=type(basis.forward)=="table" and basis.forward or {0,0,-1}
  local right=type(basis.right)=="table" and basis.right or {1,0,0}
  local frame=(tonumber(inst.frame) or 0)+(tonumber(inst.accumulator) or 0)*60
  local total=math.max(1,tonumber(inst.sourceEndFrame) or 1)
  local p=math.max(0,math.min(1,frame/total))
  local fallbackStyle=V.WazaPhasePolicy and V.WazaPhasePolicy.cameraStyle(inst.spec) or tostring(inst.spec and inst.spec.style or "impact"):lower()
  local fight=math.max(10,tonumber(basis.fightDistance) or cdist(src,dst))
  local sh=math.max(2.8,tonumber(basis.sourceVisualHeight) or 5.5)
  local th=math.max(2.8,tonumber(basis.targetVisualHeight) or sh)
  local avgH=(sh+th)*.5
  local focus,eye,fov=clerp(src,dst,.5),nil,SOURCE_CAMERA_FOV
  local fovSourceStatus
  local ownerRootBasis
  local okOwnerRoot,ownerRoot=pcall(CSM.wazaBasis,CSM,ctx,sourceOwnerSide,sourceOtherSide,nil,{
    moveId=tonumber(inst.moveId) or (inst.spec and inst.spec.moveId),style=inst.spec and inst.spec.style,role=role,sourceStrict=true,ownerRoot=true})
  if okOwnerRoot and type(ownerRoot)=="table" and type(ownerRoot.origin)=="table" then ownerRootBasis=ownerRoot end
  local sourceDecision=sourceCameraDecision(inst,role,src,ownerRootBasis,sourceOwnerSide)
  if sourceDecision and sourceDecision.active==false then return nil end
  local sourceCameraTarget
  if sourceDecision and not sourceDecision.embedded and sourceDecision.targetSlotExact then
    local okTarget,targetBasis=pcall(CSM.wazaBasis,CSM,ctx,sourceOwnerSide,sourceOtherSide,sourceDecision.targetSlot,{
      moveId=tonumber(inst.moveId) or (inst.spec and inst.spec.moveId),style=inst.spec and inst.spec.style,
      role=role,sourceStrict=true})
    if okTarget and type(targetBasis)=="table" and type(targetBasis.origin)=="table" then
      sourceCameraTarget=targetBasis.origin;sourceDecision.targetResolved=true
    end
  end
  -- Keep the diagnostic style distinct from the composition selector. An
  -- embedded retail camera resource owns the real shot, but until its HSD
  -- curve is decoded we must retain the move's previous safe source-shaped
  -- composition rather than falling through to the unrelated generic branch.
  local compositionStyle=fallbackStyle
  local style=sourceDecision and sourceDecision.embedded
      and (sourceDecision.embeddedDecoded and "source-embedded-hsd" or ("source-embedded-fallback-"..fallbackStyle))
    or (sourceDecision and ("source-motion-"..tostring(sourceDecision.motion)) or fallbackStyle)
  -- battleCameraStartWaza mirrors its camera rotation from the owner's facing
  -- (`reverse`) and the attack/damage Waza instances share BattleDirector's
  -- presentationSerial. Preserve one mirrored side of the 180-degree line for
  -- that complete source presentation instead of letting style-specific signs
  -- flip launch and impact to opposite sides.
  local actionKey=tostring(inst.presentationSerial or inst.parentAttackSerial or inst.serial or "waza")
  if cameraContinuity.actionKey~=actionKey then
    cameraContinuity.actionKey=actionKey
    cameraContinuity.axisSign=originSide=="enemy" and -1 or 1
  end
  local axisSign=cameraContinuity.axisSign or 1

  local embeddedStageSpace=false
  if sourceDecision and sourceDecision.embeddedDecoded then
    -- Retail embedded camera data is owner-local in this branch. Resolve the
    -- owner's model root (not a particle attachment), preserve the decoded HSD
    -- eye/interest/FOV curve, then reproduce the offset transform in final stage
    -- space. Source stageScale and actor figureScale are intentionally separate.
    local okRoot,rootBasis=ownerRootBasis~=nil,ownerRootBasis
    local sample=embeddedCameraSample(sourceDecision.camera,frame)
    if okRoot and type(rootBasis)=="table" and type(rootBasis.origin)=="table" and sample then
      local figureScale=tonumber(ctx and ctx.arena and ctx.arena.figureScale) or tonumber(ctx and ctx.services and ctx.services.figureScale) or 1
      local stageScale=tonumber(ctx and ctx.arena and ctx.arena.stageScale) or .25
      local ownerScale,ownerRelative,ownerSelector,ownerSelectorExact=embeddedOwnerScale(rootBasis,figureScale)
      local ownerReverse,ownerFacing=retailEmbeddedReverse(sourceOwnerSide,sourceDecision.flags)
      sourceDecision.ownerSide=sourceOwnerSide;sourceDecision.ownerFacing=ownerFacing;sourceDecision.ownerReverse=ownerReverse==true
      if ownerReverse==nil then
        sourceDecision.embeddedDecoded=false
        sourceDecision.embeddedTransformUnsupported="owner-facing-unavailable"
        style="source-embedded-fallback-"..fallbackStyle
      end
      if sourceDecision.battleSpace then
        local gridScale,gridSelector,gridScaleExact=1,nil,true
        if sourceDecision.gridNormalised then
          gridScale,gridSelector,gridScaleExact=retailGridScale(ctx)
          if not gridScale then
            sourceDecision.embeddedDecoded=false
            sourceDecision.embeddedTransformUnsupported="battle-grid-selector-unavailable"
            style="source-embedded-fallback-"..fallbackStyle
          end
        end
        local gridOwnerSide=sourceOwnerSide
        local gridOwnerFacing=ownerFacing
        local gridFacingSign=1
        if sourceDecision.gridFacingFlip then
          if gridOwnerFacing==nil then
            sourceDecision.embeddedDecoded=false
            sourceDecision.embeddedTransformUnsupported="battle-grid-owner-facing-unavailable"
            style="source-embedded-fallback-"..fallbackStyle
          elseif gridOwnerFacing<0 then
            -- battleCameraStartWaza writes offsetRotation.y = PI.  In grid-local
            -- coordinates that is exactly x,z -> -x,-z before stageYaw.
            gridFacingSign=-1
          end
        end
        if sourceDecision.embeddedDecoded then
          local yScale=sourceDecision.gridYIdentity and 1 or gridScale
          -- Retail transform order is scale -> offsetRotation -> reverse-axis
          -- flags -> offsetPosition. For the grid branch offsetPosition is zero;
          -- optional facing PI rotates both X/Z, then reverse shift=4 mirrors Z.
          local reverseZ=ownerReverse and -1 or 1
          eye=embeddedBattlePoint(ctx,sample.eye,stageScale,gridScale*gridFacingSign,yScale,gridScale*gridFacingSign*reverseZ)
          focus=embeddedBattlePoint(ctx,sample.focus,stageScale,gridScale*gridFacingSign,yScale,gridScale*gridFacingSign*reverseZ)
          sourceDecision.gridScale=gridScale;sourceDecision.gridSelector=gridSelector
          sourceDecision.gridScaleExact=gridScaleExact==true
          sourceDecision.gridOwnerSide=gridOwnerSide;sourceDecision.gridOwnerFacing=gridOwnerFacing
          sourceDecision.gridFacingApplied=sourceDecision.gridFacingFlip and gridFacingSign<0 or false
          sourceDecision.reverseMirrorApplied=ownerReverse==true
          embeddedStageSpace=true
        end
      else
        if rootBasis.ownerModelRotationExact~=true or tonumber(rootBasis.ownerModelYaw)==nil then
          sourceDecision.embeddedDecoded=false
          sourceDecision.embeddedTransformUnsupported="owner-model-rotation-unavailable"
          style="source-embedded-fallback-"..fallbackStyle
        elseif sourceDecision.embeddedDecoded then
          local pointBasis=rootBasis
          if sourceDecision.boundCentre then
            local retailBound=rootBasis.ownerRetailWazaBound
            if not (type(retailBound)=="table" and retailBound.exact==true and retailBound.selectorExact==true
                and type(retailBound.centerWorld)=="table") then
              sourceDecision.embeddedDecoded=false
              sourceDecision.embeddedTransformUnsupported="owner-bound-centre-unavailable"
              style="source-embedded-fallback-"..fallbackStyle
            else
              pointBasis={origin=retailBound.centerWorld,ownerModelYaw=rootBasis.ownerModelYaw,ownerModelRotationExact=true}
              sourceDecision.ownerBoundCentreExact=true
              sourceDecision.ownerBoundAnimationIndex=retailBound.animationIndex
            end
          end
          if sourceDecision.embeddedDecoded then
            eye=embeddedOwnerPoint(pointBasis,sample.eye,figureScale,stageScale,ownerScale,ownerReverse)
            focus=embeddedOwnerPoint(pointBasis,sample.focus,figureScale,stageScale,ownerScale,ownerReverse)
            if eye and focus then
              sourceDecision.ownerModelYaw=rootBasis.ownerModelYaw
              sourceDecision.reverseMirrorApplied=ownerReverse==true
              embeddedStageSpace=true
            else
              sourceDecision.embeddedDecoded=false
              sourceDecision.embeddedTransformUnsupported="owner-model-rotation-unavailable"
              style="source-embedded-fallback-"..fallbackStyle
            end
          end
        end
      end
      fov=math.rad(math.max(1,math.min(179,tonumber(sample.fov) or 40)))
      sourceDecision.ownerScale=ownerScale;sourceDecision.ownerRelative=ownerRelative;sourceDecision.ownerSelector=ownerSelector
      sourceDecision.ownerSelectorExact=ownerSelectorExact;sourceDecision.stageScale=stageScale
    else
      -- A decoded source curve without a live owner transform is not safe to
      -- present as retail. Fall through to the previous source-shaped fallback.
      sourceDecision.embeddedDecoded=false
      style="source-embedded-fallback-"..fallbackStyle
    end
  end
  if embeddedStageSpace then
    -- Decoded retail HSD pose already owns eye/focus/FOV in final stage space.
  elseif sourceDecision and not sourceDecision.embedded then
    -- Source root data wins over the legacy style vocabulary. Retail chooses one
    -- of camera motion modes 0/1/2/3/5 from the Waza root flags, calculates a
    -- source distance/rotation envelope, and advances that camera over the Waza
    -- duration. Reconstruct that *system* here; exact random samples and the
    -- authored HSD offset-camera animation remain explicitly outside this path.
    local motion=sourceDecision.motion
    local motionSample=sourceDecision.motionSample
    local ownerH=role=="damage" and th or sh
    local distance=sourceDecision.distance0
    local angle=sourceDecision.rotation0
    local worldAngle
    local sourceLateral
    if motion==0 then
      -- Retail beam/projectile mode: dolly between two source-range samples over
      -- the sequence duration. Focus stays at the owner/effect origin; this is
      -- camera travel, never projectile tracking.
      distance=lerp(sourceDecision.distance0,sourceDecision.distance1,p)
      focus=role=="damage" and {dst[1],dst[2]+th*.04,dst[3]} or clerp(src,dst,.08)
    elseif motion==1 then
      -- Mode 1 performs one timed lateral camera position
      -- move. Retail actually starts 10 units off-axis and then moves a further
      -- 25..35; when exact scalar params are available preserve that start/end
      -- displacement directly rather than collapsing it into a zero-based arc.
      if motionSample and motionSample.lateral0 and motionSample.lateral1 then
        sourceLateral=lerp(motionSample.lateral0,motionSample.lateral1,p)
        angle=math.atan(sourceLateral/math.max(1,distance))
      else
        local lateral=25+10*stable01(inst.presentationSerial or inst.serial or 1,inst.serial or 1,181)
        angle=math.atan((lateral*p)/math.max(1,distance))
      end
      focus=role=="damage" and {dst[1],dst[2]+th*.04,dst[3]} or clerp(src,dst,.16)
    elseif motion==2 then
      -- Mode 2 is the source's one timed Y-rotation channel. It is an authored
      -- arc within the shot, not a perpetual arena orbit.
      angle=lerp(sourceDecision.rotation0,sourceDecision.rotation1,p)
      focus=role=="damage" and {dst[1],dst[2]+th*.04,dst[3]} or clerp(src,dst,.27)
    elseif motion==3 then
      focus=role=="damage" and {dst[1],dst[2]+th*.04,dst[3]} or clerp(src,dst,.24)
    elseif motion==4 then
      -- ModelSequence id 0x13A forces retail mode 4: 110 distance, 25 height,
      -- and a fixed 0.47123894-radian (27-degree) owner-relative yaw. Earlier
      -- CBE builds inherited a random rotation-band sample here.
      if motionSample then angle=motionSample.rotation0
      elseif CameraParams and type(CameraParams.mode4)=="function" then angle=CameraParams.mode4().rotation end
      focus=role=="damage" and {dst[1],dst[2]+th*.04,dst[3]} or {src[1],src[2]+sh*.05,src[3]}
    elseif motion==5 then
      angle=motionSample and motionSample.rotation0 or math.rad(45)
      focus=role=="damage" and {dst[1],dst[2]+th*.04,dst[3]} or {src[1],src[2]+sh*.05,src[3]}
    end
    if sourceCameraTarget then
      -- The target identity is source-exact: +0x4C + sequence[0x17]*4 in the
      -- current PKX animation row. CurrentSpriteModels resolves that body-map
      -- slot against the live owner animation, matching retail's per-frame part
      -- tracking instead of aiming procedural cameras at a semantic midpoint.
      focus={sourceCameraTarget[1],sourceCameraTarget[2],sourceCameraTarget[3]}
    end
    local height
    if motionSample and tonumber(motionSample.height) then height=motionSample.height
    elseif motion==1 then height=1+9*stable01(inst.presentationSerial or inst.serial or 1,inst.serial or 1,197)
    elseif motion==4 and CameraParams and type(CameraParams.mode4)=="function" then height=CameraParams.mode4().height
    elseif sourceDecision.retailParams and sourceDecision.retailParams.exact then
      local rp=sourceDecision.retailParams
      height=rp.heightMin+(rp.heightMax-rp.heightMin)*stable01(inst.presentationSerial or inst.serial or 1,inst.serial or 1,197)
    else height=math.max(6,math.min(20,ownerH*.80)) end
    local fovRange=distance
    if motion==0 then fovRange=math.sqrt(sourceDecision.distance0*sourceDecision.distance0+height*height)
    elseif motion==1 then
      if motionSample and motionSample.fovRange then fovRange=motionSample.fovRange.near
      else
        local lateral=25+10*stable01(inst.presentationSerial or inst.serial or 1,inst.serial or 1,181)
        fovRange=math.sqrt(lateral*lateral+height*height)
      end
    elseif motion==2 then fovRange=math.sqrt(distance*distance+height*height)
    elseif motion==3 then fovRange=math.sqrt(distance*distance+height*height+angle*angle)
    elseif motion==4 and CameraParams and type(CameraParams.mode4)=="function" then fovRange=CameraParams.mode4().range
    elseif motion==5 then fovRange=math.sqrt(distance*distance+height*height+math.rad(45)*math.rad(45)) end
    if motion~=1 and motionSample and motionSample.worldRotationFormulaExact
        and tonumber(motionSample.worldRotation0) and tonumber(motionSample.worldRotation1) then
      -- GC6E01 camera mode 7 is cylindrical around the selected target.  Once
      -- GSmodel.rotation.y and the owner reverse bit are exact, DoPosition gives
      -- literal world Y rotations. Keep source linear interpolation for mode 2;
      -- modes 0/3/4/5 simply hold the source yaw while position/radius changes.
      worldAngle=lerp(motionSample.worldRotation0,motionSample.worldRotation1,p)
      eye={focus[1]+math.sin(worldAngle)*distance,focus[2]+height,focus[3]+math.cos(worldAngle)*distance}
      sourceDecision.worldRotationApplied=true;sourceDecision.worldRotation=worldAngle
    elseif sourceLateral then
      -- cameraMovePosition mode 1 translates the already-offset eye in X while
      -- retaining the 20..50 source distance. This is not a circular yaw arc.
      eye=offsetEye(focus,forward,right,distance,sourceLateral*axisSign,height)
    else
      local back=distance*math.cos(angle);local side=distance*math.sin(angle)*axisSign
      eye=offsetEye(focus,forward,right,back,side,height)
    end
    local ownerTiming
    local okTiming,timingBasis=pcall(CSM.wazaBasis,CSM,ctx,sourceOwnerSide,sourceOtherSide,nil,{
      moveId=tonumber(inst.moveId) or (inst.spec and inst.spec.moveId),style=inst.spec and inst.spec.style,
      role=role,sourceStrict=true,ownerRoot=true})
    if okTiming and type(timingBasis)=="table" then ownerTiming=timingBasis.ownerCameraTiming end
    local fovRanges=motionSample and motionSample.fovRange or fovRange
    fov,fovSourceStatus=sourceCameraFov(sourceDecision,ownerH,fovRanges,
      inst.presentationSerial or inst.serial or 1,frame,ownerTiming)
  elseif role=="damage" then
    -- Hold the struck actor's live source pose. The authored reaction supplies
    -- the impact motion; do not add an unrelated shake waveform to every move.
    focus={dst[1],dst[2]+th*.05,dst[3]}
    eye=offsetEye(focus,forward,right,fight*.29,fight*.22*axisSign,th*.52)
    fov=math.rad(35.5)
  elseif compositionStyle=="projectile" then
    -- The reference launch shot holds the attacker and its mouth-origin stream;
    -- the target receives its own damage shot. Do not chase the projectile
    -- across the entire arena before that authored phase boundary.
    focus=clerp(src,dst,.08);focus[2]=focus[2]+sh*.03
    eye=offsetEye(focus,forward,right,fight*.20,fight*.30*axisSign,sh*.48)
    fov=math.rad(36.5)
  elseif compositionStyle=="wave" then
    focus=clerp(src,dst,.5);focus[2]=focus[2]+avgH*.02
    eye=offsetEye(focus,forward,right,fight*.17,fight*.52*axisSign,avgH*.68)
    fov=math.rad(40.0)
  elseif compositionStyle=="contact" then
    focus=clerp(src,dst,.28);focus[2]=focus[2]+avgH*.04
    eye=offsetEye(focus,forward,right,fight*.23,fight*.36*axisSign,avgH*.50)
    fov=math.rad(36.0)
  elseif compositionStyle=="aura" or compositionStyle=="self" then
    focus={src[1],src[2]+sh*.08,src[3]}
    eye=offsetEye(focus,forward,right,fight*.30,fight*.26*axisSign,sh*.62)
    fov=math.rad(34.5)
  elseif compositionStyle=="target" then
    focus={dst[1],dst[2]+th*.05,dst[3]}
    eye=offsetEye(focus,forward,right,fight*.28,fight*.25*axisSign,th*.57)
    fov=math.rad(35.5)
  else -- A readable held attack composition while exact retail curves are pending.
    focus=clerp(src,dst,.25);focus[2]=focus[2]+avgH*.04
    eye=offsetEye(focus,forward,right,fight*.25,fight*.34*axisSign,avgH*.56)
    fov=math.rad(36.0)
  end
  -- Chapter changes are cuts, including hit/launch changes. Live actor motion
  -- still moves the focus within each shot through Camera's velocity limiter.

  local k=tonumber(ctx and ctx.arena and ctx.arena.figureScale) or tonumber(ctx and ctx.services and ctx.services.figureScale) or 1
  if not embeddedStageSpace then
    eye={eye[1]*k,eye[2]*k,eye[3]*k};focus={focus[1]*k,focus[2]*k,focus[3]*k}
  end
  local shotId=tostring(inst.presentationSerial or inst.serial or "waza")..":"..role..":"..style
  local cut=cameraContinuity.currentSerial~=shotId
  cameraContinuity.currentSerial=shotId
  local pose={eye=eye,focus=focus,fov=fov,sourceSerial=inst.serial,sourceShotId=shotId,sourceFrame=frame,sourceProgress=p,
    sourceStyle=style,sourceRole=role,presentationSerial=inst.presentationSerial,blend=.10,cut=cut,
    sourceCameraMotion=sourceDecision and sourceDecision.motion or nil,sourceCameraFlags=sourceDecision and sourceDecision.flags or nil,
    sourceCameraParamsFlags=sourceDecision and sourceDecision.paramsFlags or nil,sourceSequenceKind=sourceDecision and sourceDecision.sequenceKind or nil,
    sourceCameraMotionScalarExact=sourceDecision and sourceDecision.motionScalarExact==true or false,
    sourceCameraMotionRngExact=sourceDecision and sourceDecision.motionRngExact==true or false,
    sourceCameraWorldRotationExact=sourceDecision and sourceDecision.motionWorldRotationExact==true or false,
    sourceCameraWorldRotationApplied=sourceDecision and sourceDecision.worldRotationApplied==true or false,
    sourceCameraWorldRotation=sourceDecision and sourceDecision.worldRotation or nil,
    sourceCameraTargetSlot=sourceDecision and sourceDecision.targetSlot or nil,
    sourceCameraTargetSlotExact=sourceDecision and sourceDecision.targetSlotExact==true or false,
    sourceCameraTargetResolved=sourceDecision and sourceDecision.targetResolved==true or false,
    sourceCameraMode1LateralStart=sourceDecision and sourceDecision.motionSample and sourceDecision.motionSample.lateral0 or nil,
    sourceCameraMode1LateralEnd=sourceDecision and sourceDecision.motionSample and sourceDecision.motionSample.lateral1 or nil,
    sourceCameraEmbedded=sourceDecision and sourceDecision.embedded==true or false,
    sourceCameraEmbeddedSize=sourceDecision and sourceDecision.embeddedSize or nil,
    sourceCameraEmbeddedCurveDecoded=sourceDecision and sourceDecision.embeddedCurveDecoded==true or false,
    sourceCameraEmbeddedDecoded=sourceDecision and sourceDecision.embeddedDecoded==true or false,
    sourceCameraEmbeddedTransformUnsupported=sourceDecision and sourceDecision.embeddedTransformUnsupported or nil,
    sourceCameraRootNullSpecial=sourceDecision and sourceDecision.rootNullSpecial==true or false,
    sourceCameraOwnerBoundCentreExact=sourceDecision and sourceDecision.ownerBoundCentreExact==true or false,
    sourceCameraOwnerBoundAnimationIndex=sourceDecision and sourceDecision.ownerBoundAnimationIndex or nil,
    sourceCameraOwnerScale=sourceDecision and sourceDecision.ownerScale or nil,
    sourceCameraOwnerRelative=sourceDecision and sourceDecision.ownerRelative or nil,
    sourceCameraOwnerSelector=sourceDecision and sourceDecision.ownerSelector or nil,
    sourceCameraOwnerSelectorExact=sourceDecision and sourceDecision.ownerSelectorExact==true or false,
    sourceCameraOwnerSide=sourceDecision and sourceDecision.ownerSide or nil,
    sourceCameraOwnerFacing=sourceDecision and sourceDecision.ownerFacing or nil,
    sourceCameraOwnerReverse=sourceDecision and sourceDecision.ownerReverse==true or false,
    sourceCameraOwnerModelYaw=sourceDecision and sourceDecision.ownerModelYaw or nil,
    sourceCameraReverseMirrorApplied=sourceDecision and sourceDecision.reverseMirrorApplied==true or false,
    sourceCameraStageScale=sourceDecision and sourceDecision.stageScale or nil,
    sourceCameraGridScale=sourceDecision and sourceDecision.gridScale or nil,
    sourceCameraGridScaleExact=sourceDecision and sourceDecision.gridScaleExact==true or false,
    sourceCameraGridSelector=sourceDecision and sourceDecision.gridSelector or nil,
    sourceCameraGridOwnerSide=sourceDecision and sourceDecision.gridOwnerSide or nil,
    sourceCameraGridOwnerFacing=sourceDecision and sourceDecision.gridOwnerFacing or nil,
    sourceCameraGridFacingApplied=sourceDecision and sourceDecision.gridFacingApplied==true or false,
    sourceCameraFovPatternExact=fovSourceStatus and fovSourceStatus.patternExact==true or false,
    sourceCameraFovPatternUsed=fovSourceStatus and fovSourceStatus.patternUsed==true or false,
    sourceCameraFovTimingExact=fovSourceStatus and fovSourceStatus.timingExact==true or false,
    sourceCameraFovBoundsExact=fovSourceStatus and fovSourceStatus.boundsExact==true or false,
    sourceCameraFovBoundsProxy=fovSourceStatus and fovSourceStatus.boundsProxy==true or false,
    sourceCameraFovBoundGeometryExact=fovSourceStatus and fovSourceStatus.boundGeometryExact==true or false,
    sourceCameraFovRangeFormulaExact=fovSourceStatus and fovSourceStatus.rangeFormulaExact==true or false,
    sourceCameraFovRangeSampleExact=fovSourceStatus and fovSourceStatus.rangeSampleExact==true or false,
    sourceCameraFovTable=fovSourceStatus and fovSourceStatus.tableName or nil,
    sourceCameraFovRow=fovSourceStatus and fovSourceStatus.rowIndex or nil,
    sourceCameraFovSelection=fovSourceStatus and fovSourceStatus.selection or nil,
    sourceCameraFovFrameShift=fovSourceStatus and fovSourceStatus.frameShift or nil,
    sourceCameraFovClock=fovSourceStatus and fovSourceStatus.cameraClock or nil,
    sourceCameraFovUnsupported=fovSourceStatus and fovSourceStatus.reason or nil,
    sourceCameraRetailFrameExact=sourceDecision and sourceDecision.camera and sourceDecision.camera.retailFrameExact==true or false}
  cameraContinuity.lastPose={eye={eye[1],eye[2],eye[3]},focus={focus[1],focus[2],focus[3]},fov=fov}
  return pose
end
function H.activeModels() local out={};for _,row in pairs(H.models) do out[#out+1]=row end;return out end
function H.finish() releasePost();if H.distortShader and H.distortShader.release then pcall(H.distortShader.release,H.distortShader) end;H.distortShader=nil;for _,rec in pairs(H.effects) do releaseDynamicMeshes(rec) end;H.models={};H.effects={};H.controllers={player={},enemy={}};cameraContinuity={session=nil,currentSerial=nil,transitionFrom=nil,transitionStartFrame=0,lastPose=nil,actionKey=nil,axisSign=nil,motionKey=nil,motionMode=nil,lastMotionMode=nil};return true end

local function releaseLoveObject(obj,seen)
  if obj==nil then return end
  seen=seen or {}
  if seen[obj] then return end
  seen[obj]=true
  pcall(function()
    local release=obj.release
    if type(release)=="function" then release(obj) end
  end)
end

-- Release battle-used Waza GPU assets on Android without deleting the generated
-- model/texture files in mod.cache. Shader programs stay resident, avoiding a
-- compile hitch on the next move while preventing an unbounded per-move VRAM
-- cache from growing throughout a long mobile play session.
function H.trimRuntimeMemory()
  -- Keep only the four most recently used Waza effect models. The previous
  -- all-or-nothing purge guaranteed that common source effect meshes/textures
  -- were reparsed and reuploaded in the next battle. Four entries keep the
  -- working set tiny on mobile while avoiding that repeated first-use hitch.
  local ranked={}
  for path,asset in pairs(H.modelCache) do
    if type(asset)=="table" then ranked[#ranked+1]={path=path,asset=asset,use=tonumber(asset.__cbeUse) or 0} end
  end
  table.sort(ranked,function(a,b)return a.use>b.use end)
  local keep={};for i=1,math.min(4,#ranked) do keep[ranked[i].path]=true end
  local keptImages={}
  for path in pairs(keep) do
    local asset=H.modelCache[path]
    if type(asset)=="table" then
      for _,g in ipairs(asset.groups or {}) do if type(g)=="table" and g.image then keptImages[g.image]=true end end
      for _,img in pairs(asset.textures or {}) do if img then keptImages[img]=true end end
    end
  end
  local seen={}
  for path,asset in pairs(H.modelCache) do
    if not keep[path] and type(asset)=="table" then
      for _,g in ipairs(asset.groups or {}) do
        if type(g)=="table" then
          releaseLoveObject(g.mesh,seen)
          if g.image and not keptImages[g.image] then releaseLoveObject(g.image,seen) end
        end
      end
      for _,img in pairs(asset.textures or {}) do if not keptImages[img] then releaseLoveObject(img,seen) end end
      H.modelCache[path]=nil;H.modelErrors[path]=nil
    elseif asset==false then
      -- Failed cache entries are tiny; keep the failure memo so a malformed
      -- source effect is not reparsed every battle.
    end
  end
  for key,img in pairs(H.textureCache or {}) do
    if not keptImages[img] then releaseLoveObject(img,seen);H.textureCache[key]=nil end
  end
  H.partsCache={};releasePost();for _,rec in pairs(H.effects) do releaseDynamicMeshes(rec) end;H.models={};H.effects={};H.controllers={player={},enemy={}};H.opaque={};H.lastModel=nil
  cameraContinuity={session=nil,currentSerial=nil,transitionFrom=nil,transitionStartFrame=0,lastPose=nil}
  -- Meshes/textures above are explicitly released. Avoid a stop-the-world Lua
  -- collection on the battle-end seam; BattleRuntime performs incremental GC
  -- while the player is back in the overworld.
  return true
end

H._test={runtimeUsable=runtimeUsable,runtimeRoot=runtimeRoot,runtimeMetaPath=runtimeMetaPath,bakeRuntimeCache=bakeRuntimeCache,modelMatrix=modelMatrix,morphWeights=morphWeights,ensureShader=ensureShader,keyedColor=keyedColor,sourceSurfaceColor=sourceSurfaceColor,drawTraceRibbon=drawTraceRibbon,releaseDynamicMeshes=releaseDynamicMeshes,
  type6Start=type6Start,filteredPartTransform=filteredPartTransform,partTransformSelector=partTransformSelector,linkedParticleBirthTransform=linkedParticleBirthTransform,
  textureAnimationSample=textureAnimationSample,sourceCameraFov=sourceCameraFov,sourceFovEnvelope=sourceFovEnvelope,sourceParamsFlags=sourceParamsFlags,retailGridScale=retailGridScale}

function H.status()
  local m=0;for _ in pairs(H.models) do m=m+1 end
  local cached=0;for _,v in pairs(H.modelCache) do if v then cached=cached+1 end end
  return {installed=H.installed,activeModels=m,cachedModels=cached,opaqueEntries=#H.opaque,drawError=H.drawError,renderFaults=H.renderFaults or 0,runtimeMeshHits=runtimeMeshHits,runtimeMeshWrites=runtimeMeshWrites,runtimeMeshFallbacks=runtimeMeshFallbacks,hardCache=H.hardCacheStatus(),
    provenSourceTypes={controller=1,model=2,particle=3,effect=4,sound=5,ownerController=6},opaqueSourceTypes={},
    cameraDecoder="embedded HSD_CObj retail-frame curves plus procedural FOV pattern/timing tables; exact GSmodel-bound geometry and DoPosition range formulas are used when available, retail RNG identity remains unresolved; bound-centre/root-null-Y/unsupported path transforms fail closed",
    modelDecoder="native-HSD-60Hz-morph-pages-v4-safe-tev-pass"}
end
return H
