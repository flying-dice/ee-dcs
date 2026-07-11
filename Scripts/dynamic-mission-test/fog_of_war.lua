-- fog_of_war.lua
-- EECH source: aphavoc/source/entity/special/sector/sector.c
--   update_client_server_sector_fog_of_war() line 562
--   update_sector_fog_of_war() line 533  — subtracts FOG_OF_WAR_DECAY_RATE every period
--   set_sector_fog_of_war_value() line 374 — units grant fog proportional to (1-r/recon_radius)*maximum
-- EECH source: aphavoc/source/ai/highlevl/highlevl.h
--   FOG_OF_WAR_DECAY_RATE    = 30.0
--   DEFAULT_FOG_OF_WAR_MAXIMUM_VALUE = 4.0 * ONE_HOUR = 4.0 * 3600 = 14400
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c line 280
--   add_high_level_ai_function(update_client_server_sector_fog_of_war, FOG_OF_WAR_DECAY_RATE, 8.0)
--   → period = 30 s, initial offset = 8 s
-- EECH source: highlevl.c FOW threshold usage:
--   line 1433, 1620, 2072, 2653, 3062: fow >= 0.25 * maximum  → proceed with task
--   line 1179: fow < 0.25 * maximum  → create recon instead
--   line 1819: fow < 0.20 * maximum  → create recon instead (troop insertion, stricter)
--
-- DCS proxy: EECH stores per-sector fog values.  DCS has no sector grid, so we track
-- per-base fog-of-war for each side.  Units within RECON_RADIUS of a base grant fog.
-- Normalised value returned by get() is raw / FOW_MAX (0.0–1.0).

local cs = require("campaign_state")
local S  = cs.S
local M  = {}

-- ── EECH constants (exact mirror) ─────────────────────────────────────────────
local FOW_DECAY_RATE = 30.0           -- subtract per period (highlevl.h)
local FOW_MAX        = 4.0 * 3600    -- 14400; DEFAULT_FOG_OF_WAR_MAXIMUM_VALUE (highlevl.h)
local FOW_PERIOD     = FOW_DECAY_RATE -- 30 s; period used as update period (highlevl.c:280)
local FOW_OFFSET     = 8.0            -- initial offset seconds (highlevl.c:280)

-- EECH: FLOAT_TYPE_RECON_RADIUS is a single per-unit-type database float
-- (aircraft ac_dbase.c, vehicles/ships vh_dbase.c). The FOW code doubles it
-- (recon_radius = db_value * 2.0, eech sector.c:434) to get the effective scan
-- radius, then linearly falls off to 0 at that radius.
--
-- The port's old flat "airplane 20 km / heli 10 km / ground 3 km" values do NOT
-- exist anywhere in EECH (spec 06 §SECTOR-F8 — REFUTED). Replaced here with the
-- real per-unit-type recon_radius, keyed off DCS unit attributes (getDesc) which
-- map cleanly onto EECH's per-type database rows. Values below are the raw
-- database recon_radius (metres); the *2.0 doubling is applied in the grant loop.
local RECON = {
    -- Aircraft (eech entity/mobile/aircraft/ac_dbase.c)
    FIGHTER        = 10000, -- fighters/strike fighters (F-16C, MiG-29, F/A-18C, Su-33/34) eech ac_dbase.c:1226,1303,1534,1611,1689
    ATTACK_JET     = 6000,  -- attack jets (A-10A, Su-25, AV-8B, Yak-41)                    eech ac_dbase.c:1072,1149,1380,1457
    HELI_ATTACK    = 5000,  -- attack/scout/utility helis (AH-64D, Ka-52, Mi-28, Mi-24...)  eech ac_dbase.c:144,221,298,375,454,533
    HELI_TRANSPORT = 3000,  -- transport helis + fixed-wing transports (CH-47, Mi-6, C-130) eech ac_dbase.c:610,764,918,995,2007
    -- Vehicles / ships (eech entity/mobile/vehicle/vh_dbase.c)
    INFANTRY       = 500,   -- infantry / small units                                       eech vh_dbase.c:2104,2290,2538
    VEHICLE        = 1000,  -- tanks, trucks, most AFVs, artillery (most common tier)        eech vh_dbase.c:554,616,740
    APC_IFV        = 2000,  -- APC / IFV class                                               eech vh_dbase.c:120,182,368
    SCOUT          = 3000,  -- scout / recon vehicles                                        eech vh_dbase.c:244,306,1174
    AD_RADAR       = 4000,  -- short-range AD radar vehicles (Avenger/Tor tier)              eech vh_dbase.c:1050,1112
    RADAR_SAM      = 6000,  -- radar SAM / frigates (SA-19, O.H. Perry, Krivak II)           eech vh_dbase.c:988,1794,1856
    CAPITAL_SHIP   = 8000,  -- capital ships (Tarawa, Kiev)                                  eech vh_dbase.c:1670,1732
}
local RECON_DEFAULT = RECON.VEHICLE  -- unknown ground → tanks/trucks tier (19×1000, the modal value)

