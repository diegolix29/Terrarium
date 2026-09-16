local P={version=2}

local SQRT3_INV=0.577350259
local ROT_18=0.314159274
local ROT_30=0.523703516
local ROT_36=0.628318548
local ROT_54=0.942477882
local ROT_63=1.09955740
local ROT_72=1.25663710
local ROT_90=1.57079637
local MODE1_START_LATERAL=10.0
local MODE1_LATERAL_MIN=25.0
local MODE1_LATERAL_SPAN=10.0
local MODE1_HEIGHT_MIN=1.0
local MODE1_HEIGHT_SPAN=9.0
local MODE1_DISTANCE_MIN=20.0
local MODE1_DISTANCE_SPAN=30.0
local MODE4_ROTATION=0.47123894
local MODE4_DISTANCE=110.0
local MODE4_HEIGHT=25.0
local MODE4_RANGE2=12725.0
local MODE5_ROTATION=0.7853982

local CLASS={
  [-2]={size=1.1,distance=.875},[-1]={size=1.1,distance=.875},
  [1]={size=1.25,distance=1.4},[2]={size=1.29999995,distance=1.8},
  [3]={size=1.5,distance=3.0},
}

local function has(flags,mask)
  flags=math.max(0,math.floor(tonumber(flags) or 0));mask=math.max(1,math.floor(tonumber(mask) or 1))
  return math.floor(flags/mask)%2==1
end

local function classFor(selector)
  return CLASS[tonumber(selector)] or {size=1.20000005,distance=1.0}
end

local function rotationBand(flags,selector)
  local mode=tonumber(selector) or 0
  if has(flags,0x01) then return 0,ROT_30 end
  if has(flags,0x02) then return ROT_18,ROT_36 end
  if has(flags,0x04) then
    if mode>0 then return ROT_18,ROT_36 end
    return ROT_36,ROT_54
  end
  if has(flags,0x08) then
    if mode>0 then return ROT_36,ROT_54 end
    return ROT_54,ROT_72
  end
  if has(flags,0x10) then return ROT_72,ROT_90 end
  if mode>0 then return ROT_18,ROT_54 end
  return ROT_18,ROT_63
end

-- Public because battleCameraStartRandom feeds Pokemon owners through the same
-- CalculateParams rotation grammar with sequence=NULL. Passive Camera can use
-- this dimensionless source angle safely before the remaining owner target/radius
-- scale seams are exact.
function P.rotationBand(flags,selector)
  if tonumber(selector)==nil then return nil,"retail ModelSequence class unavailable" end
  local lo,hi=rotationBand(flags,selector)
  return lo,hi
end

local function distanceBand(flags)
  if has(flags,0x20) then return 25,35,6,8 end
  if has(flags,0x40) then return 35,50,6,11 end
  if has(flags,0x80) then return 50,60,6,20 end
  return 20,60,6,20
end

local function vec3(v)
  if type(v)~="table" then return nil end
  local x,y,z=tonumber(v[1]),tonumber(v[2]),tonumber(v[3])
  if not (x and y and z) then return nil end
  return x,y,z
end

