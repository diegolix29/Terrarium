-- Stadium-style presentation for Gold's shared dialogue and YES/NO boxes.
--
-- Presentation only: src.render.TextBox still owns substitution, pagination,
-- typewriter timing, CONT/page waits, auto text, choice spawning and input.
-- src.ui.ChoiceBox still owns selection and answer timing.  This module only
-- replaces draw() while CUSTOM UI / MENUS is enabled, so scripts and battle/
-- overworld state machines keep the engine's current behaviour exactly.
local V = ...
local mod = V and V.mod

local M = {
  installed = false,
  textDraws = 0,
  choiceDraws = 0,
  lastError = nil,
}

local fonts = {}

local function customUIEnabled()
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return true end
  local ok, value = pcall(options.get, options, "customUI")
  if not ok or value == nil then return true end
  return value ~= false
end

local function font(size)
  size = math.max(8, math.floor((tonumber(size) or 18) + 0.5))
  if fonts[size] ~= nil then return fonts[size] or nil end
  local G = love and love.graphics
  if not (G and type(G.newFont) == "function") then
    fonts[size] = false
    return nil
  end
  local ok, f = pcall(G.newFont, size)
  fonts[size] = ok and f or false
  return fonts[size] or nil
end

local function targetDimensions()
  local G = love and love.graphics
  if not G then return nil, nil end
  if type(G.getCanvas) == "function" then
    local ok, canvas = pcall(G.getCanvas)
    if ok and canvas and type(canvas.getDimensions) == "function" then
      local cw, ch = canvas:getDimensions()
      if cw and ch and cw > 0 and ch > 0 then return cw, ch end
    end
  end
  if type(G.getDimensions) == "function" then return G.getDimensions() end
  return nil, nil
end

local function uiScaleFor(ww, wh)
  local helper = mod and mod.exports and mod.exports.mobileUiScale
  if helper and type(helper.scale) == "function" then
    return helper.scale(ww, wh, 0.55, 1.40)
  end
  return math.max(0.55, math.min(1.75, math.min(ww / 800, wh / 600)))
end

local function roundRect(mode, x, y, w, h, r)
  love.graphics.rectangle(mode, x, y, w, h, r, r)
end

local function panel(x, y, w, h, r, s, alpha)
  local G = love.graphics
  G.setColor(0.018, 0.026, 0.045, alpha or 0.86)
  roundRect("fill", x, y, w, h, r)
  G.setColor(1, 1, 1, 0.23)
  G.setLineWidth(math.max(1, 2 * s))
  roundRect("line", x, y, w, h, r)
end

local function geometry(ww, wh)
  local s = uiScaleFor(ww, wh)
  local margin = math.max(12 * s, wh * 0.022)
  local w = math.min(ww - margin * 2, math.max(ww * 0.72, 650 * s))
  local h = math.max(104 * s, math.min(190 * s, wh * 0.205))
  if h > wh - margin * 2 then h = wh - margin * 2 end
  local x = math.floor((ww - w) * 0.5 + 0.5)
  local y = math.floor(wh - h - margin + 0.5)
  local r = math.max(13 * s, math.min(28 * s, h * 0.18))
  local padX = math.max(22 * s, w * 0.035)
  local padY = math.max(15 * s, h * 0.15)
  return {
    s = s, margin = margin, x = x, y = y, w = w, h = h,
    r = r, padX = padX, padY = padY,
  }
end

