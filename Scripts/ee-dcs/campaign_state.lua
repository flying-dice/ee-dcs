-- campaign_state.lua
-- Inspired by:
--   aphavoc/source/entity/special/session/session.c   SESSION root entity: elapsed_time, start_time
--   aphavoc/source/entity/special/session/ss_updt.c   session periodic update
--   aphavoc/source/entity/special/force/force.h       FORCE per-side: kills, losses, hardware counts
--   aphavoc/source/entity/special/force/fc_funcs.c    add/remove_from_force_info hardware registry
--   aphavoc/source/ai/highlevl/imaps.c                normalise_importance_imaps balance-of-power
--
-- Singleton state table for the entire campaign session.
-- All other modules require this and read/write M.S directly.
-- Mirrors SESSION (root) + FORCE (per-side) entity data.

local M = {}

-- ── Phase thresholds (DISPLAY-ONLY — no behavioural consumer) ────────────────────
-- EECH has NO explicit campaign phases; difficulty emerges from imap/threat state (Cluster F).
-- These elapsed-time buckets USED to drive wave-escort escalation (attack_waves WAVE table) —
-- that invented consumer was removed in Cluster F (escorts are now threat-thresholded per EECH's
-- escort_required model, assign.c:598-627). current_phase() now feeds ONLY the status log
-- (game_loop.lua) and the pilot brief (pilots.lua); the fields are retained for that display and
-- carry NO behavioural weight. Do NOT re-attach a behavioural consumer (EECH has no phases).
M.PHASE_MID  = 15 * 60   -- 15 min → mid  (display label only)
M.PHASE_LATE = 35 * 60   -- 35 min → late (display label only)

-- ── Keysite health thresholds ──────────────────────────────────────────────────
-- mirrors keysite.keysite_usable_state: USABLE / REPAIRING / UNUSABLE.
-- HEALTH_NEUTRALISED is the OPERATIONAL floor for launching/regenerating from a base. In EECH this
-- is EXACTLY the keysite USABLE-state line: a keysite with efficiency < minimum_efficiency is
-- UNUSABLE (keysite.c:827-830) and can neither launch sorties nor regenerate — the same threshold
-- capture/win tests use. It is therefore UNIFIED with MINIMUM_EFFICIENCY (0.3, ks_dbase.c). The
-- previous 0.35 "buffer" had NO EECH source (tuned-by-feel) and was a latent divergence (03-F11) —
-- removed. Kept as a named alias so launch/regen call sites read "neutralised floor" rather than
-- "capture line", but the value is the one EECH usable-state threshold.
M.MINIMUM_EFFICIENCY = 0.3   -- eech ks_dbase.c minimum_efficiency (all keysite types); ks_float.c:285-291
M.HEALTH_NEUTRALISED = M.MINIMUM_EFFICIENCY   -- unified with the EECH USABLE line (keysite.c:827-830)
M.HEALTH_DESTROYED   = 0.0

-- ── Keysite minimum efficiency (EECH capture / usable-state line) ───────────────
-- M.MINIMUM_EFFICIENCY (0.3) is defined with the health thresholds above (unified with
-- HEALTH_NEUTRALISED). Capture semantics: a keysite with efficiency < minimum is UNUSABLE (eech
-- keysite.c:827-830) and is the ONLY state in which troop-insertion (capture) tasks are generated
-- against it (eech highlevl.c:1732). All port keysites are equal-importance airbases.

-- ── Campaign objectives per side ────────────────────────────────────────────────
-- eech ai/highlevl/setup.c:79  NUMBER_OF_CAMPAIGN_OBJECTIVES_PER_SIDE = 5
-- Each side is assigned a fixed set of ENEMY keysites at OOB; the side wins when it OWNS all
-- of them (all port keysites are troop_insertion_targets → "must own", eech fc_msgs.c:180-211).
M.OBJECTIVES_PER_SIDE = 5

-- ── Force strength posture: DELIBERATELY ABSENT ────────────────────────────────
-- EECH has NO strength/attitude-gated "survival mode": FORCE.force_attitude is parsed
-- (parsgen.c:1474) and stored (fc_creat.c:134 default NORMAL, fc_int.c:106/215) but read by ZERO AI
-- code — highlevl.c never inspects force strength/attitude, so create_*_tasks generate offensive
-- tasks regardless of how badly a side is losing (verified E:\eech_source_code, empty grep of
-- highlevl.c for force_percentage/FORCE_ATTITUDE). The old STRENGTH_SURVIVAL(40)/STRENGTH_DEFEAT(5)
-- constants gated strike/TI/ground/heli generation and a bogus 4th win criterion — all invented,
-- all removed in Cluster E. Do NOT reintroduce a posture threshold.

-- ── Keysite attrition: structural death ONLY (no generic kill-proximity bleed) ──────────────────
-- EECH keysite_strength changes ONLY when the keysite's own buildings/structures die (keysite.c:854
-- notify_keysite_structure_under_attack + the destroy path), NOT from nearby unit kills. The port's
-- old generic KILL_RADIUS/KILL_DMG channel (a base bled structure from every air-to-air kill within
-- 8 km) was an INVENTION that double-dipped with the deterministic strike_damage / registered-static-
-- death channels — removed in Cluster G (B4 note). Airbase attrition now comes exclusively from
-- keysite.strike_damage (deterministic per-sortie strike) and registered-asset death; installation
-- attrition from installations.damage + register_static_death.

-- ── Session state (S) ─────────────────────────────────────────────────────────
-- Mirrors SESSION.elapsed_time, SESSION.start_time (session.c)
-- and per-side FORCE.strength, kills, losses (force.h)

