-- ds_fp_ceiling settings
--
-- This module consolidates all the ds_fp_ceiling compatibility settings
-- to reduce local variable count in main.lua

local V = ...

local ModSetting = V.require("ModSetting")

local FpCeilingSettings = {}

-- Interior details
FpCeilingSettings.shadows = ModSetting.new("fpshadows", "CONTACT SHADOW",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.rails = ModSetting.new("fprails", "RAIL AND SKIRTING",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.spill = ModSetting.new("fpspill", "DOORWAY LIGHT",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.fittings = ModSetting.new("fpfittings", "CEILING LAMPS",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.backs = ModSetting.new("fpbacks", "BUILDING BACKS",
  { true, false }, { "ON", "OFF" })

-- Cave features
FpCeilingSettings.rock = ModSetting.new("fprock", "CAVE ROCK",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.pools = ModSetting.new("fppools", "CAVE POOLS",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.sconces = ModSetting.new("fpsconces", "CAVE TORCHES",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.bats = ModSetting.new("fpbats", "BATS",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.dark = ModSetting.new("fpdark", "CAVE DARKNESS",
  { true, false }, { "ON", "OFF" })

-- Third person ceiling
FpCeilingSettings.third = ModSetting.new("fpthird", "3RD CEILING",
  { "NONE", "CUTAWAY", "FULL" }, { "NONE", "CUTAWAY", "FULL" })

-- Horizon backdrop
FpCeilingSettings.backdrop = ModSetting.new("fpbackdrop", "HORIZON",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.horizonart = ModSetting.new("fphorizonart", "HORIZON ART",
  { "KANTO", "FUJI", "VALLEY", "CITY" }, { "KANTO", "FUJI", "VALLEY", "CITY" })

-- Sky features
FpCeilingSettings.clouds = ModSetting.new("fpclouds", "CLOUDS",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.stars = ModSetting.new("fpstars", "NIGHT SKY",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.birds = ModSetting.new("fpbirds", "BIRDS",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.aircraft = ModSetting.new("fpaircraft", "AIRCRAFT",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.rainbows = ModSetting.new("fprainbows", "RAINBOWS",
  { true, false }, { "ON", "OFF" })

-- Weather effects
FpCeilingSettings.rain = ModSetting.new("fprain", "RAIN",
  { "OFF", "SOMETIMES", "ALWAYS" }, { "OFF", "SOMETIMES", "ALWAYS" })
FpCeilingSettings.lightning = ModSetting.new("fplightning", "LIGHTNING",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.umbrellas = ModSetting.new("fpumbrellas", "NPC UMBRELLAS",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.puddles = ModSetting.new("fppuddles", "PUDDLES",
  { true, false }, { "ON", "OFF" })

-- Ground detail
FpCeilingSettings.grass = ModSetting.new("fpgrass", "GRASS HEIGHT",
  { "OFF", "SUBTLE", "WILD" }, { "OFF", "SUBTLE", "WILD" })
FpCeilingSettings.wind = ModSetting.new("fpwind", "WIND",
  { "OFF", "BREEZE", "GUSTY" }, { "OFF", "BREEZE", "GUSTY" })
FpCeilingSettings.particles = ModSetting.new("fpparticles", "PARTICLES",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.insects = ModSetting.new("fpinsects", "INSECTS",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.groundflock = ModSetting.new("fpgroundflock", "GROUND FLOCK",
  { true, false }, { "ON", "OFF" })

-- Forest features
FpCeilingSettings.canopy = ModSetting.new("fpcanopy", "FOREST CANOPY",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.vines = ModSetting.new("fpvines", "HANGING VINES",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.shafts = ModSetting.new("fpshafts", "SUN SHAFTS",
  { true, false }, { "ON", "OFF" })

-- Town features
FpCeilingSettings.fog = ModSetting.new("fpfog", "LAVENDER FOG",
  { true, false }, { "ON", "OFF" })
FpCeilingSettings.lights = ModSetting.new("fplights", "LAMPLIGHT",
  { true, false }, { "ON", "OFF" })

-- Movement
FpCeilingSettings.jump = ModSetting.new("fpjump", "JUMP FEEL",
  { "OFF", "SUBTLE", "BIG" }, { "OFF", "SUBTLE", "BIG" })
FpCeilingSettings.doorstep = ModSetting.new("fpdoorstep", "DOORWAY STEP",
  { true, false }, { "ON", "OFF" })

return FpCeilingSettings
