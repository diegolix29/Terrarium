-- Realtime battle input/presentation bridge ported from XD_BATTLE_ENVIRONMENTS.
-- Attaches onto Terrarium's BattleRuntime without replacing Terrarium-specific lifecycle.
local V=...
local B={}
function B.attach(R)
  local mod=V.mod
  local BattleSettings=V.BattleSettings
  local Compat=V.GenerationCompat
  R.rawInputCaptureInstalled=R.rawInputCaptureInstalled or false
  R.realtimeKeyPressed=R.realtimeKeyPressed or {}
  R.realtimeKeyDown=R.realtimeKeyDown or {}
  R.realtimePadPressed=R.realtimePadPressed or {}
  R.realtimePadDown=R.realtimePadDown or {}
  R.realtimeWheelY=tonumber(R.realtimeWheelY) or 0
  R.realtimeMouseDX=tonumber(R.realtimeMouseDX) or 0
  R.realtimeMouseDY=tonumber(R.realtimeMouseDY) or 0
  R.statBoxAutoDismissed=R.statBoxAutoDismissed or 0
  R.trainerChoiceAutoDeclined=R.trainerChoiceAutoDeclined or 0
  local function stackTop(game)
    local states=game and game.stack and game.stack.states
    return type(states)=="table" and states[#states] or nil
  end
  local function contextFor(battle)
    battle=Compat and Compat.prepare(battle) or battle
    return {battle=battle,game=(battle and battle.game) or (mod and mod.game)}
  end
  local function miniDispatch(name,payload)
    local battle=(type(payload)=="table" and payload.battle) or R.activeBattle
    battle=Compat and Compat.prepare(battle) or battle
    local ctx=contextFor(battle)
    local rt=V and V.RealtimeBattle
    if rt and type(rt.event)=="function" then pcall(rt.event,rt,ctx,name,payload) end
    -- Also forward to StandaloneHost/CurrentSprites via existing R path if present later.
  end
local NATIVE_BATTLE_INPUT_BLOCK={
  a=true,b=true,start=true,select=true,
  up=true,down=true,left=true,right=true,
  l=true,r=true,x=true,y=true,
  confirm=true,cancel=true,menu=true,
}

local function realtimeOwnsBattleInput(game)
  if not R.activeBattle then return false end
  if stackTop(game)~=R.activeBattle then return false end
  if BattleSettings and type(BattleSettings.realtimeEnabled)=="function" then
    local ok,v=pcall(BattleSettings.realtimeEnabled,game)
    return ok and v==true
  end
  return false
end

local function realtimeAutoAdvances(game)
  -- In realtime mode the native battle textbox is hidden, so *all* ordinary
  -- BattleState message pages must advance without a physical A/B press, not
  -- only the pages emitted by one realtime move resolution.  This remains
  -- safe for real choices: ChoiceBox/PartyMenu are pushed above BattleState,
  -- which makes realtimeOwnsBattleInput() false until that UI closes.
  return realtimeOwnsBattleInput(game)
    and R.activeBattle and R.activeBattle.phase=="messages"
end

-- Realtime owns the visible 3D battlefield. The stock BattleState still updates
-- its move-animation FX for battle semantics/timing, but its full-screen palette
-- flashes are a second presentation layer and visibly flash the XD arena. Keep
-- those timers running; suppress only their DRAW result while realtime is on.
local function realtimeOwnsPresentation(battle)
  if not (battle and battle==R.activeBattle) then return false end
  if BattleSettings and type(BattleSettings.realtimeEnabled)=="function" then
    local ok,v=pcall(BattleSettings.realtimeEnabled,battle.game)
    return ok and v==true
  end
  return false
end

local function neutralizeRealtimeNativeFx(battle)
  if not realtimeOwnsPresentation(battle) then return false end
  local fx=battle and battle.fx
  if type(fx)=="table" then
    -- Realtime owns the visible battlefield. Keep native battle logic/timers,
    -- but remove every stock full-field palette/flash/shake/wavy/blink visual.
    -- In particular, applyHitFx uses shakeProg for enemy damage and status
    -- moves such as Sand-Attack; on a transparent CBE layer those offsets can
    -- expose the white native field and look like a full-screen flash.
    fx.flash=0
    fx.bgp=nil;fx.bgpSeq=nil
    fx.wavy=nil
    fx.shake=0;fx.shakeProg=nil;fx.shakeX=0;fx.shakeY=0
    fx.hudShakeProg=nil;fx.hudShakeX=0
    fx.blink=nil
  end
  battle.letterboxWhite=false
  return true
end

local function installRealtimeNativeFxSuppression()
  local req=V.engineRequire or require
  local ok,BattleState=pcall(req,"src.battle.BattleState")
  if not ok or type(BattleState)~="table" then R.nativeFxBridge=false;return false end

  -- Quarantine stock AnimPlayer visual events at their source. Sounds still
  -- run, and AnimPlayer itself still advances, so authoritative battle timing
  -- is unchanged. This is stronger than merely hiding activeBgp()/fx.flash.
  if type(BattleState.applyAnimEffect)=="function" and BattleState.applyAnimEffect~=R.nativeAnimEffectWrapper then
    local inner=BattleState.applyAnimEffect
    R.nativeAnimEffectInner=inner
    R.nativeAnimEffectWrapper=function(self,ev,...)
      if realtimeOwnsPresentation(self) then
        local e=type(ev)=="table" and tostring(ev.effect or "") or ""
        -- SFX_* rows are sound-only; let the engine handle those normally.
        if e:match("^SFX_") then return inner(self,ev,...) end
        if type(ev)=="table" and ev.sound and type(self.playAnimSound)=="function" then
          pcall(self.playAnimSound,self,ev.sound)
        end
        neutralizeRealtimeNativeFx(self)
        return nil
      end
      return inner(self,ev,...)
    end
    BattleState.applyAnimEffect=R.nativeAnimEffectWrapper
  end

  -- The post-move applying-attack animation is a separate engine path. It is
  -- what drives enemy-hit vertical shakes and non-damaging status-move shakes.
  -- Preserve its sound + waitFrames by running it, then delete only visuals.
  if type(BattleState.applyHitFx)=="function" and BattleState.applyHitFx~=R.nativeHitFxWrapper then
    local inner=BattleState.applyHitFx
    R.nativeHitFxInner=inner
    R.nativeHitFxWrapper=function(self,hit,...)
      local result=inner(self,hit,...)
      neutralizeRealtimeNativeFx(self)
      return result
    end
    BattleState.applyHitFx=R.nativeHitFxWrapper
  end

  -- Catch fallback anim.flash rows and any visual state written by queue/update
  -- code outside applyAnimEffect/applyHitFx before the next frame is drawn.
  if type(BattleState.update)=="function" and BattleState.update~=R.nativeUpdateFxWrapper then
    local inner=BattleState.update
    R.nativeUpdateFxInner=inner
    R.nativeUpdateFxWrapper=function(self,...)
      local result=inner(self,...)
      neutralizeRealtimeNativeFx(self)
      return result
    end
    BattleState.update=R.nativeUpdateFxWrapper
  end

  -- Palette/BGP flashes (SE_DARK_SCREEN_FLASH / SE_FLASH_SCREEN_LONG and
  -- related palette rows) all resolve through activeBgp(). Returning nil here
  -- leaves the native queue/timers intact while preventing the 3D arena from
  -- inheriting the Game Boy/SGB flash.
  if type(BattleState.activeBgp)=="function" and BattleState.activeBgp~=R.nativeBgpWrapper then
    local inner=BattleState.activeBgp
    R.nativeBgpInner=inner
    R.nativeBgpWrapper=function(self,...)
      if realtimeOwnsPresentation(self) then return nil end
      return inner(self,...)
    end
    BattleState.activeBgp=R.nativeBgpWrapper
  end

  -- Wide layout bypasses drawClassic() entirely, so suppress the same native
  -- white-flash flag around the top-level BattleState:draw() as well. This
  -- catches both classic and widescreen/native composition paths.
  if type(BattleState.draw)=="function" and BattleState.draw~=R.nativeTopDrawWrapper then
    local inner=BattleState.draw
    R.nativeTopDrawInner=inner
    R.nativeTopDrawWrapper=function(self,...)
      local fx=self and self.fx
      if not (fx and realtimeOwnsPresentation(self)) then return inner(self,...) end
      local saved=fx.flash
      fx.flash=0
      local out={pcall(inner,self,...)}
      fx.flash=saved
      local success=table.remove(out,1)
      if not success then error(out[1],0) end
      return (table.unpack or unpack)(out)
    end
    BattleState.draw=R.nativeTopDrawWrapper
  end

  -- Animations-off fallback uses fx.flash as a literal white fullscreen overlay
  -- at the end of drawClassic(). Temporarily zero only that draw flag. Do not
  -- erase it from state: updateFx continues to advance it normally.
  if type(BattleState.drawClassic)=="function" and BattleState.drawClassic~=R.nativeFxDrawWrapper then
    local inner=BattleState.drawClassic
    R.nativeFxDrawInner=inner
    R.nativeFxDrawWrapper=function(self,...)
      local fx=self and self.fx
      if not (fx and realtimeOwnsPresentation(self)) then return inner(self,...) end
      local saved=fx.flash
      fx.flash=0
      local out={pcall(inner,self,...)}
      fx.flash=saved
      local success=table.remove(out,1)
      if not success then error(out[1],0) end
      return (table.unpack or unpack)(out)
    end
    BattleState.drawClassic=R.nativeFxDrawWrapper
  end

  R.nativeFxBridge=(BattleState.activeBgp==R.nativeBgpWrapper)
    and (BattleState.draw==R.nativeTopDrawWrapper)
    and (BattleState.drawClassic==R.nativeFxDrawWrapper)
    and (type(BattleState.applyAnimEffect)~="function" or BattleState.applyAnimEffect==R.nativeAnimEffectWrapper)
    and (type(BattleState.applyHitFx)~="function" or BattleState.applyHitFx==R.nativeHitFxWrapper)
    and (type(BattleState.update)~="function" or BattleState.update==R.nativeUpdateFxWrapper)
  return R.nativeFxBridge
end

function R.consumeRealtimeKey(key)
  key=tostring(key or ""):lower()
  if key=="" then return false end
  local hit=R.realtimeKeyPressed[key]==true
  R.realtimeKeyPressed[key]=nil
  return hit
end

function R.realtimeKeyIsDown(key)
  return R.realtimeKeyDown[tostring(key or ""):lower()]==true
end

function R.consumeRealtimePad(button)
  button=tostring(button or ""):lower()
  if button=="" then return false end
  local hit=R.realtimePadPressed[button]==true
  R.realtimePadPressed[button]=nil
  return hit
end

function R.realtimePadIsDown(button)
  return R.realtimePadDown[tostring(button or ""):lower()]==true
end

function R.consumeRealtimeWheel()
  local y=tonumber(R.realtimeWheelY) or 0
  R.realtimeWheelY=0
  return y
end

function R.consumeRealtimeMouse()
  local dx=tonumber(R.realtimeMouseDX) or 0
  local dy=tonumber(R.realtimeMouseDY) or 0
  R.realtimeMouseDX,R.realtimeMouseDY=0,0
  return dx,dy
end

local function latchRealtimeKeyPressed(key)
  key=tostring(key or ""):lower()
  if key=="" then return end
  if not R.realtimeKeyDown[key] then
    R.realtimeKeyPressed[key]=true
  end
  R.realtimeKeyDown[key]=true
end

local function latchRealtimeKeyReleased(key)
  key=tostring(key or ""):lower()
  if key=="" then return end
  R.realtimeKeyDown[key]=nil
end

local function latchRealtimePadPressed(button)
  button=tostring(button or ""):lower()
  if button=="" then return end
  if not R.realtimePadDown[button] then
    R.realtimePadPressed[button]=true
  end
  R.realtimePadDown[button]=true
end

local function latchRealtimePadReleased(button)
  button=tostring(button or ""):lower()
  if button=="" then return end
  R.realtimePadDown[button]=nil
end

local function installRawRealtimeInputCapture()
  if R.rawInputCaptureInstalled then return true end

  local req=V.engineRequire or require
  local ok,Game=pcall(req,"src.core.Game")
  if not ok or type(Game)~="table" then return false end

  -- Hard realtime keyboard ownership.
  --
  -- Gen1Recomp converts keyboard keys into its virtual pad inside
  -- Game:keypressed/keyreleased, before input.step. Therefore masking only
  -- game.input during input.step is too late: the invisible command cursor can
  -- already have moved or confirmed FIGHT / ITEM / PKMN / RUN.
  --
  -- While REALTIME owns the top BattleState we swallow every keyboard key that
  -- can reasonably navigate/confirm/cancel the native battle command menu.
  -- RealtimeBattle still reads love.keyboard directly, so WASD and the future
  -- 6/7/8/9 move hotkeys remain available to the realtime controller.
  local REALTIME_RAW_KEYS={
    space=true,["return"]=true,kpenter=true,
    up=true,down=true,left=true,right=true,
    w=true,a=true,s=true,d=true,
    z=true,x=true,c=true,v=true,lctrl=true,
    j=true,k=true,l=true,
    backspace=true,
    ["0"]=true,["6"]=true,["7"]=true,["8"]=true,["9"]=true,
    kp9=true,kp6=true,kp3=true,["kp."]=true,
  }
  local function blocksRealtimeKey(key)
    return REALTIME_RAW_KEYS[tostring(key):lower()]==true
  end

  if type(Game.keypressed)=="function" then
    local inner=Game.keypressed
    R.rawKeyPressedInner=inner
    Game.keypressed=function(self,key,...)
      if realtimeOwnsBattleInput(self) and blocksRealtimeKey(key) then
        latchRealtimeKeyPressed(key)
        return
      end
      return inner(self,key,...)
    end
  end

  if type(Game.keyreleased)=="function" then
    local inner=Game.keyreleased
    R.rawKeyReleasedInner=inner
    Game.keyreleased=function(self,key,...)
      if realtimeOwnsBattleInput(self) and blocksRealtimeKey(key) then
        latchRealtimeKeyReleased(key)
        return
      end
      return inner(self,key,...)
    end
  end

  -- Isolate controller inputs from the native FIGHT menu while latching edges
  -- for RealtimeBattle (left stick / right stick are polled live; face/D-pad
  -- presses are edge-latched here the same way keyboard hotkeys are).
  local REALTIME_PAD_BUTTONS={
    a=true,b=true,x=true,y=true,start=true,back=true,
    dpup=true,dpdown=true,dpleft=true,dpright=true,
    leftshoulder=true,rightshoulder=true,
    leftstick=true,rightstick=true,
  }
  local function blocksRealtimePad(button)
    return REALTIME_PAD_BUTTONS[tostring(button):lower()]==true
  end

  if type(Game.gamepadpressed)=="function" then
    local inner=Game.gamepadpressed
    R.rawGamepadPressedInner=inner
    Game.gamepadpressed=function(self,joystick,button,...)
      if realtimeOwnsBattleInput(self) and blocksRealtimePad(button) then
        latchRealtimePadPressed(button)
        return
      end
      return inner(self,joystick,button,...)
    end
  end

  if type(Game.gamepadreleased)=="function" then
    local inner=Game.gamepadreleased
    R.rawGamepadReleasedInner=inner
    Game.gamepadreleased=function(self,joystick,button,...)
      if realtimeOwnsBattleInput(self) and blocksRealtimePad(button) then
        latchRealtimePadReleased(button)
        return
      end
      return inner(self,joystick,button,...)
    end
  end

  -- Mouse wheel owns realtime camera distance while the realtime BattleState is
  -- top-most. LÃ–VE dispatches wheel events through love.wheelmoved; preserve
  -- the previous callback outside realtime battles.
  if love then
    local inner=love.wheelmoved
    R.rawWheelMovedInner=inner
    love.wheelmoved=function(x,y)
      if realtimeOwnsBattleInput(mod and mod.game) then
        R.realtimeWheelY=(tonumber(R.realtimeWheelY) or 0)+(tonumber(y) or 0)
        return
      end
      if type(inner)=="function" then return inner(x,y) end
    end
  end

  -- Captured relative mouse movement for the battle third-person controller.
  if love then
    local inner=love.mousemoved
    R.rawMouseMovedInner=inner
    love.mousemoved=function(x,y,dx,dy,istouch)
      if realtimeOwnsBattleInput(mod and mod.game) then
        R.realtimeMouseDX=(tonumber(R.realtimeMouseDX) or 0)+(tonumber(dx) or 0)
        R.realtimeMouseDY=(tonumber(R.realtimeMouseDY) or 0)+(tonumber(dy) or 0)
        return
      end
      if type(inner)=="function" then return inner(x,y,dx,dy,istouch) end
    end
  end

  R.rawInputCaptureInstalled=true
  return true
end

-- Realtime combat owns its own visible HUD, so no ordinary BattleState text
-- page may leave an invisible PromptText/CONT gate waiting for a physical A/B
-- press.  Auto-confirm the text layer for the entire realtime BattleState,
-- including faint/EXP/victory/return-to-map cleanup.  Queue waits, animations,
-- HP drain and sounds still run normally.  Real ChoiceBox/PartyMenu states are
-- pushed above BattleState and therefore temporarily disable this bridge.
local function installRealtimeMessageAdvanceBridge()
  local req=V.engineRequire or require
  local ok,BattleState=pcall(req,"src.battle.BattleState")
  if not ok or type(BattleState)~="table" or type(BattleState.updateQueue)~="function" then
    R.queueAdvanceBridge=false
    return false
  end
  if BattleState.updateQueue==R.queueAdvanceWrapper then
    R.queueAdvanceBridge=true
    return true
  end
  local inner=BattleState.updateQueue
  R.queueAdvanceInner=inner
  R.queueAdvanceWrapper=function(self,...)
    local own=self==R.activeBattle and realtimeAutoAdvances(self.game)
    if not own then return inner(self,...) end

    -- A realtime XD faint tail is presentation that must finish before the
    -- authoritative queue is allowed to replace the battler. This is especially
    -- important in multi-Pokemon trainer battles where the next send-out can
    -- otherwise retire the KO'd 3D actor before its faint clip becomes visible.
    local rt=V and V.RealtimeBattle
    -- Mirror the exact authoritative battle text before this hidden native
    -- message page is auto-advanced. RealtimeBattle decides which acting
    -- side owns it and filters duplicate move/faint/EXP lines.
    local textRow=self.current
    if not (type(textRow)=="table" and textRow.text~=nil) then
      textRow=type(self.queue)=="table" and self.queue[1] or nil
    end
    if rt and type(rt.captureNativeText)=="function" and type(textRow)=="table" and textRow.text~=nil
       and not textRow.__xdRealtimeTextCaptured then
      textRow.__xdRealtimeTextCaptured=true
      pcall(rt.captureNativeText,rt,self,textRow)
    end
    if rt and type(rt.queuePresentationHold)=="function" then
      local okHold,hold=pcall(rt.queuePresentationHold,rt,self)
      if okHold and hold==true then return true end
    end

    local input=self.game and self.game.input
    if type(input)~="table" then return inner(self,...) end
    local oldPressed=input.wasPressed
    local oldDown=input.isDown

    input.wasPressed=function(obj,key,...)
      local k=tostring(key or ""):lower()
      if k=="a" or k=="b" then return true end
      if type(oldPressed)=="function" then return oldPressed(obj,key,...) end
      return false
    end
    input.isDown=function(obj,key,...)
      local k=tostring(key or ""):lower()
      if k=="a" or k=="b" then return true end
      if type(oldDown)=="function" then return oldDown(obj,key,...) end
      return false
    end

    -- These are message-only waits. Do not touch queue waitFrames, animation,
    -- HP-drain, sound, or UI waits: those still carry real battle semantics.
    if self.msgPreWait then self.msgPreWait=0 end
    if self.msgPromptWait then self.msgPromptWait=0 end
    if self.msgAutoWait then self.msgAutoWait=0 end
    if self.current and self.codes then
      self.charTimer=math.max(tonumber(self.charTimer) or 0,65536)
    end

    local result={pcall(inner,self,...)}
    input.wasPressed=oldPressed
    input.isDown=oldDown
    local success=table.remove(result,1)
    if not success then error(result[1],0) end
    return (table.unpack or unpack)(result)
  end
  BattleState.updateQueue=R.queueAdvanceWrapper
  R.queueAdvanceBridge=true
  return true
end

local function callEngineStepWithRealtimeInputBlocked(next,game,dt)
  if not realtimeOwnsBattleInput(game) then
    return next(game,dt)
  end

  local input=game and game.input
  if type(input)~="table" then
    return next(game,dt)
  end

  local originalWasPressed=input.wasPressed
  local originalIsDown=input.isDown
  local originalWasReleased=input.wasReleased

  -- The engine battle state reads semantic pad actions from game.input.  Mask
  -- those only while the engine advances.  Our real-time controller reads raw
  -- LÃ–VE keyboard state after this step, so Space/WASD still belong to it.
  if type(originalWasPressed)=="function" then
    input.wasPressed=function(self,key,...)
      local k=tostring(key):lower()
      if realtimeAutoAdvances(game) and (k=="a" or k=="b") then return true end
      if NATIVE_BATTLE_INPUT_BLOCK[k] then return false end
      return originalWasPressed(self,key,...)
    end
  end
  if type(originalIsDown)=="function" then
    input.isDown=function(self,key,...)
      local k=tostring(key):lower()
      if realtimeAutoAdvances(game) and (k=="a" or k=="b") then return true end
      if NATIVE_BATTLE_INPUT_BLOCK[k] then return false end
      return originalIsDown(self,key,...)
    end
  end
  if type(originalWasReleased)=="function" then
    input.wasReleased=function(self,key,...)
      if NATIVE_BATTLE_INPUT_BLOCK[tostring(key):lower()] then return false end
      return originalWasReleased(self,key,...)
    end
  end

  local results={pcall(next,game,dt)}

  input.wasPressed=originalWasPressed
  input.isDown=originalIsDown
  input.wasReleased=originalWasReleased

  local ok=table.remove(results,1)
  if not ok then error(results[1],0) end
  return (table.unpack or unpack)(results)
end

  local function dispatch(name,payload)
    miniDispatch(name,payload)
  end
local function installTrainerItemActionBridge()
  local req=V.engineRequire or require
  local ok,TrainerAI=pcall(req,"src.battle.TrainerAI")
  if not ok or type(TrainerAI)~="table" or type(TrainerAI.useItem)~="function" then
    R.trainerItemBridge=false;return false
  end
  if TrainerAI.useItem==R.trainerItemWrapper then R.trainerItemBridge=true;return true end
  local inner=TrainerAI.useItem
  R.trainerItemInner=inner
  R.trainerItemWrapper=function(battle,item,...)
    if battle and battle==R.activeBattle then
      dispatch("battle.trainer_item_used",{battle=battle,item=item,trainer=battle.trainer})
    end
    return inner(battle,item,...)
  end
  TrainerAI.useItem=R.trainerItemWrapper
  R.trainerItemBridge=true
  return true
end
local function installRealtimeTrainerReplacementBridge()
  local req=V.engineRequire or require
  local ok,BattleState=pcall(req,"src.battle.BattleState")
  if not ok or type(BattleState)~="table" or type(BattleState.enemyMonFainted)~="function" then
    R.trainerReplacementBridge=false
    return false
  end
  if BattleState.enemyMonFainted==R.enemyMonFaintedWrapper then
    R.trainerReplacementBridge=true
    return true
  end
  local inner=BattleState.enemyMonFainted
  R.enemyMonFaintedInner=inner
  R.enemyMonFaintedWrapper=function(self,...)
    if not (self==R.activeBattle and self.kind=="trainer" and realtimeOwnsPresentation(self)) then
      return inner(self,...)
    end
    local save=self.game and self.game.save
    local opts=save and save.options
    if type(opts)~="table" then return inner(self,...) end
    local previous=opts.battleStyle
    opts.battleStyle="set"
    local out={pcall(inner,self,...)}
    opts.battleStyle=previous
    local passed=table.remove(out,1)
    if not passed then error(out[1],0) end
    return (table.unpack or unpack)(out)
  end
  BattleState.enemyMonFainted=R.enemyMonFaintedWrapper
  R.trainerReplacementBridge=true
  return true
end


-- Realtime queue UI bridge.
--
-- enemyMonFainted() awards EXP BEFORE it queues the next trainer send-out.
-- A level-up inserts BattleState.StatBox into that same queue. updateQueue()
-- then sets waitingUI and will not continue until the pushed state pops.
-- In the XD realtime presentation the battle world keeps updating behind that
-- native modal, so it looks exactly like a replacement softlock: the defeated
-- enemy stays fainted on the field while the player can still move.
--
-- StatBox is informational only (A/B simply closes it), so realtime mode may
-- safely auto-dismiss it after the engine pushes it. Interactive screens such
-- as MoveLearnMenu/PartyMenu are NEVER auto-answered: instead we mark them as
-- native modals so RealtimeBattle freezes direct-control movement/attacks and
-- gives the real engine screen/input exclusive ownership until it closes.
local function realtimeNativeModal(game)
  local battle=R.activeBattle
  if not (battle and realtimeOwnsPresentation(battle) and game and game.stack) then
    if battle then battle.__xdRealtimeNativeModal=nil end
    R.nativeModalName=nil
    return nil,nil
  end
  local top=stackTop(game)
  if not top or top==battle then
    battle.__xdRealtimeNativeModal=nil
    R.nativeModalName=nil
    return nil,top
  end
  local req=V.engineRequire or require
  local ok,BattleState=pcall(req,"src.battle.BattleState")
  if ok and type(BattleState)=="table" and type(BattleState.StatBox)=="table"
      and getmetatable(top)==BattleState.StatBox then
    return "StatBox",top
  end
  local okChoice,ChoiceBox=pcall(req,"src.ui.ChoiceBox")
  if okChoice and type(ChoiceBox)=="table" and getmetatable(top)==ChoiceBox then
    return "ChoiceBox",top
  end
  local id=rawget(top,"screenId")
  if id~=nil then return tostring(id),top end
  return "native-ui",top
end

local function serviceRealtimeQueueUi(game)
  local battle=R.activeBattle
  if not (battle and realtimeOwnsPresentation(battle)) then return false end
  local name,top=realtimeNativeModal(game)
  if not name then return false end

  -- Level-up stat pages have no decision attached to them. Pop the exact
  -- exported BattleState.StatBox and preserve its optional onDone callback.
  if name=="StatBox" and battle.waitingUI and stackTop(game)==top then
    local popped=game.stack:pop()
    if popped and type(popped.onDone)=="function" then pcall(popped.onDone) end
    R.statBoxAutoDismissed=(tonumber(R.statBoxAutoDismissed) or 0)+1
    R.nativeModalName=nil
    battle.__xdRealtimeNativeModal=nil
    return true
  end

  -- Belt-and-suspenders for the trainer SHIFT prompt: v0.6.27 already runs
  -- enemyMonFainted() as SET style, but if another mod/wrapper reintroduces
  -- the ChoiceBox, decline ONLY the post-KO trainer free-switch question.
  local enemy=battle.enemy and battle.enemy.mon
  if name=="ChoiceBox" and battle.kind=="trainer" and battle.waitingUI
      and enemy and (tonumber(enemy.hp) or 0)<=0
      and battle.current and battle.current.choice and stackTop(game)==top then
    local popped=game.stack:pop()
    if popped and type(popped.onChoose)=="function" then pcall(popped.onChoose,false) end
    R.trainerChoiceAutoDeclined=(tonumber(R.trainerChoiceAutoDeclined) or 0)+1
    R.nativeModalName=nil
    battle.__xdRealtimeNativeModal=nil
    return true
  end

  -- Real decisions (MoveLearnMenu, PartyMenu, etc.) stay native and must be
  -- answered by the player. RealtimeBattle reads this marker and stops direct
  -- locomotion/attacks while the top state owns input.
  R.nativeModalName=name
  battle.__xdRealtimeNativeModal=name
  return false
end

local function installHardRealtimeMenuQuarantine()
  if R.hardMenuQuarantine then return true end
  local req=V.engineRequire or require
  local ok,BattleState=pcall(req,"src.battle.BattleState")
  if not ok or type(BattleState)~="table" or type(BattleState.update)~="function" then return false end
  local inner=BattleState.update
  R.nativeBattleUpdateInner=inner
  R.nativeBattleUpdateWrapper=function(self,dt,...)
    if self~=R.activeBattle or not realtimeOwnsBattleInput(self.game) then return inner(self,dt,...) end

    -- IMPORTANT: quarantine ONLY the two hidden command-menu phases. Trainer
    -- replacement, faint/EXP, SHIFT/SET and victory are all driven by the
    -- authoritative message queue. Wrapping those phases here can swallow the
    -- transition that pushes the YES/NO ChoiceBox or the next enemy send-out.
    -- Message A/B auto-advance is already handled by updateQueue + input.step.
    if self.phase~="menu" and self.phase~="moveSelect" then
      return inner(self,dt,...)
    end

    -- If an old/raw input edge ever put the hidden engine menu into moveSelect,
    -- immediately return it to the neutral command phase. Realtime attacks never
    -- use this phase; they call executeAction/performMove only after spatial hit.
    if self.phase=="moveSelect" and not self.__xdRealtimeAllowNativeMenu then
      self.phase="menu";self.moveSwapIndex=nil
    end
    if self.phase=="menu" then self.menuIndex=1 end

    local input=self.game and self.game.input
    if type(input)~="table" then return inner(self,dt,...) end
    local wasPressed,isDown,wasReleased=input.wasPressed,input.isDown,input.wasReleased
    if type(wasPressed)=="function" then
      input.wasPressed=function(obj,key,...)
        local k=tostring(key):lower()
        if self.phase=="messages" and (k=="a" or k=="b") then return true end
        if NATIVE_BATTLE_INPUT_BLOCK[k] then return false end
        return wasPressed(obj,key,...)
      end
    end
    if type(isDown)=="function" then
      input.isDown=function(obj,key,...)
        local k=tostring(key):lower()
        if self.phase=="messages" and (k=="a" or k=="b") then return true end
        if NATIVE_BATTLE_INPUT_BLOCK[k] then return false end
        return isDown(obj,key,...)
      end
    end
    if type(wasReleased)=="function" then
      input.wasReleased=function(obj,key,...)
        if NATIVE_BATTLE_INPUT_BLOCK[tostring(key):lower()] then return false end
        return wasReleased(obj,key,...)
      end
    end
    local results={pcall(inner,self,dt,...)}
    input.wasPressed,input.isDown,input.wasReleased=wasPressed,isDown,wasReleased
    local passed=table.remove(results,1)
    if not passed then error(results[1],0) end
    return (table.unpack or unpack)(results)
  end
  BattleState.update=R.nativeBattleUpdateWrapper
  R.hardMenuQuarantine=true
  return true
end

  function B.install()
    installRawRealtimeInputCapture()
    installRealtimeMessageAdvanceBridge()
    installRealtimeNativeFxSuppression()
    installTrainerItemActionBridge()
    installRealtimeTrainerReplacementBridge()
    installHardRealtimeMenuQuarantine()
    return true
  end
  function B.wrapEngineStep(next,game,dt)
    return callEngineStepWithRealtimeInputBlocked(next,game,dt)
  end
  function B.afterEngineStep(game)
    if R.activeBattle then pcall(serviceRealtimeQueueUi,game) end
  end
  function B.onDispatch(ctx,name,payload)
    local rt=V and V.RealtimeBattle
    if rt and type(rt.event)=="function" then pcall(rt.event,rt,ctx,name,payload) end
  end
  function B.statusExtras()
    return {
      rawRealtimeInputCapture=R.rawInputCaptureInstalled==true,
      hardMenuQuarantine=R.hardMenuQuarantine==true,
      realtimeWheelBuffered=tonumber(R.realtimeWheelY) or 0,
      nativeBattleFlashSuppressed=R.nativeFxBridge==true,
      trainerItemActionBridge=R.trainerItemBridge==true,
      trainerReplacementBridge=R.trainerReplacementBridge==true,
      realtimeQueueUiBridge=true,
      statBoxAutoDismissed=R.statBoxAutoDismissed or 0,
      trainerChoiceAutoDeclined=R.trainerChoiceAutoDeclined or 0,
      nativeModalName=R.nativeModalName,
    }
  end
  return B
end
return B