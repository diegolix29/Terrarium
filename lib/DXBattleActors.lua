-- Adapter: 368ImporterDX -> 368RealtimeBattleDX battleActors v1.
--
-- The environment mod intentionally owns no Pokemon assets. This module finds
-- the separately installed POKEMON_XD_GEN1 mod, uses its public pokemon_xd_386
-- createActor() API, and presents those actors through CBE/XDBE's portable
-- battleActors seam. Rendering uses the arena's own VP matrix so Battle Art's
-- stage/compositor does not need to be active.
local V=...
local A={}
local ModLookup=V.ModLookup
local Mat4=V.Mat4
local provider=nil
local providerOwner="POKEMON_XD_GEN1"
local shader=nil
local shaderError=nil
local shadowImage=nil
local rendererContext=nil

local VERTEX=[[
uniform mat4 vp;
uniform mat4 model;
attribute float VertexShade;
varying float shadeAmount;
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  shadeAmount = VertexShade;
  return vp * model * vertex_position;
}
]]

local PIXEL=[[
uniform float toonMode;
varying float shadeAmount;
vec4 effect(vec4 color, Image texture, vec2 uv, vec2 screen) {
  vec4 texel = Texel(texture, uv) * color;
  if (texel.a < 0.035) discard;
  float s = clamp(shadeAmount, 0.30, 1.10);
  if (toonMode > 0.5) {
    if (s < 0.76) s = 0.52;
    else if (s < 0.90) s = 0.76;
    else s = 1.00;
  }
  return vec4(texel.rgb * s, texel.a);
}
]]

local function log(level,fmt,...)
  local m=V.mod
  local l=m and m.log
  local fn=l and l[level]
  if type(fn)=="function" then pcall(fn,l,fmt,...) end
end

local function dxApi(context)
  local game=(context and context.game) or (context and context.battle and context.battle.game) or (V.mod and V.mod.game)
  if ModLookup and type(ModLookup.find)=="function" then
    local h=ModLookup.find(V.mod,"POKEMON_XD_GEN1")
    local e=h and h.exports
    local api=e and (e.pokemon_xd_386 or e.stadiumdx)
    if type(api)=="table" and type(api.createActor)=="function" then
      return api,h
    end
  end
  -- Fallback for builds whose loader does not enumerate the provider yet.
  local api=rawget(_G,"POKEMON_XD_386_API") or rawget(_G,"POKEMON_XD_API")
  if type(api)=="table" and type(api.createActor)=="function" then
    return api,{id="POKEMON_XD_GEN1",exports={pokemon_xd_386=api}}
  end
  return nil,nil
end

local function toonEnabled(context)
  local api=dxApi(context or rendererContext)
  if api and type(api.toonEnabled)=="function" then
    local ok,v=pcall(api.toonEnabled)
    if ok then return v==true end
  end
  -- Gen1DX386's TOON/CEL option defaults OFF. If an older provider does not
  -- expose toonEnabled(), do not silently force the battle renderer into toon.
  return false
end

local function modelsEnabled(context)
  local settings=V.BattleSettings
  if settings and type(settings.pokemonModelsEnabled)=="function" then
    local game=(context and context.game) or (context and context.battle and context.battle.game) or (V.mod and V.mod.game)
    local ok,v=pcall(settings.pokemonModelsEnabled,game)
    if ok and v==false then return false end
  end
  local api=dxApi(context)
  if not api then return false end
  if type(api.battleSceneEnabled)=="function" then
    local ok,v=pcall(api.battleSceneEnabled)
    if ok and v==false then return false end
  end
  return true
end

local function ensureShader()
  if shader then return shader end
  if shaderError then return nil,shaderError end
  if not (love and love.graphics and type(love.graphics.newShader)=="function") then
    shaderError="LOVE graphics unavailable"
    return nil,shaderError
  end
  local ok,value=pcall(love.graphics.newShader,VERTEX,PIXEL)
  if not ok then shaderError=tostring(value);return nil,shaderError end
  shader=value
  return shader
end

local function atan2(y,x)
  if math.atan2 then return math.atan2(y,x) end
  if x>0 then return math.atan(y/x) end
  if x<0 and y>=0 then return math.atan(y/x)+math.pi end
  if x<0 and y<0 then return math.atan(y/x)-math.pi end
  if x==0 and y>0 then return math.pi/2 end
  if x==0 and y<0 then return -math.pi/2 end
  return 0
