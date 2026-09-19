-- Voxel world mode: assemble and draw one frame of the 3D scene.
--
-- World space is world pixels and shares its origin with the 2D paths, so
-- the terrain mesh needs no transform at all and a connected map just
-- translates by the same (ox, oy) the flat renderer already offsets it by.
--
-- Order is: the sun's shadow pass, then terrain, then characters, then a 2D
-- overlay for the field FX. There is no y-sort anywhere -- the depth buffer
-- resolves occlusion, which is the whole point of the mode. Walk behind a
-- building and the building is simply in front.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local Voxel3D = V.require("Voxel3D")
local ShadowMap = V.require("ShadowMap")
local Shadows = V.require("Shadows")
local ChunkMesher = V.require("ChunkMesher")
local SpriteBillboards = V.require("SpriteBillboards")
local TileShape = V.require("TileShape")
local TerrainAtlas = V.require("TerrainAtlas")
local Voxel = V.require("VoxelState")
local Sky = V.require("Sky")
local DayNight = V.require("DayNight")
local GroundFX = V.require("GroundFX")

-- Gen 3 support
local Gen3 = (function()
  local ok, gen3 = pcall(V.require, "Gen3")
  return ok and gen3 or nil
end)()
local Quality = V.require("Quality")
local Wind = V.require("Wind")
local Water = V.require("Water")
local Ceiling = V.require("Ceiling")
local Backdrop = V.require("Backdrop")
local SkyLayer = V.require("SkyLayer")
local Flora = V.require("Flora")
local Roamer = V.require("Roamer")
local StreetLamps = V.require("StreetLamps")
local Skyline = V.require("Skyline")
local HorizonArt = V.require("HorizonArt")
local FirstPerson = V.require("FirstPerson")
local VoxelGrid = V.require("VoxelGrid")
local BattleBillboard = V.require("BattleBillboard")
local Pokedex = V.require("Pokedex")
local Diorama = V.require("Diorama")
local ViewBox = V.require("ViewBox")
local DrawDistance = V.require("DrawDistance")
local PlayerModel = V.require("PlayerModel")
local StadiumFollower = V.require("StadiumFollower")
local StadiumWilds = V.require("StadiumWilds")
local PaletteFX = require("src.render.PaletteFX")
local Map = require("src.world.Map")

local VoxelScene = {}

-- When the grass pass last ran, in love.timer seconds. The grass springs
-- and the walked trail are integrated per PASS rather than per frame (see
-- the crush block in render), so this is what tells them how much time
-- actually went by. nil until the first pass.
local lastGrassAt = nil

-- What the active display mode actually paints with.
--
-- paletteFor hands back a map's RAW SGB zone palette, and that is not what
-- any of the non-colour modes draw. The flat path runs it through
-- PaletteFX.effectiveColors on the way to the shade-remap shader, and that
-- call IS where GRAY, INVERTED and CLASSIC happen -- OG / OG INV replace
-- the palette with the DMG greys (inverted for the latter), CLASSIC
-- replaces it with the green DMG set, and GBC INV permutes the zone's own
-- shades. GBC and RED++ pass through untouched.
--
-- This pass has no shader to apply that in: colour is baked into the atlas
-- and into the sprite sheets ahead of the draw, so it has to run the same
-- transform itself. Without it every mode that is not already a colour mode
-- comes through wearing the SGB palette -- grey and inverted both rendering
-- as plain SGB blue.
local function modeColors(paletteFor, map)
  local c = paletteFor and paletteFor(map) or nil
  return PaletteFX.effectiveColors(c)
end

VoxelScene._modeColors = modeColors   -- named for the suite

-- ------------------------------------------------------------------ sky --
--
-- The void behind the diorama is SKY, at every rung -- so the world reads as
-- standing under something rather than floating on a black plate.
--
-- What is up there differs by rung, and the sky follows it rather than being
-- retuned for each. At 75 degrees the camera is pitched far enough over that
-- the horizon is genuinely in frame, and the bands run down to meet it. At the
-- steeper rungs the horizon is above the top edge and the void that shows is
-- where the ground runs OUT -- past the map edge, past the curve -- so the
-- bands take a fixed slice of the frame instead (lib/Sky.lua, Sky.SPAN) and the
-- haze below them fills the rest.
--
-- INDOORS THERE IS NO SKY. A house, a cave or a gym is a room with a
-- ceiling, and the void past its walls is the outside of a box, not open
-- air. Map.isOutdoor is the same test the engine uses for door SFX and the
-- town map, and the same one Structures already asks to decide whether a
-- map rings with trees.
--
-- The colour is a four-shade ramp shaped like a world palette so the
-- display mode can transform it exactly like one: GRAY gets a grey sky,
-- CLASSIC a green one, GBC INV a dark one, and the colour modes the blue.
-- A hardcoded blue would sit wrong in every non-colour mode -- the same
-- mismatch the terrain bake had.
--
-- This ramp is the FLAT sky -- what a caller clears the void to. The free-roam
-- camera's banded sky has a palette of its own (lib/Sky.lua), transformed the
-- same way by the same seam; they are separate because the flat one also has to
-- serve an indoor void and a battle's arena, which want a colour rather than a
-- sky.
local SKY_SHADES = { { 222, 242, 255 }, { 135, 196, 240 },
                     { 64, 120, 192 }, { 16, 40, 80 } }
local SKY_SHADE = 2        -- the ramp's "sky" proper; 1 is its highlight

-- the ramp as the display mode has it, which is the only form anything here
-- should be reading it in
local function skyRamp()
  return PaletteFX.effectiveColors(SKY_SHADES) or SKY_SHADES
end

-- Full strength at every rung: the sky is painted wherever the diorama is.
--
-- The ramp that is left is for ARRIVAL alone. Switching the mode on eases the
-- camera up from flat, and the sky comes up with it over the first few degrees
-- rather than appearing whole on the keypress -- which is also what keeps a
-- top-down camera, where there is no void worth speaking of, from painting one.
local SKY_FADE_DEG = 8

local function skyStrength(angleRad)
  local deg = math.deg(angleRad or 0)
  if deg <= 0 then return 0 end
  local t = deg / SKY_FADE_DEG
  return t < 1 and t or 1
end

-- One shade off the sky ramp, transformed by the display mode, as an
-- {r, g, b, a} in 0..1. `shade` picks the rung (SKY_SHADE is the sky
-- proper; 4 is its darkest, which is what an indoor void wants).
function VoxelScene.skyShade(shade, alpha)
  local shades = skyRamp()
  local c = shades[shade] or SKY_SHADES[shade] or SKY_SHADES[SKY_SHADE]
  return { c[1] / 255, c[2] / 255, c[3] / 255, alpha or 1 }
end

-- The sky `map` stands under at strength `t`, or nil where there is no sky
-- to paint: indoors, or with the horizon out of frame.
--
-- One flat colour, which is what a caller that only needs something to clear the
-- void to wants -- the overworld battle's arena shot is one of those. The
-- gradient is added on top of this by skyFor, for the free-roam camera alone.
function VoxelScene.skyColor(map, t)
  if not (map and map.def and Map.isOutdoor(map.def)) then return nil end
  if not t or t <= 0 then return nil end
  local sky = VoxelScene.skyShade(SKY_SHADE, t)
  -- outdoors the flat fill follows the CLOCK: it becomes the hour's haze --
  -- gold at dusk, navy at night -- so a battle staged on the map at
  -- midnight is under a midnight void, not a noon one. Free-roam is
  -- unchanged by this: Sky.dress overwrites the fill with the same value.
  local haze = Sky.haze()
  if haze then sky[1], sky[2], sky[3] = haze[1], haze[2], haze[3] end
  return sky
end

-- The free-roam sky: the flat one above, dressed with the banded gradient
-- (lib/Sky.lua).
--
-- Only here, and deliberately. This is the sky the walking camera stands under,
-- where the horizon is a quarter of the way down the frame at the top rung and
-- one flat blue reads as a wall of paint. A battle is a staged shot with its own
-- placed camera whose horizon sits above the frame entirely, so it keeps the
-- flat fill it has always had -- there is no gradient to see from down there,
-- and the arena's look is not this rung's to change.
local function skyFor(map)
  local sky = VoxelScene.skyColor(map, skyStrength(Voxel.angle))
  if not sky then return nil end
  sky = Sky.dress(sky)
  if sky then sky.map = map end
  return sky
end

VoxelScene._skyFor = skyFor            -- named for the suite
VoxelScene._skyStrength = skyStrength

-- A facing as a yaw about +Y, kept for callers that reason about which way
-- an entity points (the mod exports it). The character cards themselves
-- never yaw -- they face south and lean, like the flat game.
local YAW = {
  down = 0,
  up = math.pi,
  right = math.pi / 2,
  left = -math.pi / 2,
}

-- THE ENGINE'S FRAME PROFILER (F11), so this pass can say where its own time
-- goes.  The engine already reports `world pass: voxel` as one number -- 32 to
-- 43 ms of a 90 ms frame -- and one number is not something anybody can act
-- on: it could be the shadow map, the terrain submit, the neighbours, or 155
-- billboards, and those have nothing in common as fixes.
--
-- Resolved once, lazily, and every call is a no-op closure while the profiler
-- is off, so this costs a table lookup per phase and nothing else.
local Profile = nil
local function profile()
  if Profile ~= nil then return Profile or nil end
  -- Plain `require` first: a mod chunk runs under the engine's own searcher,
  -- so engine modules resolve by name.  `V.engineRequire` is tried after it
  -- because it exists only on the Colosseum namespace in this mod and not on
  -- the lib namespace -- which is why the first cut of this measured nothing
  -- and reported no phases at all.
  local ok, mod = pcall(require, "src.core.FrameProfile")
  if not (ok and type(mod) == "table") then
    local req = V and V.engineRequire
    if type(req) == "function" then ok, mod = pcall(req, "src.core.FrameProfile") end
  end
  Profile = (ok and type(mod) == "table" and mod) or false
  return Profile or nil
end

local function phase(name)
  local P = profile()
  if not (P and P.section) then return nil end
  return P.section("        voxel: " .. name)
end

local NEIGHBOUR4 = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }

-- Lazily, and through pcall: Structures pulls in other modules of this mod and
-- the load order here is not ours to depend on.  Memoised in an upvalue so the
-- lookup happens once rather than per cell per frame.
local Structures = nil
local function structures()
  if Structures ~= nil then return Structures or nil end
  local ok, mod = pcall(V.require, "Structures")
  Structures = (ok and mod) or false
  return Structures or nil
end

