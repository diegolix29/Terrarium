local V=...

-- Runtime bridge for Pokemon Colosseum's retail GC6E01 message font bank 0.
-- The source extractor owns acquisition/persistence of the exact main.dol bytes;
-- this module only decodes those bytes and presents them through LOVE's bitmap
-- font path. No TTF/lookalike font is involved.
local Source=V and V.ColosseumFontSource or nil
local F={version=1,source="GC6E01 main.dol lbl_8027A500 / GSmsgFontOpen font 0",_test={}}

local EXPECTED_FONT_ID=0
local EXPECTED_NATIVE_WIDTH=22
local EXPECTED_NATIVE_HEIGHT=22
local EXPECTED_GLYPHS=408
local EXPECTED_DATA_OFFSET=0x0CD0
local EXPECTED_BANK_BYTES=0x14ED0
local EXPECTED_NODE_HEADER=0x01980001
local SUPPLEMENTAL_GLYPHS=59
local SUPPLEMENTAL_DATA_OFFSET=0x01E8
local SUPPLEMENTAL_BANK_BYTES=0x38B0
local SUPPLEMENTAL_NODE_HEADER=0x003B0000
local PAGE_WIDTH=512

F.nativeWidth=EXPECTED_NATIVE_WIDTH
F.nativeHeight=EXPECTED_NATIVE_HEIGHT
F.glyphCount=EXPECTED_GLYPHS
F.primaryGlyphCount=EXPECTED_GLYPHS
F.supplementalGlyphCount=SUPPLEMENTAL_GLYPHS
F.bankBytes=EXPECTED_BANK_BYTES

local function be16(s,p)
  local a,b=s:byte(p+1,p+2)
  if not b then return nil end
  return a*256+b
end

local function be32(s,p)
  local a,b,c,d=s:byte(p+1,p+4)
  if not d then return nil end
  return ((a*256+b)*256+c)*256+d
end

local function s8(v)
  v=tonumber(v) or 0
  if v>=128 then return v-256 end
  return v
end

