-- spawn_test.lua — INTEGRATION TEST: spawn every unit type + payload the campaign uses, in ISOLATION,
-- and report which succeed / fail. Purpose: catch bad type names, missing modules ("Corrupt damage
-- model"), and wrong payload CLSIDs BEFORE they silently break the campaign (e.g. BLUE fielding no
-- Apaches). Attack helis are tested BOTH bare and with their CAP payload, so a pass-bare / fail-loaded
-- result pinpoints a bad CLSID vs a bad/absent airframe.
--
-- Run in the MISSION env:
--   net.dostring_in('server', 'dofile([[C:/Users/jonat/DCSStudio/my-test-mod/Scripts/ee-dcs/test/spawn_test.lua]])')
-- Returns a summary string and logs a full PASS/FAIL table via env.info ("[spawn_test] ...").
-- Each probe spawns, checks existence, then immediately destroys — nothing is left in the world.

local function log(fmt, ...) env.info("[spawn_test] " .. string.format(fmt, ...)) end

-- ── Payload CLSID tables (copied from payloads.lua so this stays self-contained) ─────────────────
local AH64D_CAP = {
    { CLSID = "M261_MK151",                              num = 1 },
    { CLSID = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}", num = 2 },
    { CLSID = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}", num = 3 },
    { CLSID = "M261_MK151",                              num = 4 },
    { CLSID = "{IAFS_ComboPak_100}",                    num = 5 },
    { CLSID = "{AN_APG_78}",                            num = 6 },
}
local MI24V_CAP = {
    { CLSID = "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}", num = 1 },
    { CLSID = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num = 2 },
    { CLSID = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num = 3 },
    { CLSID = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num = 4 },
    { CLSID = "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num = 5 },
    { CLSID = "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}", num = 6 },
}

local USA, RUS = country.id.USA, country.id.RUSSIA

-- ── The full spawn inventory (label, kind, country, type[, payload][, shape]) ─────────────────────
-- kind: "air" | "heli" | "ground" | "static"
local SPECS = {
    -- Fixed-wing (attack_waves.lua / cas_bai_sead.lua / recon.lua / main.lua)
    { "BLUE striker  F-16C",  "air",  USA, "F-16C bl.52d" },
    { "BLUE escort   F-15C",  "air",  USA, "F-15C" },
    { "BLUE CAP tpt  C-130",  "air",  USA, "C-130" },
    { "RED  striker  Su-25T", "air",  RUS, "Su-25T" },
    { "RED  escort   Su-27",  "air",  RUS, "Su-27" },
    { "RED  CAP tpt  IL-76",  "air",  RUS, "IL-76MD" },
    -- Attack helis — BARE (isolates airframe/module) then LOADED (isolates payload CLSIDs)
    { "BLUE atk heli AH-64D  (bare)",   "heli", USA, "AH-64D" },
    { "BLUE atk heli AH-64D  (payload)","heli", USA, "AH-64D", AH64D_CAP },
    { "RED  atk heli Mi-24V  (bare)",   "heli", RUS, "Mi-24V" },
    { "RED  atk heli Mi-24V  (payload)","heli", RUS, "Mi-24V", MI24V_CAP },
    -- Transport / reaction helis (troop.lua / reaction.lua / regen.lua)
    { "BLUE troop heli UH-1H",  "heli", USA, "UH-1H" },
    { "RED  troop heli Mi-8MT", "heli", RUS, "Mi-8MT" },
    -- Ground: garrison (main.lua / installations.lua)
    { "BLUE MBT   M-1 Abrams",   "ground", USA, "M-1 Abrams" },
    { "BLUE IFV   M2A2 Bradley", "ground", USA, "M2A2 Bradley" },
    { "BLUE scout M1043 HMMWV",  "ground", USA, "M1043 HMMWV Armament" },
    { "RED  MBT   T-80UD",       "ground", RUS, "T-80UD" },
    { "RED  IFV   BMP-2",        "ground", RUS, "BMP-2" },
    { "RED  APC   BTR-80",       "ground", RUS, "BTR-80" },
    -- Ground: SP-artillery (ground_forces.lua OOB — Cluster F). UNVERIFIED-IN-LIVE-DB: these probe
    -- the artillery type names the campaign now fields; a FAIL here means the name must be corrected.
    { "BLUE arty  M-109",        "ground", USA, "M-109" },
    { "BLUE MLRS  MLRS (M270)",  "ground", USA, "MLRS" },
    { "RED  arty  SAU Msta",     "ground", RUS, "SAU Msta" },
    { "RED  MLRS  Grad-URAL",    "ground", RUS, "Grad-URAL" },
    -- Ground: FORMCOMP.DAT combined-arms slots (ground_forces.lua PRIMARY_SLOTS/ARTY_SLOTS —
    -- Cluster F realignment). UNVERIFIED-IN-LIVE-DB probes; a FAIL means correct that slot's name.
    { "BLUE APC   M-113",         "ground", USA, "M-113" },          -- FORMCOMP M113A2
    { "BLUE SAM   M48 Chaparral", "ground", USA, "M48 Chaparral" },  -- FORMCOMP M48A1_CHAPARRAL
    { "BLUE truck M 818",         "ground", USA, "M 818" },          -- FORMCOMP M923A1_BIG_FOOT
    { "RED  SHORAD 2S6 Tunguska", "ground", RUS, "2S6 Tunguska" },   -- FORMCOMP SA19_GRISON
    { "RED  IFV   BMP-3",         "ground", RUS, "BMP-3" },          -- FORMCOMP BMP3
    { "RED  SAM   Strela-10M3",   "ground", RUS, "Strela-10M3" },    -- FORMCOMP SA13_GOPHER
    { "RED  truck Ural-375",      "ground", RUS, "Ural-375" },       -- FORMCOMP URAL_4320
    { "RED  scout UAZ-469",       "ground", RUS, "UAZ-469" },        -- FORMCOMP UAZ469B
    -- Ground: air defence (installations.lua / base_defenses.lua)
    { "BLUE AAA   Vulcan",        "ground", USA, "Vulcan" },
    { "BLUE SAM   Roland ADS",    "ground", USA, "Roland ADS" },
    { "BLUE SHORAD M1097 Avenger","ground", USA, "M1097 Avenger" },
    { "BLUE EWR   Hawk sr",       "ground", USA, "Hawk sr" },
    { "RED  AAA   ZSU-23-4",      "ground", RUS, "ZSU-23-4 Shilka" },
    { "RED  SAM   Kub str",       "ground", RUS, "Kub 1S91 str" },
    { "RED  SAM   Kub ln",        "ground", RUS, "Kub 2P25 ln" },
    { "RED  EWR   55G6",          "ground", RUS, "55G6 EWR" },
    -- Statics (installations.lua PALETTE)
    { "static Container", "static", USA, "M92_10Ft_Container", nil, "M92_Container_10ft" },
    { "static Fuel Depot","static", USA, "FARP Fuel Depot",    nil, "GSM Rus" },
    { "static Cmd Center", "static", USA, ".Command Center",   nil, "ComCenter" },
    { "static Boiler",     "static", USA, "Boiler-house A",    nil, "kotelnaya_a" },
}

-- ── Test bed position: first AIRDROME on the map, spread probes on a grid around it ───────────────
local function test_origin()
    for _, ab in ipairs(world.getAirbases() or {}) do
        local ok = pcall(function() return ab:getDesc().category == Airbase.Category.AIRDROME end)
        if ok and ab:getDesc().category == Airbase.Category.AIRDROME then
            return ab:getPosition().p
        end
    end
    return { x = 0, y = 0, z = 0 }
end

-- PHASE 1 — spawn (groups/statics are NOT queryable in the frame they're created in the dostring
-- context, so we only spawn here and record names; verification happens on a deferred timer).
local function spawn_one(spec, ox, oz)
    local kind, cid, utype, payload, shape = spec[2], spec[3], spec[4], spec[5], spec[6]
    local nm = "__st_" .. utype:gsub("[^%w]", "_") .. (payload and "_pl" or "")
    local gy = 0
    pcall(function() gy = land.getHeight({ x = ox, y = oz }) or 0 end)

    if kind == "static" then
        local ok, err = pcall(function()
            coalition.addStaticObject(cid, {
                name = nm, type = utype, shape_name = shape, category = "Fortifications",
                x = ox, y = oz, heading = 0, dead = false,
            })
        end)
        return nm, (ok and "" or tostring(err))
    end

    local cat = (kind == "air") and Group.Category.AIRPLANE
             or (kind == "heli") and Group.Category.HELICOPTER
             or Group.Category.GROUND
    local unit = { name = nm .. "-1", type = utype, skill = "Good", heading = 0, x = ox, y = oz }
    if kind == "air" or kind == "heli" then
        unit.alt = (kind == "air") and (gy + 2000) or (gy + 50)
        unit.alt_type = "BARO"; unit.speed = (kind == "air") and 150 or 30
        if payload then unit.payload = { pylons = payload, fuel = 1000, flare = 30, chaff = 30, gun = 100 } end
    end
    local route = { points = { {
        type = "Turning Point", action = "Turning Point", x = ox, y = oz,
        alt = unit.alt, alt_type = "BARO", speed = unit.speed or 20, ETA = 0, ETA_locked = false,
    } } }
    local ok, err = pcall(function()
        coalition.addGroup(cid, cat, { name = nm, task = "Nothing", hidden = false, units = { unit }, route = route })
    end)
    return nm, (ok and "" or tostring(err))
end

-- Ground units / statics can only spawn on LAND — a coastal test origin (e.g. Batumi) would drop some
-- grid cells in the sea and fail spawns that are actually fine. Nudge each land-bound probe to the
-- nearest LAND/ROAD surface so a FAIL means a genuinely bad type name, not a wet position.
local used = {}
local function land_pos(x, z)
    for r = 0, 14000, 400 do
        for _, a in ipairs({ 0, 45, 90, 135, 180, 225, 270, 315 }) do
            local px, pz = x + r * math.cos(math.rad(a)), z + r * math.sin(math.rad(a))
            local st = land.getSurfaceType({ x = px, y = pz })
            if st == land.SurfaceType.LAND or st == land.SurfaceType.ROAD then
                local clear = true
                for _, u in ipairs(used) do
                    if (px - u.x) ^ 2 + (pz - u.z) ^ 2 < 600 * 600 then clear = false; break end
                end
                if clear then used[#used + 1] = { x = px, z = pz }; return px, pz end
            end
        end
    end
    return x, z
end

local origin = test_origin()
log("=== SPAWN INTEGRATION TEST: %d specs, origin=(%.0f,%.0f) — spawning, verify in 4s ===",
    #SPECS, origin.x, origin.z)
-- Wide spacing (1.5 km grid) so land-nudged ground probes don't collapse onto the same strip and
-- collide — an overlap would fail-spawn a perfectly valid unit and read as a false negative.
local probes = {}
for i, spec in ipairs(SPECS) do
    local ox = origin.x + (i % 6) * 1500
    local oz = origin.z + math.floor(i / 6) * 1500 + 800
    if spec[2] == "ground" or spec[2] == "static" then ox, oz = land_pos(ox, oz) end
    local nm, err = spawn_one(spec, ox, oz)
    probes[#probes + 1] = { name = nm, spec = spec, err = err }
end

-- PHASE 2 — verify after the sim has registered the spawns (deferred one frame-batch later).
timer.scheduleFunction(function()
    local pass, fail = 0, 0
    for _, p in ipairs(probes) do
        local isStatic = (p.spec[2] == "static")
        local live = isStatic and StaticObject.getByName(p.name) or Group.getByName(p.name)
        local ok = (live ~= nil)
        if ok then pass = pass + 1 else fail = fail + 1 end
        local line = string.format("  [%s] %-32s (%s)", ok and "PASS" or "FAIL", p.spec[1], p.spec[4])
        if not ok and p.err ~= "" then line = line .. " spawn-err=" .. p.err:sub(1, 60) end
        log("%s", line)
        if live then pcall(function() live:destroy() end) end
    end
    log("=== RESULT: %d PASS, %d FAIL (of %d) — see lines above ===", pass, fail, #probes)
    return nil
end, nil, timer.getTime() + 4)

return string.format("spawn_test: spawned %d probes; verifying in 4s — read log [spawn_test] for PASS/FAIL", #probes)
