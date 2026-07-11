-- cas_bai_sead.lua
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c
--
-- create_cas_tasks() line 815
--   Period: 6 min (skirmish) / 15 min (campaign); offset 0.0
--   Targets: LIST_TYPE_GROUND_REGISTRY groups where INT_TYPE_FRONTLINE==1 (highlevl.c:877)
--            → PRIMARY frontline group TYPE (armour), not a sector-distance value.
--   Score: (1-airdef)*1 + base_dist*3 + sector_ratio*2; max=6.0
--   Limits: CREATE_CAS_TASK_COUNT=2, MAX_SECTOR_CAS_TASK_COUNT=1
--   FOW: NO FOW check (CAS proceeds regardless of fog)
--
-- create_bai_tasks() line 575
--   Period: 10 min (skirmish) / 20 min (campaign); offset 90 s / 5 min
--   Targets: LIST_TYPE_GROUND_REGISTRY groups where INT_TYPE_FRONTLINE>1 (highlevl.c:637)
--            → SECONDARY(2)/support + ARTILLERY(3) group TYPES (second-line).
--   Score: (1-airdef)*2 + base_dist*3 + sector_ratio*2; max=7.0
--   Limits: CREATE_BAI_TASK_COUNT=2, MAX_SECTOR_BAI_TASK_COUNT=1
--   FOW: fow > 0.5 * maximum (CONFIRMED at line 757 — HIGHER threshold than other tasks)
--
-- ECHELON SPLIT (Cluster B): INT_TYPE_FRONTLINE is group_database[sub_type].frontline_flag
-- (gp_int.c:389-392) — a STATIC per-group-TYPE flag (NONE=0/PRIMARY=1/SECONDARY=2/ARTILLERY=3,
-- group.h:199-202), NOT a distance. The port's ground groups are undifferentiated, so the
-- echelon is proxied POSITIONALLY via frontline.echelon_of(pos): a target whose nearest owned
-- base is a Gabriel-frontline base → "frontline" (CAS), else → "second" (BAI/SEAD). See
-- frontline.lua:echelon_of. This is the first real consumer of the Gabriel frontline flags and
-- replaces the old invented `is_near_friendly` 200 km band (frontl.FRONTLINE_RADIUS, traced to
-- nothing in EECH) that starved BAI on any scoped theatre.
--
-- create_sead_tasks() line 1918
--   Period: 10 min (skirmish) / 12 min (campaign); offset 2 s / 3 min
--   Targets: enemy groups with air_attack_strength==10 AND !frontline_flag (highlevl.c:1981)
--            → rear/site AA (NONE echelon), not frontline-attached AA. Proxied via
--              frontline.echelon_of(pos)=="second".
--   Score: base_dist*4 + sector_ratio*3; max=7.0
--   Limits: CREATE_SEAD_TASK_COUNT=2, MAX_SECTOR_SEAD_TASK_COUNT=1
--   FOW: fow >= 0.25 * maximum
--
-- create_oca_sweep_tasks() line 1473
--   Period: 20 min (skirmish) / 30 min (campaign); offset 4 min / 1.5 min
--   Targets: enemy keysites where keysite_database[type].oca_target == true
--   Score: (1-airdef)*1 + base_dist*4 + sector_ratio*2; max=7.0
--   Limits: CREATE_OCA_SWEEP_TASK_COUNT=2, MIN_TASK_CREATION_RATIO=0.75
--   FOW: fow >= 0.25 * maximum
--
-- create_artillery_strike_tasks() line 2836
--   Period: 12 min (skirmish) / 15 min (campaign); offset 8 s / 45 s
--   Groups: own artillery groups (GROUP_FRONTLINE_FLAG_ARTILLERY)
--   Targets: enemy frontline groups + ground_strike keysites within max_weapon_range
--   FOW: fow > 0.25 * maximum (per target sector)
--   Limit: MAX_ARTILLERY_STRIKE_COUNT=5
--
-- highlevl.c line 84-100 constants:
--   MAX_HIGHLEVEL_TARGET_CHECKS = 160
--   MIN_TASK_CREATION_RATIO     = 0.75
--   CREATE_CAS_TASK_COUNT       = 2
--   MAX_SECTOR_CAS_TASK_COUNT   = 1
--   CREATE_BAI_TASK_COUNT       = 2
--   MAX_SECTOR_BAI_TASK_COUNT   = 1
--   CREATE_OCA_SWEEP_TASK_COUNT = 2
--   CREATE_SEAD_TASK_COUNT      = 2
--   MAX_SECTOR_SEAD_TASK_COUNT  = 1
--   MAX_ARTILLERY_STRIKE_COUNT  = 5 (line 2836)

local cs       = require("campaign_state")
local croute   = require("croute")
local imap_m   = require("imap")
local fow_m    = require("fog_of_war")
local frontl   = require("frontline")
local ov       = require("map_overlay")
local recon    = require("recon")
local config   = require("config")
local board    = require("task_board")
local supply   = require("supply")   -- SEAD-escort secondary consume/refund (spawn_sead_escort);
                                     -- was referenced as an undeclared global → every SEAD builder
                                     -- threw at :273 (live-caught; the analyzer does not flag
                                     -- unknown globals — checker blind spot)
local S        = cs.S
local M        = {}

-- ── EECH constants (exact mirror, highlevl.c line 84–100, 2836) ────────────────
local MAX_HIGHLEVEL_TARGET_CHECKS = 160
local MIN_TASK_CREATION_RATIO     = 0.75
local CREATE_CAS_TASK_COUNT       = 2
local MAX_SECTOR_CAS_TASK_COUNT   = 1
local CREATE_BAI_TASK_COUNT       = 2
local MAX_SECTOR_BAI_TASK_COUNT   = 1
local CREATE_OCA_SWEEP_TASK_COUNT = 2
local CREATE_SEAD_TASK_COUNT      = 2
local MAX_SECTOR_SEAD_TASK_COUNT  = 1
local MAX_ARTILLERY_STRIKE_COUNT  = 5

-- ── FOW thresholds (exact from highlevl.c usage) ───────────────────────────────
-- CAS: no FOW check (line 980–1000, no fow conditional)
-- BAI: fow > 0.5 * maximum (line 757)
-- SEAD/OCA/Artillery: fow >= 0.25 * maximum (lines 2072, 1620, 3062)
local FOW_THRESHOLD_BAI  = 0.50  -- line 757
local FOW_THRESHOLD_SEAD = 0.25  -- line 2072
local FOW_THRESHOLD_OCA  = 0.25  -- line 1620
local FOW_THRESHOLD_ART  = 0.25  -- line 3062

-- ── Periods (from highlevl.c add_high_level_ai_function calls; Item 5: mode-selected) ─────────
-- Campaign (highlevl.c:246-266) vs SKIRMISH (:220-240) is chosen by config.C.mode via campaign_mode.lua
-- (the single cadence source). Campaign values are byte-identical to the prior hardcoded literals.
local mode            = require("campaign_mode")
local PERIOD_CAS      = mode.SCHED.cas.period        -- :246 15min campaign / :220 6min skirmish
local PERIOD_BAI      = mode.SCHED.bai.period        -- :266 20min campaign / :236 10min skirmish
local PERIOD_SEAD     = mode.SCHED.sead.period       -- :264 12min campaign / :222 10min skirmish
local PERIOD_OCA_SWEP = mode.SCHED.oca_sweep.period  -- :258 30min campaign / :240 20min skirmish
local PERIOD_ARTY     = mode.SCHED.artillery.period  -- :254 15min campaign / :226 12min skirmish

-- ── Initial offsets (exact from add_high_level_ai_function, campaign mode) ────
local OFFSET_CAS      = 0.0           -- line 246: offset 0
local OFFSET_BAI      = 5.0 * 60      -- line 266: offset 5 min
local OFFSET_SEAD     = 3.0 * 60      -- line 264: offset 3 min
local OFFSET_OCA_SWEP = 1.5 * 60      -- line 258: offset 1.5 min
local OFFSET_ARTY     = 45.0          -- line 254: offset 45 s

