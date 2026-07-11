-- keysite_repair.lua
-- EECH source: aphavoc/source/entity/special/keysite/ks_updt.c
--   update_server() — two sub-loops at different periods:
--     Loop A (every KEYSITE_UPDATE_SLEEP_TIMER = 60 s):
--       ammo_supply_level += AMMO_USAGE_ACCELERATOR(1.0) × default_supply_usage.ammo_supply_level
--       fuel_supply_level += FUEL_USAGE_ACCELERATOR(1.0) × default_supply_usage.fuel_supply_level
--       bound both to [KEYSITE_MINIMUM_AMMO_SUPPLY_LEVEL=10.0, 100.0]
--     Loop B (every 1.0 * ONE_MINUTE = 60 s, offset by task_timer):
--       if keysite_strength < keysite_maximum_strength AND repairable:
--         create_repair_task(side, pos, en, priority=10.0) if not already tasked
--   KEYSITE_STATE_REPAIRING loop (continuous, delta-time driven):
--     repair_timer -= delta_time; if <= 0: repair_client_server_entity_keysite()
--     (repairs one building per timer expiry; when all repaired → KEYSITE_STATE_USABLE)
--
-- EECH source: aphavoc/source/entity/system/en_types/en_suply.h
--   KEYSITE_MINIMUM_AMMO_SUPPLY_LEVEL = 10.0  (percentage, 0–100 scale)
--   KEYSITE_MINIMUM_FUEL_SUPPLY_LEVEL = 10.0
--   AMMO_USAGE_ACCELERATOR            = 1.0
--   FUEL_USAGE_ACCELERATOR            = 1.0
--
-- EECH source: aphavoc/source/entity/special/keysite/keysite.h
--   KEYSITE_UPDATE_SLEEP_TIMER = 1.0 * ONE_MINUTE = 60 s
--
-- DCS proxy notes:
-- • Repair in EECH requires a dedicated repair unit task.  We proxy this as automatic
--   health increment when base is damaged but not neutralised.  Rate mirrors EECH's
--   1-building-per-10-min heal (REPAIR_RATE_PER_TICK = 1/100 → full in ~100 min; see below).
-- • Supply consumption: default_supply_usage is keysite-type-specific in EECH data.
--   We branch the drain rate on keysite type (airbase ammo -0.2%/fuel -0.4% per 60 s;
--   FARP far lighter — see the per-type constants below), matching EECH's per-row rates.
-- • S.base_ammo[name] uses 0–100 scale to match EECH's ammo_supply_level.

local cs     = require("campaign_state")
local supply = require("supply")
local inst   = require("installations")
local sf     = require("supply_flight")
local S      = cs.S
local M      = {}

-- ── EECH constants (exact mirror) ─────────────────────────────────────────────
local KEYSITE_UPDATE_SLEEP_TIMER      = 60        -- s; keysite.h: 1.0 * ONE_MINUTE
local KEYSITE_MINIMUM_AMMO_SUPPLY     = 10.0      -- %; en_suply.h: KEYSITE_MINIMUM_AMMO_SUPPLY_LEVEL
local KEYSITE_MINIMUM_FUEL_SUPPLY     = 10.0      -- %; en_suply.h: KEYSITE_MINIMUM_FUEL_SUPPLY_LEVEL
local AMMO_USAGE_ACCELERATOR          = 1.0       -- en_suply.h
local FUEL_USAGE_ACCELERATOR          = 1.0       -- en_suply.h
local KEYSITE_SUPPLY_REQUEST_THRESHOLD = 75.0     -- %; en_suply.h:87 / keysite.c:469 — below → request crate

