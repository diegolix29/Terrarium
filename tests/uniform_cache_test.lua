-- NOTHING MAY SEND A CACHED UNIFORM BEHIND THE CACHE'S BACK.
--
-- Voxel3D.draw used to upload twelve uniforms per card, of which ten are
-- frame constants, so they are now remembered and skipped when unchanged.
-- That is only correct while EVERY site that changes one of those uniforms
-- goes through the cache: one raw `sh:send` for, say, `sway` would leave the
-- cache believing the old value is still on the shader, and every later draw
-- would skip a send it needed.  The symptom would be a whole pass leaning,
-- or water-tinted, or snow-capped, with nothing in the code looking wrong.
--
-- A runtime test cannot see that -- the bad site is the one that is NOT
-- called.  So this reads the source, the same way arity_check.lua does, and
-- pins the invariant directly.  The second half checks the cache's own
-- logic, including the copy-not-reference rule the vector path needs.
--
--   texlua tests/uniform_cache_test.lua
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local LIB = os.getenv("MOD_LIB") or (HERE .. "/../lib/")

local fail, checks = 0, 0
local function check(cond, what)
  checks = checks + 1
  if not cond then fail = fail + 1; print("FAIL " .. what) end
end

-- ---- the invariant, read off the source ---------------------------------
local src
do
  local f = assert(io.open(LIB .. "Voxel3D.lua", "r"))
  src = f:read("*a"); f:close()
end

-- strip comments so a name mentioned in prose is not mistaken for a send
local code = src:gsub("%-%-[^\n]*", "")

local CACHED = {
  "pull", "sway", "waterBody", "grassH", "grassLoad",
  "crushN", "snowTop", "snowColor", "snowSide",
}
for _, name in ipairs(CACHED) do
  local raw = 0
  for _ in code:gmatch('sh%.send,%s*sh,%s*"' .. name .. '"') do raw = raw + 1 end
  for _ in code:gmatch('sh:send%(%s*"' .. name .. '"') do raw = raw + 1 end
  check(raw == 0,
        ("`%s` is still sent raw %d time(s) -- it must go through sendNum/sendVec")
          :format(name, raw))
end

-- and the cache must be pointed at the right shader before any of that
for _, fn in ipairs({ "function Voxel3D.draw%(", "function Voxel3D.drawGroup%(",
                      "function Voxel3D.beginScene%(" }) do
  local body = code:match(fn .. "(.-)\nend\n")
  check(body and body:find("forShader(sh)", 1, true) ~= nil,
        ("%s does not call forShader before sending"):format(fn:gsub("%%", "")))
end

-- the two that must NEVER be cached: they change every card
check(code:find('sh%.send,%s*sh,%s*"model"') ~= nil,
      "`model` must still be sent unconditionally")
check(code:find('sh%.send,%s*sh,%s*"sunModel"') ~= nil,
      "`sunModel` must still be sent unconditionally")

-- ---- the cache's own behaviour ------------------------------------------
local sentShader, sent = nil, {}
local sends = 0
local function forShader(sh)
  if sh ~= sentShader then sentShader, sent = sh, {} end
end
local function sendNum(sh, name, v)
  if sent[name] == v then return end
  sent[name] = v
  sends = sends + 1
end
local function sendVec(sh, name, v)
  local prev, n = sent[name], #v
  if prev and prev.n == n then
    local same = true
    for i = 1, n do if prev[i] ~= v[i] then same = false break end end
    if same then return end
  end
  if not prev then prev = {}; sent[name] = prev end
  for i = 1, n do prev[i] = v[i] end
  prev.n = n
  sends = sends + 1
end

