-- UI-only display adapter for version-1 CBE doubles producers predating the
-- optional Test 3 display fields. Never calls a battle method or writes to a
-- producer, native party, save, move or species record. Command validation stays
-- entirely in CBE. This does not try to infer a different doubles protocol.
local C={version=1}
local function tableOf(t) return type(t)=='table' and t or nil end
local function shallow(t)
  local out={};for k,v in pairs(t or {}) do out[k]=v end;return out
end
local function scalar(v)
  local kind=type(v);return kind=='string' or kind=='number' or kind=='boolean'
end
local function fields(source,names)
  local out={};source=tableOf(source) or {}
  for _,key in ipairs(names) do if scalar(source[key]) then out[key]=source[key] end end
  return out
end
local function flat(source,limit)
  local out={};local n=0
  for k,v in pairs(tableOf(source) or {}) do
    if scalar(k) and scalar(v) then
      n=n+1;if n>limit then break end;out[k]=v
    end
  end
  return out
end
local portraitFields={'species','dex','level','nickname','name','gender','shiny','isShiny','exp','experience','xp','abilityId','abilityName','otId'}
local monFields={'hp','maxHp','maxHP','status','isEgg','egg','item','type1','type2'}
local function portrait(source)
  local out=fields(source,portraitFields)
  if source and tableOf(source.dvs) then out.dvs=flat(source.dvs,12) end
  return out
end
local function hasXP(mon)
  return mon and (mon.exp~=nil or mon.experience~=nil or mon.xp~=nil)
end
local function fillPortrait(p,source)
  local out=portrait(p);local fallback=portrait(source)
  local keepXP=hasXP(out)
  for k,v in pairs(fallback) do
    if out[k]==nil and not (keepXP and (k=='exp' or k=='experience' or k=='xp')) then out[k]=v end
  end
  return out
end
-- Use the same native party view as the existing Gen I/II host, but read its
-- table directly. In particular, do not invoke a mod-overridden getter here.
local function hostParty(host)
  host=tableOf(host);if not host then return nil end
  return tableOf(rawget(host,'playerParty')) or tableOf(rawget(host,'party'))
end
function C.nativeParty(game,battle)
  battle=tableOf(battle)
  if battle then
    local p=hostParty(rawget(battle,'battle')) or hostParty(battle)
      or hostParty(rawget(battle,'_model')) or hostParty(rawget(battle,'_view'))
    if p then return p end
  end
  return game and game.save and tableOf(game.save.party) or nil
end
local function indexOf(n)
  return type(n)=='number' and n==math.floor(n) and n>=1 and n<=6 and n or nil
end
local function match(party,index,row)
  index=indexOf(index)
  local mon=party and index and tableOf(party[index])
  if not mon then return nil end
  -- No name/species search or roster reordering: duplicate species are ordinary
  -- distinct party members. A known species conflict fails closed.
  local p=row and tableOf(row.portrait)
  local species=row and (row.species or (p and p.species))
  if species~=nil and species~=mon.species then return nil end
  return mon
