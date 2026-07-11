-- win_condition.lua
-- Inspired by:
--   aphavoc/source/entity/special/force/fc_msgs.c  response_to_check_campaign_objectives
--                                                   (the LIVE, shipped win check — lines 144-311)
--   aphavoc/source/ai/highlevl/setup.c             create_force_campaign_objectives (5 per side)
--   aphavoc/source/entity/mobile/aircraft/helicop/hc_dstry.c  helicopter-kill win trigger
--   aphavoc/source/entity/special/force/force.c    add_mobile_to_force_losses_stats (kill ledger)
--
-- Implements the THREE real end conditions of shipped EECH (spec 02 F26-F28 / spec 01 F13).
-- The Razorworks campaign_criteria evaluator in fc_updt.c is DEAD CODE (its whole body is
-- commented out); the community build ends a campaign purely event-driven, when a keysite is
-- captured/destroyed or a helicopter is killed, via response_to_check_campaign_objectives. A side
-- wins if ANY of:
--   (a) OBJECTIVES  — it OWNS every keysite in its campaign-objective set (troop-insertion
--                     targets must be owned; eech fc_msgs.c:180-211). See keysite.designate_objectives.
--   (b) NO USABLE AIRBASE — the enemy has no alive+in-use keysite with air_force_capacity != NONE
--                     (eech fc_msgs.c:222-249). In the port every keysite is an airbase, so this is
--                     "enemy owns no keysite at efficiency >= minimum" (usable state, KEYSITE-F11).
--   (c) NO GUNSHIPS — the enemy has no flyable player-controllable combat helicopter left
--                     (eech fc_msgs.c:255-295).
-- The invented 4-hour time limit and balance-of-power/captured-sectors criteria of the old port
-- (which modelled the DEAD fc_updt.c system) are REMOVED — EECH has no time-based end.

local cs      = require("campaign_state")
local keysite = require("keysite")
local S       = cs.S
local M       = {}

local function finish(winner, reason, log_fn)
    S.game_over = true
    S.winner    = winner
    local b_own, r_own = 0, 0
    for _, owner in pairs(S.base_owner) do
        if owner == coalition.side.BLUE then b_own = b_own + 1
        elseif owner == coalition.side.RED then r_own = r_own + 1 end
    end
    local msg = string.format(
        "══════════ CAMPAIGN OVER ══════════\n%s VICTORY — %s\nBases: BLUE %d  RED %d   |   Strength: BLUE %d%%  RED %d%%",
        cs.SIDE_NAME[winner] or "?", reason, b_own, r_own,
        S.strength[coalition.side.BLUE], S.strength[coalition.side.RED])
    log_fn(msg)
    trigger.action.outText(msg, 120)
    cs.dbg("win", "GAME OVER: %s wins (%s) — bases BLUE=%d RED=%d, strength BLUE=%d RED=%d",
        cs.SIDE_NAME[winner] or "?", reason, b_own, r_own, S.strength[coalition.side.BLUE], S.strength[coalition.side.RED])

    -- Persistence (WAVE 2): checkpoint the decided campaign so a restart restores S.game_over/winner
    -- (a finished campaign stays finished). No-op unless persistence enabled; pcall-guarded.
    local ok_p, persist = pcall(require, "persist")
    if ok_p and persist and persist.save then pcall(persist.save, log_fn) end

    -- Campaign medal (PILOT-F14, eech play_md.c:1062 award_campaign_medal; campaign.c:1128 at session
    -- complete): every pilot who flew this campaign receives the campaign medal on the win declaration.
    -- Deferred + pcall-guarded (pilots requires task_board/supply/frontline — no cycle with win_condition).
    local ok_pc, pilots = pcall(require, "pilots")
    if ok_pc and pilots and pilots.award_campaign_medals then
        pcall(pilots.award_campaign_medals, winner, log_fn)
    end
end

