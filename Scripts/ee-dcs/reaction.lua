-- reaction.lua
-- EECH source: aphavoc/source/ai/highlevl/reaction.c
--
-- create_task_assigned_reactionary_tasks (line 97): on an OFFENSIVE keysite task being assigned
--   (GROUND_STRIKE / OCA_STRIKE / OCA_SWEEP / RECON), the OBJECTIVE side scrambles defensive air:
--   create_reaction_to_offensive_keysite_task_assigned (line 217):
--     if keysite requires_cap  and not already CAP-tasked  → create_cap_task   (CAP_DURATION)
--     if keysite requires_barcap and not already BARCAP-tasked → create_barcap_task at
--        objective + normalise(attacker - objective) * BARCAP_OFFSET (CAP_DURATION)
--
-- create_task_completed_reactionary_tasks (line 152): on RECON/BDA/STRIKE completing with SUCCESS:
--   create_reaction_to_recon_task_completed (line 314):
--     KEYSITE objective:
--       if create_sead_tasks_around_keysite() > 1 → BREAK (suppress: strike into SAMs aborted)
--       if ALIVE:
--         if troop_insertion_target and eff < min and not tasked → T.I. (+ backup defender T.I.)
--         if oca_target      → OCA_STRIKE (dedup) + OCA_SWEEP (dedup)
--         if ground_strike_target and eff >= min → GROUND_STRIKE
--     GROUP objective:
--       ANTI_AIRCRAFT group → create_sead_task
--       frontline group     → create_bai_task
--   create_reaction_to_strike_task_completed (line 609):
--     if ground_strike_target and eff >= min → another GROUND_STRIKE ; else if recon_target → BDA
--
-- Constants (reaction.c): BARCAP_OFFSET = 6.0*KILOMETRE = 6000 m (line 293);
--   CAP_DURATION = 30.0*ONE_MINUTE = 1800 s (lines 248/298).
--
-- DCS mapping. "task assigned" = S_EVENT_BIRTH of the mission group; "task completed SUCCESS" =
-- the mission group RTBs (S_EVENT_LAND) — a shot-down mission never lands, so it is a FAILURE and
-- triggers NO follow-on (this is the H1 fix: the old port fired follow-ons on group WIPEOUT, which
-- is EECH's failure case, not success). Every mission registers its exact objective in
-- campaign_state.active_tasks at spawn, so reactions target the RIGHT keysite (H5 fix), not the
-- base nearest the attacker's launch field.

local cs     = require("campaign_state")
local supply = require("supply")
local ks     = require("keysite")
local imap_m = require("imap")
local fow_m  = require("fog_of_war")
local inst_m = require("installations")
local config = require("config")
local S      = cs.S
local M      = {}

-- ── EECH constants ─────────────────────────────────────────────────────────────
local BARCAP_OFFSET      = 6000   -- m; reaction.c:293 (6.0 * KILOMETRE)
local CAP_DURATION       = 1800   -- s; reaction.c:248/298 (30.0 * ONE_MINUTE)
local MINIMUM_EFFICIENCY = cs.MINIMUM_EFFICIENCY   -- 0.3; eech ks_dbase.c minimum_efficiency (all types)
local KEYSITE_SEAD_RANGE = 4000   -- m; MAX_KEYSITE_SEAD_RANGE (create_sead_tasks_around_keysite)
local MAX_KEYSITE_SEAD   = 3      -- MAX_KEYSITE_SEAD_COUNT

-- ── Per-keysite flags — kind-aware keysite_database rows (ks_dbase.c) ──────────
-- EECH keys every reaction decision off keysite_database[sub_type].<flag>. The port resolves the
-- keysite kind from campaign state and returns the matching ks_dbase row:
--   basing keysites   → AIRBASE (ks_dbase.c:114-129) or FARP (:255-270), both requires_cap TRUE;
--   installation keysites → the ks_dbase row per zone kind (installations.flags_for_kind).
-- AIRBASE row: requires_cap T:120, requires_barcap F:121, oca T:124, recon T:125, gs T:126, ti T:128.
-- FARP    row: requires_cap T:261, requires_barcap F:262, oca F:265, recon T:266, gs T:267, ti T:269.
-- BARCAP is a CARRIER/ANCHORAGE behaviour (ks_dbase.c ANCHORAGE:168), never airbases/FARPs.
-- The OLD proxy returned the AIRBASE row for EVERYTHING — wrong for FARPs (would OCA a FARP whose
-- oca_target is FALSE) and for installation objectives (whole reaction chain assumed airbase rows).
-- Now every objective's true flags drive react_recon_complete_keysite.
local AIRBASE_FLAGS = {
    requires_cap = true,  requires_barcap = false, oca_target = true,  ground_strike_target = true,
    troop_insertion_target = true, recon_target = true,   -- ks_dbase.c:120-128 AIRBASE row
}
local FARP_FLAGS = {
    requires_cap = true,  requires_barcap = false, oca_target = false, ground_strike_target = true,
    troop_insertion_target = true, recon_target = true,   -- ks_dbase.c:261-269 FARP row
}
local function keysite_flags(base)
    local bk = S.base_kind and S.base_kind[base]
    if bk == "farp"    then return FARP_FLAGS end
    if bk == "airbase" then return AIRBASE_FLAGS end
    -- installation keysite: read its zone kind → ks_dbase row (installations.flags_for_kind).
    local rec = S.keysites and S.keysites[base]
    if rec then
        if rec.kind == "airbase" then return AIRBASE_FLAGS end   -- "AB-<name>" airfield-assets keysite
        local f = inst_m.flags_for_kind(rec.kind)
        if f then return f end
    end
    -- real DCS airbase not tagged in base_kind (auto/no-zones theatre) → AIRBASE row.
    return AIRBASE_FLAGS
end

-- ── Aircraft configuration (hoisted to config.lua) ────────────────────────────
-- escort = the CAP/BARCAP fighter; heli = the BDA overflight airframe (config bda_heli).
local AC = {}
for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
    AC[side] = {
        country = config.C.countries[side],
        escort  = config.C.types.aircraft[side].escort,
        heli    = config.C.types.aircraft[side].bda_heli,
    }
end

-- Offensive task types that make the objective side scramble CAP/BARCAP (reaction.c:97 switch).
local OFFENSIVE = {
    ground_strike = true, oca_strike = true, oca_sweep = true, recon = true,
}

-- ── Group-name → task_type classifier ────────────────────────────────────────
-- Aligns with the names set by the spawner modules (Cluster A/B renames).
local function classify(gname)
    if gname:match("^KStrike%-")    then return "ground_strike" end
    if gname:match("^OCAStrike%-")  then return "oca_strike"    end
    if gname:match("^OCA%-Sweep%-") then return "oca_sweep"     end
    if gname:match("^Recon%-")      then return "recon"         end
    if gname:match("^BDA%-")        then return "bda"           end
    if gname:match("^CAP%-")        then return "cap"           end
    if gname:match("^BARCAP%-")     then return "barcap"        end
    return nil
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function nearest_base(owner_side, pos)
    local best, best_d2 = nil, math.huge
    for name, owner in pairs(S.base_owner) do
        if owner == owner_side then
            local bpos = S.base_pos[name]
            if bpos then
                local dx = pos.x - bpos.x; local dz = pos.z - bpos.z
                local d2 = dx*dx + dz*dz
                if d2 < best_d2 then best_d2 = d2; best = name end
            end
        end
    end
    return best
end

-- Nearest owned base of ANY side to a position = its FOW sector (get_local_sector_entity). Used by
-- the SEAD-ring per-group FOW gate and the counter-battery reaction.
local function nearest_any_base(pos)
    local best, best_d2 = nil, math.huge
    for name, bpos in pairs(S.base_pos) do
        if S.base_owner[name] then
            local dx = pos.x - bpos.x; local dz = pos.z - bpos.z
            local d2 = dx*dx + dz*dz
            if d2 < best_d2 then best_d2 = d2; best = name end
        end
    end
    return best
end

local function efficiency_of(base)
    return (S.base_efficiency and S.base_efficiency[base])
        or (S.base_health and S.base_health[base])
        -- installation keysites: eff = strength/max applies to EVERY keysite type (ks_float.c:260-275);
        -- without this, strike-complete follow-ons read a destroyed installation as eff=1.0 and
        -- re-strike it forever.
        or (S.keysites and S.keysites[base] and S.keysites[base].health)
        or 1.0
end

-- Recycle-on-expiry guard shared with supply.make_land_handler (S._recycled). Credits back ONLY the
-- LIVE survivors of the group at expiry — a flight shot down before its expiry/loiter timer is
-- already in the regen queue (regen.make_dead_handler), so crediting reserve for it too would
-- double-count and soften attrition on exactly the flights that die most (MED-1 fix). A group that
-- RTB'd already had its survivors credited by the land handler (which sets S._recycled), so this
-- no-ops for it. Airborne-at-expiry (despawned below) → credit its live units.
local function recycle_once(gname, side, role, grp)
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
    if n > 0 then supply.recycle_side(side, role, n) end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Defensive spawns: CAP / BARCAP
-- ═══════════════════════════════════════════════════════════════════════════════
-- The CAP waypoint carries a ComboTask: EngageTargets (intercept) + Orbit (loiter on-station).
-- The Orbit keeps the flight on station for the whole CAP_DURATION (EECH's on-station time) rather
-- than flying through and RTB'ing in minutes. The expiry timer despawns + recycles it (no Land wp).
local function cap_route(ab, ab_pos, bx, by, orbit_x, orbit_z)
    return { points = {
        {type="TakeOff",action="From Parking Area",airdromeId=ab:getID(),
         alt=ab_pos.y,alt_type="BARO",speed=0,ETA=0,ETA_locked=true,x=bx,y=by,name="Depart",formation_template=""},
        {type="Turning Point",action="Turning Point",alt=7000,alt_type="BARO",speed=250,
         ETA=0,ETA_locked=false,x=orbit_x,y=orbit_z,name="CAP",formation_template="",
         task={id="ComboTask",params={tasks={
           [1]={number=1,auto=true,id="EngageTargets",enabled=true,
             params={maxDist=60000,priority=0,targetTypes={"Air"}}},
           [2]={number=2,auto=false,id="Orbit",enabled=true,
             params={pattern="Race-Track", speed=250, altitude=7000,
                     point={x=orbit_x,y=orbit_z}, point2={x=orbit_x+18000,y=orbit_z}}},
         }}}},
    }}
end

-- Schedule CAP_DURATION expiry: recycle the escort back to reserve (EECH replace_into_force_info
-- at task expiry) and despawn if still airborne. If it already RTB'd, the land handler recycled it
-- and the shared once-guard makes this a no-op.
local function schedule_cap_expiry(grp, gname, side, duration)
    duration = duration or CAP_DURATION
    local my_gen = _DMT_GEN
    timer.scheduleFunction(function()
        if _DMT_GEN ~= my_gen then return nil end   -- stale generation: reset.nuke already cleaned up
        recycle_once(gname, side, "escort", grp)   -- credits only live survivors (dead → regen owns it)
        ks.release_slot(gname)                     -- Cluster 5: free the base landing slot on despawn
        if grp and grp:isExist() then grp:destroy() end
        cs.clear_task(gname)   -- clear registry so the dedup guard frees up for the next reaction
        return nil
    end, nil, timer.getTime() + duration)
end

-- spawn_cap(defending_side, base_name, log_fn [, duration]): duration defaults to CAP_DURATION
-- (reaction.c:248, 30 min) for the offensive-task-assigned CAP; the under-attack CAP passes its own
-- 15-min duration (keysite.c:915). Priority/force-assign semantics (keysite.c:915/921) are moot in the
-- port (defensive CAP is a DIRECT spawn, not a board-priority task).
local function spawn_cap(defending_side, base_name, log_fn, duration)
    duration = duration or CAP_DURATION
    -- Consume from the DEFENDED base's own ledger (Cluster 4): the CAP is flown by fighters resident
    -- at that keysite (assign.c). No resident escort → no CAP (force conservation with location).
    if not supply.consume_base(base_name, "escort", 1) then
        cs.dbg("reaction", "%s spawn_cap ABORT at %s: no escort stock", cs.SIDE_NAME[defending_side], base_name)
        return false
    end
    local cfg = AC[defending_side]
    local ab  = Airbase.getByName(base_name)
    if not ab then
        supply.recycle_base(base_name, "escort", 1)
        cs.dbg("reaction", "%s spawn_cap ABORT at %s: no Airbase -> refunded", cs.SIDE_NAME[defending_side], base_name)
        return false
    end
    local ab_pos = ab:getPosition().p
    local bx, by = cs.wp_xy(ab_pos)
    local sid    = cs.next_id()
    local gname  = string.format("CAP-%d-%d", defending_side, sid)

    local grp = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
        name = gname, task = "CAP", hidden = false, airdromeId = ab:getID(),
        units = {{ name=gname.."-1", type=cfg.escort, skill="High",
            x=ab_pos.x, y=ab_pos.z, alt=ab_pos.y, alt_type="BARO", speed=0, heading=0,
            payload={fuel=5200,flare=120,chaff=120,gun=100} }},
        route = cap_route(ab, ab_pos, bx, by, bx, by),
    })
    if grp then
        -- Cluster 5: a scrambled CAP occupies a landing slot at the defended base so it counts
        -- against basing capacity (visible to the board's assignment gate). PROXY: defensive
        -- scrambles are NOT hard-gated — the base must always be defended, so reaction stays
        -- responsive even at capacity (EECH's landing arbitration would queue/hold; spec 07 TASK-F23).
        ks.reserve_slot(base_name, gname)
        cs.register_task(gname, { task_type="cap", side=defending_side, target_base=base_name,
                                  target_pos=S.base_pos[base_name], born_time=timer.getTime() })
        schedule_cap_expiry(grp, gname, defending_side, duration)
        log_fn(string.format("reaction CAP #%d defending %s (dur=%ds)", sid, base_name, duration))
        cs.dbg("reaction", "%s CAP #%d spawned defending %s (dur=%ds)", cs.SIDE_NAME[defending_side], sid, base_name, duration)
        return true
    end
    supply.recycle_base(base_name, "escort", 1)  -- refund: CAP spawn failed
    cs.dbg("reaction", "%s CAP #%d SPAWN FAILED at %s -> refunded", cs.SIDE_NAME[defending_side], sid, base_name)
    return false
end

local function spawn_barcap(defending_side, obj_pos, attacker_pos, base_name, log_fn)
    local dx = attacker_pos.x - obj_pos.x
    local dz = attacker_pos.z - obj_pos.z
    local len = math.sqrt(dx*dx + dz*dz)
    if len < 1.0 then return false end
    dx, dz = dx/len, dz/len
    local bp_x = obj_pos.x + dx * BARCAP_OFFSET
    local bp_z = obj_pos.z + dz * BARCAP_OFFSET

    if not supply.consume_base(base_name, "escort", 1) then
        cs.dbg("reaction", "%s spawn_barcap ABORT at %s: no escort stock", cs.SIDE_NAME[defending_side], base_name)
        return false
    end
    local cfg = AC[defending_side]
    local ab  = Airbase.getByName(base_name)
    if not ab then
        supply.recycle_base(base_name, "escort", 1)
        cs.dbg("reaction", "%s spawn_barcap ABORT at %s: no Airbase -> refunded", cs.SIDE_NAME[defending_side], base_name)
        return false
    end
    local ab_pos = ab:getPosition().p
    local bx, by = cs.wp_xy(ab_pos)
    local sid    = cs.next_id()
    local gname  = string.format("BARCAP-%d-%d", defending_side, sid)

    local grp = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
        name = gname, task = "CAP", hidden = false, airdromeId = ab:getID(),
        units = {{ name=gname.."-1", type=cfg.escort, skill="High",
            x=ab_pos.x, y=ab_pos.z, alt=ab_pos.y, alt_type="BARO", speed=0, heading=0,
            payload={fuel=5200,flare=120,chaff=120,gun=100} }},
        route = cap_route(ab, ab_pos, bx, by, bp_x, bp_z),
    })
    if grp then
        ks.reserve_slot(base_name, gname)   -- Cluster 5: occupy a landing slot (responsive proxy, see spawn_cap)
        cs.register_task(gname, { task_type="barcap", side=defending_side, target_base=base_name,
                                  target_pos=S.base_pos[base_name], born_time=timer.getTime() })
        schedule_cap_expiry(grp, gname, defending_side)
        log_fn(string.format("reaction BARCAP #%d at (%.0f,%.0f) dur=%ds", sid, bp_x, bp_z, CAP_DURATION))
        cs.dbg("reaction", "%s BARCAP #%d spawned at (%.0f,%.0f) from %s", cs.SIDE_NAME[defending_side], sid, bp_x, bp_z, base_name)
        return true
    end
    supply.recycle_base(base_name, "escort", 1)  -- refund: BARCAP spawn failed
    cs.dbg("reaction", "%s BARCAP #%d SPAWN FAILED from %s -> refunded", cs.SIDE_NAME[defending_side], sid, base_name)
    return false
