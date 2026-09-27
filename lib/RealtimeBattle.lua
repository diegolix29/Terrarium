-- 368RealtimeBattleDX real-time battle movement prototype.
--
-- v0.1 scope:
--   * third-person chase camera
--   * WASD movement relative to camera
--   * player facing follows movement
--   * circular arena boundary
--   * player/enemy body collision
--   * enemy stays fixed
--
-- v0.4.2 starts the authoritative Gen1 combat bridge for one move: TACKLE.
-- v0.4.9 generalizes damaging moves into contact/projectile/stream/target-line
-- collision classes while keeping PP/damage authoritative in the live battle.
-- v0.5.0 adds a deliberately simplified realtime VFX renderer.  These visuals
-- read attack/collision state only; they NEVER decide hits or apply damage and
-- are not intended to reproduce retail XD GPT1 V2 particles.
-- v0.5.1 anchors emitted visuals to the live animated XD PKX mouth body-map
-- joint and hard-locks player translation until the attack animation finishes.
-- v0.5.2 fixes ranged reach/aim and moves simplified VFX to a robust
-- screen-projected pass. Collision remains world-space and authoritative.
-- v0.5.3 fixes the actual submission path: the realtime overlay is rendered
-- once at the end of Arena.render even when the direct XD-model actor branch
-- bypasses StandaloneHost's actor callback.
-- v0.5.8 removes move-specific targeting/special-casing: every live move slot
-- enters the realtime path. Manual collision decides opponent contact; the
-- authoritative Gen1/Kanto executeAction/performMove pipeline resolves the move after contact.
-- Self/field moves resolve without enemy lock. Body collision radius follows the
-- live XD model footprint where available.
-- v0.5.9 merges the overworld-style third-person controller into the v0.5.8
-- authoritative attack branch: captured mouse look, camera-relative WASD,
-- standing/moving facing semantics, Flying-type repeated air-jumps with the
-- Onix-height cap, and grounded double-jump. Combat resolution is unchanged.
-- v0.6.1 adds a species-agnostic realtime enemy combat brain and replaces
-- unlimited Flying-type lift with finite stamina/recharge. Enemy AI uses the
-- same spatial move classes and authoritative Gen1/Kanto action pipeline.
-- v0.6.3 removes attack/charge locomotion locks and replaces them with
-- power-scaled realtime cooldowns (Tackle/base power 35 = 1.0s; zero-power
-- utility/status moves = 10s). Realtime movement now reflects PAR/SLP/confusion.
-- v0.6.5 adds an always-visible translucent 2x2 move selector, LCTRL move
-- cycling + LMB fire, and a real hitstun/recovery loop: hurt animation locks
-- locomotion, then grants one second of movement-only invulnerability.
-- v0.6.26 puts direct realtime executeAction/performMove calls into the native
-- messages queue phase first, so faint/EXP/trainer replacement/status follow-up
-- work is actually drained instead of remaining queued behind phase=menu.
-- v0.6.21 replaces the old pitch/zoom reticle approximation with a live
-- camera-ray -> arena-floor aim solution plus screen-space self-clearance, and
-- adds a one-use-per-airtime X air dash after jumping/flying.
-- v0.6.19 adds move-aware soft aim assist, 15% player-side hitbox forgiveness,
-- short opening projectile homing, truthful assist reticle feedback, and RMB
-- camera lock-on without replacing the crosshair-driven attack solution.
-- v0.6.18 adds symmetric 0.5s post-switch attack/target immunity and a
-- dedicated grounded X dodge roll with early i-frames and visual tumble.
-- v0.6.6 makes LCTRL one-slot-per-tap, turns grounded Space into a higher
-- forward dodge-leap/double-jump, and pairs with BattleRuntime's full realtime
-- message auto-advance so wild-battle teardown cannot wait on hidden text.
-- v0.6.7 adds symmetric defender hit/recovery and freezes both combatants for
-- the confirmed impact animation beat. v0.6.14 keeps faint animation purely
-- presentation-side so the authoritative replacement/switch queue is never
-- blocked, and widens/dynamically scales the realtime camera for large Pokemon.
-- v0.7.0 adds comprehensive two-sided attack presentation (enemy parity, multi-hit, charge, drain/heal, traps, stat changes, barriers, ground/explosion/recoil/unique families) while preserving authoritative battle mechanics.
-- v0.6.30 extends the live status adapter: SLP/FRZ stop all movement/action
-- commits, sleep wakes on damage or its timer, freeze naturally thaws after a
-- short lock or immediately after damaging Fire hits, and mirrored battle text
-- strips ROM {PROMPT} control tails.
-- v0.6.31 adds the Gen I-III realtime targeting profile table plus live
-- v0.6.32 adds independent WASD ground-target cursor control for circle/trap moves.
-- v0.6.33 isolates the expanded VFX implementation behind a private helper table
-- and fail-opens ground-cursor placement so a targeting-preview fault can never
-- disable the core realtime controller.
-- v0.6.34 gives all four move slots independent cooldowns with a short shared
-- recovery lock and maps live Speed/Accuracy/Evasion stages into movement and
-- realtime hit geometry without changing Attack/Defense/Special damage math.
-- ground-circle, lane and cone telegraphs. Ground-targeted attacks lock the
-- camera-ray floor point on LMB and resolve collision at that world position.
-- v0.6.15 suppresses the remaining native fullscreen palette/white flashes in
-- realtime battles and adds a top action banner for enemy moves, trainer
-- switches, and trainer item use.
local V=...
local R={}
R._fx={} -- private attack-presentation helpers grouped under one stable namespace

local state={
  battle=nil,active=false,
  px=0,py=0,pz=0,vy=0,ex=0,ez=0,playerVelX=0,playerVelZ=0,
  startPX=0,startPY=0,startPZ=0,startEX=0,startEZ=0,
  facingX=0,facingZ=-1,
  yaw=math.pi,pitch=0.06,
  mouseX=nil,mouseY=nil,
  keys={},
  wallAt=nil,
  moving=false,
  arenaRadius=22,
  nav=nil,boundaryMode="fallback-circle",cameraZoom=1.0,groundY=0,
  playerDex=nil,flightCapable=false,flightMode=false,flightState="grounded",
  jumpCount=0,flapClock=0,maxFlightY=9.52,
  jumpBoostX=0,jumpBoostZ=0,jumpBoostClock=0,
  moveCycleHeld=false,moveCycleDebounce=0,
  flightStamina=3.0,flightStaminaMax=3.0,flightRechargeLock=0,
  flightGroundTime=0,flightExhausted=false,
  camEye=nil,camFocus=nil,
  playerRadius=1.75,
  enemyRadius=1.90,playerHeight=3.0,enemyHeight=3.2,
  enemyFacingX=0,enemyFacingZ=1,enemyMoving=false,
  enemyAIStrafe=1,enemyAIThink=0,enemyAIStrafeClock=0,enemyAIFireClock=.45,
  enemyAIDodgeClock=0,enemyAIMoveCursor=0,
  enemyAttackSerial=0,enemyAttackAge=0,enemyAttackDuration=.58,
  enemyAttackActiveStart=.14,enemyAttackActiveEnd=.36,enemyAttackCooldown=0,
  enemyAttackCooldownDuration=0,
  enemyMoveCooldowns={0,0,0,0},enemyMoveCooldownDurations={0,0,0,0},enemyGlobalAttackLock=0,
  enemyAttackAccuracyScale=1,
  enemyAttackKind=nil,enemyAttackRange=0,enemyAttackRadius=0,
  enemyAttackDirX=0,enemyAttackDirZ=1,enemyAttackMove=nil,enemyAttackMoveDef=nil,
  enemyAttackMoveId=nil,enemyAttackMoveSlot=nil,enemyAttackSelf=false,
  enemyAttackHit=false,enemyAttackResolved=false,enemyAttackPpSpent=false,
  enemyProjectileX=nil,enemyProjectileZ=nil,enemyProjectilePrevX=nil,enemyProjectilePrevZ=nil,
  enemyProjectileVX=0,enemyProjectileVZ=0,enemyLastResult="READY",
  reticleOnTarget=false,reticleAssistActive=false,reticleAssistAmount=0,reticleAssistCone=0,
  reticleAimX=0,reticleAimZ=-1,reticleDisplayDistance=9,reticleWorldX=0,reticleWorldZ=0,
  aimHeld=false,cameraLockHeld=false,
  mouseButtons={},
  speed=10.0,
  playerMoveSpeed=10.0,enemyMoveSpeed=8.4,
  playerBaseSpeedStat=20,enemyBaseSpeedStat=20,
  playerSpeedStage=0,enemySpeedStage=0,playerSpeedStageFactor=1,enemySpeedStageFactor=1,
  uiCursorMode=false,uiCursorActive=false,commandMovesOpen=false,
  uiHover=nil,uiPadFocus=1,nativeModalActive=false,nativeModalName=nil,
  playerStatus=nil,enemyStatus=nil,
  playerStatusEvent=nil,enemyStatusEvent=nil,playerStatusEventTTL=0,enemyStatusEventTTL=0,
  playerSleepTimer=0,enemySleepTimer=0,playerSleepMonRef=nil,enemySleepMonRef=nil,
  playerFreezeTimer=0,enemyFreezeTimer=0,playerFreezeMonRef=nil,enemyFreezeMonRef=nil,
  playerConfused=false,enemyConfused=false,
  playerConfuseClock=0,playerConfuseAngle=0,playerConfuseSeed=16017,
  enemyConfuseClock=0,enemyConfuseAngle=0,enemyConfuseSeed=22021,
  playerHitAnimating=false,playerHitActorSeen=false,playerHitFallback=0,
  playerInvuln=0,playerFainted=false,playerPendingFaintAfterHit=false,
  enemyHitAnimating=false,enemyHitActorSeen=false,enemyHitFallback=0,
  enemyInvuln=0,enemyFainted=false,enemyPendingFaintAfterHit=false,
  impactLockActive=false,impactAttacker=nil,impactDefender=nil,
  impactSeenAttacker=false,impactSeenDefender=false,impactMin=0,impactFallback=0,
  impactGuardSide=nil,impactGuardHP=nil,impactGuardDamage=nil,impactGuardTTL=0,impactSource=nil,
  playerFaintHold=false,playerFaintSeen=false,playerFaintFallback=0,
  enemyFaintHold=false,enemyFaintSeen=false,enemyFaintFallback=0,
  playerMonRef=nil,enemyMonRef=nil,
  playerSwitchGuard=0,enemySwitchGuard=0,
  rollTimer=0,rollElapsed=0,rollCooldown=0,rollIFrame=0,
  rollDirX=0,rollDirZ=-1,
  airDashTimer=0,airDashElapsed=0,airDashIFrame=0,airDashUsed=false,
  airDashDirX=0,airDashDirZ=-1,

  -- Realtime combat debug/prototype state.
  attackSerial=0,
  hitSerial=0,
  attackAge=0,
  attackDuration=0.58,
  attackActiveStart=0.14,
  attackActiveEnd=0.34,
  attackCooldown=0,
  attackCooldownDuration=0,
  playerMoveCooldowns={0,0,0,0},playerMoveCooldownDurations={0,0,0,0},playerGlobalAttackLock=0,
  attackAccuracyScale=1,
  attackHit=false,
  attackMotionLock=false,
  attackActorSeen=false,
  attackFacingLock=false,attackFacingActorSeen=false,attackFacingTimer=0,
  attackFacingX=0,attackFacingZ=-1,
  attackResult="READY",
  attackMove=nil,
  attackMoveDef=nil,
  attackMoveId=nil,
  attackMoveSlot=nil,
  attackPP=nil,
  attackKind=nil,
  attackRange=0,
  attackDirX=0,attackDirZ=-1,
  attackSelf=false,attackResolved=false,attackPpSpent=false,
  attackTargetX=nil,attackTargetZ=nil,attackTargetDistance=0,
  projectileX=nil,projectileZ=nil,projectilePrevX=nil,projectilePrevZ=nil,
  projectileVX=0,projectileVZ=0,projectileHomingTimer=0,projectileHomingScale=1,
  projectileRadius=0,
  attackAssistActive=false,attackAssistAmount=0,
  lastDamage=0,
  lastCrit=false,
  lastTypeMult=10,
  lastHpBefore=nil,
  lastHpAfter=nil,
  combatError=nil,
  selectedMoveSlot=nil,
  selectedMoveId=nil,
  selectedMoveXdId=nil,
  selectedMoveCanonical=nil,
  selectedMoveHasVFX=false,
  targetPreviewActive=false,targetPreviewClass=nil,targetPreviewKind=nil,
  targetPreviewX=0,targetPreviewZ=0,targetPreviewDirX=0,targetPreviewDirZ=-1,
  targetPreviewRange=0,targetPreviewRadius=0,targetPreviewAngle=0,targetPreviewWidth=0,
  groundCursorInitialized=false,groundCursorOwnsWASD=false,groundCursorKey=nil,
  groundCursorX=0,groundCursorZ=0,
  attackProfileClass=nil,attackAOERadius=0,attackConeHalfAngle=0,
  enemyAttackProfileClass=nil,enemyAttackTargetX=nil,enemyAttackTargetZ=nil,
  enemyAttackAOERadius=0,enemyAttackConeHalfAngle=0,
  utilityRequested=false,

  -- Realtime attack presentation. These fields never own damage/status logic.
  vfx=nil,enemyVfx=nil,
  persistentMoveVfx={},visualBursts={},
  -- GPT1 V2 diagnostics. This never participates in collision/damage.
  v2Probe=nil,enemyV2Probe=nil,
  impacts={},

  -- Side-local realtime battle text. Player and enemy each own a matching
  -- action/result box above their HUD instead of a shared top banner.
  actionMessage=nil,actionMessageTimer=0,actionMessageKind=nil,
  actionMessageDedupKey=nil,actionMessageDedupTTL=0,actionMessageQueue={},
  playerActionMessage=nil,playerActionTimer=0,playerActionKind=nil,playerActionQueue={},
  playerActionDedupKey=nil,playerActionDedupTTL=0,
  enemyActionMessage=nil,enemyActionTimer=0,enemyActionKind=nil,enemyActionQueue={},
  enemyActionDedupKey=nil,enemyActionDedupTTL=0,
  nativeTextSideHint=nil,nativeTextSideHintTTL=0,nativeTextSerial=0,
}

local function clamp(v,a,b)
  if v<a then return a elseif v>b then return b end
  return v
end

-- Large XD models (Dragonite, Tyranitar-sized bodies, broad winged species)
-- need more camera room than small Pokemon. Use the same live actor metrics as
-- realtime collision and increase boom distance only when a displayed model is
-- genuinely large. This compounds with the user's mouse-wheel cameraZoom.
function R._actorFramingScale(context)
  local csm=V and V.CurrentSpriteModels
  if not (csm and type(csm.realtimeActorMetrics)=="function") then return 1 end
  local largest=0
  for _,side in ipairs({"player","enemy"}) do
    local ok,m=pcall(csm.realtimeActorMetrics,csm,side,context)
    if ok and type(m)=="table" then
      local h=tonumber(m.height) or 0
      local f=(tonumber(m.footprint) or 0)*1.20
      if h>largest then largest=h end
      if f>largest then largest=f end
    end
  end
  if largest<=13 then return 1 end
  return clamp(1+(largest-13)/38,1,1.34)
end
R._ACTION_MESSAGE_TIME=2.35
R._ACTION_MESSAGE_DEDUP=.90

function R._prettyToken(v)
  if type(v)=="table" then v=v.name or v.displayName or v.label or v.id end
  local text=tostring(v or "")
  text=text:gsub("_"," "):gsub("%-"," "):lower()
  text=text:gsub("(%a)([%w']*)",function(a,b) return a:upper()..b end)
  return text~="" and text or "Item"
end

function R._battlerLabel(b)
  if type(b)~="table" then return "Enemy Pokemon" end
  local name=b.name or b.nickname
  if not name and type(b.mon)=="table" then name=b.mon.name or b.mon.nickname or b.mon.speciesName or b.mon.species end
  return tostring(name or "Enemy Pokemon")
end

function R._trainerLabel(battle)
  local t=battle and battle.trainer
  local name=(type(t)=="table" and (t.name or t.trainerName)) or (battle and (battle.trainerName or battle.oppName))
  return tostring(name or "Enemy Trainer")
end

function R._cleanActionText(text)
  text=tostring(text or "")
  -- Extracted ROM battle text can carry the source control-tail marker as a
  -- literal token. The stock TextBox consumes it; our realtime mirror must not
  -- print it to the player. Keep this deliberately narrow so real replacement
  -- tokens such as Pokemon/player names are never stripped.
  text=text:gsub("%{PROMPT%}",""):gsub("%{prompt%}","")
  text=text:gsub("\r",""):gsub("\v","\n"):gsub("\f","\n")
  text=text:gsub("\n%s*\n+","\n")
  text=text:gsub("^%s+",""):gsub("%s+$","")
  return text
end

function R._showSideAction(side,text,duration,key,kind)
  side=(side=="enemy") and "enemy" or "player"
  text=R._cleanActionText(text)
  if text=="" then return false end
  key=tostring(key or text)
  local msgKey=side.."ActionMessage"
  local timerKey=side.."ActionTimer"
  local kindKey=side.."ActionKind"
  local queueKey=side.."ActionQueue"
  local dedupKey=side.."ActionDedupKey"
  local dedupTTL=side.."ActionDedupTTL"
  if state[dedupKey]==key and (tonumber(state[dedupTTL]) or 0)>0 then return false end
  local row={text=text,duration=tonumber(duration) or 1.55,key=key,kind=kind or "action"}
  if state[msgKey] and (tonumber(state[timerKey]) or 0)>0 then
    local q=state[queueKey] or {};state[queueKey]=q
    for _,v in ipairs(q) do if v.key==key then return false end end
    if #q>=8 then table.remove(q,1) end
    q[#q+1]=row
  else
    state[msgKey]=row.text;state[timerKey]=row.duration;state[kindKey]=row.kind
  end
  state[dedupKey]=key;state[dedupTTL]=.55
  return true
end

function R._advanceSideAction(side)
  side=(side=="enemy") and "enemy" or "player"
  local msgKey=side.."ActionMessage"
  local timerKey=side.."ActionTimer"
  local kindKey=side.."ActionKind"
  local q=state[side.."ActionQueue"] or {}
  if state[msgKey] and (tonumber(state[timerKey]) or 0)>0 then return false end
  local row=table.remove(q,1)
  if not row then state[msgKey]=nil;state[kindKey]=nil;return false end
  state[msgKey]=row.text;state[timerKey]=row.duration;state[kindKey]=row.kind
  return true
end

-- Backward-compatible enemy/trainer call site: the old top banner is retired;
-- these messages now go to the enemy's own action box.
function R._showActionMessage(text,kind,key,duration)
  return R._showSideAction("enemy",text,duration,key,kind)
end

function R._queueActionMessage(text,kind,key,duration,side)
  return R._showSideAction(side or "enemy",text,duration,key,kind or "ending")
end

function R._advanceActionMessageQueue()
  return false
end

function R._showPlayerAction(context,text,duration,key,kind)
  return R._showSideAction("player",text,duration,key or ("player:"..tostring(text)),kind)
end

function R._showEnemyAction(context,text,duration,key,kind)
  return R._showSideAction("enemy",text,duration,key or ("enemy:"..tostring(text)),kind)
end

function R._announcePlayerMove(context,moveId,moveDef)
  local battle=context and context.battle
  local user=battle and battle.player
  local moveName=(type(moveDef)=="table" and (moveDef.name or moveDef.displayName)) or moveId
  state.nativeTextSideHint="player";state.nativeTextSideHintTTL=4.0
  return R._showPlayerAction(context,R._battlerLabel(user).." used "..R._prettyToken(moveName).."!",1.45,
    "move:player:"..tostring(moveId)..":"..tostring(state.attackSerial or 0),"move")
end

function R._announceEnemyMove(context,moveId,moveDef)
  local battle=context and context.battle
  local user=battle and battle.enemy
  local moveName=(type(moveDef)=="table" and (moveDef.name or moveDef.displayName)) or moveId
  state.nativeTextSideHint="enemy";state.nativeTextSideHintTTL=4.0
  return R._showEnemyAction(context,R._battlerLabel(user).." used "..R._prettyToken(moveName).."!",1.45,
    "move:enemy:"..tostring(moveId)..":"..tostring(state.enemyAttackSerial or 0),"move")
end

-- Mirror the authoritative hidden BattleState text row into the active side's
-- realtime text box. This catches misses, "But, it failed!", stat-stage text,
-- Reflect/Light Screen/Mist messages and other engine-authored outcomes without
-- reimplementing their battle rules here.
function R:captureNativeText(battle,row)
  if not state.active or (state.battle and battle and state.battle~=battle) then return false end
  if type(row)~="table" or row.text==nil then return false end
  if not state.nativeTextSideHint or (tonumber(state.nativeTextSideHintTTL) or 0)<=0 then return false end
  local text=R._cleanActionText(row.text)
  if text=="" then return false end
  local lower=text:lower()
  local flat=lower:gsub("\n"," "):gsub("%s+"," ")
  -- Move-use, faint and EXP lines already have semantic event/commit messages;
  -- only mirror the result/effect pages so the side box does not duplicate them.
  if flat:find(" used ",1,true) or flat:find("fainted",1,true) or (flat:find("gained",1,true) and flat:find("exp",1,true)) then
    return false
  end
  state.nativeTextSerial=(tonumber(state.nativeTextSerial) or 0)+1
  return R._showSideAction(state.nativeTextSideHint,text,1.45,
    "native:"..tostring(state.nativeTextSerial),"result")
end

local function len2(x,z) return math.sqrt(x*x+z*z) end
local function normalize2(x,z)
  local d=len2(x,z)
  if d<1e-8 then return 0,0 end
  return x/d,z/d
end

-- Gen III Flying-type whitelist for #001-386. This intentionally follows
-- elemental typing rather than anatomy/levitation.
local FLYING_TYPE_DEX={}
for _,d in ipairs({
  6,12,16,17,18,21,22,41,42,83,84,85,123,130,142,144,145,146,149,
  163,164,165,166,169,176,177,178,187,188,189,193,198,207,225,226,
  227,249,250,267,276,277,278,279,284,291,333,334,357,373,384
}) do FLYING_TYPE_DEX[d]=true end

local ONIX_BATTLE_HEIGHT=6.90*1.38
local FLIGHT_FLAP_COOLDOWN=.40
local FLIGHT_STAMINA_MAX=3.0
local FLIGHT_GROUND_LOCKOUT=1.5
local FLIGHT_RECHARGE_TIME=2.5
local FLIGHT_RECHARGE_RATE=FLIGHT_STAMINA_MAX/FLIGHT_RECHARGE_TIME
local FLIGHT_ATTACK_COST=FLIGHT_STAMINA_MAX*.15

-- Grounded dodge-leap tuning.  Space should create useful forward separation
-- instead of a nearly vertical hop.  The boost is additive to camera-relative
-- WASD, decays quickly in the air, and never applies to the Flying-type lift
-- system so flight balance is unchanged.
local GROUND_JUMP_VY=12.5
local GROUND_DOUBLE_JUMP_VY=11.8
local GROUND_JUMP_FORWARD_FACTOR=.85
local GROUND_JUMP_BOOST_TIME=.52
local GROUND_JUMP_BOOST_DRAG=2.6
local MOVE_CYCLE_DEBOUNCE=.22

-- Newly switched battlers get a short neutral-entry window. During this time
-- they cannot start a realtime move and incoming realtime collisions pass
-- through them. This applies symmetrically to player and enemy replacements.
R._SWITCH_GUARD_TIME=.50

-- Dedicated Souls-style grounded dodge roll on X. The roll is movement-only,
-- blocks attacks for its full duration, and grants i-frames only through the
-- early/mid portion so late recovery can still be punished. Keep these on R
-- rather than adding chunk locals; this file already runs close to Lua's 200
-- local-variable limit.
R._ROLL_DURATION=.42
R._ROLL_IFRAME_TIME=.28
R._ROLL_COOLDOWN=.68
R._ROLL_SPEED_FACTOR=1.65
R._ROLL_MIN_SPEED=5.0
R._ROLL_MAX_SPEED=21.0
R._ROLL_VISUAL_LIFT=.42

R._AIR_DASH_DURATION=.18
R._AIR_DASH_IFRAME=.14
R._AIR_DASH_SPEED_FACTOR=2.10
R._AIR_DASH_MIN_SPEED=8.0
R._AIR_DASH_MAX_SPEED=30.0

-- v0.6.19 aiming comfort. Player attack collision gets a modest invisible
-- margin, soft aim magnetism varies by move class, projectiles receive only a
-- brief opening correction, and RMB can hold the camera on the opponent.
R._PLAYER_TARGET_RADIUS_SCALE=1.15
R._PROJECTILE_HOMING_TIME=.16
R._PROJECTILE_HOMING_TURN=math.rad(110)
R._PROJECTILE_HOMING_CONE=math.rad(30)
R._CAMERA_LOCK_RATE=11.5
R._CAMERA_LOCK_PITCH_RATE=8.5

local TORKOAL_BASE_SPEED=20
local TORKOAL_PLAYER_MOVE_SPEED=10.0
local TORKOAL_ENEMY_MOVE_SPEED=8.4
local MOVE_SPEED_EXPONENT=.28
local MOVE_SPEED_MIN_FACTOR=.80
local MOVE_SPEED_MAX_FACTOR=1.70
local ENEMY_AI_REACTION=.42
R._PLAYER_POST_HIT_INVULN=1.0
R._PLAYER_HIT_FALLBACK=.80
R._ENEMY_POST_HIT_INVULN=1.0
R._ENEMY_HIT_FALLBACK=.80
R._IMPACT_LOCK_FALLBACK=1.60
R._FAINT_HOLD_FALLBACK=3.00
local ENEMY_AI_MIN_RANGE=7.0
local ENEMY_AI_IDEAL_RANGE=11.5
local ENEMY_AI_MAX_RANGE=17.0

-- Independent move cooldowns. Each slot owns its own timer; a short shared
-- recovery starts only after the current attack animation ends so players can
-- rotate moves without chaining several attacks in the same instant.
R._GLOBAL_ATTACK_RECOVERY=.80
R._PLAYER_MOVE_SPEED_MIN=2.5
R._PLAYER_MOVE_SPEED_MAX=26.0
R._ENEMY_MOVE_SPEED_MIN=2.2
R._ENEMY_MOVE_SPEED_MAX=22.0

-- Accuracy changes the authored realtime attack footprint, while Evasion changes
-- the effective target body. Range itself is intentionally unchanged. These
-- values are gameplay geometry scales, not replacements for Gen1's damage stats.
R._ACCURACY_SHAPE_SCALE={[-6]=.34,[-5]=.40,[-4]=.48,[-3]=.56,[-2]=.67,[-1]=.82,[0]=1.00,[1]=1.18,[2]=1.40,[3]=1.55,[4]=1.70,[5]=1.85,[6]=2.00}
R._EVASION_TARGET_SCALE={[-6]=1.35,[-5]=1.30,[-4]=1.25,[-3]=1.20,[-2]=1.14,[-1]=1.07,[0]=1.00,[1]=.94,[2]=.88,[3]=.83,[4]=.78,[5]=.73,[6]=.68}

-- Realtime action pacing. Tackle's Gen III base power (35) is the user's
-- reference at exactly one second. Damaging moves scale linearly from that
-- baseline; utility/status/stat moves use a long anti-spam cooldown. Cooldown
-- begins when the move is committed, so animation time counts toward it.
local STATUS_MOVE_COOLDOWN=10.0
local DAMAGE_COOLDOWN_POWER_BASE=35.0
local DAMAGE_COOLDOWN_MIN=1.0
local DAMAGE_COOLDOWN_MAX=7.5
local FIXED_DAMAGE_COOLDOWN_POWER={
  SONICBOOM=20,SONIC_BOOM=20,DRAGON_RAGE=40,
  SEISMIC_TOSS=60,NIGHT_SHADE=60,PSYWAVE=60,SUPER_FANG=80,
  COUNTER=100,MIRROR_COAT=100,ENDEAVOR=100,
  GUILLOTINE=250,HORN_DRILL=250,FISSURE=250,SHEER_COLD=250,
}

local function normalizedStatus(battler)
  local mon=type(battler)=="table" and battler.mon or nil
  local st=(mon and mon.status) or (type(battler)=="table" and battler.shownStatus)
  if st==nil then return nil end
  st=tostring(st):upper():gsub("[%s%-]+","_")
  if st=="" or st=="NONE" or st=="NIL" or st=="0" then return nil end
  if st=="PARALYZE" or st=="PARALYZED" or st=="PARALYSIS" then st="PAR"
  elseif st=="SLEEP" or st=="ASLEEP" then st="SLP"
  elseif st=="POISON" or st=="POISONED" then st="PSN"
  elseif st=="TOXIC" or st=="BAD_POISON" or st=="BADLY_POISONED" then st="TOX"
  elseif st=="BURN" or st=="BURNED" or st=="BURNING" then st="BRN"
  elseif st=="FREEZE" or st=="FROZEN" then st="FRZ"
  end
  -- Gen1Recomp stores Toxic as PSN plus battler.toxicCounter, not a separate
  -- persistent mon.status value. Expose TOX in the realtime HUD when that
  -- counter is live so the badge matches the actual battle condition.
  if st=="PSN" and type(battler)=="table" and (tonumber(battler.toxicCounter) or 0)>0 then st="TOX" end
  return st
end

function R._statusBadgeCode(battle,battler,side)
  local st=normalizedStatus(battler)
  if not st and (side=="player" or side=="enemy") then
    local ttl=tonumber(state[side.."StatusEventTTL"]) or 0
    if ttl>0 then
      local raw=state[side.."StatusEvent"]
      if raw~=nil then
        st=tostring(type(raw)=="table" and (raw.id or raw.hudLabel or raw.label or raw.name) or raw):upper():gsub("[%s%-]+","_")
      end
    end
  end
  if not st or st=="" or st=="NONE" or st=="NIL" or st=="0" then return nil end
  if st=="PARALYZE" or st=="PARALYZED" or st=="PARALYSIS" then st="PAR"
  elseif st=="SLEEP" or st=="ASLEEP" then st="SLP"
  elseif st=="POISON" or st=="POISONED" then st="PSN"
  elseif st=="TOXIC" or st=="BAD_POISON" or st=="BADLY_POISONED" then st="TOX"
  elseif st=="BURN" or st=="BURNED" or st=="BURNING" then st="BRN"
  elseif st=="FREEZE" or st=="FROZEN" then st="FRZ" end
  if st=="PSN" and type(battler)=="table" and (tonumber(battler.toxicCounter) or 0)>0 then st="TOX" end
  if st=="TOX" then return "TOX" end
  local statuses=battle and battle.data and battle.data.statuses
  local rec=type(statuses)=="table" and statuses[st] or nil
  local code=type(rec)=="table" and (rec.hudLabel or rec.label or rec.id) or st
  code=tostring(code or st):upper():gsub("[%s%-]+","_")
  if #code>5 then code=st end
  return code
end
local function battlerSleeping(battler) return normalizedStatus(battler)=="SLP" end
function R._battlerFrozen(battler) return normalizedStatus(battler)=="FRZ" end
local function battlerParalyzed(battler) return normalizedStatus(battler)=="PAR" end
local function battlerConfused(battler)
  return type(battler)=="table" and (tonumber(battler.confusedTurns) or 0)>0
end

function R._stageValue(battler,key)
  local stages=type(battler)=="table" and battler.stages or nil
  local v=type(stages)=="table" and tonumber(stages[key]) or 0
  return math.max(-6,math.min(6,math.floor(tonumber(v) or 0)))
end

function R._statStageMultiplier(battler,key)
  local s=R._stageValue(battler,key)
  if s>=0 then return (2+s)/2 end
  return 2/(2-s)
end

function R._accuracyShapeScale(battler)
  return R._ACCURACY_SHAPE_SCALE[R._stageValue(battler,"accuracy")] or 1
end

function R._evasionTargetScale(battler)
  return R._EVASION_TARGET_SCALE[R._stageValue(battler,"evasion")] or 1
end

function R._slotCooldown(side,slot)
  slot=math.max(1,math.min(4,math.floor(tonumber(slot) or 1)))
  local t=(side=="enemy") and state.enemyMoveCooldowns or state.playerMoveCooldowns
  return math.max(0,tonumber(type(t)=="table" and t[slot]) or 0)
end

function R._setSlotCooldown(side,slot,duration)
  slot=math.max(1,math.min(4,math.floor(tonumber(slot) or 1)))
  duration=math.max(0,tonumber(duration) or 0)
  local t=(side=="enemy") and state.enemyMoveCooldowns or state.playerMoveCooldowns
  local d=(side=="enemy") and state.enemyMoveCooldownDurations or state.playerMoveCooldownDurations
  if type(t)~="table" then t={0,0,0,0};if side=="enemy" then state.enemyMoveCooldowns=t else state.playerMoveCooldowns=t end end
  if type(d)~="table" then d={0,0,0,0};if side=="enemy" then state.enemyMoveCooldownDurations=d else state.playerMoveCooldownDurations=d end end
  t[slot]=duration;d[slot]=duration
  return duration
end

function R._updateMoveCooldowns(dt)
  dt=math.max(0,tonumber(dt) or 0)
  for _,side in ipairs({"player","enemy"}) do
    local t=(side=="enemy") and state.enemyMoveCooldowns or state.playerMoveCooldowns
    if type(t)~="table" then t={0,0,0,0};if side=="enemy" then state.enemyMoveCooldowns=t else state.playerMoveCooldowns=t end end
    for i=1,4 do t[i]=math.max(0,(tonumber(t[i]) or 0)-dt) end
  end
  state.playerGlobalAttackLock=math.max(0,(tonumber(state.playerGlobalAttackLock) or 0)-dt)
  state.enemyGlobalAttackLock=math.max(0,(tonumber(state.enemyGlobalAttackLock) or 0)-dt)
end

-- Turn-based sleep only counts down when Status.beforeMove runs. In realtime we
-- intentionally block attack commits while asleep, so that native countdown
-- would otherwise never execute. Convert the already-authoritative Gen 1
-- sleepTurns roll (1..7) into realtime seconds. Damage wakes immediately as a
-- live-battle concession; if nobody hits the sleeper, the timer still expires.
R._SLEEP_SECONDS_PER_TURN=1.25
function R._wakeRealtimeSleep(context,side,reason)
  side=(side=="enemy") and "enemy" or "player"
  local battle=context and context.battle
  local b=battle and battle[side]
  if not (b and b.mon and battlerSleeping(b)) then return false end
  b.mon.status=nil
  b.sleepTurns=nil
  b.shownStatus=nil
  if battle and type(battle.syncShownStatus)=="function" then pcall(battle.syncShownStatus,battle) end
  state[side.."SleepTimer"]=0
  state[side.."SleepMonRef"]=nil
  state[side.."Status"]=nil
  state[side.."StatusEvent"]=nil
  state[side.."StatusEventTTL"]=0
  local text=R._battlerLabel(b).." woke up!"
  R._showSideAction(side,text,1.45,"wake:"..side..":"..tostring(reason or "timer"),"status")
  return true
end

function R._updateRealtimeSleep(context,dt)
  local battle=context and context.battle
  if not battle then return end
  for _,side in ipairs({"player","enemy"}) do
    local b=battle[side]
    local timerKey=side.."SleepTimer"
    local refKey=side.."SleepMonRef"
    if b and b.mon and battlerSleeping(b) then
      if state[refKey]~=b.mon or (tonumber(state[timerKey]) or 0)<=0 then
        state[refKey]=b.mon
        local turns=math.max(1,math.min(7,math.floor((tonumber(b.sleepTurns) or 1)+.5)))
        state[timerKey]=turns*R._SLEEP_SECONDS_PER_TURN
      end
      state[timerKey]=math.max(0,(tonumber(state[timerKey]) or 0)-math.max(0,tonumber(dt) or 0))
      if state[timerKey]<=0 then R._wakeRealtimeSleep(context,side,"timer") end
    else
      state[timerKey]=0
      state[refKey]=nil
    end
  end
end

-- Gen I freeze has no ordinary random thaw, which is too absolute for a live
-- action battle. Realtime freeze therefore keeps the native FRZ status as the
-- authority while adding two presentation/gameplay exits: a short natural thaw
-- and an immediate thaw after a real damaging Fire-type hit. Y/HP/damage logic
-- remains untouched; this only clears FRZ and releases the realtime action lock.
R._FREEZE_NATURAL_SECONDS=5.0
function R._thawRealtimeFreeze(context,side,reason)
  side=(side=="enemy") and "enemy" or "player"
  local battle=context and context.battle
  local b=battle and battle[side]
  if not (b and b.mon and R._battlerFrozen(b)) then return false end
  b.mon.status=nil
  b.shownStatus=nil
  if battle and type(battle.syncShownStatus)=="function" then pcall(battle.syncShownStatus,battle) end
  state[side.."FreezeTimer"]=0
  state[side.."FreezeMonRef"]=nil
  state[side.."Status"]=nil
  state[side.."StatusEvent"]=nil
  state[side.."StatusEventTTL"]=0
  local text=R._battlerLabel(b)..((reason=="fire") and " thawed out from the heat!" or " thawed out!")
  R._showSideAction(side,text,1.45,"thaw:"..side..":"..tostring(reason or "timer"),"status")
  return true
end

function R._updateRealtimeFreeze(context,dt)
  local battle=context and context.battle
  if not battle then return end
  for _,side in ipairs({"player","enemy"}) do
    local b=battle[side]
    local timerKey=side.."FreezeTimer"
    local refKey=side.."FreezeMonRef"
    if b and b.mon and R._battlerFrozen(b) then
      if state[refKey]~=b.mon or (tonumber(state[timerKey]) or 0)<=0 then
        state[refKey]=b.mon
        state[timerKey]=R._FREEZE_NATURAL_SECONDS
      end
      state[timerKey]=math.max(0,(tonumber(state[timerKey]) or 0)-math.max(0,tonumber(dt) or 0))
      if state[timerKey]<=0 then R._thawRealtimeFreeze(context,side,"timer") end
    else
      state[timerKey]=0
      state[refKey]=nil
    end
  end
end
local function cooldownPower(moveId,def)
  local p=tonumber(def and (def.power or def.basePower or def.damage))
  if p and p>0 then return p end
  local n=tostring((def and (def.id or def.name)) or moveId or ""):upper():gsub("[%s%-]+","_"):gsub("[^A-Z0-9_]","")
  return FIXED_DAMAGE_COOLDOWN_POWER[n]
end
local function moveCooldownSeconds(moveId,def)
  local p=cooldownPower(moveId,def)
  if not p or p<=0 then return STATUS_MOVE_COOLDOWN end
  return clamp(p/DAMAGE_COOLDOWN_POWER_BASE,DAMAGE_COOLDOWN_MIN,DAMAGE_COOLDOWN_MAX)
end

-- Confusion movement is intentionally presentation/controller-side and never
-- consumes the battle RNG. A tiny deterministic LCG changes the steering angle
-- every few tenths of a second, making WASD/AI locomotion unreliable while the
-- authoritative confusion counter/self-hit behavior remains in BattleState.
local function nextConfuseSeed(seed)
  return (math.floor(tonumber(seed) or 1)*1103515245+12345)%2147483648
end
local function updateConfusionSteer(side,confused,dt)
  local ck=side=="enemy" and "enemyConfuseClock" or "playerConfuseClock"
  local ak=side=="enemy" and "enemyConfuseAngle" or "playerConfuseAngle"
  local sk=side=="enemy" and "enemyConfuseSeed" or "playerConfuseSeed"
  if not confused then state[ck]=0;state[ak]=0;return 0 end
  state[ck]=math.max(0,(tonumber(state[ck]) or 0)-math.max(0,tonumber(dt) or 0))
  if state[ck]<=0 then
    local seed=nextConfuseSeed(state[sk]);state[sk]=seed
    local unit=(seed%2001)/1000-1
    local angle=unit*math.rad(125)
    if (math.floor(seed/2001)%5)==0 then angle=angle+math.pi end
    state[ak]=angle
    state[ck]=.20+((math.floor(seed/10007)%19)/100)
  end
  return tonumber(state[ak]) or 0
end
local function rotate2(x,z,a)
  if not a or math.abs(a)<1e-8 then return x,z end
  local c,ss=math.cos(a),math.sin(a)
  return x*c-z*ss,x*ss+z*c
end

local function playerDex(context)
  local battle=context and context.battle
  local battler=battle and battle.player
  local mon=battler and battler.mon
  if not mon then return nil end
  local game=(context and context.game) or (battle and battle.game)
  local data=game and game.data
  local def=data and data.pokemon and data.pokemon[mon.species]
  return tonumber((def and (def.dex or def.index or def.number))
    or mon.dex or mon.speciesIndex or mon.species)
end

local function flightCapable(context)
  local d=playerDex(context)
  return d,FLYING_TYPE_DEX[d]==true
end

-- Species locomotion speed uses the Gen III base Speed stat, but a softened
-- curve keeps the realtime arena controllable. Torkoal (base Speed 20) is the
-- user's reference: its existing v0.6.1 movement is exactly 1.0x. Very slow
-- species remain usable and extreme-speed species never exceed 1.70x.
local function battlerSpeciesDef(context,battler)
  if type(battler)~="table" then return nil end
  if type(battler.def)=="table" then return battler.def end
  local battle=context and context.battle
  local game=(context and context.game) or (battle and battle.game)
  local data=(battle and battle.data) or (game and game.data)
  local mon=battler.mon
  local species=mon and mon.species
  return data and data.pokemon and species and data.pokemon[species] or nil
end
local function battlerBaseSpeed(context,battler)
  local def=battlerSpeciesDef(context,battler)
  local bs=def and def.baseStats and tonumber(def.baseStats.speed)
  if not bs or bs<=0 then return TORKOAL_BASE_SPEED end
  return bs
end
local function speciesMoveFactor(baseSpeed)
  local bs=math.max(1,tonumber(baseSpeed) or TORKOAL_BASE_SPEED)
  return clamp((bs/TORKOAL_BASE_SPEED)^MOVE_SPEED_EXPONENT,
    MOVE_SPEED_MIN_FACTOR,MOVE_SPEED_MAX_FACTOR)
end
local function refreshMovementSpeeds(context)
  local battle=context and context.battle
  local pbs=battlerBaseSpeed(context,battle and battle.player)
  local ebs=battlerBaseSpeed(context,battle and battle.enemy)
  state.playerBaseSpeedStat=pbs
  state.enemyBaseSpeedStat=ebs
  local player=battle and battle.player
  local enemy=battle and battle.enemy
  local pm=battlerParalyzed(player) and .5 or 1.0
  local em=battlerParalyzed(enemy) and .5 or 1.0
  local ps=R._statStageMultiplier(player,"speed")
  local es=R._statStageMultiplier(enemy,"speed")
  state.playerSpeedStage=R._stageValue(player,"speed");state.enemySpeedStage=R._stageValue(enemy,"speed")
  state.playerSpeedStageFactor=ps;state.enemySpeedStageFactor=es
  state.playerMoveSpeed=clamp(TORKOAL_PLAYER_MOVE_SPEED*speciesMoveFactor(pbs)*pm*ps,R._PLAYER_MOVE_SPEED_MIN,R._PLAYER_MOVE_SPEED_MAX)
  state.enemyMoveSpeed=clamp(TORKOAL_ENEMY_MOVE_SPEED*speciesMoveFactor(ebs)*em*es,R._ENEMY_MOVE_SPEED_MIN,R._ENEMY_MOVE_SPEED_MAX)
  state.playerStatus=normalizedStatus(player)
  state.enemyStatus=normalizedStatus(enemy)
  state.playerConfused=battlerConfused(player)
  state.enemyConfused=battlerConfused(enemy)
end

-- v0.6.0 shooter aim: the reticle represents the ACTUAL center-camera ray.
-- The shoulder camera therefore converges attacks toward the screen center
-- instead of firing a parallel yaw-only ray from the Pokemon. This removes the
-- third-person parallax that made narrow streams such as Flamethrower difficult
-- to place. A target is only converged when the camera ray actually overlaps a
-- model-sized aim volume; this is not lock-on/autotarget.
local function normalize3(x,y,z)
  local d=math.sqrt(x*x+y*y+z*z)
  if d<1e-8 then return 0,0,-1 end
  return x/d,y/d,z/d
end
local function cameraAimRay()
  local e,f=state.camEye,state.camFocus
  if type(e)=="table" and type(f)=="table" then
    local dx,dy,dz=(f[1] or 0)-(e[1] or 0),(f[2] or 0)-(e[2] or 0),(f[3] or 0)-(e[3] or 0)
    dx,dy,dz=normalize3(dx,dy,dz)
    return e[1] or 0,e[2] or 0,e[3] or 0,dx,dy,dz
  end
  local cp=math.cos(state.pitch or 0)
  local dx,dy,dz=math.sin(state.yaw or 0)*cp,-math.sin(state.pitch or 0),math.cos(state.yaw or 0)*cp
  dx,dy,dz=normalize3(dx,dy,dz)
  return state.px or 0,(state.py or 0)+2.85,state.pz or 0,dx,dy,dz
end
local function cameraRayOnEnemy()
  local ox,oy,oz,dx,dy,dz=cameraAimRay()
  local h=math.max(1.4,tonumber(state.enemyHeight) or 3.2)
  local cx,cy,cz=state.ex,h*.52,state.ez
  local vx,vy,vz=cx-ox,cy-oy,cz-oz
  local t=vx*dx+vy*dy+vz*dz
  if t<=0 then return false,t end
  local qx,qy,qz=ox+dx*t,oy+dy*t,oz+dz*t
  local ex,ey,ez=cx-qx,cy-qy,cz-qz
  -- The aim volume is a little larger than the visible body, matching the
  -- 15% player-side collision forgiveness used by the realtime hit tests.
  local r=math.max((tonumber(state.enemyRadius) or 1.9)*R._PLAYER_TARGET_RADIUS_SCALE+.24,math.min(3.8,h*.36))
  r=r*R._evasionTargetScale(state.battle and state.battle.enemy)
  return ex*ex+ey*ey+ez*ez<=r*r,t
end

function R._aimAssistProfile(kind,def)
  kind=tostring(kind or "target-line")
  local cone,strength
  if kind=="contact" then cone,strength=math.rad(30),.88
  elseif kind=="projectile" then cone,strength=math.rad(22),.52
  elseif kind=="stream" then cone,strength=math.rad(20),.50
  elseif kind=="target-line" then cone,strength=math.rad(14),.36
  else return 0,0 end
  -- Big long-range nukes keep more manual precision than small/ordinary shots.
  local power=tonumber(def and (def.power or def.basePower or def.damage)) or 0
  if kind~="contact" then
    if power>=100 then cone,strength=cone*.68,strength*.68
    elseif power>=80 then cone,strength=cone*.84,strength*.82 end
  end
  local acc=R._accuracyShapeScale(state.battle and state.battle.player)
  cone=cone*clamp(acc,.45,1.50)
  strength=clamp(strength*clamp(acc,.45,1.30),0,.96)
  return cone,strength
end

function R._cameraFloorAimPoint(range)
  range=math.max(1,tonumber(range) or 18)
  local ox,oy,oz,dx,dy,dz=cameraAimRay()
  local px,pz=tonumber(state.px) or 0,tonumber(state.pz) or 0
  local gy=tonumber(state.groundY) or 0
  local tx,tz
  if dy<-1e-4 then
    local t=(gy-oy)/dy
    if t>0 and t<1000 then tx,tz=ox+dx*t,oz+dz*t end
  end
  local hx,hz=normalize2(dx,dz)
  if hx==0 and hz==0 then hx,hz=normalize2(math.sin(state.yaw or 0),math.cos(state.yaw or 0)) end
  if hx==0 and hz==0 then hx,hz=0,-1 end
  if not tx then tx,tz=px+hx*range,pz+hz*range end
  local d=len2(tx-px,tz-pz)
  local minD=math.max(3.5,(tonumber(state.playerRadius) or 1.75)*1.75)
  if d<minD then tx,tz=px+hx*minD,pz+hz*minD;d=minD end
  return tx,tz,d
end

local function cameraAimDirection(range,kind,def)
  range=math.max(1,tonumber(range) or 18)
  local ox,oy,oz,dx,dy,dz=cameraAimRay()
  local onTarget=cameraRayOnEnemy()
  if kind=="self" or kind=="radial" then onTarget=false end
  local tx,tz,displayDist
  if onTarget then
    tx,tz=state.ex,state.ez
    displayDist=len2((state.ex or 0)-(state.px or 0),(state.ez or 0)-(state.pz or 0))
  else
    tx,tz,displayDist=R._cameraFloorAimPoint(range)
  end
  if not tx then
    local fx,fz=normalize2(math.sin(state.yaw or 0),math.cos(state.yaw or 0))
    if fx==0 and fz==0 then fx,fz=0,-1 end
    tx,tz=(state.px or 0)+fx*range,(state.pz or 0)+fz*range
    displayDist=range
  end
  local ax,az=normalize2(tx-(state.px or 0),tz-(state.pz or 0))
  if ax==0 and az==0 then ax,az=0,-1 end

  local assistActive=false
  local assistAmount=0
  local cone,strength=R._aimAssistProfile(kind,def)
  if not onTarget and cone>0 and strength>0 then
    local ex,ez=normalize2((state.ex or 0)-(state.px or 0),(state.ez or 0)-(state.pz or 0))
    if ex~=0 or ez~=0 then
      local dot=clamp(ax*ex+az*ez,-1,1)
      local angle=math.acos(dot)
      if angle<=cone then
        local edge=1-clamp(angle/cone,0,1)
        assistAmount=strength*(edge^.60)
        -- At the very edge the nudge is deliberately tiny; near center it is
        -- strong enough to remove frustrating near-misses without auto-aiming.
        local bx,bz=normalize2(ax*(1-assistAmount)+ex*assistAmount,az*(1-assistAmount)+ez*assistAmount)
        if bx~=0 or bz~=0 then ax,az=bx,bz end
        assistActive=assistAmount>.025
      end
    end
  end
  return ax,az,onTarget==true,assistActive,assistAmount,math.deg(cone or 0),math.max(1,tonumber(displayDist) or range)
end

-- Ground-target cursor used by circle/trap moves. Unlike the ordinary reticle,
-- this deliberately has no minimum lead: the point can be placed anywhere
-- inside the move's cast radius, then is hard-clamped at that radius.
function R._cameraGroundTargetPoint(range)
  range=math.max(.5,tonumber(range) or 18)
  local ox,oy,oz,dx,dy,dz=cameraAimRay()
  local px,pz=tonumber(state.px) or 0,tonumber(state.pz) or 0
  local gy=tonumber(state.groundY) or 0
  local tx,tz
  if dy<-1e-4 then
    local t=(gy-oy)/dy
    if t>0 and t<1000 then tx,tz=ox+dx*t,oz+dz*t end
  end
  local hx,hz=normalize2(dx,dz)
  if hx==0 and hz==0 then hx,hz=normalize2(math.sin(state.yaw or 0),math.cos(state.yaw or 0)) end
  if hx==0 and hz==0 then hx,hz=0,-1 end
  if not tx then tx,tz=px+hx*range,pz+hz*range end
  local vx,vz=tx-px,tz-pz
  local d=len2(vx,vz)
  if d>range then
    vx,vz=normalize2(vx,vz)
    tx,tz=px+vx*range,pz+vz*range
    d=range
  end
  return tx,tz,d
end

function R._moveTargetProfile(moveId,def)
  local mt=V and V.MoveTargeting
  if mt and type(mt.get)=="function" then
    local ok,v=pcall(mt.get,moveId,def)
    if ok and type(v)=="table" then return v end
  end
  return nil
end

function R._coneHitsPoint(tx,tz,ox,oz,dx,dz,range,halfAngle,targetRadius)
  local vx,vz=(tonumber(tx) or 0)-(tonumber(ox) or 0),(tonumber(tz) or 0)-(tonumber(oz) or 0)
  local dist=len2(vx,vz)
  local rr=math.max(0,tonumber(targetRadius) or 0)
  if dist>math.max(0,tonumber(range) or 0)+rr then return false end
  if dist<=rr+.001 then return true end
  vx,vz=normalize2(vx,vz)
  dx,dz=normalize2(dx,dz)
  if dx==0 and dz==0 then dx,dz=0,-1 end
  local extra=math.asin(clamp(rr/math.max(rr+.001,dist),0,.95))
  return (vx*dx+vz*dz)>=math.cos(math.max(.01,tonumber(halfAngle) or math.rad(22.5))+extra)
end

local function atan2(y,x)
  if math.atan2 then return math.atan2(y,x) end
  if x>0 then return math.atan(y/x) end
  if x<0 and y>=0 then return math.atan(y/x)+math.pi end
  if x<0 and y<0 then return math.atan(y/x)-math.pi end
  if x==0 and y>0 then return math.pi/2 end
  if x==0 and y<0 then return -math.pi/2 end
  return 0
end
local function wallClock()
  if love and love.timer and type(love.timer.getTime)=="function" then
    local ok,v=pcall(love.timer.getTime)
    if ok and type(v)=="number" then return v end
  end
  return nil
end
local function wallDt(fallback)
  local now=wallClock()
  if not now then return math.max(0,math.min(.05,tonumber(fallback) or 0)) end
  local dt=state.wallAt and (now-state.wallAt) or (tonumber(fallback) or 0)
  state.wallAt=now
  return math.max(0,math.min(.05,dt))
end
local function isDown(k)
  return love and love.keyboard and type(love.keyboard.isDown)=="function"
    and love.keyboard.isDown(k) and true or false
end
local function pressed(k)
  local d=isDown(k)
  local was=state.keys[k]
  state.keys[k]=d
  return d and not was
end
local function actionPressed(k)
  -- BattleRuntime captures these keys before Gen1Recomp can translate them
  -- into the native virtual battle pad. Consume that captured edge here.
  local br=V and V.BattleRuntime
  if br and type(br.consumeRealtimeKey)=="function" then
    local ok,hit=pcall(br.consumeRealtimeKey,k)
    if ok and hit then return true end
  end
  -- Fallback for hosts/builds where raw callback capture is unavailable.
  return pressed(k)
end

-- Gamepad + mouse helpers live on R._pad so they do not burn main-chunk locals
-- (Lua 5.1/LOVE caps each function at 200 locals).
R._pad=(function()
  local PAD_DEADZONE=.22
  local PAD_LOOK_SENS=.055
  local function mappedGamepad()
    local J=love and love.joystick
    if not (J and type(J.getJoysticks)=="function") then return nil end
    local ok,list=pcall(J.getJoysticks)
    if not ok or type(list)~="table" then return nil end
    local best,bestMag=nil,-1
    for _,js in ipairs(list) do
      local okPad,isPad=pcall(function()
        return js and type(js.isGamepad)=="function" and js:isGamepad()
      end)
      if okPad and isPad and type(js.getGamepadAxis)=="function" then
        local okX,lx=pcall(js.getGamepadAxis,js,"leftx")
        local okY,ly=pcall(js.getGamepadAxis,js,"lefty")
        if okX and okY then
          lx,ly=tonumber(lx) or 0,tonumber(ly) or 0
          local mag=lx*lx+ly*ly
          if mag>bestMag then best,bestMag={js=js,lx=lx,ly=ly},mag end
        end
      end
    end
    if best and type(best.js.getGamepadAxis)=="function" then
      local okRX,rx=pcall(best.js.getGamepadAxis,best.js,"rightx")
      local okRY,ry=pcall(best.js.getGamepadAxis,best.js,"righty")
      best.rx=okRX and tonumber(rx) or 0
      best.ry=okRY and tonumber(ry) or 0
    end
    return best
  end
  local function applyDeadzone(x,y,dz)
    x,y=tonumber(x) or 0,tonumber(y) or 0
    local mag=math.sqrt(x*x+y*y)
    if mag<=(dz or PAD_DEADZONE) then return 0,0 end
    local scale=(mag-(dz or PAD_DEADZONE))/(1-(dz or PAD_DEADZONE))
    scale=clamp(scale,0,1)/mag
    return x*scale,y*scale
  end
  local function padButtonLive(js,button)
    if not (js and type(js.isGamepadDown)=="function") then return false end
    local ok,down=pcall(js.isGamepadDown,js,button)
    return ok and down and true or false
  end
  local function padPressed(button)
    button=tostring(button or ""):lower()
    local br=V and V.BattleRuntime
    local hasLatch=br and type(br.consumeRealtimePad)=="function"
    if hasLatch then
      local ok,hit=pcall(br.consumeRealtimePad,button)
      if ok and hit then return true end
      return false
    end
    local pad=mappedGamepad()
    local d=pad and padButtonLive(pad.js,button) or false
    local key="pad:"..button
    local was=state.keys[key]==true
    state.keys[key]=d
    return d and not was
  end
  local function padDown(button)
    button=tostring(button or ""):lower()
    local br=V and V.BattleRuntime
    if br and type(br.realtimePadIsDown)=="function" then
      local ok,down=pcall(br.realtimePadIsDown,button)
      if ok and down then return true end
    end
    local pad=mappedGamepad()
    return pad and padButtonLive(pad.js,button) or false
  end
  local function mouseDown(button)
    return love and love.mouse and type(love.mouse.isDown)=="function"
      and love.mouse.isDown(button) and true or false
  end
  local function mousePressed(button)
    local d=mouseDown(button)
    local was=state.mouseButtons[button]==true
    state.mouseButtons[button]=d
    return d and not was
  end
  return {
    DEADZONE=PAD_DEADZONE,
    LOOK_SENS=PAD_LOOK_SENS,
    mappedGamepad=mappedGamepad,
    applyDeadzone=applyDeadzone,
    padPressed=padPressed,
    padDown=padDown,
    mouseDown=mouseDown,
    mousePressed=mousePressed,
  }
end)()

local function settings()
  return V and V.BattleSettings
end
function R.enabled(game)
  local s=settings()
  if s and type(s.realtimeEnabled)=="function" then
    local ok,v=pcall(s.realtimeEnabled,game)
    if ok then return v==true end
  end
  return false
end

local function setEnabled(game,value)
  local s=settings()
  if s and type(s.setRealtimeEnabled)=="function" then
    local ok,v=pcall(s.setRealtimeEnabled,game,value)
    if ok then return v==true end
  end
  return false
end

local function resetMouse()
  state.mouseX=nil
  state.mouseY=nil
end

local function setMouseCapture(on)
  if not (love and love.mouse and type(love.mouse.setRelativeMode)=="function") then return false end
  local ok=pcall(love.mouse.setRelativeMode,on==true)
  if ok and love.mouse.setVisible then pcall(love.mouse.setVisible,on~=true) end
  return ok
end

local function baseAnchors(arena)
  local p=arena and arena.visualPlayer or {0,14.5}
  local e=arena and arena.visualEnemy or {0,-14.5}
  return tonumber(p[1]) or 0,tonumber(p[2]) or 14.5,
         tonumber(e[1]) or 0,tonumber(e[2]) or -14.5
end

local function computeArenaRadius(arena,px,pz,ex,ez)
  local mid=arena and arena.mid or {0,0}
  local mx,mz=tonumber(mid[1]) or 0,tonumber(mid[2]) or 0
  local a=len2(px-mx,pz-mz)
  local b=len2(ex-mx,ez-mz)
  -- Keep a useful run-around margin beyond the authored battle slots while
  -- staying well inside the decorative outer geometry.
  return math.max(30,math.max(a,b)+16)
end

local function initialize(context,arena)
  local px,pz,ex,ez=baseAnchors(arena)
  state.battle=context and context.battle or nil
  state.px,state.py,state.pz,state.vy,state.ex,state.ez=px,0,pz,0,ex,ez
  state.playerVelX,state.playerVelZ=0,0
  state.startPX,state.startPY,state.startPZ,state.startEX,state.startEZ=px,0,pz,ex,ez
  state.playerDex,state.flightCapable=flightCapable(context)
  state.flightMode=false
  state.flightState="grounded"
  state.jumpCount=0
  state.flapClock=0
  state.jumpBoostX,state.jumpBoostZ,state.jumpBoostClock=0,0,0
  state.airDashTimer=0;state.airDashElapsed=0;state.airDashIFrame=0;state.airDashUsed=false
  state.airDashDirX,state.airDashDirZ=0,-1
  state.moveCycleHeld=false
  state.moveCycleDebounce=0
  state.maxFlightY=ONIX_BATTLE_HEIGHT
  state.flightStamina=FLIGHT_STAMINA_MAX
  state.flightStaminaMax=FLIGHT_STAMINA_MAX
  state.flightRechargeLock=0
  state.flightGroundTime=0
  state.flightExhausted=false
  state.camEye=nil
  state.camFocus=nil
  state.reticleOnTarget=false;state.reticleAssistActive=false;state.reticleAssistAmount=0;state.reticleAssistCone=0
  state.reticleAimX,state.reticleAimZ=0,-1
  state.reticleDisplayDistance=9;state.reticleWorldX,state.reticleWorldZ=state.px or 0,state.pz or 0
  state.cameraLockHeld=false
  state.mouseButtons={}
  state.uiCursorMode=false
  state.uiCursorActive=false
  state.commandMovesOpen=false
  state.uiHover=nil
  state.playerStatus=nil;state.enemyStatus=nil
  state.playerStatusEvent=nil;state.enemyStatusEvent=nil;state.playerStatusEventTTL=0;state.enemyStatusEventTTL=0
  state.playerSleepTimer=0;state.enemySleepTimer=0;state.playerSleepMonRef=nil;state.enemySleepMonRef=nil
  state.playerFreezeTimer=0;state.enemyFreezeTimer=0;state.playerFreezeMonRef=nil;state.enemyFreezeMonRef=nil
  state.playerConfused=false;state.enemyConfused=false
  state.playerConfuseClock=0;state.playerConfuseAngle=0;state.playerConfuseSeed=16017
  state.enemyConfuseClock=0;state.enemyConfuseAngle=0;state.enemyConfuseSeed=22021
  state.playerHitAnimating=false;state.playerHitActorSeen=false;state.playerHitFallback=0
  state.playerInvuln=0;state.playerFainted=false;state.playerPendingFaintAfterHit=false
  state.enemyHitAnimating=false;state.enemyHitActorSeen=false;state.enemyHitFallback=0
  state.enemyInvuln=0;state.enemyFainted=false;state.enemyPendingFaintAfterHit=false
  state.impactLockActive=false;state.impactAttacker=nil;state.impactDefender=nil
  state.impactSeenAttacker=false;state.impactSeenDefender=false;state.impactMin=0;state.impactFallback=0
  state.impactGuardSide=nil;state.impactGuardHP=nil;state.impactGuardDamage=nil;state.impactGuardTTL=0;state.impactSource=nil
  state.playerFaintHold=false;state.playerFaintSeen=false;state.playerFaintFallback=0
  state.enemyFaintHold=false;state.enemyFaintSeen=false;state.enemyFaintFallback=0
  state.playerMonRef=context and context.battle and context.battle.player and context.battle.player.mon or nil
  state.enemyMonRef=context and context.battle and context.battle.enemy and context.battle.enemy.mon or nil
  state.playerSwitchGuard=0;state.enemySwitchGuard=0
  state.rollTimer=0;state.rollElapsed=0;state.rollCooldown=0;state.rollIFrame=0
  state.rollDirX,state.rollDirZ=0,-1
  state.airDashTimer=0;state.airDashElapsed=0;state.airDashIFrame=0;state.airDashUsed=false
  state.airDashDirX,state.airDashDirZ=0,-1
  refreshMovementSpeeds(context)
  local fx,fz=normalize2(ex-px,ez-pz)
  if fx==0 and fz==0 then fx,fz=0,-1 end
  state.facingX,state.facingZ=fx,fz
  state.enemyFacingX,state.enemyFacingZ=-fx,-fz
  state.enemyMoving=false
  state.enemyAIStrafe=1
  state.enemyAIThink=.18
  state.enemyAIStrafeClock=.9
  state.enemyAIFireClock=ENEMY_AI_REACTION
  state.enemyAIDodgeClock=0
  state.enemyAIMoveCursor=0
  state.enemyAttackSerial=0
  state.enemyAttackAge=0
  state.enemyAttackCooldown=0
  state.enemyAttackCooldownDuration=0
  state.enemyMoveCooldowns={0,0,0,0};state.enemyMoveCooldownDurations={0,0,0,0};state.enemyGlobalAttackLock=0
  state.enemyAttackAccuracyScale=1
  state.enemyAttackKind=nil
  state.enemyAttackProfileClass=nil
  state.enemyAttackTargetX=nil;state.enemyAttackTargetZ=nil
  state.enemyAttackAOERadius=0;state.enemyAttackConeHalfAngle=0
  state.enemyAttackMove=nil
  state.enemyAttackMoveDef=nil
  state.enemyAttackMoveId=nil
  state.enemyAttackMoveSlot=nil
  state.enemyAttackHit=false
  state.enemyAttackResolved=false
  state.enemyAttackPpSpent=false
  state.enemyProjectileX=nil;state.enemyProjectileZ=nil
  state.enemyProjectilePrevX=nil;state.enemyProjectilePrevZ=nil
  state.enemyProjectileVX=0;state.enemyProjectileVZ=0
  state.enemyLastResult="READY"
  state.yaw=atan2(fx,fz)
  state.pitch=0.06
  state.arenaRadius=computeArenaRadius(arena,px,pz,ex,ez)
  state.nav=nil
  state.boundaryMode="fallback-circle"
  state.wallAt=wallClock()
  state.moving=false
  state.attackAge=0
  state.attackCooldown=0
  state.attackCooldownDuration=0
  state.playerMoveCooldowns={0,0,0,0};state.playerMoveCooldownDurations={0,0,0,0};state.playerGlobalAttackLock=0
  state.attackAccuracyScale=1
  state.attackHit=false
  state.attackMotionLock=false
  state.attackActorSeen=false
  state.attackFacingLock=false;state.attackFacingActorSeen=false;state.attackFacingTimer=0
  state.attackFacingX,state.attackFacingZ=state.facingX or 0,state.facingZ or -1
  state.attackResult="READY"
  state.attackMove=nil
  state.attackMoveDef=nil
  state.attackMoveId=nil
  state.attackMoveSlot=nil
  state.attackPP=nil
  state.attackKind=nil
  state.attackRange=0
  state.attackDirX,state.attackDirZ=0,-1
  state.attackTargetX,state.attackTargetZ=nil,nil
  state.attackTargetDistance=0
  state.attackProfileClass=nil;state.attackAOERadius=0;state.attackConeHalfAngle=0
  state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
  state.projectileVX=0;state.projectileVZ=0;state.projectileHomingTimer=0;state.projectileHomingScale=1
  state.projectileRadius=0
  state.attackAssistActive=false;state.attackAssistAmount=0
  state.lastDamage=0
  state.lastCrit=false
  state.lastTypeMult=10
  state.lastHpBefore=nil
  state.lastHpAfter=nil
  state.combatError=nil
  state.selectedMoveSlot=1
  state.selectedMoveId=nil
  state.selectedMoveXdId=nil
  state.selectedMoveCanonical=nil
  state.selectedMoveHasVFX=false
  state.targetPreviewActive=false;state.targetPreviewClass=nil;state.targetPreviewKind=nil
  state.targetPreviewX,state.targetPreviewZ=state.px or 0,state.pz or 0
  state.targetPreviewDirX,state.targetPreviewDirZ=state.facingX or 0,state.facingZ or -1
  state.targetPreviewRange=0;state.targetPreviewRadius=0;state.targetPreviewAngle=0;state.targetPreviewWidth=0
  state.groundCursorInitialized=false;state.groundCursorOwnsWASD=false;state.groundCursorKey=nil
  state.groundCursorX,state.groundCursorZ=state.px or 0,state.pz or 0
  state.utilityRequested=false
  state.vfx=nil;state.enemyVfx=nil
  state.v2Probe=nil;state.enemyV2Probe=nil
  state.persistentMoveVfx={};state.visualBursts={}
  state.impacts={}
  state.actionMessage=nil;state.actionMessageTimer=0;state.actionMessageKind=nil
  state.actionMessageDedupKey=nil;state.actionMessageDedupTTL=0;state.actionMessageQueue={}
  state.playerActionMessage=nil;state.playerActionTimer=0;state.playerActionKind=nil;state.playerActionQueue={}
  state.playerActionDedupKey=nil;state.playerActionDedupTTL=0
  state.enemyActionMessage=nil;state.enemyActionTimer=0;state.enemyActionKind=nil;state.enemyActionQueue={}
  state.enemyActionDedupKey=nil;state.enemyActionDedupTTL=0
  state.nativeTextSideHint=nil;state.nativeTextSideHintTTL=0;state.nativeTextSerial=0
  state.cameraZoom=1.0
  local s=settings()
  if s and type(s.realtimeZoom)=="function" then
    local ok,z=pcall(s.realtimeZoom,context and context.game)
    if ok then state.cameraZoom=clamp(tonumber(z) or 1.0,.65,3.5) end
  end
  resetMouse()
end

function R:begin(context,arena)
  initialize(context,arena)
  state.active=R.enabled(context and context.game)
  if state.active then setMouseCapture(true) end
  return true
end

function R:finish()
  state.battle=nil
  state.active=false
  state.wallAt=nil
  state.moving=false
  state.uiCursorMode=false
  state.uiCursorActive=false
  state.commandMovesOpen=false
  setMouseCapture(false)
  resetMouse()
end

local function applyArena(arena)
  if not arena then return end
  local k=math.max(.08,tonumber(arena.figureScale) or .38)
  arena.visualPlayer={state.px,state.pz}
  arena.visualEnemy={state.ex,state.ez}
  arena.player={state.px/k,state.pz/k}
  arena.enemy={state.ex/k,state.ez/k}
end

local function resetPlayer()
  state.px,state.py,state.pz=state.startPX,state.startPY or 0,state.startPZ
  state.vy=0
  state.playerVelX,state.playerVelZ=0,0
  state.flightMode=false
  state.flightState="grounded"
  state.jumpCount=0
  state.flapClock=0
  state.jumpBoostX,state.jumpBoostZ,state.jumpBoostClock=0,0,0
  state.moveCycleHeld=false
  state.moveCycleDebounce=0
  state.flightStamina=FLIGHT_STAMINA_MAX
  state.flightRechargeLock=0
  state.flightGroundTime=0
  state.flightExhausted=false
  state.playerHitAnimating=false;state.playerHitActorSeen=false;state.playerHitFallback=0
  state.playerInvuln=0;state.playerFainted=false;state.playerPendingFaintAfterHit=false
  state.playerFaintHold=false;state.playerFaintSeen=false;state.playerFaintFallback=0
  state.impactLockActive=false;state.impactAttacker=nil;state.impactDefender=nil
  local fx,fz=normalize2(state.ex-state.px,state.ez-state.pz)
  if fx~=0 or fz~=0 then state.facingX,state.facingZ=fx,fz end
end

local function updateMouse()
  if love and love.mouse and type(love.mouse.setRelativeMode)=="function" then
    local want=state.active==true and state.uiCursorActive~=true
    local current=nil
    if type(love.mouse.getRelativeMode)=="function" then
      local ok,v=pcall(love.mouse.getRelativeMode);if ok then current=v end
    end
    if current~=want then setMouseCapture(want) end
  end

  local br=V and V.BattleRuntime
  local dx,dy=0,0
  if br and type(br.consumeRealtimeMouse)=="function" then
    local ok,x,y=pcall(br.consumeRealtimeMouse)
    if ok then dx,dy=tonumber(x) or 0,tonumber(y) or 0 end
  end

  if dx==0 and dy==0 and love and love.mouse and type(love.mouse.getPosition)=="function" then
    local relative=false
    if type(love.mouse.getRelativeMode)=="function" then
      local ok,v=pcall(love.mouse.getRelativeMode);relative=ok and v==true
    end
    if not relative then
      local x,y=love.mouse.getPosition()
      if state.mouseX~=nil then dx,dy=x-state.mouseX,y-state.mouseY end
      state.mouseX,state.mouseY=x,y
    end
  end

  if dx~=0 or dy~=0 then
    state.yaw=state.yaw-dx*0.0032
    state.pitch=clamp(state.pitch+dy*0.0032,-0.70,1.05)
  end
end

local function arenaNavigation(arena)
  if state.nav then return state.nav end
  local A=V and V.Arena
  if A and type(A.navigation)=="function" then
    local ok,nav=pcall(A.navigation,A,arena)
    if ok and type(nav)=="table" and type(nav.hull)=="table" and #nav.hull>=3 then
      state.nav=nav
      state.boundaryMode="stage-floor+walls"
      local mid=arena and arena.mid or {0,0}
      local mx,mz=tonumber(mid[1]) or 0,tonumber(mid[2]) or 0
      local r=0
      for _,p in ipairs(nav.hull) do
        local dx,dz=(tonumber(p[1]) or 0)-mx,(tonumber(p[2]) or 0)-mz
        r=math.max(r,math.sqrt(dx*dx+dz*dz))
      end
      if r>0 then state.arenaRadius=r end
      return nav
    end
  end
  return nil
end

local function pushFromSegment(x1,z1,x2,z2,radius)
  local vx,vz=x2-x1,z2-z1
  local ll=vx*vx+vz*vz
  if ll<1e-8 then return end
  local t=((state.px-x1)*vx+(state.pz-z1)*vz)/ll
  t=clamp(t,0,1)
  local qx,qz=x1+vx*t,z1+vz*t
  local dx,dz=state.px-qx,state.pz-qz
  local d2=dx*dx+dz*dz
  if d2>=radius*radius then return end
  local d=math.sqrt(d2)
  local nx,nz
  if d>1e-5 then nx,nz=dx/d,dz/d
  else
    local l=math.sqrt(ll);nx,nz=-vz/l,vx/l
    local midx,midz=(x1+x2)*.5,(z1+z2)*.5
    if (state.px-midx)*nx+(state.pz-midz)*nz<0 then nx,nz=-nx,-nz end
  end
  local push=radius-d
  state.px=state.px+nx*push
  state.pz=state.pz+nz*push
end

local function resolveStageNavigation(nav)
  local hull=nav and nav.hull
  if type(hull)~="table" or #hull<3 then return false end
  local pad=state.playerRadius+.18

  -- Convex hull is authored CCW by Arena.lua. Require the Pokemon center to
  -- stay at least its body radius inside every ground edge.
  for _=1,3 do
    local moved=false
    for i=1,#hull do
      local a=hull[i];local b=hull[i%#hull+1]
      local x1,z1=tonumber(a[1]) or 0,tonumber(a[2]) or 0
      local x2,z2=tonumber(b[1]) or 0,tonumber(b[2]) or 0
      local ex,ez=x2-x1,z2-z1
      local l=math.sqrt(ex*ex+ez*ez)
      if l>1e-6 then
        local nx,nz=-ez/l,ex/l
        local dist=(state.px-x1)*nx+(state.pz-z1)*nz
        if dist<pad then
          local push=pad-dist
          state.px=state.px+nx*push
          state.pz=state.pz+nz*push
          moved=true
        end
      end
    end
    if not moved then break end
  end

  -- Low vertical geometry becomes physical barrier segments. This catches
  -- actual walls/rails/pillars inside the walkable floor instead of using an
  -- invisible fixed circle.
  for _,w in ipairs(nav.walls or {}) do
    pushFromSegment(tonumber(w[1]) or 0,tonumber(w[2]) or 0,
      tonumber(w[3]) or 0,tonumber(w[4]) or 0,pad)
  end
  return true
end

local function resolveArenaBoundary(arena)
  local nav=arenaNavigation(arena)
  if nav and resolveStageNavigation(nav) then return end

  local mid=arena and arena.mid or {0,0}
  local mx,mz=tonumber(mid[1]) or 0,tonumber(mid[2]) or 0
  local dx,dz=state.px-mx,state.pz-mz
  local maxR=math.max(2,state.arenaRadius-state.playerRadius)
  local d=len2(dx,dz)
  if d>maxR then
    local nx,nz=normalize2(dx,dz)
    state.px=mx+nx*maxR
    state.pz=mz+nz*maxR
  end
end

local function resolveBodyCollision()
  if (tonumber(state.py) or 0) > (state.playerRadius+state.enemyRadius)*0.78 then return end
  local dx,dz=state.px-state.ex,state.pz-state.ez
  local minD=state.playerRadius+state.enemyRadius
  local d=len2(dx,dz)
  if d<minD then
    local nx,nz
    if d<1e-6 then
      nx,nz=-state.facingX,-state.facingZ
      if nx==0 and nz==0 then nx,nz=0,1 end
    else
      nx,nz=dx/d,dz/d
    end
    state.px=state.ex+nx*minD
    state.pz=state.ez+nz*minD
  end
end

local function tackleBox()
  -- OBB centered in front of the player.  X axis = facing-right, Z axis = facing.
  local fx,fz=normalize2(state.facingX,state.facingZ)
  if fx==0 and fz==0 then fx,fz=0,-1 end
  local rx,rz=-fz,fx
  local forwardOffset=state.playerRadius+math.max(.85,state.playerRadius*.55)
  return {
    cx=state.px+fx*forwardOffset,
    cz=state.pz+fz*forwardOffset,
    fx=fx,fz=fz,rx=rx,rz=rz,
    halfW=math.max(.42,math.max(1.10,state.playerRadius*.90)*(tonumber(state.attackAccuracyScale) or 1)),
    halfD=math.max(.38,math.max(1.00,state.playerRadius*.72)*(tonumber(state.attackAccuracyScale) or 1)),
    height=math.max(2.6,state.playerRadius*2.0),
  }
end

local function circleHitsOBB(cx,cz,r,box)
  local dx,dz=cx-box.cx,cz-box.cz
  local lx=dx*box.rx+dz*box.rz
  local lz=dx*box.fx+dz*box.fz
  local qx=clamp(lx,-box.halfW,box.halfW)
  local qz=clamp(lz,-box.halfD,box.halfD)
  local ex,ez=lx-qx,lz-qz
  return ex*ex+ez*ez<=r*r
end


local function pointSegmentDistance2(px,pz,ax,az,bx,bz)
  local vx,vz=bx-ax,bz-az
  local ll=vx*vx+vz*vz
  if ll<1e-8 then
    local dx,dz=px-ax,pz-az
    return dx*dx+dz*dz
  end
  local t=((px-ax)*vx+(pz-az)*vz)/ll
  t=clamp(t,0,1)
  local qx,qz=ax+vx*t,az+vz*t
  local dx,dz=px-qx,pz-qz
  return dx*dx+dz*dz
end

local function attackDirection()
  local fx,fz=normalize2(state.attackDirX or 0,state.attackDirZ or 0)
  if fx==0 and fz==0 then fx,fz=normalize2(state.facingX,state.facingZ) end
  -- Never fall back to enemy direction: zero/invalid aim uses a fixed forward
  -- vector rather than silently reintroducing auto-targeting.
  if fx==0 and fz==0 then fx,fz=0,-1 end
  return fx,fz
end

function R._playerTargetRadius()
  return (tonumber(state.enemyRadius) or 1.9)*R._PLAYER_TARGET_RADIUS_SCALE*R._evasionTargetScale(state.battle and state.battle.enemy)
end

function R._enemyTargetRadius()
  return (tonumber(state.playerRadius) or 1.75)*R._evasionTargetScale(state.battle and state.battle.player)
end

local function lineCapsuleHitsEnemy(range,radius)
  local fx,fz=attackDirection()
  local ax,az=state.px+fx*state.playerRadius,state.pz+fz*state.playerRadius
  local bx,bz=ax+fx*range,az+fz*range
  local rr=(radius+R._playerTargetRadius())
  return pointSegmentDistance2(state.ex,state.ez,ax,az,bx,bz)<=rr*rr
end

local function moveName(v)
  return tostring(v or ""):upper():gsub("[%s%-]+","_"):gsub("[^A-Z0-9_]","")
end

local TYPE_COLORS={
  NORMAL={0.92,0.92,0.86},FIRE={1.00,0.30,0.06},WATER={0.18,0.58,1.00},
  ELECTRIC={1.00,0.86,0.10},GRASS={0.28,0.86,0.22},ICE={0.48,0.92,1.00},
  FIGHTING={0.92,0.24,0.18},POISON={0.72,0.30,0.82},GROUND={0.76,0.57,0.27},
  FLYING={0.62,0.78,1.00},PSYCHIC={1.00,0.30,0.66},BUG={0.65,0.80,0.16},
  ROCK={0.72,0.62,0.34},GHOST={0.48,0.38,0.72},DRAGON={0.44,0.30,1.00},
  DARK={0.34,0.28,0.28},STEEL={0.68,0.72,0.82},
}

local function moveType(def)
  local t=moveName(def and (def.type or def.moveType or def.element) or "NORMAL")
  t=t:gsub("_TYPE$","")
  if t=="LIGHTNING" then t="ELECTRIC" end
  return TYPE_COLORS[t] and t or "NORMAL"
end

local function copyColor(c)
  return {tonumber(c and c[1]) or 1,tonumber(c and c[2]) or 1,tonumber(c and c[3]) or 1}
end

-- Comprehensive move-presentation families --------------------------------
-- The authoritative BattleState remains responsible for PP, damage, hit count,
-- status, stat stages, charging, trapping, recoil and all other mechanics.
-- These tables only choose a visual treatment after a move has already been
-- classified by MoveTargeting / the battle engine.
R._PRESENT_POWDER={
  SLEEP_POWDER=true,POISONPOWDER=true,POISON_POWDER=true,STUN_SPORE=true,
  SPORE=true,COTTON_SPORE=true,SWEET_SCENT=true,
}
R._PRESENT_MULTI={
  DOUBLESLAP=true,DOUBLE_SLAP=true,COMET_PUNCH=true,FURY_ATTACK=true,PIN_MISSILE=true,
  SPIKE_CANNON=true,BARRAGE=true,FURY_SWIPES=true,BONE_RUSH=true,ROCK_BLAST=true,
  BULLET_SEED=true,ARM_THRUST=true,ICICLE_SPEAR=true,TRIPLE_KICK=true,TWINEEDLE=true,
}
R._PRESENT_CHARGE={
  SOLARBEAM=true,SOLAR_BEAM=true,DIG=true,FLY=true,SKULL_BASH=true,RAZOR_WIND=true,
  SKY_ATTACK=true,BOUNCE=true,DIVE=true,FOCUS_PUNCH=true,
}
R._PRESENT_DRAIN={
  ABSORB=true,MEGA_DRAIN=true,GIGA_DRAIN=true,LEECH_LIFE=true,DREAM_EATER=true,
}
R._PRESENT_HEAL={
  RECOVER=true,SOFTBOILED=true,SOFT_BOILED=true,REST=true,MILK_DRINK=true,
  SYNTHESIS=true,MORNING_SUN=true,MOONLIGHT=true,WISH=true,SLACK_OFF=true,
}
R._PRESENT_TRAP={
  LEECH_SEED=true,WRAP=true,BIND=true,FIRE_SPIN=true,CLAMP=true,WHIRLPOOL=true,
  SAND_TOMB=true,INGRAIN=true,
}
R._PRESENT_BARRIER={
  REFLECT=true,LIGHT_SCREEN=true,MIST=true,SAFEGUARD=true,PROTECT=true,DETECT=true,
}
R._PRESENT_GROUND={
  EARTHQUAKE=true,FISSURE=true,MAGNITUDE=true,ROCK_SLIDE=true,ROCK_TOMB=true,
  MUD_SLAP=true,MUD_SHOT=true,EARTH_POWER=true,BONEMERANG=true,BONE_CLUB=true,
}
R._PRESENT_EXPLOSION={SELFDESTRUCT=true,SELF_DESTRUCT=true,EXPLOSION=true}
R._PRESENT_RECOIL={
  TAKE_DOWN=true,DOUBLE_EDGE=true,SUBMISSION=true,STRUGGLE=true,VOLT_TACKLE=true,
  WOOD_HAMMER=true,HEAD_SMASH=true,
}
R._PRESENT_STAT_UP={
  SWORDS_DANCE=true,GROWTH=true,MEDITATE=true,AGILITY=true,HARDEN=true,MINIMIZE=true,
  DEFENSE_CURL=true,BARRIER=true,LIGHT_SCREEN=true,REFLECT=true,AMNESIA=true,
  SHARPEN=true,WITHDRAW=true,ACID_ARMOR=true,DOUBLE_TEAM=true,FOCUS_ENERGY=true,
  BULK_UP=true,CALM_MIND=true,DRAGON_DANCE=true,COSMIC_POWER=true,IRON_DEFENSE=true,
  HOWL=true,TAIL_GLOW=true,
}
R._PRESENT_STAT_DOWN={
  GROWL=true,TAIL_WHIP=true,LEER=true,STRING_SHOT=true,SCREECH=true,SAND_ATTACK=true,
  SMOKESCREEN=true,KINESIS=true,FLASH=true,CHARM=true,FEATHERDANCE=true,FAKE_TEARS=true,
  METAL_SOUND=true,TICKLE=true,SWEET_SCENT=true,COTTON_SPORE=true,
}
R._PRESENT_UNIQUE={
  SEISMIC_TOSS=true,NIGHT_SHADE=true,METRONOME=true,TRANSFORM=true,MIMIC=true,
  GUILLOTINE=true,HORN_DRILL=true,COUNTER=true,MIRROR_COAT=true,BIDE=true,
  TELEPORT=true,CONVERSION=true,CONVERSION_2=true,PSYWAVE=true,SONICBOOM=true,
  DRAGON_RAGE=true,SUPER_FANG=true,ENDEAVOR=true,PAIN_SPLIT=true,DESTINY_BOND=true,
  PERISH_SONG=true,
}

function R._fx.presentationFamily(moveId,def,kind)
  local n=moveName(moveId)
  if R._PRESENT_POWDER[n] then return "powder" end
  if R._PRESENT_DRAIN[n] then return "drain" end
  if R._PRESENT_HEAL[n] then return "heal" end
  if n=="SUBSTITUTE" then return "substitute" end
  if R._PRESENT_BARRIER[n] then return "barrier" end
  if R._PRESENT_EXPLOSION[n] then return "explosion" end
  if R._PRESENT_GROUND[n] then return "ground" end
  if R._PRESENT_TRAP[n] then return "persistent" end
  if R._PRESENT_CHARGE[n] then return "charge" end
  if R._PRESENT_MULTI[n] then return "multi" end
  if R._PRESENT_RECOIL[n] then return "recoil" end
  if R._PRESENT_STAT_UP[n] then return "stat-up" end
  if R._PRESENT_STAT_DOWN[n] then return "stat-down" end
  if R._PRESENT_UNIQUE[n] then return "unique" end
  return kind or "contact"
end

function R._fx.sideAttackAge(side)
  return side=="enemy" and (tonumber(state.enemyAttackAge) or 0) or (tonumber(state.attackAge) or 0)
end
function R._fx.sideAttackDuration(side)
  return side=="enemy" and (tonumber(state.enemyAttackDuration) or .6) or (tonumber(state.attackDuration) or .6)
end
function R._fx.sideAttackActiveStart(side)
  return side=="enemy" and (tonumber(state.enemyAttackActiveStart) or .15) or (tonumber(state.attackActiveStart) or .15)
end
function R._fx.sideAttackActiveEnd(side)
  return side=="enemy" and (tonumber(state.enemyAttackActiveEnd) or .4) or (tonumber(state.attackActiveEnd) or .4)
end
function R._fx.sideProjectile(side)
  if side=="enemy" then return state.enemyProjectileX,state.enemyProjectileZ end
  return state.projectileX,state.projectileZ
end
function R._fx.sideWorld(side)
  if side=="enemy" then return state.ex,state.ez,state.px,state.pz end
  return state.px,state.pz,state.ex,state.ez
end

function R._fx.beginSideVFX(side,moveId,def,kind,xdVFX,xdId,canonical)
  local n=moveName(moveId)
  local t=moveType(def)
  local sx,sz,ox,oz=R._fx.sideWorld(side)
  local targetX,targetZ
  if side=="enemy" then
    targetX=state.enemyAttackTargetX or ox;targetZ=state.enemyAttackTargetZ or oz
  else
    targetX=state.attackTargetX or ox;targetZ=state.attackTargetZ or oz
  end
  local px,pz=R._fx.sideProjectile(side)
  local v={
    side=side,serial=side=="enemy" and state.enemyAttackSerial or state.attackSerial,
    name=n,type=t,kind=kind,family=R._fx.presentationFamily(n,def,kind),
    color=copyColor(TYPE_COLORS[t]),age=0,fade=0,trail={},trailClock=0,
    sourceX=sx,sourceZ=sz,targetX=targetX,targetZ=targetZ,
    collisionStartX=px,collisionStartZ=pz,launchSource=nil,
    xdSource=type(xdVFX)=="table" and xdVFX or nil,
    xdMoveId=tonumber(xdId),xdCanonical=canonical,
    beat=-1,
  }
  if side=="enemy" then state.enemyVfx=v else state.vfx=v end
  return v
end

local function beginSimplifiedVFX(moveId,def,kind,xdVFX,xdId,canonical)
  return R._fx.beginSideVFX("player",moveId,def,kind,xdVFX,xdId,canonical)
end

function R._fx.spawnImpactForSide(side,x,z)
  local v=side=="enemy" and state.enemyVfx or state.vfx
  local color=copyColor(v and v.color or TYPE_COLORS.NORMAL)
  local tx,tz
  if side=="enemy" then tx,tz=state.px,state.pz else tx,tz=state.ex,state.ez end
  state.hitSerial=state.hitSerial+1
  state.impacts[#state.impacts+1]={
    serial=state.hitSerial,x=tonumber(x) or tx,z=tonumber(z) or tz,y=2.15,
    age=0,duration=.40,color=color,type=v and v.type or "NORMAL",side=side,
  }
end

local function spawnImpactVFX(x,z)
  return R._fx.spawnImpactForSide("player",x,z)
end

function R._fx.updateOneSideVFX(side,dt)
  local key=side=="enemy" and "enemyVfx" or "vfx"
  local v=state[key]
  if not v then return end
  v.age=(tonumber(v.age) or 0)+dt
  v.trailClock=(tonumber(v.trailClock) or 0)+dt
  local px,pz=R._fx.sideProjectile(side)
  if v.kind=="projectile" and px then
    if v.trailClock>=.025 or #v.trail==0 then
      v.trailClock=0
      v.trail[#v.trail+1]={x=px,z=pz,age=0}
      if #v.trail>18 then table.remove(v.trail,1) end
    end
  end
  for _,p in ipairs(v.trail or {}) do p.age=(tonumber(p.age) or 0)+dt end
  while v.trail and v.trail[1] and (tonumber(v.trail[1].age) or 0)>.38 do table.remove(v.trail,1) end
  if R._fx.sideAttackAge(side)<=0 then
    v.fade=(tonumber(v.fade) or 0)+dt
    if v.fade>.24 then state[key]=nil end
  end
end

local function updateSimplifiedVFX(dt)
  R._fx.updateOneSideVFX("player",dt)
  R._fx.updateOneSideVFX("enemy",dt)
  for i=#state.impacts,1,-1 do
    local p=state.impacts[i];p.age=(tonumber(p.age) or 0)+dt
    if p.age>=(tonumber(p.duration) or .4) then table.remove(state.impacts,i) end
  end
  for i=#(state.persistentMoveVfx or {}),1,-1 do
    local p=state.persistentMoveVfx[i]
    p.age=(tonumber(p.age) or 0)+dt
    if p.age>=(tonumber(p.duration) or 5) then table.remove(state.persistentMoveVfx,i) end
  end
end

local PROJECTILE_MOVES={
  EMBER=true,SHADOW_BALL=true,RAZOR_LEAF=true,MAGICAL_LEAF=true,
  BULLET_SEED=true,MUD_SHOT=true,WATER_PULSE=true,ROCK_THROW=true,
  SLUDGE_BOMB=true,ENERGY_BALL=true,SWIFT=true,PAY_DAY=true,
  PIN_MISSILE=true,SPIKE_CANNON=true,BONE_CLUB=true,BONEMERANG=true,
  EGG_BOMB=true,BARRAGE=true,SEED_BOMB=true,ROCK_BLAST=true,ICE_SHARD=true,
  AURA_SPHERE=true,FOCUS_BLAST=true,SHADOW_SNEAK=true,
}
local STREAM_MOVES={
  FLAMETHROWER=true,WATER_GUN=true,HYDRO_PUMP=true,ICE_BEAM=true,
  HYPER_BEAM=true,AURORA_BEAM=true,PSYBEAM=true,DRAGON_BREATH=true,
  HEAT_WAVE=true,WATER_SPOUT=true,SOLARBEAM=true,SOLAR_BEAM=true,
  BUBBLE=true,BUBBLEBEAM=true,ACID=true,SLUDGE=true,SONICBOOM=true,
  DRAGON_RAGE=true,MEGA_DRAIN=true,GIGA_DRAIN=true,LEECH_LIFE=true,
}
local TARGET_LINE_MOVES={
  THUNDERBOLT=true,THUNDER_SHOCK=true,THUNDER=true,SHOCK_WAVE=true,
  PSYCHIC=true,SIGNAL_BEAM=true,NIGHT_SHADE=true,PSYWAVE=true,
  CONFUSION=true,DREAM_EATER=true,SEISMIC_TOSS=true,
}
local CONTACT_WORDS={
  "TACKLE","PUNCH","KICK","SLASH","CLAW","BITE","FANG","HEADBUTT",
  "STOMP","BODY_SLAM","TAKE_DOWN","QUICK_ATTACK","SCRATCH","CUT","PECK",
  "WING_ATTACK","DRILL_PECK","SLAM","WRAP","BIND","THRASH","CRUNCH",
  "EXTREMESPEED","EXTREME_SPEED","AQUA_JET","MACH_PUNCH","SUCKER_PUNCH",
}
local PRE_GEN4_PHYSICAL_TYPE={
  NORMAL=true,FIGHTING=true,FLYING=true,POISON=true,GROUND=true,
  ROCK=true,BUG=true,GHOST=true,STEEL=true,
}

local function hasContactWord(name)
  for _,w in ipairs(CONTACT_WORDS) do if name:find(w,1,true) then return true end end
  return false
end

local function damagingMove(def)
  if type(def)~="table" then return false end
  local p=tonumber(def.power or def.basePower or def.damage)
  return p~=nil and p>0
end

-- Status/self/field moves should not require an enemy lock. Prefer explicit
-- move metadata, then a narrow list of engine effects whose subject is the user
-- or field. Opponent status moves still need manual aim/collision.
local SELF_FIELD_EFFECTS={
  HEAL_EFFECT=true,HEAL_SELF_EFFECT=true,REST_EFFECT=true,SUBSTITUTE_EFFECT=true,
  FOCUS_ENERGY_EFFECT=true,BIDE_EFFECT=true,CHARGE_EFFECT=true,
  CONVERSION_EFFECT=true,HAZE_EFFECT=true,MIST_EFFECT=true,
  LIGHT_SCREEN_EFFECT=true,REFLECT_EFFECT=true,SWITCH_AND_TELEPORT_EFFECT=true,
  EXP_WEATHER_SUNNY=true,EXP_WEATHER_RAINY=true,EXP_WEATHER_SANDSTORM=true,
  EXP_WEATHER_HAIL=true,EXP_PROTECT_EFFECT=true,EXP_ENDURE_EFFECT=true,
  EXP_BELLY_DRUM_EFFECT=true,EXP_REFRESH_EFFECT=true,EXP_INGRAIN_EFFECT=true,
  EXP_AQUA_RING_EFFECT=true,EXP_WISH_EFFECT=true,EXP_HEAL_BELL_EFFECT=true,
  EXP_STOCKPILE_EFFECT=true,EXP_SWALLOW_EFFECT=true,EXP_HEALING_WISH_EFFECT=true,
  EXP_TRICK_ROOM_EFFECT=true,EXP_LUCKY_CHANT_EFFECT=true,EXP_TAILWIND_EFFECT=true,
  EXP_SAFEGUARD_EFFECT=true,EXP_MAGIC_COAT_EFFECT=true,EXP_GRUDGE_EFFECT=true,
  EXP_MUD_SPORT_EFFECT=true,EXP_WATER_SPORT_EFFECT=true,EXP_SNATCH_EFFECT=true,
  EXP_POWER_TRICK_EFFECT=true,EXP_CHARGE_EFFECT=true,EXP_ACUPRESSURE_EFFECT=true,
  EXP_CAMOUFLAGE_EFFECT=true,EXP_IMPRISON_EFFECT=true,EXP_BATON_PASS_EFFECT=true,
  EXP_RECYCLE_EFFECT=true,EXP_DESTINY_BOND_EFFECT=true,EXP_PERISH_SONG_EFFECT=true,
  EXP_SPIKES_EFFECT=true,EXP_STEALTH_ROCK_EFFECT=true,EXP_TOXIC_SPIKES_EFFECT=true,
  EXP_FOLLOW_ME_EFFECT=true,EXP_ALLY_SWITCH_EFFECT=true,EXP_HELPING_HAND_EFFECT=true,
}
local SELF_FIELD_MOVES={
  -- Gen I setup/recovery/field moves.
  SWORDS_DANCE=true,GROWTH=true,MEDITATE=true,AGILITY=true,DOUBLE_TEAM=true,
  MINIMIZE=true,HARDEN=true,WITHDRAW=true,DEFENSE_CURL=true,BARRIER=true,
  FOCUS_ENERGY=true,AMNESIA=true,ACID_ARMOR=true,SHARPEN=true,RECOVER=true,
  REST=true,SOFTBOILED=true,SUBSTITUTE=true,BIDE=true,SPLASH=true,
  CONVERSION=true,HAZE=true,MIST=true,LIGHT_SCREEN=true,REFLECT=true,TELEPORT=true,
  -- Expanded/Kanto-Reforged self or battlefield moves.
  SUNNY_DAY=true,RAIN_DANCE=true,SANDSTORM=true,HAIL=true,PROTECT=true,DETECT=true,
  BELLY_DRUM=true,SYNTHESIS=true,MOONLIGHT=true,MORNING_SUN=true,MILK_DRINK=true,
  SLACK_OFF=true,ROOST=true,HEAL_ORDER=true,IRON_DEFENSE=true,ROCK_POLISH=true,
  AUTOTOMIZE=true,HOWL=true,ENDURE=true,WISH=true,HEAL_BELL=true,AROMATHERAPY=true,
  SAFEGUARD=true,REFRESH=true,INGRAIN=true,AQUA_RING=true,STOCKPILE=true,SWALLOW=true,
  DESTINY_BOND=true,PERISH_SONG=true,BATON_PASS=true,MAGIC_COAT=true,GRUDGE=true,
  MUD_SPORT=true,WATER_SPORT=true,SNATCH=true,ACUPRESSURE=true,CAMOUFLAGE=true,
  IMPRISON=true,POWER_TRICK=true,CHARGE=true,LUCKY_CHANT=true,TAILWIND=true,
  TRICK_ROOM=true,HEALING_WISH=true,SPIKES=true,STEALTH_ROCK=true,TOXIC_SPIKES=true,
  FOLLOW_ME=true,RAGE_POWDER=true,ALLY_SWITCH=true,HELPING_HAND=true,RECYCLE=true,
}
local function moveTargetsSelfOrField(moveId,def)
  if damagingMove(def) then return false end
  local st=tostring(def and (def.statTarget or def.target or def.moveTarget) or ""):lower()
  if st=="target" or st=="opponent" or st=="foe" or st=="selected-pokemon" then return false end
  if st=="user" or st=="self" or st=="field" or st=="users-field" or st=="user-side"
      or st=="ally-side" or st=="entire-field" then return true end

  local n=moveName(moveId)
  if SELF_FIELD_MOVES[n] then return true end
  local effect=moveName(def and def.effect or "")
  if SELF_FIELD_EFFECTS[effect]==true then return true end

  -- Vanilla stage-raising effect ids are self-targeted even though the old
  -- Gen1 move table has no explicit target metadata. Opponent stage drops use
  -- *_DOWN* and therefore remain manually aimed.
  if effect:match("^ATTACK_UP%d?_EFFECT$")
      or effect:match("^DEFENSE_UP%d?_EFFECT$")
      or effect:match("^SPEED_UP%d?_EFFECT$")
      or effect:match("^SPECIAL_UP%d?_EFFECT$")
      or effect:match("^ACCURACY_UP%d?_EFFECT$")
      or effect:match("^EVASION_UP%d?_EFFECT$") then
    return true
  end
  return false
end

-- Moves whose effect is centered on the user/arena rather than on a ray. They
-- still require the opponent to be inside the authored radius before the
-- authoritative move pipeline is invoked, but camera yaw cannot auto-target it.
local RADIAL_MOVES={
  SELFDESTRUCT=true,SELF_DESTRUCT=true,EXPLOSION=true,EARTHQUAKE=true,
  MAGNITUDE=true,SURF=true,DISCHARGE=true,LAVA_PLUME=true,SLUDGE_WAVE=true,
  BOOMBURST=true,RAZOR_WIND=false,
}

local function classifyRealtimeMove(moveId,def)
  local n=moveName(moveId)
  local profile=R._moveTargetProfile(moveId,def)
  if profile then
    local c=tostring(profile.class or ""):upper()
    if c=="SELF" or c=="FIELD" then return "self",0,0,profile end
    if c=="SELF_AOE" then return "radial",math.max(2,tonumber(profile.radius) or 6),0,profile end
    if c=="GROUND_AOE" or c=="TRAP_ZONE" then
      return "ground-aoe",math.max(2,tonumber(profile.range) or 18),math.max(.5,tonumber(profile.radius) or 4),profile
    end
    if c=="CONE" then
      return "cone",math.max(2,tonumber(profile.range) or 10),math.max(5,tonumber(profile.angle) or 45),profile
    end
    if c=="LINE" then
      return "stream",math.max(2,tonumber(profile.range) or 16),math.max(.45,(tonumber(profile.width) or 2.5)*.5),profile
    end
    if c=="PROJECTILE" or c=="HOMING_PROJECTILE" then
      return "projectile",math.max(2,tonumber(profile.range) or 18),math.max(.35,tonumber(profile.radius) or 1.5),profile
    end
    if c=="TARGETED" then return "target-line",math.max(2,tonumber(profile.range) or 15),1.45,profile end
    if c=="MELEE" then return "contact",math.max(2.8,tonumber(profile.range) or 3),1.1,profile end
    -- DASH remains a close committed contact attack for now; the profile still
    -- drives its short red approach lane without silently granting ranged hits.
    if c=="DASH" then return "contact",4.5,1.1,profile end
    -- SPECIAL intentionally falls through to the proven legacy resolver.
  end

  if moveTargetsSelfOrField(moveId,def) then return "self",0,0,profile end
  if RADIAL_MOVES[n] then return "radial",math.max(6,tonumber(def and def.realtimeRange) or 9),0,profile end
  if PROJECTILE_MOVES[n] then return "projectile",18,.9,profile end
  if STREAM_MOVES[n] then return "stream",16,(n=="FLAMETHROWER" and 2.05 or 1.55),profile end
  if TARGET_LINE_MOVES[n] then return "target-line",18,1.8,profile end
  if hasContactWord(n) then return "contact",4.5,1.1,profile end

  local c=tostring(def and (def.category or def.damageClass or def.class) or ""):lower()
  local typ=moveType(def)
  local physical=(c:find("physical",1,true)~=nil)
      or (c=="" and PRE_GEN4_PHYSICAL_TYPE[typ]==true)
  if physical and damagingMove(def) then return "contact",4.5,1.1,profile end
  if damagingMove(def) then return "stream",15,1.25,profile end
  return "target-line",14,1.45,profile
end

function R._selectedTargetProfile(context)
  local battle=context and context.battle
  local slot=tonumber(state.selectedMoveSlot) or 1
  local inst=battle and battle.player and battle.player.curMoves and battle.player.curMoves[slot] or nil
  if not inst then return nil,nil,18,0,nil,nil end
  local def=battle and battle.data and battle.data.moves and (battle.data.moves[inst.id] or battle.data.moves[tonumber(inst.id)]) or nil
  if type(def)~="table" then return nil,nil,18,0,nil,inst end
  local kind,range,radius,profile=classifyRealtimeMove(inst.id,def)
  return profile,kind,range,radius,def,inst
end

-- v0.6.32: Circle/trap targeting owns WASD while it is selected. The cursor is
-- seeded once from the live camera ray, then moves independently in camera-
-- relative X/Z space. Rotating/zooming the camera no longer drags the cursor.
-- The point is continuously clamped to the selected move's spherical cast
-- radius around the Pokemon, including after rolls/dashes move the caster.
R._GROUND_CURSOR_MIN_SPEED=8.0
R._GROUND_CURSOR_MAX_SPEED=16.0
R._GROUND_CURSOR_RANGE_SCALE=.85

function R._updateGroundTargetCursor(context,dt,ix,iz)
  local profile,kind,range,radius,def,inst=R._selectedTargetProfile(context)
  local cls=profile and tostring(profile.class or ""):upper() or ""
  local isGround=(cls=="GROUND_AOE" or cls=="TRAP_ZONE")
  if not isGround then
    state.groundCursorOwnsWASD=false
    state.groundCursorInitialized=false
    state.groundCursorKey=nil
    return false
  end

  range=math.max(.5,tonumber(range) or 18)
  local key=tostring(tonumber(state.selectedMoveSlot) or 1)..":"..tostring(inst and inst.id or state.selectedMoveId or "?")..":"..cls
  if not state.groundCursorInitialized or state.groundCursorKey~=key then
    local tx,tz=R._cameraGroundTargetPoint(range)
    state.groundCursorX,state.groundCursorZ=tx,tz
    state.groundCursorInitialized=true
    state.groundCursorKey=key
  end

  local px,pz=tonumber(state.px) or 0,tonumber(state.pz) or 0
  local cx,cz=tonumber(state.groundCursorX) or px,tonumber(state.groundCursorZ) or pz

  -- Keep an already-placed cursor legal if the caster itself moved.
  local vx,vz=cx-px,cz-pz
  local d=len2(vx,vz)
  if d>range then
    vx,vz=normalize2(vx,vz)
    cx,cz=px+vx*range,pz+vz*range
  end

  local owns=(tonumber(state.attackAge) or 0)<=0
    and not state.nativeModalActive and not state.uiCursorActive
  state.groundCursorOwnsWASD=owns
  if owns and (ix~=0 or iz~=0) then
    local sy,cy=math.sin(state.yaw or 0),math.cos(state.yaw or 0)
    local mx,mz=-cy*ix+sy*iz,sy*ix+cy*iz
    if len2(mx,mz)>.001 then
      mx,mz=normalize2(mx,mz)
      local speed=clamp(range*R._GROUND_CURSOR_RANGE_SCALE,R._GROUND_CURSOR_MIN_SPEED,R._GROUND_CURSOR_MAX_SPEED)
      if isDown("lshift") or isDown("rshift") then speed=speed*1.55 end
      cx,cz=cx+mx*speed*math.max(0,tonumber(dt) or 0),cz+mz*speed*math.max(0,tonumber(dt) or 0)
    end
  end

  -- Hard circular range clamp after movement. This is the same origin/range
  -- used by the targeting telegraph and the eventual LMB world-position lock.
  vx,vz=cx-px,cz-pz
  d=len2(vx,vz)
  if d>range then
    vx,vz=normalize2(vx,vz)
    cx,cz=px+vx*range,pz+vz*range
  end

  state.groundCursorX,state.groundCursorZ=cx,cz
  return owns
end

local function attackActive()
  return state.attackAge>=state.attackActiveStart
    and state.attackAge<=state.attackActiveEnd
end

local function gen1Battle(context)
  local battle=context and context.battle
  if type(battle)~="table" then return nil,"NO BATTLE" end
  -- GenerationCompat decorates Gen2 facades with __cbeGeneration=2.  This
  -- prototype intentionally mutates only the Gen1 BattleState whose public
  -- fields/methods were verified in gen1recomp 0.2.56.
  if battle.__cbeGeneration==2 then return nil,"GEN2 NOT SUPPORTED" end
  if type(battle.player)~="table" or type(battle.enemy)~="table"
      or type(battle.data)~="table" then return nil,"GEN1 STATE UNAVAILABLE" end
  return battle
end

local function syncCollisionRadii(context)
  local csm=V and V.CurrentSpriteModels
  if not (csm and type(csm.realtimeActorMetrics)=="function") then return end
  local okP,p=pcall(csm.realtimeActorMetrics,csm,"player",context)
  local okE,e=pcall(csm.realtimeActorMetrics,csm,"enemy",context)
  if okP and type(p)=="table" then
    if tonumber(p.radius) then state.playerRadius=clamp(tonumber(p.radius),.68,5.5) end
    if tonumber(p.height) then state.playerHeight=math.max(.8,tonumber(p.height)) end
  end
  if okE and type(e)=="table" then
    if tonumber(e.radius) then state.enemyRadius=clamp(tonumber(e.radius),.68,5.5) end
    if tonumber(e.height) then state.enemyHeight=math.max(.8,tonumber(e.height)) end
  end
end

local function findTackle(battle)
  local player=battle and battle.player
  for slot,move in ipairs((player and player.curMoves) or {}) do
    if move and (move.id=="TACKLE" or tonumber(move.id)==33) then
      local def=battle.data and battle.data.moves and battle.data.moves[move.id]
      if not def and battle.data and battle.data.moves then
        def=battle.data.moves.TACKLE or battle.data.moves[33]
      end
      return move,slot,def
    end
  end
  return nil,nil,nil
end

local function dxMoveApi(context)
  local lookup=V and V.ModLookup
  if lookup and type(lookup.find)=="function" then
    local h=lookup.find(V.mod,"POKEMON_XD_GEN1")
    local e=h and h.exports
    local api=e and (e.pokemon_xd_386 or e.stadiumdx)
    if type(api)=="table" then return api end
  end
  local api=rawget(_G,"POKEMON_XD_386_API") or rawget(_G,"POKEMON_XD_API")
  return type(api)=="table" and api or nil
end

-- GPT1 V2 bank probe -------------------------------------------------------
-- XD WZX Particle/Effect payloads use the 0x01F056DA bank signature. The
-- exact peBankLoadFile layout is still under investigation, so this scanner is
-- intentionally read-only: it proves what live retail bank(s) are present and
-- exposes stable header words/pointer-like fields without pretending to decode
-- particles yet.
local GPT1V2_MAGIC=string.char(0x01,0xF0,0x56,0xDA)

local function be32str(data,pos)
  if type(data)~="string" then return nil end
  local a,b,c,d=data:byte(pos,pos+3)
  if not d then return nil end
  return (((a*256)+b)*256+c)*256+d
end

local function hex8(v)
  v=tonumber(v)
  if not v then return "--------" end
  return string.format("%08X",v%4294967296)
end

local function scanGPT1V2Banks(data)
  local out={}
  if type(data)~="string" then return out end
  local pos=1
  while #out<8 do
    local p=data:find(GPT1V2_MAGIC,pos,true)
    if not p then break end
    local words={}
    for off=0,0x38,4 do words[#words+1]=be32str(data,p+off) end
    local ptrs={}
    -- The retail V2 header contains several relative-looking fields. Record
    -- only aligned in-range candidates; interpretation remains deliberately
    -- separate from this diagnostic.
    for off=4,0x38,4 do
      local w=be32str(data,p+off)
      if w and w>=0x40 and w<#data and (w%4)==0 then
        ptrs[#ptrs+1]={off=off,value=w}
        if #ptrs>=6 then break end
      end
    end
    out[#out+1]={offset=p-1,words=words,pointers=ptrs}
    pos=p+4
  end
  return out
end

local function probeGPT1V2(context,vfx,xdId,canonical)
  local api=dxMoveApi(context)
  local result={move=canonical or state.selectedMoveId,xdId=xdId,phases={},error=nil}
  if not (api and type(api.readVFX)=="function") then
    result.error="Gen1DX386 readVFX API unavailable"
    state.v2Probe=result
    return result
  end
  for _,role in ipairs({"attack","damage","special"}) do
    local ref=type(vfx)=="table" and vfx[role] or nil
    if ref then
      local ok,data=pcall(api.readVFX,ref)
      local phase={role=role,path=type(ref)=="table" and (ref.path or ref.wzx or ref.file) or tostring(ref)}
      if ok and type(data)=="string" then
        phase.bytes=#data
        phase.version=be32str(data,0x81)
        phase.entryCount=be32str(data,0x75)
        phase.banks=scanGPT1V2Banks(data)
      else
        phase.error=tostring(ok and "no WZX bytes" or data)
        phase.banks={}
      end
      result.phases[#result.phases+1]=phase
    end
  end
  if #result.phases==0 then result.error="move has no XD WZX phase refs" end
  state.v2Probe=result
  return result
end

local function drawGPT1V2Probe()
  local P=state.v2Probe
  local g=love and love.graphics
  if not (P and g and type(g.print)=="function") then return end
  local lines={}
  lines[#lines+1]="GPT1 V2 RETAIL BANK PROBE  move="..tostring(P.move or "-").."  XD="..tostring(P.xdId or "-")
  if P.error then lines[#lines+1]="ERR: "..tostring(P.error) end
  for _,phase in ipairs(P.phases or {}) do
    local banks=phase.banks or {}
    lines[#lines+1]=string.format("%s  WZXv%s  bytes=%s  banks=%d  %s",
      string.upper(phase.role or "?"),tostring(phase.version or "?"),tostring(phase.bytes or "?"),#banks,tostring(phase.path or ""))
    if phase.error then lines[#lines+1]="  ERR: "..tostring(phase.error) end
    for i,b in ipairs(banks) do
      local w=b.words or {}
      local pc={}
      for _,q in ipairs(b.pointers or {}) do pc[#pc+1]=string.format("+%02X=%X",q.off,q.value) end
      lines[#lines+1]=string.format("  B%d @%06X  H04=%s H08=%s H0C=%s H10=%s  ptr[%s]",
        i,tonumber(b.offset) or 0,hex8(w[2]),hex8(w[3]),hex8(w[4]),hex8(w[5]),table.concat(pc,","))
    end
  end
  local x,y=10,166
  local h=12+#lines*15
  g.setColor(0,0,0,0.80);g.rectangle("fill",x,y,900,h)
  g.setColor(0.40,1.00,1.00,1)
  for i,line in ipairs(lines) do g.print(line,x+8,y+5+(i-1)*15) end
end

local function xdRetailVariant(context,moveId)
  local battle=context and context.battle
  local user=battle and battle.player
  local id=tostring(moveId or ""):upper()

  -- These counters are directly exposed by Kanto-Reforged and correspond to
  -- XD's "same motion, increasing intensity" variant family.
  if id=="ROLLOUT" or id=="ICE_BALL" then
    return math.max(1,math.min(5,(tonumber(user and user.expRollout) or 0)+1))
  end
  if id=="FURY_CUTTER" then
    return math.max(1,math.min(5,(tonumber(user and user.expFuryCutter) or 0)+1))
  end
  if id=="STOCKPILE" or id=="SPIT_UP" or id=="SWALLOW" then
    return math.max(1,math.min(3,tonumber(user and user.expStockpile) or 1))
  end
  if id=="PURSUIT" and battle and battle.expPursuitSwitch then
    return 2
  end

  -- Magnitude, Triple Kick, Present, Return/Frustration, Low Kick,
  -- Seismic Toss, Weather Ball, Eruption and Water Spout require values that
  -- are selected/calculated later in the retail move pipeline. Until realtime
  -- owns those calculations, variant A is the correct non-invented fallback.
  return 1
end

local function mapLiveMove(context,slot)
  local battle=context and context.battle
  local inst=battle and battle.player and battle.player.curMoves and battle.player.curMoves[slot]
  if not inst then return nil,nil,nil,nil end
  local api=dxMoveApi(context)
  local xdId,canonical,vfx=nil,nil,nil
  if api and type(api.resolveMoveId)=="function" then
    local ok,a,b=pcall(api.resolveMoveId,inst.id)
    if ok then xdId,canonical=a,b end
  end
  if api and type(api.vfxForMove)=="function" then
    local ok,a,b,c=pcall(api.vfxForMove,inst.id)
    if ok then
      vfx=a
      xdId=xdId or b
      canonical=canonical or c
    end
  end
  return inst,xdId,canonical,vfx
end

function R._fx.mapAnyMoveVFX(context,moveId)
  local api=dxMoveApi(context)
  local xdId,canonical,vfx=nil,nil,nil
  if api and type(api.resolveMoveId)=="function" then
    local ok,a,b=pcall(api.resolveMoveId,moveId);if ok then xdId,canonical=a,b end
  end
  if api and type(api.vfxForMove)=="function" then
    local ok,a,b,c=pcall(api.vfxForMove,moveId)
    if ok then vfx=a;xdId=xdId or b;canonical=canonical or c end
  end
  return xdId,canonical,vfx
end

local function runtimeModule()
  local req=(V and V.engineRequire) or require
  local ok,m=pcall(req,"src.mods.Runtime")
  return ok and m or nil
end

local function emitDamage(battle,user,target,move,damage,info)
  local Runtime=runtimeModule()
  if not (Runtime and type(Runtime.emit)=="function") then return false end
  local payload={battle=battle,user=user,target=target,move=move,
    damage=damage,crit=info and info.crit or false,
    typeMult=info and info.typeMult or 10,realtime=true}
  local ok=pcall(Runtime.emit,"battle.damage_dealt",payload)
  return ok
end

function R._realtimeActorInfo(side)
  local csm=V and V.CurrentSpriteModels
  if csm and type(csm.realtimeActorState)=="function" then
    local ok,info=pcall(csm.realtimeActorState,csm,side)
    if ok and type(info)=="table" then return info end
  end
  return nil
end

function R._realtimeActor(side)
  local csm=V and V.CurrentSpriteModels
  local rec=csm and csm.stadiumActors and csm.stadiumActors[side]
  return rec and rec.actor or nil
end

function R._forceActorHit(side,payload)
  local actor=R._realtimeActor(side)
  if actor and actor.state~="faint" and actor.state~="hit" and type(actor.hit)=="function" then
    pcall(actor.hit,actor,payload or {realtime=true})
  end
end

function R._forceActorFaint(side)
  local actor=R._realtimeActor(side)
  if actor and actor.state~="faint" and type(actor.faint)=="function" then
    pcall(actor.faint,actor,"realtime-hp-zero")
  end
end

function R._beginFaintPresentation(side)
  if side~="player" and side~="enemy" then return end
  local holdKey=side.."FaintHold"
  if state[holdKey] then return end
  state[holdKey]=true
  state[side.."FaintSeen"]=false
  state[side.."FaintFallback"]=R._FAINT_HOLD_FALLBACK
  R._forceActorFaint(side)
end

local function updateFaintSide(side,dt)
  local holdKey=side.."FaintHold"
  if not state[holdKey] then return end
  local actor=R._realtimeActor(side)
  local info=R._realtimeActorInfo(side)
  if info and info.state=="faint" then state[side.."FaintSeen"]=true end
  local complete=false
  if actor and type(actor.terminalComplete)=="function" and actor.state=="faint" then
    local ok,v=pcall(actor.terminalComplete,actor)
    complete=ok and v==true
  elseif info and info.state=="faint" and tonumber(info.duration) and tonumber(info.stateAge) then
    complete=tonumber(info.stateAge)>=tonumber(info.duration)
  elseif state[side.."FaintSeen"] and not actor then
    complete=true
  end
  state[side.."FaintFallback"]=math.max(0,(tonumber(state[side.."FaintFallback"]) or 0)-dt)
  if complete or state[side.."FaintFallback"]<=0 then
    state[holdKey]=false
    state[side.."FaintSeen"]=false
    state[side.."FaintFallback"]=0
  end
end

function R:queuePresentationHold(battle)
  if battle and state.battle and battle~=state.battle then return false end
  -- Do not hold for the 3D faint animation itself; retiringActors already lets
  -- that tail finish independently. We DO pace the hidden BattleState message
  -- queue while a visible ending banner (fainted / gained EXP) is being shown,
  -- so realtime mode no longer races from KO straight to map teardown.
  for _,side in ipairs({"player","enemy"}) do
    if state[side.."ActionKind"]=="ending" and (tonumber(state[side.."ActionTimer"]) or 0)>0 then return true end
    for _,q in ipairs(state[side.."ActionQueue"] or {}) do if q.kind=="ending" then return true end end
  end
  return false
end

function R._forceActorAttack(side)
  local actor=R._realtimeActor(side)
  if not actor or actor.state=="attack" or actor.state=="hit" or actor.state=="hurt"
      or actor.state=="faint" or actor.state=="recall" then return false end
  if type(actor.attack)~="function" then return false end
  local moveId,moveDef
  if side=="player" then
    moveId=state.attackMoveId or state.selectedMoveId or 33
    moveDef=state.attackMoveDef
  else
    moveId=state.enemyAttackMoveId or 33
    moveDef=state.enemyAttackMoveDef
  end
  if type(moveDef)~="table" then moveDef={category="physical",name=tostring(moveId)} end
  local ok=pcall(actor.attack,actor,moveId,moveDef)
  return ok
end

function R._confirmImpact(context,attacker,defender,damage,source)
  damage=math.max(0,tonumber(damage) or 0)
  if damage<=0 then return false end
  if (attacker~="player" and attacker~="enemy") or (defender~="player" and defender~="enemy")
      or attacker==defender then return false end
  local b=context and context.battle
  local battler=b and b[defender]
  local hp=battler and battler.mon and tonumber(battler.mon.hp) or nil
  -- executeAction() and battle.damage_dealt can expose the SAME impact through
  -- two seams in the same frame. HP-after + damage is a stable de-duplication
  -- key; a real multi-hit strike changes HP and therefore remains distinct.
  if (tonumber(state.impactGuardTTL) or 0)>0 and state.impactGuardSide==defender
      and state.impactGuardHP==hp and state.impactGuardDamage==damage then
    return false
  end
  state.impactGuardSide=defender;state.impactGuardHP=hp;state.impactGuardDamage=damage
  state.impactGuardTTL=.24;state.impactSource=source or "confirmed"
  local av=attacker=="enemy" and state.enemyVfx or state.vfx
  if attacker=="enemy" or (av and av.family=="multi") then
    R._fx.spawnImpactForSide(attacker)
  end

  -- The impact beat is presentation-only: preserve the attacker's committed
  -- native XD move motion, force the defender's Damage/hurt reaction, then
  -- freeze BOTH locomotion controllers until those animations have played out.
  R._forceActorAttack(attacker)
  if defender=="player" then R._beginPlayerHitReaction(context,damage)
  else R._beginEnemyHitReaction(context,damage) end
  R._beginImpactLock(attacker,defender)
  return true
end

function R._beginImpactLock(attacker,defender)
  state.impactLockActive=true
  state.impactAttacker=attacker
  state.impactDefender=defender
  state.impactSeenAttacker=false
  state.impactSeenDefender=false
  state.impactMin=.12
  state.impactFallback=R._IMPACT_LOCK_FALLBACK
end

function R._updateImpactLock(dt)
  if not state.impactLockActive then return end
  state.impactMin=math.max(0,(tonumber(state.impactMin) or 0)-dt)
  state.impactFallback=math.max(0,(tonumber(state.impactFallback) or 0)-dt)
  local ai=R._realtimeActorInfo(state.impactAttacker)
  local di=R._realtimeActorInfo(state.impactDefender)
  local aBusy=ai and ai.state=="attack"
  local dBusy=di and (di.state=="hit" or di.state=="hurt")
  if aBusy then state.impactSeenAttacker=true end
  if dBusy or (di and di.state=="faint") then state.impactSeenDefender=true end
  local attackerDone=(ai~=nil) and state.impactSeenAttacker and not aBusy
  local defenderDone=(di~=nil) and state.impactSeenDefender and not dBusy
  if state.impactFallback<=0 or (state.impactMin<=0 and attackerDone and defenderDone) then
    state.impactLockActive=false
    state.impactAttacker=nil;state.impactDefender=nil
    state.impactSeenAttacker=false;state.impactSeenDefender=false
    state.impactMin=0;state.impactFallback=0
  end
end

function R._cancelPlayerAttackOnHit()
  if state.attackAge<=0 then return end
  state.attackAge=0
  state.attackHit=false
  state.attackMove=nil;state.attackMoveDef=nil;state.attackMoveId=nil;state.attackMoveSlot=nil
  state.attackKind=nil;state.attackProfileClass=nil;state.attackAOERadius=0;state.attackConeHalfAngle=0
  state.attackSelf=false;state.attackResolved=false;state.attackPpSpent=false
  state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
  state.projectileVX=0;state.projectileVZ=0
  state.vfx=nil
  state.attackResult="INTERRUPTED BY HIT"
end

function R._cancelEnemyAttackOnHit()
  if state.enemyAttackAge<=0 then return end
  state.enemyAttackAge=0
  state.enemyAttackHit=false
  state.enemyAttackMove=nil;state.enemyAttackMoveDef=nil;state.enemyAttackMoveId=nil;state.enemyAttackMoveSlot=nil
  state.enemyAttackKind=nil;state.enemyAttackProfileClass=nil;state.enemyAttackSelf=false;state.enemyAttackResolved=false;state.enemyAttackPpSpent=false
  state.enemyAttackTargetX=nil;state.enemyAttackTargetZ=nil;state.enemyAttackAOERadius=0;state.enemyAttackConeHalfAngle=0
  state.enemyProjectileX=nil;state.enemyProjectileZ=nil;state.enemyProjectilePrevX=nil;state.enemyProjectilePrevZ=nil
  state.enemyProjectileVX=0;state.enemyProjectileVZ=0
  state.enemyLastResult="INTERRUPTED BY HIT"
  state.enemyVfx=nil
end

function R._beginPlayerHitReaction(context,damage)
  local battle=context and context.battle
  local hp=battle and battle.player and battle.player.mon and tonumber(battle.player.mon.hp) or 0
  R._cancelPlayerAttackOnHit()
  if (tonumber(damage) or 0)<=0 then return end
  state.playerFainted=hp<=0
  state.playerPendingFaintAfterHit=hp<=0
  state.playerHitAnimating=true
  state.playerHitActorSeen=false
  state.playerHitFallback=R._PLAYER_HIT_FALLBACK
  state.playerInvuln=0
  R._forceActorHit("player",{damage=damage,realtime=true,target=battle and battle.player})
end

function R._beginEnemyHitReaction(context,damage)
  local battle=context and context.battle
  local hp=battle and battle.enemy and battle.enemy.mon and tonumber(battle.enemy.mon.hp) or 0
  R._cancelEnemyAttackOnHit()
  if (tonumber(damage) or 0)<=0 then return end
  state.enemyFainted=hp<=0
  state.enemyPendingFaintAfterHit=hp<=0
  state.enemyHitAnimating=true
  state.enemyHitActorSeen=false
  state.enemyHitFallback=R._ENEMY_HIT_FALLBACK
  state.enemyInvuln=0
  R._forceActorHit("enemy",{damage=damage,realtime=true,target=battle and battle.enemy})
end

local function updateHitRecoverySide(side,context,dt)
  local battle=context and context.battle
  local battler=battle and battle[side]
  local hp=battler and battler.mon and tonumber(battler.mon.hp) or 0
  local cap=side=="player" and "player" or "enemy"
  local animKey=cap.."HitAnimating"
  local seenKey=cap.."HitActorSeen"
  local fallbackKey=cap.."HitFallback"
  local invulKey=cap.."Invuln"
  local faintedKey=cap.."Fainted"
  local pendingFaintKey=cap.."PendingFaintAfterHit"
  local invulDur=side=="player" and R._PLAYER_POST_HIT_INVULN or R._ENEMY_POST_HIT_INVULN
  local hitFallback=side=="player" and R._PLAYER_HIT_FALLBACK or R._ENEMY_HIT_FALLBACK

  if hp<=0 then
    state[faintedKey]=true
  else
    state[faintedKey]=false
    state[pendingFaintKey]=false
  end

  local info=R._realtimeActorInfo(side)
  local actorHit=info and (info.state=="hit" or info.state=="hurt")
  local actorFaint=info and info.state=="faint"
  local startedInvuln=false

  if state[animKey] then
    if actorHit then state[seenKey]=true end
    local hitFinished=false
    if state[seenKey] then
      if info and not actorHit then hitFinished=true end
    else
      state[fallbackKey]=math.max(0,(tonumber(state[fallbackKey]) or 0)-dt)
      if state[fallbackKey]<=0 then hitFinished=true end
    end

    -- An authoritative faint event may arrive while the Damage clip is still
    -- running. DXBattleActors queues that faint behind hit; if another provider
    -- has already switched to faint, treat that as the hit boundary completing.
    if actorFaint and state[pendingFaintKey] then hitFinished=true end

    if hitFinished then
      state[animKey]=false
      state[seenKey]=false
      state[fallbackKey]=0
      if state[pendingFaintKey] or hp<=0 then
        state[pendingFaintKey]=false
        state[invulKey]=0
        R._beginFaintPresentation(side)
        return
      end
      state[invulKey]=invulDur
      startedInvuln=true
    end
  elseif actorHit then
    state[animKey]=true
    state[seenKey]=true
    state[fallbackKey]=hitFallback
    state[invulKey]=0
  elseif hp<=0 then
    state[pendingFaintKey]=false
    state[invulKey]=0
    R._beginFaintPresentation(side)
    return
  end

  if not startedInvuln and state[invulKey]>0 then
    state[invulKey]=math.max(0,state[invulKey]-dt)
  end
end

function R._updatePlayerHitRecovery(context,dt) updateHitRecoverySide("player",context,dt) end
function R._updateEnemyHitRecovery(context,dt) updateHitRecoverySide("enemy",context,dt) end

function R._playerAttackSuppressed()
  return state.nativeModalActive==true or state.playerHitAnimating==true or (tonumber(state.playerInvuln) or 0)>0
    or (tonumber(state.playerSwitchGuard) or 0)>0 or (tonumber(state.rollTimer) or 0)>0
    or (tonumber(state.airDashTimer) or 0)>0 or state.playerFainted==true
    or state.playerStatus=="SLP" or state.playerStatus=="FRZ"
end

function R._playerDamageBlocked()
  return state.playerHitAnimating==true or (tonumber(state.playerInvuln) or 0)>0
    or (tonumber(state.playerSwitchGuard) or 0)>0 or (tonumber(state.rollIFrame) or 0)>0
    or (tonumber(state.airDashIFrame) or 0)>0 or state.playerFainted==true
end

function R._enemyAttackSuppressed()
  return state.enemyHitAnimating==true or (tonumber(state.enemyInvuln) or 0)>0
    or (tonumber(state.enemySwitchGuard) or 0)>0 or state.enemyFainted==true
    or state.enemyStatus=="SLP" or state.enemyStatus=="FRZ"
end

function R._enemyDamageBlocked()
  return state.enemyHitAnimating==true or (tonumber(state.enemyInvuln) or 0)>0
    or (tonumber(state.enemySwitchGuard) or 0)>0 or state.enemyFainted==true
end

local function startTackle(context)
  if R._playerAttackSuppressed() or state.impactLockActive then state.attackResult="RECOVERY - ATTACK BLOCKED";return false end
  if state.attackAge>0 or state.attackMotionLock then return false end
  local tackleSlot=tonumber(state.selectedMoveSlot) or 1
  if R._slotCooldown("player",tackleSlot)>0 or (tonumber(state.playerGlobalAttackLock) or 0)>0 then return false end
  local battle,reason=gen1Battle(context)
  if not battle then state.attackResult=reason or "NO BATTLE";return false end
  if battle.phase~="menu" then
    state.attackResult="BUSY: "..tostring(battle.phase or "?")
    return false
  end
  local user,target=battle.player,battle.enemy
  if not (user and user.mon and target and target.mon) then
    state.attackResult="BATTLER MISSING";return false
  end
  if (tonumber(user.mon.hp) or 0)<=0 or (tonumber(target.mon.hp) or 0)<=0 then
    state.attackResult="FAINTED";return false
  end

  local move,slot,def=findTackle(battle)
  if not move then state.attackResult="NO TACKLE";return false end
  if battle.player.disabledSlot==slot then state.attackResult="TACKLE DISABLED";return false end
  if (tonumber(move.pp) or 0)<=0 then state.attackResult="NO PP";return false end
  if type(def)~="table" then state.attackResult="TACKLE DATA MISSING";return false end

  -- PP is spent when the attack is committed, even if the realtime contact
  -- volume later misses. curMoves aliases the live party mon's moves in Gen1.
  move.pp=math.max(0,(tonumber(move.pp) or 0)-1)
  battle.playerMoveListIndex=slot
  state.attackMove=move
  local motionDef={}
  if type(def)=="table" then for k,v in pairs(def) do motionDef[k]=v end end
  motionDef.id=motionDef.id or move.id
  motionDef.type=motionDef.type or "NORMAL"
  motionDef._xdVariant=1
  state.attackMoveDef=motionDef
  state.attackMoveId=move.id
  state.attackMoveSlot=slot
  state.attackPP=move.pp
  state.attackKind="contact"
  state.attackRange=4.5
  local aimX,aimZ,onTarget,assistActive,assistAmount=cameraAimDirection(state.attackRange or 4.5,"contact",motionDef)
  state.attackAssistActive=onTarget or assistActive
  state.attackAssistAmount=onTarget and 1 or (assistAmount or 0)
  state.attackDirX,state.attackDirZ=aimX,aimZ
  state.facingX,state.facingZ=aimX,aimZ
  state.attackFacingLock=true;state.attackFacingActorSeen=false;state.attackFacingTimer=1.35
  state.attackFacingX,state.attackFacingZ=aimX,aimZ
  state.attackTargetX,state.attackTargetZ=state.px+aimX*state.attackRange,state.pz+aimZ*state.attackRange
  state.attackTargetDistance=len2(state.ex-state.px,state.ez-state.pz)
  state.projectileRadius=1.1
  state.attackDuration=.58
  state.attackActiveStart=.14
  state.attackActiveEnd=.36
  state.attackSerial=state.attackSerial+1
  state.attackAge=0.0001
  state.attackHit=false
  state.attackCooldownDuration=moveCooldownSeconds(move.id,motionDef)
  state.attackCooldown=state.attackCooldownDuration
  R._setSlotCooldown("player",slot,state.attackCooldownDuration)
  state.attackAccuracyScale=R._accuracyShapeScale(battle.player)
  state.attackMotionLock=false
  state.attackActorSeen=false
  state.lastDamage=0
  state.lastCrit=false
  state.lastTypeMult=10
  state.lastHpBefore=tonumber(target.mon.hp)
  state.lastHpAfter=state.lastHpBefore
  state.combatError=nil
  beginSimplifiedVFX(move.id,motionDef,"contact",nil,nil,move.id)
  state.attackResult="ACTIVE"
  R._announcePlayerMove(context,move.id,motionDef)
  return true
end


local function startRealtimeMove(context,slot,inst,xdId,canonical,xdVFX)
  if R._playerAttackSuppressed() or state.impactLockActive then state.attackResult="RECOVERY - ATTACK BLOCKED";return false end
  local slotCooldown=R._slotCooldown("player",slot)
  if slotCooldown>0 then state.attackResult=string.format("MOVE %d COOLDOWN %.1fs",slot,slotCooldown);return false end
  if (tonumber(state.playerGlobalAttackLock) or 0)>0 then state.attackResult=string.format("GLOBAL RECOVERY %.1fs",state.playerGlobalAttackLock);return false end
  if state.attackAge>0 or state.attackMotionLock then return false end
  local battle,reason=gen1Battle(context)
  if not battle then state.attackResult=reason or "NO BATTLE";return false end
  if battle.phase~="menu" then state.attackResult="BUSY: "..tostring(battle.phase or "?");return false end
  local user,target=battle.player,battle.enemy
  if not (inst and user and user.mon and target and target.mon) then
    state.attackResult="BATTLER/MOVE MISSING";return false
  end
  if (tonumber(user.mon.hp) or 0)<=0 or (tonumber(target.mon.hp) or 0)<=0 then
    state.attackResult="FAINTED";return false
  end
  if battle.player.disabledSlot==slot then state.attackResult="MOVE DISABLED";return false end
  if (tonumber(inst.pp) or 0)<=0 then state.attackResult="NO PP";return false end

  local def=battle.data and battle.data.moves and (battle.data.moves[inst.id] or battle.data.moves[xdId])
  if type(def)~="table" then state.attackResult="MOVE DATA MISSING";return false end

  local kind,range,radius,profile=classifyRealtimeMove(inst.id,def)

  -- PP is now owned by the authoritative action pipeline on a confirmed
  -- realtime hit. A manual spatial miss spends one PP explicitly at attack end.
  battle.playerMoveListIndex=slot

  local motionDef={}
  for k,v in pairs(def) do motionDef[k]=v end
  motionDef.id=motionDef.id or inst.id
  motionDef._xdVariant=xdRetailVariant(context,inst.id)

  state.attackMove=inst
  state.attackMoveDef=motionDef
  state.attackMoveId=inst.id
  state.attackMoveSlot=slot
  state.attackPP=inst.pp
  state.attackKind=kind
  state.attackProfileClass=profile and tostring(profile.class or ""):upper() or nil
  state.attackSelf=(kind=="self")
  state.attackAOERadius=0;state.attackConeHalfAngle=0
  state.attackResolved=false
  state.attackPpSpent=false
  state.attackRange=range or 0
  state.projectileRadius=0
  state.attackSerial=state.attackSerial+1
  state.attackAge=.0001
  state.attackHit=false
  state.attackCooldownDuration=moveCooldownSeconds(inst.id,motionDef)
  state.attackCooldown=state.attackCooldownDuration
  R._setSlotCooldown("player",slot,state.attackCooldownDuration)
  state.attackAccuracyScale=R._accuracyShapeScale(user)
  state.attackMotionLock=false
  state.attackActorSeen=false
  state.lastDamage=0
  state.lastCrit=false
  state.lastTypeMult=10
  state.lastHpBefore=tonumber(target.mon.hp)
  state.lastHpAfter=state.lastHpBefore
  state.combatError=nil

  -- v0.5.6 CAMERA AIM: snapshot the third-person camera's horizontal forward
  -- direction on attack commit. WASD no longer decides shot direction. The
  -- Pokemon is turned to the snapshotted aim only for visual alignment with
  -- its native XD attack animation. Already-fired shots keep this direction.
  local aimX,aimZ,onTarget,assistActive,assistAmount
  local authoredRange=tonumber(range) or 0
  if kind=="ground-aoe" then
    local tx,tz,td
    if state.targetPreviewActive and (state.targetPreviewClass=="GROUND_AOE" or state.targetPreviewClass=="TRAP_ZONE") then
      tx,tz,td=state.targetPreviewX,state.targetPreviewZ,len2((state.targetPreviewX or state.px)-state.px,(state.targetPreviewZ or state.pz)-state.pz)
    else
      tx,tz,td=R._cameraGroundTargetPoint(authoredRange)
    end
    aimX,aimZ=normalize2((tx or state.px)-state.px,(tz or state.pz)-state.pz)
    if aimX==0 and aimZ==0 then aimX,aimZ=normalize2(math.sin(state.yaw or 0),math.cos(state.yaw or 0)) end
    if aimX==0 and aimZ==0 then aimX,aimZ=0,-1 end
    state.attackTargetX,state.attackTargetZ=tx,tz
    state.attackTargetDistance=td or 0
    state.attackAOERadius=math.max(.35,(tonumber(radius) or 4)*(tonumber(state.attackAccuracyScale) or 1))
    local dx,dz=(state.ex or 0)-(tx or 0),(state.ez or 0)-(tz or 0)
    onTarget=(dx*dx+dz*dz)<=((state.attackAOERadius+R._playerTargetRadius())^2)
    assistActive=false;assistAmount=0
  else
    aimX,aimZ,onTarget,assistActive,assistAmount=cameraAimDirection(authoredRange>0 and authoredRange or 18,kind,motionDef)
  end
  state.attackAssistActive=onTarget or assistActive
  state.attackAssistAmount=onTarget and 1 or (assistAmount or 0)
  state.attackDirX,state.attackDirZ=aimX,aimZ
  state.facingX,state.facingZ=aimX,aimZ
  state.attackFacingLock=true;state.attackFacingActorSeen=false;state.attackFacingTimer=1.35
  state.attackFacingX,state.attackFacingZ=aimX,aimZ

  if kind=="projectile" and authoredRange<=0 then authoredRange=18 end
  if kind=="stream" and authoredRange<=0 then authoredRange=16 end
  if kind=="target-line" and authoredRange<=0 then authoredRange=18 end
  if kind=="cone" and authoredRange<=0 then authoredRange=10 end
  if kind~="ground-aoe" then
    state.attackTargetX=state.px+aimX*authoredRange
    state.attackTargetZ=state.pz+aimZ*authoredRange
    state.attackTargetDistance=authoredRange
  end
  state.attackRange=authoredRange
  if kind=="cone" then
    state.attackConeHalfAngle=math.rad(clamp((tonumber(radius) or tonumber(profile and profile.angle) or 45)*(tonumber(state.attackAccuracyScale) or 1),8,90))*.5
    state.projectileRadius=0
  elseif kind=="ground-aoe" then
    state.projectileRadius=0
  else
    state.projectileRadius=math.max(.18,(tonumber(radius) or 0)*(tonumber(state.attackAccuracyScale) or 1))
  end

  state.projectileHomingTimer=0;state.projectileHomingScale=1
  if kind=="projectile" then
    state.projectileX=state.px+aimX*(state.playerRadius+.5)
    state.projectileZ=state.pz+aimZ*(state.playerRadius+.5)
    state.projectilePrevX,state.projectilePrevZ=state.projectileX,state.projectileZ
    local projectileDistance=math.max(1,authoredRange)
    state.attackTargetDistance=projectileDistance
    local flight=clamp(projectileDistance/42,.34,.72)
    local speed=projectileDistance/math.max(.12,flight)
    state.projectileVX=aimX*speed
    state.projectileVZ=aimZ*speed
    state.projectileHomingTimer=R._PROJECTILE_HOMING_TIME
    local power=tonumber(motionDef and (motionDef.power or motionDef.basePower or motionDef.damage)) or 0
    state.projectileHomingScale=power>=100 and .55 or (power>=80 and .75 or 1.0)
    state.attackDuration=flight+.18
    state.attackActiveStart=.04
    state.attackActiveEnd=flight+.04
  elseif kind=="stream" then
    state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
    state.attackDuration=.82
    state.attackActiveStart=.16
    state.attackActiveEnd=.70
  elseif kind=="target-line" then
    state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
    state.attackDuration=.72
    state.attackActiveStart=.16
    state.attackActiveEnd=.54
  elseif kind=="cone" then
    state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
    state.attackDuration=.82
    state.attackActiveStart=.22
    state.attackActiveEnd=.64
  elseif kind=="ground-aoe" then
    state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
    state.attackDuration=.96
    state.attackActiveStart=.50
    state.attackActiveEnd=.64
  elseif kind=="radial" then
    state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
    state.attackDuration=.74
    state.attackActiveStart=.18
    state.attackActiveEnd=.58
  elseif kind=="self" then
    state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
    state.attackDuration=.62
    state.attackActiveStart=.18
    state.attackActiveEnd=.30
  else
    state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
    state.attackDuration=.58
    state.attackActiveStart=.14
    state.attackActiveEnd=.36
  end

  beginSimplifiedVFX(inst.id,motionDef,kind,xdVFX,xdId,canonical)
  if xdVFX then
    local okProbe=pcall(probeGPT1V2,context,xdVFX,xdId,canonical)
    if okProbe and state.vfx then state.vfx.xdProbe=state.v2Probe end
  end
  state.attackResult="ACTIVE "..kind:upper().." "..tostring(canonical or inst.id)
  R._announcePlayerMove(context,inst.id,motionDef)
  if state.flightCapable and ((tonumber(state.py) or 0)>0.05 or state.flightMode) then
    state.flightStamina=math.max(0,(tonumber(state.flightStamina) or 0)-FLIGHT_ATTACK_COST)
    if state.flightStamina<=0 then state.flightExhausted=true end
  end
  return true
end

local function resolveRealtimeDamageFallback(context)
  local battle,reason=gen1Battle(context)
  if not battle then state.combatError=reason;return false end
  local user,target=battle.player,battle.enemy
  local moveInst=state.attackMove
  local moveDef=state.attackMoveDef
  if type(moveDef)~="table" and moveInst and battle.data and battle.data.moves then
    moveDef=battle.data.moves[moveInst.id]
  end
  if not (user and target and target.mon and type(moveDef)=="table") then
    state.combatError="MOVE RESOLVE DATA MISSING";return false
  end
  if not damagingMove(moveDef) then
    state.combatError="STATUS MOVE EFFECTS NOT WIRED"
    return false
  end
  if type(battle.computeDamage)~="function" or type(battle.applyDamage)~="function" then
    state.combatError="GEN1 DAMAGE API MISSING";return false
  end

  local hpBefore=tonumber(target.mon.hp) or 0
  local okDamage,dmg,info=pcall(battle.computeDamage,battle,user,target,moveDef,{rng=battle.rng})
  if not okDamage then
    state.combatError="DAMAGE ERROR: "..tostring(dmg)
    return false
  end
  dmg=math.max(0,math.floor(tonumber(dmg) or 0))
  info=type(info)=="table" and info or {crit=false,typeMult=10}

  battle.phase="messages"
  battle.afterQueue="menu"
  battle.__xdRealtimeResolution=true
  local okApply,dealt=pcall(battle.applyDamage,battle,target,dmg)
  if not okApply then
    battle.__xdRealtimeResolution=nil
    battle.phase="menu"
    state.combatError="APPLY ERROR: "..tostring(dealt)
    return false
  end
  dealt=math.max(0,math.floor(tonumber(dealt) or 0))

  state.lastDamage=dealt
  state.lastCrit=info.crit==true
  state.lastTypeMult=tonumber(info.typeMult) or 10
  state.lastHpBefore=hpBefore
  state.lastHpAfter=tonumber(target.mon.hp) or 0
  state.attackResult=(dealt>0 and ("HIT -"..tostring(dealt)) or "IMMUNE")
    ..(state.lastCrit and " CRIT" or "")

  emitDamage(battle,user,target,moveDef,dealt,info)
  if dealt>0 then R._confirmImpact(context,"player","enemy",dealt,"fallback-applyDamage") end
  if (tonumber(target.mon.hp) or 0)<=0 then
    if type(battle.onFaint)=="function" then pcall(battle.onFaint,battle,target) end
    state.attackResult=state.attackResult.." KO"
  end
  return true
end


-- Realtime attacks call the authoritative Gen1 action functions directly instead
-- of entering through resolveTurn().  The native action functions can enqueue
-- faint/EXP/status/replacement work, but BattleState only drains that queue while
-- phase == "messages".  Put direct realtime resolutions into that native queue
-- phase first so every queued consequence actually runs.
function R._beginRealtimeAuthoritativeQueue(battle)
  if type(battle)~="table" then return false end
  if battle.phase=="menu" or battle.phase=="moveSelect" then
    battle.phase="messages"
  end
  -- Ordinary realtime actions should return to the command phase once all
  -- queued consequences finish.  Never overwrite an already-authoritative
  -- battle finish/result state; faint/victory processing may set finish later.
  if battle.afterQueue~="finish" and not battle.result then
    battle.afterQueue="menu"
  end
  battle.__xdRealtimeResolution=true
  return true
end


function R._fx.addPersistentMovePresentation(side,moveId)
  local n=moveName(moveId)
  local family=R._fx.presentationFamily(n,nil,nil)
  local targetSide=side
  local duration=0
  if R._PRESENT_TRAP[n] then
    targetSide=(n=="INGRAIN") and side or (side=="enemy" and "player" or "enemy")
    duration=(n=="LEECH_SEED") and 8.5 or 5.5
  elseif R._PRESENT_BARRIER[n] or n=="SUBSTITUTE" then
    targetSide=side;duration=(n=="SUBSTITUTE") and 7.0 or 5.0
  else return end
  state.persistentMoveVfx=state.persistentMoveVfx or {}
  -- Refresh matching presentation instead of stacking duplicate shields/seeds.
  for _,p in ipairs(state.persistentMoveVfx) do
    if p.side==side and p.targetSide==targetSide and p.name==n then p.age=0;p.duration=duration;return end
  end
  local def=side=="enemy" and state.enemyAttackMoveDef or state.attackMoveDef
  state.persistentMoveVfx[#state.persistentMoveVfx+1]={
    side=side,targetSide=targetSide,name=n,family=family,age=0,duration=duration,
    color=copyColor(TYPE_COLORS[moveType(def)] or TYPE_COLORS.NORMAL),
  }
end

function R._fx.commitResolvedPresentation(side,moveId)
  R._fx.addPersistentMovePresentation(side,moveId)
end

local function resolveRealtimeMove(context)
  local battle,reason=gen1Battle(context)
  if not battle then state.combatError=reason;return false end
  local user=battle.player
  local target=state.attackSelf and user or battle.enemy
  local inst=state.attackMove
  if not (user and target and inst) then state.combatError="MOVE RESOLVE DATA MISSING";return false end
  local hpBefore=target.mon and tonumber(target.mon.hp) or 0

  -- Prefer the complete Gen1/Kanto action pipeline after realtime spatial
  -- confirmation. executeAction adds the ordinary status gauntlet (sleep,
  -- freeze, flinch, disable/confusion/paralysis), locked-action bookkeeping,
  -- move execution and post-action residual handling. The spatial layer still
  -- decides only whether an opponent-facing move reached the foe.
  if type(battle.executeAction)=="function" then
    R._beginRealtimeAuthoritativeQueue(battle)
    local beforePP=tonumber(inst.pp) or 0
    local ok,err=pcall(battle.executeAction,battle,user,target,inst)
    if not ok then
      battle.__xdRealtimeResolution=nil
      state.combatError="EXECUTE ACTION ERROR: "..tostring(err)
      return false
    end
    state.attackPP=tonumber(inst.pp) or beforePP
    state.attackPpSpent=(state.attackPP<beforePP) or inst.struggle==true
    state.attackResolved=true
    state.attackResult=state.attackSelf and "SELF/FIELD RESOLVED" or "MANUAL HIT RESOLVED"
    if not state.attackSelf and target.mon then
      local hpAfter=tonumber(target.mon.hp) or hpBefore
      local dealt=math.max(0,hpBefore-hpAfter)
      if dealt>0 then R._confirmImpact(context,"player","enemy",dealt,"executeAction-hp") end
    end
    R._fx.commitResolvedPresentation("player",inst.id)
    return true
  end

  -- Older compatible hosts may expose performMove without executeAction. It
  -- still preserves the authoritative move/effect registry, PP and damage.
  if type(battle.performMove)=="function" then
    R._beginRealtimeAuthoritativeQueue(battle)
    local beforePP=tonumber(inst.pp) or 0
    local ok,err=pcall(battle.performMove,battle,user,target,inst,false)
    if not ok then
      battle.__xdRealtimeResolution=nil
      state.combatError="PERFORM MOVE ERROR: "..tostring(err)
      return false
    end
    state.attackPP=tonumber(inst.pp) or beforePP
    state.attackPpSpent=(state.attackPP<beforePP) or inst.struggle==true
    state.attackResolved=true
    state.attackResult=state.attackSelf and "SELF/FIELD RESOLVED" or "MANUAL HIT RESOLVED"
    if not state.attackSelf and target.mon then
      local hpAfter=tonumber(target.mon.hp) or hpBefore
      local dealt=math.max(0,hpBefore-hpAfter)
      if dealt>0 then R._confirmImpact(context,"player","enemy",dealt,"performMove-hp") end
    end
    R._fx.commitResolvedPresentation("player",inst.id)
    return true
  end

  -- Compatibility fallback for an older host without either action API. Damaging
  -- moves retain the proven computeDamage/applyDamage bridge; status moves
  -- report the missing authoritative API rather than inventing their effects.
  if damagingMove(state.attackMoveDef) then return resolveRealtimeDamageFallback(context) end
  state.combatError="AUTHORITATIVE MOVE ACTION API MISSING"
  return false
end

local function spendManualMissPP(context)
  if state.attackPpSpent then return end
  local battle=gen1Battle(context)
  local inst=state.attackMove
  if not (battle and inst) then return end
  if not inst.struggle then inst.pp=math.max(0,(tonumber(inst.pp) or 0)-1) end
  state.attackPP=tonumber(inst.pp) or 0
  state.attackPpSpent=true

  -- Give move-effect records their ordinary miss cleanup (Rollout/Fury Cutter,
  -- traps, etc.) without allowing the engine to apply the move to a missed foe.
  local def=state.attackMoveDef
  local rec=def and battle.data and battle.data.move_effects and battle.data.move_effects[def.effect]
  if rec and type(rec.onMiss)=="function" then
    pcall(rec.onMiss,{battle=battle,user=battle.player,target=battle.enemy,move=def,moveInst=inst,rng=battle.rng,data=battle.data})
  end
end


-- Universal realtime enemy combat brain ------------------------------------
-- All species use the same movement/aim/reaction rules. Flying typing does
-- not grant special AI altitude camping; the opponent remains on the authored
-- battle floor and wins through spacing, strafing, prediction and move choice.
local function enemyAttackActive()
  return state.enemyAttackAge>=state.enemyAttackActiveStart
    and state.enemyAttackAge<=state.enemyAttackActiveEnd
end

local function enemyContactHitsPlayer()
  local fx,fz=normalize2(state.enemyAttackDirX,state.enemyAttackDirZ)
  if fx==0 and fz==0 then fx,fz=0,1 end
  local rx,rz=-fz,fx
  local forwardOffset=state.enemyRadius+math.max(.85,state.enemyRadius*.55)
  local box={
    cx=state.ex+fx*forwardOffset,cz=state.ez+fz*forwardOffset,
    fx=fx,fz=fz,rx=rx,rz=rz,
    halfW=math.max(.42,math.max(1.10,state.enemyRadius*.90)*(tonumber(state.enemyAttackAccuracyScale) or 1)),
    halfD=math.max(.38,math.max(1.00,state.enemyRadius*.72)*(tonumber(state.enemyAttackAccuracyScale) or 1)),
  }
  return circleHitsOBB(state.px,state.pz,R._enemyTargetRadius(),box)
end

local function enemyLineHitsPlayer(range,radius)
  local fx,fz=normalize2(state.enemyAttackDirX,state.enemyAttackDirZ)
  if fx==0 and fz==0 then fx,fz=0,1 end
  local ax,az=state.ex+fx*state.enemyRadius,state.ez+fz*state.enemyRadius
  local bx,bz=ax+fx*(range or 0),az+fz*(range or 0)
  local rr=(radius or 1.4)+R._enemyTargetRadius()
  return pointSegmentDistance2(state.px,state.pz,ax,az,bx,bz)<=rr*rr
end

local function enemyMoveDef(battle,inst)
  if not (battle and inst and battle.data and battle.data.moves) then return nil end
  return battle.data.moves[inst.id] or battle.data.moves[tonumber(inst.id)]
end

local function enemyMoveUsable(battle,slot,inst)
  if not inst or (tonumber(inst.pp) or 0)<=0 then return false end
  if R._slotCooldown("enemy",slot)>0 then return false end
  if battle and battle.enemy and battle.enemy.disabledSlot==slot then return false end
  return enemyMoveDef(battle,inst)~=nil
end

local function chooseEnemyMove(context,dist)
  local battle=gen1Battle(context)
  local enemy=battle and battle.enemy
  local moves=enemy and enemy.curMoves or nil
  if type(moves)~="table" then return nil end
  local best,bestScore=nil,-1e9
  local hp=(enemy.mon and tonumber(enemy.mon.hp)) or 1
  local maxhp=(enemy.mon and enemy.mon.stats and tonumber(enemy.mon.stats.hp)) or math.max(1,hp)
  local hpRatio=maxhp>0 and hp/maxhp or 1
  for slot,inst in ipairs(moves) do
    if enemyMoveUsable(battle,slot,inst) then
      local def=enemyMoveDef(battle,inst)
      local kind,range,radius,profile=classifyRealtimeMove(inst.id,def)
      local score=0
      if kind=="self" then
        score=(hpRatio<.48) and 6.2 or .25
      elseif kind=="contact" then
        score=dist<=(range+state.playerRadius+state.enemyRadius*.35) and 7.5 or (2.0-math.max(0,dist-range)*.45)
      elseif kind=="radial" then
        score=dist<=(range+state.playerRadius) and 6.8 or 1.0
      else
        if dist<=range+state.playerRadius then
          score=6.0+clamp((range-dist)/math.max(1,range),-.5,.8)
        else
          score=1.5-math.max(0,dist-range)*.25
        end
      end
      if damagingMove(def) then score=score+1.1 end
      -- deterministic tie-break rotation prevents one move from monopolizing
      -- every decision without introducing a species-specific preference.
      local rotate=((slot+(state.enemyAIMoveCursor or 0))%4)*.015
      score=score+rotate
      if score>bestScore then
        bestScore=score
        best={slot=slot,inst=inst,def=def,kind=kind,range=range,radius=radius,profile=profile}
      end
    end
  end
  return best
end

local function enemyMoveInRange(choice,dist)
  if not choice then return false end
  local kind=choice.kind
  local range=tonumber(choice.range) or 0
  if kind=="self" then return true end
  if kind=="contact" then return dist<=range+state.playerRadius+state.enemyRadius*.35 end
  if kind=="radial" then return dist<=range+state.playerRadius end
  return dist<=range+state.playerRadius
end

local function resolveEnemyMove(context)
  local battle,reason=gen1Battle(context)
  if not battle then state.enemyLastResult=reason or "NO BATTLE";return false end
  local user=battle.enemy
  local target=state.enemyAttackSelf and user or battle.player
  local inst=state.enemyAttackMove
  if not (user and target and inst) then state.enemyLastResult="AI RESOLVE DATA MISSING";return false end
  local hpBefore=target.mon and tonumber(target.mon.hp) or 0
  if type(battle.executeAction)=="function" then
    R._beginRealtimeAuthoritativeQueue(battle)
    local before=tonumber(inst.pp) or 0
    local ok,err=pcall(battle.executeAction,battle,user,target,inst)
    if not ok then
      battle.__xdRealtimeResolution=nil
      state.enemyLastResult="AI EXECUTE ERROR: "..tostring(err)
      return false
    end
    state.enemyAttackPpSpent=((tonumber(inst.pp) or before)<before) or inst.struggle==true
    state.enemyAttackResolved=true
    state.enemyLastResult=state.enemyAttackSelf and "AI SELF RESOLVED" or "AI HIT RESOLVED"
    local hpAfter=target.mon and tonumber(target.mon.hp) or hpBefore
    if not state.enemyAttackSelf and hpAfter<hpBefore then
      R._confirmImpact(context,"enemy","player",hpBefore-hpAfter,"enemy-executeAction-hp")
    end
    R._fx.commitResolvedPresentation("enemy",inst.id)
    return true
  end
  if type(battle.performMove)=="function" then
    R._beginRealtimeAuthoritativeQueue(battle)
    local before=tonumber(inst.pp) or 0
    local ok,err=pcall(battle.performMove,battle,user,target,inst,false)
    if not ok then
      battle.__xdRealtimeResolution=nil
      state.enemyLastResult="AI MOVE ERROR: "..tostring(err)
      return false
    end
    state.enemyAttackPpSpent=((tonumber(inst.pp) or before)<before) or inst.struggle==true
    state.enemyAttackResolved=true
    state.enemyLastResult=state.enemyAttackSelf and "AI SELF RESOLVED" or "AI HIT RESOLVED"
    local hpAfter=target.mon and tonumber(target.mon.hp) or hpBefore
    if not state.enemyAttackSelf and hpAfter<hpBefore then
      R._confirmImpact(context,"enemy","player",hpBefore-hpAfter,"enemy-performMove-hp")
    end
    R._fx.commitResolvedPresentation("enemy",inst.id)
    return true
  end
  state.enemyLastResult="AI ACTION API MISSING"
  return false
end

local function spendEnemyMissPP(context)
  if state.enemyAttackPpSpent then return end
  local battle=gen1Battle(context)
  local inst=state.enemyAttackMove
  if not (battle and inst) then return end
  if not inst.struggle then inst.pp=math.max(0,(tonumber(inst.pp) or 0)-1) end
  state.enemyAttackPpSpent=true
  local def=state.enemyAttackMoveDef
  local rec=def and battle.data and battle.data.move_effects and battle.data.move_effects[def.effect]
  if rec and type(rec.onMiss)=="function" then
    pcall(rec.onMiss,{battle=battle,user=battle.enemy,target=battle.player,move=def,moveInst=inst,rng=battle.rng,data=battle.data})
  end
end

local function startEnemyMove(context,choice)
  if R._enemyAttackSuppressed() or state.impactLockActive then return false end
  if not choice or state.enemyAttackAge>0 then return false end
  if (tonumber(state.enemyGlobalAttackLock) or 0)>0 or R._slotCooldown("enemy",choice.slot)>0 then return false end
  local battle=gen1Battle(context)
  if not battle or battle.phase~="menu" then return false end
  local user,target=battle.enemy,battle.player
  if not (user and user.mon and target and target.mon) then return false end
  if (tonumber(user.mon.hp) or 0)<=0 or (tonumber(target.mon.hp) or 0)<=0 then return false end
  if not enemyMoveUsable(battle,choice.slot,choice.inst) then return false end

  local kind,range,radius=choice.kind,tonumber(choice.range) or 0,tonumber(choice.radius) or 0
  local predict=.22
  if kind=="projectile" then predict=clamp(len2(state.px-state.ex,state.pz-state.ez)/42,.18,.48)
  elseif kind=="stream" or kind=="target-line" then predict=.16 end
  local tx=(state.px or 0)+(state.playerVelX or 0)*predict
  local tz=(state.pz or 0)+(state.playerVelZ or 0)*predict
  local ax,az=normalize2(tx-state.ex,tz-state.ez)
  if ax==0 and az==0 then ax,az=normalize2(state.px-state.ex,state.pz-state.ez) end
  if ax==0 and az==0 then ax,az=0,1 end

  -- Small deterministic aim wobble keeps the AI good without becoming an aimbot.
  local accScale=R._accuracyShapeScale(user)
  local err=math.sin((state.enemyAttackSerial+1)*2.173)*math.rad(2.8/clamp(accScale,.45,1.65))
  local ce,se=math.cos(err),math.sin(err)
  ax,az=ax*ce-az*se,ax*se+az*ce

  local motionDef={}
  for k,v in pairs(choice.def or {}) do motionDef[k]=v end
  motionDef.id=motionDef.id or choice.inst.id
  motionDef._xdVariant=1
  battle.enemyMoveListIndex=choice.slot
  state.enemyAttackSerial=state.enemyAttackSerial+1
  state.enemyAttackAge=.0001
  state.enemyAttackCooldownDuration=moveCooldownSeconds(choice.inst.id,motionDef)
  state.enemyAttackCooldown=state.enemyAttackCooldownDuration
  R._setSlotCooldown("enemy",choice.slot,state.enemyAttackCooldownDuration)
  state.enemyAttackAccuracyScale=accScale
  state.enemyAttackHit=false
  state.enemyAttackResolved=false
  state.enemyAttackPpSpent=false
  state.enemyAttackMove=choice.inst
  state.enemyAttackMoveDef=motionDef
  state.enemyAttackMoveId=choice.inst.id
  state.enemyAttackMoveSlot=choice.slot
  state.enemyAttackKind=kind
  state.enemyAttackProfileClass=choice.profile and tostring(choice.profile.class or ""):upper() or nil
  state.enemyAttackSelf=(kind=="self")
  state.enemyAttackRange=range
  state.enemyAttackRadius=math.max(.18,(tonumber(radius) or 0)*accScale)
  state.enemyAttackAOERadius=kind=="ground-aoe" and math.max(.35,(tonumber(radius) or 4)*accScale) or 0
  state.enemyAttackConeHalfAngle=kind=="cone" and math.rad(clamp((tonumber(radius) or tonumber(choice.profile and choice.profile.angle) or 45)*accScale,8,90))*.5 or 0
  state.enemyAttackTargetX=nil;state.enemyAttackTargetZ=nil
  if kind=="ground-aoe" then
    local vx,vz=tx-state.ex,tz-state.ez
    local dd=len2(vx,vz)
    if dd>math.max(1,range) then vx,vz=normalize2(vx,vz);tx,tz=state.ex+vx*range,state.ez+vz*range end
    state.enemyAttackTargetX,state.enemyAttackTargetZ=tx,tz
    ax,az=normalize2(tx-state.ex,tz-state.ez)
    if ax==0 and az==0 then ax,az=0,1 end
  end
  state.enemyAttackDirX,state.enemyAttackDirZ=ax,az
  state.enemyFacingX,state.enemyFacingZ=ax,az
  state.enemyProjectileX=nil;state.enemyProjectileZ=nil
  state.enemyProjectilePrevX=nil;state.enemyProjectilePrevZ=nil
  state.enemyProjectileVX,state.enemyProjectileVZ=0,0

  if kind=="projectile" then
    state.enemyProjectileX=state.ex+ax*(state.enemyRadius+.5)
    state.enemyProjectileZ=state.ez+az*(state.enemyRadius+.5)
    state.enemyProjectilePrevX,state.enemyProjectilePrevZ=state.enemyProjectileX,state.enemyProjectileZ
    local flight=clamp(math.max(1,range)/42,.34,.72)
    local speed=math.max(1,range)/math.max(.12,flight)
    state.enemyProjectileVX,state.enemyProjectileVZ=ax*speed,az*speed
    state.enemyAttackDuration=flight+.18
    state.enemyAttackActiveStart=.04;state.enemyAttackActiveEnd=flight+.04
  elseif kind=="stream" then
    state.enemyAttackDuration=.82;state.enemyAttackActiveStart=.16;state.enemyAttackActiveEnd=.70
  elseif kind=="target-line" then
    state.enemyAttackDuration=.72;state.enemyAttackActiveStart=.16;state.enemyAttackActiveEnd=.54
  elseif kind=="cone" then
    state.enemyAttackDuration=.82;state.enemyAttackActiveStart=.28;state.enemyAttackActiveEnd=.64
  elseif kind=="ground-aoe" then
    state.enemyAttackDuration=.98;state.enemyAttackActiveStart=.58;state.enemyAttackActiveEnd=.70
  elseif kind=="radial" then
    state.enemyAttackDuration=.74;state.enemyAttackActiveStart=.18;state.enemyAttackActiveEnd=.58
  elseif kind=="self" then
    state.enemyAttackDuration=.62;state.enemyAttackActiveStart=.18;state.enemyAttackActiveEnd=.30
  else
    state.enemyAttackDuration=.58;state.enemyAttackActiveStart=.14;state.enemyAttackActiveEnd=.36
  end
  local enemyXdId,enemyCanonical,enemyXdVFX=R._fx.mapAnyMoveVFX(context,choice.inst.id)
  local ev=R._fx.beginSideVFX("enemy",choice.inst.id,motionDef,kind,enemyXdVFX,enemyXdId,enemyCanonical or choice.inst.id)
  if enemyXdVFX then
    local oldProbe=state.v2Probe
    local okProbe=pcall(probeGPT1V2,context,enemyXdVFX,enemyXdId,enemyCanonical or choice.inst.id)
    if okProbe then state.enemyV2Probe=state.v2Probe;if ev then ev.xdProbe=state.v2Probe end end
    state.v2Probe=oldProbe
  end
  state.enemyLastResult="AI ACTIVE "..tostring(kind):upper().." "..tostring(choice.inst.id)
  R._announceEnemyMove(context,choice.inst.id,motionDef)
  return true
end

local function updateEnemyAttack(context,dt)
  if state.enemyAttackCooldown>0 then
    state.enemyAttackCooldown=math.max(0,state.enemyAttackCooldown-dt)
  end
  if state.enemyAttackAge<=0 then return end
  state.enemyAttackAge=state.enemyAttackAge+dt
  if state.enemyAttackKind=="projectile" and state.enemyProjectileX then
    state.enemyProjectilePrevX,state.enemyProjectilePrevZ=state.enemyProjectileX,state.enemyProjectileZ
    state.enemyProjectileX=state.enemyProjectileX+state.enemyProjectileVX*dt
    state.enemyProjectileZ=state.enemyProjectileZ+state.enemyProjectileVZ*dt
  end
  if enemyAttackActive() and not state.enemyAttackHit then
    local hit=false
    if state.enemyAttackKind=="self" then
      hit=true
    elseif state.enemyAttackKind=="projectile" and state.enemyProjectileX then
      local rr=R._enemyTargetRadius()+(state.enemyAttackRadius or .8)
      hit=pointSegmentDistance2(state.px,state.pz,
        state.enemyProjectilePrevX or state.enemyProjectileX,state.enemyProjectilePrevZ or state.enemyProjectileZ,
        state.enemyProjectileX,state.enemyProjectileZ)<=rr*rr
    elseif state.enemyAttackKind=="stream" or state.enemyAttackKind=="target-line" then
      hit=enemyLineHitsPlayer(state.enemyAttackRange,state.enemyAttackRadius)
    elseif state.enemyAttackKind=="cone" then
      hit=R._coneHitsPoint(state.px,state.pz,state.ex,state.ez,state.enemyAttackDirX,state.enemyAttackDirZ,
        state.enemyAttackRange or 10,state.enemyAttackConeHalfAngle or math.rad(22.5),R._enemyTargetRadius())
    elseif state.enemyAttackKind=="ground-aoe" then
      local dx,dz=state.px-(tonumber(state.enemyAttackTargetX) or state.ex),state.pz-(tonumber(state.enemyAttackTargetZ) or state.ez)
      local rr=(tonumber(state.enemyAttackAOERadius) or 4)+R._enemyTargetRadius()
      hit=dx*dx+dz*dz<=rr*rr
    elseif state.enemyAttackKind=="radial" then
      local dx,dz=state.px-state.ex,state.pz-state.ez
      local rr=(state.enemyAttackRange or 9)+R._enemyTargetRadius()
      hit=dx*dx+dz*dz<=rr*rr
    else
      hit=enemyContactHitsPlayer()
    end
    if hit then
      state.enemyAttackHit=true
      if R._playerDamageBlocked() then
        spendEnemyMissPP(context)
        state.enemyLastResult=state.playerHitAnimating and "AI HITSTUN BLOCK" or "AI I-FRAME BLOCK"
      elseif not resolveEnemyMove(context) then
        state.enemyLastResult=state.enemyLastResult or "AI HIT FAILED"
      end
    end
  end
  if state.enemyAttackAge>=state.enemyAttackDuration then
    state.enemyGlobalAttackLock=math.max(tonumber(state.enemyGlobalAttackLock) or 0,R._GLOBAL_ATTACK_RECOVERY)
    if not state.enemyAttackHit then
      spendEnemyMissPP(context)
      state.enemyLastResult="AI MISS (PP SPENT)"
    end
    state.enemyAttackAge=0
    state.enemyAttackMove=nil;state.enemyAttackMoveDef=nil;state.enemyAttackMoveId=nil
    state.enemyAttackMoveSlot=nil;state.enemyAttackKind=nil;state.enemyAttackProfileClass=nil;state.enemyAttackSelf=false
    state.enemyAttackTargetX=nil;state.enemyAttackTargetZ=nil;state.enemyAttackAOERadius=0;state.enemyAttackConeHalfAngle=0
    state.enemyAttackResolved=false;state.enemyAttackPpSpent=false
    state.enemyProjectileX=nil;state.enemyProjectileZ=nil
    state.enemyProjectilePrevX=nil;state.enemyProjectilePrevZ=nil
    state.enemyProjectileVX,state.enemyProjectileVZ=0,0
    state.enemyAttackAccuracyScale=1
  end
end

local function constrainEnemyToArena(arena)
  local nav=arenaNavigation(arena)
  local pad=state.enemyRadius+.18
  if nav and type(nav.hull)=="table" and #nav.hull>=3 then
    local hull=nav.hull
    for _=1,3 do
      local moved=false
      for i=1,#hull do
        local a,b=hull[i],hull[i%#hull+1]
        local x1,z1=tonumber(a[1]) or 0,tonumber(a[2]) or 0
        local x2,z2=tonumber(b[1]) or 0,tonumber(b[2]) or 0
        local ex,ez=x2-x1,z2-z1
        local l=math.sqrt(ex*ex+ez*ez)
        if l>1e-6 then
          local nx,nz=-ez/l,ex/l
          local dist=(state.ex-x1)*nx+(state.ez-z1)*nz
          if dist<pad then
            local push=pad-dist
            state.ex=state.ex+nx*push;state.ez=state.ez+nz*push;moved=true
          end
        end
      end
      if not moved then break end
    end
    for _,w in ipairs(nav.walls or {}) do
      local x1,z1,x2,z2=tonumber(w[1]) or 0,tonumber(w[2]) or 0,tonumber(w[3]) or 0,tonumber(w[4]) or 0
      local vx,vz=x2-x1,z2-z1;local ll=vx*vx+vz*vz
      if ll>1e-8 then
        local t=clamp(((state.ex-x1)*vx+(state.ez-z1)*vz)/ll,0,1)
        local qx,qz=x1+vx*t,z1+vz*t
        local dx,dz=state.ex-qx,state.ez-qz;local d2=dx*dx+dz*dz
        if d2<pad*pad then
          local d=math.sqrt(d2);local nx,nz
          if d>1e-5 then nx,nz=dx/d,dz/d else local l=math.sqrt(ll);nx,nz=-vz/l,vx/l end
          local push=pad-d;state.ex=state.ex+nx*push;state.ez=state.ez+nz*push
        end
      end
    end
    return
  end
  local mid=arena and arena.mid or {0,0}
  local mx,mz=tonumber(mid[1]) or 0,tonumber(mid[2]) or 0
  local dx,dz=state.ex-mx,state.ez-mz
  local maxR=math.max(2,state.arenaRadius-state.enemyRadius)
  local d=len2(dx,dz)
  if d>maxR then local nx,nz=normalize2(dx,dz);state.ex=mx+nx*maxR;state.ez=mz+nz*maxR end
end

local function updateEnemyAI(context,dt,arena)
  updateEnemyAttack(context,dt)
  local battle=gen1Battle(context)
  if not battle or not battle.enemy or not battle.player then return end
  if not (battle.enemy.mon and battle.player.mon) then return end
  if (tonumber(battle.enemy.mon.hp) or 0)<=0 or (tonumber(battle.player.mon.hp) or 0)<=0 then
    state.enemyMoving=false;return
  end
  if state.impactLockActive or state.enemyHitAnimating then
    state.enemyMoving=false;return
  end
  local enemySleeping=battlerSleeping(battle.enemy)
  local enemyFrozen=R._battlerFrozen(battle.enemy)
  local enemyConfused=battlerConfused(battle.enemy)
  updateConfusionSteer("enemy",enemyConfused,dt)

  state.enemyAIThink=math.max(0,(tonumber(state.enemyAIThink) or 0)-dt)
  state.enemyAIStrafeClock=math.max(0,(tonumber(state.enemyAIStrafeClock) or 0)-dt)
  state.enemyAIFireClock=math.max(0,(tonumber(state.enemyAIFireClock) or 0)-dt)
  state.enemyAIDodgeClock=math.max(0,(tonumber(state.enemyAIDodgeClock) or 0)-dt)
  if state.enemyAIStrafeClock<=0 then
    state.enemyAIStrafe=-(tonumber(state.enemyAIStrafe) or 1)
    state.enemyAIStrafeClock=1.15
  end
  -- Read the player's committed attack and sidestep the line during its active
  -- window. This is deliberately the same for every species.
  if state.attackAge>0 and (state.attackKind=="projectile" or state.attackKind=="stream" or state.attackKind=="target-line") then
    state.enemyAIDodgeClock=math.max(state.enemyAIDodgeClock,.34)
  end

  local dx,dz=state.px-state.ex,state.pz-state.ez
  local dist=len2(dx,dz)
  local fx,fz=normalize2(dx,dz);if fx==0 and fz==0 then fx,fz=0,1 end
  local rx,rz=-fz,fx
  if state.enemyAttackAge>0 then
    state.enemyFacingX,state.enemyFacingZ=state.enemyAttackDirX,state.enemyAttackDirZ
  else
    state.enemyFacingX,state.enemyFacingZ=fx,fz
  end
  local choice=chooseEnemyMove(context,dist)
  local desired=ENEMY_AI_IDEAL_RANGE
  if choice then
    if choice.kind=="contact" then desired=math.max(3.2,(choice.range or 4.5)*.78)
    elseif choice.kind=="radial" then desired=math.max(5.0,(choice.range or 9)*.65)
    elseif choice.kind=="self" then desired=dist
    else desired=clamp((choice.range or 15)*.68,8.0,ENEMY_AI_MAX_RANGE) end
  end

  local forward=0
  if dist>desired+1.6 then forward=1 elseif dist<math.max(3.4,desired-2.2) then forward=-1 end
  local strafe=(state.enemyAIStrafe or 1)*.72
  if state.enemyAIDodgeClock>0 then strafe=(state.enemyAIStrafe or 1)*1.45;forward=forward*.25 end
  local mx,mz=fx*forward+rx*strafe,fz*forward+rz*strafe
  mx,mz=normalize2(mx,mz)
  if enemyConfused then mx,mz=rotate2(mx,mz,state.enemyConfuseAngle) end
  if enemySleeping or enemyFrozen then mx,mz=0,0 end
  if mx~=0 or mz~=0 then
    local enemySpeed=tonumber(state.enemyMoveSpeed) or TORKOAL_ENEMY_MOVE_SPEED
    state.ex=state.ex+mx*enemySpeed*dt
    state.ez=state.ez+mz*enemySpeed*dt
    state.enemyMoving=true
  else state.enemyMoving=false end
  constrainEnemyToArena(arena)

  dx,dz=state.px-state.ex,state.pz-state.ez;dist=len2(dx,dz)
  if state.enemyAIFireClock<=0 and battle.phase=="menu" and choice and enemyMoveInRange(choice,dist) then
    if startEnemyMove(context,choice) then
      state.enemyAIMoveCursor=(state.enemyAIMoveCursor or 0)+1
      state.enemyAIFireClock=.58+((state.enemyAIMoveCursor%3)*.11)
    else
      state.enemyAIFireClock=.18
    end
  end
end

local function resolveTackleHit(context)
  return resolveRealtimeMove(context)
end

local function updateTackle(context,dt)
  if state.attackCooldown>0 then
    state.attackCooldown=math.max(0,state.attackCooldown-dt)
    if state.attackCooldown==0 and state.attackAge<=0 then state.attackResult="READY" end
  end
  if state.attackAge<=0 then return end

  state.attackAge=state.attackAge+dt

  if state.attackKind=="projectile" and state.projectileX then
    if (tonumber(state.projectileHomingTimer) or 0)>0 then
      local vx,vz=tonumber(state.projectileVX) or 0,tonumber(state.projectileVZ) or 0
      local speed=len2(vx,vz)
      local cx,cz=normalize2(vx,vz)
      local tx,tz=normalize2((state.ex or 0)-state.projectileX,(state.ez or 0)-state.projectileZ)
      if speed>1e-5 and (tx~=0 or tz~=0) then
        local dot=clamp(cx*tx+cz*tz,-1,1)
        local delta=math.acos(dot)
        if delta<=R._PROJECTILE_HOMING_CONE then
          local current=atan2(cx,cz)
          local desired=atan2(tx,tz)
          local signed=(desired-current+math.pi)%(math.pi*2)-math.pi
          local maxTurn=R._PROJECTILE_HOMING_TURN*(tonumber(state.projectileHomingScale) or 1)*dt
          local ang=current+clamp(signed,-maxTurn,maxTurn)
          state.projectileVX=math.sin(ang)*speed
          state.projectileVZ=math.cos(ang)*speed
        end
      end
      state.projectileHomingTimer=math.max(0,(tonumber(state.projectileHomingTimer) or 0)-dt)
    end
    state.projectilePrevX,state.projectilePrevZ=state.projectileX,state.projectileZ
    state.projectileX=state.projectileX+state.projectileVX*dt
    state.projectileZ=state.projectileZ+state.projectileVZ*dt
  end

  if attackActive() and not state.attackHit then
    local hit=false
    if state.attackKind=="self" then
      hit=true
    elseif state.attackKind=="projectile" and state.projectileX then
      local rr=R._playerTargetRadius()+(state.projectileRadius or .8)
      local ax,az=state.projectilePrevX or state.projectileX,state.projectilePrevZ or state.projectileZ
      hit=pointSegmentDistance2(state.ex,state.ez,ax,az,state.projectileX,state.projectileZ)<=rr*rr
    elseif state.attackKind=="stream" then
      hit=lineCapsuleHitsEnemy(state.attackRange or 16,state.projectileRadius or 1.35)
    elseif state.attackKind=="target-line" then
      hit=lineCapsuleHitsEnemy(state.attackRange or 18,state.projectileRadius or 1.8)
    elseif state.attackKind=="cone" then
      hit=R._coneHitsPoint(state.ex,state.ez,state.px,state.pz,state.attackDirX,state.attackDirZ,
        state.attackRange or 10,state.attackConeHalfAngle or math.rad(22.5),R._playerTargetRadius())
    elseif state.attackKind=="ground-aoe" then
      local dx,dz=state.ex-(tonumber(state.attackTargetX) or state.px),state.ez-(tonumber(state.attackTargetZ) or state.pz)
      local rr=(tonumber(state.attackAOERadius) or 4)+R._playerTargetRadius()
      hit=(dx*dx+dz*dz)<=rr*rr
    elseif state.attackKind=="radial" then
      local dx,dz=state.ex-state.px,state.ez-state.pz
      local rr=(state.attackRange or 9)+R._playerTargetRadius()
      hit=(dx*dx+dz*dz)<=rr*rr
    else
      hit=circleHitsOBB(state.ex,state.ez,R._playerTargetRadius(),tackleBox())
    end
    if hit then
      state.attackHit=true
      if R._enemyDamageBlocked() then
        spendManualMissPP(context)
        state.attackResult=state.enemyHitAnimating and "ENEMY HITSTUN BLOCK" or "ENEMY I-FRAME BLOCK"
      else
        -- Presentation reacts to confirmed opponent collision only. Self/field
        -- moves deliberately have no enemy impact marker.
        if state.attackKind~="self" then
          if state.attackKind=="ground-aoe" then spawnImpactVFX(state.attackTargetX,state.attackTargetZ)
          else spawnImpactVFX() end
        end
        if not resolveRealtimeMove(context) then
          state.attackResult=state.combatError or "HIT RESOLVE FAILED"
        end
      end
    end
  end

  if state.attackAge>=state.attackDuration then
    state.playerGlobalAttackLock=math.max(tonumber(state.playerGlobalAttackLock) or 0,R._GLOBAL_ATTACK_RECOVERY)
    if not state.attackHit then
      spendManualMissPP(context)
      state.attackResult="MANUAL MISS (PP SPENT)"
      R._showPlayerAction(context,"Attack missed!",1.05,"manual-miss:"..tostring(state.attackSerial or 0),"result")
    end
    state.attackAge=0
    state.attackMove=nil
    state.attackMoveDef=nil
    state.attackMoveId=nil
    state.attackMoveSlot=nil
    state.attackKind=nil
    state.attackProfileClass=nil;state.attackAOERadius=0;state.attackConeHalfAngle=0
    state.attackSelf=false;state.attackResolved=false;state.attackPpSpent=false
    state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
    state.projectileVX=0;state.projectileVZ=0;state.projectileHomingTimer=0;state.projectileHomingScale=1
    state.attackAssistActive=false;state.attackAssistAmount=0
    state.attackAccuracyScale=1
  end
end

local function updateAttackMotionLock()
  if not state.attackMotionLock then return end
  local actorInfo
  local csm=V and V.CurrentSpriteModels
  if csm and type(csm.realtimeActorState)=="function" then
    local ok,value=pcall(csm.realtimeActorState,csm,"player")
    if ok and type(value)=="table" then actorInfo=value end
  end
  if actorInfo and actorInfo.state=="attack" then
    state.attackActorSeen=true
    return
  end
  -- Collision/VFX timing must always finish before locomotion can resume. Once
  -- the portable actor has actually entered its attack state, also wait for the
  -- native XD one-shot to hand itself back to Idle. If no 3D actor is present,
  -- fail open after the ordinary realtime attack cooldown.
  if state.attackAge>0 then return end
  if state.attackActorSeen then
    state.attackMotionLock=false
  elseif state.attackCooldown<=0 then
    state.attackMotionLock=false
  end
end

function R._updateAttackFacingLock(dt)
  if not state.attackFacingLock then return end
  state.attackFacingTimer=math.max(0,(tonumber(state.attackFacingTimer) or 0)-(tonumber(dt) or 0))
  local info
  local csm=V and V.CurrentSpriteModels
  if csm and type(csm.realtimeActorState)=="function" then
    local ok,v=pcall(csm.realtimeActorState,csm,"player")
    if ok and type(v)=="table" then info=v end
  end
  if info and info.state=="attack" then
    state.attackFacingActorSeen=true
    return
  end
  if (tonumber(state.attackAge) or 0)>0 then return end
  if state.attackFacingActorSeen or state.attackFacingTimer<=0 then
    state.attackFacingLock=false;state.attackFacingActorSeen=false;state.attackFacingTimer=0
  end
end

local function project(context,x,y,z)
  local fn=context and context.services and context.services.project
  if type(fn)~="function" then return nil end
  local ok,sx,sy=pcall(fn,x,y,z)
  if not ok or type(sx)~="number" or type(sy)~="number" then return nil end
  return sx,sy
end

local function figureScale(context)
  return math.max(.08,tonumber(context and context.services and context.services.figureScale)
    or tonumber(context and context.arena and context.arena.figureScale) or .38)
end

-- Realtime collision/navigation is stored in visual stage units, while the
-- actor projector deliberately expects pre-figure-scale Pokemon world units.
-- Keep those domains explicit so presentation can follow exact model joints
-- without ever feeding back into collision/damage.
local function stageToActor(context,x,y,z)
  local k=figureScale(context)
  return {(tonumber(x) or 0)/k,(tonumber(y) or 0)/k,(tonumber(z) or 0)/k}
end

local function projectStage(context,x,y,z)
  local p=stageToActor(context,x,y,z)
  return project(context,p[1],p[2],p[3])
end

local function attachmentPoint(context,side,name,fallbackY)
  local csm=V and V.CurrentSpriteModels
  if csm and type(csm.attachmentPoint)=="function" then
    local ok,p,exact=pcall(csm.attachmentPoint,csm,context,side,name)
    if ok and type(p)=="table" and tonumber(p[1]) and tonumber(p[2]) and tonumber(p[3]) then
      return {tonumber(p[1]),tonumber(p[2]),tonumber(p[3])},exact==true
    end
  end
  local x,z
  if side=="enemy" then x,z=state.ex,state.ez else x,z=state.px,state.pz end
  if side=="player" and name=="mouth" then
    local fx,fz=normalize2(state.facingX,state.facingZ)
    x=x+fx*state.playerRadius*.72
    z=z+fz*state.playerRadius*.72
  end
  local gy=tonumber(context and context.groundY) or 0
  return stageToActor(context,x,gy+(tonumber(fallbackY) or 2.0),z),false
end

local function drawProjectedLine(context,points)
  local out={}
  for _,v in ipairs(points) do
    local x,y=projectStage(context,v[1],v[2],v[3])
    if not x then return false end
    out[#out+1]=x;out[#out+1]=y
  end
  if #out>=4 then love.graphics.line(out);return true end
  return false
end

local function drawCylinder(context,cx,cz,r,y0,h,segments)
  segments=segments or 20
  local bottom,top={},{}
  for i=0,segments do
    local a=(i/segments)*math.pi*2
    local x=cx+math.cos(a)*r
    local z=cz+math.sin(a)*r
    bottom[#bottom+1]={x,y0,z}
    top[#top+1]={x,y0+h,z}
  end
  drawProjectedLine(context,bottom)
  drawProjectedLine(context,top)
  for _,i in ipairs({1,1+math.floor(segments/4),1+math.floor(segments/2),1+math.floor(segments*3/4)}) do
    local b=bottom[i];local t=top[i]
    if b and t then drawProjectedLine(context,{b,t}) end
  end
end

local function boxCorners(box,y0)
  local function point(r,f,y)
    return {
      box.cx+box.rx*r+box.fx*f,
      y,
      box.cz+box.rz*r+box.fz*f,
    }
  end
  local w,d,h=box.halfW,box.halfD,box.height
  return {
    point(-w,-d,y0),point(w,-d,y0),point(w,d,y0),point(-w,d,y0),
    point(-w,-d,y0+h),point(w,-d,y0+h),point(w,d,y0+h),point(-w,d,y0+h),
  }
end

local function drawBox(context,box,y0)
  local c=boxCorners(box,y0)
  drawProjectedLine(context,{c[1],c[2],c[3],c[4],c[1]})
  drawProjectedLine(context,{c[5],c[6],c[7],c[8],c[5]})
  for i=1,4 do drawProjectedLine(context,{c[i],c[i+4]}) end
end

local function setColorA(c,a,boost)
  local b=tonumber(boost) or 1
  love.graphics.setColor(clamp((c[1] or 1)*b,0,1),clamp((c[2] or 1)*b,0,1),clamp((c[3] or 1)*b,0,1),clamp(a or 1,0,1))
end

local function projectedRadius(context,x,y,z,r)
  local sx,sy=project(context,x,y,z)
  if not sx then return nil end
  local ax,ay=project(context,x+r,y,z)
  local bx,by=project(context,x,y+r,z)
  local pr=5
  if ax then pr=math.max(pr,math.sqrt((ax-sx)^2+(ay-sy)^2)) end
  if bx then pr=math.max(pr,math.sqrt((bx-sx)^2+(by-sy)^2)) end
  return sx,sy,clamp(pr,2,80)
end

local function drawGlowOrb(context,x,y,z,r,c,alpha)
  local sx,sy,pr=projectedRadius(context,x,y,z,r)
  if not sx then return false end
  local g=love.graphics
  setColorA(c,(alpha or 1)*.18);g.circle("fill",sx,sy,pr*1.85)
  setColorA(c,(alpha or 1)*.72,1.08);g.circle("fill",sx,sy,pr)
  g.setColor(1,1,1,(alpha or 1)*.88);g.circle("fill",sx-pr*.17,sy-pr*.17,math.max(1,pr*.34))
  return true
end

local function collisionLine()
  local fx,fz=attackDirection()
  local ax,az=state.px+fx*state.playerRadius,state.pz+fz*state.playerRadius
  return ax,az,ax+fx*(state.attackRange or 0),az+fz*(state.attackRange or 0),fx,fz
end

local function projectileLaunchSource(context,v)
  if type(v.launchSource)=="table" then return v.launchSource end
  local p=attachmentPoint(context,"player","mouth",2.15)
  v.launchSource={p[1],p[2],p[3]}
  return v.launchSource
end

local function projectileVisualPoint(context,v,x,z)
  local src=projectileLaunchSource(context,v)
  local k=figureScale(context)
  local sx=tonumber(v.collisionStartX) or tonumber(state.px) or 0
  local sz=tonumber(v.collisionStartZ) or tonumber(state.pz) or 0
  return {
    src[1]+((tonumber(x) or sx)-sx)/k,
    src[2],
    src[3]+((tonumber(z) or sz)-sz)/k,
  }
end

local function drawWorldPolyline(context,pts,width,c,alpha)
  local out={}
  for _,p in ipairs(pts) do
    local x,y=project(context,p[1],p[2],p[3])
    if x then out[#out+1]=x;out[#out+1]=y end
  end
  if #out<4 then return false end
  local g=love.graphics
  if type(g.setLineJoin)=="function" then g.setLineJoin("bevel") end
  g.setLineWidth(width)
  setColorA(c,alpha)
  g.line(out)
  return true
end

local function drawEmber(context,v,gy)
  if not state.projectileX then return end
  local c=v.color
  local source=projectileLaunchSource(context,v)
  if (tonumber(v.age) or 0)<.18 then
    drawGlowOrb(context,source[1],source[2],source[3],.44/figureScale(context),c,.72)
  end
  for _,p in ipairs(v.trail or {}) do
    local age=tonumber(p.age) or 0
    local a=clamp(1-age/.32,0,1)
    local scale=(.20+.48*a)/figureScale(context)
    local q=projectileVisualPoint(context,v,p.x,p.z)
    drawGlowOrb(context,q[1],q[2],q[3],scale,c,.42*a)
  end
  local q=projectileVisualPoint(context,v,state.projectileX,state.projectileZ)
  drawGlowOrb(context,q[1],q[2],q[3],.76/figureScale(context),c,1)
end

local function drawGenericProjectile(context,v,gy)
  if not state.projectileX then return end
  local c=v.color
  local source=projectileLaunchSource(context,v)
  if (tonumber(v.age) or 0)<.14 then
    drawGlowOrb(context,source[1],source[2],source[3],.34/figureScale(context),c,.55)
  end
  for _,p in ipairs(v.trail or {}) do
    local a=clamp(1-(tonumber(p.age) or 0)/.32,0,1)
    local q=projectileVisualPoint(context,v,p.x,p.z)
    drawGlowOrb(context,q[1],q[2],q[3],(.22+.32*a)/figureScale(context),c,.28*a)
  end
  local q=projectileVisualPoint(context,v,state.projectileX,state.projectileZ)
  drawGlowOrb(context,q[1],q[2],q[3],.64/figureScale(context),c,.95)
end

local function drawFlameStream(context,v,gy)
  local _,_,_,_,fx,fz=collisionLine()
  local src=attachmentPoint(context,"player","mouth",2.15)
  local k=figureScale(context)
  local range=(tonumber(state.attackRange) or 0)/k
  local bx,bz=src[1]+fx*range,src[3]+fz*range
  local rx,rz=-fz,fx
  local pts={}
  local segments=18
  local phase=(state.attackAge or 0)*34+state.attackSerial*.71
  for i=0,segments do
    local t=i/segments
    local envelope=math.sin(math.pi*t)
    local wave=math.sin(phase+t*16)*(.22+.28*t)*envelope/k
    local lift=(.10+math.sin(phase*.71+t*11)*.11)/k
    pts[#pts+1]={src[1]+(bx-src[1])*t+rx*wave,src[2]+lift+(t*.10/k),src[3]+(bz-src[3])*t+rz*wave}
  end
  drawWorldPolyline(context,pts,15,v.color,.20)
  drawWorldPolyline(context,pts,9,v.color,.72)
  love.graphics.setColor(1,0.84,0.38,.82)
  local core={}
  for i,p in ipairs(pts) do core[i]={p[1],p[2]+.02/k,p[3]} end
  drawWorldPolyline(context,core,3,{1,.86,.42},.92)
  for i=3,#pts,3 do
    local p=pts[i]
    drawGlowOrb(context,p[1],p[2],p[3],(.24+.12*(i%2))/k,v.color,.36)
  end
end

local function drawGenericStream(context,v,gy)
  local _,_,_,_,fx,fz=collisionLine()
  local src=attachmentPoint(context,"player","mouth",2.15)
  local k=figureScale(context)
  local range=(tonumber(state.attackRange) or 0)/k
  local bx,bz=src[1]+fx*range,src[3]+fz*range
  local rx,rz=-fz,fx
  local pts={}
  local phase=(state.attackAge or 0)*20+state.attackSerial
  for i=0,12 do
    local t=i/12
    local wave=math.sin(phase+t*10)*.16*math.sin(math.pi*t)/k
    pts[#pts+1]={src[1]+(bx-src[1])*t+rx*wave,src[2]+math.sin(phase+t*7)*.06/k,src[3]+(bz-src[3])*t+rz*wave}
  end
  drawWorldPolyline(context,pts,11,v.color,.20)
  drawWorldPolyline(context,pts,6,v.color,.70)
  drawWorldPolyline(context,pts,2,{1,1,1},.72)
end

local function manualAimActorEndpoint(context,src)
  local fx,fz=attackDirection()
  local k=figureScale(context)
  local range=(tonumber(state.attackRange) or 0)/k
  return {src[1]+fx*range,src[2],src[3]+fz*range}
end

local function drawThunderbolt(context,v,gy)
  local src=attachmentPoint(context,"player","mouth",2.2)
  local target=manualAimActorEndpoint(context,src)
  local dx,dz=target[1]-src[1],target[3]-src[3]
  local nx,nz=normalize2(dx,dz)
  local rx,rz=-nz,nx
  local pts={{src[1],src[2],src[3]}}
  local phase=math.floor((state.attackAge or 0)*28)+state.attackSerial*5
  local k=figureScale(context)
  for i=1,10 do
    local t=i/11
    local jitter=((i*37+phase*17)%11-5)/5
    local off=jitter*(.28+.36*math.sin(math.pi*t))/k
    pts[#pts+1]={src[1]+dx*t+rx*off,src[2]+(((i*13+phase)%7)-3)*.075/k,src[3]+dz*t+rz*off}
  end
  pts[#pts+1]={target[1],target[2],target[3]}
  drawWorldPolyline(context,pts,12,v.color,.16)
  drawWorldPolyline(context,pts,6,v.color,.92)
  drawWorldPolyline(context,pts,2,{1,1,1},.98)
  for i=3,#pts-2,3 do
    local p=pts[i]
    drawGlowOrb(context,p[1],p[2],p[3],.30/k,v.color,.35)
  end
end

local function drawGenericTargetLine(context,v,gy)
  local src=attachmentPoint(context,"player","mouth",2.15)
  local target=manualAimActorEndpoint(context,src)
  local pts={{src[1],src[2],src[3]},{target[1],target[2],target[3]}}
  drawWorldPolyline(context,pts,12,v.color,.16)
  drawWorldPolyline(context,pts,6,v.color,.80)
  drawWorldPolyline(context,pts,2,{1,1,1},.68)
end

local function drawContactVFX(context,v,gy)
  local fx,fz=normalize2(state.facingX,state.facingZ)
  if fx==0 and fz==0 then fx,fz=0,-1 end
  local rx,rz=-fz,fx
  local k=figureScale(context)
  local base=attachmentPoint(context,"player","center",1.55)
  local cx,cz=base[1]+fx*(state.playerRadius+1.1)/k,base[3]+fz*(state.playerRadius+1.1)/k
  local pts={}
  local ageNorm=clamp((state.attackAge-state.attackActiveStart)/math.max(.01,state.attackActiveEnd-state.attackActiveStart),0,1)
  local sweep=-1.15+2.30*ageNorm
  for i=0,9 do
    local t=i/9
    local a=sweep-.80+t*1.55
    local rr=(1.0+1.15*t)/k
    pts[#pts+1]={cx+rx*math.sin(a)*rr+fx*math.cos(a)*.35/k,base[2]-.15/k+t*1.4/k,cz+rz*math.sin(a)*rr+fz*math.cos(a)*.35/k}
  end
  drawWorldPolyline(context,pts,12,v.color,.14)
  drawWorldPolyline(context,pts,6,v.color,.78)
  drawWorldPolyline(context,pts,2,{1,1,1},.66)
end

local function drawImpact(context,p)
  local life=clamp(1-(p.age/(p.duration or .4)),0,1)
  local grow=1+3.5*(p.age/(p.duration or .4))
  local center=stageToActor(context,p.x,(context.groundY or 0)+(p.y or 2.1),p.z)
  local sx,sy,pr=projectedRadius(context,center[1],center[2],center[3],(.42*grow)/figureScale(context))
  if not sx then return end
  local g=love.graphics
  setColorA(p.color,.18*life);g.circle("fill",sx,sy,pr*1.35)
  setColorA(p.color,.86*life,1.12);g.circle("line",sx,sy,pr*.78)
  g.setLineWidth(math.max(1,4*life))
  for i=0,9 do
    local a=(i/10)*math.pi*2+(p.serial or 0)*.37
    local inner=pr*.42
    local outer=pr*(.95+((i*7)%4)*.18)
    g.line(sx+math.cos(a)*inner,sy+math.sin(a)*inner,sx+math.cos(a)*outer,sy+math.sin(a)*outer)
  end
  g.setColor(1,1,1,.85*life);g.circle("fill",sx,sy,math.max(1,pr*.18))
end

-- v0.5.2: robust screen-projected replacement VR._fx. The stage renderer already
-- provides a camera-correct projector; drawing the lightweight effects in screen
-- space avoids GameCube/actor scale mismatches while still anchoring each frame
-- to the live animated PKX mouth when that anchor is sane.
local function renderSize(context)
  local r=context and context.services and context.services.renderSize or {}
  return tonumber(r.width) or 1280,tonumber(r.height) or 720
end

R._pad.mouseToRender=function(context)
  local mx,my=0,0
  if love and love.mouse and type(love.mouse.getPosition)=="function" then
    mx,my=love.mouse.getPosition()
  end
  local rw,rh=renderSize(context)
  local ww,wh=0,0
  if love and love.graphics and type(love.graphics.getDimensions)=="function" then
    ww,wh=love.graphics.getDimensions()
  end
  if ww and wh and ww>0 and wh>0 and (rw~=ww or rh~=wh) then
    return mx*(rw/ww),my*(rh/wh)
  end
  return mx,my
end

local function drawAimCrosshair(context)
  local g=love.graphics
  local w,h=renderSize(context)
  local cx,cy=w*.5,h*.5
  local gap,arm=5,11
  g.setBlendMode("alpha","alphamultiply")
  g.setLineWidth(4)
  g.setColor(0,0,0,.78)
  g.line(cx-arm-1,cy,cx-gap+1,cy);g.line(cx+gap-1,cy,cx+arm+1,cy)
  g.line(cx,cy-arm-1,cx,cy-gap+1);g.line(cx,cy+gap-1,cx,cy+arm+1)
  g.circle("line",cx,cy,4)
  g.setLineWidth(2)
  g.setColor(1,1,1,.96)
  g.line(cx-arm,cy,cx-gap,cy);g.line(cx+gap,cy,cx+arm,cy)
  g.line(cx,cy-arm,cx,cy-gap);g.line(cx,cy+gap,cx,cy+arm)
  g.circle("line",cx,cy,3)
end

local function screenFallbackAnchor(context,side,name,fallbackY)
  local x,z
  if side=="enemy" then x,z=state.ex,state.ez else x,z=state.px,state.pz end
  local fx,fz=attackDirection()
  if side=="player" and name=="mouth" then
    x=x+fx*state.playerRadius*.70;z=z+fz*state.playerRadius*.70
  end
  local gy=tonumber(context and context.groundY) or 0
  local sx,sy=projectStage(context,x,gy+(tonumber(fallbackY) or 2.4),z)
  return sx,sy
end

local function screenAnchor(context,side,name,fallbackY)
  local fsx,fsy=screenFallbackAnchor(context,side,name,fallbackY)
  local p,exact=attachmentPoint(context,side,name,fallbackY)
  if type(p)=="table" then
    local sx,sy=project(context,p[1],p[2],p[3])
    if sx and sy then
      local w,h=renderSize(context)
      local onScreen=sx>-w*.18 and sx<w*1.18 and sy>-h*.18 and sy<h*1.18
      local nearFallback=true
      if fsx and fsy then
        local dx,dy=sx-fsx,sy-fsy
        nearFallback=(dx*dx+dy*dy)<=((math.max(w,h)*.42)^2)
      end
      if onScreen and nearFallback then return sx,sy,exact==true end
    end
  end
  return fsx,fsy,false
end

local function screenSetColor(c,a,boost)
  local b=tonumber(boost) or 1
  love.graphics.setColor(clamp((c[1] or 1)*b,0,1),clamp((c[2] or 1)*b,0,1),clamp((c[3] or 1)*b,0,1),clamp(a or 1,0,1))
end

local function screenGlow(sx,sy,r,c,a)
  if not (sx and sy) then return end
  local g=love.graphics
  screenSetColor(c,(a or 1)*.20);g.circle("fill",sx,sy,r*1.8)
  screenSetColor(c,(a or 1)*.82,1.08);g.circle("fill",sx,sy,r)
  g.setColor(1,1,1,(a or 1)*.88);g.circle("fill",sx-r*.18,sy-r*.18,math.max(1,r*.34))
end

local function screenLine(points,width,c,a)
  if #points<4 then return end
  local g=love.graphics
  g.setLineWidth(width)
  screenSetColor(c,a)
  g.line(points)
end

local function rangedScreenEndpoints(context)
  local sx,sy,exact=screenAnchor(context,"player","mouth",2.7)
  local src=attachmentPoint(context,"player","mouth",2.7)
  local target=manualAimActorEndpoint(context,src)
  local tx,ty=project(context,target[1],target[2],target[3])
  return sx,sy,tx,ty,exact
end

local function projectileProgress(v)
  if not (state.projectileX and v and v.collisionStartX and v.collisionStartZ) then return 0 end
  local travel=len2(state.projectileX-v.collisionStartX,state.projectileZ-v.collisionStartZ)
  return clamp(travel/math.max(.001,tonumber(state.attackTargetDistance) or 1),0,1.08)
end

local function drawScreenEmber(context,v,alpha)
  local sx,sy,tx,ty=rangedScreenEndpoints(context)
  if not (sx and sy and tx and ty) then return false end
  local t=projectileProgress(v)
  local cx,cy=sx+(tx-sx)*t,sy+(ty-sy)*t
  screenGlow(sx,sy,10,v.color,.55*alpha)
  for i=1,7 do
    local tt=clamp(t-i*.035,0,1)
    local px,py=sx+(tx-sx)*tt,sy+(ty-sy)*tt
    local life=1-i/8
    screenGlow(px,py,4+6*life,v.color,.28*life*alpha)
  end
  screenGlow(cx,cy,14,v.color,alpha)
  love.graphics.setColor(1,.55,.08,.9*alpha);love.graphics.circle("fill",cx,cy,7)
  return true
end

local function drawScreenProjectile(context,v,alpha)
  local sx,sy,tx,ty=rangedScreenEndpoints(context)
  if not (sx and sy and tx and ty) then return false end
  local t=projectileProgress(v)
  local cx,cy=sx+(tx-sx)*t,sy+(ty-sy)*t
  screenGlow(sx,sy,7,v.color,.40*alpha)
  for i=1,5 do
    local tt=clamp(t-i*.045,0,1)
    screenGlow(sx+(tx-sx)*tt,sy+(ty-sy)*tt,4+i*.5,v.color,.18*alpha)
  end
  screenGlow(cx,cy,12,v.color,.95*alpha)
  return true
end

local function drawScreenStream(context,v,alpha,flame)
  local sx,sy,tx,ty=rangedScreenEndpoints(context)
  if not (sx and sy and tx and ty) then return false end
  local dx,dy=tx-sx,ty-sy
  local d=math.sqrt(dx*dx+dy*dy);if d<1 then d=1 end
  local nx,ny=-dy/d,dx/d
  local pts={}
  local phase=(state.attackAge or 0)*(flame and 38 or 25)+state.attackSerial*.73
  for i=0,20 do
    local t=i/20
    local amp=(flame and (3+10*t) or (2+5*t))*math.sin(math.pi*t)
    local wave=math.sin(phase+t*(flame and 18 or 12))*amp
    pts[#pts+1]=sx+dx*t+nx*wave
    pts[#pts+1]=sy+dy*t+ny*wave
  end
  screenLine(pts,flame and 24 or 16,v.color,.18*alpha)
  screenLine(pts,flame and 13 or 9,v.color,.78*alpha)
  screenLine(pts,flame and 4 or 3,flame and {1,.88,.38} or {1,1,1},.94*alpha)
  screenGlow(sx,sy,flame and 12 or 9,v.color,.70*alpha)
  if flame then
    for i=5,#pts-1,8 do screenGlow(pts[i],pts[i+1],6,v.color,.26*alpha) end
  end
  return true
end

local function drawScreenThunder(context,v,alpha)
  local sx,sy,tx,ty=rangedScreenEndpoints(context)
  if not (sx and sy and tx and ty) then return false end
  local dx,dy=tx-sx,ty-sy
  local d=math.sqrt(dx*dx+dy*dy);if d<1 then d=1 end
  local nx,ny=-dy/d,dx/d
  local pts={sx,sy}
  local phase=math.floor((state.attackAge or 0)*34)+state.attackSerial*7
  for i=1,11 do
    local t=i/12
    local jitter=(((i*37+phase*19)%13)-6)/6
    local off=jitter*(7+11*math.sin(math.pi*t))
    pts[#pts+1]=sx+dx*t+nx*off
    pts[#pts+1]=sy+dy*t+ny*off
  end
  pts[#pts+1]=tx;pts[#pts+1]=ty
  screenLine(pts,16,v.color,.22*alpha)
  screenLine(pts,8,v.color,.95*alpha)
  screenLine(pts,3,{1,1,1},alpha)
  screenGlow(sx,sy,9,v.color,.65*alpha)
  return true
end

local function drawScreenTargetLine(context,v,alpha)
  local sx,sy,tx,ty=rangedScreenEndpoints(context)
  if not (sx and sy and tx and ty) then return false end
  screenLine({sx,sy,tx,ty},15,v.color,.18*alpha)
  screenLine({sx,sy,tx,ty},8,v.color,.84*alpha)
  screenLine({sx,sy,tx,ty},3,{1,1,1},.78*alpha)
  screenGlow(sx,sy,8,v.color,.55*alpha)
  return true
end

local function drawScreenContact(context,v,alpha)
  local sx,sy=screenAnchor(context,"player","center",2.0)
  if not (sx and sy) then return false end
  local phase=clamp((state.attackAge-state.attackActiveStart)/math.max(.01,state.attackActiveEnd-state.attackActiveStart),0,1)
  local pts={}
  for i=0,10 do
    local t=i/10
    local a=(-1.1+2.2*phase)-.75+t*1.5
    local r=24+24*t
    pts[#pts+1]=sx+math.cos(a)*r;pts[#pts+1]=sy+math.sin(a)*r*.55
  end
  screenLine(pts,11,v.color,.18*alpha);screenLine(pts,6,v.color,.78*alpha);screenLine(pts,2,{1,1,1},.70*alpha)
  return true
end

local function drawScreenSelf(context,v,alpha)
  local sx,sy=screenAnchor(context,"player","center",2.2)
  if not (sx and sy) then return false end
  local t=clamp((state.attackAge or 0)/math.max(.01,state.attackDuration or .62),0,1)
  local pulse=.5+.5*math.sin((state.attackAge or 0)*24)
  local g=love.graphics
  for i=1,3 do
    local r=18+i*13+14*t
    screenSetColor(v.color,(.42-.09*i+.15*pulse)*alpha,1.08)
    g.setLineWidth(math.max(2,7-i*1.5))
    g.circle("line",sx,sy,r)
  end
  screenGlow(sx,sy,12+6*pulse,v.color,.50*alpha)
  return true
end

local function drawScreenRadial(context,v,alpha)
  local sx,sy=screenAnchor(context,"player","center",1.2)
  if not (sx and sy) then return false end
  local phase=clamp(((state.attackAge or 0)-(state.attackActiveStart or 0))
      /math.max(.01,(state.attackActiveEnd or .58)-(state.attackActiveStart or .18)),0,1)
  local g=love.graphics
  for i=0,2 do
    local q=clamp(phase-i*.13,0,1)
    local r=24+125*q
    screenSetColor(v.color,(.75-.18*i)*(1-q*.58)*alpha,1.04)
    g.setLineWidth(math.max(2,10-i*2))
    g.circle("line",sx,sy,r)
  end
  screenGlow(sx,sy,16,v.color,.38*alpha)
  return true
end

local function drawScreenImpact(context,p)
  local gy=tonumber(context and context.groundY) or tonumber(state.groundY) or 0
  local sx,sy
  if tonumber(p and p.x) and tonumber(p and p.z) then
    sx,sy=projectStage(context,p.x,gy+math.max(.12,tonumber(p.y) or 2.15),p.z)
  else
    sx,sy=screenAnchor(context,"enemy","center",2.4)
  end
  if not (sx and sy) then return false end
  local life=clamp(1-p.age/(p.duration or .4),0,1)
  local grow=18+48*(p.age/(p.duration or .4))
  local g=love.graphics
  screenSetColor(p.color,.20*life);g.circle("fill",sx,sy,grow*.72)
  screenSetColor(p.color,.92*life,1.10);g.setLineWidth(math.max(1,5*life));g.circle("line",sx,sy,grow)
  for i=0,9 do
    local a=(i/10)*math.pi*2+(p.serial or 0)*.37
    g.line(sx+math.cos(a)*grow*.35,sy+math.sin(a)*grow*.35,sx+math.cos(a)*grow*1.25,sy+math.sin(a)*grow*1.25)
  end
  return true
end

function R._drawScreenGroundAOE(context,v,alpha)
  local g=love.graphics
  local gy=tonumber(context and context.groundY) or tonumber(state.groundY) or 0
  local tx=tonumber(v and v.targetX) or tonumber(state.attackTargetX) or state.ex
  local tz=tonumber(v and v.targetZ) or tonumber(state.attackTargetZ) or state.ez
  local bx,by=projectStage(context,tx,gy+.12,tz)
  local txs,tys=projectStage(context,tx,gy+8.0,tz)
  if not (bx and by and txs and tys) then return false end
  local impact=clamp((tonumber(v and v.age) or tonumber(state.attackAge) or 0)/math.max(.01,tonumber(state.attackActiveStart) or .5),0,1)
  local cx,cy=txs+(bx-txs)*impact,tys+(by-tys)*impact
  local c=v and v.color or {1,.35,.18}
  screenSetColor(c,.22*alpha);g.setLineWidth(8);g.line(txs,tys,bx,by)
  screenSetColor(c,.90*alpha,1.08);g.setLineWidth(3);g.line(txs,tys,bx,by)
  screenGlow(cx,cy,12,c,.92*alpha)
  if impact>.90 then
    local q=(impact-.90)/.10
    screenSetColor(c,(1-q*.45)*alpha,1.08);g.setLineWidth(4);g.circle("line",bx,by,18+55*q)
  end
  return true
end


local POWDER_MOVES={
  SLEEP_POWDER={.78,.42,1.00},POISONPOWDER={.74,.25,.82},POISON_POWDER={.74,.25,.82},
  STUN_SPORE={1.00,.86,.18},SPORE={.74,.92,.62},COTTON_SPORE={.92,.94,1.00},
}
function R._fx.drawScreenPowder(context,v,alpha)
  local g=love.graphics;if not (g and type(g.circle)=="function") then return false end
  local gy=tonumber(context and context.groundY) or tonumber(state.groundY) or 0
  local sx,sz=tonumber(v.sourceX) or state.px,tonumber(v.sourceZ) or state.pz
  local tx,tz=tonumber(v.targetX) or state.ex,tonumber(v.targetZ) or state.ez
  local age=tonumber(v.age) or tonumber(state.attackAge) or 0
  local travel=clamp(age/math.max(.25,(tonumber(state.attackDuration) or .82)*.72),0,1)
  local c=POWDER_MOVES[v.name] or v.color or {.8,.55,1};local drew=false
  for i=1,18 do
    local phase=((i*37+(tonumber(v.serial) or 0)*13)%97)/97
    local along=clamp(travel*1.22-phase*.42,0,1)
    local x=sx+(tx-sx)*along+math.cos(age*5.4+i*1.73)*(.28+.035*i)
    local z=sz+(tz-sz)*along+math.sin(age*7.2+i*2.17)*(.24+.025*(i%5))
    local y=gy+1.25+math.sin(i*1.91+age*4.5)*.55+along
    local px,py=projectStage(context,x,y,z)
    if px and py then
      local r=3.5+(i%4)*1.8+4.5*along
      screenSetColor(c,(.18+.035*(i%5))*alpha,1.06);g.circle("fill",px,py,r)
      screenSetColor(c,.52*alpha,1.12);g.circle("line",px,py,r*.72);drew=true
    end
  end
  return drew
end

function R._fx.statusCodeForSide(context,side)
  local battle=context and context.battle;local b=battle and battle[side]
  if not b then return "",false end
  local code=nil
  if type(R._statusBadgeCode)=="function" then local ok,v=pcall(R._statusBadgeCode,battle,b,side);if ok then code=v end end
  if not code and b.mon then local s=b.mon.status;code=type(s)=="table" and (s.hudLabel or s.label or s.id or s.name) or s end
  return tostring(code or ""):upper(),battlerConfused(b)
end
function R._fx.drawPersistentStatusVFX(context)
  local g=love.graphics;if not (g and type(g.circle)=="function") then return false end
  local gy=tonumber(context and context.groundY) or tonumber(state.groundY) or 0
  local now=(love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
  local drew=false
  for _,side in ipairs({"player","enemy"}) do
    local code,confused=R._fx.statusCodeForSide(context,side)
    local x=side=="player" and state.px or state.ex
    local z=side=="player" and state.pz or state.ez
    local h=side=="player" and (tonumber(state.playerHeight) or 3.0) or (tonumber(state.enemyHeight) or 3.2)
    local top=gy+math.max(1.5,h*.78)
    if confused then
      for i=1,4 do local a=now*2.2+i*math.pi*.5;local px,py=projectStage(context,x+math.cos(a)*.75,top+.45,z+math.sin(a)*.75)
        if px then g.setColor(1,.83,.16,.78);g.circle("fill",px,py,4);drew=true end end
    end
    if code=="SLP" or code=="SLEEP" or code=="ASLEEP" then
      for i=1,3 do local a=now*1.25+i*2.1;local px,py=projectStage(context,x+math.cos(a)*(.28+i*.12),top+.35+i*.33,z+math.sin(a)*(.28+i*.12))
        if px then g.setColor(.72,.58,1,.58);g.circle("line",px,py,5+i*1.5);drew=true end end
    elseif code=="PAR" or code=="PARALYSIS" or code=="PARALYZED" then
      for i=1,4 do local a=now*7+i*1.57;local x1,y1=projectStage(context,x+math.cos(a)*.75,gy+.55+(i%2)*h*.35,z+math.sin(a)*.75);local x2,y2=projectStage(context,x+math.cos(a+.45)*1.05,gy+.9+(i%2)*h*.35,z+math.sin(a+.45)*1.05)
        if x1 and x2 then g.setColor(1,.9,.12,.82);g.setLineWidth(2);g.line(x1,y1,x2,y2);drew=true end end
    elseif code=="PSN" or code=="POISON" or code=="TOX" or code=="TOXIC" then
      for i=1,5 do local a=now*.9+i*1.31;local px,py=projectStage(context,x+math.cos(a)*.72,gy+.4+((now*.55+i*.19)%1)*h*.72,z+math.sin(a)*.72)
        if px then g.setColor(.67,.22,.82,.46);g.circle("fill",px,py,3.5+(i%3));drew=true end end
    elseif code=="BRN" or code=="BURN" or code=="BURNED" then
      for i=1,4 do local a=now*2+i*1.8;local px,py=projectStage(context,x+math.cos(a)*.55,gy+.35+(i%2)*.35,z+math.sin(a)*.55)
        if px then g.setColor(1,.28,.04,.52);g.circle("fill",px,py,5+(i%2)*3);g.setColor(1,.78,.12,.72);g.circle("fill",px,py-2,2.5);drew=true end end
    elseif code=="FRZ" or code=="FREEZE" or code=="FROZEN" then
      for i=1,5 do local a=i*1.256+now*.3;local px,py=projectStage(context,x+math.cos(a)*.72,gy+.55+(i%3)*h*.28,z+math.sin(a)*.72)
        if px then g.setColor(.55,.92,1,.62);g.setLineWidth(2);g.line(px-4,py,px+4,py);g.line(px,py-4,px,py+4);drew=true end end
    end
  end
  return drew
end

function R._fx.sideScreenEndpoints(context,v)
  local side=v.side or "player"
  local opp=side=="enemy" and "player" or "enemy"
  local sx,sy=screenAnchor(context,side,"mouth",2.35)
  local tx,ty
  if v.kind=="ground-aoe" and tonumber(v.targetX) and tonumber(v.targetZ) then
    tx,ty=projectStage(context,v.targetX,(tonumber(context and context.groundY) or 0)+.18,v.targetZ)
  else
    tx,ty=screenAnchor(context,opp,"center",2.35)
  end
  return sx,sy,tx,ty
end

function R._fx.sideProjectileScreen(context,v)
  local side=v.side or "player"
  local x,z=R._fx.sideProjectile(side)
  if x and z then return projectStage(context,x,(tonumber(context and context.groundY) or 0)+2.15,z) end
  return nil,nil
end

function R._fx.drawSideProjectile(context,v,alpha)
  local g=love.graphics;local px,py=R._fx.sideProjectileScreen(context,v)
  if not (g and px and py) then return false end
  for _,p in ipairs(v.trail or {}) do
    local tx,ty=projectStage(context,p.x,(tonumber(context and context.groundY) or 0)+2.15,p.z)
    if tx then local a=clamp(1-(tonumber(p.age) or 0)/.38,0,1);screenGlow(tx,ty,5+5*a,v.color,.25*a*alpha) end
  end
  local r=v.name=="EMBER" and 12 or 10
  screenGlow(px,py,r,v.color,.96*alpha);g.setColor(1,1,1,.80*alpha);g.circle("fill",px,py,math.max(2,r*.28))
  return true
end

function R._fx.drawSideLine(context,v,alpha,flame)
  local sx,sy,tx,ty=R._fx.sideScreenEndpoints(context,v);if not (sx and sy and tx and ty) then return false end
  local dx,dy=tx-sx,ty-sy;local d=math.max(1,math.sqrt(dx*dx+dy*dy));local nx,ny=-dy/d,dx/d
  local pts={};local age=R._fx.sideAttackAge(v.side);local phase=age*(flame and 31 or 19)+(tonumber(v.serial) or 0)*.73
  for i=0,20 do local t=i/20;local amp=(flame and (3+10*t) or (2+5*t))*math.sin(math.pi*t);local wave=math.sin(phase+t*(flame and 18 or 12))*amp;pts[#pts+1]=sx+dx*t+nx*wave;pts[#pts+1]=sy+dy*t+ny*wave end
  screenLine(pts,flame and 24 or 16,v.color,.18*alpha);screenLine(pts,flame and 13 or 9,v.color,.78*alpha);screenLine(pts,flame and 4 or 3,flame and {1,.88,.38} or {1,1,1},.94*alpha);screenGlow(sx,sy,flame and 12 or 9,v.color,.68*alpha)
  return true
end

function R._fx.drawSideThunder(context,v,alpha)
  local sx,sy,tx,ty=R._fx.sideScreenEndpoints(context,v);if not (sx and sy and tx and ty) then return false end
  local dx,dy=tx-sx,ty-sy;local d=math.max(1,math.sqrt(dx*dx+dy*dy));local nx,ny=-dy/d,dx/d
  local pts={sx,sy};local phase=math.floor(R._fx.sideAttackAge(v.side)*34)+(tonumber(v.serial) or 0)*7
  for i=1,11 do local t=i/12;local jitter=(((i*37+phase*19)%13)-6)/6;local off=jitter*(7+11*math.sin(math.pi*t));pts[#pts+1]=sx+dx*t+nx*off;pts[#pts+1]=sy+dy*t+ny*off end
  pts[#pts+1]=tx;pts[#pts+1]=ty;screenLine(pts,16,v.color,.22*alpha);screenLine(pts,8,v.color,.95*alpha);screenLine(pts,3,{1,1,1},alpha);return true
end

function R._fx.drawSideContact(context,v,alpha)
  local sx,sy=screenAnchor(context,v.side or "player","center",2.0);if not (sx and sy) then return false end
  local age=R._fx.sideAttackAge(v.side);local a0=R._fx.sideAttackActiveStart(v.side);local a1=R._fx.sideAttackActiveEnd(v.side);local phase=clamp((age-a0)/math.max(.01,a1-a0),0,1)
  local pts={};for i=0,10 do local t=i/10;local a=(-1.1+2.2*phase)-.75+t*1.5;local r=24+24*t;pts[#pts+1]=sx+math.cos(a)*r;pts[#pts+1]=sy+math.sin(a)*r*.55 end
  screenLine(pts,11,v.color,.18*alpha);screenLine(pts,6,v.color,.78*alpha);screenLine(pts,2,{1,1,1},.70*alpha);return true
end

function R._fx.drawSideSelf(context,v,alpha)
  local sx,sy=screenAnchor(context,v.side or "player","center",2.2);if not (sx and sy) then return false end
  local age=R._fx.sideAttackAge(v.side);local dur=R._fx.sideAttackDuration(v.side);local t=clamp(age/math.max(.01,dur),0,1);local pulse=.5+.5*math.sin(age*24);local g=love.graphics
  for i=1,3 do local r=18+i*13+14*t;screenSetColor(v.color,(.42-.09*i+.15*pulse)*alpha,1.08);g.setLineWidth(math.max(2,7-i*1.5));g.circle("line",sx,sy,r) end
  screenGlow(sx,sy,12+6*pulse,v.color,.50*alpha);return true
end

function R._fx.drawSideRadial(context,v,alpha)
  local sx,sy=screenAnchor(context,v.side or "player","center",1.2);if not (sx and sy) then return false end
  local age=R._fx.sideAttackAge(v.side);local a0=R._fx.sideAttackActiveStart(v.side);local a1=R._fx.sideAttackActiveEnd(v.side);local phase=clamp((age-a0)/math.max(.01,a1-a0),0,1);local g=love.graphics
  for i=0,2 do local q=clamp(phase-i*.13,0,1);local r=24+125*q;screenSetColor(v.color,(.75-.18*i)*(1-q*.58)*alpha,1.04);g.setLineWidth(math.max(2,10-i*2));g.circle("line",sx,sy,r) end
  return true
end

function R._fx.drawSideGround(context,v,alpha)
  local g=love.graphics;local gy=tonumber(context and context.groundY) or tonumber(state.groundY) or 0
  local tx,tz=tonumber(v.targetX),tonumber(v.targetZ);if not tx then local _,_,ox,oz=R._fx.sideWorld(v.side);tx,tz=ox,oz end
  local bx,by=projectStage(context,tx,gy+.10,tz);if not bx then return false end
  local age=R._fx.sideAttackAge(v.side);local a0=R._fx.sideAttackActiveStart(v.side);local q=clamp(age/math.max(.01,a0),0,1)
  for i=1,3 do screenSetColor(v.color,(.68-.12*i)*alpha,1.05);g.setLineWidth(3+i);g.circle("line",bx,by,15+i*16+q*28) end
  for i=1,7 do local a=(i/7)*math.pi*2+(tonumber(v.serial) or 0)*.31;local rr=18+((i*17)%25);local x=bx+math.cos(a)*rr;local y=by+math.sin(a)*rr*.35;screenSetColor(v.color,.62*alpha,1.05);g.rectangle("fill",x-3,y-3,6,6) end
  return true
end

function R._fx.drawSidePowder(context,v,alpha)
  local g=love.graphics;if not (g and type(g.circle)=="function") then return false end
  local gy=tonumber(context and context.groundY) or tonumber(state.groundY) or 0;local sx,sz,ox,oz=R._fx.sideWorld(v.side or "player");local tx,tz=tonumber(v.targetX) or ox,tonumber(v.targetZ) or oz
  local age=R._fx.sideAttackAge(v.side);local travel=clamp(age/math.max(.25,R._fx.sideAttackDuration(v.side)*.72),0,1);local c=v.color or {.8,.55,1};local drew=false
  for i=1,20 do local phase=((i*37+(tonumber(v.serial) or 0)*13)%97)/97;local along=clamp(travel*1.22-phase*.42,0,1);local x=sx+(tx-sx)*along+math.cos(age*5.4+i*1.73)*(.28+.035*i);local z=sz+(tz-sz)*along+math.sin(age*7.2+i*2.17)*(.24+.025*(i%5));local y=gy+1.25+math.sin(i*1.91+age*4.5)*.55+along;local px,py=projectStage(context,x,y,z);if px then local r=3.5+(i%4)*1.8+4.5*along;screenSetColor(c,(.18+.035*(i%5))*alpha,1.06);g.circle("fill",px,py,r);drew=true end end
  return drew
end

function R._fx.drawDrain(context,v,alpha)
  local sx,sy,tx,ty=R._fx.sideScreenEndpoints(context,v);if not (sx and sy and tx and ty) then return false end
  local g=love.graphics;local age=R._fx.sideAttackAge(v.side);local drew=false
  for i=1,10 do local phase=((age*1.7+i*.11)%1);local x=tx+(sx-tx)*phase+math.sin(i*2.3+age*8)*8;local y=ty+(sy-ty)*phase+math.cos(i*1.7+age*7)*5;screenSetColor({.35,1,.45},.52*alpha,1.06);g.circle("fill",x,y,3+(i%3));drew=true end
  screenLine({tx,ty,sx,sy},5,{.35,1,.45},.28*alpha);return drew
end

function R._fx.drawHeal(context,v,alpha)
  local g=love.graphics;local sx,sy=screenAnchor(context,v.side or "player","center",2.2);if not sx then return false end;local age=R._fx.sideAttackAge(v.side)
  for i=1,4 do local q=(age*.75+i*.19)%1;screenSetColor({.45,1,.62},(.65*(1-q))*alpha,1.08);g.setLineWidth(3);g.circle("line",sx,sy+30-70*q,12+22*q) end
  screenGlow(sx,sy,15,{.55,1,.72},.44*alpha);return true
end

function R._fx.drawBarrier(context,v,alpha)
  local g=love.graphics;local sx,sy=screenAnchor(context,v.side or "player","center",2.1);if not sx then return false end;local age=R._fx.sideAttackAge(v.side);local pulse=.5+.5*math.sin(age*11);local c=v.name=="REFLECT" and {.65,.75,1} or (v.name=="LIGHT_SCREEN" and {1,.92,.48} or {.70,1,1})
  screenSetColor(c,(.48+.18*pulse)*alpha,1.06);g.setLineWidth(5);g.circle("line",sx,sy,42+5*pulse);screenSetColor(c,.10*alpha);g.circle("fill",sx,sy,38+4*pulse);return true
end

function R._fx.drawSubstitute(context,v,alpha)
  local g=love.graphics;local sx,sy=screenAnchor(context,v.side or "player","center",2.0);if not sx then return false end;local age=R._fx.sideAttackAge(v.side);local pulse=1+math.sin(age*12)*.04
  screenSetColor({.55,1,.55},.22*alpha);g.circle("fill",sx,sy,34*pulse);screenSetColor({.65,1,.65},.75*alpha,1.04);g.setLineWidth(4);g.circle("line",sx,sy,34*pulse);g.circle("fill",sx-10,sy-5,3);g.circle("fill",sx+10,sy-5,3);return true
end

function R._fx.drawExplosion(context,v,alpha)
  local g=love.graphics;local sx,sy=screenAnchor(context,v.side or "player","center",1.8);if not sx then return false end;local q=clamp(R._fx.sideAttackAge(v.side)/math.max(.01,R._fx.sideAttackDuration(v.side)),0,1)
  for i=0,3 do local qq=clamp(q-i*.10,0,1);local r=16+155*qq;screenSetColor(v.color,(.86-.16*i)*(1-qq*.55)*alpha,1.10);g.setLineWidth(9-i*1.5);g.circle("line",sx,sy,r) end;screenGlow(sx,sy,28+32*q,{1,.86,.35},.78*alpha);return true
end

function R._fx.drawStatChange(context,v,alpha,up)
  local g=love.graphics;local targetSide=(v.side or "player");if not up and v.kind~="self" then targetSide=targetSide=="enemy" and "player" or "enemy" end;local sx,sy=screenAnchor(context,targetSide,"center",2.1);if not sx then return false end;local age=R._fx.sideAttackAge(v.side);local c=up and {.35,1,.55} or {1,.38,.36}
  for i=1,4 do local q=(age*1.2+i*.17)%1;local x=sx+(i-2.5)*13;local y=up and (sy+32-72*q) or (sy-32+72*q);screenSetColor(c,(.75*(1-q*.55))*alpha,1.08);local dir=up and -1 or 1;g.polygon("fill",x,y+dir*8,x-6,y-dir*2,x+6,y-dir*2) end;return true
end

function R._fx.drawCharge(context,v,alpha)
  local g=love.graphics;local sx,sy=screenAnchor(context,v.side or "player","center",2.1);if not sx then return false end;local age=R._fx.sideAttackAge(v.side);local dur=R._fx.sideAttackDuration(v.side);local q=clamp(age/math.max(.01,dur*.48),0,1)
  if q<1 then for i=1,6 do local a=age*5+i*math.pi/3;local r=40*(1-q*.55);screenGlow(sx+math.cos(a)*r,sy+math.sin(a)*r*.45,5+5*q,v.color,.55*alpha) end;screenGlow(sx,sy,10+18*q,v.color,.45*alpha);return true end
  return false
end

function R._fx.drawRecoil(context,v,alpha)
  local drew=false
  if v.kind=="projectile" then drew=R._fx.drawSideProjectile(context,v,alpha)
  elseif v.kind=="stream" or v.kind=="target-line" then drew=R._fx.drawSideLine(context,v,alpha,false)
  else drew=R._fx.drawSideContact(context,v,alpha) end
  local age=R._fx.sideAttackAge(v.side);local a1=R._fx.sideAttackActiveEnd(v.side)
  if age>=a1 then
    local sx,sy,tx,ty=R._fx.sideScreenEndpoints(context,v)
    if sx and tx then
      local q=clamp((age-a1)/math.max(.08,R._fx.sideAttackDuration(v.side)-a1),0,1)
      local rx=tx+(sx-tx)*q;local ry=ty+(sy-ty)*q
      screenGlow(rx,ry,7,{1,.78,.42},.62*alpha)
      screenLine({tx,ty,rx,ry},4,{1,.55,.25},.42*alpha)
      drew=true
    end
  end
  return drew
end

function R._fx.drawUnique(context,v,alpha)
  local g=love.graphics;local n=v.name;local sx,sy,tx,ty=R._fx.sideScreenEndpoints(context,v);if not sx then return false end;local age=R._fx.sideAttackAge(v.side)
  if n=="TELEPORT" then for i=1,4 do screenSetColor(v.color,.55*alpha);g.setLineWidth(3);g.circle("line",sx,sy,15+i*11+age*22) end;return true end
  if n=="METRONOME" then g.setColor(1,1,.45,.9*alpha);g.print("?",sx-4,sy-48-math.sin(age*8)*8);g.print("♪",sx+20,sy-30);return true end
  if n=="TRANSFORM" or n=="MIMIC" or n:find("CONVERSION",1,true) then for i=1,3 do local a=age*3+i*2.09;screenGlow(sx+math.cos(a)*35,sy+math.sin(a)*18,7,v.color,.48*alpha) end;return true end
  if n=="NIGHT_SHADE" or n=="PSYWAVE" then if tx then for i=0,3 do local q=((age*1.5+i*.22)%1);local x=sx+(tx-sx)*q;local y=sy+(ty-sy)*q;screenSetColor({.55,.30,.82},.62*alpha);g.setLineWidth(3);g.circle("line",x,y,8+22*q) end end;return true end
  if n=="GUILLOTINE" or n=="HORN_DRILL" or n=="FISSURE" then if tx then screenLine({tx-32,ty-32,tx+32,ty+32},9,{1,.25,.18},.75*alpha);screenLine({tx+32,ty-32,tx-32,ty+32},5,{1,1,1},.75*alpha) end;return true end
  if n=="COUNTER" or n=="MIRROR_COAT" or n=="BIDE" then screenSetColor(v.color,.65*alpha,1.08);g.setLineWidth(5);g.circle("line",sx,sy,30+12*math.sin(age*9));return true end
  if n=="SEISMIC_TOSS" then if tx then local mx,my=(sx+tx)*.5,(sy+ty)*.5-55;screenLine({sx,sy,mx,my,tx,ty},7,v.color,.72*alpha) end;return true end
  return false
end

function R._fx.drawMulti(context,v,alpha)
  local drew=(v.kind=="projectile" and R._fx.drawSideProjectile(context,v,alpha)) or R._fx.drawSideContact(context,v,alpha)
  local _,_,tx,ty=R._fx.sideScreenEndpoints(context,v);if tx then local beat=math.floor(R._fx.sideAttackAge(v.side)*15);for i=0,2 do local a=(beat+i)*2.2;screenLine({tx+math.cos(a)*8,ty+math.sin(a)*8,tx+math.cos(a)*28,ty+math.sin(a)*28},3,v.color,.55*alpha) end end;return drew or tx~=nil
end

function R._fx.drawSideVFX(context,v,alpha)
  if not v then return false end
  local f=v.family
  if f=="powder" then return R._fx.drawSidePowder(context,v,alpha) end
  if f=="drain" then return R._fx.drawDrain(context,v,alpha) end
  if f=="heal" then return R._fx.drawHeal(context,v,alpha) end
  if f=="barrier" then return R._fx.drawBarrier(context,v,alpha) end
  if f=="substitute" then return R._fx.drawSubstitute(context,v,alpha) end
  if f=="explosion" then return R._fx.drawExplosion(context,v,alpha) end
  if f=="ground" then return R._fx.drawSideGround(context,v,alpha) end
  if f=="stat-up" then return R._fx.drawStatChange(context,v,alpha,true) end
  if f=="stat-down" then return R._fx.drawStatChange(context,v,alpha,false) end
  if f=="unique" then return R._fx.drawUnique(context,v,alpha) end
  if f=="multi" then return R._fx.drawMulti(context,v,alpha) end
  if f=="recoil" then return R._fx.drawRecoil(context,v,alpha) end
  if f=="charge" then if R._fx.drawCharge(context,v,alpha) then return true end end
  if v.kind=="projectile" then return R._fx.drawSideProjectile(context,v,alpha) end
  if v.kind=="stream" or v.kind=="cone" then return R._fx.drawSideLine(context,v,alpha,v.name=="FLAMETHROWER") end
  if v.kind=="target-line" then if v.name=="THUNDERBOLT" or v.type=="ELECTRIC" then return R._fx.drawSideThunder(context,v,alpha) end;return R._fx.drawSideLine(context,v,alpha,false) end
  if v.kind=="ground-aoe" then return R._fx.drawSideGround(context,v,alpha) end
  if v.kind=="self" then return R._fx.drawSideSelf(context,v,alpha) end
  if v.kind=="radial" then return R._fx.drawSideRadial(context,v,alpha) end
  return R._fx.drawSideContact(context,v,alpha)
end

function R._fx.drawPersistentMoveVFX(context)
  local g=love.graphics;if not (g and type(g.circle)=="function") then return false end;local drew=false
  for _,p in ipairs(state.persistentMoveVfx or {}) do
    local sx,sy=screenAnchor(context,p.targetSide or p.side,"center",2.0)
    if sx then
      local life=clamp(1-(tonumber(p.age) or 0)/math.max(.1,tonumber(p.duration) or 5),0,1);local n=p.name;local age=tonumber(p.age) or 0
      if n=="LEECH_SEED" then for i=1,5 do local a=age*1.4+i*1.256;screenGlow(sx+math.cos(a)*28,sy+math.sin(a)*15,5,{.35,1,.35},.50*life) end
      elseif n=="FIRE_SPIN" then for i=1,8 do local a=age*3+i*.785;screenGlow(sx+math.cos(a)*38,sy+math.sin(a)*14,7,{1,.30,.05},.55*life) end
      elseif n=="WHIRLPOOL" or n=="CLAMP" then for i=1,3 do screenSetColor({.25,.65,1},.52*life);g.setLineWidth(3);g.ellipse("line",sx,sy+18,i*18,6+i*3) end
      elseif n=="WRAP" or n=="BIND" or n=="SAND_TOMB" then screenSetColor(p.color,.48*life);g.setLineWidth(4);for i=1,3 do g.ellipse("line",sx,sy+12,i*16,7+i*4) end
      elseif n=="SUBSTITUTE" then screenSetColor({.55,1,.55},.16*life);g.circle("fill",sx,sy,36);screenSetColor({.65,1,.65},.62*life);g.setLineWidth(4);g.circle("line",sx,sy,36)
      else local c=(n=="REFLECT" and {.65,.75,1}) or (n=="LIGHT_SCREEN" and {1,.92,.48}) or {.65,1,1};screenSetColor(c,.42*life);g.setLineWidth(4);g.circle("line",sx,sy,43+4*math.sin(age*4)) end
      drew=true
    end
  end
  return drew
end

local function drawScreenSimplifiedVFX(context,gy)
  local drew=false
  for _,v in ipairs({state.vfx,state.enemyVfx}) do
    if v then
      local age=R._fx.sideAttackAge(v.side);local active=age>0;local alpha=active and 1 or clamp(1-(tonumber(v.fade) or 0)/.24,0,1)
      if active or alpha>0 then if R._fx.drawSideVFX(context,v,alpha) then drew=true end end
    end
  end
  for _,p in ipairs(state.impacts or {}) do if drawScreenImpact(context,p) then drew=true end end
  if R._fx.drawPersistentMoveVFX(context) then drew=true end
  return drew
end

local function drawSimplifiedVFX(context,gy)
  local v=state.vfx
  if v and (state.attackAge>0 or (v.fade or 0)<.20) then
    local a=state.attackAge>0 and 1 or clamp(1-(v.fade or 0)/.20,0,1)
    local old=v.color
    if a<1 then v.color={old[1],old[2],old[3]} end
    if v.kind=="projectile" then
      if v.name=="EMBER" then drawEmber(context,v,gy) else drawGenericProjectile(context,v,gy) end
    elseif v.kind=="stream" then
      if v.name=="FLAMETHROWER" then drawFlameStream(context,v,gy) else drawGenericStream(context,v,gy) end
    elseif v.kind=="target-line" then
      if v.name=="THUNDERBOLT" then drawThunderbolt(context,v,gy) else drawGenericTargetLine(context,v,gy) end
    elseif v.kind=="contact" then
      drawContactVFX(context,v,gy)
    end
  end
  for _,p in ipairs(state.impacts or {}) do drawImpact(context,p) end
end

-- Persistent renderer probe for the v0.5.3 VFX-path diagnostic build.
-- It intentionally uses the SAME immediate-mode love.graphics screen-space
-- primitives as Ember/Flamethrower/Thunderbolt below. If this marker is visible,
-- the final Arena realtime presentation pass is unquestionably executing.
local function drawVFXRendererProbe(context)
  local g=love.graphics
  local w,h=renderSize(context)
  local pw,ph=math.min(300,math.max(220,w*.24)),74
  local x,y=math.max(12,w-pw-18),18
  g.setBlendMode("alpha","alphamultiply")
  g.setColor(1,0,1,.94)
  g.rectangle("fill",x,y,pw,ph)
  g.setColor(0,1,1,1)
  g.setLineWidth(6)
  g.rectangle("line",x+3,y+3,pw-6,ph-6)
  g.line(x+12,y+12,x+44,y+44)
  g.line(x+44,y+12,x+12,y+44)
  g.setColor(0,0,0,1)
  g.print("VFX RENDER PATH OK",x+58,y+16)
  g.print("Arena final overlay / love.graphics",x+58,y+36)
end

function R._drawTargetingTelegraphs(context,gy)
  local g=love.graphics
  if not (g and type(g.polygon)=="function") then return end
  gy=tonumber(gy) or tonumber(state.groundY) or 0

  local function projectPoly(points)
    local out={}
    for _,q in ipairs(points) do
      local x,y=projectStage(context,q[1],gy+.055,q[2])
      if not x then return nil end
      out[#out+1]=x;out[#out+1]=y
    end
    return out
  end
  local function circle(cx,cz,r,fillA,lineA)
    r=math.max(.15,tonumber(r) or 1)
    local pts={}
    for i=0,32 do local a=(i/32)*math.pi*2;pts[#pts+1]={cx+math.cos(a)*r,cz+math.sin(a)*r} end
    local poly=projectPoly(pts)
    if poly and #poly>=6 then
      g.setColor(1,.08,.06,fillA or .10);g.polygon("fill",poly)
      g.setColor(1,.20,.12,lineA or .78);g.setLineWidth(2);g.line(poly)
    end
  end
  local function lane(ox,oz,dx,dz,range,halfW,fillA)
    dx,dz=normalize2(dx,dz);if dx==0 and dz==0 then dx,dz=0,-1 end
    local rx,rz=-dz,dx
    local start=math.max(.1,(tonumber(state.playerRadius) or 1.5)*.45)
    local x0,z0=ox+dx*start,oz+dz*start
    local x1,z1=ox+dx*math.max(start+.1,tonumber(range) or 1),oz+dz*math.max(start+.1,tonumber(range) or 1)
    local w=math.max(.25,tonumber(halfW) or 1.1)
    local poly=projectPoly({{x0+rx*w,z0+rz*w},{x1+rx*w,z1+rz*w},{x1-rx*w,z1-rz*w},{x0-rx*w,z0-rz*w}})
    if poly then
      g.setColor(1,.07,.05,fillA or .13);g.polygon("fill",poly)
      g.setColor(1,.18,.10,.82);g.setLineWidth(2);g.line(poly[1],poly[2],poly[3],poly[4],poly[5],poly[6],poly[7],poly[8],poly[1],poly[2])
    end
  end
  local function cone(ox,oz,dx,dz,range,halfAngle,fillA)
    dx,dz=normalize2(dx,dz);if dx==0 and dz==0 then dx,dz=0,-1 end
    local base=atan2(dx,dz)
    local pts={{ox,oz}}
    for i=0,20 do
      local a=base-halfAngle+(i/20)*(halfAngle*2)
      pts[#pts+1]={ox+math.sin(a)*range,oz+math.cos(a)*range}
    end
    local poly=projectPoly(pts)
    if poly then
      g.setColor(1,.07,.05,fillA or .12);g.polygon("fill",poly)
      g.setColor(1,.18,.10,.82);g.setLineWidth(2);g.line(poly)
    end
  end

  -- Player preview while selecting/aiming. Once LMB is pressed, draw the same
  -- shape from the locked attack snapshot until the damage frame.
  local cls=state.targetPreviewClass
  local committed=(tonumber(state.attackAge) or 0)>0 and (tonumber(state.attackAge) or 0)<(tonumber(state.attackActiveStart) or 0)
  if committed then cls=state.attackProfileClass end
  if committed and cls then
    if cls=="GROUND_AOE" or cls=="TRAP_ZONE" then
      circle(state.px,state.pz,state.attackRange or 18,.015,.24)
      circle(state.attackTargetX or state.px,state.attackTargetZ or state.pz,state.attackAOERadius or 4,.14,.94)
    elseif cls=="LINE" then lane(state.px,state.pz,state.attackDirX,state.attackDirZ,state.attackRange or 16,state.projectileRadius or 1.25,.14)
    elseif cls=="CONE" then cone(state.px,state.pz,state.attackDirX,state.attackDirZ,state.attackRange or 10,state.attackConeHalfAngle or math.rad(22.5),.13)
    elseif cls=="SELF_AOE" then circle(state.px,state.pz,state.attackRange or 6,.12,.88)
    elseif cls=="DASH" then lane(state.px,state.pz,state.attackDirX,state.attackDirZ,state.attackRange or 4.5,1.25,.11) end
  elseif state.targetPreviewActive and cls then
    if cls=="GROUND_AOE" or cls=="TRAP_ZONE" then
      circle(state.px,state.pz,state.targetPreviewRange or 18,.012,.20)
      circle(state.targetPreviewX or state.px,state.targetPreviewZ or state.pz,state.targetPreviewRadius or 4,.13,.94)
    elseif cls=="LINE" then lane(state.px,state.pz,state.targetPreviewDirX,state.targetPreviewDirZ,state.targetPreviewRange or 16,math.max(.4,(state.targetPreviewWidth or 2.5)*.5),.12)
    elseif cls=="CONE" then cone(state.px,state.pz,state.targetPreviewDirX,state.targetPreviewDirZ,state.targetPreviewRange or 10,math.rad(math.max(5,state.targetPreviewAngle or 45))*.5,.12)
    elseif cls=="SELF_AOE" then circle(state.px,state.pz,state.targetPreviewRadius or 6,.10,.82)
    elseif cls=="DASH" then lane(state.px,state.pz,state.targetPreviewDirX,state.targetPreviewDirZ,state.targetPreviewRange or 4.5,math.max(.4,(state.targetPreviewWidth or 2.5)*.5),.10) end
  end

  -- Enemy warning telegraph uses the same locked geometry during wind-up.
  local ecls=state.enemyAttackProfileClass
  if ecls and (tonumber(state.enemyAttackAge) or 0)>0 and (tonumber(state.enemyAttackAge) or 0)<(tonumber(state.enemyAttackActiveStart) or 0) then
    if ecls=="GROUND_AOE" or ecls=="TRAP_ZONE" then
      circle(state.enemyAttackTargetX or state.ex,state.enemyAttackTargetZ or state.ez,state.enemyAttackAOERadius or 4,.18,.98)
    elseif ecls=="LINE" then lane(state.ex,state.ez,state.enemyAttackDirX,state.enemyAttackDirZ,state.enemyAttackRange or 16,state.enemyAttackRadius or 1.25,.18)
    elseif ecls=="CONE" then cone(state.ex,state.ez,state.enemyAttackDirX,state.enemyAttackDirZ,state.enemyAttackRange or 10,state.enemyAttackConeHalfAngle or math.rad(22.5),.18)
    elseif ecls=="SELF_AOE" then circle(state.ex,state.ez,state.enemyAttackRange or 6,.16,.96)
    elseif ecls=="DASH" then lane(state.ex,state.ez,state.enemyAttackDirX,state.enemyAttackDirZ,state.enemyAttackRange or 4.5,1.25,.16) end
  end
end

function R._shooterReticleScreenPoint(context)
  local w,h=renderSize(context)
  local gy=tonumber(context and context.groundY) or tonumber(state.groundY) or 0
  local wx,wz,wy
  if state.reticleOnTarget then
    wx,wz=state.ex,state.ez
    wy=gy+math.max(1.0,(tonumber(state.enemyHeight) or 3.2)*.52)
  else
    wx=tonumber(state.reticleWorldX) or state.px or 0
    wz=tonumber(state.reticleWorldZ) or state.pz or 0
    wy=gy+.16
  end
  local sx,sy=projectStage(context,wx,wy,wz)
  if not (sx and sy) then return w*.5,h*.42 end
  if not state.reticleOnTarget then
    local playerY=gy+math.max(.9,(tonumber(state.playerHeight) or 3.0)*.46)
    local psx,psy=projectStage(context,state.px or 0,playerY,state.pz or 0)
    if psx and psy then
      local erx,ery=projectStage(context,(state.px or 0)+(tonumber(state.playerRadius) or 1.75),playerY,state.pz or 0)
      local bodyPx=46
      if erx and ery then bodyPx=math.max(bodyPx,math.sqrt((erx-psx)^2+(ery-psy)^2)*1.45) end
      local qdx,qdy=sx-psx,sy-psy
      if qdx*qdx+qdy*qdy<bodyPx*bodyPx then
        local ax,az=normalize2(tonumber(state.reticleAimX) or 0,tonumber(state.reticleAimZ) or -1)
        local d=math.max(tonumber(state.reticleDisplayDistance) or 4,math.max(3.5,(tonumber(state.playerRadius) or 1.75)*1.8))
        for _=1,8 do
          d=d*1.32+1.0
          local x=(state.px or 0)+ax*d
          local z=(state.pz or 0)+az*d
          local x2,y2=projectStage(context,x,gy+.16,z)
          if x2 and y2 then
            sx,sy=x2,y2;wx,wz=x,z
            local ddx,ddy=sx-psx,sy-psy
            if ddx*ddx+ddy*ddy>=bodyPx*bodyPx then break end
          end
        end
      end
    end
  end
  state.reticleWorldX,state.reticleWorldZ=wx,wz
  local marginX=math.max(18,w*.035)
  local top=math.max(18,h*.045)
  local bottom=h*.80
  sx=clamp(sx,marginX,w-marginX)
  sy=clamp(sy,top,bottom)
  return sx,sy
end

local function drawShooterReticle(context)
  local cls=state.targetPreviewClass
  if state.targetPreviewActive and (cls=="GROUND_AOE" or cls=="TRAP_ZONE" or cls=="SELF_AOE") and state.attackAge<=0 then return end
  local g=love.graphics
  local cx,cy=R._shooterReticleScreenPoint(context)
  local ready=state.attackAge<=0 and state.attackCooldown<=0 and not state.attackMotionLock and not R._playerAttackSuppressed()
  if state.reticleOnTarget then g.setColor(1.0,.28,.18,.98)
  elseif state.reticleAssistActive then g.setColor(1.0,.72,.16,.96)
  elseif ready then g.setColor(1,1,1,.90)
  else g.setColor(.62,.66,.70,.72) end
  g.setLineWidth(2)
  local gap,len=state.reticleAssistActive and 6 or 7,state.reticleAssistActive and 11 or 9
  g.line(cx-gap-len,cy,cx-gap,cy);g.line(cx+gap,cy,cx+gap+len,cy)
  g.line(cx,cy-gap-len,cx,cy-gap);g.line(cx,cy+gap,cx,cy+gap+len)
  g.circle("line",cx,cy,4)
  if state.reticleOnTarget then
    g.setColor(1,.68,.20,.90);g.circle("line",cx,cy,10)
  elseif state.reticleAssistActive then
    g.setColor(1,.72,.16,.72);g.circle("line",cx,cy,12)
  end
  if state.cameraLockHeld then
    g.setColor(.35,.85,1,.55);g.circle("line",cx,cy,16)
  end
end

local function drawFlightStaminaHUD(context)
  if not state.flightCapable then return end
  local maxS=math.max(.01,tonumber(state.flightStaminaMax) or FLIGHT_STAMINA_MAX)
  local cur=clamp(tonumber(state.flightStamina) or 0,0,maxS)
  -- Keep the normal grounded/full state completely clean. The meter only
  -- appears while flight is relevant: airborne, exhausted, cooling down or
  -- recharging.
  local active=(tonumber(state.py) or 0)>.001 or state.flightMode
    or state.flightExhausted or state.flightRechargeLock>0 or cur<maxS-.001
  if not active then return end
  local g=love and love.graphics
  if not (g and type(g.rectangle)=="function") then return end
  local w,h=renderSize(context)
  local scale=clamp(math.min(w/1280,h/720),.82,1.30)
  local bw,bh=math.floor(164*scale),math.floor(7*scale)
  local x,y=math.floor(w*.5-bw*.5),math.floor(h-196*scale)
  local pct=cur/maxS
  g.setColor(0,0,0,.55);g.rectangle("fill",x-2*scale,y-2*scale,bw+4*scale,bh+4*scale,3*scale,3*scale)
  g.setColor(.20,.22,.25,.90);g.rectangle("fill",x,y,bw,bh,3*scale,3*scale)
  if state.flightExhausted then g.setColor(1,.34,.18,.96)
  elseif pct<.30 then g.setColor(1,.72,.18,.96)
  else g.setColor(.40,.82,1,.96) end
  g.rectangle("fill",x,y,bw*pct,bh,3*scale,3*scale)
  g.setColor(1,1,1,.76)
  local label
  if state.flightRechargeLock>0 then label="FLIGHT  "..string.format("%.1fs",state.flightRechargeLock)
  elseif state.flightExhausted and (tonumber(state.py) or 0)<=.001 and cur<maxS then label="FLIGHT  RECHARGE"
  else label="FLIGHT  "..string.format("%.1f",cur) end
  g.printf(label,x,y-15*scale,bw,"center")
end

local hudFontCache={}
local function hudFont(sz)
  local g=love and love.graphics
  if not (g and type(g.newFont)=="function") then return g and g.getFont and g.getFont() or nil end
  sz=math.max(10,math.floor((tonumber(sz) or 14)+.5))
  if hudFontCache[sz] then return hudFontCache[sz] end
  local ok,f=pcall(g.newFont,sz)
  if ok and f then
    if f.setFilter then pcall(f.setFilter,f,"linear","linear") end
    hudFontCache[sz]=f
    return f
  end
  return g.getFont and g.getFont() or nil
end
local function battleTopIsActive(context)
  local game=context and context.game
  local stack=game and game.stack
  local states=stack and stack.states
  if type(states)~="table" then return true end
  return states[#states]==(context and context.battle)
end
local function hpColor(pct)
  if pct<=.20 then return 1.0,.24,.20
  elseif pct<=.50 then return 1.0,.72,.18
  else return .22,.86,.34 end
end
function R._stageMultiplierText(stage)
  stage=math.max(-6,math.min(6,math.floor(tonumber(stage) or 0)))
  local t={[-6]="0.25x",[-5]="0.28x",[-4]="0.33x",[-3]="0.40x",[-2]="0.50x",[-1]="0.66x",
    [0]="1x",[1]="1.5x",[2]="2x",[3]="2.5x",[4]="3x",[5]="3.5x",[6]="4x"}
  return t[stage] or "1x"
end

function R._effectBadges(battle,battler,side)
  local out={}
  local st=R._statusBadgeCode(battle,battler,side)
  if st then out[#out+1]={text=st,kind="major"} end
  if battlerConfused(battler) then out[#out+1]={text="CNF",kind="volatile"} end
  if type(battler)=="table" then
    if battler.reflect then out[#out+1]={text="REFLECT",kind="buff"} end
    if battler.lightScreen then out[#out+1]={text="LIGHT SCR",kind="buff"} end
    if battler.mist then out[#out+1]={text="MIST",kind="buff"} end
    if battler.focusEnergy then out[#out+1]={text="FOCUS",kind="buff"} end
    if (tonumber(battler.substituteHP) or 0)>0 then out[#out+1]={text="SUB",kind="buff"} end
    if battler.leechSeeded then out[#out+1]={text="SEEDED",kind="debuff"} end
    if battler.xAccuracy then out[#out+1]={text="X ACC",kind="buff"} end
    local stages=type(battler.stages)=="table" and battler.stages or nil
    if stages then
      local order={{"accuracy","ACC"},{"evasion","EVA"},{"attack","ATK"},{"defense","DEF"},{"speed","SPE"},{"special","SPC"}}
      for _,row in ipairs(order) do
        local v=tonumber(stages[row[1]]) or 0
        if v~=0 then
          out[#out+1]={text=row[2].." "..R._stageMultiplierText(v),kind=v>0 and "stageup" or "stagedown"}
        end
      end
    end
  end
  return out
end

local function drawMinimalBattlerHUD(context)
  local battle=context and context.battle
  if not (battle and battle.player and battle.enemy) then return end
  local g=love.graphics
  local w,h=renderSize(context)
  local scale=clamp(math.min(w/1280,h/720),.82,1.35)
  local panelW,panelH=math.floor(318*scale),math.floor(72*scale)
  local margin=math.floor(24*scale)
  local y=h-panelH-margin
  local function drawOne(battler,x,rightAlign,side)
    local mon=battler and battler.mon
    if not mon then return end
    local hp=math.max(0,tonumber(mon.hp) or 0)
    local maxHp=math.max(1,tonumber(mon.stats and mon.stats.hp) or 1)
    local pct=clamp(hp/maxHp,0,1)
    g.setColor(0,0,0,.56);g.rectangle("fill",x,y,panelW,panelH,8*scale,8*scale)
    g.setColor(.08,.09,.10,.86);g.rectangle("fill",x+2*scale,y+2*scale,panelW-4*scale,panelH-4*scale,7*scale,7*scale)
    local f=hudFont(17*scale);if f then g.setFont(f) end
    g.setColor(1,1,1,.96)
    local name=tostring(battler.name or (mon and mon.species) or "POKEMON")
    local nameW=(g.getFont and g.getFont() and g.getFont():getWidth(name)) or (#name*9*scale)
    local nameX=rightAlign and (x+panelW-12*scale-nameW) or (x+12*scale)
    g.print(name,nameX,y+6*scale)

    local badges=R._effectBadges(battle,battler,side)
    local badgeFont=hudFont(9.5*scale);if badgeFont then g.setFont(badgeFont) end
    local gap=3*scale
    local bx=rightAlign and (nameX-6*scale) or (nameX+nameW+6*scale)
    local by=y+6*scale
    local rowH=17*scale
    for i,badge in ipairs(badges) do
      if i>10 then break end
      local code=tostring(badge.text or "")
      local tw=(g.getFont and g.getFont() and g.getFont():getWidth(code)) or (#code*5*scale)
      local bwid=math.max(24*scale,tw+9*scale)
      if rightAlign then
        if bx-bwid<x+10*scale then bx=x+panelW-12*scale;by=by+rowH end
        bx=bx-bwid
      else
        if bx+bwid>x+panelW-10*scale then bx=x+12*scale;by=by+rowH end
      end
      if by>y+39*scale then break end
      local r,cg,bb=.38,.42,.48
      if badge.kind=="stageup" then r,cg,bb=.22,.66,.40
      elseif badge.kind=="stagedown" then r,cg,bb=.96,.40,.20
      elseif badge.kind=="buff" then r,cg,bb=.25,.55,.78
      elseif badge.kind=="debuff" then r,cg,bb=.74,.34,.25
      elseif code=="SLP" then r,cg,bb=.42,.55,.72
      elseif code=="PAR" then r,cg,bb=.95,.76,.18
      elseif code=="PSN" then r,cg,bb=.68,.32,.82
      elseif code=="TOX" then r,cg,bb=.52,.18,.68
      elseif code=="BRN" then r,cg,bb=.92,.34,.18
      elseif code=="FRZ" then r,cg,bb=.28,.74,.90
      elseif code=="CNF" then r,cg,bb=.88,.36,.66 end
      g.setColor(r,cg,bb,.96);g.rectangle("fill",bx,by,bwid,15*scale,4*scale,4*scale)
      g.setColor(1,1,1,.23);g.rectangle("line",bx+.5*scale,by+.5*scale,bwid-1*scale,15*scale-1*scale,4*scale,4*scale)
      g.setColor(1,1,1,.98);g.printf(code,bx,by+2.2*scale,bwid,"center")
      if rightAlign then bx=bx-gap else bx=bx+bwid+gap end
    end
    local hpX=x+12*scale;local hpY=y+panelH-16*scale;local hpW=panelW-24*scale;local hpH=9*scale
    g.setColor(.22,.24,.26,.95);g.rectangle("fill",hpX,hpY,hpW,hpH,4*scale,4*scale)
    local r,gg,bb=hpColor(pct);g.setColor(r,gg,bb,.98);g.rectangle("fill",hpX,hpY,hpW*pct,hpH,4*scale,4*scale)
  end
  drawOne(battle.enemy,margin,false,"enemy")
  drawOne(battle.player,w-margin-panelW,true,"player")
end

local function commandMenuLayout(context)
  local w,h=renderSize(context)
  local scale=clamp(math.min(w/1280,h/720),.82,1.30)
  local bw,bh,gap=math.floor(150*scale),math.floor(38*scale),math.floor(8*scale)
  local x=w-bw-math.floor(18*scale)
  local y=math.floor(h*.30)
  local buttons={}
  local labels={"ATTACK","ITEM","POKEMON","RUN"}
  for i,label in ipairs(labels) do
    buttons[i]={x=x,y=y+(i-1)*(bh+gap),w=bw,h=bh,label=label}
  end
  local moves={}
  if state.commandMovesOpen then
    local mw=math.floor(220*scale)
    local mx=x-mw-gap
    for i=1,4 do moves[i]={x=mx,y=y+(i-1)*(bh+gap),w=mw,h=bh,slot=i} end
  end
  return buttons,moves,scale
end
local function pointInRect(x,y,r)
  return r and x>=r.x and x<=r.x+r.w and y>=r.y and y<=r.y+r.h
end
local function currentMoveLabel(context,slot)
  local battle=context and context.battle
  local inst=battle and battle.player and battle.player.curMoves and battle.player.curMoves[slot]
  if not inst then return "-",nil,nil end
  local def=battle.data and battle.data.moves and (battle.data.moves[inst.id] or battle.data.moves[tonumber(inst.id)])
  local name=(def and def.name) or tostring(inst.id or "-")
  return tostring(name),tonumber(inst.pp),def and tonumber(def.pp)
end
R._MOVE_TILE_COLORS={
  {1.00,.14,.12},{1.00,.84,.08},{.12,.72,.25},{.08,.58,.90}
}
function R._attackGridLayout(context)
  local w,h=renderSize(context)
  local scale=clamp(math.min(w/1280,h/720),.82,1.30)
  local tw,th,gap=math.floor(150*scale),math.floor(58*scale),math.floor(8*scale)
  local totalW=tw*2+gap
  local totalH=th*2+gap
  local x=math.floor(w*.5-totalW*.5)
  local y=math.floor(h-totalH-22*scale)
  return {
    {x=x,y=y,w=tw,h=th,slot=1},{x=x+tw+gap,y=y,w=tw,h=th,slot=2},
    {x=x,y=y+th+gap,w=tw,h=th,slot=3},{x=x+tw+gap,y=y+th+gap,w=tw,h=th,slot=4},
  },scale
end
function R._selectRealtimeSlot(context,slot)
  slot=math.max(1,math.min(4,math.floor(tonumber(slot) or 1)))
  state.selectedMoveSlot=slot
  local inst,xdId,canonical,vfx=mapLiveMove(context,slot)
  state.selectedMoveId=inst and inst.id or nil
  state.selectedMoveXdId=xdId
  state.selectedMoveCanonical=canonical
  state.selectedMoveHasVFX=vfx~=nil
  return inst,xdId,canonical,vfx
end
function R._cycleSelectedMove(context)
  local battle=context and context.battle
  local moves=battle and battle.player and battle.player.curMoves or nil
  local cur=tonumber(state.selectedMoveSlot) or 1
  for step=1,4 do
    local slot=((cur-1+step)%4)+1
    if type(moves)=="table" and moves[slot] then
      R._selectRealtimeSlot(context,slot)
      return slot
    end
  end
  R._selectRealtimeSlot(context,((cur)%4)+1)
  return state.selectedMoveSlot
end
function R._drawAttackGrid(context)
  if not battleTopIsActive(context) then return end
  local g=love.graphics
  local rects,scale=R._attackGridLayout(context)
  local selected=tonumber(state.selectedMoveSlot) or 1
  local f=hudFont(15*scale);if f then g.setFont(f) end
  local globalLock=math.max(0,tonumber(state.playerGlobalAttackLock) or 0)
  local suppressed=R._playerAttackSuppressed()
  for i,r in ipairs(rects) do
    local cooldown=R._slotCooldown("player",i)
    local name,pp=currentMoveLabel(context,i)
    local c=R._MOVE_TILE_COLORS[i]
    local active=i==selected
    local alpha=active and .58 or .34
    if name=="-" then alpha=.15 end
    g.setColor(0,0,0,.34);g.rectangle("fill",r.x-2*scale,r.y-2*scale,r.w+4*scale,r.h+4*scale,7*scale,7*scale)
    g.setColor(c[1],c[2],c[3],alpha);g.rectangle("fill",r.x,r.y,r.w,r.h,6*scale,6*scale)
    if cooldown>0 or globalLock>0 or suppressed then
      g.setColor(0,0,0,suppressed and .48 or .30);g.rectangle("fill",r.x,r.y,r.w,r.h,6*scale,6*scale)
    end
    if active then
      g.setColor(1,1,1,.96);g.setLineWidth(math.max(2,3*scale));g.rectangle("line",r.x+1*scale,r.y+1*scale,r.w-2*scale,r.h-2*scale,6*scale,6*scale)
    else
      g.setColor(1,1,1,.24);g.setLineWidth(math.max(1,1*scale));g.rectangle("line",r.x+1*scale,r.y+1*scale,r.w-2*scale,r.h-2*scale,6*scale,6*scale)
    end
    g.setColor(1,1,1,.96)
    g.printf(name,r.x+8*scale,r.y+12*scale,r.w-16*scale,"center")
    local sf=hudFont(10*scale);if sf then g.setFont(sf) end
    local sub="SLOT "..tostring(i)
    if pp~=nil then sub=sub.."   PP "..tostring(pp) end
    if active then sub=sub.."   SELECTED" end
    g.setColor(1,1,1,.72);g.printf(sub,r.x+6*scale,r.y+r.h-17*scale,r.w-12*scale,"center")
    if cooldown>0 then
      g.setColor(1,1,1,.92);g.printf(string.format("%.1fs",cooldown),r.x,r.y+4*scale,r.w-7*scale,"right")
    elseif globalLock>0 then
      g.setColor(1,.86,.42,.94);g.printf(string.format("REC %.1f",globalLock),r.x,r.y+4*scale,r.w-7*scale,"right")
    elseif suppressed then
      local txt=state.playerHitAnimating and "HIT"
        or ((tonumber(state.playerSwitchGuard) or 0)>0 and string.format("SWITCH %.1f",state.playerSwitchGuard))
        or ((tonumber(state.rollTimer) or 0)>0 and "ROLL")
        or ((tonumber(state.airDashTimer) or 0)>0 and "AIR DASH")
        or ((tonumber(state.playerInvuln) or 0)>0 and string.format("REC %.1f",state.playerInvuln) or "LOCK")
      g.setColor(1,.82,.30,.94);g.printf(txt,r.x,r.y+4*scale,r.w-7*scale,"right")
    end
    if f then g.setFont(f) end
  end
  local hf=hudFont(10*scale);if hf then g.setFont(hf) end
  g.setColor(1,1,1,.62)
  local y=rects[1].y-15*scale
  g.printf("LCTRL / DPAD: MOVE    LMB / A: ATTACK    B: ROLL    Y: JUMP    RMB: CAMERA LOCK",rects[1].x-140*scale,y,(rects[2].x+rects[2].w)-rects[1].x+280*scale,"center")
end

local function drawSideCommandMenu(context)
  if not battleTopIsActive(context) then return end
  local g=love.graphics
  local buttons,moves,scale=commandMenuLayout(context)
  local mx,my=R._pad.mouseToRender(context)
  state.uiHover=nil
  local padFocus=tonumber(state.uiPadFocus) or 1
  local f=hudFont(14*scale);if f then g.setFont(f) end
  for i,r in ipairs(buttons) do
    local hover=state.uiCursorActive and pointInRect(mx,my,r)
    local padSel=state.uiCursorActive and padFocus==i and not state.commandMovesOpen
    if hover then state.uiHover="command:"..i end
    if padSel then state.uiHover="command:"..i end
    g.setColor(0,0,0,.50);g.rectangle("fill",r.x,r.y,r.w,r.h,7*scale,7*scale)
    if hover or padSel then g.setColor(.24,.27,.31,.96) else g.setColor(.10,.11,.13,.88) end
    g.rectangle("fill",r.x+2*scale,r.y+2*scale,r.w-4*scale,r.h-4*scale,6*scale,6*scale)
    if i==1 and state.commandMovesOpen then g.setColor(.95,.65,.18,.95) else g.setColor(1,1,1,.94) end
    local label=r.label
    if i==1 then
      local selectedCd=R._slotCooldown("player",state.selectedMoveSlot or 1)
      if selectedCd>0 then label="ATTACK  "..string.format("%.1fs",selectedCd)
      elseif (tonumber(state.playerGlobalAttackLock) or 0)>0 then label="ATTACK  REC "..string.format("%.1f",state.playerGlobalAttackLock) end
    end
    g.printf(label,r.x,r.y+10*scale,r.w,"center")
    if padSel then
      g.setColor(.95,.65,.18,.95);g.setLineWidth(math.max(2,2*scale))
      g.rectangle("line",r.x+1*scale,r.y+1*scale,r.w-2*scale,r.h-2*scale,6*scale,6*scale)
    end
  end
  if state.commandMovesOpen then
    for i,r in ipairs(moves) do
      local hover=state.uiCursorActive and pointInRect(mx,my,r)
      local padSel=state.uiCursorActive and padFocus==i
      if hover then state.uiHover="move:"..i end
      if padSel then state.uiHover="move:"..i end
      local name,pp=currentMoveLabel(context,i)
      g.setColor(0,0,0,.50);g.rectangle("fill",r.x,r.y,r.w,r.h,7*scale,7*scale)
      local slotCd=R._slotCooldown("player",i)
      local onCooldown=slotCd>0 or (tonumber(state.playerGlobalAttackLock) or 0)>0
      if (hover or padSel) and not onCooldown then g.setColor(.25,.28,.32,.96)
      elseif onCooldown then g.setColor(.08,.09,.10,.82)
      else g.setColor(.11,.12,.14,.91) end
      g.rectangle("fill",r.x+2*scale,r.y+2*scale,r.w-4*scale,r.h-4*scale,6*scale,6*scale)
      if onCooldown then g.setColor(.62,.64,.67,.90) else g.setColor(1,1,1,.94) end
      g.print(tostring(i).."  "..name,r.x+10*scale,r.y+9*scale)
      if pp~=nil then
        local pf=hudFont(11*scale);if pf then g.setFont(pf) end
        local right=slotCd>0 and ("CD "..string.format("%.1f",slotCd)) or (((tonumber(state.playerGlobalAttackLock) or 0)>0) and ("REC "..string.format("%.1f",state.playerGlobalAttackLock)) or ("PP "..tostring(pp)))
        g.printf(right,r.x,r.y+12*scale,r.w-10*scale,"right")
        if f then g.setFont(f) end
      end
      if padSel then
        g.setColor(.95,.65,.18,.95);g.setLineWidth(math.max(2,2*scale))
        g.rectangle("line",r.x+1*scale,r.y+1*scale,r.w-2*scale,r.h-2*scale,6*scale,6*scale)
      end
    end
  end
  local hint
  if state.uiCursorActive then hint="TAB / BACK: RETURN TO AIM    A: CONFIRM"
  elseif state.groundCursorOwnsWASD then hint="WASD: MOVE TARGET   SHIFT: FAST   LMB: CAST   RMB: CAMERA"
  else hint="TAB / BACK: MENU CURSOR" end
  local hf=hudFont(10*scale);if hf then g.setFont(hf) end
  g.setColor(1,1,1,.58)
  g.printf(hint,buttons[1].x-230*scale,buttons[4].y+buttons[4].h+8*scale,buttons[1].w+230*scale,"right")
end

local function fireRealtimeSlot(context,slot)
  local battle=context and context.battle
  local user=battle and battle.player
  if battlerSleeping(user) then
    state.attackResult="FAST ASLEEP"
    R._showPlayerAction(context,R._battlerLabel(user).." is fast asleep!",1.05,"status-block:sleep","status")
    return false
  elseif R._battlerFrozen(user) then
    state.attackResult="FROZEN"
    R._showPlayerAction(context,R._battlerLabel(user).." is frozen solid!",1.05,"status-block:freeze","status")
    return false
  end
  local inst,xdId,canonical,vfx=R._selectRealtimeSlot(context,slot)
  local slotCd=R._slotCooldown("player",slot)
  if slotCd>0 then state.attackResult=string.format("MOVE %d COOLDOWN %.1fs",slot,slotCd);return false end
  if (tonumber(state.playerGlobalAttackLock) or 0)>0 then state.attackResult=string.format("GLOBAL RECOVERY %.1fs",state.playerGlobalAttackLock);return false end
  if vfx then pcall(probeGPT1V2,context,vfx,xdId,canonical) else state.v2Probe=nil end
  if inst then
    return startRealtimeMove(context,slot,inst,xdId,canonical or inst.id,vfx)
  end
  state.attackResult="EMPTY MOVE SLOT "..tostring(slot)
  return false
end
local function triggerSideCommand(context,command)
  local battle=context and context.battle
  if not (battle and battle.phase=="menu" and battleTopIsActive(context)) then return false end
  command=tostring(command or ""):lower()
  if command=="attack" then
    state.commandMovesOpen=not state.commandMovesOpen
    if state.commandMovesOpen then state.uiPadFocus=tonumber(state.selectedMoveSlot) or 1 end
    return true
  end
  state.commandMovesOpen=false
  -- BattleState has no chooseMenu; openParty / openItems / tryRun are the
  -- real menu actions used by the native FIGHT command diamond.
  if command=="item" and type(battle.openItems)=="function" then
    local ok=pcall(battle.openItems,battle)
    return ok
  elseif (command=="pokemon" or command=="party") and type(battle.openParty)=="function" then
    local ok=pcall(battle.openParty,battle)
    return ok
  elseif command=="run" and type(battle.tryRun)=="function" then
    local ok=pcall(battle.tryRun,battle)
    return ok
  end
  return false
end

local function handleSideMenuClick(context,x,y)
  local battle=context and context.battle
  if not (battle and battle.phase=="menu" and battleTopIsActive(context)) then return false end
  local buttons,moves=commandMenuLayout(context)
  local attackRects=R._attackGridLayout(context)
  for i,r in ipairs(attackRects) do
    if pointInRect(x,y,r) then R._selectRealtimeSlot(context,i);return true end
  end
  if state.commandMovesOpen then
    for i,r in ipairs(moves) do
      if pointInRect(x,y,r) then
        local ok=fireRealtimeSlot(context,i)
        state.commandMovesOpen=false
        if ok then state.uiCursorMode=false end
        return true
      end
    end
  end
  for i,r in ipairs(buttons) do
    if pointInRect(x,y,r) then
      return triggerSideCommand(context,({[1]="attack",[2]="item",[3]="pokemon",[4]="run"})[i])
    end
  end
  return false
end

R._pad.confirmPadSideFocus=function(context)
  if not state.uiCursorActive then return false end
  local focus=math.max(1,math.min(4,math.floor(tonumber(state.uiPadFocus) or 1)))
  if state.commandMovesOpen then
    local ok=fireRealtimeSlot(context,focus)
    state.commandMovesOpen=false
    if ok then state.uiCursorMode=false end
    return true
  end
  return triggerSideCommand(context,({[1]="attack",[2]="item",[3]="pokemon",[4]="run"})[focus])
end

R._pad.navigatePadSideFocus=function(dir)
  if not state.uiCursorActive then return false end
  local focus=math.max(1,math.min(4,math.floor(tonumber(state.uiPadFocus) or 1)))
  if dir=="up" then focus=focus>1 and focus-1 or 4
  elseif dir=="down" then focus=focus<4 and focus+1 or 1
  elseif dir=="left" and not state.commandMovesOpen then
    state.commandMovesOpen=true;focus=tonumber(state.selectedMoveSlot) or 1
  elseif dir=="right" and state.commandMovesOpen then
    state.commandMovesOpen=false;focus=1
  end
  state.uiPadFocus=focus
  return true
end

R._pad.selectMoveFromDpad=function(context)
  -- Navigate the visible 2x2 attack grid from the current selection.
  --   1 2
  --   3 4
  local cur=math.max(1,math.min(4,math.floor(tonumber(state.selectedMoveSlot) or 1)))
  local nextSlot=nil
  local padPressed=R._pad.padPressed
  if padPressed("dpup") then
    nextSlot=(cur<=2) and cur or (cur-2)
  elseif padPressed("dpdown") then
    nextSlot=(cur>=3) and cur or (cur+2)
  elseif padPressed("dpleft") then
    nextSlot=((cur%2)==1) and cur or (cur-1)
  elseif padPressed("dpright") then
    nextSlot=((cur%2)==0) and cur or (cur+1)
  end
  if nextSlot then R._selectRealtimeSlot(context,nextSlot);return nextSlot end
  return nil
end

function R._drawSideActionHUD(context,side)
  side=(side=="enemy") and "enemy" or "player"
  local text=state[side.."ActionMessage"]
  local timer=tonumber(state[side.."ActionTimer"]) or 0
  if not text or timer<=0 then return end
  local g=love.graphics
  local w,h=renderSize(context)
  local scale=clamp(math.min(w/1280,h/720),.82,1.35)
  local hudW=318*scale
  local margin=24*scale
  local panelW=math.min(390*scale,w*.40)
  local bh=44*scale
  local hudTop=h-72*scale-margin
  local x=side=="enemy" and margin or (w-margin-panelW)
  local y=hudTop-bh-8*scale
  local alpha=clamp(timer/.18,0,1)
  g.setColor(0,0,0,.78*alpha);g.rectangle("fill",x,y,panelW,bh,8*scale,8*scale)
  if side=="enemy" then g.setColor(.88,.28,.24,.82*alpha) else g.setColor(.95,.65,.18,.82*alpha) end
  g.setLineWidth(math.max(1,1.4*scale));g.rectangle("line",x+.5*scale,y+.5*scale,panelW-1*scale,bh-1*scale,8*scale,8*scale)
  local f=hudFont(13*scale);if f then g.setFont(f) end
  g.setColor(1,1,1,.98*alpha)
  g.printf(tostring(text),x+11*scale,y+7*scale,panelW-22*scale,side=="enemy" and "left" or "right")
end

function R._drawPlayerActionHUD(context) return R._drawSideActionHUD(context,"player") end
function R._drawEnemyActionHUD(context) return R._drawSideActionHUD(context,"enemy") end

-- Retained only for compatibility with older call sites. The shared top banner
-- is intentionally no longer drawn; all battle text is side-local now.
function R._drawActionMessage(context) return false end

function R._drawCollisionDebug(context,gy)
  if not attackActive() then return end
  if state.attackHit then love.graphics.setColor(1.00,0.35,0.95,0.92)
  else love.graphics.setColor(1.00,0.82,0.15,0.88) end
  if state.attackKind=="projectile" and state.projectileX then
    drawCylinder(context,state.projectileX,state.projectileZ,state.projectileRadius or .8,gy+.2,3.0,14)
  elseif state.attackKind=="stream" or state.attackKind=="target-line" then
    local ax,az,bx,bz=collisionLine()
    drawProjectedLine(context,{{ax,gy+2.0,az},{bx,gy+2.0,bz}})
  else
    drawBox(context,tackleBox(),gy)
  end
end

function R:drawWorld(context)
  if not state.active then return false end
  local g=love and love.graphics
  if not (g and type(g.line)=="function") then return false end
  if not (context and context.services and type(context.services.project)=="function") then return false end

  local gy=tonumber(context.groundY) or 0
  g.push("all")
  g.setShader()
  local depthOK=pcall(g.setDepthMode,"always",false)
  if not depthOK then pcall(g.setDepthMode) end
  g.setBlendMode("alpha","alphamultiply")

  -- Gameplay presentation only. Hurtbox cylinders, collision debug geometry,
  -- renderer probe, and raw GPT1 V2 diagnostic text are intentionally hidden.
  -- Their underlying collision/VFX systems remain unchanged.
  R._drawTargetingTelegraphs(context,gy)
  local vok,vdrew=pcall(drawScreenSimplifiedVFX,context,gy)
  state.vfxDrawError=vok and nil or tostring(vdrew)
  state.vfxDrew=vok and vdrew==true or false
  local sok,sdrew=pcall(R._fx.drawPersistentStatusVFX,context)
  state.statusVfxDrawError=sok and nil or tostring(sdrew)
  state.statusVfxDrew=sok and sdrew==true or false

  -- Shared top enemy banner retired; side-local boxes render near each HUD.

  -- v0.6.0 true shooter reticle. This is the SAME center-camera ray used by
  -- cameraAimDirection(), so unlike the old cosmetic crosshair it represents
  -- the actual manual-aim solution.
  drawShooterReticle(context)
  drawFlightStaminaHUD(context)
  drawMinimalBattlerHUD(context)
  R._drawAttackGrid(context)
  drawSideCommandMenu(context)
  -- Draw both side-local action/result boxes LAST so no HUD panel can cover them.
  R._drawEnemyActionHUD(context)
  R._drawPlayerActionHUD(context)

  g.pop()
  return true
end

function R._clearPlayerAttackForSwitch()
  state.attackAge=0;state.attackCooldown=0;state.attackCooldownDuration=0
  state.attackHit=false;state.attackMotionLock=false;state.attackActorSeen=false
  state.attackMove=nil;state.attackMoveDef=nil;state.attackMoveId=nil;state.attackMoveSlot=nil
  state.attackKind=nil;state.attackSelf=false;state.attackResolved=false;state.attackPpSpent=false
  state.projectileX=nil;state.projectileZ=nil;state.projectilePrevX=nil;state.projectilePrevZ=nil
  state.projectileVX=0;state.projectileVZ=0;state.projectileHomingTimer=0;state.projectileHomingScale=1
  state.attackAssistActive=false;state.attackAssistAmount=0
  state.attackAccuracyScale=1
  state.vfx=nil
end

function R._clearEnemyAttackForSwitch()
  state.enemyAttackAge=0;state.enemyAttackCooldown=0;state.enemyAttackCooldownDuration=0
  state.enemyAttackHit=false
  state.enemyAttackMove=nil;state.enemyAttackMoveDef=nil;state.enemyAttackMoveId=nil;state.enemyAttackMoveSlot=nil
  state.enemyAttackKind=nil;state.enemyAttackSelf=false;state.enemyAttackResolved=false;state.enemyAttackPpSpent=false
  state.enemyProjectileX=nil;state.enemyProjectileZ=nil;state.enemyProjectilePrevX=nil;state.enemyProjectilePrevZ=nil
  state.enemyProjectileVX=0;state.enemyProjectileVZ=0
  state.enemyAttackAccuracyScale=1
  state.enemyVfx=nil
end

function R._beginSwitchGuard(side)
  if side=="player" or side=="enemy" then
    local keep={}
    for _,p in ipairs(state.persistentMoveVfx or {}) do if p.targetSide~=side then keep[#keep+1]=p end end
    state.persistentMoveVfx=keep
  end
  if side=="player" then
    state.playerMoveCooldowns={0,0,0,0};state.playerMoveCooldownDurations={0,0,0,0};state.playerGlobalAttackLock=0
    state.playerSwitchGuard=math.max(tonumber(state.playerSwitchGuard) or 0,R._SWITCH_GUARD_TIME)
    state.playerHitAnimating=false;state.playerHitActorSeen=false;state.playerHitFallback=0
    state.playerInvuln=0;state.playerFainted=false;state.playerPendingFaintAfterHit=false
    state.rollTimer=0;state.rollElapsed=0;state.rollIFrame=0
    state.airDashTimer=0;state.airDashElapsed=0;state.airDashIFrame=0;state.airDashUsed=false
    state.attackFacingLock=false;state.attackFacingActorSeen=false;state.attackFacingTimer=0
    R._clearPlayerAttackForSwitch()
  elseif side=="enemy" then
    state.enemyMoveCooldowns={0,0,0,0};state.enemyMoveCooldownDurations={0,0,0,0};state.enemyGlobalAttackLock=0
    state.enemySwitchGuard=math.max(tonumber(state.enemySwitchGuard) or 0,R._SWITCH_GUARD_TIME)
    state.enemyHitAnimating=false;state.enemyHitActorSeen=false;state.enemyHitFallback=0
    state.enemyInvuln=0;state.enemyFainted=false;state.enemyPendingFaintAfterHit=false
    R._clearEnemyAttackForSwitch()
  end
end

function R:update(context,dt,arena)
  local game=context and context.game
  if pressed("f8") then
    setEnabled(game,not R.enabled(game))
  end

  local enabled=R.enabled(game)
  if not enabled then
    state.active=false
    setMouseCapture(false)
    if context and context.services then context.services.realtimeBattle=nil end
    return false
  end

  if state.battle~=(context and context.battle) then initialize(context,arena) end
  state.active=true
  do
    local live=context and context.battle
    local modal=live and live.__xdRealtimeNativeModal or nil
    state.nativeModalName=modal
    state.nativeModalActive=modal~=nil
  end
  syncCollisionRadii(context)

  -- A switch can replace battle.player without replacing the BattleState table.
  -- Refresh movement rules from the live battler without touching combat state.
  do
    local dex,canFly=flightCapable(context)
    if dex~=state.playerDex then
      state.playerDex=dex
      state.flightCapable=canFly
      state.py=0;state.vy=0;state.flightMode=false
      state.flightState="grounded";state.jumpCount=0;state.flapClock=0
      state.maxFlightY=ONIX_BATTLE_HEIGHT
      state.flightStamina=FLIGHT_STAMINA_MAX
      state.flightRechargeLock=0
      state.flightGroundTime=0
      state.flightExhausted=false
    else
      state.flightCapable=canFly
    end
  end

  local rdt=wallDt(dt)
  state.groundY=tonumber(context and context.groundY) or 0
  state.actionMessageTimer=0;state.actionMessage=nil;state.actionMessageKind=nil
  state.actionMessageDedupTTL=0
  state.playerActionTimer=math.max(0,(tonumber(state.playerActionTimer) or 0)-rdt)
  state.enemyActionTimer=math.max(0,(tonumber(state.enemyActionTimer) or 0)-rdt)
  state.playerActionDedupTTL=math.max(0,(tonumber(state.playerActionDedupTTL) or 0)-rdt)
  state.enemyActionDedupTTL=math.max(0,(tonumber(state.enemyActionDedupTTL) or 0)-rdt)
  state.nativeTextSideHintTTL=math.max(0,(tonumber(state.nativeTextSideHintTTL) or 0)-rdt)
  if state.nativeTextSideHintTTL<=0 then state.nativeTextSideHint=nil end
  if state.playerActionTimer<=0 then state.playerActionMessage=nil;state.playerActionKind=nil;R._advanceSideAction("player") end
  if state.enemyActionTimer<=0 then state.enemyActionMessage=nil;state.enemyActionKind=nil;R._advanceSideAction("enemy") end
  state.playerStatusEventTTL=math.max(0,(tonumber(state.playerStatusEventTTL) or 0)-rdt)
  state.enemyStatusEventTTL=math.max(0,(tonumber(state.enemyStatusEventTTL) or 0)-rdt)
  if state.playerStatusEventTTL<=0 then state.playerStatusEvent=nil end
  if state.enemyStatusEventTTL<=0 then state.enemyStatusEvent=nil end
  state.impactGuardTTL=math.max(0,(tonumber(state.impactGuardTTL) or 0)-rdt)
  refreshMovementSpeeds(context)
  R._updateMoveCooldowns(rdt)
  R._updateRealtimeSleep(context,rdt)
  R._updateRealtimeFreeze(context,rdt)
  do
    local livePlayer=context and context.battle and context.battle.player and context.battle.player.mon or nil
    if livePlayer~=state.playerMonRef then
      state.playerMonRef=livePlayer
      state.playerFaintHold=false;state.playerFaintSeen=false;state.playerFaintFallback=0
      R._beginSwitchGuard("player")
      state.impactLockActive=false;state.impactAttacker=nil;state.impactDefender=nil
      state.impactGuardSide=nil;state.impactGuardHP=nil;state.impactGuardDamage=nil;state.impactGuardTTL=0;state.impactSource=nil
    end
    local liveEnemy=context and context.battle and context.battle.enemy and context.battle.enemy.mon or nil
    if liveEnemy~=state.enemyMonRef then
      state.enemyMonRef=liveEnemy
      state.enemyFaintHold=false;state.enemyFaintSeen=false;state.enemyFaintFallback=0
      R._beginSwitchGuard("enemy")
      state.impactLockActive=false;state.impactAttacker=nil;state.impactDefender=nil
      state.impactGuardSide=nil;state.impactGuardHP=nil;state.impactGuardDamage=nil;state.impactGuardTTL=0;state.impactSource=nil
    end
  end
  state.playerSwitchGuard=math.max(0,(tonumber(state.playerSwitchGuard) or 0)-rdt)
  state.enemySwitchGuard=math.max(0,(tonumber(state.enemySwitchGuard) or 0)-rdt)
  state.rollCooldown=math.max(0,(tonumber(state.rollCooldown) or 0)-rdt)
  state.rollIFrame=math.max(0,(tonumber(state.rollIFrame) or 0)-rdt)
  state.airDashIFrame=math.max(0,(tonumber(state.airDashIFrame) or 0)-rdt)
  R._updatePlayerHitRecovery(context,rdt)
  R._updateEnemyHitRecovery(context,rdt)
  R._updateImpactLock(rdt)
  updateFaintSide("player",rdt)
  updateFaintSide("enemy",rdt)

  -- FPS/TPS aim owns the mouse by default. TAB / Back toggles a real desktop
  -- cursor for the side command buttons; holding either ALT key also gives
  -- temporary cursor access. The native hidden battle menu remains input-blocked.
  local Pad=R._pad
  if pressed("tab") or Pad.padPressed("back") then
    state.uiCursorMode=not state.uiCursorMode
    if state.uiCursorMode then state.uiPadFocus=tonumber(state.uiPadFocus) or 1 end
  end
  state.uiCursorActive=state.uiCursorMode or isDown("lalt") or isDown("ralt")
  if state.uiCursorActive then
    setMouseCapture(false)
    resetMouse()
  else
    updateMouse()
  end
  state.aimHeld=(not state.uiCursorActive) and (Pad.mouseDown(2) or Pad.padDown("leftshoulder"))
  state.cameraLockHeld=state.aimHeld

  -- Right stick look (always when not in UI cursor mode). Mouse look still
  -- applies through updateMouse above.
  local pad=Pad.mappedGamepad()
  if pad and not state.uiCursorActive and not state.nativeModalActive then
    local rx,ry=Pad.applyDeadzone(pad.rx,pad.ry,Pad.DEADZONE)
    if rx~=0 or ry~=0 then
      state.yaw=state.yaw-rx*Pad.LOOK_SENS
      state.pitch=clamp((state.pitch or 0)+ry*Pad.LOOK_SENS,-0.70,1.05)
    end
  end

  -- Mouse wheel camera zoom: wheel up = closer, wheel down = farther.
  -- Exponential stepping feels consistent at both close and very wide views.
  local runtime=V and V.BattleRuntime
  if runtime and type(runtime.consumeRealtimeWheel)=="function" then
    local ok,wy=pcall(runtime.consumeRealtimeWheel)
    wy=ok and tonumber(wy) or 0
    if wy and wy~=0 then
      state.cameraZoom=clamp((tonumber(state.cameraZoom) or 1.0)*(1.12^(-wy)),.65,3.5)
    end
  end

  if pressed("f7") then resetPlayer() end

  -- Shooter move selection: one physical LCTRL press advances exactly one
  -- slot.  Use both the captured key edge and a release gate/debounce so OS
  -- key-repeat or a noisy callback cannot skip multiple moves in one tap.
  state.moveCycleDebounce=math.max(0,(tonumber(state.moveCycleDebounce) or 0)-rdt)
  local lctrlDown=isDown("lctrl")
  local lctrlEdge=actionPressed("lctrl")
  if (lctrlEdge or (lctrlDown and not state.moveCycleHeld))
      and not state.moveCycleHeld and state.moveCycleDebounce<=0 then
    R._cycleSelectedMove(context)
    state.moveCycleDebounce=MOVE_CYCLE_DEBOUNCE
  end
  state.moveCycleHeld=lctrlDown

  -- Dedicated numpad command row (Num Lock on):
  -- KP9 = ATTACK, KP6 = POKEMON, KP3 = ITEM, KP. = RUN.
  -- These call the same real BattleState actions as the visible side buttons;
  -- they never touch the hidden native command cursor.
  if actionPressed("kp9") then triggerSideCommand(context,"attack")
  elseif actionPressed("kp6") then triggerSideCommand(context,"pokemon")
  elseif actionPressed("kp3") then triggerSideCommand(context,"item")
  elseif actionPressed("kp.") then triggerSideCommand(context,"run")
  end

  -- D-pad: in UI cursor mode navigate the side panel; otherwise select a live
  -- move slot on the 2x2 attack grid.
  if state.uiCursorActive then
    if Pad.padPressed("dpup") then Pad.navigatePadSideFocus("up")
    elseif Pad.padPressed("dpdown") then Pad.navigatePadSideFocus("down")
    elseif Pad.padPressed("dpleft") then Pad.navigatePadSideFocus("left")
    elseif Pad.padPressed("dpright") then Pad.navigatePadSideFocus("right")
    end
  else
    Pad.selectMoveFromDpad(context)
  end

  -- Realtime move hotkeys are reserved here, outside Gen1Recomp's native
  -- FIGHT menu. 6/7/8/9 correspond to live move slots 1/2/3/4.
  local hotSlot=nil
  if actionPressed("6") then hotSlot=1
  elseif actionPressed("7") then hotSlot=2
  elseif actionPressed("8") then hotSlot=3
  elseif actionPressed("9") then hotSlot=4
  end
  -- Shooter control: LMB / A fires the selected live move while aiming. In UI
  -- cursor mode, LMB / A belongs exclusively to the visible side command panel.
  local lmbPressed=Pad.mousePressed(1)
  local padAttack=Pad.padPressed("a")
  if state.uiCursorActive then
    if lmbPressed then
      local mx,my=Pad.mouseToRender(context)
      handleSideMenuClick(context,mx,my)
    elseif padAttack then
      Pad.confirmPadSideFocus(context)
    end
  else
    if not hotSlot and (lmbPressed or padAttack) then
      hotSlot=state.selectedMoveSlot or 1
    end
  end
  if hotSlot and not state.nativeModalActive then fireRealtimeSlot(context,hotSlot) end

  -- Space / Y belong to vertical movement; attacks stay on LMB / A / slots.
  local jumpPressed=(not state.nativeModalActive) and (actionPressed("space") or Pad.padPressed("y"))
  local jumpHeld=isDown("space") or Pad.padDown("y")

  -- 0 is reserved for the future Item/Pokemon/Run utility overlay. It is not
  -- forwarded to the hidden native 4-command menu.
  if actionPressed("0") then
    state.utilityRequested=true
    state.attackResult="UTILITY RESERVED (0)"
  end

  updateTackle(context,rdt)
  updateAttackMotionLock()
  R._updateAttackFacingLock(rdt)
  updateSimplifiedVFX(rdt)
  local liveBattle=context and context.battle
  if liveBattle and liveBattle.__xdRealtimeResolution and liveBattle.phase=="menu" then
    liveBattle.__xdRealtimeResolution=nil
  end

  -- Keyboard fallback for captured mouse look.
  local look=2.4*rdt
  if isDown("q") then state.yaw=state.yaw+look end
  if isDown("e") then state.yaw=state.yaw-look end

  local battleForStatus=context and context.battle
  local playerSleeping=battlerSleeping(battleForStatus and battleForStatus.player)
  local playerFrozen=R._battlerFrozen(battleForStatus and battleForStatus.player)
  local playerConfused=battlerConfused(battleForStatus and battleForStatus.player)
  updateConfusionSteer("player",playerConfused,rdt)
  -- Attacks/charge animations no longer lock locomotion. Only explicit UI
  -- cursor ownership and sleep stop WASD. Cooldown controls attack cadence.
  local movementLocked=state.nativeModalActive or state.uiCursorActive or playerSleeping or playerFrozen or state.playerHitAnimating or state.playerFainted or state.impactLockActive
  -- Hold RMB for a Souls-style camera lock. This rotates only the camera; move
  -- collision and attack resolution still use the crosshair/soft-assist system.
  -- Releasing RMB instantly returns to free mouse camera.
  if state.cameraLockHeld and not state.nativeModalActive and not state.uiCursorActive and not state.enemyFainted then
    local dx,dz=(state.ex or 0)-(state.px or 0),(state.ez or 0)-(state.pz or 0)
    local dist=len2(dx,dz)
    if dist>.05 then
      local targetYaw=atan2(dx,dz)
      local dyaw=(targetYaw-(state.yaw or 0)+math.pi)%(math.pi*2)-math.pi
      local k=1-math.exp(-R._CAMERA_LOCK_RATE*rdt)
      state.yaw=(state.yaw or 0)+dyaw*k
      local pivotY=(tonumber(state.py) or 0)+2.85
      local enemyY=math.max(1.0,(tonumber(state.enemyHeight) or 3.2)*.52)
      local targetPitch=clamp(atan2(pivotY-enemyY,math.max(.1,dist)),-.28,.72)
      local pk=1-math.exp(-R._CAMERA_LOCK_PITCH_RATE*rdt)
      state.pitch=(state.pitch or 0)+(targetPitch-(state.pitch or 0))*pk
    end
  end

  local ix=(isDown("d") and 1 or 0)-(isDown("a") and 1 or 0)
  local iz=(isDown("w") and 1 or 0)-(isDown("s") and 1 or 0)
  -- Left stick overlays keyboard WASD when present.
  if pad and not movementLocked then
    local lx,ly=Pad.applyDeadzone(pad.lx,pad.ly,Pad.DEADZONE)
    if lx~=0 or ly~=0 then
      -- Stick: +x right, +y down. Match WASD: ix=+right, iz=+forward(W).
      ix=ix+lx
      iz=iz+(-ly)
      local stickMag=len2(ix,iz)
      if stickMag>1 then ix,iz=ix/stickMag,iz/stickMag end
    end
  end
  local groundCursorOwnsWASD=false
  do
    local okCursor,ownsOrErr=pcall(R._updateGroundTargetCursor,context,rdt,ix,iz)
    if okCursor then
      groundCursorOwnsWASD=ownsOrErr==true
    else
      -- Target preview is presentation/input sugar. Never let it take the
      -- realtime controller down if a move definition is malformed or absent.
      state.groundCursorOwnsWASD=false
      state.groundCursorInitialized=false
      state.groundCursorKey=nil
      state.combatError="GROUND CURSOR: "..tostring(ownsOrErr)
    end
  end
  if groundCursorOwnsWASD then ix,iz=0,0 end
  if movementLocked then ix,iz=0,0 end

  -- Same camera-space -> world-space transform as the overworld free-move
  -- controller. W is camera-forward, A/D strafe, and diagonals normalize.
  local sy,cy=math.sin(state.yaw),math.cos(state.yaw)
  local mx,mz=-cy*ix+sy*iz,sy*ix+cy*iz
  if playerConfused then mx,mz=rotate2(mx,mz,state.playerConfuseAngle) end
  local mag=len2(mx,mz)

  local dodgePressed=actionPressed("x") or Pad.padPressed("b")
  local airborne=(tonumber(state.py) or 0)>.06 or state.flightMode==true
  if dodgePressed and (tonumber(state.rollCooldown) or 0)<=0
      and (tonumber(state.rollTimer) or 0)<=0 and not airborne
      and (tonumber(state.playerSwitchGuard) or 0)<=0
      and not state.nativeModalActive and not state.uiCursorActive and not playerSleeping and not playerFrozen and not state.playerHitAnimating
      and not state.playerFainted and not state.impactLockActive
      and (tonumber(state.attackAge) or 0)<=0 and not state.attackMotionLock then
    local rx,rz=mx,mz
    if len2(rx,rz)<.01 then rx,rz=state.reticleAimX,state.reticleAimZ end
    if len2(rx,rz)<.01 then rx,rz=sy,cy end
    rx,rz=normalize2(rx,rz)
    state.rollDirX,state.rollDirZ=rx,rz
    state.rollTimer=R._ROLL_DURATION;state.rollElapsed=0
    state.rollCooldown=R._ROLL_COOLDOWN;state.rollIFrame=R._ROLL_IFRAME_TIME
    state.facingX,state.facingZ=rx,rz
    state.attackResult="DODGE ROLL"
    local pb=context and context.battle and context.battle.player
    R._showPlayerAction(context,R._battlerLabel(pb).." rolled!",.90)
  elseif dodgePressed and airborne and not state.airDashUsed
      and (tonumber(state.airDashTimer) or 0)<=0 and (tonumber(state.playerSwitchGuard) or 0)<=0
      and not state.nativeModalActive and not state.uiCursorActive and not playerSleeping and not playerFrozen and not state.playerHitAnimating
      and not state.playerFainted and not state.impactLockActive
      and (tonumber(state.attackAge) or 0)<=0 and not state.attackMotionLock then
    local dxz,dzz=mx,mz
    if len2(dxz,dzz)<.01 then dxz,dzz=state.reticleAimX,state.reticleAimZ end
    if len2(dxz,dzz)<.01 then dxz,dzz=sy,cy end
    dxz,dzz=normalize2(dxz,dzz)
    state.airDashDirX,state.airDashDirZ=dxz,dzz
    state.airDashTimer=R._AIR_DASH_DURATION;state.airDashElapsed=0
    state.airDashIFrame=R._AIR_DASH_IFRAME;state.airDashUsed=true
    state.facingX,state.facingZ=dxz,dzz
    state.attackResult="AIR DASH"
    local pb=context and context.battle and context.battle.player
    R._showPlayerAction(context,R._battlerLabel(pb).." air dashed!",.90)
  end

  local rolling=(tonumber(state.rollTimer) or 0)>0
  local airDashing=(tonumber(state.airDashTimer) or 0)>0
  state.playerVelX,state.playerVelZ=0,0
  if airDashing then
    local progress=clamp((tonumber(state.airDashElapsed) or 0)/R._AIR_DASH_DURATION,0,1)
    local base=clamp((tonumber(state.playerMoveSpeed) or TORKOAL_PLAYER_MOVE_SPEED)*R._AIR_DASH_SPEED_FACTOR,R._AIR_DASH_MIN_SPEED,R._AIR_DASH_MAX_SPEED)
    local speed=base*(1.06-.18*progress)
    state.playerVelX,state.playerVelZ=(tonumber(state.airDashDirX) or 0)*speed,(tonumber(state.airDashDirZ) or -1)*speed
    state.px=state.px+state.playerVelX*rdt
    state.pz=state.pz+state.playerVelZ*rdt
    state.facingX,state.facingZ=state.airDashDirX,state.airDashDirZ
    state.moving=true
    state.airDashElapsed=(tonumber(state.airDashElapsed) or 0)+rdt
    state.airDashTimer=math.max(0,(tonumber(state.airDashTimer) or 0)-rdt)
    if state.airDashTimer<=0 then state.airDashElapsed=0 end
  elseif rolling then
    local progress=clamp((tonumber(state.rollElapsed) or 0)/R._ROLL_DURATION,0,1)
    local base=clamp((tonumber(state.playerMoveSpeed) or TORKOAL_PLAYER_MOVE_SPEED)*R._ROLL_SPEED_FACTOR,R._ROLL_MIN_SPEED,R._ROLL_MAX_SPEED)
    local speed=base*(1.08-.30*progress)
    state.playerVelX,state.playerVelZ=(tonumber(state.rollDirX) or 0)*speed,(tonumber(state.rollDirZ) or -1)*speed
    state.px=state.px+state.playerVelX*rdt
    state.pz=state.pz+state.playerVelZ*rdt
    state.facingX,state.facingZ=state.rollDirX,state.rollDirZ
    state.moving=true
    state.rollElapsed=(tonumber(state.rollElapsed) or 0)+rdt
    state.rollTimer=math.max(0,(tonumber(state.rollTimer) or 0)-rdt)
    if state.rollTimer<=0 then state.rollElapsed=0 end
  else
    state.moving=(not movementLocked) and mag>0.01
    if state.moving then
      mx,mz=normalize2(mx,mz)
      local speed=(tonumber(state.playerMoveSpeed) or TORKOAL_PLAYER_MOVE_SPEED)
        *((isDown("lshift") or isDown("rshift")) and 1.45 or 1)
      state.playerVelX,state.playerVelZ=mx*speed,mz*speed
      state.px=state.px+state.playerVelX*rdt
      state.pz=state.pz+state.playerVelZ*rdt
      if state.attackFacingLock then
        state.facingX,state.facingZ=state.attackFacingX,state.attackFacingZ
      elseif state.attackAge>0 then
        state.facingX,state.facingZ=state.attackDirX,state.attackDirZ
      else
        state.facingX,state.facingZ=mx,mz
      end
    elseif not movementLocked then
      -- During an attack the Pokemon keeps the committed aim bearing while WASD
      -- can still strafe it. Outside attacks, standing follows camera bearing.
      if state.attackFacingLock then state.facingX,state.facingZ=state.attackFacingX,state.attackFacingZ
      elseif state.attackAge>0 then state.facingX,state.facingZ=state.attackDirX,state.attackDirZ
      else state.facingX,state.facingZ=sy,cy end
    end
  end

  -- Vertical movement. Flying types now have finite lift stamina rather than
  -- permanent hover: 3 seconds of active lift, no aerial recharge, a grounded
  -- recovery lockout, then a timed refill. Grounded Pokemon keep double jump.
  if state.flapClock>0 then state.flapClock=math.max(0,state.flapClock-rdt) end
  do
    local verticalControlAllowed=(not state.nativeModalActive) and (not state.uiCursorActive) and (not playerSleeping) and (not playerFrozen) and (not state.playerHitAnimating) and (not state.playerFainted) and (not state.impactLockActive) and not ((tonumber(state.rollTimer) or 0)>0) and not ((tonumber(state.airDashTimer) or 0)>0)
    if state.flightCapable then
      local grounded=(tonumber(state.py) or 0)<=0.001 and (tonumber(state.vy) or 0)<=0
      if grounded then
        state.py=0;state.vy=0;state.flightMode=false;state.flightState="grounded"
        state.flightGroundTime=(tonumber(state.flightGroundTime) or 0)+rdt
        if state.flightRechargeLock>0 then
          state.flightRechargeLock=math.max(0,state.flightRechargeLock-rdt)
        elseif state.flightGroundTime>=FLIGHT_GROUND_LOCKOUT then
          state.flightStamina=math.min(FLIGHT_STAMINA_MAX,(tonumber(state.flightStamina) or 0)+FLIGHT_RECHARGE_RATE*rdt)
          if state.flightStamina>=FLIGHT_STAMINA_MAX-.001 then state.flightExhausted=false end
        end
      else
        state.flightGroundTime=0
      end

      if verticalControlAllowed and jumpPressed and grounded and (tonumber(state.flightStamina) or 0)>.08 and state.flightRechargeLock<=0 then
        state.flightMode=true
        state.flightState="takeoff"
        state.vy=7.2
        state.flapClock=FLIGHT_FLAP_COOLDOWN
      end

      if state.flightMode then
        local lifting=verticalControlAllowed and jumpHeld and (tonumber(state.flightStamina) or 0)>0
        if lifting then
          state.flightStamina=math.max(0,(tonumber(state.flightStamina) or 0)-rdt)
          if state.flightStamina<=0 then state.flightExhausted=true end
        end
        if lifting and state.flapClock<=0 then
          state.vy=math.min(8.8,(tonumber(state.vy) or 0)+3.0)
          state.flapClock=FLIGHT_FLAP_COOLDOWN
        elseif (not lifting) and state.vy>0 then
          state.vy=0
        end
        local descending=(verticalControlAllowed and (isDown("rctrl") or isDown("c"))) or state.flightExhausted or playerSleeping or playerFrozen or state.playerHitAnimating or state.playerFainted
        local gravity=descending and 11.0 or 4.6
        state.vy=(tonumber(state.vy) or 0)-gravity*rdt
        if descending then state.vy=math.max(state.vy,-9.0) end
        state.py=clamp((tonumber(state.py) or 0)+state.vy*rdt,0,state.maxFlightY)
        if state.py>=state.maxFlightY and state.vy>0 then state.vy=0 end
        if state.py<=0.001 and state.vy<=0 then
          state.py=0;state.vy=0;state.flightMode=false;state.flightState="grounded"
          state.airDashUsed=false;state.airDashTimer=0;state.airDashElapsed=0;state.airDashIFrame=0
          state.flightGroundTime=0
          state.flightRechargeLock=FLIGHT_GROUND_LOCKOUT
        elseif state.flightState=="takeoff" and state.py>1.15 then
          state.flightState="airborne"
        elseif state.flightState~="takeoff" then
          state.flightState="airborne"
        end
      end
    else
      if verticalControlAllowed and jumpPressed then
        local canJump=false
        if state.py<=0.001 then
          state.vy=GROUND_JUMP_VY
          state.jumpCount=1
          state.flightState="jump"
          canJump=true
        elseif state.jumpCount<2 then
          state.vy=GROUND_DOUBLE_JUMP_VY
          state.jumpCount=2
          state.flightState="double-jump"
          canJump=true
        end
        if canJump then
          -- Leap in the current travel direction; from a standstill, leap
          -- through the camera reticle direction. This makes Space useful as
          -- an actual dodge instead of a vertical pogo hop.
          local jx,jz=mx,mz
          if len2(jx,jz)<.01 then jx,jz=sy,cy end
          jx,jz=normalize2(jx,jz)
          local boost=(tonumber(state.playerMoveSpeed) or TORKOAL_PLAYER_MOVE_SPEED)
            *GROUND_JUMP_FORWARD_FACTOR
          state.jumpBoostX,state.jumpBoostZ=jx*boost,jz*boost
          state.jumpBoostClock=GROUND_JUMP_BOOST_TIME
        end
      end
      if state.py>0 or state.vy>0 then
        state.vy=(tonumber(state.vy) or 0)-22.0*rdt
        state.py=(tonumber(state.py) or 0)+state.vy*rdt

        if verticalControlAllowed and state.jumpBoostClock>0 then
          local bx,bz=tonumber(state.jumpBoostX) or 0,tonumber(state.jumpBoostZ) or 0
          state.px=state.px+bx*rdt
          state.pz=state.pz+bz*rdt
          state.playerVelX=(tonumber(state.playerVelX) or 0)+bx
          state.playerVelZ=(tonumber(state.playerVelZ) or 0)+bz
          state.jumpBoostClock=math.max(0,state.jumpBoostClock-rdt)
          local decay=math.exp(-GROUND_JUMP_BOOST_DRAG*rdt)
          state.jumpBoostX,state.jumpBoostZ=bx*decay,bz*decay
        elseif not verticalControlAllowed then
          state.jumpBoostX,state.jumpBoostZ,state.jumpBoostClock=0,0,0
        end

        if state.py<=0 then
          state.py=0;state.vy=0;state.jumpCount=0;state.flightState="grounded"
          state.airDashUsed=false;state.airDashTimer=0;state.airDashElapsed=0;state.airDashIFrame=0
          state.jumpBoostX,state.jumpBoostZ,state.jumpBoostClock=0,0,0
        end
      end
    end
  end

  updateEnemyAI(context,rdt,arena)
  resolveArenaBoundary(arena)
  resolveBodyCollision()
  applyArena(arena)

  -- True third-person action/FPS-style boom. Pitch changes the actual look
  -- direction, and mouse response is immediate rather than orbit-eased.
  do
    local zoom=clamp(tonumber(state.cameraZoom) or 1.0,.65,3.5)
    local framing=R._actorFramingScale(context)
    -- v0.6.14 starts roughly 17% farther out than the old camera, then adds
    -- species-size framing. Small Pokemon stay readable; Dragonite no longer
    -- fills/crops the whole battle view.
    local boom=(state.aimHeld and 9.0 or 12.4)*zoom*framing
    local shoulder=state.aimHeld and .82 or 1.15
    local pivotY=(tonumber(state.py) or 0)+2.85
    local cp=math.cos(state.pitch)
    local lx,ly,lz=math.sin(state.yaw)*cp,-math.sin(state.pitch),math.cos(state.yaw)*cp
    local rx,rz=-math.cos(state.yaw),math.sin(state.yaw)
    local pivot={state.px,pivotY,state.pz}
    state.camEye={
      pivot[1]-lx*boom+rx*shoulder,
      math.max(.75,pivot[2]-ly*boom+.35),
      pivot[3]-lz*boom+rz*shoulder,
    }
    local focusDist=7.8*framing
    state.camFocus={
      pivot[1]+lx*focusDist+rx*shoulder,
      pivot[2]+ly*focusDist,
      pivot[3]+lz*focusDist+rz*shoulder,
    }
  end

  -- Selected-move targeting preview. Circle/trap moves use the live camera ray
  -- intersected with the arena floor and clamped to cast range. Lane/cone
  -- previews share the same committed aim direction used on LMB.
  do
    local profile,kind,range,radius,def=R._selectedTargetProfile(context)
    local cls=profile and tostring(profile.class or ""):upper() or nil
    state.targetPreviewClass=cls;state.targetPreviewKind=kind
    local accScale=R._accuracyShapeScale(context and context.battle and context.battle.player)
    state.targetPreviewRange=tonumber(range) or 0
    state.targetPreviewRadius=(tonumber(profile and profile.radius) or ((kind=="ground-aoe") and tonumber(radius) or 0) or 0)*accScale
    state.targetPreviewAngle=(tonumber(profile and profile.angle) or ((kind=="cone") and tonumber(radius) or 0) or 0)*accScale
    state.targetPreviewWidth=(tonumber(profile and profile.width) or ((kind=="stream") and ((tonumber(radius) or 0)*2) or 0) or 0)*accScale
    state.targetPreviewActive=cls=="GROUND_AOE" or cls=="TRAP_ZONE" or cls=="LINE" or cls=="CONE" or cls=="SELF_AOE" or cls=="DASH"

    if cls=="GROUND_AOE" or cls=="TRAP_ZONE" then
      local tx,tz=state.groundCursorX,state.groundCursorZ
      if not state.groundCursorInitialized then tx,tz=R._cameraGroundTargetPoint(range or 18) end
      local td=len2((tx or state.px)-state.px,(tz or state.pz)-state.pz)
      local ax,az=normalize2((tx or state.px)-state.px,(tz or state.pz)-state.pz);if ax==0 and az==0 then ax,az=0,-1 end
      state.targetPreviewX,state.targetPreviewZ=tx,tz
      state.targetPreviewDirX,state.targetPreviewDirZ=ax,az
      state.reticleAimX,state.reticleAimZ=ax,az
      state.reticleWorldX,state.reticleWorldZ=tx,tz
      state.reticleDisplayDistance=td or 1
      local dx,dz=(state.ex or 0)-tx,(state.ez or 0)-tz
      local rr=(state.targetPreviewRadius or 4)+R._playerTargetRadius()
      state.reticleOnTarget=dx*dx+dz*dz<=rr*rr
      state.reticleAssistActive=false;state.reticleAssistAmount=0;state.reticleAssistCone=0
    elseif cls=="SELF_AOE" then
      state.targetPreviewX,state.targetPreviewZ=state.px,state.pz
      state.targetPreviewDirX,state.targetPreviewDirZ=state.facingX,state.facingZ
      state.targetPreviewRange=0
      state.targetPreviewRadius=tonumber(profile and profile.radius) or tonumber(range) or 6
      state.reticleOnTarget=false;state.reticleAssistActive=false;state.reticleAssistAmount=0;state.reticleAssistCone=0
      state.reticleWorldX,state.reticleWorldZ=state.px,state.pz
    else
      local ax,az,on,assist,amount,coneDeg,aimDist=cameraAimDirection(range or 18,kind,def)
      state.targetPreviewX,state.targetPreviewZ=(state.px or 0)+ax*(range or 18),(state.pz or 0)+az*(range or 18)
      state.targetPreviewDirX,state.targetPreviewDirZ=ax,az
      if cls=="DASH" then state.targetPreviewRange=4.5 end
      state.reticleAimX,state.reticleAimZ=ax,az
      state.reticleOnTarget=on==true
      state.reticleAssistActive=(not on) and assist==true
      state.reticleAssistAmount=amount or 0
      state.reticleAssistCone=coneDeg or 0
      local lead=math.max(1,tonumber(aimDist) or tonumber(range) or 18)
      state.reticleDisplayDistance=lead
      if on then state.reticleWorldX,state.reticleWorldZ=state.ex,state.ez
      else state.reticleWorldX=(state.px or 0)+ax*lead;state.reticleWorldZ=(state.pz or 0)+az*lead end
    end
  end


  context.services=context.services or {}
  context.services.realtimeBattle={
    active=true,
    mode="movement-prototype",
    dt=rdt,
    player={x=state.px,y=state.py,z=state.pz,vy=state.vy,radius=state.playerRadius},
    enemy={x=state.ex,z=state.ez,radius=state.enemyRadius},
    playerFacing={state.facingX,state.facingZ},
    enemyFacing={state.enemyFacingX,state.enemyFacingZ},
    moving=state.moving,
    enemyMoving=state.enemyMoving==true,
    playerDex=state.playerDex,
    playerBaseSpeedStat=state.playerBaseSpeedStat,
    enemyBaseSpeedStat=state.enemyBaseSpeedStat,
    playerMoveSpeed=state.playerMoveSpeed,playerSpeedStage=state.playerSpeedStage,playerSpeedStageFactor=state.playerSpeedStageFactor,
    enemyMoveSpeed=state.enemyMoveSpeed,enemySpeedStage=state.enemySpeedStage,enemySpeedStageFactor=state.enemySpeedStageFactor,
    playerStatus=state.playerStatus,enemyStatus=state.enemyStatus,
    playerConfused=state.playerConfused==true,enemyConfused=state.enemyConfused==true,
    playerActionMessage=state.playerActionMessage,playerActionTimer=state.playerActionTimer,
    enemyActionMessage=state.enemyActionMessage,enemyActionTimer=state.enemyActionTimer,
    attackFacingLock=state.attackFacingLock==true,
    attackCooldown=state.attackCooldown,attackCooldownDuration=state.attackCooldownDuration,
    playerMoveCooldowns=state.playerMoveCooldowns,playerGlobalAttackLock=state.playerGlobalAttackLock,
    enemyAttackCooldown=state.enemyAttackCooldown,enemyAttackCooldownDuration=state.enemyAttackCooldownDuration,
    enemyMoveCooldowns=state.enemyMoveCooldowns,enemyGlobalAttackLock=state.enemyGlobalAttackLock,
    uiCursorActive=state.uiCursorActive==true,nativeModalActive=state.nativeModalActive==true,nativeModalName=state.nativeModalName,
    commandMovesOpen=state.commandMovesOpen==true,
    playerHitAnimating=state.playerHitAnimating==true,
    playerInvuln=state.playerInvuln,
    playerSwitchGuard=state.playerSwitchGuard,enemySwitchGuard=state.enemySwitchGuard,
    rolling=(tonumber(state.rollTimer) or 0)>0,rollTimer=state.rollTimer,rollCooldown=state.rollCooldown,rollIFrame=state.rollIFrame,
    airDashing=(tonumber(state.airDashTimer) or 0)>0,airDashTimer=state.airDashTimer,airDashIFrame=state.airDashIFrame,airDashUsed=state.airDashUsed==true,
    rollProgress=((tonumber(state.rollTimer) or 0)>0) and clamp((tonumber(state.rollElapsed) or 0)/R._ROLL_DURATION,0,1) or 0,
    rollAngle=((tonumber(state.rollTimer) or 0)>0) and (clamp((tonumber(state.rollElapsed) or 0)/R._ROLL_DURATION,0,1)*math.pi*2) or 0,
    rollVisualLift=((tonumber(state.rollTimer) or 0)>0) and (math.sin(math.pi*clamp((tonumber(state.rollElapsed) or 0)/R._ROLL_DURATION,0,1))*R._ROLL_VISUAL_LIFT) or 0,
    impactLockActive=state.impactLockActive==true,impactAttacker=state.impactAttacker,impactDefender=state.impactDefender,impactSource=state.impactSource,
    playerFainted=state.playerFainted==true,
    flightCapable=state.flightCapable==true,
    flightMode=state.flightMode==true,
    flightState=state.flightState,
    jumpCount=state.jumpCount,
    flapCooldown=state.flapClock,
    maxFlightY=state.maxFlightY,
    flightStamina=state.flightStamina,
    flightStaminaMax=state.flightStaminaMax,
    flightRechargeLock=state.flightRechargeLock,
    flightGroundTime=state.flightGroundTime,
    flightExhausted=state.flightExhausted==true,
    attackSerial=state.attackSerial,
    enemyAttackSerial=state.enemyAttackSerial,
    enemyAttackMoveId=state.enemyAttackMoveId,
    enemyAttackMoveDef=state.enemyAttackMoveDef,
    enemyAttackActive=enemyAttackActive(),
    enemyAttackResult=state.enemyLastResult,
    attackMoveId=state.attackMoveId,
    attackMoveDef=state.attackMoveDef,
    attackMoveSlot=state.attackMoveSlot,
    hitSerial=state.hitSerial,
    attackActive=attackActive(),
    attackMotionLock=state.attackMotionLock==true,
    attackResult=state.attackResult,
    attackKind=state.attackKind,
    attackProfileClass=state.attackProfileClass,
    attackRange=state.attackRange,
    attackTargetDistance=state.attackTargetDistance,
    attackTarget={state.attackTargetX,state.attackTargetZ},attackAOERadius=state.attackAOERadius,
    targetPreviewActive=state.targetPreviewActive==true,targetPreviewClass=state.targetPreviewClass,
    targetPreview={state.targetPreviewX,state.targetPreviewZ},targetPreviewRange=state.targetPreviewRange,
    targetPreviewRadius=state.targetPreviewRadius,targetPreviewAngle=state.targetPreviewAngle,targetPreviewWidth=state.targetPreviewWidth,
    attackDir={state.attackDirX,state.attackDirZ},
    reticleOnTarget=state.reticleOnTarget==true,reticleAssistActive=state.reticleAssistActive==true,
    reticleAssistAmount=state.reticleAssistAmount,reticleAssistCone=state.reticleAssistCone,
    cameraLockHeld=state.cameraLockHeld==true,
    reticleAim={state.reticleAimX,state.reticleAimZ},
    reticleWorld={state.reticleWorldX,state.reticleWorldZ},reticleDisplayDistance=state.reticleDisplayDistance,
    aimHeld=state.aimHeld==true,
    projectileX=state.projectileX,projectileZ=state.projectileZ,
    simplifiedVFX=state.vfx and {name=state.vfx.name,type=state.vfx.type,kind=state.vfx.kind} or nil,
    gpt1v2Probe=state.v2Probe,
    vfxDrew=state.vfxDrew==true,
    vfxDrawError=state.vfxDrawError,
    impactCount=#(state.impacts or {}),
    tacklePP=(function()
      local b=context and context.battle
      local m=b and findTackle(b)
      return m and m.pp or nil
    end)(),
    enemyHP=context and context.battle and context.battle.enemy and context.battle.enemy.mon and context.battle.enemy.mon.hp or nil,
    enemyMaxHP=context and context.battle and context.battle.enemy and context.battle.enemy.mon and context.battle.enemy.mon.stats and context.battle.enemy.mon.stats.hp or nil,
    lastDamage=state.lastDamage,
    lastCrit=state.lastCrit,
    lastTypeMult=state.lastTypeMult,
    combatError=state.combatError,
    selectedMoveSlot=state.selectedMoveSlot,
    selectedMoveId=state.selectedMoveId,
    selectedMoveXdId=state.selectedMoveXdId,
    selectedMoveCanonical=state.selectedMoveCanonical,
    selectedMoveHasVFX=state.selectedMoveHasVFX,
    utilityRequested=state.utilityRequested,
    arenaRadius=state.arenaRadius,
    boundaryMode=state.boundaryMode,
    navWalls=state.nav and #(state.nav.walls or {}) or 0,
    cameraZoom=state.cameraZoom,
    controls="TPS/FPS aim / classified circle-lane-cone targeting telegraphs / WASD manual ground cursor for circle+trap moves / translucent 2x2 move grid / debounced LCTRL cycle + LMB lock-and-fire / X grounded roll / airborne dash + grounded Space dodge-leap double jump / 0.5s post-switch neutral guard / hurt-animation WASD lock + 1s recovery i-frames / no attacks during recovery / independent 4-slot cooldowns + 0.8s shared recovery / live SPE movement scaling + ACC attack-shape scaling + EVA target-size scaling / PAR half-speed / SLP movement lock+sleep state / confusion steering scramble / universal enemy AI / species Speed-scaled locomotion (Torkoal=1.0x) / TAB or ALT menu cursor / RMB shoulder-aim zoom / 6-9 select+fire / WASD camera-relative / Space flight-stamina or double-jump / RCTRL/C descend / Shift run / F7 reset / F8 toggle",
  }
  return true
end

function R:event(context,name,payload)
  if not state.active then return false end
  local battle=context and context.battle
  if state.battle and battle and state.battle~=battle then return false end
  local S=V and V.BattleSides

  -- Enemy move announcements. The realtime AI announces at attack commit so a
  -- projectile miss still says what was used; this event path covers native or
  -- alternate action paths. The short de-dup window prevents a committed move
  -- and its later authoritative executeAction event from printing twice.
  if name=="battle.move_used" then
    local side
    if S and type(S.payload)=="function" then
      local ok,v=pcall(S.payload,context,payload,{"user","attacker","source"});if ok then side=v end
    end
    if S and type(S.value)=="function" then side=S.value(side) or side end
    local user=type(payload)=="table" and (payload.user or payload.attacker or payload.source) or nil
    local move=type(payload)=="table" and payload.move or nil
    local moveId=type(move)=="table" and (move.id or move.name) or move
    if side=="enemy" then
      state.nativeTextSideHint="enemy";state.nativeTextSideHintTTL=4.0
      R._showEnemyAction(context,R._battlerLabel(user or (battle and battle.enemy)).." used "..R._prettyToken(move).."!",
        1.45,"move:event:enemy:"..tostring(moveId),"move")
      return true
    elseif side=="player" then
      state.nativeTextSideHint="player";state.nativeTextSideHintTTL=4.0
      -- Event fallback catches authoritative/alternate move paths as well as the
      -- direct realtime commit path, so player action text cannot silently miss.
      R._showPlayerAction(context,R._battlerLabel(user or (battle and battle.player)).." used "..R._prettyToken(move).."!",
        1.45,"move:event:player:"..tostring(moveId),"move")
      return true
    end
    return false
  end

  if name=="battle.status_inflicted" then
    local side
    if S and type(S.payload)=="function" then
      local ok,v=pcall(S.payload,context,payload,{"target","battler","side"});if ok then side=v end
    end
    if S and type(S.value)=="function" then side=S.value(side) or side end
    local st=type(payload)=="table" and payload.status or nil
    if side=="player" or side=="enemy" then
      -- Keep the currently acting side for the native status-result page.
      state[side.."StatusEvent"]=st
      state[side.."StatusEventTTL"]=2.50
      -- Force the immediate HUD cache too; mon.status remains authoritative and
      -- takes over on the next frame.
      state[side.."Status"]=st
      local code=tostring(type(st)=="table" and (st.id or st.hudLabel or st.label or st.name) or st or ""):upper()
      if code=="SLP" or code=="SLEEP" or code=="ASLEEP" or code=="FRZ" or code=="FREEZE" or code=="FROZEN" then
        if side=="player" then
          state.rollTimer=0;state.rollElapsed=0;state.rollIFrame=0
          state.airDashTimer=0;state.airDashElapsed=0;state.airDashIFrame=0
          state.attackFacingLock=false;state.attackFacingActorSeen=false;state.attackFacingTimer=0
          R._clearPlayerAttackForSwitch()
        else
          R._clearEnemyAttackForSwitch()
        end
      end
    end
    return false
  end

  if name=="battle.battler_switched" then
    local side
    if S and type(S.payload)=="function" then
      local ok,v=pcall(S.payload,context,payload,{"side","battler","replacement","newBattler","target"});if ok then side=v end
    end
    if S and type(S.value)=="function" then side=S.value(side) or side end
    if side=="player" or side=="enemy" then R._beginSwitchGuard(side) end
    if side=="enemy" then
      local b=type(payload)=="table" and (payload.battler or payload.replacement or payload.newBattler or payload.target) or nil
      local previous=type(payload)=="table" and payload.previous or nil
      local previousAlive=previous and previous.mon and (tonumber(previous.mon.hp) or 0)>0
      local verb=previousAlive and " switched to " or " sent out "
      local text=R._trainerLabel(battle)..verb..R._battlerLabel(b).."!"
      R._showActionMessage(text,"switch","switch:"..R._battlerLabel(b),2.65)
      return true
    end
    return false
  end

  if name=="battle.trainer_item_used" then
    local item=type(payload)=="table" and payload.item or nil
    local text=R._trainerLabel(battle).." used "..R._prettyToken(item).."!"
    R._showActionMessage(text,"item","item:"..tostring(type(item)=="table" and (item.id or item.name) or item),2.45)
    return true
  end

  if name=="battle.fainted" then
    local side
    if S and type(S.payload)=="function" then
      local ok,v=pcall(S.payload,context,payload,{"battler","target","side","faintedSide","targetSide"});if ok then side=v end
    end
    if S and type(S.value)=="function" then side=S.value(side) or side end
    local b=type(payload)=="table" and (payload.battler or payload.target) or nil
    if not b and battle and (side=="enemy" or side=="player") then b=battle[side] end
    R._queueActionMessage(R._battlerLabel(b).." fainted!","ending","faint:"..tostring(side or R._battlerLabel(b)),1.30,side=="player" and "player" or "enemy")
    return true
  end

  if name=="battle.exp_gained" then
    local amount=type(payload)=="table" and tonumber(payload.exp or payload.amount or payload.gained or payload.value or payload.xp) or nil
    local b=type(payload)=="table" and (payload.battler or payload.target or payload.mon or payload.pokemon) or nil
    if not b and battle then b=battle.player end
    local label=R._battlerLabel(b)
    local text=amount and (label.." gained "..tostring(math.floor(amount+0.5)).." EXP!") or (label.." gained EXP!")
    R._queueActionMessage(text,"ending","exp:"..tostring(amount or "?")..":"..label,1.55,"player")
    return true
  end

  if name~="battle.damage_dealt" then return false end
  local defender
  local attacker
  if S and type(S.payload)=="function" then
    local okD,d=pcall(S.payload,context,payload,{"target","side","battler"})
    if okD then defender=d end
    local okA,a=pcall(S.payload,context,payload,{"user","attacker","source"})
    if okA then attacker=a end
  end
  if not defender and type(payload)=="table" then defender=payload.side end
  if S and type(S.value)=="function" then defender=S.value(defender) or defender end
  if not attacker and S and type(S.other)=="function" and defender then attacker=S.other(defender) end
  if S and type(S.value)=="function" then attacker=S.value(attacker) or attacker end
  local damage=type(payload)=="table" and tonumber(payload.damage or payload.dealt or payload.amount or payload.value) or nil
  if not damage or damage<=0 then return false end
  -- Realtime sleep wakes on a real damaging hit. This happens after the
  -- authoritative damage event, so misses/status-only moves never wake it.
  if defender=="player" or defender=="enemy" then
    R._wakeRealtimeSleep(context,defender,"damage")

    -- Fire damage immediately releases FRZ. Prefer move metadata supplied by
    -- the battle event; otherwise use the currently committed realtime attack.
    local hitMoveDef=type(payload)=="table" and (payload.moveDef or payload.moveData or payload.def) or nil
    if type(hitMoveDef)~="table" then
      if attacker=="player" then hitMoveDef=state.attackMoveDef
      elseif attacker=="enemy" then hitMoveDef=state.enemyAttackMoveDef end
    end
    if type(hitMoveDef)=="table" and moveType(hitMoveDef)=="FIRE" then
      R._thawRealtimeFreeze(context,defender,"fire")
    end
  end
  return R._confirmImpact(context,attacker,defender,damage,"battle.damage_dealt")
end

function R:cameraPose(context,arena)
  if not state.active then return nil end
  if state.camEye and state.camFocus then
    return {
      eye={state.camEye[1],state.camEye[2],state.camEye[3]},
      focus={state.camFocus[1],state.camFocus[2],state.camFocus[3]},
      fov=math.rad(state.aimHeld and 48 or 56),curve=0,
    }
  end
  local fx,fz=math.sin(state.yaw),math.cos(state.yaw)
  local rx,rz=-fz,fx
  local zoom=clamp(tonumber(state.cameraZoom) or 1.0,.65,3.5)
  local framing=R._actorFramingScale(context)
  local distance=(state.aimHeld and 9.0 or 12.4)*zoom*framing
  local flat=distance*math.cos(state.pitch)
  local lift=distance*math.sin(state.pitch)
  local baseY=(tonumber(state.py) or 0)+2.55
  return {
    eye={state.px-fx*flat+rx*1.15,math.max(1.35,baseY+lift+.55),state.pz-fz*flat+rz*1.15},
    focus={state.px+fx*4.2+rx*.28,baseY+.15,state.pz+fz*4.2+rz*.28},
    fov=math.rad(state.aimHeld and 48 or 56),curve=0,
  }
end

function R:status()
  return {
    active=state.active,
    mode="movement-prototype",
    player={state.px,state.py,state.pz},
    playerDex=state.playerDex,
    playerBaseSpeedStat=state.playerBaseSpeedStat,
    enemyBaseSpeedStat=state.enemyBaseSpeedStat,
    playerMoveSpeed=state.playerMoveSpeed,playerSpeedStage=state.playerSpeedStage,playerSpeedStageFactor=state.playerSpeedStageFactor,
    enemyMoveSpeed=state.enemyMoveSpeed,enemySpeedStage=state.enemySpeedStage,enemySpeedStageFactor=state.enemySpeedStageFactor,
    playerStatus=state.playerStatus,enemyStatus=state.enemyStatus,
    playerConfused=state.playerConfused==true,enemyConfused=state.enemyConfused==true,
    playerActionMessage=state.playerActionMessage,playerActionTimer=state.playerActionTimer,
    attackCooldown=state.attackCooldown,attackCooldownDuration=state.attackCooldownDuration,
    playerMoveCooldowns=state.playerMoveCooldowns,playerGlobalAttackLock=state.playerGlobalAttackLock,
    enemyAttackCooldown=state.enemyAttackCooldown,enemyAttackCooldownDuration=state.enemyAttackCooldownDuration,
    enemyMoveCooldowns=state.enemyMoveCooldowns,enemyGlobalAttackLock=state.enemyGlobalAttackLock,
    uiCursorActive=state.uiCursorActive==true,nativeModalActive=state.nativeModalActive==true,nativeModalName=state.nativeModalName,
    playerHitAnimating=state.playerHitAnimating==true,
    playerInvuln=state.playerInvuln,
    playerSwitchGuard=state.playerSwitchGuard,enemySwitchGuard=state.enemySwitchGuard,
    rolling=(tonumber(state.rollTimer) or 0)>0,rollTimer=state.rollTimer,rollCooldown=state.rollCooldown,rollIFrame=state.rollIFrame,
    airDashing=(tonumber(state.airDashTimer) or 0)>0,airDashTimer=state.airDashTimer,airDashIFrame=state.airDashIFrame,airDashUsed=state.airDashUsed==true,
    rollProgress=((tonumber(state.rollTimer) or 0)>0) and clamp((tonumber(state.rollElapsed) or 0)/R._ROLL_DURATION,0,1) or 0,
    rollAngle=((tonumber(state.rollTimer) or 0)>0) and (clamp((tonumber(state.rollElapsed) or 0)/R._ROLL_DURATION,0,1)*math.pi*2) or 0,
    rollVisualLift=((tonumber(state.rollTimer) or 0)>0) and (math.sin(math.pi*clamp((tonumber(state.rollElapsed) or 0)/R._ROLL_DURATION,0,1))*R._ROLL_VISUAL_LIFT) or 0,
    impactLockActive=state.impactLockActive==true,impactAttacker=state.impactAttacker,impactDefender=state.impactDefender,impactSource=state.impactSource,
    playerFainted=state.playerFainted==true,
    commandMovesOpen=state.commandMovesOpen==true,
    flightCapable=state.flightCapable==true,
    flightMode=state.flightMode==true,
    flightState=state.flightState,
    jumpCount=state.jumpCount,
    flapCooldown=state.flapClock,
    maxFlightY=state.maxFlightY,
    flightStamina=state.flightStamina,
    flightStaminaMax=state.flightStaminaMax,
    flightRechargeLock=state.flightRechargeLock,
    flightExhausted=state.flightExhausted==true,
    enemy={state.ex,state.ez},
    enemyFacing={state.enemyFacingX,state.enemyFacingZ},
    enemyMoving=state.enemyMoving==true,
    enemyAttackSerial=state.enemyAttackSerial,
    enemyAttackResult=state.enemyLastResult,
    facing={state.facingX,state.facingZ},
    arenaRadius=state.arenaRadius,
    bodyCollision=true,
    boundaryMode=state.boundaryMode,
    navWalls=state.nav and #(state.nav.walls or {}) or 0,
    cameraZoom=state.cameraZoom,
    actionMessage=state.actionMessage,
    actionMessageTimer=state.actionMessageTimer,
    actionMessageKind=state.actionMessageKind,
    hurtboxesVisible=false,
    tackleHitbox=false,
    attackResult=state.attackResult,
    attackMotionLock=state.attackMotionLock==true,
    tacklePP=state.attackPP,
    lastDamage=state.lastDamage,
    lastCrit=state.lastCrit,
    lastTypeMult=state.lastTypeMult,
    attacks="TPS/FPS center-ray aim with Gen I-III move targeting profiles, live circle/lane/cone telegraphs, independent WASD ground-cursor placement for GROUND_AOE/TRAP_ZONE moves, and LMB world-target lock; X rolls on the ground or air-dashes once per airtime with early i-frames; newly switched battlers have 0.5s attack+target immunity; grounded Space uses the existing forward dodge-leap/double-jump; hurt animation locks movement, followed by 1.0s movement-only invulnerability where attacks are blocked; each of the four moves owns its own power-scaled cooldown (Tackle 35 power = 1.0s; zero-power utility/status = 10s) plus a 0.8s post-attack shared recovery; Speed stages scale locomotion while Accuracy shrinks/expands attack geometry and Evasion shrinks/expands effective target size; status locomotion mirrors PAR/SLP/confusion while authoritative Gen1/Kanto resolution remains intact",
  }
end

function R.runtimeHealth()
  return {active=state.active==true,combatError=state.combatError,groundCursor=state.groundCursorOwnsWASD==true}
end

return R
