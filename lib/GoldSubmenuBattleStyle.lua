-- Stadium 2 custom-battle-style renderers for the built-in Gold submenus that
-- are opened from the Gen-2 START / pause menu.
--
-- IMPORTANT: this module deliberately patches PRESENTATION ONLY.  Every screen
-- keeps its original update/action/save/item/party/Pokegear/Pokedex logic.
-- Most constructors are tagged only when created from the real Gen-2 START
-- menu.  PartyMenu and SummaryMenu are intentionally universal in v0.2.42 so
-- their 3D presentation works from pause, battle fallbacks and item/party flows
-- regardless of stack-construction timing on Gen1Recomp v0.1.83.
--
-- The skin matches lib/BattleControllerUI.lua's custom PACK/PKMN selectors:
--   panel fill  (0.018, 0.026, 0.045)
--   normal row  white @ 0.07
--   selected    white @ 0.17 + white @ 0.72 outline
--   rounded glass panels, thin white borders, compact title/meta hierarchy.
local V = ...
local mod = V and V.mod

local M = {
  installed = false,
  draws = 0,
  tagged = 0,
  lastError = nil,
  targets = {},
}

local fonts = {}
local StartMenuClass = nil
local SaveModule = nil
local PartyModelPreview = nil

local function controllerPrompt(text)
  local C = mod and mod.exports and mod.exports.controllerLayout
  if C and type(C.prompt) == "function" then
    local ok, value = pcall(C.prompt, text)
    if ok and value then return value end
  end
  return tostring(text or "")
end

local function customUIEnabled()
  local options = mod and mod.options
  if not (options and type(options.get) == "function") then return true end
  local ok, value = pcall(options.get, options, "customUI")
  if not ok or value == nil then return true end
  return value ~= false
end

local function partyPreviewModule()
  if PartyModelPreview == false then return nil end
  if PartyModelPreview then return PartyModelPreview end
  if not (V and type(V.require) == "function") then
    PartyModelPreview = false
    return nil
  end
  local ok, preview = pcall(V.require, "PartyModelPreview")
  if ok and type(preview) == "table" then
    PartyModelPreview = preview
    return preview
  end
  PartyModelPreview = false
  M.lastError = "PartyModelPreview: " .. tostring(preview)
  return nil
end

local function font(size)
  size = math.max(5, math.floor((tonumber(size) or 10) + 0.5))
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

local function roundRect(mode, x, y, w, h, r)
  love.graphics.rectangle(mode, x, y, w, h, r, r)
end

local function uiScaleFor(ww, wh)
  local helper = mod and mod.exports and mod.exports.mobileUiScale
  if helper and type(helper.scale) == "function" then
    return helper.scale(ww, wh, 0.18, 1.15)
  end
  return math.max(0.18, math.min(1, math.min(ww / 800, wh / 600)))
end

local function panel(x, y, w, h, r, alpha, s)
  local G = love.graphics
  G.setColor(0.018, 0.026, 0.045, alpha or 0.80)
  roundRect("fill", x, y, w, h, r)
  G.setColor(1, 1, 1, 0.20)
  G.setLineWidth(math.max(1, 2 * (s or 1)))
  roundRect("line", x, y, w, h, r)
end

local function cleanText(text)
  text = tostring(text or "")
  text = text:gsub("<PO><KE>", "POKé")
  text = text:gsub("<PK><MN>", "POKéMON")
  text = text:gsub("<POKE>", "POKé")
  text = text:gsub("<LV>", "LV ")
  text = text:gsub("<NEXT>", " ")
  text = text:gsub("{PLAYER}", "PLAYER")
  text = text:gsub("[\v\f\r]", " ")
  text = text:gsub("\n", "  ")
  text = text:gsub("%s+", " ")
  return text
end

local function clipped(text, f, maxW)
  text = cleanText(text)
  if not f or type(f.getWidth) ~= "function" or f:getWidth(text) <= maxW then
    return text
  end
  local suffix = "..."
  while #text > 0 and f:getWidth(text .. suffix) > maxW do
    text = text:sub(1, -2)
  end
  return text .. suffix
end

local function targetDimensions(fallbackW, fallbackH)
  if fallbackW and fallbackH and fallbackW > 0 and fallbackH > 0 then
    return fallbackW, fallbackH
  end
  local G = love and love.graphics
  if not G then return nil, nil end
  if type(G.getCanvas) == "function" then
    local ok, c = pcall(G.getCanvas)
    if ok and c and type(c.getDimensions) == "function" then
      local w, h = c:getDimensions()
      if w and h and w > 0 and h > 0 then return w, h end
    end
  end
  if type(G.getDimensions) == "function" then return G.getDimensions() end
  return nil, nil
end

local function beginDraw(ww, wh)
  if not (ww and wh and ww > 0 and wh > 0) then return false end
  local G = love and love.graphics
  if not G then return false end
  G.push("all")
  G.origin()
  if type(G.setBlendMode) == "function" then G.setBlendMode("alpha") end
  return true
end

local function endDraw()
  love.graphics.pop()
  M.draws = M.draws + 1
end

local function header(G, title, subtitle, x, y, w, headerH, wh, s)
  local titleFont = font(math.max(18 * s, wh * 0.023))
  local metaFont = font(math.max(11 * s, wh * 0.013))
  if titleFont then G.setFont(titleFont) end
  G.setColor(1, 1, 1, 0.98)
  G.print(clipped(title, G.getFont(), w * 0.89), x + w * 0.055, y + headerH * 0.22)
  if subtitle and subtitle ~= "" then
    if metaFont then G.setFont(metaFont) end
    G.setColor(1, 1, 1, 0.58)
    G.print(clipped(subtitle, G.getFont(), w * 0.89),
      x + w * 0.055, y + headerH * 0.68)
  end
end

local function footer(G, text, x, y, w, h, gap, wh, s, warning)
  local metaFont = font(math.max(10 * s, wh * 0.013))
  if metaFont then G.setFont(metaFont) end
  if warning and warning ~= "" then
    G.setColor(1, 0.86, 0.56, 0.96)
  else
    G.setColor(1, 1, 1, 0.58)
  end
  G.printf(cleanText(controllerPrompt(warning and warning ~= "" and warning or text)),
    x + gap * 1.5, y + h - math.max(30 * s, wh * 0.037),
    w - gap * 3, "left")
end

-- Dynamic battle-selector geometry.  Ordinary party lists (6 + CANCEL),
-- Pokegear stations and the pause options all grow vertically before scrolling.
local function listGeometry(ww, wh, count, widthFrac, maxW, rowScale, maxRows)
  local s = uiScaleFor(ww, wh)
  local margin = math.max(18 * s, wh * 0.025)
  local w = math.min(ww * (widthFrac or 0.46), (maxW or 620) * s)
  local gap = math.max(7 * s, wh * 0.008)
  local headerH = math.max(48 * s, wh * 0.060)
  local footerH = math.max(42 * s, wh * 0.052)
  local baseRowH = math.max(48 * s,
    math.min(72 * s, wh * (rowScale or 0.070)))
  local minRowH = math.max(30 * s, wh * 0.040)
  local available = wh - margin * 2
  local requested = math.max(1, math.floor(tonumber(count) or 1))
  local rows = requested
  if tonumber(maxRows) and tonumber(maxRows) > 0 then
    rows = math.min(rows, math.max(1, math.floor(tonumber(maxRows))))
  end
  local rowH = baseRowH

  local function heightFor(n, rh)
    return headerH + rh * n + gap * (n + 1) + footerH
  end
  local h = heightFor(rows, rowH)
  if h > available then
    rowH = (available - headerH - footerH - gap * (rows + 1)) / rows
    if rowH < minRowH then
      rowH = minRowH
      rows = math.max(1, math.floor(
        (available - headerH - footerH - gap) / (rowH + gap)))
    end
    h = heightFor(rows, rowH)
  end
  local x = ww - w - margin
  local y = wh - h - margin
  local r = math.max(14 * s, wh * 0.022)
  return {
    x = x, y = y, w = w, h = h, rowH = rowH, gap = gap,
    headerH = headerH, footerH = footerH, r = r, s = s,
    rows = math.max(1, rows), margin = margin,
  }
end

