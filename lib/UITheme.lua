-- Primary/secondary UI chrome only. No shaders, image tinting, or model work.
-- DEFAULT returns every original channel exactly; HP/EXP, types, statuses,
-- Pokemon art, trainer art and battle-side target rings keep their own colors.
local T=... or {}
local C={}
local presets={
  gold={.72,.58,.30},red={.78,.18,.16},orange={.90,.43,.12},
  yellow={.88,.72,.14},green={.19,.62,.30},cyan={.14,.65,.70},
  blue={.18,.42,.78},purple={.48,.27,.68},pink={.82,.37,.57},
  brown={.47,.30,.17},gray={.46,.47,.45},white={.91,.91,.87},black={.08,.08,.07},
}
local roleKeys={surface='uiPrimaryColor',trim='uiPrimaryColor',
  selection='uiSecondaryColor',accent='uiSecondaryColor'}
local epoch,primary,secondary
local caches={};local builds,hits,resets=0,0,0
local function refresh()
  local current=T.epoch and T.epoch() or 0
  if epoch==current then return end
  epoch=current
  local p=T.get and T.get('uiPrimaryColor') or 'default'
  local s=T.get and T.get('uiSecondaryColor') or 'default'
  -- Invalid/removed presets fail open to the original palette, never an error.
  p=presets[p] and p or 'default';s=presets[s] and s or 'default'
  if p~=primary or s~=secondary then
    primary,secondary=p,s;caches={};resets=resets+1
  end
end
function C.invalidate() epoch=nil end
function C.color(role,r,g,b,a)
  a=a==nil and 1 or a
  if not roleKeys[role] then return r,g,b,a end
  refresh()
  local name=roleKeys[role]=='uiPrimaryColor' and primary or secondary
  local tint=presets[name]
  if not tint then return r,g,b,a end
  -- Numeric nested keys avoid allocating a concatenated RGBA string per draw.
  -- Alpha is not cached: animated fades reuse the same RGB shade.
  local cache=caches[role]
  if not cache then cache={count=0,rows={}};caches[role]=cache end
  local red=cache.rows[r];local green=red and red[g];local shade=green and green[b]
  if not shade then
    if cache.count>=256 then cache.rows={};cache.count=0;red=nil;green=nil end
    local peak=math.max(tint[1],tint[2],tint[3])
    local value=math.max(r,g,b)*(.55+.45*peak)
    local nr=value*(.12+.88*tint[1]/peak)
    local ng=value*(.12+.88*tint[2]/peak)
    local nb=value*(.12+.88*tint[3]/peak)
    -- White/yellow selection fills must not erase the unchanged pale labels.
    -- Metallic edges and pointers are allowed to remain bright.
    if role=='surface' or role=='selection' then
      local luma=.2126*nr+.7152*ng+.0722*nb
      local cap=role=='surface' and .27 or .32
      if luma>cap then local k=cap/luma;nr,ng,nb=nr*k,ng*k,nb*k end
    end
    shade={nr,ng,nb};builds=builds+1;cache.count=cache.count+1
    if not red then red={};cache.rows[r]=red end
    if not green then green={};red[g]=green end
    green[b]=shade
  else hits=hits+1 end
  return shade[1],shade[2],shade[3],a
end
function C.status()
  refresh()
  local count=0;for _,cache in pairs(caches) do count=count+cache.count end
  return {primary=primary,secondary=secondary,shadeBuilds=builds,shadeHits=hits,
    cachedShades=count,limitPerRole=256,resets=resets}
end
return C
