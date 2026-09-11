-- Doubles presentation; commands still pass through the version-1 controller.
-- No party mutation, independent turn resolution, asset extraction or state-stack
-- replacement happens here. The shared Colosseum Party renderer owns its art.
local T=...
local U={version=1,presentationVersion=3,compatibilityVersion=1,itemApiVersion=1,abilityApiVersion=1,states={}}
local function service()
  local provider=T.mod
  if type(T.findCBE)=="function" then
    provider=T.findCBE()
  elseif provider and not (provider.exports and provider.exports.doubles) and type(provider.find)=="function" then
    -- Compatibility for older embedders; the UI's injected resolver is cached
    -- and invalidated by presentation-provider/options events.
    local ok,found=pcall(provider.find,"COLOSSEUM_BATTLE_ENVIRONMENTS")
    if not ok or not found then ok,found=pcall(provider.find,provider,"COLOSSEUM_BATTLE_ENVIRONMENTS") end
    provider=ok and found or nil
  end
  local api=provider and provider.exports and provider.exports.doubles
  return type(api)=='table' and api.version==1 and type(api.snapshot)=='function'
    and type(api.submit)=='function' and api or nil
end

local function clamp(n,a,b) return math.max(a,math.min(b,n)) end
local function rowFor(s,id)
  for _,row in ipairs(s.slots or {}) do if row.id==id then return row end end
end
-- The opponent faces the player, so its two battlefield positions appear
-- mirrored in the HUD: enemy-right is the upper card, enemy-left the lower.
-- This is ONLY a screen-row mapping. Never reorder the controller snapshot,
-- change position/slot IDs, or swap Pokemon data to obtain the visual order.
-- Use the same mapping for target navigation and card/ring/portrait placement.
function U.hudRow(row)
  local position=row.position or 1
  return row.side=='enemy' and 3-position or position
end
local function firstReserve(s)
  for _,m in ipairs(s.party or {}) do if m.enabled then return m.index end end
  return (s.party and s.party[1] and s.party[1].index) or 0
end
local function state(s)
  local u=U.states[s.battleId]
  if not u then U.states={};u={page='commands',index=1};U.states[s.battleId]=u end
  if u.ticket~=s.ticket then
    u.ticket=s.ticket;u.page=s.phase=='replace' and 'party' or 'commands'
    u.index=u.page=='party' and firstReserve(s) or 1
    u.move=nil;u.item=nil;u.itemPartyIndex=nil;u.bagIndex=nil;u.bagOffset=0
    u.error=nil;u.reserveOffset=0;u.lastPartyIndex=nil
  end
  return u
end
local function request(s,kind)
  return {battleId=s.battleId,ticket=s.ticket,turn=s.turn,slot=s.commandSlot,battlerId=s.battlerId,kind=kind}
end
local function send(api,s,u,req)
  local ok,why=api.submit(req)
  if not ok then u.error=why end
  return ok
end
local function targets(s,u)
  local m=u.move;local t=m and s.targets and s.targets[m.index]
  return t and t.ids or {},t and t.mode
end
-- Prefer the topmost legal enemy card, irrespective of controller slot order.
-- Ally-only moves fall back to their topmost legal card. No target is invented.
function U.defaultTargetIndex(s,ids)
  local best,bestScore=1,nil
  for i,id in ipairs(ids or {}) do
    local row=rowFor(s,id)
    if row then
      local score=(row.side=="enemy" and 0 or 100)+U.hudRow(row)
      if not bestScore or score<bestScore then best,bestScore=i,score end
    end
  end
  return best