-- Generation counter: incremented on each fresh injection so old timer closures
-- can detect they belong to a superseded campaign and self-cancel (return nil).
_DMT_GEN = (_DMT_GEN or 0) + 1
M.GENERATION = _DMT_GEN

-- ── Debug logging channel ───────────────────────────────────────────────────────
-- Toggleable STRUCTURED logging for tracing campaign LOGIC (not just headline events) — decisions,
-- funnels, task lifecycle, spawn success/failure, state transitions. Every module calls
--   cs.dbg("<tag>", "fmt", ...)   → env.info("[dmt:<tag>] ...")
-- Gate with the _DMT_DEBUG global so a production run can silence the firehose without touching call
-- sites:  net.dostring_in('server','_DMT_DEBUG=false')  (or =true to re-enable). Defaults ON (dev
-- campaign). A pcall guards format errors so a malformed dbg() call can never abort a scheduler tick.
-- Tags mirror the module/subsystem: cas, bai, sead, board, heli, strike, oca, troop, recon, regen,
-- reaction, ground, supply, keysite, capture, imap, fow, transfer, win, econ, spawn, loop.
if _DMT_DEBUG == nil then _DMT_DEBUG = true end
function M.dbg(tag, fmt, ...)
    if not _DMT_DEBUG then return end
    local ok, s = pcall(string.format, fmt, ...)
    env.info("[dmt:" .. tostring(tag) .. "] " .. (ok and s or ("FMT-ERR " .. tostring(fmt))))
end

