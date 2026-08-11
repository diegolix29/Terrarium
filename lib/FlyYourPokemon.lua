-- Fly Your Pokemon: native Gold/Gen-2 mount owner for STADIUM2_OVERWORLD_MODELS.
--
-- Independent implementation inspired by the public feature surface of popular
-- ride/fly mods. It owns flight, ground ride and visible Surf state inside this
-- package and does not require or load Dramatic Sky Ride.
local V = ...
local mod = V and V.mod
local M = { installed = false, version = "2.0" }

local FLIGHT = {
  CHARIZARD=true, PIDGEOT=true, FEAROW=true, GOLBAT=true, AERODACTYL=true,
  ARTICUNO=true, ZAPDOS=true, MOLTRES=true, DRAGONAIR=true, DRAGONITE=true,
  NOCTOWL=true, CROBAT=true, XATU=true, SKARMORY=true, LUGIA=true, HO_OH=true,
}
local GROUND = {
  ARCANINE=true, RAPIDASH=true, DODRIO=true, RHYHORN=true, RHYDON=true,
  KANGASKHAN=true, TAUROS=true, SNORLAX=true, MEGANIUM=true, GIRAFARIG=true,
  URSARING=true, DONPHAN=true, STANTLER=true, RAIKOU=true, ENTEI=true,
  SUICUNE=true, TYRANITAR=true,
}
local SURF = {
  BLASTOISE=true, TENTACRUEL=true, GYARADOS=true, LAPRAS=true,
  FERALIGATR=true, MANTINE=true, KINGDRA=true, LUGIA=true,
}
local ALL = {}
for k in pairs(FLIGHT) do ALL[k]=true end
for k in pairs(GROUND) do ALL[k]=true end
for k in pairs(SURF) do ALL[k]=true end

local state = {
  mode=nil, species=nil, slot=nil, altitude=0, targetAltitude=0,
  flightClock=0, gallop=1, notice=nil, noticeTimer=0, selected={},
  reachedMaps={}, world=nil, mountEntity=nil, mountSprite=nil,
  nativePlayerYOffset=nil, guard=nil, amphibiousWater=false, pendingFlight=false,
  sessionReady=false, resettingSession=false, suppressStoredFlight=true,
  -- Landing is deliberately deferred out of the controller callback. Gold's
  -- gamepad event can arrive while the current render/world objects are still
  -- being traversed; tearing the Stadium mount/entity down from inside that
  -- callback can invalidate live renderer state. The request is consumed at
  -- World:step's Gen2Compat tail instead.
  pendingLand=false, pendingLandGame=nil, wasVisibleSurf=false,
  controllerQuarantineInstalled=false, controllerQuarantinePasses=0,
  controllerBlockedEdges=0, padPoll={}, loveBlockedButtons={},
  loveGamepadGuardInstalled=false, mountRenderActive=false,
  flightIntentX=0, flightIntentZ=0, flightIntentFresh=false,
}
M.state = state

-- Forward declarations used by landing cleanup before the movement-guard
-- implementation appears later in the file.
local resetFreePosition, restoreGuards, requestLanding, installGuards

local function opt(key, default)
  local o = mod and mod.options
  if not (o and type(o.get)=="function") then return default end
  local ok, v = pcall(o.get, o, key)
  if not ok or v == nil then return default end
  return v
end
local function on(key, default)
  local v = opt(key, default)
  return not (v==false or v==0 or v=="0" or v=="false" or v=="off")
end
local function num(key, default)
  return tonumber(opt(key, default)) or default
end
local function upper(s)
  return type(s)=="string" and s:upper():gsub("[^A-Z0-9]+","_") or nil
end
local atan2 = math.atan2 or function(y, x)
  if x > 0 then return math.atan(y / x) end
  if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
  if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
  if x == 0 and y > 0 then return math.pi / 2 end
  if x == 0 and y < 0 then return -math.pi / 2 end
  return 0
end
local function wrapPi(a)
  while a > math.pi do a = a - math.pi * 2 end
  while a < -math.pi do a = a + math.pi * 2 end
  return a
end
local function approachAngle(a, b, maxStep)
  local d = wrapPi(b - a)
  if d > maxStep then d = maxStep elseif d < -maxStep then d = -maxStep end
  return wrapPi(a + d)
end
local function liveGame()
  return (V and V.game) or (mod and mod.game)
end

local writingFlightOption = false
local function writeStoredOption(key, value, game)
  if writingFlightOption then return false end
  writingFlightOption = true
  local okC, Config = pcall(require, "lib.config")
  local wrote = false
  if okC and Config and type(Config.setOption) == "function" then
    local ok, result = pcall(Config.setOption, mod, key, value, "fly_your_pokemon", { game = game or liveGame() })
    wrote = ok and result == true
  end
  writingFlightOption = false
  return wrote
end

local function setFlightOption(enabled, game)
  return writeStoredOption("mountFlightMode", enabled == true, game)
end

-- Landing only needs the live option value to flip immediately.  Persisting
-- through Config.setOption also calls the host option writer, which is useful
-- for menus but unnecessary inside the flight state transition.  Keep the
-- controller LAND path free of save/file/manager side effects: update the
-- in-memory buckets that mod.options:get reads and let the normal save/options
-- lifecycle persist them later.  Fresh boot already clears stale FLY=ON.
local function setRuntimeFlightOption(enabled, game)
  game = game or liveGame()
  local value = enabled == true
  local function write(bucket)
    if type(bucket) ~= "table" or not (mod and mod.id) then return false end
    bucket[mod.id] = bucket[mod.id] or {}
    bucket[mod.id].mountFlightMode = value
    return true
  end
  local wrote = false
  if game and game.save then
    game.save.options = game.save.options or {}
    game.save.options.modOptions = game.save.options.modOptions or {}
    if write(game.save.options.modOptions) then wrote = true end
  end
  if game and game.mods then
    game.mods.modOptions = game.mods.modOptions or {}
    if write(game.mods.modOptions) then wrote = true end
    if game.mods.loader then
      game.mods.loader.modOptions = game.mods.loader.modOptions or {}
      if write(game.mods.loader.modOptions) then wrote = true end
    end
  end
  return wrote
end
local function liveWorld(game)
  game = game or liveGame()
  if game and game.world then return game.world end
  local api = mod and mod.world
  if api and type(api.overworld)=="function" then
    local ok, w = pcall(api.overworld, api)
    if ok then return w end
  end
  return nil
end
local function busy(world)
  if not world then return true end
  if type(world.busy)=="function" then
    local ok, v = pcall(world.busy, world)
    if ok and v then return true end
  end
  return world.player == nil
end

local function freeOverworldInput(game)
  game = game or liveGame()
  local world = liveWorld(game)
  if not (game and world and world.player and world.map) then return false end
  if game.phase ~= nil and game.phase ~= "play" then return false end
  local stack = game.stack
  if stack and type(stack.top) == "function" then
    local okTop, top = pcall(stack.top, stack)
    if okTop and top ~= nil then return false end
  end
  if type(world.acceptsMenuInput) == "function" then
    local ok, allowed = pcall(world.acceptsMenuInput, world)
    if not ok or allowed ~= true then return false end
  elseif busy(world) then
    return false
  end
  return true
end

-- LAND must still be reachable while the mount is moving. Gold's
-- acceptsMenuInput() intentionally returns false mid-step, so using the normal
-- free-roam gate for landing made Cross/A leak through to the engine whenever
-- the player tried to land while moving. Only screen ownership matters here:
-- gameplay active, live world present, and no menu/battle state stacked above.
local function flightInputOwned(game)
  game = game or liveGame()
  local world = liveWorld(game)
  if not (game and world and world.player and world.map) then return false end
  if game.phase ~= nil and game.phase ~= "play" then return false end
  local stack = game.stack
  if stack and type(stack.top) == "function" then
    local okTop, top = pcall(stack.top, stack)
    if not okTop or top ~= nil then return false end
  end
  return true
end

local function logInputError(button, err)
  if mod and mod.log and type(mod.log.warn) == "function" then
    pcall(mod.log.warn, mod.log,
      "Fly Your Pokemon controller shortcut %s failed safely: %s",
      tostring(button), tostring(err))
  end
end
local function notice(s)
  state.notice, state.noticeTimer = tostring(s or ""), 2.2
  if mod and mod.log and mod.log.info then pcall(mod.log.info, mod.log, "Fly Your Pokemon: %s", tostring(s)) end
end

local function feedback(strength, seconds)
  if not on("mountSoundRumble", true) then return end
  local j = love and love.joystick
  if j and type(j.getJoysticks) == "function" then
    local ok, list = pcall(j.getJoysticks)
    if ok then
      for _, js in ipairs(list or {}) do
        if js and type(js.setVibration) == "function" then
          pcall(js.setVibration, js, strength or 0.25, strength or 0.25, seconds or 0.12)
        end
      end
    end
  end
  local sys = love and love.system
  if sys and type(sys.vibrate) == "function" then pcall(sys.vibrate, seconds or 0.08) end
end

local function playCry(species)
  if not on("mountCries", true) or not species then return end
  local okS, Sound = pcall(require, "src.core.Sound")
  local game = liveGame()
  if okS and Sound and type(Sound.playCry) == "function" and game and game.data then
    pcall(Sound.playCry, game.data, species)
  end
end

local function party(game)
  local save = game and game.save or (mod and mod.game and mod.game.save)
  return save and save.party or {}
end
local function monSpecies(mon)
  return upper(mon and (mon.species or mon.id or mon.name))
end

local function partyEntryForMon(game, mon)
  if not mon then return nil end
  for i, candidate in ipairs(party(game)) do
    if candidate == mon then
      return { slot = i, mon = candidate, species = monSpecies(candidate) }
    end
  end
  -- Some menu adapters hand mods a shallow mon view instead of the exact
  -- party object.  Fall back to the species only when it is unambiguous.
  local wanted = monSpecies(mon)
  local hit
  for i, candidate in ipairs(party(game)) do
    if monSpecies(candidate) == wanted then
      if hit then return nil end
      hit = { slot = i, mon = candidate, species = wanted }
    end
  end
  return hit
end
local function knows(mon, move)
  move = upper(move)
  for _, m in ipairs(mon and mon.moves or {}) do
    local id = type(m)=="table" and (m.id or m.move or m.name) or m
    if upper(id)==move then return true end
  end
  return false
