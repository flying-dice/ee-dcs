-- Focused regression harness for the aircraft-lifecycle defects catalogued for epic #17
-- (docs/bots/CALLER-MAP-aircraft-lifecycle.md, docs/bots/sprints/2026-09-22-sprint-04.md). Runs
-- the REAL transpiled bundle (dist/ee-dcs.lua) through a fake DCS boundary.
--
-- Defects 1 (P1, "submission outcomes + reversible allocation") and 3 (P2, "physical parking
-- leases") are FIXED and this file now asserts the TARGET invariant for each. Defect 2 (P3) is not
-- fixed yet, so it still asserts CURRENT (wrong) behaviour behind the agreed marker pair:
--   -- CURRENT BEHAVIOUR (defect, epic #17 P<n>): <what happens now>
--   -- TARGET: <the invariant this must assert once P<n> lands>
-- so the flip point stays unambiguous when that package fixes it.
--
-- Scope: adapter/accounting contract only (ledger counts, slot reservations, task state, parking
-- position bookkeeping). No DCS flight-physics assertions (no waypoints, no autopilot, no AI
-- decision quality).
local root = arg[1] or '.'
local file = assert(io.open(root .. '/dist/ee-dcs.lua', 'rb'))
local bundle = file:read('*a'); file:close()
local replaced
bundle, replaced = bundle:gsub('local ____entry = require%("index", %.%.%.%)%s+return ____entry', 'return require')
assert(replaced == 1)

-- Shared fake-DCS boundary, modelled on spawn-diagnostics.lua's runtime() (same event ids, same
-- timer/log/handler shape) and extended with: S_EVENT_LAND, coalition.getPlayers (task_board.tick
-- reads it), a settable Airbase registry, the trigger.action surface map_overlay draws through,
-- and an addGroup that can materialise a real group/getUnits()/destroy() OR fail on demand.
-- `opts.outcome` controls what the SIMULATED real coalition.addGroup does once
-- spawn_queue.drain() actually calls it, reusing spawn-diagnostics.lua's fault-injection
-- vocabulary for the same boundary and adding the cases epic #17 P1 has to separate:
--   'ok'               full group, every requested unit present
--   'nil'              API returns nil, nothing created            -> PROVEN failure
--   'threw'            API raises, nothing created                 -> PROVEN failure
--   'birth_then_threw' API raises AFTER an S_EVENT_BIRTH           -> AMBIGUOUS, must not refund
--   'partial'          group returned with one unit missing        -> created, must not refund
--   'delayed'          group returned before any unit materialises -> created, must not refund
-- `opts.group_lookup_error` makes Group.getByName raise, i.e. the query-error case.
-- Each call builds a FRESH sandboxed environment and re-loads the bundle into it, so module-level
-- state (farp_parking's per-base parking-position counter, spawn_queue's captured "real" addGroup,
-- aircraft_lifecycle's attempt registry) resets between scenarios exactly as a fresh
-- mission/re-injection would.
local function runtime(opts)
    if type(opts)=='string' then opts={outcome=opts} end
    opts = opts or {}
    local outcome = opts.outcome or 'ok'
    local e = setmetatable({}, {__index=_G}); e._G=e; e._DMT_DEBUG=(opts.debug ~= false)
    local now, logs, timers, handlers, groups, airbases = 0, {}, {}, {}, {}, {}
    local calls = 0
    -- Unit registry behind Unit.getByName. P3's settlement re-reads every expected airframe by
    -- NAME (the allocation's identity) rather than trusting a group handle, so the fake boundary
    -- has to answer that lookup the way DCS does.
    local units_registry, destroys = {}, {}
    local COALITION_OF_COUNTRY = {[2]=2, [80]=2, [0]=1, [81]=1}
    local function log(message) logs[#logs+1]=message end
    e.env={info=log}
    e.coalition={side={BLUE=2,RED=1,NEUTRAL=0}, getPlayers=function() return {} end}
    e.country={id={USA=2,RUSSIA=0,CJTF_BLUE=80,CJTF_RED=81}}
    e.Group={Category={AIRPLANE=0,HELICOPTER=1,GROUND=2},getByName=function(name)
        if opts.group_lookup_error then error('injected Group.getByName failure') end
        return groups[name]
    end}
    e.Unit={getByName=function(name) return units_registry[name] end,
            getDescByName=function() return {attributes={Planes=true}} end}
    e.StaticObject={getByName=function() return nil end}
    e.Airbase={Category={HELIPAD=1,AIRDROME=0},getByName=function(name) return airbases[name] end}
    e.land={SurfaceType={LAND=1,ROAD=4,RUNWAY=5},getSurfaceType=function() return 1 end,getHeight=function() return 20 end}
    e.trigger={action={}}
    for _,name in ipairs({'outText','outTextForCoalition','outTextForGroup','lineToAll','textToAll',
                          'circleToAll','markToAll','markToCoalition','removeMark','arrowToAll',
                          'quadToAll','markupToAll'}) do
        e.trigger.action[name]=function() end
    end
    -- Event ids MEASURED on the target build (docs/bots/LIVE-PROBE-2026-09-22.md), including the
    -- two runway-contact ids the probe captured: RUNWAY_TOUCH fires for a crash as well as for a
    -- recovery, so it must be inert here exactly as it is in production.
    e.world={event={S_EVENT_BIRTH=15,S_EVENT_TAKEOFF=3,S_EVENT_LAND=4,S_EVENT_DEAD=8,S_EVENT_CRASH=5,
                    S_EVENT_RUNWAY_TAKEOFF=54,S_EVENT_RUNWAY_TOUCH=55}}
    e.world.addEventHandler=function(h) handlers[h]=true end
    e.world.removeEventHandler=function(h) handlers[h]=nil end
    e.world.getMarkPanels=function() return {} end
    e.timer={getTime=function() return now end,scheduleFunction=function(fn,arg,time) timers[#timers+1]={fn=fn,arg=arg,time=time} end}
    -- Fires a world event into every currently registered handler, exactly as DCS would while a
    -- synchronous coalition.addGroup is still on the stack.
    local function fire(id, unit_name)
        local initiator={getName=function() return unit_name end}
        for h in pairs(handlers) do pcall(h.onEvent, h, {id=id, initiator=initiator}) end
    end
    -- The REAL (post spawn_queue interception) addGroup: what actually lands in DCS once
    -- drain() calls it. This is intentionally the ONLY place the outcome is decided — the
    -- proxy returned to callers at enqueue time never sees it.
    -- Builds a live group with addressable UNIT objects: isExist/destroy/getGroup/getCoalition/
    -- getPlayerName, all registered under Unit.getByName. Per-aircraft settlement operates on
    -- units, so a group-only fake could not express the cases it has to separate.
    local function materialise(country, data, visible)
        local group={destroyed=false, visible=visible, unit_objects={}}
        function group:isExist() return not self.destroyed end
        function group:getName() return data.name end
        function group:getUnits()
            local out={}
            for i,unit in ipairs(self.unit_objects) do
                if i<=self.visible and unit.alive then out[#out+1]=unit end
            end
            return out
        end
        function group:destroy()
            self.destroyed=true
            for _,unit in ipairs(self.unit_objects) do unit.alive=false end
        end
        function group:getUnit(index) return self.unit_objects[index] end
        for i,u in ipairs(data.units) do
            local unit={alive=true, player=nil, unit_name=u.name}
            function unit:getName() return self.unit_name end
            function unit:isExist() return self.alive end
            function unit:destroy()
                self.alive=false
                destroys[self.unit_name]=(destroys[self.unit_name] or 0)+1
            end
            function unit:getGroup() return group end
            function unit:getCoalition() return COALITION_OF_COUNTRY[country] or 2 end
            function unit:getPlayerName() return self.player end
            function unit:getPosition() return {p={x=u.x or 0, y=20, z=u.y or 0}} end
            group.unit_objects[i]=unit
            units_registry[u.name]=unit
        end
        groups[data.name]=group
        return group
    end
    e.coalition.addGroup=function(country, _, data)
        calls = calls + 1
        if outcome=='threw' then error('injected addGroup failure') end
        if outcome=='birth_then_threw' then
            fire(e.world.event.S_EVENT_BIRTH, data.units[1].name)
            error('injected addGroup failure AFTER a unit was born')
        end
        if outcome=='nil' then return nil end
        local visible = #data.units
        if outcome=='partial' then visible = #data.units - 1 end
        if outcome=='delayed' then visible = 0 end
        return materialise(country, data, visible)
    end
    e.coalition.addStaticObject=function() return nil end
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
    -- Delivers one real DCS event payload (initiator object + optional `place`) to every handler
    -- registered through world.addEventHandler, the way the sim does.
    local function emit(id, unit, place)
        for h in pairs(handlers) do
            local ok, err = pcall(h.onEvent, h, {id=id, initiator=unit, place=place, time=now})
            assert(ok, 'event '..tostring(id)..' raised out of a handler: '..tostring(err))
        end
    end
    local function at(t) now = t end
    local require_module=setfenv(assert(loadstring(bundle)),e)()
    return {e=e,require_module=require_module,logs=logs,timers=timers,handlers=handlers,groups=groups,
        airbases=airbases,fire=fire,advance=advance,contains=contains,units=units_registry,
        destroys=destroys,materialise=materialise,emit=emit,at=at,now=function() return now end,
        calls=function() return calls end}
end

--------------------------------------------------------------------------------------------------
-- Defect 1 (epic #17 P1 -- "submission outcomes + reversible allocation") -- FIXED, asserts TARGET
--------------------------------------------------------------------------------------------------
-- The defect was: spawn_queue's coalition.addGroup returns a non-nil lazy proxy at ENQUEUE time, so
-- `ok && group ~= undefined` in task_board.try_assign was true regardless of whether the deferred
-- spawn ever succeeded, and drain() only LOGGED a later nil/throw. Ledger debit, keysite slot,
-- task registration and ASSIGNED state were committed against a group DCS was never asked for.
--
-- TARGET now asserted: allocation is REVERSIBLE and the reversal is driven by what the real API
-- actually did, with "unknown is not failed" as the governing rule.

local BASE, BASE2 = 'RECON-BASE', 'RECON-BASE-2'
local GROUP = 'Recon-Test-1'

-- Mirrors recon.buildRecon / heli_war.build_attack_heli exactly: call the (intercepted)
-- coalition.addGroup, hand the returned handle to aircraft_lifecycle.track(), return it. That one
-- track() call is the whole opt-in; untracked builders keep the previous behaviour.
local function tracked_builder(r, lifecycle, sides, unit_count, capture)
    return function(_)
        local units = {}
        for i=1,(unit_count or 1) do units[i]={name=GROUP..'-'..i, type='OH-58D', x=0, y=0} end
        local group = r.e.coalition.addGroup(sides.BLUE, r.e.Group.Category.AIRPLANE,
            {name=GROUP, units=units})
        lifecycle.track(group)
        if capture then capture(group) end
        return group
    end
end

local function scenario(opts, unit_count, capture)
    local r = runtime(opts)
    local queue = r.require_module('spawn_queue')       -- installs the interception FIRST, as main.ts does
    local state = r.require_module('campaign_state').S
    local board = r.require_module('task_board')
    local sides = r.require_module('sides')
    local lifecycle = r.require_module('aircraft_lifecycle')
    for _,name in ipairs({BASE, BASE2}) do
        state.base_owner[name] = sides.BLUE
        state.base_health[name] = 1
        state.base_pos[name] = {x=0, z=0}
        state.base_kind[name] = 'airbase'
        state.base_ledger[name] = {striker=0, escort=0, heli=0, recon=0, transport=0, vehicle=0}
    end
    state.base_ledger[BASE].recon = 1
    local task = board.create_task({
        type = 'recon',
        side = sides.BLUE,
        immediate = true,
        builder = tracked_builder(r, lifecycle, sides, unit_count, capture),
    })
    return {r=r, queue=queue, state=state, board=board, sides=sides, lifecycle=lifecycle, task=task}
end

-- QUEUED, NOT YET DRAINED. The debit is real and the task is ASSIGNED, but no aircraft is claimed
-- to exist: the attempt is explicitly unresolved and the task is not re-assignable.
do
    local c = scenario('ok')
    assert(c.task.state=='ASSIGNED', 'try_assign did not take the assignment')
    assert(c.task.assigned_group==GROUP)
    assert(c.task.attempt_id~=nil, 'no attempt id was linked to the assignment')
    assert(c.lifecycle.attempt_unresolved(c.task.attempt_id), 'attempt should be unresolved before drain')
    local attempt = c.lifecycle.get_attempt(c.task.attempt_id)
    -- Allocation facts are stored, not reconstructed from a group-name prefix later.
    assert(attempt.group_name==GROUP and attempt.expected_units[1]==GROUP..'-1')
    assert(attempt.resolution=='pending' and attempt.submitted==false)
    assert(c.state.base_ledger[BASE].recon==0, 'ledger was not debited at assignment time')
    assert(c.state.base_inflight[BASE]==1, 'launch slot was not reserved at assignment time')
    assert(c.state.active_tasks[c.task.dedup_key]==nil, 'dedup marker was not dropped at assignment time')
    assert(#c.state.spawn_queue==1, 'the group spawn is still only QUEUED, not live')
    assert(c.r.e.Group.getByName(GROUP)==nil, 'no real DCS group exists yet')
    assert(c.r.calls()==0, 'the real addGroup must not have been called yet')

    -- Repeated reconciliation while the attempt is unresolved: no second spawn, no second debit.
    c.board.tick()
    assert(#c.state.spawn_queue==1 and c.r.calls()==0, 'tick() issued a second spawn for an in-flight attempt')
    assert(c.state.base_ledger[BASE].recon==0, 'tick() debited a second aircraft')
    -- Even if the task were somehow back on the board, an unresolved attempt blocks assignment.
    c.task.state='UNASSIGNED'
    assert(c.board.try_assign(c.task)==false, 'try_assign re-assigned a task whose attempt is unresolved')
    c.board.tick()
    assert(#c.state.spawn_queue==1 and c.r.calls()==0, 'tick() assigned a task holding an unresolved attempt')
    c.task.state='ASSIGNED'

    assert(c.queue.drain()==1)
    assert(c.lifecycle.attempt_unresolved(c.task.attempt_id)==false, 'a created group left the attempt unresolved')
    assert(c.state.base_ledger[BASE].recon==0, 'a successful spawn must not refund')
    assert(c.state.base_inflight[BASE]==1, 'a successful spawn must keep its slot')
    assert(c.task.state=='ASSIGNED')
end

-- PROVEN NO-CREATION: nil, and a throw with no birth and no visible group. Exact refund, slot
-- released, task record cleared, dedup marker restored, task re-listed for retry -- exactly once.
for _,outcome in ipairs({'nil','threw'}) do
    local c = scenario(outcome)
    local attempt_id = c.task.attempt_id
    assert(c.state.base_ledger[BASE].recon==0 and c.state.base_inflight[BASE]==1)
    assert(c.queue.drain()==1)
    assert(c.r.contains(outcome=='threw' and 'addGroup THREW' or 'api_returned=false'),
        'drain-time failure was not logged (outcome='..outcome..')')
    assert(c.r.e.Group.getByName(GROUP)==nil, 'no live group was ever created (outcome='..outcome..')')
    assert(c.state.base_ledger[BASE].recon==1, 'ledger was not refunded (outcome='..outcome..')')
    assert(c.state.base_inflight[BASE]==0, 'launch slot was not released (outcome='..outcome..')')
    assert(c.state.group_launch_base[GROUP]==nil, 'slot ownership record survived the refund')
    assert(c.state.active_tasks[GROUP]==nil, 'task record for a group that never existed survived')
    assert(c.task.state=='UNASSIGNED', 'task stayed ASSIGNED though the spawn never happened (outcome='..outcome..')')
    assert(c.task.attempt_id==nil, 'a re-listed task kept a dead attempt id')
    assert(c.state.active_tasks[c.task.dedup_key]~=nil, 'dedup marker was not restored on re-listing')
    local on_board = false
    for _,t in ipairs(c.state.board_tasks) do if t==c.task then on_board=true end end
    assert(on_board, 'task was not put back on the board for retry')
    assert(#c.state.spawn_queue==0, 'drain did not clear the queue (outcome='..outcome..')')
    assert(c.lifecycle.stats().refunded==1, 'expected exactly one reversal')

    -- DUPLICATE RESULT: settling the same attempt again must not refund a second time.
    c.lifecycle.settle_submission(c.lifecycle.get_attempt(attempt_id), outcome)
    assert(c.state.base_ledger[BASE].recon==1, 'a duplicate result double-refunded')
    assert(c.lifecycle.get_attempt(attempt_id).resolution=='failed_no_creation',
        'a duplicate result re-classified an already settled attempt')
    assert(c.lifecycle.stats().refunded==1, 'a duplicate result reversed the allocation twice')
    assert(c.lifecycle.stats().duplicate_results==1, 'the duplicate result was not rejected by the settlement guard')
    -- Repeated reconciliation: draining again changes nothing and spawns nothing.
    assert(c.queue.drain()==0)
    assert(c.state.base_ledger[BASE].recon==1 and c.state.base_inflight[BASE]==0)

    -- RETRY rides the EXISTING assignment pass and the EXISTING expiry -- no new timer, no new
    -- cadence (ts_updt.c:99-124, assign.c:259-295).
    c.board.tick()
    assert(c.task.state=='ASSIGNED', 'the re-listed task was not retried by the ordinary board pass')
    assert(c.state.base_ledger[BASE].recon==0 and #c.state.spawn_queue==1, 'retry did not re-debit and re-queue')
end

-- SETTLEMENT IDEMPOTENCY, at the allocation level. Reversing the same allocation twice must give
-- back the debit once. This is the guard that stands between a retry storm and invented stock.
do
    local c = scenario('ok')
    local allocation = c.lifecycle.begin_allocation({
        task_type='recon', side=c.sides.BLUE, base=BASE2, role='recon', count=1,
    })
    c.state.base_ledger[BASE2].recon = 0
    c.lifecycle.abort_allocation(allocation, 'first reversal')
    assert(c.state.base_ledger[BASE2].recon==1, 'the first reversal did not refund')
    c.lifecycle.abort_allocation(allocation, 'second reversal')
    assert(c.state.base_ledger[BASE2].recon==1, 'reversing the same allocation twice double-refunded')
end

-- AMBIGUOUS: the API threw, but a unit was BORN first. Something may well exist, so this must not
-- refund and must not respawn -- it stays visible as unresolved and accounted for.
do
    local c = scenario('birth_then_threw')
    local attempt_id = c.task.attempt_id
    assert(c.queue.drain()==1)
    local attempt = c.lifecycle.get_attempt(attempt_id)
    assert(attempt.birth_seen==true, 'the synchronous BIRTH during addGroup was not correlated')
    assert(attempt.resolution=='ambiguous', 'a throw after a birth was treated as a proven failure')
    assert(c.state.base_ledger[BASE].recon==0, 'an ambiguous outcome refunded the ledger')
    assert(c.state.base_inflight[BASE]==1, 'an ambiguous outcome released the slot')
    assert(c.task.state=='ASSIGNED', 'an ambiguous outcome re-listed the task for respawn')
    assert(c.lifecycle.stats().refunded==0 and c.lifecycle.stats().ambiguous==1)
    local still_listed = false
    for _,a in ipairs(c.lifecycle.unresolved()) do if a.id==attempt_id then still_listed=true end end
    assert(still_listed, 'an ambiguous attempt stopped being visible as unresolved')
    c.board.tick()
    assert(#c.state.spawn_queue==0 and c.r.calls()==1, 'an ambiguous outcome triggered a respawn')
end

-- AMBIGUOUS: the outcome query itself failed. Same rule -- unknown is not failed.
do
    local c = scenario({outcome='nil', group_lookup_error=true})
    assert(c.queue.drain()==1)
    assert(c.lifecycle.get_attempt(c.task.attempt_id).resolution=='ambiguous',
        'a failed existence query was treated as a proven failure')
    assert(c.state.base_ledger[BASE].recon==0 and c.state.base_inflight[BASE]==1)
    assert(c.task.state=='ASSIGNED')
end

-- PARTIAL and DELAYED materialisation: a group came back with fewer units than requested. A
-- partial group never triggers a whole-group refund.
for _,case in ipairs({{outcome='partial', units=2, observed=1}, {outcome='delayed', units=2, observed=0}}) do
    local c = scenario(case.outcome, case.units)
    assert(c.queue.drain()==1)
    local attempt = c.lifecycle.get_attempt(c.task.attempt_id)
    assert(attempt.resolution=='created_partial', case.outcome..': expected created_partial')
    assert(attempt.observed_units==case.observed, case.outcome..': wrong observed unit count')
    assert(c.state.base_ledger[BASE].recon==0, case.outcome..': a partial group refunded the whole allocation')
    assert(c.state.base_inflight[BASE]==1, case.outcome..': a partial group released the slot')
    assert(c.task.state=='ASSIGNED', case.outcome..': a partial group re-listed the task')
    assert(c.lifecycle.stats().refunded==0)
end

-- CANCELLATION BEFORE DRAIN: destroying the handle must prevent the physical spawn, not merely
-- destroy a group that does not exist yet, and must reverse the allocation.
do
    local handle
    local c = scenario('ok', 1, function(group) handle = group end)
    assert(handle.__queued==true, 'queued proxy flag lost')
    handle:destroy()
    assert(#c.state.spawn_queue==1, 'cancellation should leave the item queued but inert')
    assert(c.queue.drain()==1)
    assert(c.r.calls()==0, 'a cancelled request still reached the real coalition.addGroup')
    assert(c.r.contains('CANCELLED #'), 'the cancelled submission was not reported')
    assert(c.r.e.Group.getByName(GROUP)==nil, 'a cancelled request still produced a group')
    assert(c.state.base_ledger[BASE].recon==1, 'cancellation did not refund the debit')
    assert(c.state.base_inflight[BASE]==0, 'cancellation did not release the slot')
    assert(c.task.state=='UNASSIGNED', 'cancellation did not re-list the task')
    assert(#c.state.spawn_queue==0)
end

-- A request-owned DELAYED CALLBACK is fenced by that one attempt's cancellation. A generation
-- check alone cannot express this: the generation is unchanged throughout.
do
    local handle
    local c = scenario('ok', 1, function(group) handle = group end)
    local generation = c.r.e._DMT_GEN
    local fired = {}
    c.lifecycle.schedule_for(c.lifecycle.get_attempt(c.task.attempt_id), 60,
        function() fired.cancelled_one = true end)
    handle:destroy()
    c.r.advance(120)
    assert(c.r.e._DMT_GEN==generation, 'the generation must not have moved for this to prove anything')
    assert(fired.cancelled_one==nil, 'a cancelled request still ran its delayed callback')

    local d = scenario('ok')
    d.lifecycle.schedule_for(d.lifecycle.get_attempt(d.task.attempt_id), 60,
        function() fired.live_one = true end)
    d.r.advance(120)
    assert(fired.live_one==true, 'a live request lost its delayed callback')
end

-- STALE GENERATION: a re-injection replaced the state table. The failure is still classified, but
-- nothing is credited into the new campaign's ledger and nothing is re-listed.
do
    local c = scenario('nil')
    c.r.e._DMT_GEN = c.r.e._DMT_GEN + 1
    assert(c.queue.drain()==1)
    assert(c.state.base_ledger[BASE].recon==0, 'a stale-generation failure refunded the new campaign')
    assert(c.state.base_inflight[BASE]==1, 'a stale-generation failure released a slot')
    assert(c.task.state=='ASSIGNED', 'a stale-generation failure re-listed a task')
    assert(c.lifecycle.stats().refunded==0)
end

-- BASE OWNER CHANGED BEFORE DRAIN: the launch base was captured between the debit and the proven
-- failure. The refund must never credit the captor.
do
    local c = scenario('nil')
    c.state.base_owner[BASE] = c.sides.RED
    assert(c.queue.drain()==1)
    assert(c.state.base_ledger[BASE].recon==0, 'the refund credited a base now held by the enemy')
    assert(c.state.base_ledger[BASE2].recon==1, 'the allocating side never got its aircraft back')
    assert(c.state.base_inflight[BASE]==0, 'the launch slot was not released')
    assert(c.task.state=='UNASSIGNED')
end

-- RECONCILIATION WITH DEBUG DISABLED. spawn_diagnostics is observational only; correctness must
-- not depend on it (and no observer may be left behind).
do
    local c = scenario({outcome='nil', debug=false})
    assert(c.queue.drain()==1)
    assert(c.state.base_ledger[BASE].recon==1, 'refund did not happen with debug disabled')
    assert(c.state.base_inflight[BASE]==0)
    assert(c.task.state=='UNASSIGNED')
    assert(not c.r.contains('[spawn_probe]'), 'diagnostics ran with debug disabled')
    assert(next(c.r.handlers)==nil, 'the birth observer outlived the submission')
end

-- UNTRACKED (non-aircraft) CALLERS: no attempt, no allocation, no refund path -- the accounting
-- contract does not reach them and must not.
--
-- The ONE thing they now share (epic #17 P4, item 7): destroying the proxy handle before the
-- queued spawn drains cancels the request. Until P4 that was a silent no-op unless the item was a
-- tracked aircraft, so a ground group or static torn down inside the drain window spawned anyway,
-- minutes later, with nobody holding it.
do
    local r = runtime('ok')
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local proxy = r.e.coalition.addGroup(2, r.e.Group.Category.GROUND,
        {name='Ground-Test', units={{name='Ground-Test-1', type='M-1 Abrams', x=0, y=0}}})
    assert(state.spawn_queue[1].attempt_id==nil, 'an untracked spawn was given a lifecycle attempt')
    proxy:destroy()
    assert(state.spawn_queue[1].cancelled==true, 'destroy() before drain did not cancel the queued item')
    -- drain() still CONSUMES the item (returns 1), it just must not spend an API call on it.
    assert(queue.drain()==1, 'the cancelled item was not consumed by drain')
    assert(r.calls()==0, 'a destroyed-before-drain untracked spawn still reached the real addGroup')
    assert(r.e.Group.getByName('Ground-Test')==nil, 'a group destroyed before drain was created anyway')
    assert(r.contains('CANCELLED'), 'the untracked cancellation was not logged')
    assert(#state.spawn_queue==0, 'drain did not clear the queue')
end

-- ...and a static torn down the same way, since statics take the same proxy.
do
    local r = runtime('ok')
    local placed = 0
    -- Installed BEFORE spawn_queue is required, so this is the "real" API the interception
    -- captures and defers to -- not a stand-in written over the top of the interception.
    r.e.coalition.addStaticObject = function() placed = placed + 1 return {} end
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local proxy = r.e.coalition.addStaticObject(2, {name='Static-Test', type='Warehouse', x=0, y=0})
    assert(state.spawn_queue[1] ~= nil and state.spawn_queue[1].kind=='static', 'static was not queued')
    proxy:destroy()
    assert(state.spawn_queue[1].cancelled==true, 'destroy() before drain did not cancel the queued static')
    assert(queue.drain()==1, 'the cancelled static was not consumed by drain')
    assert(placed==0, 'a static destroyed before drain still reached the real addStaticObject')
end

-- UNTOUCHED CALLERS ARE UNTOUCHED: an untracked spawn nobody destroys still goes through.
do
    local r = runtime('ok')
    local queue = r.require_module('spawn_queue')
    r.e.coalition.addGroup(2, r.e.Group.Category.GROUND,
        {name='Ground-Keep', units={{name='Ground-Keep-1', type='M-1 Abrams', x=0, y=0}}})
    assert(queue.drain()==1 and r.calls()==1, 'an untouched untracked spawn was suppressed')
    assert(r.e.Group.getByName('Ground-Keep')~=nil, 'the untracked ground spawn did not reach DCS')
end

-- END TO END through the real production builder: recon.spawn_recon -> task_board -> buildRecon
-- -> spawn_queue -> drain. Proves the wiring above is the one the campaign actually uses, not
-- just a harness-local mirror of it.
do
    local r = runtime('nil')
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local recon = r.require_module('recon')
    local FIELD = 'RECON-FIELD'
    state.base_owner[FIELD] = sides.BLUE
    state.base_health[FIELD] = 1
    state.base_pos[FIELD] = {x=0, z=0}
    state.base_kind[FIELD] = 'airbase'
    state.base_ledger[FIELD] = {striker=0, escort=0, heli=0, recon=1, transport=0, vehicle=0}
    r.airbases[FIELD] = {
        getID=function() return 11 end,
        getName=function() return FIELD end,
        getPosition=function() return {p={x=0, y=20, z=0}} end,
        getDesc=function() return {category=0} end,
    }
    assert(recon.spawn_recon(sides.BLUE, {x=5000, z=5000}, 'RECON', function() end)==true)
    assert(state.base_ledger[FIELD].recon==0, 'spawn_recon did not debit through the board')
    assert(state.base_inflight[FIELD]==1, 'spawn_recon did not reserve a slot')
    assert(#state.spawn_queue==1, 'spawn_recon did not defer its spawn')
    assert(queue.drain()==1)
    assert(state.base_ledger[FIELD].recon==1, 'a proven recon spawn failure was not refunded end to end')
    assert(state.base_inflight[FIELD]==0, 'a proven recon spawn failure did not release the slot')
    local relisted = false
    for _,t in ipairs(state.board_tasks) do if t.type=='recon' and t.state=='UNASSIGNED' then relisted=true end end
    assert(relisted, 'the recon task was not re-listed for retry end to end')
end
-- END TO END through the second P1 path: heli_war.build_attack_heli (the CAS/BAI attack-heli
-- section, 2 airframes in ONE group). Same contract, a multi-unit group and a different role.
do
    local r = runtime('nil')
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local board = r.require_module('task_board')
    local sides = r.require_module('sides')
    local heli_war = r.require_module('heli_war')
    local PAD = 'HELI-BASE'
    state.base_owner[PAD] = sides.BLUE
    state.base_health[PAD] = 1
    state.base_pos[PAD] = {x=0, z=0}
    state.base_kind[PAD] = 'airbase'
    -- SECTION_SIZE (2) plus MIN_IDLE.heli (2) must be in stock for the board to assign at all.
    state.base_ledger[PAD] = {striker=0, escort=0, heli=4, recon=0, transport=0, vehicle=0}
    r.airbases[PAD] = {
        getID=function() return 22 end,
        getName=function() return PAD end,
        getPosition=function() return {p={x=0, y=20, z=0}} end,
        getDesc=function() return {category=0} end,
    }
    local task = board.create_task({
        type = 'cas',
        side = sides.BLUE,
        count = 2,
        immediate = true,
        target = {pos={x=4000, z=4000}},
        -- task_board calls builders with a receiver (dist: `task:builder(bestBase)`), so the
        -- base name arrives as the SECOND argument.
        builder = function(_, base)
            return heli_war.build_attack_heli(sides.BLUE, base, {x=4000, z=4000}, 'cas')
        end,
    })
    assert(task.state=='ASSIGNED', 'the heli CAS section was not assigned')
    assert(state.base_ledger[PAD].heli==2, 'the heli section did not debit SECTION_SIZE airframes')
    assert(state.base_inflight[PAD]==1, 'the heli section did not reserve a launch slot')
    assert(task.attempt_id~=nil, 'build_attack_heli did not link a lifecycle attempt')
    local attempt = r.require_module('aircraft_lifecycle').get_attempt(task.attempt_id)
    assert(#attempt.expected_units==2, 'the attempt did not record both section members')
    assert(#state.spawn_queue==1)
    assert(queue.drain()==1)
    assert(state.base_ledger[PAD].heli==4, 'a proven heli-section spawn failure refunded the wrong count')
    assert(state.base_inflight[PAD]==0, 'a proven heli-section spawn failure did not release the slot')
    assert(state.active_tasks[task.assigned_group or '?']==nil, 'a task record survived for a group that never existed')
    assert(task.state=='UNASSIGNED', 'the heli CAS task was not re-listed for retry')
end
print('PASS aircraft-lifecycle defect 1 (P1 TARGET): submission outcomes reported back; a PROVEN failure refunds the exact debit and slot once and re-lists the task; nil/throw/throw-after-birth/query-error/partial/delayed/cancelled/duplicate/stale-generation/base-capture all settle correctly')

--------------------------------------------------------------------------------------------------
-- Defect 3 (epic #17 P2 — "physical parking leases") — FIXED, asserts TARGET
--------------------------------------------------------------------------------------------------
-- The defect was: farp_parking.configureDeparture() rotated a single module-level counter 1..4 per
-- base with no record of which stand was actually occupied and no release when a group departed or
-- died. The live probe (docs/bots/LIVE-PROBE-2026-09-22.md) measured three facts that make that
-- doubly wrong:
--   finding 3: FARP terminals are Term_Index 0..3 and the emitted `parking` value maps DIRECTLY
--              onto Term_Index — so "4" addressed a stand that does not exist and pad 0 could
--              never be used;
--   finding 2: getParking(true) does NOT report occupancy, so occupancy must come from per-terminal
--              TO_AC, and a failed parking query is UNKNOWN (never zero, never unlimited);
--   finding 4: a departed aircraft keeps TO_AC=true while airborne, so a stand must NOT be freed
--              on takeoff.
--
-- TARGET now asserted: stand selection is separate from departure serialisation, reads the live
-- terminal set, leases each stand atomically for the whole group (including while the request is
-- still undrained in the spawn queue), accounts for occupants we did not create, never frees a
-- stand because its aircraft left the pad, and rolls back only its own leases when its allocation
-- is reversed.

-- A stock four-pad FARP whose per-terminal TO_AC is settable, exactly as the probe read it.
local function farp_airbase(pads, id)
    local base = {pads = pads}
    function base:getID() return id or 77 end
    function base:getDesc() return {category=1} end
    function base:getPosition() return {p={x=100, y=20, z=200}} end
    function base:getParking(available)
        -- The adapter must ask for the FULL set: getParking(true) was measured unreliable.
        assert(available == false, 'stand selection must not rely on getParking(available=true)')
        local out = {}
        for index = 0, 3 do
            out[#out+1] = {Term_Index=index, Term_Index_0=index, Term_Type=40,
                           vTerminalPos={x=100+index, y=20, z=200}, TO_AC=self.pads[index]==true,
                           fDistToRW=0}
        end
        return out
    end
    return base
end
local function nship(name, n)
    local units = {}
    for i = 1, n do units[i] = {name=name..'-'..i, type='Mi-24V', x=7, y=9} end
    return {name=name, units=units}
end
local function departure() return {x=0, y=0, type='TakeOffParkingHot', action='stale'} end
local function parking_of(spec)
    local out = {}
    for i, unit in ipairs(spec.units) do out[i] = unit.parking end
    return out
end

-- A four-ship at a four-pad FARP occupies all four REAL stands, including Term_Index 0, and emits
-- nothing outside the live terminal set. This is the 0-based defect, asserted directly.
do
    local r = runtime()
    local adapter = r.require_module('farp_parking')
    r.require_module('campaign_state').S.base_kind.FARP = 'farp'
    local base = farp_airbase({})
    local quad = nship('Quad', 4)
    adapter.configureDeparture('FARP', base, quad, departure())

    local live = {['0']=true, ['1']=true, ['2']=true, ['3']=true}
    local seen = {}
    for _, value in ipairs(parking_of(quad)) do
        assert(live[value], 'emitted parking "'..tostring(value)..'" is not a live Term_Index')
        assert(not seen[value], 'two aircraft were put on the same stand: '..tostring(value))
        seen[value] = true
    end
    assert(seen['0'], 'Term_Index 0 was never used — the 0-based defect is still present')
    assert(seen['1'] and seen['2'] and seen['3'], 'the four-ship did not occupy all four real stands')
    for _, unit in ipairs(quad.units) do
        assert(unit.parking_id == unit.parking, 'parking_id diverged from parking')
        assert(unit.parking ~= '4', 'parking "4" is not a terminal on a stock FARP')
    end
end

-- Occupancy comes from TO_AC, so stands held by aircraft this campaign did not create — players,
-- authored units, anything already parked — are never taken.
do
    local r = runtime()
    local adapter = r.require_module('farp_parking')
    r.require_module('campaign_state').S.base_kind.FARP = 'farp'
    local base = farp_airbase({[0]=true, [2]=true})  -- e.g. a player and a pre-existing unit
    local pair = nship('Pair', 2)
    adapter.configureDeparture('FARP', base, pair, departure())
    local got = parking_of(pair)
    table.sort(got)
    assert(got[1]=='1' and got[2]=='3',
        'a stand flagged TO_AC was taken from its occupant: got '..table.concat(got, ','))
end

-- Reservations are atomic and cross-group while the requests are still UNDRAINED in the spawn
-- queue: nothing has spawned, nothing is TO_AC, and the leases are the only thing holding the pads.
-- The third two-ship cannot be seated and is refused rather than stacked onto Alpha's stands.
do
    local r = runtime()
    local adapter = r.require_module('farp_parking')
    local lifecycle = r.require_module('aircraft_lifecycle')
    r.require_module('campaign_state').S.base_kind.FARP = 'farp'
    local base = farp_airbase({})
    local alpha, bravo, charlie = nship('Alpha', 2), nship('Bravo', 2), nship('Charlie', 2)
    adapter.configureDeparture('FARP', base, alpha, departure())
    adapter.configureDeparture('FARP', base, bravo, departure())
    local a, b = parking_of(alpha), parking_of(bravo)
    table.sort(a); table.sort(b)
    assert(a[1]=='0' and a[2]=='1', 'first section did not take the first two real stands')
    assert(b[1]=='2' and b[2]=='3', 'second section overlapped the first section')
    assert(#lifecycle.leased_stands('FARP')==4, 'four undrained aircraft did not hold four stands')
    assert(lifecycle.stand_holder('FARP', 0)=='Alpha' and lifecycle.stand_holder('FARP', 3)=='Bravo')

    local ok, err = pcall(adapter.configureDeparture, 'FARP', base, charlie, departure())
    assert(ok == false, 'a full FARP silently seated a third section')
    assert(tostring(err):find('no free parking stand', 1, true), 'capacity refusal lost its reason: '..tostring(err))
    assert(charlie.units[1].parking == nil and charlie.units[2].parking == nil,
        'a refused group was still given stands')
    -- Refusal is all-or-nothing: the failed request leaves the other groups' leases exactly as they
    -- were and claims nothing partially.
    assert(#lifecycle.leased_stands('FARP')==4, 'the refused request mutated the held stands')
    assert(lifecycle.stand_holder('FARP', 0)=='Alpha' and lifecycle.stand_holder('FARP', 1)=='Alpha')
    assert(lifecycle.stand_holder('FARP', 2)=='Bravo' and lifecycle.stand_holder('FARP', 3)=='Bravo')
end

-- A lease is NOT released because the aircraft left our hands. Alpha has drained and exists in DCS,
-- but the live pads still read TO_AC=false — the pad "looks empty". The lease must hold, so Bravo
-- gets the remaining stands and never Alpha's. (Probe finding 4: TO_AC stays true across a real
-- departure, so this is the conservative direction in every case.)
do
    local r = runtime()
    local adapter = r.require_module('farp_parking')
    local lifecycle = r.require_module('aircraft_lifecycle')
    r.require_module('campaign_state').S.base_kind.FARP = 'farp'
    local base = farp_airbase({})
    local alpha, bravo = nship('Alpha', 2), nship('Bravo', 2)
    adapter.configureDeparture('FARP', base, alpha, departure())
    -- Alpha is now a real group in DCS, airborne, with the pads reporting nothing.
    r.groups.Alpha = {getName=function() return 'Alpha' end}
    adapter.configureDeparture('FARP', base, bravo, departure())
    local b = parking_of(bravo)
    table.sort(b)
    assert(b[1]=='2' and b[2]=='3',
        'a departed aircraft\'s stand was handed to another group: got '..table.concat(b, ','))
    assert(lifecycle.stand_holder('FARP', 0)=='Alpha' and lifecycle.stand_holder('FARP', 1)=='Alpha',
        'Alpha\'s stands were released although only its aircraft, not its claim, had left')
end

-- Hand-over, not release: once the live airbase reports the pads as TO_AC, the provisional lease is
-- dropped (the registry must not grow without bound) but the stands stay OCCUPIED — the union of
-- TO_AC and leased is what selection sees, so a later group still cannot take them.
do
    local r = runtime()
    local adapter = r.require_module('farp_parking')
    local lifecycle = r.require_module('aircraft_lifecycle')
    r.require_module('campaign_state').S.base_kind.FARP = 'farp'
    local base = farp_airbase({})
    local alpha, bravo, charlie = nship('Alpha', 2), nship('Bravo', 2), nship('Charlie', 2)
    adapter.configureDeparture('FARP', base, alpha, departure())
    r.groups.Alpha = {getName=function() return 'Alpha' end}
    base.pads[0] = true; base.pads[1] = true   -- DCS now reports Alpha's pads itself
    adapter.configureDeparture('FARP', base, bravo, departure())
    local b = parking_of(bravo)
    table.sort(b)
    assert(b[1]=='2' and b[2]=='3', 'hand-over let Bravo onto Alpha\'s pads')
    assert(lifecycle.stand_holder('FARP', 0)==nil, 'the overlay lease outlived the live TO_AC it duplicates')
    local ok = pcall(adapter.configureDeparture, 'FARP', base, charlie, departure())
    assert(ok == false, 'the FARP was treated as having free pads after hand-over')
end

-- Real FOB airdromes and ordinary airfields stay distinct from heliports: even with real parking
-- data available, no stand is selected, no lease is taken and airdromeId is used. Validated against
-- actual parking data rather than by assuming the query is absent.
do
    local r = runtime()
    local adapter = r.require_module('farp_parking')
    local lifecycle = r.require_module('aircraft_lifecycle')
    local state = r.require_module('campaign_state').S
    for _, kind in ipairs({'airbase', 'fob'}) do
        local name = 'FIELD-'..kind
        state.base_kind[name] = kind
        local base = farp_airbase({}, 31)
        function base:getDesc() return {category=0} end   -- AIRDROME, not HELIPAD
        local spec, depart = nship('Jets', 2), departure()
        adapter.configureDeparture(name, base, spec, depart)
        assert(spec.airdromeId==31 and depart.airdromeId==31, kind..' departure lost airdromeId')
        assert(depart.helipadId==nil and depart.linkUnit==nil, kind..' was encoded as a heliport')
        assert(spec.units[1].parking==nil and spec.units[1].parking_id==nil,
            kind..' invented a parking stand DCS resolves itself')
        assert(#lifecycle.leased_stands(name)==0, kind..' took a stand lease it does not own')
    end
end

-- END TO END through the real production builder (heli_war.build_attack_heli) at a FARP with a live
-- terminal set, asserting the departure ENCODING against the fixture's own identity and the real
-- group contents — not copied literals.
do
    local r = runtime()
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local heli_war = r.require_module('heli_war')
    local lifecycle = r.require_module('aircraft_lifecycle')
    local PAD = 'FARP-Prod'
    local BASE_ID, ORIGIN_X, ORIGIN_Z = 4242, 100, 200
    state.base_owner[PAD] = sides.BLUE
    state.base_health[PAD] = 1
    state.base_pos[PAD] = {x=ORIGIN_X, z=ORIGIN_Z}
    state.base_kind[PAD] = 'farp'
    state.farp_active[PAD] = true
    state.base_ledger[PAD] = {striker=0, escort=0, heli=4, recon=0, transport=0, vehicle=0}
    local base = farp_airbase({}, BASE_ID)
    function base:getName() return PAD end
    r.airbases[PAD] = base

    local group = heli_war.build_attack_heli(sides.BLUE, PAD, {x=9000, z=9000}, 'cas', function() end)
    assert(group ~= nil, 'the production FARP builder did not return a group')
    local spec
    for _, item in ipairs(state.spawn_queue) do
        if item.kind=='group' and item.name==group:getName() then spec = item.data end
    end
    assert(spec ~= nil, 'the production FARP group was not queued')
    local depart = spec.route.points[1]
    -- Live base identity, taken from the fixture's own getID/getPosition, not a literal.
    assert(depart.helipadId==base:getID() and depart.linkUnit==base:getID(),
        'FARP departure did not link to the live heliport object')
    assert(spec.airdromeId==nil and depart.airdromeId==nil, 'a FARP departure used airdrome fields')
    assert(spec.x==base:getPosition().p.x and spec.y==base:getPosition().p.z,
        'the group was not placed at the live heliport origin')
    assert(depart.x==spec.x and depart.y==spec.y, 'the departure waypoint left the heliport origin')
    -- The proven hot ramp pair: `type` is what the sim honours, so the pair must stay matched.
    assert(depart.type=='TakeOffParkingHot' and depart.action=='From Parking Area Hot',
        'the hot ramp start pair was not preserved')
    -- Real aircraft count, from the group the builder actually produced.
    local count = #spec.units
    assert(count >= 1, 'the production builder produced no aircraft')
    local claimed = {}
    for _, unit in ipairs(spec.units) do
        assert(unit.x==spec.x and unit.y==spec.y, 'a helicopter kept a formation offset at a FARP')
        assert(unit.parking ~= nil and unit.parking==unit.parking_id, 'a helicopter got no stand')
        assert(not claimed[unit.parking], 'two helicopters shared a stand')
        claimed[unit.parking] = true
        assert(lifecycle.stand_holder(PAD, tonumber(unit.parking))==spec.name,
            'the emitted stand is not the one the allocation leased')
    end
    assert(#lifecycle.leased_stands(PAD)==count,
        'the number of leased stands does not match the number of aircraft actually built')
    assert(#state.spawn_queue==1 and queue ~= nil, 'the production FARP spawn was not deferred')
end

-- A reversed allocation rolls back ONLY its own stands. Alpha's proven-failed launch gives its pads
-- back; Bravo, whose request is still in flight, keeps both of hers.
do
    local r = runtime('nil')
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local board = r.require_module('task_board')
    local sides = r.require_module('sides')
    local heli_war = r.require_module('heli_war')
    local lifecycle = r.require_module('aircraft_lifecycle')
    local PAD = 'FARP-Rollback'
    state.base_owner[PAD] = sides.BLUE
    state.base_health[PAD] = 1
    state.base_pos[PAD] = {x=100, z=200}
    state.base_kind[PAD] = 'farp'
    state.farp_active[PAD] = true
    state.base_ledger[PAD] = {striker=0, escort=0, heli=6, recon=0, transport=0, vehicle=0}
    local base = farp_airbase({}, 55)
    function base:getName() return PAD end
    r.airbases[PAD] = base

    local first = board.create_task({
        type='cas', side=sides.BLUE, count=2, immediate=true, target={pos={x=4000, z=4000}},
        builder=function(_, b) return heli_war.build_attack_heli(sides.BLUE, b, {x=4000, z=4000}, 'cas') end,
    })
    local second_group = heli_war.build_attack_heli(sides.BLUE, PAD, {x=5000, z=5000}, 'cas', function() end)
    assert(first.state=='ASSIGNED' and second_group ~= nil)
    assert(#lifecycle.leased_stands(PAD)==4, 'two undrained sections did not hold four stands')
    local kept = {}
    for _, index in ipairs(lifecycle.leased_stands(PAD)) do
        if lifecycle.stand_holder(PAD, index)==second_group:getName() then kept[#kept+1] = index end
    end
    assert(#kept==2, 'the second section did not hold two distinct stands')

    -- Drain: the FIRST section's real addGroup returns nil with no birth and no visible group — a
    -- PROVEN failure, so its allocation reverses and takes its stands with it.
    assert(queue.drain() >= 1)
    assert(first.state=='UNASSIGNED', 'the proven-failed section was not re-listed')
    -- 6 in stock, 2 debited by the board for the first section, 2 refunded by the reversal. The
    -- second section was built directly, outside the board, so it never debited.
    assert(state.base_ledger[PAD].heli==6, 'the proven-failed section did not refund its exact debit')
    local remaining = lifecycle.leased_stands(PAD)
    assert(#remaining==2, 'reversal released the wrong number of stands: '..#remaining)
    for _, index in ipairs(remaining) do
        assert(lifecycle.stand_holder(PAD, index)==second_group:getName(),
            'reversal released a stand belonging to another allocation')
    end
end

-- A FARP with NO usable terminal data is UNKNOWN capacity, not zero and not unlimited: the
-- departure still serialises (no launch is falsely failed) and no stand lease is taken against
-- data that does not exist.
do
    local r = runtime()
    local adapter = r.require_module('farp_parking')
    local lifecycle = r.require_module('aircraft_lifecycle')
    r.require_module('campaign_state').S.base_kind.FARP = 'farp'
    local blind = {getID=function() return 88 end, getDesc=function() return {category=1} end,
                   getPosition=function() return {p={x=100, y=20, z=200}} end}
    local spec, depart = nship('Blind', 2), departure()
    adapter.configureDeparture('FARP', blind, spec, depart)
    assert(depart.helipadId==88 and depart.type=='TakeOffParkingHot' and depart.action=='From Parking Area Hot',
        'an unknown-capacity FARP broke the departure encoding')
    assert(spec.units[1].parking ~= nil and spec.units[2].parking ~= nil,
        'unknown capacity was treated as zero and blocked the departure')
    assert(spec.units[1].parking ~= spec.units[2].parking, 'the fallback stacked both aircraft on one stand')
    assert(#lifecycle.leased_stands('FARP')==0, 'a stand was leased with no terminal data to lease against')

    local raising = {getID=function() return 89 end, getDesc=function() return {category=1} end,
                     getPosition=function() return {p={x=100, y=20, z=200}} end,
                     getParking=function() error('injected parking query failure') end}
    local raised = nship('Raised', 1)
    adapter.configureDeparture('FARP', raising, raised, departure())
    assert(raised.units[1].parking ~= nil, 'a raising parking query was treated as zero capacity')
end
-- FULL BASE, through the real assignment process. Every pad is occupied by something we did not
-- create, so the builder refuses. The task must come back to the existing board — no duplicate
-- spawn, no debit left stranded, no falsely successful launch, and no new retry timer.
do
    local r = runtime()
    local state = r.require_module('campaign_state').S
    local board = r.require_module('task_board')
    local sides = r.require_module('sides')
    local heli_war = r.require_module('heli_war')
    local lifecycle = r.require_module('aircraft_lifecycle')
    local PAD = 'FARP-Full'
    state.base_owner[PAD] = sides.BLUE
    state.base_health[PAD] = 1
    state.base_pos[PAD] = {x=100, z=200}
    state.base_kind[PAD] = 'farp'
    state.farp_active[PAD] = true
    state.base_ledger[PAD] = {striker=0, escort=0, heli=4, recon=0, transport=0, vehicle=0}
    local base = farp_airbase({[0]=true, [1]=true, [2]=true, [3]=true}, 66)
    function base:getName() return PAD end
    r.airbases[PAD] = base

    local task = board.create_task({
        type='cas', side=sides.BLUE, count=2, immediate=true, target={pos={x=4000, z=4000}},
        builder=function(_, b) return heli_war.build_attack_heli(sides.BLUE, b, {x=4000, z=4000}, 'cas') end,
    })
    assert(task.state=='UNASSIGNED', 'a launch from a full FARP was reported as assigned')
    assert(#state.spawn_queue==0, 'a full FARP still queued a spawn')
    assert(r.calls()==0, 'a full FARP reached the real addGroup')
    assert(state.base_ledger[PAD].heli==4, 'the refused launch left its debit stranded')
    assert((state.base_inflight[PAD] or 0)==0, 'the refused launch kept a keysite launch slot')
    assert(#lifecycle.leased_stands(PAD)==0, 'the refused launch retained a stand it never got')
    -- Still on the board: the existing tick()/expiry retry window owns it from here.
    local listed = false
    for _, queued in ipairs(state.board_tasks) do if queued==task then listed = true end end
    assert(listed, 'the refused task was dropped instead of staying eligible for assignment')
end
print('PASS aircraft-lifecycle defect 3 (P2 TARGET): stands are leased over real 0-based Term_Index values read from the live airbase; TO_AC occupancy, atomic whole-group reservation across the undrained queue, no release on departure, hand-over to live truth, own-leases-only rollback, conservative full-base refusal and unknown-capacity fallback')

--------------------------------------------------------------------------------------------------
-- Guarded configureDeparture call sites (epic #17 P2 follow-up) -- FIXED, asserts TARGET
--------------------------------------------------------------------------------------------------
-- `regen.spawnRegen`, `reaction.spawn_bda` and `supply_flight.buildSupplyFlight` all call
-- farp_parking.configureDeparture directly. P2 made a capacity refusal reachable there (it raises
-- rather than stacking aircraft on one pad), and each of these runs off a scheduler tick, so an
-- uncaught refusal could kill a timer chain. Each call is now guarded and routed into that
-- function's OWN pre-existing spawn-failure path.
--
-- Each leg below refuses the SAME way: a live four-pad FARP with every Term_Index already flagged
-- TO_AC by something we did not create. The invariants are identical at all three sites --
-- no aircraft spawned, no debit leaked, no error escaping the caller.

-- regen: existing failure path is log + `return false`, which leaves the entry queued for the next
-- tick. The `supply.consume` this call made must come back, once, or a permanently full FARP would
-- drain the base reserve one helicopter per tick for ever.
do
    local r = runtime()
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local regen = r.require_module('regen')
    local PAD = 'FARP-Regen-Refusal'
    state.base_owner[PAD] = sides.BLUE
    state.base_health[PAD] = 1
    state.base_pos[PAD] = {x=100, z=200}
    state.base_kind[PAD] = 'farp'
    state.farp_active[PAD] = true
    state.base_ammo[PAD] = 100
    state.base_ledger[PAD] = {striker=0, escort=0, heli=2, recon=0, transport=0, vehicle=0}
    local base = farp_airbase({[0]=true, [1]=true, [2]=true, [3]=true}, 91)
    function base:getName() return PAD end
    r.airbases[PAD] = base

    regen.init(function(message) r.logs[#r.logs+1] = message end)
    regen.queue_reseed(sides.BLUE, PAD, 1, 0)
    local queued = state.regen_queue[sides.BLUE].heli
    assert(#queued==1, 'the regen fixture did not queue exactly one helicopter')
    regen.schedule_regen(function(message) r.logs[#r.logs+1] = message end)
    -- Read the cadence off the timer the module itself registered: no literal period here.
    local period = r.timers[#r.timers].time
    assert(period and period > 0, 'regen registered no timer to drive')
    r.advance(period)
    assert(r.calls()==0, 'a refused regen still reached coalition.addGroup')
    assert(state.base_ledger[PAD].heli==2, 'a refused regen leaked its supply.consume debit')
    assert(#state.regen_queue[sides.BLUE].heli==1, 'a refused regen dequeued the entry it never spawned')
    assert(not r.contains('regen tick error'), 'a parking refusal escaped spawnRegen into the regen tick')
    assert(r.contains('no parking stand'), 'the regen refusal was not logged')
    -- Second tick: still refused, and STILL only the one debit -- the unwind is exactly once per
    -- attempt, not a slow leak repeated every cadence.
    r.advance(period * 3)
    assert(r.calls()==0 and state.base_ledger[PAD].heli==2,
        'repeated regen refusals drained the base reserve')
end

-- reaction.spawn_bda: existing failure path is `supply.recycle_base(home,'heli',1); return`, the
-- same one used when addGroup gives back nothing. spawn_bda runs straight off a reaction tick with
-- no pcall of its own, so the error must not leave the function at all.
do
    local r = runtime()
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local reaction = r.require_module('reaction')
    local PAD = 'FARP-BDA-Refusal'
    state.base_owner[PAD] = sides.BLUE
    state.base_health[PAD] = 1
    state.base_pos[PAD] = {x=100, z=200}
    state.base_kind[PAD] = 'farp'
    state.farp_active[PAD] = true
    state.base_ledger[PAD] = {striker=0, escort=0, heli=3, recon=0, transport=0, vehicle=0}
    local base = farp_airbase({[0]=true, [1]=true, [2]=true, [3]=true}, 92)
    function base:getName() return PAD end
    r.airbases[PAD] = base

    local target = {x=9000, z=9000}
    local ok, err = pcall(reaction.spawn_bda, sides.BLUE, 'TARGET-BASE', target,
        function(message) r.logs[#r.logs+1] = message end)
    assert(ok, 'a parking refusal escaped reaction.spawn_bda: '..tostring(err))
    assert(r.calls()==0, 'a refused BDA still reached coalition.addGroup')
    assert(state.base_ledger[PAD].heli==3, 'a refused BDA leaked its consume_base debit')
    assert((state.base_inflight[PAD] or 0)==0, 'a refused BDA took a keysite launch slot')
    assert(r.contains('no parking stand'), 'the BDA refusal was not logged')
end

-- supply_flight.buildSupplyFlight: existing failure path is `supply.refund_crate` + return nil.
-- task_board's pcall already reverses the transport debit, but NOT the crate this builder took
-- with deliver_crate, so the crate has to come back here and exactly here.
do
    local r = runtime()
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local board = r.require_module('task_board')
    local supply = r.require_module('supply')
    local flight = r.require_module('supply_flight')
    local PAD, CONSUMER = 'FARP-Supply-Refusal', 'FARP-Consumer'
    for _, name in ipairs({PAD, CONSUMER}) do
        state.base_owner[name] = sides.BLUE
        state.base_health[name] = 1
        state.base_kind[name] = 'farp'
        state.farp_active[name] = true
        state.base_ledger[name] = {striker=0, escort=0, heli=0, recon=0, transport=0, vehicle=0}
    end
    state.base_pos[PAD] = {x=100, z=200}
    state.base_pos[CONSUMER] = {x=5000, z=5000}
    state.base_ledger[PAD].transport = 2
    state.keysites['PROD'] = {kind='factory', side=sides.BLUE, pos={x=2000, z=2000}, health=1,
                              alive=1, producer={ammo=1, fuel=1}}
    local base = farp_airbase({[0]=true, [1]=true, [2]=true, [3]=true}, 93)
    function base:getName() return PAD end
    r.airbases[PAD] = base

    -- Bank crates directly: supply.init() would also rebuild the base ledger this fixture set.
    state.production[sides.BLUE] = {ammo=30, fuel=30, ammo_rr=0, fuel_rr=0, ammo_earmark=0, fuel_earmark=0}
    local banked = state.production[sides.BLUE].ammo
    assert(supply.free_crate(sides.BLUE, 'ammo'), 'the supply fixture banked no crate to fly')
    assert(flight.request(sides.BLUE, CONSUMER, 'ammo', function(message) r.logs[#r.logs+1] = message end),
        'the supply request was never queued')
    local ok, err = pcall(board.tick, function(message) r.logs[#r.logs+1] = message end)
    assert(ok, 'a parking refusal escaped the task_board tick: '..tostring(err))
    assert(r.calls()==0, 'a refused supply flight still reached coalition.addGroup')
    assert(state.production[sides.BLUE].ammo==banked, 'a refused supply flight leaked its crate')
    assert(state.base_ledger[PAD].transport==2, 'a refused supply flight leaked its transport debit')
    assert(r.contains('no parking stand'), 'the supply refusal was not logged')
end
print('PASS aircraft-lifecycle defect 3b (P2 follow-up): a parking refusal at regen / reaction BDA / supply_flight spawns nothing, escapes no caller, and unwinds its own debit exactly once')

--------------------------------------------------------------------------------------------------
-- Defect 2 (epic #17 P3 — "per-aircraft recovery/loss settlement") — FIXED, asserts TARGET
--------------------------------------------------------------------------------------------------
-- The defect was: supply.make_land_handler() settled the WHOLE group on the FIRST member's
-- S_EVENT_LAND — it credited `#group:getUnits()` airframes, released the keysite slot, and
-- scheduled `group:destroy()` — and it chose the recovery base by "nearest friendly base anywhere
-- on the map" rather than by reading the event.
--
-- Three MEASURED facts (docs/bots/LIVE-PROBE-2026-09-22.md findings 6-7, raw capture at
-- dcs-bugs/aircraft-lifecycle/probe-events-pre-p2.txt: 219 events, 9 landings, clock t=5729):
--   * S_EVENT_LAND carries a real `place` with getName()/getID()/getDesc().category at both an
--     airdrome (Kutaisi id=25 cat=0) and an authored FARP (FARP-... id=3 cat=1);
--   * CRASH (5) and DEAD (8) carry place=nil — a loss has no site;
--   * RUNWAY_TOUCH (55) fires for a crash as well as for a recovery.
-- And the killer sequence, captured live rather than imagined:
--     t=1953 id=55 Heli-CAS-1-2055-1   t=1954 id=5 Heli-CAS-1-2055-1 place=nil
--     t=1955 id=55 Heli-CAS-1-2055-2   t=1956 id=4 Heli-CAS-1-2055-2 place=FARP(id=3)
-- Under the old handler member 2's landing credited the CRASHED airframe as a recovery and
-- despawned the group. Those exact timings are the fixture below.
--
-- TARGET now asserted: settlement is per AIRFRAME and exactly once, its authority is the P1
-- allocation's debited role and expected unit names (not supply.classify_role's name prefix), a
-- landing only starts an EVALUATION, and ledger credit is coupled to the airframe actually
-- leaving the world.

-- The four-pad FARP and the airdrome the probe recorded, as event `place` objects.
local function site(name, id, category)
    return {getName=function() return name end, getID=function() return id end,
            getDesc=function() return {category=category or 0} end}
end

-- A campaign base the settlement can recognise, with a ledger to credit into.
local function own_base(state, sides, name, side, kind)
    state.base_owner[name] = side or sides.BLUE
    state.base_health[name] = 1
    state.base_pos[name] = {x=0, z=0}
    state.base_kind[name] = kind or 'airbase'
    state.base_ledger[name] = {striker=0, escort=0, heli=0, recon=0, transport=0, vehicle=0}
end

-- One spawned group of `n` airframes, live in the fake DCS world, with its P1 allocation facts
-- registered exactly as commit_allocation does for a tracked builder.
local function flight(r, lifecycle, state, sides, group_name, n, facts)
    facts = facts or {}
    local units = {}
    for i = 1, n do units[i] = {name=group_name..'-'..i, type='Mi-24V', x=0, y=0} end
    local group = r.materialise(2, {name=group_name, units=units}, n)
    local names = {}
    for i, u in ipairs(units) do names[i] = u.name end
    lifecycle.register_sortie({
        group_name = group_name,
        side = facts.side or sides.BLUE,
        role = facts.role or 'heli',
        debit_base = facts.debit_base,
        unit_names = names,
        budget = facts.budget,
        task_type = facts.task_type,
        target_base = facts.target_base,
        tracked = true,
    })
    if facts.debit_base then
        state.group_launch_base[group_name] = facts.debit_base
        state.base_inflight[facts.debit_base] = (state.base_inflight[facts.debit_base] or 0) + 1
    end
    return group, names
end

-- The production handler set for these events, registered in the production order
-- (game_loop.ts:169-172): regen DEAD, supply LAND, reaction.
local function settlement_case()
    local r = runtime()
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local supply = r.require_module('supply')
    local lifecycle = r.require_module('aircraft_lifecycle')
    local regen = r.require_module('regen')
    local reaction = r.require_module('reaction')
    r.handlers[regen.make_dead_handler(function(m) r.logs[#r.logs+1]=m end)] = true
    r.handlers[supply.make_land_handler(function(m) r.logs[#r.logs+1]=m end)] = true
    r.handlers[reaction.make_event_handler(function(m) r.logs[#r.logs+1]=m end)] = true
    return {r=r, state=state, sides=sides, supply=supply, lifecycle=lifecycle}
end

-- supply.ts's own LANDED_GROUP_CLEANUP_DELAY_SECONDS; P3 introduces no new cadence of its own.
local CLEANUP_DELAY = 30

-- 1. STAGGERED TWO-SHIP LANDING. The first member's landing must not credit, release or destroy
--    anything belonging to the member still in the air.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'farp')
    local group, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-CAS-1-2055', 2,
        {debit_base='HOME'})
    local place = site('HOME', 3, 1)

    -- Probe spacing: RUNWAY_TOUCH one second before the LAND it belongs to.
    c.r.advance(1955)
    c.r.emit(c.r.e.world.event.S_EVENT_RUNWAY_TOUCH, c.r.units[names[1]], place)
    c.r.advance(1956)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], place)
    assert(c.state.base_ledger.HOME.heli==0,
        'a landing credited the ledger before the airframe left the world')
    assert(c.lifecycle.member_state(names[1])=='returned', 'member 1 was not recorded as returned')
    assert(c.lifecycle.member_state(names[2])=='outbound',
        'the landing of member 1 settled its still-airborne wingman')
    assert(c.r.units[names[2]].alive, 'the airborne wingman was destroyed by its leader landing')
    assert(group:isExist(), 'the whole group was destroyed on the first member landing')
    assert(c.state.base_inflight.HOME==1, 'the launch slot was released while a member was still up')

    c.r.advance(1956 + CLEANUP_DELAY)
    assert(c.r.destroys[names[1]]==1, 'the recovered airframe was not retired')
    assert(c.r.units[names[2]].alive, 'the cleanup destroyed the airborne wingman')
    assert(c.state.base_ledger.HOME.heli==1,
        'exactly one airframe should be credited: got '..tostring(c.state.base_ledger.HOME.heli))
    assert(c.state.base_inflight.HOME==1, 'the launch slot went back before the sortie finished')

    -- Wingman comes home four seconds later.
    c.r.advance(1960)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[2]], place)
    c.r.advance(1960 + CLEANUP_DELAY)
    assert(c.r.destroys[names[2]]==1, 'the second airframe was never retired')
    assert(c.state.base_ledger.HOME.heli==2, 'the two-ship did not return exactly two airframes')
    assert(c.state.base_inflight.HOME==0, 'the launch slot was never released')
    assert(c.state.group_launch_base['Heli-CAS-1-2055']==nil, 'slot ownership survived the sortie')
    assert(c.lifecycle.stats().credited_airframes==2 and c.lifecycle.stats().refused_credits==0)
end

-- 2. THE CAPTURED FIXTURE: one return plus one loss, two seconds apart, at a FARP.
--    RUNWAY_TOUCH must be inert; the crashed airframe must never be credited.
do
    local c = settlement_case()
    local FARP = 'FARP-farp_H3-852d527bfffffff-1'
    own_base(c.state, c.sides, FARP, c.sides.BLUE, 'farp')
    local group, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-CAS-1-2055', 2,
        {debit_base=FARP})
    local pad = site(FARP, 3, 1)

    c.r.advance(1953); c.r.emit(c.r.e.world.event.S_EVENT_RUNWAY_TOUCH, c.r.units[names[1]], pad)
    assert(c.lifecycle.member_state(names[1])=='outbound',
        'RUNWAY_TOUCH was treated as a completed recovery')
    -- CRASH carries place=nil, as measured on every one of the capture's 12 crashes.
    c.r.advance(1954); c.r.units[names[1]].alive=false
    c.r.emit(c.r.e.world.event.S_EVENT_CRASH, c.r.units[names[1]], nil)
    assert(c.lifecycle.member_state(names[1])=='lost', 'the crashed airframe was not marked lost')
    c.r.advance(1955); c.r.emit(c.r.e.world.event.S_EVENT_RUNWAY_TOUCH, c.r.units[names[2]], pad)
    c.r.advance(1956); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[2]], pad)
    assert(group:isExist(), 'the surviving member landing destroyed the group')

    c.r.advance(1956 + CLEANUP_DELAY)
    assert(c.state.base_ledger[FARP].heli==1,
        'a crashed airframe was credited as a recovery: got '..
        tostring(c.state.base_ledger[FARP].heli))
    assert(c.r.destroys[names[1]]==nil, 'the cleanup re-destroyed an already crashed airframe')
    assert(c.r.destroys[names[2]]==1, 'the recovered airframe was not retired')
    assert(c.state.base_inflight[FARP]==0,
        'the launch slot was not released once every airframe was resolved')
    assert(c.lifecycle.stats().confirmed_losses==1 and c.lifecycle.stats().credited_airframes==1)
end

-- 3. A LOSS AFTER TOUCHDOWN, ALSO CAPTURED: t=2160 LAND then t=2161 CRASH, same airframe. The
--    credit is coupled to retirement, so the airframe that died on the pad is never credited.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'farp')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-CAS-1-2061', 1,
        {debit_base='HOME'})
    local pad = site('HOME', 3, 1)
    c.r.advance(2160); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], pad)
    c.r.advance(2161); c.r.units[names[1]].alive=false
    c.r.emit(c.r.e.world.event.S_EVENT_CRASH, c.r.units[names[1]], nil)
    c.r.advance(2161 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.heli==0,
        'an airframe lost seconds after touchdown was credited as recovered stock')
    assert(c.state.base_inflight.HOME==0, 'the launch slot leaked after the loss')
end

-- 4. CRASH BEFORE TAKEOFF (probe finding 8: Heli-CAS-2-2062-2 died at age 44 s, on the pad). No
--    landing ever happens for that airframe and nothing may ever credit it.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'farp')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-CAS-2-2062', 2,
        {debit_base='HOME'})
    c.r.advance(1125); c.r.units[names[2]].alive=false
    c.r.emit(c.r.e.world.event.S_EVENT_CRASH, c.r.units[names[2]], nil)
    assert(c.state.base_ledger.HOME.heli==0, 'a departure crash credited the ledger')
    c.r.advance(2845); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('HOME',2,1))
    c.r.advance(2845 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.heli==1,
        'the survivor credited the departure-crashed wingman too: got '..
        tostring(c.state.base_ledger.HOME.heli))
end

-- 5. DUPLICATE AND OUT-OF-ORDER EVENTS are idempotent: repeated LAND, repeated CRASH, and a DEAD
--    arriving after the CRASH for the same airframe.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'farp')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-CAS-1-2063', 2,
        {debit_base='HOME'})
    local pad = site('HOME', 3, 1)
    c.r.advance(3060)
    for _ = 1, 3 do c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], pad) end
    c.r.advance(3060 + CLEANUP_DELAY)
    assert(c.r.destroys[names[1]]==1, 'three LAND events retired the airframe more than once')
    assert(c.state.base_ledger.HOME.heli==1, 'a duplicate LAND credited twice')
    -- A LAND arriving after the airframe has already been retired changes nothing.
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], pad)
    assert(c.state.base_ledger.HOME.heli==1, 'a LAND after retirement credited a second time')

    c.r.units[names[2]].alive=false
    for _ = 1, 2 do c.r.emit(c.r.e.world.event.S_EVENT_CRASH, c.r.units[names[2]], nil) end
    c.r.emit(c.r.e.world.event.S_EVENT_DEAD, c.r.units[names[2]], nil)
    assert(c.lifecycle.stats().confirmed_losses==1, 'one airframe was counted lost repeatedly')
    assert(c.state.base_ledger.HOME.heli==1, 'a loss event credited the ledger')
    assert(c.state.base_inflight.HOME==0, 'the slot was not released once everything was resolved')
end

-- 6. A TRANSIENTLY MISSING UNIT IS NOT A DEAD ONE. The wingman is not answerable through
--    Unit.getByName, which must not resolve it as lost.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'farp')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-CAS-1-2073', 2,
        {debit_base='HOME'})
    local hidden = c.r.units[names[2]]
    c.r.units[names[2]] = nil     -- the query answers "not there" without any loss event
    c.r.advance(2000); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('HOME',3,1))
    c.r.advance(2000 + CLEANUP_DELAY)
    assert(hidden.alive, 'test setup drifted: the hidden wingman must still be flying')
    assert(c.lifecycle.member_state(names[2])=='outbound',
        'an unanswerable unit query was treated as a confirmed loss')
    assert(c.state.base_ledger.HOME.heli==1, 'the credit for the airframe that did land was lost')
    assert(c.state.base_inflight.HOME==1,
        'the slot was released while one airframe was still unaccounted for')
    local pending = c.lifecycle.unsettled_sorties()
    assert(#pending==1 and pending[1]=='Heli-CAS-1-2073',
        'the unresolved sortie stopped being visible')
end

-- 7. AN INTERMEDIATE MISSION LANDING IS NOT A RECOVERY. A supply flight delivering at the
--    consumer base, and a troop insertion setting down off-field, must not recycle the airframe —
--    and the metadata that proves it must survive cs.clear_task().
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'farp')
    own_base(c.state, c.sides, 'CONSUMER', c.sides.BLUE, 'farp')
    local cstate = c.r.require_module('campaign_state')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Supply-2080', 1,
        {role='transport', debit_base='HOME', task_type='supply', target_base='CONSUMER'})
    cstate.register_task('Supply-2080', {task_type='supply', side=c.sides.BLUE,
        target_base='CONSUMER'})
    -- reaction clears the task on the same LAND; the recovery record must not depend on it.
    cstate.clear_task('Supply-2080')
    assert(cstate.get_task('Supply-2080')==nil, 'test setup: the task should be gone')

    c.r.advance(3000)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('CONSUMER', 9, 1))
    c.r.advance(3000 + CLEANUP_DELAY)
    assert(c.state.base_ledger.CONSUMER.transport==0 and c.state.base_ledger.HOME.transport==0,
        'a delivery landing at the objective recycled the airframe')
    assert(c.r.destroys[names[1]]==nil, 'a delivery landing despawned the aircraft mid-mission')
    assert(c.state.base_inflight.HOME==1, 'a delivery landing released the launch slot')

    -- Off-field: a troop insertion sets down in open country, so the event carries no place at
    -- all. CRASH and DEAD carry place=nil too, so a missing site is never read as a landing.
    c.r.advance(3100)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], nil)
    c.r.advance(3100 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.transport==0 and c.state.base_ledger.CONSUMER.transport==0,
        'an off-field landing with no place was credited as a recovery')
    assert(c.r.destroys[names[1]]==nil, 'an off-field landing despawned the aircraft')

    -- Home at last: a landing that is NOT the objective, at a friendly site, is the recovery.
    c.r.advance(3400)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('HOME', 3, 1))
    c.r.advance(3400 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.transport==1, 'the RTB leg was not credited')
    assert(c.r.destroys[names[1]]==1, 'the recovered transport was not retired')
    assert(c.state.base_inflight.HOME==0, 'the slot was not released on the genuine recovery')
end

-- 8. A VALID DIVERSION still recovers the airframe, and it recovers it AT THE RECEIVING BASE --
--    which is deliberately not the base whose ledger was debited.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'LAUNCH', c.sides.BLUE, 'airbase')
    own_base(c.state, c.sides, 'DIVERT', c.sides.BLUE, 'airbase')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Recon-2-2076', 1,
        {role='recon', debit_base='LAUNCH'})
    c.r.advance(4395)
    -- Kutaisi, exactly as the capture reports it: id=25, category 0 (AIRDROME).
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('DIVERT', 25, 0))
    c.r.advance(4395 + CLEANUP_DELAY)
    assert(c.state.base_ledger.DIVERT.recon==1, 'the diversion base did not receive the airframe')
    assert(c.state.base_ledger.LAUNCH.recon==0, 'the credit went to the debit base, not the site')
    assert(c.state.base_inflight.LAUNCH==0, 'the launch slot at the ORIGINAL base was not released')
end

-- 9. MISSING OR ENEMY LANDING-SITE EVIDENCE credits nothing. An unknown site is unknown, not
--    friendly; an enemy field is a capture, not a recovery.
do
    for _, leg in ipairs({{name='STRANGER', id=404}, {name='ENEMY', id=7}}) do
        local c = settlement_case()
        own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'airbase')
        own_base(c.state, c.sides, 'ENEMY', c.sides.RED, 'airbase')
        local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Strike-2064', 1,
            {role='striker', debit_base='HOME'})
        c.r.advance(2170)
        c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site(leg.name, leg.id, 0))
        c.r.advance(2170 + CLEANUP_DELAY)
        assert(c.state.base_ledger.HOME.striker==0,
            leg.name..': a landing with no usable friendly site credited the reserve')
        assert(c.state.base_ledger.ENEMY.striker==0, leg.name..': the enemy was credited')
        assert(c.r.destroys[names[1]]==nil, leg.name..': the aircraft was retired on weak evidence')
        assert(c.state.base_inflight.HOME==1, leg.name..': the launch slot was released')
    end
end

-- 10. ROLE / NAME MISMATCH. The allocation is the authority: a group whose NAME prefix classifies
--     as one role but whose debit was taken against another must credit the DEBITED role.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'airbase')
    assert(c.supply.classify_role('Strike-Mislabelled')=='striker',
        'test setup: the name prefix must classify differently from the allocation role')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Strike-Mislabelled', 1,
        {role='recon', debit_base='HOME'})
    c.r.advance(1712)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('HOME', 25, 0))
    c.r.advance(1712 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.recon==1, 'the credit did not follow the allocation role')
    assert(c.state.base_ledger.HOME.striker==0,
        "supply.classify_role's name prefix overrode the allocation")
end

-- 11. EXPIRY AFTER AN EARLIER SETTLEMENT. One airframe is already home and credited; resolving
--     the rest of the sortie must not invent a second credit, and a late LAND for an airframe
--     that was already settled must not either.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'farp')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-BAI-1-2066', 2,
        {debit_base='HOME'})
    local pad = site('HOME', 4, 1)
    c.r.advance(2668); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], pad)
    c.r.advance(2668 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.heli==1)
    assert(c.lifecycle.resolve_sortie('Heli-BAI-1-2066', 'task expired')==true)
    assert(c.state.base_ledger.HOME.heli==1, 'expiry credited an airframe with no recovery evidence')
    assert(c.state.base_inflight.HOME==0, 'expiry did not give the launch slot back')
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], pad)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[2]], pad)
    c.r.advance(3000)
    assert(c.state.base_ledger.HOME.heli==1, 'a landing after expiry re-credited a settled sortie')
    assert(c.lifecycle.resolve_sortie('Heli-BAI-1-2066', 'again')==false,
        'resolving an already resolved sortie reported fresh work')
end

-- 12. REINJECTION BEFORE CLEANUP. The generation moved between the landing and the retirement:
--     the new campaign's ledger must not be credited and the old campaign's aircraft must not be
--     despawned out from under it.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'farp')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-CAS-2-2079', 1,
        {debit_base='HOME'})
    c.r.advance(3034); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('HOME',1,1))
    c.r.e._DMT_GEN = c.r.e._DMT_GEN + 1
    c.r.advance(3034 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.heli==0, 'a stale settlement credited the new campaign')
    assert(c.r.destroys[names[1]]==nil, 'a stale settlement destroyed an aircraft')
end

-- 13. PLAYERS ARE FIRST-CLASS, including inside the delayed callback. A player landing settles
--     nothing at all, and a human who takes the aircraft between the landing and the cleanup is
--     never despawned and never counted as returned stock.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'airbase')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Escort-2069', 2,
        {role='escort', debit_base='HOME'})
    c.r.units[names[1]].player = 'Human Pilot'
    c.r.advance(3915); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('HOME',25,0))
    c.r.advance(3915 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.escort==0, 'a player landing was recycled into the reserve')
    assert(c.r.destroys[names[1]]==nil, 'a player aircraft was despawned')
    assert(c.lifecycle.member_state(names[1])=='outbound', 'a player airframe was settled')

    -- AI lands, human slots in before the cleanup fires.
    c.r.advance(4000); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[2]], site('HOME',25,0))
    c.r.units[names[2]].player = 'Latecomer'
    c.r.advance(4000 + CLEANUP_DELAY)
    assert(c.r.destroys[names[2]]==nil, 'a player took the aircraft and it was destroyed anyway')
    assert(c.state.base_ledger.HOME.escort==0,
        'an aircraft still flyable under a player was also counted as idle stock')
    assert(c.lifecycle.member_state(names[2])=='resolved', 'the player takeover was not resolved')
