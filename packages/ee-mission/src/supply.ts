/** @noSelfInFile */
/*
-- supply.lua
-- Mirrors EECH's per-FORCE hardware reserve system:
--   aphavoc/source/entity/special/force/force.h   force_info_reserve_hardware[NUM_CATAGORIES]
--   aphavoc/source/entity/special/force/force.c    add_to_force_info  (spawn → reserve--, force.c:236-241)
--                                                   remove_from_force_info (death → current--, :270)
--                                                   replace_into_force_info (RTB recycle → reserve++, :297)
--   aphavoc/source/ai/faction/parser.c:1303         reserve_hardware seeded once at OOB
--   aphavoc/source/entity/special/regen/rg_updt.c:287  regen gated on reserve > 0
--
-- CLUSTER 4 — PER-BASE IDLE LEDGER: idle hardware now lives in a PER-BASE ledger (S.base_ledger,
-- counts by role at each owned base), NOT a single per-side pool. This localises EECH's reserve
-- hardware to keysites — the task engine's resident-group source (assign.c LIST_TYPE_KEYSITE_GROUP).
-- The per-side pool is the SUM of base ledgers (reserve_side); consume_side/recycle_side stay as
-- thin wrappers that pick a base internally (the richest owned base) when the caller has no base in
-- hand. The task board (task_board.lua) consumes from the CHOSEN launch base at assignment time.
-- Why a proxy: DCS cannot keep hundreds of parked AI aircraft alive (parking/perf), so parked
-- aircraft are counts, spawned physically only at assignment and despawned on RTB.
--
-- PORT PROXY — recycle-on-RTB: shipped EECH has ZERO callers of replace_into_force_info (force.c:
-- 278-300; verified full-tree grep, spec 02 FORCE-F6) — hardware that lands/withdraws is never
-- returned. The port credits reserve on RTB (make_land_handler → the LANDING base's ledger) and on
-- task expiry (reaction.lua) as a reconstruction of the DESIGN intent (force conservation with
-- location: survivors become idle inventory at the base they landed at, transferable thereafter).
--
-- PRODUCTION (this cluster) — the OTHER caller of the replacement mechanism: production keysites
-- (factory/refinery/port, KEYSITE-F1/F5) accumulate ammo/fuel as cargo crates while alive+owned;
-- crates restock consumer keysites (KEYSITE-F6/F7/F8, in keysite_repair.lua) and SURPLUS crates
-- convert to reserve replacement here (convert_reserves → recycle_side). This is a deliberate port
-- synthesis: shipped EECH keeps aircraft-reserve and keysite-supply on separate ledgers, but the
-- port has no crate-logistics entities, so production is wired to BOTH surfaces so that destroying
-- an enemy factory genuinely starves it (the economic-vulnerability gap). Rates: eech ks_dbase.c
-- factory ammo +1.0/min, refinery fuel +1.0/min; crate size 10 (cargo.h:89,91).
--
-- The public API is still keyed by base NAME (so existing call sites are unchanged); a base
-- name resolves to its owner side via S.base_owner, and all accounting hits that side's pool.
-- Side-keyed variants (*_side) exist for code that already has the side in hand.
--
-- VEHICLE/TROOP reserve discipline: ground reinforcement (ground_forces.lua) draws the "vehicle"
-- pool through the SAME consume_side/recycle_side path (with refund on failure) as aircraft — the
-- reserve gate is identical (EECH gates vehicle regen on reserves too, rg_updt.c:291). Production's
-- convert_reserves also replenishes the vehicle/troop pools, so factory loss starves the ground war.
*/

import * as cs from "./campaign_state";
import type { InventoryLedger, Side } from "./campaign_types";
import * as config from "./config";
import * as keysite from "./keysite";
import { matches } from "./lua_interop";
import { BLUE, RED } from "./sides";

export type Role =
	| "striker"
	| "escort"
	| "heli"
	| "recon"
	| "transport"
	| "vehicle";
export type Commodity = "ammo" | "fuel";
type LogFunction = (this: void, message: string) => void;

export interface PrefixRole {
	pattern: string;
	role: Role;
	regen: boolean;
}

const S = cs.S;
const SIDES: Side[] = [BLUE, RED];
const LANDED_GROUP_CLEANUP_DELAY_SECONDS = 30;

