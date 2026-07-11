-- recon.lua
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c  create_recon_task (called from the
--   strike-vs-recon fork in create_bai_tasks:785, create_sead_tasks:2093, create_oca_*_tasks,
--   create_keysite_strike_tasks:1051) and aphavoc/source/ai/highlevl/reaction.c (recon of AA
--   groups / frontline groups → SEAD/BAI chain).
--
-- THE RECON FORK (the single most important behavioural fix): in EECH the fog-of-war gate on a
-- strike task is not a filter that drops fogged targets — it is a FORK. When the highest-value
-- candidate's sector is under-reconned, the task generator creates a RECON task INSTEAD of the
-- strike. The recon flight overflies the target, which raises that sector's fog-of-war value, so
-- next cycle the target is revealed and becomes strikeable. Without this, a fogged sector never
-- generates recon → its FOW never rises → the target is invisible to the tasker forever (a dead
-- loop). EECH self-heals; the previous port self-stalled.
--
-- A recon flight is a fast, high-altitude overflight of the target. Its presence near the target
-- keysite grants fog-of-war to the recon side via fog_of_war.lua's per-unit recon scan. It draws
-- from the side's "recon" reserve pool, RTBs, and is recycled on landing (supply.make_land_handler).

local cs      = require("campaign_state")
local croute  = require("croute")
local ov      = require("map_overlay")
local board   = require("task_board")
local config  = require("config")
local M       = {}

-- ── Recon airframe per side (hoisted to config.lua) ───────────────────────────
-- Fast, high-flying types for a survivable overflight. Consumes the "recon" reserve
-- pool (distinct from striker/escort), so recon sorties never starve strike packages.
local AC = {}
for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
    AC[side] = { country = config.C.countries[side], recon = config.C.types.aircraft[side].recon }
end

local RECON_ALT   = 8000   -- m AMSL — high overflight
local RECON_SPEED = 300    -- m/s ≈ 580 kt — fast dash in/out

-- ── build_recon(side, base_name, target_pos, label, log_fn, objective) ────────
-- BUILDER (task-board contract): physically spawns one recon overflight FROM base_name toward
-- target_pos. The board has already consumed 1 "recon" from base_name's ledger and refunds on nil.
-- Returns the DCS group on success, nil on failure. No reserve accounting here (the board owns it).
local function build_recon(side, base_name, target_pos, label, log_fn, objective)
    log_fn = log_fn or function() end
    label  = label or "RECON"
    local home_ab = Airbase.getByName(base_name)
    if not home_ab then
        cs.dbg("recon", "%s build_recon ABORT: base %s not found", cs.SIDE_NAME[side], tostring(base_name))
        return nil
    end

    local cfg    = AC[side]
    local ab_pos = home_ab:getPosition().p
    local bx, by = cs.wp_xy(ab_pos)
    local tx, ty = cs.wp_xy(target_pos)
    local sid    = cs.next_id()
    local gname  = string.format("Recon-%d-%d", side, sid)

    local grp = coalition.addGroup(cfg.country, Group.Category.AIRPLANE, {
        name       = gname,
        task       = "Reconnaissance",
        hidden     = false,
        airdromeId = home_ab:getID(),
        units = {{
            name = gname .. "-1", type = cfg.recon, skill = "High",
            x = ab_pos.x, y = ab_pos.z, alt = ab_pos.y, alt_type = "BARO",
            speed = 0, heading = cs.heading_to(ab_pos.x, ab_pos.z, target_pos.x, target_pos.z),
            payload = { fuel = 5200, flare = 120, chaff = 120, gun = 100 },
        }},
        route = { points = croute.expand({
            { type="TakeOff", action="From Parking Area", airdromeId=home_ab:getID(),
              alt=ab_pos.y, alt_type="BARO", speed=0, ETA=0, ETA_locked=true,
              x=bx, y=by, name="Depart", formation_template="" },
            -- Overfly the target at high speed/altitude — grants fog-of-war on arrival.
            { type="Turning Point", action="Fly Over Point",
              alt=RECON_ALT, alt_type="BARO", speed=RECON_SPEED,
              ETA=0, ETA_locked=false, x=tx, y=ty, name="Recon", formation_template="",
              -- No EngageTargets task: recon observes, it does not fight.
            },
            { type="Land", action="Landing", airdromeId=home_ab:getID(),
              alt=ab_pos.y, alt_type="BARO", speed=RECON_SPEED, ETA=0, ETA_locked=false,
              x=bx, y=by, name="RTB", formation_template="" },
        }, side, { alt=RECON_ALT, alt_type="BARO", speed=RECON_SPEED, name="Nav" })},
    })

    if grp then
        cs.register_task(gname, {
            task_type   = "recon",
            side        = side,
            target_base = objective and objective.base or nil,
            target_pos  = target_pos,
            objective   = objective or { kind = "keysite" },
            born_time   = timer.getTime(),
        })
        ov.add_task_arrow(gname, ab_pos, target_pos, side)   -- Item 4: key by group name (clear_task reaps it)
        log_fn(string.format("%s %s RECON #%d from %s → (%.0f,%.0f)",
            cs.SIDE_NAME[side], label, sid, home_ab:getName(), target_pos.x, target_pos.z))
        cs.dbg("recon", "%s RECON #%d spawned from %s -> obj=%s", cs.SIDE_NAME[side], sid,
            home_ab:getName(), objective and (objective.base or objective.kind) or "pos")
        return grp
    end
    cs.dbg("recon", "%s RECON spawn FAILED from %s (addGroup returned nil)", cs.SIDE_NAME[side], base_name)
    return nil
end

-- ── spawn_recon(side, target_pos, label, log_fn, objective) ───────────────────
-- SINGLE-SHOT EXPORT (unchanged signature; called by apply_fork's recon fork and reaction chains).
-- Reimplemented as a create_task wrapper with immediate assignment: the board picks the suitable
-- launch base from the "recon" ledger (nearest, in range) and calls build_recon. If no recon
-- inventory is reachable the task sits UNASSIGNED and retries until its 10-min expiry (then FAILED).
-- objective (optional) = { kind="keysite"|"aa_group"|"frontline_group", base=name, group=, pos= }.
-- Returns true when a task was created (queued or assigned) — the caller uses it as a per-sector
-- "task placed" signal, which holds whether assignment is immediate or deferred.
-- `critical` (optional, WAVE 3 Item 4): the counter-battery RECON reaction is critical=TRUE
-- (reaction.c:803 create_recon_task) — reaction.lua passes true there. Generator/apply-fork recon callers
-- omit it → M.create_task falls back to the M.CRITICAL default (recon is not critical there), unchanged.
function M.spawn_recon(side, target_pos, label, log_fn, objective, critical)
    log_fn = log_fn or function() end
    label  = label or "RECON"
    if not target_pos then
        cs.dbg("recon", "%s spawn_recon ABORT: no target_pos (label=%s)", cs.SIDE_NAME[side], label)
        return false
    end
    cs.dbg("recon", "%s spawn_recon: queueing task (label=%s obj=%s)", cs.SIDE_NAME[side], label,
        objective and (objective.base or objective.kind) or "pos")
    board.create_task({
        type = "recon", side = side, count = 1, immediate = true, log_fn = log_fn,
        critical = critical,   -- nil for generators (M.CRITICAL default); true from counter-battery recon
        target = { base = objective and objective.base or nil, pos = target_pos,
                   group = objective and objective.group, objective = objective },
        builder = function(base_name)
            return build_recon(side, base_name, target_pos, label, log_fn, objective)
        end,
    })
    return true
end

return M
