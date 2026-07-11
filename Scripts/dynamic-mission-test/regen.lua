-- regen.lua
-- EECH source: aphavoc/source/entity/special/regen/rg_updt.c
--   update_server() line 160  — sleep-based tick, period = regen_frequency * modifier
--   regen_update()  line 199  — dequeue front entry if queue non-empty + keysite usable + reserve > 0
--   regen_queue_insert() line 763 — ring buffer; when full, oldest is overwritten (front advances)
--   regen_queue_use()    line 820 — pop front, consume reserve_hardware, spawn via
--                                   create_landing_faction_members()
-- EECH source: aphavoc/source/entity/special/regen/regen.h
--   REGEN_QUEUE_DEFAULT_SIZE = 5
--   REGEN_QUEUE_MINIMUM_SIZE = 5
--   REGEN_UPDATE_SLOW   = 1.5
--   REGEN_UPDATE_MEDIUM = 1.0   ← used by get_regen_frequency_difficulty_modifier()
--   REGEN_UPDATE_FAST   = 0.5
-- EECH source: aphavoc/source/entity/special/regen/regen.c line 335
--   get_regen_frequency_difficulty_modifier() returns REGEN_UPDATE_MEDIUM (1.0) always (medium only)
-- regen_frequency[side] is mission-data driven (parsgen.c:1519); proxy value: 60 s
-- regen_update blocked when: building not alive OR keysite NOT KEYSITE_STATE_USABLE
--   → DCS proxy: S.base_health[base] <= cs.HEALTH_NEUTRALISED
-- regen_update blocked when: reserve_count <= 0
--   → DCS proxy: supply.available(base, type) <= 0
-- CLUSTER 4: supply.available/consume are now the PER-BASE ledger (S.base_ledger), so a regenerated
-- airframe draws from — and is fielded at — its OWN home base's idle inventory (the exact base the
-- dead group is homed to via nearest_friendly), not a shared side pool. Force conservation with
-- location: regen at a base with no reserve of that role is blocked even if another base has some.
--
-- Types tracked (mirrors ENTITY_SUB_TYPE_REGEN_* enum used to classify dead entities):
--   REGEN_FIXED_WING  → "striker" (group name prefix "Strike-")
--   REGEN_FIXED_WING  → "escort"  (group name prefix "Escort-")
--   REGEN_HELICOPTER  → "heli"    (group name prefix "Heli-", "BDA-")

local cs     = require("campaign_state")
local supply = require("supply")
local ks     = require("keysite")
local config = require("config")
local S      = cs.S
local M      = {}

-- ── EECH constants (exact mirror) ─────────────────────────────────────────────
local REGEN_QUEUE_DEFAULT_SIZE       = 5     -- regen.h
local REGEN_UPDATE_MEDIUM            = 1.0   -- regen.h; difficulty modifier
-- regen_frequency[side] is DATA-DRIVEN per side in EECH (parsgen.c:1519); the campaign-file values
-- are not in the C tree (spec 08 Open-Q1), so we keep the single 60 s proxy per side with citation.
local REGEN_FREQUENCY_BASE           = 60    -- proxy for regen_frequency[side] (seconds)
local REGEN_PERIOD = REGEN_FREQUENCY_BASE * REGEN_UPDATE_MEDIUM  -- 60 s

-- ── Supply-scaled rearm/turnaround (KEYSITE-F9, en_suply.c:95-148) ────────────
-- rearming_sleep = base_time * ( -(MAX-1)/100 * ammo_supply_level + MAX ), MAX=5 (en_suply.h:67):
-- 1x turnaround at supply 100, up to ~5x at the 10-point floor. The port's closest surface is the
-- regen dequeue: a starved base (few crate deliveries — see keysite_repair) rearms its replacements
-- far more slowly, so an economy under pressure loses operational tempo. base_time = REGEN_PERIOD.
local MAX_REARMING_TIME_SCALING_FACTOR = 5   -- en_suply.h:67
local function rearm_scale(level)
    level = level or 100
    return -(MAX_REARMING_TIME_SCALING_FACTOR - 1) / 100 * level + MAX_REARMING_TIME_SCALING_FACTOR
end

