-- Free Fly integration for Terrarium Advance Mod
-- Full port of the free_fly mod adapted for Terrarium's architecture
local V = ...

local function loadShared(file)
  local src = V.mod:read("lib/shared/" .. file)
  if not src then 
    V.mod.log:warn("Could not load " .. file .. " from lib/shared/")
    return nil 
  end
  local ok, chunk = pcall((loadstring or load), src, "@Terrarium/lib/shared/" .. file)
  if not ok then
    V.mod.log:error("Failed to compile " .. file .. ": " .. tostring(chunk))
    return nil
  end
  local ok2, result = pcall(chunk)
  if not ok2 then
    V.mod.log:error("Failed to execute " .. file .. ": " .. tostring(result))
    return nil
  end
  return result
end

local Sky = loadShared("skylib.lua")
if not Sky then
  V.mod.log:error("lib/shared/skylib.lua is missing -- Free Fly disabled")
  return {}
end

V.mod.log:info("Sky library loaded successfully")

-- Load ColosseumDexNames for Pokemon Player integration
local ColosseumDexNames = nil
local okDexNames, ColosseumDexNamesModule = pcall(V.require, "ColosseumDexNames")
if okDexNames and ColosseumDexNamesModule then
  ColosseumDexNames = ColosseumDexNamesModule
  V.mod.log:info("ColosseumDexNames loaded successfully for Pokemon Player integration")
else
  V.mod.log:warn("ColosseumDexNames not available, Pokemon Player integration disabled")
end

local FreeFly = {}
FreeFly.__index = FreeFly

local RISE_SPEED = 72

-- Free Fly options using Terrarium's ModSetting system
local ModSetting = V.require("ModSetting")

local altitudeSetting = ModSetting.new("free_fly_altitude", "FLY ALTITUDE",
  { "low", "med", "high" }, { "LOW", "MED", "HIGH" })
local speedSetting = ModSetting.new("free_fly_speed", "FLY SPEED",
  { "normal", "fast", "turbo" }, { "NORMAL", "FAST", "TURBO" })
local encountersSetting = ModSetting.new("free_fly_encounters", "AIR ENCOUNTERS",
  { true, false }, { "ON", "OFF" })
local spottedSetting = ModSetting.new("free_fly_spotted", "TRAINERS SPOT YOU",
  { true, false }, { "ON", "OFF" })
local gatesSetting = ModSetting.new("free_fly_gates", "STORY GATES",
  { true, false }, { "ON", "OFF" })
local badgesSetting = ModSetting.new("free_fly_badges", "BADGE CHECKS",
  { true, false }, { "ON", "OFF" })
local quickstartSetting = ModSetting.new("free_fly_quickstart", "QUICK START",
  { true, false }, { "ON", "OFF" })

local ALTS = { low = 32, med = 56, high = 80 }
local SPEEDS = { normal = 8, fast = 6, turbo = 4 }

local function cruiseAlt()
  local alt = altitudeSetting:get()
  return ALTS[alt] or 56
end

local function flyFrames()
  local speed = speedSetting:get()
  return SPEEDS[speed] or 8
end

local GIFT_SPECIES = "PIDGEOT"
local GIFT_LEVEL = 10
local GIFT_TAKEN = "MOD_FREE_FLY_PIDGEY_TAKEN"
local GIFT_TEXT = "TEXT_FREE_FLY_PIDGEY"

-- Flight state
local state = {
  phase = "idle",
  alt = 0,
  bob = 0,
  giftNpcId = nil,
  rider = nil,
  mountMon = nil,
  windCooldown = 0,
  expectBattle = nil,
  landmark = nil,
  riseGlide = 0,
  glide = 0,
  landRequest = nil,
  approachPath = nil,
  fpRef = nil,
  v3dRef = nil,
  voxelStateRef = nil,
  placedCam = nil,
  placeWanted = false,
  placeHeight = 0,
  prefetchedQueue = {},
  prefetchTick = 0,
  mesherRef = nil,
  skiesTake = nil,
  interceptCooldown = 0,
  askCooldown = 0,
  qsArmed = nil,
  qsHeld = nil,
  previousPokemonPlayerDex = nil,  -- Store previous Pokemon Player setting
  previousPokemonPlayerMarker = nil,  -- Store previous marker file content
  pokemonPlayerStateSaved = false  -- Track if we saved the state (needed for OFF detection)
}

local function flying()
  return state.phase ~= "idle"
end

local function knowsFly(mon)
  return Sky.knowsMove(mon, "FLY")
end

-- where the sky exists: outside maps, plus Viridian Forest, whose
-- canopy reads as open air even though vanilla classes it indoor
local function skyAbove(game, mapDef)
  if not mapDef then return false end
  local Map = require("src.world.Map")
  local FieldDefaults = require("src.world.FieldDefaults")
  if Map.isOutside(mapDef,
       FieldDefaults.field(game.data, "outsideTilesets")) then
    return true
  end
  -- Gen2 support: check environment byte (1 = TOWN, 2 = ROUTE)
  if mapDef.environment then
    local OUTDOOR_ENVIRONMENTS = { [1] = true, [2] = true }
    if OUTDOOR_ENVIRONMENTS[mapDef.environment] then
      return true
    end
  end
  return mapDef.tileset == "FOREST"
end

-- HM02 compatibility: the species' tmhm list is the same one the
-- machine-teach path checks, so eligibility exactly matches "could this
-- mon legitimately learn FLY"
local function canLearnFly(game, mon)
  local def = mon and game.data.pokemon[mon.species]
  for _, m in ipairs((def and def.tmhm) or {}) do
    if m == "FLY" then return true end
  end
  return false
end

