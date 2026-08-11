-- Android-safe Pokemon Stadium announcer extractor / MORT decoder.
--
-- This is a Lua port/adaptation of StadiumBattleFX's MIT-licensed local
-- announcer tooling and SubDrag's reverse-engineered MORT decoder that ships
-- with StadiumBattleFX 2.1.7.  It exists here because a normal Gen1Recomp mod
-- cannot execute the desktop mort_decoder helper on Android.  No Nintendo
-- audio is bundled: the player selects their own Pokemon Stadium (USA) v1.0
-- image and the resulting PCM clips are written only to this mod's scoped
-- storage by Announcer.lua.
local V = ...
local M = {}

local StadiumRom = V.require("StadiumModelRom")

local SPEECH_ARCHIVE_OFFSET = 0x197C1E0
local CLIP_COUNT = 823
local SAMPLE_RATE = 16000
local SAMPLES_PER_FRAME = 0xA0
local U16 = 0x10000
local U32 = 0x100000000
local POW2 = {}
for i = 0, 32 do POW2[i] = 2 ^ i end

M.CLIP_COUNT = CLIP_COUNT
M.SAMPLE_RATE = SAMPLE_RATE
M.SAMPLES_PER_FRAME = SAMPLES_PER_FRAME
M.SPEECH_ARCHIVE_OFFSET = SPEECH_ARCHIVE_OFFSET

local function u16(v)
  v = v % U16
  if v < 0 then v = v + U16 end
  return v
end

local function s16(v)
  v = u16(v)
  if v >= 0x8000 then return v - U16 end
  return v
end

local function u32(v)
  v = v % U32
  if v < 0 then v = v + U32 end
  return v
end

local function s32(v)
  v = u32(v)
  if v >= 0x80000000 then return v - U32 end
  return v
end

-- MIPS/C++ arithmetic right shift for a signed 32-bit value.
local function sar(v, bits)
  return math.floor(s32(v) / POW2[bits])
end

local function be16(bytes, offset)
  local a, b = bytes:byte(offset + 1, offset + 2)
  if not b then error("announcer ROM read out of bounds", 0) end
  return a * 256 + b
end

local function be32(bytes, offset)
  local a, b, c, d = bytes:byte(offset + 1, offset + 4)
  if not d then error("announcer ROM read out of bounds", 0) end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function le16(v)
  v = u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function le32(v)
  v = u32(v)
  return string.char(
    v % 256,
    math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256,
    math.floor(v / 16777216) % 256)
end

local function wavFromPcm(pcmBytes, sampleRate)
  local dataSize = #pcmBytes
  return table.concat({
    "RIFF", le32(36 + dataSize), "WAVE",
    "fmt ", le32(16), le16(1), le16(1), le32(sampleRate),
    le32(sampleRate * 2), le16(2), le16(16),
    "data", le32(dataSize), pcmBytes,
  })
end

local function frameToBytes(samples)
  local out = {}
  for i = 1, #samples do
    local value = u16(samples[i])
    out[i] = string.char(value % 256, math.floor(value / 256))
  end
  return table.concat(out)
end

