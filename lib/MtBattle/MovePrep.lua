-- Battle 100 move-prep service.
--
-- Lv.50 is a battle-stat normalization rule, not a learnset restriction. A
-- player's prepared challenge loadout may use any move the species learns by
-- Lv.100 plus every compatible TM/HM, independent of inventory ownership.
-- Preparation is challenge-local: it never consumes a TM/HM and never mutates the live party;
-- RunController freezes the selected rows into rosterSnapshot at BEGIN.
local V=... or {}
local SourceCatalog=V.ColosseumMoveCatalog
local BattleData=V.MtBattleBattleData
local LevelClone=V.MtBattleLevelClone
local GenerationCompat=V.GenerationCompat
local MP={MAX_LEVEL=100,MAX_MOVES=4}

-- MOVE PREP edits the Mt. Battle challenge copy, not the native cartridge
-- party. When the challenge projection is available, resolve move definitions
-- against that private 001-386 data view so challenge-only source moves are not
-- incorrectly reported missing just because ordinary Gen-I/II game.data cannot
-- represent them. This never mutates or replaces the live host data table.
local function moveData(game)
  if BattleData and type(BattleData.data)=="function" then
    local ok,data=pcall(BattleData.data,game)
    if ok and type(data)=="table" then return data end
  end
  return game and game.data or {}
end

local function sourceCatalogGame(game,data)
  if not game or data==game.data then return game end
  return setmetatable({data=data,save=game.save},{__index=game})
end

local function copyMove(mv,data)
  if type(mv)~="table" then mv={id=mv} end
  local id=mv and mv.id
  if not id then return nil end
  local def=data and data.moves and data.moves[id]
  if not def then return nil end
  local ppUps=math.max(0,math.min(3,math.floor(tonumber(mv.ppUps) or 0)))
  local maxPP=(tonumber(def.pp) or 0)+ppUps*math.floor((tonumber(def.pp) or 0)/5)
  return {id=id,pp=maxPP,ppUps=ppUps,maxPp=maxPP,maxPP=maxPP}
end

local function legalMachineSet(def)
  local out={}
  for _,id in ipairs((def and def.tmhm) or {}) do out[id]=true end
  return out
end

local function machineInfoByMove(data)
  local out={}
  for itemId,item in pairs((data and data.items) or {}) do
    if type(item)=="table" then
      local machine=item.machine
      local move=machine and machine.move or item.teaches
      if move and not out[move] then
        local label=tostring(item.tmLabel or item.name or itemId or "")
        local kind=machine and machine.kind or label:match("^(TM)") or label:match("^(HM)") or "TM/HM"
        local number=machine and machine.number or tonumber(label:match("^[TH]M(%d+)$"))
        out[move]={itemId=itemId,kind=kind,number=number}
      end
    end
  end
  return out
end

