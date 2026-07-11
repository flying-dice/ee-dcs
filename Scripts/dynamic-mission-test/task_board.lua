-- task_board.lua
-- EECH source:
--   aphavoc/source/entity/system/en_types/en_task.h   TASK_STATE_TYPES (UNASSIGNED/ASSIGNED/
--                                                      COMPLETED, :83-90), TASK_TERMINATED_TYPES
--                                                      (EXPIRE_TIME_REACHED, :115-127)
--   aphavoc/source/entity/special/task/task.c          task list membership / state machine
--                                                      (get_local_task_list_type :561-589)
--   aphavoc/source/entity/special/task/ts_updt.c        update_server: UNASSIGNED expire_timer
--                                                      countdown → TASK_TERMINATED (:99-124)
--   aphavoc/source/entity/special/task/ts_dbase.c       per-type task_priority / expiry defaults
--   aphavoc/source/ai/taskgen/assign.c                 assign_keysite_tasks (sort by priority,
--                                                      critical ×2, :201-212); get_suitable_
--                                                      registered_group (LOWEST-positive-suitability
--                                                      winner, best_result=FLT_MAX / result<best,
--                                                      :433-501, the quirk at :497); locality gate
--   aphavoc/source/ai/highlevl/suitable.c              group×task suitability matrix
--   aphavoc/source/entity/special/keysite/keysite.h    KEYSITE_TASK_ASSIGN_TIMER = 3 min (:69)
--
-- THE ASSIGNMENT ENGINE (Cluster 4). Shipped EECH does NOT spawn fresh aircraft per task: order
-- generation creates TASK entities and this engine matches them to EXISTING idle groups resident
-- at keysites. The port previously fresh-spawned per task (no unassigned pool, no suitability, no
-- failure path). This module restores the shipped model with a DCS-shaped ledger:
--
--   * Idle aircraft = a PER-BASE ledger (supply.lua S.base_ledger) — counts by role at each owned
--     base, a documented proxy for EECH's live aircraft parked at keysites (DCS cannot keep
--     hundreds of parked AI aircraft alive).
--   * Generators create_task(...) an UNASSIGNED record instead of spawning.
--   * tick() drains the board: sort by priority (critical ×2, assign.c:201-204); for each task pick
--     the suitable base inventory (SUIT matrix → role; assign.c:497 LOWEST-positive-suitability
--     winner reproduced exactly; distance a pass/fail gate, TASK-F14); consume that base's ledger;
--     physically spawn via the generator's builder; mark ASSIGNED. On spawn failure → refund the
--     ledger, task STAYS UNASSIGNED for retry until expiry (refund discipline).
--   * UNASSIGNED past its unassigned-expiry (ts_updt.c:99-124) → FAILED, removed — the real
--     task-failure path that the fresh-spawn port never had.
--
-- Dedup: while a task is UNASSIGNED the board keeps a synthetic marker in S.active_tasks (keyed
-- "board:<id>", shaped {task_type,target_base,side}) so the existing cs.has_task_against() /
-- reaction dedup guards transparently see QUEUED-but-not-yet-spawned tasks. On assignment the
-- marker is dropped and the freshly spawned group registers under its real name (reaction's BIRTH
-- path). So a target is never double-tasked whether the prior task is queued or already flying.
--
-- Reaction unchanged: the ASSIGNED transition IS the DCS S_EVENT_BIRTH (the group is physically
-- created at assignment), and completion is RTB (S_EVENT_LAND) — exactly what reaction.lua already
-- keys off (ENTITY_MESSAGE_TASK_ASSIGNED / TASK_COMPLETED). The board owns create→assign→expire.

local cs     = require("campaign_state")
local supply = require("supply")
local ks     = require("keysite")
local S      = cs.S
local M      = {}

-- ── Assignment cadence ─────────────────────────────────────────────────────────
-- KEYSITE_TASK_ASSIGN_TIMER = 3.0 * ONE_MINUTE (eech keysite.h:69; spec 07 TASK-F9). EECH runs a
-- per-keysite pass every 3 min (staggered by frand1()*3min at ks_creat.c:166); the port has no
-- per-keysite timers, so one global board pass every 3 min stands in.
local ASSIGN_CADENCE = 3 * 60

-- ── Per-type task_priority (eech ts_dbase.c; spec 07 Table A / spec 04 §2) ─────
-- heli_escort is the port's escort-at-assignment task (spawn_escort, immediate); priced at the
-- escort band. (anti_armour/hunter_killer rows removed with their retired generators, Cluster H.)
M.PRIORITY = {
    ground_strike = 9, oca_strike = 6, oca_sweep = 7, cas = 6, bai = 4, sead = 9,
    recon = 7, bda = 9, troop_insertion = 10, heli_escort = 7,
    supply = 4,   -- ts_dbase.c:1391 TASK_SUPPLY task_priority = 4 (TASK_CATEGORY_SUPPORT)
}

