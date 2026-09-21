/** @noSelfInFile */
/*
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
*/
import * as cs from "./campaign_state";
import "./spawn_queue";
import * as reset from "./reset";
export const name = "ee-dcs";
export const version = "0.2.0";
function info(message: string): void {
	env.info(string.format("[%s] %s", name, message));
}
export function start(): void {
	info("loaded v" + version);
	cs.dbg("loop", "main.start(): generation=%d", cs.GENERATION);
	reset.nuke(info);
	cs.dbg("loop", "main.start(): reset done; single game_loop.start() follows");
}
start();
cs.dbg("loop", "main.lua: config.load_and_validate() before game_loop require");
const config = require("./config") as typeof import("./config");
config.load_and_validate(info);
// Deliberately loaded after validation: modules capture config.C during evaluation.
cs.dbg(
	"loop",
	'main.lua: single unconditional require("game_loop").start() call',
);
const game_loop = require("./game_loop") as typeof import("./game_loop");
game_loop.start();
cs.dbg("spawn", "main.lua: starting spawn_queue drain");
const spawn_queue = require("./spawn_queue") as typeof import("./spawn_queue");
spawn_queue.schedule_drain();