export const ROLES: Role[] = [
	"striker",
	"escort",
	"heli",
	"recon",
	"transport",
	"vehicle",
];
export const ROLE_CATEGORY: Record<Role, string> = {
	striker: "ARMED_FIXED_WING",
	escort: "ARMED_FIXED_WING",
	recon: "ARMED_FIXED_WING",
	transport: "UNARMED_FIXED_WING",
	heli: "ARMED_HELICOPTER",
	vehicle: "ARMED_ROUTED_VEHICLE",
};

const RESERVE_PER_BASE = config.C.reserves.per_base;
const CRATE_SIZE = 10; // eech cargo.h:89,91 CARGO_AMMO_SIZE / CARGO_FUEL_SIZE
const AMMO_RESERVE_ROLES: Role[] = ["heli", "striker", "vehicle"];
const FUEL_RESERVE_ROLES: Role[] = ["escort", "recon", "transport"];

// Ordered, load-bearing get_regen_sub_type classification (rg_updt.c:598). The same table feeds RTB
// recycling and regeneration; one-shot flights recycle survivors but never enter the regen queue.
export const PREFIX_ROLES: PrefixRole[] = [
	{ pattern: "^Escort%-", role: "escort", regen: true },
	{ pattern: "^Regen%-Escort", role: "escort", regen: true },
	{ pattern: "^OCA%-Sweep", role: "escort", regen: true },
	{ pattern: "^CAP%-", role: "escort", regen: true },
	{ pattern: "^BARCAP%-", role: "escort", regen: true },
	{ pattern: "^Strike%-", role: "striker", regen: true },
	{ pattern: "^Regen%-Strike", role: "striker", regen: true },
	{ pattern: "^KStrike%-", role: "striker", regen: true },
	{ pattern: "^OCAStrike%-", role: "striker", regen: true },
	{ pattern: "^CAS%-", role: "striker", regen: true },
	{ pattern: "^BAI%-", role: "striker", regen: true },
	{ pattern: "^SEAD%-", role: "striker", regen: true },
	{ pattern: "^Recon%-", role: "recon", regen: false },
	{ pattern: "^Ferry%-", role: "transport", regen: false },
	{ pattern: "^Insert%-", role: "transport", regen: false },
	{ pattern: "^Supply%-", role: "transport", regen: false },
	{ pattern: "^Heli", role: "heli", regen: true },
	{ pattern: "^Regen%-Heli", role: "heli", regen: true },
	{ pattern: "^BDA%-", role: "heli", regen: true },
];

export function classify_role(name: string): Role | undefined {
	for (const entry of PREFIX_ROLES) {
		if (matches(name, entry.pattern)) return entry.role;
	}
	return undefined;
}

export function classify_group(name: string): Role | undefined {
	for (const entry of PREFIX_ROLES) {
		if (matches(name, entry.pattern))
			return entry.regen ? entry.role : undefined;
	}
	return undefined;
}

export function init(logFn: LogFunction = () => undefined): void {
	S.base_ledger = {};
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === BLUE || owner === RED) {
			const kind = S.base_kind[name];
			const helicopterOnly = kind === "fob" || kind === "farp";
			const ledger: InventoryLedger = {
				striker: 0,
				escort: 0,
				heli: 0,
				recon: 0,
				transport: 0,
				vehicle: 0,
			};
			for (const role of ROLES) {
				if (helicopterOnly) {
					ledger[role] =
						role === "heli"
							? config.C.reserves.farp_heli
							: role === "transport"
								? config.C.reserves.farp_transport
								: 0;
				} else {
					ledger[role] = RESERVE_PER_BASE[role] ?? 0;
				}
			}
			S.base_ledger[name] = ledger;
		}
	}
	S.production = {
		[BLUE]: {
			ammo: 0,
			fuel: 0,
			ammo_rr: 0,
			fuel_rr: 0,
			ammo_earmark: 0,
			fuel_earmark: 0,
		},
		[RED]: {
			ammo: 0,
			fuel: 0,
			ammo_rr: 0,
			fuel_rr: 0,
			ammo_earmark: 0,
			fuel_earmark: 0,
		},
	};
	S._recycled = {};
	for (const side of SIDES) {
		logFn(
			string.format(
				"supply: %s reserve seeded — striker=%d escort=%d heli=%d recon=%d veh=%d",
				cs.SIDE_NAME[side],
				reserve_side(side, "striker"),
				reserve_side(side, "escort"),
				reserve_side(side, "heli"),
				reserve_side(side, "recon"),
				reserve_side(side, "vehicle"),
			),
		);
		cs.dbg(
			"supply",
			"%s reserve seeded: striker=%d escort=%d heli=%d recon=%d veh=%d",
			cs.SIDE_NAME[side],
			reserve_side(side, "striker"),
			reserve_side(side, "escort"),
			reserve_side(side, "heli"),
			reserve_side(side, "recon"),
			reserve_side(side, "vehicle"),
		);
	}
}

