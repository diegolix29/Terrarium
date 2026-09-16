-- Screen-space cache UI shared by Gen I/II. No source reads, GPU model loads or
-- save writes. The controller renders this AFTER the cartridge palette pass.
local Screen={version=5}
local fonts={}
local color={bg={.028,.044,.049,1},panel={.065,.10,.11,1},edge={.29,.40,.39,1},
  inset={.039,.064,.069,1},ink={.92,.94,.88,1},muted={.60,.72,.70,1},
  accent={1,.31,.15,1},ok={.45,.80,.66,1},error={1,.53,.38,1}}
local function font(size)
  size=math.max(7,math.floor(size+.5))
  if not fonts[size] then
    fonts[size]=love.graphics.newFont(size)
    if fonts[size].setFilter then fonts[size]:setFilter('linear','linear') end
  end
  return fonts[size]
end
local function shorten(f,value,width)
  local t=tostring(value or ''):gsub('[\r\n\t]+',' ')
  if f:getWidth(t)<=width then return t end
  local chars={};for c in t:gmatch('[%z\1-\127\194-\244][\128-\191]*')do chars[#chars+1]=c end
  while #chars>0 do
    chars[#chars]=nil
    local s=table.concat(chars)..'...'
    if f:getWidth(s)<=width then return s end
  end
  return ''
end
local function text(t,x,y,w,size,c,align)
  local G=love.graphics;local f=font(size);t=shorten(f,t,math.max(0,w))
  G.setFont(f);G.setColor(c or color.ink)
  if align=='right' then x=x+w-f:getWidth(t)
  elseif align=='center' then x=x+(w-f:getWidth(t))/2 end
  G.print(t,math.floor(x+.5),math.floor(y+.5))
end
local function plate(x,y,w,h,c,line)
  local G=love.graphics;G.setColor(c);G.setLineWidth(1)
  G.rectangle(line and 'line' or 'fill',x,y,w,h)
end
function Screen.layout(w,h)
  if Screen._platformOS==nil then
    Screen._platformOS=''
    if love and love.system and type(love.system.getOS)=='function' then
      local ok,value=pcall(love.system.getOS)
      if ok then Screen._platformOS=tostring(value or '') end
    end
  end
  local mobile=Screen._platformOS=='Android' or Screen._platformOS=='iOS'
  -- Near-square foldable screens also carry the virtual pad over the lower
  -- viewport. Treat them as a stack, not a short desktop window.
  local portrait=mobile and w/h<1.35 or h>w*1.25
  local margin=math.max(8,math.min(34,w*.035,h*.04))
  local pw=mobile and (w-2*margin) or math.min(portrait and 650 or 980,w-2*margin)
  local avail=mobile and h*(portrait and .72 or .85) or (portrait and h*.76 or h)
  local ph=mobile and (avail-2*margin) or math.min(portrait and 550 or 590,avail-2*margin)
  local s
  if mobile then s=math.min(pw/(portrait and 410 or 620),ph/(portrait and 500 or 460),2.2)
  else s=portrait and math.min(pw/400,ph/490,1.1) or math.min(pw/620,ph/460,1.2) end
  local pad=math.max(10,24*s)
  return {x=(w-pw)/2,y=(mobile or portrait) and margin or (h-ph)/2,w=pw,h=ph,
    s=s,pad=pad,portrait=portrait,mobile=mobile,controlY=avail}
end
-- Show the actual failure rather than ellipsizing the old generic error on one
-- line. Very long paths remain bounded; the full diagnostic persists on disk.
local function wrapped(t,x,y,w,size,c,lines)
  local f=font(size);local line='';local rows={}
  for word in tostring(t or ''):gsub('[\r\n\t]+',' '):gmatch('%S+') do
    local trial=line=='' and word or (line..' '..word)
    if line~='' and f:getWidth(trial)>w then rows[#rows+1]=line;line=word else line=trial end
  end
  if line~='' then rows[#rows+1]=line end
  local count=math.min(lines,#rows);local step=f:getHeight()*1.22
  for i=1,count do
    local value=rows[i]
    if i==count and #rows>count then value=value..' ...' end
    text(value,x,y+(i-1)*step,w,size,c)
  end
  return y+count*step
end
local function elapsed(s,now)
  local n=math.max(0,math.floor((s.finishedAt or now)-(s.startedAt or now)))
  if n>=3600 then return ('%dh %02dm elapsed'):format(math.floor(n/3600),math.floor(n/60)%60) end
  return ('%d:%02d elapsed'):format(math.floor(n/60),n%60)
end
local function nameFor(s,row)
  if not row or not row.dex then return 'Checking saved model files' end
  if row.name then return row.name end
  if not s.displayNames then
    s.displayNames={}
    for _,def in pairs(s.game and s.game.data and s.game.data.pokemon or {})do
      if type(def)=='table' then
        local n=tonumber(def.dex or def.index or def.number)
        if n then s.displayNames[n]=def.name or def.id end
      end
    end
  end
  return s.displayNames[row.dex] or ('Pokemon #'..row.dex)
end
function Screen.draw(s,w,h,inventory,now)
  local G=love.graphics;local l=Screen.layout(w,h);local z,p=l.s,l.pad
  local x,y,bw=l.x+p,l.y+p,l.w-2*p
  s.buttons={};s.layout=l
  G.push('all');G.origin();G.setShader();if G.setScissor then G.setScissor()end
  if G.setBlendMode then G.setBlendMode('alpha')end
  plate(0,0,w,h,color.bg)
  plate(l.x+4,l.y+5,l.w,l.h,{0,0,0,.32})
  plate(l.x,l.y,l.w,l.h,color.panel);plate(l.x,l.y,l.w,l.h,color.edge,true)
  plate(l.x,l.y,math.max(3,4*z),l.h,color.accent)
  text('COLOSSEUM / MODEL LIBRARY',x,y,bw,12*z,color.muted)
  local title=s.selector and 'Battle cache' or (s.error and 'Preparation paused' or
    (s.complete and (s.mode=='mtbattle' and 'Mt. Battle cache ready' or (s.full and 'Full catalog ready' or (#s.rows==0 and 'Catalog complete' or 'Batch saved'))) or
      (s.mode=='mtbattle' and 'Mt. Battle cache' or
        (s.mode=='quick' and 'Quick Start' or (s.full and 'Full catalog' or 'Preparing models')))))
  text(title,x,y+23*z,bw,30*z,color.ink)
  local sub=s.selector and ((not s.reuseChecked)
      and 'Checking saved cache. No model extraction starts until you select a mode.'
      or 'Choose a mode. No model extraction starts until you select it.') or
    (s.complete and 'Completed models are stored on this device.' or
      (s.mode=='mtbattle' and 'Preparing required cross-generation models. Existing valid files are reused.' or
        (s.mode=='quick' and (l.portrait and ((tostring(s.batchLimit or 30)..' new models. Saved for future sessions.')) or ('Adding up to '..tostring(s.batchLimit or 30)..' uncached models for your save.')) or
          (s.full and 'Preparing all 386 normal models. Existing valid files are reused; battle actions stay on-demand.' or 'Loading the exact models this session needs.'))))
  text(sub,x,y+66*z,bw,14*z,color.muted)
  local contentY=y+106*z
  local recoveryGrid=s.error and l.portrait
  local buttonH=recoveryGrid and math.max(34,32*z) or 30*z
  local buttonGap=10*z
  local recoveryRows=recoveryGrid and 2 or 1
  local footerY=l.y+l.h-p-buttonH*recoveryRows-buttonGap*(recoveryRows-1)
  local contentEnd=footerY-34*z
  local function button(key,label,bx,by,bw2,bh,focused,detail)
    local selected=focused or false
    plate(bx,by,bw2,bh,selected and {.13,.22,.23,1} or color.inset)
    plate(bx,by,bw2,bh,selected and color.accent or color.edge,true)
    if selected then plate(bx,by,3*z,bh,color.accent)end
    local fs=detail and 19*z or 14*z
    text(label,bx+12*z,by+(detail and 9*z or (bh-font(fs):getHeight())/2),bw2-24*z,fs,color.ink)
    if detail then text(detail,bx+12*z,by+34*z,bw2-24*z,12*z,color.muted)end
    s.buttons[#s.buttons+1]={key=key,x=bx,y=by,w=bw2,h=bh}
  end
  if s.selector then
    local gap=10*z
    local labels
    if not s.reuseChecked then
      -- Do not briefly present QUICK START / CURRENT TEAM as the apparent default
      -- while Android is still proving whether an existing cache qualifies for
      -- REUSE. The controller blocks selection during this read-only probe too.
      labels={{'wait','CHECKING SAVED CACHE','Looking for 30+ reusable models. This check does not extract or write models.'}}
    else
      labels={
        {'quick','SMART CACHE / +30','Team, caught, seen, nearby and level-relevant.'},
        {'batch60','SMART CACHE / +60','Same relevance ranking, with a larger persistent batch.'},
        {'batch120','SMART CACHE / +120','Broader coverage while still avoiding a forced full build.'},
        {'full','FULL CATALOG / 386','All 386 normal models. Existing valid cache is reused; action banks stay on-demand.'},
        {'b','MAIN MENU','Leave now. Your existing cache stays saved.'}}
      if s.startupRequest then
        if s.reuseEligible then
          table.insert(labels,1,{'reuse','REUSE CACHE',
            s.startupRequest.newGame and 'Use saved models; load only required starters, then begin New Game.'
              or 'Use saved models; load only required team models, then Continue.'})
        else
          table.insert(labels,1,{'startup',s.startupRequest.newGame and 'STARTER MODELS ONLY' or 'CURRENT TEAM ONLY',
            s.startupRequest.newGame and 'Prepare native starters, then begin New Game.' or 'Reuse / prepare your team, then Continue.'})
        end
      elseif s.reuseEligible then
        table.insert(labels,1,{'reuse','REUSE CACHE','Reuse saved models; load only the current team. No new smart-cache batch.'})
      end
    end
    local rowH=math.min(64*z,(contentEnd-contentY-(#labels-1)*gap)/#labels)
    -- Short landscape windows can fit six choices only if the explanatory second
    -- line is suppressed. Keep the full descriptions on portrait/tablet layouts,
    -- but never let detail text overlap the next touch target on mobile landscape.
    local compactRows=rowH<46*z
    for i,row in ipairs(labels)do
      button(row[1],row[2],x,contentY+(i-1)*(rowH+gap),bw,rowH,s.reuseChecked and s.choice==i,compactRows and nil or row[3])
    end
    local status
    if s.reuseEligible then
      if s.reuseInfo and s.reuseInfo.certified then
        status='Previous cache save detected. Reuse loads only the models this session requires.'
      else
        local n=s.reuseInfo and tonumber(s.reuseInfo.cachedModels) or 30
        status=('Reusable cache detected: %d+ saved models. Pick +30 / +60 / +120 / 386, or reuse only.'):format(math.max(30,n or 30))
      end
    elseif not s.reuseChecked then
      status='Checking existing cache (read only). Completed model files are preserved.'
    elseif s.reuseChecked and s.reuseProbeError then
      status='Existing-cache check unavailable. Team/starter-only and manual cache modes remain available.'
    elseif inventory then
      status=('Saved: %d / 386 normal models'):format(inventory.cachedModels)
    else
      status='Completed files are checked before selecting each batch.'
    end
    text(status,x,footerY-17*z,bw,12*z,color.muted)
    text('A: SELECT    B: BACK',x,footerY+9*z,bw,12*z,color.ink)
  else
    local done=math.min(#s.rows,math.max(0,s.index-1));local total=#s.rows
    local label=s.planning and 'CHECKING YOUR SAVED CACHE' or (s.complete and 'PERSISTED ON DEVICE' or 'THIS PASS')
    text(label,x,contentY,bw,12*z,color.muted)
    local progress=s.planning and 'Selecting relevant models...' or
      (s.complete and total==0 and 'No new models needed' or
        ('%d / %d %s'):format(done,total,s.batchInfo and 'new models saved' or 'appearances ready'))
    text(progress,x,contentY+23*z,bw,25*z,s.error and color.error or color.ink)
    local barY=contentY+64*z
    plate(x,barY,bw,8*z,color.inset)
    local q=total>0 and done/total or (s.complete and 1 or 0)
    if q>0 then plate(x,barY,bw*q,8*z,s.error and color.error or color.ok)end
    local row=s.rows[s.index]
    local model=s.complete and (s.mode=='mtbattle' and 'Cross-generation library is ready.' or 'Quick Start will select the next new batch.') or nameFor(s,row)
    if row and row.variant=='shiny' then model=model..' / shiny' end
    text(model,x,barY+25*z,bw,18*z,color.ink)
    local stage=s.error and tostring(s.error) or (s.complete and 'No re-extraction on restart.' or s.label or 'Checking generated data...')
    local stageBottom=barY+67*z
    if s.error then
      local fs=l.mobile and math.max(11,12*z) or 12*z
      local available=math.max(1,math.floor((contentEnd-36*z-(barY+53*z))/(font(fs):getHeight()*1.22)))
      stageBottom=wrapped(stage,x,barY+53*z,bw,fs,color.error,math.min(4,available))
    else text(stage,x,barY+53*z,bw,12*z,color.muted) end
    local info=s.batchInfo or inventory
    local by=math.min(math.max(barY+91*z,stageBottom+8*z),contentEnd-29*z)
    if info then
      text(('DISK CACHE  %d / 386 normal models'):format(info.cachedModels),x,by,bw,12*z,color.ok)
    else text('Disk files persist. Graphics memory is session-only.',x,by,bw,12*z,color.muted)end
    text(elapsed(s,now),x,by+23*z,bw,12*z,color.muted,'right')
    if s.error then text('Details: model-cache-error.txt',x,by+23*z,bw*.68,11*z,color.muted) end
    local note=s.battle and 'Exact Colosseum models required. No sprite substitution.' or
      (s.error and 'Retry repairs the failed action. Rebuild affects only this model.' or 'Leaving preserves every completed model.')
    text(note,x,footerY-24*z,bw,12*z,color.muted)
    local keys={}
    if s.error then keys[#keys+1]={'a','A: RETRY'} end
    if s.error and row and row.dex then keys[#keys+1]={'select','SELECT: WIPE MODEL + REBUILD'} end
    if not s.battle then keys[#keys+1]={s.complete and 'a' or 'b',s.complete and 'A: MAIN MENU' or 'B: MAIN MENU'} end
    if s.error then keys[#keys+1]={'start','EXIT GAME'} end
    local gap=buttonGap;local columns=recoveryGrid and 2 or math.max(1,#keys)
    local buttonW=(bw-(columns-1)*gap)/columns
    local mobileLabels={a='A: RETRY',select='SELECT: REBUILD',b='B: MAIN MENU',start='START: EXIT'}
    for i,k in ipairs(keys)do
      local label=(s.error and l.mobile) and mobileLabels[k[1]] or k[2]
      if recoveryGrid and k[1]=='select' then label='SELECT: REBUILD' end
      button(k[1],label,x+((i-1)%columns)*(buttonW+gap),
        footerY+math.floor((i-1)/columns)*(buttonH+gap),buttonW,buttonH,i==1)
    end
  end
  G.pop()
end
Screen._test={shorten=shorten,layout=Screen.layout}
-- Faults keep the native battle visible and paused. This compact message is
-- never used for ordinary cache misses or successful model buffering.
function Screen.drawRuntimeError(w,h,detail)
  if not (love and love.graphics) then return end
  local G=love.graphics;if not w then w,h=G.getDimensions() end
  detail=type(detail)=='table' and detail or {}
  local size=math.max(10,math.min(18,w/45));local f=font(size)
  local pad=math.min(12,w*.025);local width=math.max(1,w-pad*2)
  local maxReasonLines=math.max(1,math.min(3,math.floor((h*.32-24)/f:getHeight())-4))
  local panelH=math.min(h,24+f:getHeight()*(4+maxReasonLines*1.22))
  local identity=detail.species and tostring(detail.species) or 'MODEL UNAVAILABLE'
  if detail.dex then identity=identity..' # '..tostring(detail.dex) end
  if detail.variant then identity=identity..' / '..tostring(detail.variant) end
  if detail.kind then identity=identity..' / '..tostring(detail.kind) end
  G.push('all');G.origin();G.setShader();if G.setScissor then G.setScissor() end
  plate(0,0,w,panelH,color.panel)
  text('COLOSSEUM / MODEL DIAGNOSTIC',pad,6,width,size,color.muted,'center')
  text(identity,pad,8+f:getHeight(),width,size,color.error,'center')
  local bottom=wrapped(detail.error or 'Failure detail unavailable; see saved log.',
    pad,10+f:getHeight()*2,width,size,color.error,maxReasonLines)
  text('A: RETRY    START: EXIT',pad,bottom+2,width,size,color.ink,'center')
  text('Log: build/model-cache-error.txt',pad,bottom+4+f:getHeight(),width,size,color.muted,'center')
  G.pop()
end
return Screen
