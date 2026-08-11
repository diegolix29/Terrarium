-- Story-free Kanto dialogue bridge (v0.3.54).
--
-- Pokemon Yellow's generated text_pointers marks TEXT_* entries backed by
-- text_asm as { asm = true }, because the spoken branch lives in the engine's
-- hand-ported data/scripts modules rather than in data/generated/text.lua.
-- TwinRegionWorld historically rejected every such entry to keep Yellow story
-- state from mutating Gold/Silver.  That made many otherwise harmless NPCs
-- mute.  This bridge runs the *dialogue presentation* of those hand-ported
-- scripts inside a detached sandbox:
--   * Gold's real save/map/world are never handed to the Gen-1 handler.
--   * script writes land in a deep-cloned save only;
--   * warps, battles, scripted movement and screen changes are suppressed;
--   * TextBox / ListMenu pushes are captured and replayed through the Kanto UI;
--   * current Kanto physical-event flags are mirrored into the clone so common
--     before/after dialogue branches still choose sensibly;
--   * GameVersion is temporarily presented as Yellow so shared handlers take
--     their Yellow wording/branches even though the owning game is Gold.
--
-- Dedicated TwinRegionWorld handlers (mart/nurse/PC, trainers, trades, rods,
-- Game Corner, Safari, etc.) still run before this bridge.  This module is the
-- safe fallback for text_asm dialogue, not a second story VM.

local V = ...
local M = {
  VERSION = "0.3.54",
  sessions = 0,
  handled = 0,
  fallbacks = 0,
  errors = 0,
  suppressedStates = 0,
  suppressedScreens = 0,
  suppressedCommands = 0,
  presentationAudio = 0,
}

local unpack = table.unpack or unpack

local YELLOW_MODULES = {
  -- OAKS_LAB is selected by GameVersion at data/scripts/init load time, so a
  -- Gold host has the R/B module attached.  Force the Yellow contribution.
  { map = "OAKS_LAB", module = "data.scripts.oaks_lab_yellow", direct = true },
  -- These modules are conditionally omitted by data/scripts/init on Gold.
  { module = "data.scripts.yellow_gifts" },
  { module = "data.scripts.yellow_jessie_james" },
  { module = "data.scripts.yellow_beach_house" },
  { module = "data.scripts.yellow_viridian_old_man" },
}

local yellowTalkCache

