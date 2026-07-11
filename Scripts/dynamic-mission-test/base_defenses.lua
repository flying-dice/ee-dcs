-- base_defenses.lua
-- EECH source: aphavoc/source/gunships/campaign/populate/popread.c
--   read_population_sam_placements (popread.c:2148-2212): for EVERY population AAA/SAM placement point
--   the engine spawns an ENTITY_SUB_TYPE_GROUP_ANTI_AIRCRAFT group, formation
--   FORMATION_COMPONENT_LIGHT_SAM_AAA_GROUP (popread.c:2204), member count = max(0, component_count-1)
--   = 2 (popread.c:2208), side = the initial sector side. The placement POINTS come from the map
--   population templates (TEMPLATE_TYPE_AIRFIELD / TEMPLATE_TYPE_AAASAM, popread.c:100-101), which seed
--   SEVERAL such points around every airfield/town → EECH keysites, especially airbases, are ringed by
--   many AA groups.
--
-- This module ports that: each basing keysite (and each installation keysite) is ringed with N
-- LIGHT_SAM_AAA_GROUP groups. Because the per-keysite point DENSITY lives in the map population data
-- (not the C tree), N is a DOCUMENTED DESIGNER PROXY (config.defenses.groups_per: airbase=3, farp=1,
-- installation=1; author sets 0 to opt a class out). The per-group composition is FORMCOMP.DAT:535-545
-- LIGHT_SAM_AAA_GROUP's first TWO slots (popread.c:2208 count-1=2): BLUE {M48 Chaparral, Vulcan},
-- RED {2S6 Tunguska (SA-19), Strela-10M3 (SA-13)}. FORMCOMP HEAVY_SAM_AAA_GROUP:516-530 has no code
-- consumer in the shipped tree (popread.c:2204 uses LIGHT only) → deliberately NOT ported.
--
-- CLASSIFICATION (critical): these groups are SITE AA (EECH air_attack_strength==10 non-frontline AA,
-- highlevl.c:1981) → SEAD targets, NOT campaign ground groups. Their name prefix "AD-" does NOT match
-- the protected campaign-group tag set (^GndCol / ^Arty / -def$ / ^Patrol), so cas_bai_sead's
-- group_frontline_flag returns nil → get_enemy_aa_targets picks them up and get_enemy_ground_targets
-- excludes them (their lead unit has a SAM/AAA attribute). imap.update_air_defence scans AA by unit
-- attribute with no name filter, so they feed the AIR_DEFENCE layer automatically.
--
-- ECONOMY: FREE OOB placement — no force_reserve consume. EECH population AA is engine-placed at map
-- load and never draws on force_info hardware (popread.c:2148-2212); the old garrison here also spawned
-- free. They are NOT registered as keysite assets (register_static_death untouched) — they defend;
-- keysite health stays building-driven.
--
-- Spawned through coalition.addGroup → intercepted by spawn_queue, so the rings drain in over time.
-- reset.nuke clears them; they re-seed on the next injection (S.base_ad_groups is cleared at init).
--
-- POPULATION FIRING POINTS (added): popread.c:1389-1439 (read_population_sam_placements' building
-- scene-link branch) additionally spawns SINGLE-UNIT GROUP_STATIC_INFANTRY groups at each population
-- building link — LIGHT/MEDIUM/HEAVY_FIRING_POINT MG posts (FORMCOMP.DAT:693-717 :COUNT 1) and
-- INFANTRY_SAM_STANDING/KNEELING MANPAD soldiers (FORMCOMP.DAT:617-631 :COUNT 1), linked to the closest
-- keysite, sector-side owned. This module scatters an even MG/MANPAD mix inside each keysite's footprint
-- (config.defenses.firing_points count = designer proxy for the map population density). CLASSIFICATION:
-- GROUP_STATIC_INFANTRY frontline_flag = NONE (gp_dbase.c:887) and air_attack_strength = 6 (:896) → the
-- "FP-" name maps to group_frontline_flag 0: a target of NEITHER CAS(==1) nor BAI(>1), and excluded from
-- the generator SEAD's get_enemy_aa_targets (highlevl.c:1981 wants air_attack==10 site AA). MANPADs still
-- feed the AIR_DEFENCE imap by attribute (desired). Tracked in S.base_fp_groups; re-manned on capture.

