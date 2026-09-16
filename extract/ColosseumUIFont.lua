-- Source-backed Pokemon Colosseum GC6E01 UI font bank reader/cache.
--
-- Font 0 is embedded in main.dol at VA 0x8027A500. Its raw retail bytes are
-- cached verbatim at one release-stable mod.cache path: cache identity never
-- includes a mod/build/extractor version, and a structurally valid payload is
-- reused without touching the source disc. This module intentionally has no
-- cache-delete path.
local M={}

local CACHE_PATH="cache/ui/gc6e01_font0.bin"
local SUPPLEMENTAL_CACHE_PATH="cache/ui/gc6e01_font0_supp.bin"
local PRESERVED_ROOT="cache/preserved/ui_font/v1/"
local DISC_ID="GC6E01"
local FONT_VA=0x8027A500
local RESOURCE_SPAN=0x14ED0
local FONT_ID=0
local DEFAULT_METRICS_WORD=0x00001616
local NODE_HEADER=0x01980001
local GLYPH_COUNT=408
local DATA_OFFSET=0x0CD0
-- main.c registers lbl_802BD260 immediately after lbl_8027A500 through the
-- same GSmsgFontOpen call. Both resources have key/fontId 0, so GSmsgFontOpen
-- appends this FONT_INFO node to font 0's lookup chain (gs_msg.c 2541-2553).
local SUPPLEMENTAL_VA=0x802BD260
local SUPPLEMENTAL_SPAN=0x38B0
local SUPPLEMENTAL_METRICS_WORD=0x00001616
local SUPPLEMENTAL_NODE_HEADER=0x003B0000
local SUPPLEMENTAL_GLYPH_COUNT=59
local SUPPLEMENTAL_DATA_OFFSET=0x01E8

local function be16(s,off)
  local a,b=s:byte(off+1,off+2)
  if not b then return nil end
  return a*0x100+b
end

local function be32(s,off)
  local a,b,c,d=s:byte(off+1,off+4)
  if not d then return nil end
  return ((a*0x100+b)*0x100+c)*0x100+d
end

local function signed8(value)
  return value>=0x80 and value-0x100 or value
end

-- Generic parser for the retail resource layout documented by gs_msg.c.
-- Offsets returned below are zero-based offsets into `bytes`, matching the
-- source structure and making an eventual UIMain renderer able to slice I4
-- glyph bytes without translating the retail metadata first.
local function parseBank(bytes)
  if type(bytes)~="string" then return nil,"font bank bytes required" end
  if #bytes<0x10 then return nil,"font bank is shorter than its resource/node header" end

  -- GSmsgFontOpen reads the resource key as a u16 at +0. The remaining two
  -- bytes of that first word are the registered nominal width/height; +4 is
  -- the byte span to the next resource. The FONT_INFO node itself starts +8.
  local metrics=be32(bytes,0x00)
  local fontId=be16(bytes,0x00)
  local defaultWidth=bytes:byte(0x03)
  local defaultHeight=bytes:byte(0x04)
  local nextResourceOffset=be32(bytes,0x04)
  local nodeBase=0x08
  local nodeHeader=be32(bytes,nodeBase+0x00)
  local dataOffset=be32(bytes,nodeBase+0x04)
  if not (fontId and metrics and defaultWidth and defaultHeight and nextResourceOffset and nodeHeader and dataOffset) then
    return nil,"font bank header is truncated"
  end

  local count=math.floor(nodeHeader/0x10000)
  local nodeType=nodeHeader%0x10000
  if count<=0 then return nil,"font bank contains no glyph rows" end
  local rowsOffset=nodeBase+0x10
  local rowsEnd=rowsOffset+count*8
  local bitmapBase=nodeBase+dataOffset
  if rowsEnd>#bytes then return nil,"font glyph table exceeds resource bytes" end
  if bitmapBase<rowsEnd or bitmapBase>#bytes then return nil,"font node data offset is outside the resource" end

  local glyphs,byCode={},{}
  local bitmapRegionLength=#bytes-bitmapBase
  local previousCode=-1
  for i=1,count do
    local off=rowsOffset+(i-1)*8
    local code=be16(bytes,off)
    local width=bytes:byte(off+3)
    local height=bytes:byte(off+4)
    local packed=be32(bytes,off+4)
    if not (code and width and height and packed) then
      return nil,("font glyph row %d is truncated"):format(i)
    end
    local yRaw=math.floor(packed/0x1000000)
    local bitmapOffset=packed%0x1000000
    local rowBytes=math.floor((width+1)/2) -- fn_800FD69C: ceil(width/2) I4 bytes/row.
    local bitmapLength=rowBytes*height
    if bitmapOffset>bitmapRegionLength or bitmapOffset+bitmapLength>bitmapRegionLength then
      return nil,("font glyph row %d bitmap exceeds node data"):format(i)
    end
    local glyph={
      index=i,code=code,width=width,height=height,yOffset=signed8(yRaw),
      bitmapOffset=bitmapOffset,bitmapDataOffset=bitmapBase+bitmapOffset,
      rowBytes=rowBytes,bitmapLength=bitmapLength,
    }
    if code<=previousCode then return nil,("font glyph row %d is not strictly code-sorted"):format(i) end
    previousCode=code
    glyphs[i]=glyph
    byCode[code]=glyph
  end

  return {
    bytes=bytes,rawBytes=bytes,
    fontId=fontId,defaultMetricsWord=metrics,defaultWidth=defaultWidth,defaultHeight=defaultHeight,
    nextResourceOffset=nextResourceOffset,nodeBase=nodeBase,
    nodeHeader=nodeHeader,nodeType=nodeType,glyphCount=count,
    glyphRowsOffset=rowsOffset,dataOffset=dataOffset,bitmapBase=bitmapBase,
    glyphs=glyphs,byCode=byCode,
  }
