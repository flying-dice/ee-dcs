-- installations.lua
-- EECH source: aphavoc/source/entity/special/keysite/keysite.h + keysite_database
--   Non-airbase keysites — bridges / depots / factories / radar / command — each with per-type
--   flags: oca_target, ground_strike_target, ship_strike_target, troop_insertion_target,
--   recon_target, requires_cap, requires_barcap, minimum_efficiency.
--
-- WHY THIS MODULE EXISTS: airbase-only keysites made create_keysite_strike_tasks (ground_strike_
-- target) and create_oca_strike_tasks (oca_target) hit the SAME set. EECH's keysite database has
-- many ground_strike-only keysites (depots, radars, bridges) that OCA never touches. These
-- installations restore that distinction: they are ground_strike_target + recon_target but NOT
-- oca_target / troop_insertion_target — so the ground-strike tasker and artillery hit them while
-- OCA-strike stays airfield-only.
--
-- TWO MODES:
--   • ZONE-AUTHORED (preferred, register_static_death spec): when the author placed keysite trigger
--     zones, the campaign REGISTERS the STATIC OBJECTS the author dropped inside each circle — it
--     SPAWNS NOTHING. Keysite health = alive registered assets / total registered assets; a struck
--     keysite destroys that fraction of its still-alive statics and drains toward 0 (neutralised /
--     capturable at < MINIMUM_EFFICIENCY, never removed). Terrain-safe: the author controls placement.
--   • AUTO (fallback, no zones): installations are placed PROCEDURALLY around each airbase (legacy).
--     Kept intact so an empty Caucasus mission still boots a scenario; this path still spawns.

local cs     = require("campaign_state")
local config = require("config")
local S  = cs.S
local M  = {}

-- Physical small keysites are now SPAWNED (verified live: statics need a valid type/shape_name/
-- category triple AND a running sim — addStaticObject throws "Can't update mission database" while
-- the sim is paused at t=0, which caused the earlier crash confusion; on a live sim the verified
-- triples below spawn and persist cleanly). All triples were extracted from an ME-authored .miz so
-- they are guaranteed-good shapes. Radar sites are REAL EWR ground units so SEAD has a live emitter
-- to hunt. Everything spawns through the coalition.* stagger queue (spawn_queue) so the whole
-- infrastructure network drains in over time rather than popping in at once.
local SPAWN_PHYSICAL = true

-- ── Installation kinds (hoisted to config.statics.kinds; ME-VERIFIED static triples + EWR units) ──
-- spawn = "static": {type, shape, cat} verified from a mission-editor .miz (spawn+persist confirmed).
-- spawn = "unit":   an EWR radar GROUND unit per side — a SEAD target with a real emitter.
local COUNTRY = config.C.countries
local KINDS   = config.C.statics.kinds

-- ── Production keysites (KEYSITE-F1/F5) ────────────────────────────────────────
-- eech ks_dbase.c factory/refinery/port rows; default_supply_usage (spec 03 §2.3, %/min):
--   FACTORY   ammo +1.0, fuel  0.0   (eech ks_dbase.c:185-224 factory row)
--   REFINERY  ammo  0.0, fuel +1.0   (eech ks_dbase.c:420-459 oil-refinery row)
-- Positive default_supply_usage = PRODUCER (accumulates stock as cargo crates, eech ks_updt.c:
-- 136-146). While alive AND owned, a producer feeds its side's economy: crate deliveries restock
-- consumer keysites (KEYSITE-F6/F7/F8) and surplus crates replace hardware losses (supply.lua).
-- Rates are percentage-points-per-minute (= 0.1 CARGO crate/min at +1.0; CARGO_*_SIZE=10, cargo.h:89).
local PRODUCER = {
    factory  = { ammo = 1.0, fuel = 0.0 },   -- eech ks_dbase.c factory default_supply_usage
    refinery = { ammo = 0.0, fuel = 1.0 },   -- eech ks_dbase.c oil-refinery default_supply_usage
    port     = { ammo = 0.0, fuel = 1.0 },   -- port keysite: fuel logistics (proxy = refinery row)
}

-- Flags per kind = the FULL keysite_database row (ks_dbase.c) each zone kind maps to. NO installation
-- requires CAP or BARCAP and NONE is an oca_target — that is the whole point (distinct from airbases,
-- which OCA hits). Producers are ground_strike_target too so the ground-strike / CAS / artillery
-- taskers hit them: destroying an enemy factory genuinely starves that side (production_rates drops
-- → no crate deliveries, no reserve replacement).
-- The port zone kind → EECH keysite_database row (ks_dbase.c), with the six task-relevant flags read
-- by the reaction chain (Cluster I made keysite_flags kind-aware, so these are now consumed):
--   factory  → FACTORY          (cap F:214, oca F:218, recon F:219, gs T:220, ti T:222)
--   refinery → OIL_REFINERY     (cap F:449, oca F:453, recon T:454, gs T:455, ti F:457)
--   fuel     → OIL_REFINERY (analog: fuel dump ≈ refinery/fuel logistics — same row)
--   port     → PORT             (cap F:355, oca F:359, recon F:360, gs T:361, ti F:363)
--   power    → POWER_STATION    (cap F:402, oca F:406, recon T:407, gs T:408, ti F:410)
--   radar    → RADIO_TRANSMITTER(cap F:496, oca F:500, recon T:501, gs T:502, ti F:504)
--   depot    → MILITARY_BASE    (cap F:308, oca F:312, recon T:313, gs T:314, ti T:316)
--   command  → MILITARY_BASE    (same row as depot)
local FLAGS = {
    factory  = { requires_cap = false, requires_barcap = false, oca_target = false, ground_strike_target = true,  troop_insertion_target = true,  recon_target = false },
    refinery = { requires_cap = false, requires_barcap = false, oca_target = false, ground_strike_target = true,  troop_insertion_target = false, recon_target = true  },
    fuel     = { requires_cap = false, requires_barcap = false, oca_target = false, ground_strike_target = true,  troop_insertion_target = false, recon_target = true  },
    port     = { requires_cap = false, requires_barcap = false, oca_target = false, ground_strike_target = true,  troop_insertion_target = false, recon_target = false },
    power    = { requires_cap = false, requires_barcap = false, oca_target = false, ground_strike_target = true,  troop_insertion_target = false, recon_target = true  },
    radar    = { requires_cap = false, requires_barcap = false, oca_target = false, ground_strike_target = true,  troop_insertion_target = false, recon_target = true  },
    depot    = { requires_cap = false, requires_barcap = false, oca_target = false, ground_strike_target = true,  troop_insertion_target = true,  recon_target = true  },
    command  = { requires_cap = false, requires_barcap = false, oca_target = false, ground_strike_target = true,  troop_insertion_target = true,  recon_target = true  },
}