-- ── Aircraft configuration (hoisted to config.lua; matches attack_waves.lua for consistency) ──────
local AC = {}
for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
    AC[side] = {
        country = config.C.countries[side],
        striker = config.C.types.aircraft[side].striker,
        escort  = config.C.types.aircraft[side].escort,
    }
end

local PYLON = config.C.payloads

local STRIKE_ALT   = 6000
local ESCORT_ALT   = 7000
local STRIKE_SPEED = 220

-- ── Sector ratio proxy (mirrors get_local_sector_side_ratio, sector.c) ────────
-- EECH: get_local_sector_side_ratio(x,z,side) = fraction of the local sector
-- neighbourhood painted by `side` (keysite 1/d² influence over the sector grid).
-- DCS proxy: fraction of owned bases within SECTOR_RATIO_RADIUS of (x,z) that
-- belong to `side` — a coarse keysite-influence stand-in.
-- NOTE: this is its OWN named constant, INDEPENDENT of the (now-deleted) frontline
-- echelon band. Cluster B decoupled the echelon split from this value; the 200 km
-- here is the sector-influence proxy radius and is NOT an EECH-derived constant
-- (no C source paints influence at a fixed metric radius), so it remains a
-- designer-tunable proxy — kept at 200 km, deliberately not re-tuned in this cluster.
local SECTOR_RATIO_RADIUS = 200000  -- metres; keysite-influence sector-paint proxy radius

local function sector_ratio(pos, side)
    if not pos then return 0.0 end
    local r2      = SECTOR_RATIO_RADIUS * SECTOR_RATIO_RADIUS
    local friendly, total = 0, 0
    for name, owner in pairs(S.base_owner) do
        local bpos = S.base_pos[name]
        if bpos then
            local dx = pos.x - bpos.x
            local dz = pos.z - bpos.z
            if dx*dx + dz*dz <= r2 then
                total = total + 1
                if owner == side then friendly = friendly + 1 end
            end
        end
    end
    if total == 0 then return 0.0 end
    return friendly / total
end

-- ── Score sorting (mirrors quicksort_entity_list) ─────────────────────────────
local function sort_targets(list)
    table.sort(list, function(a, b) return a.rating > b.rating end)
end

-- ── Sector proxy ──────────────────────────────────────────────────────────────
-- EECH reads get_local_sector_entity(pos); the port has no sector grid, so the nearest
-- keysite to a position is its "sector". Used for both the per-sector task cap and the
-- fog-of-war lookup (which is tracked per base).
local function nearest_base_to(pos)
    local best, best_d2 = nil, math.huge
    for name, bpos in pairs(S.base_pos) do
        local dx = pos.x - bpos.x
        local dz = pos.z - bpos.z
        local d2 = dx*dx + dz*dz
        if d2 < best_d2 then best_d2 = d2; best = name end
    end
    return best
end

-- Normalised (0..1) fog-of-war value at a target position for `side` = FOW of the target's
-- sector (nearest base). fow_m.get() already returns raw/FOW_MAX. Mirrors
-- get_sector_fog_of_war_value(sector_of(pos), side). Fixes the old 200 km-cap proxy that made
-- distant targets permanently un-strikeable AND un-reconnable (audit L4).
local function fow_at(pos, side)
    local base = nearest_base_to(pos)
    if not base then return 0.0 end
    return fow_m.get(base, side) or 0.0
end

-- Echelon classification (Cluster B): frontl.echelon_of(pos) returns "frontline"
-- (PRIMARY-frontline target TYPE, INT_TYPE_FRONTLINE==1, highlevl.c:877 → CAS) or
-- "second" (SECONDARY/ARTILLERY, INT_TYPE_FRONTLINE>1, highlevl.c:637 → BAI; and
-- rear AA, !frontline_flag, highlevl.c:1981 → SEAD). See frontline.lua:echelon_of
-- for the group-database-flag-vs-positional-proxy rationale. This replaces the
-- deleted `is_near_friendly` 200 km band that traced to nothing in EECH.

