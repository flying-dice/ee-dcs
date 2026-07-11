-- game_loop.lua
-- Inspired by:
--   aphavoc/source/ai/highlevl/highlevl.c   start_high_level_ai(): registers ALL campaign
--                                            AI functions into the update list with period + offset
--   aphavoc/source/update.c                 add_update_function: staggered periodic scheduler
--   aphavoc/source/update.h                 update_function_data_type: callback, sleep, offset
--   aphavoc/source/entity/special/session/ss_updt.c  session update: elapsed_time tick
--   aphavoc/source/entity/special/force/fc_updt.c    update_server: criteria evaluation every 5s
--
-- Orchestrator only — thin wiring layer, no campaign logic lives here.
-- Mirrors start_high_level_ai() which does nothing but register every task-generation
-- function into the update list; the logic is in each sub-system module.
--
-- Module dependency graph (mirrors EECH entity/AI split):
--   campaign_state  ← SESSION + FORCE data (no dependencies)
--   keysite         ← KEYSITE entity ops (requires campaign_state)
--   imap            ← influence maps (requires campaign_state)
--   fog_of_war      ← FOW decay (requires campaign_state)
--   frontline       ← frontline detection (requires campaign_state)
--   win_condition   ← fc_updt criteria + kill handler (requires campaign_state, keysite)
--   attack_waves    ← highlevl OCA/strike tasks (requires campaign_state, keysite)
--   ground_forces   ← highlevl advance/retreat tasks (requires campaign_state, keysite)
--   regen           ← dead-group regen FIFO (requires campaign_state, supply)
--   keysite_repair  ← ks_updt supply/repair tick (requires campaign_state)
--   cas_bai_sead    ← highlevl CAS/BAI/SEAD/OCA Sweep/Artillery (requires imap, fog_of_war, frontline)
--   troop           ← highlevl T.I. + patrol (requires campaign_state, imap, fog_of_war)
--   transfer        ← highlevl FW/HC transfer (requires campaign_state, imap, supply)
--   reaction        ← reactive AI on task-assign (requires campaign_state, supply)
--   game_loop       ← start_high_level_ai orchestrator (requires all above)

local cs       = require("campaign_state")
local ks       = require("keysite")
local sup      = require("supply")
local wc       = require("win_condition")
local atk      = require("attack_waves")
local gnd      = require("ground_forces")
local ov       = require("map_overlay")
local imap_m   = require("imap")
local fow_m    = require("fog_of_war")
local frontl   = require("frontline")
local regen_m  = require("regen")
local kr_m     = require("keysite_repair")
local cas_m    = require("cas_bai_sead")
local troop_m  = require("troop")
local xfer_m   = require("transfer")
local react_m  = require("reaction")
local inst_m   = require("installations")
-- heli_war is NOT required here: its schedulers were deleted in Cluster H and its remaining exports
-- (build_attack_heli, spawn_escort) are required directly by cas_bai_sead / troop.
local board_m  = require("task_board")
local sf_m     = require("supply_flight")
local pilots_m = require("pilots")
local persist  = require("persist")
local sched    = require("campaign_mode")   -- Item 5: mode-selected scheduler cadence (period + per-side offsets)

local game_loop = {}
game_loop.name    = "game_loop"
game_loop.version = "0.2.0"

local S = cs.S

-- Status and capture-check periods
-- mirrors update_campaign_triggers (every 1s in EECH); we log at human granularity
local STATUS_PERIOD = 2 * 60
local CAPTURE_CHK   = 60

local function info(msg)
    env.info(string.format("[dynamic-mission-test] [game_loop] %s", tostring(msg)))
end

-- ── Admin scheduler ────────────────────────────────────────────────────────────
-- mirrors update_client_server_sector_side_count (1 min) +
--         update_campaign_triggers (1 s) + fc_updt criteria check (5 s)
-- Combined here at coarser granularity since DCS log is the readout.