-- Yellow-only modules are not normally loaded by a Gold host.  Load their
-- contribution under a short-lived Yellow GameVersion facade so any values
-- chosen at module construction time match the cache being explored.
local function requireYellow(moduleName)
  local okGV, GameVersion = pcall(require, "src.core.GameVersion")
  if not (okGV and type(GameVersion) == "table") then return pcall(require, moduleName) end
  local saved = {}
  local function swap(key, fn)
    if type(GameVersion[key]) == "function" then
      saved[#saved + 1] = { key = key, value = GameVersion[key] }
      GameVersion[key] = fn
    end
  end
  swap("isYellow", function() return true end)
  swap("isRed", function() return false end)
  swap("isBlue", function() return false end)
  swap("get", function() return "yellow" end)
  swap("generation", function() return 1 end)
  local ok, value = pcall(require, moduleName)
  for i = #saved, 1, -1 do GameVersion[saved[i].key] = saved[i].value end
  return ok, value
end

local function deepCopy(value, seen, depth)
  if type(value) ~= "table" then return value end
  depth = depth or 0
  if depth > 20 then return {} end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do
    local tk, tv = type(k), type(v)
    local ck = tk == "table" and deepCopy(k, seen, depth + 1) or k
    if tv ~= "function" and tv ~= "userdata" and tv ~= "thread" then
      out[ck] = deepCopy(v, seen, depth + 1)
    end
  end
  return out
end

local function mergeTalk(registry, mapId, contribution)
  if type(mapId) ~= "string" or type(contribution) ~= "table"
      or type(contribution.talk) ~= "table" then return end
  local bucket = registry[mapId]
  if not bucket then bucket = {}; registry[mapId] = bucket end
  for textConst, script in pairs(contribution.talk) do
    bucket[textConst] = script
  end
end

local function yellowTalkRegistry()
  if yellowTalkCache then return yellowTalkCache end
  local registry = {}
  for _, row in ipairs(YELLOW_MODULES) do
    local ok, contribution = requireYellow(row.module)
    if ok and type(contribution) == "table" then
      if row.direct then
        mergeTalk(registry, row.map, contribution)
      else
        for mapId, mapContribution in pairs(contribution) do
          mergeTalk(registry, mapId, mapContribution)
        end
      end
    end
  end
  yellowTalkCache = registry
  return registry
end

local function engineTalk(mapId, textConst)
  -- data.scripts.init attaches the shared hand ports.  It is safe to load on a
  -- Gold host; Yellow-only overlays above take precedence afterwards.
  pcall(require, "data.scripts.init")
  local yellow = yellowTalkRegistry()
  local hit = yellow[mapId] and yellow[mapId][textConst]
  if hit ~= nil then return hit, "yellow-overlay" end
  local ok, MapScripts = pcall(require, "src.script.MapScripts")
  if ok and MapScripts then
    -- Prefer the engine base contribution.  A composed talkScript can include
    -- arbitrary third-party mod overrides; this bridge is recovery for the
    -- hand-ported cartridge dialogue, not a second mod-dispatch surface.
    local getter = type(MapScripts.baseTalk) == "function" and MapScripts.baseTalk
      or MapScripts.talkScript
    if type(getter) == "function" then
      local okTalk, script = pcall(getter, mapId, textConst)
      if okTalk and script ~= nil then return script, "engine-base" end
    end
  end
  return nil, nil
end

local function textFromMarker(marker)
  local text = marker and marker.text
  if type(text) ~= "string" then return nil end
  return text
end

local function makeSave(actualSave, kantoEvents)
  local save = deepCopy(actualSave or {})
  save.flags = type(save.flags) == "table" and save.flags or {}
  for name, on in pairs(type(kantoEvents) == "table" and kantoEvents or {}) do
    if on == true then save.flags[name] = true end
  end
  save.inventory = type(save.inventory) == "table" and save.inventory or {}
  save.player = type(save.player) == "table" and save.player or { name = "GOLD" }
  save.party = type(save.party) == "table" and save.party or {}
  save.defeatedTrainers = type(save.defeatedTrainers) == "table"
    and save.defeatedTrainers or {}
  save.objectToggles = type(save.objectToggles) == "table" and save.objectToggles or {}
  save.itemsTaken = type(save.itemsTaken) == "table" and save.itemsTaken or {}
  return save
end

local function makeData(actualData, region, mapId)
  local loaded = region and region.loaded or {}
  local data = {
    text = type(loaded.text) == "table" and loaded.text or {},
    field = type(loaded.field) == "table" and loaded.field or {},
    maps = type(loaded.maps) == "table" and loaded.maps or {},
  }
  setmetatable(data, { __index = actualData or {} })
  function data:resolveText(mapLabel, textConst)
    local all = loaded and loaded.textPointers
    local pointers = type(all) == "table"
      and (all[mapLabel] or all[mapId]) or nil
    local info = type(pointers) == "table" and pointers[textConst] or nil
    local label = type(info) == "table" and info.text or nil
    return label and self.text[label] or nil
  end
  return data
end

local function makeNpc(obj, entity)
  local npc = {
    id = entity and entity.id or (obj and obj.name) or "KANTO_DIALOGUE_NPC",
    def = obj or (entity and entity.def) or {},
    cellX = tonumber(entity and entity.cellX or obj and obj.x) or 0,
    cellY = tonumber(entity and entity.cellY or obj and obj.y) or 0,
    facing = entity and entity.facing or "down",
    moving = false,
    frozen = false,
  }
  function npc:facePlayer(player)
    if not player then return end
    local dx = (tonumber(player.cellX) or 0) - (tonumber(self.cellX) or 0)
    local dy = (tonumber(player.cellY) or 0) - (tonumber(self.cellY) or 0)
    if math.abs(dx) > math.abs(dy) then self.facing = dx > 0 and "right" or "left"
    elseif dy ~= 0 then self.facing = dy > 0 and "down" or "up" end
  end
  return npc
end

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if not ok then M.errors = M.errors + 1; M.lastError = tostring(a); return nil end
  return a, b, c
end

local function patchFunction(bucket, key, fn, saved)
  if type(bucket) ~= "table" or type(bucket[key]) ~= "function" then return end
  saved[#saved + 1] = { bucket = bucket, key = key, value = bucket[key] }
  bucket[key] = fn
end

local function restorePatches(saved)
  for i = #saved, 1, -1 do
    local row = saved[i]
    row.bucket[row.key] = row.value
  end
end

local HALT_COMMAND = {
  start_battle = true, static_battle = true, rival_battle = true,
  wild_battle = true, warp = true, teleport = true, fly = true, blackout = true,
  hall_of_fame = true, enter_hall_of_fame = true,
}

local SAFE_COMMAND = {
  show_text = true, ask = true, face_player = true, play_cry = true,
  check_flag = true, check_item = true, check_dex_owned = true,
  jump = true, jump_if_true = true, jump_if_false = true,
  label = true, ["end"] = true,
  -- Writes are allowed only because ctx.save is a detached clone.  They make
  -- multi-page before/after branches coherent within this one conversation.
  set_flag = true, clear_flag = true,
  set_var = true, clear_var = true, check_var = true,
  compare = true, check_money = true, check_party = true,
  text_opts = true,
}

local Session = {}
Session.__index = Session

function Session:enqueue(job)
  if type(job) ~= "table" then return end
  self.queue[#self.queue + 1] = job
end

function Session:proxyStack()
  if self.stack then return self.stack end
  local session = self
  local stack = { entries = {} }
  function stack:push(state)
    self.entries[#self.entries + 1] = state
    if type(state) == "table" and state.__kantoDialogueText then
      session:enqueue(state)
    elseif type(state) == "table" and state.__kantoDialogueMenu then
      session:enqueue(state)
    else
      M.suppressedStates = M.suppressedStates + 1
    end
    return state
  end
  function stack:pop() return table.remove(self.entries) end
  function stack:top() return self.entries[#self.entries] end
  function stack:contains(state)
    for _, row in ipairs(self.entries) do if row == state then return true end end
    return false
  end
  self.stack = stack
  return stack
end

function Session:proxyWorld()
  if self.ow then return self.ow end
  local session = self
  local excursion = self.excursion or {}
  local map = self.map or {
    id = self.mapId,
    def = (self.region and self.region.loaded and self.region.loaded.maps
      and self.region.loaded.maps[self.mapId]) or { label = self.mapId },
  }
  map.id = map.id or self.mapId
  map.def = map.def or { label = self.mapId }
  local ow = {
    map = map,
    player = {
      cellX = tonumber(excursion.cellX) or 0,
      cellY = tonumber(excursion.cellY) or 0,
      facing = excursion.facing or "down",
      moving = false,
    },
    npcs = { self.npc }, entities = { self.npc },
    scriptMoves = {}, pendingScripts = {}, parallelRunners = {},
    npcMoveLocks = {},
  }
  function ow:trainerDefeated(npc)
    if session.adapters and type(session.adapters.trainerDefeated) == "function" then
      return session.adapters.trainerDefeated(session.mapId, npc and npc.def or session.obj) == true
    end
    return false
  end
  function ow:scriptMove(_, _, _, done) if done then done() end return true end
  function ow:queueScript(rows, extra)
    return session:runRows(rows, extra)
  end
  function ow:replaceBlock() return true end
  function ow:refreshObjectVisibility() return true end
  function ow:syncObjectVisibility() return true end
  function ow:killParallel() return true end
  function ow:pushBattle() return false end
  function ow:engageTrainer(_, done) if done then done() end return false end
  function ow:startTrainerApproach() return false end
  function ow:afterBattle() return false end
  function ow:setMap() return false end
  function ow:warpTo() return false end
  function ow:flyTo() return false end
  function ow:healPoint() return nil end
  function ow:facingIsShoreOrWater() return false end
  function ow:hasHiddenItemLeft() return false end
  function ow:objectAtCell() return nil end
  function ow:pushableAtCell() return nil end
  function ow:dexRating(done)
    if session.adapters and session.adapters.show then
      session.adapters.show(session.world, "POKéDEX evaluation isn't changed by Kanto free roam.", done)
    elseif done then done() end
  end
  self.ow = ow
  return ow
end

function Session:proxyGame()
  if self.gameProxy then return self.gameProxy end
  local actual = self.world and self.world.game or {}
  local game = {
    data = makeData(actual.data, self.region, self.mapId),
    save = makeSave(actual.save, self.kantoEvents),
    stack = self:proxyStack(),
    input = actual.input,
    stringBuffer = actual.stringBuffer,
    boxNumString = actual.boxNumString,
    boxMonNicks = actual.boxMonNicks,
  }
  game.overworld = self:proxyWorld()
  self.gameProxy = setmetatable(game, {
    __index = function(_, key)
      -- Do not expose the real state stack / overworld through fallback.
      if key == "stack" or key == "overworld" or key == "save" then return nil end
      return actual[key]
    end,
  })
  return self.gameProxy
end

function Session:patchEnvironment()
  local saved = {}
  local proxyGame = self:proxyGame()

  local okGV, GameVersion = pcall(require, "src.core.GameVersion")
  if okGV and type(GameVersion) == "table" then
    patchFunction(GameVersion, "isYellow", function() return true end, saved)
    patchFunction(GameVersion, "isRed", function() return false end, saved)
    patchFunction(GameVersion, "isBlue", function() return false end, saved)
    patchFunction(GameVersion, "get", function() return "yellow" end, saved)
    patchFunction(GameVersion, "generation", function() return 1 end, saved)
  end

  local okTB, TextBox = pcall(require, "src.render.TextBox")
  if okTB and type(TextBox) == "table" and type(TextBox.new) == "function" then
    local realSubstitute = TextBox.substitute
    patchFunction(TextBox, "new", function(game, text, onDone, opts)
      local body = tostring(text or "")
      if type(realSubstitute) == "function" then
        local okSub, substituted = pcall(realSubstitute, proxyGame, body)
        if okSub and type(substituted) == "string" then body = substituted end
      end
      return {
        __kantoDialogueText = true,
        text = body,
        onDone = onDone,
        opts = opts,
      }
    end, saved)
  end

  local okLM, ListMenu = pcall(require, "src.ui.ListMenu")
  if okLM and type(ListMenu) == "table" and type(ListMenu.new) == "function" then
    patchFunction(ListMenu, "new", function(_, title, items, opts)
      return { __kantoDialogueMenu = true, title = title, items = items, opts = opts }
    end, saved)
  end

  local okScreens, Screens = pcall(require, "src.ui.Screens")
  if okScreens and type(Screens) == "table" then
    patchFunction(Screens, "push", function() M.suppressedScreens = M.suppressedScreens + 1; return false end, saved)
  end

  for _, moduleName in ipairs({ "src.core.Sound", "src.core.Music" }) do
    local okAudio, Audio = pcall(require, moduleName)
    if okAudio and type(Audio) == "table" then
      for key, fn in pairs(Audio) do
        if type(fn) == "function" and (key:match("^play") or key:match("^stop")
            or key:match("^fade") or key:match("^duck")) then
          patchFunction(Audio, key, function() return nil end, saved)
        end
      end
    end
  end

  -- ScriptRunner resolves every row through Commands.resolve.  Present a
  -- deliberately small command surface: dialogue/control/clone-only flag
  -- operations use the engine implementation; everything else becomes a
  -- harmless no-op so a text_asm cannot move/warp/battle/award the real game.
  local okCommands, Commands = pcall(require, "src.script.Commands")
  if okCommands and type(Commands) == "table" and type(Commands.resolve) == "function" then
    local originalResolve = Commands.resolve
    patchFunction(Commands, "resolve", function(data, name)
      if SAFE_COMMAND[tostring(name)] or tostring(name):match("^check_")
          or tostring(name):match("^jump") then
        return originalResolve(data, name)
      end
      local fn = originalResolve(data, name)
      if not fn then return nil end
      if HALT_COMMAND[tostring(name)] then
        return function()
          M.suppressedCommands = M.suppressedCommands + 1
          return "end"
        end, { foreground = false }
      end
      return function() M.suppressedCommands = M.suppressedCommands + 1; return nil end,
        { foreground = false }
    end, saved)
  end

  return saved
end

function Session:withSandbox(fn, ...)
  local args = { ... }
  local saved = self:patchEnvironment()
  local ok, a, b, c = xpcall(function() return fn(unpack(args)) end,
    function(err) return debug and debug.traceback and debug.traceback(err, 2) or tostring(err) end)
  restorePatches(saved)
  if not ok then
    M.errors = M.errors + 1
    M.lastError = tostring(a)
    return false, a
  end
  return true, a, b, c
end

function Session:resume(fn, ...)
  if type(fn) ~= "function" then self:drain(); return end
  self:withSandbox(fn, ...)
  self:drain()
end

local function safePresentationOpts(opts)
  if type(opts) ~= "table" then return nil end
  local out = {}
  if opts.instant == true then out.instant = true end
  local auto = opts.auto
  if type(auto) == "table" then
    local clean = {
      delay = math.max(0, tonumber(auto.delay) or 0),
      wait = auto.wait == true,
    }
    -- The captured function closes over the detached proxy game/save. Run it
    -- only when the real Kanto TextBox reaches the cartridge's audio beat;
    -- arbitrary overlap/tick callbacks never cross the sandbox boundary.
    if type(auto.sound) == "function" then
      clean.sound = function()
        local ok, value = pcall(auto.sound)
        if ok then M.presentationAudio = M.presentationAudio + 1; return value end
        M.errors = M.errors + 1
        M.lastError = tostring(value)
        return nil
      end
    end
    out.auto = clean
  elseif auto == true then
    out.auto = true
  end
  return next(out) and out or nil
end

function Session:drain()
  if self.presenting then return true end
  local job = table.remove(self.queue, 1)
  if not job then return self.started == true end
  self.presenting = true
  if job.__kantoDialogueText then
    local body = textFromMarker(job)
    if not body or body == "" then
      self.presenting = false
      self:resume(job.onDone)
      return true
    end
    local opts = job.opts or {}
    if type(opts.choice) == "function" and self.adapters and self.adapters.ask then
      local shown = self.adapters.ask(self.world, body, function(yes)
        self.presenting = false
        self:resume(opts.choice, yes == true)
      end)
      if shown then return true end
    elseif self.adapters and self.adapters.show then
      local shown = self.adapters.show(self.world, body, function()
        self.presenting = false
        self:resume(job.onDone)
      end, safePresentationOpts(opts))
      if shown then return true end
    end
  elseif job.__kantoDialogueMenu and self.adapters and self.adapters.list then
    local items = type(job.items) == "table" and job.items or {}
    local opts = job.opts or {}
    local shown = self.adapters.list(self.world, tostring(job.title or ""), items,
      function(item, menu)
        self.presenting = false
        if type(opts.onChoose) == "function" then self:resume(opts.onChoose, item, menu)
        else self:drain() end
      end, opts.footer)
    if shown then return true end
  end
  self.presenting = false
  self:drain()
  return self.started == true
end

function Session:runRows(rows, extra)
  local okRunner, ScriptRunner = pcall(require, "src.script.ScriptRunner")
  if not (okRunner and ScriptRunner and type(ScriptRunner.new) == "function") then
    return false
  end
  local runner = ScriptRunner.new(self:proxyGame(), self:proxyWorld())
  self.runner = runner
  self.ow.runner = runner
  local context = type(extra) == "table" and extra or {}
  context.npc = context.npc or self.npc
  context.map = context.map or self.map
  context.onDone = context.onDone or function() end
  local ok = self:withSandbox(function() runner:run(rows, context) end)
  if ok then self.started = true end
  return ok
end

function Session:runFunction(handler)
  local done = function() end
  local ok = self:withSandbox(handler, self:proxyGame(), self:proxyWorld(), self.npc, done)
  if ok then self.started = true end
  return ok
end

local function fallbackText(region, info, textConst)
  local loaded = region and region.loaded
  local text = loaded and loaded.text
  if type(text) ~= "table" then return nil end
  -- A handful of old hand ports use a local label with the same spelling as
  -- the far text except for the leading underscore.  Try that before falling
  -- back to an ellipsis; never guess unrelated dialogue.
  local label = type(info) == "table" and info.label or nil
  for _, candidate in ipairs({
    type(info) == "table" and info.text or nil,
    label and ("_" .. label) or nil,
    textConst,
  }) do
    if candidate and type(text[candidate]) == "string" and text[candidate] ~= "" then
      return text[candidate]
    end
  end
  return nil
end

function M.try(args)
  args = type(args) == "table" and args or {}
  local world, region = args.world, args.region
  local mapId, textConst = tostring(args.mapId or ""), args.textConst
  if mapId == "" or not textConst or not (world and world.game) then return false end
  local handler, source = engineTalk(mapId, textConst)
  local session = setmetatable({
    world = world,
    region = region,
    mapId = mapId,
    map = args.map,
    obj = args.obj,
    entity = args.entity,
    excursion = args.excursion,
    adapters = args.adapters or {},
    kantoEvents = args.kantoEvents or {},
    npc = makeNpc(args.obj, args.entity),
    queue = {}, presenting = false, source = source,
  }, Session)
  M.sessions = M.sessions + 1

  local ok = false
  if type(handler) == "table" then
    ok = session:runRows(handler, { npc = session.npc, map = session.map })
  elseif type(handler) == "function" then
    ok = session:runFunction(handler)
  end
  if ok then
    session:drain()
    if session.started and (session.presenting or #session.queue > 0) then
      M.handled = M.handled + 1
      M.lastSource = source
      return true
    end
    -- Some handlers finish synchronously after only state/cutscene actions.
    -- They do not count as dialogue; fall through to extracted text/fallback.
  end

  local fallback = fallbackText(region, args.info, textConst)
  if fallback and args.adapters and args.adapters.show then
    M.fallbacks = M.fallbacks + 1
    return args.adapters.show(world, fallback) == true
  end
  if args.allowEllipsis ~= false and args.adapters and args.adapters.show then
    M.fallbacks = M.fallbacks + 1
    -- Last-resort usability guarantee: no visible Kanto NPC silently consumes
    -- A because an upstream text_asm has not been hand-ported yet.
    return args.adapters.show(world, "...") == true
  end
  return false
end

function M.audit(region)
  local loaded = region and region.loaded or {}
  local maps, pointers, text = loaded.maps or {}, loaded.textPointers or {}, loaded.text or {}
  local out = { npcText = 0, signText = 0, plain = 0, asm = 0, service = 0,
    missingPointer = 0, direct = 0, guaranteedInteractive = 0 }
  local function classify(mapId, def, textConst, npc)
    if not textConst then return end
    if npc then out.npcText = out.npcText + 1 else out.signText = out.signText + 1 end
    local tableForMap = pointers[def and def.label or mapId] or pointers[mapId]
    local info = type(tableForMap) == "table" and tableForMap[textConst] or nil
    if type(info) == "table" then
      if info.mart or info.nurse or info.pc or info.cableClub then out.service = out.service + 1
      elseif info.asm then out.asm = out.asm + 1
      elseif info.text and type(text[info.text]) == "string" then out.plain = out.plain + 1
      else out.missingPointer = out.missingPointer + 1 end
    elseif type(text[textConst]) == "string" then out.direct = out.direct + 1
    else out.missingPointer = out.missingPointer + 1 end
    -- v0.3.53's dispatch guarantees every TEXT_* object/sign reaches either
    -- a real handler/plain line or the final non-muting fallback.
    out.guaranteedInteractive = out.guaranteedInteractive + 1
  end
  for mapId, def in pairs(maps) do
    if type(def) == "table" then
      for _, obj in ipairs(def.objects or {}) do classify(mapId, def, obj.text, true) end
      for _, sign in ipairs(def.signs or {}) do classify(mapId, def, sign.text, false) end
    end
  end
  out.totalTextInteractions = out.npcText + out.signText
  return out
end

function M.resetCaches()
  yellowTalkCache = nil
end

return M