end
local function badge(game, name, index)
  local save = game and game.save
  local b = save and save.player and save.player.badges
  if type(b)~="table" then return false end
  return b[name] == true or b[index] == true
end
function M.supportsFlight(mon)
  local species = monSpecies(mon)
  return species ~= nil and FLIGHT[species] == true
end

function M.supportsSurf(mon)
  local species = monSpecies(mon)
  return species ~= nil and SURF[species] == true
end

local function flyProgress(game, mon)
  if on("mountRequireFly", true) and not knows(mon, "FLY") then return false end
  if on("mountBadgeChecks", true) and not badge(game, "STORM", 6) then return false end
  return true
end
local function surfProgress(game, mon)
  if on("mountBadgeChecks", true) and not badge(game, "FOG", 4) then return false end
  if on("mountRequireSurf", true) and mon ~= nil and not knows(mon, "SURF") then return false end
  return true
end
local function roster(mode)
  if mode=="flight" then return FLIGHT end
  if mode=="ground" then return GROUND end
  return SURF
end
local function eligible(game, mode)
  local out = {}
  for i, mon in ipairs(party(game)) do
    local s = monSpecies(mon)
    if s and roster(mode)[s] and not mon.egg and (tonumber(mon.hp) or 1) > 0 then
      local ok = true
      if mode=="flight" then ok = flyProgress(game, mon)
      elseif mode=="surf" then ok = surfProgress(game, mon) end
      if ok then out[#out+1] = {slot=i, mon=mon, species=s} end
    end
  end
  return out
end
local function preferredFlightSpecies()
  local wanted = upper(opt("mountFlightPokemon", "auto"))
  if wanted == nil or wanted == "AUTO" then return nil end
  return wanted
end

local function choose(game, mode)
  local list = eligible(game, mode)
  if #list==0 then return nil end
  if mode == "flight" then
    local preferred = preferredFlightSpecies()
    if preferred then
      for _, e in ipairs(list) do
        if e.species == preferred then
          state.selected[mode] = e.slot
          return e
        end
      end
      return nil
    end
  end
  local wanted = state.selected[mode]
  for _, e in ipairs(list) do if e.slot==wanted then return e end end
  state.selected[mode] = list[1].slot
  return list[1]
end
function M.cycleMount(mode, delta)
  local game = liveGame()
  if mode == "flight" and preferredFlightSpecies() then
    writeStoredOption("mountFlightPokemon", "auto", game)
  end
  local list = eligible(game, mode)
  if #list==0 then notice("NO ELIGIBLE "..string.upper(mode).." MOUNT"); return false end
  local at = 1
  for i,e in ipairs(list) do if e.slot==state.selected[mode] then at=i break end end
  at = ((at-1+(delta or 1)) % #list)+1
  state.selected[mode]=list[at].slot
  notice(list[at].species.." SELECTED")
  if state.mode==mode then state.species=list[at].species; state.slot=list[at].slot; state.mountSprite=nil end
  return true
end

local function mapEnvironment(world)
  local m = world and world.map
  return upper(m and (m.environment or m.env or (m.def and m.def.environment)))
end
local function outdoors(world)
  local e = mapEnvironment(world)
  if not e then return true end
  if e:find("CAVE",1,true) or e:find("DUNGEON",1,true) or e:find("INDOOR",1,true)
     or e:find("BUILDING",1,true) then return false end
  return true
end
local function currentWater(world)
  local m,p = world and world.map, world and world.player
  if not (m and p) then return false end
  if type(m.isWaterCell)=="function" then
    local ok,v=pcall(m.isWaterCell,m,p.cellX,p.cellY); if ok then return v==true end
  end
  return false
end
local function cellSafe(world, x, y)
  local m = world and world.map
  if not (m and type(m.inBounds)=="function" and m:inBounds(x,y)) then return false end
  if type(m.isWalkable)=="function" and not m:isWalkable(x,y) then return false end
  if type(m.warpAt)=="function" and m:warpAt(x,y) then return false end
  for _,e in ipairs(world.entities or {}) do
    if e~=world.player and not e.passable and e.cellX==x and e.cellY==y then return false end
  end
  for _,e in ipairs(world.npcs or {}) do
    if e~=world.player and not e.passable and e.cellX==x and e.cellY==y then return false end
  end
  return true
end

local function sizeScale(species)
  local key = "mountSize_"..tostring(species or ""):lower()
  local custom = num(key, 100)/100
  if opt("mountSizeOverrides","hidden") ~= "edit" then custom=1 end
  if not on("mountRealisticSizes", true) then return custom end
  -- Use the package's canonical Gen-1/2 Pokédex heights when the species row
  -- is available.  Keep the range comfortable for an overworld mount: the
  -- relationship is proportional, but enormous serpents do not become a
  -- forty-tile obstruction and smaller flyers still remain rideable.
  local base = 1.0
  local game = liveGame()
  local def = game and game.data and game.data.pokemon and game.data.pokemon[species]
  local dex = def and tonumber(def.index) or nil
  local okH, Heights = pcall(V.require, "PokemonHeights")
  local dm = okH and Heights and Heights.DECIMETERS and dex and Heights.DECIMETERS[dex] or nil
  if tonumber(dm) then
    local meters = tonumber(dm) / 10
    base = math.max(0.78, math.min(1.42, meters / 1.65))
  end
  return base*custom
end

local function resolveSprite(species, surface)
  if state.mountSprite and state.mountSpriteSpecies==species and state.mountSpriteSurface==surface then return state.mountSprite end
  local resolver = mod and mod.exports and mod.exports.resolveFollowerSprite
  if type(resolver)~="function" then return nil end
  local ok, def = pcall(resolver, {species=species, surface=surface or "land", role="mount", game=liveGame()})
  if not (ok and type(def)=="table" and def.image) then return nil end
  def = setmetatable({ flyYourPokemonMountSpecies=species, id="FLY_YOUR_POKEMON_"..species }, {__index=def})
  local okR, SpriteRenderer = pcall(require,"src.render.SpriteRenderer")
  if not (okR and SpriteRenderer and type(SpriteRenderer.new)=="function") then return nil end
  local okS, sprite = pcall(SpriteRenderer.new, def, "fly_your_pokemon_mount")
  if not okS then return nil end
  state.mountSprite, state.mountSpriteSpecies, state.mountSpriteSurface = sprite, species, surface
  return sprite
end

local function visualMode(world)
  if state.mode then return state.mode end
  if on("mountVisibleSurf",true) and world then
    local ps = world.playerState
    if ps=="surf" or ps=="surf_pika" or ps==4 or ps==8 then return "surf" end
  end
  return nil
end
local function visibleChoice(world)
  local mode = visualMode(world)
  if not mode then return nil,nil end
  if state.mode==mode and state.species then return mode,state.species end
  local e = choose(liveGame(),"surf")
  return mode,e and e.species or nil
end
local function altitudeLift()
  if state.mode~="flight" then return 0 end
  return math.max(0, tonumber(state.altitude) or 0)
end
local function riderSeatOffset(species, mode)
  local s=sizeScale(species)
  local mount = state.mountEntity
  local modelH = mount and tonumber(mount._flyYourPokemonStadiumWorldHeight) or nil
  if mount and mount._flyYourPokemonStadiumActive == true
      and modelH and modelH > 0
      and tostring(opt("mountRenderer", "auto")):lower() ~= "2d" then
    -- Stadium models vary enormously in authored height. Seat the trainer near
    -- the upper body instead of using the tiny 2D-card offset for everything.
    local frac = mode == "flight" and 0.58 or (mode == "surf" and 0.42 or 0.48)
    return math.floor(math.max(5, math.min(42, modelH * frac)) + 0.5)
  end
  if mode=="flight" then return math.floor(7*s+0.5) end
  if mode=="surf" then return math.floor(4*s+0.5) end
  return math.floor(5*s+0.5)
end

local function ensureMountEntity(world)
  local mode,species=visibleChoice(world)
  if not (mode and species and world and world.player) then
    state.mountRenderActive=false
    -- Never delete the Stadium carrier from Gold's live entity array during a
    -- dismount.  The voxel renderer can still be walking/cache-referencing that
    -- table later in the same frame.  Park the passable carrier instead and
    -- reuse it on the next mount.  With all Pokemon identity/render flags
    -- cleared it is invisible to both the 2D and Stadium renderers.
    local e = state.mountEntity
    if e then
      local ow = V and V.OverworldStadium
      if ow and type(ow.untag) == "function" then pcall(ow.untag, e) end
      e.sprite=nil; e.spriteDef=nil; e.species=nil
      e.flyYourPokemonMountSpecies=nil; e._flyYourPokemonSpecies=nil
      e._flyYourPokemonMode=nil; e._flyYourPokemonScale=nil
      e._flyYourPokemonForceStadium=nil; e.stadiumModel=nil
      e._flyYourPokemonMount=false; e._flyYourPokemonParked=true
      e._flyYourPokemonShadow=false; e.visibleSprite=false
      e.worldRenderer=nil
      e.voxelDisabled=true; e.voxelRegistered=false; e.voxelUpdateOk=false
      e.render2DFallback=false
    end
    state.mountSprite=nil
    return
  end
  state.mountRenderActive=true
  local p=world.player
  local surface = mode=="surf" and "water" or (state.amphibiousWater and "water" or "land")
  local mountRenderer = tostring(opt("mountRenderer", "auto")):lower()
  local sprite=resolveSprite(species,surface)
  -- Stadium mounts must not depend on the 2D follower-art provider.  Older
  -- builds returned here when no follower sprite could be resolved, which
  -- meant a perfectly valid imported Stadium model never even received an
  -- entity/pose to render.  AUTO/STADIUM now creates a species-tagged carrier
  -- directly; the sprite is only a fallback for cards/2D mode.
  if not sprite and mountRenderer == "2d" then return end
  local e=state.mountEntity
  if not e then
    e={id="fly_your_pokemon_mount", passable=true, flyYourPokemonMount=true}
    e.pose=function(self)
      local pp=state.world and state.world.player
      if not pp then return nil end
      local lift=altitudeLift()
      local phase=(state.mode=="flight") and (math.floor(state.flightClock*5)%2) or ((pp.walkPhase and pp:walkPhase()) or 0)
      return self.sprite, pp.px, pp.py-lift, pp.facing, phase, pp.stepFlip==true, false
    end
    state.mountEntity=e
  end
  e.sprite=sprite; e.spriteDef=sprite and sprite.def or nil; e.species=species
  e.visibleSprite=nil; e._flyYourPokemonParked=nil
  e.flyYourPokemonMount=true
  e.flyYourPokemonMountSpecies=species; e._flyYourPokemonMount=true
  e._flyYourPokemonSpecies=species
  e._flyYourPokemonMode=mode; e._flyYourPokemonScale=sizeScale(species)
  -- Make the mount an explicit Stadium entity instead of relying on the
  -- follower sprite filename to be reverse-inferred as a species.  AUTO and
  -- STADIUM therefore use the imported 3D model whenever it is available;
  -- the 2D SpriteRenderer remains only the fallback/carrier pose.
  if mountRenderer ~= "2d" then
    e.worldRenderer = V.voxelHostId or "DRAMATIC_SHAPE"
    e.voxelDisabled = false
    e.voxelRegistered = true
    e.voxelUpdateOk = true
    e.render2DFallback = false
    e._flyYourPokemonForceStadium = true
    e.stadiumModel = true
    local ow = V and V.OverworldStadium
    if ow and type(ow.tag) == "function" then pcall(ow.tag, e, species) end
  else
    local ow = V and V.OverworldStadium
    if ow and type(ow.untag) == "function" then pcall(ow.untag, e) end
    e.worldRenderer=nil; e.voxelDisabled=true; e.voxelRegistered=false
    e.voxelUpdateOk=false; e.render2DFallback=true
    e._flyYourPokemonForceStadium=nil; e.stadiumModel=nil
  end
  e._flyYourPokemonShadow=on("mountDynamicShadow",true)
  e._flyYourPokemonAnimTime=state.flightClock
  e._flyYourPokemonClimb=(tonumber(state.targetAltitude) or 0)-(tonumber(state.altitude) or 0)
  local turn = 0
  if e._flyYourPokemonLastFacing and e._flyYourPokemonLastFacing ~= p.facing then
    local order={up=0,right=1,down=2,left=3}
    local a,b=order[e._flyYourPokemonLastFacing],order[p.facing]
    if a and b then local d=(b-a)%4; turn=(d==1 and 1) or (d==3 and -1) or 0 end
  end
  e._flyYourPokemonBank = turn
  e._flyYourPokemonLastFacing=p.facing
  e.cellX,e.cellY=p.cellX,p.cellY; e.px,e.py=p.px,p.py; e.facing=p.facing
  -- Presentation-only carrier: NEVER insert this synthetic mount into Gold's
  -- gameplay world.entities list.  World:interact and several event scans assume
  -- entries there implement Gold's complete NPC/entity contract; a Stadium-only
  -- carrier does not, so a normal confirm/A press could make the engine treat
  -- it like an NPC and crash.  GoldVoxelBridge.mergedEntities() already merges
  -- state.mountEntity directly into the voxel render scene every frame, and
  -- Player:draw handles the 2D fallback, so gameplay ownership is unnecessary.
end

local function saveYOffset(player)
  if state.nativePlayerYOffset==nil then state.nativePlayerYOffset=player.spriteYOffset or 0 end
end
local function restoreYOffset()
  local w=state.world; local p=w and w.player
  if p and state.nativePlayerYOffset~=nil then p.spriteYOffset=state.nativePlayerYOffset end
  state.nativePlayerYOffset=nil
end
local function syncRider(world)
  local p=world and world.player; if not p then return end
  -- Mod-owned presentation marker used by OverworldStadium.  It follows the
  -- real Gold Player object across seamless setMap calls and is cleared as soon
  -- as flight ends, so Surf/Bike can still use their normal special cards.
  p._flyYourPokemonFlight3D = state.mode == "flight" and true or nil
  local mode,species=visibleChoice(world)
  if mode and species then
    saveYOffset(p)
    if on("mountShowRider",true) then
      p._flyYourPokemonHideRider=nil
      p.spriteYOffset=(state.nativePlayerYOffset or 0)-altitudeLift()-riderSeatOffset(species,mode)
    else
      p._flyYourPokemonHideRider=true
      p.spriteYOffset=(state.nativePlayerYOffset or 0)-altitudeLift()
    end
  else
    p._flyYourPokemonHideRider=nil
    restoreYOffset()
  end
end

local function applyPlayerState(world, s)
  if world and type(world.applyPlayerState)=="function" then pcall(world.applyPlayerState,world,s) end
end

-- A Gold map load always runs CheckUpdatePlayerSprite.  That is correct for a
-- walking/surfing player, but free flight can cross a connection whose landing
-- cell is water or whose map callback forces the bike.  In those cases Gold
-- temporarily rewrites playerState to SURF/BIKE and Character Selector quite
-- reasonably falls back to its special 2D card.  Flight owns locomotion and
-- presentation, so keep Gold's underlying state NORMAL for the whole airborne
-- session and tag the real player for the standalone 3D bridge.
local function preserveFlightPlayerPresentation(world)
  if state.mode ~= "flight" or not (world and world.player) then return false end
  local p = world.player
  p._flyYourPokemonFlight3D = true
  local ps = world.playerState
  if ps ~= nil and ps ~= "normal" and ps ~= 0 then
    applyPlayerState(world, "normal")
  end
  p.surfing = false
  return true
end
M._preserveFlightPlayerPresentation = preserveFlightPlayerPresentation

-- Visible Surf starts through Gold's native player state, but custom mount
-- startup can leave that state one tick behind when the forced shoreline step
-- finishes.  Once a completed step is physically on land, restore NORMAL so
-- the Character Selector's 3D player renderer is eligible again immediately.
local function normalizeSurfExit(world, player)
  if not (world and player) then return false end
  local ps = world.playerState
  local surfing = ps=="surf" or ps=="surf_pika" or ps==4 or ps==8
    or player.surfing==true
  if not surfing then
    state.wasVisibleSurf=false
    return false
  end
  -- Do not cancel the initial shore -> water scripted step: at that moment the
  -- logical state is SURF while the player is still moving off the land cell.
  if player.moving then
    state.wasVisibleSurf=true
    return false
  end
  local inWater = currentWater(world)
  if inWater then
    state.wasVisibleSurf=true
    return false
  end
  applyPlayerState(world,"normal")
  player.surfing=false
  player._flyYourPokemonHideRider=nil
  restoreYOffset()
  state.mountSprite=nil
  state.wasVisibleSurf=false
  ensureMountEntity(world)
  return true
end

local function flightMusicStart(world)
  state.musicStopped = false
  if tostring(opt("mountFlyingMusic", "map")) ~= "none" then return end
  local okM, Music = pcall(require, "src.core.Music")
  if okM and Music and type(Music.stop) == "function" then
    pcall(Music.stop); state.musicStopped = true
  end
end

local function flightMusicRestore(world)
  if not state.musicStopped then return end
  state.musicStopped = false
  if world and type(world.forceMapMusic) == "function" then
    pcall(world.forceMapMusic, world)
    return
  end
  local okM, Music = pcall(require, "src.core.Music")
  local game = liveGame()
  if okM and Music and type(Music.playMap) == "function" and game and game.data and world and world.map then
    pcall(Music.playMap, game.data, world.map.id, false, false)
  end
end

local function flightEligibilityFailure(game)
  local preferred = preferredFlightSpecies()
  local sawSupported = false
  for _, mon in ipairs(party(game)) do
    local species = monSpecies(mon)
    if species and FLIGHT[species] and not mon.egg and (tonumber(mon.hp) or 1) > 0
       and (preferred == nil or preferred == species) then
      sawSupported = true
      if on("mountRequireFly", true) and not knows(mon, "FLY") then
        return species:gsub("_", "-") .. " NEEDS FLY"
      end
      if on("mountBadgeChecks", true) and not badge(game, "STORM", 6) then
        return "NEED STORMBADGE"
      end
    end
  end
  if preferred and not sawSupported then
    return preferred:gsub("_", "-") .. " NOT IN PARTY"
  end
  return sawSupported and "FLIGHT REQUIREMENTS NOT MET" or "NO FLYING PARTY POKEMON"
end

local function canTakeOff(game,world,entry)
  if not entry then
    return false, flightEligibilityFailure(game)
  end
  if on("mountStoryGates",true) and not outdoors(world) then return false,"CAN'T FLY HERE" end
  if on("mountQuestCollisions",true) and busy(world) then return false,"BUSY" end
  return true
end
local function activateFlight(game, w, e)
  state.pendingFlight=false
  state.suppressStoredFlight=false
  state.world=w
  state.selected.flight=e.slot
  state.mode="flight"; state.species=e.species; state.slot=e.slot
  state.altitude=math.max(12,state.altitude or 0); state.targetAltitude=state.altitude
  state.mountSprite=nil; state.amphibiousWater=false
  state.flightIntentX,state.flightIntentZ,state.flightIntentFresh=0,0,false
  if w and (w.playerState=="surf" or w.playerState=="surf_pika") then applyPlayerState(w,"normal") end
  pcall(preserveFlightPlayerPresentation, w)
  setFlightOption(true, game)
  flightMusicStart(w)
  -- Arm the airborne interaction guard and presentation carrier immediately,
  -- before the next logic tick.  Previously these were only reconciled from
  -- Player:update; Gold may not call that while the free-flight solver keeps
  -- the player logically idle, leaving a short/unbounded window where confirm
  -- could still reach native World:interact.
  if installGuards then pcall(installGuards, w) end
  pcall(ensureMountEntity, w)
  pcall(syncRider, w)
  playCry(e.species); feedback(0.32, 0.16); notice("FLYING ON "..e.species:gsub("_", "-"))
  return true
end

function M.startFlight(game)
  game=game or liveGame(); local w=liveWorld(game); local e=choose(game,"flight")
  local ok,why=canTakeOff(game,w,e)
  if not ok then
    state.pendingFlight = (why == "BUSY")
    notice(why)
    return false, why
  end
  return activateFlight(game,w,e)
end

-- Party-menu mount action: ride the Pokemon the player actually selected,
-- instead of silently choosing AUTO/slot 1.  The normal progression toggles
-- still apply, and the chosen species is mirrored to Mod Settings so the
-- visible FLYING POKEMON row stays truthful.
function M.startFlightWith(game, mon)
  game=game or liveGame()
  local e=partyEntryForMon(game, mon)
  if not (e and e.species and FLIGHT[e.species]) then
    local why="THIS POKEMON CAN'T FLY"; notice(why); return false,why
  end
  if e.mon.egg or e.mon.isEgg or (tonumber(e.mon.hp) or 1) <= 0 then
    local why="THIS POKEMON CAN'T FLY NOW"; notice(why); return false,why
  end
  if on("mountRequireFly", true) and not knows(e.mon,"FLY") then
    local why=e.species:gsub("_", "-").." NEEDS FLY"; notice(why); return false,why
  end
  if on("mountBadgeChecks", true) and not badge(game,"STORM",6) then
    local why="NEED STORMBADGE"; notice(why); return false,why
  end
  local w=liveWorld(game)
  local ok,why=canTakeOff(game,w,e)
  if not ok then state.pendingFlight=(why=="BUSY"); notice(why); return false,why end
  if state.mode and state.mode ~= "flight" then M.dismount(true) end
  state.selected.flight=e.slot
  writeStoredOption("mountFlightPokemon", e.species, game)
  return activateFlight(game,w,e)
end

local SURF_DELTA = { up={0,-1}, down={0,1}, left={-1,0}, right={1,0} }
local function facingWater(world)
  local p,m=world and world.player,world and world.map
  if not (p and m and type(m.isWaterCell)=="function") then return false end
  local d=SURF_DELTA[p.facing or "down"] or SURF_DELTA.down
  local x,y=(p.cellX or 0)+d[1],(p.cellY or 0)+d[2]
  if type(m.inBounds)=="function" then
    local ok,inside=pcall(m.inBounds,m,x,y); if ok and not inside then return false end
  end
  local ok,water=pcall(m.isWaterCell,m,x,y)
  return ok and water==true
end

local function refreshSurfMusic(game, world)
  if world and type(world.forceMapMusic)=="function" then
    pcall(world.forceMapMusic,world); return
  end
  local okM,Music=pcall(require,"src.core.Music")
  if okM and Music and type(Music.playMap)=="function" and game and game.data and world and world.map then
    pcall(Music.playMap,game.data,world.map.id,false,true)
  end
end

-- Party-menu SWIM action.  Gold's native Surf movement remains authoritative;
-- this only starts that state with the selected supported Pokemon and records
-- which Pokemon should be drawn as the visible water mount.
function M.startSurfWith(game, mon)
  game=game or liveGame()
  local e=partyEntryForMon(game,mon)
  if not (e and e.species and SURF[e.species]) then
    local why="THIS POKEMON CAN'T SWIM"; notice(why); return false,why
  end
  if e.mon.egg or e.mon.isEgg or (tonumber(e.mon.hp) or 1) <= 0 then
    local why="THIS POKEMON CAN'T SWIM NOW"; notice(why); return false,why
  end
  if on("mountRequireSurf", true) and not knows(e.mon,"SURF") then
    local why=e.species:gsub("_", "-").." NEEDS SURF"; notice(why); return false,why
  end
  if on("mountBadgeChecks",true) and not badge(game,"FOG",4) then
    local why="NEED FOGBADGE"; notice(why); return false,why
  end
  local w=liveWorld(game); local p=w and w.player
  if not (w and p) then local why="NO OVERWORLD"; notice(why); return false,why end
  if on("mountQuestCollisions",true) and busy(w) then local why="BUSY"; notice(why); return false,why end
  state.selected.surf=e.slot
  state.mountSprite=nil
  if w.playerState=="surf" or w.playerState=="surf_pika" or p.surfing==true then
    playCry(e.species); notice("SWIMMING ON "..e.species:gsub("_", "-")); ensureMountEntity(w)
    return true
  end
  if not facingWater(w) then local why="FACE THE WATER"; notice(why); return false,why end
  if state.mode then M.dismount(true) end
  local surfState="surf"
  local okF,FieldMoves=pcall(require,"src.world.gen2.FieldMoves")
  if okF and FieldMoves and type(FieldMoves.surfType)=="function" then
    local okS,v=pcall(FieldMoves.surfType,e.mon); if okS and v then surfState=v end
  end
  applyPlayerState(w,surfState)
  p.surfing=true
  refreshSurfMusic(game,w)
  if type(p.scriptStep)=="function" then pcall(p.scriptStep,p,p.facing) end
  w.fieldMove={phase="step"}
  state.world=w
  playCry(e.species); feedback(0.24,0.12); notice("SWIMMING ON "..e.species:gsub("_", "-"))
  ensureMountEntity(w)
  return true
end
function M.startGround(game)
  game=game or liveGame(); local w=liveWorld(game); local e=choose(game,"ground")
  if not e then notice("NO GROUND MOUNT"); return false end
  if busy(w) then notice("BUSY"); return false end
  state.pendingFlight=false
  setFlightOption(false, game)
  state.mode="ground"; state.species=e.species; state.slot=e.slot; state.altitude=0; state.targetAltitude=0
  state.mountSprite=nil; state.amphibiousWater=false
  playCry(e.species); feedback(0.28, 0.14); notice("RIDING "..e.species); return true
end
local function safeMapCall(obj, name, ...)
  local fn = obj and obj[name]
  if type(fn) ~= "function" then return false, nil end
  local ok, value = pcall(fn, obj, ...)
  if not ok then return false, nil end
  return true, value
end

local function landingSafe(world, player)
  if not (world and player and world.map) then return false, false end
  local map = world.map
  local okBounds, inside = safeMapCall(map, "inBounds", player.cellX, player.cellY)
  if okBounds and inside ~= true then return false, false end
  local okWater, water = safeMapCall(map, "isWaterCell", player.cellX, player.cellY)
  if okWater and water == true then return true, true end
  local okWalk, walkable = safeMapCall(map, "isWalkable", player.cellX, player.cellY)
  if okWalk and walkable ~= true then return false, false end
  local okWarp, warp = safeMapCall(map, "warpAt", player.cellX, player.cellY)
  if okWarp and warp then return false, false end
  for _, e in ipairs(world.entities or {}) do
    if e ~= player and e ~= state.mountEntity and not e.passable
        and e.cellX == player.cellX and e.cellY == player.cellY then
      return false, false
    end
  end
  for _, e in ipairs(world.npcs or {}) do
    if e ~= player and e ~= state.mountEntity and not e.passable
        and e.cellX == player.cellX and e.cellY == player.cellY then
      return false, false
    end
  end
  return true, false
end

local function forceDismountCleanup(world, oldMode)
  -- Ground-ride cleanup only.  Flight landing deliberately does NOT come
  -- through this function anymore: controller LAND must not restore method
  -- wrappers, retag Stadium entities, vibrate hardware, or write options while
  -- transitioning out of the airborne frame.
  if oldMode == "flight" then flightMusicRestore(world) end
  state.mode=nil; state.species=nil; state.slot=nil
  state.altitude=0; state.targetAltitude=0; state.amphibiousWater=false
  state.pendingFlight=false
  state.pendingLand=false; state.pendingLandGame=nil
  state.mountRenderActive=false
  resetFreePosition()
  restoreYOffset()
  if oldMode == "flight" then setRuntimeFlightOption(false, liveGame()) end
end

-- Minimal flight landing commit.  This runs from input.step BEFORE Input:step
-- and World:step, so Gold is not iterating players/entities and the renderer
-- is not traversing the Stadium carrier.  The carrier itself is left intact;
-- GoldVoxelBridge simply stops submitting it once mountRenderActive is false.
-- Stable world wrappers are also left installed and become transparent because
-- every wrapper already checks state.mode before changing behavior.
local function commitFlightLanding(game, force)
  if state.mode ~= "flight" then return false end
  game = game or liveGame()
  local w=state.world or liveWorld(game); local p=w and w.player
  if not force and p then
    local safe, water = landingSafe(w, p)
    if not safe then notice("NO SAFE LANDING"); return false end
    -- Keep controller LAND completely out of Gold's Surf/player-state machine.
    -- Water landing can still be added later as a staged transition, but a
    -- crash-fix build must not combine flight teardown with applyPlayerState.
    -- Use the existing SWIM action to enter visible Surf.
    if water then
      notice("LAND OVER SOLID GROUND")
      return false
    end
  end

  -- Pure-Lua live option update only; no disk persistence / Manager callbacks.
  setRuntimeFlightOption(false, game)
  if p then p._flyYourPokemonFlight3D = nil end

  -- The entire crash-sensitive transition is these state writes.  Do not
  -- restore player offsets, world wrappers, music, Stadium tags/entities or
  -- haptics here.  The next ordinary Player:update sees mode=nil and naturally
  -- restores rider/follower presentation before the frame is drawn.
  state.mode=nil; state.species=nil; state.slot=nil
  state.altitude=0; state.targetAltitude=0; state.amphibiousWater=false
  state.pendingFlight=false
  state.pendingLand=false; state.pendingLandGame=nil
  state.mountRenderActive=false
  state.pendingPostLandCleanup=true
  resetFreePosition()
  notice("LANDED")
  return true
end
M._commitFlightLanding = commitFlightLanding

function M.dismount(force)
  local old=state.mode
  if old=="flight" then
    return commitFlightLanding(liveGame(), force == true)
  end
  local w=state.world or liveWorld()
  state.mode=nil; state.species=nil; state.slot=nil
  state.altitude=0; state.targetAltitude=0; state.amphibiousWater=false
  state.pendingFlight=false
  state.pendingLand=false; state.pendingLandGame=nil
  state.mountRenderActive=false
  local ok, err = pcall(forceDismountCleanup, w, old)
  if not ok and mod and mod.log and type(mod.log.error)=="function" then
    pcall(mod.log.error, mod.log, "Fly Your Pokemon dismount cleanup failed safely: %s", tostring(err))
  end
  if old then feedback(0.18, 0.08); notice("DISMOUNTED") end
  return true
end

function M.land(game)
  return commitFlightLanding(game or liveGame(), false)
end

requestLanding = function(game)
  if state.mode ~= "flight" then return false end
  state.pendingLand = true
  state.pendingLandGame = game or liveGame()
  return true
end
M.requestLanding = requestLanding

local function processPendingLanding()
  if not state.pendingLand then return false end
  local game = state.pendingLandGame or liveGame()
  -- Clear first: a failed/blocked landing is one button press, not a retry loop.
  state.pendingLand = false
  state.pendingLandGame = nil
  if state.mode ~= "flight" then return false end
  local ok, landed = pcall(commitFlightLanding, game, false)
  if ok then return landed == true end
  logInputError("LAND", landed)
  return false
end

local function disableLegacyLandingTail()
  -- v0.3.09-v0.3.12 wrapped the Gen1 facade OverworldController.update to
  -- process LAND after World:step.  Leave any already-installed bridge inert
  -- on hot reload; v0.3.13 commits LAND at input.step before world iteration.
  local ok, OverworldState = pcall(require, "src.world.OverworldController")
  if ok and type(OverworldState)=="table" then
    local bridge=OverworldState._flyYourPokemonLandingTailBridge
    if type(bridge)=="table" then bridge.process=nil end
  end
  return true
end

function M.toggleFlight(game)
  if state.mode=="flight" then return requestLanding(game) end
  if state.mode then M.dismount(true) end
  return M.startFlight(game)
end
function M.toggleGround(game)
  if state.mode=="ground" then return M.dismount(true) end
  if state.mode then M.dismount(true) end
  return M.startGround(game)
end

local isHeld

local function flightSteeringOwned()
  -- Flight movement is its own controller.  Do not require the 1ST/3RD camera
  -- rung here: DIORAMA must still steer, and tying movement ownership to
  -- FirstPerson.driving() is what made the v0.3.14 solver silently receive no
  -- usable vector on some camera/player-controller combinations.
  return state.mode == "flight" and flightInputOwned(liveGame())
end

local function sampleFlightIntent()
  -- Read the live engine Input table directly every logic tick.  This is the
  -- same source FirstPerson.moveVector() uses for both the analog left stick
  -- and held D-pad actions, but unlike v0.3.14 it does not depend on
  -- GoldCameraControls writing a temporary _stadiumFreeIntent field first.
  local ok, FP = pcall(V.require, "FirstPerson")
  local mx, mz = 0, 0
  if ok and FP and type(FP.moveVector) == "function" then
    local okV, x, z = pcall(FP.moveVector)
    if okV then mx, mz = tonumber(x) or 0, tonumber(z) or 0 end
  else
    local game = liveGame()
    local input = game and game.input
    local ax = input and input.stickAxis
    if type(ax) == "table" then
      local x, y = tonumber(ax.x) or 0, tonumber(ax.y) or 0
      local mag = math.sqrt(x*x + y*y)
      if mag > 0.20 then
        local capped = math.min(1, mag)
        mx, mz = x / mag * capped, -y / mag * capped
      end
    end
    if math.abs(mx) < 0.001 and math.abs(mz) < 0.001 and input
        and type(input.isDown) == "function" then
      local function held(name)
        local okH, v = pcall(input.isDown, input, name)
        return okH and v == true
      end
      mx = (held("right") and 1 or 0) - (held("left") and 1 or 0)
      mz = (held("up") and 1 or 0) - (held("down") and 1 or 0)
      local mag = math.sqrt(mx*mx + mz*mz)
      if mag > 1 then mx, mz = mx/mag, mz/mag end
    end
  end

  if math.abs(mx) < 0.001 and math.abs(mz) < 0.001 then return 0, 0 end

  -- FIRST/THIRD PERSON use camera-relative steering.  DIORAMA has no
  -- FirstPerson driving yaw, so its controls stay map-relative: up=north,
  -- down=south, left=west, right=east.
  if ok and FP and type(FP.engaged) == "function" then
    local okE, engaged = pcall(FP.engaged)
    if okE and engaged and type(FP.moveWorld) == "function" then
      local okW, wx, wz = pcall(FP.moveWorld, mx, mz)
      if okW then return tonumber(wx) or 0, tonumber(wz) or 0 end
    end
  end
  return mx, -mz
end

resetFreePosition = function()
  state.freeX, state.freeZ, state.freeLastPx, state.freeLastPy = nil,nil,nil,nil
  state.flightIntentX, state.flightIntentZ, state.flightIntentFresh = 0,0,false
end

local function continuousFlight(world, intentX, intentZ)
  if not (flightSteeringOwned() and world and world.player and world.map) then resetFreePosition(); return false end
  local p=world.player
  if p.moving or busy(world) then resetFreePosition(); return false end
  local ok,FP=pcall(V.require,"FirstPerson")
  if not (ok and FP and type(FP.moveWorld)=="function") then return false end
  if state.freeX==nil or math.abs((p.px or 0)-(state.freeLastPx or p.px or 0))>.01
      or math.abs((p.py or 0)-(state.freeLastPy or p.py or 0))>.01 then
    state.freeX=(p.px or p.cellX*16)+8; state.freeZ=(p.py or p.cellY*16)+8
  end
  local wx,wz
  if type(intentX)=="number" and type(intentZ)=="number" then
    -- GoldCameraControls has already rotated the live D-pad/left-stick vector
    -- into world space for this exact camera frame.  Reuse that fresh vector
    -- instead of asking a second input owner to infer it again.
    wx,wz=intentX,intentZ
  elseif type(FP.moveVector)=="function" then
    local mx,mz=FP.moveVector(); mx,mz=tonumber(mx) or 0,tonumber(mz) or 0
    if math.abs(mx)<.001 and math.abs(mz)<.001 then state.freeLastPx,state.freeLastPy=p.px,p.py; return false end
    wx,wz=FP.moveWorld(mx,mz)
  else
    wx,wz=0,0
  end
  wx,wz=tonumber(wx) or 0,tonumber(wz) or 0
  if math.abs(wx)<.001 and math.abs(wz)<.001 then
    state.freeLastPx,state.freeLastPy=p.px,p.py
    return false
  end
  if on("mountCameraFollow",true) and (math.abs(wx)>.001 or math.abs(wz)>.001)
      and type(FP.yaw)=="number" then
    local target=atan2(wx,wz)
    FP.yaw=approachAngle(FP.yaw,target,0.055)
  end
  local speed=(num("mountFlightSpeed",100)/100)
  if on("mountFlightBoost",true) and (isHeld("lshift") or isHeld("rshift")) then speed=speed*1.45 end
  local dx,dz=wx*speed,wz*speed
  if type(FP.bodyFacing)=="function" then local okF,f=pcall(FP.bodyFacing,wx,wz); if okF and f then p.facing=f end end
  local function inside(x,z) return world.map:inBounds(math.floor(x/16),math.floor(z/16)) end
  local nx=state.freeX+dx
  if inside(nx,state.freeZ) then state.freeX=nx
  elseif math.abs(dx)>.001 and type(world.tryConnection)=="function" then
    if world:tryConnection(dx<0 and "left" or "right") then resetFreePosition(); return true end
  end
  local nz=state.freeZ+dz
  if inside(state.freeX,nz) then state.freeZ=nz
  elseif math.abs(dz)>.001 and type(world.tryConnection)=="function" then
    if world:tryConnection(dz<0 and "up" or "down") then resetFreePosition(); return true end
  end
  p.px,p.py=state.freeX-8,state.freeZ-8
  p.cellX,p.cellY=math.floor(state.freeX/16),math.floor(state.freeZ/16)
  p.targetX,p.targetY=nil,nil; p.moving=false; p.progress=0
  state.freeLastPx,state.freeLastPy=p.px,p.py
  return true
end

restoreGuards = function()
  local g=state.guard
  if not g then return end
  local w=g.world
  for name,raw in pairs(g.raw) do rawset(w,name,raw==g.absent and nil or raw) end
  state.guard=nil
end
installGuards = function(world)
  if state.guard and state.guard.world==world then return end
  restoreGuards(); if not world then return end
  local g={world=world,raw={},absent={}}; state.guard=g
  local function wrap(name,fn)
    local raw=rawget(world,name); g.raw[name]=raw==nil and g.absent or raw
    local native=world[name]; if type(native)~="function" then return end
    rawset(world,name,fn(native))
  end
  wrap("pollInput",function(native) return function(self,input,...)
    if state.mode=="flight" and flightSteeringOwned() then
      -- Do not hand airborne directions to Gold's grid/free-walk owners.
      -- Steering is sampled directly from the live Input object after the
      -- native world body has completed.  This leaves GoldCameraControls
      -- installed for normal walking but removes it from Flight's ownership
      -- chain entirely.
      self.heldDir=nil
      self._stadiumFreeIntentX,self._stadiumFreeIntentZ=nil,nil
      self._stadiumFreeX,self._stadiumFreeZ=nil,nil
      self._stadiumFreeMapId=nil
      self._stadiumFreeMoveActive=nil
      self._stadiumFreeVisualMoving=false
      return nil
    end
    return native(self,input,...)
  end end)
  wrap("stepBody",function(native) return function(self,...)
    local owns = state.mode=="flight" and flightSteeringOwned()
    if owns then
      -- Clear any continuous-walk state left from the frame before takeoff so
      -- GoldCameraControls cannot replay it from its stepBody tail.
      self.heldDir=nil
      self._stadiumFreeIntentX,self._stadiumFreeIntentZ=nil,nil
      self._stadiumFreeX,self._stadiumFreeZ=nil,nil
      self._stadiumFreeMapId=nil
      self._stadiumFreeMoveActive=nil
      self._stadiumFreeVisualMoving=false
      state.flightIntentX,state.flightIntentZ=0,0
      state.flightIntentFresh=false
    end

    local a,b,c=native(self,...)

    if state.mode=="flight" and flightSteeringOwned() then
      -- Sample AFTER native Gold simulation so the vector is the current
      -- controller state for this tick, not a temporary field that another
      -- movement wrapper can clear.  Releasing the stick therefore becomes
      -- 0,0 immediately; changing direction is visible on this same tick.
      local wx,wz=sampleFlightIntent()
      state.flightIntentX,state.flightIntentZ=wx,wz
      state.flightIntentFresh=true
      local okMove,errMove=pcall(continuousFlight,self,wx,wz)
      if not okMove and mod and mod.log and type(mod.log.warn)=="function" then
        pcall(mod.log.warn,mod.log,"Fly Your Pokemon steering step failed safely: %s",tostring(errMove))
      end
      -- Keep Gold's ordinary free-walk owner empty for the next tick.
      self.heldDir=nil
      self._stadiumFreeIntentX,self._stadiumFreeIntentZ=nil,nil
      self._stadiumFreeX,self._stadiumFreeZ=nil,nil
      self._stadiumFreeMapId=nil
      self._stadiumFreeMoveActive=nil
      self._stadiumFreeVisualMoving=false
    end
    return a,b,c
  end end)
  wrap("interact",function(native) return function(self,...)
    if state.mode=="flight" then
      -- A/confirm is not a landing path.  Older builds synchronously called
      -- M.land() here; if a controller confirm leaked past the outer wrapper it
      -- could mutate the Stadium entity list during World:step and crash.
      -- Consume interaction while airborne.  Dedicated LAND input queues the
      -- teardown at the post-world-step tail instead.
      return true
    end
    return native(self,...)
  end end)
  for _,name in ipairs({"checkTrainerBattle","checkWarpOnArrive","tryCoordScript","countStep","tryWildEncounter","checkCarpetWhileStanding"}) do
    wrap(name,function(native) return function(self,...)
      if state.mode=="flight" then return false end
      return native(self,...)
    end end)
  end
  wrap("tryConnection",function(native) return function(self,dir,...)
    if state.mode~="flight" then return native(self,dir,...) end
    local crossed=native(self,dir,...)
    if crossed then
      pcall(preserveFlightPlayerPresentation, self)
      pcall(syncRider, self)
      return crossed
    end
    local okM,Map=pcall(require,"src.world.gen2.Map")
    if not (okM and Map and self.map and self.maps and self.player) then return false end
    local key=({up="north",down="south",left="west",right="east"})[dir]
    local conn=key and self.map.connection and self.map:connection(key)
    local target=conn and (conn.mapId or (type(conn.map)=="string" and conn.map))
    local dest=target and self.maps[target]
    if not (conn and dest and type(Map.connectionLanding)=="function") then return false end
    -- Physical free flight is not fast travel: crossing a connected map edge
    -- should load the destination whether or not the player has visited it
    -- before. Older builds incorrectly treated session/save discovery history
    -- as an airspace lock and blocked unexplored connected routes.
    local x,y=Map.connectionLanding(dest,conn,dir,self.player.cellX,self.player.cellY)
    if not (x and y and type(self.setMap)=="function") then return false end
    local d=Map.DELTA and Map.DELTA[dir]; if not d then return false end
    local loaded=self:setMap(target,x,y,dir,{seamless=true}); if not loaded then return false end
    -- setMap's CheckUpdatePlayerSprite may have selected SURF/BIKE from the
    -- destination edge.  That state is only meaningful to Gold's ground
    -- locomotion; free flight remains NORMAL and keeps the selected 3D trainer.
    pcall(preserveFlightPlayerPresentation, self)
    local p=self.player; p.cellX,p.cellY=x-d[1],y-d[2]; p.px,p.py=p.cellX*16,p.cellY*16
    p.facing=dir; p.targetX,p.targetY=x,y; p.moving,p.progress=true,0; p.inGrass=false; p.grassShake=nil
    pcall(syncRider, self)
    return true
  end end)
end

-- Internal regression seams used by the packaged smoke tests.  They expose no
-- new player-facing API and keep the actual runtime functions as the single
-- implementation under test.
M._debugFlightSteeringOwned = flightSteeringOwned
M._debugSampleFlightIntent = sampleFlightIntent
M._debugContinuousFlight = continuousFlight
M._debugInstallGuards = installGuards

local function reverseLedge(world,dir)
  if not (state.mode=="ground" and on("mountTwoWayLedges",true)) then return false end
  local okM,Map=pcall(require,"src.world.gen2.Map")
  local okP,Permissions=pcall(require,"src.world.gen2.Permissions")
  if not (okM and okP and Map and Permissions and world and world.map and world.player) then return false end
  local d=Map.DELTA and Map.DELTA[dir]; if not d then return false end
  local opposite={up="down",down="up",left="right",right="left"}
  local p,m=world.player,world.map; local x=p.cellX+d[1]*2; local y=p.cellY+d[2]*2
  if not (m:inBounds(x,y) and m:isWalkable(x,y)) then return false end
  if m.isWaterCell and m:isWaterCell(x,y) then return false end
  local c=m.cellCollision and m:cellCollision(x,y); local facings=c and Permissions.ledgeFacings(c)
  if not (facings and facings[opposite[dir]]) then return false end
  p.targetX,p.targetY=x,y; p.moving,p.jumping=true,true; p.progress=0; p.inGrass=false; p.grassShake=nil
  return true
end
local ledgeWorld,ledgeRaw,ledgeNative
local function syncLedge(world)
  if ledgeWorld==world then return end
  if ledgeWorld and ledgeRaw~=nil then rawset(ledgeWorld,"tryLedgeJump",ledgeRaw==false and nil or ledgeRaw) end
  ledgeWorld,ledgeRaw,ledgeNative=nil,nil,nil
  if not world or type(world.tryLedgeJump)~="function" then return end
  ledgeWorld=world; ledgeRaw=rawget(world,"tryLedgeJump") or false; ledgeNative=world.tryLedgeJump
  rawset(world,"tryLedgeJump",function(self,dir,...)
    if ledgeNative(self,dir,...) then return true end
    return reverseLedge(self,dir)
  end)
end

isHeld = function(key)
  local kb=love and love.keyboard
  if not (kb and type(kb.isDown)=="function") then return false end
  local ok,v=pcall(kb.isDown,key); return ok and v==true
end
local function padAxis(axis)
  local j=love and love.joystick
  if not (j and type(j.getJoysticks)=="function") then return 0 end
  local ok,list=pcall(j.getJoysticks); if not ok then return 0 end
  for _,js in ipairs(list or {}) do
    if js.isGamepad and js:isGamepad() and js.getGamepadAxis then
      local okA,v=pcall(js.getGamepadAxis,js,axis); if okA and math.abs(v or 0)>.05 then return v or 0 end
    end
  end
  return 0
end
local function updateAltitude(dt)
  if state.mode~="flight" or not on("mountManualAltitude",true) then return end
  local dir=0
  if isHeld("pageup") then dir=dir+1 end; if isHeld("pagedown") then dir=dir-1 end
  dir=dir + math.max(0,padAxis("triggerright")) - math.max(0,padAxis("triggerleft"))
  local rate=({slow=22,normal=38,fast=62})[tostring(opt("mountVerticalSpeed","normal"))] or 38
  state.targetAltitude=math.max(8,math.min(96,state.targetAltitude+dir*rate*dt))
  state.altitude=state.altitude+(state.targetAltitude-state.altitude)*math.min(1,dt*8)
end
local function updateGallop(dt)
  if state.mode~="ground" or not on("mountGroundGallop",true) then state.gallop=math.min(1,state.gallop+dt*.45); return end
  local boosting=isHeld("lshift") or isHeld("rshift")
  if boosting and state.gallop>0 then state.gallop=math.max(0,state.gallop-dt*.28) else state.gallop=math.min(1,state.gallop+dt*.22) end
end
local function speedFrames(mode)
  local pct=(mode=="flight") and num("mountFlightSpeed",100) or num("mountGroundSpeed",100)
  if mode=="flight" and on("mountFlightBoost",true) and (isHeld("lshift") or isHeld("rshift")) then pct=pct*1.45 end
  if mode=="ground" and on("mountGroundGallop",true) and (isHeld("lshift") or isHeld("rshift")) and state.gallop>0 then pct=pct*1.4 end
  return math.max(3,math.floor(16*100/math.max(50,math.min(260,pct))+.5))
end

local function airEncounterTick(world)
  if state.mode~="flight" or not on("mountAirEncounters",false) then return end
  local wild=V and V.wilds; local logic=wild and wild.logic
  if not (logic and type(logic.spawns)=="table" and type(logic.entities)=="table" and type(logic._startBattle)=="function") then return end
  state.airCooldown=(state.airCooldown or 0)-1; if state.airCooldown>0 then return end
  state.airCooldown=30
  local p=world.player
  for id,rec in pairs(logic.spawns) do
    local e=logic.entities[id]
    if e and rec and rec.state and e.px and e.py then
      local dx=(e.px-p.px)/16; local dy=(e.py-p.py)/16
      if dx*dx+dy*dy<=1.2 then
        M.dismount(true); pcall(logic._startBattle,logic,rec); return
      end
    end
  end
end

local function syncFollowers(world)
  if not world then return end
  local mounted = visualMode(world) ~= nil
  local hide = mounted and not on("mountShowFollowers", false)
  local function one(e)
    if type(e) ~= "table" or e == world.player or e == state.mountEntity then return end
    local isFollower = e.wildsFollower == true or e.isPokemonFollower == true
      or e.pokepcTrailer == true or e._wildsFollowerSpecies ~= nil
      or e._pokepcFollowerSpecies ~= nil
    if not isFollower then return end
    if hide then
      if e._flyYourPokemonPrevVisible == nil then
        e._flyYourPokemonPrevVisible = (e.visibleSprite == nil) and "nil" or e.visibleSprite
      end
      e.visibleSprite = false
      e._flyYourPokemonHiddenFollower = true
    elseif e._flyYourPokemonHiddenFollower then
      local prev = e._flyYourPokemonPrevVisible
      e.visibleSprite = prev == "nil" and nil or prev
      e._flyYourPokemonPrevVisible = nil
      e._flyYourPokemonHiddenFollower = nil
    end
  end
  for _, e in ipairs(world.entities or {}) do one(e) end
  for _, e in ipairs(world.npcs or {}) do one(e) end
end

local function tickPlayer(player)
  local world=liveWorld(); if not (world and world.player==player) then return end
  state.world=world; state.flightClock=state.flightClock+1/60
  if state.pendingFlight and on("mountFlightMode", false) and state.mode ~= "flight" and not busy(world) then
    state.pendingFlight=false
    pcall(M.startFlight, liveGame())
  end
  if state.noticeTimer>0 then state.noticeTimer=math.max(0,state.noticeTimer-1/60) end
  if state.pendingPostLandCleanup and state.mode ~= "flight" then
    state.pendingPostLandCleanup=false
    -- Presentation cleanup happens from the ordinary player-update path, not
    -- from the controller/input transition. These are all optional and guarded.
    pcall(restoreYOffset)
    pcall(flightMusicRestore, world)
  end
  updateAltitude(1/60); updateGallop(1/60)
  if state.mode=="ground" and state.species=="SUICUNE" and world.map and world.map.isWaterCell then
    local ok,v=pcall(world.map.isWaterCell,world.map,player.cellX,player.cellY); state.amphibiousWater=ok and v==true or false
  else state.amphibiousWater=false end
  -- Free-camera flight movement is driven once from the guarded World:stepBody
  -- tail, where GoldCameraControls has already sampled this tick's stick.  Do
  -- not move again from Player:update or flight speed doubles / depends on
  -- whether Gold happened to animate Player this frame.
  if state.mode=="flight" then
    installGuards(world)
    pcall(preserveFlightPlayerPresentation, world)
  else
    resetFreePosition()
  end
  normalizeSurfExit(world, player)
  syncLedge(world)
  if visualMode(world) then ensureMountEntity(world) else state.mountRenderActive=false end
  syncRider(world); syncFollowers(world); airEncounterTick(world)
end

local function drawMount2D(player,ox,oy,scale)
  local world=state.world; local mode,species=visibleChoice(world)
  if not (mode and species) then return false end
  local surface=mode=="surf" and "water" or (state.amphibiousWater and "water" or "land")
  local sprite=resolveSprite(species,surface); if not sprite then return false end
  local G=love.graphics; local s=sizeScale(species); local lift=altitudeLift()
  local phase=(mode=="flight") and (math.floor(state.flightClock*5)%2) or ((player.walkPhase and player:walkPhase()) or 0)
  G.push(); G.translate(tonumber(ox) or 0,tonumber(oy) or 0); G.scale(tonumber(scale) or 1,tonumber(scale) or 1)
  if mode=="ground" and on("mountGroundDust",true) and player.moving then
    G.setColor(0.35,0.28,0.18,0.35)
    G.circle("fill",player.px+5,player.py+13,2.2)
    G.circle("fill",player.px+11,player.py+14,1.6)
  elseif mode=="flight" and on("mountLandingMarker",true) and lift>8 then
    G.setColor(1,1,1,0.28); G.ellipse("line",player.px+8,player.py+14,5,2)
  end
  local ax,ay=player.px+8,player.py+12-lift
  G.translate(ax,ay); G.scale(s,s); G.translate(-ax,-ay)
  G.setColor(1,1,1,1); sprite:draw(player.px,player.py-lift,0,0,player.facing,phase,player.stepFlip==true)
  G.pop()
  return true
end

local function installCameraBridge()
  local ok,FP=pcall(V.require,"FirstPerson")
  if not (ok and FP and type(FP.frame)=="function") then return false end
  if FP._flyYourPokemonCameraBridge then return true end
  local native=FP.frame
  FP.frame=function(me,...)
    if state.mode=="flight" and not on("mountCameraAltitude",true) and type(me)=="table" then
      local copy={}
      for k,v in pairs(me) do copy[k]=v end
      copy.lift=(tonumber(copy.lift) or 0)-altitudeLift()
      return native(copy,...)
    end
    return native(me,...)
  end
  FP._flyYourPokemonCameraBridge=true
  return true
end

local function installPlayerPatch()
  local okP,Player=pcall(require,"src.world.gen2.Player")
  if not (okP and type(Player)=="table") then return false,"Gold Player unavailable" end
  if Player._flyYourPokemonPatched then return true end
  if type(Player.tryMove)=="function" then
    local native=Player.tryMove
    Player.tryMove=function(self,dir,map,entities,...)
      local result=native(self,dir,map,entities,...)
      if result=="moved" and state.world and state.world.player==self and state.mode then self.stepFrames=speedFrames(state.mode) end
      return result
    end
  end
  if type(Player.update)=="function" then
    local native=Player.update
    Player.update=function(self,...)
      local r=native(self,...); pcall(tickPlayer,self); return r
    end
  end
  if type(Player.draw)=="function" then
    local native=Player.draw
    Player.draw=function(self,ox,oy,scale,...)
      if state.world and state.world.player==self and visualMode(state.world) then
        drawMount2D(self,ox,oy,scale)
        if self._flyYourPokemonHideRider then return end
      end
      return native(self,ox,oy,scale,...)
    end
  end
  Player._flyYourPokemonPatched=true
  return true
end

local function installInput(game)
  -- Keyboard-only wrapper.  v0.3.12 deliberately does NOT wrap
  -- Game2:gamepadpressed/gamepadreleased anymore.  This mod already has other
  -- controller owners (CamControl, BattleControllerUI, PerformanceRuntime and
  -- Gold itself); stacking another instance callback around all of them made
  -- airborne face-button ownership depend on wrapper order / stack state.
  -- Controller mount input is now polled/quarantined at input.step below.
  if not game or game._flyYourPokemonKeyboardInputV312 then return true end
  local kp=game.keypressed
  game.keypressed=function(self,key,...)
    local k=type(key)=="string" and key:lower() or key
    if freeOverworldInput(self) then
      if on("mountShortcut",true) and k=="h" then
        local fn = state.mode == "flight" and requestLanding or M.toggleFlight
        local ok, handled = pcall(fn, self)
        if ok and handled then return end
        if not ok then logInputError(k, handled) end
      elseif on("mountShortcut",true) and (k=="g" or k=="j") then
        local ok, handled = pcall(M.toggleGround, self)
        if ok and handled then return end
        if not ok then logInputError(k, handled) end
      elseif k=="m" and on("mountMenu",true) then
        local ok, handled = pcall(M.cycleMount, state.mode or "flight", 1)
        if ok and handled then return end
        if not ok then logInputError(k, handled) end
      end
    end
    if kp then return kp(self,key,...) end
  end
  game._flyYourPokemonKeyboardInputV312=true
  return true
end

local BLOCKED_FLIGHT_ACTIONS = { a=true, b=true, start=true, select=true }

local function clearAction(input, action)
  if type(input) ~= "table" then return end
  local q = input.pressQueue
  if type(q) == "table" then
    for i=#q,1,-1 do
      if q[i] == action then table.remove(q, i) end
    end
  end
  if type(input.pressed) == "table" then input.pressed[action] = nil end
  if type(input.state) == "table" then input.state[action] = false end
  if type(input.sources) == "table" then input.sources[action] = nil end
end

local function queued(input, action)
  local q = input and input.pressQueue
  if type(q) ~= "table" then return false end
  for i=1,#q do if q[i] == action then return true end end
  return false
end

local function hasControllerSource(input, action)
  local sources = input and input.sources and input.sources[action]
  if type(sources) ~= "table" then return false end
  for source in pairs(sources) do
    if type(source)=="string" and (source:sub(1,4)=="pad:" or source:sub(1,4)=="joy:") then
      return true
    end
  end
  return false
end

local function controllerDown(button)
  local J = love and love.joystick
  if not (button and J and type(J.getJoysticks)=="function") then return false end
  local okList, list = pcall(J.getJoysticks)
  if not okList or type(list) ~= "table" then return false end
  for _, js in ipairs(list) do
    local okPad, mapped = pcall(function()
      return js and type(js.isGamepad)=="function" and js:isGamepad()
    end)
    if okPad and mapped and type(js.isGamepadDown)=="function" then
      local okDown, down = pcall(js.isGamepadDown, js, button)
      if okDown and down then return true end
    end
  end
  return false
end

local function pollControllerMountEdges(game)
  -- While airborne, do not call love.joystick:getJoysticks/isGamepadDown at
  -- all. LAND comes solely from Gold's queued logical B edge below. This makes
  -- the flight frame use the engine's normal event stream and avoids extra
  -- native SDL polling while any face button is held.
  if state.mode == "flight" then return end
  local poll = state.padPoll
  local nowFlight = controllerDown("x")
  local nowGround = controllerDown("y")

  if freeOverworldInput(game) and on("mountControllerShortcuts", false) then
    if nowFlight and not poll.flight then
      local ok, err = pcall(M.toggleFlight, game)
      if not ok then logInputError("FLIGHT-POLL", err) end
    elseif nowGround and not poll.ground then
      local ok, err = pcall(M.toggleGround, game)
      if not ok then logInputError("GROUND-POLL", err) end
    end
  end

  poll.flight, poll.ground = nowFlight, nowGround
end

local function quarantineFlightControllerInput(game)
  game = game or liveGame()
  if not game then return false end
  pcall(pollControllerMountEdges, game)
  if state.mode ~= "flight" then return false end

  -- Hard quarantine at the engine's fixed-step seam.  This runs immediately
  -- before Input:step promotes queued device edges, so it is independent of
  -- Game2 callback wrapper order, transparent UI states, camera ownership and
  -- BattleControllerUI.  A/B/START/SELECT cannot become Gold actions while
  -- airborne.  D-pad/left stick remain untouched for movement; trigger axes
  -- remain untouched for altitude.
  local input = game.input
  if type(input) ~= "table" then return false end
  local hadA, hadB, hadStart, hadSelect = queued(input,"a"), queued(input,"b"), queued(input,"start"), queued(input,"select")
  if hadB and hasControllerSource(input, "b") and not state.pendingLand then
    local ok, err = pcall(requestLanding, game)
    if not ok then logInputError("LAND-QUEUE", err) end
  end
  if hadA or hadB or hadStart or hadSelect then
    state.controllerBlockedEdges = (state.controllerBlockedEdges or 0) + 1
  end
  for action in pairs(BLOCKED_FLIGHT_ACTIONS) do clearAction(input, action) end
  state.controllerQuarantinePasses = (state.controllerQuarantinePasses or 0) + 1
  -- LAND is committed here, before Input:step and before Gold begins this
  -- logic frame's world/entity iteration.  The physical B/Circle edge has
  -- already been scrubbed, so the same press can never become a Gold action.
  if state.pendingLand then
    local okLand, errLand = pcall(processPendingLanding)
    if not okLand then logInputError("LAND-PRESTEP", errLand) end
  end
  return true
end

local function installControllerQuarantine()
  if state.controllerQuarantineInstalled then return true end
  if not (mod and mod.hooks and type(mod.hooks.wrap)=="function") then
    return false, "input.step hook unavailable"
  end
  local ok, err = pcall(mod.hooks.wrap, mod.hooks, "input.step",
    function(nextFn, game, dt)
      -- Scrub once before other input-step hooks and once after them.  The
      -- second pass catches a hook that injects a synthetic A/B edge.  Calling
      -- nextFn in between preserves camera/capture polling and every non-face
      -- input consumer.
      pcall(quarantineFlightControllerInput, game)
      local a,b,c = nextFn(game, dt)
      pcall(quarantineFlightControllerInput, game)
      return a,b,c
    end, 100000)
  if not ok then return false, tostring(err) end
  state.controllerQuarantineInstalled=true
  return true
end


local function removeLegacyLoveGamepadGuard()
  -- v0.3.12 installed a global LOVE bridge. On hot reload, do not rewrite the
  -- host callback again (another mod may now be outside it); simply neuter the
  -- bridge's flight handlers. Its old wrapper then becomes a transparent
  -- pass-through to the native callback. A full process restart removes it.
  local L=love
  local bridge=L and L._flyYourPokemonGamepadBridge
  if type(bridge)=="table" then
    bridge.press=nil
    bridge.release=nil
  end
  state.loveBlockedButtons={}
  state.loveGamepadGuardInstalled=false
  return true
end

local function controllerFaceLabel(role, fallback)
  local C = mod and mod.exports and mod.exports.controllerLayout
  if C and type(C.face) == "function" then
    local ok, spec = pcall(C.face, role)
    if ok and type(spec) == "table" and spec.label then return tostring(spec.label) end
  end
  return fallback
end

local function drawOverlay()
  local world=state.world; local mode=visualMode(world)
  if not mode then return end
  local G=love and love.graphics; if not G then return end
  local showAlt=opt("mountAltitudeDisplay","flight")
  local parts={}
  if state.noticeTimer>0 and state.notice then parts[#parts+1]=state.notice end
  if mode=="flight" and (showAlt=="always" or showAlt=="flight") then parts[#parts+1]=("ALT %d"):format(math.floor(state.altitude+.5)) end
  if mode=="ground" and on("mountGallopHud",true) then parts[#parts+1]=("GALLOP %d%%"):format(math.floor(state.gallop*100+.5)) end
  if on("mountHints",true) and #parts==0 then
    local controllerShortcuts = on("mountControllerShortcuts",false)
    local flightPad = controllerFaceLabel("west", "X")
    local groundPad = controllerFaceLabel("north", "Y")
    local C = mod and mod.exports and mod.exports.controllerLayout
    local landLabel = "B"
    if C and type(C.cancelLabel)=="function" then
      local okL, got = pcall(C.cancelLabel)
      if okL and got then landLabel=tostring(got) end
    end
    local flightControl = controllerShortcuts and ("H/"..flightPad) or "H"
    local groundControl = controllerShortcuts and ("G/"..groundPad) or "G"
    parts[#parts+1]=(mode=="flight" and (landLabel.."/H LAND  PGUP/PGDN ALT  SHIFT BOOST")
      or mode=="ground" and (groundControl.." DISMOUNT  SHIFT GALLOP") or "VISIBLE SURF")
  end
  if #parts==0 then return end
  local text=table.concat(parts,"   ")
  local w,h=G.getDimensions(); local font=G.getFont(); local tw=font and font:getWidth(text) or #text*7
  G.push("all"); G.setColor(0,0,0,.58); G.rectangle("fill",math.max(8,(w-tw)/2-8),12,tw+16,26,5,5)
  G.setColor(1,1,1,1); G.print(text,math.max(16,(w-tw)/2),18); G.pop()
end
local function installOverlay()
  if not (mod and mod.hooks and type(mod.hooks.wrap)=="function") then return false end
  local ok=pcall(function()
    mod.hooks:wrap("render.compose",function(nextFn,host,ctx)
      local a,b,c=nextFn(host,ctx); pcall(drawOverlay); return a,b,c
    end,1400)
  end)
  return ok
end

local function installCollision()
  if not (mod and mod.hooks and type(mod.hooks.wrap)=="function") then return false end
  local ok=pcall(function()
    mod.hooks:wrap("movement.collision",function(nextFn,allowed,ctx)
      local w=state.world or liveWorld()
      if not (ctx and w and ctx.mover==w.player) then return nextFn(allowed,ctx) end
      if state.mode=="flight" and allowed==false and ctx.reason~="bounds" then return nextFn(true,ctx) end
      if state.mode=="ground" and state.species=="SUICUNE" and allowed==false and ctx.reason=="tile"
         and surfProgress(liveGame(),nil) and ctx.map and type(ctx.map.isWaterCell)=="function" then
        local okW,isWater=pcall(ctx.map.isWaterCell,ctx.map,ctx.toX,ctx.toY)
        if okW and isWater then state.amphibiousWater=true; return nextFn(true,ctx) end
      end
      return nextFn(allowed,ctx)
    end,125)
  end)
  return ok
end

local function applyPreferredFlightPokemon(game)
  game = game or liveGame()
  if state.mode ~= "flight" then return true end
  local e = choose(game, "flight")
  if not e then
    local preferred = preferredFlightSpecies()
    notice((preferred and preferred:gsub("_", "-") or "FLYING POKEMON") .. " NOT ELIGIBLE")
    return false
  end
  if state.species ~= e.species or state.slot ~= e.slot then
    state.species, state.slot, state.mountSprite = e.species, e.slot, nil
    playCry(e.species)
    notice("NOW FLYING " .. e.species:gsub("_", "-"))
  end
  return true
end

local function purgeLegacyGameplayCarrier(world)
  -- v0.3.08-v0.3.10 inserted the presentation carrier into Gold's live
  -- gameplay entity array.  A normal restart recreates the world and loses it,
  -- but hot reload / CONTINUE can keep an older carrier table alive.  Session
  -- reset is outside the entity-iteration hot path, so this is the one safe
  -- place to remove those legacy synthetic entries before any interaction.
  if not (world and type(world.entities) == "table") then return 0 end
  local removed = 0
  for i = #world.entities, 1, -1 do
    local e = world.entities[i]
    if type(e) == "table" and (e == state.mountEntity
        or e.id == "fly_your_pokemon_mount"
        or e.flyYourPokemonMount == true or e._flyYourPokemonMount == true) then
      table.remove(world.entities, i)
      removed = removed + 1
    end
  end
  return removed
end

local function resetSessionFlight(game)
  if state.resettingSession then return true end
  state.resettingSession=true
  local w=state.world or liveWorld(game)
  if w and w.player then w.player._flyYourPokemonFlight3D = nil end
  pcall(purgeLegacyGameplayCarrier, w)
  if state.mode=="flight" then flightMusicRestore(w) end
  state.mode=nil; state.species=nil; state.slot=nil
  state.altitude=0; state.targetAltitude=0; state.pendingFlight=false
  state.pendingLand=false; state.pendingLandGame=nil
  state.pendingPostLandCleanup=false
  state.amphibiousWater=false; state.suppressStoredFlight=true
  state.mountRenderActive=false
  state.loveBlockedButtons={}
  resetFreePosition(); restoreGuards()
  restoreYOffset()
  -- FLY is an action/state indicator, not a boot preference. A crash can leave
  -- the persisted option at ON, so every fresh game/save load explicitly
  -- clears it before mount reconciliation is allowed.
  setFlightOption(false, game)
  state.resettingSession=false
  return true
end

local function reconcileFlightOption(game)
  game = game or liveGame()
  if not state.sessionReady or state.suppressStoredFlight then
    if on("mountFlightMode", false) then setFlightOption(false, game) end
    return true
  end
  if on("mountFlightMode", false) then
    if state.mode == "flight" then
      state.pendingFlight=false
      return applyPreferredFlightPokemon(game)
    end
    if state.mode ~= nil then M.dismount(true) end
    state.pendingFlight=true
    return M.startFlight(game)
  elseif state.mode == "flight" then
    -- Mod Settings FLY=OFF uses the same deferred request as controller LAND.
    -- The next input.step commits it before world iteration.
    return requestLanding(game)
  end
  return true
end

function M.sync(game)
  game=game or liveGame(); if not game then return false end
  installInput(game); local w=liveWorld(game)
  if w then
    state.world=w
    local id=w.map and w.map.id; if id then state.reachedMaps[id]=true end
    pcall(reconcileFlightOption, game)
    if state.mode == "flight" then pcall(preserveFlightPlayerPresentation, w) end
    if visualMode(w) then ensureMountEntity(w) else state.mountRenderActive=false end
    syncRider(w); syncLedge(w)
  end
  return true
end
function M.status()
  return {installed=M.installed,mode=state.mode,species=state.species,slot=state.slot,
    altitude=state.altitude,gallop=state.gallop,amphibiousWater=state.amphibiousWater,
    reachedMaps=state.reachedMaps,controllerQuarantine=state.controllerQuarantineInstalled,
    loveGamepadGuard=false,mountRenderActive=state.mountRenderActive==true,
    controllerQuarantinePasses=state.controllerQuarantinePasses,
    controllerBlockedEdges=state.controllerBlockedEdges,
    flightIntentX=state.flightIntentX,flightIntentZ=state.flightIntentZ,
    flightIntentFresh=state.flightIntentFresh}
end
function M.install()
  if M.installed then return true end
  local ok,err=installPlayerPatch(); if not ok then return false,err end
  disableLegacyLandingTail()
  removeLegacyLoveGamepadGuard()
  installControllerQuarantine()
  installCameraBridge(); installCollision(); installOverlay()
  if mod and mod.events then
    mod.events:on("game.ready",function(game)
      pcall(resetSessionFlight, game)
      state.sessionReady=true
      pcall(M.sync,game)
    end)
    mod.events:on("map.entered",function(ev)
      local w=liveWorld(); if w and w.map and w.map.id then state.reachedMaps[w.map.id]=true end
      pcall(M.sync,liveGame())
    end)
    mod.events:on("save.loaded",function()
      local game=liveGame()
      pcall(resetSessionFlight, game)
      state.sessionReady=true
      pcall(M.sync,game)
    end)
    mod.events:on("mod.options_changed", function(payload)
      if not payload or payload.mod ~= mod.id then return end
      if payload.key == "mountFlightMode" then
        state.suppressStoredFlight=false
        pcall(reconcileFlightOption, liveGame())
      elseif payload.key == "mountFlightPokemon" then
        if state.mode == "flight" then
          pcall(applyPreferredFlightPokemon, liveGame())
        elseif on("mountFlightMode", false) then
          state.pendingFlight=true
          pcall(reconcileFlightOption, liveGame())
        end
      end
    end)
    mod.events:on("battle.ended",function()
      if state.mode=="ground" and not on("mountRemountAfterBattle",true) then
        pcall(M.dismount,true)
      else
        pcall(M.sync,liveGame())
      end
    end)
  end
  M.installed=true
  local live=liveGame()
  if live then
    -- During normal boot the loader is still constructing game.mods here, so
    -- game.ready must be the point that arms persisted option reconciliation.
    -- On an actual hot reload game.mods already exists and we can reset safely.
    if live.mods ~= nil then
      pcall(resetSessionFlight, live)
      state.sessionReady=true
      pcall(M.sync, live)
    else
      installInput(live)
    end
  end
  return true
end

M.FLIGHT_ROSTER=FLIGHT; M.GROUND_ROSTER=GROUND; M.SURF_ROSTER=SURF; M.ALL_MOUNTS=ALL
return M