local function schedule_admin()
    local my_gen = _DMT_GEN
    cs.dbg("loop", "admin scheduler REGISTERED: capture/win offset=90s period=%ds, status offset=%ds period=%ds",
        CAPTURE_CHK, STATUS_PERIOD, STATUS_PERIOD)
    -- Capture poll + win condition (mirrors fc_updt every-5s criteria scan).
    -- INFRASTRUCTURE: keeps running post-victory — captures still happen and wc.check_win is idempotent
    -- (win_condition.lua:118 early-returns once S.game_over is set, mirroring EECH fc_msgs.c:163 which
    -- returns TRUE early on an already-complete session rather than re-awarding). Cluster E.
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end
        ks.try_capture(info)
        wc.check_win(info)
        return t + CAPTURE_CHK
    end, nil, timer.getTime() + 90)

    -- Periodic status log (mirrors EECH campaign map HUD + update_campaign_triggers)
    -- INFRASTRUCTURE: status/strength readout keeps running post-victory (EECH fc_msgs.c:163). Cluster E.
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end
        cs.recalc_strength()
        local elapsed = math.floor((timer.getTime() - S.start_time) / 60)
        local ph      = cs.current_phase()

        -- Phase transition announcement — logged AND shown to players in-game.
        if ph ~= S.phase then
            local prev = S.phase
            S.phase = ph
            info(string.format("Phase → %s | BLUE str=%d RED str=%d",
                ph, S.strength[coalition.side.BLUE], S.strength[coalition.side.RED]))
            trigger.action.outText(string.format(
                "── Campaign phase: %s ──\nBLUE %d%%   RED %d%%",
                string.upper(ph), S.strength[coalition.side.BLUE], S.strength[coalition.side.RED]), 20)
            cs.dbg("loop", "phase transition %s -> %s at T+%dm", tostring(prev), ph, elapsed)
        end

        local parts = {}
        for n, o in pairs(S.base_owner) do
            local h = math.floor((S.base_health[n] or 1) * 100)
            parts[#parts + 1] = n .. "=" .. (cs.SIDE_NAME[o] or "?") .. "(" .. h .. "%)"
        end
        table.sort(parts)

        info(string.format("STATUS T+%dm [%s] BLUE=%d RED=%d | %s",
            elapsed, ph,
            S.strength[coalition.side.BLUE],
            S.strength[coalition.side.RED],
            table.concat(parts, "  ")))

        -- Item 2: per-side kill/loss/task/sortie tally line alongside the strength/ownership readout.
        info(cs.stats_summary_line())

        return t + STATUS_PERIOD
    end, nil, timer.getTime() + STATUS_PERIOD)
end

-- ── Entry point ────────────────────────────────────────────────────────────────
-- mirrors start_high_level_ai(): called once, registers all campaign AI timers.
-- Each sub-system's schedule_* function mirrors add_high_level_ai_function(fn, period, offset).