function MP.pool(game,mon)
  local data=moveData(game)
  local def=data.pokemon and mon and data.pokemon[mon.species]
  local rows,byId={},{}
  local function add(id,source,level,itemId,kind)
    local m=data.moves and data.moves[id]
    if not m then return end
    local row=byId[id]
    if not row then
      local typeDef=data.types and data.types[m.type]
      local displayType=(type(typeDef)=="table" and typeDef.name) or m.type
      -- Presentation metadata comes from the SAME private challenge data view
      -- that proved this move executable, not Gen I's smaller native catalog.
      row={id=id,name=tostring(m.name or id),source=source,level=level,itemId=itemId,kind=kind,
        displayType=displayType,basePP=tonumber(m.pp)}
      byId[id]=row;rows[#rows+1]=row
    elseif row.source~="KNOWN" and source=="KNOWN" then
      row.source="KNOWN"
    end
  end

  -- Never make an already-known legal move disappear from the prep screen just
  -- because a modded species record lacks the provenance row that taught it.
  for _,mv in ipairs(mon.moves or {}) do add(type(mv)=="table" and mv.id or mv,"KNOWN") end

  -- Prefer the retail GC6E01 acquisition catalog whenever it can resolve this
  -- species. It covers National Dex 001-386. Rows whose Colosseum move id does
  -- not exist in the active host are intentionally omitted and returned in the
  -- diagnostic instead of being guessed from a name or a nearby native move.
  local sourceRows,diag
  if SourceCatalog and type(SourceCatalog.pool)=="function" then
    sourceRows,diag=SourceCatalog.pool(sourceCatalogGame(game,data),mon)
  end
  if diag and diag.sourceBacked then
    for _,row in ipairs(sourceRows or {}) do
      add(row.id,row.source,row.level,row.itemId,row.kind or row.source)
    end
  else
    -- Native Gen I / Gen II fallback. Gen I stores level-1 rows separately
    -- from learnset; Gen II stores all level-up rows in levelMoves. Machines
    -- are species compatibility, never an inventory gate in MOVE PREP.
    diag=diag or {sourceBacked=false,failedClosed=false,unresolved=0,unresolvedEntries={}}
    diag.fallback="native"
    if not def then
      diag.failedClosed=true
      diag.error=diag.error or "species definition unavailable for native MOVE PREP fallback"
    else
      for _,id in ipairs(def.level1Moves or {}) do add(id,"LEVEL",1) end
      for _,entry in ipairs(def.learnset or {}) do
        local level=tonumber(entry.level)
        if (not level) or level<=MP.MAX_LEVEL then add(entry.move,"LEVEL",level) end
      end
      for _,entry in ipairs(def.levelMoves or {}) do
        local level=tonumber(entry.level)
        if (not level) or level<=MP.MAX_LEVEL then add(entry.move,"LEVEL",level) end
      end
      local machineInfo=machineInfoByMove(data)
      for _,id in ipairs(def.tmhm or {}) do
        local info=machineInfo[id]
        add(id,info and info.kind or "TM/HM",nil,info and info.itemId or nil,info and info.kind or "TM/HM")
      end
    end
  end

  table.sort(rows,function(a,b)
    local order={KNOWN=0,LEVEL=1,HM=2,TM=3}
    local ao,bo=order[a.source] or 4,order[b.source] or 4
    if ao~=bo then return ao<bo end
    if a.source=="LEVEL" and b.source=="LEVEL" then
      local al,bl=tonumber(a.level) or 0,tonumber(b.level) or 0
      if al~=bl then return al<bl end
    end
    if a.name~=b.name then return a.name<b.name end
    return tostring(a.id)<tostring(b.id)
  end)
  diag=diag or {sourceBacked=false,failedClosed=false,unresolved=0,unresolvedEntries={}}
  diag.poolCount=#rows
  return rows,diag
end

function MP.diagnostics(game,mon)
  local _,diag=MP.pool(game,mon);return diag
end

function MP.currentSelection(game,mon,preparedRow)
  local data=moveData(game)
  local source=(preparedRow and preparedRow.species==mon.species and preparedRow.moves) or mon.moves or {}
  local out={}
  for _,mv in ipairs(source) do
    local row=copyMove(mv,data)
    if row then out[#out+1]=row;if #out>=MP.MAX_MOVES then break end end
  end
  return out
end

local function currentGeneration()
  if GenerationCompat and type(GenerationCompat.current)=="function" then
    local ok,generation=pcall(GenerationCompat.current)
    if ok and (generation==1 or generation==2) then return generation end
  end
  return 1
end

local function resolveRosterSource(game,entry)
  if type(entry)~="table" then return nil end
  if entry.source=="rental" or entry.source=="custom" then return entry end
  if entry.source=="party" then
    return game and game.save and game.save.party and game.save.party[entry.index] or nil
  end
  if entry.source=="pc" and LevelClone and type(LevelClone.resolveSource)=="function" then
    return LevelClone.resolveSource(game,currentGeneration(),entry)
  end
  return nil
end

-- Resolve the exact six selected by setup. Detached rental/custom rows already
-- carry stable species+moves; owned rows are read-only references resolved from
-- their native location. If an owned slot changed species after selection, fail
-- closed rather than silently preparing/launching a different Pokemon.
function MP.rosterTeam(game,rosterSource)
  if type(rosterSource)~="table" or #rosterSource~=6 then return nil,"team is not exactly six" end
  local out={}
  for i,entry in ipairs(rosterSource) do
    local mon=resolveRosterSource(game,entry)
    if not mon then return nil,("team slot "..i.." is unavailable") end
    if entry.species~=nil and mon.species~=entry.species then
      return nil,("team slot "..i.." changed after selection")
    end
    out[i]=mon
  end
  return out
end

-- `prepared` is setup-session-only state, never native save data. Binding the
-- selected roster here makes the unchanged pushMovePrep(game,prepared,onDone)
-- screen work for party, mixed, rental, and loaded custom teams alike.
function MP.bindRoster(game,prepared,rosterSource)
  prepared=prepared or {}
  local team,why=MP.rosterTeam(game,rosterSource)
  if not team then return prepared,false,why end
  prepared.__cbeMtBattleRosterSource=rosterSource
  for i=1,6 do
    local row=prepared[i]
    if row and row.species~=team[i].species then prepared[i]=nil end
  end
  return prepared,true
end

function MP.team(game,prepared)
  local source=type(prepared)=="table" and prepared.__cbeMtBattleRosterSource or nil
  if source then return MP.rosterTeam(game,source) end
  return game and game.save and game.save.party or {}
end

function MP.store(game,prepared,partyIndex,moves)
  prepared=prepared or {}
  local team,why=MP.team(game,prepared)
  if not team then return prepared,false,why end
  local mon=team[partyIndex]
  if not mon then return prepared,false,"team slot unavailable" end
  local out={}
  local data=moveData(game)
  for _,mv in ipairs(moves or {}) do
    local row=copyMove(mv,data)
    if row then out[#out+1]=row;if #out>=MP.MAX_MOVES then break end end
  end
  if #out<1 then return prepared,false,"at least one move is required" end
  prepared[partyIndex]={species=mon.species,moves=out}
  return prepared,true
end

function MP.challengeOverrides(game,prepared,rosterSource)
  local out={}
  local data=moveData(game)
  local team=MP.rosterTeam(game,rosterSource)
  for i,entry in ipairs(rosterSource or {}) do
    -- Full setup rosters are exactly six. Keep this helper tolerant of focused
    -- callers/tests that project a smaller source slice by resolving that one
    -- row directly when rosterTeam's exact-six gate intentionally rejects it.
    local mon=(team and team[i]) or resolveRosterSource(game,entry)
    if mon and entry and entry.species~=nil and mon.species~=entry.species then mon=nil end
    local row=prepared and prepared[i]
    -- Compatibility with pre-roster-binding party prep tables, whose key was the
    -- native party index rather than the selected challenge slot.
    if not row and entry and entry.source=="party" then row=prepared and prepared[entry.index] end
    if mon and row and row.species==mon.species and type(row.moves)=="table" and #row.moves>0 then
      out[i]={}
      for _,mv in ipairs(row.moves) do
        local copy=copyMove(mv,data)
        if copy then out[i][#out[i]+1]=copy end
      end
    end
  end
  return next(out) and out or nil
end

-- Materialize a reusable saved-team row set from the exact setup roster. This is
-- intentionally independent of party/PC positions: loading a saved team later
-- must reconstruct the challenge copy from stable species/move identities and
-- must never pull whatever happens to occupy an overworld slot at that time.
function MP.customRoster(game,prepared,rosterSource)
  local team,why=MP.rosterTeam(game,rosterSource)
  if not team then return nil,why end
  local overrides=MP.challengeOverrides(game,prepared,rosterSource) or {}
  local data=moveData(game)
  local out={}
  for i=1,6 do
    local mon=team[i]
    local source=overrides[i] or mon.moves or {}
    local moves={}
    for _,mv in ipairs(source) do
      local copy=copyMove(mv,data)
      if copy then moves[#moves+1]=copy end
      if #moves>=MP.MAX_MOVES then break end
    end
    if #moves<1 then return nil,("team slot "..i.." has no executable moves") end
    out[i]={source="custom",species=mon.species,moves=moves}
  end
  return out
end

MP._test={copyMove=copyMove,legalMachineSet=legalMachineSet,machineInfoByMove=machineInfoByMove,moveData=moveData,
  resolveRosterSource=resolveRosterSource}
return MP
