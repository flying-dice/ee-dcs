/** @noSelfInFile */
/*
-- spawn_queue.lua
-- Diagnostic + robustness layer: intercept every coalition.addGroup / addStaticObject and DEFER it
-- into a queue that drains a few spawns per timer tick, instead of spawning ~150-200 groups
-- synchronously in a single frame at mission start.
--
-- WHY: injecting the campaign hard-crashes DCS (~0.07s after init) with C0000005 ACCESS_VIOLATION
-- in edObjects viLight::QueryEditor, via wSimCalendar::DoActionsUntil → wSimTrace (track recorder).
-- No Lua error — a DCS-engine null-deref triggered when the sim first advances and processes the
-- burst of freshly-added groups. Draining one spawn per tick lets the sim advance a frame BETWEEN
-- each spawn, so (a) if the crash is a volume/burst problem it is avoided entirely, and (b) if it is
-- one specific unit, the log pinpoints it: the last ">>> SPAWNING #N" / "<<< OK #N" pair with no
-- following "#N+1" is the group whose render/track step crashed the sim.
--
-- Callers keep working: addGroup returns a lazy PROXY that delegates to the real DCS group (by name)
-- once the queued spawn drains. getController() before the real spawn captures setTask/pushTask and
-- replays them on drain (ground_forces / cas artillery set a task immediately after spawning).
*/
import * as cs from "./campaign_state";
import * as diagnostics from "./spawn_diagnostics";

const S = cs.S;
const DRAIN_PER_TICK = 4;
const DRAIN_INTERVAL = 1.0;
export type LogFunction = (this: void, message: string) => void;

import type { SpawnItem } from "./campaign_types";

export type { SpawnItem } from "./campaign_types";

