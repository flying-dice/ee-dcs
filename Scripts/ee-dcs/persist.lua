-- persist.lua
-- EECH source:
--   aphavoc/source/session/session.c   pack_session / unpack_session — the campaign save/restore
--                                       root: elapsed_time, per-FORCE data, keysite ownership/strength,
--                                       reserve hardware, regen queues, and the mobile OOB are packed to
--                                       a save block and restored on load (SESSION-F15/F16/F17).
--   aphavoc/source/entity/special/force/force.c    force reserve hardware (restored, not respawned).
--   aphavoc/source/entity/special/keysite/keysite.c keysite side/strength/supply (restored).
--
-- WHAT THIS IS: the port's pack_session analog. EECH's process is a single monolithic entity-tree
-- serialize; the DCS port cannot serialize live DCS object handles (Group/StaticObject/scenery are
-- engine userdata that do not survive a process restart), so it saves a PROJECTION of the campaign
-- state singleton S — the subset that is either pure data or reconstructible — and RESPAWNS the mobile
-- OOB from position/count SUMMARIES on restore. Air-defence rings, firing points, patrols, installations
-- and the airbase-asset scenery are re-seeded FRESH by their own init() at boot (exactly as at-boot),
-- then overlaid with saved health; in-flight sorties are NOT restored (they RTB into the void of the old
-- process — EECH likewise does not resurrect airborne missions verbatim, it repacks the task tree which
-- the port drops; unassigned demand regenerates within one generator cycle).
--
-- TRANSPORT: the DCS Studio native bridge (dcs_studio.*), which the mission scripting env can reach and
-- which survives sanitizeModule (CLAUDE.md guardrail: NO os/io/lfs). dcs_studio.file is WRITE-ONLY
-- (write_text/write_json/write_csv/dump — no read fn), so the round-trippable store is dcs_studio.sqlite:
-- one row per slot holding a versioned, self-contained Lua-literal blob produced by the pure-Lua
-- serializer below (chosen over the bridge's JSON so integer coalition.side keys and mixed key types
-- round-trip exactly — JSON would stringify [2]=BLUE).
--
-- RE-INJECTION vs RESTART: a same-process hot re-inject is UNAFFECTED — restore only fires when
-- config.persistence.enabled is true (default FALSE), so all current dev workflows keep working exactly
-- as before. Enable it (DMT_CONFIG.persistence.enabled=true) for a dedicated-server deployment where the
-- campaign must survive a DCS_server.exe restart. See README "Persistence".

local cs     = require("campaign_state")
local config = require("config")
local S      = cs.S
local M      = {}

local SAVE_VERSION = 1

-- ── Bridge access (mission-env reachable dcs_studio native runtime) ───────────────────────────────
-- rawget avoids an undeclared-global finding and a nil-index if the bridge is not present. If it is
-- genuinely absent, EVERY persist entry point no-ops with a single loud warning — the campaign runs
-- unaffected (persistence is best-effort infrastructure, never a spawn-path dependency). We do NOT fall
-- back to io/lfs (CLAUDE.md guardrail — the sanitized mission env has none).
local function bridge()
    return rawget(_G, "dcs_studio")
end

local _warned_no_bridge = false
local function no_bridge()
    local b = bridge()
    if b and b.sqlite then return false end
    if not _warned_no_bridge then
        _warned_no_bridge = true
        env.info("[dmt:persist] dcs_studio bridge (sqlite) NOT reachable from the mission env — "
            .. "persistence DISABLED for this run (no save/restore). Campaign continues normally.")
    end
    return true
end

-- ── Config ────────────────────────────────────────────────────────────────────────────────────────
local function pcfg()
    return (config.C and config.C.persistence) or {}
end
function M.enabled()
    return pcfg().enabled == true
