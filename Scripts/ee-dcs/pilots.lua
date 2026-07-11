-- pilots.lua
-- EECH source:
--   aphavoc/source/entity/special/pilot/pi_funcs.c    pilot entity accessors (kills/rank/side)
--   aphavoc/source/entity/special/pilot/pilot.c        get_player_rank_from_points, high-score,
--                                                      join-announce, session pilot count
--   aphavoc/source/entity/system/en_types/en_plyr.h    entity_players (AI/LOCAL/REMOTE, :67-73)
--   aphavoc/source/ui_menu/player/player.c             promotion thresholds (:73-77),
--                                                      inc_player_log_kills classification (:912-977)
--   aphavoc/source/ui_menu/player/play_md.c            valour-medal criteria table (:218-260)
--   aphavoc/source/entity/mobile/mobile.c              credit_client_server_mobile_kill /
--                                                      calculate_task_points_for_kill (:281-484)
--   aphavoc/source/entity/mobile/aircraft/helicop/helicop.c  suitable_for_player (:1825-1966),
--                                                      notify_gunship_entity_mission_terminated
--
-- THE PILOT / PLAYER CAREER SUBSTRATE (Cluster 6, spec 10). EECH's PILOT entity + player_log are
-- NOT PORTED (DCS owns player slots, join/leave, side selection, occupancy — spec 10 §5). This
-- module is the port-side career record the campaign keeps ABOUT each human: per-player kills by
-- category, cumulative score (experience proxy), rank, valour medals, sorties and deaths, keyed by
-- getPlayerName. It is scaffolding: it activates fully only once flyable player slots exist (goals/03
-- P0 — coalition.addGroup cannot create human slots). With zero players every entry point is inert.
--
-- State lives in the campaign_state singleton (S.pilots) so a future persistence layer (goals/03 P1)
-- serializes it with the rest of the campaign. init() never clobbers an existing S.pilots (restore-safe).
--
-- PORTED IN WAVE 4 (this file):
--   * Player mission assignment (F19): a human binds an open player-flyable board task via the F-10
--     group menu (M._grp_request → task_board.assign_to_player); it leaves the AI pool and is registered
--     as the player's sortie so reaction/dedup/debrief treat it like an AI task.
--   * Per-sortie debrief loop (F9): M.on_debrief, fired from reaction's S_EVENT_LAND when a human lands
--     completing their task — mirrors notify_gunship_entity_mission_terminated (helicop.c:693-836).
--   * Air Medal (F11, 3 consecutive successes, play_md.c:1304-1359); Purple Heart (F13, damaged-but-
--     survived, play_md.c:1245-1296, tracked via S_EVENT_HIT → M.on_hit); Campaign medal at the win
--     declaration (F14, play_md.c:1062, M.award_campaign_medals from win_condition.finish).
--
-- DELIBERATELY NOT PORTED (noted, not reproduced):
--   * Flying-hours career track + aviator-wings flight-time medals (F12): the port keeps `sorties`
--     (mission count) but no flying-hours accrual, so the documented EECH ×1000 unit bug
--     (get_player_log_flying_hours uses TIME_1_HOUR = 3_600_000 ms, player.c:740, while
--     award_aviator_wings uses ONE_HOUR = 3600 s, play_md.c:1018 — spec 10 Open-Q1) is NOT
--     reproduced. If flying hours are ever added, divide seconds by 3600 (ONE_HOUR) everywhere.
--   * MP pilot entity replication, high-score table, planner locks (F1-F6,F18,F20-F22):
--     DCS-native or out of scope for this scaffolding.

local cs      = require("campaign_state")
local supply  = require("supply")
local board   = require("task_board")
local frontl  = require("frontline")
local S       = cs.S
local M       = {}

local function info(msg)
    env.info(string.format("[ee-dcs] [pilots] %s", tostring(msg)))
end

-- ── Rank / promotion thresholds (PILOT-F8) ─────────────────────────────────────
-- Rank is a pure function of accumulated per-side experience points (award_player_rank,
-- get_player_rank_from_points; eech player.c:408-431). Base constants eech player.c:73-77.
-- NO demotion guard in EECH — rank is whatever the points imply; points only shrink via explicit
-- clamping at 0 (player.c:540-546), never from death. Names: eech player.c:172-177.
M.RANK = {
    { name = "Lieutenant",  points = 0 },       -- LIEUTENANT_POINTS_BASE   eech player.c:73
    { name = "Captain",     points = 7500 },    -- CAPTAIN_POINTS_BASE      eech player.c:74
    { name = "Major",       points = 32000 },   -- MAJOR_POINTS_BASE        eech player.c:75
    { name = "Lt. Colonel", points = 120000 },  -- LT_COLONEL_POINTS_BASE   eech player.c:76
    { name = "Colonel",     points = 250000 },  -- COLONEL_POINTS_BASE      eech player.c:77
}