end

-- 14. CLEANUP-GENERATED DEATH IS NOT A COMBAT LOSS. The DEAD that follows our own retirement must
--     not queue a regeneration or terminate the mission as a failure.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'farp')
    local cstate = c.r.require_module('campaign_state')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-CAS-1-2075', 1,
        {debit_base='HOME'})
    cstate.register_task('Heli-CAS-1-2075', {task_type='cas', side=c.sides.BLUE, target_base='HOME2'})
    local queued = function()
        local total = 0
        for _, by_role in pairs(c.state.regen_queue) do
            for _, entries in pairs(by_role) do total = total + #entries end
        end
        return total
    end
    local before = queued()
    c.r.advance(3060); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('HOME',3,1))
    c.r.advance(3060 + CLEANUP_DELAY)
    assert(c.r.destroys[names[1]]==1 and c.state.base_ledger.HOME.heli==1)
    assert(c.lifecycle.is_retired_unit(names[1]), 'the retired airframe was not recorded as retired')
    -- DCS reports the despawn. It must be inert.
    c.r.emit(c.r.e.world.event.S_EVENT_DEAD, c.r.units[names[1]], nil)
    assert(queued()==before, 'our own cleanup queued a regeneration')
    assert(c.state.base_ledger.HOME.heli==1, 'the cleanup death moved the ledger')
    assert(c.lifecycle.stats().confirmed_losses==0, 'the cleanup death was counted as a combat loss')
