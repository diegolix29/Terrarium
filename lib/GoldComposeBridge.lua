-- Gold/Silver official render.compose bridge.
--
-- v0.1.74 fixes Gold's START/menu overlay path correctly.  Gen 2 Game2.lua
-- composites the overworld and stack UI into ONE scene canvas; unlike Gen 1,
-- it does not expose a separable worldOverride pass.  A voxel frame therefore
-- has to own the Gold compose window, then re-draw only the live Gold stack on
-- top using the exact transform Game2:drawScene() uses for overworld overlays.
--
-- This keeps the voxel overworld visible while START/dialog/menu overlays are
-- open without painting Gold's already-composited vanilla 2D world back over it.
local mod, VoxelBridge, WildsBridge, PipelineBridge = ...

local function customUIEnabled()
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return true end
  local ok, value = pcall(options.get, options, "customUI")
  if not ok or value == nil then return true end
  return value ~= false
end

local function world3DEnabled()
  if VoxelBridge and type(VoxelBridge.world3DEnabled) == "function" then
    local ok, enabled = pcall(VoxelBridge.world3DEnabled)
    if ok then return enabled == true end
  end
  if VoxelBridge and type(VoxelBridge.voxelModeEnabled) == "function" then
    local ok, enabled = pcall(VoxelBridge.voxelModeEnabled)
    if ok then return enabled == true end
  end
  local options = mod and mod.options
  if options and type(options.get) == "function" then
    local ok, value = pcall(options.get, options, "voxel3d")
    if ok and value ~= nil then return value ~= false end
  end
  return true
end

local Bridge = {
  installed = false,
  frames = 0,
  worldFrames = 0,
  voxelFrames = 0,
  voxelOverlayFrames = 0,
  goldOverlayRedrawFrames = 0,
  goldOverlayStatesDrawn = 0,
  worldOverrideFrames = 0,
  legacyDirectFrames = 0,
  spriteFallbackFrames = 0,
  wildSpritesDrawn = 0,
  passthroughFrames = 0,
  battleFrames = 0,
  battleFallbackFrames = 0,
  pipelineFrames = 0,
  lastVoxelError = nil,
  lastOverlayError = nil,
  lastWildError = nil,
}

local function resolveGame(host, ctx)
  -- Current Gold passes Game2 itself as the render.compose hook owner.  Prefer
  -- that object whenever generation==2 so its real stack/world are used.
  if type(host) == "table" and host.stack then
    if ctx and tonumber(ctx.generation) == 2 and host.world then return host end
    if host.world or host.overworld then return host end
  end

  -- Compatibility only: older experimental hosts may not pass Game2 directly.
  local ok2, Game2 = pcall(require, "src.core.Game2")
  if ok2 and type(Game2) == "table" and Game2.stack and Game2.world then
    return Game2
  end
  local ok1, Game = pcall(require, "src.core.Game")
  if ok1 and type(Game) == "table" then return Game end
  return nil
end

local function resolveWorld(game, host)
  local world = game and game.world
  if type(world) == "table" and world.map then return world end

  world = game and game.overworld
  if type(world) == "table" and world.map then return world end

  world = host and host.world
  if type(world) == "table" and world.map then return world end

  world = host and host.overworld
  if type(world) == "table" and world.map then return world end

  local api = mod.world
  if api and type(api.overworld) == "function" then
    local ok, publicWorld = pcall(api.overworld, api)
    if ok and type(publicWorld) == "table" and publicWorld.map then return publicWorld end
  end
  return nil
end

local function stackTop(game)
  local stack = game and game.stack
  if not stack or type(stack.top) ~= "function" then return nil end
  local ok, top = pcall(stack.top, stack)
  if ok then return top end
  return nil
end

-- Gold marks OPTIONS / PACK / POKEGEAR / TRAINER CARD / SAVE and several other
-- pages as widescreen/full-screen screens. That makes Game2 report
-- ctx.worldActive=false even after our pause skin sets the instance non-opaque,
-- so the compose hook used to receive the page's black surround instead of the
-- live overworld. A pause-skin chain is an explicit promise from our menu
-- patcher that this page belongs over the paused world. Detect that chain on
-- the stack and render the voxel world behind it exactly like MOD SETTINGS.
local function pauseBackdropRequested(game)
  if not customUIEnabled() then return false end
  local stack = game and game.stack
  local states = stack and stack.states
  if type(states) ~= "table" then return false end
  for i = #states, 1, -1 do
    local state = states[i]
    if type(state) == "table" and state._stadium2PauseSkinChain == true then
      return true
    end
    -- Stop at a genuinely opaque unrelated page. We never tunnel through a
    -- battle/title/cutscene just because an old hidden state lower in the stack
    -- happened to have been opened from pause earlier.
    if state and state.isOpaque == true then return false end
  end
  return false
