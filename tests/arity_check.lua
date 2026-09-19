-- DO THE CALL SITES MATCH THE PARAMETER LISTS?
--
-- This file has been bitten twice by a slipped argument list, and both times
-- it was invisible: Lua pads a short call with nil and drops a long one's
-- tail, so nothing throws and the only evidence is a wrong picture.  The
-- second one -- drawCast declared with four parameters and called with five,
-- cascading into drawEntity receiving eleven arguments for twelve -- drew the
-- entire cast with `yaw = nil` for as long as it stood.
--
-- A runtime test cannot see it: calling the inner function directly, with a
-- correct list, is exactly what a unit test does.  So read the source.
--
-- Deliberately conservative.  It only looks at `local function NAME(...)`
-- declarations with a fixed parameter list (no varargs, no defaults, since
-- Lua has neither), and it only counts a call's TOP-LEVEL commas -- commas
-- inside nested calls, tables, strings or comments do not count.  A function
-- that is reassigned, shadowed, or called through a table is not checked;
-- this is a lint for the common shape, not a type system.
--
--   texlua arity_check.lua <file.lua> [...]

local function stripped(src)
  -- Blank out comments and strings so their brackets and commas cannot be
  -- miscounted, KEEPING BYTE OFFSETS IDENTICAL -- every reported line number
  -- is derived from this string, and an earlier version collapsed long
  -- comments to a few spaces, which silently shifted every line number after
  -- the first one in the file.
  --
  -- Comments become spaces and strings become a digit run: a blanked string
  -- must still read as an ARGUMENT (`phase('sky: layer')` is one argument,
  -- not none), while a blanked comment must read as nothing at all.
  local n = #src
  local buf, i = {}, 1
  local function put(s2) buf[#buf + 1] = s2 end
  -- NEWLINES SURVIVE BLANKING.  A shader lives in a [[ long string ]] and a
  -- design note lives in a --[[ long comment ]]; flattening either to a run
  -- of one character keeps the byte count but destroys the line breaks
  -- inside it, and every line number after it is then reported short by the
  -- height of that block.  So blank character by character and copy the
  -- newlines through.
  local function blank(from, to, ch)
    local out = {}
    for k = from, to do
      local d = src:sub(k, k)
      out[#out + 1] = (d == "\n") and "\n" or ch
    end
    put(table.concat(out))
  end
  -- the closer for a long bracket opening at `at`, or nil
  local function longEnd(at)
    local eq = src:match("^%[(=*)%[", at)
    if not eq then return nil end
    local close = "]" .. eq .. "]"
    local j = src:find(close, at, true)
    return j and (j + #close - 1) or n
  end
  while i <= n do
    local c = src:sub(i, i)
    if c == "-" and src:sub(i + 1, i + 1) == "-" then
      local j = longEnd(i + 2)                 -- --[[ ... ]]
      if not j then j = (src:find("\n", i) or (n + 1)) - 1 end
      blank(i, j, " "); i = j + 1
    elseif c == '"' or c == "'" then
      local q, j = c, i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == q or d == "\n" then break
        else j = j + 1 end
      end
      blank(i, j, "0"); i = j + 1
    elseif c == "[" then
      local j = longEnd(i)                     -- [[ ... ]]
      if j then blank(i, j, "0"); i = j + 1
      else put(c); i = i + 1 end
    else put(c); i = i + 1 end
  end
  local out = table.concat(buf)
  assert(#out == n, "stripped() changed the source length -- line numbers "
                    .. "reported from it would be wrong")
  local _, a2 = src:gsub("\n", "")
  local _, b2 = out:gsub("\n", "")
  assert(a2 == b2, "stripped() lost line breaks -- every line number after "
                   .. "the first long string or comment would be short")
  return out
end

-- count top-level arguments of a call whose '(' is at `open`
local function argCount(s, open)
  local depth, i, n = 0, open, #s
  local commas, sawContent = 0, false
  while i <= n do
    local c = s:sub(i, i)
    if c == "(" or c == "{" or c == "[" then depth = depth + 1
    elseif c == ")" or c == "}" or c == "]" then
      depth = depth - 1
      if depth == 0 then
        return (sawContent and (commas + 1) or 0), i
      end
    elseif depth == 1 and c == "," then commas = commas + 1
    elseif depth == 1 and not c:match("%s") then sawContent = true end
    i = i + 1
  end
  return nil
end

local bad, checked = 0, 0
for _, path in ipairs(arg) do
  local f = assert(io.open(path, "r"))
  local raw = f:read("*a"); f:close()
  local src = stripped(raw)

  local decl = {}
  for pos, name, params in src:gmatch("()local%s+function%s+([%w_]+)%s*(%b())") do
    local inner = params:sub(2, -2)
    if not inner:find("%.%.%.") then
      local k = 0
      if inner:match("%S") then
        k = 1
        for _ in inner:gmatch(",") do k = k + 1 end
      end
      decl[name] = { n = k, pos = pos, params = inner:gsub("%s+", " ") }
    end
  end

  local function lineOf(pos) local _, nl = src:sub(1, pos):gsub("\n", "") return nl + 1 end

  -- A DELIBERATE SHORT CALL IS ALLOWED TO SAY SO.  Trailing parameters that
  -- the body treats as optional are a real pattern (groundRaw's px/py), and
  -- the checker cannot tell one from a dropped argument -- which is the whole
  -- bug it exists to catch, so it must not guess.  Mark the call line
  -- `-- arity-ok: <why>` and it is skipped; the reason is the point.
  local rawLines = {}
  do
    local i = 1
    for line in (raw .. "\n"):gmatch("(.-)\n") do rawLines[i] = line; i = i + 1 end
  end
  local function excused(ln)
    -- looked for ABOVE the call as well as on it: a reason worth writing is
    -- a comment line, and a comment goes above the code it explains
    for k = math.max(1, ln - 3), math.min(ln + 3, #rawLines) do
      if rawLines[k] and rawLines[k]:find("arity%-ok") then return true end
    end
    return false
  end

  for name, d in pairs(decl) do
    local i = 1
    while true do
      local s1, e1 = src:find("[^%w_%.:]" .. name .. "%s*%(", i)
      if not s1 then break end
      -- e1 IS the '(' -- the pattern ends on it.  Searching forward from s1
      -- for a literal '(' instead finds the one that may PRECEDE the name
      -- (`(leanAngle() - x)`), which counted the enclosing expression's
      -- arguments and reported a mismatch on every correct call.
      local open = e1
      if open > d.pos then                    -- calls only, not the declaration
        local k = argCount(src, open)
        if k then
          checked = checked + 1
          if k ~= d.n and not excused(lineOf(s1 + 1)) then
            bad = bad + 1
            print(("%s:%d: %s takes %d (%s) but is called with %d")
              :format(path, lineOf(s1 + 1), name, d.n, d.params, k))
          end
        end
      end
      i = e1
    end
  end
end
print(("arity: %d call site(s) checked, %d mismatch(es)"):format(checked, bad))
os.exit(bad == 0 and 0 or 1)
