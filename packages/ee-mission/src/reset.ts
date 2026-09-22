/** @noSelfInFile */
/*
-- reset.lua
-- Dev-iteration reset: on EACH injection, nuke the previous campaign so a fresh order-of-battle
-- starts in the SAME running mission — no DCS restart needed to iterate (edit → build → inject).
--
-- What survives a re-inject and must be cleared here:
--   1. Units/groups placed in the DCS world by the previous campaign (Lua state resets on the
--      fresh bundle run + the _DMT_GEN generation guard cancels the old run's timers, but the
--      spawned OBJECTS live in the sim, not in Lua).
--   2. Event handlers registered via world.addEventHandler (never auto-removed → would stack).
--   3. F-10 overlay marks (map_overlay ID ranges).
-- Human players are never touched.
*/
import * as cs from "./campaign_state";
import { BLUE, NEUTRAL, RED } from "./sides";

// Reserved F10/map-overlay ID ranges owned by the campaign modules. These match
// the allocation blocks in task, column, frontline, installation, base and asset overlays.
const CAMPAIGN_MARK_RANGES: Array<[number, number]> = [
	[10000, 10050],
	[20000, 21199],
	[30000, 31999],
	[40000, 40799],
	[50000, 51999],
	[60000, 62399],
	[70000, 70400],
	// One-time cleanup for the old ground-column bug (30001 * 100 + index).
	[3000100, 3000299],
];

function group_has_player(g: Group): boolean {
	const [ok, units] = pcall(() => g.getUnits());
	if (!ok || !units) return false;
	for (const u of units) {
		const [okp, name] = pcall(() => u.getPlayerName && u.getPlayerName());
		if (okp && name !== undefined && name !== "") return true;
	}
	return false;
}
export function nuke(
	log_fn: (this: void, message: string) => void = env.info,
): void {
	cs.dbg(
		"reset",
		"nuke() starting: current generation=%d (old timers with a stale generation self-cancel)",
		cs.GENERATION,
	);
	let removed_h = 0;
	for (const h of _G.__dmt_handlers ?? []) {
		const [ok] = pcall(world.removeEventHandler, h);
		if (ok) removed_h++;
	}
	_G.__dmt_handlers = [];
	let destroyed = 0;
	let skipped = 0;
	for (const side of [NEUTRAL, RED, BLUE]) {
		const [ok, groups] = pcall(coalition.getGroups, side);
		if (ok && groups) {
			for (const g of groups) {
				if (group_has_player(g)) skipped++;
				else {
					pcall(() => g.destroy());
					destroyed++;
				}
			}
		}
	}
	let ds = 0;
	for (const side of [NEUTRAL, RED, BLUE]) {
		const [ok, objs] = pcall(coalition.getStaticObjects, side);
		if (ok && objs) {
			for (const so of objs) {
				const [okn, nm] = pcall(() => so.getName());
				if (
					okn &&
					(nm.startsWith("KS-") ||
						nm.startsWith("FARP-") ||
						nm.startsWith("Inst-"))
				) {
					pcall(() => so.destroy());
					ds++;
				}
			}
		}
	}
	function clear(a: number, b: number): void {
		for (let id = a; id <= b; id++) pcall(trigger.action.removeMark, id);
	}
	for (const [firstId, lastId] of CAMPAIGN_MARK_RANGES) clear(firstId, lastId);
	log_fn(
		string.format(
			"[reset] fresh start — destroyed %d group(s), %d campaign static(s), skipped %d player group(s), removed %d handler(s), cleared overlay",
			destroyed,
			ds,
			skipped,
			removed_h,
		),
	);
	cs.dbg(
		"reset",
		"nuke() done: %d groups destroyed, %d statics destroyed, %d player groups skipped, %d handlers removed",
		destroyed,
		ds,
		skipped,
		removed_h,
	);
}