end

-- 15. END TO END through the real production builder at a FARP: the P2 stand lease is held for
--     the whole departure and released only on genuine retirement, one pad per airframe.
do
    local r = runtime()
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local board = r.require_module('task_board')
    local heli_war = r.require_module('heli_war')
    local supply = r.require_module('supply')
    local lifecycle = r.require_module('aircraft_lifecycle')
    r.handlers[supply.make_land_handler(function(m) r.logs[#r.logs+1]=m end)] = true
    local PAD = 'FARP-Recovery'
    state.base_owner[PAD] = sides.BLUE
    state.base_health[PAD] = 1
    state.base_pos[PAD] = {x=100, z=200}
    state.base_kind[PAD] = 'farp'
    state.farp_active[PAD] = true
    state.base_ledger[PAD] = {striker=0, escort=0, heli=4, recon=0, transport=0, vehicle=0}
    local base = farp_airbase({}, 3)
    function base:getName() return PAD end
    r.airbases[PAD] = base

    local task = board.create_task({
        type='cas', side=sides.BLUE, count=2, immediate=true, target={pos={x=4000, z=4000}},
        builder=function(_, b) return heli_war.build_attack_heli(sides.BLUE, b, {x=4000, z=4000}, 'cas') end,
    })
    assert(task.state=='ASSIGNED', 'the production CAS section was not assigned')
    local group_name = task.assigned_group
    assert(queue.drain()>=1, 'the deferred spawn never drained')
    assert(#lifecycle.leased_stands(PAD)==2, 'the section did not hold one stand per airframe')
    assert(lifecycle.sortie_of(group_name)~=nil, 'the production builder registered no sortie')
    assert(state.base_ledger[PAD].heli==2, 'the board did not debit SECTION_SIZE airframes')

    local members = {}
    for _, unit in ipairs(r.groups[group_name]:getUnits()) do members[#members+1] = unit:getName() end
    assert(#members==2)
    local pad_place = site(PAD, 3, 1)
    r.advance(1956); r.emit(r.e.world.event.S_EVENT_LAND, r.units[members[1]], pad_place)
    assert(#lifecycle.leased_stands(PAD)==2,
        'a stand was released at the landing rather than at the retirement')
    r.advance(1956 + CLEANUP_DELAY)
    assert(#lifecycle.leased_stands(PAD)==1, 'the retired airframe did not give its pad back')
    assert(lifecycle.stand_holder(PAD, lifecycle.leased_stands(PAD)[1])==group_name,
        'the surviving airframe lost its own pad')
    r.advance(2000); r.emit(r.e.world.event.S_EVENT_LAND, r.units[members[2]], pad_place)
    r.advance(2000 + CLEANUP_DELAY)
    assert(#lifecycle.leased_stands(PAD)==0, 'the finished sortie kept its pads')
    assert(state.base_ledger[PAD].heli==4, 'the section did not return exactly what it took')
    assert((state.base_inflight[PAD] or 0)==0, 'the finished sortie kept its launch slot')
end

-- 16. NO NEGATIVE, NO LEAKED AND NO DUPLICATED COUNTERS. Whatever order the evidence arrives in,
--     a sortie can never return more hardware than the allocation debited.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'farp')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-CAS-2-2060', 2,
        {debit_base='HOME', budget=2})
    local pad = site('HOME', 2, 1)
    -- An extra airframe DCS reports under the same group name (a replacement slot): tracked, but
    -- it cannot push the sortie past what was paid for.
    c.r.materialise(2, {name='Heli-CAS-2-2060-extra',
        units={{name='Heli-CAS-2-2060-3', x=0, y=0}}}, 1)
    c.r.advance(1269)
    for _, unit_name in ipairs({names[1], names[2]}) do
        c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[unit_name], pad)
    end
    c.r.advance(1269 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.heli==2, 'the two-ship did not return exactly two airframes')
    -- A third airframe claiming the same sortie is tracked but cannot be paid for.
    local extra = c.lifecycle.settle_landing({group_name='Heli-CAS-2-2060',
        unit_name='Heli-CAS-2-2060-3', side=c.sides.BLUE, place=pad, player=false,
        member_names={}, cleanup_delay=CLEANUP_DELAY})
    assert(extra.verdict=='budget_exhausted',
        'an unbudgeted airframe was accepted as a recovery: '..tostring(extra.verdict))
    c.r.advance(1400)
    assert(c.state.base_ledger.HOME.heli==2,
        'more airframes came back than were ever debited: got '..
        tostring(c.state.base_ledger.HOME.heli))
    assert(c.lifecycle.stats().refused_credits>=1, 'the conservation guard never fired')
    assert((c.state.base_inflight.HOME or 0)==0, 'the launch-slot counter leaked')
    for _, ledger in pairs(c.state.base_ledger) do
        for role, count in pairs(ledger) do
            assert(count>=0, 'ledger went negative for '..role)
        end
    end
end
-- 17. THE UNTRACKED FALLBACK still works, and it is still PER AIRFRAME. Every caller that P1 did
--     not bring under begin_allocation (escorts, reaction CAP/BDA, troop, supply flights) reaches
--     settlement with no allocation record at all, so the group-name role guess survives as the
--     documented fallback until P4 closes it -- but the per-aircraft discipline does not depend
--     on it.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'airbase')
    local units = {{name='Escort-2065-1', x=0, y=0}, {name='Escort-2065-2', x=0, y=0}}
    c.r.materialise(2, {name='Escort-2065', units=units}, 2)
    c.state.group_launch_base['Escort-2065'] = 'HOME'
    c.state.base_inflight.HOME = 1
    assert(c.lifecycle.sortie_of('Escort-2065')==nil, 'test setup: this group must be untracked')
    local pad = site('HOME', 25, 0)
    c.r.advance(2143); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units['Escort-2065-1'], pad)
    c.r.advance(2143 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.escort==1,
        'the untracked fallback credited the wrong number of airframes: got '..
        tostring(c.state.base_ledger.HOME.escort))
    assert(c.r.units['Escort-2065-2'].alive, 'the untracked fallback despawned an airborne wingman')
    assert(c.state.base_inflight.HOME==1, 'the untracked fallback released the slot too early')
    c.r.advance(2400); c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units['Escort-2065-2'], pad)
    c.r.advance(2400 + CLEANUP_DELAY)
    assert(c.state.base_ledger.HOME.escort==2, 'the untracked pair did not return two airframes')
    assert(c.state.base_inflight.HOME==0, 'the untracked sortie kept its launch slot')
end

-- 18. A GROUP WITH NO RESERVE ROLE AT ALL settles nothing and is left alone: the launch slot goes
--     back (exactly what the pre-P3 handler did for an unclassified group) and no aircraft that
--     this module cannot account for is destroyed.
do
    local c = settlement_case()
    own_base(c.state, c.sides, 'HOME', c.sides.BLUE, 'airbase')
    assert(c.supply.classify_role('Mystery-2099')==nil, 'test setup: this name must not classify')
    c.r.materialise(2, {name='Mystery-2099', units={{name='Mystery-2099-1', x=0, y=0}}}, 1)
    c.state.group_launch_base['Mystery-2099'] = 'HOME'
    c.state.base_inflight.HOME = 1
    c.r.advance(5000)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units['Mystery-2099-1'], site('HOME', 25, 0))
    c.r.advance(5000 + CLEANUP_DELAY)
    assert(c.state.base_inflight.HOME==0, 'an unclassified landing kept the launch slot')
    assert(c.r.destroys['Mystery-2099-1']==nil,
        'an aircraft with no accountable role was destroyed anyway')
    for _, count in pairs(c.state.base_ledger.HOME) do
        assert(count==0, 'an unclassified landing credited the reserve')
    end
end

print("PASS aircraft-lifecycle defect 2 (P3 TARGET): settlement is per airframe and exactly once, driven by the allocation role and the LAND event's own site identity; staggered returns, the captured crash+land pair, post-touchdown losses, duplicates, transient gaps, intermediate mission landings, diversions, unknown/enemy sites, expiry, reinjection, player takeover and cleanup-generated deaths all settle correctly")

--------------------------------------------------------------------------------------------------
-- Defect 4 (epic #17 P4 — "caller integration") — FIXED, asserts TARGET
--------------------------------------------------------------------------------------------------
-- Two defects, both recorded by P1/P3 and both closed here.
--
-- (a) FOUR TIMERS PERFORMED VIRTUAL RETIREMENT OUTSIDE THE CONTRACT. reaction's CAP station
--     expiry, the BDA loiter, supply_flight's route backstop and troop's insertion TTL each
--     hand-rolled their own recycle / release_slot / destroy / clear_task. The supply backstop
--     credited by GROUP name (S._recycled[group]) while aircraft_lifecycle credited by UNIT name
--     (S._recycled[unit]), so the two guards could not see each other: a flight that landed home
--     and was then swept by its backstop before its ~30 s retirement was CREDITED TWICE.
--     ADR 0010 recorded that race as bounded and owned by P4.
--
-- (b) FIVE CALLERS SPAWNED AIRCRAFT WITH NO ALLOCATION RECORD, so a drain-time nil refunded
--     nothing: regen, reaction's CAP, reaction's BDA, and the two inline escorts
--     (cas_bai_sead's SEAD escort, attack_waves' strike escort). troop's insert and
--     supply_flight's supply flight DID have a task_board allocation but never called track(),
--     so commit_allocation saw no attempt and no recovery record was opened either.
--
-- TARGET now asserted: every aircraft path has exactly ONE owner of its reserve credit, its
-- keysite launch slot and its stand leases; a timer-driven end-of-sortie is labelled as the
-- VIRTUAL RETIREMENT proxy it is (recycled / abandoned) rather than passed off as an RTB; and a
-- proven no-creation gives back the exact debit the caller took, whoever the caller is.

-- A plain (non-helipad) airbase: configureDeparture resolves the stand from airdromeId, so these
-- legs exercise the accounting without the FARP stand-lease path on top.
local function plain_airbase(r, name, id)
    local base = {
        getID=function() return id end,
        getName=function() return name end,
        getPosition=function() return {p={x=0, y=20, z=0}} end,
        getDesc=function() return {category=0} end,
    }
    r.airbases[name] = base
    return base
end

-- Full production wiring: spawn_queue interception first (as main.ts does), then the three
-- registered event handlers in their production order (game_loop.ts:169-172).
local function p4_case()
    local r = runtime('ok')
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local lifecycle = r.require_module('aircraft_lifecycle')
    local supply = r.require_module('supply')
    local log = function(message) r.logs[#r.logs+1] = message end
    r.handlers[r.require_module('regen').make_dead_handler(log)] = true
    r.handlers[supply.make_land_handler(log)] = true
    r.handlers[r.require_module('reaction').make_event_handler(log)] = true
    return {r=r, queue=queue, state=state, sides=sides, lifecycle=lifecycle, supply=supply, log=log}
end

local function base_here(state, sides, name, kind, side)
    state.base_owner[name] = side or sides.BLUE
    state.base_health[name] = 1
    state.base_pos[name] = {x=0, z=0}
    state.base_kind[name] = kind or 'airbase'
    state.base_ledger[name] = {striker=0, escort=0, heli=0, recon=0, transport=0, vehicle=0}
end

-- Drains until the queue is empty, so a queued spawn actually reaches the fake DCS world.
local function drain_all(c)
    local guard = 0
    while #c.state.spawn_queue > 0 do
        c.queue.drain(function() end)
        guard = guard + 1
        assert(guard < 200, 'spawn queue never drained')
    end
end

-- The end-of-sortie timer the production code just registered, read off the harness rather than
-- assumed: no TTL, station-time, loiter or backstop literal appears anywhere in this file.
-- `mark` is #r.timers taken immediately before the action; the virtual-retirement timer is the
-- longest-dated of the ones registered since.
local function timer_mark(r) return #r.timers end
local function retirement_timer(r, mark)
    local best
    for index = mark + 1, #r.timers do
        local entry = r.timers[index]
        if entry.time and (not best or entry.time > best) then best = entry.time end
    end
    return best
end

-- 1. THE DOUBLE-CREDIT RACE, end to end through the real supply_flight builder and its real
--    route backstop. The flight lands home, and its backstop fires inside the retirement delay.
--    Exactly ONE transport airframe may come back.
do
    local c = p4_case()
    local board = c.r.require_module('task_board')
    local flights = c.r.require_module('supply_flight')
    base_here(c.state, c.sides, 'LAUNCH', 'airbase')
    base_here(c.state, c.sides, 'CONSUMER', 'airbase')
    c.state.base_pos.CONSUMER = {x=40000, z=40000}
    c.state.base_ledger.LAUNCH.transport = 4
    plain_airbase(c.r, 'LAUNCH', 41)
    plain_airbase(c.r, 'CONSUMER', 42)
    c.state.keysites['PROD'] = {kind='factory', side=c.sides.BLUE, pos={x=20000, z=20000},
                                health=1, alive=1, producer={ammo=1, fuel=1}}
    c.state.production[c.sides.BLUE] = {ammo=30, fuel=30, ammo_rr=0, fuel_rr=0, ammo_earmark=0, fuel_earmark=0}
    assert(c.supply.free_crate(c.sides.BLUE, 'ammo'), 'the fixture banked no crate to fly')
    assert(flights.request(c.sides.BLUE, 'CONSUMER', 'ammo', c.log), 'the supply request was never queued')
    local mark = timer_mark(c.r)
    board.tick(c.log)

    local group_name
    for name in pairs(c.state.active_tasks) do
        if name:match('^Supply%-') then group_name = name end
    end
    assert(group_name, 'no supply flight was dispatched')
    assert(c.state.base_ledger.LAUNCH.transport==3, 'the supply flight did not debit one transport')
    drain_all(c)
    local unit_name = group_name..'-1'
    assert(c.r.units[unit_name], 'the supply flight never reached the fake DCS world')

    -- The record was opened by the ALLOCATION (track() + commit_allocation), not by a name prefix.
    local sortie = c.lifecycle.sortie_of(group_name)
    assert(sortie and sortie.tracked==true, 'the supply flight was not brought under the allocation')
    assert(sortie.role=='transport', 'the sortie took its role from somewhere other than the allocation')

    local backstop = retirement_timer(c.r, mark)
    assert(backstop and backstop > c.r.now(), 'supply_flight registered no route backstop')

    -- Land home 10 s BEFORE the backstop, so the (delayed) retirement falls on the far side of it.
    -- This is the exact interleaving ADR 0010 recorded as an open race.
    c.r.advance(backstop - 10)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[unit_name], site('LAUNCH', 41, 0))
    assert(c.lifecycle.member_state(unit_name)=='returned', 'the landing did not start an evaluation')
    assert(c.state.base_ledger.LAUNCH.transport==3, 'the touchdown credited before retirement')

    c.r.advance(backstop)               -- backstop fires while the airframe is parked and uncredited
    assert(c.lifecycle.member_state(unit_name)=='retired', 'the backstop did not settle the airframe')
    c.r.advance(backstop - 10 + CLEANUP_DELAY + 1)   -- the retirement callback now runs too

    assert(c.state.base_ledger.LAUNCH.transport==4,
        'DOUBLE CREDIT: the backstop and the recovery both returned the same airframe ('
        ..tostring(c.state.base_ledger.LAUNCH.transport)..' transports at LAUNCH, expected 4)')
    -- reserve_side sums every owned base's ledger: the side's TOTAL idle stock.
    assert(c.supply.reserve_side(c.sides.BLUE, 'transport')==4,
        'the side-wide idle total disagrees with the base ledger')
    assert((c.state.base_inflight.LAUNCH or 0)==0, 'the launch slot was never released')
    assert(c.state.active_tasks[group_name]==nil, 'the backstop left the task record behind')

    local stats = c.lifecycle.stats()
    assert(stats.virtual_retirements==1, 'the backstop was not recorded as a virtual retirement')
    assert(stats.virtual_credits==1, 'the timer credit was not labelled as the proxy it is')
    assert(stats.credited_airframes==1, 'more than one airframe was credited')
end

-- 2. THE OTHER ORDER: the backstop fires while the flight is still airborne. Same single credit,
--    and the airframe is taken out of the world rather than left orphaned.
do
    local c = p4_case()
    base_here(c.state, c.sides, 'HOME', 'airbase')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Supply-4001', 1,
        {role='transport', debit_base='HOME'})
    c.r.advance(500)
    assert(c.lifecycle.retire_sortie('Supply-4001', 'backstop', 'recycled'), 'no record to retire')
    assert(c.supply.reserve_side(c.sides.BLUE, 'transport')==1,
        'the surviving airframe was not returned to the side reserve')
    assert(c.r.destroys[names[1]]==1, 'the swept airframe was left in the world')
    assert((c.state.base_inflight.HOME or 0)==0, 'the launch slot was not released')
    -- A late landing event for an airframe already settled must change nothing.
    c.r.advance(600)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('HOME', 3, 0))
    c.r.advance(600 + CLEANUP_DELAY + 1)
    assert(c.supply.reserve_side(c.sides.BLUE, 'transport')==1, 'a late landing credited an already-retired airframe')
    assert(c.state.base_ledger.HOME.transport==1, 'the credit did not land in the only owned base')
    -- Repeating the retirement is idempotent: one owner, one settlement.
    c.lifecycle.retire_sortie('Supply-4001', 'backstop again', 'recycled')
    assert(c.supply.reserve_side(c.sides.BLUE, 'transport')==1, 'a repeated virtual retirement credited twice')
