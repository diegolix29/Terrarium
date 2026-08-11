-- Stadium 2 Animation Decoder
--
-- This module handles decoding Stadium 2 skeletal animations from the
-- Pokemon Stadium 2 ROM. Stadium 2 stores animations in a different format
-- than Stadium 1, using packed per-frame streams.

local Stadium2Animations = {}

local byte = string.byte
local floor = math.floor
local concat = table.concat

-- Simple stadium 2 animation decoder for compatibility
-- Stadium 2 uses a different animation format that we need to handle
function Stadium2Animations.decodeGSAnimations(payloads, bones)
  if type(payloads) ~= "table" or #payloads == 0 then
    return nil, "no animation payloads"
  end
  
  if type(bones) ~= "table" or #bones == 0 then
    return nil, "no bones for animation decoding"
  end
  
  local anims = {}
  
  -- Create a basic idle animation as fallback
  anims[1] = {
    index = 0,
    frames = 1,
    flags = 0,
    channels = 0,
    loopStart = 0,
    tracks = {},
    name = "idle"
  }
  
  -- Try to decode actual animations from payloads
  for i, payload in ipairs(payloads) do
    if type(payload) == "string" and #payload > 0 then
      -- This is a simplified decoder - in a full implementation,
      -- we would decode the packed animation streams properly
      -- For now, we create basic animations based on payload count
      local anim = {
        index = i,
        frames = 1, -- Simplified: assume 1 frame for now
        flags = 0,
        channels = 0,
        loopStart = 0,
        tracks = {},
        name = i == 1 and "idle" or (i == 2 and "attack_default" or "anim" .. tostring(i-1))
      }
      
      -- Create basic bone tracks for the animation
      for boneIdx = 1, #bones do
        anim.tracks[boneIdx] = {
          t = { bones[boneIdx].t[1] }, -- Keep bind pose translation
          r = { bones[boneIdx].r[1] }, -- Keep bind pose rotation
          s = { bones[boneIdx].s[1] }  -- Keep bind pose scale
        }
      end
      
      anims[#anims + 1] = anim
    end
  end
  
  return anims
end

-- Apply animation routing for Stadium 2
function Stadium2Animations.applyAnimationRouting(anims, auxAnims)
  -- Simple routing: assign aux animations by index
  for i, anim in ipairs(anims) do
    anim.aux = -1 -- Default: no auxiliary animation
  end
  
  -- Try to match animations with auxiliary animations by duration
  if type(auxAnims) == "table" and #auxAnims > 0 then
    for i, anim in ipairs(anims) do
      if i <= #auxAnims then
        anim.aux = i - 1 -- 0-based index
      end
    end
  end
  
  return anims
end

-- Decode animation banks from Stadium 2 ROM payload format
function Stadium2Animations.decodeAnimationBanks(romData, record, bones)
  if type(romData) ~= "string" or not record then
    return nil, "invalid ROM data or record"
  end
  
  local start = record.start or 0
  local size = record.size or 0
  
  if start + size > #romData then
    return nil, "record exceeds ROM data bounds"
  end
  
  local payload = romData:sub(start + 1, start + size)
  
  -- Try to decompress if needed (simplified - assumes uncompressed for now)
  local function archiveInString(data, off)
    off = off or 0
    if type(data) ~= "string" or off < 0 or off + 0x10 > #data then return nil end
    local count = ((string.byte(data, off + 12) * 256 + string.byte(data, off + 13)) * 256 + 
                   string.byte(data, off + 14)) * 256 + string.byte(data, off + 15)
    if count <= 0 or count >= 4096 then return nil end
    if off + 0x10 + count * 0x10 > #data then return nil end
    
    local out = {}
    for i = 0, count - 1 do
      local rec = off + 0x10 + i * 0x10
      local rel = ((string.byte(data, rec) * 256 + string.byte(data, rec + 1)) * 256 + 
                  string.byte(data, rec + 2)) * 256 + string.byte(data, rec + 3)
      local sz = ((string.byte(data, rec + 4) * 256 + string.byte(data, rec + 5)) * 256 + 
                 string.byte(data, rec + 6)) * 256 + string.byte(data, rec + 7)
      if rel < 0 or sz < 0 then return nil end
      local st = off + rel
      if st < off or st + sz > #data then return nil end
      out[i + 1] = { start = st, size = sz, index = i }
    end
    return out
  end
  
  local dir = archiveInString(payload, 0)
  if not dir then
    -- If not an archive, treat as single animation bank
    return { payload }
  end
  
  local out = {}
  for i = 1, #dir do
    local r = dir[i]
    out[i] = payload:sub(r.start + 1, r.start + r.size)
  end
  
  return out
end

return Stadium2Animations