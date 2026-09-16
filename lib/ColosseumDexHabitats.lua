-- Read-only habitat projection of the SAME additive encounter pools used in play.
-- Intersect candidate level/time rules with the loaded host's real native slots:
-- a planned route with no successful native encounter must not claim a spawn.
local V=... or {}
local E=assert(V.ExpandedWildEncounters,"ExpandedWildEncounters required")
local H={version=2}
local req=V.engineRequire or require
local cache=setmetatable({}, {__mode="k"})
local TIMES={"MORN","DAY","NITE"}
local function generation(game,opts)
  return tonumber(opts and opts.generation) or ((game and game.data and game.data.gen2Pokedex) and 2)
    or tonumber(game and game.save and game.save.generation) or 1
end
local function allowed(row,tod)
  return not row.times or row.times[tod]==true
end
local function slotsRange(slots,row,tod,enc)
  local lo,hi
  for _,raw in ipairs(slots or {}) do
    if type(raw)=="table" then
      local key=tod=="NITE" and "nite" or "day"
      local group=raw.timeGroup and enc and enc.timeFishGroups and enc.timeFishGroups[raw.timeGroup]
      local s=raw[key] or (group and group[key]) or raw
      local level=tonumber(s.level)
      if s.species and s.species~=0 and s.species~="NO_ITEM" and level
          and level>=(row.minLevel or 1) and level<=(row.maxLevel or 100) then
        lo=math.min(lo or level,level);hi=math.max(hi or level,level)
      end
    end
  end
  return lo,hi
end
local function name(data,map,gen)
  local def=(gen==2 and data.gen2Maps or data.maps) or data.maps or {}
  def=def[map]
  return type(def)=="table" and (def.name or def.label or def.displayName) or map
end
local function selectedMode(game)
  local p=game.save and game.save.colosseumBattle
  return p and p.wildSpawnMode=="new_only" and "new_only" or "mixed"
