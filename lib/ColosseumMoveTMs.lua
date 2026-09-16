-- Make every source-backed custom Colosseum move that the active host can
-- actually execute AND has a source-proven host learner for obtainable in
-- ordinary play as a purchasable TM. Executable rows with no proven teaching
-- relation stay explicitly blocked rather than receiving invented compatibility.
--
-- This is deliberately an availability layer, not another move-mechanics
-- implementation. ColosseumVerifiedMoves remains the authority for whether a
-- move exists at all. Unresolved/blocked raw move ids never get an item.
--
-- Compatibility policy, strongest source relation first:
--   1. If GC6E01's retail 58-entry machine table contains the move, use the
--      exact PokemonStats machine flags.
--   2. Otherwise use PokemonStats level-up learners in the active host dex as a
--      conservative proof that the species can legally know the source move.
--   3. If neither relation exists, fail closed. Type, theme, evolution family,
--      or native-game intuition are NOT TM compatibility evidence.
--
-- Gen I stock is extended through the actual Celadon 2F TM clerk pointer.
-- Gen II has no public mart content registry, so its already-merged runtime
-- marts table is extended once at game.ready: Goldenrod 5F (all four story
-- variants) and Celadon 3F. No extracted/generated mart table or save identity
-- is mutated on disk.
local V=... or {}
local Source=V.ColosseumPokemonMoveData
local Names=V.ColosseumDexNames or {}
local Verified=V.ColosseumVerifiedMoves
local T={VERSION=1,PRICE=3000,FIRST_TM_NUMBER=51}

local GEN1_DEX_LIMIT=151
local GEN2_DEX_LIMIT=251
local GEN2_TM_MARTS={
  [9]=true,  -- MART_GOLDENROD_5F_1
  [10]=true, -- MART_GOLDENROD_5F_2
  [11]=true, -- MART_GOLDENROD_5F_3
  [12]=true, -- MART_GOLDENROD_5F_4
  [25]=true, -- MART_CELADON_3F
}

local function sourceReady()
  return type(Source)=="table" and Source.discId=="GC6E01"
    and type(Source.moves)=="table" and type(Source.machines)=="table"
    and type(Source.species)=="table"
end

local function copyList(list)
  local out={}
  for i,v in ipairs(type(list)=="table" and list or {}) do out[i]=v end
  return out
end


