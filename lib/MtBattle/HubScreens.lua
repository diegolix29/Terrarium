-- Mt. Battle 100 hub UI screens: offer/rules text, 6-of-N team select
-- (legacy/Gen2 path), Challenge Bag review, BEGIN CHALLENGE confirmation,
-- and the real native Team Review (Gen 1) -- see pushTeamReview below.
--
-- Selection-state logic (TeamSelectState) is real, pure, and fully
-- tested headlessly. Screen PLACEMENT follows the confirmed native
-- pattern -- game.stack:push(state) where state is a plain table with
-- update/draw methods the engine calls per-frame (UIMain.lua's
-- GoldCompat.openGoldUISettings, UIMain.lua:2370-2415, is the concrete
-- precedent for a self-contained pushed screen, as opposed to this mod's
-- MORE COMMON monkeypatch-a-native-screen style, which doesn't apply
-- here since none of these screens exist natively).
--
-- The hub deliberately renders its OWN presentation chrome over HubStage's
-- real Mt. Battle Summit/Wes scene. Native Bag/Box screens still own their
-- actual contents; this module only replaces the previously-placeholder hub
-- composition. The center of the screen is kept clear so the animated trainer
-- and summit remain the visual anchor rather than being buried under menus.
local V=... or {}
local req=V.engineRequire or require
local HSc={}

-- Real climb-length choices exposed by the Summit setup screen. 100 remains the
-- compatibility/default path, but shorter formats are first-class run options.
HSc.CLIMB_FORMATS={3,5,10,25,50,100}

-- Injected exactly like V.StandaloneHost is elsewhere in this feature:
-- default to the real engine modules, but let a test swap in a stub so
-- pushTeamReview's PC wiring can be verified without constructing
-- the real (data-heavier) native BoxMenu screen. Menu itself is
-- NOT worth stubbing -- src/ui/Menu.lua's :new() is cheap, pure, and
-- calls no love.graphics (confirmed by direct read; only :draw() does),
-- so tests get real cursor/button-press behavior for free.
local Screens=V.engineScreens or req("src.ui.Screens")
local Menu=V.engineMenu or req("src.ui.Menu")
local MovePrep=V.MtBattleMovePrep
local SaveState=V.MtBattleSaveState
local ChallengeBag=V.MtBattleChallengeBag
local BattleSettings=V.BattleSettings
local GenerationCompat=V.GenerationCompat
local ColosseumFont=V.ColosseumFont
local EngineFont=V.engineFont
if not EngineFont then
  local ok,value=pcall(req,"src.render.Font")
  if ok then EngineFont=value end
end

-- ===== Shared presentation layer ==========================================
--
-- This is intentionally self-contained rather than reaching into UIMain.lua's
-- private drawing helpers. HubScreens is also used by the CBE-only package, and
-- coupling a challenge-critical screen to the optional UI overhaul would make
-- the entry flow disappear when the companion UI is not installed.
local fontCache={}
local retailFontActive=false
local HUB_UI_WIDTH,HUB_UI_HEIGHT=640,360
local PLATFORM_OS=tostring(V.PlatformOS or "")
if PLATFORM_OS=="" and love and love.system and type(love.system.getOS)=="function" then
  local ok,value=pcall(love.system.getOS)
  if ok and value then PLATFORM_OS=tostring(value) end
end
local MOBILE_RUNTIME=PLATFORM_OS=="Android" or PLATFORM_OS=="iOS"
local function gfx()
  return love and love.graphics or nil
end
local function clamp(v,a,b)return math.max(a,math.min(b,v))end
local function mobileSafeArea(x,y,w,h)
  if not MOBILE_RUNTIME then return x,y,w,h,0 end
  -- Gen1Recomp's mobile virtual pad is composited over the final game target,
  -- so love.window.getSafeArea() cannot reserve it for us. Keep Mt. Battle's
  -- interactive chrome above that overlay while leaving the Summit visible
  -- behind the controls. Portrait/foldable layouts need a deeper reservation;
  -- landscape only needs the lower control band cleared.
  local portrait=(w/h)<1.08
  local reserve
  if portrait then
    reserve=clamp(h*.235,math.min(96,h*.12),math.min(340,h*.30))
  else
    reserve=clamp(h*.12,36,math.min(100,h*.18))
  end
  return x,y,w,math.max(1,h-reserve),reserve
end
local function fontFor(px)
  local g=gfx();if not (g and g.newFont) then return nil end
  px=math.max(10,math.floor((tonumber(px) or 16)+.5))
  if not fontCache[px] then
    local ok,f
    if ColosseumFont and type(ColosseumFont.font)=="function" then
      -- Genuine GC6E01 font-0 raster + variable metrics. The source bank is I4
      -- antialiased, so linear scaling preserves its native coverage values.
      ok,f=pcall(ColosseumFont.font,px,"linear")
      if ok and f then retailFontActive=true end
    end
    if not ok or not f then
      if EngineFont and EngineFont.PLAINPIXEL then
        ok,f=pcall(g.newFont,EngineFont.PLAINPIXEL,px,"normal")
      else
        ok,f=pcall(g.newFont,px)
      end
      if ok and f and f.setFilter then pcall(f.setFilter,f,"nearest","nearest") end
    end
    if ok and f then fontCache[px]=f else fontCache[px]=false end
  end
  return fontCache[px] or nil
end
local function safeArea(viewport)
  local g=gfx()
  -- `render.hud` runs AFTER Renderer:endFrame and hands us the dimensions of
  -- the actual target Gen1Recomp just composited into (the whole window on the
  -- normal desktop path, or the captured game viewport when render.viewport is
  -- active). Those coordinates are already screen-space: do not inspect the
  -- native Game Boy UI canvas or apply Renderer scaling a second time.
  if type(viewport)=="table" then
    local vw,vh=tonumber(viewport.width),tonumber(viewport.height)
    if vw and vh and vw>0 and vh>0 then
      if g and type(g.getDimensions)=="function" and love.window and type(love.window.getSafeArea)=="function" then
        local ww,wh=g.getDimensions()
        if math.abs(vw-ww)<1 and math.abs(vh-wh)<1 then
          local ok,x,y,sw,sh=pcall(love.window.getSafeArea)
          if ok and type(x)=="number" and type(y)=="number" and type(sw)=="number" and type(sh)=="number"
              and x>=0 and y>=0 and sw>0 and sh>0 and x+sw<=vw+1 and y+sh<=vh+1 then
            return mobileSafeArea(x,y,sw,sh)
          end
        end
      end
      return mobileSafeArea(0,0,vw,vh)
    end
  end
  if not g then return mobileSafeArea(0,0,1280,720) end
  -- Direct smoke tests / older hosts may call a hub draw without render.hud's
  -- viewport payload. In that fallback only, respect an already-bound target
  -- rather than using physical-window dimensions inside a smaller canvas.
  if type(g.getCanvas)=="function" then
    local ok,canvas=pcall(g.getCanvas)
    if ok and canvas and type(canvas.getDimensions)=="function" then
      local okSize,cw,ch=pcall(canvas.getDimensions,canvas)
      if okSize and tonumber(cw) and tonumber(ch) and cw>0 and ch>0 then
        return mobileSafeArea(0,0,cw,ch)
      end
    end
  end
  local w,h=g.getDimensions()
  local x,y,sw,sh=0,0,w,h
  if love.window and type(love.window.getSafeArea)=="function" then
    local ok,a,b,c,d=pcall(love.window.getSafeArea)
    if ok and tonumber(c) and tonumber(d) and c>0 and d>0 then x,y,sw,sh=a,b,c,d end
  end
  return mobileSafeArea(x,y,sw,sh)
end
local function normalizedClimbLength(value)
  value=math.floor(tonumber(value) or 100)
  for _,n in ipairs(HSc.CLIMB_FORMATS) do if value==n then return n end end
  return 100
end
local function climbLengthFor(game,fallback)
  local run=game and game.save and game.save.mtBattleChallenge
  if run and run.active==true and run.totalFights~=nil then return normalizedClimbLength(run.totalFights) end
  if fallback~=nil then return normalizedClimbLength(fallback) end
  if run and run.totalFights~=nil then return normalizedClimbLength(run.totalFights) end
  return 100
end
local function layoutFor(width,height,x,y)
  width=math.max(320,tonumber(width) or 1280);height=math.max(240,tonumber(height) or 720)
  x=tonumber(x) or 0;y=tonumber(y) or 0
  -- The Gen-1 hub uses a 640x360 logical surface. Keep the same composition at
  -- that height instead of clamping typography/spacing to the old 720p floor,
  -- which made the four interaction rows collide even after the canvas fix.
  local s=MOBILE_RUNTIME and clamp(math.min(height/900,width/720),.55,1.18)
    or clamp(height/900,.55,1.28)
  -- Keep the Summit as the dominant visual. Earlier Battle 100 chrome occupied
  -- almost the complete top/left/bottom thirds at desktop resolutions, hiding
  -- the arena the player is meant to be standing in while setting up the run.
  local margin=clamp(math.min(width,height)*.018,11*s,22*s)
  local headerH=clamp(height*.085,54*s,82*s)
  local footerH=clamp(height*.095,66*s,92*s)
  local gap=clamp(11*s,8,18)
  local bodyY=y+margin+headerH+gap
  local bodyH=height-margin*2-headerH-footerH-gap*2
  local portrait=width/height<1.30
  local leftW=portrait and (width-margin*2) or clamp(width*.255,280*s,450*s)
  local rightW=portrait and 0 or clamp(width*.18,210*s,315*s)
  -- On phones/foldables a full-height setup plate creates a giant empty slab
  -- after the five Climb actions and hides most of the live Summit. Compact the
  -- interaction card and leave the remaining middle band intentionally open.
  local leftH=bodyH
  if MOBILE_RUNTIME and portrait then
    leftH=math.min(bodyH,clamp(455*s,350,540))
  end
  return {
    x=x,y=y,w=width,h=height,s=s,margin=margin,gap=gap,
    header={x=x+margin,y=y+margin,w=width-margin*2,h=headerH},
    left={x=x+margin,y=bodyY,w=leftW,h=leftH},
    right=rightW>0 and {x=x+width-margin-rightW,y=bodyY,w=rightW,h=bodyH} or nil,
    footer={x=x+margin,y=y+height-margin-footerH,w=width-margin*2,h=footerH},
    portrait=portrait,mobile=MOBILE_RUNTIME,
  }
end
local function challengeLayout(width,height,x,y)
  width=math.max(320,tonumber(width) or HUB_UI_WIDTH);height=math.max(240,tonumber(height) or HUB_UI_HEIGHT)
  x=tonumber(x) or 0;y=tonumber(y) or 0
  local portrait=width/height<1.30
  local s=MOBILE_RUNTIME and clamp(math.min(height/HUB_UI_HEIGHT,width/720),.72,1.20)
    or clamp(height/HUB_UI_HEIGHT,.72,1.35)
  local margin=clamp(math.min(width,height)*.022,8*s,17*s)
  local top=y+clamp(height*.115,34*s,58*s)
  local bottom=clamp(height*.045,12*s,24*s)
  if MOBILE_RUNTIME and portrait then
    -- A phone cannot use the desktop side rails, but simply stacking two nearly
    -- full-height panels hid Wes and the Summit entirely. Reserve a deliberate
    -- hero band between a compact action card and a compact challenge summary.
    local gap=clamp(9*s,7,13)
    local available=math.max(1,height-(top-y)-bottom)
    -- Size the action card from its real six-row minimum, not a screen-height
    -- percentage. This keeps MOVE PREP through CANCEL above the status strip on
    -- the 1182x1311 foldable target while still leaving a large live-stage band.
    local actionGap=clamp(4*s,3,6)
    local actionPad=clamp(14*s,11,18)
    local statusH=clamp(34*s,30,42)
    local minButtonH=28*s
    local minActionH=53*s+statusH+actionPad+actionGap+6*minButtonH+5*actionGap
    local leftH=math.max(clamp(available*.32,220*s,320*s),minActionH)
    local rightH=clamp(available*.18,130*s,185*s)
    -- Protect at least 28% of the safe viewport for Wes/Summit. If a very short
    -- device cannot satisfy that plus both cards, compress the summary first;
    -- never shrink the interactive six-row action card below its fitted minimum.
    local minHero=height*.28
    local maxCards=math.max(1,available-minHero-gap*2)
    if leftH+rightH>maxCards then rightH=math.max(84*s,maxCards-leftH) end
    local fullW=width-margin*2
    local clearY=top+leftH+gap
    local rightY=top+available-rightH
    local clear={x=x+margin*2,y=clearY,w=math.max(1,width-margin*4),h=math.max(1,rightY-gap-clearY)}
    local left={x=x+margin,y=top,w=fullW,h=leftH}
    local right={x=x+margin,y=rightY,w=fullW,h=rightH}
    return {x=x,y=y,w=width,h=height,s=s,margin=margin,left=left,right=right,clear=clear,
      portrait=true,mobile=true,stacked=true,heroStack=true}
  end
  local leftW=clamp(width*.255,170*s,235*s)
  local rightW=clamp(width*.18,140*s,190*s)
  local left={x=x+margin,y=top,w=leftW,h=height-(top-y)-bottom}
  local right={x=x+width-margin-rightW,y=top+clamp(14*s,10,22),w=rightW,
    h=height-(top-y)-bottom-clamp(28*s,20,38)}
  local clear={x=left.x+left.w+margin,y=y,w=right.x-(left.x+left.w)-margin*2,h=height}
  return {x=x,y=y,w=width,h=height,s=s,margin=margin,left=left,right=right,clear=clear,
    portrait=portrait,mobile=MOBILE_RUNTIME,stacked=false}
end
HSc._test=HSc._test or {}
HSc._test.layoutFor=layoutFor
HSc._test.challengeLayout=challengeLayout
HSc._test.safeArea=safeArea

local ensureHudHook
local stateCanvasDraw -- referenced by Challenge Bag states declared before its body
local safeHubDraw
local function currentGeneration(game)
  if GenerationCompat and type(GenerationCompat.current)=="function" then
    local ok,value=pcall(GenerationCompat.current)
    if ok and tonumber(value) then return tonumber(value) end
  end
  return tonumber(game and game.save and game.save.generation) or 1
end
local function drawHubSurfaceFullWindow(winW,winH)
  local host=V.StandaloneHost
  if not (host and type(host.renderHubFrame)=="function") then return false end
  local ok,surface=pcall(host.renderHubFrame)
  if not (ok and surface and surface~=true and surface~=V.FALLBACK) then return false end
  local g=gfx();if not g then return false end
  local okSize,w,h=pcall(surface.getDimensions,surface)
  if not (okSize and tonumber(w) and tonumber(h) and w>0 and h>0) then return false end
  winW=math.max(1,tonumber(winW) or w);winH=math.max(1,tonumber(winH) or h)
  -- Game2 gives the hub a physical-window widescreen pass. Preserve the Summit
  -- render's authored aspect ratio rather than independently scaling X/Y to the
  -- handset/window dimensions (which visibly squashed the arena on tall mobile
  -- displays and 16:10-ish desktop windows). Use a centered aspect-fill crop: the
  -- environment still owns every physical pixel, but circles/characters/terrain
  -- keep their source proportions just like the normal CBE battle compositor.
  local scale=math.max(winW/w,winH/h)
  local drawW,drawH=w*scale,h*scale
  local x=(winW-drawW)*.5;local y=(winH-drawH)*.5
  g.setColor(1,1,1,1)
  g.draw(surface,x,y,0,scale,scale)
  return true
end
local function hubSurface(state)
  state.isOpaque=false
  -- Do NOT expose uiSize()/wantsFillScale here. Gen1Recomp resolves those
  -- methods before Renderer:beginFrame and they only control the native UI
  -- canvas/final blit. The user's 1.3.7 runtime proved that treating the Mt.
  -- Battle hub as a 640x360 Game Boy surface is not portable: it can leave the
  -- custom composition trapped in a small top-left target. The hub chrome is a
  -- true screen-space overlay and is drawn through render.hud below instead.
  state.__cbeMtBattleHubSurface=true
  if currentGeneration(state.game)==2 then
    -- Game2 owns its physical background through a widescreen surface rather
    -- than Renderer.worldOverride. A transparent non-wide hub therefore leaves
    -- the live Pokemon Center/map visible underneath its chrome. Make only the
    -- Gen-II hub a full-window owner; Gen I keeps the proven final-HUD split.
    state.__cbeMtBattleGen2Wide=true
    state.drawsWidescreen=function() return true end
    state.wantsFillScale=function() return false end
    state.drawWidescreen=function(self,winW,winH)
      if drawHubSurfaceFullWindow(winW,winH) then return true end
      local g=gfx()
      if g then
        g.setColor(.025,.075,.145,1)
        g.rectangle("fill",0,0,tonumber(winW) or 160,tonumber(winH) or 144)
        g.setColor(1,1,1,1)
      end
      return false
    end
  end
  if ensureHudHook then ensureHudHook() end
  return state
end
HSc._test.hubSurface=hubSurface
HSc._test.currentGeneration=currentGeneration
HSc._test.drawHubSurfaceFullWindow=drawHubSurfaceFullWindow

local C={
  -- Match lib/BattleMenuUI.lua's Start-menu BATTLE surface rather than growing
  -- a second Mt. Battle-only visual language.
  ink={.99,.94,.74,1},muted={.76,.80,.73,1},dim={.50,.56,.51,1},
  panel={.072,.084,.080,.955},panelStrong={.13,.15,.14,.98},
  panelSoft={.11,.125,.115,.36},line={.46,.48,.43,.94},
  gold={.96,.91,.72,1},goldSoft={.30,.32,.29,.82},
  orange={.96,.53,.23,1},red={.82,.31,.25,1},cyan={.38,.70,.68,1},green={.45,.82,.56,1},
  disabled={.31,.34,.39,1},shadow={0,0,0,.42},
}
local function set(g,c,a)
  g.setColor(c[1],c[2],c[3],a or c[4] or 1)
end
local function rr(g,mode,x,y,w,h,r)
  if w<=0 or h<=0 then return end
  g.rectangle(mode,x,y,w,h,r or 0,r or 0)
end
local function text(g,value,x,y,size,color,align,width)
  local f=fontFor(size);if f and g.setFont then g.setFont(f) end
  local value=tostring(value or "")
  if color and (color[1]+color[2]+color[3])>1.55 then
    g.setColor(0,0,0,retailFontActive and (0xC0/0xFF) or .46)
    if align and width and g.printf then g.printf(value,x+1,y+1,width,align)
    else g.print(value,x+1,y+1) end
  end
  set(g,color or C.ink)
  if align and width and g.printf then g.printf(value,x,y,width,align)
  else g.print(value,x,y) end
end
local function textWidth(value,size)
  local f=fontFor(size);return f and f:getWidth(tostring(value or "")) or #tostring(value or "")*(tonumber(size) or 16)*.55
end
local function fitTextSize(value,preferred,minimum,maxWidth)
  local size=math.max(tonumber(minimum) or 6,tonumber(preferred) or 12)
  local floor=tonumber(minimum) or 6
  while size>floor and textWidth(value,size)>maxWidth do size=size-.5 end
  return math.max(floor,size)
end
local function panel(g,r,strong,alpha)
  local c=clamp(math.min(r.w,r.h)*.055,7,15)
  set(g,C.shadow,.34)
  g.polygon("fill",r.x+c+4,r.y+5,r.x+r.w-c+4,r.y+5,r.x+r.w+4,r.y+c+5,
    r.x+r.w-c+4,r.y+r.h+5,r.x+c+4,r.y+r.h+5,r.x+4,r.y+r.h-c+5,r.x+4,r.y+c+5)
  set(g,strong and C.panelStrong or C.panel,alpha)
  g.polygon("fill",r.x+c,r.y,r.x+r.w-c,r.y,r.x+r.w,r.y+c,
    r.x+r.w-c,r.y+r.h,r.x+c,r.y+r.h,r.x,r.y+r.h-c,r.x,r.y+c)
  set(g,C.line);g.setLineWidth(1.25)
  g.line(r.x+c+4,r.y+3,r.x+r.w-c-4,r.y+3)
  g.line(r.x+4,r.y+c+2,r.x+4,r.y+r.h-c-2)
end
local function sectionRule(g,x,y,w)
  set(g,C.gold,.92);rr(g,"fill",x,y,clamp(w*.16,38,92),3,1.5)
  set(g,C.line,.42);rr(g,"fill",x+clamp(w*.16,38,92)+8,y+1,w-clamp(w*.16,38,92)-8,1,0)
end
local function titleHeader(g,L,kicker,title,detail,rightMeta)
  local r=L.header;panel(g,r,true)
  local s=L.s;local pad=clamp(18*s,14,26)
  set(g,C.red);rr(g,"fill",r.x,r.y,7*s,r.h,5*s)
  text(g,kicker,r.x+pad,r.y+8*s,clamp(12*s,9,16),C.gold)
  local titleSize=fitTextSize(title,clamp(27*s,17,36),13,r.w-pad*2)
  text(g,title,r.x+pad,r.y+24*s,titleSize,C.ink)
  if detail and detail~="" then
    local fs=fitTextSize(detail,clamp(12*s,9,16),7,r.w*.42);local tw=textWidth(detail,fs)
    text(g,detail,r.x+r.w-pad-tw,r.y+12*s,fs,C.muted)
  end
  local right=rightMeta or "100 BATTLES  /  LV. 50  /  DOUBLES"
  local fs=fitTextSize(right,clamp(10*s,8,13),6.5,r.w-pad*2);local tw=textWidth(right,fs)
  text(g,right,r.x+r.w-pad-tw,r.y+r.h-20*s,fs,C.dim)
end
local function button(g,r,selected,title,sub,accent)
  local s=clamp(r.h/76,.72,1.3)
  if selected then
    set(g,C.goldSoft)
    g.polygon("fill",r.x+11*s,r.y+2*s,r.x+r.w-8*s,r.y+2*s,r.x+r.w,r.y+r.h-3*s,
      r.x+11*s,r.y+r.h-3*s)
    set(g,C.orange)
    g.polygon("fill",r.x+8*s,r.y+r.h*.50,r.x,r.y+r.h*.26,r.x,r.y+r.h*.74)
  else
    set(g,C.panelSoft);rr(g,"fill",r.x+11*s,r.y+2*s,r.w-15*s,r.h-5*s,0)
  end
  local tx=r.x+19*s
  text(g,title,tx,r.y+8*s,clamp(16*s,12,20),selected and C.ink or C.muted)
  if sub then text(g,sub,tx,r.y+29*s,clamp(10*s,8,12),selected and C.muted or C.dim,"left",r.w-28*s) end
end
local function speciesName(game,mon)
  if not mon then return "EMPTY" end
  local def=game and game.data and game.data.pokemon and game.data.pokemon[mon.species]
  return tostring(mon.nickname or mon.name or (def and def.name) or mon.species or "POKéMON"):upper()
end
local function partyReady(game)
  local party=game and game.save and game.save.party or {}
  if #party~=6 then return false,#party end
  for _,mon in ipairs(party) do if mon and mon.isEgg then return false,#party end end
  return true,#party
