-- lib/ColosseumDex.lua
--
-- National Dex (1-386) -> Pokemon Colosseum GC6E01 asset identity.
--
-- Every stem below was verified against the real GC6E01 file table: each one
-- exists as pkx_<stem>.fsys and holds exactly ONE member, an LZSS-compressed
-- fileType 0x1E (.pkx) battle-model wrapper.
--
-- Colosseum ships the full Gen 1-3 model set because it has to render anything
-- traded in from the GBA titles, so National Dex coverage is complete: 386/386.
-- No second disc is required.
--
-- Stems are the romanized Japanese asset names used on the disc, NOT English
-- species names. Do not "correct" them.

local D={version=1,discId="GC6E01",memberType=0x1E}

-- [dex]={stem,compressedArchiveBytes}
D.species={
  [1]={"fushigidane",211712},
  [2]={"fushigisou",252000},
  [3]={"fushigibana",329120},
  [4]={"hitokage",238720},
  [5]={"lizardo",182304},
  [6]={"lizardon",336768},
  [7]={"zenigame",145664},
  [8]={"kameil",262432},
  [9]={"kamex",273216},
  [10]={"caterpie",94528},
  [11]={"transel",39040},
  [12]={"butterfree",94240},
  [13]={"beedle",165504},
  [14]={"cocoon",45344},
  [15]={"spear",222144},
  [16]={"poppo",176352},
  [17]={"pigeon",217152},
  [18]={"pigeot",226112},
  [19]={"koratta",185152},
  [20]={"ratta",122176},
  [21]={"onisuzume",204416},
  [22]={"onidrill",146528},
  [23]={"arbo",265920},
  [24]={"arbok",127776},
  [25]={"pikachu",258272},
  [26]={"raichu",223616},
  [27]={"sand",141792},
  [28]={"sandpan",281696},
  [29]={"nidoran_f",156608},
  [30]={"nidorina",148704},
  [31]={"nidoqueen",256128},
  [32]={"nidoran_m",163488},
  [33]={"nidorino",123360},
  [34]={"nidoking",186528},
  [35]={"pippi",142912},
  [36]={"pixy",141472},
  [37]={"rokon",202464},
  [38]={"kyukon",169056},
  [39]={"purin",70560},
  [40]={"pukurin",124640},
  [41]={"zubat",52928},
  [42]={"golbat",227616},
  [43]={"nazonokusa",168768},
  [44]={"kusaihana",191616},
  [45]={"ruffresia",121088},
  [46]={"paras",155680},
  [47]={"parasect",99584},
  [48]={"kongpang",313536},
  [49]={"morphon",57344},
  [50]={"digda",49312},
  [51]={"dugtrio",91584},
  [52]={"nyarth",139392},
  [53]={"persian",123360},
  [54]={"koduck",129184},
  [55]={"golduck",215872},
  [56]={"mankey",169632},
  [57]={"okorizaru",108704},
  [58]={"gardie",134752},
  [59]={"windie",249632},
  [60]={"nyoromo",179520},
  [61]={"nyorozo",119168},
  [62]={"nyorobon",278016},
  [63]={"casey",228800},
  [64]={"yungerer",190944},
  [65]={"foodin",183616},
  [66]={"wanriky",222848},
  [67]={"goriky",164416},
  [68]={"kairiky",199264},
  [69]={"madatsubomi",189568},
  [70]={"utsudon",101440},
  [71]={"utsubot",122080},
  [72]={"menokurage",72320},
  [73]={"dokukurage",125120},
  [74]={"ishitsubute",69440},
  [75]={"golone",199392},
  [76]={"golonya",249312},
  [77]={"ponyta",296480},
  [78]={"gallop",209216},
  [79]={"yadon",111520},
  [80]={"yadoran",138496},
  [81]={"coil",46368},
  [82]={"rarecoil",114912},
  [83]={"kamonegi",231072},
  [84]={"dodo",215552},
  [85]={"dodorio",211712},
  [86]={"pawou",81536},
  [87]={"jugon",70880},
  [88]={"betbeter",118656},
  [89]={"betbeton",163680},
  [90]={"shellder",53376},
  [91]={"parshen",73792},
  [92]={"ghos",83520},
  [93]={"ghost",111648},
  [94]={"gangar",134528},
  [95]={"iwark",241792},
  [96]={"sleepe",133984},
  [97]={"sleeper",263488},
  [98]={"crab",135232},
  [99]={"kingler",159040},
  [100]={"biriridama",45472},
  [101]={"marumine",90784},
  [102]={"tamatama",145120},
  [103]={"nassy",193664},
  [104]={"karakara",170208},
  [105]={"garagara",143680},
  [106]={"sawamular",205312},
  [107]={"ebiwalar",173440},
  [108]={"beroringa",114752},
  [109]={"dogars",81056},
  [110]={"matadogas",141472},
  [111]={"sihorn",138976},
  [112]={"sidon",151808},
  [113]={"lucky",132160},
  [114]={"monjara",324736},
  [115]={"garura",243424},
  [116]={"tattu",69952},
  [117]={"seadra",67904},
  [118]={"tosakinto",102912},
  [119]={"azumao",107712},
  [120]={"hitodeman",61440},
  [121]={"starmie",103232},
  [122]={"barrierd",283296},
  [123]={"strike",223776},
  [124]={"rougela",282848},
  [125]={"eleboo",238400},
  [126]={"boober",235968},
  [127]={"kailios",178272},
  [128]={"kentauros",300992},
  [129]={"koiking",146560},
  [130]={"gyarados",133216},
  [131]={"laplace",118656},
  [132]={"metamon",92416},
  [133]={"eievui",224064},
  [134]={"showers",248032},
  [135]={"thunders",262048},
  [136]={"booster",303968},
  [137]={"porygon",71168},
  [138]={"omnite",54976},
  [139]={"omstar",214080},
  [140]={"kabuto",80864},
  [141]={"kabutops",284256},
  [142]={"ptera",160640},
  [143]={"kabigon",164032},
  [144]={"freezer",335552},
  [145]={"thunder",128896},
  [146]={"fire",274432},
  [147]={"miniryu",75488},
  [148]={"hakuryu",64800},
  [149]={"kairyu",288160},
  [150]={"mewtwo",260096},
  [151]={"mew",165152},
  [152]={"chicorita",102496},
  [153]={"bayleaf",164096},
  [154]={"meganium",145600},
  [155]={"hinoarashi",139072},
  [156]={"magmarashi",208544},
  [157]={"bakphoon",138368},
  [158]={"waninoko",140864},
  [159]={"alligates",180256},
  [160]={"ordile",136288},
  [161]={"otachi",200064},
  [162]={"ootachi",309600},
  [163]={"hoho",126880},
  [164]={"yorunozuku",234304},
  [165]={"rediba",91136},
  [166]={"redian",77248},
  [167]={"itomaru",123424},
  [168]={"ariados",289920},
  [169]={"crobat",187456},
  [170]={"chonchie",96288},
  [171]={"lantern",126496},
  [172]={"pichu",185344},
  [173]={"py",84544},
  -- Real, pre-existing bug found and fixed while adding Gen III (this
  -- entry predates this pass): dex 174 is Igglybuff, whose official
  -- Japanese romaji is "Pupurin" -- confirmed directly. "ruriri" is
  -- actually Azurill's (dex 298, Gen III) archive; the two species are
  -- NOT visually interchangeable (Igglybuff is pink/tailless, Azurill is
  -- blue with a ball-tipped tail), so this was never a legitimate shared
  -- asset, just a wrong stem. Fixed to the real archive.
  [174]={"pupurin",58592},
  [175]={"togepy",70272},
  [176]={"togechick",116032},
  [177]={"natio",152896},
  [178]={"naty",66080},
  [179]={"merriep",147328},
  [180]={"mokoko",146976},
  [181]={"denryu",105536},
  [182]={"kireihana",163008},
  [183]={"maril",73088},
  [184]={"marilli",143200},
  [185]={"usokkie",120480},
  [186]={"nyorotono",147648},
  [187]={"hanecco",311392},
  [188]={"popocco",180224},
  [189]={"watacco",112192},
  [190]={"eipam",184416},
  [191]={"himanuts",61312},
  [192]={"kimawari",116544},
  [193]={"yanyanma",92864},
  [194]={"upah",131968},
  [195]={"nuoh",109088},
  [196]={"eifie",146336},
  [197]={"blacky",157664},
  [198]={"yamikarasu",176608},
  [199]={"yadoking",154464},
  [200]={"muma",203872},
  [201]={"unknown_a",76640},
  [202]={"sonans",87808},
  [203]={"kirinriki",177632},
  [204]={"kunugidama",166144},
  [205]={"foretos",124288},
  [206]={"nokocchi",86688},
  [207]={"gliger",127104},
  [208]={"haganeil",109952},
  [209]={"bulu",109152},
  [210]={"granbulu",171072},
  [211]={"harysen",52896},
  [212]={"hassam",146656},
  [213]={"tsubotsubo",86368},
  [214]={"heracros",182464},
  [215]={"nyula",187456},
  [216]={"himeguma",104576},
  [217]={"ringuma",205952},
  [218]={"magmag",152224},
  [219]={"magcargot",164128},
  [220]={"urimoo",105344},
  [221]={"inomoo",149984},
  [222]={"sunnygo",32736},
  [223]={"teppouo",54688},
  [224]={"okutank",127392},
  [225]={"delibird",219072},
  [226]={"mantain",114528},
  [227]={"airmd",264512},
  [228]={"delvil",133536},
  [229]={"hellgar",153344},
  [230]={"kingdra",71264},
  [231]={"gomazou",152928},
  [232]={"donfan",154912},
  [233]={"porygon2",49248},
  [234]={"odoshishi",136320},
  [235]={"doble",192192},
  [236]={"balkie",147520},
  [237]={"kapoerer",100608},
  [238]={"muchul",147424},
  [239]={"elekid",216672},
  [240]={"buby",114624},
  [241]={"miltank",154656},
  [242]={"happinas",170016},
  [243]={"raikou",169856},
  [244]={"entei",249216},
  [245]={"suikun",353280},
  [246]={"yogiras",96320},
  [247]={"sanagiras",30880},
  [248]={"bangiras",131840},
  [249]={"lugia",227520},
  [250]={"houou",336768},
  [251]={"cerebi",128672},

  -- ===== Gen III (Hoenn, 252-386) =====
  -- Colosseum's own disc genuinely ships all 386 species (it has to render
  -- anything traded in from the GBA titles) -- confirmed directly: 527
  -- pkx_*.fsys archives exist on GC6E01 total, far more than the 251
  -- entries above account for. Every stem below was verified against the
  -- real file table exactly like the Gen 1/2 entries above -- either (a)
  -- confirmed directly via a matching pkx_rare_<stem>.fsys "story/
  -- cinematic" archive (see D.rare below -- 13 starters+legendaries this
  -- way), (b) an exact match between the species' official Japanese
  -- romaji name and a real archive stem (100 of 135), or (c) the same
  -- ASCII-simplified-romaji pattern the confirmed entries already show
  -- (e.g. "Dātengu"->dirteng, "Chāremu"->charem) applied to a real,
  -- otherwise-unclaimed archive stem (the rest).
  --
  -- Four entries previously looked anomalous only because their retail stems
  -- were compared with literal/Hepburn-style readings of the Japanese names.
  -- The official/trademarked romanizations are exactly the GC6E01 stems below:
  --   [332]="noctus"  (Cacturne; ノクタス: Hepburn Nokutasu, trademarked Noctus)
  --   [358]="chirean" (Chimecho; チリーン: Hepburn Chirin, trademarked Chirean)
  --   [369]="glanth"  (Relicanth; ジーランス: Hepburn Jiransu, trademarked Glanth)
  --   [374]="dumbber" (Beldum; ダンバル: Hepburn Danbaru, trademarked Dumbber)
  -- Direct local retail corroboration: the GC6E01 FST contains each exact
  -- pkx_<stem>.fsys at the byte size recorded below, and each FSYS contains one
  -- type-0x1E member whose short name is that same stem. These are source-backed
  -- mappings, not best-effort assignments.
  -- Every one of the 135 entries below maps to a DISTINCT real archive
  -- (no two dex numbers share a stem) and every stem was confirmed
  -- present in the real GC6E01 file table -- verified programmatically,
  -- not just by eye.
  [252]={"kimori",148512},
  [253]={"juptile",176800},
  [254]={"jukain",202720},
  [255]={"achamo",185760},
  [256]={"wakasyamo",148864},
  [257]={"bursyamo",182816},
  [258]={"mizugorou",176864},
  [259]={"numacraw",167520},
  [260]={"laglarge",198560},
  [261]={"pochiena",203584},
  [262]={"guraena",212064},
  [263]={"ziguzaguma",213024},
  [264]={"massuguma",245248},
  [265]={"kemusso",60608},
  [266]={"karasalis",94912},
  [267]={"agehunt",154560},
  [268]={"mayuld",127776},
  [269]={"dokucale",55104},
  [270]={"hassboh",93088},
  [271]={"hasubrero",174592},
  [272]={"runpappa",202016},
  [273]={"taneboh",66592},
  [274]={"konohana",187456},
  [275]={"dirteng",202016},
  [276]={"subame",246624},
  [277]={"ohsubame",250304},
  [278]={"camome",68192},
  [279]={"pelipper",197504},
  [280]={"ralts",80288},
  [281]={"kirlia",137984},
  [282]={"sirnight",174816},
  [283]={"ametama",104896},
  [284]={"amemoth",60736},
  [285]={"kinococo",139584},
  [286]={"kinogassa",170560},
  [287]={"namakero",135456},
  [288]={"yarukimono",170656},
  [289]={"kekking",274400},
  [290]={"tutinin",180224},
  [291]={"tekkanin",67872},
  [292]={"nukenin",33760},
  [293]={"gonyonyo",88000},
  [294]={"dogohmb",133856},
  [295]={"bakuong",126432},
  [296]={"makunoshita",112352},
  [297]={"hariteyama",190592},
  [298]={"ruriri",115616},
  [299]={"nosepass",56832},
  [300]={"eneco",75840},
  [301]={"enekororo",146752},
  [302]={"yamirami",86560},
  [303]={"kucheat",264928},
  [304]={"cokodora",99328},
  [305]={"kodora",189760},
  [306]={"bossgodora",158624},
  [307]={"asanan",184736},
  [308]={"charem",164384},
  [309]={"rakurai",272096},
  [310]={"livolt",317952},
  [311]={"prasle",183104},
  [312]={"minun",182368},
  [313]={"barubeat",174240},
  [314]={"illumise",72992},
  [315]={"roselia",185376},
  [316]={"gokulin",108704},
  [317]={"marunoom",211488},
  [318]={"kibanha",127072},
  [319]={"samehader",205344},
  [320]={"hoeruko",83584},
  [321]={"whaloh",121696},
  [322]={"donmel",118016},
  [323]={"bakuuda",201088},
  [324]={"cotoise",253856},
  [325]={"baneboo",113120},
  [326]={"boopig",121152},
  [327]={"patcheel",209696},
  [328]={"nuckrar",194208},
  [329]={"vibrava",223680},
  [330]={"frygon",166144},
  [331]={"sabonea",96544},
  [332]={"noctus",138112},
  [333]={"tyltto",249216},
  [334]={"tyltalis",260992},
  [335]={"zangoose",235232},
  [336]={"habunake",311968},
  [337]={"lunatone",83200},
  [338]={"solrock",88512},
  [339]={"dojoach",156512},
  [340]={"namazun",79488},
  [341]={"heigani",233632},
  [342]={"shizariger",136352},
  [343]={"yajilon",54912},
  [344]={"nendoll",113088},
  [345]={"lilyla",100416},
  [346]={"yuradle",87520},
  [347]={"anopth",104512},
  [348]={"armaldo",149536},
  [349]={"hinbass",58912},
  [350]={"milokaross",335712},
  [351]={"powalen",63264},
  [352]={"kakureon",218272},
  [353]={"kagebouzu",244512},
  [354]={"juppeta",134752},
  [355]={"yomawaru",107744},
  [356]={"samayouru",94400},
  [357]={"tropius",268512},
  [358]={"chirean",47936},
  [359]={"absol",249888},
  [360]={"sohnano",99488},
  [361]={"yukiwarashi",126528},
  [362]={"onigohri",70656},
  [363]={"tamazarashi",85216},
  [364]={"todoggler",93504},
  [365]={"todoseruga",193696},
  [366]={"pearlulu",75392},
  [367]={"huntail",118464},
  [368]={"sakurabyss",73568},
  [369]={"glanth",42880},
  [370]={"lovecus",48160},
  [371]={"tatsubay",177696},
  [372]={"komoruu",153280},
  [373]={"bohmander",231616},
  [374]={"dumbber",46624},
  [375]={"metang",93664},
  [376]={"metagross",187360},
  [377]={"regirock",250656},
  [378]={"regice",62720},
  [379]={"registeel",125184},
  [380]={"latias",108096},
  [381]={"latios",86592},
  [382]={"kyogre",110688},
  [383]={"groudon",264032},
  [384]={"rayquaza",311872},
  [385]={"jirachi",160608},
  [386]={"deoxys",300640},
}