local function appendUnique(list,values)
  local out=copyList(list);local seen={}
  for _,v in ipairs(out) do seen[v]=true end
  for _,v in ipairs(values or {}) do if not seen[v] then seen[v]=true;out[#out+1]=v end end
  return out
end

local function customMoves(mod,generation)
  local out={}
  local registry=mod and mod.content and mod.content.moves
  if registry and type(registry.each)=="function" then
    for id,def in registry:each() do
      local raw=type(def)=="table" and tonumber(def.colosseumMoveId) or nil
      if raw and tostring(def.colosseumSource or "")=="GC6E01"
          and tostring(id):find("^CMOVE_%d+$") then
        out[#out+1]={id=id,rawMoveId=raw,name=tostring(def.name or id),def=def}
      end
    end
  end
  -- Small fallback for a minimal/test registry that cannot enumerate. The same
  -- source validator used by install() decides which records are executable.
  if #out==0 and Verified and type(Verified.records)=="table"
      and type(Verified.canRegister)=="function" then
    for raw in pairs(Verified.records) do
      if Verified.canRegister(raw,generation) then
        local def=type(Verified.definition)=="function" and Verified.definition(raw,generation) or nil
        if def then out[#out+1]={id=def.id,rawMoveId=raw,name=tostring(def.name or def.id),def=def} end
      end
    end
  end
  table.sort(out,function(a,b)
    if a.rawMoveId~=b.rawMoveId then return a.rawMoveId<b.rawMoveId end
    return tostring(a.id)<tostring(b.id)
  end)
  return out
end

local function machineSlotsFor(raw)
  local out={}
  for slot,row in pairs(sourceReady() and Source.machines or {}) do
    if type(row)=="table" and tonumber(row.rawMoveId or row[4])==tonumber(raw) then
      out[tonumber(row.slot or row[1]) or tonumber(slot)]=true
    end
  end
  return out
end

local function speciesHasMachine(src,slots)
  for _,slot in ipairs(type(src)=="table" and src.machineSlots or {}) do
    if slots[tonumber(slot)] then return true end
  end
  return false
end

local function speciesLearnsLevel(src,raw)
  for _,row in ipairs(type(src)=="table" and src.levelMoves or {}) do
    if tonumber(row.rawMoveId or row[2])==tonumber(raw) then return true end
  end
  return false
end

local function compatibilityFor(raw,generation)
  local limit=tonumber(generation)==2 and GEN2_DEX_LIMIT or GEN1_DEX_LIMIT
  local slots=machineSlotsFor(raw)
  local hasMachine=next(slots)~=nil
  local exact={}
  for dex=1,limit do
    local src=Source.species[dex]
    if hasMachine and speciesHasMachine(src,slots) then exact[#exact+1]=dex
    elseif not hasMachine and speciesLearnsLevel(src,raw) then exact[#exact+1]=dex end
  end
  if #exact>0 then return exact,hasMachine and "retail-machine" or "source-level" end
  return {},hasMachine and "retail-machine-no-host-learner" or "no-proven-host-learner"
end

local function sourceCompatibleMoves(moves,generation)
  local admitted,blocked={},{}
  for _,move in ipairs(moves or {}) do
    local dexes,mode=compatibilityFor(move.rawMoveId,generation)
    if #dexes>0 then
      admitted[#admitted+1]=move
    else
      blocked[#blocked+1]={id=move.id,rawMoveId=move.rawMoveId,name=move.name,reason=mode}
    end
  end
  return admitted,blocked
end

local function patchSpecies(mod,moves,generation)
  local registry=mod and mod.content and mod.content.pokemon
  if not (registry and type(registry.get)=="function" and type(registry.patch)=="function") then
    return 0,{},"pokemon content registry unavailable"
  end
  local byDex={};local modeByMove={}
  for _,move in ipairs(moves) do
    local dexes,mode=compatibilityFor(move.rawMoveId,generation)
    modeByMove[move.id]=mode
    for _,dex in ipairs(dexes) do
      byDex[dex]=byDex[dex] or {}
      byDex[dex][#byDex[dex]+1]=move.id
    end
  end
  local patched=0
  for dex,ids in pairs(byDex) do
    local species=Names[dex]
    if species and registry:get(species) then
      registry:patch(species,{tmhm={__append=ids}})
      patched=patched+1
    end
  end
  return patched,modeByMove,nil
end

local function registerItems(mod,moves,generation)
  local registry=mod and mod.content and mod.content.items
  if not (registry and type(registry.register)=="function") then return nil,"item content registry unavailable" end
  local items={}
  for i,move in ipairs(moves) do
    local number=T.FIRST_TM_NUMBER+i-1
    local itemId=("TM_CBE_%03d"):format(move.rawMoveId)
    local def={
      id=itemId,
      name=("TM%02d"):format(number),
      price=T.PRICE,
      machine={kind="TM",move=move.id,number=number},
      tossable=true,
      needsTarget=true,
    }
    if not (type(registry.has)=="function" and registry:has(itemId)) then registry:register(itemId,def) end
    items[#items+1]={id=itemId,number=number,move=move.id,rawMoveId=move.rawMoveId,name=move.name}
  end
  return items,nil
end

local function installGen1Seller(mod,items)
  local registry=mod and mod.content and mod.content.text_pointers
  if not (registry and type(registry.patch)=="function") then return false,"Gen I text-pointer registry unavailable" end
  local ids={};for _,row in ipairs(items) do ids[#ids+1]=row.id end
  registry:patch("CeladonMart2F",{
    CeladonMart2FClerk2Text={mart={__append=ids}},
  })
  return true
end

local function normalizeGen2Item(game,row)
  local data=game and game.data
  local def=data and data.items and data.items[row.id]
  if type(def)~="table" then return false end
  -- Gold's native extractor spells these fields differently from the shared
  -- Gen-I item schema. Add only the runtime aliases its PACK/Mart already reads.
  def.teaches=row.move
  def.pocket="TM_HM"
  def.tmNumber=row.number
  def.tmLabel=("TM%02d"):format(row.number)
  def.name=def.tmLabel
  return true
end

local function extendGen2Marts(game,items)
  local data=game and game.data
  local marts=data and data.gen2Marts
  local lists=type(marts)=="table" and marts.lists or nil
  if type(lists)~="table" then return 0,"Gen II mart inventory unavailable" end
  local ids={};for _,row in ipairs(items) do ids[#ids+1]=row.id end
  local changed=0
  for martId in pairs(GEN2_TM_MARTS) do
    local index=martId+1
    if type(lists[index])=="table" then
      local merged=appendUnique(lists[index],ids)
      if #merged~=#lists[index] then lists[index]=merged;changed=changed+1 end
    end
  end
  return changed,nil
end

local function installGen2Runtime(mod,items)
  local events=mod and mod.events
  if not (events and type(events.on)=="function") then return false,"game.ready event unavailable" end
  events:on("game.ready",function(payload)
    local game=type(payload)=="table" and payload.game or nil
    if not game then return end
    for _,row in ipairs(items) do normalizeGen2Item(game,row) end
    extendGen2Marts(game,items)
  end)
  return true
end

function T.install(mod,generation)
  generation=tonumber(generation) or 1
  if not sourceReady() then
    return {version=T.VERSION,generation=generation,ready=false,installed=0,
      error=Source and Source.error or "GC6E01 move acquisition source unavailable"}
  end
  local candidates=customMoves(mod,generation)
  local moves,compatibilityBlocked=sourceCompatibleMoves(candidates,generation)
  local items,itemWhy=registerItems(mod,moves,generation)
  if not items then return {version=T.VERSION,generation=generation,ready=false,installed=0,error=itemWhy} end
  local speciesPatched,modes,speciesWhy=patchSpecies(mod,moves,generation)
  local sellerOK,sellerWhy
  if generation==2 then sellerOK,sellerWhy=installGen2Runtime(mod,items)
  else sellerOK,sellerWhy=installGen1Seller(mod,items) end
  return {version=T.VERSION,generation=generation,ready=sellerOK==true and speciesWhy==nil,
    installed=#items,candidates=candidates,moves=moves,items=items,speciesPatched=speciesPatched,compatibility=modes,
    compatibilityBlocked=compatibilityBlocked,blockedCompatibility=#compatibilityBlocked,
    sellerInstalled=sellerOK==true,error=speciesWhy or sellerWhy,
    price=T.PRICE,
    seller=generation==2 and "Goldenrod Dept. Store 5F + Celadon Dept. Store 3F"
      or "Celadon Dept. Store 2F TM clerk"}
end

T._test={customMoves=customMoves,machineSlotsFor=machineSlotsFor,compatibilityFor=compatibilityFor,
  sourceCompatibleMoves=sourceCompatibleMoves,
  appendUnique=appendUnique,registerItems=registerItems,patchSpecies=patchSpecies,
  installGen1Seller=installGen1Seller,normalizeGen2Item=normalizeGen2Item,
  extendGen2Marts=extendGen2Marts,gen2TmMarts=GEN2_TM_MARTS}
return T