end

-- 3. A LOST AIRFRAME IS NEVER RETURNED BY A TIMER. The crash beat the clock; the backstop must
--    not turn a wreck into stock.
do
    local c = p4_case()
    base_here(c.state, c.sides, 'HOME', 'airbase')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Supply-4002', 2,
        {role='transport', debit_base='HOME'})
    c.r.advance(400)
    c.r.emit(c.r.e.world.event.S_EVENT_CRASH, c.r.units[names[1]], nil)
    assert(c.lifecycle.member_state(names[1])=='lost', 'the crash was not recorded')
    c.r.advance(900)
    c.lifecycle.retire_sortie('Supply-4002', 'backstop', 'recycled')
    assert(c.supply.reserve_side(c.sides.BLUE, 'transport')==1,
        'the timer credited the confirmed loss as well as the survivor')
    assert(c.lifecycle.stats().confirmed_losses==1)
end

-- 4. PLAYERS ARE FIRST-CLASS INSIDE A DELAYED CALLBACK TOO. A timer must never despawn a human,
--    and an airframe we did not remove is never counted as returned stock.
do
    local c = p4_case()
    base_here(c.state, c.sides, 'HOME', 'airbase')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Supply-4003', 1,
        {role='transport', debit_base='HOME'})
    c.r.units[names[1]].player = 'Human Pilot'
    c.r.advance(900)
    c.lifecycle.retire_sortie('Supply-4003', 'backstop', 'recycled')
    assert(c.r.units[names[1]].alive, 'a virtual retirement destroyed a player-controlled aircraft')
    assert(c.r.destroys[names[1]]==nil, 'destroy() was called on a player aircraft')
    assert(c.supply.reserve_side(c.sides.BLUE, 'transport')==0 and c.state.base_ledger.HOME.transport==0,
        'a player aircraft was counted back into stock')
    assert((c.state.base_inflight.HOME or 0)==0, 'the launch slot was not released')