M.S = {
    start_time = 0,      -- timer.getTime() at campaign start (mirrors SESSION.start_time)
    phase      = "early",
    game_over  = false,
    winner     = nil,

    -- mirrors KEYSITE.side, KEYSITE.keysite_strength, KEYSITE.position (keysite.h)
    base_health = {},    -- [name] = 0.0–1.0
    base_owner  = {},    -- [name] = coalition.side.*
    base_pos    = {},    -- [name] = { x=north, z=east }

    -- mirrors FLOAT_TYPE_EFFICIENCY per keysite (eech ks_float.c:260-275):
    --   efficiency = keysite_strength / keysite_maximum_strength   (building-strength model)
    -- Supply (ammo/fuel) is DELIBERATELY EXCLUDED — EECH efficiency is purely the sum of live
    -- building importance over the max (KEYSITE-F3). In the port base_health IS strength/max
    -- (starts 1.0, decremented by structural kill damage), so efficiency == base_health.
    -- Updated every KEYSITE_UPDATE_SLEEP_TIMER (60 s) by keysite_repair.lua.
    -- Used by T.I. scoring, capture roll, recon reaction chain, and transfer scoring.
    base_efficiency = {},   -- [name] = 0.0–1.0

    -- Per-side campaign objective keysites (eech force campaign_objective_root; setup.c:126-289).
    -- [side] = { enemy_base_name, ... } — the ENEMY keysites this side must capture to win.
    objectives = {},

    -- mirrors FORCE.relative_strength (fc_updt.c balance-of-power formula)
    strength = {
        [coalition.side.BLUE] = 100,
        [coalition.side.RED]  = 100,
    },

    -- Standing frontline: a registry of ground groups per side (mirrors EECH ground registry /
    -- armoured divisions — NOT a single column). ground_forces.lua populates this at OOB.
    -- [side] = { [gname] = { grp, target_base, home_base, want } }
    ground_groups = {
        [coalition.side.BLUE] = {},
        [coalition.side.RED]  = {},
    },

    -- Standing SELF-PROPELLED ARTILLERY groups per side (mirrors EECH FRONTLINE_FORCE_ARTILLERY
    -- placement, faction.c:1602-1661 — SP artillery / MLRS groups at artillery nodes supporting the
    -- frontline). Kept SEPARATE from ground_groups so advance_retreat never drives batteries into
    -- contact (EECH artillery holds and fires at range). ground_forces.lua populates this at OOB;
    -- cas_bai_sead.run_artillery finds own shooters (attribute or "Arty-" name) and enemy batteries
    -- (this registry) as counter-fire targets.  [side] = { [gname] = { grp, home_base } }
    arty_groups = {
        [coalition.side.BLUE] = {},
        [coalition.side.RED]  = {},
    },

    -- COUNTER-BATTERY dedup markers (Cluster F / REACT-F13). map firing-battery group_name → expiry
    -- time; the victim side does not raise a 2nd BAI/RECON against a battery already object of one
    -- (mirrors EECH entity_is_object_of_task(group, BAI/RECON) gate, reaction.c:740-744). On S so it
    -- survives across ticks; lazy-init in reaction.lua.
    counter_battery = {},

    -- PER-BASE IDLE INVENTORY LEDGER (Cluster 4 — task-board assignment source).
    -- Replaces the old single per-SIDE reserve pool. DCS cannot keep hundreds of parked AI
    -- aircraft alive (parking/perf), so idle aircraft are a per-base LEDGER (counts by role at
    -- each OWNED base) — a documented proxy for EECH's live aircraft parked at keysites
    -- (force.h:95 force_info_reserve_hardware, but localised to keysites as the task engine's
    -- resident-group source, assign.c LIST_TYPE_KEYSITE_GROUP). Seeded from RESERVE_PER_BASE at
    -- OOB, DECREMENTED on assignment/spawn from the CHOSEN base, re-credited on RTB to the
    -- LANDING base, by production to a producer base, and by regen. The per-SIDE reserve is now
    -- the SUM of base ledgers (supply.reserve_side); consume_side/recycle_side pick a base.
    -- [baseName] = { striker=N, escort=N, heli=N, recon=N, transport=N, vehicle=N }
    base_ledger = {},

    -- LANDING-SLOT / BASING-CAPACITY ARBITRATION (Cluster 5). EECH throttles sortie tempo per
    -- keysite through LANDING entities holding slot counts (reserved/free/total landing sites;
    -- landing.h:102-105) — availability = free - reserved (eech keysite.c:324; spec 07 TASK-F23).
    -- Port proxy (per-SORTIE, not per-airframe): base_inflight[base] = number of sorties currently
    -- airborne that LAUNCHED from `base`; a base at slot capacity (keysite.base_slot_capacity)
    -- is skipped by the assignment gate. group_launch_base[gname] = the launch base of an in-flight
    -- sortie, so its slot is released on RTB-land / death. See keysite.lua (slot API) + task_board.
    -- [baseName] = integer sorties in flight;  [group_name] = launch base name.
    base_inflight     = {},
    group_launch_base = {},

    -- mirrors force_info_current_hardware[side][catagory]: count of live fielded units.
    -- Computed as a live census from coalition.getGroups each recalc_strength (DCS can
    -- enumerate cheaply, so we census rather than maintain a drift-prone ++/-- tally).
    -- WRITE-ONLY DIAGNOSTIC (B3): recalc_strength derives S.strength from the census inline and does
    -- not read force_current back; it is KEPT intentionally as a cheap per-side hardware snapshot for
    -- logging / a future status surface. Harmless. [side] = total alive mobile-unit count
    force_current = {},

    -- mirrors GROUP_MODE_IDLE group count per keysite (transfer scoring proxy).
    -- Updated each transfer tick by counting alive groups near each base.
    -- [baseName] = integer count of alive DCS groups within 5 km
    base_idle_groups = {},

    -- mirrors task entity tracking: which group was assigned what task, targeting where.
    -- Populated on group BIRTH by reaction.lua; consumed on group death.
    -- [group_name] = { task_type="Strike"|"OCA-Sweep"|"Recon"|"BDA", side=N,
    --                  target_base=name_or_nil, born_time=t }
    active_tasks = {},

    -- TASK BOARD (Cluster 4): the UNASSIGNED-task queue that the assignment engine drains.
    -- Mirrors keysite LIST_TYPE_UNASSIGNED_TASK (task.c:561-589) + task_state machine (en_task.h:83).
    -- Each generator create_task(...)s a record here; task_board.tick() matches idle base inventory
    -- to it (assign.c) and physically spawns; records past their unassigned-expiry become FAILED
    -- (ts_updt.c:99-124) — the task-failure path the fresh-spawn port never had. Records: see
    -- task_board.lua. board_failed counts EXPIRE_TIME_REACHED failures for observability.
    board_tasks  = {},
    board_failed = 0,

    -- ── DORMANT-FARP ACTIVATION (Item 1 — eech keysite.c:507-568 initialise_keysite_farp_enable) ─────
    -- EECH FARP keysites are created in_use=FALSE (ks_creat.c:157) and only ACTIVATE (in_use=TRUE,
    -- usable) when their SECTOR's side == the FARP's force side (keysite.c:541-547) — i.e. as the front
    -- reaches them. A not-in_use keysite is excluded from nearest-keysite search (keysite.c:369), the
    -- win-check usable-airbase census (fc_msgs.c:234 requires ALIVE && IN_USE), imap and supply. Port
    -- proxy on bases-as-sectors: a FARP activates when the nearest NON-FARP base to it is friendly.
    -- [farpName] = true once activated (latch — EECH only clears in_use on destroy, ks_dstry.c:325).
    -- Non-FARP bases are ALWAYS active (cs.base_is_active); this table only tracks FARPs.
    farp_active = {},

    -- ── PER-SIDE + PER-TASK STATS (Item 2 — eech force.h:98-99 kills[]/losses[] per FORCE) ───────────
    -- EECH FORCE carries kills[NUM_ENTITY_SUB_TYPE_GROUPS] and losses[NUM_ENTITY_SUB_TYPE_GROUPS],
    -- indexed by the victim's group sub_type (a category), incremented on kill/death
    -- (force.c:307-361 add_mobile_to_force_kills_stats / _losses_stats: kill → killer force, indexed by
    -- victim category; loss → victim force). Port buckets by DCS unit category (air/heli/ground/ship/
    -- structure) as the sub_type proxy. tasks_created/completed/partial/failed mirror the task-board
    -- lifecycle + the per-task completion assessment (task.c). sorties counts registered missions flown.
    -- [side] = { kills={cat->n}, losses={cat->n}, sorties, tasks_created, tasks_completed, tasks_partial, tasks_failed }
    stats = {
        [coalition.side.BLUE] = { kills = {}, losses = {}, sorties = 0,
                                  tasks_created = 0, tasks_completed = 0, tasks_partial = 0, tasks_failed = 0 },
        [coalition.side.RED]  = { kills = {}, losses = {}, sorties = 0,
                                  tasks_created = 0, tasks_completed = 0, tasks_partial = 0, tasks_failed = 0 },
    },

    -- TROOP-INSERTION RESOLVED MARKERS (Cluster C): map group_name → true once an insertion's
    -- capture roll has RESOLVED (won or lost). EECH's TROOP_CAPTURE waypoint event fires once per
    -- task (mb_msgs.c:2260); a repelled heli loitering at its final waypoint must not re-roll every
    -- tick. On S (persistence surface, gap B3).
    pending_captures = {},

    -- IMAP INFLUENCE-MAP LAYER STORE (Wave 1 — moved onto S for the persistence surface, GOAL P2).
    -- imap.lua previously held these as module-local tables reachable only via imap.get(); they now
    -- live on S so the whole influence-map state is enumerable/serialisable with the rest of the
    -- campaign. imap.lua keeps module-local imap_raw/imap_nrm as REFERENCES into these sub-tables — the
    -- get()/update API and every consumer are unchanged. Rebuilt per inject by imap.init() (S itself is
    -- fresh each inject, so this starts empty and is repopulated exactly as before).
    --   raw[layer][side][base_name] = float (unnormalised);  nrm[layer][side][base_name] = 0.0–1.0
    imap = { raw = {}, nrm = {} },
}

