-- troop.lua
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c
--
-- create_troop_insertion_tasks() line 1660
--   Period: 2.0*ONE_MINUTE (skirmish line 234) / 2.0*ONE_MINUTE (campaign line 256) → SAME both modes
--   Offset: 60 s (skirmish) / 1.0*ONE_MINUTE=60 s (campaign)
--   Targets: enemy keysites where keysite_database[type].troop_insertion_target==true
--            AND efficiency < minimum_efficiency
--   Score: (1-airdef)*1 + base_dist*3 + (1-efficiency)*3 + sector_ratio*2; max=9.0
--   Limits: CREATE_TROOP_INSERTION_TASK_COUNT=2 (line 97), MIN_TASK_CREATION_RATIO=0.75
--   FOW: fow >= 0.20 * maximum (line 1819: if fow < 0.20 → create recon instead)
--   NOTE: commented-out "low enemy importance" term not included (line source: // rating += ...)
--
-- create_troop_patrol_tasks() line 2735
--   Period: 10.0*ONE_MINUTE (skirmish line 230) / 5.0*ONE_MINUTE (campaign line 248)
--   Offset: 5 s (both modes)
--   Targets: own FARP, military base, airbase keysites
--   Limit: 1 patrol group per keysite (groups_limit=1 line 2775)
--   Group: 4 infantry units (FORMATION_COMPONENT_INFANTRY, count=4, line 2812)
--   Spawn radius: 300 + frand1()*50 metres from keysite (line 2805-2808)
--   Capture mechanic: patrol task → guard area; if enemy keysite switches → reaction chain
--
-- Capture-on-ARRIVAL (eech mb_msgs.c:2260-2325, response_to_waypoint_troop_capture_reached):
--   EECH fires the capture roll when the insertion group physically REACHES the TROOP_CAPTURE
--   waypoint at the destination keysite — NOT at dispatch, and with NO offload delay. The port
--   mirrors this 1:1: check_landing_helis detects the "Insert-*" heli arriving within
--   CAPTURE_RADIUS of ITS OWN registered target_base (never any other base the flight line passes)
--   and rolls IMMEDIATELY — members = surviving units, losses = units lost en route (eech reads the
--   GROUP's INT_TYPE_MEMBER_COUNT / INT_TYPE_LOSSES at 2293-2295), against the keysite's CURRENT
--   efficiency (FLOAT_TYPE_EFFICIENCY read at the event, 2283) — a base repaired above minimum
--   REPELS. A transport shot down en route never reaches the waypoint → no roll (eech: task
--   terminates on group death), and the DEAD handler clears the task + slot. On a won roll
--   keysite.do_capture applies side flip + instant repair + regen reseed + win re-check
--   (eech capture_keysite, keysite.c:1289-1518).
--
-- EECH constants referenced:
--   CREATE_TROOP_INSERTION_TASK_COUNT = 2 (highlevl.c line 97)
--   MIN_TASK_CREATION_RATIO           = 0.75 (highlevl.c line 90)
--   MAX_HIGHLEVEL_TARGET_CHECKS       = 160 (highlevl.c line 84)

local cs      = require("campaign_state")
local croute  = require("croute")
local imap_m  = require("imap")
local fow_m   = require("fog_of_war")
local frontl  = require("frontline")
local keysite = require("keysite")
local board   = require("task_board")
local config  = require("config")
local S       = cs.S
local M       = {}

-- ── EECH constants ─────────────────────────────────────────────────────────────
local CREATE_TROOP_INSERTION_TASK_COUNT = 2      -- highlevl.c line 97
local MIN_TASK_CREATION_RATIO           = 0.75   -- highlevl.c line 90
local MAX_HIGHLEVEL_TARGET_CHECKS       = 160    -- highlevl.c line 84

-- ── EECH FOW threshold ─────────────────────────────────────────────────────────
-- line 1819: if fow < 0.20 * maximum → create recon; else proceed with T.I.
-- So T.I. requires fow >= 0.20 (matches fog_of_war.THRESHOLD_TROOP)
local FOW_THRESHOLD_TI = 0.20

-- ── EECH minimum_efficiency ────────────────────────────────────────────────────
-- eech ks_dbase.c: minimum_efficiency = 0.3 for ALL keysite types (spec 03 §2.3).
-- Troop-insertion (capture) tasks are generated ONLY against enemy keysites whose
-- efficiency < minimum_efficiency (eech highlevl.c:1724-1732). Shared constant in campaign_state.
local MINIMUM_EFFICIENCY = cs.MINIMUM_EFFICIENCY   -- 0.3

-- Capture-roll troop inputs (eech mb_msgs.c:2293-2297): the roll multiplies the efficiency term by
-- member_count / (member_count + losses), read from the INSERTION GROUP (NOT the keysite garrison) —
-- member_count = INT_TYPE_MEMBER_COUNT (troops still alive at the waypoint), losses = INT_TYPE_LOSSES
-- (troops killed en route). The port maps these to the DCS transport group's live census at arrival:
--   members = grp:getSize()  (surviving units), losses = grp:getInitialSize() - grp:getSize().
-- EECH inserts a multi-member troop division; the port stages a single transport heli, so in practice
-- members=1/losses=0 (an insertion that loses units is shot down entirely → no capture attempt at all,
-- mb_msgs path never runs). The wiring is faithful regardless of group size. Fallback if the group is
-- gone at resolution: the 4-man infantry component (eech highlevl.c:2812).
local TROOP_MEMBER_FALLBACK = 4

-- ── Periods (from add_high_level_ai_function; Item 5: mode-selected via campaign_mode.lua) ────────
local mode           = require("campaign_mode")
local PERIOD_TI      = mode.SCHED.troop_insertion.period  -- :256 2min campaign / :234 2min skirmish
local OFFSET_TI      = mode.SCHED.troop_insertion.blue    -- :256 campaign 1.0*ONE_MINUTE (fallback offset)
local PERIOD_PATROL  = mode.SCHED.patrol.period           -- :248 5min campaign / :230 10min skirmish
local OFFSET_PATROL  = mode.SCHED.patrol.blue             -- :248 offset 5 s (fallback offset)

-- ── Patrol group radius (line 2805-2808) ──────────────────────────────────────
-- pos.x = keysite_pos.x + cos(angle) * (300 + frand1()*50)
-- pos.z = keysite_pos.z + sin(angle) * (300 + frand1()*50)
-- frand1() → random float 0–1; the port draws PATROL_BASE_RADIUS + math.random()*PATROL_RADIUS_JITTER (300 + rand*50).
local PATROL_BASE_RADIUS = 300   -- metres (EECH: 300 + frand1()*50)
local PATROL_RADIUS_JITTER = 50  -- metres (frand1()*50)

-- ── Heli AC types (hoisted to config transport_heli; T.I. uses heli category) ────────────────────
local AC_HELI = {}
-- Ground infantry type for patrol (config types.ground.infantry; proxy for FORMATION_COMPONENT_INFANTRY)
local INFANTRY_TYPE = {}
for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
    AC_HELI[side]      = { country = config.C.countries[side], heli_type = config.C.types.aircraft[side].transport_heli }
    INFANTRY_TYPE[side] = { country = config.C.countries[side], unit = config.C.types.ground.infantry[side] }
end

-- ── Sector ratio proxy (same as in cas_bai_sead.lua) ─────────────────────────
local SECTOR_RATIO_RADIUS = 200000

local function sector_ratio(pos, side)
    if not pos then return 0.0 end
    local r2 = SECTOR_RATIO_RADIUS * SECTOR_RATIO_RADIUS
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

local function sort_targets(list)
    table.sort(list, function(a, b) return a.rating > b.rating end)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Troop insertion (create_troop_insertion_tasks, line 1660)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Capture mechanic: when the Insert- helicopter reaches ITS designated target keysite (proximity
-- to the registered task's target_base only), the capture roll fires IMMEDIATELY — EECH's
-- response_to_waypoint_troop_capture_reached reads eff/members/losses and rolls right at the
-- waypoint event (mb_msgs.c:2283-2305); there is no offload delay in the C.
local CAPTURE_RADIUS         = 8000      -- metres; heli captures from STAND-OFF (doesn't overfly the
                                         -- base's SAM/AAA — the troops air-assault the last stretch).
                                         -- This proximity IS the TROOP_CAPTURE-waypoint-reached trigger
                                         -- (eech mb_msgs.c:2260 response_to_waypoint_troop_capture_reached).
local INSERT_PREFIX          = "Insert"

-- Safety-net TTL for the dedup task registration of an insertion that neither arrives (opens a capture
-- window, which clears the task on resolution) nor dies (DEAD handler clears it): after this it is
-- force-cleared so a stuck heli can't hold the has_task_against dedup guard forever. Anchored to the
-- board's troop_insertion unassigned-expire window (task_board.lua:78, 45 min) — EECH would have
-- expired the task by then regardless (ts_updt.c UNASSIGNED expire_timer).
local INSERT_TASK_TTL        = 45 * 60

-- S.pending_captures (campaign_state): map group_name → true for insertions whose capture roll has
-- RESOLVED (won or lost). A repelled heli loiters at its final waypoint, so without this marker it
-- would re-roll on every 120 s tick — EECH's waypoint event fires exactly once per task
-- (mb_msgs.c:2260). Lazy-init defends against a partial/older S.
local function resolved_inserts()
    S.pending_captures = S.pending_captures or {}
    return S.pending_captures
end

-- response_to_waypoint_troop_capture_reached (mb_msgs.c:2260-2325), ported 1:1:
-- the roll fires the moment the insertion group reaches ITS OWN designated keysite — the
-- registered task's target_base, never any other base the flight line happens to pass
-- (EECH's event carries the task's destination keysite; scanning all enemy bases let a single
-- overflight capture non-targeted bases — adversarial-review CRITICAL fix).
local function check_landing_helis(side, log_fn)
    local grps = coalition.getGroups(side)
    if not grps then return end
    local done = resolved_inserts()
    for _, grp in ipairs(grps) do
        if grp and grp:isExist() then
            local gname = grp:getName()
            local task  = cs.get_task(gname)
            -- Eligible insertion sorties: the campaign's own "Insert-" groups, OR (F4a) a PLAYER group
            -- that bound a troop_insertion board task (task_board.assign_to_player registers it with
            -- player=true) — a human-flown insertion fires the same TROOP_CAPTURE waypoint event as an
            -- AI one (eech mb_msgs.c:2260 keys off the TASK, not the crew). Read-only on the player
            -- unit throughout (position/size sampling only — guardrail).
            local is_insert    = gname:match("^" .. INSERT_PREFIX) ~= nil
            local is_player_ti = task ~= nil and task.player == true and task.task_type == "troop_insertion"
            local tbase = task and task.target_base
            if (is_insert or is_player_ti) and not done[gname] and tbase and S.base_owner[tbase] ~= side then
                local u = grp:getUnit(1)
                local bpos = S.base_pos[tbase]
                if u and u:isExist() and bpos then
                    local hpos = u:getPosition().p
                    local dx, dz = hpos.x - bpos.x, hpos.z - bpos.z
                    if dx*dx + dz*dz <= CAPTURE_RADIUS * CAPTURE_RADIUS then
                        -- Waypoint reached: sample the group's live census (INT_TYPE_MEMBER_COUNT /
                        -- INT_TYPE_LOSSES, mb_msgs.c:2293-2295) and roll IMMEDIATELY (d vs frand1,
                        -- :2287-2305) against the keysite's CURRENT efficiency — a repaired base
                        -- repels. All capture side-effects live in keysite.do_capture.
                        local members = TROOP_MEMBER_FALLBACK
                        local losses  = 0
                        local ok_sz, sz = pcall(function() return grp:getSize() end)
                        local cur = ok_sz and tonumber(sz) or nil
                        if cur then
                            members = math.max(1, cur)
                            local ok_is, isz = pcall(function() return grp:getInitialSize() end)
                            local init = ok_is and tonumber(isz) or nil
                            if init then losses = math.max(0, init - members) end
                        end
                        done[gname] = true
                        cs.dbg("troop", "%s heli %s reached capture waypoint of %s: members=%d losses=%d — rolling",
                            cs.SIDE_NAME[side], gname, tbase, members, losses)
                        if keysite.capture_roll(tbase, members, losses) then
                            keysite.do_capture(tbase, side, log_fn)
                            cs.stat_task_result(side, "success")   -- Item 3: capture won (eech task.c objective-message)
                            log_fn(string.format("T.I. CAPTURE: %s → %s (members=%d losses=%d)",
                                tbase, cs.SIDE_NAME[side], members, losses))
                            cs.dbg("troop", "CAPTURE ROLL WON: %s -> %s (group=%s)", tbase, cs.SIDE_NAME[side], gname)
                        else
                            cs.stat_task_result(side, "failure")   -- Item 3: capture repelled (defence held)
                            log_fn(string.format("T.I. repelled at %s (defence held)", tbase))
                            cs.dbg("troop", "CAPTURE ROLL LOST: %s repelled (group=%s)", tbase, gname)
                        end
                        -- The insertion is spent either way: free its dedup registration and launch
                        -- slot (the heli has no Land waypoint — only death or this path frees them).
                        cs.clear_task(gname)
                        keysite.release_slot(gname)
                    end
                end
            end
        end
    end
end

-- ── build_troop_insert(side, base_name, target_name, target_pos, log_fn) ──────
-- BUILDER (task-board contract): spawns the insertion helicopter FROM base_name toward the target
-- keysite. The board has already consumed 1 "heli" from base_name's ledger (refunds on nil).
-- Returns the group on success, nil on failure.
-- `members` (WAVE 3 Item 3b): number of assault helis in the insertion group. EECH's assignment gate
-- suitable_group_task_specific_checks (assign.c:366-390) refuses a troop-insertion group of < 2 members
-- against an ENEMY AIRBASE keysite (objective_type == KEYSITE_AIRBASE && MEMBER_COUNT < 2 && objective
-- side != group side → FALSE). The port stages assault helis, so an airbase capture must field a 2-ship;
-- FARP captures and same-side (defender reinforcement) inserts stay 1-ship. Defaults to 1.
local function build_troop_insert(side, base_name, target_name, target_pos, log_fn, members)
    members = math.max(1, members or 1)
    local home_ab = base_name

    local cfg    = AC_HELI[side]
    -- Spawn from a real airbase if the base has one, else GROUND-START from its coordinates — a
    -- synthetic zone-FARP has no Airbase object (same fix as heli_war.build_attack_heli). Without this
    -- the board could never assign a troop insertion staged from a padless FARP → no captures.
    local ab     = Airbase.getByName(home_ab)
    local ab_pos, ab_id
    if ab then
        ab_pos, ab_id = ab:getPosition().p, ab:getID()
    else
        local bp = cs.S.base_pos and cs.S.base_pos[home_ab]
        if not bp then
            cs.dbg("troop", "%s build_troop_insert ABORT: base %s unknown (no Airbase, no base_pos)",
                cs.SIDE_NAME[side], tostring(home_ab))
            return nil   -- unknown base → board refunds the heli ledger
        end
        local gy = 0
        pcall(function() gy = land.getHeight({ x = bp.x, y = bp.z }) or 0 end)
        ab_pos = { x = bp.x, y = gy, z = bp.z }
    end
    local bx, by = cs.wp_xy(ab_pos)
    local tx, ty = cs.wp_xy(target_pos)
    local sid    = cs.next_id()
    local gname  = string.format("Insert-%s-%d-%d", target_name:sub(1,8), side, sid)

    -- Depart via TakeOff-from-parking at a real airbase, else a ground start at the FARP coordinates.
    local depart
    if ab_id then
        depart = { type="TakeOff", action="From Parking Area", airdromeId=ab_id,
                   alt=ab_pos.y, alt_type="BARO", speed=0, ETA=0, ETA_locked=true,
                   x=bx, y=by, name="Depart", formation_template="" }
    else
        depart = { type="TakeOffGroundHot", action="From Ground Area Hot",
                   alt=ab_pos.y, alt_type="BARO", speed=0, ETA=0, ETA_locked=true,
                   x=bx, y=by, name="Depart", formation_template="" }
    end
    -- One or more assault helis (Item 3b: airbase captures require a 2-ship, assign.c:386).
    local units = {}
    for i = 1, members do
        units[i] = {
            name = gname .. "-" .. i, type = cfg.heli_type, skill = "Good",
            x = ab_pos.x + (i - 1) * 30, y = ab_pos.z, alt = ab_pos.y, alt_type = "BARO",
            speed = 0, heading = 0,
            payload = { fuel = 2200, flare = 60, chaff = 60, gun = 100 },
        }
    end
    local gspec = {
        name   = gname, task = "Transport", hidden = false,
        units  = units,
        route = { points = croute.expand({
            depart,
            { type="Turning Point", action="Turning Point",
              alt=150, alt_type="BARO", speed=100,   -- fast + low: cross to the target quickly, under SAM
              ETA=0, ETA_locked=false, x=tx, y=ty, name="Insert", formation_template="" },
        }, side, { alt=150, alt_type="BARO", speed=100, name="Nav" }) },
    }
    if ab_id then gspec.airdromeId = ab_id end
    local grp = coalition.addGroup(cfg.country, Group.Category.HELICOPTER, gspec)

    if grp then
        -- Register so the T.I. dedup (has_task_against "troop_insertion") sees an in-progress
        -- insertion against this base — stops a new heli being tasked every 2-min tick while the
        -- base stays neutralised (drained the transport pool). Cleared after the capture window.
        cs.register_task(gname, { task_type="troop_insertion", side=side,
            target_base=target_name, target_pos=target_pos, born_time=timer.getTime() })
        -- Capture on ARRIVAL: NO capture window is opened here at dispatch. check_landing_helis opens it
        -- when the heli physically reaches the keysite (eech captures at the TROOP_CAPTURE waypoint,
        -- mb_msgs.c:2260-2325). A heli shot down en route never arrives → no window → no capture attempt.
        -- Safety-net TTL: the insertion heli has NO Land waypoint (it stages at the target and loiters),
        -- so nothing frees its dedup registration + landing slot except (a) the capture window resolving
        -- (check_landing_helis) or (b) death (DEAD handler + regen slot release). If it does NEITHER — a stuck
        -- heli that never reaches CAPTURE_RADIUS and never dies — this force-clears both after
        -- INSERT_TASK_TTL so it can't hold the has_task_against dedup guard / launch slot forever.
        -- Idempotent: if the window already resolved or the heli died, both calls no-op.
        local ttl_gen = _DMT_GEN
        timer.scheduleFunction(function()
            if _DMT_GEN == ttl_gen and cs.get_task(gname) then
                cs.dbg("troop", "T.I. safety-net TTL reached for %s (never arrived/died) -> clearing task+slot", gname)
                cs.clear_task(gname)
                keysite.release_slot(gname)
            end
            return nil
        end, nil, timer.getTime() + INSERT_TASK_TTL)
        -- Attack-helicopter escort shepherds the insertion — but only when the route is dangerous
        -- enough (assign.c:598-627: escort iff route difficulty >= troop_insertion threshold = 3).
        -- Replaces the old unconditional escort. Difficulty logged inside cs.escort_count.
        if cs.escort_count("troop_insertion", side, ab_pos, target_pos, log_fn) > 0 then
            pcall(function() require("heli_war").spawn_escort(side, target_pos, log_fn) end)
        end
        log_fn(string.format("%s T.I. #%d → %s from %s (%d-ship, capture on arrival)", cs.SIDE_NAME[side], sid, target_name, home_ab, members))
        cs.dbg("troop", "%s T.I. #%d DISPATCHED from %s -> %s (capture window opens on arrival within %.0fm)",
            cs.SIDE_NAME[side], sid, home_ab, target_name, CAPTURE_RADIUS)
        return grp
    end
    cs.dbg("troop", "%s T.I. #%d SPAWN FAILED from %s -> %s", cs.SIDE_NAME[side], sid, home_ab, target_name)
    return nil   -- spawn failed; board refunds the heli ledger
end

-- Enqueue a troop-insertion task on the board (role heli). immediate for the reaction chain.
local function create_troop_insert_task(side, target_name, target_pos, log_fn, immediate)
    -- Item 3b (assign.c:386): an OFFENSIVE capture of an enemy AIRBASE keysite needs a >= 2-member
    -- assault group; FARP captures and same-side (defender reinforcement) inserts stay 1-ship. The board
    -- consumes `count` of the transport role, so count == members keeps the ledger draw matched to the
    -- ship count the builder spawns.
    local is_airbase = (cs.S.base_kind and cs.S.base_kind[target_name]) == "airbase"
    local offensive  = cs.S.base_owner and cs.S.base_owner[target_name] ~= side   -- objective side != group side
    local members    = (is_airbase and offensive) and 2 or 1
    cs.dbg("troop", "%s create_troop_insert_task: vs %s (immediate=%s, %d-ship — airbase=%s offensive=%s, assign.c:386)",
        cs.SIDE_NAME[side], target_name, tostring(immediate), members, tostring(is_airbase), tostring(offensive))
    board.create_task({
        type = "troop_insertion", side = side, count = members, log_fn = log_fn, immediate = immediate,
        target = { base = target_name, pos = target_pos, objective = { kind = "keysite", base = target_name } },
        builder = function(base_name)
            return build_troop_insert(side, base_name, target_name, target_pos, log_fn, members)
        end,
    })
    return true
end

-- ── Defender BACKUP troop insertion (eech highlevl.c:1876-1897) ────────────────
-- In create_troop_insertion_tasks, right after tasking the ATTACKER's capture of a weak enemy keysite,
-- EECH also tasks the keysite's OWNER (the defender) to reinforce it — but only when:
--   (1) the keysite is enemy-owned relative to the attacker  (keysite_side != this_side, :1879)
--       — always true here: the periodic scan only rates enemy keysites;
--   (2) the defender has no existing troop_insertion / INSERT_CAPTURE / INSERT_DEFEND task there
--       (:1880-1882) — the port's single "troop_insertion" type covers all three (one insertion
--       pipeline), so ONE has_task_against dedup check;
--   (3) the defender holds fewer than 2 troop patrols at the keysite (:1883). The port caps patrols
--       at 1 per keysite (spawn_patrol/has_patrol), so this count is 0 or 1 → always < 2, never
--       blocking; kept for fidelity to EECH's intent (a base already held by 2 patrols needs no backup).
-- There is NO efficiency gate on the backup — it reinforces the SAME weak keysite the attacker targets.
local function defender_patrol_count(base_name)
    if S.patrol_groups and S.patrol_groups[base_name] then
        local grp = Group.getByName(S.patrol_groups[base_name])
        if grp and grp:isExist() then return 1 end
    end
    return 0
end

local function try_defender_backup(attacker, tname, tpos, log_fn)
    local defender = S.base_owner[tname]
    if defender == nil or defender == attacker then return end              -- (1) keysite_side != this_side
    if cs.has_task_against("troop_insertion", tname, defender) then return end  -- (2) dedup (all 3 EECH types)
    if defender_patrol_count(tname) >= 2 then return end                    -- (3) < 2 patrols
    cs.dbg("troop", "backup DEFENDER T.I.: %s reinforces its own weak keysite %s (patrols=%d)",
        cs.SIDE_NAME[defender], tname, defender_patrol_count(tname))
    create_troop_insert_task(defender, tname, tpos, log_fn, true)
    log_fn(string.format("%s backup T.I. → %s (defend own keysite under capture)", cs.SIDE_NAME[defender], tname))
end

-- run_troop_insertion(side, log_fn, target_name):
--   target_name given  → insert directly against THAT keysite (reaction chain, reaction.c:413).
--   target_name nil    → periodic scan, pick top targets (create_troop_insertion_tasks).
local function run_troop_insertion(side, log_fn, target_name)
    if target_name then
        local tpos = S.base_pos[target_name]
        local dup  = cs.has_task_against("troop_insertion", target_name, side)
        if tpos and not dup then
            cs.dbg("troop", "%s run_troop_insertion: DIRECTED (reaction) vs %s", cs.SIDE_NAME[side], target_name)
            create_troop_insert_task(side, target_name, tpos, log_fn, true)  -- reaction chain: immediate
        else
            cs.dbg("troop", "%s run_troop_insertion DIRECTED SKIP vs %s: tpos=%s dup=%s",
                cs.SIDE_NAME[side], target_name, tostring(tpos ~= nil), tostring(dup))
        end
        return
    end
    local enemy = cs.ENEMY[side]
    -- No survival gate: EECH create_troop_insertion_tasks (highlevl.c:1780+) generates offensive
    -- captures regardless of force strength — force_attitude/strength is read by no AI code. The former
    -- STRENGTH_SURVIVAL skip was invented (Cluster E); the endgame is resolved by the strike/capture
    -- pressure realignment (Clusters A/C/D), not a posture cutoff.
    local rated = {}
    local count = 0

    for tname, towner in pairs(S.base_owner) do
        if count >= MAX_HIGHLEVEL_TARGET_CHECKS then break end
        if towner == enemy then
            local tpos = S.base_pos[tname]
            if tpos then
                -- FLOAT_TYPE_EFFICIENCY proxy: composite health+ammo+fuel metric
                -- (updated every 60 s by keysite_repair.lua; falls back to health alone)
                local efficiency = (S.base_efficiency and S.base_efficiency[tname])
                                   or S.base_health[tname] or 1.0

                -- Filter: only troop_insertion_target keysites (proxy: health < MINIMUM_EFFICIENCY)
                if efficiency < MINIMUM_EFFICIENCY then
                    -- FOW check (line 1819): fow >= 0.20 * maximum
                    local fow = fow_m.get(tname, side)
                    if fow < FOW_THRESHOLD_TI then
                        -- EECH highlevl.c:1819: a fogged capture target spawns a RECON to reveal it
                        -- (was previously an empty else → neutralised-but-fogged bases were skipped
                        -- forever and never captured). Recon raises FOW so a later T.I. tick proceeds.
                        if not cs.has_task_against("recon", tname, side) then
                            local ok_r, recon = pcall(require, "recon")
                            if ok_r and recon and recon.spawn_recon then
                                pcall(recon.spawn_recon, side, tpos, "TIscout-" .. tname:sub(1, 8),
                                      log_fn, { kind = "keysite", base = tname })
                                log_fn(string.format(
                                    "T.I.: %s neutralised (%.0f%%) but FOGGED (fow=%.2f<%.2f) — recon dispatched",
                                    tname, efficiency * 100, fow, FOW_THRESHOLD_TI))
                            end
                        end
                    end
                    if fow >= FOW_THRESHOLD_TI then
                        log_fn(string.format("T.I.: %s capturable (%.0f%%, fow=%.2f) — tasking insertion",
                            tname, efficiency * 100, fow))
                        -- Orientation: AIR_DEFENCE[side] = the AA that SIDE faces (built from
                        -- ENEMY[side]'s AA) — the attacker reads its OWN side's layer. get(enemy,...)
                        -- returned the attacker's own AA, inverting the (1-airdef) term.
                        local airdef = imap_m.get(side, imap_m.AIR_DEFENCE, tpos)
                        local bdist  = imap_m.get(side, imap_m.BASE_DISTANCE, tpos)
                        local sratio = sector_ratio(tpos, side)

                        -- EECH formula: (1-airdef)*1 + base_dist*3 + (1-efficiency)*3 + sector_ratio*2
                        -- Commented-out importance term not included (// rating += ...)
                        -- max=9.0
                        local rating = (1.0 - airdef) * 1.0
                                     + bdist * 3.0
                                     + (1.0 - efficiency) * 3.0
                                     + sratio * 2.0

                        if rating > 0.0 then
                            rated[#rated + 1] = { name = tname, pos = tpos, rating = rating }
                            count = count + 1
                        end
                    end
                end
            end
        end
    end

    if #rated == 0 then
        cs.dbg("troop", "%s run_troop_insertion: 0 enemy keysites below minimum-efficiency, no T.I. tasked", cs.SIDE_NAME[side])
        return
    end
    sort_targets(rated)

    local max_r  = rated[1].rating
    local n      = math.min(#rated, CREATE_TROOP_INSERTION_TASK_COUNT)
    local n_tasked, n_dup_skip = 0, 0
    for i = 1, n do
        local entry = rated[i]
        -- Dedup (highlevl.c:1853): skip if a T.I. task already exists (queued or flying) here.
        if entry.rating / max_r >= MIN_TASK_CREATION_RATIO then
            if not cs.has_task_against("troop_insertion", entry.name, side) then
                -- immediate=true: assign + spawn THIS tick so the active-task registration (dedup) lands
                -- before the next 2-min tick — otherwise a new insertion is tasked every tick while the
                -- board's 3-min assignment lag leaves has_task_against false (transport-pool drain).
                create_troop_insert_task(side, entry.name, entry.pos, log_fn, true)
                n_tasked = n_tasked + 1
                -- eech highlevl.c:1876-1897: after the attacker's capture task, task the defender to
                -- reinforce its own weak keysite (gated conditions in try_defender_backup).
                try_defender_backup(side, entry.name, entry.pos, log_fn)
            else
                n_dup_skip = n_dup_skip + 1
            end
        end
    end
    cs.dbg("troop", "%s run_troop_insertion funnel: %d capturable rated -> top %d checked -> %d tasked, %d already-dup",
        cs.SIDE_NAME[side], #rated, n, n_tasked, n_dup_skip)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Infantry patrol (create_troop_patrol_tasks, line 2735)
-- ═══════════════════════════════════════════════════════════════════════════════
-- mirrors: for each own FARP/military/airbase keysite:
--   if no existing patrol group (groups_counter < groups_limit=1):
--     create_faction_members(... INFANTRY_PATROL, count=4, ...)
--     create_patrol_task(group, keysite, side)
--
-- DCS proxy: spawn 4-unit infantry group at PATROL_BASE_RADIUS from base.
-- Patrol task → Guard area with radius 500m.
-- Track S.patrol_groups[base_name] so we don't double-spawn.

local PATROL_UNIT_COUNT  = 4     -- EECH line 2812: count=4
local PATROL_GUARD_RADIUS = 500  -- metres; proxy for patrol waypoint orbit

local function has_patrol(base_name, side)
    if not S.patrol_groups then return false end
    local pg = S.patrol_groups[base_name]
    if not pg then return false end
    local grp = Group.getByName(pg)
    return grp and grp:isExist()
end

local function spawn_patrol(base_name, side, log_fn)
    if has_patrol(base_name, side) then return end
    local cfg   = INFANTRY_TYPE[side]
    if not cfg then return end
    local bpos  = S.base_pos[base_name]
    if not bpos then return end

    -- Angle: keysite index % 6 * PI2/6 (line 2803: get_local_entity_index % 6)
    -- DCS proxy: a random bearing around the base.
    local angle = math.random() * math.pi * 2.0
    local r     = PATROL_BASE_RADIUS + math.random() * PATROL_RADIUS_JITTER

    -- Snap the patrol ring point off water (a 300 m ring at a coastal FARP/base can be wet);
    -- fallback = the base centre `bpos` (always land). Per-unit offsets stay relative to the snap.
    local sp = cs.snap_land(bpos.x + math.cos(angle) * r, bpos.z + math.sin(angle) * r, bpos.x, bpos.z)
    local px = sp.x
    local pz = sp.z
    local py = land.getHeight({ x = px, y = pz })   -- land.getHeight takes a single {x,y} vec2

    local id    = cs.next_id()
    local gname = string.format("Patrol-%s-%d", base_name:sub(1,10), id)

    local units = {}
    for i = 1, PATROL_UNIT_COUNT do
        units[i] = {
            name     = gname .. "-" .. i,
            type     = cfg.unit,
            skill    = "Good",
            x        = px + (i - 1) * 5.0,
            y        = pz,
            alt      = py,
            alt_type = "BARO",
            speed    = 0,
            heading  = 0,
            playerCanDrive = false,
        }
    end

    local grp = coalition.addGroup(cfg.country, Group.Category.GROUND, {
        name   = gname,
        task   = "Ground Nothing",
        hidden = false,
        units  = units,
        route  = { points = {
            {
                type = "Turning Point", action = "Turning Point",
                x = px, y = pz, speed = 1.4, ETA = 0, ETA_locked = false,
                formation_template = "",
                task = {
                    id = "ComboTask",
                    params = { tasks = { [1] = {
                        number = 1, auto = true, id = "Guard", enabled = true,
                        params = { zone = { x = px, y = pz }, radius = PATROL_GUARD_RADIUS },
                    }}},
                },
            },
        }},
    })

    if grp then
        S.patrol_groups = S.patrol_groups or {}
        S.patrol_groups[base_name] = gname
        log_fn(string.format("%s patrol spawned at %s (#%d, %d units)",
            cs.SIDE_NAME[side], base_name, id, PATROL_UNIT_COUNT))
    end
end

local function run_troop_patrol(side, log_fn)
    -- mirrors: for each own FARP/military/airbase keysite
    -- DCS proxy: all friendly bases are treated as patrol-eligible
    local n_checked, n_spawned, n_already, n_error = 0, 0, 0, 0
    for name, owner in pairs(S.base_owner) do
        if owner == side then
            local h = S.base_health[name] or 1.0
            if h >= cs.HEALTH_NEUTRALISED then   -- USABLE iff eff >= min (keysite.c:827-830, inclusive)
                n_checked = n_checked + 1
                local was_patrolled = has_patrol(name, side)
                local ok, err = pcall(spawn_patrol, name, side, log_fn)
                if not ok then
                    log_fn(string.format("patrol spawn error at %s: %s", name, tostring(err)))
                    n_error = n_error + 1
                elseif was_patrolled then
                    n_already = n_already + 1
                else
                    n_spawned = n_spawned + 1
                end
            end
        end
    end
    cs.dbg("troop", "%s patrol tick: %d bases checked -> %d spawned, %d already patrolled, %d errors",
        cs.SIDE_NAME[side], n_checked, n_spawned, n_already, n_error)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Schedulers
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── Single-shot spawn (called by reaction.lua for follow-on T.I. tasks) ───────
-- Mirrors create_troop_insertion_task called from create_reaction_to_recon_task_completed.
function M.run_troop_insertion(side, log_fn, target_name)
    log_fn = log_fn or function() end
    cs.dbg("troop", "%s run_troop_insertion single-shot invoked (target=%s)", cs.SIDE_NAME[side], tostring(target_name))
    local ok, err = pcall(run_troop_insertion, side, log_fn, target_name)
    if not ok then log_fn("run_troop_insertion error: " .. tostring(err)) end
end

function M.schedule_troop_insertion(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    local offset = initial_offset or OFFSET_TI
    cs.dbg("troop", "%s T.I. scheduler REGISTERED offset=%.0fs period=%.0fs", cs.SIDE_NAME[side], offset, PERIOD_TI)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end    -- re-injection guard: cancel superseded closure
        cs.dbg("troop", "%s T.I. FIRE", cs.SIDE_NAME[side])
        local ok, err = pcall(function()
            -- INFRASTRUCTURE: arrival check (waypoint-reached → capture roll) keeps running after
            -- campaign-over — in-flight troops still capture on arrival (the world runs on, per EECH
            -- fc_msgs.c:163 which halts only the win-check, not the sim).
            check_landing_helis(side, log_fn)
            -- Item 6 (LITERAL post-victory semantics): T.I. generation keeps running after the win is
            -- declared — EECH fc_msgs.c:163 gates ONLY the win-check re-award, never the generators.
            run_troop_insertion(side, log_fn)
        end)
        if not ok then log_fn("T.I. error: " .. tostring(err)) end
        return t + PERIOD_TI
    end, nil, timer.getTime() + offset)
end

function M.schedule_patrol(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    local offset = initial_offset or OFFSET_PATROL
    cs.dbg("troop", "%s patrol scheduler REGISTERED offset=%.0fs period=%.0fs", cs.SIDE_NAME[side], offset, PERIOD_PATROL)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end    -- re-injection guard: cancel superseded closure
        -- Item 6: patrol generation keeps running post-victory (EECH fc_msgs.c:163 gates only the win re-award).
        local ok, err = pcall(run_troop_patrol, side, log_fn)
        if not ok then log_fn("patrol error: " .. tostring(err)) end
        return t + PERIOD_PATROL
    end, nil, timer.getTime() + offset)
end

return M