function game_loop.start()
    info("EECH-inspired campaign game loop v" .. game_loop.version .. " starting")

    S.start_time = timer.getTime()
    S.phase      = "early"

    -- ── Phase 1: State initialisation ─────────────────────────────────────────
    -- Mirrors initialise_order_of_battle + session entity setup.

    -- Keysite registry (keysite entity list → S.base_owner, S.base_pos, S.base_health)
    ks.init_base_state(info)

    -- FARP layer (EECH popread.c FARP keysites): forward heli-only bases ahead of each frontline
    -- airbase. Marks airfields base_kind="airbase" and adds base_kind="farp" forward bases. MUST run
    -- after base discovery and BEFORE supply.init so FARPs get a (heli-only) ledger.
    require("farps").init(info)

    cs.recalc_strength()

    -- Hardware inventory (force_info_reserve_hardware → supply counts)
    sup.init(info)

    -- Influence maps (4 layers, start empty — first update at T+30s)
    imap_m.init()

    -- Fog of war (per-base per-side fog tables, all zero at mission start)
    fow_m.init()

    -- Frontline detection (per-base is_frontline flag)
    frontl.init_and_build()

    -- Regen queues (FIFO per side per type, all empty)
    regen_m.init(info)

    -- Keysite supply/repair state (ammo/fuel 100% at mission start)
    kr_m.init(info)

    -- ── PERSISTENCE RESTORE — DATA phase (WAVE 2, goals/03 P1) ─────────────────
    -- After world discovery + all data-seeding init() (so keys exist to overlay) but BEFORE the ground
    -- OOB spawn and before installations/AD read ownership. Overlays the saved base_*/ledger/production/
    -- regen/fow/pilots/objectives/strength onto the fresh state so the rest of boot sees the restored
    -- campaign. No-op (returns false) unless config.persistence.enabled AND a save exists for the slot.
    -- On a same-process hot re-inject this stays a no-op (default disabled) — current workflows unchanged.
    local restored = persist.restore_data(info)
    if restored then
        -- ownership changed under us → rebuild the frontline now (the 120 s scheduler would otherwise
        -- catch up later); pcall-guarded, purely a freshness optimisation.
        pcall(function() if frontl.recompute then frontl.recompute(info) end end)
        -- F1: re-derive FARP activation against the RESTORED ownership. farps.init ran seed_activation
        -- BEFORE this overlay (against fresh ownership), and the latch only ever sets true — a stale
        -- pre-restore activation would never heal (over-active FARPs polluting the win census after
        -- every server restart). EECH's own boot behaviour is a RECOMPUTE, not a persisted flag:
        -- initialise_keysite_farp_enable re-evaluates every FARP's sector side at campaign setup
        -- (keysite.c:507-568). Reset the latch and re-seed; S.farp_active is deliberately NOT persisted.
        S.farp_active = {}
        pcall(function() require("farps").seed_activation(info) end)
    end

    -- Standing frontline: seed N ground groups per side (mirrors order.c ground registry).
    -- Runs after supply.init (draws from the "vehicle" reserve) and keysite state.
    -- On RESTORE the mobile OOB is respawned from saved summaries (persist.restore_world, below) instead
    -- of a fresh seed — so skip the OOB spawn to avoid a doubled frontline / double reserve consume.
    if not restored then
        gnd.init_oob(info)
    else
        cs.dbg("loop", "restore active: skipping fresh ground OOB seed (mobile OOB respawns from save)")
    end

    -- Non-airbase keysites: depots/radar/fuel installations behind each base (Cluster G).
    inst_m.init(info)

    -- Flesh out keysites with an air-defence garrison (radar SAM + AAA per base): gives SEAD real
    -- targets, contests strikes, feeds the AIR_DEFENCE imap, and drives organic keysite attrition.
    require("base_defenses").init(info)

    -- Pilot/player career substrate (Cluster 6, spec 10). Restore-safe (never clobbers S.pilots).
    -- Kill/birth/death wiring lives inside the EXISTING win_condition + reaction handlers; here we
    -- only init the record store and build the F-10 menu. Fully dormant until player slots exist.
    pilots_m.init(info)

    -- ── PERSISTENCE RESTORE — WORLD phase (WAVE 2) ────────────────────────────
    -- After installations + AD rings + pilots are freshly seeded: overlay saved keysite health/dead
    -- (re-killing saved-dead author statics so the world matches), and respawn the mobile OOB (primary/
    -- artillery/secondary ground groups) from summaries — reserve-neutral (restored ledger already
    -- reflects them). No-op unless restore_data applied a save above.
    if restored then
        persist.restore_world(info)
    end

    info(string.format("Campaign live — BLUE str=%d RED str=%d phase=early",
        S.strength[coalition.side.BLUE], S.strength[coalition.side.RED]))
    local n_bases = 0
    for _ in pairs(S.base_owner) do n_bases = n_bases + 1 end
    cs.dbg("loop", "Phase 1 init complete: %d bases known, generation=%d", n_bases, cs.GENERATION)

    -- ── Phase 2: Event handlers ───────────────────────────────────────────────
    -- Mirrors entity destroy hooks + task-assign notification hooks in EECH.

    -- Register handlers through a global tracker so reset.lua can remove them on the next
    -- injection (world.addEventHandler has no auto-cleanup; untracked handlers would stack).
    _G.__dmt_handlers = _G.__dmt_handlers or {}
    local function add_handler(h)
        world.addEventHandler(h)
        _G.__dmt_handlers[#_G.__dmt_handlers + 1] = h
    end

    add_handler(wc.make_kill_handler(info))        -- Kill → win condition decrement
    add_handler(regen_m.make_dead_handler(info))   -- Dead aircraft → regen queue insert
    add_handler(sup.make_land_handler(info))       -- RTB landing → recycle hardware to reserve
    add_handler(react_m.make_event_handler(info))  -- Offensive spawn → CAP/BARCAP reaction
    cs.dbg("loop", "Phase 2 complete: %d event handlers registered (kill/dead/land/reaction)", #_G.__dmt_handlers)

    -- ── Phase 3: Periodic schedulers ─────────────────────────────────────────
    -- Mirrors start_high_level_ai() registering each function with period + offset.
    -- Order matches EECH highlevl.c lines 246-280 (campaign mode) where applicable.

    -- STARTUP SCHEDULER ROSTER (loop tag): every registration below appends {label, offset} here so
    -- the full set — and any offset<=0 that DCS would silently drop — is visible in ONE grep, rather
    -- than scattered across each subsystem's own dbg tag. This is exactly the blind spot that hid the
    -- BLUE-attack-heli-war bug (schedule_cas offset=0) for so long.
    local sched_roster = {}
    local function roster(label, offset) sched_roster[#sched_roster + 1] = { label, offset } end

    -- Task-board assignment engine (Cluster 4): drains the UNASSIGNED task queue every 3 min
    -- (KEYSITE_TASK_ASSIGN_TIMER, keysite.h:69), matching idle base inventory to queued tasks and
    -- expiring the unassignable (assign.c / ts_updt.c). Registered before the generators so the
    -- board is live when the first tasks are created.
    board_m.schedule(info)

    -- Supply consumption + resupply (sup.schedule_supply mirrors ks_updt supply loop)
    sup.schedule_supply(info)

    -- Keysite repair (mirrors overload_keysite_update_functions, 60 s). This tick also raises the
    -- PHYSICAL supply-flight requests (supply_flight.request) when a keysite drops below threshold.
    kr_m.schedule_repair(info)

    -- Supply-flight delivery detection (supply_flight.check_arrivals): the transport's DROP_OFF
    -- fly-over of a consumer keysite restocks it to 100 (ks_msgs.c:230,238). Short cadence so a fast
    -- transport's pass is never missed. Producer→consumer transport is the EECH create_supply_task path.
    sf_m.schedule_arrivals(info)

    -- Regen dequeue (rg_updt.c update_server, 60 s × REGEN_UPDATE_MEDIUM)
    regen_m.schedule_regen(info)

    -- FOW decay + recon scan (mirrors add_high_level_ai_function(..., 30s, 8s))
    fow_m.schedule_decay(info)

    -- Influence maps (4 staggered layers, 120 s each; mirrors separate imap update registrations)
    imap_m.schedule_update(info)

    -- Frontline rebuild (120 s; mirrors per-tick sector neighbour scan)
    frontl.schedule_update(info)

    -- Dormant-FARP activation (Item 1; 120 s): latch a forward FARP active once its sector turns
    -- friendly — the port's "activation as the front moves" (eech keysite.c:507-568). No-op when
    -- config.C.theatre.farp_activation is false (all FARPs already active).
    require("farps").schedule(info)

    -- Item 5: all per-side offsets now come from campaign_mode.SCHED (mode-selected). The CAMPAIGN
    -- column is byte-identical to the prior inline literals + staggers (verified value-by-value); the
    -- SKIRMISH column is highlevl.c:218-242. `.blue`/`.red` carry the port's per-side stagger.

    -- Keysite (ground) strikes: EECH create_keysite_strike_tasks (highlevl.c:252 campaign / :228 skirmish)
    atk.schedule_keysite_strikes(coalition.side.BLUE, sched.SCHED.keysite_strike.blue, info)
    atk.schedule_keysite_strikes(coalition.side.RED,  sched.SCHED.keysite_strike.red,  info)
    roster("keysite_strike/BLUE", sched.SCHED.keysite_strike.blue); roster("keysite_strike/RED", sched.SCHED.keysite_strike.red)

    -- OCA strikes: EECH create_oca_strike_tasks (highlevl.c:268 campaign / :242 skirmish)
    atk.schedule_oca_strikes(coalition.side.BLUE, sched.SCHED.oca_strike.blue, info)
    atk.schedule_oca_strikes(coalition.side.RED,  sched.SCHED.oca_strike.red,  info)
    roster("oca_strike/BLUE", sched.SCHED.oca_strike.blue); roster("oca_strike/RED", sched.SCHED.oca_strike.red)

    -- Ground advance/retreat: EECH create_advance_and_retreat_tasks (highlevl.c:250 campaign / :224 skirmish)
    gnd.schedule_ground(coalition.side.BLUE, sched.SCHED.ground.blue, info)
    gnd.schedule_ground(coalition.side.RED,  sched.SCHED.ground.red,  info)
    roster("ground/BLUE", sched.SCHED.ground.blue); roster("ground/RED", sched.SCHED.ground.red)

    -- Infantry patrol: EECH create_troop_patrol_tasks (highlevl.c:248 campaign / :230 skirmish)
    troop_m.schedule_patrol(coalition.side.BLUE, sched.SCHED.patrol.blue, info)
    troop_m.schedule_patrol(coalition.side.RED,  sched.SCHED.patrol.red,  info)
    roster("patrol/BLUE", sched.SCHED.patrol.blue); roster("patrol/RED", sched.SCHED.patrol.red)

    -- ── Rotary-wing war (EECH's primary offensive arm) ────────────────────────
    -- heli_war.schedule_anti_armour / schedule_hunter_killer were a PORT INVENTION — EECH has no
    -- anti_armour / hunter_killer task (grep of the C source finds only a formation component,
    -- en_forms.c:177). In EECH the attack-helicopter frontline fight IS CAS + BAI, which are
    -- heli-eligible (ts_dbase.c :511/:329) and launch attack helis from the forward FARPs (task_board
    -- SUIT cas/bai = "heli"; cas_bai_sead builds heli sections). Those two schedulers + their private
    -- helpers were DELETED in Cluster H (2026-07-09); heli_war.lua remains only as the shared
    -- attack-heli / escort BUILDER (build_attack_heli, spawn_escort). No rotary scheduler is registered here.

    -- CAS: EECH create_cas_tasks (highlevl.c:246 campaign / :220 skirmish) — the rotary frontline fight
    -- from FARPs. EECH start_time 0.0 is bumped to blue=5 in campaign_mode (DCS silently drops a timer
    -- scheduled at getTime()+0 — this once suppressed BLUE's whole attack-heli war); red staggered 30.
    cas_m.schedule_cas(coalition.side.BLUE, sched.SCHED.cas.blue, info)
    cas_m.schedule_cas(coalition.side.RED,  sched.SCHED.cas.red,  info)
    roster("cas/BLUE", sched.SCHED.cas.blue); roster("cas/RED", sched.SCHED.cas.red)

    -- Artillery: EECH create_artillery_strike_tasks (highlevl.c:254 campaign / :226 skirmish)
    cas_m.schedule_artillery(coalition.side.BLUE, sched.SCHED.artillery.blue, info)
    cas_m.schedule_artillery(coalition.side.RED,  sched.SCHED.artillery.red,  info)
    roster("artillery/BLUE", sched.SCHED.artillery.blue); roster("artillery/RED", sched.SCHED.artillery.red)

    -- Troop insertion: EECH create_troop_insertion_tasks (highlevl.c:256 campaign / :234 skirmish)
    troop_m.schedule_troop_insertion(coalition.side.BLUE, sched.SCHED.troop_insertion.blue, info)
    troop_m.schedule_troop_insertion(coalition.side.RED,  sched.SCHED.troop_insertion.red,  info)
    roster("troop_insertion/BLUE", sched.SCHED.troop_insertion.blue); roster("troop_insertion/RED", sched.SCHED.troop_insertion.red)

    -- SEAD: EECH create_sead_tasks (highlevl.c:264 campaign / :222 skirmish)
    cas_m.schedule_sead(coalition.side.BLUE, sched.SCHED.sead.blue, info)
    cas_m.schedule_sead(coalition.side.RED,  sched.SCHED.sead.red,  info)
    roster("sead/BLUE", sched.SCHED.sead.blue); roster("sead/RED", sched.SCHED.sead.red)

    -- BAI: EECH create_bai_tasks (highlevl.c:266 campaign / :236 skirmish)
    cas_m.schedule_bai(coalition.side.BLUE, sched.SCHED.bai.blue, info)
    cas_m.schedule_bai(coalition.side.RED,  sched.SCHED.bai.red,  info)
    roster("bai/BLUE", sched.SCHED.bai.blue); roster("bai/RED", sched.SCHED.bai.red)

    -- OCA Sweep: EECH create_oca_sweep_tasks (highlevl.c:258 campaign / :240 skirmish)
    cas_m.schedule_oca_sweep(coalition.side.BLUE, sched.SCHED.oca_sweep.blue, info)
    cas_m.schedule_oca_sweep(coalition.side.RED,  sched.SCHED.oca_sweep.red,  info)
    roster("oca_sweep/BLUE", sched.SCHED.oca_sweep.blue); roster("oca_sweep/RED", sched.SCHED.oca_sweep.red)

    -- Helicopter transfer: EECH create_helicopter_transfer_tasks (highlevl.c:260 campaign / :238 skirmish)
    xfer_m.schedule_hc_transfer(coalition.side.BLUE, sched.SCHED.hc_transfer.blue, info)
    xfer_m.schedule_hc_transfer(coalition.side.RED,  sched.SCHED.hc_transfer.red,  info)
    roster("hc_transfer/BLUE", sched.SCHED.hc_transfer.blue); roster("hc_transfer/RED", sched.SCHED.hc_transfer.red)

    -- Fixed-wing transfer: EECH create_fixed_wing_transfer_tasks (highlevl.c:262 campaign / :232 skirmish)
    xfer_m.schedule_fw_transfer(coalition.side.BLUE, sched.SCHED.fw_transfer.blue, info)
    xfer_m.schedule_fw_transfer(coalition.side.RED,  sched.SCHED.fw_transfer.red,  info)
    roster("fw_transfer/BLUE", sched.SCHED.fw_transfer.blue); roster("fw_transfer/RED", sched.SCHED.fw_transfer.red)

    -- Resource-scenery drain poll: the airfields' built-in fuel/barrel/warehouse scenery has no
    -- S_EVENT_DEAD and can't be re-acquired by name, so its attrition is detected by polling the held
    -- handles' getLife() (register-not-spawn scenery layer, installations.lua). ~25 s cadence.
    inst_m.schedule_scenery_poll(info)

    -- Admin: capture poll + status log (mirrors fc_updt criteria scan + campaign HUD)
    schedule_admin()

    -- Persistence autosave (WAVE 2): periodic background save (mirrors EECH's periodic session repack).
    -- No-op unless config.persistence.enabled; saves also fire on capture (keysite.do_capture) and on
    -- the win declaration (win_condition finish).
    persist.schedule(info)

    -- F-10 map overlay (base ownership, task arrows, frontline)
    ov.schedule_overlay(info)

    -- F-10 radio menu: Campaign > Request Mission / My Record (display-only, spec 10 Cluster 6).
    -- pcall-guarded so a missing missionCommands API degrades silently.
    pilots_m.build_menus(info)

    -- Startup roster dump: one line per scheduler with its offset — an offset<=0 is instantly visible
    -- by grepping "[dmt:loop] scheduler" (this is the fix for the historical silent-drop class of bug).
    for _, entry in ipairs(sched_roster) do
        local label, offset = entry[1], entry[2]
        cs.dbg("loop", "scheduler %-24s offset=%.1fs%s", label, offset, offset <= 0 and " <-- WARNING: DCS drops offset<=0!" or "")
    end
    cs.dbg("loop", "startup roster: %d schedulers registered (see individual subsystem tags for their own period/offset logs too)",
        #sched_roster)
    cs.dbg("loop", "scheduler cadence MODE = %s (highlevl.c %s branch)", sched.mode,
        sched.mode == "skirmish" and ":218-242" or ":246-268")

    info("All campaign schedulers registered — EECH game loop active")
end

return game_loop
