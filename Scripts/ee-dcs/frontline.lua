-- frontline.lua
-- EECH source: aphavoc/source/ai/frontl/ai_fline.c
--   create_frontline(force) line 125  — iterates all sectors, marks PRIMARY if check passes
--   check_sector_frontline(side, x, z) line 177 — returns PRIMARY if sector owned by side
--     AND any of its 8 adjacent (3×3 neighbourhood) sectors is owned by a different side
--   recreate_frontline / recreate_side_frontline line 383 — event-driven on capture
-- EECH source: aphavoc/source/ai/highlevl/highlevl.c
--   add_high_level_ai_function(create_frontline, ...) — periodic rebuild
--
-- DCS proxy: EECH operates on a 2D sector grid (SECTOR_SIDE_LENGTH ≈ 4096 m).
-- check_sector_frontline (ai_fline.c:177) marks a sector PRIMARY when it is owned
-- by side X and any of its up-to-8 grid neighbours (3×3 box) is owned by a
-- different side. DCS has no sector grid and no static painted ownership; bases
-- (keysites) are our sector proxies. The faithful analogue of "the next sector
-- over is enemy-owned" is a *topological* adjacency between bases, not a fixed
-- metric radius. We use Gabriel-graph adjacency: base B (side X) is frontline iff
-- it is Gabriel-adjacent to at least one enemy base E, i.e. no third base lies
-- inside the circle whose diameter is the segment B–E. This is parameter-free and
-- mirrors "immediate neighbour of a different side" far better than the old
-- invented 200 km radius (spec 06 §SECTOR-F16 — the port's fixed-km threshold is
-- REFUTED as an EECH constant).
--
-- Recompute cadence (spec 06 §SECTOR-F16): EECH's create_frontline runs ONCE per
-- force at campaign load (parser.c:1369) over STATIC painted ownership and is never
-- recomputed during play (recreate_frontline, ai_fline.c:383, has no callers). The
-- port's ownership is DYNAMIC (bases change hands), so the faithful analogue is:
-- build at load + recompute on each capture event. There is NO periodic (120 s)
-- rebuild in EECH — that was an invention. M.recompute() is the capture hook.
--
-- Also provides:
--   M.get_frontline(side)       — sorted list of frontline base names for side
--   M.nearest_enemy(name)       — {name, distance} of nearest enemy base
--   M.echelon_of(pos)           — "frontline" | "second" CAS/BAI/SEAD echelon of a position
--   M.rebuild() / M.recompute() — recompute all flags (load + on capture)

local cs = require("campaign_state")
local S  = cs.S
local M  = {}

-- ── Internal cache ────────────────────────────────────────────────────────────
-- frontline_flag[side][base_name] = true/false
local frontline_flag = {
    [coalition.side.BLUE] = {},
    [coalition.side.RED]  = {},
}

-- Gabriel-graph adjacency test: are bases a,b adjacent with no other base strictly
-- inside the disk whose diameter is a–b? r is inside that disk iff the angle a-r-b
-- is obtuse, i.e. |a-r|² + |b-r|² < |a-b|². Faithful proxy for "immediate neighbour".
local function gabriel_adjacent(apos, bpos, aname, bname)
    local dx = apos.x - bpos.x
    local dz = apos.z - bpos.z
    local d2 = dx*dx + dz*dz
    if d2 <= 0 then return false end
    for rname, rpos in pairs(S.base_pos) do
        if rname ~= aname and rname ~= bname and S.base_owner[rname] then
            local ax, az = apos.x - rpos.x, apos.z - rpos.z
            local bx, bz = bpos.x - rpos.x, bpos.z - rpos.z
            if (ax*ax + az*az) + (bx*bx + bz*bz) < d2 then
                return false  -- a third base sits between a and b → not immediate neighbours
            end
        end
    end
    return true
end

-- ── rebuild() ─────────────────────────────────────────────────────────────────
-- Mirrors create_frontline() + check_sector_frontline() (ai_fline.c:125,177):
--   For each base owned by side X, it is frontline iff it is Gabriel-adjacent to
--   at least one enemy-owned base (the topological "adjacent enemy sector" rule).
function M.rebuild()
    for _, side in ipairs({ coalition.side.BLUE, coalition.side.RED }) do
        frontline_flag[side] = {}
        local enemy = cs.ENEMY[side]

        for name, owner in pairs(S.base_owner) do
            if owner == side then
                local bpos = S.base_pos[name]
                if bpos then
                    local is_front = false
                    for ename, eowner in pairs(S.base_owner) do
                        if eowner == enemy then
                            local epos = S.base_pos[ename]
                            if epos and gabriel_adjacent(bpos, epos, name, ename) then
                                is_front = true
                                break
                            end
                        end
                    end
                    frontline_flag[side][name] = is_front
                end
            end
        end
    end
    local n_blue, n_red = 0, 0
    for _, f in pairs(frontline_flag[coalition.side.BLUE]) do if f then n_blue = n_blue + 1 end end
    for _, f in pairs(frontline_flag[coalition.side.RED])  do if f then n_red  = n_red  + 1 end end
    cs.dbg("frontline", "rebuild: BLUE frontline=%d bases, RED frontline=%d bases", n_blue, n_red)
end