-- Exact GC6E01 _wazaSequenceCameraCalculateParams arithmetic.  The returned
-- envelope is exact only when the caller supplies the retail ModelSequence class
-- and the exact frame-0 GSmodel bound.  Random sampling performed later by
-- DoPosition is deliberately outside this helper.
function P.calculate(flags,selector,retailBound,rotationBase)
  local src=type(retailBound)=="table" and retailBound.source or nil
  local minx,miny,minz=vec3(src and src.min)
  local maxx,maxy,maxz=vec3(src and src.max)
  local ex,ey,ez=vec3(src and src.extent)
  if not (minx and maxx and ex) then return nil,"retail GSmodel bound unavailable" end
  if retailBound.exact~=true or retailBound.selectorExact~=true then return nil,"retail GSmodel bound is not exact" end
  if tonumber(selector)==nil then return nil,"retail ModelSequence class unavailable" end

  local cls=classFor(selector)
  local rmin,rmax=rotationBand(flags,selector)
  local dmin,dmax,lower,upper=distanceBand(flags)
  dmin=dmin*cls.distance;dmax=dmax*cls.distance

  local hmin,hmax=miny,maxy
  if hmin<lower then
    hmin=lower
    if hmax<lower then hmax=1.5*lower end
  end
  if hmax>upper then
    hmax=upper
    if hmin>upper then hmin=.800000012*upper end
  end

  local magnitude=math.sqrt(ex*ex+ey*ey+ez*ez)
  local scaleMin=SQRT3_INV*magnitude*cls.size
  local scaleMax=ey*cls.size

  if dmin<20 then dmin=20 end
  if dmax<40 then dmax=40 end
  if dmin>48 then dmin=48 end
  if dmax>60 then dmax=60 end

  return {
    exact=true,formula="GC6E01 _wazaSequenceCameraCalculateParams",
    selector=tonumber(selector),sizeScale=cls.size,distanceScale=cls.distance,
    rotationMin=rmin,rotationMax=rmax,rotationBase=tonumber(rotationBase) or 0,
    heightMin=hmin,heightMax=hmax,distanceMin=dmin,distanceMax=dmax,
    scaleMin=scaleMin,scaleMax=scaleMax,
  }
end

function P.mode5Distance(selector)
  return 50*classFor(selector).distance
end