end

-- ── Dedup guard: existing CAP/BARCAP over an objective base for the defender ──
-- Mirrors entity_is_object_of_task(objective, TASK_*, objective_side). Independent per type.
local function has_defensive(base_name, defending_side, task_type)
    return cs.has_task_against(task_type, base_name, defending_side)
end

-- ── react_to_offense: create_reaction_to_offensive_keysite_task_assigned (reaction.c:217) ──
-- objective = the target keysite (owned by the defending side). CAP/BARCAP scramble THERE.
local function react_to_offense(objective_base, objective_pos, attacker_pos, log_fn)
    local defending_side = S.base_owner[objective_base]
    if defending_side ~= coalition.side.BLUE and defending_side ~= coalition.side.RED then return end
    local flags = keysite_flags(objective_base)

    local cap_dup, barcap_dup = has_defensive(objective_base, defending_side, "cap"),
                                 has_defensive(objective_base, defending_side, "barcap")
    cs.dbg("reaction", "%s react_to_offense at %s: requires_cap=%s(dup=%s) requires_barcap=%s(dup=%s)",
        cs.SIDE_NAME[defending_side], objective_base, tostring(flags.requires_cap), tostring(cap_dup),
        tostring(flags.requires_barcap), tostring(barcap_dup))
    if flags.requires_cap and not cap_dup then
        spawn_cap(defending_side, objective_base, log_fn)
    end
    if flags.requires_barcap and not barcap_dup then
        spawn_barcap(defending_side, objective_pos, attacker_pos, objective_base, log_fn)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Under-attack defensive CAP: notify_keysite_structure_under_attack (keysite.c:854-939)
