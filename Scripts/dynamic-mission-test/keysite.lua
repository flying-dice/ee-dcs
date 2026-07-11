-- keysite.lua
-- Inspired by:
--   aphavoc/source/entity/special/keysite/keysite.h     KEYSITE entity: side, strength, position
--   aphavoc/source/entity/special/keysite/ks_funcs.c    capture_keysite, destroy_keysite
--   aphavoc/source/entity/special/keysite/ks_updt.c     supply tracking, assign_timer (3 min)
--   aphavoc/source/entity/special/sector/sc_secfuncs.c  sector ownership, influence map updates
--   aphavoc/source/ai/highlevl/imaps.c                  IMAP_BASE_DISTANCE, IMAP_IMPORTANCE scoring
--
-- Manages airbase (keysite) ownership, structural health, damage, and capture.
-- Provides target-scoring used by attack_waves.lua.
-- Mirrors KEYSITE entity: sub_type=AIRBASE, side, keysite_strength, keysite_usable_state.

local cs   = require("campaign_state")
local imap = require("imap")
local S    = cs.S
local M    = {}

-- MIN_TASK_CREATION_RATIO — a candidate whose rating is < 75% of the top target's rating is not
-- worth tasking this cycle (highlevl.c:88). FOW recon threshold = 0.25 * FOW maximum (highlevl.c:1179).
local MIN_TASK_CREATION_RATIO = 0.75   -- highlevl.c:88
local FOW_RECON_THRESHOLD     = 0.25   -- highlevl.c:1179 (0.25 * FLOAT_TYPE_FOG_OF_WAR_MAXIMUM_VALUE)

-- ── Airdrome discovery ────────────────────────────────────────────────────────
-- mirrors keysite sub_type filter: ENTITY_SUB_TYPE_KEYSITE_AIRBASE

