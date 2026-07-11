-- farps.lua — base-role classification + forward FARP network
-- EECH source:
--   ks_dbase.c: AIRBASE (air_force_capacity LARGE, fixed-wing + heli, requires_cap TRUE, requires_
--     barcap FALSE); FARP (air_force_capacity SMALL, HELICOPTERS ONLY).
--   popread.c:1601-1664,1981-2019: airfields with fixed-wing runway routes are AIRBASEs, the rest are
--     helicopter sites; FARP keysites are placed at forward FARP objects. EECH warzones field only a
--     handful of fixed-wing airbases plus a dense field of heli-only bases and forward FARPs.
--
-- Two layers, both EECH-faithful:
--  1) CLASSIFY the DCS airfields (PREDICTABLE structure): a fixed number per side (the REAR fields)
--     run as fixed-wing AIRBASEs; the rest run as heli-only FOBs ("FARP only behaviour").
--  2) Place a FORWARD FARP network (RANDOMNESS/variety): extra heli-only forward bases ahead of the
--     line, jittered in position and count so each campaign's rotary staging differs.
-- Enforcement is via the supply ledger: airbase = fixed-wing + heli; FOB/FARP = helicopters only. So
-- fixed-wing (OCA / keysite strike / SEAD) launches ONLY from the few airbases, while the rotary war
-- (CAS/BAI/insertion) flies from the whole FOB + FARP network — an EECH helicopter-primary front.

local cs     = require("campaign_state")
local config = require("config")
local S  = cs.S
local M  = {}

-- EECH warzones field only "a couple" of fixed-wing airbases per side. Cap (config theatre
-- fixed_wing_per_side), and never more than a third of a side's fields, so the majority stay heli-only
-- FOBs even on a small scoped theatre.
local FIXED_WING_PER_SIDE = config.C.theatre.fixed_wing_per_side
local function fixed_wing_count(side_field_count)
    return math.max(1, math.min(FIXED_WING_PER_SIDE, math.floor(side_field_count / 3)))
end
local FRONT_DIST          = config.C.theatre.farp_front_dist   -- m; a base with an enemy within this is "frontline" (config theatre)
local FARP_FWD_MIN        = 18000    -- m: forward-FARP distance ahead of the parent field (min)
local FARP_FWD_MAX        = 40000    -- m: ... (max) — randomised per FARP
local FARP_LATERAL        = 22000    -- m: max random lateral jitter along the front
local FARP_CHANCE         = 70       -- % chance a given frontline field gets a forward FARP (variety)

local COUNTRY = config.C.countries

-- Nearest enemy base to `base` → (name, distance). math.huge if the enemy has none.
local function nearest_enemy(base, side)
    local bp = S.base_pos[base]
    local enemy = cs.ENEMY[side]
    if not bp or not enemy then return nil, math.huge end
    local best, bestd = nil, math.huge
    for name, owner in pairs(S.base_owner) do
        if owner == enemy and S.base_pos[name] then
            local ep = S.base_pos[name]
            local d = cs.dist2d(bp.x, bp.z, ep.x, ep.z)
            if d < bestd then bestd = d; best = name end
        end
    end
    return best, bestd
end

-- ── Dormant-FARP activation (Item 1 — eech keysite.c:507-568 initialise_keysite_farp_enable) ────────
-- EECH FARP keysites are created in_use=FALSE (ks_creat.c:157) and only ACTIVATE when their SECTOR's
-- side matches their own force side (keysite.c:541-547) — i.e. as the friendly front reaches them.
-- Port proxy on bases-as-sectors: the FARP's "sector side" is the owner of the nearest NON-FARP base
-- to it; the FARP is friendly-sector iff that owner == the FARP's own side. Activation LATCHES (EECH
-- only clears in_use on destroy, ks_dstry.c:325). While dormant a FARP is excluded from launch
-- candidacy (task_board.owned_bases ≈ nearest-keysite search keysite.c:369) and the win usable-airbase
-- census (win_condition ≈ fc_msgs.c:234 ALIVE && IN_USE) via cs.base_is_active.
--
-- WATCH ITEM (F5, documented proxy limit): an AUTHOR-PLACED friendly FARP whose nearest NON-FARP base
-- happens to be enemy-owned reads as "sector not friendly" and starts DORMANT under this proxy — even
-- though the author clearly intends it live (EECH's real sector grid is far finer than
-- bases-as-sectors, so its FARP could still sit in a friendly sector there). It self-heals as the
-- front advances past it; an author who wants such deep-forward FARPs active from boot sets
-- theatre.farp_activation = false (all FARPs active — the documented override).
local function sector_side_friendly(fname)
    local fpos  = S.base_pos[fname]
    local fside = S.base_owner[fname]
    if not fpos or not fside then return false end
    local best_owner, best_d = nil, math.huge
    for name, owner in pairs(S.base_owner) do
        if name ~= fname and (S.base_kind or {})[name] ~= "farp" and S.base_pos[name] then
            local bp = S.base_pos[name]
            local d = cs.dist2d(fpos.x, fpos.z, bp.x, bp.z)
            if d < best_d then best_d = d; best_owner = owner end
        end
    end
    return best_owner == fside