end

-- 5. reaction's CAP EXPIRY, end to end. The CAP is dispatched by the real under-attack path, its
--    debit is owned by an allocation, and the station-time timer settles it exactly once.
do
    local c = p4_case()
    local reaction = c.r.require_module('reaction')
    base_here(c.state, c.sides, 'DEFENDED', 'airbase')
    c.state.base_ledger.DEFENDED.escort = 2
    plain_airbase(c.r, 'DEFENDED', 51)

    reaction.on_keysite_under_attack('DEFENDED', c.log)
    local mark = timer_mark(c.r)
    c.r.advance(c.r.now() + 200)          -- past the response delay + jitter
    local cap_name
    for name in pairs(c.state.active_tasks) do if name:match('^CAP%-') then cap_name = name end end
    assert(cap_name, 'the under-attack reaction never dispatched a CAP')
    assert(c.state.base_ledger.DEFENDED.escort==1, 'the CAP did not debit one escort')
    assert(c.state.base_inflight.DEFENDED==1, 'the CAP did not reserve a launch slot')
    drain_all(c)
    local cap_unit = cap_name..'-1'
    assert(c.r.units[cap_unit], 'the CAP never reached the fake DCS world')
    local cap_sortie = c.lifecycle.sortie_of(cap_name)
    assert(cap_sortie and cap_sortie.tracked==true and cap_sortie.role=='escort',
        'the CAP was not brought under its own allocation')

    local expiry = retirement_timer(c.r, mark)
    assert(expiry, 'spawnCap registered no station-time timer')
    c.r.advance(expiry)
    assert(c.supply.reserve_side(c.sides.BLUE, 'escort')==2,
        'the expired CAP did not return its airframe (1 unspent + 1 recovered expected)')
    assert(c.r.destroys[cap_unit]==1, 'the expired CAP was left in the world')
    assert((c.state.base_inflight.DEFENDED or 0)==0, 'the expired CAP kept its launch slot')
    assert(c.state.active_tasks[cap_name]==nil, 'the expired CAP left its task record behind')
    assert(c.lifecycle.stats().virtual_credits==1, 'the CAP credit was not labelled as the timer proxy')
    -- Firing the same settlement again cannot manufacture a second airframe.
    c.lifecycle.retire_sortie(cap_name, 'expired again', 'recycled')
    assert(c.supply.reserve_side(c.sides.BLUE, 'escort')==2, 'a repeated CAP expiry credited twice')
