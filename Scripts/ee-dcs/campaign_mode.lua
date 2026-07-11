-- campaign_mode.lua — scheduler cadence set selected by campaign mode (CAMPAIGN | SKIRMISH).
-- EECH source:
--   aphavoc/source/ai/highlevl/highlevl.c  start_high_level_ai (:181-287): registers every
--     create_*_tasks generator with a period + start_time. There are TWO tables — a SKIRMISH branch
--     (get_game_type()==GAME_TYPE_SKIRMISH, :218-242, faster periods) and the campaign branch
--     (the else, :246-268). A DCS session == campaign mode, which the port hardcoded across modules;
--     this module centralises BOTH so config.C.mode selects the cadence set.
--
-- WHAT LIVES HERE (and why it is not in config.lua): these are EECH-CITED ENGINE CONSTANTS (each value
-- cites its highlevl.c line), so per CLAUDE.md they stay in a module, not the scenario-data config. The
-- ONLY config knob is the selector `config.C.mode` ("campaign"|"skirmish"); a bad/absent value falls
-- back to CAMPAIGN here (defensive default — this module loads before config.load_and_validate runs).
--
-- SCHED[gen] = { period = seconds, blue = offset_s, red = offset_s }:
--   * period + `blue` (the port's BLUE-side start delay) trace to the cited EECH period/start_time.
--   * `red` is the port's per-side stagger of the single EECH generator into a BLUE and a RED pass
--     (EECH has one function per task; the port runs one per side). The stagger rule is a PORT
--     construct, applied IDENTICALLY in both modes so the two are structurally parallel:
--       - keysite_strike / oca_strike / ground → red = blue + floor(period/2)  (half-period offset)
--       - cas                                   → blue 5, red 30  (EECH start_time 0 bumped to 5: DCS
--                                                 silently drops a timer scheduled at getTime()+0)
--       - every other generator                 → red = blue + 30 (fixed 30 s stagger)
--   The CAMPAIGN column is BYTE-IDENTICAL to the port's prior hardcoded module periods + game_loop
--   offset expressions (verified value-by-value against the pre-change literals).

local config = require("config")
local M = {}

local MIN = 60

-- ── CAMPAIGN cadence (highlevl.c:246-268 else-branch) — byte-identical to prior port values ──────────
-- period      blue   red         highlevl.c line (campaign start_time)          prior port literal
local CAMPAIGN = {
    cas             = { period = 15   * MIN, blue = 5,   red = 30   },  -- :246 15min off 0.0 (blue bumped 0→5; cas_bai_sead PERIOD_CAS, game_loop cas 5/30)
    patrol          = { period = 5    * MIN, blue = 5,   red = 35   },  -- :248 5min  off 5.0  (troop PERIOD_PATROL; game_loop patrol 5.0 / 5.0+30)
    ground          = { period = 12   * MIN, blue = 12,  red = 372  },  -- :250 12min off 12.0 (ground GND_PERIOD; game_loop 12 / 12+floor(720/2)=372)
    keysite_strike  = { period = 7.5  * MIN, blue = 15,  red = 240  },  -- :252 7.5min off 15.0 (attack_waves KEYSITE_STRIKE_PERIOD; 15 / 15+floor(450/2)=240)
    artillery       = { period = 15   * MIN, blue = 45,  red = 75   },  -- :254 15min off 45.0 (cas_bai_sead PERIOD_ARTY; game_loop 45 / 45+30)
    troop_insertion = { period = 2    * MIN, blue = 60,  red = 90   },  -- :256 2min  off 60.0 (troop PERIOD_TI; game_loop 60 / 60+30)
    oca_sweep       = { period = 30   * MIN, blue = 90,  red = 120  },  -- :258 30min off 90.0 (cas_bai_sead PERIOD_OCA_SWEP; game_loop 90 / 90+30)
    hc_transfer     = { period = 7.5  * MIN, blue = 120, red = 150  },  -- :260 7.5min off 120.0 (transfer PERIOD_HC; game_loop 120 / 120+30)
    fw_transfer     = { period = 15   * MIN, blue = 150, red = 180  },  -- :262 15min off 150.0 (transfer PERIOD_FW; game_loop 150 / 150+30)
    sead            = { period = 12   * MIN, blue = 180, red = 210  },  -- :264 12min off 180.0 (cas_bai_sead PERIOD_SEAD; game_loop 180 / 180+30)
    bai             = { period = 20   * MIN, blue = 300, red = 330  },  -- :266 20min off 300.0 (cas_bai_sead PERIOD_BAI; game_loop 300 / 300+30)
    oca_strike      = { period = 30   * MIN, blue = 390, red = 1290 },  -- :268 30min off 390.0 (attack_waves OCA_STRIKE_PERIOD; 390 / 390+floor(1800/2)=1290)
}

-- ── SKIRMISH cadence (highlevl.c:218-242 GAME_TYPE_SKIRMISH branch) — faster periods ───────────────
-- Same stagger rule as CAMPAIGN above; each value cites its highlevl.c skirmish line + EECH start_time.
local SKIRMISH = {
    cas             = { period = 6    * MIN, blue = 5,   red = 30   },  -- :220 6min  off 0.0  (blue bumped 0→5, red 30 — as campaign)
    sead            = { period = 10   * MIN, blue = 2,   red = 32   },  -- :222 10min off 2.0  (red +30)
    ground          = { period = 15   * MIN, blue = 12,  red = 462  },  -- :224 15min off 12.0 (red +floor(900/2)=462)
    artillery       = { period = 12   * MIN, blue = 8,   red = 38   },  -- :226 12min off 8.0  (red +30)
    keysite_strike  = { period = 10   * MIN, blue = 15,  red = 315  },  -- :228 10min off 15.0 (red +floor(600/2)=315)
    patrol          = { period = 10   * MIN, blue = 5,   red = 35   },  -- :230 10min off 5.0  (red +30)
    fw_transfer     = { period = 15   * MIN, blue = 34,  red = 64   },  -- :232 15min off 34.0 (red +30)
    troop_insertion = { period = 2    * MIN, blue = 60,  red = 90   },  -- :234 2min  off 60.0 (red +30)
    bai             = { period = 10   * MIN, blue = 90,  red = 120  },  -- :236 10min off 90.0 (red +30)
    hc_transfer     = { period = 10   * MIN, blue = 180, red = 210  },  -- :238 10min off 180.0=3.0*ONE_MINUTE (red +30)
    oca_sweep       = { period = 20   * MIN, blue = 240, red = 270  },  -- :240 20min off 240.0=4.0*ONE_MINUTE (red +30)
    oca_strike      = { period = 30   * MIN, blue = 300, red = 1200 },  -- :242 30min off 300.0=5.0*ONE_MINUTE (red +floor(1800/2)=1200)
}

-- Defensive select: only "skirmish" switches away from campaign; anything else (typo, nil, non-string)
-- falls back to CAMPAIGN. config.load_and_validate additionally sanitises + logs a bad user value.
local mode = (type(config.C.mode) == "string") and string.lower(config.C.mode) or "campaign"
if mode ~= "skirmish" then mode = "campaign" end

M.mode     = mode
M.CAMPAIGN = CAMPAIGN
M.SKIRMISH = SKIRMISH
M.SCHED    = (mode == "skirmish") and SKIRMISH or CAMPAIGN

return M