-- Capture-event hook (spec 06 §SECTOR-F16): recompute the whole frontline after a
-- base changes hands. Coordinator must wire this into the base-capture path (in
-- keysite/win modules — out of this cluster's file scope). Alias of rebuild().
function M.recompute()
    cs.dbg("frontline", "recompute triggered (capture event)")
    M.rebuild()
end

-- ── is_frontline(name, side) ──────────────────────────────────────────────────
-- Returns true if the base is on the frontline for the given side.
function M.is_frontline(name, side)
    return frontline_flag[side] and frontline_flag[side][name] == true
end

-- ── echelon_of(pos) — CAS / BAI / SEAD echelon classifier ─────────────────────
-- EECH splits enemy ground targets between the generators by the STATIC
-- per-group-TYPE flag group_database[sub_type].frontline_flag, surfaced as
-- INT_TYPE_FRONTLINE (gp_int.c:389-392 — it returns the database flag verbatim,
-- it is NOT a sector-distance value). The enum (group.h:199-202) is
-- NONE=0, PRIMARY=1, SECONDARY=2, ARTILLERY=3, so:
--   • create_cas_tasks   keeps groups with FRONTLINE == 1  (highlevl.c:877) → PRIMARY frontline armour
--   • create_bai_tasks   keeps groups with FRONTLINE >  1  (highlevl.c:637) → SECONDARY/support + artillery
--   • create_sead_tasks  keeps AA with !frontline_flag     (highlevl.c:1981) → NONE (rear/site AA, not frontline-attached)
--
-- The port's ground groups are undifferentiated (there is no per-type
-- frontline_flag database — every standing-frontline / garrison group is the same
-- DCS composition), so the only available echelon signal is POSITIONAL: a target
-- in the contact zone stands in for a PRIMARY-frontline group; one deeper in the
-- rear stands in for a SECONDARY/second-line group. A target's echelon is decided
-- by whether its NEAREST owned base (either side) is a Gabriel-frontline base
-- (is_frontline for that base's owner — a base owned by side X and Gabriel-adjacent
-- to an enemy base is by construction frontline for X and its neighbour frontline
-- for the enemy). Returns "frontline" (CAS-eligible) or "second" (BAI/SEAD-eligible).
--
-- CURRENCY: the Gabriel flags are rebuilt at load (init_and_build, game_loop.lua)
-- and on every capture (recompute, keysite.lua). Base ownership is the flags' ONLY
-- input and it changes ONLY on capture, so the flags are always current when read
-- here — no periodic rebuild is needed (matches EECH: create_frontline is not on a
-- timer, ai_fline.c:383 recreate_frontline has no callers).
local function base_is_frontline(name)
    local owner = S.base_owner[name]
    return owner ~= nil and M.is_frontline(name, owner)
end

function M.echelon_of(pos)
    if not pos then return "second" end
    local best, best_d2 = nil, math.huge
    for name, bpos in pairs(S.base_pos) do
        if S.base_owner[name] then
            local dx = pos.x - bpos.x
            local dz = pos.z - bpos.z
            local d2 = dx*dx + dz*dz
            if d2 < best_d2 then best_d2 = d2; best = name end
        end
    end
    if best and base_is_frontline(best) then return "frontline" end
    return "second"
end

-- ── get_frontline(side) ───────────────────────────────────────────────────────
-- Returns a list of base names owned by side that are frontline,
-- sorted ascending by distance to the nearest enemy base (most forward first).
-- Mirrors EECH's frontline sector ordering by proximity.
function M.get_frontline(side)
    local list = {}
    for name, flag in pairs(frontline_flag[side] or {}) do
        if flag then
            local ne = M.nearest_enemy(name)
            list[#list + 1] = { name = name, dist = ne and ne.distance or math.huge }
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    local names = {}
    for _, entry in ipairs(list) do names[#names + 1] = entry.name end
    return names
end

-- ── nearest_enemy(name) ───────────────────────────────────────────────────────
-- Returns {name=string, distance=metres} for the nearest enemy-owned base.
-- Returns nil if no enemy bases exist.
function M.nearest_enemy(name)
    local bpos  = S.base_pos[name]
    local owner = S.base_owner[name]
    if not bpos or not owner then return nil end

    local enemy   = cs.ENEMY[owner]
    local best_d2 = math.huge
    local best_nm = nil

    for ename, eowner in pairs(S.base_owner) do
        if eowner == enemy then
            local epos = S.base_pos[ename]
            if epos then
                local dx = bpos.x - epos.x
                local dz = bpos.z - epos.z
                local d2 = dx*dx + dz*dz
                if d2 < best_d2 then
                    best_d2 = d2
                    best_nm = ename
                end
            end
        end
    end

    if best_nm then
        return { name = best_nm, distance = math.sqrt(best_d2) }
    end
    return nil
end

-- ── init_and_build() ──────────────────────────────────────────────────────────
function M.init_and_build()
    M.rebuild()
end

-- ── Scheduler ─────────────────────────────────────────────────────────────────
-- EECH computes the frontline ONCE at campaign load and never on a timer
-- (spec 06 §SECTOR-F16; recreate_frontline has no callers). The port's dynamic
-- ownership instead recomputes on capture via M.recompute(). This scheduler is
-- therefore intentionally a no-op — retained only so game_loop.lua's call site
-- (frontl.schedule_update) stays valid. The frontline is fresh from init_and_build
-- at load and from recompute() on each capture.
function M.schedule_update(log_fn)
    -- no periodic rebuild (faithful to EECH); frontline is event-driven now.
    cs.dbg("frontline", "schedule_update called: intentional no-op (EECH computes frontline once at " ..
        "load + on capture, not on a timer — see module header)")
end

return M
