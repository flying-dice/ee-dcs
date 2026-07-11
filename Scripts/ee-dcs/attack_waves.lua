-- attack_waves.lua
-- Inspired by:
--   aphavoc/source/ai/highlevl/highlevl.c   create_oca_strike_tasks (every 30 min campaign),
--                                            create_keysite_strike_tasks (every 7.5 min),
--                                            create_bai_tasks (every 20 min),
--                                            add_high_level_ai_function + staggered offset
--   aphavoc/source/ai/highlevl/reaction.c   escort created reactively when task difficulty
--                                            >= escort_required_threshold
--   aphavoc/source/ai/taskgen/taskgen.h     create_escort_task factory function
--   aphavoc/source/ai/highlevl/suitable.c   suitability matrix: ARMED_FW for strike,
--                                            FIGHTER for escort (category-based selection)
--
-- Generates periodic fixed-wing strike packages against enemy airbases and installations.
-- Each package is a fixed-size strike flight (STRIKE_PACKAGE_SIZE = 2); the escort count is
-- threat-thresholded per the reaction.c escort_required gate (assign.c:598-627), NOT scaled by
-- campaign phase (the old phase-scaling wave table was removed). Strike cadence is mode-selected
-- (campaign vs skirmish) via campaign_mode.lua.

local cs       = require("campaign_state")
local keysite  = require("keysite")
local croute   = require("croute")
local supply   = require("supply")
local ov       = require("map_overlay")
local config   = require("config")
local board    = require("task_board")
local recon    = require("recon")
local fow      = require("fog_of_war")
local S        = cs.S
local M        = {}

-- FOW gate for the OCA-strike generator (highlevl.c:1433: fow(sector) >= 0.25 * FOW maximum). OCA has
-- NO recon fallback (unlike the keysite-strike fork) — a fogged #1 target yields no OCA this cycle.
local FOW_OCA_THRESHOLD = 0.25   -- highlevl.c:1433

-- Side → pylon table for striker and escort (config.payloads[side].{striker,escort}; payloads.lua).
local PYLON = config.C.payloads

-- ── Aircraft configuration ─────────────────────────────────────────────────────
-- Hoisted to config.lua (types.aircraft + countries; validated at boot). Unit type names verified
-- against live DCS install (Unit.getDescByName, category=0).
local AC = {}
for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
    AC[side] = {
        country = config.C.countries[side],
        striker = config.C.types.aircraft[side].striker,   -- ARMED_FW / ground attack
        escort  = config.C.types.aircraft[side].escort,    -- FIGHTER / air superiority
    }
end

-- ── Strike package size ────────────────────────────────────────────────────────
-- EECH's create_keysite_strike_tasks assigns the best resident group; a strike group's size is its
-- member_count, not a per-cadence "wave" figure — there is no EECH per-task striker count. The old
-- WAVE phase table (2/2/4 strikers + 0/1/2 escorts by invented phase) is removed: a single documented
-- flight size, and escorts are now THREAT-thresholded per EECH's escort_required model (cs.escort_count,
-- assign.c:598-627), computed on the actual launch→target leg — NOT by elapsed-time phase.
local STRIKE_PACKAGE_SIZE = 2   -- a standard 2-ship strike flight (documented port constant)

-- Flight constants — route cruise altitude/speed (units ground-spawn at the launch base and depart via a real TakeOff waypoint)
local STRIKE_ALT   = 6000   -- m AMSL cruise altitude
local ESCORT_ALT   = 7000   -- m, above strikers
local STRIKE_SPEED = 220    -- m/s ≈ 428 kt

-- Installation strike attrition (Cluster G): deterministic damage per sortie applied at time-on-
-- target (static objects can't be EngageTargets'd, so this is the guaranteed destruction path).
local INSTALLATION_STRIKE_DMG      = 0.5    -- ~2 sorties destroy an installation (health 1.0 → ≤0.1);
                                            -- with the concentration bias the economy war bites fast