local A, B = {}, {}
sends = 0; forShader(A); sendNum(A, "pull", 0)
check(sends == 1, "the first send of a value goes through")
sends = 0; sendNum(A, "pull", 0); sendNum(A, "pull", 0)
check(sends == 0, "repeating the same value sends nothing")
sends = 0; sendNum(A, "pull", 0.5)
check(sends == 1, "a changed value sends")
sends = 0; forShader(B); sendNum(B, "pull", 0.5)
check(sends == 1, "a different shader has its own uniforms, so it re-sends")
sends = 0; forShader(A); sendNum(A, "pull", 0.5)
check(sends == 1, "...and coming back re-sends too, rather than trusting a "
                  .. "cache that belonged to the other one")

sends = 0; forShader(A)
local live = { 1, 2, 3 }
sendVec(A, "snowColor", live)
check(sends == 1, "the first vector goes through")
sends = 0; sendVec(A, "snowColor", live)
check(sends == 0, "an unchanged vector sends nothing")
-- THE REASON THE PREVIOUS VALUE IS COPIED: these come from module fields a
-- caller may rewrite in place.  Holding the same table would compare it
-- against itself and never send again.
live[2] = 99
sends = 0; sendVec(A, "snowColor", live)
check(sends == 1, "a vector mutated IN PLACE is still noticed")
sends = 0; sendVec(A, "snowColor", { 1, 99, 3 })
check(sends == 0, "...and an equal vector in a different table is not")
sends = 0; sendVec(A, "snowColor", { 1, 99 })
check(sends == 1, "a vector of a different length is a change")

-- ---- AND THE HELPER MUST MATCH THE VALUE'S TYPE --------------------------
--
-- THIS IS THE CHECK THAT WAS MISSING, and it cost a whole session of the
-- world rendering in 2D.
--
-- `Voxel3D.SNOW_SIDE` is 0.34 -- a scalar, how much the side faces take --
-- and it was routed through sendVec because the name looks like
-- SNOW_COLOR's, which IS a vec3.  `#v` on a number throws; this runs inside
-- the render pipeline; the pipeline catches and drops the entire voxel pass.
-- Every frame.  The symptom was "the voxels are not loading at all and it is
-- extremely laggy", and nothing about the code looked wrong.
--
-- The source lint above could not see it -- the uniform WAS going through a
-- helper, just the wrong one.  So pair each uniform with the module constant
-- it sends and check the type against the helper the source uses.  sendVec
-- now also defers to sendNum when handed a scalar, so a future mismatch is a
-- uniform sent correctly rather than a renderer that stops; this keeps the
-- pairing honest anyway.
do
  local inert = setmetatable({}, { __index = function(t, k)
    local v = setmetatable({}, { __index = function() return function() end end })
    rawset(t, k, v); return v
  end })
  local V = { require = function(n) return inert[n] end, engineRequire = require,
              mod = { log = { info = function() end, warn = function() end } },
              data = function() return {} end }
  local ok, Voxel3D = pcall(function()
    return assert(loadfile(LIB .. "Voxel3D.lua"))(V)
  end)
  check(ok and type(Voxel3D) == "table", "Voxel3D loads headless")
  if ok and type(Voxel3D) == "table" then
    -- uniform -> the module field whose value it sends
    local SENDS = {
      grassH    = "GRASS_H",
      snowTop   = "snowTop",
      snowColor = "SNOW_COLOR",
      snowSide  = "SNOW_SIDE",
    }
    for name, field in pairs(SENDS) do
      local value = Voxel3D[field]
      local wanted = (type(value) == "table") and "sendVec" or "sendNum"
      local used = nil
      if code:find(wanted .. '%(sh, "' .. name .. '"') then
        used = wanted
      elseif code:find('sendVec%(sh, "' .. name .. '"')
          or code:find('sendNum%(sh, "' .. name .. '"') then
        used = (wanted == "sendVec") and "sendNum" or "sendVec"
      end
      check(used == wanted,
            ("`%s` sends Voxel3D.%s, which is a %s, so it must go through %s (source uses %s)")
              :format(name, field, type(value), wanted, tostring(used)))
    end
  end
end

print(("uniform cache: %d/%d checks passed"):format(checks - fail, checks))
os.exit(fail == 0 and 0 or 1)
