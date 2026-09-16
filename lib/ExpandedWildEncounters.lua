-- Logical National-Dex wild encounter overlay for Gen1/Gen2 hosts.
--
-- The native game ALWAYS owns encounter chance and level. This module runs
-- only after a successful native encounter and adds later-generation species
-- as extra route/method outcomes. It does NOT require or consume a particular
-- native species slot: every native species remains a valid baseline outcome.
-- The route plan still records ecological affinity as design provenance, but
-- affinity is never used as a replacement gate. The overlay never manufactures
-- an encounter, never changes the rolled level, and fails closed when the
-- target species is not registered/persistable.
local E={version=3}

local function set(list)
  local out={}
  for _,v in ipairs(list or {}) do out[tostring(v):upper()]=true end
  return out
end
local function C(species,dex,weight,affinity,lo,hi,times,note)
  return {species=species,dex=dex,weight=weight or 1,ecology=set(affinity),minLevel=lo,maxLevel=hi,times=times and set(times) or nil,note=note}
end
local ADDITIVE_SHARE=50
-- Every planned route/method uses one simple top-level split after a native
-- encounter succeeds: 50% keep the native result, 50% draw from the added
-- ColosseumDex pool. Historical per-area share arguments are intentionally
-- ignored so route difficulty does not quietly change this contract.
local function A(_share,rows) return {share=ADDITIVE_SHARE,rows=rows} end
local function maps(names,area,out)
  for _,name in ipairs(names) do out[name]=area end
end

-- Gen1: Johto + Hoenn are interleaved with Kanto's existing ecology. The
-- affinity tags document why a species belongs in a route pool (birds with
-- birds, burrowers in caves/ground, ghosts in ghost areas, aquatic species in
-- water/fishing, etc.). They are descriptive only: no native spawn is removed
-- or required for an added species to become eligible.
local G1={land={},surf={},fishing={}}
local function g1(names,share,rows,kind)
  maps(names,A(share,rows),G1[kind or "land"])
end