local INSTALLATION_TIME_ON_TARGET  = 150    -- s after launch (fly out + attack run) — quicker credit

-- Airbase keysite-strike attrition (mirrors EECH create_keysite_strike_tasks reducing keysite
-- strength). A keysite has far more "buildings" than an installation, so a package neutralises it
-- over several strikes rather than ~3. KStrike (dedicated ground strike ON the keysite) hits harder
-- than an OCA strike (counter-air, primarily suppressing the airfield's air ops).
local KEYSITE_STRIKE_DMG           = 0.28   -- KStrike: 1.0 → capturable (<0.3) in ~3 focused strikes
local OCA_STRIKE_DMG               = 0.16   -- OCA strike: lighter structural damage
local KEYSITE_TIME_ON_TARGET       = 240    -- s after launch (fly out + attack run)

-- ── Strike package spawn ───────────────────────────────────────────────────────
-- Mirrors EECH's create_keysite_strike_tasks task-assignment model:
-- find the nearest friendly keysite (airbase) to the target, spawn aircraft
-- there using a real TakeOff waypoint — aircraft depart from their actual base
-- just as EECH tasks existing aircraft at the nearest keysite.

-- intent: "oca" (create_oca_strike_tasks — counter-air against airfield) or
--         "ground" (create_keysite_strike_tasks — ground strike against installations).
-- Both bomb the target keysite; they differ in cadence (7.5 min vs 30 min) and group-name
-- prefix. When non-airbase keysites exist, targeting will diverge on oca_target vs
-- ground_strike_target flags (see keysite flags); with airbase-only keysites the set is shared.
-- ── build_strike_package(side, base_name, tname, log_fn, intent) ──────────────
-- BUILDER (task-board contract): spawns the strike package FROM base_name. The board has already
-- consumed STRIKE_PACKAGE_SIZE "striker" from base_name's ledger (refunds on nil). The escort
-- sub-package is a SECONDARY consumption drawn directly from the SAME base's escort ledger, sized by
-- the threat threshold (escort created at assignment, assign.c:598-627), with its own refund.
-- Returns the strike group on success, nil on fail.
local function build_strike_package(side, base_name, tname, log_fn, intent)
    log_fn = log_fn or function() end
    intent = intent or "ground"

    local cfg      = AC[side]
    local strikers = STRIKE_PACKAGE_SIZE
    -- Target may be an airbase keysite OR a non-airbase installation (depot/radar/etc, Cluster G).
    local is_installation = (S.base_pos[tname] == nil)
    local tpos = S.base_pos[tname]
              or (S.keysites and S.keysites[tname] and S.keysites[tname].pos)
    if not tpos then
        log_fn("strike: no position for " .. tname)
        cs.dbg("strike", "%s build_strike_package ABORT: no position for target %s", cs.SIDE_NAME[side], tostring(tname))
        return nil
    end

    local home_ab = Airbase.getByName(base_name)
    if not home_ab then
        cs.dbg("strike", "%s build_strike_package ABORT: base %s not found", cs.SIDE_NAME[side], tostring(base_name))
        return nil
    end

    local ab_pos = home_ab:getPosition().p
    local bx, by = cs.wp_xy(ab_pos)
    local tx, ty = cs.wp_xy(tpos)
    local hdg    = cs.heading_to(ab_pos.x, ab_pos.z, tpos.x, tpos.z)
    local sid    = cs.next_id()
    local prefix = (intent == "oca") and "OCAStrike" or "KStrike"
    local sname  = string.format("%s-%d", prefix, sid)

    -- Escort by threat (assign.c:598-627): count = 0/1/2 from route difficulty vs the strike escort
    -- threshold (ground_strike / oca_strike = 3, CRITICAL 2-ship at difficulty >= 6). Replaces the
    -- WAVE phase-table escort count. Computed on the real launch(ab_pos)→target(tpos) leg.
    local escorts = cs.escort_count((intent == "oca") and "oca_strike" or "ground_strike",
                                    side, ab_pos, tpos, log_fn)

    -- Units start on the ground at the airbase
    local s_units = {}
    for i = 1, strikers do
        s_units[i] = {
            name     = sname .. "-" .. i,
            type     = cfg.striker,
            skill    = "Good",
            x        = ab_pos.x + (i-1) * 20,
            y        = ab_pos.z,
            alt      = ab_pos.y,
            alt_type = "BARO",
            speed    = 0,
            heading  = hdg,
            payload  = { fuel = 4900, flare = 60, chaff = 60, gun = 100, pylons = PYLON[side].striker },
        }
    end

    local strike_grp = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
        name        = sname,
        task        = "Ground Attack",
        hidden      = false,
        airdromeId  = home_ab:getID(),
        units       = s_units,
        -- Biased route (croute.c): valley-following / enemy-avoiding nav points spliced into each leg.
        route = {
            points = croute.expand({
                {   -- TakeOff from the nearest friendly airbase
                    type="TakeOff", action="From Parking Area",
                    airdromeId = home_ab:getID(),
                    alt=ab_pos.y, alt_type="BARO", speed=0,
                    ETA=0, ETA_locked=true,
                    x=bx, y=by,
                    name="Depart", formation_template="",
                },
                {   -- Attack run over the target
                    type="Turning Point", action="Turning Point",
                    alt=STRIKE_ALT, alt_type="BARO", speed=STRIKE_SPEED,
                    ETA=0, ETA_locked=false, x=tx, y=ty,
                    name="Strike", formation_template="",
                    task = {
                        id = "ComboTask",
                        params = { tasks = { [1] = {
                            number=1, auto=true, id="EngageTargets", enabled=true,
                            params = { maxDist=10000, priority=0,
                                       targetTypes = { "Ground Units", "Helicopters" } },
                        }}},
                    },
                },
                {   -- RTB
                    type="Land", action="Landing",
                    airdromeId = home_ab:getID(),
                    alt=ab_pos.y, alt_type="BARO", speed=STRIKE_SPEED,
                    ETA=0, ETA_locked=false,
                    x=bx, y=by,
                    name="RTB", formation_template="",
                },
            }, side, { alt=STRIKE_ALT, alt_type="BARO", speed=STRIKE_SPEED, name="Nav" }),
        },
    })

    if strike_grp then
        -- Register the mission for BOTH airbase and installation keysites: EECH's
        -- entity_is_object_of_task dedup spans the task's whole life (highlevl.c:1227-1231) and the
        -- DEAD/LAND handlers clear the record. For installations the BIRTH-side CAP reaction
        -- naturally no-ops (S.base_pos[tname]=nil → no obj_pos; matches factory requires_cap=FALSE,
        -- ks_dbase.c:214) and LAND fires react_strike_complete (BDA/follow-on, reaction.c:609).
        cs.register_task(sname, {
            task_type   = (intent == "oca") and "oca_strike" or "ground_strike",
            side        = side,
            target_base = tname,
            target_pos  = tpos,
            objective   = { kind = "keysite", base = tname },
            born_time   = timer.getTime(),
            -- Item 3: capture target efficiency BEFORE the strike lands (assess_task ground-strike rating
            -- = eff_before - eff_after, eech task.c:384). Airbase → base_health; installation → keysites.
            eff_before  = S.base_health[tname]
                or (S.keysites and S.keysites[tname] and S.keysites[tname].health) or 1.0,
        })
        if not is_installation then
            -- Degrade the target keysite's building strength at time-on-target (mirrors EECH
            -- keysite_strength reduction). Deterministic — an empty airfield yields no unit-kills,
            -- so this is the guaranteed keysite-attrition source that lets bases fall and be captured.
            local dmg = (intent == "oca") and OCA_STRIKE_DMG or KEYSITE_STRIKE_DMG
            local my_gen = _DMT_GEN
            timer.scheduleFunction(function()
                if _DMT_GEN == my_gen then keysite.strike_damage(tname, dmg, log_fn) end
                return nil
            end, nil, timer.getTime() + KEYSITE_TIME_ON_TARGET)
        else
            -- DCS AI does not engage static objects via EngageTargets and no unit-kills occur in the
            -- installation's rear, so credit deterministic damage after the package's time-on-target.
            -- ~2 sorties destroy an installation; this is the guaranteed attrition source of truth.
            local my_gen = _DMT_GEN
            timer.scheduleFunction(function()
                if _DMT_GEN == my_gen then
                    require("installations").damage(tname, INSTALLATION_STRIKE_DMG, log_fn)
                end
                return nil
            end, nil, timer.getTime() + INSTALLATION_TIME_ON_TARGET)
        end
        log_fn(string.format("Strike %d: %s %dx%s from %s → %s (escorts=%d)",
            sid, cs.SIDE_NAME[side], strikers, cfg.striker,
            home_ab:getName(), tname, escorts))
        ov.add_task_arrow(sname, ab_pos, tpos, side)   -- Item 4: key by group name (clear_task reaps it)
        cs.dbg("strike", "%s Strike #%d (%s) spawned from %s -> %s (installation=%s, dmg scheduled +%.0fs)",
            cs.SIDE_NAME[side], sid, intent, home_ab:getName(), tname, tostring(is_installation),
            is_installation and INSTALLATION_TIME_ON_TARGET or KEYSITE_TIME_ON_TARGET)
    else
        -- Strike group creation failed → return nil; the board refunds the striker ledger.
        log_fn(string.format("Strike %d FAILED: %s → %s", sid, cs.SIDE_NAME[side], tname))
        cs.dbg("strike", "%s Strike #%d (%s) SPAWN FAILED -> %s", cs.SIDE_NAME[side], sid, intent, tname)
        return nil
    end

    -- Escort (assign.c:598-627 threshold gate): secondary consumption from the SAME launch base's
    -- escort ledger. Refunded to that base on spawn failure. Count from cs.escort_count above.
    if escorts > 0 and supply.consume_base(base_name, "escort", escorts) then
        local eid   = cs.next_id()
        local ename = string.format("Escort-%d", eid)

        local e_units = {}
        for i = 1, escorts do
            e_units[i] = {
                name     = ename .. "-" .. i,
                type     = cfg.escort,
                skill    = "High",
                x        = ab_pos.x + (i-1) * 20,
                y        = ab_pos.z,
                alt      = ab_pos.y,
                alt_type = "BARO",
                speed    = 0,
                heading  = hdg,
                payload  = { fuel = 5200, flare = 120, chaff = 120, gun = 100, pylons = PYLON[side].escort },
            }
        end

        -- pcall the escort addGroup: a THROW here must NOT propagate out of the builder (the strike
        -- group already spawned+registered — a propagating throw would make the board double-credit
        -- strikers and leak the escort). Contained throw/nil → refund the escort ledger only (MED-2).
        local ok_e, escort_grp = pcall(coalition.addGroup, cfg.country, Group.Category.AIRPLANE, {
            name       = ename,
            task       = "Fighter Sweep",
            hidden     = false,
            airdromeId = home_ab:getID(),
            units      = e_units,
            route = {
                points = croute.expand({
                    {
                        type="TakeOff", action="From Parking Area",
                        airdromeId = home_ab:getID(),
                        alt=ab_pos.y, alt_type="BARO", speed=0,
                        ETA=0, ETA_locked=true,
                        x=bx, y=by,
                        name="Depart", formation_template="",
                    },
                    {
                        type="Turning Point", action="Turning Point",
                        alt=ESCORT_ALT, alt_type="BARO", speed=STRIKE_SPEED,
                        ETA=0, ETA_locked=false, x=tx, y=ty,
                        name="Sweep", formation_template="",
                        task = {
                            id = "ComboTask",
                            params = { tasks = { [1] = {
                                number=1, auto=true, id="EngageTargets", enabled=true,
                                params = { maxDist=40000, priority=0,
                                           targetTypes = { "Air" } },
                            }}},
                        },
                    },
                    {
                        type="Land", action="Landing",
                        airdromeId = home_ab:getID(),
                        alt=ab_pos.y, alt_type="BARO", speed=STRIKE_SPEED,
                        ETA=0, ETA_locked=false,
                        x=bx, y=by,
                        name="RTB", formation_template="",
                    },
                }, side, { alt=ESCORT_ALT, alt_type="BARO", speed=STRIKE_SPEED, name="Nav" }),
            },
        })

        if ok_e and escort_grp then
            log_fn(string.format("Escort %d: %s %dx%s from %s for Strike-%d",
                eid, cs.SIDE_NAME[side], escorts, cfg.escort,
                home_ab:getName(), sid))
            cs.dbg("strike", "%s Escort #%d spawned for Strike-%d", cs.SIDE_NAME[side], eid, sid)
        else
            supply.recycle_base(base_name, "escort", escorts)  -- refund: escort spawn failed/threw
            cs.dbg("strike", "%s Escort for Strike-%d FAILED (pcall_ok=%s) -> refunded", cs.SIDE_NAME[side], sid, tostring(ok_e))
        end
    end
    return strike_grp