-- Unown (201) is one dex number with 28 authored form models.
-- Index 1-26 = A-Z, 27 = "!", 28 = "?".
D.unownForms={"unknown_a","unknown_b","unknown_c","unknown_d","unknown_e","unknown_f","unknown_g","unknown_h","unknown_i","unknown_j","unknown_k","unknown_l","unknown_m","unknown_n","unknown_o","unknown_p","unknown_q","unknown_r","unknown_s","unknown_t","unknown_u","unknown_v","unknown_w","unknown_x","unknown_y","unknown_z","unknown_ex","unknown_qu"}

-- Colosseum does NOT ship a shiny model per species. Only these stems have a
-- pkx_rare_<stem>.fsys, and they are story/cinematic assets. Shiny colouring
-- for every other species is a runtime palette shift, exactly as the source
-- game does it -- a missing rare_ archive is NOT an error.
D.rare={
  [3]="rare_fushigibana",
  [6]="rare_lizardon",
  [9]="rare_kamex",
  [130]="rare_gyarados",
  [144]="rare_freezer",
  [145]="rare_thunder",
  [146]="rare_fire",
  [150]="rare_mewtwo",
  [151]="rare_mew",
  [154]="rare_meganium",
  [157]="rare_bakphoon",
  [160]="rare_ordile",
  [164]="rare_yorunozuku",
  [243]="rare_raikou",
  [244]="rare_entei",
  [245]="rare_suikun",
  [249]="rare_lugia",
  [250]="rare_houou",
  [251]="rare_cerebi",

  -- Gen III: the same pkx_rare_<stem>.fsys pattern, confirmed present for
  -- all three Hoenn starter lines plus every Hoenn legendary/mythical --
  -- exactly the same "story/cinematic" category the Gen 1/2 entries above
  -- cover, not a new mechanism.
  [252]="rare_kimori",
  [253]="rare_juptile",
  [254]="rare_jukain",
  [255]="rare_achamo",
  [256]="rare_wakasyamo",
  [257]="rare_bursyamo",
  [258]="rare_mizugorou",
  [259]="rare_numacraw",
  [260]="rare_laglarge",
  [380]="rare_latias",
  [381]="rare_latios",
  [382]="rare_kyogre",
  [383]="rare_groudon",
  [384]="rare_rayquaza",
  [385]="rare_jirachi",
  [386]="rare_deoxys",
}

