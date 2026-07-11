-- spawn_queue.lua
-- Diagnostic + robustness layer: intercept every coalition.addGroup / addStaticObject and DEFER it
-- into a queue that drains a few spawns per timer tick, instead of spawning ~150-200 groups
-- synchronously in a single frame at mission start.
--
-- WHY: injecting the campaign hard-crashes DCS (~0.07s after init) with C0000005 ACCESS_VIOLATION
-- in edObjects viLight::QueryEditor, via wSimCalendar::DoActionsUntil → wSimTrace (track recorder).
-- No Lua error — a DCS-engine null-deref triggered when the sim first advances and processes the
-- burst of freshly-added groups. Draining one spawn per tick lets the sim advance a frame BETWEEN
-- each spawn, so (a) if the crash is a volume/burst problem it is avoided entirely, and (b) if it is
-- one specific unit, the log pinpoints it: the last ">>> SPAWNING #N" / "<<< OK #N" pair with no
-- following "#N+1" is the group whose render/track step crashed the sim.
--
-- Callers keep working: addGroup returns a lazy PROXY that delegates to the real DCS group (by name)
-- once the queued spawn drains. getController() before the real spawn captures setTask/pushTask and
-- replays them on drain (ground_forces / cas artillery set a task immediately after spawning).

local cs = require("campaign_state")
local S  = cs.S
local M  = {}

-- Tuning. 1/tick with a 1s gap = maximal isolation for crash bisection. Raise DRAIN_PER_TICK once
-- the crash trigger is understood (burst-size threshold vs a single bad unit).
local DRAIN_PER_TICK = 4     -- crash root cause was launch lights=0 (not spawn volume), so the burst
                             -- guard can drain faster; keeps stagger but clears the larger OOB
                             -- (airbases + AD garrisons + the infrastructure network) in reasonable time
local DRAIN_INTERVAL = 1.0   -- sim seconds between drains

S.spawn_queue = S.spawn_queue or {}
S._spawn_seq  = S._spawn_seq  or 0

-- Preserve the REAL engine originals across re-injection — never wrap an already-wrapped function.
_G.__dmt_real_addGroup  = _G.__dmt_real_addGroup  or coalition.addGroup
_G.__dmt_real_addStatic = _G.__dmt_real_addStatic or coalition.addStaticObject
local real_addGroup  = _G.__dmt_real_addGroup
local real_addStatic = _G.__dmt_real_addStatic

-- ── Lazy proxy ─────────────────────────────────────────────────────────────────
-- Stands in for the group between enqueue and drain; delegates to the live group by name.
local function make_proxy(name, item)
    local function live() return Group.getByName(name) end
    local p = { __queued = true }
    function p:getName()      return name end
    function p:isExist()      local g = live(); return g ~= nil and g:isExist() end
    function p:getUnits()     local g = live(); return g and g:getUnits() or {} end
    function p:getUnit(i)     local g = live(); return g and g:getUnit(i) or nil end
    function p:getSize()      local g = live(); return g and g:getSize() or 0 end
    function p:getID()        local g = live(); return g and g:getID() or -1 end
    function p:getCategory()  local g = live(); return g and g:getCategory() or nil end
    function p:getCoalition() local g = live(); return g and g:getCoalition() or nil end
    function p:destroy()      local g = live(); if g then g:destroy() end end
    function p:getController()
        local g = live()
        if g then return g:getController() end
        -- Real group not spawned yet: capture tasking to replay on drain.
        return {
            setTask    = function(_, t) item.deferred_setTask  = t end,
            pushTask   = function(_, t) item.deferred_pushTask = t end,
            resetTask  = function() end,
            setCommand = function() end,
            setOption  = function() end,
        }
    end
    return p
end

-- ── Interception ─────────────────────────────────────────────────────────────────
coalition.addGroup = function(country_id, category, data)
    S._spawn_seq = S._spawn_seq + 1
    local name = (data and data.name) or ("SpawnQ-" .. S._spawn_seq)
    local item = { kind = "group", country = country_id, category = category, data = data,
                   name = name, seq = S._spawn_seq }
    S.spawn_queue[#S.spawn_queue + 1] = item
    return make_proxy(name, item)
end

coalition.addStaticObject = function(country_id, data)
    S._spawn_seq = S._spawn_seq + 1
    local name = (data and data.name) or ("SpawnQ-static-" .. S._spawn_seq)
    local item = { kind = "static", country = country_id, data = data, name = name, seq = S._spawn_seq }
    S.spawn_queue[#S.spawn_queue + 1] = item
    return make_proxy(name, item)
end

-- ── Drain ─────────────────────────────────────────────────────────────────────
-- Reaching drain tick T proves every spawn done in tick T-1 survived the sim advancing a frame.
function M.drain(log_fn)
    log_fn = log_fn or env.info
    local q = S.spawn_queue
    local n = 0
    while #q > 0 and n < DRAIN_PER_TICK do
        local item  = table.remove(q, 1)
        local utype = (item.data and item.data.units and item.data.units[1] and item.data.units[1].type) or "?"
        log_fn(string.format("[spawn_queue] >>> SPAWNING #%d name=%s type=%s kind=%s (%d left)",
            item.seq, tostring(item.name), tostring(utype), item.kind, #q))
        local g
        if item.kind == "group" then
            local ok, res = pcall(real_addGroup, item.country, item.category, item.data)
            if ok then g = res else
                log_fn(string.format("[spawn_queue] !!! addGroup THREW #%d: %s", item.seq, tostring(res)))
            end
        else
            local ok, res = pcall(real_addStatic, item.country, item.data)
            if ok then g = res end
        end
        if g and item.deferred_setTask  then pcall(function() g:getController():setTask(item.deferred_setTask)   end) end
        if g and item.deferred_pushTask then pcall(function() g:getController():pushTask(item.deferred_pushTask) end) end
        log_fn(string.format("[spawn_queue] <<< OK #%d name=%s spawned=%s", item.seq, tostring(item.name), tostring(g ~= nil)))
        n = n + 1
    end
    if #q == 0 and not S._spawn_drain_reported and S._spawn_seq > 0 then
        S._spawn_drain_reported = true
        log_fn(string.format("[spawn_queue] DRAIN COMPLETE — all %d queued spawns executed and survived the loop",
            S._spawn_seq))
        cs.dbg("spawn", "DRAIN COMPLETE: all %d queued spawns executed", S._spawn_seq)
    end
    return n
end

function M.schedule_drain(log_fn)
    log_fn = log_fn or env.info
    local my_gen = _DMT_GEN
    local function tick(_, t)
        if _DMT_GEN ~= my_gen then return nil end   -- self-cancel on re-injection
        M.drain(log_fn)
        return t + DRAIN_INTERVAL
    end
    timer.scheduleFunction(tick, nil, timer.getTime() + DRAIN_INTERVAL)
    log_fn(string.format("[spawn_queue] drain scheduled: %d spawn/tick every %.1fs (%d queued now)",
        DRAIN_PER_TICK, DRAIN_INTERVAL, #S.spawn_queue))
    cs.dbg("spawn", "drain scheduler REGISTERED offset=%.1fs period=%.1fs rate=%d/tick (%d queued now)",
        DRAIN_INTERVAL, DRAIN_INTERVAL, DRAIN_PER_TICK, #S.spawn_queue)
end

return M