g1({"ROUTE_1"},30,{
  C("SENTRET",161,30,{"RATTATA"},2,5),C("ZIGZAGOON",263,28,{"RATTATA"},2,5),C("POOCHYENA",261,18,{"RATTATA"},2,5),
  C("HOOTHOOT",163,12,{"PIDGEY"},2,5),C("TAILLOW",276,12,{"PIDGEY"},2,5),
})
g1({"ROUTE_2"},32,{
  C("LEDYBA",165,15,{"CATERPIE","WEEDLE"},3,7),C("SPINARAK",167,15,{"CATERPIE","WEEDLE"},3,7),C("WURMPLE",265,28,{"CATERPIE","WEEDLE"},3,7),
  C("LOTAD",270,12,{"ODDISH"},3,7),C("SEEDOT",273,12,{"ODDISH"},3,7),C("TAILLOW",276,18,{"PIDGEY"},3,7),
})
g1({"VIRIDIAN_FOREST"},36,{
  C("WURMPLE",265,28,{"CATERPIE","WEEDLE"},3,9),C("SILCOON",266,7,{"METAPOD","KAKUNA"},5,9),C("CASCOON",268,7,{"METAPOD","KAKUNA"},5,9),
  C("PINECO",204,10,{"METAPOD","KAKUNA"},5,9),C("SHROOMISH",285,14,{"PARAS"},4,9),C("NINCADA",290,10,{"CATERPIE","WEEDLE","PARAS"},5,9),C("SLAKOTH",287,5,{"PIKACHU"},5,9),
})
g1({"ROUTE_3"},32,{
  C("MAREEP",179,22,{"RATTATA"},6,11),C("HOPPIP",187,18,{"SPEAROW"},6,11),C("SKITTY",300,16,{"JIGGLYPUFF"},6,11),C("TAILLOW",276,18,{"SPEAROW"},6,11),
  C("SNUBBULL",209,10,{"JIGGLYPUFF"},7,11),C("RALTS",280,7,{"JIGGLYPUFF"},7,11),C("SWABLU",333,9,{"SPEAROW"},7,11),
})
g1({"MT_MOON_1F","MT_MOON_B1F","MT_MOON_B2F"},35,{
  C("WHISMUR",293,18,{"ZUBAT"},7,14),C("MAKUHITA",296,14,{"GEODUDE"},8,14),C("ARON",304,20,{"GEODUDE","ONIX"},8,14),C("NOSEPASS",299,12,{"GEODUDE","ONIX"},9,14),
  C("DUNSPARCE",206,8,{"PARAS"},8,14),C("MEDITITE",307,8,{"GEODUDE"},9,14),C("SABLEYE",302,5,{"ZUBAT"},10,14),C("MAWILE",303,5,{"ONIX"},10,14),
  C("LUNATONE",337,5,{"CLEFAIRY"},10,14),C("SOLROCK",338,5,{"CLEFAIRY"},10,14),
})
g1({"ROUTE_4","ROUTE_24","ROUTE_25"},32,{
  C("MARILL",183,18,{"RATTATA","ODDISH"},8,16),C("HOPPIP",187,16,{"PIDGEY","ODDISH"},8,16),C("YANMA",193,12,{"PIDGEY","VENONAT"},9,16),C("SURSKIT",283,12,{"ODDISH","VENONAT"},8,16),
  C("NATU",177,10,{"PIDGEY","SPEAROW"},9,16),C("RALTS",280,8,{"ABRA"},9,16),C("ROSELIA",315,12,{"ODDISH","BELLSPROUT"},9,16),C("KECLEON",352,4,{"ABRA"},12,16),C("SMEARGLE",235,8,{"ABRA"},12,16),
})
g1({"ROUTE_5","ROUTE_6","ROUTE_11"},34,{
  C("SNUBBULL",209,14,{"MEOWTH","JIGGLYPUFF"},12,20),C("SKITTY",300,14,{"MEOWTH"},12,20),C("MAREEP",179,14,{"ODDISH","BELLSPROUT"},12,20),C("FLAAFFY",180,5,{"ODDISH","BELLSPROUT"},15,20),
  C("ELECTRIKE",309,16,{"MAGNEMITE","PIKACHU"},13,20),C("PLUSLE",311,7,{"PIKACHU"},13,20),C("MINUN",312,7,{"PIKACHU"},13,20),C("GULPIN",316,12,{"ODDISH","BELLSPROUT"},13,20),
  C("SPOINK",325,6,{"DROWZEE"},14,20),C("GIRAFARIG",203,5,{"DROWZEE"},15,20),
})
g1({"DIGLETTS_CAVE"},34,{
  C("NINCADA",290,24,{"DIGLETT"},15,24),C("PHANPY",231,18,{"DIGLETT"},16,24),C("TRAPINCH",328,18,{"DIGLETT"},17,24),C("DUNSPARCE",206,14,{"DIGLETT"},15,24),
  C("GLIGAR",207,10,{"DUGTRIO"},18,24),C("NOSEPASS",299,8,{"DUGTRIO"},18,24),C("ARON",304,8,{"DUGTRIO"},18,24),
})
g1({"ROUTE_9","ROUTE_10"},36,{
  C("PHANPY",231,14,{"RATTATA"},16,24),C("MAKUHITA",296,12,{"MANKEY"},16,24),C("SWABLU",333,14,{"SPEAROW"},16,24),C("SPOINK",325,12,{"DROWZEE"},17,24),
  C("MEDITITE",307,12,{"MANKEY"},17,24),C("ELECTRIKE",309,14,{"PIKACHU","MAGNEMITE"},16,24),C("ABSOL",359,4,{"RATICATE"},20,24),C("GIRAFARIG",203,6,{"DROWZEE"},18,24),
})
g1({"ROCK_TUNNEL_1F","ROCK_TUNNEL_B1F"},38,{
  C("ARON",304,20,{"GEODUDE","ONIX"},18,27),C("LAIRON",305,5,{"GRAVELER"},22,27),C("NOSEPASS",299,14,{"GEODUDE","ONIX"},18,27),C("MEDITITE",307,10,{"MACHOP"},18,27),C("BALTOY",343,10,{"GEODUDE"},19,27),
  C("SHUCKLE",213,7,{"ONIX"},20,27),C("GLIGAR",207,8,{"ZUBAT","ONIX"},20,27),C("SABLEYE",302,6,{"ZUBAT"},21,27),C("MAWILE",303,6,{"ONIX"},21,27),C("LUNATONE",337,4,{"GEODUDE"},22,27),C("SOLROCK",338,4,{"GEODUDE"},22,27),
})
g1({"ROUTE_7","ROUTE_8"},37,{
  C("HOUNDOUR",228,14,{"GROWLITHE","VULPIX"},18,27),C("MURKROW",198,12,{"PIDGEY"},18,27),C("SHUPPET",353,12,{"MEOWTH"},19,27),C("DUSKULL",355,12,{"MEOWTH"},19,27),
  C("SUNKERN",191,10,{"ODDISH","BELLSPROUT"},18,27),C("ROSELIA",315,12,{"ODDISH","BELLSPROUT"},18,27),C("AIPOM",190,10,{"MEOWTH"},18,27),C("KECLEON",352,5,{"MEOWTH"},20,27),C("SMEARGLE",235,5,{"MEOWTH"},20,27),
})
g1({"POKEMON_TOWER_3F","POKEMON_TOWER_4F","POKEMON_TOWER_5F","POKEMON_TOWER_6F","POKEMON_TOWER_7F"},40,{
  C("MISDREAVUS",200,22,{"GASTLY"},20,30),C("SHUPPET",353,22,{"GASTLY"},20,30),C("DUSKULL",355,22,{"GASTLY"},20,30),C("MURKROW",198,10,{"GASTLY"},21,30),
  C("SABLEYE",302,8,{"HAUNTER"},22,30),C("CHIMECHO",358,7,{"HAUNTER"},23,30),C("BANETTE",354,4,{"HAUNTER"},26,30),C("DUSCLOPS",356,5,{"HAUNTER"},26,30),
})
g1({"ROUTE_12","ROUTE_13","ROUTE_14","ROUTE_15"},40,{
  C("MARILL",183,12,{"ODDISH","BELLSPROUT"},20,32),C("WOOPER",194,12,{"ODDISH","BELLSPROUT"},20,32),C("YANMA",193,12,{"VENONAT","PIDGEY"},21,32),C("ROSELIA",315,12,{"ODDISH","BELLSPROUT"},21,32),
  C("STANTLER",234,10,{"DODUO","RATICATE"},23,32),C("GIRAFARIG",203,9,{"DODUO","DROWZEE"},23,32),C("ZANGOOSE",335,8,{"RATICATE"},24,32),C("SEVIPER",336,8,{"EKANS","ARBOK"},24,32),
  C("SWABLU",333,9,{"PIDGEY","DODUO"},23,32),C("TROPIUS",357,4,{"DODUO"},27,32),C("ABSOL",359,3,{"RATICATE"},28,32),
})
g1({"ROUTE_16","ROUTE_17","ROUTE_18"},40,{
  C("PHANPY",231,16,{"RATTATA","RATICATE"},23,34),C("GLIGAR",207,13,{"SPEAROW","DODUO"},24,34),C("SLUGMA",218,13,{"PONYTA"},23,34),C("NUMEL",322,13,{"PONYTA"},23,34),
  C("SPINDA",327,10,{"RATTATA","RATICATE"},23,34),C("CACNEA",331,10,{"DODUO"},24,34),C("TRAPINCH",328,10,{"RATTATA"},24,34),C("VIBRAVA",329,5,{"RATICATE"},29,34),C("SKARMORY",227,5,{"SPEAROW","DODUO"},28,34),
})
g1({"SAFARI_ZONE_CENTER","SAFARI_ZONE_EAST","SAFARI_ZONE_NORTH","SAFARI_ZONE_WEST"},45,{
  C("HERACROSS",214,12,{"PINSIR","SCYTHER"},24,35),C("TEDDIURSA",216,10,{"NIDORAN_M","NIDORAN_F"},24,35),C("MILTANK",241,9,{"TAUROS"},25,35),C("STANTLER",234,9,{"TAUROS"},25,35),C("GIRAFARIG",203,9,{"EXEGGCUTE"},25,35),
  C("TROPIUS",357,8,{"EXEGGCUTE","DODUO"},26,35),C("KECLEON",352,9,{"PARAS"},25,35),C("SHROOMISH",285,8,{"PARAS"},24,35),C("SLAKOTH",287,6,{"PARAS"},24,35),C("PINECO",204,7,{"PARAS"},24,35),C("WOBBUFFET",202,5,{"EXEGGCUTE"},26,35),
})
g1({"POWER_PLANT"},43,{
  C("ELECTRIKE",309,22,{"MAGNEMITE","VOLTORB"},25,36),C("MANECTRIC",310,5,{"MAGNETON","ELECTRODE"},31,36),C("PLUSLE",311,11,{"PIKACHU","VOLTORB"},26,36),C("MINUN",312,11,{"PIKACHU","VOLTORB"},26,36),
  C("BALTOY",343,11,{"MAGNEMITE"},27,36),C("NOSEPASS",299,10,{"MAGNEMITE"},27,36),C("LUNATONE",337,5,{"MAGNETON"},30,36),C("SOLROCK",338,5,{"MAGNETON"},30,36),
})
g1({"ROUTE_19","ROUTE_20"},42,{
  C("WINGULL",278,18,{"TENTACOOL"},25,40),C("MANTINE",226,12,{"TENTACOOL","TENTACRUEL"},27,40),C("CHINCHOU",170,14,{"TENTACOOL"},25,40),C("QWILFISH",211,10,{"TENTACOOL"},26,40),C("CORSOLA",222,10,{"TENTACOOL"},26,40),
  C("WAILMER",320,12,{"TENTACRUEL"},27,40),C("CARVANHA",318,10,{"TENTACOOL"},27,40),C("SPHEAL",363,6,{"TENTACRUEL"},28,40),C("CLAMPERL",366,5,{"TENTACOOL"},29,40),
},"surf")
g1({"SEAFOAM_ISLANDS_1F","SEAFOAM_ISLANDS_B1F","SEAFOAM_ISLANDS_B2F","SEAFOAM_ISLANDS_B3F","SEAFOAM_ISLANDS_B4F"},44,{
  C("SWINUB",220,18,{"ZUBAT","GOLBAT"},28,42),C("SNEASEL",215,14,{"ZUBAT","GOLBAT"},29,42),C("DELIBIRD",225,10,{"ZUBAT"},29,42),C("SNORUNT",361,18,{"ZUBAT","GOLBAT"},28,42),C("SPHEAL",363,18,{"SLOWPOKE","SEEL"},28,42),C("ABSOL",359,5,{"GOLBAT"},33,42),C("SKARMORY",227,5,{"GOLBAT"},33,42),
})
g1({"SEAFOAM_ISLANDS_1F","SEAFOAM_ISLANDS_B1F","SEAFOAM_ISLANDS_B2F","SEAFOAM_ISLANDS_B3F","SEAFOAM_ISLANDS_B4F"},44,{
  C("CHINCHOU",170,18,{"TENTACOOL","SLOWPOKE"},29,42),C("MANTINE",226,13,{"TENTACOOL"},30,42),C("SPHEAL",363,18,{"SEEL","DEWGONG"},29,42),C("CLAMPERL",366,15,{"SLOWPOKE"},30,42),C("RELICANTH",369,4,{"DEWGONG"},35,42),C("REMORAID",223,15,{"TENTACOOL"},30,42),C("LUVDISC",370,12,{"TENTACOOL"},30,42),
},"surf")
g1({"ROUTE_21"},43,{
  C("SLUGMA",218,16,{"RATTATA","RATICATE"},29,42),C("NUMEL",322,16,{"RATTATA","RATICATE"},29,42),C("TORKOAL",324,13,{"RATICATE"},31,42),C("HOUNDOUR",228,12,{"RATTATA"},29,42),C("SWABLU",333,12,{"PIDGEY"},29,42),C("CACNEA",331,10,{"TANGELA"},30,42),C("ABSOL",359,6,{"RATICATE"},33,42),C("NOSEPASS",299,8,{"RATICATE"},31,42),
})
g1({"POKEMON_MANSION_1F","POKEMON_MANSION_2F","POKEMON_MANSION_3F","POKEMON_MANSION_B1F"},45,{
  C("SLUGMA",218,18,{"KOFFING","GRIMER"},30,42),C("NUMEL",322,18,{"KOFFING","GRIMER"},30,42),C("TORKOAL",324,14,{"WEEZING","MUK"},32,42),C("HOUNDOUR",228,13,{"RATTATA","RATICATE"},30,42),
  C("SHUPPET",353,12,{"KOFFING","GRIMER"},31,42),C("DUSKULL",355,10,{"KOFFING","GRIMER"},31,42),C("NOSEPASS",299,7,{"WEEZING","MUK"},32,42),C("ARON",304,8,{"RATICATE"},31,42),
})
g1({"ROUTE_22","ROUTE_23"},42,{
  C("TEDDIURSA",216,10,{"RATTATA","RATICATE"},30,44),C("PHANPY",231,11,{"RATTATA","RATICATE"},30,44),C("GLIGAR",207,11,{"SPEAROW","FEAROW"},31,44),C("SKARMORY",227,8,{"SPEAROW","FEAROW"},34,44),
  C("SNEASEL",215,10,{"RATTATA","RATICATE"},32,44),C("ABSOL",359,7,{"RATICATE"},34,44),C("LARVITAR",246,5,{"RATICATE"},35,44),C("BAGON",371,5,{"RATICATE"},35,44),C("LAIRON",305,5,{"RHYHORN"},34,44),
})
g1({"VICTORY_ROAD_1F","VICTORY_ROAD_2F","VICTORY_ROAD_3F"},45,{
  C("LARVITAR",246,14,{"RHYHORN","MACHOP"},38,48),C("PUPITAR",247,5,{"RHYDON","MACHOKE"},42,48),C("BAGON",371,13,{"RHYHORN","MACHOP"},38,48),C("SHELGON",372,5,{"RHYDON","MACHOKE"},42,48),
  C("LAIRON",305,12,{"RHYHORN","ONIX"},38,48),C("VIBRAVA",329,10,{"ONIX"},39,48),C("MEDITITE",307,8,{"MACHOP"},38,48),C("BALTOY",343,8,{"GEODUDE"},39,48),C("SKARMORY",227,8,{"ZUBAT","GOLBAT"},39,48),C("SNEASEL",215,7,{"GOLBAT"},39,48),C("ABSOL",359,5,{"RHYDON"},40,48),
})
g1({"CERULEAN_CAVE_1F","CERULEAN_CAVE_2F","CERULEAN_CAVE_B1F"},50,{
  C("TYRANITAR",248,6,{"RHYDON"},50,70),C("SALAMENCE",373,6,{"RHYDON"},50,70),C("METANG",375,8,{"MAGNETON"},50,70),C("AGGRON",306,9,{"RHYDON"},50,70),C("FLYGON",330,9,{"RHYDON"},50,70),
  C("DUSCLOPS",356,9,{"HAUNTER"},50,70),C("HOUNDOOM",229,8,{"ARBOK"},50,70),C("CROBAT",169,9,{"GOLBAT"},50,70),C("GLALIE",362,8,{"GOLBAT"},50,70),C("WALREIN",365,7,{"RHYDON"},50,70),C("MEDICHAM",308,7,{"MACHOKE"},50,70),C("CLAYDOL",344,7,{"RHYDON"},50,70),C("ABSOL",359,5,{"RHYDON"},50,70),
})

