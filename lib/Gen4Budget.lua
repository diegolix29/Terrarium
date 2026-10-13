-- Gen4Budget: ONE per-frame mesh-build budget shared by every Gen 4 effect.
--
-- WHY THIS EXISTS
--
-- Gen4Water, Gen4Sand, Gen4Trees and Gen4Grass each kept their own clock: a
-- chunk was built when "this effect's" few milliseconds were not spent, and
-- every one of them always built at least one. On a cold window (a new map, a
-- warp, a camera jump) all four fired in the SAME frame, and Gen4Trees even
-- allowed 40 ms while "filling". That is the hitch you feel on desktop, and on
-- a phone a single tree land can cost more than a whole frame budget.
--
-- Now every pass asks `allow()` before a build and reports it with `charge()`.
-- The frame always gets ONE build (so a window can never starve), and further
-- builds only while the shared total is under the limit. The limit is larger
-- while the world is covered by a warp fade (nothing on screen to hitch) and
-- smaller on a phone.
--
-- `nextFrame()` is called by Gen4Bridge after the engine closes the free
-- canvas. If it is ever missed, `allow()` notices the stale stamp itself.
--
-- A short log line summarises each burst of building (how many meshes, how
-- long, which effect), so "mobile takes long to load" can be read off the log
-- instead of guessed: look for `Gen4Budget: burst`.

local V = ...

local B = {
  builds = 0,          -- builds charged this frame
  spent = 0,           -- seconds charged this frame
  stamp = nil,         -- clock() of the first charge this frame
  covered = false,     -- set by Gen4Bridge: a warp fade hides the world
  idle = 0,            -- frames since the last build (burst detection)
  burst = nil,         -- { n, ms, max, kinds = { kind -> { n, ms, max } } }
  LOG = true,
}

local clock = (love and love.timer and love.timer.getTime) or os.clock

local function detectMobile()
  local ok, name = pcall(function() return love.system.getOS() end)
  return ok and (name == "Android" or name == "iOS") or false
end
B.mobile = detectMobile()

-- seconds of building ONE frame may spend beyond its guaranteed build
B.LIMITS = B.mobile
  and { steady = 0.003, warm = 0.008, covered = 0.020 }
  or  { steady = 0.005, warm = 0.012, covered = 0.030 }

local function limit(warm)
  if B.covered then return B.LIMITS.covered end
  return warm and B.LIMITS.warm or B.LIMITS.steady
end

local function reset()
  B.builds, B.spent, B.stamp = 0, 0, nil
end

local function flush()
  local b = B.burst
  B.burst = nil
  if not (B.LOG and b and b.n > 0) then return end
  local parts = {}
  for kind, k in pairs(b.kinds) do
    parts[#parts + 1] = ("%s %d x avg %.1f ms (max %.1f)"):format(kind, k.n, k.ms / k.n, k.max)
  end
  table.sort(parts)
  if V and V.mod and V.mod.log then
    V.mod.log:info(("Gen4Budget: burst of %d meshes, %.0f ms total, %s"):format(
      b.n, b.ms, table.concat(parts, "; ")))
  end
end

-- May a pass start another build right now? `warm` = the pass is still filling
-- its window (water, trees on a new ground), which earns the larger limit.
function B.allow(warm)
  if B.stamp and clock() - B.stamp > 0.25 then reset() end   -- missed nextFrame
  if B.builds == 0 then return true end
  return B.spent < limit(warm)
end

-- Report a finished build that started at t0 (clock()).
function B.charge(t0, kind)
  local t = clock()
  local ms = (t - t0) * 1000
  if not B.stamp then B.stamp = t0 end
  B.builds = B.builds + 1
  B.spent = B.spent + (t - t0)
  local b = B.burst
  if not b then b = { n = 0, ms = 0, kinds = {} }; B.burst = b end
  b.n, b.ms = b.n + 1, b.ms + ms
  local k = b.kinds[kind or "?"]
  if not k then k = { n = 0, ms = 0, max = 0 }; b.kinds[kind or "?"] = k end
  k.n, k.ms = k.n + 1, k.ms + ms
  if ms > k.max then k.max = ms end
  B.idle = 0
end

-- Call once per frame, after the frame's builds.
function B.nextFrame()
  if B.builds == 0 then
    B.idle = B.idle + 1
    if B.idle == 90 and B.burst then flush() end
  end
  reset()
end

return B
