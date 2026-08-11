-- Full controller-native battle HUD for Gold live 3D battles.
--
-- Gold still owns battle rules, timing, HP, move legality, inventory, party
-- switching and outcomes. This module owns the NORMAL live-3D battle screen's
-- presentation and its four-command controller shortcuts:
--
--     Top face / Up      PKMN
--     Left face / Left   FIGHT
--     Right face / Right RUN
--     Bottom face / Down PACK
--
-- Face-button names/glyphs follow CONTROLLER LAYOUT (PlayStation/Xbox/Switch).
--
-- Left stick/WASD are reserved for direct Pokemon movement. The right stick is
-- consumed by BattleCinematic. The real controller D-pad remains available to
-- Gold's move/item/party submenus.
local V = ...
local M = {
  installed = false,
  shortcuts = 0,
  draws = 0,
  fullDraws = 0,
  sceneDraws = 0,
  sceneDrawn = false,
}

local installedGame = nil
local installedInput = nil
local fonts = {}
local blockedPadRelease = setmetatable({}, { __mode = "k" })
local blockedRawRelease = setmetatable({}, { __mode = "k" })
local blockedKeyRelease = {}
local polledPadHeld = setmetatable({}, { __mode = "k" })
-- v0.2.74: direct battle shortcuts are armed only after the command panel has
-- actually been drawn at least once for the current menu opening.  Gold can
-- switch phase to "menu" during a fixed step before the next render.  Without
-- this latch, a face-button edge in that tiny window selects an invisible
-- command and the panel appears only after the action has already fired.
local commandPresented = setmetatable({}, { __mode = "k" })
-- Automatic intro-page advancement is per BattleState so a new encounter never
-- inherits the previous one's prompt signature/counter.
local introAuto = setmetatable({}, { __mode = "k" })
local AUTO_INTRO_HOLD_FRAMES = 6
local NIL_PAD = {}
local function padKey(joystick) return joystick or NIL_PAD end

-- v0.2.35: PACK and PKMN no longer push Gold's full-screen menus during the
-- Stadium battle presentation.  They stay on the live 3D battlefield and use
-- the same four-row glass list language as the move picker.  Gold still owns
-- every actual battle action underneath: this state is presentation + cursor
-- only, and valid choices are handed back to BattleState:submit/useItem/
-- applyPartyItem.
local overlay = nil
local itemEffectsCache = nil
local partyPreviewCache = nil

local function customUIEnabled()
  local mod = V and V.mod
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return true end
  local ok, value = pcall(options.get, options, "customUI")
  if not ok or value == nil then return true end
  return value ~= false
end

local function battleCommandsEnabled()
  if not customUIEnabled() then return false end
  local mod = V and V.mod
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return true end
  local ok, value = pcall(options.get, options, "battleCommands")
  if not ok or value == nil then return true end
  return value ~= false
end

local function battleShortcutMode()
  local mod = V and V.mod
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return "face" end
  local ok, value = pcall(options.get, options, "battleShortcutMode")
  value = ok and tostring(value or "face"):lower() or "face"
  if value == "native" or value == "off" then return "native" end
  if value == "dpad" or value == "arrows" then return "dpad" end
  return "face"
end

local function controllerLayoutModule()
  local mod = V and V.mod
  local C = mod and mod.exports and mod.exports.controllerLayout
  return type(C) == "table" and C or nil
end

local function controllerPrompt(text)
  local C = controllerLayoutModule()
  if C and type(C.prompt) == "function" then
    local ok, value = pcall(C.prompt, text)
    if ok and value then return value end
  end
  return tostring(text or "")
end

local function controllerFace(role)
  local C = controllerLayoutModule()
  if C and type(C.face) == "function" then
    local ok, value = pcall(C.face, role)
    if ok and type(value) == "table" then return value end
  end
  local fallback = {
    west={logical="x",label="SQUARE",kind="square"},
    north={logical="y",label="TRIANGLE",kind="triangle"},
    south={logical="a",label="CROSS",kind="cross"},
    east={logical="b",label="CIRCLE",kind="circle"},
  }
  return fallback[role] or fallback.south
end

local function controllerLayoutName()
  local C = controllerLayoutModule()
  if C and type(C.layoutName) == "function" then
    local ok, value = pcall(C.layoutName)
    if ok and value then return tostring(value) end
  end
  return "PLAYSTATION"
end

local function confirmPadButton()
  local C = controllerLayoutModule()
  if C and type(C.confirmButton) == "function" then
    local ok, value = pcall(C.confirmButton)
    if ok and (value == "a" or value == "b") then return value end
  end
  return "a"
end

local function cancelPadButton()
  local C = controllerLayoutModule()
  if C and type(C.cancelButton) == "function" then
    local ok, value = pcall(C.cancelButton)
    if ok and (value == "a" or value == "b") then return value end
  end
  return "b"
end

local function overlayPadControl(button)
  if button == confirmPadButton() then return "confirm" end
  if button == cancelPadButton() then return "cancel" end
  local dpad = { dpup="up", dpdown="down", dpleft="left", dpright="right" }
  return dpad[button]
end

local function rawOverlayControl(button)
  local C = controllerLayoutModule()
  local switch = false
  if C and type(C.current) == "function" then
    local ok, value = pcall(C.current)
    switch = ok and value == "switch"
  end
  if switch then
    if button == 2 then return "confirm" end
    if button == 1 then return "cancel" end
  else
    if button == 1 then return "confirm" end
    if button == 2 then return "cancel" end
  end
  return nil
end

-- Forward declaration: the same visual-ready test used by the HUD is also the
-- safety gate for direct shortcuts.  BattleState can keep phase == "menu"
-- while a message/text step is still on screen, so phase alone is NOT enough.
local commandReady
local function commandVisualReady(screen)
  return screen ~= nil and tostring(screen.phase or "") == "menu"
    and commandReady ~= nil and commandReady(screen) == true
end

local function commandInputReady(screen)
  return commandVisualReady(screen) and commandPresented[screen] == true
end

local function commandWarming(screen)
  return commandVisualReady(screen) and commandPresented[screen] ~= true
end

local function partyPreview()
  if partyPreviewCache == false then return nil end
  if partyPreviewCache then return partyPreviewCache end
  local ok, got = pcall(V.require, "PartyModelPreview")
  partyPreviewCache = (ok and type(got) == "table") and got or false
  if not partyPreviewCache then M.lastPartyPreviewError = tostring(got) end
  return partyPreviewCache or nil
end

local function releasePartyPreview(screen)
  local preview = partyPreviewCache
  if preview and type(preview.release) == "function" and screen then
    pcall(preview.release, screen)
  end
end

local function itemEffects()
  if itemEffectsCache ~= nil then return itemEffectsCache or nil end
  local ok, got = pcall(require, "src.core.gen2.ItemEffects")
  itemEffectsCache = ok and got or false
  return itemEffectsCache or nil
end

local function overlayFor(screen)
  if overlay and overlay.screen == screen then return overlay end
  return nil
end

local function closeOverlay(screen)
  if not screen or (overlay and overlay.screen == screen) then
    if overlay and overlay.screen then releasePartyPreview(overlay.screen) end
    overlay = nil
  end
end

local function partyOf(screen)
  local battle = screen and screen.battle
  local party = battle and battle.party
  if type(party) ~= "table" then
    party = screen and screen.save and screen.save.party
  end
  return type(party) == "table" and party or {}
end

local POCKET_ORDER = { ITEM = 1, BALL = 2, KEY_ITEM = 3, TM_HM = 4 }

local function packRows(screen)
  local save = screen and (screen.save or (screen.game and screen.game.save))
  local data = screen and screen.game and screen.game.data or {}
  local defs = data.items or {}
  local rows = {}
  for id, raw in pairs((save and save.inventory) or {}) do
    local count = tonumber(raw) or (raw and 1) or 0
    if count > 0 then
      local def = defs[id]
      rows[#rows + 1] = {
        id = id,
        count = count,
        name = (def and def.name) or tostring(id):gsub("_", " "),
        pocket = (def and def.pocket) or "ITEM",
        index = (def and tonumber(def.index)) or math.huge,
        disabled = def and def.battleMenu == "ITEMMENU_NOUSE" or false,
      }
    end
  end
  table.sort(rows, function(a, b)
    local ap = POCKET_ORDER[a.pocket] or 99
    local bp = POCKET_ORDER[b.pocket] or 99
    if ap ~= bp then return ap < bp end
    if a.index ~= b.index then return a.index < b.index end
    return tostring(a.id) < tostring(b.id)
  end)
  return rows
end

local function clampOverlayCursor(o)
  if not o then return end
  local count = 0
  if o.mode == "pack" then
    count = #(o.rows or {})
  elseif o.mode == "party" or o.mode == "itemparty" then
    count = #partyOf(o.screen)
  elseif o.mode == "itemmove" then
    count = #((o.targetMon and o.targetMon.moves) or {})
  end
  count = math.max(1, count)
  o.index = math.max(1, math.min(tonumber(o.index) or 1, count))
  local visible = 4
  o.scroll = math.max(0, tonumber(o.scroll) or 0)
  if o.index <= o.scroll then o.scroll = o.index - 1 end
  if o.index > o.scroll + visible then o.scroll = o.index - visible end
  o.scroll = math.max(0, math.min(o.scroll, math.max(0, count - visible)))
