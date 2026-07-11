-- map_overlay.lua
-- F-10 map mission tasking overlay.
-- Mirrors EECH's campaign map briefing screen (briefing.c / campaign_map.c):
--   - Base ownership labels with health bars
--   - Active strike task arrows (attacker → target)
--   - Ground column position markers
--   - Frontline indicator (midpoint between nearest opposing bases)
--
-- DCS API used:
--   trigger.action.markToAll(id, text, pos, readonly, message)
--   trigger.action.markToCoalition(id, text, pos, coal, readonly, message)
--   trigger.action.removeMark(id)
--   trigger.action.lineToAll(coal, id, startPos, endPos, r, g, b, a, lineType)
--   trigger.action.textToAll(coal, id, pos, r, g, b, a, fillR, fillG, fillB, fillA,
--                            fontSize, readonly, text)
--   trigger.action.circleToAll(coal, id, pos, radius, r, g, b, a, fillR, fillG, fillB, fillA, lineType)

local cs = require("campaign_state")
local S  = cs.S
local M  = {}

-- ── Mark ID allocation ────────────────────────────────────────────────────────
-- Base labels: 10000 + sequential index
-- Task arrows: 20000 + task_id
-- Column marks: 30000 + side
-- Frontline:    40000

local BASE_MARK_START = 60000   -- moved out of the 10000 range: stale overlay schedulers from earlier
                                -- re-injects removeMark the old 10000 base range every tick and clobber
                                -- new base labels. 60000+ dodges them. (A fresh mission start also
                                -- clears the stale timers — the definitive fix.)
local TASK_MARK_START = 20000
local COL_MARK_BLUE   = 30001
local COL_MARK_RED    = 30002
local FRONT_MARK      = 40000

local UPDATE_PERIOD   = 30  -- seconds between overlay refreshes

-- Map from base name → mark ID (assigned on first draw)
local base_mark_ids   = {}
local base_last_label = {}   -- base name → last label issued (STABLE marks: update only on change)
local next_base_id    = BASE_MARK_START

-- Active task arrows: task_id → mark_id pair
local task_mark_ids = {}
local next_task_mark = TASK_MARK_START

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function world_to_mark_pos(wx, wz)
    -- trigger.action marks use {x=north, y=altitude, z=east}
    return { x = wx, y = 0, z = wz }
end

local function health_bar(h)
    -- 5-segment ASCII bar like EECH's keysite strength display
    local filled = math.floor(h * 5 + 0.5)
    return string.rep("|", filled) .. string.rep(".", 5 - filled)
end

-- ── Base ownership labels ──────────────────────────────────────────────────────
-- One mark per airbase; updated in-place (remove + re-add).
-- EECH analogue: draw_keysite_icon() in campaign_map.c

local function update_base_marks()
    for name, owner in pairs(S.base_owner) do
        local pos = S.base_pos[name]
        if pos then
            local mid = world_to_mark_pos(pos.x, pos.z)
            local h   = S.base_health[name] or 1.0
            -- Idle inventory is a PER-BASE ledger now (Cluster 4); show THIS base's parked aircraft.
            local pool = S.base_ledger and S.base_ledger[name]

            local side_tag = (owner == coalition.side.BLUE) and "BLUE" or "RED"
            local kind  = (S.base_kind and S.base_kind[name]) or "airbase"
            local ktag  = (kind == "airbase" and "AIRBASE (fixed-wing)")
                       or (kind == "fob" and "FOB (heli)")
                       or (kind == "farp" and "FARP (heli)") or "BASE"
            -- Item 1: a dormant FARP (sector not yet friendly) is flagged so the player sees it is not
            -- yet participating (it activates as the front reaches it).
            if kind == "farp" and not cs.base_is_active(name) then ktag = ktag .. " — DORMANT" end
            -- FOB/FARP are heli-only → show only the heli count; airbases show the fixed-wing pools too.
            local str_txt = "?"
            if pool then
                if kind == "airbase" then
                    str_txt = string.format("idle F%d E%d H%d", pool.striker or 0, pool.escort or 0, pool.heli or 0)
                else
                    str_txt = string.format("idle H%d T%d", pool.heli or 0, pool.transport or 0)
                end
            end
            local label = string.format("%s  [%s]\n%s\n%s %.0f%%\n%s",
                name, side_tag, ktag, health_bar(h), h * 100, str_txt)

            -- Allocate a stable ID for this base
            if not base_mark_ids[name] then
                base_mark_ids[name] = next_base_id
                next_base_id = next_base_id + 1
            end
            local mid_id = base_mark_ids[name]

            -- STABLE marks: only re-issue when the label actually changes. The previous code did
            -- removeMark+markToAll EVERY tick for every base, which made the labels flicker/vanish on
            -- the client (the remove and add race). Updating on change keeps them rendered.
            if base_last_label[name] ~= label then
                trigger.action.removeMark(mid_id)
                trigger.action.markToAll(mid_id, label, mid, true, "")  -- shown to all (shared campaign map)
                base_last_label[name] = label
            end
        end
    end
