-- Pokemon Colosseum GC6E01 battle-portrait identity.
--
-- Source: poke_face.fsys plus the GC6E01 PokemonStats portrait-id field.
-- National Dex 001-251 use matching face numbers; Hoenn uses a separate portrait
-- identity table that is NOT the PokemonStats/model internal-species index.
-- Each source face stores normal portraits in the upper row and shiny portraits
-- in the lower row. Only the entries listed below have a second horizontal
-- source frame; every omitted species has exactly one.
local V=... or {}
local Names=V.names or V.ColosseumDexNames or {}
local PortraitIndex=assert(V.portraitIndex or V.ColosseumPortraitIndex,
  "ColosseumPortraitIndex dependency required")
local P={version=4,maxDex=386,sourceArchive="poke_face.fsys"}

local speciesToDex={}
for dex,name in pairs(Names) do
  local n=tonumber(dex)
  if n and type(name)=="string" then speciesToDex[name:upper()]=math.floor(n) end
end

P.multiFrames={
  [1]=2,[2]=2,[35]=2,[36]=2,[39]=2,[40]=2,[44]=2,[64]=2,
  [83]=2,[85]=2,[99]=2,[102]=2,[103]=2,[104]=2,[105]=2,[120]=2,
  [173]=2,[174]=2,[175]=2,[179]=2,[215]=2,[216]=2,
  [266]=2,[268]=2,[283]=2,[303]=2,[351]=2,[353]=2,[354]=2,[355]=2,[373]=2,
}

local function dexNumber(value)
  local n=tonumber(value)
  if not n then return nil end
  n=math.floor(n)
  if n<1 or n>P.maxDex then return nil end
  return n
end

function P.frameCount(dex)
  dex=dexNumber(dex)
  if not dex then return 0 end
  local face=PortraitIndex.faceForDex(dex)
  if not face then return 0 end
  return P.multiFrames[face] or 1
end

function P.sourceFace(dex)
  dex=dexNumber(dex)
  if not dex then return nil end
  if dex==201 then return "face201a" end
  local face=PortraitIndex.faceForDex(dex)
  if not face then return nil end
  return ("face%03d"):format(face)
end

function P.assetPath(dex,frame,shiny)
  dex=dexNumber(dex)
  if not dex then return nil end
  local face=PortraitIndex.faceForDex(dex)
  if not face then return nil end
  frame=math.floor(tonumber(frame) or 1)
  if frame<1 or frame>P.frameCount(dex) then return nil end
  return ("assets/portraits/%03d_%d%s.png"):format(
    face,frame,shiny and "_shiny" or "")
end

function P.supported(dex) return dexNumber(dex)~=nil end

-- Presentation-only identity bridge for expanded Gen III battle proxies. Those
-- mons deliberately do not enter the host cartridge's game.data.pokemon table,
-- so the HUD must be able to resolve the Colosseum mugshot from the stable
-- ColosseumDex species id alone. Numeric identities remain accepted too.
function P.dexForSpecies(species)
  local direct=dexNumber(species)
  if direct then return direct end
  if species==nil then return nil end
  return speciesToDex[tostring(species):upper()]
end

-- One canonical presentation identity for battle HUDs. Species is authoritative:
-- challenge/native mon tables can carry legacy `dex` fields whose meaning is not
-- guaranteed to be National Dex. A stale numeric field must never make LEDIAN
-- draw TOGETIC, MAROWAK draw another species, etc.
function P.dexForMon(game,mon)
  mon=type(mon)=="table" and (type(mon.mon)=="table" and mon.mon or mon) or nil
  if not mon then return nil end
  local species=mon.species or mon.id

  -- Canonical species identity wins over every numeric host field. Gen I uses a
  -- cartridge-internal `index` that is *not* National-Dex order, and challenge/
  -- compatibility facades may preserve that field beside a correct name. Using a
  -- numeric definition first is exactly how a correctly-labelled KINGLER card
  -- could display another species' portrait. Resolve the stable name first.
  local dex
  if type(species)=="string" then
    dex=P.dexForSpecies(species)
    if dex then return dex end
  end

  local defs=game and game.data and game.data.pokemon
  local def=defs and species~=nil and (defs[species] or defs[tostring(species)]) or nil
  -- A definition's own canonical id/name is also safer than any legacy index.
  if type(def)=="table" then
    for _,name in ipairs({def.id,def.name}) do
      if type(name)=="string" then
        dex=P.dexForSpecies(name)
        if dex then return dex end
      end
    end
    dex=dexNumber(def.nationalDex) or dexNumber(def.dex) or dexNumber(def.number)
    if dex then return dex end
  end

  -- Detached extended mons can carry an explicit National identity. Legacy
  -- `mon.dex` is accepted only after all species/name-backed routes fail.
  return dexNumber(mon.nationalDex) or dexNumber(mon.speciesIndex)
    or dexNumber(mon.dexNumber) or dexNumber(mon.dex)
end

return P
