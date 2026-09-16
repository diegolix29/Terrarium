-- GC6E01 retail trainer/sendout throw ownership evidence.
--
-- This module is deliberately data/validation only.  Runtime must not claim
-- exact trainer-ball playback until it can reproduce the Waza model's selector-4
-- attachment (position + rotation) from the trainer ModelSequence part matrix.
-- Existing native_v1 trainer caches serialize per-frame joint positions but not
-- the corresponding 3x4 part matrices, so position-only playback would guess
-- ball orientation and is intentionally left blocked.
local T={source="GC6E01",version=1}

-- ItemBallData rows 0..12.  Row 0 is the retail default/none row and is byte-
-- identical to POKE_BALL (row 4), so 13 table rows resolve to 12 unique banks.
-- fightTrainerBallThrowEffect reads field 0x11 == throwWzxDataId.
T.balls={
  {ballId=0,key="DEFAULT",stem="monsterball",throwWzxDataId=107,archive="wzx_throw_monster.fsys",fsysGroup=1553,member="throw_monster.wzx",resourceId=0x10722000},
  {ballId=1,key="MASTER_BALL",stem="masterball",throwWzxDataId=104,archive="wzx_throw_master.fsys",fsysGroup=1550,member="throw_master.wzx",resourceId=0x106F2000},
  {ballId=2,key="ULTRA_BALL",stem="hyperball",throwWzxDataId=105,archive="wzx_throw_hyper.fsys",fsysGroup=1551,member="throw_hyper.wzx",resourceId=0x10702000},
  {ballId=3,key="GREAT_BALL",stem="superball",throwWzxDataId=106,archive="wzx_throw_super.fsys",fsysGroup=1552,member="throw_super.wzx",resourceId=0x10712000},
  {ballId=4,key="POKE_BALL",stem="monsterball",throwWzxDataId=107,archive="wzx_throw_monster.fsys",fsysGroup=1553,member="throw_monster.wzx",resourceId=0x10722000},
  {ballId=5,key="SAFARI_BALL",stem="safariball",throwWzxDataId=108,archive="wzx_throw_safari.fsys",fsysGroup=1554,member="throw_safari.wzx",resourceId=0x10732000},
  {ballId=6,key="NET_BALL",stem="netball",throwWzxDataId=109,archive="wzx_throw_net.fsys",fsysGroup=1555,member="throw_net.wzx",resourceId=0x10742000},
  {ballId=7,key="DIVE_BALL",stem="diveball",throwWzxDataId=110,archive="wzx_throw_dive.fsys",fsysGroup=1556,member="throw_dive.wzx",resourceId=0x10752000},
  {ballId=8,key="NEST_BALL",stem="nestball",throwWzxDataId=111,archive="wzx_throw_nest.fsys",fsysGroup=1557,member="throw_nest.wzx",resourceId=0x10762000},
  {ballId=9,key="REPEAT_BALL",stem="repeatball",throwWzxDataId=112,archive="wzx_throw_repeat.fsys",fsysGroup=1558,member="throw_repeat.wzx",resourceId=0x10772000},
  {ballId=10,key="TIMER_BALL",stem="timerball",throwWzxDataId=113,archive="wzx_throw_timer.fsys",fsysGroup=1559,member="throw_timer.wzx",resourceId=0x10782000},
  {ballId=11,key="LUXURY_BALL",stem="gorgeousball",throwWzxDataId=114,archive="wzx_throw_gorgeus.fsys",fsysGroup=1560,member="throw_gorgeus.wzx",resourceId=0x107A2000},
  {ballId=12,key="PREMIER_BALL",stem="puremiyaball",throwWzxDataId=115,archive="wzx_throw_premiere.fsys",fsysGroup=1561,member="throw_premiere.wzx",resourceId=0x10792000},
}

-- All 12 unique throw WZX members parse as sequence kind 1 with exactly the
-- same ownership skeleton: static Type-2 ball model, source sound 1210, then a
-- zero-wait completion controller.  The model is unlinked and uses selector 4
-- (retail GSmodelAttachToGSpart position+rotation inheritance), attachment slot 7.
T.waza={sequenceKind=1,declaredCount=4,parsedCount=3,
  -- GC6E01 _wazaSequenceModelEntryStart passes runtime positionType directly to
  -- GSmodelAttachToGSpart. Selector 4 inherits position+rotation (not scale).
  model={kind="model",entryType=2,commonMode=2,positionType=4,attachmentSelector=4,attachment=7,partIndex=0,flags=0},
  sound={kind="sound",subtype=1210,flags=1},
  complete={kind="type1",subtype=0,controllerParam=0,flags=0},
}