end

-- ── Active task arrows (Item 4 — RE-ENABLED with a reliable lifecycle) ─────────────────────────────
-- EECH analogue: draw_task_arrow() highlighting active offensive sorties on the campaign map.
--
-- The previous re-enable LEAKED (~170 orphaned line-marks) because remove_task_arrow was not reliably
-- called. This version keys the arrow by the sortie's DCS GROUP NAME (the same key the task registry
-- uses) and reaps it through TWO redundant paths so an arrow can never outlive its group:
--   (1) PRIMARY — cs.clear_task(gname) is the SINGLE chokepoint every registered task-end funnels
--       through (reaction LAND/DEAD, troop capture, keysite capture-termination, supply RTB). It
--       fires cs.task_end_hook = M.remove_task_arrow (wired in schedule_overlay), so a registered
--       sortie's arrow is removed the instant its task clears.
--   (2) BACKSTOP — gc_task_arrows() (run every refresh) removes any arrow whose group no longer
--       exists. This covers the non-registered arrow sources (CAS/BAI/SEAD run, heli sections) that
--       never enter the task registry, so EVERY arrow is bounded regardless of the clear_task path.
-- Mark ids are allocated in a bounded band [TASK_MARK_START, TASK_MARK_END] with wrap; reset.lua
-- clears 20000..20400 (covers the band) on every re-inject.
local TASK_MARK_END = 20399   -- inclusive band top (reset.lua clears 20000..20400)

local function alloc_task_mark()
    local id = next_task_mark
    next_task_mark = next_task_mark + 1
    if next_task_mark > TASK_MARK_END then next_task_mark = TASK_MARK_START end
    return id
end

-- add_task_arrow(gname, from_pos, to_pos, side): draw a side-coloured line from launch → target.
-- `gname` MUST be the sortie's DCS group name (so the GC backstop can test its existence). Idempotent
-- per key (a re-registered name replaces its old arrow).
function M.add_task_arrow(gname, from_pos, to_pos, side)
    if not gname or not from_pos or not to_pos then return end
    M.remove_task_arrow(gname)
    local id = alloc_task_mark()
    task_mark_ids[gname] = id
    local sp = world_to_mark_pos(from_pos.x, from_pos.z)
    local ep = world_to_mark_pos(to_pos.x, to_pos.z)
    -- BLUE arrow blue, RED arrow red; lineType 1 = solid.
    local r = (side == coalition.side.BLUE) and 0.2 or 0.9
    local g = 0.3
    local b = (side == coalition.side.BLUE) and 0.9 or 0.2
    pcall(trigger.action.lineToAll, -1, id, sp, ep, r, g, b, 0.6, 1)
    return id
end

function M.remove_task_arrow(gname)
    local mid = task_mark_ids[gname]
    if mid then
        pcall(trigger.action.removeMark, mid)
        task_mark_ids[gname] = nil
    end
end

-- GC backstop: reap any arrow whose group is gone (covers arrows never routed through clear_task).
local function gc_task_arrows()
    for gname, mid in pairs(task_mark_ids) do
        local ok, grp = pcall(Group.getByName, gname)
        local alive = ok and grp ~= nil and grp:isExist()
        if not alive then
            pcall(trigger.action.removeMark, mid)
            task_mark_ids[gname] = nil
        end
    end
end

-- ── Ground column markers ──────────────────────────────────────────────────────

local col_mark_prev = {}  -- [side] = highest mark index used last refresh (to clear the tail)

