-- Offline engine-boundary regression harness. This is not a substitute for live DCS validation.
local root = arg[1] or '.'
local mode = arg[2] or 'typescript'
local duration = tonumber(arg[3]) or 310
-- Optional 4th arg: root of a checked-out lua baseline tree (one containing Scripts/ee-dcs).
-- Only consulted by mode=='lua'. It lets the golden fixtures be regenerated from the pinned
-- pre-deletion commit extracted into a scratch directory, without restoring that tree into
-- the repository working copy.
local lua_root = arg[4] or root
local now, next_id = 100, 1000
local logs, timers, groups, statics, handlers, marks = {}, {}, {}, {}, {}, {}

-- ORDER LOG -------------------------------------------------------------------------------
-- The name/tick comparison in run-tests.cjs is blind to WHERE a group is sent: it only sees
-- that a group named X exists. A bug that changes a destination waypoint, a task parameter,
-- or a unit's type/offset produces an identical name SET and an identical tick count and
-- passes silently (proven by the `numericSuffix` LuaMultiReturn bug, which collapsed every
-- artillery/secondary lateral slot onto -2 while this suite stayed green).
--
-- `orders` is the ordered, duplicate-preserving record of every order the campaign issues at
-- the engine boundary: coalition.addGroup, coalition.addStaticObject, and
-- Controller:setTask / :pushTask. Being a LIST it also captures CALL MULTIPLICITY — two
-- spawns under one name are two entries here but a single entry in the name set.
local orders = {}
local function round(v)
    if type(v) ~= 'number' then return v end
    -- Quantise to 1 mm. Lua and typescript-to-lua can evaluate the same formula with a
    -- different association order, giving ~1e-9 relative float noise; at theatre coordinates
    -- (1e5 m) that is ~1e-4 m. 1 mm sits far below any meaningful order change (the smallest
    -- real lateral slot step is 1500 m) and far above that noise floor.
    return math.floor(v * 1000 + 0.5) / 1000
end
-- Canonical, bounded projection of a DCS route: the fields that decide WHERE a group goes and
-- HOW it gets there. Cosmetic fields (point name, ETA_locked, formation_template) are
-- deliberately omitted to keep the fixture reviewable; `type`/`action`/`airdromeId`/
-- `helipadId` are kept because the hot-ramp-start guardrail in CLAUDE.md turns on them.
local function route_points(route)
    if type(route) ~= 'table' or type(route.points) ~= 'table' then return nil end
    local out = {}
    for i, p in ipairs(route.points) do
        out[i] = {type=p.type, action=p.action, x=round(p.x), y=round(p.y),
                  alt=round(p.alt), alt_type=p.alt_type, speed=round(p.speed),
                  airdromeId=p.airdromeId, helipadId=p.helipadId, linkUnit=p.linkUnit}
    end
    return out
end
-- Unit composition: type and PLACEMENT of every unit in the spawned group.
local function unit_composition(units)
    if type(units) ~= 'table' then return nil end
    local out = {}
    for i, u in ipairs(units) do
        out[i] = {type=u.type, x=round(u.x), y=round(u.y),
                  heading=round(u.heading), parking=u.parking, skill=u.skill}
    end
    return out
