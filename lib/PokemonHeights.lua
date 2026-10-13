-- Canonical Gen 1 + Gen 2 + Gen 3 + Gen 4 Pokemon heights, National Dex #1..493.
-- Source: PokeAPI pokemon.csv; height is stored in decimetres.
-- https://github.com/PokeAPI/pokeapi/blob/master/data/v2/csv/pokemon.csv
--
-- These are data values only; no Pokemon/Stadium model assets are included.
local H = {}

H.DECIMETERS = {
  [1] = 7, -- bulbasaur
  [2] = 10, -- ivysaur
  [3] = 20, -- venusaur
  [4] = 6, -- charmander
  [5] = 11, -- charmeleon
  [6] = 17, -- charizard
  [7] = 5, -- squirtle
  [8] = 10, -- wartortle
  [9] = 16, -- blastoise
  [10] = 3, -- caterpie
  [11] = 7, -- metapod
  [12] = 11, -- butterfree
  [13] = 3, -- weedle
  [14] = 6, -- kakuna
  [15] = 10, -- beedrill
  [16] = 3, -- pidgey
  [17] = 11, -- pidgeotto
  [18] = 15, -- pidgeot
  [19] = 3, -- rattata
  [20] = 7, -- raticate
  [21] = 3, -- spearow
  [22] = 12, -- fearow
  [23] = 20, -- ekans
  [24] = 35, -- arbok
  [25] = 4, -- pikachu
  [26] = 8, -- raichu
  [27] = 6, -- sandshrew
  [28] = 10, -- sandslash
  [29] = 4, -- nidoran-f
  [30] = 8, -- nidorina
  [31] = 13, -- nidoqueen
  [32] = 5, -- nidoran-m
  [33] = 9, -- nidorino
  [34] = 14, -- nidoking
  [35] = 6, -- clefairy
  [36] = 13, -- clefable
  [37] = 6, -- vulpix
  [38] = 11, -- ninetales
  [39] = 5, -- jigglypuff
  [40] = 10, -- wigglytuff
  [41] = 8, -- zubat
  [42] = 16, -- golbat
  [43] = 5, -- oddish
  [44] = 8, -- gloom
  [45] = 12, -- vileplume
  [46] = 3, -- paras
  [47] = 10, -- parasect
  [48] = 10, -- venonat
  [49] = 15, -- venomoth
  [50] = 2, -- diglett
  [51] = 7, -- dugtrio
  [52] = 4, -- meowth
  [53] = 10, -- persian
  [54] = 8, -- psyduck
  [55] = 17, -- golduck
  [56] = 5, -- mankey
  [57] = 10, -- primeape
  [58] = 7, -- growlithe
  [59] = 19, -- arcanine
  [60] = 6, -- poliwag
  [61] = 10, -- poliwhirl
  [62] = 13, -- poliwrath
  [63] = 9, -- abra
  [64] = 13, -- kadabra
  [65] = 15, -- alakazam
  [66] = 8, -- machop
  [67] = 15, -- machoke
  [68] = 16, -- machamp
  [69] = 7, -- bellsprout
  [70] = 10, -- weepinbell
  [71] = 17, -- victreebel
  [72] = 9, -- tentacool
  [73] = 16, -- tentacruel
  [74] = 4, -- geodude
  [75] = 10, -- graveler
  [76] = 14, -- golem
  [77] = 10, -- ponyta
  [78] = 17, -- rapidash
  [79] = 12, -- slowpoke
  [80] = 16, -- slowbro
  [81] = 3, -- magnemite
  [82] = 10, -- magneton
  [83] = 8, -- farfetchd
  [84] = 14, -- doduo
  [85] = 18, -- dodrio
  [86] = 11, -- seel
  [87] = 17, -- dewgong
  [88] = 9, -- grimer
  [89] = 12, -- muk
  [90] = 3, -- shellder
  [91] = 15, -- cloyster
  [92] = 13, -- gastly
  [93] = 16, -- haunter
  [94] = 15, -- gengar
  [95] = 88, -- onix
  [96] = 10, -- drowzee
  [97] = 16, -- hypno
  [98] = 4, -- krabby
  [99] = 13, -- kingler
  [100] = 5, -- voltorb
  [101] = 12, -- electrode
  [102] = 4, -- exeggcute
  [103] = 20, -- exeggutor
  [104] = 4, -- cubone
  [105] = 10, -- marowak
  [106] = 15, -- hitmonlee
  [107] = 14, -- hitmonchan
  [108] = 12, -- lickitung
  [109] = 6, -- koffing
  [110] = 12, -- weezing
  [111] = 10, -- rhyhorn
  [112] = 19, -- rhydon
  [113] = 11, -- chansey
  [114] = 10, -- tangela
  [115] = 22, -- kangaskhan
  [116] = 4, -- horsea
  [117] = 12, -- seadra
  [118] = 6, -- goldeen
  [119] = 13, -- seaking
  [120] = 8, -- staryu
  [121] = 11, -- starmie
  [122] = 13, -- mr-mime
  [123] = 15, -- scyther
  [124] = 14, -- jynx
  [125] = 11, -- electabuzz
  [126] = 13, -- magmar
  [127] = 15, -- pinsir
  [128] = 14, -- tauros
  [129] = 9, -- magikarp
  [130] = 65, -- gyarados
  [131] = 25, -- lapras
  [132] = 3, -- ditto
  [133] = 3, -- eevee
  [134] = 10, -- vaporeon
  [135] = 8, -- jolteon
  [136] = 9, -- flareon
  [137] = 8, -- porygon
  [138] = 4, -- omanyte
  [139] = 10, -- omastar
  [140] = 5, -- kabuto
  [141] = 13, -- kabutops
  [142] = 18, -- aerodactyl
  [143] = 21, -- snorlax
  [144] = 17, -- articuno
  [145] = 16, -- zapdos
  [146] = 20, -- moltres
  [147] = 18, -- dratini
  [148] = 40, -- dragonair
  [149] = 22, -- dragonite
  [150] = 20, -- mewtwo
  [151] = 4, -- mew
  [152] = 9, -- chikorita
  [153] = 12, -- bayleef
  [154] = 18, -- meganium
  [155] = 5, -- cyndaquil
  [156] = 9, -- quilava
  [157] = 17, -- typhlosion
  [158] = 6, -- totodile
  [159] = 11, -- croconaw
  [160] = 23, -- feraligatr
  [161] = 8, -- sentret
  [162] = 18, -- furret
  [163] = 7, -- hoothoot
  [164] = 16, -- noctowl
  [165] = 10, -- ledyba
  [166] = 14, -- ledian
  [167] = 5, -- spinarak
  [168] = 11, -- ariados
  [169] = 18, -- crobat
  [170] = 5, -- chinchou
  [171] = 12, -- lanturn
  [172] = 3, -- pichu
  [173] = 3, -- cleffa
  [174] = 3, -- igglybuff
  [175] = 3, -- togepi
  [176] = 6, -- togetic
  [177] = 2, -- natu
  [178] = 15, -- xatu
  [179] = 6, -- mareep
  [180] = 8, -- flaaffy
  [181] = 14, -- ampharos
  [182] = 4, -- bellossom
  [183] = 4, -- marill
  [184] = 8, -- azumarill
  [185] = 12, -- sudowoodo
  [186] = 11, -- politoed
  [187] = 4, -- hoppip
  [188] = 6, -- skiploom
  [189] = 8, -- jumpluff
  [190] = 8, -- aipom
  [191] = 3, -- sunkern
  [192] = 8, -- sunflora
  [193] = 12, -- yanma
  [194] = 4, -- wooper
  [195] = 14, -- quagsire
  [196] = 9, -- espeon
  [197] = 10, -- umbreon
  [198] = 5, -- murkrow
  [199] = 20, -- slowking
  [200] = 7, -- misdreavus
  [201] = 5, -- unown
  [202] = 13, -- wobbuffet
  [203] = 15, -- girafarig
  [204] = 6, -- pineco
  [205] = 12, -- forretress
  [206] = 15, -- dunsparce
  [207] = 11, -- gligar
  [208] = 92, -- steelix
  [209] = 6, -- snubbull
  [210] = 14, -- granbull
  [211] = 5, -- qwilfish
  [212] = 18, -- scizor
  [213] = 6, -- shuckle
  [214] = 15, -- heracross
  [215] = 9, -- sneasel
  [216] = 6, -- teddiursa
  [217] = 18, -- ursaring
  [218] = 7, -- slugma
  [219] = 8, -- magcargo
  [220] = 4, -- swinub
  [221] = 11, -- piloswine
  [222] = 6, -- corsola
  [223] = 6, -- remoraid
  [224] = 9, -- octillery
  [225] = 9, -- delibird
  [226] = 21, -- mantine
  [227] = 17, -- skarmory
  [228] = 6, -- houndour
  [229] = 14, -- houndoom
  [230] = 18, -- kingdra
  [231] = 5, -- phanpy
  [232] = 11, -- donphan
  [233] = 6, -- porygon2
  [234] = 14, -- stantler
  [235] = 12, -- smeargle
  [236] = 7, -- tyrogue
  [237] = 14, -- hitmontop
  [238] = 4, -- smoochum
  [239] = 6, -- elekid
  [240] = 7, -- magby
  [241] = 12, -- miltank
  [242] = 15, -- blissey
  [243] = 19, -- raikou
  [244] = 21, -- entei
  [245] = 20, -- suicune
  [246] = 6, -- larvitar
  [247] = 12, -- pupitar
  [248] = 20, -- tyranitar
  [249] = 52, -- lugia
  [250] = 38, -- ho-oh
  [251] = 6, -- celebi
  -- Gen 3, National Dex #252..386
  [252] = 5, -- treecko
  [253] = 9, -- grovyle
  [254] = 17, -- sceptile
  [255] = 4, -- torchic
  [256] = 9, -- combusken
  [257] = 19, -- blaziken
  [258] = 4, -- mudkip
  [259] = 7, -- marshtomp
  [260] = 15, -- swampert
  [261] = 5, -- poochyena
  [262] = 10, -- mightyena
  [263] = 4, -- zigzagoon
  [264] = 5, -- linoone
  [265] = 3, -- wurmple
  [266] = 6, -- silcoon
  [267] = 10, -- beautifly
  [268] = 7, -- cascoon
  [269] = 12, -- dustox
  [270] = 5, -- lotad
  [271] = 12, -- lombre
  [272] = 15, -- ludicolo
  [273] = 5, -- seedot
  [274] = 10, -- nuzleaf
  [275] = 13, -- shiftry
  [276] = 3, -- taillow
  [277] = 7, -- swellow
  [278] = 6, -- wingull
  [279] = 12, -- pelipper
  [280] = 4, -- ralts
  [281] = 8, -- kirlia
  [282] = 16, -- gardevoir
  [283] = 5, -- surskit
  [284] = 8, -- masquerain
  [285] = 4, -- shroomish
  [286] = 12, -- breloom
  [287] = 8, -- slakoth
  [288] = 14, -- vigoroth
  [289] = 20, -- slaking
  [290] = 5, -- nincada
  [291] = 8, -- ninjask
  [292] = 8, -- shedinja
  [293] = 6, -- whismur
  [294] = 10, -- loudred
  [295] = 15, -- exploud
  [296] = 10, -- makuhita
  [297] = 23, -- hariyama
  [298] = 2, -- azurill
  [299] = 10, -- nosepass
  [300] = 6, -- skitty
  [301] = 11, -- delcatty
  [302] = 5, -- sableye
  [303] = 6, -- mawile
  [304] = 4, -- aron
  [305] = 9, -- lairon
  [306] = 21, -- aggron
  [307] = 6, -- meditite
  [308] = 13, -- medicham
  [309] = 6, -- electrike
  [310] = 15, -- manectric
  [311] = 4, -- plusle
  [312] = 4, -- minun
  [313] = 7, -- volbeat
  [314] = 6, -- illumise
  [315] = 3, -- roselia
  [316] = 4, -- gulpin
  [317] = 17, -- swalot
  [318] = 8, -- carvanha
  [319] = 18, -- sharpedo
  [320] = 20, -- wailmer
  [321] = 145, -- wailord
  [322] = 7, -- numel
  [323] = 19, -- camerupt
  [324] = 5, -- torkoal
  [325] = 7, -- spoink
  [326] = 9, -- grumpig
  [327] = 11, -- spinda
  [328] = 7, -- trapinch
  [329] = 11, -- vibrava
  [330] = 20, -- flygon
  [331] = 4, -- cacnea
  [332] = 13, -- cacturne
  [333] = 4, -- swablu
  [334] = 11, -- altaria
  [335] = 13, -- zangoose
  [336] = 27, -- seviper
  [337] = 10, -- lunatone
  [338] = 12, -- solrock
  [339] = 4, -- barboach
  [340] = 9, -- whiscash
  [341] = 6, -- corphish
  [342] = 11, -- crawdaunt
  [343] = 5, -- baltoy
  [344] = 15, -- claydol
  [345] = 10, -- lileep
  [346] = 15, -- cradily
  [347] = 7, -- anorith
  [348] = 15, -- armaldo
  [349] = 6, -- feebas
  [350] = 62, -- milotic
  [351] = 3, -- castform
  [352] = 10, -- kecleon
  [353] = 6, -- shuppet
  [354] = 11, -- banette
  [355] = 8, -- duskull
  [356] = 16, -- dusclops
  [357] = 20, -- tropius
  [358] = 6, -- chimecho
  [359] = 12, -- absol
  [360] = 6, -- wynaut
  [361] = 7, -- snorunt
  [362] = 15, -- glalie
  [363] = 8, -- spheal
  [364] = 11, -- sealeo
  [365] = 14, -- walrein
  [366] = 4, -- clamperl
  [367] = 17, -- huntail
  [368] = 18, -- gorebyss
  [369] = 10, -- relicanth
  [370] = 6, -- luvdisc
  [371] = 6, -- bagon
  [372] = 11, -- shelgon
  [373] = 15, -- salamence
  [374] = 6, -- beldum
  [375] = 12, -- metang
  [376] = 16, -- metagross
  [377] = 17, -- regirock
  [378] = 18, -- regice
  [379] = 19, -- registeel
  [380] = 14, -- latias
  [381] = 20, -- latios
  [382] = 45, -- kyogre
  [383] = 35, -- groudon
  [384] = 70, -- rayquaza
  [385] = 3, -- jirachi
  [386] = 17, -- deoxys
  -- Gen 4 (#387..493). NOT in the original PokeAPI import above: entered by
  -- hand so Platinum's native Sinnoh species have a height. Verify against
  -- pokemon.csv before shipping (see GEN4_SIZING_NOTES.md).
  [387] = 4, -- turtwig
  [388] = 11, -- grotle
  [389] = 22, -- torterra
  [390] = 5, -- chimchar
  [391] = 9, -- monferno
  [392] = 12, -- infernape
  [393] = 4, -- piplup
  [394] = 8, -- prinplup
  [395] = 17, -- empoleon
  [396] = 3, -- starly
  [397] = 6, -- staravia
  [398] = 12, -- staraptor
  [399] = 5, -- bidoof
  [400] = 10, -- bibarel
  [401] = 3, -- kricketot
  [402] = 10, -- kricketune
  [403] = 5, -- shinx
  [404] = 9, -- luxio
  [405] = 14, -- luxray
  [406] = 2, -- budew
  [407] = 9, -- roserade
  [408] = 9, -- cranidos
  [409] = 16, -- rampardos
  [410] = 5, -- shieldon
  [411] = 13, -- bastiodon
  [412] = 2, -- burmy
  [413] = 5, -- wormadam
  [414] = 9, -- mothim
  [415] = 3, -- combee
  [416] = 12, -- vespiquen
  [417] = 4, -- pachirisu
  [418] = 7, -- buizel
  [419] = 11, -- floatzel
  [420] = 4, -- cherubi
  [421] = 5, -- cherrim
  [422] = 3, -- shellos
  [423] = 9, -- gastrodon
  [424] = 12, -- ambipom
  [425] = 4, -- drifloon
  [426] = 12, -- drifblim
  [427] = 4, -- buneary
  [428] = 12, -- lopunny
  [429] = 9, -- mismagius
  [430] = 9, -- honchkrow
  [431] = 5, -- glameow
  [432] = 10, -- purugly
  [433] = 2, -- chingling
  [434] = 4, -- stunky
  [435] = 10, -- skuntank
  [436] = 5, -- bronzor
  [437] = 13, -- bronzong
  [438] = 5, -- bonsly
  [439] = 6, -- mime-jr
  [440] = 6, -- happiny
  [441] = 5, -- chatot
  [442] = 10, -- spiritomb
  [443] = 7, -- gible
  [444] = 14, -- gabite
  [445] = 19, -- garchomp
  [446] = 6, -- munchlax
  [447] = 7, -- riolu
  [448] = 12, -- lucario
  [449] = 8, -- hippopotas
  [450] = 20, -- hippowdon
  [451] = 8, -- skorupi
  [452] = 13, -- drapion
  [453] = 7, -- croagunk
  [454] = 13, -- toxicroak
  [455] = 14, -- carnivine
  [456] = 4, -- finneon
  [457] = 12, -- lumineon
  [458] = 10, -- mantyke
  [459] = 10, -- snover
  [460] = 22, -- abomasnow
  [461] = 11, -- weavile
  [462] = 12, -- magnezone
  [463] = 17, -- lickilicky
  [464] = 24, -- rhyperior
  [465] = 20, -- tangrowth
  [466] = 18, -- electivire
  [467] = 16, -- magmortar
  [468] = 15, -- togekiss
  [469] = 19, -- yanmega
  [470] = 10, -- leafeon
  [471] = 8, -- glaceon
  [472] = 20, -- gliscor
  [473] = 25, -- mamoswine
  [474] = 9, -- porygon-z
  [475] = 16, -- gallade
  [476] = 14, -- probopass
  [477] = 22, -- dusknoir
  [478] = 13, -- froslass
  [479] = 3, -- rotom
  [480] = 3, -- uxie
  [481] = 3, -- mesprit
  [482] = 3, -- azelf
  [483] = 54, -- dialga
  [484] = 42, -- palkia
  [485] = 17, -- heatran
  [486] = 37, -- regigigas
  [487] = 45, -- giratina
  [488] = 15, -- cresselia
  [489] = 4, -- phione
  [490] = 3, -- manaphy
  [491] = 15, -- darkrai
  [492] = 2, -- shaymin
  [493] = 32, -- arceus
}

function H.meters(dex)
  local dm = H.DECIMETERS[tonumber(dex)]
  return dm and (dm / 10) or nil
end

-- PokeAPI pokemon-shape id per National Dex #1..386.
-- https://github.com/PokeAPI/pokeapi/blob/master/data/v2/csv/pokemon_species.csv
-- 1 ball, 2 squiggle, 3 fish, 4 arms, 5 blob, 6 upright, 7 legs, 8 quadruped,
-- 9 wings, 10 tentacles, 11 heads, 12 humanoid, 13 bug-wings, 14 armor
H.SHAPE = {
   8, 8, 8, 6, 6, 6, 6, 6, 6,14, 2,13,14, 2,13, 9, -- 1..16
   9, 9, 8, 8, 9, 9, 2, 2, 8, 6, 6, 6, 8, 8, 6, 8, -- 17..32
   8, 6, 6, 6, 8, 8,12,12, 9, 9, 7,12,12,14,14,12, -- 33..48
  13, 5,11, 8, 8, 6, 6, 6, 6, 8, 8, 7,12,12, 6, 6, -- 49..64
  12, 6,12,12,12, 5, 5,10,10, 4,12,12, 8, 8, 8, 6, -- 65..80
   4,11, 9, 7, 7, 3, 3, 4, 4, 1, 1, 1, 4, 6, 2,12, -- 81..96
  12,14,14, 1, 1,11, 7, 6, 6,12,12, 6, 1,11, 8, 6, -- 97..112
   6, 7, 6, 5, 5, 3, 3, 5, 5,12,13,12, 6, 6,12, 8, -- 113..128
   3, 2, 3, 1, 8, 8, 8, 8, 7,10,10,14, 6, 9,12, 9, -- 129..144
   9, 9, 2, 2, 6, 6, 6, 8, 8, 8,12, 8, 8, 6, 6, 6, -- 145..160
   8, 8, 9, 9, 9, 9,14,14,13, 3, 3, 8, 6,12,12,12, -- 161..176
   9, 9, 8, 6, 6,12, 6, 6,12,12, 6, 6, 6, 6, 1,12, -- 177..192
  13, 7, 6, 8, 8, 9, 6, 1, 1, 5, 8, 1, 1, 2, 9, 2, -- 193..208
  12, 6, 3,13,14,12, 6, 6, 6, 2, 2, 8, 8,14, 3,10, -- 209..224
   9, 9, 9, 8, 8, 5, 8, 8, 7, 8, 6,12, 6,12,12, 6, -- 225..240
   6,12, 8, 8, 8, 6, 2, 6, 9, 9,12, 6, 6, 6, 7, 6, -- 241..256
   6, 8, 6, 6, 8, 8, 8, 8,14, 1,13, 1,13,14,12,12, -- 257..272
   7,12,12, 9, 9, 9, 9,12,12,12,14,13, 7, 6, 8, 6, -- 273..288
  12,14,13, 5, 6, 6, 6,12,12, 7,12, 8, 8,12,12, 8, -- 289..304
   8, 6,12,12, 8, 8, 6, 6, 6,12,12, 4, 4, 3, 3, 3, -- 305..320
   3, 8, 8, 8, 4, 6, 6,14,13, 9,12,12, 9, 9, 6, 2, -- 321..336
   1, 1, 3, 3,14,14, 4, 4, 5, 5,14, 6, 3, 2, 1, 6, -- 337..352
   1, 6, 4,12, 8, 4, 8, 6,12, 1, 3, 3, 8, 1, 2, 2, -- 353..368
   3, 3,12, 8, 8, 5, 4,11,12,12,12, 9, 9, 3, 6, 2, -- 369..384
  12,12, -- 385..386
}

H.SHAPE_ID = {
  [1] = "ball",
  [2] = "squiggle",
  [3] = "fish",
  [4] = "arms",
  [5] = "blob",
  [6] = "upright",
  [7] = "legs",
  [8] = "quadruped",
  [9] = "wings",
  [10] = "tentacles",
  [11] = "heads",
  [12] = "humanoid",
  [13] = "bug-wings",
  [14] = "armor",
}

-- Global silhouette rules. Pokédex "height" is standing height for uprights
-- and most quadrupeds, but it is body length for long squiggles, often
-- wingspan-adjacent for birds, and tentacle-span for jellies. Colosseum
-- meshes are the compact battle pose, so these factors run for every species
-- of that shape -- not a per-Pokémon patch list.
--
-- Squiggle/fish only kick in past a metre threshold so cocoons (Metapod)
-- and short fish (Magikarp, Lapras) keep published standing size.
H.SHAPE_FACTOR = {
  [9] = 0.80,  -- wings
  [13] = 0.80, -- bug-wings
  [10] = 0.75, -- tentacles
}

H.LENGTH_SHAPE = {
  [2] = { minMeters = 1.5, factor = 0.50 }, -- squiggle: Ekans, Dratini, Onix...
  [3] = { minMeters = 3.0, factor = 0.55 }, -- fish: Wailord, Kyogre
}

-- True exceptions the shape rules still get wrong (sitting upright, long weasel).
H.BATTLE_BODY_FACTOR = {
  [63] = 0.68,  -- abra: upright in the dex, seated/floating in Colosseum
  [162] = 0.62, -- furret: quadruped whose 1.8 m is body length
}

function H.shapeId(dex)
  return H.SHAPE[tonumber(dex)]
end

function H.battleBodyFactor(dex)
  local id = tonumber(dex)
  if not id then return 1 end
  local override = H.BATTLE_BODY_FACTOR[id]
  if override and override > 0 then return override end
  local shape = H.SHAPE[id]
  local meters = H.meters(id)
  local lengthRule = shape and H.LENGTH_SHAPE[shape]
  if lengthRule and meters and meters >= lengthRule.minMeters then
    return lengthRule.factor
  end
  local byShape = shape and H.SHAPE_FACTOR[shape]
  if byShape and byShape > 0 then return byShape end
  return 1
end

-- ---------------------------------------------------------------------------
-- Shared presentation size (dex -> size relative to a ~1.70 m trainer).
--
-- This is the SAME arithmetic PokemonActors.normalizedPresentationRelative()
-- applies to every Colosseum actor (soft allometric curve, battleBodyFactor,
-- readability floor, giant ceiling). It lives here as well so renderers that
-- are not PokemonActors -- the Platinum native-world HD cards and Stadium
-- models, see Gen4PokemonScale.lua -- size a species identically to the
-- Colosseum model instead of inventing their own convention.
--
-- KEEP IN SYNC with PokemonActors.lua (HUMAN_REFERENCE_METERS, SCALE_CURVE_EXP,
-- MIN/MAX_READABLE_RELATIVE, TINY_SPECIES_FLOOR, LARGE_SPECIES_CEILING).
-- ---------------------------------------------------------------------------
H.HUMAN_REFERENCE_METERS = 1.70
H.SCALE_CURVE_EXP = 0.72
H.MIN_READABLE_RELATIVE = 0.29
H.MAX_READABLE_RELATIVE = 1.58

H.TINY_SPECIES_FLOOR = {
  [10] = 0.32, -- caterpie
  [13] = 0.34, -- weedle
  [50] = 0.32, -- diglett
  [19] = 0.31, -- rattata
  [21] = 0.31, -- spearow
}

H.LARGE_SPECIES_CEILING = {
  [95]  = 1.38, -- onix
  [130] = 1.34, -- gyarados
  [131] = 1.48, -- lapras
  [143] = 1.42, -- snorlax
  [149] = 1.46, -- dragonite
  [208] = 1.42, -- steelix
  [249] = 1.50, -- lugia
  [250] = 1.50, -- ho-oh
}

-- nil when the species has no canonical height (callers must not guess).
function H.presentationRelative(dex)
  local id = tonumber(dex)
  if not id then return nil end
  local meters = H.meters(id)
  if not (meters and meters > 0) then return nil end
  local raw = math.max(0.04, meters / H.HUMAN_REFERENCE_METERS)
  local relative = (raw ^ H.SCALE_CURVE_EXP) * H.battleBodyFactor(id)
  local floor = H.TINY_SPECIES_FLOOR[id] or H.MIN_READABLE_RELATIVE
  local ceiling = H.LARGE_SPECIES_CEILING[id] or H.MAX_READABLE_RELATIVE
  return math.min(math.max(relative, floor), ceiling)
end

return H
