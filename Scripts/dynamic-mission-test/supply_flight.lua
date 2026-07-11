-- supply_flight.lua
-- PHYSICAL supply flights — the transport that actually flies a resupply crate from a producer
-- keysite to a low consumer keysite, replacing the old instant-crate teleport in keysite_repair.
--
-- EECH source:
--   aphavoc/source/entity/special/force/fc_msgs.c:672-870  response_to_force_low_on_supplies:
--     a keysite whose ammo/fuel supply level fell to KEYSITE_SUPPLY_REQUEST_THRESHOLD (75.0,
--     en_suply.h:87) raises ENTITY_MESSAGE_FORCE_LOW_ON_SUPPLIES (keysite.c:469-494). The FORCE
--     picks the CLOSEST supplier — AMMO: nearest FACTORY (fall back OIL_REFINERY), FUEL: nearest
--     OIL_REFINERY (fall back FACTORY); an AIRBASE within range may substitute if closer
--     (fc_msgs.c:759-800) — then finds the matching cargo crate and calls create_supply_task with
--     movement_type = MOVEMENT_TYPE_AIR (fc_msgs.c:846 — the land-convoy branch is commented out in
--     the shipped source, fc_msgs.c:834-845). Dedup: one supply task per keysite PER CARGO SUB_TYPE
--     (entity_is_object_of_task + FLOAT_TYPE_TASK_USER_DATA==sub_type, fc_msgs.c:721-742).
--   aphavoc/source/ai/taskgen/taskgen.c:1638-1727  create_supply_task: TASK_SUPPLY with waypoints
--     PICK_UP (at the cargo/producer, :1707), PREPARE_FOR_DROP_OFF (stop - dir*4km, :1688-1690),
--     DROP_OFF (requester supply position, :1709), FINISH_DROP_OFF (stop + dir*2km, :1692-1694);
--     expire_time = 20*ONE_MINUTE (:1696). Start keysite = get_task_start_keysite (a friendly
--     keysite with idle transports) — the task board's launch-base selection is the port analog.
--   aphavoc/source/entity/special/task/ts_dbase.c:1386-1440  TASK_SUPPLY row: task_priority 4,
--     Escort Required Threshold 6, Movement Type MOVEMENT_TYPE_AIR, landing types
--     LANDING_FIXED_WING_TRANSPORT + LANDING_HELICOPTER, Cargo Space 5, Engage Enemy FALSE.
--   aphavoc/source/entity/special/keysite/keysite.c:337-467  update_keysite_cargo / ks_msgs.c:230,238
--     one crate delivery restocks the consumer keysite to 100.
--
-- PORT MODEL (documented divergences from the C):
--   * MOVEMENT_TYPE_AIR only. EECH's create_supply_task also serves land convoys when the caller
--     picks MOVEMENT_TYPE_LAND, but fc_msgs.c:846 hardcodes AIR for keysite resupply (the land branch
--     is commented out), and DCS exposes no road-node adjacency graph for a node-by-node convoy (the
--     documented structural road-graph limit shared with ground movement) — so AIR is both faithful to
--     the live caller and the only reproducible option.
--   * The "cargo crate" is the side-level production accumulator (supply.lua S.production), not a
--     per-factory cargo entity. The producer keysite (installations.nearest_producer) is used as the
--     PICK_UP position; the crate is debited from the accumulator at pick-up (flight spawn). A crate
--     requested but not yet picked up is EARMARKED (supply.earmark_crate) so convert_reserves cannot
--     turn it into a jet while the flight is queued — EECH's cargo, once claimed by a supply task, is
--     never repurposed.
--   * DROP_OFF is a fly-over of the consumer detected by proximity (check_arrivals); the transport
--     then RTBs and LANDS BACK AT ITS LAUNCH BASE (where the land handler recycles it to the transport
--     ledger). EECH lands at the requester; the port has no consumer-landing model, so restock is
--     triggered by the fly-over and the airframe returns home for recycle.
--   * Airframe: fixed-wing transport (config transport_fw: C-130 / An-26B) for airbase↔airbase legs;
--     transport heli (config transport_heli: UH-1H / Mi-8MT) whenever EITHER endpoint is a padless
--     FARP/FOB (no runway). Movement stays AIR either way (the ts_dbase landing types allow both).
--   * Shot down en route = crate LOST (debited at pick-up, never refunded) — the interceptable
--     economy this whole feature exists to create.