-- ── Valour medals (PILOT-F10) ──────────────────────────────────────────────────
-- Points thresholds of the valour-medal criteria table (eech play_md.c:218-260); the points test
-- is strictly `points >` the threshold (eech play_md.c:1212).
-- PORT PROXY: EECH awards these on PER-MISSION points with rank / prerequisite-medal / campaign-medal
-- gating (query_award_medal, play_md.c:1109-1173), inside the mission-termination debrief (F9). The
-- port awards each valour medal ONCE when CUMULATIVE career score first exceeds its threshold
-- (award_after_score, called from both on_kill and the on_debrief loop) rather than on per-mission
-- points — a documented reward-spine stand-in. The rank/prerequisite gates are intentionally omitted.
M.VALOUR = {
    { name = "Flying Cross",          points = 2600 },  -- eech play_md.c:218-260
    { name = "Silver Star",           points = 3200 },
    { name = "Distinguished Service", points = 4000 },
    { name = "Medal of Honour",       points = 5000 },
}

-- ── Per-category kill points ───────────────────────────────────────────────────
-- PORT PROXY for INT_TYPE_POINTS_VALUE (the per-entity data value that EECH's
-- calculate_task_points_for_kill uses as its base; eech mobile.c:281-359). The port has no
-- per-entity points-value data, so kills are scored by CATEGORY. Same-side (friendly) kills score 0
-- (eech mobile.c:306-311). The EECH threat-target bonuses (+10% own group / +50% other friendly
-- group; mobile.c:338/346) are omitted — the port has no per-kill "was the victim targeting a
-- friendly" context. Values are relative-worth proxies, not eech literals.
M.KILL_POINTS = {
    fixed_wing = 100, helicopter = 100, air_defence = 80,
    armour = 60, artillery = 60, ground = 40, sea = 120, fixed = 50,
}

-- ── Player-flyable task types (PILOT-F17) ──────────────────────────────────────
-- suitable_for_player gates the campaign to player-controllable COMBAT HELICOPTERS (gunships;
-- eech helicop.c:1825-1966). In the port the gunship missions are the LIVE heli-role board tasks:
-- CAS and BAI (the rotary frontline fight, ts_dbase.c heli-eligible landing types) plus troop
-- insertion (critical → shown in the menu but never held back by the reservation) and BDA.
-- The retired anti_armour/hunter_killer/heli_escort types were removed with their generators
-- (Cluster H) — listing them here made the player reservation + Request Mission list INERT
-- (adversarial-review Finding 1). Fixed-wing striker/escort/recon tasks are AI-only here.
-- Consumed by get_player_missions (F-10 "Request Mission") and task_board's player reservation.
M.PLAYER_FLYABLE = {
    cas = true, bai = true, troop_insertion = true, bda = true,
}

-- ── Air Medal streak (PILOT-F11, eech play_md.c:89) ────────────────────────────
-- NUM_NEEDED_TO_AWARD_AIR_MEDAL = 3 (play_md.c:89): the Air Medal is awarded on a hat-trick of
-- CONSECUTIVE successful missions (award_air_medal_medal, play_md.c:1304-1359 — counter++ on success,
-- award+reset at 3, reset to 0 on any failure).
M.AIR_MEDAL_STREAK = 3

-- ── Per-task briefing templates (WARZONE-F20/21, eech ai/faction/briefing.c) ───────────────────────
-- EECH generates mission briefing text from a briefing database: briefing.dat holds a template string
-- per task type and build_substitution_info (briefing.c) walks %-tokens substituting the live objective
-- — briefing_add_keysite / briefing_add_position / briefing_add_sector / briefing_add_target_type
-- (briefing.c:107-117) splice in the target keysite name, its map position, and the target kind. The
-- port keeps that SHAPE data-light: one template per port task type, with a single %s target-name
-- substitution, and brief_for() appends the live bearing/range from the assigning base (the
-- briefing_add_position analog). Kept intentionally as flavour+geometry text, not a data-file loader.
M.TEMPLATES = {
    cas             = "CLOSE AIR SUPPORT: friendly ground forces are in contact near %s. Find and destroy the enemy armour and infantry in the engagement zone, then RTB.",
    bai             = "BATTLEFIELD INTERDICTION: enemy ground forces are moving to reinforce %s. Interdict and destroy the column before it reaches the front line.",
    bda             = "BATTLE DAMAGE ASSESSMENT: overfly %s and confirm the results of the preceding strike. Stay high, observe, and return to base.",
    troop_insertion = "AIR ASSAULT: %s has been suppressed below holding strength. Insert the assault troops onto the objective to capture it.",
    ground_strike   = "GROUND STRIKE: destroy the high-value structures at %s to degrade its operational output.",
    oca_strike      = "OCA STRIKE: hit the airbase at %s to suppress enemy air operations — crater the ramp and kill parked aircraft.",
    oca_sweep       = "OCA SWEEP: sweep the airspace over %s ahead of the strike package and clear enemy fighters.",
    sead            = "SEAD: suppress the enemy air-defence network protecting %s. Kill the radars and launchers screening the objective.",
    recon           = "RECONNAISSANCE: overfly %s and reveal enemy dispositions to cue follow-on tasking.",
    heli_escort     = "ESCORT: shepherd the friendly rotary package operating near %s and keep threats off it.",
    supply          = "LOGISTICS: fly the resupply run into %s.",
}

-- ── Rank helper ────────────────────────────────────────────────────────────────
local function rank_from_points(pts)
    local r = 1
    for i = #M.RANK, 1, -1 do
        if pts >= M.RANK[i].points then r = i; break end
    end
    return r
end