-- ── (a) Objectives held ────────────────────────────────────────────────────────
-- eech fc_msgs.c:180-211: every objective keysite of the force must be OWNED by its side
-- (all port keysites are troop_insertion_targets → "must own", not "must destroy").
local function holds_all_objectives(side)
    local objs = S.objectives and S.objectives[side]
    if not objs or #objs == 0 then return false end
    for _, bname in ipairs(objs) do
        if S.base_owner[bname] ~= side then return false end
    end
    return true
end

-- ── (b) Enemy has a usable airbase ─────────────────────────────────────────────
-- eech fc_msgs.c:222-249: any enemy keysite that is alive+in-use with air_force_capacity != NONE.
-- Port: any enemy-owned keysite at efficiency >= minimum (usable state, KEYSITE-F11).
local function has_usable_airbase(side)
    for bname, owner in pairs(S.base_owner) do
        -- Item 1: a keysite must be IN_USE (active) to count, matching fc_msgs.c:234 (ALIVE && IN_USE).
        -- A dormant FARP does not keep a side "alive" for the win check.
        if owner == side and cs.base_is_active(bname) and keysite.efficiency(bname) >= cs.MINIMUM_EFFICIENCY then
            return true
        end
    end
    return false
end

-- ── (c) Enemy has a flyable combat helicopter ──────────────────────────────────
-- eech fc_msgs.c:255-295 walks the enemy's live air registry for a surviving player-controllable
-- combat helicopter (view_category == VIEW_CATEGORY_COMBAT_HELICOPTERS).
-- Port proxy: EECH's combat helis are seeded in the air registry at OOB; in the port a side's
-- gunship capability lives in its reserve pool and regen queue (helis are spawned on demand), so a
-- census of LIVE units alone would falsely fire at campaign start. A side therefore still "has"
-- flyable combat helicopters while it can field one — i.e. any live attack helicopter, OR any
-- "heli" reserve, OR any queued heli regen. Only when it can neither fly nor regenerate one is it
-- out of gunships. Combat helicopter == DCS attribute "Attack helicopters".
local function live_combat_helis(side)
    local ok, grps = pcall(coalition.getGroups, side, Group.Category.HELICOPTER)
    if not ok or not grps then return 0 end
    local n = 0
    for _, grp in ipairs(grps) do
        if grp and grp.isExist and grp:isExist() then
            local units = grp:getUnits()
            if units then
                for _, u in ipairs(units) do
                    if u and u:isExist() then
                        local d = u:getDesc()
                        local a = d and d.attributes
                        if a and a["Attack helicopters"] then n = n + 1; break end
                    end
                end
            end
        end
        if n > 0 then break end
    end
    return n
end

local function has_combat_heli_capability(side)
    if live_combat_helis(side) > 0 then return true end
    -- reserve pool (supply) — a side with heli reserves can still field gunships
    local ok_s, supply = pcall(require, "supply")
    if ok_s and supply and supply.reserve_side(side, "heli") > 0 then return true end
    -- queued heli regen (a shot-down gunship waiting to respawn)
    local q = S.regen_queue and S.regen_queue[side] and S.regen_queue[side].heli
    if q and #q > 0 then return true end
    return false
end

