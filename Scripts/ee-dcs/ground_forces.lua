-- ground_forces.lua
-- EECH source:
--   aphavoc/source/ai/highlevl/highlevl.c   create_advance_and_retreat_tasks (12 min campaign,
--                                            highlevl.c:250): advances the best frontline group ONE
--                                            road-node toward the warmest reachable node; retreat
--                                            emerges when forward nodes are hostile (:505-543).
--   aphavoc/source/ai/highlevl/order.c       initialise_armoured_divisions: the frontline is a
--                                            STANDING set of ground groups (ground registry), grouped
--                                            into divisions (ceil(count/12)) — NOT one column.
--   aphavoc/source/ai/faction/faction.c      initialise_frontline_forces (:1500-1662): places PRIMARY
--                                            (:1520-1562), SECONDARY (:1565-1600) and ARTILLERY
--                                            (:1602-1661) groups at road nodes. This module ports all
--                                            three: primary tank column (spawn_group), SP artillery
--                                            (spawn_arty_group), and the second-echelon SECONDARY group
--                                            (spawn_sec_group) behind each frontline base.
--   aphavoc/source/entity/special/group/group.h  GROUP.route_node, frontline_flag.
--
-- Port model: a STANDING FRONTLINE of N ground groups per side (one per frontline base), created at
-- OOB and drawn from the side's "vehicle" reserve. This replaces the old single-column-per-side.
-- Keysites are the movement "nodes": each group drives base-to-base toward the nearest enemy base,
-- retargets when its objective is captured, and retreats to the nearest friendly base when cut off.
--
-- STRUCTURAL LIMIT (documented, not a proxy we can close): DCS exposes no road-node adjacency graph,
-- so EECH's true node-by-node road pathfinding and "move one group one node per tick" discretisation
-- cannot be reproduced. Continuous vehicle movement between keysite nodes is the closest achievable;
-- the front paces itself through vehicle speed rather than a per-tick node step.

local cs      = require("campaign_state")
local keysite = require("keysite")
local supply  = require("supply")
local config  = require("config")
local S       = cs.S
local M       = {}

local mode       = require("campaign_mode")   -- Item 5: mode-selected cadence
local GND_PERIOD = mode.SCHED.ground.period    -- highlevl.c:250 campaign 12min / :224 skirmish 15min
local COL_SPEED  = 8         -- m/s ≈ 29 km/h

-- Artillery advance halt distance: batteries advance with the front (highlevl.c:433 — the
-- advance/retreat candidate filter is `if (group_database[sub_type].frontline_flag)`, NON-zero,
-- so ARTILLERY(3) advances exactly like PRIMARY(1) tank groups) but hold INSIDE firing range of
-- the contact line rather than driving into it: create_artillery_strike_tasks engages targets
-- within weapon range (highlevl.c:2939-3081). 15 km = 0.75 × the 20 km ARTY_DEFAULT_RANGE
-- envelope in cas_bai_sead (margin so the whole battery is in range of the base point).
local ARTY_STANDOFF = 15000
local FRONT_DIST = config.C.theatre.front_dist    -- m; a friendly base this close to an enemy base is "frontline" (config theatre)
local CUTOFF_HP  = 0.5       -- retreat when group strength (alive fraction) drops below this

-- ── COMPOSITIONS: EECH formation-component DATA, not the gp_dbase labels ──────────────────────────
-- The real member composition of every EECH ground group is DATA: setup/common/data/FORMCOMP.DAT
-- (the default formation-component database). create_faction_members consumes it slot-by-slot in
-- FILE ORDER — components[loop*2] = BLUE vehicle, components[loop*2+1] = RED vehicle, for
-- loop = 0..number-1 (faction.c:661/666) — so a group of size N fields the FIRST N slots. The
-- gp_dbase.c default_blue/red_force_sub_type (M1A2/T80U) is only the fallback single type; the
-- placed PRIMARY_FRONTLINE_GROUP is COMBINED ARMS with ORGANIC AD (the earlier "all-tank" reading
-- of the gp_dbase labels was a misalignment — corrected against FORMCOMP.DAT:434-469).
-- COUNTRY_OF + the FORMCOMP.DAT ordered slot rows are hoisted to config.lua (types.ground.*), with the
-- per-row FORMCOMP citations kept ON THE DEFAULTS there. SIDE_COL maps a side to its column (1=BLUE,
-- 2=RED) into those {BLUE, RED} rows.
local COUNTRY_OF = config.C.countries
local SIDE_COL = { [coalition.side.BLUE] = 1, [coalition.side.RED] = 2 }   -- {BLUE, RED} column
local PRIMARY_SLOTS = config.C.types.ground.primary_slots     -- FORMCOMP.DAT:434-469 (:COUNT 16)
local SECONDARY_SLOTS = config.C.types.ground.secondary_slots -- FORMCOMP.DAT:475-511 (:COUNT 16)
local ARTY_SLOTS    = config.C.types.ground.arty_slots        -- FORMCOMP.DAT:549-562 (:COUNT 4)
local MLRS_SLOTS    = config.C.types.ground.mlrs_slots        -- FORMCOMP.DAT:566-579 (:COUNT 4)

-- Primary frontline group size: faction.c:1540-1542 places
--   number = (int)((safe_radius / 4.0) + sfrand1() * 2.0), bound to [1, force_size].
-- With EECH's default road-node safe_radius ~28 this is int(28/4) ± 2 = 7 ± 2. Proxy: 7 + rand(-2,2).
local function primary_group_size()
    return math.max(1, 7 + math.random(-2, 2))