-- ═══════════════════════════════════════════════════════════════════════════════
-- EECH's SECOND defensive-CAP path (distinct from the task-assigned reaction above): when a keysite's
-- STRUCTURE actually takes damage, the owning side scrambles a defensive CAP even if NO task was ever
-- registered against it. This is the path that covers a HUMAN PLAYER's strike (MP-critical) — a
-- player's bombs register no AI task, so only the structure-damage notification defends the base.
-- EECH behaviour (keysite.c:854-939):
--   • friendly-fire ignored (aggressor side == keysite side, :883-901);
--   • gated by the ASSIST_TIMER (:903): only if no assistance request is pending — this dedups
--     sustained bombardment so CAPs don't stack. On firing, ASSIST_TIMER is set to
--     DEFAULT_KEYSITE_ASSISTANCE_REQUEST_TIMER = ONE_MINUTE + sfrand1()*20 (keysite.h:67) = 60±20 s;
--   • only if the aggressor is an aircraft (:907) and the keysite is not already CAP-tasked (:909);
--   • create_cap_task(side, keysite, aggressor, TRUE, 10.0, 15.0*ONE_MINUTE, ...) — priority 10.0,
--     duration 15 min (keysite.c:915). NB: this is the CAP's OWN duration, NOT the 30-min CAP_DURATION
--     of the offensive-reaction path (reaction.c:248) — we use the keysite.c value.
-- Port mapping onto the existing CAP machinery: the 60±20 s assist timer is BOTH the dedup window and,
-- in the port's event model, the scramble delay (assistance arrives after that time). The CAP is
-- spawned with UNDER_ATTACK_CAP_DURATION and blocks re-CAP via has_task_against("cap") for its life
-- (matching EECH's not-already-CAP-tasked gate). Wired from keysite.strike_damage (deterministic
-- strike on a base) and installations.register_static_death (an airfield-asset building dying — covers
-- a HUMAN bombing airfield structures, MP-critical); inert from installations.damage (installation
-- keysites have requires_cap FALSE / no base owner). The old apply_kill_damage caller was removed in
-- Cluster G (generic kill-proximity bleed deleted — buildings dying IS the EECH under-attack trigger).
local UNDER_ATTACK_CAP_DURATION = 15 * 60   -- s; keysite.c:915 (15.0 * ONE_MINUTE)