end

-- ── create_strike_task: enqueue a strike package task on the board ────────────
-- The board picks the launch base from the "striker" ledger (nearest, in range, package-sized stock)
-- and calls build_strike_package. count = STRIKE_PACKAGE_SIZE (so the ledger consume matches the units
-- build). Escort is a secondary threat-thresholded consume inside build_strike_package.
-- immediate=true for the reaction single-shots so follow-on strikes assign without waiting a tick.
-- `critical` (optional, WAVE 3 Item 4): when the reaction chain creates this task it passes true so the
-- board sorts it at ×2 priority (assign.c:201-204) — EECH's reaction create_*_task calls all pass the
-- critical argument = TRUE (reaction.c:459 OCA / :486 & :663 ground strike). Generator callers omit it
-- (nil) → M.create_task falls back to the per-type M.CRITICAL default, so their behaviour is unchanged.
local function create_strike_task(side, tname, log_fn, intent, immediate, critical)
    log_fn = log_fn or function() end
    intent = intent or "ground"
    local tpos = S.base_pos[tname]
              or (S.keysites and S.keysites[tname] and S.keysites[tname].pos)
    if not tpos then
        log_fn("strike: no position for " .. tname)
        cs.dbg("strike", "%s create_strike_task ABORT: no position for %s", cs.SIDE_NAME[side], tostring(tname))
        return false
    end
    local ttype = (intent == "oca") and "oca_strike" or "ground_strike"
    cs.dbg("strike", "%s create_strike_task: %s vs %s (strikers=%d, immediate=%s)",
        cs.SIDE_NAME[side], ttype, tname, STRIKE_PACKAGE_SIZE, tostring(immediate))
    board.create_task({
        type = ttype, side = side, count = STRIKE_PACKAGE_SIZE, log_fn = log_fn, immediate = immediate,
        critical = critical,   -- nil for generators (uses M.CRITICAL default); true from the reaction chain
        -- target.base is ALWAYS the keysite name (airbase OR installation): the board's synthetic
        -- dedup marker keys on it, and EECH's entity_is_object_of_task dedup covers every keysite
        -- type (highlevl.c:1227-1231) — keying only real airbases left installation strikes
        -- invisible to has_task_against, re-tasking the same installation every cycle.
        target = { base = tname, pos = tpos },
        builder = function(base_name)
            return build_strike_package(side, base_name, tname, log_fn, intent)
        end,
    })
    return true
