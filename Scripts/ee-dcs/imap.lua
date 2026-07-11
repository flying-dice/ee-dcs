-- imap.lua
-- EECH source: aphavoc/source/ai/highlevl/imaps.c
--   initialise_imaps(), normalise_importance_imaps(), normalise_base_distance_imaps(),
--   normalise_air_defence_imaps(), normalise_surface_defence_imaps(),
--   normalise_inlfuence_map() (min-max normalise to 0–255 then / 255.0),
--   update_keysite_distance_to_friendly_base() — inverse-square falloff within air_coverage_radius,
--   update_imap_surface_to_air_defence_level()  — AIR_SCAN_RANGE * 10 exaggeration,
--   update_imap_surface_to_surface_defence_level() — SURFACE_SCAN_RANGE * 10 exaggeration.
--
-- DCS proxy: EECH stores values in a 2D sector grid.  DCS has no sector grid, so we
-- compute per-base proxy values using the same falloff formulas; imap.get() interpolates
-- for any world position via inverse-distance weighting from the known base positions.
--
-- Layers (string keys, mirrors imap_types enum):
--   M.BASE_DISTANCE  — proximity to friendly bases (inverse-square within air_coverage_radius)
--   M.AIR_DEFENCE    — enemy AA threat coverage (AIR_SCAN_RANGE × 10 exaggeration)
--   M.SURFACE_DEFENCE— enemy surface-to-surface threat (SURFACE_SCAN_RANGE × 10)
--   M.IMPORTANCE     — keysite strategic importance (health × ownership)
--
-- Period: each layer refreshes every 120 s, staggered 20 s apart (mirrors EECH's
--         separate update_imap_* calls registered at different offsets).

local cs = require("campaign_state")
local S  = cs.S
local M  = {}

-- ── Layer name constants (mirrors imap_types enum) ────────────────────────────
M.BASE_DISTANCE   = "BASE_DISTANCE"
M.AIR_DEFENCE     = "AIR_DEFENCE"
M.SURFACE_DEFENCE = "SURFACE_DEFENCE"
M.IMPORTANCE      = "IMPORTANCE"

-- ── EECH constants ─────────────────────────────────────────────────────────────
-- air_coverage_radius: keysite_database[sub_type].air_coverage_radius.
-- All Caucasus airbases use the same default (not per-keysite in our approximation).
local AIR_COVERAGE_RADIUS    = 150000  -- metres; proxy for keysite air_coverage_radius
local IMPORTANCE_RADIUS      = 100000  -- metres; proxy for keysite importance_radius
local AIR_SCAN_EXAGGERATION  = 10.0   -- EECH: radius = AIR_SCAN_RANGE * 10 / SECTOR_SIDE_LENGTH
local SURF_SCAN_EXAGGERATION = 10.0   -- EECH: radius = SURFACE_SCAN_RANGE * 10 / SECTOR_SIDE_LENGTH
local DEFAULT_AIR_SCAN_RANGE  = 25000 -- metres; proxy for FLOAT_TYPE_AIR_SCAN_RANGE on AA units
local DEFAULT_SURF_SCAN_RANGE = 15000 -- metres; proxy for FLOAT_TYPE_SURFACE_SCAN_RANGE
local AA_THREAT_VALUE         = 1.0   -- FLOAT_TYPE_POTENTIAL_SURFACE_TO_AIR_THREAT proxy
local SURF_THREAT_VALUE       = 1.0   -- FLOAT_TYPE_POTENTIAL_SURFACE_TO_SURFACE_THREAT proxy

local UPDATE_PERIOD  = 120  -- seconds per layer; four layers = one full cycle per 480 s
local LAYER_STAGGER  = 20   -- seconds between successive layer updates

-- ── Raw storage: imap_raw[layer][side][base_name] = float (unnormalised) ───────
-- ── Normalised: imap_nrm[layer][side][base_name] = 0.0–1.0 ────────────────────
-- Wave 1: the layer store now lives on S (S.imap.raw / S.imap.nrm) so the influence-map state is part
-- of the persistence surface (GOAL P2). These module-local names are REFERENCES into S.imap — the
-- get()/update API and every consumer are unchanged; S (and thus S.imap) is rebuilt fresh per inject,
-- and M.init() zeroes the sub-tables exactly as before. The `or` guard is belt-and-suspenders: the
-- S literal already defines S.imap, so this only ever reuses the existing tables.
S.imap = S.imap or { raw = {}, nrm = {} }
local imap_raw = S.imap.raw
local imap_nrm = S.imap.nrm