export function ledger(base: string | undefined, role: Role): number {
	if (base === undefined) return 0;
	return S.base_ledger[base]?.[role] ?? 0;
}

export function consume_base(
	base: string | undefined,
	role: Role,
	count = 1,
): boolean {
	const baseLedger = base !== undefined ? S.base_ledger[base] : undefined;
	if (baseLedger === undefined) {
		cs.dbg(
			"supply",
			"consume_base FAIL: %s has no ledger (unowned/unknown base)",
			tostring(base),
		);
		return false;
	}
	const before = baseLedger[role] ?? 0;
	if (before < count) {
		cs.dbg(
			"supply",
			"consume_base FAIL: %s %s stock=%d < requested=%d",
			base,
			role,
			before,
			count,
		);
		return false;
	}
	baseLedger[role] = before - count;
	cs.dbg(
		"supply",
		"consume_base: %s %s %d -> %d (-%d)",
		base,
		role,
		before,
		baseLedger[role],
		count,
	);
	return true;
}

const FIXED_WING_ROLES: Partial<Record<Role, boolean>> = {
	striker: true,
	escort: true,
	recon: true,
};

function helicopterOnlyBase(name: string): boolean {
	const kind = S.base_kind[name];
	return kind === "farp" || kind === "fob";
}

export function recycle_base(
	base: string | undefined,
	role: Role,
	count = 1,
): void {
	let destination = base;
	if (
		destination !== undefined &&
		FIXED_WING_ROLES[role] &&
		helicopterOnlyBase(destination)
	) {
		const owner = S.base_owner[destination];
		let redirect: string | undefined;
		let bestCount = -1;
		for (const [name, candidateOwner] of pairs(S.base_owner)) {
			if (candidateOwner === owner && !helicopterOnlyBase(name)) {
				const candidateCount = S.base_ledger[name]?.[role] ?? 0;
				if (candidateCount > bestCount) {
					bestCount = candidateCount;
					redirect = name;
				}
			}
		}
		if (redirect !== undefined) {
			cs.dbg(
				"supply",
				"recycle_base: %s is heli-only, %s credit redirected -> %s",
				destination,
				role,
				redirect,
			);
			destination = redirect;
		}
	}

	let baseLedger =
		destination !== undefined ? S.base_ledger[destination] : undefined;
	if (baseLedger === undefined) {
		if (destination === undefined) {
			cs.dbg(
				"supply",
				"recycle_base FAIL: no base name / no S.base_ledger, credit of %d %s LOST",
				count,
				role,
			);
			return;
		}
		baseLedger = {
			striker: 0,
			escort: 0,
			heli: 0,
			recon: 0,
			transport: 0,
			vehicle: 0,
		};
		S.base_ledger[destination] = baseLedger;
		cs.dbg(
			"supply",
			"recycle_base: %s had no ledger, lazily created",
			destination,
		);
	}
	const before = baseLedger[role] ?? 0;
	baseLedger[role] = before + count;
	cs.dbg(
		"supply",
		"recycle_base: %s %s %d -> %d (+%d)",
		destination,
		role,
		before,
		baseLedger[role],
		count,
	);
}

function richestBase(side: Side, role: Role): string | undefined {
	let best: string | undefined;
	let bestCount = 0;
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === side) {
			const count = ledger(name, role);
			if (count > bestCount) {
				bestCount = count;
				best = name;
			}
		}
	}
	return best;
}

function anyOwnedBase(side: Side, role: Role): string | undefined {
	const richest = richestBase(side, role);
	if (richest !== undefined) return richest;
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === side && S.base_ledger[name] !== undefined) return name;
	}
	return undefined;
}

export function reserve_side(side: Side, role: Role): number {
	let total = 0;
	for (const [name, owner] of pairs(S.base_owner)) {
		if (owner === side) total += ledger(name, role);
	}
	return total;
}