end

-- ── Scheduler registration ─────────────────────────────────────────────────────
-- EECH registers TWO distinct strike task creators (highlevl.c campaign branch):
--   create_keysite_strike_tasks : 7.5 min / 15 s  — frequent ground strike vs installations
--   create_oca_strike_tasks     : 30  min / 6.5 min — infrequent counter-air vs airfields
-- These are separate tasks with separate cadence; the port must run both (a prior "fix"
-- collapsed them into one at the OCA cadence, deleting the high-tempo strike — restored here).
-- Item 5: mode-selected via campaign_mode.lua (campaign byte-identical to the prior literals).
local mode                  = require("campaign_mode")
local KEYSITE_STRIKE_PERIOD = mode.SCHED.keysite_strike.period  -- highlevl.c:252 campaign / :228 skirmish
local OCA_STRIKE_PERIOD     = mode.SCHED.oca_strike.period      -- highlevl.c:268 campaign / :242 skirmish

-- create_keysite_strike_tasks (ground) scans the WHOLE ground_strike_target keysite set — airbases
-- AND non-airbase installations — with ONE rating formula (keysite.pick_targets → keysite.
-- strike_candidates), then applies the ratio gate + recon-first fork + eff/dedup gates. This replaces
-- the old two-stream airbase/installation interleave and the invented installation STRIKE_VALUE table.
-- create_oca_strike_tasks scores oca_target keysites only (airfields) with the OCA weights + FOW gate.