M.SIDE_NAME = { [coalition.side.BLUE] = "BLUE", [coalition.side.RED] = "RED" }
M.ENEMY     = { [coalition.side.BLUE] = coalition.side.RED,
                [coalition.side.RED]  = coalition.side.BLUE }

-- ── Sequence IDs ──────────────────────────────────────────────────────────────
-- Starts at 2000 to avoid collision with main.lua's counter (which starts at 0)

local _seq = 2000
function M.next_id()
    _seq = _seq + 1
    return _seq
end

-- ── Task registry ──────────────────────────────────────────────────────────────
-- Mirrors the EECH task entity list: each spawned mission registers itself here at spawn
-- time so the reactive AI (reaction.lua) knows the EXACT objective (target keysite/group),
-- rather than guessing from spawn position. Also drives "task completed" follow-ons.
-- info = { task_type, side (attacker), target_base, target_pos, objective = {kind, base}, born_time }
function M.register_task(gname, info)
    M.S.active_tasks = M.S.active_tasks or {}
    M.S.active_tasks[gname] = info
    -- Sortie counter (Item 2): a registered mission == a flown sortie for its side (force.h stats).
    if info and info.side ~= nil then M.stat_sortie(info.side) end
end

function M.get_task(gname)
    return M.S.active_tasks and M.S.active_tasks[gname]
end

-- Task-end hook (Item 4): map_overlay registers M.task_end_hook = remove_task_arrow so cs.clear_task —
-- the SINGLE chokepoint every task-end path funnels through (reaction LAND/DEAD, troop capture,
-- keysite capture-termination, supply RTB) — reliably reaps the task's map arrow. campaign_state stays
-- dependency-root: map_overlay depends on us, so we call OUT via this slot rather than requiring it.
M.task_end_hook = nil

function M.clear_task(gname)
    if M.S.active_tasks then M.S.active_tasks[gname] = nil end
    if M.task_end_hook then pcall(M.task_end_hook, gname) end
end