end

-- 6. reaction's BDA LOITER, end to end: allocation-owned debit and slot, single settlement.
do
    local c = p4_case()
    local reaction = c.r.require_module('reaction')
    base_here(c.state, c.sides, 'HOME', 'airbase')
    base_here(c.state, c.sides, 'TARGET', 'airbase', c.sides.RED)
    c.state.base_pos.TARGET = {x=5000, z=5000}
    c.state.base_ledger.HOME.heli = 2
    plain_airbase(c.r, 'HOME', 61)

    -- The loiter callback re-runs reactReconKeysite, which scans live groups. DCS answers that;
    -- the fake boundary must too, or the settlement below would never be reached.
    c.r.e.coalition.getGroups = function() return {} end
    local mark = timer_mark(c.r)
    reaction.spawn_bda(c.sides.BLUE, 'TARGET', {x=5000, z=5000}, c.log)
    local bda_name
    for name in pairs(c.state.active_tasks) do if name:match('^BDA%-') then bda_name = name end end
    assert(bda_name, 'spawn_bda dispatched nothing')
    assert(c.state.base_ledger.HOME.heli==1, 'the BDA did not debit one heli')
    assert(c.state.base_inflight.HOME==1, 'the BDA did not reserve a launch slot')
    drain_all(c)
    local bda_unit = bda_name..'-1'
    local bda_sortie = c.lifecycle.sortie_of(bda_name)
    assert(bda_sortie and bda_sortie.tracked==true and bda_sortie.role=='heli',
        'the BDA was not brought under its own allocation')

    local loiter = retirement_timer(c.r, mark)
    assert(loiter, 'spawn_bda registered no loiter timer')
    c.r.advance(loiter)
    assert(c.supply.reserve_side(c.sides.BLUE, 'heli')==2,
        'the BDA airframe was not returned (1 unspent + 1 recovered expected)')
    assert(c.r.destroys[bda_unit]==1, 'the BDA was left in the world after its loiter')
    assert((c.state.base_inflight.HOME or 0)==0, 'the BDA kept its launch slot')
    assert(c.state.active_tasks[bda_name]==nil, 'the BDA left its task record behind')