end

local function drawCanvasFull(canvas, ctx)
  if not canvas then return false end
  local G = love.graphics
  local ww, wh = tonumber(ctx and ctx.ww), tonumber(ctx and ctx.wh)
  if not (ww and wh and ww > 0 and wh > 0) then ww, wh = G.getDimensions() end
  local cw, ch = canvas:getDimensions()
  if not (cw and ch and cw > 0 and ch > 0) then return false end
  G.setColor(1, 1, 1, 1)
  G.draw(canvas, 0, 0, 0, ww / cw, wh / ch)
  return true
end

local function installWorldOverride(host, ctx, canvas)
  -- Gen 1 / experimental compatibility only.  Current Gold Game2 deliberately
  -- has no setWorldOverride because worldCanvas and uiCanvas are the same scene.
  local renderer = (ctx and ctx.renderer)
    or (type(host) == "table" and host.setWorldOverride and host)
  if not (renderer and type(renderer.setWorldOverride) == "function") then
    return false
  end
  local ok = pcall(renderer.setWorldOverride, renderer, canvas)
  return ok and renderer.worldOverride ~= nil
end

local function goldOverlayStateCount(game)
  local stack = game and game.stack
  local states = stack and stack.states
  if type(states) ~= "table" or #states == 0 then return 0 end

  local base = 1
  if type(stack.visibleBase) == "function" then
    local ok, value = pcall(stack.visibleBase, stack)
    if ok and tonumber(value) then
      base = math.max(1, math.min(#states, math.floor(tonumber(value))))
    end
  end
  return math.max(0, #states - base + 1)
end

local function drawGoldOverlayStack(game, world, ctx)
  local stack = game and game.stack
  if not stackTop(game) then return true, 0 end
  if not (stack and type(stack.draw) == "function") then
    return false, 0, "Gold stack has no draw()"
  end
  if not (world and type(world.fitScale) == "function") then
    return false, 0, "Gold world has no fitScale()"
  end

  local ww, wh = tonumber(ctx and ctx.ww), tonumber(ctx and ctx.wh)
  if not (ww and wh and ww > 0 and wh > 0) then
    ww, wh = love.graphics.getDimensions()
  end

  local okScale, scale = pcall(world.fitScale, world)
  scale = okScale and tonumber(scale) or nil
  if not (scale and scale > 0) then
    return false, 0, "Gold world fitScale() returned an invalid scale"
  end

  -- Mirror Game2:drawScene's live-overworld overlay branch exactly:
  -- center a 160x144 UI at world:fitScale(), then draw the visible stack.
  local G = love.graphics
  local okDraw, drawErr = pcall(function()
    G.push("all")
    G.origin()
    G.translate(math.floor((ww - 160 * scale) / 2),
                math.floor((wh - 144 * scale) / 2))
    G.scale(scale, scale)
    stack:draw()
    G.pop()
  end)
  if not okDraw then
    -- pcall can catch an error after push() but before pop(); restore one level
    -- best-effort so the compose hook never leaves the engine in a poisoned state.
    pcall(G.pop)
    return false, 0, tostring(drawErr)
  end
  return true, goldOverlayStateCount(game)
end

-- Draw-local native-2D guard. Gen1Recomp permits one active drawWorld pipeline,
-- and optional companion mods (notably Character Selector / voxel providers)
-- may still have theirs enabled even when THIS mod's 3D VOXEL WORLD switch is
-- OFF. World:draw() would otherwise invoke that external pipeline and the user
-- would still see 3D. Temporarily zero every active world pipeline only for the
-- native redraw, then restore the exact live levels without syncing options.
-- This never rewrites another mod's saved preference.
local function withNativeWorldPipelinesSuspended(body)
  local okP, Pipelines = pcall(require, "src.render.Pipelines")
  if not (okP and type(Pipelines) == "table"
      and type(Pipelines.list) == "function"
      and type(Pipelines.level) == "function"
      and type(Pipelines.setLevel) == "function") then
    return pcall(body)
  end

  local saved = {}
  local okList, entries = pcall(Pipelines.list)
  if okList and type(entries) == "table" then
    for _, entry in ipairs(entries) do
      local id = entry and entry.id
      local def = entry and entry.def
      if id and type(def) == "table" and type(def.drawWorld) == "function" then
        local okLevel, level = pcall(Pipelines.level, id)
        level = okLevel and tonumber(level) or 0
        if level and level > 0 then
          saved[#saved + 1] = { id = id, level = level }
          pcall(Pipelines.setLevel, id, 0)
        end
      end
    end
  end

  local okBody, a, b, c = pcall(body)
  -- Restore after the body even if drawing throws. There can only be one live
  -- world pipeline under the engine contract, but iterate in reverse so this
  -- remains correct if an older host allowed more than one level to linger.
  for i = #saved, 1, -1 do
    pcall(Pipelines.setLevel, saved[i].id, saved[i].level)
  end
  if #saved > 0 then
    Bridge.native2DPipelineSuppressions = (Bridge.native2DPipelineSuppressions or 0) + 1
  end
  return okBody, a, b, c
end

local function drawGoldNative2DFrame(game, world, ctx)
  if not (world and type(world.draw) == "function") then
    return false, 0, "Gold 2D world has no draw()", 0
  end
  local G = love and love.graphics
  if not G then return false, 0, "graphics unavailable", 0 end
  local overlayCount, wildDrawn = 0, 0
  local ok, drawErr = pcall(function()
    G.push("all")
    G.origin()
    -- Draw Gold's authoritative 2D map first, then the mod-owned roaming
    -- Pokemon fallback, then the stack. This preserves native layer order and
    -- prevents visible Wilds from being painted on top of START/custom menus.
    local okNative, nativeErr = withNativeWorldPipelinesSuspended(function()
      world:draw()
    end)
    if not okNative then error(nativeErr or "native 2D world draw failed", 0) end
    if WildsBridge and type(WildsBridge.drawFallback) == "function" then
      local okWild, drawn, wildErr = pcall(WildsBridge.drawFallback, world)
      if okWild then
        wildDrawn = tonumber(drawn) or 0
        Bridge.lastWildError = wildErr
      else
        Bridge.lastWildError = tostring(drawn)
      end
    end
    local okOverlay, count, overlayErr = drawGoldOverlayStack(game, world, ctx)
    if not okOverlay then error(overlayErr or "Gold 2D overlay redraw failed", 0) end
    overlayCount = tonumber(count) or 0
    G.pop()
  end)
  if not ok then
    pcall(G.pop)
    return false, 0, tostring(drawErr), wildDrawn
  end
  return true, overlayCount, nil, wildDrawn
end

local function drawGoldVoxelFrame(canvas, game, world, ctx)
  local G = love.graphics
  local ok, result, overlayCount, overlayErr = pcall(function()
    G.push("all")
    G.origin()
    if not drawCanvasFull(canvas, ctx) then
      G.pop()
      return false, 0, "voxel renderer returned an unusable canvas"
    end

    local okOverlay, count, err = drawGoldOverlayStack(game, world, ctx)
    if okOverlay and VoxelBridge and type(VoxelBridge.drawCameraSlider) == "function" then
      -- Android-only camera-mode slider. Drawn after Gold's stack so the
      -- control remains visible over the voxel world, but the slider itself
      -- hides whenever a menu/overlay is on top (its visibility gate lives in
      -- GoldVoxelBridge). Desktop never draws it and keeps F6 instead.
      pcall(VoxelBridge.drawCameraSlider, ctx)
    end
    G.pop()
    if not okOverlay then return false, 0, err end
    return true, count, nil
  end)

  if not ok then
    pcall(G.pop)
    return false, 0, tostring(result)
  end
  return result, overlayCount or 0, overlayErr
end

local function drawGoldBattleFrame(shot, ctx, game)
  local canvas = shot and shot.canvas
  local ui = ctx and ctx.sceneCanvas
  if not (canvas and ui) then return false end
  local G = love.graphics
  local ok, err = pcall(function()
    G.push("all")
    G.origin()
    G.setBlendMode("alpha")
    if not drawCanvasFull(canvas, ctx) then error("unusable 3D battle canvas") end

    -- v0.2.31: normal live 3D battles no longer composite Gold's 160x144
    -- battle screen at all. BattleControllerUI owns the complete battle HUD
    -- (names/HP/message/commands/move list) directly on the window-sized 3D
    -- frame. Gold still runs underneath and owns every rule/timer/action.
    --
    -- Separate pushed screens such as PACK/PARTY are not BattleState objects,
    -- so they deliberately fall through to the native UI canvas below.
    local controllerUI = mod.exports and mod.exports.battleControllerUI
    if controllerUI and not controllerUI.installed
        and type(controllerUI.install) == "function" then
      pcall(controllerUI.install, game)
    end
    local top = stackTop(game)
    local screen = top
    if VoxelBridge and type(VoxelBridge.battleScreen) == "function" then
      local okLive, live = pcall(VoxelBridge.battleScreen)
      if okLive and type(live) == "table" then screen = live end
    end
    -- Only replace the battle canvas while the live BattleState itself is the
    -- visible top state. PACK/PARTY and other pushed screens remain native.
    -- Compare the underlying logic-battle too because some engine revisions
    -- wrap the BattleState for presentation while retaining the same battle.
    local visibleBattle = (top == screen)
      or (type(top) == "table" and type(screen) == "table"
          and top.battle ~= nil and top.battle == screen.battle)
    local owned = false
    if visibleBattle and controllerUI and type(controllerUI.owns) == "function" then
      local okOwn, yes = pcall(controllerUI.owns, screen)
      owned = okOwn and yes and true or false
    end

    local customDrawn = false
    local sceneOwnsHud = false
    if controllerUI and type(controllerUI.sceneHasHud) == "function" then
      local okScene, yes = pcall(controllerUI.sceneHasHud)
      sceneOwnsHud = okScene and yes and true or false
    end
    if sceneOwnsHud then
      -- The HUD is already baked into shot.canvas by VoxelScene.render().
      customDrawn = true
    elseif owned and controllerUI then
      -- Compatibility/fail-open path for an engine revision that bypasses the
      -- live VoxelScene insertion point.
      if type(controllerUI.update) == "function" then pcall(controllerUI.update, game) end
      local draw = controllerUI.drawFull or controllerUI.draw
      if type(draw) == "function" then
        local okDraw, yes = pcall(draw, screen, ctx)
        customDrawn = okDraw and yes and true or false
      end
    end

    -- Fail open. If the replacement HUD cannot draw on a future engine build,
    -- put Gold's own canvas back instead of leaving a playable but invisible UI.
    if not customDrawn then
      if not drawCanvasFull(ui, ctx) then error("unusable Gold battle UI canvas") end
    end
    G.pop()
  end)
  if not ok then
    pcall(G.pop)
    Bridge.lastBattleError = tostring(err)
    return false
  end
  Bridge.lastBattleError = nil
  return true
end

local function composeCore(nextFn, host, ctx)
  Bridge.frames = Bridge.frames + 1

  -- Battle updates must run even though Game2 reports worldActive=false for an
  -- opaque BattleState. Pause-skinned full-screen Gold pages are a different
  -- case: they intentionally want the live voxel overworld behind their glass
  -- UI even though Game2's widescreen-page branch reports worldActive=false.
  local game = resolveGame(host, ctx)
  local pauseBackdrop = pauseBackdropRequested(game)
  local worldActive = (ctx and ctx.worldActive == true) or pauseBackdrop
  if pauseBackdrop then
    Bridge.pauseBackdropFrames = (Bridge.pauseBackdropFrames or 0) + 1
  end
  if VoxelBridge and type(VoxelBridge.setGame) == "function" then
    pcall(VoxelBridge.setGame, game)
  end
  if VoxelBridge and type(VoxelBridge.updateBattle) == "function" then
    pcall(VoxelBridge.updateBattle, 1 / 60)
  end
  if not worldActive and VoxelBridge
     and type(VoxelBridge.battleShot) == "function" then
    local okShot, shot = pcall(VoxelBridge.battleShot)
    if okShot and shot and shot.canvas then
      if drawGoldBattleFrame(shot, ctx, game) then
        Bridge.battleFrames = Bridge.battleFrames + 1
        return true
      end
      Bridge.battleFallbackFrames = Bridge.battleFallbackFrames + 1
    end
  end

  -- v0.4.16: native 2D is a first-class presentation mode, not "voxel
  -- failed this frame". Check this BEFORE consuming render_pipelines output:
  -- a mode change can happen between drawWorld and compose, and a stale 3D
  -- renderedForCompose bit must never win over an explicit 2D selection.
  -- Do not call VoxelScene at all while the master switch
  -- is OFF. Gold remains the world owner; this bridge only adds mod-owned
  -- visible Wilds in the correct layer and redraws custom pause overlays when
  -- Game2's full-screen classification hides the live world behind them.
  if not world3DEnabled() then
    -- Discard a drawWorld result produced earlier in this same frame before the
    -- option changed. The bit is edge-triggered; leaving it armed could make
    -- the first later 3D frame consume an obsolete canvas.
    if PipelineBridge and type(PipelineBridge.consumeRenderedFrame) == "function" then
      pcall(PipelineBridge.consumeRenderedFrame)
    end
    if not worldActive then
      Bridge.passthroughFrames = Bridge.passthroughFrames + 1
      return nextFn(host, ctx)
    end
    local world2d = resolveWorld(game, host)
    if not (world2d and world2d.map) then
      Bridge.passthroughFrames = Bridge.passthroughFrames + 1
      return nextFn(host, ctx)
    end
    -- Always own the live world frame in 2D. This is not just for Wilds or a
    -- pause backdrop: an optional companion drawWorld pipeline may already have
    -- painted a voxel canvas into ctx.sceneCanvas before compose. Redrawing the
    -- authoritative Gold world with world pipelines suspended guarantees that
    -- 3D VOXEL WORLD = OFF really means native 2D.
    local ok2d, overlayCount, err2d, wildDrawn = drawGoldNative2DFrame(
      game, world2d, ctx)
    if ok2d then
      Bridge.native2DFrames = (Bridge.native2DFrames or 0) + 1
      Bridge.native2DOverlayFrames = (Bridge.native2DOverlayFrames or 0)
        + ((stackTop(game) ~= nil) and 1 or 0)
      Bridge.wildSpritesDrawn = Bridge.wildSpritesDrawn + (tonumber(wildDrawn) or 0)
      Bridge.lastOverlayError = nil
      return true
    end
    Bridge.lastOverlayError = err2d
    Bridge.passthroughFrames = Bridge.passthroughFrames + 1
    return nextFn(host, ctx)
  end


  -- Current desktop Gold renders the voxel world earlier through the official
  -- render_pipelines drawWorld seam. In that case sceneCanvas already contains
  -- the 3D world plus Gold's normal overlay stack; rendering VoxelScene again
  -- here would double the GPU work and can overwrite the pipeline composite.
  -- Older Gold builds never call the drawWorld callback, so this bit stays
  -- false and the long-standing compose renderer below remains the fallback.
  if PipelineBridge and type(PipelineBridge.consumeRenderedFrame) == "function" then
    local okPipeline, rendered = pcall(PipelineBridge.consumeRenderedFrame)
    if okPipeline and rendered then
      Bridge.pipelineFrames = Bridge.pipelineFrames + 1
      Bridge.voxelFrames = Bridge.voxelFrames + 1
      Bridge.lastVoxelError = nil
      local result = nextFn(host, ctx)
      if VoxelBridge and type(VoxelBridge.drawCameraSlider) == "function" then
        pcall(VoxelBridge.drawCameraSlider, ctx)
      end
      return result
    end
  end

  -- Game2 marks only its live overworld branch worldActive=true.  Opaque/full-
  -- screen Gold pages are already excluded by Game2 before this hook runs.
  if not worldActive then
    Bridge.passthroughFrames = Bridge.passthroughFrames + 1
    return nextFn(host, ctx)
  end

  local world = resolveWorld(game, host)
  if not (world and world.map) then
    Bridge.passthroughFrames = Bridge.passthroughFrames + 1
    return nextFn(host, ctx)
  end

  Bridge.worldFrames = Bridge.worldFrames + 1
  local isGold = tonumber(ctx.generation) == 2
  local hasOverlay = stackTop(game) ~= nil

  if VoxelBridge and type(VoxelBridge.renderFrame) == "function" then
    -- Hand the renderer the ACTUAL live Game2 owner. Gold's World is not a
    -- Gen-1 singleton, and first/third-person camera gates/input need the same
    -- stack object whose overlays are composited below.
    local okVoxel, canvas, voxelErr = pcall(VoxelBridge.renderFrame, world, ctx)
    if okVoxel and canvas then
      if isGold then
        -- Gold's sceneCanvas/worldCanvas/uiCanvas are the same finished texture.
        -- Own the compose frame, paint voxels first, then re-draw ONLY the stack
        -- UI at the same transform Game2 uses.  This is the v0.1.74 pause fix.
        local okFrame, overlayCount, overlayErr = drawGoldVoxelFrame(
          canvas, game, world, ctx)
        if okFrame then
          Bridge.voxelFrames = Bridge.voxelFrames + 1
          Bridge.legacyDirectFrames = Bridge.legacyDirectFrames + 1
          if hasOverlay then
            Bridge.voxelOverlayFrames = Bridge.voxelOverlayFrames + 1
            Bridge.goldOverlayRedrawFrames = Bridge.goldOverlayRedrawFrames + 1
            Bridge.goldOverlayStatesDrawn = Bridge.goldOverlayStatesDrawn
              + (tonumber(overlayCount) or 0)
          end
          Bridge.lastVoxelError = nil
          Bridge.lastOverlayError = nil
          return true
        end
        voxelErr = overlayErr or "Gold voxel/UI composite failed"
        Bridge.lastOverlayError = voxelErr
      else
        -- Gen 1 / experimental compatibility path where separate world + UI
        -- passes really do exist.
        if installWorldOverride(host, ctx, canvas) then
          Bridge.voxelFrames = Bridge.voxelFrames + 1
          Bridge.worldOverrideFrames = Bridge.worldOverrideFrames + 1
          if hasOverlay then Bridge.voxelOverlayFrames = Bridge.voxelOverlayFrames + 1 end
          Bridge.lastVoxelError = nil
          return nextFn(host, ctx)
        end
        if not hasOverlay and drawCanvasFull(canvas, ctx) then
          Bridge.voxelFrames = Bridge.voxelFrames + 1
          Bridge.legacyDirectFrames = Bridge.legacyDirectFrames + 1
          Bridge.lastVoxelError = nil
          return true
        end
        voxelErr = hasOverlay
          and "legacy compose API cannot preserve UI over direct voxel canvas"
          or "voxel renderer returned an unusable canvas"
      end
    elseif not okVoxel then
      voxelErr = tostring(canvas)
    end
    Bridge.lastVoxelError = voxelErr
  end

  -- If voxel rendering is unavailable, preserve Gold's already-composited scene
  -- and the existing visible-Wilds sprite fallback behavior.
  local visible = WildsBridge and type(WildsBridge.visibleEntities) == "function"
    and WildsBridge.visibleEntities(world) or {}
  if type(visible) == "table" and #visible > 0
     and ctx.sceneCanvas and WildsBridge
     and type(WildsBridge.drawFallback) == "function" then
    drawCanvasFull(ctx.sceneCanvas, ctx)
    local okWild, drawn, wildErr = pcall(WildsBridge.drawFallback, world)
    if okWild then
      Bridge.spriteFallbackFrames = Bridge.spriteFallbackFrames + 1
      Bridge.wildSpritesDrawn = Bridge.wildSpritesDrawn + (tonumber(drawn) or 0)
      Bridge.lastWildError = wildErr
    else
      Bridge.lastWildError = tostring(drawn)
    end
    return true
  end

  Bridge.passthroughFrames = Bridge.passthroughFrames + 1
  return nextFn(host, ctx)
end

local function isAndroid()
  -- love.system is a blocked proxy member in current mod sandboxes, so even
  -- reading it must be protected. Engine Platform is the authoritative path.
  local okPlatform, Platform = pcall(require, "src.core.Platform")
  if okPlatform and type(Platform) == "table" and type(Platform.detect) == "function" then
    local okDetect, info = pcall(Platform.detect)
    if okDetect and type(info) == "table" and type(info.os) == "string" then
      return string.lower(info.os) == "android"
    end
  end
  local ok, name = pcall(function()
    local sys = love and love.system
    return sys and sys.getOS and sys.getOS()
  end)
  if ok and type(name) == "string" then return string.lower(name) == "android" end
  local okGlobal, platform = pcall(rawget, _G, "PLATFORM")
  return okGlobal and type(platform) == "string"
    and string.lower(platform) == "android"
end

local function screenFlipEnabled()
  if not isAndroid() then return false end
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return false end
  local ok, value = pcall(options.get, options, "screenFlip")
  return ok and value == true
end

local flipCanvas, flipW, flipH
local function ensureFlipCanvas(w, h)
  if flipCanvas and flipW == w and flipH == h then return flipCanvas end
  local G = love and love.graphics
  if not (G and type(G.newCanvas) == "function") then return nil end
  local ok, canvas = pcall(G.newCanvas, w, h)
  if not ok or not canvas then return nil end
  flipCanvas, flipW, flipH = canvas, w, h
  if type(canvas.setFilter) == "function" then pcall(canvas.setFilter, canvas, "nearest", "nearest") end
  return canvas
end

-- Screen flip is applied around the *entire* render.compose chain. This makes
-- the setting rotate the finished Android presentation rather than only the
-- voxel world, so Gold menus, Stadium battle HUD and fallback 2D screens all
-- keep the same orientation. It is intentionally a presentation transform:
-- when the physical device itself is held in reverse-landscape, Android's
-- locked coordinate frame already maps touches to the corresponding rotated
-- on-screen controls.
local function compose(nextFn, host, ctx)
  -- v0.2.56: Android screenFlip is owned by AndroidFullFrameFlip around the
  -- entire Game2:draw call.  Keeping a second rotation here would double-flip
  -- the world while leaving Game2's later HUD/touch layer inconsistent.
  return composeCore(nextFn, host, ctx)
end

function Bridge.install()
  if Bridge.installed then return true end
  if not (mod.hooks and type(mod.hooks.wrap) == "function") then
    return false, "mod.hooks:wrap is unavailable"
  end
  local ok, err = pcall(function()
    mod.hooks:wrap("render.compose", compose, 1000)
  end)
  if not ok then return false, tostring(err) end
  Bridge.installed = true
  if mod.log and type(mod.log.info) == "function" then
    pcall(mod.log.info, mod.log,
      "Gold render.compose bridge installed (voxel + Gold overlay-stack redraw)")
  end
  return true
end

function Bridge.status()
  return {
    installed = Bridge.installed,
    frames = Bridge.frames,
    worldFrames = Bridge.worldFrames,
    voxelFrames = Bridge.voxelFrames,
    voxelOverlayFrames = Bridge.voxelOverlayFrames,
    goldOverlayRedrawFrames = Bridge.goldOverlayRedrawFrames,
    goldOverlayStatesDrawn = Bridge.goldOverlayStatesDrawn,
    worldOverrideFrames = Bridge.worldOverrideFrames,
    legacyDirectFrames = Bridge.legacyDirectFrames,
    spriteFallbackFrames = Bridge.spriteFallbackFrames,
    wildSpritesDrawn = Bridge.wildSpritesDrawn,
    battleFrames = Bridge.battleFrames,
    battleFallbackFrames = Bridge.battleFallbackFrames,
    pipelineFrames = Bridge.pipelineFrames,
    passthroughFrames = Bridge.passthroughFrames,
    native2DFrames = Bridge.native2DFrames or 0,
    native2DOverlayFrames = Bridge.native2DOverlayFrames or 0,
    native2DPipelineSuppressions = Bridge.native2DPipelineSuppressions or 0,
    lastVoxelError = Bridge.lastVoxelError,
    lastOverlayError = Bridge.lastOverlayError,
    lastWildError = Bridge.lastWildError,
    lastBattleError = Bridge.lastBattleError,
    pauseBackdropFrames = Bridge.pauseBackdropFrames or 0,
    flipFrames = Bridge.flipFrames or 0,
    lastFlipError = Bridge.lastFlipError,
  }
end

Bridge._compose = compose
Bridge._pauseBackdropRequested = pauseBackdropRequested
return Bridge
