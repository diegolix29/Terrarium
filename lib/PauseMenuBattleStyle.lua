-- Stadium 2 custom-battle-style renderer for Gold's actual Gen-2 START menu.
--
-- v0.2.39 keeps Gold's native menu logic and makes the panel tall enough to
-- show every ordinary START-menu entry at once.  If another mod injects more
-- rows than can physically fit, it falls back to a readable scrolling window.
--
-- The visual language intentionally mirrors lib/BattleControllerUI.lua's
-- custom PACK / POKéMON battle selectors: translucent navy glass, thin white
-- borders, rounded row capsules and the same selected-row treatment.
local V = ...
local mod = V and V.mod

local M = {
  installed = false,
  draws = 0,
  target = "src.ui.gen2.StartMenu",
  lastError = nil,
  spotifyCards = 0,
  spotifyLastError = nil,
}

local fonts = {}

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

local function panel(x, y, w, h, r, alpha, uiScale)
  local G = love.graphics
  G.setColor(0.018, 0.026, 0.045, alpha or 0.80)
  roundRect("fill", x, y, w, h, r)
  G.setColor(1, 1, 1, 0.20)
  G.setLineWidth(math.max(1, 2 * (uiScale or 1)))
  roundRect("line", x, y, w, h, r)
end

local function targetDimensions()
  local G = love and love.graphics
  if not G then return nil, nil end
  if type(G.getCanvas) == "function" then
    local ok, c = pcall(G.getCanvas)
    if ok and c and type(c.getDimensions) == "function" then
      local cw, ch = c:getDimensions()
      if cw and ch and cw > 0 and ch > 0 then return cw, ch end
    end
  end
  if type(G.getDimensions) == "function" then return G.getDimensions() end
  return nil, nil
end

local function uiScaleFor(ww, wh)
  local helper = mod and mod.exports and mod.exports.mobileUiScale
  if helper and type(helper.scale) == "function" then
    return helper.scale(ww, wh, 0.18, 1.15)
  end
  return math.max(0.18, math.min(1, math.min(ww / 800, wh / 600)))
end

local function cleanText(text)
  text = tostring(text or "")
  text = text:gsub("<PO><KE>", "POKé")
  text = text:gsub("<PK><MN>", "POKéMON")
  text = text:gsub("<POKE>", "POKé")
  text = text:gsub("<NEXT>", " ")
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

-- Same battle-selector geometry, but dynamically compress the row height just
-- enough to keep all normal pause rows visible.  At 600p+ eight rows fit with
-- no scroll.  A pathological hook list still receives a readable minimum row
-- height and uses a cursor-following window.
local function selectorGeometry(ww, wh, requestedRows)
  local s = uiScaleFor(ww, wh)
  local margin = math.max(18 * s, wh * 0.025)
  local w = math.min(ww * 0.42, 560 * s)
  local gap = math.max(7 * s, wh * 0.008)
  local headerH = math.max(48 * s, wh * 0.060)
  local footerH = math.max(42 * s, wh * 0.052)
  local baseRowH = math.max(54 * s, math.min(76 * s, wh * 0.076))
  local minRowH = math.max(31 * s, wh * 0.041)
  local available = math.max(1, wh - margin * 2)
  local rows = math.max(1, math.floor(tonumber(requestedRows) or 1))

  local function heightFor(n, rh)
    return headerH + rh * n + gap * (n + 1) + footerH
  end

  local rowH = baseRowH
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
  return x, y, w, h, rowH, gap, headerH, footerH, r, s, rows
end

local function selectorHeader(G, title, subtitle, x, y, w, headerH, wh, s)
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

local function selectorFooter(G, text, x, y, w, h, gap, wh, s)
  local metaFont = font(math.max(11 * s, wh * 0.013))
  if metaFont then G.setFont(metaFont) end
  G.setColor(1, 1, 1, 0.58)
  G.printf(controllerPrompt(text), x + gap * 1.5, y + h - math.max(30 * s, wh * 0.037),
           w - gap * 3, "left")
end

local function rowLabel(item)
  return cleanText(item and item.label or "")
end

local function rowDescription(item)
  local desc = item and item.desc
  if type(desc) == "table" then
    local a, b = cleanText(desc[1]), cleanText(desc[2])
    if a ~= "" and b ~= "" then return a .. " " .. b end
    return a ~= "" and a or b
  end
  return cleanText(desc)
end