-- ── Critical flag (eech generator `critical=` argument; spec 04 F6/F7/F8) ──────
-- Critical tasks sort at ×2 priority (assign.c:201-204).
M.CRITICAL = { oca_strike = true, oca_sweep = true, troop_insertion = true }

-- ── Per-creator UNASSIGNED expiry (eech taskgen.c; spec 07 TASK-F8), seconds ───
-- Zero expire timer = never expires in EECH; every port task type has a finite window here so the
-- failure path always exists. recon = 10 min is the shortest (taskgen.c:1477) and the generic
-- unassigned-expiry the design emphasises; the rotary composite reuses it.
M.EXPIRY = {
    ground_strike = 40 * 60, oca_strike = 30 * 60, oca_sweep = 30 * 60,
    cas = 20 * 60, bai = 20 * 60, sead = 30 * 60, recon = 10 * 60,
    bda = 30 * 60, troop_insertion = 45 * 60, heli_escort = 10 * 60,
    supply = 20 * 60,   -- taskgen.c:1696 create_supply_task expire_time = 20 * ONE_MINUTE
}
local UNASSIGNED_EXPIRY_DEFAULT = 10 * 60

-- ── Suitability matrix: task type → acceptable {role, suitability} (eech suitable.c) ──
-- Each entry is a group×task suitability value (>0). The assignment keeps the LOWEST-positive
-- suitability candidate (assign.c:497 quirk — "least over-qualified", best_result=FLT_MAX,
-- result<best). Port roles are effectively 1:1 with task types (as EECH's data is effectively 1.0
-- for every capable group — spec 07 §6.1), so the matrix is single-role per task; the lowest-
-- positive comparison is reproduced across candidate BASES (each owned base = a candidate "group").
M.SUIT = {
    ground_strike = { { role = "striker", s = 1.0 } },
    oca_strike    = { { role = "striker", s = 1.0 } },
    cas           = { { role = "heli",    s = 1.0 } },  -- CAS/BAI are the rotary frontline fight in
    bai           = { { role = "heli",    s = 1.0 } },  -- EECH → attack helis from the nearest FARP
    sead          = { { role = "striker", s = 1.0 } },  -- SEAD stays fixed-wing (Wild Weasel)
    oca_sweep     = { { role = "escort",  s = 1.0 } },
    recon         = { { role = "recon",   s = 1.0 } },
    bda           = { { role = "heli",    s = 1.0 } },
    troop_insertion = { { role = "transport", s = 1.0 } },  -- transport heli (UH-1H/Mi-8MT), its OWN
                                                             -- pool — not the attack-heli pool that
                                                             -- heli_war drains dry at the frontline
    heli_escort   = { { role = "heli",    s = 1.0 } },
    supply        = { { role = "transport", s = 1.0 } },  -- physical resupply flight (supply_flight.lua):
                                                          -- fixed-wing transport (C-130/An-26B) airbase↔
                                                          -- airbase, or transport heli when an endpoint is
                                                          -- a padless FARP. Shares the transport ledger.
}

-- ── ESCORT speed-class suitability check (eech assign.c:318-363) — DOCUMENTED AS IMPOSSIBLE HERE ─────
-- WAVE 3 Item 3a: EECH's suitable_group_task_specific_checks gates a TASK_ESCORT group by movement class
-- (assign.c:318-363): "Jets escort Jets, Helis escort anything but jets" — a fast objective (movement
-- speed >= 5) requires a fast escort and vice-versa, and an escort must not be slower than its objective.
-- The port has NO analogous runtime check, and deliberately so: its role model makes a class mismatch
-- structurally impossible, so coding the check would be dead code. The port has exactly two escort task
-- surfaces, each bound by this SUIT matrix to a single airframe class:
--   • heli_escort → role "heli" ONLY (attack helis). It only ever escorts other HELICOPTERS
--     (transport / BDA / troop-insertion helis, heli_war.spawn_escort), so escort and objective are both
--     rotary — a heli-escorts-jet / jet-escorts-heli pairing can never arise.
--   • oca_sweep   → role "escort" ONLY (fixed-wing fighters), sweeping ahead of fixed-wing strike.
-- Because the board can only ever match each escort task to its one correct class, the assign.c:318-363
-- gate is satisfied by construction; there is nothing to test at assignment time.

-- ── Per-role cruise speed (m/s) — the port's ACTUAL route velocities ───────────
-- EECH's locality gate reads each group's live FLOAT_TYPE_CRUISE_VELOCITY (group.c:296). The port has
-- no per-group velocity model, so the ETA gate uses the fixed cruise speed each role's spawner
-- actually flies its route at — the faithful stand-in for "the group's own cruise velocity". Each
-- value is cited to the port module that flies it (source of truth) and to group.c for the model:
--   striker   220  — attack_waves.lua:68 / cas_bai_sead.lua:133 STRIKE_SPEED (ground/OCA strike, SEAD)
--   escort    220  — cas_bai_sead.lua:293 / attack_waves.lua:289 escort leg flies at STRIKE_SPEED
--   recon     300  — recon.lua:33 RECON_SPEED (fast recon dash in/out)
--   heli       55  — heli_war.lua:40 HELI_SPEED (attack-heli CAS/BAI/BDA/anti-armour/HK/escort cruise)
--   transport 100  — troop.lua:267 troop-insertion ingress leg speed
local CRUISE_SPEED = {
    striker = 220, escort = 220, recon = 300, heli = 55, transport = 100,
}
local CRUISE_SPEED_DEFAULT = 100   -- conservative fallback for any un-tabled role

