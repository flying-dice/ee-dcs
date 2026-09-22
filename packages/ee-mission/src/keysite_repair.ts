/** @noSelfInFile */
/*
-- keysite_repair.lua
-- EECH source: aphavoc/source/entity/special/keysite/ks_updt.c
--   update_server() — two sub-loops at different periods:
--     Loop A (every KEYSITE_UPDATE_SLEEP_TIMER = 60 s):
--       ammo_supply_level += AMMO_USAGE_ACCELERATOR(1.0) × default_supply_usage.ammo_supply_level
--       fuel_supply_level += FUEL_USAGE_ACCELERATOR(1.0) × default_supply_usage.fuel_supply_level
--       bound both to [KEYSITE_MINIMUM_AMMO_SUPPLY_LEVEL=10.0, 100.0]
--     Loop B (every 1.0 * ONE_MINUTE = 60 s, offset by task_timer):
--       if keysite_strength < keysite_maximum_strength AND repairable:
--         create_repair_task(side, pos, en, priority=10.0) if not already tasked
--   KEYSITE_STATE_REPAIRING loop (continuous, delta-time driven):
--     repair_timer -= delta_time; if <= 0: repair_client_server_entity_keysite()
--     (repairs one building per timer expiry; when all repaired → KEYSITE_STATE_USABLE)
--
-- EECH source: aphavoc/source/entity/system/en_types/en_suply.h
--   KEYSITE_MINIMUM_AMMO_SUPPLY_LEVEL = 10.0  (percentage, 0–100 scale)
--   KEYSITE_MINIMUM_FUEL_SUPPLY_LEVEL = 10.0
--   AMMO_USAGE_ACCELERATOR            = 1.0
--   FUEL_USAGE_ACCELERATOR            = 1.0
--
-- EECH source: aphavoc/source/entity/special/keysite/keysite.h
--   KEYSITE_UPDATE_SLEEP_TIMER = 1.0 * ONE_MINUTE = 60 s
--
-- DCS proxy notes:
-- • Repair in EECH requires a dedicated repair unit task.  We proxy this as automatic
--   health increment when base is damaged but not neutralised.  Rate mirrors EECH's
--   1-building-per-10-min heal (REPAIR_RATE_PER_TICK = 1/100 → full in ~100 min; see below).
-- • Supply consumption: default_supply_usage is keysite-type-specific in EECH data.
--   We branch the drain rate on keysite type (airbase ammo -0.2%/fuel -0.4% per 60 s;
--   FARP far lighter — see the per-type constants below), matching EECH's per-row rates.
-- • S.base_ammo[name] uses 0–100 scale to match EECH's ammo_supply_level.
*/
import * as cs from "./campaign_state";
import type { Side } from "./campaign_types";
import * as installations from "./installations";
import { BLUE, RED } from "./sides";
import type { Commodity } from "./supply";
import * as supply from "./supply";
import * as supplyFlight from "./supply_flight";

type LogFunction = (this: void, message: string) => void;
type Need = Record<Side, Record<Commodity, string[]>>;

const S = cs.S;
const KEYSITE_UPDATE_SLEEP_TIMER = 60; // keysite.h: 1.0 * ONE_MINUTE
const KEYSITE_MINIMUM_AMMO_SUPPLY = 10.0; // en_suply.h
const KEYSITE_MINIMUM_FUEL_SUPPLY = 10.0; // en_suply.h
const AMMO_USAGE_ACCELERATOR = 1.0; // en_suply.h
const FUEL_USAGE_ACCELERATOR = 1.0; // en_suply.h
const KEYSITE_SUPPLY_REQUEST_THRESHOLD = 75.0; // en_suply.h:87 / keysite.c:469
const FULL_SUPPLY_PERCENT = 100; // EECH supply levels use a 0..100 percentage scale.

// ks_dbase.c keysite-type-specific default_supply_usage.
const AIRBASE_AMMO_USAGE_PER_TICK = -0.2; // line 98
const AIRBASE_FUEL_USAGE_PER_TICK = -0.4; // line 99
const FARP_AMMO_USAGE_PER_TICK = -0.05; // line 239
const FARP_FUEL_USAGE_PER_TICK = -0.03; // line 240

// keysite.c:1581 and ks_updt.c: one building every ten minutes. Ten building-equivalents means a
// complete repair takes about 100 minutes.
const REPAIR_RATE_PER_TICK = 1.0 / 100.0;
// Proxy for repair-task creation, assignment and delivery (ks_updt.c:169-222).
const STRIKE_SUPPRESS_TIME = 480.0;
const SIDES: Side[] = [BLUE, RED];
const COMMODITIES: Commodity[] = ["ammo", "fuel"];

export function init(logFn: LogFunction = () => undefined): void {
	for (const [name] of pairs(S.base_owner)) {
		S.base_ammo[name] ??= FULL_SUPPLY_PERCENT;
		S.base_fuel[name] ??= FULL_SUPPLY_PERCENT;
		S.base_efficiency[name] = 1;
	}
	logFn(
		string.format(
			"keysite_repair: ammo/fuel tables initialised (min_ammo=%.0f%%, min_fuel=%.0f%%)",
			KEYSITE_MINIMUM_AMMO_SUPPLY,
			KEYSITE_MINIMUM_FUEL_SUPPLY,
		),
	);
	cs.dbg(
		"repair",
		"init: ammo/fuel tables seeded at 100%% for all owned bases",
	);
}

