-- Pokemon Yellow Summer Beach House bridge for the Gold-owned Kanto excursion.
--
-- KantoDialogue deliberately suppresses arbitrary full-screen states so Yellow
-- text_asm cannot mutate Gold.  The Beach House is a safe exception: its
-- Surfin' Dude launches Gen1Recomp's engine-owned SurfingMinigame.  This module
-- keeps the minigame/high score Yellow-local while using Gold's real party to
-- decide whether a Pikachu knows SURF.

local V = ...
local M = {
  MAP_ID = "SUMMER_BEACH_HOUSE",
  HISCORE_KEY = "yellowSurfingHighScoreV1",
}

function M.surfingPikachu(game)
  local party = game and game.save and game.save.party or {}
  for _, mon in ipairs(party) do
    if mon and tostring(mon.species or ""):upper() == "PIKACHU" then
      for _, move in ipairs(mon.moves or {}) do
        local id = type(move) == "table" and (move.id or move.move or move.name) or move
        if tostring(id or ""):upper() == "SURF" then return mon end
      end
    end
  end
  return nil
end

function M.resetVisit(excursion, mapId)
  if tostring(mapId or "") == M.MAP_ID then return false end
  if type(excursion) ~= "table" then return false end
  excursion.surfinDudeAsked = false
  excursion.surfedThisVisit = false
  return true
end

local function text(ctx, label, fallback)
  if type(ctx.textByLabel) == "function" then
    local body = ctx.textByLabel(ctx.region, label)
    if body and body ~= "" then return body end
  end
  return fallback
end

local function show(ctx, body, onDone, opts)
  if type(ctx.showMessage) ~= "function" then return false end
  return ctx.showMessage(ctx.world, body, onDone, opts)
end

local function ask(ctx, body, onChoice)
  if type(ctx.askYesNo) ~= "function" then return false end
  return ctx.askYesNo(ctx.world, body, onChoice)
end

local function restoreHostMapMusic(world)
  local game = world and world.game
  if not (game and game.data and world and world.map and world.map.id) then return false end
  local okMusic, Music = pcall(require, "src.core.Music")
  if not (okMusic and Music and type(Music.playMap) == "function") then return false end
  return pcall(Music.playMap, game.data, world.map.id, false, false)
end

function M.startMinigame(ctx)
  local world = ctx and ctx.world
  local game = world and world.game
  if not (game and game.save and game.stack and type(game.stack.push) == "function") then
    return false
  end
  local okSurf, SurfingMinigame = pcall(require, "src.ui.SurfingMinigame")
  if not (okSurf and SurfingMinigame and type(SurfingMinigame.new) == "function") then
    return show(ctx, "Surfing Pikachu isn't available on this build.")
  end

  local get = type(ctx.persistenceGet) == "function" and ctx.persistenceGet
  local set = type(ctx.persistenceSet) == "function" and ctx.persistenceSet
  local oldGoldScore = game.save.surfingHighScore
  local localScore = get and get(M.HISCORE_KEY, 0) or 0
  game.save.surfingHighScore = math.max(0, tonumber(localScore) or 0)
  local restored = false
  local function finish()
    if restored then return end
    restored = true
    local score = math.max(0, tonumber(game.save.surfingHighScore) or 0)
    if set then set(M.HISCORE_KEY, score) end
    game.save.surfingHighScore = oldGoldScore
    if type(ctx.excursion) == "table" then ctx.excursion.surfedThisVisit = true end
    if type(ctx.twin) == "table" then
      ctx.twin.yellowSurfingPikachuFinishes =
        (ctx.twin.yellowSurfingPikachuFinishes or 0) + 1
    end
    restoreHostMapMusic(world)
  end

  local ok, screen = pcall(SurfingMinigame.new, game, finish)
  if not ok or not screen then
    game.save.surfingHighScore = oldGoldScore
    return show(ctx, "Surfing Pikachu couldn't start on this build.")
  end
  local pushed = pcall(game.stack.push, game.stack, screen)
  if not pushed then
    game.save.surfingHighScore = oldGoldScore
    return show(ctx, "Surfing Pikachu couldn't open on this build.")
  end
  if type(ctx.twin) == "table" then
    ctx.twin.yellowSurfingPikachuRuns = (ctx.twin.yellowSurfingPikachuRuns or 0) + 1
  end
  return true
end