-- Rod overlays keep OLD_ROD untouched. Added species are extra outcomes after
-- a successful native bite; failed bites stay failed and bite chance is not
-- changed.
local fishCoast=A(38,{
  C("REMORAID",223,20,{"GOLDEEN","POLIWAG"},10,40),C("CHINCHOU",170,18,{"GOLDEEN","POLIWAG"},15,40),C("QWILFISH",211,14,{"GOLDEEN","HORSEA"},15,40),
  C("BARBOACH",339,16,{"POLIWAG","GOLDEEN"},15,40),C("CORPHISH",341,16,{"KRABBY","GOLDEEN"},15,40),C("CARVANHA",318,12,{"KRABBY","HORSEA"},20,40),C("FEEBAS",349,2,{"MAGIKARP"},15,40),
})
for _,m in ipairs({"ROUTE_12","ROUTE_13","ROUTE_19","ROUTE_20","ROUTE_21","SAFARI_ZONE_CENTER","SAFARI_ZONE_WEST"}) do G1.fishing[m]=fishCoast end

-- Gen2: Hoenn species are added alongside Johto/Kanto's existing native pools.
-- Time-of-day is used where Gold exposes it; rows without `times` are neutral.
local G2={land={},surf={},fishing={}}
local function g2(names,share,rows,kind) maps(names,A(share,rows),G2[kind or "land"]) end