end

-- Artillery group size: faction.c:1640-1644 places number = (int)(safe_radius/5.0) then bounds it by
-- size = min(force_size, formation_component_data->count) — the ARTILLERY/MLRS component :COUNT is 4
-- (FORMCOMP.DAT:552/:569; gp_dbase.c:810 maximum_member_count agrees). 4 IS the component count, and
-- the group fields all 4 ordered slots (2 guns + truck + scout), not 4 guns.
local ARTY_GROUP_SIZE = 4   -- FORMCOMP.DAT:552/:569 :COUNT 4 (= faction.c:1642-1644 bound)

-- Combined-arms PRIMARY-frontline group: the first N ordered FORMCOMP slots for this side
-- (create_faction_members consumes slots in file order, faction.c:661/666). A 7-group is therefore
-- 2 tanks + IFV + SHORAD + IFV + SAM + APC — combined arms with organic AD, per FORMCOMP.DAT:438-450.
local function group_comp(side)
    local col = SIDE_COL[side]
    local n   = math.min(primary_group_size(), #PRIMARY_SLOTS)
    local out = {}
    for i = 1, n do out[i] = PRIMARY_SLOTS[i][col] end
    return out
end

-- ── SECONDARY (second-echelon) frontline group ────────────────────────────────────────────────────
-- EECH faction.c:1565-1600 places FORMATION_COMPONENT_SECONDARY_FRONTLINE_GROUP at
-- FRONTLINE_FORCE_SECONDARY road nodes — nodes marked BEHIND the primary line — group type
-- GROUP_SECONDARY_FRONTLINE (frontline_flag SECONDARY, gp_dbase.c:764). Same 7±2 size formula as the
-- primary line (faction.c:1579-1581 = the primary :1540-1542 form). Composition is FORMCOMP.DAT:475-511
-- (:COUNT 16), consumed slot-by-slot in file order (faction.c:661/666), so a size-N group fields the
-- FIRST N ordered slots: 2 tanks + SHORAD + IFV + cargo truck + tank + fuel truck + scout for N=7 —
-- combined arms with organic AD (Chaparral/SA-13 at slot 2), a fuel truck at slot 6, a BRDM/HMMWV scout
-- at slot 7.
--
-- SECOND-ECHELON MOVEMENT PROXY (documented divergence): DCS has no road-node adjacency graph, so
-- EECH's "warm node behind the primary line" placement + advance can't be reproduced node-by-node. The
-- port models it as: the group holds SEC_STANDOFF behind its side's NEAREST FRIENDLY FRONTLINE base,
-- toward the side's own rear, and re-routes to follow when the front moves (the nearest friendly
-- frontline base changes) — see advance_retreat step 2c. It never drives at enemy bases (that is
-- PRIMARY's job, spawn_group); following the moving front is the faithful proxy for EECH's warm-node
-- advance eventually pulling the secondaries forward.
local SEC_STANDOFF = 10000   -- m; designer proxy: second echelon sits ~10 km behind the front (no EECH
                             -- metric constant — EECH uses road-node topology the port cannot mirror)
local SEC_REAR_OFFSET = 4000 -- m; OOB spawn offset toward the side's rear (behind the arty's ~1.5 km)