local function printHighScore(ctx)
  local world = ctx.world
  local game = world and world.game
  if not (game and game.save) then return false end
  local okPrinter, Printer = pcall(require, "src.core.Printer")
  local okFont, Font = pcall(require, "src.render.Font")
  local okStrings, Strings = pcall(require, "src.core.Strings")
  if not (okPrinter and Printer and type(Printer.save) == "function"
      and okFont and Font and type(Font.draw) == "function"
      and love and love.graphics) then
    return show(ctx, "The BEACH HOUSE printer isn't available on this build.")
  end
  local get = type(ctx.persistenceGet) == "function" and ctx.persistenceGet
  local hi = math.max(0, tonumber(get and get(M.HISCORE_KEY, 0) or 0) or 0)
  local name = game.save.player and game.save.player.name or "RED"
  local saved, err = Printer.save("surf_hiscore", 160, 64, function()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, 160, 64)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("line", 2.5, 2.5, 155, 59)
    local str = okStrings and Strings or function(fmt, ...) return string.format(fmt, ...) end
    Font.draw(str("SUMMER BEACH HOUSE"), 8, 10)
    Font.draw(str("SURFING Hi-Score"), 8, 24)
    Font.draw(name, 8, 40)
    Font.draw(str("%d pts", hi), 96, 40)
  end)
  if saved then
    if type(ctx.twin) == "table" then
      ctx.twin.yellowSurfingPikachuPrints = (ctx.twin.yellowSurfingPikachuPrints or 0) + 1
    end
    return show(ctx, "Printed!\fSaved as\n" .. tostring(saved) .. "\vin the save folder.")
  end
  return show(ctx, "Printer error!\n" .. tostring(err or "unknown error"))
end

function M.interact(ctx)
  if type(ctx) ~= "table" or tostring(ctx.mapId or "") ~= M.MAP_ID or not ctx.obj then
    return false
  end
  local textConst = tostring(ctx.obj.text or "")
  local game = ctx.world and ctx.world.game
  if not game then return false end
  local pika = M.surfingPikachu(game)
  local excursion = type(ctx.excursion) == "table" and ctx.excursion or {}

  if textConst == "TEXT_SUMMERBEACHHOUSE_SURFINDUDE" then
    if not pika then
      return show(ctx, text(ctx, "_SummerBeachHouseSurfinDudeText4",
        "Dogs and burgers\non special today!"))
    end
    local first = excursion.surfinDudeAsked ~= true
    excursion.surfinDudeAsked = true
    local prompt = first
      and text(ctx, "_SummerBeachHouseSurfinDudeText1",
        "Whoa!\nYour PIKACHU knows\nhow to SURF!\fGive it a go?")
      or text(ctx, "_SummerBeachHouseSurfinDudeText3", "Wanna go SURF?")
    return ask(ctx, prompt, function(yes)
      if not yes then
        show(ctx, text(ctx, "_SummerBeachHouseSurfinDudeText2",
          "Come SURF anytime,\nmy friend!"))
        return
      end
      M.startMinigame(ctx)
    end)
  end

  if textConst == "TEXT_SUMMERBEACHHOUSE_PIKACHU" then
    local opts
    local okSound, Sound = pcall(require, "src.core.Sound")
    if okSound and Sound and type(Sound.playCry) == "function" then
      opts = { auto = { wait = true, delay = 0,
        sound = function() return Sound.playCry(game.data, "PIKACHU") end } }
    end
    return show(ctx, text(ctx, "_SummerBeachHousePikachuText", "PIKACHU: Pikaa!"), nil, opts)
  end

  local poster = textConst:match("^TEXT_SUMMERBEACHHOUSE_POSTER([123])$")
  if poster then
    return show(ctx, text(ctx,
      "_SummerBeachHousePoster" .. poster .. "Text" .. (pika and "1" or "2"),
      "A surfing poster."))
  end

  if textConst == "TEXT_SUMMERBEACHHOUSE_PRINTER" then
    if not pika then
      return show(ctx, text(ctx, "_SummerBeachHousePrinterText1",
        "It's some sort of\na machine..."))
    end
    return show(ctx, text(ctx, "_SummerBeachHousePrinterText2",
      "SUMMER BEACH HOUSE\nPRINTER, it says."), function()
        if not excursion.surfedThisVisit then return end
        ask(ctx, text(ctx, "_SummerBeachHousePrinterText3",
          "The Hi-Score is\nshown.\fPRINT it out?"), function(yes)
            if yes then printHighScore(ctx) end
          end)
      end)
  end
  return false
end

return M
