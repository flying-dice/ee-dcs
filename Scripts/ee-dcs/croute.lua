-- croute.lua
-- Inspired by:
--   aphavoc/source/ai/taskgen/croute.c   BIASED ROUTE GENERATOR — the whole file.
--     route_biasing_database[MOVEMENT_TYPE_AIR]  (croute.c:126-135)  the AIR profile constants
--     create_route / generate_best_mid_point     (croute.c:1242-1309) recursive perpendicular search
--     get_best_point                             (croute.c:1315-1458) sample the perpendicular sweep
--     get_route_point_rating                     (croute.c:1502-1553) elevation + range + side cost
--     second_past_route                          (croute.c:1464-1496) one smoothing re-optimise pass
--     optimise_route                             (croute.c:1559-1669) prune near-colinear nodes
--     generate_biased_vec3d_route                (croute.c:1132-1236) per-leg driver + stitch
--
-- WHY: EECH does NOT fly straight lines between keysites. Every AI air/heli group's route is run
-- through this biased generator, which recursively drops nav nodes onto the LOWEST terrain, nearest
-- OWN territory, near the leg centreline — i.e. valley-following, enemy-sector-avoiding, dispersed
-- routes. The port previously flew depart->target->RTB as three points (a straight "kill corridor");
-- this module reproduces the EECH algorithm so every builder's legs bend through cover.
--
-- SCOPE: this module is PURE route geometry (no spawning, no DCS group calls). `M.biased_route`
-- ports create_route+second_past_route+optimise_route for ONE leg; `M.expand` walks a DCS `points`
-- list and stitches biased nav points between consecutive waypoints (the generate_biased_vec3d_route
-- multi-leg loop). All airborne movement is MOVEMENT_TYPE_AIR in EECH (group_database movement_type
-- for aircraft/helicopters), so there is a single profile — no config, no scenario data: these are
-- EECH C constants, cited above.
--
-- PORT DEVIATIONS (documented, not invented):
--  * sector_side proxy: EECH reads get_local_sector_entity(test_point)->SECTOR_SIDE (croute.c:1534-1536)
--    off its fine authored sector grid. The port has no sector grid — bases ARE the sectors (the same
--    convention campaign_state.route_difficulty uses, task.c:876). So sector_side(test_point) = owner of
--    the NEAREST base. nil owner (no base / unowned) -> treated as NOT own side (biased against), per spec.
--  * elevation: EECH get_3d_terrain_elevation (croute.c:1389) -> DCS pcall(land.getHeight,{x,y=z}); a
--    failed/out-of-map probe defaults to 0 (then max(avg,0), matching croute.c:1526). Memoised per
--    biased_route call (quantised key) to bound land.getHeight to ~one probe per distinct sample point.
--  * hard recursion depth cap (DEPTH_CAP): min_route_range (5000 m, croute.c:1347) is the REAL
--    terminator — a leg subdivides until each half is <= 5 km. The depth cap is only a safety bound so a
--    pathological/degenerate leg can never recurse unboundedly; at 5 km termination a 100 km leg reaches
--    depth ~5, so DEPTH_CAP=6 is never the binding limit on real routes.
--  * nav points are NOT land-snapped: they are flown at cruise altitude (nav waypoints), so they may sit
--    over water/steep ground exactly as EECH's do (EECH never snaps nav nodes either; only the elevation
--    RATING cares about terrain height).
--  * per-leg nav cap (MAX_NAV_PER_LEG): a DCS route table safety cap (DCS is fine to ~20 points/route;
--    we keep <=8 inserted nav points per leg after the optimise prune). Not an EECH constant; on real
--    legs the colinear prune already yields ~3-8, so this only guards degenerate long legs.

local cs = require("campaign_state")
local S  = cs.S
local M  = {}