local LAYERS = { M.BASE_DISTANCE, M.AIR_DEFENCE, M.SURFACE_DEFENCE, M.IMPORTANCE }
local SIDES  = { coalition.side.BLUE, coalition.side.RED }

-- Table entry count (debug summaries only — never used in a hot per-cell path).
local function count_entries(t)
    local n = 0
    if t then for _ in pairs(t) do n = n + 1 end end
    return n
end

local function ensure_tables()
    for _, layer in ipairs(LAYERS) do
        imap_raw[layer] = imap_raw[layer] or {}
        imap_nrm[layer] = imap_nrm[layer] or {}
        for _, side in ipairs(SIDES) do
            imap_raw[layer][side] = imap_raw[layer][side] or {}
            imap_nrm[layer][side] = imap_nrm[layer][side] or {}
        end
    end
end

-- ── normalise_inlfuence_map equivalent ────────────────────────────────────────
-- Mirrors EECH: find min/max across all entries, map to 0–255, divide by 255.
-- Returns early (no-op) if max == min (all entries identical).
local function normalise_layer(layer, side)
    local raw = imap_raw[layer][side]
    local min_val, max_val = math.huge, -math.huge
    for _, v in pairs(raw) do
        if v < min_val then min_val = v end
        if v > max_val then max_val = v end
    end
    if max_val == min_val then return end  -- mirrors EECH early-return
    local range = max_val - min_val
    local nrm   = imap_nrm[layer][side]
    for name, v in pairs(raw) do
        -- (v - min) / range → 0..1; matches EECH's 255 * ((v - min)/(max - min)) / 255
        nrm[name] = (v - min_val) / range
    end
end

-- ── IMAP_BASE_DISTANCE ─────────────────────────────────────────────────────────
-- Mirrors update_keysite_distance_to_friendly_base():
--   for each friendly keysite: scale = 1 - (dist^2 / radius^2), clamped 0–1.
--   Accumulate max(existing, scale) per sector (we use per-base proxy).
-- Then normalise_base_distance_imaps() min-max normalises across all sectors.
local function update_base_distance(side)
    local layer = M.BASE_DISTANCE
    local raw   = imap_raw[layer][side]
    -- Zero all entries first (mirrors zero loop in update_imap_distance_to_friendly_base)
    for name in pairs(S.base_owner) do raw[name] = 0.0 end

    local r2 = AIR_COVERAGE_RADIUS * AIR_COVERAGE_RADIUS

    -- For each friendly keysite: spread inverse-square influence to all base-proxies
    for fname, fowner in pairs(S.base_owner) do
        if fowner == side then
            local fpos = S.base_pos[fname]
            if fpos then
                for tname in pairs(S.base_owner) do
                    local tpos = S.base_pos[tname]
                    if tpos then
                        local dx = fpos.x - tpos.x
                        local dz = fpos.z - tpos.z
                        local d2 = dx*dx + dz*dz
                        if d2 < r2 then
                            local scale = 1.0 - d2 / r2  -- inverse-square within radius
                            -- mirrors max() accumulation in EECH
                            if scale > (raw[tname] or 0) then
                                raw[tname] = scale
                            end
                        end
                    end
                end
            end
        end
    end
    normalise_layer(layer, side)
end