-- ── Aircraft type tables (hoisted to config.lua; mirrors force faction data for spawning) ─────────
-- The "heli" reserve is dominated by attack helicopters (EECH's main arm), so regenerated rotary
-- reinforcements are attack helis (config attack_heli: AH-64D / Mi-24V), not unarmed transports.
-- regen's local "heli" atype = config attack_heli.
local AC = {}
for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
    AC[side] = {
        country = config.C.countries[side],
        striker = config.C.types.aircraft[side].striker,
        escort  = config.C.types.aircraft[side].escort,
        heli    = config.C.types.aircraft[side].attack_heli,
    }
end

local REGEN_ALT   = 300   -- m; parking area height proxy
local REGEN_SPEED = 0     -- 0 at TakeOff waypoint

-- ── Queue structure ────────────────────────────────────────────────────────────
-- S.regen_queue[side][atype] = FIFO list of {base_name, aircraft_type, side}
-- "atype" ∈ {"striker", "escort", "heli"}

local TYPES = { "striker", "escort", "heli" }
local SIDES = { coalition.side.BLUE, coalition.side.RED }

-- ── Pattern → type mapping (mirrors get_regen_sub_type() switch in rg_updt.c:598) ──
-- SINGLE SOURCE (Wave 1): the prefix→role table now lives ONCE in supply.lua (supply.PREFIX_ROLES).
-- classify_group delegates to supply.classify_group, which returns a role only for REGENERATED types
-- (regen=true) and nil for one-shots — Recon, Ferry, Insert (troop-transport) and Supply (physical
-- resupply) flights are NOT regenerated; they respawn on demand (recon via the FOW fork, insertions via
-- the next T.I. task, supply flights via the next keysite_repair supply request). Guaranteed to AGREE
-- with supply.classify_role for regen types (same table, same order). Kept as a local wrapper so the
-- caller (make_dead_handler) is untouched.
local function classify_group(name)
    return supply.classify_group(name)
end

-- ── Nearest friendly base (home base for regen spawn) ─────────────────────────
local function nearest_friendly(side, pos)
    local best, best_d2 = nil, math.huge
    for name, owner in pairs(S.base_owner) do
        if owner == side then
            local h = S.base_health[name] or 1.0
            if h >= cs.HEALTH_NEUTRALISED then   -- USABLE iff eff >= min (keysite.c:827-830, inclusive)
                local bpos = S.base_pos[name]
                if bpos then
                    local dx = pos.x - bpos.x
                    local dz = pos.z - bpos.z
                    local d2 = dx*dx + dz*dz
                    if d2 < best_d2 then best_d2 = d2; best = name end
                end
            end
        end
    end
    return best
end

-- ── Player-landed veto (rg_updt.c:307-339) ────────────────────────────────────
-- "Don't regen if PLAYER landed there" (rg_updt.c:308). EECH walks the keysite's own groups/members
-- and returns NULL from regen_update if ANY non-AI (human) member has INT_TYPE_LANDED set
-- (rg_updt.c:311-339). This is the regen expression of "players are first-class": no AI reinforcement
-- appears at a base a human is currently sitting on the ground at.
--
-- Port proxy: the port has no keysite-group membership list, so "landed among the keysite's groups" is
-- proxied by "a player unit on the ground within PLAYER_LANDED_RADIUS of the base". The keysite is
-- owned by `side` (spawn_regen's usable gate runs first), and EECH's keysite-group members are the
-- keysite owner's, so we scan coalition.getPlayers(side) — own-side players only. 2 km is the
-- base-vicinity proxy for keysite-group membership (spec 08-F14). Read-only: the player unit is NEVER
-- touched or destroyed (guardrail). Every DCS call pcall-guarded. Returns true → caller VETOES (delays,
-- not drops) this regen; the entry stays queued and is retried next tick.
local PLAYER_LANDED_RADIUS = 2000  -- m

local function player_landed_at(base_name, side)
    local bp = S.base_pos and S.base_pos[base_name]
    if not bp then return false end
    local ok, players = pcall(coalition.getPlayers, side)
    if not ok or type(players) ~= "table" then return false end
    for _, u in ipairs(players) do
        local alive = false
        pcall(function() alive = u and u.isExist and u:isExist() or false end)
        if alive then
            local in_air = true   -- default true → only a CONFIRMED on-ground reading vetoes
            local oka = pcall(function() in_air = u:inAir() end)
            if oka and in_air == false then
                local okp, p = pcall(function() return u:getPosition().p end)
                if okp and p then
                    if cs.dist2d(p.x, p.z, bp.x, bp.z) <= PLAYER_LANDED_RADIUS then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- ── init() ────────────────────────────────────────────────────────────────────
function M.init(log_fn)
    log_fn = log_fn or function() end
    S.regen_queue = {}
    for _, side in ipairs(SIDES) do
        S.regen_queue[side] = {}
        for _, atype in ipairs(TYPES) do
            S.regen_queue[side][atype] = {}
        end
    end
    log_fn(string.format("regen: queues initialised (REGEN_QUEUE_DEFAULT_SIZE=%d, period=%ds)",
        REGEN_QUEUE_DEFAULT_SIZE, REGEN_PERIOD))
    cs.dbg("regen", "queues initialised: size=%d period=%ds", REGEN_QUEUE_DEFAULT_SIZE, REGEN_PERIOD)
end

-- ── regen_queue_insert (rg_updt.c:763) ────────────────────────────────────────
-- Ring buffer: when full, drop OLDEST entry (advance front) and insert newest.
-- Mirrors EECH: at capacity, rear==front, new entry overwrites oldest slot,
-- then m1->front = (m1->front + 1) % size.  Count stays at REGEN_QUEUE_DEFAULT_SIZE.
-- Returns (inserted, evicted_oldest). `evicted_oldest` is true when the ring buffer was full and the
-- oldest pending regen was overwritten to make room — so the caller can surface the (silent) tempo loss.
local function queue_insert(side, atype, base_name, aircraft_type)
    local q = S.regen_queue[side][atype]
    local evicted = false
    if #q >= REGEN_QUEUE_DEFAULT_SIZE then
        table.remove(q, 1)  -- drop OLDEST (mirrors ring buffer advancing front past overwritten slot,
                            -- rg_updt.c:791-794 — overflow overwrites the oldest pending regen, NOT the newest)
        evicted = true
    end
    -- enqueued time drives the supply-scaled turnaround gate in process_queue (KEYSITE-F9).
    q[#q + 1] = { base_name = base_name, aircraft_type = aircraft_type, enqueued = timer.getTime() }
    return true, evicted
end

-- ── queue_reseed (capture side-effect, eech keysite.c:1483-1517) ──────────────
-- On keysite capture the new owner's regen queue is reseeded with default groups at the
-- captured base (EECH AIRBASE: 2× attack-helo, 2× recon-attack-helo, 2× assault-helo,
-- 2× CAS, 2× multi-role — 6 rotary + 4 fixed-wing groups). Port proxy: insert heli_n
-- helicopter + fw_n striker entries for `base_name`. The queue is a fixed-size ring
-- (REGEN_QUEUE_DEFAULT_SIZE) so it retains the newest 5 per type; the matching reserve
-- boost (supply.recycle_side in keysite.reseed_regen_on_capture) carries the full +6/+4.
function M.queue_reseed(side, base_name, heli_n, fw_n, log_fn)
    log_fn = log_fn or function() end
    if not S.regen_queue or not S.regen_queue[side] then return end
    local cfg = AC[side]
    for _ = 1, (heli_n or 0) do
        queue_insert(side, "heli", base_name, cfg and cfg.heli or "AH-64D")
    end
    for _ = 1, (fw_n or 0) do
        queue_insert(side, "striker", base_name, cfg and cfg.striker or "F-16C bl.52d")
    end
    log_fn(string.format("regen: capture reseed at %s (%s) +%d heli +%d fw queued",
        base_name, cs.SIDE_NAME[side] or "?", heli_n or 0, fw_n or 0))
    cs.dbg("regen", "capture reseed at %s (%s): +%d heli +%d fw queued",
        base_name, cs.SIDE_NAME[side] or "?", heli_n or 0, fw_n or 0)
end

-- ── make_dead_handler() ───────────────────────────────────────────────────────
-- Returns an event handler table for world.addEventHandler().
-- On S_EVENT_DEAD: classify dead group → add to regen queue.
-- Mirrors add_entity_to_regen_queue() called from destroy hooks.
function M.make_dead_handler(log_fn)
    log_fn = log_fn or function() end
    return {
        onEvent = function(_, event)
            if event.id ~= world.event.S_EVENT_DEAD then return end
            local obj = event.initiator
            if not obj or not obj.getGroup then return end
            local ok, grp = pcall(function() return obj:getGroup() end)
            if not ok or not grp then return end

            -- Players are first-class: a human-piloted airframe is NEVER regen hardware (guardrail). The
            -- prefix classifier below already rejects player group names, but this explicit getPlayerName
            -- check makes the invariant unbreakable if a player group is ever named with a tracked prefix
            -- (goal-03 P1 "regen dead handler prefix-fragile"). A player death never queues an AI
            -- replacement; the fc census still counts the human alive while flying (campaign_state).
            if obj.getPlayerName then
                local okp, pn = pcall(function() return obj:getPlayerName() end)
                if okp and pn then
                    cs.dbg("regen", "dead unit is a player (%s) - no regen queue (players first-class)", tostring(pn))
                    return
                end
            end

            -- Resolve the group name WITHOUT requiring grp:isExist() — on the final unit's death the
            -- group can already report non-existent, and the slot release must still fire.
            local okn, gname = pcall(function() return grp:getName() end)
            if not okn then gname = nil end

            -- Cluster 5: release the base landing slot once the WHOLE sortie is dead (S_EVENT_DEAD
            -- fires per unit, so release only when no OTHER unit survives). This is the sole release
            -- path for a board sortie killed before RTB (it has no despawn/loiter timer), so it must
            -- NOT sit behind the grp:isExist() guard below. The dying unit (event.initiator) is
            -- excluded from the survivor scan to defeat DCS unit-removal lag (it may still list as
            -- alive on its own death event). Idempotent + clamped in release_slot.
            if gname then
                local dying
                local okd, dn = pcall(function() return obj.getName and obj:getName() or nil end)
                if okd then dying = dn end
                local any_alive = false
                local oku, us = pcall(function() return grp:getUnits() end)
                if oku and us then
                    for _, uu in ipairs(us) do
                        if uu and uu:isExist() and (not dying or uu:getName() ~= dying) then
                            any_alive = true; break
                        end
                    end
                end
                if not any_alive then ks.release_slot(gname) end
            end

            -- Regen-queue insertion needs a still-valid group (original guard preserved).
            if not grp:isExist() then return end
            local gname_s = gname or ""   -- provably string for classify_group's :match
            if gname_s == "" then return end

            local atype = classify_group(gname_s)
            if not atype then return end

            -- Determine side from the dead unit
            local u = grp:getUnit(1)
            if not u or not u:isExist() then return end
            local coal = u:getCoalition()
            -- DCS coalition: 2=BLUE, 1=RED
            local side = (coal == 2) and coalition.side.BLUE or coalition.side.RED

            -- Find nearest surviving friendly base as home for regen
            local upos = u:getPosition().p
            local home = nearest_friendly(side, upos)
            if not home then
                log_fn(string.format("regen: dead %s — no friendly base found, skipped", gname))
                cs.dbg("regen", "%s dead, NO friendly base found for regen -> dropped (type=%s)",
                    tostring(gname), atype)
                return
            end

            -- Determine aircraft type from AC table
            local ac_type = AC[side] and AC[side][atype] or "F-16C bl.52d"

            if not S.regen_queue or not S.regen_queue[side] then return end
            local _, evicted = queue_insert(side, atype, home, ac_type)
            log_fn(string.format("regen: queued %s (%s) at %s [q=%d/%d]",
                gname, atype, home, #S.regen_queue[side][atype], REGEN_QUEUE_DEFAULT_SIZE))
            cs.dbg("regen", "queue INSERT: %s (%s/%s) at %s [q=%d/%d]",
                gname, cs.SIDE_NAME[side], atype, home, #S.regen_queue[side][atype], REGEN_QUEUE_DEFAULT_SIZE)
            if evicted then
                -- The ring buffer was full: EECH overwrites the OLDEST pending regen (rg_updt.c:791-794).
                -- Now VISIBLE — a saturated regen queue means the oldest queued replacement is lost (tempo hit).
                log_fn(string.format("regen: queue was full for %s/%s — oldest pending regen evicted",
                    cs.SIDE_NAME[side], atype))
                cs.dbg("regen", "queue OVERFLOW %s/%s: oldest pending regen evicted (tempo loss)",
                    cs.SIDE_NAME[side], atype)
            end
        end
    }
end

-- ── Spawn replacement (mirrors create_landing_faction_members at keysite) ──────
local function spawn_regen(side, atype, entry, log_fn)
    local base_name   = entry.base_name
    local aircraft_type = entry.aircraft_type
    local cfg         = AC[side]
    if not cfg then return false end

    -- Blocked: keysite must be usable (mirrors regen_update check)
    local h = S.base_health[base_name] or 0.0
    if h < cs.HEALTH_NEUTRALISED then   -- UNUSABLE iff eff < min, strict (keysite.c:827-830)
        log_fn(string.format("regen: %s too damaged (%.0f%%) — regen blocked", base_name, h*100))
        cs.dbg("regen", "spawn BLOCKED: %s too damaged (%.0f%% < neutralised threshold %.0f%%)",
            base_name, h * 100, cs.HEALTH_NEUTRALISED * 100)
        return false
    end

    -- Blocked: no reserve hardware (mirrors reserve_count <= 0)
    if supply.available(base_name, atype) <= 0 then
        log_fn(string.format("regen: no %s reserve at %s — regen blocked", atype, base_name))
        cs.dbg("regen", "spawn BLOCKED: no %s reserve at %s", atype, base_name)
        return false
    end

    -- Vetoed: a human player is landed at this base (rg_updt.c:307-339). EECH checks this AFTER the
    -- reserve gate (rg_updt.c:294 then :311) and returns NULL — a DELAY, not a drop: process_queue
    -- leaves the entry queued (no pop on false) and retries next tick, exactly as EECH re-attempts the
    -- pending regen. No reserve is consumed here (consume happens below), so nothing leaks on veto.
    if player_landed_at(base_name, side) then
        log_fn(string.format("regen: human player landed at %s — regen delayed", base_name))
        cs.dbg("regen", "spawn VETOED: human player landed within %.0fm of %s — regen delayed (retry next tick)",
            PLAYER_LANDED_RADIUS, base_name)
        return false
    end

    -- Spawn from a real airbase if the base has one, else GROUND-START from its coordinates — a
    -- synthetic zone-FARP has no Airbase object (same fix as heli_war.build_attack_heli / troop
    -- insertion). Without this, regen was silently blocked at EVERY padless FARP (the old
    -- `if not ab then return false end`), so FARP losses never replenished — only Batumi/Kutaisi
    -- regenerated. FARP reserves are heli-only, so the ground start only ever fields rotary here.
    local ab = Airbase.getByName(base_name)
    local ab_pos, ab_id
    if ab then
        ab_pos, ab_id = ab:getPosition().p, ab:getID()
    else
        local bp = cs.S.base_pos and cs.S.base_pos[base_name]
        if not bp then
            cs.dbg("regen", "spawn BLOCKED: %s has no Airbase and no base_pos", tostring(base_name))
            return false
        end
        local gy = 0
        pcall(function() gy = land.getHeight({ x = bp.x, y = bp.z }) or 0 end)
        ab_pos = { x = bp.x, y = gy, z = bp.z }
    end

    supply.consume(base_name, atype, 1)

    local bx, by = cs.wp_xy(ab_pos)
    local id      = cs.next_id()
    local prefix  = (atype == "striker") and "Regen-Strike" or
                    (atype == "escort")  and "Regen-Escort" or "Regen-Heli"
    local gname   = string.format("%s-%d", prefix, id)

    local cat = (atype == "heli") and Group.Category.HELICOPTER or Group.Category.AIRPLANE

    local u = {
        name     = gname .. "-1",
        type     = aircraft_type,
        skill    = "Good",
        x        = ab_pos.x,
        y        = ab_pos.z,
        alt      = ab_pos.y,
        alt_type = "BARO",
        speed    = REGEN_SPEED,
        heading  = 0,
        payload  = { fuel = 4000, flare = 60, chaff = 60, gun = 100 },
    }

    local depart
    if ab_id then
        depart = { type = "TakeOff", action = "From Parking Area", airdromeId = ab_id,
                   alt = ab_pos.y, alt_type = "BARO", speed = 0, ETA = 0, ETA_locked = true,
                   x = bx, y = by, name = "Depart", formation_template = "" }
    else
        depart = { type = "TakeOffGroundHot", action = "From Ground Area Hot",
                   alt = ab_pos.y, alt_type = "BARO", speed = 0, ETA = 0, ETA_locked = true,
                   x = bx, y = by, name = "Depart", formation_template = "" }
    end
    local gspec = {
        name   = gname,
        task   = (atype == "heli") and "Transport" or "Ground Attack",
        hidden = false,
        units  = { u },
        route  = { points = { depart } },
    }
    if ab_id then gspec.airdromeId = ab_id end
    local grp = coalition.addGroup(cfg.country, cat, gspec)

    if grp then
        log_fn(string.format("regen: spawned %s %s at %s", gname, aircraft_type, base_name))
        cs.dbg("regen", "spawn SUCCESS: %s (%s) at %s", gname, aircraft_type, base_name)
        return true
    end
    cs.dbg("regen", "spawn FAILED: %s (%s) at %s (addGroup returned nil)", gname, aircraft_type, base_name)
    return false
end

-- ── regen_queue_use (rg_updt.c:820) ──────────────────────────────────────────
-- Pop front of FIFO, attempt spawn.  If blocked: leave in queue (don't pop).
local function process_queue(side, atype, log_fn)
    local q = S.regen_queue[side][atype]
    if not q or #q == 0 then return end

    local entry = q[1]  -- peek front (mirrors m1->front)

    -- Supply-scaled turnaround gate (KEYSITE-F9): the home base's ammo supply level scales the
    -- required rearm time. A well-supplied base (100) turns a replacement around in REGEN_PERIOD;
    -- a starved base (floor 10) takes up to ~4.6x as long. Not-yet-ready → leave queued, retry next tick.
    local level    = (S.base_ammo and S.base_ammo[entry.base_name]) or 100
    local required = REGEN_PERIOD * rearm_scale(level)
    local waited   = timer.getTime() - (entry.enqueued or 0)
    if waited < required then
        return
    end

    cs.dbg("regen", "dequeue attempt: %s/%s front=%s@%s (waited=%.0fs >= required=%.0fs, ammo=%.0f%%)",
        cs.SIDE_NAME[side], atype, entry.aircraft_type, entry.base_name, waited, required, level)
    if spawn_regen(side, atype, entry, log_fn) then
        table.remove(q, 1)  -- pop (mirrors regen_queue_use advancing front)
    end
    -- If blocked: leave in queue (EECH behaviour: regen retries next tick)
end

-- ── schedule_regen() ─────────────────────────────────────────────────────────
-- Mirrors update_server() sleep loop: period = regen_frequency * REGEN_UPDATE_MEDIUM
function M.schedule_regen(log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    cs.dbg("regen", "scheduler REGISTERED offset=%.0fs period=%.0fs", REGEN_PERIOD, REGEN_PERIOD)
    timer.scheduleFunction(function(_, t)
        -- INFRASTRUCTURE: regen keeps running post-victory. EECH's rg_updt.c regen tick is not gated on
        -- SESSION_COMPLETE (only on the usable/reserve/player-landed gates it already applies), and the
        -- world runs on after the win banner (fc_msgs.c:163). Cluster E — keep alive; only the
        -- re-injection guard cancels.
        if _DMT_GEN ~= my_gen then return nil end
        if not S.regen_queue then return t + REGEN_PERIOD end

        local ok, err = pcall(function()
            for _, side in ipairs(SIDES) do
                for _, atype in ipairs(TYPES) do
                    process_queue(side, atype, log_fn)
                end
            end
        end)
        if not ok then log_fn("regen tick error: " .. tostring(err)) end

        return t + REGEN_PERIOD  -- mirrors raw->sleep = regen_frequency * modifier
    end, nil, timer.getTime() + REGEN_PERIOD)
end

return M
