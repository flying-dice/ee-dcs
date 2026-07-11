-- config.lua — SCENARIO-DATA configuration loader (the port's "warzone data file").
--
-- WHAT THIS IS (and is NOT):
--   EECH itself splits its campaign into two layers: hard ENGINE CONSTANTS compiled into the C source
--   (cadences, formulas, thresholds — highlevl.c / reaction.c / ks_dbase.c / force.c) and DATA files
--   loaded from disk (FORMCOMP.DAT formation compositions, the WUT warzone-unit tables, faction rosters).
--   This module is the port's equivalent of that DATA layer: the SCENARIO warzone data a mission author
--   may legitimately re-skin — unit type names, countries, weapon payloads, reserve counts, installation
--   statics, and a handful of documented designer/proxy theatre knobs.
--
--   EECH-CITED ENGINE CONSTANTS ARE DELIBERATELY **NOT** HERE (CLAUDE.md prime directive). Cadences,
--   strike/repair/capture formulas, MINIMUM_EFFICIENCY, ESCORT thresholds, FOW gates, damage fractions,
--   ETA-gate speeds, CRUISE_SPEED and all spawn kinematics (alt/speed/fuel) stay hardcoded in their
--   modules with their file:line citations. If a value traces to the EECH C source it is not tunable.
--
-- HOW AN AUTHOR OVERRIDES IT:
--   Set a global table `_G.DMT_CONFIG` BEFORE the campaign script runs (a MISSION START → DO SCRIPT
--   trigger, or a dofile before injection). It is deep-merged OVER the DEFAULTS below (user wins per
--   LEAF key; ARRAYS — slot lists, pylon lists, unit lists — replace wholesale, never merge per-index).
--   The merged result is exposed as `config.C` and also on `_G.DMT_ACTIVE_CONFIG` for inspection.
--
--   SIDE-KEYED tables use the STRING keys "blue" / "red" in DMT_CONFIG (NOT coalition.side numbers —
--   those collide with array indices and would break the deep-merge). `config.C` re-keys them to
--   coalition.side.BLUE / coalition.side.RED for the consuming modules. See README "Configuring the
--   campaign (DMT_CONFIG)".
--
-- BOOT VALIDATION:
--   main.lua calls `config.load_and_validate(log_fn)` AFTER reset.nuke but BEFORE game_loop starts (so
--   before ANY spawn). It DB-checks every aircraft/ground unit type (Unit.getDescByName), structurally
--   checks statics/payloads (they cannot be verified from the mission env), and falls each bad USER
--   override back to its DEFAULT (resilient boot). A DEFAULT that itself fails the DB check (e.g. the
--   AH-64D module is not installed — a real past incident) raises a LOUD warning + on-screen outText
--   naming the missing types and the fix. Boot continues either way; spawn-path pcall+refund keeps the
--   economy safe on any residual failure.
--
-- Hoisted from (defaults trace back to these literals, citations preserved):
--   attack_waves.lua / cas_bai_sead.lua / reaction.lua / recon.lua / regen.lua / heli_war.lua (aircraft
--   + pylon tables), troop.lua (transport heli + infantry), ground_forces.lua (FORMCOMP.DAT slot rows),
--   installations.lua (KINDS/PALETTE/garrison/EWR/AAA/SAM), base_defenses.lua (AD-ring composition,
--   counts, radius → the `defenses` section),
--   farps.lua (FARP static + fixed-wing count + front distance), supply.lua (reserve allotments),
--   payloads.lua (the pylon/CLSID tables — this module exposes them).

local cs       = require("campaign_state")
local payloads = require("payloads")

local BLUE = coalition.side.BLUE
local RED  = coalition.side.RED

local M = {}

-- ═══════════════════════════════════════════════════════════════════════════════
-- DEFAULTS — string side keys ("blue"/"red"); re-keyed to coalition.side in build().
-- Values are the EXACT current literals from the modules named above (a pure hoist).
-- ═══════════════════════════════════════════════════════════════════════════════
local DEFAULTS = {

    -- Campaign scheduler MODE selector (campaign_mode.lua): "campaign" (default) or "skirmish".
    -- Selects which of EECH's two start_high_level_ai cadence tables the schedulers use — campaign
    -- (highlevl.c:246-268) or the faster SKIRMISH branch (highlevl.c:218-242). The cadence VALUES are
    -- EECH-cited engine constants and live in campaign_mode.lua; this is only the selector. Default
    -- "campaign" preserves EECH fidelity for a DCS session (== campaign game type).
    mode = "campaign",

    -- Country id per side (single source; ground_forces/installations/farps/base_defenses + the
    -- aircraft spawners all draw their coalition country from here).
    countries = { blue = country.id.USA, red = country.id.RUSSIA },

    types = {
        -- ── Aircraft roster per side ──────────────────────────────────────────────
        -- striker/escort: attack_waves.lua AC + cas_bai_sead.lua AC; recon: recon.lua AC;
        -- attack_heli: heli_war.lua ATTACK + regen.lua AC.heli; transport_heli: troop.lua AC_HELI;
        -- bda_heli: reaction.lua AC.heli (BDA/CAP-transport airframe). All verified via Unit.getDescByName.
        aircraft = {
            blue = {
                striker        = "F-16C bl.52d",   -- ARMED_FW / ground attack
                escort         = "F-15C",           -- FIGHTER / air superiority
                recon          = "F-15C",           -- fast high overflight (recon.lua)
                attack_heli    = "AH-64D",          -- primary anti-armour/CAS/BAI arm (heli_war/regen)
                transport_heli = "UH-60A",          -- troop insertion + FARP resupply (user pref
                                                    -- 2026-07-10: Black Hawk over Huey; live-DB-verified)
                transport_fw   = "C-130",           -- MEDIUM lift (gp_dbase.c:590 C-130J Hercules II)
                transport_fw_heavy = "C-17A",       -- HEAVY lift (gp_dbase.c:631 C-17 Globemaster III;
                                                    -- alternates with medium per supply flight)
                bda_heli       = "UH-60A",          -- BDA overflight (Black Hawk, ditto)
            },
            red = {
                striker        = "Su-25T",
                escort         = "Su-27",
                recon          = "Su-27",
                attack_heli    = "Mi-24V",
                transport_heli = "Mi-8MT",
                transport_fw   = "An-26B",          -- MEDIUM lift (gp_dbase.c:591 An-12B Cub; DCS has
                                                    -- no An-12 → An-26B is the documented analog)
                transport_fw_heavy = "IL-76MD",     -- HEAVY lift (gp_dbase.c:632 IL-76MD Candid B;
                                                    -- alternates with medium per supply flight)
                bda_heli       = "Mi-8MT",
            },
        },

        ground = {
            -- PRIMARY_FRONTLINE_GROUP ordered slots (ground_forces.lua; FORMCOMP.DAT:434-469, :COUNT 16
            -- at :436). Each row = { BLUE DCS type, RED DCS type }; FORMCOMP line pair cited per row.
            -- ARRAY — replaced wholesale on override.
            primary_slots = {
                { "M-1 Abrams",    "T-80UD"       },  -- :438/:439  M1A2_ABRAMS / T80U        (both verified)
                { "M-1 Abrams",    "T-80UD"       },  -- :440/:441  M1A2_ABRAMS / T80U
                { "M2A2 Bradley",  "BMP-2"        },  -- :442/:443  M2A2_BRADLEY / BMP2       (both verified)
                { "M1097 Avenger", "2S6 Tunguska" },  -- :444/:445  M1037_AVENGER / SA19_GRISON (RED UNVERIFIED-IN-LIVE-DB)
                { "M2A2 Bradley",  "BMP-3"        },  -- :446/:447  M2A2_BRADLEY / BMP3 (RED UNVERIFIED-IN-LIVE-DB)
                { "M48 Chaparral", "Strela-10M3"  },  -- :448/:449  M48A1_CHAPARRAL / SA13_GOPHER (both UNVERIFIED-IN-LIVE-DB)
                { "M-113",         "BTR-80"       },  -- :450/:451  M113A2 / BTR80 (BLUE UNVERIFIED-IN-LIVE-DB)
                { "M-1 Abrams",    "T-80UD"       },  -- :452/:453  M1A2_ABRAMS / T80U
                { "M-1 Abrams",    "T-80UD"       },  -- :454/:455  M1A2_ABRAMS / T80U
                { "M2A2 Bradley",  "BMP-2"        },  -- :456/:457  M2A2_BRADLEY / BMP2
                { "M-1 Abrams",    "T-80UD"       },  -- :458/:459  M1A2_ABRAMS / T80U
                { "M-1 Abrams",    "T-80UD"       },  -- :460/:461  M1A2_ABRAMS / T80U
                { "M-113",         "BTR-80"       },  -- :462/:463  M113A2 / BTR80
                { "M-1 Abrams",    "T-80UD"       },  -- :464/:465  M1A2_ABRAMS / T80U
                { "M-113",         "BTR-80"       },  -- :466/:467  M113A2 / BTR80
                { "M-1 Abrams",    "T-80UD"       },  -- :468/:469  M1A2_ABRAMS / T80U
            },
            -- SECONDARY_FRONTLINE_GROUP ordered slots (ground_forces.lua; FORMCOMP.DAT:475-511, :COUNT 16
            -- at :477). Placed at FRONTLINE_FORCE_SECONDARY road nodes BEHIND the primary line
            -- (faction.c:1565-1600); group type GROUP_SECONDARY_FRONTLINE, frontline_flag SECONDARY
            -- (gp_dbase.c:764). Consumed slot-by-slot in file order (faction.c:661/666); a size-N group
            -- fields the FIRST N slots. Each row = { BLUE DCS type, RED DCS type }; FORMCOMP line pair per
            -- row. ARRAY — replaced wholesale on override. All types LIVE-DB-VERIFIED (Unit.getDescByName
            -- desc check, 2026-07-10); the three NEW types (M978 HEMTT Tanker / ATZ-10 / BRDM-2) pass the
            -- same DB query the boot validator uses — spawn-test still the only 100% proof.
            secondary_slots = {
                { "M-1 Abrams",          "T-80UD"     },  -- :479/:480  M1A2_ABRAMS / T80U            (verified)
                { "M48 Chaparral",       "Strela-10M3"},  -- :481/:482  M48A1_CHAPARRAL / SA13_GOPHER (organic SHORAD)
                { "M2A2 Bradley",        "BMP-3"      },  -- :483/:484  M2A2_BRADLEY / BMP3
                { "M 818",               "Ural-375"   },  -- :485/:486  M923A1_BIG_FOOT_COVERED / URAL_4320 (cargo truck)
                { "M-1 Abrams",          "T-80UD"     },  -- :487/:488  M1A2_ABRAMS / T80U
                { "M978 HEMTT Tanker",   "ATZ-10"     },  -- :489/:490  M978_HEMTT / URAL_FUEL_TANKER (NEW fuel truck)
                { "M1043 HMMWV Armament","BRDM-2"     },  -- :491/:492  M1025_HUMVEE / BRDM2 (scout; RED BRDM-2 NEW)
                { "M-113",               "BTR-80"     },  -- :493/:494  M113A2 / BTR80
                { "M-1 Abrams",          "T-80UD"     },  -- :495/:496  M1A2_ABRAMS / T80U
                { "M 818",               "Ural-375"   },  -- :497/:498  M923A1_BIG_FOOT_COVERED / URAL_4320
                { "M-113",               "BTR-80"     },  -- :499/:500  M113A2 / BTR80
                { "M48 Chaparral",       "Strela-10M3"},  -- :501/:502  M48A1_CHAPARRAL / SA13_GOPHER
                { "M-1 Abrams",          "T-80UD"     },  -- :503/:504  M1A2_ABRAMS / T80U
                { "M978 HEMTT Tanker",   "ATZ-10"     },  -- :505/:506  M978_HEMTT / URAL_FUEL_TANKER
                { "M48 Chaparral",       "Strela-10M3"},  -- :507/:508  M48A1_CHAPARRAL / SA13_GOPHER
                { "M-1 Abrams",          "T-80UD"     },  -- :509/:510  M1A2_ABRAMS / T80U
            },
            -- ARTILLERY_GROUP slots (ground_forces.lua; FORMCOMP.DAT:549-562, :COUNT 4 at :552).
            arty_slots = {
                { "M-109",                "SAU Msta" },  -- :554/:555  M109A2 / 2S19 (both UNVERIFIED-IN-LIVE-DB)
                { "M-109",                "SAU Msta" },  -- :556/:557  M109A2 / 2S19
                { "M 818",                "Ural-375" },  -- :558/:559  M923A1_BIG_FOOT / URAL_4320 (both UNVERIFIED; Ural-4320 → "Ural-375")
                { "M1043 HMMWV Armament", "UAZ-469"  },  -- :560/:561  M998_HUMVEE / UAZ469B (BLUE armed-variant sub; RED UNVERIFIED)
            },
            -- MLRS_GROUP slots (ground_forces.lua; FORMCOMP.DAT:566-579, :COUNT 4 at :569).
            mlrs_slots = {
                { "MLRS",                 "Grad-URAL" },  -- :571/:572  M270_MLRS / BM21_GRAD (both UNVERIFIED)
                { "MLRS",                 "Grad-URAL" },  -- :573/:574  M270_MLRS / BM21_GRAD
                { "M 818",                "Ural-375"  },  -- :575/:576  M923A1_BIG_FOOT / URAL_4320
                { "M1043 HMMWV Armament", "UAZ-469"   },  -- :577/:578  M998_HUMVEE / UAZ469B
            },
            -- Keysite infantry patrol type (troop.lua INFANTRY_TYPE — proxy for FORMATION_COMPONENT_INFANTRY).
            infantry = { blue = "Soldier M4", red = "Infantry AK" },
            -- Installation empty-zone GARRISON (installations.lua GARRISON_UNITS — DESIGNER data, a mixed
            -- defensive company for an auto-zone; ARRAY replaced wholesale).
            garrison = {
                blue = { "M-1 Abrams", "M2A2 Bradley", "M2A2 Bradley", "M1043 HMMWV Armament" },
                red  = { "T-80UD", "BMP-2", "BMP-2", "BTR-80" },
            },
            -- Installation defence element types (installations.lua). ewr also feeds statics.kinds.radar.unit.
            ewr = { blue = "Hawk sr", red = "55G6 EWR" },        -- radar/EWR unit per side
            aaa = { blue = "Vulcan",  red = "ZSU-23-4 Shilka" }, -- short-range AAA
            sam = { blue = { "Roland ADS" }, red = { "Kub 1S91 str", "Kub 2P25 ln" } },  -- point SAM battery (ARRAY)
        },
    },

    -- ── Static objects (STRUCTURE-only validated: a DB type query is not spawn proof — see the
    -- 2026-07-06 journal crash saga where a "valid" type still failed to spawn; only a live spawn
    -- confirms a triple. Author-supplied statics are trusted structurally and verified at spawn time).
    statics = {
        -- installations.lua KINDS: zone kind → physical object. "static" kinds carry a type/shape/cat
        -- triple; the "radar" kind spawns a per-side EWR UNIT instead.
        kinds = {
            depot    = { spawn = "static", type = "M92_10Ft_Container", shape = "M92_Container_10ft", cat = "Cargos",         label = "Supply Depot" },
            fuel     = { spawn = "static", type = "FARP Fuel Depot",    shape = "GSM Rus",            cat = "Fortifications", label = "Fuel Depot" },
            command  = { spawn = "static", type = ".Command Center",    shape = "ComCenter",          cat = "Fortifications", label = "Command Post" },
            factory  = { spawn = "static", type = "Boiler-house A",     shape = "kotelnaya_a",        cat = "Fortifications", label = "Munitions Factory" },
            refinery = { spawn = "static", type = "FARP Fuel Depot",    shape = "GSM Rus",            cat = "Fortifications", label = "Oil Refinery" },
            radar    = { spawn = "unit",   unit = { blue = "Hawk sr", red = "55G6 EWR" },             label = "Radar/EWR" },
        },
        -- installations.lua PALETTE: verified spawn building blocks (type | shape_name | category).
        palette = {
            factory   = { "Boiler-house A",         "kotelnaya_a",        "Fortifications" },  -- production hall
            warehouse = { "Warehouse",              "sklad",              "Warehouses"     },  -- storage shed
            fueltank  = { "Tank",                   "bak",                "Warehouses"     },  -- fuel/oil tank
            ammo      = { ".Ammunition depot",      "SkladC",             "Warehouses"     },  -- ammo store
            fuel      = { "FARP Fuel Depot",        "GSM Rus",            "Fortifications" },  -- fuel dump
            command   = { ".Command Center",        "ComCenter",          "Fortifications" },  -- HQ building
            bunker    = { "FARP CP Blindage",       "kp_ug",              "Fortifications" },  -- command bunker
            container = { "M92_10Ft_Container",     "M92_Container_10ft", "Cargos"         },  -- cargo container
        },
        -- farps.lua forward-FARP static (auto-theatre only; zone-authored theatres place their own).
        farp = { type = "FARP", shape_name = "FARP", category = "Heliports" },
    },

    -- ── Weapon pylon tables (payloads.lua). STRUCTURE-only validated (no mission-env API enumerates
    -- CLSIDs); the CLSIDs are spawn-time-verified. Keyed side→role→pylon list.
    payloads = {
        blue = { striker = payloads.F16_STRIKER,  escort = payloads.F15_ESCORT, attack_heli = payloads.AH64D_CAP },
        red  = { striker = payloads.SU25T_STRIKER, escort = payloads.SU27_ESCORT, attack_heli = payloads.MI24V_CAP },
    },

    -- ── Reserve allotments (supply.lua). NOT the EECH-cited regen reseed counts (+6/+4 at
    -- keysite.c:1490/1494 are engine constants and stay in regen.lua).
    reserves = {
        -- Per owned AIRBASE idle-aircraft ledger seed (supply.lua RESERVE_PER_BASE).
        per_base = { striker = 4, escort = 2, heli = 6, recon = 1, transport = 3, vehicle = 2 },
        -- FOB/FARP (helicopters-only) ledger seed (supply.lua:143): rotary + insertion transport only.
        farp_heli      = 4,
        farp_transport = 2,
    },

    -- ── Theatre knobs — documented DESIGNER/proxy data only (no EECH C citation). Everything with a
    -- C citation stays in its module.
    theatre = {
        -- Dormant-FARP activation gate (farps.lua; EECH keysite.c:507-568 initialise_keysite_farp_enable):
        -- when TRUE (default, EECH-faithful) a forward FARP is created DORMANT (in_use=FALSE, ks_creat.c:157)
        -- and only participates once its sector's side matches its own — i.e. as the front reaches it. When
        -- FALSE, every FARP is active from boot (authored theatres that want all-active). Default TRUE for
        -- fidelity (EECH FARPs are never all-active at boot; they enable when the sector is friendly).
        farp_activation     = true,
        fixed_wing_per_side = 2,        -- farps.lua FIXED_WING_PER_SIDE (a couple of FW airbases per side)
        front_dist          = 140000,   -- m; ground_forces.lua:38 + installations.lua FRONT_DIST — both were
                                        -- 140000 pre-hoist (unification VERIFIED, not a merge of two values)
        farp_front_dist     = 260000,   -- m; farps.lua FRONT_DIST (forward-FARP frontline distance). The
                                        -- RECORDED value is 260 km (goals/03 2026-07-06 close-spec-gaps
                                        -- journal:523 "FRONT_DIST 260km → 19 FARPs"); the 200000 found in
                                        -- farps.lua at hoist time was unjournaled drift (07-09 journal:345)
                                        -- — realigned to the journaled value here.
    },

    -- ── Persistence (persist.lua — WAVE 2, goals/03 P1) ────────────────────────────────────────────
    -- Campaign save/restore through the DCS Studio SQLite bridge so the campaign survives a
    -- DCS_server.exe restart (EECH pack_session analog). DISABLED BY DEFAULT so every current dev
    -- workflow (hot re-inject) is byte-for-byte unchanged — enable it only for a dedicated-server
    -- deployment. autosave_period is seconds between background autosaves (saves also fire on capture
    -- and on the win declaration). slot names the save row; db_path is under lfs.writedir() (bridge-guarded).
    persistence = {
        enabled         = false,               -- master switch (restore in game_loop + autosave)
        autosave_period = 300,                 -- s between autosaves (proxy for periodic session repack)
        slot            = "default",           -- save-slot key (one campaign per slot)
        db_path         = "dmt_campaign.sqlite", -- SQLite file under the guarded write root
    },

    -- ── Keysite AIR-DEFENCE RINGS (base_defenses.lua) ──────────────────────────────────────────────
    -- EECH popread.c:2148-2212 read_population_sam_placements spawns an ENTITY_SUB_TYPE_GROUP_ANTI_
    -- AIRCRAFT group (formation FORMATION_COMPONENT_LIGHT_SAM_AAA_GROUP, popread.c:2204) at EVERY
    -- population AAA/SAM point; the points come from map population templates (TEMPLATE_TYPE_AIRFIELD /
    -- TEMPLATE_TYPE_AAASAM, popread.c:100-101) that seed several around every airfield/town. That per-
    -- keysite DENSITY is MAP DATA, not in the C tree, so `groups_per` is a DOCUMENTED DESIGNER PROXY for
    -- it (author sets 0 to opt a keysite class out). `ring_radius` is metres from the keysite centre the
    -- ring is spaced at. `group` is the per-group composition = FORMCOMP.DAT:535-545 LIGHT_SAM_AAA_GROUP
    -- FIRST TWO slots (member count = component_count-1 = 2, popread.c:2208): slot1 M48A1_CHAPARRAL /
    -- SA19_GRISON, slot2 M163_VULCAN / SA13_GOPHER → DCS BLUE {M48 Chaparral, Vulcan}, RED {2S6 Tunguska
    -- (SA-19), Strela-10M3 (SA-13)}. (FORMCOMP HEAVY_SAM_AAA_GROUP:516-530 has no code consumer in the
    -- shipped tree — popread.c:2204 uses LIGHT only — so it is deliberately NOT ported.) These are FREE
    -- OOB placement (no force-reserve consume — population AA is engine-placed, not force hardware).
    defenses = {
        groups_per  = { airbase = 3, farp = 1, installation = 1 },  -- DESIGNER proxy for popread density
        ring_radius = 1500,                                         -- m; ring spacing from keysite centre
        group = {   -- FORMCOMP.DAT:535-545 first 2 slots (ARRAY — replaced wholesale on override)
            blue = { "M48 Chaparral", "Vulcan" },        -- M48A1_CHAPARRAL + M163_VULCAN
            red  = { "2S6 Tunguska", "Strela-10M3" },    -- SA19_GRISON (SA-19) + SA13_GOPHER (SA-13)
        },
        -- ── POPULATION FIRING POINTS (base_defenses.lua) ────────────────────────────────────────────
        -- EECH popread.c:1389-1439: population building scene-links spawn SINGLE-UNIT
        -- GROUP_STATIC_INFANTRY groups — FORMATION_COMPONENT_LIGHT/MEDIUM/HEAVY_FIRING_POINT (MG posts,
        -- FORMCOMP.DAT:693-717, :COUNT 1) and INFANTRY_SAM_STANDING/KNEELING (MANPAD soldier,
        -- FORMCOMP.DAT:617-631, :COUNT 1), linked to the closest keysite, owned by the sector side.
        -- GROUP_STATIC_INFANTRY frontline_flag = NONE (gp_dbase.c:887) → target of NEITHER CAS(==1) nor
        -- BAI(>1); air_attack_strength = 6 (gp_dbase.c:896, NOT the ==10 the generator SEAD wants at
        -- highlevl.c:1981) → not a generator-SEAD target. Per-keysite point DENSITY is MAP population
        -- DATA (not in the C tree), so `firing_points` counts are a DOCUMENTED DESIGNER PROXY (0 opts a
        -- class out). FREE OOB placement (population-placed, never force-reserve hardware). MG types are a
        -- proxy for the building-mounted VEHICLE_*_FIRING_POINT posts (no DCS equivalent) — reuse the
        -- verified infantry patrol soldiers; MANPAD = INFANTRY_SAM soldier (FORMCOMP.DAT:621/:622).
        firing_points = { airbase = 4, farp = 2, installation = 2 },  -- DESIGNER proxy for popread FP density
        mg     = { blue = "Soldier M4",     red = "Infantry AK" },        -- MG post proxy (verified soldiers)
        manpad = { blue = "Soldier stinger", red = "SA-18 Igla manpad" }, -- INFANTRY_SAM (LIVE-DB-VERIFIED)
    },
}

-- ═══════════════════════════════════════════════════════════════════════════════
-- Merge + re-key machinery
-- ═══════════════════════════════════════════════════════════════════════════════

-- A "sequence" (array) = a table whose keys are exactly 1..n. Arrays REPLACE wholesale on merge.
local function is_seq(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n > 0 and #t == n
end

-- Deep-merge `over` onto `base`: maps merge per key, arrays replace wholesale, scalars replace.
local function deep_merge(base, over)
    if type(base) ~= "table" or type(over) ~= "table" then return over end
    if is_seq(over) then return over end
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(over) do
        if type(v) == "table" and type(out[k]) == "table" and not is_seq(v) then
            out[k] = deep_merge(out[k], v)
        else
            out[k] = v
        end
    end
    return out
end

-- Deep-copy while re-keying the string side keys "blue"/"red" → coalition.side numbers. No other key
-- in the schema is ever the string "blue"/"red", so a generic remap is safe.
-- SIDE-KEY TYPO GUARD: only lowercase "blue"/"red" re-key. A leftover key that merely LOOKS like a
-- side ("BLUE", "Red", "neutral") would otherwise be silently carried through and never read — the
-- author's override would be a silent no-op. Warn loudly instead (accepted forms named).
local SIDE_OF = { blue = BLUE, red = RED }
local function build(v, path)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do
        if type(k) == "string" and not SIDE_OF[k] then
            local lk = string.lower(k)
            if lk == "blue" or lk == "red" or lk == "neutral" or lk == "neutrals" then
                cs.dbg("config", "INVALID: side key %q at %s ignored (accepted side keys are "
                    .. "\"blue\"/\"red\", lowercase) — that override is a NO-OP", k, path or "<root>")
            end
        end
        out[SIDE_OF[k] or k] = build(val, (path and (path .. ".") or "") .. tostring(k))
    end
    return out
end

-- Count leaf values in a table (for the "K user overrides applied" summary).
local function count_leaves(t)
    if type(t) ~= "table" then return 1 end
    local n = 0
    for _, v in pairs(t) do n = n + count_leaves(v) end
    return n
end

-- Merge the author override (if any) and expose both the ACTIVE config (C) and a pristine DEFAULT
-- view (used as the fallback source during validation).
local user_cfg = (type(_G.DMT_CONFIG) == "table") and _G.DMT_CONFIG or nil
-- deep_merge on string-keyed DEFAULTS + string-keyed user, THEN re-key to coalition.side.
local merged = deep_merge(DEFAULTS, user_cfg or {})
M.C   = build(merged)         -- ACTIVE config, coalition.side-keyed
M.DEF = build(DEFAULTS)       -- pristine defaults, coalition.side-keyed (fallback source)
_G.DMT_ACTIVE_CONFIG = M.C

-- ═══════════════════════════════════════════════════════════════════════════════
-- Validation (config.load_and_validate) — DB-checks types, structure-checks the rest, falls bad
-- user overrides back to defaults, and warns loudly if a DEFAULT type itself is missing.
-- ═══════════════════════════════════════════════════════════════════════════════

local KNOWN_ROLES = { striker = true, escort = true, heli = true, recon = true, transport = true, vehicle = true }
local KNOWN_CATS  = { Fortifications = true, Warehouses = true, Cargos = true, Heliports = true, Fortification = true, GroundVehicles = true }

local function db_exists(name)
    if type(name) ~= "string" then return false end
    local ok, desc = pcall(Unit.getDescByName, name)
    if not ok or type(desc) ~= "table" then return false end
    -- This DCS build returns a STUB table for UNKNOWN types (echoes typeName back, ~5 keys,
    -- EMPTY displayName, no attributes) instead of nil — live-caught when "F-99 Bogus" passed
    -- validation and became BLUE's active striker. A REAL desc always carries a non-empty
    -- displayName and a populated attributes table; require either signal to count as existing.
    local dn = desc.displayName
    if type(dn) == "string" and #dn > 0 then return true end
    local at = desc.attributes
    if type(at) == "table" and next(at) ~= nil then return true end
    return false
end

local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deep_copy(val) end
    return out
end

local function deep_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deep_equal(v, b[k]) then return false end end
    for k, v in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- Set of valid country ids (values of country.id).
local function valid_country_ids()
    local set = {}
    if type(country) == "table" and type(country.id) == "table" then
        for _, id in pairs(country.id) do set[id] = true end
    end
    return set
end

function M.load_and_validate(log_fn)
    log_fn = log_fn or function() end
    local C, DEF = M.C, M.DEF

    -- ── Branch type-guards (resilient boot) ────────────────────────────────────
    -- A scalar where a TABLE is expected (e.g. DMT_CONFIG.types.aircraft.blue = "F-16", or
    -- countries = "USA") survives deep_merge and would crash the section loops / write-back paths
    -- below ("attempt to index a string"), aborting the whole boot. Guard every branch first: a
    -- wrong-typed branch is logged INVALID and replaced by a deep copy of its DEFAULT subtree, then
    -- leaf validation proceeds normally.
    local function ensure_table(container, key, defval, path)
        if type(container[key]) ~= "table" then
            cs.dbg("config", "INVALID: %s = %s (expected table) — using default subtree",
                path, tostring(container[key]))
            container[key] = deep_copy(defval)
        end
        return container[key]
    end
    ensure_table(C, "types", DEF.types, "types")
    ensure_table(C.types, "aircraft", DEF.types.aircraft, "types.aircraft")
    ensure_table(C.types, "ground",   DEF.types.ground,   "types.ground")
    for _, side in ipairs({ BLUE, RED }) do
        local sname = cs.SIDE_NAME[side]
        ensure_table(C.types.aircraft, side, DEF.types.aircraft[side], "types.aircraft." .. sname)
    end
    for _, k in ipairs({ "primary_slots", "secondary_slots", "arty_slots", "mlrs_slots",
                         "infantry", "garrison", "ewr", "aaa", "sam" }) do
        ensure_table(C.types.ground, k, DEF.types.ground[k], "types.ground." .. k)
    end
    ensure_table(C, "statics", DEF.statics, "statics")
    ensure_table(C.statics, "kinds",   DEF.statics.kinds,   "statics.kinds")
    ensure_table(C.statics, "palette", DEF.statics.palette, "statics.palette")
    -- (statics.farp has its own structural check below; palette/kind ENTRIES are guarded in their loops)
    ensure_table(C, "payloads", DEF.payloads, "payloads")
    for _, side in ipairs({ BLUE, RED }) do
        ensure_table(C.payloads, side, DEF.payloads[side], "payloads." .. cs.SIDE_NAME[side])
    end
    ensure_table(C, "reserves", DEF.reserves, "reserves")
    ensure_table(C.reserves, "per_base", DEF.reserves.per_base, "reserves.per_base")
    ensure_table(C, "countries", DEF.countries, "countries")
    ensure_table(C, "theatre",   DEF.theatre,   "theatre")
    ensure_table(C, "defenses",  DEF.defenses,  "defenses")
    ensure_table(C.defenses, "groups_per",    DEF.defenses.groups_per,    "defenses.groups_per")
    ensure_table(C.defenses, "firing_points", DEF.defenses.firing_points, "defenses.firing_points")
    ensure_table(C.defenses, "group",         DEF.defenses.group,         "defenses.group")
    ensure_table(C.defenses, "mg",            DEF.defenses.mg,            "defenses.mg")
    ensure_table(C.defenses, "manpad",        DEF.defenses.manpad,        "defenses.manpad")
    for _, side in ipairs({ BLUE, RED }) do
        ensure_table(C.defenses.group,  side, DEF.defenses.group[side],  "defenses.group."  .. cs.SIDE_NAME[side])
    end

    local ok_names, missing = {}, {}   -- sets of type-name → true
    local function note(names)         -- DB-check a list of names into ok/missing sets
        for _, n in ipairs(names) do
            if db_exists(n) then ok_names[n] = true else missing[n] = true end
        end
    end
    local function names_scalar(v) return (type(v) == "string") and { v } or {} end
    local function names_strlist(v)
        local o = {}
        if type(v) == "table" then for _, n in ipairs(v) do if type(n) == "string" then o[#o + 1] = n end end end
        return o
    end
    local function names_rows(v)   -- array of {BLUE, RED} slot rows
        local o = {}
        if type(v) == "table" then for _, row in ipairs(v) do
            if type(row) == "table" then o[#o + 1] = row[1]; o[#o + 1] = row[2] end
        end end
        return o
    end
    -- Validate one leaf: DB-check its type names; if a USER override is bad, log INVALID and fall the
    -- whole leaf back to its default, then account the default's names into ok/missing.
    local function validate_leaf(container, key, defval, path, extract)
        local cur = container[key]
        local bad = {}
        for _, n in ipairs(extract(cur)) do if not db_exists(n) then bad[#bad + 1] = n end end
        if #bad == 0 then note(extract(cur)); return end
        if not deep_equal(cur, defval) then
            cs.dbg("config", "INVALID: %s = %s (unknown unit type: %s) — using default",
                path, (type(cur) == "table" and "[array]" or tostring(cur)), table.concat(bad, ", "))
            container[key] = defval
            note(extract(defval))
        else
            for _, n in ipairs(bad) do missing[n] = true end
            for _, n in ipairs(extract(cur)) do if db_exists(n) then ok_names[n] = true end end
        end
    end

    -- ── Aircraft roster (per side, per role) ──────────────────────────────────
    for _, side in ipairs({ BLUE, RED }) do
        local sname = cs.SIDE_NAME[side]
        local ac, dac = C.types.aircraft[side], DEF.types.aircraft[side]
        for _, role in ipairs({ "striker", "escort", "recon", "attack_heli", "transport_heli", "transport_fw", "transport_fw_heavy", "bda_heli" }) do
            validate_leaf(ac, role, dac[role], string.format("types.aircraft.%s.%s", sname, role), names_scalar)
        end
    end

    -- ── Ground: slot rows (shared arrays), per-side infantry/garrison/ewr/aaa/sam ──
    validate_leaf(C.types.ground, "primary_slots",   DEF.types.ground.primary_slots,   "types.ground.primary_slots",   names_rows)
    validate_leaf(C.types.ground, "secondary_slots", DEF.types.ground.secondary_slots, "types.ground.secondary_slots", names_rows)
    validate_leaf(C.types.ground, "arty_slots",    DEF.types.ground.arty_slots,    "types.ground.arty_slots",    names_rows)
    validate_leaf(C.types.ground, "mlrs_slots",    DEF.types.ground.mlrs_slots,    "types.ground.mlrs_slots",    names_rows)
    for _, side in ipairs({ BLUE, RED }) do
        local sname = cs.SIDE_NAME[side]
        local g, dg = C.types.ground, DEF.types.ground
        validate_leaf(g.infantry,     side, dg.infantry[side],     "types.ground.infantry."     .. sname, names_scalar)
        validate_leaf(g.garrison,     side, dg.garrison[side],     "types.ground.garrison."     .. sname, names_strlist)
        validate_leaf(g.ewr,          side, dg.ewr[side],          "types.ground.ewr."          .. sname, names_scalar)
        validate_leaf(g.aaa,          side, dg.aaa[side],          "types.ground.aaa."          .. sname, names_scalar)
        validate_leaf(g.sam,          side, dg.sam[side],          "types.ground.sam."          .. sname, names_strlist)
    end

    -- ── Statics: STRUCTURE only (a DB type query is NOT spawn proof — 2026-07-06 crash saga) ──
    for kind, spec in pairs(C.statics.kinds) do
        if type(spec) ~= "table" then
            cs.dbg("config", "INVALID: statics.kinds.%s = %s (expected table) — using default",
                tostring(kind), tostring(spec))
            C.statics.kinds[kind] = deep_copy(DEF.statics.kinds[kind])   -- nil default drops the entry
            spec = C.statics.kinds[kind]
        end
        if spec and spec.spawn == "static" then
            if type(spec.type) ~= "string" or type(spec.shape) ~= "string" or type(spec.cat) ~= "string" then
                cs.dbg("config", "INVALID: statics.kinds.%s (missing type/shape/cat triple) — using default", tostring(kind))
                C.statics.kinds[kind] = DEF.statics.kinds[kind]
            elseif not KNOWN_CATS[spec.cat] then
                cs.dbg("config", "INVALID: statics.kinds.%s.cat = %s (unknown category) — using default", tostring(kind), tostring(spec.cat))
                C.statics.kinds[kind].cat = DEF.statics.kinds[kind] and DEF.statics.kinds[kind].cat or spec.cat
            end
        end
    end
    for token, tri in pairs(C.statics.palette) do
        if type(tri) ~= "table" or type(tri[1]) ~= "string" or type(tri[2]) ~= "string" or not KNOWN_CATS[tri[3]] then
            cs.dbg("config", "INVALID: statics.palette.%s (bad type|shape|category triple) — using default", tostring(token))
            C.statics.palette[token] = DEF.statics.palette[token]
        end
    end
    if type(C.statics.farp) ~= "table" or type(C.statics.farp.type) ~= "string"
       or type(C.statics.farp.shape_name) ~= "string" or not KNOWN_CATS[C.statics.farp.category] then
        cs.dbg("config", "INVALID: statics.farp (bad type/shape_name/category) — using default")
        C.statics.farp = DEF.statics.farp
    end
    cs.dbg("config", "statics/payloads are STRUCTURE-validated only (type triples + CLSIDs are spawn-time-verified, "
        .. "not queryable from the mission env)")

    -- ── Payloads: STRUCTURE only (no CLSID enumeration API) ──
    for _, side in ipairs({ BLUE, RED }) do
        local sname = cs.SIDE_NAME[side]
        for _, role in ipairs({ "striker", "escort", "attack_heli" }) do
            local pl = C.payloads[side] and C.payloads[side][role]
            local structurally_ok = type(pl) == "table"
            if structurally_ok then
                for _, p in ipairs(pl) do
                    if type(p) ~= "table" or type(p.CLSID) ~= "string" then structurally_ok = false; break end
                end
            end
            if not structurally_ok then
                cs.dbg("config", "INVALID: payloads.%s.%s (not a pylon list of {CLSID=string}) — using default", sname, role)
                if C.payloads[side] then C.payloads[side][role] = DEF.payloads[side][role] end
            end
        end
    end

    -- ── Reserves: known role names, numbers >= 0 ──
    for role, n in pairs(C.reserves.per_base) do
        if not KNOWN_ROLES[role] then
            cs.dbg("config", "INVALID: reserves.per_base.%s (unknown role) — dropping", tostring(role))
            C.reserves.per_base[role] = nil
        elseif type(n) ~= "number" or n < 0 then
            cs.dbg("config", "INVALID: reserves.per_base.%s = %s (must be number >= 0) — using default", tostring(role), tostring(n))
            C.reserves.per_base[role] = DEF.reserves.per_base[role]
        end
    end
    for _, key in ipairs({ "farp_heli", "farp_transport" }) do
        if type(C.reserves[key]) ~= "number" or C.reserves[key] < 0 then
            cs.dbg("config", "INVALID: reserves.%s = %s (must be number >= 0) — using default", key, tostring(C.reserves[key]))
            C.reserves[key] = DEF.reserves[key]
        end
    end

    -- ── Countries: valid country.id values ──
    local valid_cid = valid_country_ids()
    for _, side in ipairs({ BLUE, RED }) do
        local sname = cs.SIDE_NAME[side]
        if not valid_cid[C.countries[side]] then
            cs.dbg("config", "INVALID: countries.%s = %s (not a country.id value) — using default", sname, tostring(C.countries[side]))
            C.countries[side] = DEF.countries[side]
        end
    end

    -- ── Mode selector: "campaign" | "skirmish" (else default). campaign_mode.lua already falls back
    --    defensively, but sanitise + log here so a typo is visible and C.mode is a clean value. ──
    if C.mode ~= "campaign" and C.mode ~= "skirmish" then
        cs.dbg("config", "INVALID: mode = %s (must be \"campaign\" or \"skirmish\") — using default",
            tostring(C.mode))
        C.mode = DEF.mode
    end

    -- ── Theatre knobs: numeric >= 0 (fixed_wing_per_side additionally an integer) ──
    -- Without this a string front_dist would only crash much later, at ground_forces frontline-scan
    -- time — far from the author's mistake. Mirror the reserves loop: INVALID log + default fallback.
    for _, key in ipairs({ "fixed_wing_per_side", "front_dist", "farp_front_dist" }) do
        local v = C.theatre[key]
        if type(v) ~= "number" or v < 0 then
            cs.dbg("config", "INVALID: theatre.%s = %s (must be number >= 0) — using default", key, tostring(v))
            C.theatre[key] = DEF.theatre[key]
        end
    end
    if C.theatre.fixed_wing_per_side ~= math.floor(C.theatre.fixed_wing_per_side) then
        cs.dbg("config", "INVALID: theatre.fixed_wing_per_side = %s (must be an integer) — using default",
            tostring(C.theatre.fixed_wing_per_side))
        C.theatre.fixed_wing_per_side = DEF.theatre.fixed_wing_per_side
    end
    if type(C.theatre.farp_activation) ~= "boolean" then
        cs.dbg("config", "INVALID: theatre.farp_activation = %s (must be boolean) — using default",
            tostring(C.theatre.farp_activation))
        C.theatre.farp_activation = DEF.theatre.farp_activation
    end

    -- ── Persistence: bool enabled, numeric autosave_period > 0, string slot/db_path ──
    ensure_table(C, "persistence", DEF.persistence, "persistence")
    if type(C.persistence.enabled) ~= "boolean" then
        cs.dbg("config", "INVALID: persistence.enabled = %s (must be boolean) — using default",
            tostring(C.persistence.enabled))
        C.persistence.enabled = DEF.persistence.enabled
    end
    if type(C.persistence.autosave_period) ~= "number" or C.persistence.autosave_period <= 0 then
        cs.dbg("config", "INVALID: persistence.autosave_period = %s (must be number > 0) — using default",
            tostring(C.persistence.autosave_period))
        C.persistence.autosave_period = DEF.persistence.autosave_period
    end
    for _, key in ipairs({ "slot", "db_path" }) do
        if type(C.persistence[key]) ~= "string" or #C.persistence[key] == 0 then
            cs.dbg("config", "INVALID: persistence.%s = %s (must be non-empty string) — using default",
                key, tostring(C.persistence[key]))
            C.persistence[key] = DEF.persistence[key]
        end
    end

    -- ── Defenses: per-side ring composition (DB-checked types), counts + radius (numbers >= 0) ──
    for _, side in ipairs({ BLUE, RED }) do
        validate_leaf(C.defenses.group,  side, DEF.defenses.group[side],
            "defenses.group."  .. cs.SIDE_NAME[side], names_strlist)
        -- Firing-point unit types: single DCS type per side each (MG post + MANPAD soldier).
        validate_leaf(C.defenses.mg,     side, DEF.defenses.mg[side],
            "defenses.mg."     .. cs.SIDE_NAME[side], names_scalar)
        validate_leaf(C.defenses.manpad, side, DEF.defenses.manpad[side],
            "defenses.manpad." .. cs.SIDE_NAME[side], names_scalar)
    end
    for _, key in ipairs({ "airbase", "farp", "installation" }) do
        local v = C.defenses.groups_per[key]
        if type(v) ~= "number" or v < 0 then
            cs.dbg("config", "INVALID: defenses.groups_per.%s = %s (must be number >= 0) — using default", key, tostring(v))
            C.defenses.groups_per[key] = DEF.defenses.groups_per[key]
        end
        local fv = C.defenses.firing_points[key]
        if type(fv) ~= "number" or fv < 0 then
            cs.dbg("config", "INVALID: defenses.firing_points.%s = %s (must be number >= 0) — using default", key, tostring(fv))
            C.defenses.firing_points[key] = DEF.defenses.firing_points[key]
        end
    end
    if type(C.defenses.ring_radius) ~= "number" or C.defenses.ring_radius < 0 then
        cs.dbg("config", "INVALID: defenses.ring_radius = %s (must be number >= 0) — using default", tostring(C.defenses.ring_radius))
        C.defenses.ring_radius = DEF.defenses.ring_radius
    end

    -- ── Cross-checks: every side has the required aircraft roles; slot tables non-empty w/ both columns ──
    for _, side in ipairs({ BLUE, RED }) do
        local sname = cs.SIDE_NAME[side]
        for _, role in ipairs({ "striker", "escort", "recon", "attack_heli", "transport_heli", "transport_fw" }) do
            if type(C.types.aircraft[side][role]) ~= "string" then
                cs.dbg("config", "INVALID: types.aircraft.%s.%s missing (required role) — using default", sname, role)
                C.types.aircraft[side][role] = DEF.types.aircraft[side][role]
            end
        end
    end
    for _, sk in ipairs({ "primary_slots", "secondary_slots", "arty_slots", "mlrs_slots" }) do
        local rows = C.types.ground[sk]
        local ok = type(rows) == "table" and #rows > 0
        if ok then
            for _, row in ipairs(rows) do
                if type(row) ~= "table" or type(row[1]) ~= "string" or type(row[2]) ~= "string" then ok = false; break end
            end
        end
        if not ok then
            cs.dbg("config", "INVALID: types.ground.%s (empty or missing a side column) — using default", sk)
            C.types.ground[sk] = DEF.types.ground[sk]
        end
    end

    -- ── Tally + report ──
    local n_ok, n_missing = 0, 0
    for _ in pairs(ok_names)  do n_ok = n_ok + 1 end
    local missing_list = {}
    for name in pairs(missing) do if not ok_names[name] then n_missing = n_missing + 1; missing_list[#missing_list + 1] = name end end
    local n_over = user_cfg and count_leaves(user_cfg) or 0

    -- A DEFAULT type that fails the DB check = a module/mod not installed (e.g. the AH-64D incident):
    -- LOUD warning + on-screen outText, because those spawns will silently fail until the module loads.
    if n_missing > 0 then
        table.sort(missing_list)
        local list = table.concat(missing_list, ", ")
        local warn = string.format("[dmt:config] WARNING: %d unit type(s) NOT in this DCS install's DB: %s. "
            .. "Their spawns will FAIL. Fix: install the module OR place ONE such unit in the .miz to "
            .. "preload it. Boot continues (spawn refunds keep the economy safe).", n_missing, list)
        env.info(warn)
        log_fn(warn)
        pcall(function() trigger.action.outText(warn, 30) end)
    end

    local summary = string.format("[dmt:config] validated: %d unit types OK, %d unknown, %d user overrides applied",
        n_ok, n_missing, n_over)
    env.info(summary)
    log_fn(summary)
    if n_missing > 0 then
        pcall(function() trigger.action.outText(summary, 20) end)
    end
    cs.dbg("config", "load_and_validate complete: ok=%d missing=%d overrides=%d (user_cfg=%s)",
        n_ok, n_missing, n_over, tostring(user_cfg ~= nil))

    return M.C
end

return M