-- ── Locality gate — EECH ETA test (assess_group_task_locality_factor, group.c:245-336) ──
-- EECH accepts a group for a task iff its ETA to the task keysite is within the task's expire timer:
--   eta = distance / cruise_speed;  reject iff eta > FLOAT_TYPE_EXPIRE_TIMER   (group.c:298,314)
-- i.e. accept iff  distance <= cruise_speed(role) × expire_timer(task).  The port reuses its per-type
-- unassigned-expiry (M.EXPIRY — the taskgen expire_timer values, ts_updt.c) as that timer and each
-- role's actual route cruise speed (CRUISE_SPEED) as the group velocity. This replaces the old flat
-- MAX_ASSIGN_RANGE 400 km hack (which sat arbitrarily between the real per-type reaches): the ETA gate
-- legitimises long FIXED-WING reach (ground strike 220 m/s × 40 min ≈ 528 km — the anti-stalemate reach
-- the flat cap was hand-tuned to allow) while correctly CAPPING helicopters (CAS 55 m/s × 20 min ≈ 66 km
-- — the flat 400 km wrongly let FARP helis accept tasks they could never reach in time; EECH rejects
-- them). TASK-F14 realigned. `t` carries its own expire window (t.expiry_t - t.created_t == M.EXPIRY
-- value, honouring any per-task spec.expiry override).
local function eta_range(role, t)
    -- REMAINING window, not the total: EECH's expire_timer counts DOWN (ts_updt.c:107
    -- `raw->expire_timer -= get_delta_time()`) and group.c:314 compares eta against that live
    -- value — the acceptance radius SHRINKS as a task ages. Using the total window over-ranged
    -- stale tasks (a 35-min-old ground strike kept its full 528 km reach with 5 min left).
    local window = t.expiry_t - timer.getTime()
    if window <= 0 then return 0 end
    return (CRUISE_SPEED[role] or CRUISE_SPEED_DEFAULT) * window
end

-- ── Per-keysite assign budget (eech assign_task_count, assign.c:218; ks_dbase.c:118 airbase=3) ──
-- EECH assigns at most `assign_task_count` (airbase = 3) tasks FROM a keysite per assignment pass
-- (assign.c:218 `assign_count = max(assign_task_count,1u)`; loop breaks at :224 when it hits 0). The
-- port's board is one global pass, so this caps how many tasks a single base may launch per tick —
-- once a base has been chosen 3 times this pass it is skipped, and the task falls through to the next
-- base (or stays UNASSIGNED for retry). Reset at the top of each M.tick.
local ASSIGN_BUDGET_PER_BASE = 3
local _assign_count = {}   -- base_name -> assignments made THIS board pass (reset in M.tick)

-- ── Minimum idle reserve per role (eech get_suitable_registered_group, assign.c:465-474) ──────────
-- EECH will not assign an idle group unless the keysite's idle count OF THAT GROUP SUB_TYPE strictly
-- exceeds group_database[sub_type].minimum_idle_count (assign.c:474 `idle_count > minimum_idle_count`) —
-- a per-group-type DEFENSIVE RESERVE the assignment engine never spends offensively. It is a compiled-in
-- group_database constant (gp_dbase.c), NOT warzone data. Per-role values, mapped to the EECH group
-- sub_type each port role represents (assigning one group consumes one group, so the port keeps MIN_IDLE
-- aircraft of the role idle after the task: ledger >= t.count + MIN_IDLE):
--   heli      = 2  — ENTITY_SUB_TYPE_GROUP_ATTACK_HELICOPTER minimum_idle_count (gp_dbase.c:114); the
--                    RECON_ATTACK_HELICOPTER row is 3 (gp_dbase.c:319) but the port's single "heli" role
--                    is the plain attack helicopter, so its reserve (2) is used.
--   striker   = 1  — ENTITY_SUB_TYPE_GROUP_CLOSE_AIR_SUPPORT_AIRCRAFT (gp_dbase.c:565): CAS/OCA/SEAD jets.
--   escort    = 1  — ENTITY_SUB_TYPE_GROUP_MULTI_ROLE_FIGHTER (gp_dbase.c:442): CAP/BARCAP/sweep fighters.
--   recon     = 0  — ENTITY_SUB_TYPE_GROUP_RECON_HELICOPTER (gp_dbase.c:278): no reserve.
--   transport = 0  — MEDIUM/HEAVY_LIFT_TRANSPORT_HELICOPTER (gp_dbase.c:360/401): no reserve.
--   vehicle   = 0  — frontline ground groups (gp_dbase.c:729/770): no reserve.
local MIN_IDLE = { heli = 2, striker = 1, escort = 1, recon = 0, transport = 0, vehicle = 0 }