end

local function openPartyOverlay(screen)
  overlay = { screen = screen, mode = "party", index = 1, scroll = 0 }
  local party = partyOf(screen)
  local active = screen and screen.battle and screen.battle.player
  for i, mon in ipairs(party) do
    if mon == active then overlay.index = i break end
  end
  clampOverlayCursor(overlay)
  return true
end

local function openPackOverlay(screen)
  overlay = { screen = screen, mode = "pack", index = 1, scroll = 0,
              rows = packRows(screen) }
  clampOverlayCursor(overlay)
  return true
end

local function localMonName(screen, mon)
  if not mon then return "POKéMON" end
  if screen and type(screen.name) == "function" then
    local ok, name = pcall(screen.name, screen, mon)
    if ok and name and tostring(name) ~= "" then return tostring(name) end
  end
  return tostring(mon.nickname or mon.name or mon.species or "POKéMON")
end

local function overlayMessage(o, text)
  if o then o.message = tostring(text or "") end
end

local function confirmPartySwitch(screen, o)
  local party = partyOf(screen)
  local mon = party[o.index]
  if not mon then return false end
  local battle = screen and screen.battle
  if battle and mon == battle.player then
    overlayMessage(o, localMonName(screen, mon) .. " is already out.")
    return true
  end
  if battle and type(battle.switchLocked) == "function" then
    local ok, locked = pcall(battle.switchLocked, battle)
    if ok and locked then
      overlayMessage(o, localMonName(screen, battle.player) .. " can't be recalled!")
      return true
    end
  end
  if mon.isEgg then
    overlayMessage(o, "An EGG can't battle!")
    return true
  end
  if (tonumber(mon.hp) or 0) <= 0 then
    overlayMessage(o, "There's no will to battle!")
    return true
  end
  closeOverlay(screen)
  if type(screen.submit) == "function" then
    screen:submit({ kind = "switch", index = o.index })
    return true
  end
  return false
end

local function enterItemParty(screen, o, row, action)
  o.packIndex, o.packScroll = o.index, o.scroll
  o.mode = "itemparty"
  o.itemId, o.itemName, o.action = row.id, row.name, action
  o.index, o.scroll = 1, 0
  o.message = nil
  clampOverlayCursor(o)
  return true
end

local function confirmPack(screen, o)
  o.rows = packRows(screen)
  clampOverlayCursor(o)
  local row = o.rows[o.index]
  if not row then
    overlayMessage(o, "Your PACK is empty.")
    return true
  end
  if row.disabled then
    overlayMessage(o, "That won't help in battle.")
    return true
  end

  local I = itemEffects()
  local action = I and type(I.partyAction) == "function" and I.partyAction(row.id) or nil
  if action and type(screen.applyPartyItem) == "function" then
    return enterItemParty(screen, o, row, action)
  end

  closeOverlay(screen)
  if type(screen.useItem) == "function" then
    screen:useItem(row.id)
    return true
  end
  return false
end

local function confirmItemParty(screen, o)
  local party = partyOf(screen)
  local mon = party[o.index]
  if not mon then return false end
  local I = itemEffects()
  local restore = I and I.RESTORE_PP and I.RESTORE_PP[o.itemId]
  if o.action == "pp" and restore and not restore.each and not mon.isEgg then
    o.partyIndex, o.partyScroll = o.index, o.scroll
    o.mode = "itemmove"
    o.targetMon = mon
    o.index, o.scroll = 1, 0
    o.message = nil
    clampOverlayCursor(o)
    return true
  end
  local itemId, action = o.itemId, o.action
  closeOverlay(screen)
  screen:applyPartyItem(itemId, action, mon)
  return true
end

local function confirmItemMove(screen, o)
  local moves = (o.targetMon and o.targetMon.moves) or {}
  if not moves[o.index] then return false end
  local itemId, mon, slot = o.itemId, o.targetMon, o.index
  closeOverlay(screen)
  screen:applyPartyItem(itemId, "pp", mon, slot)
  return true
end

local function cancelOverlay(screen, o)
  if o.mode == "itemmove" then
    o.mode = "itemparty"
    o.targetMon = nil
    o.index = o.partyIndex or 1
    o.scroll = o.partyScroll or 0
    o.message = nil
    clampOverlayCursor(o)
    return true
  end
  if o.mode == "itemparty" then
    o.mode = "pack"
    o.rows = packRows(screen)
    o.index = o.packIndex or 1
    o.scroll = o.packScroll or 0
    o.message = nil
    clampOverlayCursor(o)
    return true
  end
  closeOverlay(screen)
  return true
end

local function overlayControl(screen, control)
  local o = overlayFor(screen)
  if not o then return false end
  if o.message and o.message ~= "" then
    if control == "confirm" or control == "cancel" then
      o.message = nil
      return true
    end
    return true
  end

  if control == "up" or control == "down" or control == "left" or control == "right" then
    local count
    if o.mode == "pack" then count = #(o.rows or {}) end
    if o.mode == "party" or o.mode == "itemparty" then count = #partyOf(screen) end
    if o.mode == "itemmove" then count = #((o.targetMon and o.targetMon.moves) or {}) end
    count = tonumber(count) or 0
    if count <= 0 then return true end
    local delta = (control == "up" and -1) or (control == "down" and 1)
      or (control == "left" and -4) or 4
    local nextIndex = (tonumber(o.index) or 1) + delta
    if math.abs(delta) == 1 then
      if nextIndex < 1 then nextIndex = count end
      if nextIndex > count then nextIndex = 1 end
    else
      nextIndex = math.max(1, math.min(count, nextIndex))
    end
    o.index = nextIndex
    clampOverlayCursor(o)
    return true
  end

  if control == "cancel" then return cancelOverlay(screen, o) end
  if control == "confirm" then
    if o.mode == "party" then return confirmPartySwitch(screen, o) end
    if o.mode == "pack" then return confirmPack(screen, o) end
    if o.mode == "itemparty" then return confirmItemParty(screen, o) end
    if o.mode == "itemmove" then return confirmItemMove(screen, o) end
  end
  return false
end

local INDEX = {
  fight = 1,
  pkmn = 2,
  pack = 3,
  run = 4,
}

local function stackTop(game)
  local stack = game and game.stack
  if not (stack and type(stack.top) == "function") then return nil end
  local ok, top = pcall(stack.top, stack)
  if not ok or type(top) ~= "table" then return nil end
  return top
end

-- v0.2.33: the live Gold battle renderer already learned this lesson in
-- v0.2.32: Game2.stack:top() is not a reliable authority for the BattleState
-- while the overworld/voxel battle bridge is composing the fight. Resolve the
-- exact BattleState held by OverworldBattle first whenever the stack top is not
-- itself a battle screen. This keeps the physical face-button shortcuts wired
-- to the same screen that VoxelScene is visibly rendering.
local function sessionBattleScreen()
  local okO, OverworldBattle = pcall(V.require, "OverworldBattle")
  if not (okO and type(OverworldBattle) == "table") then return nil end

  if type(OverworldBattle.battle) == "function" then
    local ok, screen = pcall(OverworldBattle.battle)
    if ok and type(screen) == "table" and type(screen.battle) == "table" then
      return screen
    end
  end

  -- Compatibility with slightly older embedded OverworldBattle revisions that
  -- exposed only cameraContext().screen.
  if type(OverworldBattle.cameraContext) == "function" then
    local ok, ctx = pcall(OverworldBattle.cameraContext)
    local screen = ok and type(ctx) == "table" and ctx.screen or nil
    if type(screen) == "table" and type(screen.battle) == "table" then
      return screen
    end
  end
  return nil
end

local function screenOf(game)
  local top = stackTop(game)
  if type(top) == "table" and type(top.battle) == "table" then return top end
  return sessionBattleScreen()
end

local function battleInputOwned(game)
  -- v0.2.44: BATTLE COMMANDS is now a complete UI-mode switch.  OFF means
  -- Gold owns the battle screen and its controls again, rather than merely
  -- hiding our command diamond while the replacement HUD still owns the frame.
  if not battleCommandsEnabled() then return nil end
  local screen = screenOf(game)
  if not screen then return nil end
  -- Tutorial and contest flows have special cart-authored menus and automatic
  -- input; do not replace those here.
  if screen.tutorial or screen.contest then return nil end
  if screen.phase == "done" or screen.phase == "evolving" then return nil end
  -- openParty/openPack change the battle state to submenu before pushing the
  -- native screen. Once that happens, immediately yield ALL input back to Gold
  -- so the party/item menu gets its normal D-pad, stick and A/B handling.
  if screen.phase == "submenu" then return nil end
  return screen
end

