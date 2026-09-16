-- Mt. Battle persistent run state: game.save.mtBattleChallenge.
-- Mirrors lib/BattleSettings.lua's prefs(game) idiom (lazy-init, validate/
-- migrate fields in place, return the LIVE table so callers read/write
-- through it directly) but for run-state rather than flat preferences --
-- see plan section "game.save.mtBattleChallenge schema".
local S={}
-- Runtime presentation ownership is NOT save data. A loaded active run must
-- ask before taking over the overworld. Key by the run object so slot changes
-- and reset/new runs cannot inherit a previous run's permission.
local presentationOwners=setmetatable({}, {__mode="k"})
function S.sessionEngaged(game)
  local run=game and game.save and game.save.mtBattleChallenge
  return type(run)=="table" and presentationOwners[run]==true
end
function S.enterSession(game)
  local run=S.state(game)
  presentationOwners[run]=true
  run.suspended=false
end
-- Pause and persist as one decision. A veto/throw keeps the old presentation
-- permission and old suspended flag, just as it keeps the live challenge.
function S.pauseSession(game,writer)
  local run=S.state(game)
  local before,owned=run.suspended,presentationOwners[run]
  run.suspended=true;presentationOwners[run]=nil
  local ok,written=pcall(writer,game)
  if not ok or written~=true then
    run.suspended=before;presentationOwners[run]=owned
    return false,"save write failed"
  end
  return true
end

-- A move's remaining PP is NOT its capacity. Native Gen II Mon rows commonly
-- contain only {id,pp}; their definitions live on Battle.data (no Battle.game).
-- Treat a legacy zero maxPp as absent, rather than allowing Lua's truthy 0 to
-- clamp a healthy move to zero on every subsequent challenge launch.
local function positive(v)
  v=tonumber(v)
  return v and v==v and v<math.huge and v>=1 and math.floor(v) or nil
end
function S.movePPLimit(move,data,locked)
  move=type(move)=="table" and move or {id=move}
  locked=type(locked)=="table" and locked or {}
  if locked.id~=nil and locked.id~=move.id then locked={} end
  local ups=tonumber(move.ppUps) or tonumber(locked.ppUps) or 0
  if ups~=ups or ups==math.huge or ups==-math.huge then ups=0 end
  ups=math.max(0,math.min(3,math.floor(ups)))
  local def=data and data.moves and data.moves[move.id]
  local base=positive(def and def.pp)
  local cap=positive(move.maxPp) or positive(move.maxPP)
    or (base and (base+ups*math.floor(base/5)))
    or positive(locked.maxPp) or positive(locked.maxPP)
  -- Missing definitions must not destroy an observed remaining-PP value. This
  -- last fallback does not pretend to reconstruct an unknown move's true max.
  return cap or math.max(positive(move.pp) or 0,positive(locked.pp) or 0),ups
end

-- Shorter climbs are first-class formats, while 100 remains the migration and
-- compatibility default for every save created before format selection existed.
S.SUPPORTED_TOTAL_FIGHTS={3,5,10,25,50,100}
local VALID_TOTAL_FIGHTS={}
for _,n in ipairs(S.SUPPORTED_TOTAL_FIGHTS) do VALID_TOTAL_FIGHTS[n]=true end

-- Mt. Battle content always spans the complete ColosseumDex 001-386 catalog.
-- `generation` elsewhere in this module still identifies the host battle/save
-- kernel (Gen 1 or Gen 2); it must never be reused as a species-content filter.
-- Keep the old preference helpers as compatibility API for callers/saves from
-- earlier test builds, but collapse every value to the only valid policy.
S.GENERATION_PREFERENCES={"all"}
S.GENERATION_PREFERENCE_LABELS={all="GEN 1 + 2 + 3"}

function S.normalizeGenerationPreference(value)
  return "all"
end

function S.generationPreferenceAllows(preference,dex)
  dex=tonumber(dex)
  return dex~=nil and dex>=1 and dex<=386 and dex==math.floor(dex)