local function update_column_marks()
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local base_id = (side == coalition.side.BLUE) and COL_MARK_BLUE or COL_MARK_RED
        -- Clear the full band drawn last time, then redraw current groups (prevents orphaned marks
        -- when a side loses groups; pairs() order is nondeterministic so we clear rather than diff).
        for k = 0, (col_mark_prev[side] or 0) do trigger.action.removeMark(base_id * 100 + k) end
        local i = 0
        for _, rec in pairs((S.ground_groups and S.ground_groups[side]) or {}) do
            if cs.group_is_alive(rec.grp) then
                local u = rec.grp:getUnit(1)
                if u and u:isExist() then
                    local p = u:getPosition().p
                    trigger.action.markToAll(base_id * 100 + i,
                        string.format("[%s] Ground group → %s", cs.SIDE_NAME[side] or "?",
                            rec.target_base or "?"),
                        { x = p.x, y = 0, z = p.z }, true, "")
                    i = i + 1
                end
            end
        end
        col_mark_prev[side] = math.max(i - 1, col_mark_prev[side] or 0)
    end
end

-- ── Frontline indicator ────────────────────────────────────────────────────────
-- Draws a line connecting the midpoints of nearest BLUE–RED base pairs.
-- EECH analogue: draw_frontline() in ai_fline.c visual output.

local function update_frontline()
    trigger.action.removeMark(FRONT_MARK)

    -- Find the single closest BLUE–RED base pair to approximate the front
    local min_d, bx, bz, rx, rz = math.huge, 0, 0, 0, 0
    local found = false
    for bname, bowner in pairs(S.base_owner) do
        if bowner == coalition.side.BLUE then
            local bp = S.base_pos[bname]
            if bp then
                for rname, rowner in pairs(S.base_owner) do
                    if rowner == coalition.side.RED then
                        local rp = S.base_pos[rname]
                        if rp then
                            local d = cs.dist2d(bp.x, bp.z, rp.x, rp.z)
                            if d < min_d then
                                min_d = d
                                bx, bz = bp.x, bp.z
                                rx, rz = rp.x, rp.z
                                found = true
                            end
                        end
                    end
                end
            end
        end
    end

    if found then
        local mx = (bx + rx) * 0.5
        local mz = (bz + rz) * 0.5
        trigger.action.markToAll(FRONT_MARK,
            string.format("--- FRONTLINE ---\nBLUE str=%d RED str=%d",
                S.strength[coalition.side.BLUE] or 0,
                S.strength[coalition.side.RED]  or 0),
            { x = mx, y = 0, z = mz }, true, "")
    end
end

-- ── One-time startup sweep of leaked/orphaned task-arrow marks from earlier injects ──────
local cleaned_leaks = false
local function cleanup_leaked_marks()
    if cleaned_leaks then return end
    cleaned_leaks = true
    local ok, panels = pcall(world.getMarkPanels)
    if ok and panels then
        for _, p in ipairs(panels) do
            local id = p.idx or -1
            if id >= TASK_MARK_START and id < COL_MARK_BLUE then  -- 20000..30000 (old task arrows)
                pcall(trigger.action.removeMark, id)
            end
        end
    end
end

