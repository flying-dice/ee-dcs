-- transfer.lua
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c
--
-- create_fixed_wing_transfer_tasks()  line 2132
--   Period:  15.0*ONE_MINUTE (skirmish line 232 / campaign line 262)
--   Offsets: 34.0 s (skirmish) / 2.5*ONE_MINUTE=150 s (campaign)
--   Score: base_dist*4 + (1 - min(idle_count,4)*0.25)*4;  max=8.0
--   Commented-out terms (importance, airdef, surfdef) are NOT included.
--   Pairing: sort descending; top CREATE_TRANSFER_TASK_COUNT=3 receive from bottom donors.
--     keysite_count = min(count/2, CREATE_TRANSFER_TASK_COUNT)  (line 2294)
--     donar = target_list[loop2]  (highest index = lowest rating = most idle aircraft)
--     target = target_list[loop]  (lowest index = highest rating = most needed reinforcement)
--     Condition: donor != target; target has landing sites available.
--
-- create_helicopter_transfer_tasks() line 2352
--   Period:  10.0*ONE_MINUTE (skirmish line 238) / 7.5*ONE_MINUTE (campaign line 260)
--   Offsets: 3.0*ONE_MINUTE=180 s (skirmish) / 2.0*ONE_MINUTE=120 s (campaign)
--   Score: IDENTICAL formula and max to fixed-wing (same source block, same coefficients).
--
-- EECH constants:
--   CREATE_TRANSFER_TASK_COUNT = 3 (line 102)
--   MAX_HIGHLEVEL_TARGET_CHECKS = 160 (line 84)
--
-- DCS proxy notes:
--   EECH transfers fly real aircraft from donor keysite to target keysite via task.
--   DCS proxy: immediately adjust supply.available() counts — consume from donor,
--   produce at target.  No flight is spawned; the aircraft materialises at the new base.
--   idle_group_count proxy: supply.available(base, type) — more reserve = more idle.
--   Clamped to [0, 4] then ×0.25, matching EECH: min(idle, 4.0f) × 0.25.

local cs     = require("campaign_state")
local imap_m = require("imap")
local supply = require("supply")
local S      = cs.S
local M      = {}

-- ── EECH constants ─────────────────────────────────────────────────────────────
local CREATE_TRANSFER_TASK_COUNT = 3    -- highlevl.c line 102
local MAX_HIGHLEVEL_TARGET_CHECKS = 160 -- highlevl.c line 84
local TRANSFER_MAX_RATING         = 8.0 -- highlevl.c lines 2264, 2474

-- ── Periods (from add_high_level_ai_function; Item 5: mode-selected via campaign_mode.lua) ────────
local mode        = require("campaign_mode")
local PERIOD_FW   = mode.SCHED.fw_transfer.period  -- :262 15min campaign / :232 15min skirmish
local OFFSET_FW   = mode.SCHED.fw_transfer.blue    -- :262 campaign offset 2.5 min (fallback offset)
local PERIOD_HC   = mode.SCHED.hc_transfer.period  -- :260 7.5min campaign / :238 10min skirmish
local OFFSET_HC   = mode.SCHED.hc_transfer.blue    -- :260 campaign offset 2.0 min (fallback offset)

-- ── idle_group_count proxy ────────────────────────────────────────────────────
-- EECH: counts GROUP_MODE_IDLE groups physically attached to a keysite that match
-- the landing type (FW or HC).
-- DCS proxy: count alive same-side groups whose lead unit is within 5 km of the base.
-- These represent groups currently "at" the base (parked / idle), matching EECH semantics.
-- S.base_idle_groups[name] is updated by update_idle_groups() each transfer tick.
-- Falls back to supply.available() if the idle count table is not yet populated.
local IDLE_RADIUS = 5000  -- metres; groups within this radius count as "at" the base

local function update_idle_groups(side)
    S.base_idle_groups = S.base_idle_groups or {}
    local r2 = IDLE_RADIUS * IDLE_RADIUS
    -- Reset counts for all own bases
    for name, owner in pairs(S.base_owner) do
        if owner == side then S.base_idle_groups[name] = 0 end
    end
    -- Count alive groups near each base
    local grps = coalition.getGroups(side)
    if not grps then return end
    for _, grp in ipairs(grps) do
        if grp and grp:isExist() then
            local u = grp:getUnit(1)
            if u and u:isExist() then
                local gpos = u:getPosition().p
                for name, owner in pairs(S.base_owner) do
                    if owner == side then
                        local bpos = S.base_pos[name]
                        if bpos then
                            local dx = gpos.x - bpos.x
                            local dz = gpos.z - bpos.z
                            if dx*dx + dz*dz <= r2 then
                                S.base_idle_groups[name] = (S.base_idle_groups[name] or 0) + 1
                            end
                        end
                    end
                end
            end
        end
    end
end

local function idle_fraction(base_name)
    local count = S.base_idle_groups and S.base_idle_groups[base_name] or 0
    local clamped = math.min(count, 4.0)
    return clamped * 0.25  -- maps 0→0.0, 1→0.25, 2→0.5, 3→0.75, 4→1.0
end

