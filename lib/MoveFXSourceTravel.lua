-- GC6E01 source-derived cross-arena Waza travel envelopes.
--
-- Particle spans come from the exact MoveFXVM execution of retail GPT1 banks
-- (three deterministic source RNG probes, filtered by CommonMoveData power/contact
-- and one-way forward anisotropy). Model spans come from decoded Type-2 HSD union
-- bounds. Profiles are keyed by the retail Waza row identity, never by a generic
-- move-type effect. Target-local/spherical rows therefore remain untouched.
local T={version=1,particle={},model={}}

T.particle[16]={
  {phase="attack",sourceBank=1,state=0,selector=3,span=64},
  {phase="sp1",sourceBank=1,state=0,selector=3,span=64},
}
T.particle[51]={
  {phase="attack",sourceBank=1,state=1,selector=8,span=50.738856},
}
T.particle[52]={
  {phase="attack",sourceBank=1,state=0,selector=9,span=59.96109},
}
T.particle[53]={
  {phase="attack",sourceBank=1,state=0,selector=23,span=68.8398249544812},
  {phase="sp1",sourceBank=1,state=0,selector=23,span=68.8398249544812},
}
T.particle[55]={
  {phase="attack",sourceBank=1,state=0,selector=24,span=60},
  {phase="sp1",sourceBank=1,state=0,selector=24,span=60},
}
T.particle[56]={
  {phase="attack",sourceBank=1,state=2,selector=2,span=44.991898},
  {phase="kamex",sourceBank=1,state=2,selector=2,span=44.991898},
}
T.particle[58]={
  {phase="attack",sourceBank=1,state=2,selector=5,span=22.176686},
  {phase="attack",sourceBank=1,state=2,selector=8,span=16.408567},
}
T.particle[59]={
  {phase="attack",sourceBank=1,state=2,selector=8,span=17.425083},
  {phase="attack",sourceBank=1,state=2,selector=11,span=57},
  {phase="attack",sourceBank=1,state=2,selector=12,span=25},
  {phase="sp1",sourceBank=1,state=2,selector=8,span=17.425083},
  {phase="sp1",sourceBank=1,state=2,selector=11,span=57},
  {phase="sp1",sourceBank=1,state=2,selector=12,span=25},
}
T.particle[60]={
  {phase="attack",sourceBank=1,state=0,selector=3,span=62.754002},
  {phase="attack",sourceBank=1,state=1,selector=8,span=86.794304},
}
T.particle[61]={
  {phase="attack",sourceBank=1,state=0,selector=22,span=64.9999976158142},
  {phase="sp1",sourceBank=1,state=0,selector=22,span=64.9999976158142},
}
T.particle[75]={
  {phase="attack",sourceBank=1,state=0,selector=1,span=524.49282},
}
T.particle[82]={
  {phase="attack",sourceBank=1,state=0,selector=1,span=11.772286},
  {phase="sp1",sourceBank=1,state=0,selector=1,span=11.772286},
}
T.particle[126]={
  {phase="attack",sourceBank=1,state=0,selector=1,span=85.987244},
  {phase="sp1",sourceBank=1,state=0,selector=1,span=85.987244},
}
T.particle[129]={
  {phase="attack",sourceBank=1,state=2,selector=5,span=10},
}
T.particle[145]={
  {phase="attack",sourceBank=1,state=0,selector=19,span=190.221431},
  {phase="sp1",sourceBank=1,state=0,selector=19,span=190.221431},
}
T.particle[149]={
  {phase="attack",sourceBank=1,state=0,selector=2,span=62.732923},
}
T.particle[177]={
  {phase="attack",sourceBank=1,state=0,selector=1,span=55.68},
}
T.particle[181]={
  {phase="attack",sourceBank=1,state=1,selector=9,span=37.999994},
  {phase="freezer",sourceBank=1,state=1,selector=9,span=37.999994},
}
T.particle[188]={
  {phase="attack",sourceBank=1,state=0,selector=1,span=80},
}
T.particle[190]={
  {phase="attack",sourceBank=1,state=0,selector=45,span=60},
}
T.particle[192]={
  {phase="attack",sourceBank=1,state=1,selector=25,span=293.910843},
  {phase="pikachu",sourceBank=1,state=1,selector=25,span=293.910843},
}
T.particle[247]={
  {phase="attack",sourceBank=1,state=1,selector=1,span=40.467037},
}
T.model[41]={
  {phase="attack",identifier=1,reach=64.946254},
  {phase="spear",identifier=2,reach=64.946254},
}
T.model[42]={
  {phase="attack",identifier=2,reach=50.917926},
  {phase="thunders",identifier=2,reach=50.917926},
}
T.model[49]={
  {phase="attack",identifier=1,reach=48.464948},
  {phase="rarecoil",identifier=1,reach=48.464948},
}
T.model[56]={
  {phase="attack",identifier=6,reach=45.12059},
  {phase="kamex",identifier=6,reach=45.12059},
  {phase="kamex",identifier=14,reach=45.12059},
}
T.model[58]={
  {phase="attack",identifier=8,reach=103.135382},
}
T.model[62]={
  {phase="attack",identifier=1,reach=103.450305},
}
T.model[63]={
  {phase="attack",identifier=5,reach=50.643943},
}
T.model[76]={
  {phase="attack",identifier=3,reach=50.643943},
  {phase="sp1",identifier=3,reach=50.643943},
}
T.model[121]={
  {phase="attack",identifier=2,reach=66.915412},
  {phase="nassy",identifier=2,reach=66.915412},
}
T.model[125]={
  {phase="attack",identifier=1,reach=50.236504},
}
T.model[131]={
  {phase="attack",identifier=1,reach=74.843784},
  {phase="parshen",identifier=1,reach=74.843784},
}
T.model[140]={
  {phase="attack",identifier=1,reach=43.03456},
  {phase="nassy",identifier=1,reach=43.03456},
}
T.model[155]={
  {phase="attack",identifier=1,reach=72.966136},
}
T.model[196]={
  {phase="attack",identifier=1,reach=97.329194},
}
T.model[198]={
  {phase="attack",identifier=1,reach=50.236504},
}
T.model[217]={
  {phase="attack",identifier=1,reach=62.357916},
  {phase="purin",identifier=1,reach=62.357916},
  {phase="sp1",identifier=1,reach=62.357916},
}
T.model[250]={
  {phase="attack",identifier=2,reach=87.846789},
}

for _,rows in pairs(T.particle) do for _,row in ipairs(rows) do row.sourceExact=true end end

local function phase(v)return tostring(v or "attack"):lower()end
function T.particleProfile(moveId,entry)
  local rows=T.particle[tonumber(moveId)];if type(rows)~="table" or type(entry)~="table" then return nil end
  local ph=phase(entry.phase);local bank=tonumber(entry.sourceBank);local state=tonumber(entry.state) or 0
  local selector=tonumber(entry.selector~=nil and entry.selector or entry.rootRef)
  for _,row in ipairs(rows) do
    if phase(row.phase)==ph and tonumber(row.sourceBank)==bank and tonumber(row.state)==state and tonumber(row.selector)==selector then return row end
  end
end
function T.modelProfile(moveId,entry)
  local rows=T.model[tonumber(moveId)];if type(rows)~="table" or type(entry)~="table" then return nil end
  local ph=phase(entry.phase);local id=tonumber(entry.identifier or entry.index)
  for _,row in ipairs(rows) do if phase(row.phase)==ph and tonumber(row.identifier)==id then return row end end
end
return T