-- The ground height a cell stands at, so a character on a ledge stands on
-- top of it rather than sunk into it. Uses the same bottom-left collision
-- tile the engine walks on (Map:cellTile).
--
-- `elev` is the walker's own elevation and `px`/`py` their world pixel
-- position.  Both are optional -- plenty of callers ask about an empty cell --
-- and both are what this function was missing:
--
--   * without `elev` a bridge cell has one height, so the walker on the deck
--     and the walker on the street under it are answered the same number and
--     one of them is inside the geometry;
--   * without `px`/`py` a stair cell can only answer one height for the whole
--     cell, so a flight is climbed in cell-sized jerks or not at all.
--
-- AND WITHOUT ANY OF THE BRANCHES BELOW it answers the TILESET ART's class
-- height, which on Hoenn is 0 for ordinary ground -- while the mesher raises
-- that same ground onto terraces (`gen3 shapes: ... 6708 tile(s) raised`).
-- That gap is the whole of "it places me underground in some areas where the
-- ground is raised": the terrain went up and the character did not.
local function groundRaw(map, cellX, cellY, elev, px, py)
  -- Off the map, cellTile border-extends into the map's borderBlock --
  -- which on maps ringed with trees is a RAISED tile. The only entity
  -- ever standing off-map is the player mid seam-step (placed one cell
  -- before the connection entry), and the ground actually rendered
  -- there is the departed neighbour's flat walkway: height 0. Without
  -- this, crossing into such a map hoisted the walker tree-high for
  -- exactly one step -- the "hops like a ledge" seam bug.
  if not map:inBounds(cellX, cellY) then return 0 end
  local shapes = TileShape.forMap(map)
  -- The same full resolution the mesher draws with, NOT the raw collision
  -- table: on Gen 2, map:cellTile answers a COLLISION CLASS (a counter, a
  -- bookcase, a console...), not a tile id. Indexing TileShape with that
  -- class resolved some unrelated tile's box instead of the one actually
  -- underfoot, and stood every character above the floor/furniture they
  -- were standing on -- the "characters float above the ground" bug on
  -- Gen 2 maps.
  local tx, ty = cellX * 2, cellY * 2 + 1
  local tile = map:tileAt(tx, ty)
  local isGen3 = Gen3 and Gen3.mapIsGen3(map) or false
  if isGen3 then tile = Gen3.tileAt(map, tx, ty) or tile end
  local s = TileShape.at(map, shapes, tile, tx, ty)
  if not s then return 0 end
  local S = structures()

  local okWalk, walkable = pcall(map.isWalkableCell, map, cellX, cellY)
  walkable = okWalk and walkable or false

  -- A BOX THE WALKER PASSES THROUGH rather than onto: a doorway is pinned
  -- solid so the facade closes over it, and the cell it is cut into stays
  -- walkable.  Answered at the height that box STANDS ON, not at the world
  -- datum -- a doorway cut into a facade founded four courses up walks the
  -- player out of the house and into the inside of the terrace below it.
  if s.art == "upright" and walkable then
    if S and S.standHeight then
      local okH, h = pcall(S.standHeight, map, tx, ty)
      if okH and type(h) == "number" then return h end
    end
    return 0
  end

  -- Doors carry no collision class of their own and fall through to the
  -- tileset's generic `wall`, which would step the walker up onto the frame.
  if map.doorTiles and map.doorTiles[tile] then return 0 end

  -- A FLIGHT CLIMBS.
  --
  -- This used to answer 0 -- so walking a staircase never raised the walker
  -- at all: they slid along the bottom terrace with the treads drawn under
  -- their feet and popped up a course on arrival.
  --
  -- Gen 3 has no stair art in the tileset: its flights are found by
  -- Structures, from tread art and the profile's flight lists, and marked on
  -- the cell -- so ask there too or this can never fire on a Hoenn map.
  local marked = false
  if S and S.stairAt then
    local okS, m2 = pcall(S.stairAt, map, tx, ty)
    marked = (okS and m2) or false
  end
  if s.art == "stair" or marked then
    if S and S.flightEnds then
      local okF, z0, z1, axis, heading, idx, n =
        pcall(S.flightEnds, map, cellX, cellY)
      if okF and z0 and z1 and n and n > 0 then
        -- The flight's two LANDINGS give the gap, through the same ranked
        -- elevation table the terraces are built from, so the top tread and
        -- the terrace it serves are equal by construction.  Position along
        -- the run gives the rest: a multi-cell flight spreads one rise over
        -- all its cells rather than a course per tile.
        local sub = 0.5
        if px and py then
          local off = (axis == "x") and (px % 16) or (py % 16)
          sub = off / 16
          if sub < 0 then sub = 0 elseif sub > 1 then sub = 1 end
        end
        -- WHICH TREAD IS THE BOTTOM ONE.  flightEnds returns its landings
        -- SORTED (z0 is the low one) but `idx` counts from the run's START,
        -- which is the high end whenever `heading` is -1.
        local fromLow = (heading == 1) and idx or ((n - 1) - (idx or 0))
        if not fromLow or fromLow < 0 then fromLow = 0 end
        if heading and heading < 0 then sub = 1 - sub end
        local t = (fromLow + sub) / n
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        -- VOLATILE: a flight interpolates on the walker's own pixel position
        return z0 + (z1 - z0) * t, true
      end
    end
    -- NOTHING TO CLIMB BETWEEN: a flight with one landing, or two at the
    -- same level, still stands on a terrace.
    if S and S.terraceAt then
      local okT, tz = pcall(S.terraceAt, map, cellX, cellY)
      if okT and type(tz) == "number" then return tz end
    end
    if S and S.standHeight then
      local okH, h = pcall(S.standHeight, map, tx, ty)
      if okH and type(h) == "number" then return h end
    end
    return 0
  end

  -- A DECK IS THE FLOOR ONLY FOR WHOEVER IS ON IT.
  --
  -- Keyed on the cartridge's own ELEV_MULTI (15) rather than on the voxel
  -- class, because the class does not always say bridge: Victory Road's
  -- crossings are ordinary floor metatiles whose only statement of "this is a
  -- deck" is the elevation.  Emerald's MULTI cells keep the elevation you
  -- arrived with -- that is the whole mechanism of walking UNDER the cycling
  -- road while someone rides over your head.
  --
  -- ASKED BEFORE THE TERRACE, and it has to be: the terrace answers for ANY
  -- walkable cell including a deck, so a walker on the street under Fortree's
  -- rope walkway was lifted onto the planks over their head.
  --
  -- And the span is WALKED, not peeked at: the middle of a MULTI span has
  -- MULTI on both sides and the ground it crosses on the other two, so a
  -- four-neighbour test finds nothing and falls back to the datum -- a walker
  -- on the deck drops through it.
  local g3ctx = nil
  if isGen3 and Gen3.forMap then
    local okG3, ctx = pcall(Gen3.forMap, map)
    g3ctx = okG3 and ctx or nil
  end
  local cellE = nil
  if g3ctx and g3ctx.elevationAt then
    local okE, e2 = pcall(g3ctx.elevationAt, cellX, cellY)
    cellE = okE and e2 or nil
  end
  local isDeck = (s.class == "bridge" or s.class == "log") or cellE == 15
  if isDeck and elev ~= nil and elev ~= 0 and elev ~= 15 and cellE ~= elev
     and g3ctx and g3ctx.elevationAt and g3ctx.groundHeight then
    local seen = { [cellY * 8192 + cellX] = true }
    local queue, qi = { { cellX, cellY } }, 1
    while qi <= #queue and qi <= 24 do
      local c = queue[qi]
      qi = qi + 1
      for _, d in ipairs(NEIGHBOUR4) do
        local nx, ny = c[1] + d[1], c[2] + d[2]
        local nk = ny * 8192 + nx
        if map:inBounds(nx, ny) and not seen[nk] then
          seen[nk] = true
          local okE, ne = pcall(g3ctx.elevationAt, nx, ny)
          ne = okE and ne or nil
          if ne == elev then
            -- The neighbour is a cell at the walker's OWN level, so it can
            -- never re-enter this branch (`cellE ~= elev` fails there) and
            -- the recursion is one deep.  Ask it what it stands on and the
            -- two sides of the span agree by construction -- rather than
            -- asking Gen3.groundHeight, which is the elevation grid's answer
            -- and not always the finished one (a causeway map pins its land
            -- to the datum on purpose and lets the bridge behaviour carry
            -- the lift).
            -- VOLATILE: a deck answers differently for the walker ON it
            -- than for the one beneath it, so this is never cached
            -- arity-ok: px/py are optional and only refine a stair's
            -- sub-cell interpolation, which a deck span has none of
            return (groundRaw(map, nx, ny, elev) or 0), true
          end
          -- keep walking, but only along the span itself
          if ne == 15 then queue[#queue + 1] = { nx, ny } end
        end
      end
    end
  end

  -- THE TERRACE IS THE FLOOR, WHATEVER THE CELL'S ART BECAME.  Structures'
  -- own height passes read the synthesised terrace height FIRST and only then
  -- look at the cell's shape; this function used to do the opposite, so the
  -- two disagreed about the same cell and a flat corridor answered three
  -- different heights along a row you can walk in a straight line.
  if walkable and S and S.terraceAt then
    local okT, tz = pcall(S.terraceAt, map, cellX, cellY)
    if okT and type(tz) == "number" then return tz end
  end

  -- A CELL WHOSE DRAWING STOOD UP IS GROUND AGAIN: the props -- chimneys,
  -- lamps, barrels -- whose art was lifted into a hull and whose leftover
  -- shape still carries the height that art had.
  if S and S.stampGround then
    local okP, stamped = pcall(S.stampGround, map, tx, ty)
    if okP and stamped then return stamped end
  end

  -- ...and a cell the mesher gave a MEASURED height to answers with that one,
  -- not with its class default: the river above a waterfall is drawn at the
  -- fall's crest, and a surfer reading the class height alone swam four cells
  -- under the sheet he was floating on.
  if S and S.runHeight then
    local okR, measured = pcall(S.runHeight, map, tx, ty)
    if okR and measured and measured > 0 then return measured end
  end

  -- ...AND THEN ASK THE MESH WHAT IT DREW, before asking the tileset what the
  -- tile class usually is.
  --
  -- THIS IS THE RUNG THE WHOLE LADDER WAS MISSING, and it is why characters
  -- kept sinking on maps with a raised tier after the datum itself was fixed.
  --
  -- ChunkMesher decides a tile's floor in exactly three steps (its own
  -- `heightAt`): a stamped cell answers `Structures.stampGround`, a cell with
  -- a run answers `run.h`, and everything else answers `S.shapeAt[k].h` --
  -- which on Gen 3 is `shapeHeight` verbatim.  The two rungs above are those
  -- first two steps.  The third was never asked.
  --
  -- What stood in its place was the TILESET's shape (`s`, from TileShape.at),
  -- which is cached per TILESET ID and knows nothing about what this MAP did
  -- with the tile afterwards -- the elevation pass, the terrace flood, the
  -- grading, every pass that writes `S.shapeAt`.  On flat ground the two
  -- agree and nobody notices.  On a tier they differ by the whole lift, the
  -- class height is 0, the `> 0` test rejects it, and the cell falls through
  -- to the four-neighbour vote -- which only answers when all four agree, so
  -- a cell beside a building, a fence, a rock or the map edge gets no answer
  -- and lands on the datum.  That is the cell-dependent sinking: most of a
  -- town right, a handful wrong, and no way to tell which from outside.
  --
  -- `flatGroundAt` is the reader for it and is already public: it answers
  -- `S.shapeAt[k].h` for a tile the mesh laid FLAT, and nil for a wall, a
  -- facade, a prop or a cell the build has not reached -- so a walker never
  -- takes a facade's height from here, and everything below still runs for a
  -- cell the mesh has no shape for.  Asked AFTER stamp and run so the three
  -- are asked in the mesher's own order, and after the terrace and the
  -- doorway/stair/deck rungs, which exist precisely to DISAGREE with the
  -- drawing (a walker must not be stood on a roof, or under a bridge).
  if walkable and S and S.flatGroundAt then
    local okF, drawn = pcall(S.flatGroundAt, map, tx, ty)
    if okF and type(drawn) == "number" then return drawn end
  end

  if s.h and s.h > 0 then return s.h end

  -- THE SEA IS DRAWN BELOW THE DATUM, which the line above throws away.
  -- Hoenn draws its water recessed into its own cell, so a water tile's
  -- height is -2 or -4 and never positive; every branch above is silent for
  -- such a cell and the `> 0` test rejects the one number that IS the answer.
  if s.h and s.h < 0 then
    if s.class == "water" and isGen3 then return s.h end
    return s.h
  end

  -- ...AND THE DATUM IS NOT THE DEFAULT FLOOR.  A walkable cell with no run
  -- and no height of its own still sits on whatever floor is around it.  Only
  -- the four cells TOUCHING this one vote, only walkable floor among them,
  -- and only when they AGREE: a bush standing in a plaza has terrace on every
  -- side and takes it; a cell on open ground has neighbours that differ, or
  -- none, and keeps the datum.  A wider ring was tried and reaches some
  -- unrelated rise on open routes -- a net loss.
  if walkable and S then
    local agreed, seen = nil, false
    for _, d in ipairs(NEIGHBOUR4) do
      local nx, ny = cellX + d[1], cellY + d[2]
      if map:inBounds(nx, ny) then
        local okN, nw = pcall(map.isWalkableCell, map, nx, ny)
        if okN and nw then
          local ns = nil
          if S.runHeight then
            local okR, r = pcall(S.runHeight, map, nx * 2, ny * 2 + 1)
            ns = okR and r or nil
          end
          if ns == nil and S.flatGroundAt then
            local okG, g = pcall(S.flatGroundAt, map, nx * 2, ny * 2 + 1)
            ns = okG and g or nil
          end
          -- a neighbour with neither ABSTAINS rather than vetoing: vetoing
          -- meant one un-flat neighbour silenced the whole vote
          if ns ~= nil then
            if not seen then agreed, seen = ns, true
            elseif agreed ~= ns then agreed = nil break end
          end
        end
      end
    end
    if agreed and agreed > 0 then return agreed end
  end

  -- THE ELEVATION GRID IS THE LAST WORD, NOT THE DATUM.
  --
  -- Everything above has declined: no doorway, no flight, no deck, no terrace,
  -- no stamp, no measured run, no height of its own, and no agreement among
  -- the four cells touching it.  Returning 0 there says "this cell is at the
  -- world floor", and on a map whose ground the mesher RAISED off the
  -- elevation grid -- `gen3 shapes: took ground height from the elevation
  -- grid, 3 level(s), 8248 tile(s) set` -- that is a claim the terrain
  -- contradicts.  The result is a character standing a course or two inside
  -- the ground, reported from Mauville and from every town with a raised
  -- plaza.
  --
  -- So ask the same grid the terrain was built from.  `ctx.groundHeight` is
  -- the mod's own reader for it: it resolves the transition cells by ramp and
  -- the decks by bridge behaviour, and it is what `Structures` consults when
  -- it lays the ground in the first place.  It is not always the FINISHED
  -- height -- a causeway map pins its land to the datum on purpose and lets
  -- the bridge carry the lift -- which is exactly why it is here, after every
  -- reader that knows better, and not before them.
  if g3ctx and g3ctx.groundHeight then
    local okH, h = pcall(g3ctx.groundHeight, cellX, cellY)
    if okH and type(h) == "number" and h > 0 then return h end
  end

  return 0
end

