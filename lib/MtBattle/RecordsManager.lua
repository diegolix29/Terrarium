-- Mt. Battle persistent records + Hall of Fame + current-run ledger.
-- doc). Lives at game.save.mtBattleRecords -- a SIBLING to game.save.
-- mtBattleChallenge, deliberately never touched by SaveState.reset(),
-- since records must survive across runs while challenge state resets
-- every BEGIN CHALLENGE. Same lazy-init idiom as SaveState.lua/
-- BattleSettings.lua's prefs(), applied to a save location that is
-- permanent instead of per-run.
local V=... or {}
local SaveState=V.MtBattleSaveState
local RM={}

local function normalizeTotalFights(value)
  if SaveState and type(SaveState.normalizeTotalFights)=="function" then
    return SaveState.normalizeTotalFights(value)
  end
  local n=tonumber(value)
  for _,allowed in ipairs({3,5,10,25,50,100}) do if n==allowed then return allowed end end
  return 100
end

local function freshFormatStats()
  return {
    runsStarted=0,runsFailed=0,clears=0,bestStreak=0,
    totalBattlesPlayed=0,totalBattleWins=0,totalBattleLosses=0,
    perfectClears=0,fewestContinuesUsed=nil,fewestItemsUsed=nil,largestXpBank=0,
  }
end

local function formatStatsFor(records,totalFights)
  records.formatStats=type(records.formatStats)=="table" and records.formatStats or {}
  local key=tostring(normalizeTotalFights(totalFights))
  local stats=records.formatStats[key]
  if type(stats)~="table" then stats=freshFormatStats();records.formatStats[key]=stats end
  for k,v in pairs(freshFormatStats()) do if stats[k]==nil then stats[k]=v end end
  return stats,key
end

local function defaults()
  return {
    clears=0,bestStreak=0,totalVictories=0,
    runsStarted=0,runsFailed=0,
    totalBattlesPlayed=0,totalBattleWins=0,totalBattleLosses=0,
    totalOpponentPokemonDefeated=0,totalPlayerKnockouts=0,
    fewestContinuesUsed=nil,fewestItemsUsed=nil,
    fastestClearFights=nil, -- placeholder metric: real-time timing needs a
                             -- live clock this pass has no access to;
                             -- fight-count-to-clear is the honest
                             -- deterministic substitute until a real
                             -- wall-clock hook is wired in a later pass
    largestXpBank=0,perfectBattles=0,battle100Victories=0,
    -- Historical field name retained for save compatibility: this actually
    -- counts opposing species defeated across all successful battles.
    mostUsedSpecies={},
    opponentSpeciesFaced={},playerSpeciesSelected={},
    naturallyRolledShiniesEncountered=0,
    shinyAreaLeaderAcesDefeated=0,
    perfectClears=0,
    -- Per-format counters use string keys ("3".."100") so the table remains
    -- stable through save serializers that distinguish dense numeric arrays.
    formatStats={},
    -- Complete archive of finished attempts (clear or failed). Unlike
    -- hallOfFame this is not restricted to successful climbs and is never
    -- truncated; the setup screen uses it for "all recorded runs".
    runHistory={},
    hallOfFame={},
  }
end

