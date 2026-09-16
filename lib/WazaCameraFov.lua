-- Source-backed GC6E01 procedural Waza FOV pattern grammar.
--
-- Data source:
--   wazaSequenceCamera.c::wazaSequenceCameraGetPattern__Fbi
--   wazaSequenceCamera.c::_wazaSequenceCameraDoFOV
--   wazaSequenceCamera.c::_wazaSequenceCameraSelectDuration__FUcPff
--   data_8036E150.c::lbl_80371F60 / lbl_803721C0
--
-- This module deliberately does NOT own the retail shared RNG stream or the
-- GSmodel-bound-derived FOV endpoints.  Callers supply random samples and lens
-- endpoints; table choice, forced rows, descriptor grammar and timing are exact.
local F={version=1}

local function D(mode,durationMode,a,b,c,d,initialFlags,flags,timingMode)
  return {mode=mode,durationMode=durationMode,thresholds={a,b,c,d},
    initialFlags=initialFlags,flags=flags,timingMode=timingMode}
end
local Z=D(0,0,0,0,0,0,0,0,0)

F.short={
  {weight=.20,descriptors={D(3,13,.20,0,.70,.10,6,1,1),D(4,5,.80,0,.20,0,0,2,1)}},
  {weight=.25,descriptors={D(3,13,.30,0,.40,.30,4,2,2),Z}},
  {weight=.20,descriptors={D(1,0,0,0,0,0,1,0,0),D(4,5,.80,0,.20,0,0,2,1)}},
  {weight=.10,descriptors={D(4,13,.10,0,.20,.70,1,2,2),Z}},
  {weight=.05,descriptors={D(1,0,0,0,0,0,1,0,0),Z}},
  {weight=.05,descriptors={D(1,0,0,0,0,0,2,0,0),Z}},
  {weight=.05,descriptors={D(1,0,0,0,0,0,4,0,0),Z}},
  {weight=.10,descriptors={D(4,2,0,1,0,0,1,2,2),Z}},
}

F.long={
  {weight=.15,descriptors={D(4,13,.70,0,.15,.15,1,2,1),Z}},
  {weight=.20,descriptors={D(4,5,.80,0,.20,0,1,2,1),D(3,12,.50,0,0,.50,0,1,1)}},
  {weight=.05,descriptors={D(3,5,.70,0,.30,0,6,1,1),D(4,13,.20,0,.50,.30,0,6,1)}},
  {weight=.05,descriptors={D(3,5,.80,0,.20,0,4,3,1),D(4,13,.20,0,.50,.30,0,4,1)}},
  {weight=.05,descriptors={D(3,5,.70,0,.30,0,6,1,1),Z}},
  {weight=.15,descriptors={D(3,5,.70,0,.30,0,4,2,1),Z}},
  {weight=.10,descriptors={D(1,0,0,0,0,0,2,0,0),D(3,12,.70,0,0,.30,0,1,1)}},
  {weight=.05,descriptors={D(1,0,0,0,0,0,1,0,0),D(4,13,.10,0,.70,.20,0,6,1)}},
  {weight=.10,descriptors={D(1,0,0,0,0,0,2,0,0),D(4,13,.10,0,.70,.20,0,4,1)}},
  {weight=.05,descriptors={D(1,0,0,0,0,0,1,0,0),Z}},
  {weight=.05,descriptors={D(1,0,0,0,0,0,2,0,0),Z}},
  {weight=.05,descriptors={D(1,0,0,0,0,0,4,0,0),Z}},
  -- Retail normal weighted selection cannot reach this row (weight 0), but the
  -- fallback random-index path can, so it remains part of the exact table.
  {weight=0,descriptors={D(2,0,0,0,0,0,0,0,0),D(3,12,0,0,0,0,4,3,1)}},
}

local function bit(v,mask)
  v=math.max(0,math.floor(tonumber(v) or 0));return math.floor(v/mask)%2==1
end

function F.tableFor(sequenceKind)
  local k=tonumber(sequenceKind)
  if k==8 or k==9 then return F.long,"long" end
  return F.short,"short"
end

-- Return 1-based row plus how retail reached it. `rand01` and `randIndex` are
-- injected because CBE intentionally does not claim ownership of the shared
-- retail battle RNG stream.
function F.selectPattern(sequenceKind,flags,rand01,randIndex)
  local rows,name=F.tableFor(sequenceKind)
  -- Retail calls fn_800E0BE4 before checking the forced flag rows. Keep that
  -- draw in the injected RNG contract even though forced selection ignores it.
  -- Retail fn_800E0BE4 is HSD_Randf: u16/65536, so production draws are
  -- naturally in [0,1). Do not renormalise the table: the long rows really sum
  -- to 1.05, making its trailing weighted row unreachable except via a forced
  -- flag. Keep values above 1 usable only for source-branch unit coverage of
  -- the otherwise unreachable fallback-index code path.
  local r=tonumber(rand01 and rand01()) or 0
  if name=="short" then
    if bit(flags,0x20) then return rows[5],5,name,"forced-0x20" end
    if bit(flags,0x40) then return rows[6],6,name,"forced-0x40" end
    if bit(flags,0x80) then return rows[7],7,name,"forced-0x80" end
  else
    if bit(flags,0x20) then return rows[10],10,name,"forced-0x20" end
    if bit(flags,0x40) then return rows[11],11,name,"forced-0x40" end
    if bit(flags,0x80) then return rows[12],12,name,"forced-0x80" end
  end
  local finish=0
  for i,row in ipairs(rows) do
    finish=finish+(tonumber(row.weight) or 0)
    if r<finish then return row,i,name,"weighted" end
  end
  local n=#rows
  local idx=math.floor(tonumber(randIndex and randIndex(n)) or 0)%n+1
  return rows[idx],idx,name,"fallback-index"