end

-- 7. troop's INSERTION TTL is `abandoned`, not `recycled`. It has never returned its `transport`
--    debit, and P4 does not change that: the deferred asymmetry needs an EECH citation, not an
--    internal-consistency argument (sprint 04). What P4 changes is that the write-off now has one
--    owner and is recorded, so nothing can credit the airframe afterwards.
do
    local c = p4_case()
    base_here(c.state, c.sides, 'HOME', 'airbase')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Insert-4004', 2,
        {role='transport', debit_base='HOME', target_base='TARGET'})
    c.r.advance(500)
    assert(c.lifecycle.retire_sortie('Insert-4004', 'insertion TTL expired', 'abandoned'),
        'no record to abandon')
    assert(c.state.base_ledger.HOME.transport==0 and c.supply.reserve_side(c.sides.BLUE, 'transport')==0,
        'the TTL returned the transport debit — the deferred asymmetry was silently resolved')
    assert(c.r.destroys[names[1]]==nil and c.r.destroys[names[2]]==nil,
        'an abandoned insertion despawned its aircraft')
    assert((c.state.base_inflight.HOME or 0)==0, 'the abandoned insertion kept its launch slot')
    assert(c.lifecycle.member_state(names[1])=='resolved', 'the abandoned member was not closed out')
    local stats = c.lifecycle.stats()
    assert(stats.virtual_abandons==2 and stats.virtual_credits==0,
        'an abandoned insertion was not distinguished from a recycled retirement')
    -- And it can never be credited afterwards: the record is closed.
    c.r.advance(900)
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[names[1]], site('HOME', 3, 0))
    c.r.advance(900 + CLEANUP_DELAY + 1)
    assert(c.state.base_ledger.HOME.transport==0 and c.supply.reserve_side(c.sides.BLUE, 'transport')==0,
        'a written-off insertion was credited after the fact')