-- DEFAULT_KEYSITE_ASSISTANCE_REQUEST_TIMER = ONE_MINUTE + sfrand1()*20 (keysite.h:67). sfrand1 ∈ [-1,1].
local function assist_timer_delay()
    return 60.0 + (math.random() * 2.0 - 1.0) * 20.0
end

function M.on_keysite_under_attack(base_name, log_fn)
    log_fn = log_fn or function() end
    if not base_name then return end
    local defending_side = S.base_owner[base_name]
    -- Non-basing keysites (installation names not in base_owner) and neutral sites: no CAP owner.
    if defending_side ~= coalition.side.BLUE and defending_side ~= coalition.side.RED then return end
    -- Only keysites that require CAP defend this way (keysite.c:909 → keysite_database.requires_cap).
    if not keysite_flags(base_name).requires_cap then return end

    -- Assist-timer dedup (keysite.c:903): while a request is pending, no new scramble.
    S.keysite_assist_timer = S.keysite_assist_timer or {}
    local now = timer.getTime()
    if (S.keysite_assist_timer[base_name] or 0) > now then
        cs.dbg("reaction", "under-attack CAP SKIP at %s: assist timer pending (%.0fs left)",
            base_name, S.keysite_assist_timer[base_name] - now)
        return
    end
    local delay = assist_timer_delay()
    S.keysite_assist_timer[base_name] = now + delay
    cs.dbg("reaction", "%s keysite %s STRUCTURE UNDER ATTACK: assist timer %.0fs → scramble CAP (keysite.c:854-939)",
        cs.SIDE_NAME[defending_side], base_name, delay)

    -- Scramble after the assist-timer delay (keysite.c:915 create_cap_task, 15-min duration).
    local my_gen = _DMT_GEN
    timer.scheduleFunction(function()
        if _DMT_GEN ~= my_gen then return nil end            -- stale generation: reset.nuke cleaned up
        if S.base_owner[base_name] ~= defending_side then return nil end   -- base flipped in the interim
        if has_defensive(base_name, defending_side, "cap") then            -- keysite.c:909 not-already-CAP
            cs.dbg("reaction", "under-attack CAP at %s: already CAP-tasked, no scramble", base_name)
            return nil
        end
        if spawn_cap(defending_side, base_name, log_fn, UNDER_ATTACK_CAP_DURATION) then
            log_fn(string.format("reaction: %s under attack → defensive CAP scrambled (dur=%ds)",
                base_name, UNDER_ATTACK_CAP_DURATION))
        end
        return nil
    end, nil, now + delay)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- SEAD suppression gate: create_sead_tasks_around_keysite (reaction.c:386, highlevl.c:2576)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Count enemy AA groups within KEYSITE_SEAD_RANGE of the objective; spawn SEAD against up to
-- MAX_KEYSITE_SEAD of them. Returns the count. Caller aborts the strike follow-ons if it is > 1
-- (strike into intact SAM coverage is suppressed until SEAD clears the way).
local function is_aa_unit(u)
    local desc = u:getDesc()
    local a = desc and desc.attributes
    return a and (a["SAM"] or a["AAA"] or a["SR SAM"] or a["MR SAM"] or a["LR SAM"] or a["IR Guided SAM"])
end

local function create_sead_around_keysite(attacking_side, objective_pos, log_fn)
    -- SEAD is flown by the ATTACKER against the objective's (enemy) air defences.
    local aa_side = cs.ENEMY[attacking_side]
    local grps = coalition.getGroups(aa_side)
    if not grps then return 0 end
    local r2 = KEYSITE_SEAD_RANGE * KEYSITE_SEAD_RANGE
    local cas_m = require("cas_bai_sead")
    local count, n_fogged = 0, 0
    for _, grp in ipairs(grps) do
        if count >= MAX_KEYSITE_SEAD then break end
        if grp and grp:isExist() then
            local u = grp:getUnit(1)
            if u and u:isExist() and is_aa_unit(u) then
                local gp = u:getPosition().p
                local dx = gp.x - objective_pos.x
                local dz = gp.z - objective_pos.z
                if dx*dx + dz*dz <= r2 then
                    -- Per-group FOW gate (highlevl.c:2653): only SEAD an AA group whose OWN sector is
                    -- revealed to the attacker (FOW > 0.25*max) — do not SEAD SAMs we cannot yet see.
                    -- fow_m.get returns raw/FOW_MAX (normalised 0..1), so the gate is a bare > 0.25.
                    local sect = nearest_any_base(gp)
                    local fv   = (sect and fow_m.get(sect, attacking_side)) or 0.0
                    if fv > 0.25 then
                        if cas_m.spawn_sead_against(attacking_side, grp, log_fn, true) then   -- highlevl.c:2659 critical=TRUE
                            count = count + 1
                        end
                    else
                        n_fogged = n_fogged + 1
                    end
                end
            end
        end
    end
    if n_fogged > 0 then
        cs.dbg("reaction", "%s SEAD gate: %d in-range AA skipped (sector fogged, FOW<=0.25, highlevl.c:2653)",
            cs.SIDE_NAME[attacking_side], n_fogged)
    end
    if count > 0 then
        log_fn(string.format("reaction SEAD gate: %d AA within %dm of objective → SEAD", count, KEYSITE_SEAD_RANGE))
    end
    cs.dbg("reaction", "%s SEAD gate: %d SEAD tasks created within %dm of objective (cap=%d, suppress follow-ons if >1)",
        cs.SIDE_NAME[attacking_side], count, KEYSITE_SEAD_RANGE, MAX_KEYSITE_SEAD)
    return count
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Completion reactions
-- ═══════════════════════════════════════════════════════════════════════════════