end
local function record_order(entry) orders[#orders+1] = entry end
-- END ORDER LOG ---------------------------------------------------------------------------
local function new_id() next_id = next_id + 1; return next_id end
local function assert_type(value, expected, label) assert(type(value) == expected, label .. ': expected ' .. expected .. ', got ' .. type(value)) end
local function position(x,z) return {p={x=x,y=20,z=z},x={x=1,y=0,z=0},y={x=0,y=1,z=0},z={x=0,y=0,z=1}} end
local function descriptor(name)
    if name == 'INVALID-UNIT' then return nil end
    local attributes = {['Ground Units']=true}
    if name:match('AH%-') or name:match('Mi%-') or name:match('UH%-') then attributes={Helicopters=true}
    elseif name:match('F%-') or name:match('Su%-') or name:match('C%-') or name:match('An%-') or name:match('IL%-') then attributes={Planes=true}
    elseif name:match('Hawk') or name:match('55G6') or name:match('SAM') then attributes={['Air Defence']=true,SAM=true} end
    return {typeName=name, category=0, attributes=attributes}
end
local function object(name, x,z,side,kind)
    local o={name=name,id=new_id(),x=x,z=z,side=side,alive=true,life=100,kind=kind or 'M-1 Abrams'}
    function o:getName() assert(self==o); return self.name end
    function o:getID() assert(self==o); return self.id end
    function o:isExist() assert(self==o); return self.alive end
    function o:getLife() assert(self==o); return self.life end
    function o:getPosition() assert(self==o); return position(self.x,self.z) end
    function o:getPoint() assert(self==o); return self:getPosition().p end
    function o:getCoalition() assert(self==o); return self.side end
    function o:getTypeName() assert(self==o); return self.kind end
    function o:getDesc() assert(self==o); return descriptor(self.kind) end
    function o:getCategory() assert(self==o); return 1 end
    function o:getPlayerName() assert(self==o); return nil end
    function o:destroy() assert(self==o); self.alive=false; self.life=0 end
    function o:inAir() assert(self==o); return false end
    return o
end
-- Projects a DCS task table down to the parameters that decide WHAT the group is ordered to
-- do. `id` plus the route destination covers movement orders; `params.task`/`expend`/
-- `groupId`/`unitId`/`altitude`/`speed`/`pattern`/`point` cover engage/orbit/attack orders.
-- Unrecognised params are reduced to a sorted key list so a change in SHAPE is still visible
-- without dumping unbounded nested data into the fixture.
local function task_shape(task)
    if type(task)~='table' then return {id=tostring(task)} end
    local p = type(task.params)=='table' and task.params or {}
    local keys={}
    for k in pairs(p) do if type(k)=='string' then keys[#keys+1]=k end end
    table.sort(keys)
    local point = type(p.point)=='table' and {x=round(p.point.x),y=round(p.point.y)} or nil
    return {
        id=task.id,
        route=route_points(p.route),
        task=type(p.task)=='table' and p.task.id or p.task,
        groupId=p.groupId, unitId=p.unitId, targetTypes=p.targetTypes,
        altitude=round(p.altitude), speed=round(p.speed), pattern=p.pattern,
        expend=p.expend, weaponType=p.weaponType, attackQty=p.attackQty,
        point=point, param_keys=keys,
    }
end
local function controller(owner)
    local c={owner=owner}
    function c:setTask(task)
        assert(self==c); assert_type(task,'table','setTask')
        record_order({call='setTask',group=self.owner,task=task_shape(task)})
        self.task=task
    end
    function c:pushTask(task)
        assert(self==c); assert_type(task,'table','pushTask')
        record_order({call='pushTask',group=self.owner,task=task_shape(task)})
    end
    function c:resetTask() assert(self==c) end
    function c:setCommand() assert(self==c) end
    function c:setOption() assert(self==c) end
    return c
end
coalition={side={BLUE=2,RED=1,NEUTRAL=0}}
Group={Category={AIRPLANE=0,HELICOPTER=1,GROUND=2,SHIP=3,TRAIN=4},getByName=function(name) assert_type(name,'string','Group.getByName'); local g=groups[name]; return g and g.alive and g or nil end}
Unit={getDescByName=function(name) assert_type(name,'string','Unit.getDescByName'); return descriptor(name) end,getByName=function(name) for _,g in pairs(groups) do for _,u in ipairs(g.units) do if u.name==name then return u end end end end}
StaticObject={getByName=function(name) assert_type(name,'string','StaticObject.getByName'); local s=statics[name]; return s and s.alive and s or nil end}
Object={Category={UNIT=1,WEAPON=2,STATIC=3,BASE=4,SCENERY=5,CARGO=6}}
Airbase={Category={AIRDROME=0,HELIPAD=1,SHIP=2}}
country={id={USA=2,RUSSIA=0,CJTF_BLUE=80,CJTF_RED=81}}
local bases={}
for i,spec in ipairs({{'Blue Rear',-90000,0,2},{'Blue Front',-30000,10000,2},{'Red Front',30000,0,1},{'Red Rear',90000,10000,1}}) do
    local ab=object(spec[1],spec[2],spec[3],spec[4]); ab.id=i
    function ab:getDesc() return {category=0} end
    function ab:getWarehouse() return {getInventory=function() return {aircraft={}} end} end
    bases[#bases+1]=ab
end
function Airbase.getByName(name) assert_type(name,'string','Airbase.getByName'); for _,ab in ipairs(bases) do if ab.name==name then return ab end end end
function coalition.getAirbases(side) assert_type(side,'number','getAirbases'); local out={}; for _,ab in ipairs(bases) do if ab.side==side then out[#out+1]=ab end end; return out end
function coalition.getGroups(side,cat) assert_type(side,'number','getGroups'); local out={}; for _,g in pairs(groups) do if g.alive and g.side==side and (cat==nil or cat==g.category) then out[#out+1]=g end end; return out end
function coalition.getPlayers(side) assert_type(side,'number','getPlayers'); return {} end
function coalition.getStaticObjects(side) assert_type(side,'number','getStaticObjects'); local out={}; for _,s in pairs(statics) do if s.alive and s.side==side then out[#out+1]=s end end; return out end
function coalition.addGroup(cid,category,data)
    assert_type(cid,'number','addGroup country'); assert_type(category,'number','addGroup category'); assert_type(data,'table','addGroup data')
    record_order({call='addGroup',group=data.name,country=cid,category=category,
                  x=round(data.x),y=round(data.y),task=data.task,
                  units=unit_composition(data.units),route=route_points(data.route),
                  airdromeId=data.airdromeId})
    local side=(cid==2 or cid==80) and 2 or 1; local g={name=data.name,id=new_id(),side=side,category=category,alive=true,units={},controller=controller(data.name),data=data}
    for _,ud in ipairs(data.units) do local u=object(ud.name,ud.x,ud.y,side,ud.type); function u:getGroup() assert(self==u); return g end; g.units[#g.units+1]=u end
    function g:getName() assert(self==g); return self.name end
    function g:getID() assert(self==g); return self.id end
    function g:isExist() assert(self==g); return self.alive end
    function g:getUnits() assert(self==g); return self.units end
    function g:getUnit(i) assert(self==g); return self.units[i] end
    function g:getSize() assert(self==g); return #self.units end
    function g:getInitialSize() assert(self==g); return #self.units end
    function g:getCategory() assert(self==g); return self.category end
    function g:getCoalition() assert(self==g); return self.side end
    function g:getController() assert(self==g); return self.controller end
    function g:destroy() assert(self==g); self.alive=false; for _,u in ipairs(self.units) do u:destroy() end end
    groups[g.name]=g; return g
end
function coalition.addStaticObject(cid,data) assert_type(cid,'number','addStatic country'); assert_type(data,'table','addStatic data')
    record_order({call='addStatic',group=data.name,country=cid,type=data.type,
                  x=round(data.x),y=round(data.y),heading=round(data.heading),
                  category=data.category,shape_name=data.shape_name})
    local s=object(data.name,data.x,data.y,(cid==2 or cid==80) and 2 or 1,data.type); statics[s.name]=s; return s end
land={SurfaceType={LAND=1,SHALLOW_WATER=2,WATER=3,ROAD=4,RUNWAY=5},getHeight=function(p) assert_type(p,'table','getHeight'); return 20 end,getSurfaceType=function(p) assert_type(p,'table','getSurfaceType'); return 1 end}
env={mission={triggers={zones={}},coalitions={blue={80},red={81},neutrals={0,2}}},info=function(msg) assert_type(msg,'string','env.info'); logs[#logs+1]=msg end}
trigger={action={}}
for _,name in ipairs({'outText','outTextForCoalition','outTextForGroup','lineToAll','textToAll','circleToAll'}) do trigger.action[name]=function(...) end end
function trigger.action.removeMark(id) assert_type(id,'number','removeMark'); marks[id]=nil end
function trigger.action.markToAll(id,text,pos) assert_type(id,'number','markToAll'); marks[id]=text end
function trigger.action.markToCoalition(id,text,pos) assert_type(id,'number','markToCoalition'); marks[id]=text end
world={event={S_EVENT_SHOT=1,S_EVENT_HIT=2,S_EVENT_TAKEOFF=3,S_EVENT_LAND=4,S_EVENT_CRASH=5,S_EVENT_EJECTION=6,S_EVENT_DEAD=8,S_EVENT_BIRTH=15,S_EVENT_KILL=28},VolumeType={SPHERE=2}}
function world.addEventHandler(h) assert_type(h,'table','addEventHandler'); assert_type(h.onEvent,'function','onEvent'); handlers[h]=true end
function world.removeEventHandler(h) assert_type(h,'table','removeEventHandler'); handlers[h]=nil end
function world.searchObjects(category,volume,handler) assert_type(category,'number','search category'); assert_type(volume,'table','search volume'); assert_type(handler,'function','search handler') end
function world.getMarkPanels() return {} end
function world.getAirbases() return bases end
missionCommands={}
for _,name in ipairs({'addSubMenuForGroup','addSubMenuForCoalition','addCommandForGroup','addCommandForCoalition','removeItemForGroup'}) do missionCommands[name]=function(...) return {'Campaign'} end end
timer={getTime=function() return now end,scheduleFunction=function(fn,arg,time) assert_type(fn,'function','schedule fn'); assert_type(time,'number','schedule time'); timers[#timers+1]={fn=fn,arg=arg,time=time}; return #timers end}
local mission_require
local function inject()
    if mode=='lua' then
        for key in pairs(package.loaded) do if package.loaded[key] and key~='_G' and key~='package' and key~='string' and key~='table' and key~='math' and key~='io' and key~='os' and key~='debug' and key~='coroutine' then package.loaded[key]=nil end end
        package.path=lua_root..'/Scripts/ee-dcs/?.lua;'..package.path
        local result=dofile(lua_root..'/Scripts/ee-dcs/main.lua'); mission_require=require; return result
    end
    local file=assert(io.open(root..'/dist/ee-dcs.lua','rb')); local text=file:read('*a'); file:close()
    text=text:gsub('return ____entry%s*$', 'return ____entry, require')
    local result,loader=assert(loadstring(text,'@'..root..'/dist/ee-dcs.lua'))(); mission_require=loader; return result
end
local function run_until(stop)
    local ticks=0
    while true do
        local best
        for i,t in ipairs(timers) do if t.time and t.time<=stop and (not best or t.time<timers[best].time) then best=i end end
        if not best then break end
        local t=timers[best]; now=t.time; t.time=nil
        local ok,result=pcall(t.fn,t.arg,now)
        if not ok then error('timer at '..now..': '..tostring(result)) end
        t.time=result; ticks=ticks+1; assert(ticks<20000,'timer did not advance')
    end
    now=stop; return ticks
end
local protected_errors={}
local native_pcall=pcall
local function pack(...) return {n=select("#",...),...} end
pcall=function(fn,...) local results=pack(native_pcall(fn,...)); if results[1]==false then protected_errors[#protected_errors+1]=tostring(results[2]); print("PROTECTED ERROR: "..tostring(results[2])) end; return unpack(results,1,results.n) end
math.randomseed(42)
local ok,result=xpcall(inject,debug.traceback)
if not ok then for _,line in ipairs(logs) do print(line) end; error(result) end

-- TASK CREATION COUNTS --------------------------------------------------------------------
-- Orders and names only become visible once a task ASSIGNS and a group SPAWNS. A generator
-- that produces nothing at all is therefore invisible to both: the orphaned tasks simply
-- expire. That is exactly how 12 `string.match` LuaMultiReturn defects left the SEAD and BAI
-- generators permanently dead in the typescript port while this suite stayed green.
--
-- Counting task_board.create_task by task TYPE closes that hole: a silently dead generator
-- drops its type's count to zero and the comparison in run-tests.cjs turns red.
--
-- Both trees call the board through a module-table lookup (`board.create_task({...})`), so a
-- single wrapper on the shared module table intercepts every generator in either tree. It is
-- installed after inject() (which only SCHEDULES timers) and before run_until, so no task
-- creation can escape it.
local task_creations={}
local board_module=mission_require('task_board')
assert(type(board_module)=='table' and type(board_module.create_task)=='function',
    'order harness: task_board.create_task is not interceptable — the per-type task-creation '..
    'counts would silently record nothing, which is the very failure mode they exist to catch')
local inner_create_task=board_module.create_task
board_module.create_task=function(spec)
    local task_type=(type(spec)=='table' and spec.type) or 'UNTYPED'
    task_creations[task_type]=(task_creations[task_type] or 0)+1
    return inner_create_task(spec)
end

local ticks=run_until(now+duration)
local marks_before_reset=0; for _ in pairs(marks) do marks_before_reset=marks_before_reset+1 end
local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
local function sorted_names(t)
    local out={}
    for name in pairs(t) do out[#out+1]=name end
    table.sort(out)
    return out
end
-- Snapshot the campaign's own spawn state immediately after the timer-driven
-- run, before any test-harness-only fixtures (FARP regression, neutral-enum
-- regression, Deferred-Test/Human-Test/Author-Structure probes) mutate the
-- shared groups/statics registries or consume next_id. This keeps the
-- lua-vs-typescript differential summary (SUMMARY_JSON, printed at the end)
-- limited to campaign behaviour, not test-harness artefacts.
local campaign_groups=count(groups)
local campaign_statics=count(statics)
local campaign_group_names=sorted_names(groups)
local campaign_static_names=sorted_names(statics)
-- Same cut for the order log and the task-creation counts: everything recorded from here on
-- is a test-harness fixture (FARP regression, deferred-task probe, neutral-enum probe,
-- re-injection), not campaign behaviour, and must not leak into the differential.
local campaign_orders={}
for i=1,#orders do campaign_orders[i]=orders[i] end
local campaign_task_creations={}
for task_type,n in pairs(task_creations) do campaign_task_creations[task_type]=n end

-- GENERATOR LIVENESS ----------------------------------------------------------------------
-- The per-type counts above only catch a generator that was ALIVE in the golden recording
-- going dead. SEAD and BAI create zero tasks in the toy 4-base theatre at both smoke
-- durations for a legitimate reason: both are fog-of-war gated (FOW_THRESHOLD_SEAD 0.25,
-- FOW_THRESHOLD_BAI 0.5, cas_bai_sead.ts:125-126) and the theatre never accumulates enough
-- recognition, so they correctly fall back to recon. A zero there proves nothing.
--
-- This fixture removes that excuse. It raises fog of war over every base to maximum, then
-- runs the SEAD, BAI and CAS generators once each and requires every one of them to create
-- at least one task of its own type. With the generators healthy each produces a strike
-- task; with the `string.match` LuaMultiReturn defect that killed them, groupFlag() classes
-- every ground group PRIMARY, so aaTargets() returns nothing and no group is ever in the
-- 'second' echelon — SEAD and BAI then create literally zero tasks and this turns red while
-- the spawned-name set and tick count stay identical.
--
-- Runs after the campaign snapshot cut above, so it never contaminates the differential.
-- Fixture failures are COLLECTED, not raised on the spot, and reported at the very end after
-- SUMMARY_JSON has been printed. One run then shows every fixture that failed AND lets
-- run-tests.cjs still diff the order log, instead of the first assert hiding the rest.
local fixture_failures={}
local function fixture_check(condition, message)
    if not condition then fixture_failures[#fixture_failures+1]=message end
    return condition
end

local liveness={}
task_creations=liveness
local FOW_MAX=4.0*3600  -- fog_of_war.ts:27
local liveness_state=mission_require('campaign_state').S
for base_name in pairs(liveness_state.base_owner) do
    liveness_state.fow[base_name]=liveness_state.fow[base_name] or {}
    liveness_state.fow[base_name][coalition.side.BLUE]=FOW_MAX
    liveness_state.fow[base_name][coalition.side.RED]=FOW_MAX
end
local cbs=mission_require('cas_bai_sead')
for _,side in ipairs({coalition.side.BLUE,coalition.side.RED}) do
    cbs.schedule_sead(side,0,function() end)
    cbs.schedule_bai(side,0,function() end)
    cbs.schedule_cas(side,0,function() end)
end
run_until(now+2)  -- generators use MIN_SCHEDULER_DELAY_SECONDS=1; one pass each, no re-fire
for _,task_type in ipairs({'sead','bai','cas'}) do
    fixture_check((liveness[task_type] or 0)>0,
        'generator liveness: the '..task_type..' generator created ZERO tasks with fog of war '..
        'saturated and valid targets present — it is silently dead')
end
task_creations={}
-- END GENERATOR LIVENESS ------------------------------------------------------------------

-- DEPLOYMENT DISPERSION -------------------------------------------------------------------
-- Targeted regression for the defect that motivated the order log: `numericSuffix()` in
-- ground_forces read `string.match()` without destructuring, so TSTL handed it a table, it
-- returned 0 for every group, and every artillery battery and secondary group took lateral
-- slot (0 % 5) - 2 = -2. Co-located groups heading for the same objective then converged on
-- ONE deployment point instead of spreading across the five-slot standoff ring.
--
-- Names, tick counts and even per-type task counts are all identical either way, which is
-- why the suite stayed green through the bug. This fixture is the direct probe: two groups
-- with the SAME initial position and the SAME objective, differing only in the numeric
-- suffix that selects their slot. Their deployment waypoints must be separated by exactly
-- the slot delta times the slot spacing. With the bug both slots are -2 and the separation
-- is 0, so both assertions below fail.
local DEPLOY_SLOT_COUNT, DEPLOY_SLOT_CENTRE = 5, 2   -- ground_forces.ts:67-68
local ARTY_SLOT_SPACING, SEC_SLOT_SPACING = 2000, 1500 -- ground_forces.ts:65-66
local function slot_of(id) return (id % DEPLOY_SLOT_COUNT) - DEPLOY_SLOT_CENTRE end
-- 9001 -> slot -1, 9003 -> slot +1: two DIFFERENT, non-adjacent slots either side of centre,
-- so a collapse to a single slot is unambiguous rather than an off-by-one.
local SLOT_A_ID, SLOT_B_ID = 9001, 9003
local ground=mission_require('ground_forces')
local dispersion_side=coalition.side.BLUE

local function place_probe_group(name, x, z, unit_type)
    return __dmt_real_addGroup(country.id.CJTF_BLUE, Group.Category.GROUND,
        {name=name, units={{name=name..'-1', type=unit_type, x=x, y=z}}})
end
-- Deployment waypoint = the LAST route point of the move order issued to `name`.
local function last_deploy_point(name, from_index)
    local found
    for i=from_index,#orders do
        local o=orders[i]
        if o.call=='setTask' and o.group==name and o.task and o.task.route then
            found=o.task.route[#o.task.route]
        end
    end
    return found
end
local function assert_dispersed(kind, name_a, name_b, spacing, from_index)
    local a=last_deploy_point(name_a, from_index)
    local b=last_deploy_point(name_b, from_index)
    if not fixture_check(a and b,
        'deployment dispersion: '..kind..' probes were never issued a move order '..
        '(fixture setup problem, not a port regression)') then return end
    local expected=math.abs(slot_of(SLOT_A_ID)-slot_of(SLOT_B_ID))*spacing
    local actual=math.sqrt((a.x-b.x)^2+(a.y-b.y)^2)
    fixture_check(math.abs(actual-expected)<1,
        string.format('deployment dispersion: co-located %s groups with the same objective '..
            'deployed %.1f m apart, expected %.1f m (slots %+d and %+d, %d m spacing). '..
            'A separation of 0 means numericSuffix() returned 0 for both and every group '..
            'collapsed onto slot -2.',
            kind, actual, expected, slot_of(SLOT_A_ID), slot_of(SLOT_B_ID), spacing))
end

-- ARTILLERY: two batteries co-located deep in blue rear. Nearest enemy base is Red Front at
-- (30000,0), well beyond ARTY_STANDOFF, so both advance to the same standoff ring.
local arty_a='Arty-2-'..SLOT_A_ID
local arty_b='Arty-2-'..SLOT_B_ID
local arty_from=#orders+1
liveness_state.arty_groups[dispersion_side][arty_a]=
    {grp=place_probe_group(arty_a,-50000,0,'M-109'), home_base='Blue Rear'}
liveness_state.arty_groups[dispersion_side][arty_b]=
    {grp=place_probe_group(arty_b,-50000,0,'M-109'), home_base='Blue Rear'}

-- SECONDARY: two second-echelon groups co-located next to the same blue frontline base, so
-- both resolve the same `behind_base` and the same rear vector.
local sec_a='GndSec-2-'..SLOT_A_ID
local sec_b='GndSec-2-'..SLOT_B_ID
liveness_state.sec_groups[dispersion_side][sec_a]=
    {grp=place_probe_group(sec_a,-31000,10000,'M-1 Abrams'), home_base='Blue Front', want=1}
liveness_state.sec_groups[dispersion_side][sec_b]=
    {grp=place_probe_group(sec_b,-31000,10000,'M-1 Abrams'), home_base='Blue Front', want=1}

ground.schedule_ground(dispersion_side,0,function() end)
run_until(now+1)
assert_dispersed('artillery', arty_a, arty_b, ARTY_SLOT_SPACING, arty_from)
assert_dispersed('secondary', sec_a, sec_b, SEC_SLOT_SPACING, arty_from)
-- END DEPLOYMENT DISPERSION ---------------------------------------------------------------
local zones=mission_require('zones')
env.mission.triggers.zones={{name='Scenery Enum Test',type=0,x=0,y=0,radius=100}}
zones.load()
local scenery_probe=object('Scenery-Enum-Probe',0,0,0,'Warehouse')
local searched_category
world.searchObjects=function(category,volume,handler)
    searched_category=category
    assert(category==Object.Category.SCENERY,'scenery search used the wrong DCS Object.Category enum')
    handler(scenery_probe)
end
local scenery_matches=zones.scenery_in_zone('Scenery Enum Test')
assert(searched_category==Object.Category.SCENERY,'scenery search did not use Object.Category.SCENERY')
assert(#scenery_matches==1 and scenery_matches[1].id=='Scenery-Enum-Probe','scenery search failed to return the matching resource')
local persistence=mission_require('persist')
local config=mission_require('config')
local state=mission_require('campaign_state').S
if mode=='typescript' then
    env.mission.triggers.zones={{name='farp_Authored Regression',type=0,x=12345,y=67890,radius=500,color={0,0,1,1}}}
    zones.load()
    local farp_name='FARP-Authored-Regression'
    state.base_kind[farp_name]='farp'
    state.base_owner[farp_name]=coalition.side.BLUE
    state.base_pos[farp_name]={x=12345,z=67890}
    state.base_health[farp_name]=1
    mission_require('farps').init(function() end)
    local queued
    for _,item in ipairs(state.spawn_queue) do if item.kind=='static' and item.name==farp_name then queued=item end end
    assert(queued~=nil,'authored FARP zone did not queue a physical heliport')
    assert(queued.country==country.id.CJTF_BLUE,'authored FARP used the wrong coalition country')
    assert(queued.data.type=='FARP' and queued.data.shape_name=='FARPS' and queued.data.category=='Heliports','authored FARP did not use the stock four-slot DCS FARP/FARPS heliport')
    assert(queued.data.heliport_frequency=='127.5' and queued.data.heliport_modulation==0 and queued.data.heliport_callsign_id==1,'authored FARP omitted the Mission Editor heliport defaults')
    assert(queued.data.x==12345 and queued.data.y==67890,'authored FARP static was not placed at the zone centre')

    -- DCS MissionEditor/modules/me_exportToMiz.lua:895-944: stock FARPs use
    -- helipadId/linkUnit and distinct parking names 1..4, never airdromeId.
    local farp_airbase=object(farp_name,12345,67890,coalition.side.BLUE,'FARP')
    farp_airbase.id=7654
    function farp_airbase:getDesc() return {category=Airbase.Category.HELIPAD} end
    bases[#bases+1]=farp_airbase
    local farp_group=mission_require('heli_war').build_attack_heli(
        coalition.side.BLUE,farp_name,{x=22345,z=67890},'anti_armour',function() end)
    assert(farp_group~=nil,'multi-helicopter FARP regression group did not spawn')
    local farp_spec,farp_queue_index
    for index,item in ipairs(state.spawn_queue) do
        if item.kind=='group' and item.name==farp_group:getName() then farp_spec=item.data; farp_queue_index=index; break end
    end
    assert(farp_spec~=nil,'multi-helicopter FARP group was not queued')
    local farp_depart=farp_spec.route.points[1]
    assert(farp_spec.airdromeId==nil,'FARP group incorrectly used group airdromeId')
    assert(farp_depart.type=='TakeOffParking' and farp_depart.action=='From Parking Area','FARP departure did not use parking takeoff')
    assert(farp_depart.helipadId==7654 and farp_depart.linkUnit==7654 and farp_depart.airdromeId==nil,'FARP departure did not link to its heliport object')
    assert(farp_spec.x==12345 and farp_spec.y==67890 and farp_depart.x==12345 and farp_depart.y==67890,'FARP group and departure were not moved to the heliport origin')
    assert(#farp_spec.units==2,'FARP regression did not exercise a helicopter section')
    for index,unit in ipairs(farp_spec.units) do
        assert(unit.parking==tostring(index) and unit.parking_id==tostring(index),'FARP helicopters did not receive distinct stock parking slots')
        assert(unit.x==12345 and unit.y==67890,'FARP helicopter retained an incompatible formation offset')
        assert(index<=4,'FARP group exceeded the stock four-slot capacity')
    end
    local second_farp_group=mission_require('heli_war').build_attack_heli(
        coalition.side.BLUE,farp_name,{x=22345,z=68890},'anti_armour',function() end)
    assert(second_farp_group~=nil,'second FARP section did not spawn')
    local second_farp_spec,second_farp_queue_index
    for index,item in ipairs(state.spawn_queue) do
        if item.kind=='group' and item.name==second_farp_group:getName() then second_farp_spec=item.data; second_farp_queue_index=index; break end
    end
    assert(second_farp_spec~=nil,'second FARP section was not queued')
    assert(second_farp_spec.units[1].parking=='3' and second_farp_spec.units[2].parking=='4','successive FARP sections did not rotate onto the remaining parking slots')
    table.remove(state.spawn_queue,second_farp_queue_index)
    mission_require('map_overlay').remove_task_arrow(second_farp_group:getName())
    table.remove(state.spawn_queue,farp_queue_index)
    mission_require('map_overlay').remove_task_arrow(farp_group:getName())

    local runway_group=mission_require('heli_war').build_attack_heli(
        coalition.side.BLUE,'Blue Rear',{x=-80000,z=0},'anti_armour',function() end)
    assert(runway_group~=nil,'airbase helicopter control group did not spawn')
    local runway_spec,runway_queue_index
    for index,item in ipairs(state.spawn_queue) do
        if item.kind=='group' and item.name==runway_group:getName() then runway_spec=item.data; runway_queue_index=index; break end
    end
    assert(runway_spec~=nil,'airbase helicopter control group was not queued')
    local runway_depart=runway_spec.route.points[1]
    assert(runway_spec.airdromeId==1 and runway_depart.airdromeId==1,'real airbase helicopter departure lost airdromeId')
    assert(runway_depart.helipadId==nil and runway_spec.units[1].parking==nil,'real airbase was incorrectly encoded as a FARP')
    table.remove(state.spawn_queue,runway_queue_index)
    mission_require('map_overlay').remove_task_arrow(runway_group:getName())

    local pilots=mission_require('pilots')
    state.base_owner['Intel-Known']=coalition.side.RED
    state.base_owner['Intel-Hidden']=coalition.side.RED
    state.base_pos['Intel-Known']={x=1000,z=1000}
    state.base_pos['Intel-Hidden']={x=2000,z=2000}
    state.fow['Intel-Known']={[coalition.side.BLUE]=3600}
    state.fow['Intel-Hidden']={[coalition.side.BLUE]=1}
    state.base_ledger['Blue Front']={striker=3,escort=2,heli=4,recon=1,transport=1,vehicle=6}
    state.base_ammo['Blue Front']=80
    state.base_fuel['Blue Front']=70
    state.production[coalition.side.BLUE]={ammo=20,fuel=10,ammo_rr=0,fuel_rr=0,ammo_earmark=1,fuel_earmark=0}
    state.regen_queue[coalition.side.BLUE]={heli={{base_name='Blue Front',aircraft_type='AH-64D',enqueued=0}}}
    state.board_tasks={{id=999,type='cas',side=coalition.side.BLUE,target={base='Intel-Known'},count=1,builder=function() end,log_fn=function() end,origin='test',priority=5,critical=true,created_t=0,expiry_t=100,state='UNASSIGNED',dedup_key='board:999',exclude_target_base=false}}
    state.active_tasks['CAS-Test']={task_type='cas',side=coalition.side.BLUE,target_base='Intel-Known'}
    local intelligence=pilots.intelligence_report(coalition.side.BLUE)
    assert(intelligence:match('Intel%-Known'),'intelligence report omitted a recognised enemy contact')
    assert(not intelligence:match('Intel%-Hidden'),'intelligence report leaked an unrecognised enemy contact')
    assert(pilots.tasking_report(coalition.side.BLUE):match('CAS'),'tasking report omitted friendly queued/active tasking')
    assert(pilots.logistics_report(coalition.side.BLUE):match('Blue Front: A80 F70'),'logistics report omitted friendly base supply')
end
state.keysites['Scenery-Save-Test']={kind='depot',pos={x=0,z=0},health=1,flags={ground_strike_target=true,recon_target=true},assets={},dead={},scenery={{id=42,type='Warehouse',handle=object('Scenery-42',0,0,2),dead=false}}}
local before=persistence.snapshot()
local blob=persistence._ser(before)
local decoded,decode_error=persistence._deser(blob)
assert(type(decoded)=='table' and decoded.version==1,'persistence roundtrip: '..tostring(decode_error))
assert(decoded.data.base_owner['Blue Front']==2,'numeric coalition keys lost'); assert(decoded.data.keysites['Scenery-Save-Test'].scenery[1].id==42,'numeric scenery id lost')
assert(decoded.data.strength[coalition.side.BLUE]~=nil and decoded.data.regen_queue[coalition.side.RED]~=nil,'numeric map keys lost')
local saved_blob
local db={}
function db:exec(sql,args) if sql:match('INSERT') then saved_blob=args[4] end end
function db:query(sql,args) return saved_blob and {{blob=saved_blob,version=1,saved_t=now}} or {} end
function db:close() end
dcs_studio={sqlite={open=function(path) return db end}}
config.C.persistence.enabled=true
assert(persistence.save(),'persistence save failed')
if mode=='typescript' then
    local valid_saved_blob=saved_blob
    local corrupt=persistence.snapshot()
    corrupt.data.base_owner['Blue Front']=coalition.side.NEUTRAL
    saved_blob=persistence._ser(corrupt)
    assert(not persistence.restore_data(function() end),'persistence accepted a neutral combat-side owner')
    saved_blob=valid_saved_blob
end
local old_start=state.start_time
now=now+100
assert(persistence.restore_data(),'persistence data restore failed')
assert(state.start_time==old_start+100,'saved elapsed time did not rebase')
config.C.persistence.enabled=false
local queue=mission_require('spawn_queue')
local original_lookup=Group.getByName
Group.getByName=function(name) if name=='Deferred-Test' then return nil end; return original_lookup(name) end
local proxy=coalition.addGroup(2,2,{name='Deferred-Test',units={{name='Deferred-Test-1',type='M-1 Abrams',x=0,y=0}}})
assert(proxy.__queued==true,'queued proxy flag lost')
local deferred={id='Mission',params={}}
proxy:getController():setTask(deferred)
while #state.spawn_queue>0 do queue.drain() end
assert(groups['Deferred-Test'].controller.task==deferred,'deferred task lost while registry lookup lags')
Group.getByName=original_lookup
local player_group=__dmt_real_addGroup(2,0,{name='Human-Test',units={{name='Human-Test-1',type='F-15C',x=0,y=0}}})
player_group.units[1].getPlayerName=function() return 'Human Pilot' end
local author_static=__dmt_real_addStatic(2,{name='Author-Structure',type='Warehouse',x=0,y=0})
for _,event_id in ipairs({world.event.S_EVENT_BIRTH,world.event.S_EVENT_LAND,world.event.S_EVENT_DEAD}) do
  for handler in pairs(handlers) do
    local ok,err=pcall(handler.onEvent,handler,{id=event_id,initiator=author_static})
    assert(ok,'static event '..event_id..' reached a unit-only handler: '..tostring(err))
  end
end
if mode=='typescript' then
    local neutral_group=__dmt_real_addGroup(80,0,{name='Strike-Neutral-Enum-Test',units={{name='Strike-Neutral-Enum-Test-1',type='F-15C',x=0,y=0}}})
    neutral_group.side=coalition.side.NEUTRAL
    neutral_group.units[1].side=coalition.side.NEUTRAL
    local regen_before=0
    for _,by_role in pairs(state.regen_queue) do for _,entries in pairs(by_role) do regen_before=regen_before+#entries end end
    for handler in pairs(handlers) do handler:onEvent({id=world.event.S_EVENT_DEAD,initiator=neutral_group.units[1]}) end
    local regen_after=0
    for _,by_role in pairs(state.regen_queue) do for _,entries in pairs(by_role) do regen_after=regen_after+#entries end end
    assert(regen_after==regen_before,'neutral unit was assigned to a combat-side regen queue')
end
local generation=_DMT_GEN
local old_timers={}; for _,t in ipairs(timers) do old_timers[#old_timers+1]=t end
inject(); assert(_DMT_GEN==generation+1,'reinjection generation did not increment'); assert(player_group.alive,'reset destroyed a human player group'); assert(author_static.alive,'reset destroyed an author static')
for _,t in ipairs(old_timers) do if t.time then assert(t.fn(t.arg,t.time)==nil,'stale timer survived reinjection') end end
local errors={}; for _,line in ipairs(logs) do if line:match('tick error') or line:match('FMT%-ERR') or line:match('THREW') or line:match('builder FAILED') or line:match('restore: deserialize FAILED') then errors[#errors+1]=line end end
for _,line in ipairs(errors) do print(line) end
assert(#errors==0,'campaign swallowed '..#errors..' runtime errors'); assert(#protected_errors==0,'protected calls hid '..#protected_errors..' errors')
assert(ticks>0,'no periodic timers fired'); assert(count(groups)>0,'no groups spawned'); assert(marks_before_reset>0,'no overlay marks')
print(string.format('PASS %s: %d timer ticks; %d groups; %d statics; %d handlers; %d logs; reinjection cancels old timers',mode,ticks,count(groups),count(statics),count(handlers),#logs))

-- Structured summary for the lua-vs-typescript differential harness (run-tests.cjs).
-- Names (not just counts) are emitted so the harness can report exactly which
-- spawned group/static diverged between the two trees. Uses the campaign_*
-- snapshot captured right after run_until, not the live groups/statics
-- tables, so test-harness-only fixtures below never leak into the diff.
local function json_string(s)
    return '"'..tostring(s):gsub('\\','\\\\'):gsub('"','\\"')..'"'
end
local function json_string_array(list)
    local parts={}
    for _,s in ipairs(list) do parts[#parts+1]=json_string(s) end
    return '['..table.concat(parts,',')..']'
end
-- Deterministic JSON for the order log. Object keys are emitted in sorted order and nil-valued
-- fields are omitted, so the same world state always serialises to the same bytes regardless of
-- Lua's pairs() iteration order — otherwise the fixture would be flaky rather than a net.
local function json_number(n)
    if n ~= n or n == math.huge or n == -math.huge then
        error('order log: non-finite number cannot be recorded deterministically')
    end
    if n == math.floor(n) and math.abs(n) < 1e15 then return string.format('%d', n) end
    return string.format('%.6f', n)
end
local json_value
local function json_array(list)
    local parts={}
    for i=1,#list do parts[#parts+1]=json_value(list[i]) end
    return '['..table.concat(parts,',')..']'
end
local function json_object(t)
    local keys={}
    for k in pairs(t) do keys[#keys+1]=k end
    table.sort(keys)
    local parts={}
    for _,k in ipairs(keys) do parts[#parts+1]=json_string(k)..':'..json_value(t[k]) end
    return '{'..table.concat(parts,',')..'}'
end
json_value=function(v)
    local t=type(v)
    if v==nil then return 'null' end
    if t=='boolean' then return tostring(v) end
    if t=='number' then return json_number(v) end
    if t=='string' then return json_string(v) end
    if t=='table' then
        if #v>0 then return json_array(v) end
        if next(v)==nil then return '{}' end
        return json_object(v)
    end
    error('order log: cannot serialize a '..t..' — orders must be plain data')
end

-- Call multiplicity per spawn name: repeated spawns under one name are one entry in
-- `group_names` but N here, so a duplicate-spawn regression is detectable.
local spawn_call_counts={}
for _,entry in ipairs(campaign_orders) do
    if entry.call=='addGroup' or entry.call=='addStatic' then
        local key=entry.call..':'..tostring(entry.group)
        spawn_call_counts[key]=(spawn_call_counts[key] or 0)+1
    end
end

print(string.format(
    'SUMMARY_JSON {"mode":%s,"duration":%d,"ticks":%d,"groups":%d,"statics":%d,"group_names":%s,"static_names":%s,'..
    '"orders":%s,"spawn_call_counts":%s,"task_creations":%s,"generator_liveness":%s}',
    json_string(mode), duration, ticks, campaign_groups, campaign_statics,
    json_string_array(campaign_group_names), json_string_array(campaign_static_names),
    json_array(campaign_orders), json_object(spawn_call_counts), json_object(campaign_task_creations),
    json_object(liveness)
))

-- Reported last, on purpose: SUMMARY_JSON above is already on stdout, so run-tests.cjs can
-- still diff the order log and show WHICH waypoints moved alongside these fixture failures.
if #fixture_failures>0 then
    for _,message in ipairs(fixture_failures) do print('FIXTURE FAILED: '..message) end
    error(#fixture_failures..' campaign-smoke fixture(s) failed in mode '..mode, 0)
end