end
local function selectedTeam(model)
  if not (model and type(model.selected)=="table" and type(model.candidates)=="table") then return nil end
  local order={}
  for i in pairs(model.selected) do order[#order+1]=i end
  table.sort(order,function(a,b)
    return (model.pickOrder and model.pickOrder[a] or a)<(model.pickOrder and model.pickOrder[b] or b)
  end)
  local team={}
  for _,i in ipairs(order) do team[#team+1]=model.candidates[i] end
  return team
end
local function drawTeamStrip(g,L,game,model)
  local r=L.footer;panel(g,r,true);local s=L.s
  local team=selectedTeam(model)
  local ready,count
  if team then ready=#team==HSc.MAX_TEAM;count=#team else ready,count=partyReady(game) end
  local pad=clamp(18*s,13,25)
  text(g,"CHALLENGE TEAM",r.x+pad,r.y+8*s,clamp(10.5*s,9,14),C.gold)
  local status=ready and "READY" or (tostring(count).." / 6")
  local statusColor=ready and C.green or C.gold
  local fs=clamp(10.5*s,9,14);text(g,status,r.x+r.w-pad-textWidth(status,fs),r.y+8*s,fs,statusColor)

  local party=team or (game and game.save and game.save.party or {})
  local slotsY=r.y+27*s;local slotGap=clamp(6*s,4,9)
  local usableW=r.w-pad*2
  local slotW=(usableW-slotGap*5)/6
  local slotH=clamp(34*s,24,42)
  for i=1,6 do
    local x=r.x+pad+(i-1)*(slotW+slotGap);local mon=party[i]
    set(g,mon and C.panelSoft or C.panel);rr(g,"fill",x,slotsY,slotW,slotH,6*s)
    set(g,mon and C.line or C.disabled,.7);rr(g,"line",x+.5,slotsY+.5,slotW-1,slotH-1,6*s)
    local num=tostring(i)
    text(g,num,x+7*s,slotsY+4*s,clamp(8.5*s,7.5,11),mon and C.gold or C.dim)
    text(g,speciesName(game,mon),x+7*s,slotsY+16*s,clamp(8.5*s,7,11),mon and C.ink or C.dim,"left",math.max(1,slotW-14*s))
  end
end
local RULES={
  {"FORMAT","100 consecutive trainer battles"},
  {"LEVEL","Your six are normalized to Lv. 50"},
  {"ROSTER","Team locks when the challenge begins"},
  {"MOVES","Prep changes lock with the challenge team"},
  {"PROGRESS","Run state is separate from your live party"},
}
local function ruleDescription(row,totalFights)
  if row and row[1]=="FORMAT" then
    return tostring(normalizedClimbLength(totalFights)).." consecutive trainer battles"
  end
  return row and row[2] or ""
end
local function drawRulesRail(g,L,game,model,totalFights)
  local r=L.right;if not r then return end
  panel(g,r,false);local s=L.s;local pad=clamp(18*s,14,25)
  text(g,"CHALLENGE FORMAT",r.x+pad,r.y+17*s,clamp(16*s,12,21),C.ink)
  sectionRule(g,r.x+pad,r.y+47*s,r.w-pad*2)
  local y=r.y+66*s
  local total=climbLengthFor(game,totalFights)
  for _,row in ipairs(RULES) do
    text(g,row[1],r.x+pad,y,clamp(10*s,9,13),C.gold)
    text(g,ruleDescription(row,total),r.x+pad,y+17*s,clamp(11*s,9,14),C.muted,"left",r.w-pad*2)
    y=y+52*s
  end
  local team=selectedTeam(model)
  local ready
  if team then ready=#team==HSc.MAX_TEAM else ready=partyReady(game) end
  local chipH=clamp(42*s,34,52);local cy=r.y+r.h-chipH-pad
  set(g,ready and C.green or C.gold,.16);rr(g,"fill",r.x+pad,cy,r.w-pad*2,chipH,7*s)
  set(g,ready and C.green or C.gold,.88);rr(g,"line",r.x+pad+.5,cy+.5,r.w-pad*2-1,chipH-1,7*s)
  text(g,ready and "TEAM READY TO LOCK" or "TEAM REQUIRES 6 POKéMON",r.x+pad+12*s,cy+13*s,clamp(11*s,9,14),ready and C.green or C.gold)
end
local REVIEW_DRAW={
  ["MOVE PREP"]={title="MOVE PREP",sub="Lv.100 learnset + compatible TM/HM",accent=C.cyan},
  ["START CHALLENGE"]={title="LOCK TEAM & START",sub="Lock six / enter Battle 1",accent=C.green},
  CANCEL={title="LEAVE MT. BATTLE",sub="Return to overworld",accent=C.red},
  -- Presentation aliases used by the rental/team-builder branch. Keeping these
  -- here means that branch can share this exact screen instead of growing a
  -- second, visually divergent Battle 100 menu.
  ["USE PARTY"]={title="USE CURRENT PARTY",sub="Prepare the six you brought",accent=C.green},
  ["RENTAL TEAM"]={title="BUILD CHALLENGE TEAM",sub="Party + all PC boxes + Gen 1 / 2 / 3 rentals",accent=C.gold},
  ["CUSTOM TEAMS"]={title="CUSTOM TEAMS",sub="Save / load / delete reusable challenge teams",accent=C.cyan},
  ["ADJUST MOVES"]={title="ADJUST MOVE LOADOUT",sub="Review legal move pool",accent=C.cyan},
  ["BEGIN CHALLENGE"]={title="LOCK TEAM & START",sub="Lock six / enter Battle 1",accent=C.green},
  BACK={title="BACK TO SETUP",sub="Keep preparing your team",accent=C.red},
}
local function challengeTab(g,r,title,s)
  local h=clamp(24*s,20,32)
  local w=math.min(r.w*.82,175*s)
  set(g,C.panelStrong)
  g.polygon("fill",r.x+16*s,r.y-h,r.x+w,r.y-h,r.x+w+14*s,r.y,r.x+8*s,r.y)
  text(g,title,r.x+28*s,r.y-h+4*s,clamp(13*s,11,17),C.gold)
end
local function drawChallengeInfo(g,r,game,s,fallbackTotal,providedTeam)
  panel(g,r,true)
  local pad=clamp(14*s,11,18)
  text(g,"CHALLENGE INFO",r.x+pad,r.y+13*s,clamp(14*s,11,17),C.ink)
  sectionRule(g,r.x+pad,r.y+34*s,r.w-pad*2)
  local run=game and game.save and game.save.mtBattleChallenge or nil
  local total=climbLengthFor(game,fallbackTotal)
  local ready,count
  if type(providedTeam)=="table" then count=#providedTeam;ready=count==HSc.MAX_TEAM
  else ready,count=partyReady(game) end
  local status=(run and run.active) and ("BATTLE "..tostring(math.max(1,math.floor(tonumber(run.currentFight) or 1)))) or "NEW RUN"
  local rows={
    {"FORMAT","DOUBLE BATTLE"},
    {"CLIMB",tostring(total).." BATTLES"},
    {"LEVEL","LV. 50 LOCK"},
    {"CONTINUE","1 PER RUN"},
    {"STATUS",status},
  }
  local y=r.y+48*s
  local rowH=clamp(25*s,21,31)
  for i,row in ipairs(rows) do
    if i%2==0 then set(g,C.panelSoft,.26);rr(g,"fill",r.x+pad,y-2*s,r.w-pad*2,rowH,0) end
    text(g,row[1],r.x+pad+4*s,y+4*s,clamp(9.5*s,8,11),C.dim)
    local fs=clamp(9.5*s,8,11);local tw=textWidth(row[2],fs)
    text(g,row[2],r.x+r.w-pad-4*s-tw,y+4*s,fs,i==5 and C.gold or C.muted)
    y=y+rowH
  end
  sectionRule(g,r.x+pad,y+2*s,r.w-pad*2)
  y=y+13*s
  local teamLabel=ready and "TEAM READY" or (tostring(count).." / 6 POKéMON")
  text(g,"TEAM",r.x+pad+4*s,y,clamp(9*s,8,11),C.dim)
  local tfs=clamp(9*s,8,11);local tw=textWidth(teamLabel,tfs)
  text(g,teamLabel,r.x+r.w-pad-4*s-tw,y,tfs,ready and C.green or C.gold)
  y=y+18*s
  local party=type(providedTeam)=="table" and providedTeam or (game and game.save and game.save.party or {})
  local gap=5*s;local cw=(r.w-pad*2-gap)/2;local ch=clamp(18*s,16,22)
  for i=1,6 do
    local col=(i-1)%2;local row=math.floor((i-1)/2);local x=r.x+pad+col*(cw+gap);local yy=y+row*(ch+4*s)
    local mon=party[i]
    set(g,mon and C.panelSoft or C.disabled,.42);rr(g,"fill",x,yy,cw,ch,0)
    text(g,tostring(i),x+5*s,yy+3*s,clamp(8*s,7,10),mon and C.orange or C.dim)
    text(g,speciesName(game,mon):sub(1,8),x+17*s,yy+3*s,clamp(8*s,7,10),mon and C.muted or C.dim,"left",math.max(1,cw-20*s))
  end
end
local function drawChallengeInfoCompact(g,r,game,s,fallbackTotal,providedTeam)
  panel(g,r,true,.76)
  local pad=clamp(12*s,9,15)
  local run=game and game.save and game.save.mtBattleChallenge or nil
  local total=climbLengthFor(game,fallbackTotal)
  local ready,count
  if type(providedTeam)=="table" then count=#providedTeam;ready=count==HSc.MAX_TEAM
  else ready,count=partyReady(game) end
  local status=(run and run.active) and ("BATTLE "..tostring(math.max(1,math.floor(tonumber(run.currentFight) or 1)))) or "NEW RUN"
  text(g,"CHALLENGE INFO",r.x+pad,r.y+9*s,clamp(11*s,9,14),C.ink)
  sectionRule(g,r.x+pad,r.y+27*s,r.w-pad*2)
  local y=r.y+37*s
  text(g,"DOUBLE BATTLE   //   "..tostring(total).." BATTLES   //   LV. 50 LOCK",r.x+pad,y,
    clamp(7.8*s,6.8,9.5),C.muted,"left",r.w-pad*2)
  y=y+18*s
  local team=ready and "TEAM READY" or ("TEAM "..tostring(count).." / 6")
  text(g,"1 CONTINUE   //   "..team.."   //   "..status,r.x+pad,y,clamp(7.8*s,6.8,9.5),
    ready and C.green or C.gold,"left",r.w-pad*2)
end

-- Dedicated mobile chrome shares the source font and screen-space viewport,
-- but not desktop density. Native Menu/state updates remain authoritative.
local Mobile=V.MtBattleMobileHubUI
if Mobile then
  Mobile.configure({mobile=MOBILE_RUNTIME,safeArea=safeArea,gfx=gfx,fontFor=fontFor,
    text=text,panel=panel,speciesName=speciesName,colors=C})
end
HSc._test.mobileUI=Mobile

local function mobileBrowseStatus(state)
  if not (Mobile and Mobile.active()) then return false end
  local input=state.game and state.game.input
  if not (input and input.wasPressed) then return false end
  local count=state.__cbeMobileLayout and state.__cbeMobileLayout.count or 1
  local cursor=state.mobileInfoCursor or 1
  if input:wasPressed("up") then state.mobileInfoCursor=math.max(1,cursor-1);return true end
  if input:wasPressed("down") then state.mobileInfoCursor=math.min(math.max(1,count),cursor+1);return true end
  return false
end
local function mobileStat(label,value,detail)
  return {label=tostring(label),badge=tostring(value or "--"),detail=detail or (tostring(label)..": "..tostring(value or "--"))}
end

local function drawTeamReview(menu,viewport)
  if Mobile and Mobile.active(viewport) then
    local rows={};for i,item in ipairs(menu.items or {}) do
      local meta=REVIEW_DRAW[item.label] or {}
      rows[i]={label=meta.title or item.label,detail=meta.sub or meta.title or item.label}
    end
    local team
    if type(menu.teamProvider)=="function" then local ok,value=pcall(menu.teamProvider);if ok and type(value)=="table" then team=value end end
    return Mobile.draw(menu,viewport,{title=menu.kind=="teamSourceChoice" and "CHOOSE YOUR TEAM" or "TEAM SETUP",
      subtitle=tostring(climbLengthFor(menu.game,menu.totalFights)).." BATTLES / LV. 50 / DOUBLES",
      rows=rows,cursor=menu.index or 1,team=team,detail=menu.saveMessage,
      hints={"UP/DOWN Browse   A Select   B Back","START Save game   SELECT Records"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=challengeLayout(sw,sh,sx,sy);local s=L.s
  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  -- The arena/Wes composition is the hero. Match the Start-menu BATTLE screen's
  -- light glass veil, then keep the entire center lane free of panels.
  set(g,{0,0,0,.09});g.rectangle("fill",sx,sy,sw,sh)
  local total=climbLengthFor(menu.game,menu.totalFights)
  local r=L.left;panel(g,r,true,L.heroStack and .78 or nil);challengeTab(g,r,"MT. BATTLE "..tostring(total),s)
  local pad=clamp(14*s,11,18)
  text(g,"CHALLENGE SETUP",r.x+pad,r.y+13*s,clamp(14*s,11,17),C.ink)
  text(g,"PREPARE / LOCK / CLIMB",r.x+pad,r.y+32*s,clamp(9*s,8,11),C.dim)
  sectionRule(g,r.x+pad,r.y+45*s,r.w-pad*2)
  local top=r.y+53*s;local gap=clamp(4*s,3,6)
  local statusH=clamp(34*s,30,42)
  local availableH=r.h-(top-r.y)-statusH-pad-gap
  local itemCount=math.max(1,#(menu.items or {}))
  -- Six setup rows now include CUSTOM TEAMS. Keep compact/mobile rails inside
  -- the same status/footer boundary instead of allowing the historical five-row
  -- minimum height to push the final action into the footer by a few pixels.
  local bh=clamp((availableH-gap*(itemCount-1))/itemCount,28*s,50*s)
  for i,item in ipairs(menu.items or {}) do
    local meta=REVIEW_DRAW[item.label] or {title=item.label,sub="",accent=C.gold}
    button(g,{x=r.x+pad,y=top+(i-1)*(bh+gap),w=r.w-pad*2,h=bh},menu.index==i,meta.title,L.heroStack and nil or meta.sub,meta.accent)
  end
  local providedTeam
  if type(menu.teamProvider)=="function" then
    local ok,team=pcall(menu.teamProvider)
    if ok and type(team)=="table" then providedTeam=team end
  end
  local ready,count
  if providedTeam then count=#providedTeam;ready=count==HSc.MAX_TEAM
  else ready,count=partyReady(menu.game) end
  local choosingSource=menu.kind=="teamSourceChoice"
  local sy0=r.y+r.h-statusH-pad
  set(g,choosingSource and C.gold or (ready and C.green or C.orange),.13);rr(g,"fill",r.x+pad,sy0,r.w-pad*2,statusH,0)
  local statusText=choosingSource and "SELECT CHALLENGE TEAM" or (ready and "TEAM READY TO LOCK" or ("TEAM  "..tostring(count).." / 6"))
  text(g,statusText,r.x+pad+10*s,sy0+6*s,
    clamp(10*s,8,12),choosingSource and C.gold or (ready and C.green or C.gold))
  text(g,"A SELECT   START SAVE   B BACK   SELECT RECORDS",r.x+pad+10*s,sy0+19*s,clamp(6.2*s,5.6,7.8),C.dim,"left",r.w-pad*2-14*s)
  if L.heroStack then drawChallengeInfoCompact(g,L.right,menu.game,s,menu.totalFights,providedTeam)
  else drawChallengeInfo(g,L.right,menu.game,s,menu.totalFights,providedTeam) end
  g.pop()
end

local function drawInfoState(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local rows={};local bag=state.kind=="bagReview"
    if bag then
      for item,count in pairs(type(state.content)=="table" and state.content or {}) do
        rows[#rows+1]={label=tostring(item):gsub("_"," "),badge="x"..tostring(count),detail="Challenge supplies are separate from your normal bag. Use them during run intermissions."}
      end
      table.sort(rows,function(a,b)return a.label<b.label end)
    else
      for i,row in ipairs(RULES) do rows[i]={label=row[1],detail=ruleDescription(row,climbLengthFor(state.game,state.totalFights))} end
    end
    state.__cbeMobileInfoCount=#rows
    return Mobile.draw(state,viewport,{title=bag and "CHALLENGE BAG" or "BEFORE YOU BEGIN",
      subtitle=tostring(climbLengthFor(state.game,state.totalFights)).." BATTLES / LV. 50 / DOUBLES",
      rows=rows,cursor=state.mobileInfoCursor or 1,
      hints={"UP/DOWN Review   A/B Continue",state.onRental and "SELECT Rental team" or "Your normal party and bag stay separate"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=layoutFor(sw,sh,sx,sy);local s=L.s
  g.push("all");g.origin();g.setShader();set(g,{0,0,0,.08});g.rectangle("fill",sx,sy,sw,sh)
  local kind=tostring(state.kind or "rules")
  local total=climbLengthFor(state.game,state.totalFights)
  titleHeader(g,L,"MT. BATTLE","BATTLE "..tostring(total).."  //  CHALLENGE BRIEFING",
    kind=="bagReview" and "CHALLENGE BAG" or "RUN RULES",tostring(total).." BATTLES  /  LV. 50  /  DOUBLES")
  local card=L.left
  if L.right then
    card={x=L.left.x,y=L.left.y,w=clamp(L.w*.32,L.left.w,560*s),h=L.left.h}
  end
  -- Rules are a briefing, not a full-height modal. Fit the complete source text
  -- into a compact plate and deliberately leave the lower/center Summit visible.
  if kind~="bagReview" then card.h=math.min(card.h,clamp(385*s,325,445)) end
  panel(g,card,true);local pad=clamp(18*s,14,25)
  if kind=="bagReview" then
    text(g,"CHALLENGE BAG",card.x+pad,card.y+16*s,clamp(19*s,15,25),C.ink)
    text(g,"These supplies belong to the run and do not consume your normal bag.",card.x+pad,card.y+45*s,clamp(10*s,8.5,13),C.muted,"left",card.w-pad*2)
    sectionRule(g,card.x+pad,card.y+73*s,card.w-pad*2)
    local rows={};for k,v in pairs(type(state.content)=="table" and state.content or {}) do rows[#rows+1]={tostring(k):gsub("_"," "),v} end
    table.sort(rows,function(a,b)return a[1]<b[1]end)
    local cols=card.w>700*s and 2 or 1;local rowH=clamp(38*s,31,48);local y=card.y+91*s
    for i,row in ipairs(rows) do
      local col=(i-1)%cols;local rowIndex=math.floor((i-1)/cols);local cw=(card.w-pad*2-(cols-1)*14*s)/cols
      local x=card.x+pad+col*(cw+14*s);local yy=y+rowIndex*(rowH+8*s)
      set(g,C.panelSoft);rr(g,"fill",x,yy,cw,rowH,6*s)
      text(g,row[1],x+12*s,yy+9*s,clamp(11*s,9,14),C.muted)
      local qty="×"..tostring(row[2]);text(g,qty,x+cw-12*s-textWidth(qty,12*s),yy+9*s,clamp(12*s,10,16),C.gold)
    end
  else
    text(g,"THE CLIMB",card.x+pad,card.y+15*s,clamp(19*s,15,25),C.ink)
    text(g,"Build one team for a "..tostring(total).."-battle endurance run across Mt. Battle.",card.x+pad,card.y+44*s,clamp(10*s,8.5,13),C.muted,"left",card.w-pad*2)
    sectionRule(g,card.x+pad,card.y+70*s,card.w-pad*2)
    local y=card.y+87*s
    for i,row in ipairs(RULES) do
      local cy=y+(i-1)*clamp(48*s,39,55)
      set(g,C.panelSoft);rr(g,"fill",card.x+pad,cy,card.w-pad*2,clamp(40*s,34,46),5*s)
      text(g,string.format("%02d",i),card.x+pad+10*s,cy+10*s,clamp(9.5*s,8,12),C.gold)
      text(g,row[1],card.x+pad+40*s,cy+6*s,clamp(9.5*s,8,12),C.ink)
      text(g,ruleDescription(row,total),card.x+pad+40*s,cy+20*s,clamp(8.5*s,7,11),C.muted,"left",card.w-pad*2-52*s)
    end
    if state.onRental then
      local ry=math.min(card.y+card.h-30*s,y+5*clamp(48*s,39,55)+3*s)
      set(g,C.gold,.12);rr(g,"fill",card.x+pad,ry,card.w-pad*2,22*s,4*s)
      text(g,"SELECT  RENTAL TEAM",card.x+pad+9*s,ry+5*s,clamp(8.5*s,7,11),C.gold)
    end
  end
  drawTeamStrip(g,L,state.game)
  local prompt=state.onRental and "A/B CONTINUE   SELECT RENTALS   RMB DRAG FREE LOOK" or "A/B CONTINUE   RMB DRAG FREE LOOK"
  text(g,prompt,L.footer.x+L.footer.w-16*s-textWidth(prompt,9*s),L.footer.y+L.footer.h-18*s,clamp(9*s,7.5,11),C.dim)
  g.pop()
end

local GENERATION_PREFERENCES={
  {id="all",label="GEN 1 + 2 + 3",sub="All source-backed National Dex species"},
}
HSc.GENERATION_PREFERENCES=GENERATION_PREFERENCES
local GENERATION_BY_ID={}
for i,row in ipairs(GENERATION_PREFERENCES) do GENERATION_BY_ID[row.id]=i end

local CLIMB_ACTIONS={"FORMAT","OPTIONS","RULESETS","HALL OF FAME","TEAM SETUP","BP REWARDS"}
-- THE CLIMB's right rail is opt-in contextual chrome. Merely landing the
-- left-side cursor on FORMAT must not populate the opposite side of the Summit;
-- only activating that submenu may expose its list. Keep this decision pure so
-- input-state tests can lock the visibility contract without a graphics stub.
local function climbDetailKind(state)
  if type(state)=="table" and state.activeSubscreen=="format" then return "format" end
  return nil
end
local RULESET_ROWS={
  {"BATTLE FORMAT","Choose 3, 5, 10, 25, 50, or 100 consecutive trainer battles.","RUN"},
  {"BATTLE TYPE","Trainer encounters use the Mt. Battle doubles battle path.","RUN"},
  {"GENERATIONS","Gen 1 + 2 + 3 stay active together; rental tabs are navigation only.","RUN"},
  {"TEAM SIZE","Lock exactly six eligible POKéMON before the first battle.","TEAM"},
  {"LEVEL","Challenge clones are normalized to Lv. 50; the live save team is unchanged.","TEAM"},
  {"MOVE ACCESS","MOVE PREP may use the full Lv. 1-100 learnset plus compatible TM/HM moves.","TEAM"},
  {"ROSTER LOCK","Species, rental identity, and prepared moves are frozen into the run snapshot at start.","TEAM"},
  {"CHALLENGE BAG","Run supplies are isolated from the player's normal inventory.","RESOURCES"},
  {"CONTINUE","One Continue is available per run and retries the same persisted encounter.","RESOURCES"},
  {"SUSPEND / RESUME","A run can be saved and suspended at safe decision boundaries without abandoning it.","RESOURCES"},
  {"OPPONENTS","Teams are generated deterministically from the run seed and difficulty curve.","PROGRESSION"},
  {"MILESTONES","Runs that reach them use the Area Leader difficulty/presentation path every 10th battle.","PROGRESSION"},
  {"XP BANK","Battle rewards accumulate in the run-local XP Bank until a successful clear.","PROGRESSION"},
  {"RECORDS","Battle attempts, run totals, completed runs, and Hall of Fame data persist.","PROGRESSION"},
}
local OPTION_ROWS={
  {id="freeLookEnabled",label="FREE LOOK CAMERA",detail="Right-drag or touch to inspect the live Summit while setup screens are open."},
  {id="cameraEnabled",label="BATTLE CAMERA",detail="Use the Colosseum-authored battle camera layer when the challenge enters combat."},
  {id="autoProgressEnabled",label="AUTO BATTLE FLOW",detail="Advance non-choice battle text and presentation beats automatically when safe."},
  {id="battleSoundsEnabled",label="BATTLE SOUNDS",detail="Choose Colosseum battle sound presentation or the host game's original sound path."},
  {id="bossIntroEnabled",label="BOSS INTRO",detail="Enable the optional special-opponent intro presentation when an encounter owns it."},
}
local OPTION_DEFAULTS={
  freeLookEnabled=true,cameraEnabled=true,autoProgressEnabled=true,
  battleSoundsEnabled=true,bossIntroEnabled=false,
}
local function optionPrefs(game)
  if BattleSettings and type(BattleSettings.prefs)=="function" then
    local ok,p=pcall(BattleSettings.prefs,game)
    if ok and type(p)=="table" then
      return p
    end
  end
  if not (game and game.save) then
    local p={};for k,v in pairs(OPTION_DEFAULTS) do p[k]=v end;return p
  end
  local p=game.save.colosseumBattle
  if type(p)~="table" then p={};game.save.colosseumBattle=p end
  for k,v in pairs(OPTION_DEFAULTS) do if p[k]==nil then p[k]=v end end
  return p
end
local function optionEnabled(game,id)
  return optionPrefs(game)[id]==true
end
local function optionValue(game,row)
  local enabled=optionEnabled(game,row and row.id)
  if row and row.id=="battleSoundsEnabled" then return enabled and "COLOSSEUM" or "ORIGINAL" end
  return enabled and "ON" or "OFF"
end
local function toggleOption(game,row)
  if not row then return nil end
  local nextValue=not optionEnabled(game,row.id)
  optionPrefs(game)[row.id]=nextValue
  return nextValue
end
local function focusLayout(width,height,x,y)
  width=math.max(320,tonumber(width) or HUB_UI_WIDTH);height=math.max(240,tonumber(height) or HUB_UI_HEIGHT)
  x=tonumber(x) or 0;y=tonumber(y) or 0
  local s=MOBILE_RUNTIME and clamp(math.min(height/HUB_UI_HEIGHT,width/720),.72,1.20)
    or clamp(height/HUB_UI_HEIGHT,.72,1.35)
  -- Reserving the virtual-pad band can make a tall foldable's remaining content
  -- rectangle slightly landscape-shaped. Keep that device in the mobile stack;
  -- the physical interaction shape is still portrait and the controls still sit
  -- across the lower screen.
  local portrait=width/height<(MOBILE_RUNTIME and 1.30 or 1.08)
  local margin=clamp(math.min(width,height)*.035,10*s,24*s)
  local top=y+clamp(height*.105,34*s,62*s)
  local availableH=height-(top-y)-clamp(height*.055,18*s,34*s)
  local outerW=portrait and (width-margin*2) or clamp(width*.76,560*s,980*s)
  local outerH=portrait and clamp(availableH*.92,430*s,760*s) or clamp(availableH*.88,350*s,610*s)
  local ox=x+(width-outerW)*.5;local oy=top
  local gap=clamp(10*s,7,16)
  local list,detail
  if portrait then
    local lh=clamp(outerH*.50,210*s,370*s)
    list={x=ox,y=oy,w=outerW,h=lh}
    detail={x=ox,y=oy+lh+gap,w=outerW,h=outerH-lh-gap}
  else
    local lw=clamp(outerW*.36,235*s,355*s)
    list={x=ox,y=oy,w=lw,h=outerH}
    detail={x=ox+lw+gap,y=oy,w=outerW-lw-gap,h=outerH}
  end
  return {s=s,portrait=portrait,list=list,detail=detail,x=x,y=y,w=width,h=height,gap=gap,mobile=MOBILE_RUNTIME}
end
local function twoPaneLayout(width,height,x,y,bodyY,bodyH,margin,gap,leftFraction,leftWidthFraction,minLeft,maxLeft)
  width=math.max(320,tonumber(width) or HUB_UI_WIDTH);height=math.max(240,tonumber(height) or HUB_UI_HEIGHT)
  x=tonumber(x) or 0;y=tonumber(y) or 0;bodyY=tonumber(bodyY) or y;bodyH=math.max(1,tonumber(bodyH) or height)
  margin=math.max(0,tonumber(margin) or 0);gap=math.max(1,tonumber(gap) or 1)
  local mobilePortrait=MOBILE_RUNTIME and width/height<1.30
  if mobilePortrait then
    local usableW=math.max(1,width-margin*2)
    local leftH=math.max(1,math.floor((bodyH-gap)*clamp(tonumber(leftFraction) or .42,.28,.62)))
    local rightH=math.max(1,bodyH-gap-leftH)
    return {
      left={x=x+margin,y=bodyY,w=usableW,h=leftH},
      right={x=x+margin,y=bodyY+leftH+gap,w=usableW,h=rightH},
      portrait=true,mobile=true,stacked=true,
    }
  end
  local leftW=clamp(width*(tonumber(leftWidthFraction) or .35),tonumber(minLeft) or 210,tonumber(maxLeft) or 430)
  local left={x=x+margin,y=bodyY,w=leftW,h=bodyH}
  local right={x=left.x+left.w+gap,y=bodyY,w=width-margin-(left.x+left.w+gap-x),h=bodyH}
  return {left=left,right=right,portrait=false,mobile=MOBILE_RUNTIME,stacked=false}
end
HSc._test.CLIMB_ACTIONS=CLIMB_ACTIONS
HSc._test.RULESET_ROWS=RULESET_ROWS
HSc._test.OPTION_ROWS=OPTION_ROWS
HSc._test.optionValue=optionValue
HSc._test.toggleOption=toggleOption
HSc._test.focusLayout=focusLayout
HSc._test.twoPaneLayout=twoPaneLayout
HSc._test.GENERATION_PREFERENCES=GENERATION_PREFERENCES
HSc._test.normalizedClimbLength=normalizedClimbLength
HSc._test.climbDetailKind=climbDetailKind
HSc._test.ruleDescription=ruleDescription

local function drawClimbSetup(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local total=HSc.CLIMB_FORMATS[state.formatIndex or #HSc.CLIMB_FORMATS] or 100
    local format=climbDetailKind(state)=="format";local rows={}
    if format then
      for _,n in ipairs(HSc.CLIMB_FORMATS) do rows[#rows+1]={label=tostring(n).." BATTLES",detail="Confirm this length to return to setup. Your team is not locked yet."} end
    else
      local descriptions={"Choose 3, 5, 10, 25, 50 or 100 battles.","Camera, battle flow and audio preferences.",
        "Read the challenge rules and resource limits.","Completed runs, records and current-run statistics.","Choose your six, prepare moves, then start.","BP balance, reward rules, history and Challenge Bag exchange."}
      for i,label in ipairs(CLIMB_ACTIONS) do rows[i]={label=label,detail=descriptions[i],badge=i==1 and tostring(total) or nil} end
    end
    return Mobile.draw(state,viewport,{title=format and "CHOOSE A FORMAT" or "THE CLIMB",
      subtitle=tostring(total).." BATTLES / LV. 50 / DOUBLES",rows=rows,
      cursor=format and (state.formatDraftIndex or state.formatIndex) or state.cursor,detail=state.message,
      hints=format and {"UP/DOWN Choose   A Confirm","B Cancel - keep current format"}
        or {"UP/DOWN Browse   A Open   B Exit","START Save game   SELECT Hall of Fame"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=layoutFor(sw,sh,sx,sy);local s=L.s
  local total=HSc.CLIMB_FORMATS[state.formatIndex or #HSc.CLIMB_FORMATS] or 100
  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  set(g,{0,0,0,.08});g.rectangle("fill",sx,sy,sw,sh)
  titleHeader(g,L,"MT. BATTLE","THE CLIMB  //  CHALLENGE SETUP",tostring(total).." BATTLE FORMAT",
    tostring(total).." BATTLES  /  LV. 50  /  DOUBLES")

  local r=L.left;panel(g,r,true);local pad=clamp(16*s,12,22)
  text(g,"THE CLIMB",r.x+pad,r.y+14*s,clamp(18*s,14,24),C.ink)
  text(g,"CONFIGURE THE CLIMB, THEN PREPARE YOUR SIX.",r.x+pad,r.y+41*s,clamp(8.5*s,7,11),C.muted,"left",r.w-pad*2)
  sectionRule(g,r.x+pad,r.y+64*s,r.w-pad*2)
  local top=r.y+76*s;local gap=clamp(5*s,4,7)
  local available=r.h-(top-r.y)-pad
  local bh=clamp((available-gap*(#CLIMB_ACTIONS-1))/#CLIMB_ACTIONS,38*s,58*s)
  for i,label in ipairs(CLIMB_ACTIONS) do
    local sub
    if label=="FORMAT" then sub=tostring(total).." BATTLES  //  A OPEN"
    elseif label=="OPTIONS" then sub="Camera / flow / audio / scouting"
    elseif label=="RULESETS" then sub="Standard challenge contract"
    elseif label=="HALL OF FAME" then sub="Recorded runs + current run data"
    elseif label=="BP REWARDS" then sub="Wallet / challenge supplies / history"
    else sub="MOVE PREP / PC / RENTAL TEAM / START" end
    button(g,{x=r.x+pad,y=top+(i-1)*(bh+gap),w=r.w-pad*2,h=bh},(state.cursor or 1)==i,label,sub,
      label=="TEAM SETUP" and C.green or C.gold)
  end

  -- Keep the Summit/Wes composition open by default. The right rail is a
  -- contextual detail surface, not permanent chrome: it appears only after the
  -- player explicitly opens FORMAT from the left rail.
  if climbDetailKind(state)=="format" and L.right then
    local q=L.right;panel(g,q,true);local qp=clamp(14*s,10,18)
    text(g,"FORMAT",q.x+qp,q.y+16*s,clamp(15*s,12,19),C.ink)
    text(g,"AVAILABLE CLIMBS",q.x+qp,q.y+39*s,clamp(8.5*s,7,11),C.dim)
    sectionRule(g,q.x+qp,q.y+57*s,q.w-qp*2)
    local y=q.y+72*s;local rh=clamp(31*s,26,39)
    for i,n in ipairs(HSc.CLIMB_FORMATS) do
      local selected=i==(state.formatDraftIndex or state.formatIndex or #HSc.CLIMB_FORMATS)
      if selected then set(g,C.gold,.15);rr(g,"fill",q.x+qp,y,q.w-qp*2,rh-3*s,4*s) end
      text(g,string.format("%3d BATTLE",n),q.x+qp+8*s,y+7*s,clamp(9*s,8,11),selected and C.gold or C.muted)
      if selected then
        local tag="SELECTED";local fs=clamp(7*s,6,9)
        text(g,tag,q.x+q.w-qp-7*s-textWidth(tag,fs),y+9*s,fs,C.green)
      end
      y=y+rh
    end
  end
  drawTeamStrip(g,L,state.game)
  local prompt=climbDetailKind(state)=="format"
    and "↑↓ / ←→ FORMAT   A CONFIRM   B BACK   RMB DRAG FREE LOOK"
    or "↑↓ MENU   A OPEN   START SAVE   B EXIT   RMB DRAG FREE LOOK"
  text(g,prompt,L.footer.x+L.footer.w-14*s-textWidth(prompt,8.5*s),L.footer.y+L.footer.h-18*s,clamp(8.5*s,7,10.5),C.dim)
  if state.message then text(g,tostring(state.message),L.footer.x+14*s,L.footer.y+L.footer.h-18*s,clamp(8*s,7,10),C.green) end
  g.pop()
end

local function drawGenerationOptions(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local rows={};for i,row in ipairs(OPTION_ROWS) do
      rows[i]={label=row.label,badge=optionValue(state.game,row),selected=optionEnabled(state.game,row.id),detail=row.detail}
    end
    return Mobile.draw(state,viewport,{title="CHALLENGE OPTIONS",subtitle="CAMERA / FLOW / SOUND",rows=rows,cursor=state.cursor,team=false,
      hints={"UP/DOWN Browse   A Change","START Save game   B Back"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=focusLayout(sw,sh,sx,sy);local s=L.s
  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  set(g,{0,0,0,.13});g.rectangle("fill",sx,sy,sw,sh)

  local r=L.list;panel(g,r,true);challengeTab(g,r,"OPTIONS",s);local pad=clamp(13*s,10,19)
  text(g,"CHALLENGE OPTIONS",r.x+pad,r.y+13*s,clamp(15*s,12,20),C.ink)
  text(g,"PRESENTATION / FLOW",r.x+pad,r.y+35*s,clamp(7.5*s,6.5,9.5),C.dim)
  sectionRule(g,r.x+pad,r.y+51*s,r.w-pad*2)
  local top=r.y+62*s;local bottom=r.y+r.h-31*s
  local rh=clamp((bottom-top)/#OPTION_ROWS,35*s,49*s);local cursor=clamp(state.cursor or 1,1,#OPTION_ROWS)
  for i,row in ipairs(OPTION_ROWS) do
    local yy=top+(i-1)*rh;local focused=i==cursor
    if focused then
      set(g,C.gold,.14);rr(g,"fill",r.x+pad,yy,r.w-pad*2,rh-3*s,4*s)
      set(g,C.orange,.82);rr(g,"fill",r.x+pad,yy,3*s,rh-3*s,2*s)
    elseif i%2==0 then set(g,C.panelSoft,.20);rr(g,"fill",r.x+pad,yy,r.w-pad*2,rh-3*s,0) end
    text(g,row.label,r.x+pad+10*s,yy+8*s,clamp(8.5*s,7.2,11),focused and C.ink or C.muted,"left",r.w-pad*2-86*s)
    local value=optionValue(state.game,row);local fs=clamp(8*s,7,10.5)
    text(g,value,r.x+r.w-pad-8*s-textWidth(value,fs),yy+8*s,fs,optionEnabled(state.game,row.id) and C.green or C.dim)
  end
  text(g,"↑↓ SELECT   A / ←→ CHANGE   B RETURN",r.x+pad,r.y+r.h-21*s,clamp(7*s,6,9),C.dim,"left",r.w-pad*2)

  local q=L.detail;panel(g,q,true);local qp=clamp(16*s,12,23);local selected=OPTION_ROWS[cursor]
  text(g,"SELECTED OPTION",q.x+qp,q.y+14*s,clamp(8*s,7,10),C.dim)
  text(g,selected.label,q.x+qp,q.y+32*s,clamp(17*s,13,23),C.gold,"left",q.w-qp*2)
  local current=optionValue(state.game,selected);local vfs=clamp(11*s,9,14)
  set(g,optionEnabled(state.game,selected.id) and C.green or C.panelSoft,.16);rr(g,"fill",q.x+qp,q.y+62*s,q.w-qp*2,clamp(32*s,26,42),5*s)
  text(g,current,q.x+qp+10*s,q.y+70*s,vfs,optionEnabled(state.game,selected.id) and C.green or C.muted)
  text(g,selected.detail,q.x+qp,q.y+109*s,clamp(9*s,7.5,11.5),C.muted,"left",q.w-qp*2)

  local rulesY=q.y+clamp(q.h*.52,150*s,230*s)
  text(g,"LOCKED CHALLENGE CORE",q.x+qp,rulesY,clamp(8*s,7,10),C.gold)
  sectionRule(g,q.x+qp,rulesY+17*s,q.w-qp*2)
  local facts={{"POOL","GEN 1 + 2 + 3 / 001-386"},{"TEAM","EXACTLY 6"},{"BATTLE","DOUBLES"},{"LEVEL","LV. 50"}}
  local fy=rulesY+28*s;local fh=clamp(23*s,19,29)
  for i,row in ipairs(facts) do
    if i%2==0 then set(g,C.panelSoft,.20);rr(g,"fill",q.x+qp,fy,q.w-qp*2,fh,0) end
    text(g,row[1],q.x+qp+4*s,fy+5*s,clamp(7.5*s,6.5,9.5),C.dim)
    local fs=clamp(7.5*s,6.5,9.5);text(g,row[2],q.x+q.w-qp-4*s-textWidth(row[2],fs),fy+5*s,fs,C.muted)
    fy=fy+fh
  end
  text(g,"OPTIONS CHANGE PRESENTATION ONLY; THEY NEVER FILTER THE NATIONAL DEX POOL.",q.x+qp,q.y+q.h-25*s,
    clamp(6.8*s,6,8.5),C.dim,"left",q.w-qp*2)
  g.pop()
end

local function rulesetDetail(row,total)
  if row and row[1]=="BATTLE FORMAT" then
    return ("This run is set to %d consecutive trainer battles. Available formats are 3, 5, 10, 25, 50, and 100."):format(total)
  end
  return row and row[2] or ""
end
local function drawRulesets(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local rows={};for i,row in ipairs(RULESET_ROWS) do rows[i]={label=row[1],detail=rulesetDetail(row,normalizedClimbLength(state.totalFights))} end
    return Mobile.draw(state,viewport,{title="CHALLENGE RULES",subtitle="STANDARD RULESET / READ ONLY",rows=rows,cursor=state.cursor,team=false,
      hints={"UP/DOWN Browse   LEFT/RIGHT Page","B Back"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=focusLayout(sw,sh,sx,sy);local s=L.s
  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  set(g,{0,0,0,.14});g.rectangle("fill",sx,sy,sw,sh)
  local total=normalizedClimbLength(state.totalFights);local cursor=clamp(state.cursor or 1,1,#RULESET_ROWS)
  local selected=RULESET_ROWS[cursor]

  local r=L.list;panel(g,r,true);challengeTab(g,r,"RULESETS",s);local pad=clamp(13*s,10,19)
  text(g,"STANDARD RULESET",r.x+pad,r.y+13*s,clamp(15*s,12,20),C.ink)
  local counter=string.format("%02d / %02d",cursor,#RULESET_ROWS);local cfs=clamp(8*s,7,10)
  text(g,counter,r.x+r.w-pad-textWidth(counter,cfs),r.y+17*s,cfs,C.gold)
  text(g,"LOCKED CHALLENGE CONTRACT",r.x+pad,r.y+35*s,clamp(7*s,6,9),C.dim)
  sectionRule(g,r.x+pad,r.y+51*s,r.w-pad*2)
  local rowH=clamp(31*s,27,40);local y0=r.y+63*s
  local visible=math.max(4,math.floor((r.h-(y0-r.y)-30*s)/rowH))
  local first=math.max(1,math.min(math.max(1,#RULESET_ROWS-visible+1),cursor-math.floor(visible/2)))
  local lastGroup=nil
  for n=0,visible-1 do
    local i=first+n;local row=RULESET_ROWS[i];if not row then break end
    local yy=y0+n*rowH;local focused=i==cursor
    if focused then
      set(g,C.gold,.14);rr(g,"fill",r.x+pad,yy,r.w-pad*2,rowH-3*s,4*s)
      set(g,C.orange,.85);rr(g,"fill",r.x+pad,yy,3*s,rowH-3*s,2*s)
    elseif row[3]~=lastGroup then set(g,C.panelSoft,.17);rr(g,"fill",r.x+pad,yy,r.w-pad*2,rowH-3*s,0) end
    text(g,string.format("%02d",i),r.x+pad+9*s,yy+7*s,clamp(7*s,6,9),focused and C.gold or C.dim)
    text(g,row[1],r.x+pad+35*s,yy+6*s,clamp(8.5*s,7.2,11),focused and C.ink or C.muted,"left",r.w-pad*2-82*s)
    local tag=tostring(row[3] or "CORE");local tfs=clamp(6.5*s,5.8,8)
    text(g,tag,r.x+r.w-pad-7*s-textWidth(tag,tfs),yy+8*s,tfs,focused and C.gold or C.dim)
    lastGroup=row[3]
  end
  if first>1 then text(g,"▲ MORE",r.x+pad,r.y+54*s,clamp(6*s,5.5,7.5),C.dim) end
  if first+visible-1<#RULESET_ROWS then text(g,"▼ MORE",r.x+r.w-pad-textWidth("▼ MORE",6*s),r.y+r.h-23*s,clamp(6*s,5.5,7.5),C.dim) end
  text(g,"↑↓ REVIEW   ←→ PAGE   B RETURN",r.x+pad,r.y+r.h-21*s,clamp(7*s,6,9),C.dim)

  local q=L.detail;panel(g,q,true);local qp=clamp(17*s,13,24)
  text(g,tostring(selected[3] or "CORE").." RULE",q.x+qp,q.y+15*s,clamp(8*s,7,10),C.gold)
  text(g,selected[1],q.x+qp,q.y+34*s,clamp(20*s,15,27),C.ink,"left",q.w-qp*2)
  sectionRule(g,q.x+qp,q.y+67*s,q.w-qp*2)
  text(g,rulesetDetail(selected,total),q.x+qp,q.y+82*s,clamp(10*s,8.5,13),C.muted,"left",q.w-qp*2)

  local activeY=q.y+clamp(q.h*.48,145*s,225*s)
  text(g,"ACTIVE RUN CONTRACT",q.x+qp,activeY,clamp(8*s,7,10),C.dim)
  sectionRule(g,q.x+qp,activeY+17*s,q.w-qp*2)
  local facts={{"FORMAT",tostring(total).." BATTLES"},{"POOL","GEN 1 + 2 + 3"},{"TEAM","6 LOCKED"},{"LEVEL","LV. 50"},{"BATTLE","DOUBLES"},{"CONTINUE","1 PER RUN"}}
  local fy=activeY+29*s;local fh=clamp(22*s,18,28)
  for i,row in ipairs(facts) do
    if i%2==0 then set(g,C.panelSoft,.20);rr(g,"fill",q.x+qp,fy,q.w-qp*2,fh,0) end
    text(g,row[1],q.x+qp+4*s,fy+4*s,clamp(7.5*s,6.5,9.5),C.dim)
    local fs=clamp(7.5*s,6.5,9.5);text(g,row[2],q.x+q.w-qp-4*s-textWidth(row[2],fs),fy+4*s,fs,C.muted)
    fy=fy+fh
  end
  text(g,"RULESET IS READ-ONLY. FORMAT IS CHOSEN FROM THE CLIMB; CORE RULES DO NOT DRIFT MID-RUN.",q.x+qp,q.y+q.h-25*s,
    clamp(6.8*s,6,8.5),C.dim,"left",q.w-qp*2)
  g.pop()
end

local function drawTeamSelect(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local model=state.model;local rental=model:isRentalCatalog()
    local indices=rental and (model:categoryCandidateIndices() or {}) or nil
    local category=rental and model:currentCategory() or nil
    local rows={};local cursor=rental and model:categoryCursorPosition() or model.cursor
    local count=rental and #indices or #model.candidates
    state.__cbeTeamRowText=state.__cbeTeamRowText or {}
    for pos=1,count do
      local i=indices and indices[pos] or pos;local c=model.candidates[i]
      local picked=model:isSelected(i);local unavailable=c.selectable==false
      -- Candidate identity is fixed for this screen's lifetime. Cache the static
      -- text once; selection badges and cursor remain live and save-independent.
      local row=state.__cbeTeamRowText[c]
      if not row then
        local source=c.source=="pc" and ("BOX "..tostring(c.box).." / SLOT "..tostring(c.slot))
          or (c.source=="party" and ("PARTY "..tostring(c.index or i)) or "RENTAL")
        row={label=speciesName(state.game,c),meta="LV."..tostring(c.level or "--").."  /  "..source,
          detail=unavailable and (c.disabledReason or "Required host mechanics are unavailable.")
            or (source..". A adds or removes this individual. Choose exactly six.")}
        state.__cbeTeamRowText[c]=row
      end
      row.disabled=unavailable;row.selected=picked
      row.badge=unavailable and "BLOCKED" or (picked and ("PICK "..tostring(model.pickOrder and model.pickOrder[i] or ">")) or nil)
      rows[pos]=row
    end
    local tabs={}
    for _,cat in ipairs(model.rentalCategories or {}) do
      tabs[#tabs+1]={label=cat=="owned" and "OWNED" or ("GEN "..tostring(cat)),active=cat==category}
    end
    return Mobile.draw(state,viewport,{title="BUILD CHALLENGE TEAM",subtitle=tostring(model:selectedCount()).." OF 6 SELECTED / LEVEL 50 CHALLENGE",
      section="POKEMON",tabs=tabs,teamCatalog=true,twoLineRows=true,
      rows=rows,cursor=cursor,team=selectedTeam(model) or {},
      hints=rental and {"A Toggle   START Lock six   B Back","SELECT Tab   LEFT/RIGHT Page"}
        or {"UP/DOWN Browse   A Toggle","START Lock six   B Back"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=layoutFor(sw,sh,sx,sy);local s=L.s
  g.push("all");g.origin();g.setShader();set(g,{0,0,0,.08});g.rectangle("fill",sx,sy,sw,sh)
  local total=climbLengthFor(state.game,state.totalFights)
  local rentalMode=state.model:isRentalCatalog()
  local mixedMode=state.model:isMixedCatalog()
  local generation=state.model:currentGeneration()
  titleHeader(g,L,"MT. BATTLE","BATTLE "..tostring(total).."  //  "..(mixedMode and "TEAM BUILDER" or (rentalMode and "RENTAL TEAM" or "TEAM SELECT")),"SELECT EXACTLY SIX",
    tostring(total).." BATTLES  /  LV. 50  /  DOUBLES")
  local r=L.left;panel(g,r,true);local pad=clamp(16*s,12,22)
  local count=state.model:selectedCount();text(g,mixedMode and "OWNED + RENTALS" or (rentalMode and "RENTALS" or "ROSTER"),r.x+pad,r.y+14*s,clamp(15*s,12,20),C.ink)
  text(g,tostring(count).." / 6 SELECTED",r.x+r.w-pad-textWidth(tostring(count).." / 6 SELECTED",11*s),r.y+17*s,clamp(11*s,9,14),count==6 and C.green or C.gold)
  sectionRule(g,r.x+pad,r.y+44*s,r.w-pad*2)
  local listY=r.y+60*s
  if rentalMode then
    local categories=state.model.rentalCategories or {}
    local gap=4*s;local tabW=(r.w-pad*2-gap*math.max(0,#categories-1))/math.max(1,#categories)
    local tabY=r.y+48*s;local tabH=clamp(16*s,14,19)
    local activeCategory=state.model:currentCategory()
    for n,category in ipairs(categories) do
      local active=category==activeCategory;local x=r.x+pad+(n-1)*(tabW+gap)
      set(g,active and C.goldSoft or C.panelSoft,active and .82 or .36);rr(g,"fill",x,tabY,tabW,tabH,3*s)
      local tabLabel=category=="owned" and "OWNED" or ("GEN "..tostring(category))
      text(g,tabLabel,x,tabY+2*s,clamp(7*s,6,9),active and C.gold or C.dim,"center",tabW)
    end
    listY=r.y+70*s
  end
  local rows=math.max(4,math.floor((r.h-(listY-r.y)-12*s)/(54*s)));local cursor=state.model.cursor
  local indices=rentalMode and (state.model:categoryCandidateIndices() or {}) or nil
  local listCount=rentalMode and #indices or #state.model.candidates
  local cursorPosition=rentalMode and state.model:categoryCursorPosition() or cursor
  local first=math.max(1,math.min(math.max(1,listCount-rows+1),cursorPosition-math.floor(rows/2)))
  for n=0,rows-1 do
    local position=first+n;local i=rentalMode and indices[position] or position;local c=i and state.model.candidates[i];if not c then break end
    local y=listY+n*54*s;local selected=state.model:isSelected(i);local focused=i==cursor;local unavailable=c.selectable==false
    set(g,focused and C.goldSoft or C.panelSoft);rr(g,"fill",r.x+pad,y,r.w-pad*2,46*s,6*s)
    if focused then set(g,C.gold);rr(g,"line",r.x+pad+.5,y+.5,r.w-pad*2-1,46*s-1,6*s) end
    local order=state.model.pickOrder and state.model.pickOrder[i]
    text(g,unavailable and "×" or (selected and tostring(order or ">") or tostring(position)),r.x+pad+10*s,y+11*s,clamp(11*s,9,14),selected and C.green or C.dim)
    local def=state.game.data and state.game.data.pokemon and state.game.data.pokemon[c.species]
    text(g,tostring(c.name or (def and def.name) or c.species or "POKéMON"):upper(),r.x+pad+42*s,y+7*s,clamp(12*s,10,16),unavailable and C.dim or C.ink)
    local sub=unavailable and (c.disabledReason or "SOURCE DATA  /  HOST MECHANICS BLOCKED") or ("Lv. "..tostring(c.level or "--").."  /  "..(c.source=="pc" and ("BOX "..tostring(c.box).." / SLOT "..tostring(c.slot)) or tostring(c.source or "party"):upper()))
    text(g,sub,r.x+pad+42*s,y+25*s,clamp(9.5*s,8,12),unavailable and C.dim or C.muted)
  end
  drawRulesRail(g,L,state.game,state.model,state.totalFights);drawTeamStrip(g,L,state.game,state.model)
  local prompt
  if rentalMode then
    prompt=(count==6 and "START LOCK   " or "").."A TOGGLE   ←→ PAGE   SELECT NEXT TAB   B BACK   RMB LOOK"
  else
    prompt=count==6 and "START LOCK TEAM   A TOGGLE   B BACK   RMB DRAG FREE LOOK" or "A TOGGLE   B BACK   RMB DRAG FREE LOOK"
  end
  text(g,prompt,L.footer.x+L.footer.w-18*s-textWidth(prompt,10*s),L.footer.y+L.footer.h-23*s,clamp(10*s,8,13),count==6 and C.green or C.dim)
  g.pop()
end

local function moveLabel(game,id)
  local m=game and game.data and game.data.moves and game.data.moves[id]
  return tostring((m and m.name) or id or "MOVE"):upper()
end
local function moveSourceLabel(row)
  if not row then return "" end
  if row.source=="LEVEL" then return row.level and ("LV."..tostring(row.level)) or "LEVEL" end
  if row.source=="KNOWN" then return "KNOWN" end
  if row.source=="HM" then return "HM" end
  if row.source=="TM" then return "TM" end
  return tostring(row.source or "")
end
local function selectedMoveSet(rows)
  local out={};for _,mv in ipairs(rows or {}) do out[type(mv)=="table" and mv.id or mv]=true end;return out
end
local function drawMovePrep(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local party=(MovePrep and type(MovePrep.team)=="function" and MovePrep.team(state.game,state.prepared))
      or (state.game and state.game.save and state.game.save.party) or {}
    local rows={};local cursor=state.teamCursor or 1;local editing=state.phase=="moves"
    if editing then
      cursor=state.moveCursor or 1;local selected=selectedMoveSet(state.workingMoves)
      for i,row in ipairs(state.pool or {}) do
        local def=state.game and state.game.data and state.game.data.moves and state.game.data.moves[row.id] or {}
        local typeName=tostring(row.displayType or def.type or row.type or "--"):upper():gsub("_TYPE$",""):gsub("_"," ")
        local pp=row.basePP or def.pp or row.pp
        rows[i]={label=tostring(row.name or moveLabel(state.game,row.id)):upper(),selected=selected[row.id],
          meta=typeName.." / BASE PP "..tostring(pp or "--"),
          badge=(selected[row.id] and "> " or "")..moveSourceLabel(row),
          detail=state.message or state.poolDiagnosticMessage or (tostring(row.name or moveLabel(state.game,row.id)):upper().." / "..moveSourceLabel(row)..". A toggles; START saves this loadout.")}
      end
    else
      for i=1,6 do
        local mon=party[i];local names={}
        local moves=(MovePrep and MovePrep.currentSelection and mon) and MovePrep.currentSelection(state.game,mon,state.prepared and state.prepared[i]) or (mon and mon.moves) or {}
        for _,mv in ipairs(moves) do names[#names+1]=moveLabel(state.game,type(mv)=="table" and mv.id or mv) end
        rows[i]={label=speciesName(state.game,mon),badge=state.prepared and state.prepared[i] and "PREPPED" or nil,
          detail=#names>0 and table.concat(names," / ") or "No Pokemon in this team slot."}
      end
    end
    return Mobile.draw(state,viewport,{title="MOVE PREP",rows=rows,cursor=cursor,team=false,focusedList=true,twoLineRows=editing,section=editing and "LEGAL MOVE POOL" or "CHALLENGE TEAM",
      subtitle=editing and (speciesName(state.game,party[state.teamCursor or 1]).." / "..tostring(#(state.workingMoves or {})).." OF 4 MOVES") or "CHOOSE A POKEMON / FULL LV. 1-100 MOVE ACCESS",
      warning=editing and (state.message~=nil or state.poolDiagnosticMessage~=nil),
      hints=editing and {"UP/DOWN Browse   LEFT/RIGHT Page","A Toggle   START Save   B Cancel edit"} or {"UP/DOWN Team   A Edit moves","B Return to setup"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=challengeLayout(sw,sh,sx,sy);local s=L.s
  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  set(g,{0,0,0,.09});g.rectangle("fill",sx,sy,sw,sh)

  local r=L.left;panel(g,r,true);challengeTab(g,r,"MOVE PREP",s)
  local pad=clamp(12*s,9,16)
  text(g,"CHALLENGE SIX",r.x+pad,r.y+11*s,clamp(12*s,9,15),C.ink)
  text(g,"LV.50 DOES NOT LIMIT MOVE ACCESS",r.x+pad,r.y+29*s,clamp(7.2*s,6.2,9),C.gold)
  sectionRule(g,r.x+pad,r.y+43*s,r.w-pad*2)
  local party=(MovePrep and type(MovePrep.team)=="function" and MovePrep.team(state.game,state.prepared))
    or (state.game and state.game.save and state.game.save.party) or {}
  local rowH=clamp(34*s,27,43);local y0=r.y+52*s
  for i=1,6 do
    local mon=party[i];local yy=y0+(i-1)*(rowH+3*s);local focused=i==(state.teamCursor or 1)
    set(g,focused and C.goldSoft or C.panelSoft,focused and .80 or .34);rr(g,"fill",r.x+pad,yy,r.w-pad*2,rowH,4*s)
    if focused then set(g,C.gold,.82);rr(g,"line",r.x+pad+.5,yy+.5,r.w-pad*2-1,rowH-1,4*s) end
    text(g,tostring(i),r.x+pad+7*s,yy+5*s,clamp(8*s,7,10),focused and C.gold or C.dim)
    text(g,speciesName(state.game,mon),r.x+pad+23*s,yy+4*s,clamp(9*s,7.5,11),mon and C.ink or C.dim,"left",r.w-pad*2-29*s)
    local prepared=state.prepared and state.prepared[i]
    local status=prepared and prepared.species==(mon and mon.species) and "PREPPED" or "CURRENT"
    text(g,status,r.x+pad+23*s,yy+18*s,clamp(6.8*s,6,8.2),prepared and C.cyan or C.dim)
  end

  local q=L.right;panel(g,q,true);local qp=clamp(10*s,8,13)
  local slot=state.teamCursor or 1;local mon=party[slot]
  text(g,state.phase=="moves" and "MOVE POOL" or "SELECTED LOADOUT",q.x+qp,q.y+10*s,clamp(10.5*s,8.5,13),C.ink)
  sectionRule(g,q.x+qp,q.y+28*s,q.w-qp*2)
  if mon then text(g,speciesName(state.game,mon),q.x+qp,q.y+38*s,clamp(9*s,7.5,11),C.gold,"left",q.w-qp*2) end
  if state.phase=="moves" then
    local pool=state.pool or {};local selected=selectedMoveSet(state.workingMoves)
    local y=q.y+56*s;local bottom=q.y+q.h-44*s;local rh=clamp(21*s,18,25)
    local visible=math.max(1,math.floor((bottom-y)/rh));local cursor=clamp(state.moveCursor or 1,1,math.max(1,#pool))
    local first=math.max(1,math.min(math.max(1,#pool-visible+1),cursor-math.floor(visible/2)))
    for n=0,visible-1 do
      local i=first+n;local row=pool[i];if not row then break end
      local yy=y+n*rh;local focused=i==cursor
      if focused then set(g,C.gold,.14);rr(g,"fill",q.x+qp,yy,q.w-qp*2,rh-1*s,2*s) end
      text(g,selected[row.id] and ">" or "-",q.x+qp+2*s,yy+3*s,clamp(7.5*s,6.5,9),selected[row.id] and C.green or C.dim)
      text(g,row.name:upper(),q.x+qp+14*s,yy+2*s,clamp(7.5*s,6.3,9),focused and C.ink or C.muted,"left",math.max(1,q.w-qp*2-47*s))
      local src=moveSourceLabel(row);local fs=clamp(6.5*s,5.8,8)
      text(g,src,q.x+q.w-qp-textWidth(src,fs),yy+3*s,fs,row.source=="HM" and C.cyan or C.dim)
    end
    local count=#(state.workingMoves or {})
    local footerMessage=state.message or state.poolDiagnosticMessage
    if footerMessage then
      text(g,footerMessage,q.x+qp,q.y+q.h-50*s,clamp(6.5*s,5.6,8),C.red,"left",q.w-qp*2)
    end
    text(g,tostring(count).." / 4",q.x+qp,q.y+q.h-35*s,clamp(8*s,7,10),count==4 and C.green or C.gold)
    text(g,"A TOGGLE   START SAVE   B CANCEL",q.x+qp,q.y+q.h-20*s,clamp(6.5*s,5.6,8),C.dim,"left",q.w-qp*2)
  else
    local moves=(MovePrep and MovePrep.currentSelection and mon) and MovePrep.currentSelection(state.game,mon,state.prepared and state.prepared[slot]) or (mon and mon.moves or {})
    local y=q.y+58*s
    for i,mv in ipairs(moves or {}) do
      local id=type(mv)=="table" and mv.id or mv
      text(g,tostring(i).."  "..moveLabel(state.game,id),q.x+qp,y+(i-1)*clamp(21*s,18,25),clamp(8*s,7,10),C.muted,"left",q.w-qp*2)
    end
    text(g,"A EDIT MOVES",q.x+qp,q.y+q.h-35*s,clamp(8*s,7,10),C.green)
    text(g,"B BACK   RMB DRAG FREE LOOK",q.x+qp,q.y+q.h-20*s,clamp(6.5*s,5.6,8),C.dim,"left",q.w-qp*2)
  end
  g.pop()
end
HSc._test.drawMovePrep=drawMovePrep

local function drawBeginConfirm(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local team=(MovePrep and type(MovePrep.team)=="function" and MovePrep.team(state.game,state.prepared)) or nil
    return Mobile.draw(state,viewport,{title="READY TO CLIMB?",subtitle=tostring(climbLengthFor(state.game,state.totalFights)).." BATTLES / LV. 50 / DOUBLES",
      rows={{label="BEGIN CHALLENGE",badge="A",detail="Starting locks your six and prepared moves into a separate Level 50 challenge team. Your normal party and bag stay separate."}},
      cursor=1,team=team,hints={"A Begin challenge","B Return to setup"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=layoutFor(sw,sh,sx,sy);local s=L.s
  g.push("all");g.origin();g.setShader();set(g,{0,0,0,.11});g.rectangle("fill",sx,sy,sw,sh)
  local total=climbLengthFor(state.game,state.totalFights)
  titleHeader(g,L,"MT. BATTLE","BATTLE "..tostring(total).."  //  FINAL CHECK","READY TO CLIMB",
    tostring(total).." BATTLES  /  LV. 50  /  DOUBLES")
  local w=clamp(sw*.42,420*s,680*s);local h=clamp(230*s,190,300);local r={x=sx+(sw-w)*.5,y=sy+(sh-h)*.48,w=w,h=h}
  panel(g,r,true);text(g,"LOCK THIS TEAM?",r.x+28*s,r.y+28*s,clamp(25*s,18,33),C.ink)
  text(g,"Your Level 50 challenge snapshot is created when you continue.",r.x+28*s,r.y+70*s,clamp(12*s,10,16),C.muted,"left",r.w-56*s)
  set(g,C.green,.16);rr(g,"fill",r.x+28*s,r.y+r.h-82*s,r.w-56*s,50*s,7*s)
  set(g,C.green,.9);rr(g,"line",r.x+28*s+.5,r.y+r.h-82*s+.5,r.w-57*s,49*s,7*s)
  text(g,"A  BEGIN "..tostring(total).." BATTLE RUN",r.x+45*s,r.y+r.h-68*s,clamp(12*s,10,16),C.green)
  text(g,"B  RETURN TO SETUP",r.x+45*s,r.y+r.h-35*s,clamp(10*s,9,13),C.dim)
  drawTeamStrip(g,L,state.game)
  text(g,"RMB DRAG FREE LOOK",L.footer.x+16*s,L.footer.y+L.footer.h-18*s,clamp(8*s,7,10),C.dim)
  g.pop()
end

-- Battle 1 has no preceding result screen, so it owns a dedicated Summit
-- briefing. Later fights enter directly from the post-battle intermission,
-- which already introduces the next opponent. Do not reveal the opponent's
-- six here; Battle Records expose teams only after an attempt is actually
-- played.
local function fightBriefingMeta(encounter)
  encounter=encounter or {}
  local fight=math.max(1,math.floor(tonumber(encounter.fightIndex) or 1))
  local identity=type(encounter.identity)=="table" and encounter.identity or {}
  return {
    fight=fight,area=math.floor((fight-1)/10)+1,
    name=tostring(identity.displayName or identity.name or "MT. BATTLE TRAINER"),
    title=identity.title and tostring(identity.title) or nil,
    archetype=tostring(encounter.archetype or "balanced"):gsub("_"," "):upper(),
    personality=tostring(encounter.personality or "standard"):gsub("_"," "):upper(),
    isAreaLeader=encounter.isAreaLeader==true,
    isFinale=fight==100,
  }
end

local function drawFightBriefing(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local m=fightBriefingMeta(state.encounter)
    local total=climbLengthFor(state.game,state.totalFights)
    local run=state.game and state.game.save and state.game.save.mtBattleChallenge or {}
    local remaining=math.max(0,(run.continuesTotal or 1)-(run.continuesUsed or 0))
    local rows={{label=m.name,meta=(m.fight==total and "FINAL BATTLE" or (m.isAreaLeader and "AREA LEADER" or "NEXT OPPONENT")),detail=((m.title and m.title.." " or "")..m.name)},
      {label="OPPONENT STYLE",meta=m.personality,detail=m.personality.." / "..m.archetype},
      {label="AREA",meta=tostring(m.area).." / "..tostring(math.ceil(total/10)),detail="Battle "..m.fight.." of "..total},
      {label="CONTINUES",meta=tostring(remaining).." LEFT",detail="Technical launch failure does not consume a Continue."},
      {label="XP BANK",meta=tostring(run.xpBank or 0),detail="XP is distributed after clearing the challenge."}}
    return Mobile.draw(state,viewport,{title="BATTLE "..m.fight.." / "..total,subtitle="NEXT OPPONENT / LEVEL 50 DOUBLES",
      section="BRIEFING",rows=rows,cursor=state.mobileInfoCursor or 1,team=run.rosterSnapshot or {},twoLineRows=true,focusedList=true,
      hints={"A / START Enter battle","B Suspend   SELECT Records","UP/DOWN Briefing"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=challengeLayout(sw,sh,sx,sy);local s=L.s
  local m=fightBriefingMeta(state.encounter)
  local total=climbLengthFor(state.game,state.totalFights)
  m.totalFights=total
  m.isFinale=(m.fight==total)
  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  set(g,{0,0,0,.10});g.rectangle("fill",sx,sy,sw,sh)

  local r=L.left;panel(g,r,true);challengeTab(g,r,"MT. BATTLE "..tostring(total),s)
  local pad=clamp(14*s,11,18)
  local kicker=m.isFinale and ((m.isAreaLeader and "FINAL AREA LEADER") or "FINAL BATTLE") or (m.isAreaLeader and "AREA LEADER" or "NEXT OPPONENT")
  text(g,kicker,r.x+pad,r.y+13*s,clamp(9*s,8,11),(m.isAreaLeader or m.isFinale) and C.gold or C.dim)
  text(g,"BATTLE "..string.format("%03d",m.fight),r.x+pad,r.y+31*s,clamp(17*s,13,22),C.ink)
  sectionRule(g,r.x+pad,r.y+55*s,r.w-pad*2)

  local y=r.y+69*s
  text(g,((m.title and (m.title.." ")) or "")..m.name,r.x+pad,y,clamp(12*s,10,15),C.gold,"left",r.w-pad*2)
  y=y+24*s
  local rows={{"AREA",tostring(m.area).." / "..tostring(math.ceil(total/10))},{"STYLE",m.personality},{"TEAM",m.archetype},{"FORMAT","DOUBLE / LV. 50"}}
  local rh=clamp(21*s,18,26)
  for i,row in ipairs(rows) do
    if i%2==0 then set(g,C.panelSoft,.24);rr(g,"fill",r.x+pad,y,r.w-pad*2,rh,0) end
    text(g,row[1],r.x+pad+4*s,y+4*s,clamp(8*s,7,10),C.dim)
    local fs=clamp(8*s,7,10);text(g,row[2],r.x+r.w-pad-4*s-textWidth(row[2],fs),y+4*s,fs,C.muted)
    y=y+rh
  end

  y=y+7*s;text(g,"CLIMB PROGRESS",r.x+pad,y,clamp(8*s,7,10),C.dim);y=y+14*s
  local bw=r.w-pad*2;set(g,C.panelSoft);rr(g,"fill",r.x+pad,y,bw,6*s,3*s)
  set(g,(m.isAreaLeader or m.isFinale) and C.gold or C.green)
  rr(g,"fill",r.x+pad,y,bw*clamp((m.fight-1)/math.max(1,total),0,1),6*s,3*s)

  local actionH=clamp(47*s,40,58);local ay=r.y+r.h-pad-actionH
  set(g,C.green,.15);rr(g,"fill",r.x+pad,ay,r.w-pad*2,actionH,6*s)
  set(g,C.green,.85);rr(g,"line",r.x+pad+.5,ay+.5,r.w-pad*2-1,actionH-1,6*s)
  text(g,"A  ENTER BATTLE",r.x+pad+12*s,ay+8*s,clamp(11*s,9,14),C.green)
  text(g,"B  SUSPEND & QUIT",r.x+pad+12*s,ay+25*s,clamp(8*s,7,10),C.gold)
  text(g,"SELECT  BATTLE RECORDS",r.x+pad+12*s,ay+39*s,clamp(7*s,6,9),C.dim)

  local q=L.right;panel(g,q,true);local qp=clamp(12*s,9,15)
  text(g,"RUN CONDITIONS",q.x+qp,q.y+11*s,clamp(12*s,10,15),C.ink)
  sectionRule(g,q.x+qp,q.y+31*s,q.w-qp*2)
  local run=state.game and state.game.save and state.game.save.mtBattleChallenge or {}
  local conditions={
    {"TARGET",tostring(total).." WINS"},{"LEVEL","LOCKED 50"},
    {"CONTINUE",tostring(math.max(0,(run.continuesTotal or 1)-(run.continuesUsed or 0))).." LEFT"},
    {"XP BANK",tostring(math.floor(tonumber(run.xpBank) or 0))},
  }
  local cy=q.y+43*s;local ch=clamp(20*s,17,24)
  for i,row in ipairs(conditions) do
    if i%2==0 then set(g,C.panelSoft,.24);rr(g,"fill",q.x+qp,cy,q.w-qp*2,ch,0) end
    text(g,row[1],q.x+qp+3*s,cy+4*s,clamp(8*s,7,10),C.dim)
    local fs=clamp(8*s,7,10);text(g,row[2],q.x+q.w-qp-3*s-textWidth(row[2],fs),cy+4*s,fs,i==3 and C.gold or C.muted)
    cy=cy+ch
  end
  cy=cy+7*s;text(g,"LOCKED CHALLENGE TEAM",q.x+qp,cy,clamp(8*s,7,10),C.gold);cy=cy+14*s
  local roster=run.rosterSnapshot or {}
  for i=1,math.min(6,#roster) do
    local row=roster[i] or {};local label=speciesName(state.game,row)
    text(g,string.format("%d  %s",i,label),q.x+qp+3*s,cy,clamp(7.5*s,6.5,9),C.muted,"left",q.w-qp*2-4*s)
    cy=cy+clamp(15*s,13,18)
  end
  g.pop()
end
HSc._test.fightBriefingMeta=fightBriefingMeta

local INTERMISSION_BAG={
  {"FULL_RESTORE","FULL REST."},{"HYPER_POTION","HYPER"},
  {"REVIVE","REVIVE"},{"FULL_HEAL","FULL HEAL"},
  {"ETHER","ETHER"},{"ELIXER","ELIXER"},
}
local function bpAwardDescription(award)
  if (tonumber(award.policy) or 1)<2 then
    return "Previously recorded under the old BP rule. Current rewards require a no-faint victory with all six alive."
  end
  if award.clean==true then
    return "No player Pokemon fainted; all six finished alive. "..
      ((tonumber(award.amount) or 0)>0 and "1 BP earned." or "BP wallet is at its limit.")
  end
  return "0 BP. Winning alone does not earn BP. "..tostring(award.reason or "No-faint victory could not be verified").."."
end
local function intermissionHeadline(m)
  if m.bpAward and m.kind~="complete" and m.kind~="areaBreak" then
    local a=m.bpAward
    local label=(tonumber(a.policy) or 1)<2 and "PREVIOUS BP RULE" or (a.clean and "NO-FAINT VICTORY" or "NO BP EARNED")
    return "BATTLE "..tostring(m.completedFight or "").." CLEAR",
      ((tonumber(a.amount) or 0)>0 and "+" or "")..tostring(a.amount or 0).." BP  /  "..label
  end
  if m.kind=="complete" then
    local total=normalizedClimbLength(m.totalFights or 100)
    return "BATTLE "..tostring(total).." CLEAR","MT. BATTLE CHALLENGE COMPLETE"
  end
  if m.kind=="failed" then return "CHALLENGE ENDED","NO CONTINUES REMAIN" end
  if m.kind=="continue" then return "CHALLENGE PAUSED","RETRY THE SAME BATTLE" end
  if m.kind=="areaBreak" then return "AREA "..tostring(m.area or 1).." CLEAR","10-BATTLE AREA COMPLETE" end
  return "BATTLE "..string.format("%03d",tonumber(m.completedFight) or 0).." CLEAR","CLIMB STATUS"
end
local function intermissionTeamLabel(mon)
  if not mon then return "--" end
  if mon.fainted then return "FNT" end
  if mon.status and mon.status~="" then return tostring(mon.status):upper():sub(1,4) end
  return tostring(math.max(0,math.min(100,math.floor(tonumber(mon.hpPercent) or 0)))).."%"
end
local function drawChallengeIntermission(state,viewport)
  if V.MtBattleBattlePoints then
    state.model=state.model or {}
    state.model.bp=V.MtBattleBattlePoints.summary(state.game)
    local live=SaveState.state(state.game)
    state.model.bag=live.bag
  end
  if Mobile and Mobile.active(viewport) then
    local m=state.model or {};local headline,sub=intermissionHeadline(m)
    local total=math.max(1,tonumber(m.totalFights) or climbLengthFor(state.game))
    local rows={mobileStat("WINS",tostring(m.fightsWon or 0).." / "..total),
      mobileStat("CONTINUES",tostring(m.continuesRemaining or 0).." LEFT"),
      mobileStat("XP BANK",math.floor(tonumber(m.xpBank) or 0)),
      mobileStat("NEXT BATTLE",m.nextFight or "--",m.nextContext or sub)}
    if m.bp then
      table.insert(rows,1,mobileStat("BP BALANCE",m.bp.balance,"SELECT opens BP rewards, supplies and battle records."))
      if m.bpAward then table.insert(rows,2,mobileStat("BP EARNED",tostring(m.bpAward.amount).." BP",
        bpAwardDescription(m.bpAward))) end
    end
    for i,mon in ipairs(m.teamStatus or {}) do
      rows[#rows+1]=mobileStat(speciesName(state.game,mon),intermissionTeamLabel(mon),"TEAM SLOT "..i.." / "..intermissionTeamLabel(mon))
    end
    return Mobile.draw(state,viewport,{title=headline,subtitle=sub,section="RUN STATUS",rows=rows,
      cursor=state.mobileInfoCursor or 1,team=false,focusedList=true,detail=state.message,
      hints={"A "..tostring(m.action or "Next battle")..(m.itemUseAllowed and "   LEFT Heal" or ""),
        "START Save   B Suspend   RIGHT End","SELECT BP / Records   UP/DOWN Status"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=challengeLayout(sw,sh,sx,sy);local s=L.s
  local m=state.model or {};local headline,sub=intermissionHeadline(m)
  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  set(g,{0,0,0,(m.areaBreak or m.complete) and .14 or .09});g.rectangle("fill",sx,sy,sw,sh)

  -- Left rail: progress + the one explicit action that is allowed to advance
  -- the run.  The center lane stays untouched so Wes/Summit remain visible.
  local total=math.max(1,tonumber(m.totalFights) or climbLengthFor(state.game))
  local r=L.left;panel(g,r,true);challengeTab(g,r,"MT. BATTLE "..tostring(total),s)
  local pad=clamp(14*s,11,18)
  text(g,headline,r.x+pad,r.y+13*s,clamp(15*s,12,19),m.kind=="failed" and C.red or C.ink)
  text(g,sub,r.x+pad,r.y+34*s,clamp(9*s,8,11),(m.areaBreak or m.complete) and C.gold or C.dim)
  sectionRule(g,r.x+pad,r.y+51*s,r.w-pad*2)

  local y=r.y+65*s
  local wins=math.max(0,tonumber(m.fightsWon) or 0)
  text(g,"RUN PROGRESS",r.x+pad,y,clamp(9*s,8,11),C.dim)
  local prog=tostring(wins).." / "..tostring(total)
  text(g,prog,r.x+r.w-pad-textWidth(prog,9*s),y,clamp(9*s,8,11),C.gold)
  y=y+18*s
  local barW=r.w-pad*2;set(g,C.panelSoft);rr(g,"fill",r.x+pad,y,barW,7*s,3*s)
  set(g,m.complete and C.green or C.gold);rr(g,"fill",r.x+pad,y,barW*clamp(wins/total,0,1),7*s,3*s)
  y=y+18*s
  local areaProgress=math.max(0,tonumber(m.areaProgress) or 0)
  text(g,"AREA "..tostring(m.area or 1),r.x+pad,y,clamp(9*s,8,11),C.muted)
  local areaText=tostring(areaProgress).." / 10"
  text(g,areaText,r.x+r.w-pad-textWidth(areaText,9*s),y,clamp(9*s,8,11),C.muted)

  y=y+22*s
  local cardH=clamp(62*s,52,78)
  set(g,(m.nextIsAreaLeader or m.complete) and C.gold or C.panelSoft,(m.nextIsAreaLeader or m.complete) and .13 or .36)
  rr(g,"fill",r.x+pad,y,r.w-pad*2,cardH,5*s)
  if m.complete then
    text(g,"SUMMIT CLEARED",r.x+pad+10*s,y+10*s,clamp(11*s,9,14),C.green)
    text(g,"XP BANK READY FOR FINALE",r.x+pad+10*s,y+30*s,clamp(8.5*s,7,10),C.muted)
  elseif m.kind=="failed" then
    text(g,"RUN RESULT",r.x+pad+10*s,y+10*s,clamp(10*s,8,13),C.red)
    text(g,"BATTLE "..tostring(m.failedFight or m.currentFight or "--").."  /  FORFEIT",r.x+pad+10*s,y+30*s,clamp(9*s,8,11),C.muted)
  else
    text(g,"NEXT  BATTLE "..string.format("%03d",tonumber(m.nextFight) or 0),r.x+pad+10*s,y+9*s,clamp(10*s,8,13),C.ink)
    text(g,m.nextContext~="" and m.nextContext or "MT. BATTLE TRAINER",r.x+pad+10*s,y+29*s,
      clamp(9*s,8,11),(m.nextIsAreaLeader or m.nextIsFinale) and C.gold or C.muted)
  end

  local actionH=clamp(76*s,64,90);local ay=r.y+r.h-pad-actionH
  set(g,m.kind=="failed" and C.red or C.green,.15);rr(g,"fill",r.x+pad,ay,r.w-pad*2,actionH,6*s)
  set(g,m.kind=="failed" and C.red or C.green,.85);rr(g,"line",r.x+pad+.5,ay+.5,r.w-pad*2-1,actionH-1,6*s)
  text(g,"A  "..tostring(m.action or "NEXT BATTLE"),r.x+pad+12*s,ay+7*s,clamp(10*s,8.5,13),m.kind=="failed" and C.red or C.green)
  if m.itemUseAllowed then text(g,"<  CHALLENGE BAG  /  HEAL TEAM",r.x+pad+12*s,ay+24*s,clamp(7.2*s,6.2,9),C.gold) end
  text(g,"START  SAVE     B  SUSPEND & QUIT",r.x+pad+12*s,ay+41*s,clamp(6.8*s,6,8.5),C.dim)
  text(g,V.MtBattleBattlePoints and "SELECT  BP / RECORDS     >  END RUN" or "SELECT  RECORDS     >  END RUN",r.x+pad+12*s,ay+57*s,clamp(6.8*s,6,8.5),C.dim)
  if state.message then
    text(g,tostring(state.message),r.x+pad,ay-15*s,clamp(7.5*s,6.5,9.5),C.green)
  end

  -- Right rail: durable run resources and a compact snapshot of the team as
  -- it left the battle.  This is status presentation only; the next fight's
  -- Level-50 clones remain governed by LevelClone/RunController.
  local q=L.right;panel(g,q,true);local qp=clamp(12*s,9,15)
  text(g,"RUN STATUS",q.x+qp,q.y+11*s,clamp(12*s,10,15),C.ink)
  sectionRule(g,q.x+qp,q.y+31*s,q.w-qp*2)
  local rows={
    {"WINS",tostring(wins)},
    {"AREA",tostring(m.area or 1).." / "..tostring(math.max(1,math.ceil(total/10)))},
    {"CONTINUE",tostring(m.continuesRemaining or 0).." LEFT"},
    {"XP / BP",tostring(math.floor(tonumber(m.xpBank) or 0)).." / "..tostring(m.bp and m.bp.balance or 0)},
  }
  local ry=q.y+42*s;local rowH=clamp(18*s,16,22)
  for i,row in ipairs(rows) do
    if i%2==0 then set(g,C.panelSoft,.24);rr(g,"fill",q.x+qp,ry-1*s,q.w-qp*2,rowH,0) end
    text(g,row[1],q.x+qp+3*s,ry+3*s,clamp(8*s,7,10),C.dim)
    local fs=clamp(8*s,7,10);text(g,row[2],q.x+q.w-qp-3*s-textWidth(row[2],fs),ry+3*s,fs,i==3 and C.gold or C.muted)
    ry=ry+rowH
  end

  text(g,"CHALLENGE BAG",q.x+qp,ry+4*s,clamp(8.5*s,7,10),C.gold);ry=ry+18*s
  local gap=4*s;local cw=(q.w-qp*2-gap)/2;local ch=clamp(15*s,13,18)
  for i,row in ipairs(INTERMISSION_BAG) do
    local col=(i-1)%2;local line=math.floor((i-1)/2);local x=q.x+qp+col*(cw+gap);local yy=ry+line*(ch+2*s)
    set(g,C.panelSoft,.34);rr(g,"fill",x,yy,cw,ch,0)
    text(g,row[2],x+4*s,yy+2*s,clamp(7*s,6,8),C.dim)
    local qty=tostring((m.bag and m.bag[row[1]]) or 0);text(g,qty,x+cw-4*s-textWidth(qty,7*s),yy+2*s,clamp(7*s,6,8),C.muted)
  end
  ry=ry+3*(ch+2*s)+3*s
  text(g,"LAST BATTLE TEAM",q.x+qp,ry,clamp(8.5*s,7,10),C.gold);ry=ry+14*s
  local team=m.teamStatus or {}
  for i=1,6 do
    local col=(i-1)%2;local line=math.floor((i-1)/2);local x=q.x+qp+col*(cw+gap);local yy=ry+line*(ch+2*s);local mon=team[i]
    set(g,C.panelSoft,.34);rr(g,"fill",x,yy,cw,ch,0)
    text(g,speciesName(state.game,mon):sub(1,7),x+4*s,yy+2*s,clamp(7*s,6,8),mon and C.muted or C.dim)
    local st=intermissionTeamLabel(mon);local sc=mon and mon.fainted and C.red or C.dim
    text(g,st,x+cw-4*s-textWidth(st,7*s),yy+2*s,clamp(7*s,6,8),sc)
  end
  g.pop()
end
HSc._test.intermissionHeadline=intermissionHeadline
HSc._test.bpAwardDescription=bpAwardDescription
HSc._test.intermissionTeamLabel=intermissionTeamLabel

local function challengeBagMoveLabel(game,mv)
  local id=type(mv)=="table" and mv.id or mv
  local def=game and game.data and game.data.moves and game.data.moves[id]
  return tostring((def and def.name) or id or "MOVE")
end

local function drawChallengeBagUse(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local phase=state.phase or "item";local m=state.model or {};local rows={};local cursor
    local item=INTERMISSION_BAG[state.itemCursor or 1]
    local itemName=item and item[1]:gsub("_"," ") or "ITEM"
    if phase=="item" then
      cursor=state.itemCursor
      for _,row in ipairs(INTERMISSION_BAG) do
        local count=(m.bag or {})[row[1]] or 0
        rows[#rows+1]=mobileStat(row[1]:gsub("_"," "),count,"Choose the item, then the Pokemon. Only the Challenge Bag is used.")
        rows[#rows].disabled=count<=0
      end
    elseif phase=="target" then
      cursor=state.targetCursor
      for i=1,6 do
        local mon=(m.teamStatus or {})[i]
        rows[i]={label=speciesName(state.game,mon),meta=intermissionTeamLabel(mon),detail=itemName.." / Team slot "..i,disabled=mon==nil}
      end
    else
      cursor=state.moveCursor
      local mon=(m.teamStatus or {})[state.targetCursor or 1] or {}
      for i,mv in ipairs(mon.moves or {}) do
        rows[i]={label=challengeBagMoveLabel(state.game,mv),meta="PP "..tostring(mv.pp or 0).." / "..tostring(mv.maxPp or 0),
          detail=itemName.." / "..speciesName(state.game,mon)}
      end
    end
    return Mobile.draw(state,viewport,{title="CHALLENGE BAG",subtitle=phase=="item" and "CHOOSE AN ITEM" or (itemName.." / "..(phase=="target" and "CHOOSE A POKEMON" or "CHOOSE A MOVE")),
      section=phase:upper(),rows=rows,cursor=cursor or 1,team=false,focusedList=true,twoLineRows=phase~="item",detail=state.message,
      hints={"UP/DOWN Browse   A Select / Use","B Back"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport)
  local s=math.max(.72,math.min(1.55,math.min(sw/640,sh/360)))
  g.push("all");g.origin();g.setShader();set(g,{0,0,0,.38});g.rectangle("fill",sx,sy,sw,sh)
  local w=clamp(sw*.72,470*s,760*s);local h=clamp(sh*.76,245*s,420*s)
  local r={x=sx+(sw-w)*.5,y=sy+(sh-h)*.48,w=w,h=h};panel(g,r,true)
  local pad=clamp(15*s,11,20)
  text(g,"CHALLENGE BAG",r.x+pad,r.y+12*s,clamp(15*s,12,19),C.ink)
  local phase=tostring(state.phase or "item")
  local sub=phase=="item" and "CHOOSE AN ITEM" or (phase=="target" and "CHOOSE A POKEMON" or "CHOOSE A MOVE")
  text(g,sub,r.x+pad,r.y+33*s,clamp(8.5*s,7,11),C.gold);sectionRule(g,r.x+pad,r.y+49*s,r.w-pad*2)
  local leftX,leftY,leftW=r.x+pad,r.y+62*s,r.w*.40-pad
  for i,row in ipairs(INTERMISSION_BAG) do
    local yy=leftY+(i-1)*clamp(25*s,21,31);local selected=phase=="item" and i==state.itemCursor
    if selected then set(g,C.green,.18);rr(g,"fill",leftX,yy,leftW,21*s,4*s) end
    text(g,row[2],leftX+5*s,yy+4*s,clamp(8*s,7,10),selected and C.ink or C.muted)
    local qty=tostring((state.model and state.model.bag and state.model.bag[row[1]]) or 0)
    text(g,qty,leftX+leftW-5*s-textWidth(qty,8*s),yy+4*s,clamp(8*s,7,10),selected and C.gold or C.dim)
  end
  local rightX=r.x+r.w*.44;local rightY=leftY;local rightW=r.x+r.w-pad-rightX
  local team=(state.model and state.model.teamStatus) or {}
  if phase=="move" then
    local mon=team[state.targetCursor] or {};text(g,speciesName(state.game,mon),rightX,rightY,clamp(10*s,8,13),C.ink)
    for i,mv in ipairs(mon.moves or {}) do
      local yy=rightY+26*s+(i-1)*clamp(29*s,24,35);local selected=i==state.moveCursor
      if selected then set(g,C.green,.18);rr(g,"fill",rightX,yy,rightW,23*s,4*s) end
      local label=challengeBagMoveLabel(state.game,mv);local pp=tostring(mv.pp or 0).."/"..tostring(mv.maxPp or 0)
      text(g,label,rightX+5*s,yy+4*s,clamp(8*s,7,10),selected and C.ink or C.muted,"left",rightW*.68)
      text(g,pp,rightX+rightW-5*s-textWidth(pp,8*s),yy+4*s,clamp(8*s,7,10),selected and C.gold or C.dim)
    end
  else
    for i=1,6 do
      local mon=team[i];local yy=rightY+(i-1)*clamp(25*s,21,31);local selected=phase=="target" and i==state.targetCursor
      if selected then set(g,C.green,.18);rr(g,"fill",rightX,yy,rightW,21*s,4*s) end
      local name=speciesName(state.game,mon);local st=intermissionTeamLabel(mon)
      text(g,string.format("%d  %s",i,name),rightX+5*s,yy+4*s,clamp(8*s,7,10),selected and C.ink or C.muted,"left",rightW*.72)
      text(g,st,rightX+rightW-5*s-textWidth(st,8*s),yy+4*s,clamp(8*s,7,10),(mon and mon.fainted) and C.red or (selected and C.gold or C.dim))
    end
  end
  if state.message then text(g,tostring(state.message),r.x+pad,r.y+r.h-35*s,clamp(8*s,7,10),C.green,"left",r.w-pad*2) end
  text(g,"A  USE / SELECT     B  BACK",r.x+r.w-pad-220*s,r.y+r.h-18*s,clamp(7*s,6,9),C.dim)
  g.pop()
end

function HSc.pushChallengeBagUse(game,model)
  if not (ChallengeBag and SaveState and type(ChallengeBag.useIntermissionItem)=="function") then return nil,"challenge bag unavailable" end
  local state=hubSurface({game=game,model=model or {},kind="challengeBagUse",phase="item",itemCursor=1,targetCursor=1,moveCursor=1})
  state.__cbeMtBattleHubDraw=drawChallengeBagUse
  local function pop(self) if self.game.stack and self.game.stack:top()==self then self.game.stack:pop() end end
  local function refresh(self)
    local run=SaveState.state(self.game);self.model.teamStatus=run.lastTeamStatus;self.model.bag=self.model.bag or {}
    for _,row in ipairs(INTERMISSION_BAG) do self.model.bag[row[1]]=run.bag[row[1]] or 0 end
  end
  local function use(self,moveIndex)
    local item=INTERMISSION_BAG[self.itemCursor] and INTERMISSION_BAG[self.itemCursor][1]
    local ok,why=ChallengeBag.useIntermissionItem(self.game,SaveState,item,self.targetCursor,moveIndex)
    self.message=why or (ok and "ITEM USED" or "NO EFFECT")
    if ok then refresh(self);self.phase="item" end
  end
  function state:update()
    local input=self.game and self.game.input;if not (input and input.wasPressed) then return end
    local phase=self.phase
    if input:wasPressed("b") then
      if phase=="item" then pop(self) elseif phase=="move" then self.phase="target" else self.phase="item" end
      self.message=nil;return
    end
    local max=phase=="item" and #INTERMISSION_BAG or (phase=="target" and 6 or math.max(1,#(((self.model.teamStatus or {})[self.targetCursor] or {}).moves or {})))
    local key=phase=="item" and "itemCursor" or (phase=="target" and "targetCursor" or "moveCursor")
    if input:wasPressed("up") then self[key]=math.max(1,(self[key] or 1)-1);self.message=nil;return end
    if input:wasPressed("down") then self[key]=math.min(max,(self[key] or 1)+1);self.message=nil;return end
    if not input:wasPressed("a") then return end
    if phase=="item" then
      local item=INTERMISSION_BAG[self.itemCursor] and INTERMISSION_BAG[self.itemCursor][1]
      if ((self.model.bag or {})[item] or 0)<=0 then self.message="NONE LEFT";return end
      self.phase="target";self.targetCursor=1;self.message=nil
    elseif phase=="target" then
      local team=self.model.teamStatus or {};if not team[self.targetCursor] then self.message="NO POKEMON";return end
      local item=INTERMISSION_BAG[self.itemCursor] and INTERMISSION_BAG[self.itemCursor][1]
      if item=="ETHER" then self.phase="move";self.moveCursor=1;self.message=nil else use(self,nil) end
    else use(self,self.moveCursor) end
  end
  function state:draw() return stateCanvasDraw(self,drawChallengeBagUse) end
  game.stack:push(state);return state
end

local function drawEndRunConfirm(state,viewport)
  if Mobile and Mobile.active(viewport) then
    return Mobile.draw(state,viewport,{title="END RUN?",subtitle="THIS CANNOT BE UNDONE",section="CONFIRM FORFEIT",team=false,focusedList=true,warning=true,
      rows={{label="ABANDON THIS RUN",detail="Your current climb and XP Bank will be forfeited. B keeps the run active."}},
      hints={"A End run","B Keep run active"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=layoutFor(sw,sh,sx,sy);local s=L.s
  g.push("all");g.origin();g.setShader();set(g,{0,0,0,.16});g.rectangle("fill",sx,sy,sw,sh)
  local total=climbLengthFor(state.game,state.totalFights)
  titleHeader(g,L,"MT. BATTLE","BATTLE "..tostring(total).."  //  RUN CONTROL","END RUN?","THIS ACTION CANNOT BE UNDONE")
  local w=clamp(sw*.42,420*s,680*s);local h=clamp(230*s,190,300);local r={x=sx+(sw-w)*.5,y=sy+(sh-h)*.48,w=w,h=h}
  panel(g,r,true)
  text(g,"ABANDON THIS RUN?",r.x+28*s,r.y+28*s,clamp(23*s,18,31),C.red)
  text(g,"Your current climb and XP Bank will be forfeited. Saving or leaving the hub does NOT end the run.",
    r.x+28*s,r.y+69*s,clamp(11*s,9,14),C.muted,"left",r.w-56*s)
  set(g,C.red,.15);rr(g,"fill",r.x+28*s,r.y+r.h-82*s,r.w-56*s,50*s,7*s)
  set(g,C.red,.9);rr(g,"line",r.x+28*s+.5,r.y+r.h-82*s+.5,r.w-57*s,49*s,7*s)
  text(g,"A  END RUN",r.x+45*s,r.y+r.h-68*s,clamp(12*s,10,16),C.red)
  text(g,"B  KEEP RUN ACTIVE",r.x+45*s,r.y+r.h-35*s,clamp(10*s,9,13),C.green)
  g.pop()
end

local function drawSuspendRunConfirm(state,viewport)
  if Mobile and Mobile.active(viewport) then
    return Mobile.draw(state,viewport,{title="SUSPEND & QUIT?",subtitle="YOUR RUN STAYS ACTIVE",section="SAVE AND LEAVE",team=false,focusedList=true,
      rows={{label="BATTLE "..tostring(state.fight or 1),detail="Resume the same opponent and seed. No Continue is used; the unfinished attempt is not recorded."}},
      detail=state.message,hints={"A Suspend & quit","B Return to run"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=layoutFor(sw,sh,sx,sy);local s=L.s
  g.push("all");g.origin();g.setShader();set(g,{0,0,0,.16});g.rectangle("fill",sx,sy,sw,sh)
  local total=climbLengthFor(state.game,state.totalFights)
  local fight=math.max(1,math.floor(tonumber(state.fight) or 1))
  titleHeader(g,L,"MT. BATTLE","BATTLE "..tostring(total).."  //  RUN CONTROL","SUSPEND RUN?","RETURN TO THIS CLIMB LATER")
  local w=clamp(sw*.46,450*s,720*s);local h=clamp(248*s,205,320);local r={x=sx+(sw-w)*.5,y=sy+(sh-h)*.48,w=w,h=h}
  panel(g,r,true)
  text(g,"SUSPEND & QUIT?",r.x+28*s,r.y+26*s,clamp(23*s,18,31),C.gold)
  text(g,"Your run stays active. Battle "..tostring(fight).." will resume with the SAME opponent and seed, from the start of the fight. No Continue is used and this unfinished attempt is not recorded.",
    r.x+28*s,r.y+65*s,clamp(10.5*s,9,13.5),C.muted,"left",r.w-56*s)
  set(g,C.gold,.14);rr(g,"fill",r.x+28*s,r.y+r.h-82*s,r.w-56*s,50*s,7*s)
  set(g,C.gold,.9);rr(g,"line",r.x+28*s+.5,r.y+r.h-82*s+.5,r.w-57*s,49*s,7*s)
  text(g,"A  SUSPEND & QUIT",r.x+45*s,r.y+r.h-68*s,clamp(12*s,10,16),C.gold)
  text(g,"B  RETURN TO BATTLE",r.x+45*s,r.y+r.h-35*s,clamp(10*s,9,13),C.green)
  if state.message then text(g,tostring(state.message),r.x+28*s,r.y+r.h-104*s,clamp(8*s,7,10),C.red) end
  g.pop()
end

local ACTIVE_RUN_ACTIONS={"RESUME RUN","SUSPEND & QUIT","END RUN"}
local function drawActiveRunControl(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local run=state.game and state.game.save and state.game.save.mtBattleChallenge or state.run or {}
    local rows={{label="RESUME RUN",detail="Return to the saved challenge boundary."},
      {label="SUSPEND & QUIT",detail="Keep this run active and return to the overworld."},
      {label="END RUN",detail="Forfeit the climb and XP Bank only after confirmation."}}
    return Mobile.draw(state,viewport,{title="ACTIVE RUN",subtitle="BATTLE "..tostring(run.currentFight or 1).." / "..climbLengthFor(state.game,run.totalFights),
      rows=rows,cursor=state.cursor or 1,team=false,detail=state.message,
      hints={"UP/DOWN Browse   A Select","B Suspend   SELECT Records"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=challengeLayout(sw,sh,sx,sy);local s=L.s
  local run=state.game and state.game.save and state.game.save.mtBattleChallenge or state.run or {}
  local total=climbLengthFor(state.game,run.totalFights or state.totalFights)
  local fight=math.max(1,math.floor(tonumber(run.currentFight) or tonumber(state.fight) or 1))
  local wins=math.max(0,math.floor(tonumber(run.fightsWon) or 0))
  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  set(g,{0,0,0,.12});g.rectangle("fill",sx,sy,sw,sh)

  local r=L.left;panel(g,r,true);challengeTab(g,r,"MT. BATTLE "..tostring(total),s)
  local pad=clamp(14*s,11,18)
  text(g,"ACTIVE RUN",r.x+pad,r.y+13*s,clamp(15*s,12,20),C.ink)
  text(g,"BATTLE "..string.format("%03d",fight).."  //  "..tostring(wins).." WINS",r.x+pad,r.y+34*s,clamp(8*s,7,10),C.gold)
  sectionRule(g,r.x+pad,r.y+51*s,r.w-pad*2)
  local top=r.y+66*s;local gap=clamp(6*s,4,8)
  local bottom=r.y+r.h-pad-clamp(31*s,25,39)
  local bh=clamp((bottom-top-gap*2)/3,43*s,61*s)
  local subs={
    ["RESUME RUN"]="Return to the saved challenge boundary",
    ["SUSPEND & QUIT"]="Keep this run active and return to the overworld",
    ["END RUN"]="Forfeit the run only after confirmation",
  }
  for i,label in ipairs(ACTIVE_RUN_ACTIONS) do
    local accent=label=="END RUN" and C.red or (label=="SUSPEND & QUIT" and C.gold or C.green)
    button(g,{x=r.x+pad,y=top+(i-1)*(bh+gap),w=r.w-pad*2,h=bh},(state.cursor or 1)==i,label,subs[label],accent)
  end
  text(g,"A SELECT   B SUSPEND & QUIT   SELECT RECORDS",r.x+pad,r.y+r.h-23*s,clamp(6.5*s,5.8,8.2),C.dim,"left",r.w-pad*2)
  if state.message then text(g,tostring(state.message),r.x+pad,r.y+r.h-39*s,clamp(7*s,6,9),C.red,"left",r.w-pad*2) end

  local q=L.right;panel(g,q,true);local qp=clamp(12*s,9,15)
  text(g,"RUN STATUS",q.x+qp,q.y+11*s,clamp(12*s,10,15),C.ink)
  sectionRule(g,q.x+qp,q.y+31*s,q.w-qp*2)
  local rows={
    {"BATTLE",tostring(fight).." / "..tostring(total)},
    {"WINS",tostring(wins)},
    {"CONTINUE",tostring(math.max(0,(run.continuesTotal or 1)-(run.continuesUsed or 0))).." LEFT"},
    {"XP BANK",tostring(math.floor(tonumber(run.xpBank) or 0))},
  }
  local y=q.y+43*s;local rh=clamp(22*s,18,28)
  for i,row in ipairs(rows) do
    if i%2==0 then set(g,C.panelSoft,.24);rr(g,"fill",q.x+qp,y,q.w-qp*2,rh,0) end
    text(g,row[1],q.x+qp+3*s,y+4*s,clamp(7.5*s,6.5,9.5),C.dim)
    local fs=clamp(7.5*s,6.5,9.5);text(g,row[2],q.x+q.w-qp-3*s-textWidth(row[2],fs),y+4*s,fs,C.muted)
    y=y+rh
  end
  y=y+9*s;text(g,"SUSPEND IS NON-DESTRUCTIVE",q.x+qp,y,clamp(7.5*s,6.5,9.5),C.gold);y=y+17*s
  text(g,"The same fight, opponent seed, locked team, XP Bank, and Continue count remain intact.",
    q.x+qp,y,clamp(7.5*s,6.5,9.5),C.muted,"left",q.w-qp*2)
  g.pop()
end
HSc._test.ACTIVE_RUN_ACTIONS=ACTIVE_RUN_ACTIONS

local function recordHistoryRows(value)
  if type(value)~="table" then return {} end
  if type(value.battleHistory)=="table" then return value.battleHistory end
  if type(value.entries)=="table" then return value.entries end
  return value
end
local function recordTrainerLabel(entry)
  if entry and (entry.trainerName or entry.trainerTitle) then
    local title=entry.trainerTitle and tostring(entry.trainerTitle) or nil
    local name=entry.trainerName and tostring(entry.trainerName) or nil
    if title and name then return title.." "..name end
    return name or title
  end
  local identity=entry and (entry.identity or entry.trainerIdentity or entry.trainer)
  if type(identity)=="table" then
    return tostring(identity.displayName or identity.name or identity.label or identity.id or "MT. BATTLE TRAINER")
  elseif identity~=nil then return tostring(identity) end
  return "MT. BATTLE TRAINER"
end
local function recordMoveLabel(move)
  if type(move)=="table" then return tostring(move.name or move.id or "MOVE") end
  return tostring(move or "")
end
local function recordDefeatedRows(entry)
  -- RecordsManager's naming is from the battle's point of view:
  -- enemyKnockouts are opposing Pokemon the PLAYER knocked out, while
  -- playerKnockouts are the player's own faint events.  Keep that distinction
  -- centralized so the records UI cannot accidentally invert the user's KO
  -- history again.
  return type(entry)=="table" and type(entry.enemyKnockouts)=="table" and entry.enemyKnockouts or {}
end
local function recordTeamFaintRows(entry)
  return type(entry)=="table" and type(entry.playerKnockouts)=="table" and entry.playerKnockouts or {}
end
local function recordSpeciesList(game,rows,limit)
  local names={}
  for i=1,math.min(#(rows or {}),limit or 6) do
    local mon=rows[i]
    if type(mon)=="table" then names[#names+1]=speciesName(game,mon)
    else names[#names+1]=tostring(mon or "POKéMON") end
  end
  return names
end
local function hallTeamNames(game,entry)
  local names={}
  for i,row in ipairs((entry and entry.team) or {}) do
    if i>6 then break end
    if type(row)=="table" then names[#names+1]=speciesName(game,row)
    else names[#names+1]=speciesName(game,{species=row}) end
  end
  return names
end
local function mobileRecordDetails(state,hall)
  local rows={};local summary=state.summary or {};local current=state.currentRun or {}
  local function stat(k,v) rows[#rows+1]=mobileStat(k,v) end
  local list=hall and (state.runs or summary.runHistory or summary.hallOfFame or {}) or (state.history or {})
  local entry=list[state.cursor or 0]
  stat("LIFETIME CLEARS",summary.clears or 0);stat("TOTAL WINS",summary.totalBattleWins or summary.totalVictories or summary.totalWins or 0)
  stat("TOTAL LOSSES",summary.totalBattleLosses or 0);stat("TOTAL ATTEMPTS",summary.totalBattlesPlayed or 0)
  stat("BEST STREAK",summary.bestStreak or 0);stat("PERFECT BATTLES",summary.perfectBattles or summary.perfectClears or 0)
  stat("BATTLE 100 WINS",summary.battle100Victories or 0);stat("LARGEST XP BANK",summary.largestXpBank or 0)
  stat("TOTAL POKEMON DEFEATED",summary.totalOpponentPokemonDefeated or 0);stat("TOTAL TEAM FAINTS",summary.totalPlayerKnockouts or 0)
  stat("CURRENT RUN",current.active and (tostring(current.currentFight or 1).." / "..tostring(current.totalFights or 100)) or "NONE")
  stat("CURRENT XP BANK",current.xpBank or 0);stat("CURRENT BP EARNED",current.bpEarned or 0)
  if current.active then
    stat("CURRENT WINS",current.fightsWon or 0);stat("CURRENT ATTEMPTS",current.battlesPlayed or #(current.battleHistory or {}))
    stat("CURRENT CONTINUES",tostring(current.continuesUsed or 0).." / "..tostring(current.continuesTotal or 1).." USED")
  end
  if entry then
    stat("RESULT",tostring(entry.result or "--"):upper())
    if hall then
      stat("FORMAT",tostring(entry.totalFights or entry.format or 100).." BATTLES")
      stat("BATTLES WON",entry.fightsWon or "--");stat("ATTEMPTS",entry.battlesPlayed or entry.attempts or "--")
      stat("CONTINUES USED",entry.continuesUsed~=nil and entry.continuesUsed or "--");stat("ITEMS USED",entry.itemsUsed~=nil and entry.itemsUsed or "--");stat("RUN XP BANK",entry.xpBank or "--");stat("RUN BP EARNED",entry.bpEarned or 0);stat("RUN BP SPENT",entry.bpSpent or 0)
    else
      stat("BATTLE",entry.fightIndex or state.cursor);stat("ATTEMPT",entry.attempt or 1)
      stat("BP EARNED",entry.bpEarned or 0);stat("BP BALANCE AFTER",entry.bpBalanceAfter or 0);stat("XP BANK AFTER",entry.xpBankAfter or 0);stat("CONTINUES USED",entry.continuesUsed or 0)
      stat("TRAINER",recordTrainerLabel(entry))
      stat("STYLE",tostring(entry.personality or "--").." / "..tostring(entry.archetype or "--"))
      stat("AREA",tostring(entry.area or math.ceil((entry.fightIndex or 1)/10))..(entry.isAreaLeader and " / LEADER" or ""))
      stat("POKEMON DEFEATED",#recordDefeatedRows(entry));stat("TEAM FAINTS",#recordTeamFaintRows(entry))
    end
    local function mons(label,team)
      for i,mon in ipairs(team or {}) do
        local m=type(mon)=="table" and mon or {species=mon}
        local moves={};for _,mv in ipairs(m.moves or {}) do moves[#moves+1]=recordMoveLabel(mv) end
        rows[#rows+1]={label=(m.shiny and "* " or "")..speciesName(state.game,m),meta=label.." "..i,
          detail=#moves>0 and table.concat(moves," / ") or label.." / "..speciesName(state.game,m)}
      end
    end
    if hall then mons("TEAM",entry.team)
    else mons("OPPONENT",entry.opponentTeam);mons("YOUR TEAM",entry.playerTeam)
      mons("DEFEATED",recordDefeatedRows(entry));mons("TEAM FAINT",recordTeamFaintRows(entry)) end
  end
  return rows
end
local function mobileRecordInput(state,hall)
  if not (Mobile and Mobile.active()) then return false end
  local input=state.game and state.game.input
  if not (input and input.wasPressed) then return false end
  if input:wasPressed("a") then state.mobileDetails=true;state.mobileDetailCursor=1;return true end
  if not state.mobileDetails or input:wasPressed("select") then return false end
  if input:wasPressed("b") then state.mobileDetails=nil;return true end
  local delta=input:wasPressed("up") and -1 or (input:wasPressed("down") and 1 or
    (input:wasPressed("left") and -6 or (input:wasPressed("right") and 6 or 0)))
  state.mobileDetailCursor=clamp((state.mobileDetailCursor or 1)+delta,1,#mobileRecordDetails(state,hall))
  return true
end

local function drawHallOfFame(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local summary=state.summary or {};local runs=state.runs or summary.runHistory or summary.hallOfFame or {};local rows={}
    if state.mobileDetails then rows=mobileRecordDetails(state,true)
    else
      for i,run in ipairs(runs) do
        local total=normalizedClimbLength(run.totalFights or run.format or 100)
        local tag=tostring(run.result or ""):lower()=="failed" and "FAILED" or (run.perfect and "PERFECT" or "CLEAR")
        rows[i]={label="#"..i.." / "..total.." BATTLES",meta=tag,detail="A opens this run's complete stats and team."}
      end
    end
    return Mobile.draw(state,viewport,{title="HALL OF FAME",subtitle="ALL RECORDED RUNS / "..tostring(summary.clears or 0).." CLEARS",
      section=state.mobileDetails and "RUN DETAILS" or "RECORDED RUNS",rows=rows,team=false,focusedList=true,twoLineRows=true,
      cursor=state.mobileDetails and (state.mobileDetailCursor or 1) or state.cursor,
      detail=#rows==0 and "No recorded runs. A opens current-run and lifetime statistics." or nil,
      hints={"UP/DOWN Browse   LEFT/RIGHT Page",state.mobileDetails and "B Runs   SELECT Close" or "A Details   B / SELECT Close"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local s=MOBILE_RUNTIME and clamp(math.min(sh/HUB_UI_HEIGHT,sw/720),.72,1.20) or clamp(sh/HUB_UI_HEIGHT,.72,1.35)
  local margin=clamp(math.min(sw,sh)*.028,9*s,20*s);local gap=clamp(8*s,6,13)
  local headerH=clamp(50*s,40,66);local footerH=clamp(34*s,28,48)
  local bodyY=sy+margin+headerH+gap;local bodyH=sh-margin*2-headerH-footerH-gap*2
  local panes=twoPaneLayout(sw,sh,sx,sy,bodyY,bodyH,margin,gap,.38,.35,215*s,430*s)
  local left,right=panes.left,panes.right
  local footer={x=sx+margin,y=sy+sh-margin-footerH,w=sw-margin*2,h=footerH}
  local summary=state.summary or {};local runs=summary.runHistory or summary.hallOfFame or {};local current=state.currentRun or {}
  local cursor=(#runs>0) and clamp(state.cursor or 1,1,#runs) or 0
  local entry=cursor>0 and runs[cursor] or nil

  g.push("all");g.origin();g.setShader();g.setLineWidth(1);set(g,{0,0,0,.52});g.rectangle("fill",sx,sy,sw,sh)
  text(g,"HALL OF FAME",sx+margin,sy+margin+2*s,clamp(21*s,16,28),C.ink)
  text(g,"MT. BATTLE  //  ALL RECORDED RUNS + CURRENT RUN",sx+margin,sy+margin+28*s,clamp(8.5*s,7.5,11),C.gold)

  panel(g,left,true);local lp=clamp(12*s,9,16)
  text(g,"RECORDED RUNS",left.x+lp,left.y+10*s,clamp(11*s,9,14),C.ink)
  sectionRule(g,left.x+lp,left.y+29*s,left.w-lp*2)
  local listY=left.y+39*s;local rh=clamp(26*s,22,32)
  local visible=math.max(1,math.floor((left.h-48*s)/rh));local first=1
  if cursor>visible then first=math.min(math.max(1,#runs-visible+1),cursor-math.floor(visible/2)) end
  if #runs==0 then
    text(g,"NO COMPLETED RUNS YET",left.x+lp,listY+8*s,clamp(8*s,7,10),C.dim)
  else
    for n=0,visible-1 do
      local i=first+n;local run=runs[i];if not run then break end
      local yy=listY+n*rh;local focused=i==cursor
      if focused then set(g,C.gold,.15);rr(g,"fill",left.x+lp,yy,left.w-lp*2,rh-2*s,3*s) end
      local total=normalizedClimbLength(run.totalFights or run.format or 100)
      local clearNo=tonumber(run.clearNumber) or (#runs-i+1)
      text(g,string.format("#%03d  %3d BATTLE",clearNo,total),left.x+lp+4*s,yy+3*s,clamp(8*s,7,10),focused and C.ink or C.muted)
      local failed=tostring(run.result or ""):lower()=="failed"
      local tag=failed and "FAILED" or (run.perfect and "PERFECT" or "CLEAR");local fs=clamp(7*s,6,9)
      text(g,tag,left.x+left.w-lp-4*s-textWidth(tag,fs),yy+5*s,fs,failed and C.red or (run.perfect and C.gold or C.green))
      local team=hallTeamNames(state.game,run)
      text(g,#team>0 and table.concat(team," / ") or "TEAM NOT RECORDED",left.x+lp+4*s,yy+14*s,
        clamp(6*s,5.5,7.5),C.dim,"left",left.w-lp*2-8*s)
    end
  end

  panel(g,right,true);local rp=clamp(13*s,10,17)
  if entry then
    local total=normalizedClimbLength(entry.totalFights or entry.format or 100)
    text(g,"SELECTED RUN",right.x+rp,right.y+10*s,clamp(9*s,8,11),C.dim)
    text(g,tostring(total).." BATTLE RUN",right.x+rp,right.y+28*s,clamp(15*s,12,20),C.gold)
    sectionRule(g,right.x+rp,right.y+52*s,right.w-rp*2)
    local failed=tostring(entry.result or ""):lower()=="failed"
    local rows={
      {"RESULT",failed and "FAILED" or (entry.perfect and "PERFECT CLEAR" or "CLEAR")},
      {"BATTLES WON",entry.fightsWon or total},
      {"ATTEMPTS",entry.battlesPlayed or entry.attempts or "--"},
      {"CONTINUES USED",entry.continuesUsed~=nil and entry.continuesUsed or "--"},
      {"ITEMS USED",entry.itemsUsed~=nil and entry.itemsUsed or "--"},
      {"XP BANK",entry.xpBank~=nil and entry.xpBank or "--"},
    }
    local y=right.y+63*s;local rowH=clamp(20*s,17,24)
    for i,row in ipairs(rows) do
      if i%2==0 then set(g,C.panelSoft,.24);rr(g,"fill",right.x+rp,y,right.w-rp*2,rowH,0) end
      text(g,row[1],right.x+rp+3*s,y+4*s,clamp(7*s,6,9),C.dim)
      local value=tostring(row[2]);local fs=clamp(7.5*s,6.5,9.5)
      text(g,value,right.x+right.w-rp-3*s-textWidth(value,fs),y+4*s,fs,C.muted)
      y=y+rowH
    end
    y=y+6*s;text(g,"TEAM",right.x+rp,y,clamp(8*s,7,10),C.gold);y=y+14*s
    local team=hallTeamNames(state.game,entry)
    text(g,#team>0 and table.concat(team,"  /  ") or "--",right.x+rp,y,clamp(7*s,6,9),C.muted,"left",right.w-rp*2)
  else
    text(g,"NO RUN SELECTED",right.x+rp,right.y+18*s,clamp(12*s,10,16),C.dim)
  end

  local cy=right.y+right.h-clamp(92*s,76,115);sectionRule(g,right.x+rp,cy,right.w-rp*2);cy=cy+10*s
  text(g,"CURRENT RUN",right.x+rp,cy,clamp(8.5*s,7,10.5),C.gold);cy=cy+15*s
  local active=current.active==true
  local ctotal=normalizedClimbLength(current.totalFights or 100)
  local line=active and ("BATTLE "..tostring(current.currentFight or 1).." / "..tostring(ctotal).."    WINS "..tostring(current.fightsWon or 0)) or "NO ACTIVE RUN"
  text(g,line,right.x+rp,cy,clamp(8*s,7,10),active and C.ink or C.dim,"left",right.w-rp*2);cy=cy+15*s
  if active then
    text(g,"XP BANK "..tostring(math.floor(tonumber(current.xpBank) or 0)).."    CONTINUE "..tostring(current.continuesUsed or 0).." / "..tostring(current.continuesTotal or 1),
      right.x+rp,cy,clamp(7*s,6,9),C.muted,"left",right.w-rp*2)
  end

  set(g,C.panelStrong,.96);rr(g,"fill",footer.x,footer.y,footer.w,footer.h,5*s)
  text(g,"UP/DOWN  RECORDED RUN     B / SELECT  RETURN",footer.x+12*s,footer.y+9*s,clamp(8*s,7,10),C.muted)
  g.pop()
end
HSc._test.hallTeamNames=hallTeamNames
local function drawBattleRecords(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local rows={};local summary=state.summary or {}
    if state.mobileDetails then rows=mobileRecordDetails(state,false)
    else
      for i,row in ipairs(state.history or {}) do
        rows[i]={label="BATTLE "..tostring(row.fightIndex or i),meta=tostring(row.result or "--"):upper().." / ATTEMPT "..tostring(row.attempt or 1),
          detail="A opens opponent/team details, Pokemon defeated and team faints."}
      end
    end
    return Mobile.draw(state,viewport,{title="BATTLE RECORDS",subtitle="CURRENT RUN + LIFETIME / "..tostring(summary.totalBattleWins or 0).." WINS",
      section=state.mobileDetails and "ATTEMPT DETAILS" or "BATTLE ATTEMPTS",rows=rows,team=false,focusedList=true,twoLineRows=true,
      cursor=state.mobileDetails and (state.mobileDetailCursor or 1) or state.cursor,
      detail=#rows==0 and "No completed attempts. A opens current-run and lifetime statistics." or nil,
      hints={"UP/DOWN Browse   LEFT/RIGHT Page",state.mobileDetails and "B Attempts   SELECT Close" or "A Details   B / SELECT Close"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local s=MOBILE_RUNTIME and clamp(math.min(sh/HUB_UI_HEIGHT,sw/720),.72,1.20) or clamp(sh/HUB_UI_HEIGHT,.72,1.35)
  local margin=clamp(math.min(sw,sh)*.028,9*s,20*s)
  local headerH=clamp(48*s,38,66);local footerH=clamp(34*s,28,48);local gap=clamp(8*s,6,13)
  local bodyY=sy+margin+headerH+gap;local bodyH=sh-margin*2-headerH-footerH-gap*2
  local panes=twoPaneLayout(sw,sh,sx,sy,bodyY,bodyH,margin,gap,.42,.34,210*s,420*s)
  local left,right=panes.left,panes.right
  local footer={x=sx+margin,y=sy+sh-margin-footerH,w=sw-margin*2,h=footerH}
  local summary=state.summary or {};local history=state.history or {};local cursor=state.cursor or 0
  local entry=cursor>0 and history[cursor] or nil

  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  set(g,{0,0,0,.52});g.rectangle("fill",sx,sy,sw,sh)
  text(g,"BATTLE RECORDS",sx+margin,sy+margin+2*s,clamp(21*s,16,28),C.ink)
  local currentTotal=normalizedClimbLength(state.currentRun and state.currentRun.totalFights or 100)
  text(g,"MT. BATTLE "..tostring(currentTotal).."  //  CURRENT RUN + LIFETIME",sx+margin,sy+margin+28*s,clamp(9*s,8,12),C.gold)

  panel(g,left,true);local lp=clamp(12*s,9,16)
  text(g,"LIFETIME",left.x+lp,left.y+10*s,clamp(11*s,9,14),C.ink)
  sectionRule(g,left.x+lp,left.y+29*s,left.w-lp*2)
  local lifetime={
    {"CLEARS",summary.clears or 0},{"BEST STREAK",summary.bestStreak or 0},
    {"TOTAL WINS",summary.totalBattleWins or summary.totalVictories or summary.totalWins or 0},
    {"PERFECT BATTLES",summary.perfectBattles or summary.perfectClears or 0},
    {"BATTLE 100 WINS",summary.battle100Victories or 0},
    {"LARGEST XP BANK",summary.largestXpBank or 0},
  }
  local y=left.y+39*s;local lh=clamp(17*s,15,21)
  for i,row in ipairs(lifetime) do
    if i%2==0 then set(g,C.panelSoft,.25);rr(g,"fill",left.x+lp,y,left.w-lp*2,lh,0) end
    text(g,row[1],left.x+lp+3*s,y+2*s,clamp(7.5*s,6.5,9),C.dim)
    local value=tostring(row[2]);text(g,value,left.x+left.w-lp-3*s-textWidth(value,7.5*s),y+2*s,clamp(7.5*s,6.5,9),C.muted)
    y=y+lh
  end
  y=y+5*s;text(g,"CURRENT RUN",left.x+lp,y,clamp(9*s,8,11),C.gold);y=y+15*s
  local available=math.max(1,math.floor((left.y+left.h-y-5*s)/lh));local first=1
  if cursor>available then first=math.min(math.max(1,#history-available+1),cursor-math.floor(available/2)) end
  for n=0,available-1 do
    local i=first+n;local row=history[i];if not row then break end
    local yy=y+n*lh;local focused=i==cursor
    if focused then set(g,C.gold,.15);rr(g,"fill",left.x+lp,yy,left.w-lp*2,lh,0) end
    local result=tostring(row.result or "--"):upper();local fight=tonumber(row.fightIndex) or i
    local label=string.format("%03d  %-4s  ATT %d",fight,result:sub(1,4),tonumber(row.attempt) or 1)
    text(g,label,left.x+lp+4*s,yy+2*s,clamp(7.5*s,6.5,9),focused and C.ink or C.muted)
  end

  panel(g,right,true);local rp=clamp(14*s,10,18)
  if not entry then
    text(g,"NO BATTLES RECORDED YET",right.x+rp,right.y+18*s,clamp(13*s,10,17),C.dim)
    text(g,"Completed attempts will appear here without affecting challenge state.",right.x+rp,right.y+45*s,
      clamp(9*s,8,11),C.muted,"left",right.w-rp*2)
  else
    local fight=tonumber(entry.fightIndex) or cursor
    local title="BATTLE "..string.format("%03d",fight).."  //  "..tostring(entry.result or "--"):upper()
    text(g,title,right.x+rp,right.y+12*s,clamp(13*s,10,17),C.ink)
    local area=tostring(entry.area or math.floor((fight-1)/10)+1)
    local badge=entry.isAreaLeader and "  //  AREA LEADER" or ""
    text(g,"AREA "..area..badge,right.x+rp,right.y+34*s,clamp(8.5*s,7,10),entry.isAreaLeader and C.gold or C.dim)
    sectionRule(g,right.x+rp,right.y+51*s,right.w-rp*2)
    local trainer=recordTrainerLabel(entry)
    text(g,trainer:upper(),right.x+rp,right.y+62*s,clamp(11*s,9,14),C.gold)
    local style=tostring(entry.personality or "--").."  /  "..tostring(entry.archetype or "--")
    text(g,style:upper(),right.x+rp,right.y+81*s,clamp(8*s,7,10),C.muted)
    local meta="ATTEMPT "..tostring(entry.attempt or 1).."    XP BANK "..tostring(entry.xpBankAfter or 0)..
      "    CONTINUE "..tostring(entry.continuesUsed or 0)
    text(g,meta,right.x+rp,right.y+99*s,clamp(8*s,7,10),C.dim)

    local team=entry.opponentTeam or {}
    local playerTeam=entry.playerTeam or {}
    local defeated=recordDefeatedRows(entry)
    local faints=recordTeamFaintRows(entry)
    local compact=right.h<360*s
    local oy=right.y+(compact and 112*s or 121*s)
    text(g,"OPPONENT TEAM",right.x+rp,oy,clamp(8.5*s,7,10),C.gold);oy=oy+13*s
    if compact then
      -- The 640x360 hub has only ~120 px below the trainer metadata.  A 2x3
      -- roster grid preserves all six identities and leaves room for the
      -- player's team + KO history instead of clipping the latter off-screen.
      local gap2=4*s;local cw=(right.w-rp*2-gap2)/2;local rh=clamp(15*s,13,18)
      for i=1,math.min(6,#team) do
        local mon=team[i] or {};local col=(i-1)%2;local row=math.floor((i-1)/2)
        local x=right.x+rp+col*(cw+gap2);local yy=oy+row*rh
        if row%2==1 then set(g,C.panelSoft,.20);rr(g,"fill",x,yy,cw,rh,0) end
        local name=speciesName(state.game,type(mon)=="table" and mon or {species=mon})
        if type(mon)=="table" and mon.shiny then name="* "..name end
        text(g,name:sub(1,13),x+3*s,yy+1*s,clamp(7*s,6,8),type(mon)=="table" and mon.shiny and C.gold or C.muted)
      end
      oy=oy+3*rh+4*s
      local yours=recordSpeciesList(state.game,playerTeam,6)
      text(g,"YOUR TEAM",right.x+rp,oy,clamp(7.5*s,6.5,9),C.gold)
      text(g,#yours>0 and table.concat(yours," / ") or "--",right.x+rp+62*s,oy,
        clamp(7*s,6,8),C.muted,"left",math.max(1,right.w-rp*2-62*s));oy=oy+14*s
      local names=recordSpeciesList(state.game,defeated,6)
      text(g,"POKéMON DEFEATED",right.x+rp,oy,clamp(7.5*s,6.5,9),C.gold);oy=oy+12*s
      text(g,#names>0 and table.concat(names," / ") or "NONE",right.x+rp,oy,
        clamp(7*s,6,8),C.muted,"left",right.w-rp*2)
    else
      local rowH=clamp(18*s,15,22)
      for i=1,math.min(6,#team) do
        local mon=team[i] or {};local yy=oy+(i-1)*rowH
        if i%2==0 then set(g,C.panelSoft,.23);rr(g,"fill",right.x+rp,yy,right.w-rp*2,rowH,0) end
        local species=speciesName(state.game,type(mon)=="table" and mon or {species=mon}):upper()
        if type(mon)=="table" and mon.shiny then species="* "..species end
        text(g,species,right.x+rp+4*s,yy+2*s,clamp(7.5*s,6.5,9),type(mon)=="table" and mon.shiny and C.gold or C.muted)
        local moves={};for n,mv in ipairs(type(mon)=="table" and (mon.moves or {}) or {}) do
          if n>2 then break end;moves[#moves+1]=recordMoveLabel(mv)
        end
        local moveText=table.concat(moves," / ")
        if moveText~="" then text(g,moveText,right.x+right.w-rp-(right.w*.45),yy+2*s,clamp(7*s,6,8),C.dim,"left",right.w*.43) end
      end
      local ky=oy+math.min(6,#team)*rowH+7*s
      local yours=recordSpeciesList(state.game,playerTeam,6)
      text(g,"YOUR CHALLENGE TEAM",right.x+rp,ky,clamp(8*s,7,10),C.gold);ky=ky+13*s
      text(g,#yours>0 and table.concat(yours,"  /  ") or "--",right.x+rp,ky,
        clamp(7.5*s,6.5,9),C.muted,"left",right.w-rp*2);ky=ky+19*s
      text(g,"POKéMON DEFEATED",right.x+rp,ky,clamp(8.5*s,7,10),C.gold);ky=ky+14*s
      local names=recordSpeciesList(state.game,defeated,6)
      text(g,#names>0 and table.concat(names,"  /  ") or "NONE",right.x+rp,ky,
        clamp(8*s,7,10),C.muted,"left",right.w-rp*2);ky=ky+20*s
      if #faints>0 and ky+14*s<right.y+right.h then
        local faintNames=recordSpeciesList(state.game,faints,6)
        text(g,"TEAM FAINTS",right.x+rp,ky,clamp(7.5*s,6.5,9),C.red);ky=ky+12*s
        text(g,table.concat(faintNames,"  /  "),right.x+rp,ky,clamp(7*s,6,8),C.dim,"left",right.w-rp*2)
      end
    end
  end
  set(g,C.panelStrong,.94);rr(g,"fill",footer.x,footer.y,footer.w,footer.h,5*s)
  text(g,"UP/DOWN  BATTLE     LEFT/RIGHT  +/-10     B / SELECT  CLOSE",footer.x+12*s,footer.y+9*s,clamp(8*s,7,10),C.muted)
  g.pop()
end
HSc._test.recordHistoryRows=recordHistoryRows
HSc._test.recordTrainerLabel=recordTrainerLabel
HSc._test.recordDefeatedRows=recordDefeatedRows
HSc._test.recordTeamFaintRows=recordTeamFaintRows

-- ===== Battle 100 finale / XP reward presentation =========================
local function drawFinaleSummary(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local m=state.model or {};local run=m.run or {};local summary=m.summary or {}
    local total=normalizedClimbLength(run.totalFights or m.totalFights or 100)
    local rows={mobileStat("XP BANK",m.xpBank or run.xpBank or 0,"Distribute the locked bank to your real owned Pokemon."),
      mobileStat("CONTINUES USED",m.continuesUsed or run.continuesUsed or 0),mobileStat("ATTEMPTS",#(run.battleHistory or {})),
      mobileStat("LIFETIME CLEARS",summary.clears or 0)}
    return Mobile.draw(state,viewport,{title=total.." / "..total.." CLEAR",subtitle="SUMMIT CHAMPION",section="CLEAR RECORD",
      rows=rows,cursor=state.mobileInfoCursor or 1,team=m.team or run.roster or {},focusedList=true,
      hints={"A / START Distribute XP","UP/DOWN Stats   SELECT Records"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=challengeLayout(sw,sh,sx,sy);local s=L.s
  local m=state.model or {};local run=m.run or {};local summary=m.summary or {}
  local total=normalizedClimbLength(run.totalFights or m.totalFights or 100)
  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  set(g,{0,0,0,.15});g.rectangle("fill",sx,sy,sw,sh)

  local r=L.left;panel(g,r,true);challengeTab(g,r,"MT. BATTLE "..tostring(total),s)
  local pad=clamp(14*s,11,18)
  text(g,"SUMMIT CHAMPION",r.x+pad,r.y+13*s,clamp(9*s,8,11),C.gold)
  text(g,tostring(total).." / "..tostring(total).." CLEAR",r.x+pad,r.y+31*s,clamp(18*s,14,23),C.ink)
  sectionRule(g,r.x+pad,r.y+57*s,r.w-pad*2)
  local y=r.y+70*s
  text(g,"THE CLIMB IS COMPLETE.",r.x+pad,y,clamp(11*s,9,14),C.ink);y=y+22*s
  text(g,"Your locked XP Bank is ready to distribute to your real owned POKéMON.",
    r.x+pad,y,clamp(8.5*s,7.5,11),C.muted,"left",r.w-pad*2);y=y+42*s
  local rows={
    {"XP BANK",math.floor(tonumber(m.xpBank or run.xpBank) or 0)},
    {"CONTINUES USED",tonumber(m.continuesUsed or run.continuesUsed) or 0},
    {"BATTLE ATTEMPTS",#(run.battleHistory or {})},
    {"LIFETIME CLEARS",tonumber(summary.clears) or 0},
  }
  local rh=clamp(21*s,18,26)
  for i,row in ipairs(rows) do
    if i%2==0 then set(g,C.panelSoft,.24);rr(g,"fill",r.x+pad,y,r.w-pad*2,rh,0) end
    text(g,row[1],r.x+pad+4*s,y+4*s,clamp(8*s,7,10),C.dim)
    local value=tostring(row[2]);local fs=clamp(8.5*s,7,10.5)
    text(g,value,r.x+r.w-pad-4*s-textWidth(value,fs),y+4*s,fs,row[1]=="XP BANK" and C.gold or C.muted)
    y=y+rh
  end
  local actionH=clamp(48*s,40,60);local ay=r.y+r.h-pad-actionH
  set(g,C.green,.16);rr(g,"fill",r.x+pad,ay,r.w-pad*2,actionH,6*s)
  set(g,C.green,.85);rr(g,"line",r.x+pad+.5,ay+.5,r.w-pad*2-1,actionH-1,6*s)
  text(g,"A  DISTRIBUTE XP",r.x+pad+12*s,ay+10*s,clamp(11*s,9,14),C.green)
  text(g,"SELECT  BATTLE RECORDS",r.x+pad+12*s,ay+29*s,clamp(8*s,7,10),C.dim)

  local q=L.right;panel(g,q,true);local qp=clamp(12*s,9,15)
  text(g,"CLEAR RECORD",q.x+qp,q.y+11*s,clamp(12*s,10,15),C.ink)
  sectionRule(g,q.x+qp,q.y+31*s,q.w-qp*2)
  local metrics={
    {"BEST STREAK",summary.bestStreak or total},{"TOTAL BATTLE WINS",summary.totalBattleWins or total},
    {"FORMAT CLEARS",summary.clearsByFormat and summary.clearsByFormat[total] or summary.clears or 1},
    {"LARGEST XP BANK",summary.largestXpBank or m.xpBank or 0},
  }
  local cy=q.y+43*s;local ch=clamp(20*s,17,24)
  for i,row in ipairs(metrics) do
    if i%2==0 then set(g,C.panelSoft,.24);rr(g,"fill",q.x+qp,cy,q.w-qp*2,ch,0) end
    text(g,row[1],q.x+qp+3*s,cy+4*s,clamp(7.5*s,6.5,9),C.dim)
    local value=tostring(row[2]);local fs=clamp(8*s,7,10)
    text(g,value,q.x+q.w-qp-3*s-textWidth(value,fs),cy+4*s,fs,C.muted);cy=cy+ch
  end
  cy=cy+8*s;text(g,"CHALLENGE TEAM",q.x+qp,cy,clamp(8*s,7,10),C.gold);cy=cy+14*s
  local roster=m.team or run.roster or {}
  for i=1,math.min(6,#roster) do
    text(g,string.format("%d  %s",i,speciesName(state.game,roster[i] or {})),q.x+qp+3*s,cy,
      clamp(7.5*s,6.5,9),C.muted,"left",q.w-qp*2-4*s)
    cy=cy+clamp(15*s,13,18)
  end
  g.pop()
end

local function xpAllocationStep(xpState)
  local total=xpState and type(xpState.bankTotal)=="function" and tonumber(xpState:bankTotal()) or 0
  return math.max(1,math.floor((total or 0)/20))
end

local function drawXPDistribution(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local xp=state.xpState;local entries=(xp and xp.eligibleMons) or {};local rows={}
    local bank=xp and xp:bankTotal() or 0;local remaining=xp and xp:remaining() or 0
    for i,entry in ipairs(entries) do
      local mon=entry.mon or {};local amount=(xp.allocated and xp.allocated[i]) or 0
      local detail="Allocated "..tostring(amount).." XP. "..tostring(remaining).." XP remaining."
      if i==state.cursor and type(xp.preview)=="function" then
        local ok,preview=pcall(xp.preview,xp,i)
        if ok and preview then detail=detail.." Level "..tostring(preview.fromLevel or mon.level or "--").." -> "..tostring(preview.toLevel or mon.level or "--") end
      end
      rows[i]={label=entry.label or speciesName(state.game,mon),meta="LV."..tostring(mon.level or "--").." / "..tostring(amount).." XP",detail=detail}
    end
    return Mobile.draw(state,viewport,{title="XP DISTRIBUTION",subtitle="BANK "..tostring(bank).." / LEFT "..tostring(remaining),section="OWNED POKEMON",
      rows=rows,cursor=state.cursor,team=false,focusedList=true,twoLineRows=true,
      detail=state.message or (#entries==0 and "No recipient available. START closes without an XP award." or nil),
      hints={"UP/DOWN Recipient   LEFT/RIGHT Adjust","A Add remainder   START Confirm","B Back   SELECT Records"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local s=MOBILE_RUNTIME and clamp(math.min(sh/HUB_UI_HEIGHT,sw/720),.72,1.20) or clamp(sh/HUB_UI_HEIGHT,.72,1.35)
  local margin=clamp(math.min(sw,sh)*.026,9*s,20*s);local gap=clamp(8*s,6,13)
  local headerH=clamp(55*s,45,72);local footerH=clamp(39*s,32,52)
  local bodyY=sy+margin+headerH+gap;local bodyH=sh-margin*2-headerH-footerH-gap*2
  local panes=twoPaneLayout(sw,sh,sx,sy,bodyY,bodyH,margin,gap,.48,.42,220*s,520*s)
  local left,right=panes.left,panes.right
  local footer={x=sx+margin,y=sy+sh-margin-footerH,w=sw-margin*2,h=footerH}
  local xp=state.xpState;local entries=(xp and xp.eligibleMons) or {}
  local total=xp and xp:bankTotal() or 0;local allocated=xp and xp:allocatedTotal() or 0
  local remaining=xp and xp:remaining() or 0;local cursor=state.cursor or 0

  g.push("all");g.origin();g.setShader();g.setLineWidth(1)
  set(g,{0,0,0,.42});g.rectangle("fill",sx,sy,sw,sh)
  text(g,"XP DISTRIBUTION",sx+margin,sy+margin+2*s,clamp(21*s,16,28),C.ink)
  local climbTotal=climbLengthFor(state.game)
  text(g,"MT. BATTLE "..tostring(climbTotal).." REWARD  //  ALLOCATE THE ENTIRE LOCKED BANK",sx+margin,sy+margin+29*s,clamp(8.5*s,7.5,11),C.gold)

  panel(g,left,true);local lp=clamp(12*s,9,16)
  text(g,"OWNED POKéMON",left.x+lp,left.y+10*s,clamp(11*s,9,14),C.ink)
  sectionRule(g,left.x+lp,left.y+29*s,left.w-lp*2)
  local rowH=clamp(25*s,21,31);local listY=left.y+38*s
  local available=math.max(1,math.floor((left.h-48*s)/rowH));local first=1
  if cursor>available then first=math.min(math.max(1,#entries-available+1),cursor-math.floor(available/2)) end
  if #entries==0 then
    text(g,"NO OWNED POKéMON AVAILABLE",left.x+lp,listY+8*s,clamp(8*s,7,10),C.dim,"left",left.w-lp*2)
  else
    for n=0,available-1 do
      local i=first+n;local entry=entries[i];if not entry then break end
      local yy=listY+n*rowH;local focused=i==cursor
      if focused then set(g,C.gold,.16);rr(g,"fill",left.x+lp,yy,left.w-lp*2,rowH-2*s,4*s) end
      local mon=entry.mon or {};local label=tostring(entry.label or speciesName(state.game,mon))
      text(g,label,left.x+lp+4*s,yy+3*s,clamp(8*s,7,10),focused and C.ink or C.muted,"left",left.w-lp*2-80*s)
      text(g,"Lv."..tostring(mon.level or "--"),left.x+lp+4*s,yy+14*s,clamp(7*s,6,8),C.dim)
      local amount=tostring((xp.allocated and xp.allocated[i]) or 0)
      text(g,amount,left.x+left.w-lp-4*s-textWidth(amount,8*s),yy+6*s,clamp(8*s,7,10),focused and C.gold or C.dim)
    end
  end

  panel(g,right,true);local rp=clamp(14*s,10,18)
  text(g,"BANK",right.x+rp,right.y+11*s,clamp(10*s,8,13),C.dim)
  text(g,tostring(math.floor(total)),right.x+rp,right.y+30*s,clamp(22*s,16,30),C.gold)
  local budget="ALLOCATED "..tostring(math.floor(allocated)).."    REMAINING "..tostring(math.floor(remaining))
  text(g,budget,right.x+rp,right.y+58*s,clamp(8*s,7,10),C.muted,"left",right.w-rp*2)
  sectionRule(g,right.x+rp,right.y+76*s,right.w-rp*2)
  local entry=cursor>0 and entries[cursor] or nil
  if entry then
    local mon=entry.mon or {};local y=right.y+89*s
    text(g,speciesName(state.game,mon):upper(),right.x+rp,y,clamp(15*s,11,19),C.ink);y=y+25*s
    local preview
    if xp and type(xp.preview)=="function" then local okp,p=pcall(xp.preview,xp,cursor);if okp then preview=p end end
    local amount=(xp.allocated and xp.allocated[cursor]) or 0
    text(g,"ALLOCATION",right.x+rp,y,clamp(8*s,7,10),C.dim);y=y+16*s
    text(g,tostring(math.floor(amount)).." XP",right.x+rp,y,clamp(18*s,14,23),C.gold);y=y+29*s
    if preview then
      text(g,"LEVEL PREVIEW",right.x+rp,y,clamp(8*s,7,10),C.dim);y=y+15*s
      text(g,"Lv."..tostring(preview.fromLevel or mon.level or "--").."  →  Lv."..tostring(preview.toLevel or mon.level or "--"),
        right.x+rp,y,clamp(13*s,10,17),(preview.toLevel or 0)>(preview.fromLevel or 0) and C.green or C.muted)
    end
  else
    text(g,"No recipient is available. START will close the run without an XP award.",right.x+rp,right.y+94*s,
      clamp(8*s,7,10),C.muted,"left",right.w-rp*2)
  end
  if state.message then
    text(g,tostring(state.message),right.x+rp,right.y+right.h-28*s,clamp(8*s,7,10),C.red,"left",right.w-rp*2)
  end

  set(g,C.panelStrong,.96);rr(g,"fill",footer.x,footer.y,footer.w,footer.h,5*s)
  local controls="↑↓ RECIPIENT   ←→ +/-"..tostring(xpAllocationStep(xp)).."   A ADD REMAINDER   START CONFIRM   B BACK"
  text(g,controls,footer.x+12*s,footer.y+11*s,clamp(7.5*s,6.5,9.5),C.muted,"left",footer.w-24*s)
  g.pop()
end

local function drawFinaleComplete(state,viewport)
  if Mobile and Mobile.active(viewport) then
    local m=state.model or {};local rows={}
    for i,row in ipairs(m.applied or {}) do
      rows[i]={label=row.label or ("POKEMON "..i),meta="LV."..tostring(row.fromLevel or "--").." -> LV."..tostring(row.toLevel or "--"),detail="XP reward delivered and saved."}
    end
    return Mobile.draw(state,viewport,{title="CHALLENGE COMPLETE",subtitle="CLEAR RECORD SAVED",section="XP RESULTS",rows=rows,
      cursor=state.mobileInfoCursor or 1,team=false,focusedList=true,twoLineRows=true,
      detail=#rows==0 and "No XP recipients. Your clear record is saved." or nil,
      hints={"A / START Return to overworld","UP/DOWN Results   SELECT Records"}})
  end
  local g=gfx();if not g then return end
  local sx,sy,sw,sh=safeArea(viewport);local L=challengeLayout(sw,sh,sx,sy);local s=L.s
  local m=state.model or {};local applied=m.applied or {};local total=climbLengthFor(state.game,m.totalFights)
  g.push("all");g.origin();g.setShader();g.setLineWidth(1);set(g,{0,0,0,.14});g.rectangle("fill",sx,sy,sw,sh)
  local r=L.left;panel(g,r,true);challengeTab(g,r,"MT. BATTLE "..tostring(total),s);local pad=clamp(14*s,11,18)
  text(g,"CHALLENGE COMPLETE",r.x+pad,r.y+14*s,clamp(16*s,13,21),C.ink)
  text(g,#applied>0 and "XP REWARDS DELIVERED" or "CLEAR RECORD SAVED",r.x+pad,r.y+38*s,clamp(9*s,8,11),C.gold)
  sectionRule(g,r.x+pad,r.y+57*s,r.w-pad*2)
  text(g,"Your Battle "..tostring(total).." result and lifetime records are now saved.",r.x+pad,r.y+72*s,
    clamp(9*s,8,11),C.muted,"left",r.w-pad*2)
  local actionH=clamp(50*s,42,60);local ay=r.y+r.h-pad-actionH
  set(g,C.green,.16);rr(g,"fill",r.x+pad,ay,r.w-pad*2,actionH,6*s);set(g,C.green,.85);rr(g,"line",r.x+pad+.5,ay+.5,r.w-pad*2-1,actionH-1,6*s)
  text(g,"A  RETURN TO OVERWORLD",r.x+pad+12*s,ay+11*s,clamp(10*s,8.5,13),C.green)
  text(g,"SELECT  BATTLE RECORDS",r.x+pad+12*s,ay+30*s,clamp(8*s,7,10),C.dim)

  local q=L.right;panel(g,q,true);local qp=clamp(12*s,9,15)
  text(g,"XP RESULTS",q.x+qp,q.y+11*s,clamp(12*s,10,15),C.ink);sectionRule(g,q.x+qp,q.y+31*s,q.w-qp*2)
  local y=q.y+43*s
  if #applied==0 then
    text(g,"NO XP RECIPIENTS",q.x+qp,y,clamp(9*s,8,11),C.dim)
  else
    local rh=clamp(27*s,23,34)
    for i=1,math.min(#applied,8) do
      local row=applied[i] or {}
      if i%2==0 then set(g,C.panelSoft,.24);rr(g,"fill",q.x+qp,y,q.w-qp*2,rh-2*s,0) end
      text(g,tostring(row.label or ("POKéMON "..i)),q.x+qp+3*s,y+3*s,clamp(7.5*s,6.5,9),C.muted,"left",q.w-qp*2)
      text(g,"Lv."..tostring(row.fromLevel or "--").." → Lv."..tostring(row.toLevel or "--"),q.x+qp+3*s,y+15*s,
        clamp(8*s,7,10),(row.toLevel or 0)>(row.fromLevel or 0) and C.green or C.dim)
      y=y+rh
    end
  end
  g.pop()
end

HSc._test.xpAllocationStep=xpAllocationStep

local function topState(game)
  local stack=game and game.stack
  if stack and type(stack.top)=="function" then
    local ok,state=pcall(stack.top,stack)
    if ok then return state end
  end
  local states=stack and stack.states
  return type(states)=="table" and states[#states] or nil
end

local function renderHubBackdrop()
  local host=V.StandaloneHost
  if not (host and type(host.renderHubFrame)=="function") then return false end
  local ok,value=pcall(host.renderHubFrame)
  return ok and value~=false and value~=nil
end

safeHubDraw=function(state,drawFn,viewport)
  local g=gfx();local depth
  if g and type(g.getStackDepth)=="function" and type(g.push)=="function" and type(g.pop)=="function" then
    depth=g.getStackDepth();g.push("all")
  end
  local ok,result=pcall(drawFn,state,viewport)
  -- A draw can raise after push("all"). Catching only the Lua exception leaks
  -- its graphics stack every frame, eventually corrupting the next UI/camera.
  if depth then
    while g.getStackDepth()>depth do g.pop() end
  end
  if not ok then
    local message=tostring(result)
    state.__cbeHubDrawError=message
    if state.__cbeLastLoggedDrawError~=message then
      state.__cbeLastLoggedDrawError=message
      local log=V.mod and V.mod.log
      if log and type(log.warn)=="function" then pcall(log.warn,log,"UI CAMERA AUDIT 1 / Mt. Battle draw: %s",message) end
    end
    return nil,message
  end
  state.__cbeHubDrawError=nil
  return result
end
HSc._test.safeHubDraw=safeHubDraw

stateCanvasDraw=function(state,drawFn)
  -- This draw occurs before Renderer:endFrame, which is exactly where the
  -- non-battle Summit session must submit its worldOverride. Chrome itself is
  -- deferred to render.hud so it uses the completed viewport's coordinates.
  if not (state and state.__cbeMtBattleGen2Wide==true) then renderHubBackdrop() end
  if not HSc._hudHookInstalled then return safeHubDraw(state,drawFn,nil) end
end

ensureHudHook=function()
  if HSc._hudHookInstalled then return true end
  local mod=V.mod
  local hooks=mod and mod.hooks
  if not (hooks and type(hooks.wrap)=="function") then return false end
  if HSc._hudHookAttempted then return false end
  HSc._hudHookAttempted=true
  hooks:wrap("render.hud",function(next,game,viewport)
    local out=next(game,viewport)
    local state=topState(game)
    local draw=state and state.__cbeMtBattleHubDraw
    if state and state.__cbeMtBattleHubSurface==true and type(draw)=="function" then
      -- Fail open: a presentation-only drawing fault must never trap the player
      -- inside Battle 100 or prevent the native menu input from progressing.
      safeHubDraw(state,draw,viewport)
    end
    return out
  end,22000)
  HSc._hudHookInstalled=true
  return true
end
HSc.install=ensureHudHook
HSc._test.topState=topState
HSc._test.renderHubBackdrop=renderHubBackdrop

-- ===== Team Select selection state (real, pure, testable) =====

local TeamSelectState={}
TeamSelectState.__index=TeamSelectState
HSc.TeamSelectState=TeamSelectState

HSc.MAX_TEAM=6
HSc.RENTAL_PAGE_JUMP=8

local function rentalCandidateGeneration(candidate)
  local generation=tonumber(candidate and candidate.generation)
  if generation==1 or generation==2 or generation==3 then return generation end
  local dex=tonumber(candidate and candidate.dex)
  if not dex then return nil end
  if dex>=1 and dex<=151 then return 1 end
  if dex<=251 then return 2 end
  if dex<=386 then return 3 end
  return nil
end

local function candidateCategory(candidate)
  if candidate and candidate.source=="rental" then return rentalCandidateGeneration(candidate) end
  if candidate and (candidate.source=="party" or candidate.source=="pc") then return "owned" end
  return nil
end

-- candidates: array of {source="party"|"pc"|"rental", index=/box=,slot=, species=,
--   level=, ...display fields...} -- eligible party+PC Pokemon, already
--   resolved by the caller (this module has no save/PC access of its own).
function TeamSelectState.new(candidates)
  candidates=candidates or {}
  local self=setmetatable({candidates=candidates,selected={},cursor=1},TeamSelectState)
  local buckets={owned={},[1]={},[2]={},[3]={}}
  local hasRental=false
  for i,candidate in ipairs(candidates) do
    local category=candidateCategory(candidate)
    if candidate.source=="rental" and type(category)=="number" then hasRental=true end
    if category and buckets[category] then buckets[category][#buckets[category]+1]=i end
  end
  -- Rental/team-builder categories are presentation/navigation only. The final
  -- selection remains one global six, so owned Pokemon and rentals can be mixed
  -- freely without changing RunController's durable rosterSource contract.
  if hasRental then
    local categories={}
    local positions={}
    if #buckets.owned>0 then
      categories[#categories+1]="owned"
      for position,index in ipairs(buckets.owned) do positions[index]=position end
    end
    for generation=1,3 do
      if #buckets[generation]>0 then
        categories[#categories+1]=generation
        for position,index in ipairs(buckets[generation]) do positions[index]=position end
      end
    end
    if #categories>0 then
      self.rentalCategories=categories
      self.rentalIndices=buckets
      self.rentalPositions=positions
      self.categoryIndex=1
      self.categoryCursors={}
      self.cursor=buckets[categories[1]][1] or 1
    end
  end
  return self
end

function TeamSelectState:isRentalCatalog()
  return type(self.rentalCategories)=="table" and #self.rentalCategories>0
end

function TeamSelectState:currentGeneration()
  if not self:isRentalCatalog() then return nil end
  local category=self.rentalCategories[self.categoryIndex or 1]
  return type(category)=="number" and category or nil
end

function TeamSelectState:currentCategory()
  if not self:isRentalCatalog() then return nil end
  return self.rentalCategories[self.categoryIndex or 1]
end

function TeamSelectState:categoryCandidateIndices()
  local category=self:currentCategory()
  return category and self.rentalIndices[category] or nil
end

function TeamSelectState:categoryCursorPosition()
  if not self:isRentalCatalog() then return self.cursor end
  return (self.rentalPositions and self.rentalPositions[self.cursor]) or 1
end

function TeamSelectState:moveCursor(delta)
  delta=math.floor(tonumber(delta) or 0)
  if delta==0 then return self.cursor end
  if not self:isRentalCatalog() then
    self.cursor=math.max(1,math.min(#self.candidates,self.cursor+delta))
    return self.cursor
  end
  local indices=self:categoryCandidateIndices() or {}
  if #indices==0 then return self.cursor end
  local position=math.max(1,math.min(#indices,self:categoryCursorPosition()+delta))
  self.cursor=indices[position]
  -- Mixed team building adds an OWNED tab beside the numeric rental-generation
  -- tabs. currentGeneration() deliberately returns nil for OWNED, so using it
  -- as the cursor-memory key raises "table index is nil" as soon as the player
  -- moves within that tab. Cursor memory is category-scoped, not generation-
  -- scoped: use the exact category token ("owned", 1, 2 or 3), matching
  -- cycleGeneration() below.
  local category=self:currentCategory()
  if category~=nil then self.categoryCursors[category]=self.cursor end
  return self.cursor
end

function TeamSelectState:pageCursor(direction,pageSize)
  direction=tonumber(direction) or 0
  if direction==0 then return self.cursor end
  pageSize=math.max(1,math.floor(tonumber(pageSize) or HSc.RENTAL_PAGE_JUMP))
  return self:moveCursor((direction<0 and -1 or 1)*pageSize)
end

function TeamSelectState:cycleGeneration(direction)
  if not self:isRentalCatalog() then return false end
  local categories=self.rentalCategories
  local current=self:currentCategory()
  -- Defensive for mixed OWNED + rental navigation. OWNED is a category token,
  -- not a numeric generation, and interrupted/legacy state can also arrive with
  -- a missing cursor-memory table. Never allow a UI tab switch to become a
  -- table[nil] write or nil arithmetic crash.
  self.categoryCursors=self.categoryCursors or {}
  if current~=nil then self.categoryCursors[current]=self.cursor end
  local step=(tonumber(direction) or 1)<0 and -1 or 1
  self.categoryIndex=((math.max(1,tonumber(self.categoryIndex) or 1)-1+step)%#categories)+1
  local category=self:currentCategory()
  local indices=(self.rentalIndices and category~=nil and self.rentalIndices[category]) or {}
  if #indices==0 then return false end
  local remembered=self.categoryCursors[category]
  self.cursor=(remembered and self.rentalPositions[remembered] and remembered) or indices[1]
  return true
end

function TeamSelectState:isMixedCatalog()
  return self:isRentalCatalog() and self.rentalIndices and #(self.rentalIndices.owned or {})>0
end

function TeamSelectState:selectedCount()
  local n=0
  for _ in pairs(self.selected) do n=n+1 end
  return n
end

function TeamSelectState:isSelected(i) return self.selected[i]==true end

-- Toggles candidate `i`. Selecting past MAX_TEAM is refused (returns
-- false, nothing changes) rather than silently evicting an earlier pick
-- -- the player deselects something first, an explicit action.
function TeamSelectState:toggle(i)
  if not self.candidates[i] then return false end
  if self.candidates[i].selectable==false then return false end
  if self.selected[i] then self.selected[i]=nil;return true end
  if self:selectedCount()>=HSc.MAX_TEAM then return false end
  self.selected[i]=true
  return true
end

function TeamSelectState:isValid()
  return self:selectedCount()==HSc.MAX_TEAM
end

-- Extracts the {source=,index=}/{source=,box=,slot=} rows for
-- RunController.beginChallenge, in SELECTION ORDER (the order the player
-- picked them, not candidate-list order -- matters for e.g. lead-mon
-- conventions later, even though nothing in this pass depends on it yet).
function TeamSelectState:rosterSource()
  if not self:isValid() then return nil,"team is not exactly 6" end
  local order={}
  for i in pairs(self.selected) do order[#order+1]=i end
  table.sort(order,function(a,b) return (self.pickOrder and self.pickOrder[a] or a)<(self.pickOrder and self.pickOrder[b] or b) end)
  local rows={}
  for _,i in ipairs(order) do
    local c=self.candidates[i]
    if c.source=="pc" then
      rows[#rows+1]={source="pc",box=c.box,slot=c.slot,species=c.species}
    elseif c.source=="rental" then
      local moves={}
      for n,mv in ipairs(c.moves or {}) do
        moves[n]={id=mv.id,pp=mv.pp,ppUps=mv.ppUps,maxPp=mv.maxPp,maxPP=mv.maxPP}
      end
      -- RentalPool may carry retail-only mechanics for identities that do not
      -- exist in the host's native species table. Preserve that compact scalar
      -- payload through the UI boundary so LevelClone can build the locked
      -- challenge copy without re-querying/mutating game.data. Copy nested rows
      -- rather than retaining catalogue references: rosterSource is durable run
      -- input and must not change if a later browsing/cache object is reused.
      local stats=c.sourceBaseStats and {
        hp=c.sourceBaseStats.hp,attack=c.sourceBaseStats.attack,defense=c.sourceBaseStats.defense,
        speed=c.sourceBaseStats.speed,specialAttack=c.sourceBaseStats.specialAttack,
        specialDefense=c.sourceBaseStats.specialDefense,
      } or nil
      local types=c.sourceTypeIds and {c.sourceTypeIds[1],c.sourceTypeIds[2]} or nil
      rows[#rows+1]={
        source="rental",index=c.index,species=c.species,moves=moves,
        dex=c.dex,generation=c.generation,sourceBacked=c.sourceBacked,
        sourceMechanics=c.sourceMechanics,sourceBaseStats=stats,sourceTypeIds=types,
        unresolvedMoveCount=c.unresolvedMoveCount,
      }
    else
      rows[#rows+1]={source="party",index=c.index,species=c.species}
    end
  end
  return rows
end

-- Wraps toggle() to also record pick order (first selected = order 1),
-- so rosterSource() reflects the player's actual pick sequence.
function TeamSelectState:toggleTracked(i)
  local wasSelected=self:isSelected(i)
  local ok=self:toggle(i)
  if ok and not wasSelected then
    self.pickOrder=self.pickOrder or {}
    self.nextOrder=(self.nextOrder or 0)+1
    self.pickOrder[i]=self.nextOrder
  end
  return ok
end

-- Builds a game.stack-pushable screen. `onConfirm(rosterSource)` fires
-- when the player confirms exactly 6; `onCancel()` fires on back-out.
function HSc.pushTeamSelect(game,candidates,onConfirm,onCancel,totalFights)
  local model=TeamSelectState.new(candidates)
  local state=hubSurface({game=game,model=model,totalFights=normalizedClimbLength(totalFights or 100)})
  state.__cbeMtBattleHubDraw=drawTeamSelect
  function state:update()
    local input=self.game.input
    if not input then return end
    -- Input:wasPressed is a colon method (src/core/Input.lua:458) -- must
    -- be called via `input:wasPressed(...)`, not `input.wasPressed(...)`;
    -- the dot form silently binds the button-name string as `self` and
    -- drops the real key argument, so it would never actually fire
    -- against the real engine Input object (only worked in earlier tests
    -- because the test stub happened to accept a single bare argument).
    if input.wasPressed and input:wasPressed("down") then
      self.model:moveCursor(1)
    elseif input.wasPressed and input:wasPressed("up") then
      self.model:moveCursor(-1)
    elseif self.model:isRentalCatalog() and input.wasPressed and input:wasPressed("left") then
      self.model:pageCursor(-1)
    elseif self.model:isRentalCatalog() and input.wasPressed and input:wasPressed("right") then
      self.model:pageCursor(1)
    elseif self.model:isRentalCatalog() and input.wasPressed and input:wasPressed("select") then
      self.model:cycleGeneration(1)
    elseif input.wasPressed and input:wasPressed("a") then
      self.model:toggleTracked(self.model.cursor)
    elseif input.wasPressed and input:wasPressed("start") then
      if self.model:isValid() then
        local rows=self.model:rosterSource()
        self.game.stack:pop()
        if onConfirm then onConfirm(rows) end
      end
    elseif input.wasPressed and input:wasPressed("b") then
      self.game.stack:pop()
      if onCancel then onCancel() end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawTeamSelect) end
  game.stack:push(state)
  return state
end

-- ===== Rules / Challenge Bag review: plain confirm-to-continue screens =====

function HSc.pushClimbSetup(game,opts)
  opts=opts or {}
  local initial=normalizedClimbLength(opts.totalFights or 100)
  local formatIndex=#HSc.CLIMB_FORMATS
  for i,n in ipairs(HSc.CLIMB_FORMATS) do if n==initial then formatIndex=i;break end end
  local state=hubSurface({game=game,kind="climbSetup",cursor=1,formatIndex=formatIndex,generationPreference="all"})
  state.__cbeMtBattleHubDraw=drawClimbSetup
  local function closeSelf()
    if state.game.stack and state.game.stack.top and state.game.stack:top()==state then state.game.stack:pop() end
  end
  function state:selectedFormat() return HSc.CLIMB_FORMATS[self.formatIndex] or 100 end
  function state:selectedGenerationPreference() return "all" end
  function state:update()
    local input=self.game and self.game.input;if not (input and input.wasPressed) then return end
    if self.activeSubscreen=="format" then
      local draft=self.formatDraftIndex or self.formatIndex or #HSc.CLIMB_FORMATS
      if input:wasPressed("up") or input:wasPressed("left") then
        self.formatDraftIndex=draft>1 and draft-1 or #HSc.CLIMB_FORMATS
      elseif input:wasPressed("down") or input:wasPressed("right") then
        self.formatDraftIndex=draft<#HSc.CLIMB_FORMATS and draft+1 or 1
      elseif input:wasPressed("a") or input:wasPressed("start") then
        self.formatIndex=self.formatDraftIndex or self.formatIndex
        self.formatDraftIndex=nil;self.activeSubscreen=nil
        if opts.onFormatChanged then opts.onFormatChanged(self:selectedFormat()) end
      elseif input:wasPressed("b") then
        self.formatDraftIndex=nil;self.activeSubscreen=nil
      end
      return
    end
    if input:wasPressed("up") then
      self.cursor=self.cursor>1 and self.cursor-1 or #CLIMB_ACTIONS
    elseif input:wasPressed("down") then
      self.cursor=self.cursor<#CLIMB_ACTIONS and self.cursor+1 or 1
    elseif input:wasPressed("start") then
      local ok=true
      if opts.onSave then ok=opts.onSave() end
      self.message=ok==false and "SAVE FAILED" or "GAME SAVED"
    elseif input:wasPressed("select") then
      HSc.pushHallOfFame(self.game)
    elseif input:wasPressed("a") then
      local label=CLIMB_ACTIONS[self.cursor]
      if label=="FORMAT" then
        self.activeSubscreen="format";self.formatDraftIndex=self.formatIndex
      elseif label=="OPTIONS" then
        HSc.pushOptions(self.game,{onSave=opts.onSave})
      elseif label=="RULESETS" then HSc.pushRulesets(self.game,self:selectedFormat())
      elseif label=="HALL OF FAME" then HSc.pushHallOfFame(self.game)
      elseif label=="BP REWARDS" then HSc.pushBPScreen(self.game)
      elseif label=="TEAM SETUP" then
        local total=self:selectedFormat()
        closeSelf()
        if opts.onTeamSetup then opts.onTeamSetup(total,"all") end
      end
    elseif input:wasPressed("b") then
      closeSelf()
      if opts.onCancel then opts.onCancel() end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawClimbSetup) end
  game.stack:push(state)
  return state
end

function HSc.pushOptions(game,opts)
  opts=opts or {}
  local state=hubSurface({game=game,kind="options",generationPreference="all",cursor=1,message=nil})
  state.__cbeMtBattleHubDraw=drawGenerationOptions
  function state:update()
    local input=self.game and self.game.input
    if not (input and input.wasPressed) then return end
    if input:wasPressed("up") then
      self.cursor=self.cursor>1 and self.cursor-1 or #OPTION_ROWS
      self.message=nil
    elseif input:wasPressed("down") then
      self.cursor=self.cursor<#OPTION_ROWS and self.cursor+1 or 1
      self.message=nil
    elseif input:wasPressed("a") or input:wasPressed("left") or input:wasPressed("right") then
      local row=OPTION_ROWS[self.cursor or 1]
      toggleOption(self.game,row)
      self.message=row and (row.label.."  "..optionValue(self.game,row)) or nil
    elseif input:wasPressed("start") then
      local ok=true
      if opts.onSave then ok=opts.onSave() end
      self.message=ok==false and "SAVE FAILED" or "GAME SAVED"
    elseif input:wasPressed("b") or input:wasPressed("select") then
      if self.game.stack and self.game.stack.top and self.game.stack:top()==self then self.game.stack:pop() end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawGenerationOptions) end
  game.stack:push(state)
  return state
end

-- Compatibility wrapper for callers from the generation-filter prototype. It
-- opens the real presentation/options screen but still reports the permanently
-- fixed all-generations challenge policy when the caller returns.
function HSc.pushGenerationOptions(game,initial,onConfirm)
  local state=HSc.pushOptions(game,{})
  state.generationPreference="all"
  state.compatOnReturn=onConfirm
  local original=state.update
  function state:update()
    local wasTop=self.game.stack and self.game.stack.top and self.game.stack:top()==self
    original(self)
    if wasTop and self.game.stack and self.game.stack.top and self.game.stack:top()~=self and self.compatOnReturn then
      local cb=self.compatOnReturn;self.compatOnReturn=nil;cb("all")
    end
  end
  return state
end
HSc.pushOptionsTBA=HSc.pushOptions

function HSc.pushRulesets(game,totalFights)
  local state=hubSurface({game=game,kind="rulesets",totalFights=normalizedClimbLength(totalFights),cursor=1})
  state.__cbeMtBattleHubDraw=drawRulesets
  function state:update()
    local input=self.game and self.game.input;if not (input and input.wasPressed) then return end
    if input:wasPressed("up") then self.cursor=self.cursor>1 and self.cursor-1 or #RULESET_ROWS
    elseif input:wasPressed("down") then self.cursor=self.cursor<#RULESET_ROWS and self.cursor+1 or 1
    elseif input:wasPressed("left") then self.cursor=math.max(1,(self.cursor or 1)-4)
    elseif input:wasPressed("right") then self.cursor=math.min(#RULESET_ROWS,(self.cursor or 1)+4)
    elseif input:wasPressed("b") or input:wasPressed("select") then
      if self.game.stack and self.game.stack.top and self.game.stack:top()==self then self.game.stack:pop() end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawRulesets) end
  game.stack:push(state)
  return state
end

-- `opts` (optional): {kind=, content=} -- identifies WHICH info screen this
-- is ("rules"/"bagReview"/...) and carries the real data it's showing
-- (e.g. the Challenge Bag's starting contents), so a future real-draw
-- pass has something to render and tests can assert the right content
-- reached the right screen -- draw() itself stays a placeholder either
-- way, per this module's header note.
function HSc.pushInfoScreen(game,onDone,opts)
  opts=opts or {}
  local state=hubSurface({game=game,kind=opts.kind,content=opts.content,onRental=opts.onRental,
    totalFights=opts.totalFights and normalizedClimbLength(opts.totalFights) or nil})
  state.__cbeMtBattleHubDraw=drawInfoState
  function state:update()
    local input=self.game.input
    if input and input.wasPressed and Mobile and Mobile.active() and input:wasPressed("up") then
      self.mobileInfoCursor=math.max(1,(self.mobileInfoCursor or 1)-1)
    elseif input and input.wasPressed and Mobile and Mobile.active() and input:wasPressed("down") then
      self.mobileInfoCursor=math.min(self.__cbeMobileInfoCount or 5,(self.mobileInfoCursor or 1)+1)
    elseif input and input.wasPressed and self.onRental and input:wasPressed("select") then
      local owner=self
      self.onRental(function()
        if owner.game.stack and owner.game.stack:top()==owner then owner.game.stack:pop() end
      end)
    elseif input and input.wasPressed and (input:wasPressed("a") or input:wasPressed("b")) then
      self.game.stack:pop()
      if onDone then onDone() end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawInfoState) end
  game.stack:push(state)
  return state
end

-- Challenge-local move editor for the current six. Selection is written only to
-- `prepared`; the live party and inventory remain untouched until the challenge
-- snapshot consumes the override. This keeps Mt. Battle prep reversible while
-- still exposing every source-resolved Lv.100 learnset move and compatible TM/HM.
function HSc.pushMovePrep(game,prepared,onDone)
  if not (MovePrep and type(MovePrep.pool)=="function" and type(MovePrep.currentSelection)=="function") then
    return nil,"move prep unavailable"
  end
  prepared=prepared or {}
  local state=hubSurface({game=game,kind="movePrep",prepared=prepared,phase="team",teamCursor=1,moveCursor=1,message=nil})
  state.__cbeMtBattleHubDraw=drawMovePrep
  local function openSlot(self)
    local party=(MovePrep and type(MovePrep.team)=="function" and MovePrep.team(self.game,self.prepared))
      or (self.game and self.game.save and self.game.save.party) or {}
    local mon=party[self.teamCursor]
    if not mon then self.message="TEAM SLOT UNAVAILABLE";return end
    self.pool,self.poolDiagnostics=MovePrep.pool(self.game,mon)
    local diag=self.poolDiagnostics
    if diag and (tonumber(diag.unresolved) or 0)>0 then
      self.poolDiagnosticMessage=("%d SOURCE MOVE%s UNAVAILABLE IN THIS HOST"):format(diag.unresolved,diag.unresolved==1 and "" or "S")
    elseif diag and diag.failedClosed and diag.error then
      self.poolDiagnosticMessage="SOURCE MOVE DATA UNAVAILABLE - NATIVE FALLBACK"
    else self.poolDiagnosticMessage=nil end
    self.workingMoves=MovePrep.currentSelection(self.game,mon,self.prepared[self.teamCursor])
    self.moveCursor=1;self.phase="moves";self.message=nil
  end
  function state:update()
    local input=self.game and self.game.input
    if not (input and input.wasPressed) then return end
    if self.phase=="team" then
      if input:wasPressed("up") then self.teamCursor=self.teamCursor>1 and self.teamCursor-1 or 6
      elseif input:wasPressed("down") then self.teamCursor=self.teamCursor<6 and self.teamCursor+1 or 1
      elseif input:wasPressed("a") then openSlot(self)
      elseif input:wasPressed("b") then
        if self.game.stack and self.game.stack:top()==self then self.game.stack:pop() end
        if onDone then onDone(self.prepared) end
      end
      return
    end

    local pool=self.pool or {}
    if Mobile and Mobile.active() and (input:wasPressed("left") or input:wasPressed("right")) then
      local step=self.__cbeMobileLayout and self.__cbeMobileLayout.visible or 8
      self.moveCursor=clamp((self.moveCursor or 1)+(input:wasPressed("left") and -step or step),1,math.max(1,#pool))
    elseif input:wasPressed("up") then
      self.moveCursor=self.moveCursor>1 and self.moveCursor-1 or math.max(1,#pool)
    elseif input:wasPressed("down") then
      self.moveCursor=self.moveCursor<#pool and self.moveCursor+1 or 1
    elseif input:wasPressed("a") then
      local row=pool[self.moveCursor]
      if not row then return end
      local at
      for i,mv in ipairs(self.workingMoves or {}) do if mv.id==row.id then at=i;break end end
      if at then
        if #self.workingMoves<=1 then self.message="AT LEAST ONE MOVE IS REQUIRED"
        else table.remove(self.workingMoves,at);self.message=nil end
      elseif #self.workingMoves>=4 then self.message="FOUR MOVES ALREADY SELECTED"
      else self.workingMoves[#self.workingMoves+1]={id=row.id};self.message=nil end
    elseif input:wasPressed("start") then
      local nextPrepared,ok,why=MovePrep.store(self.game,self.prepared,self.teamCursor,self.workingMoves)
      self.prepared=nextPrepared or self.prepared
      if ok then self.phase="team";self.pool=nil;self.poolDiagnostics=nil;self.poolDiagnosticMessage=nil;self.workingMoves=nil;self.message=nil
      else self.message=tostring(why or "MOVE PREP COULD NOT BE SAVED") end
    elseif input:wasPressed("b") then
      self.phase="team";self.pool=nil;self.poolDiagnostics=nil;self.poolDiagnosticMessage=nil;self.workingMoves=nil;self.message=nil
    end
  end
  function state:draw() return stateCanvasDraw(self,drawMovePrep) end
  game.stack:push(state)
  return state
end

-- ===== Saved custom teams ====================================================
-- A deliberately small native-list controller over SaveState's permanent
-- mod-owned sidecar. It never edits party/PC Pokemon: SAVE serializes the exact
-- prepared challenge six supplied by EntryFlow, LOAD selects detached rows for
-- the setup session, and DELETE removes only that sidecar entry.
local function customTeamMessage(game,message)
  local ok,TextBox=pcall(req,"src.render.TextBox")
  if ok and TextBox and type(TextBox.new)=="function" and game and game.stack then
    game.stack:push(TextBox.new(game,"MT. BATTLE\n\n"..tostring(message or "CUSTOM TEAM ACTION FAILED")))
  end
end

local function drawCustomTeamsMobile(state,viewport)
  if not (Mobile and Mobile.active(viewport)) then return end
  local rows={}
  for i,item in ipairs(state.items or {}) do
    rows[i]={label=item.label or "TEAM",detail=state.kind=="customTeamActions" and
      "Load or delete this saved challenge team. Your party and PC are unchanged." or "Save the prepared six, or open a saved challenge team."}
  end
  return Mobile.draw(state,viewport,{title=state.kind=="customTeamActions" and "SAVED TEAM" or "CUSTOM TEAMS",
    subtitle="CHALLENGE COPIES ONLY",rows=rows,cursor=state.index or 1,team=false,focusedList=true,
    hints={"UP/DOWN Browse   A Select","B Back"}})
end
local function customTeamMobileChrome(menu)
  menu.__cbeMtBattleHubDraw=drawCustomTeamsMobile
  local original=menu.draw
  menu.draw=function(self,...)
    if Mobile and Mobile.active() then return stateCanvasDraw(self,drawCustomTeamsMobile) end
    if original then return original(self,...) end
  end
end

function HSc.pushCustomTeams(game,opts)
  opts=opts or {}
  local function rows()
    local value=type(opts.teams)=="function" and opts.teams() or opts.teams
    return type(value)=="table" and value or {}
  end
  local menu
  local function closeMenu(target)
    if target and target.game and target.game.stack and target.game.stack.top
        and target.game.stack:top()==target then target.game.stack:pop();return true end
    return false
  end
  local function refresh()
    closeMenu(menu)
    return HSc.pushCustomTeams(game,opts)
  end
  local items={
    {label="SAVE TEAM",keepOpen=true,onSelect=function()
      local ok,detail=true,nil
      if opts.onSave then ok,detail=opts.onSave() end
      if ok==false or ok==nil then customTeamMessage(game,detail or "TEAM COULD NOT BE SAVED")
      else refresh() end
    end},
  }
  for position,entry in ipairs(rows()) do
    local selected=entry
    local label=("%02d  %s"):format(tonumber(selected.id) or position,tostring(selected.name or ("TEAM "..tostring(selected.id or position))))
    items[#items+1]={label=label,keepOpen=true,onSelect=function()
      local action
      local actionItems={
        {label="LOAD TEAM",keepOpen=true,onSelect=function()
          local ok,detail=true,nil
          if opts.onLoad then ok,detail=opts.onLoad(selected.id) end
          if ok==false or ok==nil then customTeamMessage(game,detail or "TEAM COULD NOT BE LOADED");return end
          closeMenu(action);closeMenu(menu)
        end},
        {label="DELETE TEAM",keepOpen=true,onSelect=function()
          local ok,detail=true,nil
          if opts.onDelete then ok,detail=opts.onDelete(selected.id) end
          if ok==false or ok==nil then customTeamMessage(game,detail or "TEAM COULD NOT BE DELETED");return end
          closeMenu(action);refresh()
        end},
        {label="BACK"},
      }
      action=Menu.new(game,actionItems,{tx=2,ty=2,noSound=true})
      action.kind="customTeamActions";action.customTeamId=selected.id
      hubSurface(action);customTeamMobileChrome(action);game.stack:push(action)
    end}
  end
  items[#items+1]={label="BACK",onSelect=function() if opts.onCancel then opts.onCancel() end end}
  menu=Menu.new(game,items,{tx=2,ty=2,maxVisible=8,noSound=true,onCancel=opts.onCancel})
  menu.kind="customTeams"
  hubSurface(menu);customTeamMobileChrome(menu);game.stack:push(menu)
  return menu
end

-- ===== BEGIN CHALLENGE confirmation =====

function HSc.pushBeginConfirm(game,onBegin,onCancel,totalFights)
  local state=hubSurface({game=game,confirmed=false,totalFights=normalizedClimbLength(totalFights or 100)})
  state.__cbeMtBattleHubDraw=drawBeginConfirm
  function state:update()
    local input=self.game.input
    if not input then return end
    if input.wasPressed and input:wasPressed("a") then
      self.game.stack:pop()
      if onBegin then onBegin() end
    elseif input.wasPressed and input:wasPressed("b") then
      self.game.stack:pop()
      if onCancel then onCancel() end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawBeginConfirm) end
  game.stack:push(state)
  return state
end

function HSc.pushFightBriefing(game,encounter,onStart,onSuspend)
  local state=hubSurface({game=game,encounter=encounter or {},kind="fightBriefing",resolved=false})
  state.__cbeMtBattleHubDraw=drawFightBriefing
  function state:update()
    if mobileBrowseStatus(self) then return end
    if self.resolved then return end
    local input=self.game and self.game.input
    if not (input and input.wasPressed) then return end
    if input:wasPressed("a") or input:wasPressed("start") then
      self.resolved=true
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then
        self.game.stack:pop()
      end
      if onStart then onStart() end
    elseif input:wasPressed("b") and onSuspend then
      self.resolved=true
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then
        self.game.stack:pop()
      end
      local ok=onSuspend()
      if ok==false then
        self.resolved=false;self.message=tostring(why or "BATTLE COULD NOT START - RETRY")
        if self.game.stack and type(self.game.stack.push)=="function" then self.game.stack:push(self) end
      end
    elseif input:wasPressed("select") then
      HSc.pushBattleRecords(self.game)
    end
  end
  function state:draw() return stateCanvasDraw(self,drawFightBriefing) end
  game.stack:push(state)
  return state
end

function HSc.pushSuspendRunConfirm(game,opts)
  opts=opts or {}
  local state=hubSurface({game=game,kind="suspendRunConfirm",resolved=false,
    fight=opts.fight,totalFights=normalizedClimbLength(opts.totalFights or 100)})
  state.__cbeMtBattleHubDraw=drawSuspendRunConfirm
  function state:update()
    if self.resolved then return end
    local input=self.game and self.game.input
    if not (input and input.wasPressed) then return end
    if input:wasPressed("a") then
      self.resolved=true
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then self.game.stack:pop() end
      local ok,why=true,nil
      if opts.onConfirm then ok,why=opts.onConfirm() end
      if ok==false then
        self.resolved=false;self.message=tostring(why or "SUSPEND FAILED")
        if self.game.stack and type(self.game.stack.push)=="function" then self.game.stack:push(self) end
      end
    elseif input:wasPressed("b") then
      self.resolved=true
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then self.game.stack:pop() end
      if opts.onCancel then opts.onCancel() end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawSuspendRunConfirm) end
  game.stack:push(state)
  return state
end

function HSc.pushActiveRunControl(game,opts)
  opts=opts or {}
  local run=game and game.save and game.save.mtBattleChallenge or {}
  local state=hubSurface({game=game,kind="activeRunControl",cursor=1,resolved=false,
    run=run,fight=run.currentFight,totalFights=normalizedClimbLength(run.totalFights or 100),message=nil})
  state.__cbeMtBattleHubDraw=drawActiveRunControl
  local function popSelf()
    if state.game.stack and type(state.game.stack.top)=="function" and state.game.stack:top()==state then
      state.game.stack:pop()
    end
  end
  local function suspendConfirm()
    HSc.pushSuspendRunConfirm(state.game,{
      fight=run.currentFight,totalFights=run.totalFights,
      onConfirm=function()
        local ok,why=true,nil
        if opts.onSuspend then ok,why=opts.onSuspend() end
        if ok~=false then state.resolved=true;popSelf() end
        return ok,why
      end,
    })
  end
  function state:update()
    if self.resolved then return end
    local input=self.game and self.game.input;if not (input and input.wasPressed) then return end
    if input:wasPressed("up") then self.cursor=self.cursor>1 and self.cursor-1 or #ACTIVE_RUN_ACTIONS;self.message=nil
    elseif input:wasPressed("down") then self.cursor=self.cursor<#ACTIVE_RUN_ACTIONS and self.cursor+1 or 1;self.message=nil
    elseif input:wasPressed("select") then HSc.pushBattleRecords(self.game)
    elseif input:wasPressed("b") then suspendConfirm()
    elseif input:wasPressed("a") then
      local label=ACTIVE_RUN_ACTIONS[self.cursor or 1]
      if label=="RESUME RUN" then
        self.resolved=true;popSelf()
        local ok,why=true,nil;if opts.onResume then ok,why=opts.onResume() end
        if ok==false then
          self.resolved=false;self.message=tostring(why or "RUN COULD NOT RESUME")
          if self.game.stack and type(self.game.stack.push)=="function" then self.game.stack:push(self) end
        end
      elseif label=="SUSPEND & QUIT" then
        suspendConfirm()
      elseif label=="END RUN" then
        HSc.pushEndRunConfirm(self.game,function()
          local ok,why=true,nil;if opts.onEndRun then ok,why=opts.onEndRun() end
          if ok~=false then self.resolved=true;popSelf()
          else self.message=tostring(why or "END RUN FAILED") end
          return ok,why
        end,nil,run.totalFights)
      end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawActiveRunControl) end
  game.stack:push(state)
  return state
end

-- ===== Battle 100 post-battle / area-break intermission ===================

function HSc.pushEndRunConfirm(game,onConfirm,onCancel,totalFights)
  local state=hubSurface({game=game,kind="endRunConfirm",resolved=false,totalFights=normalizedClimbLength(totalFights or 100)})
  state.__cbeMtBattleHubDraw=drawEndRunConfirm
  function state:update()
    if self.resolved then return end
    local input=self.game and self.game.input
    if not (input and input.wasPressed) then return end
    if input:wasPressed("a") then
      self.resolved=true
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then self.game.stack:pop() end
      local ok,why=true,nil
      if onConfirm then ok,why=onConfirm() end
      if ok==false then
        self.resolved=false;self.message=tostring(why or "END RUN FAILED")
        self.game.stack:push(self)
      end
    elseif input:wasPressed("b") then
      self.resolved=true
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then self.game.stack:pop() end
      if onCancel then onCancel() end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawEndRunConfirm) end
  game.stack:push(state)
  return state
end

-- BP is drawn through the same measured, scrolling screen-space component on
-- desktop and mobile, not a new fixed-resolution modal.
local function drawBPScreen(state,viewport)
  local BP=V.MtBattleBattlePoints
  if not (BP and Mobile) then return end
  local view=BP.summary(state.game);local run=SaveState.state(state.game)
  local rows={};local tab=state.bpTab or 1
  if state.bpPhase=="confirm" then
    local item=state.bpItem
    rows={{label="BUY "..item.name,meta=tostring(item.cost).." BP",
      detail="Adds one to this run's Challenge Bag only. A confirms and saves. B cancels. Leftover supplies do not carry to the next run."}}
  elseif state.bpPhase=="receipt" then
    rows={{label="PURCHASE SAVED",meta=tostring(view.balance).." BP LEFT",detail=state.message or "A returns to the exchange. B closes."}}
  elseif tab==1 then
    rows={mobileStat("BP BALANCE",view.balance,"BP persists on this save after a loss, an abandoned run, a clear, and a new challenge."),
      mobileStat("NO-FAINT VICTORY",tostring(view.cleanWinBP).." BP","Earn 1 BP total only when you win with no player Pokemon fainting and all six alive at the finish. Winning alone earns 0 BP."),
      mobileStat("REQUIREMENTS","0 FAINTS / 6 ALIVE","Checked separately for each battle. Reviving a Pokemon that fainted does not restore BP eligibility. Full HP is not required."),
      mobileStat("THIS RUN",view.runEarned.." EARNED",view.runSpent.." BP spent during this run. XP BANK remains separate."),
      mobileStat("LIFETIME EARNED",view.lifetimeEarned),mobileStat("LIFETIME SPENT",view.lifetimeSpent)}
    if view.lastAward then
      local a=view.lastAward
      rows[#rows+1]=mobileStat("LAST WIN",tostring(a.amount).." BP","Battle "..tostring(a.fight)..": "..bpAwardDescription(a))
    end
  elseif tab==2 then
    for _,item in ipairs(BP.CATALOG) do
      rows[#rows+1]={label=item.name,meta=tostring(item.cost).." BP / x"..tostring((run.bag or {})[item.id] or 0),
        disabled=not BP.canExchange(state.game) or view.balance<item.cost,
        detail=BP.canExchange(state.game) and "Challenge Bag only. A opens purchase confirmation; no BP is spent until you confirm and saving succeeds."
          or "The exchange opens after a victory, before the next fight. It is closed during battles, Continue decisions, and the finale."}
    end
  else
    for i=#view.receipts,1,-1 do
      local r=view.receipts[i];local purchase=r.kind=="purchase"
      rows[#rows+1]={label=purchase and (tostring(r.item):gsub("_"," ")) or ("BATTLE "..tostring(r.fight).." WIN"),
        meta=(purchase and "-" or "+")..tostring(r.amount).." BP",
        detail=tostring(r.runId).." / Balance after: "..tostring(r.balanceAfter).." BP / "..(purchase and "Purchase saved" or bpAwardDescription(r))}
    end
    if #rows==0 then rows={{label="NO BP TRANSACTIONS YET",detail="New wins will appear here. Historic fights are not awarded again on upgrade."}} end
  end
  local tabs={}
  for i,label in ipairs({"WALLET","EXCHANGE","HISTORY"}) do tabs[i]={label=label,active=i==tab} end
  state.bpRowCount=#rows
  state.cursor=math.max(1,math.min(#rows,state.cursor or 1))
  return Mobile.draw(state,viewport,{title="BATTLE POINTS",subtitle=tostring(view.balance).." BP / SEPARATE FROM XP BANK",
    section=state.bpPhase=="confirm" and "CONFIRM PURCHASE" or (tab==3 and "RECENT 64 TRANSACTIONS" or "BP REWARDS"),tabs=tabs,rows=rows,
    cursor=state.cursor,team=false,focusedList=true,detail=state.message,
    hints=state.bpPhase=="confirm" and {"A Buy and save   B Cancel"}
      or {"SELECT Change tab   UP/DOWN Browse","A Open / Confirm   B Back","LEFT/RIGHT Page   START Records"}})
end

function HSc.pushBPScreen(game,initialTab)
  local BP=V.MtBattleBattlePoints
  if not (BP and Mobile and game and game.stack) then return nil,"BP screen unavailable" end
  local owner,stack=game.save,game.stack
  local state=hubSurface({game=game,kind="battlePoints",bpTab=initialTab or 1,cursor=1,bpPhase="browse"})
  state.__cbeMtBattleHubDraw=drawBPScreen
  local function close()
    if stack.top and stack:top()==state then stack:pop() end
  end
  function state:update()
    if self.game.save~=owner or self.game.stack~=stack then close();return end
    local input=self.game.input;if not (input and input.wasPressed) then return end
    if self.bpPhase=="confirm" then
      if input:wasPressed("b") then self.bpPhase="browse";self.message=nil;self.bpToken=nil
      elseif input:wasPressed("a") then
        local ok,why=BP.purchase(self.game,self.bpItem.id,self.bpToken)
        self.message=why;self.bpToken=nil;self.bpPhase=ok and "receipt" or "browse"
      end
      return
    end
    if input:wasPressed("b") then close();return end
    if self.bpPhase=="receipt" then
      if input:wasPressed("a") then self.bpPhase="browse";self.message=nil end
      return
    end
    if input:wasPressed("select") then self.bpTab=self.bpTab%3+1;self.cursor=1;self.message=nil;return end
    if input:wasPressed("start") then HSc.pushBattleRecords(self.game);return end
    local count=self.bpTab==2 and #BP.CATALOG or (self.bpRowCount or 6)
    if input:wasPressed("up") then self.cursor=math.max(1,self.cursor-1);self.message=nil
    elseif input:wasPressed("down") then self.cursor=math.min(count,self.cursor+1);self.message=nil
    elseif input:wasPressed("left") or input:wasPressed("right") then
      local step=math.max(1,self.__cbeMobileLayout and self.__cbeMobileLayout.visible or 1)
      self.cursor=math.max(1,math.min(count,self.cursor+(input:wasPressed("left") and -step or step)))
    elseif input:wasPressed("a") then
      if self.bpTab==1 then self.bpTab=2;self.cursor=1;self.message=nil
      elseif self.bpTab==2 then
        local token,why=BP.purchaseToken(self.game)
        if not token then self.message=why;return end
        self.bpItem=BP.CATALOG[self.cursor];if not self.bpItem then return end
        if BP.state(self.game).balance<self.bpItem.cost then self.message="NOT ENOUGH BP";return end
        self.bpToken=token;self.bpPhase="confirm";self.message=nil
      end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawBPScreen) end
  stack:push(state);return state
end

function HSc.pushChallengeIntermission(game,model,onAction,opts)
  opts=opts or {}
  local state=hubSurface({game=game,model=model or {},kind="challengeIntermission",resolved=false,message=model and model.saveError})
  state.__cbeMtBattleHubDraw=drawChallengeIntermission
  function state:update()
    if mobileBrowseStatus(self) then return end
    if self.resolved then return end
    local input=self.game and self.game.input
    if not (input and input.wasPressed) then return end
    if input:wasPressed("a") then
      self.resolved=true
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then
        self.game.stack:pop()
      end
      local ok,why=true,nil
      if onAction then ok,why=onAction(self.model) end
      -- A technical launch refusal must not destroy the deterministic pause.
      -- Re-arm this same screen only when the callback explicitly reports false.
      if ok==false then
        self.resolved=false
        if self.game.stack and type(self.game.stack.push)=="function" then self.game.stack:push(self) end
      end
    elseif input:wasPressed("start") then
      local ok=true
      if opts.onSave then ok=opts.onSave(self.model) end
      self.message=ok==false and "SAVE FAILED" or "RUN SAVED"
    elseif input:wasPressed("b") then
      if opts.onExit then
        local ok=opts.onExit(self.model)
        if ok~=false then
          self.resolved=true
          if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then self.game.stack:pop() end
        end
      end
    elseif input:wasPressed("left") then
      if self.model.itemUseAllowed then HSc.pushChallengeBagUse(self.game,self.model)
      else self.message="CHALLENGE BAG UNAVAILABLE AT THIS BREAK" end
    elseif input:wasPressed("right") and opts.onEndRun then
      HSc.pushEndRunConfirm(self.game,function()
        local ok,why=opts.onEndRun(self.model)
        if ok~=false then
          self.resolved=true
          if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then self.game.stack:pop() end
        else self.message=tostring(why or "END RUN FAILED") end
        return ok,why
      end,nil,self.model.totalFights)
    elseif input:wasPressed("select") then
      if V.MtBattleBattlePoints then HSc.pushBPScreen(self.game)
      else HSc.pushBattleRecords(self.game) end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawChallengeIntermission) end
  game.stack:push(state)
  return state
end

-- Read-only Battle Records overlay. RecordsManager owns every byte of capture;
-- this screen consumes only its public summary/currentRun views and therefore
-- cannot alter run determinism, Continue state, or encounter generation.
function HSc.pushBattleRecords(game)
  local RM=V.MtBattleRecordsManager
  if not (RM and type(RM.summary)=="function" and type(RM.currentRun)=="function") then return nil,"records unavailable" end
  local summary=RM.summary(game) or {}
  local current=RM.currentRun(game) or {}
  local history=recordHistoryRows(current)
  local state=hubSurface({game=game,kind="battleRecords",summary=summary,currentRun=current,history=history,cursor=#history})
  if state.cursor<1 then state.cursor=0 end
  state.__cbeMtBattleHubDraw=drawBattleRecords
  function state:update()
    if mobileRecordInput(self,false) then return end
    local input=self.game and self.game.input;if not (input and input.wasPressed) then return end
    if input:wasPressed("b") or input:wasPressed("select") then
      if self.game.stack and self.game.stack:top()==self then self.game.stack:pop() end
      return
    end
    if #self.history==0 then return end
    if input:wasPressed("up") then self.cursor=math.max(1,self.cursor-1)
    elseif input:wasPressed("down") then self.cursor=math.min(#self.history,self.cursor+1)
    elseif input:wasPressed("left") then self.cursor=math.max(1,self.cursor-10)
    elseif input:wasPressed("right") then self.cursor=math.min(#self.history,self.cursor+10) end
  end
  function state:draw() return stateCanvasDraw(self,drawBattleRecords) end
  game.stack:push(state)
  return state
end

function HSc.pushHallOfFame(game)
  local RM=V.MtBattleRecordsManager
  if not (RM and type(RM.summary)=="function" and type(RM.currentRun)=="function") then return nil,"records unavailable" end
  local summary=RM.summary(game) or {}
  local runs=type(summary.runHistory)=="table" and summary.runHistory
    or (type(summary.hallOfFame)=="table" and summary.hallOfFame or {})
  local current=RM.currentRun(game) or {}
  local state=hubSurface({game=game,kind="hallOfFame",summary=summary,currentRun=current,runs=runs,cursor=#runs>0 and 1 or 0})
  state.__cbeMtBattleHubDraw=drawHallOfFame
  function state:update()
    if mobileRecordInput(self,true) then return end
    local input=self.game and self.game.input;if not (input and input.wasPressed) then return end
    -- Navigate the exact archive being rendered. Hall of Fame keeps successful
    -- clears as its durable subset, while this screen intentionally promises all
    -- recorded runs (including failed attempts) plus the active run summary.
    local list=type(self.runs)=="table" and self.runs or {}
    if input:wasPressed("b") or input:wasPressed("select") then
      if self.game.stack and self.game.stack.top and self.game.stack:top()==self then self.game.stack:pop() end
      return
    end
    if #list==0 then return end
    if input:wasPressed("up") then self.cursor=self.cursor>1 and self.cursor-1 or #list
    elseif input:wasPressed("down") then self.cursor=self.cursor<#list and self.cursor+1 or 1
    elseif input:wasPressed("left") then self.cursor=math.max(1,self.cursor-10)
    elseif input:wasPressed("right") then self.cursor=math.min(#list,self.cursor+10) end
  end
  function state:draw() return stateCanvasDraw(self,drawHallOfFame) end
  game.stack:push(state)
  return state
end

function HSc.pushFinaleSummary(game,model,onDistribute)
  local state=hubSurface({game=game,kind="finaleSummary",model=model or {},resolved=false})
  state.__cbeMtBattleHubDraw=drawFinaleSummary
  function state:update()
    if mobileBrowseStatus(self) then return end
    local run=self.game and self.game.save and self.game.save.mtBattleChallenge
    if run and run.finaleCompletePending==true then
      self.resolved=true
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then self.game.stack:pop() end
      self.game.__cbeMtBattleFinaleSummaryState=nil
      self.game.__cbeMtBattleFinaleOpen=nil
      return
    end
    local input=self.game and self.game.input;if not (input and input.wasPressed) then return end
    if input:wasPressed("select") then HSc.pushBattleRecords(self.game);return end
    if (input:wasPressed("a") or input:wasPressed("start")) and not self.resolved then
      self.resolved=true
      local ok=true;if onDistribute then ok=onDistribute(self) end
      -- Distribution is pushed over this summary so B can return without losing
      -- the allocation state. Re-arm the A action only if setup itself failed.
      if ok==false then self.resolved=false end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawFinaleSummary) end
  game.stack:push(state)
  return state
end

function HSc.pushXPDistribution(game,xpState,onCommit,onClose)
  local entries=(xpState and xpState.eligibleMons) or {}
  local state=hubSurface({game=game,kind="xpDistribution",xpState=xpState,cursor=#entries>0 and 1 or 0,resolved=false,message=nil})
  state.__cbeMtBattleHubDraw=drawXPDistribution
  function state:update()
    if self.resolved then return end
    local input=self.game and self.game.input;if not (input and input.wasPressed) then return end
    if input:wasPressed("select") then HSc.pushBattleRecords(self.game);return end
    local list=(self.xpState and self.xpState.eligibleMons) or {}
    if self.xpState.__cbeMtBattleAppliedReceipt and not input:wasPressed("start") then
      self.message="XP APPLIED IN MEMORY - START TO RETRY SAVE"
      return
    end
    if input:wasPressed("b") then
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then self.game.stack:pop() end
      local parent=self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top() or nil
      if parent and parent.kind=="finaleSummary" then parent.resolved=false end
      if onClose then onClose(self.xpState) end
      return
    end
    if #list>0 then
      if input:wasPressed("up") then self.cursor=math.max(1,self.cursor-1);self.message=nil;return
      elseif input:wasPressed("down") then self.cursor=math.min(#list,self.cursor+1);self.message=nil;return
      elseif input:wasPressed("left") or input:wasPressed("right") then
        local current=(self.xpState.allocated and self.xpState.allocated[self.cursor]) or 0
        local delta=xpAllocationStep(self.xpState)*(input:wasPressed("left") and -1 or 1)
        self.xpState:allocate(self.cursor,math.max(0,current+delta));self.message=nil;return
      elseif input:wasPressed("a") then
        local current=(self.xpState.allocated and self.xpState.allocated[self.cursor]) or 0
        self.xpState:allocate(self.cursor,current+self.xpState:remaining());self.message=nil;return
      end
    end
    if input:wasPressed("start") then
      if #list>0 and self.xpState:remaining()>0 then
        self.message="ALLOCATE THE ENTIRE XP BANK BEFORE CONFIRMING."
        return
      end
      self.resolved=true
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then self.game.stack:pop() end
      local ok,why=true,nil
      if onCommit then ok,why=onCommit(self.xpState) end
      if ok==false then
        self.resolved=false;self.message=tostring(why or "XP DISTRIBUTION COULD NOT BE COMMITTED.")
        if self.game.stack and type(self.game.stack.push)=="function" then self.game.stack:push(self) end
      end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawXPDistribution) end
  game.stack:push(state)
  return state
end

function HSc.pushFinaleComplete(game,model,onReturn)
  local state=hubSurface({game=game,kind="finaleComplete",model=model or {},resolved=false})
  state.__cbeMtBattleHubDraw=drawFinaleComplete
  function state:update()
    if mobileBrowseStatus(self) then return end
    if self.resolved then return end
    local input=self.game and self.game.input;if not (input and input.wasPressed) then return end
    if input:wasPressed("select") then HSc.pushBattleRecords(self.game);return end
    if input:wasPressed("a") or input:wasPressed("start") then
      self.resolved=true
      if self.game.stack and type(self.game.stack.top)=="function" and self.game.stack:top()==self then self.game.stack:pop() end
      local ok,why=true,nil;if onReturn then ok,why=onReturn() end
      if ok==false then
        self.resolved=false;self.message=tostring(why or "SAVE FAILED")
        self.game.stack:push(self)
      end
    end
  end
  function state:draw() return stateCanvasDraw(self,drawFinaleComplete) end
  game.stack:push(state)
  return state
end

-- ===== Team source choice (Gen 1): current save team vs true rentals =====

-- This is intentionally a thin legacy sibling of Team Review: the parent setup
-- menu stays underneath so MOVE PREP/PC remains available if a caller still
-- uses the old source-choice helper.
-- Selecting either source auto-pops this menu before invoking its callback,
-- matching native Menu's normal (non-keepOpen) selection contract.
function HSc.pushTeamSourceChoice(game,opts)
  opts=opts or {}
  local menu
  local items={
    {label="USE PARTY",onSelect=function() if opts.onParty then opts.onParty() end end},
    {label="RENTAL TEAM",onSelect=function() if opts.onRental then opts.onRental() end end},
    {label="BACK",onSelect=function() if opts.onCancel then opts.onCancel() end end},
  }
  menu=Menu.new(game,items,{tx=2,ty=2,onCancel=opts.onCancel,noSound=true})
  menu.kind="teamSourceChoice"
  hubSurface(menu)
  menu.__cbeMtBattleHubDraw=drawTeamReview
  menu.draw=function(self) return stateCanvasDraw(self,drawTeamReview) end
  game.stack:push(menu)
  return menu
end

-- ===== Team Review: shared Gen 1 / Gen 2 setup surface ======================
--
-- One challenge setup menu; BUILD CHALLENGE TEAM now owns party + storage
-- selection. No duplicate PC/BUILD YOUR SIX door that mutates the live party.
-- Move preparation and team selection operate on detached challenge snapshots.
--
-- `opts`: {onStart=function(closeSelf) .. end, onCancel=function() end}.
--   `onStart` receives `closeSelf` (call it once validation passes,
--   BEFORE going on to BEGIN CHALLENGE, since this menu used keepOpen
--   and never auto-closes on its own) -- so an invalid team (not exactly
--   6, or containing an egg) can show a refusal message and leave the
--   menu open, exactly like BattleTower's own checkRules refusal pattern.
function HSc.pushTeamReview(game,opts)
  opts=opts or {}
  game.__cbeMtBattlePrep=true
  local menu
  local function clearPrep() game.__cbeMtBattlePrep=nil end
  local function cancel()
    clearPrep()
    if opts.onCancel then opts.onCancel() end
  end
  local function closeSelf()
    clearPrep()
    if game.stack:top()==menu then game.stack:pop() end
  end
  local items={
    {label="MOVE PREP",keepOpen=true,onSelect=function()
      if opts.onMovePrep then opts.onMovePrep(closeSelf) end
    end},
    {label="RENTAL TEAM",keepOpen=true,onSelect=function()
      if opts.onRental then opts.onRental(closeSelf) end
    end},
    {label="CUSTOM TEAMS",keepOpen=true,onSelect=function()
      if opts.onCustomTeams then opts.onCustomTeams(closeSelf) end
    end},
    {label="START CHALLENGE",keepOpen=true,onSelect=function()
      if opts.onStart then opts.onStart(closeSelf) end
    end},
    {label="CANCEL",onSelect=cancel},
  }
  -- noSound, like Bill's PC (src/ui/BoxMenu.lua): a new mod-original menu
  -- with no established native sound cue of its own.
  menu=Menu.new(game,items,{tx=2,ty=2,onCancel=cancel,noSound=true})
  menu.kind="teamReview"
  menu.generation=tonumber(opts.generation)==2 and 2 or 1
  menu.totalFights=normalizedClimbLength(opts.totalFights or 100)
  menu.teamProvider=opts.teamProvider
  -- ListMenu's cartridge watched-key mask already treats SELECT as a legitimate
  -- extra key, but this generic engine Menu intentionally does not assign it a
  -- behavior. Use it as a read-only records shortcut without adding another
  -- primary setup action; the action rail sizes itself from the current rows.
  local nativeUpdate=menu.update
  menu.update=function(self,dt)
    local input=self.game and self.game.input
    if input and input.wasPressed and input:wasPressed("start") then
      local ok=true
      if opts.onSave then ok=opts.onSave() end
      self.saveMessage=ok==false and "SAVE FAILED" or "GAME SAVED"
      return
    end
    if input and input.wasPressed and input:wasPressed("select") then
      HSc.pushBattleRecords(self.game)
      return
    end
    return nativeUpdate(self,dt)
  end
  -- Preserve the native Menu input/update implementation (and therefore the
  -- exact MOVE PREP/RENTAL/START/CANCEL behavior), but replace its small Game Boy box with
  -- the challenge-specific widescreen composition above. Keeping the screen
  -- transparent is essential: HubStage's live Summit/Wes render remains the
  -- hero layer behind this chrome.
  hubSurface(menu)
  menu.__cbeMtBattleHubDraw=drawTeamReview
  menu.draw=function(self) return stateCanvasDraw(self,drawTeamReview) end
  game.stack:push(menu)
  return menu
end

HSc._test.mobileDraws={bp=drawBPScreen,review=drawTeamReview,climb=drawClimbSetup,options=drawGenerationOptions,
  rules=drawRulesets,team=drawTeamSelect,moves=drawMovePrep,confirm=drawBeginConfirm,info=drawInfoState,briefing=drawFightBriefing,intermission=drawChallengeIntermission,
  bag=drawChallengeBagUse,endRun=drawEndRunConfirm,suspend=drawSuspendRunConfirm,activeRun=drawActiveRunControl,
  hall=drawHallOfFame,records=drawBattleRecords,finale=drawFinaleSummary,xp=drawXPDistribution,receipt=drawFinaleComplete,custom=drawCustomTeamsMobile}
HSc._test.mobileRecordDetails=mobileRecordDetails

return HSc