-- Resolve a unit's database recon_radius from its DCS attributes/category, mapping
-- onto the closest EECH per-type value. Attribute-driven (not type-name-hardcoded)
-- so it stays valid across the whole DCS unit set. Mirrors FLOAT_TYPE_RECON_RADIUS.
local function recon_radius_for(u, cat)
    local desc = u.getDesc and u:getDesc() or nil
    local a = (desc and desc.attributes) or {}

    if cat == Group.Category.AIRPLANE then
        if a["Transports"] then return RECON.HELI_TRANSPORT end     -- fixed-wing transports → 3000
        if a["Attack planes"] then return RECON.ATTACK_JET end      -- A-10/Su-25 class → 6000
        return RECON.FIGHTER                                        -- fighters/multirole/bombers → 10000
    elseif cat == Group.Category.HELICOPTER then
        if a["Transport helicopters"] then return RECON.HELI_TRANSPORT end
        return RECON.HELI_ATTACK
    elseif cat == Group.Category.SHIP then
        if a["Aircraft Carriers"] then return RECON.CAPITAL_SHIP end
        return RECON.RADAR_SAM                                      -- frigates/other combatants → 6000
    else -- GROUND
        if a["Infantry"] then return RECON.INFANTRY end
        if a["SAM TR"] or a["SAM LR"] then return RECON.RADAR_SAM end  -- long-range radar SAM → 6000
        if a["SAM SR"] then return RECON.AD_RADAR end                 -- short-range AD → 4000
        if a["IFV"] or a["APC"] then return RECON.APC_IFV end          -- IFV/APC → 2000
        return RECON_DEFAULT                                           -- tanks/trucks/artillery → 1000
    end
end

-- FOW thresholds (normalised 0.0–1.0), derived from highlevl.c fractional comparisons:
M.THRESHOLD_TASK   = 0.25  -- most task generators require fow >= 0.25 * maximum
M.THRESHOLD_TROOP  = 0.20  -- troop insertion requires fow >= 0.20 * maximum (stricter)

-- ── State: S.fow[base_name][side] = raw float 0–FOW_MAX ──────────────────────
-- Initialised to 0 (fog of war fully engaged — EECH starts missions with zero fog)

function M.init()
    S.fow = S.fow or {}
    for name in pairs(S.base_owner) do
        S.fow[name] = S.fow[name] or {}
        for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
            S.fow[name][side] = S.fow[name][side] or 0.0
        end
    end
end

-- ── get() ─────────────────────────────────────────────────────────────────────
-- Returns normalised 0.0–1.0 for the named base from the given attacker's perspective.
-- "side" here is the ATTACKER — returns FOW the attacker has on the base (enemy info).
-- mirrors get_sector_fog_of_war_value() semantics.
function M.get(base_name, side)
    if not S.fow or not S.fow[base_name] then return 0.0 end
    -- EECH: get_sector_fog_of_war_value() returns FOW_MAX when sector owned by queried side
    -- (sector.c line 521: "if sector_side == side return maximum_value")
    if S.base_owner[base_name] == side then return 1.0 end
    local raw = S.fow[base_name][side] or 0.0
    return raw / FOW_MAX