-- who may field-use a move is the ENGINE'S question, not this mod's:
-- OverworldState:partyKnows routes through the fieldmove.eligibility
-- hook chain, so HM-relaxing mods (qol_toggles' FIELD MOVES ALL) and
-- anything else wrapping that hook decide alongside the vanilla check.
-- Returns the mon the chain nominates, or nil.
local function fieldMoveUser(ow, moveId)
  if ow and ow.partyKnows then
    local ok, user = pcall(ow.partyKnows, ow, moveId)
    if ok then return user end
  end
  return nil
end

-- a mon qualifies when it IS the gift (the marker outlives whatever a
-- randomizer does to its moves or its species' data), when it knows
-- FLY (knowing the move is vanilla's own bar for field use; the
-- species compat list can lie under randomizers), or when a mod has
-- relaxed the field-move rules through the engine's own chain, where
-- HM02 compatibility still gates as the machine-teach path would
local function eligibleFlyer(game, ow, mon)
  V.mod.log:info("ELIGIBLE CHECK: mon=%s, freeFlyGift=%s, knowsFly=%s",
               mon and mon.species or "nil",
               tostring(mon and mon.freeFlyGift),
               tostring(knowsFly(mon)))
  if mon and mon.freeFlyGift then return true end
  if knowsFly(mon) then return true end
  if not canLearnFly(game, mon) then
    V.mod.log:info("ELIGIBLE CHECK: cannot learn FLY")
    return false
  end
  local Runtime = require("src.mods.Runtime")
  local wantsHook = Runtime.wantsHook("fieldmove.eligibility")
  local fieldUser = fieldMoveUser(ow, "FLY")
  V.mod.log:info("ELIGIBLE CHECK: wantsHook=%s, fieldUser=%s",
               tostring(wantsHook), tostring(fieldUser ~= nil))
  return wantsHook and fieldUser ~= nil
end

local function badgeOk(game, mon)
  local badgesOption = badgesSetting:get()
  V.mod.log:info("BADGE CHECK: badges option=%s, mon.freeFlyGift=%s",
               tostring(badgesOption),
               tostring(mon and mon.freeFlyGift))
  if not badgesOption then
    V.mod.log:info("BADGE CHECK: badges option disabled, returning true")
    return true
  end
  if mon.freeFlyGift then
    V.mod.log:info("BADGE CHECK: gift mon, returning true")
    return true
  end
  local Badges = require("src.inventory.Badges")
  -- Gen1 uses THUNDERBADGE, Gen2 uses STORMBADGE for FLY
  -- Badges.has checks both inventory (Gen1) and flags (Gen2)
  local hasThunder = Badges.has(game.save, { id = "THUNDERBADGE" })
  local hasStorm = Badges.has(game.save, { id = "STORMBADGE" })
  V.mod.log:info("BADGE CHECK: THUNDERBADGE=%s, STORMBADGE=%s",
               tostring(hasThunder), tostring(hasStorm))
  if hasThunder or hasStorm then
    V.mod.log:info("BADGE CHECK: has required badge, returning true")
    return true
  end
  V.mod.log:info("BADGE CHECK: no required badge, returning false")
  return false
end

local function partyKnowsSurf(save)
  for _, mon in ipairs(save and save.party or {}) do
    if Sky.knowsMove(mon, "SURF") then return true end
  end
  return false
end

local function emitTakeoff(mon)
  pcall(function()
    V.mod.events:emit("mod.free_fly.takeoff",
      { species = mon and mon.species, level = mon and mon.level })
  end)
end

-- reason: "landed", "indoors", "blackout" or "save_loaded"; water is
-- true when the landing handed the player straight into surfing
local function emitLanded(reason, p)
  pcall(function()
    V.mod.events:emit("mod.free_fly.landed", {
      reason = reason,
      x = p and p.cellX, y = p and p.cellY,
      water = (p and p.surfing == true) or nil,
    })
  end)
end

local function startFlight(game, mon)
  if flying() then return end
  local ow = V.mod.world and V.mod.world:overworld()
  if not (ow and ow.player) then
    V.mod.log:warn("no overworld to take off from; FREEFLY skipped")
    return
  end
  state.phase, state.alt, state.bob = "rising", 0, 0
  -- wild flyers climb on a diagonal; so does the mount
  state.riseGlide = 2
  
  -- Mount resolution (inline version for early initialization)
  state.mountMon = mon
  local species = mon and mon.species
  local Player = require("src.world.Player")
  local Game = require("src.core.Game")
  local SpriteRenderer = require("src.render.SpriteRenderer")
  
  -- Convert the flying Pokemon's species to dex number and set Pokemon Player
  local flyingPokemonDex = nil
  if species then
    -- Save the current Pokemon Player setting before changing it
    local okInstall, PlayerModelInstall = pcall(V.require, "PlayerModelInstall")
    V.mod.log:info("PlayerModelInstall available for save: %s", tostring(okInstall))
    if okInstall and PlayerModelInstall then
      state.previousPokemonPlayerMarker = PlayerModelInstall.modelFilename()
      V.mod.log:info("Got marker filename: %s", tostring(state.previousPokemonPlayerMarker))
      local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
      V.mod.log:info("PlayerModel available for save: %s", tostring(okPlayerModel))
      if okPlayerModel and PlayerModel then
        state.previousPokemonPlayerDex = PlayerModel.getStadiumDex()
        V.mod.log:info("Got dex from PlayerModel: %s", tostring(state.previousPokemonPlayerDex))
      end
      state.pokemonPlayerStateSaved = true
      V.mod.log:info("Saved previous Pokemon Player: dex=%s, marker=%s, saved=%s", 
                     tostring(state.previousPokemonPlayerDex), 
                     tostring(state.previousPokemonPlayerMarker),
                     tostring(state.pokemonPlayerStateSaved))
    else
      V.mod.log:warn("PlayerModelInstall not available, cannot save previous Pokemon Player state")
    end
    
    -- Try to get dex number from species name
    -- Handle Gen2 SPECIES_XXX format first (e.g., SPECIES_006 -> dex 6)
    if species:match("^SPECIES_%d+$") then
      local dexNum = tonumber(species:match("^SPECIES_(%d+)$"))
      if dexNum then
        flyingPokemonDex = dexNum
        V.mod.log:info("Extracted dex %d from Gen2 species format %s", dexNum, species)
      end
    end
    
    -- If not found, try ColosseumDexNames reverse lookup for regular names
    if not flyingPokemonDex and ColosseumDexNames then
      -- Reverse lookup: find dex number for this species name
      for dex, name in pairs(ColosseumDexNames) do
        if name == species then
          flyingPokemonDex = dex
          V.mod.log:info("Found dex %d for species %s", dex, species)
          break
        end
      end
    end
    
    -- If not found in ColosseumDexNames, try to look up in game data
    if not flyingPokemonDex then
      local pokemonDef = Game.data.pokemon[species]
      if pokemonDef and pokemonDef.number then
        flyingPokemonDex = pokemonDef.number
        V.mod.log:info("Found dex %d from game data for species %s", flyingPokemonDex, species)
      end
    end
    
    -- Set Pokemon Player to this dex number
    if flyingPokemonDex then
      local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
      if okPlayerModel and PlayerModel then
        local okLoad = PlayerModel.loadStadium(flyingPokemonDex)
        if okLoad then
          if okInstall and PlayerModelInstall then
            PlayerModelInstall.writeMarker("stadium_player_" .. flyingPokemonDex)
            V.mod.log:info("Set Pokemon Player to dex %d (%s) for FreeFly", flyingPokemonDex, species)
          end
        else
          V.mod.log:warn("Failed to load Pokemon Player model for dex %d", flyingPokemonDex)
        end
      end
    else
      V.mod.log:warn("Could not find dex number for species %s", species)
    end
  end
  
  -- Ensure SPRITE_BIRD is loaded as fallback
  if not Player.__freeFlyBird then
    if Game.data.sprites.SPRITE_BIRD then
      Player.__freeFlyBird = SpriteRenderer.new(Game.data.sprites.SPRITE_BIRD, "free_fly_mount")
    end
  end

  -- Try to use the Pokémon's actual sprite using the follower sprite service
  local monSprite = nil
  local mountSpecies = species
  
  if mountSpecies then
    -- Try to use the follower sprite service (same as roamers/followers)
    local ok, spriteService = pcall(V.require, "follower/sprite_service")
    if ok and spriteService and spriteService.resolveFollowerSprite then
      local shiny = mon.shiny == true or mon.isShiny == true
      local resolved = spriteService:resolveFollowerSprite({
        species = mountSpecies,
        shiny = shiny,
        surface = "land",
        role = "free_fly_mount",
        game = Game,
      })
      if resolved and resolved.image then
        monSprite = SpriteRenderer.new({
          id = "SPRITE_FREE_FLY_MOUNT",
          image = resolved.image,
          frames = resolved.frames or 6,
          walker = resolved.walker ~= false,
          trueColor = resolved.trueColor ~= false,
        }, "free_fly_" .. mountSpecies)
        V.mod.log:info("Using follower sprite service for species %s: %s", tostring(mountSpecies), tostring(resolved.image))
      else
        V.mod.log:info("Follower sprite service returned nil for species %s", tostring(mountSpecies))
      end
    else
      V.mod.log:info("Follower sprite service not available")
    end
  end

  -- Fall back to Sky.mountSprite if species sprite not available
  Player.__freeFlyMount = monSprite or (mountSpecies and Sky.mountSprite(Game.data, mountSpecies, "free_fly")) or Player.__freeFlyBird
  Player.__freeFlyMountScale = mountSpecies and Sky.dexScale(Game.data, mountSpecies) or 1
  V.mod.log:info("Mount resolved: species=%s, scale=%s, using=%s", tostring(mountSpecies), tostring(Player.__freeFlyMountScale), tostring(monSprite and "species_sprite" or "fallback"))
  
  -- taking off from a surf dismounts into the air
  ow.player.surfing = nil
  ow.player.freeFlying = true
  pcall(function()
    require("src.core.Sound").play(require("src.core.Game").data, "Fly")
  end)
  V.mod.log:info("took off; press B over walkable ground to land")
  emitTakeoff(mon)
end

-- a sprite-source mod changed its settings mid-flight: the mount
-- re-dresses in the new art without landing
V.mod.events:on("mod.options_changed", function(payload)
  if not Sky.spriteSourceChanged(payload) then return end
  if flying() and state.resolveMount then
    state.resolveMount(state.mountMon)
  end
  
  -- Also update if Pokemon Player setting changed
  if payload and payload.id == "DRAMATIC_SHAPE:pokemonPlayer" and flying() then
    V.mod.log:info("Pokemon Player setting changed mid-flight, updating mount")
    state.resolveMount(state.mountMon)
  end
end)

-- render pipelines (voxel, tilt) billboard every entity through pose();
-- while flying the player's own card becomes the bird, and this ghost
-- entity carries the player figure seated above it.  Invisible in the
-- flat 2D view, where Player.draw composes the ride itself.
local Rider = {}
Rider.__index = Rider
-- px/py/cellX/cellY are real fields, not conveniences: the overworld
-- y-sorts entities on py and the voxel capture does arithmetic on it,
-- so an entity without them crashes both passes
function Rider.new(player)
  return setmetatable({ player = player, passable = true,
                        px = player.px, py = player.py,
                        cellX = player.cellX, cellY = player.cellY }, Rider)
end
function Rider:pose()
  local p = self.player
  local lift = math.floor((p.freeFlyAlt or 0) + 0.5)
  -- always the WALKING sheet: while airborne p.sprite is the mount
  return p.freeFlyWalkSprite or p.sprite, p.px, p.py - lift - 6,
         p.facing, 0, false, false
end
function Rider:draw() end

-- ------- public hooks, all pass-through unless airborne

V.mod.hooks:wrap("movement.collision", function(next, allowed, ctx)
  if flying() and ctx.mover and ctx.mover.freeFlying then
    -- very tall buildings stay walls even to a flyer, sealed rooftop
    -- plazas included: you ride up to the facade and bump
    local lm = state.landmark
    if lm and lm.cells and ctx.map and lm.mapId == ctx.map.id
       and lm.cells[ctx.toY * lm.w + ctx.toX] then
      ctx.reason = "tile"
      return false
    end
    if ctx.reason == "tile" or ctx.reason == "entity" then
      ctx.reason = nil
      return true
    end
  end
  return next(allowed, ctx)
end)

-- airborne you can only flush other flyers: the vanilla roll stands,
-- but a non-FLYING result becomes no encounter at all
V.mod.hooks:wrap("encounter.roll", function(next, encDef, ctx)
  local enc = next(encDef, ctx)
  if not (enc and flying()) then return enc end
  if not encountersSetting:get() then return nil end
  local game = require("src.core.Game")
  if Sky.hasType(game.data, enc.species, "FLYING") then return enc end
  return nil
end)

V.mod.hooks:wrap("movement.speed", function(next, frames, ctx)
  if flying() then return math.min(frames, flyFrames()) end
  return next(frames, ctx)
end)

V.mod.hooks:wrap("save.write", function(next, game)
  if flying() then
    V.mod.log:warn("can't save mid-flight; land first (press B)")
    return false
  end
  return next(game)
end)

V.mod.hooks:wrap("ui.party.submenu", function(next, game, items, mon, ctx)
  local out = next(game, items, mon, ctx)
  if type(out) ~= "table" then return out end
  local ow = ctx and ctx.overworld
  V.mod.log:info("FREEFLY HOOK: ow=%s, map=%s, flying=%s",
               tostring(ow ~= nil),
               ow and ow.map and ow.map.id or "nil",
               tostring(flying()))
  if not (ow and ow.map and ow.map.def) or flying() then
    V.mod.log:info("FREEFLY: early return - no overworld or flying")
    return out
  end
  local eligible = eligibleFlyer(game, ow, mon)
  V.mod.log:info("FREEFLY: eligibleFlyer=%s", tostring(eligible))
  local badge = badgeOk(game, mon)
  V.mod.log:info("FREEFLY: badgeOk=%s", tostring(badge))
  if not (eligible and badge) then
    V.mod.log:info("FREEFLY: failed eligibility or badge check")
    return out
  end
  if ow.player and ow.player.onBike then
    V.mod.log:info("FREEFLY: on bike")
    return out
  end
  local sky = skyAbove(game, ow.map.def)
  V.mod.log:info("FREEFLY: skyAbove=%s", tostring(sky))
  if not sky then
    V.mod.log:info("FREEFLY: not sky above")
    return out
  end
  V.mod.log:info("FREEFLY: adding FREEFLY option")
  table.insert(out, 1, { label = "FREEFLY", onSelect = function(m, g)
    -- unwind party menu / start menu back to the overworld, then lift off
    local stack = g.stack
    while stack:top() and not stack:top().isOverworld do stack:pop() end
    startFlight(g, m)
  end })
  return out
end)

-- ------- the Pallet Town Pidgeot: a quick way to get a FLY user

-- after give_pokemon lands the gift, put FLY in its move list; PIDGEY
-- stays accepted for anything replaying against an older save
V.mod.content.commands:register("free_fly:teach_fly", {
  foreground = true,
  fn = function(ctx)
    local function teach(mon, anySpecies)
      if not mon then return false end
      -- Handle both Gen 1 (PIDGEOT) and Gen 2 (SPECIES_164) gift species
      if not anySpecies and mon.species ~= GIFT_SPECIES and mon.species ~= "PIDGEY" and mon.species ~= "SPECIES_164" then
        return false
      end
      -- marks the gift so the BADGE CHECKS option exempts its flights;
      -- rides the mon table, so it survives in the save
      mon.freeFlyGift = true
      for _, mv in ipairs(mon.moves or {}) do
        if mv.id == "FLY" then return true end
      end
      local flyDef = ctx.game.data.moves.FLY
      local slot = { id = "FLY", pp = flyDef and flyDef.pp or 15 }
      mon.moves = mon.moves or {}
      if #mon.moves >= 4 then
        mon.moves[#mon.moves] = slot
      else
        table.insert(mon.moves, slot)
      end
      return true
    end
    for i = #ctx.save.party, 1, -1 do
      if teach(ctx.save.party[i]) then return end
    end
    for _, box in ipairs(ctx.save.boxes or {}) do
      for _, mon in ipairs(box) do
        if teach(mon) then return end
      end
    end
    -- no bird by name: a randomizer swapped the gift's species.  This
    -- command only runs right after give_pokemon, so the newest party
    -- member IS the gift; it gets FLY and the marker all the same
    local newest = ctx.save.party[#ctx.save.party]
    if teach(newest, true) then
      V.mod.log:info("gift became %s; taught FLY anyway",
                   tostring(newest.species))
      return
    end
    V.mod.log:warn("gift %s not found; FLY not taught", GIFT_SPECIES)
  end,
})

V.mod.content.commands:register("free_fly:pidgey_taken", {
  foreground = true,
  fn = function()
    if state.giftNpcId then
      V.mod.world:removeNpc(state.giftNpcId)
      state.giftNpcId = nil
    end
  end,
})

-- the YES branch of the sea-crossing confirm; remembered per save so
-- each map asks once
V.mod.content.commands:register("free_fly:allow_crossing", {
  foreground = true,
  fn = function(_, mapId)
    local ok = V.mod.save:get("dangerOk")
    if type(ok) ~= "table" then ok = {} end
    ok[mapId] = true
    V.mod.save:set("dangerOk", ok)
  end,
})

V.mod.content.map_scripts:register("PALLET_TOWN", {
  talk = {
    [GIFT_TEXT] = {
      { "check_flag", GIFT_TAKEN },
      { "jump_if_true", "end" },
      { "show_text", "The tag on this\nPIDGEOT's neck\nsays it can fly\nanywhere without\na badge!\fUse only if\nyou dare" },
      { "choice", { "TAKE IT", "LEAVE IT" } },
      { "jump_if_false", "refused" },
      { "set_flag", GIFT_TAKEN },
      { "give_pokemon", GIFT_SPECIES, GIFT_LEVEL },
      { "free_fly:teach_fly" },
      { "free_fly:pidgey_taken" },
      { "show_text", "PIDGEOT is glad to\ncarry you!\fPick FREEFLY in\nits party menu." },
      { "jump", "end" },

      { "label", "refused" },
      { "show_text", "PIDGEOT tilts its\nhead." },
    },
  },
})

-- Register New Bark Town gift NPC (Gen 2)
V.mod.content.map_scripts:register("NEW_BARK_TOWN", {
  talk = {
    [GIFT_TEXT] = {
      { "check_flag", GIFT_TAKEN },
      { "jump_if_true", "end" },
      { "show_text", "The tag on this\nNOCTOWL's neck\nsays it can fly\nanywhere without\na badge!\fUse only if\nyou dare" },
      { "choice", { "TAKE IT", "LEAVE IT" } },
      { "jump_if_false", "refused" },
      { "set_flag", GIFT_TAKEN },
      { "give_pokemon", "SPECIES_164", GIFT_LEVEL },
      { "free_fly:teach_fly" },
      { "free_fly:pidgey_taken" },
      { "show_text", "NOCTOWL is glad to\ncarry you!\fPick FREEFLY in\nits party menu." },
      { "jump", "end" },
      { "label", "refused" },
      { "show_text", "NOCTOWL tilts its\nhead." },
    },
  },
})

-- ids of our runtime gift NPCs already living in the map def (the
-- legacy FREE_FLY_PIDGEY name spans both species):
-- spawnNpc persists into def.objects, so they outlive the visit that
-- spawned them and come back on every later map load
local function giftObjectIds(game)
  local ids = {}
  -- Check Gen 1 PALLET_TOWN
  local def = game.data.maps and game.data.maps.PALLET_TOWN
  for _, obj in ipairs(def and def.objects or {}) do
    if obj.runtime and obj.name == "FREE_FLY_PIDGEY" then
      ids[#ids + 1] = "PALLET_TOWN_obj_" .. obj.index
    end
  end
  -- Check Gen 2 NEW_BARK_TOWN
  def = game.data.maps and game.data.maps.NEW_BARK_TOWN
  for _, obj in ipairs(def and def.objects or {}) do
    if obj.runtime and obj.name == "FREE_FLY_GIFT" then
      ids[#ids + 1] = "NEW_BARK_TOWN_obj_" .. obj.index
    end
  end
  return ids
end

local function spawnGift()
  local ow = V.mod.world and V.mod.world:overworld()
  if not ow then return end

  -- Check for both Gen 1 (PALLET_TOWN) and Gen 2 (NEW_BARK_TOWN)
  local mapId = ow.map and ow.map.id
  if mapId ~= "PALLET_TOWN" and mapId ~= "NEW_BARK_TOWN" then return end

  local game = require("src.core.Game")
  local taken = game.save and game.save.flags and game.save.flags[GIFT_TAKEN]
  local wanted = quickstartSetting:get() and not taken

  -- adopt the survivor from an earlier visit instead of spawning a
  -- twin; retire it (and any twins already accumulated) when the gift
  -- is taken or the option is off
  local existing = giftObjectIds(game)
  for i = #existing, wanted and 2 or 1, -1 do
    V.mod.world:removeNpc(existing[i])
    table.remove(existing, i)
  end
  if existing[1] then
    state.giftNpcId = existing[1]
    return
  end
  if not wanted then return end

  -- Determine gift species and dex based on generation
  local giftSpecies = GIFT_SPECIES
  local giftDex = 18 -- PIDGEOT dex
  local generation = game.data and game.data.generation or 1

  -- Detect generation by checking species name format
  -- Gen 1 uses names like "VICTREEBEL", Gen 2 uses "SPECIES_001" format
  local k1, v1 = next(game.data and game.data.pokemon or {})
  if k1 and string.sub(tostring(k1), 1, 8) == "SPECIES_" then
    generation = 2
    V.mod.log:info("Detected Gen 2 from species name format: %s", tostring(k1))
  else
    generation = 1
    V.mod.log:info("Detected Gen 1 from species name format: %s", tostring(k1))
  end

  V.mod.log:info("Generation detected: %d (game.data.generation=%s)", generation, tostring(game.data and game.data.generation))

  if generation == 2 then
    giftSpecies = "SPECIES_164" -- NOCTOWL dex 164
    giftDex = 164 -- NOCTOWL dex
    V.mod.log:info("Using Gen 2 gift: SPECIES_164 (dex 164)")
  else
    giftSpecies = "PIDGEOT" -- Use original format for Gen 1
    giftDex = 18 -- PIDGEOT dex
    V.mod.log:info("Using Gen 1 gift: PIDGEOT (dex 18)")
  end

  -- first free walkable cell near the town center
  local Collision = require("src.world.Collision")
  local spots = { { 10, 10 }, { 9, 10 }, { 11, 10 }, { 10, 11 },
                  { 12, 9 }, { 8, 10 }, { 9, 11 }, { 12, 10 } }
  for _, s in ipairs(spots) do
    local x, y = s[1], s[2]
    if ow.map:isWalkableCell(x, y)
       and not Collision.occupied(ow.entities, x, y, nil) then
      -- Spawn NPC with default sprite first (same approach as roamers)
      state.giftNpcId = V.mod.world:spawnNpc(mapId, {
        name = "FREE_FLY_GIFT",
        sprite = "SPRITE_BIRD",
        movement = "STAY",
        range = "DOWN",
        text = GIFT_TEXT,
        x = x, y = y,
      })

      V.mod.log:info("Spawned NPC with id: %s", tostring(state.giftNpcId))

      -- Find the NPC and apply species sprite using the same approach as roamers
      local npc = nil
      for _, entity in ipairs(ow.entities or {}) do
        if entity and entity.id == state.giftNpcId then
          npc = entity
          break
        end
      end

      if npc then
        V.mod.log:info("Found NPC entity: %s", tostring(npc.id))

        -- Resolve sprite using follower sprite service
        -- Use appropriate format for sprite resolution
        local spriteSpecies = generation == 2 and "SPECIES_164" or "PIDGEOT"
        local ok, spriteService = pcall(V.require, "follower/sprite_service")
        V.mod.log:info("Sprite service available: %s", tostring(ok))
        if ok and spriteService and spriteService.resolveFollowerSprite then
          local resolved = spriteService:resolveFollowerSprite({
            species = spriteSpecies,
            shiny = false,
            surface = "land",
            role = "free_fly_gift",
            game = game,
          })
          V.mod.log:info("Sprite resolution for %s: image=%s, frames=%s", tostring(spriteSpecies), tostring(resolved and resolved.image or "nil"), tostring(resolved and resolved.frames or "nil"))
          if resolved and resolved.image then
            local SpriteRenderer = require("src.render.SpriteRenderer")
            local ok2, sprite = pcall(SpriteRenderer.new, {
              id = "SPRITE_FREE_FLY_GIFT",
              image = resolved.image,
              frames = resolved.frames or 6,
              walker = resolved.walker ~= false,
              trueColor = resolved.trueColor ~= false,
            }, npc.id)
            if ok2 and sprite then
              npc.sprite = sprite
              sprite._colosseumEntity = npc
              V.mod.log:info("Applied sprite for %s: %s", tostring(spriteSpecies), tostring(resolved.image))
            else
              V.mod.log:warn("Failed to create SpriteRenderer for %s: ok=%s", tostring(giftSpecies), tostring(ok2))
            end
          else
            V.mod.log:warn("No sprite resolved for %s", tostring(giftSpecies))
          end
        else
          V.mod.log:warn("Follower sprite service not available: ok=%s, service=%s", tostring(ok), tostring(spriteService ~= nil))
        end

        -- Tag for Colosseum (same as roamers)
        npc._colosseumDex = giftDex
        npc._wildsFollowerSpecies = giftSpecies
        npc.pokepcShiny = false
        V.mod.log:info("Tagged NPC with dex=%d, species=%s", giftDex, tostring(giftSpecies))
      else
        V.mod.log:warn("Could not find NPC entity after spawn")
      end

      V.mod.log:info("Spawned gift %s (dex %d) at %d,%d with id %s on map %s", tostring(giftSpecies), giftDex, x, y, tostring(state.giftNpcId), tostring(mapId))
      return
    end
  end
  V.mod.log:warn("no free cell for the gift on map %s this visit", tostring(mapId))
end

V.mod.events:on("map.entered", function(ev)
  state.giftNpcId = nil
  if ev and (ev.mapId == "PALLET_TOWN" or ev.mapId == "NEW_BARK_TOWN") then spawnGift() end
  -- hard guarantee: there is no indoor flight.  Whatever path leads
  -- into a cave or building while airborne, the flight ends on arrival.
  if flying() then
    local ow = V.mod.world and V.mod.world:overworld()
    if ow and ow.map and ow.map.def then
      local game = require("src.core.Game")
      if not skyAbove(game, ow.map.def) then
        state.phase, state.alt = "idle", 0
        V.mod.log:info("indoors; flight over")
        
        -- Restore the previous Pokemon Player setting
        if state.pokemonPlayerStateSaved then
          local okInstall, PlayerModelInstall = pcall(V.require, "PlayerModelInstall")
          if okInstall and PlayerModelInstall then
            -- Check if the previous state was OFF (empty marker and no dex)
            local wasOff = (state.previousPokemonPlayerMarker == "" or state.previousPokemonPlayerMarker == nil) and 
                          (state.previousPokemonPlayerDex == nil)
            
            if wasOff then
              V.mod.log:info("Previous Pokemon Player was OFF (indoors), clearing to OFF")
              PlayerModelInstall.writeMarker("")
              local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
              if okPlayerModel and PlayerModel then
                PlayerModel.clear()
                V.mod.log:info("Cleared Pokemon Player model to OFF (indoors)")
              end
            else
              if state.previousPokemonPlayerMarker then
                PlayerModelInstall.writeMarker(state.previousPokemonPlayerMarker)
                V.mod.log:info("Restored Pokemon Player marker (indoors): %s", state.previousPokemonPlayerMarker)
              else
                PlayerModelInstall.writeMarker("")
                V.mod.log:info("Cleared Pokemon Player marker (indoors)")
              end
              
              if state.previousPokemonPlayerDex then
                local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
                if okPlayerModel and PlayerModel then
                  PlayerModel.loadStadium(state.previousPokemonPlayerDex)
                  V.mod.log:info("Restored Pokemon Player model to dex %d (indoors)", state.previousPokemonPlayerDex)
                end
              else
                local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
                if okPlayerModel and PlayerModel then
                  PlayerModel.clear()
                  V.mod.log:info("Cleared Pokemon Player model (indoors)")
                end
              end
            end
            
            -- Force sprite refresh
            local Player = require("src.world.Player")
            if ow.player and ow.player.freeFlyWalkSprite then
              ow.player.sprite = ow.player.freeFlyWalkSprite
              V.mod.log:info("Forced sprite refresh after Pokemon Player restoration (indoors)")
            end
          end
          
          state.previousPokemonPlayerDex = nil
          state.previousPokemonPlayerMarker = nil
          state.pokemonPlayerStateSaved = false
        end
        
        emitLanded("indoors", ow.player)
      end
    end
  end
end)

-- a blackout wakes you at the heal point on solid ground, not mid-air;
-- the next tick sees the idle phase and clears the player's flags/rider
-- first person hides the player's card, and the mount is that card; a
-- rider still expects to see their bird, so draw it into the HUD pass:
-- bottom-center, back-facing, flapping, like a cockpit view
local hudQuads = {}
local hudLogged = false
V.mod.hooks:wrap("render.hud", function(next, game, vp)
  local out = next(game, vp)
  if not flying() then return out end
  local ok, err = pcall(function()
    -- resolved once, not per frame
    if state.fpRef == nil then
      state.fpRef = false
      local exports = game.mods and game.mods.exports
      local V_module = exports and exports.DRAMATIC_SHAPE and exports.DRAMATIC_SHAPE.lib
      local okFP, fp = pcall(function() return V_module and V_module.require("FirstPerson") end)
      if okFP and fp then state.fpRef = fp end
    end
    local FP = state.fpRef
    -- hidePlayer() is true exactly when the first-person eye hides the
    -- player's card -- the one situation a rider needs a cockpit view
    -- (third person keeps showing the mount card itself)
    if not (FP and FP.hidePlayer and FP.hidePlayer()) then
      if not hudLogged then
        hudLogged = true
        V.mod.log:info("cockpit idle (%s)",
          not FP and "no DRAMATIC_SHAPE lib"
          or not FP.hidePlayer and "no hidePlayer api" or "card visible")
      end
      return
    end
    if not hudLogged then
      hudLogged = true
      V.mod.log:info("cockpit view active")
    end
    local Player = require("src.world.Player")
    local mount = Player.__freeFlyMount or Player.__freeFlyBird
    local img = mount and mount.image
    if not img then return end
    local SR = require("src.render.SpriteRenderer")
    local t = love.timer.getTime()
    local frame = (math.floor(t * 6) % 2 == 0) and SR.STAND.up or SR.WALK.up
    local key = tostring(img) .. "#" .. frame
    if not hudQuads[key] then
      local iw, ih = img:getDimensions()
      hudQuads[key] = love.graphics.newQuad(0, frame * 16, 16, 16, iw, ih)
    end
    local s = (vp.scale or 4) * 2.2 * (Player.__freeFlyMountScale or 1)
    local x = vp.gameX + vp.gameWidth / 2 - 8 * s
    local y = vp.gameY + vp.gameHeight - 10 * s + math.sin(t * 3) * 3
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, hudQuads[key], x, y, 0, s, s)
  end)
  if not ok and not hudLogged then
    hudLogged = true
    V.mod.log:warn("cockpit overlay failed: %s", tostring(err))
  end
  return out
end)

-- flight never survives into a loaded save (saving is vetoed mid-air),
-- so a save swap always grounds the state machine; a stale "flying"
-- phase could otherwise follow the player into a fresh save
V.mod.events:on("save.loaded", function()
  local wasFlying = flying()
  state.phase, state.alt = "idle", 0
  if wasFlying then 
    -- Restore the previous Pokemon Player setting
    if state.previousPokemonPlayerMarker or state.previousPokemonPlayerDex then
      local okInstall, PlayerModelInstall = pcall(V.require, "PlayerModelInstall")
      if okInstall and PlayerModelInstall then
        if state.previousPokemonPlayerMarker then
          PlayerModelInstall.writeMarker(state.previousPokemonPlayerMarker)
          V.mod.log:info("Restored Pokemon Player marker (save loaded): %s", state.previousPokemonPlayerMarker)
        else
          PlayerModelInstall.writeMarker("")
          V.mod.log:info("Cleared Pokemon Player marker (save loaded)")
        end
        
        if state.pokemonPlayerStateSaved then
          if state.previousPokemonPlayerDex then
            local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
            if okPlayerModel and PlayerModel then
              PlayerModel.loadStadium(state.previousPokemonPlayerDex)
              V.mod.log:info("Restored Pokemon Player model to dex %d (save loaded)", state.previousPokemonPlayerDex)
              
              -- Force sprite refresh
              local ow = V.mod.world and V.mod.world:overworld()
              if ow and ow.player and ow.player.freeFlyWalkSprite then
                ow.player.sprite = ow.player.freeFlyWalkSprite
                V.mod.log:info("Forced sprite refresh after Pokemon Player restoration (save loaded)")
              end
            end
          else
            -- Check if it was OFF (empty marker and no dex)
            local wasOff = (state.previousPokemonPlayerMarker == "" or state.previousPokemonPlayerMarker == nil) and 
                          (state.previousPokemonPlayerDex == nil)
            
            if wasOff then
              V.mod.log:info("Previous Pokemon Player was OFF (save loaded), clearing to OFF")
              local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
              if okPlayerModel and PlayerModel then
                PlayerModel.clear()
                V.mod.log:info("Cleared Pokemon Player model to OFF (save loaded)")
              end
            else
              local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
              if okPlayerModel and PlayerModel then
                PlayerModel.clear()
                V.mod.log:info("Cleared Pokemon Player model (save loaded)")
              end
            end
            
            -- Force sprite refresh
            local ow = V.mod.world and V.mod.world:overworld()
            if ow and ow.player and ow.player.freeFlyWalkSprite then
              ow.player.sprite = ow.player.freeFlyWalkSprite
              V.mod.log:info("Forced sprite refresh after Pokemon Player clear (save loaded)")
            end
          end
          
          state.previousPokemonPlayerDex = nil
          state.previousPokemonPlayerMarker = nil
          state.pokemonPlayerStateSaved = false
        end
      end
      
      state.previousPokemonPlayerDex = nil
      state.previousPokemonPlayerMarker = nil
    end
    emitLanded("save_loaded", nil) 
  end
end)

V.mod.events:on("world.blacked_out", function()
  if flying() then
    state.phase, state.alt = "idle", 0
    V.mod.log:info("blacked out; flight over")
    
    -- Restore the previous Pokemon Player setting
    if state.previousPokemonPlayerMarker or state.previousPokemonPlayerDex then
      local okInstall, PlayerModelInstall = pcall(V.require, "PlayerModelInstall")
      if okInstall and PlayerModelInstall then
        if state.previousPokemonPlayerMarker then
          PlayerModelInstall.writeMarker(state.previousPokemonPlayerMarker)
          V.mod.log:info("Restored Pokemon Player marker (blackout): %s", state.previousPokemonPlayerMarker)
        else
          PlayerModelInstall.writeMarker("")
          V.mod.log:info("Cleared Pokemon Player marker (blackout)")
        end
        
        if state.pokemonPlayerStateSaved then
          if state.previousPokemonPlayerDex then
            local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
            if okPlayerModel and PlayerModel then
              PlayerModel.loadStadium(state.previousPokemonPlayerDex)
              V.mod.log:info("Restored Pokemon Player model to dex %d (blackout)", state.previousPokemonPlayerDex)
              
              -- Force sprite refresh
              local ow = V.mod.world and V.mod.world:overworld()
              if ow and ow.player and ow.player.freeFlyWalkSprite then
                ow.player.sprite = ow.player.freeFlyWalkSprite
                V.mod.log:info("Forced sprite refresh after Pokemon Player restoration (blackout)")
              end
            end
          else
            -- Check if it was OFF (empty marker and no dex)
            local wasOff = (state.previousPokemonPlayerMarker == "" or state.previousPokemonPlayerMarker == nil) and 
                          (state.previousPokemonPlayerDex == nil)
            
            if wasOff then
              V.mod.log:info("Previous Pokemon Player was OFF (blackout), clearing to OFF")
              local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
              if okPlayerModel and PlayerModel then
                PlayerModel.clear()
                V.mod.log:info("Cleared Pokemon Player model to OFF (blackout)")
              end
            else
              local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
              if okPlayerModel and PlayerModel then
                PlayerModel.clear()
                V.mod.log:info("Cleared Pokemon Player model (blackout)")
              end
            end
            
            -- Force sprite refresh
            local ow = V.mod.world and V.mod.world:overworld()
            if ow and ow.player and ow.player.freeFlyWalkSprite then
              ow.player.sprite = ow.player.freeFlyWalkSprite
              V.mod.log:info("Forced sprite refresh after Pokemon Player clear (blackout)")
            end
          end
          
          state.previousPokemonPlayerDex = nil
          state.previousPokemonPlayerMarker = nil
          state.pokemonPlayerStateSaved = false
        end
      end
      
      state.previousPokemonPlayerDex = nil
      state.previousPokemonPlayerMarker = nil
    end
    
    emitLanded("blackout", nil)
  end
end)

-- ------- engine wiring (will be completed in game.ready event)

local function windBack()
  if (state.windCooldown or 0) > 0 then return end
  state.windCooldown = 3
  pcall(function()
    require("src.core.Sound").play(require("src.core.Game").data, "Collision")
  end)
  V.mod.world:queueScript({
    { "show_text", "A fierce wind\nblows you back!" },
  })
end

local function dropRider(ow)
  if not state.rider then return end
  for i = #ow.entities, 1, -1 do
    if ow.entities[i] == state.rider then table.remove(ow.entities, i) end
  end
  state.rider = nil
end

local function syncRider(ow, p)
  local r = state.rider
  if not r or r.player ~= p then
    dropRider(ow)
    r = Rider.new(p)
    state.rider = r
  end
  r.px, r.py = p.px, p.py
  r.cellX, r.cellY = p.cellX, p.cellY
  for _, e in ipairs(ow.entities) do
    if e == r then return end
  end
  -- setMap rebuilds the entity list on every seam crossing, so the
  -- rider re-attaches here each time it goes missing
  table.insert(ow.entities, r)
end

-- does the badge-gate data forbid an airborne crossing into mapId?
-- Reads the same field.badgeGates the walking checkpoints enforce, so
-- any mod that adds its own gates is respected automatically.
local function storyGateBlocks(mapId)
  local Game = require("src.core.Game")
  local field = Game.data.field
  local entry = field and field.badgeGates and field.badgeGates[mapId]
  if not entry then return false end
  local save = Game.save
  local flags = (save and save.flags) or {}
  local bag = (save and save.inventory) or {}
  if flags[entry.passedFlag or ("PASSED_" .. tostring(mapId))] then
    return false
  end
  if entry.badge then return not bag[entry.badge] end
  for _, guard in ipairs(entry.guards or {}) do
    if not (flags[guard.event] or (guard.badge and bag[guard.badge])) then
      return true
    end
  end
  return false
end

local function dangerAllowed(mapId)
  local ok = V.mod.save:get("dangerOk")
  return type(ok) == "table" and ok[mapId] == true
end

-- crossing where only SURF could take a walker: confirm once per map
local function dangerAsk(destMapId)
  if (state.askCooldown or 0) > 0 then return end
  state.askCooldown = 2
  V.mod.world:queueScript({
    { "show_text", "That looks\ndangerous!" },
    { "choice", { "CROSS", "TURN BACK" } },
    { "jump_if_false", "no" },
    { "free_fly:allow_crossing", destMapId },
    { "show_text", "You brace against\nthe sea wind!" },
    { "jump", "end" },
    { "label", "no" },
    { "show_text", "You circle back." },
  })
end

local DIRV = { up = { 0, -1 }, down = { 0, 1 },
               left = { -1, 0 }, right = { 1, 0 } }

local function aheadCell(p)
  local d = DIRV[p.facing] or DIRV.down
  return p.cellX + d[1], p.cellY + d[2]
end

local function surfAllowed(ow)
  if not (fieldMoveUser(ow, "SURF") ~= nil or partyKnowsSurf(require("src.core.Game").save)) then
    return false
  end
  if not badgesSetting:get() then return true end
  local Badges = require("src.inventory.Badges")
  -- Gen1 uses SOULBADGE, Gen2 uses FOGBADGE for SURF
  -- Badges.has checks both inventory (Gen1) and flags (Gen2)
  return Badges.has(require("src.core.Game").save, { id = "SOULBADGE" })
    or Badges.has(require("src.core.Game").save, { id = "FOGBADGE" })
end

-- safe for an auto-glide step to pass over: in bounds, no sealed
-- tower facade, no doormat to hover on
local function glideOk(ow, cx, cy)
  local map = ow.map
  local lm = state.landmark
  if not map:inBounds(cx, cy) then return false end
  if lm and lm.mapId == map.id and lm.cells[cy * lm.w + cx] then
    return false
  end
  if map:warpAtCell(cx, cy) then return false end
  return true
end

local function landableCell(ow, p, cx, cy, allowWater)
  local map = ow.map
  local Collision = require("src.world.Collision")
  if not glideOk(ow, cx, cy)
     or Collision.occupied(ow.entities, cx, cy, p) then
    return nil
  end
  if map:isWalkableCell(cx, cy) then return "ground" end
  if allowWater and map:isWaterCell(cx, cy) then return "water" end
  return nil
end

-- Assisted landing: breadth-first from the rider over flyable cells
-- (anything in bounds that isn't a sealed tower facade) to the
-- nearest cell you could set down on.  Dry land wins over water,
-- doormats and occupied cells are skipped, and south is tried first
-- so hovering over a building tends to land at its entrance.
local APPROACH_RANGE = 12
local APPROACH_DIRS = { { 0, 1 }, { 1, 0 }, { -1, 0 }, { 0, -1 } }

local function findLandingPath(ow, p)
  local map = ow.map
  local lm = state.landmark
  local w = map.widthCells
  local function facade(cx, cy)
    return lm and lm.mapId == map.id and lm.cells[cy * lm.w + cx]
  end
  local allowWater = surfAllowed(ow)
  local function landable(cx, cy)
    return landableCell(ow, p, cx, cy, allowWater)
  end
  local sx, sy = p.cellX, p.cellY
  local startKey = sy * w + sx
  local seen, parent = { [startKey] = true }, {}
  local queue, qi = { { sx, sy, 0 } }, 1
  local function pathTo(key)
    local path = {}
    while key and key ~= startKey do
      table.insert(path, 1, { key % w, math.floor(key / w) })
      key = parent[key]
    end
    return path[1] and path or nil
  end
  local waterKey
  while queue[qi] do
    local cx, cy, depth = queue[qi][1], queue[qi][2], queue[qi][3]
    qi = qi + 1
    if depth > 0 then
      local kind = landable(cx, cy)
      if kind == "ground" then return pathTo(cy * w + cx) end
      if kind == "water" and not waterKey then waterKey = cy * w + cx end
    end
    if depth < APPROACH_RANGE then
      for _, d in ipairs(APPROACH_DIRS) do
        local nx, ny = cx + d[1], cy + d[2]
        local key = ny * w + nx
        if not seen[key] and map:inBounds(nx, ny)
           and not facade(nx, ny) then
          seen[key] = true
          parent[key] = cy * w + cx
          queue[#queue + 1] = { nx, ny, depth + 1 }
        end
      end
    end
  end
  return waterKey and pathTo(waterKey) or nil
end

-- Public API
FreeFly.isFlying = flying
FreeFly.altitude = function() return flying() and state.alt or 0 end
FreeFly.mount = function()
  local mon = flying() and state.mountMon or nil
  if not mon then return nil end
  return { species = mon.species, level = mon.level }
end
FreeFly.registerSpriteSource = Sky.registerSpriteSource
FreeFly.unregisterSpriteSource = Sky.unregisterSpriteSource

-- Export settings for menu access
FreeFly.settings = {
  altitude = altitudeSetting,
  speed = speedSetting,
  encounters = encountersSetting,
  spotted = spottedSetting,
  gates = gatesSetting,
  badges = badgesSetting,
  quickstart = quickstartSetting,
}

-- Make the init function safe to call multiple times
local initialized = false
function FreeFly.init()
  if initialized then
    V.mod.log:info("Free Fly already initialized, skipping")
    return
  end
  initialized = true
  
  -- Set up the game.ready event handler
  V.mod.events:on("game.ready", function()
    local Game = require("src.core.Game")
    local Player = require("src.world.Player")
    local OC = require("src.world.OverworldController")
    local Collision = require("src.world.Collision")
    local MapDef = require("src.world.Map")

    V.mod.log:info("Starting Free Fly game.ready initialization")
    local Pipelines = require("src.render.Pipelines")

    -- per-frame flight state, called from the guarded update wrap below
    local tileShape        -- nil = not tried, false = unavailable
    local ghCache = {}
    -- the shape profile's height for one cell, or nil when the voxel
    -- lib is unreachable
    local function tileHeightAt(map, cx, cy)
      if tileShape == nil then
        tileShape = false
        local exports = Game.mods and Game.mods.exports
        local V_module = exports and exports.DRAMATIC_SHAPE and exports.DRAMATIC_SHAPE.lib
        if V_module and V_module.require then
          local ok, ts = pcall(V_module.require, "TileShape")
          if ok and ts and ts.forMap then tileShape = ts end
        end
      end
      if not tileShape then return nil end
      local ok, got = pcall(function()
        if not map:inBounds(cx, cy) then return 0 end
        local s = tileShape.forMap(map)[map:cellTile(cx, cy)]
        if not s or s.art == "stair" then return 0 end
        return s.h > 0 and s.h or 0
      end)
      return ok and got or 0
    end

    -- the shape profile's art class for one cell, or nil when the voxel
    -- lib is unreachable
    local function tileArtAt(map, cx, cy)
      if tileShape == nil then tileHeightAt(map, cx, cy) end
      if not tileShape then return nil end
      local ok, got = pcall(function()
        if not map:inBounds(cx, cy) then return nil end
        local s = tileShape.forMap(map)[map:cellTile(cx, cy)]
        return s and s.art or "none"
      end)
      return ok and got or nil
    end

    -- returns gh, voxelActive
    local function voxelGroundHeight(ow, p)
      local hasVoxel = Pipelines.get and Pipelines.get("voxel") ~= nil
      if not hasVoxel or Pipelines.level("voxel") <= 0 then return 0, false end
      if ghCache.map == ow.map and ghCache.x == p.cellX
         and ghCache.y == p.cellY then
        return ghCache.h, true
      end
      local h = tileHeightAt(ow.map, p.cellX, p.cellY) or 0
      ghCache.map, ghCache.x, ghCache.y, ghCache.h = ow.map, p.cellX, p.cellY, h
      return h, true
    end

    local function mesherBusy()
      if state.mesherRef == nil then
        state.mesherRef = false
        local exports = Game.mods and Game.mods.exports
        local V_module = exports and exports.DRAMATIC_SHAPE and exports.DRAMATIC_SHAPE.lib
        local ok, cm = pcall(function() return V_module and V_module.require("ChunkMesher") end)
        if ok and cm and cm.pending then state.mesherRef = cm end
      end
      if not state.mesherRef then return false end
      local ok, n = pcall(state.mesherRef.pending)
      return ok and (n or 0) > 0
    end

    -- the whole outdoor world is small (36 maps, under a megabyte of
    -- block data, renderers draw windowed), so a flyer keeps ALL of it
    -- resident: trim() treats the outdoor set as protected, and every
    -- outdoor map is warmed once at one load per tick (~half a second).
    -- Seam crossings then never load anything.  Indoor maps keep the
    -- engine's normal LRU.
    local outdoorSet = {}
    do
      local MapField = require("src.world.FieldDefaults")
      local outside = MapField.field(Game.data, "outsideTilesets")
      for id, def in pairs(Game.data.maps) do
        if MapDef.isOutside(def, outside) then outdoorSet[id] = true end
      end
    end

    local MapLoader = require("src.world.MapLoader")

    if not MapLoader.__freeFlyWrapped then
      MapLoader.__freeFlyWrapped = true
      local origTrim = MapLoader.trim
      MapLoader.trim = function(protected)
        local policy = MapLoader.__freeFlyTrimPolicy
        if policy then return policy(protected, origTrim) end
        return origTrim(protected)
      end
    end
    -- indoor maps keep their FULL vanilla cache budget: the resident
    -- outdoor world never counts against the engine's cap, and eviction
    -- only happens when indoor maps alone would have exceeded it anyway
    MapLoader.__freeFlyTrimPolicy = function(protected, origTrim)
      local indoor = 0
      for id in pairs(Game.data.maps) do
        if not outdoorSet[id] and MapLoader.cached(id) then
          indoor = indoor + 1
        end
      end
      if indoor <= 32 then return end
      protected = protected or {}
      for id in pairs(outdoorSet) do protected[id] = true end
      return origTrim(protected)
    end

    state.prefetchQueue = {}
    for id in pairs(outdoorSet) do
      if not MapLoader.cached(id) then
        state.prefetchQueue[#state.prefetchQueue + 1] = id
      end
    end

    local function tickPrefetch()
      if #state.prefetchQueue == 0 then return end
      -- throttled, and it always yields the frame to the voxel mesher:
      -- its arrival builds matter more than our cache warm
      state.prefetchTick = ((state.prefetchTick or 0) + 1) % 6
      if state.prefetchTick ~= 0 or mesherBusy() then return end
      local id = table.remove(state.prefetchQueue)
      if not id then return end
      local okLoad = pcall(MapLoader.load, Game.data, id)
      if not okLoad then state.prefetchQueue = {} end
    end

    -- "tall" is derived from the game's own data, never an authored
    -- list: an exterior door whose interior spans three or more floor
    -- maps (the dept store, Silph Co, the tower, the mansion) marks its
    -- building's solid footprint as a no-fly wall.  Anything smaller
    -- stays fly-over, and modded towers qualify automatically.
    local function floorFamilySize(destId)
      if type(destId) ~= "string" then return 0 end
      local base = destId:gsub("_B?%d+F$", ""):gsub("_ROOF$", "")
      if base == destId then return 1 end
      -- caves are terrain, not towers: Seafoam or Victory Road go deep
      -- and stay flyable no matter how many maps they span
      local destDef = Game.data.maps[destId]
      if destDef and destDef.tileset == "CAVERN" then return 1 end
      -- only floors ABOVE ground make a building tall; basements don't
      local n = 0
      for id in pairs(Game.data.maps) do
        if (id == base or id:find("^" .. base .. "_"))
           and not id:find("_B%d+F$") then
          n = n + 1
        end
      end
      return n
    end

    local function landmarkCellsFor(ow)
      local map = ow.map
      local w = map.widthCells or ((map.def and map.def.width or 0) * 2)
      local cells = {}
      -- four or more floors above ground is a tower (dept store, Silph,
      -- Pokemon Tower, Celadon Mansion).  Three is a big house whose
      -- small drawn exterior stays fly-over: Cinnabar's mansion.
      for _, warp in ipairs((map.def and map.def.warps) or {}) do
        if floorFamilySize(warp.destMap) >= 4 then
          -- flood the solid footprint starting above the door, bounded
          -- so it can never wander off into the border-tree ring
          -- the footprint floods through BUILDING cells only.  In the
          -- shape profile, building walls are "upright"; trees are
          -- "cylinder", fences "post", signs "billboard" (measured over
          -- Saffron), so those never chain the wall into a neighbour.
          local function buildingCell(cx, cy)
            if not map:inBounds(cx, cy) or map:isWalkableCell(cx, cy) then
              return false
            end
            local art = tileArtAt(map, cx, cy)
            return art == nil or art == "upright"
          end
          local queue = { { warp.x, warp.y - 1 } }
          local seen, budget = {}, 400
          while #queue > 0 and budget > 0 do
            local cell = table.remove(queue)
            local cx, cy = cell[1], cell[2]
            local key = cy * w + cx
            local dx, dy = cx - warp.x, cy - warp.y
            -- generous bounds: the fence exclusion is what stops spill
            -- into neighbours, so the box only needs to contain the
            -- biggest tower (Silph) in every direction from its door
            if not seen[key]
               and math.abs(dx) <= 12 and dy >= -12 and dy <= 1
               and buildingCell(cx, cy) then
              seen[key] = true
              cells[key] = true
              budget = budget - 1
              queue[#queue + 1] = { cx + 1, cy }
              queue[#queue + 1] = { cx - 1, cy }
              queue[#queue + 1] = { cx, cy + 1 }
              queue[#queue + 1] = { cx, cy - 1 }
            end
          end

          -- seal enclosed walkable pockets (the dept store's rooftop
          -- plaza): walkable cells inside the footprint's box that can't
          -- be walked into from the box border are part of the building
          -- while airborne.  Streets crossing near the complex reach the
          -- border and are never touched.
          local minx, maxx = warp.x - 12, warp.x + 12
          local miny, maxy = warp.y - 12, warp.y + 1
          local open, oq = {}, {}
          local function seed(cx, cy)
            local key = cy * w + cx
            if not open[key] and map:inBounds(cx, cy)
               and map:isWalkableCell(cx, cy) then
              open[key] = true
              oq[#oq + 1] = { cx, cy }
            end
          end
          for cx = minx, maxx do seed(cx, miny); seed(cx, maxy) end
          for cy = miny, maxy do seed(minx, cy); seed(maxx, cy) end
          while #oq > 0 do
            local c = table.remove(oq)
            local cx, cy = c[1], c[2]
            for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1} }) do
              local nx, ny = cx + d[1], cy + d[2]
              if nx >= minx and nx <= maxx and ny >= miny and ny <= maxy then
                seed(nx, ny)
              end
            end
          end
          for cy = miny, maxy do
            for cx = minx, maxx do
              local key = cy * w + cx
              if map:inBounds(cx, cy) and map:isWalkableCell(cx, cy)
                 and not open[key] then
                cells[key] = true
              end
            end
          end
        end
      end
      return { mapId = map.id, w = w, cells = cells }
    end

    -- Core flight tick function
    OC.__freeFlyTick = function(ow, dt)
      local p = ow.player
      if not p then return end
      if ow.map and (not state.landmark
                     or state.landmark.mapId ~= ow.map.id) then
        local ok, lm = pcall(landmarkCellsFor, ow)
        state.landmark = ok and lm or { mapId = ow.map.id, w = 1, cells = {} }
      end
      if not flying() then
        if p.freeFlyAlt then p.freeFlyAlt, p.freeFlying = nil, nil end
        if p.freeFlyWalkSprite then
          p.sprite, p.freeFlyWalkSprite = p.freeFlyWalkSprite, nil
        end
        if state.placedCam and state.v3dRef
           and state.v3dRef.camera == state.placedCam then
          state.v3dRef.camera = nil
        end
        dropRider(ow)
        return
      end
      p.freeFlying = true
      -- the mount IS the player's sheet while airborne, so every renderer
      -- (voxel first/third person frame remaps included) shows it; the
      -- walking sheet is stashed for the rider overlay and the landing
      local mount = Player.__freeFlyMount or Player.__freeFlyBird
      if mount and p.sprite ~= mount then
        p.freeFlyWalkSprite = p.freeFlyWalkSprite or p.sprite
        p.sprite = mount
      end
      syncRider(ow, p)
      -- wings work harder in transitions than on the cruise, same as
      -- the wild flyers' flap profiles; big mounts beat slower
      p.freeFlyFlapRate = (state.phase == "flying" and 8 or 12)
        / math.max(1, Player.__freeFlyMountScale or 1)
      dt = dt or 1 / 60
      local groundOk = ow.map:isWalkableCell(p.cellX, p.cellY)
      -- SURF availability goes through the same engine chain, so
      -- HM-relaxing mods unlock water landings exactly as they unlock
      -- the SURF field move itself
      local waterOk = not groundOk and ow.map:isWaterCell(p.cellX, p.cellY)
        and surfAllowed(ow)
      local canLand = not p.moving and (groundOk or waterOk)
        and not Collision.occupied(ow.entities, p.cellX, p.cellY, p)
      p.freeFlyCanLand = state.phase == "flying" and canLand or false

      if state.phase == "rising" then
        local cruise = cruiseAlt()
        state.alt = math.min(cruise, state.alt + RISE_SPEED * dt)
        -- diagonal climb, like the wild flyers: a short forward drift,
        -- dropped the moment the player steers or anything's in the way
        local steering = Game.input:isDown("up") or Game.input:isDown("down")
          or Game.input:isDown("left") or Game.input:isDown("right")
        if steering then state.riseGlide = 0 end
        if (state.riseGlide or 0) > 0 and not p.moving then
          local cx, cy = aheadCell(p)
          if glideOk(ow, cx, cy) then
            local result = p:tryMove(p.facing, ow.map, ow.entities)
            if result == "moved" then
              state.riseGlide = state.riseGlide - 1
            elseif result == "blocked" then
              state.riseGlide = 0
            end
          else
            state.riseGlide = 0
          end
        end
        if state.alt >= cruise then state.phase = "flying" end
      elseif state.phase == "landing" then
        -- the last pixel waits for the step to finish, so a swoop skims
        -- the ground on its final cell instead of dismounting mid-step
        state.alt = math.max(p.moving and 1 or 0,
                             state.alt - RISE_SPEED * dt)
        -- swoop: a land press on the wing keeps the heading for a
        -- couple of cells on the way down, like the wild flyers' glide
        -- in to a perch
        if (state.glide or 0) > 0 and state.alt > 20 and not p.moving then
          local cx, cy = aheadCell(p)
          if landableCell(ow, p, cx, cy, surfAllowed(ow)) then
            local result = p:tryMove(p.facing, ow.map, ow.entities)
            if result == "moved" then
              state.glide = state.glide - 1
            elseif result == "blocked" then
              state.glide = 0
            end
          else
            state.glide = 0
          end
        end
        if state.alt <= 0 and not p.moving then
          local landableHere = (ow.map:isWalkableCell(p.cellX, p.cellY)
                                or ow.map:isWaterCell(p.cellX, p.cellY))
            and not Collision.occupied(ow.entities, p.cellX, p.cellY, p)
          if not landableHere then
            -- the ground can change under a swoop (an NPC wanders in);
            -- pull up and hand back rather than landing on them
            state.phase = "flying"
          else
            state.phase = "idle"
            -- setting down on water hands you straight to a SURF-knower
            if ow.map:isWaterCell(p.cellX, p.cellY) then
              p.surfing = true
              V.mod.log:info("landed on the water; surfing")
            else
              V.mod.log:info("landed")
            end
            p.freeFlying, p.freeFlyAlt, p.freeFlyCanLand = nil, nil, nil
            if p.freeFlyWalkSprite then
              p.sprite, p.freeFlyWalkSprite = p.freeFlyWalkSprite, nil
            end
            
            -- Restore the previous Pokemon Player setting
            V.mod.log:info("LANDING: Checking Pokemon Player restoration state")
            V.mod.log:info("LANDING: pokemonPlayerStateSaved=%s, previousPokemonPlayerMarker=%s, previousPokemonPlayerDex=%s", 
                           tostring(state.pokemonPlayerStateSaved),
                           tostring(state.previousPokemonPlayerMarker), 
                           tostring(state.previousPokemonPlayerDex))
            
            if state.pokemonPlayerStateSaved then
              V.mod.log:info("LANDING: Attempting to restore Pokemon Player: marker=%s, dex=%s", 
                             tostring(state.previousPokemonPlayerMarker), 
                             tostring(state.previousPokemonPlayerDex))
              local okInstall, PlayerModelInstall = pcall(V.require, "PlayerModelInstall")
              V.mod.log:info("LANDING: PlayerModelInstall available: %s", tostring(okInstall))
              if okInstall and PlayerModelInstall then
                -- Check if the previous state was OFF (empty marker and no dex)
                local wasOff = (state.previousPokemonPlayerMarker == "" or state.previousPokemonPlayerMarker == nil) and 
                              (state.previousPokemonPlayerDex == nil)
                V.mod.log:info("LANDING: wasOff=%s (marker=%s, dex=%s)", 
                               tostring(wasOff),
                               tostring(state.previousPokemonPlayerMarker),
                               tostring(state.previousPokemonPlayerDex))
                
                if wasOff then
                  V.mod.log:info("LANDING: Previous Pokemon Player was OFF, clearing to OFF")
                  PlayerModelInstall.writeMarker("")
                  local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
                  if okPlayerModel and PlayerModel then
                    PlayerModel.clear()
                    V.mod.log:info("LANDING: Cleared Pokemon Player model to OFF")
                  end
                else
                  -- Restore the previous marker
                  if state.previousPokemonPlayerMarker then
                    PlayerModelInstall.writeMarker(state.previousPokemonPlayerMarker)
                    V.mod.log:info("LANDING: Restored Pokemon Player marker: %s", state.previousPokemonPlayerMarker)
                  else
                    PlayerModelInstall.writeMarker("")
                    V.mod.log:info("LANDING: Cleared Pokemon Player marker (was nil)")
                  end
                  
                  -- Reload the previous model if it had a dex number
                  if state.previousPokemonPlayerDex then
                    local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
                    V.mod.log:info("LANDING: PlayerModel available: %s", tostring(okPlayerModel))
                    if okPlayerModel and PlayerModel then
                      PlayerModel.loadStadium(state.previousPokemonPlayerDex)
                      V.mod.log:info("LANDING: Restored Pokemon Player model to dex %d", state.previousPokemonPlayerDex)
                    end
                  else
                    local okPlayerModel, PlayerModel = pcall(V.require, "PlayerModel")
                    if okPlayerModel and PlayerModel then
                      PlayerModel.clear()
                      V.mod.log:info("LANDING: Cleared Pokemon Player model (was nil)")
                    end
                  end
                end
                
                -- Force sprite refresh
                local Player = require("src.world.Player")
                if p.freeFlyWalkSprite then
                  p.sprite = p.freeFlyWalkSprite
                  V.mod.log:info("LANDING: Forced sprite refresh after Pokemon Player restoration")
                else
                  V.mod.log:warn("LANDING: No freeFlyWalkSprite available for refresh")
                end
              else
                V.mod.log:warn("LANDING: PlayerModelInstall module not available for restoration")
              end
              
              -- Clear the saved state
              state.previousPokemonPlayerDex = nil
              state.previousPokemonPlayerMarker = nil
              state.pokemonPlayerStateSaved = false
              V.mod.log:info("LANDING: Cleared saved Pokemon Player state")
            else
              V.mod.log:info("LANDING: No previous Pokemon Player state to restore")
            end
            
            emitLanded("landed", p)
            return
          end
        end
      elseif state.phase == "flying" then
        -- an ALTITUDE option change applies mid-flight
        state.alt = state.alt + (cruiseAlt() - state.alt) * math.min(1, dt * 2)

        if Game.input:wasPressed("b") or state.landRequest then
          state.landRequest = nil
          if canLand then
            state.phase, state.glide = "landing", 0
          elseif p.moving and p.targetX
                 and landableCell(ow, p, p.targetX, p.targetY,
                                  surfAllowed(ow)) then
            -- pressed on the wing over good ground: swoop in along the
            -- current heading instead of stopping dead
            state.phase, state.glide = "landing", 2
          else
            -- assisted landing: glide to the nearest landable cell (in
            -- front of the building you're hovering over) and set down
            local path = findLandingPath(ow, p)
            if path then
              state.phase = "approach"
              state.approachPath = path
              V.mod.log:info("gliding to a landing spot")
            else
              pcall(function()
                require("src.core.Sound").play(Game.data, "Collision")
              end)
              V.mod.log:info("nowhere to land nearby")
            end
          end
        end

        -- aerial interception: brushing a wild_skies flyer starts that
        -- exact battle, through its exports rather than its internals
        if (state.interceptCooldown or 0) > 0 then
          state.interceptCooldown = state.interceptCooldown - dt
        elseif encountersSetting:get() then
          if state.skiesTake == nil then
            local skies = V.mod.find("wild_skies")
            state.skiesTake = (skies and skies.exports
                               and skies.exports.takeFlyer) or false
          end
          local take = state.skiesTake
          if take then
            local ok, hit = pcall(take, p.cellX, p.cellY, 1)
            if ok and hit and hit.species then
              state.interceptCooldown = 2
              state.expectBattle = 4
              pcall(function()
                require("src.core.Sound").playCry(Game.data, hit.species)
              end)
              V.mod.log:info("intercepted %s!", tostring(hit.species))
              V.mod.world:queueScript({
                { "start_battle", "wild", hit.species, hit.level or 5 },
              })
            end
          end
        end
      elseif state.phase == "approach" then
        state.alt = state.alt + (cruiseAlt() - state.alt) * math.min(1, dt * 2)
        -- the glide is autopilot, so ANY steering or another land press
        -- hands control straight back
        local steering = Game.input:isDown("up") or Game.input:isDown("down")
          or Game.input:isDown("left") or Game.input:isDown("right")
        local cancel = steering or Game.input:wasPressed("b")
          or state.landRequest
        state.landRequest = nil
        if cancel or not state.approachPath then
          state.phase, state.approachPath = "flying", nil
        elseif not p.moving then
          local nextCell = state.approachPath[1]
          if not nextCell then
            state.approachPath = nil
            -- recheck on arrival: an NPC may have wandered onto the spot
            state.phase = canLand and "landing" or "flying"
            state.glide = 0
          else
            local dir
            if nextCell[1] > p.cellX then dir = "right"
            elseif nextCell[1] < p.cellX then dir = "left"
            elseif nextCell[2] > p.cellY then dir = "down"
            elseif nextCell[2] < p.cellY then dir = "up" end
            if not dir then
              table.remove(state.approachPath, 1)
            else
              local result = p:tryMove(dir, ow.map, ow.entities)
              if result == "moved" then
                table.remove(state.approachPath, 1)
              elseif result == "blocked" then
                state.phase, state.approachPath = "flying", nil
              end
            end
          end
        end
      end
      tickPrefetch()
      state.expectBattle = (state.expectBattle and state.expectBattle > dt)
        and (state.expectBattle - dt) or nil
      state.windCooldown = math.max(0, (state.windCooldown or 0) - dt)
      -- TURN BACK is never remembered: once this expires the next push
      -- into the seam asks again, until the player says CROSS
      state.askCooldown = math.max(0, (state.askCooldown or 0) - dt)
      state.bob = (state.bob + dt * 4) % (2 * math.pi)
      local hover = state.phase == "flying" and math.sin(state.bob) * 2 or 0
      -- altitude is absolute: the voxel scene adds the ground height back
      -- under the card, so standing geometry eats into the visual lift
      -- instead of stacking on top of it (min 10 keeps clearance)
      local lift = state.alt + hover
      local gh, voxelOn = voxelGroundHeight(ow, p)
      local camLift
      if voxelOn then
        -- constant 52px TOTAL ride: the scene's building volumes cap at
        -- 48px from the ground plane (their mesher's MAX_ROWS), so this
        -- clears every small building everywhere with no climbs at all.
        -- The per-cell gh subtraction stays INSTANT, which is what keeps
        -- fences from reading as hops.  Towers are facade-blocked.
        local total = math.max(lift * 0.75, 52)
        -- takeoff and landing ramp the constant ride in and out, so the
        -- voxel mount climbs and descends like the wild flyers instead
        -- of popping to cruise height (mid-flight ALTITUDE lerps are
        -- exempt or they'd read as a dive)
        if state.phase == "rising" or state.phase == "landing" then
          total = total * math.min(1, state.alt / math.max(1, cruiseAlt()))
        end
        p.freeFlyAlt = math.max(0, total - gh)
        -- the camera follows the constant TOTAL, never the varying
        -- per-cell part: roofs mix zero-height flat-class cells into
        -- their upper rows, and a camera tracking freeFlyAlt lurched
        -- there while the card itself stayed level.  The follow factor
        -- scales with the rung's PITCH, read live from the voxel mod's
        -- own angle table (the ladder is OFF/FULL/15/35/50/75/1ST/3RD).
        -- The engine camera is a GROUND-PLANE point, so it can express
        -- forward but never height; the 75-degree orbit gets its height
        -- through the scene's placed-camera seam below instead.
        local FOLLOW_BY_DEG = { [15] = 0.65, [35] = 0.65,
                                [50] = 0.78, [75] = 0.65 }
        local rung = Pipelines.level("voxel") or 0
        if state.voxelStateRef == nil then
          state.voxelStateRef = false
          local exports = Game.mods and Game.mods.exports
          local V_module = exports and exports.DRAMATIC_SHAPE
            and exports.DRAMATIC_SHAPE.lib
          local okV, vs = pcall(function()
            return V_module and V_module.require("VoxelState")
          end)
          if okV and vs and vs.ANGLES_DEG then state.voxelStateRef = vs end
        end
        local deg = state.voxelStateRef
          and state.voxelStateRef.ANGLES_DEG[rung + 1] or 0
        camLift = total * (FOLLOW_BY_DEG[deg] or 0.65)
        state.placeWanted = deg == 75
          and not (state.voxelStateRef.isFirstPerson
                   and state.voxelStateRef.isFirstPerson(rung))
          and not (state.voxelStateRef.isThirdPerson
                   and state.voxelStateRef.isThirdPerson(rung))
        state.placeHeight = (p.freeFlyAlt or 0) + gh
      else
        -- 2D flies steady: a 2px integer-quantized hover reads as
        -- jitter, and the wing flap already carries the life
        p.freeFlyAlt = state.alt
        camLift = state.alt
      end
      local camLift = p.freeFlyAlt
      -- Calculate camera position: same fixed, UNROTATED offset vanilla
      -- Camera:follow uses (viewW/2-16, viewH/2-8). The Renderer already
      -- rotates the whole screen around the screen-centre pivot to draw
      -- the compass turn (see Renderer:drawTiltedWorld's
      -- love.graphics.rotate around viewCenterX/Y), the same pivot this
      -- unrotated offset keeps the player pinned to. Pre-rotating this
      -- offset by yaw (as before) double-transformed: it moved the
      -- camera off that pivot, so the player drifted away from screen
      -- centre the moment the compass left FRONT, and the drift only got
      -- worse the more it turned. camLift is a screen-space altitude
      -- nudge, not a world offset, so it must stay unrotated too.
      local viewW, viewH = Game.renderer:worldViewSize()
      ow.camera.x = p.px - (viewW / 2 - 16)
      ow.camera.y = (p.py - camLift) - (viewH / 2 - 8)
      ow.camera:follow(p.px, p.py - camLift,
                       Game.renderer:worldViewSize())
      -- the 75-degree orbit, lifted to the rider through the scene's
      -- placed-camera seam (the battle-camera mechanism): same centre,
      -- same pitch, same fov, focus raised to flight height.  Never
      -- touches a camera someone else placed (battles, first person).
      local vsRef = state.voxelStateRef
      if state.v3dRef == nil then
        state.v3dRef = false
        local exports = Game.mods and Game.mods.exports
        local V_module = exports and exports.DRAMATIC_SHAPE
          and exports.DRAMATIC_SHAPE.lib
        local okV3, v3 = pcall(function()
          return V_module and V_module.require("Voxel3D")
        end)
        if okV3 and v3 then state.v3dRef = v3 end
      end
      local V3 = state.v3dRef
      if state.placeWanted and vsRef and V3
         and (V3.camera == nil or V3.camera == state.placedCam) then
        local ok = pcall(function()
          local vw, vh = Game.renderer:worldViewSize()
          local ccx = ow.camera.x + vw / 2
          local ccy = ow.camera.y + vh / 2
          local a = vsRef.angle or math.rad(75)
          local focal = vsRef.FOCAL or 1.2
          local distC = focal * vh
          local L = state.placeHeight or 0
          local cam = state.placedCam or {}
          cam.fov = 2 * math.atan(1 / (2 * focal))
          cam.focus = { ccx, L, ccy }
          -- Incorporate camera yaw rotation into eye position: the old
          -- code only ever read camYaw into cam.yaw (for sprite billboard
          -- rotation) and never rotated the eye or up vectors with it, so
          -- turning moved the compass reading but the 75-degree orbit's
          -- eye stayed nailed to the same world point -- no visible turn.
          -- Decompose the pitched offset into a height part (unchanged)
          -- and a ground-plane part (horizDist), then spin that ground
          -- part around the focus by -camYaw: this engine documents
          -- (FirstPerson.lua) that increasing yaw is a LEFT turn, and
          -- every place that turns camYaw into real coordinates negates
          -- it first (Renderer's -cameraRotation, every FirstPerson look
          -- input); using the raw, un-negated angle here spins the
          -- camera backwards, which is what made the first pass of this
          -- fix turn the wrong way.
          local camYaw = ow.camera:angle() or 0
          local horizDist = distC * math.sin(a)
          local eyeOffX = horizDist * math.sin(camYaw)
          local eyeOffZ = horizDist * math.cos(camYaw)
          cam.eye = { ccx + eyeOffX, L + distC * math.cos(a), ccy + eyeOffZ }
          cam.up = { -math.cos(a) * math.sin(camYaw), math.sin(a),
                     -math.cos(a) * math.cos(camYaw) }
          -- Store the camera yaw for proper sprite rotation
          cam.yaw = camYaw
          state.placedCam = cam
          V3.camera = cam
        end)
        if not ok then state.placeWanted = false end
      elseif not state.placeWanted and V3 and state.placedCam
             and V3.camera == state.placedCam then
        V3.camera = nil
      end
    end

    if not OC.__freeFlyWrapped then
      OC.__freeFlyWrapped = true

      local origUpdate = OC.update
      OC.update = function(self, dt)
        origUpdate(self, dt)
        if OC.__freeFlyTick then
          local ok, err = pcall(OC.__freeFlyTick, self, dt)
          if not ok then print("[free_fly] tick failed: " .. tostring(err)) end
        end
      end

      -- doors and edge warps must not swallow a bird passing over them
      local origTakeWarp = OC.takeWarp
      OC.takeWarp = function(self, ...)
        if self.player and self.player.freeFlying then return end
        return origTakeWarp(self, ...)
      end

      -- trainers don't spot what flies over their head (unless the
      -- hardcore option says they do); the gate is swappable so hot
      -- reload always runs the latest logic
      local origSight = OC.checkTrainerSight
      OC.checkTrainerSight = function(self, ...)
        local gate = OC.__freeFlySightGate
        if gate and gate(self) then return end
        return origSight(self, ...)
      end
    end

    OC.__freeFlySightGate = function(ow)
      local p = ow.player
      return p and p.freeFlying and not spottedSetting:get()
    end

    -- crossing where only SURF could take a walker: confirm once per map
    local function dangerAsk(destMapId)
      if (state.askCooldown or 0) > 0 then return end
      state.askCooldown = 2
      V.mod.world:queueScript({
        { "show_text", "That looks\ndangerous!" },
        { "choice", { "CROSS", "TURN BACK" } },
        { "jump_if_false", "no" },
        { "free_fly:allow_crossing", destMapId },
        { "show_text", "You brace against\nthe sea wind!" },
        { "jump", "end" },
        { "label", "no" },
        { "show_text", "You circle back." },
      })
    end

    -- story gates and the sea-crossing confirm share the seam chokepoint.
    -- v2 guard flag: the 0.7.0 wrapper did not pass `dir`, so a hot reload
    -- from it installs this one and retires the old gate key.
    if not OC.__freeFlyCrossWrapped3 then
      OC.__freeFlyCrossWrapped3 = true
      local origCross = OC.crossConnection
      OC.crossConnection = function(self, dir, conn)
        local gate = OC.__freeFlyCrossGate2
        if gate and conn and gate(self, dir, conn.map) then return false end
        local crossed = origCross(self, dir, conn)
        local after = OC.__freeFlyCrossAfter
        if crossed and after then after(self) end
        return crossed
      end
    end
    OC.__freeFlyCrossGate = nil

    -- the seam step crossConnection kicks off bypasses tryMove, so it
    -- would run at walking pace mid-flight (a visible hitch at every
    -- seam); the rider ghost also needs re-attaching the same frame the
    -- entity list is rebuilt, not a tick later
    OC.__freeFlyCrossAfter = function(ow)
      local p = ow.player
      if not (p and p.freeFlying) then return end
      p.stepFramesCur = flyFrames()
      if state.rider then
        state.rider.px, state.rider.py = p.px, p.py
        state.rider.cellX, state.rider.cellY = p.cellX, p.cellY
        table.insert(ow.entities, state.rider)
      end
    end

    -- forced-movement tiles (Cycling Road's mount-or-refuse, forced surf
    -- currents) don't grab what flies over them; landing brings the
    -- vanilla check straight back.  Own guard flag so a hot reload from
    -- an older version still installs it.
    if not OC.__freeFlyForcedWrapped then
      OC.__freeFlyForcedWrapped = true
      local origForced = OC.checkForcedMovement
      OC.checkForcedMovement = function(self, ...)
        if self.player and self.player.freeFlying then return false end
        return origForced(self, ...)
      end
    end

    -- other mods (overworld_encounters' ground roamers above all) start
    -- wild battles by ground-cell collision and know nothing about
    -- altitude.  While airborne, the only wild battle allowed to start is
    -- one this mod just asked for (interception); everything else is a
    -- ground creature the flyer passes over.
    local BattleState = require("src.battle.BattleState")
    if not BattleState.__freeFlyWrapped then
      BattleState.__freeFlyWrapped = true
      local origNewWild = BattleState.newWild
      BattleState.newWild = function(...)
        local gate = BattleState.__freeFlyGate
        if gate and gate() then return nil end
        return origNewWild(...)
      end
    end
    BattleState.__freeFlyGate = function()
      return flying() and not state.expectBattle
    end

    V.mod.events:on("battle.started", function()
      state.expectBattle = nil
    end)

    -- neutralize stale border wraps from a hot reload of the previous
    -- build; the border draws normally everywhere again
    local TileRenderer = require("src.render.TileRenderer")
    TileRenderer.__freeFlySkip = nil
    pcall(function()
      local exports = Game.mods and Game.mods.exports
      local V_module = exports and exports.DRAMATIC_SHAPE and exports.DRAMATIC_SHAPE.lib
      local CM = V_module and V_module.require("ChunkMesher")
      if CM then CM.__freeFlyBodyOnly = nil end
    end)

    -- a flyer crossing a ledge just crosses it: the vanilla hop would
    -- hijack the step and stack its arc on top of the flight lift
    if not OC.__freeFlyLedgeWrapped then
      OC.__freeFlyLedgeWrapped = true
      local origLedge = OC.checkLedgeHop
      OC.checkLedgeHop = function(self, ...)
        if self.player and self.player.freeFlying then return false end
        return origLedge(self, ...)
      end
    end

    -- completed-step reactions (locked-door step scripts, gate guards,
    -- spinner tiles, poison ticks) belong to walkers; an airborne step
    -- touches nothing, and landing brings them all straight back
    if not OC.__freeFlyStepWrapped then
      OC.__freeFlyStepWrapped = true
      local origStep = OC.onStepComplete
      OC.onStepComplete = function(self, ...)
        if self.player and self.player.freeFlying then
          -- the Safari Game's step economy still ticks mid-air (the
          -- FOREST-tileset rule makes its zones flyable, and flight must
          -- not grant unlimited safari time); no-op outside the safari
          pcall(function() self:safariStep() end)
          return
        end
        return origStep(self, ...)
      end
    end

    OC.__freeFlyCrossGate2 = function(ow, dir, destMapId)
      if not flying() then return false end
      if gatesSetting:get() and storyGateBlocks(destMapId) then
        windBack()
        return true
      end
      if not dangerAllowed(destMapId) then
        local dest, ts, x, y = ow:connectionLanding(dir)
        if dest and MapDef.defIsWaterCell(dest, ts, x, y) then
          dangerAsk(destMapId)
          return true
        end
      end
      return false
    end

    -- thin wraps install once; the implementations live on the Player
    -- table and are reassigned on every load, so F5 hot reload always
    -- runs the latest logic
    if not Player.__freeFlyWrapped then
      Player.__freeFlyWrapped = true

      local origPose = Player.pose
      Player.pose = function(self)
        local impl = Player.__freeFlyPoseImpl
        if impl then return impl(self, origPose) end
        return origPose(self)
      end

      local origDraw = Player.draw
      Player.draw = function(self, camX, camY)
        local impl = Player.__freeFlyDrawImpl
        if impl then return impl(self, camX, camY, origDraw) end
        return origDraw(self, camX, camY)
      end
    end

    -- lift rides pose so every renderer (flat, tilt, pipelines) sees it;
    -- airborne the card itself becomes the flapping bird, and the Rider
    -- ghost entity above carries the player figure
    Player.__freeFlyPoseImpl = function(self, origPose)
      local sprite, px, py, facing, phase, flip, hopping = origPose(self)
      local lift = self.freeFlyAlt
      if lift and lift > 0 then
        py = py - math.floor(lift + 0.5)
        local mount = Player.__freeFlyMount or Player.__freeFlyBird
        if mount then
          sprite = mount
          phase = math.floor(love.timer.getTime()
                             * (self.freeFlyFlapRate or 8)) % 2
          flip = false
        end
      end
      return sprite, px, py, facing, phase, flip, hopping
    end

    -- airborne the player rides: the bird sheet as the mount, the
    -- player's own top half seated on its back.  Both images come out
    -- of the player's imported cache, so nothing ships.
    Player.__freeFlyDrawImpl = function(self, camX, camY, origDraw)
      local lift = self.freeFlyAlt
      local bird = Player.__freeFlyMount or Player.__freeFlyBird
      if not (lift and lift > 0 and bird) then
        return origDraw(self, camX, camY)
      end
      -- the shadow shrinks with height and turns green over landable
      -- ground, so B-to-land reads at a glance
      if self.freeFlyCanLand then
        love.graphics.setColor(0.1, 0.45, 0.15, 0.45)
      else
        love.graphics.setColor(0, 0, 0, 0.35)
      end
      local s = Player.__freeFlyMountScale or 1
      local r = math.max(3, 7 - lift / 16) * s
      love.graphics.ellipse("fill", self.px + 8 - camX, self.py + 13 - camY,
                            r, r * 0.4)
      love.graphics.setColor(1, 1, 1, 1)
      local ry = self.py - math.floor(lift + 0.5)
      local flap = math.floor(love.timer.getTime()
                              * (self.freeFlyFlapRate or 8)) % 2
      -- rider FIRST, tucked low, then the mount over it: the mount's body
      -- hides the crop line, so the figure reads as seated behind its
      -- neck instead of a head floating above it
      local walk = self.freeFlyWalkSprite or self.sprite
      walk:draw(self.px, ry - math.floor(1 + 2 * s + 0.5),
                camX, camY, self.facing, 0, false, true)
      if s ~= 1 then
        local fx = math.floor(self.px + 8 - camX)
        local fy = math.floor(ry + 12 - camY)
        love.graphics.push()
        love.graphics.translate(fx, fy)
        love.graphics.scale(s, s)
        love.graphics.translate(-fx, -fy)
      end
      bird:draw(self.px, ry, camX, camY, self.facing, flap, false)
      if s ~= 1 then love.graphics.pop() end
    end

    local SpriteRenderer = require("src.render.SpriteRenderer")
    if Game.data.sprites.SPRITE_BIRD then
      Player.__freeFlyBird = SpriteRenderer.new(Game.data.sprites.SPRITE_BIRD,
                                                "free_fly_mount")
    end

    -- mount identity: use the follower sprite service to get species-specific sprites
    -- This matches how roamers and wild life display their actual species sprites
    state.resolveMount = function(mon)
      state.mountMon = mon
      local species = mon and mon.species
      local SpriteRenderer = require("src.render.SpriteRenderer")
      
      -- Ensure SPRITE_BIRD is loaded as fallback
      if not Player.__freeFlyBird then
        if Game.data.sprites.SPRITE_BIRD then
          Player.__freeFlyBird = SpriteRenderer.new(Game.data.sprites.SPRITE_BIRD, "free_fly_mount")
        end
      end

      -- Try to use the Pokémon's actual sprite using the follower sprite service
      local monSprite = nil
      if species then
        -- Try to use the follower sprite service (same as roamers/followers)
        local ok, spriteService = pcall(V.require, "follower/sprite_service")
        if ok and spriteService and spriteService.resolveFollowerSprite then
          local shiny = mon.shiny == true or mon.isShiny == true
          local resolved = spriteService:resolveFollowerSprite({
            species = species,
            shiny = shiny,
            surface = "land",
            role = "free_fly_mount",
            game = Game,
          })
          if resolved and resolved.image then
            monSprite = SpriteRenderer.new({
              id = "SPRITE_FREE_FLY_MOUNT",
              image = resolved.image,
              frames = resolved.frames or 6,
              walker = resolved.walker ~= false,
              trueColor = resolved.trueColor ~= false,
            }, "free_fly_" .. species)
            V.mod.log:info("Using follower sprite service for species %s: %s", tostring(species), tostring(resolved.image))
          else
            V.mod.log:info("Follower sprite service returned nil for species %s", tostring(species))
          end
        else
          V.mod.log:info("Follower sprite service not available")
        end
      end

      -- Fall back to Sky.mountSprite if species sprite not available
      Player.__freeFlyMount = monSprite or (species and Sky.mountSprite(Game.data, species, "free_fly")) or Player.__freeFlyBird
      Player.__freeFlyMountScale = species and Sky.dexScale(Game.data, species) or 1
      V.mod.log:info("Mount resolved: species=%s, scale=%s, using=%s", tostring(species), tostring(Player.__freeFlyMountScale), tostring(monSprite and "species_sprite" or "fallback"))
    end

    -- crossConnection re-validates the landing tile on the neighbor map
    -- with Map.defPassable, outside the movement.collision hook; a flyer
    -- crosses any seam, water included
    local MapMod = require("src.world.Map")
    if not MapMod.__freeFlyWrapped then
      MapMod.__freeFlyWrapped = true
      local origPassable = MapMod.defPassable
      MapMod.defPassable = function(...)
        local active = MapMod.__freeFlyActive
        if active and active() then return true end
        return origPassable(...)
      end
    end
    MapMod.__freeFlyActive = function() return flying() end

    -- DRAMATIC_SHAPE's first/third-person FreeMove does its own collision
    -- (Map:isWalkableCell + Collision.occupied directly, never
    -- Collision.canMove), so the airborne pass-through above never
    -- reaches it.  Wrapping its tick opens a permissive window scoped to
    -- exactly that call while the player flies.
    do
      local exports = Game.mods and Game.mods.exports
      local V_module = exports and exports.DRAMATIC_SHAPE and exports.DRAMATIC_SHAPE.lib
      local okFM, FreeMove = pcall(function() return V_module and V_module.require("FreeMove") end)
      if okFM and FreeMove and FreeMove.tick then
        if not MapMod.__freeFlyWalkWrapped then
          MapMod.__freeFlyWalkWrapped = true
          local origWalkable = MapMod.isWalkableCell
          MapMod.isWalkableCell = function(self, cx, cy)
            if MapMod.__freeFlyPermissive then return self:inBounds(cx, cy) end
            return origWalkable(self, cx, cy)
          end
          local origOccupied = Collision.occupied
          Collision.occupied = function(...)
            if MapMod.__freeFlyPermissive then return false end
            return origOccupied(...)
          end
        end
        if not FreeMove.__freeFlyWrapped then
          FreeMove.__freeFlyWrapped = true
          local origTick = FreeMove.tick
          FreeMove.tick = function(fmState, ...)
            local p = fmState and fmState.player
            if not (p and p.freeFlying) then return origTick(fmState, ...) end
            MapMod.__freeFlyPermissive = true
            local ok, err = pcall(origTick, fmState, ...)
            MapMod.__freeFlyPermissive = false
            if not ok then error(err, 0) end
          end
        end
      end
    end

    -- saves from before 0.9.0 have a taken gift but no marker on the mon;
    -- re-mark the first FLY-knowing bird of the gift line so BADGE CHECKS
    -- keeps exempting it (runs on load and on every save swap).  The whole
    -- line matches so an old gift PIDGEY that evolved stays exempt too.
    local function migrateGiftMarker()
      local save = Game.save
      if not (save and save.flags and save.flags[GIFT_TAKEN]) then return end
      local lists = { save.party }
      for _, box in ipairs(save.boxes or {}) do lists[#lists + 1] = box end
      for _, list in ipairs(lists) do
        for _, mon in ipairs(list or {}) do
          if mon.freeFlyGift then return end
        end
      end
      -- prefer a FLY knower; failing that take the first of the line
      -- anyway (a randomizer may have stripped the move), since the
      -- taken flag proves the gift was collected
      local fallback
      for _, list in ipairs(lists) do
        for _, mon in ipairs(list or {}) do
          if mon.species == "PIDGEY" or mon.species == "PIDGEOTTO"
             or mon.species == GIFT_SPECIES then
            if knowsFly(mon) then
              mon.freeFlyGift = true
              V.mod.log:info("marked the gift %s from an older save",
                           mon.species)
              return
            end
            fallback = fallback or mon
          end
        end
      end
      if fallback then
        fallback.freeFlyGift = true
        V.mod.log:info("marked the gift %s from an older save (FLY missing)",
                     fallback.species)
      end
    end
    migrateGiftMarker()
    V.mod.events:on("save.loaded", migrateGiftMarker)

    -- a save loaded while already standing in Pallet Town gets its bird too
    spawnGift()
    V.mod.log:info("Free Fly game.ready completed")
  end)
  
  local ok, err = pcall(function()
    -- Set up the hooks that should be registered outside game.ready
    -- Hook into party submenu to add FREEFLY option
    V.mod.hooks:wrap("ui.party.submenu", function(next, game, items, mon, ctx)
      local out = next(game, items, mon, ctx)
      if type(out) ~= "table" then return out end
      local ow = ctx and ctx.overworld
      V.mod.log:info("FREEFLY HOOK: ow=%s, map=%s, flying=%s",
                   tostring(ow ~= nil),
                   ow and ow.map and ow.map.id or "nil",
                   tostring(flying()))
      if not (ow and ow.map and ow.map.def) or flying() then
        V.mod.log:info("FREEFLY: early return - no overworld or flying")
        return out
      end
      local eligible = eligibleFlyer(game, ow, mon)
      V.mod.log:info("FREEFLY: eligibleFlyer=%s", tostring(eligible))
      local badge = badgeOk(game, mon)
      V.mod.log:info("FREEFLY: badgeOk=%s", tostring(badge))
      if not (eligible and badge) then
        V.mod.log:info("FREEFLY: failed eligibility or badge check")
        return out
      end
      if ow.player and ow.player.onBike then
        V.mod.log:info("FREEFLY: on bike")
        return out
      end
      local sky = skyAbove(game, ow.map.def)
      V.mod.log:info("FREEFLY: skyAbove=%s", tostring(sky))
      if not sky then
        V.mod.log:info("FREEFLY: not sky above")
        return out
      end
      V.mod.log:info("FREEFLY: adding FREEFLY option")
      table.insert(out, 1, { label = "FREEFLY", onSelect = function(m, g)
        V.mod.log:info("FREEFLY selected for %s", tostring(m and m.species))
        local stack = g.stack
        while stack:top() and not stack:top().isOverworld do stack:pop() end
        startFlight(g, m)
      end })
      return out
    end)

    -- Event handlers
    V.mod.events:on("map.entered", function(ev)
      state.giftNpcId = nil
      if ev and (ev.mapId == "PALLET_TOWN" or ev.mapId == "NEW_BARK_TOWN") then spawnGift() end
      if flying() then
        local ow = V.mod.world and V.mod.world:overworld()
        if ow and ow.map and ow.map.def then
          local game = require("src.core.Game")
          if not skyAbove(game, ow.map.def) then
            state.phase, state.alt = "idle", 0
            V.mod.log:info("indoors; flight over")
            emitLanded("indoors", ow.player)
          end
        end
      end
    end)

    V.mod.events:on("save.loaded", function()
      local wasFlying = flying()
      state.phase, state.alt = "idle", 0
      if wasFlying then emitLanded("save_loaded", nil) end
      spawnGift()
    end)

    V.mod.events:on("world.blacked_out", function()
      if flying() then
        state.phase, state.alt = "idle", 0
        V.mod.log:info("blacked out; flight over")
        emitLanded("blackout", nil)
      end
    end)

    -- Hook into movement speed for flying
    V.mod.hooks:wrap("movement.speed", function(next, frames, ctx)
      if flying() then return math.min(frames, flyFrames()) end
      return next(frames, ctx)
    end)

    -- Hook into collision to allow free movement while flying
    V.mod.hooks:wrap("movement.collision", function(next, allowed, ctx)
      if flying() and ctx.mover and ctx.mover.freeFlying then
        -- very tall buildings stay walls even to a flyer, sealed rooftop
        -- plazas included: you ride up to the facade and bump
        local lm = state.landmark
        if lm and lm.cells and ctx.map and lm.mapId == ctx.map.id
           and lm.cells[ctx.toY * lm.w + ctx.toX] then
          ctx.reason = "tile"
          return false
        end
        if ctx.reason == "tile" or ctx.reason == "entity" then
          ctx.reason = nil
          return true
        end
      end
      return next(allowed, ctx)
    end)

    -- airborne you can only flush other flyers: the vanilla roll stands,
    -- but a non-FLYING result becomes no encounter at all
    V.mod.hooks:wrap("encounter.roll", function(next, encDef, ctx)
      local enc = next(encDef, ctx)
      if not (enc and flying()) then return enc end
      if not encountersSetting:get() then return nil end
      local game = require("src.core.Game")
      if Sky.hasType(game.data, enc.species, "FLYING") then return enc end
      return nil
    end)

    -- Hook into save.write to prevent saving mid-flight
    V.mod.hooks:wrap("save.write", function(next, game)
      if flying() then
        V.mod.log:warn("can't save mid-flight; land first (press B)")
        return false
      end
      return next(game)
    end)
  end)
  if not ok then
    V.mod.log:error("Free Fly initialization failed: " .. tostring(err))
    initialized = false
  end

  V.mod.log:info("Free Fly initialized successfully")
end

-- Export for external mods
V.mod.exports.freeFly = {
  isFlying = FreeFly.isFlying,
  altitude = FreeFly.altitude,
  mount = FreeFly.mount,
  registerSpriteSource = FreeFly.registerSpriteSource,
  unregisterSpriteSource = FreeFly.unregisterSpriteSource,
}

return FreeFly