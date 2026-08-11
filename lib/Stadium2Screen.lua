-- STADIUM 2 battles: the one-time build, on screen.
--
-- Similar to StadiumScreen but for Pokemon Stadium 2 (251 Pokemon)

local V = ...

local Stadium2Install = V.require("Stadium2Install")

local Stadium2Screen = {}
Stadium2Screen.__index = Stadium2Screen

local W, H = 160, 144
Stadium2Screen.HOLD = 1.1

local Font = nil
local function font()
  if Font then return Font end
  local ok, F = pcall(require, "src.render.Font")
  if ok then Font = F end
  return Font
end

-- ------- drawing text the way StadiumScreen.lua actually does it
--
-- The previous version of this file called `f:drawCode(str, x, y, w, align)`,
-- which is not a real API on this module -- src/render/Font.lua's drawCode /
-- pageFor is the engine's source-code pager, built for paging through lines
-- of Lua in a debug view, not for laying out a UI string. Feeding it a plain
-- width number and an align string where it expects its own internal table
-- shape is what crashed it ("attempt to compare number with table" inside
-- pageFor).
--
-- StadiumScreen.lua (Stadium 1's equivalent screen, which has never hit this)
-- never calls drawCode at all -- it uses the plain `Font.draw(str, x, y)` /
-- `Font.width(str)` pair and does its own centring and word-wrap. Doing the
-- same here.
local function text(str, x, y)
  local F = font()
  if not F then return end
  F.draw(str, math.floor(x), math.floor(y))
end

local function textWidth(str)
  local F = font()
  if F and F.width then return F.width(str) end
  return #tostring(str) * 8
end

local function centred(str, y)
  if not str or str == "" then return end
  text(str, (W - textWidth(str)) / 2, y)
end

-- Break a string into lines that fit on word boundaries, never more than
-- `limit` of them. Same fixed-width reasoning as StadiumScreen.lua: these are
-- 1-bit 8x8 glyphs, so long strings get more LINES instead of a shrink.
local COLS = 20
local function wrapped(str, limit, cols)
  limit = limit or 2
  cols = cols or COLS
  local lines, line = {}, nil
  local function push(t)
    if #lines < limit then lines[#lines + 1] = t end
  end
  for word in tostring(str):gmatch("%S+") do
    local try = line and (line .. " " .. word) or word
    if #try <= cols then
      line = try
    else
      if line then push(line) end
      while #word > cols do
        push(word:sub(1, cols))
        word = word:sub(cols + 1)
      end
      line = word
    end
    if #lines >= limit then break end
  end
  if line then push(line) end
  return lines
end

local function speciesName(dex)
  local ok, names = pcall(require, "src.data.names")
  if ok and names and names[dex] then return names[dex] end
  return "Pokemon " .. tostring(dex)
end

function Stadium2Screen.new(game, forROM)
  local self = setmetatable({}, Stadium2Screen)
  self.game = game
  self.note = forROM and true or false
  self.hold = 0
  return self
end

function Stadium2Screen.newNote(game, title, subtitle, hint)
  local self = Stadium2Screen.new(game, true)
  self.title = title
  self.subtitle = subtitle
  self.hint = hint
  return self
end

function Stadium2Screen:update(dt)
  if self.note then
    self.hold = self.hold + dt
    if self.hold >= Stadium2Screen.HOLD then
      if self.game and self.game.stack and self.game.stack:top() == self then
        self.game.stack:pop()
      end
    end
    return
  end

  local status = Stadium2Install.status
  if status.state == "building" then
    -- Advance the job by exactly one species this frame
    local more = Stadium2Install.step()
    if not more then
      self.hold = 0
    end
    return
  end

  self.hold = self.hold + 1 / 60
  local wait = Stadium2Screen.HOLD
  if status.state == "failed" then
    wait = Stadium2Screen.HOLD * 4
  end
  if self.hold >= wait then
    if self.game and self.game.stack and self.game.stack:top() == self then
      self.game.stack:pop()
    end
  end
end

local function pop(self)
  if self.game and self.game.stack and self.game.stack:top() == self then
    self.game.stack:pop()
  end
end

function Stadium2Screen:onKeyPressed(key)
  if self.note then pop(self) return true end
  if key == "escape" or key == "x" or key == "backspace" then
    pop(self)
    return true
  end
  return false
end

function Stadium2Screen:draw()
  if not font() then return end

  local graphics = love and love.graphics
  if not graphics then return end

  graphics.push("all")
  graphics.origin()

  -- Background
  graphics.setColor(1, 1, 1, 1)
  graphics.rectangle("fill", 0, 0, W, H)

  if self.note then
    -- Note screen
    graphics.setColor(0, 0, 0, 1)
    centred(self.title, 20)
    for i, line in ipairs(wrapped(self.subtitle or "", 2)) do
      centred(line, 35 + (i - 1) * 10)
    end
    if self.hint then
      for i, line in ipairs(wrapped(self.hint, 2)) do
        centred(line, 55 + (i - 1) * 10)
      end
    end
  else
    -- Build screen
    local status = Stadium2Install.status

    graphics.setColor(0, 0, 0, 1)
    centred("STADIUM 2 EXTRACTION", 20)

    -- Progress bar
    local barW = W - 20
    local barH = 8
    local barX = 10
    local barY = 40

    graphics.setColor(0.78, 0.78, 0.78, 1)
    graphics.rectangle("fill", barX, barY, barW, barH)

    if status.total > 0 then
      local fillW = (status.done / status.total) * barW
      graphics.setColor(0, 0.59, 0, 1)
      graphics.rectangle("fill", barX, barY, fillW, barH)
    end

    -- Species name
    graphics.setColor(0, 0, 0, 1)
    if status.species then
      local name = speciesName(status.species)
      centred(name, 55)
    end

    -- Count
    centred(string.format("%d / %d", status.done, status.total), 65)

    -- Done/Failed message
    if status.state == "done" then
      graphics.setColor(0, 0.59, 0, 1)
      centred("DONE", 90)
    elseif status.state == "failed" then
      graphics.setColor(0.78, 0, 0, 1)
      centred("FAILED", 90)
      if status.error then
        for i, line in ipairs(wrapped(status.error, 2)) do
          centred(line, 100 + (i - 1) * 10)
        end
      end
    end
  end

  graphics.pop()
end

function Stadium2Screen.maybePush()
  local status = Stadium2Install.status
  if status.state == "building" then
    local ok, Game = pcall(require, "src.core.Game")
    if ok and Game and Game.stack then
      -- Now that Stadium2Install.step() (see Stadium2Screen:update) spreads
      -- the build across many frames instead of one blocking call, state
      -- stays "building" for as long as the build runs -- and this is
      -- polled every single one of those frames from main.lua's always-tick.
      -- Pushing unconditionally would stack a fresh copy of this screen on
      -- every frame for the whole build. Only push if a build screen is not
      -- already on top.
      local top = Game.stack.top and Game.stack:top()
      if getmetatable(top) ~= Stadium2Screen then
        Game.stack:push(Stadium2Screen.new(Game, false))
      end
    end
  end
end

return Stadium2Screen