end

-- Seed S.farp_active for every FARP at boot. Gate OFF → all FARPs active (authored convenience).
-- Gate ON (default, EECH-faithful) → active only if the FARP's sector is already friendly; the rest
-- stay dormant until M.update latches them.
function M.seed_activation(log_fn)
    log_fn = log_fn or function() end
    S.farp_active = S.farp_active or {}
    local gate = config.C.theatre.farp_activation
    local n_active, n_dormant = 0, 0
    for name, kind in pairs(S.base_kind or {}) do
        if kind == "farp" then
            local active = (not gate) or sector_side_friendly(name)
            S.farp_active[name] = active or nil
            if active then n_active = n_active + 1 else n_dormant = n_dormant + 1 end
        end
    end
    log_fn(string.format("FARP activation (gate=%s): %d active, %d dormant (dormant activate as the front nears)",
        tostring(gate), n_active, n_dormant))
    cs.dbg("farps", "seed_activation gate=%s: %d active, %d dormant", tostring(gate), n_active, n_dormant)
end

-- Periodic latch: activate any dormant FARP whose sector has become friendly (front advanced). This is
-- the "dormant-FARP activation as the front moves" — EECH re-runs initialise_keysite_farp_enable at
-- campaign setup; the port re-evaluates the same sector-side predicate as ownership shifts.
function M.update(log_fn)
    log_fn = log_fn or function() end
    S.farp_active = S.farp_active or {}
    if not config.C.theatre.farp_activation then return end   -- gate off → all already active
    for name, kind in pairs(S.base_kind or {}) do
        if kind == "farp" and not S.farp_active[name] and sector_side_friendly(name) then
            S.farp_active[name] = true
            log_fn(string.format("FARP %s ACTIVATED — sector now friendly (front reached)", name))
            cs.dbg("farps", "FARP %s ACTIVATED (sector friendly, keysite.c:541 proxy)", name)
        end
    end
end

-- Scheduler (registered once from game_loop.start): re-evaluate FARP activation every 120 s.
function M.schedule(log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    local PERIOD = 120
    cs.dbg("farps", "activation scheduler REGISTERED period=%ds", PERIOD)
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end
        pcall(M.update, log_fn)
        return t + PERIOD
    end, nil, timer.getTime() + PERIOD)
end