-- ── Consumer keysite drain (per-keysite-type default_supply_usage, ks_dbase.c) ───────────────────
-- default_supply_usage is keysite-TYPE-specific in the EECH keysite_database, NOT one flat rate:
--   AIRBASE : ammo -0.2 %/min, fuel -0.4 %/min   (eech ks_dbase.c:98-99, airbase row)
--   FARP    : ammo -0.05 %/min, fuel -0.03 %/min (eech ks_dbase.c:239-240, FARP row)
-- A FARP is a SMALL forward base with a far lighter supply appetite than a full airbase, so it drains
-- ~4-13× slower. The port branches on S.base_kind so FARPs/FOBs drain at the FARP rate and full
-- airbases at the airbase rate (03-F5). Every base drains every 60 s tick; restock no longer comes
-- from being "rear" but from the LOGISTICS CHAIN (KEYSITE-F6/F7/F8): when a base falls below
-- KEYSITE_SUPPLY_REQUEST_THRESHOLD it requests a crate, and a PHYSICAL supply flight (supply_flight.lua
-- — a transport that flies the crate from the nearest producer to the consumer) restocks it to 100 on
-- arrival — but ONLY if the owner has a live producer (factory/refinery) with a crate available, AND
-- the transport survives the trip. Kill the enemy's factories (or shoot down its transports) and its
-- bases drain to the floor (10) and can no longer rearm/refuel/repair.
local AIRBASE_AMMO_USAGE_PER_TICK = -0.2    -- eech ks_dbase.c:98  airbase ammo default_supply_usage
local AIRBASE_FUEL_USAGE_PER_TICK = -0.4    -- eech ks_dbase.c:99  airbase fuel default_supply_usage
local FARP_AMMO_USAGE_PER_TICK    = -0.05   -- eech ks_dbase.c:239 FARP ammo default_supply_usage
local FARP_FUEL_USAGE_PER_TICK    = -0.03   -- eech ks_dbase.c:240 FARP fuel default_supply_usage

-- Proxy repair rate — realigned to EECH's ACTUAL cadence (keysite.c:1581 repair_client_server_entity_
-- keysite + ks_updt.c update_server): a repairing keysite restores exactly ONE building every 10 min
-- (repair_timer = 10.0 * ONE_MINUTE; regen buildings 20 min), building-by-building until usable. So a
-- multi-building AIRBASE takes ~10 min × building-count (50-100+ min) for a FULL repair — NOT the 20 min
-- the old proxy assumed. At the old 0.05/min (1/20), bases recovered from strikes faster than the
-- spread-out strike tasker could re-neutralise them → they never dropped below MINIMUM_EFFICIENCY (0.3)
-- → NO base captures → permanent stalemate. Modelling ~10 building-equivalents at 10 min each:
local REPAIR_RATE_PER_TICK = 1.0 / 100.0  -- ≈1 building (0.1 strength) per 10 min → full in ~100 min

-- STRIKE_SUPPRESS_TIME — PROXY for EECH's repair-TASK creation + delivery delay, NOT a standalone
-- EECH timer. EECH repair has NO supply gate and NO suppression timer: when keysite_strength < max
-- the update loop CREATES a repair task (ks_updt.c:200-217, create_repair_task priority 10) which
-- must be ASSIGNED and physically DELIVERED before the keysite enters KEYSITE_STATE_REPAIRING and the
-- 1-building/10-min heal begins (ks_updt.c:169-222; keysite.c:1581). That create→assign→deliver
-- latency is the real brake on recovery under sustained attack. The port has no repair-flight entity,
-- so it proxies that latency as a fixed post-strike hold: a keysite struck within the last
-- STRIKE_SUPPRESS_TIME does not run its repair increment. 480 s > the 7.5-min (450 s) keysite-strike
-- period, so a base under SUSTAINED strike pressure stays suppressed (matching EECH, where a keysite
-- that keeps taking hits never gets its repair task delivered).
local STRIKE_SUPPRESS_TIME = 480.0        -- s: repair-task creation/delivery-delay proxy (ks_updt.c:169-222)

-- ── S.base_ammo and S.base_fuel ───────────────────────────────────────────────
-- 0–100 percentage, mirroring EECH ammo_supply_level / fuel_supply_level.

function M.init(log_fn)
    log_fn = log_fn or function() end
    S.base_ammo       = S.base_ammo or {}
    S.base_fuel       = S.base_fuel or {}
    S.base_efficiency = S.base_efficiency or {}
    for name in pairs(S.base_owner) do
        S.base_ammo[name]       = S.base_ammo[name] or 100.0
        S.base_fuel[name]       = S.base_fuel[name] or 100.0
        S.base_efficiency[name] = 1.0   -- full efficiency at mission start
    end
    log_fn(string.format(
        "keysite_repair: ammo/fuel tables initialised (min_ammo=%.0f%%, min_fuel=%.0f%%)",
        KEYSITE_MINIMUM_AMMO_SUPPLY, KEYSITE_MINIMUM_FUEL_SUPPLY))
    cs.dbg("repair", "init: ammo/fuel tables seeded at 100%% for all owned bases")