function bound(value: number, lower: number): number {
	if (value < lower) return lower;
	if (value > FULL_SUPPLY_PERCENT) return FULL_SUPPLY_PERCENT;
	return value;
}

function tick(logFn: LogFunction): void {
	// KEYSTE-F5: production is credited only by live producer keysites.
	for (const side of SIDES) {
		let ammo = 0;
		let fuel = 0;
		const [ok] = pcall(() => {
			[ammo, fuel] = installations.production_rates(side);
		});
		if (ok) supply.credit_production(side, ammo, fuel, 1);
	}

	const need: Need = {
		[BLUE]: { ammo: [], fuel: [] },
		[RED]: { ammo: [], fuel: [] },
	};
	for (const [name, ownerValue] of pairs(S.base_owner)) {
		// `pairs()` erases the value type to `any`; S.base_owner is Record<string, Side>.
		const owner = ownerValue as Side | undefined;
		if (owner === BLUE || owner === RED) {
			const kind = S.base_kind[name];
			const isFarp = kind === "farp" || kind === "fob";
			const ammoRate = isFarp
				? FARP_AMMO_USAGE_PER_TICK
				: AIRBASE_AMMO_USAGE_PER_TICK;
			const fuelRate = isFarp
				? FARP_FUEL_USAGE_PER_TICK
				: AIRBASE_FUEL_USAGE_PER_TICK;
			S.base_ammo[name] = bound(
				(S.base_ammo[name] ?? FULL_SUPPLY_PERCENT) +
					AMMO_USAGE_ACCELERATOR * ammoRate,
				KEYSITE_MINIMUM_AMMO_SUPPLY,
			);
			S.base_fuel[name] = bound(
				(S.base_fuel[name] ?? FULL_SUPPLY_PERCENT) +
					FUEL_USAGE_ACCELERATOR * fuelRate,
				KEYSITE_MINIMUM_FUEL_SUPPLY,
			);
			if (S.base_ammo[name] <= KEYSITE_SUPPLY_REQUEST_THRESHOLD)
				need[owner].ammo.push(name);
			if (S.base_fuel[name] <= KEYSITE_SUPPLY_REQUEST_THRESHOLD)
				need[owner].fuel.push(name);
		}
	}

	// KEYSITE-F6/F7: neediest consumer first; restock happens only when the physical flight arrives.
	for (const side of SIDES) {
		for (const commodity of COMMODITIES) {
			const levels = commodity === "ammo" ? S.base_ammo : S.base_fuel;
			const list = need[side][commodity];
			list.sort((left, right) => (levels[left] ?? 0) - (levels[right] ?? 0));
			for (const baseName of list)
				supplyFlight.request(side, baseName, commodity, logFn);
		}
	}

	// Earmarks are derived from still-queued board tasks, avoiding leakage after spawn/expiry.
	for (const side of SIDES) {
		for (const commodity of COMMODITIES) {
			supply.set_earmark(
				side,
				commodity,
				supplyFlight.count_queued(side, commodity),
			);
		}
	}
	for (const side of SIDES) supply.convert_reserves(side, logFn);

	let repaired = 0;
	let suppressedCount = 0;
	let fullOrDead = 0;
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === BLUE || owner === RED) {
			const health = S.base_health[name] ?? 1;
			const lastStrike = S.base_last_strike[name];
			const suppressed =
				lastStrike !== undefined &&
				timer.getTime() - lastStrike < STRIKE_SUPPRESS_TIME;
			if (health < 1 && health >= cs.HEALTH_NEUTRALISED && !suppressed) {
				S.base_health[name] = math.min(1, health + REPAIR_RATE_PER_TICK);
				repaired++;
			} else if (health < 1 && health >= cs.HEALTH_NEUTRALISED && suppressed) {
				suppressedCount++;
			} else {
				fullOrDead++;
			}
			S.base_efficiency[name] = S.base_health[name] ?? 1;
		}
	}
	cs.dbg(
		"repair",
		"repair tick: %d repaired, %d suppressed (recent strike / repair-task-delay proxy), %d full/neutralised-or-dead",
		repaired,
		suppressedCount,
		fullOrDead,
	);
}

export function schedule_repair(logFn: LogFunction = () => undefined): void {
	const generation = _DMT_GEN;
	cs.dbg(
		"repair",
		"scheduler REGISTERED offset=%.0fs period=%.0fs",
		KEYSITE_UPDATE_SLEEP_TIMER,
		KEYSITE_UPDATE_SLEEP_TIMER,
	);
	timer.scheduleFunction(
		(_argument: undefined, time: number) => {
			if (_DMT_GEN !== generation) return undefined;
			const [ok, error] = pcall(() => tick(logFn));
			if (!ok) logFn(`keysite_repair tick error: ${tostring(error)}`);
			return time + KEYSITE_UPDATE_SLEEP_TIMER;
		},
		undefined,
		timer.getTime() + KEYSITE_UPDATE_SLEEP_TIMER,
	);
}
