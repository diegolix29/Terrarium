-- lib/ColosseumBattleMon.lua
--
-- COLOSSEUM A/B battles: one Pokemon, standing on its tile, played by the
-- same Colosseum (GC6E01) actor service the overworld's Colosseum spawns,
-- roamers, followers and player model already use (lib/PokemonActors.lua,
-- reached through lib/ColosseumMon.lua's sibling bridge).
--
-- ------- why this file exists
--
-- Stadium.lua's `session.player` / `session.enemy` have always been
-- StadiumMon instances, backed by StadiumPack -- i.e. by a Pokemon Stadium
-- ROM import. That is correct for the STADIUM A/B rungs. It was ALSO,
-- silently, what ran for the COLOSSEUM A/B rungs: Stadium.mode() and
-- Stadium.enabled() have known about "COLOSSEUM_A"/"COLOSSEUM_B" since they
-- were added to OverworldBattle's ladder (see Stadium.enabled's
-- Voxel3D-only gate for those two), but Stadium.begin() never branched on
-- that and always built a StadiumMon -- which, with no Stadium ROM
-- imported, declines every species and leaves the fight standing on its
-- flat GB pics. The world/void ambient swap (Stadium.discs, driven by
-- OverworldBattle) still worked, because that path never touched
-- StadiumMon at all, which is what made the bug read as "the mode is
-- selected but nothing changes".
--
-- This class is the missing branch: a second implementation of exactly the
-- surface Stadium.lua calls on session.player/session.enemy (see StadiumMon
-- for the canonical list -- new, release, setSpecies, request, play,
-- attack, update, beginGrow, growScale, finished, worldHeight, worldRadius,
-- bodySpan, groundGap, matrix, build -- plus the handful of PLAIN FIELDS
-- Stadium.lua reads directly: species, shiny, model, rig, visible, scale,
-- grow, grewOwn, state, model_matrix), backed by PokemonActors' Actor
-- instead of StadiumPack/StadiumRig.
--
-- ------- what is reused, and what is new
--
-- PokemonActors' Actor (lib/PokemonActors.lua) already turned out to be a
-- genuine battle actor, not merely an overworld one: it carries its own
-- spawn/idle/attack/hit/faint/recall state machine, a move-aware native
-- slot resolver (Actor:attack picks specialA/physicalA off the move's
-- type), and a matrix() that already bakes in spawn scale, attack lunge,
-- hit kick, faint collapse and floor clamping. lib/ColosseumMon.lua (the
-- overworld adapter) proved the acquire -> matrix -> draw pipeline and,
-- importantly, its own comment on M.figureScale says the service's default
-- figureScale ALREADY calibrates a mid-size Pokemon to roughly the 14 world
-- pixels StadiumMon.REF_HEIGHT uses -- i.e. actor.height*actor.worldScale
-- comes out in the SAME world-pixel unit space Stadium.lua's cell
-- coordinates are already in, with no extra conversion. That is what makes
-- reusing PokemonActors here safe rather than a second guess at a unit
-- system.
--
-- What ColosseumMon.lua does NOT cover is a battle lifecycle: no send-out
-- grow, no move-triggered attack slot, no faint hold. Every acquired Actor
-- is otherwise independent (PokemonActors.acquire hands back a FRESH Actor
-- per call -- only the mesh/texture "scene" underneath is shared -- and
-- Actor:release "must not free the shared scene", per its own comment), so
-- one battle side driving its own Actor's state (spawn/attack/faint) cannot
-- bleed into an overworld Pokemon of the same species, or into the other
-- side of the same fight.
--
-- ------- known gaps against STADIUM A/B (v1)
--
-- * Attacks play the retail-accurate native slot when the extracted WZX
--   move data covers this move (see retailNativeSlot below -- the exact
--   MoveFXExtractor -> WazaPhasePolicy -> CurrentSpriteModels pipeline
--   lib/doubles/MovePresentation.lua already drives for the full Colosseum
--   battle screen, reused rather than reimplemented). Not every move is
--   covered by that extraction yet (see MoveFXExtractor's own curated
--   tables); an uncovered move falls back to Actor's own moveSlot(), the
--   type-based physicalA/specialA split retail itself falls back to for
--   the same case (see PKX_SLOT_BY_INDEX's comment in CurrentSpriteModels).
-- * Colosseum's native slot set (see PokemonActors' NATIVE_FALLBACKS) has
--   no distinct "entrance" bank the way Stadium's context table does,
--   so a send-out grows into the idle loop rather than a unique arrival
--   pose -- see :play() below.
-- * No shadow-cast entry point exists on Actor yet, so Colosseum-mode
--   battlers cast no shadow (Stadium.cast's guard makes that a silent
--   no-op, never a crash).
-- * worldRadius() is a flat fraction of worldHeight() (the same 0.4 ratio
--   Stadium.captureBody already falls back to for a Stadium model with no
--   measured radius), because Actor does not expose a measured footprint.
-- * bodySpan() returns nil (no posed-bounds query on Actor), so
--   Stadium.captureBody's capture-ring sizing falls back to its own
--   height/radius estimate instead of the exact posed silhouette a flying
--   Pokemon would give StadiumMon.
-- * The Let's Go capture "pull into the ball" swirl (Stadium.draw's `pull`
--   argument) has no Actor-level equivalent; the SHRINK itself still
--   applies (mon.scale still drives the actor's spawnScale), only the
--   extra distortion is not reproduced.
--
-- None of these are crashes -- each is a graceful "slightly less specific
-- than Stadium" answer, in keeping with Stadium.lua's own per-Pokemon
-- decline philosophy (see its header).

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Dex = V.require("ColosseumDex")
local Voxel3D = V.require("Voxel3D")
-- Borrowed rather than duplicated, so a future retune of REF_HEIGHT/
-- MIN_HEIGHT/MAX_HEIGHT/GROW_TIME for STADIUM automatically keeps this mode
-- pacing- and scale-matched to it instead of quietly drifting apart.
local StadiumMon = V.require("StadiumMon")
-- The retail-accurate per-move native-slot pipeline (see retailNativeSlot
-- below). Both are ordinary lib/ modules; V.MoveFXExtractor, the third leg
-- of that pipeline, is not -- see retailNativeSlot for why it is read
-- differently.
local WazaPhasePolicy = V.require("WazaPhasePolicy")
local CurrentSpriteModels = V.require("CurrentSpriteModels")

local ColosseumBattleMon = {}
ColosseumBattleMon.__index = ColosseumBattleMon

local function game()
  return require("src.core.Game")
end

local function service()
  local mod = V.mod
  return mod and mod.exports and mod.exports.pokemonActorsOverworld
end

-- The move def a request's moveIndex resolves to, straight off the
-- engine's own move table -- used only as a last resort when a caller
-- didn't already have a moveDef to hand (Stadium.lua's own hook does, and
-- passes it straight through -- see Stadium.lua's performMove hook).
local function moveDefFor(moveIndex)
  if not moveIndex then return nil end
  local ok, g = pcall(game)
  local data = ok and g and g.data
  return data and data.moves and data.moves[moveIndex] or nil
end

-- The native action slot the SOURCE Colosseum game itself plays for this
-- move, straight from its own extracted WZX sequence data. This is not a
-- guess: lib/CurrentSpriteModels.lua's own comment on PKX_SLOT_BY_INDEX
-- says plainly that "the WZX sequence itself selects the body slot; move
-- type is only a legacy fallback for caches that predate the typed Waza
-- root" -- and lib/doubles/MovePresentation.lua, the presentation for the
-- separate full Colosseum battle screen, already drives exactly this
-- MoveFXExtractor.peek -> WazaPhasePolicy.select -> CurrentSpriteModels:
-- sourceNativeSlot pipeline for its own battlers. This reuses that same
-- pipeline rather than reimplementing it, so a move that has retail WZX
-- data gets the exact clip the real game plays it with; a move that
-- doesn't returns nil here and Actor:attack's own opts.nativeSlot-or-
-- moveSlot(moveDef) fallback picks the type-based physicalA/specialA
-- split instead -- the same fallback retail itself falls back to.
--
-- V.MoveFXExtractor lives under extract/, not lib/, so main.lua attaches
-- it onto V directly once the Colosseum disc integration has run, rather
-- than through V.require (which only ever looks under lib/) -- read as a
-- plain field and nil-checked here for exactly that reason, the same way
-- MovePresentation.lua reads it.
local function retailNativeSlot(moveIndex, moveDef, dex)
  local Extractor = V.MoveFXExtractor
  if not (Extractor and type(Extractor.peek) == "function"
          and WazaPhasePolicy and CurrentSpriteModels and dex) then
    return nil
  end
  local okPeek, spec = pcall(Extractor.peek, moveIndex, moveDef)
  if not (okPeek and spec) then return nil end
  local okSel, selected = pcall(WazaPhasePolicy.select, spec,
                                 { dex = dex, stage = "attack" })
  if not (okSel and selected) then return nil end
  local okSlot, slot = pcall(CurrentSpriteModels.sourceNativeSlot,
                              CurrentSpriteModels, selected, "attack")
  if not okSlot then return nil end
  return slot
end

-- ------- the rig shim
--
-- Stadium.lua's draw/cast/covers/guard code only ever touches session.
-- player/enemy's `.rig` field for its truthiness (a model is loaded) and,
-- when drawing, `mon.rig:draw(matrix, pull)` / `mon.rig:caster(shadowMap,
-- matrix)` -- see Stadium.draw/Stadium.cast. Handing back a tiny shim with
-- just those two methods means Stadium.lua's draw/cast pass needs no
-- Colosseum-specific branch of its own; it keeps calling `mon.rig:draw`
-- exactly as it always has, and this is what answers.
local function makeRig(mon)
  local rig = {}
  function rig:draw(matrix, pull) -- luacheck: ignore pull (see the header)
    local actor = mon.actor
    if not (actor and matrix) then return false end
    local svc = service()
    local vp = Voxel3D.vp
    if not (svc and vp and type(svc.withRenderer) == "function") then
      return false
    end
    local ok, accepted = pcall(svc.withRenderer, vp, function()
      if actor.build and actor:build() == false then
        error("colosseum battle build declined")
      end
      local drew = actor:draw(matrix)
      if drew == false then error("colosseum battle draw declined") end
      return true
    end, { eye = Voxel3D.eye })
    return ok and accepted ~= false
  end
  function rig:caster(shadowMap, matrix) -- luacheck: ignore
    -- see the file header: no shadow entry point on Actor yet
    return false
  end
  function rig:release()
    -- real teardown is ColosseumBattleMon:release(); Stadium.lua never
    -- calls rig:release() directly (see StadiumMon:release, which does,
    -- but ColosseumBattleMon:release below does its own actor:release
    -- instead of going through here) -- kept only so nothing that ever
    -- does find this missing.
  end
  return rig
end

function ColosseumBattleMon.new(side)
  return setmetatable({
    kind = "colosseum",       -- lets Stadium.lua tell the two mon types
                               -- apart where it must (StadiumPack.keep)
    side = side,               -- "player" or "enemy"
    species = nil,             -- the dex number currently modelled
    shiny = false,
    model = nil,                -- true once an actor is loaded (Stadium.lua
                                 -- only ever tests this for truthiness)
    rig = nil,                  -- the shim above, once an actor is loaded
    actor = nil,                -- the live PokemonActors Actor
    state = nil,
    done = false,
    visible = false,
    scale = 1,                  -- the send-out grow, 1 the rest of the time
    grow = nil,
    grewOwn = nil,
  }, ColosseumBattleMon)
end

function ColosseumBattleMon:release()
  if self.actor then pcall(self.actor.release, self.actor) end
  self.actor, self.rig, self.model, self.species = nil, nil, nil, nil
  self.shiny = false
  self.state, self.done = nil, false
end

-- Mirrors StadiumMon:setSpecies -- see its own comment for why `shiny` is
-- part of the identity check rather than a flag applied afterwards.
--
-- `battler`/`gameObj` are optional and are ONLY used to look the species'
-- Pokedex height up in meters (PokemonActors.dexHeightMeters), which is
-- what lets CBE's own per-species height curve apply instead of its
-- generic ".72" fallback -- pass them when they're at hand (Stadium.update
-- already has both in scope) and this still degrades gracefully without
-- them.
function ColosseumBattleMon:setSpecies(dex, shiny, battler, gameObj)
  shiny = shiny and true or false
  if dex == self.species and shiny == (self.shiny or false) then
    return self.rig ~= nil
  end
  if self.actor then pcall(self.actor.release, self.actor) end
  self.actor, self.rig, self.model, self.species = nil, nil, nil, dex
  self.shiny = shiny
  self.grow, self.grewOwn = nil, nil
  self.state, self.done = nil, false
  if not dex then return false end
  if not Dex.supported(dex) then return false end
  local svc = service()
  if not (svc and type(svc.acquire) == "function") then return false end
  local variant = shiny and "shiny" or "normal"
  local ok, actor = pcall(svc.acquire, "battle-" .. tostring(self.side), dex,
                          variant, {
    side = self.side,
    battler = battler,
    context = {
      game = gameObj,
      battle = gameObj and { game = gameObj } or nil,
      services = { informationSurface = false },
      -- left unset on purpose: the service's own default figureScale is
      -- what ColosseumMon.lua's header says already lands a mid-size
      -- Pokemon at roughly StadiumMon.REF_HEIGHT world pixels
    },
  })
  if not ok or not actor then return false end
  self.actor = actor
  self.model = true
  self.rig = makeRig(self)
  self.state = actor.state
  return true
