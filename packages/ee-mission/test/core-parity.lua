-- Core parity checks for the campaign port; run from repository root.
--
-- Each `check` runs one scenario twice and demands identical results. The reference side is:
--   * the preserved Lua baseline in Scripts/ee-dcs, while that tree still exists; or
--   * the committed golden fixture test/golden/core-parity-baseline.lua once it is deleted.
-- The fixture is a frozen recording of the Lua baseline's own answers, so these checks keep
-- their value after the Lua tree is removed instead of silently disappearing.
--
-- Re-record the fixture (only meaningful while Scripts/ee-dcs exists, and only when a change
-- to the BASELINE is intended):  lua core-parity.lua <repo-root> --emit-golden
local root = arg[1] or '.'
local emit_golden = arg[2] == '--emit-golden'
local golden_path = root .. '/packages/ee-mission/test/golden/core-parity-baseline.lua'
local function file_exists(path) local f = io.open(path, 'r'); if f then f:close(); return true end; return false end
local HAVE_BASELINE = file_exists(root .. '/Scripts/ee-dcs/config.lua')
local GOLDEN
if not HAVE_BASELINE then
    assert(file_exists(golden_path),
        'Scripts/ee-dcs is absent and there is no golden fixture at ' .. golden_path)
    GOLDEN = assert(loadfile(golden_path))()
    print('SKIP lua baseline leg: Scripts/ee-dcs is not present.')
    print('     core-parity is asserting the typescript build against the recorded baseline in')
    print('     test/golden/core-parity-baseline.lua instead.')
