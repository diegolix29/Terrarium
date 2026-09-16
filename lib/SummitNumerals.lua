-- Floor geometry in the measured Platform-100 proportions. 0 and 1 are
-- lifted from the resident retail mesh; the other digits extend its rounded
-- stroke vocabulary. No menu font, outline, plaque, or raster decal.
local N={}
local function curve(points,a,b,c,d)
  for i=1,16 do
    local t=i/16;local s=1-t
    points[#points+1]={s*s*s*a[1]+3*s*s*t*b[1]+3*s*t*t*c[1]+t*t*t*d[1],
      s*s*s*a[2]+3*s*s*t*b[2]+3*s*t*t*c[2]+t*t*t*d[2]}
  end
end
local function path(start,segments)
  local p={start}
  for _,seg in ipairs(segments) do
    if #seg==2 then p[#p+1]=seg
    else curve(p,p[#p],{seg[1],seg[2]},{seg[3],seg[4]},{seg[5],seg[6]}) end
  end
  return p
end
local function ellipse(cx,cy,rx,ry)
  local p={}
  for i=0,64 do local a=i*math.pi/32;p[#p+1]={cx+rx*math.cos(a),cy+ry*math.sin(a)} end
  return p
end
local strokes={
 [2]={path({.07,.23},{{.08,.01,.47,-.01,.49,.22},{.53,.43,.18,.57,.07,.93},{.51,.93}})},
 [3]={path({.07,.19},{{.15,-.01,.48,.00,.49,.22},{.49,.39,.39,.46,.25,.46},
   {.43,.46,.52,.55,.50,.74},{.48,1.01,.14,1.01,.06,.81}})},
 [4]={path({.40,1},{{.40,.04}}),path({.40,.04},{{.04,.68},{.55,.68}})},
 [5]={path({.50,.07},{{.11,.07},{.08,.48},{.26,.36,.52,.43,.51,.70},{.52,1.00,.17,1.02,.06,.81}})},
 [6]={path({.48,.16},{{.36,-.05,.04,.02,.06,.60}}),ellipse(.285,.705,.225,.235)},
 [7]={path({.035,.07},{{.53,.07},{.35,.33,.23,.63,.18,.97}})},
 [8]={ellipse(.285,.265,.215,.205),ellipse(.285,.725,.235,.215)},
}
strokes[9]={}
for _,p in ipairs(strokes[6]) do local q={};for _,v in ipairs(p) do q[#q+1]={.57-v[1],1-v[2]} end;strokes[9][#strokes[9]+1]=q end
local function strokeTriangles(p,out)
  local left,right={},{};local half=.06
  for i,v in ipairs(p) do
    local a,b=p[math.max(1,i-1)],p[math.min(#p,i+1)]
    local dx,dy=b[1]-a[1],b[2]-a[2];local len=math.max(1e-9,math.sqrt(dx*dx+dy*dy))
    local nx,ny=-dy/len*half,dx/len*half
    left[i]={v[1]+nx,v[2]+ny};right[i]={v[1]-nx,v[2]-ny}
  end
  for i=1,#p-1 do
    for _,v in ipairs({left[i],right[i],right[i+1],left[i],right[i+1],left[i+1]}) do out[#out+1]=v end
  end
end
function N.build(number,source,center,extent,scale)
  number=math.max(1,math.min(100,math.floor(tonumber(number) or 1)))
  if number==100 then return nil end -- unchanged authored DObj
  local digits={};local h=extent[3];local minx=center[1]-extent[1]/2
  local minz=center[3]-h/2
  -- Native glyphs occupy separate X islands: 1, 0, 0.
  local native={[0]={},[1]={}};local lo={[0]=math.huge,[1]=math.huge};local hi={[0]=-math.huge,[1]=-math.huge}
  for i=1,#source,3 do
    local a,b,c=source[i],source[i+1],source[i+2]
    local x=(a[1]+b[1]+c[1])/3;local digit
    if x<minx+extent[1]*.23 then digit=1
    elseif x<minx+extent[1]*.64 then digit=0 end
    if digit then for _,v in ipairs({a,b,c}) do
      native[digit][#native[digit]+1]=v;lo[digit]=math.min(lo[digit],v[1]);hi[digit]=math.max(hi[digit],v[1])
    end end
  end
  local total=0;local gap=h*.095
  for char in tostring(number):gmatch('.') do
    local d=tonumber(char);local width=(d==0 or d==1) and (hi[d]-lo[d]) or h*.57
    if width<=0 or width==math.huge or width==-math.huge then return nil end
    digits[#digits+1]={digit=d,width=width};total=total+width
  end
  total=total+gap*(#digits-1)
  local x=center[1]-total/2;local rows={};scale=scale or 1
  local function vertex(px,pz,u,v,color)
    rows[#rows+1]={px*scale,center[2]*scale+.012,pz*scale,u,v,
      color and color[6] or 1,color and color[7] or 1,color and color[8] or 1,color and color[9] or 1,0,1,0}
  end
  for _,g in ipairs(digits) do
    if native[g.digit] then
      for _,v in ipairs(native[g.digit]) do vertex(x+v[1]-lo[g.digit],v[3],v[4],v[5],v) end
    else
      local points={};for _,p in ipairs(strokes[g.digit]) do strokeTriangles(p,points) end
      local lx,ly,hx,hy=math.huge,math.huge,-math.huge,-math.huge
      for _,p in ipairs(points) do lx=math.min(lx,p[1]);ly=math.min(ly,p[2]);hx=math.max(hx,p[1]);hy=math.max(hy,p[2]) end
      for _,p in ipairs(points) do
        local nx,ny=(p[1]-lx)/(hx-lx),(p[2]-ly)/(hy-ly)
        local px,pz=x+nx*g.width,minz+ny*h
        -- Repeated source paint, at the native floor's approximate texel density.
        vertex(px,pz,nx*.7125,ny*1.25)
      end
    end
    x=x+g.width+gap
  end
  return rows
end
return N