export function consume_side(side: Side, role: Role, count = 1): boolean {
	const base = richestBase(side, role);
	if (base === undefined || ledger(base, role) < count) {
		cs.dbg(
			"supply",
			"consume_side FAIL: %s has no base with >= %d %s in stock",
			cs.SIDE_NAME[side],
			count,
			role,
		);
		return false;
	}
	return consume_base(base, role, count);
}

export function recycle_side(side: Side, role: Role, count = 1): void {
	const base = anyOwnedBase(side, role);
	if (base === undefined) {
		cs.dbg(
			"supply",
			"recycle_side FAIL: %s owns no base, credit of %d %s LOST",
			cs.SIDE_NAME[side],
			count,
			role,
		);
		return;
	}
	recycle_base(base, role, count);
}

export function credit_production(
	side: Side,
	ammoRate = 0,
	fuelRate = 0,
	minutes = 1,
): void {
	const accumulator = S.production[side];
	if (accumulator === undefined) return;
	accumulator.ammo += ammoRate * minutes;
	accumulator.fuel += fuelRate * minutes;
}

export function deliver_crate(side: Side, commodity: Commodity): boolean {
	const accumulator = S.production[side];
	if (accumulator === undefined || accumulator[commodity] < CRATE_SIZE)
		return false;
	accumulator[commodity] -= CRATE_SIZE;
	cs.dbg(
		"supply",
		"%s deliver_crate: %s crate picked up (%.1f remaining)",
		cs.SIDE_NAME[side],
		commodity,
		accumulator[commodity],
	);
	return true;
}

export function refund_crate(side: Side, commodity: Commodity): void {
	const accumulator = S.production[side];
	if (accumulator === undefined) return;
	accumulator[commodity] += CRATE_SIZE;
	cs.dbg(
		"supply",
		"%s refund_crate: %s crate returned (%.1f banked)",
		cs.SIDE_NAME[side],
		commodity,
		accumulator[commodity],
	);
}

function earmarkKey(commodity: Commodity): "ammo_earmark" | "fuel_earmark" {
	return commodity === "ammo" ? "ammo_earmark" : "fuel_earmark";
}

function roundRobinKey(commodity: Commodity): "ammo_rr" | "fuel_rr" {
	return commodity === "ammo" ? "ammo_rr" : "fuel_rr";
}

export function free_crate(side: Side, commodity: Commodity): boolean {
	const accumulator = S.production[side];
	if (accumulator === undefined) return false;
	return (
		accumulator[commodity] - accumulator[earmarkKey(commodity)] * CRATE_SIZE >=
		CRATE_SIZE
	);
}

export function earmark_crate(side: Side, commodity: Commodity): boolean {
	if (!free_crate(side, commodity)) return false;
	const accumulator = S.production[side];
	if (accumulator === undefined) return false;
	const key = earmarkKey(commodity);
	accumulator[key]++;
	cs.dbg(
		"supply",
		"%s earmark_crate: %s earmark -> %d (%.1f banked)",
		cs.SIDE_NAME[side],
		commodity,
		accumulator[key],
		accumulator[commodity],
	);
	return true;
}

export function release_earmark(side: Side, commodity: Commodity): void {
	const accumulator = S.production[side];
	if (accumulator === undefined) return;
	const key = earmarkKey(commodity);
	accumulator[key] = math.max(0, accumulator[key] - 1);
}

export function set_earmark(side: Side, commodity: Commodity, count = 0): void {
	const accumulator = S.production[side];
	if (accumulator === undefined) return;
	const maxCrates = math.floor(accumulator[commodity] / CRATE_SIZE);
	accumulator[earmarkKey(commodity)] = math.max(0, math.min(count, maxCrates));
}

export function convert_reserves(
	side: Side,
	_logFn: LogFunction = () => undefined,
): void {
	const accumulator = S.production[side];
	if (accumulator === undefined) return;
	const drain = (commodity: Commodity, roles: Role[]): void => {
		let converted = 0;
		const earmark = accumulator[earmarkKey(commodity)];
		const rrKey = roundRobinKey(commodity);
		while (accumulator[commodity] - earmark * CRATE_SIZE >= CRATE_SIZE) {
			accumulator[commodity] -= CRATE_SIZE;
			const roundRobin = (accumulator[rrKey] % roles.length) + 1;
			accumulator[rrKey] = roundRobin;
			recycle_side(side, roles[roundRobin - 1], 1);
			converted++;
		}
		if (converted > 0) {
			cs.dbg(
				"supply",
				"%s convert_reserves: %d surplus %s crate(s) -> reserve hardware",
				cs.SIDE_NAME[side],
				converted,
				commodity,
			);
		}
	};
	drain("ammo", AMMO_RESERVE_ROLES);
	drain("fuel", FUEL_RESERVE_ROLES);
}

