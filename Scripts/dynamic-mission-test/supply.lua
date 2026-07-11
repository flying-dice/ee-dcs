-- supply.lua
-- Mirrors EECH's per-FORCE hardware reserve system:
--   aphavoc/source/entity/special/force/force.h   force_info_reserve_hardware[NUM_CATAGORIES]
--   aphavoc/source/entity/special/force/force.c    add_to_force_info  (spawn → reserve--, force.c:236-241)
--                                                   remove_from_force_info (death → current--, :270)
--                                                   replace_into_force_info (RTB recycle → reserve++, :297)
--   aphavoc/source/ai/faction/parser.c:1303         reserve_hardware seeded once at OOB
--   aphavoc/source/entity/special/regen/rg_updt.c:287  regen gated on reserve > 0
--
-- CLUSTER 4 — PER-BASE IDLE LEDGER: idle hardware now lives in a PER-BASE ledger (S.base_ledger,
-- counts by role at each owned base), NOT a single per-side pool. This localises EECH's reserve
-- hardware to keysites — the task engine's resident-group source (assign.c LIST_TYPE_KEYSITE_GROUP).
-- The per-side pool is the SUM of base ledgers (reserve_side); consume_side/recycle_side stay as
-- thin wrappers that pick a base internally (the richest owned base) when the caller has no base in
-- hand. The task board (task_board.lua) consumes from the CHOSEN launch base at assignment time.
-- Why a proxy: DCS cannot keep hundreds of parked AI aircraft alive (parking/perf), so parked
-- aircraft are counts, spawned physically only at assignment and despawned on RTB.
--
-- PORT PROXY — recycle-on-RTB: shipped EECH has ZERO callers of replace_into_force_info (force.c:
-- 278-300; verified full-tree grep, spec 02 FORCE-F6) — hardware that lands/withdraws is never
-- returned. The port credits reserve on RTB (make_land_handler → the LANDING base's ledger) and on
-- task expiry (reaction.lua) as a reconstruction of the DESIGN intent (force conservation with
-- location: survivors become idle inventory at the base they landed at, transferable thereafter).
--
-- PRODUCTION (this cluster) — the OTHER caller of the replacement mechanism: production keysites
-- (factory/refinery/port, KEYSITE-F1/F5) accumulate ammo/fuel as cargo crates while alive+owned;
-- crates restock consumer keysites (KEYSITE-F6/F7/F8, in keysite_repair.lua) and SURPLUS crates
-- convert to reserve replacement here (convert_reserves → recycle_side). This is a deliberate port
-- synthesis: shipped EECH keeps aircraft-reserve and keysite-supply on separate ledgers, but the
-- port has no crate-logistics entities, so production is wired to BOTH surfaces so that destroying
-- an enemy factory genuinely starves it (the economic-vulnerability gap). Rates: eech ks_dbase.c
-- factory ammo +1.0/min, refinery fuel +1.0/min; crate size 10 (cargo.h:89,91).
--
-- The public API is still keyed by base NAME (so existing call sites are unchanged); a base
-- name resolves to its owner side via S.base_owner, and all accounting hits that side's pool.
-- Side-keyed variants (*_side) exist for code that already has the side in hand.
--
-- VEHICLE/TROOP reserve discipline: ground reinforcement (ground_forces.lua) draws the "vehicle"
-- pool through the SAME consume_side/recycle_side path (with refund on failure) as aircraft — the
-- reserve gate is identical (EECH gates vehicle regen on reserves too, rg_updt.c:291). Production's
-- convert_reserves also replenishes the vehicle/troop pools, so factory loss starves the ground war.

local cs = require("campaign_state")
local ks = require("keysite")
local config = require("config")
local S  = cs.S
local M  = {}

-- ── Roles → EECH force_info_catagory ──────────────────────────────────────────
-- Roles are finer-grained than EECH's 8 categories (striker+escort are both ARMED_FIXED_WING);
-- the mapping is used only for category-level logging / future per-category reporting. Strength
-- itself is a live census (campaign_state.count_current_hardware), so this map is informational.
-- NOTE: the "troop" role was REMOVED in Cluster H — it was seeded + credited by fuel-crate conversion
-- but NO spawner ever drew it (troop insertions consume the "transport" role, classify_role Insert→
-- transport), so 1 of the 4 fuel round-robin slots vanished into a dead pool. Insertion troops ride
-- the transport ledger; ground reinforcement rides "vehicle".
M.ROLES = { "striker", "escort", "heli", "recon", "transport", "vehicle" }

M.ROLE_CATEGORY = {
    striker   = "ARMED_FIXED_WING",
    escort    = "ARMED_FIXED_WING",
    recon     = "ARMED_FIXED_WING",
    transport = "UNARMED_FIXED_WING",
    heli      = "ARMED_HELICOPTER",
    vehicle   = "ARMED_ROUTED_VEHICLE",
}

-- ── Baked scenario: per-owned-base reserve allotment ──────────────────────────
-- The whole OOB is injected at server start (empty DCS mission). Each base a side owns at
-- campaign start contributes this allotment to that side's strategic reserve pool. Scaling
-- the pool with base count keeps the scenario map-agnostic (works on any Caucasus layout).
-- Mission designers tune the campaign length here: bigger pools = longer war before attrition.
-- EECH is a helicopter-centric campaign — attack helis fly the bulk of the sorties (anti-armour,
-- hunter-killer, escort, BDA, troop insertion), so the rotary reserve is the deepest pool.
-- striker=4 so a SINGLE base can source a full late-phase strike wave; the task board assigns one task
-- to one base, so a base must be able to field the largest package. Hoisted to config.reserves.per_base.
local RESERVE_PER_BASE = config.C.reserves.per_base

-- ── Production → reserve replacement (KEYSITE-F5/F8, force.c replace_into_force_info) ─────────
-- Crate size: eech cargo.h:89,91 CARGO_AMMO_SIZE / CARGO_FUEL_SIZE = 10 supply points per crate.
-- A production keysite's %/min stock (installations.production_rates) accumulates in S.production;
-- keysite_repair debits whole crates for consumer restock (deliver_crate), then surplus crates
-- convert to reserve hardware (convert_reserves). One crate → one reserve unit, round-robin across
-- the roles that logically consume that commodity:
--   ammo (factory/port) → the armed shooters that expend ordnance (heli, striker, vehicle)
--   fuel (refinery/port) → the fuel-hungry mobility/support airframes (escort, recon, transport)
local CRATE_SIZE = 10
local AMMO_RESERVE_ROLES = { "heli", "striker", "vehicle" }
local FUEL_RESERVE_ROLES = { "escort", "recon", "transport" }

-- ── Group-name → role classifier: SINGLE SOURCE (RTB recycle + regen) ─────────
-- Mirrors get_regen_sub_type()'s entity classification (rg_updt.c:598). ONE ordered prefix→role table
-- feeds BOTH consumers (Wave 1 merge — was two hand-synced tables, here + regen.classify_group):
--   • classify_role  (RTB recycle) → role for ANY match. Every spawned combat/support group whose lead
--     unit RTBs is recycled back to its side's reserve (replace_into_force_info), so it MUST recycle the
--     SAME pool it consumed at spawn. Escort-consuming flights (OCA-Sweep, CAP, BARCAP use cfg.escort) →
--     "escort"; heli-consuming flights (BDA, troop Insert, Heli CAP) → "heli".
--   • classify_group (regen queue, called by regen.lua) → role only for REGENERATED types (regen=true);
--     nil for one-shots (Recon/Ferry/Insert/Supply, regen=false) which respawn on demand, not via the
--     regen queue. A one-shot SURVIVOR that lands is still recycled to its "transport"/"recon" pool by
--     classify_role; one shot down is simply LOST (no regen entry, its picked-up crate lost with it).
-- Order is LOAD-BEARING: matched top-to-bottom, first hit wins — preserves the original if/elseif order
-- of both functions exactly (no prefix matches across a regen boundary, so first-hit is unambiguous).
local PREFIX_ROLES = {
    { pattern = "^Escort%-",      role = "escort",    regen = true  },
    { pattern = "^Regen%-Escort", role = "escort",    regen = true  },
    { pattern = "^OCA%-Sweep",    role = "escort",    regen = true  },
    { pattern = "^CAP%-",         role = "escort",    regen = true  },
    { pattern = "^BARCAP%-",      role = "escort",    regen = true  },
    { pattern = "^Strike%-",      role = "striker",   regen = true  },
    { pattern = "^Regen%-Strike", role = "striker",   regen = true  },
    { pattern = "^KStrike%-",     role = "striker",   regen = true  },
    { pattern = "^OCAStrike%-",   role = "striker",   regen = true  },
    { pattern = "^CAS%-",         role = "striker",   regen = true  },
    { pattern = "^BAI%-",         role = "striker",   regen = true  },
    { pattern = "^SEAD%-",        role = "striker",   regen = true  },
    { pattern = "^Recon%-",       role = "recon",     regen = false },  -- one-shot: recycled on RTB, not regenerated
    { pattern = "^Ferry%-",       role = "transport", regen = false },  -- one-shot
    { pattern = "^Insert%-",      role = "transport", regen = false },  -- troop-insert helis → transport pool, one-shot
    { pattern = "^Supply%-",      role = "transport", regen = false },  -- physical supply flights → transport pool, one-shot
    { pattern = "^Heli",          role = "heli",      regen = true  },
    { pattern = "^Regen%-Heli",   role = "heli",      regen = true  },
    { pattern = "^BDA%-",         role = "heli",      regen = true  },
}
M.PREFIX_ROLES = PREFIX_ROLES   -- exposed as the single source (regen.classify_group delegates here)

-- classify_role(name) → role of the first matching prefix, or nil. RTB recycle: every tracked flight.
local function classify_role(name)
    for _, e in ipairs(PREFIX_ROLES) do
        if name:match(e.pattern) then return e.role end
    end
    return nil
end
M.classify_role = classify_role

-- classify_group(name) → role only when the matched prefix is a REGENERATED type (regen=true); nil for
-- one-shots and non-matches. Used by regen.lua (single source; agrees with classify_role for regen
-- types by construction — same table, same order).
function M.classify_group(name)
    for _, e in ipairs(PREFIX_ROLES) do
        if name:match(e.pattern) then
            return e.regen and e.role or nil
        end
    end
    return nil
end

-- ── Init: seed per-side reserve pool from OOB ─────────────────────────────────
-- Called once from game_loop.start() after keysite.init_base_state().
-- Mirrors order.c initialise_order_of_battle assigning reserve hardware to each force.
function M.init(log_fn)
    log_fn = log_fn or function() end

    -- Seed the PER-BASE ledger: each owned base gets RESERVE_PER_BASE idle aircraft by role.
    -- The per-side pool is now the SUM of these ledgers (reserve_side). This localises EECH's
    -- reserve hardware to keysites (the assignment engine's resident-group source, assign.c).
    S.base_ledger = {}
    for name, owner in pairs(S.base_owner) do
        if owner == coalition.side.BLUE or owner == coalition.side.RED then
            local led = {}
            local k = S.base_kind and S.base_kind[name]
            local heli_only = (k == "fob" or k == "farp")
            for _, role in ipairs(M.ROLES) do
                if heli_only then
                    -- FOB/FARP = HELICOPTERS ONLY (ks_dbase.c FARP air_force_capacity SMALL, and the
                    -- "FARP only behaviour" fields): rotary roles resident (heli attack + transport for
                    -- insertion), NO fixed-wing striker/escort/recon. This is what confines fixed-wing
                    -- to the few AIRBASEs and makes the FRONT a helicopter war.
                    led[role] = (role == "heli" and config.C.reserves.farp_heli)
                             or (role == "transport" and config.C.reserves.farp_transport) or 0
                else
                    led[role] = RESERVE_PER_BASE[role] or 0
                end
            end
            S.base_ledger[name] = led
        end
    end

    -- per-side production crate accumulator (KEYSITE-F5). ammo/fuel are supply-points; *_rr are
    -- round-robin cursors for reserve conversion. Fed by keysite_repair from production_rates.
    -- *_earmark = whole crates COMMITTED to a pending physical supply flight (supply_flight.lua): a
    -- crate a consumer keysite has requested but not yet picked up. convert_reserves must NOT convert
    -- an earmarked crate to reserve hardware (the cargo is claimed by a TASK_SUPPLY — EECH's cargo
    -- entity is a child of the factory referenced by the supply task, never repurposed; fc_msgs.c:848).
    -- The count is RECONCILED to live queued supply tasks each keysite_repair tick (supply.set_earmark),
    -- so an expired/vanished supply task can never leak an earmark.
    S.production = {
        [coalition.side.BLUE] = { ammo = 0, fuel = 0, ammo_rr = 0, fuel_rr = 0, ammo_earmark = 0, fuel_earmark = 0 },
        [coalition.side.RED]  = { ammo = 0, fuel = 0, ammo_rr = 0, fuel_rr = 0, ammo_earmark = 0, fuel_earmark = 0 },
    }

    -- recycle once-guard: group names already credited back to reserve on landing
    S._recycled = {}

    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        log_fn(string.format("supply: %s reserve seeded — striker=%d escort=%d heli=%d recon=%d veh=%d",
            cs.SIDE_NAME[side],
            M.reserve_side(side, "striker"), M.reserve_side(side, "escort"), M.reserve_side(side, "heli"),
            M.reserve_side(side, "recon"), M.reserve_side(side, "vehicle")))
        cs.dbg("supply", "%s reserve seeded: striker=%d escort=%d heli=%d recon=%d veh=%d",
            cs.SIDE_NAME[side],
            M.reserve_side(side, "striker"), M.reserve_side(side, "escort"), M.reserve_side(side, "heli"),
            M.reserve_side(side, "recon"), M.reserve_side(side, "vehicle"))
    end
end

-- ── Side resolution ───────────────────────────────────────────────────────────
local function side_of(name)
    return S.base_owner and S.base_owner[name]
end

-- ── Per-base ledger core (the assignment source) ──────────────────────────────
-- ledger(base, role) — idle count of `role` currently parked at `base` (0 if none/unowned).
function M.ledger(base, role)
    local led = base and S.base_ledger and S.base_ledger[base]
    return led and (led[role] or 0) or 0
end

-- consume_base: decrement `count` of `role` from ONE base's ledger. Mirrors add_to_force_info
-- reserve-- (force.c:241) localised to the launch keysite. false if the base lacks the stock.
function M.consume_base(base, role, count)
    count = count or 1
    local led = base and S.base_ledger and S.base_ledger[base]
    if not led then
        cs.dbg("supply", "consume_base FAIL: %s has no ledger (unowned/unknown base)", tostring(base))
        return false
    end
    local before = led[role] or 0
    if before < count then
        cs.dbg("supply", "consume_base FAIL: %s %s stock=%d < requested=%d", base, role, before, count)
        return false
    end
    led[role] = before - count
    cs.dbg("supply", "consume_base: %s %s %d -> %d (-%d)", base, role, before, led[role], count)
    return true
end

-- Fixed-wing roles can never be resident at a heli-only keysite: the EECH FARP row's air
-- capacity is rotary (ks_dbase.c:255 KEYSITE_AIR_FORCE_CAPACITY_SMALL + "FARP only behaviour");
-- FARPs get no fixed-wing runway routes (popread.c:1981-2019).
local FIXED_WING_ROLES = { striker = true, escort = true, recon = true }

local function heli_only_base(name)
    local k = S.base_kind and S.base_kind[name]
    return k == "farp" or k == "fob"
end

-- recycle_base: credit `count` of `role` back to ONE base's ledger. Mirrors
-- replace_into_force_info reserve++ (force.c:297) localised to the recipient keysite.
-- A FIXED-WING credit aimed at a heli-only FARP/FOB is REDIRECTED to the side's richest
-- fixed-wing-capable base: convert_reserves' round-robin and refund paths could otherwise stock
-- striker/escort/recon at a FARP, which the board then assigns but the builder can never launch
-- (live-observed assign→builder-fail→refund-to-same-FARP loop that starved the recon-first
-- strike spine — 36 failed recons in 30 min).
function M.recycle_base(base, role, count)
    count = count or 1
    if base and FIXED_WING_ROLES[role] and heli_only_base(base) then
        local owner, redirect, best_n = S.base_owner[base], nil, -1
        for name, own in pairs(S.base_owner) do
            if own == owner and not heli_only_base(name) then
                local n = (S.base_ledger and S.base_ledger[name] and S.base_ledger[name][role]) or 0
                if n > best_n then best_n = n; redirect = name end
            end
        end
        if redirect then
            cs.dbg("supply", "recycle_base: %s is heli-only, %s credit redirected -> %s", base, role, redirect)
            base = redirect
        end
    end
    local led = base and S.base_ledger and S.base_ledger[base]
    if not led then
        -- base not in ledger (e.g. just captured / neutral) — lazily create it so the credit is not lost.
        if base and S.base_ledger then
            led = {}; for _, r in ipairs(M.ROLES) do led[r] = 0 end
            S.base_ledger[base] = led
            cs.dbg("supply", "recycle_base: %s had no ledger, lazily created", base)
        else
            cs.dbg("supply", "recycle_base FAIL: no base name / no S.base_ledger, credit of %d %s LOST", count, role)
            return
        end
    end
    local before = led[role] or 0
    led[role] = before + count
    cs.dbg("supply", "recycle_base: %s %s %d -> %d (+%d)", base, role, before, led[role], count)
end

-- Pick the owned base with the MOST of `role` (so we don't fragment stock); nil if none has any.
local function richest_base(side, role)
    local best, best_n = nil, 0
    for name, owner in pairs(S.base_owner) do
        if owner == side then
            local n = M.ledger(name, role)
            if n > best_n then best_n = n; best = name end
        end
    end
    return best
end

-- Pick any owned base to CREDIT (prefer the one with the most of `role`, else the first owned base).
local function any_owned_base(side, role)
    return richest_base(side, role) or (function()
        for name, owner in pairs(S.base_owner) do
            if owner == side and S.base_ledger and S.base_ledger[name] then return name end
        end
        return nil
    end)()
end

-- ── Side-keyed core (EECH force_info operations) — thin wrappers over the ledger ─────────
-- reserve_side = SUM of the side's base ledgers (the per-side pool is derived, not stored).
function M.reserve_side(side, role)
    local total = 0
    for name, owner in pairs(S.base_owner) do
        if owner == side then total = total + M.ledger(name, role) end
    end
    return total
end

-- consume_side: caller does not name a base, so pick the richest owned base with >= count and
-- consume THERE. Mirrors add_to_force_info reserve-- (force.c:241).
function M.consume_side(side, role, count)
    count = count or 1
    local base = richest_base(side, role)
    if not base or M.ledger(base, role) < count then
        cs.dbg("supply", "consume_side FAIL: %s has no base with >= %d %s in stock", cs.SIDE_NAME[side], count, role)
        return false
    end
    return M.consume_base(base, role, count)
end

-- recycle_side: caller does not name a base, so credit the richest owned base's ledger.
-- Mirrors replace_into_force_info reserve++ (force.c:297).
function M.recycle_side(side, role, count)
    count = count or 1
    local base = any_owned_base(side, role)
    if not base then
        cs.dbg("supply", "recycle_side FAIL: %s owns no base, credit of %d %s LOST", cs.SIDE_NAME[side], count, role)
        return
    end
    M.recycle_base(base, role, count)
end

-- ── Production economy (KEYSITE-F5/F8) ────────────────────────────────────────
-- Credit a side's crate accumulator from its alive producers. rate is %/min (supply-points/min),
-- minutes = length of the tick (keysite supply tick = 1 min, ks_updt.c KEYSITE_UPDATE_SLEEP_TIMER).
function M.credit_production(side, ammo_rate, fuel_rate, minutes)
    local acc = S.production and S.production[side]
    if not acc then return end
    minutes = minutes or 1
    acc.ammo = acc.ammo + (ammo_rate or 0) * minutes
    acc.fuel = acc.fuel + (fuel_rate or 0) * minutes
end

-- Debit ONE crate of `commodity` ("ammo"|"fuel") for a keysite delivery; true if a crate was
-- available (KEYSITE-F8: one crate delivery restocks a consumer keysite to 100). In the PHYSICAL
-- supply-flight model this is the PICK_UP debit (taskgen.c:1638 WAYPOINT_PICK_UP): the crate leaves
-- the producer the moment the transport is spawned. A flight shot down after pick-up = crate LOST
-- (already debited, never refunded) — the interceptable-economy point of the feature.
function M.deliver_crate(side, commodity)
    local acc = S.production and S.production[side]
    if not acc or (acc[commodity] or 0) < CRATE_SIZE then return false end
    acc[commodity] = acc[commodity] - CRATE_SIZE
    cs.dbg("supply", "%s deliver_crate: %s crate picked up (%.1f remaining)", cs.SIDE_NAME[side], commodity, acc[commodity])
    return true
end

-- Refund ONE crate (re-credit the accumulator) — used when a supply flight FAILS to spawn AFTER the
-- pick-up debit (coalition.addGroup returned nil), so the committed crate is not silently lost.
function M.refund_crate(side, commodity)
    local acc = S.production and S.production[side]
    if not acc then return end
    acc[commodity] = (acc[commodity] or 0) + CRATE_SIZE
    cs.dbg("supply", "%s refund_crate: %s crate returned (%.1f banked)", cs.SIDE_NAME[side], commodity, acc[commodity])
end

-- ── Crate earmark (protect delivery-committed crates from reserve conversion) ──────────────────────
-- free_crate: is there at least one WHOLE crate of `commodity` beyond those already earmarked for
-- pending supply flights? (gate for creating a new supply flight — "if no crate banked → no flight").
function M.free_crate(side, commodity)
    local acc = S.production and S.production[side]
    if not acc then return false end
    local earmark = acc[commodity .. "_earmark"] or 0
    return (acc[commodity] or 0) - earmark * CRATE_SIZE >= CRATE_SIZE
end

-- earmark_crate: reserve one free crate (increment the earmark) so convert_reserves leaves it alone
-- until a supply flight picks it up. Returns false if no free crate exists (caller creates no flight).
function M.earmark_crate(side, commodity)
    if not M.free_crate(side, commodity) then return false end
    local acc = S.production[side]
    local key = commodity .. "_earmark"
    acc[key] = (acc[key] or 0) + 1
    cs.dbg("supply", "%s earmark_crate: %s earmark -> %d (%.1f banked)", cs.SIDE_NAME[side], commodity, acc[key], acc[commodity])
    return true
end

-- release_earmark: drop one earmark (a supply flight was picked up, aborted, or expired). Clamped >= 0.
function M.release_earmark(side, commodity)
    local acc = S.production and S.production[side]
    if not acc then return end
    local key = commodity .. "_earmark"
    acc[key] = math.max(0, (acc[key] or 0) - 1)
end

-- set_earmark: RECONCILE the earmark count to `n` (number of live queued supply tasks for this
-- commodity), clamped to the crates actually banked. Called each keysite_repair tick from the count of
-- UNASSIGNED board supply tasks, so a supply task that expired/spawned/vanished can never leak an
-- earmark (fully derived — no per-task release bookkeeping). Spawned flights drop out of the board
-- task list, so their earmark is released here the tick after pick-up (the crate was already debited).
function M.set_earmark(side, commodity, n)
    local acc = S.production and S.production[side]
    if not acc then return end
    local key = commodity .. "_earmark"
    local max_crates = math.floor((acc[commodity] or 0) / CRATE_SIZE)
    acc[key] = math.max(0, math.min(n or 0, max_crates))
end

-- Convert SURPLUS whole crates (those not spent on deliveries this tick) into reserve replacement,
-- mirroring replace_into_force_info (force.c:297) — production is what replaces hardware losses.
function M.convert_reserves(side, log_fn)
    log_fn = log_fn or function() end
    local acc = S.production and S.production[side]
    if not acc then return end
    local function drain(commodity, roles, rr_key)
        local n = 0
        -- Convert only SURPLUS crates: those beyond crates earmarked for pending physical supply
        -- flights (KEYSITE-F6/F7 delivery has priority over stockpiling reserves; the earmarked cargo
        -- is claimed by a TASK_SUPPLY and must reach the requester keysite, not become a jet).
        local earmark = acc[commodity .. "_earmark"] or 0
        while (acc[commodity] or 0) - earmark * CRATE_SIZE >= CRATE_SIZE do
            acc[commodity] = acc[commodity] - CRATE_SIZE
            local rr = (acc[rr_key] % #roles) + 1
            acc[rr_key] = rr
            M.recycle_side(side, roles[rr], 1)
            n = n + 1
        end
        if n > 0 then
            cs.dbg("supply", "%s convert_reserves: %d surplus %s crate(s) -> reserve hardware", cs.SIDE_NAME[side], n, commodity)
        end
    end
    drain("ammo", AMMO_RESERVE_ROLES, "ammo_rr")
    drain("fuel", FUEL_RESERVE_ROLES, "fuel_rr")
end

-- ── Base-name-keyed public API (unchanged signatures for existing call sites) ──
-- Now TRULY per-base (hits that base's ledger), so regen/troop/transfer operate on the exact
-- base's idle inventory. transfer's consume(donor)+produce(target) becomes a real ledger move.
function M.available(name, role)
    return M.ledger(name, role)
end

function M.consume(name, role, count)
    return M.consume_base(name, role, count)
end

-- Back-compat alias: some call sites "produce" to undo a failed consume — that is a recycle.
function M.produce(name, role, count)
    M.recycle_base(name, role, count)
end

-- ── RTB recycle handler ───────────────────────────────────────────────────────
-- On S_EVENT_LAND, an AI combat/support flight that RTBs is recycled back into its side's
-- reserve (EECH replace_into_force_info) and despawned to free the DCS slot — important for a
-- long-running MP session. Player-slot units are ignored (they are not reserve hardware).
function M.make_land_handler(log_fn)
    log_fn = log_fn or function() end
    return {
        onEvent = function(_, event)
            if event.id ~= world.event.S_EVENT_LAND then return end
            local u = event.initiator
            if not u or not u.getGroup then return end
            local ok, grp = pcall(function() return u:getGroup() end)
            if not ok or not grp or not grp:isExist() then return end
            local gname = grp:getName()

            -- Cluster 5: an RTB frees the base landing slot this sortie reserved at launch
            -- (UNLOCK_LANDING_SITE, ld_msgs.c:1567). Idempotent; runs before the classify gate so
            -- the slot is released even for a group we do not recycle into the reserve pool.
            ks.release_slot(gname)

            local role = classify_role(gname)
            if not role then return end                        -- not one of our tracked flights
            if u.getPlayerName and u:getPlayerName() then return end  -- human slot, not reserve
            S._recycled = S._recycled or {}
            if S._recycled[gname] then return end              -- already recycled this group
            S._recycled[gname] = true

            local coal = u:getCoalition()
            local side = (coal == coalition.side.BLUE) and coalition.side.BLUE or coalition.side.RED

            -- Recycle EVERY surviving airframe in the group (EECH replace_into_force_info returns
            -- each one). Spawn consumed N units; crediting only 1 would leak N-1 on every healthy
            -- multi-ship sortie. Count live units now (dead ones are already gone from the group).
            local survivors = grp:getUnits()
            local n = survivors and #survivors or 1

            -- Credit the LANDING base's ledger (force conservation with LOCATION): the flight lands
            -- at a specific keysite and its survivors become idle inventory THERE, transferable by
            -- transfer.lua thereafter. Landing base = nearest owned base to the landing position.
            local lpos = u:getPosition().p
            local land_base, best_d2 = nil, math.huge
            for bname, bowner in pairs(S.base_owner) do
                if bowner == side then
                    local bpos = S.base_pos[bname]
                    if bpos then
                        local dx = lpos.x - bpos.x; local dz = lpos.z - bpos.z
                        local d2 = dx*dx + dz*dz
                        if d2 < best_d2 then best_d2 = d2; land_base = bname end
                    end
                end
            end
            if land_base then M.recycle_base(land_base, role, n) else M.recycle_side(side, role, n) end
            log_fn(string.format("supply: %s (%s) RTB @ %s → +%d %s (base now %d / side %d)",
                gname, cs.SIDE_NAME[side], land_base or "?", n, role,
                M.ledger(land_base, role), M.reserve_side(side, role)))

            -- Despawn shortly after landing to free the slot (aircraft is now "in reserve").
            -- Group:destroy() fires NO S_EVENT_DEAD, so this does not re-enter the regen queue —
            -- load-bearing: if that DCS behaviour ever changed, a recycled airframe would also be
            -- regenerated (double-count). Any stragglers still airborne are folded into reserve too.
            timer.scheduleFunction(function()
                if grp and grp:isExist() then grp:destroy() end
                return nil
            end, nil, timer.getTime() + 30)
        end
    }
end

-- ── Reserve status logger ─────────────────────────────────────────────────────
-- Kept for observability only; periodically logs remaining reserves + crate accumulators so the
-- attrition arc AND the production economy are visible in the DCS log. The reserve pool is fed by
-- production (convert_reserves) and RTB recycle, and drained by spawns — killing enemy producers
-- flattens the reserve line, which is the whole point of the economic gap.
local SUPPLY_PERIOD = 10 * 60

function M.schedule_supply(log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    cs.dbg("supply", "reserve-status scheduler REGISTERED offset=%.0fs period=%.0fs", SUPPLY_PERIOD, SUPPLY_PERIOD)
    timer.scheduleFunction(function(_, t)
        -- INFRASTRUCTURE: reserve-status logging keeps running post-victory (EECH fc_msgs.c:163). Cluster E.
        if _DMT_GEN ~= my_gen then return nil end
        for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
            local prod = S.production and S.production[side]
            log_fn(string.format("reserve %s: striker=%d escort=%d heli=%d recon=%d veh=%d | crates ammo=%.1f fuel=%.1f | tasks failed=%d",
                cs.SIDE_NAME[side],
                M.reserve_side(side, "striker"), M.reserve_side(side, "escort"), M.reserve_side(side, "heli"),
                M.reserve_side(side, "recon"), M.reserve_side(side, "vehicle"),
                prod and prod.ammo or 0, prod and prod.fuel or 0, S.board_failed or 0))
        end
        return t + SUPPLY_PERIOD
    end, nil, timer.getTime() + SUPPLY_PERIOD)
end

return M
