-- Mt. Battle 100 overworld entry point: spawns the Wes/Red NPC and wires
-- the real talk interception, cross-generation.
--
-- Gen 1 mechanism verified live in Phase 0 Spike 3: patching
-- require("src.world.OverworldController").talkTo (the module IS the
-- live singleton class table -- OverworldController.lua's final line is
-- `return OverworldState`) is visible to every later require() of the
-- same module name, independent of the mod sandbox's _G isolation
-- (package.loaded is process-wide; _G is not -- confirmed as two
-- SEPARATE facts, not one).
--
-- Gen 2: mod.world is expected to BE the Gen2Compat proxy object on that
-- generation (WorldAPI:spawnNpc/removeNpc, src/world/WorldAPI.lua:
-- 468-481, is reached via mod.world either way) -- so mod.world.talkTo is
-- wrapped too, defensively, alongside the direct module patch. Spike 3's
-- log flags this as needing a live generation=2 SDK confirmation before
-- being treated as verified; wrapping both seams is the safe default
-- until that follow-up runs, not a claim that both are proven necessary.
local V=... or {}
local req=V.engineRequire or require
local EntryFlow=V.MtBattleEntryFlow
local OG={}

OG.TAG="mtBattleGate"
-- game.ready is a startup hint, not a permanent owner. Capture the current
-- native Game from input.step and resolve again at the NPC interaction. Gen 1
-- controllers do not have to expose self.game; Gen 2 world owners may do so.
OG.liveGame=nil
OG.trainerModel="wes"

local function wrapTalkTo(target,onGate)
  if type(target)~="table" or type(target.talkTo)~="function" then return false end
  if target.__mtbWrapped then return true end -- idempotent: never double-wrap
  local original=target.talkTo
  target.talkTo=function(self,npc)
    if npc and npc.def and npc.def[OG.TAG] then
      return onGate(self,npc) and true or false
    end
    return original(self,npc)
  end
  target.__mtbWrapped=true
  return true
end