-- entity_is_object_of_task proxy: is there an active task of `task_type` against `target_base`
-- for `side`? Used for the EECH dedup guards (don't create a 2nd OCA/TI/strike on one objective).
function M.has_task_against(task_type, target_base, side)
    if not M.S.active_tasks then return false end
    for _, t in pairs(M.S.active_tasks) do
        if t.task_type == task_type and t.target_base == target_base and t.side == side then
            return true
        end
    end
    return false
end

-- ── Phase ──────────────────────────────────────────────────────────────────────
-- Computes a DISPLAY-ONLY elapsed-time label (early/mid/late) from SESSION.elapsed_time.
-- No scheduler or task generator reads it — it feeds only the status log / pilot brief
-- (see the PHASE_MID/PHASE_LATE note above; EECH has no behavioural phases).

function M.current_phase()
    local t = timer.getTime() - M.S.start_time
    if     t >= M.PHASE_LATE then return "late"
    elseif t >= M.PHASE_MID  then return "mid"
    else                           return "early" end
end

-- ── Current-hardware census ────────────────────────────────────────────────────
-- mirrors force_info_current_hardware: count of live fielded mobile units for a side.
-- EECH maintains a ++/-- tally; we enumerate live units directly (DCS lets us, so the
-- count can never drift). Sums aircraft + helicopters + ground vehicles/infantry —
-- the same union of categories fc_updt.c:148-161 sums over (FLOAT_TYPE_FORCE_PERCENTAGE):
--   for loop = ARMED_FIXED_WING .. NUM_FORCE_INFO_CATAGORIES: this_force += current_hardware[loop].
-- Static buildings/keysites are NOT force_info hardware in EECH, so we skip them.
--
-- HUMANS IN THE CENSUS (goal-03 P1): the player's gunship is a member of a force group, so EECH's
-- census walks it like any other member — fc_updt.c:148-161 has NO player exclusion (verified: the
-- sum is over force_info_current_hardware categories, populated by add/remove_from_force_info for
-- every group member regardless of AI/human). The port matches by counting via coalition.getGroups,
-- which INCLUDES client/player groups once slotted — so player gunships already count toward force
-- strength here, exactly as EECH intends. This census is strictly READ-ONLY: it never destroys,
-- recycles, or regenerates a unit (those paths — regen.make_dead_handler, supply.make_land_handler —
-- carry their own explicit getPlayerName guards), so counting players is guardrail-safe.
function M.count_current_hardware(side)
    local n = 0
    local grps = coalition.getGroups(side)
    if grps then
        for _, grp in ipairs(grps) do
            if grp and grp.isExist and grp:isExist() then
                local units = grp:getUnits()
                if units then
                    for _, u in ipairs(units) do
                        if u and u:isExist() and u:getLife() > 1.0 then n = n + 1 end
                    end
                end
            end
        end
    end
    return n
end

-- ── Strength recalculation ─────────────────────────────────────────────────────
-- mirrors fc_updt.c:140-161 balance-of-power exactly:
--   force_percentage[side] = this_force / total_forces
--     this_force   = Σ current_hardware[side]  over all categories
--     total_forces = Σ current_hardware[side] + current_hardware[enemy]
-- Stored as an integer 0..100 (EECH campaign_criteria count = force_percentage*100).
-- Territory (base ownership) and keysite efficiency are SEPARATE campaign criteria,
-- evaluated in win_condition.lua — NOT folded into strength (matches EECH criteria split).
function M.recalc_strength()
    local cur = {}
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        cur[side] = M.count_current_hardware(side)
        M.S.force_current[side] = cur[side]
    end

    local total = cur[coalition.side.BLUE] + cur[coalition.side.RED]
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        if total > 0 then
            M.S.strength[side] = math.floor(cur[side] / total * 100 + 0.5)
        else
            M.S.strength[side] = 50   -- no units fielded on either side → even
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- DORMANT-FARP ACTIVATION GATE (Item 1 — eech keysite.c:507-568 / in_use participation)
-- ═══════════════════════════════════════════════════════════════════════════════
-- base_is_active(name): does the base PARTICIPATE in the campaign (== EECH keysite in_use)? Non-FARP
-- bases (airbase/fob) are always in_use. A FARP is in_use only once activated (S.farp_active), which
-- farps.update latches when its sector becomes friendly (the eech keysite.c:541 sector-side gate).
-- Consulted by the launch-candidate gate (task_board.owned_bases, ≈ nearest-keysite search
-- keysite.c:369) and the win usable-airbase census (win_condition, ≈ fc_msgs.c:234 ALIVE && IN_USE).
function M.base_is_active(name)
    if M.S.base_kind and M.S.base_kind[name] == "farp" then
        return M.S.farp_active[name] == true
    end
    return true   -- airbases / FOBs always participate (only FARPs are gated by in_use)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- PER-SIDE + PER-TASK STATS (Item 2 — eech force.h:98-99 kills[]/losses[]; force.c:307-361)
-- ═══════════════════════════════════════════════════════════════════════════════
M.STAT_CATEGORIES = { "air", "heli", "ground", "ship", "structure", "other" }

-- Bucket a DCS object into a stats category (proxy for EECH group sub_type). pcall-guarded — a kill
-- event target may be a Unit, a StaticObject (structure) or an already-cleaned handle.
function M.unit_category(obj)
    if not obj then return "other" end
    -- Prefer the group category for live units (airplane / helicopter / ground / ship).
    local okg, grp = pcall(function() return obj.getGroup and obj:getGroup() end)
    if okg and grp then
        local okc, gc = pcall(function() return grp:getCategory() end)
        if okc then
            if     gc == Group.Category.AIRPLANE   then return "air"
            elseif gc == Group.Category.HELICOPTER then return "heli"
            elseif gc == Group.Category.GROUND     then return "ground"
            elseif gc == Group.Category.SHIP       then return "ship" end
        end
    end
    -- No group (static/scenery) → attributes, then STATIC category, then "structure"/"other".
    local okd, desc = pcall(function() return obj.getDesc and obj:getDesc() end)
    if okd and type(desc) == "table" and type(desc.attributes) == "table" then
        local a = desc.attributes
        if     a["Helicopters"] then return "heli"
        elseif a["Air"] or a["Planes"] then return "air"
        elseif a["Ships"] then return "ship"
        elseif a["Ground Units"] or a["Vehicles"] then return "ground"
        elseif a["Buildings"] or a["Fortifications"] then return "structure" end
    end
    local okoc, ocat = pcall(function() return obj.getCategory and obj:getCategory() end)
    if okoc and Object and Object.Category and ocat == Object.Category.STATIC then return "structure" end
    return "other"
end

-- kill → killer force's kills[victim_category]++, victim force's losses[victim_category]++
-- (force.c:307-331 credits the killer force indexed by the victim's category; :337-361 the loss).
function M.stat_kill(killer_side, victim_side, category)
    category = category or "other"
    local st = M.S.stats
    if killer_side and st[killer_side] then
        st[killer_side].kills[category] = (st[killer_side].kills[category] or 0) + 1
    end
    if victim_side and st[victim_side] then
        st[victim_side].losses[category] = (st[victim_side].losses[category] or 0) + 1
    end
end

function M.stat_sortie(side)
    local st = M.S.stats and M.S.stats[side]
    if st then st.sorties = (st.sorties or 0) + 1 end
end

function M.stat_task_created(side)
    local st = M.S.stats and M.S.stats[side]
    if st then st.tasks_created = (st.tasks_created or 0) + 1 end
end

-- result ∈ "success" | "partial" | "failure" — the three EECH task_completed outcomes (task.c:496-501).
function M.stat_task_result(side, result)
    local st = M.S.stats and M.S.stats[side]
    if not st then return end
    if     result == "failure" then st.tasks_failed    = (st.tasks_failed    or 0) + 1
    elseif result == "partial" then st.tasks_partial   = (st.tasks_partial   or 0) + 1
    elseif result == "success" then st.tasks_completed = (st.tasks_completed or 0) + 1 end
end

local function _stat_total(t) local n = 0; for _, v in pairs(t) do n = n + v end; return n end

-- One-line summary for the 2-min STATUS log (game_loop).
function M.stats_summary_line()
    local st = M.S.stats
    local b, r = st[coalition.side.BLUE], st[coalition.side.RED]
    return string.format("STATS kills B=%d R=%d | losses B=%d R=%d | tasks(ok/part/fail) B=%d/%d/%d R=%d/%d/%d | sorties B=%d R=%d",
        _stat_total(b.kills), _stat_total(r.kills), _stat_total(b.losses), _stat_total(r.losses),
        b.tasks_completed, b.tasks_partial, b.tasks_failed,
        r.tasks_completed, r.tasks_partial, r.tasks_failed, b.sorties, r.sorties)
end

-- Multi-line per-side breakdown for the F-10 "Campaign Stats" menu entry (display text).
function M.stats_text()
    local st = M.S.stats
    local function bycat(t)
        local parts = {}
        for _, c in ipairs(M.STAT_CATEGORIES) do
            if (t[c] or 0) > 0 then parts[#parts + 1] = c .. ":" .. t[c] end
        end
        return (#parts > 0) and table.concat(parts, " ") or "none"
    end
    local function block(side)
        local s = st[side]
        return string.format("%s\n  kills %d (%s)\n  losses %d (%s)\n  sorties %d\n  tasks: created %d, done %d, partial %d, failed %d",
            M.SIDE_NAME[side], _stat_total(s.kills), bycat(s.kills), _stat_total(s.losses), bycat(s.losses),
            s.sorties, s.tasks_created, s.tasks_completed, s.tasks_partial, s.tasks_failed)
    end
    return "=== CAMPAIGN STATS ===\n" .. block(coalition.side.BLUE) .. "\n" .. block(coalition.side.RED)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- TASK COMPLETION ASSESSMENT (Item 3 — eech task.c:110-502 get task_completed rating)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Faithful port of the per-task-type completion rating (task.c switch, :150-490). `terminated`:
--   "route_complete" — the mission ended cleanly (RTB/landed) == EECH TASK_TERMINATED_WAYPOINT_ROUTE_
--                      COMPLETE / OBJECTIVE_MESSAGE / STOP_TIME_REACHED (a successful terminator).
--   "terminated"     — the group was destroyed before completing == a failure terminator.
-- Returns (result, rating): result ∈ "success"|"partial"|"failure", rating 0..1 (task.c FLOAT_TYPE_RATING).
-- NOTE ON THRESHOLDS: EECH reads task_pass_percentage_success/partial from task_database (task.c:138-140),
-- which is WUT WARZONE DATA, not a constant in the C tree — so no citable engine default exists. For the
-- efficiency-based GROUND_STRIKE rating we use documented proxy thresholds (SUCCESS 0.25 / PARTIAL 0.10):
-- the port's per-sortie keysite damage is deterministic (attack_waves KEYSITE_STRIKE_DMG), so a single
-- arriving strike drops efficiency by ~that fraction — success when a meaningful chunk fell. Every other
-- registered port task type follows the EECH structural rule (route-complete → success, else failure)
-- which needs no threshold. A strike arriving after the base was already captured/repaired scores by the
-- SAME rule (unusable/below-min → success rating 1.0; no further drop → failure) — faithful, not trivial.
function M.assess_task(task, terminated)
    local ttype       = task and task.task_type
    local success_end = (terminated == "route_complete")
    if ttype == "ground_strike" then
        -- eech ENTITY_SUB_TYPE_TASK_GROUND_STRIKE (task.c:347-427): efficiency before/after vs 0.8*min.
        local base    = task.target_base
        local min_eff = M.MINIMUM_EFFICIENCY * 0.8   -- task.c:364 (stop repairing-one-structure gaming)
        -- efficiency source of truth: airbase → base_health; installation → keysites[name].health.
        local eff_after = base and (M.S.base_health[base]
            or (M.S.keysites and M.S.keysites[base] and M.S.keysites[base].health) or 1.0) or 1.0
        if base and ((not M.base_is_active(base)) or eff_after < min_eff) then
            return "success", 1.0                     -- task.c:366-377 not-in-use / below-min → success
        end
        local rating = (task.eff_before or 1.0) - eff_after   -- task.c:384
        if rating < 0 then rating = 0 elseif rating > 1 then rating = 1 end
        local SUCCESS_THR, PARTIAL_THR = 0.25, 0.10   -- documented proxies (task_pass_percentage is WUT data)
        if     rating >= SUCCESS_THR then return "success", rating   -- task.c:388-391
        elseif rating >= PARTIAL_THR then return "partial", rating   -- task.c:392-395
        elseif success_end            then return "partial", rating   -- task.c:410-416 route-complete → partial
        else                               return "failure", rating end -- task.c:418-424
    elseif ttype == "recon" or ttype == "bda" then
        -- eech BDA/RECON (task.c:432-456): success iff the objective message fired (target reached).
        if success_end then return "success", 1.0 else return "failure", 0.0 end
    else
        -- oca_strike / oca_sweep / troop_patrol / cap / barcap / transfer / troop_insertion etc.
        -- (task.c:153-204 route/stop-time group + :461-472 route-complete group): success on a clean
        -- mission end, failure if terminated early.
        if success_end then return "success", 1.0 else return "failure", 0.0 end
    end
end

-- ── Shared math helpers ────────────────────────────────────────────────────────

-- DCS world: x=north, z=east.  Waypoint/unit position: x=north, y=east.
function M.wp_xy(world_pos)
    return world_pos.x, world_pos.z
end

function M.dist2d(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return math.sqrt(dx * dx + dz * dz)
end

-- Heading in radians toward (bx,bz) from (ax,az)
function M.heading_to(ax, az, bx, bz)
    return math.atan2(bz - az, bx - ax)
end

function M.group_is_alive(g)
    if not g then return false end
    if not g:isExist() then return false end
    local units = g:getUnits()
    if not units then return false end
    for _, u in ipairs(units) do
        if u and u:isExist() then return true end
    end
    return false
end

-- ── Land-snap: keep COMPUTED ground/static placements out of the water ───────────────────────────
-- DCS coastal keysites (Batumi!) drop ring / scatter / rear-offset positions into the sea, where
-- ground units and statics fail to spawn or strand on the shoreline. snap_land nudges a computed
-- placement point to the nearest LAND before it feeds addGroup / addStaticObject / a ground route.
-- NOT an EECH port: EECH keysites are authored terrain 3D-object clusters (popread.c) so its placement
-- never lands in water — this is a DCS-side placement-safety proxy with no EECH constant to cite.
-- Applied ONLY to COMPUTED ground/static offsets (rings, scatter, rear standoffs, template grids),
-- NEVER to authored zone/base centres, aircraft parking, or air routes.
--
-- CONTRACT (analyzer-safe by construction — the historical snap failure was the static analyzer, which
-- does NOT narrow multiple returns / and-or guards): PURE, deterministic, bounded. ALWAYS returns a
-- TABLE {x=,z=} — never nil, never a bare return — so callers read .x/.z with zero nil-narrowing
-- (single-value-per-variable style throughout). Every land.* touch is pcall-guarded. Bearings are
-- DETERMINISTIC (no random). Bounded: 5 radii x 8 bearings = 40 probes maximum, then fallback.
-- DCS land.getSurfaceType enum: LAND=1, SHALLOW_WATER=2, WATER=3, ROAD=4, RUNWAY=5 — LAND/ROAD/RUNWAY
-- are placeable; the two water types are not.
local SNAP_RADII = { 200, 500, 1000, 2000, 4000 }   -- spiral search radii (m), inner → outer

-- pcall-guarded surface probe → a numeric SurfaceType, or nil if the land API threw / is unavailable.
local function surface_at(x, z)
    local ok, st = pcall(land.getSurfaceType, { x = x, y = z })
    if ok and type(st) == "number" then return st end
    return nil
end

-- A placeable (dry) surface: LAND(1) / ROAD(4) / RUNWAY(5). Water(2/3), and a nil probe, are NOT dry.
local function is_dry(st)
    return st == 1 or st == 4 or st == 5
end

-- snap_land(x, z, fx, fz) → { x = SAFE, z = SAFE }, guaranteed non-nil.
--   dry at (x,z)                 → returned as-is (NO log — the common land case, avoid spam).
--   water/shallow at (x,z)       → spiral search (SNAP_RADII x 8 deterministic 45° bearings); the
--                                  FIRST dry candidate wins (inner radii first → smallest nudge).
--   nothing dry found / API dead → fallback (fx,fz): the keysite / base centre the caller passes
--                                  (airbases are always land; authored zone centres assumed on land).
--                                  Returned even if the fallback is itself wet (never loops forever) —
--                                  a warning is logged so a genuinely bad authored centre is visible.
-- Exactly ONE dbg line is emitted, and only when a point actually MOVED (spiral hit) or no land was
-- found — the common as-is case is silent.
function M.snap_land(x, z, fx, fz)
    local bx, bz = fx or x, fz or z            -- fallback defaults to the input point when not supplied
    local st = surface_at(x, z)
    if is_dry(st) then return { x = x, z = z } end   -- already on land — return as-is, no log
    for ri = 1, #SNAP_RADII do
        local r = SNAP_RADII[ri]
        for b = 0, 7 do
            local ang = b * (math.pi / 4)      -- deterministic 45° steps (8 bearings, fixed order)
            local px = x + math.cos(ang) * r
            local pz = z + math.sin(ang) * r
            if is_dry(surface_at(px, pz)) then
                M.dbg("snap", "moved (%.0f,%.0f) surf=%s -> land (%.0f,%.0f) r=%dm",
                    x, z, tostring(st), px, pz, r)
                return { x = px, z = pz }
            end
        end
    end
    M.dbg("snap", "NO land within %dm of (%.0f,%.0f) surf=%s -> fallback (%.0f,%.0f)",
        SNAP_RADII[#SNAP_RADII], x, z, tostring(st), bx, bz)
    return { x = bx, z = bz }
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- ESCORT MODEL — threat-based, mirroring EECH escort_required (Cluster F)
-- ═══════════════════════════════════════════════════════════════════════════════
-- On task assignment EECH assesses route difficulty and creates an escort iff
--   difficulty >= task_database[type].escort_required_threshold           (assign.c:598-627)
-- with a CRITICAL escort at difficulty >= ESCORT_CRITICAL (ts_dbase.h:156).
-- Route difficulty (assess_task_difficulty → assess_task_sector_difficulty, task.c:880-909):
--   walk the leg's sectors; +1 air_threat per sector with enemy S-A defence,
--   +1 enemy_sector per sector not owned by `side`; then
--   difficulty = min(air_threats >> 1, 5) + min(enemy_sectors >> 1, 5).
-- Port proxy: bases are the sector grid. Sample the launch→target leg; each sample's NEAREST base
-- is its sector. air_threat if IMAP_AIR_DEFENCE[side] (= enemy AA coverage) > 0 there; enemy_sector
-- if the base is not owned by `side`. The C's >>1 halving is NOT applied (coarse-grid calibration
-- — see the note inside route_difficulty); the caps of 5 are kept.
M.ESCORT_CRITICAL = 6   -- ts_dbase.h:156 (#define ESCORT_CRITICAL 6)

-- Per-task escort thresholds. NOTE: the shipped ts_dbase.c defaults are ALL ESCORT_NEVER (=15,
-- ts_dbase.h:154) — the operative per-type thresholds are WARZONE DATA (parsed by
-- wutcfg.c:1590 escort_required_threshold; assign.c reads task_database[type].escort_required_threshold).
-- No C constant exists, so these are the researched warzone values (gap analysis 07-F15): a strike
-- (ground/OCA) and troop-insertion escort at difficulty >= 3, SEAD at >= 5. Absent from this table =
-- ESCORT_NEVER (CAS/BAI are rotary attack-heli sections, never fixed-wing-escorted). Designer data.
M.ESCORT_THRESHOLD = {
    ground_strike   = 3,
    oca_strike      = 3,
    sead            = 5,
    troop_insertion = 3,
    supply          = 6,   -- ts_dbase.c:1406 TASK_SUPPLY Escort Required Threshold = 6 (== ESCORT_CRITICAL).
                           -- In practice INERT: supply routes run over own REAR area (launch→producer→
                           -- consumer are all friendly keysites), so route_difficulty ≈ 0 << 6 and no
                           -- escort is created — faithful to EECH, whose rear resupply legs cross no
                           -- enemy sectors either. Wired for fidelity; fires only if the front overruns
                           -- the supply corridor.
}

local ESCORT_SECTOR_STEP = 25000   -- m between leg samples (sector-walk proxy; base spacing scale)

-- route_difficulty(side, from_pos, to_pos) → difficulty (0..10), air_threats, enemy_sectors.
-- Faithful port of assess_task_difficulty (task.c:880-909) onto bases-as-sectors.
function M.route_difficulty(side, from_pos, to_pos)
    if not from_pos or not to_pos then return 0, 0, 0 end
    local imap = require("imap")   -- deferred require: avoids the imap→campaign_state load cycle
    local dx, dz = to_pos.x - from_pos.x, to_pos.z - from_pos.z
    local len = math.sqrt(dx * dx + dz * dz)
    local n = math.max(1, math.floor(len / ESCORT_SECTOR_STEP))
    local seen, air_threats, enemy_sectors = {}, 0, 0
    for i = 0, n do
        local t  = i / n
        local px = from_pos.x + dx * t
        local pz = from_pos.z + dz * t
        -- nearest base to the sample = its sector (mirrors get_x/z_sector of a route node, task.c:876)
        local best, best_d2 = nil, math.huge
        for name, bpos in pairs(M.S.base_pos) do
            if M.S.base_owner[name] then
                local ex, ez = px - bpos.x, pz - bpos.z
                local d2 = ex * ex + ez * ez
                if d2 < best_d2 then best_d2 = d2; best = name end
            end
        end
        if best and not seen[best] then
            seen[best] = true
            local bpos = M.S.base_pos[best]
            -- +1 air_threat per sector with enemy surface-to-air defence (task.c:930-935)
            if imap.get(side, imap.AIR_DEFENCE, bpos) > 0.0 then air_threats = air_threats + 1 end
            -- +1 enemy_sector per sector whose side != this side (task.c:937-939)
            if M.S.base_owner[best] ~= side then enemy_sectors = enemy_sectors + 1 end
        end
    end
    -- GRID-COARSENESS CALIBRATION: EECH's >>1 halving (task.c:890 `min((air_threats >> 1), 5)`,
    -- :901 `min((enemy_sectors >> 1), 5)`) is calibrated to its FINE ~4 km sector grid, where a
    -- strike leg crosses tens of sectors. The port's bases-as-sectors grid is ~25-100 km coarse —
    -- ONE base-sector spans many EECH sectors — so a typical leg touches only 2-5 base-sectors and
    -- halving crushes the counts to 0-1, below every threshold (escorts would silently never fire).
    -- Faithful proxy: count each coarse base-sector at full weight, keeping the C's caps of 5.
    -- Sanity: a 60 km leg over 2 defended enemy bases → difficulty 4 (strike threshold 3 met);
    -- deep multi-base legs reach the SEAD threshold 5; CRITICAL 6 stays rare.
    local air = math.min(air_threats, 5)     -- cap 5 (task.c:890); no >>1 on the coarse grid (see above)
    local ens = math.min(enemy_sectors, 5)   -- cap 5 (task.c:901); no >>1 on the coarse grid (see above)
    return air + ens, air_threats, enemy_sectors
end

-- escort_count(task_type, side, from_pos, to_pos, log_fn) → number of escorts to create (0/1/2).
-- 0 below threshold; 1 at/above threshold; 2 (CRITICAL) at difficulty >= ESCORT_CRITICAL.
-- PROXY NOTE: in EECH the CRITICAL flag (assign.c:619, threat >= ESCORT_CRITICAL) marks the escort
-- TASK critical → higher assignment PRIORITY (×2 sort), not a larger escort. The port spawns escorts
-- directly (no priority queue for the secondary consume), so criticality has no priority meaning here;
-- the closest observable analog is a heavier (2-ship) escort on a critical-threat leg. Documented proxy.
-- Logs difficulty-vs-threshold at the decision point (Cluster F dbg requirement).
function M.escort_count(task_type, side, from_pos, to_pos, log_fn)
    local thr = M.ESCORT_THRESHOLD[task_type]
    if not thr then return 0 end            -- ESCORT_NEVER task type
    local diff = M.route_difficulty(side, from_pos, to_pos)
    local want = (diff >= thr) and ((diff >= M.ESCORT_CRITICAL) and 2 or 1) or 0
    M.dbg("escort", "%s %s escort: route difficulty=%d vs threshold=%d -> %d escort(s)%s",
        M.SIDE_NAME[side] or "?", task_type, diff, thr, want,
        (diff >= M.ESCORT_CRITICAL) and " (CRITICAL)" or "")
    return want
end

return M
