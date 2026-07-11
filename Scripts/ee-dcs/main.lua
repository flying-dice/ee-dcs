-- ee-dcs
-- Trigger-script ENTRY POINT (thin shim). The entire EECH-style dynamic campaign lives in
-- game_loop.lua and its sub-modules; this file only wires the boot sequence:
--   1. install the spawn-queue interception FIRST (before ANY spawn happens),
--   2. nuke the previous injection (clean re-injection into the same running mission),
--   3. start the campaign game loop,
--   4. start the spawn-queue drain (everything above only ENQUEUED its spawns).
--
-- HISTORY: a legacy parallel supply / helicopter-CAP / ground-patrol wave layer used to live here
-- (gated behind _G.DMT_ENABLE_LEGACY_LAYER). It fired a transport/CAP/patrol to EVERY base at once —
-- redundant with, and less EECH-faithful than, the game_loop campaign (task-board-driven supply,
-- heli_war, frontline patrols). It was retired 2026-07-06 and DELETED entirely in Cluster H
-- (2026-07-09); the campaign feel now comes solely from the EECH port.

local cs = require("campaign_state")
-- Install the spawn-queue interception FIRST, before any spawn happens (reset + game_loop init):
-- all coalition.addGroup / addStaticObject calls now enqueue and drain over time.
require("spawn_queue")

local ee_dcs = {}
ee_dcs.name    = "ee-dcs"
ee_dcs.version = "0.2.0"

local function info(msg)
    env.info(string.format("[%s] %s", ee_dcs.name, msg))
end

-- ── Entry point ─────────────────────────────────────────────────────────────────
function ee_dcs.start()
    info("loaded v" .. ee_dcs.version)
    cs.dbg("loop", "main.start(): generation=%d", cs.GENERATION)

    -- RESET FIRST: nuke the previous injection's world objects, event handlers, and F-10 marks so
    -- each inject starts a fresh campaign in the SAME running mission (no DCS restart to iterate).
    -- Runs before game_loop registers new handlers / spawns, so old-group deaths hit no handler.
    require("reset").nuke(info)
    cs.dbg("loop", "main.start(): reset done; single game_loop.start() follows")
end

ee_dcs.start()

-- Load + validate SCENARIO configuration (config.lua / _G.DMT_CONFIG) AFTER reset.nuke but BEFORE the
-- game loop and its sub-modules are required (they read config.C at module scope) — so bad author
-- overrides are caught and fall back to defaults before anything spawns. See config.lua header.
cs.dbg("loop", "main.lua: config.load_and_validate() before game_loop require")
require("config").load_and_validate(info)

-- Start the EECH-inspired campaign game loop (attack waves, ground offensives, territory control,
-- win conditions). Defined in game_loop.lua and its sub-modules.
cs.dbg("loop", "main.lua: single unconditional require(\"game_loop\").start() call")
local game_loop = require("game_loop")
game_loop.start()

-- Everything above only ENQUEUED its spawns (spawn_queue intercepts addGroup). Start draining now
-- that the full init burst is queued — one spawn per tick so the sim advances between each.
cs.dbg("spawn", "main.lua: starting spawn_queue drain")
require("spawn_queue").schedule_drain()

return ee_dcs