local function parseBank(raw,spec)
  spec=spec or {
    glyphs=EXPECTED_GLYPHS,dataOffset=EXPECTED_DATA_OFFSET,bankBytes=EXPECTED_BANK_BYTES,
    nodeHeader=EXPECTED_NODE_HEADER,
  }
  if type(raw)~="string" then return nil,"retail font bytes unavailable" end
  if #raw<spec.bankBytes then
    return nil,("retail font bank short: %d < %d"):format(#raw,spec.bankBytes)
  end
  local fontId=be16(raw,0)
  local nominalWidth=raw:byte(3)
  local nominalHeight=raw:byte(4)
  local nextOffset=be32(raw,4)
  local nodeBase=8
  local nodeHeader=be32(raw,nodeBase)
  local glyphCount=be16(raw,nodeBase)
  local dataOffset=be32(raw,nodeBase+4)
  if fontId~=EXPECTED_FONT_ID then return nil,"retail font id mismatch" end
  if nominalWidth~=EXPECTED_NATIVE_WIDTH or nominalHeight~=EXPECTED_NATIVE_HEIGHT then
    return nil,"retail font nominal metrics mismatch"
  end
  if nextOffset~=spec.bankBytes then return nil,"retail font bank span mismatch" end
  if nodeHeader~=spec.nodeHeader then return nil,"retail font node header mismatch" end
  if glyphCount~=spec.glyphs then return nil,"retail font glyph count mismatch" end
  if dataOffset~=spec.dataOffset then return nil,"retail font bitmap base mismatch" end

  local glyphs={}
  local prior=-1
  local glyphTable=nodeBase+0x10
  local bitmapBase=nodeBase+dataOffset
  for i=0,glyphCount-1 do
    local at=glyphTable+i*8
    local code=be16(raw,at)
    local width=raw:byte(at+3)
    local height=raw:byte(at+4)
    local packed=be32(raw,at+4)
    if not (code and width and height and packed) then return nil,"retail font glyph table truncated" end
    if code<=prior then return nil,"retail font glyph table is not strictly sorted" end
    prior=code
    local yOffset=s8(math.floor(packed/0x1000000)%0x100)
    local bitmapOffset=packed%0x1000000
    local rowBytes=math.floor((width+1)/2)
    local byteCount=rowBytes*height
    if bitmapBase+bitmapOffset+byteCount>#raw then
      return nil,("retail font glyph U+%04X bitmap exceeds bank"):format(code)
    end
    glyphs[#glyphs+1]={
      code=code,width=width,height=height,yOffset=yOffset,
      bitmapOffset=bitmapOffset,rowBytes=rowBytes,byteCount=byteCount,
      sourceRaw=raw,sourceBitmapBase=bitmapBase,
    }
  end
  return {
    raw=raw,fontId=fontId,nominalWidth=nominalWidth,nominalHeight=nominalHeight,
    glyphCount=glyphCount,dataOffset=dataOffset,bitmapBase=bitmapBase,glyphs=glyphs,
  }
end

local function packGlyphs(glyphs,pageWidth)
  pageWidth=math.max(64,math.floor(tonumber(pageWidth) or PAGE_WIDTH))
  local x,y,rowH=1,1,0
  for _,glyph in ipairs(glyphs or {}) do
    local w=math.max(1,tonumber(glyph.width) or 1)
    local h=math.max(1,tonumber(glyph.height) or 1)
    if x+w+1>pageWidth then
      x=1;y=y+rowH+2;rowH=0
    end
    glyph.atlasX=x;glyph.atlasY=y
    x=x+w+2
    if h>rowH then rowH=h end
  end
  return pageWidth,math.max(4,y+rowH+1)
end

local function sourceRaw()
  if type(Source)~="table" then return nil end
  local raw=Source.raw or Source.bytes or Source.data
  if type(raw)=="string" then return raw end
  if type(Source.bank)=="table" then
    raw=Source.bank.raw or Source.bank.bytes or Source.bank.data
    if type(raw)=="string" then return raw end
  end
  return nil
end

local function sourceSupplementalRaw()
  if type(Source)~="table" then return nil end
  local supp=Source.supplemental
  if type(supp)~="table" then return nil end
  local raw=supp.raw or supp.bytes or supp.data
  return type(raw)=="string" and raw or nil
end

local decoded=nil
local decodedRaw=nil
local decodedSupplementalRaw=nil
local sourceError=nil
local supplementalError=nil
local imageData=nil
local fontDefinition=nil
local fontCache={}

local function ensureDecoded()
  local raw=sourceRaw()
  if type(raw)~="string" then sourceError="retail font source cache unavailable";return nil,sourceError end
  local suppRaw=sourceSupplementalRaw()
  if decoded and decodedRaw==raw and decodedSupplementalRaw==suppRaw then return decoded end
  local primary,why=parseBank(raw)
  if not primary then sourceError=why;return nil,why end

  local supplemental=nil
  supplementalError=nil
  if suppRaw then
    supplemental,supplementalError=parseBank(suppRaw,{
      glyphs=SUPPLEMENTAL_GLYPHS,dataOffset=SUPPLEMENTAL_DATA_OFFSET,
      bankBytes=SUPPLEMENTAL_BANK_BYTES,nodeHeader=SUPPLEMENTAL_NODE_HEADER,
    })
  elseif type(Source)=="table" then
    supplementalError=Source.supplementalError
      or (type(Source.supplemental)=="table" and Source.supplemental.error)
      or "retail font-0 supplemental source cache unavailable"
  end

  -- Retail lookup searches the first registered node, then follows its linked
  -- next node. Preserve that priority exactly: supplemental duplicate codes do
  -- not replace primary glyphs (notably U+0020).
  local merged,seen={},{}
  for _,glyph in ipairs(primary.glyphs) do
    merged[#merged+1]=glyph;seen[glyph.code]=true
  end
  local supplementalAdded=0
  if supplemental then
    for _,glyph in ipairs(supplemental.glyphs) do
      if not seen[glyph.code] then
        merged[#merged+1]=glyph;seen[glyph.code]=true;supplementalAdded=supplementalAdded+1
      end
    end
  end
  table.sort(merged,function(a,b)return a.code<b.code end)
  primary.glyphs=merged
  primary.primaryGlyphCount=EXPECTED_GLYPHS
  primary.supplementalGlyphCount=supplemental and SUPPLEMENTAL_GLYPHS or 0
  primary.supplementalUniqueAdded=supplementalAdded
  primary.registeredGlyphRows=EXPECTED_GLYPHS+(supplemental and SUPPLEMENTAL_GLYPHS or 0)
  primary.uniqueGlyphCount=#merged
  primary.registeredRetailFaceComplete=supplemental~=nil
  primary.supplemental=supplemental
  packGlyphs(primary.glyphs,PAGE_WIDTH)
  decoded=primary;decodedRaw=raw;decodedSupplementalRaw=suppRaw
  sourceError=nil;imageData=nil;fontDefinition=nil;fontCache={}
  return decoded
end

local function nibble(byteValue,x)
  if x%2==0 then return math.floor(byteValue/16)%16 end
  return byteValue%16
end

local function ensureImage()
  local bank,why=ensureDecoded();if not bank then return nil,why end
  if imageData then return imageData end
  if not (love and love.image and type(love.image.newImageData)=="function") then
    return nil,"LOVE image module unavailable"
  end
  local pageW,pageH=PAGE_WIDTH,select(2,packGlyphs(bank.glyphs,PAGE_WIDTH))
  local ok,img=pcall(love.image.newImageData,pageW,pageH,"rgba8")
  if not ok or not img then return nil,tostring(img or "image allocation failed") end
  -- The retail source is I4. GSmsg copies these nibbles unchanged into its I4
  -- glyph texture; use the same 4-bit value as alpha on a white glyph so LOVE's
  -- text colour multiplies the source mask exactly.
  for _,glyph in ipairs(bank.glyphs) do
    local srcBase=(glyph.sourceBitmapBase or bank.bitmapBase)+glyph.bitmapOffset
    for y=0,glyph.height-1 do
      local row=srcBase+y*glyph.rowBytes
      for x=0,glyph.width-1 do
        local b=(glyph.sourceRaw or bank.raw):byte(row+math.floor(x/2)+1) or 0
        local a=nibble(b,x)
        if a~=0 then img:setPixel(glyph.atlasX+x,glyph.atlasY+y,1,1,1,a/15) end
      end
    end
  end
  imageData=img
  return imageData
end

local function ensureDefinition()
  local bank,why=ensureDecoded();if not bank then return nil,why end
  if fontDefinition then return fontDefinition end
  local _,pageH=packGlyphs(bank.glyphs,PAGE_WIDTH)
  local lines={
    'info face="Pokemon Colosseum GC6E01 Font 0" size=22 unicode=1',
    ("common lineHeight=22 base=0 scaleW=%d scaleH=%d pages=1 packed=0"):format(PAGE_WIDTH,pageH),
    'page id=0 file="gc6e01_font0.png"',
    ("chars count=%d"):format(#bank.glyphs),
  }
  for _,glyph in ipairs(bank.glyphs) do
    -- Retail special-cases U+0020 to half the bank's nominal width. Other
    -- glyphs advance by their exact per-glyph width (gs_msg.c fn_800FCA8C).
    local advance=(glyph.code==0x20) and math.floor(bank.nominalWidth/2) or glyph.width
    lines[#lines+1]=("char id=%d x=%d y=%d width=%d height=%d xoffset=0 yoffset=%d xadvance=%d page=0 chnl=15")
      :format(glyph.code,glyph.atlasX,glyph.atlasY,glyph.width,glyph.height,glyph.yOffset,advance)
  end
  fontDefinition=table.concat(lines,"\n").."\n"
  return fontDefinition
end

function F.font(px,filterMode)
  px=math.max(4,tonumber(px) or EXPECTED_NATIVE_HEIGHT)
  local filter=(filterMode=="nearest") and "nearest" or "linear"
  local key=("%.3f:%s"):format(px,filter)
  if fontCache[key]~=nil then return fontCache[key] or nil end
  local img,why=ensureImage();if not img then fontCache[key]=false;sourceError=why;return nil,why end
  local def,dwhy=ensureDefinition();if not def then fontCache[key]=false;sourceError=dwhy;return nil,dwhy end
  if not (love and love.filesystem and love.font and love.graphics
      and type(love.filesystem.newFileData)=="function"
      and type(love.font.newBMFontRasterizer)=="function"
      and type(love.graphics.newFont)=="function") then
    return nil,"LOVE BMFont runtime unavailable"
  end
  local okData,fileData=pcall(love.filesystem.newFileData,def,"gc6e01_font0.fnt")
  if not okData or not fileData then fontCache[key]=false;return nil,tostring(fileData or "BMFont FileData failed") end
  -- BMFont stores the physical retail 22px glyphs once. DPI scale changes only
  -- logical geometry, so arbitrary UI sizes still sample the original raster
  -- rather than a regenerated/lookalike outline.
  local dpiScale=EXPECTED_NATIVE_HEIGHT/px
  local okRaster,raster=pcall(love.font.newBMFontRasterizer,fileData,{img},dpiScale)
  if not okRaster or not raster then fontCache[key]=false;return nil,tostring(raster or "BMFont rasterizer failed") end
  local okFont,font=pcall(love.graphics.newFont,raster)
  if not okFont or not font then fontCache[key]=false;return nil,tostring(font or "graphics font failed") end
  if font.setFilter then pcall(font.setFilter,font,filter,filter) end
  fontCache[key]=font
  return font
end

function F.available()
  return ensureDecoded()~=nil
end

function F.status()
  local bank=ensureDecoded()
  return {
    ready=bank~=nil,source=F.source,fontId=bank and bank.fontId or EXPECTED_FONT_ID,
    nativeHeight=EXPECTED_NATIVE_HEIGHT,glyphCount=bank and bank.uniqueGlyphCount or 0,
    primaryGlyphCount=bank and bank.primaryGlyphCount or 0,
    supplementalGlyphCount=bank and bank.supplementalGlyphCount or 0,
    registeredGlyphRows=bank and bank.registeredGlyphRows or 0,
    registeredRetailFaceComplete=bank and bank.registeredRetailFaceComplete or false,
    exactRetailRaster=bank~=nil,variableAdvance=bank~=nil,verticalBearing=bank~=nil,
    supplementalError=bank and supplementalError or nil,
    error=bank and nil or sourceError,
  }
end

F._test.parseBank=parseBank
F._test.packGlyphs=packGlyphs
F._test.ensureDefinition=ensureDefinition
F._test.constants={fontId=EXPECTED_FONT_ID,width=EXPECTED_NATIVE_WIDTH,height=EXPECTED_NATIVE_HEIGHT,
  glyphs=EXPECTED_GLYPHS,dataOffset=EXPECTED_DATA_OFFSET,bankBytes=EXPECTED_BANK_BYTES,nodeHeader=EXPECTED_NODE_HEADER,
  supplementalGlyphs=SUPPLEMENTAL_GLYPHS,supplementalDataOffset=SUPPLEMENTAL_DATA_OFFSET,
  supplementalBankBytes=SUPPLEMENTAL_BANK_BYTES,supplementalNodeHeader=SUPPLEMENTAL_NODE_HEADER,pageWidth=PAGE_WIDTH}
return F