end
local function types(source,data,species)
  local def=data and data.pokemon and data.pokemon[species]
  local raw=source and tableOf(source.types)
  if not raw or #raw==0 then raw=def and tableOf(def.types) end
  if not raw or #raw==0 then
    raw={source and source.type1 or def and def.type1,source and source.type2 or def and def.type2}
  end
  local out={}
  for i=1,math.min(#raw,4) do
    local value=raw[i]
    if type(value)=='table' then value=value.name or value.id or value.type end
    if type(value)=='string' or type(value)=='number' then
      local name=tostring(value):upper():gsub('^TYPE_',''):gsub('_TYPE$','')
      if name~='' and name~='NONE' and name~=out[1] then out[#out+1]=name end
      if #out==2 then break end
    end
  end
  return out
end
local function displayMon(source)
  local out=portrait(source)
  for k,v in pairs(fields(source,monFields)) do out[k]=v end
  out.stats=flat(source and source.stats,24)
  out.moves={}
  for i,move in ipairs(source and tableOf(source.moves) or {}) do
    if i>4 then break end
    if type(move)=='table' then out.moves[i]=flat(move,16)
    elseif scalar(move) then out.moves[i]={id=move} end
  end
  return out
end
local function needsRow(row)
  return row and not row.empty and
    (row.types==nil or (row.side=='player' and not hasXP(row.portrait or row.display)))
end
local function enrichRow(row,native,data)
  if not needsRow(row) then return row end
  local out=shallow(row)
  -- Live HP/status/identity/target fields must NEVER replace the snapshot's
  -- presentation fields: the native kernel may be ahead of the displayed event.
  if row.side=='player' then
    local base=row.portrait or row.display or row
    out.portrait=fillPortrait(base,native)
  end
  if row.types==nil then out.types=types(native or row.portrait or row,data,row.species or (out.portrait and out.portrait.species)) end
  return out
end
function C.enrich(game,battle,snapshot,page)
  if type(snapshot)~='table' then return snapshot end
  local needs=false
  for _,row in ipairs(snapshot.slots or {}) do if needsRow(row) then needs=true;break end end
  if page=='party' or page=='item-party' or page=='item-moves' then
    for _,row in ipairs(snapshot.party or {}) do if type(row.display)~='table' then needs=true;break end end
  end
  local event=snapshot.presentation
  if event and needsRow(event.subject) then needs=true end
  -- A complete producer needs no fallback, copy or native-party lookup.
  if not needs then return snapshot end
  local out=shallow(snapshot);local data=game and game.data
  local native=C.nativeParty(game,battle)
  out.slots={}
  for i,row in ipairs(snapshot.slots or {}) do
    local mon=row.side=='player' and match(native,row.partyIndex,row) or nil
    out.slots[i]=enrichRow(row,mon,data)
  end
  if page=='party' or page=='item-party' or page=='item-moves' then
    out.party={}
    for i,row in ipairs(snapshot.party or {}) do
      out.party[i]=row
      if type(row.display)~='table' then
        local slot
        for _,r in ipairs(snapshot.slots or {}) do
          if r.side=='player' and not r.empty and r.partyIndex==row.index then slot=r;break end
        end
        local mon=match(native,row.index,row)
        if mon and slot and slot.species~=nil and slot.species~=mon.species then mon=nil end
        local d=displayMon(mon)
        if slot and slot.portrait then d=fillPortrait(slot.portrait,d) end
        -- The original party index and controller legality flags remain intact.
        -- Supply the native Party renderer's detached detail fields only.
        if mon then
          local details=displayMon(mon)
          for _,key in ipairs(monFields) do if d[key]==nil then d[key]=details[key] end end
          d.stats=details.stats;d.moves=details.moves
        end
        d.species=row.species or (slot and slot.species) or d.species
        d.nickname=row.name or d.nickname;d.level=row.level or d.level
        d.hp=row.hp;d.maxHp=row.maxHP;d.maxHP=row.maxHP
        d.stats=d.stats or {};d.stats.hp=row.maxHP;d.moves=d.moves or {}
        d.isEgg=not not row.egg
        if slot then d.status=slot.status
        elseif row.status~=nil then d.status=row.status end
        d.types=slot and slot.types or types(mon or d,data,d.species)
        local r=shallow(row);r.display=d;out.party[i]=r
      end
    end
  end
  if event and event.subject and needsRow(event.subject) then
    local subject=event.subject;local mon
    -- An outgoing event must not borrow the incoming occupant's XP, even for
    -- two identical species. Only a matching actor token permits enrichment.
    for _,row in ipairs(snapshot.slots or {}) do
      if row.side=='player' and row.battlerId~=nil and row.battlerId==subject.battlerId and row.id==subject.id then
        mon=match(native,row.partyIndex,subject);break
      end
    end
    out.presentation=shallow(event);out.presentation.subject=enrichRow(subject,mon,data)
  end
  return out
end
return C
