-- Mt. Battle 100 trainer identities: deterministic name + personality +
-- title per fight, so generated opponents "have deterministic identities
-- rather than feeling like identical anonymous CPUs" (supplemental
-- design doc). Consumes stream draws in a fixed position of the
-- generation call order, same determinism contract as every other piece
-- of one fight's generation.
local TIG={}

-- A small combinatorial name pool rather than a large curated database --
-- deterministic and varied enough to avoid obvious repetition across 100
-- fights (900 prefix*suffix combinations), without inventing hundreds of
-- one-off flavor names this pass has no basis to justify individually.
TIG.PREFIXES={
  "ACE","IRON","STONE","SWIFT","CRAG","EMBER","FROST","THUNDER","SHADOW",
  "GALE","RIDGE","VOLT","QUARTZ","OBSIDIAN","CINDER","MIST","BRISK","GRIT",
  "AMBER","ONYX","TEMPEST","HOLLOW","SILT","BRAMBLE","HALCYON","UMBRA",
  "SPARK","GRANITE","MARSH","ZEPHYR",
}
TIG.SUFFIXES={
  "KADE","REN","MORA","VESS","TARN","OKI","LYRA","BRAND","HOLT","VANE",
  "WICK","ROSS","DAHL","FINN","QUILL","SORA","THORNE","WREN","GALEN","ASH",
  "CASS","DRISK","EIRA","FALK","GARR","HESS","IONA","JODEL","KORA","LUNE",
}

TIG.TITLE_BY_PERSONALITY={
  aggressive="BRAWLER",technical="TACTICIAN",defensive="SENTINEL",
  disruptive="TRICKSTER",setup="STRATEGIST",unpredictable="WILDCARD",
}

TIG.AREA_LEADER_TITLE="AREA LEADER"
TIG.FINALE_NAME="THE MT. BATTLE MASTER"
TIG.FINALE_TITLE="MT. BATTLE MASTER"

-- Consumes exactly 2 stream draws (prefix, suffix) -- fixed position,
-- same rule every generation step follows.
function TIG.rollName(stream)
  local prefix=stream:pick(TIG.PREFIXES)
  local suffix=stream:pick(TIG.SUFFIXES)
  return prefix..suffix
end

-- fightIndex==100 gets the FIXED finale identity (name/title constant
-- across every run -- "a permanent name/identity" per the doc -- only
-- the TEAM stays adaptive); every other fight gets a rolled name.
-- isAreaLeader fights (including 100, though 100's own fixed title wins)
-- get the AREA_LEADER_TITLE prefix on top of their personality title.
function TIG.generate(stream,fightIndex,isAreaLeader,personality)
  if fightIndex==100 then
    return {name=TIG.FINALE_NAME,personality=personality.id,title=TIG.FINALE_TITLE,fixed=true}
  end
  local name=TIG.rollName(stream)
  local personalityTitle=TIG.TITLE_BY_PERSONALITY[personality.id] or "TRAINER"
  local title=isAreaLeader and (TIG.AREA_LEADER_TITLE.." "..personalityTitle) or personalityTitle
  return {name=name,personality=personality.id,title=title,fixed=false}
end

return TIG
