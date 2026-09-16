-- Measured screen-space Mt. Battle navigation for desktop, phones and foldables.
-- The historical filename is kept as a stable CBE module/injection seam.
-- This module only draws chrome. HubStage, native input and the challenge/save
-- state machines continue to own the live scene and every gameplay action.
local V=... or {}
local M={}
local H
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
function M.configure(helpers) H=helpers end
function M.active(viewport)
  if not H then return false end
  -- Use one font-measured renderer on every platform. The old desktop-only
  -- branch positioned three instructions in a fixed-height two-line box and
  -- bypassed every mobile containment test. Platform changes layout, not safety.
  return true
end

function M.layout(w,h,x,y,opts)
  opts=opts or {};x=x or 0;y=y or 0
  w=math.max(1,tonumber(w) or 390);h=math.max(1,tonumber(h) or 640)
  local portrait=w/h<1.35
  local desktop=H and not H.mobile and w>=900 and h>=500 and not portrait
  local s=desktop and clamp(math.min(w/1280,h/720),.85,1.8)
    or (portrait and clamp(math.min(w/420,h/580),.80,2.6)
    or clamp(math.min(w/844,h/350),.80,2.6))
  local margin=10*s;local gap=8*s;local pad=10*s
  local function height(px)
    local f=H and H.fontFor and H.fontFor(px)
    return math.ceil(f and f.getHeight and f:getHeight() or px*1.2)
  end
  local titleSize=math.max(18,21*s);local smallSize=math.max(11,12*s)
  local titleH,smallH=height(titleSize),height(smallSize)
  local subtitleY=5*s+titleH+2*s
  local headerH=subtitleY+smallH+5*s
  local tabH=(tonumber(opts.tabCount) or 0)>0 and (smallH+10*s) or 0
  local tabY=headerH+2*s
  if tabH>0 then headerH=headerH+tabH+7*s end
  local footerLines=clamp(tonumber(opts.footerLines) or 2,1,4)
  local footerLineH=smallH+2*s;local footerH=footerLineH*footerLines+6*s
  local teamH=opts.team~=false and math.max(70*s,smallH*3+16*s) or 0
  local innerW=math.max(1,w-margin*2)
  local L={x=x,y=y,w=w,h=h,s=s,portrait=portrait,desktop=desktop,pad=pad,gap=gap,
    labelSize=math.max(14,(opts.twoLineRows and 15 or 17)*s),bodySize=math.max(12,14*s),smallSize=smallSize,
    titleSize=titleSize,titleH=titleH,subtitleY=subtitleY,footerLineH=footerLineH,smallH=smallH,
    footerLines=footerLines,detailLines=clamp(opts.detailLines or 2,1,4),twoLineRows=opts.twoLineRows==true}
  L.labelH=height(L.labelSize)
  L.rowH=opts.twoLineRows and math.max(40*s,L.labelH+smallH+8*s) or 38*s
  L.header={x=x+margin,y=y+margin,w=innerW,h=headerH}
  if tabH>0 then L.tabs={x=L.header.x+pad,y=L.header.y+tabY,w=innerW-pad*2,h=tabH} end
  L.footer={x=x+margin,y=y+h-margin-footerH,w=innerW,h=footerH}
  local top=L.header.y+headerH+gap
  local bottom=L.footer.y-gap
  -- The rental/owned picker is a tall, narrow rail on foldables/tablets. It
  -- uses the former blank right half for the live arena, NOT a wider empty row.
  -- Narrow phones retain full-width readable rows plus a smaller scene band.
  local sideCatalog=opts.teamCatalog and w>=560
  if sideCatalog then
    -- Short landscape screens cannot stack tabs, two-line rows, detail,
    -- team and controls vertically. Keep a full readable row/detail pair;
    -- put the team in the already-reserved right lane rather than letting
    -- math.max(1, visible) push a row over its detail text.
    local minCard=pad*2+26*s+L.rowH+math.max(math.ceil(L.bodySize*1.22),height(L.bodySize)+math.ceil(s))
    local teamAtSide=teamH>0 and not portrait and bottom-top-teamH-gap<minCard
    if teamH>0 and not teamAtSide then L.team={x=x+margin,y=bottom-teamH,w=innerW,h=teamH};bottom=L.team.y-gap end
    local cardW=desktop and math.min(innerW*.36,460*s) or math.min(innerW*.49,450*s)
    L.card={x=x+margin,y=top,w=cardW,h=math.max(1,bottom-top)}
    local rx=L.card.x+cardW+gap;local rw=math.max(1,x+w-margin-rx)
    if teamAtSide then L.team={x=rx,y=bottom-teamH,w=rw,h=teamH} end
    L.clear={x=rx,y=top,w=rw,h=teamAtSide and math.max(0,L.team.y-gap-top) or L.card.h}
  elseif portrait then
    if teamH>0 then L.team={x=x+margin,y=bottom-teamH,w=innerW,h=teamH};bottom=L.team.y-gap end
    local heroH=h*((opts.focusedList or opts.teamCatalog) and .12 or .27)
    -- Minimum readable row/detail chrome wins on very short displays. Do not
    -- create negative list rectangles to preserve an arbitrary scene fraction.
    local minCard=pad*2+26*s+L.rowH+height(L.bodySize)
    heroH=math.max(0,math.min(heroH,bottom-top-minCard-gap))
    L.card={x=x+margin,y=top,w=innerW,h=math.max(1,bottom-top-heroH-gap)}
    L.clear={x=x+margin,y=top+L.card.h+gap,w=innerW,h=math.max(0,bottom-top-L.card.h-gap)}
  else
    local leftW=desktop and math.min(innerW*.36,460*s) or math.min(innerW*.405,430*s)
    L.card={x=x+margin,y=top,w=leftW,h=math.max(1,bottom-top)}
    local rx=L.card.x+leftW+gap;local rw=math.max(1,x+w-margin-rx)
    if teamH>0 then L.team={x=rx,y=bottom-teamH,w=rw,h=teamH} end
    L.clear={x=rx,y=top,w=rw,h=math.max(0,(L.team and L.team.y-gap or bottom)-top)}
  end
  L.lineH=math.max(math.ceil(L.bodySize*1.22),height(L.bodySize)+math.ceil(s))
  local chrome=pad*2+18*s+8*s
  local maxDetail=math.floor((L.card.h-chrome-L.rowH)/L.lineH)
  L.detailLines=math.max(1,math.min(L.detailLines,maxDetail))
  L.detailH=L.detailLines*L.lineH
  -- Content owns the card height, rather than a full-screen empty slab. Lists
  -- still scroll when space is tight; short menus release that space to Wes.
  if tonumber(opts.rowCount) and opts.rowCount>=0 then
    local needed=chrome+L.detailH+math.max(1,opts.rowCount)*L.rowH
    L.card.h=math.min(L.card.h,needed)
    if portrait and not sideCatalog then
      L.clear.y=L.card.y+L.card.h+gap
      L.clear.h=math.max(0,bottom-L.clear.y)
    end
  end
  L.visible=math.max(1,math.floor((L.card.h-chrome-L.detailH)/L.rowH))
  L.list={x=L.card.x+pad,y=L.card.y+pad+18*s,w=L.card.w-pad*2,h=L.visible*L.rowH}
  L.detail={x=L.card.x+pad,y=L.card.y+L.card.h-pad-L.detailH,w=L.card.w-pad*2,h=L.detailH}
  return L