end

function S.speciesDex(data,id)
  local def=data and data.pokemon and data.pokemon[id]
  local dex=def and tonumber(def.nationalDex or def.dex or def.number)
  if not dex and type(id)=="number" and id>=1 and id<=386 then dex=id end
  if dex and dex>=1 and dex<=386 and dex==math.floor(dex) then return dex end
  return nil
end

function S.filterEligibleSpecies(data,ids,preference)
  local out={}
  for _,id in ipairs(ids or {}) do out[#out+1]=id end
  return out
end

function S.isSupportedTotalFights(value)
  local n=tonumber(value)
  return n~=nil and n==math.floor(n) and VALID_TOTAL_FIGHTS[n]==true
end

function S.normalizeTotalFights(value)
  local n=tonumber(value)
  if n and n==math.floor(n) and VALID_TOTAL_FIGHTS[n] then return n end
  return 100
end

-- Gen1Recomp follows the cartridge's historical item id spelling `ELIXER`.
-- Keep the challenge bag on engine ids so the doubles/native item handlers can
-- consume it directly instead of carrying an Mt.-Battle-only alias.
local DEFAULT_BAG={FULL_RESTORE=10,HYPER_POTION=15,REVIVE=12,FULL_HEAL=15,ETHER=5,ELIXER=3}

local function copyBag(bag)
  local out={}
  for id,qty in pairs(bag or DEFAULT_BAG) do out[id]=qty end
  return out
end

-- The 100-battle allowance is the balance baseline. Shorter selectable climbs
-- receive the same allowance proportionally to their run length, while every
-- item that exists in the baseline keeps a minimum stock of one. That makes the
-- Challenge Bag meaningfully smaller for 3/5/10/25/50 without making a short
-- run lose an entire recovery category due only to rounding.
function S.scaledBagForTotalFights(totalFights,base)
  totalFights=S.normalizeTotalFights(totalFights)
  base=base or DEFAULT_BAG
  local out={}
  for id,qty in pairs(base) do
    qty=math.max(0,math.floor(tonumber(qty) or 0))
    if qty>0 then
      out[id]=math.max(1,math.ceil((qty*totalFights)/100))
    else
      out[id]=0
    end
  end
  return out
end

local function copyTeamStatus(team)
  local out={}
  for i,row in ipairs(type(team)=="table" and team or {}) do
    if type(row)=="table" then
      local copy={}
      for _,key in ipairs({"species","nickname","hp","maxHp","hpPercent","status","fainted"}) do copy[key]=row[key] end
      copy.moves={}
      for j,mv in ipairs(type(row.moves)=="table" and row.moves or {}) do
        if type(mv)=="table" then copy.moves[j]={id=mv.id,pp=mv.pp,ppUps=mv.ppUps,maxPp=mv.maxPp,maxPP=mv.maxPP} end
      end
      out[i]=copy
    end
  end
  return out
end

-- No live game/save (e.g. a menu preview outside any save context): return a
-- fresh, inert default rather than nil, so callers never need a separate
-- "no save" branch.
local function defaults()
  return {
    active=false,generation=1,masterSeed=0,runNonce=0,
    totalFights=100,rulesetId=nil,generationPreference="all",
    summitVariations={},summitVariationSeed=0,summitVariationTotal=0,
    rosterSource={},rosterSnapshot={},fingerprint=nil,
    currentFight=1,fightsWon=0,continuesTotal=1,continuesUsed=0,
    usedSpecies={},usedArchetypes={},
    -- speciesUseCount: {species -> total times used across the whole run},
    -- separate from usedSpecies (a RECENCY cache of last-used fight index,
    -- for AntiRepeat's soft weighting). This is a hard, run-total count --
    -- the "every species appears at least once, none more than 4 times"
    -- coverage/cap guarantee reads this, never the recency cache.
    speciesUseCount={},
    xpBank=0,xpDistributed=false,
    bag=copyBag(),bagSnapshot=copyBag(),bagInitial=copyBag(),
    currentEncounter=nil,
    -- A battle result is committed immediately, but the next battle is not.
    -- This persisted descriptor is what lets a save/reload resume on the same
    -- explicit Mt. Battle intermission instead of silently chaining fights.
    pendingIntermission=nil,lastTeamStatus={},teamSnapshot={},awaitingFinale=false,ppStateVersion=1,
    -- Reward commit and the final "return to overworld" presentation are two
    -- separate boundaries. Persist this second marker so a reload after XP has
    -- been granted can show the completion receipt without ever granting XP a
    -- second time.
    finaleCompletePending=false,finaleXpResults={},
    -- Current-run battle ledger. Each battle attempt is appended only after a
    -- real battle.ended boundary, so the Records UI can reconstruct everything
    -- the player has actually played without regenerating old opponents.
    battleHistory={},attemptsByFight={},
  }
end

-- Lazily init/validate game.save.mtBattleChallenge and return the LIVE
-- table. Never rewrites a field that's already correctly typed/present --
-- only fills in what's missing, so an in-progress run's state is never
-- silently reset by a later mod update adding a new field.
function S.state(game)
  if not (game and game.save) then return defaults() end
  local s=game.save.mtBattleChallenge
  if type(s)~="table" then s={};game.save.mtBattleChallenge=s end

  if type(s.active)~="boolean" then s.active=false end
  if s.generation~=1 and s.generation~=2 then s.generation=1 end
  if type(s.masterSeed)~="number" then s.masterSeed=0 end
  if type(s.runNonce)~="number" then s.runNonce=0 end
  if type(s.summitVariations)~="table" then s.summitVariations={} end
  if type(s.summitVariationSeed)~="number" then s.summitVariationSeed=0 end
  if type(s.summitVariationTotal)~="number" then s.summitVariationTotal=0 end
  -- Old saves did not carry an explicit length because every run was Battle
  -- 100. Treat missing/invalid values as that legacy format rather than making
  -- an in-progress historical run suddenly end early.
  s.totalFights=S.normalizeTotalFights(s.totalFights)
  if s.rulesetId~=nil and type(s.rulesetId)~="string" then s.rulesetId=nil end
  -- Migrate any generation-filtered run written by an earlier test build to
  -- the permanent all-generations Mt. Battle policy.
  s.generationPreference="all"
  if type(s.rosterSource)~="table" then s.rosterSource={} end
  if type(s.rosterSnapshot)~="table" then s.rosterSnapshot={} end
  if type(s.currentFight)~="number" then s.currentFight=1 end
  if type(s.fightsWon)~="number" then s.fightsWon=0 end
  if type(s.continuesTotal)~="number" then s.continuesTotal=1 end
  if type(s.continuesUsed)~="number" then s.continuesUsed=0 end
  if type(s.usedSpecies)~="table" then s.usedSpecies={} end
  if type(s.usedArchetypes)~="table" then s.usedArchetypes={} end
  if type(s.speciesUseCount)~="table" then s.speciesUseCount={} end
  if type(s.xpBank)~="number" then s.xpBank=0 end
  if type(s.xpDistributed)~="boolean" then s.xpDistributed=false end
  if type(s.bag)~="table" then s.bag=copyBag() end
  if type(s.bagSnapshot)~="table" then s.bagSnapshot=copyBag(s.bag) end
  -- Existing runs predate format-scaled bags. Preserve their historical
  -- Battle-100 allowance for accounting instead of retroactively shrinking an
  -- in-progress inventory just because the mod was updated mid-run.
  if type(s.bagInitial)~="table" then s.bagInitial=copyBag() end
  -- Migrate the early-development typo without losing an in-progress run's
  -- remaining stock. Do the snapshot too so Continue rewind stays identical.
  if s.bag.ELIXER==nil and s.bag.ELIXIR~=nil then
    s.bag.ELIXER=s.bag.ELIXIR;s.bag.ELIXIR=nil
  end
  if s.bagSnapshot.ELIXER==nil and s.bagSnapshot.ELIXIR~=nil then
    s.bagSnapshot.ELIXER=s.bagSnapshot.ELIXIR;s.bagSnapshot.ELIXIR=nil
  end
  if s.bagInitial.ELIXER==nil and s.bagInitial.ELIXIR~=nil then
    s.bagInitial.ELIXER=s.bagInitial.ELIXIR;s.bagInitial.ELIXIR=nil
  end
  if type(s.suspended)~="boolean" then s.suspended=false end
  if s.currentEncounter~=nil and type(s.currentEncounter)~="table" then s.currentEncounter=nil end
  if s.pendingIntermission~=nil and type(s.pendingIntermission)~="table" then s.pendingIntermission=nil end
  if type(s.lastTeamStatus)~="table" then s.lastTeamStatus={} end
  if type(s.teamSnapshot)~="table" then s.teamSnapshot=copyTeamStatus(s.lastTeamStatus) end
  if type(s.awaitingFinale)~="boolean" then s.awaitingFinale=false end
  if type(s.finaleCompletePending)~="boolean" then s.finaleCompletePending=false end
  if type(s.finaleXpResults)~="table" then s.finaleXpResults={} end
  if type(s.battleHistory)~="table" then s.battleHistory={} end
  if type(s.attemptsByFight)~="table" then s.attemptsByFight={} end

  return s
end

-- Resets every field to a fresh, inactive default -- used when a run ends
-- (win, forfeit, or abandon before BEGIN CHALLENGE) and the next hub entry
-- should start clean. Does NOT touch anything outside mtBattleChallenge:
-- the player's real party/PC/bag are never referenced here.
function S.reset(game)
  if not (game and game.save) then return defaults() end
  local fresh=defaults()
  game.save.mtBattleChallenge=fresh
  return fresh
end

-- Refreshes bagSnapshot from the CURRENT live bag. Call this at the start
-- of every fight (not just ones that might be retried) so Continue-rewind
-- is always just "restore bagSnapshot", with no special-casing.
function S.snapshotBag(game)
  local s=S.state(game)
  s.bagSnapshot=copyBag(s.bag)
  return s.bagSnapshot
end

-- Restores the live bag from the last snapshot (Continue rewind). Does not
-- touch anything else -- currentFight/currentEncounter are left exactly as
-- they are, since a Continue replays the SAME fight, not a new one.
function S.restoreBag(game)
  local s=S.state(game)
  s.bag=copyBag(s.bagSnapshot)
  return s.bag
end

-- The persistent challenge team carries battle wear between fights. Snapshot it
-- at the same boundary as the Challenge Bag so Continue can rewind BOTH HP/status
-- and items to the exact start of the failed encounter.
function S.snapshotTeam(game)
  local s=S.state(game)
  s.teamSnapshot=copyTeamStatus(s.lastTeamStatus)
  return s.teamSnapshot
end

function S.restoreTeam(game)
  local s=S.state(game)
  s.lastTeamStatus=copyTeamStatus(s.teamSnapshot)
  return s.lastTeamStatus
end

function S.copyTeamStatus(team) return copyTeamStatus(team) end

-- Repair only challenge-side PP metadata. Never touch the real party/PC or
-- inventory. Existing valid 0/N rows remain exhausted. An old Gen-II 0/0 row
-- has lost its history to the previous launcher's zero-cap clamp: for that
-- explicitly broken schema only, recover once from the immutable run moveset.
-- Positive remaining PP is always retained, and missing source data is retried
-- later rather than fabricated. Both Continue and live snapshots migrate.
function S.repairTeamPP(game,data)
  local s=S.state(game)
  data=data or (game and game.data)
  local legacy=(tonumber(s.ppStateVersion) or 0)<1 and tonumber(s.generation)==2
  local repaired,recovered,unresolved=0,0,false
  for _,team in ipairs({s.lastTeamStatus,s.teamSnapshot}) do
    for i,row in ipairs(type(team)=="table" and team or {}) do
      local locked=s.rosterSnapshot and s.rosterSnapshot[i]
      if type(locked)~="table" or (locked.species~=nil and locked.species~=row.species) then locked=nil end
      for j,mv in ipairs(type(row.moves)=="table" and row.moves or {}) do
        if type(mv)=="table" then
          local lock=locked and locked.moves and locked.moves[j]
          if type(lock)~="table" or lock.id~=mv.id then lock=nil end
          local cap,ups=S.movePPLimit(mv,data,lock)
          local invalid=not (positive(mv.maxPp) or positive(mv.maxPP))
          local zeroCap=tonumber(mv.maxPp)==0 and not positive(mv.maxPP)
          if cap>0 and (invalid or tonumber(mv.maxPp)~=cap or tonumber(mv.maxPP)~=cap
              or tonumber(mv.ppUps)~=ups) then
            if legacy and zeroCap and tonumber(mv.pp)==0 and lock then
              local startPP=tonumber(lock.pp)
              -- Preserve a deliberately exhausted locked move. Otherwise use
              -- the known starting allowance, not an unlimited per-fight heal.
              mv.pp=math.max(0,math.min(cap,math.floor(startPP or cap)))
              if mv.pp>0 then recovered=recovered+1 end
            end
            mv.maxPp=cap;mv.maxPP=cap;mv.ppUps=ups
            if tonumber(mv.pp) then mv.pp=math.max(0,math.min(cap,math.floor(tonumber(mv.pp)))) end
            repaired=repaired+1
          elseif invalid and mv.id~=nil then unresolved=true end
        end
      end
    end
  end
  if not unresolved then s.ppStateVersion=1 end
  if recovered>0 then s.legacyPPRecovered=(tonumber(s.legacyPPRecovered) or 0)+recovered end
  return repaired,recovered
end

-- Saved challenge teams are permanent mod-owned data, not run state. Keep them
-- in a sibling sidecar so S.reset() can freely replace mtBattleChallenge without
-- ever deleting a player's reusable teams or touching cartridge party/PC/Pokedex
-- identity. Rows are deliberately compact stable identities only: species + up
-- to four move ids (and their ordinary PP scalar fields). No live Pokemon table,
-- box reference, runtime annotation, or native-save object is retained here.
local function stableIdentity(value)
  return type(value)=="string" or (type(value)=="number" and value==value)
end

local function copyStableMove(value)
  local src=type(value)=="table" and value or {id=value}
  if not stableIdentity(src.id) then return nil end
  local out={id=src.id}
  for _,key in ipairs({"pp","ppUps","maxPp","maxPP"}) do
    if type(src[key])=="number" then out[key]=src[key] end
  end
  return out
end

local function copyStableTeam(rows)
  if type(rows)~="table" or #rows~=6 then return nil,"custom team must contain exactly six Pokemon" end
  local out={}
  for i=1,6 do
    local src=rows[i]
    if type(src)~="table" or not stableIdentity(src.species) then
      return nil,("custom team slot "..i.." has no stable species identity")
    end
    local moves={}
    for _,mv in ipairs(src.moves or {}) do
      local copy=copyStableMove(mv)
      if copy then moves[#moves+1]=copy end
      if #moves>=4 then break end
    end
    if #moves<1 then return nil,("custom team slot "..i.." has no stable move identity") end
    out[i]={source="custom",species=src.species,moves=moves}
  end
  return out
end

local function customState(game)
  if not (game and game.save) then return {schema=1,nextId=1,teams={}} end
  local state=game.save.mtBattleCustomTeams
  if state==nil then state={};game.save.mtBattleCustomTeams=state
  elseif type(state)~="table" then return nil,"custom-team sidecar is malformed" end
  -- Missing schema is the only legacy shape this first production schema can
  -- safely adopt. Never downgrade/overwrite a future schema we do not know how
  -- to interpret; preserving it byte-for-byte is safer than guessing.
  if state.schema==nil then state.schema=1
  elseif state.schema~=1 then return nil,"unsupported custom-team sidecar schema" end
  if state.teams==nil then state.teams={}
  elseif type(state.teams)~="table" then return nil,"custom-team list is malformed" end
  local maxId=0
  for _,entry in ipairs(state.teams) do
    local id=type(entry)=="table" and tonumber(entry.id) or nil
    if id and id==math.floor(id) and id>maxId then maxId=id end
  end
  local nextId=tonumber(state.nextId)
  if not nextId or nextId~=math.floor(nextId) or nextId<=maxId then nextId=maxId+1 end
  state.nextId=math.max(1,nextId)
  return state
end

local function publicCustomEntry(entry)
  if type(entry)~="table" then return nil end
  local team=copyStableTeam(entry.team)
  if not team then return nil end
  return {id=entry.id,name=tostring(entry.name or ("TEAM "..tostring(entry.id or ""))),team=team}
end

function S.customTeams(game)
  local out={}
  local state,why=customState(game)
  if not state then return out,why end
  for _,entry in ipairs(state.teams) do
    local copy=publicCustomEntry(entry)
    if copy then out[#out+1]=copy end
  end
  table.sort(out,function(a,b) return (tonumber(a.id) or 0)<(tonumber(b.id) or 0) end)
  return out
end

function S.saveCustomTeam(game,rows,name)
  if not (game and game.save) then return nil,"save unavailable" end
  local team,why=copyStableTeam(rows)
  if not team then return nil,why end
  local state,stateWhy=customState(game)
  if not state then return nil,stateWhy end
  local id=state.nextId
  state.nextId=id+1
  local label=type(name)=="string" and name:match("^%s*(.-)%s*$") or ""
  if label=="" then label=("TEAM %02d"):format(id) end
  if #label>24 then label=label:sub(1,24) end
  local entry={id=id,name=label,team=team}
  state.teams[#state.teams+1]=entry
  return publicCustomEntry(entry)
end

function S.loadCustomTeam(game,id)
  id=tonumber(id)
  if not id then return nil,"saved team not found" end
  local state,why=customState(game)
  if not state then return nil,why end
  for _,entry in ipairs(state.teams) do
    if type(entry)=="table" and tonumber(entry.id)==id then
      local copy=publicCustomEntry(entry)
      if not copy then return nil,"saved team data is invalid" end
      return copy.team,copy
    end
  end
  return nil,"saved team not found"
end

function S.deleteCustomTeam(game,id)
  if not (game and game.save) then return false,"save unavailable" end
  id=tonumber(id)
  local state,why=customState(game)
  if not state then return false,why end
  for i,entry in ipairs(state.teams) do
    if type(entry)=="table" and tonumber(entry.id)==id then
      table.remove(state.teams,i)
      return true,publicCustomEntry(entry)
    end
  end
  return false,"saved team not found"
end

-- Reinsert an exact public entry after a host write failure. This is used only
-- as transaction rollback for DELETE; it never manufactures a new identity or
-- changes nextId, so an I/O rejection cannot leave memory diverged from the
-- still-persisted sidecar.
function S.restoreCustomTeam(game,entry)
  if not (game and game.save and type(entry)=="table") then return false,"saved team unavailable" end
  local id=tonumber(entry.id)
  if not id or id~=math.floor(id) or id<1 then return false,"saved team id is invalid" end
  local team,teamWhy=copyStableTeam(entry.team)
  if not team then return false,teamWhy end
  local state,stateWhy=customState(game)
  if not state then return false,stateWhy end
  for _,existing in ipairs(state.teams) do
    if type(existing)=="table" and tonumber(existing.id)==id then return true end
  end
  state.teams[#state.teams+1]={id=id,name=tostring(entry.name or ("TEAM "..tostring(id))),team=team}
  return true
end

S.DEFAULT_BAG=DEFAULT_BAG
S.defaults=defaults
S.customState=customState
S.copyStableTeam=copyStableTeam

return S