local function run_scheduled_strike(side, intent, log_fn)
    -- EECH generates strike tasks regardless of force strength (no survival mode; see
    -- campaign_state.lua posture note + highlevl.c create_keysite_strike_tasks/create_oca_strike_tasks
    -- which never inspect force_percentage). The former STRENGTH_SURVIVAL skip here was invented
    -- (Cluster E).
    if intent == "ground" then
        -- CREATE_KEYSITE_STRIKE_TASK_COUNT = 3 (highlevl.c:94). keysite.pick_targets returns the funnel
        -- decisions (strike vs recon) after the ratio/fork/eff/dedup gates; we just execute them.
        local COUNT = 3
        local decisions = keysite.pick_targets(side, COUNT, log_fn)
        if #decisions == 0 then
            log_fn(cs.SIDE_NAME[side] .. ": no valid ground strike target")
            return
        end
        for _, d in ipairs(decisions) do
            if d.action == "recon" then
                -- Recon-first fork (highlevl.c:1179-1205): reconnoitre the keysite; the GROUND STRIKE
                -- is created on recon completion by the reaction chain (react_recon_complete_keysite).
                -- objective.base is the airbase keysite so the reaction re-strikes the right target.
                recon.spawn_recon(side, d.pos, "KStrikeRecon", log_fn, { kind = "keysite", base = d.name })
            else
                create_strike_task(side, d.name, log_fn, "ground")
            end
        end
    else
        -- create_oca_strike_tasks (highlevl.c:1286-1467): best oca_target airbase by the OCA weights,
        -- then FOW>=0.25 gate + dedup vs oca_strike/bda/troop_insertion. Count = 1 (ratio gate moot).
        local tname = keysite.pick_target(side, log_fn, keysite.RATE_OCA_STRIKE)
        if not tname then
            log_fn(cs.SIDE_NAME[side] .. ": no valid oca strike target")
            cs.dbg("strike", "%s OCA strike: no valid target", cs.SIDE_NAME[side])
            return
        end
        local fow_val = fow.get(tname, side) or 0.0            -- airbase name is a FOW sector key
        if fow_val < FOW_OCA_THRESHOLD then
            cs.dbg("strike", "%s OCA strike SKIPPED: %s fogged (fow=%.2f < %.2f)",
                cs.SIDE_NAME[side], tname, fow_val, FOW_OCA_THRESHOLD)   -- highlevl.c:1433
        elseif cs.has_task_against("oca_strike", tname, side)
            or cs.has_task_against("bda", tname, side)
            or cs.has_task_against("troop_insertion", tname, side) then
            cs.dbg("strike", "%s OCA strike SKIPPED: %s already tasked (dedup)",
                cs.SIDE_NAME[side], tname)                               -- highlevl.c:1435-1440
        else
            create_strike_task(side, tname, log_fn, "oca")
        end
    end