-- ── EECH post-sort strike-vs-recon fork (highlevl.c:731-800) ──────────────────
-- Score ALL candidates ignoring FOW, sort, then for the top CREATE_*_TASK_COUNT:
--   ratio = rating[i]/rating[0]; require ratio >= MIN_TASK_CREATION_RATIO
--   require the target's sector has < MAX_SECTOR_*_TASK_COUNT existing tasks this cycle
--   if sector FOW passes the task's threshold → create the STRIKE
--   else                                      → create a RECON of that sector instead
-- This is a FORK, not a filter: fogged high-value targets get reconned (revealed) rather than
-- silently dropped, and the #1 target keeps setting the ratio baseline either way.
-- cfg = { count, sector_max, fow_threshold (normalised 0..1, or nil = no FOW gate / never recon),
--         fow_strict (true → strict '>' as EECH BAI, else '>='), side, label,
--         spawn = function(entry) -> bool,
--         recon_obj = function(entry) -> objective table for reaction's recon-completed chain }
local function apply_fork(rated, cfg)
    local tag = cfg.dbg_tag or "cas"
    if #rated == 0 then return end
    sort_targets(rated)
    local max_r = rated[1].rating
    if max_r <= 0 then return end
    local count = math.min(#rated, cfg.count)
    local sectors_used = {}
    local n_struck, n_reconned, n_ratio_dropped, n_sector_capped = 0, 0, 0, 0

    for i = 1, count do
        local e = rated[i]
        if e.rating / max_r >= MIN_TASK_CREATION_RATIO then
            local base = nearest_base_to(e.pos)      -- the sector whose FOW the gate reads
            local sk   = base or tostring(i)
            local used = sectors_used[sk] or 0
            if used < cfg.sector_max then
                local ok
                if cfg.fow_threshold == nil then
                    -- CAS: no FOW gate, always strike (never recon).
                    ok = cfg.spawn(e)
                    if ok then n_struck = n_struck + 1 end
                else
                    local fow  = fow_at(e.pos, cfg.side)
                    local pass = cfg.fow_strict and (fow > cfg.fow_threshold)
                                                 or (not cfg.fow_strict and fow >= cfg.fow_threshold)
                    if pass then
                        ok = cfg.spawn(e)                              -- reconned → strike
                        if ok then n_struck = n_struck + 1 end
                    else
                        -- Fogged → RECON. Aim at the SECTOR BASE (the FOW value the gate reads),
                        -- not the raw target, so the overflight actually raises that base's FOW
                        -- and the target becomes strikeable next cycle (self-heal for all task types).
                        local recon_pos = (base and S.base_pos[base]) or e.pos
                        local obj = cfg.recon_obj and cfg.recon_obj(e) or nil
                        ok = recon.spawn_recon(cfg.side, recon_pos, cfg.label, cfg.log_fn, obj)
                        if ok then n_reconned = n_reconned + 1 end
                    end
                end
                if ok then sectors_used[sk] = used + 1 end
            else
                n_sector_capped = n_sector_capped + 1
            end
        else
            n_ratio_dropped = n_ratio_dropped + 1
        end
    end
    cs.dbg(tag, "%s %s fork: %d rated -> top %d checked: %d struck, %d reconned (fogged), %d below ratio, %d sector-capped",
        cs.SIDE_NAME[cfg.side], cfg.label, #rated, count, n_struck, n_reconned, n_ratio_dropped, n_sector_capped)
end

-- ── SEAD escort (assign.c:598-627 escort_required, threshold model) ───────────
-- EECH creates an escort at task assignment when route difficulty >= escort_required_threshold; SEAD's
-- warzone threshold is the highest (5) so escort only fires on genuinely deep/defended legs. Fixed-wing
-- fighters resident at the launch base; SECONDARY escort ledger consume with refund-on-fail (dev-loop).
local function spawn_sead_escort(side, home_ab, ab_pos, target_pos, n, log_fn)
    if n <= 0 then return end
    local base_name = home_ab:getName()
    if not supply.consume_base(base_name, "escort", n) then
        cs.dbg("sead", "%s SEAD escort ABORT at %s: no escort stock", cs.SIDE_NAME[side], base_name)
        return
    end
    local cfg    = AC[side]
    local bx, by = cs.wp_xy(ab_pos)
    local tx, ty = cs.wp_xy(target_pos)
    local eid    = cs.next_id()
    local ename  = string.format("Escort-%d", eid)
    local e_units = {}
    for i = 1, n do
        e_units[i] = { name = ename.."-"..i, type = cfg.escort, skill = "High",
            x = ab_pos.x + (i-1)*20, y = ab_pos.z, alt = ab_pos.y, alt_type = "BARO", speed = 0, heading = 0,
            payload = { fuel = 5200, flare = 120, chaff = 120, gun = 100, pylons = PYLON[side].escort } }
    end
    local ok_e, grp = pcall(coalition.addGroup, cfg.country, Group.Category.AIRPLANE, {
        name = ename, task = "Fighter Sweep", hidden = false, airdromeId = home_ab:getID(), units = e_units,
        route = { points = croute.expand({
            { type="TakeOff", action="From Parking Area", airdromeId=home_ab:getID(),
              alt=ab_pos.y, alt_type="BARO", speed=0, ETA=0, ETA_locked=true, x=bx, y=by, name="Depart", formation_template="" },
            { type="Turning Point", action="Turning Point", alt=ESCORT_ALT, alt_type="BARO", speed=STRIKE_SPEED,
              ETA=0, ETA_locked=false, x=tx, y=ty, name="Sweep", formation_template="",
              task = { id="ComboTask", params={ tasks={ [1]={ number=1, auto=true, id="EngageTargets",
                enabled=true, params={ maxDist=40000, priority=0, targetTypes={"Air"} } } }}}},
            { type="Land", action="Landing", airdromeId=home_ab:getID(),
              alt=ab_pos.y, alt_type="BARO", speed=STRIKE_SPEED, ETA=0, ETA_locked=false, x=bx, y=by, name="RTB", formation_template="" },
        }, side, { alt=ESCORT_ALT, alt_type="BARO", speed=STRIKE_SPEED, name="Nav" }) },
    })
    if ok_e and grp then
        cs.dbg("sead", "%s SEAD escort #%d (%dx%s) spawned from %s", cs.SIDE_NAME[side], eid, n, cfg.escort, base_name)
    else
        supply.recycle_base(base_name, "escort", n)   -- refund: escort spawn failed/threw
        cs.dbg("sead", "%s SEAD escort #%d FAILED (pcall_ok=%s) -> refunded", cs.SIDE_NAME[side], eid, tostring(ok_e))
    end
end

-- ── build_air_strike(side, base_name, target_pos, task_label, log_fn) ─────────
-- BUILDER (task-board contract): spawns a striker FROM base_name at target_pos. The board has
-- already consumed 1 "striker" from base_name's ledger (refunds on nil). Shared by CAS/BAI/SEAD.
-- Returns the group on success, nil on failure.
local function build_air_strike(side, base_name, target_pos, task_label, log_fn)
    local dbg_tag = task_label:find("SEAD") and "sead" or (task_label:find("BAI") and "bai" or "cas")
    local home_ab = Airbase.getByName(base_name)
    if not home_ab then
        cs.dbg(dbg_tag, "%s build_air_strike ABORT: base %s not found", cs.SIDE_NAME[side], tostring(base_name))
        return nil
    end

    local cfg    = AC[side]
    local ab_pos = home_ab:getPosition().p
    local bx, by = cs.wp_xy(ab_pos)
    local tx, ty = cs.wp_xy(target_pos)
    local sid    = cs.next_id()
    local gname  = string.format("%s-%d-%d", task_label, side, sid)

    -- SEAD role (#16): dedicated SEAD tasking so the AI prioritises radars/air-defence rather than
    -- generic ground units. NOTE: an anti-radiation loadout (AGM-88 HARM / Kh-25MP) needs weapon
    -- CLSIDs verified against the live DCS DB (guardrail) — swap PYLON[side].sead in once verified;
    -- the striker payload (Kh-29T / GBU can still kill radars) is the interim verified loadout.
    local is_sead    = task_label:find("SEAD") ~= nil
    local dcs_task   = is_sead and "SEAD" or "Ground Attack"
    local target_set = is_sead and { "Air Defence" } or { "Ground Units", "Helicopters" }

    local grp = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
        name        = gname,
        task        = dcs_task,
        hidden      = false,
        airdromeId  = home_ab:getID(),
        units = {{
            name     = gname .. "-1",
            type     = cfg.striker,
            skill    = "Good",
            x        = ab_pos.x,
            y        = ab_pos.z,
            alt      = ab_pos.y,
            alt_type = "BARO",
            speed    = 0,
            heading  = cs.heading_to(ab_pos.x, ab_pos.z, target_pos.x, target_pos.z),
            payload  = { fuel = 4900, flare = 60, chaff = 60, gun = 100, pylons = PYLON[side].striker },
        }},
        route = { points = croute.expand({
            {
                type = "TakeOff", action = "From Parking Area",
                airdromeId = home_ab:getID(),
                alt = ab_pos.y, alt_type = "BARO", speed = 0,
                ETA = 0, ETA_locked = true,
                x = bx, y = by, name = "Depart", formation_template = "",
            },
            {
                type = "Turning Point", action = "Turning Point",
                alt = STRIKE_ALT, alt_type = "BARO", speed = STRIKE_SPEED,
                ETA = 0, ETA_locked = false, x = tx, y = ty,
                name = "Attack", formation_template = "",
                task = {
                    id = "ComboTask",
                    params = { tasks = { [1] = {
                        number = 1, auto = true, id = "EngageTargets", enabled = true,
                        params = { maxDist = 15000, priority = 0,
                                   targetTypes = { "Ground Units", "Helicopters" } },
                    }}},
                },
            },
            {
                type = "Land", action = "Landing",
                airdromeId = home_ab:getID(),
                alt = ab_pos.y, alt_type = "BARO", speed = STRIKE_SPEED,
                ETA = 0, ETA_locked = false,
                x = bx, y = by, name = "RTB", formation_template = "",
            },
        }, side, { alt=STRIKE_ALT, alt_type="BARO", speed=STRIKE_SPEED, name="Nav" })},
    })

    if grp then
        ov.add_task_arrow(gname, ab_pos, target_pos, side)   -- Item 4: key by group name (GC backstop reaps it)
        -- Escort by threat (assign.c:598-627): SEAD flights get fighter escort iff route difficulty
        -- >= the SEAD escort threshold (5). Only SEAD is escort-eligible here (CAS/BAI are rotary).
        if is_sead then
            local ec = cs.escort_count("sead", side, ab_pos, target_pos, log_fn)
            spawn_sead_escort(side, home_ab, ab_pos, target_pos, ec, log_fn)
        end
        log_fn(string.format("%s %s #%d from %s", cs.SIDE_NAME[side], task_label, sid, home_ab:getName()))
        cs.dbg(dbg_tag, "%s %s #%d spawned from %s (task=%s)", cs.SIDE_NAME[side], task_label, sid,
            home_ab:getName(), dcs_task)
        return grp
    end
    log_fn(string.format("%s %s #%d SPAWN FAILED", cs.SIDE_NAME[side], task_label, sid))
    cs.dbg(dbg_tag, "%s %s #%d SPAWN FAILED (addGroup returned nil)", cs.SIDE_NAME[side], task_label, sid)
    return nil
end

-- Create a board task for a striker sortie (task_type = "cas"|"bai"|"sead"; label drives the DCS
-- task/target set inside build_air_strike). Returns true (task placed) for the per-sector cap.
-- `critical` (optional, WAVE 3 Item 4): reaction callers pass true (SEAD reaction.c:540/highlevl.c:2659,
-- BAI-from-recon reaction.c:583) or false (counter-battery BAI reaction.c:788) so the board sorts the
-- task at the C's critical setting (assign.c:201-204). Generator callers omit it → M.CRITICAL default.
local function create_air_strike_task(side, target_pos, task_type, task_label, log_fn, immediate, critical)
    -- CAS and BAI are the ROTARY frontline fight in EECH (heli-eligible, ts_dbase.c landing_types
    -- :511/:329) — they launch ATTACK-HELICOPTER sections. The board's "heli" role assigns them to
    -- the nearest heli-capable base; forward FARPs win, so the front becomes a helicopter war (this
    -- is what the retired heli_war anti_armour/hunter_killer layer was faking). SEAD stays fixed-wing.
    local builder
    if task_type == "cas" or task_type == "bai" then
        local hw = require("heli_war")
        builder = function(base_name)
            return hw.build_attack_heli(side, base_name, target_pos, task_type, log_fn)
        end
    else
        builder = function(base_name)
            return build_air_strike(side, base_name, target_pos, task_label, log_fn)
        end
    end
    board.create_task({
        type = task_type, side = side, count = 1, log_fn = log_fn, immediate = immediate,
        critical = critical,   -- nil for generators (M.CRITICAL default); set by the reaction chain
        target = { pos = target_pos },
        builder = builder,
    })
    return true
end

-- ── Echelon-by-GROUP-TYPE (Cluster F, fold-in from Cluster B) ─────────────────
-- EECH splits ground targets between CAS/BAI/SEAD by the STATIC per-group-TYPE flag
-- group_database[sub_type].frontline_flag (INT_TYPE_FRONTLINE, gp_int.c:389-392); the enum is
-- NONE=0 / PRIMARY=1 / SECONDARY=2 / ARTILLERY=3 (group.h:199-202):
--   create_cas_tasks  keeps FRONTLINE==1 (PRIMARY armour, highlevl.c:877)          → CAS
--   create_bai_tasks  keeps FRONTLINE >1 (SECONDARY support + ARTILLERY, hl.c:637) → BAI
--   create_sead_tasks keeps !frontline_flag AA (NONE, highlevl.c:1981)             → SEAD
-- The port now tags its spawned ground groups by NAME, so we can read the flag by TYPE directly:
--   "GndCol-"  = COMBINED-ARMS PRIMARY frontline (FORMCOMP.DAT:434-469: tanks + IFVs + ORGANIC AD
--                slots 4/6 + APCs; gp_dbase.c:723 frontline_flag PRIMARY) → flag 1
--   "GndSec-"  = SECONDARY second-echelon frontline group (FORMCOMP.DAT:475-511: tanks + IFVs +
--                organic SHORAD + trucks/scout; GROUP_SECONDARY_FRONTLINE frontline_flag SECONDARY,
--                gp_dbase.c:764) → flag 2. FRONTLINE>1 → these are the CANONICAL BAI targets
--                (highlevl.c:637), never CAS (==1), never SEAD (tagged → not a get_enemy_aa_targets
--                candidate even when attrition compacts its lead onto the organic Chaparral/SA-13).
--   "Arty-"    = SP-artillery / MLRS battery (FORMCOMP.DAT:549-579; gp_dbase.c:805/846) → flag 3
--   "*-def"    = installation garrison company → flag 2 (SECONDARY)
--   "Patrol-"  = 4-man infantry keysite patrol → flag 0 (NONE): EECH's infantry-patrol group type is
--                not a frontline group (frontline_flag NONE, gp_int.c:389-392 returns the database
--                flag), and BOTH generators exclude 0 — CAS keeps ==1 (highlevl.c:877), BAI keeps
--                >1 (highlevl.c:637) — so patrols are a target of NEITHER.
--   "FP-"      = population FIRING POINT / MANPAD (GROUP_STATIC_INFANTRY, gp_dbase.c:887 frontline_flag
--                NONE; air_attack_strength 6, gp_dbase.c:896) → flag 0 (NONE): matched by NEITHER CAS
--                (==1) nor BAI (>1), and — being non-nil-flagged (tagged) — excluded from the generator
--                SEAD's get_enemy_aa_targets (highlevl.c:1981 wants air_attack==10 SITE AA; a MANPAD
--                soldier is not). NOTE: EECH's REACTION SEAD-around-keysite (highlevl.c:2620) filters on
--                default_entity_type==ANTI_AIRCRAFT, which GROUP_STATIC_INFANTRY IS (gp_dbase.c:876), so
--                firing-point MANPADs DO count there — reaction.create_sead_around_keysite is left
--                untagged/unchanged to stay faithful. MANPADs also feed the AIR_DEFENCE imap by
--                attribute (desired, small contribution).
-- GENUINELY unknown combat groups (no tag) fall back to the POSITIONAL proxy frontl.echelon_of(pos)
-- from Cluster B. Type-first, position-as-fallback (used FIRST per the Cluster F spec).
local function group_frontline_flag(grp)
    local n = (grp and grp.getName and grp:getName()) or ""
    if n:match("^GndCol")  then return 1 end   -- PRIMARY   (gp_dbase.c:723)
    if n:match("^GndSec")  then return 2 end   -- SECONDARY (gp_dbase.c:764) → BAI target
    if n:match("^Arty")    then return 3 end   -- ARTILLERY (gp_dbase.c:805/846)
    if n:match("%-def$")   then return 2 end   -- installation garrison → SECONDARY
    if n:match("^Patrol")  then return 0 end   -- infantry patrol → NONE (excluded from CAS AND BAI)
    if n:match("^FP%-")    then return 0 end   -- population firing point / MANPAD → NONE (gp_dbase.c:887)
    return nil                                  -- unknown → positional fallback
end

-- Echelon of a ground target: type flag first (0 → "none": neither generator; 1 → "frontline"/CAS;
-- >1 → "second"/BAI), else the Cluster B positional proxy for untagged combat groups.
local function target_echelon(t)
    local f = group_frontline_flag(t.group)
    if f == 0 then return "none" end        -- NONE: matched by neither ==1 nor >1 (highlevl.c:877/:637)
    if f == 1 then return "frontline" end
    if f then return "second" end           -- 2 (SECONDARY) / 3 (ARTILLERY)
    return frontl.echelon_of(t.pos)
end

-- ── Collect enemy ground group targets ────────────────────────────────────────
-- Mirrors EECH LIST_TYPE_GROUND_REGISTRY scan in create_cas/bai_tasks().
-- EECH iterates all registered ground groups per force. DCS proxy: scan
-- coalition.getGroups(enemy) for GROUND category groups, excluding AA (→ SEAD).
-- Enemy ARTILLERY is NOT excluded: EECH create_bai_tasks keeps FRONTLINE>1 which includes
-- ARTILLERY(3) — batteries are legitimate BAI targets (and counter-battery targets). They classify
-- as "second" via target_echelon so they flow to BAI, never CAS. This closes the single-column limit.
local function get_enemy_ground_targets(side)
    local enemy   = cs.ENEMY[side]
    local targets = {}
    local grps = coalition.getGroups(enemy)
    if not grps then return targets end

    for _, grp in ipairs(grps) do
        if #targets >= MAX_HIGHLEVEL_TARGET_CHECKS then break end
        if grp and grp:isExist() and grp:getCategory() == Group.Category.GROUND then
            local u = grp:getUnit(1)
            if u and u:isExist() then
                -- TAG PRIORITY (organic-AD guard): PRIMARY groups now carry ORGANIC AD (FORMCOMP.DAT
                -- slots 4/6 — Avenger/SA-19, Chaparral/SA-13). This scan classifies by unit(1)
                -- attributes, and after attrition the lead unit can compact onto an AD vehicle —
                -- which would silently reclassify the whole GndCol as an AA group. A NAME-tagged
                -- campaign group's echelon flag is authoritative (EECH's frontline_flag is per
                -- GROUP TYPE, gp_int.c:389-392, never per member), so tagged groups are always
                -- ground targets; the unit-level is_aa filter applies only to untagged groups.
                local tagged = group_frontline_flag(grp) ~= nil
                local desc = u:getDesc()
                local attr = desc and desc.attributes
                -- Exclude only untagged AA (air_attack_strength==10 → SEAD's job, highlevl.c:1981).
                local is_aa  = attr and (attr["SAM"] or attr["AAA"] or attr["SR SAM"] or
                                          attr["LR SAM"] or attr["MR SAM"] or attr["IR Guided SAM"])
                if tagged or not is_aa then
                    targets[#targets + 1] = { group = grp, pos = u:getPosition().p }
                end
            end
        end
    end
    return targets
end

-- ── Collect enemy AA group targets ────────────────────────────────────────────
-- Mirrors EECH: air_attack_strength==10 groups in LIST_TYPE_GROUND_REGISTRY.
-- TAG PRIORITY (organic-AD guard, mirror of get_enemy_ground_targets): a NAME-tagged campaign
-- ground group is NEVER a SEAD target even if its lead unit compacts onto an organic AD vehicle
-- (FORMCOMP.DAT slots 4/6) — EECH SEADs only air_attack_strength==10 site-AA groups
-- (highlevl.c:1981); a PRIMARY frontline group's stat is 6 (gp_dbase.c:732) and its
-- frontline_flag is per GROUP TYPE (gp_int.c:389-392), so it stays a CAS/BAI ground target.
local function get_enemy_aa_targets(enemy_side)
    local targets = {}
    local grps = coalition.getGroups(enemy_side)
    if not grps then return targets end
    for _, grp in ipairs(grps) do
        if grp and grp:isExist() and #targets < MAX_HIGHLEVEL_TARGET_CHECKS then
            local u = grp:getUnit(1)
            if u and u:isExist() and group_frontline_flag(grp) == nil then
                local desc = u:getDesc()
                if desc and desc.attributes and (
                    desc.attributes["SAM"] or desc.attributes["AAA"] or
                    desc.attributes["SR SAM"] or desc.attributes["LR SAM"] or
                    desc.attributes["MR SAM"] or desc.attributes["IR Guided SAM"]
                ) then
                    targets[#targets + 1] = { group = grp, pos = u:getPosition().p }
                end
            end
        end
    end
    return targets
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. CAS — create_cas_tasks (highlevl.c line 815)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Score = (1-airdef)*1 + base_dist*3 + sector_ratio*2;  max=6.0
-- Targets: frontline enemy ground groups (FRONTLINE==1)
-- No FOW check
local function run_cas(side, log_fn)
    local targets = get_enemy_ground_targets(side)
    if #targets == 0 then
        log_fn(cs.SIDE_NAME[side] .. " CAS: no ground targets found")
        cs.dbg("cas", "%s CAS: no ground targets found, skipping", cs.SIDE_NAME[side])
        return
    end

    -- Score each target (mirrors create_cas_tasks loop). FOW is NOT applied here — the fork
    -- handles it. CAS keeps PRIMARY-frontline targets (INT_TYPE_FRONTLINE==1, highlevl.c:877),
    -- proxied by frontl.echelon_of(pos)=="frontline". Second-line targets fall through to BAI.
    local rated = {}
    local n_front, n_second = 0, 0
    for _, t in ipairs(targets) do
        local pos    = t.pos
        local front  = target_echelon(t) == "frontline"
        if front then n_front = n_front + 1 else n_second = n_second + 1 end

        if front then
            -- ORIENTATION FIX (Cluster F review): AIR_DEFENCE[side] = the AA that SIDE faces (imap's
            -- updater scans SIDE's enemy's AA groups), so the ATTACKER reads its OWN side's layer —
            -- get(side, ...). The old get(enemy, ...) returned the attacker's own AA, inverting the
            -- (1-airdef) term. Matches EECH get_imap_value(IMAP_AIR_DEFENCE, side, ...) semantics.
            local airdef = imap_m.get(side, imap_m.AIR_DEFENCE, pos)
            local bdist  = imap_m.get(side, imap_m.BASE_DISTANCE, pos)
            local sratio = sector_ratio(pos, side)

            -- EECH formula: (1-airdef)*1 + base_dist*3 + sector_ratio*2; max=6.0
            local rating = (1.0 - airdef) * 1.0 + bdist * 3.0 + sratio * 2.0
            if rating > 0.0 then
                rated[#rated + 1] = { pos = pos, group = t.group, rating = rating }
            end
        end
    end

    cs.dbg("cas", "%s cas-scan: %d groups, %d frontline (cas), %d second-line (bai) -> %d rated (up to %d tasks)",
        cs.SIDE_NAME[side], #targets, n_front, n_second, #rated, CREATE_CAS_TASK_COUNT)

    -- CAS has NO fog-of-war gate in EECH → fow_threshold = nil (always strike, never recon).
    apply_fork(rated, {
        count = CREATE_CAS_TASK_COUNT, sector_max = MAX_SECTOR_CAS_TASK_COUNT,
        fow_threshold = nil, side = side, label = "CAS", log_fn = log_fn, dbg_tag = "cas",
        spawn = function(e) return create_air_strike_task(side, e.pos, "cas", "CAS", log_fn) end,
    })
end

function M.schedule_cas(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    -- Offset MUST be strictly > 0: DCS silently drops a timer scheduled at timer.getTime()+0, so an
    -- offset of 0 means the scheduler never fires (this is exactly what suppressed BLUE's whole
    -- attack-heli war). Clamp to a 1 s floor so a 0 can never silently disable a side again.
    local offset = math.max(initial_offset or OFFSET_CAS, 1)
    cs.dbg("cas", "%s CAS scheduler REGISTERED offset=%.0fs period=%.0fs", cs.SIDE_NAME[side], offset, PERIOD_CAS)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end    -- re-injection guard: cancel superseded closure
        -- Item 6 (LITERAL post-victory semantics): the world runs on after victory — EECH fc_msgs.c:163
        -- gates ONLY the win-check re-award (INT_TYPE_SESSION_COMPLETE), never the highlevl.c generators.
        -- The prior Cluster-E generator suppression is removed (it was a proxy, not the literal C).
        cs.dbg("cas", "%s CAS FIRE", cs.SIDE_NAME[side])
        local ok, err = pcall(run_cas, side, log_fn)
        if not ok then log_fn("CAS error: " .. tostring(err)) end
        return t + PERIOD_CAS
    end, nil, timer.getTime() + offset)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. BAI — create_bai_tasks (highlevl.c line 575)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Score = (1-airdef)*2 + base_dist*3 + sector_ratio*2;  max=7.0
-- Targets: enemy ground groups where FRONTLINE>1 (NOT primary frontline → second-line)
-- FOW: fow > 0.5 * maximum (line 757 — confirmed 0.5, higher than other checks)
local function run_bai(side, log_fn)
    local targets = get_enemy_ground_targets(side)
    if #targets == 0 then
        cs.dbg("bai", "%s BAI: no ground targets found, skipping", cs.SIDE_NAME[side])
        return
    end

    -- Score ALL candidates ignoring FOW (the fork applies FOW). BAI keeps second-line targets
    -- (INT_TYPE_FRONTLINE>1 → SECONDARY/ARTILLERY, highlevl.c:637), proxied by
    -- frontl.echelon_of(pos)=="second". Primary-frontline targets are CAS's.
    local rated = {}
    local n_front, n_second = 0, 0
    for _, t in ipairs(targets) do
        local pos    = t.pos
        local second = target_echelon(t) == "second"
        if second then n_second = n_second + 1 else n_front = n_front + 1 end

        if second then
            -- ORIENTATION FIX: AIR_DEFENCE[side] = the AA that SIDE faces → attacker reads its own
            -- side's layer, get(side, ...) (see run_cas note; old get(enemy,...) was inverted).
            local airdef = imap_m.get(side, imap_m.AIR_DEFENCE, pos)
            local bdist  = imap_m.get(side, imap_m.BASE_DISTANCE, pos)
            local sratio = sector_ratio(pos, side)

            -- EECH formula: (1-airdef)*2 + base_dist*3 + sector_ratio*2; max=7.0
            local rating = (1.0 - airdef) * 2.0 + bdist * 3.0 + sratio * 2.0
            if rating > 0.0 then
                rated[#rated + 1] = { pos = pos, group = t.group, rating = rating }
            end
        end
    end

    cs.dbg("bai", "%s bai-scan: %d groups, %d frontline (cas), %d second-line (bai) -> %d rated (up to %d tasks)",
        cs.SIDE_NAME[side], #targets, n_front, n_second, #rated, CREATE_BAI_TASK_COUNT)

    -- FOW gate (line 757): fow > 0.5 × max (STRICT) → BAI strike; else → RECON of the sector.
    apply_fork(rated, {
        count = CREATE_BAI_TASK_COUNT, sector_max = MAX_SECTOR_BAI_TASK_COUNT,
        fow_threshold = FOW_THRESHOLD_BAI, fow_strict = true,
        side = side, label = "BAI", log_fn = log_fn, dbg_tag = "bai",
        spawn = function(e) return create_air_strike_task(side, e.pos, "bai", "BAI", log_fn) end,
        recon_obj = function(e) return { kind = "frontline_group", pos = e.pos, group = e.group } end,
    })
end

function M.schedule_bai(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    local offset = initial_offset or OFFSET_BAI
    cs.dbg("bai", "%s BAI scheduler REGISTERED offset=%.0fs period=%.0fs", cs.SIDE_NAME[side], offset, PERIOD_BAI)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end    -- re-injection guard: cancel superseded closure
        -- Item 6: generators keep running post-victory (EECH fc_msgs.c:163 gates only the win re-award).
        cs.dbg("bai", "%s BAI FIRE", cs.SIDE_NAME[side])
        local ok, err = pcall(run_bai, side, log_fn)
        if not ok then log_fn("BAI error: " .. tostring(err)) end
        return t + PERIOD_BAI
    end, nil, timer.getTime() + offset)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. SEAD — create_sead_tasks (highlevl.c line 1918)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Score = base_dist*4 + sector_ratio*3;  max=7.0
-- Targets: enemy groups with air_attack_strength==10 AND NOT frontline
-- FOW: fow >= 0.25 * maximum (line 2072)
local function run_sead(side, log_fn)
    local enemy   = cs.ENEMY[side]
    local targets = get_enemy_aa_targets(enemy)
    if #targets == 0 then
        cs.dbg("sead", "%s SEAD: no enemy AA targets found, skipping", cs.SIDE_NAME[side])
        return
    end

    -- EECH SEADs only NON-frontline AA (highlevl.c:1981 `!group_database[type].frontline_flag`):
    -- rear SAM sites and standalone air-defence, NOT frontline-attached AA (which the CAS/BAI
    -- package suppresses incidentally). The port has no per-group-type frontline_flag, so it
    -- proxies via echelon position: keep AA whose nearest owned base is NOT a frontline base
    -- (frontl.echelon_of(pos)=="second"). Frontline-sector AA is excluded, matching the C filter.
    local rated = {}
    local n_rear, n_front = 0, 0
    for _, t in ipairs(targets) do
        local pos = t.pos
        -- AA groups carry no GndCol/Arty/-def name tag → target_echelon falls back to the positional
        -- proxy (identical to the Cluster B behaviour), keeping frontline-attached AA out of SEAD.
        if target_echelon(t) == "second" then
            n_rear = n_rear + 1
            local bdist  = imap_m.get(side, imap_m.BASE_DISTANCE, pos)
            local sratio = sector_ratio(pos, side)

            -- EECH formula: base_dist*4 + sector_ratio*3; max=7.0
            -- (commented-out terms in source not used: airdef, importance)
            local rating = bdist * 4.0 + sratio * 3.0
            if rating > 0.0 then
                rated[#rated + 1] = { pos = pos, group = t.group, rating = rating }
            end
        else
            n_front = n_front + 1
        end
    end

    cs.dbg("sead", "%s sead-scan: %d AA groups, %d rear (sead), %d frontline-attached (excluded) -> %d rated (up to %d tasks)",
        cs.SIDE_NAME[side], #targets, n_rear, n_front, #rated, CREATE_SEAD_TASK_COUNT)

    -- FOW gate (line 2072): fow >= 0.25 × max → SEAD strike; else → RECON of the sector.
    apply_fork(rated, {
        count = CREATE_SEAD_TASK_COUNT, sector_max = MAX_SECTOR_SEAD_TASK_COUNT,
        fow_threshold = FOW_THRESHOLD_SEAD, side = side, label = "SEAD", log_fn = log_fn, dbg_tag = "sead",
        spawn = function(e) return create_air_strike_task(side, e.pos, "sead", "SEAD", log_fn) end,
        recon_obj = function(e) return { kind = "aa_group", group = e.group, pos = e.pos } end,
    })
end

function M.schedule_sead(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    local offset = initial_offset or OFFSET_SEAD
    cs.dbg("sead", "%s SEAD scheduler REGISTERED offset=%.0fs period=%.0fs", cs.SIDE_NAME[side], offset, PERIOD_SEAD)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end    -- re-injection guard: cancel superseded closure
        -- Item 6: generators keep running post-victory (EECH fc_msgs.c:163 gates only the win re-award).
        cs.dbg("sead", "%s SEAD FIRE", cs.SIDE_NAME[side])
        local ok, err = pcall(run_sead, side, log_fn)
        if not ok then log_fn("SEAD error: " .. tostring(err)) end
        return t + PERIOD_SEAD
    end, nil, timer.getTime() + offset)
end

-- Also expose direct SEAD spawn for reaction.lua to call
-- Mirrors EECH: create_sead_task called from reaction chain when AA found near strike target
-- SINGLE-SHOT EXPORTS (never-replace list) — reimplemented as immediate create_task wrappers.
-- `critical` (optional): reaction SEAD is critical=TRUE (reaction.c:540, highlevl.c:2659) — reaction.lua
-- passes true. Signature back-compatible: existing callers that omit it get the M.CRITICAL default.
function M.spawn_sead_against(side, aa_group, log_fn, critical)
    log_fn = log_fn or function() end
    if not aa_group or not aa_group:isExist() then
        cs.dbg("sead", "%s spawn_sead_against ABORT: aa_group missing/dead", cs.SIDE_NAME[side])
        return false
    end
    local u = aa_group:getUnit(1)
    if not u or not u:isExist() then
        cs.dbg("sead", "%s spawn_sead_against ABORT: aa_group has no live unit", cs.SIDE_NAME[side])
        return false
    end
    cs.dbg("sead", "%s spawn_sead_against: reaction-triggered SEAD task queued (immediate)", cs.SIDE_NAME[side])
    return create_air_strike_task(side, u:getPosition().p, "sead", "SEAD-React", log_fn, true, critical)
end

-- Direct BAI spawn for reaction.lua's recon-of-frontline-group → BAI chain (reaction.c:568).
-- `critical` (optional): the recon-of-frontline BAI is critical=TRUE (reaction.c:583) but the
-- counter-battery BAI (create_reaction_to_artillery_fire) is critical=FALSE (reaction.c:788) — reaction.lua
-- passes the C's value per call site. Omitting it (existing callers) keeps the M.CRITICAL default.
function M.spawn_bai_against(side, pos, log_fn, critical)
    log_fn = log_fn or function() end
    if not pos then
        cs.dbg("bai", "%s spawn_bai_against ABORT: no pos", cs.SIDE_NAME[side])
        return false
    end
    cs.dbg("bai", "%s spawn_bai_against: reaction-triggered BAI task queued (immediate)", cs.SIDE_NAME[side])
    return create_air_strike_task(side, pos, "bai", "BAI-React", log_fn, true, critical)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. OCA Sweep — create_oca_sweep_tasks (highlevl.c line 1473)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Score = (1-airdef)*1 + base_dist*4 + sector_ratio*2;  max=7.0
-- Targets: enemy keysites where keysite_database[type].oca_target == true
--          (DCS proxy: all enemy-owned airbases)
-- FOW: fow >= 0.25 * maximum (line 1620)
-- Spawns: ESCORT (fighter) aircraft for CAP orbit rather than strike
-- BUILDER: spawn a fighter sweep (escort) FROM base_name over the target airfield. The board has
-- already consumed 1 "escort" from base_name's ledger (refunds on nil). Returns group or nil.
local function build_oca_sweep(side, base_name, target_pos, target_name, log_fn)
    local home_ab = Airbase.getByName(base_name)
    if not home_ab then
        cs.dbg("oca", "%s build_oca_sweep ABORT: base %s not found", cs.SIDE_NAME[side], tostring(base_name))
        return nil
    end
    local cfg    = AC[side]
    local ab_pos = home_ab:getPosition().p
    local bx, by = cs.wp_xy(ab_pos)
    local tx, ty = cs.wp_xy(target_pos)
    local sid    = cs.next_id()
    local gname  = string.format("OCA-Sweep-%d-%d", side, sid)

    local sweep_grp = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
        name        = gname,
        task        = "Fighter Sweep",
        hidden      = false,
        airdromeId  = home_ab:getID(),
        units = {{
            name = gname.."-1", type = cfg.escort, skill = "High",
            x = ab_pos.x, y = ab_pos.z, alt = ab_pos.y, alt_type = "BARO",
            speed = 0, heading = 0,
            payload = { fuel = 5200, flare = 120, chaff = 120, gun = 100, pylons = PYLON[side].escort },
        }},
        route = { points = croute.expand({
            { type="TakeOff", action="From Parking Area", airdromeId=home_ab:getID(),
              alt=ab_pos.y, alt_type="BARO", speed=0, ETA=0, ETA_locked=true,
              x=bx, y=by, name="Depart", formation_template="" },
            { type="Turning Point", action="Turning Point",
              alt=ESCORT_ALT, alt_type="BARO", speed=STRIKE_SPEED,
              ETA=0, ETA_locked=false, x=tx, y=ty, name="Sweep", formation_template="",
              task = { id="ComboTask", params={ tasks={ [1]={ number=1, auto=true,
                id="EngageTargets", enabled=true,
                params={ maxDist=40000, priority=0, targetTypes={"Air"} } }}}},
            },
            { type="Land", action="Landing", airdromeId=home_ab:getID(),
              alt=ab_pos.y, alt_type="BARO", speed=STRIKE_SPEED, ETA=0, ETA_locked=false,
              x=bx, y=by, name="RTB", formation_template="" },
        }, side, { alt=ESCORT_ALT, alt_type="BARO", speed=STRIKE_SPEED, name="Nav" })},
    })
    if sweep_grp then
        -- Offensive keysite task → registered so the defender scrambles CAP/BARCAP at target_name.
        cs.register_task(gname, {
            task_type   = "oca_sweep",
            side        = side,
            target_base = target_name,
            target_pos  = target_pos,
            objective   = { kind = "keysite", base = target_name },
            born_time   = timer.getTime(),
        })
        ov.add_task_arrow(gname, ab_pos, target_pos, side)   -- Item 4: key by group name (clear_task reaps it)
        log_fn(string.format("%s OCA Sweep #%d from %s → %s", cs.SIDE_NAME[side], sid, home_ab:getName(), target_name or "?"))
        cs.dbg("oca", "%s OCA Sweep #%d spawned from %s -> %s", cs.SIDE_NAME[side], sid, home_ab:getName(), target_name or "?")
        return sweep_grp
    end
    cs.dbg("oca", "%s OCA Sweep #%d SPAWN FAILED", cs.SIDE_NAME[side], sid)
    return nil
end

-- Create a board task for an OCA sweep (role escort). target has a base name (airfield objective).
local function create_oca_sweep_task(side, target_pos, target_name, log_fn)
    board.create_task({
        type = "oca_sweep", side = side, count = 1, log_fn = log_fn,
        target = { base = target_name, pos = target_pos, objective = { kind = "keysite", base = target_name } },
        builder = function(base_name)
            return build_oca_sweep(side, base_name, target_pos, target_name, log_fn)
        end,
    })
    return true
end

local function run_oca_sweep(side, log_fn)
    local enemy = cs.ENEMY[side]

    -- Score ALL enemy airfields ignoring FOW (the fork applies FOW).
    local rated = {}
    for tname, towner in pairs(S.base_owner) do
        if towner == enemy then
            local tpos = S.base_pos[tname]
            if tpos then
                -- ORIENTATION FIX: AIR_DEFENCE[side] = the AA that SIDE faces → attacker reads its
                -- own side's layer, get(side, ...) (see run_cas note; old get(enemy,...) was inverted).
                local airdef = imap_m.get(side, imap_m.AIR_DEFENCE, tpos)
                local bdist  = imap_m.get(side, imap_m.BASE_DISTANCE, tpos)
                local sratio = sector_ratio(tpos, side)

                -- EECH formula: (1-airdef)*1 + base_dist*4 + sector_ratio*2; max=7.0
                local rating = (1.0 - airdef) * 1.0 + bdist * 4.0 + sratio * 2.0
                if rating > 0.0 then
                    rated[#rated + 1] = { name = tname, pos = tpos, rating = rating }
                end
            end
        end
    end

    cs.dbg("oca", "%s OCA Sweep: %d enemy airfields rated (creating up to %d tasks)",
        cs.SIDE_NAME[side], #rated, CREATE_OCA_SWEEP_TASK_COUNT)

    -- FOW gate (line 1620): fow >= 0.25 × max → sweep; else → RECON of the airfield.
    apply_fork(rated, {
        count = CREATE_OCA_SWEEP_TASK_COUNT, sector_max = 1,
        fow_threshold = FOW_THRESHOLD_OCA, side = side, label = "OCA-Sweep", log_fn = log_fn, dbg_tag = "oca",
        spawn = function(e) return create_oca_sweep_task(side, e.pos, e.name, log_fn) end,
        recon_obj = function(e) return { kind = "keysite", base = e.name, pos = e.pos } end,
    })
end

-- ── Single-shot spawn (called by reaction.lua for follow-on OCA Sweep) ────────
-- SINGLE-SHOT EXPORT (never-replace list). Backward-compatible signature — the two new args are
-- OPTIONAL; existing generator/no-target callers are unaffected:
--   • no target      → re-run the whole generator scan (unchanged legacy behaviour);
--   • target_name(+pos) → create ONE OCA_SWEEP task ON that recon'd objective. EECH's follow-on sweep
--     (create_reaction_to_recon_task_completed, reaction.c:469-471) passes the recon'd `objective` to
--     create_oca_sweep_task, so the sweep hits the SAME base the recon revealed — NOT a fresh scan
--     that could pick a different base and double-charge the 2-task (CREATE_OCA_SWEEP_TASK_COUNT)
--     generator budget. The reaction call site now passes the objective + its position.
function M.run_oca_sweep(side, log_fn, target_name, target_pos)
    log_fn = log_fn or function() end
    if target_name then
        local tpos = target_pos or S.base_pos[target_name]
        if not tpos then
            cs.dbg("oca", "%s run_oca_sweep DIRECTED SKIP vs %s: no position", cs.SIDE_NAME[side], tostring(target_name))
            return
        end
        cs.dbg("oca", "%s run_oca_sweep: DIRECTED (reaction follow-on) OCA sweep ON %s (reaction.c:469-471)",
            cs.SIDE_NAME[side], target_name)
        local ok, err = pcall(create_oca_sweep_task, side, tpos, target_name, log_fn)
        if not ok then log_fn("run_oca_sweep(directed) error: " .. tostring(err)) end
        return
    end
    cs.dbg("oca", "%s run_oca_sweep: single-shot invocation (generator scan)", cs.SIDE_NAME[side])
    local ok, err = pcall(run_oca_sweep, side, log_fn)
    if not ok then log_fn("run_oca_sweep error: " .. tostring(err)) end
end

function M.schedule_oca_sweep(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    local offset = initial_offset or OFFSET_OCA_SWEP
    cs.dbg("oca", "%s OCA Sweep scheduler REGISTERED offset=%.0fs period=%.0fs", cs.SIDE_NAME[side], offset, PERIOD_OCA_SWEP)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end    -- re-injection guard: cancel superseded closure
        -- Item 6: generators keep running post-victory (EECH fc_msgs.c:163 gates only the win re-award).
        cs.dbg("oca", "%s OCA Sweep FIRE", cs.SIDE_NAME[side])
        local ok, err = pcall(run_oca_sweep, side, log_fn)
        if not ok then log_fn("OCA Sweep error: " .. tostring(err)) end
        return t + PERIOD_OCA_SWEP
    end, nil, timer.getTime() + offset)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. Artillery — create_artillery_strike_tasks (highlevl.c line 2836)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Find own artillery groups (GROUP_FRONTLINE_FLAG_ARTILLERY proxy: DCS Artillery attribute)
-- Find enemy frontline targets (groups + ground_strike keysites) within max weapon range
-- Assign via setTask(engageTargets / engageTargetsInZone)
-- FOW > 0.25 * maximum per target (line 3062)
-- MAX_ARTILLERY_STRIKE_COUNT = 5
local ARTY_DEFAULT_RANGE = 20000  -- metres; proxy for get_local_group_max_weapon_range

local function run_artillery(side, log_fn)
    local enemy = cs.ENEMY[side]

    -- Collect own artillery groups (mirrors GROUP_FRONTLINE_FLAG_ARTILLERY list, gp_dbase.c:805/846).
    -- Belt-and-braces: match the DCS "Artillery" attribute OR the "Arty-" group name the OOB tags them
    -- with (ground_forces.spawn_arty_group) — so a chosen DCS type that lacks the attribute still fires.
    local arty_groups = {}
    local own_grps = coalition.getGroups(side)
    if own_grps then
        for _, grp in ipairs(own_grps) do
            if grp and grp:isExist() then
                local u = grp:getUnit(1)
                if u and u:isExist() then
                    local desc = u:getDesc()
                    local is_art = desc and desc.attributes and desc.attributes["Artillery"]
                    local by_name = grp:getName():match("^Arty")
                    if is_art or by_name then
                        arty_groups[#arty_groups + 1] = grp
                    end
                end
            end
        end
    end
    if #arty_groups == 0 then
        cs.dbg("cas", "%s Artillery: no own artillery groups, skipping", cs.SIDE_NAME[side])
        return
    end

    -- Collect enemy targets: frontline ground groups + enemy bases within range
    local target_positions = {}
    -- Enemy frontline groups (whole standing frontline, not a single column)
    for _, rec in pairs((S.ground_groups and S.ground_groups[enemy]) or {}) do
        if cs.group_is_alive(rec.grp) then
            local u = rec.grp:getUnit(1)
            if u and u:isExist() then
                target_positions[#target_positions + 1] = u:getPosition().p
            end
        end
    end
    -- Enemy artillery batteries (counter-battery: EECH BAI/artillery both target FRONTLINE>1 incl.
    -- ARTILLERY, gp_dbase.c:805). Own artillery counter-fires enemy batteries when in range.
    for _, rec in pairs((S.arty_groups and S.arty_groups[enemy]) or {}) do
        if cs.group_is_alive(rec.grp) then
            local u = rec.grp:getUnit(1)
            if u and u:isExist() then
                target_positions[#target_positions + 1] = u:getPosition().p
            end
        end
    end
    -- Enemy non-airbase installations (ground_strike_target keysites, Cluster G)
    do
        local ok, inst = pcall(require, "installations")
        if ok and inst then
            for _, t in ipairs(inst.strike_targets(side)) do
                target_positions[#target_positions + 1] = t.pos
            end
        end
    end
    -- Enemy bases as keysite targets (ground_strike_target == true proxy: all bases)
    for ename, eowner in pairs(S.base_owner) do
        if eowner == enemy then
            local epos = S.base_pos[ename]
            if epos then target_positions[#target_positions + 1] = epos end
        end
    end

    if #target_positions == 0 then
        cs.dbg("cas", "%s Artillery: %d arty groups but no targets in range, skipping", cs.SIDE_NAME[side], #arty_groups)
        return
    end

    -- Assign artillery to targets (mirrors group_index/target_index loops)
    local assigned = 0
    for _, arty in ipairs(arty_groups) do
        if assigned >= MAX_ARTILLERY_STRIKE_COUNT then break end
        local au = arty:getUnit(1)
        if au and au:isExist() then
            local apos   = au:getPosition().p
            local max_r2 = ARTY_DEFAULT_RANGE * ARTY_DEFAULT_RANGE

            for _, tpos in ipairs(target_positions) do
                if assigned >= MAX_ARTILLERY_STRIKE_COUNT then break end
                local dx = apos.x - tpos.x
                local dz = apos.z - tpos.z
                local d2 = dx*dx + dz*dz

                if d2 < max_r2 then
                    -- FOW check: fow > 0.25 * maximum (line 3062)
                    -- Find nearest enemy base to target pos
                    local fow_ok = false
                    for ename, eowner in pairs(S.base_owner) do
                        if eowner == enemy then
                            local epos = S.base_pos[ename]
                            if epos then
                                local dx2 = tpos.x - epos.x
                                local dz2 = tpos.z - epos.z
                                if dx2*dx2 + dz2*dz2 < 200000*200000 then
                                    if fow_m.get(ename, side) > FOW_THRESHOLD_ART then
                                        fow_ok = true; break
                                    end
                                end
                            end
                        end
                    end

                    if fow_ok then
                        -- mirrors engage_targets_in_area(group, target_pos, 1.0*KILOMETRE, ...)
                        local ctrl = arty:getController()
                        if ctrl then
                            ctrl:setTask({
                                id = "FireAtPoint",
                                params = {
                                    point    = { x = tpos.x, y = tpos.z },
                                    radius   = 1000,    -- 1 km; mirrors 1.0*KILOMETRE in EECH
                                    expendQty = 20,
                                    expendQtyEnabled = true,
                                },
                            })
                            assigned = assigned + 1
                            log_fn(string.format("%s Artillery → (%.0f, %.0f)", cs.SIDE_NAME[side], tpos.x, tpos.z))
                            -- The shot IS the "artillery fire" notification (EECH notify_local_entity
                            -- ARTILLERY_FIRE → create_reaction_to_artillery_fire): the VICTIM side raises
                            -- counter-battery BAI/RECON against THIS battery (reaction.c:703-810).
                            local ok_r, react = pcall(require, "reaction")
                            if ok_r and react and react.on_artillery_fire then
                                pcall(react.on_artillery_fire, cs.ENEMY[side], arty, apos, log_fn)
                            end
                            break  -- each artillery group gets one target
                        end
                    end
                end
            end
        end
    end
    cs.dbg("cas", "%s Artillery: %d groups, %d targets -> %d fire missions assigned", cs.SIDE_NAME[side],
        #arty_groups, #target_positions, assigned)
end

function M.schedule_artillery(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    local offset = initial_offset or OFFSET_ARTY
    cs.dbg("cas", "%s Artillery scheduler REGISTERED offset=%.0fs period=%.0fs", cs.SIDE_NAME[side], offset, PERIOD_ARTY)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end    -- re-injection guard: cancel superseded closure
        -- Item 6: generators keep running post-victory (EECH fc_msgs.c:163 gates only the win re-award).
        local ok, err = pcall(run_artillery, side, log_fn)
        if not ok then log_fn("Artillery error: " .. tostring(err)) end
        return t + PERIOD_ARTY
    end, nil, timer.getTime() + offset)
end

return M