g2({"ROUTE_29","ROUTE_30","ROUTE_31"},28,{
  C("ZIGZAGOON",263,28,{"SENTRET","RATTATA"},2,6,{"MORN","DAY"}),C("POOCHYENA",261,24,{"RATTATA"},2,6,{"NITE"}),C("TAILLOW",276,20,{"PIDGEY"},2,6,{"MORN","DAY"}),
  C("WURMPLE",265,18,{"CATERPIE","WEEDLE","LEDYBA","SPINARAK"},3,7),C("LOTAD",270,10,{"HOPPIP","BELLSPROUT"},3,7,{"MORN","NITE"}),
})
g2({"DARK_CAVE_VIOLET_ENTRANCE","DARK_CAVE_BLACKTHORN_ENTRANCE"},34,{
  C("WHISMUR",293,20,{"ZUBAT"},2,25),C("ARON",304,20,{"GEODUDE","ONIX"},4,28),C("NOSEPASS",299,14,{"GEODUDE","ONIX"},6,28),C("SABLEYE",302,7,{"ZUBAT"},8,28,{"NITE"}),C("MAWILE",303,7,{"ONIX"},8,28),C("MAKUHITA",296,12,{"GEODUDE"},6,28),
})
g2({"ROUTE_32","ROUTE_33"},32,{
  C("ELECTRIKE",309,18,{"MAREEP"},6,14),C("WINGULL",278,16,{"SPEAROW","PIDGEY"},6,14),C("MAKUHITA",296,12,{"RATTATA"},7,14),C("ROSELIA",315,14,{"BELLSPROUT","HOPPIP"},7,14),C("SURSKIT",283,12,{"HOPPIP"},6,14),C("SWABLU",333,10,{"SPEAROW"},7,14),
})
g2({"UNION_CAVE_1F","UNION_CAVE_B1F","UNION_CAVE_B2F"},36,{
  C("ARON",304,22,{"GEODUDE","ONIX"},6,24),C("NOSEPASS",299,14,{"GEODUDE","ONIX"},8,24),C("MAKUHITA",296,14,{"GEODUDE"},7,24),C("WHISMUR",293,16,{"ZUBAT"},6,24),C("SABLEYE",302,6,{"ZUBAT"},10,24,{"NITE"}),C("MAWILE",303,6,{"ONIX"},10,24),C("BALTOY",343,8,{"GEODUDE"},12,24),
})
g2({"ILEX_FOREST"},36,{
  C("WURMPLE",265,24,{"CATERPIE","WEEDLE","PARAS"},5,15),C("SILCOON",266,6,{"METAPOD","KAKUNA"},7,15,{"MORN","DAY"}),C("CASCOON",268,6,{"METAPOD","KAKUNA"},7,15,{"NITE"}),
  C("SHROOMISH",285,18,{"PARAS","ODDISH"},5,15),C("SLAKOTH",287,8,{"PARAS"},7,15),C("NINCADA",290,12,{"PARAS","CATERPIE","WEEDLE"},7,15),C("SEEDOT",273,12,{"ODDISH"},6,15),
})
g2({"ROUTE_34","ROUTE_35","NATIONAL_PARK"},34,{
  C("SKITTY",300,18,{"DITTO","DROWZEE"},10,20),C("ELECTRIKE",309,16,{"DROWZEE","NIDORAN_M","NIDORAN_F"},10,20),C("PLUSLE",311,8,{"PIKACHU"},10,20,{"MORN","DAY"}),C("MINUN",312,8,{"PIKACHU"},10,20,{"NITE"}),
  C("ROSELIA",315,16,{"HOPPIP","ODDISH","BELLSPROUT"},10,20),C("RALTS",280,8,{"DROWZEE","ABRA"},10,20),C("VOLBEAT",313,8,{"LEDYBA"},10,20,{"NITE"}),C("ILLUMISE",314,8,{"SPINARAK"},10,20,{"NITE"}),C("SWABLU",333,10,{"PIDGEY"},10,20),
})
g2({"ROUTE_36","ROUTE_37"},35,{
  C("ROSELIA",315,16,{"HOPPIP","BELLSPROUT"},12,22),C("KECLEON",352,10,{"STANTLER"},14,22),C("SPINDA",327,12,{"RATTATA"},12,22),C("SWABLU",333,14,{"PIDGEY"},12,22),C("SHROOMISH",285,14,{"ODDISH"},12,22),C("NINCADA",290,10,{"VENONAT"},12,22),
})
g2({"BURNED_TOWER_1F","BURNED_TOWER_B1F"},40,{
  C("SHUPPET",353,30,{"GASTLY","KOFFING"},14,28,{"NITE"}),C("DUSKULL",355,30,{"GASTLY","RATTATA"},14,28,{"NITE"}),C("SABLEYE",302,10,{"GASTLY"},18,28,{"NITE"}),C("BALTOY",343,10,{"KOFFING"},18,28),C("NUMEL",322,10,{"KOFFING"},18,28),C("SPOINK",325,10,{"RATTATA"},18,28),
})
g2({"ROUTE_38","ROUTE_39"},36,{
  C("ELECTRIKE",309,18,{"MAGNEMITE"},15,24),C("SPOINK",325,14,{"RATICATE"},15,24),C("ZANGOOSE",335,12,{"RATICATE","TAUROS"},17,24,{"MORN","DAY"}),C("SEVIPER",336,12,{"RATICATE"},17,24,{"NITE"}),
  C("SWABLU",333,16,{"PIDGEY","FARFETCHD"},15,24),C("ROSELIA",315,14,{"TAUROS","MILTANK"},15,24),C("ABSOL",359,4,{"RATICATE"},20,24,{"NITE"}),C("KECLEON",352,10,{"TAUROS"},17,24),
})
g2({"ROUTE_40","ROUTE_41","OLIVINE_CITY","CIANWOOD_CITY"},38,{
  C("WINGULL",278,22,{"TENTACOOL"},15,30),C("WAILMER",320,16,{"TENTACRUEL"},18,32),C("CARVANHA",318,14,{"TENTACOOL"},18,32),C("CLAMPERL",366,12,{"TENTACOOL"},20,32),C("LUVDISC",370,12,{"TENTACOOL"},20,32),C("RELICANTH",369,4,{"TENTACRUEL"},26,34),C("CORPHISH",341,10,{"KRABBY"},18,32),C("BARBOACH",339,10,{"MAGIKARP"},18,32),
},"surf")
g2({"WHIRL_ISLAND_NW","WHIRL_ISLAND_NE","WHIRL_ISLAND_SW","WHIRL_ISLAND_CAVE","WHIRL_ISLAND_B1F","WHIRL_ISLAND_B2F","WHIRL_ISLAND_LUGIA_CHAMBER"},42,{
  C("CLAMPERL",366,22,{"TENTACOOL","SEEL"},20,38),C("RELICANTH",369,7,{"SEEL","DEWGONG"},28,40),C("WAILMER",320,18,{"TENTACOOL"},20,38),C("CARVANHA",318,14,{"TENTACOOL"},20,38),C("LUVDISC",370,12,{"TENTACOOL"},20,38),C("SPHEAL",363,16,{"SEEL","DEWGONG"},22,38),C("BARBOACH",339,11,{"MAGIKARP"},20,38),
},"surf")
g2({"MT_MORTAR_1F_OUTSIDE","MT_MORTAR_1F_INSIDE","MT_MORTAR_2F_INSIDE","MT_MORTAR_B1F"},40,{
  C("ARON",304,20,{"GEODUDE","GRAVELER","ONIX"},18,35),C("LAIRON",305,6,{"GRAVELER"},28,35),C("MEDITITE",307,16,{"MACHOP","MACHOKE"},18,35),C("BALTOY",343,14,{"GEODUDE"},20,35),
  C("MAKUHITA",296,14,{"MACHOP"},18,35),C("NOSEPASS",299,12,{"ONIX","GRAVELER"},20,35),C("SABLEYE",302,6,{"ZUBAT","GOLBAT"},22,35,{"NITE"}),C("MAWILE",303,6,{"ONIX"},22,35),C("ABSOL",359,4,{"GOLBAT"},28,35),
})
g2({"ROUTE_42","ROUTE_43","LAKE_OF_RAGE"},38,{
  C("SHROOMISH",285,16,{"ODDISH","BELLSPROUT"},15,28),C("ROSELIA",315,16,{"ODDISH","BELLSPROUT"},15,28),C("SWABLU",333,14,{"PIDGEY","FARFETCHD"},15,28),C("KECLEON",352,10,{"GIRAFARIG"},18,28),
  C("ZANGOOSE",335,10,{"GIRAFARIG","TAUROS"},18,28,{"MORN","DAY"}),C("SEVIPER",336,10,{"EKANS","ARBOK"},18,28,{"NITE"}),C("ABSOL",359,5,{"GIRAFARIG"},22,28,{"NITE"}),C("SPINDA",327,13,{"RATICATE"},16,28),
})
g2({"LAKE_OF_RAGE"},40,{
  C("BARBOACH",339,24,{"MAGIKARP"},15,32),C("WHISCASH",340,8,{"GYARADOS"},25,32),C("CORPHISH",341,22,{"MAGIKARP"},15,32),C("CRAWDAUNT",342,6,{"GYARADOS"},25,32),C("SURSKIT",283,16,{"MAGIKARP"},15,32),C("WAILMER",320,12,{"GYARADOS"},20,32),C("FEEBAS",349,2,{"MAGIKARP"},15,32),C("LUVDISC",370,10,{"MAGIKARP"},18,32),
},"surf")
g2({"ICE_PATH_1F","ICE_PATH_B1F","ICE_PATH_B2F_MAHOGANY_SIDE","ICE_PATH_B2F_BLACKTHORN_SIDE","ICE_PATH_B3F"},44,{
  C("SNORUNT",361,28,{"SWINUB","ZUBAT"},20,38),C("SPHEAL",363,20,{"SWINUB"},22,38),C("ABSOL",359,6,{"SNEASEL","GOLBAT"},28,38,{"NITE"}),C("SWABLU",333,10,{"DELIBIRD","ZUBAT"},22,38),C("SABLEYE",302,8,{"ZUBAT","GOLBAT"},24,38,{"NITE"}),C("DUSKULL",355,8,{"ZUBAT","GOLBAT"},24,38,{"NITE"}),C("ARON",304,10,{"SWINUB"},22,38),C("NOSEPASS",299,10,{"SWINUB"},22,38),
})
g2({"ROUTE_44"},40,{
  C("SWABLU",333,18,{"PIDGEY","SPEAROW"},20,32),C("ROSELIA",315,16,{"BELLSPROUT","TANGELA"},20,32),C("ZANGOOSE",335,12,{"LICKITUNG","RATICATE"},22,32,{"MORN","DAY"}),C("SEVIPER",336,12,{"EKANS","ARBOK"},22,32,{"NITE"}),C("KECLEON",352,12,{"TANGELA","LICKITUNG"},22,32),C("ABSOL",359,6,{"RATICATE"},26,32,{"NITE"}),C("TROPIUS",357,8,{"TANGELA"},25,32),C("SPOINK",325,10,{"RATICATE"},22,32),
})
g2({"ROUTE_45","ROUTE_46"},42,{
  C("ARON",304,18,{"GEODUDE","GRAVELER"},20,38),C("LAIRON",305,5,{"GRAVELER"},30,38),C("NUMEL",322,14,{"GEODUDE"},20,38),C("TRAPINCH",328,14,{"GEODUDE"},20,38),C("VIBRAVA",329,6,{"GRAVELER"},30,38),
  C("BAGON",371,5,{"SKARMORY","GLIGAR"},30,38),C("CACNEA",331,10,{"PHANPY"},20,38),C("ABSOL",359,6,{"GLIGAR"},28,38,{"NITE"}),C("MAWILE",303,8,{"SKARMORY"},24,38),C("MEDITITE",307,14,{"TEDDIURSA"},22,38),
})
g2({"DRAGONS_DEN_1F","DRAGONS_DEN_B1F"},45,{
  C("BAGON",371,30,{"DRATINI"},30,45),C("SHELGON",372,8,{"DRAGONAIR"},38,45),C("SWABLU",333,16,{"MAGIKARP"},30,45),C("ALTARIA",334,5,{"DRAGONAIR"},40,45),C("BARBOACH",339,13,{"MAGIKARP"},30,45),C("RELICANTH",369,5,{"DRAGONAIR"},38,45),C("ABSOL",359,5,{"GOLBAT"},35,45,{"NITE"}),C("SABLEYE",302,8,{"GOLBAT"},32,45,{"NITE"}),C("MAWILE",303,10,{"DRATINI"},32,45),
})
g2({"VICTORY_ROAD"},45,{
  C("BAGON",371,16,{"RHYHORN","ONIX"},32,46),C("SHELGON",372,5,{"RHYDON"},40,46),C("LAIRON",305,14,{"GRAVELER","ONIX"},32,46),C("VIBRAVA",329,12,{"ONIX","SANDSLASH"},32,46),C("ABSOL",359,8,{"GOLBAT","RHYDON"},34,46),
  C("MEDITITE",307,10,{"MACHOKE"},32,46),C("BALTOY",343,10,{"GRAVELER"},32,46),C("MAWILE",303,8,{"ONIX"},32,46),C("SABLEYE",302,7,{"GOLBAT"},32,46,{"NITE"}),C("AGGRON",306,3,{"RHYDON"},44,46),C("FLYGON",330,3,{"RHYDON"},44,46),
})
g2({"ROUTE_28","SILVER_CAVE_OUTSIDE"},46,{
  C("ABSOL",359,10,{"SNEASEL","RAPIDASH"},38,52,{"NITE"}),C("TROPIUS",357,10,{"TANGELA"},38,52),C("ZANGOOSE",335,10,{"RAPIDASH","DODRIO"},38,52,{"MORN","DAY"}),C("SEVIPER",336,10,{"ARBOK"},38,52,{"NITE"}),C("SWABLU",333,12,{"DODRIO"},38,52),C("ALTARIA",334,5,{"DODRIO"},45,52),C("LAIRON",305,12,{"RHYHORN"},38,52),C("BAGON",371,8,{"SNEASEL"},38,52),C("KECLEON",352,12,{"TANGELA"},38,52),C("METANG",375,3,{"MAGNETON"},45,52),
})
g2({"SILVER_CAVE_ROOM_1","SILVER_CAVE_ROOM_2","SILVER_CAVE_ROOM_3","SILVER_CAVE_ITEM_ROOMS"},50,{
  C("AGGRON",306,8,{"RHYDON","ONIX"},42,65),C("FLYGON",330,8,{"RHYDON","ONIX"},42,65),C("SALAMENCE",373,5,{"DRAGONAIR","RHYDON"},48,65),C("METANG",375,10,{"MAGNETON","RHYDON"},42,65),C("METAGROSS",376,3,{"TYRANITAR"},55,65),
  C("DUSCLOPS",356,8,{"MISDREAVUS","GOLBAT"},42,65,{"NITE"}),C("GLALIE",362,8,{"SNEASEL"},42,65),C("WALREIN",365,7,{"SNEASEL"},45,65),C("MEDICHAM",308,8,{"MACHOKE"},42,65),C("CLAYDOL",344,8,{"GRAVELER"},42,65),C("ABSOL",359,10,{"SNEASEL"},42,65),C("TROPIUS",357,7,{"TANGELA"},42,65),C("ARMALDO",348,4,{"RHYDON"},50,65),C("CRADILY",346,4,{"TANGELA"},50,65),
})