-- Ground under an entity this frame.  Water is the only class whose floor
-- MOVES: the same two sines the mesh rides (Water.heightAt).  Anything
-- with `surfing` set (the player mid-Surf, a water roamer) stands on the
-- live surface at its own pixel centre so feet and plane rise together.
-- Land uses the cell's static height; mid-step hop lift still comes from
-- pose() as before.
-- Forward declaration: `entityGround` below calls `groundAt`, and the memo
-- that defines it sits further down (it needs TileShape's per-map table).
-- Without this the call resolves to a GLOBAL of that name -- nil -- and takes
-- the whole render pass down with it.
local groundAt

local function entityGround(map, e, px, py)
  local wx = (px or 0) + 8
  local wz = (py or 0) + 8
  if e and (e.surfing or (e.roamer and e.kind == "water")) then
    local ok, y = pcall(Water.surfaceAt, wx, wz)
    if ok and y then return y end
    return Water.BASE or -2
  end
  -- Walkable ice: height identity is still water, but the effective floor is
  -- the frozen surface (Water.surfaceAt), not the land groundAt of -2.
  if e and map and map.isWaterCell and Water.walkableIce then
    local wok, water = pcall(map.isWaterCell, map, e.cellX, e.cellY)
    if wok and water then
      local iok, ice = pcall(Water.walkableIce, wx, wz)
      if iok and ice then
        local ok, y = pcall(Water.surfaceAt, wx, wz)
        if ok and y then return y end
        return (Water.BASE or -2) + (Water.iceLift and Water.iceLift() or 0)
      end
    end
  end
  -- ...AND THE WALKER'S OWN ELEVATION AND PIXEL POSITION GO WITH THE
  -- QUESTION.  Dropping them here is what left every character standing at
  -- the tileset's class height while the mesher raised the ground under
  -- them: `elev` is what tells a bridge cell whether this walker is on the
  -- deck or on the street beneath it, and px/py are what make a flight climb
  -- continuously instead of popping a course at the top.
  return groundAt(map, e.cellX, e.cellY, e and e.elevation, px, py)
end

-- Whether what stands on this cell has a FLAT top at groundAt's height, or a
-- shape carved out of its own artwork.
--
-- groundAt answers how HIGH the profile puts a cell, and for a box that is
-- also where its top face is: a wall, a roof, a ledge and a fence are all
-- 16x16 lids at exactly that height. For the round classes it is not. A
-- `cylinder` or `canopy` cell is a voxel HULL cut from the drawing's own
-- outline (Structures.buildCylinders) and a `billboard` or `post` is a
-- per-pixel slab, so the class height is where the crown's HIGHEST voxel
-- lands and the surface falls away from it in every direction -- by half a
-- cell at the rim of a dome.
--
-- Anything that wants to lie ON a cell has to know the difference, because a
-- flat quad at the class height of a rounded crown touches it at one point
-- and hangs in the air everywhere else. See GroundFX's crusts, which is the
-- one caller and the reason this exists.
local ROUND_ART = {
  cylinder = true,     -- tree canopies, stumps: hulls cut from the art
  canopy = true,       -- the 2x2-cell forest trees, same carve at 32px
  billboard = true,    -- signs and props: per-pixel standing slabs
  post = true,         -- fence posts, one depth band per cell
  grass = true,        -- tufts standing in rows
  flower = true,
}

local function flatTop(map, cellX, cellY)
  if not map:inBounds(cellX, cellY) then return false end
  local shapes = TileShape.forMap(map)
  -- Same reasoning as groundAt above: on Gen 2, map:cellTile is a collision
  -- class, not a tile id, so this has to resolve the real tile the same way
  -- groundAt does (map:tileAt at the full-resolution sub-cell).
  local tx, ty = cellX * 2, cellY * 2 + 1
  local tile = map:tileAt(tx, ty)
  -- Gen 3: use Gen3.tileAt to get the correct synthetic tile ID
  if Gen3 and Gen3.mapIsGen3(map) then
    tile = Gen3.tileAt(map, tx, ty) or tile
  end
  local s = TileShape.at(map, shapes, tile, tx, ty)
  -- no shape is flat ground at zero, which groundAt already reports as 0 and
  -- every caller here rejects on its own
  if not s then return true end
  return not ROUND_ART[s.art]
end

-- ONE LOOKUP PER CELL, NOT ONE PER ENTITY PER FRAME.
--
-- Measured, once the world pass could report its own phases:
--
--   world pass: voxel                        167.29 ms/frame
--     voxel: poses (ground lookup per entity) 100.02 ms/frame   <- here
--
-- 155 posed entities, each asking what its cell stands on, every frame -- and
-- the answer for a cell does not change from one frame to the next.  A
-- character walks one cell every sixteen frames or stands still for minutes,
-- so almost every one of those lookups is the same question asked again.
--
-- Keyed on the MAP, weakly, and witnessed by the shapes table it was filled
-- from (see groundAt below for why the shapes table alone is not a key).  Each
-- entry also carries the tick it
-- was taken on, because Structures can rebuild behind us without TileShape
-- changing (a seam refresh does exactly that) -- so an entry older than the
-- TTL is recomputed rather than trusted.  Half a second of staleness at
-- 60fps, against 155 full lookups a frame.
--
-- TWO ANSWERS ARE NEVER CACHED.  A flight interpolates on the walker's pixel
-- position and a deck answers differently for the walker on it than for the
-- one beneath it; both are marked volatile by the worker above.  Caching
-- either is how a character would climb a staircase in sixteen-frame steps,
-- or stand on a bridge they are walking under.
local groundMemo = setmetatable({}, { __mode = "k" })
local groundTick = 0
local GROUND_TTL = 30

function VoxelScene.groundTick()
  groundTick = groundTick + 1
end

function groundAt(map, cellX, cellY, elev, px, py)
  if not (map and map.inBounds) then return 0 end
  local shapes = TileShape.forMap(map)
  if not shapes then return (groundRaw(map, cellX, cellY, elev, px, py)) end
  -- KEYED ON THE MAP, WITNESSED BY THE SHAPES.
  --
  -- The first cut of this keyed the cache on the shapes table alone, which was
  -- wrong in a way that only shows up in a town: TileShape.forMap caches by
  -- TILESET id, not by map, so every map drawn with the same tileset shared
  -- one table -- and cell (10,10) of Mauville answered with cell (10,10) of
  -- whatever else was loaded beside it.  Reported as "some npcs were appearing
  -- in the ground in mauville city", which is exactly what borrowing another
  -- map's terrace heights looks like.
  --
  -- So the cache hangs off the MAP (weak, so an evicted map takes its heights
  -- with it) and remembers which shapes table it was filled from.  A rebuilt
  -- tileset changes that table, and the map's heights are dropped with it
  -- rather than quietly surviving the analysis they were read from.
  -- ...AND ON WHETHER THE MAP HAS BEEN BUILT YET, which is a third thing the
  -- answers depend on and the first two do not carry.
  --
  -- Before Structures has been over a map every reader in the ladder answers
  -- nil, so a character is placed on the datum.  That is the right thing to
  -- draw with -- somebody has to stand somewhere while a town meshes, which
  -- takes seconds -- and the wrong thing to keep.
  --
  -- The first cut refused to cache at ALL while a map was unbuilt, which is
  -- correct and costs the most at exactly the worst moment: every actor on a
  -- map still being meshed walked the whole ladder every frame, and
  -- `voxel: poses` went from nine milliseconds to twelve.
  --
  -- So cache as usual, and throw the whole map's answers away the first
  -- frame it reports built.  One boolean compare per lookup, one flush at
  -- the transition, and nothing carries a pre-build guess past it.
  local S0 = structures()
  local isBuilt = (S0 and S0.built and S0.built(map)) or false
  local entry = groundMemo[map]
  if not entry or entry.shapes ~= shapes or entry.built ~= isBuilt then
    entry = { shapes = shapes, cells = {}, built = isBuilt }
    groundMemo[map] = entry
  end
  local memo = entry.cells
  -- the elevation is part of the question (a deck), and nil is a real value
  local key = (cellY * 8192 + cellX) * 18 + ((tonumber(elev) or 16) % 18)
  local hit = memo[key]
  if hit and (groundTick - hit[2]) < GROUND_TTL then return hit[1] end
  local h, volatileAnswer = groundRaw(map, cellX, cellY, elev, px, py)
  if volatileAnswer then
    memo[key] = nil
    return h
  end
  memo[key] = { h, groundTick }
  return h
end

VoxelScene.YAW = YAW
-- shared with the overworld battle, which stands its mons on map cells and
-- needs the same answer about what height "the floor" is there
VoxelScene.groundAt = groundAt
VoxelScene.flatTop = flatTop

-- Camera-ward pull distance for billboards (and the grass rows, which
-- must keep their relative depth to feet): just enough that a leaned-back
-- slab clears the wall it leans over. The lean flattens toward top-down,
-- so the needed pull grows exactly as real occlusion stops mattering.
function VoxelScene.pull(a)
  return 6 + math.max(0, 16 * math.cos(a) - 8) / math.max(math.sin(a), 0.2)
end

-- The sheet frame and mirror flag the 2D path would draw for this pose
-- (same tables as SpriteRenderer). Shared by the billboard pass and the
-- shadow pass so a walking character's shadow swings its legs too.
-- resolved ONCE, not per card: `require` is a package.loaded lookup plus a
-- call, and this runs for every actor in both the eye pass and the sun
-- pass.  Memoised rather than bound at load because the engine module is
-- not guaranteed to be there when a mod chunk first runs.
-- THE THREE QUARTER-TURN FACING MAPS, BUILT ONCE.
--
-- These were table literals inside the branch, so a card standing while the
-- camera happened to sit near a cardinal allocated a fresh four-entry table
-- -- per actor, per pass.  Harmless while the yaw never arrived; the moment
-- the slipped argument list was fixed and `yaw` started reaching this
-- function, the branch went live for every card in the world.
local YAW_LEFT  = { up = "left",  right = "up",    down = "right", left = "down"  }
local YAW_RIGHT = { up = "right", right = "down",  down = "left",  left = "up"    }
local YAW_BACK  = { up = "down",  right = "left",  down = "up",    left = "right" }

local SpriteRenderer = nil
local function frameFor(def, facing, phase, flip, yaw)
  local SR = SpriteRenderer
  if not SR then
    SR = require("src.render.SpriteRenderer")
    SpriteRenderer = SR
  end
  local frame, mirror = 0, false

  -- Adjust facing based on camera yaw (ported from ADVANCED_SHAPE): as the
  -- orbit camera turns, a sprite drawn "facing down" from due south should
  -- read as facing whichever way is actually toward the camera now.
  if yaw and yaw ~= 0 then
    local yawDeg = math.deg(yaw)
    -- Normalize to handle both 180 and -180
    while yawDeg > 180 do yawDeg = yawDeg - 360 end
    while yawDeg < -180 do yawDeg = yawDeg + 360 end

    -- Map camera rotation to facing adjustments with tolerance
    local map = nil
    if math.abs(yawDeg - (-90)) < 5 then map = YAW_LEFT
    elseif math.abs(yawDeg - 90) < 5 then map = YAW_RIGHT
    elseif math.abs(yawDeg - 180) < 5 or math.abs(yawDeg - (-180)) < 5 then
      map = YAW_BACK
    end

    if map then
      facing = map[facing] or facing
    end
  end

  if (def.frames or 1) > 1 then
    frame = (def.walker and phase == 1) and SR.WALK[facing]
            or SR.STAND[facing]
    mirror = facing == "right"
      or ((facing == "down" or facing == "up") and phase == 1 and flip)
  end
  return frame, mirror
end

-- The facing a pose SHOWS this camera. The flat frames are "how this pose
-- looks from the south", which is where the orbit always stands; a
-- first-person eye stands anywhere, so deep enough into the blend the
-- facing is remapped to how the pose looks from THERE -- walk behind an
-- NPC and their card wears the back sprite. Used by the camera draw and
-- the sun pass BOTH: the card the sun stored and the transform a lit card
-- reads its own shadowing with must describe the same frame, or the
-- mirror-flip half of the pair asks the map about texels the sun filed
-- under the other cheek.
-- The player's own card asks a different function for the same answer:
-- their body's bearing is what the camera is derived FROM, so it is known
-- continuously rather than as one of four directions, and measuring
-- against the compass point instead flicks the card to a profile for a
-- frame or two when the camera is spun fast (see playerFacing).
--
-- The facing a pose SHOWS this camera. The flat frames are "how this pose
-- looks from the south", which is where the orbit always stands; a
-- first-person eye stands anywhere, so deep enough into the blend the
-- facing is remapped to how the pose looks from THERE -- walk behind an
-- NPC and their card wears the back sprite. Used by the camera draw and
-- the sun pass BOTH: the card the sun stored and the transform a lit card
-- reads its own shadowing with must describe the same frame, or the
-- mirror-flip half of the pair asks the map about texels the sun filed
-- under the other cheek.
-- The player's own card asks a different function for the same answer:
-- their body's bearing is what the camera is derived FROM, so it is known
-- continuously rather than as one of four directions, and measuring
-- against the compass point instead flicks the card to a profile for a
-- frame or two when the camera is spun fast (see playerFacing).
local function viewFacing(p)
  if FirstPerson.cardBlend() > 0.5 then
    if p.isPlayer then
      return FirstPerson.playerFacing(p.facing, p.px + 8, p.py + 8)
    end
    return FirstPerson.apparentFacing(p.facing, p.px + 8, p.py + 8)
  end
  return p.facing
end

-- FALLBACK ONLY (see castShadows below). Draw one entity's drop shadow as
-- a decal: its current sprite frame as a single quad, flattened onto the
-- ground along the sun line (Voxel3D.shadowMatrix). Runs inside
-- beginShadows, which supplies the translucent black; the texture is only
-- consulted for its alpha, so no palette work is needed.
local function drawShadow(sprite, px, py, facing, phase, flip, gh, lift,
                          waterline, yaw)
  local def = sprite.def
  local frame, mirror = frameFor(def, facing, phase, flip, yaw)
  local mesh = SpriteBillboards.shadowQuad(def, frame, waterline or 0)
  if not mesh then return end
  
  -- Get sprite dimensions for dynamic sizing (texture dims and world dims)
  local texWidth, texHeight, worldWidth, worldHeight = SpriteBillboards.getSpriteDimensions(def, frame)
  Voxel3D.draw(mesh, sprite:resolveImage(),
               Voxel3D.shadowMatrix(px, py, gh, lift, mirror, worldWidth, worldHeight))
end

-- Where a billboard character's card stands: on the middle of its cell at
-- height `y`, pivoted at the feet and tipped back by exactly the camera's
-- pitch. The slab is built centred on its sprite plane (z = 0), so only the
-- x anchor shifts; the relief bulges symmetrically front and back of it.
--
-- Shared by the solid draw and the silhouette below, so the two can never
-- drift apart -- a silhouette standing anywhere but exactly behind the
-- figure would read as a second character.
--
-- IN FIRST PERSON the card stops leaning and starts TURNING: upright, yawed
-- about its feet to face the eye (cylindrical billboarding). A south-facing
-- card is invisible edge-on to an eye standing east of it, which no orbit
-- camera could ever do and a first-person one does constantly. The blend
-- carries one pose into the other -- the lean eases out as the yaw eases in
-- -- and cardBlend is zero for every camera that is not the first-person
-- rig, the battle's placed shot included, so nothing else moves.
-- The pitch the sprite cards lean back by -- normally the rung's own
-- camera angle, overridable in radians. VR sets the override to the top
-- rung's 75 degrees for every diorama and battle frame: a table watched
-- from a freely moving head has no one camera pitch for the cards to
-- match, and the near-upright top-rung lean is the pose that reads as
-- "standing" from anywhere around it. nil (the default, and the flat
-- screen always) leans with the rung as ever.
VoxelScene.spriteLean = nil

local function leanAngle()
  -- `Voxel` is this module's own VoxelState, bound at load.  Going back
  -- through V.require here cost a call per CARD per pass -- a couple of
  -- hundred a frame in a town -- to reach the table already in scope.
  return VoxelScene.spriteLean or Voxel.angle
end

-- Composition order matters here and is easy to get backwards: Mat4.mul(m,
-- X) RIGHT-multiplies, so the LAST matrix chained on is the FIRST one
-- applied to a vertex. Correct billboard behavior is to tip the card back
-- by pitch in its OWN local frame first, then swing the already-tipped
-- card around the world +Y axis to face the camera's yaw.
-- THE CHAIN IS FIXED, SO IT IS WRITTEN OUT.
--
-- The composition never varies: translate to the card's centre, turn it about
-- +Y, tip it back about its own X, mirror it if the sheet wants the flipped
-- frame, then shift the origin back to the card's left edge.  Built with
-- Mat4.mul that is up to nine fresh sixteen-slot tables and four full matrix
-- products -- 256 multiplies -- for a transform with about ten distinct
-- numbers in it.  Per card.  Per pass.  Twice over, because the sun draws the
-- cast as well, and a town poses well over a hundred actors.
--
-- Multiplied out by hand (T1 * Ry * Rx * S * T2, row-major, translation in
-- the fourth column, and every factor affine so the bottom row stays
-- [0,0,0,1]):
--
--   Ry*Rx  = { c, s*sp, s*cp ; 0, cp, -sp ; -s, c*sp, c*cp }
--   *S     scales the FIRST COLUMN by sx (mirror is scale(-1,1,1))
--   T1     adds the centre to the fourth column
--   *T2    adds column1 * -halfW to the fourth column
--
-- One table, about ten multiplies, and identical to the ninth decimal --
-- tests/matrix_test.lua builds the old chain with the real Mat4 and compares
-- all sixteen slots across yaw, mirror, blend and lean.
local HALF_PI = math.pi / 2
local cos, sin = math.cos, math.sin
local function billboardMatrix(px, py, y, mirror, yaw, spriteWidth, spriteHeight)
  local halfW = (spriteWidth or 16) / 2
  local cx = px + halfW
  local cz = py + (spriteHeight or 16) / 2
  local b = FirstPerson.cardBlend()

  local a = 0
  if b > 0 then a = FirstPerson.cardYaw(cx, cz) * b
  elseif yaw and yaw ~= 0 then a = yaw end

  local ca, sa = cos(a), sin(a)
  local pitch = (leanAngle() - HALF_PI) * (1 - b)
  local cp, sp = cos(pitch), sin(pitch)
  local sx = mirror and -1 or 1
  local m1 = ca * sx          -- column 1, which is also what T2 shifts by
  local m9 = -sa * sx
  return {
    m1,  sa * sp,  sa * cp,  cx - m1 * halfW,
    0,   cp,       -sp,      y,
    m9,  ca * sp,  ca * cp,  cz - m9 * halfW,
    0,   0,        0,        1,
  }
end

local function billboardPull()
  return VoxelScene.pull(math.max(leanAngle(), 0.05))
end

-- An authored FIGURE's card -- a person the tileset draws INTO a piece of
-- furniture, cut out by the profile's mask (Structures.buildFigures). It is
-- a sprite, so it gets the sprite treatment: the mesh arrives in its own
-- local space with its feet on y = 0, and this stands it at its drawn
-- position and tips it back by exactly the camera's pitch -- the same
-- pivot-at-the-feet lean billboardMatrix gives a character, so the man on
-- the Pokemon Center couch reads face-on at every tilt like the NPCs
-- around him. No cell centring: unlike a character he is not standing on a
-- cell, he is standing where he was drawn, which may straddle two.
--
-- First person turns him at the eye like the walkers (see billboardMatrix)
-- -- about his own middle, because unlike a character card his local space
-- starts at x = 0 rather than being anchored by a -8 shift, and a yaw about
-- his edge would swing him off his seat. The width rode in on the record
-- for exactly this (ChunkMesher.buildFigureMeshes).
local function figureMatrix(f, offX, offZ)
  local Voxel = V.require("VoxelState")
  local b = FirstPerson.cardBlend()
  local wx, wz = f.wx + (offX or 0), f.wz + (offZ or 0)
  local m = Mat4.translate(wx, f.y, wz)
  if b > 0 and f.w and f.w > 0 then
    local half = f.w / 2
    m = Mat4.mul(m, Mat4.translate(half, 0, 0))
    m = Mat4.mul(m, Mat4.rotateY(FirstPerson.cardYaw(wx + half, wz) * b))
    m = Mat4.mul(m, Mat4.translate(-half, 0, 0))
  end
  return Mat4.mul(m, Mat4.rotateX((leanAngle() - math.pi / 2) * (1 - b)))
end

-- What the sun sees: the same card UNLEANED and flattened, exactly as
-- Voxel3D.casterMatrix does it for a character.
local function figureCaster(f, offX, offZ)
  return Mat4.mul(
    Mat4.translate(f.wx + (offX or 0), f.y, f.wz + (offZ or 0)),
    Mat4.scale(1, 1, 0))
end

-- Every figure on `map`, drawn with `draw(mesh, model, caster)`.
local function eachFigure(map, offX, offZ, draw)
  local figs = ChunkMesher.figures(map) or {}
  for _, f in ipairs(figs) do
    draw(f.mesh, figureMatrix(f, offX, offZ), figureCaster(f, offX, offZ))
  end
end

-- Draw one posed entity. Returns true if 3D geometry carried it, false
-- when nothing could be built and the caller should fall back.
-- `colors` is the 4-color world palette the entity stands under in the SGB
-- modes (nil under RED++/trueColor): the 2D path colorizes sprites with a
-- screen-space shader the voxel canvas never runs through, so the model's
-- texture gets the palette baked in instead (TerrainAtlas.forSprite).
-- `lift` raises the figure off the ground plane (ledge hops arc UP in 3D,
-- where the 2D path could only slide the sprite north).
local function drawEntity(sprite, px, py, facing, phase, flip, gh, colors,
                          lift, waterline, isPlayer, yaw)
  local def = sprite.def
  local tex = sprite:resolveImage()
  if colors and not def.trueColor then
    tex = TerrainAtlas.forSprite(def.image, colors) or tex
  end
  local y = gh + (lift or 0)

  -- pick the very frame the 2D path would draw (same tables). The card
  -- always faces SOUTH -- the direction the 2D game implies -- and only
  -- LEANS BACK, pivoting at its feet, by exactly the camera's pitch, so
  -- at every tilt level the sprite reads face-on like the flat game.
  -- No camera-tracking yaw: every sprite leans in parallel.
  -- waterline > 0: only the top of the card is built, origin at the
  -- waterline (SpriteBillboards), so a swimming mon is cut by the pond
  -- rather than standing on it.
  local frame, mirror = frameFor(def, facing, phase, flip, yaw)
  local mesh = SpriteBillboards.mesh(def, frame, waterline or 0)
  if not mesh then return false end
  
  -- Get sprite dimensions for dynamic sizing (texture dims and world dims)
  local texWidth, texHeight, worldWidth, worldHeight = SpriteBillboards.getSpriteDimensions(def, frame)
  
  -- Apply LOD bias for sharpness when scaling down
  local scale = def.scale or 1.0
  if scale < 1.0 then
    local lodBias = SpriteBillboards.getLodBiasForScale(scale)
    if lodBias ~= 0.0 then
      Voxel3D.setLodBias(lodBias)
    end
  end

  -- Camera-ward pull (applied per vertex in the shader, along each
  -- vertex's own eye ray, so it is a PURE depth bias with zero screen
  -- drift): lets the leaned-back head win against the wall it leans
  -- OVER while a character genuinely BEHIND a building is dozens of
  -- pixels deeper and still loses, so real occlusion works.
  -- the same card UNLEANED -- and SNUGGED, exactly as the sun stored it
  -- (castShadows draws this mesh through ShadowMap.snug) -- is where each
  -- vertex asks whether the light reached it; see ShadowMap.snug for why
  -- the lookup must match the stored transform to the letter
  Voxel3D.draw(mesh, tex, billboardMatrix(px, py, y, mirror, yaw, worldWidth, worldHeight),
               billboardPull(),
               ShadowMap.snug(Voxel3D.casterMatrix(px, py, y, mirror, worldWidth, worldHeight)))
  return true
end

VoxelScene.drawEntity = drawEntity




-- A CARD OUTSIDE THE BOX BEING DRAWN IS NOT IN THE PICTURE -- so it must not
-- be drawn, and for the sun it must not be in the signature that decides
-- whether the shadow map has to be redrawn either.
--
-- One predicate, two boxes: the sun pass hands it the light box
-- (VoxelScene.bounds forSun) and the eye pass hands it the view box, which
-- is the same box the terrain is drawn to.  Declared up HERE rather than
-- beside the sun pass because drawCast is the first user and a local is not
-- visible above its own declaration -- left below, it would silently be a
-- nil global and take the render pass down on its first card.
--
-- MOTIVATED BY MAUVILLE, where the sun pass measured 83 ms EVERY FRAME.
--
-- Two costs, one cause.  The town is a seam: with DRAW DIST on FAR its four
-- neighbours are resident, one of them Route 119 at 40x140 cells, and the
-- posed list comes out around 150 entries -- most of them people wandering
-- about a route the light box does not reach anywhere near.  Every one of
-- them was drawn as a caster card (frame pick, quad, dimensions, matrix,
-- draw), and every one of them put its exact pixel position and animation
-- phase into `shadowSignature`.  So a stranger taking a step three screens
-- away made the signature differ, and the whole sun pass -- a route-sized
-- terrain mesh plus 78 building runs -- was redrawn for a shadow that falls
-- nowhere near the canvas.  Standing perfectly still in a town could not
-- reuse the map even once, which is the one case the signature exists for.
--
-- The SAME predicate governs both, deliberately: cull the draw without
-- culling the signature and the map would go stale for a caster that is no
-- longer in it; cull the signature without culling the draw and a card would
-- be drawn from a stamp that never recorded it.  They have to be one test.
--
-- The pad is a card's own half-width and then some; the box already carries
-- the sun's shear margin (VoxelScene.bounds forSun) on the side the shadows
-- actually stretch toward.
local CAST_PAD = 32
local function castsInto(box, p)
  if not box then return true end
  local x, y = p.px or 0, p.py or 0
  return x >= box[1] - CAST_PAD and x <= box[3] + CAST_PAD
     and y >= box[2] - CAST_PAD and y <= box[4] + CAST_PAD
end

-- ------- the cast
--
-- Everybody standing on the map: the walkers, and the authored FIGURES the
-- tileset draws into its own furniture (they ARE characters as far as the
-- artwork is concerned, just ones drawn by the tileset instead of by a
-- sprite sheet, so they get the same lean and the same camera-ward pull).
-- THE PARAMETER LIST MUST MATCH THE CALL, and this one did not.
--
-- Called as `drawCast(state, posed, me, atlasFor, yaw)` -- five arguments into
-- four parameters -- so everything shifted one place left: `atlasFor` bound
-- the player's pose, `yaw` bound the atlas function, and the real camera yaw
-- fell off the end.  Then each `drawEntity` here passed ten arguments plus
-- that shifted `yaw` into a TWELVE-parameter list whose eleventh is
-- `isPlayer`, so `isPlayer` took the atlas function (truthy, for everybody)
-- and `yaw` took nil.
--
-- Nothing threw, because Lua pads a short call with nil and drops a long
-- one's tail: the whole cast simply drew with `yaw = nil` -- no camera-facing
-- frame chosen, no billboard turned toward the eye -- in a mode whose entire
-- point is that you walk around things and look at them.  A slipped argument
-- list is not a crash, it is a wrong picture, which is why it survived.
-- tests/arity_check.lua reads the source for exactly this shape.
-- A CARD OUTSIDE THIS FRAME'S CUT IS NOT ON SCREEN.
--
-- ViewBox.shows is the frame's own visibility test -- the box ViewBox.frame
-- fits to the camera footprint, plus ViewBox.PAD, and it answers true when
-- there is no box, so it is safe to guard every draw with unconditionally.
-- It is what the terrain and shadow passes already ask about a whole
-- neighbour map; asked about one card it is the same question at the
-- resolution that matters here.
--
-- Deliberately NOT VoxelScene.bounds: that box is what to BUILD, capped at
-- five view heights of ground, and in a town it swallows the whole map and a
-- good part of its neighbours.  It is the right box for the sun, which
-- reaches that far; it is far too loose to decide what the eye can see.
--
-- ViewBox.frame runs earlier in this same frame (it needs the camera
-- FirstPerson may have moved), so by the time the cast is drawn the cut is
-- this frame's, not the last one's.
local CARD_W, CARD_H = 32, 48
local function cardShows(p)
  local x, y = p.px or 0, p.py or 0
  local ok, seen = pcall(ViewBox.shows, x, y, x + CARD_W, y + CARD_H)
  return (not ok) or seen
end

local function drawCast(state, posed, me, atlasFor, yaw)
  Voxel3D.glass(false)
  Voxel3D.seams(false)
  
  -- Characters, normally depth-tested: the camera-ward pull inside
  -- drawEntity resolves the lean-over-the-wall-in-front case, and a
  -- character genuinely behind a building is far deeper and loses the
  -- test, so buildings and trees really occlude.
  --
  -- In first person two of them change: the player's own card is left out
  -- (the eye is standing in it), and every other card wears the frame its
  -- pose SHOWS this eye (viewFacing) rather than the one it shows the
  -- south. Both run through here, so the water's reflection copy -- drawn
  -- by this same function -- agrees with the frame to the pixel.
  local hideMe = FirstPerson.hidePlayer()
  -- THE CROWD IS MOSTLY OFF-SCREEN.
  --
  -- The pose pass drops a ghost whose whole MAP the window box does not
  -- reach, but within a map that IS reached every one of its people was
  -- still built and submitted -- and a town seam keeps four neighbours
  -- resident, one of them a route forty by a hundred and forty cells.  So a
  -- hundred-odd cards were drawn every frame for a view that holds a few
  -- dozen, each one a mesh lookup, a transform and a DRAW CALL.  Draw calls
  -- are what this pass actually costs; the arithmetic around them is noise
  -- by comparison.
  --
  -- The player is never culled: they are what the box is centred on, so the
  -- test would pass anyway, and saying so means no camera rig can ever put
  -- the one card that must be there outside its own box.
  local shown, culled = 0, 0
  for _, p in ipairs(posed) do
    if not (p.isPlayer and hideMe) and (p.isPlayer or cardShows(p)) then
      shown = shown + 1
      -- Check if this is the player and a custom model is loaded
      if p.isPlayer and PlayerModel.loaded() then
        -- Draw custom 3D model instead of sprite
        PlayerModel.draw(p.px, p.py, p.gh + (p.lift or 0), viewFacing(p), p.flip)
      -- Check if this is the Pikachu follower and Stadium follower is loaded
      elseif p.isFollower and StadiumFollower.loaded() then
        -- Update follower animation
        StadiumFollower.update(1 / 60)
        -- Draw Stadium follower model instead of sprite
        StadiumFollower.draw(p.px, p.py, viewFacing(p))
      -- Check if this is a wild Pokemon and Stadium wilds is enabled
      elseif StadiumWilds.enabled() and StadiumWilds.isWildPokemon(p) then
        -- (a debug print stood here, twice, inside the per-entity draw loop.
        -- On Windows print() to a console is a SYNCHRONOUS write -- the
        -- engine's own Logger carries a comment about that exact cost -- so
        -- every wild Pokemon on screen was buying a console round trip per
        -- frame, inside the pass measured at 78 ms.)
        -- Try to load the model if not already loaded
        if not StadiumWilds.hasModel(p) then
          StadiumWilds.loadEntityModel(p)
        end
        -- If model is available, draw it
        if StadiumWilds.hasModel(p) then
          StadiumWilds.updateEntity(p, 1 / 60)
          StadiumWilds.drawEntity(p)
        else
          -- Fall back to sprite if model not available
          drawEntity(p.sprite, p.px, p.py, viewFacing(p), p.phase, p.flip, p.gh,
                     p.colors, p.lift, p.waterline, p.isPlayer, yaw)
        end
      else
        --.Draw normal sprite entity
        drawEntity(p.sprite, p.px, p.py, viewFacing(p), p.phase, p.flip, p.gh,
                   p.colors, p.lift, p.waterline, p.isPlayer, yaw)
      end
    elseif not (p.isPlayer and hideMe) then
      culled = culled + 1
    end
  end
  -- what went in and what did not, in the F11 report's calls column
  do
    local P = profile()
    if P and P.count then
      P.count("        voxel: cards drawn", shown)
      P.count("        voxel: cards culled", culled)
    end
  end
  
  -- (a frame counter that allocated a closure and pcall'd it every sixtieth
  -- frame, then discarded both results, used to sit here)
  
  -- back on for everything textured from the atlas again -- figures, grass
  -- and flowers all sample it, where the mask's coordinates are honest
  Voxel3D.glass(true)
end

-- The player's silhouette, for wherever the scenery is standing in front of
-- them (Voxel3D.beginGhost inverts the depth test around this call).
--
-- The same flat card the solid pass and the sun pass draw. That it has no
-- self-overlap is what makes it safe here: with the depth test inverted, a
-- mesh carrying both front and back faces would read its own back faces as
-- "behind something" and repaint the figure on open ground, occluded or
-- not. One quad cannot do that, and cannot double-blend into a mottled
-- patch either. A silhouette is an outline, so an outline is the right
-- mesh for it.
local function drawGhost(p, yaw)
  local def = p.sprite.def
  local frame, mirror = frameFor(def, viewFacing(p), p.phase, p.flip, yaw)
  local mesh = SpriteBillboards.shadowQuad(def, frame)
  if not mesh then return end
  local tex = p.sprite:resolveImage()
  if p.colors and not def.trueColor then
    tex = TerrainAtlas.forSprite(def.image, p.colors) or tex
  end
  local y = p.gh + (p.lift or 0)
  
  -- Get sprite dimensions for dynamic sizing (texture dims and world dims)
  local texWidth, texHeight, worldWidth, worldHeight = SpriteBillboards.getSpriteDimensions(def, frame)
  Voxel3D.draw(mesh, tex, billboardMatrix(p.px, p.py, y, mirror, yaw, worldWidth, worldHeight),
               billboardPull())
end

-- Render the world. `state` is the OverworldState; `vw`/`vh` the world view
-- size in world pixels; `w`/`h` the pixel size of the canvas to render
-- into; `paletteFor(map)` yields a map's 4-color world palette (nil in the
-- color modes whose atlas is already true color). Returns the finished
-- canvas, or nil if the 3D pass could not run (headless, no depth support)
-- so the caller can fall back to 2D.
-- The last live-set key, so eviction only runs when the neighbourhood
-- actually changes (a map crossing), not every frame.
local lastLiveKey = nil