-- ── Record lifecycle (created on first sight, PILOT-F1 analogue) ───────────────
local function get_or_create(name, side)
    S.pilots = S.pilots or {}
    local rec = S.pilots[name]
    if not rec then
        rec = {
            name = name, side = side,
            score = 0, rank = 1,
            -- category counters mirror player_kills_type (eech player.h:154-169)
            kills = { air = 0, ground = 0, sea = 0, fixed = 0,
                      fixed_wing = 0, helicopter = 0, air_defence = 0,
                      armour = 0, artillery = 0, friendly = 0, total = 0 },
            medals   = {},   -- [medal_name] = count
            sorties  = 0,    -- slot-entries (S_EVENT_BIRTH count)
            deaths   = 0,
            -- Debrief-loop fields (PILOT-F9/F11/F13, eech play_md.c). missions_flown mirrors
            -- inc_player_log_missions_flown (helicop.c:729 — COMPLETED missions, distinct from `sorties`
            -- which is births); air_medal_counter is player_log side_log.air_medal_counter (play_md.c:1320);
            -- sortie_score_start snapshots career score at task assignment so mission_points = the per-
            -- sortie delta (the INT_TYPE_TASK_SCORE proxy, mobile.c:416-424); sortie_damaged is the
            -- S_EVENT_HIT-tracked "took damage this sortie" flag for the Purple Heart (play_md.c:1245).
            missions_flown   = 0,
            air_medal_counter = 0,
            sortie_score_start = 0,
            sortie_damaged   = false,
            first_seen = timer.getTime(),
        }
        S.pilots[name] = rec
        info(string.format("pilot record created: %s (%s)", name, cs.SIDE_NAME[side] or "?"))
        cs.dbg("pilots", "record created: %s (%s)", name, cs.SIDE_NAME[side] or "?")
    end
    return rec
end

-- ── Victim classification (PILOT-F15, eech player.c:912-977) ───────────────────
-- Returns (category, sub) where category ∈ {air,ground,sea,fixed} and sub is the finer bucket
-- (fixed_wing/helicopter/air_defence/armour/artillery) or nil. nil category → not a scorable kill.
local function classify_victim(victim)
    local ok, desc = pcall(function() return victim:getDesc() end)
    local a = (ok and desc and desc.attributes) or {}
    if a["Planes"]      then return "air", "fixed_wing" end
    if a["Helicopters"] then return "air", "helicopter" end
    if a["Air Defence"] or a["SAM"] or a["AAA"] or a["SR SAM"] or a["MR SAM"] or a["LR SAM"]
                        then return "ground", "air_defence" end
    if a["Ships"]       then return "sea", nil end
    if a["Buildings"] or a["Structures"] or a["Immobile"] then return "fixed", nil end
    if a["Tanks"] or a["Armored vehicles"] or a["IFV"] or a["APC"] or a["MBT"]
                        then return "ground", "armour" end
    if a["Artillery"]   then return "ground", "artillery" end
    if a["Ground Units"] or a["Infantry"] then return "ground", nil end
    return nil, nil
end

-- ── Promotion / medal awarding (announced via outText, PILOT-F8/F10) ───────────
local function award_after_score(rec)
    -- Promotion (no demotion: score only grows, so rank_from_points >= current).
    local newr = rank_from_points(rec.score)
    if newr > rec.rank then
        rec.rank = newr
        local msg = string.format("%s promoted to %s (score %d)", rec.name, M.RANK[newr].name, rec.score)
        info(msg)
        pcall(trigger.action.outText, msg, 15)
    end
    -- Valour medals: award each once when cumulative score strictly exceeds its threshold.
    for _, m in ipairs(M.VALOUR) do
        if rec.score > m.points and not rec.medals[m.name] then
            rec.medals[m.name] = 1
            local msg = string.format("%s awarded the %s", rec.name, m.name)
            info(msg)
            pcall(trigger.action.outText, msg, 15)
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Event entry points (called from EXISTING world handlers — no new world hooks)
-- ═══════════════════════════════════════════════════════════════════════════════

-- on_kill: called from win_condition's S_EVENT_KILL handler. Credits the killer's career record
-- when the killer is a human (PILOT-F16 player-career branch, mobile.c:449-459). Inert for AI kills.
function M.on_kill(event)
    if not event or event.id ~= world.event.S_EVENT_KILL then return end
    local killer = event.initiator
    if not killer or not killer.getPlayerName then return end
    local pname
    local ok = pcall(function() pname = killer:getPlayerName() end)
    if not ok or not pname then return end   -- AI killer → not a player career event

    local kside
    pcall(function() kside = killer:getCoalition() end)
    local rec = get_or_create(pname, kside)

    local victim = event.target
    if not victim then return end

    local vside
    pcall(function() vside = victim:getCoalition() end)
    local cat, sub = classify_victim(victim)
    if not cat then return end

    if vside ~= nil and vside == kside then
        rec.kills.friendly = rec.kills.friendly + 1   -- same-side kill: 0 points (mobile.c:306-311)
        info(string.format("%s FRIENDLY kill (no score)", pname))
        return
    end

    rec.kills[cat] = (rec.kills[cat] or 0) + 1
    if sub then rec.kills[sub] = (rec.kills[sub] or 0) + 1 end
    rec.kills.total = rec.kills.total + 1
    local pts = M.KILL_POINTS[sub or cat] or 0
    rec.score = rec.score + pts
    info(string.format("%s kill: %s (+%d → score %d, %d total)",
        pname, sub or cat, pts, rec.score, rec.kills.total))
    cs.dbg("pilots", "%s kill: %s +%d -> score %d rank=%s", pname, sub or cat, pts, rec.score,
        M.RANK[rec.rank] and M.RANK[rec.rank].name or "?")
    award_after_score(rec)
