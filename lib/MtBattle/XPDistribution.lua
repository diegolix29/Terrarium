-- Mt. Battle 100 XP Distribution: post-Trainer-#100 bank allocation
-- across arbitrary owned Pokemon (party or PC), with a level-up preview
-- before committing -- built directly on XPBank.lua's preview/commit
-- (Phase 0 Spike 8's clone-and-simulate technique), so every number
-- shown here is produced by the exact same code path that will actually
-- apply it, never a separate estimate.
local V=... or {}
local XPBank=V.MtBattleXPBank
local RunController=V.MtBattleRunController
local XD={}

local State={}
State.__index=State
XD.State=State

-- eligibleMons: array of {mon=<real mon table>, label=<display string>}
-- -- real mon REFERENCES (party+PC), resolved by the caller (this module
-- has no save/PC access of its own, matching LevelClone.lua's own
-- separation of "resolve a mon" from "do something with it").
function State.new(game,generation,data,eligibleMons)
  return setmetatable({game=game,generation=generation,data=data,
    eligibleMons=eligibleMons or {},allocated={}},State)
end

function State:bankTotal()
  local save=V.MtBattleSaveState.state(self.game)
  return save.xpBank or 0
end

function State:allocatedTotal()
  local sum=0
  for _,amount in pairs(self.allocated) do sum=sum+amount end
  return sum
end

function State:remaining()
  return math.max(0,self:bankTotal()-self:allocatedTotal())
end

-- Sets mon `i`'s allocation to exactly `amount` (not a delta), clamped so
-- the total across every mon never exceeds the bank -- the UI can call
-- this freely (e.g. from a slider) without needing its own bookkeeping.
function State:allocate(i,amount)
  if self.__cbeMtBattleAppliedReceipt then return false end
  amount=tonumber(amount or 0)
  if not amount or amount~=amount or amount==math.huge or amount==-math.huge then return false end
  amount=math.max(0,math.floor(amount))
  local entry=self.eligibleMons[i]
  if not entry then return false end
  local othersTotal=self:allocatedTotal()-(self.allocated[i] or 0)
  local cap=math.max(0,self:bankTotal()-othersTotal)
  self.allocated[i]=math.min(amount,cap)
  return true
end

-- Preview for mon `i` at its CURRENTLY allocated amount -- reuses
-- XPBank.preview verbatim, so "Lv.22 -> Lv.37" here is guaranteed to
-- match what commit() actually produces.
function State:preview(i)
  local entry=self.eligibleMons[i]
  if not entry then return nil end
  return XPBank.preview(self.generation,self.data,entry.mon,self.allocated[i] or 0)
end

-- Applies every non-zero allocation for real (XPBank.commit, the actual
-- award path, full real side effects) and closes out the run via
-- RunController.finish. Returns the list of {label=,preview=} actually
-- applied, for a confirmation summary screen. Refuses to commit twice --
-- xpDistributed is checked, not just active, so a stray double-tap on
-- confirm can't double-grant.
function State:commit()
  local save=V.MtBattleSaveState.state(self.game)
  if save.xpDistributed then return nil,"already distributed" end
  -- A partially allocated bank is not a valid completion.  The presentation
  -- screen enforces this too, but keeping the invariant in the state layer
  -- prevents a stray caller from silently discarding the remainder.  The only
  -- exception is the defensive edge case where the save contains no eligible
  -- owned Pokemon at all; that run must still be able to close cleanly.
  if #self.eligibleMons>0 and self:remaining()>0 then return nil,"xp remains unallocated" end
  local applied={}
  for i,entry in ipairs(self.eligibleMons) do
    local amount=self.allocated[i] or 0
    if amount>0 then
      local before=XPBank.preview(self.generation,self.data,entry.mon,amount)
      XPBank.commit(self.generation,self.data,entry.mon,amount)
      applied[#applied+1]={label=entry.label,fromLevel=before.fromLevel,toLevel=before.toLevel}
    end
  end
  RunController.finish(self.game)
  return applied
end

return XD