end
-- Party indices are identities, not visual cell numbers. Switching a non-leading
-- party member into either position must not rearrange save.party to draw it.
function U.partyColumns(s)
  local left={{id='player-left'},{id='player-right'}};local active={};local right={}
  for i,entry in ipairs(left) do
    local slot=rowFor(s,entry.id)
    if slot and not slot.empty and slot.partyIndex then
      entry.index=slot.partyIndex;active[slot.partyIndex]=true
    end
  end
  for _,m in ipairs(s.party or {}) do if not active[m.index] then right[#right+1]={index=m.index} end end
  return left,right
end
function U.partyCards(s,u)
  local left,right=U.partyColumns(s)
  local selectedRight
  for i,r in ipairs(right) do if r.index==u.index then selectedRight=i end end
  local offset=clamp(u.reserveOffset or 0,0,math.max(0,#right-4))
  if selectedRight then
    if selectedRight<=offset then offset=selectedRight-1 end
    if selectedRight>offset+4 then offset=selectedRight-4 end
  end
  u.reserveOffset=offset
  local cards={}
  for i,r in ipairs(left) do
    cards[#cards+1]={index=r.index,x=5,y=(i==1 and 13 or 49),w=74,h=28,
      active=true,slot=r.id,placeholder=(r.id==s.commandSlot and s.phase=='replace') and 'REPLACEMENT' or 'EMPTY POSITION'}
  end
  for i=1,4 do
    local entry=right[offset+i]
    cards[#cards+1]={index=entry and entry.index,x=81,y=3+(i-1)*20,w=74,h=18,
      active=false,placeholder='EMPTY'}
  end
  return cards,#right,offset
end
local function partyNavigate(s,u,p)
  local left,right=U.partyColumns(s)
  local lists={{},{}};local column,at
  for _,entry in ipairs(left) do if entry.index then lists[1][#lists[1]+1]=entry.index end end
  for _,entry in ipairs(right) do lists[2][#lists[2]+1]=entry.index end
  for col,list in ipairs(lists) do for i,index in ipairs(list) do if index==u.index then column,at=col,i end end end
  if u.index==0 then
    if p.up or p.left or p.right then
      local list=#lists[2]>0 and lists[2] or lists[1];u.index=list[#list] or 0
    elseif p.down then u.index=firstReserve(s) end
    return
  end
  if not column then u.index=firstReserve(s);return end
  if p.left or p.right then
    local other=p.left and 1 or 2;local dest=lists[other]
    if other==column then return end
    if #dest>0 then
      -- Pair each large active card with the nearby reserve card, not with the
      -- same ordinal in a generic six-entry list.
      local y=column==1 and (at==1 and .25 or .75) or ((at-.5)/math.max(1,#lists[2]))
      local i=clamp(math.floor(y*#dest)+1,1,#dest);u.index=dest[i]
    end
  elseif p.up then
    if at>1 then u.index=lists[column][at-1] else u.index=0 end
  elseif p.down then
    if at<#lists[column] then u.index=lists[column][at+1] else u.index=0 end
  end
end
-- Target navigation follows the actual screen columns and rows. Only controller-
-- supplied legal targets are considered; friendly fire is not silently removed.
function U.targetNavigate(s,u,p)
  local ids=targets(s,u);if #ids==0 then return end
  u.index=clamp(u.index or 1,1,#ids)
  local current=rowFor(s,ids[u.index]);if not current then return end
  local cross=p.left or p.right;local vertical=p.up or p.down
  if not cross and not vertical then return end
  local best,bestScore
  for i,id in ipairs(ids) do
    local row=rowFor(s,id)
    if row and i~=u.index then
      local dy=U.hudRow(row)-U.hudRow(current)
      local wantedSide=p.left and 'player' or 'enemy'
      local allowed=cross and row.side~=current.side and row.side==wantedSide or (vertical and row.side==current.side)
      if allowed then
        local score=math.abs(dy)
        if vertical and ((p.up and dy>=0) or (p.down and dy<=0)) then score=score+10 end
        if not bestScore or score<bestScore then best,bestScore=i,score end
      end
    end
  end
  if best then u.index=best end
end
local function bagEnabled(s)
  return s.itemApiVersion==1 and s.limitations and s.limitations.bag==true
    and type(s.items)=='table'
end
local function itemFor(s,u)
  for _,item in ipairs(s.items or {}) do if item.id==u.item then return item end end
end
local function partyFor(s,index)
  for _,mon in ipairs(s.party or {}) do if mon.index==index then return mon end end
end
local function itemTargetAllowed(item,mon)
  return item and mon and not mon.egg and not mon.isEgg
    and (item.target~='active-player' or (mon.active and (mon.hp or 0)>0))
end
local function firstItemTarget(s,item)
  local active=rowFor(s,s.commandSlot)
  local mon=active and partyFor(s,active.partyIndex)
  if itemTargetAllowed(item,mon) then return mon.index end
  for _,m in ipairs(s.party or {}) do if itemTargetAllowed(item,m) then return m.index end end
  return 0
end
local function submitItem(api,s,u,moveIndex)
  local item=itemFor(s,u)
  if not bagEnabled(s) or not item or (tonumber(item.available) or 0)<1 then
    u.error='No unreserved copies of this item remain.';return false
  end
  local r=request(s,'item');r.item=item.id;r.partyIndex=u.itemPartyIndex;r.moveIndex=moveIndex
  return send(api,s,u,r)
end
function U.bagWindow(s,u)
  local count=#(s.items or {});local visible=6
  local offset=clamp(u.bagOffset or 0,0,math.max(0,count-visible))
  if u.index<=offset then offset=math.max(0,u.index-1) end
  if u.index>offset+visible then offset=u.index-visible end
  u.bagOffset=offset
  return offset,math.min(visible,count-offset),count
end
function U.input(api,s,p,game)
  local u=state(s)
  if s.phase~='command' and s.phase~='replace' then return end
  if u.page=='party' or u.page=='item-party' then partyNavigate(s,u,p)
  elseif u.page=='bag' then
    local n=#(s.items or {})
    if n>0 then
      local delta=p.up and -1 or p.down and 1 or p.left and -6 or p.right and 6 or 0
      u.index=clamp((u.index or 1)+delta,1,n)
      U.bagWindow(s,u)
    end
  elseif u.page=='targets' then U.targetNavigate(s,u,p)
  else
    local itemMon=u.page=='item-moves' and partyFor(s,u.itemPartyIndex)
    local size=itemMon and #(itemMon.moves or {}) or u.page=='moves' and #(s.moves or {}) or 4
    local col=(u.index-1)%2;local row=math.floor((u.index-1)/2)
    if p.left or p.right then col=1-col end
    if p.up then row=(row-1)%math.max(1,math.ceil(size/2)) end
    if p.down then row=(row+1)%math.max(1,math.ceil(size/2)) end
    u.index=math.max(1,math.min(size,row*2+col+1))
  end
  if p.up or p.down or p.left or p.right then u.error=nil end
  if p.b then
    u.error=nil
    if u.page=='item-moves' then u.page='item-party';u.index=u.itemPartyIndex or 0
    elseif u.page=='item-party' then u.page='bag';u.index=u.bagIndex or 1
    elseif u.page=='bag' then u.page='commands';u.index=3;u.item=nil
    elseif u.page=='targets' then u.page='moves';u.index=u.move.index>0 and u.move.index or 1
    elseif u.page=='party' and s.phase=='replace' then u.error='Choose a replacement before continuing.'
    elseif u.page~='commands' then u.page='commands';u.index=1
    else send(api,s,u,request(s,'cancel')) end
    return
  end
  if not p.a then return end
  if u.page=='commands' then
    if u.index==1 then u.page='moves';u.index=1
    elseif u.index==2 then
      if s.switchLocked then u.error='This Pokemon cannot switch.'
      else u.page='party';u.index=firstReserve(s);u.reserveOffset=0 end
    elseif u.index==3 then
      if not bagEnabled(s) then u.error='This CBE controller does not provide battle items.'
      else u.page='bag';u.index=1;u.bagOffset=0 end
    else u.error='No running from a trainer battle.' end
  elseif u.page=='bag' then
    local item=s.items and s.items[u.index]
    if not item then u.error='No usable battle items in the Bag.';return end
    if (tonumber(item.available) or 0)<1 then u.error='Reserved for your other Pokemon.';return end
    u.item=item.id;u.bagIndex=u.index;u.page='item-party'
    u.index=firstItemTarget(s,item);u.reserveOffset=0
  elseif u.page=='item-party' then
    if u.index==0 then u.page='bag';u.index=u.bagIndex or 1;return end
    local item=itemFor(s,u);local mon=partyFor(s,u.index)
    if not itemTargetAllowed(item,mon) then
      u.error=mon and (mon.egg or mon.isEgg) and 'An Egg cannot use this item.' or 'Choose an active Pokemon.';return
    end
    u.itemPartyIndex=mon.index
    if item.moveRequired then
      if #(mon.moves or {})==0 then u.error='No move can receive this item.';return end
      u.page='item-moves';u.index=1
      for i,m in ipairs(mon.moves) do if (m.pp or 0)<(m.maxPP or m.maxPp or 0) then u.index=i;break end end
    else submitItem(api,s,u) end
  elseif u.page=='item-moves' then
    local mon=partyFor(s,u.itemPartyIndex);local move=mon and mon.moves and mon.moves[u.index]
    if not move then u.error='Choose a move to restore.';return end
    submitItem(api,s,u,move.index or u.index)
  elseif u.page=='moves' then
    local m=s.moves and s.moves[u.index]
    if not (m and m.enabled) then u.error=(m and m.reason) or 'Move unavailable';return end
    u.move=m
    local ids,mode=targets(s,u)
    if mode=='selected' or mode=='foe' or mode=='ally' then
      if #ids==0 then u.error='No legal target is available.';return end
      u.page='targets';u.index=U.defaultTargetIndex(s,ids)
    else local r=request(s,'move');r.moveIndex=m.index;send(api,s,u,r) end
  elseif u.page=='targets' then
    local ids=targets(s,u)
    if not ids[u.index] then u.error='Choose an available target.';return end
    local r=request(s,'move');r.moveIndex=u.move.index;r.target=ids[u.index];send(api,s,u,r)
  elseif u.page=='party' then
    if u.index==0 then
      if s.phase=='replace' then u.error='Choose a replacement before continuing.' else u.page='commands';u.index=2 end
      return
    end
    local mon
    for _,m in ipairs(s.party or {}) do if m.index==u.index then mon=m;break end end
    if not mon then u.error='That position is empty.';return end
    if not mon.enabled then
      u.error=mon.active and 'That Pokemon is already in battle.' or mon.reserved and 'Reserved for your other Pokemon.'
        or mon.egg and 'An Egg cannot battle.' or 'That Pokemon has fainted.';return
    end
    local r=request(s,'switch');r.partyIndex=mon.index;send(api,s,u,r)
  end
end
function U.ready(game) return T.ready and T.ready(game)~=false end
local function clean(t)
  return (tostring(t or ''):gsub('{[Pp][Rr][Oo][Mm][Pp][Tt]}',''):gsub('{[Dd][Oo][Nn][Ee]}','')
    :gsub('[\1-\31]',' '):gsub(' +',' '))
end
local ivory={.94,.94,.85,1}
local dim={.55,.59,.55,1}
local metricFonts=setmetatable({}, {__mode='k'})
local metricStats={hits=0,misses=0,resets=0}
local function textMetrics(f,str)
  local cache=metricFonts[f]
  if not cache then cache={count=0,rows={}};metricFonts[f]=cache end
  local row=cache.rows[str]
  if row then metricStats.hits=metricStats.hits+1;return row[1],row[2],row[3] end
  local width,height,top=f:getWidth(str),f:getHeight(),0
  if T.inkMetrics then
    local ink,offset=T.inkMetrics(f,str)
    if ink and ink>0 then height=ink;top=offset or 0 end
  end
  if cache.count>=512 then cache.rows={};cache.count=0;metricStats.resets=metricStats.resets+1 end
  cache.rows[str]={width,height,top};cache.count=cache.count+1;metricStats.misses=metricStats.misses+1
  return width,height,top
end
function U.performanceStatus()
  return {metricHits=metricStats.hits,metricMisses=metricStats.misses,metricResets=metricStats.resets,metricLimitPerFont=512}
end
local function label(g,value,x,y,w,h,size,color,align)
  local str=clean(value);local f=T.font(math.max(11,size));local fw,fh,top=textMetrics(f,str)
  local scale=math.min(1,math.max(0,w)/math.max(1,fw),math.max(0,h)/math.max(1,fh))
  g.setFont(f);g.setColor(color or ivory)
  if align=='right' then x=x+w-fw*scale elseif align=='center' then x=x+(w-fw*scale)/2 end
  g.print(str,math.floor(x+.5),math.floor(y+(h-fh*scale)/2-top*scale+.5),0,scale,scale)
end
-- Reuse the selected Party typeface while fitting visible Latin ink rather
-- than its multilingual line box. The 7px visible floor matters on handhelds;
-- widths still clamp long nicknames and large text profiles inside each card.
local function partyMetrics(value,size,sc)
  local height=math.max(7,(tonumber(size) or 2)*sc*1.15)
  local fontSize=height*2.6
  local f=T.font(fontSize);local width,fh=textMetrics(f,clean(value))
  local scale=math.min(1,height/math.max(1,fh))
  return fontSize,height,width*scale
end
function U.partyTextWidth(value,size,sc)
  local _,_,width=partyMetrics(value,size,sc);return width/math.max(.001,sc)
end
function U.partyText(value,x,y,size,color,align,width,ox,oy,sc)
  local fontSize,height=partyMetrics(value,size,sc)
  local g=love.graphics;g.push('all');g.origin()
  label(g,value,ox+x*sc,oy+y*sc,(width or 160)*sc,height,fontSize,color,align)
  g.pop()
end
local function uiColor(g,role,r,green,b,a)
  if T.setUIColor then return T.setUIColor(role,r,green,b,a) end
  return g.setColor(r,green,b,a)
end
local function panel(g,x,y,w,h,u)
  if T.panel then T.panel(x,y,w,h,u)
  else uiColor(g,'surface',.095,.11,.105,.94);g.rectangle('fill',x,y,w,h) end
end
local function pointer(g,x,y,h,u)
  if T.selector then T.selector(x,y,h,u) else
    uiColor(g,'accent',.9,.23,.13,1);g.polygon('fill',x,y+h*.28,x+7*u,y+h*.5,x,y+h*.72)
  end
end
function U.layout(w,h,page,mobile)
  local u=clamp(math.min(w/1280,h/720),.65,1.65)
  local margin=clamp(24*u,10,40)
  local totalW=math.min(322*u,(w-margin*3)/2)
  local narrow=w<640
  local ch=narrow and math.max(53,62*u) or clamp(51*u,40,82)
  local pod=math.min(ch,totalW*.26)
  local cardW=totalW-pod-4*u
  local expH=math.max(7,9*u)
  local gap=math.max(expH+5*u,17*u)
  local rows=page=='party' and 3 or 2
  local menuH=page=='bag' and clamp(214*u,140,285) or page=='targets' and clamp(57*u,50,94) or clamp((page=='commands' and 100 or rows*46+18)*u,100,225)
  local menuW=math.min(w-margin*2,(page=='commands' and 690 or 820)*u)
  local bottom=margin
  if h>w or mobile then bottom=math.max(bottom,h*.24) end
  local menuY=math.max(margin+2*(ch+gap)+34,h-bottom-menuH)
  if menuY+menuH>h-margin then menuY=h-margin-menuH end
  return {u=u,margin=margin,totalW=totalW,cardW=cardW,pod=pod,ch=ch,gap=gap,expH=expH,narrow=narrow,
    menu={x=(w-menuW)/2,y=menuY,w=menuW,h=menuH},w=w,h=h}
end
function U.cardBounds(row,L)
  local u=L.u;local left=row.side=='player'
  local allX=left and L.margin or L.w-L.margin-L.totalW
  return {x=left and allX or allX+L.pod+4*u,
    px=left and allX+L.cardW+4*u or allX,
    y=L.margin+(U.hudRow(row)-1)*(L.ch+L.gap),w=L.cardW,h=L.ch}
end
function U.visibility(s,page,selectedTarget)
  local out={}
  -- The full Party menu replaces the battle HUD, without replacing the arena.
  if (page=='party' or page=='item-party') and (s.phase=='command' or s.phase=='replace') then return out end
  if s.phase=='command' then
    for _,row in ipairs(s.slots or {}) do if not row.empty then out[row.id]=true end end
  elseif s.phase=='replace' then
    for _,row in ipairs(s.slots or {}) do if row.side=='player' and not row.empty then out[row.id]=true end end
  else
    local e=s.presentation
    if e and e.kind=='move' then
      for _,impact in ipairs(e.impacts or {}) do out[impact.slot]=true end
    end
    if e and (e.kind=='send' or e.kind=='damage' or e.kind=='heal' or e.kind=='status' or e.kind=='faint') and e.subject then out[e.slot]=true end
  end
  return out
end
local function hpColor(g,ratio)
  if ratio>.5 then g.setColor(.19,.78,.31,1)
  elseif ratio>.2 then g.setColor(.96,.70,.09,1) else g.setColor(.9,.22,.17,1) end
end
local statusNames={POISON='PSN',POISONED='PSN',TOXIC='TOX',BURN='BRN',BURNED='BRN',PARALYZE='PAR',PARALYSIS='PAR',PARALYZED='PAR',SLEEP='SLP',ASLEEP='SLP',FREEZE='FRZ',FROZEN='FRZ',FAINTED='FNT'}
function U.status(row)
  if not row.egg and not row.empty and (tonumber(row.hp) or 1)<=0 then return 'FNT' end
  local value=row.status
  if not value or value==0 or value=='' or value=='OK' then return nil end
  value=tostring(value):upper();return statusNames[value] or value
end
local function chip(g,value,x,y,w,h,u,rgb)
  rgb=rgb or {.38,.50,.47}
  g.setColor(rgb[1]*.30,rgb[2]*.30,rgb[3]*.30,.98);g.rectangle('fill',x,y,w,h,2*u,2*u)
  g.setColor(rgb[1],rgb[2],rgb[3],.95);g.setLineWidth(math.max(1,.7*u));g.rectangle('line',x,y,w,h,2*u,2*u)
  label(g,value,x+2*u,y,w-4*u,h,9*u,ivory,'center')
end
function U.expRatio(game,row,generation)
  if T.experience then
    local ratio=T.experience(game,row.portrait or row.display or {},generation)
    if type(ratio)=='number' and ratio==ratio then return clamp(ratio,0,1) end
  end
  return 0
end
local function drawExp(game,g,row,b,L,generation)
  local u=L.u;local x,y,w,h=b.x+11*u,b.y+b.h-1*u,b.w-27*u,L.expH
  g.setColor(.055,.070,.068,.98);g.polygon('fill',x,y,x+w,y,x+w-4*u,y+h,x-4*u,y+h)
  g.setColor(.24,.29,.29,1);g.setLineWidth(math.max(1,.7*u));g.line(x,y+h,x+w-4*u,y+h)
  local tag=math.min(27*u,w*.20)
  label(g,'EXP',x+2*u,y,w*.19,h,7*u,{.52,.69,.92,1})
  local bx=x+tag;local by=y+h*.30;local bw=math.max(1,w-tag-6*u);local bh=math.max(2,h*.4)
  g.setColor(.10,.16,.19,1);g.rectangle('fill',bx,by,bw,bh)
  g.setColor(.20,.52,.92,1);g.rectangle('fill',bx,by,bw*U.expRatio(game,row,generation),bh)
end
local function targetRing(g,b,u,ally)
  local rgb=ally and {.23,.81,1} or {1,.40,.17}
  local x,y,w,h=b.x-2*u,b.y-2*u,b.w+4*u,b.h+4*u
  local bevel=10*u
  local points={x+bevel,y,x+w-bevel,y,x+w,y+bevel,x+w-5*u,y+h,x+bevel,y+h,x,y+h-bevel,x,y+bevel}
  g.setLineWidth(math.max(5,6*u));g.setColor(rgb[1],rgb[2],rgb[3],.21);g.polygon('line',points)
  g.setLineWidth(math.max(2,2*u));g.setColor(rgb[1],rgb[2],rgb[3],1);g.polygon('line',points)
end
function U.displayHP(row,event)
  local hp=tonumber(row.hp) or 0
  if event and event.kind=='move' then
    for _,impact in ipairs(event.impacts or {}) do
      if impact.battlerId==row.battlerId then event=impact;break end
    end
  end
  if event and event.previousHP and not event.presentationConsumed and (event.kind=='damage' or event.kind=='heal') then
    local t=clamp((event.elapsed or 0)/math.max(.05,(event.duration or .38)*.8),0,1)
    hp=event.previousHP+(hp-event.previousHP)*t
  end
  return hp
end
local function drawCard(game,g,row,L,commandOwner,targeted,event,generation)
  local u=L.u;local left=row.side=='player';local b=U.cardBounds(row,L)
  local x,px,y,w,h=b.x,b.px,b.y,b.w,b.h
  if T.plate then T.plate(x,y,w,h,row.side,math.min(u,h/55)) else panel(g,x,y,w,h,u) end
  if T.pod then T.pod(px,y,L.pod,math.min(u,L.pod/60)) else panel(g,px,y,L.pod,L.pod,u) end
  local mon=row.portrait or {species=row.species,level=row.level}
  if T.portrait then
    local ok,drawn=pcall(T.portrait,game,mon,px+1.8*u,y+1.8*u,L.pod-3.6*u,L.pod-3.6*u)
    if (not ok or not drawn) and T.spritePortrait then pcall(T.spritePortrait,game,mon,px+1.8*u,y+1.8*u,L.pod-3.6*u,L.pod-3.6*u) end
  end
  if T.podOverlay then T.podOverlay(px,y,L.pod,math.min(u,L.pod/60)) end
  if commandOwner and not targeted then pointer(g,px+L.pod*.44,y-8*u,7*u,u) end
  local pad=clamp(12*u,6,20);local inner=w-pad*2
  local headerH=h*(L.narrow and .23 or .31);local levelW=clamp(inner*.27,26,54*u)
  label(g,row.name,x+pad,y+4*u,inner-levelW-4*u,headerH,15*u)
  label(g,'Lv '..tostring(row.level or '?'),x+w-pad-levelW,y+4*u,levelW,headerH,13*u,nil,'right')
  local hp=U.displayHP(row,event)
  local ratio=clamp(hp/math.max(1,row.maxHP or 1),0,1)
  local hpY=y+h*(L.narrow and .37 or .47);local hpH=math.max(3,6*u);local tag=math.min(23*u,inner*.17)
  label(g,'HP',x+pad,hpY-2*u,tag-3*u,hpH+4*u,9*u,{.88,.75,.35,1})
  g.setColor(.045,.06,.055,1);g.rectangle('fill',x+pad+tag-1,hpY-1,inner-tag+2,hpH+2)
  hpColor(g,ratio);g.rectangle('fill',x+pad+tag,hpY,(inner-tag)*ratio,hpH)
  local detailY=y+h*(L.narrow and .57 or .71);local detailH=math.max(8,h*(L.narrow and .20 or .22))
  local st=U.status{hp=hp,status=row.status,empty=row.empty}
  local typeNames=row.types
  if (not typeNames or #typeNames==0) and T.types then typeNames=T.types(game,row) end
  typeNames=typeNames or {}
  local count=math.min(2,#typeNames);local gap=3*u
  local detailW=(left and not L.narrow) and inner*.65 or inner
  local statusW=st and math.min(26*u,detailW*.26) or 0
  local tx=x+pad
  if st then chip(g,st,tx,detailY,statusW,detailH,u,{.96,.63,.25});tx=tx+statusW+gap end
  local available=math.max(0,detailW-statusW-(st and gap or 0))
  local tw=count>0 and math.min(57*u,(available-gap*(count-1))/count) or 0
  for i=1,count do
    local name=tostring(typeNames[i]):upper():gsub('^TYPE_',''):gsub('_TYPE$','')
    chip(g,name,tx,detailY,tw,detailH,u,T.typeColors and T.typeColors[name]);tx=tx+tw+gap
  end
  if left then
    local hy=L.narrow and y+h*.81 or detailY;local hh=L.narrow and h*.16 or detailH
    local hw=L.narrow and inner or inner*.33
    label(g,math.floor(hp+.5)..' / '..tostring(row.maxHP or 1),x+w-pad-hw,hy,hw,hh,10*u,nil,'right')
    drawExp(game,g,row,b,L,generation)
  end
  if row.committed then
    label(g,'OK',px+L.pod*.50,y+L.pod*.70,L.pod*.35,L.pod*.22,8*u,{.50,1,.64,1},'center')
  end
  if targeted then targetRing(g,b,u,left) end
end
local function getRows(s,u)
  local rows={}
  if u.page=='commands' then
    rows={{label='FIGHT',enabled=true},{label='POKéMON',enabled=not s.switchLocked},
      {label='BAG',enabled=bagEnabled(s)},{label='RUN',enabled=false}}
  elseif u.page=='item-moves' then
    local mon=partyFor(s,u.itemPartyIndex)
    for _,m in ipairs(mon and mon.moves or {}) do
      rows[#rows+1]={label=m.name or m.id,detail='RESTORE PP',right='PP '..(m.pp or 0)..'/'..(m.maxPP or m.maxPp or '?'),
        enabled=(m.pp or 0)<(m.maxPP or m.maxPp or math.huge)}
    end
  elseif u.page=='moves' then
    for _,m in ipairs(s.moves or {}) do rows[#rows+1]={label=m.name,detail=m.type or '',right='PP '..(m.pp or 0)..'/'..(m.maxPP or 0),enabled=m.enabled} end
  end
  return rows
end
function U.partyState(s,u)
  local cards,total,offset=U.partyCards(s,u)
  local party={};local labels={}
  for _,m in ipairs(s.party or {}) do
    -- A complete producer or the UI-only native display adapter supplies a
    -- detached mon. This minimal record is retained for unavailable native data.
    party[m.index]=m.display or {species=m.species,nickname=m.name,level=m.level,hp=m.hp,maxHp=m.maxHP,
      stats={hp=m.maxHP},status=m.status,isEgg=m.egg,moves={}}
    labels[m.index]=m.active and 'IN BATTLE' or m.reserved and 'RESERVED' or m.egg and 'EGG'
      or (m.hp or 0)<=0 and 'FAINTED' or nil
  end
  if u.index>0 then u.lastPartyIndex=u.index end
  local active=rowFor(s,s.commandSlot)
  local item=u.page=='item-party' and itemFor(s,u)
  local prompt=item and ('Use '..clean(item.name or item.id)..': choose a POKéMON.')
    or ((s.phase=='replace' and 'Replace ' or 'Switch ')..(active and not active.empty and active.name or (s.commandSlot=='player-left' and 'ALLY LEFT' or 'ALLY RIGHT'))..': choose a POKéMON.')
  return {party=party,index=u.index>0 and u.index or u.lastPartyIndex or 1,
    __cbeDoublesParty=true,doublesCards=cards,doublesLabels=labels,doublesExit=u.index==0,
    doublesRequired=s.phase=='replace',doublesReserveCount=total,doublesReserveOffset=offset,
    doublesError=u.error,doublesCommandSlot=s.commandSlot,
    prompt=u.error or prompt,
    isOpaque=false}
end
function U.draw(game,battle)
  local api=service()
  local previous=U.activeBattleId and U.states[U.activeBattleId]
  local options=api and api.snapshotOptionsVersion==1 and {view='render',page=previous and previous.page or 'commands'} or nil
  local s=api and api.snapshot(battle,options)
  if not s then return false end
  U.activeBattleId=s.battleId
  local u=state(s)
  if T.displayCompat then s=T.displayCompat.enrich(game,battle,s,u.page) end
  local g=love.graphics;local w,h=g.getDimensions()
  local mobile=T.mobile and T.mobile() or false
  local L=U.layout(w,h,u.page,mobile);local unit=L.u
  local choosing=s.phase=='command' or s.phase=='replace'
  local ids=targets(s,u);local selectedTarget=u.page=='targets' and ids[u.index]
  local visible=U.visibility(s,u.page,selectedTarget)
  g.push('all');g.origin();g.setShader();g.setScissor()
  if choosing and (u.page=='party' or u.page=='item-party') then
    g.setColor(0,.015,.02,.28);g.rectangle('fill',0,0,w,h)
    if T.party then
      T.party(game,U.partyState(s,u))
    else
      panel(g,L.menu.x,L.menu.y,L.menu.w,L.menu.h,unit)
      label(g,'Party renderer unavailable. Press B to return.',L.menu.x+12,L.menu.y+10,L.menu.w-24,L.menu.h-20,16*unit)
    end
    g.pop();return true
  end
  for _,row in ipairs(s.slots or {}) do
    if visible[row.id] then
      local event=s.presentation
      if not choosing and event and event.subject and event.slot==row.id then row=event.subject end
      drawCard(game,g,row,L,u.page~='targets' and row.id==s.commandSlot,row.id==selectedTarget,not choosing and event or nil,s.nativeRules)
    end
  end
  local box=L.menu
  if choosing then
    panel(g,box.x,box.y,box.w,box.h,unit)
    local active=rowFor(s,s.commandSlot)
    local title=active and active.name or ''
    if u.page=='targets' then title=(u.move and u.move.name or 'MOVE')..' / TARGET'
    elseif u.page=='bag' then title='BAG / '..title
    elseif u.page=='item-moves' then
      local item=itemFor(s,u);local mon=partyFor(s,u.itemPartyIndex)
      title=clean(item and (item.name or item.id))..' / '..clean(mon and mon.name)
    end
    local tabW=math.min(box.w*.64,math.max(170*unit,T.font(12*unit):getWidth(title)*.5+35*unit))
    uiColor(g,'surface',.19,.21,.19,.98);g.polygon('fill',box.x+15*unit,box.y,box.x+25*unit,box.y-17*unit,box.x+tabW,box.y-17*unit,box.x+tabW+12*unit,box.y)
    label(g,title,box.x+35*unit,box.y-17*unit,tabW-30*unit,16*unit,12*unit)
    label(g,s.commandSlot and (s.commandSlot:find('left') and 'LEFT' or 'RIGHT') or '',box.x+box.w-90*unit,box.y-16*unit,65*unit,15*unit,10*unit,dim,'right')
    if u.page=='bag' then
      local offset,visible,total=U.bagWindow(s,u)
      local pad=16*unit;local footer=24*unit;local contentH=box.h-pad-footer
      local rowH=contentH/6;local listW=box.w-pad*2-9*unit
      for i=1,visible do
        local index=offset+i;local item=s.items[index];local y=box.y+pad/2+(i-1)*rowH
        if index==u.index then
          uiColor(g,'selection',.34,.37,.32,.79);g.rectangle('fill',box.x+pad,y,listW,rowH-2*unit)
          pointer(g,box.x+pad-10*unit,y,rowH-2*unit,unit)
        end
        local available=tonumber(item.available) or 0
        local info=available>0 and ('x '..available) or 'RESERVED'
        local infoW=math.min(95*unit,listW*.30)
        label(g,item.name or item.id,box.x+pad+5*unit,y,listW-infoW-10*unit,rowH-2*unit,17*unit,available>0 and ivory or dim)
        label(g,info,box.x+pad+listW-infoW-5*unit,y,infoW,rowH-2*unit,12*unit,available>0 and ivory or dim,'right')
      end
      if total==0 then label(g,'No usable battle items.',box.x+pad,box.y+pad,listW,contentH,17*unit,dim,'center') end
      if total>6 then
        local trackX=box.x+box.w-10*unit;local trackY=box.y+pad/2
        g.setColor(.20,.24,.22,1);g.rectangle('fill',trackX,trackY,3*unit,contentH)
        g.setColor(.72,.76,.66,1);g.rectangle('fill',trackX,trackY+contentH*offset/total,3*unit,contentH*6/total)
      end
      label(g,'A: choose   B: commands',box.x+pad,box.y+box.h-footer,listW*.76,footer,11*unit,dim)
      label(g,total>0 and (u.index..' / '..total) or '0 / 0',box.x+pad+listW*.76,box.y+box.h-footer,listW*.24,footer,11*unit,dim,'right')
    elseif u.page=='targets' then
      local target=rowFor(s,selectedTarget);local ally=target and target.side=='player'
      local color=ally and {.23,.81,1,1} or {1,.53,.29,1}
      label(g,target and target.name or 'Choose a target',box.x+22*unit,box.y+8*unit,box.w*.58,box.h*.40,20*unit,color)
      label(g,ally and 'ALLY / FRIENDLY FIRE' or 'OPPONENT',box.x+22*unit,box.y+box.h*.60,box.w*.55,box.h*.24,10*unit,color)
      label(g,'A: confirm   B: moves',box.x+box.w*.59,box.y+box.h*.20,box.w*.37,box.h*.30,12*unit,ivory,'right')
      label(g,'Choose the highlighted HP panel',box.x+box.w*.55,box.y+box.h*.60,box.w*.41,box.h*.24,10*unit,dim,'right')
    else
      local rows=getRows(s,u);local rowCount=math.max(2,math.ceil(#rows/2))
      local padX=clamp(28*unit,14,50);local padY=11*unit;local gap=16*unit
      local cellW=(box.w-padX*2-gap)/2;local cellH=(box.h-padY*2)/rowCount
      for i,row in ipairs(rows) do
        local x=box.x+padX+((i-1)%2)*(cellW+gap);local y=box.y+padY+math.floor((i-1)/2)*cellH
        if i==u.index then
          uiColor(g,'selection',.34,.37,.32,.79);g.polygon('fill',x-1,y,x+cellW-4*unit,y,x+cellW,y+cellH-4*unit,x-1,y+cellH-4*unit)
          pointer(g,x-12*unit,y,cellH-4*unit,unit)
        end
        local hasDetail=row.detail or row.right
        label(g,row.label,x+5*unit,y+2*unit,cellW-12*unit,hasDetail and cellH*.46 or cellH-7*unit,20*unit,row.enabled and ivory or dim)
        if hasDetail then
          label(g,row.detail or '',x+5*unit,y+cellH*.51,cellW*.47,cellH*.29,11*unit,dim)
          label(g,row.right or '',x+cellW*.46,y+cellH*.51,cellW*.5-6*unit,cellH*.29,11*unit,dim,'right')
        end
      end
    end
    if u.error then
      local eh=28*unit;panel(g,box.x,box.y-eh-23*unit,box.w,eh,unit*.65)
      label(g,u.error,box.x+15*unit,box.y-eh-23*unit,box.w-30*unit,eh,12*unit,{1,.72,.45,1})
    end
  else
    local message=s.presentation and s.presentation.text or (s.phase=='fault' and s.message) or ''
    if message~='' then
      local mw=math.min(w-L.margin*2,720*unit);local mh=s.phase=='fault' and 96*unit or 66*unit
      local mx=L.margin;local my=math.min(box.y+box.h-mh,h-L.margin-mh)
      panel(g,mx,my,mw,mh,unit)
      label(g,message,mx+22*unit,my+10*unit,mw-44*unit,mh-(s.phase=='fault' and 40 or 20)*unit,18*unit)
      if s.phase=='fault' then label(g,'B: restore the encounter as a single battle',mx+22*unit,my+mh-26*unit,mw-44*unit,20*unit,12*unit) end
    end
  end
  g.pop();return true
end
U._test={textMetrics=textMetrics,label=label,state=state,rows=getRows,service=service,partyNavigate=partyNavigate,drawCard=drawCard,targetRing=targetRing,clean=clean,bagEnabled=bagEnabled}
return U