end

local SHADOW_FORMAT={
  {"VertexPosition","float",3},
  {"VertexTexCoord","float",2},
  {"VertexShade","float",1},
}

local function ensureShadowImage()
  if shadowImage then return shadowImage end
  if not (love and love.image and love.graphics and love.image.newImageData and love.graphics.newImage) then return nil end
  local size=48
  local ok,data=pcall(love.image.newImageData,size,size)
  if not ok or not data then return nil end
  for y=0,size-1 do
    for x=0,size-1 do
      local dx=((x+.5)/size)*2-1
      local dy=((y+.5)/size)*2-1
      local d=dx*dx+dy*dy
      local a=0
      if d<1 then
        local q=1-d
        a=.44*q*q
      end
      data:setPixel(x,y,0,0,0,a)
    end
  end
  local okImg,img=pcall(love.graphics.newImage,data)
  if not okImg or not img then return nil end
  if img.setFilter then pcall(img.setFilter,img,"linear","linear") end
  shadowImage=img
  return shadowImage
end

local function ensureActorShadow(actor)
  local r=actor and actor.raw
  local rig=r and r.rig
  local g=love and love.graphics
  local img=ensureShadowImage()
  if not (r and rig and g and img) then return nil end
  local girth=math.max(1,tonumber(rig.girth) or tonumber(r.model and r.model.girth) or 4)
  local floor=tonumber(r._idleFloor) or tonumber(r.model and r.model.baseFloor) or tonumber(r.model and r.model.floor) or 0
  local rx=math.min(28,math.max(2.2,girth*.92))
  local rz=math.min(18,math.max(1.5,girth*.58))
  if actor._shadowMesh and math.abs((actor._shadowRX or 0)-rx)<.35 and math.abs((actor._shadowRZ or 0)-rz)<.35 and math.abs((actor._shadowFloor or 0)-floor)<.25 then
    return actor._shadowMesh
  end
  if actor._shadowMesh and actor._shadowMesh.release then pcall(actor._shadowMesh.release,actor._shadowMesh) end
  local verts={}
  local seg=28
  local yy=floor+.08
  local function add(px,pz,u,v) verts[#verts+1]={px,yy,pz,u,v,1} end
  for i=0,seg-1 do
    local a0=(i/seg)*math.pi*2
    local a1=((i+1)/seg)*math.pi*2
    add(0,0,.5,.5)
    add(math.cos(a0)*rx,math.sin(a0)*rz,.5+.5*math.cos(a0),.5+.5*math.sin(a0))
    add(math.cos(a1)*rx,math.sin(a1)*rz,.5+.5*math.cos(a1),.5+.5*math.sin(a1))
  end
  local ok,mesh=pcall(g.newMesh,SHADOW_FORMAT,verts,"triangles","static")
  if not ok or not mesh then return nil end
  if mesh.setTexture then pcall(mesh.setTexture,mesh,img) end
  actor._shadowMesh=mesh;actor._shadowRX=rx;actor._shadowRZ=rz;actor._shadowFloor=floor
  return mesh
end

local function groundedShadowMatrix(matrix,raw)
  local m={}
  for i=1,16 do m[i]=matrix[i] end
  local base=rendererContext and tonumber(rendererContext.groundY)
  local y=raw and tonumber(raw.y)
  if base and y then m[8]=(m[8] or 0)-(y-base) end
  -- The visible actor may receive a battle-only pose-floor lift so wing/leg
  -- motion cannot pass through the arena deck. The contact shadow itself must
  -- remain on the deck, not follow that corrective lift upward.
  local poseLift=raw and tonumber(raw._cbeBattleFloorLift) or 0
  if poseLift and poseLift>0 then m[8]=(m[8] or 0)-poseLift end
  return m
end

local function battlePoseFloorLift(raw)
  local rig=raw and raw.rig
  if not rig then return 0 end
  -- Gen1DX386 anchors its raw actor to the idle frame's floor. Some flying XD
  -- clips (notably Spearow/Pidgeotto) move the whole authored pose below that
  -- idle baseline, so the lower body can intersect the battle-stage surface.
  -- Clamp only downward penetration; upward/bobbing motion remains native.
  local floor=tonumber(raw._idleFloor)
    or tonumber(raw.model and raw.model.baseFloor)
    or tonumber(raw.model and raw.model.floor)
  local posedLo=tonumber(rig.lo)
  if floor==nil or posedLo==nil or posedLo>=floor then return 0 end
  local k=.6*(tonumber(raw._presentationScale) or 1)
  return math.max(0,(floor-posedLo)*k)+.002
end

-- XD PKX body-map slot order. The generated DX386 pack preserves these raw
-- body-map joint ids, but its public actor did not expose them. Realtime VFX
-- needs the animated mouth position, so this adapter resolves the compact XDA1
-- skin matrix for the mapped joint and transforms that authored point through
-- the exact same raw actor matrix used to render the Pokemon.
local BODY_SLOT_INDEX={
  origin=1,mouth=2,chest=3,tail=4,eye_left=5,eye_right=6,
  hand_left=7,hand_right=8,additional_1=9,additional_2=10,
  additional_3=11,additional_4=12,foot_left=13,foot_right=14,
  center=15,additional_5=16,
}

local function matrixPoint(m,p)
  if not (type(m)=="table" and type(p)=="table") then return nil end
  local x,y,z=tonumber(p[1]) or 0,tonumber(p[2]) or 0,tonumber(p[3]) or 0
  return {
    (m[1] or 1)*x+(m[2] or 0)*y+(m[3] or 0)*z+(m[4] or 0),
    (m[5] or 0)*x+(m[6] or 1)*y+(m[7] or 0)*z+(m[8] or 0),
    (m[9] or 0)*x+(m[10] or 0)*y+(m[11] or 1)*z+(m[12] or 0),
  }
end

local function u16le(s,i)
  local a,b=s:byte(i,i+1);if not a then return 0 end
  return a+(b or 0)*256
end
local function u32le(s,i)
  local a,b,c,d=s:byte(i,i+3);if not a then return 0 end
  return a+(b or 0)*256+(c or 0)*65536+(d or 0)*16777216
end
local function f32le(s,i)
  local a,b,c,d=s:byte(i,i+3);if not d then return 0 end
  local u=a+b*256+c*65536+d*16777216
  local sign=1
  if u>=2147483648 then sign=-1;u=u-2147483648 end
  local exp=math.floor(u/8388608)
  local man=u-exp*8388608
  if exp==255 then return man==0 and sign*math.huge or 0/0 end
  if exp==0 then
    if man==0 then return sign==1 and 0 or -0 end
    return sign*(man/8388608)*2^-126
  end
  return sign*(1+man/8388608)*2^(exp-127)
end
local function m43(s,p)
  local m={}
  for i=1,12 do m[i]=f32le(s,p+(i-1)*4) end
  return {m[1],m[2],m[3],m[4],m[5],m[6],m[7],m[8],m[9],m[10],m[11],m[12],0,0,0,1}
end

local function matrix44(m)
  if type(m)~="table" then return nil end
  if m[16]~=nil then return m end
  -- The DX386 builder stores HSD affine matrices as 3x4 (12 numbers).
  -- Pad them here before using the environment's ordinary 4x4 multiplier.
  if m[12]~=nil then
    return {m[1],m[2],m[3],m[4],m[5],m[6],m[7],m[8],m[9],m[10],m[11],m[12],0,0,0,1}
  end
  return nil
end

local function bindWorlds(model)
  if not model then return nil end
  if type(model._cbeBindWorlds)=="table" then return model._cbeBindWorlds end
  local worlds={}
  local bones=model.parsed and model.parsed.skeleton and model.parsed.skeleton.bones or {}
  for _,b in ipairs(bones) do
    local joint=tonumber(b.joint)
    local localM=matrix44(b.localM)
    if joint and localM then
      local parent=tonumber(b.parent)
      local world=localM
      if parent and parent>=0 and type(worlds[parent])=="table" and Mat4 and type(Mat4.mul)=="function" then
        world=Mat4.mul(worlds[parent],localM)
      end
      worlds[joint]=world
    end
  end
  model._cbeBindWorlds=worlds
  return worlds
end

local function compactRows(clip)
  if not clip then return nil end
  if type(clip._cbeAttachmentRows)=="table" then return clip._cbeAttachmentRows end
  local s=clip._animData
  if type(s)~="string" or #s<8 or s:sub(1,4)~="XDA1" then return nil end
  local rows={}
  local count=u16le(s,7)
  local p=9
  for _=1,count do
    if p+7>#s then break end
    local joint=u16le(s,p)
    local mode=s:byte(p+2) or 0
    local samples=u32le(s,p+4)
    local data=p+8
    local bytes=samples*48
    if samples<1 or data+bytes-1>#s then break end
    rows[joint]={mode=mode,count=samples,offset=data}
    p=data+bytes
  end
  clip._cbeAttachmentRows=rows
  return rows
end

local function sampledJointLocal(raw,joint)
  local rig=raw and raw.rig
  local model=raw and raw.model
  local worlds=bindWorlds(model)
  local bind=worlds and worlds[joint]
  if type(bind)~="table" then return nil end
  local bindPos={tonumber(bind[4]) or 0,tonumber(bind[8]) or 0,tonumber(bind[12]) or 0}
  local clip=rig and rig.clip
  local rows=compactRows(clip)
  local row=rows and rows[joint]
  if not row then return bindPos end
  local frame=math.floor(tonumber(rig.frameAt) or 0)
  local sample=(row.mode==0) and 0 or (frame%math.max(1,row.count))
  local skin=m43(clip._animData,row.offset+sample*48)
  return matrixPoint(skin,bindPos) or bindPos
end

local Actor={}
Actor.__index=Actor

function Actor.new(raw,dex,variant,opts)
  return setmetatable({
    raw=raw,dex=dex,variant=variant or "normal",side=opts and opts.side,
    state="spawn",stateAge=0,recallScale=nil,removed=false,
  },Actor)
end

function Actor:attachment(name)
  local r=self.raw
  local model=r and r.model
  local bodyMap=model and model.bodyMap
  local slot=BODY_SLOT_INDEX[tostring(name or "center"):lower()] or BODY_SLOT_INDEX.center
  local bone=type(bodyMap)=="table" and tonumber(bodyMap[slot]) or nil
  if not bone or bone<0 then return nil,"XD PKX body-map slot unavailable" end

  -- PKX body-map values are zero-based HSD joint ids; generated skeleton joints
  -- are one-based. Keep a defensive same-index fallback for older generated packs.
  local joint=bone+1
  local localPos=sampledJointLocal(r,joint)
  if not localPos then
    joint=bone
    localPos=sampledJointLocal(r,joint)
  end
  if not localPos then return nil,"XD PKX body-map joint unavailable" end

  local worldMatrix
  if r and type(r.matrix)=="function" then
    local ok,m=pcall(r.matrix,r)
    if ok then worldMatrix=m end
  end
  local world=matrixPoint(worldMatrix,localPos)
  if not world then return nil,"XD actor world matrix unavailable" end
  return {name=name,boneIndex=bone,joint=joint,localPosition=localPos,position=world,source="xd-pkx-body-map-xda1"}
end

function Actor:build()
  return self.raw~=nil and self.raw.dead~=true
end

function Actor:matrix(x,groundY,z,towardX,towardZ)
  local r=self.raw
  if not r then return nil end
  if type(r.setGroundY)=="function" then pcall(r.setGroundY,r,groundY or 0) end
  if type(r.setPosition)=="function" then pcall(r.setPosition,r,x or 0,groundY or 0,z or 0) end
  if type(r.setYaw)=="function" then pcall(r.setYaw,r,atan2(towardX or 0,towardZ or 1)) end
  if type(r.matrix)=="function" then
    local ok,m=pcall(r.matrix,r)
    if ok and type(m)=="table" then
      local lift=battlePoseFloorLift(r)
      r._cbeBattleFloorLift=lift
      if lift>0 then m[8]=(m[8] or 0)+lift end
      return m
    end
  end
  r._cbeBattleFloorLift=0
  return nil
end

function Actor:draw(matrix)
  local r=self.raw
  if not (r and r.rig and type(r.rig.parts)=="table" and shader and matrix) then return false end
  local g=love and love.graphics
  if not g then return false end
  local drew=false

  -- Soft contact shadow. Keep it on the arena floor even while realtime jump/
  -- flight lifts the model; the shadow fades at the rim instead of using a
  -- hard black decal. It deliberately does not write depth.
  local sm=ensureActorShadow(self)
  if sm then
    local shadowM=groundedShadowMatrix(matrix,r)
    pcall(shader.send,shader,"model","row",shadowM)
    pcall(shader.send,shader,"toonMode",0)
    pcall(g.setDepthMode,"lequal",false)
    pcall(g.setColor,1,1,1,1)
    pcall(g.draw,sm)
    pcall(g.setDepthMode,"lequal",true)
  end

  local okModel=pcall(shader.send,shader,"model","row",matrix)
  if not okModel then return false end

  -- Battle toon rendering follows the SAME live Main DX option as overworld.
  -- Turning STADIUMDX TOON / CEL SHADING off now removes both the expanded
  -- black outline and the three-band quantization immediately in battle.
  local cel=toonEnabled(rendererContext)
  if cel then
    pcall(shader.send,shader,"toonMode",0)
    pcall(g.setDepthMode,"lequal",false)
    pcall(g.setColor,.025,.025,.03,1)
    for _,part in ipairs(r.rig.parts) do
      if part and part.outlineMesh then pcall(g.draw,part.outlineMesh) end
    end
    pcall(g.setDepthMode,"lequal",true)
  end

  pcall(shader.send,shader,"toonMode",cel and 1 or 0)
  pcall(g.setColor,1,1,1,1)
  for _,part in ipairs(r.rig.parts) do
    if part and part.mesh then
      local ok=pcall(g.draw,part.mesh)
      if ok then drew=true end
    end
  end
  return drew
end

function Actor:spawn(scale)
  local r=self.raw
  scale=math.max(0,math.min(1,tonumber(scale) or 1))

  -- driveSpawn() is intentionally called every frame by CurrentSpriteModels.
  -- Do not interpret every fully-visible frame as a fresh spawn completion.
  -- The old code forced raw:setAnimation("idle") here every frame, which
  -- restarted walk/physical/hurt at frame 0 continuously.
  local wasSpawn=(self.state=="spawn")
  if scale<0.999 then
    self.state="spawn"
  elseif wasSpawn then
    self.state="idle"
  elseif self.state==nil then
    self.state="idle"
  end

  if r then
    if type(r.setVisible)=="function" then pcall(r.setVisible,r,scale>0.001) end
    if type(r.setPresentationScale)=="function" then pcall(r.setPresentationScale,r,scale) end

    -- Only establish idle once when the actual send-out/spawn transition ends.
    -- Preserve realtime locomotion and one-shot action states afterward.
    if scale>=0.999 and wasSpawn and r.requestedAnim~="idle"
        and type(r.setAnimation)=="function" then
      pcall(r.setAnimation,r,"idle")
    end
  end
  return self
end

function Actor:idle()
  self.state="idle";self.stateAge=0
  if self.raw and type(self.raw.setAnimation)=="function" then pcall(self.raw.setAnimation,self.raw,"idle") end
  return self
end

function Actor:sleep()
  self.state="sleep";self.stateAge=0
  if self.raw and type(self.raw.setAnimation)=="function" then
    if self.raw.requestedAnim~="sleep" then pcall(self.raw.setAnimation,self.raw,"sleep") end
  end
  return self
end

function Actor:locomotion(moving,flightState,flightMode)
  if self.state~="idle" and self.state~="spawn" then return self end
  local r=self.raw
  if not (r and type(r.setAnimation)=="function") then return self end
  local airborne=flightMode==true or flightState=="takeoff" or flightState=="airborne"
  local wanted
  if flightState=="takeoff" then
    wanted="fly"
  elseif airborne then
    wanted=moving and "fly" or "air_idle"
  else
    wanted=moving and "walk" or "idle"
  end
  if r.requestedAnim~=wanted then pcall(r.setAnimation,r,wanted) end
  return self
end

local function moveName(moveId,move)
  local n=move and (move.id or move.name) or moveId
  return tostring(n or ""):upper():gsub("[%s%-]+","_"):gsub("[^A-Z0-9_]","")
end

-- Pokemon XD / Gen III uses the pre-Gen-IV type split for the model's
-- section motion. This is intentionally NOT Kanto-Reforged's modern
-- move.category field.
local PHYSICAL_TYPE={
  NORMAL=true,FIGHTING=true,FLYING=true,POISON=true,GROUND=true,
  ROCK=true,BUG=true,GHOST=true,STEEL=true,
}
local SPECIAL_TYPE={
  FIRE=true,WATER=true,GRASS=true,ELECTRIC=true,PSYCHIC=true,
  ICE=true,DRAGON=true,DARK=true,
}

local function normalizeMoveType(move)
  local t=move and (move.type or move.moveType or move.element)
  t=tostring(t or ""):upper():gsub("[%s%-]+","_")
  t=t:gsub("_TYPE$","")
  if t=="PSYCHIC_TYPE" then t="PSYCHIC" end
  return t
end

local function fallbackFamily(move)
  -- Only used if an injected/custom move has no readable type.
  local c=move and (move.category or move.damageClass or move.class)
  c=tostring(c or ""):lower()
  if c:find("special",1,true) then return "special" end
  if c:find("physical",1,true) then return "physical" end
  return nil
end

local PHYSICAL_VARIANT_SLOTS={2,3,4,5,7} -- A,B,C,D,E
local SPECIAL_VARIANT_SLOTS={1,6,12}      -- A,B,C

-- Retail XD uses variant A for virtually every ordinary move. A small group
-- of stateful moves can select B/C/D/E depending on runtime state. Realtime
-- publishes _xdVariant when that state is known; otherwise retail-safe A is
-- used instead of inventing a limb/body-part animation.
local function retailMoveSlot(moveId,move)
  local typ=normalizeMoveType(move)
  local family
  if PHYSICAL_TYPE[typ] then family="physical"
  elseif SPECIAL_TYPE[typ] then family="special"
  else family=fallbackFamily(move) or "physical" end

  local variant=math.floor(tonumber(move and move._xdVariant) or 1)
  if variant<1 then variant=1 end
  local slots=family=="special" and SPECIAL_VARIANT_SLOTS or PHYSICAL_VARIANT_SLOTS
  if variant>#slots then variant=#slots end
  return family,slots[variant],variant,typ
end

local function slotActions(raw,slot)
  local rig=raw and raw.rig
  local model=rig and rig.model
  local slots=model and model.xdSlots
  local row=slots and (slots[tostring(slot)] or slots[slot])
  local actions=row and row.actions
  if type(actions)=="table" and #actions>0 then return actions end
  return nil
end

local function playExactXDSlot(raw,slot,family)
  if not raw then return nil end
  local rig=raw.rig
  local model=rig and rig.model
  local stateMap=model and model.stateMap

  local actions=slotActions(raw,slot)
  if rig and type(rig.setState)=="function" and type(stateMap)=="table" and actions then
    local key="_cbe_xd_retail_slot_"..tostring(slot)
    stateMap[key]=actions
    local ok=pcall(rig.setState,rig,key)
    if ok then
      raw.time=0
      raw.done=false
      raw.requestedAnim=(family=="special" and "xd_special_a" or "xd_physical_a")
      return slot
    end
  end

  -- Realtime presentation fallback: some XD Pokemon do not populate retail
  -- variant A even though they do have another native physical/special attack
  -- motion. The importer already builds semantic physical/special sets from
  -- the Pokemon's actual populated XD slots, so use that verified set before
  -- giving up to Idle. This does not invent a motion or change combat logic.
  if type(raw.setAnimation)=="function" then
    local semantic=(family=="special" and "special" or "physical")
    local ok=pcall(raw.setAnimation,raw,semantic)
    if ok then return semantic end
  end

  -- Final retail-safe fallback: if the Pokemon genuinely has no populated
  -- attack motion in the imported PKX metadata, stay in its actual Idle slot.
  local idleActions=slotActions(raw,0)
  if rig and type(rig.setState)=="function" and type(stateMap)=="table" and idleActions then
    local key="_cbe_xd_retail_slot_0"
    stateMap[key]=idleActions
    local ok=pcall(rig.setState,rig,key)
    if ok then
      raw.time=0
      raw.done=false
      raw.requestedAnim="idle"
      return 0
    end
  end

  if type(raw.setAnimation)=="function" then
    pcall(raw.setAnimation,raw,family=="special" and "special" or "physical")
  end
  return nil
end

local function playExactXDFaint(raw)
  if not raw then return nil end
  local rig=raw.rig
  local model=rig and rig.model
  local stateMap=model and model.stateMap
  local actions=slotActions(raw,10)
  if rig and type(rig.setState)=="function" and type(stateMap)=="table" and actions then
    local key="_cbe_xd_faint_slot_10"
    stateMap[key]=actions
    local ok=pcall(rig.setState,rig,key)
    if ok then
      -- IMPORTANT: old Gen1DX386 providers had an update bug specifically when
      -- requestedAnim=="faint" (they indexed a boolean state capability as a
      -- metadata table and then pcall swallowed the error). Use a private one-shot
      -- tag here so the provider continues advancing rig:update(), while CBE owns
      -- completion using the authored rig duration.
      raw.time=0
      raw.done=false
      raw.animName="xd_faint_slot10"
      raw.requestedAnim="xd_faint_slot10"
      if rig then rig.loop=false;rig.hold=true end
      return actions[1]
    end
  end
  return nil
end

function Actor:attack(moveId,move)
  -- A defender in its authored Damage reaction cannot fight back or have the
  -- reaction overwritten by a late move_used event. Realtime recovery decides
  -- when a new attack may begin.
  if self.state=="hit" or self.state=="hurt" or self.state=="faint" or self.state=="recall" then return self end
  self.state="attack"
  self.stateAge=0
  self.lastMove=moveId

  local family,slot,variant,typ=retailMoveSlot(moveId,move)
  self.lastXDMoveType=typ
  self.lastXDFamily=family
  self.lastXDVariant=variant
  self.lastXDSlot=playExactXDSlot(self.raw,slot,family)
  return self
end

function Actor:hit(payload)
  if self.state=="faint" or self.state=="recall" then return self end
  if self.state=="hit" or self.state=="hurt" then return self end
  self.state="hit";self.stateAge=0
  if self.raw and type(self.raw.setAnimation)=="function" then pcall(self.raw.setAnimation,self.raw,"hurt") end
  return self
end

function Actor:faint()
  if self.state=="faint" then return self end
  -- Lethal damage still gets a complete Damage/hurt beat before the native XD
  -- faint bank. BattleState may emit battle.fainted while hit is still playing;
  -- queue it instead of replacing the reaction on that same frame.
  if self.state=="hit" or self.state=="hurt" then self.pendingFaint=true;return self end
  self.pendingFaint=false
  self.state="faint";self.stateAge=0
  local raw=self.raw
  -- XD PKX slot 10 is resolved separately for every species in DX386pack.
  -- Play that exact native clip instead of relying on the provider's generic
  -- semantic faint path. This also bypasses the frame-0 freeze in older
  -- 368ImporterDXs; completion is still governed by rig:duration().
  local clip=playExactXDFaint(raw)
  self.lastXDFaintClip=clip
  if not clip and raw and type(raw.setAnimation)=="function" then
    pcall(raw.setAnimation,raw,"faint")
  end
  return self
end

function Actor:recall(reason)
  self.state="recall";self.stateAge=0;self.recallReason=reason;self.recallScale=1
  if self.raw and type(self.raw.setAnimation)=="function" then pcall(self.raw.setAnimation,self.raw,"idle") end
  return self
end

function Actor:setRecallScale(v)
  self.recallScale=math.max(0,math.min(1,tonumber(v) or 0))
  if self.raw and type(self.raw.setPresentationScale)=="function" then pcall(self.raw.setPresentationScale,self.raw,self.recallScale) end
  if self.raw and type(self.raw.setVisible)=="function" then pcall(self.raw.setVisible,self.raw,self.recallScale>0.001) end
  return self
end

function Actor:stateDuration(kind)
  local r=self.raw
  if r and r.rig and type(r.rig.duration)=="function" then
    local ok,d=pcall(r.rig.duration,r.rig)
    if ok and tonumber(d) then return math.max(0.12,tonumber(d)) end
  end
  return kind=="faint" and 0.9 or 0.8
end

function Actor:terminalDuration(kind) return self:stateDuration(kind) end

function Actor:terminalComplete()
  if self.state=="recall" then
    return (self.recallScale~=nil and self.recallScale<=0.001) or self.stateAge>=0.55
  end
  if self.state=="faint" then
    return (self.raw and self.raw.done==true) or self.stateAge>=self:stateDuration("faint")
  end
  return false
end

function Actor:update(dt)
  dt=math.max(0,tonumber(dt) or 0)
  self.stateAge=(self.stateAge or 0)+dt
  local r=self.raw
  if self.state=="recall" and self.recallScale==nil and r and type(r.setPresentationScale)=="function" then
    local s=math.max(0,1-self.stateAge/0.45);pcall(r.setPresentationScale,r,s)
  end
  if r and type(r.update)=="function" then pcall(r.update,r,dt) end
  if self.state=="attack" or self.state=="hit" then
    local was=self.state
    local finished=(r and r.done==true)
      or (self.stateAge>=self:stateDuration(self.state)+0.04)
      or (r and r.requestedAnim=="idle")
    if finished then
      if was=="hit" and self.pendingFaint then
        self.pendingFaint=false
        self:faint()
      else
        self.state="idle";self.stateAge=0
        if r and type(r.setAnimation)=="function" and r.requestedAnim~="idle" then
          pcall(r.setAnimation,r,"idle")
        end
      end
    end
  end
  return self
end

function Actor:remove(reason)
  if self.removed then return true end
  self.removed=true
  if self._shadowMesh and self._shadowMesh.release then pcall(self._shadowMesh.release,self._shadowMesh) end
  self._shadowMesh=nil
  local r=self.raw
  self.raw=nil
  if r and type(r.destroy)=="function" then pcall(r.destroy,r) end
  return true
end
function Actor:release() return self:remove("release") end

local service={
  version=1,portable=true,priority=95000,worldUnits=false,
}

function service.selected(context)
  return modelsEnabled(context)
end

function service.available(source,dex)
  dex=tonumber(dex)
  if not (dex and dex>=1 and dex<=386) then return false end
  local api=dxApi()
  if not api then return false end
  if type(api.available)=="function" then
    local ok,v=pcall(api.available,dex)
    if ok and v==false then return false end
  end
  return true
end

function service.acquire(source,dex,variant,opts)
  local context=opts and opts.context
  local api=dxApi(context)
  if not api then return nil,"368ImporterDX is not loaded" end
  if not modelsEnabled(context) then return nil,"XD battle models disabled" end
  local ok,raw,err=pcall(api.createActor,dex,{manual=true,visible=true,fullLore=true})
  if not ok then return nil,tostring(raw) end
  if not raw then return nil,tostring(err or "DX model unavailable") end
  return Actor.new(raw,dex,variant,opts)
end

function service.withRenderer(vp,callback,opts)
  local sh,err=ensureShader()
  if not sh then return false,err end
  local g=love and love.graphics
  if not g then return false,"LOVE graphics unavailable" end
  local okPush,pushErr=pcall(g.push,"all")
  if not okPush then return false,pushErr end
  local previousContext=rendererContext
  rendererContext=opts and opts.context or nil
  local ok,result=pcall(function()
    g.setDepthMode("lequal",true)
    g.setBlendMode("alpha","alphamultiply")
    if g.setMeshCullMode then g.setMeshCullMode("none") end
    g.setShader(sh)
    sh:send("vp","row",vp)
    sh:send("toonMode",toonEnabled(rendererContext) and 1 or 0)
    return callback()
  end)
  rendererContext=previousContext
  pcall(g.setShader)
  pcall(g.setDepthMode)
  pcall(g.pop)
  if not ok then return false,result end
  return result
end

function service.status()
  local api,h=dxApi()
  return {ready=api~=nil,provider=h and h.id or nil,shaderError=shaderError,toonBattle=toonEnabled(),dropShadows=true}
end

A.service=service
A.Actor=Actor
function A:install(currentSpriteModels)
  if provider then return true end
  provider=service
  if currentSpriteModels and type(currentSpriteModels.registerCapability)=="function" then
    local ok,err=currentSpriteModels.registerCapability(providerOwner,"battleActors",service)
    if ok then
      log("info","Gen1DX386 battle actor adapter registered")
      return true
    end
    log("warn","Gen1DX386 battle actor adapter registration failed: %s",tostring(err))
    return false,err
  end
  return false,"CurrentSpriteModels capability registry unavailable"
end
return A
