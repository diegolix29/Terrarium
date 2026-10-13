-- One place that decides how big a Pokemon is on Platinum's native 3D world.
--
-- WHY THIS EXISTS
--   Gen 1-3 size their 3D Pokemon in "voxel world" units, where a trainer is
--   ~16 units tall and a 1.70 m Pokemon is PokemonActors.WORLD_HEIGHT
--   (6.90 / 0.38 = 18.16) units tall. Platinum's NSBMD world is bigger: the
--   trainer is drawn at CHARACTER_HEIGHT * 1.5 (see PlayerModel). Anything that
--   kept the voxel numbers came out 1.5x too small next to the trainer and the
--   terrain, and the renderers that never read PokemonHeights at all (HD cards,
--   Stadium models) ignored species size entirely.
--
-- THE RULE (identical for every renderer)
--   world height = VOXEL_HUMAN_WORLD_HEIGHT
--                  * PokemonHeights.presentationRelative(dex)   -- canonical
--                  * WORLD_FACTOR                               -- Gen 4 world
--
--   presentationRelative is the same curve/floor/ceiling/body-shape math the
--   Colosseum actors already use (PokemonHeights.lua), so an Onix reads as an
--   Onix whether it is drawn as an HD card, a Stadium model or a Colosseum
--   model, and every one of them is in proportion with the 1.5x trainer.
--
-- Outside Platinum's native world every helper here is a pass-through, so the
-- Gen 1-3 voxel sizing is untouched.

local V = ...

local S = {}

-- Must match the Gen 4 human scale in PlayerModel (character `scale * 1.5`).
S.WORLD_FACTOR = 1.5

-- PokemonActors: HUMAN_WORLD_HEIGHT / DEFAULT_FIGURE_SCALE.
S.VOXEL_HUMAN_WORLD_HEIGHT = 6.90 / 0.38

local hostModule
local function host()
  if hostModule == nil then
    local ok, h = pcall(V.require, "Gen4WorldHost")
    hostModule = (ok and type(h) == "table") and h or false
  end
  return hostModule or nil
end

local heightsModule
local function heights()
  if heightsModule == nil then
    local ok, h = pcall(V.require, "PokemonHeights")
    heightsModule = (ok and type(h) == "table"
      and type(h.presentationRelative) == "function") and h or false
  end
  return heightsModule or nil
end

-- True while the current overworld map is drawn by the Gen 4 native world.
function S.active()
  local h = host()
  if not (h and type(h.groundOf) == "function") then return false end
  local ok, ground = pcall(h.groundOf)
  return ok and ground ~= nil
end

-- Plain world factor: 1.5 on Platinum, 1 everywhere else.
function S.factor()
  return S.active() and S.WORLD_FACTOR or 1
end

-- Canonical standing height in Gen 4 world units, plus the relative size and
-- the Pokedex metres. nil when the species has no height on file.
function S.targetHeight(dex)
  local H = heights()
  if not H then return nil end
  local relative = H.presentationRelative(dex)
  if not relative then return nil end
  return S.VOXEL_HUMAN_WORLD_HEIGHT * relative * S.WORLD_FACTOR,
         relative, H.meters(dex)
end

-- Uniform scale for an HD card whose natural world height is `cardHeight`
-- (SpriteBillboards worldHeight; 16 for overworld HD cards).
-- Falls back to the plain world factor when the species has no height.
function S.cardScale(dex, cardHeight)
  cardHeight = tonumber(cardHeight)
  if not (cardHeight and cardHeight > 0) then cardHeight = 16 end
  local target = S.targetHeight(dex)
  if not target then return S.WORLD_FACTOR end
  return target / cardHeight
end

-- Multiplier to apply ON TOP of StadiumMon.scaleFor(model). scaleFor stands the
-- model at StadiumMon.worldHeightFor(model) px (battle-compressed); this
-- re-targets it to the canonical Gen 4 height. 1 outside Platinum.
function S.stadiumMultiplier(model, dex, StadiumMon)
  if not S.active() then return 1 end
  local target = S.targetHeight(dex)
  local base = StadiumMon and StadiumMon.worldHeightFor
    and StadiumMon.worldHeightFor(model)
  base = tonumber(base)
  if target and base and base > 0 then return target / base end
  return S.WORLD_FACTOR
end

-- ColosseumMon.matrix with the Gen 4 world factor applied about the feet.
-- ColosseumMon.matrix already carries the species height (PokemonActors); a
-- plain Mat4.scale of its result would also scale the translation, so build
-- T(pos) * S(factor) * M(origin) -- the same construction PlayerModel uses.
function S.colosseumMatrix(ColosseumMon, dex, variant, x, y, z, fx, fz)
  if not S.active() then
    return ColosseumMon.matrix(dex, variant, x, y, z, fx, fz)
  end
  local base = ColosseumMon.matrix(dex, variant, 0, 0, 0, fx, fz)
  if not base then return nil end
  local Mat4 = V.require("Mat4")
  local f = S.WORLD_FACTOR
  local m = Mat4.translate(x or 0, y or 0, z or 0)
  m = Mat4.mul(m, Mat4.scale(f, f, f))
  return Mat4.mul(m, base)
end

return S