local G2_FISH=A(38,{
  C("BARBOACH",339,20,{"MAGIKARP","POLIWAG","GOLDEEN"},10,45),C("CORPHISH",341,18,{"KRABBY","GOLDEEN"},10,45),C("CARVANHA",318,16,{"QWILFISH","KRABBY"},15,45),C("WAILMER",320,16,{"TENTACOOL","MAGIKARP"},15,45),
  C("CLAMPERL",366,12,{"SHELLDER","TENTACOOL"},20,45),C("LUVDISC",370,10,{"GOLDEEN","MAGIKARP"},15,45),C("RELICANTH",369,5,{"CORSOLA","QWILFISH"},25,45),C("FEEBAS",349,2,{"MAGIKARP"},15,45),
})
for _,m in ipairs({"ROUTE_32","ROUTE_34","ROUTE_40","ROUTE_41","OLIVINE_CITY","CIANWOOD_CITY","LAKE_OF_RAGE","WHIRL_ISLAND_NW","WHIRL_ISLAND_NE","WHIRL_ISLAND_SW","DRAGONS_DEN_B1F"}) do G2.fishing[m]=G2_FISH end

local PLAN={[1]=G1,[2]=G2}

local function rngInt(rng,n)
  n=math.max(1,math.floor(tonumber(n) or 1))
  if type(rng)~="function" then return math.random(n) end
  local ok,v=pcall(rng,n)
  if ok and tonumber(v) then
    v=tonumber(v);if v>=1 and v<=n then return math.floor(v) end
    if v>=0 and v<1 then return math.floor(v*n)+1 end
  end
  ok,v=pcall(rng,1,n)
  if ok and tonumber(v) then return math.max(1,math.min(n,math.floor(tonumber(v)))) end
  ok,v=pcall(rng)
  if ok and tonumber(v) then v=tonumber(v);if v>=0 and v<1 then return math.floor(v*n)+1 end end
  return 1