-- ── Non-USABLE keysite ×2 assign interval (eech ks_updt.c:118-123) ─────────────────────────────────
-- EECH doubles a keysite's assign_timer when its keysite_usable_state != KEYSITE_STATE_USABLE
-- (ks_updt.c:120-123), so a not-fully-repaired keysite runs its assignment pass HALF as often. USABLE is
-- set only when keysite_strength == keysite_maximum_strength; a captured/struck keysite below full
-- strength is KEYSITE_STATE_REPAIRING (keysite.c:1468-1474). The port's board is ONE global 3-min pass,
-- so the faithful proxy is: a non-usable (below-full-strength) base participates as a launch candidate
-- every OTHER pass — a per-base skip flag toggles each tick (S.base_assign_toggle) and, while set, this
-- table excludes the base from owned_bases for the current pass. Recomputed at the top of M.tick.
local _skip_pass = {}   -- base_name -> true when skipped THIS board pass (Item 5)

-- ── Player task reservation count (eech ks_dbase.c:119 airbase reserve_task_count = 2) ──
-- Per assign pass EECH holds back up to `reserve_task_count` FRESH, NON-CRITICAL tasks so a human
-- gunship pilot can take them before the AI does (assign.c:220,244-255). Airbase row = 2
-- (ks_dbase.c:119). Applied in M.tick's assignment loop (see the block there for the full semantics).
local RESERVE_TASK_COUNT = 2

-- ── Player-flyable task set (single source of truth: pilots.PLAYER_FLYABLE) ────────────────────
-- The reservation narrows to task types a human can actually fly here (the port's gunship-mission
-- set). pilots.lua owns that list (PLAYER_FLYABLE); we read it rather than duplicate it. A deferred
-- require avoids the pilots<->task_board load cycle (pilots requires task_board at load, so a
-- top-level require back would be circular); by the time M.tick first fires, pilots is fully loaded
-- and require() returns the cached module. Cached on first successful resolve.
local _player_flyable
local function player_flyable_set()
    if not _player_flyable then
        local ok, pilots = pcall(require, "pilots")
        if ok and pilots then _player_flyable = pilots.PLAYER_FLYABLE end
    end
    return _player_flyable
end

local _tid = 0
local function next_tid() _tid = _tid + 1; return _tid end

