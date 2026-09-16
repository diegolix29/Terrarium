-- Gen3-specific battle settings module
-- This handles the different menu system in Gen3 games (Ruby/Sapphire/Emerald/FireRed/LeafGreen)

local S={}
local installed=false
local modRef,Trainer,Music,ArenaCatalog,BattleMenuUI,CacheManager,TrainerRoster,Compat,AudioFidelity

local function prefs(game)
  if not (game and game.save) then
    return {
      music="normal",arena="auto",arenasEnabled=true,cameraEnabled=true,pokemonModelsEnabled=true,
      playerModel="red",enemyTrainerModel="auto",rivalModel="leaf",
      doubleBattlesEnabled=true,abilitiesEnabled=true,freeLookEnabled=true,
      autoProgressEnabled=true,bossIntroEnabled=false,battleSoundsEnabled=true,
    }
  end
  local p=game.save.colosseumBattle
  if type(p)~="table" then p={}; game.save.colosseumBattle=p end
  if p.arenasEnabled==nil then p.arenasEnabled=true end
  p.arenasEnabled=p.arenasEnabled and true or false
  if p.cameraEnabled==nil then p.cameraEnabled=true end
  p.cameraEnabled=p.cameraEnabled and true or false
  if p.pokemonModelsEnabled==nil then p.pokemonModelsEnabled=true end
  p.pokemonModelsEnabled=p.pokemonModelsEnabled and true or false
  if p.battleSoundsEnabled==nil then p.battleSoundsEnabled=true end
  p.battleSoundsEnabled=p.battleSoundsEnabled==true
  if p.bossIntroEnabled==nil then p.bossIntroEnabled=false end
  p.bossIntroEnabled=p.bossIntroEnabled==true
  if p.doubleBattlesEnabled==nil then p.doubleBattlesEnabled=true end
  p.doubleBattlesEnabled=p.doubleBattlesEnabled==true
  if p.abilitiesEnabled==nil then p.abilitiesEnabled=true end
  p.abilitiesEnabled=p.abilitiesEnabled==true
  if p.freeLookEnabled==nil then p.freeLookEnabled=true end
  if p.autoProgressEnabled==nil then p.autoProgressEnabled=true end
  local legacy=p.sprites
  if p.playerModel==nil then
    p.playerModel=(p.playerTrainerModel==false or legacy=="off") and "off" or "red"
  end
  if p.enemyTrainerModel==nil then
    p.enemyTrainerModel=(p.enemyTrainerModels==false or legacy=="off" or legacy=="player") and "off" or "auto"
  end
  if p.rivalModel==nil then p.rivalModel="leaf" end
  if TrainerRoster and TrainerRoster.normalizeChoice then
    p.playerModel=TrainerRoster.normalizeChoice(p.playerModel,"player")
    p.enemyTrainerModel=TrainerRoster.normalizeChoice(p.enemyTrainerModel,"enemy")
    p.rivalModel=TrainerRoster.normalizeChoice(p.rivalModel,"rival")
  else
    p.playerModel=tostring(p.playerModel or "red"):lower()
    p.enemyTrainerModel=tostring(p.enemyTrainerModel or "auto"):lower()
    p.rivalModel=tostring(p.rivalModel or "leaf"):lower()
  end
  p.playerTrainerModel=p.playerModel~="off"
  p.enemyTrainerModels=p.enemyTrainerModel~="off"
  local validMusic={random=true,normal=true,first=true,cipher_peon=true,miror_b=true,cipher_admin=true,mirakle_b=true,semifinal=true,final=true,link1=true,link2=true,link3=true,original=true}
  if p.music=="colosseum" or p.music=="wild" or p.music=="trainer" or p.music=="gym" then p.music="normal" end
  if not validMusic[p.music] then p.music="normal" end
  local validArena={auto=true,random=true,water=true,orre_colosseum=true,relic_chamber=true,relic_cave=true,outskirts=true,pyrite_colosseum=true,deep_colosseum=true,realgam_colosseum=true,outdoor_wild=true,mt_battle_summit=true,cipher_lab_underground=true}
  if not validArena[p.arena] then p.arena="auto" end
  return p
end