-- Request everything `state`'s frame wants and evict what it no longer
-- does; returns the current map's terrain mesh (or nil while it builds)
-- and the neighbour meshes ready to draw. render() calls this for the
-- frame it is drawing, and the pipeline's update hook calls it EVERY
-- frame -- including the frames a warp's Transition covers, when the
-- world pass is off. That update-side call is what lets a door fade hide
-- the destination's build: the map swaps behind the fade, and waiting
-- for the first visible frame to request meshes would show the flat
-- fallback while the first slices run.
function VoxelScene.prefetch(state)
  local Voxel = V.require("VoxelState")

  -- The live set is the current map plus its rendered neighbours. When
  -- it changes, everything outside it (and the previous set, which
  -- ChunkMesher retains so stepping into a house keeps the town warm)
  -- is evicted -- meshes released, analysis dropped -- so memory stays
  -- bounded by the neighbourhood instead of growing with every area
  -- ever visited.
  local liveKey = state.map.id
  local live = { [state.map.id] = true }
  
  -- Limit neighbors based on DrawDistance setting for performance
  local neighborLimit = DrawDistance.neighborLimit()
  local limitedNeighbors = {}
  
  -- If neighborLimit is nil (OFF setting), use all neighbors (original behavior)
  if neighborLimit == nil then
    limitedNeighbors = state.neighbors or {}
  else
    -- Apply neighbor limiting
    for i, nb in ipairs(state.neighbors or {}) do
      if i <= neighborLimit then
        limitedNeighbors[#limitedNeighbors + 1] = nb
      end
    end
  end
  
  for _, nb in ipairs(limitedNeighbors) do
    live[nb.map.id] = true
    liveKey = liveKey .. "|" .. nb.map.id
  end
  
  if liveKey ~= lastLiveKey then
    lastLiveKey = liveKey
    ChunkMesher.setLive(live)
    -- RED++ bakes one atlas per map, so its animated copy is per map too
    -- and is bounded by the same neighbourhood
    TerrainAtlas.setLive(live)
  end

  -- masks: where connected neighbour BODIES sit, so the border ring is
  -- suppressed under them (see runGeometry)
  local masks = {}
  for _, nb in ipairs(limitedNeighbors) do
    masks[#masks + 1] = { nb.ox, nb.oy,
                          nb.ox + nb.map.def.width * 32,
                          nb.oy + nb.map.def.height * 32 }
  end

  -- Builds are asynchronous (ChunkMesher.pump runs in the pipeline's
  -- update): request what this frame wants and draw what is ready.
  -- The current map draws its body-only mesh while the full one (the
  -- border ring) is still building -- a seam crossing promotes a
  -- neighbour whose body is already cached, and only the RING arrives
  -- a few frames later (mostly hidden behind the map just left). The
  -- body itself keeps the same trees and props as the full mesh; it is
  -- not a lower LOD, so the world does not "load in" when you step
  -- across. A neighbour missing its body-only mesh draws its cached
  -- FULL mesh instead -- a crossing demotes the map just left, and it
  -- must not vanish from behind the player while its body variant
  -- builds; its ring is already masked out under this map's body, so
  -- the stand-in is safe.
  -- COLD is a map nothing has ever built anything for: a door, a Fly
  -- landing, a blackout -- anywhere that was not a drawn neighbour a moment
  -- ago. The fallback below has always wanted the body-only variant to
  -- stand in while the full one cooks, and on a map crossed into from a
  -- seam it is there, because the map spent the previous minute being a
  -- neighbour and neighbours are asked for exactly that. On a cold map
  -- nobody ever asked, so the fallback fell back to nothing and the scene
  -- sat on the flat 2D path until the FULL mesh landed -- measured at 128
  -- frames, over two seconds, walking onto a fresh map.
  --
  -- So the cheap variant is queued FIRST and the full one drops a tier
  -- behind it: same two meshes, same budget, the one that can be shown
  -- soonest goes first. The tier is given back the moment there is
  -- something to draw, and request() only ever promotes, so the full mesh
  -- does not lose its place -- it waits behind a stand-in instead of
  -- behind an empty screen.
  local cold = not (ChunkMesher.peek(state.map, false)
                    or ChunkMesher.peek(state.map, true))
  if cold then ChunkMesher.request(state.map, true, nil, true) end
  local terrain = ChunkMesher.request(state.map, false, masks,
                                      cold and ChunkMesher.HOLE or true)
  if not terrain then
    terrain = ChunkMesher.peek(state.map, true)
  end
  
  local nbMesh = {}
  for i, nb in ipairs(state.neighbors or {}) do
    if neighborLimit == nil or i <= neighborLimit then
      -- A neighbour holding NEITHER variant is a gap in the world: nothing
      -- is drawn at its offset and the sky clear behind the scene shows
      -- through it. One holding the other variant is only waiting on an
      -- upgrade -- its ground is covered either way -- so it stays idle and
      -- does not compete with a map that is showing sky. The difference is
      -- exactly the one the priority tier exists for, and it is answered
      -- here rather than in ChunkMesher because this is the loop that knows
      -- what is about to be drawn.
    local held = ChunkMesher.peek(nb.map, true)
                 or ChunkMesher.peek(nb.map, false)
    nbMesh[i] = ChunkMesher.request(nb.map, true, nil,
                                    (not held) and ChunkMesher.HOLE or nil)
                or ChunkMesher.peek(nb.map, false)
  end
  end
  
  Voxel.ready = terrain ~= nil
  return terrain, nbMesh
end

-- Capture every entity's pose for this frame. pose() advances the hop /
-- surf bob / spinner timers, so it must be called EXACTLY once per entity
-- per frame -- the sun pass and the character pass then read the same
-- answer instead of disagreeing by a tick. Ghost NPCs live on a neighbour
-- map, so their position, ground lookup and palette all belong to that
-- map. pose() returns the VISUAL y (ledge hops arc it, surfing bobs it);
-- the difference from the entity's base y becomes vertical LIFT in 3D, so
-- a hop rises off the ground instead of sliding north.
-- Returns the pose list and, separately, the PLAYER's entry in it (nil
-- during a Fly animation, which draws the player itself and is skipped
-- below). Only that one entry gets the see-through treatment: NPCs and the
-- ghosts standing on a neighbour map are left to honest occlusion, because
-- it is only your own character you cannot afford to lose behind a roof.
local function posesOf(state, spriteColors)
  VoxelScene.groundTick()
  -- the ground lookups separately from the rest of posing: pose() advances
  -- every timer and resolves every sprite, and after the memo above it is no
  -- longer obvious which half of this phase is which
  local _pg = phase("poses: ground lookups")
  local colors = spriteColors(state.map)
  local posed = {}
  local me = nil
  -- A GHOST ON A MAP THIS FRAME IS NOT DRAWING CANNOT BE SEEN.
  --
  -- `state.ghosts` is one entry per object on every resident neighbour map --
  -- a hundred of them on a seam, against a couple of dozen real entities --
  -- and the terrain and shadow passes already decline to draw a neighbour the
  -- window box does not reach (ViewBox.showsMap, the same test both of them
  -- ask).  A card standing on ground that is not drawn is not a card anybody
  -- can see, so building it, looking up what it stands on and handing it to
  -- the billboard and shadow passes is work with no picture at the end.
  --
  -- The box is LAST FRAME'S: ViewBox.frame runs after this, because it needs
  -- the camera that FirstPerson may have moved, which needs the player's own
  -- pose from this very loop.  One frame of lag against a box that already
  -- carries a pad, on a neighbour the size of a map -- a ghost can arrive a
  -- frame late at the very edge and never a frame early.
  --
  -- NOT EVEN POSED, and that is a different call from the one castHides makes.
  --
  -- A `castHides` actor is on a map that IS being drawn and is merely behind
  -- something, so it can be revealed by the camera moving a few pixels within
  -- the same frame's geometry -- posing it anyway is what keeps it from
  -- arriving a frame behind.  A ghost on a map outside the window box is not
  -- hidden, it is ABSENT: its ground is not drawn, its shadow is not cast, and
  -- the box has to open across a whole map before it can matter again.
  --
  -- pose() returns the draw position and advances the hop, surf bob and
  -- spinner.  It is not what MOVES the actor -- the engine's own cast update
  -- does that, and keeps doing it -- so what is lost is an animation phase on
  -- a body nobody can see, recovered on the first frame it can.  Skipping it
  -- takes the sprite resolve with it, which is the expensive half.
  local skippedGhosts = 0
  for _, g in ipairs(state.ghosts or {}) do
    local seen = true
    if g.nb then
      local okV, shows = pcall(ViewBox.showsMap, g.nb)
      seen = (not okV) or shows
    end
    if not seen then skippedGhosts = skippedGhosts + 1 end
    if seen then
    local sprite, vx, vy, facing, phase, flip = g.npc:pose()
    local gpx, gpy = vx + g.ox, g.npc.py + g.oy
    local waterRoamer = g.npc.roamer and g.npc.kind == "water"
    local onWater = g.npc.surfing or waterRoamer
    -- On water the swell is already in entityGround; pose()'s bob is for
    -- the 2D blit only and must not be added again as lift.  Waterline cut
    -- while swimming; full body on ice; freeze/thaw anim blends the cut.
    local wl, hop = 0, 0
    if waterRoamer then
      local okc, cut = pcall(Water.waterlineCut, gpx + 8, gpy + 8,
                             Roamer.WATERLINE)
      wl = (okc and cut) or Roamer.WATERLINE
    end
    if onWater then
      local okl, lift = pcall(Water.standAnimLift, gpx + 8, gpy + 8)
      hop = (okl and lift) or 0
    end
    posed[#posed + 1] = {
      sprite = sprite, px = gpx, py = gpy,
      facing = facing, phase = phase, flip = flip,
      gh = entityGround(g.map or state.map, g.npc, gpx, gpy) + hop,
      lift = onWater and 0 or (g.npc.py - vy),
      waterline = wl,
      colors = spriteColors(g.map or state.map),
    }
    end
  end
  for ei, e in ipairs(state.entities or {}) do
    if not (state.flyAnim and e == state.player) then
      local sprite, vx, vy, facing, phase, flip = e:pose()
      local waterRoamer = e.roamer and e.kind == "water"
      local onWater = e.surfing or waterRoamer
      -- Grass roamers: pose() already leaned px (vx); recompute the same
      -- lean on map-y so the 3D card sits at the leaned cell centre.  lift
      -- is then only the breath/hop (drawPy - vy), never the wind twice.
      local drawPx, drawPy = vx, e.py
      if e.roamer and e.kind == "grass" then
        local ok, _, lz = pcall(Wind.leanAt, e.px + 8, e.py + 8,
                                Roamer.WIND_HEIGHT)
        if ok and lz then drawPy = e.py + lz end
      elseif e ~= state.player and not e.roamer and not onWater then
        -- NPC "cloth" substitute: whole billboard leans with the meadow wave
        -- (no skeleton in Gen 1 sprites). heightFrac 0.55 = torso, not feet.
        -- Share 0.55 keeps it subtler than grass tips so people do not skate.
        local ok, lx, lz = pcall(Wind.leanAt, e.px + 8, e.py + 8, 0.55)
        if ok and lx then
          drawPx = drawPx + lx * 0.55
          drawPy = drawPy + lz * 0.55
        end
      end
      -- Swim cut / ice stand / freeze-thaw blend (keeps Surf as the mount).
      local wl, hop = 0, 0
      if waterRoamer then
        local okc, cut = pcall(Water.waterlineCut, drawPx + 8, drawPy + 8,
                               Roamer.WATERLINE)
        wl = (okc and cut) or Roamer.WATERLINE
      end
      if onWater then
        local okl, lift = pcall(Water.standAnimLift, drawPx + 8, drawPy + 8)
        hop = (okl and lift) or 0
      end
      -- Player mid-Surf also gets the freeze/thaw hop + full body on ice
      -- (no waterline cut on the player card, but hop still reads).
      posed[#posed + 1] = {
        sprite = sprite, px = drawPx, py = drawPy,
        facing = facing, phase = phase, flip = flip,
        gh = entityGround(state.map, e, drawPx, drawPy) + hop,
        lift = onWater and 0 or (drawPy - vy),
        waterline = wl,
        colors = colors,
        entity = e, entityIndex = ei,
      }
      if e == state.player then
        me = posed[#posed]
        me.isPlayer = true
      end
    end
  end
  if _pg then _pg() end
  -- HOW MANY, not just how long: "cast: 114 ms" is a slow pass and "114 ms
  -- over 40 actors" is a crowd, and they do not have the same fix.  Shows up
  -- in the report's calls-per-frame column; costs nothing when F11 is off.
  do
    local P = profile()
    if P and P.count then
      P.count("        voxel: ACTORS posed", #posed)
      P.count("        voxel: ACTORS ghosts skipped", skippedGhosts)
    end
  end
  return posed, me
end

-- ------- what is worth submitting
--
-- The world XZ box a pass has to cover, as {x0, z0, x1, z1} in world
-- pixels. Terrain chunks outside it are not drawn (ChunkMesher's cells,
-- Voxel3D.drawGroup's test), and a connected neighbour whose whole body
-- falls outside it costs nothing at all -- which is most of them most of
-- the time, because a map is only ever connected on the side you are not
-- looking at.
--
-- Deliberately generous on all four sides. Every term here is a bound on
-- something the camera might see, and being wrong about that is a hole in
-- the world where being wrong the other way is a few thousand wasted
-- triangles.
--
--   NORTH   how far the camera still sees ground (ShadowMap.groundReach --
--           the same answer the light frustum is fitted to), but taken
--           against a cap twice as far out. The sun pass can let the far
--           field go because its shader fades those shadows out anyway;
--           terrain that stops has an edge on it. At the steep rungs the
--           horizon is genuinely in frame and this reaches past any map.
--           A tall thing standing on ground just past this still shows
--           above it -- that is handled at the draw, per chunk, out of the
--           height each one actually reaches rather than out of the
--           tallest one that could exist anywhere.
--   SIDES   the view widens with distance, so the far ground spans more
--           than the near ground does; half the depth is the same
--           serviceable stand-in ShadowMap.fit uses for the true spread.
--   SOUTH   the camera sits south of its focus, so a little behind.
--
-- `forSun` adds the caster margin on the two sides shadows come FROM. The
-- sun hangs southeast, so what casts onto visible ground stands south and
-- east of it -- the same asymmetry, and the same two sides, as fit().
VoxelScene.FAR_CAP = 5      -- multiples of the view height; ShadowMap's own is 2.5

function VoxelScene.bounds(cx, cy, vw, vh, forSun)
  local reach = ShadowMap.groundReach(vh, VoxelScene.FAR_CAP)
  local north = reach
  local spread = reach * 0.5 + 64
  local sun = 0
  if forSun then
    sun = ShadowMap.HEIGHT
          * math.max(math.abs(ShadowMap.KX), math.abs(ShadowMap.KZ)) + 24
  end
  return { cx - vw / 2 - spread, cy - north,
           cx + vw / 2 + spread + sun, cy + vh / 2 + 64 + sun }
end

-- The same box in a connected neighbour's own coordinates: its geometry is
-- built about its own origin and placed with translate(ox, oy), so the box
-- has to come back the other way rather than the mesh going forward.
local function shifted(b, ox, oy)
  return { b[1] - ox, b[2] - oy, b[3] - ox, b[4] - oy }
end

-- ------- the glint's drive
--
-- A reflection is something the VIEWPOINT does, so the window glint is fed
-- by the camera's own travel rather than by a clock: its phase advances
-- with distance covered and its strength fades in over a few steps of
-- walking and back out within a beat of standing still. Stand still and
-- the glass is still; move and the light crosses it.
-- The rate is slow on purpose: the sweep pattern lives in the pane's own
-- texels (see the scene shader), so this is a FRACTION of a texel per world
-- pixel walked -- one full pass of the glint across a pane per eight or so
-- cells of travel, with no frame ever jumping it far enough to strobe.
VoxelScene.GLINT_RATE = 0.05     -- radians of sweep per world pixel travelled
VoxelScene.GLINT_IN = 0.12      -- strength gained per moving frame
VoxelScene.GLINT_OUT = 0.08     -- and lost per resting frame

function VoxelScene.glintStep(g, cx, cy)
  local dist = 0
  if g.x then
    dist = math.abs(cx - g.x) + math.abs(cy - g.y)
  end
  g.x, g.y = cx, cy
  g.phase = ((g.phase or 0) + dist * VoxelScene.GLINT_RATE) % (2 * math.pi)
  if dist > 0.05 then
    g.amp = math.min(1, (g.amp or 0) + VoxelScene.GLINT_IN)
  else
    g.amp = math.max(0, (g.amp or 0) - VoxelScene.GLINT_OUT)
  end
  return g
end

local glint = {}

-- A stamp of everything the sun pass depends on. Nothing in it moving
-- means the shadow map it produced last frame is still exactly right, and
-- redrawing the whole world from the sun would buy nothing -- which is
-- most of a dialog, a menu, or any moment standing still.
-- COMPARED, NOT CONCATENATED.
--
-- This used to build a comma-joined STRING of everything the sun pass
-- depends on and compare it against last frame's.  With a town's cast that
-- is well over a thousand fields -- and `tostring(terrain)` and a
-- `tostring` per neighbour mesh on top, each of which allocates a fresh
-- "table: 0x..." -- concatenated into a multi-kilobyte string, every frame,
-- purely to answer a yes/no question.  The string was never read.
--
-- So the fields go into a REUSED buffer and are compared element by element
-- against the last committed one.  Same answer, exactly: no hash, no
-- collision, nothing to go subtly stale.  A table goes in as ITSELF, because
-- `==` on tables is identity, which is the question `tostring` was
-- approximating anyway.  After the first frame it allocates nothing.
--
-- The buffers are SWAPPED rather than copied, and only once the pass has
-- actually finished -- a frame that bails between here and finish (no
-- canvas, not ready) must leave the previous signature standing so the next
-- frame still knows it has work to do.
local sigBuf, sigPrev = {}, {}
local sigN, sigPrevN = 0, -1

local function shadowSignature(terrain, nbMesh, posed, cx, cy, vw, vh, box,
                               battleToken)
  local n = 0
  local function put(v)
    n = n + 1
    sigBuf[n] = v
  end
  -- quarter-pixel camera granularity: the light frustum is snapped to
  -- whole texels anyway, each a third of a world pixel
  put(math.floor(cx * 4))
  put(math.floor(cy * 4))
  -- the view size and the camera PITCH are both what the light frustum is
  -- fitted to (a lower camera sees further north, so the box grows), so a
  -- zoom step, a window resize or a rung change invalidates the map even
  -- standing perfectly still
  put(vw); put(vh)
  put(math.floor((Voxel.angle or 0) * 512))
  -- the sun itself: the cycle swings the shear as the clock runs, and a map
  -- lit from somewhere new must be redrawn from there too. Quantised by the
  -- rig's own step (DayNight.rigTime), so a running cycle redraws the map a
  -- few times a minute rather than every frame.
  put(math.floor(ShadowMap.KX * 128))
  put(math.floor(ShadowMap.KZ * 128))
  -- and the first-person head: the box is fitted around wherever it looks
  -- and the sprite cards swap frames as it circles them, so a turn on the
  -- spot re-fits and redraws exactly like a camera move ("" outside 1ST)
  put(FirstPerson.signature())
  -- and the window box, because WHICH neighbours went into the light is a
  -- function of it (see ViewBox.signature): opening the row out brings a
  -- map back inside the cut, and a sun map recorded without it would leave
  -- that map standing in its own unlit shadow
  put(ViewBox.signature())
  -- a staged fight's pics move every frame the animation does, and the sun
  -- has to follow them (VR frames only)
  put(battleToken or false)
  put(terrain)
  for i = 1, #nbMesh do put(nbMesh[i]) end
  for _, p in ipairs(posed) do
    if castsInto(box, p) then
      put(p.sprite.def.image)
      put(p.px); put(p.py); put(p.gh); put(p.lift or 0)
      put(p.facing); put(p.phase); put(p.flip and 1 or 0)
      put(p.waterline or 0)
    end
  end
  sigN = n
  if n ~= sigPrevN then return true end
  for i = 1, n do
    if sigBuf[i] ~= sigPrev[i] then return true end
  end
  return false
end

-- Committed only after the pass has drawn: swap the buffers, so the one just
-- built becomes the reference and last frame's becomes scratch.
local function shadowSignatureCommit()
  sigBuf, sigPrev = sigPrev, sigBuf
  sigPrevN = sigN
end

-- The sun pass: render the scene once from the light, so the main pass can
-- ask any fragment whether the sun reached it. Every caster the main pass
-- draws goes in -- the terrain mesh, which is where buildings, trees,
-- ledges, signs and every prop live, plus one UPRIGHT card per character
-- (Voxel3D.casterMatrix; the leaning slab is a trick for the camera, not
-- for the sun) -- so shadows land on walls, roofs, ledges and passing NPCs
-- as readily as on the floor.
--
-- Runs BEFORE Voxel3D.beginScene, because canvases do not nest. Grass is
-- left out on purpose: thousands of tufts would cast a speckle no bigger
-- than the pixels it lands on, at the cost of the mesh being drawn twice.
local function castShadows(state, terrain, nbMesh, posed, cx, cy, vw, vh,
                           atlasFor, battleCards, battleToken, yaw, neighborLimit)
  if not ShadowMap.available() then return end
  -- computed BEFORE the signature, because the signature is filtered by it
  -- (see castsInto).  Pure arithmetic -- no geometry is touched here -- so
  -- hoisting it above the staleness test costs nothing on a reused frame.
  local box = VoxelScene.bounds(cx, cy, vw, vh, true)
  local changed = shadowSignature(terrain, nbMesh, posed, cx, cy, vw, vh,
                                  box, battleToken)
  -- (the staged fight's token is part of the signature above now, rather
  -- than glued onto a string afterwards)
  if not ShadowMap.stale(changed) then return end
  if not ShadowMap.begin(cx, cy, vw, vh) then return end

  -- On the LOW rung the neighbours are drawn in the SCENE as usual and
  -- simply do not cast. They are whole route-sized meshes -- the mesher's
  -- own note puts one at 10 to 20 MB of vertices -- so letting up to four
  -- of them through here multiplies the sun pass's geometry by five for
  -- shadows that fall almost entirely off the side of the view. What is
  -- lost is a strip along the seam where a neighbour's border trees should
  -- be throwing onto this map's edge; what is bought is most of the pass.
  local casters = Quality.neighbourShadows() and (state.neighbors or {}) or {}

  ShadowMap.drawGroup(terrain, atlasFor(state.map), nil, box)
  for i, nb in ipairs(casters) do
    if neighborLimit == nil or i <= neighborLimit then
      if nbMesh[i] then
        ShadowMap.drawGroup(nbMesh[i], atlasFor(nb.map),
                            Mat4.translate(nb.ox, 0, nb.oy),
                            shifted(box, nb.ox, nb.oy))
      end
    end
  end

  -- flower billboards live outside the terrain mesh (they draw after the
  -- characters, pulled -- see render), but the sun still sees them: a
  -- handful of cutouts per meadow, unlike the grass left out below.
  -- Every thin card from here down is SNUGGED toward the sun along its own
  -- ray (ShadowMap.snug) so its shadow keeps contact with its feet instead
  -- of starting a bias-width away.
  if ChunkMesher.flowers then
    ShadowMap.draw(ChunkMesher.flowers(state.map), atlasFor(state.map),
                   ShadowMap.snug(nil))
    for i, nb in ipairs(casters) do
      if neighborLimit == nil or i <= neighborLimit then
        ShadowMap.draw(ChunkMesher.flowers(nb.map), atlasFor(nb.map),
                       ShadowMap.snug(Mat4.translate(nb.ox, 0, nb.oy)))
      end
    end
  end

  -- From here down it is the CAST, marked as such in the map (see
  -- ShadowMap.sprites) so water can decline them: everything the world casts
  -- still shades a lake, a silhouette of somebody standing beside it does
  -- not. Ground, roofs and the characters themselves take them as before.
  ShadowMap.sprites(true)
  -- authored figures cast too, for the same reason the flowers do: a
  -- handful of cards per map, and a person with no shadow reads as pasted on
  eachFigure(state.map, 0, 0, function(mesh, _, caster)
    ShadowMap.draw(mesh, atlasFor(state.map), ShadowMap.snug(caster))
  end)
  for _, nb in ipairs(casters) do
    if ViewBox.showsMap(nb) then
      eachFigure(nb.map, nb.ox, nb.oy, function(mesh, _, caster)
        ShadowMap.draw(mesh, atlasFor(nb.map), ShadowMap.snug(caster))
      end)
    end
  end
  local sunCards, sunSkipped = 0, 0
  for _, p in ipairs(posed) do
    if castsInto(box, p) then
      sunCards = sunCards + 1
      local def = p.sprite.def
      -- viewFacing, exactly as the camera draw picks it (see viewFacing for
      -- why the two passes must agree): in first person the sun's card
      -- swaps frame as the eye circles, which costs a redraw the signature
      -- already charges for (FirstPerson.signature) and keeps a card from
      -- fringing against a mirror-flipped record of itself
      local frame, mirror = frameFor(def, viewFacing(p), p.phase, p.flip, yaw)
      local mesh = SpriteBillboards.shadowQuad(def, frame, p.waterline or 0)
      if mesh then
        local texWidth, texHeight, worldWidth, worldHeight = SpriteBillboards.getSpriteDimensions(def, frame)
        ShadowMap.draw(mesh, p.sprite:resolveImage(),
                       ShadowMap.snug(
                         Voxel3D.casterMatrix(p.px, p.py, p.gh + (p.lift or 0),
                                              mirror, worldWidth, worldHeight)))
      end
    else
      sunSkipped = sunSkipped + 1
    end
  end
  -- HOW MANY WENT IN AND HOW MANY DID NOT, in the F11 report's calls column:
  -- "casters in light" against "casters culled" says at a glance whether a
  -- slow sun pass is a crowded town or a wide draw distance.
  do
    local P = profile()
    if P and P.count then
      P.count("        voxel: sun casters in light", sunCards)
      P.count("        voxel: sun casters culled", sunSkipped)
    end
  end
  
  -- a staged fight's mons (VR frames only): the same cards the eye pass
  -- stands on the arena, snugged like every thin card, marked as the cast
  -- so the water can decline them like everybody else's silhouette
  for _, card in ipairs(battleCards or {}) do
    ShadowMap.draw(BattleBillboard.mesh(), card.tex, ShadowMap.snug(card.model))
  end
  ShadowMap.sprites(false)
  
  -- and the STADIUM models, outside the sprite flag and un-snugged, for
  -- the reasons the flat battle pass gives (BattleScene.castShadows):
  -- these are geometry, not cut-outs
  pcall(function()
    local stageArena, stageY = V.require("OverworldBattle").stage()
    if stageArena and stageArena.discs then
      V.require("StadiumStage").cast(ShadowMap, stageArena, stageY or 0)
    end
    V.require("Stadium").cast(ShadowMap)
  end)

  -- town street lamps cast from their poles (heads are small and would
  -- speck the pavement).  Neighbour-map lamps are skipped: their sites are
  -- in the neighbour's own coordinates and a wrong offset lands the shadow
  -- on the wrong block.
  pcall(StreetLamps.castShadows, state.map)

  ShadowMap.finish()
  -- ...and only NOW is this frame's signature the one to compare against
  shadowSignatureCommit()
end

-- Render the world. Without `eyes`, one frame into one canvas -- the flat
-- path every rung has always taken. With `eyes` -- a list of
-- { camera, w, h, slot, adopt } records, plus optional cx/cy for the
-- scene centre -- the same frame is drawn once per entry and the list of
-- canvases comes back: the VR path, two eyes over one shared shadow map,
-- pose capture and glint step.
function VoxelScene.render(state, w, h, vw, vh, paletteFor, eyes)
  -- With nothing cached at all (the first frame of a fresh toggle),
  -- return nil: the engine keeps the 2D path for the frame and
  -- Voxel.ready holds the camera tween at flat, so the switch waits
  -- invisibly instead of freezing or tilting an empty stage.
  local _p = phase('mesh build / prefetch')
  local terrain, nbMesh = VoxelScene.prefetch(state)
  if _p then _p() end
  if not terrain then return nil end

  local cam = state.camera
  local cx, cy = cam.x + vw / 2, cam.y + vh / 2
  -- The same compass camera-rotate angle the flat and tilt ground passes
  -- spin their canvas by (see src.render.Camera / Renderer.lua), ported
  -- from ADVANCED_SHAPE: without reading it here, turning the camera had
  -- no effect on the voxel pass at all. :angle() is 0 whenever the camera
  -- hasn't been turned (or has settled back to north), so an unrotated
  -- camera is unaffected.
  local yaw = cam.angle and cam:angle() or 0
  -- If a placed camera exists (e.g., from a free-fly mod), use its yaw if
  -- available.
  if Voxel3D.camera and Voxel3D.camera.yaw then
    yaw = Voxel3D.camera.yaw
  end

  -- the hour's light, before anything is cast or drawn: point the shared
  -- rig at the clock (or at noon, indoors -- a cave at midnight is exactly
  -- as dark as a cave at noon) and set the tint the scene shader multiplies
  -- every surface by. A CANOPY map (Viridian Forest) is the case between:
  -- the rig stays at noon and no sky is painted, but the hour's tint still
  -- falls through the leaves -- night reaches a forest floor.
  local outdoor = state.map.def and Map.isOutdoor(state.map.def) or false
  -- how much SKY there is to be filled by, which is the other half of the
  -- lighting split (see Light.lua). There is none in a cave, so a gym's
  -- shadows stay grey rather than turning the blue that says "outdoors" --
  -- the same Map.isOutdoor test the sky itself is painted on.
  Voxel3D.skyAmount = outdoor and 1 or 0
  DayNight.applyRig(outdoor)
  Voxel3D.tint = DayNight.tint(outdoor or DayNight.isCanopy(state.map))
  
  -- and the window glass: the tileset's own panes (found in its art --
  -- GlassMask), lit after dark. Outdoors only, like everything the clock
  -- touches, which also keeps any pane-shaped art in an interior tileset
  -- from picking up a glint.
  local GlassMask = V.require("GlassMask")
  Voxel3D.glassMask = outdoor and GlassMask.texture(state.map.tileset) or nil
  Voxel3D.glassNight = outdoor and DayNight.windowLight() or 0
  -- The existing day/night ramp is also a darkness factor. Fireflies fade
  -- in naturally at dusk and reach full contrast only at deepest night.
  Voxel3D.fireflyNight = outdoor and DayNight.windowLight() or 0
  Voxel3D.lampColor = DayNight.lampColor()
  
  -- Send only the nearby active posts to the shader.  This belongs before
  -- beginScene: the ground is the first mesh drawn and must receive the same
  -- warm pools as the post itself.
  -- Map data must never be allowed to abort the whole 3D frame.  A bad or
  -- half-streamed map simply gets no local pools for that frame and retries
  -- on the next one; the post meshes and the rest of the renderer stay live.
  if outdoor then
    local ok, lamps = pcall(StreetLamps.lights, state.map, cx, cy)
    Voxel3D.lampLights = ok and lamps or nil
    -- The flame's height belongs to whichever post is shipping, not to a
    -- number the renderer assumes: the authored bake measures its own lantern
    -- and the box models put theirs somewhere else entirely.
    local okH, y = pcall(StreetLamps.flameHeight)
    Voxel3D.lampHeight = okH and y or nil
    -- The gas clock. Wrapped so a long session cannot walk sin() out into the
    -- range where a float has no fraction left and the flicker freezes.
    Voxel3D.lampFlicker = (Voxel3D.lampLights and #Voxel3D.lampLights > 0)
      and ((love.timer and love.timer.getTime and love.timer.getTime() or 0) * 2.4) % 6283.185
      or 0
  else
    Voxel3D.lampLights = nil
    Voxel3D.lampFlicker = 0
  end

  local g = VoxelScene.glintStep(glint, cx, cy)
  Voxel3D.glassPhase, Voxel3D.glassGlint = g.phase, g.amp

  -- and the map's atmosphere, if it has one (see ForestAtmos): the haze
  -- the scene shader folds every surface into, in the hour's colour.
  -- nil for every map without an entry -- a clear day, exactly as before.
  local ForestAtmos = V.require("ForestAtmos")
  local atmos = ForestAtmos.frame(state.map)
  Voxel3D.fog = atmos and atmos.fog or nil

  -- and the DIORAMA modes' viewport and chroma key (lib/Diorama, driven by
  -- the headset -- lib/VR sets them for the length of one frame). Both are
  -- put back to nil at the end of this function, so no other pass in the
  -- frame -- the battle screen's own arena shot above all -- can inherit a
  -- cut world or a green background.
  local dioFrame = (eyes and Diorama.on) and true or false
  Voxel3D.cull = dioFrame and Diorama.cull or nil
  Voxel3D.keyColor = dioFrame and Diorama.keyColor() or nil

  -- ONE LOOKUP PER MAP PER FRAME.
  --
  -- This is called from fourteen places in a frame -- the terrain submit, each
  -- neighbour, the flowers, the ceiling, the flora, and every one of those
  -- again in the sun pass -- and each call rebuilt the palette (`modeColors`)
  -- and walked TerrainAtlas.forMap to reach a sheet that cannot change within
  -- a frame.  The memo lives in this call's own scope, so an animated Gen 3
  -- atlas still advances between frames; it just stops being re-derived
  -- thirteen extra times inside one.  `false` stands in for a genuine nil so a
  -- map with no sheet is not retried on every call either.
  local atlasMemo = {}
  local function atlasFor(map)
    if map == nil then return nil end
    local hit = atlasMemo[map]
    if hit ~= nil then return hit or nil end
    local sheet = TerrainAtlas.forMap(map, modeColors(paletteFor, map))
    atlasMemo[map] = sheet or false
    return sheet
  end

  -- sprite palettes only exist in the SGB modes; under RED++ the OBP bake
  -- inside sprite:resolveImage() already colors the sheet
  -- ONE PALETTE PER MAP PER FRAME, for the same reason the atlas above gets
  -- one: this is called once for EVERY ghost in the posed list -- a hundred of
  -- them on a seam -- and it rebuilds the same table each time.  The map a
  -- ghost stands on cannot change within a frame.
  --
  -- The worker is declared FIRST: the memo below closes over it, and a local
  -- declared after the function that calls it resolves to a global instead --
  -- nil, and a render pass that dies on its first ghost.
  local function spriteColorsRaw(map)
    if PaletteFX.usesGbcPack() then return nil end
    return modeColors(paletteFor, map)
  end
  local spriteColorMemo = {}
  local function spriteColors(map)
    local key = map or false
    local hit = spriteColorMemo[key]
    if hit ~= nil then return hit or nil end
    local v = spriteColorsRaw(map)
    spriteColorMemo[key] = v or false
    return v
  end

  local _p = phase('poses (all of it: pose, sprite, ground)')
  local posed, me = posesOf(state, spriteColors)
  if _p then _p() end

  -- The first-person rig, built (or blended) for this frame and handed to
  -- Voxel3D BEFORE either pass runs: the sun's box is fitted around this
  -- camera, and every card matrix asks it which way to turn. With the
  -- blend fully out the call clears the placed camera and the orbit is
  -- exactly what it always was. The scene centre it returns walks from
  -- the orbit's view centre into the head, so the curve's focus and the
  -- depth reference follow the camera actually in charge.
  --
  -- A VR frame skips all of it: the caller brought its own cameras, and
  -- its own idea of the scene centre with them.
  local okFP, FirstPerson = pcall(V.require, "FirstPerson")
  if okFP and FirstPerson then
  local fpRig, fpCx, fpCy = FirstPerson.frame(me, cx, cy, vw, vh)
    if fpRig then cx, cy = fpCx, fpCy end
    
    -- and the ORBIT RUNGS' own viewport (lib/ViewBox): the flat screen's
    -- answer to the same question the diorama's box asks -- the map cut to
    -- the window that frames it, so a tilted world reads as a model with
    -- sides rather than a map running off every edge. Flat frames only: a
    -- headset's cut is Diorama's above, and the two must never both be live.
    --
    -- After the first-person block, so the box is centred on the camera
    -- actually in charge and opens out with a dive into a head rather than
    -- vanishing on the frame the rung changed.
    --
    -- Ahead of castShadows, deliberately: the sun draws the same neighbours
    -- the eye does (both ask ViewBox.showsMap), so a map skipped out here is
    -- skipped out there and nothing is left casting a shadow it cannot own.
    Voxel3D.cull = ViewBox.frame(cx, cy, vw, vh)
  else
    if eyes.cx then cx, cy = eyes.cx, eyes.cy end
    ViewBox.stop()
  end

  -- A staged fight, seen by the VR eyes: the flat screen draws the battle
  -- SCREEN while one is up (this pass never runs), but the headset keeps
  -- looking at the world, so the world had better have the fight on it.
  -- Fetched per frame for the sun, and again per EYE in drawScene, because
  -- the cards yaw toward whichever eye is asking.
  local battleCards, battleTex, battleToken = nil, nil, nil
  if eyes then
    local okB, cards, tex, token = pcall(function()
      return V.require("OverworldBattle").worldCards()
    end)
    if okB and cards then
      battleCards, battleTex, battleToken = cards, tex, token
    end
  end

  -- The sun's box, pushed along the first-person look so it covers the
  -- ground THIS camera sees (a no-op at blend zero): the orbit's fit
  -- reaches far north and barely south, which is right for every rung
  -- but a head free to face south.
  local shCx, shCy = cx, cy
  if FirstPerson.shadowCenter then
     shCx, shCy = FirstPerson.shadowCenter(cx, cy, vh)
  end
  local neighborLimit = DrawDistance.neighborLimit()
  
  local _p = phase('shadow map')
  castShadows(state, terrain, nbMesh, posed, shCx, shCy, vw, vh, atlasFor,
              battleCards, battleToken, yaw, neighborLimit)
  if _p then _p() end

  -- Everything between beginScene and endScene, as one function: the flat
  -- path runs it once, a VR frame runs it once PER EYE -- same posed
  -- list, same shadow map, same glint, so the two eyes can never disagree
  -- about anything but their viewpoint.
  local function drawScene()
    -- THE HORIZON ART FIRST (lib/HorizonArt.lua, ported from ADVANCED_SHAPE):
    -- the painted panorama that reads as ADVANCED_SHAPE's own horizon,
    -- drawn before Skyline's real map-shaped massing so the placed towns and
    -- routes still stand out as actual geometry in front of the painting.
    local _q = phase('sky: horizon art')
    pcall(HorizonArt.draw, state)
    if _q then _q() end

    -- THE HORIZON FIRST, before anything real. The far silhouettes
    -- (lib/Skyline.lua) are the most distant thing in the frame by an order
    -- of magnitude, so they go down first and the depth buffer lets every
    -- actual map overwrite them -- which is also why they need no culling
    -- box and no sort. Ahead of the snow tint on purpose: a silhouette is a
    -- shape, not a surface, and whitening its crowns would put a snowfield
    -- on a hill nobody can reach.
    local _q = phase('sky: skyline')
    pcall(Skyline.frame)
    pcall(Skyline.draw, state, cx, cy, vh)
    if _q then _q() end

    -- SNOW ON THE WORLD ITSELF, for the length of the terrain pass and no
    -- longer. Every up-facing voxel goes white -- the ground, the top of a
    -- stone wall, the crown of a tree, a roof, a ledge -- which is what snow
    -- does and what no decal ever quite did: a quad laid over a rounded crown
    -- either sinks into it or hovers over it, and the second is the one you
    -- cannot stop seeing. There is nothing to float here. The face the camera
    -- is already looking at is the face that turns white.
    Voxel3D.snowTop = GroundFX.snowTint(state.map)
    local box = VoxelScene.bounds(cx, cy, vw, vh, false)

    -- the sky (lib/SkyLayer.lua) then distant horizon (lib/Backdrop.lua):
    -- before the terrain, depth writes off, so every real surface draws over them
    -- Sky draws first as background, then horizon draws in front of it
    local _q = phase('sky: layer')
    pcall(SkyLayer.draw, state)
    if _q then _q() end
    pcall(Backdrop.draw, state)

    -- Terrain, chunked and culled: only the cells of this map -- and only
    -- the connected maps -- that the camera can still see ground on. This is
    -- the pass that made a route heavy and a house free, because the cost was
    -- never the camera, it was how much map was being submitted behind it.
    local _p = phase('terrain (home map)')
    Voxel3D.drawGroup(terrain, atlasFor(state.map), nil, nil, nil, box)
    if _p then _p() end
    
    -- interiors, then ground detail (lib/Ceiling.lua, lib/Flora.lua)
    local _p = phase('ceiling + flora')
    pcall(Ceiling.draw, state, atlasFor)
    pcall(Flora.draw, state, atlasFor)
    if _p then _p() end
    
    -- the window box's coarse cut, exactly as the sun pass took it: the same
    -- test on the same maps, so the light and the eye can never disagree
    -- about which neighbours are in this frame (see ViewBox.showsMap)
    local _p = phase('terrain (neighbours)')
    for i, nb in ipairs(state.neighbors or {}) do
      if (not neighborLimit or i <= neighborLimit) and ViewBox.showsMap(nb) then
        Voxel3D.drawGroup(nbMesh[i], atlasFor(nb.map), Mat4.translate(nb.ox, 0, nb.oy), nil, nil, shifted(box, nb.ox, nb.oy))
      end
    end
    if _p then _p() end

    -- and off again before anything that is not the world is drawn: a
    -- character's card is a sprite facing the camera, and its shade is 1 for
    -- the same reason a voxel's top is -- so leaving this on would put snow on
    -- everybody's face. It goes back on for the WORLD's other passes below --
    -- the authored figures, the grass and the flowers are all things snow
    -- falls on, and the bushes a town is hedged with live in those passes
    -- rather than in the terrain group.
    local snowOnWorld = Voxel3D.snowTop
    Voxel3D.snowTop = 0

    -- What the weather LEFT on that ground: puddles after a shower, drifts
    -- and footprints in the snow. Here rather than in the overlay pass every
    -- other drawing this mod composites goes through, and the difference is
    -- the whole reason it is a decal: a butterfly IS in front of the world,
    -- and a puddle is underneath the person standing in it. Between the
    -- terrain and the characters, depth-tested and never depth-writing --
    -- the same footing the flat drop shadows below use, for the same
    -- reasons. See lib/GroundFX.lua.
    local _p = phase('ground fx')
    GroundFX.draw3D(state)
    if _p then _p() end

    -- Without a shadow map (headless, or a driver that could not make the
    -- canvas) the old flat decals stand in: ground-only, characters only,
    -- but better than a world with nothing under anybody. They go down
    -- first, as decals the characters then stand over -- depth-tested
    -- against the terrain just drawn (a shadow behind a building stays
    -- hidden) but never depth-writing, so the grass pass at the end of the
    -- frame still wins its feet-overdraw fights.
    --
    -- Not with the SHADOWS row off, though: that is a player saying no
    -- shadows, and standing the fallback in would answer a machine that
    -- cannot have them (see lib/Shadows).
    if Shadows.enabled() and not Voxel3D.shadowsActive() then
      Voxel3D.beginShadows()
      for _, p in ipairs(posed) do
        drawShadow(p.sprite, p.px, p.py, viewFacing(p), p.phase, p.flip, p.gh,
                   p.lift, p.waterline, yaw)
      end
      Voxel3D.endShadows()
    end

    -- Sprite sheets from here to the figure pass: their texture coordinates
    -- mean nothing to the tileset-shaped glass mask, so the glass is off or
    -- the panes' atlas positions stripe the cast with lamplight at night
    Voxel3D.glass(false)

    -- The player's silhouette goes down BEFORE the characters, so the only
    -- thing it can meet in the depth buffer is the WORLD -- terrain, buildings,
    -- trees. Drawn after the solid pass it would meet the player's own card
    -- instead, and every fragment of a figure sits behind the one that just
    -- wrote it, so the silhouette would paint over the player at all times.
    -- Every character then draws on top as usual, which leaves the silhouette
    -- showing in exactly one situation: where the world hides them.
    --
    -- Not in first person: the card it silhouettes is the one the camera is
    -- standing inside, and "the world is in front of the player" is every
    -- wall the player faces.
    if me and not FirstPerson.hidePlayer() then
      Voxel3D.beginGhost()
      drawGhost(me, yaw)
      Voxel3D.endGhost()
    end

    -- Characters carry no wireframe out here, whatever the V-GRID row says.
    -- The seams are what makes the WORLD read as built out of voxels, and
    -- the people walking around in it are the one thing that should read as
    -- drawn instead -- a grid over a 16x16 sprite lands a line every couple
    -- of display pixels and turns a face into a mesh. (The battle pass makes
    -- the opposite call for its own combatants, deliberately: that is a
    -- staged shot rather than the world being walked around in -- see
    -- BattleBillboard.)
    local _p = phase('cast (billboards)')
    drawCast(state, posed, me, atlasFor, yaw)
    if _p then _p() end

    -- The staged fight's mons, standing on their arena cells in THIS eye's
    -- view (VR frames only; battleTex is nil otherwise). Rebuilt per eye
    -- because the cards yaw toward the eye that is looking. No wireframe
    -- and no glass on them for the reasons BattleBillboard and the battle
    -- pass each argue: the cards are not on the voxel grid, and their
    -- texcoords mean nothing to the tileset's pane mask. The hit flash
    -- rides the same flatten the battle pass uses, held short of solid.
    if battleTex then
      local okB, cards = pcall(function() return V.require("OverworldBattle").worldCards() end)
      if okB and cards then
        local BattleScene = V.require("BattleScene")
        Voxel3D.glass(false)
        Voxel3D.seams(false)
        if battleTex.flash then
          Voxel3D.flatten(BattleScene.FLASH_COLOR, BattleScene.FLASH_STRENGTH)
        end
        for _, card in ipairs(cards) do
          Voxel3D.draw(BattleBillboard.mesh(), card.tex, card.model, BattleBillboard.PULL)
        end
        -- and, on the STADIUM rungs, the models -- the same skinned meshes the
        -- flat pass and the sun already used this frame, drawn again through
        -- THIS eye. Unlike the cards there is nothing per-eye about them: a
        -- model faces its opponent, not the viewer, so both eyes see the same
        -- pose from their own seats, which is what makes it read as solid.
        --
        -- On a disc rung the platforms come with them. In a headset the world is
        -- still drawn -- the player is standing IN it, which is the whole point
        -- of the headset, so the rung's "no map" does not apply here -- and the
        -- discs then read as a stage set down on the ground, which is what they
        -- are.
        pcall(function()
          local stageArena, stageY = V.require("OverworldBattle").stage()
          if stageArena and stageArena.discs then
            V.require("StadiumStage").draw(stageArena, stageY or 0)
          end
          V.require("Stadium").draw(BattleBillboard.PULL)
        end)
        if battleTex.flash then Voxel3D.flatten(nil) end
        -- and the MOVE ANIMATIONS, standing on the same arena: the
        -- engine's own effects layer on the plane through both cells
        -- (BattleScene.fxCard), pulled a little harder than the mons so
        -- a burst plays over the card it is bursting on
        local okA, fxTex, fxModel = pcall(function() return V.require("OverworldBattle").worldAnim() end)
        if okA and fxTex and fxModel then
          Voxel3D.draw(BattleBillboard.mesh(), fxTex, fxModel, BattleBillboard.PULL + 6)
        end
        Voxel3D.seams(true)
        Voxel3D.glass(true)
      end
    end

    -- back on for everything textured from the atlas again -- figures, grass
    -- and flowers all sample it, where the mask's coordinates are honest
    Voxel3D.glass(true)
    
    -- Authored figures, alongside the characters and with the same lean and
    -- the same camera-ward pull -- they ARE characters as far as the artwork
    -- is concerned, just ones the tileset draws instead of a sprite sheet.
    -- Drawn after the walkers so a player standing in front of the couch
    -- wins the overlap, which is the order the flat game draws them in.
    local figPull = billboardPull()
    eachFigure(state.map, 0, 0, function(mesh, model, caster)
      Voxel3D.draw(mesh, atlasFor(state.map), model, figPull, ShadowMap.snug(caster))
    end)
    for i, nb in ipairs(state.neighbors or {}) do
      if (not neighborLimit or i <= neighborLimit) and ViewBox.showsMap(nb) then
        eachFigure(nb.map, nb.ox, nb.oy, function(mesh, model, caster)
          Voxel3D.draw(mesh, atlasFor(nb.map), model, figPull, ShadowMap.snug(caster))
        end)
      end
    end

    -- and the snow is back on with them: a hedge, a tuft of grass and a flower
    -- bed are all things a snowfall lands on, and the town's bushes are drawn
    -- in these passes rather than in the terrain group -- which is why the
    -- crowns stayed green while the ground and the walls went white.
    Voxel3D.snowTop = snowOnWorld
    -- and the seams are back on for the terrain art that follows: grass and
    -- flowers are the world's own drawing, not people
    Voxel3D.seams(true)

    -- tall grass last, pulled camera-ward exactly as far as the characters
    -- were (same per-vertex shader bias, so grass never drifts either):
    -- relative depth between a walker and the tuft row south of their feet
    -- is preserved, so the row still overdraws feet -- the 3D version of
    -- the GB's grass-over-feet trick -- while grass keeps losing to the
    -- buildings it genuinely stands behind (far deeper than the pull).
    -- the same angle the cards leaned by (leanAngle honours VR's override),
    -- so the tuft rows keep exactly the characters' own depth handicap
    local lean = math.max(leanAngle(), 0.05)
    local pull = VoxelScene.pull(lean)
    
    -- and the wind, which only these last two passes take: the grass and the
    -- flowers are the only things out here with a base planted in the ground
    -- and a top free to give. Everything above is either terrain, which does
    -- not lean, or a character, whose card is a trick played on the camera
    -- and would read as the person swaying rather than the meadow.
    local sway = Wind.amount()
    
    -- 3D grass bake (if present) + foot-crush physics from everyone walking
    -- through the meadow this frame.
    local grassTex = atlasFor(state.map)
    local Grass3D = nil
    local GrassMod = nil
    do
      local ok, G = pcall(V.require, "Grass3D")
      if ok and G then
        -- the module is wanted either way: the springs below are physics on
        -- whatever the grass pass is drawing, and the classic extruded slab
        -- is crushed underfoot exactly like a bake is
        GrassMod = G
        if G.available and G.available() then
          Grass3D = G
          grassTex = G.texture() or grassTex
        end
      end
    end

    -- ------- how tall the thing that is about to lean stands
    --
    -- The bake knows its own height; the classic slab does not, and takes the
    -- default. Handed over rather than assumed, so the bend curve runs over
    -- the geometry actually in front of the shader (see Voxel3D's sway block).
    do
      local h = nil
      if Grass3D and Grass3D.meta then
        local okm, m = pcall(Grass3D.meta)
        if okm and m and tonumber(m.height) and m.height > 0.5 then h = m.height end
      end
      Voxel3D.grassH = h
      
      -- and what is lying on the blades this frame: rain, settled snow, gust
      local wet, snowLd, gust = 0, 0, 0
      local okl, a, b, c = pcall(Wind.load)
      if okl then wet, snowLd, gust = a or 0, b or 0, c or 0 end
      Voxel3D.grassLoad = { wet, snowLd, gust }
    end

    do
      -- Everyone standing in the world parts the grass; moving parts it
      -- harder. Handed to Grass3D rather than sent straight down, because
      -- what the shader wants is not where the feet are this frame -- it is
      -- how far each tuft has got in bending down and standing back up, and
      -- that is a thing with a memory (Grass3D.crushFrame).
      -- ------- and the player goes FIRST
      --
      -- There are only so many live foot slots, and `posed` is in draw order
      -- -- ghosts on neighbouring maps, then this map's cast, with the
      -- player wherever they happen to fall in it. Filling the slots in that
      -- order means three wild Pokemon standing near you can take all of
      -- them, and then the one walker whose trail anybody is looking at --
      -- yours -- silently drops out. Measured: a walk down Route 1 laid two
      -- crumbs instead of five, all of them a Rattata's.
      local feet = {}
      local function foot(p)
        if not p or #feet >= 4 then return end
        local lift = p.lift or 0
        local moving = math.abs(lift) > 0.15
        feet[#feet + 1] = { (p.px or 0) + 8, (p.py or 0) + 8, moving and 12 or 10, moving and 1.0 or 0.6 }
      end
      foot(me)
      for _, p in ipairs(posed) do if p ~= me then foot(p) end end

      -- Time since the LAST grass pass, not love.timer.getDelta(): the
      -- springs and the trail are integrated in here, and a frame that
      -- renders the scene twice (a staged battle over the overworld) would
      -- otherwise step them twice and run the meadow at double speed. Asked
      -- this way, a second pass in the same frame gets dt = 0 and changes
      -- nothing, which is exactly right -- it is the same instant.
      local now = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
      local dt = (lastGrassAt and (now - lastGrassAt)) or 0
      lastGrassAt = now
      if dt < 0 then dt = 0 elseif dt > 0.1 then dt = 0.1 end
      local crush = nil
      if GrassMod and GrassMod.crushFrame then
        local okc, c = pcall(GrassMod.crushFrame, feet, dt)
        if okc then crush = c end
      end
      if not crush then 
        -- springs unavailable: the old per-frame list, which is still right,
        -- just instant
        crush = { n = #feet, p = feet } 
      end
      Voxel3D.crush = crush
    end

    if ChunkMesher.grass then
      Voxel3D.draw(ChunkMesher.grass(state.map), grassTex, nil, pull, nil, sway)
      for i, nb in ipairs(state.neighbors or {}) do
        if neighborLimit == nil or i <= neighborLimit then
          local ntex = grassTex
          if not Grass3D then ntex = atlasFor(nb.map) end
          Voxel3D.draw(ChunkMesher.grass(nb.map), ntex, Mat4.translate(nb.ox, 0, nb.oy), pull, nil, sway)
        end
      end
    end

    -- decorative grass mesh (no effects)
    local decorMesh = ChunkMesher.decor and ChunkMesher.decor(state.map)
    if decorMesh then
      Voxel3D.draw(decorMesh, grassTex, nil, pull, nil, 0)  -- No sway for decorative grass
    end
    for i, nb in ipairs(state.neighbors or {}) do
      if neighborLimit == nil or i <= neighborLimit then
        local nbDecor = ChunkMesher.decor and ChunkMesher.decor(nb.map)
        if nbDecor then
          Voxel3D.draw(nbDecor, grassTex, Mat4.translate(nb.ox, 0, nb.oy), pull, nil, 0)
        end
      end
    end

    -- road mesh using Grass3D with road texture at 0.05 height
    local roadMesh = ChunkMesher.road and ChunkMesher.road(state.map)
    if roadMesh then
      local roadTex = Grass3D and Grass3D.roadTexture() or nil
      Voxel3D.draw(roadMesh, roadTex, nil, pull, nil, 0)  -- No sway for road
    end
    for i, nb in ipairs(state.neighbors or {}) do
      if neighborLimit == nil or i <= neighborLimit then
        local nbRoad = ChunkMesher.road and ChunkMesher.road(nb.map)
        if nbRoad then
          local roadTex = Grass3D and Grass3D.roadTexture() or nil
          Voxel3D.draw(nbRoad, roadTex, Mat4.translate(nb.ox, 0, nb.oy), pull, nil, 0)
        end
      end
    end

    -- ground mesh using Grass3D with ground texture at 0.1 height
    local groundMesh = ChunkMesher.ground and ChunkMesher.ground(state.map)
    if groundMesh then
      local groundTex = Grass3D and Grass3D.groundTexture() or nil
      Voxel3D.draw(groundMesh, groundTex, nil, pull, nil, 0)  -- No sway for ground
    end
    for i, nb in ipairs(state.neighbors or {}) do
      if neighborLimit == nil or i <= neighborLimit then
        local nbGround = ChunkMesher.ground and ChunkMesher.ground(nb.map)
        if nbGround then
          local groundTex = Grass3D and Grass3D.groundTexture() or nil
          Voxel3D.draw(nbGround, groundTex, Mat4.translate(nb.ox, 0, nb.oy), pull, nil, 0)
        end
      end
    end

    -- The crush stays ON through the flowers. They are the other thing out
    -- here with a base in the ground and a top free to give, they grow in
    -- the same beds people walk through, and a boot that lays the grass flat
    -- and steps over a flower bed untouched is the seam showing.
    -- and the flowers stand on their own height again: they are the tileset's
    -- own slab whatever the grass bake is, so a tall bake must not stretch
    -- their bend curve with it
    Voxel3D.grassH = nil
    
    -- flower billboards: pulled like the characters and the grass, MINUS
    -- the depth of 8 world pixels along the view (8 sin a -- the camera
    -- looks along (0, -cos a, -sin a), so that is exactly one tile row of
    -- northness). A pure depth handicap with zero screen drift: every
    -- flower is judged as if it stood one tile row further north. The
    -- character card's feet plane sits at its cell's MIDDLE (py + 8), so
    -- a flower on the walker's own cell (z +4 or +12 across the cell)
    -- lands behind the card and the player obscures the patch they stand
    -- ON, while the nearest flower of the cell south (+20) stays in front
    -- and keeps overdrawing their feet.
    local fpull = math.max(0, pull - 8 * math.sin(lean))
    
    -- flowers are snugged casters too, so they read their own shadowing
    -- through the same snugged transform the sun stored them with
    -- flowers take a share of the wind rather than all of it: they are
    -- shorter and stiffer than a grass tuft, and they are also the one thing
    -- in a meadow the eye settles on
    local fsway = sway * Wind.FLOWER_SHARE
    
    if ChunkMesher and ChunkMesher.flowers then
      Voxel3D.draw(ChunkMesher.flowers(state.map), atlasFor(state.map), nil, fpull, ShadowMap.snug(nil), fsway)
      for i, nb in ipairs(state.neighbors or {}) do
        if neighborLimit == nil or i <= neighborLimit then
          if ViewBox.showsMap(nb) then
            Voxel3D.draw(ChunkMesher.flowers(nb.map), atlasFor(nb.map), Mat4.translate(nb.ox, 0, nb.oy), fpull, ShadowMap.snug(Mat4.translate(nb.ox, 0, nb.oy)), fsway)
          end
        end
      end
    end

    Voxel3D.crush = nil
    Voxel3D.grassLoad = nil
    
    -- The map's atmosphere -- god rays down from the invisible canopy, and
    -- whatever drifts through them (see ForestAtmos). Additive over the
    -- finished depth buffer, so the trees occlude the light and the light
    -- writes nothing; here in the prop slot, after everything the beams
    -- should fall across and inside drawScene so VR gets them per eye. On
    -- the one map that has any, today.
    ForestAtmos.draw(state.map)

    -- The VR pokedex in the player's left hand, last of all: a prop over
    -- the world drawn with real depth, so leaning it into a wall still
    -- occludes honestly. Its frame only exists while a session is live and
    -- the left hand is tracked (VR.lua sets it), so every flat frame skips
    -- this in one field read. No wireframe and no glass, like the cast:
    -- the device is a drawing riding the scene, not part of the terrain.
    if Pokedex and Pokedex.frame then
      Voxel3D.glass(false)
      Voxel3D.seams(false)
      Pokedex.draw()
      Voxel3D.seams(true)
      Voxel3D.glass(true)
    end

    -- HORDE MODE's handgun, in the same slot and for the same reasons: a
    -- prop over the world with real depth, no wireframe and no glass. In VR
    -- it rides the tracked right hand (lib/VR placed it this frame); on the
    -- flat screen it is carried by the camera, which is why it draws here
    -- rather than in the overlay -- a view model that is 2D cannot be
    -- occluded by the wall the player just backed into.
    local HordeGun = nil
    pcall(function() HordeGun = V.require("HordeGun") end)
    if HordeGun and HordeGun.visible and HordeGun.visible() then
      Voxel3D.glass(false)
      Voxel3D.seams(false)
      HordeGun.draw()
      Voxel3D.seams(true)
      Voxel3D.glass(true)
    end

    -- Street lamps last among the world props: poles take the hour's light,
    -- heads flatten to lampColor after dusk so a DEEP night still has light
    -- on the street.  Seams off -- these are not voxel-grid props.
    Voxel3D.seams(false)
    pcall(StreetLamps.draw, state.map, outdoor)
    Voxel3D.seams(true)
  end

  -- the viewport fields are this function's for the length of this
  -- function, whichever way it leaves (see where they are set)
  local function done(result)
    Voxel3D.cull, Voxel3D.keyColor = nil, nil
    ViewBox.stop()
    return result
  end

  if not eyes then
    if not Voxel3D.beginScene(w, h, cx, cy, vw, vh, skyFor(state.map), nil, yaw) then return nil end
    drawScene()
    return done(Voxel3D.endScene())
  end

  -- The VR frame: the same scene once per eye, each into its own named
  -- canvas slot under its own placed camera. `adopt` hands the eye's
  -- record to FirstPerson as the live rig, which is what turns the
  -- billboards toward THIS eye in first person (cardBlend keys on rig
  -- identity -- see FirstPerson) and leaves them leaning in the diorama,
  -- where the blend is zero.
  local out = {}
  for i, eye in ipairs(eyes) do
    Voxel3D.camera = eye.camera
    if eye.adopt then FirstPerson.adoptVReye(eye.camera) end
    if not Voxel3D.beginScene(eye.w, eye.h, cx, cy, vw, vh, skyFor(state.map), eye.slot, yaw) then return nil end
    drawScene()
    out[i] = Voxel3D.endScene()
  end
  return done(out)
end

return VoxelScene