local function all_airdromes()
    local out, seen = {}, {}
    for _, side in ipairs({ coalition.side.NEUTRAL, coalition.side.BLUE, coalition.side.RED }) do
        for _, ab in ipairs(coalition.getAirbases(side)) do
            local n = ab:getName()
            -- ab:getDesc().category == Airbase.Category.AIRDROME (0) is the correct check;
            -- ab:getCategory() returns Object.Category.BASE (4) which is WRONG.
            -- Guard nil desc: runtime-spawned FARPs register as HELIPAD airbases and, once destroyed,
            -- can linger in getAirbases() with a nil getDesc(); filtering to AIRDROME here also keeps
            -- FARP (HELIPAD) keysites out of the fixed-wing airbase registry (they are their own layer).
            local d = ab:getDesc()
            if d and d.category == Airbase.Category.AIRDROME and not seen[n] then
                seen[n] = true
                out[#out + 1] = ab
            end
        end
    end
    return out
end

-- ── Initialisation ─────────────────────────────────────────────────────────────
-- mirrors initialise_order_of_battle (order.c): assigns all keysites to a force,
-- builds initial keysite registry with side, position, and full health.

function M.init_base_state(log_fn)
    log_fn = log_fn or function() end

    -- Prefer coalition-assigned bases from the mission editor
    local assigned = {}
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        for _, ab in ipairs(coalition.getAirbases(side)) do
            local d = ab:getDesc()   -- guard nil desc (lingering destroyed HELIPAD/FARP airbases)
            if d and d.category == Airbase.Category.AIRDROME then
                assigned[ab:getName()] = side
            end
        end
    end

    local all = all_airdromes()

    -- ── AUTHORED THEATRE via ME trigger zones (preferred) ─────────────────────────
    -- If the mission author placed zones, they define the theatre and ownership:
    --   • BLUE + RED boxes  → airfields inside each become that side; the theatre is their union;
    --                          anything outside both is excluded. The gap between them is the front.
    --   • THEATRE box only  → scope to it, then auto-split sides (below).
    -- Falls back to the automatic densest-cluster scoping when no zones are placed.
    local zones = require("zones")
    zones.load()

    -- ── FULLY-AUTHORED zone-based theatre (preferred) ─────────────────────────────
    -- If the author placed one zone per keysite (colour = side, first word of name = type, centre =
    -- location — see README "Authoring a mission"), the WHOLE order of battle is read from them and
    -- the auto-generation below is skipped entirely. Only airfields covered by an `airbase` zone are
    -- in play; `farp` zones become forward heli bases; other keysite zones are handled by
    -- installations.lua. Ownership is the zone colour, so there is NO x-median side split here.
    if zones.has_keysite_zones() then
        S.base_kind = S.base_kind or {}
        local ksz = zones.keysites()
        local n_ab, n_farp, n_ks, farp_seen = 0, 0, 0, {}

        for _, kz in ipairs(ksz) do
            if kz.type == "airbase" and kz.side then
                -- Bind the zone to the DCS AIRDROME nearest its centre; that airfield's real position
                -- is the keysite location. Airfields no airbase zone covers are excluded (never added).
                local best, bestd = nil, math.huge
                for _, ab in ipairs(all) do
                    local p = ab:getPosition().p
                    local d = cs.dist2d(p.x, p.z, kz.x, kz.z)
                    if d < bestd then bestd = d; best = ab end
                end
                if best then
                    local nm = best:getName()
                    local p  = best:getPosition().p
                    S.base_pos[nm]    = { x = p.x, z = p.z }
                    S.base_health[nm] = 1.0
                    S.base_owner[nm]  = kz.side
                    S.base_kind[nm]   = "airbase"
                    n_ab = n_ab + 1

                    -- REGISTER the DCS airbase warehouse inventory (aircraft type→count). This is
                    -- read/registered but DOES NOT drive sortie generation: per the user's explicit
                    -- 2026-07-07 decision the port uses the EECH economy (per-base reserve ledger +
                    -- production crates), NOT a warehouse-driven OOB. The registration is retained as
                    -- authored data for future use (a possible F10 inventory display / restore surface) —
                    -- documented-intentional, NOT accidentally-dead. Do NOT wire it into the ledger.
                    -- pcall-guarded (getWarehouse/getInventory can throw on some bases).
                    S.base_warehouse = S.base_warehouse or {}
                    local ok_w, inv = pcall(function() return best:getWarehouse():getInventory() end)
                    if ok_w and inv and inv.aircraft then
                        local summ = {}
                        for atype, cnt in pairs(inv.aircraft) do summ[atype] = cnt end
                        S.base_warehouse[nm] = summ
                    end

                    -- REGISTER placed statics AND destroyable resource scenery (the airfield's built-in
                    -- fuel-barrel dumps / GSM / warehouses — TOPLIVO-BAK/SKLADIK/etc.) inside the airbase
                    -- zone as this airbase's assets (same structure as installations.lua). Spawns nothing.
                    -- Count scales with airfield size: Batumi ~5, Kutaisi ~80 — the author's zone bounds it.
                    local ab_assets = zones.statics_in_zone(kz.label)
                    local ab_scenery = {}
                    for _, srow in ipairs(zones.scenery_in_zone(kz.label, zones.RESOURCE_SCENERY)) do
                        ab_scenery[#ab_scenery + 1] =
                            { id = srow.id, type = srow.type, handle = srow.handle, dead = false }
                    end
                    local ab_total = #ab_assets + #ab_scenery
                    if ab_total > 0 then
                        S.keysites = S.keysites or {}
                        S.keysites["AB-" .. nm] = {
                            kind = "airbase", side = kz.side, pos = { x = p.x, z = p.z },
                            home_base = nm, assets = ab_assets, dead = {}, scenery = ab_scenery,
                            total = ab_total, alive = ab_total, health = 1.0,
                            flags = { ground_strike_target = true, recon_target = true },
                            label = "Airfield assets " .. nm, producer = nil,
                        }
                    end

                    log_fn(string.format(
                        "  airbase keysite %s → %s (%s) — warehouse %s, %d placed statics + %d scenery",
                        nm, cs.SIDE_NAME[kz.side] or "?", kz.label,
                        (S.base_warehouse and S.base_warehouse[nm]) and "read" or "unavailable",
                        #ab_assets, #ab_scenery))
                end
            end
        end

        for _, kz in ipairs(ksz) do
            if kz.type == "farp" and kz.side then
                -- Forward heli base created AT the zone centre; base_kind "farp" (heli-only ledger).
                local base = "FARP-" .. tostring(kz.label or "farp")
                local uniq, k = base, 1
                while S.base_owner[uniq] or farp_seen[uniq] do
                    k = k + 1; uniq = base .. "-" .. k
                end
                farp_seen[uniq]    = true
                S.base_pos[uniq]   = { x = kz.x, z = kz.z }
                S.base_health[uniq]= 1.0
                S.base_owner[uniq] = kz.side
                S.base_kind[uniq]  = "farp"
                n_farp = n_farp + 1
                log_fn(string.format("  farp keysite %s → %s", uniq, cs.SIDE_NAME[kz.side] or "?"))
            elseif kz.type ~= "airbase" and kz.type ~= "farp" then
                n_ks = n_ks + 1   -- non-basing keysite (factory/refinery/radar/... → installations.lua)
            end
        end

        log_fn(string.format("theatre from zones: %d airbases, %d FARPs, %d keysites",
            n_ab, n_farp, n_ks))
        cs.dbg("keysite", "init_base_state (zone-authored theatre): %d airbases, %d FARPs, %d installations",
            n_ab, n_farp, n_ks)
        M.designate_objectives(log_fn)
        return
    end

    local zone_owner = {}   -- base name → side, when BLUE/RED zones assign ownership explicitly
    local zone_scoped = false

    if zones.exists("BLUE") and zones.exists("RED") then
        local scoped, total = {}, #all
        for _, ab in ipairs(all) do
            local p = ab:getPosition().p
            local side
            if zones.contains("BLUE", p.x, p.z) then side = coalition.side.BLUE
            elseif zones.contains("RED", p.x, p.z) then side = coalition.side.RED end
            if side then scoped[#scoped + 1] = ab; zone_owner[ab:getName()] = side end
        end
        if #scoped >= 2 then all = scoped end
        zone_scoped = true
        log_fn(string.format("theatre from ME zones (BLUE/RED): %d of %d airfields in play", #all, total))
    elseif zones.exists("THEATRE") then
        local scoped, total = {}, #all
        for _, ab in ipairs(all) do
            local p = ab:getPosition().p
            if zones.contains("THEATRE", p.x, p.z) then scoped[#scoped + 1] = ab end
        end
        if #scoped >= 4 then all = scoped end
        zone_scoped = true
        log_fn(string.format("theatre from ME zone (THEATRE): %d of %d airfields in play", #all, total))
    end

    -- THEATRE SCOPING (fallback, no zones): an EECH warzone is ~260 km across (128 sectors x 2048 m —
    -- parser.c:347 / en_world.c set_entity_world_map_size), far smaller than DCS Caucasus (~500+ km).
    -- Scope to the densest EECH-sized cluster so distances/gameplay match.
    if not zone_scoped then
        local THEATRE_RADIUS = 130000   -- m; ~260 km theatre ≈ EECH Georgia map extent
        local total = #all
        -- Centre the theatre on the DENSEST cluster (the airfield with the most neighbours within the
        -- radius) rather than the centroid — the Caucasus fields span ~370x660 km, so the centroid can
        -- land in an empty gap. This picks the busiest EECH-sized pocket of airfields.
        local best_center, best_count = nil, -1
        for _, c in ipairs(all) do
            local cp, cnt = c:getPosition().p, 0
            for _, ab in ipairs(all) do
                local p = ab:getPosition().p
                if cs.dist2d(p.x, p.z, cp.x, cp.z) <= THEATRE_RADIUS then cnt = cnt + 1 end
            end
            if cnt > best_count then best_count = cnt; best_center = cp end
        end
        if best_center then
            local scoped = {}
            for _, ab in ipairs(all) do
                local p = ab:getPosition().p
                if cs.dist2d(p.x, p.z, best_center.x, best_center.z) <= THEATRE_RADIUS then
                    scoped[#scoped + 1] = ab
                end
            end
            if #scoped >= 6 then all = scoped end   -- guard: keep a playable count
        end
        log_fn(string.format("theatre scoped to ~%.0f km (densest cluster): %d of %d airfields in play",
            THEATRE_RADIUS * 2 / 1000, #all, total))
    end

    -- COHERENT territory split (used only when ownership is NOT authored by BLUE/RED zones): project
    -- each base onto the x axis and cut at the median so each side owns a contiguous block with the
    -- frontline between them. On DCS Caucasus low-x = Georgia (BLUE), high-x = Russia (RED).
    table.sort(all, function(a, b) return a:getPosition().p.x < b:getPosition().p.x end)
    local half = math.floor(#all / 2)

    local counts = { [coalition.side.BLUE] = 0, [coalition.side.RED] = 0 }
    for i, ab in ipairs(all) do
        local n   = ab:getName()
        local pos = ab:getPosition().p
        S.base_health[n] = 1.0   -- mirrors keysite.keysite_strength = keysite_maximum_strength
        S.base_pos[n]    = { x = pos.x, z = pos.z }

        -- Zone-authored ownership wins; else editor coalition; else the contiguous median split.
        local side = zone_owner[n] or assigned[n] or ((i <= half) and coalition.side.BLUE or coalition.side.RED)
        S.base_owner[n] = side
        counts[side]    = (counts[side] or 0) + 1
        log_fn(string.format("  keysite %s → %s", n, cs.SIDE_NAME[side] or "?"))
    end
    log_fn(string.format("keysites initialised: BLUE=%d RED=%d total=%d",
        counts[coalition.side.BLUE], counts[coalition.side.RED], #all))
    cs.dbg("keysite", "init_base_state (auto theatre): BLUE=%d RED=%d total=%d",
        counts[coalition.side.BLUE], counts[coalition.side.RED], #all)

    M.designate_objectives(log_fn)
end

-- ── Campaign objective selection ───────────────────────────────────────────────
-- Mirrors create_force_campaign_objectives (eech ai/highlevl/setup.c:126-289): for each force,
-- choose NUMBER_OF_CAMPAIGN_OBJECTIVES_PER_SIDE (5, setup.c:79) ENEMY keysites, rated by
-- isolation = distance to the closest OTHER enemy keysite (setup.c:224-253) plus frand1()
-- ("obligatory random factor", setup.c:255-262); take the top 5.
-- PROXY: all port keysites are airbases (equal keysite_database importance 1.0), so importance
-- gives no ordering — the EECH isolation+random rating IS the selection rule and is reproduced
-- exactly. The result is the per-side objective set the win check tests (KEYSITE-F26/F31).
function M.designate_objectives(log_fn)
    log_fn = log_fn or function() end
    S.objectives = { [coalition.side.BLUE] = {}, [coalition.side.RED] = {} }

    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local enemy = cs.ENEMY[side]
        -- Candidate set: every enemy-owned keysite at OOB (eech: enemy keysites that are
        -- POTENTIAL_CAMPAIGN_OBJECTIVE and IN_USE — all port airbases qualify).
        local cands = {}
        for name, owner in pairs(S.base_owner) do
            if owner == enemy then
                local bp = S.base_pos[name]
                if bp then
                    -- isolation: distance to the closest OTHER enemy keysite (setup.c:224)
                    local iso = math.huge
                    for other, oowner in pairs(S.base_owner) do
                        if oowner == enemy and other ~= name then
                            local op = S.base_pos[other]
                            if op then
                                local d = cs.dist2d(bp.x, bp.z, op.x, op.z)
                                if d < iso then iso = d end
                            end
                        end
                    end
                    if iso == math.huge then iso = 0 end
                    cands[#cands + 1] = { name = name, iso = iso }
                end
            end
        end

        -- Normalise isolation by the maximum (setup.c:244-253), add frand1() (setup.c:255-262).
        local max_iso = 0
        for _, c in ipairs(cands) do if c.iso > max_iso then max_iso = c.iso end end
        for _, c in ipairs(cands) do
            local norm = (max_iso > 0) and (c.iso / max_iso) or 0
            c.rating = norm + math.random()   -- math.random() ∈ [0,1) proxies frand1()
        end
        table.sort(cands, function(a, b) return a.rating > b.rating end)

        local n = math.min(#cands, cs.OBJECTIVES_PER_SIDE)
        for i = 1, n do S.objectives[side][i] = cands[i].name end
        log_fn(string.format("objectives %s (must capture %d enemy keysites): %s",
            cs.SIDE_NAME[side] or "?", n, table.concat(S.objectives[side], ", ")))
        cs.dbg("keysite", "objectives designated for %s: %d of %d enemy candidates -> %s",
            cs.SIDE_NAME[side] or "?", n, #cands, table.concat(S.objectives[side], ","))
    end
end

-- ── Queries ────────────────────────────────────────────────────────────────────
-- NOTE: best_friendly_base, best_friendly_airbase and behind_base were DELETED in Cluster H — all
-- three had zero callers (pre-task-board / pre-ground-spawn-era leftovers: launch-base selection now
-- lives in the task board's per-base ledger + slot gate, and spawns start on the ground at the chosen
-- base with real TakeOff waypoints — no "behind the base" in-air offset).

-- ── Landing-slot / basing-capacity arbitration (Cluster 5) ─────────────────────
-- EECH throttles sortie tempo per keysite via LANDING entities holding slot counts. A keysite's
-- available landing sites = free_landing_sites - reserved_landing_sites (eech keysite.c:313-331,
-- :324 get_keysite_landing_sites_available; spec 07 TASK-F23). Order generation / assignment gate
-- on that availability (assign.c:879/:906); a sortie RESERVES a site at assignment
-- (RESERVE_LANDING_SITE, ld_msgs.c:950) and frees it on landing/loss (UN/LOCK_LANDING_SITE,
-- ld_msgs.c:1567). The port reproduces this as an in-flight-sortie counter per launch base.
--
-- CAPACITY: total_landing_sites is PER-KEYSITE scenario/route data (eech ai/faction/parser.c:2667,
-- FILE_TAG_COUNT) with NO compiled-in default, so the port tiers a proxy default by the keysite's
-- air_force_capacity enum (NONE/SMALL/LARGE, eech keysite.h:77-84; airbase = LARGE, ks_dbase.c /
-- spec 03:88). SMALL = 4 is a labeled PROXY anchored to the per-pass assignment budget
-- (assign_task_count = 3, eech assign.c:218 / spec 03:91) + 1 headroom so one lingering prior-pass
-- sortie cannot zero out the current pass's launch budget; airbase = LARGE = 8 doubles that so a
-- busy frontline airbase does not starve concurrent insertions.
--
-- GRANULARITY PROXY: EECH locks per-AIRFRAME landing sites (formation_position bitmask, landing.c);
-- the port tracks per-SORTIE (group) — matching its group-level ledger/spawn model and the per-group
-- land/dead release handlers. One occupied slot = one in-flight sortie launched from the base.
M.SLOT_CAPACITY = { NONE = 0, SMALL = 4, LARGE = 8 }  -- airbase can run more concurrent sorties;
                                                       -- 4 starved insertions at busy frontline bases

-- All port keysites are airbases (all_airdromes filters to AIRDROME) → air_force_capacity LARGE.
function M.base_slot_capacity(name)
    -- Size-aware: a forward FARP/FOB is a small landing site (fewer concurrent sorties) than a full
    -- airbase (eech keysite landing-site capacity is per keysite type). base_kind mirrors EECH's
    -- air_force_capacity SMALL vs LARGE — same split do_capture uses for the repair bump.
    local kind = name and S.base_kind and S.base_kind[name]
    return (kind == "farp" or kind == "fob") and M.SLOT_CAPACITY.SMALL or M.SLOT_CAPACITY.LARGE
end

-- Available launch/landing slots at a base = capacity - in-flight sorties (>= 0). Mirrors
-- get_keysite_landing_sites_available = free - reserved (eech keysite.c:324).
function M.slot_available(name)
    if not name then return 0 end
    local used = (S.base_inflight and S.base_inflight[name]) or 0
    return M.base_slot_capacity(name) - used
end

-- Reserve one slot at `base` for sortie `gname` (RESERVE/LOCK_LANDING_SITE, ld_msgs.c:950/:599).
-- Records the launch base so the slot can be released on RTB-land / death. Idempotent per group.
function M.reserve_slot(base, gname)
    if not base or not gname then return end
    S.base_inflight     = S.base_inflight or {}
    S.group_launch_base = S.group_launch_base or {}
    if S.group_launch_base[gname] then return end   -- already holds a slot for this sortie
    S.group_launch_base[gname] = base
    S.base_inflight[base] = (S.base_inflight[base] or 0) + 1
end

-- Release the slot held by sortie `gname` (UNLOCK_LANDING_SITE, ld_msgs.c:1567). Idempotent: a
-- second call (e.g. death then despawn-timer, or first-unit-death then RTB) is a no-op. Clamps ≥ 0.
function M.release_slot(gname)
    if not gname then return end
    local base = S.group_launch_base and S.group_launch_base[gname]
    if not base then return end
    S.group_launch_base[gname] = nil
    if S.base_inflight then
        S.base_inflight[base] = math.max(0, (S.base_inflight[base] or 0) - 1)
    end
end

-- ── Unified keysite accessor (Wave 1 — one enumeration surface over both namespaces) ─────────────────
-- The port keeps keysite state in TWO parallel namespaces: BASING keysites (airbases/FARPs in
-- S.base_owner / S.base_pos / S.base_health / S.base_kind) and non-basing INSTALLATIONS (S.keysites
-- records). get()/all() give consumers ONE uniform read-only view so they stop branching per-namespace,
-- and give persistence a single enumeration point. This is a lookup FACADE only — it does NOT migrate
-- the underlying storage (deliberately: a mid-campaign storage move is too invasive; GOAL P2).
--
-- get(name) → view, or nil if `name` is neither a base nor an installation. The resolution reproduces
-- reaction.lua's keysite_owner / keysite_pos / keysite_health EXACTLY (those helpers now delegate here):
--   view = { name, kind, side, owner (== side), pos, health, is_basing, rec }
-- owner : basing → S.base_owner[name]; installation → rec.side or S.base_owner[rec.home_base] (may be nil)
-- pos   : basing → S.base_pos[name];   installation → rec.pos
-- health: basing → S.base_health[name]; installation → rec.health (nil → 1.0; a caller resolves the
--         "unknown base → 1.0" case via the nil return, matching keysite_health's tail).
function M.get(name)
    if not name then return nil end
    local basing_owner = S.base_owner[name]
    if basing_owner ~= nil then
        return {
            name      = name,
            kind      = S.base_kind and S.base_kind[name] or nil,
            side      = basing_owner,
            owner     = basing_owner,
            pos       = S.base_pos[name],
            health    = S.base_health[name],
            is_basing = true,
            rec       = nil,
        }
    end
    local rec = S.keysites and S.keysites[name]
    if rec then
        local owner = rec.side or S.base_owner[rec.home_base]
        return {
            name      = name,
            kind      = rec.kind,
            side      = owner,
            owner     = owner,
            pos       = rec.pos,
            health    = (rec.health ~= nil) and rec.health or 1.0,
            is_basing = false,
            rec       = rec,
        }
    end
    return nil
end

-- all(side) → iterator over EVERY keysite (basing + installation) as get()-shaped views; pass a side to
-- filter to that owner. The single enumeration surface for persistence and cross-namespace scans.
-- Snapshots the current keysites into a list, then returns a closure: `for v in ks.all(side) do ... end`.
function M.all(side)
    local views = {}
    for name in pairs(S.base_owner) do
        local v = M.get(name)
        if v and (side == nil or v.owner == side) then views[#views + 1] = v end
    end
    for name in pairs(S.keysites or {}) do
        local v = M.get(name)
        if v and (side == nil or v.owner == side) then views[#views + 1] = v end
    end
    local i = 0
    return function()
        i = i + 1
        return views[i]
    end
end

-- ── Target scoring ─────────────────────────────────────────────────────────────
-- EECH create_keysite_strike_tasks (highlevl.c:1109-1127) and create_oca_strike_tasks
-- (highlevl.c:1370-1381) rate every ground_strike / oca keysite with ONE weighted sum over the
-- influence-map layers. Both share this core; only the per-term weights + max differ:
--   ground strike : 1*(1-AIR_DEFENCE) + 4*BASE_DISTANCE + 2*(1-efficiency) + 2*side_ratio  max 9.0
--   oca strike    : 1*(1-AIR_DEFENCE) + 4*BASE_DISTANCE +      (no eff)    + 2*side_ratio  max 7.0
-- The IMAP_IMPORTANCE term is COMMENTED OUT in the C (highlevl.c:1113) — not ported. There is NO
-- target damage/health term (the port's old 2*damage / 4*proximity "obj_boost" were invented, REMOVED).
M.RATE_GROUND_STRIKE = { air_def = 1.0, base_dist = 4.0, eff = 2.0, side_ratio = 2.0, max = 9.0 } -- highlevl.c:1116-1127
M.RATE_OCA_STRIKE    = { air_def = 1.0, base_dist = 4.0, eff = 0.0, side_ratio = 2.0, max = 7.0 } -- highlevl.c:1373-1381

-- get_local_sector_side_ratio(x,z,side) proxy (highlevl.c:1125): fraction of nearby keysites owned
-- by `side`. Uses the SAME 200 km radius the CAS/BAI/OCA-sweep generator uses for the same EECH call
-- (cas_bai_sead.lua SECTOR_RATIO_RADIUS) so every rating formula reads one sector model.
local SECTOR_RATIO_RADIUS = 200000   -- m; get_local_sector_side_ratio proxy radius
local function sector_ratio(pos, side)
    if not pos then return 0.0 end
    local r2 = SECTOR_RATIO_RADIUS * SECTOR_RATIO_RADIUS
    local friendly, total = 0, 0
    for name, owner in pairs(S.base_owner) do
        local bp = S.base_pos[name]
        if bp then
            local dx, dz = pos.x - bp.x, pos.z - bp.z
            if dx * dx + dz * dz <= r2 then
                total = total + 1
                if owner == side then friendly = friendly + 1 end
            end
        end
    end
    if total == 0 then return 0.0 end
    return friendly / total
end

-- Nearest owned/known base to a world position — the position's "sector" (there is no sector grid),
-- used to read the FOW value that gates the recon fork (mirrors get_local_sector_entity(pos)).
local function nearest_base_to(pos)
    local best, best_d2 = nil, math.huge
    for name, bp in pairs(S.base_pos) do
        local dx, dz = pos.x - bp.x, pos.z - bp.z
        local d2 = dx * dx + dz * dz
        if d2 < best_d2 then best_d2 = d2; best = name end
    end
    return best
end

-- Weighted imap rating for an arbitrary keysite position + efficiency (shared by airbases and
-- non-airbase installations so create_keysite_strike_tasks scores the whole ground_strike set with
-- ONE formula). Reads the EXISTING imap layers (imap.get, normalised 0..1, refreshed every 120 s):
--   IMAP_AIR_DEFENCE : highlevl.c:1116 reads it for the ENEMY side; the port builds this layer for
--       `attacker` by scanning the ENEMY's AA (imap.lua:update_air_defence), so
--       imap.get(attacker, AIR_DEFENCE, ·) IS the enemy-AA field. LOW enemy AA is preferred → (1-v).
--   IMAP_BASE_DISTANCE : highlevl.c:1119 reads it for this_side (attacker) — closeness to the
--       attacker's own bases (reachability). imap.get(attacker, BASE_DISTANCE, ·).
--   efficiency + side_ratio read directly, exactly as EECH (FLOAT_TYPE_EFFICIENCY / sector_side_ratio).
function M.rate_pos(attacker, tpos, eff, weights)
    if not tpos then return 0 end
    weights = weights or M.RATE_GROUND_STRIKE
    eff = eff or 1.0
    local air_def   = imap.get(attacker, imap.AIR_DEFENCE,   tpos)   -- highlevl.c:1116
    local base_dist = imap.get(attacker, imap.BASE_DISTANCE, tpos)   -- highlevl.c:1119
    local sr        = sector_ratio(tpos, attacker)                   -- highlevl.c:1125
    return weights.air_def    * (1.0 - air_def)
         + weights.base_dist  * base_dist
         + weights.eff        * (1.0 - eff)
         + weights.side_ratio * sr
end

-- Rating for a named airbase keysite. weights defaults to ground-strike; pass RATE_OCA_STRIKE for
-- the OCA generator (which scans oca_target keysites = airbases only, ks_dbase.c:124/218).
function M.rate_target(attacker, tname, weights)
    local tpos = S.base_pos[tname]
    if not tpos then return 0 end
    if (S.base_health[tname] or 1) <= cs.HEALTH_DESTROYED then return 0 end   -- fully destroyed, skip
    if S.base_owner[tname] == attacker then return 0 end                      -- own base, skip
    return M.rate_pos(attacker, tpos, M.efficiency(tname), weights)
end

-- Returns (name, rating) of the best enemy airbase target; nil if none. Used by the OCA generator +
-- reaction single-shots. Mirrors the top-of-list pick of create_oca_strike_tasks.
function M.pick_target(attacker, log_fn, weights)
    log_fn = log_fn or function() end
    local best_name, best_r = nil, -1
    local enemy = cs.ENEMY[attacker]

    for name, owner in pairs(S.base_owner) do
        -- Attack enemy-owned OR partly-damaged neutral bases
        if owner == enemy or (owner ~= attacker and (S.base_health[name] or 1) < 1) then
            local r = M.rate_target(attacker, name, weights)
            if r > best_r then best_r = r; best_name = name end
        end
    end

    if best_name then
        log_fn(string.format("target: %s → %s (rating=%.2f health=%.0f%%)",
            cs.SIDE_NAME[attacker], best_name, best_r,
            (S.base_health[best_name] or 1) * 100))
        cs.dbg("keysite", "%s pick_target: %s rating=%.2f health=%.0f%%",
            cs.SIDE_NAME[attacker], best_name, best_r, (S.base_health[best_name] or 1) * 100)
    else
        cs.dbg("keysite", "%s pick_target: no candidate found", cs.SIDE_NAME[attacker])
    end
    return best_name, best_r
end

-- Merged, rating-sorted candidate list across the WHOLE ground_strike_target keysite set (airbases
-- AND non-airbase installations) scored by the ONE create_keysite_strike_tasks formula
-- (highlevl.c:1093-1127 iterates every keysite whose keysite_database row is ground_strike_target).
-- Each entry: { name, pos, eff, rating, recon_target, is_inst }. Replaces the old airbase/installation
-- interleave with a single ranked scan (invented STRIKE_VALUE table + finish-off bonus removed).
function M.strike_candidates(attacker, weights)
    weights = weights or M.RATE_GROUND_STRIKE
    local enemy = cs.ENEMY[attacker]
    local out = {}
    -- Airbases (ks_dbase.c AIRBASE row: ground_strike_target=TRUE, recon_target=TRUE, min_eff 0.3 —
    -- ks_dbase.c:103,125-126).
    for name, owner in pairs(S.base_owner) do
        if owner == enemy or (owner ~= attacker and (S.base_health[name] or 1) < 1) then
            local pos = S.base_pos[name]
            if pos and (S.base_health[name] or 1) > cs.HEALTH_DESTROYED then
                local eff = M.efficiency(name)
                out[#out + 1] = { name = name, pos = pos, eff = eff,
                    rating = M.rate_pos(attacker, pos, eff, weights),
                    recon_target = true, is_inst = false }
            end
        end
    end
    -- Non-airbase installations (ground_strike_target keysites — installations.strike_targets).
    local ok_i, inst = pcall(require, "installations")
    if ok_i and inst and inst.strike_targets then
        for _, t in ipairs(inst.strike_targets(attacker)) do
            out[#out + 1] = { name = t.name, pos = t.pos, eff = t.health,
                rating = M.rate_pos(attacker, t.pos, t.health, weights),
                recon_target = (t.recon_target == true), is_inst = true }
        end
    end
    table.sort(out, function(a, b) return a.rating > b.rating end)
    return out
end

-- create_keysite_strike_tasks funnel (highlevl.c:1155-1270). Scores the whole ground_strike set
-- (strike_candidates), takes the top CREATE_KEYSITE_STRIKE_TASK_COUNT (n), and for each applies:
--   • MIN_TASK_CREATION_RATIO gate — rating < 0.75*top → skip (highlevl.c:1167-1169).
--   • recon-first fork (highlevl.c:1179): recon_target OR FOW(sector) < 0.25*max → dispatch RECON
--       (the STRIKE is created later by the recon-complete reaction, reaction.c:482 / the port's
--       react_recon_complete_keysite), with the recon-branch dedup on recon/bda/ground_strike/
--       troop_insertion (highlevl.c:1185-1191).
--   • else (recon not required) → direct strike iff efficiency >= minimum_efficiency (highlevl.c:1224;
--       below-min keysites are left for troop insertion), with the strike-branch dedup on
--       ground_strike/troop_insertion (highlevl.c:1227-1230).
-- AIRBASES are recon_target=TRUE (ks_dbase.c:125) so they ALWAYS take the recon fork — the generator
-- reconnoitres and the ground strike arrives via the reaction chain, exactly as EECH.
-- INSTALLATIONS now take the SAME fork keyed on their TRUE recon_target row (Cluster I made
-- react_recon_complete_keysite + reaction.keysite_flags installation-aware, so the all-installations
-- direct-strike carve-out is removed): factory (recon_target=FALSE, ks_dbase.c:219) and port (:360)
-- are direct-struck when visible; refinery/power/radar/military_base (recon_target=TRUE, :454/:407/
-- :501/:313) recon-fork and the ground strike arrives via the reaction chain — exact EECH behaviour.
-- (Installations have no port capture mechanic, so an installation that reaches eff < minimum is left
-- by the strike branch — highlevl.c:1224 — and finished by the deterministic 0.5-per-sortie
-- installations.damage / artillery, since EECH's below-min→troop-insertion path needs a capturable
-- keysite the port only models for airbases/FARPs.)
-- Returns a list of decisions { action="strike"|"recon", name, pos, is_inst } for attack_waves.
function M.pick_targets(attacker, n, log_fn)
    log_fn = log_fn or function() end
    n = n or 3
    local cands = M.strike_candidates(attacker, M.RATE_GROUND_STRIKE)
    local decisions = {}
    if #cands == 0 or cands[1].rating <= 0 then
        cs.dbg("keysite", "%s strike funnel: 0 candidates", cs.SIDE_NAME[attacker])
        return decisions
    end

    local ok_f, fow = pcall(require, "fog_of_war")
    local top_r = cands[1].rating
    local count = math.min(#cands, n)
    local n_strike, n_recon, n_ratio, n_dedup, n_eff = 0, 0, 0, 0, 0

    for i = 1, count do
        local e = cands[i]
        if e.rating / top_r < MIN_TASK_CREATION_RATIO then
            n_ratio = n_ratio + 1                               -- highlevl.c:1167-1169
        else
            -- Full EECH fork for BOTH airbases and installations, driven by each keysite's TRUE
            -- recon_target row (no all-installations carve-out). FOW of the target's sector: the
            -- keysite's own base key for airbases; the nearest base for installations.
            local fow_val = 1.0
            if ok_f and fow then
                local fow_base = (S.base_pos[e.name] and e.name) or nearest_base_to(e.pos)
                fow_val = (fow_base and fow.get(fow_base, attacker)) or 0.0
            end
            if e.recon_target or fow_val < FOW_RECON_THRESHOLD then   -- highlevl.c:1179
                -- Dedup set highlevl.c:1185-1191 = RECON/BDA/GROUND_STRIKE/ANTI_SHIP/TROOP_INSERTION/
                -- TROOP_MOVEMENT_INSERT_CAPTURE. ANTI_SHIP is n/a (no ship keysites); the port's single
                -- "troop_insertion" type covers BOTH EECH troop task types (one insertion pipeline).
                if cs.has_task_against("recon", e.name, attacker)
                   or cs.has_task_against("bda", e.name, attacker)
                   or cs.has_task_against("ground_strike", e.name, attacker)
                   or cs.has_task_against("troop_insertion", e.name, attacker) then
                    n_dedup = n_dedup + 1                        -- highlevl.c:1185-1191
                else
                    decisions[#decisions + 1] = { action = "recon", name = e.name, pos = e.pos, is_inst = e.is_inst }
                    n_recon = n_recon + 1
                end
            elseif e.eff < cs.MINIMUM_EFFICIENCY then
                n_eff = n_eff + 1                                -- highlevl.c:1224 (below-min → TI, not strike)
            elseif cs.has_task_against("ground_strike", e.name, attacker)
                or cs.has_task_against("troop_insertion", e.name, attacker) then
                n_dedup = n_dedup + 1                            -- highlevl.c:1227-1230
            else
                decisions[#decisions + 1] = { action = "strike", name = e.name, pos = e.pos, is_inst = e.is_inst }
                n_strike = n_strike + 1
            end
        end
    end

    cs.dbg("keysite",
        "%s strike funnel: %d cands -> top %d checked: %d strike, %d recon(fogged/recon_target), %d below-ratio, %d deduped, %d eff-gated",
        cs.SIDE_NAME[attacker], #cands, count, n_strike, n_recon, n_ratio, n_dedup, n_eff)
    return decisions
end

-- ── Damage ─────────────────────────────────────────────────────────────────────
-- NOTE: the generic kill-proximity bleed (apply_kill_damage: any kill within KILL_RADIUS of a base
-- reduced its structural health) was REMOVED in Cluster G. EECH keysite_strength changes ONLY when
-- the keysite's own buildings die (keysite.c:854), not from nearby air-to-air kills — the old channel
-- double-dipped with strike_damage. Airbase attrition is now strike_damage (below) + registered-asset
-- death (installations.register_static_death); the under-attack CAP notification lives in both paths.

-- ── Direct keysite-strike attrition ─────────────────────────────────────────────
-- A strike package that reaches an airbase keysite reduces its building strength directly (mirrors
-- EECH create_keysite_strike_tasks: keysites are degraded by strikes ON them, not only by incidental
-- unit kills — an empty airfield takes no unit-kills, so without this the base can never fall). Also
-- stamps the strike time so keysite_repair suppresses recovery while the keysite is under attack
-- (EECH: a suppressed keysite does not run its repair loop).
function M.strike_damage(bname, dmg, log_fn)
    log_fn = log_fn or function() end
    if not S.base_health[bname] then return end
    local old_h = S.base_health[bname]
    local new_h = math.max(0, old_h - dmg)
    S.base_health[bname]     = new_h
    S.base_efficiency        = S.base_efficiency or {}
    S.base_efficiency[bname] = new_h
    S.base_last_strike       = S.base_last_strike or {}
    S.base_last_strike[bname] = timer.getTime()
    -- Strict < min: UNUSABLE/capturable iff eff < minimum (keysite.c:827-830); matches the TI
    -- generators' strict test so the "capturable" banner never fires for a base resting at exactly min.
    local newly_neutralised = old_h >= cs.HEALTH_NEUTRALISED and new_h < cs.HEALTH_NEUTRALISED
    log_fn(string.format("keysite strike: %s (%s) %.0f%%→%.0f%%%s",
        bname, cs.SIDE_NAME[S.base_owner[bname]] or "?", old_h * 100, new_h * 100,
        newly_neutralised
            and string.format(" — NEUTRALISED, capturable (<%.0f%%)", cs.MINIMUM_EFFICIENCY * 100) or ""))
    cs.dbg("keysite", "strike_damage: %s %.0f%%->%.0f%% (dmg=%.2f)%s", bname, old_h * 100, new_h * 100,
        dmg, newly_neutralised and " -> NEUTRALISED" or "")
    -- Under-attack defensive CAP (keysite.c:854-939 notify_keysite_structure_under_attack): a struck
    -- keysite scrambles CAP even when NO attacker task was registered (covers a HUMAN player's strike —
    -- MP-critical). Lazy pcall require avoids a load cycle (reaction requires keysite at the top).
    local ok_r, react = pcall(require, "reaction")
    if ok_r and react and react.on_keysite_under_attack then
        pcall(react.on_keysite_under_attack, bname, log_fn)
    end
    return new_h
end

-- ── Efficiency ─────────────────────────────────────────────────────────────────
-- FLOAT_TYPE_EFFICIENCY (eech ks_float.c:260-275) = keysite_strength / keysite_maximum_strength.
-- In the port that is base_efficiency (kept == base_health by keysite_repair; see KEYSITE-F3).
function M.efficiency(bname)
    return (S.base_efficiency and S.base_efficiency[bname])
        or (S.base_health and S.base_health[bname]) or 1.0
end

-- ── Capture ────────────────────────────────────────────────────────────────────
-- mirrors capture_keysite(en, new_side) (eech keysite.c:1289-1518): probabilistic roll on the
-- troop-insertion-capture waypoint, then flip side + instant repair + regen queue reseed +
-- campaign-objective re-check. Capture is OFFERED only when efficiency < minimum (0.3).

local CAPTURE_RANGE = 5000   -- m; ground column "at" the keysite (port proxy for insert waypoint)

-- On-capture repair — eech keysite.c:1451-1462 repairs UP TO 5 buildings (for loop<5 call
-- repair_client_server_entity_keysite), then USABLE if that reached full strength else REPAIRING (the
-- slow 1-building/10-min heal continues). KEY nuance: "5 buildings" is SIZE-DEPENDENT — a SMALL keysite
-- (FARP/FOB, air_force_capacity SMALL — only a handful of buildings) is effectively FULLY repaired by 5
-- (→ full strength → USABLE, and HELD), while a LARGE airbase (air_force_capacity LARGE — many
-- buildings) gets only a partial bump (→ REPAIRING, stays contestable). The port proxies this via
-- base_kind. Without the size split, small FARPs came back at a flat ~0.65 and instantly flip-flopped,
-- so the front oscillated on one base and never advanced → no decisive win.
local CAPTURE_REPAIR_LARGE = 0.4   -- airbase: ~5 of ~12 buildings restored → partial, contestable
local CAPTURE_REPAIR_SMALL = 1.0   -- FARP/FOB: 5 buildings ≈ all → full (held); lets the front advance

-- Regen queue reseed on capture — eech keysite.c:1483-1517 (AIRBASE): the new owner gains
-- +6 helicopter and +4 fixed-wing regen slots; the destroy path (eech keysite.c:1266-1282,
-- KEYSITE-F14) removes the same from the old owner. Port maps "regen slots" onto the per-side
-- reserve pool (+ queued groups at the base) — see supply.lua / regen.lua.
local CAPTURE_REGEN_HELI = 6   -- eech keysite.c:1490 (helicopter slots)
local CAPTURE_REGEN_FW   = 4   -- eech keysite.c:1494 (fixed-wing slots)

-- Defence score + probabilistic capture test — eech mb_msgs.c:2287-2308:
--   d = (efficiency - minimum) / (1 - minimum)          [d is the DEFENCE score]
--   d = d * member_count / (member_count + losses)
--   capture iff d < frand1()
-- efficiency ≤ minimum ⇒ d ≤ 0 ⇒ guaranteed capture; full efficiency + intact troops ⇒ d≈1 ⇒
-- capture chance ≈ 0. Uses the keysite's CURRENT efficiency, so a base that repairs above the
-- minimum while troops are inbound can resist the capture.
function M.capture_roll(bname, member_count, losses)
    local eff = M.efficiency(bname)
    local mn  = cs.MINIMUM_EFFICIENCY
    local d   = (eff - mn) / (1.0 - mn)
    member_count = member_count or 1
    losses       = losses or 0
    d = d * (member_count / (member_count + losses))
    local roll = math.random()   -- math.random() ∈ [0,1) proxies EECH frand1()
    local won  = d < roll
    cs.dbg("capture", "capture_roll %s: eff=%.2f defence_score=%.2f roll=%.2f -> %s",
        bname, eff, d, roll, won and "CAPTURED" or "REPELLED")
    return won
end

-- Regen reseed side-effect (eech keysite.c:1483-1517 + 1266-1282).
local function reseed_regen_on_capture(old_side, new_side, bname, log_fn)
    local ok_s, supply = pcall(require, "supply")
    if ok_s and supply then
        -- new owner gains the base's air slots
        supply.recycle_side(new_side, "heli",    CAPTURE_REGEN_HELI)
        supply.recycle_side(new_side, "striker", CAPTURE_REGEN_FW)
        -- old owner loses them (clamped at 0 — reserves never go negative on this path).
        -- Drain ONE at a time: consume_side needs a single base to hold the whole count, so a
        -- fragmented reserve (e.g. 3+3 heli across two bases, nreq 6) would otherwise remove
        -- nothing. One-at-a-time drains across bases (each hit takes from the richest remaining).
        local function shrink(side, role, nreq)
            local have = supply.reserve_side(side, role)
            for _ = 1, math.min(have, nreq) do
                if not supply.consume_side(side, role, 1) then break end
            end
        end
        shrink(old_side, "heli",    CAPTURE_REGEN_HELI)
        shrink(old_side, "striker", CAPTURE_REGEN_FW)
    end
    -- queue the fresh default groups at the captured base so they actually regenerate.
    -- F3: the FIXED-WING portion only at an AIRBASE — EECH reseeds a captured keysite with the group
    -- types the keysite supports (keysite.c:1483 reseeds the AIRBASE default set; a FARP fields
    -- helicopters only, ks_dbase.c FARP air_force_capacity SMALL/heli). The port's base_kind convention
    -- (farps.lua: "farp"/"fob" = heli-only ledger, no striker stock) means FW regen entries at a
    -- captured FARP could never be satisfied by spawn_regen — they'd sit as dead ring-buffer slots.
    local ok_r, regen = pcall(require, "regen")
    if ok_r and regen and regen.queue_reseed then
        local kind = (S.base_kind and S.base_kind[bname]) or "airbase"
        local fw_n = (kind == "airbase") and CAPTURE_REGEN_FW or 0
        regen.queue_reseed(new_side, bname, CAPTURE_REGEN_HELI, fw_n, log_fn)
    end
end

-- Apply the ownership flip and all capture side-effects (assumes the roll already succeeded).
function M.do_capture(bname, new_side, log_fn)
    log_fn = log_fn or function() end
    local old_side = S.base_owner[bname]
    if old_side == new_side then
        cs.dbg("capture", "do_capture NO-OP: %s already owned by %s", bname, cs.SIDE_NAME[new_side])
        return false
    end

    S.base_owner[bname] = new_side
    -- Repair UP TO 5 buildings on capture (eech keysite.c loop < 5), SIZE-aware: a small FARP/FOB is
    -- fully covered by 5 buildings (→ held); a large airbase gets a partial bump (→ contestable).
    local bump = ((S.base_kind and S.base_kind[bname]) == "airbase") and CAPTURE_REPAIR_LARGE or CAPTURE_REPAIR_SMALL
    S.base_health[bname] = math.min(1.0, (S.base_health[bname] or 0) + bump)
    S.base_efficiency = S.base_efficiency or {}
    S.base_efficiency[bname] = S.base_health[bname]

    -- Captured-aircraft disposition on keysite loss (WAVE 3 — realign to the C). This fork ships
    -- command_line_capture_aircraft = TRUE by default (cmndline.c:151, "Moje 040304"), so on capture EECH
    -- does NOT destroy or evacuate the RESIDENT IDLE aircraft parked at the seized keysite — it CHANGES
    -- THEIR SIDE to the captor and leaves them parked there (capture_keysite: for each GROUP_MODE_IDLE
    -- aircraft group, set INT_TYPE_SIDE = new_side, keysite.c:1375-1393). destroy_keysite's capture branch
    -- then spares them because they are no longer the old side (keysite.c:1025-1090 only touches SIDE==old).
    -- The port's per-base ledger IS exactly those idle parked groups (supply.lua header), and S.base_owner
    -- has ALREADY flipped above, so we KEEP the ledger untouched: it now counts toward the new owner's
    -- reserve (reserve_side sums owned-base ledgers). This realigns the previous "zero the ledger" proxy,
    -- which modelled the command_line_capture_aircraft = FALSE branch (keysite.c:1130-1133 kills parked
    -- aircraft) — the WRONG default for this fork. The regen-queue reseed below (keysite.c:1483-1517) adds
    -- fresh production slots ON TOP, exactly as EECH does both (captured hardware + regen reseed).
    -- (True EMERGENCY TRANSFER — create_group_emergency_transfer_task, keysite.c:1087/1213 — moves only
    -- AIRBORNE, still-old-side aircraft in their landing phase OUT to a friendly keysite; the port already
    -- models that as in-flight sorties RTB'ing and recycling to the nearest friendly base via
    -- supply.make_land_handler, so no ledger action is owed for it here.)
    do
        local led = S.base_ledger and S.base_ledger[bname]
        local n_captured = 0
        if led then for _, c in pairs(led) do n_captured = n_captured + (c or 0) end end
        cs.dbg("capture", "%s captures %d parked aircraft with %s (ledger kept under new owner; keysite.c:1375-1393, command_line_capture_aircraft=TRUE)",
            cs.SIDE_NAME[new_side], n_captured, bname)
    end

    -- Keysite-loss task termination (EECH destroy_keysite, keysite.c:1229-1260, invoked from
    -- capture_keysite:1423). On capture EECH terminates ALL tasks whose objective is this keysite,
    -- REGARDLESS of side: LIST_TYPE_UNASSIGNED_TASK children → TASK_TERMINATED_ABORTED (:1233-1242)
    -- and LIST_TYPE_TASK_DEPENDENT children → TASK_COMPLETED/TASK_INCOMPLETE (:1248-1260). That kills
    -- BOTH the new owner's (former attacker's) offensive strikes/OCA/TI/recon AND the old owner's
    -- defensive CAP against a base it no longer holds — neither makes sense after the flip.
    -- PROXY: in-flight DCS groups are NOT despawned (too aggressive for the port's event model). We
    -- clear the registry entry so NO follow-on reaction fires (LAND/DEAD read cs.get_task → nil → no
    -- completion chain) and let the group RTB naturally; UNASSIGNED board records are FAILED (they
    -- consumed no ledger yet, so no refund is owed).
    do
        local n_term = 0
        local doomed = {}
        for gname, t in pairs(S.active_tasks or {}) do
            if t.target_base == bname then doomed[#doomed + 1] = gname end
        end
        for _, gname in ipairs(doomed) do cs.clear_task(gname); n_term = n_term + 1 end
        if S.board_tasks then
            for _, t in ipairs(S.board_tasks) do
                if t.state == "UNASSIGNED" and t.target and t.target.base == bname then
                    t.state = "FAILED"; n_term = n_term + 1
                end
            end
        end
        if n_term > 0 then
            cs.dbg("capture", "%s task-termination on capture of %s: %d task(s) cleared (keysite.c:1229-1260)",
                cs.SIDE_NAME[new_side], bname, n_term)
        end
    end

    reseed_regen_on_capture(old_side, new_side, bname, log_fn)
    cs.recalc_strength()

    log_fn(string.format("CAPTURE: %s seizes %s from %s (health→%.0f%%, +%d heli/+%d fw reseed)",
        cs.SIDE_NAME[new_side] or "?", bname, cs.SIDE_NAME[old_side] or "NEUTRAL",
        (S.base_health[bname] or 0) * 100, CAPTURE_REGEN_HELI, CAPTURE_REGEN_FW))
    cs.dbg("capture", "OWNER TRANSITION: %s %s -> %s (health->%.0f%%, kind=%s)",
        bname, cs.SIDE_NAME[old_side] or "NEUTRAL", cs.SIDE_NAME[new_side] or "?",
        (S.base_health[bname] or 0) * 100, tostring(S.base_kind and S.base_kind[bname]))
    trigger.action.outText(string.format("%s captured by %s!", bname, cs.SIDE_NAME[new_side]), 20)

    -- Frontline recomputes on ownership change (EECH computes it at load only because its
    -- ownership map is static; capture is the port's equivalent trigger — see frontline.lua).
    local ok_f, frontl = pcall(require, "frontline")
    if ok_f and frontl and frontl.recompute then pcall(frontl.recompute, log_fn) end

    -- The captor garrisons the seized keysite with its own air defence (the old defenders were
    -- ground down by the strikes that neutralised it).
    local ok_d, bd = pcall(require, "base_defenses")
    if ok_d and bd and bd.regarrison then pcall(bd.regarrison, bname, new_side, log_fn) end

    -- eech F29: keysite capture re-checks campaign objectives on BOTH forces (event-driven).
    local ok_w, wc = pcall(require, "win_condition")
    if ok_w and wc and wc.check_win then pcall(wc.check_win, log_fn) end

    -- Persistence (WAVE 2): a capture is a durable campaign event — checkpoint immediately so a restart
    -- right after a base flips restores the new ownership (EECH pack_session is repacked on such events).
    -- No-op unless persistence enabled; pcall-guarded so a save failure can never abort the capture.
    local ok_p, persist = pcall(require, "persist")
    if ok_p and persist and persist.save then pcall(persist.save, log_fn) end
    return true
end

-- Ground-column capture poll: an enemy ground group parked at a keysite whose efficiency has
-- fallen below the minimum attempts a probabilistic capture (eech mb_msgs.c:2260-2325 analogue
-- for the port's advancing armour; the airmobile troop-insertion path lives in troop.lua).
function M.try_capture(log_fn)
    log_fn = log_fn or function() end
    local n_below_min, n_attempts = 0, 0
    for bname, owner in pairs(S.base_owner) do
        -- Offer gate: capture only offered when efficiency < minimum (eech highlevl.c:1732).
        if M.efficiency(bname) < cs.MINIMUM_EFFICIENCY then
            n_below_min = n_below_min + 1
            local bpos = S.base_pos[bname]
            if bpos then
                -- Any enemy ground group within CAPTURE_RANGE of the keysite may capture it.
                -- Scans the whole standing frontline registry (not a single column).
                for side, groups in pairs(S.ground_groups or {}) do
                    if side ~= owner then
                        for _, rec in pairs(groups) do
                            local col = rec.grp
                            if cs.group_is_alive(col) then
                                local units = col:getUnits()
                                if units and units[1] and units[1]:isExist() then
                                    local upos = units[1]:getPosition().p
                                    if cs.dist2d(upos.x, upos.z, bpos.x, bpos.z) < CAPTURE_RANGE then
                                        -- member_count = column strength; losses proxied 0
                                        -- (port does not track per-column casualties en route).
                                        n_attempts = n_attempts + 1
                                        if M.capture_roll(bname, #units, 0) then
                                            M.do_capture(bname, side, log_fn)
                                        else
                                            log_fn(string.format(
                                                "capture repelled at %s (defence held)", bname))
                                        end
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if n_below_min > 0 then
        cs.dbg("capture", "try_capture tick: %d bases below min-efficiency, %d ground-column capture attempts",
            n_below_min, n_attempts)
    end
end

return M