-- ── Score (shared between FW and HC — formulas are identical in EECH source) ──
-- rating = base_dist*4 + (1 - idle_fraction)*4
-- IMAP_BASE_DISTANCE is queried for ENEMY side (closest to enemy base → most threatened)
local function score_base(base_name, enemy_side, side, atype)
    local bpos = S.base_pos[base_name]
    if not bpos then return 0.0 end
    -- Base must be usable: eff >= min inclusive (KEYSITE_STATE_USABLE, keysite.c:827-830)
    local h = S.base_health[base_name] or 0.0
    if h < cs.HEALTH_NEUTRALISED then return 0.0 end

    local bdist = imap_m.get(enemy_side, imap_m.BASE_DISTANCE, bpos)
    local idle  = idle_fraction(base_name)

    -- EECH formula: base_dist*4 + (1 - min(idle,4)*0.25)*4; max=8.0
    -- Commented-out terms (importance, airdef, surfdef) not included per source.
    return bdist * 4.0 + (1.0 - idle) * 4.0
end

-- ── Transfer one unit from donor to target ────────────────────────────────────
-- Mirrors create_transfer_task: aircraft moves from donar keysite to target keysite.
-- DCS proxy: consume 1 from donor supply, produce 1 at target.
local function do_transfer(atype, donor_name, target_name, side, log_fn)
    if not supply.consume(donor_name, atype, 1) then
        log_fn(string.format("transfer: no %s at donor %s", atype, donor_name))
        cs.dbg("transfer", "%s transfer ABORT: no %s at donor %s", cs.SIDE_NAME[side], atype, donor_name)
        return false
    end
    supply.produce(target_name, atype, 1)
    log_fn(string.format("%s transfer (%s): %s → %s",
        cs.SIDE_NAME[side], atype, donor_name, target_name))
    cs.dbg("transfer", "%s transfer: 1x %s %s -> %s", cs.SIDE_NAME[side], atype, donor_name, target_name)
    return true
end

-- ── Shared transfer scheduler for FW or HC ────────────────────────────────────
local function run_transfer(side, atype, log_fn)
    local enemy  = cs.ENEMY[side]
    -- Update idle group count before scoring (mirrors GROUP_MODE_IDLE scan per keysite)
    update_idle_groups(side)
    local ratings = {}

    -- Score all own bases
    for name, owner in pairs(S.base_owner) do
        if owner == side then
            local r = score_base(name, enemy, side, atype)
            if r > 0.0 then
                ratings[#ratings + 1] = { name = name, rating = r }
            end
        end
    end

    if #ratings < 2 then
        cs.dbg("transfer", "%s %s: only %d usable base(s) rated, skipping (need >=2)", cs.SIDE_NAME[side], atype, #ratings)
        return
    end  -- need at least one donor and one target

    -- Sort descending (highest rating first = most needs reinforcement)
    table.sort(ratings, function(a, b) return a.rating > b.rating end)

    -- keysite_count = min(count/2, CREATE_TRANSFER_TASK_COUNT)  (line 2294/2514)
    local keysite_count = math.min(math.floor(#ratings / 2), CREATE_TRANSFER_TASK_COUNT)
    local loop2 = #ratings  -- bottom index (lowest rating = most idle = donor)
    local n_done = 0

    for loop = 1, keysite_count do
        local target = ratings[loop]
        local donor  = ratings[loop2]
        -- Mirrors: donar = target_list[loop2]; target = target_list[loop]
        -- Guard: donor != target (EECH checks landing sites; we check names and supply)
        if target.name ~= donor.name and supply.available(donor.name, atype) > 0 then
            if do_transfer(atype, donor.name, target.name, side, log_fn) then n_done = n_done + 1 end
        end
        loop2 = loop2 - 1
    end
    cs.dbg("transfer", "%s %s: %d bases rated -> %d pairing slots -> %d transfers executed",
        cs.SIDE_NAME[side], atype, #ratings, keysite_count, n_done)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Fixed-wing transfer scheduler
-- ═══════════════════════════════════════════════════════════════════════════════
function M.schedule_fw_transfer(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    local offset = initial_offset or OFFSET_FW
    cs.dbg("transfer", "%s FW transfer scheduler REGISTERED offset=%.0fs period=%.0fs", cs.SIDE_NAME[side], offset, PERIOD_FW)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end    -- re-injection guard: cancel superseded closure
        -- Item 6: transfers keep running post-victory (EECH fc_msgs.c:163 gates only the win re-award).
        cs.dbg("transfer", "%s FW transfer FIRE", cs.SIDE_NAME[side])
        local ok, err = pcall(function()
            run_transfer(side, "striker", log_fn)
            run_transfer(side, "escort", log_fn)
        end)
        if not ok then log_fn("FW transfer error: " .. tostring(err)) end
        return t + PERIOD_FW
    end, nil, timer.getTime() + offset)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Helicopter transfer scheduler
-- ═══════════════════════════════════════════════════════════════════════════════
function M.schedule_hc_transfer(side, initial_offset, log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    local offset = initial_offset or OFFSET_HC
    cs.dbg("transfer", "%s HC transfer scheduler REGISTERED offset=%.0fs period=%.0fs", cs.SIDE_NAME[side], offset, PERIOD_HC)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end    -- re-injection guard: cancel superseded closure
        -- Item 6: transfers keep running post-victory (EECH fc_msgs.c:163 gates only the win re-award).
        cs.dbg("transfer", "%s HC transfer FIRE", cs.SIDE_NAME[side])
        local ok, err = pcall(function()
            run_transfer(side, "heli", log_fn)
        end)
        if not ok then log_fn("HC transfer error: " .. tostring(err)) end
        return t + PERIOD_HC
    end, nil, timer.getTime() + offset)
end

return M