-- Owned, usable bases sorted nearest-first to `pos` (nil pos → health order).
local function owned_bases(side, pos)
    local out = {}
    for name, owner in pairs(S.base_owner) do
        -- Item 1: a dormant FARP (not yet in_use — sector not friendly) is not a launch candidate
        -- (eech nearest-keysite search skips !in_use keysites, keysite.c:369).
        if owner == side and not _skip_pass[name] and cs.base_is_active(name) then   -- Item 5: non-USABLE base skips alternate passes
            local h = S.base_health[name] or 1.0
            if h >= cs.HEALTH_NEUTRALISED then   -- USABLE iff eff >= min (keysite.c:827-830, inclusive)
                local bpos = S.base_pos[name]
                if bpos then
                    local d = pos and cs.dist2d(pos.x, pos.z, bpos.x, bpos.z) or 0
                    out[#out + 1] = { name = name, pos = bpos, d = d, h = h }
                end
            end
        end
    end
    if pos then
        table.sort(out, function(a, b) return a.d < b.d end)
    else
        table.sort(out, function(a, b) return a.h > b.h end)
    end
    return out
end

-- ── create_task ────────────────────────────────────────────────────────────────
-- spec = { type, side, target = {base=, pos=, group=, objective=}, count, builder,
--          priority?, critical?, expiry?, immediate?, log_fn? }
-- builder(base_name) -> group|truthy on spawn success, nil/false on spawn failure.
-- The board consumes `count` of the matched role from the CHOSEN base BEFORE calling builder;
-- builder only builds the DCS group at that base (no reserve accounting of its own for the primary
-- role). Returns the task record.
function M.create_task(spec)
    S.board_tasks = S.board_tasks or {}
    local id  = next_tid()
    local now = timer.getTime()
    -- Explicit if (not `a and b or c`) so an explicit critical=false is honored over the type default.
    local critical
    if spec.critical ~= nil then critical = spec.critical else critical = M.CRITICAL[spec.type] or false end
    local t = {
        id       = id,
        type     = spec.type,
        side     = spec.side,
        target   = spec.target or {},
        count    = spec.count or 1,
        builder  = spec.builder,
        log_fn   = spec.log_fn or function() end,
        origin   = spec.origin or spec.type,
        priority = spec.priority or M.PRIORITY[spec.type] or 1,
        critical = critical,
        created_t = now,
        expiry_t  = now + (spec.expiry or M.EXPIRY[spec.type] or UNASSIGNED_EXPIRY_DEFAULT),
        state     = "UNASSIGNED",
        assigned_group = nil,
        dedup_key = "board:" .. id,
        -- Supply tasks: the start keysite must not BE the requester (taskgen.c:1676) — try_assign
        -- skips the target base itself as a launch candidate when this is set.
        exclude_target_base = spec.exclude_target_base or false,
    }
    S.board_tasks[#S.board_tasks + 1] = t

    -- Item 2 stats: a queued board task == a task created for its side (eech task-generation count).
    cs.stat_task_created(spec.side)

    -- Synthetic dedup marker so cs.has_task_against() sees this QUEUED task (dropped on assign/fail).
    S.active_tasks = S.active_tasks or {}
    S.active_tasks[t.dedup_key] = { task_type = t.type, target_base = t.target.base, side = t.side }

    cs.dbg("board", "created #%d %s side=%s target=%s prio=%.1f critical=%s expiry=%.0fmin immediate=%s",
        id, t.type, cs.SIDE_NAME[t.side], t.target.base or "field", t.priority, tostring(t.critical),
        (t.expiry_t - now) / 60, tostring(spec.immediate))

    if spec.immediate then M.try_assign(t) end
    return t
end

-- ── try_assign: match one UNASSIGNED task to a base ledger and spawn ────────────
function M.try_assign(t)
    if t.state ~= "UNASSIGNED" then return false end
    local suit = M.SUIT[t.type]
    if not suit then return false end
    local tpos  = t.target.pos
    local bases = owned_bases(t.side, tpos)

    -- Roles in ascending suitability (lowest positive first = assign.c:497 winner order).
    for _, entry in ipairs(suit) do
        local role, s = entry.role, entry.s
        if s > 0 then
            -- Among candidate bases (nearest-first), keep the LOWEST-positive suitability with
            -- best_result=FLT_MAX / result<best (assign.c:433-501). Suitability is uniform, so the
            -- strict `<` makes the FIRST qualifying (nearest, within range, stocked) base win —
            -- faithful to the spec's own note that the current data reduces the quirk to first-match.
            local best_base, best_s = nil, math.huge
            local range = eta_range(role, t)   -- cruise_speed(role) × expire_timer(task), group.c:298,314
            for _, b in ipairs(bases) do
                local within = (not tpos) or (b.d <= range)   -- ETA locality gate (group.c:314; TASK-F14)
                -- start_ks != requester gate (taskgen.c:1676; supply tasks): never launch from the
                -- base being resupplied — the transport would spawn inside its own delivery radius.
                if t.exclude_target_base and b.name == t.target.base then within = false end
                -- Per-base assign budget: a base that has already launched ASSIGN_BUDGET_PER_BASE tasks
                -- this pass is skipped so the task falls through to the next base (assign.c:218,224).
                local under_budget = (_assign_count[b.name] or 0) < ASSIGN_BUDGET_PER_BASE
                -- Basing-capacity gate (Cluster 5): skip a base with no free landing slot, so it
                -- falls through to the NEXT-best base; if no base has a free slot the task stays
                -- UNASSIGNED and is retried until expiry (the starvation/throttle path). Mirrors the
                -- landing-site availability check at assignment (eech assign.c:879, keysite.c:324).
                local has_slot = ks.slot_available(b.name) >= 1
                -- Minimum idle reserve (assign.c:474): keep MIN_IDLE[role] of the role idle at the base
                -- (never spent on offensive board tasks), so require ledger >= t.count + MIN_IDLE[role].
                local need = t.count + (MIN_IDLE[role] or 0)
                if within and under_budget and has_slot and supply.ledger(b.name, role) >= need and s < best_s then
                    best_s   = s
                    best_base = b.name
                end
            end
            if not best_base and not t._dbg_logged then
                -- One-shot funnel diagnostic: why did no base qualify? (range / stock / slot / budget)
                local nb, nr, nstock, nslot, nbudget = #bases, 0, 0, 0, 0
                local need = t.count + (MIN_IDLE[role] or 0)   -- incl. minimum idle reserve (assign.c:474)
                for _, b in ipairs(bases) do
                    if (not tpos) or (b.d <= range) then nr = nr + 1 end
                    if supply.ledger(b.name, role) >= need then nstock = nstock + 1 end
                    if ks.slot_available(b.name) >= 1 then nslot = nslot + 1 end
                    if (_assign_count[b.name] or 0) < ASSIGN_BUDGET_PER_BASE then nbudget = nbudget + 1 end
                end
                t._dbg_logged = true
                cs.dbg("board", "%s %s vs %s UNASSIGNED (role=%s): owned_bases=%d in_range=%d(<=%.0fkm) stocked=%d free_slot=%d w/budget=%d",
                    cs.SIDE_NAME[t.side], t.type, (t.target and t.target.base) or "field",
                    role, nb, nr, range / 1000, nstock, nslot, nbudget)
            end
            if best_base then
                if supply.consume_base(best_base, role, t.count) then
                    -- pcall the builder so a THROW (e.g. coalition.addGroup raising) still refunds the
                    -- ledger — a missed refund silently drains a base forever (dev-loop guardrail).
                    local ok_b, grp = pcall(t.builder, best_base)
                    if ok_b and grp then
                        t.state = "ASSIGNED"
                        t.role  = role
                        t.base  = best_base
                        local ok_n, nm = pcall(function()
                            return (type(grp) == "table" and grp.getName) and grp:getName() or nil
                        end)
                        t.assigned_group = ok_n and nm or nil
                        -- Occupy a landing slot at the launch base (Cluster 5). Reserve keyed by the
                        -- spawned group's name so the slot releases on its RTB-land / death. If the
                        -- name could not be resolved we skip (cannot track release → do not leak a slot).
                        if t.assigned_group then ks.reserve_slot(best_base, t.assigned_group) end
                        _assign_count[best_base] = (_assign_count[best_base] or 0) + 1   -- per-base budget (assign.c:218)
                        S.active_tasks[t.dedup_key] = nil   -- hand off to the spawned group's registration
                        cs.dbg("board", "#%d %s vs %s ASSIGNED base=%s role=%s group=%s (waited %.0fs)",
                            t.id, t.type, (t.target and t.target.base) or "field", best_base, role,
                            tostring(t.assigned_group), timer.getTime() - t.created_t)
                        return true
                    else
                        -- Refund discipline: spawn failed OR threw → credit the ledger back; task stays
                        -- UNASSIGNED and is retried next tick until it expires.
                        supply.recycle_base(best_base, role, t.count)
                        if not ok_b then t.log_fn("task_board builder error: " .. tostring(grp)) end
                        cs.dbg("board", "#%d %s vs %s builder FAILED at base=%s role=%s ok=%s -> refunded, retry",
                            t.id, t.type, (t.target and t.target.base) or "field", best_base, role, tostring(ok_b))
                        return false
                    end
                end
            end
        end
    end
    -- Diagnostic: a CRITICAL task (troop_insertion / OCA) that can't assign is a stalled payoff —
    -- log WHY (in-range / has-slot / has-stock counts), throttled per type, so starvation is visible.
    if M.CRITICAL[t.type] and suit[1] then
        local role = suit[1].role
        local range = eta_range(role, t)   -- group.c:298,314 (TASK-F14)
        local inrange, slotted, stocked = 0, 0, 0
        for _, b in ipairs(bases) do
            if (not tpos) or b.d <= range then
                inrange = inrange + 1
                if ks.slot_available(b.name) >= 1 then
                    slotted = slotted + 1
                    if supply.ledger(b.name, role) >= t.count + (MIN_IDLE[role] or 0) then stocked = stocked + 1 end
                end
            end
        end
        S._board_diag = S._board_diag or {}
        if (timer.getTime() - (S._board_diag[t.type] or 0)) > 30 then
            S._board_diag[t.type] = timer.getTime()
            t.log_fn(string.format(
                "board: %s vs %s UNASSIGNED — %d owned, %d in-range, %d w/slot, %d w/%s-stock",
                t.type, (t.target and t.target.base) or "?", #bases, inrange, slotted, stocked, role))
            cs.dbg("board", "CRITICAL STALL %s vs %s: %d owned, %d in-range, %d w/slot, %d w/%s-stock",
                t.type, (t.target and t.target.base) or "?", #bases, inrange, slotted, stocked, role)
        end
    end
    return false   -- no suitable base with stock in range → remains UNASSIGNED (retry until expiry)
end

-- ── assign_to_player: a human binds an UNASSIGNED task (PILOT-F19) ─────────────
-- EECH reserves player-flyable tasks in the assign pass (reserve_task_count, assign.c:220-255) so a
-- human gunship can take one before the AI; on binding, the task becomes ASSIGNED with the player's
-- gunship as its object (get_local_entity_primary_task, helicop.c:314). This is that binding for the
-- port: the task LEAVES the AI unassigned pool (state → ASSIGNED, compacted out of board_tasks next
-- tick) and is registered under the player's group name so reaction/dedup treat the human sortie
-- exactly like an AI one — the defender's under-attack CAP scrambles against it, completion fires on
-- the player's LAND, and death clears it. Deliberately DIFFERENT from try_assign: NO ledger consume
-- (the human airframe is not reserve hardware) and NO landing-slot reserve (the player occupies a real
-- DCS slot). Returns true on success.
function M.assign_to_player(t, gname, gid)
    if not t or t.state ~= "UNASSIGNED" then return false end
    if not gname then return false end
    t.state          = "ASSIGNED"
    t.assigned_group = gname
    t.role           = "player"
    t.player         = true
    S.active_tasks = S.active_tasks or {}
    S.active_tasks[t.dedup_key] = nil   -- drop the queued-task dedup marker (hand off to the group name)
    cs.register_task(gname, {
        task_type   = t.type,
        side        = t.side,
        target_base = t.target and t.target.base,
        target_pos  = t.target and t.target.pos,
        objective   = (t.target and t.target.objective) or
                      { kind = "keysite", base = t.target and t.target.base },
        born_time   = timer.getTime(),
        player      = true,
    })
    -- F4b: draw the player sortie's F-10 task arrow (AI assignments get theirs in the spawners; the
    -- player path spawns nothing, so draw here). From = the player's current position; if the group
    -- can't be resolved, skip (a zero-length arrow at the target is useless). Lifecycle already reaped:
    -- cs.clear_task fires the map_overlay task_end_hook, and the GC backstop covers a vanished group.
    pcall(function()
        local tpos = t.target and t.target.pos
        if not tpos then return end
        local grp = Group.getByName(gname)
        local u = grp and grp:getUnit(1)
        if u and u:isExist() then
            local p = u:getPosition().p
            require("map_overlay").add_task_arrow(gname, { x = p.x, z = p.z }, tpos, t.side)
        end
    end)
    cs.dbg("board", "#%d %s vs %s ASSIGNED to PLAYER group=%s (left AI pool, no ledger/slot)",
        t.id, t.type, (t.target and t.target.base) or "field", tostring(gname))
    return true
end

-- ── tick: expire, sort by priority, assign; then compact ──────────────────────
function M.tick(log_fn)
    log_fn = log_fn or function() end
    if not S.board_tasks then return end
    local now = timer.getTime()
    _assign_count = {}   -- reset the per-base assign budget for this pass (assign.c:218)

    -- Item 5: recompute the non-USABLE per-base skip set for this pass (ks_updt.c:118-123). A base below
    -- full strength (KEYSITE_STATE_REPAIRING/UNUSABLE — USABLE ⟺ strength==max, keysite.c:1468-1474) has
    -- its assign interval doubled, i.e. it participates as a launch candidate every OTHER pass. Toggle a
    -- per-base flag each tick: while set, owned_bases excludes the base. Fully-usable bases never skip.
    S.base_assign_toggle = S.base_assign_toggle or {}
    _skip_pass = {}
    local n_skip = 0
    for name, owner in pairs(S.base_owner) do
        if owner == coalition.side.BLUE or owner == coalition.side.RED then
            if (S.base_health[name] or 1.0) >= 1.0 then
                S.base_assign_toggle[name] = nil          -- USABLE (full strength): every pass
            else
                local skip = not S.base_assign_toggle[name]   -- non-USABLE: flip skip/serve each tick
                S.base_assign_toggle[name] = skip
                if skip then _skip_pass[name] = true; n_skip = n_skip + 1 end
            end
        end
    end
    if n_skip > 0 then
        cs.dbg("board", "assign-interval ×2: %d non-USABLE base(s) skipped this pass (ks_updt.c:118-123)", n_skip)
    end

    -- 1) Expire UNASSIGNED tasks past their window → FAILED (ts_updt.c:99-124 / TASK-F10.7).
    local live = {}
    for _, t in ipairs(S.board_tasks) do
        if t.state == "UNASSIGNED" then
            if now > t.expiry_t then
                t.state = "FAILED"
                S.active_tasks[t.dedup_key] = nil
                S.board_failed = (S.board_failed or 0) + 1
                log_fn(string.format("task_board: %s vs %s EXPIRED after %.0fmin unassigned → FAILED (no suitable idle group)",
                    t.type, (t.target and t.target.base) or "field", (now - t.created_t) / 60))
                cs.dbg("board", "#%d %s vs %s EXPIRED after %.0fmin -> FAILED (total board_failed=%d)",
                    t.id, t.type, (t.target and t.target.base) or "field", (now - t.created_t) / 60, S.board_failed)
            else
                live[#live + 1] = t
            end
        end
    end

    -- 2) Sort by priority, critical ×2 (assign.c:201-204).
    table.sort(live, function(a, b)
        local pa = a.priority * (a.critical and 2.0 or 1.0)
        local pb = b.priority * (b.critical and 2.0 or 1.0)
        return pa > pb
    end)

    -- 3) Assign in priority order — with PLAYER TASK RESERVATION (assign.c:220-255).
    -- EECH holds back up to reserve_task_count (=2 airbase, ks_dbase.c:119) FRESH, NON-CRITICAL tasks
    -- per keysite per assign pass so a human gunship pilot can take them (assign.c:220,244-253). The
    -- exact EECH predicate for a reservable task, per pass, while the counter is > 0:
    --     !INT_TYPE_CRITICAL_TASK                                    (assign.c:244 — never reserve critical)
    --   &&  FLOAT_TYPE_EXPIRE_TIMER > KEYSITE_TASK_ASSIGN_TIMER      (assign.c:246 — only while "fresh")
    -- When matched it does non_critical_task_count-- and `continue` (skips AI assignment, leaves the task
    -- UNASSIGNED). KEYSITE_TASK_ASSIGN_TIMER = 3 min (keysite.h:69) == our ASSIGN_CADENCE, so "fresh"
    -- means remaining time-to-expiry > one assign cadence. Reservation LAPSES BY AGING: once a reserved
    -- task's remaining window falls to <= ASSIGN_CADENCE it is no longer reservable and falls through to
    -- AI assignment on a later pass — it ages into AI use BEFORE expiry (EECH never holds it to expiry).
    --
    -- Port adaptations (cited divergences):
    --   * The board runs ONE global pass (no per-keysite passes, spec 07-F9), so the reserve budget is a
    --     single global counter per pass — the faithful proxy for EECH's per-keysite reserve_task_count.
    --   * Reservable set is narrowed to PLAYER-FLYABLE types (pilots.PLAYER_FLYABLE, single source of
    --     truth) — only those can ever be flown by a human here; EECH reserves any non-critical task for
    --     player gunships, but the port's fixed-wing striker/SEAD/recon tasks are AI-only (PILOT-F17).
    --   * SCALE proxy (adversarial-review Finding 1b): EECH reserves 2 PER KEYSITE across many keysites,
    --     so its reservation is a small fraction of the task flow; the port's single global pass makes a
    --     flat global-2 hold ~half of each rotary CAS/BAI cycle hostage for ~the full window. Reserving
    --     only while a human pilot is actually CONNECTED keeps the intent (missions left for humans,
    --     assign.c:244-255) without the scale distortion on an empty server. Reserved tasks are only
    --     DELAYED (they age into AI assignment), never dropped.
    -- Critical-path safety: immediate=true reaction tasks call try_assign directly from create_task and
    -- never enter this loop, so the reaction chain is never throttled by reservation (EECH likewise
    -- reserves only in the periodic assign pass, not on the immediate assign path).
    local humans_present = false
    for _, ps in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local okp, plist = pcall(coalition.getPlayers, ps)
        local players = (okp and plist) or {}   -- provable table for the analyzer (no and/or narrowing)
        if #players > 0 then humans_present = true; break end
    end
    local reserve_left = humans_present and RESERVE_TASK_COUNT or 0
    local flyable = player_flyable_set()
    for _, t in ipairs(live) do
        local reservable = reserve_left > 0 and flyable and flyable[t.type]
            and not t.critical                             -- assign.c:244
            and (t.expiry_t - now) > ASSIGN_CADENCE        -- assign.c:246 ("fresh")
        if reservable then
            reserve_left = reserve_left - 1
            cs.dbg("board", "reserved #%d %s vs %s for players (%d/%d reserve left, %.0fs to expiry)",
                t.id, t.type, (t.target and t.target.base) or "field",
                reserve_left, RESERVE_TASK_COUNT, t.expiry_t - now)
        else
            local ok, err = pcall(M.try_assign, t)
            if not ok then log_fn("task_board assign error: " .. tostring(err)) end
        end
    end

    -- 4) Compact: keep only still-UNASSIGNED records (ASSIGNED handed to the group lifecycle;
    --    FAILED are terminal). Bounds S.board_tasks growth.
    local kept = {}
    for _, t in ipairs(S.board_tasks) do
        if t.state == "UNASSIGNED" then kept[#kept + 1] = t end
    end
    S.board_tasks = kept
end

-- NOTE: M.has_live_task_of_type_against was DELETED in Cluster H (zero callers) — it was a spec-facing
-- alias of cs.has_task_against, which every dedup site calls directly. The board's synthetic markers
-- put UNASSIGNED tasks INTO active_tasks, so cs.has_task_against already covers both queued + flying.

-- ── Scheduler registration (called once from game_loop.start) ─────────────────
function M.schedule(log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    cs.dbg("board", "scheduler REGISTERED cadence=%.0fs offset=%.0fs", ASSIGN_CADENCE, ASSIGN_CADENCE)
    timer.scheduleFunction(function(_, t)
        -- POST-VICTORY (Item 6 LITERAL semantics): the whole task pipeline keeps running after the win —
        -- generators keep QUEUEING and this pass keeps ASSIGNING, exactly as EECH (fc_msgs.c:163 gates
        -- only the win-check re-award; nothing else is session-gated). The former Cluster-E generator
        -- game_over gates were removed in WAVE 5 Item 6.
        if _DMT_GEN ~= my_gen then return nil end
        local n_unassigned = S.board_tasks and #S.board_tasks or 0
        cs.dbg("board", "tick FIRE: %d unassigned queued before pass", n_unassigned)
        local ok, err = pcall(M.tick, log_fn)
        if not ok then log_fn("task_board tick error: " .. tostring(err)) end
        return t + ASSIGN_CADENCE
    end, nil, timer.getTime() + ASSIGN_CADENCE)
end

return M