end

-- NOTE: M.grant (a manual FOW-grant export) was DELETED in Cluster H — it had zero callers (the
-- per-unit proximity scan in tick_fow does its grants inline via the local grant logic below).

-- ── Decay + recon scan ────────────────────────────────────────────────────────
-- Mirrors update_sector_fog_of_war():
--   raw = max(0, raw - FOG_OF_WAR_DECAY_RATE)  for every sector, every period.
-- Plus: scan all friendly units (via coalition.getGroups) for proximity to each base;
--   mirrors the per-entity set_sector_fog_of_war_value() calls that happen during
--   entity movement updates.

local function tick_fow()
    if not S.fow then return end
    local sides = { coalition.side.BLUE, coalition.side.RED }
    local n_grants = 0

    for name in pairs(S.base_owner) do
        local bpos = S.base_pos[name]
        S.fow[name] = S.fow[name] or {}
        for _, side in ipairs(sides) do
            -- Decay (mirrors update_sector_fog_of_war: max(0, val - DECAY_RATE))
            local raw = (S.fow[name][side] or 0.0) - FOW_DECAY_RATE
            if raw < 0.0 then raw = 0.0 end
            S.fow[name][side] = raw
        end

        -- Recon grant from friendly units near this base
        -- Mirrors the continuous per-entity set_sector_fog_of_war_value() calls.
        -- Per-unit FLOAT_TYPE_RECON_RADIUS now resolved per unit-type via getDesc
        -- attributes (closes the invented 20/10/3 km proxy; mirrors EECH's per-type
        -- database recon_radius lookup, doubled with linear falloff).
        if bpos then
            for _, side in ipairs(sides) do
                local grps = coalition.getGroups(side)
                if grps then
                    for _, grp in ipairs(grps) do
                        if grp and grp:isExist() then
                            local u = grp:getUnit(1)
                            if u and u:isExist() then
                                -- Resolve per-unit-type database recon_radius (mirrors FLOAT_TYPE_RECON_RADIUS)
                                local cat = grp:getCategory()
                                local recon_r = recon_radius_for(u, cat)

                                local upos = u:getPosition().p
                                local dx = upos.x - bpos.x
                                local dz = upos.z - bpos.z
                                local r  = math.sqrt(dx*dx + dz*dz)
                                -- set_sector_fog_of_war_value uses recon_radius * 2.0 for sector scan
                                local scan_r = recon_r * 2.0
                                if r <= scan_r then
                                    -- new_fog_value = max(current, (1 - r/scan_r) * maximum)
                                    local grant = (1.0 - r / scan_r) * FOW_MAX
                                    local current = S.fow[name][side] or 0.0
                                    if grant > current then
                                        S.fow[name][side] = math.min(FOW_MAX, grant)
                                        n_grants = n_grants + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    cs.dbg("fow", "decay+recon tick: %d (base,side) FOW grants raised this pass", n_grants)
end

-- ── Scheduler ─────────────────────────────────────────────────────────────────
-- mirrors add_high_level_ai_function(update_client_server_sector_fog_of_war,
--                                    FOG_OF_WAR_DECAY_RATE, 8.0)
-- period = 30 s, initial offset = 8 s
function M.schedule_decay(log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    cs.dbg("fow", "decay scheduler REGISTERED offset=%.0fs period=%.0fs", FOW_OFFSET, FOW_PERIOD)
    timer.scheduleFunction(function(_, t)
        -- INFRASTRUCTURE: FOW decay/grant keeps running post-victory (EECH fc_msgs.c:163). Cluster E.
        if _DMT_GEN ~= my_gen then return nil end
        local ok, err = pcall(tick_fow)
        if not ok then log_fn("fog_of_war tick error: " .. tostring(err)) end
        return t + FOW_PERIOD
    end, nil, timer.getTime() + FOW_OFFSET)
end

return M
