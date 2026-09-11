-- Presentation resources shared by standalone UI and the combined package.
-- No texture readback, source mutation, or input/state-stack replacement.
local T=... or {}
local U={version=1}
local portraits=setmetatable({},{__mode="k"})
local paths=setmetatable({},{__mode="k"})
local quadBuilds=0
function U.registerPortrait(image,path)
  if image then paths[image]=path end
end
function U.drawPortrait(image,x,y,w,h)
  if not image or not (w>0 and h>0) then return false,false end
  local cached=portraits[image]
  if not cached then
    local iw,ih=image:getDimensions()
    if not (iw and ih and iw>0 and ih>0) then return false,false end
    local rect=T.bounds and T.bounds[paths[image]]
    local cx,cy,cw,ch=0,0,iw,ih
    if rect then
      cx=math.max(0,math.min(iw-1,rect[1]));cy=math.max(0,math.min(ih-1,rect[2]))
      cw=math.max(1,math.min(iw-cx,rect[3]));ch=math.max(1,math.min(ih-cy,rect[4]))
    end
    cached={quad=love.graphics.newQuad(cx,cy,cw,ch,iw,ih),w=cw,h=ch}
    portraits[image]=cached;quadBuilds=quadBuilds+1
  end
  -- Fit the actual authored tile, not the asymmetric transparent sheet gutter.
  -- Keep the complete face and its aspect ratio; never stretch a portrait.
  local scale=math.min(w/cached.w,h/cached.h)
  love.graphics.setColor(1,1,1,1)
  love.graphics.draw(image,cached.quad,x+(w-cached.w*scale)/2,y+(h-cached.h*scale)/2,0,scale,scale)
  return true,true
end
function U.bindDexAction(state)
  if type(state)~="table" or not state.__gen3uiPokedexAction or type(state.draw)~="function" then return false end
  if state.draw==state.__colosseumDexVisualWrapper then return true end
  -- Native Gen I assigns side.draw AFTER Menu.new. A class-level Menu.draw
  -- wrapper cannot intercept that instance method; bind after the assignment.
  local native=state.draw
  local wrapped=function(self,...)
    if T.hideDexAction and T.hideDexAction(self) then return end
    return native(self,...)
  end
  state.__colosseumDexVisualWrapper=wrapped
  state.draw=wrapped
  return true
end
function U.wrapDexChoose(class)
  if type(class)~="table" or type(class.onChoose)~="function" or class.__colosseumDexChooseBound then return false end
  class.__colosseumDexChooseBound=true
  local native=class.onChoose
  class.onChoose=function(item,list,...)
    local function finish(...)
      local stack=list and list.game and list.game.stack
      local top=stack and type(stack.top)=="function" and stack:top() or nil
      U.bindDexAction(top)
      return ...
    end
    -- Preserve all returns and every native DATA/CRY/AREA/PRINT/QUIT callback.
    return finish(native(item,list,...))
  end
  return true
end
function U.status() return {quadBuilds=quadBuilds} end
return U