-- Builds the Colosseum battle-settings Menu instance but does NOT push it.
local function buildBattleMenu(game)
  if modRef and modRef.log then modRef.log:info("Building Gen3 battle settings menu") end

  local ok,Menu=pcall(require,"src.ui.Menu")
  if not ok or not Menu then
    if modRef and modRef.log then modRef.log:warn("Failed to load src.ui.Menu for Gen3 battle settings") end
    return nil
  end

  local p=prefs(game)
  if ArenaCatalog and ArenaCatalog.sync then ArenaCatalog.sync(game) end
  if ArenaCatalog and ArenaCatalog.selected then p.arena=ArenaCatalog.selected(game) end

  local function refresh()
    if modRef and modRef.log then modRef.log:info("Refreshing Gen3 battle settings menu") end
  end

  -- Helper to cycle through lists (e.g. for arenas, music, player models)
  local function cycle(list, current)
      for i, v in ipairs(list) do
          if v == current then return list[(i % #list) + 1] end
      end
      return list[1]
  end

  -- ===========================
  -- TOGGLE DEFINITIONS
  -- ===========================

  local arenaToggle={keepOpen=true,label="COLOSSEUM ARENAS  "..(p.arenasEnabled and "ON" or "OFF")}
  arenaToggle.onSelect=function()
    p.arenasEnabled=not p.arenasEnabled
    arenaToggle.label="COLOSSEUM ARENAS  "..(p.arenasEnabled and "ON" or "OFF")
    if ArenaCatalog and ArenaCatalog.setEnabled then ArenaCatalog.setEnabled(game,p.arenasEnabled) end
    refresh()
  end

  local arenaOpts = {"auto", "random", "water", "orre_colosseum", "relic_chamber", "relic_cave", "outskirts", "pyrite_colosseum", "deep_colosseum", "realgam_colosseum", "outdoor_wild", "mt_battle_summit", "cipher_lab_underground"}
  local arenaSelectToggle = {keepOpen=true, label="ARENA  "..string.upper(p.arena)}
  arenaSelectToggle.onSelect = function()
    p.arena = cycle(arenaOpts, p.arena)
    arenaSelectToggle.label = "ARENA  "..string.upper(p.arena)
    refresh()
  end

  local cameraToggle={keepOpen=true,label="COLOSSEUM CAMERA  "..(p.cameraEnabled and "ON" or "OFF")}
  cameraToggle.onSelect=function()
    p.cameraEnabled=not p.cameraEnabled
    cameraToggle.label="COLOSSEUM CAMERA  "..(p.cameraEnabled and "ON" or "OFF")
    refresh()
  end

  local freeLookToggle={keepOpen=true,label="FREE LOOK  "..(p.freeLookEnabled and "ON" or "OFF")}
  freeLookToggle.onSelect=function()
    p.freeLookEnabled=not p.freeLookEnabled
    freeLookToggle.label="FREE LOOK  "..(p.freeLookEnabled and "ON" or "OFF")
    refresh()
  end

  local modelsToggle={keepOpen=true,label="COLOSSEUM MODELS  "..(p.pokemonModelsEnabled and "ON" or "OFF")}
  modelsToggle.onSelect=function()
    p.pokemonModelsEnabled=not p.pokemonModelsEnabled
    modelsToggle.label="COLOSSEUM MODELS  "..(p.pokemonModelsEnabled and "ON" or "OFF")
    refresh()
  end
  
  local playerOpts = {"red", "leaf", "brendan", "may", "off"}
  local playerModelToggle = {keepOpen=true, label="PLAYER MODEL  "..string.upper(p.playerModel)}
  playerModelToggle.onSelect = function()
    p.playerModel = cycle(playerOpts, p.playerModel)
    p.playerTrainerModel = (p.playerModel ~= "off")
    playerModelToggle.label = "PLAYER MODEL  "..string.upper(p.playerModel)
    refresh()
  end
  
  local enemyOpts = {"auto", "off"}
  local enemyModelToggle = {keepOpen=true, label="ENEMY MODEL  "..string.upper(p.enemyTrainerModel)}
  enemyModelToggle.onSelect = function()
    p.enemyTrainerModel = cycle(enemyOpts, p.enemyTrainerModel)
    p.enemyTrainerModels = (p.enemyTrainerModel ~= "off")
    enemyModelToggle.label = "ENEMY MODEL  "..string.upper(p.enemyTrainerModel)
    refresh()
  end

  local soundsToggle={keepOpen=true,label="BATTLE SOUNDS  "..(p.battleSoundsEnabled and "COLOSSEUM" or "ORIGINAL")}
  soundsToggle.onSelect=function()
    p.battleSoundsEnabled=not p.battleSoundsEnabled
    soundsToggle.label="BATTLE SOUNDS  "..(p.battleSoundsEnabled and "COLOSSEUM" or "ORIGINAL")
    refresh()
  end

  local musicOpts = {"normal", "random", "first", "cipher_peon", "miror_b", "cipher_admin", "mirakle_b", "semifinal", "final", "link1", "link2", "link3", "original"}
  local musicToggle = {keepOpen=true, label="MUSIC  "..string.upper(p.music)}
  musicToggle.onSelect = function()
    p.music = cycle(musicOpts, p.music)
    musicToggle.label = "MUSIC  "..string.upper(p.music)
    refresh()
  end

  local doubleBattlesToggle = {keepOpen=true, label="DOUBLE BATTLES  "..(p.doubleBattlesEnabled and "ON" or "OFF")}
  doubleBattlesToggle.onSelect = function()
    p.doubleBattlesEnabled = not p.doubleBattlesEnabled
    doubleBattlesToggle.label = "DOUBLE BATTLES  "..(p.doubleBattlesEnabled and "ON" or "OFF")
    refresh()
  end

  local abilitiesToggle = {keepOpen=true, label="ABILITIES  "..(p.abilitiesEnabled and "ON" or "OFF")}
  abilitiesToggle.onSelect = function()
    p.abilitiesEnabled = not p.abilitiesEnabled
    abilitiesToggle.label = "ABILITIES  "..(p.abilitiesEnabled and "ON" or "OFF")
    refresh()
  end

  local autoProgressToggle = {keepOpen=true, label="AUTO PROGRESS  "..(p.autoProgressEnabled and "ON" or "OFF")}
  autoProgressToggle.onSelect = function()
    p.autoProgressEnabled = not p.autoProgressEnabled
    autoProgressToggle.label = "AUTO PROGRESS  "..(p.autoProgressEnabled and "ON" or "OFF")
    refresh()
  end

  local bossIntroToggle = {keepOpen=true, label="BOSS INTROS  "..(p.bossIntroEnabled and "ON" or "OFF")}
  bossIntroToggle.onSelect = function()
    p.bossIntroEnabled = not p.bossIntroEnabled
    bossIntroToggle.label = "BOSS INTROS  "..(p.bossIntroEnabled and "ON" or "OFF")
    refresh()
  end

  -- Assemble all active items into our UI array
  local mainRows={
    arenaToggle,
    arenaSelectToggle,
    cameraToggle,
    freeLookToggle,
    modelsToggle,
    playerModelToggle,
    enemyModelToggle,
    soundsToggle,
    musicToggle,
    doubleBattlesToggle,
    abilitiesToggle,
    autoProgressToggle,
    bossIntroToggle,
    {label="BACK",onSelect=function()
      if modRef and modRef.log then modRef.log:info("BACK selected in Gen3 battle settings") end
      if game.stack and type(game.stack.pop)=="function" then
        game.stack:pop()
      end
    end}
  }

  local ok2, menu = pcall(function()
    return Menu.new(game,mainRows,{tx=1,ty=2,tw=24,maxVisible=10,onCancel=function()
      if modRef and modRef.log then modRef.log:info("CANCEL in Gen3 battle settings") end
      if game.stack and type(game.stack.pop)=="function" then
        game.stack:pop()
      end
    end})
  end)

  if not ok2 then
    if modRef and modRef.log then modRef.log:warn("Failed to create Gen3 battle settings menu: " .. tostring(menu)) end
    return nil
  end

  menu.screenId="CbeBattleSettingsGen3"

  if BattleMenuUI and BattleMenuUI.mark then
    BattleMenuUI.mark(menu,"COLOSSEUM BATTLE",mainRows,10,"ENVIRONMENT / CAMERA / POKEMON / AUDIO")
  end

  if modRef and modRef.log then modRef.log:info("Gen3 battle settings menu created successfully") end
  return menu
end

-- Pushes the battle-settings menu directly.
local function openBattleMenu(game)
  local menu = buildBattleMenu(game)
  if not menu then return end
  local ok, err = pcall(function() game.stack:push(menu) end)
  if not ok then
    if modRef and modRef.log then modRef.log:warn("Failed to push Gen3 battle settings menu: " .. tostring(err)) end
  end
end

function S.install(mod,trainer,music,arenaCatalog,battleMenuUI,cacheManager,trainerRoster,compat,audioFidelity)
  if installed then
    if mod.log then mod.log:info("Gen3 battle settings already installed") end
    return true
  end

  if mod.log then mod.log:info("Gen3 battle settings install function called") end

  modRef,Trainer,Music,ArenaCatalog,BattleMenuUI,CacheManager,TrainerRoster,Compat,AudioFidelity=mod,trainer,music,arenaCatalog,battleMenuUI,cacheManager,trainerRoster,compat,audioFidelity
  if BattleMenuUI and BattleMenuUI.install then BattleMenuUI.install() end
  if not (mod and mod.hooks and type(mod.hooks.wrap)=="function") then
    if mod.log then mod.log:warn("Gen3 battle settings install failed: mod.hooks.wrap not available") end
    return false
  end

  if mod.log then mod.log:info("Installing Gen3 battle settings") end

  -- Store the battle menu opener globally for keybind access
  _G.DRAMATIC_GEN3_BATTLE_MENU_OPENER = function(g)
    if mod.log then mod.log:info("Global Gen3 battle menu opener called") end
    openBattleMenu(g or (modRef and modRef.game))
  end

  -- Register console command
  local okCmd, cmdErr = pcall(function()
    if mod and mod.commands and mod.commands.register then
      mod.commands.register("battle_settings", function()
        if mod.log then mod.log:info("Battle settings console command called") end
        openBattleMenu(modRef and modRef.game)
      end, "Open Colosseum battle settings")
      if mod.log then mod.log:info("Gen3 battle settings console command registered") end
    end
  end)

  if not okCmd then
    if mod.log then mod.log:warn("Failed to register console command: " .. tostring(cmdErr)) end
  end

  local success = false

  local ok, err = pcall(function()
    mod.hooks:wrap("ui.start_menu.items",function(next,game,items)
      local out=next(game,items)
      if type(out)~="table" then out=items end

      for _,entry in ipairs(out) do
        if entry.__colosseumBattleEntryGen3 or tostring(entry.label or ""):upper()=="BATTLE" then
          return out
        end
      end

      local at=#out+1
      for i,entry in ipairs(out) do
        if tostring(entry.label or ""):upper()=="OPTION" then at=i;break end
      end

      if game and game.data then
        game.data.screens = game.data.screens or {}
        game.data.screens["CbeBattleSettingsGen3"] = { new = function(g) return buildBattleMenu(g) end }
      end

      table.insert(out,at,{
        label="BATTLE",
        __colosseumBattleEntryGen3=true,
        screen="CbeBattleSettingsGen3",
      })

      if mod.log then mod.log:info("BATTLE entry inserted at position " .. at) end
      return out
    end,650)
  end)

  if ok then
    success = true
    if mod.log then mod.log:info("Gen3 battle settings ui.start_menu.items hook installed successfully") end
  else
    if mod.log then mod.log:warn("Gen3 battle settings ui.start_menu.items hook failed: " .. tostring(err)) end
  end

  installed = success
  return success
end

function S.prefs(game) return prefs(game) end
function S.cameraEnabled(game) return prefs(game or (modRef and modRef.game)).cameraEnabled~=false end
function S.pokemonModelsEnabled(game) return prefs(game or (modRef and modRef.game)).pokemonModelsEnabled~=false end
function S.abilitiesEnabled(game) return prefs(game or (modRef and modRef.game)).abilitiesEnabled==true end
function S.setCameraEnabled(game,value)
  local p=prefs(game or (modRef and modRef.game)); p.cameraEnabled=value~=false; return p.cameraEnabled
end
function S.status(game)
  local p=prefs(game or (modRef and modRef.game))
  return {
    installed=installed,arenasEnabled=p.arenasEnabled,cameraEnabled=p.cameraEnabled,pokemonModelsEnabled=p.pokemonModelsEnabled,
    battleSoundsEnabled=p.battleSoundsEnabled,freeLookEnabled=p.freeLookEnabled,autoProgressEnabled=p.autoProgressEnabled,bossIntroEnabled=p.bossIntroEnabled,doubleBattlesEnabled=p.doubleBattlesEnabled,
    abilitiesEnabled=p.abilitiesEnabled,
    music=p.music,musicLabel=Music and Music.themeLabel and Music.themeLabel(game,p.music),
    arena=p.arena,playerModel=p.playerModel,enemyTrainerModel=p.enemyTrainerModel,rivalModel=p.rivalModel,
    playerTrainerModel=p.playerTrainerModel,enemyTrainerModels=p.enemyTrainerModels,
    cache=CacheManager and CacheManager.status and CacheManager.status() or nil,
    audioFidelity=AudioFidelity and AudioFidelity.status(modRef) or nil,
  }
end

return S