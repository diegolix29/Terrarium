-- ORRE OPEN SEA / original environment, using retained GC6E01 source textures.
-- v7: continuous ocean plus substantial sandbar mounds for ALL battle anchors.
-- Ground remains y=0; water is lowered locally, not the actors/camera.
-- No source disc assets are bundled; all four texture paths use existing caches.
local groups={}
local function V(x,y,z,u,v,r,g,b,a)
  return {x,y,z,u or 0,v or 0,r or 1,g or 1,b or 1,a or 1}
end
local function G(role,tex,w,h,diff,xlu)
  local g={role=role,vertices={},alpha=1,xlu=xlu==true,noz=false,
    -- The packed mesh reconstructs vertex-alpha use from this compatibility bit.
    renderFlags=xlu==true and 1073741824 or 0,
    useVertexColor=true,useDiffuseLighting=true,
    diffuse=diff or {1,1,1},ambient={.34,.40,.45},specular={.01,.02,.025},shininess=8}
  if tex then g.texture={path=tex,w=w,h=h,wrapS=1,wrapT=1,mipmaps=true} end
  groups[#groups+1]=g;return g
end
local function T(g,a,b,c)
  g.vertices[#g.vertices+1]=a;g.vertices[#g.vertices+1]=b;g.vertices[#g.vertices+1]=c
end
local function Q(g,a,b,c,d)T(g,a,b,c);T(g,a,c,d)end
local function RING(g,cx,cz,r0,r1,y,n,uv,tint,edgeAlpha)
  tint=tint or {1,1,1,1};uv=uv or .018;n=n or 40
  for i=0,n-1 do
    local a,b=2*math.pi*i/n,2*math.pi*(i+1)/n
    local function p(r,t,alpha)
      local x,z=cx+math.cos(t)*r,cz+math.sin(t)*r
      return V(x,y,z,x*uv,z*uv,tint[1],tint[2],tint[3],alpha)
    end
    -- Counter-clockwise when viewed from above: upward normals, no black caps.
    if r0==0 then T(g,p(0,a,tint[4]),p(r1,b,edgeAlpha or tint[4]),p(r1,a,edgeAlpha or tint[4]))
    else Q(g,p(r0,a,tint[4]),p(r0,b,tint[4]),p(r1,b,edgeAlpha or tint[4]),p(r1,a,edgeAlpha or tint[4])) end
  end
end
local function DISC(g,cx,cz,r,y,n,uv,tint)
  tint=tint or {1,1,1,1};uv=uv or .018;n=n or 40
  local c=V(cx,y,cz,cx*uv,cz*uv,tint[1],tint[2],tint[3],tint[4])
  for i=0,n-1 do
    local a,b=2*math.pi*i/n,2*math.pi*(i+1)/n
    local function p(t)
      local x,z=cx+math.cos(t)*r,cz+math.sin(t)*r
      return V(x,y,z,x*uv,z*uv,tint[1],tint[2],tint[3],tint[4])
    end
    T(g,c,p(b),p(a))
  end
end
local WATER_A='cache/stages/water/source/tex_081b60_256x256_f14.rgba'
local WATER_B='cache/stages/water/source/tex_0cdb60_256x256_f14.rgba'
local STONE='cache/stages/water/source/tex_05db60_512x512_f14.rgba'
local ROCK='cache/stages/d2_crater/textures/tex_0ce920_256x256_f14.rgba'

-- The atmosphere belongs to the world, not a fixed screen-space horizon stripe.
-- Distant geometry is cheap: 96 angular sectors, no new textures/render targets.
local sky=G('sky',nil,nil,nil,{1,1,1},false)
sky.useDiffuseLighting=false
local latitudes={-.20,-.06,0,.018,.055,.10,.18,.32,.55,.86,math.pi*.5}
local skyRadius=6150
local function skyPoint(a,e)
  local y=math.sin(e);local r=math.cos(e)*skyRadius
  local u=math.max(0,math.min(1,y/.70));u=u*u*(3-2*u)
  local c={.285+(.075-.285)*u,.430+(.205-.430)*u,.520+(.365-.520)*u}
  -- Broad, low-contrast cloud banks are baked into the dome's vertex colours;
  -- no alpha cards, fake moon disc or camera-relative layers.
  local bank=math.max(0,math.cos(a*3+.55)*.55+math.sin(a*7-1.2)*.30+.15)
  local cloud=bank*math.max(0,1-math.abs(y-.065)/.07)*.19
  for k=1,3 do c[k]=c[k]+((k==3 and .77 or .74)-c[k])*cloud end
  return V(math.cos(a)*r,y*skyRadius,math.sin(a)*r,0,0,c[1],c[2],c[3],1)
end
for l=1,#latitudes-1 do for j=0,95 do
  local a,b=j*math.pi/48,(j+1)*math.pi/48
  Q(sky,skyPoint(a,latitudes[l]),skyPoint(b,latitudes[l]),
    skyPoint(b,latitudes[l+1]),skyPoint(a,latitudes[l+1]))
end end

-- One depth-writing, continuous water sheet. Source atlas alpha is NOT coverage
-- for this authored ocean: the Water Colosseum atlas contains effect linework.
-- Normal animation is shader-only; surface Y never crosses the platform tops.
local WATER_Y=-3.8
local ocean=G('ocean',WATER_A,256,256,{.14,.30,.39},false)
ocean.flow=1
local rings={0,50,100,160,250,400,650,1100,2000,3500,6000}
for i=1,#rings-1 do RING(ocean,0,0,rings[i],rings[i+1],WATER_Y,96,.0055) end

-- Two connected, solid sandbar mounds replace six small tiled circles. Each
-- Pokemon anchor has a 68-raw-unit dry footprint (17 world units), in every
-- direction; the overlapping footprints form ONE mesh per side with no layered
-- coplanar discs. Both singles centers are included, not left between two pads.
-- This exceeds the standard 3.45 * 6.90 world-unit maximum-axis body policy's
-- half-diagonal. Attack lunges/flying animations are intentionally not confined.
-- Presenter.actorAnchor uses a 16-actor-unit spread at this venue's .36 figure
-- scale. Convert its perpendicular offset back to raw (.25 stage-scale) units.
-- Regression tests compare these roots against the actual presenter function.
local battleDistance=math.sqrt(9.6^2+35^2)
local spread=math.max(9,math.min(16,(battleDistance/.36)*.28))*.36
local sideX,sideZ=(35/battleDistance)*spread,(9.6/battleDistance)*spread
local BATTLE_PADS={
  {kind='pokemon',slot='player-left',cx=(-4.8-sideX)/.25,cz=(17.5-sideZ)/.25,r=68},
  {kind='pokemon',slot='player-right',cx=(-4.8+sideX)/.25,cz=(17.5+sideZ)/.25,r=68},
  {kind='pokemon',slot='enemy-left',cx=(4.8+sideX)/.25,cz=(-17.5+sideZ)/.25,r=68},
  {kind='pokemon',slot='enemy-right',cx=(4.8-sideX)/.25,cz=(-17.5-sideZ)/.25,r=68},
  {kind='trainer',slot='player-trainer',cx=56,cz=116,r=24},
  {kind='trainer',slot='enemy-trainer',cx=-56,cz=-116,r=24},
}
local SINGLE_PADS={
  {kind='pokemon',slot='player-single',cx=-19.2,cz=70,r=68},
  {kind='pokemon',slot='enemy-single',cx=19.2,cz=-70,r=68},
}
-- Vertex-coloured sand does not inherit the source masonry atlas's dark tile
-- stripes or artificial concentric inlays. Quiet broad colour variation remains
-- stable under mobile minification; no new image/import dependency is needed.
local tops=G('platform-tops',nil,nil,nil,{1,.97,.90})
local edges=G('platform-edges',nil,nil,nil,{.88,.88,.84})
tops.ambient={.53,.53,.48};edges.ambient={.45,.48,.45}
local foam=G('contact-foam',nil,nil,nil,{.65,.78,.80},true)
foam.alpha=.28
local landforms={}
local nx,nz=-9.6/battleDistance,35/battleDistance
for side=1,2 do
  local sign=side==1 and 1 or -1
  local cx,cz=-19.2*sign,70*sign
  local supports=side==1 and {BATTLE_PADS[1],BATTLE_PADS[2],BATTLE_PADS[5],SINGLE_PADS[1]}
    or {BATTLE_PADS[3],BATTLE_PADS[4],BATTLE_PADS[6],SINGLE_PADS[2]}
  local outline={};local n=128;local seed=side*2.31
  -- A polar union is well-defined here: the single center lies inside both
  -- Pokemon support discs. The trainer lobe also overlaps the main bar.
  for j=0,n-1 do
    local a=j*math.pi*2/n;local ux,uz=math.cos(a),math.sin(a);local radius=0
    for _,pad in ipairs(supports) do
      local dx,dz=pad.cx-cx,pad.cz-cz
      local dot=dx*ux+dz*uz;local rr=pad.r+1.0
      local disc=rr*rr-(dx*dx+dz*dz-dot*dot)
      if disc>=0 then radius=math.max(radius,dot+math.sqrt(disc)) end
    end
    radius=radius*(1+.006*(1+math.sin(a*5+seed))+.004*(1+math.cos(a*3-seed)))
    local x,z=cx+ux*radius,cz+uz*radius
    -- Reserve a continuous central water channel. The dry boundary still lies
    -- beyond every 68-unit required footprint; only the extra shoreline varies.
    local inner=sign*(x*nx+z*nz)
    if inner<4 then x=x+sign*nx*(4-inner);z=z+sign*nz*(4-inner) end
    outline[#outline+1]={x,z}
  end
  landforms[#landforms+1]={side=side==1 and 'player' or 'enemy',outline=outline,groundY=0}
  local function sand(x,z,t)
    local mott=.013*math.sin(x*.10+seed)*math.cos(z*.08)+.009*math.sin(x*.035-z*.065)
    local edge=math.max(0,(t-.72)/.28)
    return V(x,0,z,0,0,.77+mott-.045*edge,.72+mott-.036*edge,.57+mott-.021*edge,1)
  end
  -- Flat continuous dry core, with color detail but NO geometric dips beneath
  -- feet/tails. All ring vertices share exact edges, so there are no floor holes.
  local rings={0,.20,.40,.60,.78,1}
  for k=1,#rings-1 do for j=1,n do
    local q,r=outline[j],outline[j%n+1]
    local function p(point,t)return sand(cx+(point[1]-cx)*t,cz+(point[2]-cz)*t,t)end
    if k==1 then T(tops,p(q,0),p(r,rings[k+1]),p(q,rings[k+1]))
    else Q(tops,p(q,rings[k]),p(r,rings[k]),p(r,rings[k+1]),p(q,rings[k+1])) end
  end end
  local steps={{1,0},{1.025,-.38},{1.060,-1.50},{1.105,WATER_Y+.02},{1.145,WATER_Y-1.25}}
  local function shore(point,scale,y)
    local x,z=cx+(point[1]-cx)*scale,cz+(point[2]-cz)*scale
    local minimum=4-(scale-1)/.105*2.65
    minimum=math.max(.65,minimum)
    local inner=sign*(x*nx+z*nz)
    if inner<minimum then x=x+sign*nx*(minimum-inner);z=z+sign*nz*(minimum-inner) end
    local wet=math.min(1,math.max(0,-y/-WATER_Y))
    local mott=.008*math.sin(x*.11+z*.09)
    return V(x,y,z,0,0,.73-.30*wet+mott,.69-.25*wet+mott,.55-.16*wet+mott,1)
  end
  for k=1,#steps-1 do for j=1,n do
    local q,r=outline[j],outline[j%n+1];local a,b=steps[k],steps[k+1]
    Q(edges,shore(q,a[1],a[2]),shore(r,a[1],a[2]),shore(r,b[1],b[2]),shore(q,b[1],b[2]))
  end end
  -- Closed submerged underside, so free look never exposes a hollow ring.
  for j=1,n do
    local last=steps[#steps];local q,r=outline[j],outline[j%n+1]
    T(edges,V(cx,last[2],cz,0,0,.40,.43,.40,1),shore(q,last[1],last[2]),shore(r,last[1],last[2]))
    local function f(point,index,outer)
      local v=shore(point,outer and 1.120 or 1.106,WATER_Y+.045)
      local pulse=.5+.5*math.sin(index*.23+seed)
      v[6]=.82;v[7]=.94;v[8]=1;v[9]=outer and 0 or (.12+.19*pulse)
      return v
    end
    Q(foam,f(q,j,false),f(r,j+1,false),f(r,j+1,true),f(q,j,true))
  end
end

-- Local shallow-water colour, not a second full-screen scrolling surface.
local shoal=G('shoals',WATER_B,256,256,{.14,.37,.42},true)
shoal.alpha=.10;shoal.flow=.25
for _,p in ipairs({{-107,19,26,57},{105,26,24,52},{-157,103,31,70},{149,-108,34,76}}) do
  RING(shoal,p[1],p[2],p[3],p[4],WATER_Y+.045,40,.007,{.70,.95,1,.60},0)
end

-- Eroded basalt shoulders with offset crowns; no repeated cone silhouettes.
local rock=G('basalt-stacks',ROCK,256,256,{.42,.49,.53})
local coast=G('basalt-shores',ROCK,256,256,{.35,.44,.48})
local profile={1,1.02,.91,.94,.69,.65,.36}
local function stack(cx,cz,rx,rz,h,seed)
  local rows={};local n=18
  for l=1,#profile do
    local t=(l-1)/(#profile-1);rows[l]={}
    for j=0,n-1 do
      local a=math.pi*2*j/n
      local erosion=1+.11*math.sin(a*3+seed)+.06*math.cos(a*5-seed*.7)
      local r=profile[l]*erosion
      local x=cx+math.cos(a)*rx*r+t*rx*.17*math.sin(seed)
      local z=cz+math.sin(a)*rz*r+t*rz*.15*math.cos(seed)
      local y=WATER_Y-1.4+t*(h-WATER_Y)+math.sin(a*2+seed)*t*h*.055
      rows[l][j+1]=V(x,y,z,x*.015+y*.006,z*.015,.79+t*.09,.87+t*.07,.92+t*.05,1)
    end
  end
  for l=1,#rows-1 do for j=1,n do local k=j%n+1
    Q(rock,rows[l][j],rows[l][k],rows[l+1][k],rows[l+1][j])
  end end
  local c=V(cx+rx*.17*math.sin(seed),h-1.4,cz+rz*.15*math.cos(seed),cx*.015,cz*.015,.88,.94,.97,1)
  for j=1,n do T(rock,c,rows[#rows][j%n+1],rows[#rows][j]) end
  -- Low irregular shoulders connect the stack to the sea; not floating props.
  for j=0,35 do
    local a,b=j*math.pi/18,(j+1)*math.pi/18
    local function p(t,outer)
      local r=(outer and 1.58 or .92)*(1+.08*math.sin(t*4+seed))
      return V(cx+math.cos(t)*rx*r,outer and (WATER_Y-.12) or .70,cz+math.sin(t)*rz*r,
        (cx+math.cos(t)*rx*r)*.016,(cz+math.sin(t)*rz*r)*.016,.76,.88,.94,1)
    end
    Q(coast,p(a,false),p(b,false),p(b,true),p(a,true))
  end
end
local islands={
  {-276,211,43,32,25,1},{288,-217,49,36,31,2},{-410,-255,66,43,40,3},
  {445,292,61,44,35,4},{-585,95,81,49,53,5},{600,-75,76,47,46,6},
  {-672,407,87,57,62,7},{695,-398,90,61,65,8},{184,606,64,42,38,9},
  {-182,-638,69,45,41,10},{-490,540,52,34,30,11},{525,-566,57,37,35,12},
  {-1530,-960,210,110,94,13},{1760,900,240,126,100,14},{-1090,1980,290,142,111,15},
}
for i,p in ipairs(islands) do
  stack(p[1],p[2],p[3],p[4],p[5],p[6])
  if i<=8 then stack(p[1]+p[3]*1.18,p[2]+p[4]*.45,p[3]*.56,p[4]*.64,p[5]*.35,p[6]+19) end
end

-- Weathered masonry stays low and nestled in the shoreline, not bright isolated
-- white boxes. Geometry retains the original route's Orre/Phenac material link.
local ruins=G('shore-masonry',STONE,512,512,{.43,.51,.54})
local function block(cx,cz,w,d,h,yaw)
  local cs,sn=math.cos(yaw),math.sin(yaw)
  local function p(x,y,z,u,v)
    return V(cx+x*cs-z*sn,y,cz+x*sn+z*cs,u,v,.77,.88,.94,1)
  end
  local a,b,c,d0=-w/2,w/2,-d/2,d/2
  Q(ruins,p(a,-.1,c,0,1),p(b,-.1,c,1,1),p(b,h,c,1,0),p(a,h,c,0,0))
  Q(ruins,p(b,-.1,c,0,1),p(b,-.1,d0,1,1),p(b,h,d0,1,0),p(b,h,c,0,0))
  Q(ruins,p(b,-.1,d0,0,1),p(a,-.1,d0,1,1),p(a,h,d0,1,0),p(b,h,d0,0,0))
  Q(ruins,p(a,-.1,d0,0,1),p(a,-.1,c,1,1),p(a,h,c,1,0),p(a,h,d0,0,0))
  Q(ruins,p(a,h,c,0,1),p(a,h,d0,0,0),p(b,h,d0,1,0),p(b,h,c,1,1))
end
for _,p in ipairs({{-371,-254,17,12,10,.22},{-350,-248,12,10,6,.38},
  {491,296,18,11,9,-.31},{511,310,11,9,5,-.45}}) do block(p[1],p[2],p[3],p[4],p[5],p[6]) end
local total=0;for _,g in ipairs(groups) do total=total+#g.vertices end
return {version=7,prototype=false,
  source='Original Orre Open Sea / Pokemon Colosseum GC6E01 Water Colosseum water and stone + Mt. Battle rock',
  bounds={min={-6200,-1230,-6200},max={6200,6200,6200}},battlePads=BATTLE_PADS,singlePads=SINGLE_PADS,landforms=landforms,waterY=WATER_Y,
  fidelity='two solid sandbar mounds supporting singles, doubles and trainers / continuous mipmapped source-water surface / world-space marine sky and haze / eroded basalt shores / clear cross-arena move lanes',
  groupCount=#groups,vertexCount=total,groups=groups}