S.spawn_queue = S.spawn_queue ?? [];
S._spawn_seq = S._spawn_seq ?? 0;
_G.__dmt_real_addGroup = _G.__dmt_real_addGroup ?? coalition.addGroup;
_G.__dmt_real_addStatic = _G.__dmt_real_addStatic ?? coalition.addStaticObject;
const real_addGroup = _G.__dmt_real_addGroup;
const real_addStatic = _G.__dmt_real_addStatic;
function make_proxy(
	name: string,
	item: SpawnItem,
): Group & { __queued: boolean } {
	function live(): Group | undefined {
		return Group.getByName(name);
	}
	// While the spawn is still queued there is no DCS group behind this handle,
	// so the proxy implements only the subset of the group/static API the
	// campaign calls, and reports empty/undefined for the rest. That is a
	// deliberately partial implementation, hence the assertion.
	return {
		__queued: true,
		getName(this: Group) {
			return name;
		},
		isExist(this: Group) {
			return live()?.isExist() ?? false;
		},
		getUnits(this: Group) {
			return live()?.getUnits() ?? [];
		},
		getUnit(this: Group, i: number) {
			return live()?.getUnit(i);
		},
		getSize(this: Group) {
			return live()?.getSize() ?? 0;
		},
		getID(this: Group) {
			return live()?.getID() ?? -1;
		},
		getCategory(this: Group) {
			return live()?.getCategory();
		},
		getCoalition(this: Group) {
			return live()?.getCoalition();
		},
		destroy(this: Group) {
			live()?.destroy();
		},
		getController(this: Group): Controller {
			const g = live();
			if (g) return g.getController();
			// Same deal for the controller: record the tasks so `drain` can
			// replay them onto the real controller once the group exists.
			return {
				setTask(this: Controller, task: DcsTask) {
					item.deferred_setTask = task;
				},
				pushTask(this: Controller, task: DcsTask) {
					item.deferred_pushTask = task;
				},
				resetTask(this: Controller) {},
				setCommand(this: Controller) {},
				setOption(this: Controller) {},
			} as unknown as Controller;
		},
	} as unknown as Group & { __queued: boolean };
}
coalition.addGroup = (country_id, category, data) => {
	S._spawn_seq++;
	const name = (data as GroupData).name ?? "SpawnQ-" + S._spawn_seq;
	const item: SpawnItem = {
		kind: "group",
		country: country_id,
		category,
		data: data as GroupData,
		name,
		seq: S._spawn_seq,
	};
	S.spawn_queue.push(item);
	return make_proxy(name, item);
};
coalition.addStaticObject = (country_id, data) => {
	S._spawn_seq++;
	const name = (data as StaticData).name ?? "SpawnQ-static-" + S._spawn_seq;
	const item: SpawnItem = {
		kind: "static",
		country: country_id,
		data: data as StaticData,
		name,
		seq: S._spawn_seq,
	};
	S.spawn_queue.push(item);
	return make_proxy(name, item) as unknown as StaticObject;
};
export function drain(log_fn: LogFunction = env.info): number {
	const q = S.spawn_queue;
	let n = 0;
	while (q.length > 0 && n < DRAIN_PER_TICK) {
		const item = q.shift();
		if (!item) break;
		const utype =
			item.kind === "group" ? (item.data.units[0]?.type ?? "?") : "?";
		log_fn(
			string.format(
				"[spawn_queue] >>> SPAWNING #%d name=%s type=%s kind=%s (%d left)",
				item.seq,
				item.name,
				utype,
				item.kind,
				q.length,
			),
		);
		let g: Group | StaticObject | undefined;
		let spawned: Group | undefined;
		if (item.kind === "group") {
			const probe = diagnostics.begin(item, log_fn);
			const [ok, res] = pcall(
				real_addGroup,
				item.country,
				item.category,
				item.data,
			);
			diagnostics.finish(
				probe,
				ok ? (res !== undefined ? "returned" : "nil") : "threw",
			);
			if (ok) {
				g = res;
				spawned = res;
			} else
				log_fn(
					string.format(
						"[spawn_queue] !!! addGroup THREW #%d: %s",
						item.seq,
						tostring(res),
					),
				);
		} else {
			const [ok, res] = pcall(real_addStatic, item.country, item.data);
			if (ok) g = res;
		}
		if (spawned) {
			const set = item.deferred_setTask;
			const push = item.deferred_pushTask;
			if (spawned && set) pcall(() => spawned.getController().setTask(set));
			if (spawned && push) pcall(() => spawned.getController().pushTask(push));
		}
		log_fn(
			string.format(
				"[spawn_queue] <<< API RESULT #%d name=%s api_returned=%s",
				item.seq,
				item.name,
				tostring(g !== undefined),
			),
		);
		n++;
	}
	if (q.length === 0 && !S._spawn_drain_reported && S._spawn_seq > 0) {
		S._spawn_drain_reported = true;
		log_fn(
			string.format(
				"[spawn_queue] DRAIN COMPLETE — all %d queued spawn requests processed (not proof of live units)",
				S._spawn_seq,
			),
		);
		cs.dbg(
			"spawn",
			"DRAIN COMPLETE: all %d queued spawns executed",
			S._spawn_seq,
		);
	}
	return n;
}
export function schedule_drain(log_fn: LogFunction = env.info): void {
	const my_gen = _DMT_GEN;
	timer.scheduleFunction(
		(_, t) => {
			if (_DMT_GEN !== my_gen) return undefined;
			drain(log_fn);
			return t + DRAIN_INTERVAL;
		},
		undefined,
		timer.getTime() + DRAIN_INTERVAL,
	);
	log_fn(
		string.format(
			"[spawn_queue] drain scheduled: %d spawn/tick every %.1fs (%d queued now)",
			DRAIN_PER_TICK,
			DRAIN_INTERVAL,
			S.spawn_queue.length,
		),
	);
	cs.dbg(
		"spawn",
		"drain scheduler REGISTERED offset=%.1fs period=%.1fs rate=%d/tick (%d queued now)",
		DRAIN_INTERVAL,
		DRAIN_INTERVAL,
		DRAIN_PER_TICK,
		S.spawn_queue.length,
	);
}