end

local function validateRetail(bytes)
  if type(bytes)~="string" then return nil,"font-0 cache is not raw bytes" end
  if #bytes~=RESOURCE_SPAN then
    return nil,("font-0 span mismatch: got 0x%X, expected 0x%X"):format(#bytes,RESOURCE_SPAN)
  end
  local descriptor,why=parseBank(bytes)
  if not descriptor then return nil,why end
  if descriptor.fontId~=FONT_ID then return nil,"font-0 id mismatch" end
  if descriptor.defaultMetricsWord~=DEFAULT_METRICS_WORD then return nil,"font-0 default metrics mismatch" end
  if descriptor.nextResourceOffset~=RESOURCE_SPAN then return nil,"font-0 resource span link mismatch" end
  if descriptor.nodeHeader~=NODE_HEADER then return nil,"font-0 node header mismatch" end
  if descriptor.glyphCount~=GLYPH_COUNT then return nil,"font-0 glyph count mismatch" end
  if descriptor.dataOffset~=DATA_OFFSET then return nil,"font-0 node data offset mismatch" end
  descriptor.discId=DISC_ID
  descriptor.source="GC6E01/main.dol font-0"
  descriptor.sourceVA=FONT_VA
  descriptor.resourceSpan=RESOURCE_SPAN
  descriptor.cachePath=CACHE_PATH
  descriptor.pixelFormat="I4"
  return descriptor
end

local function validateSupplemental(bytes)
  if type(bytes)~="string" then return nil,"font-0 supplemental cache is not raw bytes" end
  if #bytes~=SUPPLEMENTAL_SPAN then
    return nil,("font-0 supplemental span mismatch: got 0x%X, expected 0x%X"):format(#bytes,SUPPLEMENTAL_SPAN)
  end
  local descriptor,why=parseBank(bytes)
  if not descriptor then return nil,why end
  if descriptor.fontId~=FONT_ID then return nil,"font-0 supplemental id mismatch" end
  if descriptor.defaultMetricsWord~=SUPPLEMENTAL_METRICS_WORD then return nil,"font-0 supplemental metrics mismatch" end
  if descriptor.nextResourceOffset~=SUPPLEMENTAL_SPAN then return nil,"font-0 supplemental resource span link mismatch" end
  if descriptor.nodeHeader~=SUPPLEMENTAL_NODE_HEADER then return nil,"font-0 supplemental node header mismatch" end
  if descriptor.glyphCount~=SUPPLEMENTAL_GLYPH_COUNT then return nil,"font-0 supplemental glyph count mismatch" end
  if descriptor.dataOffset~=SUPPLEMENTAL_DATA_OFFSET then return nil,"font-0 supplemental data offset mismatch" end
  descriptor.discId=DISC_ID
  descriptor.source="GC6E01/main.dol font-0 supplemental node"
  descriptor.sourceVA=SUPPLEMENTAL_VA
  descriptor.resourceSpan=SUPPLEMENTAL_SPAN
  descriptor.cachePath=SUPPLEMENTAL_CACHE_PATH
  descriptor.pixelFormat="I4"
  descriptor.supplemental=true
  return descriptor
end

local DOL_GROUPS={
  {kind="text",count=7,fileBase=0x00,addressBase=0x48,sizeBase=0x90},
  {kind="data",count=11,fileBase=0x1C,addressBase=0x64,sizeBase=0xAC},
}

-- Map one complete virtual-address range through the DOL section table. BSS is
-- deliberately not considered: only file-backed text/data sections may satisfy
-- an extraction read. Ambiguous/overflowing/malformed mappings fail closed.
local function resolveDolRange(header,va,length)
  if type(header)~="string" or #header<0x100 then return nil,"DOL header is truncated" end
  va=tonumber(va);length=tonumber(length)
  if not va or not length or va%1~=0 or length%1~=0 or va<0 or length<0 then
    return nil,"invalid DOL virtual range"
  end
  local rangeEnd=va+length
  if rangeEnd>0x100000000 or rangeEnd<va then return nil,"DOL virtual range overflows u32" end

  local hit
  for _,group in ipairs(DOL_GROUPS) do
    for index=0,group.count-1 do
      local fileOffset=be32(header,group.fileBase+index*4)
      local address=be32(header,group.addressBase+index*4)
      local size=be32(header,group.sizeBase+index*4)
      if not (fileOffset and address and size) then return nil,"DOL section table is truncated" end
      if size>0 then
        local sectionEnd=address+size
        local fileEnd=fileOffset+size
        if address<=0 or fileOffset<0x100 or sectionEnd>0x100000000 or fileEnd>0x100000000 then
          return nil,("malformed DOL %s section %d"):format(group.kind,index)
        end
        if va>=address and rangeEnd<=sectionEnd then
          if hit then return nil,"DOL virtual range is ambiguously mapped" end
          local delta=va-address
          hit={kind=group.kind,index=index,address=address,size=size,
            sectionFileOffset=fileOffset,offsetInSection=delta,fileOffset=fileOffset+delta}
        end
      end
    end
  end
  if not hit then return nil,"DOL virtual range is not contained in a file-backed section" end
  return hit
end

local function gc6e01Header(disc)
  local header=disc and disc.header
  if type(header)~="string" or #header<0x424 then
    if not (disc and type(disc.read)=="function") then return nil,"GC6E01 disc reader unavailable" end
    local ok,value=pcall(disc.read,disc,0,0x440)
    if not ok then return nil,tostring(value) end
    header=value
  end
  if type(header)~="string" or #header<0x424 then return nil,"GameCube disc header is truncated" end
  if header:sub(1,6)~=DISC_ID then return nil,"source disc is not Pokemon Colosseum GC6E01" end
  if header:byte(7)~=0 or header:byte(8)~=0 then return nil,"unsupported GC6E01 disc revision" end
  return header
end

local function readDolVA(disc,va,length)
  if not (disc and type(disc.read)=="function") then return nil,"GC6E01 disc reader unavailable" end
  local discHeader,why=gc6e01Header(disc)
  if not discHeader then return nil,why end
  local dolDiscOffset=be32(discHeader,0x420)
  if not dolDiscOffset or dolDiscOffset<=0 then return nil,"GC6E01 main.dol offset is invalid" end
  local ok,dolHeader=pcall(disc.read,disc,dolDiscOffset,0x100)
  if not ok then return nil,tostring(dolHeader) end
  if type(dolHeader)~="string" or #dolHeader~=0x100 then return nil,"GC6E01 main.dol header short read" end
  local mapping,mapErr=resolveDolRange(dolHeader,va,length)
  if not mapping then return nil,mapErr end
  local readOk,bytes=pcall(disc.read,disc,dolDiscOffset+mapping.fileOffset,length)
  if not readOk then return nil,tostring(bytes) end
  if type(bytes)~="string" or #bytes~=length then return nil,"GC6E01 main.dol VA short read" end
  mapping.dolDiscOffset=dolDiscOffset
  return bytes,mapping
end

local function cacheRead(mod,path,label)
  local cache=mod and mod.cache
  if not (cache and type(cache.read)=="function") then return nil,"mod.cache.read unavailable" end
  local ok,value=pcall(cache.read,cache,path)
  if not ok then return nil,tostring(value) end
  if type(value)~="string" then return nil,(label or "font-0").." cache missing" end
  return value
end

local function cacheWrite(mod,path,bytes,label)
  local cache=mod and mod.cache
  if not (cache and type(cache.write)=="function") then return false,"mod.cache.write unavailable" end
  local ok,value,why=pcall(cache.write,cache,path,bytes)
  if not ok then return false,tostring(value) end
  if value==false or value==nil then return false,why or ((label or "font-0").." cache write failed") end
  return true
end

local function fingerprint(bytes)
  local a,b,c=1,0,0
  for start=1,#bytes,4096 do
    for i=start,math.min(#bytes,start+4095) do
      local v=bytes:byte(i)
      a=(a+v)%65521;b=(b+a)%65521;c=(c*257+v+1)%2147483647
    end
  end
  return string.format("%04x%04x-%08x-%d",b,a,c,#bytes)
end

local function preservedPath(bytes,name)
  return PRESERVED_ROOT..(name or "gc6e01_font0.bin").."."..fingerprint(bytes)..".bin"
end

-- Even an invalid/stale canonical payload is user-acquired data. Before an
-- automatic source repair may overwrite its pathname, retain those exact bytes
-- in a content-addressed namespace that is never part of generated-reset lists.
local function preserveExisting(mod,old,incoming,name)
  if type(old)~="string" or old==incoming then return nil,false end
  local cache=mod and mod.cache
  if not (cache and type(cache.read)=="function" and type(cache.write)=="function") then
    return nil,"font preservation cache API unavailable"
  end
  local archive=preservedPath(old,name)
  local ok,retained=pcall(cache.read,cache,archive)
  if ok and retained==old then return archive,false end
  if ok and type(retained)=="string" and retained~=old then
    local base=archive;local n=2
    repeat
      archive=base.."."..n;n=n+1
      local rok,current=pcall(cache.read,cache,archive)
      retained=rok and current or nil
    until retained==nil or retained==old or n>10000
    if n>10000 then return nil,"font preservation namespace exhausted" end
    if retained==old then return archive,false end
  end
  local wok,value,why=pcall(cache.write,cache,archive,old)
  if not wok or value==false or value==nil then return nil,why or value or "font preservation write failed" end
  local rok,verify=pcall(cache.read,cache,archive)
  if not rok or verify~=old then return nil,"font preservation readback failed" end
  return archive,true
end

local function extractAt(disc,va,span,validator)
  local bytes,mapping=readDolVA(disc,va,span)
  if not bytes then return nil,mapping end
  local descriptor,why=validator(bytes)
  if not descriptor then return nil,why end
  descriptor.dolSection=mapping
  descriptor.cached=false
  return descriptor
end

function M.extract(disc)
  return extractAt(disc,FONT_VA,RESOURCE_SPAN,validateRetail)
end

function M.extractSupplemental(disc)
  return extractAt(disc,SUPPLEMENTAL_VA,SUPPLEMENTAL_SPAN,validateSupplemental)
end

-- Cache-first by construction. A valid fixed-path payload is authoritative and
-- reused forever; no source opener/read and no cache write/delete occurs. Before
-- an invalid payload may be repaired at the canonical pathname, its exact bytes
-- are committed to the non-generated preservation namespace and read back.
function M.load(mod,openDisc)
  local cached,cacheReadWhy=cacheRead(mod,CACHE_PATH,"font-0")
  local primary=cached and validateRetail(cached) or nil
  if primary then primary.cached=true;primary.cacheStatus="reused" end

  local suppCached,suppReadWhy=cacheRead(mod,SUPPLEMENTAL_CACHE_PATH,"font-0 supplemental")
  local supplemental=suppCached and validateSupplemental(suppCached) or nil
  if supplemental then supplemental.cached=true;supplemental.cacheStatus="reused" end

  if primary and supplemental then
    primary.supplemental=supplemental
    primary.registeredGlyphRows=primary.glyphCount+supplemental.glyphCount
    return primary
  end

  -- Open the retail source at most once. A missing/new supplemental node never
  -- invalidates already-valid primary bytes; it is augmentation, not a recache.
  local disc,openWhy
  if type(openDisc)=="function" then
    local ok,value,why=pcall(openDisc)
    if ok then disc=value;openWhy=why else openWhy=tostring(value) end
  else
    openWhy="GC6E01 source opener unavailable"
  end

  if not primary then
    if not disc then return nil,openWhy or "GC6E01 source unavailable" end
    local descriptor,why=M.extract(disc)
    if not descriptor then return nil,why end
    local preserved,preserveWhy=preserveExisting(mod,cached,descriptor.bytes,"gc6e01_font0.bin")
    if preserveWhy and preserved==nil then return nil,preserveWhy end
    local wrote,writeWhy=cacheWrite(mod,CACHE_PATH,descriptor.bytes,"font-0")
    if not wrote then return nil,writeWhy end
    descriptor.preservedPrevious=preserved
    descriptor.cacheStatus=cached and "repaired" or "created"
    descriptor.cacheReadError=cached and nil or cacheReadWhy
    primary=descriptor
  end

  if not supplemental then
    if disc then
      local descriptor,why=M.extractSupplemental(disc)
      if descriptor then
        local preserved,preserveWhy=preserveExisting(mod,suppCached,descriptor.bytes,"gc6e01_font0_supp.bin")
        if not (preserveWhy and preserved==nil) then
          local wrote,writeWhy=cacheWrite(mod,SUPPLEMENTAL_CACHE_PATH,descriptor.bytes,"font-0 supplemental")
          if wrote then
            descriptor.preservedPrevious=preserved
            descriptor.cacheStatus=suppCached and "repaired" or "created"
            descriptor.cacheReadError=suppCached and nil or suppReadWhy
            supplemental=descriptor
          else
            primary.supplementalError=writeWhy
          end
        else
          primary.supplementalError=preserveWhy
        end
      else
        primary.supplementalError=why
      end
    else
      primary.supplementalError=openWhy or "GC6E01 source unavailable for supplemental font node"
    end
  end

  primary.supplemental=supplemental
  primary.registeredGlyphRows=primary.glyphCount+(supplemental and supplemental.glyphCount or 0)
  primary.registeredRetailFaceComplete=supplemental~=nil
  return primary
end

function M.glyphBytes(descriptor,glyphOrCode)
  if type(descriptor)~="table" or type(descriptor.bytes)~="string" then return nil,"font descriptor required" end
  local glyph=glyphOrCode
  if type(glyphOrCode)=="number" then glyph=descriptor.byCode and descriptor.byCode[glyphOrCode] end
  if type(glyph)~="table" then return nil,"glyph unavailable" end
  local off,len=tonumber(glyph.bitmapDataOffset),tonumber(glyph.bitmapLength)
  if not off or not len or off<0 or len<0 or off+len>#descriptor.bytes then return nil,"glyph range invalid" end
  return descriptor.bytes:sub(off+1,off+len)
end

M.cachePath=CACHE_PATH
M.supplementalCachePath=SUPPLEMENTAL_CACHE_PATH
M.preservedRoot=PRESERVED_ROOT
M.constants={
  discId=DISC_ID,fontVA=FONT_VA,resourceSpan=RESOURCE_SPAN,fontId=FONT_ID,
  defaultMetricsWord=DEFAULT_METRICS_WORD,nodeHeader=NODE_HEADER,
  glyphCount=GLYPH_COUNT,dataOffset=DATA_OFFSET,
  supplementalVA=SUPPLEMENTAL_VA,supplementalSpan=SUPPLEMENTAL_SPAN,
  supplementalMetricsWord=SUPPLEMENTAL_METRICS_WORD,supplementalNodeHeader=SUPPLEMENTAL_NODE_HEADER,
  supplementalGlyphCount=SUPPLEMENTAL_GLYPH_COUNT,supplementalDataOffset=SUPPLEMENTAL_DATA_OFFSET,
}
M._test={be16=be16,be32=be32,parseBank=parseBank,validateRetail=validateRetail,validateSupplemental=validateSupplemental,
  resolveDolRange=resolveDolRange,readDolVA=readDolVA,fingerprint=fingerprint,
  preservedPath=preservedPath,preserveExisting=preserveExisting}

return M