-- ── Win check ──────────────────────────────────────────────────────────────────
-- Event-driven (called from the kill handler, capture side-effect, and the admin poll), mirroring
-- EECH's ENTITY_MESSAGE_CHECK_CAMPAIGN_OBJECTIVES fan-out to both forces (fc_msgs.c F29).
function M.check_win(log_fn)
    log_fn = log_fn or function() end
    if S.game_over then return end

    cs.recalc_strength()   -- kept for the debrief strength readout only (not a win criterion)

    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local enemy = cs.ENEMY[side]

        -- Criterion telemetry (evaluated before the gates below fire so the counts are always visible,
        -- even on the check that doesn't end the campaign).
        local objs = S.objectives and S.objectives[side]
        local held = 0
        if objs then
            for _, bname in ipairs(objs) do if S.base_owner[bname] == side then held = held + 1 end end
        end
        local enemy_usable = 0
        for bname, owner in pairs(S.base_owner) do
            if owner == enemy and cs.base_is_active(bname) and keysite.efficiency(bname) >= cs.MINIMUM_EFFICIENCY then enemy_usable = enemy_usable + 1 end
        end
        cs.dbg("win", "%s check: objectives %d/%d held, enemy(%s) usable-airbases=%d, enemy live-combat-helis=%d",
            cs.SIDE_NAME[side], held, objs and #objs or 0, cs.SIDE_NAME[enemy], enemy_usable, live_combat_helis(enemy))

        -- (a) OBJECTIVES: this side owns all its objective keysites
        if holds_all_objectives(side) then
            finish(side, "all objective keysites captured", log_fn)
            return
        end

        -- (b) NO USABLE AIRBASE on the enemy side
        if not has_usable_airbase(enemy) then
            finish(side, cs.SIDE_NAME[enemy] .. " has no usable airbase", log_fn)
            return
        end

        -- (c) NO FLYABLE COMBAT HELICOPTERS on the enemy side
        if not has_combat_heli_capability(enemy) then
            finish(side, cs.SIDE_NAME[enemy] .. " combat helicopters eliminated", log_fn)
            return
        end

        -- EECH has EXACTLY THREE end conditions (fc_msgs.c:180-295 → CAMPAIGN_COMPLETED_OBJECTIVES /
        -- no alive+in-use air-capable keysite / no player-controllable combat helicopter). There is no
        -- fourth. The former criterion (d) "military collapse" (enemy <=25% of bases AND strength <
        -- STRENGTH_SURVIVAL) was invented — it modelled a strength/posture "rout" EECH does not have
        -- (force_attitude is parsed but read by NO AI code; verified E:\eech_source_code parsgen.c:1474
        -- + fc_int.c:215, zero consumers). Removed in Cluster E. Stalemate resolution is now the job of
        -- the realigned strike/capture pressure (Clusters A/C/D), not a synthetic strength cutoff.
    end
end

-- ── Kill event handler ─────────────────────────────────────────────────────────
-- A helicopter kill is one of EECH's three live win-check triggers (hc_dstry.c:631-643), so we
-- re-check the win conditions on every kill. Keysite structural attrition is NOT driven from here —
-- EECH keysite_strength changes only when the keysite's own buildings die (Cluster G, see below).
function M.make_kill_handler(log_fn)
    log_fn = log_fn or function() end
    local handler = {}

    function handler:onEvent(event)
        if event.id ~= world.event.S_EVENT_KILL then return end
        local tgt = event.target
        if not tgt then return end

        -- Item 2 stats: credit the kill to the killer's side and the loss to the victim's side, bucketed
        -- by the victim's category (eech force.c:307-361 add_mobile_to_force_kills_stats /_losses_stats:
        -- kill → killer force indexed by victim category; loss → victim force). pcall-guarded.
        local killer_side, victim_side
        pcall(function() if event.initiator and event.initiator.getCoalition then killer_side = event.initiator:getCoalition() end end)
        pcall(function() if tgt.getCoalition then victim_side = tgt:getCoalition() end end)
        cs.stat_kill(killer_side, victim_side, cs.unit_category(tgt))

        -- Re-evaluate win conditions on every kill (helicopter-exhaustion + base-count triggers,
        -- hc_dstry.c:631-643). Keysite structural attrition is NOT driven from here anymore: EECH
        -- keysite_strength changes only when the keysite's own buildings die, so airbase/installation
        -- health is driven by the deterministic strike channel (keysite.strike_damage /
        -- installations.damage) and registered-asset death (installations.register_static_death) — the
        -- old generic kill-proximity bleed (both apply_kill_damage calls) was removed in Cluster G (B4).
        M.check_win(log_fn)

        -- Pilot career: credit the killer if it is a human (spec 10 PILOT-F16 player branch).
        -- pcall-guarded so the career substrate is fully inert / harmless with zero players.
        local ok_p, pilots = pcall(require, "pilots")
        if ok_p and pilots then pcall(pilots.on_kill, event) end
    end

    return handler
end

return M