end

function M.window(count,cursor,visible)
  count=math.max(0,math.floor(tonumber(count) or 0))
  cursor=clamp(math.floor(tonumber(cursor) or 1),1,math.max(1,count))
  visible=math.max(1,math.floor(visible or 1))
  local first=math.max(1,math.min(math.max(1,count-visible+1),cursor-math.floor(visible/2)))
  return first,math.min(count,first+visible-1),cursor
end

-- Remove complete UTF-8 code points, not arbitrary bytes. Long nicknames and
-- translated move labels are bounded using the real font's advance widths.
function M.ellipsize(value,size,width)
  value=tostring(value or ""):gsub("[\r\n]+"," ")
  local f=H.fontFor(size)
  local function measure(v) return f and f:getWidth(v) or #v*size*.55 end
  if measure(value)<=width then return value end
  local out="";local suffix="..."
  for cp in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if measure(out..cp..suffix)>width then break end
    out=out..cp
  end
  return measure(suffix)<=width and out..suffix or ""
end
function M.wrap(value,size,width)
  local lines={};local current="";local f=H.fontFor(size)
  local function measure(v) return f and f:getWidth(v) or #v*size*.55 end
  for paragraph in (tostring(value or "").."\n"):gmatch("(.-)\n") do
    for word in paragraph:gmatch("%S+") do
      local nextLine=current=="" and word or current.." "..word
      if current~="" and measure(nextLine)>width then lines[#lines+1]=current;current=word
      else current=nextLine end
    end
    if current~="" then lines[#lines+1]=current;current="" end
  end
  if #lines==0 then lines[1]="" end
  return lines
end
function M.line(g,value,r,size,color)
  local rendered=M.ellipsize(value,size,r.w)
  H.text(g,rendered,r.x,r.y,size,color)
  return rendered
end
function M.paragraph(g,value,r,size,lineH,maxLines,color)
  local lines=M.wrap(value,size,r.w)
  for i=1,math.min(#lines,maxLines) do
    local value=lines[i]
    if i==maxLines and #lines>maxLines then value=value.." ..." end
    M.line(g,value,{x=r.x,y=r.y+(i-1)*lineH,w=r.w},size,color)
  end
  return #lines<=maxLines
end

function M.draw(state,viewport,model)
  if not H then return false end
  local g=H.gfx();if not g then return false end
  model=model or {};local C=H.colors
  local x,y,w,h=H.safeArea(viewport)
  local team=model.team;local tabs=model.tabs or {}
  local opts={team=team~=false,focusedList=model.focusedList,teamCatalog=model.teamCatalog,
    tabCount=#tabs,twoLineRows=model.twoLineRows,rowCount=#(model.rows or {})}
  local L=M.layout(w,h,x,y,opts)
  -- Wrap input instructions instead of ellipsizing the action that happens to
  -- be on the right edge of a narrow phone. No new input ownership is introduced.
  local hints={}
  for _,hint in ipairs(model.hints or {"UP/DOWN Browse   A Select","B Back"}) do
    for _,line in ipairs(M.wrap(hint,L.smallSize,L.footer.w-L.pad*2)) do hints[#hints+1]=line end
  end
  opts.footerLines=math.min(4,math.max(1,#hints))
  L=M.layout(w,h,x,y,opts)
  local rows=model.rows or {};local cursor=clamp(model.cursor or 1,1,math.max(1,#rows))
  local selected=rows[cursor] or {}
  local detail=model.detail or selected.detail or "Use UP / DOWN to browse."
  opts.detailLines=#M.wrap(detail,L.bodySize,L.card.w-L.pad*2)
  L=M.layout(w,h,x,y,opts)
  local first,last=M.window(#rows,cursor,L.visible)
  L.first=first;L.last=last;L.cursor=cursor;L.count=#rows
  state.__cbeMobileLayout=L -- diagnostics, not serialized run/save state
  local s,pad=L.s,L.pad
  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  -- No full-window dark plate: the stage is not an illustration behind a modal.
  H.panel(g,L.header,true,.87)
  M.line(g,model.title or "MT. BATTLE",{x=L.header.x+pad,y=L.header.y+5*s,w=L.header.w-pad*2},L.titleSize,C.ink)
  M.line(g,model.subtitle or "PREPARE YOUR CHALLENGE",{x=L.header.x+pad,y=L.header.y+L.subtitleY,w=L.header.w-pad*2},L.smallSize,C.gold)
  if L.tabs then
    local gap=4*s;local tw=(L.tabs.w-gap*math.max(0,#tabs-1))/#tabs
    for i,tab in ipairs(tabs) do
      local tx=L.tabs.x+(i-1)*(tw+gap);local c=tab.active and C.goldSoft or C.panelSoft
      g.setColor(c[1],c[2],c[3],tab.active and .95 or .55)
      g.rectangle("fill",tx,L.tabs.y,tw,L.tabs.h,3*s,3*s)
      if tab.active then
        g.setColor(C.orange[1],C.orange[2],C.orange[3],1)
        g.rectangle("fill",tx,L.tabs.y+L.tabs.h-2*s,tw,2*s)
      end
      M.line(g,tab.label,{x=tx+5*s,y=L.tabs.y+4*s,w=tw-10*s},L.smallSize,tab.active and C.ink or C.muted)
    end
  end
  H.panel(g,L.card,true,.86)
  M.line(g,model.section or "SELECT AN OPTION",{x=L.card.x+pad,y=L.card.y+5*s,w=L.card.w-pad*2-65*s},L.smallSize,C.dim)
  local counter=#rows>0 and (tostring(cursor).." / "..tostring(#rows)) or "0 / 0"
  M.line(g,counter,{x=L.card.x+L.card.w-pad-60*s,y=L.card.y+5*s,w=60*s},L.smallSize,C.gold)
  for i=first,last do
    local row=rows[i];local focused=i==cursor
    local r={x=L.list.x,y=L.list.y+(i-first)*L.rowH,w=L.list.w,h=L.rowH-4*s}
    local c=focused and C.goldSoft or C.panelSoft
    g.setColor(c[1],c[2],c[3],focused and .94 or .38)
    g.rectangle("fill",r.x,r.y,r.w,r.h,3*s,3*s)
    if focused then
      g.setColor(C.orange[1],C.orange[2],C.orange[3],1)
      g.rectangle("fill",r.x,r.y,3*s,r.h)
    end
    local badge=tostring(row.badge or "")
    local meta=row.meta
    if L.twoLineRows and not meta then meta=badge;badge="" end
    local badgeW=badge~="" and math.min(r.w*.31,100*s) or 0
    local labelY=L.twoLineRows and r.y+2*s or r.y+(r.h-L.labelSize)*.42
    M.line(g,row.label or row.title or "",{x=r.x+9*s,y=labelY,w=r.w-18*s-badgeW},L.labelSize,
      row.disabled and C.dim or (focused and C.ink or C.muted))
    if L.twoLineRows then
      M.line(g,meta or "",{x=r.x+9*s,y=labelY+L.labelH+s,w=r.w-18*s},L.smallSize,C.dim)
    end
    if badgeW>0 then
      M.line(g,badge,{x=r.x+r.w-badgeW-6*s,y=L.twoLineRows and labelY or r.y+(r.h-L.smallSize)*.44,w=badgeW},L.smallSize,row.selected and C.green or C.gold)
    end
  end
  if #rows>L.visible then
    local track=L.visible*L.rowH-4*s;local thumb=math.max(8*s,track*L.visible/#rows)
    local ty=L.list.y+(track-thumb)*(cursor-1)/math.max(1,#rows-1)
    g.setColor(C.gold[1],C.gold[2],C.gold[3],.85)
    g.rectangle("fill",L.card.x+L.card.w-4*s,ty,2*s,thumb)
  end
  M.paragraph(g,detail,L.detail,L.bodySize,L.lineH,L.detailLines,model.warning and C.orange or C.muted)
  if L.team then
    local r=L.team;H.panel(g,r,true,.82)
    team=type(team)=="table" and team or (state.game and state.game.save and state.game.save.party) or {}
    M.line(g,"CHALLENGE SIX",{x=r.x+pad,y=r.y+5*s,w=r.w-pad*2-95*s},L.smallSize,C.gold)
    M.line(g,tostring(#team).." / 6"..(#team==6 and " READY" or ""),{x=r.x+r.w-pad-95*s,y=r.y+5*s,w=95*s},L.smallSize,#team==6 and C.green or C.gold)
    local cellW=(r.w-pad*2-8*s)/3;local cellH=21*s
    for i=1,6 do
      local cx=r.x+pad+((i-1)%3)*(cellW+4*s);local cy=r.y+24*s+math.floor((i-1)/3)*cellH
      M.line(g,tostring(i).." "..H.speciesName(state.game,team[i]),{x=cx,y=cy,w=cellW},L.smallSize,team[i] and C.ink or C.dim)
    end
  end
  H.panel(g,L.footer,true,.78)
  for i,hint in ipairs(hints) do
    if i>L.footerLines then break end
    M.line(g,hint,{x=L.footer.x+pad,y=L.footer.y+3*s+(i-1)*L.footerLineH,w=L.footer.w-pad*2},L.smallSize,C.muted)
  end
  g.pop()
  return true
end
return M