-- Installs the talk interception. `onGate(overworld,npc)` is called only
-- for OUR spawned NPC; its return value becomes talkTo's own return
-- value (true = handled). Safe to call more than once (idempotent per
-- target, per wrapTalkTo's own guard).
function OG.installTalkHook(onGate)
  local ok,OverworldState=pcall(req,"src.world.OverworldController")
  if ok then wrapTalkTo(OverworldState,onGate) end
end

-- Called from mod.world:spawnNpc's context (real overworld boot only --
-- confirmed in Spike 3 that this cannot be exercised outside a live
-- game). `mod` is the real mod API object; `mapId`/`x`/`y` place the NPC;
-- `spriteId` is the Wes/Red 3D-model-linked overworld sprite (resolved
-- by HubStage/TrainerRoster, not this module -- OverworldGate only
-- places the 2D overworld marker; the 3D presentation happens once the
-- player enters the hub, per the design's "transfers to a fully 3D
-- render" requirement).
function OG.spawn(mod,mapId,x,y,spriteId,textId)
  if not (mod and mod.world and mod.world.spawnNpc) then return nil,"mod.world unavailable" end
  return mod.world:spawnNpc(mapId,{
    sprite=spriteId,x=x,y=y,range="ANY_DIR",movement="STILL",
    text=textId,[OG.TAG]=true,
  })
end

-- One-time install: talk hook (both gens defensively) + hooking
-- map.entered to (re)spawn the NPC every time the target map loads,
-- since addRuntimeObject's insertion is NOT persisted across a map
-- reload (a runtime object lives only in the currently-loaded map's live
-- object list -- confirmed via direct read of OverworldState:
-- addRuntimeObject, Spike 3's log).
-- The tagged NPC must hand the real stack/save owner into every hub screen.
-- A stale startup reference must not crash showOffer or silently create a
-- detached stack. Preserve the injected EntryFlow seam used by older hosts.
local function defaultOnGateOpened(overworld)
  if not EntryFlow then return false,"Mt. Battle entry flow unavailable" end
  local game,why
  if type(EntryFlow.resolveGame)=="function" then
    game,why=EntryFlow.resolveGame(nil,overworld)
  else
    game=OG.liveGame or (OG.mod and OG.mod.game)
  end
  if not game then
    OG.lastEntryError=why or "Mt. Battle live game unavailable"
    local log=OG.mod and OG.mod.log
    if log and type(log.warn)=="function" then
      pcall(log.warn,log,"MTB ENTRY FIX 1: %s",OG.lastEntryError)
    end
    return false,OG.lastEntryError
  end
  OG.liveGame=game
  local open=EntryFlow.showOffer or EntryFlow.start
  local ok,detail=open(game,OG.trainerModel)
  -- Legacy injected handlers have no return value; only explicit false fails.
  OG.lastEntryError=ok==false and detail or nil
  return ok~=false,detail
end
OG.onGateOpened=defaultOnGateOpened

function OG.install(mod,opts)
  if OG.installed then return end
  OG.installed=true
  OG.mod=mod
  opts=opts or {}

  local function observeGame(game)
    if EntryFlow and type(EntryFlow.observeGame)=="function" then
      OG.liveGame=EntryFlow.observeGame(game)
    else
      OG.liveGame=game
    end
  end
  -- Observe BEFORE downstream hooks/native NPC code, not after next(). Keep
  -- every return value and call the downstream handler exactly once. This hook
  -- only records a reference: no I/O, cache work, screen push or save mutation.
  if mod.hooks and type(mod.hooks.wrap)=="function" then
    mod.hooks:wrap("input.step",function(next,game,dt,...)
      observeGame(game)
      return next(game,dt,...)
    end,10000)
  end
  -- INDIGO_PLATEAU_POKECENTER_1F is a REAL Gen 2 map id, confirmed via
  -- tests/drivers/gold/map_regions.lua:555 (this project's own generated
  -- route-bot map graph). Gen 1's Indigo Plateau has no standalone
  -- Pokemon Center building (its League interior heals you directly) --
  -- this map only exists on a Gen 2 (Kanto post-Elite-Four) save, so this
  -- gate is reachable there, not on a Gen 1 save. That same region entry
  -- lists a real, walkable exit tile at (0,13) (the stairs down to
  -- POKECENTER_2F, part of the same single 115-tile connected room seeded
  -- at (14,1)) -- confirming (0,13) is real floor, not guessed. The NPC
  -- sits one tile off it, at (1,12), staying inside the room without
  -- sitting on the stairs warp itself -- the closest this offline
  -- environment can get to "bottom-left of the room" without a live tile
  -- grid; NOT independently walk-tested, same disclosure standard as
  -- every other placement in this feature.
  -- Mt. Battle must be reachable in BOTH supported generations.
  --
  -- Gen 1: the screenshot/test target is the actual Indigo Plateau League
  -- lobby.  The real map id is INDIGO_PLATEAU_LOBBY (16x12 tiles); (2,9)
  -- is the open lower-left side of the lobby, away from the stock NPC at
  -- (4,9) and the exit warps at (7,11)/(8,11).
  --
  -- Gen 2: keep the existing Kanto-postgame Pokemon Center placement.
  local defaultSprite=opts.spriteId or "SPRITE_SCIENTIST"
  local defaultText=opts.textId or "TEXT_MTBATTLE_VR_OFFER"
  local gates=opts.gates or {
    {mapId="INDIGO_PLATEAU_LOBBY",x=2,y=9},
    {mapId="INDIGO_PLATEAU_POKECENTER_1F",x=1,y=12},
  }
  -- Preserve the older single-map override API for tests/third-party callers.
  if opts.mapId then
    gates={{mapId=opts.mapId,x=opts.x or 1,y=opts.y or 12}}
  end
  if opts.trainerModel then OG.trainerModel=opts.trainerModel end
  if opts.onGateOpened then OG.onGateOpened=opts.onGateOpened end

  OG.installTalkHook(function(overworld,npc)
    if type(OG.onGateOpened)=="function" then OG.onGateOpened(overworld,npc) end
    return true
  end)

  if mod.world and type(mod.world.talkTo)=="function" then
    wrapTalkTo(mod.world,function(overworld,npc)
      if type(OG.onGateOpened)=="function" then OG.onGateOpened(overworld,npc) end
      return true
    end)
  end

  if mod.events and type(mod.events.on)=="function" then
    mod.events:on("game.ready",function(payload)
      local game=type(payload)=="table" and payload.game or nil
      observeGame(game)
    end)
    mod.events:on("map.entered",function(payload)
      local enteredMapId=type(payload)=="table" and (payload.mapId or payload.id) or nil
      if not enteredMapId then return end
      for _,gate in ipairs(gates) do
        if enteredMapId==gate.mapId then
          OG.spawn(
            mod,
            gate.mapId,
            gate.x,
            gate.y,
            gate.spriteId or defaultSprite,
            gate.textId or defaultText
          )
          break
        end
      end
    end)
  end
end

return OG