end

-- on_death: called from reaction's S_EVENT_DEAD handler. Records a player's loss (PILOT-F15/F23).
-- Death does NOT destroy the career (spec 10 F23) and carries NO score penalty in EECH (experience
-- only shrinks via explicit clamping, player.c:540-546) — so there is no demotion (F8). We record the
-- death and re-affirm rank (unchanged). No respawn mechanics (DCS owns slot re-entry).
function M.on_death(event)
    local u = event and event.initiator
    if not u or not u.getPlayerName then return end
    local pname
    local ok = pcall(function() pname = u:getPlayerName() end)
    if not ok or not pname then return end
    local rec = S.pilots and S.pilots[pname]
    if not rec then return end   -- never seen alive → nothing to record
    rec.deaths = (rec.deaths or 0) + 1
    rec.kills.deaths = rec.deaths   -- mirror into the player_kills_type deaths field
    -- A death is a FAILED mission (the sortie never debriefs): reset the Air Medal consecutive-success
    -- streak (eech play_md.c:820 award_air_medal_medal(side, FALSE) on TASK_COMPLETED_FAILURE) and clear
    -- the per-sortie debrief baselines so the next sortie starts clean. No score penalty (rank held).
    rec.air_medal_counter  = 0
    rec.sortie_damaged     = false
    rec.sortie_score_start = rec.score
    info(string.format("%s DEATH recorded (deaths=%d, rank held at %s, no score penalty)",
        pname, rec.deaths, M.RANK[rec.rank].name))
    cs.dbg("pilots", "%s DEATH recorded: deaths=%d, air-medal streak reset, no score penalty", pname, rec.deaths)
end

-- on_birth: called from reaction's S_EVENT_BIRTH handler. Ensures a career record for a human unit
-- and, once per entry (debounced), sends the situational JOIN BRIEF (goals/03 P1): phase, own-side
-- strength, reserves, nearest frontline, own objectives, open gunship missions. Inert for AI births.
function M.on_birth(event)
    local u = event and event.initiator
    if not u or not u.getPlayerName then return end
    local pname
    local ok = pcall(function() pname = u:getPlayerName() end)
    if not ok or not pname then return end

    local side
    pcall(function() side = u:getCoalition() end)
    local rec = get_or_create(pname, side)
    rec.sorties = (rec.sorties or 0) + 1

    -- Resolve this human's group id/name once (used for the group-scoped menu AND the join brief).
    local gid, gname
    pcall(function() local g = u:getGroup(); gid = g:getID(); gname = g:getName() end)

    -- Build/refresh this human's group-scoped F-10 assignment menu (PILOT-F19). Group-scoped so the
    -- command can identify WHICH player is requesting (a coalition-scoped command cannot). Rebuilt on
    -- each birth (remove+add) so it stays correct across slot changes and re-injection.
    if gid and gname then pcall(M.build_group_menu, gid, gname, side) end

    -- Debounce: S_EVENT_BIRTH can fire more than once per slot entry; one brief per ~10 s.
    local now = timer.getTime()
    if rec.last_brief_t and (now - rec.last_brief_t) < 10 then return end
    rec.last_brief_t = now

    local text = M.build_brief(rec, side)
    if gid and trigger.action.outTextForGroup then
        local sent = pcall(trigger.action.outTextForGroup, gid, text, 30)
        if sent then info(string.format("join brief sent to %s (group %s)", pname, tostring(gid)))
                     return end
    end
    pcall(trigger.action.outText, text, 30)   -- fallback: whole-server text
    info(string.format("join brief (fallback outText) for %s", pname))
end