-- Keysite owner + position resolvers that also cover non-airbase INSTALLATION objectives (which live
-- in S.keysites, not S.base_owner/S.base_pos). Installations reach here once Cluster I removed the
-- pick_targets carve-out: a recon_target=TRUE installation (refinery/power/radar/military_base) takes
-- the recon fork, so its recon completion drives this same reaction with the installation's true flags.
-- Wave 1: these three now delegate to the unified keysite accessor (keysite.get), which resolves the
-- basing (S.base_owner/pos/health) and installation (S.keysites) namespaces with the SAME precedence
-- these helpers used to hand-roll. Behaviour is identical, including the "unknown base → nil owner/pos,
-- 1.0 health" tails (ks.get returns nil for an unknown name; the `or 1.0` reproduces keysite_health's).
local function keysite_owner(base)
    local v = ks.get(base)
    return v and v.owner
end
local function keysite_pos(base)
    local v = ks.get(base)
    return v and v.pos
end
local function keysite_health(base)
    local v = ks.get(base)
    return v and v.health or 1.0
end

-- create_reaction_to_recon_task_completed — KEYSITE objective branch (reaction.c:375-520)
local function react_recon_complete_keysite(attacking_side, target_base, log_fn)
    if not target_base then return end
    if keysite_owner(target_base) == attacking_side then return end   -- objective must be enemy (line 353)

    local objective_pos = keysite_pos(target_base)
    local is_basing     = S.base_owner[target_base] ~= nil            -- real airbase/FARP (capturable)
    local flags = keysite_flags(target_base)                          -- kind-aware ks_dbase row
    local eff   = efficiency_of(target_base)

    -- SEAD gate (reaction.c:386): if surrounding AA > 1 → abort follow-ons, create SEAD instead.
    if objective_pos and create_sead_around_keysite(attacking_side, objective_pos, log_fn) > 1 then
        log_fn(string.format("reaction: %s defended by SAMs → strike suppressed, SEAD only", target_base))
        cs.dbg("reaction", "%s recon-complete(keysite) at %s SUPPRESSED: SAM gate", cs.SIDE_NAME[attacking_side], target_base)
        return
    end

    -- INT_TYPE_ALIVE gate (reaction.c:391): a destroyed keysite gets no new strikes.
    if keysite_health(target_base) <= cs.HEALTH_DESTROYED then
        log_fn(string.format("reaction: %s already destroyed → no follow-on", target_base))
        cs.dbg("reaction", "%s recon-complete(keysite) at %s ABORT: destroyed", cs.SIDE_NAME[attacking_side], target_base)
        return
    end

    cs.dbg("reaction", "%s recon-complete(keysite) at %s: eff=%.2f basing=%s ti_target=%s oca_target=%s ground_target=%s",
        cs.SIDE_NAME[attacking_side], target_base, eff, tostring(is_basing), tostring(flags.troop_insertion_target),
        tostring(flags.oca_target), tostring(flags.ground_strike_target))

    local atk_m   = require("attack_waves")
    local cas_m   = require("cas_bai_sead")
    local troop_m = require("troop")

    -- Troop insertion (reaction.c:402) — efficiency below minimum, deduped, TARGETED at this
    -- keysite (reaction.c:413 passes the objective), + backup defender T.I. (reaction.c:429).
    -- PROXY: the port's capture mechanic exists only for BASING keysites (do_capture flips
    -- S.base_owner). An installation may be troop_insertion_target=TRUE in ks_dbase (factory :222,
    -- military_base :316) but the port has no installation-capture path, so T.I. follow-ons are
    -- gated to basing keysites; installations are neutralised by strike/artillery attrition instead.
    if flags.troop_insertion_target and eff < MINIMUM_EFFICIENCY and is_basing
       and not cs.has_task_against("troop_insertion", target_base, attacking_side) then
        pcall(troop_m.run_troop_insertion, attacking_side, log_fn, target_base)
        log_fn(string.format("reaction: %s eff=%.2f<min → T.I.", target_base, eff))
        -- Backup DEFENDER troop insertion: if the objective side has < 2 patrols there.
        local defender = S.base_owner[target_base]
        if defender ~= attacking_side
           and not cs.has_task_against("troop_insertion", target_base, defender) then
            pcall(troop_m.run_troop_insertion, defender, log_fn, target_base)
            log_fn(string.format("reaction: backup defender T.I. at %s", target_base))
        end
    end

    -- OCA (reaction.c:455): OCA strike (targeted) + OCA sweep, each deduped. The sweep is created ON
    -- the recon'd objective (reaction.c:469-471 passes `objective`), NOT a fresh generator scan that
    -- could hit a different base and double-charge the generator's 2-task budget. oca_target is FALSE
    -- for FARPs and every installation, so this whole block is airbase-only in practice.
    if flags.oca_target then
        if not cs.has_task_against("oca_strike", target_base, attacking_side) then
            pcall(atk_m.run_oca_strike, attacking_side, log_fn, target_base, true)   -- reaction.c:459 critical=TRUE
        end
        if not cs.has_task_against("oca_sweep", target_base, attacking_side) then
            -- reaction.c:471 create_oca_sweep_task critical=TRUE — oca_sweep is already in board.M.CRITICAL,
            -- so the follow-on is critical without threading an override through run_oca_sweep.
            pcall(cas_m.run_oca_sweep, attacking_side, log_fn, target_base, objective_pos)
        end
    end

    -- Ground strike (reaction.c:482): only if efficiency >= minimum. EECH does NOT dedup this
    -- follow-on (creates unconditionally), so we don't either.
    if flags.ground_strike_target and eff >= MINIMUM_EFFICIENCY then
        pcall(atk_m.run_strike, attacking_side, log_fn, target_base, true)   -- reaction.c:486 critical=TRUE
    end