local cs      = require("campaign_state")
local croute  = require("croute")
local config  = require("config")
local supply  = require("supply")
local inst    = require("installations")
local board   = require("task_board")
local ks      = require("keysite")
local S       = cs.S
local M       = {}

-- Route cruise speed (m/s) — matches the task-board ETA gate's transport CRUISE_SPEED (task_board.lua:113).
local SUPPLY_SPEED = 100

-- Proximity a supply flight must reach at the consumer keysite for the DROP_OFF fly-over to count as
-- delivered. 4 km comfortably brackets the ~2 km a 100 m/s transport covers between 20 s arrival scans.
local DELIVERY_RADIUS = 4000

-- Arrival scan cadence — short so a fast transport's fly-over is never missed between ticks.
local ARRIVAL_SCAN_PERIOD = 20

local SUPPLY_PREFIX = "Supply"

-- ── Dedup: one live supply flight per consumer PER COMMODITY (fc_msgs.c:721-742) ───────────────────
-- Derived from live state (no per-task bookkeeping): a supply demand is "pending" if a board supply
-- task is still QUEUED for it, OR a spawned "Supply-" flight is registered against it. Both sources are
-- rebuilt from S.board_tasks / S.active_tasks, so an expired/spawned/dead flight self-clears here.
function M.has_pending(side, consumer, commodity)
    for _, t in ipairs(S.board_tasks or {}) do
        if t.state == "UNASSIGNED" and t.type == "supply" and t.side == side
           and t.target and t.target.base == consumer and t.target.commodity == commodity then
            return true
        end
    end
    for _, at in pairs(S.active_tasks or {}) do
        if at.task_type == "supply" and at.side == side and at.target_base == consumer
           and at.commodity == commodity then
            return true
        end
    end
    return false
end

-- Number of QUEUED (not-yet-spawned) supply board tasks for a side+commodity — the earmark target
-- (keysite_repair reconciles supply.set_earmark to this each tick).
function M.count_queued(side, commodity)
    local n = 0
    for _, t in ipairs(S.board_tasks or {}) do
        if t.state == "UNASSIGNED" and t.type == "supply" and t.side == side
           and t.target and t.target.commodity == commodity then
            n = n + 1
        end
    end
    return n
end

-- ── RTB / backstop recycle (transport ledger) ─────────────────────────────────────────────────────
-- A supply flight that lands at its launch base is recycled by supply.make_land_handler (classify_role
-- "Supply-" → transport). But a heli launched from a PADLESS FARP fires no S_EVENT_LAND on its RTB
-- turning point, so this backstop guarantees the transport ledger + landing slot are freed. Once-guarded
-- via the SHARED S._recycled set (so if the land handler already recycled, this no-ops). A flight shot
-- down en route reaches here with no survivors → nothing credited (the airframe is a real loss), and the
-- DEAD handlers already freed its slot + task.
local function recycle_supply_once(gname, launch_base, grp)
    S._recycled = S._recycled or {}
    if S._recycled[gname] then return end
    S._recycled[gname] = true
    local n = 0
    if grp and grp.isExist and grp:isExist() then
        local ok, units = pcall(function() return grp:getUnits() end)
        if ok and units then
            for _, u in ipairs(units) do if u and u:isExist() then n = n + 1 end end
        end
    end
    if n > 0 then supply.recycle_base(launch_base, "transport", n) end
end

local function schedule_backstop(gname, launch, grp, ab_pos, ppos, cpos)
    local function d(a, b) local x = a.x - b.x; local z = a.z - b.z; return math.sqrt(x*x + z*z) end
    local dist = d(ab_pos, ppos) + d(ppos, cpos) + d(cpos, ab_pos)
    local ttl  = dist / 40 + 600   -- conservative (40 m/s floor << the 100 m/s cruise) + 10 min margin,
                                    -- so the backstop only fires well AFTER a normal round trip would land.
    local my_gen = _DMT_GEN
    timer.scheduleFunction(function()
        if _DMT_GEN ~= my_gen then return nil end   -- stale generation: reset.nuke already cleaned up
        recycle_supply_once(gname, launch, grp)
        ks.release_slot(gname)
        if grp and grp:isExist() then grp:destroy() end
        cs.clear_task(gname)
        return nil
    end, nil, timer.getTime() + ttl)