-- Combined-arms SECONDARY-frontline group: the first N ordered FORMCOMP-secondary slots for this side.
local function sec_group_comp(side)
    local col = SIDE_COL[side]
    local n   = math.min(primary_group_size(), #SECONDARY_SLOTS)   -- same 7±2 size (faction.c:1579-1581)
    local out = {}
    for i = 1, n do out[i] = SECONDARY_SLOTS[i][col] end
    return out
end

-- ── Node helpers (keysites = nodes) ───────────────────────────────────────────
local function nearest_base_of(owner_side, pos)
    local best, best_d = nil, math.huge
    for name, owner in pairs(S.base_owner) do
        if owner == owner_side then
            local bp = S.base_pos[name]
            if bp then
                local d = cs.dist2d(pos.x, pos.z, bp.x, bp.z)
                if d < best_d then best_d = d; best = name end
            end
        end
    end
    return best, best_d
end

-- Frontline bases for `side`: friendly bases within FRONT_DIST of any enemy base.
local function frontline_bases(side)
    local enemy, out = cs.ENEMY[side], {}
    for name, owner in pairs(S.base_owner) do
        if owner == side then
            local bp = S.base_pos[name]
            if bp then
                for ename, eowner in pairs(S.base_owner) do
                    if eowner == enemy then
                        local ep = S.base_pos[ename]
                        if ep and cs.dist2d(bp.x, bp.z, ep.x, ep.z) <= FRONT_DIST then
                            out[#out + 1] = name; break
                        end
                    end
                end
            end
        end
    end
    return out
end

local function lead_pos(grp)
    local u = grp:getUnit(1)
    if u and u:isExist() then return u:getPosition().p end
    return nil
end

local function alive_fraction(grp, want)
    local units = grp:getUnits()
    local n = units and #units or 0
    return (want > 0) and (n / want) or 0
end

-- Re-task an existing ground group to drive to a new objective (On Road).
local function reroute(grp, to_pos)
    if not to_pos then return end
    local from = lead_pos(grp)
    if not from then return end
    local mx, mz = (from.x + to_pos.x) * 0.5, (from.z + to_pos.z) * 0.5
    local ctrl = grp:getController()
    if not ctrl then return end
    ctrl:setTask({
        id = "Mission",
        params = { route = { points = {
            { type="Turning Point", action="On Road", speed=COL_SPEED, ETA=0, ETA_locked=false,
              alt=land.getHeight({x=mx, y=mz}), alt_type="BARO", x=mx, y=mz, name="Via", formation_template="" },
            { type="Turning Point", action="On Road", speed=COL_SPEED, ETA=0, ETA_locked=false,
              alt=land.getHeight({x=to_pos.x, y=to_pos.z}), alt_type="BARO",
              x=to_pos.x, y=to_pos.z, name="Objective", formation_template="" },
        } } },
    })
end

-- Artillery variant: approach On Road (march like any column) but DEPLOY the final leg Off Road
-- at the exact dispersed slot — reroute()'s On-Road terminal snaps every battery back onto the
-- road network, which collapsed the standoff-ring dispersion and piled batteries on one road
-- (live-observed). EECH batteries occupy their node position, not the road line (faction.c:1602).
local function arty_reroute(grp, to_pos)
    if not to_pos then return end
    local from = lead_pos(grp)
    if not from then return end
    local mx, mz = (from.x + to_pos.x) * 0.5, (from.z + to_pos.z) * 0.5
    local ctrl = grp:getController()
    if not ctrl then return end
    ctrl:setTask({
        id = "Mission",
        params = { route = { points = {
            { type="Turning Point", action="On Road", speed=COL_SPEED, ETA=0, ETA_locked=false,
              alt=land.getHeight({x=mx, y=mz}), alt_type="BARO", x=mx, y=mz, name="Via", formation_template="" },
            { type="Turning Point", action="Off Road", speed=COL_SPEED, ETA=0, ETA_locked=false,
              alt=land.getHeight({x=to_pos.x, y=to_pos.z}), alt_type="BARO",
              x=to_pos.x, y=to_pos.z, name="Deploy", formation_template="" },
        } } },
    })
end

-- ── Spawn one frontline group at home_base, driving toward target_base ────────
local function spawn_group(side, home_base, target_base, log_fn)
    if not supply.consume_side(side, "vehicle", 1) then
        log_fn(cs.SIDE_NAME[side] .. " ground: vehicle reserve exhausted")
        cs.dbg("ground", "%s spawn_group ABORT: vehicle reserve exhausted", cs.SIDE_NAME[side])
        return false
    end
    local home = S.base_pos[home_base]
    local tpos = S.base_pos[target_base]
    if not home or not tpos then
        supply.recycle_side(side, "vehicle", 1)
        cs.dbg("ground", "%s spawn_group ABORT: missing position for %s or %s -> refunded",
            cs.SIDE_NAME[side], tostring(home_base), tostring(target_base))
        return false
    end

    local comp = group_comp(side)   -- ordered FORMCOMP slot types (first N, faction.c:661/666)
    local id   = cs.next_id()
    local name = string.format("GndCol-%d-%d", side, id)
    -- Snap the jittered spawn origin off water (coastal base); fallback = the base centre `home`.
    local sp = cs.snap_land(home.x + math.random(-800, 800), home.z + math.random(-800, 800), home.x, home.z)
    local sx, sz = sp.x, sp.z

    local units = {}
    for ui, utype in ipairs(comp) do
        local ux, uz = sx + (ui-1)*30, sz + (ui-1)*15
        units[ui] = { name=name.."-"..ui, type=utype, skill="Average",
            x=ux, y=uz, alt=land.getHeight({x=ux, y=uz}), alt_type="BARO",
            heading=cs.heading_to(sx, sz, tpos.x, tpos.z) }
    end
    local want = #units

    local mx, mz = (sx + tpos.x) * 0.5, (sz + tpos.z) * 0.5
    -- pcall the addGroup: a THROW here would leak the consumed vehicle (same class as the escort
    -- builders' MED-2 fix) — contained throw/nil both refund below.
    local ok_g, grp = pcall(coalition.addGroup, COUNTRY_OF[side], Group.Category.GROUND, {
        name = name, hidden = false, units = units,
        route = { points = {
            { type="Turning Point", action="On Road", speed=COL_SPEED, ETA=0, ETA_locked=false,
              alt=land.getHeight({x=sx, y=sz}), alt_type="BARO", x=sx, y=sz, name="Start", formation_template="" },
            { type="Turning Point", action="On Road", speed=COL_SPEED, ETA=0, ETA_locked=false,
              alt=land.getHeight({x=mx, y=mz}), alt_type="BARO", x=mx, y=mz, name="Via", formation_template="" },
            { type="Turning Point", action="On Road", speed=COL_SPEED, ETA=0, ETA_locked=false,
              alt=land.getHeight({x=tpos.x, y=tpos.z}), alt_type="BARO",
              x=tpos.x, y=tpos.z, name="Objective", formation_template="" },
        } },
    })
    if ok_g and grp then
        S.ground_groups[side][name] = { grp=grp, target_base=target_base, home_base=home_base, want=want }
        log_fn(string.format("GndCol %s: %d units %s → %s", name, want, home_base, target_base))
        cs.dbg("ground", "%s spawned: %d units %s -> %s", name, want, home_base, target_base)
        return true
    end
    supply.recycle_side(side, "vehicle", 1)  -- refund: spawn failed/threw
    cs.dbg("ground", "%s SPAWN FAILED %s -> %s (pcall_ok=%s) -> refunded", name, home_base, target_base, tostring(ok_g))
    return false
end

-- ── Spawn one SP-artillery/MLRS group behind home_base ───────────────────────
-- EECH FRONTLINE_FORCE_ARTILLERY (faction.c:1602-1661): artillery groups start at artillery
-- nodes supporting the frontline. They then ADVANCE with the front like every frontline_flag
-- group (highlevl.c:433) — see the 2b arty-advance step in advance_retreat, which walks them to
-- ARTY_STANDOFF of the nearest enemy base so run_artillery has targets in its fire envelope.
-- Tagged "Arty-" (cas_bai_sead.run_artillery keys on it) and tracked in the SEPARATE
-- S.arty_groups registry (advance_retreat moves them with arty semantics, not column semantics).
-- Alternates tube / MLRS per the mlrs_flag toggle (faction.c:1624-1633). Consumes 1 "vehicle"
-- from reserve, exactly like spawn_group.
local function spawn_arty_group(side, home_base, use_mlrs, log_fn)
    if not supply.consume_side(side, "vehicle", 1) then
        cs.dbg("ground", "%s artillery ABORT: vehicle reserve exhausted", cs.SIDE_NAME[side])
        return false
    end
    local home = S.base_pos[home_base]
    if not home then
        supply.recycle_side(side, "vehicle", 1)
        return false
    end
    -- Ordered slot list (FORMCOMP.DAT ARTILLERY_GROUP :549-562 / MLRS_GROUP :566-579): the battery
    -- fields 2 guns + supply truck + scout, consumed slot-by-slot (faction.c:661/666) — NOT 4 guns.
    local slots = use_mlrs and MLRS_SLOTS or ARTY_SLOTS
    local col   = SIDE_COL[side]
    local id    = cs.next_id()
    local name  = string.format("Arty-%d-%d", side, id)
    -- Place a little behind the base (into its own rear = away from the nearest enemy base).
    local ex, ez = home.x, home.z + 1
    local eb = nearest_base_of(cs.ENEMY[side], home)
    if eb and S.base_pos[eb] then ex, ez = S.base_pos[eb].x, S.base_pos[eb].z end
    local dx, dz = home.x - ex, home.z - ez
    local len = math.max(math.sqrt(dx*dx + dz*dz), 1)
    -- ~1.5 km into the rear; snap off water (a rear offset at a coastal base can be wet), fallback = home.
    local sp = cs.snap_land(home.x + dx/len * 1500 + math.random(-200, 200),
                            home.z + dz/len * 1500 + math.random(-200, 200), home.x, home.z)
    local sx, sz = sp.x, sp.z

    local units = {}
    for i = 1, math.min(ARTY_GROUP_SIZE, #slots) do
        local ux, uz = sx + (i-1)*35, sz
        units[i] = { name = name.."-"..i, type = slots[i][col], skill = "Average",
            x = ux, y = uz, alt = land.getHeight({x=ux, y=uz}), alt_type = "BARO", heading = 0 }
    end
    -- pcall the addGroup: a THROW (e.g. an unverified artillery type name rejected by the DB) must
    -- refund the consumed vehicle, not leak it (escort builders' MED-2 pattern).
    local ok_g, grp = pcall(coalition.addGroup, COUNTRY_OF[side], Group.Category.GROUND, {
        name = name, hidden = false, units = units,
        route = { points = {
            { type="Turning Point", action="Off Road", speed=0, ETA=0, ETA_locked=true,
              alt=land.getHeight({x=sx, y=sz}), alt_type="BARO", x=sx, y=sz, name="Hold", formation_template="" },
        } },
    })
    if ok_g and grp then
        S.arty_groups[side][name] = { grp = grp, home_base = home_base }
        log_fn(string.format("Artillery %s: %d units (2×%s + truck + scout) at %s",
            name, #units, slots[1][col], home_base))
        cs.dbg("ground", "%s artillery spawned: %d units lead=%s at %s (mlrs=%s)",
            name, #units, slots[1][col], home_base, tostring(use_mlrs))
        return true
    end
    supply.recycle_side(side, "vehicle", 1)   -- refund: spawn failed/threw
    cs.dbg("ground", "%s artillery SPAWN FAILED at %s (pcall_ok=%s) -> refunded", name, home_base, tostring(ok_g))
    return false
end

-- ── Spawn one SECONDARY (second-echelon) frontline group behind home_base ─────
-- EECH FRONTLINE_FORCE_SECONDARY (faction.c:1565-1600): a second-echelon combined-arms group placed at
-- a road node BEHIND the primary line. Port: spawn it SEC_REAR_OFFSET into home_base's own rear (away
-- from the nearest enemy base — same away-from-enemy vector the arty uses, but a larger offset so the
-- secondary sits behind both the primary line and the artillery). Consumes 1 "vehicle" from reserve,
-- refund-on-fail/throw exactly like spawn_group / spawn_arty_group. Tagged "GndSec-" so
-- cas_bai_sead.group_frontline_flag classes it SECONDARY(2) → a BAI target (never CAS, never SEAD).
local function spawn_sec_group(side, home_base, log_fn)
    if not supply.consume_side(side, "vehicle", 1) then
        log_fn(cs.SIDE_NAME[side] .. " secondary: vehicle reserve exhausted")
        cs.dbg("ground", "%s spawn_sec_group ABORT: vehicle reserve exhausted", cs.SIDE_NAME[side])
        return false
    end
    local home = S.base_pos[home_base]
    if not home then
        supply.recycle_side(side, "vehicle", 1)
        cs.dbg("ground", "%s spawn_sec_group ABORT: missing position for %s -> refunded",
            cs.SIDE_NAME[side], tostring(home_base))
        return false
    end
    -- Rear vector: away from the nearest enemy base (into this side's own rear).
    local ex, ez = home.x, home.z + 1
    local eb = nearest_base_of(cs.ENEMY[side], home)
    if eb and S.base_pos[eb] then ex, ez = S.base_pos[eb].x, S.base_pos[eb].z end
    local dx, dz = home.x - ex, home.z - ez
    local len = math.max(math.sqrt(dx*dx + dz*dz), 1)
    -- Second-echelon rear offset; snap off water at a coastal base, fallback = the base centre `home`.
    local sp = cs.snap_land(home.x + dx/len * SEC_REAR_OFFSET + math.random(-200, 200),
                            home.z + dz/len * SEC_REAR_OFFSET + math.random(-200, 200), home.x, home.z)
    local sx, sz = sp.x, sp.z

    local comp = sec_group_comp(side)   -- ordered FORMCOMP-secondary slot types (first N)
    local id   = cs.next_id()
    local name = string.format("GndSec-%d-%d", side, id)
    local units = {}
    for ui, utype in ipairs(comp) do
        local ux, uz = sx + (ui-1)*30, sz + (ui-1)*15
        units[ui] = { name=name.."-"..ui, type=utype, skill="Average",
            x=ux, y=uz, alt=land.getHeight({x=ux, y=uz}), alt_type="BARO", heading=0 }
    end
    local want = #units
    -- pcall the addGroup: a THROW (e.g. an unverified secondary type rejected by the DB) must refund
    -- the consumed vehicle, not leak it (spawn_group / spawn_arty_group MED-2 pattern).
    local ok_g, grp = pcall(coalition.addGroup, COUNTRY_OF[side], Group.Category.GROUND, {
        name = name, hidden = false, units = units,
        route = { points = {
            { type="Turning Point", action="Off Road", speed=0, ETA=0, ETA_locked=true,
              alt=land.getHeight({x=sx, y=sz}), alt_type="BARO", x=sx, y=sz, name="Hold", formation_template="" },
        } },
    })
    if ok_g and grp then
        S.sec_groups[side][name] = { grp = grp, home_base = home_base, want = want }
        log_fn(string.format("GndSec %s: %d units (2nd echelon) behind %s", name, want, home_base))
        cs.dbg("ground", "%s secondary spawned: %d units lead=%s behind %s", name, want, comp[1], home_base)
        return true
    end
    supply.recycle_side(side, "vehicle", 1)   -- refund: spawn failed/threw
    cs.dbg("ground", "%s secondary SPAWN FAILED behind %s (pcall_ok=%s) -> refunded", name, home_base, tostring(ok_g))
    return false
end

-- ── OOB init: seed the standing frontline + supporting artillery ──────────────
function M.init_oob(log_fn)
    log_fn = log_fn or function() end
    S.ground_groups = { [coalition.side.BLUE] = {}, [coalition.side.RED] = {} }
    S.arty_groups   = { [coalition.side.BLUE] = {}, [coalition.side.RED] = {} }
    S.sec_groups    = { [coalition.side.BLUE] = {}, [coalition.side.RED] = {} }
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local fbases = frontline_bases(side)
        -- WARZONE RESERVE-SEED ANALOG (parser.c:1397-1435): EECH seeds each force's reserve hardware
        -- from warzone DATA sized to cover the actual OOB placement — the reserve is never smaller
        -- than what initialise_order_of_battle places. The port's RESERVE_PER_BASE.vehicle (=2) is
        -- airbase-only scenario data predating the per-frontline-base OOB (tank company + artillery
        -- battery + SECONDARY second-echelon group — three vehicle groups per frontline base), so
        -- supplement the vehicle pool up to the real placement demand BEFORE placement, rather than
        -- hand-tuning the per-base constant.
        local demand = 3 * #fbases   -- 1 tank + 1 artillery + 1 secondary group per frontline base
        local have   = supply.reserve_side(side, "vehicle")
        if have < demand then
            supply.recycle_side(side, "vehicle", demand - have)
            cs.dbg("ground", "%s OOB vehicle reserve topped up %d -> %d (3 x %d frontline bases; "
                .. "parser.c:1397-1435 warzone reserve-seed analog)", cs.SIDE_NAME[side], have, demand, #fbases)
        end
        local mlrs = false
        for _, base in ipairs(fbases) do
            local tgt = nearest_base_of(cs.ENEMY[side], S.base_pos[base])
            if tgt then spawn_group(side, base, tgt, log_fn) end
            -- One SP-artillery group supporting each frontline base (faction.c artillery node ~=
            -- adjacent to a frontline node); alternate tube/MLRS (faction.c:1624-1633 mlrs_flag).
            spawn_arty_group(side, base, mlrs, log_fn)
            mlrs = not mlrs
            -- One SECONDARY (second-echelon) group behind each frontline base (faction.c:1565-1600
            -- FRONTLINE_FORCE_SECONDARY node behind the primary line). Holds/follows the front (2c).
            spawn_sec_group(side, base, log_fn)
        end
        local n_grp, n_arty, n_sec = 0, 0, 0
        for _ in pairs(S.ground_groups[side]) do n_grp = n_grp + 1 end
        for _ in pairs(S.arty_groups[side]) do n_arty = n_arty + 1 end
        for _ in pairs(S.sec_groups[side]) do n_sec = n_sec + 1 end
        log_fn(string.format("ground OOB: %s frontline = %d group(s) + %d artillery + %d secondary group(s)",
            cs.SIDE_NAME[side], n_grp, n_arty, n_sec))
        cs.dbg("ground", "init_oob: %s frontline bases=%d, tank groups=%d, artillery groups=%d, secondary groups=%d",
            cs.SIDE_NAME[side], #fbases, n_grp, n_arty, n_sec)
    end
end

-- Nearest enemy base to pos NOT already targeted by another friendly group (occupancy
-- deconfliction, highlevl.c:514 side_occupying check), excluding `self_base`.
local function nearest_unoccupied_enemy(side, pos, occupied)
    local enemy = cs.ENEMY[side]
    local best, best_d = nil, math.huge
    for name, owner in pairs(S.base_owner) do
        if owner == enemy and not occupied[name] then
            local bp = S.base_pos[name]
            if bp then
                local d = cs.dist2d(pos.x, pos.z, bp.x, bp.z)
                if d < best_d then best_d = d; best = name end
            end
        end
    end
    return best
end

-- ── Advance / retreat / reinforce tick ────────────────────────────────────────
local function advance_retreat(side, log_fn)
    local groups = S.ground_groups[side]
    if not groups then return end
    local enemy = cs.ENEMY[side]

    -- 1. Prune dead; note which bases already have a live group (home + objective occupancy).
    local alive_count, homes_covered, occupied = 0, {}, {}
    for gname, rec in pairs(groups) do
        if not cs.group_is_alive(rec.grp) then
            groups[gname] = nil  -- dead → replaced by reinforcement below (ground regen, #14)
        else
            alive_count = alive_count + 1
            if rec.home_base then homes_covered[rec.home_base] = true end
            if rec.target_base and S.base_owner[rec.target_base] == enemy then
                occupied[rec.target_base] = true
            end
        end
    end

    -- 2. Retarget / retreat survivors.
    local n_retreated, n_advanced = 0, 0
    for gname, rec in pairs(groups) do
        if cs.group_is_alive(rec.grp) then
            local gpos = lead_pos(rec.grp)
            if gpos then
                local frac   = alive_fraction(rec.grp, rec.want or 4)
                local fb, fd = nearest_base_of(side, gpos)
                if frac < CUTOFF_HP then
                    -- Retreat: weakened group falls back to the nearest friendly base and HOLDS
                    -- there (advance is gated on strength below, so no flip-flop).
                    if fb and fd and fd > 20000 and rec.target_base ~= fb then
                        rec.target_base = fb
                        reroute(rec.grp, S.base_pos[fb])
                        log_fn(string.format("GndCol %s retreating → %s (str %.0f%%)", gname, fb, frac*100))
                        cs.dbg("ground", "%s retreating -> %s (str=%.0f%%)", gname, fb, frac * 100)
                        n_retreated = n_retreated + 1
                    end
                else
                    -- Advance: only healthy groups advance, to the nearest UNOCCUPIED enemy base,
                    -- if the current objective is no longer enemy-owned or a closer node opened up.
                    if S.base_owner[rec.target_base] ~= enemy then
                        occupied[rec.target_base] = nil
                        local eb = nearest_unoccupied_enemy(side, gpos, occupied)
                        if eb and rec.target_base ~= eb then
                            rec.target_base = eb
                            occupied[eb] = true
                            reroute(rec.grp, S.base_pos[eb])
                            log_fn(string.format("GndCol %s advancing → %s", gname, eb))
                            cs.dbg("ground", "%s advancing -> %s", gname, eb)
                            n_advanced = n_advanced + 1
                        end
                    end
                end
            end
        end
    end

    -- 2b. ARTILLERY ADVANCE (live-validation fix): EECH's advance candidate filter is
    -- `if (group_database[sub_type].frontline_flag)` — NON-zero — so ARTILLERY(3) groups advance
    -- with the front exactly like PRIMARY tank groups (highlevl.c:433; the earlier "artillery
    -- never advances" note on spawn_arty_group was a misreading — faction.c artillery nodes are
    -- only the INITIAL placement). Without this, batteries parked at their home base sat
    -- permanently outside the 20 km fire envelope and run_artillery assigned 0 missions all
    -- campaign. A battery moves toward the nearest enemy base and HALTS at ARTY_STANDOFF, inside
    -- firing range; it re-routes when the front (nearest enemy base) changes.
    local n_arty_adv = 0
    for aname, arec in pairs((S.arty_groups and S.arty_groups[side]) or {}) do
        if cs.group_is_alive(arec.grp) then
            local apos = lead_pos(arec.grp)
            if apos then
                local eb, ed = nearest_base_of(enemy, apos)
                local bp = eb and S.base_pos[eb]
                if eb and bp and ed and ed > ARTY_STANDOFF and arec.moving_to ~= eb then
                    local dx, dz = bp.x - apos.x, bp.z - apos.z
                    local len = math.max(math.sqrt(dx*dx + dz*dz), 1)
                    -- DISPERSED firing positions: every battery heading for the same enemy base
                    -- must NOT share one halt coordinate — that live-piled all 5 batteries onto a
                    -- single road point (converging columns jam the DCS ground AI). EECH spreads
                    -- artillery across DISTINCT artillery nodes along the front (faction.c:
                    -- 1602-1661, one node per group), so each battery takes its own slot on the
                    -- standoff ring: a deterministic lateral offset (perpendicular to the
                    -- approach), slot index from the battery's spawn id, ~2 km apart.
                    local id   = tonumber(aname:match("(%d+)$")) or 0
                    local slot = (id % 5) - 2                       -- -2..2 → 5 spread positions
                    local px, pz = -dz / len, dx / len              -- unit perpendicular
                    -- Snap the deploy point off water so a battery isn't ordered into the sea and
                    -- stranded on the shoreline; fallback = the battery's CURRENT position (don't move
                    -- if no land found near the standoff slot — hold rather than march into water).
                    local dp = cs.snap_land(bp.x - dx/len * ARTY_STANDOFF + px * slot * 2000,
                                            bp.z - dz/len * ARTY_STANDOFF + pz * slot * 2000,
                                            apos.x, apos.z)
                    arty_reroute(arec.grp, { x = dp.x, z = dp.z })
                    arec.moving_to = eb
                    n_arty_adv = n_arty_adv + 1
                    cs.dbg("ground", "%s artillery advancing toward %s (halt at %.0f km standoff, slot %+d)",
                        aname, eb, ARTY_STANDOFF / 1000, slot)
                end
            end
        else
            S.arty_groups[side][aname] = nil   -- prune dead batteries (no auto-replacement; reserve-bound)
        end
    end

    -- 2c. SECONDARY (second-echelon) MOVEMENT: EECH secondaries sit at road nodes BEHIND the primary
    -- line and are pulled forward as the warm-node front advances (faction.c:1565-1600 place; the
    -- advance candidate filter `if (group_database[sub_type].frontline_flag)` at highlevl.c:433 is
    -- NON-zero so SECONDARY(2) advances too). DCS has no node graph, so the port proxies "behind the
    -- moving front" by tracking each secondary to its side's NEAREST FRIENDLY FRONTLINE base and holding
    -- SEC_STANDOFF into that base's rear; when the front moves (the nearest friendly frontline base
    -- changes) the group re-routes to follow. It never drives at enemy bases (PRIMARY's job).
    local fbases = frontline_bases(side)
    local n_sec_moved = 0
    for sname, srec in pairs((S.sec_groups and S.sec_groups[side]) or {}) do
        if cs.group_is_alive(srec.grp) then
            local spos = lead_pos(srec.grp)
            if spos and #fbases > 0 then
                -- nearest friendly frontline base to this group
                local fb, fd = nil, math.huge
                for _, b in ipairs(fbases) do
                    local bp = S.base_pos[b]
                    if bp then
                        local d = cs.dist2d(spos.x, spos.z, bp.x, bp.z)
                        if d < fd then fd = d; fb = b end
                    end
                end
                if fb and srec.behind_base ~= fb then
                    local bp = S.base_pos[fb]
                    -- Rear vector for that frontline base = away from ITS nearest enemy base.
                    local eb = nearest_base_of(enemy, bp)
                    local ep = eb and S.base_pos[eb] or { x = bp.x, z = bp.z - 1 }
                    local dx, dz = bp.x - ep.x, bp.z - ep.z
                    local len = math.max(math.sqrt(dx*dx + dz*dz), 1)
                    -- Deterministic lateral slot (from spawn id) so co-located secondaries don't pile on
                    -- one hold coordinate (mirrors the arty standoff-ring dispersion).
                    local id   = tonumber(sname:match("(%d+)$")) or 0
                    local slot = (id % 5) - 2
                    local px, pz = -dz / len, dx / len
                    -- Snap the follow-the-front hold point off water; fallback = the group's CURRENT
                    -- position (hold rather than route the second echelon into the sea).
                    local dp = cs.snap_land(bp.x + dx/len * SEC_STANDOFF + px * slot * 1500,
                                            bp.z + dz/len * SEC_STANDOFF + pz * slot * 1500,
                                            spos.x, spos.z)
                    arty_reroute(srec.grp, { x = dp.x, z = dp.z })
                    srec.behind_base = fb
                    n_sec_moved = n_sec_moved + 1
                    cs.dbg("ground", "%s secondary following front: holding %.0f km behind %s (slot %+d)",
                        sname, SEC_STANDOFF / 1000, fb, slot)
                end
            end
        else
            S.sec_groups[side][sname] = nil   -- prune dead secondaries (no auto-replacement; reserve-bound)
        end
    end

    -- 3. Reinforce: one group per frontline base that has lost its company (draws from the
    --    depleting "vehicle" reserve — the pool exhaustion is what ends the ground war).
    -- No survival gate: EECH create_advance_and_retreat_tasks (highlevl.c) reinforces/advances the
    -- ground front regardless of force strength — the pool exhaustion is the only brake. The former
    -- STRENGTH_SURVIVAL skip was invented (Cluster E).
    local n_reinforced = 0
    for _, base in ipairs(frontline_bases(side)) do
        if not homes_covered[base] then
            local tgt = nearest_unoccupied_enemy(side, S.base_pos[base], occupied)
                      or nearest_base_of(enemy, S.base_pos[base])
            if tgt and spawn_group(side, base, tgt, log_fn) then
                homes_covered[base] = true
                if S.base_owner[tgt] == enemy then occupied[tgt] = true end
                n_reinforced = n_reinforced + 1
            else
                break  -- reserve dry
            end
        end
    end
    cs.dbg("ground", "%s advance/retreat tick: %d alive, %d retreated, %d advanced, %d reinforced, %d arty advancing, %d secondary moved",
        cs.SIDE_NAME[side], alive_count, n_retreated, n_advanced, n_reinforced, n_arty_adv, n_sec_moved)
end

-- ── Persistence respawn (WAVE 2) ──────────────────────────────────────────────────────────────────
-- Re-create a saved ground/arty/sec group from a persist.lua SUMMARY on campaign restore. RESERVE-
-- NEUTRAL by design: the restored S.base_ledger already reflects the "vehicle" these groups consumed
-- when first spawned, so respawning must NOT consume (or refund) reserve again — it only re-materialises
-- the DCS group at its saved position with its saved surviving unit count and re-registers it. The unit
-- composition is the FIRST n ordered FORMCOMP slots for the kind (exactly as the original spawn built
-- it, faction.c:661/666); the mobile-OOB movement re-derives on the next advance/retreat tick.
-- summ = { name, side, kind ∈ {"primary","arty","sec"}, home_base, target_base, n_alive, want, lead={x,z} }
local KIND_SLOTS = { primary = PRIMARY_SLOTS, arty = ARTY_SLOTS, sec = SECONDARY_SLOTS }
local KIND_REG   = { primary = "ground_groups", arty = "arty_groups", sec = "sec_groups" }

function M.respawn_saved(summ, log_fn)
    log_fn = log_fn or function() end
    if type(summ) ~= "table" then return false end
    local side  = summ.side
    local kind  = summ.kind
    local slots = KIND_SLOTS[kind]
    local regk  = KIND_REG[kind]
    local lead  = summ.lead
    if not slots or not regk or not lead or (side ~= coalition.side.BLUE and side ~= coalition.side.RED) then
        cs.dbg("ground", "respawn_saved SKIP: bad summary (kind=%s side=%s)", tostring(kind), tostring(side))
        return false
    end
    local col = SIDE_COL[side]
    local n   = math.max(1, math.min(tonumber(summ.n_alive) or 1, #slots))
    -- Snap the saved lead point off water (a coastal front can drift wet); fallback = the point itself.
    local sp = cs.snap_land(lead.x, lead.z, lead.x, lead.z)
    local sx, sz = sp.x, sp.z
    local name = summ.name or string.format("Gnd-%s-%d-%d", tostring(kind), side, cs.next_id())

    local units = {}
    for i = 1, n do
        local ux, uz = sx + (i - 1) * 30, sz + (i - 1) * 15
        units[i] = { name = name .. "-" .. i, type = slots[i][col], skill = "Average",
            x = ux, y = uz, alt = land.getHeight({ x = ux, y = uz }), alt_type = "BARO", heading = 0 }
    end

    -- Route: a primary column drives toward its saved objective (so it keeps advancing/capturing);
    -- arty/sec spawn on a hold point and re-route themselves on the next tick (moving_to/behind_base
    -- start nil → 2b/2c re-issue their standoff route).
    local points
    local tpos = summ.target_base and S.base_pos[summ.target_base]
    if kind == "primary" and tpos then
        local mx, mz = (sx + tpos.x) * 0.5, (sz + tpos.z) * 0.5
        points = {
            { type = "Turning Point", action = "On Road", speed = COL_SPEED, ETA = 0, ETA_locked = false,
              alt = land.getHeight({ x = sx, y = sz }), alt_type = "BARO", x = sx, y = sz, name = "Start", formation_template = "" },
            { type = "Turning Point", action = "On Road", speed = COL_SPEED, ETA = 0, ETA_locked = false,
              alt = land.getHeight({ x = mx, y = mz }), alt_type = "BARO", x = mx, y = mz, name = "Via", formation_template = "" },
            { type = "Turning Point", action = "On Road", speed = COL_SPEED, ETA = 0, ETA_locked = false,
              alt = land.getHeight({ x = tpos.x, y = tpos.z }), alt_type = "BARO", x = tpos.x, y = tpos.z, name = "Objective", formation_template = "" },
        }
    else
        points = {
            { type = "Turning Point", action = "Off Road", speed = 0, ETA = 0, ETA_locked = true,
              alt = land.getHeight({ x = sx, y = sz }), alt_type = "BARO", x = sx, y = sz, name = "Hold", formation_template = "" },
        }
    end

    local ok_g, grp = pcall(coalition.addGroup, COUNTRY_OF[side], Group.Category.GROUND, {
        name = name, hidden = false, units = units, route = { points = points },
    })
    if ok_g and grp then
        S[regk] = S[regk] or { [coalition.side.BLUE] = {}, [coalition.side.RED] = {} }
        S[regk][side] = S[regk][side] or {}
        if kind == "primary" then
            S[regk][side][name] = { grp = grp, target_base = summ.target_base, home_base = summ.home_base, want = summ.want or n }
        elseif kind == "sec" then
            S[regk][side][name] = { grp = grp, home_base = summ.home_base, want = summ.want or n }
        else -- arty
            S[regk][side][name] = { grp = grp, home_base = summ.home_base }
        end
        cs.dbg("ground", "respawn_saved: %s (%s) %d units at (%.0f,%.0f) home=%s target=%s",
            name, tostring(kind), n, sx, sz, tostring(summ.home_base), tostring(summ.target_base))
        return true
    end
    cs.dbg("ground", "respawn_saved SPAWN FAILED: %s (%s) pcall_ok=%s", name, tostring(kind), tostring(ok_g))
    return false
end

function M.schedule_ground(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    cs.dbg("ground", "%s scheduler REGISTERED offset=%.0fs period=%.0fs", cs.SIDE_NAME[side], initial_offset, GND_PERIOD)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end    -- re-injection guard: cancel superseded closure
        -- Item 6 (LITERAL post-victory semantics): the ground war continues after the win is declared —
        -- EECH fc_msgs.c:163 gates ONLY the win-check re-award, never the highlevl.c generators. The
        -- prior Cluster-E ground-advance suppression is removed (it was a proxy, not the literal C).
        local ok, err = pcall(advance_retreat, side, log_fn)
        if not ok then log_fn("ground error: " .. tostring(err)) end
        return t + GND_PERIOD
    end, nil, timer.getTime() + initial_offset)
end

return M