-- TextBox.shown stores glyph codes because the native renderer is tile based.
-- The original page strings are still on self.pages, so rebuild exactly the
-- typed prefix from Font.split() rather than trying to reverse-map glyph codes.
local function shownLineText(box, slot, Font)
  local page = box.pages and box.pages[box.pageIndex]
  local shown = box.shown and box.shown[slot]
  if type(page) ~= "table" or type(shown) ~= "table" then return "" end
  local shownCount = #box.shown
  local lineIndex = (tonumber(box.lineIndex) or 1) - (shownCount - slot)
  local source = tostring(page[lineIndex] or "")
  local count = #shown
  if count <= 0 or source == "" then return "" end
  local spans = Font.split(source)
  local last = spans[math.min(count, #spans)]
  return last and source:sub(1, last.to) or ""
end

local function textBoxDraw(self, UIVisibility, Font)
  if not UIVisibility.bottomVisible(self, true) then return end
  local ww, wh = targetDimensions()
  if not ww or not wh then return end
  local geo = geometry(ww, wh)
  local G = love.graphics

  G.push("all")
  G.origin()
  panel(geo.x, geo.y, geo.w, geo.h, geo.r, geo.s, 0.87)

  -- A subtle inner lane mirrors the selected-row capsules used by the pause,
  -- party, Pokédex and battle-command UIs without turning dialogue into a menu.
  local laneX = geo.x + geo.padX * 0.55
  local laneY = geo.y + geo.padY * 0.48
  local laneW = geo.w - geo.padX * 1.10
  local laneH = geo.h - geo.padY * 1.10
  G.setColor(1, 1, 1, 0.035)
  roundRect("fill", laneX, laneY, laneW, laneH, geo.r * 0.58)

  local textSize = math.max(17 * geo.s, math.min(30 * geo.s, geo.h * 0.205))
  local f = font(textSize)
  if f then G.setFont(f) end
  G.setColor(1, 1, 1, 0.97)

  local lineStep = math.max(textSize * 1.42, geo.h * 0.265)
  local baseY = geo.y + geo.padY
  local off = tonumber(self.scrollPx) or 0
  if off > 0 then
    -- Match TextBox.draw exactly: decrement first, then draw the retained line
    -- at that remaining offset. Only the pixels are scaled into window space.
    off = off - 2
    self.scrollPx = off > 0 and off or nil
  end
  local scrollOffset = (math.max(0, off) / 8) * lineStep

  for i = 1, #(self.shown or {}) do
    local text = shownLineText(self, i, Font)
    local y = baseY + (i - 1) * lineStep + (i == 1 and scrollOffset or 0)
    G.print(text, geo.x + geo.padX, y)
  end

  local manualWait = self.waiting
    or (self.done and not self.choice and not self.auto and not self.stay)
  if manualWait then
    local meta = font(math.max(10 * geo.s, math.min(15 * geo.s, geo.h * 0.10)))
    if meta then G.setFont(meta) end
    G.setColor(1, 1, 1, 0.56)
    local hint = "A / B  CONTINUE"
    local hintW = G.getFont():getWidth(hint)
    G.print(hint, geo.x + geo.w - geo.padX - hintW,
            geo.y + geo.h - geo.padY * 0.72)

    if (tonumber(self.blink) or 0) < 30 then
      local cx = geo.x + geo.w - geo.padX * 0.52
      local cy = geo.y + geo.h * 0.48
      local size = math.max(5 * geo.s, geo.h * 0.043)
      G.setColor(1, 1, 1, 0.88)
      G.polygon("fill", cx - size, cy - size * 0.45,
                        cx + size, cy - size * 0.45,
                        cx, cy + size * 0.72)
    end
  end

  G.setColor(1, 1, 1, 1)
  G.pop()
  M.textDraws = M.textDraws + 1
end

local function choiceBoxDraw(self, UIVisibility)
  if not UIVisibility.bottomVisible(self, false) then return end
  local ww, wh = targetDimensions()
  if not ww or not wh then return end
  local base = geometry(ww, wh)
  local G = love.graphics
  local s = base.s

  local w = math.max(170 * s, math.min(260 * s, ww * 0.24))
  local rowH = math.max(38 * s, math.min(58 * s, wh * 0.070))
  local gap = math.max(7 * s, wh * 0.008)
  local headerH = math.max(30 * s, rowH * 0.72)
  local h = headerH + rowH * 2 + gap * 3
  local margin = base.margin
  local x = ww - w - margin
  local y
  if self.anchor == "bottom" then
    y = base.y - h - gap
    if y < margin then y = margin end
  else
    y = math.max(margin, math.floor((wh - h) * 0.48))
  end
  local r = math.max(12 * s, h * 0.10)

  G.push("all")
  G.origin()
  panel(x, y, w, h, r, s, 0.90)

  local meta = font(math.max(10 * s, rowH * 0.26))
  if meta then G.setFont(meta) end
  G.setColor(1, 1, 1, 0.52)
  G.print("CHOOSE", x + gap * 1.7, y + headerH * 0.28)

  local name = font(math.max(15 * s, rowH * 0.42))
  local labels = { "YES", "NO" }
  for i = 1, 2 do
    local ry = y + headerH + gap + (i - 1) * (rowH + gap)
    local on = tonumber(self.index) == i
    G.setColor(1, 1, 1, on and 0.17 or 0.065)
    roundRect("fill", x + gap, ry, w - gap * 2, rowH, r * 0.52)
    if on then
      G.setColor(1, 1, 1, 0.78)
      G.setLineWidth(math.max(1, 2 * s))
      roundRect("line", x + gap, ry, w - gap * 2, rowH, r * 0.52)
    end
    if name then G.setFont(name) end
    G.setColor(1, 1, 1, 0.96)
    G.print(labels[i], x + gap * 2.2, ry + rowH * 0.26)
  end

  G.setColor(1, 1, 1, 1)
  G.pop()
  M.choiceDraws = M.choiceDraws + 1
end

function M.install()
  if M.installed then return true end
  local okText, TextBox = pcall(require, "src.render.TextBox")
  local okChoice, ChoiceBox = pcall(require, "src.ui.ChoiceBox")
  local okFont, Font = pcall(require, "src.render.Font")
  local okVisibility, UIVisibility = pcall(require, "src.battle.UIVisibility")
  if not (okText and type(TextBox) == "table" and type(TextBox.draw) == "function") then
    return false, "src.render.TextBox.draw unavailable"
  end
  if not (okChoice and type(ChoiceBox) == "table" and type(ChoiceBox.draw) == "function") then
    return false, "src.ui.ChoiceBox.draw unavailable"
  end
  if not (okFont and type(Font) == "table" and type(Font.split) == "function") then
    return false, "src.render.Font.split unavailable"
  end
  if not (okVisibility and type(UIVisibility) == "table"
      and type(UIVisibility.bottomVisible) == "function") then
    return false, "src.battle.UIVisibility.bottomVisible unavailable"
  end

  if not TextBox._stadium2GlassDrawPatched then
    local native = TextBox.draw
    TextBox.draw = function(self, ...)
      if not customUIEnabled() then return native(self, ...) end
      return textBoxDraw(self, UIVisibility, Font)
    end
    TextBox._stadium2GlassDrawPatched = true
    TextBox._stadium2GlassNativeDraw = native
  end

  if not ChoiceBox._stadium2GlassDrawPatched then
    local native = ChoiceBox.draw
    ChoiceBox.draw = function(self, ...)
      if not customUIEnabled() then return native(self, ...) end
      return choiceBoxDraw(self, UIVisibility)
    end
    ChoiceBox._stadium2GlassDrawPatched = true
    ChoiceBox._stadium2GlassNativeDraw = native
  end

  M.installed = true
  M.lastError = nil
  return true
end

function M.status()
  return {
    installed = M.installed,
    textDraws = M.textDraws,
    choiceDraws = M.choiceDraws,
    lastError = M.lastError,
  }
end

return M
