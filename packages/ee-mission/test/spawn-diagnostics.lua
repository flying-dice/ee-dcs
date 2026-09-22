-- Engine-boundary fault injection. Does not simulate DCS parking or prove takeoff.
local root = arg[1] or '.'
local file = assert(io.open(root .. '/dist/ee-dcs.lua', 'rb'))
local bundle = file:read('*a'); file:close()
local replaced
bundle, replaced = bundle:gsub('local ____entry = require%("index", %.%.%.%)%s+return ____entry', 'return require')
assert(replaced == 1)

local function runtime(outcome, debug_enabled)
    local e = setmetatable({}, {__index=_G}); e._G=e; e._DMT_DEBUG=debug_enabled
    local now, logs, timers, handlers, units, groups = 0, {}, {}, {}, {}, {}
    local calls = 0
    local function log(message) logs[#logs+1]=message end
    e.env={info=log}
    e.coalition={side={BLUE=2,RED=1,NEUTRAL=0}}
    e.Group={Category={AIRPLANE=0,HELICOPTER=1,GROUND=2},getByName=function(name) return groups[name] end}
    e.Unit={getByName=function(name) return units[name] end}
    e.StaticObject={getByName=function() return nil end}
    e.Airbase={Category={HELIPAD=1},getByName=function() return nil end}
    e.land={getHeight=function() return 20 end}
    e.world={event={S_EVENT_BIRTH=15,S_EVENT_TAKEOFF=3,S_EVENT_DEAD=8,S_EVENT_CRASH=5}}
    e.world.addEventHandler=function(h) handlers[h]=true end
    e.world.removeEventHandler=function(h) handlers[h]=nil end
    e.timer={getTime=function() return now end,scheduleFunction=function(fn,arg,time) timers[#timers+1]={fn=fn,arg=arg,time=time} end}
    local function event(id, unit)
        for h in pairs(handlers) do h:onEvent({id=id,initiator=unit}) end
    end
    local function materialise(name)
        local unit={alive=true,active=true,air=false}
        function unit:getName() return name end
        function unit:isExist() return self.alive end
        function unit:isActive() return self.active end
        function unit:getLife() return self.alive and 100 or 0 end
        function unit:inAir() return self.air end
        function unit:getPoint() return {x=100,y=25,z=200} end
        function unit:getDesc() return {attributes={Helicopters=true,['Attack helicopters']=true}} end
        units[name]=unit
        event(15,unit)
        return unit
    end
    e.coalition.addGroup=function(_, _, data)
        calls=calls+1
        if outcome=='threw' then error('injected addGroup failure') end
        if outcome=='nil' then return nil end
        local group={}
        function group:isExist() return true end
        function group:getSize()
            local count=0
            for _,u in ipairs(data.units) do if units[u.name] and units[u.name].alive then count=count+1 end end
            return count
        end
        groups[data.name]=group
        if outcome=='full' or outcome=='partial' then materialise(data.units[1].name) end
        if outcome=='full' then materialise(data.units[2].name) end
        return group
    end
    e.coalition.addStaticObject=function() return nil end
    local require_module=setfenv(assert(loadstring(bundle)),e)()
    local queue=require_module('spawn_queue')
    local state=require_module('campaign_state').S
    local function advance(t)
        while true do
            local best
            for i,v in ipairs(timers) do if v.time and v.time<=t and (not best or v.time<timers[best].time) then best=i end end
            if not best then break end
            local v=timers[best]; now=v.time; v.time=v.fn(v.arg,now)
        end
        now=t
    end
    local function contains(text)
        for _,line in ipairs(logs) do if line:find(text,1,true) then return true end end
        return false
    end
    local function spawn()
        e.coalition.addGroup(81,1,{name='test',units={{name='test-1',type='Mi-24V',x=100,y=200},{name='test-2',type='Mi-24V',x=100,y=200}},route={points={{x=100,y=200,type='TakeOffParkingHot',action='From Parking Area Hot',helipadId=77,linkUnit=77}}}})
        assert(queue.drain(log)==1)
    end
    return {e=e,state=state,queue=queue,logs=logs,timers=timers,handlers=handlers,units=units,spawn=spawn,advance=advance,contains=contains,event=event,materialise=materialise,calls=function() return calls end,require_module=require_module}
end

for _,outcome in ipairs({'threw','nil','empty','partial','full'}) do
    local r=runtime(outcome,true)
    r.spawn()
    assert(r.contains('phase=submitted') and r.contains('type=TakeOffParkingHot'))
    assert(r.contains('outcome='..(outcome=='threw' and 'threw' or outcome=='nil' and 'nil' or 'returned')))
    if outcome=='partial' then assert(r.contains('group_size=1') and r.contains('unit=test-2 present=false')) end
    if outcome=='empty' then assert(r.contains('group_size=0') and r.contains('unit=test-1 present=false')) end
    if outcome=='full' then
        assert(r.contains('phase=event id=15'),'birth during addGroup was missed')
        assert(r.contains('group_size=2') and r.contains('agl=5'))
        assert(r.contains('active=true'),'activation was not distinguished from existence')
        r.units['test-1'].air=true; r.event(3,r.units['test-1'])
        r.advance(1)
        assert(r.contains('in_air=true') and r.contains('phase=event id=3'))
        r.units['test-1'].alive=false; r.event(8,r.units['test-1'])
        r.event(5,r.units['test-2'])
        assert(r.contains('phase=event id=8') and r.contains('phase=event id=5'))
    end
    r.advance(120)
    for _,elapsed in ipairs({0,1,5,30,120}) do assert(r.contains('phase=sample elapsed='..elapsed..' ')) end
    assert(next(r.handlers)==nil,'observer leaked after final sample')
    assert(r.calls()==1 and #r.state.spawn_queue==0,'diagnostics retried a spawn')
    assert(r.contains('phase=observation_complete'))
end

local delayed=runtime('empty',true)
delayed.spawn(); delayed.materialise('test-1'); delayed.advance(1)
assert(delayed.contains('unit=test-1 present=true'))
delayed.units['test-1']=nil; delayed.advance(5)
assert(delayed.contains('unit=test-1 present=false'))
delayed.e.Unit.getByName=function() error('lookup failed') end
delayed.advance(30)
assert(delayed.contains('lookup=QUERY_ERROR('))
delayed.advance(120)
assert(next(delayed.handlers)==nil)

local broken=runtime('full',true)
broken.e.Airbase.getByName=function() error('airbase unavailable') end
broken.state.base_pos.FARP={x=100,z=200}
broken.spawn()
assert(broken.contains('base=FARP lookup=QUERY_ERROR(') and broken.calls()==1)
broken.units['test-1'].getLife=function() error('stale handle') end
broken.units['test-1'].isActive=function() error('activation query failed') end
broken.advance(1)
assert(broken.contains('life=QUERY_ERROR(') and broken.contains('active=QUERY_ERROR(') and broken.contains('unit=test-2 present=true'))
broken.e._DMT_GEN=broken.e._DMT_GEN+1
local log_count=#broken.logs
broken.event(3,broken.units['test-1']); broken.advance(120)
assert(#broken.logs==log_count and next(broken.handlers)==nil,'stale generation emitted diagnostics')

local quiet=runtime('full',false)
quiet.spawn()
assert(#quiet.timers==0 and next(quiet.handlers)==nil and not quiet.contains('[spawn_probe]'))
local disabled=runtime('full',true)
disabled.spawn(); disabled.e._DMT_DEBUG=false; disabled.advance(120)
assert(next(disabled.handlers)==nil)

local inactive=runtime('full',true)
inactive.spawn()
inactive.units['test-1'].active=false
inactive.advance(1)
assert(inactive.contains('unit=test-1 present=true exists=true active=false'), 'inactive unit was not distinguished from absence or a query error')

local parking=runtime('full',true)
parking.state.base_pos.FARP={x=100,z=200}
parking.e.Airbase.getByName=function()
    return {
        getID=function() return 77 end,
        getDesc=function() return {category=1} end,
        getCoalition=function() return 1 end,
        getPosition=function() return {p={x=100,y=20,z=200}} end,
        getParking=function(_,available)
            if available then error('free parking unsupported') end
            return {{Term_Index=1,Term_Type=40,vTerminalPos={x=101,y=20,z=201},TO_AC=false}}
        end,
    }
end
parking.e.StaticObject.getByName=function() return {getID=function() return 99 end} end
parking.spawn()
assert(parking.contains('base=FARP id=77 category=1 coalition=1 static_id=99'))
assert(parking.contains('parking=1:40:101,20,201:TO_AC=false'))
assert(parking.contains('parking_available_only=true parking=QUERY_ERROR('))
assert(parking.calls()==1,'parking query failure prevented submission')

local observer_failure=runtime('full',true)
observer_failure.e.world.addEventHandler=function() error('registration failed') end
observer_failure.spawn(); observer_failure.advance(120)
assert(observer_failure.calls()==1 and observer_failure.contains('phase=diagnostic_error'))
assert(observer_failure.contains('phase=sample elapsed=120'))

local scheduling_failure=runtime('full',true)
scheduling_failure.e.timer.scheduleFunction=function() error('scheduling failed') end
scheduling_failure.spawn()
assert(scheduling_failure.calls()==1 and next(scheduling_failure.handlers)==nil)

-- The shared FARP adapter preserves explicit cold and hot choices for both types.
local r=runtime('full',false)
local adapter=r.require_module('farp_parking')
r.state.base_kind.FARP='farp'
local base={getID=function() return 77 end,getDesc=function() return {category=1} end,getPosition=function() return {p={x=100,y=20,z=200}} end}
for _,aircraft in ipairs({'Mi-24V','AH-64D'}) do
    for _,hot in ipairs({false,true}) do
        local p={x=0,y=0,type=hot and 'TakeOffParkingHot' or 'TakeOffParking',action='stale',airdromeId=77}
        local data={name='adapter',units={{name='a',type=aircraft,x=0,y=0}}}
        adapter.configureDeparture('FARP',base,data,p)
        assert(p.type==(hot and 'TakeOffParkingHot' or 'TakeOffParking'))
        assert(p.action==(hot and 'From Parking Area Hot' or 'From Parking Area'))
        assert(p.helipadId==77 and p.linkUnit==77 and p.airdromeId==nil)
    end
end
print('PASS spawn diagnostics: API failures, empty/partial/delayed/disappearing units, events, query failures, sampling, cleanup, generations, debug gating and hot/cold FARP departures')