function M.owns(screen)
  -- OFF restores Gold's original battle UI wholesale.  Returning false here
  -- prevents the custom HUD from being baked into VoxelScene and makes
  -- GoldComposeBridge fall through to the native Gen-2 battle canvas.
  if not battleCommandsEnabled() then return false end
  if type(screen) ~= "table" or type(screen.battle) ~= "table" then return false end
  if screen.tutorial or screen.contest then return false end
  if screen.phase == "done" or screen.phase == "evolving" then return false end
  -- PACK and PKMN are real pushed Gold screens.  Once BattleState enters
  -- submenu, stop drawing the replacement battle HUD as well as yielding
  -- input, so the native Pack/Party screen is never covered by our scene HUD.
  if screen.phase == "submenu" then return false end
  return true
end

local function clearNativeStick(input)
  if type(input) ~= "table" then return end
  local dir = input.stickDir
  if dir then
    if type(input.sourceRelease) == "function" then
      pcall(input.sourceRelease, input, dir, "stick")
    else
      local sources = input.sources and input.sources[dir]
      if type(sources) == "table" then sources.stick = nil end
      if input.state then input.state[dir] = false end
    end
  end
  input.stickDir = nil
  input.stickAxis = input.stickAxis or { x = 0, y = 0 }
  input.stickAxis.x, input.stickAxis.y = 0, 0
end

local function playerMoves(screen)
  if type(screen.playerMoves) == "function" then
    local ok, moves = pcall(screen.playerMoves, screen)
    if ok and type(moves) == "table" then return moves end
  end
  local mon = screen.battle and screen.battle.player
  return (mon and mon.moves) or {}
end

local shortcutTapSerial = 0