local function spotifySnapshot(game)
  if not (mod and type(mod.find) == "function") then return nil end
  local okFind, found = pcall(mod.find, "spotify_gold_player")
  if not okFind or type(found) ~= "table" or type(found.exports) ~= "table" then
    return nil
  end
  local getter = found.exports.getNowPlaying
  if type(getter) ~= "function" then return nil end
  local okState, state = pcall(getter, game)
  if not okState then
    M.spotifyLastError = tostring(state)
    return nil
  end
  if type(state) ~= "table" then return nil end
  state._stadiumDrawAlbumArt = type(found.exports.drawAlbumArt) == "function"
    and found.exports.drawAlbumArt or nil
  state._stadiumDrawPauseArtwork = type(found.exports.drawStadiumPauseArtwork) == "function"
    and found.exports.drawStadiumPauseArtwork or nil
  M.spotifyLastError = nil
  return state
end

local function spotifyCardHeight(wh, s)
  return math.max(92 * s, math.min(126 * s, wh * 0.145))
end

local function spotifySelected(menu)
  local list = menu and menu.list
  local item = list and type(list.current) == "function" and list:current() or nil
  return cleanText(item and item.label or "") == "SPOTIFY"
end

local DISC_COLORS = {
  { 0.85, 0.35, 0.42 }, { 0.95, 0.68, 0.24 }, { 0.78, 0.90, 0.30 },
  { 0.28, 0.82, 0.60 }, { 0.28, 0.68, 0.95 }, { 0.48, 0.42, 0.90 },
}