local cs     = require("campaign_state")
local config = require("config")
local S  = cs.S
local M  = {}

-- Per-group composition = FORMCOMP.DAT:535-545 LIGHT_SAM_AAA_GROUP first 2 slots (popread.c:2208).
local DEF = config.C.defenses
local GROUP_UNITS = {}
local MG_TYPE, MANPAD_TYPE = {}, {}
for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
    GROUP_UNITS[side]  = DEF.group[side]
    MG_TYPE[side]      = DEF.mg[side]        -- population FIRING-POINT MG post (proxy soldier)
    MANPAD_TYPE[side]  = DEF.manpad[side]    -- population INFANTRY_SAM MANPAD soldier
end

-- Group count for a keysite class (config.defenses.groups_per; designer proxy for popread density).
local function groups_for_kind(kind)
    local gp = DEF.groups_per
    if kind == "airbase" then return gp.airbase or 0 end
    if kind == "farp"    then return gp.farp or 0 end
    return gp.installation or 0   -- every non-basing keysite class
end

-- Firing-point count for a keysite class (config.defenses.firing_points; designer proxy for the
-- popread population FIRING-POINT / MANPAD scene-link density, popread.c:1389-1439).
local function firing_points_for_kind(kind)
    local fp = DEF.firing_points
    if kind == "airbase" then return fp.airbase or 0 end
    if kind == "farp"    then return fp.farp or 0 end
    return fp.installation or 0
end