export function available(name: string, role: Role): number {
	return ledger(name, role);
}

export function consume(name: string, role: Role, count = 1): boolean {
	return consume_base(name, role, count);
}

export function produce(name: string, role: Role, count = 1): void {
	recycle_base(name, role, count);
}

export function make_land_handler(
	logFn: LogFunction = () => undefined,
): DcsEventHandler {
	return {
		onEvent(event: DcsEvent): void {
			if (
				event.id !== world.event.S_EVENT_LAND ||
				event.initiator === undefined
			)
				return;
			const unit = event.initiator;
			if (unit.getGroup === undefined) return;
			const [ok, group] = pcall(() => unit.getGroup?.());
			if (!ok || group === undefined || !group.isExist()) return;
			const groupName = group.getName();
			keysite.release_slot(groupName);
			const role = classify_role(groupName);
			if (
				role === undefined ||
				unit.getPlayerName?.() !== undefined ||
				S._recycled[groupName]
			)
				return;
			S._recycled[groupName] = true;

			const [sideRead, coalitionSide] = pcall(() => unit.getCoalition?.());
			if (!sideRead || (coalitionSide !== BLUE && coalitionSide !== RED))
				return;
			const side = coalitionSide === BLUE ? BLUE : RED;
			const survivors = group.getUnits();
			const survivorCount = survivors?.length ?? 1;
			const landingPos = unit.getPosition().p;
			let landingBase: string | undefined;
			let bestDistanceSquared = math.huge;
			for (const [baseName, baseOwner] of pairs(S.base_owner)) {
				const basePos = S.base_pos[baseName];
				if (baseOwner === side && basePos !== undefined) {
					const dx = landingPos.x - basePos.x;
					const dz = landingPos.z - basePos.z;
					const distanceSquared = dx * dx + dz * dz;
					if (distanceSquared < bestDistanceSquared) {
						bestDistanceSquared = distanceSquared;
						landingBase = baseName;
					}
				}
			}
			if (landingBase !== undefined)
				recycle_base(landingBase, role, survivorCount);
			else recycle_side(side, role, survivorCount);
			logFn(
				string.format(
					"supply: %s (%s) RTB @ %s → +%d %s (base now %d / side %d)",
					groupName,
					cs.SIDE_NAME[side],
					landingBase ?? "?",
					survivorCount,
					role,
					ledger(landingBase, role),
					reserve_side(side, role),
				),
			);

			timer.scheduleFunction(
				(_argument: undefined, _time: number) => {
					if (group.isExist()) group.destroy();
					return undefined;
				},
				undefined,
				timer.getTime() + LANDED_GROUP_CLEANUP_DELAY_SECONDS,
			);
		},
	};
}

const SUPPLY_PERIOD = 10 * 60;

export function schedule_supply(logFn: LogFunction = () => undefined): void {
	const generation = _DMT_GEN;
	cs.dbg(
		"supply",
		"reserve-status scheduler REGISTERED offset=%.0fs period=%.0fs",
		SUPPLY_PERIOD,
		SUPPLY_PERIOD,
	);
	timer.scheduleFunction(
		(_argument: undefined, time: number) => {
			if (_DMT_GEN !== generation) return undefined;
			for (const side of SIDES) {
				const production = S.production[side];
				logFn(
					string.format(
						"reserve %s: striker=%d escort=%d heli=%d recon=%d veh=%d | crates ammo=%.1f fuel=%.1f | tasks failed=%d",
						cs.SIDE_NAME[side],
						reserve_side(side, "striker"),
						reserve_side(side, "escort"),
						reserve_side(side, "heli"),
						reserve_side(side, "recon"),
						reserve_side(side, "vehicle"),
						production?.ammo ?? 0,
						production?.fuel ?? 0,
						S.board_failed ?? 0,
					),
				);
			}
			return time + SUPPLY_PERIOD;
		},
		undefined,
		timer.getTime() + SUPPLY_PERIOD,
	);
}