end

-- ── Builder (task-board contract) ─────────────────────────────────────────────────────────────────
-- The board has consumed 1 "transport" from `launch`'s ledger (refunds on nil/throw). We debit the
-- crate (pick-up), spawn the transport routed launch → producer(PICK_UP) → consumer(DROP_OFF) → launch,
-- and register the task. Returns the group on success, nil on failure.
local function build_supply_flight(side, launch, consumer, cpos, commodity, prod, log_fn)
    log_fn = log_fn or function() end
    local ac = config.C.types.aircraft[side]
    local lk = S.base_kind and S.base_kind[launch]
    local ck = S.base_kind and S.base_kind[consumer]
    -- Heli when either endpoint is a padless FARP/FOB (no runway); fixed-wing transport otherwise.
    local use_heli = (lk == "farp" or lk == "fob" or ck == "farp" or ck == "fob")
    -- TWO-TIER fixed-wing fleet (gp_dbase.c:590-591 MEDIUM_LIFT = C-130J/An-12B, :631-632
    -- HEAVY_LIFT = C-17/IL-76MD): EECH's SUPPLY task accepts BOTH transport group types
    -- (suitable.c landing-type gate — FIXED_WING_TRANSPORT), and the assign flies whichever idle
    -- transport group is nearest, so C-17s hauled crates alongside C-130s. The port has no
    -- per-group airframe pool, so it ALTERNATES medium/heavy per fixed-wing flight — the same
    -- deterministic-toggle proxy the artillery uses for the tube/MLRS mix (faction.c:1633
    -- mlrs_flag pattern).
    local actype
    if use_heli then
        actype = ac.transport_heli
    else
        S.supply_heavy_flag = not S.supply_heavy_flag
        actype = (S.supply_heavy_flag and ac.transport_fw_heavy) or ac.transport_fw
        actype = actype or ac.transport_fw
    end
    local cat      = use_heli and Group.Category.HELICOPTER or Group.Category.AIRPLANE
    local country  = config.C.countries[side]

    -- LAUNCH != CONSUMER (taskgen.c:1676: `if (!get_task_start_keysite(...) || start_ks == requester)
    -- return NULL` — EECH refuses a supply task whose start keysite IS the requester). Without this a
    -- transport assigned to launch from the requesting base spawned already inside the delivery radius
    -- and "delivered" in ~20s while parked (live-caught: Supply-Kutaisi-fuel-2-2204). The board also
    -- excludes this base at assignment (exclude_target_base); this is the belt-and-braces guard.
    if launch == consumer then
        cs.dbg("supply", "%s supply build ABORT: launch == consumer %s (taskgen.c:1676) -> refund transport, retry",
            cs.SIDE_NAME[side], consumer)
        return nil
    end

    -- Re-resolve the producer at SPAWN time (board assignment lags the request by up to a pass): if the
    -- factory/refinery was destroyed or captured in the interim, EECH cancels the supply task (its cargo
    -- entity died with the keysite). Abort BEFORE any crate debit so the board just refunds the transport
    -- ledger and the task retries/expires. Otherwise route PICK_UP to the CURRENT nearest producer.
    prod = inst.nearest_producer(side, commodity, cpos)
    if not prod then
        cs.dbg("supply", "%s supply build ABORT at %s: producer died before spawn -> refund transport, retry",
            cs.SIDE_NAME[side], tostring(launch))
        return nil
    end

    -- PICK_UP debit (taskgen.c:1638 WAYPOINT_PICK_UP): the crate leaves the producer as the transport
    -- launches. No crate available → abort so the board refunds the transport ledger and retries.
    if not supply.deliver_crate(side, commodity) then
        cs.dbg("supply", "%s supply build ABORT at %s: %s crate gone before pick-up -> refund transport, retry",
            cs.SIDE_NAME[side], tostring(launch), commodity)
        return nil
    end

    -- Launch geometry: real airbase pad (TakeOff/Land) or padless FARP (ground start / RTB turning
    -- point). A fixed-wing transport only ever launches from a real airbase (use_heli forces heli at a
    -- FARP endpoint), so the padless branch is heli-only.
    local ab = Airbase.getByName(launch)
    local ab_pos, ab_id
    if ab then
        ab_pos, ab_id = ab:getPosition().p, ab:getID()
    else
        -- No runway at the launch base. A fixed-wing transport cannot ground-start off-field, so this
        -- branch is heli-only (use_heli is forced true whenever an endpoint is a FARP/FOB). Guard the
        -- latent case where a non-FARP base has no resolvable Airbase object → refund + abort.
        if not use_heli then
            supply.refund_crate(side, commodity)
            cs.dbg("supply", "%s supply build ABORT: fixed-wing launch %s has no Airbase (no runway) -> crate refunded",
                cs.SIDE_NAME[side], tostring(launch))
            return nil
        end
        local bp = S.base_pos and S.base_pos[launch]
        if not bp then
            supply.refund_crate(side, commodity)
            cs.dbg("supply", "%s supply build ABORT: launch %s unknown (no Airbase, no base_pos) -> crate refunded",
                cs.SIDE_NAME[side], tostring(launch))
            return nil
        end
        local gy = 0
        pcall(function() gy = land.getHeight({ x = bp.x, y = bp.z }) or 0 end)
        ab_pos = { x = bp.x, y = gy, z = bp.z }
    end

    local bx, by = cs.wp_xy(ab_pos)
    local px, py = cs.wp_xy(prod.pos)
    local dx, dy = cs.wp_xy(cpos)
    local sid    = cs.next_id()
    local gname  = string.format("Supply-%s-%s-%d-%d", consumer:sub(1, 8), commodity, side, sid)
    local alt      = use_heli and 150 or 3000
    local alt_type = use_heli and "RADIO" or "BARO"

    local depart, rtb
    if ab_id then
        depart = { type="TakeOff", action="From Parking Area", airdromeId=ab_id, alt=ab_pos.y,
                   alt_type="BARO", speed=0, ETA=0, ETA_locked=true, x=bx, y=by, name="Depart", formation_template="" }
        rtb    = { type="Land", action="Landing", airdromeId=ab_id, alt=ab_pos.y, alt_type="BARO",
                   speed=SUPPLY_SPEED, ETA=0, ETA_locked=false, x=bx, y=by, name="RTB", formation_template="" }
    else
        depart = { type="TakeOffGroundHot", action="From Ground Area Hot", alt=ab_pos.y, alt_type="BARO",
                   speed=0, ETA=0, ETA_locked=true, x=bx, y=by, name="Depart", formation_template="" }
        rtb    = { type="Turning Point", action="Turning Point", alt=alt, alt_type=alt_type,
                   speed=SUPPLY_SPEED, ETA=0, ETA_locked=false, x=bx, y=by, name="RTB", formation_template="" }
    end

    local gspec = {
        name = gname, task = "Transport", hidden = false,
        units = {{ name=gname.."-1", type=actype, skill="High",
            x=ab_pos.x, y=ab_pos.z, alt=ab_pos.y, alt_type="BARO", speed=0, heading=0,
            payload={ fuel = use_heli and 2200 or 12000 } }},
        route = { points = croute.expand({
            depart,
            { type="Turning Point", action="Turning Point", alt=alt, alt_type=alt_type,
              speed=SUPPLY_SPEED, ETA=0, ETA_locked=false, x=px, y=py, name="PickUp", formation_template="" },
            { type="Turning Point", action="Fly Over Point", alt=alt, alt_type=alt_type,
              speed=SUPPLY_SPEED, ETA=0, ETA_locked=false, x=dx, y=dy, name="DropOff", formation_template="" },
            rtb,
        }, side, { alt=alt, alt_type=alt_type, speed=SUPPLY_SPEED, name="Nav" }) },
    }
    if ab_id then gspec.airdromeId = ab_id end

    local ok_s, grp = pcall(coalition.addGroup, country, cat, gspec)
    if ok_s and grp then
        -- Crate physically picked up → drop its earmark (reconcile would too next tick; immediate for clarity).
        supply.release_earmark(side, commodity)
        cs.register_task(gname, { task_type="supply", side=side, target_base=consumer, target_pos=cpos,
            commodity=commodity, launch_base=launch, born_time=timer.getTime(),
            -- PICK_UP-before-DROP_OFF sequencing (taskgen.c:1709-1711 waypoint order): the arrival
            -- scan must see the transport AT the producer before a consumer flyover counts as a
            -- delivery — otherwise a route that skims the consumer early "delivers" without cargo.
            producer_pos = { x = prod.pos.x, z = prod.pos.z }, picked_up = false })
        -- Escort assessment (assign.c:598; TASK_SUPPLY threshold 6). Rear resupply legs run over own
        -- territory, so route_difficulty ≈ 0 and this is effectively inert — wired for fidelity.
        if cs.escort_count("supply", side, ab_pos, cpos, log_fn) > 0 then
            pcall(function() require("heli_war").spawn_escort(side, cpos, log_fn) end)
        end
        schedule_backstop(gname, launch, grp, ab_pos, prod.pos, cpos)
        log_fn(string.format("%s SUPPLY flight #%d: %s crate %s → %s (via producer %s, %s)",
            cs.SIDE_NAME[side], sid, commodity, launch, consumer, prod.name, use_heli and "heli" or "fixed-wing"))
        cs.dbg("supply", "%s supply flight %s DISPATCHED: %s pick-up @ %s -> drop @ %s, RTB %s (%s)",
            cs.SIDE_NAME[side], gname, commodity, prod.name, consumer, launch, actype)
        return grp
    end

    -- Spawn failed AFTER the pick-up debit → return the crate; board refunds the transport ledger.
    supply.refund_crate(side, commodity)
    cs.dbg("supply", "%s supply flight SPAWN FAILED from %s -> %s (%s): crate refunded, pcall_ok=%s err=%s",
        cs.SIDE_NAME[side], tostring(launch), consumer, tostring(actype), tostring(ok_s), tostring(grp))
    return nil