-- ── Situational brief text (goals/03 P1 "entering an ongoing war") ─────────────
function M.build_brief(rec, side)
    local enemy = cs.ENEMY[side]
    local phase = cs.current_phase()
    local lines = {}
    lines[#lines + 1] = string.format("=== SITUATION BRIEF — %s (%s) ===",
        rec.name, M.RANK[rec.rank] and M.RANK[rec.rank].name or "?")
    lines[#lines + 1] = string.format("Phase: %s   |   %s %d%%   %s %d%%",
        string.upper(phase),
        cs.SIDE_NAME[side]  or "?", S.strength[side]  or 0,
        cs.SIDE_NAME[enemy] or "?", S.strength[enemy] or 0)

    -- Own-side reserve summary (supply.reserve_side = Σ base ledgers).
    local ok_h, heli    = pcall(supply.reserve_side, side, "heli")
    local ok_s, striker = pcall(supply.reserve_side, side, "striker")
    local ok_e, escort  = pcall(supply.reserve_side, side, "escort")
    lines[#lines + 1] = string.format("Your reserves: %d gunship, %d strike, %d escort",
        (ok_h and heli) or 0, (ok_s and striker) or 0, (ok_e and escort) or 0)

    -- Nearest / most-forward frontline base for the side.
    local ok_f, fl = pcall(frontl.get_frontline, side)
    local front = (ok_f and fl and fl[1]) or "none"
    lines[#lines + 1] = "Frontline (most forward): " .. front

    -- Own campaign objectives (enemy keysites this side must capture).
    local objs = S.objectives and S.objectives[side]
    if objs and #objs > 0 then
        lines[#lines + 1] = "Objectives (capture): " .. table.concat(objs, ", ")
    else
        lines[#lines + 1] = "Objectives: (pending assignment)"
    end

    -- Open gunship missions available to request.
    local ok_m, miss = pcall(M.get_player_missions, side)
    local msn = (ok_m and miss) or {}   -- or {} → provably a table for the length op
    lines[#lines + 1] = string.format(
        "Open gunship missions: %d  (F10 > Campaign > Request Mission)", #msn)

    return table.concat(lines, "\n")
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Per-task briefing text (WARZONE-F20/21, eech ai/faction/briefing.c)
-- ═══════════════════════════════════════════════════════════════════════════════

-- nearest_own_base_pos(side, pos): position of `side`'s nearest owned base to `pos` (the launch base
-- the briefing geometry is measured FROM when no explicit origin is supplied — the F-10 list case).
local function nearest_own_base_pos(side, pos)
    if not pos then return nil end
    local best, best_d2 = nil, math.huge
    for name, owner in pairs(S.base_owner or {}) do
        if owner == side then
            local bpos = S.base_pos and S.base_pos[name]
            if bpos then
                local d2 = cs.dist2d(pos.x, pos.z, bpos.x, bpos.z) ^ 2
                if d2 < best_d2 then best_d2 = d2; best = bpos end
            end
        end
    end
    return best
end

-- brief_for(task, origin_pos): one-paragraph mission briefing — per-type template (M.TEMPLATES) with
-- the target name substituted (briefing_add_keysite, briefing.c:111) plus the live bearing/range from
-- `origin_pos` to the objective (briefing_add_position, briefing.c:107). `task` is a board-task record
-- ({type, target={base,pos}, critical}). origin_pos nil → geometry omitted (template only).
-- (task/origin_pos are normalised to provable tables with `or {}` — the static analyzer does not narrow
-- and/or guards on parameters, and this keeps the geometry safe when either is nil, e.g. a task with no
-- target position or a caller with no launch base.)
function M.brief_for(task, origin_pos)
    task = task or {}
    local ttype  = task.type or task.task_type or "recon"
    local tgt    = (task.target and task.target.base) or task.target_base or "the target area"
    local tpos   = (task.target and task.target.pos) or task.target_pos
    local tmpl   = M.TEMPLATES[ttype] or "Mission vs %s."
    local body   = string.format(tmpl, tgt)
    local geo    = ""
    local origin = origin_pos or {}
    local ox, oz = origin.x, origin.z
    local tx     = tpos and tpos.x
    local tz     = tpos and tpos.z
    if ox and oz and tx and tz then
        local rng = cs.dist2d(ox, oz, tx, tz) / 1000.0
        local brg = math.deg(cs.heading_to(ox, oz, tx, tz))
        if brg < 0 then brg = brg + 360 end
        geo = string.format("  [Bearing %03.0f, %.0f km]", brg, rng)
    end
    return body .. geo .. (task.critical and "  *PRIORITY*" or "")
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Mission request scaffolding (PILOT-F19)
-- ═══════════════════════════════════════════════════════════════════════════════

-- get_player_missions(side): the top open UNASSIGNED player-flyable board tasks, formatted for the
-- F-10 "Request Mission" menu. Display-only — this function only lists; the actual player↔task binding
-- (F19) happens in M._grp_request via board.assign_to_player.
-- Sorted by the board's own priority ordering (critical ×2, assign.c:201-204).
function M.get_player_missions(side)
    local out = {}
    for _, t in ipairs(S.board_tasks or {}) do
        if t.state == "UNASSIGNED" and t.side == side and M.PLAYER_FLYABLE[t.type] then
            out[#out + 1] = t
        end
    end
    table.sort(out, function(a, b)
        local pa = (a.priority or 1) * (a.critical and 2.0 or 1.0)
        local pb = (b.priority or 1) * (b.critical and 2.0 or 1.0)
        return pa > pb
    end)
    local top = {}
    for i = 1, math.min(3, #out) do
        local t = out[i]
        local base = (t.target and t.target.base) or "field"
        -- Briefing text (item 3) measured from the side's nearest owned base to the objective (the
        -- likely launch field), replacing the bare "type -> target" line.
        local origin = nearest_own_base_pos(side, t.target and t.target.pos)
        top[i] = {
            id = t.id, type = t.type, target = base,
            priority = t.priority, critical = t.critical or false,
            text = string.format("%d. %s", i, M.brief_for(t, origin)),
        }
    end
    return top
end

-- ── Record summary text (for the F-10 "My Record" display) ────────────────────
local function record_text(rec)
    local medals = {}
    for name, _ in pairs(rec.medals or {}) do medals[#medals + 1] = name end
    return string.format("%s  %s | score %d | kills %d (air %d, gnd %d, sea %d, fixed %d) | sorties %d | deaths %d%s",
        rec.name, M.RANK[rec.rank] and M.RANK[rec.rank].name or "?",
        rec.score, rec.kills.total, rec.kills.air, rec.kills.ground, rec.kills.sea, rec.kills.fixed,
        rec.sorties, rec.deaths,
        (#medals > 0) and (" | medals: " .. table.concat(medals, ", ")) or "")
end

-- ── Coalition-scoped text output (falls back to whole-server outText) ──────────
local function out_side(side, text, time)
    if trigger.action.outTextForCoalition then
        local ok = pcall(trigger.action.outTextForCoalition, side, text, time)
        if ok then return end
    end
    pcall(trigger.action.outText, text, time)
end

-- ── F-10 menu command handlers ─────────────────────────────────────────────────
function M._menu_request(side)
    local ok, miss = pcall(M.get_player_missions, side)
    local ms = (ok and miss) or {}   -- or {} → provably a table
    if #ms == 0 then
        out_side(side, "Campaign: no open gunship missions right now.", 20)
        return
    end
    local lines = { "-- Open gunship missions --" }
    for _, m in ipairs(ms) do lines[#lines + 1] = m.text end
    lines[#lines + 1] = "(To ACCEPT: from inside your aircraft use F10 > Campaign > Request Mission.)"
    out_side(side, table.concat(lines, "\n"), 25)
end

-- NOTE: a DCS coalition-scoped F-10 command cannot identify WHICH player triggered it, so "My Record"
-- shows the whole side roster. Per-player menus require group-scoped commands, which need player
-- slots/groups to exist first (goals/03 P0). Documented display-only limitation.
function M._menu_record(side)
    local roster = {}
    for _, rec in pairs(S.pilots or {}) do
        if rec.side == side then roster[#roster + 1] = record_text(rec) end
    end
    if #roster == 0 then
        out_side(side, "Campaign: no pilot records yet on this side.", 20)
        return
    end
    table.sort(roster)
    table.insert(roster, 1, "── Pilot records (this side) ──")
    out_side(side, table.concat(roster, "\n"), 25)
end

-- ── Campaign Stats (Item 2): per-side kill/loss/task/sortie tally to the coalition (display-only) ──
function M._menu_stats(side)
    out_side(side, cs.stats_text(), 30)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Player mission assignment + debrief (PILOT-F19, F9/F11/F13)
-- ═══════════════════════════════════════════════════════════════════════════════
-- `board` (task_board) is hard-required at module load (top of file); the reverse edge is deferred in
-- task_board (player_flyable_set), so there is no load cycle.

-- Group-scoped text output (falls back to whole-server outText).
local function _out_group(gid, text, time)
    time = time or 20
    if gid and trigger.action.outTextForGroup then
        local ok = pcall(trigger.action.outTextForGroup, gid, text, time)
        if ok then return end
    end
    pcall(trigger.action.outText, text, time)
end

-- Resolve a group's first unit + its player name (read-only; nil for AI / gone groups).
local function group_player(gname)
    if not gname or not Group or not Group.getByName then return nil, nil end
    local g = Group.getByName(gname)
    if not g then return nil, nil end
    local u
    local oku = pcall(function() u = g:getUnit(1) end)
    if not oku or not u then return nil, nil end
    local pn
    pcall(function() pn = u:getPlayerName() end)
    return u, pn
end

-- ── build_group_menu: this human's own F-10 assignment menu (rebuild-safe) ──────
-- Group-scoped so the command can identify WHICH player requested (a coalition command cannot —
-- documented limitation on _menu_record). Removes any prior "Campaign" submenu for the group first so
-- re-injection / re-slot never stacks duplicates. pcall-guarded end to end.
function M.build_group_menu(gid, gname, side)
    if not missionCommands or not gid then return end
    local arg = { gid = gid, gname = gname, side = side }
    pcall(function()
        if missionCommands.removeItemForGroup then
            pcall(missionCommands.removeItemForGroup, gid, { "Campaign" })
        end
        local root = missionCommands.addSubMenuForGroup(gid, "Campaign")
        missionCommands.addCommandForGroup(gid, "Request Mission", root, M._grp_request,   arg)
        missionCommands.addCommandForGroup(gid, "My Mission",      root, M._grp_mymission, arg)
        missionCommands.addCommandForGroup(gid, "My Record",       root, M._grp_record,    arg)
    end)
    cs.dbg("pilots", "group F-10 menu built for %s (gid=%s, %s)",
        tostring(gname), tostring(gid), cs.SIDE_NAME[side] or "?")
end

-- ── _grp_request: the player TAKES the top open gunship mission (PILOT-F19) ─────
-- The human binds an UNASSIGNED player-flyable board task exactly as an EECH gunship binds its primary
-- task: the task leaves the AI unassigned pool (board.assign_to_player marks it ASSIGNED with the
-- player's group as object; EECH reserves such tasks for humans in the assign pass, assign.c:220-255).
-- NO ledger consume and NO landing-slot reserve (the human airframe is not reserve hardware and occupies
-- a real DCS slot). A situational brief (target, bearing/range, task purpose) is sent on assignment.
function M._grp_request(arg)
    local gid, gname, side = arg.gid, arg.gname, arg.side
    local cur = cs.get_task(gname)
    if cur and cur.player then
        _out_group(gid, "Campaign: you already have an active mission. RTB to complete it first.")
        return
    end
    -- Top player-flyable UNASSIGNED board task for the side (critical x2 priority, assign.c:201-204).
    local best, best_p
    for _, t in ipairs(S.board_tasks or {}) do
        if t.state == "UNASSIGNED" and t.side == side and M.PLAYER_FLYABLE[t.type] then
            local p = (t.priority or 1) * (t.critical and 2.0 or 1.0)
            if not best or p > best_p then best, best_p = t, p end
        end
    end
    if not best then
        _out_group(gid, "Campaign: no gunship missions available right now - check back shortly.")
        cs.dbg("pilots", "player %s Request Mission: none available (side=%s)",
            tostring(gname), cs.SIDE_NAME[side] or "?")
        return
    end
    if not board.assign_to_player(best, gname, gid) then
        _out_group(gid, "Campaign: that mission was just taken - try again.")
        return
    end
    -- Snapshot the sortie score/damage baseline so the LAND debrief can score THIS mission.
    local u, pname = group_player(gname)
    if pname then
        local rec = get_or_create(pname, side)
        rec.sortie_score_start = rec.score
        rec.sortie_damaged     = false
    end
    local origin
    if u then pcall(function() origin = u:getPosition().p end) end
    origin = origin or nearest_own_base_pos(side, best.target and best.target.pos)
    _out_group(gid, "=== MISSION ASSIGNED ===\n" .. M.brief_for(best, origin) ..
        "\nReturn to base after completing the mission to log it.", 30)
    cs.dbg("pilots", "player %s ASSIGNED task #%d %s vs %s (left AI pool, no ledger/slot)",
        tostring(gname), best.id, best.type, (best.target and best.target.base) or "field")
end

-- ── _grp_mymission: re-show the player's current mission brief ─────────────────
function M._grp_mymission(arg)
    local gid, gname, side = arg.gid, arg.gname, arg.side
    local cur = cs.get_task(gname)
    if not cur or not cur.player then
        _out_group(gid, "Campaign: you have no active mission. Use Request Mission to accept one.")
        return
    end
    local origin
    local u = group_player(gname)
    if u then pcall(function() origin = u:getPosition().p end) end
    origin = origin or nearest_own_base_pos(side, cur.target_pos)
    _out_group(gid, "=== CURRENT MISSION ===\n" .. M.brief_for(cur, origin), 25)
end

-- ── _grp_record: per-PLAYER record (group scope identifies the pilot) ──────────
function M._grp_record(arg)
    local gid, gname = arg.gid, arg.gname
    local _, pname = group_player(gname)
    local rec = pname and S.pilots and S.pilots[pname]
    if not rec then
        _out_group(gid, "Campaign: no record yet - fly a mission first.")
        return
    end
    _out_group(gid, record_text(rec), 25)
end

-- ── on_hit: Purple-Heart damage tracking (PILOT-F13, play_md.c:1245) ───────────
-- Called from reaction's S_EVENT_HIT branch. Marks the target player's record as damaged-this-sortie;
-- if the pilot survives to the LAND debrief the Purple Heart is awarded. Read-only on the player unit,
-- inert for AI targets (no getPlayerName).
function M.on_hit(event)
    if not event or event.id ~= world.event.S_EVENT_HIT then return end
    local tgt = event.target
    if not tgt or not tgt.getPlayerName then return end
    local pname
    local ok = pcall(function() pname = tgt:getPlayerName() end)
    if not ok or not pname then return end
    local rec = S.pilots and S.pilots[pname]
    if not rec then
        local side; pcall(function() side = tgt:getCoalition() end)
        rec = get_or_create(pname, side)
    end
    if not rec.sortie_damaged then
        rec.sortie_damaged = true
        cs.dbg("pilots", "%s took damage this sortie (S_EVENT_HIT) -> Purple Heart eligible at debrief", pname)
    end
end

-- ── on_debrief: per-sortie mission termination for a PLAYER (PILOT-F9) ──────────
-- Called from reaction's S_EVENT_LAND branch when a human lands completing their registered task.
-- Mirrors notify_gunship_entity_mission_terminated (helicop.c:693-836) TASK_COMPLETED_SUCCESS path:
--   points = task score (port proxy: career-score delta earned since assignment, kills accrue via
--            on_kill, mobile.c:416-424); inc experience (already added live) + inc missions_flown;
--   award promotion + valour (award_after_score, the cumulative reward spine, F8/F10, helicop.c:750-756);
--   AIR MEDAL on a 3-success streak (play_md.c:1304-1359); PURPLE HEART if damaged-but-survived
--   (play_md.c:1245-1296). Read-only on the player unit throughout (guardrail).
function M.on_debrief(u, task, assessment)
    if not u or not u.getPlayerName or not task then return end
    local pname
    local ok = pcall(function() pname = u:getPlayerName() end)
    if not ok or not pname then return end
    local side
    pcall(function() side = u:getCoalition() end)
    local rec = get_or_create(pname, side)

    local mission_points = rec.score - (rec.sortie_score_start or rec.score)
    if mission_points < 0 then mission_points = 0 end
    -- Item 3: EECH award_points_for_task_completion (task.c:508-543) scales task points by the
    -- completion outcome — FAILURE 0, PARTIAL points>>2 (quarter), SUCCESS full. The port's career
    -- score accrues from kills (on_kill), so we apply the multiplier to THIS sortie's displayed points
    -- (documented proxy: there is no separate task-points award to scale). Defaults to success.
    local task_result = (assessment and assessment.result) or "success"
    if     task_result == "failure" then mission_points = 0
    elseif task_result == "partial" then mission_points = math.floor(mission_points / 4) end
    rec.missions_flown = (rec.missions_flown or 0) + 1   -- inc_player_log_missions_flown (helicop.c:729)

    award_after_score(rec)   -- promotion + valour on cumulative score (announces itself)

    local awarded = {}
    -- AIR MEDAL: success → streak++, award + reset at AIR_MEDAL_STREAK (play_md.c:1320-1326). Item 3:
    -- a PARTIAL/FAILURE outcome does not extend the success streak (only a SUCCESS advances it).
    if task_result == "success" then
        rec.air_medal_counter = (rec.air_medal_counter or 0) + 1
    end
    if rec.air_medal_counter >= M.AIR_MEDAL_STREAK then
        rec.medals["Air Medal"] = (rec.medals["Air Medal"] or 0) + 1
        rec.air_medal_counter = 0
        awarded[#awarded + 1] = "Air Medal"
    end
    -- PURPLE HEART: damaged this sortie AND survived to land (play_md.c:1273-1287).
    local alive = false
    pcall(function() alive = u:isExist() end)
    if rec.sortie_damaged and alive then
        rec.medals["Purple Heart"] = (rec.medals["Purple Heart"] or 0) + 1
        awarded[#awarded + 1] = "Purple Heart"
    end

    rec.sortie_damaged     = false
    rec.sortie_score_start = rec.score   -- baseline for the next sortie

    local msg = string.format("MISSION COMPLETE - %s: %s | +%d pts (score %d) | missions %d",
        pname, task.task_type or task.type or "sortie", mission_points, rec.score, rec.missions_flown)
    if #awarded > 0 then msg = msg .. " | AWARDED: " .. table.concat(awarded, ", ") end
    info(msg)
    cs.dbg("pilots", "DEBRIEF %s: task=%s +%d pts score=%d missions=%d awards=[%s]",
        pname, tostring(task.task_type or task.type), mission_points, rec.score, rec.missions_flown,
        table.concat(awarded, ","))
    local gid
    pcall(function() gid = u:getGroup():getID() end)
    _out_group(gid, msg, 20)
end

-- ── award_campaign_medals: campaign medal at win declaration (PILOT-F14) ────────
-- Called from win_condition.finish(). EECH awards the campaign/theatre medal to the player log at
-- session complete (award_campaign_medal, play_md.c:1062; campaign.c:1128). Port: one "Campaign" medal
-- per pilot who flew at least one sortie (both sides took part in the campaign).
function M.award_campaign_medals(winner, log_fn)
    log_fn = log_fn or function() end
    local n = 0
    for _, rec in pairs(S.pilots or {}) do
        if (rec.sorties or 0) > 0 then
            rec.medals = rec.medals or {}
            rec.medals["Campaign"] = (rec.medals["Campaign"] or 0) + 1
            n = n + 1
        end
    end
    if n > 0 then
        log_fn(string.format("pilots: campaign medal awarded to %d participating pilot(s)", n))
        cs.dbg("pilots", "campaign medal awarded to %d participating pilot(s) (winner=%s)",
            n, cs.SIDE_NAME[winner] or "?")
    end
end

-- ── F-10 menu build (once, pcall-guarded so a missing API degrades silently) ───
function M.build_menus(log_fn)
    log_fn = log_fn or function() end
    if not missionCommands then log_fn("pilots: missionCommands unavailable — F-10 menu skipped"); return end
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local ok = pcall(function()
            local root = missionCommands.addSubMenuForCoalition(side, "Campaign")
            missionCommands.addCommandForCoalition(side, "Request Mission", root, M._menu_request, side)
            missionCommands.addCommandForCoalition(side, "My Record",       root, M._menu_record,  side)
            missionCommands.addCommandForCoalition(side, "Campaign Stats",  root, M._menu_stats,   side)  -- Item 2
        end)
        if not ok then
            log_fn("pilots: F-10 menu build failed for side " .. tostring(side))
            cs.dbg("pilots", "F-10 menu build FAILED for side %s", cs.SIDE_NAME[side] or tostring(side))
        end
    end
    log_fn("pilots: F-10 'Campaign' menu registered (Request Mission / My Record)")
    cs.dbg("pilots", "F-10 'Campaign' menu registered")
end

-- ── init (restore-safe: never clobbers an existing S.pilots) ──────────────────
function M.init(log_fn)
    log_fn = log_fn or function() end
    S.pilots = S.pilots or {}
    local n = 0
    for _ in pairs(S.pilots) do n = n + 1 end
    log_fn(string.format("pilots init — career substrate ready (%d existing record(s)); dormant until player slots exist", n))
    cs.dbg("pilots", "init: career substrate ready, %d existing record(s)", n)
end

return M
