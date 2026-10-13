-- Run from the mod root with: texlua tools/test_gen4_dupes.lua
local fails, passes = 0, 0
local function check(c, m) if c then passes = passes + 1 else fails = fails + 1; print("FAIL: " .. m) end end

-- Minimal stubs: only what Gen4WorldHost / Gen4Bridge need at load + install.
love = { graphics = {} }
local Ground = {}
local calls = { drawFree = 0, endFree = 0, freeEntity = 0 }
function Ground:drawFree() calls.drawFree = calls.drawFree + 1; return true end
function Ground:endFree() calls.endFree = calls.endFree + 1 end
function Ground:freeEntity() calls.freeEntity = calls.freeEntity + 1; return true end
local engine = { ["src.render.Gen4Ground"] = Ground, ["src.render.TileRenderer"] = {} }
local V = { engineRequire = function(n) return engine[n] end, mod = {} }
V.require = function(n) return V[n] end
V.optional = function(n) return V[n] end
package.loaded["src.render.Gen4Ground"] = Ground
package.loaded["src.render.TileRenderer"] = engine["src.render.TileRenderer"]

-- Host loads with the V table the existing arena test uses
local function loadHost() return assert(loadfile("lib/Gen4WorldHost.lua"))(V) end
local Host = loadHost()

-- 1. isSkipped matches within tolerance, not only on the same rounded pixel
Host._skipPoints = { { 100, 200 } }
Host._skipFeet = {}
check(Host.isSkipped(100, 200), "exact position is skipped")
check(Host.isSkipped(101.4, 199.2), "position within 2px is skipped (old key would miss at x.5)")
check(Host.isSkipped(100.5, 200.5), "x.5 boundary is skipped")
check(not Host.isSkipped(104, 200), "a sprite 4px away is NOT skipped")
check(not Host.isSkipped(100, 230), "a sprite on another row is NOT skipped")
Host._skipPoints = {}
Host._skipFeet = { ["100:200"] = true }
check(Host.isSkipped(100, 200), "falls back to the old key")

-- 2. a second install (mod reload) leaves only the newest wrappers live
Host.shouldDrawOverworld = function() return true end
check(Host.install() == true, "first install works")
local tok1 = Ground.__terrariumHostToken
check(tok1 ~= nil, "install tags Gen4Ground")
local Host2 = loadHost()          -- the file runs again: fresh module table
Host2.shouldDrawOverworld = function() return true end
Host2.install()
check(Ground.__terrariumHostToken ~= tok1, "reinstall replaces the token")
local overlayRuns = 0
local function count(h) local o = h.overlay3D; h.overlay3D = function(...) overlayRuns = overlayRuns + 1 end end
count(Host); count(Host2)
Ground:drawFree(256, 192)
check(overlayRuns == 1, "overlay3D runs once per frame after a reinstall (got " .. overlayRuns .. ")")
check(calls.drawFree == 1, "engine drawFree runs once")

-- 3. the stale freeEntity wrapper passes through; skip logic applies once
Host.isSkipped = function() error("stale wrapper must not run skip logic") end
Host2._skipPoints = { { 5, 5 } }
local r = Ground:freeEntity(5, 5, 0, 0, 0, function() end)
check(r == true, "freeEntity returns")
check(calls.freeEntity == 0, "a skipped sprite never reaches the engine draw")
r = Ground:freeEntity(90, 90, 0, 0, 0, function() end)
check(calls.freeEntity == 1, "a non-skipped sprite is drawn exactly once through both wrappers")

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