function RM.state(game)
  if not (game and game.save) then return defaults() end
  local r=game.save.mtBattleRecords
  if type(r)~="table" then r=defaults();game.save.mtBattleRecords=r end
  local hadFormatStats=type(r.formatStats)=="table"
  local hadRunHistory=type(r.runHistory)=="table"
  -- Fill in any field a fresh defaults() would have that an older saved
  -- record table predates -- never overwrite an existing value.
  for k,v in pairs(defaults()) do
    if r[k]==nil then r[k]=v end
  end
  -- Before selectable formats existed, every recorded Mt. Battle run was a
  -- Battle 100 run. Seed the newly-added per-format bucket from those lifetime
  -- counters exactly once instead of throwing away old record history.
  if not hadFormatStats then
    r.formatStats={}
    if (r.runsStarted or 0)>0 or (r.clears or 0)>0 or (r.totalBattlesPlayed or 0)>0 then
      r.formatStats["100"]={
        runsStarted=r.runsStarted or 0,runsFailed=r.runsFailed or 0,clears=r.clears or 0,
        bestStreak=r.bestStreak or 0,totalBattlesPlayed=r.totalBattlesPlayed or 0,
        totalBattleWins=r.totalBattleWins or 0,totalBattleLosses=r.totalBattleLosses or 0,
        perfectClears=r.perfectClears or 0,fewestContinuesUsed=r.fewestContinuesUsed,
        fewestItemsUsed=r.fewestItemsUsed,largestXpBank=r.largestXpBank or 0,
      }
    end
  end
  -- Hall entries written before multi-format support necessarily represent a
  -- 100-battle clear. Add only facts that are knowable from that historical
  -- contract; attempts/items/XP/generation remain nil when they were not saved.
  if type(r.hallOfFame)~="table" then r.hallOfFame={} end
  for _,entry in ipairs(r.hallOfFame) do
    if type(entry)=="table" then
      entry.totalFights=normalizeTotalFights(entry.totalFights or entry.format)
      if entry.format==nil then entry.format=entry.totalFights end
      if entry.fightsWon==nil then entry.fightsWon=entry.totalFights end
    end
  end
  -- Older versions only persisted successful Hall-of-Fame entries. Seed the
  -- newly-added all-run archive from those knowable historical clears exactly
  -- once; failed historical runs cannot be reconstructed and are not invented.
  if not hadRunHistory then
    r.runHistory={}
    for _,entry in ipairs(r.hallOfFame) do
      if type(entry)=="table" then
        local archived={}
        for k,v in pairs(entry) do archived[k]=v end
        archived.result="clear"
        r.runHistory[#r.runHistory+1]=archived
      end
    end
  end
  return r
end

-- Hall of Fame is a durable run history, not a rolling leaderboard. The setup
-- UI promises ALL recorded successful runs, so never evict older clears.
RM.HALL_OF_FAME_CAP=nil

local function copyMoveList(moves)
  local out={}
  for _,mv in ipairs(moves or {}) do
    local id=type(mv)=="table" and mv.id or mv
    if id then out[#out+1]=id end
  end
  return out
end

local function copyTeam(rows)
  local out={}
  for _,row in ipairs(rows or {}) do
    if type(row)=="table" then
      out[#out+1]={species=row.species,nickname=row.nickname or row.name,
        shiny=row.shiny==true,moves=copyMoveList(row.moves)}
    end
  end
  return out
end

local function copyKnockouts(rows)
  local out={}
  for _,row in ipairs(rows or {}) do
    if type(row)=="table" then
      out[#out+1]={species=row.species,nickname=row.nickname,
        partyIndex=row.partyIndex,count=row.count or 1}
    end
  end
  return out
end

local function playerTeam(save)
  local out={}
  for _,row in ipairs((save and save.rosterSnapshot) or {}) do
    if row and row.species then
      out[#out+1]={species=row.species,rental=row.rental==true,moves=copyMoveList(row.moves)}
    end
  end
  return out
end

function RM.recordRunStarted(game,rosterSnapshot,opts)
  opts=opts or {}
  local save=SaveState and SaveState.state(game) or (game and game.save and game.save.mtBattleChallenge) or {}
  local totalFights=normalizeTotalFights(opts.totalFights or save.totalFights)
  local r=RM.state(game)
  r.runsStarted=(r.runsStarted or 0)+1
  local fs=formatStatsFor(r,totalFights)
  fs.runsStarted=(fs.runsStarted or 0)+1
  for _,row in ipairs(rosterSnapshot or {}) do
    if row and row.species then
      r.playerSpeciesSelected[row.species]=(r.playerSpeciesSelected[row.species] or 0)+1
    end
  end
  return r
end

-- Append one battle ATTEMPT to the current-run ledger and lifetime counters.
-- A Continue therefore produces a second entry with the same fightIndex and a
-- higher attempt number, which is much more useful in a records screen than
-- silently replacing the first loss.
function RM.recordBattleAttempt(game,encounter,result,opts)
  opts=opts or {}
  local save=SaveState and SaveState.state(game) or (game and game.save and game.save.mtBattleChallenge)
  if type(save)~="table" then return nil,"challenge state unavailable" end
  save.battleHistory=type(save.battleHistory)=="table" and save.battleHistory or {}
  save.attemptsByFight=type(save.attemptsByFight)=="table" and save.attemptsByFight or {}
  local fightIndex=math.max(1,math.floor(tonumber(encounter and encounter.fightIndex) or tonumber(save.currentFight) or 1))
  local totalFights=normalizeTotalFights((encounter and encounter.totalFights) or save.totalFights)
  local attempt=(tonumber(save.attemptsByFight[fightIndex]) or 0)+1
  save.attemptsByFight[fightIndex]=attempt
  local opponentTeam=copyTeam(encounter and (encounter.rows or encounter.mons) or {})
  local playerKnockouts=copyKnockouts(opts.playerKnockouts)
  local enemyKnockouts=copyKnockouts(opts.enemyKnockouts)
  local entry={
    fightIndex=fightIndex,attempt=attempt,result=tostring(result or "unknown"),
    totalFights=totalFights,format=totalFights,generation=save.generation,rulesetId=save.rulesetId,
    generationPreference=save.generationPreference,
    area=math.floor((fightIndex-1)/10)+1,
    isAreaLeader=encounter and encounter.isAreaLeader==true or false,
    trainerName=encounter and encounter.identity and encounter.identity.name or nil,
    trainerTitle=encounter and encounter.identity and encounter.identity.title or nil,
    personality=encounter and encounter.personality or nil,
    archetype=encounter and encounter.archetype or nil,
    opponentTeam=opponentTeam,playerTeam=playerTeam(save),
    playerKnockouts=playerKnockouts,enemyKnockouts=enemyKnockouts,
    xpBankAfter=save.xpBank or 0,continuesUsed=save.continuesUsed or 0,
    bpEarned=type(opts.bpAward)=="table" and opts.bpAward.amount or 0,
    bpCleanBonus=type(opts.bpAward)=="table" and opts.bpAward.bonus or 0, -- Legacy receipts only.
    bpNoFaintReward=type(opts.bpAward)=="table" and opts.bpAward.noFaintReward or 0,
    bpPolicy=type(opts.bpAward)=="table" and opts.bpAward.policy or nil,
    bpBalanceAfter=opts.bpBalance or 0,
  }
  save.battleHistory[#save.battleHistory+1]=entry

  local r=RM.state(game)
  local fs=formatStatsFor(r,totalFights)
  r.totalBattlesPlayed=(r.totalBattlesPlayed or 0)+1
  fs.totalBattlesPlayed=(fs.totalBattlesPlayed or 0)+1
  if entry.result=="win" then r.totalBattleWins=(r.totalBattleWins or 0)+1
    fs.totalBattleWins=(fs.totalBattleWins or 0)+1
  elseif entry.result=="lose" then r.totalBattleLosses=(r.totalBattleLosses or 0)+1
    fs.totalBattleLosses=(fs.totalBattleLosses or 0)+1 end
  r.totalOpponentPokemonDefeated=(r.totalOpponentPokemonDefeated or 0)+#enemyKnockouts
  r.totalPlayerKnockouts=(r.totalPlayerKnockouts or 0)+#playerKnockouts
  if entry.result=="win" and #playerKnockouts==0 then
    r.perfectBattles=(r.perfectBattles or 0)+1
  end
  for _,row in ipairs(opponentTeam) do
    if row.species then r.opponentSpeciesFaced[row.species]=(r.opponentSpeciesFaced[row.species] or 0)+1 end
  end
  return entry
end

function RM.currentRun(game)
  local save=SaveState and SaveState.state(game) or (game and game.save and game.save.mtBattleChallenge) or {}
  return {
    active=save.active==true,currentFight=save.currentFight or 1,fightsWon=save.fightsWon or 0,
    totalFights=normalizeTotalFights(save.totalFights),format=normalizeTotalFights(save.totalFights),
    generation=save.generation,rulesetId=save.rulesetId,generationPreference=save.generationPreference,
    roster=playerTeam(save),battleHistory=save.battleHistory or {},
    xpBank=save.xpBank or 0,continuesUsed=save.continuesUsed or 0,
    bpEarned=save.bpEarned or 0,bpSpent=save.bpSpent or 0,
    continuesTotal=save.continuesTotal or 1,battlesPlayed=#(save.battleHistory or {}),
  }
end

function RM.summary(game)
  local r=RM.state(game)
  return {
    clears=r.clears or 0,bestStreak=r.bestStreak or 0,totalVictories=r.totalVictories or 0,
    runsStarted=r.runsStarted or 0,
    runsFailed=r.runsFailed or 0,totalBattlesPlayed=r.totalBattlesPlayed or 0,
    totalBattleWins=r.totalBattleWins or 0,totalBattleLosses=r.totalBattleLosses or 0,
    totalOpponentPokemonDefeated=r.totalOpponentPokemonDefeated or 0,
    totalPlayerKnockouts=r.totalPlayerKnockouts or 0,perfectBattles=r.perfectBattles or 0,
    perfectClears=r.perfectClears or 0,battle100Victories=r.battle100Victories or 0,
    largestXpBank=r.largestXpBank or 0,
    fewestContinuesUsed=r.fewestContinuesUsed,fewestItemsUsed=r.fewestItemsUsed,
    naturallyRolledShiniesEncountered=r.naturallyRolledShiniesEncountered or 0,
    hallOfFame=r.hallOfFame or {},runHistory=r.runHistory or {},opponentSpeciesFaced=r.opponentSpeciesFaced or {},
    playerSpeciesSelected=r.playerSpeciesSelected or {},formatStats=r.formatStats or {},
  }
end

-- Called once per fight WON (not per run) -- tracks species usage and
-- naturally-rolled/ace shiny sightings as they're actually encountered,
-- independent of whether the run ultimately succeeds (matches the doc's
-- "shinies encountered" framing, not "shinies in a completed run").
function RM.recordFightWon(game,defeatedSpecies,shinyFlags,wasAreaLeader,aceSlot)
  local r=RM.state(game)
  for i,species in ipairs(defeatedSpecies or {}) do
    r.mostUsedSpecies[species]=(r.mostUsedSpecies[species] or 0)+1
    if shinyFlags and shinyFlags[i] then
      r.naturallyRolledShiniesEncountered=r.naturallyRolledShiniesEncountered+1
      if wasAreaLeader and i==aceSlot then
        r.shinyAreaLeaderAcesDefeated=r.shinyAreaLeaderAcesDefeated+1
      end
    end
  end
  return r
end

-- Called once when the selected format's final trainer is defeated (whether or
-- not the player has confirmed XP Distribution yet). The historical positional
-- arguments remain intact; `opts` only enriches newer Hall of Fame entries.
function RM.recordCompletion(game,continuesUsed,itemsUsed,xpBank,team,opts)
  opts=opts or {}
  local save=SaveState and SaveState.state(game) or (game and game.save and game.save.mtBattleChallenge) or {}
  local totalFights=normalizeTotalFights(opts.totalFights or save.totalFights)
  local fightsWon=math.max(0,math.floor(tonumber(opts.fightsWon) or tonumber(save.fightsWon) or totalFights))
  local battlesPlayed=math.max(0,math.floor(tonumber(opts.battlesPlayed) or #(save.battleHistory or {})))
  continuesUsed=math.max(0,math.floor(tonumber(continuesUsed) or 0))
  if itemsUsed~=nil then itemsUsed=math.max(0,math.floor(tonumber(itemsUsed) or 0)) end
  xpBank=math.max(0,tonumber(xpBank) or 0)
  local generation=opts.generation or save.generation
  local rulesetId=opts.rulesetId or save.rulesetId
  local generationPreference=opts.generationPreference or save.generationPreference
  local r=RM.state(game)
  r.clears=r.clears+1
  r.totalVictories=r.totalVictories+1
  if totalFights==100 then r.battle100Victories=r.battle100Victories+1 end
  r.bestStreak=math.max(r.bestStreak,fightsWon)
  if r.fewestContinuesUsed==nil or continuesUsed<r.fewestContinuesUsed then
    r.fewestContinuesUsed=continuesUsed
  end
  if itemsUsed~=nil and (r.fewestItemsUsed==nil or itemsUsed<r.fewestItemsUsed) then
    r.fewestItemsUsed=itemsUsed
  end
  r.largestXpBank=math.max(r.largestXpBank,xpBank)
  local perfect=(continuesUsed==0)
  if perfect then r.perfectClears=r.perfectClears+1 end

  local fs=formatStatsFor(r,totalFights)
  fs.clears=(fs.clears or 0)+1
  fs.bestStreak=math.max(fs.bestStreak or 0,fightsWon)
  if fs.fewestContinuesUsed==nil or continuesUsed<fs.fewestContinuesUsed then
    fs.fewestContinuesUsed=continuesUsed
  end
  if itemsUsed~=nil and (fs.fewestItemsUsed==nil or itemsUsed<fs.fewestItemsUsed) then
    fs.fewestItemsUsed=itemsUsed
  end
  fs.largestXpBank=math.max(fs.largestXpBank or 0,xpBank)
  if perfect then fs.perfectClears=(fs.perfectClears or 0)+1 end

  local hallEntry={
    team=team,perfect=perfect,clearNumber=r.clears,
    totalFights=totalFights,format=totalFights,fightsWon=fightsWon,battlesPlayed=battlesPlayed,
    attempts=battlesPlayed,continuesUsed=continuesUsed,itemsUsed=itemsUsed,xpBank=xpBank,
    generation=generation,rulesetId=rulesetId,generationPreference=generationPreference,
  }
  local bpState=SaveState and SaveState.state(game) or {}
  hallEntry.bpEarned=bpState.bpEarned or 0;hallEntry.bpSpent=bpState.bpSpent or 0
  table.insert(r.hallOfFame,1,hallEntry)
  local archived={result="clear"}
  for k,v in pairs(hallEntry) do archived[k]=v end
  local bpRun=SaveState and SaveState.state(game) or {}
  archived.bpEarned=bpRun.bpEarned or 0;archived.bpSpent=bpRun.bpSpent or 0
  table.insert(r.runHistory,1,archived)

  return r,perfect
end

-- Called on a FAILED run (forfeit) -- streak-adjacent bookkeeping only;
-- a failed run is never added to the Hall of Fame and never counts as a
-- clear, matching the design's "the entire XP Bank is forfeited" spirit
-- (no partial credit anywhere in the records either).
function RM.recordFailure(game,fightsWon,opts)
  opts=opts or {}
  local save=SaveState and SaveState.state(game) or (game and game.save and game.save.mtBattleChallenge) or {}
  local totalFights=normalizeTotalFights(opts.totalFights or save.totalFights)
  local r=RM.state(game)
  local battlesPlayed=math.max(0,math.floor(tonumber(opts.battlesPlayed) or #(save.battleHistory or {})))
  local continuesUsed=math.max(0,math.floor(tonumber(opts.continuesUsed) or tonumber(save.continuesUsed) or 0))
  local itemsUsed=opts.itemsUsed
  if itemsUsed~=nil then itemsUsed=math.max(0,math.floor(tonumber(itemsUsed) or 0)) end
  local archived={
    result="failed",perfect=false,team=playerTeam(save),
    totalFights=totalFights,format=totalFights,fightsWon=math.max(0,math.floor(tonumber(fightsWon) or 0)),
    battlesPlayed=battlesPlayed,attempts=battlesPlayed,continuesUsed=continuesUsed,
    itemsUsed=itemsUsed,xpBank=math.max(0,tonumber(opts.xpBank) or 0),
    generation=opts.generation or save.generation,rulesetId=opts.rulesetId or save.rulesetId,
    generationPreference=opts.generationPreference or save.generationPreference,
    failedFight=math.max(1,math.floor(tonumber(opts.failedFight) or tonumber(save.currentFight) or 1)),
  }
  local bpRun=SaveState and SaveState.state(game) or {}
  archived.bpEarned=bpRun.bpEarned or 0;archived.bpSpent=bpRun.bpSpent or 0
  table.insert(r.runHistory,1,archived)
  r.bestStreak=math.max(r.bestStreak,fightsWon or 0)
  r.runsFailed=(r.runsFailed or 0)+1
  local fs=formatStatsFor(r,totalFights)
  fs.bestStreak=math.max(fs.bestStreak or 0,fightsWon or 0)
  fs.runsFailed=(fs.runsFailed or 0)+1
  return r
end

return RM