-- Kind-aware keysite_database row lookup (consumed by reaction.keysite_flags for installation
-- objectives). Returns the FULL flag row for a zone kind, or nil for an unknown kind.
function M.flags_for_kind(kind)
    return FLAGS[kind]
end

-- Human-readable label per keysite ZONE type (kind = zone.type verbatim; see init_from_zones).
local ZONE_LABELS = {
    factory  = "Munitions Factory", refinery = "Oil Refinery", port = "Port",
    power    = "Power Station",      radar   = "Radar/EWR",    depot = "Supply Depot",
    fuel     = "Fuel Depot",         command = "Command Post",
}

-- Which installations each base fields, and how far into its rear (metres) they sit.
local BASE_LOADOUT = { "depot", "fuel", "radar" }   -- every owned base: consumer/target installations
local REAR_LOADOUT = { "factory", "refinery" }       -- producers: rear bases only (safe from the front)
local REAR_OFFSET  = 3200    -- m behind the base — close enough to read as THIS base's support
                             -- complex (was 10 km, which scattered them far from their airfield)
local KILL_DMG     = 0.15    -- default per-hit health fraction for M.damage (deterministic strike channel)
local FRONT_DIST   = config.C.theatre.front_dist  -- m; a base within this of an enemy base is "frontline" (config theatre; matches ground_forces)
local LOW_TARGET_THRESHOLD = 2  -- a keysite with 1..this registered assets is flagged "low targets" (a
                                -- warning to the author: place more statics/resource objects in the circle)

-- Distance from `base` to its nearest enemy base (math.huge if the enemy has no base).
local function nearest_enemy_dist(base, side)
    local bp = S.base_pos[base]
    local enemy = cs.ENEMY[side]
    if not bp or not enemy then return math.huge end
    local best = math.huge
    for name, owner in pairs(S.base_owner) do
        if owner == enemy then
            local ep = S.base_pos[name]
            if ep then
                local d = cs.dist2d(bp.x, bp.z, ep.x, ep.z)
                if d < best then best = d end
            end
        end
    end
    return best
end

-- A base is "rear" if no enemy base is within FRONT_DIST — the safe interior where EECH sites its
-- factories/refineries. Producers only spawn at rear bases so they are a strategic depth objective.
local function is_rear(base, side)
    return nearest_enemy_dist(base, side) > FRONT_DIST
end

-- Direction from a base into its own rear = away from the nearest enemy base.
local function rear_offset_pos(base, side)
    local bp = S.base_pos[base]
    if not bp then return nil end
    local enemy = cs.ENEMY[side]
    -- Default rear direction = due-north offset; overridden by the nearest enemy base if any.
    local ex, ez, best, found = bp.x, bp.z + 1, math.huge, false
    for name, owner in pairs(S.base_owner) do
        if owner == enemy then
            local ep = S.base_pos[name]
            if ep then
                local d = cs.dist2d(bp.x, bp.z, ep.x, ep.z)
                if d < best then best = d; ex, ez = ep.x, ep.z; found = true end
            end
        end
    end
    if not found then return { x = bp.x + REAR_OFFSET, z = bp.z } end
    local dx, dz = bp.x - ex, bp.z - ez           -- points into the rear (away from enemy)
    local len = math.max(math.sqrt(dx*dx + dz*dz), 1)
    return { x = bp.x + dx/len * REAR_OFFSET, z = bp.z + dz/len * REAR_OFFSET }
end

-- Spawn the installation's physical object: a building STATIC (verified triple) or an EWR UNIT
-- (radar sites). Both go through the coalition.* stagger queue (spawn_queue) so they drain in over
-- time. Returns "static" | "unit" so damage() knows which registry to destroy from.
local function spawn_installation(kname, kind, side, pos)
    local spec = KINDS[kind]
    local cid  = COUNTRY[side]
    if not spec or not cid or not SPAWN_PHYSICAL then return spec and spec.spawn or nil end
    if spec.spawn == "static" then
        pcall(coalition.addStaticObject, cid, {
            heading = 0, type = spec.type, shape_name = spec.shape, category = spec.cat,
            name = kname, x = pos.x, y = pos.z, dead = false,
        })
    elseif spec.spawn == "unit" then
        local utype = spec.unit[side]
        if utype then
            pcall(coalition.addGroup, cid, Group.Category.GROUND, {
                name = kname, task = "Ground Nothing",
                units = { { name = kname .. "-1", type = utype, x = pos.x, y = pos.z, heading = 0, skill = "Average" } },
                route = { points = { { x = pos.x, y = pos.z, type = "Turning Point", action = "Off Road",
                                       speed = 0, ETA = 0, ETA_locked = true } } },
            })
        end
    end
    return spec.spawn