function P.motionOptions(flags,modelId)
  -- `modelId` here means ModelSequence+0x70: the PokemonData.pkxDataId passed to
  -- fn_801DE190, not National Dex and not PKX sequenceKind. A direct GC6E01
  -- common_rel read finds pkxDataId 0x13A exactly once: PokemonData internal row
  -- 314 has numPokemon 321. Thus the forced mode-4 owner is National Dex 321.
  -- Mt. Battle can legitimately present that Colosseum-backed Hoenn actor even
  -- when the host cartridge generation is I/II, so never confuse host generation
  -- with the live owner's retail resource identity.
  if tonumber(modelId)==0x13A then return {4},true,"model-sequence-id-0x13A" end
  if has(flags,0x1) then return {5},true,"waza-flag-0x1" end
  local out={}
  if has(flags,0x08) then out[#out+1]=3 end
  if has(flags,0x10) then out[#out+1]=0 end
  if has(flags,0x20) then out[#out+1]=1 end
  if has(flags,0x40) then out[#out+1]=2 end
  if #out==0 then out={3,0,1,2} end
  return out,#out==1,"waza-option-mask"
end

-- The camera selector has only one source-special Pokemon resource. A direct
-- GC6E01 PokemonStats scan found exactly one pkxDataId==0x13A row and its
-- numPokemon is 321 (Wailord). We therefore do not invent the rest of the
-- shuffled Hoenn pkxDataId table merely to execute this selector: dex 321 gets
-- the proven resource id, every other supported species follows the flag path.
function P.motionOptionsForPokemonDex(flags,dex)
  dex=tonumber(dex)
  return P.motionOptions(flags,dex==321 and 0x13A or nil)
end

function P.mode4()
  return {distance=MODE4_DISTANCE,height=MODE4_HEIGHT,rotation=MODE4_ROTATION,range=math.sqrt(MODE4_RANGE2),exact=true}
end

local function unitDraw(draw,key)
  local value=tonumber(draw and draw(key)) or 0
  if value<0 then return 0 end
  if value>=1 then return 0.999999999999 end
  return value
end
local function mix(a,b,t)return a+(b-a)*t end
local function range3(a,b,c)
  return {near=a,mid=b,far=c}
end

-- Scalar geometry used by GC6E01 _wazaSequenceCameraDoPosition.  This helper
-- deliberately injects the random draws: the formula/constants are exact, but
-- CBE does not own Colosseum's shared HSD_Randf stream and therefore must not
-- claim that the selected sample is the same sample retail would have drawn.
--
-- Angles returned here are owner/fight-axis magnitudes.  WazaHandlers owns the
-- arena-space side transform so the same retail camera grammar scales/rotates
-- cleanly with CBE arenas instead of assuming Colosseum's original world axes.
function P.sampleMotion(mode,params,draw,opts)
  if type(params)~="table" or params.exact~=true then return nil,"retail camera params unavailable" end
  mode=tonumber(mode)
  if mode==nil then return nil,"retail camera motion unavailable" end
  opts=type(opts)=="table" and opts or nil
  local rotationBase=tonumber(opts and opts.rotationBase)
  if rotationBase==nil then rotationBase=tonumber(params.rotationBase) end
  local reverse=opts and opts.reverse
  local out={mode=mode,scalarFormulaExact=true,rngExact=false}
  if rotationBase~=nil and reverse~=nil then
    out.rotationBase=rotationBase;out.reverse=reverse==true;out.worldRotationFormulaExact=true
  end
  local hmin,hmax=tonumber(params.heightMin),tonumber(params.heightMax)
  local dmin,dmax=tonumber(params.distanceMin),tonumber(params.distanceMax)
  local rmin,rmax=tonumber(params.rotationMin),tonumber(params.rotationMax)
  if not (hmin and hmax and dmin and dmax and rmin and rmax) then
    return nil,"retail camera parameter band incomplete"
  end

  if mode==0 then
    -- _wazaSequenceCameraDoDollyPosition first chooses whether the two sampled
    -- radii run far->near or near->far (70% alternate gate), then samples the
    -- two radii, height and yaw. Timing/random-delay draws affect *when* the
    -- move finishes, not these endpoints, so they remain outside this helper.
    local alternate=unitDraw(draw,"dolly-alternate")<=0.7
    local a=mix(dmin,dmax,unitDraw(draw,"dolly-distance-a"))
    local b=mix(dmin,dmax,unitDraw(draw,"dolly-distance-b"))
    local near,far=a,b
    if alternate then if a<b then near,far=b,a end
    elseif a>b then near,far=b,a end
    local height=mix(hmin,hmax,unitDraw(draw,"height"))
    local angle=mix(rmin,rmax,unitDraw(draw,"rotation-a"))
    out.distance0=near;out.distance1=far;out.height=height
    out.rotation0=angle;out.rotation1=angle;out.dollyAlternate=alternate
    if out.worldRotationFormulaExact then
      local world=rotationBase+(reverse and -angle or angle)
      out.worldRotation0=world;out.worldRotation1=world
    end
    out.fovRange=range3(math.sqrt(near*near+height*height),
      math.sqrt(((near+far)*.5)^2+height*height),math.sqrt(far*far+height*height))
    out.fovRangeFormulaExact=true
    return out
  end

  if mode==1 then
    -- Retail starts ten source units off-axis, then moves a further 25..35.
    -- The previous CBE reconstruction incorrectly started at zero lateral and
    -- therefore understated the authored angle throughout the shot.
    local lateral=MODE1_LATERAL_MIN+MODE1_LATERAL_SPAN*unitDraw(draw,"mode1-lateral")
    local height=MODE1_HEIGHT_MIN+MODE1_HEIGHT_SPAN*unitDraw(draw,"height")
    local distance=MODE1_DISTANCE_MIN+MODE1_DISTANCE_SPAN*unitDraw(draw,"distance")
    local near=math.sqrt(lateral*lateral+height*height)
    local far=math.sqrt(distance*distance+near*near)
    out.distance0=distance;out.distance1=distance;out.height=height
    out.lateral0=MODE1_START_LATERAL;out.lateral1=MODE1_START_LATERAL+lateral
    out.rotation0=0;out.rotation1=0
    if reverse~=nil then
      -- Mode 1 is the exceptional global-axis shot: retail sets rotY=0, then
      -- shifts camera direction X by +/-10 and a further +/-25..35. Preserve
      -- those exact world-axis angles separately from owner-relative modes.
      local sign=reverse and 1 or -1
      out.worldRotation0=math.atan(sign*MODE1_START_LATERAL/distance)
      out.worldRotation1=math.atan(sign*(MODE1_START_LATERAL+lateral)/distance)
      out.worldRotationFormulaExact=true;out.rotationBase=nil
    end
    out.fovRange=range3(near,.5*(near+far),far)
    out.fovRangeFormulaExact=true
    return out
  end

  if mode==2 then
    local distance=mix(dmin,dmax,unitDraw(draw,"distance"))
    local height=mix(hmin,hmax,unitDraw(draw,"height"))
    local ra,rb=unitDraw(draw,"rotation-a"),unitDraw(draw,"rotation-b")
    local a=mix(rmin,rmax,ra)
    local b=mix(rmin,rmax,rb)
    if a>b then a,b=b,a end
    local near=math.sqrt(distance*distance+height*height)
    out.distance0=distance;out.distance1=distance;out.height=height
    out.rotation0=a;out.rotation1=b
    if out.worldRotationFormulaExact then
      local function world(r)
        if reverse then return (rmin-rmax)*r+(rmin-rotationBase) end
        return (rmax-rmin)*r+(rotationBase+rmin)
      end
      local wa,wb=world(ra),world(rb);if wa>wb then wa,wb=wb,wa end
      out.worldRotation0=wa;out.worldRotation1=wb
      -- Retail writes out_far from the *absolute* cameraSetRotY endpoint, not
      -- the owner-relative range sample.  This distinction matters whenever
      -- GSmodel.rotation.y is non-zero (the common battle case).
      local far=math.sqrt(wb*wb+near*near)
      out.fovRange=range3(near,.5*(near+far),far)
      out.fovRangeFormulaExact=true
    else
      -- Position/range-band sampling above remains source-formula exact, but the
      -- FOV radius cannot be reconstructed exactly without the owner's absolute
      -- GSmodel yaw/reverse state. Preserve a useful source-shaped proxy without
      -- advertising the DoPosition output tuple as exact.
      local far=math.sqrt(b*b+near*near)
      out.fovRange=range3(near,.5*(near+far),far)
      out.fovRangeFormulaExact=false
    end
    return out
  end

  if mode==3 then
    local distance=mix(dmin,dmax,unitDraw(draw,"distance"))
    local height=mix(hmin,hmax,unitDraw(draw,"height"))
    local rr=unitDraw(draw,"rotation-a")
    local angle=mix(rmin,rmax,rr)
    out.distance0=distance;out.distance1=distance;out.height=height
    out.rotation0=angle;out.rotation1=angle
    if out.worldRotationFormulaExact then
      local world
      if reverse then world=(rotationBase-rmin)*rr-(rotationBase-rmin)
      else world=(rmax-rmin)*rr+(rotationBase+rmin) end
      out.worldRotation0=world;out.worldRotation1=world
      -- Like mode 2, retail's length includes the absolute cameraSetRotY value.
      local length=math.sqrt(distance*distance+height*height+world*world)
      out.fovRange=range3(length,length,length);out.fovRangeFormulaExact=true
    else
      local length=math.sqrt(distance*distance+height*height+angle*angle)
      out.fovRange=range3(length,length,length);out.fovRangeFormulaExact=false
    end
    return out
  end

  if mode==4 then
    local length=math.sqrt(MODE4_RANGE2)
    out.distance0=MODE4_DISTANCE;out.distance1=MODE4_DISTANCE;out.height=MODE4_HEIGHT
    out.rotation0=MODE4_ROTATION;out.rotation1=MODE4_ROTATION;out.fovRange=range3(length,length,length);out.fovRangeFormulaExact=true
    if out.worldRotationFormulaExact then
      local world=rotationBase+(reverse and -MODE4_ROTATION or MODE4_ROTATION)
      out.worldRotation0=world;out.worldRotation1=world
    end
    return out
  end

  if mode==5 then
    local distance=P.mode5Distance(params.selector)
    local height=mix(hmin,hmax,unitDraw(draw,"height"))
    local length=math.sqrt(distance*distance+height*height+MODE5_ROTATION*MODE5_ROTATION)
    out.distance0=distance;out.distance1=distance;out.height=height
    out.rotation0=MODE5_ROTATION;out.rotation1=MODE5_ROTATION;out.fovRange=range3(length,length,length);out.fovRangeFormulaExact=true
    if out.worldRotationFormulaExact then
      local world=rotationBase+(reverse and -MODE5_ROTATION or MODE5_ROTATION)
      out.worldRotation0=world;out.worldRotation1=world
    end
    return out
  end
  return nil,"unsupported retail camera motion"
end

return P