end

-- 8. troop's TTL WIRING, end to end. Also proves buildInsert now calls track(), which is what was
--    missing: the task_board allocation existed all along but saw no attempt.
do
    local c = p4_case()
    local troop = c.r.require_module('troop')
    base_here(c.state, c.sides, 'HOME', 'airbase')
    base_here(c.state, c.sides, 'TARGET', 'airbase', c.sides.RED)
    c.state.base_pos.TARGET = {x=20000, z=20000}
    c.state.base_ledger.HOME.transport = 6
    plain_airbase(c.r, 'HOME', 71)

    local mark = timer_mark(c.r)
    troop.run_troop_insertion(c.sides.BLUE, c.log, 'TARGET')
    local insert_name
    for name in pairs(c.state.active_tasks) do if name:match('^Insert%-') then insert_name = name end end
    assert(insert_name, 'run_troop_insertion dispatched nothing')
    local debited = 6 - c.state.base_ledger.HOME.transport
    assert(debited >= 1, 'the insertion debited no transport')
    assert(c.state.base_inflight.HOME==1, 'the insertion did not reserve a launch slot')
    drain_all(c)
    local insert_sortie = c.lifecycle.sortie_of(insert_name)
    assert(insert_sortie and insert_sortie.tracked==true and insert_sortie.role=='transport',
        'the insertion was not brought under its task_board allocation (track() missing)')

    local ttl = retirement_timer(c.r, mark)
    assert(ttl, 'buildInsert registered no TTL')
    c.r.advance(ttl)
    assert(c.supply.reserve_side(c.sides.BLUE, 'transport')==6-debited,
        'the insertion TTL returned the transport debit')
    assert((c.state.base_inflight.HOME or 0)==0, 'the insertion TTL kept the launch slot')
    assert(c.state.active_tasks[insert_name]==nil, 'the insertion TTL left the task record behind')
end

-- 9. NO ALLOCATION RECORD, NO SILENT LEAK. A group aircraft_lifecycle holds no record of (its
--    allocation was reversed before the spawn reached DCS) still has its slot released by the
--    caller's own fallback branch — exactly one of the two owners ever runs.
do
    local c = p4_case()
    local keysite = c.r.require_module('keysite')
    base_here(c.state, c.sides, 'HOME', 'airbase')
    keysite.reserve_slot('HOME', 'Ghost-4005')
    assert(c.state.base_inflight.HOME==1)
    assert(c.lifecycle.retire_sortie('Ghost-4005', 'backstop', 'recycled')==false,
        'retire_sortie claimed ownership of a group it holds no record of')
    keysite.release_slot('Ghost-4005')     -- the caller's fallback branch
    assert((c.state.base_inflight.HOME or 0)==0, 'the fallback branch did not release the slot')
end

-- 10. regen's REPLACEMENT AIRFRAME is allocation-owned but is NOT a sortie: a proven spawn failure
--     gives the reserve back, and a successful spawn opens no recovery record that could later
--     credit the same airframe a second time.
do
    local r = runtime('nil')                     -- the real addGroup returns nil at drain
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local lifecycle = r.require_module('aircraft_lifecycle')
    local regen = r.require_module('regen')
    base_here(state, sides, 'REGEN-BASE', 'airbase')
    state.base_ledger['REGEN-BASE'].heli = 3
    state.base_ammo['REGEN-BASE'] = 100
    plain_airbase(r, 'REGEN-BASE', 81)

    regen.init(function(message) r.logs[#r.logs+1] = message end)
    regen.queue_reseed(sides.BLUE, 'REGEN-BASE', 1, 0)
    regen.schedule_regen(function(message) r.logs[#r.logs+1] = message end)
    r.advance(r.timers[#r.timers].time)
    assert(state.base_ledger['REGEN-BASE'].heli==2, 'the regen spawn did not debit the ledger')
    assert(#state.spawn_queue==1, 'the regen spawn was not queued')
    queue.drain(function() end)
    assert(state.base_ledger['REGEN-BASE'].heli==3,
        'a regen spawn PROVEN never to have reached DCS did not give the reserve back')
    assert(lifecycle.stats().refunded==1, 'the regen reversal did not go through the allocation')
end
do
    local r = runtime('ok')
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local lifecycle = r.require_module('aircraft_lifecycle')
    local regen = r.require_module('regen')
    base_here(state, sides, 'REGEN-BASE', 'airbase')
    state.base_ledger['REGEN-BASE'].heli = 3
    state.base_ammo['REGEN-BASE'] = 100
    plain_airbase(r, 'REGEN-BASE', 82)

    regen.init(function(message) r.logs[#r.logs+1] = message end)
    regen.queue_reseed(sides.BLUE, 'REGEN-BASE', 1, 0)
    regen.schedule_regen(function(message) r.logs[#r.logs+1] = message end)
    r.advance(r.timers[#r.timers].time)
    while #state.spawn_queue > 0 do queue.drain(function() end) end
    local spawned
    for name in pairs(r.groups) do if name:match('^Regen%-') then spawned = name end end
    assert(spawned, 'the regen replacement never reached the fake DCS world')
    assert(state.base_ledger['REGEN-BASE'].heli==2, 'the regen debit did not stand')
    -- `recovery: false`: parked idle stock is not a sortie, so no record is opened for it. The
    -- permanent debit is preserved exactly as it was; P4 does not decide whether it is right.
    assert(lifecycle.sortie_of(spawned)==nil,
        'regen opened a recovery record for parked stock that could later credit it back')
    assert(lifecycle.stats().sorties==0, 'the regen spawn grew the sortie registry')
end

-- 11. THE SEAD INLINE ESCORT is under the contract: a proven no-creation gives back the ESCORT
--     debit at the escort's own base, and it still takes NO keysite launch slot — unchanged, and
--     deliberately so: whether an inline escort should consume a slot is an open EECH question.
do
    local r = runtime('nil')
    local queue = r.require_module('spawn_queue')
    local state = r.require_module('campaign_state').S
    local sides = r.require_module('sides')
    local lifecycle = r.require_module('aircraft_lifecycle')
    local supply = r.require_module('supply')

    base_here(state, sides, 'LAUNCH', 'airbase')
    state.base_ledger.LAUNCH.escort = 5
    -- Mirrors cas_bai_sead.spawnSeadEscort / attack_waves' inline escort block exactly: debit
    -- directly, open a CHILD allocation inside the parent builder's scope, spawn, track.
    local parent = lifecycle.begin_allocation({
        task_type='sead', side=sides.BLUE, base='LAUNCH', role='striker', count=1,
    })
    assert(supply.consume_base('LAUNCH', 'escort', 2), 'the escort fixture could not debit')
    local child = lifecycle.begin_allocation({
        task_type='sead_escort', side=sides.BLUE, base='LAUNCH', role='escort', count=2,
    })
    local escort = r.e.coalition.addGroup(2, r.e.Group.Category.AIRPLANE, {name='Escort-4100',
        units={{name='Escort-4100-1', type='F-15C', x=0, y=0}, {name='Escort-4100-2', type='F-15C', x=0, y=0}}})
    lifecycle.track(escort)
    lifecycle.commit_allocation(child, 'Escort-4100')
    lifecycle.commit_allocation(parent, 'SEAD-4100')

    assert(state.base_ledger.LAUNCH.escort==3, 'the escort debit did not stand')
    assert(state.group_launch_base['Escort-4100']==nil,
        'the inline escort reserved a keysite slot — P4 must not change that behaviour')
    assert(state.active_tasks['Escort-4100']==nil,
        'the inline escort registered a task — P4 must not change that behaviour')
    local escort_sortie = lifecycle.sortie_of('Escort-4100')
    assert(escort_sortie and escort_sortie.role=='escort',
        "the escort's recovery record took the parent's role instead of its own")
    assert(escort_sortie.budget==2, 'the escort budget was not its own debited count')

    queue.drain(function() end)
    assert(state.base_ledger.LAUNCH.escort==5,
        'a proven inline-escort spawn failure did not give back the escort debit')
    assert(lifecycle.sortie_of('Escort-4100')==nil,
        'a reversed inline escort left a recovery record able to credit again')
end

-- 12. A NESTED (child) allocation settles INDEPENDENTLY of its parent. That independence is the
--     whole reason the inline escorts get their own allocation rather than riding on the strike's
--     as a second attempt: they carry a different (base, role, count) tuple, so a shared record
--     would refund the escort at the striker's rate and would let a surviving escort suppress the
--     strike's own reversal.
do
    local c = p4_case()
    base_here(c.state, c.sides, 'LAUNCH', 'airbase')
    c.state.base_ledger.LAUNCH.striker = 4
    c.state.base_ledger.LAUNCH.escort = 4

    local parent = c.lifecycle.begin_allocation({
        task_type='ground_strike', side=c.sides.BLUE, base='LAUNCH', role='striker', count=2,
    })
    c.state.base_ledger.LAUNCH.striker = 2
    local child = c.lifecycle.begin_allocation({
        task_type='strike_escort', side=c.sides.BLUE, base='LAUNCH', role='escort', count=3,
    })
    c.state.base_ledger.LAUNCH.escort = 1
    c.lifecycle.abort_allocation(child, 'escort never reached DCS')
    assert(c.state.base_ledger.LAUNCH.escort==4, 'the child reversal did not give back the escort debit')
    assert(c.state.base_ledger.LAUNCH.striker==2, "the child reversal touched the parent's debit")
    c.lifecycle.abort_allocation(parent, 'strike never reached DCS')
    assert(c.state.base_ledger.LAUNCH.striker==4, 'the parent reversal did not give back the striker debit')
    assert(c.state.base_ledger.LAUNCH.escort==4, 'the parent reversal double-refunded the escort debit')
end

-- 13. THE `S._recycled` KEY NAMESPACE IS EXPLICIT. The settlement path writes only `unit:<name>`,
--     so a bare group or unit name left in the same table by anything else can neither satisfy nor
--     defeat the per-airframe "credited exactly once" guard.
do
    local c = p4_case()
    base_here(c.state, c.sides, 'HOME', 'airbase')
    local _, names = flight(c.r, c.lifecycle, c.state, c.sides, 'Heli-CAS-4006', 1,
        {role='heli', debit_base='HOME'})
    -- Pre-P4-shaped bare keys for the same group, and for the unit itself.
    c.state._recycled['Heli-CAS-4006'] = true
    c.state._recycled[names[1]] = true
    c.r.advance(700)
    c.lifecycle.retire_sortie('Heli-CAS-4006', 'backstop', 'recycled')
    assert(c.supply.reserve_side(c.sides.BLUE, 'heli')==1,
        'a bare group/unit key in S._recycled blocked a legitimate credit')
    assert(c.state._recycled['unit:'..names[1]]==true, 'the settlement guard was not namespaced')
end

-- 14. PER-ROLE CONSERVATION, with production, capture and transfers all absent from the fixture:
--       initial idle == current idle + still-allocated/non-terminal + confirmed losses + written off.
--     Refunded and recovered airframes are already inside "current idle" and are not counted
--     twice; the virtual-retirement proxies are broken out so the books say how much of the answer
--     rests on a timer rather than on evidence.
do
    local c = p4_case()
    base_here(c.state, c.sides, 'HOME', 'airbase')
    local INITIAL = 10
    c.state.base_ledger.HOME.heli = INITIAL
    -- reserve_side sums every owned base's ledger, so it IS current idle stock for this side.
    local function idle() return c.supply.reserve_side(c.sides.BLUE, 'heli') end
    assert(idle()==INITIAL, 'fixture: the side reserve must start empty')

    local sorties, units = {}, {}
    for i = 1, 4 do
        local name = 'Heli-CAS-40'..(10+i)
        c.state.base_ledger.HOME.heli = c.state.base_ledger.HOME.heli - 1
        local _, names = flight(c.r, c.lifecycle, c.state, c.sides, name, 1,
            {role='heli', debit_base='HOME'})
        sorties[i] = name; units[i] = names[1]
    end
    assert(idle()==INITIAL-4, 'fixture: four airframes should be off the books')

    c.r.advance(1000)
    -- (1) recovered on real evidence,
    c.r.emit(c.r.e.world.event.S_EVENT_LAND, c.r.units[units[1]], site('HOME', 3, 0))
    c.r.advance(1000 + CLEANUP_DELAY + 1)
    -- (2) confirmed loss,
    c.r.emit(c.r.e.world.event.S_EVENT_CRASH, c.r.units[units[2]], nil)
    -- (3) virtually retired by a timer while alive — credited on the PROXY, not on evidence,
    c.lifecycle.retire_sortie(sorties[3], 'backstop', 'recycled')
    -- (4) left alone: the non-terminal category.
    local outstanding = #c.lifecycle.unsettled_sorties()
    assert(outstanding==1 and c.lifecycle.unsettled_sorties()[1]==sorties[4],
        'exactly one sortie should still be outstanding')

    local stats = c.lifecycle.stats()
    local losses = stats.confirmed_losses
    local written_off = stats.virtual_abandons
    assert(losses==1, 'expected exactly one confirmed loss')
    assert(written_off==0, 'nothing was written off in this phase')
    assert(stats.virtual_credits==1 and stats.credited_airframes==2,
        'the evidence-based and proxy credits were not both counted exactly once')

    -- THE INVARIANT.
    assert(idle() + outstanding + losses + written_off == INITIAL,
        string.format('per-role conservation broken: idle=%d outstanding=%d losses=%d written_off=%d vs initial=%d',
            idle(), outstanding, losses, written_off, INITIAL))

    -- Write the last one off and re-check. A written-off airframe leaves the books for good —
    -- the deferred troop-TTL asymmetry stated as an accounting fact rather than hidden in a timer.
    c.lifecycle.retire_sortie(sorties[4], 'TTL expired', 'abandoned')
    written_off = c.lifecycle.stats().virtual_abandons
    outstanding = #c.lifecycle.unsettled_sorties()
    assert(outstanding==0, 'the written-off sortie is still outstanding')
    assert(written_off==1, 'the write-off was not recorded as a virtual abandon')
    assert(idle() + outstanding + losses + written_off == INITIAL,
        string.format('per-role conservation broken after write-off: idle=%d outstanding=%d losses=%d written_off=%d vs initial=%d',
            idle(), outstanding, losses, written_off, INITIAL))
end
print('PASS aircraft-lifecycle defect 4 (P4 TARGET): every aircraft path has one owner of its credit, slot and stands; the four virtual-retirement timers settle through the contract (closing the supply double-credit race); regen/CAP/BDA/insert/supply-flight and both inline escorts are allocation-owned; players survive delayed callbacks; per-role conservation holds')
