-- THE SUN PASS RUNS WHEN SOMETHING MOVED, AND ONLY THEN.
--
-- The shadow map is reused while nothing it depends on has changed, which in
-- a town is the difference between redrawing a route-sized mesh every frame
-- and redrawing it a few times a minute.  Deciding that used to mean
-- building a comma-joined string of every field -- well over a thousand of
-- them with a town's cast, plus a `tostring` per mesh table -- and comparing
-- it to last frame's.  It is now a reused buffer compared element by
-- element: same answer exactly, no string, and nothing allocated after the
-- first frame.
--
-- TWO RULES MATTER AND BOTH ARE EASY TO GET WRONG:
--
--   the buffer is committed only AFTER the pass has actually drawn -- a
--   frame that bails between the test and finish (no canvas, device not
--   ready) must leave the previous signature standing, or the work is
--   skipped forever on a map that never got drawn; and
--
--   a table goes into the buffer AS ITSELF, because `==` on tables is
--   identity, which is the question the old `tostring(mesh)` was
--   approximating -- and a remesh hands over a new table.
--
-- The first half checks that discipline in the source (the failure is a
-- missing call, which no runtime test can see); the second checks the
-- compare-and-commit logic itself.
--
--   texlua tests/shadow_signature_test.lua
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local LIB = os.getenv("MOD_LIB") or (HERE .. "/../lib/")

local fail, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if not cond then fail = fail + 1; print("FAIL " .. what) end
end

local src
do
  local f = assert(io.open(LIB .. "VoxelScene.lua", "r"))
  src = f:read("*a"); f:close()
end
local code = src:gsub("%-%-[^\n]*", "")

check(code:find("ShadowMap.stale(changed)", 1, true) ~= nil,
      "the staleness test is asked with the compared result, not a string")
check(code:find("table.concat(sigBuf", 1, true) == nil,
      "the signature is no longer concatenated into a string")

-- finish must be immediately followed by the commit, and the commit must
-- appear nowhere else
local body = code:match("ShadowMap%.finish%(%)%s*(.-)\n")
check(body and body:find("shadowSignatureCommit", 1, true) ~= nil,
      "the signature is committed right after the pass finishes")
local commits = 0
-- the declaration reads `local function shadowSignatureCommit()` and matches
-- the same pattern, so only CALLS are counted
for pre in code:gmatch("([%w_ ]*)shadowSignatureCommit%(%)") do
  if not pre:find("function") then commits = commits + 1 end
end
check(commits == 1,
      ("the signature is committed in exactly one place (found %d)"):format(commits))

-- and it must not be committed before the pass can bail
local between = code:match("local changed = shadowSignature(.-)ShadowMap%.begin")
check(between and between:find("shadowSignatureCommit", 1, true) == nil,
      "...and NOT before the frame has had its chance to bail")

-- ---- the compare-and-commit logic --------------------------------------
local buf, prev = {}, {}
local n, prevN = 0, -1
local function build(fields)
  n = 0
  for i = 1, #fields do n = n + 1; buf[n] = fields[i] end
  if n ~= prevN then return true end
  for i = 1, n do if buf[i] ~= prev[i] then return true end end
  return false
end
local function commit() buf, prev = prev, buf; prevN = n end

local meshA, meshB = {}, {}
check(build({ 1, 2, meshA }) == true, "the first frame always has work to do")
commit()
check(build({ 1, 2, meshA }) == false, "nothing moved, so nothing is redrawn")
check(build({ 1, 3, meshA }) == true, "a field that changed is noticed")
commit()
check(build({ 1, 3, meshB }) == true,
      "a REMESHED neighbour is a different table, and that counts as a change")
commit()
check(build({ 1, 3 }) == true, "a shorter signature is a change")
commit()
check(build({ 1, 3 }) == false, "...and then settles")

-- the bail case: build, decide to redraw, DO NOT commit, and the next frame
-- must still know there is work
check(build({ 9, 9 }) == true, "a change is seen")
-- (no commit -- the pass bailed)
check(build({ 9, 9 }) == true,
      "an uncommitted frame still reports work the next time round")
commit()
check(build({ 9, 9 }) == false, "...and settles once the pass has run")

print(("shadow signature: %d/%d checks passed"):format(checks - fail, checks))
os.exit(fail == 0 and 0 or 1)
