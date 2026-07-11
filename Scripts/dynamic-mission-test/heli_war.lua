-- heli_war.lua
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c (create_cas_tasks / anti-armour tasks),
--   aphavoc/source/ai/highlevl/suitable.c (suitability matrix — ATTACK_HELICOPTER is the primary
--   suitable type for anti-armour / CAS / armed-recon / escort in campaign),
--   aphavoc/source/entity/helicopter/* (attack helicopter behaviour).
--
-- EECH ("Enemy Engaged": Comanche vs Hokum / Apache vs Havoc) is FUNDAMENTALLY a helicopter combat
-- sim — attack helicopters are the main offensive arm and the bulk of the campaign's sorties. The
-- fixed-wing strike/CAS/BAI/SEAD tasks (attack_waves / cas_bai_sead) model the air-force layer; THIS
-- module models the rotary-wing war that is the heart of the game:
--   1. Anti-armour sorties  — attack-heli sections hunt enemy frontline ground groups (core mission)
--   2. Hunter-killer recon  — armed recon along the front, engaging ground AND air (incl. enemy helis)
--   3. Attack-heli escort   — escorts transport/BDA/troop-insertion helis into hostile airspace
-- All draw from the per-side "heli" reserve (finite; recycled on RTB by supply.make_land_handler).

local cs      = require("campaign_state")
local croute  = require("croute")
local ov      = require("map_overlay")
local config  = require("config")
local board   = require("task_board")
local S       = cs.S
local M       = {}

-- ── Attack helicopter roster (hoisted to config: attack_heli type + payloads.attack_heli pylons) ──
-- fuel is a spawn-kinematics amount (not warzone type/economy data) → kept module-local per side.
local HELI_FUEL = { [coalition.side.BLUE] = 1600, [coalition.side.RED] = 1500 }
local ATTACK = {}
for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
    ATTACK[side] = {
        country = config.C.countries[side],
        type    = config.C.types.aircraft[side].attack_heli,
        pylons  = config.C.payloads[side].attack_heli,
        fuel    = HELI_FUEL[side],
    }
end

-- A section = 2 attack helis (draws 2 from the "heli" reserve). Used by build_attack_heli.
-- (The retired anti_armour / hunter_killer scheduler PERIODS were deleted in Cluster H — the rotary
-- frontline fight is now CAS + BAI, launched by cas_bai_sead via this module's build_attack_heli.)
local SECTION_SIZE = 2

-- Attack profile: low and slow, nap-of-the-earth-ish.
local HELI_ALT   = 60      -- m AGL cruise
local HELI_SPEED = 55      -- m/s ≈ 107 kt
local ENGAGE_DIST = 12000  -- m; attack helis engage targets within this range

-- NOTE: frontline_point, heli_sorties and front_targets were DELETED in Cluster H — they only fed the
-- retired schedule_anti_armour / schedule_hunter_killer schedulers (a PORT INVENTION; EECH has no
-- anti_armour/hunter_killer task — the rotary frontline fight IS CAS + BAI). heli_sorties' strength-
-- ratio sortie scaler was itself an invented posture mechanic (Cluster E territory). This module now
-- keeps only the shared attack-heli / escort BUILDERS (build_attack_heli, spawn_escort).

-- ── build_attack_heli(side, base_name, target_pos, role, log_fn) ──────────────
-- BUILDER (task-board contract): spawns an attack-heli section FROM base_name. The board has
-- already consumed SECTION_SIZE "heli" from base_name's ledger (refunds on nil). Returns the
-- group on success, nil on failure. role "anti_armour" (attack ground) or "hunter_killer"
-- (armed recon: ground + air).
local function build_attack_heli(side, base_name, target_pos, role, log_fn)
    log_fn = log_fn or function() end
    -- Launch position: a real Airbase (AIRDROME or HELIPAD) if the base has one — helis launch from
    -- fixed-wing airbases too — otherwise the logical base's own coordinates (a zone-authored FARP has
    -- no Airbase object). Helis start from a real airbase via TakeOff-from-parking, or from a bare
    -- position via a GROUND start. Only truly-unknown bases (no Airbase AND no S.base_pos) fail.
    local home_ab = Airbase.getByName(base_name)
    local cfg    = ATTACK[side]
    local ab_pos, ab_id
    if home_ab then
        ab_pos, ab_id = home_ab:getPosition().p, home_ab:getID()
    else
        local bp = S.base_pos and S.base_pos[base_name]
        if not bp then
            cs.dbg("heli", "%s heli ABORT: base %s has no Airbase and no base_pos",
                cs.SIDE_NAME[side], tostring(base_name))
            return nil
        end
        local gy = 0
        pcall(function() gy = land.getHeight({ x = bp.x, y = bp.z }) or 0 end)
        ab_pos = { x = bp.x, y = gy, z = bp.z }   -- ground start at the FARP coordinates
    end
    local bx, by = cs.wp_xy(ab_pos)
    local tx, ty = cs.wp_xy(target_pos)
    local sid    = cs.next_id()
    local ROLE_LABEL = { anti_armour = "AA", hunter_killer = "HK", cas = "CAS", bai = "BAI" }
    local gname  = string.format("Heli-%s-%d-%d", ROLE_LABEL[role] or "AA", side, sid)

    -- Hunter-killer engages air too (Comanche-vs-Hokum heli combat); anti-armour focuses ground.
    local target_types = (role == "hunter_killer")
        and { "Ground Units", "Helicopters", "Air" }
        or  { "Ground Units", "Helicopters" }

    local units = {}
    for i = 1, SECTION_SIZE do
        units[i] = {
            name = gname .. "-" .. i, type = cfg.type, skill = "High",
            x = ab_pos.x + (i-1)*40, y = ab_pos.z, alt = ab_pos.y, alt_type = "BARO",
            speed = 0, heading = cs.heading_to(ab_pos.x, ab_pos.z, target_pos.x, target_pos.z),
            payload = { fuel = cfg.fuel, flare = 60, chaff = 60, gun = 100, pylons = cfg.pylons },
        }
    end

    -- Depart/RTB points: a real airbase uses TakeOff-from-parking + Landing; a bare-coordinate FARP
    -- uses a ground start (From Ground Area) and returns to a hover point over its own position.
    local depart, rtb
    if ab_id then
        depart = { type="TakeOff", action="From Parking Area", airdromeId=ab_id,
                   alt=ab_pos.y, alt_type="BARO", speed=0, ETA=0, ETA_locked=true,
                   x=bx, y=by, name="Depart", formation_template="" }
        rtb    = { type="Land", action="Landing", airdromeId=ab_id, alt=ab_pos.y, alt_type="BARO",
                   speed=HELI_SPEED, ETA=0, ETA_locked=false, x=bx, y=by, name="RTB", formation_template="" }
    else
        depart = { type="TakeOffGroundHot", action="From Ground Area Hot", alt=ab_pos.y, alt_type="BARO",
                   speed=0, ETA=0, ETA_locked=true, x=bx, y=by, name="Depart", formation_template="" }
        rtb    = { type="Turning Point", action="Turning Point", alt=HELI_ALT, alt_type="RADIO",
                   speed=HELI_SPEED, ETA=0, ETA_locked=false, x=bx, y=by, name="RTB", formation_template="" }
    end
    local gspec = { name = gname, task = "CAS", hidden = false, units = units, route = { points = croute.expand({
        depart,
        { type="Turning Point", action="Turning Point", alt=HELI_ALT, alt_type="RADIO",
          speed=HELI_SPEED, ETA=0, ETA_locked=false, x=tx, y=ty, name="Engage", formation_template="",
          task = { id="ComboTask", params={ tasks={ [1]={ number=1, auto=true, id="EngageTargets",
            enabled=true, params={ maxDist=ENGAGE_DIST, priority=0, targetTypes=target_types } } }}}},
        rtb,
    }, side, { alt=HELI_ALT, alt_type="RADIO", speed=HELI_SPEED, name="Nav" }) }}
    if ab_id then gspec.airdromeId = ab_id end
    local _ok, grp = pcall(coalition.addGroup, cfg.country, Group.Category.HELICOPTER, gspec)
    if _ok and grp then
        ov.add_task_arrow(gname, ab_pos, target_pos, side)   -- Item 4: key by group name (GC backstop reaps it)
        log_fn(string.format("%s %s heli section (%dx%s) from %s → (%.0f,%.0f)",
            cs.SIDE_NAME[side], role, SECTION_SIZE, cfg.type, base_name, target_pos.x, target_pos.z))
        cs.dbg("heli", "%s %s heli section #%d spawned from %s (ground_start=%s)",
            cs.SIDE_NAME[side], role, sid, base_name, tostring(ab_id == nil))
        return grp
    end
    cs.dbg("heli", "%s heli spawn FAILED at %s (type=%s ground_start=%s): pcall_ok=%s err=%s",
        cs.SIDE_NAME[side], tostring(base_name), tostring(cfg.type), tostring(ab_id == nil),
        tostring(_ok), tostring(grp))
    return nil
end

-- NOTE: create_heli_task, schedule_anti_armour and schedule_hunter_killer were DELETED in Cluster H.
-- They were a PORT INVENTION (EECH has no anti_armour/hunter_killer task) already retired from
-- game_loop; the rotary frontline fight is CAS + BAI, launched by cas_bai_sead through the shared
-- build_attack_heli builder below.

-- ── Attack-heli escort (called when a transport/BDA/troop-insertion heli launches) ──
-- BUILDER: spawns a single attack heli FROM base_name to shepherd a transport toward target_pos.
local function build_escort(side, base_name, target_pos, log_fn)
    log_fn = log_fn or function() end
    local home_ab = Airbase.getByName(base_name)
    if not home_ab then
        cs.dbg("heli", "%s build_escort ABORT: base %s not found", cs.SIDE_NAME[side], tostring(base_name))
        return nil
    end
    local cfg    = ATTACK[side]
    local ab_pos = home_ab:getPosition().p
    local bx, by = cs.wp_xy(ab_pos)
    local tx, ty = cs.wp_xy(target_pos)
    local sid    = cs.next_id()
    local gname  = string.format("Heli-ESC-%d-%d", side, sid)

    local _ok, grp = pcall(coalition.addGroup, cfg.country, Group.Category.HELICOPTER, {
        name = gname, task = "Escort", hidden = false, airdromeId = home_ab:getID(),
        units = {{ name=gname.."-1", type=cfg.type, skill="High",
            x=ab_pos.x, y=ab_pos.z, alt=ab_pos.y, alt_type="BARO", speed=0,
            heading=cs.heading_to(ab_pos.x, ab_pos.z, target_pos.x, target_pos.z),
            payload={ fuel=cfg.fuel, flare=60, chaff=60, gun=100, pylons=cfg.pylons } }},
        route = { points = croute.expand({
            { type="TakeOff", action="From Parking Area", airdromeId=home_ab:getID(),
              alt=ab_pos.y, alt_type="BARO", speed=0, ETA=0, ETA_locked=true,
              x=bx, y=by, name="Depart", formation_template="" },
            { type="Turning Point", action="Turning Point", alt=HELI_ALT, alt_type="RADIO",
              speed=HELI_SPEED, ETA=0, ETA_locked=false, x=tx, y=ty, name="Escort", formation_template="",
              task = { id="ComboTask", params={ tasks={ [1]={ number=1, auto=true, id="EngageTargets",
                enabled=true, params={ maxDist=ENGAGE_DIST, priority=0,
                targetTypes={ "Ground Units", "Helicopters", "Air" } } } }}}},
            { type="Land", action="Landing", airdromeId=home_ab:getID(), alt=ab_pos.y, alt_type="BARO",
              speed=HELI_SPEED, ETA=0, ETA_locked=false, x=bx, y=by, name="RTB", formation_template="" },
        }, side, { alt=HELI_ALT, alt_type="RADIO", speed=HELI_SPEED, name="Nav" })},
    })
    if _ok and grp then
        log_fn(string.format("%s attack-heli escort #%d → (%.0f,%.0f)", cs.SIDE_NAME[side], sid, target_pos.x, target_pos.z))
        cs.dbg("heli", "%s escort #%d spawned from %s", cs.SIDE_NAME[side], sid, base_name)
        return grp
    end
    cs.dbg("heli", "%s escort #%d SPAWN FAILED from %s: pcall_ok=%s err=%s",
        cs.SIDE_NAME[side], sid, base_name, tostring(_ok), tostring(grp))
    return nil
end

-- ── spawn_escort(side, target_pos, log_fn) — SINGLE-SHOT EXPORT (never-replace list) ──
-- Reimplemented as an immediate create_task wrapper (create_escort_task at assignment, assign.c:598):
-- the board picks the launch base from the "heli" ledger and calls build_escort. Same signature.
function M.spawn_escort(side, target_pos, log_fn)
    log_fn = log_fn or function() end
    if not target_pos then
        cs.dbg("heli", "%s spawn_escort ABORT: no target_pos", cs.SIDE_NAME[side])
        return false
    end
    cs.dbg("heli", "%s spawn_escort: queueing immediate escort task", cs.SIDE_NAME[side])
    board.create_task({
        type = "heli_escort", side = side, count = 1, immediate = true, log_fn = log_fn,
        target = { pos = target_pos },
        builder = function(base_name) return build_escort(side, base_name, target_pos, log_fn) end,
    })
    return true
end

-- Exposed so cas_bai_sead can launch the CAS/BAI frontline fight as ATTACK-HELICOPTER sections from
-- FARPs (EECH: CAS/BAI are helicopter-eligible, ts_dbase.c landing_types :511/:329, and the rotary
-- frontline fight IS CAS/BAI — this replaces the invented anti_armour/hunter_killer schedulers).
M.build_attack_heli = build_attack_heli

return M