-- ── AIR movement profile (croute.c:126-135, route_biasing_database[MOVEMENT_TYPE_AIR]) ───────────
local ELEVATION_BIAS   = 5.0      -- elevation bias   (croute.c:128)
local RANGE_BIAS       = 0.5      -- range bias       (croute.c:129)
local SIDE_BIAS        = 1.0      -- side bias        (croute.c:130)
local MIN_ROUTE_RANGE  = 5000.0   -- min route range  (croute.c:131) — legs at/under this are not split
local DEVIATION_SIZE   = 3.0      -- route deviation size (croute.c:132)
local NUM_SAMPLES      = 8        -- num route samples   (croute.c:133)
local OPT_TOLERANCE    = 0.94     -- optimise tolerance  (croute.c:134) — |cos angle| above this = colinear

local DEPTH_CAP        = 6        -- safety bound (see header); min_route_range is the real terminator
local MAX_NAV_PER_LEG  = 8        -- DCS route-table safety cap on inserted nav points per leg (see header)

-- ── sector_side proxy: owner of the nearest base to a test point ─────────────────────────────────
-- Mirrors get_local_sector_entity(test_point)->INT_TYPE_SECTOR_SIDE (croute.c:1534-1536) onto the
-- port's bases-as-sectors grid (same nearest-base scan as campaign_state.route_difficulty). Returns the
-- coalition side owning the nearest base, or nil when none is found / it is unowned.
local function sector_side(x, z)
    local best, best_d2 = nil, math.huge
    for name, bpos in pairs(S.base_pos) do
        local dx, dz = x - bpos.x, z - bpos.z
        local d2 = dx * dx + dz * dz
        if d2 < best_d2 then best_d2 = d2; best = name end
    end
    if not best then return nil end
    return S.base_owner[best]   -- may be nil (unowned) -> caller treats nil as NOT own side
end