-- Called from game_loop init AFTER base discovery, BEFORE supply.init (the ledger reads base_kind).
function M.init(log_fn)
    log_fn = log_fn or function() end
    S.base_kind = S.base_kind or {}
    pcall(function() math.randomseed(math.floor((timer.getTime() or 0) * 1000) + cs.GENERATION * 7919) end)

    -- ── AUTHORED theatre (zone-based) — REGISTER, do not spawn ────────────────────
    -- When the bases were authored by ME keysite zones, keysite.lua already set base_kind
    -- ("airbase"/"farp") from the zones. The author PLACES the FARP static in the Mission Editor
    -- (it auto-registers as a HELIPAD airbase); the campaign SPAWNS NOTHING here. We only confirm the
    -- farp roles. The supply-ledger contract (base_kind "airbase" = fixed-wing+heli; "farp" =
    -- heli-only) is already set by keysite.lua and preserved.
    if require("zones").has_keysite_zones() then
        local nfarp = 0
        for _, kind in pairs(S.base_kind) do
            if kind == "farp" then nfarp = nfarp + 1 end
        end
        log_fn(string.format("base roles from zones: %d farp bases confirmed (author-placed FARP "
            .. "statics; NO spawning) — airbase/farp roles set by keysite zones", nfarp))
        cs.dbg("farps", "init (zone-authored): %d farp bases confirmed, no spawning", nfarp)
        M.seed_activation(log_fn)   -- Item 1: dormant-FARP activation seeding (zone-authored FARPs)
        return
    end

    -- ── Layer 1: classify airfields (predictable) ────────────────────────────────
    local nfw, nfob = 0, 0
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local fields = {}
        for name, owner in pairs(S.base_owner) do
            if owner == side then
                local _, d = nearest_enemy(name, side)
                fields[#fields + 1] = { name = name, d = d }
            end
        end
        -- Rear-most fields (largest distance to the enemy) are the fixed-wing AIRBASEs; the forward
        -- fields become heli-only FOBs. The airbase count scales down on a small theatre so the
        -- majority always stay heli (never more than a third of a side's fields, capped at 2).
        table.sort(fields, function(a, b) return a.d > b.d end)
        local nfw_side = fixed_wing_count(#fields)
        for i, f in ipairs(fields) do
            if i <= nfw_side then S.base_kind[f.name] = "airbase"; nfw = nfw + 1
            else S.base_kind[f.name] = "fob"; nfob = nfob + 1 end
        end
    end

    -- ── Layer 2: forward FARP network (randomised) ───────────────────────────────
    local airfields = {}
    for name, owner in pairs(S.base_owner) do
        if S.base_kind[name] == "airbase" or S.base_kind[name] == "fob" then
            airfields[#airfields + 1] = { name = name, owner = owner }
        end
    end
    local nfarp = 0
    for _, ab in ipairs(airfields) do
        local enemy_base, d = nearest_enemy(ab.name, ab.owner)
        if enemy_base and d < FRONT_DIST and math.random(100) <= FARP_CHANCE then
            local bp, ep = S.base_pos[ab.name], S.base_pos[enemy_base]
            local dx, dz = ep.x - bp.x, ep.z - bp.z
            local len = math.max(math.sqrt(dx * dx + dz * dz), 1)
            local ux, uz = dx / len, dz / len          -- unit vector toward the enemy
            local px, pz = -uz, ux                       -- perpendicular (lateral) unit vector
            local fwd = FARP_FWD_MIN + math.random() * (FARP_FWD_MAX - FARP_FWD_MIN)
            local lat = (math.random() * 2 - 1) * FARP_LATERAL
            -- Snap the forward-FARP placement off water (a jittered point 18-40 km ahead of a coastal
            -- field can land in the sea); fallback = the parent field centre `bp` (always land).
            local fp = cs.snap_land(bp.x + ux * fwd + px * lat, bp.z + uz * fwd + pz * lat, bp.x, bp.z)
            local fx = fp.x
            local fz = fp.z
            local fname = "FARP-" .. ab.name:sub(1, 12)

            S.base_owner[fname]  = ab.owner
            S.base_pos[fname]    = { x = fx, z = fz }
            S.base_health[fname] = 1.0
            S.base_kind[fname]   = "farp"

            -- Idempotent: FARP statics survive reset.nuke (it destroys groups, not statics).
            if not Airbase.getByName(fname) then
                local fs = config.C.statics.farp   -- config statics.farp = {type, shape_name, category}
                coalition.addStaticObject(COUNTRY[ab.owner], {
                    heading = 0, type = fs.type, shape_name = fs.shape_name, category = fs.category,
                    name = fname, x = fx, y = fz, dead = false,
                })
            end
            nfarp = nfarp + 1
        end
    end

    log_fn(string.format("base roles: %d fixed-wing AIRBASEs (rear) + %d heli-only FOBs + %d forward "
        .. "FARPs — fixed-wing flies only from airbases; the rotary front war flies from FOBs + FARPs",
        nfw, nfob, nfarp))
    cs.dbg("farps", "init (auto): %d airbases, %d heli-only FOBs, %d forward FARPs placed", nfw, nfob, nfarp)
    M.seed_activation(log_fn)   -- Item 1: dormant-FARP activation seeding (auto-theatre forward FARPs)
end

-- NOTE: M.is_heli_only was DELETED in Cluster H (zero callers) — heli-only enforcement lives in the
-- ledger seeding (supply.lua: FOB/FARP bases get no fixed-wing striker/escort/recon roles), which is
-- what actually confines fixed-wing to the airbases.

return M