-- Feed a command through Gold's OWN battle-menu dispatcher instead of
-- duplicating BattleState's FIGHT/RUN/PACK/PKMN branches here.  The live
-- controller button selects the native 2x2 cursor slot, then we enqueue one
-- synthetic GB A edge.  On the next fixed step BattleState:update sees exactly
-- the same input it would have seen if the player moved the native cursor and
-- pressed A, so PACK/PKMN go through Screens.push with Gold's current stack,
-- callbacks and menu classes.
local function queueNativeConfirm(screen)
  local input = installedInput or (screen and screen.game and screen.game.input)
  if type(input) ~= "table" then return false, "no live input object" end

  shortcutTapSerial = shortcutTapSerial + 1
  local source = "stadium2:battle-command:" .. tostring(shortcutTapSerial)

  if type(input.sourcePress) == "function"
      and type(input.sourceRelease) == "function" then
    input:sourcePress("a", source)
    input:sourceRelease("a", source)
    return true
  end

  -- Compatibility fallback for older dev builds: the current matching repo
  -- exposes sourcePress/sourceRelease, but a direct queued A edge has the same
  -- fixed-step semantics if those helpers are absent.
  if type(input.pressQueue) == "table" then
    input.pressQueue[#input.pressQueue + 1] = "a"
    return true
  end

  return false, "input cannot enqueue native A"
end

-- v0.2.74: the custom live battle UI should arrive at its command panel on its
-- own.  Current Gold intentionally holds intro text at PromptButton until A/B;
-- that made the first physical controller press both dismiss the unseen final
-- intro prompt and, after phase flipped to menu, become a direct PACK/FIGHT/etc.
-- shortcut.  Auto-page ONLY the battle intro while the custom battle UI owns
-- the screen.  Every later battle prompt remains player-controlled.
local function autoAdvanceIntro(screen)
  if not (screen and battleCommandsEnabled()) then return false end
  if screen.tutorial or screen.contest then return false end
  if tostring(screen.phase or "") ~= "intro" then
    introAuto[screen] = nil
    return false
  end
  if (tonumber(screen.messageTimer) or 0) <= 0 or not screen.message then
    return false
  end
  -- Match BattleState:update's gates: do not queue a prompt edge while an SFX,
  -- send-out animation, HP/slide animation, or stats panel still owns the loop.
  if screen.waitSfx or screen.anim or screen.hpAnim or screen.faintSlide
      or screen.trainerSlide or screen.statsBoxMon then
    return false
  end

  local queueCount = type(screen.queue) == "table" and #screen.queue or -1
  local sig = table.concat({
    tostring(screen.message), tostring(screen.messagePage or 0),
    tostring(queueCount), tostring(screen.showPlayerTrainer),
    tostring(screen.showEnemyTrainer),
  }, "\31")
  local state = introAuto[screen]
  if not state then
    state = { sig = nil, frames = 0, queued = false }
    introAuto[screen] = state
  end
  if state.sig ~= sig then
    state.sig, state.frames, state.queued = sig, 0, false
  end
  if state.queued then return true end

  state.frames = state.frames + 1
  if state.frames < AUTO_INTRO_HOLD_FRAMES then return true end
  local queued, err = queueNativeConfirm(screen)
  if queued then
    state.queued = true
    M.autoIntroPrompts = (M.autoIntroPrompts or 0) + 1
    M.lastAutoIntroError = nil
  else
    M.lastAutoIntroError = tostring(err or "failed to auto-advance battle intro")
  end
  return queued
end

local function activateImpl(screen, index)
  if not (screen and screen.battle and commandInputReady(screen)) then return false end
  index = tonumber(index)
  if not (index and index >= 1 and index <= 4) then return false end

  -- MENU order in Gold: 1 FIGHT, 2 PKMN, 3 PACK, 4 RUN.
  --
  -- FIGHT/RUN still use Gold's exact native A-confirm dispatcher. PKMN/PACK
  -- deliberately stay in the Stadium presentation now: their custom selectors
  -- call Gold's submit/useItem/applyPartyItem routines only after a choice.
  screen.menuIndex = index
  if index == INDEX.pkmn then return openPartyOverlay(screen) end
  if index == INDEX.pack then return openPackOverlay(screen) end
  local queued, err = queueNativeConfirm(screen)
  if not queued then error(err or "failed to queue native battle confirm", 0) end
  return true
end

function M.activate(screen, index)
  local ok, used = pcall(activateImpl, screen, index)
  if ok and used then
    M.lastShortcutError = nil
    M.shortcuts = M.shortcuts + 1
    return true
  end
  if not ok then
    M.lastShortcutError = tostring(used)
    local log = V and V.mod and V.mod.log
    if log and type(log.warn) == "function" then
      pcall(log.warn, log, "battle controller shortcut failed: %s", M.lastShortcutError)
    end
  end
  return false
end

local KEY_CHOICE = {
  left = INDEX.fight,
  right = INDEX.run,
  up = INDEX.pkmn,
  down = INDEX.pack,
}

-- SDL/LÖVE mapped names: west=x (PS Square / Xbox X), east=b (Circle/B),
-- south=a (Cross/A), north=y (Triangle/Y).
local PAD_CHOICE = {
  x = INDEX.fight,
  b = INDEX.run,
  a = INDEX.pack,
  y = INDEX.pkmn,
}

local PAD_DPAD_CHOICE = {
  dpleft = INDEX.fight,
  dpright = INDEX.run,
  dpdown = INDEX.pack,
  dpup = INDEX.pkmn,
}

-- Generic desktop raw joystick convention (1=A,2=B,3=X,4=Y). The engine only
-- maps raw A/B itself; adding X/Y here keeps the four-command diamond usable on
-- Linux handhelds/controllers that SDL does not recognize as a gamepad.
local RAW_CHOICE = {
  [3] = INDEX.fight,
  [2] = INDEX.run,
  [1] = INDEX.pack,
  [4] = INDEX.pkmn,
}

function M.install(game)
  if M.installed then return game == installedGame end
  if type(game) ~= "table" then return false, "no live Game2 host" end
  local input = game.input
  if type(input) ~= "table" then return false, "live Game2 host has no input object" end
  installedGame, installedInput = game, input

  -- Reserve mapped left stick before Input converts it to GB D-pad directions.
  do
    local inner = input.gamepadaxis
    input.gamepadaxis = function(self, joystick, axis, value, ...)
      local screen = battleInputOwned(game)
      if screen and (axis == "leftx" or axis == "lefty") then
        clearNativeStick(self)
        return
      end
      if inner then return inner(self, joystick, axis, value, ...) end
    end
  end

  -- Same reservation for unrecognized/raw pads. Input maps raw axes 1/2 back
  -- into gamepadaxis(leftx/lefty), but intercepting here avoids even one queued
  -- menu direction on hosts where that conversion is wrapped elsewhere.
  do
    local inner = input.joystickaxis
    input.joystickaxis = function(self, joystick, axis, value, ...)
      local screen = battleInputOwned(game)
      if screen and (axis == 1 or axis == 2) then
        clearNativeStick(self)
        return
      end
      if inner then return inner(self, joystick, axis, value, ...) end
    end
  end

  -- WASD is Pokemon locomotion. Arrow keys are the four direct command slots
  -- while the command diamond is up. Outside that phase the arrow keys return
  -- to Gold normally, so move/item lists keep ordinary keyboard navigation.
  do
    local innerPress, innerRelease = input.keypressed, input.keyreleased
    input.keypressed = function(self, key, ...)
      local screen = battleInputOwned(game)
      if screen then
        local o = overlayFor(screen)
        if o then
          local controls = {
            up = "up", down = "down", left = "left", right = "right",
            z = "confirm", ["return"] = "confirm", space = "confirm",
            x = "cancel", backspace = "cancel",
          }
          local control = controls[key]
          if control and overlayControl(screen, control) then
            blockedKeyRelease[key] = true
            return
          end
          -- The custom list owns battle input completely; WASD remains
          -- locomotion-reserved and command hotkeys cannot fire behind it.
          if key == "w" or key == "a" or key == "s" or key == "d" then
            blockedKeyRelease[key] = true
            return
          end
        else
          if key == "w" or key == "a" or key == "s" or key == "d" then
            blockedKeyRelease[key] = true
            return
          end
          local shortcutMode = battleShortcutMode()
          -- A menu can become logically ready before its first render. Swallow
          -- command hotkeys during that one-frame warmup so the hidden native
          -- cursor cannot move/select behind the custom panel.
          if shortcutMode ~= "native" and commandWarming(screen)
              and KEY_CHOICE[key] then
            blockedKeyRelease[key] = true
            return
          end
          local choice = shortcutMode ~= "native" and commandInputReady(screen)
            and KEY_CHOICE[key] or nil
          if choice and M.activate(screen, choice) then
            blockedKeyRelease[key] = true
            return
          end
        end
      end
      if innerPress then return innerPress(self, key, ...) end
    end
    input.keyreleased = function(self, key, ...)
      if blockedKeyRelease[key] then
        blockedKeyRelease[key] = nil
        return
      end
      if innerRelease then return innerRelease(self, key, ...) end
    end
  end

  -- Mapped face buttons directly activate the four command slots before the
  -- engine translates A/B into Game Boy confirm/cancel actions.
  do
    local innerPress, innerRelease = input.gamepadpressed, input.gamepadreleased
    input.gamepadpressed = function(self, joystick, button, ...)
      local screen = battleInputOwned(game)
      local handled = false
      if screen and overlayFor(screen) then
        local control = overlayPadControl(button)
        if control then handled = overlayControl(screen, control) end
        -- Square/Triangle are command buttons only on the command diamond.
        -- Swallow them while a selector is open so they never leak to Gold.
        if button == "x" or button == "y" then handled = true end
      else
        local shortcutMode = battleShortcutMode()
        local choice = nil
        if screen and commandInputReady(screen) then
          if shortcutMode == "face" then
            choice = PAD_CHOICE[button]
          elseif shortcutMode == "dpad" then
            choice = PAD_DPAD_CHOICE[button]
          end
        end
        if choice then
          handled = M.activate(screen, choice)
        elseif screen and shortcutMode ~= "native" and commandWarming(screen) then
          -- The command panel is logically ready but has not reached the screen
          -- yet. Consume its shortcut buttons for this edge; never let the
          -- native hidden menu accept an input the player could not see.
          local warmChoice = shortcutMode == "face" and PAD_CHOICE[button]
            or (shortcutMode == "dpad" and PAD_DPAD_CHOICE[button] or nil)
          if warmChoice then handled = true end
        elseif screen and shortcutMode == "face" and PAD_CHOICE[button]
            and not commandInputReady(screen) then
          -- If this physical face button is being used to page an intro line,
          -- remember that it is already held before forwarding it to Gold.
          -- The polling fallback must not reinterpret the SAME held edge as a
          -- command after BattleState flips to menu later in the frame.
          local key = padKey(joystick)
          local poll = polledPadHeld[key]
          if not poll then poll = {}; polledPadHeld[key] = poll end
          poll[button] = true
        end
      end
      if handled then
        local key = padKey(joystick)
        local held = blockedPadRelease[key]
        if not held then held = {}; blockedPadRelease[key] = held end
        held[button] = true
        local poll = polledPadHeld[key]
        if not poll then poll = {}; polledPadHeld[key] = poll end
        poll[button] = true
        return
      end
      if innerPress then return innerPress(self, joystick, button, ...) end
    end
    input.gamepadreleased = function(self, joystick, button, ...)
      local key = padKey(joystick)
      local held = blockedPadRelease[key]
      if held and held[button] then
        held[button] = nil
        local poll = polledPadHeld[key]
        if poll then poll[button] = nil end
        return
      end
      local poll = polledPadHeld[key]
      if poll then poll[button] = nil end
      if innerRelease then return innerRelease(self, joystick, button, ...) end
    end
  end

  -- Raw/unmapped face buttons. Recognized gamepads are ignored by the engine's
  -- raw path, so this block is only for generic joysticks/handheld controls.
  do
    local innerPress, innerRelease = input.joystickpressed, input.joystickreleased
    input.joystickpressed = function(self, joystick, button, ...)
      local screen = battleInputOwned(game)
      local handled = false
      if screen and overlayFor(screen) then
        local control = rawOverlayControl(button)
        if control then handled = overlayControl(screen, control)
        elseif button == 3 or button == 4 then handled = true end
      else
        local shortcutMode = battleShortcutMode()
        local choice = screen and shortcutMode == "face"
          and commandInputReady(screen) and RAW_CHOICE[button] or nil
        if choice then
          handled = M.activate(screen, choice)
        elseif screen and shortcutMode == "face" and commandWarming(screen)
            and RAW_CHOICE[button] then
          handled = true
        end
      end
      if handled then
        local key = padKey(joystick)
        local held = blockedRawRelease[key]
        if not held then held = {}; blockedRawRelease[key] = held end
        held[button] = true
        return
      end
      if innerPress then return innerPress(self, joystick, button, ...) end
    end
    input.joystickreleased = function(self, joystick, button, ...)
      local key = padKey(joystick)
      local held = blockedRawRelease[key]
      if held and held[button] then
        held[button] = nil
        return
      end
      if innerRelease then return innerRelease(self, joystick, button, ...) end
    end
  end

  -- Raw joystick D-pads usually arrive as hats. Keep those on the custom
  -- selector instead of letting Input turn them into Gold menu directions
  -- behind the Stadium overlay.
  do
    local inner = input.joystickhat
    input.joystickhat = function(self, joystick, hat, direction, ...)
      local screen = battleInputOwned(game)
      if screen and overlayFor(screen) then
        local controls = {
          u = "up", d = "down", l = "left", r = "right",
          lu = "up", ru = "up", ld = "down", rd = "down",
        }
        local control = controls[direction]
        if control then
          overlayControl(screen, control)
          return
        elseif direction == "c" then
          return
        end
      elseif screen and battleShortcutMode() == "dpad"
          and commandInputReady(screen) then
        local hats = { l = INDEX.fight, r = INDEX.run, d = INDEX.pack, u = INDEX.pkmn }
        local choice = hats[direction]
        if choice and M.activate(screen, choice) then return end
      elseif screen and battleShortcutMode() == "dpad" and commandWarming(screen) then
        local hats = { l = true, r = true, d = true, u = true,
                       lu = true, ru = true, ld = true, rd = true }
        if hats[direction] then return end
      end
      if inner then return inner(self, joystick, hat, direction, ...) end
    end
  end

  M.installed = true
  return true
end

-- Poll mapped face buttons as a fallback for controller stacks where another
-- wrapper swallows or delays gamepadpressed. Also continually erase any stale
-- analog-stick D-pad source created before battle ownership began.
function M.update(game)
  game = game or installedGame
  if not M.installed or game ~= installedGame then return false end
  local screen = battleInputOwned(game)
  if not screen then
    if overlay and overlay.screen then releasePartyPreview(overlay.screen) end
    overlay = nil
    return false
  end
  if overlay and (overlay.screen ~= screen or screen.phase ~= "menu"
      or (screen.battle and screen.battle.over)) then
    if overlay.screen then releasePartyPreview(overlay.screen) end
    overlay = nil
  end
  if not commandVisualReady(screen) then commandPresented[screen] = nil end
  -- No physical A/B is required to reach the first command panel in an
  -- ordinary custom-UI battle. The intro pages itself through Gold's own input
  -- queue; subsequent messages/prompts remain untouched.
  autoAdvanceIntro(screen)
  clearNativeStick(installedInput)

  local J = love and love.joystick
  if not (J and type(J.getJoysticks) == "function") then return true end
  local okList, list = pcall(J.getJoysticks)
  if not okList or type(list) ~= "table" then return true end
  for _, js in ipairs(list) do
    local okPad, mapped = pcall(function()
      return js and type(js.isGamepad) == "function" and js:isGamepad()
    end)
    if okPad and mapped and type(js.isGamepadDown) == "function" then
      local held = polledPadHeld[js]
      if not held then held = {}; polledPadHeld[js] = held end
      local o = overlayFor(screen)
      if o then
        local controls = {
          dpup = "up", dpdown = "down", dpleft = "left", dpright = "right",
        }
        controls[confirmPadButton()] = "confirm"
        controls[cancelPadButton()] = "cancel"
        for button, control in pairs(controls) do
          local okDown, down = pcall(js.isGamepadDown, js, button)
          down = okDown and down and true or false
          if down and not held[button] then
            held[button] = true
            overlayControl(screen, control)
          elseif not down then
            held[button] = nil
          end
        end
      else
        local shortcutMode = battleShortcutMode()
        local shortcutMap = shortcutMode == "dpad" and PAD_DPAD_CHOICE or PAD_CHOICE
        for button, choice in pairs(shortcutMap) do
          local okDown, down = pcall(js.isGamepadDown, js, button)
          down = okDown and down and true or false
          if down and not held[button] then
            held[button] = true
            if shortcutMode ~= "native" and commandInputReady(screen) then
              M.activate(screen, choice)
            end
          elseif not down then
            held[button] = nil
          end
        end
      end
    end
  end
  return true
end

local function font(size)
  size = math.max(10, math.floor(size + 0.5))
  if fonts[size] ~= nil then return fonts[size] or nil end
  local G = love and love.graphics
  if not (G and type(G.newFont) == "function") then
    fonts[size] = false
    return nil
  end
  local ok, f = pcall(G.newFont, size)
  fonts[size] = ok and f or false
  return fonts[size] or nil
end

local function roundRect(mode, x, y, w, h, r)
  love.graphics.rectangle(mode, x, y, w, h, r, r)
end

local function panel(x, y, w, h, r, alpha)
  local G = love.graphics
  G.setColor(0.018, 0.026, 0.045, alpha or 0.80)
  roundRect("fill", x, y, w, h, r)
  G.setColor(1, 1, 1, 0.20)
  G.setLineWidth(2)
  roundRect("line", x, y, w, h, r)
end

local function cleanText(text)
  text = tostring(text or "")
  text = text:gsub("[\v\f\r]", " ")
  text = text:gsub("\n", "  ")
  text = text:gsub("%s+", " ")
  return text
end

local function monName(screen, mon)
  if not mon then return "" end
  if type(screen.name) == "function" then
    local ok, name = pcall(screen.name, screen, mon)
    if ok and name and tostring(name) ~= "" then return cleanText(name) end
  end
  if mon.nickname then return cleanText(mon.nickname) end
  if mon.name then return cleanText(mon.name) end
  local data = screen.game and screen.game.data
  local def = data and data.pokemon and data.pokemon[mon.species]
  if def and def.name then return cleanText(def.name) end
  return "#" .. tostring(mon.species or "?")
end

local function shownHp(screen, side, mon)
  if not mon then return 0, 1 end
  local hp = tonumber(mon.hp) or 0
  local shown = screen.shownHp
  if type(shown) == "table" and tonumber(shown[side]) then hp = tonumber(shown[side]) end
  local maxHp = tonumber(mon.maxHp)
    or (type(mon.stats) == "table" and tonumber(mon.stats.hp)) or math.max(1, hp)
  return math.max(0, hp), math.max(1, maxHp)
end

local function hpColor(ratio)
  if ratio <= 0.20 then return 0.95, 0.23, 0.18 end
  if ratio <= 0.50 then return 0.96, 0.72, 0.15 end
  return 0.24, 0.90, 0.46
end

local function drawBattlerHud(screen, mon, side, ww, wh)
  if not mon then return end
  local G = love.graphics
  local w = math.min(ww * 0.34, 430)
  local h = math.max(76, math.min(112, wh * 0.125))
  local margin = math.max(18, wh * 0.025)
  local x = side == "enemy" and margin or ww - margin - w
  local y = margin
  if side == "player2" then y = margin + h + math.max(8, wh * 0.010) end
  local r = math.max(12, h * 0.16)
  panel(x, y, w, h, r, 0.78)

  local title = font(h * 0.24)
  local small = font(h * 0.16)
  if title then G.setFont(title) end
  G.setColor(1, 1, 1, 0.98)
  local name = monName(screen, mon)
  G.print(name, x + h * 0.18, y + h * 0.12)

  local level = tonumber(mon.level)
  if small then G.setFont(small) end
  G.setColor(1, 1, 1, 0.68)
  if level then
    local label = "LV " .. tostring(math.floor(level))
    local tw = G.getFont():getWidth(label)
    G.print(label, x + w - tw - h * 0.18, y + h * 0.16)
  end

  local hp, maxHp = shownHp(screen, side, mon)
  local ratio = math.max(0, math.min(1, hp / maxHp))
  local bx = x + h * 0.18
  local by = y + h * 0.57
  local bw = w - h * 0.36
  local bh = math.max(9, h * 0.105)
  G.setColor(0, 0, 0, 0.48)
  roundRect("fill", bx, by, bw, bh, bh * 0.5)
  local cr, cg, cb = hpColor(ratio)
  G.setColor(cr, cg, cb, 0.98)
  if ratio > 0 then roundRect("fill", bx, by, math.max(2, bw * ratio), bh, bh * 0.5) end

  if small then G.setFont(small) end
  G.setColor(1, 1, 1, 0.78)
  local hpText = tostring(math.floor(hp)) .. " / " .. tostring(math.floor(maxHp))
  G.print(hpText, bx, by + bh + h * 0.06)
  if mon.status then
    local st = cleanText(mon.status)
    local sw = G.getFont():getWidth(st)
    G.print(st, x + w - sw - h * 0.18, by + bh + h * 0.06)
  end
  if side == "player2" then
    G.setColor(1, 1, 1, 0.50)
    local tag = "PARTNER"
    local tw = G.getFont():getWidth(tag)
    G.print(tag, x + w - tw - h * 0.18, y + h * 0.16)
  end
end

local function buttonIcon(spec, x, y, r, selected)
  local G = love.graphics
  spec = type(spec) == "table" and spec or { kind = tostring(spec or "cross"), label = "" }
  local kind = spec.kind or "letter"
  local line = math.max(2, r * 0.10)
  G.setLineWidth(line)
  if selected then
    G.setColor(1, 1, 1, 0.20)
    G.circle("fill", x, y, r * 1.26)
  end
  G.setColor(1, 1, 1, 0.98)
  G.circle("line", x, y, r)
  local q = r * 0.52
  if kind == "square" then
    G.rectangle("line", x - q, y - q, q * 2, q * 2, q * 0.12, q * 0.12)
  elseif kind == "circle" then
    G.circle("line", x, y, q)
  elseif kind == "cross" then
    G.line(x - q, y - q, x + q, y + q)
    G.line(x + q, y - q, x - q, y + q)
  elseif kind == "triangle" then
    G.polygon("line", x, y - q * 1.1, x - q, y + q * 0.8, x + q, y + q * 0.8)
  else
    local f = font(math.max(12, r * 1.00))
    if f then G.setFont(f) end
    local label = tostring(spec.label or "")
    local fw = G.getFont():getWidth(label)
    local fh = G.getFont():getHeight()
    G.print(label, x - fw * 0.5, y - fh * 0.54)
  end
end

local CHOICES = {
  { index = 1, role = "west",  label = "FIGHT", key = "LEFT",  dx = -1, dy = 0 },
  { index = 4, role = "east",  label = "RUN",   key = "RIGHT", dx =  1, dy = 0 },
  { index = 3, role = "south", label = "PACK",  key = "DOWN",  dx =  0, dy = 1 },
  { index = 2, role = "north", label = "PKMN",  key = "UP",    dx =  0, dy = -1 },
}


commandReady = function(screen)
  if type(screen) ~= "table" or type(screen.battle) ~= "table" then return false end
  local phase = tostring(screen.phase or "")
  if phase == "moves" or phase == "submenu" or phase == "done" or phase == "evolving"
      or phase == "locked-in" then
    return false
  end
  -- IMPORTANT: Gold can already have phase == menu while a message/text box
  -- still owns A/B for advancing dialogue. Never show/arm direct commands until
  -- every text/animation gate is clear, or Cross/Circle can become PACK/RUN on
  -- the same press that was meant to dismiss text.
  if screen.message or screen.anim or screen.hpAnim or screen.faintSlide
      or screen.trainerSlide or screen.statsBoxMon then
    return false
  end
  if (tonumber(screen.messageTimer) or 0) > 0 then return false end
  local battle = screen.battle
  if battle.over then return false end
  local queue = screen.queue
  if type(queue) == "table" and #queue > 0 then return false end
  if phase == "menu" then return true end
  -- Gold can spend one fixed-step in intro/resolving immediately before it
  -- writes phase=menu. Keeping the controller panel up through that seam
  -- prevents the replacement HUD from blinking out even though the battle is
  -- already waiting for the next player command visually. Inputs still only
  -- ACTIVATE while phase==menu, so this is presentation-only fail-open logic.
  return phase == "intro" or phase == "resolving" or phase == ""
end

local function drawCommandDiamond(screen, ww, wh)
  local G = love.graphics
  -- Keep this deliberately conspicuous. v0.2.30's compact dock could be easy
  -- to miss (or disappear for the one-frame resolving->menu seam), defeating
  -- the point of replacing Gold's command box with a controller-native UI.
  local w = math.min(ww * 0.46, 620)
  -- v0.2.75: reserve real vertical lanes for header, command diamond and
  -- footer.  The old 43%-high panel put PACK/DOWN at ~88-96% of the panel
  -- while the stick hint already lived at ~94%, so the two text blocks could
  -- only overlap on shorter/wider windows.  A slightly taller panel plus a
  -- body-relative icon size keeps every label inside its own lane.
  local h = math.min(wh * 0.52, 430)
  local margin = math.max(18, wh * 0.025)
  local x = ww - w - margin
  local y = wh - h - margin
  local r = math.max(16, math.min(32, wh * 0.030))
  panel(x, y, w, h, r, 0.84)

  local titleFont = font(math.max(19, math.min(wh * 0.027, w * 0.066)))
  local labelFont = font(math.max(13, math.min(wh * 0.019, h * 0.075)))
  local hintFont = font(math.max(9, math.min(wh * 0.013, h * 0.050)))
  if titleFont then G.setFont(titleFont) end
  G.setColor(1, 1, 1, 0.98)
  G.print("BATTLE COMMANDS", x + w * 0.065, y + h * 0.065)
  local shortcutMode = battleShortcutMode()
  if hintFont then G.setFont(hintFont) end
  G.setColor(1, 1, 1, 0.62)
  local subtitle = shortcutMode == "native" and ("NATIVE MENU INPUT — " .. controllerLayoutName())
    or (shortcutMode == "dpad" and "D-PAD / ARROWS"
      or ("FACE BUTTONS — " .. controllerLayoutName()))
  G.print(subtitle, x + w * 0.068, y + h * 0.155)

  local cx = x + w * 0.53
  -- The icon CENTRES occupy only the middle 38% vertically.  Labels and their
  -- direction hints then finish well above the dedicated footer lane.
  local cy = y + h * 0.47
  local spreadX = w * 0.285
  local spreadY = h * 0.16
  local iconR = math.max(15, math.min(32, wh * 0.030, h * 0.072))
  local selected = tostring(screen.phase or "") == "menu"
    and (tonumber(screen.menuIndex) or 1) or -1

  for _, item in ipairs(CHOICES) do
    local bx = cx + item.dx * spreadX
    local by = cy + item.dy * spreadY
    local on = selected == item.index
    if shortcutMode == "face" then
      buttonIcon(controllerFace(item.role), bx, by, iconR, on)
    else
      -- D-pad/native modes deliberately avoid showing face-button glyphs that
      -- no longer own these commands. The compact direction plate still uses
      -- the same diamond positions and selection highlight.
      G.setColor(1, 1, 1, on and 0.20 or 0.08)
      roundRect("fill", bx - iconR, by - iconR * 0.72, iconR * 2, iconR * 1.44, iconR * 0.30)
      G.setColor(1, 1, 1, on and 0.85 or 0.30)
      roundRect("line", bx - iconR, by - iconR * 0.72, iconR * 2, iconR * 1.44, iconR * 0.30)
    end
    if labelFont then G.setFont(labelFont) end
    G.setColor(1, 1, 1, on and 1.0 or 0.88)
    local tw = G.getFont():getWidth(item.label)
    local labelY = by + iconR * 1.14
    G.print(item.label, bx - tw * 0.5, labelY)
    if hintFont then G.setFont(hintFont) end
    G.setColor(1, 1, 1, 0.54)
    local kw = G.getFont():getWidth(item.key)
    G.print(item.key, bx - kw * 0.5,
            labelY + (labelFont and labelFont:getHeight() or 20) * 0.92)
  end

  if hintFont then G.setFont(hintFont) end
  G.setColor(1, 1, 1, 0.68)
  local hint = shortcutMode == "native"
    and controllerPrompt("D-PAD SELECT    •    CROSS/A CONFIRM    •    CIRCLE/B BACK")
    or "LEFT STICK MOVE    •    RIGHT STICK CAMERA"
  local hw = G.getFont():getWidth(hint)
  local footerY = y + h - G.getFont():getHeight() * 1.55 - math.max(5, h * 0.018)
  G.print(hint, x + (w - hw) * 0.5, footerY)
end

local function moveDef(screen, move)
  local battle = screen and screen.battle
  if battle and type(battle.moveDef) == "function" then
    local ok, def = pcall(battle.moveDef, battle, move)
    if ok and type(def) == "table" then return def end
  end
  return nil
end

local function moveLabel(screen, move)
  local def = moveDef(screen, move)
  if def and def.name then return cleanText(def.name), def end
  if type(move) == "table" then
    if move.name then return cleanText(move.name), def end
    if move.id then return cleanText(move.id), def end
  end
  return cleanText(move), def
end

local function movePP(move, def)
  if type(move) ~= "table" then return nil, nil end
  local pp = tonumber(move.pp)
  local maxPp = tonumber(move.maxPp) or tonumber(move.maxPP)
  if not maxPp and def then maxPp = tonumber(def.pp) end
  return pp, maxPp
end

local function drawMoves(screen, ww, wh)
  local G = love.graphics
  local moves = playerMoves(screen)
  local w = math.min(ww * 0.38, 500)
  local rowH = math.max(52, math.min(72, wh * 0.073))
  local gap = math.max(7, wh * 0.008)
  local h = rowH * 4 + gap * 5 + math.max(30, wh * 0.045)
  local x = ww - w - math.max(18, wh * 0.025)
  local y = wh - h - math.max(18, wh * 0.025)
  local r = math.max(14, wh * 0.022)
  panel(x, y, w, h, r, 0.80)

  local selected = tonumber(screen.moveIndex) or 1
  local nameFont = font(math.max(15, wh * 0.019))
  local metaFont = font(math.max(11, wh * 0.013))
  for i = 1, 4 do
    local move = moves[i]
    local ry = y + gap + (i - 1) * (rowH + gap)
    local on = selected == i
    G.setColor(1, 1, 1, on and 0.17 or 0.07)
    roundRect("fill", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    if on then
      G.setColor(1, 1, 1, 0.72)
      G.setLineWidth(2)
      roundRect("line", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    end
    local name, def = move and moveLabel(screen, move) or "—", nil
    if move then name, def = moveLabel(screen, move) end
    if nameFont then G.setFont(nameFont) end
    G.setColor(1, 1, 1, move and 0.98 or 0.35)
    G.print(name, x + gap * 2.3, ry + rowH * 0.19)
    if move then
      local pp, maxPp = movePP(move, def)
      if metaFont then G.setFont(metaFont) end
      G.setColor(1, 1, 1, 0.62)
      local meta = def and cleanText(def.type or "") or ""
      if pp then
        if meta ~= "" then meta = meta .. "   " end
        meta = meta .. "PP " .. tostring(math.floor(pp))
        if maxPp then meta = meta .. "/" .. tostring(math.floor(maxPp)) end
      end
      G.print(meta, x + gap * 2.3, ry + rowH * 0.60)
    end
  end

  if metaFont then G.setFont(metaFont) end
  G.setColor(1, 1, 1, 0.58)
  local duoPrefix = ""
  if screen._stadiumDuoSelectingPartner then
    local battle = screen.battle
    local index = screen._stadiumDuoPartnerIndex
    local mon = battle and battle.party and battle.party[index]
    local name = mon and (mon.nickname or mon.name or mon.species) or "POKEMON 2"
    duoPrefix = "PARTNER " .. cleanText(name) .. "    "
  elseif screen._stadiumDuoPrimaryAction then
    duoPrefix = "PARTNER MOVE    "
  end
  G.print(duoPrefix .. controllerPrompt("D-PAD / ARROWS SELECT    CROSS/A CONFIRM    CIRCLE/B BACK"),
          x + gap * 1.5, y + h - math.max(24, wh * 0.032))
end


local function selectorGeometry(ww, wh)
  local w = math.min(ww * 0.42, 560)
  local rowH = math.max(54, math.min(76, wh * 0.076))
  local gap = math.max(7, wh * 0.008)
  local headerH = math.max(48, wh * 0.060)
  local footerH = math.max(42, wh * 0.052)
  local h = headerH + rowH * 4 + gap * 5 + footerH
  local x = ww - w - math.max(18, wh * 0.025)
  local y = wh - h - math.max(18, wh * 0.025)
  local r = math.max(14, wh * 0.022)
  return x, y, w, h, rowH, gap, headerH, footerH, r
end

local function selectorHeader(G, title, subtitle, x, y, w, headerH, wh)
  local titleFont = font(math.max(18, wh * 0.023))
  local metaFont = font(math.max(11, wh * 0.013))
  if titleFont then G.setFont(titleFont) end
  G.setColor(1, 1, 1, 0.98)
  G.print(title, x + w * 0.055, y + headerH * 0.22)
  if subtitle and subtitle ~= "" then
    if metaFont then G.setFont(metaFont) end
    G.setColor(1, 1, 1, 0.58)
    G.print(subtitle, x + w * 0.055, y + headerH * 0.68)
  end
end

local function selectorFooter(G, o, x, y, w, h, gap, wh)
  local metaFont = font(math.max(11, wh * 0.013))
  if metaFont then G.setFont(metaFont) end
  local text = o and o.message
  if text and text ~= "" then
    G.setColor(1, 0.86, 0.56, 0.96)
    G.printf(cleanText(text), x + gap * 1.6, y + h - math.max(37, wh * 0.046),
             w - gap * 3.2, "left")
  else
    G.setColor(1, 1, 1, 0.58)
    G.print(controllerPrompt("D-PAD / ARROWS SELECT    CROSS/A CONFIRM    CIRCLE/B BACK"),
            x + gap * 1.5, y + h - math.max(28, wh * 0.035))
  end
end

local function drawPartyModelPreview(screen, ww, wh, o, listX, listY, listH, gap, r)
  local party = partyOf(screen)
  local mon = party[tonumber(o and o.index) or 1]
  local margin = math.max(18, wh * 0.025)
  local x = margin
  local y = listY
  local w = listX - margin * 2
  local h = listH
  if not mon or w < math.max(190, ww * 0.18) then return false end

  local G = love.graphics
  panel(x, y, w, h, r, 0.82)
  local titleFont = font(math.max(18, wh * 0.023))
  local metaFont = font(math.max(11, wh * 0.013))
  local name = cleanText(monName(screen, mon))
  local species = cleanText(mon.species or "POKéMON")
  local def = screen and screen.game and screen.game.data and screen.game.data.pokemon
    and screen.game.data.pokemon[mon.species]
  if def and def.name then species = cleanText(def.name) end
  local dex = def and tonumber(def.dex or def.index) or nil
  if titleFont then G.setFont(titleFont) end
  G.setColor(1, 1, 1, 0.98)
  G.print(name, x + w * 0.055, y + h * 0.035)
  if metaFont then G.setFont(metaFont) end
  G.setColor(1, 1, 1, 0.58)
  local subtitle = species .. (dex and ("    #" .. string.format("%03d", dex)) or "")
  G.print(subtitle, x + w * 0.055, y + h * 0.085)

  local infoH = math.max(92, math.min(132, h * 0.20))
  local modelX = x + gap * 1.3
  local modelY = y + h * 0.14
  local modelW = w - gap * 2.6
  local modelH = h - infoH - h * 0.18
  G.setColor(1, 1, 1, 0.035)
  roundRect("fill", modelX, modelY, modelW, modelH, r * 0.58)
  G.setColor(1, 1, 1, 0.075)
  G.ellipse("fill", modelX + modelW * 0.50, modelY + modelH * 0.83,
    modelW * 0.28, math.max(5, modelH * 0.045))

  local preview = partyPreview()
  local canvas, details
  if mon.isEgg then
    details = { error = "egg" }
  elseif preview and type(preview.render) == "function" then
    local ok, rendered, info = pcall(preview.render, screen, mon,
      math.min(modelW, 480), math.min(modelH, 480))
    if ok then canvas, details = rendered, info else M.lastPartyPreviewError = tostring(rendered) end
  end
  if canvas and type(canvas.getDimensions) == "function" then
    local cw, ch = canvas:getDimensions()
    if cw and ch and cw > 0 and ch > 0 then
      local k = math.min(modelW / cw, modelH / ch)
      G.setColor(1, 1, 1, 1)
      G.draw(canvas, modelX + (modelW - cw * k) * 0.5,
        modelY + (modelH - ch * k) * 0.5, 0, k, k)
    end
  else
    local f = font(math.max(13, wh * 0.017))
    if f then G.setFont(f) end
    G.setColor(1, 1, 1, 0.68)
    local msg = mon.isEgg and "EGG" or "3D MODEL UNAVAILABLE"
    if details and details.error and details.error ~= "egg" then msg = "3D PREVIEW ERROR" end
    G.printf(msg, modelX, modelY + modelH * 0.45, modelW, "center")
  end

  local hp = math.max(0, tonumber(mon.hp) or 0)
  local maxHp = tonumber(mon.maxHp)
    or (type(mon.stats) == "table" and tonumber(mon.stats.hp)) or math.max(1, hp)
  maxHp = math.max(1, maxHp)
  local ratio = math.max(0, math.min(1, hp / maxHp))
  local iy = y + h - infoH - gap
  G.setColor(1, 1, 1, 0.055)
  roundRect("fill", x + gap, iy, w - gap * 2, infoH, r * 0.50)
  if metaFont then G.setFont(metaFont) end
  G.setColor(1, 1, 1, 0.66)
  local status = mon.isEgg and "EGG" or hp <= 0 and "FNT" or cleanText(mon.status or "OK")
  if status == "" then status = "OK" end
  G.print(("LV %d    %s"):format(tonumber(mon.level) or 1, status),
    x + gap * 2, iy + infoH * 0.22)
  G.print(("HP %d / %d"):format(hp, maxHp), x + gap * 2, iy + infoH * 0.52)
  local bx, by = x + gap * 2, iy + infoH * 0.76
  local bw, bh = w - gap * 4, math.max(7, infoH * 0.08)
  G.setColor(0, 0, 0, 0.48)
  roundRect("fill", bx, by, bw, bh, bh * 0.5)
  local cr, cg, cb = hpColor(ratio)
  G.setColor(cr, cg, cb, 0.96)
  if ratio > 0 then roundRect("fill", bx, by, math.max(2, bw * ratio), bh, bh * 0.5) end
  return true
end

local function drawPartySelector(screen, ww, wh, o)
  local G = love.graphics
  local party = partyOf(screen)
  local x, y, w, h, rowH, gap, headerH, _, r = selectorGeometry(ww, wh)
  panel(x, y, w, h, r, 0.82)
  local title = o.mode == "itemparty" and "CHOOSE POKéMON" or "POKéMON"
  local subtitle = o.mode == "itemparty"
    and ("USE " .. cleanText(o.itemName or o.itemId or "ITEM"))
    or "SELECT A POKéMON TO SWITCH"
  selectorHeader(G, title, subtitle, x, y, w, headerH, wh)

  local nameFont = font(math.max(15, wh * 0.019))
  local metaFont = font(math.max(11, wh * 0.013))
  local active = screen.battle and screen.battle.player
  local start = (o.scroll or 0) + 1
  for slot = 1, 4 do
    local i = start + slot - 1
    local mon = party[i]
    local ry = y + headerH + gap + (slot - 1) * (rowH + gap)
    local on = mon and o.index == i
    G.setColor(1, 1, 1, on and 0.17 or 0.07)
    roundRect("fill", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    if on then
      G.setColor(1, 1, 1, 0.72)
      G.setLineWidth(2)
      roundRect("line", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    end
    if mon then
      if nameFont then G.setFont(nameFont) end
      G.setColor(1, 1, 1, 0.98)
      G.print(monName(screen, mon), x + gap * 2.2, ry + rowH * 0.15)

      local hp = math.max(0, tonumber(mon.hp) or 0)
      local maxHp = tonumber(mon.maxHp)
        or (type(mon.stats) == "table" and tonumber(mon.stats.hp)) or math.max(1, hp)
      maxHp = math.max(1, maxHp)
      local ratio = math.max(0, math.min(1, hp / maxHp))
      local bx = x + gap * 2.2
      local by = ry + rowH * 0.53
      local bw = w * 0.46
      local bh = math.max(7, rowH * 0.10)
      G.setColor(0, 0, 0, 0.46)
      roundRect("fill", bx, by, bw, bh, bh * 0.5)
      local cr, cg, cb = hpColor(ratio)
      G.setColor(cr, cg, cb, 0.96)
      if ratio > 0 then roundRect("fill", bx, by, math.max(2, bw * ratio), bh, bh * 0.5) end

      if metaFont then G.setFont(metaFont) end
      G.setColor(1, 1, 1, 0.64)
      local status = mon.isEgg and "EGG"
        or hp <= 0 and "FNT"
        or cleanText(mon.status or "")
      local meta = ("LV %d    HP %d/%d"):format(tonumber(mon.level) or 1, hp, maxHp)
      if status ~= "" then meta = meta .. "    " .. status end
      G.print(meta, bx, by + bh + rowH * 0.08)

      if mon == active then
        local tag = "ACTIVE"
        local tw = G.getFont():getWidth(tag)
        G.setColor(1, 1, 1, 0.58)
        G.print(tag, x + w - tw - gap * 2.2, ry + rowH * 0.18)
      end
    else
      if nameFont then G.setFont(nameFont) end
      G.setColor(1, 1, 1, 0.22)
      G.print("—", x + gap * 2.2, ry + rowH * 0.28)
    end
  end
  drawPartyModelPreview(screen, ww, wh, o, x, y, h, gap, r)
  selectorFooter(G, o, x, y, w, h, gap, wh)
end

local function pocketLabel(id)
  if id == "BALL" then return "BALL" end
  if id == "KEY_ITEM" then return "KEY" end
  if id == "TM_HM" then return "TM/HM" end
  return "ITEM"
end

local function drawPackSelector(screen, ww, wh, o)
  local G = love.graphics
  o.rows = packRows(screen)
  clampOverlayCursor(o)
  local rows = o.rows
  local x, y, w, h, rowH, gap, headerH, _, r = selectorGeometry(ww, wh)
  panel(x, y, w, h, r, 0.82)
  selectorHeader(G, "PACK", "BATTLE ITEMS", x, y, w, headerH, wh)

  local nameFont = font(math.max(15, wh * 0.019))
  local metaFont = font(math.max(11, wh * 0.013))
  local start = (o.scroll or 0) + 1
  for slot = 1, 4 do
    local i = start + slot - 1
    local row = rows[i]
    local ry = y + headerH + gap + (slot - 1) * (rowH + gap)
    local on = row and o.index == i
    G.setColor(1, 1, 1, on and 0.17 or 0.07)
    roundRect("fill", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    if on then
      G.setColor(1, 1, 1, 0.72)
      G.setLineWidth(2)
      roundRect("line", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    end
    if row then
      if nameFont then G.setFont(nameFont) end
      G.setColor(1, 1, 1, row.disabled and 0.38 or 0.98)
      G.print(cleanText(row.name), x + gap * 2.2, ry + rowH * 0.18)
      if metaFont then G.setFont(metaFont) end
      G.setColor(1, 1, 1, row.disabled and 0.28 or 0.62)
      local meta = pocketLabel(row.pocket) .. "    ×" .. tostring(math.floor(row.count or 0))
      if row.disabled then meta = meta .. "    CAN'T USE" end
      G.print(meta, x + gap * 2.2, ry + rowH * 0.61)
    else
      if nameFont then G.setFont(nameFont) end
      G.setColor(1, 1, 1, 0.22)
      G.print("—", x + gap * 2.2, ry + rowH * 0.28)
    end
  end
  selectorFooter(G, o, x, y, w, h, gap, wh)
end

local function drawItemMoveSelector(screen, ww, wh, o)
  local G = love.graphics
  local moves = (o.targetMon and o.targetMon.moves) or {}
  local x, y, w, h, rowH, gap, headerH, _, r = selectorGeometry(ww, wh)
  panel(x, y, w, h, r, 0.82)
  selectorHeader(G, "CHOOSE MOVE",
    "RESTORE PP • " .. monName(screen, o.targetMon), x, y, w, headerH, wh)

  local nameFont = font(math.max(15, wh * 0.019))
  local metaFont = font(math.max(11, wh * 0.013))
  for i = 1, 4 do
    local move = moves[i]
    local ry = y + headerH + gap + (i - 1) * (rowH + gap)
    local on = move and o.index == i
    G.setColor(1, 1, 1, on and 0.17 or 0.07)
    roundRect("fill", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    if on then
      G.setColor(1, 1, 1, 0.72)
      G.setLineWidth(2)
      roundRect("line", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    end
    if move then
      local name, def = moveLabel(screen, move)
      if nameFont then G.setFont(nameFont) end
      G.setColor(1, 1, 1, 0.98)
      G.print(name, x + gap * 2.2, ry + rowH * 0.18)
      local pp, maxPp = movePP(move, def)
      if metaFont then G.setFont(metaFont) end
      G.setColor(1, 1, 1, 0.62)
      local meta = "PP " .. tostring(math.floor(pp or 0))
      if maxPp then meta = meta .. "/" .. tostring(math.floor(maxPp)) end
      if def and def.type then meta = cleanText(def.type) .. "    " .. meta end
      G.print(meta, x + gap * 2.2, ry + rowH * 0.61)
    else
      if nameFont then G.setFont(nameFont) end
      G.setColor(1, 1, 1, 0.22)
      G.print("—", x + gap * 2.2, ry + rowH * 0.28)
    end
  end
  selectorFooter(G, o, x, y, w, h, gap, wh)
end

local function drawCustomOverlay(screen, ww, wh)
  local o = overlayFor(screen)
  if not o then return false end
  if o.mode == "pack" then drawPackSelector(screen, ww, wh, o)
  elseif o.mode == "party" or o.mode == "itemparty" then drawPartySelector(screen, ww, wh, o)
  elseif o.mode == "itemmove" then drawItemMoveSelector(screen, ww, wh, o)
  else return false end
  return true
end

local function drawMessage(screen, ww, wh)
  local text = cleanText(screen and screen.message)
  if text == "" then return end
  local G = love.graphics
  local w = math.min(ww * 0.54, 720)
  local h = math.max(66, math.min(105, wh * 0.105))
  local x = math.max(18, wh * 0.025)
  local y = wh - h - math.max(18, wh * 0.025)
  local r = math.max(14, wh * 0.022)
  panel(x, y, w, h, r, 0.78)
  local f = font(math.max(15, wh * 0.020))
  if f then G.setFont(f) end
  G.setColor(1, 1, 1, 0.96)
  G.printf(text, x + h * 0.22, y + h * 0.20, w - h * 0.44, "left")
end

local function drawPhaseHint(screen, ww, wh)
  if not screen or overlayFor(screen) then return end
  local phase = tostring(screen.phase or "")
  if phase == "menu" or phase == "moves" or screen.message then return end
  local G = love.graphics
  local f = font(math.max(11, wh * 0.013))
  if f then G.setFont(f) end
  local text = "LEFT STICK MOVE   •   RIGHT STICK CAMERA"
  local tw = G.getFont():getWidth(text)
  local x = (ww - tw) * 0.5
  G.setColor(0, 0, 0, 0.44)
  roundRect("fill", x - 13, wh - 44, tw + 26, 30, 12)
  G.setColor(1, 1, 1, 0.70)
  G.print(text, x, wh - 38)
end

-- Full live battle replacement: the 3D scene is already on screen, so draw
-- only lightweight HUD furniture around its edges. No 160x144 white panel,
-- native command box or native battle pic/HUD canvas is composited underneath.
function M.drawFull(screen, ctx)
  if not (M.owns(screen) and love and love.graphics) then return false end
  local G = love.graphics
  local ww, wh = tonumber(ctx and ctx.ww), tonumber(ctx and ctx.wh)
  if not (ww and wh and ww > 0 and wh > 0) then ww, wh = G.getDimensions() end
  if not (ww and wh and ww > 0 and wh > 0) then return false end

  G.push("all")
  G.origin()
  G.setBlendMode("alpha")

  local battle = screen.battle
  drawBattlerHud(screen, battle and battle.enemy, "enemy", ww, wh)
  drawBattlerHud(screen, battle and battle.player, "player", ww, wh)
  local duo = V and V.DoubleBattleMode
  if duo and type(duo.partnerForBattle) == "function" and battle then
    local okPartner, partner = pcall(duo.partnerForBattle, battle)
    if okPartner and partner then
      drawBattlerHud(screen, partner, "player2", ww, wh)
    end
  end

  if drawCustomOverlay(screen, ww, wh) then
    -- Custom PACK / PKMN selectors live on the 3D battlefield.
  elseif screen.phase == "moves" then
    drawMoves(screen, ww, wh)
  elseif battleCommandsEnabled() and commandReady(screen) then
    drawCommandDiamond(screen, ww, wh)
    -- Arm direct command input only after the actual command panel has reached
    -- a render pass. This is the key v0.2.74 invariant: no invisible command
    -- can be selected between Gold's phase change and our next draw.
    if tostring(screen.phase or "") == "menu" then
      commandPresented[screen] = true
    end
  end
  if not overlayFor(screen) then drawMessage(screen, ww, wh) end
  drawPhaseHint(screen, ww, wh)

  G.pop()
  M.draws = M.draws + 1
  M.fullDraws = M.fullDraws + 1
  return true
end

-- v0.2.32: draw directly into the live VoxelScene canvas before endScene().
-- This is the guaranteed path for Gold live battles: if the Pokemon/world are
-- visible, this canvas is visible too. The later compositor only needs to know
-- whether this succeeded so it can avoid double-drawing or fail open to Gold.
function M.drawIntoScene(screen, w, h)
  M.sceneDrawn = false
  if not (M.owns(screen) and love and love.graphics) then return false end
  local ok, yes = pcall(M.drawFull, screen, { ww = w, wh = h, inScene = true })
  M.sceneDrawn = ok and yes and true or false
  if M.sceneDrawn then M.sceneDraws = M.sceneDraws + 1 end
  return M.sceneDrawn
end

function M.sceneHasHud()
  return M.sceneDrawn == true
end

function M.clearSceneHudFlag()
  M.sceneDrawn = false
end

-- Compatibility alias for callers from 0.2.28/0.2.29.
function M.draw(screen, ctx)
  return M.drawFull(screen, ctx)
end

function M.screen(game)
  return screenOf(game or installedGame)
end

function M.status()
  return {
    installed = M.installed,
    shortcuts = M.shortcuts,
    draws = M.draws,
    fullDraws = M.fullDraws,
    sceneDraws = M.sceneDraws,
    sceneDrawn = M.sceneDrawn,
    customUI = customUIEnabled(),
    battleCommands = battleCommandsEnabled(),
    nativeBattleUI = not battleCommandsEnabled(),
    commandVisible = battleCommandsEnabled()
      and commandReady(screenOf(installedGame)) and overlay == nil,
    commandInputArmed = commandInputReady(screenOf(installedGame)),
    autoIntroPrompts = M.autoIntroPrompts or 0,
    lastAutoIntroError = M.lastAutoIntroError,
    customMenu = overlay and overlay.mode or nil,
    partyPreview = partyPreviewCache and partyPreviewCache ~= false,
    lastPartyPreviewError = M.lastPartyPreviewError,
    lastShortcutError = M.lastShortcutError,
    controls = battleCommandsEnabled()
      and "left stick/WASD Pokemon; Square Fight Circle Run Cross Pack Triangle PKMN; arrows mirror commands; right stick camera"
      or "Gold original battle UI/input",
  }
end

return M