end

-- ------- the state machine
--
-- Ranked the same way StadiumMon:request ranks its four states, so a faint
-- is still final and an entrance still cannot be cut short by the standby
-- loop it hands on to -- see StadiumMon for why. Colosseum's own Actor
-- states ("spawn", "hit", "recall", "removal") are never asked for BY NAME
-- from here (Stadium.lua's hooks only ever request "entrance", "attack",
-- "faint" or "idle" -- see Stadium.install), so they do not need entries.
local RANK = { idle = 0, entrance = 1, attack = 2, faint = 3 }

-- `moveDef` is an extra, optional 4th argument nothing outside this file
-- passes except :attack() below -- it exists purely so the attack branch
-- of :play() can reach retailNativeSlot without a second lookup.
function ColosseumBattleMon:request(state, animIndex, auxIndex, moveDef)
  if not self.actor then return false end
  local now = RANK[self.state] or 0
  local want = RANK[state] or 0
  if self.state == "faint" then return false end
  if want < now then return false end
  return self:play(state, animIndex, auxIndex, moveDef)
end

-- Unconditional: starts `state` regardless of rank. Stadium.lua calls this
-- directly exactly once, to pull a side back to idle when a different
-- Pokemon has just arrived in a slot the last occupant left mid-faint (see
-- Stadium.update's "session.at[side] ~= battler" branch).
function ColosseumBattleMon:play(state, animIndex, auxIndex, moveDef)
  local actor = self.actor
  if not actor then return false end
  if state == "faint" then
    actor:faint("collapse")
  elseif state == "attack" then
    moveDef = moveDef or moveDefFor(animIndex)
    local nativeSlot = retailNativeSlot(animIndex, moveDef, self.species)
    actor:attack(animIndex, moveDef, { nativeSlot = nativeSlot })
  else
    -- "idle" AND "entrance" both land here: Colosseum's native slot set has
    -- no separate entrance bank (see the file header), so a send-out grows
    -- into the same idle loop a standing Pokemon plays the rest of the
    -- time, rather than a unique arrival pose.
    actor.hitAge, actor.faintAge, actor.recallAge = nil, nil, nil
    actor.pendingFaint, actor.pendingHits = nil, nil
    actor.pendingAttack, actor.pendingRecall = nil, nil
    actor.action, actor.actionAge = nil, 0
    pcall(actor.selectNativeSlot, actor, "idle")
    pcall(actor.transition, actor, "idle")
  end
  self.state = actor.state
  self.done = false
  return true
end

-- The animation a move plays for this species. `moveIndex` is the engine's
-- own move id -- the same numbering StadiumMon:attack indexes moveAnim by.
-- `moveDef` is optional (Stadium.lua's hook has one in hand and passes it
-- straight through; StadiumMon:attack(moveIndex) callers that don't just
-- get the moveDefFor(moveIndex) fallback inside :play()) and is what lets
-- retailNativeSlot -- and, failing that, Actor's own moveSlot() -- pick the
-- right animation instead of always falling back to a generic swing.
function ColosseumBattleMon:attack(moveIndex, moveDef)
  if not (self.actor and moveIndex) then return false end
  return self:request("attack", moveIndex, nil, moveDef)
end

-- ------- per frame

function ColosseumBattleMon:update(dt)
  dt = dt or 0
  self.dt = dt
  if self.grow then
    self.grow = self.grow + dt / StadiumMon.GROW_TIME
    if self.grow >= 1 then self.grow = nil end
  end
  local actor = self.actor
  if not actor then return end
  local ok = pcall(actor.update, actor, dt)
  if not ok then return end
  self.state = actor.state
  if actor.state == "faint" then
    local okT, complete = pcall(actor.terminalComplete, actor)
    self.done = (okT and complete) and true or false
  else
    self.done = false
  end
end

-- ------- the grow (see StadiumMon's own header for GROW_TIME's derivation
-- -- shared via V.require("StadiumMon") above rather than re-measured)

function ColosseumBattleMon:beginGrow()
  if self.grow or not self.actor then return false end
  self.grow = 0
  self.grewOwn = true
  return true
end

function ColosseumBattleMon:growScale()
  local t = self.grow
  if not t then return 1 end
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end

function ColosseumBattleMon:finished()
  return self.done and true or false
end

-- ------- size and placement
--
-- See the file header: actor.height*actor.worldScale already comes out in
-- the same world-pixel space StadiumMon.worldHeight does, under the
-- service's default figureScale, so this borrows StadiumMon's own
-- MIN_HEIGHT/MAX_HEIGHT hard stops rather than inventing a second pair.
function ColosseumBattleMon:worldHeight()
  local actor = self.actor
  if not actor then return StadiumMon.REF_HEIGHT end
  local h = (tonumber(actor.height) or 0) * (tonumber(actor.worldScale) or 1)
  if not (h > 0) then return StadiumMon.REF_HEIGHT end
  if h < StadiumMon.MIN_HEIGHT then h = StadiumMon.MIN_HEIGHT end
  if h > StadiumMon.MAX_HEIGHT then h = StadiumMon.MAX_HEIGHT end
  return h
end

-- No measured footprint on Actor (see the file header): approximated the
-- same way Stadium.captureBody already falls back for a Stadium model with
-- no radius of its own.
function ColosseumBattleMon:worldRadius()
  return self:worldHeight() * 0.4
end

-- No posed-bounds query on Actor yet (see the file header); nil here is
-- exactly what StadiumMon:bodySpan returns before its first skin, and
-- every caller (Stadium.captureBody, StadiumMon:groundGap's own pattern
-- below) already has a sensible fallback for that case.
function ColosseumBattleMon:bodySpan()
  return nil
end

function ColosseumBattleMon:groundGap()
  local centre, half = self:bodySpan()
  if centre then return math.max(0, centre - half) end
  return 0
end

-- The model matrix: stand this Pokemon on world (x, groundY, z) facing
-- (faceX, faceZ). Actor:matrix already bakes in spawn scale, attack lunge,
-- hit kick, faint collapse and floor clamping on its own (see the file
-- header) -- this only has to forward this frame's scale in first, the
-- same way StadiumMon folds `self.scale` into its own matrix multiply.
function ColosseumBattleMon:matrix(x, groundY, z, faceX, faceZ)
  local actor = self.actor
  if not actor then return nil end
  pcall(actor.spawn, actor, self.scale or 1)
  local ok, m = pcall(actor.matrix, actor, x, groundY, z, faceX, faceZ)
  if not ok then return nil end
  return m
end

-- Nothing to precompute separately from the draw: Actor:build() is itself
-- a no-op stub (posing and skinning happen inside Actor:draw), so this
-- only has to report whether there is anything to draw at all.
function ColosseumBattleMon:build()
  return self.actor ~= nil
end

return ColosseumBattleMon