-- ── biased_route(start_pos, end_pos, side) ──────────────────────────────────────────────────────
-- Ports create_route -> generate_best_mid_point (recursive), then second_past_route, then
-- optimise_route for ONE leg. start_pos/end_pos are world { x = north, z = east }. Returns an array of
-- intermediate nav points { {x=,z=}, ... } in world coords (EXCLUDING the two endpoints, which the
-- caller already has as real waypoints). Possibly empty for legs at/under MIN_ROUTE_RANGE.
function M.biased_route(start_pos, end_pos, side)
    -- per-call terrain memo: quantise to 1 m so identical sample points reuse one land.getHeight probe
    local elev_cache = {}
    local function terrain_h(x, z)
        local kx, kz = math.floor(x + 0.5), math.floor(z + 0.5)
        local key = kx * 100000 + kz
        local h = elev_cache[key]
        if h == nil then
            local ok, v = pcall(land.getHeight, { x = x, y = z })
            h = (ok and type(v) == "number") and v or 0.0
            elev_cache[key] = h
        end
        return h
    end

    -- get_route_point_rating (croute.c:1502-1553). `elev` is the 1..NUM_SAMPLES perpendicular elevation
    -- window; sample_number is 1-based. LOWER rating wins (low terrain + own side + near centreline).
    local function point_rating(sample_number, x, z, elev)
        -- 3-sample averaging window, clamped to [1, NUM_SAMPLES] (croute.c:1520-1524)
        local lo = math.max(sample_number - 1, 1)
        local hi = math.min(sample_number + 1, NUM_SAMPLES)
        local avg = (elev[sample_number] + elev[lo] + elev[hi]) / 3.0
        if avg < 0.0 then avg = 0.0 end                          -- max(avg,0) (croute.c:1526)
        local elevation = ELEVATION_BIAS * avg                   -- croute.c:1528
        -- range bias: |2s - N| / (2N) — minimised near the centre sample (croute.c:1530-1532)
        local range_bias = RANGE_BIAS * math.abs((2.0 * sample_number) - NUM_SAMPLES) / (NUM_SAMPLES * 2.0)
        local ss = sector_side(x, z)                             -- croute.c:1534-1536
        local side_bias = (ss ~= side) and SIDE_BIAS or 0.0      -- (sector_side != side) (croute.c:1538)
        local w = (avg > 1.0) and avg or 1.0                     -- max(avg,1.0) (croute.c:1541-1542)
        return elevation + (range_bias * w) + (side_bias * w)    -- croute.c:1540-1542
    end

    -- get_best_point (croute.c:1315-1458). Returns {x=,z=} of the lowest-rated perpendicular sample, or
    -- nil when the leg is at/under MIN_ROUTE_RANGE (no midpoint — the recursion terminator).
    local function get_best_point(ax, az, bx, bz)
        local dx, dz = bx - ax, bz - az
        local sqr = dx * dx + dz * dz
        if sqr <= (MIN_ROUTE_RANGE * MIN_ROUTE_RANGE) then return nil end   -- croute.c:1347

        -- perpendicular to the leg (croute.c:1350-1356)
        local test_x = dz
        local test_z = -dx
        -- per-sample increment along the perpendicular (croute.c:1359-1360)
        local inc_x = test_x / (NUM_SAMPLES * DEVIATION_SIZE)
        local inc_z = test_z / (NUM_SAMPLES * DEVIATION_SIZE)
        -- leg mid point (croute.c:1363-1365)
        local mid_x = ax + dx * 0.5
        local mid_z = az + dz * 0.5
        -- first sample position: mid - inc*(NUM_SAMPLES*0.5) (croute.c:1368-1369) => offsets -4..+3 inc
        local sx = mid_x - inc_x * (NUM_SAMPLES * 0.5)
        local sz = mid_z - inc_z * (NUM_SAMPLES * 0.5)

        -- gather terrain elevations across the sweep, index 1..NUM_SAMPLES (croute.c:1376-1398)
        local elev = {}
        local tx, tz = sx, sz
        for i = 1, NUM_SAMPLES do
            elev[i] = terrain_h(tx, tz)
            tx = tx + inc_x
            tz = tz + inc_z
        end

        -- rate each sample, keep the lowest (croute.c:1400-1439)
        tx, tz = sx, sz
        local best_rating = point_rating(1, tx, tz, elev)
        local best_x, best_z = tx, tz
        for i = 1, NUM_SAMPLES - 1 do            -- loop 1..N-1, rating sample_number i+1 (2..N)
            tx = tx + inc_x
            tz = tz + inc_z
            local r = point_rating(i + 1, tx, tz, elev)
            if r < best_rating then
                best_rating = r
                best_x, best_z = tx, tz
            end
        end
        return { x = best_x, z = best_z }
    end

    -- build the node list: {start, interior..., end}. generate_best_mid_point recursion (croute.c:1275).
    local nodes = { { x = start_pos.x, z = start_pos.z } }
    local generated = 0

    local function subdivide(ax, az, bx, bz, depth)
        if depth >= DEPTH_CAP then return end            -- safety bound (min_route_range is the real stop)
        local mid = get_best_point(ax, az, bx, bz)
        if not mid then return end                       -- leg <= MIN_ROUTE_RANGE: no midpoint
        subdivide(ax, az, mid.x, mid.z, depth + 1)       -- recurse first half (croute.c:1301)
        nodes[#nodes + 1] = mid
        generated = generated + 1
        subdivide(mid.x, mid.z, bx, bz, depth + 1)        -- recurse second half (croute.c:1303)
    end

    subdivide(start_pos.x, start_pos.z, end_pos.x, end_pos.z, 0)
    nodes[#nodes + 1] = { x = end_pos.x, z = end_pos.z }

    -- second_past_route (croute.c:1464-1496): one forward smoothing pass — re-solve each interior node
    -- against its (already-updated) neighbours. C ignores get_best_point's return; if it fails (a short
    -- prev->next span) C would read an uninitialised best_point — the port instead leaves the node put
    -- (the only sane reading of that latent C bug).
    for i = 2, #nodes - 1 do
        local prev, nxt = nodes[i - 1], nodes[i + 1]
        local mid = get_best_point(prev.x, prev.z, nxt.x, nxt.z)
        if mid then nodes[i] = mid end
    end

    -- optimise_route (croute.c:1559-1669): drop interior nodes that are (near-)colinear with their
    -- neighbours — |cos(angle between the two normalised leg vectors)| > OPT_TOLERANCE, or a zero leg.
    local i = 2
    while i <= #nodes - 1 do
        local prev, node, nxt = nodes[i - 1], nodes[i], nodes[i + 1]
        local v1x, v1z = node.x - prev.x, node.z - prev.z
        local v2x, v2z = nxt.x - node.x, nxt.z - node.z
        local remove = false
        local l1 = v1x * v1x + v1z * v1z
        local l2 = v2x * v2x + v2z * v2z
        if l1 == 0.0 or l2 == 0.0 then
            remove = true                                 -- zero leg (croute.c:1589-1605)
        else
            local n1 = 1.0 / math.sqrt(l1)
            local n2 = 1.0 / math.sqrt(l2)
            local cos = (v1x * n1) * (v2x * n2) + (v1z * n1) * (v2z * n2)   -- dot of normalised (croute.c:1624)
            if math.abs(cos) > OPT_TOLERANCE then remove = true end          -- croute.c:1626
        end
        if remove then
            table.remove(nodes, i)                        -- delete node; re-test at same index
        else
            i = i + 1
        end
    end

    -- collect interior nodes (exclude the two endpoints) as the biased nav points
    local nav = {}
    for k = 2, #nodes - 1 do
        nav[#nav + 1] = { x = nodes[k].x, z = nodes[k].z }
    end

    -- DCS route-table safety cap: keep <= MAX_NAV_PER_LEG (even subsample to preserve spread). See header.
    if #nav > MAX_NAV_PER_LEG then
        local trimmed = {}
        local step = #nav / MAX_NAV_PER_LEG
        for k = 1, MAX_NAV_PER_LEG do
            trimmed[k] = nav[math.min(#nav, math.floor((k - 0.5) * step) + 1)]
        end
        nav = trimmed
    end

    local leg_km = math.sqrt((end_pos.x - start_pos.x) ^ 2 + (end_pos.z - start_pos.z) ^ 2) / 1000.0
    cs.dbg("croute", "leg %.1fkm: %d node(s) generated, %d after prune/cap", leg_km, generated, #nav)
    return nav
end

-- ── expand(points, side, opts) ──────────────────────────────────────────────────────────────────
-- Ports the generate_biased_vec3d_route multi-leg loop (croute.c:1153-1229) onto a DCS `route.points`
-- list: for every consecutive pair of waypoints, insert the biased nav points between them as
-- "Turning Point" waypoints. `points` waypoints carry DCS coords (x=north, y=east); world pos of a
-- waypoint is { x = wp.x, z = wp.y }. Inserted nav points fly at opts.alt / opts.speed / opts.alt_type
-- (the group's cruise leg altitude/speed — EECH gives every generated nav node the member cruise
-- altitude, croute.c:690). Returns a NEW points array (endpoints preserved, nav spliced between).
--   opts = { alt=<m>, alt_type="BARO"|"RADIO", speed=<m/s>, name=<prefix> }
function M.expand(points, side, opts)
    if type(points) ~= "table" or #points < 2 then return points end
    opts = opts or {}
    local alt      = opts.alt or 3000
    local alt_type = opts.alt_type or "BARO"
    local speed    = opts.speed or 200
    local prefix   = opts.name or "Nav"

    local out = {}
    local seq = 0
    for i = 1, #points - 1 do
        out[#out + 1] = points[i]
        local a = { x = points[i].x,     z = points[i].y }
        local b = { x = points[i + 1].x, z = points[i + 1].y }
        local nav = M.biased_route(a, b, side)
        for j = 1, #nav do
            seq = seq + 1
            out[#out + 1] = {
                type = "Turning Point", action = "Turning Point",
                alt = alt, alt_type = alt_type, speed = speed,
                ETA = 0, ETA_locked = false,
                x = nav[j].x, y = nav[j].z,
                name = prefix .. seq, formation_template = "",
            }
        end
    end
    out[#out + 1] = points[#points]
    return out
end

return M
