-- Pure classifier for the UI-only starter confirmation presentation.
-- Gameplay/script ownership remains entirely native; this module only answers
-- whether a line of dialogue is unambiguously asking the player to choose a
-- canonical starter. Keeping it pure gives field-move prompts a direct regression
-- test instead of relying on the million-line UIMain integration surface.
local C={}

local blockers={"NICK","RELEASE","FORGET","LEARN","DELETE",
  "SURF","WATERFALL","WHIRLPOOL","FISH","SWIM"}
local starters={
  "BULBASAUR","CHARMANDER","SQUIRTLE",
  "CHIKORITA","CYNDAQUIL","TOTODILE",
  "PIKACHU","EEVEE",
}

function C.classify(text,generation)
  local all=tostring(text or ""):upper()
  if all=="" then return nil end
  for _,word in ipairs(blockers) do if all:find(word,1,true) then return nil end end
  local chooseIntent=all:find("WANT",1,true) or all:find("TAKE",1,true)
    or all:find("CHOOSE",1,true) or all:find("STARTER",1,true)
  if not chooseIntent then return nil end
  for _,species in ipairs(starters) do
    if all:find(species,1,true) then return species end
  end

  -- Type-only descriptions exist in a few translated/legacy tables, but a type
  -- word is not enough: ordinary field prompts say things such as "Want to SURF
  -- on the water?". Require an explicit Pokemon/starter noun before mapping.
  if not (all:find("POK",1,true) or all:find("STARTER",1,true)
      or all:find("MONSTER",1,true)) then return nil end
  local gen2=tonumber(generation)==2 or tostring(generation):lower()=="gen2"
  if all:find("FIRE",1,true) then return gen2 and "CYNDAQUIL" or "CHARMANDER" end
  if all:find("WATER",1,true) then return gen2 and "TOTODILE" or "SQUIRTLE" end
  if all:find("GRASS",1,true) or all:find("PLANT",1,true) or all:find("LEAF",1,true) then
    return gen2 and "CHIKORITA" or "BULBASAUR"
  end
  return nil
end

return C