-- ── IMAP_AIR_DEFENCE ──────────────────────────────────────────────────────────
-- Mirrors update_imap_surface_to_air_defence_level():
--   value = FLOAT_TYPE_POTENTIAL_SURFACE_TO_AIR_THREAT (proxy: AA_THREAT_VALUE)
--   radius = AIR_SCAN_RANGE * 10.0 / SECTOR_SIDE_LENGTH (proxy: DEFAULT_AIR_SCAN_RANGE * 10)
--   scale = (1 - dist^2/r^2) * value, accumulated (+=) per sector.
local function update_air_defence(side)
    local layer   = M.AIR_DEFENCE
    local raw     = imap_raw[layer][side]
    for name in pairs(S.base_owner) do raw[name] = 0.0 end

    local enemy = cs.ENEMY[side]
    local radius = DEFAULT_AIR_SCAN_RANGE * AIR_SCAN_EXAGGERATION
    local r2     = radius * radius

    -- Scan all enemy groups for AA units
    local enemy_groups = coalition.getGroups(enemy)
    if not enemy_groups then return end

    for _, grp in ipairs(enemy_groups) do
        if grp and grp:isExist() then
            local desc = grp:getUnit(1) and grp:getUnit(1):getDesc()
            local is_aa = desc and (
                (desc.attributes and (desc.attributes["SAM"] or
                                      desc.attributes["AAA"] or
                                      desc.attributes["SR SAM"] or
                                      desc.attributes["IR Guided SAM"] or
                                      desc.attributes["LR SAM"] or
                                      desc.attributes["MR SAM"]))
            )
            if is_aa then
                local gunit = grp:getUnit(1)
                if gunit and gunit:isExist() then
                    local gpos = gunit:getPosition().p
                    -- accumulate threat contribution into each base proxy
                    for bname in pairs(S.base_owner) do
                        local bpos = S.base_pos[bname]
                        if bpos then
                            local dx = gpos.x - bpos.x
                            local dz = gpos.z - bpos.z
                            local d2 = dx*dx + dz*dz
                            if d2 < r2 then
                                local scale = (1.0 - d2 / r2) * AA_THREAT_VALUE
                                raw[bname] = (raw[bname] or 0) + scale
                            end
                        end
                    end
                end
            end
        end
    end
    normalise_layer(layer, side)
end

-- ── IMAP_SURFACE_DEFENCE ──────────────────────────────────────────────────────
-- Mirrors update_imap_surface_to_surface_defence_level():
--   value = FLOAT_TYPE_POTENTIAL_SURFACE_TO_SURFACE_THREAT (proxy: SURF_THREAT_VALUE)
--   radius = SURFACE_SCAN_RANGE * 10 / SECTOR_SIDE_LENGTH
--   Same accumulation pattern as air_defence but for ground-attack units.
local function update_surface_defence(side)
    local layer  = M.SURFACE_DEFENCE
    local raw    = imap_raw[layer][side]
    for name in pairs(S.base_owner) do raw[name] = 0.0 end

    local enemy  = cs.ENEMY[side]
    local radius = DEFAULT_SURF_SCAN_RANGE * SURF_SCAN_EXAGGERATION
    local r2     = radius * radius

    local enemy_groups = coalition.getGroups(enemy)
    if not enemy_groups then return end

    for _, grp in ipairs(enemy_groups) do
        if grp and grp:isExist() then
            local desc = grp:getUnit(1) and grp:getUnit(1):getDesc()
            local is_surf = desc and (
                (desc.attributes and (desc.attributes["Armor"] or
                                      desc.attributes["Artillery"] or
                                      desc.attributes["Infantry"] or
                                      desc.attributes["Ground vehicles"]))
            )
            if is_surf then
                local gunit = grp:getUnit(1)
                if gunit and gunit:isExist() then
                    local gpos = gunit:getPosition().p
                    for bname in pairs(S.base_owner) do
                        local bpos = S.base_pos[bname]
                        if bpos then
                            local dx = gpos.x - bpos.x
                            local dz = gpos.z - bpos.z
                            local d2 = dx*dx + dz*dz
                            if d2 < r2 then
                                local scale = (1.0 - d2 / r2) * SURF_THREAT_VALUE
                                raw[bname] = (raw[bname] or 0) + scale
                            end
                        end
                    end
                end
            end
        end
    end
    normalise_layer(layer, side)
end

-- ── IMAP_IMPORTANCE ───────────────────────────────────────────────────────────
-- Mirrors normalise_importance_imaps() which reads sector->importance_level[side].
-- In EECH importance_level is propagated from keysite importance_radius spread.
-- DCS proxy: importance = health × 0.5 + ownership_contribution × 0.5,
--            spread with inverse-linear falloff within IMPORTANCE_RADIUS.
local function update_importance(side)
    local layer = M.IMPORTANCE
    local raw   = imap_raw[layer][side]
    for name in pairs(S.base_owner) do raw[name] = 0.0 end

    local r2 = IMPORTANCE_RADIUS * IMPORTANCE_RADIUS

    for fname, fowner in pairs(S.base_owner) do
        if fowner == side then
            local fpos = S.base_pos[fname]
            if fpos then
                local health = S.base_health[fname] or 1.0
                local importance = health * 0.5 + 0.5  -- owned by us = always non-zero
                -- spread to neighbours
                for tname in pairs(S.base_owner) do
                    local tpos = S.base_pos[tname]
                    if tpos then
                        local dx = fpos.x - tpos.x
                        local dz = fpos.z - tpos.z
                        local d2 = dx*dx + dz*dz
                        if d2 < r2 then
                            -- additive accumulation (mirrors update_sector_importance_level += scale)
                            local scale = (1.0 - d2 / r2) * importance
                            raw[tname] = (raw[tname] or 0) + scale
                        end
                    end
                end
            end
        end
    end
    normalise_layer(layer, side)
