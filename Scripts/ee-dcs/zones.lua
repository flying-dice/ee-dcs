-- zones.lua — read author-placed Mission Editor trigger zones and test points against them.
-- Lets the campaign layout be AUTHORED in the ME (theatre bounds, side ownership, objectives, no-go
-- areas) instead of auto-derived. Supports both CIRCLE and QUAD (box) zones.
--
-- Coordinate mapping: in the mission file, zone geometry uses (x, y) where x = world x (north) and
-- y = world z (east). We normalise to world (x, z).

local cs = require("campaign_state")
local M  = {}

local loaded = {}   -- name(lower) → { name, color, cx, cz, [verts | radius] }

-- Keysite type keywords (first word of a keysite zone's name → keysite type). Mirrors the EECH
-- keysite_database sub-types (ks_dbase.c). Zones whose first word is NOT one of these (e.g. a plain
-- "BLUE"/"RED"/"THEATRE" scoping box) are not keysites and are skipped by keysites()/has_keysite_zones().
local KEYSITE_KINDS = {
    airbase = true, farp = true, factory = true, refinery = true, port = true,
    radar   = true, depot = true, power = true, command = true, fuel = true,
}

-- Leading (lower-cased) LETTERS of a zone name — the keysite type selector. Uses %a+ so a numbered or
-- suffixed name resolves to its type: "airbase-1" / "farp 2" / "factoryEast" all → airbase/farp/factory.
local function first_word(name)
    if not name then return "" end
    return string.lower(string.match(name, "^%s*(%a+)") or "")
end

-- Point-in-polygon (ray casting) for quad/box zones.
local function point_in_poly(px, pz, verts)
    local inside, n = false, #verts
    local j = n
    for i = 1, n do
        local vi, vj = verts[i], verts[j]
        if ((vi.z > pz) ~= (vj.z > pz)) and
           (px < (vj.x - vi.x) * (pz - vi.z) / ((vj.z - vi.z) ~= 0 and (vj.z - vi.z) or 1e-9) + vi.x) then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- Load every ME trigger zone. Call once at init (after the mission is live).
function M.load()
    loaded = {}
    local zs = env.mission and env.mission.triggers and env.mission.triggers.zones
    if not zs then
        cs.dbg("zones", "load: no env.mission.triggers.zones table found -> 0 zones")
        return 0
    end
    local n = 0
    for _, z in ipairs(zs) do
        if z.name then
            local rec
            if z.type == 2 and z.verticies then   -- QUAD / box
                rec = { verts = {} }
                local sx, sz = 0, 0
                for _, v in ipairs(z.verticies) do
                    rec.verts[#rec.verts + 1] = { x = v.x, z = v.y }
                    sx, sz = sx + v.x, sz + v.y
                end
                local nv = math.max(#rec.verts, 1)
                rec.cx, rec.cz = sx / nv, sz / nv    -- centroid = keysite location
            else                                   -- CIRCLE
                rec = { cx = z.x, cz = z.y, radius = z.radius or 0 }
            end
            rec.name  = z.name    -- original name (label + first-word type selector)
            rec.color = z.color   -- {r,g,b,a} 0..1 — sets the side (side_of_color)
            loaded[string.lower(z.name)] = rec
            n = n + 1
        end
    end
    local n_ks = 0
    for _, rec in pairs(loaded) do
        if KEYSITE_KINDS[first_word(rec.name)] then n_ks = n_ks + 1 end
    end
    cs.dbg("zones", "load: %d zones loaded (%d recognised as keysite zones)", n, n_ks)
    return n
end

-- Does a zone with this name exist?
function M.exists(name)
    return loaded[string.lower(name)] ~= nil
end

-- Is world point (wx,wz) inside the named zone?
function M.contains(name, wx, wz)
    local z = loaded[string.lower(name)]
    if not z then return false end
    if z.verts then return point_in_poly(wx, wz, z.verts) end
    return cs.dist2d(wx, wz, z.cx, z.cz) <= (z.radius or 0)
end

-- Names of every author-placed STATIC OBJECT whose position falls inside the named zone (circle or
-- quad). Scans all coalitions (BLUE/RED/NEUTRAL) so a keysite registers every physical asset the
-- author dropped in its circle regardless of the static's coalition. Used by the register-not-spawn
-- keysite layer (installations.lua / keysite.lua) — the campaign REGISTERS these, it spawns nothing.
function M.statics_in_zone(zone_name)
    local out = {}
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL }) do
        local ok, objs = pcall(coalition.getStaticObjects, side)
        if ok and objs then
            for _, so in ipairs(objs) do
                local ok2, p = pcall(function() return so:getPoint() end)
                if ok2 and p and M.contains(zone_name, p.x, p.z) then
                    local ok3, nm = pcall(function() return so:getName() end)
                    if ok3 and nm then out[#out + 1] = nm end
                end
            end
        end
    end
    return out
end

-- ── Destroyable resource SCENERY inside a keysite zone (register-not-spawn) ────
-- The Caucasus airfields ship with a few DESTROYABLE resource scenery objects (fuel-barrel dumps /
-- GSM fuel stations / warehouses). These are author-INDEPENDENT map assets: the campaign REGISTERS
-- them exactly like placed statics so a keysite drains as they burn. Resource scenery is SPARSE
-- (only AIRBASE_BARRELS_01 and PAR_GSM observed live across the test airfields), so the allowlist is
-- EXTENDABLE and backed by a fuel/warehouse/depot pattern fallback.
--
-- Scenery cannot be re-acquired by name (Object.getByName(sceneryName) == nil), so each returned row
-- HOLDS the live handle; installations.lua polls handle:getLife() on that held handle to detect death.
-- Exact Caucasus airbase resource types (upper-cased keys). These are the objects DCS shows with the
-- fuel/warehouse resource icons at an airfield: TOPLIVO-BAK_NEW (fuel tank), AIRBASE_BARRELS_01 (fuel
-- barrels), SKLADIK (warehouse), PAR_GSM (fuel station). NOT SKLAD_NEW — that is the generic civilian
-- warehouse building (dozens across a nearby town), which must not be registered as airbase assets.
M.RESOURCE_SCENERY = {
    ["AIRBASE_BARRELS_01"] = true, ["PAR_GSM"] = true,
    ["TOPLIVO-BAK_NEW"]    = true, ["SKLADIK"] = true,
}

-- True if an (upper-cased) scenery typename names a destroyable resource asset: an explicit allowlist
-- hit, or a fuel/barrel/warehouse/depot/GSM/storage pattern (excluding poles/lights/trees/polys).
local function is_resource_scenery(typename, type_set)
    if not typename then return false end
    local up = string.upper(typename)
    if type_set and type_set[up] then return true end
    if string.find(up, "POLE", 1, true) or string.find(up, "POLY", 1, true)
       or string.find(up, "LIGHT", 1, true) or string.find(up, "TREE", 1, true) then
        return false
    end
    return string.find(up, "FUEL", 1, true) ~= nil
        or string.find(up, "BARREL", 1, true) ~= nil
        or string.find(up, "WARE", 1, true) ~= nil
        or string.find(up, "DEPOT", 1, true) ~= nil
        or string.find(up, "GSM", 1, true) ~= nil
        or string.find(up, "STORAGE", 1, true) ~= nil
        -- TOPLIVO (Russian "fuel") is airbase-specific and safe to pattern-match; SKLAD ("warehouse") is
        -- NOT — SKLAD_NEW is a generic civilian building used map-wide, so it's excluded from the pattern
        -- and only the exact airbase warehouse type (SKLADIK) registers, via the allowlist above.
        or string.find(up, "TOPLIVO", 1, true) ~= nil
end

-- Bounding-sphere radius covering a zone: the circle radius, or (for a quad) the greatest centroid→
-- vertex distance so the sphere fully encloses the box.
local function zone_bounding_radius(z)
    if z.radius and z.radius > 0 then return z.radius end
    local r = 0
    if z.verts then
        for _, v in ipairs(z.verts) do
            local d = cs.dist2d(z.cx, z.cz, v.x, v.z)
            if d > r then r = d end
        end
    end
    return r
end

-- Destroyable resource SCENERY whose position falls inside the named keysite zone. Searches SCENERY
-- over the zone's bounding sphere, keeps only objects whose typename is a resource asset AND whose
-- point is genuinely inside the zone (contains()), and returns one row per object:
--   { id = <getName, a stable numeric map-id string>, type = <typename>, handle = <live object>,
--     life0 = <getLife at registration> }
-- The HANDLE is the drain key: scenery cannot be re-acquired by name, so installations.lua polls
-- handle:getLife() on this held handle. Everything is pcall-guarded. type_set defaults to
-- M.RESOURCE_SCENERY. Spawns nothing — REGISTER-only, mirroring statics_in_zone.
function M.scenery_in_zone(zone_name, type_set)
    local out = {}
    local z = loaded[string.lower(zone_name)]
    if not z then return out end
    type_set = type_set or M.RESOURCE_SCENERY
    local radius = zone_bounding_radius(z)
    if not radius or radius <= 0 then return out end
    local seen = {}
    local volume = {
        id = world.VolumeType.SPHERE,
        params = { point = { x = z.cx, y = 0, z = z.cz }, radius = radius },
    }
    local handler = function(obj)
        pcall(function()
            local tn = obj:getTypeName()
            if not is_resource_scenery(tn, type_set) then return end
            local p = obj:getPoint()
            if not (p and M.contains(zone_name, p.x, p.z)) then return end
            local id = obj:getName()
            if not id or seen[id] then return end
            seen[id] = true
            out[#out + 1] = { id = id, type = tn, handle = obj, life0 = obj:getLife() }
        end)
        return true   -- keep enumerating
    end
    pcall(world.searchObjects, Object.Category.SCENERY, volume, handler)
    return out
end

-- List of loaded zone names (for logging/diagnostics).
function M.names()
    local out = {}
    for k in pairs(loaded) do out[#out + 1] = k end
    return out
end

-- ── Author-placed keysite zones (the zone-based theatre) ───────────────────────
-- Colour sets the side, first word of the name sets the type, centre sets the location.

-- Side from a zone's colour: BLUE if blue-dominant, RED if red-dominant, nil if grey/neutral.
-- Accepts the raw zone table (uses .color) or a bare {r,g,b,a} colour array.
function M.side_of_color(zone_raw)
    local c = zone_raw and (zone_raw.color or zone_raw)
    if type(c) ~= "table" then return nil end
    local r, b = c[1] or 0, c[3] or 0
    if b > r then return coalition.side.BLUE
    elseif r > b then return coalition.side.RED end
    return nil   -- grey / neutral: not assigned to a side
end

-- List of authored keysite zones (call after load()): { type, side, x, z, label } per zone whose
-- first word is a keysite keyword. Plain BLUE/RED/THEATRE scoping boxes are skipped.
function M.keysites()
    local out = {}
    for _, rec in pairs(loaded) do
        local kind = first_word(rec.name)
        if KEYSITE_KINDS[kind] then
            out[#out + 1] = {
                type  = kind,
                side  = M.side_of_color(rec),
                x     = rec.cx,
                z     = rec.cz,
                label = rec.name,
            }
        end
    end
    return out
end

-- True if the author placed any keysite zone (airbase/farp/factory/...). Selects the zone-based
-- theatre over the auto-generation fallback.
function M.has_keysite_zones()
    for _, rec in pairs(loaded) do
        if KEYSITE_KINDS[first_word(rec.name)] then return true end
    end
    return false
end

return M
