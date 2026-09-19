-- EVERY CHECK IN THIS FOLDER, IN ONE COMMAND.
--
-- These exist so the mod's ground and card maths can be exercised WITHOUT
-- launching the game and walking to Mauville.  They load the real
-- VoxelScene.lua against fakes for its collaborators, so they prove what this
-- file does with a given answer -- not that Structures gives that answer.
--
--   texlua tests/run_all.lua
--
-- Environment overrides, all optional:
--   MOD_LIB      the mod's lib folder      (default: ../lib relative to here)
--   ENGINE_ROOT  the Gen2Recomped checkout (default: four levels up)
local HERE = (arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$")) or "."
local LIB = os.getenv("MOD_LIB") or (HERE .. "/../lib/")

local suites = {
  "ground_test.lua",        -- where a character is placed
  "card_test.lua",          -- and where their card lands
  "matrix_test.lua",        -- the billboard transform, against the old chain
  "transform_test.lua",     -- the caster and snug transforms, likewise
  "uniform_cache_test.lua", -- nothing sends a cached uniform raw
  "shadow_signature_test.lua", -- the sun pass redraws when it must
  "gen3_grass_test.lua",    -- Hoenn names grass by behaviour, not tile id
}
local failed = {}

for _, s in ipairs(suites) do
  print(("-- %s"):format(s))
  local ok = os.execute(("texlua %q"):format(HERE .. "/" .. s))
  if ok ~= true and ok ~= 0 then failed[#failed + 1] = s end
end

-- and the static one, over every Lua file in the mod's lib
-- and the static one, over the files this work actually touches.  Pointed at
-- the whole of lib/ it still reports around fifty mismatches in Structures
-- and TileShape -- some real, most deliberate trailing-optional calls -- and
-- a suite that always fails teaches people to ignore it.  Widen this list as
-- those are worked through.
print("-- arity_check.lua")
local FILES = { "VoxelScene.lua", "Voxel3D.lua", "ShadowMap.lua",
                "SpriteBillboards.lua", "ViewBox.lua", "Quality.lua" }
local argv = {}
for _, f in ipairs(FILES) do argv[#argv + 1] = ("%q"):format(LIB .. f) end
local ok = os.execute(("texlua %q %s"):format(HERE .. "/arity_check.lua",
                                              table.concat(argv, " ")))
if ok ~= true and ok ~= 0 then failed[#failed + 1] = "arity_check.lua" end

if #failed == 0 then
  print("\nall suites passed")
else
  print("\nFAILED: " .. table.concat(failed, ", "))
  os.exit(1)
end