end

local SIDES = { coalition.side.BLUE, coalition.side.RED }

local function bound(v, lo)
    if v < lo then return lo elseif v > 100.0 then return 100.0 else return v end
end

-- ── update_server proxy ───────────────────────────────────────────────────────
-- Mirrors EECH ks_updt.c update_server()/supply tick, running every KEYSITE_UPDATE_SLEEP_TIMER.
-- One tick = 60 s = 1 minute, so per-minute rates apply directly.
local function tick(log_fn)
    S.base_ammo = S.base_ammo or {}
    S.base_fuel = S.base_fuel or {}
    S.base_efficiency = S.base_efficiency or {}

    -- ── 1. Production tick (KEYSITE-F5): credit each side's crate accumulator ──
    -- from its ALIVE producer keysites (installations.production_rates). Zero once its factories
    -- are gone → no deliveries, no reserve replacement.
    for _, side in ipairs(SIDES) do
        local ok, a, f = pcall(inst.production_rates, side)
        if ok then supply.credit_production(side, a or 0, f or 0, 1) end
    end

    -- ── 2. Consumer drain + collect restock requests (KEYSITE-F5/F6) ──────────
    local need = {
        [coalition.side.BLUE] = { ammo = {}, fuel = {} },
        [coalition.side.RED]  = { ammo = {}, fuel = {} },
    }
    for name, owner in pairs(S.base_owner) do
        if owner == coalition.side.BLUE or owner == coalition.side.RED then
            -- Branch the drain rate on keysite TYPE (ks_dbase.c per-row default_supply_usage): FARP/FOB
            -- forward bases drain at the light FARP rate (:239-240), full airbases at the airbase rate
            -- (:98-99). base_kind mirrors EECH's keysite sub_type (air_force_capacity SMALL vs LARGE).
            local kind = S.base_kind and S.base_kind[name]
            local is_farp = (kind == "farp" or kind == "fob")
            local ammo_rate = is_farp and FARP_AMMO_USAGE_PER_TICK or AIRBASE_AMMO_USAGE_PER_TICK
            local fuel_rate = is_farp and FARP_FUEL_USAGE_PER_TICK or AIRBASE_FUEL_USAGE_PER_TICK
            S.base_ammo[name] = bound((S.base_ammo[name] or 100.0)
                + AMMO_USAGE_ACCELERATOR * ammo_rate, KEYSITE_MINIMUM_AMMO_SUPPLY)
            S.base_fuel[name] = bound((S.base_fuel[name] or 100.0)
                + FUEL_USAGE_ACCELERATOR * fuel_rate, KEYSITE_MINIMUM_FUEL_SUPPLY)
            -- request a crate when at/below threshold (KEYSITE-F6: cargo_level <= 75 AND consumer)
            if S.base_ammo[name] <= KEYSITE_SUPPLY_REQUEST_THRESHOLD then
                need[owner].ammo[#need[owner].ammo + 1] = name
            end
            if S.base_fuel[name] <= KEYSITE_SUPPLY_REQUEST_THRESHOLD then
                need[owner].fuel[#need[owner].fuel + 1] = name
            end
        end
    end

    -- ── 3. Supply requests (KEYSITE-F6/F7): neediest base first → PHYSICAL supply flight ──────────
    -- Below-threshold keysites no longer teleport a crate: each raises a FORCE_LOW_ON_SUPPLIES request
    -- (keysite.c:469-494) that supply_flight.request turns into a board TASK_SUPPLY — a transport that
    -- must physically fly the crate from the nearest producer and reach the consumer before it counts
    -- (fc_msgs.c:672-870 → taskgen.c:1638 create_supply_task). request() dedups per consumer per
    -- commodity, aborts with no live producer / no banked crate, and EARMARKS the crate so the reserve
    -- conversion below can't repurpose it while the flight is queued. The actual restock-to-100 happens
    -- on the flight's DROP_OFF fly-over (supply_flight.check_arrivals), not here.
    for _, side in ipairs(SIDES) do
        for _, commodity in ipairs({ "ammo", "fuel" }) do
            local tbl  = (commodity == "ammo") and S.base_ammo or S.base_fuel
            local list = need[side][commodity]
            table.sort(list, function(x, y) return (tbl[x] or 0) < (tbl[y] or 0) end)   -- neediest first
            for _, bname in ipairs(list) do
                sf.request(side, bname, commodity, log_fn)
            end
        end
    end

    -- ── 3b. Reconcile crate earmarks to the live queued supply tasks ──────────────────────────────
    -- set_earmark = number of still-QUEUED supply board tasks per side/commodity (spawned/expired ones
    -- drop out), so convert_reserves below protects exactly the crates committed to pending flights and
    -- never leaks an earmark for a task that vanished.
    for _, side in ipairs(SIDES) do
        for _, commodity in ipairs({ "ammo", "fuel" }) do
            supply.set_earmark(side, commodity, sf.count_queued(side, commodity))
        end
    end

    -- ── 4. Reserve replacement (force.c replace_into_force_info): SURPLUS crates → reserve hardware
    -- (only crates beyond the earmarks set above — delivery has priority over stockpiling reserves).
    for _, side in ipairs(SIDES) do
        supply.convert_reserves(side, log_fn)
    end

    -- ── 5. Repair + efficiency, per keysite ───────────────────────────────────
    local n_repaired, n_suppressed, n_full_or_dead = 0, 0, 0
    for name, owner in pairs(S.base_owner) do
        if owner == coalition.side.BLUE or owner == coalition.side.RED then
            -- Loop B repair trigger (ks_updt.c:169-222): DCS proxy directly increments health when the
            -- keysite is USABLE (health > neutralised) and not currently suppressed. EECH repair has NO
            -- supply gate — repair is purely the repair-TASK delivery + the 1-building/10-min timer; the
            -- 50%-supply gate the port used to apply was an INVENTION (uncited → latent bug) and is
            -- removed (03-F10). The only brake is STRIKE_SUPPRESS_TIME (the repair-task-delivery-delay
            -- proxy above): a keysite struck within that window does not run its repair increment.
            local h = S.base_health[name] or 1.0
            local last = S.base_last_strike and S.base_last_strike[name]
            local suppressed = last and (timer.getTime() - last) < STRIKE_SUPPRESS_TIME
            if h < 1.0 and h >= cs.HEALTH_NEUTRALISED and not suppressed then   -- USABLE inclusive (keysite.c:827-830)
                S.base_health[name] = math.min(1.0, h + REPAIR_RATE_PER_TICK)
                n_repaired = n_repaired + 1
            elseif h < 1.0 and h >= cs.HEALTH_NEUTRALISED and suppressed then
                n_suppressed = n_suppressed + 1
            else
                n_full_or_dead = n_full_or_dead + 1
            end

            -- FLOAT_TYPE_EFFICIENCY (ks_float.c:260-275) = keysite_strength / keysite_maximum_strength;
            -- supply is NOT part of efficiency (KEYSITE-F3). base_health IS strength/max, so eff==health.
            S.base_efficiency[name] = S.base_health[name] or 1.0
        end
    end
    cs.dbg("repair", "repair tick: %d repaired, %d suppressed (recent strike / repair-task-delay proxy), %d full/neutralised-or-dead",
        n_repaired, n_suppressed, n_full_or_dead)
end

-- ── Scheduler ─────────────────────────────────────────────────────────────────
-- mirrors overload_keysite_update_functions → update_server, called every
-- KEYSITE_UPDATE_SLEEP_TIMER (60 s).
function M.schedule_repair(log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    cs.dbg("repair", "scheduler REGISTERED offset=%.0fs period=%.0fs", KEYSITE_UPDATE_SLEEP_TIMER, KEYSITE_UPDATE_SLEEP_TIMER)
    timer.scheduleFunction(function(_, t)
        -- INFRASTRUCTURE: keysite supply/repair tick keeps running post-victory (EECH fc_msgs.c:163). Cluster E.
        if _DMT_GEN ~= my_gen then return nil end
        local ok, err = pcall(tick, log_fn)
        if not ok then log_fn("keysite_repair tick error: " .. tostring(err)) end
        return t + KEYSITE_UPDATE_SLEEP_TIMER
    end, nil, timer.getTime() + KEYSITE_UPDATE_SLEEP_TIMER)
end

return M