end

-- create_keysite_strike_tasks — ground strike, 7.5 min campaign period.
function M.schedule_keysite_strikes(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    cs.dbg("strike", "%s keysite-strike scheduler REGISTERED offset=%.0fs period=%.0fs",
        cs.SIDE_NAME[side], initial_offset, KEYSITE_STRIKE_PERIOD)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end   -- re-injection guard: cancel superseded closure
        -- Item 6 (LITERAL post-victory semantics): generators keep running after the win is declared —
        -- EECH fc_msgs.c:163 gates ONLY the win-check re-award (INT_TYPE_SESSION_COMPLETE), never the
        -- highlevl.c task generators. The prior Cluster-E generator suppression is removed (was a proxy).
        cs.dbg("strike", "%s keysite-strike FIRE", cs.SIDE_NAME[side])
        run_scheduled_strike(side, "ground", log_fn)
        return t + KEYSITE_STRIKE_PERIOD
    end, nil, timer.getTime() + initial_offset)
end

-- create_oca_strike_tasks — offensive counter-air, 30 min campaign period.
function M.schedule_oca_strikes(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    cs.dbg("strike", "%s oca-strike scheduler REGISTERED offset=%.0fs period=%.0fs",
        cs.SIDE_NAME[side], initial_offset, OCA_STRIKE_PERIOD)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end   -- re-injection guard: cancel superseded closure
        -- Item 6: generators keep running post-victory (EECH fc_msgs.c:163 gates only the win re-award).
        cs.dbg("strike", "%s oca-strike FIRE", cs.SIDE_NAME[side])
        run_scheduled_strike(side, "oca", log_fn)
        return t + OCA_STRIKE_PERIOD
    end, nil, timer.getTime() + initial_offset)