-- ── Installation markers: strategic infrastructure (producers = factories/refineries) ──
local INST_MARK_START = 50000
local inst_mark_ids   = {}
local inst_last_label = {}
local next_inst_id    = INST_MARK_START
local function update_installation_marks()
    for kname, rec in pairs(S.keysites or {}) do
        -- Mark EVERY non-airbase keysite (factory/refinery/depot/fuel/radar/command) with its type,
        -- owner and health — the full infrastructure picture (producers flagged in the label).
        if rec.pos then
            -- Zone-registered keysites carry their own side (rec.side); auto keysites follow home base.
            local owner    = rec.side or (rec.home_base and S.base_owner[rec.home_base])
            local side_tag = (owner == coalition.side.BLUE) and "BLUE" or "RED"
            local h        = rec.health or 1.0
            if not inst_mark_ids[kname] then inst_mark_ids[kname] = next_inst_id; next_inst_id = next_inst_id + 1 end
            local id    = inst_mark_ids[kname]
            -- PENDING (empty circle: author hasn't placed statics) shows a distinct placeholder, NOT a
            -- "0%" neutralised reading — it's excluded from the campaign until filled.
            local label
            if rec.pending then
                label = string.format("%s [%s] — empty (place statics)", rec.label or rec.kind, side_tag)
            elseif (h > 0.1) or (rec.assets ~= nil) then
                -- Registered asset count (alive/total) surfaces what the author placed, e.g. "(3/5)".
                local count_txt = rec.total and string.format(" (%d/%d)", rec.alive or 0, rec.total) or ""
                -- Under-populated keysite → warn the author to place more targets in the circle.
                local warn = rec.low_targets and "⚠ LOW TARGETS " or ""
                label = string.format("%s%s [%s] %.0f%%%s", warn, rec.label or rec.kind, side_tag, h * 100, count_txt)
            end
            if inst_last_label[kname] ~= label then
                trigger.action.removeMark(id)
                if label then trigger.action.markToAll(id, label, world_to_mark_pos(rec.pos.x, rec.pos.z), true, "") end
                inst_last_label[kname] = label
            end
        end
    end
end

-- ── Per-destructible asset indicators ─────────────────────────────────────────
-- A small map marker on EACH registered destructible (every placed static + every resource-scenery
-- object) so the author can see the individual targets, not just the aggregate keysite label. Placed
-- once and left in place (statics/scenery don't move); removed when that asset is destroyed, so the
-- indicators visibly thin out as a keysite is bombed down.
local ASSET_MARK_START = 70000
local asset_mark_ids   = {}   -- asset key ("S:"..staticName / "C:"..sceneryId) → mark id
local next_asset_id    = ASSET_MARK_START

local function draw_asset_mark(key, p, text)   -- p is a getPoint() table {x,y,z}
    if asset_mark_ids[key] then return end
    local id = next_asset_id; next_asset_id = next_asset_id + 1
    asset_mark_ids[key] = id
    -- Descriptive text (which keysite this destructible belongs to) — DCS stamps the mark's AUTHOR as
    -- "mission data" (unchangeable for scripted marks), so the text is where the useful info goes.
    trigger.action.markToAll(id, text or "\226\150\170", world_to_mark_pos(p.x, p.z), true, "")
end

local function remove_asset_mark(key)
    if asset_mark_ids[key] then
        trigger.action.removeMark(asset_mark_ids[key])
        asset_mark_ids[key] = nil
    end
end

local function update_asset_indicators()
    for _, rec in pairs(S.keysites or {}) do
        -- placed statics: mark each alive one; remove when it enters rec.dead
        if rec.assets then
            for _, nm in ipairs(rec.assets) do
                local key = "S:" .. tostring(nm)
                if rec.dead and rec.dead[nm] then
                    remove_asset_mark(key)
                elseif not asset_mark_ids[key] then
                    local so = StaticObject.getByName(nm)
                    if so and so:isExist() then
                        local p = so:getPoint()
                        if p then draw_asset_mark(key, p, "\226\150\170 " .. (rec.label or rec.kind or "target") .. " (target)") end
                    end
                end
            end
        end
        -- resource scenery: mark each alive handle; remove when the row is marked dead
        if rec.scenery then
            for _, row in ipairs(rec.scenery) do
                local key = "C:" .. tostring(row.id)
                if row.dead then
                    remove_asset_mark(key)
                elseif not asset_mark_ids[key] and row.handle then
                    local ok, p = pcall(row.handle.getPoint, row.handle)
                    if ok and p then
                        draw_asset_mark(key, { x = p.x, y = 0, z = p.z },
                            "\226\150\170 " .. (rec.label or "airfield") .. " (" .. tostring(row.type) .. ")")
                    end
                end
            end
        end
    end
end

-- ── Full refresh ──────────────────────────────────────────────────────────────

local function refresh(log_fn)
    local ok, err = pcall(function()
        cleanup_leaked_marks()
        update_base_marks()
        update_installation_marks()
        update_asset_indicators()
        update_column_marks()
        update_frontline()
        gc_task_arrows()   -- Item 4 backstop: reap arrows whose sortie group is gone
    end)
    if not ok and log_fn then
        log_fn("map_overlay error: " .. tostring(err))
        cs.dbg("mapov", "refresh FAILED: %s", tostring(err))
    end
end

-- ── Scheduler ─────────────────────────────────────────────────────────────────

function M.schedule_overlay(log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    -- Item 4: wire the task-end chokepoint so cs.clear_task reaps this task's arrow the instant it ends.
    cs.task_end_hook = M.remove_task_arrow
    cs.dbg("mapov", "overlay scheduler REGISTERED offset=5s period=%.0fs (task-arrow clear_task hook wired)", UPDATE_PERIOD)
    -- Initial draw after a short delay so all bases are registered
    timer.scheduleFunction(function(_, t)
        -- INFRASTRUCTURE: map overlay keeps refreshing post-victory (shows the final/continuing state).
        -- EECH fc_msgs.c:163 halts only the win-check, not the sim. Cluster E.
        if _DMT_GEN ~= my_gen then return nil end
        refresh(log_fn)
        return t + UPDATE_PERIOD
    end, nil, timer.getTime() + 5)
end

return M