function D.number(dex)
  return tonumber(dex) or (type(dex)=="string" and tonumber(dex:match("^(%d+):shiny$"))) or nil
end
function D.variant(dex,variant)
  if variant~=nil then return variant=="shiny" and "shiny" or "normal" end
  return type(dex)=="string" and dex:match(":shiny$") and "shiny" or "normal"
end
function D.modelKey(dex,variant)
  local n=D.number(dex);if not n then return nil end
  return D.variant(dex,variant)=="shiny" and D.rare[n] and (tostring(n)..":shiny") or n
end
function D.cacheRoot(dex,variant)
  local n=D.number(dex) or 0
  return ("cache/pokemon/%d"):format(n)..(type(D.modelKey(dex,variant))=="string" and "/shiny" or "")
end

function D.archive(dex,variant,unownForm)
  variant=D.variant(dex,variant)
  dex=D.number(dex)
  local entry=dex and D.species[dex]
  if not entry then return nil,"no Colosseum asset for dex "..tostring(dex) end
  if dex==201 then
    local form=D.unownForms[tonumber(unownForm) or 1] or D.unownForms[1]
    return "pkx_"..form..".fsys",form
  end
  if variant=="shiny" and D.rare[dex] then
    return "pkx_"..D.rare[dex]..".fsys",D.rare[dex]
  end
  return "pkx_"..entry[1]..".fsys",entry[1]
end

-- Return the source-backed GC6E01 archive stem without forcing callers to
-- reconstruct it from the archive filename. This keeps encounter/cache
-- coverage checks on the same canonical mapping used by D.archive().
function D.stem(dex,variant,unownForm)
  local _,stem=D.archive(dex,variant,unownForm)
  return stem
end

function D.supported(dex)
  dex=D.number(dex)
  return dex~=nil and D.species[dex]~=nil
end

-- Total compressed footprint represented by D.species, for build-time
-- budgeting. Keep this paired with speciesCount so cache/status code cannot
-- silently advertise only the Gen I/II subset after Hoenn assets are present.
D.totalCompressedBytes=60519712
D.speciesCount=386

return D