-- Flatten the nested S1 speech archive in exactly the same depth-first order
-- as tools/extract_stadium_announcer.py.  That order is the public announcer
-- routing's 000.wav .. 822.wav index order.
local function inventory(data)
  local clips = {}
  local active = {}

  local function visit(offset, length)
    if offset < 0 or offset + 4 > #data then
      error("Stadium speech archive points outside the ROM", 0)
    end
    local magic = data:sub(offset + 1, offset + 4)
    if magic:sub(1, 2) == "S1" then
      if active[offset] then error("cyclic Stadium speech archive", 0) end
      active[offset] = true
      local count = be16(data, offset + 2)
      local tableSize = 4 + count * 8
      if length and tableSize > length then
        error("Stadium speech table exceeds its archive entry", 0)
      end
      if offset + tableSize > #data then
        error("truncated Stadium speech table", 0)
      end
      for child = 0, count - 1 do
        local entry = offset + 4 + child * 8
        local relative = be32(data, entry)
        local childLength = be32(data, entry + 4)
        if relative < tableSize then
          error("Stadium speech child overlaps its table", 0)
        end
        if length and (relative > length or childLength > length - relative) then
          error("Stadium speech child exceeds its parent", 0)
        end
        visit(offset + relative, childLength)
      end
      active[offset] = nil
      return
    end

    if not length or length < 12 or magic ~= "MORT" then
      error("invalid Stadium MORT speech entry", 0)
    end
    local frameCount = be16(data, offset + 4)
    local sampleRate = be16(data, offset + 6)
    local wordCount = be32(data, offset + 8)
    if wordCount * 4 ~= length then
      error("Stadium MORT entry length does not match its header", 0)
    end
    if sampleRate ~= SAMPLE_RATE then
      error("Stadium announcer clip is not 16000 Hz", 0)
    end
    clips[#clips + 1] = {
      index = #clips,
      offset = offset,
      length = length,
      frames = frameCount,
      sampleRate = sampleRate,
    }
  end

  visit(SPEECH_ARCHIVE_OFFSET, nil)
  if #clips ~= CLIP_COUNT then
    error(("Stadium speech archive has %d clips; expected %d")
      :format(#clips, CLIP_COUNT), 0)
  end
  return clips
end

-- ---------------------------------------------------------------------------
-- MORT decoder
-- ---------------------------------------------------------------------------
-- The original helper emulates Stadium's 0x1000-byte DMA ring while decoding.
-- In a mod we already have the complete MORT entry in memory, so the bit reader
-- below addresses the same big-endian 32-bit words directly.  Bits within each
-- word are consumed least-significant first, matching ReadBitsFrom80045FF0Buffer.
local Decoder = {}
Decoder.__index = Decoder

function Decoder.new(data, clip)
  local self = setmetatable({}, Decoder)
  self.data = data
  self.base = clip.offset
  self.limit = clip.offset + clip.length
  self.frames = clip.frames
  self.frame = 0
  self.bitPos = 0x60 -- 12-byte MORT header
  self.skipResetCheck = 0
  self.resetPredictor = 0
  self.lastPredictorBase = 0x28
  self.currentSmoother = false
  self.predictor = {}
  self.smootherA = {}
  self.smootherB = {}
  self.sampleBuffer = {}
  self.lastSample = 0
  for i = 0, 0x9F do self.predictor[i] = 0 end
  for i = 0, 7 do
    self.smootherA[i] = 0
    self.smootherB[i] = 0
    self.sampleBuffer[i] = 0
  end
  return self
end

function Decoder:readWord(wordIndex)
  local offset = self.base + wordIndex * 4
  if offset < self.base or offset + 4 > self.limit then
    error("truncated Stadium MORT bitstream", 0)
  end
  return be32(self.data, offset)
end

function Decoder:readBits(count)
  local pos = self.bitPos
  local wordIndex = math.floor(pos / 32)
  local used = pos % 32
  local available = 32 - used
  local word = self:readWord(wordIndex)
  local value
  if count <= available then
    value = math.floor(word / POW2[used]) % POW2[count]
  else
    local low = math.floor(word / POW2[used]) % POW2[available]
    local need = count - available
    local nextWord = self:readWord(wordIndex + 1)
    value = low + (nextWord % POW2[need]) * POW2[available]
  end
  self.bitPos = pos + count
  return value
end

local SPC8_SHIFT = { -4, -3, -2, -2, -1, -1, -1, -1 }
local SPC8_SCALE = { 7, 7, 3, 7, 1, 3, 5, 7 }
local SPD0_SCALE = { 0x0CCD, 0x2CCD, 0x5333, 0x7FFF, 0x852A, 0 }

function Decoder:expandStack(c8, offset, values)
  local t0, t1
  if c8 < 8 then
    t0, t1 = SPC8_SHIFT[c8 + 1], SPC8_SCALE[c8 + 1]
  else
    t0, t1 = math.floor((c8 - 8) / 8), c8 % 8
  end
  local shift = 6 - t0
  local scale = t1 * 0x800 + 0x47FF
  local stack = {}
  for i = 0, 0x27 do stack[i] = 0 end
  for x = 0, 0x0C do
    local v = s16(values[x + 1] or 0)
    local n = sar(s32(((v * 0x2000) - 0x7000) * scale + 0x4000), 15)
    if shift > 0 then
      n = sar(s32(n + POW2[shift - 1]), shift)
    end
    values[x + 1] = u16(n)
    stack[offset + x * 3] = s16(n)
  end
  return stack
end

function Decoder:updatePredictor(spe0, spd0, stack)
  if spe0 >= 0x28 and spe0 <= 0x78 then
    self.lastPredictorBase = spe0
  end

  local pred = self.predictor
  for x = 0, 0x77 do pred[x] = u16(pred[x + 0x28]) end
  local scale = SPD0_SCALE[spd0 + 1] or 0
  for x = 0, 0x27 do
    local at = 0x78 - self.lastPredictorBase + x
    local prior = s16(pred[at] or 0)
    local filtered = sar(s32(prior * scale + 0x4000), 15)
    pred[0x78 + x] = u16(filtered + s16(stack[x] or 0))
  end
end

local COEFF = {
  { 0x20, 0x3333,  0x00004000 },
  { 0x20, 0x3333,  0x00004000 },
  { 0x10, 0x3333, -0x0332F000 },
  { 0x10, 0x3333,  0x04003C00 },
  { 0x08, 0x4B17,  0xFFC91B1C },
  { 0x08, 0x4444,  0x03BBF800 },
  { 0x04, 0x7ADE,  0x0147936C },
  { 0x04, 0x740C,  0x040D6B40 },
}

local function coefficient(raw, spec)
  local center, multiplier, constant = spec[1], spec[2], spec[3]
  local expr = s32(((s16(raw) - center) * 0x400) * multiplier + constant)
  -- The C++ expression is unsigned at the shift for several rows, but the
  -- difference from arithmetic shift is a multiple of 0x10000 after << 1;
  -- only the stored signed 16-bit result is observable here.
  return s16(sar(expr, 15) * 2)
end

local function smoothShape(v)
  v = s32(v)
  local negative = v < 0
  if negative then v = -v end
  if v < 0x2B33 then
    v = v * 2
  elseif v < 0x4E66 then
    v = v + 0x2B33
  else
    v = sar(v, 2) + 0x6600
  end
  if v > 0x7FFF then v = 0x7FFF end
  if negative then v = -v end
  return s16(v)
end

local function blendedAdjuster(a, b, mode)
  local value
  if mode == 1 then
    value = sar(a, 2) + sar(b, 1) + sar(b, 2)
  elseif mode == 2 then
    value = sar(a, 1) + sar(b, 1)
  elseif mode == 3 then
    value = sar(a, 1) + sar(b, 2) + sar(a, 2)
  else
    value = a
  end
  return smoothShape(value)
end

local function mulQ15(a, b)
  return sar(s32(s32(a) * s32(b) + 0x4000), 15)
end

function Decoder:makeAdjusters(mode)
  local current = self.currentSmoother and self.smootherB or self.smootherA
  local previous = self.currentSmoother and self.smootherA or self.smootherB
  local out = {}
  for i = 0, 7 do out[i] = blendedAdjuster(s16(current[i]), s16(previous[i]), mode) end
  return out
end

function Decoder:synthRange(offset, count, adjust, state, samples)
  local pred = self.predictor
  local a3 = state.a3
  local s = state.s
  for x = 0, count - 1 do
    local t2 = s16(pred[offset + x] or 0)
    t2 = s32(t2 - mulQ15(s[7], adjust[7]))
    t2 = s32(t2 - mulQ15(s[6], adjust[6]))
    s[7] = s32(mulQ15(adjust[6], t2) + s[6])
    t2 = s32(t2 - mulQ15(s[5], adjust[5]))
    s[6] = s32(mulQ15(adjust[5], t2) + s[5])
    t2 = s32(t2 - mulQ15(s[4], adjust[4]))
    s[5] = s32(mulQ15(adjust[4], t2) + s[4])
    t2 = s32(t2 - mulQ15(s[3], adjust[3]))
    s[4] = s32(mulQ15(adjust[3], t2) + s[3])
    t2 = s32(t2 - mulQ15(s[2], adjust[2]))
    s[3] = s32(mulQ15(adjust[2], t2) + s[2])
    t2 = s32(t2 - mulQ15(s[1], adjust[1]))
    s[2] = s32(mulQ15(adjust[1], t2) + s[1])
    t2 = s32(t2 - mulQ15(s[0], adjust[0]))
    s[1] = s32(mulQ15(adjust[0], t2) + s[0])
    s[0] = t2

    t2 = s32(t2 + mulQ15(0x6E14, a3))
    a3 = t2
    local doubled = s32(t2 * 2)
    local overflow = sar(sar(doubled, 15) + 1, 1)
    if overflow ~= 0 then
      doubled = overflow < 0 and -0x8000 or 0x7FFF
    end
    local packed = math.floor(u16(doubled) / 8) * 8
    samples[#samples + 1] = s16(packed)
  end
  state.a3 = a3
end

function Decoder:synthesize(spe8)
  local target = self.currentSmoother and self.smootherB or self.smootherA
  for i = 0, 7 do target[i] = coefficient(spe8[i + 1], COEFF[i + 1]) end

  local state = { a3 = s16(self.lastSample), s = {} }
  for i = 0, 7 do state.s[i] = s32(self.sampleBuffer[i]) end
  local samples = {}

  self:synthRange(0x00, 0x0D, self:makeAdjusters(1), state, samples)
  self:synthRange(0x0D, 0x0E, self:makeAdjusters(2), state, samples)
  self:synthRange(0x1B, 0x0D, self:makeAdjusters(3), state, samples)
  self:synthRange(0x28, 0x78, self:makeAdjusters(4), state, samples)

  for i = 0, 7 do self.sampleBuffer[i] = s32(state.s[i]) end
  self.lastSample = u32(s16(state.a3))
  self.currentSmoother = not self.currentSmoother
  return samples
end

function Decoder:decodeFrame()
  if self.frame >= self.frames then return nil end

  if self.skipResetCheck == 0 and self.resetPredictor == 0 then
    if self:readBits(1) ~= 0 then
      self.resetPredictor = self:readBits(4) + 1
    else
      self.skipResetCheck = self:readBits(7) + 1
    end
  end

  local samples
  if self.resetPredictor ~= 0 then
    samples = {}
    for i = 1, SAMPLES_PER_FRAME do samples[i] = 0 end
    self.resetPredictor = self.resetPredictor - 1
  else
    local spe8 = {
      self:readBits(6), self:readBits(6), self:readBits(5), self:readBits(5),
      self:readBits(4), self:readBits(4), self:readBits(3), self:readBits(3),
    }
    for _ = 1, 4 do
      local spe0 = self:readBits(7)
      local spd0 = self:readBits(2)
      local stackOffset = self:readBits(2)
      local spc8 = self:readBits(6)
      local values = {}
      for y = 1, 0x0D do values[y] = self:readBits(3) end
      local stack = self:expandStack(spc8, stackOffset, values)
      self:updatePredictor(spe0, spd0, stack)
    end
    self.skipResetCheck = self.skipResetCheck - 1
    samples = self:synthesize(spe8)
  end

  self.frame = self.frame + 1
  return samples
end

-- ---------------------------------------------------------------------------
-- Incremental import job
-- ---------------------------------------------------------------------------
function M.begin(bytes)
  local rom, err = StadiumRom.open(bytes)
  if not rom then return nil, err or "not an N64 ROM" end
  local data = rom.data
  local ok, clipsOrErr = pcall(inventory, data)
  if not ok then return nil, tostring(clipsOrErr) end
  return {
    data = data,
    clips = clipsOrErr,
    clip = 1,
    decoder = nil,
    pcm = nil,
    framesDone = 0,
    framesTotal = 0,
  }
end

function M.step(job, frameBudget, secondsBudget)
  if type(job) ~= "table" or type(job.clips) ~= "table" then
    return nil, "invalid announcer import job"
  end
  if job.clip > #job.clips then return { done = true } end

  -- LOVE timer is available on normal Gen1Recomp Android builds. os.clock is a
  -- headless/compatibility fallback so a host that hides love.timer still gets
  -- the same small time slice instead of decoding the full frameBudget at once.
  local timer = (love and love.timer and love.timer.getTime) or (os and os.clock)
  local startedAt = timer and timer() or nil
  frameBudget = math.max(1, math.floor(tonumber(frameBudget) or 4))
  secondsBudget = tonumber(secondsBudget) or 0.007
  local processed = 0

  while job.clip <= #job.clips and processed < frameBudget do
    local clip = job.clips[job.clip]
    if not job.decoder then
      job.decoder = Decoder.new(job.data, clip)
      job.pcm = {}
      job.framesDone = 0
      job.framesTotal = clip.frames
    end

    local ok, samples = pcall(job.decoder.decodeFrame, job.decoder)
    if not ok then return nil, tostring(samples) end
    if samples then
      job.pcm[#job.pcm + 1] = frameToBytes(samples)
      job.framesDone = job.framesDone + 1
      processed = processed + 1
    end

    if job.decoder.frame >= job.decoder.frames then
      local pcm = table.concat(job.pcm)
      local wav = wavFromPcm(pcm, clip.sampleRate)
      local completed = {
        index = clip.index,
        wav = wav,
        clipDone = job.clip,
        clipTotal = #job.clips,
        frames = clip.frames,
      }
      job.clip = job.clip + 1
      job.decoder = nil
      job.pcm = nil
      job.framesDone = 0
      job.framesTotal = 0
      return completed
    end

    if startedAt and timer and processed > 0 and timer() - startedAt >= secondsBudget then
      break
    end
  end

  return {
    progress = true,
    clipDone = job.clip - 1,
    clipTotal = #job.clips,
    frameDone = job.framesDone,
    frameTotal = job.framesTotal,
  }
end

function M.finish(job)
  if job then
    job.data, job.clips, job.decoder, job.pcm = nil, nil, nil, nil
  end
end

-- Narrow test hooks: no ROM/audio content, only deterministic decoder math.
M._test = {
  u16 = u16, s16 = s16, u32 = u32, s32 = s32, sar = sar,
  smoothShape = smoothShape, coefficient = coefficient,
  Decoder = Decoder, inventory = inventory,
}

return M