end
local function slot()
    local s = pcfg().slot
    return (type(s) == "string" and #s > 0) and s or "default"
end
local function db_path()
    local p = pcfg().db_path
    return (type(p) == "string" and #p > 0) and p or "dmt_campaign.sqlite"
end
local function autosave_period()
    local n = pcfg().autosave_period
    return (type(n) == "number" and n > 0) and n or 300
end

-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- PURE-LUA SERIALIZER (proven round-trip in Lua 5.1: integer/string keys, floats, nested tables;
-- functions/userdata/threads are assert-skipped so a stray live handle can never abort a save). The
-- output is a self-contained Lua table literal; deserialize is loadstring in an EMPTY sandbox (the blob
-- is our own output — only data literals, no calls — so an empty environment is safe and total).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
local function ser_num(v)
    if v ~= v or v == math.huge or v == -math.huge then return "0" end   -- nan/inf → 0 (never in the subset)
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
        return string.format("%d", v)
    end
    return string.format("%.17g", v)   -- full float precision → exact round-trip
end

local function ser_key(k)
    local tk = type(k)
    if tk == "number" then return "[" .. ser_num(k) .. "]" end
    if tk == "string" then return "[" .. string.format("%q", k) .. "]" end
    return nil   -- non-scalar key → skip the pair
end

local function ser(v)
    local t = type(v)
    if t == "number"  then return ser_num(v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "string"  then return string.format("%q", v) end
    if t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            local tv = type(val)
            if tv == "number" or tv == "boolean" or tv == "string" or tv == "table" then
                local ks = ser_key(k)
                if ks then parts[#parts + 1] = ks .. "=" .. ser(val) end
            end
            -- function/userdata/thread values are assert-skipped (never emitted)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end
M._ser = ser   -- exposed for the standalone round-trip probe

local function deser(str)
    local ld = loadstring or load
    if type(ld) ~= "function" then return nil, "no loadstring/load in this env" end
    local chunk = ld("return " .. str)
    if not chunk then return nil, "parse error" end
    if type(setfenv) == "function" then pcall(setfenv, chunk, {}) end   -- empty sandbox
    local ok, val = pcall(chunk)
    if not ok then return nil, tostring(val) end
    return val
end
M._deser = deser

-- Count leaf fields in a table (save/restore size telemetry).
local function leaf_count(t)
    if type(t) ~= "table" then return 1 end
    local n = 0
    for _, v in pairs(t) do n = n + leaf_count(v) end
    return n
end
local function key_count(t)
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- SNAPSHOT — build the persistable projection of S. Every field decision is documented in the
-- REPORT/README; timer-relative values are stored as AGES (seconds before `now`) and rebased on restore
-- because timer.getTime() resets to 0 on a server restart.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
local BLUE, RED = coalition.side.BLUE, coalition.side.RED

local function group_summary(rec, side, kind)
    local grp = rec.grp
    if not cs.group_is_alive(grp) then return nil end
    local units = grp:getUnits()
    local n = units and #units or 0
    if n <= 0 then return nil end
    local lead
    local u = grp:getUnit(1)
    if u and u:isExist() then
        local p = u:getPosition().p
        lead = { x = p.x, z = p.z }
    end
    if not lead then return nil end
    local ok_name, gname = pcall(function() return grp:getName() end)
    return {
        name        = ok_name and gname or nil,
        side        = side,
        kind        = kind,                 -- "primary" | "arty" | "sec"
        home_base   = rec.home_base,
        target_base = rec.target_base,      -- primary only (nil for arty/sec)
        n_alive     = n,
        want        = rec.want,
        lead        = lead,
    }
end

-- keysite record → handle-stripped snapshot (scenery rows keep {id,type,dead}; NO live handle).
local function keysite_snapshot(rec)
    local scen = {}
    for _, srow in ipairs(rec.scenery or {}) do
        scen[#scen + 1] = { id = srow.id, type = srow.type, dead = srow.dead == true }
    end
    local dead = {}
    for _, dn in ipairs(rec.dead or {}) do dead[#dead + 1] = dn end
    local assets = {}
    for _, an in ipairs(rec.assets or {}) do assets[#assets + 1] = an end
    return {
        kind = rec.kind, side = rec.side, pos = rec.pos, home_base = rec.home_base,
        health = rec.health, total = rec.total, alive = rec.alive,
        label = rec.label, producer = rec.producer, flags = rec.flags,
        assets = assets, dead = dead, scenery = scen,
    }
end

function M.snapshot()
    local now = timer.getTime()
    local d = {}

    -- Session (SESSION.elapsed_time, pack_session): store elapsed so phase continuity survives the
    -- timer reset; game_over/winner so a decided campaign stays decided.
    d.start_elapsed = now - (S.start_time or now)
    d.phase         = S.phase
    d.game_over     = S.game_over == true
    d.winner        = S.winner

    -- Keysite ownership / strength / supply (keysite.c side/strength/ammo/fuel). base_last_strike is
    -- timer-relative → stored as AGE (rebased on restore) so post-restart repair suppression is correct.
    d.base_owner      = S.base_owner
    d.base_health     = S.base_health
    d.base_pos        = S.base_pos
    d.base_kind       = S.base_kind
    d.base_efficiency = S.base_efficiency
    d.base_ammo       = S.base_ammo
    d.base_fuel       = S.base_fuel
    d.base_last_strike_age = {}
    for name, t in pairs(S.base_last_strike or {}) do
        if type(t) == "number" then d.base_last_strike_age[name] = now - t end
    end

    -- Campaign objectives + per-side strength (setup.c objective set; fc_updt.c force_percentage).
    d.objectives = S.objectives
    d.strength   = S.strength

    -- Per-base idle ledger + production accumulator incl. earmarks (force reserve hardware).
    d.base_ledger = S.base_ledger
    d.production  = S.production

    -- Regen queues (rg_updt.c). enqueued is timer-relative → store AGE, rebase on restore.
    d.regen_queue = {}
    for side, byt in pairs(S.regen_queue or {}) do
        d.regen_queue[side] = {}
        for atype, q in pairs(byt) do
            local out = {}
            for _, e in ipairs(q) do
                out[#out + 1] = { base_name = e.base_name, aircraft_type = e.aircraft_type,
                                  age = now - (e.enqueued or now) }
            end
            d.regen_queue[side][atype] = out
        end
    end

    -- Fog of war (sector.c fog values) + pilot career records (player.h).
    d.fow    = S.fow
    d.pilots = S.pilots

    -- Per-side campaign stats (F2 — force.h:98-99 kills[]/losses[] live in the packed FORCE entity, so
    -- they survive an EECH session repack; plain counters, saved alongside pilots).
    d.stats = S.stats

    -- Keysites (installations + airbase-asset clusters), handles stripped.
    d.keysites = {}
    for name, rec in pairs(S.keysites or {}) do
        d.keysites[name] = keysite_snapshot(rec)
    end

    -- Mobile OOB → position/count summaries for respawn (the DCS analog of pack_session's mobile tree).
    d.ground = {}
    local function add_reg(reg, kind)
        for side, groups in pairs(reg or {}) do
            for _, rec in pairs(groups) do
                local s = group_summary(rec, side, kind)
                if s then d.ground[#d.ground + 1] = s end
            end
        end
    end
    add_reg(S.ground_groups, "primary")
    add_reg(S.arty_groups,   "arty")
    add_reg(S.sec_groups,    "sec")

    -- DELIBERATELY DROPPED (documented): board_tasks/active_tasks (reference live builders/groups —
    -- unassigned demand regenerates within one generator cycle), base_inflight/group_launch_base
    -- (in-flight not restored), counter_battery (TTL'd), supply_delivered (per-flight), pending_captures
    -- (keyed by group names that don't survive respawn), base_warehouse (re-read at boot),
    -- base_ad_groups/base_fp_groups/patrol_groups (live handles, re-seeded fresh by their init),
    -- farp_active (F1: RECOMPUTED at boot against the restored ownership — game_loop re-runs
    -- farps.seed_activation after restore_data, exactly as EECH re-runs initialise_keysite_farp_enable
    -- at campaign setup, keysite.c:507-568; persisting the latch would freeze stale over-activation).

    return { version = SAVE_VERSION, saved_t = now, data = d }
end

-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- SAVE
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
function M.save(log_fn)
    log_fn = log_fn or function() end
    if not M.enabled() then return false end
    if no_bridge() then return false end

    local ok_snap, envelope = pcall(M.snapshot)
    if not ok_snap then
        log_fn("[persist] snapshot FAILED: " .. tostring(envelope))
        cs.dbg("persist", "snapshot error: %s", tostring(envelope))
        return false
    end
    local ok_ser, blob_raw = pcall(ser, envelope)
    if not ok_ser or type(blob_raw) ~= "string" then
        log_fn("[persist] serialize FAILED: " .. tostring(blob_raw))
        cs.dbg("persist", "serialize error: %s", tostring(blob_raw))
        return false
    end
    local blob = tostring(blob_raw)   -- definite string (analyzer does not narrow a pcall union)
    local blob_len = #blob

    local b = bridge()
    local db, oerr = b.sqlite.open(db_path())
    if not db then
        log_fn("[persist] sqlite.open FAILED: " .. tostring(oerr))
        cs.dbg("persist", "sqlite.open error: %s", tostring(oerr))
        return false
    end

    local ok_w = pcall(function()
        db:exec("CREATE TABLE IF NOT EXISTS campaign_save "
            .. "(slot TEXT PRIMARY KEY, version INTEGER, saved_t REAL, blob TEXT)")
        db:exec("INSERT OR REPLACE INTO campaign_save (slot, version, saved_t, blob) VALUES (?, ?, ?, ?)",
            { slot(), SAVE_VERSION, envelope.saved_t, blob })
    end)
    pcall(function() db:close() end)

    if not ok_w then
        log_fn("[persist] sqlite write FAILED")
        cs.dbg("persist", "sqlite write error")
        return false
    end

    local d = envelope.data
    local n_ground = (type(d.ground) == "table") and #d.ground or 0
    log_fn(string.format("[persist] saved slot=%q (%d bytes, %d fields)", slot(), blob_len, leaf_count(d)))
    cs.dbg("persist", "SAVE slot=%s bytes=%d fields=%d | bases=%d keysites=%d ground=%d pilots=%d regen_q=%d",
        slot(), blob_len, leaf_count(d), key_count(d.base_owner), key_count(d.keysites),
        n_ground, key_count(d.pilots), key_count(d.regen_queue))
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- LOAD (raw) — read + deserialize the slot's blob; returns the envelope table or nil.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
local function load_envelope(log_fn)
    if no_bridge() then return nil end
    local b = bridge()
    local db, oerr = b.sqlite.open(db_path())
    if not db then
        cs.dbg("persist", "restore sqlite.open error: %s", tostring(oerr))
        return nil
    end
    local rows
    pcall(function()
        db:exec("CREATE TABLE IF NOT EXISTS campaign_save "
            .. "(slot TEXT PRIMARY KEY, version INTEGER, saved_t REAL, blob TEXT)")
        rows = db:query("SELECT blob, version, saved_t FROM campaign_save WHERE slot = ?", { slot() })
    end)
    pcall(function() db:close() end)

    if type(rows) ~= "table" or not rows[1] or type(rows[1].blob) ~= "string" then
        cs.dbg("persist", "restore: no save row for slot=%s", slot())
        return nil
    end
    local env_tbl, derr = deser(rows[1].blob)
    if type(env_tbl) ~= "table" or type(env_tbl.data) ~= "table" then
        (log_fn or env.info)("[persist] restore: deserialize FAILED: " .. tostring(derr))
        cs.dbg("persist", "restore deserialize error: %s", tostring(derr))
        return nil
    end
    if env_tbl.version ~= SAVE_VERSION then
        cs.dbg("persist", "restore: version mismatch (save=%s expected=%d) — ignoring",
            tostring(env_tbl.version), SAVE_VERSION)
        return nil
    end
    return env_tbl
end

-- Module-local carry between the two restore phases (data overlay early, world overlay late).
local _restored = false
local _data = nil

function M.was_restored() return _restored end

-- ── PHASE A: data overlay (call AFTER world discovery + all *.init that seed data tables, BEFORE
-- ground OOB spawn). Overlays the pure-data subset onto the freshly-initialised S so later init that
-- READS ownership (installations, AD rings) sees the restored map. Returns true if a save was applied.
function M.restore_data(log_fn)
    log_fn = log_fn or function() end
    _restored = false
    _data = nil
    if not M.enabled() then
        cs.dbg("persist", "restore_data: persistence disabled (config) — fresh OOB")
        return false
    end
    local envelope = load_envelope(log_fn)
    if not envelope then return false end
    local d = envelope.data
    local now = timer.getTime()

    -- Session
    S.start_time = now - (tonumber(d.start_elapsed) or 0)
    if type(d.phase) == "string" then S.phase = d.phase end
    S.game_over = d.game_over == true
    S.winner    = d.winner

    -- Keysite ownership / strength / supply (whole-table overlay — base names are stable DCS airbase
    -- names, so keys line up with the freshly-discovered registry).
    local function overlay(dst_name, src)
        if type(src) == "table" then S[dst_name] = src end
    end
    overlay("base_owner", d.base_owner)
    overlay("base_health", d.base_health)
    overlay("base_pos", d.base_pos)
    overlay("base_kind", d.base_kind)
    overlay("base_efficiency", d.base_efficiency)
    overlay("base_ammo", d.base_ammo)
    overlay("base_fuel", d.base_fuel)
    overlay("objectives", d.objectives)
    overlay("strength", d.strength)
    overlay("base_ledger", d.base_ledger)
    overlay("production", d.production)
    overlay("fow", d.fow)
    overlay("pilots", d.pilots)
    overlay("stats", d.stats)   -- F2: per-side kill/loss/task/sortie stats (absent in older saves → fresh zeros kept)

    -- base_last_strike: rebase AGE → absolute in the new timeline (now - age).
    S.base_last_strike = {}
    for name, age in pairs(d.base_last_strike_age or {}) do
        if type(age) == "number" then S.base_last_strike[name] = now - age end
    end

    -- Regen queues: rebase each entry's enqueued time (now - age).
    if type(d.regen_queue) == "table" then
        local rq = {}
        for side, byt in pairs(d.regen_queue) do
            rq[side] = {}
            for atype, q in pairs(byt) do
                local out = {}
                for _, e in ipairs(q) do
                    out[#out + 1] = { base_name = e.base_name, aircraft_type = e.aircraft_type,
                                      enqueued = now - (tonumber(e.age) or 0) }
                end
                rq[side][atype] = out
            end
        end
        S.regen_queue = rq
    end

    -- In-flight sorties are NOT restored (their DCS groups died with the old process): zero the slot
    -- ledger so no base is falsely at capacity, and clear the launch-base map.
    S.base_inflight     = {}
    S.group_launch_base = {}

    _restored = true
    _data = d
    log_fn(string.format("[persist] restore: applied slot=%q (saved %.0fs of campaign elapsed)",
        slot(), tonumber(d.start_elapsed) or 0))
    cs.dbg("persist", "RESTORE(data) slot=%s: bases=%d ledger-bases=%d regen_q=%d pilots=%d fow=%d strength B/R=%d/%d game_over=%s",
        slot(), key_count(d.base_owner), key_count(d.base_ledger), key_count(d.regen_queue),
        key_count(d.pilots), key_count(d.fow), S.strength[BLUE] or 0, S.strength[RED] or 0,
        tostring(S.game_over))
    return true
end

-- ── PHASE B: world overlay (call AFTER installations.init + base_defenses.init + pilots.init, BEFORE
-- schedulers). Overlays saved keysite health/dead onto the freshly-seeded keysite records, re-kills
-- saved-dead author statics by name, and respawns the mobile OOB from summaries.
function M.restore_world(log_fn)
    log_fn = log_fn or function() end
    if not _restored or type(_data) ~= "table" then return end
    local d = _data

    -- Keysite records (installations + airbase-asset clusters): overlay health/alive/dead so a keysite
    -- damaged last session is still damaged. Scenery handles cannot be re-acquired by name (journal:
    -- not re-acquirable) — the keysite's health is count-derived, so restoring alive/health + the
    -- per-row dead flags is sufficient; register_static_death arithmetic reads the counts, not handles.
    local n_ks, n_rekill = 0, 0
    for name, snap in pairs(d.keysites or {}) do
        local rec = S.keysites and S.keysites[name]
        if rec then
            rec.health = snap.health
            rec.alive  = snap.alive
            rec.total  = snap.total or rec.total
            rec.side   = snap.side or rec.side
            -- dead author-static NAME list: re-kill each (StaticObject.getByName → destroy) so the
            -- physical world matches the saved keysite health. pcall-guarded; a missing static is a no-op.
            -- BEST-EFFORT: author-placed statics (loaded with the .miz) are present now and ARE re-killed;
            -- campaign-spawned template statics (Inst-*) are still in the spawn_queue at this point (drains
            -- after game_loop.start), so their re-kill is a no-op here. Keysite health is already restored
            -- numerically above and is event-incremental (register_static_death), so correctness holds
            -- regardless — this loop only reconciles the VISIBLE static set, not the health value.
            rec.dead = {}
            for _, dn in ipairs(snap.dead or {}) do
                rec.dead[#rec.dead + 1] = dn
                local ok_s, so = pcall(StaticObject.getByName, dn)
                if ok_s and so then
                    if pcall(function() so:destroy() end) then n_rekill = n_rekill + 1 end
                end
            end
            -- Scenery dead flags (handles stay whatever init re-acquired; only the dead marker matters
            -- for the count-based health that installations.lua already restored above).
            if type(rec.scenery) == "table" and type(snap.scenery) == "table" then
                local by_id = {}
                for _, srow in ipairs(snap.scenery) do by_id[tostring(srow.id)] = srow.dead == true end
                for _, srow in ipairs(rec.scenery) do
                    local sd = by_id[tostring(srow.id)]
                    if sd ~= nil then srow.dead = sd end
                end
            end
            n_ks = n_ks + 1
        else
            cs.dbg("persist", "restore_world: saved keysite %s has no fresh record (placement drift) — skipped", name)
        end
    end

    -- Respawn the mobile OOB (primary/arty/sec) from summaries — reserve-neutral (the restored
    -- base_ledger already reflects these groups' original consumption).
    local ground = (type(d.ground) == "table") and d.ground or {}
    local n_ground = #ground
    local ok_g, gnd = pcall(require, "ground_forces")
    local n_resp = 0
    if ok_g and gnd and gnd.respawn_saved then
        for _, summ in ipairs(ground) do
            if pcall(gnd.respawn_saved, summ, log_fn) then n_resp = n_resp + 1 end
        end
    else
        cs.dbg("persist", "restore_world: ground_forces.respawn_saved unavailable — mobile OOB NOT restored")
    end

    log_fn(string.format("[persist] restore(world): %d keysite(s) overlaid, %d dead static(s) re-killed, %d ground group(s) respawned",
        n_ks, n_rekill, n_resp))
    cs.dbg("persist", "RESTORE(world): keysites=%d rekilled=%d ground_respawned=%d/%d",
        n_ks, n_rekill, n_resp, n_ground)
end

-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
-- AUTOSAVE SCHEDULER (mirrors EECH's periodic session repack). Registered from game_loop only when
-- persistence is enabled; gen-guarded like every other campaign timer.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════════
function M.schedule(log_fn)
    log_fn = log_fn or function() end
    if not M.enabled() then
        cs.dbg("persist", "autosave NOT scheduled (persistence disabled)")
        return
    end
    if no_bridge() then return end
    local period = autosave_period()
    local my_gen = _DMT_GEN
    cs.dbg("persist", "autosave scheduler REGISTERED period=%.0fs slot=%s db=%s", period, slot(), db_path())
    timer.scheduleFunction(function(_, t)
        if _DMT_GEN ~= my_gen then return nil end   -- re-injection guard
        local ok, err = pcall(M.save, log_fn)
        if not ok then
            log_fn("[persist] autosave error: " .. tostring(err))
            cs.dbg("persist", "autosave tick error: %s", tostring(err))
        end
        return t + period
    end, nil, timer.getTime() + period)
end

return M
