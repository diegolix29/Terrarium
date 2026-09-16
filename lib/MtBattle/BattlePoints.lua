-- Mt. Battle BP, deliberately separate from the forfeitable XP Bank and native
-- money/Bag. Award exactly 1 BP for a victory ONLY when no player Pokemon
-- fainted during that battle AND all six finish alive. Any other win earns 0.
-- This replaces the old base-win-plus-bonus policy. No RNG is consumed.
local V=... or {}
local S=V.MtBattleSaveState
local BP={}
BP.POLICY_VERSION=2
BP.WIN_BP=0 -- Compatibility/display value only; never a payable base reward.
BP.CLEAN_WIN_BP=1 -- The entire no-faint victory reward, not an extra bonus.
BP.MAX_BALANCE=999999999
BP.MAX_ITEM_STOCK=99
-- Supplies are for the CURRENT Challenge Bag only; buying never edits native
-- inventory/party. A fresh run discards leftover challenge supplies, not BP.
BP.CATALOG={
  {id="FULL_HEAL",name="FULL HEAL",cost=2},
  {id="HYPER_POTION",name="HYPER POTION",cost=3},
  {id="ETHER",name="ETHER",cost=3},
  {id="REVIVE",name="REVIVE",cost=5},
  {id="FULL_RESTORE",name="FULL RESTORE",cost=5},
  {id="ELIXER",name="ELIXER",cost=8},
}
local function integer(v,fallback,max)
  v=tonumber(v)
  if not v or v~=v or v==math.huge or v==-math.huge or v<0 then return fallback or 0 end
  return math.min(max or BP.MAX_BALANCE,math.floor(v))
end
local function copy(v)
  if type(v)~="table" then return v end
  local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local function defaults()
  return {version=1,balance=0,lifetimeEarned=0,lifetimeSpent=0,runSequence=0,spendSequence=0,receipts={}}
end
function BP.state(game)
  if not (type(game)=="table" and type(game.save)=="table") then return defaults() end
  local w=game.save.mtBattleBP
  if type(w)~="table" then w=defaults();game.save.mtBattleBP=w end
  w.version=1
  for _,key in ipairs({"balance","lifetimeEarned","lifetimeSpent","runSequence","spendSequence"}) do
    w[key]=integer(w[key],0)
  end
  if type(w.receipts)~="table" then w.receipts={} end
  for i=#w.receipts,1,-1 do
    local row=w.receipts[i]
    if type(row)~="table" or (row.kind~="win" and row.kind~="purchase") then
      table.remove(w.receipts,i)
    end
  end
  while #w.receipts>64 do table.remove(w.receipts,1) end
  return w