end
local function timeAllowed(row,daytime)
  if not row.times then return true end
  local t=tostring(daytime or "DAY"):upper();if t=="DARK" then t="NITE" end
  return row.times[t]==true
end
local function targetReady(row,ctx,opts,level)
  if not row or not row.species then return false end
  if opts and type(opts.speciesReady)=="function" then
    local ok,ready=pcall(opts.speciesReady,row.species,row.dex,ctx,level)
    if not ok or ready~=true then return false end
  end
  local data=ctx and ctx.data
  if type(data)=="table" and type(data.pokemon)=="table" and data.pokemon[row.species]==nil then return false end
  return true
end
local function candidates(area,vanilla,ctx,opts)
  local level=tonumber(vanilla and vanilla.level) or 1
  local out={}
  for _,row in ipairs(area and area.rows or {}) do
    if (not row.minLevel or level>=row.minLevel) and (not row.maxLevel or level<=row.maxLevel)
        and timeAllowed(row,ctx and ctx.daytime) and targetReady(row,ctx,opts,level) then out[#out+1]=row end
  end
  return out
end
local function weighted(rows,rng)
  local total=0;for _,r in ipairs(rows) do total=total+math.max(0,tonumber(r.weight) or 0) end
  if total<=0 then return nil end
  local roll=rngInt(rng,total);local n=0
  for _,r in ipairs(rows) do n=n+math.max(0,tonumber(r.weight) or 0);if roll<=n then return r end end
  return rows[#rows]
end
local function spawnMode(opts,ctx)
  local mode=opts and opts.mode or nil
  if type(mode)=="function" then
    local ok,value=pcall(mode,ctx)
    if ok then mode=value else return "unavailable" end
  end
  mode=tostring(mode or "mixed"):lower()
  if mode=="new_only" or mode=="new-only" or mode=="new" then return "new_only" end
  return "mixed"
end
local function methodArea(generation,mapId,kind)
  local plan=PLAN[tonumber(generation) or 1] or G1
  local bucket=kind=="surf" and plan.surf or kind=="fishing" and plan.fishing or plan.land
  return bucket and bucket[mapId] or nil
end

local function persistenceReady(opts,ctx)
  local value=opts and opts.persistenceReady
  if type(value)=="function" then local ok,v=pcall(value,ctx);return ok and v==true end
  return value==true
end
local function encounterKind(ctx)
  local kind=ctx and ctx.kind
  if kind=="fishing" or kind=="surf" or kind=="land" then return kind end
  -- Crystal uses kind="wild" for BOTH grass and Surf. Scripted/static,
  -- tutorial, contest, headbutt and rock-smash encounters are not route pools.
  if kind and kind~="wild" then return nil end
  return ctx and ctx.terrain=="water" and "surf" or "land"
end

-- Coverage pools are used ONLY by the explicit COLOSSEUMDEX ONLY setting.
-- They do not create encounter opportunities, edit native tables, change the
-- rolled level, or alter MIXED's authored 50/50 route pools. Basic/unevolved
-- source species avoid low-level evolved/legendary surprises on unplanned maps.
-- Per-species registration, executable moves and checked persistence still gate
-- every result. Pool choice is map/method based, never a native-species gate.
local COVERAGE={}
local function coverage(profile,gen2,gen1)
  local function rows(list)
    local out={};for _,v in ipairs(list) do
      out[#out+1]=C(v[1],v[2],v[3] or 1,{},1,100,nil,"new-only map/method coverage")
    end;return out
  end
  local a=rows(gen1 or {});for _,r in ipairs(rows(gen2)) do a[#a+1]=r end
  COVERAGE[profile]={[1]=A(50,a),[2]=A(50,rows(gen2))}
end
coverage("meadow",{{"ZIGZAGOON",263},{"POOCHYENA",261},{"TAILLOW",276},{"WURMPLE",265}},
  {{"SENTRET",161},{"HOPPIP",187},{"HOOTHOOT",163}})
coverage("forest",{{"WURMPLE",265},{"SHROOMISH",285},{"SEEDOT",273},{"NINCADA",290},{"SLAKOTH",287}},
  {{"PINECO",204},{"AIPOM",190},{"SPINARAK",167},{"LEDYBA",165}})
coverage("cave",{{"WHISMUR",293},{"ARON",304},{"MAKUHITA",296},{"NOSEPASS",299},{"NINCADA",290}},
  {{"DUNSPARCE",206},{"SHUCKLE",213},{"PHANPY",231}})
coverage("ghost",{{"SHUPPET",353},{"DUSKULL",355},{"SABLEYE",302}},
  {{"MISDREAVUS",200},{"MURKROW",198}})
coverage("ice",{{"SNORUNT",361},{"SPHEAL",363}},
  {{"SWINUB",220},{"SNEASEL",215},{"DELIBIRD",225}})
coverage("electric",{{"ELECTRIKE",309},{"PLUSLE",311},{"MINUN",312}},{{"MAREEP",179}})
coverage("fresh",{{"BARBOACH",339},{"CORPHISH",341},{"LOTAD",270},{"SURSKIT",283}},
  {{"WOOPER",194},{"MARILL",183},{"REMORAID",223}})
coverage("coast",{{"WAILMER",320},{"CARVANHA",318},{"CLAMPERL",366},{"LUVDISC",370}},
  {{"CHINCHOU",170},{"QWILFISH",211},{"CORSOLA",222},{"MANTINE",226}})
local COAST=set({"PALLET_TOWN","VERMILION_CITY","FUCHSIA_CITY","CINNABAR_ISLAND",
  "NEW_BARK_TOWN","CHERRYGROVE_CITY","OLIVINE_CITY","CIANWOOD_CITY",
  "ROUTE_19","ROUTE_20","ROUTE_21","ROUTE_26","ROUTE_27","ROUTE_34","ROUTE_40","ROUTE_41"})
local function coverageArea(generation,mapId,kind,ctx)
  -- A successful native roll is proof of an encounter here, but an absent map
  -- identity is not proof that an unrelated scripted call is an ordinary area.
  if type(mapId)~="string" or mapId=="" then return nil end
  local data=ctx and ctx.data or {}
  local maps=(tonumber(generation)==2 and data.gen2Maps) or data.maps
  local def=type(maps)=="table" and maps[mapId] or {}
  if type(def)~="table" then def={} end
  local id=mapId:upper();local profile="meadow"
  local env=tostring((ctx and ctx.environment) or def.environment or def.tileset or ""):upper()
  if kind=="surf" or kind=="fishing" then
    profile=(COAST[id] or id:find("WHIRL_ISLAND",1,true) or id:find("SEAFOAM",1,true)) and "coast" or "fresh"
  elseif id:find("ICE_PATH",1,true) or id:find("SEAFOAM",1,true) or env:find("ICE",1,true) then profile="ice"
  elseif id:find("TOWER",1,true) or id:find("POKEMON_MANSION",1,true) or env:find("CEMETERY",1,true) then profile="ghost"
  elseif id:find("POWER_PLANT",1,true) then profile="electric"
  elseif id:find("FOREST",1,true) or id:find("PARK",1,true) or env:find("FOREST",1,true) then profile="forest"
  elseif not id:find("OUTSIDE",1,true) and (id:find("CAVE",1,true) or id:find("MT_MOON",1,true)
      or id:find("MT_MORTAR",1,true) or id:find("ROCK_TUNNEL",1,true) or id:find("VICTORY_ROAD",1,true)
      or id:find("WHIRL_ISLAND",1,true) or env=="CAVE" or env=="DUNGEON" or env=="CAVERN") then profile="cave" end
  return COVERAGE[profile][tonumber(generation) or 1],profile
end
-- Shared by runtime and the LOCATION projection. Authored eligible rows win;
-- coverage only fills a genuinely empty result in the explicit new-only mode.
function E.candidateRows(generation,vanilla,ctx,opts,resolvedMode)
  ctx=ctx or {};opts=opts or {}
  local kind=encounterKind(ctx)
  if not kind then return {},"non-route-encounter" end
  local area=methodArea(generation,ctx.mapId,kind)
  local rows=candidates(area,vanilla,ctx,opts)
  if #rows>0 then return rows,"planned",area end
  local mode=resolvedMode or spawnMode(opts,ctx)
  if mode=="new_only" then
    local fallback,profile=coverageArea(generation,ctx.mapId,kind,ctx)
    rows=candidates(fallback,vanilla,ctx,opts)
    if #rows>0 then return rows,"coverage:"..profile,fallback end
  end
  return rows,area and "no-added-candidate" or "unplanned-map",area
end

function E.augment(generation,vanilla,ctx,opts)
  if type(vanilla)~="table" then return vanilla,"no-native-encounter" end
  ctx=ctx or {};opts=opts or {}
  if opts.enabled==false then return vanilla,"disabled" end
  local kind=encounterKind(ctx)
  if not kind then return vanilla,"non-route-encounter" end
  local mode=spawnMode(opts,ctx)
  if mode=="unavailable" then return nil,"spawn-mode-unavailable" end
  if not persistenceReady(opts,ctx) then
    if mode=="new_only" then return nil,"new-only-persistence-not-ready" end
    return vanilla,"persistence-not-ready"
  end
  local rows,source,area=E.candidateRows(generation,vanilla,ctx,opts,mode)
  if #rows==0 then
    if mode=="new_only" then return nil,"new-only-no-added-candidate" end
    return vanilla,source
  end
  if mode~="new_only" and rngInt(ctx.rng or opts.rng,100)>math.max(0,math.min(100,area.share or 0)) then return vanilla,"native-pool" end
  local row=weighted(rows,ctx.rng or opts.rng)
  if not row then
    if mode=="new_only" then return nil,"new-only-no-weight" end
    return vanilla,"no-weight"
  end
  local out={};for k,v in pairs(vanilla) do out[k]=v end
  out.species=row.species;out.level=vanilla.level;out.__cbeExpandedDex=true;out.__cbeDex=row.dex
  out.__cbeBaselineSpecies=vanilla.species;out.__cbeNativeSpecies=vanilla.species
  out.__cbeEncounterPool=source
  return out,source=="planned" and "expanded-added" or "expanded-added-coverage"
end

-- Backward-compatible name for callers/tests from the original prototype.
-- Semantics are additive now; no native-slot replacement gate remains.
E.replace=E.augment

function E.replaceFishing(generation,vanilla,rod,mapId,ctx,opts)
  if type(vanilla)~="table" then return vanilla,"no-native-bite" end
  local r=tostring(rod or ""):upper()
  ctx=ctx or {};ctx.mapId=mapId or ctx.mapId;ctx.kind="fishing"
  if r:find("OLD",1,true) then
    local mode=spawnMode(opts,ctx)
    if mode=="unavailable" then return nil,"spawn-mode-unavailable" end
    if mode=="new_only" then return nil,"new-only-old-rod-disabled" end
    return vanilla,"old-rod-native"
  end
  return E.augment(generation,vanilla,ctx,opts)
end

-- Idempotence belongs to the hook registry, not a process-wide boolean. A
-- replacement game/loader registry must get its own hooks; repeat installation
-- on the same registry refreshes live callbacks without stacking wrappers.
local installations=setmetatable({}, {__mode="k"})
local function observed(record,result,why,ctx)
  local observe=record.opts.observe
  -- Diagnostic callbacks must not throw through the host bus: its error policy
  -- keeps the downstream native result, which would defeat new-only mode.
  if type(observe)=="function" then pcall(observe,result,why,ctx) end
  return result
end
local function guarded(record,fn,native,ctx,...)
  local ok,result,why=pcall(fn,...)
  if not ok then
    local mode=spawnMode(record.opts,ctx)
    result=mode=="mixed" and native or nil
    why="encounter-overlay-error"
  end
  return observed(record,result,why,ctx)
end
function E.install(mod,generation,opts)
  if not (mod and mod.hooks and type(mod.hooks.wrap)=="function") then return false,"encounter hooks unavailable" end
  opts=opts or {};generation=tonumber(generation) or 1
  if generation~=1 and generation~=2 then return false,"unsupported encounter generation" end
  if not persistenceReady(opts) then return false,"expanded owned-Pokemon persistence unavailable" end
  local old=installations[mod.hooks]
  if old then old.mod=mod;old.generation=generation;old.opts=opts;return true,"already-installed" end
  local record={mod=mod,generation=generation,opts=opts}
  mod.hooks:wrap("encounter.species",function(next,enc,ctx)
    local native=next(enc,ctx);if not native then return nil end
    -- Do not mutate a host/other-mod context retained across calls.
    local live={};for k,v in pairs(ctx or {}) do live[k]=v end
    if live.data==nil and record.mod.game then live.data=record.mod.game.data end
    return guarded(record,E.augment,native,live,record.generation,native,live,record.opts)
  end,115)
  mod.hooks:wrap("encounter.fishing",function(next,rod,mapId,list,hostCtx)
    local native=next(rod,mapId,list,hostCtx);if not native then return nil end
    local ctx={};if type(hostCtx)=="table" then for k,v in pairs(hostCtx) do ctx[k]=v end end
    ctx.mapId=mapId;ctx.kind="fishing";ctx.rng=ctx.rng or record.opts.rng
    ctx.data=ctx.data or (record.mod.game and record.mod.game.data)
    return guarded(record,E.replaceFishing,native,ctx,record.generation,native,rod,mapId,ctx,record.opts)
  end,115)
  installations[mod.hooks]=record
  E._installed=true;return true,"installed"
end

function E.plan(generation) return PLAN[tonumber(generation) or 1] end
function E.status(generation)
  local p=E.plan(generation);local mapsCount,rows=0,0;local seen={}
  for _,bucket in ipairs({p.land,p.surf,p.fishing}) do for map,area in pairs(bucket) do if not seen[map..tostring(area)] then seen[map..tostring(area)]=true;mapsCount=mapsCount+1 end;rows=rows+#(area.rows or {}) end end
  return {version=E.version,generation=tonumber(generation) or 1,maps=mapsCount,rows=rows,installed=E._installed==true,
    policy="native-encounter/additive-route-pool/native-level-preserved",defaultMode="mixed",mixedSplit="50/50",newOnly="native-off-on-all-route-pools",coverage="map/method-basic-species-new-only"}
end
E._test={rngInt=rngInt,candidates=candidates,weighted=weighted,methodArea=methodArea,timeAllowed=timeAllowed,spawnMode=spawnMode,coverageArea=coverageArea,coverage=COVERAGE}
return E