end
local file = assert(io.open(root .. '/dist/ee-dcs.lua', 'rb'))
local bundle = file:read('*a'); file:close()
local replaced
bundle, replaced = bundle:gsub('local ____entry = require%("index", %.%.%.%)%s+return ____entry', 'return require')
assert(replaced == 1, 'bundle entry not found')
local function runtime(port, override)
    local e = setmetatable({}, {__index=_G}); e._G=e; e.DMT_CONFIG=override
    e.coalition={side={BLUE=2,RED=1,NEUTRAL=0},getGroups=function() return {} end}
    e.country={id={USA=2,RUSSIA=0,CJTF_BLUE=80,CJTF_RED=81}}
    e.Group={Category={AIRPLANE=0,HELICOPTER=1,GROUND=2,SHIP=3}}
    e.Object={Category={STATIC=3}}
    e.env={info=function() end}; e.trigger={action={outText=function() end}}
    e.Unit={getDescByName=function(name) if name=='INVALID' then return nil end; return {attributes={Planes=true}} end}
    e.now=0; e.timers={}
    e.timer={getTime=function() return e.now end,scheduleFunction=function(fn,a,t) e.timers[#e.timers+1]={fn,a,t} end}
    e.land={SurfaceType={LAND=1,ROAD=4,RUNWAY=5},getSurfaceType=function() return 1 end,getHeight=function(p) return math.abs(math.sin(p.x/10000)*math.cos(p.y/8000))*500 end}
    local cache={}
    if port then e.require=setfenv(assert(loadstring(bundle)),e)()
    else e.require=function(name) if not cache[name] then cache[name]=setfenv(assert(loadfile(root..'/Scripts/ee-dcs/'..name..'.lua')),e)() end; return cache[name] end end
    return e
end
local function equal(a,b,path)
    path=path or 'value'
    if type(a)~=type(b) then error(path..': baseline='..tostring(a)..' TS='..tostring(b)) end
    if type(a)=='table' then
        for k,v in pairs(a) do equal(v,b[k],path..'.'..tostring(k)) end
        for k in pairs(b) do assert(a[k]~=nil,path..': TS extra key '..tostring(k)) end
    elseif type(a)=='number' then assert(math.abs(a-b)<1e-8,path..': baseline='..a..' TS='..b)
    else assert(a==b,path..': baseline='..tostring(a)..' TS='..tostring(b)) end
end
-- Deterministic Lua literal serializer for the golden fixture: keys are emitted in a stable
-- order (numbers ascending, then strings alphabetically) so re-recording produces a reviewable
-- diff rather than a reshuffle. Only plain data is expected; anything else is a hard error so a
-- non-recordable check can never be silently dropped from the fixture.
local function serialize(value,indent)
    indent=indent or '  '
    local t=type(value)
    if t=='nil' or t=='boolean' then return tostring(value) end
    if t=='number' then return string.format('%.17g',value) end
    if t=='string' then return string.format('%q',value) end
    if t~='table' then error('core-parity golden: cannot serialize a '..t) end
    local nums,strs={},{}
    for k in pairs(value) do
        if type(k)=='number' then nums[#nums+1]=k
        elseif type(k)=='string' then strs[#strs+1]=k
        else error('core-parity golden: unsupported key type '..type(k)) end
    end
    table.sort(nums); table.sort(strs)
    local parts,inner={},indent..'  '
    for _,k in ipairs(nums) do parts[#parts+1]=inner..'['..string.format('%.17g',k)..'] = '..serialize(value[k],inner) end
    for _,k in ipairs(strs) do parts[#parts+1]=inner..'['..string.format('%q',k)..'] = '..serialize(value[k],inner) end
    if #parts==0 then return '{}' end
    local NL=string.char(10)
    return '{'..NL..table.concat(parts,','..NL)..NL..indent..'}'
end
local failures,checks=0,0
local recorded={}
local function check(name,scenario,override)
    checks=checks+1
    local okb,vb=pcall(scenario,runtime(true,override))
    local oka,va
    if HAVE_BASELINE then
        oka,va=pcall(scenario,runtime(false,override))
        if oka then recorded[#recorded+1]={name=name,value=va} end
    elseif GOLDEN[name]==nil then
        oka,va=false,'no golden entry for check "'..name..'" (re-record the fixture)'
    else
        oka,va=true,GOLDEN[name].value
    end
    local ok,err=pcall(function() assert(oka,'baseline error: '..tostring(va)); assert(okb,'TS error: '..tostring(vb)); equal(va,vb) end)
    if ok then print('PASS '..name) else failures=failures+1; print('FAIL '..name..': '..err) end
end
local function portcheck(name,scenario,override)
    checks=checks+1
    local e=runtime(true,override)
    local ok,err=pcall(scenario,e)
    if ok then print('PASS '..name) else failures=failures+1; print('FAIL '..name..': '..tostring(err)) end
end
-- The preserved Lua baseline combines the four-slot FARP type with the
-- single-helipad shape. The Mission Editor serializes the requested object as
-- FARP/FARPS, so normalize only this audited compatibility correction.
local function normalize_farp_shape(value)
    if value.statics and value.statics.farp then value.statics.farp.shape_name='<verified four-slot FARP shape>' end
    return value
end
check('config defaults',function(e) return normalize_farp_shape(e.require('config').load_and_validate()) end)
portcheck('config Mission Editor FARP shape',function(e)
    local farp=e.require('config').load_and_validate().statics.farp
    assert(farp.type=='FARP' and farp.shape_name=='FARPS','campaign FARP does not match the Mission Editor four-slot object')
    return true
end)
check('config CJTF countries',function(e)
    local countries=e.require('config').load_and_validate().countries
    assert(countries[e.coalition.side.BLUE]==e.country.id.CJTF_BLUE,'BLUE is not CJTF Blue')
    assert(countries[e.coalition.side.RED]==e.country.id.CJTF_RED,'RED is not CJTF Red')
    return true
end)
check('config pylon without num',function(e) return e.require('config').load_and_validate().payloads[2].striker end,{payloads={blue={striker={{CLSID='custom'}}}}})
check('config extra palette token',function(e) return e.require('config').load_and_validate().statics.palette end,{statics={palette={custom={'Custom','shape','Fortifications'}}}})
check('config custom static kind',function(e) return e.require('config').load_and_validate().statics.kinds end,{statics={kinds={bridge={spawn='static',type='Custom',shape='bridge',cat='Fortifications',label='Bridge'}}}})
check('config invalid unit fallback',function(e) return e.require('config').load_and_validate().types.aircraft end,{types={aircraft={blue={striker='INVALID'}}}})
check('neutral kill side',function(e) local cs=e.require('campaign_state'); cs.stat_kill(2,0,'ground'); return cs.S.stats end)
check('static category after failed descriptor',function(e) return e.require('campaign_state').unit_category({getDesc=function() error('stale') end,getCategory=function() return 3 end}) end)
check('task assessment boundaries',function(e) local cs=e.require('campaign_state'); local out={}; for _,v in ipairs({0,0.239,0.24,0.75,0.9,1}) do cs.S.base_health.a=v; out[#out+1]={cs.assess_task({task_type='ground_strike',target_base='a',eff_before=1},'destroyed')} end; return out end)
check('strength empty',function(e) local cs=e.require('campaign_state'); cs.recalc_strength(); return cs.S.strength end)
check('route terrain and side bias',function(e) local cs=e.require('campaign_state'); cs.S.base_pos={a={x=0,z=0},b={x=70000,z=20000}}; cs.S.base_owner={a=2,b=1}; return e.require('croute').biased_route({x=0,z=0},{x=80000,z=30000},2) end)
check('imap scheduled layers',function(e) local cs=e.require('campaign_state'); cs.S.base_pos={a={x=0,z=0},b={x=70000,z=20000}}; cs.S.base_owner={a=2,b=1}; local im=e.require('imap'); im.init(); im.schedule_update(); for _,t in ipairs(e.timers) do t[1](t[2],t[3]) end; return cs.S.imap end)
check('fow decay and ownership',function(e) local cs=e.require('campaign_state'); cs.S.base_owner={a=2,b=1}; cs.S.base_pos={a={x=0,z=0},b={x=10,z=10}}; local f=e.require('fog_of_war'); f.init(); cs.S.fow.b[2]=100; f.schedule_decay(); for _,t in ipairs(e.timers) do t[1](t[2],t[3]) end; return {f.get('a',2),f.get('b',2)} end)
check('zones authored circle and quad',function(e)
    e.env.mission={triggers={zones={
        {name='Factory Circle',x=100,y=200,radius=50,color={0,0,1,1}},
        {name='Depot Quad',type=2,color={1,0,0,1},verticies={{x=0,y=0},{x=20,y=0},{x=20,y=40},{x=0,y=40}}},
        {name='THEATRE',x=0,y=0,radius=1000},
    }}}
    local z=e.require('zones'); local n=z.load(); local ks=z.keysites(); table.sort(ks,function(a,b) return a.label<b.label end)
    return {n,ks,z.has_keysite_zones(),z.exists('FACTORY CIRCLE'),z.contains('Factory Circle',150,200),z.contains('Factory Circle',150.01,200),z.contains('Depot Quad',10,20),z.contains('Depot Quad',21,20)}
end)
check('zones bare and wrapped colors',function(e)
    local z=e.require('zones'); local out={}
    for _,c in ipairs({{0,0,1,1},{1,0,0,1},{0.5,0.5,0.5,1},{[3]=1},{}}) do out[#out+1]={z.side_of_color(c),z.side_of_color({color=c})} end
    return out
end)
check('frontline capture and missing bases',function(e)
    local cs=e.require('campaign_state'); cs.S.base_pos={a={x=0,z=0},b={x=100,z=0},c={x=250,z=0},d={x=400,z=0}}; cs.S.base_owner={a=2,b=2,c=1,d=1}
    local f=e.require('frontline'); f.init_and_build()
    local before={f.get_frontline(2),f.get_frontline(1),f.nearest_enemy('a'),f.nearest_enemy('absent'),f.echelon_of({x=0,z=0}),f.echelon_of({x=100,z=0}),f.echelon_of()}
    cs.S.base_owner.c=2; f.recompute(); return {before,f.get_frontline(2),f.get_frontline(1),f.nearest_enemy('c')}
end)
check('route unavailable terrain and short leg',function(e)
    e.land.getHeight=function() error('terrain unavailable') end
    local r=e.require('croute'); return {r.biased_route({x=0,z=0},{x=4000,z=0},2),r.biased_route({x=0,z=0},{x=80000,z=30000},2),r.expand({{x=0,y=0},{x=80000,y=30000}},2)}
end)
local function overlay(e)
    local events={}; for _,name in ipairs({'removeMark','lineToAll','markToAll','markToCoalition'}) do e.trigger.action[name]=function(...) events[#events+1]={name,...} end end
    e.world={getMarkPanels=function() return {} end}; e.Group.getByName=function() return nil end
    local m=e.require('map_overlay'); return m,events
end
portcheck('overlay coalition task replacement and cleanup',function(e)
    local m,events=overlay(e); m.schedule_overlay(); local a={x=10,z=20}; local b={x=30,z=40}
    local first=m.add_task_arrow('flight',a,b,2); local second=m.add_task_arrow('flight',b,a,1)
    assert(first==20000 and second==20000,'removed task ID was not safely recycled')
    assert(events[1][1]=='lineToAll' and events[1][2]==2 and type(events[1][6])=='table','task line is not coalition-scoped or does not use a DCS color array')
    assert(events[2][1]=='markToCoalition' and events[2][5]==2,'task label is not coalition-scoped')
    e.require('campaign_state').clear_task('flight'); m.remove_task_arrow('flight')
    local removed=0; for _,event in ipairs(events) do if event[1]=='removeMark' then removed=removed+1 end end
    assert(removed>=4,'replacement and completion did not remove both task marks')
end)
portcheck('overlay dead-group garbage collection',function(e)
    local m,events=overlay(e); m.schedule_overlay(function(err) error(err) end); m.add_task_arrow('gone',{x=0,z=0},{x=100,z=100},2)
    local t=e.timers[1]; local nextTime=t[1](t[2],t[3]); assert(nextTime==t[3]+30,'overlay cadence changed')
    local removedLine,removedLabel=false,false
    for _,event in ipairs(events) do
        if event[1]=='removeMark' and event[2]>=20000 and event[2]<=20399 then removedLine=true end
        if event[1]=='removeMark' and event[2]>=20400 and event[2]<=20799 then removedLabel=true end
    end
    assert(removedLine and removedLabel,'dead task did not remove line and label')
end)
portcheck('overlay operational picture ownership content and lifecycle',function(e)
    local m,events=overlay(e); local cs=e.require('campaign_state'); local S=cs.S
    S.base_pos={blue={x=0,z=0},red={x=100000,z=0}}; S.base_owner={blue=2,red=1}
    S.base_health={blue=.8,red=.6}; S.base_kind={blue='airbase',red='farp'}
    S.base_ledger.blue={striker=2,escort=1,heli=4,recon=1,transport=2,vehicle=3}
    S.base_ammo.blue=75; S.base_fuel.blue=50; S.base_inflight.blue=2
    S.objectives={[2]={'red'},[1]={'blue'}}; S.fow={blue={[1]=0,[2]=0},red={[1]=0,[2]=14400}}
    S.strength={[2]=12,[1]=9}
    local alive=true
    local unit={isExist=function() return alive end,getPosition=function() return {p={x=20000,y=0,z=1000}} end}
    local group={isExist=function() return alive end,getUnit=function() return unit end,getUnits=function() return {unit} end,getSize=function() return 3 end,getInitialSize=function() return 4 end}
    S.ground_groups[2].column={grp=group,home_base='blue',target_base='red',want=4}
    S.arty_groups[2].guns={grp=group,home_base='blue'}
    S.sec_groups[1].reserve={grp=group,home_base='red',want=4}
    S.board_tasks={{id=7,type='cas',side=2,target={base='red',pos={x=100000,z=0}},count=1,builder=function() end,log_fn=function() end,origin='test',priority=6,critical=false,created_t=0,expiry_t=1200,state='UNASSIGNED',dedup_key='board:7',exclude_target_base=false}}
    m.schedule_overlay(function(err) error(err) end); local timer=e.timers[1]; timer[1](timer[2],timer[3])
    local sawOwnDetail,sawEnemyRedacted,sawObjective,sawQueue,sawPrimary,sawArty,sawReserve=false,false,false,false,false,false,false
    local flotBySide={[1]=false,[2]=false}
    for _,event in ipairs(events) do
        assert(event[1]~='markToAll','global marker leaked coalition intelligence')
        if event[1]=='markToCoalition' then
            local id,text,side=event[2],event[3],event[5]
            assert(id<3000000,'legacy multiplied marker ID was emitted')
            if side==2 and text:find('blue') and text:find('idle F2') then sawOwnDetail=true end
            if side==1 and text:find('blue') and text:find('INTEL LOW') then sawEnemyRedacted=true end
            if side==2 and text:find('OBJECTIVE 1: red') then sawObjective=true end
            if side==2 and text:find('QUEUED CAS') then sawQueue=true end
            if side==2 and text:find('GROUND COLUMN') then sawPrimary=true end
            if side==2 and text:find('ARTILLERY') then sawArty=true end
            if side==1 and text:find('RESERVE') then sawReserve=true end
        elseif event[1]=='lineToAll' and event[3]>=40000 and event[3]<=40399 then flotBySide[event[2]]=true end
    end
    assert(sawOwnDetail and sawEnemyRedacted,'friendly detail or enemy intelligence filtering missing')
    assert(sawObjective and sawQueue,'objective or queued task marker missing')
    assert(sawPrimary and sawArty and sawReserve,'one or more ground formation classes missing')
    assert(flotBySide[1] and flotBySide[2],'FLOT segments are not coalition scoped')
    local before=#events; alive=false; S.board_tasks={}; timer[1](timer[2],timer[3]+30)
    local removedQueue,removedFormation=false,false
    for i=before+1,#events do local event=events[i]
        if event[1]=='removeMark' and event[2]>=20800 and event[2]<=21199 then removedQueue=true end
        if event[1]=='removeMark' and event[2]>=30000 and event[2]<=31999 then removedFormation=true end
    end
    assert(removedQueue and removedFormation,'desired-vs-rendered reconciliation left stale marks')
end)
portcheck('overlay markup failures log once',function(e)
    local m=overlay(e); local S=e.require('campaign_state').S
    S.base_pos={blue={x=0,z=0}}; S.base_owner={blue=2}; S.base_health={blue=1}; S.base_kind={blue='airbase'}
    e.trigger.action.markToCoalition=function() error('mock markup failure') end
    local reports=0
    m.schedule_overlay(function(message) if message:find('markToCoalition failed') then reports=reports+1 end end)
    local timer=e.timers[1]; timer[1](timer[2],timer[3]); timer[1](timer[2],timer[3]+30)
    assert(reports==1,'repeated markup failures should be reported exactly once')
end)
check('pilot friendly kill and score promotion',function(e)
 e.world={event={S_EVENT_KILL=28}}
 local pilot=e.require('pilots')
 local human={getPlayerName=function() return 'Pilot' end,getCoalition=function() return 2 end}
 local function victim(side) return {getCoalition=function() return side end,getDesc=function() return {attributes={Planes=true}} end} end
 pilot.on_kill({id=28,initiator=human,target=victim(2)})
 for i=1,75 do pilot.on_kill({id=28,initiator=human,target=victim(1)}) end
 return e.require('campaign_state').S.pilots.Pilot
end)
check('pilot debrief medals and partial streak',function(e)
 e.world={event={S_EVENT_HIT=2,S_EVENT_KILL=28}}
 local pilot=e.require('pilots')
 local human={getPlayerName=function() return 'Pilot' end,getCoalition=function() return 2 end,isExist=function() return true end,getGroup=function() return {getID=function() return 1 end} end}
 pilot.on_hit({id=2,target=human})
 for _,result in ipairs({'success','partial','success','success','failure'}) do pilot.on_debrief(human,{task_type='cas'},{result=result}) end
 return e.require('campaign_state').S.pilots.Pilot
end)
for _,override in ipairs({1,true,'bad'}) do check('config non-table override '..tostring(override),function(e) return normalize_farp_shape(e.require('config').load_and_validate()) end,override) end
print(string.format('%d checks, %d failures',checks,failures))
if emit_golden then
    assert(HAVE_BASELINE,'--emit-golden needs the Scripts/ee-dcs lua baseline present')
    assert(failures==0,'refusing to record a golden fixture from a failing run')
    local out={}
    out[#out+1]='-- GOLDEN FIXTURE - recorded answers of the LUA CAMPAIGN BASELINE (Scripts/ee-dcs/*.lua)'
    out[#out+1]='-- for every core-parity `check`, captured at the pre-deletion state of that tree on 2026-09-21.'
    out[#out+1]='-- core-parity.lua asserts the typescript build against these values once the lua tree is'
    out[#out+1]='-- gone. Do not hand-edit: regenerate with'
    out[#out+1]='--   lua packages/ee-mission/test/core-parity.lua <repo-root> --emit-golden'
    out[#out+1]='-- and only when a change to the BASELINE behaviour is intended.'
    out[#out+1]='return {'
    for _,entry in ipairs(recorded) do
        out[#out+1]='  ['..string.format('%q',entry.name)..'] = { value = '..serialize(entry.value,'  ')..' },'
    end
    out[#out+1]='}'
    local f=assert(io.open(golden_path,'wb'))
    local NL=string.char(10)
    f:write(table.concat(out,NL)..NL); f:close()
    print('recorded '..#recorded..' baseline answers -> '..golden_path)
end
if failures>0 then os.exit(1) end