end
-- NEW ONLY can fill an unplanned map/method (or a level/time gap) with a
-- checked coverage pool. Project actual native slots through the same selector
-- rather than listing every map or claiming an unavailable scripted encounter.
local function buildNewOnly(game,gen)
  local data=game.data or {}
  local enc=gen==2 and data.gen2Encounters or data.encounters
  if type(enc)~="table" then return nil,"host encounter tables unavailable" end
  local out={};local maps=gen==2 and (data.gen2Maps or data.maps) or data.maps
  maps=maps or {}
  local function add(map,kind,label,tod,slots,native)
    for _,raw in ipairs(slots or {}) do
      if type(raw)=="table" then
        local key=tod=="NITE" and "nite" or "day"
        local group=raw.timeGroup and enc.timeFishGroups and enc.timeFishGroups[raw.timeGroup]
        local slot=raw[key] or (group and group[key]) or raw
        local level=tonumber(slot.level)
        if slot.species and slot.species~=0 and slot.species~="NO_ITEM" and level then
          local rows,source=E.candidateRows(gen,slot,{mapId=map,kind=kind,daytime=tod,data=data},{mode="new_only"})
          for _,r in ipairs(rows) do
            if (tonumber(r.weight) or 0)>0 then
              local list=out[r.species] or {};out[r.species]=list
              -- Keep fallback-only results distinct from authored results: their
              -- levels and conditional label must not be merged misleadingly.
              local fallback=source~="planned"
              local token=map.."|"..label.."|"..tostring(fallback)
              local x=list[token]
              if not x then
                x={map=map,area=name(data,map,gen),kind=kind,method=label,
                  minLevel=level,maxLevel=level,times={},source="ExpandedWildEncounters",
                  nativeTable=native,coverage=fallback,mode=fallback and "new_only" or nil}
                list[token]=x;list[#list+1]=x
              end
              x.minLevel=math.min(x.minLevel,level);x.maxLevel=math.max(x.maxLevel,level);x.times[tod]=true
            end
          end
        end
      end
    end
  end
  if gen==1 then
    local fishMaps={}
    for map,n in pairs(enc) do
      if type(n)=="table" then
        for kind,field in pairs({land="grass",surf="water"}) do
          local row=n[field]
          if row and (tonumber(row.rate) or 0)>0 then
            add(map,kind,kind=="surf" and "SURF" or "GRASS","DAY",row.slots,"encounters")
            if kind=="surf" then fishMaps[map]=true end
          end
        end
      end
    end
    local ok,F=pcall(req,"src.world.FieldDefaults")
    local fishing=ok and F and type(F.field)=="function" and F.field(data,"fishing") or (data.field or {}).fishing
    for map in pairs(E.plan(gen).fishing) do fishMaps[map]=true end
    -- Per-map fishing groups are explicit evidence of rod access; do not infer
    -- that every ordinary map has fishable water just because Good Rod is global.
    for _,rod in ipairs({"GOOD_ROD","SUPER_ROD"}) do
      local f=fishing and fishing[rod]
      local perMap=f and f.perMap and data.field and data.field[f.perMap]
      for map in pairs(perMap or {}) do fishMaps[map]=true end
    end
    for map in pairs(fishMaps) do
      for _,rod in ipairs({"GOOD_ROD","SUPER_ROD"}) do
        local f=fishing and fishing[rod]
        local slots=f and (f.pool or (f.perMap and data.field and data.field[f.perMap] and data.field[f.perMap][map]))
        if f and f.always then slots={f.always} end
        add(map,"fishing",rod:gsub("_"," "),"DAY",slots,"field.fishing")
      end
    end
  else
    for _,entry in ipairs({{"grass","land"},{"swarmGrass","land"},{"water","surf"},{"swarmWater","surf"}}) do
      local bucket,kind=entry[1],entry[2]
      for map,n in pairs(enc[bucket] or {}) do
        for _,tod in ipairs(TIMES) do
          local rate=kind=="surf" and n.rate or (n.rates and (n.rates[tod] or n.rates.DAY))
          if (tonumber(rate) or 0)>0 then
            local slots=kind=="surf" and n.slots or (n.slots and (n.slots[tod] or n.slots.DAY))
            add(map,kind,(bucket:match("^swarm") and "SWARM " or "")..(kind=="surf" and "SURF" or "GRASS"),tod,slots,bucket)
          end
        end
      end
    end
    for map,def in pairs(maps) do
      local base=type(def)=="table" and def.fishGroup
      if type(base)=="string" and base~="FISHGROUP_NONE" then
        for _,id in ipairs({base,base.."_SWARM"}) do
          local fish=enc.fishGroups and enc.fishGroups[id]
          if fish and (fish.chance==nil or (tonumber(fish.chance) or 0)>0) then
            for _,rod in ipairs({"good","super"}) do
              for _,tod in ipairs(TIMES) do
                add(map,"fishing",(id~=base and "SWARM " or "")..rod:upper().." ROD",tod,fish[rod],"fishGroups")
              end
            end
          end
        end
      end
    end
  end
  for _,list in pairs(out) do
    for _,r in ipairs(list) do
      local times={};for _,t in ipairs(TIMES) do if r.times[t] then times[#times+1]=t end end
      r.timeLabel=gen==2 and #times<3 and table.concat(times,"/") or nil
      r.levelLabel=r.minLevel==r.maxLevel and ("LV "..r.minLevel) or ("LV "..r.minLevel.."-"..r.maxLevel)
      r.method=r.method.."  "..r.levelLabel..(r.timeLabel and ("  "..r.timeLabel) or "")
        ..(r.coverage and "  DEX ONLY" or "")
    end
    table.sort(list,function(a,b)if a.map==b.map then return a.method<b.method end;return a.map<b.map end)
  end
  return out
end
local function build(game,gen,mode)
  if mode=="new_only" then return buildNewOnly(game,gen) end
  local data=game.data or {}
  local plan=E.plan(gen)
  local enc=gen==2 and data.gen2Encounters or data.encounters
  if type(enc)~="table" then return nil,"host encounter tables unavailable" end
  local bySpecies={}
  local function add(map,kind,row,label,tod,slots,native)
    if not allowed(row,tod) then return end
    local lo,hi=slotsRange(slots,row,tod,enc)
    if not lo then return end
    local list=bySpecies[row.species] or {};bySpecies[row.species]=list
    local token=map.."|"..label
    local x=list[token]
    if not x then
      x={map=map,area=name(data,map,gen),kind=kind,method=label,
        minLevel=lo,maxLevel=hi,times={},source="ExpandedWildEncounters",nativeTable=native}
      list[token]=x;list[#list+1]=x
    end
    x.minLevel=math.min(x.minLevel,lo);x.maxLevel=math.max(x.maxLevel,hi)
    x.times[tod]=true
  end
  local fishingDefaults
  if gen==1 then
    local ok,F=pcall(req,"src.world.FieldDefaults")
    fishingDefaults=ok and F and type(F.field)=="function" and F.field(data,"fishing") or (data.field or {}).fishing
  end
  for _,kind in ipairs({"land","surf","fishing"}) do
    for map,area in pairs(plan[kind] or {}) do
      for _,row in ipairs(area.rows or {}) do
        if (tonumber(row.weight) or 0)>0 then
          if gen==1 then
            if kind=="fishing" then
              for _,rod in ipairs({"GOOD_ROD","SUPER_ROD"}) do
                local f=fishingDefaults and fishingDefaults[rod]
                local slots=f and (f.pool or (f.perMap and data.field and data.field[f.perMap] and data.field[f.perMap][map]))
                if f and f.always then slots={f.always} end
                add(map,kind,row,rod:gsub("_"," "),"DAY",slots,"field.fishing")
              end
            else
              local n=enc[map] and enc[map][kind=="surf" and "water" or "grass"]
              if n and (tonumber(n.rate) or 0)>0 then
                add(map,kind,row,kind=="surf" and "SURF" or "GRASS","DAY",n.slots,"encounters")
              end
            end
          elseif kind=="fishing" then
            local m=(data.gen2Maps or data.maps or {})[map]
            local base=m and m.fishGroup or "FISHGROUP_POND"
            -- Swarm rows are conditional, never presented as the ordinary pool.
            for _,g in ipairs({base,base.."_SWARM"}) do
              local fish=enc.fishGroups and enc.fishGroups[g]
              for _,rod in ipairs({"good","super"}) do
                for _,tod in ipairs(TIMES) do
                  add(map,kind,row,(g~=base and "SWARM " or "")..rod:upper().." ROD",tod,fish and fish[rod],"fishGroups")
                end
              end
            end
          else
            local buckets=kind=="surf" and {"water","swarmWater"} or {"grass","swarmGrass"}
            for _,bucket in ipairs(buckets) do
              local n=enc[bucket] and enc[bucket][map]
              for _,tod in ipairs(TIMES) do
                local rate=n and (kind=="surf" and n.rate or (n.rates and (n.rates[tod] or n.rates.DAY)))
                if n and (tonumber(rate) or 0)>0 then
                  local slots=kind=="surf" and n.slots or (n.slots and (n.slots[tod] or n.slots.DAY))
                  local label=(bucket:match("^swarm") and "SWARM " or "")..(kind=="surf" and "SURF" or "GRASS")
                  add(map,kind,row,label,tod,slots,bucket)
                end
              end
            end
          end
        end
      end
    end
  end
  for _,rows in pairs(bySpecies) do
    for _,row in ipairs(rows) do
      local tod={};for _,t in ipairs(TIMES) do if row.times[t] then tod[#tod+1]=t end end
      row.timeLabel=gen==2 and #tod<3 and table.concat(tod,"/") or nil
      row.levelLabel=row.minLevel==row.maxLevel and ("LV "..row.minLevel) or ("LV "..row.minLevel.."-"..row.maxLevel)
      row.method=row.method.."  "..row.levelLabel..(row.timeLabel and ("  "..row.timeLabel) or "")
    end
    table.sort(rows,function(a,b) if a.map==b.map then return a.method<b.method end;return a.map<b.map end)
  end
  return bySpecies
end
function H.locations(game,species,opts)
  if not (game and type(game.data)=="table") then return nil,"game data unavailable" end
  local data=game.data;local gen=generation(game,opts);local mode=selectedMode(game)
  local enc=gen==2 and data.gen2Encounters or data.encounters
  local maps=gen==2 and data.gen2Maps or data.maps
  local key=cache[data]
  if not key or key.generation~=gen or key.mode~=mode or key.pokemon~=data.pokemon or key.enc~=enc or key.maps~=maps or key.field~=data.field then
    local all,why=build(game,gen,mode)
    if not all then return nil,why end
    key={generation=gen,mode=mode,pokemon=data.pokemon,enc=enc,maps=maps,field=data.field,all=all};cache[data]=key
  end
  local out={}
  for _,row in ipairs(key.all[species] or {}) do
    local copy={};for k,v in pairs(row) do
      if type(v)=="table" then local t={};for a,b in pairs(v)do t[a]=b end;copy[k]=t else copy[k]=v end
    end
    out[#out+1]=copy
  end
  return out
end
return H