end

-- ── Single-shot spawns (called by reaction.lua for follow-on strike tasks) ────
-- EECH creates DISTINCT follow-on tasks: create_ground_strike_task (reaction.c:663) and
-- create_oca_strike_task (reaction.c:490). Kept as separate entry points so reaction.lua
-- can stop calling one generic run_strike for both (react-M5 fix, Cluster C).
local function run_single(side, intent, tname_override, log_fn, critical)
    log_fn = log_fn or function() end
    -- No survival gate: EECH's reaction-chain follow-on strikes (reaction.c) never check force strength.
    -- reaction always passes an override; the pick path (weights per intent) is a defensive fallback.
    local weights = (intent == "oca") and keysite.RATE_OCA_STRIKE or keysite.RATE_GROUND_STRIKE
    local tname = tname_override or keysite.pick_target(side, log_fn, weights)
    if tname then
        cs.dbg("strike", "%s run_single(%s): single-shot vs %s (override=%s)",
            cs.SIDE_NAME[side], intent, tname, tostring(tname_override ~= nil))
        -- immediate=true: reaction follow-ons assign this tick (create_ground/oca_strike_task). critical
        -- threaded from the reaction caller (reaction.c create_*_strike_task pass TRUE).
        local ok, err = pcall(create_strike_task, side, tname, log_fn, intent, true, critical)
        if not ok then log_fn("run_" .. intent .. "_strike error: " .. tostring(err)) end
    else
        cs.dbg("strike", "%s run_single(%s) ABORT: no target resolved", cs.SIDE_NAME[side], intent)
    end
end

-- create_ground_strike_task — ground strike against installations. `critical` (optional, WAVE 3 Item 4)
-- is passed true by reaction.lua (reaction.c:486/:663 create_ground_strike_task critical=TRUE); the
-- scheduled generator does not call this export, so the added trailing arg never affects a generator path.
function M.run_strike(side, log_fn, tname, critical)
    run_single(side, "ground", tname, log_fn, critical)
end

-- create_oca_strike_task — offensive counter-air against an airfield. `critical` (optional) is passed
-- true by reaction.lua (reaction.c:459 create_oca_strike_task critical=TRUE); oca_strike is already in
-- M.CRITICAL so the explicit true is behaviour-preserving, threaded for consistency with the chain.
function M.run_oca_strike(side, log_fn, tname, critical)
    run_single(side, "oca", tname, log_fn, critical)
end

return M