end

-- ── imap.get() ────────────────────────────────────────────────────────────────
-- Returns 0.0–1.0 for the given layer/side at world position wp.
-- Interpolates using inverse-distance weighting from known base positions.
-- When wp is exactly a base position: returns that base's normalised value.
function M.get(side, layer, wp)
    if not wp then return 0.0 end
    local nrm = imap_nrm[layer] and imap_nrm[layer][side]
    if not nrm then return 0.0 end

    -- Inverse-distance weighted interpolation across all bases
    local num, den = 0.0, 0.0
    for name, val in pairs(nrm) do
        local bpos = S.base_pos[name]
        if bpos then
            local dx = wp.x - bpos.x
            local dz = wp.z - bpos.z
            local d2 = dx*dx + dz*dz
            if d2 < 1.0 then
                -- Exact hit: return this base's value immediately
                return val
            end
            local w = 1.0 / d2
            num = num + w * val
            den = den + w
        end
    end
    if den == 0.0 then return 0.0 end
    return num / den
end

-- ── init ──────────────────────────────────────────────────────────────────────
function M.init()
    ensure_tables()
    -- Zero all normalised tables
    for _, layer in ipairs(LAYERS) do
        for _, side in ipairs(SIDES) do
            imap_nrm[layer][side] = {}
            imap_raw[layer][side] = {}
        end
    end
end

-- ── Scheduler ─────────────────────────────────────────────────────────────────
-- Four staggered timers, one per layer (mirrors EECH registering each
-- update_imap_* function separately with a different offset).
-- All respect the generation guard.
function M.schedule_update(log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN

    local updaters = {
        { M.BASE_DISTANCE,   "base_distance",   update_base_distance   },
        { M.AIR_DEFENCE,     "air_defence",     update_air_defence     },
        { M.SURFACE_DEFENCE, "surface_defence", update_surface_defence },
        { M.IMPORTANCE,      "importance",      update_importance      },
    }

    for i, entry in ipairs(updaters) do
        local layer_name, label, fn = entry[1], entry[2], entry[3]
        local offset = (i - 1) * LAYER_STAGGER
        timer.scheduleFunction(function(_, t)
            -- INFRASTRUCTURE: imap layers keep refreshing after campaign-over — the world runs on
            -- (EECH fc_msgs.c:163 halts only the win-check, not the sim). Only the re-injection guard cancels.
            if _DMT_GEN ~= my_gen then return nil end
            local ok, err = pcall(function()
                for _, side in ipairs(SIDES) do
                    fn(side)
                end
            end)
            if not ok then log_fn("imap " .. label .. " error: " .. tostring(err)) end
            -- LIGHT refresh summary: one line per layer per pass, entry counts only (never per cell).
            cs.dbg("imap", "layer %s refreshed: BLUE=%d entries, RED=%d entries", label,
                count_entries(imap_nrm[layer_name][coalition.side.BLUE]),
                count_entries(imap_nrm[layer_name][coalition.side.RED]))
            return t + UPDATE_PERIOD
        -- EECH highlevl.c lines 272–278: layers fire at 20, 40, 60, 80 s (base=20, stagger=20)
        end, nil, timer.getTime() + 20 + offset)
    end
    log_fn("imap: scheduled 4 layer updaters (stagger=" .. LAYER_STAGGER .. "s, period=" .. UPDATE_PERIOD .. "s)")
    cs.dbg("imap", "scheduler REGISTERED: 4 layers, base_offset=20s stagger=%.0fs period=%.0fs", LAYER_STAGGER, UPDATE_PERIOD)
end

return M