end

function F.mixBand(flags)
  local startValue,endValue=0,1
  local hasFirst,hasSecond=false,false
  if bit(flags,1) then startValue=0;endValue=.20;hasFirst=true end
  if bit(flags,2) then if not hasFirst then startValue=.35 end;endValue=.60;hasSecond=true end
  if bit(flags,4) then if not hasSecond then startValue=.75 end;endValue=1 end
  return startValue,endValue
end

local function capped(duration,limit)return math.min(math.max(0,duration),limit) end
function F.selectDuration(mode,thresholds,duration,rand01)
  mode=math.floor(tonumber(mode) or 0);duration=math.max(0,math.floor(tonumber(duration) or 0))
  thresholds=type(thresholds)=="table" and thresholds or {0,0,0,0}
  if mode==1 then return capped(duration,12) end
  if mode==2 then return capped(duration,20) end
  if mode==4 then return capped(duration,45) end
  if mode==8 then return duration end
  local r=tonumber(rand01 and rand01()) or 0
  if mode==3 then return r<(thresholds[1] or 0) and capped(duration,12) or capped(duration,20) end
  if mode==5 then return r<(thresholds[1] or 0) and capped(duration,12) or capped(duration,45) end
  if mode==9 then return r<(thresholds[1] or 0) and capped(duration,12) or duration end
  if mode==6 then return r<(thresholds[2] or 0) and capped(duration,20) or capped(duration,45) end
  if mode==10 then return r<(thresholds[2] or 0) and capped(duration,20) or duration end
  if mode==12 then return r<(thresholds[3] or 0) and capped(duration,45) or duration end
  if mode==7 then
    if r<(thresholds[1] or 0) then return capped(duration,12) end
    if r<(thresholds[2] or 0) then return capped(duration,20) end
    return capped(duration,45)
  end
  if mode==11 then
    if r<(thresholds[1] or 0) then return capped(duration,12) end
    if r<(thresholds[2] or 0) then return capped(duration,20) end
    return duration
  end
  if mode==13 then
    if r<(thresholds[1] or 0) then return capped(duration,12) end
    if r<(thresholds[3] or 0) then return capped(duration,45) end
    return duration
  end
  if mode==14 then
    if r<(thresholds[2] or 0) then return capped(duration,12) end
    if r<(thresholds[3] or 0) then return capped(duration,20) end
    return duration
  end
  if mode==15 then
    if r<(thresholds[1] or 0) then return capped(duration,12) end
    if r<(thresholds[2] or 0) then return capped(duration,12) end
    if r<(thresholds[3] or 0) then return capped(duration,20) end
  end
  return duration
end

function F.staticChoice(paramsFlags)
  if bit(paramsFlags,0x20) then return 1 end
  if bit(paramsFlags,0x80) then return 4 end
  return 2
end

function F.usesPattern(motion)
  motion=tonumber(motion)
  return not (motion==0 or motion==4 or motion==5)
end

-- Build the two-key retail timing plan. `timing.frames` are the exact runtime
-- row values before battleCameraStartWaza's +0x75-dependent shift. GC6E01
-- pokemonCreateSequence creates Pokémon owners with +0x75=1 (frameShift=0),
-- while fightTrainerCreateSequence creates +0x75=0 owners (frameShift=1).
function F.plan(sequenceKind,paramsFlags,motion,timing,rand01,randIndex)
  timing=type(timing)=="table" and timing or {}
  local count=math.floor(tonumber(timing.count or timing.cameraTimingCount) or 0)
  local frames=timing.frames or timing.cameraTimingFrames or {}
  local shift=math.max(0,math.floor(tonumber(timing.frameShift) or 0))
  local scale=2^shift
  local frame0=(tonumber(frames[1]) or 0)*scale
  if not F.usesPattern(motion) then
    return {patternUsed=false,static=true,frame0=frame0,count=count,frameShift=shift,
      initialFlags=F.staticChoice(paramsFlags),segments={}}
  end
  local row,rowIndex,tableName,selection=F.selectPattern(sequenceKind,paramsFlags,rand01,randIndex)
  local first=row.descriptors[1]
  local out={patternUsed=true,static=false,row=row,rowIndex=rowIndex,tableName=tableName,selection=selection,
    frame0=frame0,count=count,frameShift=shift,initialFlags=first.initialFlags,segments={}}
  if count<=2 then return out end
  local prev=tonumber(frames[1]) or 0
  for i=1,2 do
    local nextFrame=tonumber(frames[i+1]) or prev
    local desc=row.descriptors[i]
    local segment={descriptor=desc,from=prev*scale,to=nextFrame*scale,hold=true}
    if prev~=nextFrame and desc.mode>=3 and desc.mode<5 then
      -- Retail selects duration BEFORE left-shifting the camera-key frames.
      local duration=F.selectDuration(desc.durationMode,desc.thresholds,nextFrame-prev,rand01)
      segment.duration=duration*scale;segment.hold=false
      if desc.timingMode==2 then
        segment.startFrame=(nextFrame-duration)*scale;segment.endFrame=nextFrame*scale
      else
        segment.startFrame=prev*scale;segment.endFrame=(prev+duration)*scale
      end
    else
      segment.startFrame=prev*scale;segment.endFrame=nextFrame*scale
    end
    out.segments[i]=segment;prev=nextFrame
  end
  return out
end

return F