end

-- Decide which owned bases host the production keysites: every rear base, but guarantee at least
-- one producer per side (the base farthest from the enemy) so a side always has an economy even on
-- a tiny/all-frontline map.
local function pick_producer_bases()
    local producer = {}   -- [base] = true
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        local owned, any_rear = {}, false
        for base, owner in pairs(S.base_owner) do
            if owner == side then owned[#owned + 1] = base end
        end
        for _, base in ipairs(owned) do
            if is_rear(base, side) then producer[base] = true; any_rear = true end
        end
        if not any_rear and #owned > 0 then
            local best, best_d = nil, -1
            for _, base in ipairs(owned) do
                local d = nearest_enemy_dist(base, side)
                if d ~= math.huge and d > best_d then best_d = d; best = base end
            end
            best = best or owned[1]
            if best then producer[best] = true end
        end
    end
    return producer
end

-- ── Zone-authored keysites (register author-placed statics; spawn nothing) ────

-- Recompute alive-asset count and health from the destroyed-asset set. health = alive/total; a
-- keysite with 0 registered assets reads 0 (neutralised/capturable). Idempotent — the S_EVENT_DEAD
-- handler and M.damage both mark rec.dead[name] and call this, so double reports are harmless.
-- Assets are TWO registries folded into one total: author-placed STATICS (rec.assets, drained by name
-- via rec.dead[name]) and destroyable resource SCENERY (rec.scenery rows, drained by rec.scenery[i].dead
-- from the getLife poll / a direct destroy). total = #statics + #scenery; a scenery entry counts as dead
-- when its .dead flag is set. Keeps the statics accounting identical to before.
local function recompute_health(rec)
    if not rec.assets and not rec.scenery then return end
    local total = rec.total or 0
    local dead = 0
    if rec.assets then
        for _, nm in ipairs(rec.assets) do
            if rec.dead[nm] then dead = dead + 1 end
        end
    end
    if rec.scenery then
        for _, s in ipairs(rec.scenery) do
            if s.dead then dead = dead + 1 end
        end
    end
    rec.alive  = math.max(0, total - dead)
    rec.health = (total > 0) and (rec.alive / total) or 0
end

-- Nearest side-owned base to a point → name (for the damage log + capture affinity), or nil.
local function nearest_owned_base(pos, side)
    local best, bestd = nil, math.huge
    for name, owner in pairs(S.base_owner) do
        if owner == side then
            local bp = S.base_pos[name]
            if bp then
                local d = cs.dist2d(pos.x, pos.z, bp.x, bp.z)
                if d < bestd then bestd = d; best = name end
            end
        end
    end
    return best
end

-- ── Empty-site default TEMPLATE (DESIGNER DATA — not EECH-sourced) ────────────────────────────────
-- When a keysite zone has NO author-placed assets, spawn a well-crafted default instead of leaving it
-- pending: the type's building static PLUS a defensive garrison company. The spawned statics register
-- as the keysite's drainable assets; the garrison gives an empty auto-zone some ground presence.
-- FIDELITY NOTE: this garrison composition is DESIGNER DATA, NOT an EECH constant. EECH's actual
-- per-keysite ground presence is (a) INFANTRY PATROLS — create_troop_patrol_tasks, highlevl.c:2735,
-- 4-man infantry, already ported in troop.lua — and (b) population-data firing points (popread.c).
-- The former "order.c:361" citation was WRONG: that line is armoured-company ORGANISATION (3 groups
-- per company), not a keysite garrison. Placed statics always override this EMPTY-zone fallback.
-- ── Verified spawn PALETTE (type|shape_name|category — all extracted from ME-placed statics) ──────
-- These are the building blocks the templates draw on. Every triple is confirmed to spawn+persist.
-- Verified spawn PALETTE + defence element types are hoisted to config.lua (statics.palette,
-- types.ground.{garrison,aaa,sam,ewr}). GARRISON_UNITS is DESIGNER DATA — a mixed defensive company
-- for an empty auto-zone, not an EECH composition (EECH keysite ground = the infantry patrol of
-- troop.lua + population firing points; see the TEMPLATE header). Author-placed statics override.
local PALETTE        = config.C.statics.palette
local GARRISON_UNITS = config.C.types.ground.garrison
local AAA_UNIT       = config.C.types.ground.aaa
local SAM_UNITS      = config.C.types.ground.sam
local EWR_UNIT       = config.C.types.ground.ewr

-- ── Site TEMPLATES — organic shorthand, reasoned per keysite type ─────────────────────────────
-- `b` = the buildings that make up the installation {palette token = count}; `d` = its defence force
-- {garrison / aaa / sam / ewr}. The transpiler below lays the buildings on a grid and rings them with
-- the defenders. This is the EMPTY-zone fallback (a designer-authored complex + defensive garrison;
-- author-placed statics override it entirely. Reasoning per type:
--   factory  — a production line (3 halls) + finished-goods warehouses + an ammo store + fuel, armour+AAA
--   refinery — tank farm (fuel dumps + oil tanks) + a warehouse, armour+AAA
--   port     — quayside warehouses + fuel tanks + an ammo store, armour+AAA
--   depot    — the supply hub: warehouses + containers + ammo + fuel, armour+AAA
--   fuel     — a fuel/tank farm, armour+AAA
--   command  — HQ building + hardened bunker + a store, armour + AAA + a point SAM (HQs are defended)
--   power    — the plant (2 halls) + transformer yard (containers) + fuel, armour+AAA
--   radar    — an EWR站 + a SAM battery + a bunker + AAA (the radar site IS its air-defence node)
local TEMPLATES = {
    factory  = { b = { factory = 3, warehouse = 2, fueltank = 1, ammo = 1 }, d = { garrison = 1, aaa = 2 } },
    refinery = { b = { fuel = 2, fueltank = 3, warehouse = 1 },              d = { garrison = 1, aaa = 2 } },
    port     = { b = { warehouse = 3, fueltank = 2, ammo = 1 },              d = { garrison = 1, aaa = 2 } },
    depot    = { b = { warehouse = 2, container = 3, ammo = 2, fueltank = 1 }, d = { garrison = 1, aaa = 1 } },
    fuel     = { b = { fuel = 2, fueltank = 3 },                             d = { garrison = 1, aaa = 1 } },
    command  = { b = { command = 1, bunker = 1, warehouse = 1 },             d = { garrison = 1, aaa = 1, sam = 1 } },
    power    = { b = { factory = 2, container = 2, fueltank = 1 },           d = { garrison = 1, aaa = 1 } },
    radar    = { b = { bunker = 1 },                                         d = { ewr = 1, sam = 1, aaa = 1 } },
}

-- Spawn one palette static; returns its name (for asset registration) or nil.
local function spawn_palette_static(name, token, side, x, z)
    local p, cid = PALETTE[token], COUNTRY[side]
    if not p or not cid then return nil end
    pcall(coalition.addStaticObject, cid, {
        heading = 0, type = p[1], shape_name = p[2], category = p[3], name = name, x = x, y = z, dead = false,
    })
    return name
end

-- Spawn a ground group from a flat unit-type list around `pos` (pcall-guarded).
local function spawn_ground(name, side, types, pos)
    local cid = COUNTRY[side]
    if not cid or #types == 0 then return end
    local units = {}
    for i, t in ipairs(types) do
        local ux = pos.x + ((i - 1) % 3) * 30
        local uz = pos.z + math.floor((i - 1) / 3) * 30
        units[i] = { name = name .. "-" .. i, type = t, skill = "Average",
            x = ux, y = uz, heading = 0, alt = land.getHeight({ x = ux, y = uz }), alt_type = "BARO" }
    end
    pcall(coalition.addGroup, cid, Group.Category.GROUND, {
        name = name, task = "Ground Nothing", hidden = false, units = units,
        route = { points = { { type = "Turning Point", action = "Off Road", speed = 0, ETA = 0,
            ETA_locked = true, x = pos.x, y = pos.z,
            alt = land.getHeight({ x = pos.x, y = pos.z }), alt_type = "BARO", name = "Hold" } } },
    })
end

-- Transpile a site TEMPLATE into DCS spawns: a grid of buildings + a ringing defence force. Returns
-- the spawned STATIC names (the keysite's drainable assets).
local function spawn_keysite_template(kname, kind, side, pos)
    local tmpl = TEMPLATES[kind]
    if not tmpl then return {} end
    local cx, cz = pos.x, pos.z
    local names = {}
    -- Buildings: flatten {token=count} into a list, lay out on a centred ~45 m grid.
    local blds = {}
    for token, n in pairs(tmpl.b) do for _ = 1, n do blds[#blds + 1] = token end end
    local cols = math.max(1, math.ceil(math.sqrt(#blds)))
    for i, token in ipairs(blds) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        -- Snap EACH grid cell off water (fixes "factory 5/7 at Batumi": coastal grid cells landed in
        -- the sea); each building is its own STATIC → snap each, fallback = the keysite centre (cx,cz).
        local cell = cs.snap_land(cx + (col - (cols - 1) / 2) * 45, cz + (row - (cols - 1) / 2) * 45, cx, cz)
        local sn = spawn_palette_static(string.format("%s-b%d", kname, i), token, side, cell.x, cell.z)
        if sn then names[#names + 1] = sn end
    end
    -- Defence: each element is its OWN group so a bad unit type only loses that element (a mixed group
    -- fails entirely on one bad type). Each element's origin is snapped off water (fixes "def groups
    -- only ~4 survived" at coastal Batumi); fallback = the keysite centre (cx,cz). snap_land returns a
    -- {x=,z=} table, exactly the `pos` shape spawn_ground consumes; per-unit offsets stay relative to it.
    local d = tmpl.d or {}
    if d.garrison then spawn_ground(kname .. "-def", side, GARRISON_UNITS[side] or {}, cs.snap_land(cx + 30, cz + 30, cx, cz)) end
    if (d.aaa or 0) > 0 and AAA_UNIT[side] then
        local aaa = {}
        for _ = 1, d.aaa do aaa[#aaa + 1] = AAA_UNIT[side] end
        spawn_ground(kname .. "-aaa", side, aaa, cs.snap_land(cx - 50, cz + 50, cx, cz))
    end
    if d.sam then spawn_ground(kname .. "-sam", side, SAM_UNITS[side] or {}, cs.snap_land(cx - 40, cz - 40, cx, cz)) end
    if d.ewr and EWR_UNIT[side] then spawn_ground(kname .. "-ewr", side, { EWR_UNIT[side] }, cs.snap_land(cx + 50, cz - 30, cx, cz)) end
    return names
end

-- REGISTER S.keysites from the author's non-basing keysite zones (factory/refinery/port/radar/depot/
-- fuel/power/command). For each zone, the STATIC OBJECTS the author placed inside the circle become
-- that keysite's assets. NOTHING is spawned. kind = zone.type verbatim; side = zone colour; health =
-- 1.0 while any asset is alive, else 0. Preserves S.keysites entries already added by keysite.lua
-- (airbase-zone assets) — keysite.init_base_state runs before this.
local function init_from_zones(log_fn)
    S.keysites = S.keysites or {}
    local zones = require("zones")
    local n, np, nassets, npending = 0, 0, 0, 0
    local warnings = {}   -- keysites with no/low targets (author feedback)
    for _, kz in ipairs(zones.keysites()) do
        local kind = kz.type
        -- airbase/farp zones are basing keysites (keysite.lua / farps.lua); skip here.
        if kind ~= "airbase" and kind ~= "farp" and kz.side then
            local pos    = { x = kz.x, z = kz.z }
            local kname  = string.format("KS-%s-%s", kind, tostring(kz.label))
            local uniq, k = kname, 1
            while S.keysites[uniq] do k = k + 1; uniq = kname .. "-" .. k end
            kname = uniq
            local assets  = zones.statics_in_zone(kz.label)  -- author-placed statics inside the circle
            -- Destroyable resource SCENERY inside the circle (fuel/warehouse — TOPLIVO-BAK/SKLADIK/etc.),
            -- registered exactly like statics and folded into the same totals. The author's zone bounds
            -- which objects count, so a zone drawn over a real depot/warehouse cluster registers them.
            local scenery = {}
            for _, srow in ipairs(zones.scenery_in_zone(kz.label, zones.RESOURCE_SCENERY)) do
                scenery[#scenery + 1] = { id = srow.id, type = srow.type, handle = srow.handle, dead = false }
            end
            local nstatics, nscen = #assets, #scenery
            local ntotal = nstatics + nscen
            -- NO AUTHOR-PLACED STATICS → spawn a well-crafted default TEMPLATE (building complex +
            -- defensive garrison) rather than leaving it thin. Gated on placed STATICS only (not scenery):
            -- a zone that merely overlaps some found civilian scenery should still get its full complex +
            -- garrison (the scenery just adds to the asset pool). Placed statics always win. (User
            -- directive; garrison is DESIGNER DATA — EECH keysite ground presence is the infantry patrol
            -- of troop.lua + population firing points, NOT the mis-cited order.c:361 company org.)
            local templated = false
            if nstatics == 0 then
                for _, sn in ipairs(spawn_keysite_template(kname, kind, kz.side, pos)) do
                    assets[#assets + 1] = sn
                end
                nstatics, ntotal, templated = #assets, #assets + nscen, true
            end
            -- PENDING only if the template spawned nothing at all (should not happen for known kinds).
            local pending     = (ntotal == 0) and not templated
            local low_targets = (not pending) and (not templated) and (ntotal <= LOW_TARGET_THRESHOLD)
            S.keysites[kname] = {
                kind      = kind,                             -- zone.type verbatim
                side      = kz.side,                          -- authoritative side from zone colour
                pos       = pos,
                home_base = nearest_owned_base(pos, kz.side) or kz.label,
                assets    = assets,                           -- list of registered static NAMES
                dead      = {},                               -- destroyed-static set (name → true)
                scenery   = scenery,                          -- registered resource-scenery rows (held handles)
                total     = ntotal,                           -- statics + scenery
                alive     = ntotal,
                health    = (ntotal > 0) and 1.0 or 0,
                pending   = pending,                          -- empty circle: excluded until filled
                templated = templated,                        -- empty-zone TEMPLATE spawned its own -aaa/
                                                              -- -sam defence → base_defenses skips it (no
                                                              -- double AD ring). Author-placed keysites
                                                              -- (templated=false) get the ring.
                low_targets = low_targets,                    -- 1..threshold assets → author warning
                flags     = FLAGS[kind] or { ground_strike_target = true, recon_target = true },
                label     = ZONE_LABELS[kind] or kind,
                producer  = PRODUCER[kind],                   -- {ammo,fuel} %/min, or nil
            }
            n = n + 1
            nassets = nassets + ntotal
            if pending then npending = npending + 1
            elseif PRODUCER[kind] then np = np + 1 end
            if pending or low_targets then
                warnings[#warnings + 1] = string.format("%s(%d)", tostring(kz.label), ntotal)
            end
            log_fn(string.format("  keysite %s [%s] registered %d placed statics + %d resource scenery%s",
                kname, cs.SIDE_NAME[kz.side] or "?", nstatics, nscen,
                pending and " (PENDING — empty)" or (low_targets and " (LOW TARGETS)" or "")))
        end
    end
    log_fn(string.format("installations from zones: %d keysites (%d producers, %d pending/empty), "
        .. "%d registered statics (author-placed — NO spawning)", n, np, npending, nassets))
    cs.dbg("installs", "init_from_zones: %d keysites (%d producers, %d pending/empty), %d assets registered",
        n, np, npending, nassets)
    if #warnings > 0 then
        local list = table.concat(warnings, ", ")
        log_fn(string.format("WARNING: %d keysite(s) have no/low targets (<= %d assets) — place more "
            .. "statics/resource objects in these circles: %s", #warnings, LOW_TARGET_THRESHOLD, list))
        -- Surface the same warning in-game so the author sees it on-screen, not just in the log.
        pcall(trigger.action.outText, string.format(
            "\226\154\160 CAMPAIGN: %d keysite(s) need targets (<= %d assets each).\n"
            .. "Place static objects / resource scenery inside these zone circles:\n%s",
            #warnings, LOW_TARGET_THRESHOLD, list), 30, false)
    end
end

-- ── Static-death → keysite drain (world event handler) ────────────────────────
-- A registered asset dying (bomb, artillery, capture) decrements its keysite's alive count and
-- recomputes health. Re-injection safe: stored in _G.__dmt_static_death_handler, old one removed
-- first (world.addEventHandler has no auto-cleanup).
function M.register_static_death(static_name, log_fn)
    if not static_name then return nil end
    for kname, rec in pairs(S.keysites or {}) do
        if rec.assets and rec.dead and not rec.dead[static_name] then
            for _, nm in ipairs(rec.assets) do
                if nm == static_name then
                    rec.dead[static_name] = true
                    recompute_health(rec)
                    -- Under-attack defensive CAP (keysite.c:854 notify_keysite_structure_under_attack):
                    -- a keysite BUILDING dying IS the EECH under-attack trigger. For an AIRFIELD-asset
                    -- record the keysite is the airbase (rec.home_base, requires_cap → scrambles CAP —
                    -- covers a HUMAN bombing airfield structures, MP-critical). Installation records
                    -- (requires_cap FALSE) no-op inside on_keysite_under_attack, so gate to airbase kind.
                    if rec.kind == "airbase" and rec.home_base then
                        local ok_r, react = pcall(require, "reaction")
                        if ok_r and react and react.on_keysite_under_attack then
                            pcall(react.on_keysite_under_attack, rec.home_base, log_fn)
                        end
                    end
                    if log_fn then
                        log_fn(string.format("keysite %s asset lost: %s (%d/%d alive, %.0f%%)",
                            rec.label or kname, static_name, rec.alive, rec.total, rec.health * 100))
                    end
                    cs.dbg("installs", "%s asset lost: %s (%d/%d alive, %.0f%%)%s",
                        kname, static_name, rec.alive, rec.total, rec.health * 100,
                        (rec.health <= 0.1) and " -> NEUTRALISED" or "")
                    return kname
                end
            end
        end
    end
    return nil
end

function M.init_static_death_handler(log_fn)
    log_fn = log_fn or function() end
    if _G.__dmt_static_death_handler then
        pcall(world.removeEventHandler, _G.__dmt_static_death_handler)
        _G.__dmt_static_death_handler = nil
    end
    local h = {}
    function h:onEvent(event)
        if not event then return end
        if event.id ~= world.event.S_EVENT_DEAD and event.id ~= world.event.S_EVENT_KILL then return end
        local obj = (event.id == world.event.S_EVENT_KILL) and event.target or event.initiator
        if not obj then return end
        local ok, nm = pcall(function() return obj:getName() end)
        -- register_static_death no-ops unless the name is a registered keysite asset, so this is safe
        -- to call for every dead object regardless of its category.
        if ok and nm then M.register_static_death(nm, log_fn) end
    end
    world.addEventHandler(h)
    _G.__dmt_static_death_handler = h
end

-- ── Scenery drain via polling (held-handle getLife) ───────────────────────────
-- Resource scenery emits NO S_EVENT_DEAD the death handler can key off (and can't be re-acquired by
-- name), so its attrition is detected by POLLING the held handle. For every keysite with registered
-- scenery, read each still-alive handle's getLife(); when life is nil (handle gone) or <= 1 (burned
-- out) the entry is marked dead, health recomputed, and the drop logged. Idempotent and re-injection
-- safe (operates on S.keysites, which persists across re-injects).
function M.poll_scenery(log_fn)
    log_fn = log_fn or function() end
    for kname, rec in pairs(S.keysites or {}) do
        if rec.scenery and #rec.scenery > 0 then
            local dropped = 0
            for _, s in ipairs(rec.scenery) do
                if not s.dead then
                    local ok, life = pcall(function() return s.handle:getLife() end)
                    if (not ok) or life == nil or life <= 1 then
                        s.dead = true
                        dropped = dropped + 1
                    end
                end
            end
            if dropped > 0 then
                recompute_health(rec)
                log_fn(string.format("keysite %s scenery lost: %d destroyed (%d/%d alive, %.0f%%)",
                    rec.label or kname, dropped, rec.alive or 0, rec.total or 0, (rec.health or 0) * 100))
                cs.dbg("installs", "%s scenery poll: %d dropped this pass (%d/%d alive, %.0f%%)",
                    kname, dropped, rec.alive or 0, rec.total or 0, (rec.health or 0) * 100)
            end
        end
    end
end

-- Register the periodic scenery-drain poll. Generation-guarded like every other scheduler (self-cancels
-- on re-inject). Runs on after the win declaration — post-victory the whole sim keeps running (Item 6
-- LITERAL semantics: EECH fc_msgs.c:163 gates only the win re-award; nothing is game_over-gated).
-- Period mirrors the light cadence of the other keysite-attrition scanners; scenery death is
-- coarse-grained so ~25 s is ample.
local SCENERY_POLL_PERIOD = 25
function M.schedule_scenery_poll(log_fn)
    log_fn = log_fn or function() end
    local my_gen = _DMT_GEN
    cs.dbg("installs", "scenery-poll scheduler REGISTERED offset=%.0fs period=%.0fs", SCENERY_POLL_PERIOD, SCENERY_POLL_PERIOD)
    timer.scheduleFunction(function(_, t)
        -- INFRASTRUCTURE: installation scenery-drain poll keeps running post-victory (EECH fc_msgs.c:163). Cluster E.
        if _DMT_GEN ~= my_gen then return nil end
        M.poll_scenery(log_fn)
        return t + SCENERY_POLL_PERIOD
    end, nil, timer.getTime() + SCENERY_POLL_PERIOD)
end

-- ── init: procedurally place installations behind each base ───────────────────
function M.init(log_fn)
    log_fn = log_fn or function() end
    -- Static-death → keysite drain handler (harmless no-op when there are no registered assets).
    M.init_static_death_handler(log_fn)
    -- Zone-authored theatre: REGISTER keysites from the ME zones (spawn nothing).
    if require("zones").has_keysite_zones() then return init_from_zones(log_fn) end
    S.keysites = {}
    local producer = pick_producer_bases()
    local n, np = 0, 0
    for base, owner in pairs(S.base_owner) do
        if owner == coalition.side.BLUE or owner == coalition.side.RED then
            local rear = rear_offset_pos(base, owner)
            if rear then
                -- consumer/target installations at every base; producers only at rear/depth bases
                local loadout = { BASE_LOADOUT[1], BASE_LOADOUT[2], BASE_LOADOUT[3] }
                if producer[base] then
                    for _, k in ipairs(REAR_LOADOUT) do loadout[#loadout + 1] = k end
                end
                local bc = S.base_pos[base]
                for i, kind in ipairs(loadout) do
                    -- fan them in a TIGHT ring so each base's sites cluster into one readable complex;
                    -- snap each ring slot off water (coastal base), fallback = the base centre.
                    local ang = (i - 1) * (2 * math.pi / #loadout)
                    local pos = cs.snap_land(rear.x + math.cos(ang) * 550, rear.z + math.sin(ang) * 550,
                                             bc and bc.x or rear.x, bc and bc.z or rear.z)
                    local kname = string.format("Inst-%s-%s", kind, base)
                    local spawn_kind = spawn_installation(kname, kind, owner, pos)
                    S.keysites[kname] = {
                        home_base = base, kind = kind, pos = pos,
                        health = 1.0, flags = FLAGS[kind], label = KINDS[kind].label,
                        producer = PRODUCER[kind],   -- {ammo,fuel} %/min, or nil for consumers/targets
                        spawn_kind = spawn_kind,     -- "static" | "unit" — how to destroy its object
                    }
                    n = n + 1
                    if PRODUCER[kind] then np = np + 1 end
                end
            end
        end
    end
    log_fn(string.format("installations: %d non-airbase keysites placed (%d producers) [%s]",
        n, np, SPAWN_PHYSICAL and "physical statics + EWR radar units" or "abstract points"))
    cs.dbg("installs", "init (auto/procedural path): %d keysites placed (%d producers)", n, np)
end

-- ── Per-side production capacity (KEYSITE-F5) ─────────────────────────────────
-- Sum of default_supply_usage over all ALIVE, side-owned producer keysites. Returns ammo,fuel in
-- percentage-points-per-minute. Zero once a side's factories/refineries are all destroyed/captured
-- → its consumer keysites stop being restocked and its reserve replacement halts (supply.lua).
function M.production_rates(side)
    local ammo, fuel = 0, 0
    for _, rec in pairs(S.keysites or {}) do
        local p = rec.producer
        -- gate: producing only while healthy AND (for registered keysites) some assets still alive.
        if p and not rec.pending and rec.health > 0.1 and (rec.alive == nil or rec.alive > 0) and M.side_of(rec) == side then
            ammo = ammo + (p.ammo or 0)
            fuel = fuel + (p.fuel or 0)
        end
    end
    return ammo, fuel
end

-- Installation side. Zone-authored keysites carry their own side (rec.side, set by the zone colour);
-- auto-placed installations follow their home base's current owner (captures propagate).
function M.side_of(rec)
    if rec.side then return rec.side end
    return S.base_owner[rec.home_base]
end

-- ── nearest_producer(side, commodity, pos) — supplier selection for a physical supply flight ──────
-- Mirrors fc_msgs.c:759-800 response_to_force_low_on_supplies supplier lookup: for AMMO pick the
-- closest FACTORY (fall back to any producer); for FUEL the closest OIL_REFINERY/PORT (fall back to
-- any producer). This is the PICK_UP keysite (taskgen.c:1638) — the transport routes here first.
-- Only ALIVE + owned producers qualify (same gate as production_rates: the crate physically exists
-- only while its factory stands, so killing the factory kills the resupply too). Returns
-- {name=, pos=} of the nearest qualifying producer, or nil if the side has none alive.
function M.nearest_producer(side, commodity, pos)
    local primary, primary_d2 = nil, math.huge   -- producer that makes THIS commodity (factory/refinery)
    local any, any_d2         = nil, math.huge    -- any live producer (fc_msgs fallback path)
    for kname, rec in pairs(S.keysites or {}) do
        local p = rec.producer
        if p and not rec.pending and rec.health > 0.1 and (rec.alive == nil or rec.alive > 0)
           and M.side_of(rec) == side and rec.pos then
            local d2 = 0
            if pos then local dx, dz = pos.x - rec.pos.x, pos.z - rec.pos.z; d2 = dx*dx + dz*dz end
            if d2 < any_d2 then any_d2 = d2; any = { name = kname, pos = rec.pos } end
            if (p[commodity] or 0) > 0 and d2 < primary_d2 then
                primary_d2 = d2; primary = { name = kname, pos = rec.pos }
            end
        end
    end
    return primary or any
end

-- ── ground_strike targets for `attacker` = enemy installations still standing ─
-- Enumerator (NOT a scorer): returns every enemy ground_strike_target installation still standing.
-- keysite.strike_candidates rates these with the ONE create_keysite_strike_tasks formula
-- (highlevl.c:1093-1127) alongside airbases — the port no longer scores installations with a
-- separate invented table. `recon_target` is surfaced so the funnel's recon-fork can honour the
-- keysite_database row (ks_dbase.c) per site.
function M.strike_targets(attacker)
    local enemy, out = cs.ENEMY[attacker], {}
    for kname, rec in pairs(S.keysites or {}) do
        if rec.flags.ground_strike_target and not rec.pending and rec.health > 0.1 and M.side_of(rec) == enemy then
            out[#out + 1] = { name = kname, pos = rec.pos, health = rec.health, kind = rec.kind,
                              recon_target = rec.flags.recon_target == true }
        end
    end
    return out
end

-- ── Core damage application ───────────────────────────────────────────────────
-- Reduce an installation's health; at ≤ 0.1 it is destroyed (dropped from strike_targets and its
-- visual static removed). This is the single source of truth for installation attrition.
function M.damage(kname, amount, log_fn)
    log_fn = log_fn or function() end
    local rec = S.keysites and S.keysites[kname]
    if not rec then return end

    -- Under-attack notification (keysite.c:854-939 notify_keysite_structure_under_attack): wired for
    -- parity with the airbase strike path. Installation keysites are requires_cap=FALSE (ks_dbase.c)
    -- and carry no base owner, so reaction.on_keysite_under_attack no-ops here (no defensive CAP for a
    -- factory/depot/radar) — faithful: EECH scrambles CAP only for keysites whose row requires it.
    local ok_r, react = pcall(require, "reaction")
    if ok_r and react and react.on_keysite_under_attack then
        pcall(react.on_keysite_under_attack, kname, log_fn)
    end

    -- REGISTERED-ASSET keysite (zone-authored): a strike destroying `amount` of its strength destroys
    -- ceil(amount * total) of the still-alive placed statics; health drains to alive/total. At <=0.1 it
    -- is neutralised/capturable but the record is KEPT (feeds the capture + economy loop).
    if rec.assets then
        if (rec.alive or 0) <= 0 then return end
        local before   = rec.health or 0
        local want      = math.min(math.ceil((amount or KILL_DMG) * rec.total), rec.alive)
        local destroyed = 0
        for _, nm in ipairs(rec.assets) do
            if destroyed >= want then break end
            if not rec.dead[nm] then
                local so = StaticObject.getByName(nm)
                if so then pcall(function() so:destroy() end) end
                rec.dead[nm] = true   -- idempotent with the S_EVENT_DEAD handler
                destroyed = destroyed + 1
            end
        end
        -- Statics exhausted but more destruction still owed → burn registered SCENERY too. Try the
        -- object's destroy() (SceneryObject may not expose one — pcall-guarded); either way mark the
        -- entry dead so health drains, and the getLife poll confirms/backstops it.
        if destroyed < want and rec.scenery then
            for _, s in ipairs(rec.scenery) do
                if destroyed >= want then break end
                if not s.dead then
                    pcall(function() s.handle:destroy() end)
                    s.dead = true
                    destroyed = destroyed + 1
                end
            end
        end
        recompute_health(rec)
        if rec.health > 0.1 then
            log_fn(string.format("keysite %s struck: %.0f%%->%.0f%% (%d/%d statics left)",
                rec.label or kname, before * 100, rec.health * 100, rec.alive, rec.total))
            cs.dbg("installs", "%s damaged: %.0f%%->%.0f%% (%d assets destroyed this hit, %d/%d left)",
                kname, before * 100, rec.health * 100, destroyed, rec.alive, rec.total)
        else
            log_fn(string.format("keysite %s DESTROYED%s (%s) — %d/%d statics, capturable",
                rec.label or kname, rec.producer and " — PRODUCER LOST, supply cut" or "",
                cs.SIDE_NAME[M.side_of(rec)] or "?", rec.alive, rec.total))
            cs.dbg("installs", "%s NEUTRALISED (%.0f%%->%.0f%%)%s owner=%s", kname, before * 100, rec.health * 100,
                rec.producer and " PRODUCER LOST" or "", cs.SIDE_NAME[M.side_of(rec)] or "?")
        end
        return rec.health
    end

    -- AUTO-path keysite (no zones): legacy abstract-health model + single-object destroy.
    if rec.health <= 0.1 then return end
    local before = rec.health
    rec.health = math.max(0, rec.health - (amount or KILL_DMG))
    if rec.health > 0.1 then
        log_fn(string.format("installation struck: %s %.0f%%->%.0f%% (%s)",
            rec.label, before * 100, rec.health * 100, kname))
        cs.dbg("installs", "%s (auto) damaged: %.0f%%->%.0f%%", kname, before * 100, rec.health * 100)
    end
    if rec.health <= 0.1 then
        local owner = M.side_of(rec)
        log_fn(string.format("installation DESTROYED: %s at %s%s (%s)", rec.label, rec.home_base,
            rec.producer and " — PRODUCER LOST, supply cut" or "",
            cs.SIDE_NAME[owner] or "?"))
        cs.dbg("installs", "%s (auto) NEUTRALISED at %s%s owner=%s", kname, rec.home_base,
            rec.producer and " PRODUCER LOST" or "", cs.SIDE_NAME[owner] or "?")
        -- Remove the physical object — a static (via StaticObject) or an EWR unit group (via Group).
        pcall(function()
            if rec.spawn_kind == "unit" then
                local g = Group.getByName(kname)
                if g then g:destroy() end
            else
                local so = StaticObject.getByName(kname)
                if so then so:destroy() end
            end
        end)
    end
    return rec.health
end

-- NOTE: the generic kill-proximity bleed (apply_kill_damage: any kill within KILL_RADIUS of an
-- installation chipped its health) was REMOVED in Cluster G. EECH keysite strength changes only when
-- the keysite's own registered structures die — that path already exists (register_static_death, the
-- S_EVENT_DEAD handler) — so the extra proximity channel double-counted every registered-asset death.
-- Installation attrition is now driven exclusively by (a) the deterministic strike channel (M.damage,
-- called by the strike scheduler at time-on-target) and (b) register_static_death (real structure death).

return M