-- The trainer's logical ModelSequence is separate from the ball WZX.  Waza
-- kind 1 selects ModelSequence row 1; in every supported A1 actor row 1 maps to
-- HSD animation index 2.  Attachment slot 7 then maps through row +0x4C to the
-- actor-specific GSmodel part below.  These values were decoded directly from
-- the GC6E01 PKX resource named by the sequence registry (lbl_80370840).
T.trainers={
  wes={archive="pkx_ken_a1.fsys",fsysGroup=157,resourceId=0x030C1E00,animationIndex=2,attachmentSlot=7,partIndex=2},
  red={archive="pkx_akami_m_a1.fsys",fsysGroup=1282,resourceId=0x0BDE1E00,animationIndex=2,attachmentSlot=7,partIndex=3},
  leaf={archive="pkx_akami_f_a1.fsys",fsysGroup=1281,resourceId=0x0BDD1E00,animationIndex=2,attachmentSlot=7,partIndex=49},
  brendan={archive="pkx_agb_m_a1.fsys",fsysGroup=895,resourceId=0x06FB1E00,animationIndex=2,attachmentSlot=7,partIndex=40},
  may={archive="pkx_agb_f_a1.fsys",fsysGroup=894,resourceId=0x06FA1E00,animationIndex=2,attachmentSlot=7,partIndex=45},
  cooltrainer_m={archive="pkx_traner_m_a1.fsys",fsysGroup=733,resourceId=0x058C1E00,animationIndex=2,attachmentSlot=7,partIndex=35},
  cooltrainer_f={archive="pkx_traner_f_a1.fsys",fsysGroup=732,resourceId=0x058B1E00,animationIndex=2,attachmentSlot=7,partIndex=41},
  dakim={archive="pkx_battleyama_a1.fsys",fsysGroup=1285,resourceId=0x0BE01E00,animationIndex=2,attachmentSlot=7,partIndex=45},
  nascour={archive="pkx_boss999_a1.fsys",fsysGroup=1289,resourceId=0x0BE41E00,animationIndex=2,attachmentSlot=7,partIndex=67},
  miror_b={archive="pkx_boss555_a1.fsys",fsysGroup=1287,resourceId=0x0BE21E00,animationIndex=2,attachmentSlot=7,partIndex=41},
}
T.sourceAnimRate=.5
T.runtimeExact=false
T.blocker="native_v1 now preserves source selector-4 part matrices, but exact runtime playback still requires HSD-equivalent fractional channel interpolation before matrix composition"

local function u32be(s,p)
  local a,b,c,d=s:byte(p,p+3);if not d then return nil end
  return ((a*256+b)*256+c)*256+d
end

-- Decode only the source fields needed to prove fightTrainerBallThrowEffect's
-- ItemBallData selection.  The caller supplies exactly the 13*48-byte table.
function T.decodeItemBallRows(bytes)
  if type(bytes)~="string" or #bytes<13*48 then return nil,"ItemBallData table truncated" end
  local out={}
  for id=0,12 do
    local p=id*48+1
    out[id]={
      inWzxDataId=u32be(bytes,p+4),openWzxDataId=u32be(bytes,p+8),outWzxDataId=u32be(bytes,p+12),
      downinWzxDataId=u32be(bytes,p+16),throwWzxDataId=u32be(bytes,p+20),
    }
  end
  return out
end

-- Decode ModelSequence row 1 from one decompressed PKX wrapper.  This mirrors
-- sequence.c fn_801DD5E8 + fn_801DF160 and fn_801D97F0 narrowly enough to prove
-- the throw animation and attachment part without interpreting unrelated rows.
function T.decodeTrainerThrowRow(bytes,attachmentSlot)
  if type(bytes)~="string" or #bytes<0x80 then return nil,"trainer PKX resource truncated" end
  local main,aux,count,_,loadMode=u32be(bytes,1),u32be(bytes,5),u32be(bytes,9),u32be(bytes,13),u32be(bytes,17)
  if not (main and aux and count and count>1 and loadMode) then return nil,"invalid ModelSequence header" end
  local start=(loadMode>=1 and loadMode<=4) and 0x20 or 0x40
  local alignedMain=math.floor((main+0x1F)/0x20)*0x20
  local alignedAux=math.floor((aux+0x1F)/0x20)*0x20
  local row=start+alignedMain+alignedAux+0xD0 -- source row 1, zero-based
  if row+0xD0>#bytes then return nil,"ModelSequence row 1 truncated" end
  local countB=u32be(bytes,row+4+1) or 0
  local anim
  for j=0,countB-1 do
    local kind=u32be(bytes,row+0x8C+j*8+1)
    local value=u32be(bytes,row+0x90+j*8+1)
    if kind==0 then anim=value;break end
  end
  local slot=tonumber(attachmentSlot) or 7
  if slot<0 or slot>15 then return nil,"attachment slot outside ModelSequence part table" end
  return {animationIndex=anim,partIndex=u32be(bytes,row+0x4C+slot*4+1),countB=countB,loadMode=loadMode,rowCount=count}
end

return T