end

-- ── Request path (called from keysite_repair for each low consumer keysite) ────────────────────────
-- Picks the nearest ALIVE producer (PICK_UP), earmarks a crate, and queues a board supply task
-- targeting the consumer. Gates (all mirror the EECH request path):
--   * dedup one live task per consumer per commodity                       (fc_msgs.c:721-742)
--   * no live producer alive → no flight (economy strangulation preserved) (fc_msgs.c:802 `if factory`)
--   * no free crate banked → no flight                                     (fc_msgs.c:820 `if cargo`)
function M.request(side, consumer, commodity, log_fn)
    log_fn = log_fn or function() end
    local cpos = S.base_pos and S.base_pos[consumer]
    if not cpos then return false end
    if M.has_pending(side, consumer, commodity) then return false end
    local prod = inst.nearest_producer(side, commodity, cpos)
    if not prod then
        cs.dbg("supply", "%s supply request for %s %s: NO live producer -> no flight (strangled)",
            cs.SIDE_NAME[side], consumer, commodity)
        return false
    end
    if not supply.free_crate(side, commodity) then
        cs.dbg("supply", "%s supply request for %s %s: no crate banked -> no flight",
            cs.SIDE_NAME[side], consumer, commodity)
        return false
    end
    -- Earmark the crate so convert_reserves leaves it for this flight (released at pick-up / reconcile).
    supply.earmark_crate(side, commodity)
    board.create_task({
        type = "supply", side = side, count = 1, log_fn = log_fn,
        -- taskgen.c:1676: the start keysite must not be the requester — the board skips the
        -- consumer itself when picking the launch base (else the transport "delivers" while parked).
        exclude_target_base = true,
        target = { base = consumer, pos = cpos, commodity = commodity,
                   producer_name = prod.name, producer_pos = prod.pos,
                   objective = { kind = "keysite", base = consumer } },
        builder = function(launch)
            return build_supply_flight(side, launch, consumer, cpos, commodity, prod, log_fn)
        end,
    })
    cs.dbg("supply", "%s supply task QUEUED: %s %s (producer %s)", cs.SIDE_NAME[side], consumer, commodity, prod.name)
    return true