end

-- create_reaction_to_recon_task_completed — GROUP objective branch (reaction.c:523-590)
--   AA group → SEAD ; frontline group → BAI. (#8: the whole group-recon chain was absent before.)
local function react_recon_complete_group(attacking_side, objective, log_fn)
    local cas_m = require("cas_bai_sead")
    if objective.kind == "aa_group" then
        if objective.group and objective.group:isExist() then
            cas_m.spawn_sead_against(attacking_side, objective.group, log_fn, true)   -- reaction.c:540 critical=TRUE
            log_fn(cs.SIDE_NAME[attacking_side] .. " reaction: recon of AA group → SEAD")
            cs.dbg("reaction", "%s recon-complete(group aa_group) -> SEAD", cs.SIDE_NAME[attacking_side])
        else
            cs.dbg("reaction", "%s recon-complete(group aa_group) SKIP: group gone", cs.SIDE_NAME[attacking_side])
        end
    elseif objective.kind == "frontline_group" then
        if objective.pos then
            cas_m.spawn_bai_against(attacking_side, objective.pos, log_fn, true)   -- reaction.c:583 critical=TRUE
            log_fn(cs.SIDE_NAME[attacking_side] .. " reaction: recon of frontline group → BAI")
            cs.dbg("reaction", "%s recon-complete(group frontline_group) -> BAI", cs.SIDE_NAME[attacking_side])
        end
    end
end

-- create_reaction_to_strike_task_completed (reaction.c:609): repeat strike or send BDA.
local function react_strike_complete(attacking_side, target_base, target_pos, log_fn)
    if not target_base or S.base_owner[target_base] == attacking_side then return end
    local eff = efficiency_of(target_base)
    local atk_m = require("attack_waves")
    if eff >= MINIMUM_EFFICIENCY then
        -- EECH creates the follow-on ground strike UNCONDITIONALLY (reaction.c:659-674 — there is NO
        -- entity_is_object_of_task dedup on this branch, deliberately, spec 05 open-Q5 confirmed). The
        -- port previously added a has_task_against("ground_strike") guard that throttled EECH's
        -- strike-pressure loop; removed. (The eff >= minimum_efficiency gate at reaction.c:661 is kept.)
        log_fn(string.format("reaction: strike at %s complete eff=%.2f → follow-on strike", target_base, eff))
        cs.dbg("reaction", "%s strike-complete at %s: eff=%.2f -> follow-on strike (no dedup, reaction.c:659-674)",
            cs.SIDE_NAME[attacking_side], target_base, eff)
        pcall(atk_m.run_strike, attacking_side, log_fn, target_base, true)   -- reaction.c:663 critical=TRUE
    else
        -- BDA only if the keysite is a recon_target (reaction.c:676 gates the whole BDA branch on
        -- keysite_database[sub_type].recon_target), deduped (reaction.c:678-681: not already object of
        -- RECON or BDA). Cluster I: installations now reach here, and factory/port are recon_target=FALSE
        -- (ks_dbase.c:219/:360) → no BDA, matching EECH (kind-aware keysite_flags).
        if keysite_flags(target_base).recon_target
           and target_pos
           and not cs.has_task_against("bda", target_base, attacking_side)
           and not cs.has_task_against("recon", target_base, attacking_side) then
            log_fn(string.format("reaction: strike at %s complete eff=%.2f → BDA", target_base, eff))
            cs.dbg("reaction", "%s strike-complete at %s: eff=%.2f -> BDA", cs.SIDE_NAME[attacking_side], target_base, eff)
            M.spawn_bda(attacking_side, target_base, target_pos, log_fn)
        else
            cs.dbg("reaction", "%s strike-complete at %s: eff=%.2f, BDA skip (recon_target=%s / no target_pos / already tasked)",
                cs.SIDE_NAME[attacking_side], target_base, eff, tostring(keysite_flags(target_base).recon_target))
        end
    end
end

-- ── BDA helicopter (create_bda_task) ──────────────────────────────────────────
local BDA_LOITER_TIME = 3 * 60

function M.spawn_bda(attacking_side, target_base, target_pos, log_fn)
    log_fn = log_fn or function() end
    local home = nearest_base(attacking_side, target_pos)
    if not home then
        cs.dbg("reaction", "%s spawn_bda ABORT vs %s: no owned base found", cs.SIDE_NAME[attacking_side], tostring(target_base))
        return
    end
    if not supply.consume_base(home, "heli", 1) then
        cs.dbg("reaction", "%s spawn_bda ABORT vs %s: no heli stock at %s", cs.SIDE_NAME[attacking_side], target_base, home)
        return
    end   -- BDA heli resident at `home`
    local cfg = AC[attacking_side]
    local ab  = Airbase.getByName(home)
    if not ab then
        supply.recycle_base(home, "heli", 1)
        cs.dbg("reaction", "%s spawn_bda ABORT vs %s: %s has no Airbase -> refunded", cs.SIDE_NAME[attacking_side], target_base, home)
        return
    end
    local ab_pos = ab:getPosition().p
    local bx, by = cs.wp_xy(ab_pos)
    local tx, ty = cs.wp_xy(target_pos)
    local sid    = cs.next_id()
    local gname  = string.format("BDA-%d-%d", attacking_side, sid)

    local grp = coalition.addGroup(cfg.country, Group.Category.HELICOPTER, {
        name = gname, task = "Reconnaissance", hidden = false, airdromeId = ab:getID(),
        units = {{ name=gname.."-1", type=cfg.heli, skill="Good",
            x=ab_pos.x, y=ab_pos.z, alt=ab_pos.y, alt_type="BARO", speed=0, heading=0,
            payload={fuel=2200,flare=60,chaff=60,gun=100} }},
        route = { points = {
            {type="TakeOff",action="From Parking Area",airdromeId=ab:getID(),
             alt=ab_pos.y,alt_type="BARO",speed=0,ETA=0,ETA_locked=true,x=bx,y=by,name="Depart",formation_template=""},
            {type="Turning Point",action="Fly Over Point",alt=300,alt_type="BARO",speed=60,
             ETA=0,ETA_locked=false,x=tx,y=ty,name="BDA",formation_template=""},
        }},
    })
    if grp then
        ks.reserve_slot(home, gname)   -- Cluster 5: occupy a landing slot at the launch base (responsive proxy)
        cs.register_task(gname, { task_type="bda", side=attacking_side, target_base=target_base,
            target_pos=target_pos, objective={kind="keysite", base=target_base}, born_time=timer.getTime() })
        -- BDA "completes" after loitering over the target (reveal) → recon-completed reaction.
        local bda_gen = _DMT_GEN
        timer.scheduleFunction(function()
            if _DMT_GEN ~= bda_gen then return nil end   -- stale generation: reset.nuke cleaned up
            react_recon_complete_keysite(attacking_side, target_base, log_fn)
            recycle_once(gname, attacking_side, "heli", grp)   -- live survivors only (dead → regen)
            ks.release_slot(gname)                             -- Cluster 5: free the landing slot on despawn
            if grp and grp:isExist() then grp:destroy() end
            cs.clear_task(gname)
            return nil
        end, nil, timer.getTime() + BDA_LOITER_TIME)
        log_fn(string.format("reaction BDA #%d → %s (loiter %ds)", sid, target_base, BDA_LOITER_TIME))
        cs.dbg("reaction", "%s BDA #%d spawned from %s -> %s", cs.SIDE_NAME[attacking_side], sid, home, target_base)
    else
        supply.recycle_base(home, "heli", 1)  -- refund: BDA spawn failed
        cs.dbg("reaction", "%s BDA #%d SPAWN FAILED from %s -> refunded", cs.SIDE_NAME[attacking_side], sid, home)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Counter-battery reaction: create_reaction_to_artillery_fire (reaction.c:703-810) — REACT-F13
-- ═══════════════════════════════════════════════════════════════════════════════
-- When an artillery group FIRES, the VICTIM side raises a counter-battery task against that battery:
--   rating = (1 - IMAP_AIR_DEFENCE) + IMAP_SURFACE_DEFENCE + 2*IMAP_BASE_DISTANCE,  max 4.0
--            (reaction.c:770-778 — all three imaps read for the VICTIM side at the battery's sector)
--   FOW(battery sector, victim) > 0.5*max → create BAI ; else → create RECON  (reaction.c:780-809)
-- Dedup: skip if the battery is already object of a counter-battery BAI/RECON (reaction.c:740-744).
-- This is the SOLE consumer of IMAP_SURFACE_DEFENCE (06-F13) — porting it re-connects that layer.
-- The port's artillery fires on a timer (cas_bai_sead.run_artillery); each committed shot calls this
-- with (victim_side, battery_group, battery_pos).
local COUNTER_BATTERY_TTL = 20 * 60   -- s; proxy for "object of BAI/RECON" duration (BAI task life)
-- (nearest_any_base = the battery's FOW sector, get_local_sector_entity reaction.c:750 — hoisted to
-- the shared helpers section above; also used by the SEAD-ring FOW gate.)

function M.on_artillery_fire(victim_side, battery_group, battery_pos, log_fn)
    log_fn = log_fn or function() end
    if victim_side ~= coalition.side.BLUE and victim_side ~= coalition.side.RED then return end
    if not battery_group or not battery_pos then return end
    local gname = (battery_group.getName and battery_group:getName()) or tostring(battery_group)

    -- Dedup (reaction.c:740-744): battery already object of a counter-battery BAI/RECON.
    S.counter_battery = S.counter_battery or {}
    local now = timer.getTime()
    -- Prune EXPIRED entries on read: fresh Arty-<id> names accumulate over a long campaign (batteries
    -- die and are re-seeded), so the table would otherwise grow without bound.
    for k, exp in pairs(S.counter_battery) do
        if exp <= now then S.counter_battery[k] = nil end
    end
    if S.counter_battery[gname] and S.counter_battery[gname] > now then
        cs.dbg("reaction", "%s counter-battery SKIP vs %s: already object of BAI/RECON",
            cs.SIDE_NAME[victim_side], gname)
        return
    end

    -- Sector rating (reaction.c:761-778), read for the VICTIM side at the battery's position.
    local airdef  = imap_m.get(victim_side, imap_m.AIR_DEFENCE,     battery_pos)
    local surface = imap_m.get(victim_side, imap_m.SURFACE_DEFENCE, battery_pos)   -- re-connects the layer
    local bdist   = imap_m.get(victim_side, imap_m.BASE_DISTANCE,   battery_pos)
    local rating  = (1.0 - airdef) + surface + 2.0 * bdist   -- max_rating = 4.0

    -- FOW of the battery's sector for the victim (reaction.c:780): > 0.5 → BAI, else RECON.
    local sect = nearest_any_base(battery_pos)
    local fow  = (sect and fow_m.get(sect, victim_side)) or 0.0
    S.counter_battery[gname] = now + COUNTER_BATTERY_TTL

    local cas_m = require("cas_bai_sead")
    if fow > 0.5 then
        -- Counter-battery BAI is critical=FALSE in EECH (reaction.c:788) — the ONE reaction create_* call
        -- that is NOT critical. Pass false explicitly (board would otherwise use the M.CRITICAL default,
        -- which is already false for bai, but this pins it to the C).
        cas_m.spawn_bai_against(victim_side, battery_pos, log_fn, false)
        log_fn(string.format("%s counter-battery BAI vs artillery (fow=%.2f rating=%.2f/4.0)",
            cs.SIDE_NAME[victim_side], fow, rating))
        cs.dbg("reaction", "%s counter-battery: FOW %.2f>0.5 -> BAI vs %s (rating=%.2f/4.0)",
            cs.SIDE_NAME[victim_side], fow, gname, rating)
    else
        local ok_r, recon = pcall(require, "recon")
        if ok_r and recon and recon.spawn_recon then
            recon.spawn_recon(victim_side, battery_pos, "CounterBty", log_fn,
                { kind = "frontline_group", pos = battery_pos, group = battery_group }, true)   -- reaction.c:803 critical=TRUE
        end
        log_fn(string.format("%s counter-battery RECON vs artillery (fow=%.2f rating=%.2f/4.0)",
            cs.SIDE_NAME[victim_side], fow, rating))
        cs.dbg("reaction", "%s counter-battery: FOW %.2f<=0.5 -> RECON vs %s (rating=%.2f/4.0)",
            cs.SIDE_NAME[victim_side], fow, gname, rating)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Event handler
-- ═══════════════════════════════════════════════════════════════════════════════
-- BIRTH  = task assigned  → defender scrambles CAP/BARCAP at the objective (from the registered task).
-- LAND   = task SUCCESS    → completion reaction (strike follow-on / recon-completed chain).
--          A shot-down mission never lands → no follow-on (EECH fires only on SUCCESS).
function M.make_event_handler(log_fn)
    log_fn = log_fn or function() end
    return {
        onEvent = function(_, event)
            if event.id == world.event.S_EVENT_BIRTH then
                -- Pilot career (spec 10 Cluster 6): ensure a record + send the join brief for a human
                -- unit. pcall-guarded and inert for AI births (returns immediately on no getPlayerName).
                local ok_pb, pilots = pcall(require, "pilots")
                if ok_pb and pilots then pcall(pilots.on_birth, event) end

                local u = event.initiator
                if not u or not u.getGroup then return end
                local ok, grp = pcall(function() return u:getGroup() end)
                if not ok or not grp or not grp:isExist() then return end
                local gname = grp:getName()
                local task  = cs.get_task(gname)
                -- Only registered offensive tasks trigger a defender reaction.
                if task and OFFENSIVE[task.task_type] and task.target_base then
                    local obj_pos   = S.base_pos[task.target_base]
                    local spawn_pos = u:getPosition().p
                    if obj_pos then
                        log_fn(string.format("reaction: offensive '%s' vs %s → CAP/BARCAP", gname, task.target_base))
                        local okr, err = pcall(react_to_offense, task.target_base, obj_pos, spawn_pos, log_fn)
                        if not okr then log_fn("reaction assign error: " .. tostring(err)) end
                    end
                end

            elseif event.id == world.event.S_EVENT_LAND then
                local u = event.initiator
                if not u or not u.getGroup then return end
                -- A human landing that completes THEIR registered campaign task runs the same completion
                -- chain as an AI sortie (reactions key off the TASK, not the crew — a player-flown strike
                -- fires the same defender/BDA follow-ons) AND a per-sortie pilot debrief (PILOT-F9). A
                -- human WITHOUT a registered task falls through `if not task then return end` unchanged, so
                -- taskless players are still ignored. The player airframe is NEVER despawned/recycled here
                -- (that is supply.make_land_handler, which skips players) — read-only on the player unit.
                local is_player = false
                if u.getPlayerName then
                    local okp, pn = pcall(function() return u:getPlayerName() end)
                    is_player = okp and pn ~= nil and pn ~= false
                end
                local ok, grp = pcall(function() return u:getGroup() end)
                if not ok or not grp then return end
                local gname = grp:getName()
                local task  = cs.get_task(gname)
                if not task then return end
                S._completed = S._completed or {}
                if S._completed[gname] then return end     -- fire completion once per mission
                S._completed[gname] = true

                cs.dbg("reaction", "LAND event: %s (task=%s side=%s target=%s player=%s) -> completion dispatch",
                    gname, task.task_type, cs.SIDE_NAME[task.side], tostring(task.target_base), tostring(is_player))
                if task.task_type == "ground_strike" or task.task_type == "oca_strike" then
                    react_strike_complete(task.side, task.target_base, task.target_pos, log_fn)
                elseif task.task_type == "recon" then
                    if task.objective and task.objective.kind ~= "keysite" then
                        react_recon_complete_group(task.side, task.objective, log_fn)
                    else
                        react_recon_complete_keysite(task.side, task.target_base, log_fn)
                    end
                end
                -- Item 3: assess completion (RTB == EECH TASK_TERMINATED_WAYPOINT_ROUTE_COMPLETE) and
                -- record the success/partial outcome into the per-side task stats (Item 2).
                local result, rating = cs.assess_task(task, "route_complete")
                cs.stat_task_result(task.side, result)
                cs.dbg("reaction", "assess %s (%s) LAND -> %s (rating=%.2f)", gname, task.task_type, result, rating)
                -- Player mission debrief (spec 10 Cluster 6): score + medals for the human who completed
                -- this task. The assessment feeds the EECH points multiplier (task.c:508-555 —
                -- FAILURE 0 / PARTIAL ¼ / SUCCESS full). pcall-guarded, read-only on the player unit.
                if is_player then
                    local ok_dbf, pilots = pcall(require, "pilots")
                    if ok_dbf and pilots then pcall(pilots.on_debrief, u, task, { result = result, rating = rating }) end
                end
                cs.clear_task(gname)

            elseif event.id == world.event.S_EVENT_DEAD then
                -- Pilot career (spec 10 Cluster 6): record a player's loss (F15/F23). pcall-guarded
                -- and inert for AI deaths (returns immediately if the dead unit has no getPlayerName).
                local ok_pd, pilots = pcall(require, "pilots")
                if ok_pd and pilots then pcall(pilots.on_death, event) end

                -- A mission that dies before RTB is a FAILURE: no follow-on (EECH fires only on
                -- SUCCESS). Just clear the registry entry once the whole group is gone, so it does
                -- not leak or keep a stale dedup guard that would block future tasks on that target.
                local u = event.initiator
                if not u or not u.getGroup then return end
                local ok, grp = pcall(function() return u:getGroup() end)
                if not ok or not grp then return end
                local gname = grp:getName()
                local task  = cs.get_task(gname)
                if not task then return end
                local alive = false
                local ok2, units = pcall(function() return grp:getUnits() end)
                if ok2 and units then
                    for _, uu in ipairs(units) do
                        if uu and uu:isExist() then alive = true; break end
                    end
                end
                if not alive then
                    -- Item 3/2: a mission destroyed before RTB is a FAILURE (eech task.c terminated-early
                    -- path) — record the failed outcome before clearing the registry entry + arrow.
                    local result = cs.assess_task(task, "terminated")
                    cs.stat_task_result(task.side, result)
                    cs.dbg("reaction", "assess %s (%s) DEAD -> %s", gname, task.task_type, result)
                    cs.clear_task(gname)
                end

            elseif event.id == world.event.S_EVENT_HIT then
                -- Purple-Heart tracking (spec 10 Cluster 6, PILOT-F13): mark a hit player as damaged-
                -- this-sortie; awarded at the LAND debrief if the pilot survives. pcall-guarded, inert
                -- for AI targets (no getPlayerName), read-only on the player unit.
                local ok_ph, pilots = pcall(require, "pilots")
                if ok_ph and pilots then pcall(pilots.on_hit, event) end
            end
        end
    }
end

return M