-- Spawn `n` LIGHT_SAM_AAA_GROUP air-defence groups evenly around `pos` at DEF.ring_radius. `key` names
-- the S.base_ad_groups bucket (for regarrison teardown); `tag` is the readable name stem. Returns the
-- number of groups placed. FREE (no reserve consume); groups are recorded for capture re-garrison only.
local function spawn_ring(key, tag, side, pos, n, log_fn)
    if not n or n <= 0 then return 0 end
    local proto   = GROUP_UNITS[side]
    local country = config.C.countries[side]
    if not proto or #proto == 0 or not country or not pos then
        cs.dbg("basedef", "spawn_ring ABORT %s: proto=%s country=%s pos=%s",
            tostring(tag), tostring(proto ~= nil), tostring(country ~= nil), tostring(pos ~= nil))
        return 0
    end
    S.base_ad_groups = S.base_ad_groups or {}
    local recorded = S.base_ad_groups[key] or {}
    local placed = 0
    for i = 1, n do
        local ang = (i - 1) * (2 * math.pi / n)
        -- ground units: x = north, y = east(z). Snap the RING slot off water (coastal keysite —
        -- Batumi) to the nearest land; fallback = the keysite/base centre `pos` (always land).
        local sp  = cs.snap_land(pos.x + math.cos(ang) * DEF.ring_radius,
                                 pos.z + math.sin(ang) * DEF.ring_radius, pos.x, pos.z)
        local gx  = sp.x
        local gz  = sp.z
        -- "AD-<tag>-<id>" — MUST NOT collide with the protected tag set (^GndCol/^Arty/-def$/^Patrol),
        -- so these classify as SITE AA (SEAD targets), never campaign ground groups.
        local gname = string.format("AD-%s-%d", tag, cs.next_id())
        local units = {}
        for j, utype in ipairs(proto) do
            units[j] = {
                name = gname .. "-" .. j, type = utype, skill = "Average",
                x = gx + (j - 1) * 30, y = gz, heading = 0,
            }
        end
        local ok = pcall(coalition.addGroup, country, Group.Category.GROUND, {
            name = gname, task = "Ground Nothing", units = units,
            route = { points = { {
                x = gx, y = gz, type = "Turning Point", action = "Off Road", speed = 0,
                ETA = 0, ETA_locked = true,
            } } },
        })
        if ok then
            placed = placed + 1
            recorded[#recorded + 1] = gname
        end
    end
    S.base_ad_groups[key] = recorded
    return placed
end

-- Scatter `n` single-unit population FIRING-POINT groups inside `key`'s footprint. EECH popread.c:
-- 1389-1439 spawns one GROUP_STATIC_INFANTRY group per population building scene-link:
-- LIGHT/MEDIUM/HEAVY_FIRING_POINT (MG posts, FORMCOMP.DAT:693-717 :COUNT 1) and INFANTRY_SAM_STANDING/
-- KNEELING (MANPAD soldier, FORMCOMP.DAT:617-631 :COUNT 1), owned by the sector side. The port scatters
-- an even MG/MANPAD mix (alternating) at random points within DEF.ring_radius of the keysite centre, at
-- land height (like the infantry patrols). FREE (no reserve consume — population placement). Records the
-- group names in S.base_fp_groups[key] for capture re-garrison teardown. Returns the count placed.
local function spawn_firing_points(key, tag, side, pos, n, log_fn)
    if not n or n <= 0 then return 0 end
    local country = config.C.countries[side]
    local mg, man = MG_TYPE[side], MANPAD_TYPE[side]
    if not country or not pos or not mg or not man then
        cs.dbg("basedef", "spawn_firing_points ABORT %s: country=%s pos=%s mg=%s manpad=%s",
            tostring(tag), tostring(country ~= nil), tostring(pos ~= nil), tostring(mg ~= nil), tostring(man ~= nil))
        return 0
    end
    S.base_fp_groups = S.base_fp_groups or {}
    local recorded = S.base_fp_groups[key] or {}
    local placed = 0
    for i = 1, n do
        -- Alternate MG / MANPAD → ~half each (popread mixes firing-point posts and MANPAD soldiers).
        local utype = (i % 2 == 1) and mg or man
        local ang   = math.random() * 2 * math.pi
        local r     = math.random() * DEF.ring_radius   -- scatter INSIDE the keysite footprint
        -- Snap the scattered firing-point off water (a 300 m ring at a coastal site can be wet);
        -- fallback = the keysite/base centre `pos` (always land).
        local sp    = cs.snap_land(pos.x + math.cos(ang) * r, pos.z + math.sin(ang) * r, pos.x, pos.z)
        local gx    = sp.x
        local gz    = sp.z
        local gy    = land.getHeight({ x = gx, y = gz })
        -- "FP-<tag>-<id>" — cas_bai_sead.group_frontline_flag maps ^FP- → flag 0 (NONE): a target of
        -- NEITHER CAS(==1) nor BAI(>1), and excluded from the generator SEAD's get_enemy_aa_targets.
        local gname = string.format("FP-%s-%d", tag, cs.next_id())
        local ok = pcall(coalition.addGroup, country, Group.Category.GROUND, {
            name = gname, task = "Ground Nothing",
            units = {{ name = gname .. "-1", type = utype, skill = "Average",
                       x = gx, y = gz, alt = gy, alt_type = "BARO", heading = 0 }},
            route = { points = { {
                x = gx, y = gz, type = "Turning Point", action = "Off Road", speed = 0,
                ETA = 0, ETA_locked = true,
            } } },
        })
        if ok then
            placed = placed + 1
            recorded[#recorded + 1] = gname
        end
    end
    S.base_fp_groups[key] = recorded
    return placed
end

-- Seed the air-defence rings at every keysite. Called from game_loop init AFTER keysite OOB
-- (S.base_owner / S.base_kind / S.base_pos) and installations init (S.keysites). Works in BOTH the
-- zone-authored and auto theatres — air-defence UNITS are campaign OOB (like ground columns/patrols),
-- engine-placed by popread, never author-placed (the register-don't-spawn directive governs keysite
-- ASSETS/statics, not defence units).
function M.init(log_fn)
    log_fn = log_fn or function() end
    S.base_ad_groups = {}   -- fresh registry each injection (reset.nuke already destroyed the groups)
    S.base_fp_groups = {}   -- fresh FIRING-POINT registry (population statics, popread.c:1389-1439)
    local zoned = require("zones").has_keysite_zones()
    local n_groups, n_sites, n_fp = 0, 0, 0

    -- (A) Basing keysites: airbases + FARPs (S.base_kind distinguishes; default airbase).
    for base_name, side in pairs(S.base_owner) do
        if side == coalition.side.BLUE or side == coalition.side.RED then
            local kind   = (S.base_kind and S.base_kind[base_name]) or "airbase"
            local pos    = S.base_pos[base_name]
            local placed = spawn_ring(base_name, base_name:sub(1, 10), side, pos, groups_for_kind(kind), log_fn)
            n_fp = n_fp + spawn_firing_points(base_name, base_name:sub(1, 10), side, pos,
                firing_points_for_kind(kind), log_fn)
            n_groups = n_groups + placed
            if placed > 0 then n_sites = n_sites + 1 end
        end
    end

    -- (B) Installation keysites (non-basing): one ring each, EXCEPT auto-template keysites, which
    -- already spawned their own -aaa/-sam defence elements from the empty-zone TEMPLATE (no double AD).
    -- Skips the "AB-<name>" airbase-asset records (kind=="airbase", already ringed by their airbase).
    for kname, rec in pairs(S.keysites or {}) do
        if rec.kind ~= "airbase" and rec.pos and not rec.templated then
            local ok_i, inst = pcall(require, "installations")
            local side = rec.side or (ok_i and inst and inst.side_of and inst.side_of(rec))
                       or (rec.home_base and S.base_owner[rec.home_base])
            if side == coalition.side.BLUE or side == coalition.side.RED then
                local placed = spawn_ring(kname, kname:sub(1, 12), side, rec.pos,
                    groups_for_kind("installation"), log_fn)
                n_fp = n_fp + spawn_firing_points(kname, kname:sub(1, 12), side, rec.pos,
                    firing_points_for_kind("installation"), log_fn)
                n_groups = n_groups + placed
                if placed > 0 then n_sites = n_sites + 1 end
            end
        end
    end

    log_fn(string.format(
        "base_defenses: air-defence rings seeded — %d LIGHT_SAM_AAA groups + %d firing-point/MANPAD groups across %d keysites%s",
        n_groups, n_fp, n_sites, zoned and " (zone-authored theatre)" or " (auto theatre)"))
    cs.dbg("basedef", "init: %d AD groups + %d firing-point groups across %d keysites (zoned=%s)",
        n_groups, n_fp, n_sites, tostring(zoned))
end

-- Re-garrison a keysite when it changes hands (called from keysite.do_capture). A base is only
-- capturable after its efficiency falls below the minimum — its own defences were ground down by the
-- strikes that neutralised it — but any surviving AD from the old owner would otherwise fight the
-- incoming ring, so we TEAR DOWN the recorded old-owner groups first, then seed the new owner's ring.
-- Mirrors the sector flipping ownership of its population AA (popread.c places per initial sector side;
-- the port re-places on capture so the new owner is defended). Idempotent: destroy() no-ops on the
-- already-dead survivors, and the registry bucket is rebuilt from scratch.
function M.regarrison(base_name, new_side, log_fn)
    log_fn = log_fn or function() end
    S.base_ad_groups = S.base_ad_groups or {}
    S.base_fp_groups = S.base_fp_groups or {}
    local torn, torn_fp = 0, 0
    for _, gname in ipairs(S.base_ad_groups[base_name] or {}) do
        local g = Group.getByName(gname)
        if g then pcall(function() g:destroy() end); torn = torn + 1 end
    end
    S.base_ad_groups[base_name] = nil
    -- Firing points flip owner too (popread.c places per sector side; on capture the new owner re-mans
    -- them). Tear down any surviving old-owner FP/MANPAD groups, then re-scatter the captor's.
    for _, gname in ipairs(S.base_fp_groups[base_name] or {}) do
        local g = Group.getByName(gname)
        if g then pcall(function() g:destroy() end); torn_fp = torn_fp + 1 end
    end
    S.base_fp_groups[base_name] = nil
    local kind   = (S.base_kind and S.base_kind[base_name]) or "airbase"
    local pos    = S.base_pos[base_name]
    local placed = spawn_ring(base_name, base_name:sub(1, 10), new_side, pos, groups_for_kind(kind), log_fn)
    local fp     = spawn_firing_points(base_name, base_name:sub(1, 10), new_side, pos,
        firing_points_for_kind(kind), log_fn)
    log_fn(string.format("base_defenses: re-garrisoned %s for %s (%d AD + %d firing-point groups, %d+%d old torn down)",
        base_name, cs.SIDE_NAME[new_side] or "?", placed, fp, torn, torn_fp))
    cs.dbg("basedef", "regarrison %s -> %s: %d AD + %d FP groups placed, %d+%d survivors torn down",
        base_name, cs.SIDE_NAME[new_side] or "?", placed, fp, torn, torn_fp)
end

return M
