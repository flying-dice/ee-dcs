-- reset.lua
-- Dev-iteration reset: on EACH injection, nuke the previous campaign so a fresh order-of-battle
-- starts in the SAME running mission — no DCS restart needed to iterate (edit → build → inject).
--
-- What survives a re-inject and must be cleared here:
--   1. Units/groups placed in the DCS world by the previous campaign (Lua state resets on the
--      fresh bundle run + the _DMT_GEN generation guard cancels the old run's timers, but the
--      spawned OBJECTS live in the sim, not in Lua).
--   2. Event handlers registered via world.addEventHandler (never auto-removed → would stack).
--   3. F-10 overlay marks (map_overlay ID ranges).
-- Human players are never touched.

local cs = require("campaign_state")
local M  = {}

local function group_has_player(g)
    local ok, units = pcall(function() return g:getUnits() end)
    if not ok or not units then return false end
    for _, u in ipairs(units) do
        local okp, name = pcall(function() return u.getPlayerName and u:getPlayerName() end)
        if okp and name and name ~= "" then return true end
    end
    return false
end

function M.nuke(log_fn)
    log_fn = log_fn or env.info
    cs.dbg("reset", "nuke() starting: current generation=%d (old timers with a stale generation self-cancel)", cs.GENERATION)

    -- 1. Remove the previous injection's event handlers (game_loop tracks them here).
    local removed_h = 0
    if type(_G.__dmt_handlers) == "table" then
        for _, h in ipairs(_G.__dmt_handlers) do
            if pcall(world.removeEventHandler, h) then removed_h = removed_h + 1 end
        end
    end
    _G.__dmt_handlers = {}

    -- 2. Destroy every campaign-spawned group (skip any group holding a human player).
    local destroyed, skipped = 0, 0
    for _, side in ipairs({ coalition.side.NEUTRAL, coalition.side.RED, coalition.side.BLUE }) do
        local ok, groups = pcall(coalition.getGroups, side)
        if ok and type(groups) == "table" then
            for _, g in ipairs(groups) do
                if group_has_player(g) then
                    skipped = skipped + 1
                else
                    pcall(function() g:destroy() end)
                    destroyed = destroyed + 1
                end
            end
        end
    end

    -- 2b. Destroy CAMPAIGN-SPAWNED statics (template buildings / FARP pads / auto installations) so a
    -- re-inject re-templates cleanly. Statics survive re-injection (only groups auto-clear), so stale
    -- template buildings make an empty keysite look populated → the template + its garrison get skipped.
    -- Match campaign name prefixes ONLY (KS-/FARP-/Inst-); author-placed statics keep their own names.
    local ds = 0
    for _, side in ipairs({ coalition.side.NEUTRAL, coalition.side.RED, coalition.side.BLUE }) do
        local ok, objs = pcall(coalition.getStaticObjects, side)
        if ok and type(objs) == "table" then
            for _, so in ipairs(objs) do
                local okn, nm = pcall(function() return so:getName() end)
                if okn and type(nm) == "string" and
                   (nm:match("^KS%-") or nm:match("^FARP%-") or nm:match("^Inst%-")) then
                    pcall(function() so:destroy() end)
                    ds = ds + 1
                end
            end
        end
    end

    -- 3. Clear F-10 overlay marks. Base/column/front marks reuse STABLE ids (map_overlay overwrites
    --    them each draw), so only the task-arrow band accumulates. Keep the sweep small — a few
    --    thousand synchronous removeMark calls in one frame can trip the ANTIFREEZE watchdog.
    local function clear(a, b) for id = a, b do pcall(trigger.action.removeMark, id) end end
    clear(10000, 10050)   -- base labels (legacy range; still cleared for stale marks)
    clear(20000, 20400)   -- task arrows (map_overlay draws in 20000..20399; clear the band on re-inject)
    clear(30000, 30010)   -- ground column bands
    clear(40000, 40010)   -- frontline
    clear(50000, 50200)   -- installation labels (producers etc.)
    clear(60000, 60060)   -- base labels (current range — moved off 10000 to dodge stale schedulers)
    clear(70000, 70400)   -- per-destructible asset indicators (one small ▪ mark per static/scenery)

    log_fn(string.format(
        "[reset] fresh start — destroyed %d group(s), %d campaign static(s), skipped %d player group(s), "
        .. "removed %d handler(s), cleared overlay", destroyed, ds, skipped, removed_h))
    cs.dbg("reset", "nuke() done: %d groups destroyed, %d statics destroyed, %d player groups skipped, %d handlers removed",
        destroyed, ds, skipped, removed_h)
end

return M