end

-- ── Delivery detection: DROP_OFF fly-over of the consumer keysite ──────────────────────────────────
-- Mirrors troop.check_landing_helis: scan own-side "Supply-" groups; the first that reaches within
-- DELIVERY_RADIUS of ITS OWN registered consumer keysite restocks that keysite to 100 for its commodity
-- (ks_msgs.c:230,238), once. The transport then RTBs on its own (recycled by the land handler / backstop).
local function scan_side(side, log_fn)
    local grps = coalition.getGroups(side)
    if not grps then return end
    S.supply_delivered = S.supply_delivered or {}
    local done = S.supply_delivered
    for _, grp in ipairs(grps) do
        if grp and grp:isExist() then
            local gname = grp:getName()
            if gname:match("^" .. SUPPLY_PREFIX .. "%-") and not done[gname] then
                local task = cs.get_task(gname)
                if task and task.task_type == "supply" then
                    local consumer, commodity = task.target_base, task.commodity
                    local cpos = consumer and S.base_pos[consumer]
                    local u = grp:getUnit(1)
                    if cpos and u and u:isExist() then
                        local hp = u:getPosition().p
                        -- Phase 1 — PICK_UP: the transport must first reach the producer (waypoint
                        -- order taskgen.c:1709-1711). Until then, consumer proximity does NOT count
                        -- (a transport spawning near — or overflying — the consumer has no cargo yet).
                        if not task.picked_up and task.producer_pos then
                            local px, pz = hp.x - task.producer_pos.x, hp.z - task.producer_pos.z
                            if px*px + pz*pz <= DELIVERY_RADIUS * DELIVERY_RADIUS then
                                task.picked_up = true
                                cs.dbg("supply", "%s supply flight %s PICK-UP confirmed at producer (%.0fm)",
                                    cs.SIDE_NAME[side], gname, math.sqrt(px*px + pz*pz))
                            end
                        end
                        local dx, dz = hp.x - cpos.x, hp.z - cpos.z
                        if task.picked_up and dx*dx + dz*dz <= DELIVERY_RADIUS * DELIVERY_RADIUS then
                            done[gname] = true   -- once per flight either way (spent even if it can't restock)
                            -- Only restock if the consumer is STILL friendly: a base captured by the enemy
                            -- while the transport was en route gets no free refill (EECH's supply task
                            -- cancels when the requester keysite flips). The crate is spent regardless
                            -- (picked up at the producer) — an interdicted/overrun delivery is a loss.
                            if S.base_owner[consumer] == side then
                                -- One crate delivery fully restocks the consumer (keysite.c:438-467 / ks_msgs.c:230,238).
                                if commodity == "ammo" then
                                    S.base_ammo = S.base_ammo or {}; S.base_ammo[consumer] = 100.0
                                else
                                    S.base_fuel = S.base_fuel or {}; S.base_fuel[consumer] = 100.0
                                end
                                log_fn(string.format("supply: %s %s delivered to %s → restocked to 100 (%s)",
                                    cs.SIDE_NAME[side], commodity, consumer, gname))
                                cs.dbg("supply", "%s supply flight %s reached %s (%.0fm): %s restocked to 100%% — RTB",
                                    cs.SIDE_NAME[side], gname, consumer, math.sqrt(dx*dx + dz*dz), commodity)
                            else
                                cs.dbg("supply", "%s supply flight %s reached %s but it flipped enemy — crate lost, no restock",
                                    cs.SIDE_NAME[side], gname, consumer)
                            end
                        end
                    end
                end
            end
        end
    end
end

function M.check_arrivals(log_fn)
    log_fn = log_fn or function() end
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        scan_side(side, log_fn)
    end
end

function M.schedule_arrivals(log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    cs.dbg("supply", "supply-flight arrival scanner REGISTERED period=%.0fs", ARRIVAL_SCAN_PERIOD)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end   -- re-injection guard
        local ok, err = pcall(M.check_arrivals, log_fn)
        if not ok then log_fn("supply_flight arrival scan error: " .. tostring(err)) end
        return t + ARRIVAL_SCAN_PERIOD
    end, nil, timer.getTime() + ARRIVAL_SCAN_PERIOD)
end

return M