local function drawSpotifyDisc(cx, cy, diameter, angle)
  local G = love.graphics
  local r = math.max(4, diameter * 0.5)
  G.push("all")
  G.translate(cx, cy)
  G.rotate(tonumber(angle) or 0)
  G.setColor(0.82, 0.84, 0.86, 0.98)
  G.circle("fill", 0, 0, r)
  G.setColor(1, 1, 1, 0.44)
  G.setLineWidth(math.max(1, diameter * 0.012))
  G.circle("line", 0, 0, r * 0.95)
  G.setColor(0.38, 0.42, 0.47, 0.24)
  G.circle("line", 0, 0, r * 0.72)
  G.circle("line", 0, 0, r * 0.54)
  for i, c in ipairs(DISC_COLORS) do
    local a = (i - 1) * (math.pi * 2 / #DISC_COLORS) - 0.18
    local b = a + 0.30
    G.setColor(c[1], c[2], c[3], 0.23)
    G.polygon("fill", 0, 0,
      math.cos(a) * r * 0.92, math.sin(a) * r * 0.92,
      math.cos(b) * r * 0.92, math.sin(b) * r * 0.92)
  end
  G.setColor(1, 1, 1, 0.34)
  G.polygon("fill", 0, 0,
    math.cos(-0.78) * r * 0.88, math.sin(-0.78) * r * 0.88,
    math.cos(-0.60) * r * 0.88, math.sin(-0.60) * r * 0.88)
  G.setColor(0.33, 0.35, 0.38, 0.96)
  G.circle("fill", 0, 0, r * 0.25)
  G.setColor(0.70, 0.72, 0.74, 0.88)
  G.circle("line", 0, 0, r * 0.34)
  G.setColor(0.02, 0.02, 0.025, 1)
  G.circle("fill", 0, 0, r * 0.105)
  G.pop()
end

-- v0.2.90: artwork-only pause presentation.  This is deliberately independent
-- of Spotify's own UI renderer so it cannot replace or disable the modern
-- pause menu.  The album cover is drawn last, hiding the left half of the CD.
local function drawSpotifyLargeArtwork(menu, ww, wh, menuX, s, state)
  if not state then return 0 end
  local cover = state.cover
  local customDraw = state._stadiumDrawPauseArtwork
  if type(customDraw) ~= "function"
      and not (cover and type(cover.getDimensions) == "function") then return 0 end

  local G = love.graphics
  local margin = math.max(18 * s, wh * 0.025)
  local available = math.max(0, menuX - margin * 2)
  if available < 180 * s then return 0 end

  -- Large, borderless bottom-left art while the modern glass menu remains on
  -- the right.  Size is intentionally much larger than the old compact card.
  local size = math.min(wh * 0.46, available * 0.56)
  size = math.max(190 * s, size)
  local x = margin
  local y = wh - size - margin

  -- Preferred path: the custom Spotify Stadium Edition owns its disc/cover
  -- composition.  This keeps its rotation state and future art styling in one
  -- place without letting Spotify replace the pause menu itself.
  if type(customDraw) == "function" then
    local okDraw, result = pcall(customDraw, x, y, size, menu and menu.game, {
      pop = 0.28,
      discScale = 0.88,
      maxWidth = available,
      menuX = menuX,
      margin = margin,
    })
    if okDraw and result ~= false then
      M.spotifyCards = M.spotifyCards + 1
      return size
    end
    if not okDraw then M.spotifyLastError = tostring(result) end
  end

  -- Compatibility fallback for ordinary Spotify builds: Stadium draws the
  -- exact same artwork-only presentation itself.
  if not (cover and type(cover.getDimensions) == "function") then return 0 end
  local discSize = size * 0.88
  local discCx = x + size * 0.91
  local discCy = y + size * 0.50
  drawSpotifyDisc(discCx, discCy, discSize, state.discAngle or 0)

  local okDim, iw, ih = pcall(cover.getDimensions, cover)
  if not (okDim and iw and ih and iw > 0 and ih > 0) then return 0 end
  G.setColor(1, 1, 1, 1)
  G.draw(cover, x, y, 0, size / iw, size / ih)

  M.spotifyCards = M.spotifyCards + 1
  return size
end

local function drawSpotifyCard(menu, ww, wh, menuX, s, state)
  if not state then return 0 end
  local G = love.graphics
  local margin = math.max(18 * s, wh * 0.025)
  local available = math.max(0, menuX - margin * 2)
  if available < 130 * s then return 0 end

  local w = math.min(ww * 0.54, 720 * s, available)
  local h = spotifyCardHeight(wh, s)
  local x, y = margin, wh - h - margin
  local r = math.max(14 * s, wh * 0.022)
  panel(x, y, w, h, r, 0.86, s)

  local pad = math.max(9 * s, h * 0.085)
  local art = math.max(1, h - pad * 2)
  local drewCover = false
  if type(state._stadiumDrawAlbumArt) == "function" then
    local okDraw, result = pcall(state._stadiumDrawAlbumArt,
      x + pad, y + pad, art, art, menu and menu.game)
    drewCover = okDraw and result ~= false
    if not okDraw then M.spotifyLastError = tostring(result) end
  end
  local cover = state.cover
  if not drewCover and cover and type(cover.getDimensions) == "function" then
    local okDim, iw, ih = pcall(cover.getDimensions, cover)
    if okDim and iw and ih and iw > 0 and ih > 0 then
      G.setColor(1, 1, 1, 1)
      G.draw(cover, x + pad, y + pad, 0, art / iw, art / ih)
      drewCover = true
    end
  end
  if not drewCover then
    G.setColor(1, 1, 1, 0.08)
    roundRect("fill", x + pad, y + pad, art, art, r * 0.45)
    local pf = font(math.max(10 * s, h * 0.10))
    if pf then G.setFont(pf) end
    G.setColor(1, 1, 1, 0.48)
    G.printf("SPOTIFY", x + pad, y + h * 0.46, art, "center")
  end

  local tx = x + pad * 2 + art
  local tw = math.max(1, w - (tx - x) - pad)
  local labelF = font(math.max(9 * s, wh * 0.012))
  local titleF = font(math.max(14 * s, wh * 0.018))
  local artistF = font(math.max(11 * s, wh * 0.014))
  if labelF then G.setFont(labelF) end
  G.setColor(1, 1, 1, 0.52)
  G.print((state.isPlaying and "NOW PLAYING" or cleanText(state.status or "SPOTIFY")),
          tx, y + pad * 0.95)
  if titleF then G.setFont(titleF) end
  G.setColor(1, 1, 1, 0.98)
  G.print(clipped(state.track or "NO TRACK", G.getFont(), tw), tx, y + h * 0.33)
  if artistF then G.setFont(artistF) end
  G.setColor(1, 1, 1, 0.66)
  G.print(clipped(state.artist or "", G.getFont(), tw), tx, y + h * 0.57)

  local barY = y + h - pad * 1.25
  local barH = math.max(3 * s, 2)
  G.setColor(1, 1, 1, 0.12)
  roundRect("fill", tx, barY, tw, barH, barH)
  local duration = tonumber(state.durationMs) or 0
  if duration > 0 then
    local ratio = math.max(0, math.min(1, (tonumber(state.progressMs) or 0) / duration))
    G.setColor(1, 1, 1, 0.72)
    roundRect("fill", tx, barY, tw * ratio, barH, barH)
  end

  M.spotifyCards = M.spotifyCards + 1
  return h
end

local function drawRows(menu, x, y, w, rowH, gap, headerH, r, wh, s, rows)
  local G = love.graphics
  local list = menu.list
  local items = menu.items or (list and list.items) or {}
  local n = #items
  if n <= 0 then return end

  local cursor = math.max(1, math.min(math.floor(tonumber(list and list.index) or 1), n))
  local first = 1
  if n > rows then
    local engineFirst = math.max(1, math.floor(tonumber(list and list.scroll) or 0) + 1)
    first = engineFirst
    if cursor < first then first = cursor end
    if cursor > first + rows - 1 then first = cursor - rows + 1 end
    if first + rows - 1 > n then first = math.max(1, n - rows + 1) end
  end

  local nameFont = font(math.max(14 * s, math.min(18 * s, rowH * 0.31)))
  local metaFont = font(math.max(9 * s, math.min(12 * s, rowH * 0.22)))

  for slot = 1, rows do
    local i = first + slot - 1
    local item = items[i]
    if not item then break end
    local ry = y + headerH + gap + (slot - 1) * (rowH + gap)
    local on = i == cursor

    G.setColor(1, 1, 1, on and 0.17 or 0.07)
    roundRect("fill", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    if on then
      G.setColor(1, 1, 1, 0.72)
      G.setLineWidth(math.max(1, 2 * s))
      roundRect("line", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    end

    if nameFont then G.setFont(nameFont) end
    G.setColor(1, 1, 1, 0.98)
    local lx = x + gap * 2.2
    local maxW = w - gap * 4.4
    local meta = rowDescription(item)
    local nameY = meta ~= "" and (ry + rowH * 0.14) or (ry + rowH * 0.31)
    G.print(clipped(rowLabel(item), G.getFont(), maxW), lx, nameY)

    if meta ~= "" and rowH >= 34 * s then
      if metaFont then G.setFont(metaFont) end
      G.setColor(1, 1, 1, 0.58)
      G.print(clipped(meta, G.getFont(), maxW), lx, ry + rowH * 0.60)
    end
  end
end

local function drawDescription(menu, ww, wh, menuX, s, bottomReserve)
  if menu.showDescription == false then return end
  local list = menu.list
  local item = list and type(list.current) == "function" and list:current() or nil
  local text = rowDescription(item)
  if text == "" then return end

  local G = love.graphics
  local margin = math.max(18 * s, wh * 0.025)
  local available = math.max(0, menuX - margin * 2)
  if available < 70 * s then return end
  local w = math.min(ww * 0.54, 720 * s, available)
  local h = math.max(66 * s, math.min(105 * s, wh * 0.105))
  local x = margin
  local reserve = math.max(0, tonumber(bottomReserve) or 0)
  local y = wh - h - margin - reserve
  if y < margin then return end
  local r = math.max(14 * s, wh * 0.022)
  panel(x, y, w, h, r, 0.78, s)

  local titleFont = font(math.max(15 * s, wh * 0.020))
  local metaFont = font(math.max(11 * s, wh * 0.013))
  if titleFont then G.setFont(titleFont) end
  G.setColor(1, 1, 1, 0.96)
  G.print(clipped(rowLabel(item), G.getFont(), w - h * 0.44),
          x + h * 0.22, y + h * 0.17)
  if metaFont then G.setFont(metaFont) end
  G.setColor(1, 1, 1, 0.62)
  G.printf(text, x + h * 0.22, y + h * 0.55,
           w - h * 0.44, "left")
end

local function drawConfirm(menu, ww, wh)
  local G = love.graphics
  local x, y, w, h, rowH, gap, headerH, _, r, s = selectorGeometry(ww, wh, 2)
  panel(x, y, w, h, r, 0.82, s)
  selectorHeader(G, "RETURN TO TITLE?", "UNSAVED PROGRESS WILL BE LOST",
                 x, y, w, headerH, wh, s)

  local nameFont = font(math.max(15 * s, wh * 0.019))
  local choices = { "YES", "NO" }
  local selected = math.max(1, math.min(2, tonumber(menu.confirmChoice) or 2))
  for i = 1, 2 do
    local ry = y + headerH + gap + (i - 1) * (rowH + gap)
    local on = i == selected
    G.setColor(1, 1, 1, on and 0.17 or 0.07)
    roundRect("fill", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    if on then
      G.setColor(1, 1, 1, 0.72)
      G.setLineWidth(math.max(1, 2 * s))
      roundRect("line", x + gap, ry, w - gap * 2, rowH, r * 0.55)
    end
    if nameFont then G.setFont(nameFont) end
    G.setColor(1, 1, 1, 0.98)
    G.print(choices[i], x + gap * 2.2, ry + rowH * 0.32)
  end

  selectorFooter(G,
    "D-PAD / ARROWS SELECT    CROSS/A CONFIRM    CIRCLE/B BACK",
    x, y, w, h, gap, wh, s)

  local margin = math.max(18 * s, wh * 0.025)
  local available = math.max(0, x - margin * 2)
  if available >= 70 * s then
    local mw = math.min(ww * 0.54, 720 * s, available)
    local mh = math.max(66 * s, math.min(105 * s, wh * 0.105))
    local mx, my = margin, wh - mh - margin
    local mr = math.max(14 * s, wh * 0.022)
    panel(mx, my, mw, mh, mr, 0.78, s)
    local f = font(math.max(15 * s, wh * 0.020))
    if f then G.setFont(f) end
    G.setColor(1, 1, 1, 0.96)
    G.printf("Return to the title screen?", mx + mh * 0.22, my + mh * 0.29,
             mw - mh * 0.44, "left")
  end
end

local function drawPause(menu)
  local G = love and love.graphics
  local list = menu and menu.list
  if not (G and menu and list and type(menu.items) == "table") then return false end

  -- When a pause-launched submenu is on top, keep the START menu itself out of
  -- the picture.  Gold's world is still visible beneath the transparent modern
  -- submenu, instead of showing two glass lists on top of each other.
  local stack = menu.game and menu.game.stack
  if stack and type(stack.top) == "function" then
    local ok, top = pcall(stack.top, stack)
    if ok and top and top ~= menu then return true end
  end

  local ww, wh = targetDimensions()
  if not (ww and wh and ww > 0 and wh > 0) then return false end

  G.push("all")
  G.origin()
  if type(G.setBlendMode) == "function" then G.setBlendMode("alpha") end

  if menu.phase == "confirm" then
    drawConfirm(menu, ww, wh)
  else
    local requested = math.max(1, #menu.items)
    local x, y, w, h, rowH, gap, headerH, _, r, s, rows =
      selectorGeometry(ww, wh, requested)
    panel(x, y, w, h, r, 0.82, s)

    local save = menu.save or (menu.game and menu.game.save) or {}
    local player = save.player or {}
    local playerName = cleanText(player.name or "GOLD")
    local index = math.max(1, math.min(#menu.items, tonumber(list.index) or 1))
    local subtitle = playerName
    if #menu.items > rows then
      subtitle = subtitle .. "    " .. index .. "/" .. #menu.items
    end
    selectorHeader(G, "PAUSE MENU", subtitle, x, y, w, headerH, wh, s)
    drawRows(menu, x, y, w, rowH, gap, headerH, r, wh, s, rows)
    selectorFooter(G,
      "D-PAD / ARROWS SELECT    CROSS/A CONFIRM    CIRCLE/B BACK",
      x, y, w, h, gap, wh, s)
    local spotify = spotifySnapshot(menu.game)
    local artH = spotify and drawSpotifyLargeArtwork(menu, ww, wh, x, s, spotify) or 0
    if not spotifySelected(menu) then
      local spotifyGap = artH > 0 and math.max(12 * s, wh * 0.014) or 0
      drawDescription(menu, ww, wh, x, s, artH + spotifyGap)
    end
  end

  G.pop()
  M.draws = M.draws + 1
  return true
end

function M.install()
  if M.installed then return true end

  local ok, StartMenu = pcall(require, "src.ui.gen2.StartMenu")
  if not (ok and type(StartMenu) == "table" and type(StartMenu.draw) == "function") then
    return false, "src.ui.gen2.StartMenu.draw unavailable"
  end
  if StartMenu._stadium2CustomBattlePausePatched then
    M.installed = true
    return true
  end

  local nativeDraw = StartMenu.draw
  StartMenu.draw = function(self, ...)
    if not customUIEnabled() then return nativeDraw(self, ...) end
    local okDraw, handled = pcall(drawPause, self)
    if okDraw and handled then
      M.lastError = nil
      return
    end
    if not okDraw then M.lastError = tostring(handled) end
    return nativeDraw(self, ...)
  end

  StartMenu._stadium2CustomBattlePausePatched = true
  M.installed = true
  return true
end

function M.status()
  return {
    installed = M.installed,
    draws = M.draws,
    target = M.target,
    lastError = M.lastError,
    spotifyCards = M.spotifyCards,
    spotifyLastError = M.spotifyLastError,
  }
end

return M