end
local function append(w,row)
  w.receipts[#w.receipts+1]=copy(row)
  if #w.receipts>64 then table.remove(w.receipts,1) end
end
function BP.ensureRun(game,run)
  run=run or S.state(game)
  if not (game and game.save and run.active==true) then return nil,"run is not active" end
  local w=BP.state(game)
  if type(run.bpRunId)~="string" or run.bpRunId=="" then
    w.runSequence=integer(w.runSequence,0)+1
    run.bpRunId="BP-RUN-"..tostring(w.runSequence)
    -- An upgrade mid-run starts earning at the next uncompleted fight. Never
    -- invent historic no-faint evidence or award the entire old run on viewing.
    run.bpAwardedThrough=math.max(integer(run.fightsWon),integer(run.currentFight,1)-1)
    run.bpEarned=0;run.bpSpent=0;run.lastBPAward=nil
  end
  run.bpAwardedThrough=integer(run.bpAwardedThrough)
  run.bpEarned=integer(run.bpEarned);run.bpSpent=integer(run.bpSpent)
  return run.bpRunId
end
function BP.bindBattle(game,battle,encounter)
  local run=S.state(game);local id,why=BP.ensureRun(game,run)
  if not id then return false,why end
  battle.__cbeMtBattleBPOwnerSave=game.save -- runtime only, never serialized
  battle.__cbeMtBattleBPRunId=id
  battle.__cbeMtBattleBPAttempt=integer((run.attemptsByFight or {})[run.currentFight])+1
  battle.cbeMtBattleNumber=(encounter and encounter.fightIndex) or run.currentFight
  return true
end
-- A final HP snapshot alone cannot prove no faints: Revive can hide a prior KO.
-- Require the battle observer's complete event ledger plus all six alive.
function BP.cleanWin(battle,team)
  if type(battle)~="table" then return false,"KO history unavailable" end
  local native=type(battle._model)=="table" and battle._model or battle
  if battle.__cbeMtBattleKOTracking~=true and native.__cbeMtBattleKOTracking~=true then
    return false,"KO history unavailable"
  end
  for _,owner in ipairs({battle,native}) do
    local ledger=owner.__cbeMtBattlePlayerKnockouts
    -- A marker without its initialized ledger is not verified event coverage.
    -- Check both screen and native owners; a sparse ledger still records a KO.
    if (owner.__cbeMtBattleKOTracking==true or ledger~=nil) and type(ledger)~="table" then
      return false,"KO history unavailable"
    end
    if type(ledger)=="table" and next(ledger)~=nil then
      return false,"team fainted during battle"
    end
  end
  if type(team)~="table" or #team~=6 then return false,"incomplete team status" end
  for i=1,6 do
    local row=team[i];local hp=type(row)=="table" and tonumber(row.hp)
    if not hp or hp~=hp or hp==math.huge or hp<=0 or row.fainted==true then return false,"team has a fainted Pokemon" end
  end
  return true,"no Pokemon fainted"
end
-- Invoked only from the accepted run result, before currentFight is advanced.
-- Receipt high-water mark is run-scoped and survives retries, reloads, and the
-- bounded UI history. Discarding old display receipts never enables re-credit.
function BP.recordWin(game,run,fight,evidence)
  local id,why=BP.ensureRun(game,run);if not id then return false,why end
  fight=integer(fight)
  if fight<1 or fight>integer(run.totalFights,100) or fight~=run.currentFight then return false,"fight mismatch" end
  if fight<=run.bpAwardedThrough then return false,"already awarded" end
  if type(run.currentEncounter)~="table" or run.currentEncounter.fightIndex~=fight then return false,"encounter mismatch" end
  local w=BP.state(game)
  local clean=type(evidence)=="table" and evidence.clean==true
  local amount=clean and math.min(integer(BP.CLEAN_WIN_BP),BP.MAX_BALANCE-w.balance) or 0
  -- Keep old receipt fields at zero for compatibility, but record the single
  -- reward explicitly. Zero-BP wins still advance the durable receipt guard:
  -- replaying them later with different evidence must never create a payout.
  local row={kind="win",runId=id,fight=fight,totalFights=run.totalFights,
    base=0,bonus=0,noFaintReward=amount,amount=amount,clean=clean,
    reason=(type(evidence)=="table" and evidence.reason) or "KO history unavailable",policy=BP.POLICY_VERSION,
    balanceAfter=w.balance+amount}
  w.balance=row.balanceAfter;w.lifetimeEarned=integer(w.lifetimeEarned+amount)
  run.bpEarned=integer(run.bpEarned+amount);run.bpAwardedThrough=fight
  run.lastBPAward=copy(row);append(w,row)
  return row
end
function BP.summary(game)
  local w=BP.state(game);local run=S and S.state(game) or {}
  return {balance=w.balance,lifetimeEarned=w.lifetimeEarned,lifetimeSpent=w.lifetimeSpent,
    runEarned=integer(run.bpEarned),runSpent=integer(run.bpSpent),lastAward=copy(run.lastBPAward),
    receipts=copy(w.receipts),winBP=BP.WIN_BP,cleanWinBP=BP.CLEAN_WIN_BP}
end
function BP.canExchange(game)
  local run=S.state(game);local p=run.pendingIntermission
  return run.active==true and type(p)=="table" and (p.kind=="between" or p.kind=="areaBreak")
    and run.currentEncounter==nil and run.awaitingFinale~=true
end
function BP.purchaseToken(game)
  if not BP.canExchange(game) then return nil,"exchange opens between victories" end
  local run=S.state(game);local id,why=BP.ensureRun(game,run)
  if not id then return nil,why end
  return {runId=id,fight=run.currentFight,sequence=BP.state(game).spendSequence+1}
end
function BP.purchase(game,itemId,token)
  if not BP.canExchange(game) then return false,"EXCHANGE OPENS BETWEEN VICTORIES" end
  local run=S.state(game);local w=BP.state(game)
  if type(token)~="table" or token.runId~=run.bpRunId or token.fight~=run.currentFight
      or token.sequence~=w.spendSequence+1 then return false,"PURCHASE EXPIRED OR ALREADY PROCESSED" end
  local item
  for _,row in ipairs(BP.CATALOG) do if row.id==itemId then item=row;break end end
  if not item then return false,"UNKNOWN BP REWARD" end
  local price=integer(item.cost)
  if price<1 or w.balance<price then return false,"NOT ENOUGH BP" end
  local have=integer(run.bag[itemId])
  if have>=BP.MAX_ITEM_STOCK then return false,"CHALLENGE BAG STOCK FULL" end
  if type(game.writeSave)~="function" then return false,"SAVE UNAVAILABLE - NOTHING SPENT" end
  -- One save commit contains both debit and grant. On a refused/throwing write,
  -- restore the exact old tables. Never show success or advance the receipt.
  local owner=game.save;local beforeWallet=owner.mtBattleBP
  local beforeBag,beforeInitial,beforeSpent=run.bag,run.bagInitial,run.bpSpent
  local nextWallet=copy(w);local bag=copy(run.bag);local initial=copy(run.bagInitial or {})
  nextWallet.balance=nextWallet.balance-price
  nextWallet.lifetimeSpent=integer(nextWallet.lifetimeSpent+price)
  nextWallet.spendSequence=token.sequence
  bag[itemId]=have+1;initial[itemId]=integer(initial[itemId])+1
  local receipt={kind="purchase",runId=run.bpRunId,fight=run.currentFight,item=itemId,
    quantity=1,amount=price,sequence=token.sequence,balanceAfter=nextWallet.balance}
  append(nextWallet,receipt)
  owner.mtBattleBP=nextWallet;run.bag=bag;run.bagInitial=initial;run.bpSpent=integer(run.bpSpent)+price
  local called,written=pcall(game.writeSave,game)
  if not called or written==false or game.save~=owner then
    owner.mtBattleBP=beforeWallet;run.bag=beforeBag;run.bagInitial=beforeInitial;run.bpSpent=beforeSpent
    return false,"SAVE FAILED - NOTHING SPENT"
  end
  return true,"BOUGHT "..item.name.." - "..tostring(price).." BP",receipt
end
BP._test={integer=integer,copy=copy}
return BP