local function windowFirst(count, visible, cursor, engineScroll)
  count = math.max(0, tonumber(count) or 0)
  visible = math.max(1, tonumber(visible) or 1)
  cursor = math.max(1, math.min(count > 0 and count or 1,
    tonumber(cursor) or 1))
  if count <= visible then return 1 end
  local first = math.max(1, (tonumber(engineScroll) or 0) + 1)
  if cursor < first then first = cursor end
  if cursor > first + visible - 1 then first = cursor - visible + 1 end
  if first + visible - 1 > count then first = math.max(1, count - visible + 1) end
  return first
end

local function hpColor(ratio)
  if ratio <= 0.20 then return 0.95, 0.23, 0.18 end
  if ratio <= 0.50 then return 0.96, 0.72, 0.15 end
  return 0.24, 0.90, 0.46
end

-- rows: { name, meta, value, tag, disabled, hpRatio, accentText }
local function drawListPanel(ww, wh, title, subtitle, rows, cursor, engineScroll, opts)
  opts = opts or {}
  local G = love.graphics
  local geo = listGeometry(ww, wh, #rows, opts.widthFrac, opts.maxW,
    opts.rowScale, opts.maxRows)
  panel(geo.x, geo.y, geo.w, geo.h, geo.r, opts.alpha or 0.82, geo.s)
  header(G, title, subtitle, geo.x, geo.y, geo.w, geo.headerH, wh, geo.s)

  local first = windowFirst(#rows, geo.rows, cursor, engineScroll)
  local nameFont = font(math.max(13 * geo.s, math.min(18 * geo.s, geo.rowH * 0.31)))
  local metaFont = font(math.max(9 * geo.s, math.min(12 * geo.s, geo.rowH * 0.22)))
  for slot = 1, geo.rows do
    local i = first + slot - 1
    local row = rows[i]
    if not row then break end
    local ry = geo.y + geo.headerH + geo.gap + (slot - 1) * (geo.rowH + geo.gap)
    local on = cursor and i == cursor
    G.setColor(1, 1, 1, on and 0.17 or 0.07)
    roundRect("fill", geo.x + geo.gap, ry, geo.w - geo.gap * 2,
      geo.rowH, geo.r * 0.55)
    if on then
      G.setColor(1, 1, 1, 0.72)
      G.setLineWidth(math.max(1, 2 * geo.s))
      roundRect("line", geo.x + geo.gap, ry, geo.w - geo.gap * 2,
        geo.rowH, geo.r * 0.55)
    end

    local lx = geo.x + geo.gap * 2.2
    local right = geo.x + geo.w - geo.gap * 2.2
    local maxTextW = geo.w - geo.gap * 4.4
    if nameFont then G.setFont(nameFont) end
    G.setColor(1, 1, 1, row.disabled and 0.38 or 0.98)
    local hasMeta = row.meta and cleanText(row.meta) ~= ""
    local nameY = hasMeta and (ry + geo.rowH * 0.13) or (ry + geo.rowH * 0.31)
    local valueText = cleanText(row.value)
    local valueW = 0
    if valueText ~= "" then valueW = G.getFont():getWidth(valueText) end
    G.print(clipped(row.name or "", G.getFont(),
      math.max(20, maxTextW - valueW - geo.gap * 1.5)), lx, nameY)
    if valueText ~= "" then
      G.setColor(1, 1, 1, row.disabled and 0.30 or 0.78)
      G.print(valueText, right - valueW, nameY)
    end

    if row.tag and cleanText(row.tag) ~= "" then
      if metaFont then G.setFont(metaFont) end
      local tag = cleanText(row.tag)
      local tw = G.getFont():getWidth(tag)
      G.setColor(1, 1, 1, 0.58)
      G.print(tag, right - tw, ry + geo.rowH * 0.60)
    end

    if hasMeta and geo.rowH >= 33 * geo.s then
      if metaFont then G.setFont(metaFont) end
      G.setColor(1, 1, 1, row.disabled and 0.28 or 0.60)
      local metaMax = geo.w - geo.gap * 4.4
      if row.tag then metaMax = metaMax * 0.70 end
      G.print(clipped(row.meta, G.getFont(), metaMax), lx, ry + geo.rowH * 0.60)
    end

    if row.hpRatio ~= nil and geo.rowH >= 43 * geo.s then
      local ratio = math.max(0, math.min(1, tonumber(row.hpRatio) or 0))
      local bx = lx
      local by = ry + geo.rowH * 0.48
      local bw = geo.w * 0.40
      local bh = math.max(5 * geo.s, geo.rowH * 0.075)
      G.setColor(0, 0, 0, 0.46)
      roundRect("fill", bx, by, bw, bh, bh * 0.5)
      local cr, cg, cb = hpColor(ratio)
      G.setColor(cr, cg, cb, 0.96)
      if ratio > 0 then
        roundRect("fill", bx, by, math.max(2 * geo.s, bw * ratio), bh, bh * 0.5)
      end
    end
  end

  -- Long lists (especially the 251-entry Pokédex) get a real viewport marker.
  -- The native Gen2 screen owns cursor/index movement; this bar only mirrors
  -- the custom viewport so every species remains reachable without letting
  -- hundreds of rows run past the bottom of the window.
  if opts.scrollbar and #rows > geo.rows then
    local trackX = geo.x + geo.w - math.max(6 * geo.s, geo.gap * 0.65)
    local trackY = geo.y + geo.headerH + geo.gap
    local trackH = geo.rows * geo.rowH + math.max(0, geo.rows - 1) * geo.gap
    local thumbH = math.max(18 * geo.s, trackH * (geo.rows / #rows))
    local denom = math.max(1, #rows - geo.rows)
    local frac = math.max(0, math.min(1, (first - 1) / denom))
    local thumbY = trackY + (trackH - thumbH) * frac
    G.setColor(1, 1, 1, 0.10)
    roundRect("fill", trackX, trackY, math.max(3 * geo.s, geo.gap * 0.24),
      trackH, math.max(2 * geo.s, geo.gap * 0.12))
    G.setColor(1, 1, 1, 0.52)
    roundRect("fill", trackX, thumbY, math.max(3 * geo.s, geo.gap * 0.24),
      thumbH, math.max(2 * geo.s, geo.gap * 0.12))
  end

  local footerText = opts.footer or
    "D-PAD / ARROWS SELECT    CROSS/A CONFIRM    CIRCLE/B BACK"
  footer(G, footerText, geo.x, geo.y, geo.w, geo.h, geo.gap, wh, geo.s,
    opts.warning)
  return geo, first
end

local function drawMessage(ww, wh, rightX, title, text, opts)
  text = cleanText(text)
  if text == "" then return nil end
  opts = opts or {}
  local s = uiScaleFor(ww, wh)
  local margin = math.max(18 * s, wh * 0.025)
  local available = math.max(0, (rightX or ww) - margin * 2)
  if available < 78 * s then return nil end
  local w = math.min(ww * (opts.widthFrac or 0.52), 720 * s, available)
  local h = math.max(74 * s, math.min(opts.maxH or 126 * s, wh * (opts.heightFrac or 0.15)))
  local x = margin
  local y = opts.y or (wh - h - margin)
  local r = math.max(14 * s, wh * 0.022)
  panel(x, y, w, h, r, opts.alpha or 0.78, s)

  local titleFont = font(math.max(15 * s, wh * 0.020))
  local bodyFont = font(math.max(11 * s, wh * 0.014))
  if title and title ~= "" then
    if titleFont then love.graphics.setFont(titleFont) end
    love.graphics.setColor(1, 1, 1, 0.96)
    love.graphics.print(clipped(title, love.graphics.getFont(), w - h * 0.42),
      x + h * 0.20, y + h * 0.14)
  end
  if bodyFont then love.graphics.setFont(bodyFont) end
  love.graphics.setColor(1, 1, 1, 0.64)
  love.graphics.printf(text, x + h * 0.20,
    y + (title and title ~= "" and h * 0.48 or h * 0.28),
    w - h * 0.40, "left")
  return { x = x, y = y, w = w, h = h, r = r, s = s }
end

local function partyModelPanel(screen, mon, geo, ww, wh)
  local G = love.graphics
  local s = geo.s
  local x = geo.margin
  local y = geo.y
  local w = geo.x - geo.margin * 2
  local h = geo.h
  if w < math.max(170 * s, ww * 0.20) then return false end

  panel(x, y, w, h, geo.r, 0.80, s)
  local game = screen and screen.game
  local def = mon and game and game.data and game.data.pokemon
    and game.data.pokemon[mon.species]
  local speciesName = cleanText((def and def.name) or (mon and mon.species) or "POKéMON")
  local nickname = cleanText(mon and (mon.nickname or mon.name) or speciesName)
  local dex = def and tonumber(def.dex or def.index) or nil
  local subtitle = dex and (speciesName .. "    #" .. string.format("%03d", dex)) or speciesName
  if not mon then
    nickname, subtitle = "PARTY", "SELECT A POKéMON"
  elseif mon.isEgg then
    nickname, subtitle = cleanText(mon.nickname or "EGG"), "EGG"
  end
  header(G, nickname, subtitle, x, y, w, geo.headerH, wh, s)

  local infoH = math.max(112 * s, math.min(154 * s, h * 0.22))
  local modelTop = y + geo.headerH + geo.gap * 0.5
  local modelBottom = y + h - infoH - geo.gap * 1.5
  local modelH = math.max(40, modelBottom - modelTop)
  local modelX = x + geo.gap * 1.2
  local modelW = w - geo.gap * 2.4

  -- Subtle showroom floor.  The actual model canvas is transparent, so this
  -- reads through it and anchors hovering/flying Pokemon without pretending
  -- the party screen is a second overworld scene.
  G.setColor(1, 1, 1, 0.035)
  roundRect("fill", modelX, modelTop, modelW, modelH, geo.r * 0.62)
  G.setColor(1, 1, 1, 0.075)
  G.ellipse("fill", modelX + modelW * 0.50, modelTop + modelH * 0.82,
    modelW * 0.28, math.max(5 * s, modelH * 0.045))

  local preview, info = partyPreviewModule(), nil
  local canvas
  if mon and not mon.isEgg and preview and type(preview.render) == "function" then
    local ok, rendered, details = pcall(preview.render, screen, mon,
      math.min(modelW, 480), math.min(modelH, 480))
    if ok then canvas, info = rendered, details end
    if not ok then M.lastError = "Party model preview: " .. tostring(rendered) end
  end

  if canvas and type(canvas.getDimensions) == "function" then
    local cw, ch = canvas:getDimensions()
    if cw and ch and cw > 0 and ch > 0 then
      local k = math.min(modelW / cw, modelH / ch)
      local dw, dh = cw * k, ch * k
      G.setColor(1, 1, 1, 1)
      G.draw(canvas, modelX + (modelW - dw) * 0.5,
        modelTop + (modelH - dh) * 0.5, 0, k, k)
    end
  else
    local f1 = font(math.max(15 * s, wh * 0.019))
    local f2 = font(math.max(10 * s, wh * 0.013))
    local title
    local body
    if not mon then
      title, body = "SELECT A POKéMON", "THE STADIUM 2 MODEL WILL APPEAR HERE"
    elseif mon.isEgg then
      title, body = "EGG", "NO STADIUM MODEL UNTIL IT HATCHES"
    else
      title = "3D MODEL UNAVAILABLE"
      body = "IMPORT / BUILD THE STADIUM 2 MODEL PACK IN MOD OPTIONS"
      if info and info.error then body = "MODEL PREVIEW COULD NOT BE BUILT" end
    end
    if f1 then G.setFont(f1) end
    G.setColor(1, 1, 1, 0.82)
    G.printf(title, modelX + geo.gap, modelTop + modelH * 0.40,
      modelW - geo.gap * 2, "center")
    if f2 then G.setFont(f2) end
    G.setColor(1, 1, 1, 0.46)
    G.printf(body, modelX + geo.gap, modelTop + modelH * 0.52,
      modelW - geo.gap * 2, "center")
  end

  local ix = x + geo.gap
  local iy = y + h - infoH - geo.gap
  local iw = w - geo.gap * 2
  local ih = infoH
  G.setColor(1, 1, 1, 0.055)
  roundRect("fill", ix, iy, iw, ih, geo.r * 0.55)
  G.setColor(1, 1, 1, 0.13)
  G.setLineWidth(math.max(1, 1.5 * s))
  roundRect("line", ix, iy, iw, ih, geo.r * 0.55)

  if mon then
    local hp = math.max(0, tonumber(mon.hp) or 0)
    local maxHp = tonumber(mon.maxHp)
      or (type(mon.stats) == "table" and tonumber(mon.stats.hp)) or math.max(1, hp)
    maxHp = math.max(1, maxHp)
    local ratio = math.max(0, math.min(1, hp / maxHp))
    local labelFont = font(math.max(11 * s, wh * 0.014))
    local valueFont = font(math.max(13 * s, wh * 0.017))
    if labelFont then G.setFont(labelFont) end
    G.setColor(1, 1, 1, 0.52)
    G.print("LEVEL", ix + iw * 0.06, iy + ih * 0.14)
    G.print("STATUS", ix + iw * 0.56, iy + ih * 0.14)
    if valueFont then G.setFont(valueFont) end
    G.setColor(1, 1, 1, 0.94)
    G.print(tostring(tonumber(mon.level) or 1), ix + iw * 0.06, iy + ih * 0.34)
    local status = mon.isEgg and "EGG" or hp <= 0 and "FNT" or cleanText(mon.status or "OK")
    if status == "" then status = "OK" end
    G.print(status, ix + iw * 0.56, iy + ih * 0.34)

    if labelFont then G.setFont(labelFont) end
    local held = "---"
    if mon.item then
      local itemDef = game and game.data and game.data.items and game.data.items[mon.item]
      held = cleanText((itemDef and itemDef.name) or mon.item)
    end
    G.setColor(1, 1, 1, 0.52)
    G.print(clipped("HELD  " .. held, G.getFont(), iw * 0.88),
      ix + iw * 0.06, iy + ih * 0.56)
    G.print("HP  " .. tostring(hp) .. " / " .. tostring(maxHp),
      ix + iw * 0.06, iy + ih * 0.71)
    local bx, by = ix + iw * 0.06, iy + ih * 0.88
    local bw, bh = iw * 0.88, math.max(6 * s, ih * 0.055)
    G.setColor(0, 0, 0, 0.48)
    roundRect("fill", bx, by, bw, bh, bh * 0.5)
    local cr, cg, cb = hpColor(ratio)
    G.setColor(cr, cg, cb, 0.97)
    if ratio > 0 then
      roundRect("fill", bx, by, math.max(2 * s, bw * ratio), bh, bh * 0.5)
    end
  else
    local f = font(math.max(12 * s, wh * 0.015))
    if f then G.setFont(f) end
    G.setColor(1, 1, 1, 0.52)
    G.printf("3D PARTY SHOWCASE", ix, iy + ih * 0.42, iw, "center")
  end
  return true
end

local function drawSmallChoice(ww, wh, title, subtitle, labels, cursor, opts)
  opts = opts or {}
  local G = love.graphics
  local s = uiScaleFor(ww, wh)
  local margin = math.max(18 * s, wh * 0.025)
  local count = math.max(1, #labels)
  local w = math.min(ww * (opts.widthFrac or 0.30), (opts.maxW or 390) * s)
  local gap = math.max(7 * s, wh * 0.008)
  local headerH = math.max(44 * s, wh * 0.054)
  local footerH = math.max(34 * s, wh * 0.044)
  local available = wh - margin * 2
  local rowH = math.max(36 * s, math.min(60 * s,
    (available - headerH - footerH - gap * (count + 1)) / count))
  local h = headerH + rowH * count + gap * (count + 1) + footerH
  local x = opts.x or margin
  local y = opts.y or (wh - h - margin)
  local r = math.max(14 * s, wh * 0.022)
  panel(x, y, w, h, r, 0.84, s)
  header(G, title, subtitle, x, y, w, headerH, wh, s)
  local f = font(math.max(13 * s, math.min(18 * s, rowH * 0.31)))
  for i, label in ipairs(labels) do
    local ry = y + headerH + gap + (i - 1) * (rowH + gap)
    local on = i == cursor
    G.setColor(1, 1, 1, on and 0.17 or 0.07)
    roundRect("fill", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    if on then
      G.setColor(1, 1, 1, 0.72)
      G.setLineWidth(math.max(1, 2 * s))
      roundRect("line", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    end
    if f then G.setFont(f) end
    G.setColor(1, 1, 1, 0.98)
    G.print(clipped(label, G.getFont(), w - gap * 4.4),
      x + gap * 2.2, ry + rowH * 0.30)
  end
  footer(G, opts.footer or "CROSS/A CONFIRM    CIRCLE/B BACK",
    x, y, w, h, gap, wh, s)
  return { x = x, y = y, w = w, h = h, s = s }
end

local function countTruthy(t)
  local n = 0
  for _, v in pairs(type(t) == "table" and t or {}) do if v then n = n + 1 end end
  return n
end

local function stackTop(game)
  local stack = game and game.stack
  if not (stack and type(stack.top) == "function") then return nil end
  local ok, top = pcall(stack.top, stack)
  return ok and top or nil
end

local function openedFromPause(game)
  local top = stackTop(game)
  if not top then return false end
  if StartMenuClass and getmetatable(top) == StartMenuClass then return true end
  return top._stadium2PauseSkinChain == true
end

local function partyRenderer(screen, ww, wh)
  if not beginDraw(ww, wh) then return false end
  local party = type(screen.party) == "table" and screen.party or {}
  local rows = {}
  for i, mon in ipairs(party) do
    local hp = math.max(0, tonumber(mon.hp) or 0)
    local maxHp = tonumber(mon.maxHp)
      or (type(mon.stats) == "table" and tonumber(mon.stats.hp)) or math.max(1, hp)
    maxHp = math.max(1, maxHp)
    local name = cleanText(mon.nickname or mon.name or mon.species or "POKéMON")
    local status = mon.isEgg and "EGG" or hp <= 0 and "FNT" or cleanText(mon.status or "")
    local meta = ("LV %d    HP %d/%d"):format(tonumber(mon.level) or 1, hp, maxHp)
    if status ~= "" then meta = meta .. "    " .. status end
    rows[#rows + 1] = {
      name = name,
      meta = meta,
      hpRatio = hp / maxHp,
      tag = screen.switchFrom == i and "MOVE FROM" or nil,
    }
  end
  rows[#rows + 1] = { name = "CANCEL", meta = "BACK TO PAUSE MENU" }
  local prompt = cleanText(screen.switchFrom and "Move to where?" or screen.prompt or "Choose a POKéMON.")
  local geo = drawListPanel(ww, wh, "POKéMON", prompt, rows,
    tonumber(screen.index) or 1, 0, {
      widthFrac = 0.47, maxW = 630, rowScale = 0.067,
      footer = "D-PAD / ARROWS SELECT    CROSS/A CONFIRM    CIRCLE/B BACK",
    })

  local selectedIndex = tonumber(screen.index) or 1
  local selected = selectedIndex >= 1 and selectedIndex <= #party and party[selectedIndex] or nil
  if not partyModelPanel(screen, selected, geo, ww, wh) then
    drawMessage(ww, wh, geo.x, "POKéMON", prompt)
  end

  if screen.submenu and type(screen.submenu.items) == "table" then
    local labels = {}
    for _, item in ipairs(screen.submenu.items) do labels[#labels + 1] = cleanText(item.label or item.id) end
    local mon = screen.submenu.mon or party[screen.submenu.slot or screen.index]
    drawSmallChoice(ww, wh, cleanText(mon and (mon.nickname or mon.name or mon.species) or "POKéMON"),
      "ACTION", labels, tonumber(screen.submenu.index) or 1,
      { widthFrac = 0.31, maxW = 420,
        x = geo.x + geo.gap,
        y = geo.y + geo.headerH + geo.gap })
  end
  endDraw()
  return true
end

local drawInfoRows

local function summaryTypeText(screen)
  if type(screen.typeNames) ~= "function" then return "---" end
  local ok, first, second = pcall(screen.typeNames, screen)
  if not ok then return "---" end
  first, second = cleanText(first or "---"), cleanText(second or "")
  if second ~= "" then return first .. " / " .. second end
  return first
end

local function summaryItemText(screen)
  if type(screen.itemName) == "function" then
    local ok, value = pcall(screen.itemName, screen)
    if ok and value and value ~= "" then return cleanText(value) end
  end
  return "---"
end

local function summaryStatus(mon)
  if type(mon) ~= "table" then return "---" end
  if mon.isEgg then return "EGG" end
  if (tonumber(mon.hp) or 0) <= 0 then return "FNT" end
  local status = cleanText(mon.status or "")
  return status ~= "" and status or "OK"
end

local function summaryMoveRows(screen, detailed)
  local rows = {}
  local moves = type(screen.moveList) == "function" and screen:moveList()
    or (screen.mon and screen.mon.moves) or {}
  for i = 1, 4 do
    local entry = moves[i]
    if entry then
      local name = type(screen.moveName) == "function" and screen:moveName(entry)
        or entry.id or ("MOVE " .. i)
      local maxPp = tonumber(entry.maxPp) or tonumber(entry.pp) or 0
      local value = ("PP %d/%d"):format(tonumber(entry.pp) or 0, maxPp)
      local meta = ""
      if detailed and type(screen.moveDef) == "function" then
        local ok, def = pcall(screen.moveDef, screen, entry.id)
        if ok and type(def) == "table" then
          local t = cleanText(def.type or "")
          local power = tonumber(def.power) or 0
          meta = t
          if power >= 2 then meta = meta .. (meta ~= "" and "    " or "") .. "POWER " .. tostring(power) end
        end
      end
      rows[#rows + 1] = { name = cleanText(name), value = value, meta = meta }
    else
      rows[#rows + 1] = { name = "---", value = "PP --/--", meta = "EMPTY MOVE SLOT", disabled = true }
    end
  end
  return rows
end

local function summaryRenderer(screen, ww, wh)
  if not beginDraw(ww, wh) then return false end
  local mon = screen.mon
  local isEgg = type(mon) == "table" and mon.isEgg == true
  local geo

  if isEgg then
    local cycles = tonumber(mon.eggSteps) or 0
    local rows = {
      { "EGG", "HATCHING" },
      { "HATCH CYCLES", tostring(cycles) },
      { "STATUS", cycles < 6 and "VERY CLOSE" or cycles < 11 and "CLOSE" or "WAITING" },
    }
    geo = drawInfoRows(ww, wh, "POKéMON SUMMARY", "EGG", rows,
      { widthFrac = 0.46, maxW = 620, rowScale = 0.073,
        footer = "UP/DOWN POKéMON    CROSS/A OR CIRCLE/B BACK" })
  elseif screen.moveDetail then
    local rows = summaryMoveRows(screen, true)
    geo = drawListPanel(ww, wh, "MOVE DETAILS",
      cleanText(mon and (mon.nickname or mon.name or mon.species) or "POKéMON"),
      rows, tonumber(screen.moveIndex) or 1, 0,
      { widthFrac = 0.47, maxW = 630, rowScale = 0.074,
        footer = "UP/DOWN MOVE    LEFT/RIGHT POKéMON    CROSS/A PICK / PLACE    CIRCLE/B BACK" })
  else
    local page = tonumber(screen.page) or 1
    if page == 2 then
      local rows = { { "HELD ITEM", summaryItemText(screen), "SELECT OPENS MOVE DETAILS" } }
      for _, row in ipairs(summaryMoveRows(screen, false)) do
        rows[#rows + 1] = { row.name, row.value, row.meta }
      end
      geo = drawInfoRows(ww, wh, "POKéMON SUMMARY", "MOVES / ITEM", rows,
        { widthFrac = 0.47, maxW = 630, rowScale = 0.066,
          footer = "UP/DOWN POKéMON    LEFT/RIGHT PAGE    SELECT MOVE DETAILS    CIRCLE/B BACK" })
    elseif page == 3 then
      local stats = type(mon.stats) == "table" and mon.stats or {}
      local ot = type(screen.otName) == "function" and screen:otName() or "---"
      local otId = type(screen.otId) == "function" and screen:otId() or 0
      local rows = {
        { "OT", cleanText(ot) },
        { "ID No.", string.format("%05d", tonumber(otId) or 0) },
        { "ATTACK", tostring(tonumber(stats.attack) or 0) },
        { "DEFENSE", tostring(tonumber(stats.defense) or 0) },
        { "SPCL. ATK", tostring(tonumber(stats.specialAttack) or 0) },
        { "SPCL. DEF", tostring(tonumber(stats.specialDefense) or 0) },
        { "SPEED", tostring(tonumber(stats.speed) or 0) },
      }
      geo = drawInfoRows(ww, wh, "POKéMON SUMMARY", "STATS / TRAINER", rows,
        { widthFrac = 0.47, maxW = 630, rowScale = 0.058,
          footer = "UP/DOWN POKéMON    LEFT/RIGHT PAGE    CROSS/A BACK    CIRCLE/B BACK" })
    else
      local hp = math.max(0, tonumber(mon.hp) or 0)
      local maxHp = tonumber(mon.maxHp)
        or (type(mon.stats) == "table" and tonumber(mon.stats.hp)) or math.max(1, hp)
      maxHp = math.max(1, maxHp)
      local nextExp = type(screen.expToNext) == "function" and screen:expToNext() or 0
      local rows = {
        { "HP", tostring(hp) .. " / " .. tostring(maxHp) },
        { "STATUS", summaryStatus(mon) },
        { "TYPE", summaryTypeText(screen) },
        { "EXP POINTS", tostring(tonumber(mon.experience) or 0) },
        { "TO NEXT LEVEL", tostring(tonumber(nextExp) or 0) },
      }
      geo = drawInfoRows(ww, wh, "POKéMON SUMMARY", "STATUS / EXP", rows,
        { widthFrac = 0.47, maxW = 630, rowScale = 0.067,
          footer = "UP/DOWN POKéMON    LEFT/RIGHT PAGE    CROSS/A NEXT    CIRCLE/B BACK" })
    end
  end

  if geo then partyModelPanel(screen, mon, geo, ww, wh) end
  endDraw()
  return true
end

local PACK_ACTION = { use = "USE", give = "GIVE", toss = "TOSS", sel = "SEL", quit = "QUIT" }

local function packMessage(screen)
  local lines = screen.message or (screen.confirm and screen.confirm.prompt)
  if type(lines) == "table" then return table.concat(lines, " ") end
  if lines then return lines end
  if type(screen.description) == "function" then
    local ok, value = pcall(screen.description, screen)
    if ok then return value end
  end
  return ""
end

local function packRenderer(screen, ww, wh)
  if not beginDraw(ww, wh) then return false end
  local rows = {}
  for _, entry in ipairs(type(screen.rows) == "table" and screen.rows or {}) do
    local meta = ""
    if entry.teaches then meta = cleanText(entry.teaches)
    elseif entry.showCount then meta = "×" .. tostring(math.floor(tonumber(entry.count) or 0))
    end
    rows[#rows + 1] = {
      name = cleanText(entry.name or entry.id),
      meta = meta,
      value = entry.teaches and (entry.showCount and ("×" .. tostring(entry.count or 0)) or "") or "",
    }
  end
  rows[#rows + 1] = { name = "CANCEL", meta = "BACK TO PAUSE MENU" }
  local pocket = type(screen.pocket) == "function" and screen:pocket() or nil
  local subtitle = cleanText(pocket and pocket.label or "ITEMS")
  local geo = drawListPanel(ww, wh, "PACK", subtitle, rows,
    tonumber(screen.index) or 1, tonumber(screen.scroll) or 0, {
      widthFrac = 0.47, maxW = 630, rowScale = 0.066,
      footer = "LEFT/RIGHT POCKET    D-PAD SELECT    CROSS/A CONFIRM    CIRCLE/B BACK",
    })

  local message = packMessage(screen)
  local selected = screen.rows and screen.rows[screen.index]
  local msgTitle = selected and cleanText(selected.name or selected.id) or "PACK"
  drawMessage(ww, wh, geo.x, msgTitle, message)

  if screen.submenu and type(screen.submenu.rows) == "table" then
    local labels = {}
    for _, id in ipairs(screen.submenu.rows) do labels[#labels + 1] = PACK_ACTION[id] or tostring(id):upper() end
    drawSmallChoice(ww, wh, msgTitle, "ITEM ACTION", labels,
      tonumber(screen.submenu.index) or 1, { widthFrac = 0.29, maxW = 390 })
  elseif screen.qtyState then
    drawSmallChoice(ww, wh, "THROW AWAY", msgTitle,
      { "×" .. tostring(screen.qtyState.qty or 1) }, 1,
      { widthFrac = 0.25, maxW = 330,
        footer = "UP/DOWN ±1    LEFT/RIGHT ±10    CROSS/A CONFIRM" })
  elseif screen.confirm then
    drawSmallChoice(ww, wh, "CONFIRM", msgTitle, { "YES", "NO" },
      tonumber(screen.confirm.choice) or 1, { widthFrac = 0.27, maxW = 350 })
  end

  endDraw()
  return true
end

local function optionValue(screen, row)
  if not row then return "" end
  if row.cancel then return "" end
  if row.frame then return "TYPE " .. tostring((screen.options or {}).frame or 1) end
  if type(row.text) == "function" then
    local ok, value = pcall(row.text, screen.options or {})
    return ok and cleanText(value) or "?"
  end
  if row.values then
    local value = (screen.options or {})[row.key]
    if row.display then value = row.display[value] or value end
    return cleanText(value)
  end
  if type(row.value) == "function" then
    local ok, value = pcall(row.value, screen.game)
    return ok and cleanText(value) or "?"
  end
  return ""
end

local function optionsRenderer(screen, ww, wh)
  if not beginDraw(ww, wh) then return false end
  local rows = {}
  for _, row in ipairs(type(screen.rows) == "table" and screen.rows or {}) do
    rows[#rows + 1] = {
      name = cleanText(row.label or row.id or "OPTION"),
      value = optionValue(screen, row),
      meta = row.activate and "OPEN" or (row.cancel and "BACK" or "LEFT / RIGHT TO CHANGE"),
    }
  end
  local geo = drawListPanel(ww, wh, "OPTIONS", "GAME SETTINGS", rows,
    tonumber(screen.index) or 1, tonumber(screen.scroll) or 0, {
      widthFrac = 0.56, maxW = 760, rowScale = 0.060,
      footer = "D-PAD SELECT    LEFT/RIGHT CHANGE    CROSS/A APPLY    CIRCLE/B BACK",
    })
  drawMessage(ww, wh, geo.x, "OPTIONS",
    "Settings still use Gold's native OPTION logic. Changes are applied and persisted exactly as before.")
  endDraw()
  return true
end

local function saveSummary(screen)
  if SaveModule == nil then
    local ok, got = pcall(require, "src.core.gen2.Save")
    SaveModule = ok and got or false
  end
  if SaveModule and type(SaveModule.summary) == "function" then
    local ok, s = pcall(SaveModule.summary, screen.save)
    if ok and s then return s end
  end
  local save = screen.save or {}
  local player = save.player or {}
  local play = save.playTime or {}
  local caught = 0
  for _, v in pairs((save.pokedex and save.pokedex.caught) or {}) do if v then caught = caught + 1 end end
  return {
    name = player.name or "GOLD",
    badges = countTruthy(player.badges),
    caught = caught,
    hours = play.hours or 0,
    minutes = play.minutes or 0,
  }
end

drawInfoRows = function(ww, wh, title, subtitle, rows, opts)
  opts = opts or {}
  local fake = {}
  for _, row in ipairs(rows) do
    fake[#fake + 1] = { name = row[1], value = row[2], meta = row[3] }
  end
  return drawListPanel(ww, wh, title, subtitle, fake, nil, 0, opts)
end

local function saveRenderer(screen, ww, wh)
  if not beginDraw(ww, wh) then return false end
  local sum = saveSummary(screen)
  local info = {
    { "PLAYER", cleanText(sum.name or "GOLD") },
    { "BADGES", tostring(sum.badges or 0) },
    { "POKéDEX", tostring(sum.caught or 0) .. " CAUGHT" },
    { "TIME", ("%d:%02d"):format(tonumber(sum.hours) or 0, tonumber(sum.minutes) or 0) },
  }
  local geo = drawInfoRows(ww, wh, "SAVE GAME", "CURRENT PROGRESS", info,
    { widthFrac = 0.42, maxW = 560, rowScale = 0.067,
      footer = "GOLD'S NATIVE SAVE ROUTINE REMAINS AUTHORITATIVE" })
  local prompt = type(screen.prompt) == "function" and screen:prompt() or {}
  local text = type(prompt) == "table" and table.concat(prompt, " ") or tostring(prompt or "")
  drawMessage(ww, wh, geo.x, "SAVE", text)
  if screen.phase == "confirm" or screen.phase == "overwrite" then
    drawSmallChoice(ww, wh,
      screen.phase == "overwrite" and "OVERWRITE SAVE?" or "SAVE THE GAME?",
      "CONFIRM", { "YES", "NO" }, tonumber(screen.choice) or 1,
      { widthFrac = 0.29, maxW = 390 })
  end
  endDraw()
  return true
end

local JOHTO_BADGES = { "ZEPHYR", "HIVE", "PLAIN", "FOG", "STORM", "MINERAL", "GLACIER", "RISING" }
local KANTO_BADGES = { "BOULDER", "CASCADE", "THUNDER", "RAINBOW", "SOUL", "MARSH", "VOLCANO", "EARTH" }

local function trainerRenderer(screen, ww, wh)
  if not beginDraw(ww, wh) then return false end
  local save = screen.save or {}
  local player = save.player or {}
  if tonumber(screen.page) == 1 then
    local caught = type(screen.caughtCount) == "function" and screen:caughtCount() or 0
    local time = save.playTime or {}
    local money = tonumber(player.money) or 0
    local rows = {
      { "NAME", cleanText(player.name or "GOLD") },
      { "ID No.", ("%05d"):format(tonumber(player.id) or 0) },
      { "MONEY", "¥" .. tostring(math.floor(money)) },
      { "POKéDEX", tostring(caught) .. " CAUGHT" },
      { "PLAY TIME", ("%d:%02d"):format(tonumber(time.hours) or 0, tonumber(time.minutes) or 0) },
      { "BADGES", tostring(countTruthy(player.badges)) .. "/8" },
    }
    local geo = drawInfoRows(ww, wh, "TRAINER CARD", "PLAYER STATUS", rows,
      { widthFrac = 0.47, maxW = 630, rowScale = 0.065,
        footer = "LEFT/RIGHT PAGE    CROSS/A BADGES    CIRCLE/B BACK" })
    drawMessage(ww, wh, geo.x, cleanText(player.name or "GOLD"),
      "Trainer information and progress. Press A or Right to view badges.")
  else
    local names = tonumber(screen.page) == 3 and KANTO_BADGES or JOHTO_BADGES
    -- Gold's own TrainerCard page-3 path reuses the Johto badge flags even
    -- while relabeling the page as Kanto.  Keep that engine quirk intact: this
    -- module is a skin, not a rules/data correction.
    local owned = player.badges or {}
    local rows = {}
    for i, name in ipairs(names) do
      local has = owned[i] or owned[name]
      rows[#rows + 1] = { name = name, value = has and "EARNED" or "—", meta = has and "GYM BADGE" or "NOT EARNED" }
    end
    local title = tonumber(screen.page) == 3 and "KANTO BADGES" or "JOHTO BADGES"
    local geo = drawListPanel(ww, wh, title, cleanText(player.name or "GOLD"), rows,
      nil, 0, { widthFrac = 0.49, maxW = 660, rowScale = 0.060,
        footer = "LEFT/RIGHT PAGE    CROSS/A BACK    CIRCLE/B BACK" })
    drawMessage(ww, wh, geo.x, title,
      tostring(countTruthy(owned)) .. " badges earned.")
  end
  endDraw()
  return true
end

local function pokegearCard(screen)
  if type(screen.card) == "function" then
    local ok, card = pcall(screen.card, screen)
    if ok then return card end
  end
  return screen.cards and screen.cards[screen.cardIndex or 1] or nil
end

local function pokegearRenderer(screen, ww, wh)
  if not beginDraw(ww, wh) then return false end
  local card = pokegearCard(screen) or { id = "clock", label = "CLOCK" }
  local id = card.id or "clock"
  local mode = tostring(screen.mode or "card"):upper()
  local footerText = "LEFT/RIGHT CARD    CROSS/A OPEN    CIRCLE/B BACK"

  if screen.fly then
    local rows = {}
    for _, row in ipairs(screen.fly) do rows[#rows + 1] = { name = cleanText(row.name or "DESTINATION") } end
    drawListPanel(ww, wh, "FLY", "WHERE?", rows, tonumber(screen.flyIndex) or 1, 0,
      { widthFrac = 0.48, maxW = 650, rowScale = 0.064,
        footer = "UP/DOWN SELECT    CROSS/A FLY    CIRCLE/B BACK" })
    endDraw()
    return true
  end

  if id == "phone" then
    local list = type(screen.phoneList) == "function" and screen:phoneList() or {}
    local rows = {}
    for slot = 1, 4 do
      local contactId = list[slot + (tonumber(screen.phoneScroll) or 0)] or 0
      local label, className = "----------", nil
      if type(screen.contactRow) == "function" then
        local ok, a, b = pcall(screen.contactRow, screen, contactId)
        if ok then label, className = a or label, b end
      end
      rows[#rows + 1] = { name = cleanText(label), meta = cleanText(className or (contactId == 0 and "EMPTY SLOT" or "CONTACT")) }
    end
    local geo = drawListPanel(ww, wh, "POKéGEAR • PHONE", mode, rows,
      (tonumber(screen.phoneCursor) or 0) + 1, 0,
      { widthFrac = 0.47, maxW = 630, rowScale = 0.072,
        footer = "UP/DOWN CONTACT    CROSS/A ACTION    LEFT/RIGHT CARD    CIRCLE/B BACK" })
    local callText = screen.call and screen.call.text
      or (type(screen.phoneText) == "function" and screen:phoneText("AskWhoCall")) or "Whom do you want to call?"
    drawMessage(ww, wh, geo.x, screen.call and cleanText(screen.call.name or "PHONE") or "PHONE", callText)

    if screen.phoneSubmenu then
      local PokegearClass = package.loaded["src.ui.gen2.Pokegear"]
      local defs = PokegearClass and PokegearClass.PHONE_SUBMENUS
      local def = defs and defs[screen.phoneSubmenu]
      local labels = {}
      for _, label in ipairs(def and def.entries or { "CALL", "CANCEL" }) do labels[#labels + 1] = label end
      drawSmallChoice(ww, wh, "PHONE", "CONTACT ACTION", labels,
        (tonumber(screen.phoneSubmenuCursor) or 0) + 1,
        { widthFrac = 0.28, maxW = 360 })
    end
  elseif id == "radio" then
    local stations = type(screen.stations) == "function" and screen:stations() or {}
    local rows = {}
    for _, station in ipairs(stations) do
      rows[#rows + 1] = {
        name = cleanText(station.name or "NO STATION"),
        value = cleanText(station.frequency or ""),
        meta = station.station and "ON AIR" or "DEAD AIR",
        disabled = station.station == nil,
      }
    end
    local geo = drawListPanel(ww, wh, "POKéGEAR • RADIO", mode, rows,
      tonumber(screen.station) or 1, 0,
      { widthFrac = 0.50, maxW = 680, rowScale = 0.058,
        footer = "UP/DOWN TUNE    LEFT/RIGHT CARD    CIRCLE/B BACK" })
    local radio = screen.radio
    local text = ""
    if radio then text = cleanText((radio.top or "") .. " " .. (radio.bottom or "")) end
    drawMessage(ww, wh, geo.x, "RADIO", text ~= "" and text or "Tune a station with Up/Down.")
  elseif id == "map" then
    local current = type(screen.mapLandmark) == "function" and screen:mapLandmark() or nil
    local playerLoc = type(screen.playerLandmark) == "function" and screen:playerLandmark() or nil
    local rows = {
      { "CURSOR", cleanText(current and current.name or "UNKNOWN") },
      { "PLAYER", cleanText(playerLoc and playerLoc.name or "UNKNOWN") },
      { "REGION", type(screen.region) == "function" and tostring(screen:region()):upper() or "JOHTO" },
    }
    local geo = drawInfoRows(ww, wh, "POKéGEAR • MAP", mode, rows,
      { widthFrac = 0.48, maxW = 650, rowScale = 0.075,
        footer = "UP/DOWN LANDMARK    LEFT/RIGHT CARD    CIRCLE/B BACK" })
    drawMessage(ww, wh, geo.x, "MAP", "Use Up/Down to move the landmark cursor. The live location data and card-routing logic remain Gold's.")
  else
    local hour, minute, weekday = 0, 0, 1
    if type(screen.clockParts) == "function" then
      local ok, a, b, c = pcall(screen.clockParts, screen)
      if ok then hour, minute, weekday = a or 0, b or 0, c or 1 end
    end
    local days = { "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY" }
    local display = hour % 12
    if display == 0 then display = 12 end
    local rows = {
      { "DAY", days[weekday] or "DAY" },
      { "TIME", ("%d:%02d %s"):format(display, minute, hour < 12 and "AM" or "PM") },
    }
    local geo = drawInfoRows(ww, wh, "POKéGEAR • CLOCK", mode, rows,
      { widthFrac = 0.44, maxW = 590, rowScale = 0.085, footer = footerText })
    drawMessage(ww, wh, geo.x, "POKéGEAR", "Left/Right switches cards. Press A to open the selected card when the strip is active.")
  end

  endDraw()
  return true
end

local function pokedexModelPanel(screen, row, rightGeo, ww, wh)
  local G = love.graphics
  if not (G and rightGeo) then return false end
  local s = rightGeo.s or uiScaleFor(ww, wh)
  local margin = math.max(18 * s, wh * 0.025)
  local available = math.max(0, rightGeo.x - margin * 2)
  if available < 170 * s then return false end

  local w = math.min(available, ww * 0.46, 650 * s)
  -- v0.2.61: keep the same width and the close v0.2.59 model framing, but
  -- extend the VIEWER itself dramatically upward.  The previous panel started
  -- at the same Y as the dex list, so flying/tall animation poses could still
  -- put a head or wing above the viewport.  Preserve roughly the old bottom
  -- edge and move only the top toward the top of the screen.
  local oldH = math.max(220 * s, math.min(wh * 0.66, rightGeo.h * 0.80, 620 * s))
  local bottomY = math.min(wh - margin, rightGeo.y + oldH)
  local y = math.max(margin, math.min(rightGeo.y, wh * 0.035))
  local h = math.max(300 * s, bottomY - y)
  local x = margin
  local r = math.max(14 * s, wh * 0.022)
  panel(x, y, w, h, r, 0.80, s)

  local seen = row and row.seen ~= false
  local game = screen and screen.game
  local species = row and row.species
  local name = seen and (type(screen.monName) == "function"
    and screen:monName(species) or species) or "?????"
  name = cleanText(name or "POKéMON")
  local number = row and row.dex and ("#%03d"):format(tonumber(row.dex) or 0) or ""
  local state = row and row.caught and "CAUGHT" or (seen and "SEEN" or "UNKNOWN")
  header(G, name, (number ~= "" and (number .. "    " .. state) or state),
    x, y, w, math.max(46 * s, h * 0.13), wh, s)

  local top = y + math.max(56 * s, h * 0.15)
  local bottom = y + h - math.max(38 * s, h * 0.10)
  local modelH = math.max(80 * s, bottom - top)
  local modelX = x + margin * 0.55
  local modelW = w - margin * 1.10

  G.setColor(1, 1, 1, 0.035)
  roundRect("fill", modelX, top, modelW, modelH, r * 0.60)
  G.setColor(1, 1, 1, 0.075)
  G.ellipse("fill", modelX + modelW * 0.50, top + modelH * 0.84,
    modelW * 0.28, math.max(5 * s, modelH * 0.045))

  local canvas, info
  local preview = partyPreviewModule()
  if seen and species and preview and type(preview.render) == "function" then
    local fakeMon = { species = species }
    local ok, rendered, details = pcall(preview.render, screen, fakeMon,
      math.min(modelW, 480), math.min(modelH, 480), {
        -- Internal model-view overscan only; the glass Pokédex box stays the
        -- same size. v0.2.75 frames from the CURRENT posed mesh and fits both
        -- horizontal and vertical FOV, so portrait viewers no longer crop
        -- wings/tails at the sides.
        renderScale = 1.55,
        horizontalPadding = 1.12,
        verticalPadding = 1.10,
        cameraMargin = 1.08,
        -- Aim just above the true posed centre for a small amount of visual
        -- headroom without throwing away the pose-aware auto-fit.
        focusBias = 0.05,
      })
    if ok then canvas, info = rendered, details
    else M.lastError = "Pokedex model preview: " .. tostring(rendered) end
  elseif preview and type(preview.release) == "function" and not seen then
    -- Moving the cursor onto an unseen row must not leave the previous seen
    -- Pokemon's model resident in the Pokedex panel.
    pcall(preview.release, screen)
  end

  if canvas and type(canvas.getDimensions) == "function" then
    local cw, ch = canvas:getDimensions()
    if cw and ch and cw > 0 and ch > 0 then
      local k = math.min(modelW / cw, modelH / ch)
      local dw, dh = cw * k, ch * k
      G.setColor(1, 1, 1, 1)
      G.draw(canvas, modelX + (modelW - dw) * 0.5,
        top + (modelH - dh) * 0.5, 0, k, k)
    end
  else
    local f1 = font(math.max(15 * s, wh * 0.019))
    local f2 = font(math.max(10 * s, wh * 0.013))
    if f1 then G.setFont(f1) end
    G.setColor(1, 1, 1, 0.82)
    G.printf(not seen and "POKéMON UNKNOWN" or "3D MODEL UNAVAILABLE",
      modelX + margin * 0.4, top + modelH * 0.42,
      modelW - margin * 0.8, "center")
    if f2 then G.setFont(f2) end
    G.setColor(1, 1, 1, 0.46)
    local text
    if not seen then
      text = "SEE THIS POKéMON TO REVEAL ITS MODEL"
    elseif info and info.disabled then
      text = "3D POKéMON MODELS IS OFF IN MOD SETTINGS"
    elseif info and info.error then
      text = "THE STADIUM 2 PREVIEW COULD NOT BE BUILT"
    else
      text = "IMPORT / BUILD THE STADIUM 2 MODEL PACK IN MOD SETTINGS"
    end
    G.printf(text, modelX + margin * 0.4, top + modelH * 0.54,
      modelW - margin * 0.8, "center")
  end

  return true
end

local function numberedDexOrder(dex)
  local keyed = {}
  for species, entry in pairs((dex and dex.entries) or {}) do
    local n = tonumber(entry and entry.dex)
    if n then keyed[#keyed + 1] = { n = n, species = species } end
  end
  table.sort(keyed, function(a, b)
    if a.n == b.n then return tostring(a.species) < tostring(b.species) end
    return a.n < b.n
  end)
  local out = {}
  for i, row in ipairs(keyed) do out[i] = row.species end
  return out
end
M.numberedDexOrder = numberedDexOrder

local function pokedexEntryText(screen, row)
  if not row then return "" end
  local entry = screen.dex and screen.dex.entries and screen.dex.entries[row.species]
  if not entry then return "" end
  local page = tonumber(screen.page) or 1
  return page == 2 and (entry.text2 or entry.text or "") or (entry.text or entry.text2 or "")
end

local function pokedexRenderer(screen, ww, wh)
  -- AREA and the search/unown utility views are map/graphics-heavy and retain
  -- the native renderer for now.  The pause-launched main list, entry page and
  -- mode picker are fully modernized; falling back here is preferable to
  -- deleting useful geographic/search information just to make it dark.
  local view = screen.view or "list"
  if view ~= "list" and view ~= "entry" and view ~= "option" then return false end
  if not beginDraw(ww, wh) then return false end

  if view == "list" then
    local rows = {}
    for _, row in ipairs(type(screen.rows) == "table" and screen.rows or {}) do
      local name = row.seen and (type(screen.monName) == "function" and screen:monName(row.species) or row.species) or "?????"
      rows[#rows + 1] = {
        name = cleanText(name),
        value = row.dex and ("#%03d"):format(tonumber(row.dex) or 0) or "",
        meta = row.caught and "CAUGHT" or (row.seen and "SEEN" or "UNKNOWN"),
        disabled = not row.seen,
      }
    end
    local seen, caught = 0, 0
    if type(screen.totals) == "function" then
      local ok, a, b = pcall(screen.totals, screen)
      if ok then seen, caught = a or 0, b or 0 end
    end
    local mode = "NUMBER"
    local dexIndex = math.max(1, math.min(#rows > 0 and #rows or 1,
      tonumber(screen.index) or 1))
    local geo = drawListPanel(ww, wh, "POKéDEX",
      ("%s    SEEN %d    OWN %d    %d/%d"):format(mode, seen, caught,
        dexIndex, #rows),
      rows, dexIndex, nil,
      { widthFrac = 0.50, maxW = 680, rowScale = 0.060, maxRows = 10,
        scrollbar = true,
        footer = "D-PAD SELECT    CROSS/A ENTRY    SELECT OPTIONS    START SEARCH    CIRCLE/B BACK" })
    local current = type(screen.current) == "function" and screen:current() or nil
    pokedexModelPanel(screen, current, geo, ww, wh)
    drawMessage(ww, wh, geo.x, "POKéDEX",
      current and current.seen and "Open the highlighted POKéMON's entry with A." or "This POKéMON has not been seen yet.")
  elseif view == "entry" then
    local row = type(screen.current) == "function" and screen:current() or nil
    local name = row and (type(screen.monName) == "function" and screen:monName(row.species) or row.species) or "POKéMON"
    local entry = row and screen.dex and screen.dex.entries and screen.dex.entries[row.species] or nil
    local rows = {
      { "POKéMON", cleanText(name) },
      { "NUMBER", row and row.dex and ("#%03d"):format(tonumber(row.dex) or 0) or "—" },
      { "TYPE", cleanText(entry and entry.kind or "") },
      { "PAGE", tostring(tonumber(screen.page) or 1) .. "/2" },
    }
    local geo = drawInfoRows(ww, wh, "POKéDEX ENTRY", cleanText(name), rows,
      { widthFrac = 0.46, maxW = 620, rowScale = 0.071,
        footer = "UP/DOWN ACTION    CROSS/A SELECT    CIRCLE/B LIST" })
    pokedexModelPanel(screen, row, geo, ww, wh)
    drawMessage(ww, wh, geo.x, cleanText(name), pokedexEntryText(screen, row),
      { heightFrac = 0.20, maxH = 160 * uiScaleFor(ww, wh) })
    local actions = { "PAGE", "AREA", "CRY", "PRNT" }
    drawSmallChoice(ww, wh, "ENTRY ACTION", "POKéDEX", actions,
      tonumber(screen.entryAction) or 1, { widthFrac = 0.30, maxW = 400,
        footer = "UP/DOWN SELECT    CROSS/A CONFIRM    CIRCLE/B BACK" })
  else
    local labels = {}
    local optionRows = type(screen.optionRows) == "function" and screen:optionRows() or nil
    for _, row in ipairs(optionRows or {}) do labels[#labels + 1] = cleanText(row.label or row.mode) end
    if #labels == 0 then labels = { "NEW POKéDEX MODE", "OLD POKéDEX MODE", "A TO Z MODE" } end
    drawSmallChoice(ww, wh, "POKéDEX MODE", "SORT / DISPLAY", labels,
      tonumber(screen.optionIndex) or 1, { widthFrac = 0.38, maxW = 500 })
  end

  endDraw()
  return true
end

local function patchScreen(path, renderer)
  local ok, Class = pcall(require, path)
  if not (ok and type(Class) == "table" and type(Class.new) == "function") then
    return false, path .. ".new unavailable"
  end
  if Class._stadium2PauseSubmenuPatched then
    M.targets[path] = true
    return true
  end

  local nativeNew = Class.new
  local nativeDraw = Class.draw
  local nativeWide = Class.drawWidescreen
  local nativeOpaque = Class.isOpaque

  -- The modern Pokédex is a catalog first: keep its backing row array in
  -- strict National Dex number order so cursor/index/current() all agree with
  -- what is drawn. Native UI OFF retains Gold's NEW/OLD/A-Z behavior exactly.
  if path == "src.ui.gen2.PokedexMenu" and type(Class.order) == "function" then
    local nativeOrder = Class.order
    Class.order = function(self, ...)
      if customUIEnabled() then return numberedDexOrder(self and self.dex) end
      return nativeOrder(self, ...)
    end
  end

  -- The native Gen-2 entry action bar is horizontal, so the cart/engine uses
  -- LEFT/RIGHT for PAGE / AREA / CRY / PRNT.  Our custom skin deliberately
  -- presents those actions as a vertical phone-friendly list; make its input
  -- match what is drawn.  LEFT/RIGHT still reach the native handler as a
  -- compatibility shortcut, while UP/DOWN now advances this vertical list.
  if path == "src.ui.gen2.PokedexMenu" and type(Class.update) == "function" then
    local nativeUpdate = Class.update
    Class.update = function(self, ...)
      if customUIEnabled() and self and self._stadium2PauseSkin
         and self.view == "entry" and not self.newEntry then
        local input = self.game and self.game.input
        if input and type(input.wasPressed) == "function" then
          local count = 4
          if input:wasPressed("down") then
            self.entryAction = ((tonumber(self.entryAction) or 1) % count) + 1
          elseif input:wasPressed("up") then
            self.entryAction = ((tonumber(self.entryAction) or 1) - 2) % count + 1
          end
        end
      end
      return nativeUpdate(self, ...)
    end
  end

  Class.new = function(game, opts, ...)
    local fromPause = openedFromPause(game)
    -- v0.2.42: Party/Summary are the one pair that must work everywhere, not
    -- only when constructor timing happens to see StartMenu on top.  Gold uses
    -- PartyMenu for field, battle and item-target flows, while our live 3D
    -- battle PKMN selector is its own overlay.  Skinning these two universally
    -- makes the 3D party presentation deterministic on v0.1.83 and also gives
    -- the native fallback battle party/summary screens the same treatment.
    local universalParty = path == "src.ui.gen2.PartyMenu"
      or path == "src.ui.gen2.SummaryMenu"
    local tag = customUIEnabled() and (fromPause or universalParty)
    local instance = nativeNew(game, opts, ...)
    if tag and type(instance) == "table" then
      instance._stadium2PauseSkin = true
      instance._stadium2PauseSkinChain = fromPause and true or false
      instance._stadium2Party3dSkin = universalParty and true or false
      -- Glass party/summary screens intentionally leave the live world or
      -- battlefield visible underneath. Other pause submenus keep the old
      -- pause-only rule.
      instance.isOpaque = false
      M.tagged = M.tagged + 1
    end
    return instance
  end

  if type(nativeDraw) == "function" then
    Class.draw = function(self, ...)
      if not customUIEnabled() then
        if self then self.isOpaque = nativeOpaque end
        return nativeDraw(self, ...)
      end
      if self and self._stadium2PauseSkin then
        self.isOpaque = false
        local ww, wh = targetDimensions()
        local okDraw, handled = pcall(renderer, self, ww, wh)
        if okDraw and handled then M.lastError = nil return end
        if not okDraw then M.lastError = path .. ": " .. tostring(handled) end
      end
      return nativeDraw(self, ...)
    end
  end

  if type(nativeWide) == "function" then
    Class.drawWidescreen = function(self, ww, wh, ...)
      if not customUIEnabled() then
        if self then self.isOpaque = nativeOpaque end
        return nativeWide(self, ww, wh, ...)
      end
      if self and self._stadium2PauseSkin then
        self.isOpaque = false
        local okDraw, handled = pcall(renderer, self, ww, wh)
        if okDraw and handled then M.lastError = nil return end
        if not okDraw then M.lastError = path .. ": " .. tostring(handled) end
      end
      return nativeWide(self, ww, wh, ...)
    end
  end

  if path == "src.ui.gen2.PartyMenu" or path == "src.ui.gen2.SummaryMenu"
      or path == "src.ui.gen2.PokedexMenu" then
    local nativeExit = Class.exit
    Class.exit = function(self, ...)
      local preview = partyPreviewModule()
      if preview and type(preview.release) == "function" then
        pcall(preview.release, self)
      end
      if type(nativeExit) == "function" then return nativeExit(self, ...) end
    end
  end

  Class._stadium2PauseSubmenuPatched = true
  M.targets[path] = true
  return true
end

function M.install()
  if M.installed then return true end
  local okStart, Start = pcall(require, "src.ui.gen2.StartMenu")
  if not (okStart and type(Start) == "table") then
    return false, "src.ui.gen2.StartMenu unavailable"
  end
  StartMenuClass = Start

  local specs = {
    { "src.ui.gen2.PartyMenu", partyRenderer },
    { "src.ui.gen2.SummaryMenu", summaryRenderer },
    { "src.ui.gen2.PackMenu", packRenderer },
    { "src.ui.gen2.OptionsMenu", optionsRenderer },
    { "src.ui.gen2.SaveMenu", saveRenderer },
    { "src.ui.gen2.TrainerCard", trainerRenderer },
    { "src.ui.gen2.Pokegear", pokegearRenderer },
    { "src.ui.gen2.PokedexMenu", pokedexRenderer },
  }
  local failures = {}
  for _, spec in ipairs(specs) do
    local ok, err = patchScreen(spec[1], spec[2])
    if not ok then failures[#failures + 1] = err end
  end
  if #failures > 0 then
    return false, table.concat(failures, "; ")
  end
  M.installed = true
  return true
end

function M.status()
  return {
    installed = M.installed,
    draws = M.draws,
    tagged = M.tagged,
    targets = M.targets,
    lastError = M.lastError,
  }
end

return M
